//
//  TrackerModels.swift
//  Eclipse
//
//  Created by Soupy-dev
//

import Foundation

enum TrackerService: String, Codable, CaseIterable {
    case anilist
    case myAnimeList
    case trakt

    var displayName: String {
        switch self {
        case .anilist:
            return "AniList"
        case .myAnimeList:
            return "MyAnimeList"
        case .trakt:
            return "Trakt"
        }
    }

    var baseURL: String {
        switch self {
        case .anilist:
            return "https://anilist.co"
        case .myAnimeList:
            return "https://myanimelist.net"
        case .trakt:
            return "https://trakt.tv"
        }
    }

    var logoURL: URL? {
        switch self {
        case .anilist:
            return URL(string: "https://anilist.co/img/icons/android-chrome-512x512.png")
        case .myAnimeList:
            return URL(string: "https://cdn.myanimelist.net/images/favicon.ico")
        case .trakt:
            return URL(string: "https://walter.trakt.tv/hotlink-ok/public/apple-touch-icon.png")
        }
    }
}

struct TrackerImportScope: Equatable {
    let owner: UUID
    let accountGeneration: UInt64
    let serviceGeneration: UInt64
    let userID: String?
}

struct TrackerImportSummary: Equatable {
    let entriesChecked: Int
    let collectionAdditions: Int
    let progressEntries: Int
    let hasSkippedItems: Bool

    var message: String {
        if entriesChecked == 0 {
            return "No entries were found in the imported lists."
        }
        return "\(entriesChecked) entries checked.\n\(collectionAdditions) collection additions.\n\(progressEntries) progress entries processed."
    }
}

struct TrackerImportState: Identifiable, Equatable {
    enum Phase: Equatable {
        case running(String)
        case finished(TrackerImportSummary)
        case failed(String)
    }

    let id: UUID
    let scope: TrackerImportScope
    var phase: Phase

    var isImporting: Bool {
        if case .running = phase { return true }
        return false
    }

    var title: String {
        switch phase {
        case .running: return "Importing Library"
        case .finished(let summary): return summary.hasSkippedItems ? "Import Finished with Skipped Items" : "Import Complete"
        case .failed: return "Import Could Not Finish"
        }
    }

    var message: String {
        switch phase {
        case .running(let message), .failed(let message): return message
        case .finished(let summary): return summary.message
        }
    }

    var needsAttention: Bool {
        switch phase {
        case .running: return false
        case .finished(let summary): return summary.hasSkippedItems
        case .failed: return true
        }
    }

    func updating(_ phase: Phase, runID: UUID, scope: TrackerImportScope) -> Self? {
        guard id == runID, self.scope == scope, isImporting else { return nil }
        var state = self
        state.phase = phase
        return state
    }
}

struct TrackerAuthenticationNotice: Identifiable, Equatable {
    let service: TrackerService

    var id: TrackerService { service }

    var title: String {
        "\(service.displayName) Login Required"
    }

    var message: String {
        "Your \(service.displayName) session has expired. Log in again to resume tracker sync."
    }
}

struct TrackerAccount: Codable {
    let service: TrackerService
    let username: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    let userId: String
    var isConnected: Bool = true

    mutating func updateTokens(access: String, refresh: String?, expiresAt: Date?) {
        self.accessToken = access
        self.refreshToken = refresh
        self.expiresAt = expiresAt
    }
}

struct TrackerState: Codable {
    var accounts: [TrackerAccount] = []
    var syncEnabled: Bool = true
#if !os(tvOS)
    var readerSyncEnabled: Bool = true
#endif
    var autoSyncRatings: Bool = false
#if !os(tvOS)
    var autoSyncReaderRatings: Bool = false
#endif
    var mergeTraktContinueWatching: Bool = false
    var liveTraktScrobbling: Bool = true
    var traktPublicCatalogsEnabled: Bool = false
    var traktCommentsEnabled: Bool = false
    var traktRelatedEnabled: Bool = false

    var traktAnimeEpisodeMapping: Bool = true

    var traktWatchlistSync: Bool = false
    var lastSyncDate: Date?

