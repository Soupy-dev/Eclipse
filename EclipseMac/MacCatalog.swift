import AppKit
import Combine
import Foundation
import Security
import SwiftUI
import UserNotifications

struct MacMediaItem: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let mediaType: String
    let title: String
    let overview: String
    let posterPath: String?
    let backdropPath: String?
    let date: String?
    let rating: Double

    var stableID: String { "\(mediaType)-\(id)" }
    var posterURL: URL? { Self.artworkURL(path: posterPath, tmdbSize: "w500") }
    var backdropURL: URL? { Self.artworkURL(path: backdropPath, tmdbSize: "w1280") }

    private static func artworkURL(path: String?, tmdbSize: String) -> URL? {
        guard let path else { return nil }
        if path.lowercased().hasPrefix("https://") { return URL(string: path) }
        return URL(string: "https://image.tmdb.org/t/p/\(tmdbSize)\(path)")
    }
}

struct MacTVSeasonSummary: Identifiable, Hashable, Sendable {
    let seasonNumber: Int
    let name: String
    let episodeCount: Int
    let airDate: String?
    let posterPath: String?

    var id: Int { seasonNumber }
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)"
    }
}

struct MacTVEpisode: Identifiable, Hashable, Sendable {
    let id: Int
    let seasonNumber: Int
    let episodeNumber: Int
    let name: String
    let overview: String
    let airDate: String?
    let stillPath: String?
    let runtime: Int?

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Episode \(episodeNumber)" : trimmed
    }

    var episodeLabel: String { "S\(seasonNumber) · E\(episodeNumber)" }
    var stillURL: URL? { stillPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500\($0)") } }
}

enum MacSchedulePreferences {
    /// Schedule reminders are intentionally a separate, off-by-default Mac opt-in.
    static let notificationsEnabledKey = "macScheduleNotificationsEnabled"
}

enum MacScheduleClassification: String, Hashable, Sendable {
    case anime
    case western
    case unknown
}

enum MacScheduleSource: String, Hashable, Sendable {
    case aniList
    case myAnimeList
    case trakt
    case tvMaze

    var displayName: String {
        switch self {
        case .aniList: "AniList"
        case .myAnimeList: "MyAnimeList"
        case .trakt: "Trakt"
        case .tvMaze: "TVMaze"
        }
    }
}

struct MacScheduleEntry: Identifiable, Hashable, Sendable {
    let show: MacMediaItem
    let episodeID: Int
    let episodeTitle: String
    let seasonNumber: Int?
    let episodeNumber: Int
    let airDate: Date
    let seriesStatus: String
    let classification: MacScheduleClassification
    let source: MacScheduleSource
    let hasKnownAiringTime: Bool
    let anilistMediaID: Int?
    private let animeSpecial: Bool

    init(
        show: MacMediaItem,
        episodeID: Int,
        episodeTitle: String,
        seasonNumber: Int?,
        episodeNumber: Int,
        airDate: Date,
        seriesStatus: String,
        classification: MacScheduleClassification,
        source: MacScheduleSource,
        hasKnownAiringTime: Bool,
        anilistMediaID: Int? = nil,
        isAnimeSpecial: Bool = false
    ) {
        self.show = show
        self.episodeID = episodeID
        self.episodeTitle = episodeTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.airDate = airDate
        self.seriesStatus = seriesStatus
        self.classification = classification
        self.source = source
        self.hasKnownAiringTime = hasKnownAiringTime
        self.anilistMediaID = anilistMediaID
        animeSpecial = isAnimeSpecial
    }

    var id: String {
        "\(source.rawValue)-\(show.id)-episode-\(episodeID)"
    }
    var episodeLabel: String {
        guard let seasonNumber else { return "Episode \(episodeNumber)" }
        return "S\(seasonNumber) · E\(episodeNumber)"
    }
    var isSeasonPremiere: Bool { episodeNumber == 1 && (seasonNumber ?? 1) > 0 }
    var isAnimeSpecial: Bool { animeSpecial || (classification == .anime && seasonNumber == 0) }

    func replacingShow(_ replacement: MacMediaItem) -> MacScheduleEntry {
        MacScheduleEntry(
            show: replacement,
            episodeID: episodeID,
            episodeTitle: episodeTitle,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            airDate: airDate,
            seriesStatus: seriesStatus,
            classification: classification,
            source: source,
            hasKnownAiringTime: hasKnownAiringTime,
            anilistMediaID: anilistMediaID,
            isAnimeSpecial: animeSpecial
        )
    }
}

@MainActor
final class MacCatalogStore: ObservableObject {
    static let shared = MacCatalogStore()

    @Published private(set) var trending: [MacMediaItem] = []
    @Published private(set) var popularMovies: [MacMediaItem] = []
    @Published private(set) var popularShows: [MacMediaItem] = []
    @Published private(set) var topRatedMovies: [MacMediaItem] = []
    @Published private(set) var trendingAnime: [MacMediaItem] = []
    @Published private(set) var popularAnime: [MacMediaItem] = []
    @Published private(set) var topRatedAnime: [MacMediaItem] = []
    @Published private(set) var airingAnime: [MacMediaItem] = []
    @Published private(set) var upcomingAnime: [MacMediaItem] = []
    @Published private(set) var searchResults: [MacMediaItem] = []
    @Published private(set) var library: [MacMediaItem] = []
    @Published private(set) var scheduleEntries: [MacScheduleEntry] = []
    @Published private(set) var isLoadingSchedule = false
    @Published private(set) var scheduleErrorMessage: String?
    @Published private(set) var scheduleNotificationMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let decoder = JSONDecoder()
    private let libraryKey = "macMediaLibrary.v1"
    private var searchTask: Task<Void, Never>?
    private var activeScheduleLoadID: UUID?
    private var schedulePosterHydrationTask: Task<Void, Never>?
    private var posterHydrationAttemptedTMDBIDs = Set<Int>()
    private var hasLoadedSchedule = false
    private var unfilteredScheduleEntries: [MacScheduleEntry] = []
    private var animeScheduleCache: MacScheduleSourceCache?
    private var westernScheduleCache: MacScheduleSourceCache?
    private var hasLoadedHome = false
    private var loadedHomeAnimeKinds = Set<MacAniListCatalogKind>()
    private var loadedHomePerformanceMode: Bool?
    private var homeLoadTask: Task<Void, Never>?
    private var tvSeasonCache: [Int: [MacTVSeasonSummary]] = [:]
    private var tvEpisodeCache: [String: [MacTVEpisode]] = [:]
    private var cloudStateActivated: Bool

    private init() {
        cloudStateActivated = !MacCloudLibrarySync.hasPersistedOwner
        if cloudStateActivated { loadPersistedCloudLibrary() }
        Task { await refreshCloudLibrary() }
    }

