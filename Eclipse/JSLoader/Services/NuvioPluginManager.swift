import Combine
import Foundation

@MainActor
final class NuvioPluginManager: ObservableObject {
    static let shared = NuvioPluginManager()

    @Published private(set) var state = NuvioStoredPluginsState()

    private let store = NuvioPluginStore()
    private let maxStreamsPerSource = 80
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }()
    private var initialized = false

    nonisolated static var isFeatureAvailable: Bool {
        Bundle.main.allowsNuvioPlugins
    }

    var repositories: [NuvioPluginRepositoryItem] { state.repositories }
    var scrapers: [NuvioPluginScraper] { state.scrapers }
    var pluginsEnabled: Bool { Self.isFeatureAvailable && state.pluginsEnabled }
    var groupStreamsByRepository: Bool { state.groupStreamsByRepository }

    var activeSources: [NuvioPluginSource] {
        activeSources(for: nil)
    }

    var installedSources: [NuvioPluginSource] {
        installedSources(for: nil)
    }

    private init() {
        load()
    }

    nonisolated static func persistedBackupState() -> NuvioStoredPluginsState {
        guard isFeatureAvailable else { return NuvioStoredPluginsState() }
        return NuvioPluginStore().load()
    }

    nonisolated static func restorePersistedBackupState(
        _ restored: NuvioStoredPluginsState,
        refreshRepositories: Bool = false
    ) {
        guard isFeatureAvailable else { return }
        let sanitized = sanitizedStoredState(restored)
        NuvioPluginStore().save(sanitized)
        Task { @MainActor in
            shared.load()
            shared.syncAutoModeSources()
            await shared.refreshRestoredRepositoriesIfNeeded(force: refreshRepositories)
        }
    }

    func load() {
        guard Self.isFeatureAvailable else {
            state = NuvioStoredPluginsState(pluginsEnabled: false)
            initialized = true
            syncAutoModeSources()
            return
        }
        state = store.load()
        initialized = true
    }

    func backupState() -> NuvioStoredPluginsState {
        guard Self.isFeatureAvailable else { return NuvioStoredPluginsState() }
        var copy = state
        copy.repositories = copy.repositories.map {
            var repo = $0
            repo.isRefreshing = false
            repo.errorMessage = nil
            return repo
        }
        return copy
    }

    func restoreBackupState(_ restored: NuvioStoredPluginsState) {
        guard Self.isFeatureAvailable else { return }
        state = Self.sanitizedStoredState(restored)
        persist()
        syncAutoModeSources()
    }

    func setPluginsEnabled(_ enabled: Bool) {
        guard Self.isFeatureAvailable else { return }
        ensureLoaded()
        state.pluginsEnabled = enabled
        persist()
        syncAutoModeSources()
    }

    func setGroupStreamsByRepository(_ enabled: Bool) {
        guard Self.isFeatureAvailable else { return }
        ensureLoaded()
        state.groupStreamsByRepository = enabled
        persist()
        syncAutoModeSources()
    }

    func addRepository(rawURL: String) async throws {
        guard Self.isFeatureAvailable else {
            throw NuvioPluginError.repositoryInstallFailed("Plugins are unavailable in this distribution.")
        }
        ensureLoaded()
        let manifestURL = try Self.normalizeManifestURL(rawURL)
        guard !state.repositories.contains(where: { $0.manifestUrl.caseInsensitiveCompare(manifestURL) == .orderedSame }) else {
            throw NuvioPluginError.duplicateRepository
        }

        do {
            let previousById = Dictionary(uniqueKeysWithValues: state.scrapers.map { ($0.id, $0) })
            let fetched = try await fetchRepositoryData(manifestURL: manifestURL, previousScrapers: previousById)
            state.repositories.append(fetched.repository)
            state.scrapers.removeAll { $0.repositoryUrl == manifestURL }
            state.scrapers.append(contentsOf: fetched.scrapers)
            persist()
            syncAutoModeSources()
        } catch let error as NuvioPluginError {
            throw error
        } catch {
            throw NuvioPluginError.repositoryInstallFailed(error.localizedDescription)
        }
    }

    func removeRepository(_ manifestURL: String) {
        guard Self.isFeatureAvailable else { return }
        ensureLoaded()
        let removedSourceIds = NuvioPluginSupport.sourceGroups(
            scrapers: state.scrapers.filter { $0.repositoryUrl == manifestURL },
            repositories: state.repositories,
            groupByRepository: state.groupStreamsByRepository
        ).map(\.id)

        state.repositories.removeAll { $0.manifestUrl == manifestURL }
        state.scrapers.removeAll { $0.repositoryUrl == manifestURL }
        persist()
        removedSourceIds.forEach(AutoModeSourceSelection.removeSource)
        syncAutoModeSources()
    }

    func refreshAll() async {
        guard Self.isFeatureAvailable else { return }
        ensureLoaded()
        for repository in state.repositories {
            await refreshRepository(repository.manifestUrl)
        }
    }

    func refreshRepository(_ manifestURL: String) async {
        guard Self.isFeatureAvailable else { return }
        ensureLoaded()
        guard state.repositories.contains(where: { $0.manifestUrl == manifestURL }) else { return }
        markRefreshing(manifestURL, isRefreshing: true, error: nil)
        defer { markRefreshing(manifestURL, isRefreshing: false, error: nil, preserveExistingError: true) }

        do {
            let previousById = Dictionary(uniqueKeysWithValues: state.scrapers.map { ($0.id, $0) })
            let fetched = try await fetchRepositoryData(manifestURL: manifestURL, previousScrapers: previousById)
            state.repositories = state.repositories.map { $0.manifestUrl == manifestURL ? fetched.repository : $0 }
            state.scrapers.removeAll { $0.repositoryUrl == manifestURL }
            state.scrapers.append(contentsOf: fetched.scrapers)
            persist()
            syncAutoModeSources()
        } catch {
            markRefreshing(manifestURL, isRefreshing: false, error: error.localizedDescription)
            persist()
        }
    }

    func toggleScraper(_ scraperId: String, enabled: Bool) {
        guard Self.isFeatureAvailable else { return }
        ensureLoaded()
        state.scrapers = state.scrapers.map { scraper in
            guard scraper.id == scraperId else { return scraper }
            var copy = scraper
            copy.enabled = scraper.manifestEnabled && enabled
            return copy
        }
        persist()
        syncAutoModeSources()
    }

    func activeSources(for type: String?) -> [NuvioPluginSource] {
        guard Self.isFeatureAvailable else { return [] }
        ensureLoaded()
        guard state.pluginsEnabled else { return [] }
        return sources(for: type, includeDisabled: false)
    }

    func installedSources(for type: String?) -> [NuvioPluginSource] {
        guard Self.isFeatureAvailable else { return [] }
        ensureLoaded()
        return sources(for: type, includeDisabled: true)
    }

    func isSourceEnabled(_ source: NuvioPluginSource) -> Bool {
        guard Self.isFeatureAvailable else { return false }
        ensureLoaded()
        guard state.pluginsEnabled else { return false }
        let scraperIds = Set(source.scrapers.map(\.id))
        return state.scrapers.contains { scraper in
            scraperIds.contains(scraper.id) &&
            scraper.enabled &&
            scraper.manifestEnabled &&
            !scraper.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func canEnableSource(_ source: NuvioPluginSource) -> Bool {
        guard Self.isFeatureAvailable else { return false }
        return source.scrapers.contains {
            $0.manifestEnabled &&
            !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func setSourceEnabled(_ source: NuvioPluginSource, enabled: Bool) {
        guard Self.isFeatureAvailable else { return }
        ensureLoaded()
        let scraperIds = Set(source.scrapers.map(\.id))
        if enabled {
            state.pluginsEnabled = true
        }
        state.scrapers = state.scrapers.map { scraper in
            guard scraperIds.contains(scraper.id) else { return scraper }
            var copy = scraper
            copy.enabled = scraper.manifestEnabled && enabled
            return copy
        }
        persist()
        syncAutoModeSources()
    }

    func testScraper(_ scraperId: String) async throws -> [NuvioPluginStream] {
        guard Self.isFeatureAvailable else {
            throw NuvioPluginError.providerNotFound
        }
        ensureLoaded()
        guard let scraper = state.scrapers.first(where: { $0.id == scraperId }) else {
            throw NuvioPluginError.providerNotFound
        }
        guard !scraper.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NuvioPluginError.providerNotFound
        }
        let mediaType = scraper.supportsType("movie") ? "movie" : "tv"
        let source = NuvioPluginSource(
            id: "plugin:\(scraper.id)",
            name: scraper.name,
            repositoryUrl: scraper.repositoryUrl,
            logo: scraper.logo,
            scrapers: [scraper]
        )
        return try await executeScraper(
            scraper,
            source: source,
            tmdbId: "603",
            mediaType: mediaType,
            season: mediaType == "tv" ? 1 : nil,
            episode: mediaType == "tv" ? 1 : nil
        )
    }

    func executeSource(
        _ source: NuvioPluginSource,
        tmdbId: Int,
        mediaType: String,
        season: Int?,
        episode: Int?
    ) async -> [NuvioPluginStream] {
        guard Self.isFeatureAvailable else { return [] }
        var streams: [NuvioPluginStream] = []
        for scraper in source.scrapers where scraper.supportsType(mediaType) {
            do {
                let result = try await executeScraper(
                    scraper,
                    source: source,
                    tmdbId: String(tmdbId),
                    mediaType: mediaType,
                    season: season,
                    episode: episode
                )
                streams.append(contentsOf: result)
            } catch {
                Logger.shared.log("Nuvio plugin failed provider=\(scraper.name) error=\(error.localizedDescription)", type: "Plugin")
            }
        }
        let sorted = streams.sorted { lhs, rhs in
            if lhs.scraperName.caseInsensitiveCompare(rhs.scraperName) != .orderedSame {
                return lhs.scraperName.caseInsensitiveCompare(rhs.scraperName) == .orderedAscending
            }
            return lhs.displayName.caseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        if sorted.count > maxStreamsPerSource {
            Logger.shared.log("Nuvio plugin capped \(sorted.count) streams to \(maxStreamsPerSource) source=\(source.name)", type: "Plugin")
        }
        return Array(sorted.prefix(maxStreamsPerSource))
    }

    private func executeScraper(
        _ scraper: NuvioPluginScraper,
        source: NuvioPluginSource,
        tmdbId: String,
        mediaType: String,
        season: Int?,
        episode: Int?
    ) async throws -> [NuvioPluginStream] {
        let streams = try await NuvioPluginRuntime.execute(
            code: scraper.code,
            tmdbId: tmdbId,
            mediaType: NuvioPluginSupport.normalizeType(mediaType),
            season: season,
            episode: episode,
            scraper: scraper,
            source: source,
            scraperSettings: Self.scraperSettings(from: state.scraperSettingsJSON?[scraper.id])
        )
        let safe = streams.filter(\.isDirectHTTP)
        let dropped = streams.count - safe.count
        if dropped > 0 {
            Logger.shared.log("Nuvio plugin dropped \(dropped) non-HTTP stream(s) provider=\(scraper.name)", type: "Plugin")
        }
        return safe
    }

    private func fetchRepositoryData(
        manifestURL: String,
        previousScrapers: [String: NuvioPluginScraper]
    ) async throws -> (repository: NuvioPluginRepositoryItem, scrapers: [NuvioPluginScraper]) {
        let manifestPayload = try await downloadText(from: manifestURL, kind: "manifest")
        let manifest = try parseManifest(manifestPayload)
        let baseURL = manifestURL.components(separatedBy: "?").first?.replacingOccurrences(of: "/manifest.json", with: "") ?? manifestURL

        var scrapers: [NuvioPluginScraper] = []
        for info in manifest.scrapers where isSupportedOnIOS(info) {
            let codeURL: String
            if info.filename.hasPrefix("http://") || info.filename.hasPrefix("https://") {
                codeURL = info.filename
            } else {
                codeURL = "\(baseURL)/\(info.filename.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
            }

            do {
                let code = try await downloadText(from: codeURL, kind: "provider script")
                let scraperId = "\(manifestURL.lowercased()):\(info.id)"
                let previous = previousScrapers[scraperId]
                let enabled = info.enabled ? (previous?.enabled ?? true) : false
                scrapers.append(NuvioPluginScraper(
                    id: scraperId,
                    repositoryUrl: manifestURL,
                    name: info.name,
                    description: info.description ?? "",
                    version: info.version,
                    filename: info.filename,
                    supportedTypes: info.supportedTypes,
                    enabled: enabled,
                    manifestEnabled: info.enabled,
                    logo: info.logo,
                    contentLanguage: info.contentLanguage ?? [],
                    formats: info.formats ?? info.supportedFormats,
                    code: code
                ))
            } catch {
                Logger.shared.log("Nuvio plugin script fetch failed repo=\(manifestURL) file=\(info.filename) error=\(error.localizedDescription)", type: "Plugin")
            }
        }

        let repository = NuvioPluginRepositoryItem(
            manifestUrl: manifestURL,
            name: manifest.name,
            description: manifest.description,
            version: manifest.version,
            scraperCount: scrapers.count,
            lastUpdated: Date().timeIntervalSince1970,
            isRefreshing: false,
            errorMessage: nil
        )
        return (repository, scrapers)
    }

    private func parseManifest(_ payload: String) throws -> NuvioPluginManifest {
        guard let data = payload.data(using: .utf8) else {
            throw NuvioPluginError.invalidResponse
        }
        let manifest = try decoder.decode(NuvioPluginManifest.self, from: data)
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NuvioPluginError.manifestNameMissing
        }
        guard !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NuvioPluginError.manifestVersionMissing
        }
        guard !manifest.scrapers.isEmpty else {
            throw NuvioPluginError.manifestHasNoProviders
        }
        return manifest
    }

    private func isSupportedOnIOS(_ scraper: NuvioPluginManifestScraper) -> Bool {
        let supported = Set(scraper.supportedPlatforms?.map { $0.lowercased() } ?? [])
        let disabled = Set(scraper.disabledPlatforms?.map { $0.lowercased() } ?? [])
        if !supported.isEmpty && !supported.contains("ios") { return false }
        if disabled.contains("ios") { return false }
        return true
    }

    private func downloadText(from urlString: String, kind: String) async throws -> String {
        guard let url = URL(string: urlString),
              url.scheme?.isEmpty == false else {
            throw NuvioPluginError.invalidRepositoryURL
        }
        guard !ServiceSandboxState.isBlockedTrackingURL(url.absoluteString) else {
            Logger.shared.log("Nuvio plugin blocked tracking \(kind) download target=\(ServiceSandboxState.redactedURL(url.absoluteString))", type: "ServiceSandbox")
            throw NuvioPluginError.repositoryInstallFailed("Plugin repository requested a blocked tracking endpoint.")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = [
            "User-Agent": URLSession.randomUserAgent,
            "DNT": "1",
            "Sec-GPC": "1"
        ]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(URLSession.randomUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "DNT")
        request.setValue("1", forHTTPHeaderField: "Sec-GPC")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            throw NuvioPluginError.repositoryInstallFailed("Plugin \(kind) download failed with HTTP \(statusCode).")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NuvioPluginError.repositoryInstallFailed("Plugin \(kind) could not be decoded as UTF-8.")
        }
        return text
    }

    private func markRefreshing(
        _ manifestURL: String,
        isRefreshing: Bool,
        error: String?,
        preserveExistingError: Bool = false
    ) {
        state.repositories = state.repositories.map { repository in
            guard repository.manifestUrl == manifestURL else { return repository }
            var copy = repository
            copy.isRefreshing = isRefreshing
            if !preserveExistingError || error != nil {
                copy.errorMessage = error
            }
            return copy
        }
    }

    private func persist() {
        guard Self.isFeatureAvailable else { return }
        store.save(state)
    }

    private func ensureLoaded() {
        if !initialized {
            load()
        }
    }

    private func refreshRestoredRepositoriesIfNeeded(force: Bool) async {
        ensureLoaded()
        let hasPlaceholderScrapers = state.scrapers.contains {
            $0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard force || (!state.repositories.isEmpty && (state.scrapers.isEmpty || hasPlaceholderScrapers)) else {
            return
        }

        Logger.shared.log("Nuvio plugins refreshing restored repositories count=\(state.repositories.count)", type: "Plugin")
        await refreshAll()
    }

    private func syncAutoModeSources() {
        AutoModeSourceSelection.syncPluginSources(
            activeSourceIds: activeSources.map(\.id),
            knownSourceIds: installedSources.map(\.id)
        )
    }

    private func sources(for type: String?, includeDisabled: Bool) -> [NuvioPluginSource] {
        let scrapers = state.scrapers.filter { scraper in
            !scraper.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (includeDisabled || (scraper.enabled && scraper.manifestEnabled)) &&
            (type.map(scraper.supportsType) ?? true)
        }
        return NuvioPluginSupport.sourceGroups(
            scrapers: scrapers,
            repositories: state.repositories,
            groupByRepository: state.groupStreamsByRepository
        )
    }

    static func normalizeManifestURL(_ rawURL: String) throws -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NuvioPluginError.emptyRepositoryURL }

        let withScheme: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }

        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NuvioPluginError.invalidRepositoryURL
        }

        components.scheme = scheme
        components.fragment = nil
        let trimmedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let manifestPath: String
        if trimmedPath.isEmpty {
            manifestPath = "/manifest.json"
        } else if trimmedPath.hasSuffix("manifest.json") {
            manifestPath = "/\(trimmedPath)"
        } else {
            manifestPath = "/\(trimmedPath)/manifest.json"
        }
        components.percentEncodedPath = manifestPath

        guard let url = components.url else {
            throw NuvioPluginError.invalidRepositoryURL
        }
        return url.absoluteString
    }

    nonisolated private static func sanitizedStoredState(_ restored: NuvioStoredPluginsState) -> NuvioStoredPluginsState {
        let repositories = restored.repositories.filter { repository in
            guard let components = URLComponents(string: repository.manifestUrl),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = components.host,
                  !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            return components.path.hasSuffix("/manifest.json")
        }
        let repositoryURLs = Set(repositories.map(\.manifestUrl))
        let scrapers = restored.scrapers.filter { scraper in
            repositoryURLs.contains(scraper.repositoryUrl) &&
            !scraper.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !scraper.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let scraperIDs = Set(scrapers.map(\.id))
        let scraperSettings = restored.scraperSettingsJSON?
            .filter { scraperIDs.contains($0.key) && !Self.scraperSettings(from: $0.value).isEmpty }

        return NuvioStoredPluginsState(
            pluginsEnabled: restored.pluginsEnabled,
            groupStreamsByRepository: restored.groupStreamsByRepository,
            repositories: repositories,
            scrapers: scrapers,
            scraperSettingsJSON: scraperSettings?.isEmpty == false ? scraperSettings : nil
        )
    }

    nonisolated private static func scraperSettings(from rawJSON: String?) -> [String: Any] {
        guard let rawJSON,
              let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              JSONSerialization.isValidJSONObject(object) else {
            return [:]
        }
        return object
    }
}

private final class NuvioPluginStore {
    private let key = "nuvioPluginsState.v1"

    func load() -> NuvioStoredPluginsState {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(NuvioStoredPluginsState.self, from: data) else {
            return NuvioStoredPluginsState()
        }
        var cleaned = decoded
        cleaned.repositories = cleaned.repositories.map {
            var repo = $0
            repo.isRefreshing = false
            repo.errorMessage = nil
            return repo
        }
        return cleaned
    }

    func save(_ state: NuvioStoredPluginsState) {
        var copy = state
        copy.repositories = copy.repositories.map {
            var repo = $0
            repo.isRefreshing = false
            repo.errorMessage = nil
            return repo
        }
        guard let data = try? JSONEncoder().encode(copy) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