    enum CodingKeys: String, CodingKey {
        case accounts
        case syncEnabled
#if !os(tvOS)
        case readerSyncEnabled
#endif
        case autoSyncRatings
#if !os(tvOS)
        case autoSyncReaderRatings
#endif
        case mergeTraktContinueWatching
        case liveTraktScrobbling
        case traktPublicCatalogsEnabled
        case traktCommentsEnabled
        case traktRelatedEnabled
        case traktAnimeEpisodeMapping
        case traktWatchlistSync
        case lastSyncDate
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([TrackerAccount].self, forKey: .accounts) ?? []
        syncEnabled = try container.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? true
#if !os(tvOS)

        readerSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .readerSyncEnabled) ?? syncEnabled
#endif
        autoSyncRatings = try container.decodeIfPresent(Bool.self, forKey: .autoSyncRatings) ?? false
#if !os(tvOS)
        autoSyncReaderRatings = try container.decodeIfPresent(Bool.self, forKey: .autoSyncReaderRatings) ?? false
#endif
        mergeTraktContinueWatching = try container.decodeIfPresent(Bool.self, forKey: .mergeTraktContinueWatching) ?? false
        liveTraktScrobbling = try container.decodeIfPresent(Bool.self, forKey: .liveTraktScrobbling) ?? true
        traktPublicCatalogsEnabled = try container.decodeIfPresent(Bool.self, forKey: .traktPublicCatalogsEnabled) ?? false
        traktCommentsEnabled = try container.decodeIfPresent(Bool.self, forKey: .traktCommentsEnabled) ?? false
        traktRelatedEnabled = try container.decodeIfPresent(Bool.self, forKey: .traktRelatedEnabled) ?? false
        traktAnimeEpisodeMapping = try container.decodeIfPresent(Bool.self, forKey: .traktAnimeEpisodeMapping) ?? true
        traktWatchlistSync = try container.decodeIfPresent(Bool.self, forKey: .traktWatchlistSync) ?? false
        lastSyncDate = try container.decodeIfPresent(Date.self, forKey: .lastSyncDate)
    }

    mutating func addOrUpdateAccount(_ account: TrackerAccount) {
        if let index = accounts.firstIndex(where: { $0.service == account.service }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    func getAccount(for service: TrackerService) -> TrackerAccount? {

        accounts.first { $0.service == service && $0.isConnected && !$0.accessToken.isEmpty }
    }

    mutating func disconnectAccount(for service: TrackerService) {
        if let index = accounts.firstIndex(where: { $0.service == service }) {
            accounts[index].isConnected = false
        }
    }
}

enum TraktScrobbleAction: String {
    case start
    case pause
    case stop
}

struct TraktCommentReview: Identifiable, Codable, Equatable {
    let id: Int
    let authorName: String
    let comment: String
    let likes: Int
    let createdAt: String?
    let isReview: Bool
}

struct TraktMediaRating: Codable, Equatable {
    let rating: Double
    let votes: Int

    var displayText: String {
        String(format: "%.1f", rating)
    }
}

struct AniListAuthResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

struct AniListUser: Codable {
    let id: Int
    let name: String
}

struct AniListMediaListEntry: Codable {
    let id: Int
    let mediaId: Int
    let status: String
    let progress: Int
    let progressVolumes: Int?
    let score: Int?
    let startedAt: AniListTrackerDate?
    let completedAt: AniListTrackerDate?

    enum CodingKeys: String, CodingKey {
        case id, status, progress, score
        case mediaId = "mediaId"
        case progressVolumes = "progressVolumes"
        case startedAt, completedAt
    }
}

struct AniListTrackerDate: Codable {
    let year: Int?
    let month: Int?
    let day: Int?
}

struct AniListMediaEntry: Codable {
    let id: Int
    let title: AniListTitle
    let episodes: Int?
    let status: String?
    let seasonYear: Int?
    let season: String?
    let format: String?
    let coverImage: AniListCoverImage?
    let nextAiringEpisode: AniListAiringSchedule?
    let relations: AniListRelations?
    let type: String?

    struct AniListTitle: Codable {
        let romaji: String?
        let english: String?
        let native: String?
    }
}

struct AniListCoverImage: Codable {
    let large: String?
    let medium: String?
}

struct AniListRelations: Codable {
    let edges: [AniListRelationEdge]
}

struct AniListRelationEdge: Codable {
    let relationType: String
    let node: AniListRelatedAnime
}

struct AniListRelatedAnime: Codable {
    let id: Int
    let title: AniListTitle

    struct AniListTitle: Codable {
        let romaji: String?
        let english: String?
        let native: String?
    }
}

struct AniListAiringSchedule: Codable {
    let episode: Int
    let airingAt: Int
}

struct MALAuthResponse: Codable {
    let accessToken: String
    let tokenType: String?
    let expiresIn: Int?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

struct MALUser: Codable {
    let id: Int
    let name: String
}

struct TraktAuthResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

struct TraktUser: Codable {
    let username: String
    let ids: TraktIds
}

struct TraktUserSettingsResponse: Codable {
    let user: TraktUser
}

struct TraktIds: Codable {
    let trakt: Int?
    let slug: String
    let imdb: String?
    let tmdb: Int?
}

enum TrackerSyncToolAction: String, CaseIterable, Identifiable {
    case fillEclipseFromAniList
    case fillEclipseFromMAL
    case pushEclipseToAniList
    case pushEclipseToMAL
    case portAniListToMAL
    case portMALToAniList

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fillEclipseFromAniList:
            return "Fill Eclipse From AniList"
        case .fillEclipseFromMAL:
            return "Fill Eclipse From MAL"
        case .pushEclipseToAniList:
            return "Push Eclipse To AniList"
        case .pushEclipseToMAL:
            return "Push Eclipse To MAL"
        case .portAniListToMAL:
            return "Port AniList To MAL"
        case .portMALToAniList:
            return "Port MAL To AniList"
        }
    }

    var subtitle: String {
#if os(tvOS)
        switch self {
        case .fillEclipseFromAniList:
            return "Add missing anime and advance local watched progress."
        case .fillEclipseFromMAL:
            return "Use MAL anime-list progress to fill local Eclipse progress."
        case .pushEclipseToAniList:
            return "Send completed local anime episodes to AniList."
        case .pushEclipseToMAL:
            return "Send completed local anime episodes to MAL."
        case .portAniListToMAL:
            return "Copy AniList anime watch progress into MAL after preview."
        case .portMALToAniList:
            return "Copy MAL anime watch progress into AniList after preview."
        }
#else
        switch self {
        case .fillEclipseFromAniList:
            return "Add missing shows and advance local watched progress."
        case .fillEclipseFromMAL:
            return "Use MAL list progress to fill local Eclipse progress."
        case .pushEclipseToAniList:
            return "Send completed local episodes and chapters to AniList."
        case .pushEclipseToMAL:
            return "Send completed local episodes and chapters to MAL."
        case .portAniListToMAL:
            return "Copy AniList watch/read progress into MAL after preview."
        case .portMALToAniList:
            return "Copy MAL watch/read progress into AniList after preview."
        }
#endif
    }

    var isProviderPort: Bool {
        switch self {
        case .portAniListToMAL, .portMALToAniList:
            return true
        default:
            return false
        }
    }
}