    func loadHomeIfNeeded() async {
        let requiredAnimeKinds = Self.enabledHomeAnimeKinds(UserDefaults.standard)
        let performanceMode = UserDefaults.standard.object(forKey: "performanceModeEnabled") as? Bool ?? true
        guard !hasLoadedHome ||
                loadedHomeAnimeKinds != requiredAnimeKinds ||
                loadedHomePerformanceMode != performanceMode else { return }
        if let homeLoadTask {
            await homeLoadTask.value
            if hasLoadedHome,
               loadedHomeAnimeKinds == requiredAnimeKinds,
               loadedHomePerformanceMode == performanceMode {
                return
            }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.homeLoadTask = nil }
            await self.performHomeLoad(
                requiredAnimeKinds: requiredAnimeKinds,
                performanceMode: performanceMode
            )
        }
        homeLoadTask = task
        await task.value
    }

    private func performHomeLoad(
        requiredAnimeKinds: Set<MacAniListCatalogKind>,
        performanceMode: Bool
    ) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var failures: [String] = []
        var animeCatalogsLoaded = requiredAnimeKinds.isEmpty
        do {
            let apiKey = try configuredAPIKey()
            async let tmdbAttempt = captureScheduleSource {
                async let trendingRequest = self.fetch(path: "/3/trending/all/week")
                async let movieRequest = self.fetch(path: "/3/movie/popular")
                async let showRequest = self.fetch(path: "/3/tv/popular")
                async let topRatedRequest = self.fetch(path: "/3/movie/top_rated")
                let (trending, movies, shows, topRated) = try await (
                    trendingRequest, movieRequest, showRequest, topRatedRequest
                )
                return MacTMDBHomeCatalogs(trending: trending, movies: movies, shows: shows, topRated: topRated)
            }
            async let animeAttempt = captureScheduleSource {
                try await self.fetchAnimeHomeCatalogs(
                    apiKey: apiKey,
                    requiredKinds: requiredAnimeKinds,
                    performanceMode: performanceMode
                )
            }

            switch await tmdbAttempt {
            case .success(let catalogs):
                // Publish the fast TMDB shelves immediately. Anime identity mapping can
                // continue without holding the entire Home screen behind its fanout.
                trending = catalogs.trending
                popularMovies = catalogs.movies
                popularShows = catalogs.shows
                topRatedMovies = catalogs.topRated
            case .failure(let error):
                failures.append("TMDB home catalogs failed: \(error.localizedDescription)")
            }

            switch await animeAttempt {
            case .success(let payload):
                animeCatalogsLoaded = true
                trendingAnime = payload.catalogs[.trending, default: []]
                popularAnime = payload.catalogs[.popular, default: []]
                topRatedAnime = payload.catalogs[.topRated, default: []]
                airingAnime = payload.catalogs[.airing, default: []]
                upcomingAnime = payload.catalogs[.upcoming, default: []]
                if let warning = payload.warning { failures.append(warning) }
            case .failure(let error):
                failures.append("Anime home catalogs failed: \(error.localizedDescription)")
            }
            try Task.checkCancellation()
            hasLoadedHome = !trending.isEmpty || !trendingAnime.isEmpty
            if hasLoadedHome, animeCatalogsLoaded {
                loadedHomeAnimeKinds = requiredAnimeKinds
                loadedHomePerformanceMode = performanceMode
            }
        } catch is CancellationError {
            return
        } catch {
            failures.append("Catalog request failed: \(error.localizedDescription)")
            // A transient failure remains retryable when Home is opened again.
            hasLoadedHome = !trending.isEmpty || !trendingAnime.isEmpty
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    private func fetchAnimeHomeCatalogs(
        apiKey: String,
        requiredKinds: Set<MacAniListCatalogKind>,
        performanceMode: Bool
    ) async throws -> MacAnimeHomePayload {
        guard !requiredKinds.isEmpty else { return MacAnimeHomePayload(catalogs: [:], warning: nil) }
        let mappingLimit = performanceMode ? 15 : 20
        do {
            let catalogs = try await MacAniListCatalogService.shared.fetchHomeCatalogs(
                apiKey: apiKey,
                requiredKinds: requiredKinds,
                limit: mappingLimit
            )
            return MacAnimeHomePayload(catalogs: catalogs, warning: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let catalogs = try await MacMALCatalogService.shared.fetchHomeCatalogs(
                apiKey: apiKey,
                requiredKinds: requiredKinds,
                limit: mappingLimit
            )
            return MacAnimeHomePayload(
                catalogs: catalogs,
                warning: "AniList is unavailable. Anime shelves are temporarily using MyAnimeList fallback."
            )
        }
    }

    func loadTrendingIfNeeded() async {
        await loadHomeIfNeeded()
    }

    func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await request(
                path: "/3/search/multi",
                queryItems: [
                    URLQueryItem(name: "query", value: trimmed),
                    URLQueryItem(name: "include_adult", value: "false")
                ],
                assign: { self.searchResults = $0 }
            )
        }
    }

    func isInLibrary(_ item: MacMediaItem) -> Bool {
        library.contains { $0.stableID == item.stableID }
    }

    /// Adds an item without giving importer-style callers a way to remove an
    /// existing bookmark. Returns `true` only when the library changed.
    @discardableResult
    func addToLibraryIfNeeded(_ item: MacMediaItem) -> Bool {
        guard !isInLibrary(item) else { return false }

        library.append(item)
        library.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: libraryKey)
        }
        MacCloudLibrarySync.shared.setBookmarked(item, bookmarked: true)
        Task { await reconcileScheduleNotificationsAfterLibraryChange() }
        return true
    }

    func toggleLibrary(_ item: MacMediaItem) {
        if let index = library.firstIndex(where: { $0.stableID == item.stableID }) {
            library.remove(at: index)
        } else {
            addToLibraryIfNeeded(item)
            return
        }
        if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: libraryKey)
        }
        MacCloudLibrarySync.shared.setBookmarked(item, bookmarked: false)
        Task { await reconcileScheduleNotificationsAfterLibraryChange() }
    }

    func refreshCloudLibrary() async {
        guard let remote = await MacCloudLibrarySync.shared.pullBookmarks() else { return }
        library = remote
        if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: libraryKey)
        }
        MacCloudLibrarySync.shared.retryPendingMutations()
        await reconcileScheduleNotificationsAfterLibraryChange()
    }

    var cloudLibrarySnapshot: [MacMediaItem] { library }

    func activateCloudBackedStateForVerifiedOwner() {
        guard !cloudStateActivated else { return }
        cloudStateActivated = true
        loadPersistedCloudLibrary()
    }

    func resetCloudBackedStateForAccountIsolation() {
        library = []
        cloudStateActivated = false
        UserDefaults.standard.removeObject(forKey: libraryKey)
        Task { await reconcileScheduleNotificationsAfterLibraryChange() }
    }

    func suspendCloudBackedStateForIdentityRevalidation() {
        library = []
        cloudStateActivated = false
        Task { await reconcileScheduleNotificationsAfterLibraryChange() }
    }

    private func loadPersistedCloudLibrary() {
        guard let data = UserDefaults.standard.data(forKey: libraryKey),
              let items = try? decoder.decode([MacMediaItem].self, from: data) else { return }
        library = items
    }

    func tvSeasons(for item: MacMediaItem) async throws -> [MacTVSeasonSummary] {
        guard item.mediaType == "tv" else { return [] }
        if let cached = tvSeasonCache[item.id] { return cached }

        let payload: TMDBTVShowPayload = try await fetchDecoded(path: "/3/tv/\(item.id)")
        let seasons = payload.seasons
            .filter { $0.episodeCount > 0 }
            .map {
                MacTVSeasonSummary(
                    seasonNumber: $0.seasonNumber,
                    name: $0.name ?? "",
                    episodeCount: $0.episodeCount,
                    airDate: $0.airDate,
                    posterPath: $0.posterPath
                )
            }
            .sorted { lhs, rhs in
                if lhs.seasonNumber == 0 { return false }
                if rhs.seasonNumber == 0 { return true }
                return lhs.seasonNumber < rhs.seasonNumber
            }
        tvSeasonCache[item.id] = seasons
        return seasons
    }

    func tvEpisodes(for item: MacMediaItem, seasonNumber: Int) async throws -> [MacTVEpisode] {
        guard item.mediaType == "tv" else { return [] }
        let cacheKey = "\(item.id)-\(seasonNumber)"
        if let cached = tvEpisodeCache[cacheKey] { return cached }

        let payload: TMDBTVSeasonPayload = try await fetchDecoded(path: "/3/tv/\(item.id)/season/\(seasonNumber)")
        let episodes = payload.episodes
            .map {
                MacTVEpisode(
                    id: $0.id,
                    seasonNumber: $0.seasonNumber,
                    episodeNumber: $0.episodeNumber,
                    name: $0.name ?? "",
                    overview: $0.overview ?? "",
                    airDate: $0.airDate,
                    stillPath: $0.stillPath,
                    runtime: $0.runtime
                )
            }
            .sorted { $0.episodeNumber < $1.episodeNumber }
        tvEpisodeCache[cacheKey] = episodes
        return episodes
    }

    func loadSchedule(windowDays rawWindowDays: Int, mode rawMode: String, forceReload: Bool = false) async {
        let windowDays = [7, 14, 21, 30].contains(rawWindowDays) ? rawWindowDays : 7
        let mode = MacScheduleMode(rawValue: rawMode) ?? .anime

        // Keep any still-relevant cached rows visible while refreshing, but immediately
        // apply the newly selected mode/window so stale rows from another filter do not leak.
        scheduleEntries = visibleScheduleEntries(
            from: unfilteredScheduleEntries,
            windowDays: windowDays,
            mode: mode
        )
        let loadID = UUID()
        activeScheduleLoadID = loadID
        schedulePosterHydrationTask?.cancel()
        if forceReload {
            posterHydrationAttemptedTMDBIDs.removeAll(keepingCapacity: true)
        }
        isLoadingSchedule = true
        scheduleErrorMessage = nil
        defer {
            if activeScheduleLoadID == loadID {
                isLoadingSchedule = false
            }
        }

        do {
            let libraryShows = library.filter { $0.mediaType == "tv" }
            var animeResult: Result<MacScheduleSourcePayload, Error>?
            var westernResult: Result<MacScheduleSourcePayload, Error>?

            switch mode {
            case .anime:
                animeResult = await captureScheduleSource {
                    try await self.animeSchedulePayload(
                        dayCount: windowDays,
                        libraryShows: libraryShows,
                        forceReload: forceReload
                    )
                }
            case .western:
                westernResult = await captureScheduleSource {
                    try await self.westernSchedulePayload(
                        dayCount: windowDays,
                        forceReload: forceReload
                    )
                }
            case .combined:
                async let animeAttempt = captureScheduleSource {
                    try await self.animeSchedulePayload(
                        dayCount: windowDays,
                        libraryShows: libraryShows,
                        forceReload: forceReload
                    )
                }
                async let westernAttempt = captureScheduleSource {
                    try await self.westernSchedulePayload(
                        dayCount: windowDays,
                        forceReload: forceReload
                    )
                }
                (animeResult, westernResult) = await (animeAttempt, westernAttempt)
            }
            try Task.checkCancellation()
            guard activeScheduleLoadID == loadID else { return }

            var combined: [MacScheduleEntry] = []
            var warnings: [String] = []
            var successfulSources = 0

            if let animeResult {
                switch animeResult {
                case .success(let payload):
                    combined.append(contentsOf: payload.entries)
                    successfulSources += 1
                    if let warning = payload.warning { warnings.append(warning) }
                case .failure(let error):
                    warnings.append("Anime schedule failed: \(error.localizedDescription)")
                }
            }

            if let westernResult {
                switch westernResult {
                case .success(let payload):
                    combined.append(contentsOf: payload.entries)
                    successfulSources += 1
                    if let warning = payload.warning { warnings.append(warning) }
                case .failure(let error):
                    warnings.append("Western schedule failed: \(error.localizedDescription)")
                }
            }

            guard successfulSources > 0 else {
                throw MacCatalogError.scheduleSourcesUnavailable(warnings.joined(separator: " "))
            }

            unfilteredScheduleEntries = Self.deduplicatedScheduleEntries(combined)
            scheduleEntries = visibleScheduleEntries(from: combined, windowDays: windowDays, mode: mode)
            hasLoadedSchedule = true
            scheduleErrorMessage = warnings.isEmpty ? nil : warnings.joined(separator: " ")
            startPosterHydrationIfNeeded(loadID: loadID)
            await syncScheduleNotifications(using: reminderScheduleEntries(windowDays: windowDays, mode: mode))
        } catch is CancellationError {
            return
        } catch {
            guard activeScheduleLoadID == loadID else { return }
            scheduleErrorMessage = "Schedule request failed: \(error.localizedDescription)"
        }
    }

    func resolveScheduleEntry(_ entry: MacScheduleEntry) async -> MacMediaItem? {
        if entry.show.mediaType == "tv", entry.show.id > 0 {
            return entry.show
        }

        do {
            let apiKey = try configuredAPIKey()
            if let anilistID = entry.anilistMediaID,
               let mapped = try await MacAniListCatalogService.shared.resolveMedia(
                    anilistID: anilistID,
                    apiKey: apiKey
               ) {
                return mapped
            }

            let candidates = try await fetch(
                path: "/3/search/tv",
                queryItems: [URLQueryItem(name: "query", value: entry.show.title)]
            )
            return Self.bestScheduleDetailMatch(candidates, for: entry.show)
        } catch {
            return nil
        }
    }

    private func fetchAniListSchedule(dayCount: Int, libraryShows: [MacMediaItem]) async throws -> MacAniListScheduleResult {
        let result = try await MacAniListCatalogService.shared.fetchAiringSchedule(daysAhead: dayCount)
        guard !libraryShows.isEmpty else { return result }
        let idsByTMDB = await MacAniListCatalogService.shared.aniListIDsByTMDBShowID(libraryShows.map(\.id))
        var libraryByAniListID: [Int: MacMediaItem] = [:]
        for show in libraryShows {
            for anilistID in idsByTMDB[show.id, default: []] {
                libraryByAniListID[anilistID] = show
            }
        }
        let enriched = result.entries.map { entry in
            guard let anilistID = entry.anilistMediaID,
                  let libraryShow = libraryByAniListID[anilistID] else { return entry }
            return entry.replacingShow(libraryShow)
        }
        return MacAniListScheduleResult(entries: enriched, isAuthoritative: result.isAuthoritative)
    }

    private func animeSchedulePayload(
        dayCount: Int,
        libraryShows: [MacMediaItem],
        forceReload: Bool
    ) async throws -> MacScheduleSourcePayload {
        if !forceReload, let cached = cachedSchedulePayload(animeScheduleCache, dayCount: dayCount) {
            return cached
        }

        let payload: MacScheduleSourcePayload
        do {
            let result = try await fetchAniListSchedule(dayCount: dayCount, libraryShows: libraryShows)
            let warning = result.isAuthoritative
                ? nil
                : "AniList reached its safety page limit, so later anime airings may be missing."
            payload = MacScheduleSourcePayload(entries: result.entries, warning: warning)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let fallback = try await MacMALCatalogService.shared.fetchAiringSchedule(dayCount: dayCount)
            payload = MacScheduleSourcePayload(
                entries: fallback,
                warning: "AniList is unavailable. Showing estimated MyAnimeList dates; MAL does not provide authoritative episode airtimes."
            )
        }
        animeScheduleCache = MacScheduleSourceCache(
            entries: payload.entries,
            dayCount: dayCount,
            fetchedAt: Date(),
            warning: payload.warning
        )
        return payload
    }

    private func westernSchedulePayload(dayCount: Int, forceReload: Bool) async throws -> MacScheduleSourcePayload {
        if !forceReload, let cached = cachedSchedulePayload(westernScheduleCache, dayCount: dayCount) {
            return cached
        }

        let entries = try await MacWesternScheduleService.shared.fetchSchedule(dayCount: dayCount)
        let usedTVMazeFallback = entries.contains { $0.source == .tvMaze }
        let payload = MacScheduleSourcePayload(
            entries: entries,
            warning: usedTVMazeFallback ? "Trakt is unavailable. Showing the TVMaze fallback schedule." : nil
        )
        westernScheduleCache = MacScheduleSourceCache(
            entries: entries,
            dayCount: dayCount,
            fetchedAt: Date(),
            warning: payload.warning
        )
        return payload
    }

    /// Trakt owns Western schedule timing. Like the iPhone/iPad schedule, the Mac
    /// fills in poster/detail fields from TMDB after rows are already visible so
    /// artwork never blocks the authoritative provider result.
    private func startPosterHydrationIfNeeded(loadID: UUID) {
        var seen = Set<Int>()
        let ids = unfilteredScheduleEntries.compactMap { entry -> Int? in
            guard entry.source == .trakt,
                  entry.show.mediaType == "tv",
                  entry.show.id > 0,
                  entry.show.posterPath == nil,
                  !posterHydrationAttemptedTMDBIDs.contains(entry.show.id),
                  seen.insert(entry.show.id).inserted else { return nil }
            return entry.show.id
        }
        guard !ids.isEmpty else { return }

        schedulePosterHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var detailsByID: [Int: TMDBTVShowPayload] = [:]
            let concurrencyLimit = 8
            for startIndex in stride(from: 0, to: ids.count, by: concurrencyLimit) {
                guard !Task.isCancelled, self.activeScheduleLoadID == loadID else { return }
                let chunk = Array(ids[startIndex..<min(startIndex + concurrencyLimit, ids.count)])
                let values = await withTaskGroup(
                    of: (Int, TMDBTVShowPayload?).self,
                    returning: [(Int, TMDBTVShowPayload?)].self
                ) { group in
                    for id in chunk {
                        group.addTask { [weak self] in
                            guard let self else { return (id, nil) }
                            let detail: TMDBTVShowPayload? = try? await self.fetchDecoded(path: "/3/tv/\(id)")
                            return (id, detail)
                        }
                    }
                    var output: [(Int, TMDBTVShowPayload?)] = []
                    for await value in group { output.append(value) }
                    return output
                }
                for (id, detail) in values {
                    if let detail { detailsByID[id] = detail }
                }
            }

            guard !Task.isCancelled, self.activeScheduleLoadID == loadID else { return }
            self.posterHydrationAttemptedTMDBIDs.formUnion(ids)
            guard !detailsByID.isEmpty else { return }

            func hydrated(_ entries: [MacScheduleEntry]) -> [MacScheduleEntry] {
                entries.map { entry in
                    guard let detail = detailsByID[entry.show.id] else { return entry }
                    let show = MacMediaItem(
                        id: entry.show.id,
                        mediaType: "tv",
                        title: detail.name?.nilIfBlank ?? entry.show.title,
                        overview: detail.overview?.nilIfBlank ?? entry.show.overview,
                        posterPath: detail.posterPath ?? entry.show.posterPath,
                        backdropPath: detail.backdropPath ?? entry.show.backdropPath,
                        date: detail.firstAirDate ?? entry.show.date,
                        rating: detail.voteAverage ?? entry.show.rating
                    )
                    return entry.replacingShow(show)
                }
            }

            self.unfilteredScheduleEntries = hydrated(self.unfilteredScheduleEntries)
            self.scheduleEntries = hydrated(self.scheduleEntries)
            if let cache = self.westernScheduleCache {
                self.westernScheduleCache = MacScheduleSourceCache(
                    entries: hydrated(cache.entries),
                    dayCount: cache.dayCount,
                    fetchedAt: cache.fetchedAt,
                    warning: cache.warning
                )
            }
        }
    }

    private func cachedSchedulePayload(
        _ cache: MacScheduleSourceCache?,
        dayCount: Int
    ) -> MacScheduleSourcePayload? {
        guard let cache,
              cache.dayCount >= dayCount,
              Calendar.current.isDate(cache.fetchedAt, inSameDayAs: Date()) else { return nil }
        let age = Date().timeIntervalSince(cache.fetchedAt)
        guard age >= 0, age < Self.scheduleCacheMaxAge else { return nil }
        return MacScheduleSourcePayload(
            entries: Self.scheduleEntries(cache.entries, within: dayCount),
            warning: cache.warning
        )
    }

    private func captureScheduleSource<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    func syncScheduleNotifications() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: MacSchedulePreferences.notificationsEnabledKey) else {
            await syncScheduleNotifications(using: [])
            return
        }
        guard hasLoadedSchedule else {
            await refreshScheduleNotificationsFromStoredPreferences()
            return
        }
        let windowDays = Self.storedScheduleWindowDays(defaults)
        let mode = Self.storedScheduleMode(defaults)
        await syncScheduleNotifications(
            using: reminderScheduleEntries(windowDays: windowDays, mode: mode)
        )
    }

    /// Refreshes Library reminder data without opening Schedule or requesting permission.
    /// This is safe to call on launch because notification authorization is only inspected.
    func refreshScheduleNotificationsFromStoredPreferences(forceReload: Bool = false) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: MacSchedulePreferences.notificationsEnabledKey) else {
            await syncScheduleNotifications(using: [])
            return
        }
        await loadSchedule(
            windowDays: Self.storedScheduleWindowDays(defaults),
            mode: Self.storedScheduleMode(defaults).rawValue,
            forceReload: forceReload
        )
    }

    private func reconcileScheduleNotificationsAfterLibraryChange() async {
        if UserDefaults.standard.bool(forKey: MacSchedulePreferences.notificationsEnabledKey) {
            await refreshScheduleNotificationsFromStoredPreferences(forceReload: true)
            return
        }

        // On launch the schedule may not have been fetched yet. Prune reminders for
        // titles that are no longer followed without deleting valid Library reminders.
        let followedShowIDs = Set(library.lazy.filter { $0.mediaType == "tv" }.map(\.id))
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let managed = pending.filter { $0.identifier.hasPrefix(Self.scheduleNotificationPrefix) }
        guard UserDefaults.standard.bool(forKey: MacSchedulePreferences.notificationsEnabledKey) else {
            let identifiers = managed.map(\.identifier)
            if !identifiers.isEmpty { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
            return
        }
        let staleIDs = managed.compactMap { request -> String? in
            guard let tmdbID = request.content.userInfo["tmdbID"] as? Int else {
                return request.identifier
            }
            return followedShowIDs.contains(tmdbID) ? nil : request.identifier
        }
        if !staleIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: staleIDs) }
    }

    private func visibleScheduleEntries(
        from entries: [MacScheduleEntry],
        windowDays: Int,
        mode: MacScheduleMode
    ) -> [MacScheduleEntry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: windowDays, to: start) ?? start
        return entries
            .filter { entry in
                let day = calendar.startOfDay(for: entry.airDate)
                return day >= start && day < end && mode.includes(entry.classification)
            }
            .sorted {
                if $0.airDate != $1.airDate { return $0.airDate < $1.airDate }
                return $0.show.title.localizedStandardCompare($1.show.title) == .orderedAscending
            }
    }

    private func request(
        path: String,
        queryItems: [URLQueryItem] = [],
        assign: @escaping ([MacMediaItem]) -> Void
    ) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            assign(try await fetch(path: path, queryItems: queryItems))
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Catalog request failed: \(error.localizedDescription)"
        }
    }

    private func fetch(path: String, queryItems: [URLQueryItem] = []) async throws -> [MacMediaItem] {
        let apiKey = try configuredAPIKey()
        guard var components = URLComponents(string: "https://api.themoviedb.org\(path)") else {
            throw URLError(.badURL)
        }
        components.queryItems = queryItems + [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        let payload = try decoder.decode(TMDBPayload.self, from: data)
        return payload.results.compactMap(\.mediaItem)
    }

    private func fetchDecoded<Value: Decodable>(path: String) async throws -> Value {
        let apiKey = try configuredAPIKey()
        let separator = path.contains("?") ? "&" : "?"
        guard let url = URL(string: "https://api.themoviedb.org\(path)\(separator)api_key=\(apiKey)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(Value.self, from: data)
    }

    private func configuredAPIKey() throws -> String {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String,
              !apiKey.isEmpty,
              apiKey != "$(TMDB_API_KEY)" else {
            throw MacCatalogError.missingAPIKey
        }
        return apiKey
    }

    nonisolated private static func enabledHomeAnimeKinds(
        _ defaults: UserDefaults
    ) -> Set<MacAniListCatalogKind> {
        func enabled(_ key: String, default defaultValue: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? defaultValue
        }

        var result = Set<MacAniListCatalogKind>()
        if enabled("macHomeShowTrendingAnime", default: true) { result.insert(.trending) }
        if enabled("macHomeShowPopularAnime", default: true) { result.insert(.popular) }
        if enabled("macHomeShowTopRatedAnime", default: true) { result.insert(.topRated) }
        if enabled("macHomeShowAiringAnime", default: false) { result.insert(.airing) }
        if enabled("macHomeShowUpcomingAnime", default: false) { result.insert(.upcoming) }
        return result
    }

    nonisolated private static func scheduleEntries(
        _ entries: [MacScheduleEntry],
        within dayCount: Int
    ) -> [MacScheduleEntry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: max(dayCount, 1), to: start) ?? .distantFuture
        return entries.filter { $0.airDate >= start && $0.airDate < end }
    }

    nonisolated private static func deduplicatedScheduleEntries(
        _ entries: [MacScheduleEntry]
    ) -> [MacScheduleEntry] {
        var seen = Set<String>()
        return entries
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.airDate != $1.airDate { return $0.airDate < $1.airDate }
                return $0.show.title.localizedStandardCompare($1.show.title) == .orderedAscending
            }
    }

    nonisolated private static func bestScheduleDetailMatch(
        _ candidates: [MacMediaItem],
        for providerItem: MacMediaItem
    ) -> MacMediaItem? {
        guard !candidates.isEmpty else { return nil }
        let providerTitle = normalizedScheduleTitle(providerItem.title)
        let providerYear = providerItem.date.flatMap { Int(String($0.prefix(4))) }
        return candidates.max { lhs, rhs in
            scheduleMatchScore(lhs, title: providerTitle, year: providerYear)
                < scheduleMatchScore(rhs, title: providerTitle, year: providerYear)
        }
    }

    nonisolated private static func scheduleMatchScore(
        _ candidate: MacMediaItem,
        title: String,
        year: Int?
    ) -> Int {
        let candidateTitle = normalizedScheduleTitle(candidate.title)
        var score = candidateTitle == title ? 100 : 0
        if !title.isEmpty, candidateTitle.contains(title) || title.contains(candidateTitle) { score += 30 }
        if let year,
           let candidateYear = candidate.date.flatMap({ Int(String($0.prefix(4))) }) {
            score += max(0, 20 - abs(year - candidateYear) * 5)
        }
        return score
    }

    nonisolated private static func normalizedScheduleTitle(_ value: String) -> String {
        value.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }

    private static func storedScheduleWindowDays(_ defaults: UserDefaults) -> Int {
        let stored = defaults.integer(forKey: "scheduleWindowDays")
        return [7, 14, 21, 30].contains(stored) ? stored : 7
    }

    private static func storedScheduleMode(_ defaults: UserDefaults) -> MacScheduleMode {
        MacScheduleMode(rawValue: defaults.string(forKey: "defaultScheduleMode") ?? "anime") ?? .anime
    }

    private func reminderScheduleEntries(
        windowDays: Int,
        mode: MacScheduleMode
    ) -> [MacScheduleEntry] {
        visibleScheduleEntries(
            from: unfilteredScheduleEntries,
            windowDays: windowDays,
            mode: mode
        )
    }

    private func syncScheduleNotifications(using entries: [MacScheduleEntry]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let managedIDs = pending.map(\.identifier).filter { $0.hasPrefix(Self.scheduleNotificationPrefix) }
        let enabled = UserDefaults.standard.bool(forKey: MacSchedulePreferences.notificationsEnabledKey)

        guard enabled else {
            if !managedIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: managedIDs) }
            scheduleNotificationMessage = nil
            return
        }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
                settings.authorizationStatus == .provisional else {
            if !managedIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: managedIDs) }
            scheduleNotificationMessage = "Airing reminders are on, but macOS notification access is not allowed. Eclipse did not request access automatically."
            return
        }

        if !managedIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: managedIDs) }
        let followedShowIDs = Set(library.lazy.filter { $0.mediaType == "tv" }.map(\.id))
        let followedEntries = entries.filter { followedShowIDs.contains($0.show.id) }
        guard !followedEntries.isEmpty else {
            scheduleNotificationMessage = "No Library shows have an upcoming episode in the current schedule range. Discovery titles never create reminders."
            return
        }
        let defaults = UserDefaults.standard
        let storedEpisodeLead = defaults.object(forKey: "localNotificationEpisodeLeadTime") as? Int ?? 0
        let storedSeasonLead = defaults.object(forKey: "localNotificationSeasonLeadTime") as? Int ?? 86_400
        let episodeLeadSeconds = Self.episodeLeadSeconds(storedEpisodeLead)
        let seasonLeadSeconds = Self.seasonLeadSeconds(storedSeasonLead)
        let includeAnimeSpecials = defaults.object(forKey: "localNotificationIncludeAnimeSpecials") as? Bool ?? false
        let calendar = Calendar.current
        let now = Date()
        var scheduledCount = 0
        var exactTimeCount = 0
        var exactSources = Set<MacScheduleSource>()
        var estimatedSources = Set<MacScheduleSource>()

        for entry in followedEntries where scheduledCount < 32 {
            if entry.isAnimeSpecial && !includeAnimeSpecials { continue }
            let reminderAnchor: Date
            if entry.hasKnownAiringTime {
                reminderAnchor = entry.airDate
            } else {
                let day = calendar.startOfDay(for: entry.airDate)
                guard let dateOnlyAnchor = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) else { continue }
                reminderAnchor = dateOnlyAnchor
            }
            let lead = entry.isSeasonPremiere ? seasonLeadSeconds : episodeLeadSeconds
            let fireDate = reminderAnchor.addingTimeInterval(-lead)
            guard fireDate > now.addingTimeInterval(60) else { continue }

            let content = UNMutableNotificationContent()
            content.title = entry.show.title
            content.subtitle = entry.episodeLabel
            if entry.hasKnownAiringTime {
                let airtime = entry.airDate.formatted(date: .abbreviated, time: .shortened)
                content.body = entry.episodeTitle.isEmpty
                    ? "A new episode airs \(airtime), according to \(entry.source.displayName)."
                    : "\(entry.episodeTitle) airs \(airtime), according to \(entry.source.displayName)."
            } else {
                let listedDate = entry.airDate.formatted(date: .abbreviated, time: .omitted)
                content.body = entry.episodeTitle.isEmpty
                    ? "An episode is estimated for \(listedDate) by \(entry.source.displayName); no exact airtime is available."
                    : "\(entry.episodeTitle) is estimated for \(listedDate) by \(entry.source.displayName); no exact airtime is available."
            }
            content.sound = .default
            content.categoryIdentifier = "ECLIPSE_MAC_SCHEDULE"
            content.userInfo = [
                "route": "schedule",
                "tmdbID": entry.show.id,
                "season": entry.seasonNumber ?? 0,
                "episode": entry.episodeNumber,
                "mediaType": entry.show.mediaType,
                "title": entry.show.title,
                "scheduleSource": entry.source.rawValue
            ]

            var dateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            dateComponents.timeZone = .current
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(Self.scheduleNotificationPrefix)\(entry.id)",
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
                scheduledCount += 1
                if entry.hasKnownAiringTime {
                    exactTimeCount += 1
                    exactSources.insert(entry.source)
                } else {
                    estimatedSources.insert(entry.source)
                }
            } catch {
                continue
            }
        }

        if scheduledCount == 0 {
            scheduleNotificationMessage = "No future reminders could be scheduled from the current entries."
        } else if exactTimeCount == scheduledCount {
            let sources = Self.scheduleSourceList(exactSources)
            scheduleNotificationMessage = "\(scheduledCount) exact-time reminder\(scheduledCount == 1 ? "" : "s") scheduled from \(sources)."
        } else if exactTimeCount == 0 {
            let sources = Self.scheduleSourceList(estimatedSources)
            scheduleNotificationMessage = "\(scheduledCount) date-based reminder\(scheduledCount == 1 ? "" : "s") scheduled from \(sources) for 9:00 AM local on the estimated day."
        } else {
            let exact = Self.scheduleSourceList(exactSources)
            let estimated = Self.scheduleSourceList(estimatedSources)
            scheduleNotificationMessage = "\(scheduledCount) reminders scheduled: \(exactTimeCount) use exact \(exact) airtimes; \(estimated) date estimates use 9:00 AM local."
        }
    }

    nonisolated private static func episodeLeadSeconds(_ storedValue: Int) -> TimeInterval {
        // Mac's first timing controls stored minutes; iOS stores canonical seconds.
        if [0, 15, 30, 60, 120].contains(storedValue) {
            return TimeInterval(storedValue * 60)
        }
        return TimeInterval(max(0, storedValue))
    }

    nonisolated private static func seasonLeadSeconds(_ storedValue: Int) -> TimeInterval {
        // Mac's first timing controls stored hours; iOS stores canonical seconds.
        if storedValue >= 0 && storedValue <= 168 {
            return TimeInterval(storedValue * 3_600)
        }
        return TimeInterval(max(0, storedValue))
    }

    nonisolated private static func scheduleSourceList(_ sources: Set<MacScheduleSource>) -> String {
        let names = sources.map(\.displayName).sorted()
        switch names.count {
        case 0: return "the schedule provider"
        case 1: return names[0]
        case 2: return names.joined(separator: " and ")
        default: return names.dropLast().joined(separator: ", ") + ", and " + (names.last ?? "")
        }
    }

    private static let scheduleNotificationPrefix = "eclipse.mac.schedule."
    private static let scheduleCacheMaxAge: TimeInterval = 6 * 60 * 60
}

