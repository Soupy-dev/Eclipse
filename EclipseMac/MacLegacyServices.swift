import CryptoKit
import Foundation
import Security
import SwiftUI

struct ServiceMetadata: Codable, Hashable {
    let sourceName: String
    let author: Author
    let iconUrl: String
    let version: String
    let language: String
    let baseUrl: String
    let streamType: String
    let quality: String
    let searchBaseUrl: String
    let scriptUrl: String
    let softsub: Bool?
    let multiStream: Bool?
    let multiSubs: Bool?
    let type: String?
    let novel: Bool?
    let settings: Bool?

    struct Author: Codable, Hashable { let name: String; let icon: String }
}

struct Service: Identifiable, Hashable, Codable {
    let id: UUID
    let metadata: ServiceMetadata
    let jsScript: String
    let url: String
    var isActive: Bool
    var sortIndex: Int64
}

enum ServiceCompatibilityError: LocalizedError, Equatable {
    case browserAutomationRequired, interactiveChallengeRequired, torrentTransportRequired
    case unsupportedTransport, responseTooLarge

    var errorDescription: String? {
        switch self {
        case .browserAutomationRequired: "This Service requires browser automation that could not complete."
        case .interactiveChallengeRequired: "This Service requires an interactive security check."
        case .torrentTransportRequired: "This Service only provides torrent transport, which Eclipse does not use."
        case .unsupportedTransport: "This Service did not provide a playable HTTP or HTTPS resource."
        case .responseTooLarge: "This Service returned more data than Eclipse's safety limit allows."
        }
    }
}

struct MacLegacySearchResult: Identifiable, Hashable {
    let service: Service
    let title: String
    let imageURL: URL?
    let href: String
    var id: String { "\(service.id.uuidString):\(href)" }
}

struct MacLegacyStream: Identifiable, Hashable {
    let id = UUID()
    let sourceID: String
    let serviceName: String
    let title: String
    let url: URL
    let headers: [String: String]
    let metadataText: String
}

@MainActor
final class MacLegacyServiceStore: ObservableObject {
    static let shared = MacLegacyServiceStore()

    @Published private(set) var services: [Service] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published var pendingVerificationURL: URL?

