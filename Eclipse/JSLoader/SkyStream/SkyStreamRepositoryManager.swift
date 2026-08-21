import Foundation
import CryptoKit

public struct SkyStreamSavedRepository: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case repository
        case pluginList
    }

    public var sourceURL: String
    public var kind: Kind
    public var name: String
    public var repositoryPackageName: String?
    public var manifest: SkyStreamRepositoryManifest?
    public var pluginListURLs: [String]
    public var plugins: [SkyStreamPluginListEntry]
    public var lastRefreshedAt: Date
    public var frozenAt: Date?

    public var id: String { sourceURL }

    public init(
        sourceURL: String,
        kind: Kind,
        name: String,
        repositoryPackageName: String? = nil,
        manifest: SkyStreamRepositoryManifest? = nil,
        pluginListURLs: [String] = [],
        plugins: [SkyStreamPluginListEntry],
        lastRefreshedAt: Date = Date(),
        frozenAt: Date? = nil
    ) {
        self.sourceURL = sourceURL
        self.kind = kind
        self.name = name
        self.repositoryPackageName = repositoryPackageName
        self.manifest = manifest
        self.pluginListURLs = pluginListURLs
        self.plugins = plugins
        self.lastRefreshedAt = lastRefreshedAt
        self.frozenAt = frozenAt
    }
}

public enum SkyStreamResolvedInput: Sendable {
    case archive(data: Data, sourceURL: URL)
    case repository(SkyStreamSavedRepository)
}

public enum SkyStreamRepositoryError: Error, Sendable, Equatable {
    case unavailable
    case unsupportedInput
    case invalidRepositoryManifest
    case unsupportedRepositoryManifestVersion(Int)
    case tooManyPluginLists
    case tooManyRepositories
    case tooManyPlugins
    case catalogTooLarge
    case expansionTimedOut
    case duplicatePackage(String)
    case invalidPackageEntry(String)
    case httpStatus(Int)
}

extension SkyStreamRepositoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "SkyStream repositories are available only on iPhone and iPad."
        case .unsupportedInput:
            return "The URL did not return a SkyStream repository, plugin list, or .sky package."
        case .invalidRepositoryManifest:
            return "The SkyStream repository manifest is invalid."
        case .unsupportedRepositoryManifestVersion(let version):
            return "SkyStream repository manifest version \(version) is unsupported."
        case .tooManyPluginLists:
            return "The repository declares too many plugin lists."
        case .tooManyRepositories:
            return "The repository includes too many nested repositories."
        case .tooManyPlugins:
            return "The repository contains too many plugin entries."
        case .catalogTooLarge:
            return "The repository catalog is too large to store safely."
        case .expansionTimedOut:
            return "The repository took too long to expand its plugin lists."
        case .duplicatePackage(let packageName):
            return "The repository contains conflicting entries for \(packageName)."
        case .invalidPackageEntry(let packageName):
            return "The repository contains an invalid package entry for \(packageName)."
        case .httpStatus(let status):
            return "The SkyStream server returned HTTP \(status)."
        }
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)

private final class SkyStreamRepositoryDeadlineCoordinator<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var result: Result<Value, Error>?
    private var cancelled = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func installTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        lock.lock()
        operationTask = operation
        timeoutTask = timeout
        let shouldCancel = result != nil || cancelled
        lock.unlock()
        if shouldCancel {
            operation.cancel()
            timeout.cancel()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil, !cancelled else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        lock.unlock()
        continuation?.resume(with: result)
        operationTask?.cancel()
        timeoutTask?.cancel()
    }

    func cancel() {
        lock.lock()
        guard result == nil, !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        operationTask?.cancel()
        timeoutTask?.cancel()
    }
}

