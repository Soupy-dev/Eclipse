import Foundation

final class NuvioPluginStore {
    static let shared = NuvioPluginStore()

    private let stateKey = "nuvioPluginsState.v2"
    private let legacyStateKey = "nuvioPluginsState.v1"

    private let injectedDefaults: UserDefaults?
    private var defaults: UserDefaults { injectedDefaults ?? ProfileSettingsStore.services }
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "app.eclipse.soupy.nuvio-plugin-store", qos: .utility)

    init(defaults: UserDefaults? = nil) {
        self.injectedDefaults = defaults
    }

    func load() -> NuvioStoredPluginsState {
        guard let data = defaults.data(forKey: stateKey) else {
            return NuvioStoredPluginsState()
        }
        do {
            return sanitized(try JSONDecoder().decode(NuvioStoredPluginsState.self, from: data))
        } catch {
            Logger.shared.log(
                "Nuvio stored state could not be decoded; installed providers were reset: \(error.localizedDescription)",
                type: "Plugin"
            )
            return NuvioStoredPluginsState()
        }
    }

    func save(_ state: NuvioStoredPluginsState) {
        save(state, to: currentDestination())
    }

    struct Destination {
        fileprivate let defaults: UserDefaults
    }

    func currentDestination() -> Destination {
        Destination(defaults: defaults)
    }

    func save(_ state: NuvioStoredPluginsState, to destination: Destination) {
        guard let data = try? JSONEncoder().encode(sanitized(state)) else { return }
        destination.defaults.set(data, forKey: stateKey)
    }

    func purgeLegacyState() {
        guard defaults.object(forKey: legacyStateKey) != nil else { return }
        defaults.removeObject(forKey: legacyStateKey)
    }

    private func sanitized(_ state: NuvioStoredPluginsState) -> NuvioStoredPluginsState {
        let bounded = Self.bounded(state)
        if bounded.wasBounded {
            Logger.shared.log(
                "Nuvio bounded a stored snapshot: dropped \(bounded.droppedCount) entr(ies), "
                    + "truncated \(bounded.truncatedCount) value(s)",
                type: "Plugin"
            )
        }
        return bounded.state
    }

    enum Bounds {
        static let repositories = 100
        static let scrapersPerRepository = 200
        static let settingsKeysPerScraper = 100

        static let textLength = 2_048

        static let settingValueLength = 8 * 1_024

        static let supportedTypes = 32
        static let contentLanguages = 64
        static let formats = 64
        static let tokenLength = 128
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

            guard !fileManager.fileExists(atPath: destination.path) else { return }
            try Data(code.utf8).write(to: destination, options: .atomic)
        }
        return codeFileName
    }

    func writeLegacyNamedCode(_ code: String, repositoryID: String, scraperID: String) throws {
        let codeFileName = NuvioPluginSupport.codeFileName(forScraperID: scraperID)
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
            guard !fileManager.fileExists(atPath: destination.path) else { return }
            try Data(code.utf8).write(to: destination, options: .atomic)
        }
    }

    func readCode(repositoryID: String, codeFileName: String) -> String? {
        guard Self.isSafePathComponent(codeFileName) else { return nil }
        guard let directory = directory(forRepositoryID: repositoryID) else { return nil }
        let source = directory.appendingPathComponent(codeFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: source) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func readCodeInBackground(repositoryID: String, codeFileName: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: self.readCode(repositoryID: repositoryID, codeFileName: codeFileName)
                )
            }
        }
    }

    func hasCode(repositoryID: String, codeFileName: String) -> Bool {
        guard Self.isSafePathComponent(codeFileName) else { return false }
        guard let directory = directory(forRepositoryID: repositoryID) else { return false }
        return fileManager.fileExists(atPath: directory.appendingPathComponent(codeFileName).path)
    }

    func removeRepositoryCode(
        repositoryID: String,
        ownedBy owner: UUID? = nil
    ) {
        guard let directory = directory(forRepositoryID: repositoryID) else { return }

        guard !isRepositoryInstalledByAnotherProfile(
            repositoryID: repositoryID,
            excluding: owner ?? ProfileManager.shared.activeProfileID
        ) else {
            Logger.shared.log(
                "Nuvio kept the code for \(repositoryID): another profile still has it installed",
                type: "Plugin"
            )
            return
        }
        ioQueue.async { [fileManager] in
            try? fileManager.removeItem(at: directory)
        }
    }

    private func isRepositoryInstalledByAnotherProfile(
        repositoryID: String,
        excluding owner: UUID
    ) -> Bool {
        guard injectedDefaults == nil, !ProfileSettingsStore.sharesServices else { return false }
        for profile in ProfileManager.shared.profiles where profile.id != owner {
            let store = ProfileSettingsStore.shared.store(for: profile.id)
            guard let data = store.data(forKey: stateKey),
                  let state = try? JSONDecoder().decode(NuvioStoredPluginsState.self, from: data) else {
                continue
            }
            if state.repositories.contains(where: { $0.id == repositoryID }) { return true }
        }
        return false
    }

    func pruneCode(
        repositoryID: String,
        keeping codeFileNames: Set<String>,
        ownedBy owner: UUID? = nil
    ) {
        guard let directory = directory(forRepositoryID: repositoryID) else { return }

        let resolvedOwner = owner ?? ProfileManager.shared.activeProfileID

        let retained = codeFileNames
            .union(codeFileNamesInstalledByProfile(
                repositoryID: repositoryID,
                profileID: resolvedOwner
            ))
            .union(codeFileNamesInstalledByOtherProfiles(
                repositoryID: repositoryID,
                excluding: resolvedOwner
            ))
        ioQueue.async { [fileManager] in
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
            for name in contents where !retained.contains(name) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    private func codeFileNamesInstalledByProfile(
        repositoryID: String,
        profileID: UUID
    ) -> Set<String> {
        let store: UserDefaults
        if let injectedDefaults {
            store = injectedDefaults
        } else if ProfileSettingsStore.sharesServices
                    || profileID == ProfileManager.defaultProfileID {
            store = UserDefaults.standard
        } else {
            store = ProfileSettingsStore.shared.store(for: profileID)
        }
        guard let data = store.data(forKey: stateKey),
              let decoded = try? JSONDecoder().decode(NuvioStoredPluginsState.self, from: data) else {
            return []
        }
        return Set(
            sanitized(decoded).scrapers
                .filter { $0.repositoryId == repositoryID }
                .map(\.codeFileName)
        )
    }

    private func codeFileNamesInstalledByOtherProfiles(
        repositoryID: String,
        excluding owner: UUID
    ) -> Set<String> {
        guard injectedDefaults == nil, !ProfileSettingsStore.sharesServices else { return [] }
        var result: Set<String> = []
        for profile in ProfileManager.shared.profiles where profile.id != owner {
            let store = ProfileSettingsStore.shared.store(for: profile.id)
            guard let data = store.data(forKey: stateKey),
                  let state = try? JSONDecoder().decode(NuvioStoredPluginsState.self, from: data) else {
                continue
            }
            for scraper in state.scrapers where scraper.repositoryId == repositoryID {
                result.insert(scraper.codeFileName)
            }
        }
        return result
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
