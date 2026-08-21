import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class NuvioPluginManager: ObservableObject {
    static let shared = NuvioPluginManager()

    @Published private(set) var state = NuvioStoredPluginsState()
    @Published private(set) var isLoaded = false
    @Published private(set) var installProgress: NuvioInstallProgress?

    private var installingRepositoryIDs: Set<String> = []
    private var missingCodeRepairTask: Task<Void, Never>?
    private var missingCodeRepairGeneration = 0

    private var pendingSettingsWrite: (state: NuvioStoredPluginsState, destination: NuvioPluginStore.Destination)?
    private var pendingSettingsWriteTask: Task<Void, Never>?

    private let store: NuvioPluginStore
    private let maxStreamsPerScraper = 40
    private let maxConcurrentDownloads = 6
    private let manifestTimeout: TimeInterval = 10
    private let codeTimeout: TimeInterval = 15
    private let maxCodeBytes = 8 * 1_024 * 1_024

    private let maxManifestProviders = 200

    private let maxAutomaticMissingCodeRepairs = 12
    private let missingCodeRepairCursorKey = "nuvioMissingCodeRepairCursor.v1"

    private let settingsWriteDelayNanoseconds: UInt64 = 400_000_000

    nonisolated static var isFeatureAvailable: Bool {
        PlatformCapabilities.current.supportsNuvioPlugins
    }

    var repositories: [NuvioPluginRepository] {
        state.repositories.sorted { lhs, rhs in
            lhs.sortIndex == rhs.sortIndex
                ? lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                : lhs.sortIndex < rhs.sortIndex
        }
    }

    var enabledRepositories: [NuvioPluginRepository] {
        guard Self.isFeatureAvailable, state.pluginsEnabled else { return [] }
        return repositories.filter { $0.isEnabled && scraperCount(forRepository: $0.id, runnableOnly: true) > 0 }
    }

    var scrapers: [NuvioPluginScraper] { state.scrapers }

    var activeScrapers: [NuvioPluginScraper] {
        guard Self.isFeatureAvailable, state.pluginsEnabled else { return [] }
        let enabledRepositoryIDs = Set(
            state.repositories.filter(\.isEnabled).map(\.id)
        )

        let repositoryOrder = repositories.enumerated().reduce(into: [String: Int]()) { result, entry in
            if result[entry.element.id] == nil {
                result[entry.element.id] = entry.offset
            }
        }
        return state.scrapers
            .filter { $0.isRunnable && enabledRepositoryIDs.contains($0.repositoryId) }
            .sorted { lhs, rhs in
                let lhsRank = repositoryOrder[lhs.repositoryId] ?? Int.max
                let rhsRank = repositoryOrder[rhs.repositoryId] ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    func scraper(withID scraperID: String) -> NuvioPluginScraper? {
        state.scrapers.first { $0.id == scraperID }
    }

    init(store: NuvioPluginStore = .shared) {
        self.store = store
        load()

        NotificationCenter.default.addObserver(
            forName: ServiceStoreScope.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.load()
                self?.scheduleMissingCodeRepair(reason: "services-scope-change")
            }
        }
#if canImport(UIKit)

        for name in [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification
        ] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                MainActor.assumeIsolated {
                    self?.flushPendingSettingsWrite()
                }
            }
        }
#endif
        scheduleMissingCodeRepair(reason: "launch")
    }

    func load() {

        flushPendingSettingsWrite()
        guard Self.isFeatureAvailable else {
            state = NuvioStoredPluginsState(pluginsEnabled: false)
            isLoaded = true
            return
        }
        store.purgeLegacyState()
        state = store.load()
        isLoaded = true
    }

    @discardableResult
    func reloadPersistedStateAfterRestore(
        expectedScopeGeneration: Int? = nil
    ) async -> Bool {
        guard expectedScopeGeneration.map(ServiceStoreScope.isCurrent) ?? true else {
            return false
        }
        missingCodeRepairTask?.cancel()
        missingCodeRepairTask = nil
        missingCodeRepairGeneration &+= 1

        cancelPendingSettingsWrite()
        load()
        _ = await repairMissingCodeAfterRestore(reason: "backup-restore-reload")
        return expectedScopeGeneration.map(ServiceStoreScope.isCurrent) ?? true
    }

    @discardableResult
    func repairMissingCodeAfterRestore(reason: String = "backup-restore") async -> Bool {
        guard Self.isFeatureAvailable else { return false }
        let scopeEpoch = ServiceStoreScope.generation
        missingCodeRepairGeneration &+= 1
        let repairGeneration = missingCodeRepairGeneration
        let defaults = ProfileSettingsStore.services
        var attemptedAny = false

        guard !Task.isCancelled,
              ServiceStoreScope.isCurrent(scopeEpoch),
              missingCodeRepairGeneration == repairGeneration else {
            return false
        }
        let scrapersByRepository = Dictionary(grouping: state.scrapers, by: \.repositoryId)
        let missingRepositoryIDs = state.repositories.compactMap { repository -> String? in
            let installed = scrapersByRepository[repository.id] ?? []
            guard installed.isEmpty || installed.contains(where: {
                !store.hasCode(repositoryID: repository.id, codeFileName: $0.codeFileName)
            }) else { return nil }
            return repository.id
        }
        guard !missingRepositoryIDs.isEmpty else { return false }

        let cursor = defaults.string(forKey: missingCodeRepairCursorKey)
        let rotated: [String]
        if let cursor,
           let cursorIndex = missingRepositoryIDs.firstIndex(of: cursor) {
            let start = missingRepositoryIDs.index(after: cursorIndex)
            rotated = Array(missingRepositoryIDs[start...])
                + Array(missingRepositoryIDs[..<start])
        } else {
            rotated = missingRepositoryIDs
        }
        let batch = Array(rotated.prefix(maxAutomaticMissingCodeRepairs))
        Logger.shared.log(
            "Nuvio repairing missing restored code reason=\(reason) repositories=\(batch.count)",
            type: "Plugin"
        )
        for repositoryID in batch {
            guard !Task.isCancelled,
                  ServiceStoreScope.isCurrent(scopeEpoch),
                  missingCodeRepairGeneration == repairGeneration else {
                return attemptedAny
            }
            attemptedAny = true

            defaults.set(repositoryID, forKey: missingCodeRepairCursorKey)
            await refreshRepository(repositoryID)
        }
        return attemptedAny
    }

    private func scheduleMissingCodeRepair(reason: String) {
        missingCodeRepairTask?.cancel()
        missingCodeRepairTask = Task { @MainActor [weak self] in

            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            _ = await self.repairMissingCodeAfterRestore(reason: reason)
        }
    }

    private func persist() {

        cancelPendingSettingsWrite()
        store.save(state)
    }

    private func persistSettingsSoon() {
        pendingSettingsWriteTask?.cancel()
        pendingSettingsWrite = (state, store.currentDestination())
        let delay = settingsWriteDelayNanoseconds
        pendingSettingsWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.flushPendingSettingsWrite()
        }
    }

    func flushPendingSettingsWrite() {
        pendingSettingsWriteTask?.cancel()
        pendingSettingsWriteTask = nil
        guard let pending = pendingSettingsWrite else { return }
        pendingSettingsWrite = nil
        store.save(pending.state, to: pending.destination)
    }

    private func cancelPendingSettingsWrite() {
        pendingSettingsWriteTask?.cancel()
        pendingSettingsWriteTask = nil
        pendingSettingsWrite = nil
    }

    func scrapers(forRepository repositoryID: String) -> [NuvioPluginScraper] {
        state.scrapers
            .filter { $0.repositoryId == repositoryID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func scraperCount(forRepository repositoryID: String, runnableOnly: Bool) -> Int {
        state.scrapers.filter {
            $0.repositoryId == repositoryID && (!runnableOnly || $0.isRunnable)
        }.count
    }

    func repository(withID repositoryID: String) -> NuvioPluginRepository? {
        state.repositories.first { $0.id == repositoryID }
    }

    func setPluginsEnabled(_ enabled: Bool) {
        guard Self.isFeatureAvailable else { return }
        state.pluginsEnabled = enabled
        persist()
    }

    func setRepositoryEnabled(_ repositoryID: String, enabled: Bool) {
        guard Self.isFeatureAvailable else { return }
        guard let index = state.repositories.firstIndex(where: { $0.id == repositoryID }) else { return }
        if enabled { state.pluginsEnabled = true }
        state.repositories[index].isEnabled = enabled
        persist()
    }

    func setScraperEnabled(_ scraperID: String, enabled: Bool) {
        guard Self.isFeatureAvailable else { return }
        state.scrapers = state.scrapers.map { scraper in
            guard scraper.id == scraperID else { return scraper }
            var copy = scraper
            copy.enabled = scraper.manifestEnabled && enabled
            return copy
        }
        persist()
        if enabled {
            AutoModeSourceSelection.appendSourceToOrderIfNeeded(scraperID)
        }
    }

    func setAllScrapersEnabled(_ enabled: Bool, inRepository repositoryID: String) {
        guard Self.isFeatureAvailable else { return }
        state.scrapers = state.scrapers.map { scraper in
            guard scraper.repositoryId == repositoryID else { return scraper }
            var copy = scraper
            copy.enabled = scraper.manifestEnabled && enabled
            return copy
        }
        persist()
        guard enabled else { return }
        for scraper in scrapers(forRepository: repositoryID) where scraper.isRunnable {
            AutoModeSourceSelection.appendSourceToOrderIfNeeded(scraper.id)
        }
    }

    func addRepository(rawURL: String) async throws {
        guard Self.isFeatureAvailable else { throw NuvioPluginError.unavailable }
        let scopeEpoch = ServiceStoreScope.generation

        let owningProfile = ProfileManager.shared.activeProfileID
        let manifestURL = try NuvioPluginSupport.normalizeManifestURL(rawURL)
        let repositoryID = NuvioPluginSupport.repositoryID(forManifestURL: manifestURL)
        guard !state.repositories.contains(where: { $0.id == repositoryID }) else {
            throw NuvioPluginError.duplicateRepository
        }

        guard !installingRepositoryIDs.contains(repositoryID) else {
            throw NuvioPluginError.duplicateRepository
        }
        installingRepositoryIDs.insert(repositoryID)
        defer { installingRepositoryIDs.remove(repositoryID) }

        installProgress = NuvioInstallProgress(label: "Reading manifest", completed: 0, total: 0)
        defer { installProgress = nil }

        do {
            let fetched = try await fetchRepository(
                manifestURL: manifestURL,
                repositoryID: repositoryID,
                sortIndex: Int64(state.repositories.count),
                previousScrapers: [:]
            )

            guard ServiceStoreScope.isCurrent(scopeEpoch) else {
                store.removeRepositoryCode(repositoryID: repositoryID, ownedBy: owningProfile)
                throw NuvioPluginError.repositoryInstallFailed(
                    "The active profile changed while this repository was installing."
                )
            }
            state.repositories.append(fetched.repository)
            state.scrapers.removeAll { $0.repositoryId == repositoryID }
            state.scrapers.append(contentsOf: fetched.scrapers)
            persist()
            for scraper in fetched.scrapers where scraper.isRunnable {
                AutoModeSourceSelection.appendSourceToOrderIfNeeded(scraper.id)
            }
        } catch let error as NuvioPluginError {
            store.removeRepositoryCode(repositoryID: repositoryID, ownedBy: owningProfile)
            throw error
        } catch {
            store.removeRepositoryCode(repositoryID: repositoryID, ownedBy: owningProfile)
            throw NuvioPluginError.repositoryInstallFailed(error.localizedDescription)
        }
    }

    func refreshRepository(_ repositoryID: String) async {
        let scopeEpoch = ServiceStoreScope.generation

        let owningProfile = ProfileManager.shared.activeProfileID
        guard Self.isFeatureAvailable,
              let existing = state.repositories.first(where: { $0.id == repositoryID }) else { return }

        setRefreshing(repositoryID, isRefreshing: true, error: nil)
        installProgress = NuvioInstallProgress(label: "Refreshing \(existing.displayName)", completed: 0, total: 0)
        defer {
            installProgress = nil
            setRefreshing(repositoryID, isRefreshing: false, error: nil, preserveExistingError: true)
        }

        do {
            let previous = Dictionary(
                state.scrapers.filter { $0.repositoryId == repositoryID }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let fetched = try await fetchRepository(
                manifestURL: existing.manifestUrl,
                repositoryID: repositoryID,
                sortIndex: existing.sortIndex,
                previousScrapers: previous
            )
            guard ServiceStoreScope.isCurrent(scopeEpoch) else {

                store.pruneCode(
                    repositoryID: repositoryID,
                    keeping: Set(previous.values.map(\.codeFileName)),
                    ownedBy: owningProfile
                )
                return
            }
            var refreshed = fetched.repository
            refreshed.isEnabled = existing.isEnabled
            state.repositories = state.repositories.map { $0.id == repositoryID ? refreshed : $0 }
            state.scrapers.removeAll { $0.repositoryId == repositoryID }
            state.scrapers.append(contentsOf: fetched.scrapers)
            state.scraperSettings = state.scraperSettings.filter { key, _ in
                state.scrapers.contains { $0.id == key }
            }
            persist()

            let removedScraperIDs = Set(previous.keys)
                .subtracting(fetched.scrapers.map(\.id))
                .subtracting(fetched.carriedOverScraperIDs)
            for removedID in removedScraperIDs {
                AutoModeSourceSelection.removeSourceAuthoritatively(removedID)
            }
            for scraper in fetched.scrapers where scraper.isRunnable {
                AutoModeSourceSelection.appendSourceToOrderIfNeeded(scraper.id)
            }

            store.pruneCode(
                repositoryID: repositoryID,
                keeping: Set(fetched.scrapers.map(\.codeFileName))
            )
        } catch {
            setRefreshing(repositoryID, isRefreshing: false, error: error.localizedDescription)
        }
    }

    func refreshRepositoriesAndInstalledPlugins(autoUpdate: Bool) async {
        guard Self.isFeatureAvailable, autoUpdate else { return }
        for repository in state.repositories {
            await refreshRepository(repository.id)
        }
    }

    func uninstall(repositoryID: String) {
        guard Self.isFeatureAvailable else { return }
        state.repositories.removeAll { $0.id == repositoryID }
        let removedScraperIDs = Set(
            state.scrapers.filter { $0.repositoryId == repositoryID }.map(\.id)
        )
        state.scrapers.removeAll { $0.repositoryId == repositoryID }
        state.scraperSettings = state.scraperSettings.filter { !removedScraperIDs.contains($0.key) }
        persist()
        store.removeRepositoryCode(repositoryID: repositoryID)
        AutoModeSourceSelection.removeSourceAuthoritatively(repositoryID)

        SourceHealthStore.shared.removeRecord(sourceId: repositoryID)
        for scraperID in removedScraperIDs {
            AutoModeSourceSelection.removeSourceAuthoritatively(scraperID)
            SourceHealthStore.shared.removeRecord(sourceId: scraperID)
        }
    }

    private func setRefreshing(
        _ repositoryID: String,
        isRefreshing: Bool,
        error: String?,
        preserveExistingError: Bool = false
    ) {
        state.repositories = state.repositories.map { repository in
            guard repository.id == repositoryID else { return repository }
            var copy = repository
            copy.isRefreshing = isRefreshing
            if !preserveExistingError || error != nil {
                copy.errorMessage = error
            }
            return copy
        }
    }

    private func fetchRepository(
        manifestURL: String,
        repositoryID: String,
        sortIndex: Int64,
        previousScrapers: [String: NuvioPluginScraper]
    ) async throws -> NuvioRepositoryFetch {
        let manifestPayload = try await downloadText(from: manifestURL, timeout: manifestTimeout, kind: "manifest")
        let manifest = try parseManifest(manifestPayload)

        let candidates = manifest.scrapers.filter(isSupportedOnCurrentPlatform)
        guard !candidates.isEmpty else { throw NuvioPluginError.manifestHasNoProviders }

        installProgress = NuvioInstallProgress(
            label: "Downloading providers",
            completed: 0,
            total: candidates.count
        )

        var downloaded: [String: String] = [:]
        var completed = 0
        await BoundedProgressiveFanout.run(
            inputs: candidates,
            maxConcurrent: maxConcurrentDownloads,
            operation: { [manifestURL, codeTimeout, maxCodeBytes] info -> String? in
                let url = NuvioPluginSupport.codeURL(manifestURL: manifestURL, filename: info.filename)
                return try? await Self.downloadText(
                    from: url,
                    timeout: codeTimeout,
                    kind: "provider",
                    maximumBytes: maxCodeBytes
                )
            },
            isCurrent: { true },
            onResult: { info, code in
                completed += 1
                self.installProgress = NuvioInstallProgress(
                    label: "Downloading providers",
                    completed: completed,
                    total: candidates.count
                )
                guard let code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    Logger.shared.log("Nuvio provider download failed provider=\(info.id)", type: "Plugin")
                    return
                }
                downloaded[info.id] = code
            }
        )

        var scrapers: [NuvioPluginScraper] = []
        var carriedOver: Set<String> = []
        for info in candidates {
            let scraperID = NuvioPluginSupport.scraperSourceID(
                manifestURL: manifestURL,
                providerKey: info.id
            )

            var writtenCodeFileName: String?
            if let code = downloaded[info.id] {
                do {
                    writtenCodeFileName = try store.writeCode(
                        code,
                        repositoryID: repositoryID,
                        scraperID: scraperID
                    )
                } catch {
                    Logger.shared.log("Nuvio provider write failed provider=\(info.id): \(error.localizedDescription)", type: "Plugin")
                }
            }

            guard let codeFileName = writtenCodeFileName else {

                if let previous = previousScrapers[scraperID] {
                    scrapers.append(previous)
                    carriedOver.insert(scraperID)
                    Logger.shared.log(
                        "Nuvio provider kept after failed download provider=\(info.id)",
                        type: "Plugin"
                    )
                }
                continue
            }

            let userEnabled = previousScrapers[scraperID]?.enabled ?? true
            scrapers.append(NuvioPluginScraper(
                id: scraperID,
                providerKey: info.id,
                repositoryId: repositoryID,
                repositoryUrl: manifestURL,
                name: info.name,
                description: info.description ?? "",
                author: info.author,
                version: info.version,
                filename: info.filename,
                codeFileName: codeFileName,
                supportedTypes: info.supportedTypes,
                enabled: info.enabled && userEnabled,
                manifestEnabled: info.enabled,
                declaresSettings: info.hasSettings,
                logo: info.logo,
                contentLanguage: info.contentLanguage ?? [],
                formats: info.formats ?? info.supportedFormats
            ))
        }

        guard scrapers.count > carriedOver.count else {
            throw NuvioPluginError.repositoryInstallFailed("No providers could be downloaded from that repository.")
        }

        let repository = NuvioPluginRepository(
            id: repositoryID,
            manifestUrl: manifestURL,
            name: manifest.name,
            description: manifest.description,
            version: manifest.version,
            scraperCount: scrapers.count,
            lastUpdated: Date().timeIntervalSince1970,
            sortIndex: sortIndex
        )
        return NuvioRepositoryFetch(
            repository: repository,
            scrapers: scrapers,
            carriedOverScraperIDs: carriedOver
        )
    }

    private func parseManifest(_ payload: String) throws -> NuvioPluginManifest {
        guard let data = payload.data(using: .utf8) else { throw NuvioPluginError.invalidResponse }
        let manifest: NuvioPluginManifest
        do {
            manifest = try JSONDecoder().decode(NuvioPluginManifest.self, from: data)
        } catch {
            throw NuvioPluginError.repositoryInstallFailed("That URL did not return a Nuvio plugin manifest.")
        }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NuvioPluginError.manifestNameMissing
        }
        guard !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NuvioPluginError.manifestVersionMissing
        }
        guard !manifest.scrapers.isEmpty else { throw NuvioPluginError.manifestHasNoProviders }

        var seenProviderIDs = Set<String>()
        var bounded: [NuvioPluginManifestScraper] = []
        var rejected = 0
        for scraper in manifest.scrapers {
            guard bounded.count < maxManifestProviders else {
                rejected += 1
                continue
            }
            let trimmedID = scraper.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty, seenProviderIDs.insert(trimmedID).inserted else {
                rejected += 1
                continue
            }
            bounded.append(scraper)
        }
        if rejected > 0 {
            Logger.shared.log(
                "Nuvio manifest '\(manifest.name)': dropped \(rejected) provider(s) with a blank, duplicate, or over-limit id",
                type: "Plugin"
            )
        }
        guard !bounded.isEmpty else { throw NuvioPluginError.manifestHasNoProviders }

        var validated = manifest
        validated.scrapers = bounded
        return validated
    }

    private func isSupportedOnCurrentPlatform(_ info: NuvioPluginManifestScraper) -> Bool {
        let disabled = (info.disabledPlatforms ?? []).map { $0.lowercased() }
        if disabled.contains("ios") || disabled.contains("apple") { return false }
        guard let supported = info.supportedPlatforms, !supported.isEmpty else { return true }
        let normalized = supported.map { $0.lowercased() }
        return normalized.contains("ios") || normalized.contains("all") || normalized.contains("apple")
    }

    nonisolated private static func downloadText(
        from urlString: String,
        timeout: TimeInterval,
        kind: String,
        maximumBytes: Int = 4 * 1_024 * 1_024
    ) async throws -> String {
        guard let url = ServiceSandboxState.validatedHTTPURL(urlString) else {
            throw NuvioPluginError.invalidRepositoryURL
        }
        guard !ServiceSandboxState.isBlockedTrackingURL(url.absoluteString) else {
            throw NuvioPluginError.repositoryInstallFailed("That endpoint is blocked.")
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query = components?.queryItems ?? []
        query.append(URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        components?.queryItems = query
        let requestURL = components?.url ?? url

        let validated: SkyStreamValidatedRemoteURL
        do {
            validated = try await SkyStreamRemoteURLPolicy.shared.validateForNetworkDispatch(
                requestURL.absoluteString,
                purpose: .nuvioRepository
            )
        } catch SkyStreamSecurityError.insecureTransport {
            throw NuvioPluginError.repositoryInstallFailed(
                "Plugin repositories must use https. This \(kind) URL uses plain http, which would let anyone on the network replace the code Eclipse runs."
            )
        } catch {
            throw NuvioPluginError.repositoryInstallFailed(
                "The \(kind) URL was refused: \(error.localizedDescription)"
            )
        }

        var request = URLRequest(url: validated.url)
        request.timeoutInterval = timeout
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let session = NuvioIsolatedNetworking.makeSession(allowRedirects: true) { source, destination in
            _ = try await SkyStreamRemoteURLPolicy.shared.validateRedirectForNetworkDispatch(
                from: source,
                to: destination,
                purpose: .nuvioRepository
            )
        }
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.boundedData(
            for: request,
            maximumResponseBytes: maximumBytes
        )
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NuvioPluginError.repositoryInstallFailed("The \(kind) request failed with status \(http.statusCode).")
        }
        guard !data.isEmpty else {
            throw NuvioPluginError.repositoryInstallFailed("The \(kind) response was empty.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func downloadText(from urlString: String, timeout: TimeInterval, kind: String) async throws -> String {
        try await Self.downloadText(from: urlString, timeout: timeout, kind: kind)
    }

    func resolveStreams(
        scraperID: String,
        tmdbId: String,
        mediaType: String,
        season: Int?,
        episode: Int?
    ) async -> [NuvioPluginStream] {
        await resolveOutcome(
            scraperID: scraperID,
            tmdbId: tmdbId,
            mediaType: mediaType,
            season: season,
            episode: episode
        ).streams
    }

    func resolveOutcome(
        scraperID: String,
        tmdbId: String,
        mediaType: String,
        season: Int?,
        episode: Int?
    ) async -> NuvioProviderOutcome {

        if mediaType != "movie", season == nil || episode == nil {
            Logger.shared.log(
                "Nuvio lookup refused for TMDB \(tmdbId): no resolved season/episode coordinate, "
                    + "and omitting it makes providers default to S1E1",
                type: "Plugin"
            )
            return NuvioProviderOutcome.unresolvedCoordinate
        }
        let outcome = await computeOutcome(
            scraperID: scraperID,
            tmdbId: tmdbId,
            mediaType: mediaType,
            season: season,
            episode: episode
        )
        let vetted = await Self.withPublicStreamsOnly(outcome)
        let name = scraper(withID: scraperID)?.displayName ?? scraperID
        Logger.shared.log(
            "Nuvio outcome provider=\(name) result=\(vetted.diagnosticToken) "
                + "streams=\(vetted.streams.count) blame=\(vetted.blame) "
                + "detail=\(vetted.displayMessage)",
            type: "Plugin"
        )
        return vetted
    }

    private static func withPublicStreamsOnly(
        _ outcome: NuvioProviderOutcome
    ) async -> NuvioProviderOutcome {
        guard case .results(let streams) = outcome, !streams.isEmpty else { return outcome }
        let policy = SkyStreamRemoteURLPolicy.shared

        var requests = streams.map {
            SkyStreamRemoteURLValidationRequest(rawValue: $0.url, purpose: .streamRoot)
        }
        requests.append(contentsOf: streams.flatMap { stream in
            (stream.subtitles ?? []).map {
                SkyStreamRemoteURLValidationRequest(rawValue: $0.url, purpose: .subtitle)
            }
        })
        if (try? await policy.validate(requests)) != nil {
            return outcome
        }

        var allowed: [NuvioPluginStream] = []
        allowed.reserveCapacity(streams.count)
        var rejectedSubtitles = 0
        for stream in streams {
            guard (try? await policy.validate(stream.url, purpose: .streamRoot)) != nil else { continue }
            guard let subtitles = stream.subtitles, !subtitles.isEmpty else {
                allowed.append(stream)
                continue
            }
            var allowedSubtitles: [NuvioPluginSubtitle] = []
            allowedSubtitles.reserveCapacity(subtitles.count)
            for subtitle in subtitles
            where (try? await policy.validate(subtitle.url, purpose: .subtitle)) != nil {
                allowedSubtitles.append(subtitle)
            }
            rejectedSubtitles += subtitles.count - allowedSubtitles.count
            allowed.append(stream.withSubtitles(allowedSubtitles.isEmpty ? nil : allowedSubtitles))
        }
        if rejectedSubtitles > 0 {
            Logger.shared.log(
                "Nuvio dropped \(rejectedSubtitles) subtitle track(s) that did not resolve to a public address",
                type: "Error"
            )
        }
        let rejected = streams.count - allowed.count
        guard rejected > 0 else {
            return rejectedSubtitles > 0 ? .results(allowed) : outcome
        }
        Logger.shared.log(
            "Nuvio dropped \(rejected) stream(s) that did not resolve to a public address",
            type: "Error"
        )

        guard !allowed.isEmpty else { return .unplayableOnly(count: rejected) }
        return .results(allowed)
    }

    private func computeOutcome(
        scraperID: String,
        tmdbId: String,
        mediaType: String,
        season: Int?,
        episode: Int?
    ) async -> NuvioProviderOutcome {
        guard Self.isFeatureAvailable else {
            return .appFailure("Nuvio plugins are unavailable in this build.")
        }
        guard state.pluginsEnabled else {
            return .notEnabled("Nuvio plugins are turned off.")
        }
        guard let scraper = scraper(withID: scraperID) else {
            return .notEnabled("This provider is no longer installed.")
        }
        guard scraper.isRunnable,
              let repository = repository(withID: scraper.repositoryId),
              repository.isEnabled else {
            return .notEnabled("This provider is turned off.")
        }

        let normalizedType = NuvioPluginSupport.normalizeType(mediaType)
        guard scraper.supportsType(normalizedType) else {
            return .unsupportedMediaType(normalizedType == "movie" ? "movies" : "TV shows")
        }

#if os(iOS) && !targetEnvironment(macCatalyst)

        let scopeEpoch = ServiceStoreScope.generation
        let scraperSettings = settingsPayload(for: scraper)
        guard let code = await store.readCodeInBackground(
            repositoryID: scraper.repositoryId,
            codeFileName: scraper.codeFileName
        ) else {
            return .appFailure("The plugin code is missing from storage. Refresh the repository.")
        }
        guard ServiceStoreScope.isCurrent(scopeEpoch) else {
            return .notEnabled("The active profile changed while this provider was loading.")
        }

        let batch: NuvioStreamBatch
        do {
            batch = try await NuvioPluginRuntime.execute(
                code: code,
                tmdbId: tmdbId,
                mediaType: normalizedType,
                season: season,
                episode: episode,
                scraper: scraper,
                repository: repository,
                scraperSettings: scraperSettings
            )
        } catch {
            return Self.classify(error: error)
        }

        Logger.shared.log(
            "Nuvio ledger provider=\(scraper.name) tmdb=\(tmdbId) type=\(normalizedType)"
                + " season=\(season.map(String.init) ?? "-") episode=\(episode.map(String.init) ?? "-")"
                + " rows=\(batch.streams.count) unplayable=\(batch.unplayableCount)"
                + " malformedURLs=\(batch.malformedURLCount) \(batch.ledgerDescription)",
            type: "Plugin"
        )
        if batch.streams.isEmpty, batch.interference.blocksScraping {
            Logger.shared.log(
                "Nuvio provider=\(scraper.name) returned nothing while Eclipse itself cut its run short:"
                    + " \(batch.interference.blockingSummary). This empty result is an Eclipse problem,"
                    + " not a dead provider.",
                type: "Error"
            )
        }

        if batch.streams.isEmpty {
            if batch.unplayableCount > 0 {
                return .unplayableOnly(count: batch.unplayableCount)
            }

            if batch.interference.blocksScraping {
                return .appFailure(
                    "Eclipse cut this provider's run short (\(batch.interference.blockingSummary))."
                )
            }
            if batch.madeNoRequests { return .needsSetup }
            if batch.everyRequestFailed { return .sourceUnreachable }
            return .noResults
        }

        var seen = Set<String>()
        let deduplicated = batch.streams.filter { seen.insert($0.url).inserted }
        return .results(Array(deduplicated.prefix(maxStreamsPerScraper)))
#else
        return .appFailure("Nuvio plugins are not supported on this platform.")
#endif
    }

    private static func classify(error: Error) -> NuvioProviderOutcome {
        guard let pluginError = error as? NuvioPluginError else {
            return .providerError(error.localizedDescription)
        }
        switch pluginError {
        case .runtimeTimeout:
            return .timedOut
        case .runtimeFailed(let message):
            return .providerError(Self.humanized(message))
        case .runtimeBootstrapFailed(let message):
            return .appFailure(message)
        case .invalidResponse:
            return .providerError("The plugin returned a stream list Eclipse could not read.")
        case .unavailable:
            return .appFailure("Nuvio plugins are unavailable in this build.")
        case .providerNotFound, .repositoryNotFound:
            return .notEnabled("This provider is no longer installed.")
        default:
            return .providerError(pluginError.errorDescription ?? "The plugin failed.")
        }
    }

    private static func humanized(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "getStreams not found":
            return "The plugin did not load correctly, so Eclipse could not ask it for streams."
        case "Plugin network request blocked by sandbox.":
            return "The plugin tried to reach an address Eclipse blocks."
        case "Invalid fetch URL.":
            return "The plugin requested an address Eclipse cannot open."
        default:
            return trimmed
        }
    }

    func settingsValues(scraperID: String) -> [String: NuvioSettingsValue] {
        state.scraperSettings[scraperID] ?? [:]
    }

    func setSettingsValue(_ value: NuvioSettingsValue?, forKey key: String, scraperID: String) {
        guard Self.isFeatureAvailable, !key.isEmpty else { return }
        var values = state.scraperSettings[scraperID] ?? [:]
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        state.scraperSettings[scraperID] = values.isEmpty ? nil : values
        persistSettingsSoon()
    }

    func settingsFields(scraperID: String) async throws -> [NuvioSettingsField] {
        guard Self.isFeatureAvailable else { throw NuvioPluginError.unavailable }
        guard let scraper = state.scrapers.first(where: { $0.id == scraperID }) else {
            throw NuvioPluginError.providerNotFound
        }
#if os(iOS) && !targetEnvironment(macCatalyst)

        let scopeEpoch = ServiceStoreScope.generation
        let scraperSettings = settingsPayload(for: scraper)
        guard let code = await store.readCodeInBackground(
            repositoryID: scraper.repositoryId,
            codeFileName: scraper.codeFileName
        ) else {
            throw NuvioPluginError.providerNotFound
        }
        guard ServiceStoreScope.isCurrent(scopeEpoch) else {
            throw NuvioPluginError.runtimeFailed(
                "The active profile changed while these settings were loading."
            )
        }
        return try await NuvioPluginRuntime.executeSettings(
            code: code,
            scraper: scraper,
            scraperSettings: scraperSettings
        )
#else
        return []
#endif
    }

    private func settingsPayload(for scraper: NuvioPluginScraper) -> [String: Any] {
        var payload: [String: Any] = [:]
        for (key, value) in settingsValues(scraperID: scraper.id) {
            payload[key] = value.jsonObject
        }
        return payload
    }

    func backupState() -> NuvioStoredPluginsState? {
        guard Self.isFeatureAvailable else { return nil }
        var copy = state
        copy.repositories = copy.repositories.map {
            var repository = $0
            repository.isRefreshing = false
            repository.errorMessage = nil
            return repository
        }
        return copy
    }

    func restoreBackupState(_ restored: NuvioStoredPluginsState) async {
        guard Self.isFeatureAvailable else { return }
        let scopeEpoch = ServiceStoreScope.generation
        let previousRepositoryIDs = state.repositories.map(\.id)
        let sanitized = boundedRestoredState(restored)
        let repositoryIDs = Set(sanitized.repositories.map(\.id))

        let droppedRepositoryIDs = Set(previousRepositoryIDs).subtracting(repositoryIDs)

        state = sanitized
        persist()

        for repository in sanitized.repositories {
            AutoModeSourceSelection.appendSourceToOrderIfNeeded(repository.id)
        }
        _ = await repairMissingCodeAfterRestore(reason: "typed-backup-restore")
        guard ServiceStoreScope.isCurrent(scopeEpoch), !Task.isCancelled else {

            return
        }
        for droppedID in droppedRepositoryIDs {
            store.removeRepositoryCode(repositoryID: droppedID)
        }
    }

    private func boundedRestoredState(_ restored: NuvioStoredPluginsState) -> NuvioStoredPluginsState {
        let bounded = NuvioPluginStore.bounded(restored)
        if bounded.wasBounded {
            Logger.shared.log(
                "Nuvio restore bounded a backup snapshot: dropped \(bounded.droppedCount) entr(ies), "
                    + "truncated \(bounded.truncatedCount) value(s)",
                type: "Plugin"
            )
        }
        return bounded.state
    }

    func storageSizeBytes() -> Int64 {
        store.codeSizeBytes()
    }
}

struct NuvioRepositoryFetch {
    let repository: NuvioPluginRepository

    let scrapers: [NuvioPluginScraper]

    let carriedOverScraperIDs: Set<String>
}

struct NuvioInstallProgress: Equatable {
    let label: String
    let completed: Int
    let total: Int

    var fractionCompleted: Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 0
    }
}