struct TrackerSyncPreview: Identifiable {
    let id = UUID()
    let action: TrackerSyncToolAction
    var itemsToAdd: Int
    var itemsToAdvance: Int
    var skipped: Int
    var unmapped: Int
    var estimatedAPICalls: Int
    var notes: [String]
    var conflicts: [String] = []

    var requiresConfirmation: Bool {
        action.isProviderPort || itemsToAdd > 0 || itemsToAdvance > 0
    }
}


enum TrackerProgressSyncPolicy {
    static func aniListScoreRaw(_ rating: Double) -> Int {
        let finite = rating.isFinite ? rating : 0.5
        let bounded = min(max(finite, 0.5), 10)
        return Int(((bounded * 2).rounded() / 2 * 10).rounded())
    }

    static func traktPlaybackProgress(_ progress: Double?) -> (percent: Double, fraction: Double)? {
        guard let progress, progress.isFinite else { return nil }
        let percent = min(max(progress, 0), 100)
        guard percent > 0 else { return nil }
        return (percent, percent / 100)
    }

    static func shouldAdvance(requested: Int, requestedStatus: String, current: Int?, currentStatus: String?, isRepeating: Bool) -> Bool {
        guard requested >= 0, !isRepeating else { return false }
        guard let current else { return true }
        let status = currentStatus?.uppercased()
        guard status != "COMPLETED", status != "REPEATING" else { return false }
        if requested > current { return true }
        return requested == current && requestedStatus.uppercased() == "COMPLETED"
    }

