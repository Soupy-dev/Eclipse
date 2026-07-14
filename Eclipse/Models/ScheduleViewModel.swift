import Foundation

enum ScheduleMode: String, CaseIterable, Identifiable, Sendable {
    case anime
    case western
    case combined

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anime:
            return "Anime"
        case .western:
            return "Western"
        case .combined:
            return "Combined"
        }
    }

    var description: String {
        switch self {
        case .anime:
            return "Anime episodes from AniList."
        case .western:
            return "Western TV and streaming episodes from Trakt."
        case .combined:
            return "Anime and Western episodes together."
        }
    }

    static func sanitized(_ rawValue: String?) -> ScheduleMode {
        ScheduleMode(rawValue: rawValue ?? "") ?? .anime
    }

    static func sanitizedRawValue(_ rawValue: String?) -> String {
        sanitized(rawValue).rawValue
    }
}

enum ScheduleWindow: Int, CaseIterable, Identifiable, Sendable {
    case sevenDays = 7
    case fourteenDays = 14
    case twentyOneDays = 21
    case thirtyDays = 30

    static let storageKey = "scheduleWindowDays"
    static let defaultValue = ScheduleWindow.sevenDays

    var id: Int { rawValue }

    var displayName: String { "\(rawValue) Days" }

    var description: String {
        switch self {
        case .sevenDays:
            return "Default · Fastest loading"
        case .fourteenDays:
            return "Two weeks of upcoming episodes"
        case .twentyOneDays:
            return "Three weeks · More schedule data"
        case .thirtyDays:
            return "Longest range · Heaviest loading"
        }
    }

    static func sanitized(_ rawValue: Int?) -> ScheduleWindow {
        ScheduleWindow(rawValue: rawValue ?? 0) ?? defaultValue
    }

    static func sanitizedDays(_ rawValue: Int?) -> Int {
        sanitized(rawValue).rawValue
    }

    static var current: ScheduleWindow {
        sanitized(UserDefaults.standard.object(forKey: storageKey) as? Int)
    }
}

enum ScheduleSource: Hashable, Sendable {
    case anime
    case western

    var displayName: String {
        switch self {
        case .anime:
            return "Anime"
        case .western:
            return "Western"
        }
    }
}

struct NotificationScheduleSnapshot {
    let entries: [ScheduleEntry]
    let dayCount: Int
    let successfulSources: Set<ScheduleSource>
    let authoritativeSources: Set<ScheduleSource>
}

private struct ScheduleLoadResult {
    let entries: [ScheduleEntry]
    let successfulSources: Set<ScheduleSource>
    let authoritativeSources: Set<ScheduleSource>
}

private struct AnimeScheduleLoadResult {
    let entries: [ScheduleEntry]
    let isAuthoritativeForNotifications: Bool
}

private enum ScheduleSourceLoadError: LocalizedError {
    case retryDeferred(String)

    var errorDescription: String? {
        switch self {
        case .retryDeferred(let sourceName):
            return "\(sourceName) schedule refresh is waiting briefly after a provider failure."
        }
    }
}

struct ScheduleEntry: Identifiable, Sendable {
    let id: String
    let source: ScheduleSource
    let sourceMediaId: Int
    let title: String
    let airingAt: Date
    let episode: Int
    let season: Int?
    var coverImage: String?
    let englishTitle: String?
    let romajiTitle: String?
    let nativeTitle: String?
    let format: String?
    let hasKnownAiringTime: Bool
    let isStreamingRelease: Bool
    let tmdbId: Int?

    init(animeEntry: AniListAiringScheduleEntry) {
        id = "anime-\(animeEntry.id)"
        source = .anime
        sourceMediaId = animeEntry.mediaId
        title = animeEntry.title
        airingAt = animeEntry.airingAt
        episode = animeEntry.episode
        season = nil
        coverImage = animeEntry.coverImage
        englishTitle = animeEntry.englishTitle
        romajiTitle = animeEntry.romajiTitle
        nativeTitle = animeEntry.nativeTitle
        format = animeEntry.format
        hasKnownAiringTime = animeEntry.hasKnownAiringTime
        isStreamingRelease = false
        tmdbId = nil
    }

    fileprivate init(westernEpisode: TVMazeScheduleEpisode, airing: TVMazeAiringInfo) {
        id = "western-\(westernEpisode.id)"
        source = .western
        sourceMediaId = westernEpisode.show.id
        title = westernEpisode.show.name
        airingAt = airing.date
        episode = westernEpisode.number ?? 0
        season = westernEpisode.season
        coverImage = westernEpisode.show.image?.medium ?? westernEpisode.show.image?.original
        englishTitle = westernEpisode.show.name
        romajiTitle = nil
        nativeTitle = nil
        format = nil
        hasKnownAiringTime = airing.hasKnownAiringTime
        isStreamingRelease = westernEpisode.show.webChannel != nil
        tmdbId = nil
    }

    fileprivate init(traktItem: TraktCalendarItem, airingAt: Date, tmdbDetail: TMDBTVShowDetail?) {
        let showId = traktItem.show.ids.trakt ?? traktItem.show.ids.tmdb ?? 0
        let episodeId = traktItem.episode.ids?.trakt ?? 0
        let seasonNumber = traktItem.episode.season ?? 0
        let episodeNumber = traktItem.episode.number ?? 0
        id = "trakt-\(showId)-\(seasonNumber)-\(episodeNumber)-\(episodeId)-\(traktItem.firstAired)"
        source = .western
        sourceMediaId = showId
        title = traktItem.show.title
        self.airingAt = airingAt
        episode = episodeNumber
        season = seasonNumber
        coverImage = tmdbDetail?.fullPosterURL
        englishTitle = traktItem.show.title
        romajiTitle = nil
        nativeTitle = nil
        format = nil
        hasKnownAiringTime = true
        isStreamingRelease = false
        tmdbId = traktItem.show.ids.tmdb
    }
}

final class ScheduleViewModel: ObservableObject {
    static let shared = ScheduleViewModel()

    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var scheduleEntries: [ScheduleEntry] = []
    @Published var dayBuckets: [DayBucket] = []
    @Published var currentDayAnchor = Date()
    private(set) var loadedScheduleMode: ScheduleMode?
    private(set) var loadedScheduleDayCount: Int?

