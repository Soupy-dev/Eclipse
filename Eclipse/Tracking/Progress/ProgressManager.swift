import Foundation
import AVFoundation
import Combine

// MARK: - Data Models

struct ShowMetadata: Codable {
    let showId: Int
    var title: String
    var posterURL: String?
}

struct ProgressData: Codable {
    var movieProgress: [MovieProgressEntry] = []
    var episodeProgress: [EpisodeProgressEntry] = []
    var showMetadata: [Int: ShowMetadata] = [:]  // showId -> metadata
    var hiddenUpNextShowIds: Set<Int> = []

    private enum CodingKeys: String, CodingKey {
        case movieProgress
        case episodeProgress
        case showMetadata
        case hiddenUpNextShowIds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movieProgress = try container.decodeIfPresent([MovieProgressEntry].self, forKey: .movieProgress) ?? []
        episodeProgress = try container.decodeIfPresent([EpisodeProgressEntry].self, forKey: .episodeProgress) ?? []
        showMetadata = try container.decodeIfPresent([Int: ShowMetadata].self, forKey: .showMetadata) ?? [:]
        hiddenUpNextShowIds = try container.decodeIfPresent(Set<Int>.self, forKey: .hiddenUpNextShowIds) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(movieProgress, forKey: .movieProgress)
        try container.encode(episodeProgress, forKey: .episodeProgress)
        try container.encode(showMetadata, forKey: .showMetadata)
        try container.encode(hiddenUpNextShowIds.sorted(), forKey: .hiddenUpNextShowIds)
    }

    mutating func updateMovie(_ entry: MovieProgressEntry) {
        if let index = movieProgress.firstIndex(where: { $0.id == entry.id }) {
            movieProgress[index] = entry
        } else {
            movieProgress.append(entry)
        }
    }

    mutating func updateEpisode(_ entry: EpisodeProgressEntry) {
        if let index = episodeProgress.firstIndex(where: { $0.id == entry.id }) {
            episodeProgress[index] = entry
        } else {
            episodeProgress.append(entry)
        }
    }
    
    mutating func updateShowMetadata(showId: Int, title: String, posterURL: String?) {
        showMetadata[showId] = ShowMetadata(showId: showId, title: title, posterURL: posterURL)
    }

    func findMovie(id: Int) -> MovieProgressEntry? {
        movieProgress.first { $0.id == id }
    }

    func findEpisode(showId: Int, season: Int, episode: Int) -> EpisodeProgressEntry? {
        episodeProgress.first { $0.showId == showId && $0.seasonNumber == season && $0.episodeNumber == episode }
    }
    
    func getShowMetadata(showId: Int) -> ShowMetadata? {
        showMetadata[showId]
    }
}

struct MovieProgressEntry: Codable, Identifiable {
    let id: Int
    let title: String
    var posterURL: String? = nil
    var currentTime: Double = 0
    var totalDuration: Double = 0
    var isWatched: Bool = false
    var lastUpdated: Date = Date()
    var lastServiceId: UUID? = nil
    var lastHref: String? = nil

    var progress: Double {
        guard totalDuration > 0 else { return 0 }
        return min(currentTime / totalDuration, 1.0)
    }
}

struct EpisodeProgressEntry: Codable, Identifiable {
    let id: String
    let showId: Int
    let seasonNumber: Int
    let episodeNumber: Int
    var currentTime: Double = 0
    var totalDuration: Double = 0
    var isWatched: Bool = false
    var lastUpdated: Date = Date()
    var lastServiceId: UUID? = nil
    var lastHref: String? = nil
    var playbackContext: EpisodePlaybackContext? = nil
    var isAnime: Bool? = nil

    var progress: Double {
        guard totalDuration > 0 else { return 0 }
        return min(currentTime / totalDuration, 1.0)
    }

    init(showId: Int, seasonNumber: Int, episodeNumber: Int) {
        self.id = "ep_\(showId)_s\(seasonNumber)_e\(episodeNumber)"
        self.showId = showId
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
    }
}

enum ContinueWatchingRemovalTarget {
    case localProgress
    case localUpNextShow
    case traktPlayback(Int)
    case traktUpNextShow
    case none

    var isRemovable: Bool {
        switch self {
        case .none:
            return false
        case .localProgress, .localUpNextShow, .traktPlayback, .traktUpNextShow:
            return true
        }
    }
}

// Continue watching item
struct ContinueWatchingItem: Identifiable {
    let id: String
    let tmdbId: Int
    let isMovie: Bool
    let title: String
    let posterURL: String?
    let progress: Double
    let lastUpdated: Date
    let seasonNumber: Int?
    let episodeNumber: Int?
    let currentTime: Double
    let totalDuration: Double
    let playbackContext: EpisodePlaybackContext?
    let isAnime: Bool
    let statusText: String?
    let isWatchNext: Bool
    let traktPlaybackId: Int?
    var removalTarget: ContinueWatchingRemovalTarget = .localProgress
    
    var remainingTime: String {
        let remaining = max(0, totalDuration - currentTime)
        let minutes = Int(remaining / 60)
        if minutes < 60 {
            return "\(minutes) min left"
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            return mins > 0 ? "\(hours)h \(mins)m left" : "\(hours)h left"
        }
    }

    var displayStatus: String {
        statusText ?? remainingTime
    }
}

// MARK: - ProgressManager