private enum MacScheduleMode: String {
    case anime
    case western
    case combined

    func includes(_ classification: MacScheduleClassification) -> Bool {
        switch self {
        case .anime: classification == .anime
        case .western: classification == .western
        case .combined: classification == .anime || classification == .western
        }
    }
}

private struct MacScheduleSourcePayload: Sendable {
    let entries: [MacScheduleEntry]
    let warning: String?
}

private struct MacScheduleSourceCache: Sendable {
    let entries: [MacScheduleEntry]
    let dayCount: Int
    let fetchedAt: Date
    let warning: String?
}

private struct MacTMDBHomeCatalogs: Sendable {
    let trending: [MacMediaItem]
    let movies: [MacMediaItem]
    let shows: [MacMediaItem]
    let topRated: [MacMediaItem]
}

private struct MacAnimeHomePayload: Sendable {
    let catalogs: [MacAniListCatalogKind: [MacMediaItem]]
    let warning: String?
}

private struct TMDBTVShowPayload: Decodable, Sendable {
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let seasons: [TMDBTVSeasonRow]

    enum CodingKeys: String, CodingKey {
        case name, overview, seasons
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
    }
}

private struct TMDBTVSeasonRow: Decodable, Sendable {
    let name: String?
    let seasonNumber: Int
    let episodeCount: Int
    let airDate: String?
    let posterPath: String?