    private let scheduleCacheMaxAge: TimeInterval = 6 * 60 * 60
    private let animeAuthoritativeRetryInterval: TimeInterval = 15 * 60
    private let failedSourceRetryInterval: TimeInterval = 60
    private var animeScheduleResult: AnimeScheduleLoadResult?
    private var animeScheduleFetchedAt: Date?
    private var animeScheduleDayCount = 0
    private var animeScheduleLastAttemptAt: Date?
    private var animeScheduleLastFailureAt: Date?
    private var animeScheduleLoadTask: Task<AnimeScheduleLoadResult, Error>?
    private var animeScheduleLoadID: UUID?
    private var westernScheduleEntries: [ScheduleEntry]?
    private var westernScheduleFetchedAt: Date?
    private var westernScheduleDayCount = 0
    private var westernScheduleLastAttemptAt: Date?
    private var westernScheduleLastFailureAt: Date?
    private var westernScheduleLoadTask: Task<[ScheduleEntry], Error>?
    private var westernScheduleLoadID: UUID?
    private var activeLoadID: UUID?
    private var activeLoadMode: ScheduleMode?
    private var activeLoadDayCount: Int?
    private var activePosterHydrationID: UUID?
    private var posterHydrationTask: Task<Void, Never>?
    private var posterHydrationAttemptedTMDBIDs = Set<Int>()
    private var currentLocalTimeZone = true

    init() {}