public actor SkyStreamRepositoryManager {
    public static let shared = SkyStreamRepositoryManager()

    private let policy: SkyStreamRemoteURLPolicy
    private let client: SkyStreamHTTPClient
    private let decoder = JSONDecoder()
    private let maximumDocumentBytes = 2 * 1_024 * 1_024
    private let maximumArchiveBytes = 20 * 1_024 * 1_024
    private let maximumPluginLists = 32
    private let maximumRepositories = 32
    private let maximumPlugins = 2_000

    private let maximumExpandedCatalogBytes = 4 * 1_024 * 1_024
    private let maximumConcurrentPluginListFetches = 4
    private let repositoryExpansionDeadline: TimeInterval = 45

    private final class RepositoryExpansionState: @unchecked Sendable {
        var visitedRepositoryURLs = Set<String>()
        var repositoryCount = 0
        var fetchedDocumentBytes = 0
        var catalogURLs: [String] = []
        var seenCatalogURLs = Set<String>()
        var entries: [SkyStreamPluginListEntry] = []
    }

    public init(
        policy: SkyStreamRemoteURLPolicy = .shared,
        client: SkyStreamHTTPClient = .shared
    ) {
        self.policy = policy
        self.client = client
    }

    public func resolveUserInput(_ rawURL: String) async throws -> SkyStreamResolvedInput {
        let validated = try await validateRepositoryReference(rawURL, relativeTo: nil)
        let response = try await fetch(
            validated,
            maximumBytes: maximumArchiveBytes,
            packageNamespace: namespace(for: validated.url)
        )
        guard (200..<300).contains(response.statusCode) else {
            throw SkyStreamRepositoryError.httpStatus(response.statusCode)
        }

        if Self.hasZIPMagic(response.data) {
            return .archive(data: response.data, sourceURL: response.finalURL)
        }
        guard response.data.count <= maximumDocumentBytes else {
            throw SkyStreamSecurityError.responseTooLarge
        }
        return .repository(try await decodeRepositoryDocument(
            response.data,
            sourceURL: response.finalURL
        ))
    }

    public func refresh(_ saved: SkyStreamSavedRepository) async throws -> SkyStreamSavedRepository {
        let refreshed = try await resolveUserInput(saved.sourceURL)
        guard case .repository(var repository) = refreshed else {
            throw SkyStreamRepositoryError.unsupportedInput
        }

        repository.frozenAt = nil
        return repository
    }

    public func downloadArchive(
        from entry: SkyStreamPluginListEntry,
        relativeTo baseURL: URL,
        packageName: String
    ) async throws -> (data: Data, finalURL: URL) {
        guard entry.manifest.packageName == packageName,
              SkyStreamStableID.isValidPackageName(packageName) else {
            throw SkyStreamRepositoryError.invalidPackageEntry(packageName)
        }
        let validated = try await policy.validate(entry.url, purpose: .package, relativeTo: baseURL)
        let response = try await fetch(
            validated,
            maximumBytes: maximumArchiveBytes,
            packageNamespace: namespace(for: validated.url)
        )
        guard (200..<300).contains(response.statusCode) else {
            throw SkyStreamRepositoryError.httpStatus(response.statusCode)
        }
        guard Self.hasZIPMagic(response.data) else {
            throw SkyStreamRepositoryError.unsupportedInput
        }
        return (response.data, response.finalURL)
    }

    private func decodeRepositoryDocument(
        _ data: Data,
        sourceURL: URL
    ) async throws -> SkyStreamSavedRepository {
        let document: SkyStreamRepositoryDocument
        do {
            try SkyStreamJSONEnvelopeValidator.validate(data, limits: .repository)
            document = try decoder.decode(SkyStreamRepositoryDocument.self, from: data)
        } catch {
            throw SkyStreamRepositoryError.unsupportedInput
        }

        switch document {
        case .repository(let manifest):
            return try await expandRepository(manifest, sourceURL: sourceURL)
        case .pluginList(let list):
            let plugins = try await validatedEntries(list.plugins, relativeTo: sourceURL)
            let repository = SkyStreamSavedRepository(
                sourceURL: sourceURL.absoluteString,
                kind: .pluginList,
                name: Self.defaultListName(for: sourceURL),
                pluginListURLs: [sourceURL.absoluteString],
                plugins: plugins
            )
            try requireCatalogBudget(repository)
            return repository
        }
    }

    private func expandRepository(
        _ manifest: SkyStreamRepositoryManifest,
        sourceURL: URL
    ) async throws -> SkyStreamSavedRepository {
        try await withExpansionDeadline { [self] in
            try await expandRepositoryWithinDeadline(manifest, sourceURL: sourceURL)
        }
    }

    private func expandRepositoryWithinDeadline(
        _ manifest: SkyStreamRepositoryManifest,
        sourceURL: URL
    ) async throws -> SkyStreamSavedRepository {
        try Task.checkCancellation()
        let state = RepositoryExpansionState()
        state.repositoryCount = 1
        state.visitedRepositoryURLs.insert(sourceURL.absoluteString)
        try await expandRepositoryManifest(
            manifest,
            sourceURL: sourceURL,
            state: state
        )

        var storedManifest = manifest
        storedManifest.pluginLists = state.catalogURLs
        storedManifest.includedRepositories = []
        storedManifest.plugins = []
        let repository = SkyStreamSavedRepository(
            sourceURL: sourceURL.absoluteString,
            kind: .repository,
            name: manifest.name,
            repositoryPackageName: manifest.packageName,
            manifest: storedManifest,
            pluginListURLs: state.catalogURLs,
            plugins: try deduplicated(state.entries)
        )
        try requireCatalogBudget(repository)
        return repository
    }

    private func expandRepositoryManifest(
        _ manifest: SkyStreamRepositoryManifest,
        sourceURL: URL,
        state: RepositoryExpansionState
    ) async throws {
        try Task.checkCancellation()
        try validateRepositoryManifest(manifest)

        if !manifest.plugins.isEmpty {
            let embeddedEntries = try await validatedEntries(
                manifest.plugins,
                relativeTo: sourceURL
            )
            try appendEntries(
                embeddedEntries,
                catalogURL: sourceURL.absoluteString,
                state: state
            )
        }

        let validatedListURLs = try await policy.validate(
            manifest.pluginLists.map {
                SkyStreamRemoteURLValidationRequest(
                    rawValue: $0,
                    purpose: .repository,
                    relativeTo: sourceURL
                )
            },
            maximumConcurrentDNSLookups: maximumConcurrentPluginListFetches
        )
        try Task.checkCancellation()
        var listURLs: [SkyStreamValidatedRemoteURL] = []
        var seenListURLs = Set<String>()
        for url in validatedListURLs {
            guard seenListURLs.insert(url.url.absoluteString).inserted else { continue }
            listURLs.append(url)
        }

        for fetched in try await fetchPluginListDocuments(listURLs, sourceURL: sourceURL) {
            try Task.checkCancellation()
            let response = fetched.response
            guard (200..<300).contains(response.statusCode) else {
                throw SkyStreamRepositoryError.httpStatus(response.statusCode)
            }
            try recordFetchedDocument(response.data.count, state: state)
            let list: SkyStreamPluginListDocument
            do {
                try SkyStreamJSONEnvelopeValidator.validate(response.data, limits: .repository)
                list = try decoder.decode(SkyStreamPluginListDocument.self, from: response.data)
            } catch {
                throw SkyStreamRepositoryError.unsupportedInput
            }
            let listEntries = try await validatedEntries(
                list.plugins,
                relativeTo: response.finalURL
            )
            try appendEntries(
                listEntries,
                catalogURL: fetched.requestURL.absoluteString,
                state: state
            )
        }

        for rawRepositoryURL in manifest.includedRepositories {
            try Task.checkCancellation()
            let validated: SkyStreamValidatedRemoteURL
            do {
                validated = try await validateRepositoryReference(
                    rawRepositoryURL,
                    relativeTo: sourceURL
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()

                continue
            }
            let requestedKey = validated.url.absoluteString
            guard state.visitedRepositoryURLs.insert(requestedKey).inserted else { continue }
            state.repositoryCount += 1
            guard state.repositoryCount <= maximumRepositories else {
                throw SkyStreamRepositoryError.tooManyRepositories
            }

            let response: SkyStreamHTTPResponse
            do {
                response = try await fetch(
                    validated,
                    maximumBytes: maximumDocumentBytes,
                    packageNamespace: namespace(for: sourceURL)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                continue
            }
            try recordFetchedDocument(response.data.count, state: state)

            let finalKey = response.finalURL.absoluteString
            if finalKey != requestedKey,
               !state.visitedRepositoryURLs.insert(finalKey).inserted {

                continue
            }

            let document: SkyStreamRepositoryDocument
            do {
                try SkyStreamJSONEnvelopeValidator.validate(response.data, limits: .repository)
                document = try decoder.decode(SkyStreamRepositoryDocument.self, from: response.data)
            } catch {
                continue
            }
            guard case .repository(let childManifest) = document else {
                continue
            }
            try await expandRepositoryManifest(
                childManifest,
                sourceURL: response.finalURL,
                state: state
            )
        }
    }

    private func validateRepositoryManifest(
        _ manifest: SkyStreamRepositoryManifest
    ) throws {
        guard Self.isSupportedRepositoryManifestVersion(manifest.manifestVersion) else {
            throw SkyStreamRepositoryError.unsupportedRepositoryManifestVersion(
                manifest.manifestVersion
            )
        }
        guard Self.isBoundedDisplayString(manifest.name, maximumBytes: 256),
              manifest.description.utf8.count <= 4 * 1_024,
              SkyStreamStableID.isValidPackageName(manifest.packageName),
              !manifest.pluginLists.isEmpty
                || !manifest.includedRepositories.isEmpty
                || !manifest.plugins.isEmpty,
              manifest.authors.map({
                  Self.areBoundedDisplayStrings($0, maximumCount: 64)
              }) ?? true else {
            throw SkyStreamRepositoryError.invalidRepositoryManifest
        }
        guard manifest.pluginLists.count <= maximumPluginLists else {
            throw SkyStreamRepositoryError.tooManyPluginLists
        }
        guard manifest.includedRepositories.count <= maximumRepositories else {
            throw SkyStreamRepositoryError.tooManyRepositories
        }
        guard manifest.plugins.count <= maximumPlugins else {
            throw SkyStreamRepositoryError.tooManyPlugins
        }
    }

    static func isSupportedRepositoryManifestVersion(_ version: Int) -> Bool {
        SkyStreamRepositoryManifest.isSupportedManifestVersion(version)
    }

    private func appendEntries(
        _ entries: [SkyStreamPluginListEntry],
        catalogURL: String,
        state: RepositoryExpansionState
    ) throws {
        let (nextCount, overflow) = state.entries.count.addingReportingOverflow(entries.count)
        guard !overflow, nextCount <= maximumPlugins else {
            throw SkyStreamRepositoryError.tooManyPlugins
        }
        state.entries.append(contentsOf: entries)
        if state.seenCatalogURLs.insert(catalogURL).inserted {
            guard state.catalogURLs.count < maximumPluginLists else {
                throw SkyStreamRepositoryError.tooManyPluginLists
            }
            state.catalogURLs.append(catalogURL)
        }
    }

    private func recordFetchedDocument(
        _ byteCount: Int,
        state: RepositoryExpansionState
    ) throws {
        let (nextBytes, overflow) = state.fetchedDocumentBytes.addingReportingOverflow(byteCount)
        guard !overflow, nextBytes <= maximumExpandedCatalogBytes else {
            throw SkyStreamRepositoryError.catalogTooLarge
        }
        state.fetchedDocumentBytes = nextBytes
    }

    private struct FetchedPluginList: Sendable {
        let index: Int
        let requestURL: URL
        let response: SkyStreamHTTPResponse
    }

    private func fetchPluginListDocuments(
        _ listURLs: [SkyStreamValidatedRemoteURL],
        sourceURL: URL
    ) async throws -> [FetchedPluginList] {
        guard !listURLs.isEmpty else { return [] }
        let packageNamespace = namespace(for: sourceURL)
        return try await withThrowingTaskGroup(
            of: FetchedPluginList.self,
            returning: [FetchedPluginList].self
        ) { group in
            var nextIndex = 0
            var aggregateBytes = 0
            var results: [FetchedPluginList] = []
            results.reserveCapacity(listURLs.count)

            func submit(_ index: Int) {
                let listURL = listURLs[index]
                group.addTask { [self] in
                    let response = try await fetch(
                        listURL,
                        maximumBytes: maximumDocumentBytes,
                        packageNamespace: packageNamespace
                    )
                    return FetchedPluginList(
                        index: index,
                        requestURL: listURL.url,
                        response: response
                    )
                }
            }

            while nextIndex < min(maximumConcurrentPluginListFetches, listURLs.count) {
                submit(nextIndex)
                nextIndex += 1
            }
            while let fetched = try await group.next() {
                try Task.checkCancellation()
                let (nextBytes, overflow) = aggregateBytes.addingReportingOverflow(
                    fetched.response.data.count
                )
                guard !overflow, nextBytes <= maximumExpandedCatalogBytes else {
                    group.cancelAll()
                    throw SkyStreamRepositoryError.catalogTooLarge
                }
                aggregateBytes = nextBytes
                results.append(fetched)
                if nextIndex < listURLs.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    private func requireCatalogBudget(_ repository: SkyStreamSavedRepository) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(repository),
              encoded.count <= maximumExpandedCatalogBytes else {
            throw SkyStreamRepositoryError.catalogTooLarge
        }
    }

    private func withExpansionDeadline<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let coordinator = SkyStreamRepositoryDeadlineCoordinator<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                coordinator.install(continuation)
                let operationTask = Task {
                    do {
                        coordinator.resolve(.success(try await operation()))
                    } catch {
                        coordinator.resolve(.failure(error))
                    }
                }
                let deadline = repositoryExpansionDeadline
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(deadline * 1_000_000_000)
                        )
                        coordinator.resolve(
                            .failure(SkyStreamRepositoryError.expansionTimedOut)
                        )
                    } catch {

                    }
                }
                coordinator.installTasks(operation: operationTask, timeout: timeoutTask)
            }
        } onCancel: {
            coordinator.cancel()
        }
    }

    private func validatedEntries(
        _ entries: [SkyStreamPluginListEntry],
        relativeTo baseURL: URL
    ) async throws -> [SkyStreamPluginListEntry] {
        guard entries.count <= maximumPlugins else {
            throw SkyStreamRepositoryError.tooManyPlugins
        }
        var result: [SkyStreamPluginListEntry] = []
        result.reserveCapacity(entries.count)
        for var entry in entries {
            let packageName = entry.manifest.packageName
            if let iconURL = entry.manifest.iconURL,
               (try? policy.validateSyntactic(iconURL, purpose: .icon)) == nil {
                entry.manifest.iconURL = nil
            }
            if var providers = entry.manifest.providers {
                for index in providers.indices {
                    if let iconURL = providers[index].iconURL,
                       (try? policy.validateSyntactic(iconURL, purpose: .icon)) == nil {
                        providers[index].iconURL = nil
                    }
                }
                entry.manifest.providers = providers
            }
            guard SkyStreamStableID.isValidPackageName(packageName),
                  entry.manifest.version > 0,
                  Self.isBoundedCatalogManifest(entry.manifest) else {
                throw SkyStreamRepositoryError.invalidPackageEntry(packageName)
            }

            let archiveURL = try policy.validateSyntactic(
                entry.url,
                purpose: .package,
                relativeTo: baseURL
            )
            if !entry.manifest.baseURL.isEmpty {
                _ = try policy.validateSyntactic(
                    entry.manifest.baseURL,
                    purpose: .pluginRequest
                )
            }
            for domain in entry.manifest.domains ?? [] {
                _ = try policy.validateSyntactic(domain.url, purpose: .pluginRequest)
            }
            for provider in entry.manifest.providers ?? [] {
                if let providerURL = provider.baseURL {
                    _ = try policy.validateSyntactic(providerURL, purpose: .pluginRequest)
                }
            }
            entry.url = archiveURL.url.absoluteString
            result.append(entry)
        }
        return try deduplicated(result)
    }

    private func deduplicated(
        _ entries: [SkyStreamPluginListEntry]
    ) throws -> [SkyStreamPluginListEntry] {
        var byPackage: [String: SkyStreamPluginListEntry] = [:]
        var order: [String] = []
        for entry in entries {
            let packageName = entry.manifest.packageName
            if let previous = byPackage[packageName] {
                let same = previous.url == entry.url
                    && previous.manifest.version == entry.manifest.version
                    && previous.expectedArchiveSHA256?.lowercased()
                        == entry.expectedArchiveSHA256?.lowercased()
                guard same else { throw SkyStreamRepositoryError.duplicatePackage(packageName) }
                continue
            }
            byPackage[packageName] = entry
            order.append(packageName)
        }
        return order.compactMap { byPackage[$0] }
    }

    private func fetch(
        _ url: SkyStreamValidatedRemoteURL,
        maximumBytes: Int,
        packageNamespace: String
    ) async throws -> SkyStreamHTTPResponse {
        try Task.checkCancellation()
        let request = SkyStreamHTTPRequest(url: url)
        let limits = SkyStreamHTTPRequestLimits(
            maximumResponseBytes: maximumBytes,
            maximumRequestBodyBytes: 0,
            maximumRedirects: 5,
            timeout: 20
        )
        return try await client.fetch(request, packageID: packageNamespace, limits: limits)
    }

    private func validateRepositoryReference(
        _ rawValue: String,
        relativeTo baseURL: URL?
    ) async throws -> SkyStreamValidatedRemoteURL {
        if let shortcodeURL = Self.shortcodeURL(for: rawValue) {
            return try await policy.validate(shortcodeURL, purpose: .repository)
        }
        return try await policy.validate(
            rawValue,
            purpose: .repository,
            relativeTo: baseURL
        )
    }

    private func namespace(for url: URL) -> String {
        let origin = SkyStreamRemoteURLPolicy.redactedDescription(of: url)
        let digest = SHA256.hash(data: Data(origin.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return "repository-\(digest)"
    }

    private static func hasZIPMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let prefix = Array(data.prefix(4))
        return prefix == [0x50, 0x4b, 0x03, 0x04]
            || prefix == [0x50, 0x4b, 0x05, 0x06]
            || prefix == [0x50, 0x4b, 0x07, 0x08]
    }

    private static func defaultListName(for url: URL) -> String {
        let host = url.host?.lowercased() ?? "SkyStream"
        return "\(host) Plugin List"
    }

    private static func shortcodeURL(for rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128,
              bytes.allSatisfy({ byte in
                  (0x30...0x39).contains(byte)
                      || (0x41...0x5A).contains(byte)
                      || (0x61...0x7A).contains(byte)
                      || byte == 0x21
                      || byte == 0x5F
                      || byte == 0x2D
              }) else {
            return nil
        }
        return "https://cutt.ly/sky-\(value)"
    }

    static func isBoundedCatalogManifest(_ manifest: SkyStreamPluginManifest) -> Bool {
        guard isBoundedDisplayString(manifest.name, maximumBytes: 256),
              manifest.description.map({ isBoundedDisplayString($0, maximumBytes: 4 * 1_024) }) ?? true,
              areBoundedDisplayStrings(manifest.authors, maximumCount: 64),
              areBoundedDisplayStrings(manifest.languages, maximumCount: 64),
              areBoundedDisplayStrings(manifest.categories, maximumCount: 64),
              (manifest.domains?.count ?? 0) <= 64,
              (manifest.providers?.count ?? 0) <= 64 else {
            return false
        }
        return (manifest.domains ?? []).allSatisfy {
            isBoundedDisplayString($0.name, maximumBytes: 256)
                && $0.url.utf8.count <= 8 * 1_024
        } && (manifest.providers ?? []).allSatisfy {
            SkyStreamStableID.isValidProviderID($0.id)
                && isBoundedDisplayString($0.name, maximumBytes: 256)
                && ($0.baseURL?.utf8.count ?? 0) <= 8 * 1_024
                && ($0.iconURL?.utf8.count ?? 0) <= 8 * 1_024
                && ($0.languages?.count ?? 0) <= 64
                && ($0.languages?.allSatisfy {
                    isBoundedDisplayString($0, maximumBytes: 256)
                } ?? true)
                && ($0.categories?.count ?? 0) <= 64
                && ($0.categories?.allSatisfy {
                    isBoundedDisplayString($0, maximumBytes: 256)
                } ?? true)
        }
    }

    private static func areBoundedDisplayStrings(
        _ values: [String],
        maximumCount: Int
    ) -> Bool {
        values.count <= maximumCount
            && values.allSatisfy { isBoundedDisplayString($0, maximumBytes: 256) }
    }

    private static func isBoundedDisplayString(_ value: String, maximumBytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumBytes
    }
}

#else

public actor SkyStreamRepositoryManager {
    public static let shared = SkyStreamRepositoryManager()
    public init() {}

    public func resolveUserInput(_ rawURL: String) async throws -> SkyStreamResolvedInput {
        throw SkyStreamRepositoryError.unavailable
    }

    public func refresh(_ saved: SkyStreamSavedRepository) async throws -> SkyStreamSavedRepository {
        throw SkyStreamRepositoryError.unavailable
    }
}

#endif