    enum CodingKeys: String, CodingKey {
        case name
        case seasonNumber = "season_number"
        case episodeCount = "episode_count"
        case airDate = "air_date"
        case posterPath = "poster_path"
    }
}

private struct TMDBTVSeasonPayload: Decodable {
    let episodes: [TMDBTVEpisodeRow]
}

private struct TMDBTVEpisodeRow: Decodable {
    let id: Int
    let name: String?
    let overview: String?
    let airDate: String?
    let episodeNumber: Int
    let seasonNumber: Int
    let stillPath: String?
    let runtime: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, runtime
        case airDate = "air_date"
        case episodeNumber = "episode_number"
        case seasonNumber = "season_number"
        case stillPath = "still_path"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum MacCatalogError: LocalizedError {
    case missingAPIKey
    case scheduleSourcesUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add TMDB_API_KEY to Build.local.xcconfig to load the media catalog."
        case .scheduleSourcesUnavailable(let detail):
            detail.isEmpty ? "AniList and TV schedule sources are unavailable." : detail
        }
    }
}

private struct TMDBPayload: Decodable {
    let results: [TMDBRow]
}

private struct TMDBRow: Decodable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case mediaType = "media_type"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
    }

    var mediaItem: MacMediaItem? {
        let type = mediaType ?? (title == nil ? "tv" : "movie")
        guard type == "movie" || type == "tv", let displayTitle = title ?? name else { return nil }
        return MacMediaItem(
            id: id,
            mediaType: type,
            title: displayTitle,
            overview: overview ?? "",
            posterPath: posterPath,
            backdropPath: backdropPath,
            date: releaseDate ?? firstAirDate,
            rating: voteAverage ?? 0
        )
    }
}

