import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#endif

enum LocalNotificationNavigationKind: String, Codable, Sendable {
    case episode
    case batch
    case season
    case scheduleFallback
}

enum LocalNotificationTMDBMediaType: String, Codable, Sendable {
    case tv
    case movie
}

struct LocalNotificationNavigationTarget: Identifiable, Equatable, Sendable {
    let id: String
    let requestIdentifier: String
    let kind: LocalNotificationNavigationKind
    let source: LocalNotificationMediaSource?
    let tmdbID: Int?
    let tmdbMediaType: LocalNotificationTMDBMediaType?
    let sourceMediaID: Int?
    let mediaTitle: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    let airingAt: Date?
    let seasonLabel: String?
    let isAnimeSpecial: Bool
}

struct LocalNotificationHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let requestIdentifier: String
    var deliveredAt: Date
    var title: String
    var subtitle: String
    var body: String
    var categoryIdentifier: String
    var kind: LocalNotificationNavigationKind
    var source: LocalNotificationMediaSource?
    var tmdbID: Int?
    var tmdbMediaType: LocalNotificationTMDBMediaType?
    var sourceMediaID: Int?
    var mediaTitle: String
    var seasonNumber: Int?
    var episodeNumber: Int?
    var airingAt: Date?
    var seasonLabel: String?
    var isAnimeSpecial: Bool
    var wasOpened: Bool

    var navigationTarget: LocalNotificationNavigationTarget {
        LocalNotificationNavigationTarget(
            id: "history-\(id)-\(UUID().uuidString)",
            requestIdentifier: requestIdentifier,
            kind: kind,
            source: source,
            tmdbID: tmdbID,
            tmdbMediaType: tmdbMediaType,
            sourceMediaID: sourceMediaID,
            mediaTitle: mediaTitle,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            airingAt: airingAt,
            seasonLabel: seasonLabel,
            isAnimeSpecial: isAnimeSpecial
        )
    }
}

struct LocalNotificationHistoryCursor: Equatable, Sendable {
    let deliveredAt: Date
    let id: String
}

struct LocalNotificationHistoryPage: Sendable {
    let entries: [LocalNotificationHistoryEntry]
    let nextCursor: LocalNotificationHistoryCursor?
    let hasMore: Bool
    let totalCount: Int
}

private struct LocalNotificationHistoryMutationOutcome: Sendable {
    let changed: Bool
    let persisted: Bool
}

private actor LocalNotificationHistoryStore {
    static let shared = LocalNotificationHistoryStore()

    private struct Archive: Codable {
        var version = 1
        var entries: [LocalNotificationHistoryEntry] = []
        var clearedThrough: Date?
        var deletedEntryDates: [String: Date] = [:]

        private enum CodingKeys: String, CodingKey {
            case version, entries, clearedThrough, deletedEntryDates
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            entries = try container.decodeIfPresent([LocalNotificationHistoryEntry].self, forKey: .entries) ?? []
            clearedThrough = try container.decodeIfPresent(Date.self, forKey: .clearedThrough)
            deletedEntryDates = try container.decodeIfPresent([String: Date].self, forKey: .deletedEntryDates) ?? [:]
        }
    }

    private let maximumEntryCount = 1_000
    private let maximumTombstoneCount = 2_000
    private var archive: Archive?

    func record(_ incoming: [LocalNotificationHistoryEntry]) -> LocalNotificationHistoryMutationOutcome {
        guard !incoming.isEmpty else {
            return LocalNotificationHistoryMutationOutcome(changed: false, persisted: true)
        }
        var value = loadArchive()
        var changed = false

        for entry in incoming {
            if let clearedThrough = value.clearedThrough, entry.deliveredAt <= clearedThrough {
                continue
            }
            guard value.deletedEntryDates[entry.id] == nil else { continue }

            if let index = value.entries.firstIndex(where: { $0.id == entry.id }) {
                var merged = entry
                merged.wasOpened = value.entries[index].wasOpened || entry.wasOpened
                if value.entries[index] != merged {
                    value.entries[index] = merged
                    changed = true
                }
            } else {
                value.entries.append(entry)
                changed = true
            }
        }

        guard changed else {
            return LocalNotificationHistoryMutationOutcome(changed: false, persisted: true)
        }
        value.entries.sort(by: Self.isNewer)
        if value.entries.count > maximumEntryCount {
            value.entries.removeLast(value.entries.count - maximumEntryCount)
        }
        guard persist(value) else {
            return LocalNotificationHistoryMutationOutcome(changed: false, persisted: false)
        }
        archive = value
        return LocalNotificationHistoryMutationOutcome(changed: true, persisted: true)
    }

    func page(after cursor: LocalNotificationHistoryCursor?, limit: Int) -> LocalNotificationHistoryPage {
        let value = loadArchive()
        let ordered = value.entries
        let startIndex: Int
        if let cursor,
           let index = ordered.firstIndex(where: { $0.id == cursor.id && $0.deliveredAt == cursor.deliveredAt }) {
            startIndex = ordered.index(after: index)
        } else {
            startIndex = 0
        }
        let safeLimit = max(1, min(limit, 100))
        let endIndex = min(ordered.count, startIndex + safeLimit)
        let entries = startIndex < endIndex ? Array(ordered[startIndex..<endIndex]) : []
        let hasMore = endIndex < ordered.count
        let nextCursor = hasMore ? entries.last.map {
            LocalNotificationHistoryCursor(deliveredAt: $0.deliveredAt, id: $0.id)
        } : nil
        return LocalNotificationHistoryPage(
            entries: entries,
            nextCursor: nextCursor,
            hasMore: hasMore,
            totalCount: ordered.count
        )
    }

    func count() -> Int {
        loadArchive().entries.count
    }

    func delete(id: String) -> LocalNotificationHistoryMutationOutcome {
        var value = loadArchive()
        let previousCount = value.entries.count
        value.entries.removeAll { $0.id == id }
        value.deletedEntryDates[id] = Date()
        trimTombstones(in: &value)
        guard persist(value) else {
            return LocalNotificationHistoryMutationOutcome(changed: false, persisted: false)
        }
        archive = value
        return LocalNotificationHistoryMutationOutcome(
            changed: value.entries.count != previousCount,
            persisted: true
        )
    }

    func clear(through cutoff: Date) -> LocalNotificationHistoryMutationOutcome {
        var value = loadArchive()
        let previousCount = value.entries.count
        value.entries.removeAll { $0.deliveredAt <= cutoff }
        value.clearedThrough = max(value.clearedThrough ?? .distantPast, cutoff)
        guard persist(value) else {
            return LocalNotificationHistoryMutationOutcome(changed: false, persisted: false)
        }
        archive = value
        return LocalNotificationHistoryMutationOutcome(
            changed: value.entries.count != previousCount,
            persisted: true
        )
    }

    private func loadArchive() -> Archive {
        if let archive { return archive }
        let loaded: Archive
        if let data = try? Data(contentsOf: archiveURL),
           let decoded = try? JSONDecoder().decode(Archive.self, from: data),
           decoded.version == 1 {
            loaded = decoded
        } else {
            loaded = Archive()
        }
        var sanitized = loaded
        sanitized.entries.sort(by: Self.isNewer)
        if sanitized.entries.count > maximumEntryCount {
            sanitized.entries.removeLast(sanitized.entries.count - maximumEntryCount)
        }
        trimTombstones(in: &sanitized)
        archive = sanitized
        return sanitized
    }

    private func persist(_ value: Archive) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            let directory = archiveURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: archiveURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private var archiveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Eclipse", isDirectory: true)
            .appendingPathComponent("LocalNotificationHistory-v1.json", isDirectory: false)
    }

    private func trimTombstones(in value: inout Archive) {
        guard value.deletedEntryDates.count > maximumTombstoneCount else { return }
        let retained = value.deletedEntryDates
            .sorted { $0.value > $1.value }
            .prefix(maximumTombstoneCount)
        value.deletedEntryDates = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
    }

    private static func isNewer(_ lhs: LocalNotificationHistoryEntry, _ rhs: LocalNotificationHistoryEntry) -> Bool {
        if lhs.deliveredAt != rhs.deliveredAt { return lhs.deliveredAt > rhs.deliveredAt }
        return lhs.id > rhs.id
    }
}

enum LocalEpisodeNotificationState: Equatable {
    case off
    case explicit
    case followed
    case muted
    case unavailable

    var isEffectivelyEnabled: Bool {
        self == .explicit || self == .followed
    }
}

enum LocalNotificationActionResult: Equatable {
    case enabled
    case disabled
    case permissionDenied
    case unavailable(String)
    case failed(String)
}

struct LocalNotificationNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    var offersSettings = false

    static func from(_ result: LocalNotificationActionResult) -> LocalNotificationNotice? {
        switch result {
        case .enabled, .disabled:
            return nil
        case .permissionDenied:
            return LocalNotificationNotice(
                title: "Notifications Are Off",
                message: "Allow notifications for Eclipse in iOS Settings to receive local reminders.",
                offersSettings: true
            )
        case .unavailable(let message):
            return LocalNotificationNotice(title: "Reminder Unavailable", message: message)
        case .failed(let message):
            return LocalNotificationNotice(title: "Couldn’t Update Reminder", message: message)
        }
    }
}

enum EpisodeNotificationLeadTime: Int, CaseIterable, Identifiable {
    case atAirtime = 0
    case fifteenMinutes = 900
    case oneHour = 3600
    case oneDay = 86400

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .atAirtime: return "At airtime"
        case .fifteenMinutes: return "15 minutes before"
        case .oneHour: return "1 hour before"
        case .oneDay: return "1 day before"
        }
    }
}

enum SeasonNotificationLeadTime: Int, CaseIterable, Identifiable {
    case atPremiere = 0
    case oneDay = 86400
    case oneWeek = 604800

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .atPremiere: return "On premiere day"
        case .oneDay: return "1 day before"
        case .oneWeek: return "1 week before"
        }
    }
}

struct LocalSeasonPremiere: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var seasonLabel: String
    var premiereDate: Date?
    var hasExactTime: Bool
    var seasonNumber: Int?
    var sourceMediaID: Int?

    init(
        id: String,
        title: String,
        seasonLabel: String,
        premiereDate: Date?,
        hasExactTime: Bool,
        seasonNumber: Int? = nil,
        sourceMediaID: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.seasonLabel = seasonLabel
        self.premiereDate = premiereDate
        self.hasExactTime = hasExactTime
        self.seasonNumber = seasonNumber
        self.sourceMediaID = sourceMediaID
    }
}

struct LocalMediaNotificationSubscription: Codable, Identifiable, Equatable {
    let id: String
    var source: LocalNotificationMediaSource
    var tmdbID: Int
    var title: String
    var titleAliases: [String]

    var animeMediaIDs: Set<Int>

    var animeSpecialMediaIDs: Set<Int>
    var knownWesternSeasonIDs: Set<Int>
    var episodeNotifications: Bool
    var futureSeasonNotifications: Bool
    var mutedEpisodeKeys: Set<String>
    var mutedEpisodeExpirations: [String: Date]
    var seasonPremieres: [LocalSeasonPremiere]
    var hasCompleteAnimeSeasonBaseline: Bool
    var hasCompleteWesternSeasonBaseline: Bool
    var dateAdded: Date

