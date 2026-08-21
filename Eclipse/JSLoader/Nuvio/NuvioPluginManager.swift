import Combine
import Foundation

@MainActor
final class NuvioPluginManager: ObservableObject {
    static let shared = NuvioPluginManager()

    @Published private(set) var state = NuvioStoredPluginsState()
    @Published private(set) var isLoaded = false
    @Published private(set) var installProgress: NuvioInstallProgress?
    @Published private(set) var codeReadiness = NuvioCodeReadiness()
    @Published private(set) var repositoryProviderStatuses: [String: NuvioRepositoryProviderStatus] = [:]
    @Published private(set) var storedStateIsUnreadable = false

    private var installingRepositoryIDs: Set<String> = []
    private var repairLedger = NuvioRepositoryRepairLedger()
    private var missingCodeRepairTask: Task<Void, Never>?
    private var missingCodeRepairGeneration = 0

    private let store: NuvioPluginStore
    private let maxStreamsPerScraper = 40
    private let maxConcurrentDownloads = 6
    private let manifestTimeout: TimeInterval = 10
    private let codeTimeout: TimeInterval = 15
    private let maxCodeBytes = NuvioPluginStore.Bounds.codeBytes

    private let maxManifestProviders = 200

    private let maxAutomaticMissingCodeRepairs = 12
    private let missingCodeRepairCursorKey = "nuvioMissingCodeRepairCursor.v1"
    private static let pendingCodeWarningPrefix = "Provider code download is incomplete."