@MainActor
final class MacDownloadStore: NSObject, ObservableObject {
    static let shared = MacDownloadStore()

    struct Item: Identifiable, Hashable {
        let id: UUID
        var title: String
        var remoteURL: URL?
        var headers: [String: String]?
        var remoteFileExtension: String?
        var localFilename: String?
        var progress: Double
        var state: State
        var error: String?
        fileprivate var isLegacyCredentialFallback: Bool

        enum State: String, Codable { case queued, downloading, completed, failed }
    }

    private struct DownloadCredential: Codable {
        let version: Int
        let remoteURL: URL
        let headers: [String: String]

        init(remoteURL: URL, headers: [String: String]) {
            version = 1
            self.remoteURL = remoteURL
            self.headers = headers
        }
    }

    private struct KeychainFailure: Error {
        let status: OSStatus
    }

    private struct PersistedEnvelope: Encodable {
        let version: Int
        let items: [PersistedItem]
        let credentialDeleteTombstones: [UUID]
    }

    private struct PersistedItem: Codable {
        let id: UUID
        let title: String
        let remoteFileExtension: String?
        let localFilename: String?
        let progress: Double
        let state: Item.State
        let error: String?

        // These fields exist only while an old plaintext record cannot be moved
        // into Keychain. Newly added downloads never populate them.
        let legacyMigrationPending: Bool?
        let legacyRemoteURL: URL?
        let legacyHeaders: [String: String]?
    }

    private struct LegacyPersistedItem: Decodable {
        let id: UUID
        let title: String
        let remoteURL: URL
        let headers: [String: String]?
        let localFilename: String?
        let progress: Double
        let state: Item.State
        let error: String?
    }

    @Published private(set) var items: [Item] = []
    private var sessions: [UUID: URLSessionDownloadTask] = [:]
    private var credentialDeleteTombstones: Set<UUID> = []
    private var isMonitoringProgress = false
    private var isPersistenceLocked = false
    private let persistenceKey = "macDownloads.v2"
    private let legacyPersistenceKey = "macDownloads.v1"
    private let keychainService = "app.Eclipse.Soupy.mac.download-credentials.v1"
    private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    private override init() {
        super.init()
        loadPersistedItems()
        retryCredentialDeletes()
        persist()
    }

    func add(url: URL, title: String, headers: [String: String] = [:]) {
        let id = UUID()
        let fileExtension = normalizedFileExtension(url.pathExtension)
        guard !isPersistenceLocked else {
            let item = Item(
                id: id,
                title: title,
                remoteURL: nil,
                headers: nil,
                remoteFileExtension: fileExtension,
                localFilename: nil,
                progress: 0,
                state: .failed,
                error: "Saved download data is from an unsupported version or is damaged. It was preserved unchanged, and this download was not started.",
                isLegacyCredentialFallback: false
            )
            items.insert(item, at: 0)
            return
        }
        let credential = DownloadCredential(remoteURL: url, headers: headers)
        guard case .success = storeCredential(credential, id: id) else {
            let item = Item(
                id: id,
                title: title,
                remoteURL: nil,
                headers: nil,
                remoteFileExtension: fileExtension,
                localFilename: nil,
                progress: 0,
                state: .failed,
                error: "Couldn’t securely save this download’s address in Keychain. The download was not started.",
                isLegacyCredentialFallback: false
            )
            items.insert(item, at: 0)
            persist()
            return
        }

        let item = Item(
            id: id,
            title: title,
            remoteURL: nil,
            headers: nil,
            remoteFileExtension: fileExtension,
            localFilename: nil,
            progress: 0,
            state: .queued,
            error: nil,
            isLegacyCredentialFallback: false
        )
        items.insert(item, at: 0)
        persist()
        begin(id: item.id)
    }

    func begin(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), sessions[id] == nil else { return }
        guard items[index].state != .completed else { return }

        let credential: DownloadCredential
        switch readCredential(id: id) {
        case .success(let storedCredential):
            credential = storedCredential
            if items[index].isLegacyCredentialFallback {
                clearLegacyCredentialFallback(at: index)
            }
        case .failure:
            guard items[index].isLegacyCredentialFallback,
                  let legacyURL = items[index].remoteURL else {
                items[index].state = .failed
                items[index].error = "Secure download credentials are missing. Add this download again to retry."
                persist()
                return
            }

            let legacyCredential = DownloadCredential(
                remoteURL: legacyURL,
                headers: items[index].headers ?? [:]
            )
            if case .success = storeCredential(legacyCredential, id: id) {
                clearLegacyCredentialFallback(at: index)
            }
            credential = legacyCredential
        }