    func loadSchedule(
        mode: ScheduleMode,
        localTimeZone: Bool,
        forceRefresh: Bool = false
    ) async {
        let requestedDayCount = ScheduleWindow.current.rawValue
        let loadID = UUID()
        let shouldStart = await MainActor.run { () -> Bool in
            if !forceRefresh,
               activeLoadID != nil,
               activeLoadMode == mode,
               activeLoadDayCount == requestedDayCount {
                return false
            }
            posterHydrationTask?.cancel()
            posterHydrationTask = nil
            activePosterHydrationID = nil
            activeLoadID = loadID
            activeLoadMode = mode
            activeLoadDayCount = requestedDayCount
            currentLocalTimeZone = localTimeZone
            if forceRefresh {
                posterHydrationAttemptedTMDBIDs.removeAll(keepingCapacity: true)
            }
            isLoading = true
            errorMessage = nil
            return true
        }
        guard shouldStart else { return }

        do {
            let loadResult = try await entries(
                for: mode,
                dayCount: requestedDayCount,
                forceRefresh: forceRefresh
            )
            let entries = loadResult.entries
            let didPublish = await MainActor.run { () -> Bool in
                guard activeLoadID == loadID else { return false }
                activeLoadID = nil
                activeLoadMode = nil
                activeLoadDayCount = nil
                isLoading = false
                scheduleEntries = entries
                loadedScheduleMode = mode
                loadedScheduleDayCount = requestedDayCount
                currentDayAnchor = Date()
                updateBuckets(
                    with: entries,
                    localTimeZone: localTimeZone,
                    dayCount: requestedDayCount
                )
                startPosterHydrationIfNeeded(for: entries, loadID: loadID)
                return true
            }
            guard didPublish else { return }
#if os(iOS)
            await LocalNotificationManager.shared.reconcileScheduleEntries(
                entries,
                successfulSources: loadResult.successfulSources,
                authoritativeSources: loadResult.authoritativeSources,
                coveredDayCount: requestedDayCount
            )
#endif
        } catch {
            if Self.isIntentionalCancellation(error) {
                await MainActor.run {
                    guard activeLoadID == loadID else { return }
                    activeLoadID = nil
                    activeLoadMode = nil
                    activeLoadDayCount = nil
                    isLoading = false
                }
                return
            }
            await MainActor.run {
                guard activeLoadID == loadID else { return }
                activeLoadID = nil
                activeLoadMode = nil
                activeLoadDayCount = nil
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Fetches both schedule sources without replacing the schedule mode or rows
    /// currently visible to the user. Notification subscriptions must refresh
    /// independently from whichever Schedule tab the user last selected.
    @MainActor
    func notificationScheduleSnapshot(
        dayCount: Int,
        requiredSources: Set<ScheduleSource> = [.anime, .western],
        forceRefreshSources: Set<ScheduleSource> = [],
        requireAuthoritativeSources: Set<ScheduleSource> = []
    ) async -> NotificationScheduleSnapshot {
        // The user's selected Schedule range is also the automatic episode
        // notification window. Callers pass it explicitly so a future path
        // cannot silently fall back to seven days.
        let requestedDayCount = ScheduleWindow.sanitizedDays(dayCount)
        let needsAuthoritativeAnime = requireAuthoritativeSources.contains(.anime)
            && animeScheduleResult?.isAuthoritativeForNotifications != true
        let now = Date()
        let authoritativeRetryIsDue: Bool
        if animeScheduleResult == nil {
            authoritativeRetryIsDue = animeScheduleLastFailureAt.map {
                let elapsed = now.timeIntervalSince($0)
                return elapsed < 0 || elapsed >= failedSourceRetryInterval
            } ?? true
        } else {
            authoritativeRetryIsDue = animeScheduleLastAttemptAt.map {
                let elapsed = now.timeIntervalSince($0)
                return elapsed < 0 || elapsed >= animeAuthoritativeRetryInterval
            } ?? true
        }
        let forceAnime = forceRefreshSources.contains(.anime)
            || (needsAuthoritativeAnime && authoritativeRetryIsDue)

        async let animeLoad: Void = loadAnimeSnapshotSource(
            required: requiredSources.contains(.anime),
            dayCount: requestedDayCount,
            forceRefresh: forceAnime
        )
        async let westernLoad: Void = loadWesternSnapshotSource(
            required: requiredSources.contains(.western),
            dayCount: requestedDayCount,
            forceRefresh: forceRefreshSources.contains(.western)
        )
        _ = await (animeLoad, westernLoad)

        var entries: [ScheduleEntry] = []
        var successfulSources = Set<ScheduleSource>()
        var authoritativeSources = Set<ScheduleSource>()

        if scheduleCacheIsFresh(
            animeScheduleFetchedAt,
            cachedDayCount: animeScheduleDayCount,
            requiredDayCount: requestedDayCount
        ), let animeResult = cachedAnimeResult(for: requestedDayCount) {
            entries.append(contentsOf: animeResult.entries)
            successfulSources.insert(.anime)
            if animeResult.isAuthoritativeForNotifications {
                authoritativeSources.insert(.anime)
            }
        }
        if scheduleCacheIsFresh(
            westernScheduleFetchedAt,
            cachedDayCount: westernScheduleDayCount,
            requiredDayCount: requestedDayCount
        ), let westernEntries = cachedWesternEntries(for: requestedDayCount) {
            entries.append(contentsOf: westernEntries)
            successfulSources.insert(.western)
            authoritativeSources.insert(.western)
        }

        return NotificationScheduleSnapshot(
            entries: entries.sorted { $0.airingAt < $1.airingAt },
            dayCount: requestedDayCount,
            successfulSources: successfulSources,
            authoritativeSources: authoritativeSources
        )
    }

    @MainActor
    private func loadAnimeSnapshotSource(required: Bool, dayCount: Int, forceRefresh: Bool) async {
        guard required else { return }
        _ = try? await animeEntries(dayCount: dayCount, forceRefresh: forceRefresh)
    }

    @MainActor
    private func loadWesternSnapshotSource(required: Bool, dayCount: Int, forceRefresh: Bool) async {
        guard required else { return }
        _ = try? await westernEntries(dayCount: dayCount, forceRefresh: forceRefresh)
    }

    @MainActor
    private func entries(
        for mode: ScheduleMode,
        dayCount: Int,
        forceRefresh: Bool
    ) async throws -> ScheduleLoadResult {
        switch mode {
        case .anime:
            let result = try await animeEntries(dayCount: dayCount, forceRefresh: forceRefresh)
            return ScheduleLoadResult(
                entries: result.entries,
                successfulSources: [.anime],
                authoritativeSources: result.isAuthoritativeForNotifications ? [.anime] : []
            )
        case .western:
            return ScheduleLoadResult(
                entries: try await westernEntries(dayCount: dayCount, forceRefresh: forceRefresh),
                successfulSources: [.western],
                authoritativeSources: [.western]
            )
        case .combined:
            async let animeResult = scheduleSourceResult {
                try await self.animeEntries(dayCount: dayCount, forceRefresh: forceRefresh)
            }
            async let westernResult = scheduleSourceResult {
                try await self.westernEntries(dayCount: dayCount, forceRefresh: forceRefresh)
            }

            let sourceResults = await (animeResult, westernResult)
            var combinedEntries: [ScheduleEntry] = []
            var firstError: Error?
            var successfulSources = Set<ScheduleSource>()
            var authoritativeSources = Set<ScheduleSource>()
            var loadedAnySource = false

            switch sourceResults.0 {
            case .success(let result):
                combinedEntries += result.entries
                loadedAnySource = true
                successfulSources.insert(.anime)
                if result.isAuthoritativeForNotifications {
                    authoritativeSources.insert(.anime)
                }
            case .failure(let error):
                if Self.isIntentionalCancellation(error) {
                    throw CancellationError()
                }
                firstError = error
            }

            switch sourceResults.1 {
            case .success(let entries):
                combinedEntries += entries
                loadedAnySource = true
                successfulSources.insert(.western)
                authoritativeSources.insert(.western)
            case .failure(let error):
                if Self.isIntentionalCancellation(error) {
                    throw CancellationError()
                }
                firstError = firstError ?? error
            }

            if !loadedAnySource, let firstError {
                throw firstError
            }
            return ScheduleLoadResult(
                entries: combinedEntries,
                successfulSources: successfulSources,
                authoritativeSources: authoritativeSources
            )
        }
    }

    @MainActor
    private func scheduleSourceResult<Value>(
        operation: () async throws -> Value
    ) async -> Result<Value, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    @MainActor
    private func animeEntries(dayCount: Int, forceRefresh: Bool) async throws -> AnimeScheduleLoadResult {
        if !forceRefresh,
           scheduleCacheIsFresh(
                animeScheduleFetchedAt,
                cachedDayCount: animeScheduleDayCount,
                requiredDayCount: dayCount
           ),
           let cached = cachedAnimeResult(for: dayCount) {
            return cached
        }
        if let animeScheduleLoadTask {
            _ = try await animeScheduleLoadTask.value
            if let cached = cachedAnimeResult(for: dayCount),
               scheduleCacheIsFresh(
                    animeScheduleFetchedAt,
                    cachedDayCount: animeScheduleDayCount,
                    requiredDayCount: dayCount
               ) {
                return cached
            }
            // The in-flight request may have covered a shorter range or
            // crossed midnight. Extend/refetch rather than publishing it.
            return try await animeEntries(dayCount: dayCount, forceRefresh: forceRefresh)
        }

        if !forceRefresh, retryIsCoolingDown(since: animeScheduleLastFailureAt) {
            throw ScheduleSourceLoadError.retryDeferred(ScheduleSource.anime.displayName)
        }

        let loadID = UUID()
        let fetchStartedAt = Date()
        animeScheduleLastAttemptAt = fetchStartedAt
        let loadTask = Task { @MainActor [weak self] () throws -> AnimeScheduleLoadResult in
            guard let self else { throw CancellationError() }
            do {
                let result = try await self.retryOnceAfterTransientCancellation(operationName: "AniList schedule") {
                    try await AniListService.shared.fetchAiringScheduleResult(daysAhead: dayCount)
                }
                let entries = result.entries.map(ScheduleEntry.init(animeEntry:))
                try Task.checkCancellation()
                let loadResult = AnimeScheduleLoadResult(
                    entries: entries,
                    isAuthoritativeForNotifications: result.isAuthoritativeForNotifications
                )
                if self.animeScheduleLoadID == loadID {
                    self.animeScheduleResult = loadResult
                    self.animeScheduleDayCount = dayCount
                    // A request that straddles midnight must not make the
                    // previous day's window look fresh for the new day.
                    self.animeScheduleFetchedAt = fetchStartedAt
                    self.animeScheduleLastFailureAt = nil
                    self.animeScheduleLoadTask = nil
                    self.animeScheduleLoadID = nil
                }
                return loadResult
            } catch {
                if self.animeScheduleLoadID == loadID {
                    self.animeScheduleLastFailureAt = Date()
                    self.animeScheduleLoadTask = nil
                    self.animeScheduleLoadID = nil
                }
                throw error
            }
        }
        animeScheduleLoadID = loadID
        animeScheduleLoadTask = loadTask
        _ = try await loadTask.value
        if let cached = cachedAnimeResult(for: dayCount),
           scheduleCacheIsFresh(
                animeScheduleFetchedAt,
                cachedDayCount: animeScheduleDayCount,
                requiredDayCount: dayCount
           ) {
            return cached
        }
        return try await animeEntries(dayCount: dayCount, forceRefresh: forceRefresh)
    }

    @MainActor
    private func westernEntries(dayCount: Int, forceRefresh: Bool) async throws -> [ScheduleEntry] {
        if !forceRefresh,
           scheduleCacheIsFresh(
                westernScheduleFetchedAt,
                cachedDayCount: westernScheduleDayCount,
                requiredDayCount: dayCount
           ),
           let cached = cachedWesternEntries(for: dayCount) {
            return cached
        }
        if let westernScheduleLoadTask {
            _ = try await westernScheduleLoadTask.value
            if let cached = cachedWesternEntries(for: dayCount),
               scheduleCacheIsFresh(
                    westernScheduleFetchedAt,
                    cachedDayCount: westernScheduleDayCount,
                    requiredDayCount: dayCount
               ) {
                return cached
            }
            return try await westernEntries(dayCount: dayCount, forceRefresh: forceRefresh)
        }

        if !forceRefresh, retryIsCoolingDown(since: westernScheduleLastFailureAt) {
            throw ScheduleSourceLoadError.retryDeferred(ScheduleSource.western.displayName)
        }

        let loadID = UUID()
        let fetchStartedAt = Date()
        westernScheduleLastAttemptAt = fetchStartedAt
        let loadTask = Task { @MainActor [weak self] () throws -> [ScheduleEntry] in
            guard let self else { throw CancellationError() }
            do {
                let entries: [ScheduleEntry]
                do {
                    entries = try await self.retryOnceAfterTransientCancellation(operationName: "Trakt schedule") {
                        try await TraktScheduleService.shared.fetchSchedule(dayCount: dayCount)
                    }
                } catch {
                    if Self.isIntentionalCancellation(error) {
                        throw CancellationError()
                    }
                    Logger.shared.log("TraktScheduleService: falling back to TVMaze: \(error.localizedDescription)", type: "TMDB")
                    entries = try await TVMazeService.shared.fetchSchedule(dayCount: dayCount)
                }
                try Task.checkCancellation()
                if self.westernScheduleLoadID == loadID {
                    self.westernScheduleEntries = entries
                    self.westernScheduleDayCount = dayCount
                    self.westernScheduleFetchedAt = fetchStartedAt
                    self.westernScheduleLastFailureAt = nil
                    self.westernScheduleLoadTask = nil
                    self.westernScheduleLoadID = nil
                }
                return entries
            } catch {
                if self.westernScheduleLoadID == loadID {
                    self.westernScheduleLastFailureAt = Date()
                    self.westernScheduleLoadTask = nil
                    self.westernScheduleLoadID = nil
                }
                throw error
            }
        }
        westernScheduleLoadID = loadID
        westernScheduleLoadTask = loadTask
        _ = try await loadTask.value
        if let cached = cachedWesternEntries(for: dayCount),
           scheduleCacheIsFresh(
                westernScheduleFetchedAt,
                cachedDayCount: westernScheduleDayCount,
                requiredDayCount: dayCount
           ) {
            return cached
        }
        return try await westernEntries(dayCount: dayCount, forceRefresh: forceRefresh)
    }

    private func scheduleCacheIsFresh(
        _ fetchedAt: Date?,
        cachedDayCount: Int,
        requiredDayCount: Int
    ) -> Bool {
        guard let fetchedAt,
              cachedDayCount >= requiredDayCount,
              Calendar.current.isDate(fetchedAt, inSameDayAs: Date()) else {
            return false
        }
        let age = Date().timeIntervalSince(fetchedAt)
        return age >= 0 && age < scheduleCacheMaxAge
    }

    private func cachedAnimeResult(for dayCount: Int) -> AnimeScheduleLoadResult? {
        guard let animeScheduleResult else { return nil }
        return AnimeScheduleLoadResult(
            entries: entries(animeScheduleResult.entries, within: dayCount),
            isAuthoritativeForNotifications: animeScheduleResult.isAuthoritativeForNotifications
        )
    }

    private func cachedWesternEntries(for dayCount: Int) -> [ScheduleEntry]? {
        guard let westernScheduleEntries else { return nil }
        return entries(westernScheduleEntries, within: dayCount)
    }

    private func entries(_ entries: [ScheduleEntry], within dayCount: Int) -> [ScheduleEntry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: max(dayCount, 1), to: start) ?? .distantFuture
        return entries.filter { $0.airingAt >= start && $0.airingAt < end }
    }

    private func retryIsCoolingDown(since failureDate: Date?) -> Bool {
        guard let failureDate else { return false }
        let elapsed = Date().timeIntervalSince(failureDate)
        return elapsed >= 0 && elapsed < failedSourceRetryInterval
    }

    private func retryOnceAfterTransientCancellation<T>(
        operationName: String,
        operation: () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        do {
            let result = try await operation()
            try Task.checkCancellation()
            return result
        } catch {
            if Self.isIntentionalCancellation(error) {
                throw CancellationError()
            }
            guard Self.isTransportCancellation(error) else {
                throw error
            }

            Logger.shared.log(
                "ScheduleViewModel: transient \(operationName) cancellation; retrying once after 1 second",
                type: "TMDB"
            )
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            return result
        }
    }

    private static func isIntentionalCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError
    }

    private static func isTransportCancellation(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    func updateBuckets(with entries: [ScheduleEntry], localTimeZone: Bool, dayCount: Int) {
        let calendar = makeCalendar(localTimeZone: localTimeZone)
        let startOfToday = calendar.startOfDay(for: Date())

        var buckets: [DayBucket] = []
        for offset in 0..<dayCount {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else {
                continue
            }

            let dayItems = entries
                .filter { entry in
                    entry.airingAt >= calendar.startOfDay(for: day) && entry.airingAt < nextDay
                }
                .sorted { $0.airingAt < $1.airingAt }

            buckets.append(DayBucket(date: calendar.startOfDay(for: day), items: dayItems))
        }

        dayBuckets = buckets
    }

    func regroupBuckets(localTimeZone: Bool) {
        currentLocalTimeZone = localTimeZone
        updateBuckets(
            with: scheduleEntries,
            localTimeZone: localTimeZone,
            dayCount: loadedScheduleDayCount ?? ScheduleWindow.current.rawValue
        )
    }

    func handleDayChangeIfNeeded(mode: ScheduleMode, localTimeZone: Bool) async {
        let calendar = makeCalendar(localTimeZone: localTimeZone)
        let trackedDay = calendar.startOfDay(for: currentDayAnchor)
        let today = calendar.startOfDay(for: Date())

        if today != trackedDay {
            await loadSchedule(mode: mode, localTimeZone: localTimeZone, forceRefresh: true)
        } else {
            await MainActor.run {
                currentLocalTimeZone = localTimeZone
                currentDayAnchor = Date()
                updateBuckets(
                    with: scheduleEntries,
                    localTimeZone: localTimeZone,
                    dayCount: loadedScheduleDayCount ?? ScheduleWindow.current.rawValue
                )
            }
        }
    }

    @MainActor
    private func startPosterHydrationIfNeeded(for entries: [ScheduleEntry], loadID: UUID) {
        let westernEntries = entries.filter {
            guard $0.source == .western,
                  let tmdbId = $0.tmdbId,
                  $0.coverImage == nil else {
                return false
            }
            return !posterHydrationAttemptedTMDBIDs.contains(tmdbId)
        }
        guard !westernEntries.isEmpty else { return }

        activePosterHydrationID = loadID
        posterHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let details = await TraktScheduleService.shared.fetchTMDBDetails(for: westernEntries)
            guard !Task.isCancelled, self.activePosterHydrationID == loadID else { return }
            posterHydrationAttemptedTMDBIDs.formUnion(westernEntries.compactMap(\.tmdbId))

            if !details.isEmpty {
                var hydratedEntries = self.scheduleEntries
                for index in hydratedEntries.indices {
                    guard let tmdbId = hydratedEntries[index].tmdbId,
                          let detail = details[tmdbId] else {
                        continue
                    }
                    hydratedEntries[index].coverImage = detail.fullPosterURL
                }

                scheduleEntries = hydratedEntries
                if var cachedWesternEntries = westernScheduleEntries {
                    for index in cachedWesternEntries.indices {
                        guard let tmdbId = cachedWesternEntries[index].tmdbId,
                              let detail = details[tmdbId] else {
                            continue
                        }
                        cachedWesternEntries[index].coverImage = detail.fullPosterURL
                    }
                    westernScheduleEntries = cachedWesternEntries
                }
                updateBuckets(
                    with: hydratedEntries,
                    localTimeZone: currentLocalTimeZone,
                    dayCount: loadedScheduleDayCount ?? ScheduleWindow.current.rawValue
                )
            }
            activePosterHydrationID = nil
            posterHydrationTask = nil
        }
    }

    private func makeCalendar(localTimeZone: Bool) -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = localTimeZone ? .current : TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    // MARK: - TMDB Lookup

    /// Cache keyed by schedule source and media ID so both feeds can reuse TMDB results.
    /// Stores Optional<TMDBSearchResult> so we also cache "not found" results.
    private var tmdbCache: [String: TMDBSearchResult?] = [:]

    func lookupTMDBResult(for entry: ScheduleEntry) async -> TMDBSearchResult? {
        let cacheKey = "\(entry.source.displayName)-\(entry.sourceMediaId)"
        if let cached = tmdbCache[cacheKey] {
            return cached
        }

        let result = await performTMDBLookup(for: entry)
        tmdbCache[cacheKey] = .some(result)
        return result
    }

    private func performTMDBLookup(for entry: ScheduleEntry) async -> TMDBSearchResult? {
        if let tmdbId = entry.tmdbId,
           let detail = try? await TMDBService.shared.getTVShowDetails(id: tmdbId) {
            return tmdbSearchResult(from: detail)
        }

        func normalized(_ value: String) -> String {
            value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }

        var seen = Set<String>()
        let titleCandidates = [entry.englishTitle, entry.romajiTitle, entry.nativeTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let candidates = titleCandidates.isEmpty ? [entry.title] : titleCandidates
        let tmdbService = TMDBService.shared
        let preferAnimation = entry.source == .anime
        let isMovie = preferAnimation && entry.format?.uppercased() == "MOVIE"

        for candidate in candidates {
            if isMovie {
                if let result = try? await tmdbService.searchMovies(query: candidate),
                   let best = bestMovieMatch(results: result, candidateKey: normalized(candidate)) {
                    return best.asSearchResult
                }
            } else {
                if let result = try? await tmdbService.searchTVShows(query: candidate),
                   let best = bestTVMatch(results: result, candidateKey: normalized(candidate), preferAnimation: preferAnimation) {
                    return best.asSearchResult
                }
            }
        }

        for candidate in candidates {
            if let results = try? await tmdbService.searchMulti(query: candidate, maxPages: 1),
               let best = bestMultiMatch(results: results, candidateKey: normalized(candidate), preferAnimation: preferAnimation) {
                return best
            }
        }

        guard entry.source == .anime else {
            return nil
        }

        // Relation fallback: walk up AniList parent/prequel chain and try TMDB on each ancestor.
        let parentCandidates = await AniListService.shared.fetchParentTitleCandidates(forMediaId: entry.sourceMediaId)
        for parent in parentCandidates {
            var parentSeen = Set<String>()
            let parentTitles = [parent.englishTitle, parent.romajiTitle, parent.nativeTitle]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && parentSeen.insert($0).inserted }

            for candidate in parentTitles {
                if let results = try? await tmdbService.searchTVShows(query: candidate),
                   let best = bestTVMatch(results: results, candidateKey: normalized(candidate), preferAnimation: true) {
                    return best.asSearchResult
                }
                if let results = try? await tmdbService.searchMulti(query: candidate, maxPages: 1),
                   let best = bestMultiMatch(results: results, candidateKey: normalized(candidate), preferAnimation: true) {
                    return best
                }
            }
        }

        return nil
    }

    private func tmdbSearchResult(from detail: TMDBTVShowDetail) -> TMDBSearchResult {
        TMDBSearchResult(
            id: detail.id,
            mediaType: "tv",
            title: nil,
            name: detail.name,
            overview: detail.overview,
            posterPath: detail.posterPath,
            backdropPath: detail.backdropPath,
            releaseDate: nil,
            firstAirDate: detail.firstAirDate,
            voteAverage: detail.voteAverage,
            popularity: detail.popularity,
            adult: detail.adult,
            genreIds: detail.genres.map(\.id)
        )
    }

    private func bestTVMatch(results: [TMDBTVShow], candidateKey: String, preferAnimation: Bool) -> TMDBTVShow? {
        func normalized(_ value: String) -> String {
            value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }
        guard !results.isEmpty else { return nil }

        let exactMatches = results.filter { normalized($0.name) == candidateKey }
        if !exactMatches.isEmpty {
            return bestTVResult(from: exactMatches, preferAnimation: preferAnimation)
        }

        let partialMatches = results.filter {
            let nameKey = normalized($0.name)
            return nameKey.contains(candidateKey) || candidateKey.contains(nameKey)
        }
        if !partialMatches.isEmpty {
            return bestTVResult(from: partialMatches, preferAnimation: preferAnimation)
        }

        return bestTVResult(from: results, preferAnimation: preferAnimation)
    }

    private func bestTVResult(from results: [TMDBTVShow], preferAnimation: Bool) -> TMDBTVShow? {
        results.min { a, b in
            let aAnim = a.genreIds?.contains(16) == true
            let bAnim = b.genreIds?.contains(16) == true
            if preferAnimation, aAnim != bAnim { return aAnim }
            return a.popularity > b.popularity
        }
    }

    private func bestMovieMatch(results: [TMDBMovie], candidateKey: String) -> TMDBMovie? {
        func normalized(_ value: String) -> String {
            value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }
        guard !results.isEmpty else { return nil }

        let exactMatches = results.filter { normalized($0.title) == candidateKey }
        if !exactMatches.isEmpty {
            return bestMovieResult(from: exactMatches)
        }

        let partialMatches = results.filter {
            let nameKey = normalized($0.title)
            return nameKey.contains(candidateKey) || candidateKey.contains(nameKey)
        }
        if !partialMatches.isEmpty {
            return bestMovieResult(from: partialMatches)
        }

        return bestMovieResult(from: results)
    }

    private func bestMovieResult(from results: [TMDBMovie]) -> TMDBMovie? {
        results.min { a, b in
            let aAnim = a.genreIds?.contains(16) == true
            let bAnim = b.genreIds?.contains(16) == true
            if aAnim != bAnim { return aAnim }
            return a.popularity > b.popularity
        }
    }

    private func bestMultiMatch(results: [TMDBSearchResult], candidateKey: String, preferAnimation: Bool) -> TMDBSearchResult? {
        guard !results.isEmpty else { return nil }
        let filtered = results.filter { result in
            let nameKey = result.displayTitle.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
            return nameKey == candidateKey || nameKey.contains(candidateKey) || candidateKey.contains(nameKey)
        }
        let pool = filtered.isEmpty ? results : filtered
        return pool.min { a, b in
            let aAnim = a.genreIds?.contains(16) == true
            let bAnim = b.genreIds?.contains(16) == true
            if preferAnimation, aAnim != bAnim { return aAnim }
            return a.popularity > b.popularity
        }
    }
}

struct DayBucket: Identifiable {
    let id = UUID()
    let date: Date
    let items: [ScheduleEntry]
}

/// Detects truly high-frequency shows without treating four weekly episodes in
/// a 30-day request as a daily show. Four distinct air dates must occur inside
/// the same rolling seven-day window.
private func hasDailyScheduleDensity(_ dates: [Date]) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    let days = Set(dates.map { calendar.startOfDay(for: $0) }).sorted()
    guard days.count >= 4 else { return false }