    private let key = "macLegacyServices.v1"
    private let maximumMetadataBytes = 1_000_000
    private let maximumScriptBytes = 5_000_000
    private var persistedOrder: [UUID] = []
    private var unresolvedRecords: [UUID: PersistedService] = [:]
    private var legacyPlaintextIDs = Set<UUID>()
    private var deletionTombstones = Set<UUID>()
    private var storageWriteBlocked = false
    private var activeServiceOperation: UUID?
    private var serviceMutationRevision: UInt64 = 0

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key) {
            let state = Self.decodeStoredState(data)
            storageWriteBlocked = state.refusesOverwrite
            deletionTombstones = state.deletionTombstones
            persistedOrder = state.records.sorted { $0.sortIndex < $1.sortIndex }.map(\.id)
            var loaded: [Service] = []
            var migratedLegacyPayload = false

            for record in state.records.sorted(by: { $0.sortIndex < $1.sortIndex }) {
                if let legacyPayload = record.legacyPayload {
                    guard Self.isValidPayload(legacyPayload) else {
                        unresolvedRecords[record.id] = record
                        storageWriteBlocked = true
                        continue
                    }
                    loaded.append(record.service(payload: legacyPayload))
                    legacyPlaintextIDs.insert(record.id)
                    // Existing plaintext remains the recovery source until Keychain confirms the
                    // exact payload. A failed migration never destroys the only usable copy.
                    if !storageWriteBlocked,
                       Self.securePayload(legacyPayload, serviceID: record.id) {
                        legacyPlaintextIDs.remove(record.id)
                        migratedLegacyPayload = true
                    }
                    continue
                }

                switch MacLegacyServiceKeychain.read(serviceID: record.id) {
                case .success(let payload?):
                    guard Self.isValidPayload(payload) else {
                        unresolvedRecords[record.id] = record
                        continue
                    }
                    loaded.append(record.service(payload: payload))
                case .success(nil), .failure:
                    // Preserve the metadata record when Keychain is locked, unavailable, or
                    // unexpectedly missing an item. A later mutation must not silently erase it.
                    unresolvedRecords[record.id] = record
                }
            }
            services = loaded.sorted { $0.sortIndex < $1.sortIndex }
            if storageWriteBlocked {
                errorMessage = LegacyError.storageLocked.localizedDescription
            } else {
                let deletedCredentials = retryPendingKeychainDeletions()
                if state.needsEnvelopeMigration || migratedLegacyPayload || deletedCredentials {
                    _ = persist()
                }
            }
        } else if defaults.object(forKey: key) != nil {
            // An unexpected defaults type is still user data. Preserve it byte-for-byte instead
            // of treating the store as empty and overwriting it on the next settings action.
            storageWriteBlocked = true
            errorMessage = LegacyError.storageLocked.localizedDescription
        }
        NotificationCenter.default.addObserver(
            forName: .cloudflareBypassSolved,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pendingVerificationURL = nil }
        }
        Task { [weak self] in await self?.refreshInstalledServicesIfEnabled() }
    }

    var activeServices: [Service] { services.filter(\.isActive).sorted { $0.sortIndex < $1.sortIndex } }

    func install(from value: String) async -> Bool {
        guard !storageWriteBlocked else {
            errorMessage = LegacyError.storageLocked.localizedDescription
            return false
        }
        guard let operationID = beginServiceOperation() else {
            errorMessage = LegacyError.operationInProgress.localizedDescription
            return false
        }
        let startingRevision = serviceMutationRevision
        errorMessage = nil
        guard let metadataURL = validatedHTTPURL(value) else {
            errorMessage = "Enter a valid HTTP or HTTPS Service JSON URL."
            finishServiceOperation(operationID)
            return false
        }
        defer { finishServiceOperation(operationID) }
        do {
            let metadataData = try await boundedData(from: metadataURL, maximum: maximumMetadataBytes)
            let metadata = try JSONDecoder().decode(ServiceMetadata.self, from: metadataData)
            let scriptURL = try resolvedHTTPURL(metadata.scriptUrl, relativeTo: metadataURL)
            let scriptData = try await boundedData(from: scriptURL, maximum: maximumScriptBytes)
            guard let script = String(data: scriptData, encoding: .utf8), !script.isEmpty else {
                throw LegacyError.invalidScript
            }
            guard serviceMutationRevision == startingRevision else { throw LegacyError.serviceStateChanged }
            let id = services.first(where: { $0.url == metadataURL.absoluteString })?.id ?? stableID(metadataURL.absoluteString)
            let existing = services.first(where: { $0.id == id })
            let unresolved = unresolvedRecords[id]
            let service = Service(
                id: id,
                metadata: metadata,
                jsScript: script,
                url: metadataURL.absoluteString,
                isActive: existing?.isActive ?? unresolved?.isActive ?? true,
                sortIndex: existing?.sortIndex ?? unresolved?.sortIndex ?? Int64(persistedOrder.count)
            )
            let payload = SecurePayload(service: service)
            let previousPayload: SecurePayload?
            switch MacLegacyServiceKeychain.read(serviceID: id) {
            case .success(let value): previousPayload = value
            case .failure: throw LegacyError.secureStorageUnavailable
            }
            if previousPayload != payload,
               !Self.securePayload(payload, serviceID: id) {
                Self.restoreKeychain(previousPayload: previousPayload, serviceID: id)
                throw LegacyError.secureStorageUnavailable
            }

            let oldServices = services
            let oldOrder = persistedOrder
            let oldUnresolvedRecords = unresolvedRecords
            let oldLegacyPlaintextIDs = legacyPlaintextIDs
            let oldTombstones = deletionTombstones
            services.removeAll { $0.id == id }
            services.append(service)
            services.sort { $0.sortIndex < $1.sortIndex }
            unresolvedRecords[id] = nil
            legacyPlaintextIDs.remove(id)
            deletionTombstones.remove(id)
            guard persist() else {
                services = oldServices
                persistedOrder = oldOrder
                unresolvedRecords = oldUnresolvedRecords
                legacyPlaintextIDs = oldLegacyPlaintextIDs
                deletionTombstones = oldTombstones
                Self.restoreKeychain(previousPayload: previousPayload, serviceID: id)
                throw LegacyError.persistenceFailed
            }
            serviceMutationRevision &+= 1
            persistSuccessfulDeletionRetries()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateAll() async {
        guard !services.isEmpty else { return }
        guard !storageWriteBlocked else {
            errorMessage = LegacyError.storageLocked.localizedDescription
            return
        }
        guard let operationID = beginServiceOperation() else {
            errorMessage = LegacyError.operationInProgress.localizedDescription
            return
        }
        defer { finishServiceOperation(operationID) }

        let targets = services.map {
            (id: $0.id, url: $0.url, name: $0.metadata.sourceName)
        }
        let targetsByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        var refreshed: [UUID: SecurePayload] = [:]
        var failures: [String] = []
        for target in targets {
            do {
                let metadataURL = try requireURL(target.url)
                let metadata = try JSONDecoder().decode(
                    ServiceMetadata.self,
                    from: try await boundedData(from: metadataURL, maximum: maximumMetadataBytes)
                )
                let scriptURL = try resolvedHTTPURL(metadata.scriptUrl, relativeTo: metadataURL)
                let data = try await boundedData(from: scriptURL, maximum: maximumScriptBytes)
                guard let script = String(data: data, encoding: .utf8), !script.isEmpty else { throw LegacyError.invalidScript }
                refreshed[target.id] = SecurePayload(metadata: metadata, jsScript: script, url: target.url)
            } catch { failures.append(target.name) }
        }

        // Merge fetched metadata into the current list only when the ID and URL still match the
        // request snapshot. Removals stay removed, additions remain, and current active/order state
        // wins over any changes made while network requests were suspended.
        let oldServices = services
        let oldUnresolvedRecords = unresolvedRecords
        let oldLegacyPlaintextIDs = legacyPlaintextIDs
        let oldTombstones = deletionTombstones
        let oldOrder = persistedOrder
        var keychainRollbacks: [(UUID, SecurePayload?)] = []
        for index in services.indices {
            let current = services[index]
            guard let target = targetsByID[current.id], current.url == target.url,
                  let payload = refreshed[current.id] else { continue }

            let previousPayload: SecurePayload?
            switch MacLegacyServiceKeychain.read(serviceID: current.id) {
            case .success(let value): previousPayload = value
            case .failure:
                failures.append(current.metadata.sourceName)
                continue
            }
            if previousPayload != payload {
                guard Self.securePayload(payload, serviceID: current.id) else {
                    Self.restoreKeychain(previousPayload: previousPayload, serviceID: current.id)
                    failures.append(current.metadata.sourceName)
                    continue
                }
                keychainRollbacks.append((current.id, previousPayload))
            }
            services[index] = Service(
                id: current.id,
                metadata: payload.metadata,
                jsScript: payload.jsScript,
                url: current.url,
                isActive: current.isActive,
                sortIndex: current.sortIndex
            )
            unresolvedRecords[current.id] = nil
            legacyPlaintextIDs.remove(current.id)
            deletionTombstones.remove(current.id)
        }
        guard persist() else {
            services = oldServices
            unresolvedRecords = oldUnresolvedRecords
            legacyPlaintextIDs = oldLegacyPlaintextIDs
            deletionTombstones = oldTombstones
            persistedOrder = oldOrder
            for (id, previousPayload) in keychainRollbacks {
                Self.restoreKeychain(previousPayload: previousPayload, serviceID: id)
            }
            errorMessage = LegacyError.persistenceFailed.localizedDescription
            return
        }
        if services != oldServices { serviceMutationRevision &+= 1 }
        persistSuccessfulDeletionRetries()
        let failedNames = Array(Set(failures)).sorted()
        errorMessage = failedNames.isEmpty ? nil : "Could not update: \(failedNames.joined(separator: ", "))."
    }

    func refreshInstalledServicesIfEnabled() async {
        guard UserDefaults.standard.object(forKey: "autoUpdateServicesEnabled") == nil
                || UserDefaults.standard.bool(forKey: "autoUpdateServicesEnabled") else { return }
        await updateAll()
    }

    func setActive(_ service: Service, active: Bool) {
        guard !storageWriteBlocked else {
            errorMessage = LegacyError.storageLocked.localizedDescription
            return
        }
        guard let index = services.firstIndex(where: { $0.id == service.id }) else { return }
        let previous = services[index].isActive
        services[index].isActive = active
        if !persist() {
            services[index].isActive = previous
            errorMessage = LegacyError.persistenceFailed.localizedDescription
        } else {
            serviceMutationRevision &+= 1
            persistSuccessfulDeletionRetries()
        }
    }

    func remove(_ service: Service) {
        guard !storageWriteBlocked else {
            errorMessage = LegacyError.storageLocked.localizedDescription
            return
        }
        let oldServices = services
        let oldOrder = persistedOrder
        let oldUnresolvedRecords = unresolvedRecords
        let oldLegacyPlaintextIDs = legacyPlaintextIDs
        let oldTombstones = deletionTombstones
        services.removeAll { $0.id == service.id }
        for index in services.indices { services[index].sortIndex = Int64(index) }
        persistedOrder.removeAll { $0 == service.id }
        unresolvedRecords[service.id] = nil
        legacyPlaintextIDs.remove(service.id)
        deletionTombstones.insert(service.id)
        guard persist() else {
            services = oldServices
            persistedOrder = oldOrder
            unresolvedRecords = oldUnresolvedRecords
            legacyPlaintextIDs = oldLegacyPlaintextIDs
            deletionTombstones = oldTombstones
            errorMessage = LegacyError.persistenceFailed.localizedDescription
            return
        }
        serviceMutationRevision &+= 1
        // Persist the tombstone before attempting deletion so a crash or Keychain failure cannot
        // leave a credential with no durable cleanup record.
        persistSuccessfulDeletionRetries()
    }

    func move(from source: IndexSet, to destination: Int) {
        guard !storageWriteBlocked else {
            errorMessage = LegacyError.storageLocked.localizedDescription
            return
        }
        let previous = services
        services.move(fromOffsets: source, toOffset: destination)
        for index in services.indices { services[index].sortIndex = Int64(index) }
        if !persist() {
            services = previous
            errorMessage = LegacyError.persistenceFailed.localizedDescription
        } else {
            serviceMutationRevision &+= 1
            persistSuccessfulDeletionRetries()
        }
    }

    func search(_ query: String) async -> [MacLegacySearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        var merged: [MacLegacySearchResult] = []
        let orderedServices = activeServices
        for service in orderedServices {
            let controller = JSController()
            controller.loadScript(service.jsScript, service: service)
            let items: [SearchItem] = await bridge(timeout: 15, fallback: []) { finish in
                controller.fetchJsSearchResults(keyword: trimmed, module: service, maxResults: 30, completion: finish)
            }
            merged.append(contentsOf: items.compactMap { item in
                guard !item.href.isEmpty else { return nil }
                return MacLegacySearchResult(
                    service: service,
                    title: item.title,
                    imageURL: URL(string: item.imageUrl),
                    href: item.href
                )
            })
        }
        let ranked = deduplicated(merged).enumerated().map { index, result in
            (index: index, result: result, similarity: MacServiceStreamPolicy.titleSimilarity(expected: trimmed, result: result.title))
        }
        let threshold = MacServiceStreamPolicy.minimumSimilarity()
        let visible = MacServiceStreamPolicy.dropsMismatchedResults()
            ? ranked.filter { $0.similarity >= threshold }
            : ranked
        let sourceOrder = Dictionary(uniqueKeysWithValues: orderedServices.enumerated().map { ($0.element.id, $0.offset) })
        return visible.sorted { lhs, rhs in
            let lhsSource = sourceOrder[lhs.result.service.id] ?? Int.max
            let rhsSource = sourceOrder[rhs.result.service.id] ?? Int.max
            if lhsSource != rhsSource { return lhsSource < rhsSource }
            if abs(lhs.similarity - rhs.similarity) >= 0.0001 { return lhs.similarity > rhs.similarity }
            return lhs.index < rhs.index
        }
        .prefix(300)
        .map(\.result)
    }

    func resolve(_ result: MacLegacySearchResult, media: MacMediaItem, season: Int?, episode: Int?) async -> [MacLegacyStream] {
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        let controller = JSController()
        controller.loadScript(result.service.jsScript, service: result.service)
        var extractionURL = absolute(result.href, base: result.service.metadata.baseUrl) ?? result.href

        if media.mediaType == "tv" {
            let episodes: [EpisodeLink] = await bridge(timeout: 12, fallback: []) { finish in
                controller.fetchEpisodesJS(url: extractionURL, module: result.service, completion: finish)
            }
            guard let match = episodeLink(
                in: episodes,
                result: result,
                season: season,
                episode: episode
            ) else { return [] }
            extractionURL = absolute(match.href, base: result.service.metadata.baseUrl) ?? match.href
        }

        let extracted: ServiceStreamExtractionResult = await bridge(
            timeout: 25,
            fallback: (nil, nil, nil)
        ) { finish in
            controller.fetchStreamUrlJS(
                episodeUrl: extractionURL,
                softsub: result.service.metadata.softsub ?? false,
                module: result.service,
                completion: finish
            )
        }
        var streams: [MacLegacyStream] = []
        for value in extracted.streams ?? [] {
            if let url = validatedHTTPURL(absolute(value, base: result.service.metadata.baseUrl) ?? value) {
                streams.append(.init(
                    sourceID: "service:\(result.service.id.uuidString)",
                    serviceName: result.service.metadata.sourceName,
                    title: result.title,
                    url: url,
                    headers: [:],
                    metadataText: ""
                ))
            }
        }
        for source in extracted.sources ?? [] {
            let rawURL = ["url", "file", "src", "link", "stream"].compactMap { source[$0] as? String }.first
            guard let rawURL, let url = validatedHTTPURL(absolute(rawURL, base: result.service.metadata.baseUrl) ?? rawURL) else { continue }
            let headers = Self.stringHeaders(source["headers"])
            let label = ["name", "title", "label", "quality"].compactMap { source[$0] as? String }.first ?? result.title
            streams.append(.init(
                sourceID: "service:\(result.service.id.uuidString)",
                serviceName: result.service.metadata.sourceName,
                title: label,
                url: url,
                headers: headers,
                metadataText: Self.streamMetadata(from: source)
            ))
        }
        var seen = Set<String>()
        let playable = streams.filter { seen.insert("\($0.url.absoluteString)|\($0.headers)").inserted }
        let visible = MacServiceStreamPolicy.apply(to: playable) { [$0.metadataText] }
        if visible.isEmpty, let pending = CloudflareBypassManager.shared.pendingVerificationURL {
            pendingVerificationURL = pending
            errorMessage = ServiceCompatibilityError.interactiveChallengeRequired.localizedDescription
        } else if visible.isEmpty {
            errorMessage = playable.isEmpty
                ? "\(result.service.metadata.sourceName) returned no playable HTTP streams."
                : "\(result.service.metadata.sourceName) returned streams, but none matched Extra Service Settings."
        }
        return visible
    }

    func verifyPendingChallenge() async {
        guard let url = pendingVerificationURL ?? CloudflareBypassManager.shared.pendingVerificationURL else { return }
        do {
            try await CloudflareBypassManager.shared.triggerBypass(for: url)
            pendingVerificationURL = nil
        } catch { errorMessage = "Security verification did not complete." }
    }

    @discardableResult
    private func persist() -> Bool {
        guard !storageWriteBlocked else { return false }
        synchronizePersistedOrder()

        var recordsByID = unresolvedRecords
        for service in services {
            let retainedLegacyPayload = legacyPlaintextIDs.contains(service.id)
                ? SecurePayload(service: service)
                : nil
            let order = Int64(persistedOrder.firstIndex(of: service.id) ?? persistedOrder.count)
            recordsByID[service.id] = PersistedService(
                service: service,
                sortIndex: order,
                legacyPayload: retainedLegacyPayload
            )
        }
        let records = persistedOrder.compactMap { recordsByID[$0] }
        let envelope = PersistedEnvelope(
            version: PersistedEnvelope.currentVersion,
            services: records,
            deletionTombstones: deletionTombstones.sorted { $0.uuidString < $1.uuidString }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(envelope) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return UserDefaults.standard.data(forKey: key) == data
    }

    private func synchronizePersistedOrder() {
        let loadedIDs = services.map(\.id)
        let loadedSet = Set(loadedIDs)
        var iterator = loadedIDs.makeIterator()
        persistedOrder = persistedOrder.compactMap { id in
            loadedSet.contains(id) ? iterator.next() : id
        }
        let existing = Set(persistedOrder)
        persistedOrder.append(contentsOf: loadedIDs.filter { !existing.contains($0) })
    }

    private func beginServiceOperation() -> UUID? {
        guard activeServiceOperation == nil else { return nil }
        let id = UUID()
        activeServiceOperation = id
        isWorking = true
        return id
    }

    private func finishServiceOperation(_ id: UUID) {
        guard activeServiceOperation == id else { return }
        activeServiceOperation = nil
        isWorking = false
    }

    @discardableResult
    private func retryPendingKeychainDeletions() -> Bool {
        var changed = false
        for id in Array(deletionTombstones) where MacLegacyServiceKeychain.remove(serviceID: id) {
            deletionTombstones.remove(id)
            changed = true
        }
        return changed
    }

    private func persistSuccessfulDeletionRetries() {
        if retryPendingKeychainDeletions() { _ = persist() }
    }

    private func boundedData(from url: URL, maximum: Int) async throws -> Data {
        guard maximum > 0, validatedHTTPURL(url.absoluteString) != nil else {
            throw LegacyError.invalidMetadataURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let redirectDelegate = LegacyServiceRedirectDelegate()
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: redirectDelegate)
        guard let http = response as? HTTPURLResponse,
              let finalURL = http.url,
              validatedHTTPURL(finalURL.absoluteString) != nil,
              200..<300 ~= http.statusCode else {
            throw LegacyError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let expectedLength = http.expectedContentLength
        guard expectedLength < 0 || expectedLength <= Int64(maximum) else {
            throw ServiceCompatibilityError.responseTooLarge
        }
        if let rawLength = http.value(forHTTPHeaderField: "Content-Length") {
            let trimmed = rawLength.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let declaredLength = Int64(trimmed), declaredLength >= 0 else {
                throw LegacyError.invalidResponse
            }
            guard declaredLength <= Int64(maximum) else {
                throw ServiceCompatibilityError.responseTooLarge
            }
        }

        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(min(maximum, Int(expectedLength)))
        }
        for try await byte in bytes {
            guard data.count < maximum else { throw ServiceCompatibilityError.responseTooLarge }
            data.append(byte)
        }
        return data
    }

    private func requireURL(_ value: String) throws -> URL {
        guard let url = validatedHTTPURL(value) else { throw LegacyError.invalidMetadataURL }; return url
    }
    private func validatedHTTPURL(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.fragment == nil else { return nil }
        components.scheme = scheme
        return components.url
    }
    private func resolvedHTTPURL(_ value: String, relativeTo baseURL: URL) throws -> URL {
        guard let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              let validated = validatedHTTPURL(resolved.absoluteString) else {
            throw LegacyError.invalidScriptURL
        }
        return validated
    }
    private func absolute(_ value: String, base: String) -> String? {
        guard let baseURL = validatedHTTPURL(base),
              let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              let validated = validatedHTTPURL(resolved.absoluteString) else { return nil }
        return validated.absoluteString
    }

    private static func isValidPayload(_ payload: SecurePayload) -> Bool {
        guard !payload.jsScript.isEmpty else { return false }
        guard let metadataURL = supportedHTTPURL(payload.url),
              let scriptURL = URL(string: payload.metadata.scriptUrl, relativeTo: metadataURL)?.absoluteURL,
              supportedHTTPURL(scriptURL.absoluteString) != nil else { return false }
        return true
    }

    private static func supportedHTTPURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.fragment == nil else { return nil }
        components.scheme = scheme
        return components.url
    }

    private static func securePayload(_ payload: SecurePayload, serviceID: UUID) -> Bool {
        if MacLegacyServiceKeychain.write(payload, serviceID: serviceID) {
            // A write result is not enough to discard a legacy plaintext recovery copy. Verify
            // that the exact value can be read back from Keychain first.
            if case .success(let confirmed?) = MacLegacyServiceKeychain.read(serviceID: serviceID) {
                return confirmed == payload
            }
            return false
        }
        if case .success(let confirmed?) = MacLegacyServiceKeychain.read(serviceID: serviceID) {
            return confirmed == payload
        }
        return false
    }

    private static func restoreKeychain(previousPayload: SecurePayload?, serviceID: UUID) {
        if let previousPayload {
            _ = MacLegacyServiceKeychain.write(previousPayload, serviceID: serviceID)
        } else {
            _ = MacLegacyServiceKeychain.remove(serviceID: serviceID)
        }
    }
    private func stableID(_ value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8)); var bytes = Array(digest.prefix(16)); bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private func deduplicated(_ values: [MacLegacySearchResult]) -> [MacLegacySearchResult] {
        var seen = Set<String>(); return values.filter { seen.insert("\($0.service.id)|\($0.href)").inserted }
    }

    private func episodeLink(
        in episodes: [EpisodeLink],
        result: MacLegacySearchResult,
        season: Int?,
        episode: Int?
    ) -> EpisodeLink? {
        let sourceName = result.service.metadata.sourceName
        guard let requestedSeason = season, requestedSeason >= 0,
              let requestedEpisode = episode, requestedEpisode > 0 else {
            errorMessage = "Choose an exact season and episode before resolving \(sourceName)."
            return nil
        }
        let usable = episodes.filter { $0.number > 0 && !$0.href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else {
            errorMessage = "\(sourceName) did not expose episode links for S\(requestedSeason)E\(requestedEpisode)."
            return nil
        }

        // EpisodeLink only carries number/title/href. We therefore accept a non-first
        // season only when the Service exposes an explicit season identity in its result
        // or episode URL. Guessing by array position can silently map S2E1 to S1E1.
        let resultSeason = Self.explicitSeasonNumber(in: "\(result.title) \(result.href)")
        if let resultSeason {
            guard resultSeason == requestedSeason else {
                errorMessage = "\(sourceName) returned Season \(resultSeason), not Season \(requestedSeason)."
                return nil
            }
            return exactEpisode(
                requestedEpisode,
                from: usable,
                sourceName: sourceName,
                season: requestedSeason
            )
        }

        let seasonAwareEpisodes = usable.compactMap { link -> (link: EpisodeLink, season: Int)? in
            guard let linkSeason = Self.explicitSeasonNumber(in: "\(link.title) \(link.href)") else { return nil }
            return (link, linkSeason)
        }
        if !seasonAwareEpisodes.isEmpty {
            let matchingSeason = seasonAwareEpisodes
                .filter { $0.season == requestedSeason }
                .map(\.link)
            guard !matchingSeason.isEmpty else {
                errorMessage = "\(sourceName) did not expose Season \(requestedSeason) in its episode links."
                return nil
            }
            return exactEpisode(
                requestedEpisode,
                from: matchingSeason,
                sourceName: sourceName,
                season: requestedSeason
            )
        }

        guard requestedSeason == 1 else {
            errorMessage = "\(sourceName) does not expose season identity, so Eclipse will not guess S\(requestedSeason)E\(requestedEpisode)."
            return nil
        }
        return exactEpisode(
            requestedEpisode,
            from: usable,
            sourceName: sourceName,
            season: requestedSeason
        )
    }

    private func exactEpisode(
        _ requestedEpisode: Int,
        from episodes: [EpisodeLink],
        sourceName: String,
        season: Int
    ) -> EpisodeLink? {
        let matches = episodes.filter { $0.number == requestedEpisode }
        guard matches.count == 1, let match = matches.first else {
            errorMessage = matches.isEmpty
                ? "\(sourceName) did not return S\(season)E\(requestedEpisode)."
                : "\(sourceName) returned ambiguous links for S\(season)E\(requestedEpisode)."
            return nil
        }
        return match
    }

    private static func explicitSeasonNumber(in value: String) -> Int? {
        let normalized = value.lowercased()
        if normalized.range(of: #"(?:^|[^a-z0-9])specials?(?:[^a-z0-9]|$)"#, options: .regularExpression) != nil {
            return 0
        }
        let patterns = [
            #"(?:^|[^a-z0-9])season[\s._=/\-]*(\d{1,2})(?:[^0-9]|$)"#,
            #"(?:^|[^a-z0-9])s(\d{1,2})(?:e\d{1,3})?(?:[^a-z0-9]|$)"#,
            #"(?:^|[^a-z0-9])(\d{1,2})(?:st|nd|rd|th)[\s._\-]+season(?:[^a-z0-9]|$)"#
        ]
        let fullRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: normalized, range: fullRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: normalized),
                  let season = Int(normalized[range]) else { continue }
            return season
        }
        return nil
    }

    private static func stringHeaders(_ value: Any?) -> [String: String] {
        if let headers = value as? [String: String] { return headers }
        guard let headers = value as? [String: Any] else { return [:] }
        return headers.reduce(into: [:]) { result, pair in
            if let string = pair.value as? String { result[pair.key] = string }
            else if let number = pair.value as? NSNumber { result[pair.key] = number.stringValue }
        }
    }

    private static func streamMetadata(from source: [String: Any]) -> String {
        let keys = ["name", "title", "label", "quality", "description", "language", "languages", "lang", "audio"]
        var values: [String] = []
        for key in keys {
            if let value = source[key] as? String {
                values.append(value)
            } else if let value = source[key] as? [String] {
                values.append(contentsOf: value.prefix(16))
            } else if let value = source[key] as? NSNumber {
                values.append(value.stringValue)
            }
        }
        var remaining = 8_192
        var bounded: [String] = []
        for value in values.prefix(32) where remaining > 0 {
            let trimmed = String(value.prefix(remaining)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let part = String(trimmed.prefix(remaining))
            bounded.append(part)
            remaining -= part.count
        }
        return bounded.joined(separator: " \u{2022} ")
    }

    private func bridge<Value>(timeout: TimeInterval, fallback: Value, operation: (@escaping (Value) -> Void) -> Void) async -> Value {
        await withCheckedContinuation { continuation in
            let deadline = JSCallbackDeadline<Value> { continuation.resume(returning: $0) }
            deadline.armTimeout(nanoseconds: UInt64(timeout * 1_000_000_000), value: fallback, beforeDelivery: {})
            operation { value in _ = deadline.finish(with: value) }
        }
    }

    private enum LegacyError: LocalizedError {
        case invalidMetadataURL, invalidScriptURL, invalidScript, invalidResponse, http(Int)
        case operationInProgress, serviceStateChanged, secureStorageUnavailable, storageLocked, persistenceFailed
        var errorDescription: String? {
            switch self {
            case .invalidMetadataURL: "The Service metadata URL is invalid. HTTP and HTTPS URLs without fragments are supported."
            case .invalidScriptURL: "The Service metadata contains an invalid script URL."
            case .invalidScript: "The Service script is empty or not UTF-8."
            case .invalidResponse: "The Service returned an invalid HTTP response."
            case .http(let code): "The Service request returned HTTP \(code)."
            case .operationInProgress: "Another Service install or update is already in progress."
            case .serviceStateChanged: "The Service list changed while installation was running. Try again."
            case .secureStorageUnavailable: "The Service URL and script could not be saved securely in Keychain. No changes were made."
            case .storageLocked: "Saved Service data could not be read safely. Eclipse preserved it and disabled Service changes."
            case .persistenceFailed: "The Service change could not be saved. No changes were made."
            }
        }
    }
}