    init(
        id: String,
        source: LocalNotificationMediaSource,
        tmdbID: Int,
        title: String,
        titleAliases: [String],
        animeMediaIDs: Set<Int>,
        animeSpecialMediaIDs: Set<Int> = [],
        knownWesternSeasonIDs: Set<Int>,
        episodeNotifications: Bool,
        futureSeasonNotifications: Bool,
        mutedEpisodeKeys: Set<String> = [],
        mutedEpisodeExpirations: [String: Date] = [:],
        seasonPremieres: [LocalSeasonPremiere] = [],
        hasCompleteAnimeSeasonBaseline: Bool = false,
        hasCompleteWesternSeasonBaseline: Bool = false,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.tmdbID = tmdbID
        self.title = title
        self.titleAliases = titleAliases
        self.animeMediaIDs = animeMediaIDs
        self.animeSpecialMediaIDs = animeSpecialMediaIDs
        self.knownWesternSeasonIDs = knownWesternSeasonIDs
        self.episodeNotifications = episodeNotifications
        self.futureSeasonNotifications = futureSeasonNotifications
        self.mutedEpisodeKeys = mutedEpisodeKeys
        self.mutedEpisodeExpirations = mutedEpisodeExpirations
        self.seasonPremieres = seasonPremieres
        self.hasCompleteAnimeSeasonBaseline = hasCompleteAnimeSeasonBaseline
        self.hasCompleteWesternSeasonBaseline = hasCompleteWesternSeasonBaseline
        self.dateAdded = dateAdded
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, tmdbID, title, titleAliases, animeMediaIDs, animeSpecialMediaIDs, knownWesternSeasonIDs
        case episodeNotifications, futureSeasonNotifications, mutedEpisodeKeys, mutedEpisodeExpirations, seasonPremieres
        case hasCompleteAnimeSeasonBaseline, hasCompleteWesternSeasonBaseline, dateAdded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(LocalNotificationMediaSource.self, forKey: .source)
        tmdbID = try container.decode(Int.self, forKey: .tmdbID)
        title = try container.decode(String.self, forKey: .title)
        titleAliases = try container.decodeIfPresent([String].self, forKey: .titleAliases) ?? [title]
        animeMediaIDs = try container.decodeIfPresent(Set<Int>.self, forKey: .animeMediaIDs) ?? []
        animeSpecialMediaIDs = try container.decodeIfPresent(Set<Int>.self, forKey: .animeSpecialMediaIDs) ?? []
        knownWesternSeasonIDs = try container.decodeIfPresent(Set<Int>.self, forKey: .knownWesternSeasonIDs) ?? []
        episodeNotifications = try container.decodeIfPresent(Bool.self, forKey: .episodeNotifications) ?? true
        futureSeasonNotifications = try container.decodeIfPresent(Bool.self, forKey: .futureSeasonNotifications) ?? false
        mutedEpisodeKeys = try container.decodeIfPresent(Set<String>.self, forKey: .mutedEpisodeKeys) ?? []
        mutedEpisodeExpirations = try container.decodeIfPresent([String: Date].self, forKey: .mutedEpisodeExpirations) ?? [:]
        seasonPremieres = try container.decodeIfPresent([LocalSeasonPremiere].self, forKey: .seasonPremieres) ?? []
        hasCompleteAnimeSeasonBaseline = try container.decodeIfPresent(Bool.self, forKey: .hasCompleteAnimeSeasonBaseline) ?? false
        hasCompleteWesternSeasonBaseline = try container.decodeIfPresent(Bool.self, forKey: .hasCompleteWesternSeasonBaseline) ?? false
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
    }
}

struct LocalEpisodeNotificationReminder: Codable, Identifiable, Equatable {
    let id: String
    var source: LocalNotificationMediaSource
    var sourceMediaID: Int
    var tmdbID: Int?
    var tmdbMediaType: LocalNotificationTMDBMediaType?
    var title: String
    var season: Int?
    var episode: Int
    var airingAt: Date
    var hasKnownAiringTime: Bool
    var isStreamingRelease: Bool
    var isAnimeSpecial: Bool

    init(
        id: String,
        source: LocalNotificationMediaSource,
        sourceMediaID: Int,
        tmdbID: Int?,
        tmdbMediaType: LocalNotificationTMDBMediaType?,
        title: String,
        season: Int?,
        episode: Int,
        airingAt: Date,
        hasKnownAiringTime: Bool,
        isStreamingRelease: Bool,
        isAnimeSpecial: Bool
    ) {
        self.id = id
        self.source = source
        self.sourceMediaID = sourceMediaID
        self.tmdbID = tmdbID
        self.tmdbMediaType = tmdbMediaType
        self.title = title
        self.season = season
        self.episode = episode
        self.airingAt = airingAt
        self.hasKnownAiringTime = hasKnownAiringTime
        self.isStreamingRelease = isStreamingRelease
        self.isAnimeSpecial = isAnimeSpecial
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, sourceMediaID, tmdbID, tmdbMediaType, title, season, episode
        case airingAt, hasKnownAiringTime, isStreamingRelease, isAnimeSpecial
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(LocalNotificationMediaSource.self, forKey: .source)
        sourceMediaID = try container.decode(Int.self, forKey: .sourceMediaID)
        tmdbID = try container.decodeIfPresent(Int.self, forKey: .tmdbID)
        tmdbMediaType = try container.decodeIfPresent(LocalNotificationTMDBMediaType.self, forKey: .tmdbMediaType)
        title = try container.decode(String.self, forKey: .title)
        season = try container.decodeIfPresent(Int.self, forKey: .season)
        episode = try container.decode(Int.self, forKey: .episode)
        airingAt = try container.decode(Date.self, forKey: .airingAt)
        hasKnownAiringTime = try container.decode(Bool.self, forKey: .hasKnownAiringTime)
        isStreamingRelease = try container.decodeIfPresent(Bool.self, forKey: .isStreamingRelease) ?? false
        isAnimeSpecial = try container.decodeIfPresent(Bool.self, forKey: .isAnimeSpecial) ?? false
    }
}

@MainActor
final class LocalNotificationManager: NSObject, ObservableObject {
    static let shared = LocalNotificationManager()

    nonisolated static let subscriptionsStorageKey = "localNotificationSubscriptions"
    nonisolated static let episodeRemindersStorageKey = "localNotificationEpisodeReminders"
    nonisolated static let episodeLeadTimeKey = "localNotificationEpisodeLeadTime"
    nonisolated static let seasonLeadTimeKey = "localNotificationSeasonLeadTime"
    nonisolated static let includeAnimeSpecialsKey = "localNotificationIncludeAnimeSpecials"
    nonisolated private static let futureMetadataRefreshDatesStorageKey = "localNotificationFutureMetadataRefreshDates"

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var subscriptions: [LocalMediaNotificationSubscription] = []
    @Published private(set) var episodeReminders: [LocalEpisodeNotificationReminder] = []
    @Published private(set) var managedPendingRequestCount = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var notificationHistoryCount = 0
    @Published private(set) var notificationHistoryRevision: UInt = 0

    private let center = UNUserNotificationCenter.current()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let managedPrefix = "eclipse.local."
    private let maximumManagedPendingRequests = 48
    private let futureMetadataRefreshInterval: TimeInterval = 6 * 60 * 60
    private let futureMetadataFailureRetryInterval: TimeInterval = 60
    private var futureMetadataLastSuccessfulRefreshDates: [String: Date] = [:]
    private var futureMetadataLastAttemptDates: [String: Date] = [:]
    private var futureMetadataRefreshesInFlight = Set<String>()
    private var futureMetadataPendingBaselineRefreshes = Set<String>()
    private var pendingScheduleRefresh = false
    private var pendingForcedScheduleRefresh = false
    private var isConfigured = false
    private var lastScheduleEntries: [ScheduleEntry] = []
    private var lastLoadedSources: Set<ScheduleSource> = []
    private var pendingNavigationTarget: LocalNotificationNavigationTarget?
    private var pendingNavigationSceneSessionIdentifier: String?
    private var notificationStateRevision: UInt = 0

    private var settingsStore: UserDefaults = ProfileSettingsStore.active

    private override init() {
        super.init()
        UserDefaults.standard.register(defaults: [
            Self.episodeLeadTimeKey: EpisodeNotificationLeadTime.atAirtime.rawValue,
            Self.seasonLeadTimeKey: SeasonNotificationLeadTime.oneDay.rawValue,
            Self.includeAnimeSpecialsKey: false
        ])
        loadPersistedState()
        loadFutureMetadataRefreshDates()
    }

    var authorizationDisplayName: String {
        switch authorizationStatus {
        case .authorized: return "Allowed"
        case .provisional: return "Quietly allowed"
        case .ephemeral: return "Temporarily allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not enabled"
        @unknown default: return "Unknown"
        }
    }

    var canScheduleNotifications: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    var hasNotificationSelections: Bool {
        !subscriptions.isEmpty || !episodeReminders.isEmpty
    }

    var hasPendingScheduleNavigation: Bool {
        pendingNavigationTarget != nil
    }