    var lowerBound = 0
    for upperBound in days.indices {
        while lowerBound < upperBound,
              let windowEnd = calendar.date(
                  byAdding: .day,
                  value: 7,
                  to: days[lowerBound]
              ),
              days[upperBound] >= windowEnd {
            lowerBound += 1
        }
        if upperBound - lowerBound + 1 >= 4 {
            return true
        }
    }
    return false
}

// MARK: - Trakt Western Schedule

private final class TraktScheduleService {
    static let shared = TraktScheduleService()

    private let baseURL = URL(string: "https://api.trakt.tv")!

    private var clientId: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "TraktClientID") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("$(") ? "" : trimmed
    }

    private init() {}

    func fetchSchedule(dayCount: Int) async throws -> [ScheduleEntry] {
        guard !clientId.isEmpty else {
            throw TraktScheduleError.missingClientId
        }

        let startDate = formattedStartDate()
        let items = try await fetchCalendarItems(startDate: startDate, dayCount: dayCount)
        let candidates = scheduleCandidates(from: items)
        let filtered = removeDailyShows(from: candidates)
            .sorted { $0.airingAt < $1.airingAt }

        return filtered.map { candidate in
            ScheduleEntry(
                traktItem: candidate.item,
                airingAt: candidate.airingAt,
                tmdbDetail: nil
            )
        }
    }

    private func formattedStartDate() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Calendar.current.startOfDay(for: Date()))
    }

    private func fetchCalendarItems(startDate: String, dayCount: Int) async throws -> [TraktCalendarItem] {
        var components = URLComponents(string: "\(baseURL.absoluteString)/calendars/all/shows/\(startDate)/\(dayCount)")
        components?.queryItems = [
            URLQueryItem(name: "extended", value: "full"),
            URLQueryItem(name: "languages", value: "en")
        ]
        guard let url = components?.url else {
            throw TraktScheduleError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TraktScheduleError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw TraktScheduleError.httpStatus(httpResponse.statusCode)
        }

        return try JSONDecoder().decode([TraktCalendarItem].self, from: data)
    }

    private func scheduleCandidates(from items: [TraktCalendarItem]) -> [TraktScheduleCandidate] {
        var seenEpisodeIds = Set<String>()
        return items.compactMap { item in
            guard item.isWesternScheduleCandidate,
                  let airingAt = Self.parseDate(item.firstAired) else {
                return nil
            }

            let episodeKey = item.episode.ids?.trakt.map { "trakt-\($0)" }
                ?? item.episode.ids?.tmdb.map { "tmdb-\($0)" }
                ?? "\(item.showKey)-\(item.episode.season ?? 0)-\(item.episode.number ?? 0)-\(item.firstAired)"
            guard seenEpisodeIds.insert(episodeKey).inserted else {
                return nil
            }

            return TraktScheduleCandidate(
                item: item,
                airingAt: airingAt,
                showKey: item.showKey
            )
        }
    }

    private func removeDailyShows(from candidates: [TraktScheduleCandidate]) -> [TraktScheduleCandidate] {
        let dailyShowIds = Set(
            Dictionary(grouping: candidates, by: \.showKey)
                .compactMap { entry in
                    hasDailyScheduleDensity(entry.value.map(\.airingAt)) ? entry.key : nil
                }
        )
        return candidates.filter { !dailyShowIds.contains($0.showKey) }
    }

    func fetchTMDBDetails(for entries: [ScheduleEntry]) async -> [Int: TMDBTVShowDetail] {
        var seen = Set<Int>()
        let ids = entries
            .compactMap(\.tmdbId)
            .filter { seen.insert($0).inserted }

        return await withTaskGroup(of: (Int, TMDBTVShowDetail?).self) { group in
            for id in ids.prefix(80) {
                group.addTask {
                    (id, try? await TMDBService.shared.getTVShowDetails(id: id))
                }
            }

            var details: [Int: TMDBTVShowDetail] = [:]
            for await (id, detail) in group {
                if let detail {
                    details[id] = detail
                }
            }
            return details
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

private struct TraktScheduleCandidate {
    let item: TraktCalendarItem
    let airingAt: Date
    let showKey: String
}

fileprivate struct TraktCalendarItem: Decodable {
    let firstAired: String
    let episode: TraktCalendarEpisode
    let show: TraktCalendarShow

    enum CodingKeys: String, CodingKey {
        case firstAired = "first_aired"
        case episode, show
    }

    var showKey: String {
        show.ids.trakt.map { "trakt-\($0)" }
            ?? show.ids.tmdb.map { "tmdb-\($0)" }
            ?? show.title.lowercased()
    }

    var isWesternScheduleCandidate: Bool {
        guard show.language?.lowercased() == "en" else {
            return false
        }

        let excludedGenres: Set<String> = [
            "anime",
            "documentary",
            "food",
            "game-show",
            "home-and-garden",
            "news",
            "reality",
            "soap",
            "special-interest",
            "sport",
            "talk-show"
        ]
        let genres = Set((show.genres ?? []).map { $0.lowercased() })
        return genres.isDisjoint(with: excludedGenres)
    }
}

fileprivate struct TraktCalendarEpisode: Decodable {
    let season: Int?
    let number: Int?
    let title: String?
    let ids: TraktCalendarIDs?
}

fileprivate struct TraktCalendarShow: Decodable {
    let title: String
    let year: Int?
    let ids: TraktCalendarIDs
    let language: String?
    let country: String?
    let network: String?
    let genres: [String]?
}

fileprivate struct TraktCalendarIDs: Decodable {
    let trakt: Int?
    let slug: String?
    let tvdb: Int?
    let imdb: String?
    let tmdb: Int?
}

private enum TraktScheduleError: LocalizedError {
    case missingClientId
    case invalidURL
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingClientId:
            return "TRAKT_CLIENT_ID is not configured."
        case .invalidURL:
            return "The Trakt schedule URL could not be created."
        case .invalidResponse:
            return "The Trakt schedule service returned an invalid response."
        case .httpStatus(let status):
            return "The Trakt schedule service returned HTTP \(status)."
        }
    }
}