final class ProgressManager: ObservableObject {
    static let shared = ProgressManager()

    private let fileManager = FileManager.default
    private var progressData: ProgressData = ProgressData()
    private let progressFileURL: URL
    private let debounceInterval: TimeInterval = 2.0
    private var debounceTask: Task<Void, Never>?
    private let accessQueue = DispatchQueue(label: "app.eclipse.soupy.progress-manager", attributes: .concurrent)
    private var durationShrinkWarningKeys: Set<String> = []
    private static let continueWatchingMinimumProgress = 0.05
    private static let watchedProgressThreshold = 0.85

    private static let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    @Published private(set) var movieProgressList: [MovieProgressEntry] = []
    @Published private(set) var episodeProgressList: [EpisodeProgressEntry] = []

    private init() {
        self.progressFileURL = Self.documentsDirectory.appendingPathComponent("ProgressData.json")
        loadProgressData()
    }
    
    // MARK: - Public Access
    
    /// Returns a snapshot of the current progress data for backup purposes
    func getProgressData() -> ProgressData {
        return accessQueue.sync {
            return self.progressData
        }
    }

    /// Replaces all progress data during backup restore without triggering per-entry tracker sync.
    func replaceProgressDataForRestore(_ newData: ProgressData) {
        accessQueue.sync(flags: .barrier) {
            self.progressData = newData
        }
        publishProgressData(newData)
        writeProgressData(newData)
        Logger.shared.log("Progress data restored in bulk (\(newData.movieProgress.count) movies, \(newData.episodeProgress.count) episodes)", type: "Progress")
    }