        items[index].state = .downloading
        items[index].error = nil
        var request = URLRequest(url: credential.remoteURL)
        request.timeoutInterval = 60
        for (field, value) in credential.headers { request.setValue(value, forHTTPHeaderField: field) }
        let task = downloadSession.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            Task { @MainActor in
                self?.finish(id: id, temporaryURL: temporaryURL, response: response, error: error)
            }
        }
        sessions[id] = task
        persist()
        task.resume()
        monitorProgress()
    }

    func delete(_ item: Item) {
        sessions[item.id]?.cancel()
        sessions[item.id] = nil
        if let url = localURL(for: item) { try? FileManager.default.removeItem(at: url) }
        items.removeAll { $0.id == item.id }
        deleteCredentialOrTombstone(id: item.id)
        persist()
    }

    func localURL(for item: Item) -> URL? {
        guard let name = item.localFilename else { return nil }
        return downloadsDirectory.appendingPathComponent(name)
    }

    func reveal(_ item: Item) {
        guard let url = localURL(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func export(_ item: Item) {
        guard let source = localURL(for: item) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
    }

    private var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eclipse", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func finish(id: UUID, temporaryURL: URL?, response: URLResponse?, error: Error?) {
        sessions[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let error {
            items[index].state = .failed
            items[index].error = error.localizedDescription
        } else if let response = response as? HTTPURLResponse,
                  !(200...299).contains(response.statusCode) {
            items[index].state = .failed
            items[index].error = "Download failed because the server returned HTTP \(response.statusCode)."
        } else if let temporaryURL {
            let ext = items[index].remoteFileExtension ?? "mp4"
            let filename = "\(id.uuidString).\(ext)"
            let destination = downloadsDirectory.appendingPathComponent(filename)
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                items[index].localFilename = filename
                items[index].progress = 1
                items[index].state = .completed
                items[index].error = nil
                clearLegacyCredentialFallback(at: index)
                deleteCredentialOrTombstone(id: id)
            } catch {
                items[index].state = .failed
                items[index].error = error.localizedDescription
            }
        } else {
            items[index].state = .failed
            items[index].error = "The download finished without a file."
        }
        persist()
    }

    private func monitorProgress() {
        guard !sessions.isEmpty, !isMonitoringProgress else { return }
        isMonitoringProgress = true
        Task { [weak self] in
            while let self, !self.sessions.isEmpty {
                for (id, task) in self.sessions {
                    guard let index = self.items.firstIndex(where: { $0.id == id }) else { continue }
                    let fraction = task.progress.fractionCompleted
                    if fraction.isFinite, fraction >= 0 { self.items[index].progress = min(0.99, fraction) }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
            self?.isMonitoringProgress = false
        }
    }

    private func persist() {
        guard !isPersistenceLocked else { return }
        retryCredentialDeletes()
        let persistedItems = items.map { item in
            PersistedItem(
                id: item.id,
                title: item.title,
                remoteFileExtension: item.remoteFileExtension,
                localFilename: item.localFilename,
                progress: item.progress,
                state: item.state,
                error: item.error,
                legacyMigrationPending: item.isLegacyCredentialFallback ? true : nil,
                legacyRemoteURL: item.isLegacyCredentialFallback ? item.remoteURL : nil,
                legacyHeaders: item.isLegacyCredentialFallback ? item.headers : nil
            )
        }
        let envelope = PersistedEnvelope(
            version: 2,
            items: persistedItems,
            credentialDeleteTombstones: credentialDeleteTombstones.sorted { $0.uuidString < $1.uuidString }
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
        if UserDefaults.standard.data(forKey: persistenceKey) == data {
            UserDefaults.standard.removeObject(forKey: legacyPersistenceKey)
        }
    }

    private func loadPersistedItems() {
        if let storedValue = UserDefaults.standard.object(forKey: persistenceKey) {
            guard let data = storedValue as? Data else {
                isPersistenceLocked = true
                return
            }
            if !loadVersionedItems(from: data) {
                // Keep an unknown or malformed current envelope byte-for-byte.
                // Writes stay locked instead of silently replacing recoverable data.
                isPersistenceLocked = true
            }
            return
        }
        guard let legacyValue = UserDefaults.standard.object(forKey: legacyPersistenceKey) else { return }
        guard let legacyData = legacyValue as? Data, loadLegacyItems(from: legacyData) else {
            isPersistenceLocked = true
            return
        }
    }

    @discardableResult
    private func loadVersionedItems(from data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int,
              version == 2,
              let rawItems = root["items"] as? [Any],
              let rawTombstones = root["credentialDeleteTombstones"] as? [String] else {
            return false
        }

        let tombstones = rawTombstones.compactMap(UUID.init(uuidString:))
        guard tombstones.count == rawTombstones.count else { return false }
        credentialDeleteTombstones = Set(tombstones)

        let restoredItems: [Item] = rawItems.compactMap { rawItem -> Item? in
            guard let itemData = try? JSONSerialization.data(withJSONObject: rawItem),
                  let item = try? JSONDecoder().decode(PersistedItem.self, from: itemData) else {
                return nil
            }
            return restore(item)
        }
        guard rawItems.isEmpty || !restoredItems.isEmpty else { return false }
        items = restoredItems
        return true
    }

    @discardableResult
    private func loadLegacyItems(from data: Data) -> Bool {
        guard let rawItems = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return false }
        let restoredItems: [Item] = rawItems.compactMap { rawItem -> Item? in
            guard let itemData = try? JSONSerialization.data(withJSONObject: rawItem),
                  let legacy = try? JSONDecoder().decode(LegacyPersistedItem.self, from: itemData) else {
                return nil
            }
            return migrate(legacy)
        }
        guard rawItems.isEmpty || !restoredItems.isEmpty else { return false }
        items = restoredItems
        return true
    }

    private func restore(_ persisted: PersistedItem) -> Item {
        var state = persisted.state
        if state == .downloading { state = .queued }

        var item = Item(
            id: persisted.id,
            title: persisted.title,
            remoteURL: nil,
            headers: nil,
            remoteFileExtension: normalizedFileExtension(persisted.remoteFileExtension ?? ""),
            localFilename: persisted.localFilename,
            progress: persisted.progress,
            state: state,
            error: persisted.error,
            isLegacyCredentialFallback: false
        )

        if state == .completed {
            deleteCredentialOrTombstone(id: persisted.id)
            return item
        }

        guard persisted.legacyMigrationPending == true,
              let legacyURL = persisted.legacyRemoteURL else {
            return item
        }

        let credential = DownloadCredential(
            remoteURL: legacyURL,
            headers: persisted.legacyHeaders ?? [:]
        )
        if case .success = storeCredential(credential, id: persisted.id) {
            return item
        }
        item.remoteURL = legacyURL
        item.headers = persisted.legacyHeaders
        item.isLegacyCredentialFallback = true
        return item
    }

    private func migrate(_ legacy: LegacyPersistedItem) -> Item {
        var state = legacy.state
        if state == .downloading { state = .queued }
        let fileExtension = normalizedFileExtension(legacy.remoteURL.pathExtension)

        var item = Item(
            id: legacy.id,
            title: legacy.title,
            remoteURL: nil,
            headers: nil,
            remoteFileExtension: fileExtension,
            localFilename: legacy.localFilename,
            progress: legacy.progress,
            state: state,
            error: legacy.error,
            isLegacyCredentialFallback: false
        )
        guard state != .completed else {
            deleteCredentialOrTombstone(id: legacy.id)
            return item
        }

        let credential = DownloadCredential(
            remoteURL: legacy.remoteURL,
            headers: legacy.headers ?? [:]
        )
        if case .failure = storeCredential(credential, id: legacy.id) {
            item.remoteURL = legacy.remoteURL
            item.headers = legacy.headers
            item.isLegacyCredentialFallback = true
        }
        return item
    }

    private func clearLegacyCredentialFallback(at index: Int) {
        items[index].remoteURL = nil
        items[index].headers = nil
        items[index].isLegacyCredentialFallback = false
    }

    private func normalizedFileExtension(_ candidate: String) -> String? {
        let allowed = candidate.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let value = String(String.UnicodeScalarView(allowed)).prefix(12)
        return value.isEmpty ? nil : String(value)
    }

    private func keychainQuery(id: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: id.uuidString
        ]
    }

    private func storeCredential(_ credential: DownloadCredential, id: UUID) -> Result<Void, KeychainFailure> {
        guard let data = try? JSONEncoder().encode(credential) else {
            return .failure(KeychainFailure(status: errSecParam))
        }

        var attributes = keychainQuery(id: id)
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return .success(()) }
        guard addStatus == errSecDuplicateItem else {
            return .failure(KeychainFailure(status: addStatus))
        }

        let updateStatus = SecItemUpdate(
            keychainQuery(id: id) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        return updateStatus == errSecSuccess
            ? .success(())
            : .failure(KeychainFailure(status: updateStatus))
    }

    private func readCredential(id: UUID) -> Result<DownloadCredential, KeychainFailure> {
        var query = keychainQuery(id: id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return .failure(KeychainFailure(status: status))
        }
        guard let data = result as? Data,
              let credential = try? JSONDecoder().decode(DownloadCredential.self, from: data),
              credential.version == 1 else {
            return .failure(KeychainFailure(status: errSecDecode))
        }
        return .success(credential)
    }

    private func deleteCredential(id: UUID) -> OSStatus {
        SecItemDelete(keychainQuery(id: id) as CFDictionary)
    }

    private func deleteCredentialOrTombstone(id: UUID) {
        let status = deleteCredential(id: id)
        if status == errSecSuccess || status == errSecItemNotFound {
            credentialDeleteTombstones.remove(id)
        } else {
            credentialDeleteTombstones.insert(id)
        }
    }

    private func retryCredentialDeletes() {
        guard !credentialDeleteTombstones.isEmpty else { return }
        for id in Array(credentialDeleteTombstones) {
            let status = deleteCredential(id: id)
            if status == errSecSuccess || status == errSecItemNotFound {
                credentialDeleteTombstones.remove(id)
            }
        }
    }
}

struct MacMediaGrid: View {
    let items: [MacMediaItem]
    @EnvironmentObject private var catalog: MacCatalogStore
    @State private var selected: MacMediaItem?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165, maximum: 220), spacing: 18)], spacing: 22) {
            ForEach(items) { item in
                Button { selected = item } label: { MacMediaCard(item: item) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(catalog.isInLibrary(item) ? "Remove from Library" : "Add to Library") { catalog.toggleLibrary(item) }
                    }
            }
        }
        .sheet(item: $selected) { MacMediaDetail(item: $0) }
    }
}

enum MacMediaCardArtworkStyle: Equatable {
    case poster
    case landscape
}

struct MacMediaCard: View {
    let item: MacMediaItem
    var artworkStyle: MacMediaCardArtworkStyle = .poster
    @State private var isHovering = false

    private var artworkURL: URL? {
        switch artworkStyle {
        case .poster:
            item.posterURL ?? item.backdropURL
        case .landscape:
            item.backdropURL ?? item.posterURL
        }
    }