// MARK: - TVMaze Western Schedule

private actor TVMazeService {
    static let shared = TVMazeService()

    private let baseURL = URL(string: "https://api.tvmaze.com")!
    private let extendedCacheMaxAge: TimeInterval = 6 * 60 * 60
    private var extendedScheduleCache: (fetchedAt: Date, entries: [ScheduleEntry])?

    private init() {}

    func fetchSchedule(dayCount: Int) async throws -> [ScheduleEntry] {
        if dayCount > ScheduleWindow.sevenDays.rawValue {
            return try await fetchExtendedSchedule(dayCount: dayCount)
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let regionCode = Locale.current.regionCode?.uppercased() ?? "US"
        var episodesById: [Int: TVMazeScheduleEpisode] = [:]

        for offset in 0..<dayCount {
            guard let date = calendar.date(byAdding: .day, value: offset, to: startOfToday) else {
                continue
            }
            let dateString = formatter.string(from: date)
            let feeds = [
                (
                    path: "schedule",
                    requiresEnglishLanguage: false,
                    isOptional: false,
                    queryItems: [
                        URLQueryItem(name: "country", value: regionCode),
                        URLQueryItem(name: "date", value: dateString)
                    ]
                ),
                (
                    path: "schedule/web",
                    requiresEnglishLanguage: true,
                    isOptional: true,
                    queryItems: [
                        URLQueryItem(name: "country", value: ""),
                        URLQueryItem(name: "date", value: dateString)
                    ]
                )
            ]

            for feed in feeds {
                let episodes: [TVMazeScheduleEpisode]
                do {
                    episodes = try await fetchEpisodes(path: feed.path, queryItems: feed.queryItems)
                } catch {
                    guard feed.isOptional else {
                        throw error
                    }
                    Logger.shared.log(
                        "TVMazeService: optional feed failed path=\(feed.path) date=\(dateString) error=\(error.localizedDescription)",
                        type: "TMDB"
                    )
                    continue
                }
                for episode in episodes where episode.show.isWesternScheduleCandidate
                    && (!feed.requiresEnglishLanguage || episode.show.isEnglishLanguage) {
                    episodesById[episode.id] = episode
                }
            }
        }

        return scheduleEntries(from: episodesById)
    }

    /// TVMaze's per-date fallback costs two requests per day. Extended ranges
    /// instead use its one-call full feed, filter locally, and retain only the
    /// lightweight 30-day result rather than the multi-megabyte decoded feed.
    private func fetchExtendedSchedule(dayCount: Int) async throws -> [ScheduleEntry] {
        if let cached = extendedScheduleCache,
           Calendar.current.isDate(cached.fetchedAt, inSameDayAs: Date()) {
            let age = Date().timeIntervalSince(cached.fetchedAt)
            if age >= 0, age < extendedCacheMaxAge {
                return entries(cached.entries, within: dayCount)
            }
        }

        let episodes = try await fetchEpisodes(path: "schedule/full", queryItems: [])
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(
            byAdding: .day,
            value: ScheduleWindow.thirtyDays.rawValue,
            to: start
        ) ?? .distantFuture
        let regionCode = Locale.current.regionCode?.uppercased() ?? "US"
        var episodesById: [Int: TVMazeScheduleEpisode] = [:]

        for episode in episodes {
            guard episode.show.isWesternScheduleCandidate,
                  episode.show.isIncludedInFullSchedule(regionCode: regionCode),
                  let airing = episode.airing,
                  airing.date >= start,
                  airing.date < end else {
                continue
            }
            episodesById[episode.id] = episode
        }

        let extendedEntries = scheduleEntries(from: episodesById)
            .sorted { $0.airingAt < $1.airingAt }
        extendedScheduleCache = (Date(), extendedEntries)
        return entries(extendedEntries, within: dayCount)
    }

    private func scheduleEntries(
        from episodesById: [Int: TVMazeScheduleEpisode]
    ) -> [ScheduleEntry] {
        let dailyShowIds = Set(
            Dictionary(grouping: episodesById.values, by: { $0.show.id })
                .compactMap { entry in
                    hasDailyScheduleDensity(entry.value.compactMap { $0.airing?.date })
                        ? entry.key
                        : nil
                }
        )

        return episodesById.values.compactMap { episode in
            guard !dailyShowIds.contains(episode.show.id) else {
                return nil
            }
            guard let airing = episode.airing else {
                return nil
            }
            return ScheduleEntry(westernEpisode: episode, airing: airing)
        }
    }

    private func entries(_ entries: [ScheduleEntry], within dayCount: Int) -> [ScheduleEntry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: max(dayCount, 1), to: start) ?? .distantFuture
        return entries.filter { $0.airingAt >= start && $0.airingAt < end }
    }

    private func fetchEpisodes(path: String, queryItems: [URLQueryItem], retryAfterRateLimit: Bool = true) async throws -> [TVMazeScheduleEpisode] {
        let data = try await fetchData(path: path, queryItems: queryItems, retryAfterRateLimit: retryAfterRateLimit)
        return try JSONDecoder().decode([TVMazeScheduleEpisode].self, from: data)
    }

    private func fetchData(
        path: String,
        queryItems: [URLQueryItem],
        retryAfterRateLimit: Bool = true
    ) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw TVMazeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Eclipse iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TVMazeError.invalidResponse
        }

        if httpResponse.statusCode == 429, retryAfterRateLimit {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await fetchData(
                path: path,
                queryItems: queryItems,
                retryAfterRateLimit: false
            )
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw TVMazeError.httpStatus(httpResponse.statusCode)
        }

        return data
    }
}