    static func additiveStatus(requested: String, current: String?, progress: Int, total: Int?, isAniList: Bool, isManga: Bool) -> String {
        if let current, ["PAUSED", "ON_HOLD", "DROPPED"].contains(current.uppercased()) {
            return current
        }
        if let total, total > 0, progress >= total {
            return isAniList ? "COMPLETED" : "completed"
        }
        if requested.uppercased() == "COMPLETED" || current == nil { return requested }
        return isAniList ? "CURRENT" : (isManga ? "reading" : "watching")
    }
}


enum TrackerAnimeImportCoordinates {
    static func ranges(watched: Int, episodes: [AniListEpisode]) -> [Int: [ClosedRange<Int>]]? {
        resolve(watched: watched, episodes: episodes)?.mapValues { numbers in
            var result: [ClosedRange<Int>] = []
            for number in numbers {
                if let last = result.last, last.upperBound < Int.max, last.upperBound + 1 == number {
                    result[result.count - 1] = last.lowerBound...number
                } else {
                    result.append(number...number)
                }
            }
            return result
        }
    }

    static func resolve(watched: Int, episodes: [AniListEpisode]) -> [Int: [Int]]? {
        guard watched > 0, watched <= ProgressPersistencePolicy.maximumBulkEpisodeMutationCount else { return nil }
        let selected = episodes.filter { $0.number > 0 && $0.number <= watched }
        guard selected.count == watched, Set(selected.map(\.number)).count == watched else { return nil }
        var result: [Int: [Int]] = [:]
        var seen: [Int: Set<Int>] = [:]
        for episode in selected {
            guard let season = episode.tmdbSeasonNumber, let number = episode.tmdbEpisodeNumber,
                  ProgressPersistencePolicy.exactEpisodeMutationNumbers(showID: 1, seasonNumber: season, episodeNumbers: [number]) != nil,
                  seen[season, default: []].insert(number).inserted else { return nil }
            result[season, default: []].append(number)
        }
        return result.mapValues { $0.sorted() }
    }
}


actor TrackerProgressWriteCoordinator {
    struct Key: Hashable {
        let owner: UUID
        let service: TrackerService
        let userID: String
        let mediaID: Int
        let isManga: Bool

        static func traktCollectionIntent(owner: UUID, userID: String, tmdbID: Int?, traktID: Int? = nil) -> Self? {
            guard let identity = TrackerRemoteProgressBoundary.positiveIdentifier(tmdbID)
                ?? TrackerRemoteProgressBoundary.positiveIdentifier(traktID) else { return nil }
            return Self(owner: owner, service: .trakt, userID: userID, mediaID: -identity, isManga: false)
        }
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    static let maximumPendingWrites = 1_024
    private var active: Set<Key> = []
    private var waiters: [Key: [Waiter]] = [:]
    private(set) var pendingCount = 0

    func acquire(_ key: Key) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !active.contains(key) else {
                guard pendingCount < Self.maximumPendingWrites else { throw TrackerRequestSchedulingError.queueFull }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
                    pendingCount += 1
                }
                return
            }
            guard active.count < Self.maximumPendingWrites else { throw TrackerRequestSchedulingError.queueFull }
            active.insert(key)
        } onCancel: {
            Task { await self.cancel(id, key: key) }
        }
    }

    private func cancel(_ id: UUID, key: Key) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }),
              let waiter = waiters[key]?.remove(at: index) else { return }
        pendingCount -= 1
        if waiters[key]?.isEmpty == true { waiters.removeValue(forKey: key) }
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release(_ key: Key) {
        guard var queued = waiters[key], !queued.isEmpty else {
            waiters.removeValue(forKey: key)
            active.remove(key)
            return
        }
        let next = queued.removeFirst()
        waiters[key] = queued
        pendingCount -= 1
        next.continuation.resume()
    }
}

struct TrackerSeriesCollectionRow: Identifiable {
    let index: Int
    let target: TrackerCollectionTarget
    var candidate: TrackerLibraryEntry?
    var existing: TrackerLibraryEntry?
    var membershipLoaded = false
    var confirmedByAction = false
    var errorMessage: String?

    var id: Int { index }
}