private extension MacLegacyServiceStore {
    struct SecurePayload: Codable, Equatable {
        let metadata: ServiceMetadata
        let jsScript: String
        let url: String

        init(metadata: ServiceMetadata, jsScript: String, url: String) {
            self.metadata = metadata
            self.jsScript = jsScript
            self.url = url
        }

        init(service: Service) {
            self.init(metadata: service.metadata, jsScript: service.jsScript, url: service.url)
        }
    }

    struct PersistedEnvelope: Encodable {
        static let currentVersion = 2

        let version: Int
        let services: [PersistedService]
        let deletionTombstones: [UUID]
    }

    struct DecodedStoredState {
        var records: [PersistedService]
        var deletionTombstones: Set<UUID>
        var needsEnvelopeMigration: Bool
        var refusesOverwrite: Bool
    }

    /// New records keep only non-sensitive UI metadata in defaults. The legacy coding keys are
    /// retained exclusively so an existing plaintext payload survives until its exact Keychain
    /// migration has been verified.
    struct PersistedService: Codable {
        let id: UUID
        var name: String
        var isActive: Bool
        var sortIndex: Int64
        private var legacyMetadata: ServiceMetadata?
        private var legacyJSScript: String?
        private var legacyURL: String?

        enum CodingKeys: String, CodingKey {
            case id, name, isActive, sortIndex
            case legacyMetadata = "metadata"
            case legacyJSScript = "jsScript"
            case legacyURL = "url"
        }