    private var artworkAspectRatio: CGFloat {
        artworkStyle == .landscape ? 16 / 9 : 2 / 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AsyncImage(url: artworkURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { ZStack { Color.white.opacity(0.06); Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary) } }
            }
            .aspectRatio(artworkAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(isHovering ? 0.22 : 0.08)))
            .shadow(color: .black.opacity(isHovering ? 0.46 : 0.25), radius: isHovering ? 16 : 8, y: 6)
            Text(item.title).font(.headline).lineLimit(1)
            HStack {
                Text(item.date?.prefix(4) ?? "")
                Spacer()
                Label(String(format: "%.1f", item.rating), systemImage: "star.fill")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .scaleEffect(isHovering ? 1.025 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

struct MacMediaDetail: View {
    let item: MacMediaItem
    @EnvironmentObject private var catalog: MacCatalogStore
    @EnvironmentObject private var playback: MacPlaybackController
    @EnvironmentObject private var services: MacStremioStore
    @EnvironmentObject private var legacyServices: MacLegacyServiceStore
    @EnvironmentObject private var mediaState: MacMediaStateStore
    @Environment(\.dismiss) private var dismiss
    @State private var showServices = false
    @State private var selectedEpisode: MacTVEpisode?

    var body: some View {
        ZStack {
            EclipseMacBackground()
            ScrollView {
                VStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        AsyncImage(url: item.backdropURL) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color.white.opacity(0.05)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 380, maxHeight: 380)
                        .clipped()

                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.08),
                                .init(color: .black.opacity(0.28), location: 0.46),
                                .init(color: Color(red: 0.055, green: 0.047, blue: 0.075), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )

                        HStack(alignment: .bottom, spacing: 24) {
                            AsyncImage(url: item.posterURL) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() }
                                else { Color.white.opacity(0.06).overlay(Image(systemName: "film")) }
                            }
                            .frame(width: 150, height: 225)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.13)))
                            .shadow(color: .black.opacity(0.55), radius: 18, y: 8)

                            VStack(alignment: .leading, spacing: 11) {
                                Text(item.title)
                                    .font(.system(size: 40, weight: .black, design: .rounded))
                                    .lineLimit(2)
                                    .shadow(color: .black.opacity(0.8), radius: 10, y: 3)
                                HStack(spacing: 12) {
                                    if let date = item.date {
                                        Text(String(date.prefix(4)))
                                    }
                                    Text(item.mediaType == "movie" ? "Movie" : "TV Series")
                                    Label(String(format: "%.1f", item.rating), systemImage: "star.fill")
                                        .foregroundStyle(.yellow)
                                }
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.86))

                                HStack(spacing: 12) {
                                    Button(item.mediaType == "tv" ? "Choose Episode" : "Find Streams") { showServices = true }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(services.addons.filter(\.isActive).isEmpty && legacyServices.activeServices.isEmpty)
                                    Button {
                                        catalog.toggleLibrary(item)
                                    } label: {
                                        Label(
                                            catalog.isInLibrary(item) ? "In Library" : "Add to Library",
                                            systemImage: catalog.isInLibrary(item) ? "checkmark" : "plus"
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 36)
                        .padding(.bottom, 28)
                    }

                    HStack(alignment: .top, spacing: 20) {
                        MacGlassPanel {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Overview").font(.title2.bold())
                                Text(item.overview.isEmpty ? "No overview is available for this title." : item.overview)
                                    .font(.body)
                                    .foregroundStyle(.white.opacity(0.76))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                        }

                        MacGlassPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("My Rating").font(.headline)
                                Picker("My Rating", selection: Binding(
                                    get: { Int(mediaState.rating(for: item) ?? 0) },
                                    set: { mediaState.setRating($0 == 0 ? nil : Double($0), for: item) }
                                )) {
                                    Text("Not Rated").tag(0)
                                    ForEach(1...10, id: \.self) { Text("\($0) / 10").tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 150)
                                Text("Your rating syncs with Eclipse media state where available.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 210, alignment: .leading)
                            .padding(20)
                        }
                    }
                    .padding(.horizontal, 36)

                    if item.mediaType == "tv" {
                        MacGlassPanel {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Episodes").font(.title2.bold())
                                        Text("Choose from the seasons and episodes published by TMDB.")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                MacEpisodeBrowser(
                                    item: item,
                                    presentation: .detail,
                                    selection: $selectedEpisode,
                                    onFindStreams: { episode in
                                        selectedEpisode = episode
                                        showServices = true
                                    }
                                )
                            }
                            .padding(20)
                        }
                        .padding(.horizontal, 36)
                        .padding(.top, 20)
                    }

                    Color.clear.frame(height: 36)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .padding(18)
        }
        .frame(width: 920, height: 720)
        .sheet(isPresented: $showServices) {
            MacStreamPicker(item: item, initialEpisode: selectedEpisode)
                .environmentObject(playback)
                .environmentObject(services)
                .environmentObject(legacyServices)
        }
    }
}

private enum MacEpisodeBrowserPresentation {
    case detail
    case compact
}

private struct MacEpisodeBrowser: View {
    let item: MacMediaItem
    let presentation: MacEpisodeBrowserPresentation
    @Binding var selection: MacTVEpisode?
    var onFindStreams: ((MacTVEpisode) -> Void)?

    @EnvironmentObject private var catalog: MacCatalogStore
    @State private var seasons: [MacTVSeasonSummary] = []
    @State private var episodes: [MacTVEpisode] = []
    @State private var selectedSeasonNumber = -1
    @State private var isLoadingSeasons = false
    @State private var isLoadingEpisodes = false
    @State private var errorMessage: String?
    @State private var episodeLoadID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Picker("Season", selection: $selectedSeasonNumber) {
                    if seasons.isEmpty {
                        Text(isLoadingSeasons ? "Loading seasons…" : "No seasons").tag(-1)
                    }
                    ForEach(seasons) { season in
                        Text("\(season.displayName) · \(season.episodeCount)").tag(season.seasonNumber)
                    }
                }
                .frame(maxWidth: presentation == .compact ? 260 : 310)
                .disabled(isLoadingSeasons || seasons.isEmpty)

                if isLoadingSeasons || isLoadingEpisodes {
                    ProgressView().controlSize(.small)
                }

                Spacer(minLength: 0)

