import Foundation

final class NuvioPluginStore {
    static let shared = NuvioPluginStore()

    private let stateKey = "nuvioPluginsState.v2"
    private let legacyStateKey = "nuvioPluginsState.v1"
    private let repairLedgerKeyBase = "provider.nuvioRepositoryRepairLedger.v1"

    private let injectedDefaults: UserDefaults?
    private var defaults: UserDefaults { injectedDefaults ?? ProfileSettingsStore.services }
    private var repairDefaults: UserDefaults { injectedDefaults ?? ProfileSettingsStore.device }
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "app.eclipse.soupy.nuvio-plugin-store", qos: .utility)
    private(set) var stateWritesSuspended = false

    init(defaults: UserDefaults? = nil) {
        self.injectedDefaults = defaults
    }

    func load() -> NuvioStoredPluginsState {
        guard let storedValue = defaults.object(forKey: stateKey) else {
            stateWritesSuspended = false
            return NuvioStoredPluginsState()
        }
        guard let data = storedValue as? Data,
              let decoded = Self.decodePersistedState(data) else {
            stateWritesSuspended = true
            Logger.shared.log(
                "Nuvio stored state is invalid or oversized; preserving its bytes and blocking mutations",
                type: "Plugin"
            )
            return NuvioStoredPluginsState()
        }
        let bounded = Self.bounded(decoded)
        guard !bounded.wasBounded else {
            stateWritesSuspended = true
            Logger.shared.log(
                "Nuvio stored state has invalid or over-limit entries; preserving its bytes and blocking mutations",
                type: "Plugin"
            )
            return bounded.state
        }
        stateWritesSuspended = false
        return bounded.state
    }

    @discardableResult
    func save(_ state: NuvioStoredPluginsState) -> Bool {
        save(state, to: currentDestination())
    }

    struct Destination {
        fileprivate let defaults: UserDefaults
    }

    func currentDestination() -> Destination {
        Destination(defaults: defaults)
    }

    func canSave(_ state: NuvioStoredPluginsState) -> Bool {
        canSave(state, to: currentDestination())
    }

    func canSave(_ state: NuvioStoredPluginsState, to destination: Destination) -> Bool {
        !stateWritesSuspended
            && Self.destinationContainsReadableState(destination.defaults, stateKey: stateKey)
            && Self.persistableStateData(state) != nil
    }

    @discardableResult
    func save(_ state: NuvioStoredPluginsState, to destination: Destination) -> Bool {
        guard !stateWritesSuspended,
              Self.destinationContainsReadableState(destination.defaults, stateKey: stateKey) else {
            Logger.shared.log(
                "Nuvio refused to overwrite an unreadable stored-state snapshot",
                type: "Plugin"
            )
            return false
        }
        guard let data = Self.persistableStateData(state) else {
            Logger.shared.log("Nuvio refused an incomplete or oversized stored-state snapshot", type: "Plugin")
            return false
        }
        return Self.writePersistedStateData(data, to: destination.defaults, stateKey: stateKey)
    }

    @discardableResult
    func replaceStateAuthoritatively(_ state: NuvioStoredPluginsState) -> Bool {
        guard let data = Self.persistableStateData(state) else {
            Logger.shared.log("Nuvio refused an incomplete or oversized authoritative stored-state snapshot", type: "Plugin")
            return false
        }
        guard Self.writePersistedStateData(data, to: defaults, stateKey: stateKey) else { return false }
        stateWritesSuspended = false
        return true
    }

    func resetStateAuthoritatively() {
        stateWritesSuspended = false
        defaults.removeObject(forKey: stateKey)
        defaults.removeObject(forKey: legacyStateKey)
    }

    func loadRepairLedger(validRepositoryIDs: Set<String>) -> NuvioRepositoryRepairLedger {
        guard let data = repairDefaults.data(forKey: repairLedgerKey),
              data.count <= Bounds.repairLedgerBytes,
              let decoded = try? JSONDecoder().decode(NuvioRepositoryRepairLedger.self, from: data) else {
            return NuvioRepositoryRepairLedger()
        }
        return Self.boundedRepairLedger(decoded, validRepositoryIDs: validRepositoryIDs)
    }

    func loadRepairLedgerPreservingRepositoryIDs() -> NuvioRepositoryRepairLedger {
        guard let data = repairDefaults.data(forKey: repairLedgerKey),
              data.count <= Bounds.repairLedgerBytes,
              let decoded = try? JSONDecoder().decode(NuvioRepositoryRepairLedger.self, from: data) else {
            return NuvioRepositoryRepairLedger()
        }
        let repositoryIDs = Set(decoded.failedProviderKeysByRepository.keys.filter {
            NuvioPluginSupport.isSourceID($0) && $0.count <= Bounds.textLength
        })
        return Self.boundedRepairLedger(decoded, validRepositoryIDs: repositoryIDs)
    }

    func saveRepairLedger(
        _ ledger: NuvioRepositoryRepairLedger,
        validRepositoryIDs: Set<String>
    ) {
        let bounded = Self.boundedRepairLedger(ledger, validRepositoryIDs: validRepositoryIDs)
        guard !bounded.isEmpty else {
            repairDefaults.removeObject(forKey: repairLedgerKey)
            return
        }
        guard let data = try? JSONEncoder().encode(bounded),
              data.count <= Bounds.repairLedgerBytes else {
            Logger.shared.log("Nuvio refused an oversized provider repair ledger", type: "Plugin")
            return
        }
        repairDefaults.set(data, forKey: repairLedgerKey)
    }

    private var repairLedgerKey: String {
        if injectedDefaults != nil { return repairLedgerKeyBase + ".injected" }
        return repairLedgerKeyBase + "." + Self.repairLedgerScopeToken(
            profileID: ProfileManager.shared.activeProfileID,
            sharesServices: ProfileSettingsStore.sharesServices
        )
    }

    static func repairLedgerScopeToken(profileID: UUID, sharesServices: Bool) -> String {
        sharesServices ? "shared" : ProfileScopedStorage.token(for: profileID)
    }

    func purgeLegacyState() {
        guard !stateWritesSuspended else { return }
        guard defaults.object(forKey: legacyStateKey) != nil else { return }
        defaults.removeObject(forKey: legacyStateKey)
    }

    enum Bounds {
        static let persistedStateBytes = 4 * 1_024 * 1_024
        static let repairLedgerBytes = 256 * 1_024
        static let codeBytes = 8 * 1_024 * 1_024
        static let repositories = 100
        static let scrapersPerRepository = 200
        static let advertisedProviders = 100_000
        static let settingsKeysPerScraper = 100

        static let textLength = 2_048

        static let settingValueLength = 8 * 1_024

        static let supportedTypes = 32
        static let contentLanguages = 64
        static let formats = 64
        static let tokenLength = 128
    }

    static func persistedStateDataIsWithinLimit(_ data: Data) -> Bool {
        data.count <= Bounds.persistedStateBytes
    }

    static func codeFileMetadataIsWithinLimit(size: UInt64, isRegularFile: Bool) -> Bool {
        isRegularFile && size <= UInt64(Bounds.codeBytes)
    }

    static func boundedRepairLedger(
        _ ledger: NuvioRepositoryRepairLedger,
        validRepositoryIDs: Set<String>
    ) -> NuvioRepositoryRepairLedger {
        var bounded = NuvioRepositoryRepairLedger()
        for repositoryID in ledger.failedProviderKeysByRepository.keys.sorted() {
            guard bounded.failedProviderKeysByRepository.count < Bounds.repositories,
                  validRepositoryIDs.contains(repositoryID),
                  NuvioPluginSupport.isSourceID(repositoryID),
                  repositoryID.count <= Bounds.textLength else {
                continue
            }
            var accepted: [String] = []
            var seen = Set<String>()
            for providerKey in ledger.failedProviderKeysByRepository[repositoryID] ?? [] {
                guard accepted.count < Bounds.scrapersPerRepository,
                      !providerKey.isEmpty,
                      providerKey.count <= Bounds.textLength,
                      seen.insert(providerKey).inserted else {
                    continue
                }
                accepted.append(providerKey)
            }
            if !accepted.isEmpty {
                bounded.failedProviderKeysByRepository[repositoryID] = accepted.sorted()
            }
        }
        return bounded
    }

    private static func decodePersistedState(_ data: Data) -> NuvioStoredPluginsState? {
        guard persistedStateDataIsWithinLimit(data) else { return nil }
        return try? JSONDecoder().decode(NuvioStoredPluginsState.self, from: data)
    }

    private static func persistableStateData(_ state: NuvioStoredPluginsState) -> Data? {
        let bounded = bounded(state)
        guard !bounded.wasBounded,
              let data = try? JSONEncoder().encode(bounded.state),
              persistedStateDataIsWithinLimit(data) else {
            return nil
        }
        return data
    }

    private static func destinationContainsReadableState(
        _ defaults: UserDefaults,
        stateKey: String
    ) -> Bool {
        guard let storedValue = defaults.object(forKey: stateKey) else { return true }
        guard let data = storedValue as? Data,
              let state = decodePersistedState(data) else { return false }
        return !bounded(state).wasBounded
    }

    private static func writePersistedStateData(
        _ data: Data,
        to defaults: UserDefaults,
        stateKey: String
    ) -> Bool {
        let previous = defaults.object(forKey: stateKey)
        defaults.set(data, forKey: stateKey)
        guard defaults.data(forKey: stateKey) == data else {
            if let previous {
                defaults.set(previous, forKey: stateKey)
            } else {
                defaults.removeObject(forKey: stateKey)
            }
            return false
        }
        return true
    }

    struct BoundedState {
        var state: NuvioStoredPluginsState
        var droppedCount: Int
        var truncatedCount: Int

        var wasBounded: Bool { droppedCount > 0 || truncatedCount > 0 }
    }

    static func bounded(_ state: NuvioStoredPluginsState) -> BoundedState {
        var droppedCount = 0
        var truncatedCount = 0

        var repositories: [NuvioPluginRepository] = []
        var seenRepositoryIDs = Set<String>()
        for repository in state.repositories {
            guard repositories.count < Bounds.repositories,
                  NuvioPluginSupport.isSourceID(repository.id),
                  repository.id.count <= Bounds.textLength,
                  !repository.manifestUrl.isEmpty,
                  repository.manifestUrl.count <= Bounds.textLength,
                  seenRepositoryIDs.insert(repository.id).inserted else {
                droppedCount += 1
                continue
            }
            var bounded = repository
            bounded.name = boundedText(bounded.name, truncated: &truncatedCount)
            bounded.description = bounded.description.map { boundedText($0, truncated: &truncatedCount) }
            bounded.version = bounded.version.map { boundedText($0, truncated: &truncatedCount) }
            let boundedScraperCount = min(max(bounded.scraperCount, 0), Bounds.scrapersPerRepository)
            if boundedScraperCount != bounded.scraperCount { truncatedCount += 1 }
            bounded.scraperCount = boundedScraperCount
            if let inventory = bounded.providerInventory {
                let eligible = min(
                    max(inventory.eligibleProviderCount, 0),
                    Bounds.scrapersPerRepository
                )
                let advertised = min(
                    max(inventory.advertisedProviderCount, eligible),
                    Bounds.advertisedProviders
                )
                if eligible != inventory.eligibleProviderCount
                    || advertised != inventory.advertisedProviderCount {
                    truncatedCount += 1
                }
                bounded.providerInventory = NuvioRepositoryProviderInventory(
                    advertisedProviderCount: advertised,
                    eligibleProviderCount: eligible
                )
            }
            bounded.isRefreshing = false
            bounded.errorMessage = nil
            repositories.append(bounded)
        }

        let acceptedRepositoryIDs = Set(repositories.map(\.id))
        var scrapers: [NuvioPluginScraper] = []
        var seenScraperIDs = Set<String>()
        var countByRepository: [String: Int] = [:]
        for scraper in state.scrapers {
            guard acceptedRepositoryIDs.contains(scraper.repositoryId),
                  NuvioPluginSupport.isSourceID(scraper.id),
                  countByRepository[scraper.repositoryId, default: 0] < Bounds.scrapersPerRepository,
                  hasBoundedIdentity(scraper),
                  seenScraperIDs.insert(scraper.id).inserted else {
                droppedCount += 1
                continue
            }
            countByRepository[scraper.repositoryId, default: 0] += 1
            scrapers.append(boundedDisplayText(scraper, truncated: &truncatedCount))
        }

        let acceptedScraperIDs = Set(scrapers.map(\.id))
        var scraperSettings: [String: [String: NuvioSettingsValue]] = [:]
        for (scraperID, values) in state.scraperSettings {
            guard acceptedScraperIDs.contains(scraperID) else {
                droppedCount += 1
                continue
            }
            var bounded: [String: NuvioSettingsValue] = [:]

            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                guard bounded.count < Bounds.settingsKeysPerScraper,
                      !key.isEmpty,
                      key.count <= Bounds.textLength else {
                    droppedCount += 1
                    continue
                }
                guard let value = value.sanitizedForPersistence else {
                    droppedCount += 1
                    continue
                }
                if case .string(let text) = value, text.count > Bounds.settingValueLength {
                    bounded[key] = .string(String(text.prefix(Bounds.settingValueLength)))
                    truncatedCount += 1
                } else {
                    bounded[key] = value
                }
            }
            guard !bounded.isEmpty else { continue }
            scraperSettings[scraperID] = bounded
        }

        return BoundedState(
            state: NuvioStoredPluginsState(
                pluginsEnabled: state.pluginsEnabled,
                repositories: repositories,
                scrapers: scrapers,
                scraperSettings: scraperSettings
            ),
            droppedCount: droppedCount,
            truncatedCount: truncatedCount
        )
    }

    private static func hasBoundedIdentity(_ scraper: NuvioPluginScraper) -> Bool {
        let identifiers = [
            scraper.id,
            scraper.providerKey,
            scraper.repositoryId,
            scraper.repositoryUrl,
            scraper.filename,
            scraper.codeFileName
        ]
        guard identifiers.allSatisfy({ $0.count <= Bounds.textLength }) else { return false }
        guard scraper.supportedTypes.count <= Bounds.supportedTypes,
              scraper.contentLanguage.count <= Bounds.contentLanguages,
              (scraper.formats?.count ?? 0) <= Bounds.formats else {
            return false
        }
        let tokens = scraper.supportedTypes + scraper.contentLanguage + (scraper.formats ?? [])
        return tokens.allSatisfy { $0.count <= Bounds.tokenLength }
    }

    private static func boundedDisplayText(
        _ scraper: NuvioPluginScraper,
        truncated: inout Int
    ) -> NuvioPluginScraper {
        let before = truncated
        let name = boundedText(scraper.name, truncated: &truncated)
        let description = boundedText(scraper.description, truncated: &truncated)
        let author = scraper.author.map { boundedText($0, truncated: &truncated) }
        let version = boundedText(scraper.version, truncated: &truncated)

        var logo = scraper.logo
        if let value = logo, value.count > Bounds.textLength {
            logo = nil
            truncated += 1
        }
        guard truncated > before else { return scraper }
        return NuvioPluginScraper(
            id: scraper.id,
            providerKey: scraper.providerKey,
            repositoryId: scraper.repositoryId,
            repositoryUrl: scraper.repositoryUrl,
            name: name,
            description: description,
            author: author,
            version: version,
            filename: scraper.filename,
            codeFileName: scraper.codeFileName,
            supportedTypes: scraper.supportedTypes,
            enabled: scraper.enabled,
            manifestEnabled: scraper.manifestEnabled,
            declaresSettings: scraper.declaresSettings,
            logo: logo,
            contentLanguage: scraper.contentLanguage,
            formats: scraper.formats
        )
    }

    private static func boundedText(_ value: String, truncated: inout Int) -> String {
        guard value.count > Bounds.textLength else { return value }
        truncated += 1
        return String(value.prefix(Bounds.textLength))
    }

    private var rootDirectory: URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("NuvioPlugins", isDirectory: true)
    }

    private func directory(forRepositoryID repositoryID: String) -> URL? {
        guard let rootDirectory else { return nil }
        let folder = repositoryID.replacingOccurrences(of: NuvioPluginSupport.sourceIDPrefix, with: "")
        guard !folder.isEmpty, folder.allSatisfy({ $0.isHexDigit }) else { return nil }
        return rootDirectory.appendingPathComponent(folder, isDirectory: true)
    }

    private func ensureRootDirectory() throws -> URL {
        guard var root = rootDirectory else {
            throw NuvioPluginError.repositoryInstallFailed("Application Support is unavailable.")
        }
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
        }
        return root
    }

    private static func isSafePathComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        guard name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        return true
    }

    static func codeFileName(forScraperID scraperID: String, code: String) -> String {
        String(scraperID.sha256.prefix(40)) + "-" + String(code.sha256.prefix(32)) + ".js"
    }

    func writeCode(_ code: String, repositoryID: String, scraperID: String) throws -> String {
        let codeData = Data(code.utf8)
        guard !codeData.isEmpty, codeData.count <= Bounds.codeBytes else {
            throw NuvioPluginError.repositoryInstallFailed("Plugin code exceeds the storage limit.")
        }
        let codeFileName = Self.codeFileName(forScraperID: scraperID, code: code)
        guard Self.isSafePathComponent(codeFileName) else {
            throw NuvioPluginError.repositoryInstallFailed("Invalid plugin code filename.")
        }
        guard let directory = directory(forRepositoryID: repositoryID) else {
            throw NuvioPluginError.repositoryInstallFailed("Invalid plugin storage location.")
        }

        try ioQueue.sync {
            _ = try ensureRootDirectory()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let destination = directory.appendingPathComponent(codeFileName, isDirectory: false)
            try replaceCodeFileIfNeeded(codeData, at: destination)
        }
        return codeFileName
    }

    private func replaceCodeFileIfNeeded(_ data: Data, at destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            if boundedCodeData(at: destination) == data { return }
            try fileManager.removeItem(at: destination)
        }
        try data.write(to: destination, options: .atomic)
        guard boundedCodeData(at: destination) == data else {
            throw NuvioPluginError.repositoryInstallFailed("Plugin code could not be verified after writing.")
        }
    }

    private func boundedCodeData(at source: URL) -> Data? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: source.path),
              let fileType = attributes[.type] as? FileAttributeType,
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value > 0,
              Self.codeFileMetadataIsWithinLimit(
                  size: fileSize.uint64Value,
                  isRegularFile: fileType == .typeRegular
              ),
              let handle = try? FileHandle(forReadingFrom: source) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Bounds.codeBytes + 1),
              data.count <= Bounds.codeBytes else {
            return nil
        }
        return data
    }

    func readCode(
        repositoryID: String,
        codeFileName: String,
        expectedScraperID: String? = nil
    ) -> String? {
        guard Self.isSafePathComponent(codeFileName),
              let directory = directory(forRepositoryID: repositoryID) else { return nil }
        let source = directory.appendingPathComponent(codeFileName, isDirectory: false)
        guard let data = boundedCodeData(at: source),
              Self.codeData(
                data,
                matchesHashedFileName: codeFileName,
                expectedScraperID: expectedScraperID
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func readCodeInBackground(
        repositoryID: String,
        codeFileName: String,
        expectedScraperID: String? = nil
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: self.readCode(
                        repositoryID: repositoryID,
                        codeFileName: codeFileName,
                        expectedScraperID: expectedScraperID
                    )
                )
            }
        }
    }

    func hasCode(repositoryID: String, codeFileName: String) -> Bool {
        usableCodeFileURL(
            repositoryID: repositoryID,
            codeFileName: codeFileName
        ) != nil
    }

    private func usableCodeFileURL(
        repositoryID: String,
        codeFileName: String
    ) -> URL? {
        guard Self.isSafePathComponent(codeFileName) else { return nil }
        guard let directory = directory(forRepositoryID: repositoryID) else { return nil }
        let source = directory.appendingPathComponent(codeFileName, isDirectory: false)
        guard let data = boundedCodeData(at: source),
              Self.codeData(data, matchesHashedFileName: codeFileName) else { return nil }
        return source
    }

    private static func codeData(
        _ data: Data,
        matchesHashedFileName codeFileName: String,
        expectedScraperID: String? = nil
    ) -> Bool {
        guard codeFileName.hasSuffix(".js") else { return false }
        let stem = codeFileName.dropLast(3)
        let pieces = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              pieces[0].count == 40,
              pieces[1].count == 32,
              pieces.allSatisfy({ $0.allSatisfy(\.isHexDigit) }),
              let code = String(data: data, encoding: .utf8) else {
            return false
        }
        if let expectedScraperID,
           String(expectedScraperID.sha256.prefix(40)) != pieces[0] {
            Logger.shared.log(
                "Nuvio refused provider code whose stored name belongs to a different provider expected=\(String(expectedScraperID.sha256.prefix(40))) named=\(pieces[0]); the code is not executed, so this provider stays unavailable by Eclipse's rule",
                type: "Plugin"
            )
            return false
        }
        return String(code.sha256.prefix(32)) == pieces[1]
    }

    func removeRepositoryCode(
        repositoryID: String,
        ownedBy _: UUID? = nil
    ) {
        guard let directory = directory(forRepositoryID: repositoryID) else { return }
        guard let servicesScopes = persistedServicesScopes(),
              let repositoryIsReferenced = Self.repositoryIsReferenced(
                  repositoryID: repositoryID,
                  in: servicesScopes,
                  stateKey: stateKey
              ) else {
            Logger.shared.log(
                "Nuvio kept repository code because a Services scope is unreadable",
                type: "Plugin"
            )
            return
        }
        guard !repositoryIsReferenced else {
            Logger.shared.log(
                "Nuvio kept the code for \(repositoryID): a Services scope still has it installed",
                type: "Plugin"
            )
            return
        }
        ioQueue.async { [fileManager] in
            try? fileManager.removeItem(at: directory)
        }
    }

    static func repositoryIsReferenced(
        repositoryID: String,
        in defaultsScopes: [UserDefaults],
        stateKey: String = "nuvioPluginsState.v2"
    ) -> Bool? {
        var isReferenced = false
        for store in defaultsScopes {
            guard let storedValue = store.object(forKey: stateKey) else { continue }
            guard let data = storedValue as? Data,
                  let state = Self.decodePersistedState(data),
                  !Self.bounded(state).wasBounded else { return nil }
            if state.repositories.contains(where: { $0.id == repositoryID }) {
                isReferenced = true
            }
        }
        return isReferenced
    }

    func pruneCode(
        repositoryID: String,
        keeping codeFileNames: Set<String>,
        ownedBy _: UUID? = nil
    ) {
        guard let directory = directory(forRepositoryID: repositoryID) else { return }
        guard let servicesScopes = persistedServicesScopes(),
              let referencedCodeFileNames = Self.referencedCodeFileNames(
                  repositoryID: repositoryID,
                  in: servicesScopes,
                  stateKey: stateKey
              ) else {
            Logger.shared.log(
                "Nuvio kept repository code because a Services scope is unreadable",
                type: "Plugin"
            )
            return
        }
        let retained = codeFileNames.union(referencedCodeFileNames)
        ioQueue.async { [fileManager] in
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
            for name in contents where !retained.contains(name) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    static func referencedCodeFileNames(
        repositoryID: String,
        in defaultsScopes: [UserDefaults],
        stateKey: String = "nuvioPluginsState.v2"
    ) -> Set<String>? {
        var result: Set<String> = []
        for store in defaultsScopes {
            guard let storedValue = store.object(forKey: stateKey) else { continue }
            guard let data = storedValue as? Data,
                  let state = Self.decodePersistedState(data) else { return nil }
            let bounded = Self.bounded(state)
            guard !bounded.wasBounded else { return nil }
            for scraper in bounded.state.scrapers where scraper.repositoryId == repositoryID {
                result.insert(scraper.codeFileName)
            }
        }
        return result
    }

    private func persistedServicesScopes() -> [UserDefaults]? {
        if let injectedDefaults { return [injectedDefaults] }
        let manager = ProfileManager.shared
        guard manager.rosterStoreIsReadable else { return nil }

        var scopes = [UserDefaults.standard]
        var identifiers = Set(["standard"])
        for profile in manager.profiles where profile.id != ProfileManager.defaultProfileID {
            let suiteName = ProfileSettingsStore.suiteName(for: profile.id)
            guard identifiers.insert(suiteName).inserted else { continue }
            guard let store = UserDefaults(suiteName: suiteName) else { return nil }
            scopes.append(store)
        }
        return scopes
    }

    func removeAllCode() {
        guard let rootDirectory else { return }
        ioQueue.async { [fileManager] in
            try? fileManager.removeItem(at: rootDirectory)
        }
    }

    func codeSizeBytes() -> Int64 {
        guard let rootDirectory,
              let enumerator = fileManager.enumerator(
                at: rootDirectory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