    private var canAdministerPlugins: Bool {
        ServicePluginAdministrativeAdmissionPolicy.permits(
            isKidsProfile: ProfileManager.shared.activeProfile?.isKidsProfile == true
        )
    }

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
        guard Self.isFeatureAvailable, !storedStateIsUnreadable, state.pluginsEnabled else { return [] }
        return repositories.filter { $0.isEnabled && scraperCount(forRepository: $0.id, runnableOnly: true) > 0 }
    }

    var scrapers: [NuvioPluginScraper] { state.scrapers }

    var activeScrapers: [NuvioPluginScraper] {
        guard Self.isFeatureAvailable, !storedStateIsUnreadable, state.pluginsEnabled else { return [] }
        let enabledRepositoryIDs = Set(
            state.repositories.filter(\.isEnabled).map(\.id)
        )
        let pendingProviderIDs = Set(codeReadiness.pendingProviderIDs)

        let repositoryOrder = repositories.enumerated().reduce(into: [String: Int]()) { result, entry in
            if result[entry.element.id] == nil {
                result[entry.element.id] = entry.offset
            }
        }
        return state.scrapers
            .filter {
                $0.isRunnable
                    && enabledRepositoryIDs.contains($0.repositoryId)
                    && !pendingProviderIDs.contains($0.id)
            }
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
        scheduleMissingCodeRepair(reason: "launch")
    }

    func load() {

        guard Self.isFeatureAvailable else {
            state = NuvioStoredPluginsState(pluginsEnabled: false)
            codeReadiness = NuvioCodeReadiness()
            repositoryProviderStatuses = [:]
            repairLedger = NuvioRepositoryRepairLedger()
            storedStateIsUnreadable = false
            isLoaded = true
            return
        }
        state = store.load()
        storedStateIsUnreadable = store.stateWritesSuspended
        if !storedStateIsUnreadable {
            store.purgeLegacyState()
        }
        let repositoryIDs = Set(state.repositories.map(\.id))
        if storedStateIsUnreadable {
            repairLedger = store.loadRepairLedgerPreservingRepositoryIDs()
        } else {
            repairLedger = store.loadRepairLedger(validRepositoryIDs: repositoryIDs)
            store.saveRepairLedger(repairLedger, validRepositoryIDs: repositoryIDs)
        }
        updateCodeReadiness()
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

        load()
        let repair = await repairMissingCodeAfterRestore(
            reason: "backup-restore-reload",
            expectedScopeGeneration: expectedScopeGeneration
        )
        Logger.shared.log(
            "Nuvio restore reload codeReady=\(repair.readiness.readyProviderCount)"
                + " codePending=\(repair.readiness.pendingProviderCount)"
                + " repositoriesPending=\(repair.readiness.pendingRepositoryIDs.count)",
            type: "Plugin"
        )
        return expectedScopeGeneration.map(ServiceStoreScope.isCurrent) ?? true
    }

    @discardableResult
    func repairMissingCodeAfterRestore(
        reason: String = "backup-restore",
        expectedScopeGeneration: Int? = nil
    ) async -> NuvioCodeRepairResult {
        guard Self.isFeatureAvailable else {
            return NuvioCodeRepairResult(
                readiness: NuvioCodeReadiness(),
                attemptedRepositoryIDs: [],
                wasInterrupted: false
            )
        }
        guard !store.stateWritesSuspended else {
            return NuvioCodeRepairResult(
                readiness: codeReadiness,
                attemptedRepositoryIDs: [],
                wasInterrupted: false
            )
        }
        let scopeEpoch = expectedScopeGeneration ?? ServiceStoreScope.generation
        missingCodeRepairGeneration &+= 1
        let repairGeneration = missingCodeRepairGeneration
        let defaults = ProfileSettingsStore.services
        var attemptedRepositoryIDs: [String] = []

        guard !Task.isCancelled,
              ServiceStoreScope.isCurrent(scopeEpoch),
              missingCodeRepairGeneration == repairGeneration else {
            return NuvioCodeRepairResult(
                readiness: codeReadiness,
                attemptedRepositoryIDs: [],
                wasInterrupted: true
            )
        }
        let initialReadiness = updateCodeReadiness()
        let failedRepositoryIDs = state.repositories.compactMap { repository in
            repairLedger.failedProviderKeys(for: repository.id).isEmpty ? nil : repository.id
        }
        let missingRepositoryIDs = Self.orderedUniqueRepositoryIDs(
            initialReadiness.pendingRepositoryIDs + failedRepositoryIDs
        )
        guard !missingRepositoryIDs.isEmpty else {
            return NuvioCodeRepairResult(
                readiness: initialReadiness,
                attemptedRepositoryIDs: [],
                wasInterrupted: false
            )
        }

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
                return NuvioCodeRepairResult(
                    readiness: updateCodeReadiness(),
                    attemptedRepositoryIDs: attemptedRepositoryIDs,
                    wasInterrupted: true
                )
            }
            attemptedRepositoryIDs.append(repositoryID)

            defaults.set(repositoryID, forKey: missingCodeRepairCursorKey)
            await retryFailedProviders(
                repositoryID,
                expectedScopeGeneration: scopeEpoch
            )
            guard !Task.isCancelled,
                  ServiceStoreScope.isCurrent(scopeEpoch),
                  missingCodeRepairGeneration == repairGeneration else {
                return NuvioCodeRepairResult(
                    readiness: codeReadiness,
                    attemptedRepositoryIDs: attemptedRepositoryIDs,
                    wasInterrupted: true
                )
            }
        }
        return NuvioCodeRepairResult(
            readiness: updateCodeReadiness(),
            attemptedRepositoryIDs: attemptedRepositoryIDs,
            wasInterrupted: false
        )
    }

    @discardableResult
    private func updateCodeReadiness() -> NuvioCodeReadiness {
        let readiness = state.codeReadiness { [store] repositoryID, codeFileName in
            store.hasCode(repositoryID: repositoryID, codeFileName: codeFileName)
        }
        codeReadiness = readiness
        let pendingProviderIDs = Set(readiness.pendingProviderIDs)
        repositoryProviderStatuses = Dictionary(
            uniqueKeysWithValues: state.repositories.map { repository in
                let represented = state.scrapers.filter {
                    $0.repositoryId == repository.id
                }
                let missingCode = represented.reduce(into: 0) { count, scraper in
                    if pendingProviderIDs.contains(scraper.id) { count += 1 }
                }
                let installed = max(represented.count - missingCode, 0)
                return (
                    repository.id,
                    NuvioRepositoryProviderStatus.resolved(
                        repository: repository,
                        representedProviderCount: represented.count,
                        installedProviderCount: installed,
                        failedProviderCount: repairLedger.failedProviderKeys(
                            for: repository.id
                        ).count
                    )
                )
            }
        )
        state.repositories = state.repositories.map { repository in
            guard repository.errorMessage?.hasPrefix(Self.pendingCodeWarningPrefix) == true else {
                return repository
            }
            var copy = repository
            copy.errorMessage = nil
            return copy
        }
        return readiness
    }

    private static func orderedUniqueRepositoryIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func scheduleMissingCodeRepair(reason: String) {
        missingCodeRepairTask?.cancel()
        missingCodeRepairTask = Task { @MainActor [weak self] in

            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            _ = await self.repairMissingCodeAfterRestore(reason: reason)
        }
    }

    @discardableResult
    private func commitState(_ candidate: NuvioStoredPluginsState) -> Bool {
        guard store.save(candidate) else { return false }
        state = candidate
        return true
    }

    private func persistRepairLedger() {
        store.saveRepairLedger(
            repairLedger,
            validRepositoryIDs: Set(state.repositories.map(\.id))
        )
    }

    private static func recordRepairOutcome(
        _ fetched: NuvioRepositoryFetch,
        previousFailedProviderKeys: Set<String>,
        ledger: inout NuvioRepositoryRepairLedger
    ) {
        ledger.setFailedProviderKeys(
            NuvioRepositoryRepairPolicy.reconciledFailedProviderKeys(
                eligibleProviderKeys: fetched.eligibleProviderKeys,
                previousFailedProviderKeys: previousFailedProviderKeys,
                attemptedProviderKeys: fetched.attemptedProviderKeys,
                failedProviderKeys: fetched.failedProviderKeys
            ),
            for: fetched.repository.id
        )
    }

    func scrapers(forRepository repositoryID: String) -> [NuvioPluginScraper] {
        state.scrapers
            .filter { $0.repositoryId == repositoryID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func scraperCount(forRepository repositoryID: String, runnableOnly: Bool) -> Int {
        let pendingProviderIDs = Set(codeReadiness.pendingProviderIDs)
        return state.scrapers.filter {
            $0.repositoryId == repositoryID
                && (!runnableOnly || (
                    $0.isRunnable
                        && !pendingProviderIDs.contains($0.id)
                ))
        }.count
    }

    func providerStatus(forRepository repositoryID: String) -> NuvioRepositoryProviderStatus? {
        repositoryProviderStatuses[repositoryID]
    }

    func repository(withID repositoryID: String) -> NuvioPluginRepository? {
        state.repositories.first { $0.id == repositoryID }
    }

    func setPluginsEnabled(_ enabled: Bool) {
        guard Self.isFeatureAvailable, canAdministerPlugins,
              !store.stateWritesSuspended else { return }
        var candidate = state
        candidate.pluginsEnabled = enabled
        _ = commitState(candidate)
    }

    func setRepositoryEnabled(_ repositoryID: String, enabled: Bool) {
        guard Self.isFeatureAvailable, canAdministerPlugins,
              !store.stateWritesSuspended else { return }
        guard let index = state.repositories.firstIndex(where: { $0.id == repositoryID }) else { return }
        var candidate = state
        if enabled { candidate.pluginsEnabled = true }
        candidate.repositories[index].isEnabled = enabled
        _ = commitState(candidate)
    }

    func setScraperEnabled(_ scraperID: String, enabled: Bool) {
        guard Self.isFeatureAvailable, canAdministerPlugins,
              !store.stateWritesSuspended else { return }
        var candidate = state
        candidate.scrapers = candidate.scrapers.map { scraper in
            guard scraper.id == scraperID else { return scraper }
            var copy = scraper
            copy.enabled = scraper.manifestEnabled && enabled
            return copy
        }
        guard commitState(candidate) else { return }
        if let scraper = scraper(withID: scraperID),
           scraper.isRunnable,
           store.hasCode(
               repositoryID: scraper.repositoryId,
               codeFileName: scraper.codeFileName
           ) {
            AutoModeSourceSelection.enrollSourceOnFirstAvailability(scraperID)
        }
    }

    func setAllScrapersEnabled(_ enabled: Bool, inRepository repositoryID: String) {
        guard Self.isFeatureAvailable, canAdministerPlugins,
              !store.stateWritesSuspended else { return }
        var candidate = state
        candidate.scrapers = candidate.scrapers.map { scraper in
            guard scraper.repositoryId == repositoryID else { return scraper }
            var copy = scraper
            copy.enabled = scraper.manifestEnabled && enabled
            return copy
        }
        guard commitState(candidate), enabled else { return }
        for scraper in scrapers(forRepository: repositoryID) where scraper.isRunnable
            && store.hasCode(
                repositoryID: scraper.repositoryId,
                codeFileName: scraper.codeFileName
            ) {
            AutoModeSourceSelection.enrollSourceOnFirstAvailability(scraper.id)
        }
    }

    @discardableResult
    func addRepository(
        rawURL: String,
        expectedScopeGeneration: Int? = nil
    ) async throws -> NuvioRepositoryProviderStatus {
        guard Self.isFeatureAvailable else { throw NuvioPluginError.unavailable }
        guard canAdministerPlugins else { throw NuvioPluginError.requiresGrownUpProfile }
        guard !store.stateWritesSuspended else { throw NuvioPluginError.storedStateUnreadable }
        let scopeEpoch = expectedScopeGeneration ?? ServiceStoreScope.generation
        guard ServiceStoreScope.isCurrent(scopeEpoch) else {
            throw NuvioPluginError.repositoryInstallFailed(
                "The active profile changed before this repository could install."
            )
        }

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
                previousScrapers: [:],
                strategy: .full
            )

            guard ServiceStoreScope.isCurrent(scopeEpoch) else {
                store.removeRepositoryCode(repositoryID: repositoryID, ownedBy: owningProfile)
                throw NuvioPluginError.repositoryInstallFailed(
                    "The active profile changed while this repository was installing."
                )
            }
            var candidate = state
            candidate.repositories.append(fetched.repository)
            candidate.scrapers.removeAll { $0.repositoryId == repositoryID }
            candidate.scrapers.append(contentsOf: fetched.scrapers)
            var candidateLedger = repairLedger
            Self.recordRepairOutcome(
                fetched,
                previousFailedProviderKeys: [],
                ledger: &candidateLedger
            )
            guard commitState(candidate) else {
                throw NuvioPluginError.repositoryInstallFailed(
                    "The repository was downloaded, but its metadata could not be saved."
                )
            }
            repairLedger = candidateLedger
            persistRepairLedger()
            updateCodeReadiness()
            for scraper in fetched.scrapers where scraper.isRunnable
                && store.hasCode(
                    repositoryID: scraper.repositoryId,
                    codeFileName: scraper.codeFileName
                ) {
                AutoModeSourceSelection.enrollSourceOnFirstAvailability(scraper.id)
            }
            logRepositoryFetch(fetched)
            return providerStatus(forRepository: repositoryID)
                ?? NuvioRepositoryProviderStatus.resolved(
                    repository: fetched.repository,
                    representedProviderCount: fetched.scrapers.count,
                    installedProviderCount: fetched.scrapers.reduce(into: 0) { count, scraper in
                        if store.hasCode(
                            repositoryID: scraper.repositoryId,
                            codeFileName: scraper.codeFileName
                        ) {
                            count += 1
                        }
                    },
                    failedProviderCount: fetched.failedProviderKeys.count
                )
        } catch let error as NuvioPluginError {
            store.removeRepositoryCode(repositoryID: repositoryID, ownedBy: owningProfile)
            throw error
        } catch {
            store.removeRepositoryCode(repositoryID: repositoryID, ownedBy: owningProfile)
            throw NuvioPluginError.repositoryInstallFailed(error.localizedDescription)
        }
    }

    func refreshRepository(
        _ repositoryID: String,
        expectedScopeGeneration: Int? = nil
    ) async {
        _ = await updateRepository(
            repositoryID,
            strategy: .full,
            expectedScopeGeneration: expectedScopeGeneration
        )
    }

    @discardableResult
    func retryFailedProviders(
        _ repositoryID: String,
        expectedScopeGeneration: Int? = nil
    ) async -> NuvioRepositoryProviderStatus? {
        await updateRepository(
            repositoryID,
            strategy: .repair,
            expectedScopeGeneration: expectedScopeGeneration
        )
    }

    private func updateRepository(
        _ repositoryID: String,
        strategy: NuvioRepositoryFetchStrategy,
        expectedScopeGeneration: Int? = nil
    ) async -> NuvioRepositoryProviderStatus? {
        let scopeEpoch = expectedScopeGeneration ?? ServiceStoreScope.generation

        let owningProfile = ProfileManager.shared.activeProfileID
        guard Self.isFeatureAvailable,
              canAdministerPlugins,
              ServiceStoreScope.isCurrent(scopeEpoch),
              !store.stateWritesSuspended,
              let existing = state.repositories.first(where: { $0.id == repositoryID }) else { return nil }
        guard !installingRepositoryIDs.contains(repositoryID) else {
            return providerStatus(forRepository: repositoryID)
        }
        installingRepositoryIDs.insert(repositoryID)
        defer { installingRepositoryIDs.remove(repositoryID) }

        setRefreshing(repositoryID, isRefreshing: true, error: nil)
        let progressVerb = strategy == .full ? "Refreshing" : "Retrying"
        installProgress = NuvioInstallProgress(
            label: "\(progressVerb) \(existing.displayName)",
            completed: 0,
            total: 0
        )
        defer {
            installProgress = nil
            setRefreshing(repositoryID, isRefreshing: false, error: nil, preserveExistingError: true)
            updateCodeReadiness()
        }

        let previous = Dictionary(
            state.scrapers.filter { $0.repositoryId == repositoryID }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previousFailedProviderKeys = repairLedger.failedProviderKeys(for: repositoryID)
        do {
            let fetched = try await fetchRepository(
                manifestURL: existing.manifestUrl,
                repositoryID: repositoryID,
                sortIndex: existing.sortIndex,
                previousScrapers: previous,
                strategy: strategy,
                previousFailedProviderKeys: previousFailedProviderKeys
            )
            guard ServiceStoreScope.isCurrent(scopeEpoch) else {

                store.pruneCode(
                    repositoryID: repositoryID,
                    keeping: Set(previous.values.map(\.codeFileName)),
                    ownedBy: owningProfile
                )
                return providerStatus(forRepository: repositoryID)
            }
            guard let currentRepository = state.repositories.first(where: {
                $0.id == repositoryID
            }) else {
                store.pruneCode(
                    repositoryID: repositoryID,
                    keeping: Set(previous.values.map(\.codeFileName)),
                    ownedBy: owningProfile
                )
                return nil
            }
            var refreshed = fetched.repository
            refreshed.isEnabled = currentRepository.isEnabled
            let mergedScrapers = Self.reconciledRefreshScrapers(
                fetched.scrapers,
                withCurrent: state.scrapers.filter { $0.repositoryId == repositoryID }
            )
            var candidate = state
            candidate.repositories = candidate.repositories.map { $0.id == repositoryID ? refreshed : $0 }
            candidate.scrapers.removeAll { $0.repositoryId == repositoryID }
            candidate.scrapers.append(contentsOf: mergedScrapers)
            candidate.scraperSettings = candidate.scraperSettings.filter { key, _ in
                candidate.scrapers.contains { $0.id == key }
            }
            var candidateLedger = repairLedger
            Self.recordRepairOutcome(
                fetched,
                previousFailedProviderKeys: previousFailedProviderKeys,
                ledger: &candidateLedger
            )
            guard commitState(candidate) else {
                store.pruneCode(
                    repositoryID: repositoryID,
                    keeping: Set(previous.values.map(\.codeFileName)),
                    ownedBy: owningProfile
                )
                throw NuvioPluginError.repositoryInstallFailed(
                    "The refreshed repository metadata could not be saved."
                )
            }
            repairLedger = candidateLedger
            persistRepairLedger()

            let removedScraperIDs = Set(previous.keys)
                .subtracting(fetched.scrapers.map(\.id))
                .subtracting(fetched.carriedOverScraperIDs)
            for removedID in removedScraperIDs {
                AutoModeSourceSelection.removeSourceAuthoritatively(removedID)
            }
            for scraper in mergedScrapers where scraper.isRunnable
                && store.hasCode(
                    repositoryID: scraper.repositoryId,
                    codeFileName: scraper.codeFileName
                ) {
                AutoModeSourceSelection.enrollSourceOnFirstAvailability(scraper.id)
            }

            store.pruneCode(
                repositoryID: repositoryID,
                keeping: Set(mergedScrapers.map(\.codeFileName)),
                ownedBy: owningProfile
            )
            updateCodeReadiness()
            logRepositoryFetch(fetched)
            return providerStatus(forRepository: repositoryID)
        } catch {
            setRefreshing(repositoryID, isRefreshing: false, error: error.localizedDescription)
            return providerStatus(forRepository: repositoryID)
        }
    }

    func refreshRepositoriesAndInstalledPlugins(autoUpdate: Bool) async {
        guard Self.isFeatureAvailable, canAdministerPlugins, autoUpdate else { return }
        let scopeEpoch = ServiceStoreScope.generation
        for repository in state.repositories {
            guard ServiceStoreScope.isCurrent(scopeEpoch) else { return }
            await refreshRepository(
                repository.id,
                expectedScopeGeneration: scopeEpoch
            )
        }
    }

    func uninstall(repositoryID: String) {
        guard Self.isFeatureAvailable, canAdministerPlugins,
              !store.stateWritesSuspended else { return }
        var candidate = state
        candidate.repositories.removeAll { $0.id == repositoryID }
        let removedScraperIDs = Set(
            candidate.scrapers.filter { $0.repositoryId == repositoryID }.map(\.id)
        )
        candidate.scrapers.removeAll { $0.repositoryId == repositoryID }
        candidate.scraperSettings = candidate.scraperSettings.filter { !removedScraperIDs.contains($0.key) }
        var candidateLedger = repairLedger
        candidateLedger.removeRepository(repositoryID)
        guard commitState(candidate) else { return }
        repairLedger = candidateLedger
        persistRepairLedger()
        updateCodeReadiness()
        store.removeRepositoryCode(repositoryID: repositoryID)
        AutoModeSourceSelection.removeSourceAuthoritatively(repositoryID)

        SourceHealthStore.shared.removeRecord(sourceId: repositoryID)
        for scraperID in removedScraperIDs {
            AutoModeSourceSelection.removeSourceAuthoritatively(scraperID)
            SourceHealthStore.shared.removeRecord(sourceId: scraperID)
        }
    }

    func resetPluginData() {
        guard Self.isFeatureAvailable, canAdministerPlugins else { return }
        let owningProfile = ProfileManager.shared.activeProfileID
        let repositoryIDs = Set(state.repositories.map(\.id))
            .union(Set(repairLedger.failedProviderKeysByRepository.keys))
        let scraperIDs = Set(state.scrapers.map(\.id))
        missingCodeRepairTask?.cancel()
        missingCodeRepairTask = nil
        missingCodeRepairGeneration &+= 1
        store.resetStateAuthoritatively()
        state = NuvioStoredPluginsState()
        repairLedger = NuvioRepositoryRepairLedger()
        persistRepairLedger()
        storedStateIsUnreadable = false
        updateCodeReadiness()
        for repositoryID in repositoryIDs {
            store.removeRepositoryCode(repositoryID: repositoryID, ownedBy: owningProfile)
            AutoModeSourceSelection.removeSourceAuthoritatively(repositoryID)
            SourceHealthStore.shared.removeRecord(sourceId: repositoryID)
        }
        for scraperID in scraperIDs {
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

    static func reconciledRefreshScrapers(
        _ fetched: [NuvioPluginScraper],
        withCurrent current: [NuvioPluginScraper]
    ) -> [NuvioPluginScraper] {
        let currentByID = Dictionary(
            current.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return fetched.map { scraper in
            guard let current = currentByID[scraper.id] else { return scraper }
            var copy = scraper
            copy.enabled = scraper.manifestEnabled && current.enabled
            return copy
        }
    }

    private func fetchRepository(
        manifestURL: String,
        repositoryID: String,
        sortIndex: Int64,
        previousScrapers: [String: NuvioPluginScraper],
        strategy: NuvioRepositoryFetchStrategy,
        previousFailedProviderKeys: Set<String> = []
    ) async throws -> NuvioRepositoryFetch {
        let manifestPayload = try await NuvioManifestFetchRetryPolicy.run(
            operation: { [manifestURL, manifestTimeout] in
                try await Self.downloadText(
                    from: manifestURL,
                    timeout: manifestTimeout,
                    kind: "manifest"
                )
            },
            sleep: { seconds in
                try await Task.sleep(
                    nanoseconds: UInt64(seconds * 1_000_000_000)
                )
            }
        )
        let parsedManifest = try parseManifest(manifestPayload)
        let manifest = parsedManifest.manifest

        let candidates = manifest.scrapers.filter(isSupportedOnCurrentPlatform)
        guard !candidates.isEmpty else { throw NuvioPluginError.manifestHasNoProviders }
        let eligibleProviderKeys = Set(candidates.map(\.id))

        let attemptedCandidates: [NuvioPluginManifestScraper]
        switch strategy {
        case .full:
            attemptedCandidates = candidates
        case .repair:
            let representedProviderKeys = Set(previousScrapers.values.map(\.providerKey))
            let codeReadyProviderKeys = Set(previousScrapers.values.compactMap { scraper in
                store.hasCode(
                    repositoryID: repositoryID,
                    codeFileName: scraper.codeFileName
                ) ? scraper.providerKey : nil
            })
            let retryProviderKeys = NuvioRepositoryRepairPolicy.providerKeysToRetry(
                eligibleProviderKeys: eligibleProviderKeys,
                representedProviderKeys: representedProviderKeys,
                codeReadyProviderKeys: codeReadyProviderKeys,
                failedProviderKeys: previousFailedProviderKeys
            )
            attemptedCandidates = candidates.filter { info in
                retryProviderKeys.contains(info.id)
            }
        }
        let attemptedProviderKeys = Set(attemptedCandidates.map(\.id))

        installProgress = NuvioInstallProgress(
            label: strategy == .full ? "Downloading providers" : "Retrying provider downloads",
            completed: 0,
            total: attemptedCandidates.count
        )

        var downloaded: [String: NuvioProviderDownloadResult] = [:]
        var completed = 0
        await BoundedProgressiveFanout.run(
            inputs: attemptedCandidates,
            maxConcurrent: maxConcurrentDownloads,
            operation: { [manifestURL, codeTimeout, maxCodeBytes] info -> NuvioProviderDownloadResult in
                let url = NuvioPluginSupport.codeURL(manifestURL: manifestURL, filename: info.filename)
                do {
                    let code = try await NuvioManifestFetchRetryPolicy.run(
                        operation: {
                            try await Self.downloadText(
                                from: url,
                                timeout: codeTimeout,
                                kind: "provider",
                                maximumBytes: maxCodeBytes
                            )
                        },
                        sleep: { seconds in
                            try await Task.sleep(
                                nanoseconds: UInt64(seconds * 1_000_000_000)
                            )
                        }
                    )
                    guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return NuvioProviderDownloadResult(code: nil, failureToken: "empty")
                    }
                    return NuvioProviderDownloadResult(code: code, failureToken: nil)
                } catch {
                    return NuvioProviderDownloadResult(
                        code: nil,
                        failureToken: Self.providerDownloadFailureToken(error)
                    )
                }
            },
            isCurrent: { true },
            onResult: { info, result in
                completed += 1
                self.installProgress = NuvioInstallProgress(
                    label: strategy == .full
                        ? "Downloading providers"
                        : "Retrying provider downloads",
                    completed: completed,
                    total: attemptedCandidates.count
                )
                downloaded[info.id] = result
                if let failureToken = result.failureToken {
                    Logger.shared.log(
                        "Nuvio provider download failed provider=\(info.id) failure=\(failureToken)",
                        type: "Plugin"
                    )
                }
            }
        )
        if Task.isCancelled { throw CancellationError() }

        var scrapers: [NuvioPluginScraper] = []
        var carriedOver: Set<String> = []
        var failedProviderKeys = Set<String>()
        for info in candidates {
            let scraperID = NuvioPluginSupport.scraperSourceID(
                manifestURL: manifestURL,
                providerKey: info.id
            )

            var writtenCodeFileName: String?
            if let code = downloaded[info.id]?.code {
                do {
                    writtenCodeFileName = try store.writeCode(
                        code,
                        repositoryID: repositoryID,
                        scraperID: scraperID
                    )
                } catch {
                    Logger.shared.log(
                        "Nuvio provider write failed provider=\(info.id) failure=write",
                        type: "Plugin"
                    )
                }
            }

            let userEnabled = previousScrapers[scraperID]?.enabled ?? true
            let codeFileName = writtenCodeFileName
                ?? previousScrapers[scraperID]?.codeFileName
                ?? ""
            if writtenCodeFileName == nil {
                if previousScrapers[scraperID] != nil {
                    carriedOver.insert(scraperID)
                }
                if attemptedProviderKeys.contains(info.id) {
                    failedProviderKeys.insert(info.id)
                    Logger.shared.log(
                        "Nuvio provider metadata retained after failed download provider=\(info.id)",
                        type: "Plugin"
                    )
                }
            }
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

        let repository = NuvioPluginRepository(
            id: repositoryID,
            manifestUrl: manifestURL,
            name: manifest.name,
            description: manifest.description,
            version: manifest.version,
            scraperCount: candidates.count,
            lastUpdated: Date().timeIntervalSince1970,
            sortIndex: sortIndex,
            providerInventory: NuvioRepositoryProviderInventory(
                advertisedProviderCount: parsedManifest.advertisedProviderCount,
                eligibleProviderCount: candidates.count
            )
        )
        return NuvioRepositoryFetch(
            repository: repository,
            scrapers: scrapers,
            carriedOverScraperIDs: carriedOver,
            eligibleProviderKeys: eligibleProviderKeys,
            attemptedProviderKeys: attemptedProviderKeys,
            failedProviderKeys: failedProviderKeys
        )
    }

    private func parseManifest(_ payload: String) throws -> NuvioParsedPluginManifest {
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
        guard manifest.name.count <= NuvioPluginStore.Bounds.textLength,
              manifest.version.count <= NuvioPluginStore.Bounds.textLength,
              (manifest.description?.count ?? 0) <= NuvioPluginStore.Bounds.textLength else {
            throw NuvioPluginError.repositoryInstallFailed(
                "The repository manifest contains over-limit metadata."
            )
        }
        let advertisedProviderCount = manifest.scrapers.count
        guard advertisedProviderCount > 0,
              advertisedProviderCount <= NuvioPluginStore.Bounds.advertisedProviders else {
            throw NuvioPluginError.manifestHasNoProviders
        }

        if advertisedProviderCount > maxManifestProviders {
            Logger.shared.log(
                "Nuvio manifest advertises \(advertisedProviderCount) providers;"
                    + " keeping the first \(maxManifestProviders) and skipping the rest"
                    + " instead of failing the whole repository",
                type: "Plugin"
            )
        }
        let usableScrapers = NuvioPluginSupport.persistableManifestScrapers(
            Array(manifest.scrapers.prefix(maxManifestProviders))
        )
        guard !usableScrapers.isEmpty else {
            throw NuvioPluginError.repositoryInstallFailed(
                "The repository manifest contains duplicate, invalid, or over-limit provider metadata."
            )
        }
        var usableManifest = manifest
        usableManifest.scrapers = usableScrapers
        if usableScrapers.count != advertisedProviderCount {
            Logger.shared.log(
                "Nuvio manifest kept \(usableScrapers.count) of \(advertisedProviderCount) provider rows;"
                    + " the rest were duplicate, invalid, or over-limit and were skipped instead of"
                    + " failing the whole repository",
                type: "Plugin"
            )
        }
        return NuvioParsedPluginManifest(
            manifest: usableManifest,
            advertisedProviderCount: advertisedProviderCount
        )
    }

    private func isSupportedOnCurrentPlatform(_ info: NuvioPluginManifestScraper) -> Bool {
        let disabled = (info.disabledPlatforms ?? []).map { $0.lowercased() }
        if disabled.contains("ios") || disabled.contains("apple") { return false }
        guard let supported = info.supportedPlatforms, !supported.isEmpty else { return true }
        let normalized = supported.map { $0.lowercased() }
        return normalized.contains("ios") || normalized.contains("all") || normalized.contains("apple")
    }

    private func logRepositoryFetch(_ fetched: NuvioRepositoryFetch) {
        guard let status = providerStatus(forRepository: fetched.repository.id) else { return }
        Logger.shared.log(
            "Nuvio repository applied"
                + " advertised=\(status.advertisedProviderCount)"
                + " eligible=\(status.eligibleProviderCount)"
                + " installed=\(status.installedProviderCount)"
                + " pending=\(status.pendingProviderCount)"
                + " failed=\(status.failedProviderCount)"
                + " attempted=\(fetched.attemptedProviderKeys.count)",
            type: "Plugin"
        )
    }

    nonisolated private static func providerDownloadFailureToken(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "timeout"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
                    .notConnectedToInternet: return "unreachable"
            default: return "network"
            }
        }
        if NuvioPluginSupport.isUnreachableHostError(error) { return "unreachable" }
        let description = error.localizedDescription.lowercased()
        if description.contains("timed out") || description.contains("timeout") { return "timeout" }
        if description.contains("status ") { return "http-status" }
        if description.contains("exceeded") { return "oversized" }
        if description.contains("refused") || description.contains("blocked") { return "refused" }
        return "request"
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
        let requestURL = NuvioRepositoryRequestPolicy.requestURL(url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 30)
        configuration.httpAdditionalHeaders = ["User-Agent": URLSession.randomUserAgent]
        let session = URLSession(
            configuration: configuration,
            delegate: FetchDelegate(allowRedirects: true),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: HTTPURLResponse
        do {
            let result = try await session.boundedData(
                for: URLRequest(url: requestURL, timeoutInterval: timeout),
                maximumResponseBytes: maximumBytes
            )
            guard let httpResponse = result.1 as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            data = result.0
            response = httpResponse
        } catch is BoundedURLSessionError {
            throw NuvioPluginError.repositoryInstallFailed(
                "The \(kind) response exceeded Eclipse's \(maximumBytes)-byte limit."
            )
        }
        if !(200...299).contains(response.statusCode) {
            throw NuvioRepositoryHTTPFailure(
                statusCode: response.statusCode,
                retryAfterSeconds: NuvioManifestFetchRetryPolicy.retryAfterSeconds(
                    from: response.value(forHTTPHeaderField: "Retry-After")
                )
            )
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
        let vetted = Self.withCompatibleStreamsOnly(outcome)
        let name = scraper(withID: scraperID)?.displayName ?? scraperID
        Logger.shared.log(
            "Nuvio outcome provider=\(name) result=\(vetted.diagnosticToken) "
                + "streams=\(vetted.streams.count) blame=\(vetted.blame) "
                + "detail=\(vetted.displayMessage)",
            type: "Plugin"
        )
        return vetted
    }

    private static func withCompatibleStreamsOnly(
        _ outcome: NuvioProviderOutcome
    ) -> NuvioProviderOutcome {
        guard case .results(let streams) = outcome, !streams.isEmpty else { return outcome }
        let boundedStreams = NuvioSubtitleBoundary.boundedForNetworkValidation(streams)
        let originalSubtitleCount = streams.reduce(0) { $0 + ($1.subtitles?.count ?? 0) }
        let boundedSubtitleCount = boundedStreams.reduce(0) { $0 + ($1.subtitles?.count ?? 0) }

        var allowed: [NuvioPluginStream] = []
        allowed.reserveCapacity(boundedStreams.count)
        var rejectedSubtitles = originalSubtitleCount - boundedSubtitleCount
        for stream in boundedStreams {
            guard NuvioPluginSupport.isDirectHTTPURL(stream.url) else { continue }
            guard let subtitles = stream.subtitles, !subtitles.isEmpty else {
                allowed.append(stream)
                continue
            }
            let allowedSubtitles = subtitles.filter {
                NuvioPluginSupport.isDirectHTTPURL($0.url)
            }
            rejectedSubtitles += subtitles.count - allowedSubtitles.count
            allowed.append(stream.withSubtitles(allowedSubtitles.isEmpty ? nil : allowedSubtitles))
        }
        if rejectedSubtitles > 0 {
            Logger.shared.log(
                "Nuvio dropped \(rejectedSubtitles) malformed or unsupported subtitle track(s)",
                type: "Error"
            )
        }
        let rejected = boundedStreams.count - allowed.count
        guard rejected > 0 else {
            return rejectedSubtitles > 0 ? .results(allowed) : outcome
        }
        Logger.shared.log(
            "Nuvio dropped \(rejected) malformed or unsupported stream(s)",
            type: "Error"
        )

        guard !allowed.isEmpty else {
            return .unplayableOnly(count: rejected, kind: .unreadableLink)
        }
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
        guard !storedStateIsUnreadable else {
            return .appFailure("Nuvio's saved provider state is unreadable. Reset it before running providers.")
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
        guard store.hasCode(
            repositoryID: scraper.repositoryId,
            codeFileName: scraper.codeFileName
        ) else {
            return .notEnabled("This provider is waiting for its code download to finish.")
        }

        let normalizedType = NuvioPluginSupport.normalizeType(mediaType)
        guard scraper.supportsType(normalizedType) else {
            return .unsupportedMediaType(normalizedType == "movie" ? "movies" : "TV shows")
        }

#if os(iOS) && !targetEnvironment(macCatalyst)

        let scopeEpoch = ServiceStoreScope.generation
        let servicesProfileID = ProfileManager.shared.activeProfileID
        let sharesServices = ProfileSettingsStore.sharesServices
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
                scraperSettings: scraperSettings,
                servicesProfileID: servicesProfileID,
                sharesServices: sharesServices
            )
        } catch {
            return Self.classify(error: error)
        }

        Logger.shared.log(
            "Nuvio ledger provider=\(scraper.name) tmdb=\(tmdbId) type=\(normalizedType)"
                + " season=\(season.map(String.init) ?? "-") episode=\(episode.map(String.init) ?? "-")"
                + " rows=\(batch.streams.count) unplayable=\(batch.unplayableCount)"
                + " torrents=\(batch.torrentCount) unreadableURLs=\(batch.unreadableURLCount)"
                + " discarded=\(batch.discardedRowCount)"
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
                return .unplayableOnly(count: batch.unplayableCount, kind: batch.unplayableKind)
            }
            if batch.interference.blocksScraping {
                return .appFailure(
                    "Eclipse cut this provider's run short (\(batch.interference.blockingSummary))."
                )
            }
            if batch.discardedRowCount > 0 {
                return .providerError(
                    batch.discardedRowCount == 1
                        ? "It returned 1 result with no link Eclipse could read."
                        : "It returned \(batch.discardedRowCount) results with no link Eclipse could read."
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
        case .runtimeLimitExceeded(let message):
            return .appFailure(message)
        case .runtimeUnavailable:
            return .appFailure(pluginError.errorDescription ?? "Eclipse could not run this provider.")
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
        case "Invalid fetch URL.":
            return "The plugin requested an address Eclipse cannot open."
        default:
            return trimmed
        }
    }

    func settingsValues(scraperID: String) -> [String: NuvioSettingsValue] {
        guard !storedStateIsUnreadable else { return [:] }
        return state.scraperSettings[scraperID] ?? [:]
    }

    func setSettingsValue(_ value: NuvioSettingsValue?, forKey key: String, scraperID: String) {
        guard Self.isFeatureAvailable,
              canAdministerPlugins,
              !store.stateWritesSuspended,
              !key.isEmpty,
              key.count <= NuvioPluginStore.Bounds.textLength else { return }
        var candidate = state
        var values = candidate.scraperSettings[scraperID] ?? [:]
        if let value = value?.sanitizedForPersistence {
            if case .string(let text) = value,
               text.count > NuvioPluginStore.Bounds.settingValueLength {
                return
            }
            guard values[key] != nil
                    || values.count < NuvioPluginStore.Bounds.settingsKeysPerScraper else {
                return
            }
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        candidate.scraperSettings[scraperID] = values.isEmpty ? nil : values
        _ = commitState(candidate)
    }

    func settingsFields(scraperID: String) async throws -> [NuvioSettingsField] {
        guard Self.isFeatureAvailable else { throw NuvioPluginError.unavailable }
        guard !storedStateIsUnreadable else { throw NuvioPluginError.storedStateUnreadable }
        guard let scraper = state.scrapers.first(where: { $0.id == scraperID }) else {
            throw NuvioPluginError.providerNotFound
        }
#if os(iOS) && !targetEnvironment(macCatalyst)

        let scopeEpoch = ServiceStoreScope.generation
        let servicesProfileID = ProfileManager.shared.activeProfileID
        let sharesServices = ProfileSettingsStore.sharesServices
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
            scraperSettings: scraperSettings,
            servicesProfileID: servicesProfileID,
            sharesServices: sharesServices
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
        guard Self.isFeatureAvailable, !store.stateWritesSuspended else { return nil }
        var copy = state
        copy.repositories = copy.repositories.map {
            var repository = $0
            repository.isRefreshing = false
            repository.errorMessage = nil
            return repository
        }
        let bounded = NuvioPluginStore.bounded(copy)
        return bounded.wasBounded ? nil : bounded.state
    }

    @discardableResult
    func restoreBackupState(
        _ restored: NuvioStoredPluginsState,
        expectedScopeGeneration: Int? = nil
    ) async -> NuvioCodeRepairResult {
        guard Self.isFeatureAvailable else {
            return NuvioCodeRepairResult(
                readiness: NuvioCodeReadiness(),
                attemptedRepositoryIDs: [],
                wasInterrupted: false
            )
        }
        let scopeEpoch = expectedScopeGeneration ?? ServiceStoreScope.generation
        guard ServiceStoreScope.isCurrent(scopeEpoch) else {
            return NuvioCodeRepairResult(
                readiness: codeReadiness,
                attemptedRepositoryIDs: [],
                wasInterrupted: true
            )
        }
        let previousRepositoryIDs = Set(state.repositories.map(\.id))
        guard let sanitized = validatedRestoredState(restored) else {
            return NuvioCodeRepairResult(
                readiness: codeReadiness,
                attemptedRepositoryIDs: [],
                wasInterrupted: false
            )
        }
        let repositoryIDs = Set(sanitized.repositories.map(\.id))
        let incomingScraperIDs = Set(sanitized.scrapers.map(\.id))
        let droppedRepositoryIDs = previousRepositoryIDs.subtracting(repositoryIDs)

        let restoredRepairLedger = NuvioPluginStore.boundedRepairLedger(
            repairLedger,
            validRepositoryIDs: repositoryIDs
        )
        guard store.replaceStateAuthoritatively(sanitized) else {
            storedStateIsUnreadable = store.stateWritesSuspended
            return NuvioCodeRepairResult(
                readiness: codeReadiness,
                attemptedRepositoryIDs: [],
                wasInterrupted: false
            )
        }
        state = sanitized
        repairLedger = restoredRepairLedger
        storedStateIsUnreadable = false
        persistRepairLedger()

        let defaults = ProfileSettingsStore.services
        var configuredSourceIDs = AutoModeSourceSelection.selectedSourceIds(defaults: defaults)
        configuredSourceIDs.formUnion(
            AutoModeSourceSelection.sourceOrderIds(defaults: defaults)
        )
        configuredSourceIDs.formUnion(
            StreamLanguageFilter.extraRulesSourceIds(defaults: defaults) ?? []
        )
        for sourceID in configuredSourceIDs
        where NuvioPluginSupport.isSourceID(sourceID)
            && !incomingScraperIDs.contains(sourceID) {
            AutoModeSourceSelection.removeSourceAuthoritatively(
                sourceID,
                defaults: defaults
            )
        }
        let repair = await repairMissingCodeAfterRestore(
            reason: "typed-backup-restore",
            expectedScopeGeneration: scopeEpoch
        )
        guard ServiceStoreScope.isCurrent(scopeEpoch), !Task.isCancelled else {
            return NuvioCodeRepairResult(
                readiness: repair.readiness,
                attemptedRepositoryIDs: repair.attemptedRepositoryIDs,
                wasInterrupted: true,
                restoreWasPersisted: true
            )
        }
        for scraper in activeScrapers {
            AutoModeSourceSelection.enrollSourceOnFirstAvailability(scraper.id)
        }
        Logger.shared.log(
            "Nuvio restore metadata applied repositories=\(sanitized.repositories.count)"
                + " codeReady=\(repair.readiness.readyProviderCount)"
                + " codePending=\(repair.readiness.pendingProviderCount)"
                + " repositoriesPending=\(repair.readiness.pendingRepositoryIDs.count)",
            type: "Plugin"
        )
        for droppedID in droppedRepositoryIDs {
            store.removeRepositoryCode(repositoryID: droppedID)
        }
        return NuvioCodeRepairResult(
            readiness: repair.readiness,
            attemptedRepositoryIDs: repair.attemptedRepositoryIDs,
            wasInterrupted: repair.wasInterrupted,
            restoreWasPersisted: true
        )
    }

    private func validatedRestoredState(
        _ restored: NuvioStoredPluginsState
    ) -> NuvioStoredPluginsState? {
        let bounded = NuvioPluginStore.bounded(restored)
        guard !bounded.wasBounded else {
            Logger.shared.log(
                "Nuvio refused an incomplete backup snapshot with invalid or over-limit entries",
                type: "Plugin"
            )
            return nil
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

    let eligibleProviderKeys: Set<String>

    let attemptedProviderKeys: Set<String>

    let failedProviderKeys: Set<String>
}

private enum NuvioRepositoryFetchStrategy: Equatable {
    case full
    case repair
}

private struct NuvioParsedPluginManifest {
    let manifest: NuvioPluginManifest
    let advertisedProviderCount: Int
}

private struct NuvioProviderDownloadResult: Sendable {
    let code: String?
    let failureToken: String?
}

struct NuvioInstallProgress: Equatable {
    let label: String
    let completed: Int
    let total: Int

    var fractionCompleted: Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 0
    }
}