                if presentation == .compact, !episodes.isEmpty {
                    Picker("Episode", selection: episodeSelectionBinding) {
                        ForEach(episodes) { episode in
                            Text("E\(episode.episodeNumber) · \(episode.displayName)").tag(episode.id)
                        }
                    }
                    .frame(maxWidth: 360)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if !isLoadingSeasons && seasons.isEmpty {
                ContentUnavailableView(
                    "No Episode Metadata",
                    systemImage: "rectangle.stack.badge.questionmark",
                    description: Text("TMDB did not return any seasons with episodes for this series.")
                )
                .frame(maxWidth: .infinity, minHeight: presentation == .compact ? 90 : 150)
            } else if !isLoadingEpisodes && selectedSeasonNumber >= 0 && episodes.isEmpty {
                ContentUnavailableView(
                    "No Episodes in This Season",
                    systemImage: "rectangle.stack.badge.questionmark"
                )
                .frame(maxWidth: .infinity, minHeight: presentation == .compact ? 90 : 150)
            } else if presentation == .detail {
                detailEpisodeList
            } else if let selection {
                compactEpisodeSummary(selection)
            }
        }
        .task(id: item.id) { await loadSeasons() }
        .onChange(of: selectedSeasonNumber) { _, newValue in
            guard newValue >= 0 else { return }
            Task { await loadEpisodes(seasonNumber: newValue) }
        }
    }

    private var episodeSelectionBinding: Binding<Int> {
        Binding(
            get: { selection?.id ?? episodes.first?.id ?? -1 },
            set: { id in
                if let episode = episodes.first(where: { $0.id == id }) {
                    selection = episode
                }
            }
        )
    }

    private var detailEpisodeList: some View {
        LazyVStack(spacing: 10) {
            ForEach(episodes) { episode in
                HStack(spacing: 14) {
                    AsyncImage(url: episode.stillURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            ZStack {
                                Color.white.opacity(0.055)
                                Image(systemName: "play.rectangle")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 150, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text("E\(episode.episodeNumber) · \(episode.displayName)")
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            if let airDate = formattedAirDate(episode.airDate) { Text(airDate) }
                            if let runtime = episode.runtime, runtime > 0 { Text("\(runtime) min") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if !episode.overview.isEmpty {
                            Text(episode.overview)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Find Streams") {
                        selection = episode
                        onFindStreams?(episode)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(selection?.id == episode.id ? Color.purple.opacity(0.18) : Color.white.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { selection = episode }
            }
        }
    }

    private func compactEpisodeSummary(_ episode: MacTVEpisode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: episode.stillURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Color.white.opacity(0.055).overlay(Image(systemName: "play.rectangle")) }
            }
            .frame(width: 116, height: 65)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.episodeLabel) · \(episode.displayName)")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let airDate = formattedAirDate(episode.airDate) { Text(airDate) }
                    if let runtime = episode.runtime, runtime > 0 { Text("\(runtime) min") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !episode.overview.isEmpty {
                    Text(episode.overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @MainActor
    private func loadSeasons() async {
        isLoadingSeasons = true
        errorMessage = nil
        do {
            let loaded = try await catalog.tvSeasons(for: item)
            guard !Task.isCancelled else { return }
            seasons = loaded
            if loaded.isEmpty {
                selectedSeasonNumber = -1
                episodes = []
                selection = nil
                isLoadingSeasons = false
                return
            }
            let requestedSeason = selection?.seasonNumber
            selectedSeasonNumber = if let requestedSeason,
                                      loaded.contains(where: { $0.seasonNumber == requestedSeason }) {
                requestedSeason
            } else {
                loaded.first?.seasonNumber ?? -1
            }
        } catch is CancellationError {
            return
        } catch {
            seasons = []
            episodes = []
            selection = nil
            errorMessage = "Episode metadata could not be loaded: \(error.localizedDescription)"
        }
        isLoadingSeasons = false
    }

    @MainActor
    private func loadEpisodes(seasonNumber: Int) async {
        let loadID = UUID()
        episodeLoadID = loadID
        isLoadingEpisodes = true
        errorMessage = nil
        do {
            let loaded = try await catalog.tvEpisodes(for: item, seasonNumber: seasonNumber)
            guard episodeLoadID == loadID, !Task.isCancelled else { return }
            episodes = loaded
            if let current = selection,
               current.seasonNumber == seasonNumber,
               let refreshed = loaded.first(where: { $0.id == current.id }) {
                selection = refreshed
            } else {
                selection = loaded.first
            }
        } catch is CancellationError {
            return
        } catch {
            guard episodeLoadID == loadID else { return }
            episodes = []
            selection = nil
            errorMessage = "This season could not be loaded: \(error.localizedDescription)"
        }
        if episodeLoadID == loadID { isLoadingEpisodes = false }
    }

    private func formattedAirDate(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct MacStreamPicker: View {
    let item: MacMediaItem
    @EnvironmentObject private var playback: MacPlaybackController
    @EnvironmentObject private var services: MacStremioStore
    @EnvironmentObject private var legacyServices: MacLegacyServiceStore
    @EnvironmentObject private var downloads: MacDownloadStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEpisode: MacTVEpisode?
    @State private var streams: [MacStremioStream] = []
    @State private var serviceResults: [MacLegacySearchResult] = []
    @State private var serviceStreams: [MacLegacyStream] = []
    @State private var resolvingServiceID: String?
    @State private var pendingServiceResult: MacLegacySearchResult?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didPerformInitialSearch = false
    @State private var activeStreamLoadID = UUID()

    init(item: MacMediaItem, initialEpisode: MacTVEpisode? = nil) {
        self.item = item
        _selectedEpisode = State(initialValue: initialEpisode)
    }

    private var selectedSeasonNumber: Int? {
        item.mediaType == "tv" ? selectedEpisode?.seasonNumber : nil
    }

    private var selectedEpisodeNumber: Int? {
        item.mediaType == "tv" ? selectedEpisode?.episodeNumber : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Streams").font(.title2.bold())
                    Text(item.title).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Search") { Task { await load() } }
                    .disabled(isLoading || (item.mediaType == "tv" && selectedEpisode == nil))
            }

            if item.mediaType == "tv" {
                MacEpisodeBrowser(
                    item: item,
                    presentation: .compact,
                    selection: $selectedEpisode,
                    onFindStreams: nil
                )
            }

            if isLoading {
                HStack { ProgressView(); Text("Checking installed addons and Services…") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, streams.isEmpty, serviceResults.isEmpty, serviceStreams.isEmpty {
                ContentUnavailableView("Couldn’t Load Streams", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if streams.isEmpty && serviceResults.isEmpty && serviceStreams.isEmpty {
                ContentUnavailableView("No Direct Streams", systemImage: "network.slash", description: Text("Torrent-only results are intentionally excluded on Mac."))
            } else {
                List {
                    if !streams.isEmpty {
                        Section("Stremio") {
                            ForEach(streams) { stream in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(stream.title).font(.headline)
                                        HStack {
                                            Text(stream.addonName)
                                            if let size = stream.formattedSize { Text("· \(size)") }
                                        }
                                        .font(.caption).foregroundStyle(.secondary)
                                        if let detail = stream.detail { Text(detail).font(.caption).lineLimit(2) }
                                    }
                                    Spacer()
                                    streamActions(url: stream.url, headers: stream.headers)
                                }
                                .padding(.vertical, 5)
                            }
                        }
                    }
                    if !serviceStreams.isEmpty {
                        Section("Resolved Service Streams") {
                            ForEach(serviceStreams) { stream in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(stream.title).font(.headline)
                                        Text(stream.serviceName).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    streamActions(url: stream.url, headers: stream.headers)
                                }
                                .padding(.vertical, 5)
                            }
                        }
                    }
                    if !serviceResults.isEmpty {
                        Section("Eclipse Services") {
                            ForEach(serviceResults) { result in
                                HStack(spacing: 12) {
                                    AsyncImage(url: result.imageURL) { phase in
                                        if let image = phase.image { image.resizable().scaledToFill() }
                                        else { Image(systemName: "film").foregroundStyle(.secondary) }
                                    }
                                    .frame(width: 42, height: 58).clipped().cornerRadius(6)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.title).font(.headline).lineLimit(2)
                                        Text(result.service.metadata.sourceName).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(resolvingServiceID == result.id ? "Resolving…" : "Resolve") {
                                        Task { await resolve(result) }
                                    }
                                    .disabled(resolvingServiceID != nil)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    if legacyServices.pendingVerificationURL != nil {
                        Section("Provider Verification") {
                            HStack {
                                Text("A Service needs a browser security check before it can return streams.")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Verify & Retry") { Task { await verifyAndRetry() } }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    if let errorMessage, legacyServices.pendingVerificationURL == nil {
                        Section("Notice") {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Text("\(streams.count + serviceStreams.count) playable HTTP stream\(streams.count + serviceStreams.count == 1 ? "" : "s") · \(serviceResults.count) Service result\(serviceResults.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 780, height: item.mediaType == "tv" ? 650 : 560)
        .task {
            guard item.mediaType != "tv", !didPerformInitialSearch else { return }
            didPerformInitialSearch = true
            await load()
        }
        .task(id: selectedEpisode?.id) {
            guard item.mediaType == "tv", selectedEpisode != nil, !didPerformInitialSearch else { return }
            didPerformInitialSearch = true
            await load()
        }
        .onChange(of: selectedEpisode) { oldValue, newValue in
            guard oldValue?.id != newValue?.id else { return }
            activeStreamLoadID = UUID()
            isLoading = false
            resolvingServiceID = nil
            streams = []
            serviceResults = []
            serviceStreams = []
            pendingServiceResult = nil
            errorMessage = nil
        }
    }

    private func load() async {
        guard item.mediaType != "tv" || selectedEpisode != nil else {
            errorMessage = "Choose an episode from TMDB before searching for streams."
            return
        }
        let loadID = UUID()
        activeStreamLoadID = loadID
        let requestedEpisodeID = selectedEpisode?.id
        let requestedSeason = selectedSeasonNumber
        let requestedEpisode = selectedEpisodeNumber
        isLoading = true
        errorMessage = nil
        serviceStreams = []
        pendingServiceResult = nil
        var failures: [String] = []
        if services.addons.contains(where: \.isActive) {
            do {
                let loadedStreams = try await services.streams(
                    for: item,
                    season: requestedSeason,
                    episode: requestedEpisode
                )
                guard isCurrentStreamLoad(loadID, episodeID: requestedEpisodeID) else { return }
                streams = loadedStreams
            } catch {
                guard isCurrentStreamLoad(loadID, episodeID: requestedEpisodeID) else { return }
                streams = []
                failures.append("Stremio: \(error.localizedDescription)")
            }
        } else {
            streams = []
        }
        if legacyServices.activeServices.isEmpty {
            serviceResults = []
        } else {
            let loadedServiceResults = await legacyServices.search(item.title)
            guard isCurrentStreamLoad(loadID, episodeID: requestedEpisodeID) else { return }
            serviceResults = loadedServiceResults
            if let error = legacyServices.errorMessage { failures.append("Services: \(error)") }
        }
        guard isCurrentStreamLoad(loadID, episodeID: requestedEpisodeID) else { return }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        if await attemptAutoPlaybackIfEnabled(
            loadID: loadID,
            episodeID: requestedEpisodeID,
            seasonNumber: requestedSeason,
            episodeNumber: requestedEpisode
        ) {
            guard isCurrentStreamLoad(loadID, episodeID: requestedEpisodeID) else { return }
            isLoading = false
            return
        }
        if isCurrentStreamLoad(loadID, episodeID: requestedEpisodeID) { isLoading = false }
    }

    private func attemptAutoPlaybackIfEnabled(
        loadID: UUID,
        episodeID: Int?,
        seasonNumber: Int?,
        episodeNumber: Int?
    ) async -> Bool {
        guard isCurrentStreamLoad(loadID, episodeID: episodeID) else { return false }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "servicesAutoModeEnabled"),
              defaults.string(forKey: "servicesAutoModeQualityPreference")?.lowercased() != "manual" else { return false }

        let availableSourceIDs = services.addons.filter(\.isActive).map { "stremio:\($0.id.uuidString)" }
            + legacyServices.activeServices.map { "service:\($0.id.uuidString)" }
        guard !availableSourceIDs.isEmpty else { return false }

        let selected: Set<String>
        if defaults.object(forKey: "servicesAutoModeSourceIds") == nil {
            selected = Set(availableSourceIDs)
        } else {
            selected = Set(defaults.stringArray(forKey: "servicesAutoModeSourceIds") ?? [])
        }
        let selectedAvailable = availableSourceIDs.filter(selected.contains)
        guard !selectedAvailable.isEmpty else {
            errorMessage = [errorMessage, "Auto Mode has no enabled sources. Select at least one source in Settings."].compactMap { $0 }.joined(separator: "\n")
            return false
        }

        var seen = Set<String>()
        let savedOrder = (defaults.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? []).filter {
            selected.contains($0) && seen.insert($0).inserted
        }
        let orderedSourceIDs = savedOrder + selectedAvailable.filter { seen.insert($0).inserted }

        for sourceID in orderedSourceIDs {
            if let stream = streams.first(where: { $0.sourceID == sourceID }) {
                guard isCurrentStreamLoad(loadID, episodeID: episodeID) else { return false }
                beginPlayback(url: stream.url, headers: stream.headers)
                return true
            }

            let matchingResults = serviceResults.filter { "service:\($0.service.id.uuidString)" == sourceID }
            for result in matchingResults {
                let resolved = await legacyServices.resolve(
                    result,
                    media: item,
                    season: seasonNumber,
                    episode: episodeNumber
                )
                guard isCurrentStreamLoad(loadID, episodeID: episodeID) else { return false }
                if let stream = resolved.first {
                    serviceStreams = resolved
                    beginPlayback(url: stream.url, headers: stream.headers)
                    return true
                }
            }
        }

        errorMessage = [errorMessage, "Auto Mode could not find a playable HTTP stream. The filtered results remain available below."].compactMap { $0 }.joined(separator: "\n")
        return false
    }

    private func resolve(_ result: MacLegacySearchResult) async {
        let requestedLoadID = activeStreamLoadID
        let requestedEpisodeID = selectedEpisode?.id
        let requestedSeason = selectedSeasonNumber
        let requestedEpisode = selectedEpisodeNumber
        resolvingServiceID = result.id
        let resolved = await legacyServices.resolve(
            result,
            media: item,
            season: requestedSeason,
            episode: requestedEpisode
        )
        guard isCurrentStreamLoad(requestedLoadID, episodeID: requestedEpisodeID) else {
            resolvingServiceID = nil
            return
        }
        serviceStreams = resolved
        if let error = legacyServices.errorMessage { errorMessage = error }
        pendingServiceResult = legacyServices.pendingVerificationURL == nil ? nil : result
        resolvingServiceID = nil
    }

    private func isCurrentStreamLoad(_ loadID: UUID, episodeID: Int?) -> Bool {
        activeStreamLoadID == loadID && selectedEpisode?.id == episodeID && !Task.isCancelled
    }

    private func verifyAndRetry() async {
        let result = pendingServiceResult
        await legacyServices.verifyPendingChallenge()
        guard legacyServices.pendingVerificationURL == nil, let result else {
            if let error = legacyServices.errorMessage { errorMessage = error }
            return
        }
        pendingServiceResult = nil
        await resolve(result)
    }

    @ViewBuilder
    private func streamActions(url: URL, headers: [String: String]) -> some View {
        Button("Play") {
            beginPlayback(url: url, headers: headers)
        }
        .buttonStyle(.borderedProminent)
        Button("Download") { downloads.add(url: url, title: playbackTitle, headers: headers) }
    }

    private var playbackTitle: String {
        guard let selectedEpisode else { return item.title }
        return "\(item.title) · S\(selectedEpisode.seasonNumber) E\(selectedEpisode.episodeNumber) · \(selectedEpisode.displayName)"
    }

    private func beginPlayback(url: URL, headers: [String: String]) {
        playback.requestPlayback(
            url: url,
            title: playbackTitle,
            headers: headers,
            identity: MacPlaybackIdentity(
                item: item,
                season: selectedSeasonNumber,
                episode: selectedEpisodeNumber
            )
        )
        dismiss()
    }
}