    /// Marks episodes up to throughEpisode without tracker sync.
    /// Used during AniList import to avoid syncing back data we just imported.
    func bulkMarkEpisodesAsWatched(showId: Int, seasonNumber: Int, throughEpisode: Int) {
        guard throughEpisode >= 1 else { return }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for e in 1...throughEpisode {
                var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: e)
                    ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: e)
                guard !entry.isWatched else { continue }
                let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
                entry.totalDuration = safeDuration
                entry.isWatched = true
                entry.currentTime = safeDuration
                entry.lastUpdated = Date()
                self.progressData.updateEpisode(entry)
            }
            self.publishCurrentData()
            Logger.shared.log("Bulk marked S\(seasonNumber)E1-E\(throughEpisode) as watched for show \(showId) (import)", type: "Progress")
        }
        saveProgressData()
    }

    private func publishCurrentData() {
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            self.publishProgressData(self.progressData)
        }
    }

    private func publishProgressData(_ snapshot: ProgressData) {
        let movies = snapshot.movieProgress
        let episodes = snapshot.episodeProgress
        DispatchQueue.main.async {
            self.movieProgressList = movies
            self.episodeProgressList = episodes
            NotificationCenter.default.post(name: .progressDataDidChange, object: self)
        }
    }

    // MARK: - Data Persistence

    private func loadProgressData() {
        guard fileManager.fileExists(atPath: progressFileURL.path) else {
            Logger.shared.log("Progress file not found, initializing new data", type: "Progress")
            return
        }

        do {
            let data = try Data(contentsOf: progressFileURL)
            Logger.shared.log("Progress file size: \(data.count) bytes", type: "Progress")

            let decoded = try JSONDecoder().decode(ProgressData.self, from: data)
            Logger.shared.log("Loaded \(decoded.episodeProgress.count) episodes from JSON", type: "Progress")
            for ep in decoded.episodeProgress.prefix(5) {
                Logger.shared.log("  - showId=\(ep.showId) S\(ep.seasonNumber)E\(ep.episodeNumber)", type: "Progress")
            }
            accessQueue.async(flags: .barrier) { [weak self] in
                self?.progressData = decoded
                self?.publishCurrentData()
            }
            Logger.shared.log("Progress data loaded successfully (\(decoded.movieProgress.count) movies, \(decoded.episodeProgress.count) episodes)", type: "Progress")
        } catch {
            Logger.shared.log("Failed to load progress data: \(error.localizedDescription)", type: "Error")
        }
    }

    private func saveProgressData() {
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            self.writeProgressData(self.progressData)
        }
    }

    private func writeProgressData(_ snapshot: ProgressData) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: progressFileURL, options: .atomic)
            Logger.shared.log("Progress data saved successfully", type: "Progress")
        } catch {
            Logger.shared.log("Failed to save progress data: \(error.localizedDescription)", type: "Error")
        }
    }

    private func debouncedSave() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
            if !Task.isCancelled {
                self.saveProgressData()
            }
        }
    }

    func flushPendingSave() {
        debounceTask?.cancel()
        debounceTask = nil
        let snapshot = accessQueue.sync {
            progressData
        }
        writeProgressData(snapshot)
    }

    private func stableProgressTimes(
        currentTime: Double,
        totalDuration: Double,
        previousDuration: Double,
        label: String
    ) -> (currentTime: Double, totalDuration: Double)? {
        guard currentTime.isFinite, totalDuration.isFinite, currentTime >= 0, totalDuration > 0 else {
            Logger.shared.log("Invalid progress values for \(label): currentTime=\(currentTime), totalDuration=\(totalDuration)", type: "Warning")
            return nil
        }

        var resolvedDuration = totalDuration
        if previousDuration.isFinite, previousDuration > 0 {
            let shrinkTolerance = max(2.0, previousDuration * 0.005)
            if totalDuration + shrinkTolerance < previousDuration {
                let warningKey = "\(label)|\(Int(previousDuration.rounded()))|\(Int(totalDuration.rounded()))"
                if durationShrinkWarningKeys.insert(warningKey).inserted {
                    Logger.shared.log("Ignoring shorter reported duration for \(label): previous=\(previousDuration), reported=\(totalDuration)", type: "Warning")
                }
            }
            resolvedDuration = max(resolvedDuration, previousDuration)
        }

        resolvedDuration = max(resolvedDuration, currentTime)
        let resolvedTime = min(max(0, currentTime), resolvedDuration)
        return (resolvedTime, resolvedDuration)
    }

    // MARK: - Movie Progress

    func updateMovieProgress(movieId: Int, title: String, currentTime: Double, totalDuration: Double, posterURL: String? = nil) {
        guard currentTime.isFinite, totalDuration.isFinite, currentTime >= 0, totalDuration > 0 else {
            Logger.shared.log("Invalid progress values for movie \(title): currentTime=\(currentTime), totalDuration=\(totalDuration)", type: "Warning")
            return
        }

        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            var entry = self.progressData.findMovie(id: movieId) ?? MovieProgressEntry(id: movieId, title: title)
            let previousWatchedState = entry.isWatched
            guard let times = self.stableProgressTimes(
                currentTime: currentTime,
                totalDuration: totalDuration,
                previousDuration: entry.totalDuration,
                label: "movie \(title)"
            ) else { return }
            entry.currentTime = times.currentTime
            entry.totalDuration = times.totalDuration
            entry.lastUpdated = Date()
            
            // Update poster if provided
            if let posterURL = posterURL {
                entry.posterURL = posterURL
            }

            if entry.progress >= 0.85 {
                entry.isWatched = true
            }

            self.progressData.updateMovie(entry)
            self.publishCurrentData()

            DispatchQueue.main.async {
                TrackerManager.shared.syncTraktMoviePlaybackProgress(
                    movieId: movieId,
                    progress: entry.progress,
                    force: !previousWatchedState && entry.isWatched
                )
            }
        }
        debouncedSave()
    }

    func getMovieProgress(movieId: Int, title: String) -> Double {
        var result: Double = 0.0
        accessQueue.sync {
            result = self.progressData.findMovie(id: movieId)?.progress ?? 0.0
        }
        return result
    }

    func getMovieCurrentTime(movieId: Int, title: String) -> Double {
        var result: Double = 0.0
        accessQueue.sync {
            result = self.progressData.findMovie(id: movieId)?.currentTime ?? 0.0
        }
        return result
    }

    func isMovieWatched(movieId: Int) -> Bool {
        var result: Bool = false
        accessQueue.sync {
            if let entry = self.progressData.findMovie(id: movieId) {
                result = Self.isCompletedMovie(entry)
            }
        }
        return result
    }

    func markMovieAsWatched(movieId: Int, title: String, posterURL: String? = nil) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            var entry = self.progressData.findMovie(id: movieId) ?? MovieProgressEntry(id: movieId, title: title)
            let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
            entry.posterURL = posterURL ?? entry.posterURL
            entry.totalDuration = safeDuration
            entry.currentTime = safeDuration
            entry.isWatched = true
            entry.lastUpdated = Date()
            self.progressData.updateMovie(entry)
            self.publishCurrentData()
            self.saveProgressData()
            Logger.shared.log("Marked movie as watched: \(entry.title)", type: "Progress")

            DispatchQueue.main.async {
                TrackerManager.shared.syncTraktMoviePlaybackProgress(movieId: movieId, progress: 1.0, force: true)
            }
        }
    }

    func markMovieAsUnwatched(movieId: Int, title: String, posterURL: String? = nil) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            var entry = self.progressData.findMovie(id: movieId) ?? MovieProgressEntry(id: movieId, title: title)
            entry.posterURL = posterURL ?? entry.posterURL
            entry.currentTime = 0
            entry.isWatched = false
            entry.lastUpdated = Date()
            self.progressData.updateMovie(entry)
            self.publishCurrentData()
            self.saveProgressData()
            Logger.shared.log("Marked movie as unwatched: \(entry.title)", type: "Progress")
        }
    }

    // MARK: - Record last service/href used for playback

    func recordMovieServiceInfo(movieId: Int, serviceId: UUID?, href: String?) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            if var entry = self.progressData.findMovie(id: movieId) {
                entry.lastServiceId = serviceId
                entry.lastHref = href
                entry.lastUpdated = Date()
                self.progressData.updateMovie(entry)
                self.publishCurrentData()
            } else {
                var newEntry = MovieProgressEntry(id: movieId, title: "")
                newEntry.lastServiceId = serviceId
                newEntry.lastHref = href
                newEntry.lastUpdated = Date()
                self.progressData.updateMovie(newEntry)
                self.publishCurrentData()
            }
        }
        saveProgressData()
    }

    func recordEpisodeServiceInfo(showId: Int, seasonNumber: Int, episodeNumber: Int, serviceId: UUID?, href: String?) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            if var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber) {
                entry.lastServiceId = serviceId
                entry.lastHref = href
                entry.lastUpdated = Date()
                self.progressData.updateEpisode(entry)
                self.publishCurrentData()
            } else {
                var newEntry = EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
                newEntry.lastServiceId = serviceId
                newEntry.lastHref = href
                newEntry.lastUpdated = Date()
                self.progressData.updateEpisode(newEntry)
                self.publishCurrentData()
            }
        }
        saveProgressData()
    }

    // MARK: - Episode Progress

    func updateEpisodeProgress(showId: Int, seasonNumber: Int, episodeNumber: Int, currentTime: Double, totalDuration: Double, showTitle: String? = nil, showPosterURL: String? = nil, playbackContext: EpisodePlaybackContext? = nil, isAnime: Bool = false) {
        guard currentTime.isFinite, totalDuration.isFinite, currentTime >= 0, totalDuration > 0 else {
            Logger.shared.log("Invalid progress values for episode S\(seasonNumber)E\(episodeNumber): currentTime=\(currentTime), totalDuration=\(totalDuration)", type: "Warning")       
            return
        }

        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)
                ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)

            let previousWatchedState = entry.isWatched
            guard let times = self.stableProgressTimes(
                currentTime: currentTime,
                totalDuration: totalDuration,
                previousDuration: entry.totalDuration,
                label: "episode S\(seasonNumber)E\(episodeNumber)"
            ) else { return }
            entry.currentTime = times.currentTime
            entry.totalDuration = times.totalDuration
            entry.lastUpdated = Date()
            entry.playbackContext = playbackContext ?? entry.playbackContext
            entry.isAnime = entry.isAnime == true || isAnime || playbackContext?.hasAnimeMediaId == true

            if entry.progress >= 0.85 {
                entry.isWatched = true
            }

            self.unhideUpNextShowIfNeeded(showId: showId)
            self.progressData.updateEpisode(entry)
            
            // Update show metadata if provided
            if let showTitle = showTitle {
                self.progressData.updateShowMetadata(showId: showId, title: showTitle, posterURL: showPosterURL)
            }
            
            self.publishCurrentData()

            if !entry.isWatched {
                DispatchQueue.main.async {
                    TrackerManager.shared.syncTraktEpisodePlaybackProgress(
                        showId: showId,
                        seasonNumber: seasonNumber,
                        episodeNumber: episodeNumber,
                        progress: entry.progress,
                        playbackContext: playbackContext?.forEpisodeNumber(episodeNumber)
                    )
                }
            }

            // Sync to trackers if just reached watched threshold
            if !previousWatchedState && entry.isWatched {
                DispatchQueue.main.async {
                    TrackerManager.shared.syncWatchProgress(
                        showId: showId,
                        seasonNumber: seasonNumber,
                        episodeNumber: episodeNumber,
                        progress: entry.progress,
                        isAnime: entry.isAnime == true,
                        playbackContext: playbackContext?.forEpisodeNumber(episodeNumber)
                    )
                }
            }
        }
        debouncedSave()
    }

    func getEpisodeProgress(showId: Int, seasonNumber: Int, episodeNumber: Int) -> Double {
        var result: Double = 0.0
        accessQueue.sync {
            result = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)?.progress ?? 0.0
        }
        return result
    }

    func getEpisodeCurrentTime(showId: Int, seasonNumber: Int, episodeNumber: Int) -> Double {
        var result: Double = 0.0
        accessQueue.sync {
            result = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)?.currentTime ?? 0.0
        }
        return result
    }

    func getLatestEpisodeProgress(showId: Int) -> EpisodeProgressEntry? {
        var result: EpisodeProgressEntry?
        accessQueue.sync {
            result = self.progressData.episodeProgress
                .filter {
                    $0.showId == showId &&
                    ($0.currentTime > 0 || $0.totalDuration > 0 || $0.isWatched || $0.lastHref != nil)
                }
                .max { $0.lastUpdated < $1.lastUpdated }
        }
        return result
    }

    func findEpisode(showId: Int, season: Int, episode: Int) -> EpisodeProgressEntry? {
        var result: EpisodeProgressEntry?
        accessQueue.sync {
            result = self.progressData.findEpisode(showId: showId, season: season, episode: episode)
        }
        return result
    }

    func isEpisodeWatched(showId: Int, seasonNumber: Int, episodeNumber: Int) -> Bool {
        var result: Bool = false
        accessQueue.sync {
            if let entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber) {
                result = Self.isCompletedEpisode(entry)
            }
        }
        return result
    }

    func hasStartedOrCompletedEpisode(showId: Int, seasonNumber: Int, episodeNumber: Int) -> Bool {
        var result: Bool = false
        accessQueue.sync {
            if let entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber) {
                result = entry.isWatched || entry.progress > Self.continueWatchingMinimumProgress
            }
        }
        return result
    }

    func markEpisodeAsWatched(showId: Int, seasonNumber: Int, episodeNumber: Int, playbackContext: EpisodePlaybackContext? = nil, isAnime: Bool = false) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)
                ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
            let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
            entry.totalDuration = safeDuration
            entry.isWatched = true
            entry.currentTime = safeDuration
            entry.lastUpdated = Date()
            entry.playbackContext = playbackContext ?? entry.playbackContext
            entry.isAnime = entry.isAnime == true || isAnime || playbackContext?.hasAnimeMediaId == true
            self.unhideUpNextShowIfNeeded(showId: showId)
            self.progressData.updateEpisode(entry)
            self.publishCurrentData()
            Logger.shared.log("Marked episode as watched: S\(seasonNumber)E\(episodeNumber)", type: "Progress")

            // Sync to trackers
            DispatchQueue.main.async {
                TrackerManager.shared.syncWatchProgress(
                    showId: showId,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber,
                    progress: 1.0,
                    isAnime: entry.isAnime == true,
                    playbackContext: playbackContext?.forEpisodeNumber(episodeNumber)
                )
            }
        }
        saveProgressData()
    }

    /// Marks only the supplied episode numbers as watched locally without triggering tracker sync.
    /// Trakt progress can contain gaps, so imports must not assume every earlier episode was watched.
    func bulkMarkEpisodeNumbersAsWatched(showId: Int, seasonNumber: Int, episodeNumbers: [Int]) {
        let episodeNumbers = Array(Set(episodeNumbers.filter { $0 >= 1 })).sorted()
        guard !episodeNumbers.isEmpty else { return }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for episodeNumber in episodeNumbers {
                var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)
                    ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
                guard !entry.isWatched else { continue }
                let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
                entry.totalDuration = safeDuration
                entry.isWatched = true
                entry.currentTime = safeDuration
                entry.lastUpdated = Date()
                self.progressData.updateEpisode(entry)
            }
            self.publishCurrentData()
            Logger.shared.log("Bulk marked \(episodeNumbers.count) exact episode(s) as watched for show \(showId) S\(seasonNumber) (import)", type: "Progress")
        }
        saveProgressData()
    }

    /// Marks a movie as watched locally during import without enqueueing tracker sync.
    func markMovieAsWatchedForImport(movieId: Int, title: String, posterURL: String? = nil) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            var entry = self.progressData.findMovie(id: movieId) ?? MovieProgressEntry(id: movieId, title: title)
            let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
            entry.posterURL = posterURL ?? entry.posterURL
            entry.totalDuration = safeDuration
            entry.currentTime = safeDuration
            entry.isWatched = true
            entry.lastUpdated = Date()
            self.progressData.updateMovie(entry)
            self.publishCurrentData()
            Logger.shared.log("Marked movie \(movieId) as watched locally (import)", type: "Progress")
        }
        saveProgressData()
    }

    func resetEpisodeProgress(showId: Int, seasonNumber: Int, episodeNumber: Int) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)
                ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
            entry.currentTime = 0
            entry.isWatched = false
            entry.lastUpdated = Date()
            self.progressData.updateEpisode(entry)
            self.publishCurrentData()
            Logger.shared.log("Reset episode progress: S\(seasonNumber)E\(episodeNumber)", type: "Progress")
        }
        saveProgressData()
    }

    func markPreviousEpisodesAsWatched(showId: Int, seasonNumber: Int, episodeNumber: Int, playbackContext: EpisodePlaybackContext? = nil, isAnime: Bool = false) {
        guard episodeNumber > 1 else { return }

        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for e in 1..<episodeNumber {
                var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: e)
                    ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: e)
                let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
                entry.totalDuration = safeDuration
                entry.isWatched = true
                entry.currentTime = safeDuration
                entry.lastUpdated = Date()
                entry.playbackContext = playbackContext?.forEpisodeNumber(e)
                entry.isAnime = isAnime || playbackContext?.hasAnimeMediaId == true
                self.progressData.updateEpisode(entry)
            }
            self.publishCurrentData()
            Logger.shared.log("Marked previous episodes as watched for S\(seasonNumber) up to E\(episodeNumber - 1)", type: "Progress")

            // Sync highest episode to trackers (AniList progress is cumulative, so one call suffices)
            DispatchQueue.main.async {
                let highestEpisode = episodeNumber - 1
                TrackerManager.shared.syncWatchProgress(
                    showId: showId,
                    seasonNumber: seasonNumber,
                    episodeNumber: highestEpisode,
                    progress: 1.0,
                    isAnime: isAnime || playbackContext?.hasAnimeMediaId == true,
                    playbackContext: playbackContext?.forEpisodeNumber(highestEpisode)
                )
            }
        }
        saveProgressData()
    }

    func markEpisodeAsUnwatched(showId: Int, seasonNumber: Int, episodeNumber: Int) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)
                ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
            entry.currentTime = 0
            entry.isWatched = false
            entry.lastUpdated = Date()
            self.progressData.updateEpisode(entry)
            self.publishCurrentData()
            Logger.shared.log("Marked episode as unwatched: S\(seasonNumber)E\(episodeNumber)", type: "Progress")
        }
        saveProgressData()
    }

    func markPreviousEpisodesAsUnwatched(showId: Int, seasonNumber: Int, episodeNumber: Int) {
        guard episodeNumber > 1 else { return }

        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for e in 1..<episodeNumber {
                var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: e)
                    ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: e)
                entry.currentTime = 0
                entry.isWatched = false
                entry.lastUpdated = Date()
                self.progressData.updateEpisode(entry)
            }
            self.publishCurrentData()
            Logger.shared.log("Marked previous episodes as unwatched for S\(seasonNumber) up to E\(episodeNumber - 1)", type: "Progress")
        }
        saveProgressData()
    }

    // MARK: - Continue Watching
    
    func getContinueWatchingItems(limit: Int = 10) -> [ContinueWatchingItem] {
        var items: [ContinueWatchingItem] = []
        
        accessQueue.sync {
            // Add movies
            let movies = self.progressData.movieProgress
                .filter { !$0.isWatched && $0.progress > Self.continueWatchingMinimumProgress && $0.progress < Self.watchedProgressThreshold }
                .map { movie in
                    ContinueWatchingItem(
                        id: "movie_\(movie.id)",
                        tmdbId: movie.id,
                        isMovie: true,
                        title: movie.title,
                        posterURL: movie.posterURL,
                        progress: movie.progress,
                        lastUpdated: movie.lastUpdated,
                        seasonNumber: nil,
                        episodeNumber: nil,
                        currentTime: movie.currentTime,
                        totalDuration: movie.totalDuration,
                        playbackContext: nil,
                        isAnime: false,
                        statusText: nil,
                        isWatchNext: false,
                        traktPlaybackId: nil
                    )
                }
            
            // Add episodes (grouped by show, keep most recent)
            var showMap: [Int: EpisodeProgressEntry] = [:]
            for episode in self.progressData.episodeProgress where Self.isActiveContinueWatchingEpisode(episode) {
                if let existing = showMap[episode.showId] {
                    if episode.lastUpdated > existing.lastUpdated {
                        showMap[episode.showId] = episode
                    }
                } else {
                    showMap[episode.showId] = episode
                }
            }
            
            let episodes = showMap.values.map { episode in
                // Look up show metadata
                let showMeta = self.progressData.getShowMetadata(showId: episode.showId)
                return ContinueWatchingItem(
                    id: "episode_\(episode.showId)",
                    tmdbId: episode.showId,
                    isMovie: false,
                    title: showMeta?.title ?? "",
                    posterURL: showMeta?.posterURL,
                    progress: episode.progress,
                    lastUpdated: episode.lastUpdated,
                    seasonNumber: episode.seasonNumber,
                    episodeNumber: episode.episodeNumber,
                    currentTime: episode.currentTime,
                    totalDuration: episode.totalDuration,
                    playbackContext: episode.playbackContext,
                    isAnime: episode.isAnime == true || episode.playbackContext?.hasAnimeMediaId == true,
                    statusText: nil,
                    isWatchNext: false,
                    traktPlaybackId: nil
                )
            }
            
            items = (movies + episodes)
                .sorted { $0.lastUpdated > $1.lastUpdated }
                .prefix(limit)
                .map { $0 }
        }
        
        return items
    }

    func getWatchNextCandidates(limit: Int = 10) -> [WatchNextCandidate] {
        var candidates: [WatchNextCandidate] = []

        accessQueue.sync {
            let hiddenShowIds = self.progressData.hiddenUpNextShowIds
            candidates = Dictionary(grouping: self.progressData.episodeProgress, by: \.showId)
                .compactMap { showId, episodes in
                    guard !hiddenShowIds.contains(showId) else {
                        return nil
                    }

                    let regularEpisodes = episodes.filter(Self.isRegularEpisode)
                    guard !regularEpisodes.contains(where: Self.isActiveContinueWatchingEpisode) else {
                        return nil
                    }

                    let completedEpisodes = regularEpisodes.filter(Self.isCompletedEpisode)
                    guard let frontier = completedEpisodes.max(by: Self.isEpisodeBefore) else {
                        return nil
                    }

                    let showMeta = self.progressData.getShowMetadata(showId: showId)
                    let lastUpdated = completedEpisodes.map(\.lastUpdated).max() ?? frontier.lastUpdated
                    return WatchNextCandidate(
                        tmdbId: frontier.showId,
                        title: showMeta?.title ?? "",
                        posterURL: showMeta?.posterURL,
                        seasonNumber: frontier.seasonNumber,
                        episodeNumber: frontier.episodeNumber,
                        lastUpdated: lastUpdated,
                        playbackContext: frontier.playbackContext,
                        isAnime: frontier.isAnime == true || frontier.playbackContext?.hasAnimeMediaId == true
                    )
                }
                .sorted { $0.lastUpdated > $1.lastUpdated }
                .prefix(limit)
                .map { $0 }
        }

        return candidates
    }

    private static func isRegularEpisode(_ episode: EpisodeProgressEntry) -> Bool {
        episode.seasonNumber > 0 && episode.episodeNumber > 0
    }

    private static func isCompletedEpisode(_ episode: EpisodeProgressEntry) -> Bool {
        episode.isWatched || episode.progress >= watchedProgressThreshold
    }

    private static func isCompletedMovie(_ movie: MovieProgressEntry) -> Bool {
        movie.isWatched || movie.progress >= watchedProgressThreshold
    }

    private static func isActiveContinueWatchingEpisode(_ episode: EpisodeProgressEntry) -> Bool {
        !episode.isWatched &&
        episode.progress > continueWatchingMinimumProgress &&
        episode.progress < watchedProgressThreshold
    }

    private static func isEpisodeBefore(_ lhs: EpisodeProgressEntry, _ rhs: EpisodeProgressEntry) -> Bool {
        if lhs.seasonNumber == rhs.seasonNumber {
            return lhs.episodeNumber < rhs.episodeNumber
        }
        return lhs.seasonNumber < rhs.seasonNumber
    }

    func markContinueWatchingItemAsWatched(_ item: ContinueWatchingItem) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            if item.isMovie {
                var entry = self.progressData.findMovie(id: item.tmdbId)
                    ?? MovieProgressEntry(id: item.tmdbId, title: item.title)
                let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
                entry.totalDuration = safeDuration
                entry.currentTime = safeDuration
                entry.isWatched = true
                entry.lastUpdated = Date()
                self.progressData.updateMovie(entry)
                Logger.shared.log("Marked continue-watching movie as watched: \(entry.title)", type: "Progress")
                DispatchQueue.main.async {
                    TrackerManager.shared.syncTraktMoviePlaybackProgress(movieId: item.tmdbId, progress: 1.0, force: true)
                }
            } else {
                guard let seasonNumber = item.seasonNumber,
                      let episodeNumber = item.episodeNumber else { return }
                var entry = self.progressData.findEpisode(showId: item.tmdbId, season: seasonNumber, episode: episodeNumber)
                    ?? EpisodeProgressEntry(showId: item.tmdbId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
                let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
                entry.totalDuration = safeDuration
                entry.currentTime = safeDuration
                entry.isWatched = true
                entry.lastUpdated = Date()
                self.unhideUpNextShowIfNeeded(showId: item.tmdbId)
                self.progressData.updateEpisode(entry)
                self.progressData.updateShowMetadata(showId: item.tmdbId, title: item.title, posterURL: item.posterURL)
                Logger.shared.log("Marked continue-watching episode as watched: showId=\(item.tmdbId) S\(seasonNumber)E\(episodeNumber)", type: "Progress")

                DispatchQueue.main.async {
                    TrackerManager.shared.syncWatchProgress(
                        showId: item.tmdbId,
                        seasonNumber: seasonNumber,
                        episodeNumber: episodeNumber,
                        progress: 1.0,
                        isAnime: item.isAnime,
                        playbackContext: item.playbackContext?.forEpisodeNumber(episodeNumber)
                    )
                }
            }

            self.publishCurrentData()
            self.saveProgressData()
        }
    }

    func removeUpNextShow(_ item: ContinueWatchingItem) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.progressData.hiddenUpNextShowIds.insert(item.tmdbId)
            Logger.shared.log("Removed show from Up Next: showId=\(item.tmdbId)", type: "Progress")
            self.publishCurrentData()
            self.saveProgressData()
        }
    }

    private func unhideUpNextShowIfNeeded(showId: Int) {
        if progressData.hiddenUpNextShowIds.remove(showId) != nil {
            Logger.shared.log("Restored show to Up Next after new progress: showId=\(showId)", type: "Progress")
        }
    }

    func removeContinueWatchingItem(_ item: ContinueWatchingItem) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            if item.isMovie {
                self.progressData.movieProgress.removeAll { $0.id == item.tmdbId }
                Logger.shared.log("Removed continue-watching movie entry id=\(item.tmdbId)", type: "Progress")
            } else {
                guard let seasonNumber = item.seasonNumber,
                      let episodeNumber = item.episodeNumber else { return }
                self.progressData.episodeProgress.removeAll {
                    $0.showId == item.tmdbId &&
                    $0.seasonNumber == seasonNumber &&
                    $0.episodeNumber == episodeNumber
                }

                let hasEpisodesForShow = self.progressData.episodeProgress.contains { $0.showId == item.tmdbId }
                if !hasEpisodesForShow {
                    self.progressData.showMetadata[item.tmdbId] = nil
                }

                Logger.shared.log("Removed continue-watching episode entry showId=\(item.tmdbId) S\(seasonNumber)E\(episodeNumber)", type: "Progress")
            }

            self.publishCurrentData()
            self.saveProgressData()
        }
    }

    // MARK: - AVPlayer Extension

    func syncTraktProgressOnPlaybackClose(for mediaInfo: MediaInfo, playbackContext: EpisodePlaybackContext? = nil, played: Bool = true) {
        guard played else {
            Logger.shared.log("Skipping Trakt playback-close sync because playback never started", type: "Tracker")
            return
        }
        switch mediaInfo {
        case .movie(let id, _, _, _):
            let progress = accessQueue.sync {
                self.progressData.findMovie(id: id)?.progress ?? 0
            }
            TrackerManager.shared.syncTraktMoviePlaybackProgress(movieId: id, progress: progress, force: true)
        case .episode(let showId, let seasonNumber, let episodeNumber, _, _, _):
            let progress = accessQueue.sync {
                self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)?.progress ?? 0
            }
            TrackerManager.shared.syncTraktEpisodePlaybackProgress(
                showId: showId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                progress: progress,
                playbackContext: playbackContext?.forEpisodeNumber(episodeNumber),
                force: true
            )
        }
    }

    func addPeriodicTimeObserver(to player: AVPlayer, for mediaInfo: MediaInfo, playbackContext: EpisodePlaybackContext? = nil) -> Any? {
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

        return player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self,
                  let currentItem = player.currentItem,
                  currentItem.duration.seconds.isFinite,
                  currentItem.duration.seconds >= 5 else {
                return
            }

            let currentTime = time.seconds
            let duration = currentItem.duration.seconds

            guard currentTime >= 0 && currentTime <= duration else { return }

            switch mediaInfo {
            case .movie(let id, let title, let posterURL, _):
                self.updateMovieProgress(movieId: id, title: title, currentTime: currentTime, totalDuration: duration, posterURL: posterURL)
                if player.timeControlStatus == .playing {
                    TrackerManager.shared.scrobbleTraktPlayback(
                        .start,
                        for: mediaInfo,
                        progress: currentTime / duration
                    )
                }

            case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, let showPosterURL, let isAnime):
                let resolvedPlaybackContext = playbackContext?.forEpisodeNumber(episodeNumber)
                self.updateEpisodeProgress(
                    showId: showId,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber,
                    currentTime: currentTime,
                    totalDuration: duration,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    playbackContext: resolvedPlaybackContext,
                    isAnime: isAnime || playbackContext?.hasAnimeMediaId == true
                )
                if player.timeControlStatus == .playing {
                    TrackerManager.shared.scrobbleTraktPlayback(
                        .start,
                        for: mediaInfo,
                        progress: currentTime / duration,
                        playbackContext: resolvedPlaybackContext
                    )
                }
            }
        }
    }

}

