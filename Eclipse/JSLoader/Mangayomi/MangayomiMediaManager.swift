import CryptoKit
import Foundation

@MainActor
final class MangayomiMediaManager: ObservableObject {
    static let shared = MangayomiMediaManager()
    static let stateKey = "mangayomiMedia.state.v1"
    static let preferencesKey = "mangayomiMediaPreferencesV1"
    static let didChange = Notification.Name("MangayomiMediaDidChange")
    static let configurationDidChange = Notification.Name("MangayomiMediaConfigurationDidChange")

    @Published private(set) var state = MangayomiMediaState()
    @Published private(set) var storeIsReadable = true
    @Published private(set) var readySourceIDs: Set<UUID> = []
    @Published private(set) var failures: [UUID: String] = [:]
    private(set) var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var readinessTask: Task<Void, Never>?
    private var runtimePreferences: [UUID: [String: String]] = [:]

    private init() {
        reload()
        for name in [ServiceStoreScope.didChangeNotification, .activeProfileDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }

    var mediaServices: [Service] {
        guard storeIsReadable, PlatformCapabilities.current.supportsMangayomiMedia else { return [] }
        return state.installed.filter {
            !ProfileManager.shared.isKidsModeActive || !$0.isNSFW
        }.map(\.service)
    }

    func reload() {
        generation = UUID()
        runtimePreferences.removeAll()
        do {
            if let raw = ProfileSettingsStore.services.object(forKey: Self.stateKey) {
                guard let data = raw as? Data else { throw MangayomiMediaError.invalidData }
                state = try MangayomiMediaState.decode(data)
            } else {
                state = MangayomiMediaState()
            }
            storeIsReadable = true
        } catch {
            storeIsReadable = false
            state = MangayomiMediaState()
        }
        refreshReadiness()
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func stateDataForExport() throws -> Data {
        guard storeIsReadable else { throw MangayomiMediaError.invalidData }
        return try JSONEncoder().encode(state)
    }

    func restoreStateData(_ data: Data) throws {
        try requireAdministration()
        let restored = try MangayomiMediaState.decode(data)
        try commit(restored)
        failures.removeAll()
    }

    func addRepository(_ text: String) async throws {
        try requireAdministration()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = MangayomiMediaRepositoryParser.validURL(value),
              url.pathExtension.lowercased() == "json" else { throw MangayomiMediaError.invalidData }
        let authority = generation
        let scope = ServiceStoreScope.generation
        let downloaded = try await Self.download(url: url, maximumBytes: 4 * 1_024 * 1_024)
        let sources = try MangayomiMediaRepositoryParser.parse(downloaded, repositoryURL: url.absoluteString)
        try validate(authority, scope: scope)
        var updated = state
        let repository = MangayomiMediaRepository(url: url.absoluteString, sources: sources)
        if let index = updated.repositories.firstIndex(where: { $0.url == repository.url }) {
            updated.repositories[index] = repository
        } else {
            guard updated.repositories.count < 40 else { throw MangayomiMediaError.invalidData }
            updated.repositories.append(repository)
        }
        try commit(updated)
    }

    func removeRepository(_ repository: MangayomiMediaRepository) throws {
        try requireAdministration()
        var updated = state
        updated.repositories.removeAll { $0.url == repository.url }
        try commit(updated)
    }

    func refreshInstalledSources() async -> Bool {
        guard storeIsReadable, PlatformCapabilities.current.supportsMangayomiMedia,
              !ProfileManager.shared.isKidsModeActive else { return true }
        let scope = ServiceStoreScope.generation
        let owner = ProfileManager.shared.activeProfileID
        var authority = generation
        let repositories = state.repositories.map(\.url)
        for url in repositories {
            guard !Task.isCancelled, generation == authority, ServiceStoreScope.isCurrent(scope), ProfileManager.shared.activeProfileID == owner else { return false }
            do {
                try await addRepository(url)
                authority = generation
            } catch {
                guard generation == authority, ServiceStoreScope.isCurrent(scope), ProfileManager.shared.activeProfileID == owner else { return false }
            }
        }
        let installed = state.installed
        for source in installed {
            guard !Task.isCancelled, generation == authority, ServiceStoreScope.isCurrent(scope), ProfileManager.shared.activeProfileID == owner else { return false }
            guard let offered = state.repositories.flatMap(\.sources).first(where: { $0.id == source.id }),
                  offered.version != source.version || !readySourceIDs.contains(source.id) else { continue }
            do {
                try await install(offered)
                authority = generation
            } catch {
                guard generation == authority, ServiceStoreScope.isCurrent(scope), ProfileManager.shared.activeProfileID == owner else { return false }
            }
        }
        return !Task.isCancelled && generation == authority && ServiceStoreScope.isCurrent(scope) && ProfileManager.shared.activeProfileID == owner
    }

    func install(_ offered: MangayomiMediaSource) async throws {
        try requireAdministration()
        guard PlatformCapabilities.current.supportsMangayomiMedia,
              let source = state.repositories.flatMap(\.sources).first(where: { $0.id == offered.id })
                ?? state.installed.first(where: { $0.id == offered.id }),
              let url = MangayomiMediaRepositoryParser.validURL(source.scriptURL) else {
            throw MangayomiMediaError.unavailable
        }
        let authority = generation
        let scope = ServiceStoreScope.generation
        do {
            let data = try await Self.download(url: url, maximumBytes: 4 * 1_024 * 1_024)
            guard !data.isEmpty, let script = String(data: data, encoding: .utf8), !script.isEmpty else {
                throw MangayomiMediaError.invalidData
            }
            try validate(authority, scope: scope)
            var installed = source
            installed.enabled = state.installed.first(where: { $0.id == source.id })?.enabled ?? true
            installed.scriptDigest = Self.digest(data)
            _ = try await MangayomiMediaRuntime.execute(
                source: installed, script: script, operation: "validate", arguments: [:],
                preferences: try validatedPreferences()[source.id.uuidString] ?? [:],
                profileID: ProfileManager.shared.activeProfileID, sharesServices: ProfileSettingsStore.sharesServices
            )
            try validate(authority, scope: scope)
            let root = try Self.codeDirectory()
            guard let digest = installed.scriptDigest else { throw MangayomiMediaError.invalidData }
            let destination = root.appendingPathComponent(digest + ".source")
            try data.write(to: destination, options: .atomic)
            guard try Data(contentsOf: destination) == data else { throw MangayomiMediaError.invalidData }
            var updated = state
            let isNew = !updated.installed.contains { $0.id == installed.id }
            if let index = updated.installed.firstIndex(where: { $0.id == installed.id }) {
                updated.installed[index] = installed
            } else {
                updated.installed.append(installed)
            }
            try commit(updated)
            if isNew { AutoModeSourceSelection.enrollSourceOnFirstAvailability(installed.sourceID) }
            failures.removeValue(forKey: installed.id)
            refreshReadiness(preserveKnownReady: true)
        } catch {
            if generation == authority, ServiceStoreScope.isCurrent(scope) {
                failures[source.id] = error.localizedDescription
            }
            throw error
        }
    }

    func setEnabled(_ enabled: Bool, id: UUID) throws {
        try requireAdministration()
        var updated = state
        guard let index = updated.installed.firstIndex(where: { $0.id == id }) else { return }
        updated.installed[index].enabled = enabled
        try commit(updated)
    }

    func remove(id: UUID) throws {
        try requireAdministration()
        var updated = state
        guard let source = updated.installed.first(where: { $0.id == id }) else { return }
        updated.installed.removeAll { $0.id == id }
        try commit(updated)
        AutoModeSourceSelection.removeSourceAuthoritatively(source.sourceID)
        SourceHealthStore.shared.removeRecord(sourceId: source.sourceID)
        runtimePreferences.removeValue(forKey: id)
        failures.removeValue(forKey: id)
    }

    func preferences(for id: UUID) -> [String: Any] {
        (try? validatedPreferences()[id.uuidString]) ?? [:]
    }

    private func validatedPreferences() throws -> [String: [String: Any]] {
        guard let raw = ProfileSettingsStore.active.object(forKey: Self.preferencesKey) else { return [:] }
        guard let data = raw as? Data else { throw MangayomiMediaError.invalidData }
        let validated = try MangayomiMediaPreferencePolicy.validatedData(data)
        guard let values = try JSONSerialization.jsonObject(with: validated) as? [String: [String: Any]] else {
            throw MangayomiMediaError.invalidData
        }
        return values
    }

    func setPreference(_ value: Any, key: String, sourceID: UUID) throws {
        try requireAdministration()
        guard key.utf8.count <= 256, !key.isEmpty,
              state.installed.contains(where: { $0.id == sourceID }),
              JSONSerialization.isValidJSONObject(["value": value]) else { throw MangayomiMediaError.invalidData }
        var values = try validatedPreferences()
        values[sourceID.uuidString, default: [:]][key] = value
        let data = try MangayomiMediaPreferencePolicy.validatedData(
            JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        )
        let defaults = ProfileSettingsStore.active
        let previous = defaults.object(forKey: Self.preferencesKey)
        defaults.set(data, forKey: Self.preferencesKey)
        guard defaults.synchronize(), defaults.data(forKey: Self.preferencesKey) == data else {
            if let previous { defaults.set(previous, forKey: Self.preferencesKey) }
            else { defaults.removeObject(forKey: Self.preferencesKey) }
            _ = defaults.synchronize()
            throw MangayomiMediaError.invalidData
        }
        generation = UUID()
        runtimePreferences.removeValue(forKey: sourceID)
        refreshReadiness(preserveKnownReady: true)
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func execute(source: MangayomiMediaSource, operation: String, arguments: [String: Any]) async throws -> Data {
        if operation == "preferences" { try requireAdministration() }
        guard storeIsReadable, PlatformCapabilities.current.supportsMangayomiMedia,
              let installed = state.installed.first(where: { $0.id == source.id }),
              (installed.enabled || operation == "preferences"), installed == source,
              !ProfileManager.shared.isKidsModeActive || !installed.isNSFW,
              let digest = installed.scriptDigest else { throw MangayomiMediaError.unavailable }
        let authority = generation
        let scope = ServiceStoreScope.generation
        let owner = ProfileManager.shared.activeProfileID
        let savedPreferences = try validatedPreferences()[source.id.uuidString] ?? [:]
        var preferences = savedPreferences
        for (key, value) in runtimePreferences[source.id] ?? [:] { preferences[key] = value }
        let scriptURL = try Self.codeDirectory().appendingPathComponent(digest + ".source")
        let script: String
        do {
            script = try await Task.detached(priority: .userInitiated) {
                let values = try scriptURL.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size > 0, size <= 4 * 1_024 * 1_024 else { throw MangayomiMediaError.invalidData }
                let data = try Data(contentsOf: scriptURL)
                guard Self.digest(data) == digest, let text = String(data: data, encoding: .utf8) else {
                    throw MangayomiMediaError.invalidData
                }
                return text
            }.value
        } catch {
            if generation == authority, ServiceStoreScope.isCurrent(scope) {
                readySourceIDs.remove(source.id)
                failures[source.id] = "The installed source code is missing or invalid. Repair this source to try again."
                generation = UUID()
                refreshReadiness(preserveKnownReady: true)
                NotificationCenter.default.post(name: Self.configurationDidChange, object: self)
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
            throw error
        }
        try validate(authority, scope: scope)
        let result = try await MangayomiMediaRuntime.executeWithPreferences(
            source: installed, script: script, operation: operation,
            arguments: arguments, preferences: preferences,
            profileID: owner, sharesServices: ProfileSettingsStore.sharesServices,
            configurationPreferences: savedPreferences
        )
        try validate(authority, scope: scope)
        guard ProfileManager.shared.activeProfileID == owner else { throw MangayomiMediaError.stale }
        var runtimeValues = runtimePreferences[source.id] ?? [:]
        for (key, value) in result.preferenceWrites { runtimeValues[key] = value }
        guard runtimeValues.count <= 128,
              runtimeValues.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 1_024 * 1_024 else {
            throw MangayomiMediaError.invalidData
        }
        if runtimePreferences[source.id] != nil || runtimePreferences.count < 128 {
            runtimePreferences[source.id] = runtimeValues
        }
        return result.data
    }

    private func requireAdministration() throws {
        guard !ProfileManager.shared.isKidsModeActive else { throw MangayomiMediaError.administrativeAccess }
        guard storeIsReadable else { throw MangayomiMediaError.invalidData }
    }

    private func validate(_ authority: UUID, scope: Int) throws {
        try Task.checkCancellation()
        guard generation == authority, ServiceStoreScope.isCurrent(scope) else { throw MangayomiMediaError.stale }
    }

    private func commit(_ candidate: MangayomiMediaState) throws {
        guard candidate != state else { return }
        let data = try JSONEncoder().encode(candidate)
        _ = try MangayomiMediaState.decode(data)
        let defaults = ProfileSettingsStore.services
        let previous = defaults.object(forKey: Self.stateKey)
        defaults.set(data, forKey: Self.stateKey)
        guard defaults.synchronize(), defaults.data(forKey: Self.stateKey) == data else {
            if let previous { defaults.set(previous, forKey: Self.stateKey) }
            else { defaults.removeObject(forKey: Self.stateKey) }
            _ = defaults.synchronize()
            throw MangayomiMediaError.invalidData
        }
        let unchangedCodeIDs = Set(candidate.installed.filter { source in
            state.installed.contains { $0.id == source.id && $0.scriptDigest == source.scriptDigest }
        }.map(\.id))
        let unchangedSourceIDs = Set(candidate.installed.filter { source in
            state.installed.contains(source)
        }.map(\.id))
        runtimePreferences = runtimePreferences.filter { unchangedSourceIDs.contains($0.key) }
        readySourceIDs.formIntersection(unchangedCodeIDs)
        state = candidate
        generation = UUID()
        refreshReadiness(preserveKnownReady: true)
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func refreshReadiness(preserveKnownReady: Bool = false) {
        readinessTask?.cancel()
        if !preserveKnownReady { readySourceIDs = [] }
        let installed = state.installed
        let authority = generation
        guard let root = try? Self.codeDirectory() else { return }
        readinessTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                var checked: [String: Bool] = [:]
                var ready: Set<UUID> = []
                for source in installed {
                    guard !Task.isCancelled else { return Set<UUID>() }
                    guard let digest = source.scriptDigest else { continue }
                    let valid: Bool
                    if let cached = checked[digest] {
                        valid = cached
                    } else {
                        let file = root.appendingPathComponent(digest + ".source")
                        let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                        if let size, size > 0, size <= 4 * 1_024 * 1_024,
                           let data = try? Data(contentsOf: file), Self.digest(data) == digest,
                           String(data: data, encoding: .utf8) != nil {
                            valid = true
                        } else {
                            valid = false
                        }
                        checked[digest] = valid
                    }
                    if valid { ready.insert(source.id) }
                }
                return ready
            }
            let ready = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.generation == authority else { return }
            self.readySourceIDs = ready
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func codeDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MangayomiMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    nonisolated private static func download(url: URL, maximumBytes: Int) async throws -> Data {
        let validated = try await SkyStreamRemoteURLPolicy.shared.validateForNetworkDispatch(
            url.absoluteString, purpose: .nuvioRequest
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: FetchDelegate(
            allowRedirects: true,
            redirectAuthorization: { source, destination in
                guard MangayomiMediaRepositoryParser.validURL(destination.absoluteString) != nil else {
                    throw MangayomiMediaError.invalidData
                }
                _ = try await SkyStreamRemoteURLPolicy.shared.validateRedirectForNetworkDispatch(
                    from: source, to: destination, purpose: .nuvioRequest
                )
            }
        ), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.boundedData(for: URLRequest(url: validated.url), maximumResponseBytes: maximumBytes)
        guard let response = response as? HTTPURLResponse else { throw MangayomiMediaError.invalidData }
        guard (200...299).contains(response.statusCode) else { throw MangayomiMediaError.network(response.statusCode) }
        guard let delivered = response.url, MangayomiMediaRepositoryParser.validURL(delivered.absoluteString) != nil else {
            throw MangayomiMediaError.invalidData
        }
        return data
    }
}