        init(service: Service, sortIndex: Int64, legacyPayload: SecurePayload?) {
            id = service.id
            name = service.metadata.sourceName
            isActive = service.isActive
            self.sortIndex = sortIndex
            legacyMetadata = legacyPayload?.metadata
            legacyJSScript = legacyPayload?.jsScript
            legacyURL = legacyPayload?.url
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
            sortIndex = try container.decodeIfPresent(Int64.self, forKey: .sortIndex) ?? 0
            legacyMetadata = try container.decodeIfPresent(ServiceMetadata.self, forKey: .legacyMetadata)
            legacyJSScript = try container.decodeIfPresent(String.self, forKey: .legacyJSScript)
            legacyURL = try container.decodeIfPresent(String.self, forKey: .legacyURL)

            let legacyFieldCount = [legacyMetadata != nil, legacyJSScript != nil, legacyURL != nil]
                .filter { $0 }.count
            guard legacyFieldCount == 0 || legacyFieldCount == 3 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .legacyURL,
                    in: container,
                    debugDescription: "Legacy Service payload is incomplete."
                )
            }
            name = try container.decodeIfPresent(String.self, forKey: .name)
                ?? legacyMetadata?.sourceName
                ?? "Service"
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .name,
                    in: container,
                    debugDescription: "Service name is empty."
                )
            }
        }

        var legacyPayload: SecurePayload? {
            guard let legacyMetadata, let legacyJSScript, let legacyURL else { return nil }
            return SecurePayload(metadata: legacyMetadata, jsScript: legacyJSScript, url: legacyURL)
        }

        func service(payload: SecurePayload) -> Service {
            Service(
                id: id,
                metadata: payload.metadata,
                jsScript: payload.jsScript,
                url: payload.url,
                isActive: isActive,
                sortIndex: sortIndex
            )
        }
    }

    static func decodeStoredState(_ data: Data) -> DecodedStoredState {
        guard data.count <= 64_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return DecodedStoredState(records: [], deletionTombstones: [], needsEnvelopeMigration: false, refusesOverwrite: true)
        }

        let rawRecords: [Any]
        var tombstones = Set<UUID>()
        let needsMigration: Bool
        var refused = false

        if let legacyRecords = root as? [Any] {
            rawRecords = legacyRecords
            needsMigration = true
        } else if let envelope = root as? [String: Any],
                  let version = envelope["version"] as? NSNumber,
                  version.intValue == PersistedEnvelope.currentVersion,
                  let records = envelope["services"] as? [Any],
                  let rawTombstones = envelope["deletionTombstones"] as? [Any] {
            rawRecords = records
            needsMigration = false
            for raw in rawTombstones {
                guard let text = raw as? String,
                      let id = UUID(uuidString: text),
                      tombstones.insert(id).inserted else {
                    refused = true
                    continue
                }
            }
        } else {
            // Unknown versions and malformed envelopes stay untouched for a future recovery path.
            return DecodedStoredState(records: [], deletionTombstones: [], needsEnvelopeMigration: false, refusesOverwrite: true)
        }

        var decoded: [PersistedService] = []
        var seenIDs = Set<UUID>()
        for rawRecord in rawRecords {
            guard JSONSerialization.isValidJSONObject(rawRecord),
                  let recordData = try? JSONSerialization.data(withJSONObject: rawRecord),
                  let record = try? JSONDecoder().decode(PersistedService.self, from: recordData),
                  seenIDs.insert(record.id).inserted else {
                // Decode records independently so healthy entries can still be used, but lock all
                // mutations to keep the original mixed/corrupt blob byte-for-byte intact.
                refused = true
                continue
            }
            decoded.append(record)
        }

        if !tombstones.isDisjoint(with: seenIDs) {
            refused = true
        }
        return DecodedStoredState(
            records: decoded,
            deletionTombstones: tombstones,
            needsEnvelopeMigration: needsMigration,
            refusesOverwrite: refused
        )
    }
}