    func shouldHandlePendingNavigation(inSceneSessionIdentifier sceneSessionIdentifier: String?) -> Bool {
        guard pendingNavigationTarget != nil else { return false }
        if let pendingNavigationSceneSessionIdentifier {
            return pendingNavigationSceneSessionIdentifier == sceneSessionIdentifier
        }
        if let sceneSessionIdentifier {
            pendingNavigationSceneSessionIdentifier = sceneSessionIdentifier
            return true
        }
#if os(iOS)

        if UIDevice.current.userInterfaceIdiom == .pad { return false }
#endif
        return true
    }

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "ECLIPSE_EPISODE",
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: "ECLIPSE_SEASON",
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ])
        Task {
            await refreshAuthorizationStatus()
            await refreshPendingRequestCount()
            await syncDeliveredNotificationHistory()
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await notificationSettings()
        authorizationStatus = settings.authorizationStatus
        pruneExpiredEpisodeReminders()
    }

    func requestAuthorization() async -> LocalNotificationActionResult {
        await refreshAuthorizationStatus()
        if canScheduleNotifications {
            return .enabled
        }
        if authorizationStatus == .denied {
            return .permissionDenied
        }

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorizationStatus()
            if granted || canScheduleNotifications {

                await refreshSchedulesIfNeeded()
                return .enabled
            }
            return .permissionDenied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func subscription(
        source: LocalNotificationMediaSource,
        tmdbID: Int
    ) -> LocalMediaNotificationSubscription? {
        subscriptions.first { $0.source == source && $0.tmdbID == tmdbID }
    }

    func reconcileAnimeStructuralRoles(
        tmdbID: Int,
        regularMediaIDs: Set<Int>,
        specialMediaIDs: Set<Int>,
        canonicalProviderIDByStoredID: [Int: Int] = [:]
    ) {
        func canonical(_ id: Int) -> Int {
            canonicalProviderIDByStoredID[id] ?? id
        }

        var changed = false
        for index in episodeReminders.indices
        where episodeReminders[index].source == .anime
            && episodeReminders[index].tmdbID == tmdbID {
            let storedID = episodeReminders[index].sourceMediaID
            let canonicalID = canonical(storedID)
            if canonicalID != storedID {
                episodeReminders[index].sourceMediaID = canonicalID
                changed = true
            }
            let shouldBeSpecial = specialMediaIDs.contains(storedID)
                || specialMediaIDs.contains(canonicalID)
            let shouldBeRegular = regularMediaIDs.contains(storedID)
                || regularMediaIDs.contains(canonicalID)
            if (shouldBeSpecial || shouldBeRegular),
               episodeReminders[index].isAnimeSpecial != shouldBeSpecial {
                episodeReminders[index].isAnimeSpecial = shouldBeSpecial
                changed = true
            }
        }

        if let index = subscriptions.firstIndex(where: {
            $0.source == .anime && $0.tmdbID == tmdbID
        }) {
            var subscription = subscriptions[index]
            let oldSubscription = subscription
            subscription.animeMediaIDs.subtract(specialMediaIDs)
            subscription.animeSpecialMediaIDs.subtract(regularMediaIDs)
            subscription.animeMediaIDs.formUnion(regularMediaIDs)
            subscription.animeSpecialMediaIDs.formUnion(specialMediaIDs)
            for premiereIndex in subscription.seasonPremieres.indices {
                guard let storedID = subscription.seasonPremieres[premiereIndex].sourceMediaID else {
                    continue
                }
                let canonicalID = canonical(storedID)
                if canonicalID != storedID {
                    subscription.seasonPremieres[premiereIndex].sourceMediaID = canonicalID
                }
            }
            if subscription != oldSubscription {
                subscriptions[index] = subscription
                changed = true
            }
        }

        guard changed else { return }
        persistState()
        Task { @MainActor in
            await reconcileScheduleEntries(lastScheduleEntries, refreshedSources: [])
        }
    }

    func episodeState(for entry: ScheduleEntry) -> LocalEpisodeNotificationState {
        let explicitKey = explicitEpisodeKey(entry)
        if episodeReminders.contains(where: { $0.id == explicitKey && $0.airingAt > Date() }) {
            return .explicit
        }
        guard entry.hasKnownAiringTime, entry.airingAt > Date() else {
            return .unavailable
        }

        if isWithinAutomaticEpisodeNotificationWindow(entry),
           let followed = matchingSubscription(for: entry), followed.episodeNotifications {
            let key = subscriptionEpisodeKey(entry, subscriptionID: followed.id)
            return followed.mutedEpisodeKeys.contains(key) ? .muted : .followed
        }
        return .off
    }

    func toggleEpisodeReminder(for entry: ScheduleEntry) async -> LocalNotificationActionResult {
        let explicitKey = explicitEpisodeKey(entry)
        if let explicitReminder = episodeReminders.first(where: { $0.id == explicitKey }) {
            let confirmedAiringAt = entry.hasKnownAiringTime
                ? entry.airingAt
                : explicitReminder.airingAt
            if confirmedAiringAt > Date(),
               isWithinAutomaticEpisodeNotificationWindow(confirmedAiringAt),
               var followed = matchingSubscription(for: entry),
               followed.episodeNotifications,
               let index = subscriptions.firstIndex(where: { $0.id == followed.id }) {
                let followedKey = subscriptionEpisodeKey(entry, subscriptionID: followed.id)
                followed.mutedEpisodeKeys.insert(followedKey)
                followed.mutedEpisodeExpirations[followedKey] = confirmedAiringAt
                    .addingTimeInterval(24 * 60 * 60)
                subscriptions[index] = followed
            }
            episodeReminders.removeAll { $0.id == explicitKey }
            persistState()
            center.removePendingNotificationRequests(
                withIdentifiers: [explicitEpisodeRequestIdentifier(explicitKey)]
            )
            await reconcileScheduleEntries(lastScheduleEntries, refreshedSources: [])
            return .disabled
        }
        guard entry.hasKnownAiringTime else {
            return .unavailable("This episode does not have a confirmed airtime yet.")
        }
        guard entry.airingAt > Date() else {
            return .unavailable("This episode’s scheduled airtime has already passed.")
        }

        if isWithinAutomaticEpisodeNotificationWindow(entry),
           var followed = matchingSubscription(for: entry), followed.episodeNotifications,
           let index = subscriptions.firstIndex(where: { $0.id == followed.id }) {
            let key = subscriptionEpisodeKey(entry, subscriptionID: followed.id)
            if followed.mutedEpisodeKeys.contains(key) {
                followed.mutedEpisodeKeys.remove(key)
                followed.mutedEpisodeExpirations.removeValue(forKey: key)
                subscriptions[index] = followed
                persistState()
                await rebuildAfterFollowedEpisodeToggle(entry, subscription: followed)
                return .enabled
            }
            followed.mutedEpisodeKeys.insert(key)
            followed.mutedEpisodeExpirations[key] = mutedEpisodeExpiration(for: entry)
            subscriptions[index] = followed
            persistState()
            await rebuildAfterFollowedEpisodeToggle(entry, subscription: followed)
            return .disabled
        }

        let key = explicitKey

        let permission = await ensureAuthorization()
        guard permission == .enabled else { return permission }

        guard !episodeReminders.contains(where: { $0.id == key }) else { return .enabled }

        if var followed = matchingSubscription(for: entry),
           let index = subscriptions.firstIndex(where: { $0.id == followed.id }) {
            let followedKey = subscriptionEpisodeKey(entry, subscriptionID: followed.id)
            if followed.mutedEpisodeKeys.remove(followedKey) != nil {
                followed.mutedEpisodeExpirations.removeValue(forKey: followedKey)
                subscriptions[index] = followed
            }
        }

        episodeReminders.append(LocalEpisodeNotificationReminder(
            id: key,
            source: localSource(for: entry.source),
            sourceMediaID: entry.sourceMediaId,
            tmdbID: entry.tmdbId,
            tmdbMediaType: entry.tmdbId == nil ? nil : .tv,
            title: entry.title,
            season: entry.season,
            episode: entry.episode,
            airingAt: entry.airingAt,
            hasKnownAiringTime: entry.hasKnownAiringTime,
            isStreamingRelease: entry.isStreamingRelease,
            isAnimeSpecial: isAnimeSpecial(
                entry,
                subscription: matchingSubscription(for: entry)
            )
        ))
        sortAndPersistState()
        mergeScheduleEntry(entry)
        await reconcileScheduleEntries([], refreshedSources: [])
        return .enabled
    }

    private func isWithinAutomaticEpisodeNotificationWindow(_ entry: ScheduleEntry) -> Bool {
        isWithinAutomaticEpisodeNotificationWindow(entry.airingAt)
    }

    private func isWithinAutomaticEpisodeNotificationWindow(_ airingAt: Date) -> Bool {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(
            byAdding: .day,
            value: ScheduleWindow.current.rawValue,
            to: start
        ) else {
            return false
        }
        return airingAt >= start && airingAt < end
    }

    private func mutedEpisodeExpiration(for entry: ScheduleEntry) -> Date {
        entry.airingAt.addingTimeInterval(24 * 60 * 60)
    }

    private func refreshMutedEpisodeExpirations(from entries: [ScheduleEntry]) {
        var changed = false
        let now = Date()
        var updatedSubscriptions = subscriptions

        for index in updatedSubscriptions.indices {
            var subscription = updatedSubscriptions[index]
            var subscriptionChanged = false
            let expiredKeys = subscription.mutedEpisodeExpirations.compactMap { key, expiration in
                expiration <= now ? key : nil
            }
            for key in expiredKeys {
                subscription.mutedEpisodeKeys.remove(key)
                subscription.mutedEpisodeExpirations.removeValue(forKey: key)
                subscriptionChanged = true
            }
            let orphanedExpirationKeys = subscription.mutedEpisodeExpirations.keys.filter {
                !subscription.mutedEpisodeKeys.contains($0)
            }
            for key in orphanedExpirationKeys {
                subscription.mutedEpisodeExpirations.removeValue(forKey: key)
                subscriptionChanged = true
            }

            if !subscription.mutedEpisodeKeys.isEmpty {
                for entry in entries where matches(entry, subscription: subscription) {
                    let key = subscriptionEpisodeKey(entry, subscriptionID: subscription.id)
                    guard subscription.mutedEpisodeKeys.contains(key) else { continue }
                    let expiration = mutedEpisodeExpiration(for: entry)
                    if subscription.mutedEpisodeExpirations[key] != expiration {
                        subscription.mutedEpisodeExpirations[key] = expiration
                        subscriptionChanged = true
                    }
                }
            }
            if subscriptionChanged {
                updatedSubscriptions[index] = subscription
                changed = true
            }
        }

        if changed {
            subscriptions = updatedSubscriptions
            persistState()
        }
    }

    func updateMediaSubscription(
        source: LocalNotificationMediaSource,
        tmdbID: Int,
        title: String,
        titleAliases: [String],
        animeMediaIDs: Set<Int>,
        animeSpecialMediaIDs: Set<Int> = [],
        westernSeasonIDs: Set<Int>,
        episodeNotifications: Bool,
        futureSeasonNotifications: Bool
    ) async -> LocalNotificationActionResult {
        let id = subscriptionID(source: source, tmdbID: tmdbID)
        var existing = subscriptions.first(where: { $0.id == id })
        var isTurningOnEpisodes = episodeNotifications && existing?.episodeNotifications != true
        var isTurningOffEpisodes = !episodeNotifications && existing?.episodeNotifications == true
        var isTurningOnFutureSeasons = futureSeasonNotifications && existing?.futureSeasonNotifications != true
        var isTurningOffFutureSeasons = !futureSeasonNotifications && existing?.futureSeasonNotifications == true

        if source == .anime, futureSeasonNotifications {
            let knownIDs = animeMediaIDs.union(existing?.animeMediaIDs ?? [])
            guard knownIDs.contains(where: { $0 > 0 }) else {
                return .unavailable(
                    "Future-season checks need an AniList identity. Existing confirmed episode reminders are kept, but estimated MyAnimeList schedule rows cannot create new alerts."
                )
            }
        }

        if isTurningOnEpisodes || isTurningOnFutureSeasons {
            let permission = await ensureAuthorization()
            guard permission == .enabled else { return permission }

            existing = subscriptions.first(where: { $0.id == id })
            isTurningOnEpisodes = episodeNotifications && existing?.episodeNotifications != true
            isTurningOffEpisodes = !episodeNotifications && existing?.episodeNotifications == true
            isTurningOnFutureSeasons = futureSeasonNotifications && existing?.futureSeasonNotifications != true
            isTurningOffFutureSeasons = !futureSeasonNotifications && existing?.futureSeasonNotifications == true
        }

        if !episodeNotifications && !futureSeasonNotifications {
            subscriptions.removeAll { $0.id == id }
            removeFutureMetadataRefreshState(for: id)
            persistState()
            await removeManagedRequests(containing: ".follow.\(id).", removeDelivered: true)
            return .disabled
        }

        var subscription = existing ?? LocalMediaNotificationSubscription(
            id: id,
            source: source,
            tmdbID: tmdbID,
            title: title,
            titleAliases: titleAliases,
            animeMediaIDs: animeMediaIDs,
            animeSpecialMediaIDs: animeSpecialMediaIDs,
            knownWesternSeasonIDs: westernSeasonIDs,
            episodeNotifications: episodeNotifications,
            futureSeasonNotifications: futureSeasonNotifications
        )
        subscription.title = title
        subscription.titleAliases = normalizedAliases(titleAliases + [title] + subscription.titleAliases)
        subscription.animeMediaIDs.subtract(animeSpecialMediaIDs)
        subscription.animeSpecialMediaIDs.subtract(animeMediaIDs)
        subscription.animeMediaIDs.formUnion(animeMediaIDs)
        subscription.animeSpecialMediaIDs.formUnion(animeSpecialMediaIDs)
        subscription.knownWesternSeasonIDs.formUnion(westernSeasonIDs)
        subscription.episodeNotifications = episodeNotifications
        subscription.futureSeasonNotifications = futureSeasonNotifications
        if isTurningOnFutureSeasons {
            switch source {
            case .anime:
                subscription.hasCompleteAnimeSeasonBaseline = false
            case .western:
                subscription.hasCompleteWesternSeasonBaseline = false
            }
        }

        if let index = subscriptions.firstIndex(where: { $0.id == id }) {
            subscriptions[index] = subscription
        } else {
            subscriptions.append(subscription)
        }
        sortAndPersistState()

        if !futureSeasonNotifications && !(source == .anime && episodeNotifications) {
            removeFutureMetadataRefreshState(for: id)
        }

        if isTurningOffEpisodes {
            await removeManagedRequests(
                containing: ".episode.\(source.rawValue).follow.\(id).",
                removeDelivered: false
            )
        }
        if isTurningOffFutureSeasons {
            await removeManagedRequests(
                containing: ".season.\(source.rawValue).follow.\(id).",
                removeDelivered: false
            )
        }

        if isTurningOnFutureSeasons || (source == .anime && isTurningOnEpisodes) {

            removeFutureMetadataRefreshState(for: id)
            _ = await refreshFutureSeasonMetadataIfNeeded(
                for: id,
                force: true,
                announceNew: false
            )
        }
        if episodeNotifications {
            await reconcileScheduleSourceAfterSelection(source)
        } else {

            await reconcileScheduleEntries([], refreshedSources: [])
        }
        return .enabled
    }

    func removeSubscription(id: String) async {
        subscriptions.removeAll { $0.id == id }
        removeFutureMetadataRefreshState(for: id)
        persistState()
        await removeManagedRequests(containing: ".follow.\(id).", removeDelivered: true)
    }

    func removeEpisodeReminder(id: String) async {
        episodeReminders.removeAll { $0.id == id }
        persistState()
        let requestIdentifier = explicitEpisodeRequestIdentifier(id)
        center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
        await captureAndRemoveDeliveredNotifications(withIdentifiers: [requestIdentifier])
        await reconcileScheduleEntries(lastScheduleEntries, refreshedSources: [])
    }

    func enrichEpisodeReminderTMDBIdentity(
        for entry: ScheduleEntry,
        result: TMDBSearchResult
    ) async {
        guard result.id > 0 else { return }
        let key = explicitEpisodeKey(entry)
        guard let index = episodeReminders.firstIndex(where: { $0.id == key }) else { return }
        let mediaType = LocalNotificationTMDBMediaType(rawValue: result.mediaType.lowercased())
        guard episodeReminders[index].tmdbID != result.id
                || episodeReminders[index].tmdbMediaType != mediaType else { return }
        episodeReminders[index].tmdbID = result.id
        episodeReminders[index].tmdbMediaType = mediaType
        sortAndPersistState()
        mergeScheduleEntry(entry)
        await reconcileScheduleEntries(lastScheduleEntries, refreshedSources: [])
    }

    func clearAllSelections() async {
        subscriptions.removeAll()
        episodeReminders.removeAll()
        futureMetadataLastSuccessfulRefreshDates.removeAll()
        futureMetadataLastAttemptDates.removeAll()
        futureMetadataPendingBaselineRefreshes.removeAll()
        persistFutureMetadataRefreshDates()
        persistState()
        let pending = await pendingNotificationRequests()
        let identifiers = pending.map(\.identifier).filter { $0.hasPrefix(managedPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        let delivered = await deliveredNotifications()
        let deliveredIdentifiers = delivered.map(\.request.identifier).filter { $0.hasPrefix(managedPrefix) }
        await recordObservedNotifications(delivered, wasOpened: false)
        center.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        await refreshPendingRequestCount()
    }

    func reloadPersistedSelectionsAfterRestore() async {

        loadPersistedState(writeCanonicalizedState: false)
        await refreshAuthorizationStatus()

        let pending = await pendingNotificationRequests()
        let managedIdentifiers = pending.map(\.identifier).filter { $0.hasPrefix(managedPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: managedIdentifiers)
        if canScheduleNotifications, hasNotificationSelections {
            await refreshSchedulesIfNeeded(force: true)
        } else {
            await refreshPendingRequestCount()
        }
    }

    func takePendingNavigationTarget(
        forSceneSessionIdentifier sceneSessionIdentifier: String?
    ) -> LocalNotificationNavigationTarget? {
        guard shouldHandlePendingNavigation(
            inSceneSessionIdentifier: sceneSessionIdentifier
        ) else { return nil }
        defer {
            pendingNavigationTarget = nil
            pendingNavigationSceneSessionIdentifier = nil
        }
        return pendingNavigationTarget
    }

    func notificationHistoryPage(
        after cursor: LocalNotificationHistoryCursor?,
        limit: Int = 40
    ) async -> LocalNotificationHistoryPage {
        await LocalNotificationHistoryStore.shared.page(after: cursor, limit: limit)
    }

    func syncDeliveredNotificationHistory() async {
        let delivered = await deliveredNotifications().filter {
            $0.request.identifier.hasPrefix(managedPrefix)
        }
        guard !delivered.isEmpty else {
            let count = await LocalNotificationHistoryStore.shared.count()
            if count != notificationHistoryCount {
                notificationHistoryCount = count
                notificationHistoryRevision &+= 1
            }
            return
        }
        let entries = delivered.map {
            Self.historyEntry(from: $0, wasOpened: false)
        }
        let outcome = await LocalNotificationHistoryStore.shared.record(entries)
        await applyHistoryMutationOutcome(outcome, operation: "record delivered notifications")
    }

    @discardableResult
    func deleteNotificationHistoryEntry(_ entry: LocalNotificationHistoryEntry) async -> Bool {
        let outcome = await LocalNotificationHistoryStore.shared.delete(id: entry.id)
        guard outcome.persisted else {
            await applyHistoryMutationOutcome(outcome, operation: "delete a notification history entry")
            return false
        }
        center.removeDeliveredNotifications(withIdentifiers: [entry.requestIdentifier])
        await applyHistoryMutationOutcome(outcome, operation: "delete a notification history entry")
        return true
    }

    @discardableResult
    func clearNotificationHistory() async -> Bool {
        let cutoff = Date()
        let delivered = await deliveredNotifications()
        let outcome = await LocalNotificationHistoryStore.shared.clear(through: cutoff)
        guard outcome.persisted else {
            await applyHistoryMutationOutcome(outcome, operation: "clear notification history")
            return false
        }
        let identifiers = delivered.compactMap { notification -> String? in
            guard notification.date <= cutoff,
                  notification.request.identifier.hasPrefix(managedPrefix) else { return nil }
            return notification.request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        await applyHistoryMutationOutcome(outcome, operation: "clear notification history")
        return true
    }

    func openNotificationHistoryEntry(
        _ entry: LocalNotificationHistoryEntry,
        sceneSessionIdentifier: String?
    ) {
        pendingNavigationTarget = entry.navigationTarget
        pendingNavigationSceneSessionIdentifier = sceneSessionIdentifier
        NotificationCenter.default.post(name: .openScheduleFromLocalNotification, object: nil)
    }

    func refreshSchedulesIfNeeded(force: Bool = false) async {
        guard hasNotificationSelections else { return }
        if isRefreshing {
            pendingScheduleRefresh = true
            pendingForcedScheduleRefresh = pendingForcedScheduleRefresh || force
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        var nextForce = force
        repeat {
            pendingScheduleRefresh = false
            pendingForcedScheduleRefresh = false
            await performScheduleRefresh(force: nextForce)
            guard pendingScheduleRefresh else { break }
            nextForce = pendingForcedScheduleRefresh
        } while true
    }

    func consumeStartupScheduleSnapshot(_ snapshot: NotificationScheduleSnapshot) async {
        await refreshAuthorizationStatus()
        guard hasNotificationSelections, canScheduleNotifications else { return }
        guard snapshot.dayCount == ScheduleWindow.current.rawValue else {
            await refreshSchedulesIfNeeded()
            return
        }
        await refreshFutureSeasonMetadataIfNeeded(force: false, announceNew: true)
        await reconcileScheduleEntries(
            snapshot.entries,
            successfulSources: snapshot.successfulSources,
            authoritativeSources: snapshot.authoritativeSources,
            coveredDayCount: snapshot.dayCount
        )
    }

    private func performScheduleRefresh(force: Bool) async {
        await refreshAuthorizationStatus()
        guard hasNotificationSelections, canScheduleNotifications else { return }

        let requiredSources = notificationEpisodeScheduleSources
        let snapshot: NotificationScheduleSnapshot
        let requestedDayCount = ScheduleWindow.current.rawValue
        if requiredSources.isEmpty {
            snapshot = NotificationScheduleSnapshot(
                entries: [],
                dayCount: requestedDayCount,
                successfulSources: [],
                authoritativeSources: []
            )
        } else {
            snapshot = await ScheduleViewModel.shared.notificationScheduleSnapshot(
                dayCount: requestedDayCount,
                requiredSources: requiredSources,
                forceRefreshSources: force ? requiredSources : [],
                requireAuthoritativeSources: requiredSources.contains(.anime) ? [.anime] : []
            )
        }
        guard snapshot.dayCount == ScheduleWindow.current.rawValue else {
            pendingScheduleRefresh = true
            return
        }
        await refreshFutureSeasonMetadataIfNeeded(force: force, announceNew: true)
        await reconcileScheduleEntries(
            snapshot.entries,
            successfulSources: snapshot.successfulSources,
            authoritativeSources: snapshot.authoritativeSources,
            coveredDayCount: snapshot.dayCount
        )
    }

    private func reconcileScheduleSourceAfterSelection(_ source: LocalNotificationMediaSource) async {
        let requiredSource = scheduleSource(for: source)
        let requestedDayCount = ScheduleWindow.current.rawValue
        let snapshot = await ScheduleViewModel.shared.notificationScheduleSnapshot(
            dayCount: requestedDayCount,
            requiredSources: [requiredSource],
            requireAuthoritativeSources: source == .anime ? [.anime] : []
        )
        await reconcileScheduleEntries(
            snapshot.entries,
            successfulSources: snapshot.successfulSources,
            authoritativeSources: snapshot.authoritativeSources,
            coveredDayCount: snapshot.dayCount
        )
    }

    private var notificationEpisodeScheduleSources: Set<ScheduleSource> {
        var result = Set(episodeReminders.map { scheduleSource(for: $0.source) })
        for subscription in subscriptions where subscription.episodeNotifications {
            result.insert(scheduleSource(for: subscription.source))
        }
        return result
    }

    func reconcileScheduleEntries(
        _ entries: [ScheduleEntry],
        refreshedSources: Set<ScheduleSource>
    ) async {
        await reconcileScheduleEntries(
            entries,
            successfulSources: refreshedSources,
            authoritativeSources: refreshedSources
        )
    }

    func reconcileScheduleEntries(
        _ entries: [ScheduleEntry],
        successfulSources: Set<ScheduleSource>,
        authoritativeSources: Set<ScheduleSource>,
        coveredDayCount: Int? = nil,
        retainUnrefreshedSourceRequests: Bool = true,
        invalidateExcludedAnimeSpecialRequests: Bool = false
    ) async {
        guard canScheduleNotifications else { return }
        if let coveredDayCount,
           coveredDayCount != ScheduleWindow.current.rawValue {
            await refreshSchedulesIfNeeded()
            return
        }
        var entriesByID: [String: ScheduleEntry] = [:]
        for entry in entries {
            entriesByID[entry.id] = entry
        }
        let incomingEntries = Array(entriesByID.values)
        let successfulLocalSources = Set(successfulSources.map { localSource(for: $0) })
        let refreshedLocalSources = Set(authoritativeSources.map { localSource(for: $0) })
        let successfulIncomingEntries = incomingEntries.filter {
            successfulLocalSources.contains(localSource(for: $0.source))
        }
        let authoritativeIncomingEntries = incomingEntries.filter {
            refreshedLocalSources.contains(localSource(for: $0.source))
        }
        refreshMutedEpisodeExpirations(
            from: lastScheduleEntries + successfulIncomingEntries
        )
        if !refreshedLocalSources.isEmpty {
            lastScheduleEntries.removeAll { refreshedLocalSources.contains(localSource(for: $0.source)) }
            lastScheduleEntries.append(contentsOf: authoritativeIncomingEntries)
            lastLoadedSources.formUnion(authoritativeSources)
        }
        let additiveLocalSources = successfulLocalSources.subtracting(refreshedLocalSources)
        if !additiveLocalSources.isEmpty {
            let additiveEntries = successfulIncomingEntries.filter {
                additiveLocalSources.contains(localSource(for: $0.source))
            }
            let additiveIDs = Set(additiveEntries.map(\.id))
            lastScheduleEntries.removeAll { additiveIDs.contains($0.id) }
            lastScheduleEntries.append(contentsOf: additiveEntries)
        }
        if !refreshedLocalSources.isEmpty || !additiveLocalSources.isEmpty {
            lastScheduleEntries.sort { $0.airingAt < $1.airingAt }
        }

        updateExplicitReminders(from: successfulIncomingEntries)
        let reconciliationRevision = notificationStateRevision
        var desired: [DesiredNotification] = []
        desired.append(contentsOf: explicitReminderNotifications())
        desired.append(contentsOf: followedEpisodeNotifications(from: lastScheduleEntries))
        desired.append(contentsOf: seasonPremiereNotifications())

        desired.sort {
            if $0.fireDate != $1.fireDate { return $0.fireDate < $1.fireDate }
            return $0.priority < $1.priority
        }
        var seenDesiredIDs = Set<String>()
        desired = desired.filter { seenDesiredIDs.insert($0.request.identifier).inserted }
        let pending = await pendingNotificationRequests()
        guard reconciliationRevision == notificationStateRevision else {
            await reconcileScheduleEntries(
                lastScheduleEntries,
                successfulSources: [],
                authoritativeSources: [],
                retainUnrefreshedSourceRequests: retainUnrefreshedSourceRequests,
                invalidateExcludedAnimeSpecialRequests: invalidateExcludedAnimeSpecialRequests
            )
            return
        }
        let failedSourcePending = pending.filter { request in
            if invalidateExcludedAnimeSpecialRequests,
               !settingsStore.bool(forKey: Self.includeAnimeSpecialsKey),
               request.content.userInfo["isAnimeSpecial"] as? Bool == true {
                return false
            }
            guard retainUnrefreshedSourceRequests else { return false }
            guard request.identifier.hasPrefix(managedPrefix),
                  !request.identifier.hasPrefix("\(managedPrefix)announcement.") else { return false }
            if let airingAt = request.content.userInfo["airingAt"] as? TimeInterval,
               !isWithinAutomaticEpisodeNotificationWindow(
                   Date(timeIntervalSince1970: airingAt)
               ) {
                return false
            }
            if request.identifier.contains(".episode.anime.") {
                return !refreshedLocalSources.contains(.anime)
            }
            if request.identifier.contains(".episode.western.") {
                return !refreshedLocalSources.contains(.western)
            }
            return false
        }.sorted { lhs, rhs in
            let lhsDate = lhs.content.userInfo["scheduledFireDate"] as? TimeInterval ?? .greatestFiniteMagnitude
            let rhsDate = rhs.content.userInfo["scheduledFireDate"] as? TimeInterval ?? .greatestFiniteMagnitude
            return lhsDate < rhsDate
        }
        let desiredIDs = Set(desired.map(\.request.identifier))
        var slotCandidates = desired.map {
            (
                identifier: $0.request.identifier,
                fireDate: $0.fireDate,
                priority: $0.priority
            )
        }
        slotCandidates.append(contentsOf: failedSourcePending.compactMap { request in
            guard !desiredIDs.contains(request.identifier) else { return nil }
            let timestamp = request.content.userInfo["scheduledFireDate"] as? TimeInterval
            return (
                identifier: request.identifier,
                fireDate: timestamp.map(Date.init(timeIntervalSince1970:)) ?? .distantFuture,
                priority: 2
            )
        })
        slotCandidates.sort {
            if $0.fireDate != $1.fireDate { return $0.fireDate < $1.fireDate }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.identifier < $1.identifier
        }
        let selectedCandidateIDs = Set(
            slotCandidates.prefix(maximumManagedPendingRequests).map(\.identifier)
        )
        let retainedFailedSourceIDs = Set(
            failedSourcePending.lazy
                .map(\.identifier)
                .filter { selectedCandidateIDs.contains($0) && !desiredIDs.contains($0) }
        )
        desired = desired.filter { selectedCandidateIDs.contains($0.request.identifier) }

        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.request.identifier, $0) })
        let staleIdentifiers = pending.compactMap { request -> String? in
            guard request.identifier.hasPrefix(managedPrefix), desiredByID[request.identifier] == nil else { return nil }

            if request.identifier.hasPrefix("\(managedPrefix)announcement.") { return nil }
            if retainedFailedSourceIDs.contains(request.identifier) { return nil }
            return request.identifier
        }

        let pendingByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
        let replacementIdentifiers = desired.compactMap { item -> String? in
            guard let existing = pendingByID[item.request.identifier] else { return nil }
            return requestNeedsReplacement(existing, with: item) ? item.request.identifier : nil
        }
        let identifiersToRemove = Array(Set(staleIdentifiers + replacementIdentifiers))
        if !identifiersToRemove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: identifiersToRemove)
        }

        let pendingIDs = Set(pending.map(\.identifier)).subtracting(identifiersToRemove)
        for item in desired where !pendingIDs.contains(item.request.identifier) {
            guard reconciliationRevision == notificationStateRevision else {
                await reconcileScheduleEntries(
                    lastScheduleEntries,
                    successfulSources: [],
                    authoritativeSources: [],
                    retainUnrefreshedSourceRequests: retainUnrefreshedSourceRequests,
                    invalidateExcludedAnimeSpecialRequests: invalidateExcludedAnimeSpecialRequests
                )
                return
            }
            do {
                try await center.add(item.request)
            } catch {
                Logger.shared.log("Local notifications: failed to schedule \(item.request.identifier): \(error.localizedDescription)", type: "Error")
            }
            guard reconciliationRevision == notificationStateRevision else {
                center.removePendingNotificationRequests(withIdentifiers: [item.request.identifier])
                await reconcileScheduleEntries(
                    lastScheduleEntries,
                    successfulSources: [],
                    authoritativeSources: [],
                    retainUnrefreshedSourceRequests: retainUnrefreshedSourceRequests,
                    invalidateExcludedAnimeSpecialRequests: invalidateExcludedAnimeSpecialRequests
                )
                return
            }
        }
        await refreshPendingRequestCount()
    }

    func rescheduleForPreferenceChange(
        invalidateExcludedAnimeSpecialRequests: Bool = false
    ) async {
        notificationStateRevision &+= 1
        await reconcileScheduleEntries(
            lastScheduleEntries,
            successfulSources: [],
            authoritativeSources: [],
            invalidateExcludedAnimeSpecialRequests: invalidateExcludedAnimeSpecialRequests
        )
        if hasNotificationSelections && lastScheduleEntries.isEmpty {
            await refreshSchedulesIfNeeded(force: true)
        }
    }

    func scheduleWindowDidChange() async {
        guard hasNotificationSelections else { return }
        notificationStateRevision &+= 1

        await reconcileScheduleEntries(
            lastScheduleEntries,
            successfulSources: [],
            authoritativeSources: []
        )
        await refreshSchedulesIfNeeded()
    }

    private func ensureAuthorization() async -> LocalNotificationActionResult {
        await refreshAuthorizationStatus()
        if canScheduleNotifications { return .enabled }
        return await requestAuthorization()
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }
    }

    private func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { continuation.resume(returning: $0) }
        }
    }

    private func deliveredNotifications() async -> [UNNotification] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { continuation.resume(returning: $0) }
        }
    }

    private func refreshPendingRequestCount() async {
        managedPendingRequestCount = await pendingNotificationRequests().filter {
            $0.identifier.hasPrefix(managedPrefix)
        }.count
    }

    private func requestNeedsReplacement(
        _ existing: UNNotificationRequest,
        with desired: DesiredNotification
    ) -> Bool {
        guard let scheduledTimestamp = existing.content.userInfo["scheduledFireDate"] as? TimeInterval else {
            return true
        }
        if abs(scheduledTimestamp - desired.fireDate.timeIntervalSince1970) > 2 { return true }
        return existing.content.title != desired.request.content.title
            || existing.content.subtitle != desired.request.content.subtitle
            || existing.content.body != desired.request.content.body
            || existing.content.categoryIdentifier != desired.request.content.categoryIdentifier
            || routingFingerprint(existing.content.userInfo)
                != routingFingerprint(desired.request.content.userInfo)
    }

    private func routingFingerprint(_ userInfo: [AnyHashable: Any]) -> [String] {
        [
            "routeVersion", "route", "kind", "source", "tmdbID", "sourceMediaID",
            "mediaType", "mediaTitle", "seasonNumber", "episodeNumber", "airingAt", "seasonLabel",
            "isAnimeSpecial"
        ].map { key in
            let value = userInfo[key]
            if let number = value as? NSNumber {
                return "\(key)=\(number.stringValue)"
            }
            return "\(key)=\(value.map(String.init(describing:)) ?? "nil")"
        }
    }

    private func refreshFutureSeasonMetadataIfNeeded(force: Bool, announceNew: Bool) async {
        let subscriptionIDs = subscriptions.compactMap { subscription -> String? in
            guard subscription.futureSeasonNotifications
                    || (subscription.source == .anime && subscription.episodeNotifications) else {
                return nil
            }
            return subscription.id
        }
        for subscriptionID in subscriptionIDs {
            _ = await refreshFutureSeasonMetadataIfNeeded(
                for: subscriptionID,
                force: force,
                announceNew: announceNew
            )
        }
    }

    private func refreshFutureSeasonMetadataIfNeeded(
        for subscriptionID: String,
        force: Bool,
        announceNew: Bool
    ) async -> Bool {
        guard let subscription = subscriptions.first(where: { $0.id == subscriptionID }),
              subscription.futureSeasonNotifications
                || (subscription.source == .anime && subscription.episodeNotifications) else {
            removeFutureMetadataRefreshState(for: subscriptionID)
            return false
        }

        let now = Date()
        if !force, let lastSuccess = futureMetadataLastSuccessfulRefreshDates[subscriptionID] {
            let elapsed = now.timeIntervalSince(lastSuccess)
            if elapsed >= 0, elapsed < futureMetadataRefreshInterval {
                return true
            }
        }
        if futureMetadataRefreshesInFlight.contains(subscriptionID) {
            if force, !announceNew {
                futureMetadataPendingBaselineRefreshes.insert(subscriptionID)
            }
            return false
        }
        if !force, let lastAttempt = futureMetadataLastAttemptDates[subscriptionID] {
            let elapsed = now.timeIntervalSince(lastAttempt)
            if elapsed >= 0, elapsed < futureMetadataFailureRetryInterval {
                return false
            }
        }

        futureMetadataLastAttemptDates[subscriptionID] = now
        futureMetadataRefreshesInFlight.insert(subscriptionID)
        let succeeded = await refreshFutureSeasonMetadata(
            for: subscriptionID,
            announceNew: announceNew
        )
        futureMetadataRefreshesInFlight.remove(subscriptionID)
        let baselineRefreshWasQueued = futureMetadataPendingBaselineRefreshes.remove(subscriptionID) != nil

        if succeeded, subscriptions.contains(where: { $0.id == subscriptionID }) {
            futureMetadataLastSuccessfulRefreshDates[subscriptionID] = Date()
            persistFutureMetadataRefreshDates()
        } else if subscriptions.contains(where: { $0.id == subscriptionID }) == false {
            removeFutureMetadataRefreshState(for: subscriptionID)
        }
        if baselineRefreshWasQueued,
           subscriptions.contains(where: { $0.id == subscriptionID }),
           (!succeeded || !hasCompleteFutureSeasonBaseline(for: subscriptionID)) {
            return await refreshFutureSeasonMetadataIfNeeded(
                for: subscriptionID,
                force: true,
                announceNew: false
            )
        }
        return succeeded
    }

    private func refreshFutureSeasonMetadata(for subscriptionID: String, announceNew: Bool) async -> Bool {
        guard let snapshot = subscriptions.first(where: { $0.id == subscriptionID }) else { return false }
        switch snapshot.source {
        case .anime:
            let positiveMediaIDs = snapshot.animeMediaIDs.filter { $0 > 0 }
            guard !positiveMediaIDs.isEmpty else { return false }
            let graph = await AniListService.shared.fetchNotificationSeasons(
                startingMediaIDs: Array(positiveMediaIDs),
                tmdbShowId: snapshot.tmdbID
            )
            let seasons = graph.seasons

            guard graph.isComplete || !seasons.isEmpty else { return false }
            guard var subscription = subscriptions.first(where: { $0.id == subscriptionID }),
                  subscription.source == .anime else { return false }
            let priorIDs = subscription.animeMediaIDs.union(subscription.animeSpecialMediaIDs)
            let regularIDs = Set(seasons.filter { !$0.isDetachedSpecial }.map(\.id))
            let specialIDs = Set(seasons.filter(\.isDetachedSpecial).map(\.id))
            subscription.animeMediaIDs.subtract(specialIDs)
            subscription.animeSpecialMediaIDs.subtract(regularIDs)
            subscription.animeMediaIDs.formUnion(regularIDs)
            subscription.animeSpecialMediaIDs.formUnion(specialIDs)
            let refreshedPremiereIDs = Set(
                seasons
                    .filter { !$0.isDetachedSpecial }
                    .map { "anilist-\($0.id)" }
            )
            if graph.isComplete {
                subscription.seasonPremieres.removeAll { $0.id.hasPrefix("anilist-") }
            } else {
                subscription.seasonPremieres.removeAll {
                    $0.id.hasPrefix("anilist-") && refreshedPremiereIDs.contains($0.id)
                }
            }
            let canAnnounceNewSeasons = announceNew
                && subscription.futureSeasonNotifications
                && subscription.hasCompleteAnimeSeasonBaseline
            var announcements: [(
                title: String,
                seasonLabel: String,
                seasonID: String,
                sourceMediaID: Int?,
                seasonNumber: Int?
            )] = []

            for season in seasons where season.isUpcoming && !season.isDetachedSpecial {
                if let premiereDate = season.premiereDate {
                    let premiere = LocalSeasonPremiere(
                        id: "anilist-\(season.id)",
                        title: season.title,
                        seasonLabel: season.seasonLabel,
                        premiereDate: premiereDate,
                        hasExactTime: false,
                        seasonNumber: seasonNumber(from: season.seasonLabel),
                        sourceMediaID: season.id
                    )
                    upsertPremiere(premiere, in: &subscription)
                }
                if canAnnounceNewSeasons, !priorIDs.contains(season.id) {
                    announcements.append((
                        season.title,
                        season.seasonLabel,
                        "anilist-\(season.id)",
                        season.id,
                        seasonNumber(from: season.seasonLabel)
                    ))
                }
            }
            if graph.isComplete {
                subscription.hasCompleteAnimeSeasonBaseline = true
            }
            guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return false }
            subscriptions[index] = subscription
            persistState()

            for announcement in announcements {
                guard subscriptions.first(where: { $0.id == subscriptionID })?.futureSeasonNotifications == true else { break }
                await deliverSeasonAnnouncement(
                    title: announcement.title,
                    seasonLabel: announcement.seasonLabel,
                    subscriptionID: subscriptionID,
                    seasonID: announcement.seasonID,
                    sourceMediaID: announcement.sourceMediaID,
                    seasonNumber: announcement.seasonNumber
                )
            }
            return true

        case .western:
            guard let detail = try? await TMDBService.shared.getTVShowWithSeasons(id: snapshot.tmdbID) else { return false }
            guard var subscription = subscriptions.first(where: { $0.id == subscriptionID }),
                  subscription.source == .western else { return false }
            let seasons = detail.seasons.filter { $0.seasonNumber > 0 }
            let priorIDs = subscription.knownWesternSeasonIDs
            let canAnnounceNewSeasons = announceNew
                && subscription.futureSeasonNotifications
                && subscription.hasCompleteWesternSeasonBaseline
            subscription.knownWesternSeasonIDs.formUnion(seasons.map(\.id))
            subscription.titleAliases = normalizedAliases(subscription.titleAliases + [detail.name, detail.originalName ?? ""])

            subscription.seasonPremieres.removeAll { $0.id.hasPrefix("tmdb-season-") }
            var announcements: [(
                title: String,
                seasonLabel: String,
                seasonID: String,
                sourceMediaID: Int?,
                seasonNumber: Int?
            )] = []

            for season in seasons {
                let date = season.airDate.flatMap(localDateAtNineAM)
                if let date, date > Date() {
                    upsertPremiere(LocalSeasonPremiere(
                        id: "tmdb-season-\(season.id)",
                        title: detail.name,
                        seasonLabel: "Season \(season.seasonNumber)",
                        premiereDate: date,
                        hasExactTime: false,
                        seasonNumber: season.seasonNumber,
                        sourceMediaID: season.id
                    ), in: &subscription)
                }
                if canAnnounceNewSeasons,
                   !priorIDs.contains(season.id),
                   season.airDate == nil || (date ?? .distantFuture) > Date() {
                    announcements.append((
                        detail.name,
                        "Season \(season.seasonNumber)",
                        "tmdb-season-\(season.id)",
                        season.id,
                        season.seasonNumber
                    ))
                }
            }
            subscription.hasCompleteWesternSeasonBaseline = true
            guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return false }
            subscriptions[index] = subscription
            persistState()

            for announcement in announcements {
                guard subscriptions.first(where: { $0.id == subscriptionID })?.futureSeasonNotifications == true else { break }
                await deliverSeasonAnnouncement(
                    title: announcement.title,
                    seasonLabel: announcement.seasonLabel,
                    subscriptionID: subscriptionID,
                    seasonID: announcement.seasonID,
                    sourceMediaID: announcement.sourceMediaID,
                    seasonNumber: announcement.seasonNumber
                )
            }
            return true
        }
    }

    private func upsertPremiere(_ premiere: LocalSeasonPremiere, in subscription: inout LocalMediaNotificationSubscription) {
        if let index = subscription.seasonPremieres.firstIndex(where: { $0.id == premiere.id }) {
            subscription.seasonPremieres[index] = premiere
        } else {
            subscription.seasonPremieres.append(premiere)
        }
    }

    private func deliverSeasonAnnouncement(
        title: String,
        seasonLabel: String,
        subscriptionID: String,
        seasonID: String,
        sourceMediaID: Int?,
        seasonNumber: Int?
    ) async {
        guard let subscription = subscriptions.first(where: { $0.id == subscriptionID }),
              subscription.futureSeasonNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "New season announced"
        content.body = "\(seasonLabel) of \(title) is now listed as upcoming."
        content.sound = .default
        content.categoryIdentifier = "ECLIPSE_SEASON"
        var userInfo: [AnyHashable: Any] = [
            "routeVersion": 1,
            "route": "schedule",
            "kind": LocalNotificationNavigationKind.season.rawValue,
            "source": subscription.source.rawValue,
            "tmdbID": subscription.tmdbID,
            "mediaType": LocalNotificationTMDBMediaType.tv.rawValue,
            "mediaTitle": subscription.title,
            "seasonLabel": seasonLabel
        ]
        if let sourceMediaID { userInfo["sourceMediaID"] = sourceMediaID }
        if let seasonNumber { userInfo["seasonNumber"] = seasonNumber }
        content.userInfo = userInfo
        let requestIdentifier = "\(managedPrefix)announcement.follow.\(subscriptionID).\(seasonID)"
        let request = UNNotificationRequest(
            identifier: requestIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try? await center.add(request)
        if subscriptions.first(where: { $0.id == subscriptionID })?.futureSeasonNotifications != true {
            center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
        }
    }

    private func updateExplicitReminders(from entries: [ScheduleEntry]) {
        var changed = false
        for entry in entries {

            guard entry.hasKnownAiringTime else { continue }
            let key = explicitEpisodeKey(entry)
            guard let index = episodeReminders.firstIndex(where: { $0.id == key }) else { continue }
            let reminder = episodeReminders[index]
            let entryIsAnimeSpecial = isAnimeSpecial(
                entry,
                subscription: matchingSubscription(for: entry)
            )
            let inferredMediaType: LocalNotificationTMDBMediaType? = {
                guard reminder.tmdbID != nil else { return reminder.tmdbMediaType }
                if entry.source == .western { return .tv }
                if entry.format?.uppercased() == "MOVIE" { return .movie }
                return reminder.tmdbMediaType
            }()
            if reminder.airingAt != entry.airingAt
                || reminder.title != entry.title
                || reminder.hasKnownAiringTime != entry.hasKnownAiringTime
                || reminder.isStreamingRelease != entry.isStreamingRelease
                || reminder.isAnimeSpecial != entryIsAnimeSpecial
                || reminder.tmdbMediaType != inferredMediaType {
                episodeReminders[index].airingAt = entry.airingAt
                episodeReminders[index].title = entry.title
                episodeReminders[index].hasKnownAiringTime = entry.hasKnownAiringTime
                episodeReminders[index].isStreamingRelease = entry.isStreamingRelease
                episodeReminders[index].isAnimeSpecial = entryIsAnimeSpecial
                episodeReminders[index].tmdbMediaType = inferredMediaType
                changed = true
            }
        }

        let countAfterUpdates = episodeReminders.count
        episodeReminders.removeAll { $0.airingAt <= Date() }
        changed = changed || countAfterUpdates != episodeReminders.count
        if changed { sortAndPersistState() }
    }

    private func explicitReminderNotifications() -> [DesiredNotification] {
        episodeReminders.compactMap { reminder in
            guard reminder.hasKnownAiringTime, reminder.airingAt > Date(),
                  let fireDate = episodeFireDate(airingAt: reminder.airingAt) else { return nil }
            let content = episodeContent(
                source: reminder.source,
                tmdbID: reminder.tmdbID,
                tmdbMediaType: reminder.tmdbMediaType,
                sourceMediaID: reminder.sourceMediaID,
                title: reminder.title,
                season: reminder.season,
                episode: reminder.episode,
                airingAt: reminder.airingAt,
                isStreamingRelease: reminder.isStreamingRelease,
                isBatch: false,
                batchCount: 1,
                isAnimeSpecial: reminder.isAnimeSpecial
            )
            return desiredNotification(
                identifier: explicitEpisodeRequestIdentifier(reminder.id),
                source: reminder.source,
                fireDate: fireDate,
                content: content,
                priority: 0
            )
        }
    }

    private func followedEpisodeNotifications(from entries: [ScheduleEntry]) -> [DesiredNotification] {
        var result: [DesiredNotification] = []
        let now = Date()
        let includeSpecials = settingsStore.bool(forKey: Self.includeAnimeSpecialsKey)

        for subscription in subscriptions where subscription.episodeNotifications {
            let candidates = entries.filter { entry in
                guard entry.airingAt > now,
                      entry.hasKnownAiringTime,
                      isWithinAutomaticEpisodeNotificationWindow(entry),
                      matches(entry, subscription: subscription) else { return false }
                if subscription.source == .anime,
                   !includeSpecials,
                   isAnimeSpecial(entry, subscription: subscription) { return false }
                if episodeReminders.contains(where: { $0.id == explicitEpisodeKey(entry) }) { return false }
                return !subscription.mutedEpisodeKeys.contains(subscriptionEpisodeKey(entry, subscriptionID: subscription.id))
            }
            var grouped: [Int: [ScheduleEntry]] = [:]
            for entry in candidates {
                guard let bucket = Self.notificationTimeBucket(for: entry.airingAt, now: now) else {
                    continue
                }
                grouped[bucket, default: []].append(entry)
            }

            for (bucket, group) in grouped {
                let sorted = group.sorted { $0.episode < $1.episode }
                guard let first = sorted.first, let fireDate = episodeFireDate(airingAt: first.airingAt) else { continue }
                if sorted.count >= 3 {
                    let content = episodeContent(
                        source: subscription.source,
                        tmdbID: subscription.tmdbID,
                        tmdbMediaType: .tv,
                        sourceMediaID: first.sourceMediaId,
                        title: subscription.title,
                        season: first.season,
                        episode: first.episode,
                        airingAt: first.airingAt,
                        isStreamingRelease: first.isStreamingRelease,
                        isBatch: true,
                        batchCount: sorted.count,
                        isAnimeSpecial: subscription.source == .anime
                            && sorted.contains {
                                isAnimeSpecial($0, subscription: subscription)
                            }
                    )
                    result.append(desiredNotification(
                        identifier: "\(managedPrefix)episode.\(subscription.source.rawValue).follow.\(subscription.id).batch.\(bucket)",
                        source: subscription.source,
                        fireDate: fireDate,
                        content: content,
                        priority: 2
                    ))
                } else {
                    for entry in sorted {
                        guard let entryFireDate = episodeFireDate(airingAt: entry.airingAt) else { continue }
                        result.append(desiredNotification(
                            identifier: followedEpisodeRequestIdentifier(entry, subscription: subscription),
                            source: subscription.source,
                            fireDate: entryFireDate,
                            content: episodeContent(
                                source: subscription.source,
                                tmdbID: subscription.tmdbID,
                                tmdbMediaType: .tv,
                                sourceMediaID: entry.sourceMediaId,
                                title: entry.title,
                                season: entry.season,
                                episode: entry.episode,
                                airingAt: entry.airingAt,
                                isStreamingRelease: entry.isStreamingRelease,
                                isBatch: false,
                                batchCount: 1,
                                isAnimeSpecial: subscription.source == .anime
                                    && isAnimeSpecial(entry, subscription: subscription)
                            ),
                            priority: 2
                        ))
                    }
                }
            }
        }
        return result
    }

    nonisolated static func notificationTimeBucket(
        for value: Date,
        now: Date = Date()
    ) -> Int? {
        let seconds = value.timeIntervalSince1970
        let maximum = now.addingTimeInterval(10 * 366 * 24 * 60 * 60).timeIntervalSince1970
        guard seconds.isFinite,
              maximum.isFinite,
              seconds >= 0,
              seconds <= maximum else {
            return nil
        }
        return Int(exactly: floor(seconds / 300))
    }

    private func seasonPremiereNotifications() -> [DesiredNotification] {
        let lead = TimeInterval(settingsStore.integer(forKey: Self.seasonLeadTimeKey))
        return subscriptions
            .filter(\.futureSeasonNotifications)
            .flatMap { subscription in
                subscription.seasonPremieres.compactMap { premiere in
                    guard let premiereDate = premiere.premiereDate, premiereDate > Date() else { return nil }
                    var fireDate = premiereDate.addingTimeInterval(-lead)
                    if fireDate <= Date() { fireDate = premiereDate }
                    guard fireDate > Date() else { return nil }

                    let content = UNMutableNotificationContent()
                    content.title = premiere.title
                    content.body = lead > 0
                        ? "\(premiere.seasonLabel) premieres soon. Open Eclipse to refresh the latest date."
                        : "\(premiere.seasonLabel) is scheduled to premiere today."
                    content.sound = .default
                    content.categoryIdentifier = "ECLIPSE_SEASON"
                    var userInfo: [AnyHashable: Any] = [
                        "routeVersion": 1,
                        "route": "schedule",
                        "kind": LocalNotificationNavigationKind.season.rawValue,
                        "source": subscription.source.rawValue,
                        "tmdbID": subscription.tmdbID,
                        "mediaType": LocalNotificationTMDBMediaType.tv.rawValue,
                        "mediaTitle": subscription.title,
                        "seasonLabel": premiere.seasonLabel
                    ]
                    if let sourceMediaID = premiere.sourceMediaID {
                        userInfo["sourceMediaID"] = sourceMediaID
                    }
                    if let seasonNumber = premiere.seasonNumber {
                        userInfo["seasonNumber"] = seasonNumber
                    }
                    content.userInfo = userInfo
                    return desiredNotification(
                        identifier: "\(managedPrefix)season.\(subscription.source.rawValue).follow.\(subscription.id).\(premiere.id)",
                        source: subscription.source,
                        fireDate: fireDate,
                        content: content,
                        priority: 1
                    )
                }
            }
    }

    private func episodeContent(
        source: LocalNotificationMediaSource,
        tmdbID: Int?,
        tmdbMediaType: LocalNotificationTMDBMediaType?,
        sourceMediaID: Int?,
        title: String,
        season: Int?,
        episode: Int,
        airingAt: Date,
        isStreamingRelease: Bool,
        isBatch: Bool,
        batchCount: Int,
        isAnimeSpecial: Bool = false
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        if isBatch {
            content.body = "\(batchCount) episodes are scheduled to release together."
        } else {
            let label: String
            if source == .western, let season, season > 0 {
                label = "S\(season) · Episode \(episode)"
            } else {
                label = "Episode \(episode)"
            }
            let lead = settingsStore.integer(forKey: Self.episodeLeadTimeKey)
            if lead > 0 {
                content.body = "\(label) is scheduled to air soon."
            } else if isStreamingRelease {
                content.body = "\(label) is scheduled to release now."
            } else {
                content.body = "\(label) has reached its scheduled airtime."
            }
        }
        content.sound = .default
        content.categoryIdentifier = "ECLIPSE_EPISODE"
        var userInfo: [AnyHashable: Any] = [
            "routeVersion": 1,
            "route": "schedule",
            "kind": isBatch
                ? LocalNotificationNavigationKind.batch.rawValue
                : LocalNotificationNavigationKind.episode.rawValue,
            "source": source.rawValue,
            "mediaTitle": title,
            "airingAt": airingAt.timeIntervalSince1970,
            "isAnimeSpecial": isAnimeSpecial
        ]
        if let tmdbID { userInfo["tmdbID"] = tmdbID }
        if let tmdbMediaType { userInfo["mediaType"] = tmdbMediaType.rawValue }
        if let sourceMediaID { userInfo["sourceMediaID"] = sourceMediaID }
        if let season { userInfo["seasonNumber"] = season }
        if !isBatch { userInfo["episodeNumber"] = episode }
        content.userInfo = userInfo
        return content
    }

    private func desiredNotification(
        identifier: String,
        source: LocalNotificationMediaSource,
        fireDate: Date,
        content: UNMutableNotificationContent,
        priority: Int
    ) -> DesiredNotification {
        let interval = max(1, fireDate.timeIntervalSinceNow)
        var userInfo = content.userInfo
        userInfo["scheduledFireDate"] = fireDate.timeIntervalSince1970
        content.userInfo = userInfo
        return DesiredNotification(
            request: UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            ),
            fireDate: fireDate,
            source: source,
            priority: priority
        )
    }

    private func episodeFireDate(airingAt: Date) -> Date? {
        guard airingAt > Date() else { return nil }
        let lead = TimeInterval(settingsStore.integer(forKey: Self.episodeLeadTimeKey))
        let preferred = airingAt.addingTimeInterval(-lead)
        return preferred > Date() ? preferred : airingAt
    }

    private func matchingSubscription(for entry: ScheduleEntry) -> LocalMediaNotificationSubscription? {
        subscriptions.first { matches(entry, subscription: $0) }
    }

    private func mergeScheduleEntry(_ entry: ScheduleEntry) {
        let key = explicitEpisodeKey(entry)
        lastScheduleEntries.removeAll {
            localSource(for: $0.source) == localSource(for: entry.source)
                && explicitEpisodeKey($0) == key
        }
        lastScheduleEntries.append(entry)
        lastScheduleEntries.sort { $0.airingAt < $1.airingAt }
    }

    private func rebuildAfterFollowedEpisodeToggle(
        _ entry: ScheduleEntry,
        subscription: LocalMediaNotificationSubscription
    ) async {
        mergeScheduleEntry(entry)
        let individualID = followedEpisodeRequestIdentifier(entry, subscription: subscription)
        let batchPrefix = "\(managedPrefix)episode.\(subscription.source.rawValue).follow.\(subscription.id).batch."
        let pending = await pendingNotificationRequests()
        let affectedIDs = pending.map(\.identifier).filter {
            $0 == individualID || $0.hasPrefix(batchPrefix)
        }
        center.removePendingNotificationRequests(withIdentifiers: affectedIDs)

        if lastLoadedSources.contains(entry.source) {
            await reconcileScheduleEntries(lastScheduleEntries, refreshedSources: [])
        } else {
            await reconcileScheduleEntries([], refreshedSources: [])
            await reconcileScheduleSourceAfterSelection(subscription.source)
        }
    }

    private func matches(_ entry: ScheduleEntry, subscription: LocalMediaNotificationSubscription) -> Bool {
        guard localSource(for: entry.source) == subscription.source else { return false }
        switch subscription.source {
        case .anime:
            let knownAnimeIDs = subscription.animeMediaIDs.union(subscription.animeSpecialMediaIDs)
            if knownAnimeIDs.contains(entry.sourceMediaId) { return true }

            let entryUsesAniListNamespace = entry.sourceMediaId > 0
            let hasIDsInEntryNamespace = knownAnimeIDs.contains {
                ($0 > 0) == entryUsesAniListNamespace
            }
            guard !hasIDsInEntryNamespace else { return false }
            return normalizedAliases([entry.title]).contains { subscription.titleAliases.contains($0) }
        case .western:
            if entry.tmdbId == subscription.tmdbID { return true }
            guard entry.tmdbId == nil else { return false }
            return normalizedAliases([entry.title]).contains { subscription.titleAliases.contains($0) }
        }
    }

    private func isAnimeSpecial(
        _ entry: ScheduleEntry,
        subscription: LocalMediaNotificationSubscription? = nil
    ) -> Bool {
        if entry.source == .anime, let subscription {
            if subscription.animeSpecialMediaIDs.contains(entry.sourceMediaId) {
                return true
            }
            if subscription.animeMediaIDs.contains(entry.sourceMediaId) {
                return false
            }
        }
        guard let format = entry.format?.uppercased() else { return false }
        return ["MOVIE", "OVA", "SPECIAL", "MUSIC"].contains(format)
    }

    private func explicitEpisodeKey(_ entry: ScheduleEntry) -> String {
        switch entry.source {
        case .anime:
            return "anime:title:\(episodeTitleIdentity(entry)):e\(entry.episode)"
        case .western:
            return "western:title:\(episodeTitleIdentity(entry)):s\(entry.season ?? 0):e\(entry.episode)"
        }
    }

    private func subscriptionEpisodeKey(_ entry: ScheduleEntry, subscriptionID: String) -> String {
        "\(subscriptionID):title:\(episodeTitleIdentity(entry)):s\(entry.season ?? 0):e\(entry.episode)"
    }

    private func episodeTitleIdentity(_ entry: ScheduleEntry) -> String {
        normalizedAliases([
            entry.englishTitle ?? "",
            entry.romajiTitle ?? "",
            entry.title
        ]).first ?? "source-\(entry.sourceMediaId)"
    }

    private func explicitEpisodeRequestIdentifier(_ key: String) -> String {
        "\(managedPrefix)episode.\(key.hasPrefix("anime:") ? "anime" : "western").explicit.\(key)"
    }

    private func followedEpisodeRequestIdentifier(
        _ entry: ScheduleEntry,
        subscription: LocalMediaNotificationSubscription
    ) -> String {
        "\(managedPrefix)episode.\(subscription.source.rawValue).follow.\(subscription.id).\(subscriptionEpisodeKey(entry, subscriptionID: subscription.id))"
    }

    private func subscriptionID(source: LocalNotificationMediaSource, tmdbID: Int) -> String {
        "\(source.rawValue)-tmdb-\(tmdbID)"
    }

    private func localSource(for source: ScheduleSource) -> LocalNotificationMediaSource {
        source == .anime ? .anime : .western
    }

    private func scheduleSource(for source: LocalNotificationMediaSource) -> ScheduleSource {
        source == .anime ? .anime : .western
    }

    private func normalizedAliases(_ aliases: [String]) -> [String] {
        var seen = Set<String>()
        return aliases.compactMap { raw in
            let normalized = raw
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private func localDateAtNineAM(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: value) else { return nil }
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)
    }

    private func seasonNumber(from label: String) -> Int? {
        guard let range = label.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(label[range])
    }

    private func removeManagedRequests(containing fragment: String, removeDelivered: Bool) async {
        let pending = await pendingNotificationRequests()
        let pendingIDs = pending.map(\.identifier).filter { $0.hasPrefix(managedPrefix) && $0.contains(fragment) }
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        if removeDelivered {
            let delivered = await deliveredNotifications()
            let deliveredIDs = delivered.map(\.request.identifier).filter { $0.hasPrefix(managedPrefix) && $0.contains(fragment) }
            await recordObservedNotifications(
                delivered.filter { deliveredIDs.contains($0.request.identifier) },
                wasOpened: false
            )
            center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        }
        await refreshPendingRequestCount()
    }

    private func captureAndRemoveDeliveredNotifications(withIdentifiers identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        let identifierSet = Set(identifiers)
        let matching = await deliveredNotifications().filter {
            identifierSet.contains($0.request.identifier)
        }
        await recordObservedNotifications(matching, wasOpened: false)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func recordObservedNotifications(
        _ notifications: [UNNotification],
        wasOpened: Bool
    ) async {
        guard !notifications.isEmpty else { return }
        let entries = notifications.map { Self.historyEntry(from: $0, wasOpened: wasOpened) }
        let outcome = await LocalNotificationHistoryStore.shared.record(entries)
        await applyHistoryMutationOutcome(outcome, operation: "record observed notifications")
    }

    nonisolated func switchProfile(to profileID: UUID) {
        let store = ProfileSettingsStore.shared.store(for: profileID)
        Task { @MainActor [weak self] in
            self?.adoptProfile(store: store)
        }
    }

    @MainActor
    private func adoptProfile(store: UserDefaults) {
        settingsStore = store

        loadPersistedState(writeCanonicalizedState: false)
        loadFutureMetadataRefreshDates()
        futureMetadataLastAttemptDates.removeAll()
        futureMetadataPendingBaselineRefreshes.removeAll()
        lastScheduleEntries = []
        lastLoadedSources = []
        Task { [weak self] in
            guard let self else { return }

            await self.removeAllManagedRequests()
            await self.refreshSchedulesIfNeeded(force: true)
        }
    }

    nonisolated func flushPendingWrites(forProfile outgoing: UUID) {
        let store = ProfileSettingsStore.shared.store(for: outgoing)
        Task { @MainActor [weak self] in
            guard let self else { return }

            guard ProfileManager.shared.profiles.contains(where: { $0.id == outgoing }) else {
                return
            }
            self.persistState(into: store)
            self.persistFutureMetadataRefreshDates(into: store)
        }
    }

    nonisolated func discardStore(forProfile profileID: UUID) {
        let store = ProfileSettingsStore.shared.store(for: profileID)
        store.removeObject(forKey: Self.subscriptionsStorageKey)
        store.removeObject(forKey: Self.episodeRemindersStorageKey)
        store.removeObject(forKey: Self.futureMetadataRefreshDatesStorageKey)
    }

    private func removeAllManagedRequests() async {
        let pending = await pendingNotificationRequests()
        let identifiers = pending.map(\.identifier).filter { $0.hasPrefix(managedPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        await refreshPendingRequestCount()
    }

    private func sortAndPersistState() {
        subscriptions.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        episodeReminders.sort { $0.airingAt < $1.airingAt }
        persistState()
    }

    private func loadPersistedState(writeCanonicalizedState: Bool = true) {
        subscriptions = decodeStored([LocalMediaNotificationSubscription].self, key: Self.subscriptionsStorageKey) ?? []
        episodeReminders = decodeStored([LocalEpisodeNotificationReminder].self, key: Self.episodeRemindersStorageKey) ?? []
        episodeReminders.removeAll { $0.airingAt <= Date() }
        subscriptions = subscriptions.map { subscription in
            var copy = subscription
            copy.titleAliases = normalizedAliases(copy.titleAliases + [copy.title])
            return copy
        }
        subscriptions.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        episodeReminders.sort { $0.airingAt < $1.airingAt }
        if writeCanonicalizedState {
            persistState()
        }
    }

    private func pruneExpiredEpisodeReminders() {
        let expired = episodeReminders.filter { $0.airingAt <= Date() }
        guard !expired.isEmpty else { return }
        episodeReminders.removeAll { $0.airingAt <= Date() }
        center.removePendingNotificationRequests(
            withIdentifiers: expired.map { explicitEpisodeRequestIdentifier($0.id) }
        )
        sortAndPersistState()
    }

    private func loadFutureMetadataRefreshDates() {
        let stored = decodeStored(
            [String: Date].self,
            key: Self.futureMetadataRefreshDatesStorageKey
        ) ?? [:]
        let validSubscriptionIDs = Set(subscriptions.map(\.id))
        let now = Date()
        futureMetadataLastSuccessfulRefreshDates = stored.filter { subscriptionID, date in
            let elapsed = now.timeIntervalSince(date)
            return validSubscriptionIDs.contains(subscriptionID)
                && elapsed >= 0
                && elapsed < futureMetadataRefreshInterval
        }
        if futureMetadataLastSuccessfulRefreshDates != stored {
            persistFutureMetadataRefreshDates()
        }
    }

    private func persistFutureMetadataRefreshDates() {
        persistFutureMetadataRefreshDates(into: settingsStore)
    }

    private func persistFutureMetadataRefreshDates(into store: UserDefaults) {
        if futureMetadataLastSuccessfulRefreshDates.isEmpty {
            store.removeObject(forKey: Self.futureMetadataRefreshDatesStorageKey)
        } else {
            encodeStored(
                futureMetadataLastSuccessfulRefreshDates,
                key: Self.futureMetadataRefreshDatesStorageKey,
                into: store
            )
        }
    }

    private func removeFutureMetadataRefreshState(for subscriptionID: String) {
        let removedStoredDate = futureMetadataLastSuccessfulRefreshDates.removeValue(forKey: subscriptionID) != nil
        futureMetadataLastAttemptDates.removeValue(forKey: subscriptionID)
        futureMetadataPendingBaselineRefreshes.remove(subscriptionID)
        if removedStoredDate {
            persistFutureMetadataRefreshDates()
        }
    }

    private func hasCompleteFutureSeasonBaseline(for subscriptionID: String) -> Bool {
        guard let subscription = subscriptions.first(where: { $0.id == subscriptionID }) else { return false }
        switch subscription.source {
        case .anime:
            return subscription.hasCompleteAnimeSeasonBaseline
        case .western:
            return subscription.hasCompleteWesternSeasonBaseline
        }
    }

    private func persistState() {
        persistState(into: settingsStore)
    }

    private func persistState(into store: UserDefaults) {
        notificationStateRevision &+= 1
        encodeStored(subscriptions, key: Self.subscriptionsStorageKey, into: store)
        encodeStored(episodeReminders, key: Self.episodeRemindersStorageKey, into: store)
    }

    private func decodeStored<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let raw = settingsStore.string(forKey: key), let data = raw.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func encodeStored<T: Encodable>(_ value: T, key: String) {
        encodeStored(value, key: key, into: settingsStore)
    }

    private func encodeStored<T: Encodable>(_ value: T, key: String, into store: UserDefaults) {
        guard let data = try? encoder.encode(value), let raw = String(data: data, encoding: .utf8) else { return }
        store.set(raw, forKey: key)
    }

    private func recordObservedNotification(_ notification: UNNotification, wasOpened: Bool) async {
        let outcome = await LocalNotificationHistoryStore.shared.record([
            Self.historyEntry(from: notification, wasOpened: wasOpened)
        ])
        await applyHistoryMutationOutcome(outcome, operation: "record an observed notification")
    }

    private func applyHistoryMutationOutcome(
        _ outcome: LocalNotificationHistoryMutationOutcome,
        operation: String
    ) async {
        guard outcome.persisted else {
            Logger.shared.log("Could not \(operation): notification history could not be saved.", type: "Error")
            return
        }
        let previousCount = notificationHistoryCount
        let count = await LocalNotificationHistoryStore.shared.count()
        notificationHistoryCount = count
        if outcome.changed || count != previousCount {
            notificationHistoryRevision &+= 1
        }
    }

    private func handleNotificationResponse(_ notification: UNNotification) async {
        pendingNavigationTarget = Self.navigationTarget(from: notification.request)
        pendingNavigationSceneSessionIdentifier = preferredNotificationSceneSessionIdentifier()
        NotificationCenter.default.post(name: .openScheduleFromLocalNotification, object: nil)
        await recordObservedNotification(notification, wasOpened: true)
    }

    private func preferredNotificationSceneSessionIdentifier() -> String? {
#if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScenes = scenes.filter { $0.activationState == .foregroundActive }
        return activeScenes.first(where: { scene in
            scene.windows.contains(where: \.isKeyWindow)
        })?.session.persistentIdentifier
            ?? activeScenes.first?.session.persistentIdentifier
#else
        return nil
#endif
    }

    private nonisolated static func historyEntry(
        from notification: UNNotification,
        wasOpened: Bool
    ) -> LocalNotificationHistoryEntry {
        let request = notification.request
        let content = request.content
        let route = routeValues(from: request)
        let deliveredMilliseconds = Int64(
            exactly: (notification.date.timeIntervalSince1970 * 1_000).rounded()
        ) ?? 0
        return LocalNotificationHistoryEntry(
            id: "\(request.identifier)|\(deliveredMilliseconds)",
            requestIdentifier: request.identifier,
            deliveredAt: notification.date,
            title: content.title,
            subtitle: content.subtitle,
            body: content.body,
            categoryIdentifier: content.categoryIdentifier,
            kind: route.kind,
            source: route.source,
            tmdbID: route.tmdbID,
            tmdbMediaType: route.tmdbMediaType,
            sourceMediaID: route.sourceMediaID,
            mediaTitle: route.mediaTitle,
            seasonNumber: route.seasonNumber,
            episodeNumber: route.episodeNumber,
            airingAt: route.airingAt,
            seasonLabel: route.seasonLabel,
            isAnimeSpecial: route.isAnimeSpecial,
            wasOpened: wasOpened
        )
    }

    private nonisolated static func navigationTarget(
        from request: UNNotificationRequest
    ) -> LocalNotificationNavigationTarget {
        let route = routeValues(from: request)
        return LocalNotificationNavigationTarget(
            id: "notification-\(request.identifier)-\(UUID().uuidString)",
            requestIdentifier: request.identifier,
            kind: route.kind,
            source: route.source,
            tmdbID: route.tmdbID,
            tmdbMediaType: route.tmdbMediaType,
            sourceMediaID: route.sourceMediaID,
            mediaTitle: route.mediaTitle,
            seasonNumber: route.seasonNumber,
            episodeNumber: route.episodeNumber,
            airingAt: route.airingAt,
            seasonLabel: route.seasonLabel,
            isAnimeSpecial: route.isAnimeSpecial
        )
    }

    private nonisolated static func routeValues(
        from request: UNNotificationRequest
    ) -> (
        kind: LocalNotificationNavigationKind,
        source: LocalNotificationMediaSource?,
        tmdbID: Int?,
        tmdbMediaType: LocalNotificationTMDBMediaType?,
        sourceMediaID: Int?,
        mediaTitle: String,
        seasonNumber: Int?,
        episodeNumber: Int?,
        airingAt: Date?,
        seasonLabel: String?,
        isAnimeSpecial: Bool
    ) {
        let content = request.content
        let info = content.userInfo
        let kind: LocalNotificationNavigationKind
        if let rawKind = info["kind"] as? String,
           let decoded = LocalNotificationNavigationKind(rawValue: rawKind) {
            kind = decoded
        } else if content.categoryIdentifier == "ECLIPSE_EPISODE" {
            kind = .episode
        } else if content.categoryIdentifier == "ECLIPSE_SEASON" {
            kind = .season
        } else {
            kind = .scheduleFallback
        }
        let source = (info["source"] as? String).flatMap(LocalNotificationMediaSource.init(rawValue:))
        let airingTimestamp = doubleValue(info["airingAt"])
        let storedMediaTitle = (info["mediaTitle"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            kind: kind,
            source: source,
            tmdbID: intValue(info["tmdbID"]),
            tmdbMediaType: (info["mediaType"] as? String)
                .flatMap { LocalNotificationTMDBMediaType(rawValue: $0.lowercased()) },
            sourceMediaID: intValue(info["sourceMediaID"]),
            mediaTitle: storedMediaTitle.flatMap { $0.isEmpty ? nil : $0 } ?? content.title,
            seasonNumber: intValue(info["seasonNumber"]),
            episodeNumber: intValue(info["episodeNumber"]),
            airingAt: airingTimestamp.map(Date.init(timeIntervalSince1970:)),
            seasonLabel: info["seasonLabel"] as? String,
            isAnimeSpecial: boolValue(info["isAnimeSpecial"]) ?? false
        )
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private nonisolated static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        return (value as? NSNumber)?.doubleValue
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        return (value as? NSNumber)?.boolValue
    }
}

extension LocalNotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
        Task { @MainActor in
            await LocalNotificationManager.shared.recordObservedNotification(notification, wasOpened: false)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            await LocalNotificationManager.shared.handleNotificationResponse(response.notification)
            completionHandler()
        }
    }
}

private struct DesiredNotification {
    let request: UNNotificationRequest
    let fireDate: Date
    let source: LocalNotificationMediaSource
    let priority: Int
}