struct WatchNextCandidate {
    let tmdbId: Int
    let title: String
    let posterURL: String?
    let seasonNumber: Int
    let episodeNumber: Int
    let lastUpdated: Date
    let playbackContext: EpisodePlaybackContext?
    let isAnime: Bool
}


// MARK: - MediaInfo Enum

struct EpisodePlaybackContext: Codable, Equatable, Sendable {
    let localSeasonNumber: Int
    let localEpisodeNumber: Int
    let anilistMediaId: Int?
    let kitsuMediaId: Int?
    let tmdbSeasonNumber: Int?
    let tmdbEpisodeNumber: Int?
    let tmdbEpisodeOffset: Int?
    let animeAbsoluteEpisodeNumber: Int?
    let animeSeasonEpisodeCount: Int?
    let isSpecial: Bool
    let titleOnlySearch: Bool

    init(
        localSeasonNumber: Int,
        localEpisodeNumber: Int,
        anilistMediaId: Int?,
        kitsuMediaId: Int? = nil,
        tmdbSeasonNumber: Int?,
        tmdbEpisodeNumber: Int?,
        tmdbEpisodeOffset: Int?,
        animeAbsoluteEpisodeNumber: Int?,
        animeSeasonEpisodeCount: Int?,
        isSpecial: Bool,
        titleOnlySearch: Bool
    ) {
        self.localSeasonNumber = localSeasonNumber
        self.localEpisodeNumber = localEpisodeNumber
        self.anilistMediaId = anilistMediaId
        self.kitsuMediaId = kitsuMediaId
        self.tmdbSeasonNumber = tmdbSeasonNumber
        self.tmdbEpisodeNumber = tmdbEpisodeNumber
        self.tmdbEpisodeOffset = tmdbEpisodeOffset
        self.animeAbsoluteEpisodeNumber = animeAbsoluteEpisodeNumber
        self.animeSeasonEpisodeCount = animeSeasonEpisodeCount
        self.isSpecial = isSpecial
        self.titleOnlySearch = titleOnlySearch
    }