private enum TVMazeError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The Western schedule URL could not be created."
        case .invalidResponse:
            return "The Western schedule service returned an invalid response."
        case .httpStatus(let status):
            return "The Western schedule service returned HTTP \(status)."
        }
    }
}

fileprivate struct TVMazeScheduleEpisode: Decodable {
    let id: Int
    let season: Int
    let number: Int?
    let airdate: String
    let airtime: String?
    let airstamp: String?
    let show: TVMazeShow

    private enum CodingKeys: String, CodingKey {
        case id, season, number, airdate, airtime, airstamp, show
        case embedded = "_embedded"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        season = try container.decode(Int.self, forKey: .season)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        airdate = try container.decode(String.self, forKey: .airdate)
        airtime = try container.decodeIfPresent(String.self, forKey: .airtime)
        airstamp = try container.decodeIfPresent(String.self, forKey: .airstamp)
        show = try container.decodeIfPresent(TVMazeShow.self, forKey: .show)
            ?? container.decode(TVMazeEmbedded.self, forKey: .embedded).show
    }

    var airing: TVMazeAiringInfo? {
        tvMazeAiringInfo(
            airdate: airdate,
            airtime: airtime,
            airstamp: airstamp,
            timeZoneIdentifier: show.network?.country?.timezone ?? show.webChannel?.country?.timezone
        )
    }
}