@MainActor
enum TrackerSeriesCollection {
    static func load(
        targets: [TrackerCollectionTarget],
        confirmedEntryIDs: Set<String> = [],
        isAuthorized: () -> Bool,
        resolve: (TrackerCollectionTarget) async throws -> TrackerLibraryEntry,
        read: (TrackerLibraryEntry) async throws -> TrackerLibraryEntry?,
        onUpdate: ([TrackerSeriesCollectionRow], Int, Int) -> Void
    ) async throws -> [TrackerSeriesCollectionRow] {
        guard !targets.isEmpty, targets.count <= 256 else { throw TrackerLibraryError.tooLarge }
        var rows: [TrackerSeriesCollectionRow] = []
        var seen = Set<String>()
        for (index, target) in targets.enumerated() {
            try requireAuthority(isAuthorized)
            var row = TrackerSeriesCollectionRow(index: index, target: target)
            do {
                let candidate = try await resolve(target)
                try requireAuthority(isAuthorized)
                if seen.insert(candidate.id).inserted {
                    row.candidate = candidate
                    row.confirmedByAction = confirmedEntryIDs.contains(candidate.id)
                    row.existing = try await read(candidate)
                    try requireAuthority(isAuthorized)
                    row.membershipLoaded = true
                    rows.append(row)
                }
            } catch {
                try requireAuthority(isAuthorized)
                row.errorMessage = error is CancellationError
                    ? "The list changed. Refresh to check this season." : error.localizedDescription
                rows.append(row)
            }
            onUpdate(rows, index + 1, targets.count)
        }
        return rows
    }

    static func addAll(
        rows initialRows: [TrackerSeriesCollectionRow],
        retryIncompleteOnly: Bool = false,
        confirmedEntryIDs: Set<String> = [],
        isAuthorized: () -> Bool,
        resolve: (TrackerCollectionTarget) async throws -> TrackerLibraryEntry,
        add: (TrackerLibraryEntry) async throws -> TrackerLibraryEntry,
        onUpdate: ([TrackerSeriesCollectionRow], Int, Int) -> Void
    ) async throws -> [TrackerSeriesCollectionRow] {
        guard !initialRows.isEmpty, initialRows.count <= 256 else { throw TrackerLibraryError.tooLarge }
        var rows = initialRows
        var seen = Set<String>()
        for index in rows.indices {
            try requireAuthority(isAuthorized)
            if retryIncompleteOnly && rows[index].confirmedByAction {
                onUpdate(rows, index + 1, rows.count)
                continue
            }
            rows[index].errorMessage = nil
            rows[index].membershipLoaded = false
            rows[index].existing = nil
            do {
                let candidate: TrackerLibraryEntry
                if let existingCandidate = rows[index].candidate {
                    candidate = existingCandidate
                } else {
                    candidate = try await resolve(rows[index].target)
                }
                try requireAuthority(isAuthorized)
                rows[index].candidate = candidate
                if retryIncompleteOnly && confirmedEntryIDs.contains(candidate.id) {
                    rows[index].confirmedByAction = true
                } else if retryIncompleteOnly, let confirmed = rows.first(where: {
                    $0.confirmedByAction && $0.candidate?.id == candidate.id
                }) {
                    rows[index].existing = confirmed.existing
                    rows[index].membershipLoaded = confirmed.membershipLoaded
                    rows[index].confirmedByAction = true
                } else if seen.insert(candidate.id).inserted {
                    rows[index].existing = try await add(candidate)
                    rows[index].membershipLoaded = true
                    rows[index].confirmedByAction = true
                } else {
                    guard let confirmed = rows.prefix(index).first(where: {
                        $0.confirmedByAction && $0.candidate?.id == candidate.id
                    }) else { throw TrackerLibraryError.invalidResponse }
                    rows[index].existing = confirmed.existing
                    rows[index].membershipLoaded = confirmed.membershipLoaded
                    rows[index].confirmedByAction = true
                }
                try requireAuthority(isAuthorized)
            } catch {
                try requireAuthority(isAuthorized)
                rows[index].errorMessage = error is CancellationError
                    ? "The list changed. Refresh before retrying." : error.localizedDescription
            }
            onUpdate(rows, index + 1, rows.count)
        }
        return rows
    }

    private static func requireAuthority(_ isAuthorized: () -> Bool) throws {
        try Task.checkCancellation()
        guard isAuthorized() else { throw CancellationError() }
    }
}