/// Stores the complete metadata URL, script-bearing metadata, and JavaScript outside defaults.
/// Configured Service endpoints and scripts can both embed authorization material.
private enum MacLegacyServiceKeychain {
    typealias Payload = MacLegacyServiceStore.SecurePayload

    enum ReadResult {
        case success(Payload?)
        case failure
    }

    private static let service = "app.Eclipse.Soupy.mac.legacy-services.v1"
    private static let maximumPayloadBytes = 16_000_000

    static func read(serviceID: UUID) -> ReadResult {
        var result: CFTypeRef?
        var query = baseQuery(serviceID: serviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess,
              let data = result as? Data,
              !data.isEmpty,
              data.count <= maximumPayloadBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .failure
        }
        return .success(payload)
    }

    @discardableResult
    static func write(_ payload: Payload, serviceID: UUID) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              !data.isEmpty,
              data.count <= maximumPayloadBytes else { return false }
        let query = baseQuery(serviceID: serviceID)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insertion = query
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insertion[kSecAttrLabel as String] = "Eclipse Service payload"
        return SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(serviceID: UUID) -> Bool {
        let status = SecItemDelete(baseQuery(serviceID: serviceID) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(serviceID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serviceID.uuidString
        ]
    }
}

private final class LegacyServiceRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let destination = newRequest.url,
              let components = URLComponents(url: destination, resolvingAgainstBaseURL: false),
              let destinationScheme = components.scheme?.lowercased(),
              ["http", "https"].contains(destinationScheme),
              let host = components.host, !host.isEmpty,
              components.fragment == nil else {
            completionHandler(nil)
            return
        }
        let sourceScheme = response.url?.scheme?.lowercased()
        guard !(sourceScheme == "https" && destinationScheme == "http") else {
            completionHandler(nil)
            return
        }

        var safeRequest = newRequest
        if response.url?.host?.caseInsensitiveCompare(host) != .orderedSame {
            safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
            safeRequest.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
            safeRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(safeRequest)
    }
}