fileprivate struct TVMazeAiringInfo {
    let date: Date
    let hasKnownAiringTime: Bool
}

private func tvMazeAiringInfo(airdate: String, airtime: String?, airstamp: String?, timeZoneIdentifier: String?) -> TVMazeAiringInfo? {
    let normalizedAirtime = airtime?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasKnownAiringTime = normalizedAirtime?.isEmpty == false

    if let airstamp, let date = ISO8601DateFormatter().date(from: airstamp) {
        return TVMazeAiringInfo(date: date, hasKnownAiringTime: hasKnownAiringTime)
    }

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = hasKnownAiringTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
    if let timeZoneIdentifier {
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
    }
    let value = hasKnownAiringTime ? "\(airdate) \(normalizedAirtime ?? "")" : airdate
    guard let date = formatter.date(from: value) else {
        return nil
    }
    return TVMazeAiringInfo(date: date, hasKnownAiringTime: hasKnownAiringTime)
}

fileprivate struct TVMazeEmbedded: Decodable {
    let show: TVMazeShow
}

fileprivate struct TVMazeShow: Decodable {
    let id: Int
    let name: String
    let language: String?
    let type: String?
    let genres: [String]
    let image: TVMazeImage?
    let network: TVMazeChannel?
    let webChannel: TVMazeChannel?
    let schedule: TVMazeShowSchedule?

    var isLikelyAnime: Bool {
        let hasAnimeGenre = genres.contains { genre in
            let normalized = genre.lowercased()
            return normalized == "anime" || normalized == "animation"
        }
        return language?.lowercased() == "japanese" && hasAnimeGenre
    }

    var isWesternScheduleCandidate: Bool {
        guard !isLikelyAnime, (schedule?.days.count ?? 0) < 4 else { return false }
        switch type?.lowercased() {
        case "scripted", "animation":
            return true
        default:
            return false
        }
    }

    var isEnglishLanguage: Bool {
        language?.lowercased() == "english"
    }

    func isIncludedInFullSchedule(regionCode: String) -> Bool {
        let normalizedRegion = regionCode.uppercased()
        if network?.country?.code?.uppercased() == normalizedRegion {
            return true
        }
        if let webCountry = webChannel?.country {
            return webCountry.code?.uppercased() == normalizedRegion
        }
        // A nil web-channel country represents a global streaming service;
        // match the existing English-only global web feed behavior.
        return webChannel != nil && isEnglishLanguage
    }
}

fileprivate struct TVMazeShowSchedule: Decodable {
    let days: [String]
}

fileprivate struct TVMazeImage: Decodable {
    let medium: String?
    let original: String?
}

fileprivate struct TVMazeChannel: Decodable {
    let country: TVMazeCountry?
}

fileprivate struct TVMazeCountry: Decodable {
    let code: String?
    let timezone: String?
}