    var resolvedTMDBSeasonNumber: Int? {
        tmdbSeasonNumber
    }

    var hasAnimeMediaId: Bool {
        anilistMediaId != nil || kitsuMediaId != nil
    }

    var resolvedTMDBEpisodeNumber: Int? {
        if let tmdbEpisodeNumber {
            return tmdbEpisodeNumber
        }
        guard tmdbSeasonNumber != nil, let tmdbEpisodeOffset else {
            return nil
        }
        return tmdbEpisodeOffset + localEpisodeNumber
    }

    func forEpisodeNumber(_ episodeNumber: Int) -> EpisodePlaybackContext {
        let absoluteEpisodeNumber = animeAbsoluteEpisodeNumber.map {
            max(1, $0 - localEpisodeNumber + episodeNumber)
        }
        let translatedTMDBEpisodeNumber = tmdbEpisodeOffset.map { $0 + episodeNumber }
            ?? (episodeNumber == localEpisodeNumber ? tmdbEpisodeNumber : nil)

        return EpisodePlaybackContext(
            localSeasonNumber: localSeasonNumber,
            localEpisodeNumber: episodeNumber,
            anilistMediaId: anilistMediaId,
            kitsuMediaId: kitsuMediaId,
            tmdbSeasonNumber: tmdbSeasonNumber,
            tmdbEpisodeNumber: translatedTMDBEpisodeNumber,
            tmdbEpisodeOffset: tmdbEpisodeOffset,
            animeAbsoluteEpisodeNumber: absoluteEpisodeNumber,
            animeSeasonEpisodeCount: animeSeasonEpisodeCount,
            isSpecial: isSpecial,
            titleOnlySearch: titleOnlySearch
        )
    }

    func withKitsuMediaId(_ kitsuId: Int?) -> EpisodePlaybackContext {
        EpisodePlaybackContext(
            localSeasonNumber: localSeasonNumber,
            localEpisodeNumber: localEpisodeNumber,
            anilistMediaId: anilistMediaId,
            kitsuMediaId: kitsuId ?? kitsuMediaId,
            tmdbSeasonNumber: tmdbSeasonNumber,
            tmdbEpisodeNumber: tmdbEpisodeNumber,
            tmdbEpisodeOffset: tmdbEpisodeOffset,
            animeAbsoluteEpisodeNumber: animeAbsoluteEpisodeNumber,
            animeSeasonEpisodeCount: animeSeasonEpisodeCount,
            isSpecial: isSpecial,
            titleOnlySearch: titleOnlySearch
        )
    }
}

enum MediaInfo {
    case movie(id: Int, title: String, posterURL: String? = nil, isAnime: Bool = false)
    case episode(showId: Int, seasonNumber: Int, episodeNumber: Int, showTitle: String? = nil, showPosterURL: String? = nil, isAnime: Bool = false)
}
