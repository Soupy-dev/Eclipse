import Foundation
import Combine
import AuthenticationServices
import Security
import UIKit

private enum TrackerCredentialVault {
    private struct Credentials: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    private static let service = "app.Eclipse.Soupy.tracker-credentials"

    static func store(_ account: TrackerAccount) -> Bool {
        let credentials = Credentials(
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            expiresAt: account.expiresAt
        )
        guard !credentials.accessToken.isEmpty,
              let data = try? JSONEncoder().encode(credentials) else { return false }

        let lookup = query(for: account.service)
        let updatedValues: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, updatedValues as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }

        var attributes = lookup
        attributes.merge(updatedValues) { _, new in new }
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func hydrate(_ account: TrackerAccount) -> TrackerAccount? {
        var attributes = query(for: account.service)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
              !credentials.accessToken.isEmpty else {
            return nil
        }

        var hydrated = account
        hydrated.accessToken = credentials.accessToken
        hydrated.refreshToken = credentials.refreshToken
        hydrated.expiresAt = credentials.expiresAt
        hydrated.isConnected = true
        return hydrated
    }

    static func remove(_ serviceType: TrackerService) {
        SecItemDelete(query(for: serviceType) as CFDictionary)
    }

    private static func query(for serviceType: TrackerService) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serviceType.rawValue
        ]
    }
}

private enum TrackerRequestProvider: Hashable {
    case anilist
    case myAnimeList
    case trakt
}

private actor TrackerRequestScheduler {
    static let shared = TrackerRequestScheduler()

    private var nextAllowedAt: [TrackerRequestProvider: Date] = [:]
    private var minimumSpacing: [TrackerRequestProvider: TimeInterval] = [
        .anilist: 0.8,
        .myAnimeList: 1.2,
        .trakt: 1.05
    ]

    func waitForSlot(provider: TrackerRequestProvider) async {
        let now = Date()
        let slot = max(now, nextAllowedAt[provider] ?? .distantPast)
        nextAllowedAt[provider] = slot.addingTimeInterval(minimumSpacing[provider] ?? 1)

        let delay = slot.timeIntervalSince(now)
        if delay > 0.001 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    func recordResponse(provider: TrackerRequestProvider, response: HTTPURLResponse) -> TimeInterval? {
        if provider == .anilist,
           let limitValue = response.value(forHTTPHeaderField: "X-RateLimit-Limit"),
           let limit = Double(limitValue),
           limit > 0 {
            minimumSpacing[provider] = max(60.0 / limit, 0.8)
        }

        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap(TimeInterval.init)

        if response.statusCode == 429 {
            let pause = min(max(retryAfter ?? 5, 1), 120)
            nextAllowedAt[provider] = max(nextAllowedAt[provider] ?? .distantPast, Date().addingTimeInterval(pause))
            return pause
        }

        if provider == .anilist,
           let remainingValue = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           let remaining = Int(remainingValue),
           remaining <= 1,
           let resetValue = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let reset = TimeInterval(resetValue) {
            let resetDate = Date(timeIntervalSince1970: reset)
            if resetDate > Date() {
                nextAllowedAt[provider] = max(nextAllowedAt[provider] ?? .distantPast, resetDate)
            }
        }

        return nil
    }
}

private struct AniListRatingSyncResponse {
    let statusCode: Int
    let bodyPreview: String
    let graphQLError: String?

    var succeeded: Bool {
        (200...299).contains(statusCode) && graphQLError == nil
    }
}

private struct RemoteAnimeProgress {
    let anilistId: Int?
    let malId: Int?
    let title: String
    let status: String
    let progress: Int
    let totalEpisodes: Int?
}

#if !os(tvOS)
private struct RemoteMangaProgress {
    let anilistId: Int?
    let malId: Int?
    let title: String
    let status: String
    let progress: Int
    let totalChapters: Int?
}

private struct MangaTrackerMatch {
    let aniListId: Int?
    let malId: Int?
    let title: String
    let confidence: Double

    var isUsable: Bool {
        aniListId != nil || malId != nil
    }
}
#endif

private struct TrackerSyncToolPlan {
    let action: TrackerSyncToolAction
    let preview: TrackerSyncPreview
    var animeEntries: [RemoteAnimeProgress] = []
#if !os(tvOS)
    var mangaEntries: [RemoteMangaProgress] = []
#endif
}

final class TrackerManager: NSObject, ObservableObject {
    static let shared = TrackerManager()

    @Published var trackerState: TrackerState = TrackerState()
    @Published var isAuthenticating = false
    @Published var authError: String?
    @Published var isRunningSyncTool = false
    @Published var syncToolStatus: String?
    @Published var syncToolPreview: TrackerSyncPreview?
    @Published var syncToolProgressCompleted = 0
    @Published var syncToolProgressTotal = 0
    @Published var syncToolProgressDetail: String?
    @Published var syncToolIsLocked = false
#if os(tvOS)
    @Published private(set) var traktDeviceUserCode: String?
    @Published private(set) var traktDeviceVerificationURL: URL?
#endif
    private var cachedSyncToolPlan: TrackerSyncToolPlan?
    private var syncToolTask: Task<Void, Never>?

    private let trackerStateURL: URL
    private let trackerStatePersistenceQueue = DispatchQueue(
        label: "app.eclipse.soupy.tracker-state-persistence",
        qos: .utility
    )
    private var webAuthSession: ASWebAuthenticationSession?
#if os(tvOS)
    private var traktDeviceAuthTask: Task<Void, Never>?
#endif

    // Cache for TMDB ID -> AniList ID mappings to support anime syncing
    private var anilistIdCache: [Int: Int] = [:]
    private let anilistIdCacheQueue = DispatchQueue(label: "app.eclipse.soupy.anilistIdCache")

    // Cross-provider ID caches keep sync tools from resolving the same IDs repeatedly.
    private var malToAniListAnimeIdCache: [Int: Int] = [:]
    private var aniListToMALAnimeIdCache: [Int: Int] = [:]
#if !os(tvOS)
    private var malToAniListMangaIdCache: [Int: Int] = [:]
    private var aniListToMALMangaIdCache: [Int: Int] = [:]
#endif
    private var aniListEpisodeCountCache: [Int: Int] = [:]
#if !os(tvOS)
    private var mangaTrackerMatchCache: [String: MangaTrackerMatch] = [:]
    private let mangaTrackerMatchCacheQueue = DispatchQueue(label: "app.eclipse.soupy.mangaTrackerMatchCache")
#endif
    private let malListPageLimit = 1000
    private let largeSyncAPICallThreshold = 90
    private let tokenRefreshLeeway: TimeInterval = 5 * 60
    
    // Cache for (TMDB ID, season number) -> AniList ID for anime with multiple AniList entries per season
    private var anilistSeasonIdCache: [String: Int] = [:] // key format: "tmdbId_seasonNumber"
    private let anilistSeasonIdCacheQueue = DispatchQueue(label: "app.eclipse.soupy.anilistSeasonIdCache")

    // Prevent tracker sync bursts during local backup restore.
    private var syncSuppressedDuringBackupRestore = false
    private let backupRestoreSyncQueue = DispatchQueue(label: "app.eclipse.soupy.backupRestoreSync")
    private var recentWatchSyncKeys: [String: Date] = [:]
    private let recentWatchSyncQueue = DispatchQueue(label: "app.eclipse.soupy.recentWatchSync")
    private let watchSyncDedupeInterval: TimeInterval = 60
    private var recentTraktPlaybackSyncKeys: [String: Date] = [:]
    private let recentTraktPlaybackSyncQueue = DispatchQueue(label: "app.eclipse.soupy.recentTraktPlaybackSync")
    private let traktPlaybackSyncInterval: TimeInterval = 30
    private var traktMediaIdCache: [String: Int] = [:]
    private let traktMediaIdCacheQueue = DispatchQueue(label: "app.eclipse.soupy.traktMediaIdCache")
    private var traktTokenRefreshTask: Task<TrackerAccount, Error>?
    private var traktContinueWatchingCache: (accountUserId: String, fetchedAt: Date, items: [ContinueWatchingItem])?
    private let traktContinueWatchingCacheQueue = DispatchQueue(label: "app.eclipse.soupy.traktContinueWatchingCache")
    private let traktContinueWatchingCacheTTL: TimeInterval = 90
    private var traktCommentsCache: [String: (fetchedAt: Date, items: [TraktCommentReview])] = [:]
    private var traktRatingsCache: [String: (fetchedAt: Date, rating: TraktMediaRating)] = [:]
    private var traktRelatedCache: [String: (fetchedAt: Date, items: [TMDBSearchResult])] = [:]
    private let traktFeatureCacheQueue = DispatchQueue(label: "app.eclipse.soupy.traktFeatureCache")
    private let traktFeatureCacheTTL: TimeInterval = 10 * 60
    private var traktScrobbleLastActionByKey: [String: TraktScrobbleAction] = [:]
    private var traktScrobbleLastStampByKey: [String: (action: TraktScrobbleAction, progress: Double, sentAt: Date)] = [:]
    private var traktScrobblePendingByKey: [String: (action: TraktScrobbleAction, progress: Double, queuedAt: Date)] = [:]
    private var traktScrobbleFailureStampByKey: [String: (action: TraktScrobbleAction, progress: Double, failedAt: Date)] = [:]
    private let traktScrobbleQueue = DispatchQueue(label: "app.eclipse.soupy.traktScrobbleDedupe")
    private let traktScrobbleMinimumInterval: TimeInterval = 8
    private let traktScrobbleStartRefreshMinimumInterval: TimeInterval = 20
    private let traktScrobbleFailureCooldown: TimeInterval = 60
    private let traktScrobbleProgressWindow: Double = 1.5

    // OAuth config is supplied by ignored local build settings.
    private func bundledCredential(_ key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("$(") ? "" : trimmed
    }

    private var anilistClientId: String {
        bundledCredential("AniListClientID")
    }
    private var anilistClientSecret: String {
        bundledCredential("AniListClientSecret")
    }
    private var anilistRedirectUri: String {
        let configured = bundledCredential("AniListRedirectUri")
        return configured.isEmpty ? "luna://anilist-callback" : configured
    }

    private var malClientId: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "MALClientID") as? String ?? ""
        return raw.contains("$(") ? "" : raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var malClientSecret: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "MALClientSecret") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("$(") ? nil : trimmed
    }
    private var malRedirectUri: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "MALRedirectUri") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("$(") ? "luna://mal-callback" : trimmed
    }
    private var pendingMALCodeVerifier: String?
    private var pendingTraktOAuthState: String?

    private var traktClientId: String {
        bundledCredential("TraktClientID")
    }
    private var traktClientSecret: String {
        bundledCredential("TraktClientSecret")
    }
    private var traktRedirectUri: String {
        let configured = bundledCredential("TraktRedirectUri")
        return configured.isEmpty ? "luna://trakt-callback" : configured
    }

    override private init() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.trackerStateURL = documentsDirectory.appendingPathComponent("TrackerState.json")
        super.init()
        loadTrackerState()
    }

    // MARK: - State Management

    private func loadTrackerState() {
        if let data = try? Data(contentsOf: trackerStateURL),
           var state = try? JSONDecoder().decode(TrackerState.self, from: data) {
            var migratedPlaintextCredentials = false
            state.accounts = state.accounts.compactMap { account in
                if !account.accessToken.isEmpty {
                    guard TrackerCredentialVault.store(account) else {
                        // Do not silently sign the user out if the Keychain is temporarily
                        // unavailable (for example, before first unlock after a reboot).
                        return account
                    }
                    migratedPlaintextCredentials = true
                }
                return TrackerCredentialVault.hydrate(account)
            }
            self.trackerState = state
            if migratedPlaintextCredentials {
                saveTrackerState()
            }
        }
    }

    func saveTrackerState() {
        var stateToPersist = trackerState
        stateToPersist.accounts = stateToPersist.accounts.map { account in
            if account.isConnected {
                // Only redact credentials after they have reached the Keychain. Keeping
                // the in-memory snapshot on a failed Keychain write avoids destructive
                // sign-out on the next launch.
                guard TrackerCredentialVault.store(account) else { return account }
            } else {
                TrackerCredentialVault.remove(account.service)
            }
            var redacted = account
            redacted.accessToken = ""
            redacted.refreshToken = nil
            redacted.expiresAt = nil
            return redacted
        }
        trackerStatePersistenceQueue.async {
            if let encoded = try? JSONEncoder().encode(stateToPersist) {
                try? encoded.write(to: self.trackerStateURL, options: .atomic)
            }
        }
    }

    func setSyncEnabled(_ enabled: Bool) {
        trackerState.syncEnabled = enabled
        saveTrackerState()
    }

    func setAutoSyncRatings(_ enabled: Bool) {
        trackerState.autoSyncRatings = enabled
        saveTrackerState()
    }

#if !os(tvOS)
    func setAutoSyncReaderRatings(_ enabled: Bool) {
        trackerState.autoSyncReaderRatings = enabled
        saveTrackerState()
    }
#endif

    func setMergeTraktContinueWatching(_ enabled: Bool) {
        trackerState.mergeTraktContinueWatching = enabled
        invalidateTraktContinueWatchingCache()
        saveTrackerState()
    }

    func setLiveTraktScrobbling(_ enabled: Bool) {
        trackerState.liveTraktScrobbling = enabled
        if !enabled {
            resetTraktScrobbleState()
        }
        saveTrackerState()
    }

    func setTraktPublicCatalogsEnabled(_ enabled: Bool) {
        trackerState.traktPublicCatalogsEnabled = enabled
        saveTrackerState()
    }

    func setTraktCommentsEnabled(_ enabled: Bool) {
        trackerState.traktCommentsEnabled = enabled
        if !enabled {
            invalidateTraktFeatureCaches(comments: true, related: false)
        }
        saveTrackerState()
    }

    func setTraktRelatedEnabled(_ enabled: Bool) {
        trackerState.traktRelatedEnabled = enabled
        if !enabled {
            invalidateTraktFeatureCaches(comments: false, related: true)
        }
        saveTrackerState()
    }

    func setTraktAnimeEpisodeMapping(_ enabled: Bool) {
        trackerState.traktAnimeEpisodeMapping = enabled
        saveTrackerState()
    }

    func setTraktWatchlistSync(_ enabled: Bool) {
        trackerState.traktWatchlistSync = enabled
        saveTrackerState()
        if enabled {
            // Pull current Trakt watchlist into the local collection so the two sides
            // line up the moment the user opts in. Push happens on future edits.
            refreshTraktWatchlistCollection()
        }
    }

    func hasConnectedAccount(_ service: TrackerService) -> Bool {
        trackerState.getAccount(for: service) != nil
    }

    func setBackupRestoreSyncSuppressed(_ suppressed: Bool) {
        backupRestoreSyncQueue.sync {
            syncSuppressedDuringBackupRestore = suppressed
        }
        Logger.shared.log("Tracker sync suppression during backup restore: \(suppressed ? "enabled" : "disabled")", type: "Tracker")
    }

    private func isBackupRestoreSyncSuppressed() -> Bool {
        backupRestoreSyncQueue.sync {
            syncSuppressedDuringBackupRestore
        }
    }

    private func shouldStartWatchSync(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        progress: Double,
        isMovie: Bool,
        playbackContext: EpisodePlaybackContext?
    ) -> Bool {
        let normalizedProgress = progress <= 1.0 ? progress * 100.0 : progress
        guard normalizedProgress >= 85 else {
            return true
        }

        let providerKey = playbackContext?.anilistMediaId.map { String($0) } ?? "none"
        let specialKey = playbackContext?.isSpecial == true ? "special" : "regular"
        let key = "\(isMovie ? "movie" : "episode")|\(showId)|\(seasonNumber)|\(episodeNumber)|\(providerKey)|\(specialKey)|watched"
        let now = Date()
        var shouldStart = true
        recentWatchSyncQueue.sync {
            recentWatchSyncKeys = recentWatchSyncKeys.filter {
                now.timeIntervalSince($0.value) < watchSyncDedupeInterval * 10
            }
            if let previous = recentWatchSyncKeys[key],
               now.timeIntervalSince(previous) < watchSyncDedupeInterval {
                shouldStart = false
            } else {
                recentWatchSyncKeys[key] = now
            }
        }

        if !shouldStart {
            Logger.shared.log("Skipping duplicate watched sync for TMDB \(showId) S\(seasonNumber)E\(episodeNumber) \(Int(normalizedProgress))% within \(Int(watchSyncDedupeInterval))s", type: "Tracker")
        }
        return shouldStart
    }

    private func sendTrackerRequest(
        _ request: URLRequest,
        provider: TrackerRequestProvider,
        maxRetries: Int = 2,
        reportRateLimitStatus: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            await TrackerRequestScheduler.shared.waitForSlot(provider: provider)
            try Task.checkCancellation()

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "TrackerNetwork", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid tracker response"])
            }

            if let retryDelay = await TrackerRequestScheduler.shared.recordResponse(provider: provider, response: httpResponse),
               attempt < maxRetries - 1 {
                Logger.shared.log("Tracker request paused for rate limit (\(provider)) for \(Int(retryDelay))s", type: "Tracker")
                if reportRateLimitStatus {
                    await MainActor.run {
                        self.syncToolStatus = "Paused for rate limit. Resuming in \(Int(retryDelay))s..."
                        self.syncToolProgressDetail = "Paused for rate limit. Resuming in \(Int(retryDelay))s..."
                    }
                }
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                try Task.checkCancellation()
                lastError = NSError(domain: "TrackerRateLimit", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Rate limited by tracker"])
                continue
            }

            if provider == .trakt,
               (500...599).contains(httpResponse.statusCode),
               attempt < maxRetries - 1 {
                let retryDelay: TimeInterval = (502...504).contains(httpResponse.statusCode) ? 5.0 : Double(attempt + 1) * 1.5
                Logger.shared.log("Retrying Trakt request after server error \(httpResponse.statusCode) in \(String(format: "%.1f", retryDelay))s", type: "Tracker")
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                try Task.checkCancellation()
                lastError = NSError(domain: "TrackerServer", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Trakt server error \(httpResponse.statusCode)"])
                continue
            }

            return (data, httpResponse)
        }

        throw lastError ?? NSError(domain: "TrackerNetwork", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tracker request failed"])
    }

    private func graphQLErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]],
              let first = errors.first else {
            return nil
        }
        return first["message"] as? String
    }

    private func responseBodyPreview(from data: Data, limit: Int = 500) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
        guard raw.count > limit else { return raw }
        return String(raw.prefix(limit)) + "..."
    }

    private func aniListFailureDescription(_ prefix: String, response: HTTPURLResponse, data: Data) -> String {
        if let graphQLError = graphQLErrorMessage(from: data) {
            return "\(prefix) (\(response.statusCode)): \(graphQLError)"
        }
        return "\(prefix) (\(response.statusCode)): \(responseBodyPreview(from: data))"
    }

    private func resolvedAniListUserId(for account: TrackerAccount) async throws -> Int {
        if let userId = Int(account.userId), userId > 0 {
            return userId
        }
        let viewer = try await fetchAniListUser(token: account.accessToken)
        return viewer.id
    }

    private func connectedMALAccount() async throws -> TrackerAccount {
        let account = try connectedAccount(.myAnimeList)
        return try await refreshedMALAccountIfNeeded(account)
    }

    private func refreshedMALAccountIfNeeded(_ account: TrackerAccount, force: Bool = false) async throws -> TrackerAccount {
        guard account.service == .myAnimeList else { return account }
        let latestAccount = await MainActor.run {
            self.trackerState.getAccount(for: .myAnimeList) ?? account
        }
        if !force {
            guard let expiresAt = latestAccount.expiresAt else { return latestAccount }
            guard expiresAt.timeIntervalSinceNow <= tokenRefreshLeeway else { return latestAccount }
        }

        guard let refreshToken = latestAccount.refreshToken, !refreshToken.isEmpty else {
            throw NSError(
                domain: "MALAuth",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "MAL session expired. Reconnect MyAnimeList, then import again."]
            )
        }

        let token = try await refreshMALToken(refreshToken)
        var refreshedAccount = latestAccount
        refreshedAccount.updateTokens(
            access: token.accessToken,
            refresh: token.refreshToken ?? refreshToken,
            expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                ?? Date().addingTimeInterval(30 * 24 * 60 * 60)
        )
        let accountToSave = refreshedAccount

        await MainActor.run {
            self.trackerState.addOrUpdateAccount(accountToSave)
            self.saveTrackerState()
        }
        Logger.shared.log(force ? "MAL token refreshed after invalid_token response" : "MAL token refreshed before tracker library operation", type: "Tracker")
        return accountToSave
    }

    @MainActor
    private func refreshedTraktAccountIfNeeded(_ account: TrackerAccount, force: Bool = false) async throws -> TrackerAccount {
        guard account.service == .trakt else { return account }
        let latestAccount = trackerState.getAccount(for: .trakt) ?? account
        if !force {
            guard let expiresAt = latestAccount.expiresAt else { return latestAccount }
            guard expiresAt.timeIntervalSinceNow <= tokenRefreshLeeway else { return latestAccount }
        }

        guard let refreshToken = latestAccount.refreshToken, !refreshToken.isEmpty else {
            throw NSError(
                domain: "TraktAuth",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Trakt session expired. Reconnect Trakt in Settings."]
            )
        }

        if let traktTokenRefreshTask {
            return try await traktTokenRefreshTask.value
        }

        let refreshTask = Task { [weak self] () throws -> TrackerAccount in
            guard let self else {
                throw NSError(domain: "TraktAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tracker manager unavailable"])
            }
            let token = try await self.refreshTraktToken(refreshToken)
            var refreshedAccount = latestAccount
            refreshedAccount.updateTokens(
                access: token.accessToken,
                refresh: token.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn))
            )
            return refreshedAccount
        }
        traktTokenRefreshTask = refreshTask

        do {
            let refreshedAccount = try await refreshTask.value
            trackerState.addOrUpdateAccount(refreshedAccount)
            saveTrackerState()
            traktTokenRefreshTask = nil
            Logger.shared.log("Trakt token refreshed before tracker operation", type: "Tracker")
            return refreshedAccount
        } catch {
            traktTokenRefreshTask = nil
            throw error
        }
    }

    private func formURLEncodedBody(_ values: [String: String]) -> Data? {
        values.map { key, value in
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }

#if os(tvOS)
    private func startTVOAuthSession(
        url: URL,
        providerName: String,
        callbackScheme: String = "luna",
        onCode: @escaping (String) -> Void
    ) {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.webAuthSession = nil

                if let error {
                    self.authError = "\(providerName) sign-in did not complete: \(error.localizedDescription)"
                    self.isAuthenticating = false
                    return
                }

                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                      !code.isEmpty else {
                    self.authError = "\(providerName) did not return an authorization code."
                    self.isAuthenticating = false
                    return
                }

                Logger.shared.log("\(providerName) authorization callback received", type: "Tracker")
                onCode(code)
            }
        }
        webAuthSession = session
        if !session.start() {
            webAuthSession = nil
            authError = "\(providerName) sign-in could not be opened on Apple TV."
            isAuthenticating = false
        }
    }
#endif

    // MARK: - AniList Authentication

    func getAniListAuthURL() -> URL? {
        guard !anilistClientId.isEmpty, !anilistClientSecret.isEmpty else {
            authError = "Add ANILIST_CLIENT_ID and ANILIST_CLIENT_SECRET to Build.local.xcconfig before connecting AniList."
            return nil
        }

        var components = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: anilistClientId),
            URLQueryItem(name: "redirect_uri", value: anilistRedirectUri),
            URLQueryItem(name: "response_type", value: "code")
        ]
        let url = components?.url
        Logger.shared.log("AniList authorization URL prepared", type: "Tracker")
        return url
    }

    func startAniListAuth() {
        guard let url = getAniListAuthURL() else { return }
        authError = nil
        isAuthenticating = true

        #if os(tvOS)
        startTVOAuthSession(url: url, providerName: "AniList") { [weak self] code in
            self?.handleAniListCallback(code: code)
        }
        #else
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "luna") { [weak self] callbackURL, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                }
                Logger.shared.log("AniList auth error: \(error.localizedDescription)", type: "Error")
                return
            }

            guard let callbackURL = callbackURL else {
                Logger.shared.log("AniList callback URL is nil", type: "Error")
                DispatchQueue.main.async {
                    self.authError = "AniList callback URL is nil"
                    self.isAuthenticating = false
                }
                return
            }

            Logger.shared.log("AniList authorization callback received", type: "Tracker")

            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                Logger.shared.log("Failed to extract code from AniList callback", type: "Error")
                DispatchQueue.main.async {
                    self.authError = "Invalid AniList callback - failed to extract code"
                    self.isAuthenticating = false
                }
                return
            }

            Logger.shared.log("AniList code extracted successfully", type: "Tracker")
            self.handleAniListCallback(code: code)
        }

        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        session.start()
        webAuthSession = session
        #endif
    }

    func handleAniListCallback(code: String) {
        isAuthenticating = true
        Logger.shared.log("AniList callback received with code", type: "Tracker")
        Task {
            do {
                let token = try await exchangeAniListCode(code)
                Logger.shared.log("AniList token exchanged successfully", type: "Tracker")
                let user = try await fetchAniListUser(token: token.accessToken)
                Logger.shared.log("AniList user fetched: \(user.name)", type: "Tracker")
                let account = TrackerAccount(
                    service: .anilist,
                    username: user.name,
                    accessToken: token.accessToken,
                    refreshToken: nil,
                    expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
                    userId: String(user.id)
                )
                await MainActor.run {
                    self.trackerState.addOrUpdateAccount(account)
                    self.saveTrackerState()
                    self.isAuthenticating = false
                    self.authError = nil
                    Logger.shared.log("AniList account saved", type: "Tracker")
                }
            } catch {
                await MainActor.run {
                    self.authError = "AniList auth failed: \(error.localizedDescription)"
                    self.isAuthenticating = false
                    Logger.shared.log("AniList auth error: \(error.localizedDescription)", type: "Error")
                }
            }
        }
    }

    func handleAniListPinAuth(token: String) {
        isAuthenticating = true
        Task {
            do {
                let user = try await fetchAniListUser(token: token)
                let account = TrackerAccount(
                    service: .anilist,
                    username: user.name,
                    accessToken: token,
                    refreshToken: nil,
                    expiresAt: Date().addingTimeInterval(365 * 24 * 3600),
                    userId: String(user.id)
                )
                await MainActor.run {
                    self.trackerState.addOrUpdateAccount(account)
                    self.saveTrackerState()
                    self.isAuthenticating = false
                    self.authError = nil
                }
            } catch {
                await MainActor.run {
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                }
            }
        }
    }

    private func exchangeAniListCode(_ code: String) async throws -> AniListAuthResponse {
        guard !anilistClientId.isEmpty, !anilistClientSecret.isEmpty else {
            throw NSError(domain: "AniListAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "AniList credentials are not configured."])
        }

        let url = URL(string: "https://anilist.co/api/v2/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": anilistClientId,
            "client_secret": anilistClientSecret,
            "redirect_uri": anilistRedirectUri,
            "code": code
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.shared.log("Exchanging AniList code for token", type: "Tracker")
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? -1

        Logger.shared.log("AniList token response status: \(statusCode)", type: "Tracker")
        Logger.shared.log("AniList response data length: \(data.count) bytes", type: "Tracker")

        guard statusCode == 200 else {
            let errorMsg = "AniList token request failed with status \(statusCode)"
            Logger.shared.log(errorMsg, type: "Error")
            throw NSError(domain: "AniListAuth", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        do {
            return try JSONDecoder().decode(AniListAuthResponse.self, from: data)
        } catch {
            Logger.shared.log("Failed to decode AniList response: \(error.localizedDescription)", type: "Error")
            throw error
        }
    }

    private func fetchAniListUser(token: String) async throws -> AniListUser {
        let query = """
        query {
            Viewer {
                id
                name
            }
        }
        """

        let url = URL(string: "https://graphql.anilist.co")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.shared.log("Fetching AniList user", type: "Tracker")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? -1

        Logger.shared.log("AniList user response status: \(statusCode)", type: "Tracker")
        Logger.shared.log("AniList user response data length: \(data.count) bytes", type: "Tracker")

        struct Response: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable {
                let Viewer: AniListUser
            }
        }

        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            return response.data.Viewer
        } catch {
            Logger.shared.log("Failed to decode AniList user response: \(error.localizedDescription)", type: "Error")
            throw error
        }
    }

    // MARK: - MyAnimeList Authentication

    private func generateMALCodeVerifier() -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<96).compactMap { _ in characters.randomElement() })
    }

    func getMALAuthURL() -> URL? {
        guard !malClientId.isEmpty else {
            authError = "Add MAL_CLIENT_ID to Build.local.xcconfig before connecting MyAnimeList."
            return nil
        }

        let verifier = generateMALCodeVerifier()
        pendingMALCodeVerifier = verifier

        var components = URLComponents(string: "https://myanimelist.net/v1/oauth2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: malClientId),
            URLQueryItem(name: "redirect_uri", value: malRedirectUri),
            URLQueryItem(name: "code_challenge", value: verifier),
            URLQueryItem(name: "code_challenge_method", value: "plain")
        ]
        let url = components?.url
        // The MAL URL contains the PKCE verifier. Never place it in logs or crash breadcrumbs.
        Logger.shared.log("MAL authorization URL prepared", type: "Tracker")
        return url
    }

    func startMALAuth() {
        guard let url = getMALAuthURL() else { return }
        authError = nil
        isAuthenticating = true

        #if os(tvOS)
        startTVOAuthSession(url: url, providerName: "MyAnimeList") { [weak self] code in
            self?.handleMALCallback(code: code)
        }
        #else
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "luna") { [weak self] callbackURL, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                }
                Logger.shared.log("MAL auth error: \(error.localizedDescription)", type: "Error")
                return
            }

            guard let callbackURL = callbackURL,
                  let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                DispatchQueue.main.async {
                    self.authError = "Invalid MAL callback - failed to extract code"
                    self.isAuthenticating = false
                }
                return
            }

            Logger.shared.log("MAL code extracted successfully", type: "Tracker")
            self.handleMALCallback(code: code)
        }

        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        session.start()
        webAuthSession = session
        #endif
    }

    func handleMALCallback(code: String) {
        isAuthenticating = true
        Task {
            do {
                let token = try await exchangeMALCode(code)
                let user = try await fetchMALUser(token: token.accessToken)
                let account = TrackerAccount(
                    service: .myAnimeList,
                    username: user.name,
                    accessToken: token.accessToken,
                    refreshToken: token.refreshToken,
                    expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                    userId: String(user.id)
                )

                await MainActor.run {
                    self.trackerState.addOrUpdateAccount(account)
                    self.saveTrackerState()
                    self.isAuthenticating = false
                    self.authError = nil
                    self.pendingMALCodeVerifier = nil
                    Logger.shared.log("MAL account saved", type: "Tracker")
                }
            } catch {
                await MainActor.run {
                    self.authError = "MAL auth failed: \(error.localizedDescription)"
                    self.isAuthenticating = false
                    Logger.shared.log("MAL auth error: \(error.localizedDescription)", type: "Error")
                }
            }
        }
    }

    func handleMALPinAuth(token: String) {
        isAuthenticating = true
        Task {
            do {
                let user = try await fetchMALUser(token: token)
                let account = TrackerAccount(
                    service: .myAnimeList,
                    username: user.name,
                    accessToken: token,
                    refreshToken: nil,
                    expiresAt: Date().addingTimeInterval(365 * 24 * 3600),
                    userId: String(user.id)
                )
                await MainActor.run {
                    self.trackerState.addOrUpdateAccount(account)
                    self.saveTrackerState()
                    self.isAuthenticating = false
                    self.authError = nil
                }
            } catch {
                await MainActor.run {
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                }
            }
        }
    }

    private func exchangeMALCode(_ code: String) async throws -> MALAuthResponse {
        guard let verifier = pendingMALCodeVerifier else {
            throw NSError(domain: "MALAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing MAL code verifier"])
        }

        let url = URL(string: "https://myanimelist.net/v1/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "client_id": malClientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": malRedirectUri
        ]
        if let secret = malClientSecret {
            body["client_secret"] = secret
        }
        request.httpBody = formURLEncodedBody(body)

        let (data, response) = try await sendTrackerRequest(request, provider: .myAnimeList)
        guard response.statusCode == 200 else {
            let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw NSError(domain: "MALAuth", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "MAL token request failed: \(bodyPreview)"])
        }

        return try JSONDecoder().decode(MALAuthResponse.self, from: data)
    }

    private func refreshMALToken(_ refreshToken: String) async throws -> MALAuthResponse {
        let url = URL(string: "https://myanimelist.net/v1/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "client_id": malClientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        if let secret = malClientSecret {
            body["client_secret"] = secret
        }
        request.httpBody = formURLEncodedBody(body)

        let (data, response) = try await sendTrackerRequest(request, provider: .myAnimeList)
        guard response.statusCode == 200 else {
            let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw NSError(domain: "MALAuth", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "MAL token refresh failed: \(bodyPreview)"])
        }

        return try JSONDecoder().decode(MALAuthResponse.self, from: data)
    }

    private func fetchMALUser(token: String) async throws -> MALUser {
        let url = URL(string: "https://api.myanimelist.net/v2/users/@me")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await sendTrackerRequest(request, provider: .myAnimeList)
        guard response.statusCode == 200 else {
            throw NSError(domain: "MALAuth", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "MAL user request failed"])
        }

        return try JSONDecoder().decode(MALUser.self, from: data)
    }

    // MARK: - Trakt Authentication

    private static func makeOAuthState() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

#if os(tvOS)
    private struct TraktDeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURL = "verification_url"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private func startTraktDeviceAuth() {
        guard !traktClientId.isEmpty, !traktClientSecret.isEmpty else {
            authError = "Add TRAKT_CLIENT_ID and TRAKT_CLIENT_SECRET to Build.local.xcconfig before connecting Trakt."
            return
        }

        traktDeviceAuthTask?.cancel()
        authError = nil
        isAuthenticating = true
        traktDeviceUserCode = nil
        traktDeviceVerificationURL = nil

        traktDeviceAuthTask = Task { [weak self] in
            guard let self else { return }
            do {
                let device = try await self.requestTraktDeviceCode()
                await MainActor.run {
                    self.traktDeviceUserCode = device.userCode
                    self.traktDeviceVerificationURL = device.verificationURL
                    let session = ASWebAuthenticationSession(
                        url: device.verificationURL,
                        callbackURLScheme: nil
                    ) { _, _ in }
                    self.webAuthSession = session
                    _ = session.start()
                }

                let token = try await self.pollTraktDeviceToken(device)
                let user = try await self.fetchTraktUser(token: token.accessToken)
                let account = TrackerAccount(
                    service: .trakt,
                    username: user.username,
                    accessToken: token.accessToken,
                    refreshToken: token.refreshToken,
                    expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
                    userId: user.ids.trakt.map(String.init) ?? user.ids.slug
                )
                await MainActor.run {
                    self.trackerState.addOrUpdateAccount(account)
                    self.saveTrackerState()
                    self.isAuthenticating = false
                    self.authError = nil
                    self.traktDeviceUserCode = nil
                    self.traktDeviceVerificationURL = nil
                    self.webAuthSession = nil
                    self.traktDeviceAuthTask = nil
                    Logger.shared.log("Trakt device authorization completed", type: "Tracker")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isAuthenticating = false
                    self.traktDeviceAuthTask = nil
                }
            } catch {
                await MainActor.run {
                    self.authError = "Trakt device authorization failed: \(error.localizedDescription)"
                    self.isAuthenticating = false
                    self.webAuthSession = nil
                    self.traktDeviceAuthTask = nil
                }
            }
        }
    }

    private func requestTraktDeviceCode() async throws -> TraktDeviceCodeResponse {
        var request = URLRequest(url: URL(string: "https://api.trakt.tv/oauth/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": traktClientId])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw NSError(
                domain: "TraktDeviceAuth",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "Trakt could not start device authorization (\(status))."]
            )
        }
        return try JSONDecoder().decode(TraktDeviceCodeResponse.self, from: data)
    }

    private func pollTraktDeviceToken(_ device: TraktDeviceCodeResponse) async throws -> TraktAuthResponse {
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
        var interval = max(1, device.interval)

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

            var request = URLRequest(url: URL(string: "https://api.trakt.tv/oauth/device/token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "code": device.deviceCode,
                "client_id": traktClientId,
                "client_secret": traktClientSecret
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            switch status {
            case 200:
                return try JSONDecoder().decode(TraktAuthResponse.self, from: data)
            case 400:
                continue
            case 429:
                interval += 1
                continue
            case 404:
                throw NSError(domain: "TraktDeviceAuth", code: status, userInfo: [NSLocalizedDescriptionKey: "The Trakt device code is invalid."])
            case 409:
                throw NSError(domain: "TraktDeviceAuth", code: status, userInfo: [NSLocalizedDescriptionKey: "The Trakt device code was already used."])
            case 410:
                throw NSError(domain: "TraktDeviceAuth", code: status, userInfo: [NSLocalizedDescriptionKey: "The Trakt device code expired."])
            case 418:
                throw NSError(domain: "TraktDeviceAuth", code: status, userInfo: [NSLocalizedDescriptionKey: "Trakt authorization was declined."])
            default:
                throw NSError(domain: "TraktDeviceAuth", code: status, userInfo: [NSLocalizedDescriptionKey: "Trakt device authorization failed (\(status))."])
            }
        }

        throw NSError(domain: "TraktDeviceAuth", code: 410, userInfo: [NSLocalizedDescriptionKey: "The Trakt device code expired."])
    }
#endif

    func getTraktAuthURL(state: String? = nil) -> URL? {
        guard !traktClientId.isEmpty, !traktClientSecret.isEmpty else {
            authError = "Add TRAKT_CLIENT_ID and TRAKT_CLIENT_SECRET to Build.local.xcconfig before connecting Trakt."
            return nil
        }

        var components = URLComponents(string: "https://trakt.tv/oauth/authorize")
        var queryItems = [
            URLQueryItem(name: "client_id", value: traktClientId),
            URLQueryItem(name: "redirect_uri", value: traktRedirectUri),
            URLQueryItem(name: "response_type", value: "code")
        ]
        if let state, !state.isEmpty {
            queryItems.append(URLQueryItem(name: "state", value: state))
        }
        components?.queryItems = queryItems
        let url = components?.url
        // OAuth state must stay out of logs even though it is short-lived.
        Logger.shared.log("Trakt authorization URL prepared", type: "Tracker")
        return url
    }

    func startTraktAuth() {
#if os(tvOS)
        startTraktDeviceAuth()
#else
        let oauthState = Self.makeOAuthState()
        pendingTraktOAuthState = oauthState
        guard let url = getTraktAuthURL(state: oauthState) else {
            pendingTraktOAuthState = nil
            return
        }
        authError = nil
        isAuthenticating = true

        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "luna") { [weak self] callbackURL, error in
            guard let self = self else { return }

            if let error = error {
                self.pendingTraktOAuthState = nil
                DispatchQueue.main.async {
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                }
                Logger.shared.log("Trakt auth error: \(error.localizedDescription)", type: "Error")
                return
            }

            guard let callbackURL = callbackURL else {
                self.pendingTraktOAuthState = nil
                Logger.shared.log("Trakt callback URL is nil", type: "Error")
                DispatchQueue.main.async {
                    self.authError = "Trakt callback URL is nil"
                    self.isAuthenticating = false
                }
                return
            }

            Logger.shared.log("Trakt authorization callback received", type: "Tracker")

            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                self.pendingTraktOAuthState = nil
                Logger.shared.log("Failed to extract code from Trakt callback", type: "Error")
                DispatchQueue.main.async {
                    self.authError = "Invalid Trakt callback - failed to extract code"
                    self.isAuthenticating = false
                }
                return
            }

            let callbackState = components.queryItems?.first(where: { $0.name == "state" })?.value
            if let expectedState = self.pendingTraktOAuthState,
               callbackState != expectedState {
                self.pendingTraktOAuthState = nil
                Logger.shared.log("Rejected Trakt callback with invalid OAuth state.", type: "Error")
                DispatchQueue.main.async {
                    self.authError = "Invalid Trakt callback state. Please try connecting again."
                    self.isAuthenticating = false
                }
                return
            }

            Logger.shared.log("Trakt code extracted successfully", type: "Tracker")
            self.handleTraktCallback(code: code)
        }

        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        session.start()
        webAuthSession = session
#endif
    }

    func handleTraktCallback(code: String) {
        isAuthenticating = true
        Logger.shared.log("Trakt callback received with code", type: "Tracker")
        Task {
            do {
                let token = try await exchangeTraktCode(code)
                Logger.shared.log("Trakt token exchanged successfully", type: "Tracker")
                let user = try await fetchTraktUser(token: token.accessToken)
                Logger.shared.log("Trakt user fetched: \(user.username)", type: "Tracker")
                let account = TrackerAccount(
                    service: .trakt,
                    username: user.username,
                    accessToken: token.accessToken,
                    refreshToken: token.refreshToken,
                    expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
                    userId: user.ids.trakt.map(String.init) ?? user.ids.slug
                )
                await MainActor.run {
                    self.trackerState.addOrUpdateAccount(account)
                    self.saveTrackerState()
                    self.pendingTraktOAuthState = nil
                    self.isAuthenticating = false
                    self.authError = nil
                    Logger.shared.log("Trakt account saved", type: "Tracker")
                }
            } catch {
                await MainActor.run {
                    self.pendingTraktOAuthState = nil
                    self.authError = "Trakt auth failed: \(error.localizedDescription)"
                    self.isAuthenticating = false
                    Logger.shared.log("Trakt auth error: \(error.localizedDescription)", type: "Error")
                }
            }
        }
    }

    func handleTraktPinAuth(token: String) {
        isAuthenticating = true
        Task {
            do {
                let user = try await fetchTraktUser(token: token)
                let account = TrackerAccount(
                    service: .trakt,
                    username: user.username,
                    accessToken: token,
                    refreshToken: nil,
                    expiresAt: Date().addingTimeInterval(365 * 24 * 3600),
                    userId: user.ids.trakt.map(String.init) ?? user.ids.slug
                )
                await MainActor.run {
                    self.trackerState.addOrUpdateAccount(account)
                    self.saveTrackerState()
                    self.isAuthenticating = false
                    self.authError = nil
                }
            } catch {
                await MainActor.run {
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                }
            }
        }
    }

    private func exchangeTraktCode(_ code: String) async throws -> TraktAuthResponse {
        guard !traktClientId.isEmpty, !traktClientSecret.isEmpty else {
            throw NSError(domain: "TraktAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Trakt credentials are not configured."])
        }

        let url = URL(string: "https://api.trakt.tv/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "code": code,
            "client_id": traktClientId,
            "client_secret": traktClientSecret,
            "redirect_uri": traktRedirectUri,
            "grant_type": "authorization_code"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.shared.log("Exchanging Trakt code for token", type: "Tracker")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? -1

        Logger.shared.log("Trakt token response status: \(statusCode)", type: "Tracker")
        Logger.shared.log("Trakt response data length: \(data.count) bytes", type: "Tracker")

        guard statusCode == 200 else {
            let errorMsg = "Trakt token request failed with status \(statusCode)"
            Logger.shared.log(errorMsg, type: "Error")
            throw NSError(domain: "TraktAuth", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        do {
            return try JSONDecoder().decode(TraktAuthResponse.self, from: data)
        } catch {
            Logger.shared.log("Failed to decode Trakt response: \(error.localizedDescription)", type: "Error")
            throw error
        }
    }

    private func refreshTraktToken(_ refreshToken: String) async throws -> TraktAuthResponse {
        guard !traktClientId.isEmpty, !traktClientSecret.isEmpty else {
            throw NSError(domain: "TraktAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Trakt credentials are not configured."])
        }

        let url = URL(string: "https://api.trakt.tv/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": refreshToken,
            "client_id": traktClientId,
            "client_secret": traktClientSecret,
            "redirect_uri": traktRedirectUri,
            "grant_type": "refresh_token"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw NSError(
                domain: "TraktAuth",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Trakt token refresh failed with status \(statusCode): \(bodyPreview)"]
            )
        }

        return try JSONDecoder().decode(TraktAuthResponse.self, from: data)
    }

    private func fetchTraktUser(token: String) async throws -> TraktUser {
        guard !traktClientId.isEmpty else {
            throw NSError(domain: "TraktAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "TRAKT_CLIENT_ID is not configured."])
        }

        let url = URL(string: "https://api.trakt.tv/users/settings")!
        var request = URLRequest(url: url)
        request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")

        Logger.shared.log("Fetching Trakt user", type: "Tracker")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? -1

        Logger.shared.log("Trakt user response status: \(statusCode)", type: "Tracker")
        Logger.shared.log("Trakt user response data length: \(data.count) bytes", type: "Tracker")

        guard (200...299).contains(statusCode) else {
            let bodyPreview = responseBodyPreview(from: data)
            throw NSError(
                domain: "TraktAuth",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Trakt user request failed with status \(statusCode): \(bodyPreview)"]
            )
        }

        do {
            return try JSONDecoder().decode(TraktUserSettingsResponse.self, from: data).user
        } catch {
            Logger.shared.log("Failed to decode Trakt user response: \(error.localizedDescription)", type: "Error")
            throw error
        }
    }

    // MARK: - Sync Methods

    func cacheAniListId(tmdbId: Int, anilistId: Int) {
        guard anilistId > 0 else {
            Logger.shared.log("Skipping TMDB \(tmdbId) AniList cache for provider-safe fallback id \(anilistId)", type: "Tracker")
            return
        }
        anilistIdCacheQueue.sync {
            anilistIdCache[tmdbId] = anilistId
        }
    }

    func cachedAniListId(for tmdbId: Int) -> Int? {
        var id: Int? = nil
        anilistIdCacheQueue.sync {
            id = anilistIdCache[tmdbId]
        }
        return id
    }
    
    // Season-specific AniList ID caching for anime with multiple entries
    func cacheAniListSeasonId(tmdbId: Int, seasonNumber: Int, anilistId: Int) {
        guard anilistId > 0 else {
            Logger.shared.log("Skipping TMDB \(tmdbId) S\(seasonNumber) AniList season cache for provider-safe fallback id \(anilistId)", type: "Tracker")
            return
        }
        let key = "\(tmdbId)_\(seasonNumber)"
        anilistSeasonIdCacheQueue.sync {
            anilistSeasonIdCache[key] = anilistId
        }
    }
    
    func cachedAniListSeasonId(tmdbId: Int, seasonNumber: Int) -> Int? {
        let key = "\(tmdbId)_\(seasonNumber)"
        var id: Int? = nil
        anilistSeasonIdCacheQueue.sync {
            id = anilistSeasonIdCache[key]
        }
        return id
    }
    
    // Register AniList anime data when a show page loads (for accurate season-based syncing)
    func registerAniListAnimeData(tmdbId: Int, seasons: [(seasonNumber: Int, anilistId: Int)]) {
        for season in seasons {
            cacheAniListSeasonId(tmdbId: tmdbId, seasonNumber: season.seasonNumber, anilistId: season.anilistId)
        }
        Logger.shared.log("Registered \(seasons.count) AniList season mappings for TMDB \(tmdbId)", type: "Tracker")
    }

    func resolveMyAnimeListAnimeId(fromAniListId aniListId: Int) async -> Int? {
        await getMyAnimeListId(fromAniListId: aniListId, mediaType: "ANIME")
    }

    func cachedMyAnimeListAnimeId(fromAniListId aniListId: Int) -> Int? {
        cachedMyAnimeListId(fromAniListId: aniListId, mediaType: "ANIME")
    }

#if !os(tvOS)
    func syncMangaProgress(title: String, chapterNumber: Int, totalChapters: Int? = nil, format: String? = nil, routeKey: String? = nil, knownAniListId: Int? = nil, knownMALId: Int? = nil) {
        guard !isBackupRestoreSyncSuppressed() else {
            ReaderLogger.shared.log("Skipping manga sync during backup restore for \(title) ch \(chapterNumber)", type: "Tracker")
            return
        }

        guard trackerState.syncEnabled else {
            ReaderLogger.shared.log("Skipping manga sync (sync disabled) for \(title) ch \(chapterNumber)", type: "Tracker")
            return
        }

        let accounts = trackerState.accounts.filter { $0.isConnected && ($0.service == .anilist || $0.service == .myAnimeList) }
        guard !accounts.isEmpty else {
            ReaderLogger.shared.log("Skipping manga sync (no connected manga tracker account) for \(title) ch \(chapterNumber)", type: "Tracker")
            return
        }

        ReaderLogger.shared.log("Starting manga sync for \(title) ch \(chapterNumber) across \(accounts.count) account(s)", type: "Tracker")

        Task {
            guard let match = await resolveMangaTrackerMatch(
                title: title,
                totalChapters: totalChapters,
                format: format,
                routeKey: routeKey,
                knownAniListId: knownAniListId,
                knownMALId: knownMALId
            ) else {
                ReaderLogger.shared.log("Skipping manga sync for \(title): no confident tracker match", type: "Tracker")
                return
            }

            for account in accounts {
                switch account.service {
                case .anilist:
                    if let aniListId = match.aniListId {
                        await sendMangaProgressToAniList(mediaId: aniListId, chapterNumber: chapterNumber, account: account)
                    } else {
                        ReaderLogger.shared.log("Skipping AniList manga sync for \(title): resolved match has no AniList ID", type: "Tracker")
                    }
                case .myAnimeList:
                    if let malId = match.malId {
                        await sendMangaProgressToMAL(malId: malId, chapterNumber: chapterNumber, account: account)
                    } else if let aniListId = match.aniListId {
                        await sendMangaProgressToMAL(aniListId: aniListId, chapterNumber: chapterNumber, account: account)
                    } else {
                        ReaderLogger.shared.log("Skipping MAL manga sync for \(title): resolved match has no MAL ID", type: "Tracker")
                    }
                case .trakt:
                    break
                }
            }
        }
    }

    /// Sync manga reading progress using a known AniList media ID (skips title lookup).
    func syncMangaProgress(aniListId: Int, malId: Int? = nil, title: String? = nil, chapterNumber: Int, totalChapters: Int? = nil, format: String? = nil, routeKey: String? = nil) {
        guard !isBackupRestoreSyncSuppressed() else {
            ReaderLogger.shared.log("Skipping manga sync during backup restore for aniListId \(aniListId) ch \(chapterNumber)", type: "Tracker")
            return
        }

        guard aniListId > 0 else {
            if let title {
                syncMangaProgress(
                    title: title,
                    chapterNumber: chapterNumber,
                    totalChapters: totalChapters,
                    format: format,
                    routeKey: routeKey,
                    knownAniListId: nil,
                    knownMALId: malId
                )
            } else {
                ReaderLogger.shared.log("Skipping manga sync for generated id \(aniListId): missing title for tracker resolution", type: "Tracker")
            }
            return
        }

        guard trackerState.syncEnabled else {
            ReaderLogger.shared.log("Skipping manga sync (sync disabled) for aniListId \(aniListId) ch \(chapterNumber)", type: "Tracker")
            return
        }

        let accounts = trackerState.accounts.filter { $0.isConnected && ($0.service == .anilist || $0.service == .myAnimeList) }
        guard !accounts.isEmpty else {
            ReaderLogger.shared.log("Skipping manga sync (no connected manga tracker account) for aniListId \(aniListId) ch \(chapterNumber)", type: "Tracker")
            return
        }

        ReaderLogger.shared.log("Starting manga sync for aniListId \(aniListId) ch \(chapterNumber) across \(accounts.count) account(s)", type: "Tracker")

        Task {
            for account in accounts {
                switch account.service {
                case .anilist:
                    await sendMangaProgressToAniList(mediaId: aniListId, chapterNumber: chapterNumber, account: account)
                case .myAnimeList:
                    if let malId {
                        await sendMangaProgressToMAL(malId: malId, chapterNumber: chapterNumber, account: account)
                    } else {
                        await sendMangaProgressToMAL(aniListId: aniListId, chapterNumber: chapterNumber, account: account)
                    }
                case .trakt:
                    break
                }
            }
        }
    }
#endif

    private static func normalizedRatingOutOf10(_ rating: Double) -> Double {
        let finiteValue = rating.isFinite ? rating : 0.5
        let halfStepValue = (finiteValue * 2).rounded() / 2
        return max(0.5, min(10, halfStepValue))
    }

    private static func aniListScore(from rating: Double) -> Double {
        normalizedRatingOutOf10(rating)
    }

    private static func myAnimeListScore(from rating: Double) -> Int {
        max(1, min(10, Int(normalizedRatingOutOf10(rating).rounded())))
    }

    private static func ratingDisplayString(_ rating: Double) -> String {
        let normalized = normalizedRatingOutOf10(rating)
        if normalized.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(normalized))
        }
        return String(format: "%.1f", normalized)
    }

    func syncUserRating(tmdbId: Int, ratingOutOf10: Double, isAnime: Bool) {
        let clampedRating = Self.normalizedRatingOutOf10(ratingOutOf10)

        guard trackerState.autoSyncRatings else {
            Logger.shared.log("Skipping auto rating sync (auto sync ratings disabled) for TMDB \(tmdbId)", type: "Tracker")
            return
        }

        guard isAnime else {
            Logger.shared.log("Skipping remote rating sync for non-anime TMDB \(tmdbId)", type: "Tracker")
            return
        }

        guard !isBackupRestoreSyncSuppressed() else {
            Logger.shared.log("Skipping rating sync during backup restore for TMDB \(tmdbId)", type: "Tracker")
            return
        }

        guard trackerState.syncEnabled else {
            Logger.shared.log("Skipping rating sync (sync disabled) for TMDB \(tmdbId)", type: "Tracker")
            return
        }

        let accounts = trackerState.accounts.filter { $0.isConnected && ($0.service == .anilist || $0.service == .myAnimeList) }
        guard !accounts.isEmpty else {
            Logger.shared.log("Skipping rating sync (no connected AniList/MAL account) for TMDB \(tmdbId)", type: "Tracker")
            return
        }

        Task {
            var resolvedAniListId = cachedAniListId(for: tmdbId)
            if resolvedAniListId == nil {
                resolvedAniListId = await getAniListMediaId(tmdbId: tmdbId)
            }
            guard let aniListId = resolvedAniListId else {
                Logger.shared.log("Could not find AniList ID for rating sync, TMDB \(tmdbId)", type: "Tracker")
                return
            }

            for account in accounts {
                switch account.service {
                case .anilist:
                    await saveAniListRatingAndNote(account: account, anilistId: aniListId, rating: clampedRating, note: nil)
                case .myAnimeList:
                    guard let malId = await getMyAnimeListId(fromAniListId: aniListId, mediaType: "ANIME") else {
                        Logger.shared.log("Could not find MAL anime ID for rating sync, AniList \(aniListId)", type: "Tracker")
                        continue
                    }
                    await saveMALAnimeRatingAndNote(account: account, malId: malId, rating: clampedRating, note: nil)
                case .trakt:
                    break
                }
            }
        }
    }

    func syncRatingAndNote(tmdbId: Int, ratingOutOf10: Double, note: String, service: TrackerService, isAnime: Bool) {
        let clampedRating = Self.normalizedRatingOutOf10(ratingOutOf10)

        guard isAnime else {
            Logger.shared.log("Skipping rating note sync for non-anime TMDB \(tmdbId)", type: "Tracker")
            return
        }

        guard !isBackupRestoreSyncSuppressed() else {
            Logger.shared.log("Skipping rating note sync during backup restore for TMDB \(tmdbId)", type: "Tracker")
            return
        }

        guard trackerState.syncEnabled else {
            Logger.shared.log("Skipping rating note sync (sync disabled) for TMDB \(tmdbId)", type: "Tracker")
            return
        }

        guard let account = trackerState.getAccount(for: service), account.isConnected else {
            Logger.shared.log("Skipping rating note sync (no connected \(service.displayName) account) for TMDB \(tmdbId)", type: "Tracker")
            return
        }

        Task {
            var resolvedAniListId = cachedAniListId(for: tmdbId)
            if resolvedAniListId == nil {
                resolvedAniListId = await getAniListMediaId(tmdbId: tmdbId)
            }
            guard let aniListId = resolvedAniListId else {
                Logger.shared.log("Could not find AniList ID for rating note sync, TMDB \(tmdbId)", type: "Tracker")
                return
            }

            switch service {
            case .anilist:
                await saveAniListRatingAndNote(account: account, anilistId: aniListId, rating: clampedRating, note: note)
            case .myAnimeList:
                guard let malId = await getMyAnimeListId(fromAniListId: aniListId, mediaType: "ANIME") else {
                    Logger.shared.log("Could not find MAL anime ID for rating note sync, AniList \(aniListId)", type: "Tracker")
                    return
                }
                await saveMALAnimeRatingAndNote(account: account, malId: malId, rating: clampedRating, note: note)
            case .trakt:
                break
            }
        }
    }

#if !os(tvOS)
    func syncReaderMangaRating(
        localMangaId: Int,
        title: String,
        ratingOutOf10: Double,
        note: String? = nil,
        service: TrackerService? = nil,
        totalChapters: Int? = nil,
        format: String? = nil,
        routeKey: String? = nil,
        knownAniListId: Int? = nil,
        knownMALId: Int? = nil,
        isAutomatic: Bool = true
    ) {
        guard ratingOutOf10.isFinite, ratingOutOf10 > 0 else {
            ReaderLogger.shared.log("Skipping reader rating sync for \(title): invalid rating \(ratingOutOf10)", type: "Tracker")
            return
        }

        let clampedRating = Self.normalizedRatingOutOf10(ratingOutOf10)

        if isAutomatic, !trackerState.autoSyncReaderRatings {
            ReaderLogger.shared.log("Skipping reader rating auto-sync (disabled) for \(title)", type: "Tracker")
            return
        }

        guard !isBackupRestoreSyncSuppressed() else {
            ReaderLogger.shared.log("Skipping reader rating sync during backup restore for \(title)", type: "Tracker")
            return
        }

        guard trackerState.syncEnabled else {
            ReaderLogger.shared.log("Skipping reader rating sync (sync disabled) for \(title)", type: "Tracker")
            return
        }

        let allowedServices: Set<TrackerService> = service.map { [$0] } ?? [.anilist, .myAnimeList]
        let accounts = trackerState.accounts.filter {
            $0.isConnected && allowedServices.contains($0.service) && ($0.service == .anilist || $0.service == .myAnimeList)
        }
        guard !accounts.isEmpty else {
            ReaderLogger.shared.log("Skipping reader rating sync (no connected AniList/MAL account) for \(title)", type: "Tracker")
            return
        }

        Task {
            guard let match = await resolveMangaTrackerMatch(
                title: title,
                totalChapters: totalChapters,
                format: format,
                routeKey: routeKey,
                knownAniListId: knownAniListId,
                knownMALId: knownMALId
            ) else {
                ReaderLogger.shared.log("Skipping reader rating sync for \(title): no confident tracker match", type: "Tracker")
                return
            }

            MangaReadingProgressManager.shared.updateTrackerMatch(
                mangaId: localMangaId,
                aniListId: match.aniListId,
                malId: match.malId,
                confidence: match.confidence
            )

            var resolvedAniListId = match.aniListId
            var resolvedMALId = match.malId

            for account in accounts {
                switch account.service {
                case .anilist:
                    if resolvedAniListId == nil, let malId = resolvedMALId {
                        resolvedAniListId = await getAniListId(fromMALId: malId, mediaType: "MANGA")
                    }
                    guard let aniListId = resolvedAniListId else {
                        ReaderLogger.shared.log("Skipping AniList reader rating sync for \(title): no AniList manga ID", type: "Tracker")
                        continue
                    }
                    MangaReadingProgressManager.shared.updateTrackerMatch(
                        mangaId: localMangaId,
                        aniListId: aniListId,
                        malId: resolvedMALId,
                        confidence: match.confidence
                    )
                    await saveAniListMangaRatingAndNote(account: account, anilistId: aniListId, rating: clampedRating, note: note)

                case .myAnimeList:
                    if resolvedMALId == nil, let aniListId = resolvedAniListId {
                        resolvedMALId = await getMyAnimeListId(fromAniListId: aniListId, mediaType: "MANGA")
                    }
                    guard let malId = resolvedMALId else {
                        ReaderLogger.shared.log("Skipping MAL reader rating sync for \(title): no MAL manga ID", type: "Tracker")
                        continue
                    }
                    MangaReadingProgressManager.shared.updateTrackerMatch(
                        mangaId: localMangaId,
                        aniListId: resolvedAniListId,
                        malId: malId,
                        confidence: match.confidence
                    )
                    await saveMALMangaRatingAndNote(account: account, malId: malId, rating: clampedRating, note: note)

                case .trakt:
                    break
                }
            }
        }
    }
#endif

#if !os(tvOS)
    private func saveAniListMangaRatingAndNote(account: TrackerAccount, anilistId: Int, rating: Double, note: String?) async {
        let clampedRating = Self.normalizedRatingOutOf10(rating)
        let displayRating = Self.ratingDisplayString(clampedRating)
        do {
            let firstResult = try await sendAniListRatingAndNoteRequest(
                account: account,
                anilistId: anilistId,
                rating: clampedRating,
                note: note,
                includeCurrentStatus: false
            )

            if firstResult.succeeded {
                ReaderLogger.shared.log("Synced AniList manga rating \(displayRating)/10\(note == nil ? "" : " and notes") for mediaId \(anilistId)", type: "Tracker")
                return
            }

            if firstResult.statusCode == 400 {
                ReaderLogger.shared.log("AniList manga rating sync returned 400; retrying with CURRENT status for mediaId \(anilistId): \(firstResult.bodyPreview)", type: "Tracker")
                let retryResult = try await sendAniListRatingAndNoteRequest(
                    account: account,
                    anilistId: anilistId,
                    rating: clampedRating,
                    note: note,
                    includeCurrentStatus: true
                )

                if retryResult.succeeded {
                    ReaderLogger.shared.log("Synced AniList manga rating \(displayRating)/10\(note == nil ? "" : " and notes") for mediaId \(anilistId) after creating a list entry", type: "Tracker")
                } else if let graphQLError = retryResult.graphQLError {
                    ReaderLogger.shared.log("AniList manga rating sync error after retry: \(graphQLError)", type: "Tracker")
                } else {
                    ReaderLogger.shared.log("AniList manga rating sync returned status \(retryResult.statusCode) after retry: \(retryResult.bodyPreview)", type: "Tracker")
                }
                return
            }

            if let graphQLError = firstResult.graphQLError {
                ReaderLogger.shared.log("AniList manga rating sync error: \(graphQLError)", type: "Tracker")
            } else {
                ReaderLogger.shared.log("AniList manga rating sync returned status \(firstResult.statusCode): \(firstResult.bodyPreview)", type: "Tracker")
            }
        } catch {
            ReaderLogger.shared.log("Failed to sync AniList manga rating \(anilistId): \(error.localizedDescription)", type: "Error")
        }
    }
#endif

    private func saveAniListRatingAndNote(account: TrackerAccount, anilistId: Int, rating: Double, note: String?) async {
        let clampedRating = Self.normalizedRatingOutOf10(rating)
        let displayRating = Self.ratingDisplayString(clampedRating)
        do {
            let firstResult = try await sendAniListRatingAndNoteRequest(
                account: account,
                anilistId: anilistId,
                rating: clampedRating,
                note: note,
                includeCurrentStatus: false
            )

            if firstResult.succeeded {
                Logger.shared.log("Synced AniList rating \(displayRating)/10\(note == nil ? "" : " and notes") for mediaId \(anilistId)", type: "Tracker")
                return
            }

            if firstResult.statusCode == 400 {
                Logger.shared.log("AniList rating sync returned 400; retrying with CURRENT status for mediaId \(anilistId): \(firstResult.bodyPreview)", type: "Tracker")
                let retryResult = try await sendAniListRatingAndNoteRequest(
                    account: account,
                    anilistId: anilistId,
                    rating: clampedRating,
                    note: note,
                    includeCurrentStatus: true
                )

                if retryResult.succeeded {
                    Logger.shared.log("Synced AniList rating \(displayRating)/10\(note == nil ? "" : " and notes") for mediaId \(anilistId) after creating a list entry", type: "Tracker")
                } else if let graphQLError = retryResult.graphQLError {
                    Logger.shared.log("AniList rating sync error after retry: \(graphQLError)", type: "Tracker")
                } else {
                    Logger.shared.log("AniList rating sync returned status \(retryResult.statusCode) after retry: \(retryResult.bodyPreview)", type: "Tracker")
                }
                return
            }

            if let graphQLError = firstResult.graphQLError {
                Logger.shared.log("AniList rating sync error: \(graphQLError)", type: "Tracker")
            } else {
                Logger.shared.log("AniList rating sync returned status \(firstResult.statusCode): \(firstResult.bodyPreview)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync AniList rating \(anilistId): \(error.localizedDescription)", type: "Error")
        }
    }

    private func sendAniListRatingAndNoteRequest(
        account: TrackerAccount,
        anilistId: Int,
        rating: Double,
        note: String?,
        includeCurrentStatus: Bool
    ) async throws -> AniListRatingSyncResponse {
        let variableDeclaration = note == nil
            ? "($mediaId: Int, $score: Float)"
            : "($mediaId: Int, $score: Float, $notes: String)"
        let statusArgument = includeCurrentStatus ? ",\n                status: CURRENT" : ""
        let notesArgument = note == nil ? "" : ",\n                notes: $notes"
        let mutation = """
        mutation \(variableDeclaration) {
            SaveMediaListEntry(
                mediaId: $mediaId\(statusArgument),
                score: $score\(notesArgument)
            ) {
                id
                score
                notes
            }
        }
        """
        var variables: [String: Any] = [
            "mediaId": anilistId,
            "score": Self.aniListScore(from: rating)
        ]
        if let note {
            variables["notes"] = note
        }

        let url = URL(string: "https://graphql.anilist.co")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": mutation, "variables": variables])

        let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
        let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        let graphQLError = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { json -> String? in
                guard let errors = json["errors"] as? [[String: Any]], !errors.isEmpty else {
                    return nil
                }
                return errors.first?["message"] as? String ?? "Unknown error"
            }

        return AniListRatingSyncResponse(
            statusCode: response.statusCode,
            bodyPreview: bodyPreview,
            graphQLError: graphQLError
        )
    }

    private func sendMALListStatusRequest(
        account: TrackerAccount,
        mediaPath: String,
        mediaId: Int,
        values: [String: String],
        allowsRefreshRetry: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let account = try await refreshedMALAccountIfNeeded(account)
        let url = URL(string: "https://api.myanimelist.net/v2/\(mediaPath)/\(mediaId)/my_list_status")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncodedBody(values)

        let (data, response) = try await sendTrackerRequest(request, provider: .myAnimeList)
        if response.statusCode == 401, allowsRefreshRetry {
            let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            Logger.shared.log("MAL \(mediaPath) list status returned 401; refreshing token and retrying once: \(bodyPreview)", type: "Tracker")
            let refreshed = try await refreshedMALAccountIfNeeded(account, force: true)
            return try await sendMALListStatusRequest(
                account: refreshed,
                mediaPath: mediaPath,
                mediaId: mediaId,
                values: values,
                allowsRefreshRetry: false
            )
        }

        return (data, response)
    }

    private func saveMALAnimeRatingAndNote(account: TrackerAccount, malId: Int, rating: Double, note: String?) async {
        let clampedRating = Self.normalizedRatingOutOf10(rating)
        let malRating = Self.myAnimeListScore(from: clampedRating)
        let displayRating = Self.ratingDisplayString(clampedRating)
        var values = [
            "score": String(malRating)
        ]
        if let note {
            values["comments"] = note
        }

        do {
            let (data, response) = try await sendMALListStatusRequest(
                account: account,
                mediaPath: "anime",
                mediaId: malId,
                values: values
            )
            if (200...299).contains(response.statusCode) {
                let malSuffix = malRating == Int(clampedRating) && clampedRating.truncatingRemainder(dividingBy: 1) == 0
                    ? ""
                    : " as \(malRating)/10"
                Logger.shared.log("Synced MAL rating \(displayRating)/10\(malSuffix)\(note == nil ? "" : " and comments") for animeId \(malId)", type: "Tracker")
            } else {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                Logger.shared.log("MAL rating sync returned status \(response.statusCode): \(bodyPreview)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync MAL rating \(malId): \(error.localizedDescription)", type: "Error")
        }
    }

#if !os(tvOS)
    private func sendMangaProgressToAniList(mediaId: Int, chapterNumber: Int, account: TrackerAccount) async {
        let mutation = """
        mutation {
            SaveMediaListEntry(
                mediaId: \(mediaId),
                progress: \(chapterNumber),
                status: CURRENT
            ) {
                id
                progress
                status
            }
        }
        """

        do {
            let url = URL(string: "https://graphql.anilist.co")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")

            let body: [String: Any] = ["query": mutation]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            if response.statusCode == 200 {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                    let errorMsg = (errors.first?["message"] as? String) ?? "Unknown error"
                    ReaderLogger.shared.log("AniList manga sync error: \(errorMsg)", type: "Tracker")
                } else {
                    ReaderLogger.shared.log("Synced manga to AniList: chapter \(chapterNumber) for mediaId \(mediaId)", type: "Tracker")
                }
            } else {
                ReaderLogger.shared.log("AniList manga sync returned status \(response.statusCode)", type: "Tracker")
            }
        } catch {
            ReaderLogger.shared.log("Failed to sync manga to AniList: \(error.localizedDescription)", type: "Error")
        }
    }

    private func sendMangaProgressToMAL(aniListId: Int, chapterNumber: Int, account: TrackerAccount) async {
        guard let malId = await getMyAnimeListId(fromAniListId: aniListId, mediaType: "MANGA") else {
            ReaderLogger.shared.log("Could not find MAL manga ID for AniList manga \(aniListId)", type: "Tracker")
            return
        }

        await sendMangaProgressToMAL(malId: malId, chapterNumber: chapterNumber, account: account)
    }

    private func sendMangaProgressToMAL(malId: Int, chapterNumber: Int, account: TrackerAccount) async {
        await saveMALMangaProgress(account: account, malId: malId, chaptersRead: chapterNumber, status: "reading")
    }
#endif

    func syncWatchProgress(showId: Int, seasonNumber: Int, episodeNumber: Int, progress: Double, isMovie: Bool = false, isAnime: Bool = false, playbackContext: EpisodePlaybackContext? = nil) {
        guard !isBackupRestoreSyncSuppressed() else {
            Logger.shared.log("Skipping watch sync (backup restore in progress) for TMDB \(showId) S\(seasonNumber)E\(episodeNumber) \(Int(progress))%", type: "Tracker")
            return
        }

        guard trackerState.syncEnabled else {
            Logger.shared.log("Skipping watch sync (sync disabled) for TMDB \(showId) S\(seasonNumber)E\(episodeNumber) \(Int(progress))%", type: "Tracker")
            return
        }

        let connectedAccounts = trackerState.accounts.filter { $0.isConnected }
        guard !connectedAccounts.isEmpty else {
            Logger.shared.log("Skipping watch sync (no connected tracker accounts) for TMDB \(showId) S\(seasonNumber)E\(episodeNumber) \(Int(progress))%", type: "Tracker")
            return
        }

        guard shouldStartWatchSync(
            showId: showId,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            progress: progress,
            isMovie: isMovie,
            playbackContext: playbackContext
        ) else {
            return
        }

        let playbackProviderId = playbackContext?.anilistMediaId
        let playbackAniListMediaId = playbackProviderId.flatMap { $0 > 0 ? $0 : nil }
        let playbackMALMediaId = playbackProviderId.flatMap { $0 < 0 ? abs($0) : nil }
        let canSyncAnimeTrackers = isAnime || playbackAniListMediaId != nil || playbackMALMediaId != nil
        Logger.shared.log("Starting watch sync for TMDB \(showId) S\(seasonNumber)E\(episodeNumber) \(Int(progress))% across \(connectedAccounts.count) account(s)", type: "Tracker")     

        Task {
            for account in connectedAccounts {
                Logger.shared.log("Syncing \(account.service) account \(account.username) for TMDB \(showId) S\(seasonNumber)E\(episodeNumber)", type: "Tracker")
                switch account.service {
                case .anilist:
                    guard canSyncAnimeTrackers else {
                        Logger.shared.log("Skipping AniList watch sync for non-anime TMDB \(showId) S\(seasonNumber)E\(episodeNumber)", type: "Tracker")
                        continue
                    }
                    if let playbackContext,
                       let anilistMediaId = playbackAniListMediaId {
                        await syncToAniListMediaId(
                            account: account,
                            anilistId: anilistMediaId,
                            showId: showId,
                            seasonNumber: playbackContext.localSeasonNumber,
                            episodeNumber: playbackContext.localEpisodeNumber,
                            progress: progress
                        )
                    } else if let malMediaId = playbackMALMediaId {
                        Logger.shared.log("Skipping direct AniList watch sync for MAL fallback mediaId=\(malMediaId)", type: "Tracker")
                    } else {
                        await syncToAniList(account: account, showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber, progress: progress)
                    }
                case .myAnimeList:
                    guard canSyncAnimeTrackers else {
                        Logger.shared.log("Skipping MAL anime watch sync for non-anime TMDB \(showId) S\(seasonNumber)E\(episodeNumber)", type: "Tracker")
                        continue
                    }
                    if let playbackContext,
                       let malMediaId = playbackMALMediaId {
                        await syncToMyAnimeList(
                            account: account,
                            malId: malMediaId,
                            episodeNumber: playbackContext.localEpisodeNumber,
                            progress: progress
                        )
                    } else if let playbackContext,
                              let anilistMediaId = playbackAniListMediaId {
                        await syncToMyAnimeList(
                            account: account,
                            anilistId: anilistMediaId,
                            episodeNumber: playbackContext.localEpisodeNumber,
                            progress: progress
                        )
                    } else {
                        await syncToMyAnimeList(account: account, showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber, progress: progress)
                    }
                case .trakt:
                    let resolvedTrakt = resolvedTraktEpisodeNumbers(
                        seasonNumber: seasonNumber,
                        episodeNumber: episodeNumber,
                        playbackContext: playbackContext
                    )
                    if resolvedTrakt != nil || canUseTraktAnimeFallback(playbackContext) {
                        await syncToTrakt(
                            account: account,
                            showId: showId,
                            resolved: resolvedTrakt,
                            progress: progress,
                            playbackContext: playbackContext
                        )
                    }
                }
            }
        }
    }

    private func syncToAniList(account: TrackerAccount, showId: Int, seasonNumber: Int, episodeNumber: Int, progress: Double) async {
        // First check if we have a season-specific AniList ID (for anime with multiple AniList entries per season)
        var anilistId: Int? = cachedAniListSeasonId(tmdbId: showId, seasonNumber: seasonNumber)
        
        // Fall back to show-level lookup if no season-specific mapping exists
        if anilistId == nil {
            anilistId = await getAniListMediaId(tmdbId: showId)
        }
        
        guard let anilistId = anilistId else {
            Logger.shared.log("Could not find AniList ID for TMDB ID \(showId) S\(seasonNumber)", type: "Tracker")
            return
        }

        await syncToAniListMediaId(account: account, anilistId: anilistId, showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber, progress: progress)
    }

    private func syncToAniListMediaId(account: TrackerAccount, anilistId: Int, showId: Int, seasonNumber: Int, episodeNumber: Int, progress: Double) async {
        // AniList progress for anime is episode-based. Mark as COMPLETED only when we reach
        // the final known episode for this AniList entry; otherwise keep it CURRENT.
        let totalEpisodes = await getAniListEpisodeCount(mediaId: anilistId)
        let isFinalEpisode = (totalEpisodes ?? 0) > 0 && episodeNumber >= (totalEpisodes ?? 0)
        let normalStatus = isFinalEpisode ? "COMPLETED" : "CURRENT"
        let status: String?
#if os(iOS)
        switch await fetchAniListAnimeListStatus(account: account, mediaId: anilistId) {
        case .loaded(let currentStatus):
            status = currentStatus?.uppercased() == "REPEATING" ? "REPEATING" : normalStatus
        case .unavailable:
            // A progress-only mutation is safer than guessing when the status lookup fails:
            // AniList preserves an existing REPEATING status when status is omitted.
            status = nil
        }
#else
        status = normalStatus
#endif
        let statusClause = status.map { ",\n                status: \($0)" } ?? ""

        // Only include completedAt when marking as COMPLETED
        let completedAtClause: String
        if status == "COMPLETED" {
            completedAtClause = """
            , completedAt: {
                        year: \(Calendar.current.component(.year, from: Date()))
                        month: \(Calendar.current.component(.month, from: Date()))
                        day: \(Calendar.current.component(.day, from: Date()))
                    }
            """
        } else {
            completedAtClause = ""
        }

        let mutation = """
        mutation {
            SaveMediaListEntry(
                mediaId: \(anilistId),
                progress: \(episodeNumber)\(statusClause)\(completedAtClause)
            ) {
                id
                progress
                status
            }
        }
        """

        do {
            let url = URL(string: "https://graphql.anilist.co")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")

            let body: [String: Any] = ["query": mutation]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            if response.statusCode == 200 {
                // Parse response to check for errors
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                    let errorMsg = (errors.first?["message"] as? String) ?? "Unknown error"
                    Logger.shared.log("AniList sync error: \(errorMsg)", type: "Tracker")
                } else {
                    Logger.shared.log("Synced to AniList: mediaId=\(anilistId) S\(seasonNumber)E\(episodeNumber) (\(status ?? "status preserved"))", type: "Tracker")
                }
            } else {
                Logger.shared.log("AniList sync returned status \(response.statusCode)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync to AniList: \(error.localizedDescription)", type: "Error")
        }
    }

#if os(iOS)
    private enum AniListAnimeListStatusLookup {
        case loaded(String?)
        case unavailable
    }

    private func fetchAniListAnimeListStatus(
        account: TrackerAccount,
        mediaId: Int
    ) async -> AniListAnimeListStatusLookup {
        let query = """
        query($mediaId: Int!) {
            Media(id: $mediaId, type: ANIME) {
                mediaListEntry {
                    status
                }
            }
        }
        """

        struct Response: Decodable {
            let data: DataWrapper?

            struct DataWrapper: Decodable {
                let Media: Media?
            }

            struct Media: Decodable {
                let mediaListEntry: MediaListEntry?
            }

            struct MediaListEntry: Decodable {
                let status: String?
            }
        }

        do {
            var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query,
                "variables": ["mediaId": mediaId]
            ])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            guard response.statusCode == 200 else {
                Logger.shared.log("AniList status lookup returned \(response.statusCode) for mediaId=\(mediaId); preserving server status", type: "Tracker")
                return .unavailable
            }
            if let graphQLError = graphQLErrorMessage(from: data) {
                Logger.shared.log("AniList status lookup failed for mediaId=\(mediaId): \(graphQLError)", type: "Tracker")
                return .unavailable
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return .loaded(decoded.data?.Media?.mediaListEntry?.status)
        } catch {
            Logger.shared.log("AniList status lookup failed for mediaId=\(mediaId): \(error.localizedDescription)", type: "Tracker")
            return .unavailable
        }
    }
#endif

    private func syncToMyAnimeList(account: TrackerAccount, showId: Int, seasonNumber: Int, episodeNumber: Int, progress: Double) async {
        var anilistId: Int? = cachedAniListSeasonId(tmdbId: showId, seasonNumber: seasonNumber)

        if anilistId == nil {
            anilistId = await getAniListMediaId(tmdbId: showId)
        }

        guard let anilistId = anilistId else {
            Logger.shared.log("Could not find AniList ID for MAL sync, TMDB \(showId) S\(seasonNumber)", type: "Tracker")
            return
        }

        await syncToMyAnimeList(account: account, anilistId: anilistId, episodeNumber: episodeNumber, progress: progress)
    }

    private func syncToMyAnimeList(account: TrackerAccount, anilistId: Int, episodeNumber: Int, progress: Double) async {
        let malProgress = progress <= 1.0 ? progress * 100.0 : progress
        guard malProgress >= 85 else {
            Logger.shared.log("Skipping MAL anime sync below watched threshold for AniList \(anilistId) E\(episodeNumber)", type: "Tracker")
            return
        }

        guard let malId = await getMyAnimeListId(fromAniListId: anilistId, mediaType: "ANIME") else {
            Logger.shared.log("Could not find MAL anime ID for AniList \(anilistId)", type: "Tracker")
            return
        }

        let totalEpisodes = await getAniListEpisodeCount(mediaId: anilistId)
        let status = ((totalEpisodes ?? 0) > 0 && episodeNumber >= (totalEpisodes ?? 0)) ? "completed" : "watching"
        await saveMALAnimeProgress(
            account: account,
            malId: malId,
            watchedEpisodes: episodeNumber,
            status: status,
            preserveRewatching: true
        )
    }

    private func syncToMyAnimeList(account: TrackerAccount, malId: Int, episodeNumber: Int, progress: Double) async {
        let malProgress = progress <= 1.0 ? progress * 100.0 : progress
        guard malProgress >= 85 else {
            Logger.shared.log("Skipping MAL anime sync below watched threshold for MAL \(malId) E\(episodeNumber)", type: "Tracker")
            return
        }

#if os(iOS)
        // The MAL media lookup below supplies the actual episode total. Playback percentage
        // describes this episode, not completion of the whole series.
        let status = "watching"
#else
        let status = malProgress >= 95 ? "completed" : "watching"
#endif
        await saveMALAnimeProgress(
            account: account,
            malId: malId,
            watchedEpisodes: episodeNumber,
            status: status,
            preserveRewatching: true
        )
    }

    private func saveMALAnimeProgress(
        account: TrackerAccount,
        malId: Int,
        watchedEpisodes: Int,
        status: String,
        preserveRewatching: Bool = false
    ) async {
        var values = [
            "status": status,
            "num_watched_episodes": String(max(watchedEpisodes, 0))
        ]

#if os(iOS)
        if preserveRewatching {
            switch await fetchMALAnimePlaybackState(account: account, malId: malId) {
            case .loaded(let state):
                if state.isRewatching {
                    // MAL models rewatching separately from its watching/completed status.
                    // Avoid replacing that state and explicitly keep its rewatch flag set.
                    values.removeValue(forKey: "status")
                    values["is_rewatching"] = "true"
                } else if let totalEpisodes = state.totalEpisodes, totalEpisodes > 0 {
                    values["status"] = watchedEpisodes >= totalEpisodes ? "completed" : "watching"
                }
            case .unavailable:
                // If current state cannot be read, update progress only. Omitting status avoids
                // turning a remote rewatch into a normal Watching entry on a transient failure.
                values.removeValue(forKey: "status")
            }
        }
#endif

        do {
            let (data, response) = try await sendMALListStatusRequest(
                account: account,
                mediaPath: "anime",
                mediaId: malId,
                values: values
            )
            if (200...299).contains(response.statusCode) {
                Logger.shared.log("Synced to MAL: animeId=\(malId) episodes=\(watchedEpisodes) status=\(values["status"] ?? "preserved")", type: "Tracker")
            } else {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                Logger.shared.log("MAL anime sync returned status \(response.statusCode): \(bodyPreview)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync to MAL: \(error.localizedDescription)", type: "Error")
        }
    }

#if os(iOS)
    private struct MALAnimePlaybackState {
        let isRewatching: Bool
        let totalEpisodes: Int?
    }

    private enum MALAnimePlaybackStateLookup {
        case loaded(MALAnimePlaybackState)
        case unavailable
    }

    private func fetchMALAnimePlaybackState(
        account: TrackerAccount,
        malId: Int,
        allowsRefreshRetry: Bool = true
    ) async -> MALAnimePlaybackStateLookup {
        struct Response: Decodable {
            let numEpisodes: Int?
            let myListStatus: ListStatus?

            enum CodingKeys: String, CodingKey {
                case numEpisodes = "num_episodes"
                case myListStatus = "my_list_status"
            }

            struct ListStatus: Decodable {
                let isRewatching: Bool?

                enum CodingKeys: String, CodingKey {
                    case isRewatching = "is_rewatching"
                }
            }
        }

        do {
            let account = try await refreshedMALAccountIfNeeded(account)
            let url = URL(string: "https://api.myanimelist.net/v2/anime/\(malId)?fields=my_list_status,num_episodes")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await sendTrackerRequest(request, provider: .myAnimeList)
            if response.statusCode == 401, allowsRefreshRetry {
                let refreshed = try await refreshedMALAccountIfNeeded(account, force: true)
                return await fetchMALAnimePlaybackState(
                    account: refreshed,
                    malId: malId,
                    allowsRefreshRetry: false
                )
            }
            guard response.statusCode == 200 else {
                Logger.shared.log("MAL rewatch status lookup returned \(response.statusCode) for animeId=\(malId); preserving server status", type: "Tracker")
                return .unavailable
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return .loaded(MALAnimePlaybackState(
                isRewatching: decoded.myListStatus?.isRewatching == true,
                totalEpisodes: decoded.numEpisodes
            ))
        } catch {
            Logger.shared.log("MAL rewatch status lookup failed for animeId=\(malId): \(error.localizedDescription)", type: "Tracker")
            return .unavailable
        }
    }
#endif

#if !os(tvOS)
    private func saveMALMangaProgress(account: TrackerAccount, malId: Int, chaptersRead: Int, status: String) async {
        let values = [
            "status": status,
            "num_chapters_read": String(max(chaptersRead, 0))
        ]

        do {
            let (data, response) = try await sendMALListStatusRequest(
                account: account,
                mediaPath: "manga",
                mediaId: malId,
                values: values
            )
            if (200...299).contains(response.statusCode) {
                ReaderLogger.shared.log("Synced manga to MAL: mangaId=\(malId) chapters=\(chaptersRead) status=\(status)", type: "Tracker")
            } else {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                ReaderLogger.shared.log("MAL manga sync returned status \(response.statusCode): \(bodyPreview)", type: "Tracker")
            }
        } catch {
            ReaderLogger.shared.log("Failed to sync manga to MAL: \(error.localizedDescription)", type: "Error")
        }
    }

    private func saveMALMangaRatingAndNote(account: TrackerAccount, malId: Int, rating: Double, note: String?) async {
        let clampedRating = Self.normalizedRatingOutOf10(rating)
        let malRating = Self.myAnimeListScore(from: clampedRating)
        let displayRating = Self.ratingDisplayString(clampedRating)
        var values = [
            "score": String(malRating)
        ]
        if let note {
            values["comments"] = note
        }

        do {
            let (data, response) = try await sendMALListStatusRequest(
                account: account,
                mediaPath: "manga",
                mediaId: malId,
                values: values
            )
            if (200...299).contains(response.statusCode) {
                let malSuffix = malRating == Int(clampedRating) && clampedRating.truncatingRemainder(dividingBy: 1) == 0
                    ? ""
                    : " as \(malRating)/10"
                ReaderLogger.shared.log("Synced MAL manga rating \(displayRating)/10\(malSuffix)\(note == nil ? "" : " and comments") for mangaId \(malId)", type: "Tracker")
            } else {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                ReaderLogger.shared.log("MAL manga rating sync returned status \(response.statusCode): \(bodyPreview)", type: "Tracker")
            }
        } catch {
            ReaderLogger.shared.log("Failed to sync MAL manga rating \(malId): \(error.localizedDescription)", type: "Error")
        }
    }
#endif


    private enum TraktMediaType: String {
        case show
        case movie
    }

    private struct TraktIDs: Decodable {
        let trakt: Int?
        let imdb: String?
        let tmdb: Int?
    }

    private struct TraktShow: Decodable {
        let title: String
        let ids: TraktIDs
        let airedEpisodes: Int?

        enum CodingKeys: String, CodingKey {
            case title, ids
            case airedEpisodes = "aired_episodes"
        }
    }

    private struct TraktMovie: Decodable {
        let title: String
        let ids: TraktIDs
    }

    private struct TraktPublicListItem: Decodable {
        let movie: TraktMovie?
        let show: TraktShow?
    }

    // Trakt's `/shows/:id/comments/:sort` and `/movies/:id/comments/:sort` endpoints
    // return a flat array of comment objects, where `comment` is the text string and
    // `user` is nested inside each element (NOT a `{ comment: {...}, user: {...} }` wrapper).
    private struct TraktCommentResponse: Decodable {
        let id: Int
        let comment: String
        let spoiler: Bool?
        let review: Bool?
        let likes: Int?
        let createdAt: String?
        let user: TraktCommentUser?

        enum CodingKeys: String, CodingKey {
            case id, comment, spoiler, review, likes, user
            case createdAt = "created_at"
        }
    }

    private struct TraktCommentUser: Decodable {
        let username: String?
        let name: String?
    }

    private struct TraktRatingResponse: Decodable {
        let rating: Double?
        let votes: Int?
    }

    private struct TraktEpisode: Decodable {
        let title: String?
        let season: Int
        let number: Int
        let ids: TraktIDs?
    }

    private struct TraktShowProgress: Decodable {
        let aired: Int
        let completed: Int
        let lastWatchedAt: String?
        let nextEpisode: TraktEpisode?

        enum CodingKeys: String, CodingKey {
            case aired, completed
            case lastWatchedAt = "last_watched_at"
            case nextEpisode = "next_episode"
        }
    }

    private struct TraktUpNextResponse: Decodable {
        let progress: TraktShowProgress
        let show: TraktShow
    }

    private struct TraktWatchlistShowResponse: Decodable {
        let show: TraktShow
    }

    private struct TraktWatchlistMovieResponse: Decodable {
        let movie: TraktMovie
    }

    private struct TraktWatchedMovieResponse: Decodable {
        let movie: TraktMovie
    }

    private struct TraktWatchedShowResponse: Decodable {
        let show: TraktShow
        let seasons: [Season]?

        struct Season: Decodable {
            let number: Int
            let episodes: [Episode]

            struct Episode: Decodable {
                let number: Int
            }
        }
    }

    private struct TraktMoviePlaybackResponse: Decodable {
        let progress: Double?
        let pausedAt: String?
        let id: Int
        let movie: TraktMovie

        enum CodingKeys: String, CodingKey {
            case progress
            case pausedAt = "paused_at"
            case id
            case movie
        }
    }

    private struct TraktEpisodePlaybackResponse: Decodable {
        let progress: Double?
        let pausedAt: String?
        let id: Int
        let show: TraktShow
        let episode: TraktEpisode

        enum CodingKeys: String, CodingKey {
            case progress
            case pausedAt = "paused_at"
            case id
            case show
            case episode
        }
    }

    private func resolvedTraktEpisodeNumbers(
        seasonNumber: Int,
        episodeNumber: Int,
        playbackContext: EpisodePlaybackContext?
    ) -> (season: Int, episode: Int)? {
        guard let playbackContext else {
            return (seasonNumber, episodeNumber)
        }

        if let tmdbSeason = playbackContext.resolvedTMDBSeasonNumber,
           let tmdbEpisode = playbackContext.resolvedTMDBEpisodeNumber {
            return (tmdbSeason, tmdbEpisode)
        }

        if playbackContext.isSpecial || playbackContext.hasAnimeMediaId {
            Logger.shared.log("Skipping Trakt sync for anime episode without TMDB episode mapping: local S\(seasonNumber)E\(episodeNumber)", type: "Tracker")
            return nil
        }

        return (seasonNumber, episodeNumber)
    }

    func syncTraktEpisodePlaybackProgress(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        progress: Double,
        playbackContext: EpisodePlaybackContext? = nil,
        force: Bool = false
    ) {
        guard !isBackupRestoreSyncSuppressed(), trackerState.syncEnabled else { return }
        guard progress.isFinite, progress > 0 else { return }
        guard let account = trackerState.getAccount(for: .trakt) else { return }

        if trackerState.liveTraktScrobbling {
            guard force else { return }
            scrobbleTraktPlayback(
                .stop,
                for: .episode(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber),
                progress: progress,
                playbackContext: playbackContext,
                force: force
            )
            return
        }

        let resolved = resolvedTraktEpisodeNumbers(
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            playbackContext: playbackContext
        )
        guard resolved != nil || canUseTraktAnimeFallback(playbackContext) else { return }

        let keySeason = resolved?.season ?? seasonNumber
        let keyEpisode = resolved?.episode ?? episodeNumber
        let key = "episode|\(showId)|\(keySeason)|\(keyEpisode)"
        guard shouldStartTraktPlaybackSync(key: key, force: force) else { return }
        Task {
            await syncToTrakt(
                account: account,
                showId: showId,
                resolved: resolved,
                progress: progress,
                playbackContext: playbackContext
            )
        }
    }

    func syncTraktMoviePlaybackProgress(movieId: Int, progress: Double, force: Bool = false) {
        guard !isBackupRestoreSyncSuppressed(), trackerState.syncEnabled else { return }
        guard progress.isFinite, progress > 0 else { return }
        guard let account = trackerState.getAccount(for: .trakt) else { return }

        if trackerState.liveTraktScrobbling {
            guard force else { return }
            scrobbleTraktPlayback(.stop, for: .movie(id: movieId, title: ""), progress: progress, force: force)
            return
        }

        let key = "movie|\(movieId)"
        guard shouldStartTraktPlaybackSync(key: key, force: force) else { return }
        Task {
            await syncMovieToTrakt(account: account, movieId: movieId, progress: progress)
        }
    }

    func scrobbleTraktPlayback(
        _ action: TraktScrobbleAction,
        for mediaInfo: MediaInfo,
        progress: Double,
        playbackContext: EpisodePlaybackContext? = nil,
        force: Bool = false
    ) {
        guard !isBackupRestoreSyncSuppressed(),
              trackerState.syncEnabled,
              trackerState.liveTraktScrobbling else { return }
        guard progress.isFinite else { return }
        let normalizedProgress = normalizedTraktScrobbleProgress(progress)
        if action != .start {
            guard normalizedProgress > 0 else { return }
        }
        guard let account = trackerState.getAccount(for: .trakt) else { return }
        guard let key = traktScrobbleKey(for: mediaInfo, playbackContext: playbackContext) else { return }
        guard shouldQueueTraktScrobble(action: action, key: key, progress: normalizedProgress, force: force) else { return }

        Task {
            let sent = await sendTraktScrobble(
                action: action,
                account: account,
                mediaInfo: mediaInfo,
                progress: normalizedProgress,
                playbackContext: playbackContext
            )
            finishTraktScrobble(action: action, key: key, progress: normalizedProgress, sent: sent)
        }
    }

    func fetchTraktContinueWatchingItems() async -> [ContinueWatchingItem] {
        guard let account = trackerState.getAccount(for: .trakt) else {
            return []
        }

        if let cached = cachedTraktContinueWatchingItems(for: account) {
            return cached
        }

        do {
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(account)
            guard !traktClientId.isEmpty else {
                Logger.shared.log("Skipping Trakt Continue Watching fetch because TRAKT_CLIENT_ID is not configured.", type: "Tracker")
                return []
            }

            async let upNextData = fetchTraktPlaybackData(path: "sync/progress/up_next", account: refreshedAccount)
            async let episodeData = fetchTraktPlaybackData(path: "sync/playback/episodes", account: refreshedAccount)
            async let movieData = fetchTraktPlaybackData(path: "sync/playback/movies", account: refreshedAccount)
            let (upNextPlaybackData, episodePlaybackData, moviePlaybackData) = try await (upNextData, episodeData, movieData)

            let shows: [ContinueWatchingItem] = try JSONDecoder().decode([TraktUpNextResponse].self, from: upNextPlaybackData).compactMap { item -> ContinueWatchingItem? in
                guard let tmdbId = item.show.ids.tmdb,
                      let episode = item.progress.nextEpisode else { return nil }
                return ContinueWatchingItem(
                    id: "trakt_up_next_\(tmdbId)",
                    tmdbId: tmdbId,
                    isMovie: false,
                    title: item.show.title,
                    posterURL: nil,
                    progress: 0,
                    lastUpdated: item.progress.lastWatchedAt.flatMap(traktDate(from:)) ?? Date.distantPast,
                    seasonNumber: episode.season,
                    episodeNumber: episode.number,
                    currentTime: 0,
                    totalDuration: 1,
                    playbackContext: nil,
                    isAnime: false,
                    statusText: "Watch next",
                    isWatchNext: true,
                    traktPlaybackId: nil,
                    removalTarget: .traktUpNextShow
                )
            }
            let episodes: [ContinueWatchingItem] = try JSONDecoder().decode([TraktEpisodePlaybackResponse].self, from: episodePlaybackData).compactMap { playback -> ContinueWatchingItem? in
                guard let tmdbId = playback.show.ids.tmdb,
                      let normalized = normalizedTraktPlaybackProgress(playback.progress) else { return nil }
                return ContinueWatchingItem(
                    id: "trakt_episode_\(playback.id)",
                    tmdbId: tmdbId,
                    isMovie: false,
                    title: playback.show.title,
                    posterURL: nil,
                    progress: normalized.fraction,
                    lastUpdated: playback.pausedAt.flatMap(traktDate(from:)) ?? Date.distantPast,
                    seasonNumber: playback.episode.season,
                    episodeNumber: playback.episode.number,
                    currentTime: normalized.fraction,
                    totalDuration: 1,
                    playbackContext: nil,
                    isAnime: false,
                    statusText: "\(Int(normalized.percent.rounded()))% watched",
                    isWatchNext: false,
                    traktPlaybackId: playback.id,
                    removalTarget: .traktPlayback(playback.id)
                )
            }
            let movies: [ContinueWatchingItem] = try JSONDecoder().decode([TraktMoviePlaybackResponse].self, from: moviePlaybackData).compactMap { playback -> ContinueWatchingItem? in
                guard let tmdbId = playback.movie.ids.tmdb,
                      let normalized = normalizedTraktPlaybackProgress(playback.progress) else { return nil }
                return ContinueWatchingItem(
                    id: "trakt_movie_\(playback.id)",
                    tmdbId: tmdbId,
                    isMovie: true,
                    title: playback.movie.title,
                    posterURL: nil,
                    progress: normalized.fraction,
                    lastUpdated: playback.pausedAt.flatMap(traktDate(from:)) ?? Date.distantPast,
                    seasonNumber: nil,
                    episodeNumber: nil,
                    currentTime: normalized.fraction,
                    totalDuration: 1,
                    playbackContext: nil,
                    isAnime: false,
                    statusText: "\(Int(normalized.percent.rounded()))% watched",
                    isWatchNext: false,
                    traktPlaybackId: playback.id,
                    removalTarget: .traktPlayback(playback.id)
                )
            }
            let items = episodes + shows + movies
            storeTraktContinueWatchingItems(items, for: refreshedAccount)
            return items
        } catch {
            Logger.shared.log("Failed to fetch Trakt Continue Watching: \(error.localizedDescription)", type: "Error")
            return []
        }
    }

    private func cachedTraktContinueWatchingItems(for account: TrackerAccount) -> [ContinueWatchingItem]? {
        let now = Date()
        return traktContinueWatchingCacheQueue.sync {
            guard let cache = traktContinueWatchingCache,
                  cache.accountUserId == account.userId,
                  now.timeIntervalSince(cache.fetchedAt) < traktContinueWatchingCacheTTL else {
                return nil
            }
            return cache.items
        }
    }

    private func storeTraktContinueWatchingItems(_ items: [ContinueWatchingItem], for account: TrackerAccount) {
        traktContinueWatchingCacheQueue.sync {
            traktContinueWatchingCache = (account.userId, Date(), items)
        }
    }

    private func invalidateTraktContinueWatchingCache() {
        traktContinueWatchingCacheQueue.sync {
            traktContinueWatchingCache = nil
        }
    }

    func fetchTraktPublicListCatalogItems(
        for catalog: Catalog,
        tmdbService: TMDBService,
        limit: Int = 30
    ) async -> [TMDBSearchResult] {
        guard trackerState.traktPublicCatalogsEnabled,
              catalog.source == .trakt,
              let listPath = catalog.traktListEndpointPath,
              trackerState.getAccount(for: .trakt) != nil else {
            return []
        }

        let mediaType = Catalog.normalizedTraktListMediaType(catalog.traktListMediaType)
        let sortBy = sanitizedTraktListSortBy(catalog.traktListSortBy)
        let sortHow = sanitizedTraktListSortHow(catalog.traktListSortHow)
        let itemType = mediaType == "movies" ? "movies" : "shows"
        let path = "\(listPath)/items/\(itemType)?extended=full&sort_by=\(sortBy)&sort_how=\(sortHow)&page=1&limit=\(max(limit * 2, 30))"

        do {
            let data = try await fetchTraktData(path: path, account: trackerState.getAccount(for: .trakt))
            let items = try JSONDecoder().decode([TraktPublicListItem].self, from: data)
            var resolved: [TMDBSearchResult] = []
            var seen = Set<String>()

            for item in items {
                guard resolved.count < limit else { break }
                let result: TMDBSearchResult?
                if mediaType == "movies", let movie = item.movie {
                    result = await resolveTraktMediaToTMDB(
                        tmdbId: movie.ids.tmdb,
                        imdbId: movie.ids.imdb,
                        isMovie: true,
                        tmdbService: tmdbService
                    )
                } else if let show = item.show {
                    result = await resolveTraktMediaToTMDB(
                        tmdbId: show.ids.tmdb,
                        imdbId: show.ids.imdb,
                        isMovie: false,
                        tmdbService: tmdbService
                    )
                } else {
                    result = nil
                }

                guard let result, seen.insert(result.stableIdentity).inserted else { continue }
                resolved.append(result)
            }

            Logger.shared.log("Trakt public list catalog \(catalog.id) loaded \(resolved.count) TMDB items", type: "Tracker")
            return resolved
        } catch {
            Logger.shared.log("Failed to load Trakt public list catalog \(catalog.id): \(error.localizedDescription)", type: "Error")
            return []
        }
    }

    func fetchTraktComments(tmdbId: Int, isMovie: Bool) async -> [TraktCommentReview] {
        guard trackerState.traktCommentsEnabled else {
            return []
        }

        let cacheKey = "\(isMovie ? "movie" : "show")|\(tmdbId)"
        if let cached = cachedTraktComments(key: cacheKey) {
            return cached
        }

        let mediaType: TraktMediaType = isMovie ? .movie : .show
        guard let traktId = await getTraktIdFromTmdbId(tmdbId, mediaType: mediaType) else {
            return []
        }

        let endpoint = isMovie ? "movies" : "shows"
        do {
            let data = try await fetchTraktData(
                path: "\(endpoint)/\(traktId)/comments/likes?page=1&limit=25"
            )
            let decoded = try JSONDecoder().decode([TraktCommentResponse].self, from: data)
            let comments = decoded.compactMap { response -> TraktCommentReview? in
                guard response.spoiler != true,
                      !response.comment.lowercased().contains("[spoiler]"),
                      let cleanComment = cleanTraktComment(response.comment) else {
                    return nil
                }
                let author = response.user?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let username = response.user?.username?.trimmingCharacters(in: .whitespacesAndNewlines)
                return TraktCommentReview(
                    id: response.id,
                    authorName: author?.isEmpty == false ? author! : (username?.isEmpty == false ? username! : "Trakt User"),
                    comment: cleanComment,
                    likes: response.likes ?? 0,
                    createdAt: response.createdAt,
                    isReview: response.review ?? false
                )
            }

            storeTraktComments(comments, key: cacheKey)
            return comments
        } catch {
            Logger.shared.log("Failed to load Trakt comments for \(cacheKey): \(error.localizedDescription)", type: "Error")
            return []
        }
    }

    func fetchTraktRating(tmdbId: Int, isMovie: Bool) async -> TraktMediaRating? {
        let cacheKey = "\(isMovie ? "movie" : "show")|\(tmdbId)"
        if let cached = cachedTraktRating(key: cacheKey) {
            return cached
        }

        let mediaType: TraktMediaType = isMovie ? .movie : .show
        guard let traktId = await getTraktIdFromTmdbId(tmdbId, mediaType: mediaType) else {
            return nil
        }

        let endpoint = isMovie ? "movies" : "shows"
        do {
            let data = try await fetchTraktData(path: "\(endpoint)/\(traktId)/ratings")
            let decoded = try JSONDecoder().decode(TraktRatingResponse.self, from: data)
            guard let value = decoded.rating, value > 0 else { return nil }
            let rating = TraktMediaRating(rating: min(max(value, 0), 10), votes: decoded.votes ?? 0)
            storeTraktRating(rating, key: cacheKey)
            return rating
        } catch {
            Logger.shared.log("Failed to load Trakt rating for \(cacheKey): \(error.localizedDescription)", type: "Error")
            return nil
        }
    }

    func fetchTraktRelated(tmdbId: Int, isMovie: Bool, tmdbService: TMDBService) async -> [TMDBSearchResult] {
        guard trackerState.traktRelatedEnabled,
              let account = trackerState.getAccount(for: .trakt) else {
            return []
        }

        let cacheKey = "\(isMovie ? "movie" : "show")|\(tmdbId)"
        if let cached = cachedTraktRelated(key: cacheKey) {
            return cached
        }

        let mediaType: TraktMediaType = isMovie ? .movie : .show
        guard let traktId = await getTraktIdFromTmdbId(tmdbId, mediaType: mediaType) else {
            return []
        }

        let endpoint = isMovie ? "movies" : "shows"
        do {
            let data = try await fetchTraktData(path: "\(endpoint)/\(traktId)/related?extended=full", account: account)
            var resolved: [TMDBSearchResult] = []
            var seen = Set<String>()

            if isMovie {
                let movies = try JSONDecoder().decode([TraktMovie].self, from: data)
                for movie in movies {
                    guard let result = await resolveTraktMediaToTMDB(
                        tmdbId: movie.ids.tmdb,
                        imdbId: movie.ids.imdb,
                        isMovie: true,
                        tmdbService: tmdbService
                    ), seen.insert(result.stableIdentity).inserted else {
                        continue
                    }
                    resolved.append(result)
                }
            } else {
                let shows = try JSONDecoder().decode([TraktShow].self, from: data)
                for show in shows {
                    guard let result = await resolveTraktMediaToTMDB(
                        tmdbId: show.ids.tmdb,
                        imdbId: show.ids.imdb,
                        isMovie: false,
                        tmdbService: tmdbService
                    ), seen.insert(result.stableIdentity).inserted else {
                        continue
                    }
                    resolved.append(result)
                }
            }

            let filtered = TMDBContentFilter.shared.filterSearchResults(resolved)
            storeTraktRelated(filtered, key: cacheKey)
            return filtered
        } catch {
            Logger.shared.log("Failed to load Trakt related for \(cacheKey): \(error.localizedDescription)", type: "Error")
            return []
        }
    }

    private func fetchTraktPlaybackData(path: String, account: TrackerAccount, allowsRefreshRetry: Bool = true) async throws -> Data {
        let url = URL(string: "https://api.trakt.tv/\(path)")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")

        let (data, response) = try await sendTrackerRequest(request, provider: .trakt, reportRateLimitStatus: false)
        let statusCode = response.statusCode
        if statusCode == 401, allowsRefreshRetry {
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(account, force: true)
            return try await fetchTraktPlaybackData(path: path, account: refreshedAccount, allowsRefreshRetry: false)
        }
        guard statusCode == 200 else {
            let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw NSError(domain: "Trakt", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Trakt \(path) returned status \(statusCode): \(bodyPreview)"])
        }
        return data
    }

    private func fetchAllTraktPages(path: String, account: TrackerAccount, limit: Int = 100) async throws -> [Data] {
        var pages: [Data] = []
        var page = 1

        while true {
            let separator = path.contains("?") ? "&" : "?"
            let data = try await fetchTraktPlaybackData(
                path: "\(path)\(separator)page=\(page)&limit=\(limit)",
                account: account
            )
            pages.append(data)

            let count = (try JSONSerialization.jsonObject(with: data) as? [Any])?.count ?? 0
            guard count >= limit else { return pages }
            page += 1
        }
    }

    private func fetchTraktData(path: String, account: TrackerAccount? = nil, allowsRefreshRetry: Bool = true) async throws -> Data {
        guard !traktClientId.isEmpty else {
            throw NSError(domain: "Trakt", code: -1, userInfo: [NSLocalizedDescriptionKey: "TRAKT_CLIENT_ID is not configured."])
        }

        let refreshedAccount: TrackerAccount?
        if let account {
            refreshedAccount = try await refreshedTraktAccountIfNeeded(account)
        } else {
            refreshedAccount = nil
        }

        let url = URL(string: "https://api.trakt.tv/\(path)")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        if let refreshedAccount {
            request.setValue("Bearer \(refreshedAccount.accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await sendTrackerRequest(request, provider: .trakt, reportRateLimitStatus: false)
        if response.statusCode == 401, let account = refreshedAccount, allowsRefreshRetry {
            let forcedRefresh = try await refreshedTraktAccountIfNeeded(account, force: true)
            return try await fetchTraktData(path: path, account: forcedRefresh, allowsRefreshRetry: false)
        }
        guard (200...299).contains(response.statusCode) else {
            let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw NSError(domain: "Trakt", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Trakt \(path) returned status \(response.statusCode): \(bodyPreview)"])
        }
        return data
    }

    private func resolveTraktMediaToTMDB(
        tmdbId: Int?,
        imdbId: String?,
        isMovie: Bool,
        tmdbService: TMDBService
    ) async -> TMDBSearchResult? {
        if let tmdbId {
            if isMovie, let detail = try? await tmdbService.getMovieDetails(id: tmdbId) {
                return movieDetailSearchResult(detail)
            }
            if !isMovie, let detail = try? await tmdbService.getTVShowDetails(id: tmdbId) {
                return tvDetailSearchResult(detail)
            }
        }

        if let imdbId,
           let fallback = try? await tmdbService.findByIMDbId(imdbId, preferredMediaType: isMovie ? "movie" : "tv") {
            return fallback
        }

        return nil
    }

    private func movieDetailSearchResult(_ detail: TMDBMovieDetail) -> TMDBSearchResult {
        TMDBSearchResult(
            id: detail.id,
            mediaType: "movie",
            title: detail.title,
            name: nil,
            overview: detail.overview,
            posterPath: detail.posterPath,
            backdropPath: detail.backdropPath,
            releaseDate: detail.releaseDate,
            firstAirDate: nil,
            voteAverage: detail.voteAverage,
            popularity: detail.popularity,
            adult: detail.adult,
            genreIds: detail.genres.map(\.id),
            originalLanguage: detail.originalLanguage,
            originCountry: nil,
            voteCount: detail.voteCount
        )
    }

    private func tvDetailSearchResult(_ detail: TMDBTVShowDetail) -> TMDBSearchResult {
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
            genreIds: detail.genres.map(\.id),
            originalLanguage: detail.originalLanguage,
            originCountry: detail.originCountry,
            voteCount: detail.voteCount
        )
    }

    private func cachedTraktComments(key: String) -> [TraktCommentReview]? {
        let now = Date()
        return traktFeatureCacheQueue.sync {
            guard let cache = traktCommentsCache[key],
                  now.timeIntervalSince(cache.fetchedAt) < traktFeatureCacheTTL else {
                return nil
            }
            return cache.items
        }
    }

    private func storeTraktComments(_ items: [TraktCommentReview], key: String) {
        traktFeatureCacheQueue.sync {
            traktCommentsCache[key] = (Date(), items)
        }
    }

    private func cachedTraktRating(key: String) -> TraktMediaRating? {
        let now = Date()
        return traktFeatureCacheQueue.sync {
            guard let cache = traktRatingsCache[key],
                  now.timeIntervalSince(cache.fetchedAt) < traktFeatureCacheTTL else {
                return nil
            }
            return cache.rating
        }
    }

    private func storeTraktRating(_ rating: TraktMediaRating, key: String) {
        traktFeatureCacheQueue.sync {
            traktRatingsCache[key] = (Date(), rating)
        }
    }

    private func cachedTraktRelated(key: String) -> [TMDBSearchResult]? {
        let now = Date()
        return traktFeatureCacheQueue.sync {
            guard let cache = traktRelatedCache[key],
                  now.timeIntervalSince(cache.fetchedAt) < traktFeatureCacheTTL else {
                return nil
            }
            return cache.items
        }
    }

    private func storeTraktRelated(_ items: [TMDBSearchResult], key: String) {
        traktFeatureCacheQueue.sync {
            traktRelatedCache[key] = (Date(), items)
        }
    }

    private func invalidateTraktFeatureCaches(comments: Bool, related: Bool) {
        traktFeatureCacheQueue.sync {
            if comments {
                traktCommentsCache = [:]
            }
            if related {
                traktRelatedCache = [:]
            }
        }
    }

    private func sanitizedTraktListSortBy(_ value: String?) -> String {
        let allowed: Set<String> = ["rank", "added", "title", "released", "runtime", "popularity", "percentage", "votes"]
        let normalized = value?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return allowed.contains(normalized) ? normalized : "rank"
    }

    private func sanitizedTraktListSortHow(_ value: String?) -> String {
        let normalized = value?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized == "desc" ? "desc" : "asc"
    }

    private func cleanTraktComment(_ raw: String) -> String? {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[/spoiler]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "[spoiler]", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.isEmpty ? nil : text
    }

    func removeTraktContinueWatchingItem(_ playbackId: Int, completion: (() -> Void)? = nil) {
        guard let account = trackerState.getAccount(for: .trakt) else { return }

        Task {
            do {
                let refreshedAccount = try await refreshedTraktAccountIfNeeded(account)
                guard !traktClientId.isEmpty else { return }
                try await deleteTraktPlaybackItem(playbackId, account: refreshedAccount)
                invalidateTraktContinueWatchingCache()
                if let completion {
                    await MainActor.run {
                        completion()
                    }
                }
            } catch {
                Logger.shared.log("Failed to remove Trakt playback item: \(error.localizedDescription)", type: "Error")
            }
        }
    }

    func removeTraktUpNextShow(tmdbId: Int, completion: (() -> Void)? = nil) {
        guard let account = trackerState.getAccount(for: .trakt) else { return }

        Task {
            do {
                let refreshedAccount = try await refreshedTraktAccountIfNeeded(account)
                guard !traktClientId.isEmpty else { return }
                let payload: [String: Any] = [
                    "shows": [
                        [
                            "ids": [
                                "tmdb": tmdbId
                            ]
                        ]
                    ]
                ]
                _ = try await postTraktJSON(path: "users/hidden/progress_watched", account: refreshedAccount, payload: payload)
                invalidateTraktContinueWatchingCache()
                Logger.shared.log("Removed Trakt Up Next show tmdb=\(tmdbId)", type: "Tracker")
                if let completion {
                    await MainActor.run {
                        completion()
                    }
                }
            } catch {
                Logger.shared.log("Failed to remove Trakt Up Next show tmdb=\(tmdbId): \(error.localizedDescription)", type: "Error")
            }
        }
    }

    private func deleteTraktPlaybackItem(_ playbackId: Int, account: TrackerAccount, allowsRefreshRetry: Bool = true) async throws {
        let url = URL(string: "https://api.trakt.tv/sync/playback/\(playbackId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")

        let (data, response) = try await sendTrackerRequest(request, provider: .trakt, reportRateLimitStatus: false)
        let statusCode = response.statusCode
        if statusCode == 401, allowsRefreshRetry {
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(account, force: true)
            return try await deleteTraktPlaybackItem(playbackId, account: refreshedAccount, allowsRefreshRetry: false)
        }
        guard (200...299).contains(statusCode) else {
            let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw NSError(domain: "Trakt", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Trakt playback remove returned status \(statusCode): \(bodyPreview)"])
        }
    }

    private func shouldStartTraktPlaybackSync(key: String, force: Bool) -> Bool {
        let now = Date()
        var shouldStart = true
        recentTraktPlaybackSyncQueue.sync {
            recentTraktPlaybackSyncKeys = recentTraktPlaybackSyncKeys.filter {
                now.timeIntervalSince($0.value) < traktPlaybackSyncInterval * 10
            }
            if !force,
               let previous = recentTraktPlaybackSyncKeys[key],
               now.timeIntervalSince(previous) < traktPlaybackSyncInterval {
                shouldStart = false
            } else {
                recentTraktPlaybackSyncKeys[key] = now
            }
        }
        return shouldStart
    }

    private func traktScrobbleKey(for mediaInfo: MediaInfo, playbackContext: EpisodePlaybackContext?) -> String? {
        switch mediaInfo {
        case .movie(let id, _, _, _):
            return "movie|\(id)"
        case .episode(let showId, let seasonNumber, let episodeNumber, _, _, _):
            guard let resolved = resolvedTraktEpisodeNumbers(
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                playbackContext: playbackContext
            ) else { return nil }
            return "episode|\(showId)|\(resolved.season)|\(resolved.episode)"
        }
    }

    private func shouldQueueTraktScrobble(
        action: TraktScrobbleAction,
        key: String,
        progress: Double,
        force: Bool
    ) -> Bool {
        let now = Date()
        return traktScrobbleQueue.sync {
            traktScrobbleLastStampByKey = traktScrobbleLastStampByKey.filter {
                now.timeIntervalSince($0.value.sentAt) < 10 * 60
            }
            traktScrobblePendingByKey = traktScrobblePendingByKey.filter {
                now.timeIntervalSince($0.value.queuedAt) < 2 * 60
            }
            traktScrobbleFailureStampByKey = traktScrobbleFailureStampByKey.filter {
                now.timeIntervalSince($0.value.failedAt) < traktScrobbleFailureCooldown
            }

            if !force {
                if let failure = traktScrobbleFailureStampByKey[key],
                   failure.action == action,
                   now.timeIntervalSince(failure.failedAt) < traktScrobbleFailureCooldown,
                   abs(failure.progress - progress) <= traktScrobbleProgressWindow {
                    return false
                }

                if action == .start, traktScrobbleLastActionByKey[key] == .start {
                    guard let stamp = traktScrobbleLastStampByKey[key] else {
                        return false
                    }
                    if now.timeIntervalSince(stamp.sentAt) < traktScrobbleStartRefreshMinimumInterval {
                        return false
                    }
                }

                if let pending = traktScrobblePendingByKey[key] {
                    if action == .start, pending.action == .start {
                        return false
                    }
                    if pending.action == action,
                       now.timeIntervalSince(pending.queuedAt) < traktScrobbleMinimumInterval,
                       abs(pending.progress - progress) <= traktScrobbleProgressWindow {
                        return false
                    }
                }

                if let stamp = traktScrobbleLastStampByKey[key],
                   stamp.action == action,
                   now.timeIntervalSince(stamp.sentAt) < traktScrobbleMinimumInterval,
                   abs(stamp.progress - progress) <= traktScrobbleProgressWindow {
                    return false
                }

                if action != .start,
                   let lastAction = traktScrobbleLastActionByKey[key],
                   lastAction == action,
                   let stamp = traktScrobbleLastStampByKey[key],
                   abs(stamp.progress - progress) <= traktScrobbleProgressWindow {
                    return false
                }
            }

            traktScrobblePendingByKey[key] = (action, progress, now)
            return true
        }
    }

    private func resetTraktScrobbleState() {
        traktScrobbleQueue.sync {
            traktScrobbleLastActionByKey.removeAll()
            traktScrobbleLastStampByKey.removeAll()
            traktScrobblePendingByKey.removeAll()
            traktScrobbleFailureStampByKey.removeAll()
        }
    }

    private func finishTraktScrobble(
        action: TraktScrobbleAction,
        key: String,
        progress: Double,
        sent: Bool
    ) {
        let now = Date()
        traktScrobbleQueue.sync {
            if let pending = traktScrobblePendingByKey[key],
               pending.action == action,
               abs(pending.progress - progress) <= 0.1 {
                traktScrobblePendingByKey.removeValue(forKey: key)
            }
            if sent {
                traktScrobbleLastActionByKey[key] = action
                traktScrobbleLastStampByKey[key] = (action, progress, now)
                traktScrobbleFailureStampByKey.removeValue(forKey: key)
            } else {
                traktScrobbleFailureStampByKey[key] = (action, progress, now)
            }
        }
    }

    private func sendTraktScrobble(
        action: TraktScrobbleAction,
        account: TrackerAccount,
        mediaInfo: MediaInfo,
        progress: Double,
        playbackContext: EpisodePlaybackContext?
    ) async -> Bool {
        do {
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(account)
            let payload: [String: Any]

            switch mediaInfo {
            case .movie(let movieId, let title, _, _):
                guard let traktId = await getTraktIdFromTmdbId(movieId, mediaType: .movie) else {
                    Logger.shared.log("Skipping Trakt scrobble \(action.rawValue); no Trakt movie ID for TMDB \(movieId)", type: "Tracker")
                    return false
                }
                var moviePayload: [String: Any] = ["ids": ["trakt": traktId]]
                if !title.isEmpty {
                    moviePayload["title"] = title
                }
                payload = [
                    "progress": progress,
                    "movie": moviePayload
                ]

            case .episode(let showId, let seasonNumber, let episodeNumber, _, _, _):
                let resolved = resolvedTraktEpisodeNumbers(
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber,
                    playbackContext: playbackContext
                )
                // When the direct TMDB mapping is unavailable, only proceed if the anime
                // absolute-number fallback can supply an episode (never for specials).
                // With the setting off this collapses to the original skip behaviour.
                guard resolved != nil || canUseTraktAnimeFallback(playbackContext) else { return false }
                guard let traktId = await getTraktIdFromTmdbId(showId, mediaType: .show) else {
                    Logger.shared.log("Skipping Trakt scrobble \(action.rawValue); no Trakt show ID for TMDB \(showId)", type: "Tracker")
                    return false
                }
                guard let traktEpisodeId = await resolveTraktEpisodeIdForSync(
                    showTraktId: traktId,
                    resolved: resolved,
                    playbackContext: playbackContext,
                    account: refreshedAccount
                ) else { return false }
                payload = [
                    "progress": progress,
                    "episode": ["ids": ["trakt": traktEpisodeId]]
                ]
            }

            _ = try await postTraktJSON(
                path: "scrobble/\(action.rawValue)",
                account: refreshedAccount,
                payload: payload,
                additionalAcceptedStatusCodes: [409],
                maxRetries: action == .stop ? 3 : 2
            )

            if action != .start {
                invalidateTraktContinueWatchingCache()
            }
            Logger.shared.log("Trakt scrobble \(action.rawValue) sent at \(Int(progress.rounded()))%", type: "Tracker")
            return true
        } catch {
            Logger.shared.log("Failed Trakt scrobble \(action.rawValue): \(error.localizedDescription)", type: "Error")
            return false
        }
    }

    private func syncToTrakt(account: TrackerAccount, showId: Int, resolved: (season: Int, episode: Int)?, progress: Double, playbackContext: EpisodePlaybackContext?) async {
        do {
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(account)
            guard let traktId = await getTraktIdFromTmdbId(showId, mediaType: .show) else {
                Logger.shared.log("Could not find Trakt ID for TMDB show ID \(showId)", type: "Tracker")
                return
            }
            guard let traktEpisodeId = await resolveTraktEpisodeIdForSync(
                showTraktId: traktId,
                resolved: resolved,
                playbackContext: playbackContext,
                account: refreshedAccount
            ) else {
                return
            }

            let logSeason = resolved?.season ?? -1
            let logEpisode = resolved?.episode ?? (playbackContext?.animeAbsoluteEpisodeNumber ?? -1)
            let traktProgress = progress <= 1.0 ? progress * 100.0 : progress
            guard traktProgress >= 85 else {
                await scrobblePause(account: refreshedAccount, traktEpisodeId: traktEpisodeId, seasonNumber: logSeason, episodeNumber: logEpisode, progress: traktProgress)
                return
            }

            let watchedAt = ISO8601DateFormatter().string(from: Date())
            let payload: [String: Any] = [
                "episodes": [
                    [
                        "watched_at": watchedAt,
                        "ids": ["trakt": traktEpisodeId]
                    ]
                ]
            ]
            let data = try await postTraktJSON(path: "sync/history", account: refreshedAccount, payload: payload)
            Logger.shared.log("Trakt sync response: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")", type: "Tracker")
            Logger.shared.log("Synced to Trakt: S\(logSeason)E\(logEpisode) (watched)", type: "Tracker")
        } catch {
            Logger.shared.log("Failed to sync to Trakt: \(error.localizedDescription)", type: "Error")
        }
    }

    private func syncMovieToTrakt(account: TrackerAccount, movieId: Int, progress: Double) async {
        do {
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(account)
            guard let traktId = await getTraktIdFromTmdbId(movieId, mediaType: .movie) else {
                Logger.shared.log("Could not find Trakt ID for TMDB movie ID \(movieId)", type: "Tracker")
                return
            }

            let traktProgress = progress <= 1.0 ? progress * 100.0 : progress
            guard traktProgress >= 85 else {
                guard let detail = try? await TMDBService.shared.getMovieDetails(id: movieId),
                      let releaseDate = detail.releaseDate,
                      let year = Int(releaseDate.prefix(4)) else {
                    Logger.shared.log("Skipping Trakt movie scrobble because TMDB movie \(movieId) has no release year", type: "Tracker")
                    return
                }
                await scrobbleMoviePause(
                    account: refreshedAccount,
                    traktId: traktId,
                    title: detail.title,
                    year: year,
                    progress: traktProgress
                )
                return
            }

            let payload: [String: Any] = [
                "movies": [
                    [
                        "ids": ["trakt": traktId],
                        "watched_at": ISO8601DateFormatter().string(from: Date())
                    ]
                ]
            ]
            _ = try await postTraktJSON(path: "sync/history", account: refreshedAccount, payload: payload)
            Logger.shared.log("Synced movie to Trakt: TMDB \(movieId) (watched)", type: "Tracker")
        } catch {
            Logger.shared.log("Failed to sync movie to Trakt: \(error.localizedDescription)", type: "Error")
        }
    }

    private func scrobblePause(account: TrackerAccount, traktEpisodeId: Int, seasonNumber: Int, episodeNumber: Int, progress: Double) async {
        let payload: [String: Any] = [
            "progress": normalizedTraktScrobbleProgress(progress),
            "episode": ["ids": ["trakt": traktEpisodeId]]
        ]

        do {
            _ = try await postTraktJSON(path: "scrobble/pause", account: account, payload: payload)
            Logger.shared.log("Scrobbled to Trakt: S\(seasonNumber)E\(episodeNumber) \(Int(progress))%", type: "Tracker")
        } catch {
            Logger.shared.log("Failed to scrobble to Trakt: \(error.localizedDescription)", type: "Error")
        }
    }

    private func scrobbleMoviePause(account: TrackerAccount, traktId: Int, title: String, year: Int, progress: Double) async {
        do {
            _ = try await postTraktJSON(
                path: "scrobble/pause",
                account: account,
                payload: [
                    "progress": normalizedTraktScrobbleProgress(progress),
                    "movie": [
                        "title": title,
                        "year": year,
                        "ids": ["trakt": traktId]
                    ]
                ]
            )
            Logger.shared.log("Scrobbled movie to Trakt: \(Int(progress))%", type: "Tracker")
        } catch {
            Logger.shared.log("Failed to scrobble movie to Trakt: \(error.localizedDescription)", type: "Error")
        }
    }

    private func normalizedTraktScrobbleProgress(_ progress: Double) -> Double {
        let percent = progress <= 1.0 ? progress * 100.0 : progress
        let clamped = min(max(percent, 0), 100)
        return (clamped * 10).rounded() / 10
    }

    private func normalizedTraktPlaybackProgress(_ progress: Double?) -> (percent: Double, fraction: Double)? {
        guard let progress, progress.isFinite else { return nil }
        let percent = progress <= 1.0 ? progress * 100.0 : progress
        let clamped = min(max(percent, 0), 100)
        guard clamped > 0 else { return nil }
        return (clamped, clamped / 100.0)
    }

    private func postTraktJSON(
        path: String,
        account: TrackerAccount,
        payload: [String: Any],
        allowsRefreshRetry: Bool = true,
        additionalAcceptedStatusCodes: Set<Int> = [],
        maxRetries: Int = 2
    ) async throws -> Data {
        guard !traktClientId.isEmpty else {
            throw NSError(domain: "Trakt", code: -1, userInfo: [NSLocalizedDescriptionKey: "TRAKT_CLIENT_ID is not configured."])
        }

        let url = URL(string: "https://api.trakt.tv/\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await sendTrackerRequest(
            request,
            provider: .trakt,
            maxRetries: maxRetries,
            reportRateLimitStatus: false
        )
        let statusCode = response.statusCode
        if statusCode == 401, allowsRefreshRetry {
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(account, force: true)
            return try await postTraktJSON(
                path: path,
                account: refreshedAccount,
                payload: payload,
                allowsRefreshRetry: false,
                additionalAcceptedStatusCodes: additionalAcceptedStatusCodes,
                maxRetries: maxRetries
            )
        }
        guard (200...299).contains(statusCode) || additionalAcceptedStatusCodes.contains(statusCode) else {
            let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw NSError(domain: "Trakt", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Trakt \(path) returned status \(statusCode): \(bodyPreview)"])
        }
        return data
    }

    private func getTraktIdFromTmdbId(_ tmdbId: Int, mediaType: TraktMediaType) async -> Int? {
        let cacheKey = "\(mediaType.rawValue)|\(tmdbId)"
        if let cached = traktMediaIdCacheQueue.sync(execute: { traktMediaIdCache[cacheKey] }) {
            return cached
        }

        do {
            guard !traktClientId.isEmpty else {
                Logger.shared.log("Skipping Trakt TMDB lookup because TRAKT_CLIENT_ID is not configured.", type: "Tracker")
                return nil
            }

            let url = URL(string: "https://api.trakt.tv/search/tmdb/\(tmdbId)?type=\(mediaType.rawValue)")!
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
            request.setValue("2", forHTTPHeaderField: "trakt-api-version")

            let (data, response) = try await sendTrackerRequest(request, provider: .trakt, reportRateLimitStatus: false)
            if response.statusCode != 200 {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                Logger.shared.log("Trakt tmdb lookup failed (HTTP \(response.statusCode)): \(bodyPreview)", type: "Tracker")
                return nil
            }

            struct SearchResult: Decodable {
                let show: MediaData?
                let movie: MediaData?

                struct MediaData: Decodable {
                    let ids: IDData

                    struct IDData: Decodable {
                        let trakt: Int
                    }
                }
            }

            guard let result = try JSONDecoder().decode([SearchResult].self, from: data).first else {
                return nil
            }
            let traktId = mediaType == .show ? result.show?.ids.trakt : result.movie?.ids.trakt
            if let traktId {
                traktMediaIdCacheQueue.sync {
                    traktMediaIdCache[cacheKey] = traktId
                }
            }
            return traktId
        } catch {
            Logger.shared.log("Failed to get Trakt ID: \(error.localizedDescription)", type: "Error")
            return nil
        }
    }

    private func getTraktEpisodeId(showTraktId: Int, seasonNumber: Int, episodeNumber: Int, account: TrackerAccount) async -> Int? {
        let cacheKey = "episode|\(showTraktId)|\(seasonNumber)|\(episodeNumber)"
        if let cached = traktMediaIdCacheQueue.sync(execute: { traktMediaIdCache[cacheKey] }) {
            return cached
        }

        do {
            let data = try await fetchTraktPlaybackData(
                path: "shows/\(showTraktId)/seasons/\(seasonNumber)/episodes/\(episodeNumber)",
                account: account
            )
            let episode = try JSONDecoder().decode(TraktEpisode.self, from: data)
            guard let traktEpisodeId = episode.ids?.trakt else {
                Logger.shared.log("Trakt episode lookup returned no ID for show \(showTraktId) S\(seasonNumber)E\(episodeNumber)", type: "Tracker")
                return nil
            }
            traktMediaIdCacheQueue.sync {
                traktMediaIdCache[cacheKey] = traktEpisodeId
            }
            return traktEpisodeId
        } catch {
            Logger.shared.log("Failed to resolve Trakt episode ID for show \(showTraktId) S\(seasonNumber)E\(episodeNumber): \(error.localizedDescription)", type: "Error")
            return nil
        }
    }

    private struct TraktSeasonWithEpisodes: Decodable {
        let number: Int
        let episodes: [TraktEpisode]?
    }

    /// Anime / absolute-numbering fallback.
    private func traktFlattenedEpisodeId(showTraktId: Int, absoluteEpisodeNumber: Int, account: TrackerAccount) async -> Int? {
        guard absoluteEpisodeNumber > 0 else { return nil }
        let cacheKey = "episode-abs|\(showTraktId)|\(absoluteEpisodeNumber)"
        if let cached = traktMediaIdCacheQueue.sync(execute: { traktMediaIdCache[cacheKey] }) {
            return cached
        }

        do {
            let data = try await fetchTraktPlaybackData(
                path: "shows/\(showTraktId)/seasons?extended=episodes",
                account: account
            )
            let seasons = try JSONDecoder().decode([TraktSeasonWithEpisodes].self, from: data)
            // Exclude specials (season 0) and order by (season, episode) so position N
            // matches absolute episode N.
            let ordered = seasons
                .filter { $0.number > 0 }
                .sorted { $0.number < $1.number }
                .flatMap { ($0.episodes ?? []).sorted { $0.number < $1.number } }

            guard absoluteEpisodeNumber <= ordered.count else {
                Logger.shared.log("Trakt absolute episode \(absoluteEpisodeNumber) out of range (\(ordered.count) episodes) for show \(showTraktId)", type: "Tracker")
                return nil
            }
            guard let traktEpisodeId = ordered[absoluteEpisodeNumber - 1].ids?.trakt else { return nil }
            traktMediaIdCacheQueue.sync {
                traktMediaIdCache[cacheKey] = traktEpisodeId
            }
            Logger.shared.log("Resolved Trakt episode via absolute mapping: show \(showTraktId) abs#\(absoluteEpisodeNumber) -> episode \(traktEpisodeId)", type: "Tracker")
            return traktEpisodeId
        } catch {
            Logger.shared.log("Trakt absolute episode mapping failed for show \(showTraktId) abs#\(absoluteEpisodeNumber): \(error.localizedDescription)", type: "Error")
            return nil
        }
    }

    /// Resolve a Trakt episode id for scrobble/sync.
    private func resolveTraktEpisodeIdForSync(
        showTraktId: Int,
        resolved: (season: Int, episode: Int)?,
        playbackContext: EpisodePlaybackContext?,
        account: TrackerAccount
    ) async -> Int? {
        if let resolved,
           let directId = await getTraktEpisodeId(
                showTraktId: showTraktId,
                seasonNumber: resolved.season,
                episodeNumber: resolved.episode,
                account: account
           ) {
            return directId
        }

        guard trackerState.traktAnimeEpisodeMapping,
              let context = playbackContext,
              !context.isSpecial,
              let absolute = context.animeAbsoluteEpisodeNumber else {
            return nil
        }
        return await traktFlattenedEpisodeId(
            showTraktId: showTraktId,
            absoluteEpisodeNumber: absolute,
            account: account
        )
    }

    /// Whether the anime absolute-number fallback can supply a Trakt episode when the
    /// direct TMDB mapping is unavailable (never for specials).
    private func canUseTraktAnimeFallback(_ playbackContext: EpisodePlaybackContext?) -> Bool {
        trackerState.traktAnimeEpisodeMapping
            && playbackContext?.isSpecial != true
            && playbackContext?.animeAbsoluteEpisodeNumber != nil
    }

    private func traktDate(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }


    // MARK: - Helper Methods

    private func getMyAnimeListId(fromAniListId aniListId: Int, mediaType: String) async -> Int? {
        if let cached = cachedMyAnimeListId(fromAniListId: aniListId, mediaType: mediaType) {
            return cached
        }

        let query = """
        query {
            Media(id: \(aniListId), type: \(mediaType)) {
                idMal
            }
        }
        """

        struct Response: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable {
                let Media: MediaData?
                struct MediaData: Codable { let idMal: Int? }
            }
        }

        do {
            var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            guard response.statusCode == 200 else { return nil }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            if let malId = decoded.data.Media?.idMal {
                cacheMyAnimeListId(malId, forAniListId: aniListId, mediaType: mediaType)
                return malId
            }
            return nil
        } catch {
            Logger.shared.log("Failed to resolve MAL ID for AniList \(aniListId): \(error.localizedDescription)", type: "Tracker")
            return nil
        }
    }

    private func getAniListId(fromMALId malId: Int, mediaType: String) async -> Int? {
        if let cached = cachedAniListIds(fromMALIds: [malId], mediaType: mediaType)[malId] {
            return cached
        }

        let query = """
        query {
            Media(idMal: \(malId), type: \(mediaType)) {
                id
            }
        }
        """

        struct Response: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable {
                let Media: MediaData?
                struct MediaData: Codable { let id: Int }
            }
        }

        do {
            var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            guard response.statusCode == 200 else { return nil }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            if let aniListId = decoded.data.Media?.id {
                cacheAniListId(aniListId, forMALId: malId, mediaType: mediaType)
                return aniListId
            }
            return nil
        } catch {
            Logger.shared.log("Failed to resolve AniList ID from MAL \(malId): \(error.localizedDescription)", type: "Tracker")
            return nil
        }
    }

    private func getAniListEpisodeCount(mediaId: Int) async -> Int? {
        if let cached = aniListEpisodeCountCache[mediaId] {
            return cached
        }

        let query = """
        query {
            Media(id: \(mediaId), type: ANIME) {
                episodes
            }
        }
        """

        struct Response: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable {
                let Media: MediaData?
                struct MediaData: Codable {
                    let episodes: Int?
                }
            }
        }

        do {
            var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            guard response.statusCode == 200 else { return nil }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            if let episodes = decoded.data.Media?.episodes {
                aniListEpisodeCountCache[mediaId] = episodes
                return episodes
            }
            return nil
        } catch {
            Logger.shared.log("Failed to fetch AniList episode count for mediaId \(mediaId): \(error.localizedDescription)", type: "Tracker")
            return nil
        }
    }

    func getAniListMediaId(tmdbId: Int) async -> Int? {
        // Return cached mapping when available
        if let cachedId = cachedAniListId(for: tmdbId) {
            return cachedId
        }

        // Fetch TMDB metadata to derive candidate titles for AniList search
        var candidateTitles: [String] = []
        var firstAirYear: Int?

        if let detail = try? await TMDBService.shared.getTVShowDetails(id: tmdbId) {
            candidateTitles.append(detail.name)
            if let original = detail.originalName { candidateTitles.append(original) }

            if let firstAirDate = detail.firstAirDate, let year = Int(firstAirDate.prefix(4)) {
                firstAirYear = year
            }

            if let alt = try? await TMDBService.shared.getTVShowAlternativeTitles(id: tmdbId) {
                candidateTitles.append(contentsOf: alt.results.map { $0.title })
            }
        }

        // Remove empties and duplicates while preserving order
        var seen = Set<String>()
        let titles = candidateTitles.compactMap { title -> String? in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed.lowercased()) else { return nil }
            seen.insert(trimmed.lowercased())
            return trimmed
        }

        for title in titles {
            if let id = await searchAniListId(byTitle: title, seasonYear: firstAirYear) {
                cacheAniListId(tmdbId: tmdbId, anilistId: id)
                Logger.shared.log("Resolved AniList ID \(id) for TMDB \(tmdbId) using title '" + title + "'", type: "Tracker")
                return id
            }
        }

        Logger.shared.log("AniList lookup failed for TMDB ID \(tmdbId) after trying \(titles.count) title(s)", type: "Tracker")
        return nil
    }

    private func searchAniListId(byTitle title: String, seasonYear: Int?) async -> Int? {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let seasonFilter = seasonYear.map { ", seasonYear: \($0)" } ?? ""

        let query = """
        query {
            Page(perPage: 1) {
                media(search: \"\(escapedTitle)\", type: ANIME\(seasonFilter)) {
                    id
                }
            }
        }
        """

        struct Response: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable {
                let Page: PageData
                struct PageData: Codable { let media: [Media] }
                struct Media: Codable { let id: Int }
            }
        }

        do {
            var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            guard response.statusCode == 200 else { return nil }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.data.Page.media.first?.id
        } catch {
            Logger.shared.log("AniList title search failed for \(title): \(error.localizedDescription)", type: "Tracker")
            return nil
        }
    }

#if !os(tvOS)
    private func getAniListMangaId(title: String) async -> Int? {
        await resolveMangaTrackerMatch(
            title: title,
            totalChapters: nil,
            format: nil,
            routeKey: nil,
            knownAniListId: nil,
            knownMALId: nil
        )?.aniListId
    }

    private func resolveMangaTrackerMatch(title: String, totalChapters: Int?, format: String?, routeKey: String?, knownAniListId: Int?, knownMALId: Int?) async -> MangaTrackerMatch? {
        if let knownAniListId, knownAniListId > 0 {
            let match = MangaTrackerMatch(aniListId: knownAniListId, malId: knownMALId, title: title, confidence: 100)
            if let routeKey {
                cacheMangaTrackerMatch(match, for: routeKey)
            }
            return match
        }

        if let knownMALId, knownMALId > 0, knownAniListId == nil {
            let aniListId = await getAniListId(fromMALId: knownMALId, mediaType: "MANGA")
            let match = MangaTrackerMatch(aniListId: aniListId, malId: knownMALId, title: title, confidence: 100)
            if let routeKey {
                cacheMangaTrackerMatch(match, for: routeKey)
            }
            return match
        }

        let cacheKey = routeKey ?? mangaTrackerCacheKey(title: title, totalChapters: totalChapters, format: format)
        if let cached = cachedMangaTrackerMatch(for: cacheKey) {
            return cached
        }

        async let aniListMatch = searchAniListMangaTrackerMatch(title: title, totalChapters: totalChapters, format: format)
        async let malMatch = searchMALMangaTrackerMatch(title: title, totalChapters: totalChapters, format: format)

        let resolvedAniList = await aniListMatch
        let resolvedMAL = await malMatch
        let bestConfidence = max(resolvedAniList?.confidence ?? 0, resolvedMAL?.confidence ?? 0)
        let threshold = mangaTrackerConfidenceThreshold(totalChapters: totalChapters)

        guard bestConfidence >= threshold else {
            ReaderLogger.shared.log("Manga tracker resolver dropped '\(title)' confidence=\(Int(bestConfidence)) threshold=\(Int(threshold))", type: "Tracker")
            return nil
        }

        let acceptedAniList = resolvedAniList.flatMap { $0.confidence >= threshold ? $0 : nil }
        let acceptedMAL = resolvedMAL.flatMap { $0.confidence >= threshold ? $0 : nil }
        let match: MangaTrackerMatch?
        if let acceptedAniList, let acceptedMAL {
            match = await reconciledMangaTrackerMatch(aniListMatch: acceptedAniList, malMatch: acceptedMAL, fallbackTitle: title)
        } else if let acceptedAniList {
            match = acceptedAniList
        } else if let acceptedMAL {
            match = await mangaTrackerMatchResolvingAniListFromMAL(acceptedMAL)
        } else {
            match = nil
        }

        guard let match, match.isUsable else { return nil }
        cacheMangaTrackerMatch(match, for: cacheKey)
        return match
    }

    private func searchAniListMangaTrackerMatch(title: String, totalChapters: Int?, format: String?) async -> MangaTrackerMatch? {
        let escaped = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let query = """
        query {
            Page(page: 1, perPage: 8) {
                media(search: "\(escaped)", type: MANGA) {
                    id
                    idMal
                    chapters
                    format
                    title {
                        romaji
                        english
                        native
                    }
                    synonyms
                }
            }
        }
        """

        struct Response: Decodable {
            let data: DataWrapper?
            struct DataWrapper: Decodable { let Page: PageWrapper? }
            struct PageWrapper: Decodable { let media: [Media] }
            struct Media: Decodable {
                let id: Int
                let idMal: Int?
                let chapters: Int?
                let format: String?
                let title: Title
                let synonyms: [String]?
            }
            struct Title: Decodable {
                let romaji: String?
                let english: String?
                let native: String?
            }
        }

        do {
            var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            guard response.statusCode == 200 else { return nil }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.data?.Page?.media
                .map { media in
                    let titles = [media.title.romaji, media.title.english, media.title.native].compactMap { $0 } + (media.synonyms ?? [])
                    let confidence = mangaMatchConfidence(
                        query: title,
                        candidateTitles: titles,
                        expectedChapters: totalChapters,
                        candidateChapters: media.chapters,
                        expectedFormat: format,
                        candidateFormat: media.format
                    )
                    return MangaTrackerMatch(
                        aniListId: media.id,
                        malId: media.idMal,
                        title: titles.first ?? title,
                        confidence: confidence
                    )
                }
                .max { $0.confidence < $1.confidence }
        } catch {
            ReaderLogger.shared.log("AniList manga resolver failed for \(title): \(error.localizedDescription)", type: "Tracker")
            return nil
        }
    }

    private func searchMALMangaTrackerMatch(title: String, totalChapters: Int?, format: String?) async -> MangaTrackerMatch? {
        guard var components = URLComponents(string: "https://api.myanimelist.net/v2/manga") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "q", value: title),
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "fields", value: "id,title,alternative_titles,num_chapters,media_type")
        ]
        guard let url = components.url else { return nil }

        struct Response: Decodable {
            let data: [Entry]
            struct Entry: Decodable { let node: Node }
            struct Node: Decodable {
                let id: Int
                let title: String
                let alternativeTitles: AlternativeTitles?
                let numChapters: Int?
                let mediaType: String?

                enum CodingKeys: String, CodingKey {
                    case id
                    case title
                    case alternativeTitles = "alternative_titles"
                    case numChapters = "num_chapters"
                    case mediaType = "media_type"
                }
            }
            struct AlternativeTitles: Decodable {
                let synonyms: [String]?
                let en: String?
                let ja: String?
            }
        }

        do {
            var request = URLRequest(url: url)
            if !malClientId.isEmpty {
                request.setValue(malClientId, forHTTPHeaderField: "X-MAL-CLIENT-ID")
            } else if let account = trackerState.accounts.first(where: { $0.isConnected && $0.service == .myAnimeList }),
                      let refreshed = try? await refreshedMALAccountIfNeeded(account) {
                request.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
            } else {
                return nil
            }

            let (data, response) = try await sendTrackerRequest(request, provider: .myAnimeList)
            guard response.statusCode == 200 else { return nil }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.data
                .map { entry in
                    let node = entry.node
                    let titles = [node.title, node.alternativeTitles?.en, node.alternativeTitles?.ja]
                        .compactMap { $0 } + (node.alternativeTitles?.synonyms ?? [])
                    let confidence = mangaMatchConfidence(
                        query: title,
                        candidateTitles: titles,
                        expectedChapters: totalChapters,
                        candidateChapters: node.numChapters,
                        expectedFormat: format,
                        candidateFormat: node.mediaType
                    )
                    return MangaTrackerMatch(
                        aniListId: nil,
                        malId: node.id,
                        title: titles.first ?? title,
                        confidence: confidence
                    )
                }
                .max { $0.confidence < $1.confidence }
        } catch {
            ReaderLogger.shared.log("MAL manga resolver failed for \(title): \(error.localizedDescription)", type: "Tracker")
            return nil
        }
    }

    private func reconciledMangaTrackerMatch(
        aniListMatch: MangaTrackerMatch,
        malMatch: MangaTrackerMatch,
        fallbackTitle: String
    ) async -> MangaTrackerMatch {
        let confidence = max(aniListMatch.confidence, malMatch.confidence)
        let title = aniListMatch.confidence >= malMatch.confidence ? aniListMatch.title : malMatch.title

        if let aniListMALId = aniListMatch.malId, let malId = malMatch.malId {
            if aniListMALId == malId {
                return MangaTrackerMatch(
                    aniListId: aniListMatch.aniListId,
                    malId: malId,
                    title: title,
                    confidence: confidence
                )
            }

            ReaderLogger.shared.log(
                "Manga tracker resolver provider mismatch for '\(fallbackTitle)': AniList idMal=\(aniListMALId) MAL id=\(malId). Using higher-confidence provider only.",
                type: "Tracker"
            )
            return await preferredSingleProviderMangaMatch(aniListMatch: aniListMatch, malMatch: malMatch)
        }

        if let aniListId = aniListMatch.aniListId, let malId = malMatch.malId {
            if let mappedAniListId = await getAniListId(fromMALId: malId, mediaType: "MANGA") {
                if mappedAniListId == aniListId {
                    return MangaTrackerMatch(
                        aniListId: aniListId,
                        malId: malId,
                        title: title,
                        confidence: confidence
                    )
                }

                ReaderLogger.shared.log(
                    "Manga tracker resolver provider mismatch for '\(fallbackTitle)': AniList id=\(aniListId) MAL maps to AniList id=\(mappedAniListId). Using higher-confidence provider only.",
                    type: "Tracker"
                )
                return await preferredSingleProviderMangaMatch(aniListMatch: aniListMatch, malMatch: malMatch)
            }
        }

        ReaderLogger.shared.log(
            "Manga tracker resolver could not cross-confirm AniList/MAL matches for '\(fallbackTitle)'. Using higher-confidence provider only.",
            type: "Tracker"
        )
        return await preferredSingleProviderMangaMatch(aniListMatch: aniListMatch, malMatch: malMatch)
    }

    private func preferredSingleProviderMangaMatch(
        aniListMatch: MangaTrackerMatch,
        malMatch: MangaTrackerMatch
    ) async -> MangaTrackerMatch {
        if aniListMatch.confidence >= malMatch.confidence {
            return aniListMatch
        }
        return await mangaTrackerMatchResolvingAniListFromMAL(malMatch)
    }

    private func mangaTrackerMatchResolvingAniListFromMAL(_ match: MangaTrackerMatch) async -> MangaTrackerMatch {
        guard match.aniListId == nil, let malId = match.malId else { return match }
        let aniListId = await getAniListId(fromMALId: malId, mediaType: "MANGA")
        return MangaTrackerMatch(
            aniListId: aniListId,
            malId: malId,
            title: match.title,
            confidence: match.confidence
        )
    }

    private func cachedMangaTrackerMatch(for key: String) -> MangaTrackerMatch? {
        mangaTrackerMatchCacheQueue.sync {
            mangaTrackerMatchCache[key]
        }
    }

    private func cacheMangaTrackerMatch(_ match: MangaTrackerMatch, for key: String) {
        mangaTrackerMatchCacheQueue.sync {
            mangaTrackerMatchCache[key] = match
        }
    }

    private func mangaTrackerCacheKey(title: String, totalChapters: Int?, format: String?) -> String {
        "\(normalizedMangaTitle(title))|\(totalChapters.map(String.init) ?? "-")|\(format ?? "-")"
    }

    private func mangaTrackerConfidenceThreshold(totalChapters: Int?) -> Double {
        totalChapters == nil ? 78 : 68
    }

    private func mangaMatchConfidence(query: String, candidateTitles: [String], expectedChapters: Int?, candidateChapters: Int?, expectedFormat: String?, candidateFormat: String?) -> Double {
        let queryTitle = normalizedMangaTitle(query)
        guard !queryTitle.isEmpty else { return 0 }

        let titleScore = candidateTitles
            .map { normalizedMangaTitle($0) }
            .filter { !$0.isEmpty }
            .map { candidate -> Double in
                if candidate == queryTitle { return 82 }
                if candidate.hasPrefix(queryTitle) || queryTitle.hasPrefix(candidate) { return 70 }
                if candidate.contains(queryTitle) || queryTitle.contains(candidate) { return 62 }
                return tokenOverlapScore(queryTitle, candidate) * 58
            }
            .max() ?? 0

        var score = titleScore
        if let expectedChapters, expectedChapters > 0, let candidateChapters, candidateChapters > 0 {
            let delta = abs(expectedChapters - candidateChapters)
            if delta == 0 {
                score += 18
            } else if delta <= 2 {
                score += 12
            } else if delta <= 8 {
                score += 6
            } else if delta > max(20, expectedChapters / 3) {
                score -= 18
            }
        }

        let expected = (expectedFormat ?? "").lowercased()
        let candidate = (candidateFormat ?? "").lowercased()
        if !expected.isEmpty, !candidate.isEmpty {
            if expected.contains("novel") && candidate.contains("novel") {
                score += 8
            } else if expected.contains("webtoon") && (candidate.contains("manhwa") || candidate.contains("web") || candidate.contains("manga")) {
                score += 2
            } else if expected.contains("novel") != candidate.contains("novel") {
                score -= 8
            }
        }

        return max(0, min(100, score))
    }

    private func normalizedMangaTitle(_ title: String) -> String {
        title
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func tokenOverlapScore(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init))
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        let intersection = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }
#endif

    // MARK: - Sync Tools

#if !os(tvOS)
    func previewSyncTool(_ action: TrackerSyncToolAction) {
        guard !isRunningSyncTool else { return }

        Task {
            await MainActor.run {
                self.isRunningSyncTool = true
                self.syncToolStatus = "Building preview..."
                self.syncToolPreview = nil
                self.syncToolProgressCompleted = 0
                self.syncToolProgressTotal = 0
                self.syncToolProgressDetail = nil
                self.syncToolIsLocked = false
            }

            do {
                let plan = try await buildSyncToolPlan(for: action)
                await MainActor.run {
                    self.cachedSyncToolPlan = plan
                    self.syncToolPreview = plan.preview
                    self.syncToolStatus = "Preview ready"
                    self.isRunningSyncTool = false
                }
            } catch {
                await MainActor.run {
                    self.syncToolStatus = "Preview failed: \(error.localizedDescription)"
                    self.isRunningSyncTool = false
                }
            }
        }
    }

    func runSyncTool(_ action: TrackerSyncToolAction) {
        guard !isRunningSyncTool else { return }

        let task = Task {
            await MainActor.run {
                self.isRunningSyncTool = true
                self.syncToolStatus = "Running \(action.title)..."
                self.syncToolProgressCompleted = 0
                self.syncToolProgressTotal = 0
                self.syncToolProgressDetail = "Preparing sync..."
            }

            do {
                let plan = try await cachedOrBuildSyncToolPlan(for: action)
                let total = syncToolOperationCount(for: plan)
                await MainActor.run {
                    self.syncToolProgressCompleted = 0
                    self.syncToolProgressTotal = total
                    self.syncToolProgressDetail = total > 0 ? "0 of \(total) operations complete" : "No write operations needed"
                    self.syncToolIsLocked = plan.preview.estimatedAPICalls >= self.largeSyncAPICallThreshold || total >= self.largeSyncAPICallThreshold
                }
                let result = try await performSyncTool(plan)
                await MainActor.run {
                    self.cachedSyncToolPlan = nil
                    self.syncToolPreview = result
                    self.syncToolStatus = "Finished \(action.title)"
                    self.syncToolProgressCompleted = self.syncToolProgressTotal
                    self.syncToolProgressDetail = "Finished"
                    self.syncToolIsLocked = false
                    self.isRunningSyncTool = false
                    self.syncToolTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.syncToolStatus = "Canceled \(action.title)"
                    self.syncToolProgressDetail = "Canceled"
                    self.syncToolIsLocked = false
                    self.isRunningSyncTool = false
                    self.syncToolTask = nil
                }
            } catch {
                await MainActor.run {
                    self.syncToolStatus = "Sync failed: \(error.localizedDescription)"
                    self.syncToolProgressDetail = nil
                    self.syncToolIsLocked = false
                    self.isRunningSyncTool = false
                    self.syncToolTask = nil
                }
            }
        }
        syncToolTask = task
    }

    func cancelSyncTool() {
        syncToolTask?.cancel()
        Task { @MainActor in
            self.syncToolStatus = "Canceling sync..."
            self.syncToolProgressDetail = "Stopping after the current request..."
        }
    }

    private func cachedOrBuildSyncToolPlan(for action: TrackerSyncToolAction) async throws -> TrackerSyncToolPlan {
        if let cachedSyncToolPlan, cachedSyncToolPlan.action == action {
            return cachedSyncToolPlan
        }
        let plan = try await buildSyncToolPlan(for: action)
        cachedSyncToolPlan = plan
        return plan
    }

    private func syncToolOperationCount(for plan: TrackerSyncToolPlan) -> Int {
        switch plan.action {
        case .fillEclipseFromAniList, .fillEclipseFromMAL, .portAniListToMAL, .portMALToAniList:
            return plan.animeEntries.count + plan.mangaEntries.count
        case .pushEclipseToAniList, .pushEclipseToMAL:
            return localHighestWatchedEpisodes().count + localHighestReadMangaChapters().count
        }
    }

    private func updateSyncToolProgress(detail: String?) async {
        await MainActor.run {
            self.syncToolProgressDetail = detail
        }
    }

    private func advanceSyncToolProgress(by amount: Int = 1, detail: String? = nil) async throws {
        try Task.checkCancellation()
        await MainActor.run {
            self.syncToolProgressCompleted = min(self.syncToolProgressCompleted + amount, self.syncToolProgressTotal)
            if let detail {
                self.syncToolProgressDetail = detail
            } else if self.syncToolProgressTotal > 0 {
                self.syncToolProgressDetail = "\(self.syncToolProgressCompleted) of \(self.syncToolProgressTotal) operations complete"
            }
        }
    }

    private func buildSyncToolPreview(for action: TrackerSyncToolAction) async throws -> TrackerSyncPreview {
        try await buildSyncToolPlan(for: action).preview
    }

    private func buildSyncToolPlan(for action: TrackerSyncToolAction) async throws -> TrackerSyncToolPlan {
        switch action {
        case .fillEclipseFromAniList:
            let account = try connectedAccount(.anilist)
            let animeEntries = try await fetchAniListAnimeProgressEntries(account: account)
            let mangaEntries = try await fetchAniListMangaProgressEntries(account: account)
            let animePreview = previewForRemoteFill(action: action, entries: animeEntries, sourceName: "AniList")
            let mangaMapped = mangaEntries.filter { $0.anilistId != nil }
            let mangaUnmapped = mangaEntries.count - mangaMapped.count
            let preview = TrackerSyncPreview(
                action: action,
                itemsToAdd: animePreview.itemsToAdd,
                itemsToAdvance: animePreview.itemsToAdvance + mangaMapped.filter { remoteReadChapters($0) > 0 }.count,
                skipped: animePreview.skipped + mangaUnmapped,
                unmapped: animePreview.unmapped + mangaUnmapped,
                estimatedAPICalls: estimatedReadCalls(sourceName: "AniList", animeCount: animeEntries.count, mangaCount: mangaEntries.count),
                notes: ["AniList fill reuses this preview when you run it; local progress is never deleted or downgraded."]
            )
            return TrackerSyncToolPlan(action: action, preview: preview, animeEntries: animeEntries, mangaEntries: mangaEntries)

        case .fillEclipseFromMAL:
            let account = try connectedAccount(.myAnimeList)
            let animeEntries = await resolveMALAnimeEntriesToAniList(try await fetchMALAnimeProgressEntries(account: account))
            let mangaEntries = await resolveMALMangaEntriesToAniList(try await fetchMALMangaProgressEntries(account: account))
            let animePreview = previewForRemoteFill(action: action, entries: animeEntries, sourceName: "MAL")
            let mangaMapped = mangaEntries.filter { $0.anilistId != nil }
            let mangaUnmapped = mangaEntries.count - mangaMapped.count
            let preview = TrackerSyncPreview(
                action: action,
                itemsToAdd: animePreview.itemsToAdd,
                itemsToAdvance: animePreview.itemsToAdvance + mangaMapped.filter { remoteReadChapters($0) > 0 }.count,
                skipped: animePreview.skipped + mangaUnmapped,
                unmapped: animePreview.unmapped + mangaUnmapped,
                estimatedAPICalls: estimatedReadCalls(sourceName: "MAL", animeCount: animeEntries.count, mangaCount: mangaEntries.count),
                notes: ["MAL IDs are resolved in batches through AniList, then local progress advances without overwrites."]
            )
            return TrackerSyncToolPlan(action: action, preview: preview, animeEntries: animeEntries, mangaEntries: mangaEntries)

        case .pushEclipseToAniList:
            _ = try connectedAccount(.anilist)
            let anime = localHighestWatchedEpisodes()
            let manga = localHighestReadMangaChapters()
            let preview = TrackerSyncPreview(
                action: action,
                itemsToAdd: 0,
                itemsToAdvance: anime.count + manga.count,
                skipped: 0,
                unmapped: 0,
                estimatedAPICalls: anime.count * 3 + manga.count,
                notes: ["Local Eclipse progress will only push watched/read progress; it will not delete or downgrade AniList."]
            )
            return TrackerSyncToolPlan(action: action, preview: preview)

        case .pushEclipseToMAL:
            _ = try connectedAccount(.myAnimeList)
            let anime = localHighestWatchedEpisodes()
            let manga = localHighestReadMangaChapters()
            let preview = TrackerSyncPreview(
                action: action,
                itemsToAdd: 0,
                itemsToAdvance: anime.count + manga.count,
                skipped: 0,
                unmapped: 0,
                estimatedAPICalls: anime.count * 4 + manga.count * 2,
                notes: ["Local Eclipse progress will resolve AniList/MAL IDs first, then push watched/read counts."]
            )
            return TrackerSyncToolPlan(action: action, preview: preview)

        case .portAniListToMAL:
            let account = try connectedAccount(.anilist)
            let destination = try connectedAccount(.myAnimeList)
            let sourceAnimeEntries = try await fetchAniListAnimeProgressEntries(account: account)
            let sourceMangaEntries = try await fetchAniListMangaProgressEntries(account: account)
            let destinationAnime = try await fetchMALAnimeProgressEntries(account: destination)
            let destinationManga = try await fetchMALMangaProgressEntries(account: destination)
            let destinationAnimeByMAL = remoteAnimeByMALId(destinationAnime)
            let destinationMangaByMAL = remoteMangaByMALId(destinationManga)
            let animeEntries = sourceAnimeEntries.filter { entry in
                guard let malId = entry.malId else { return false }
                return shouldWriteAnimeProgress(source: entry, destination: destinationAnimeByMAL[malId])
            }
            let mangaEntries = sourceMangaEntries.filter { entry in
                guard let malId = entry.malId else { return false }
                return shouldWriteMangaProgress(source: entry, destination: destinationMangaByMAL[malId])
            }
            let mapped = animeEntries.count + mangaEntries.count
            let alreadyCurrent = sourceAnimeEntries.filter { entry in
                guard let malId = entry.malId else { return false }
                return !shouldWriteAnimeProgress(source: entry, destination: destinationAnimeByMAL[malId])
            }.count + sourceMangaEntries.filter { entry in
                guard let malId = entry.malId else { return false }
                return !shouldWriteMangaProgress(source: entry, destination: destinationMangaByMAL[malId])
            }.count
            let total = sourceAnimeEntries.count + sourceMangaEntries.count
            let unmapped = max(0, total - mapped - alreadyCurrent)
            let preview = TrackerSyncPreview(
                action: action,
                itemsToAdd: 0,
                itemsToAdvance: mapped,
                skipped: total - mapped,
                unmapped: unmapped,
                estimatedAPICalls: estimatedReadCalls(sourceName: "AniList", animeCount: sourceAnimeEntries.count, mangaCount: sourceMangaEntries.count) + estimatedReadCalls(sourceName: "MAL", animeCount: destinationAnime.count, mangaCount: destinationManga.count) + mapped,
                notes: ["Only entries that advance MAL are written; already-current destination entries are skipped."]
            )
            return TrackerSyncToolPlan(action: action, preview: preview, animeEntries: animeEntries, mangaEntries: mangaEntries)

        case .portMALToAniList:
            let account = try connectedAccount(.myAnimeList)
            let destination = try connectedAccount(.anilist)
            let sourceAnimeEntries = await resolveMALAnimeEntriesToAniList(try await fetchMALAnimeProgressEntries(account: account))
            let sourceMangaEntries = await resolveMALMangaEntriesToAniList(try await fetchMALMangaProgressEntries(account: account))
            let destinationAnime = try await fetchAniListAnimeProgressEntries(account: destination)
            let destinationManga = try await fetchAniListMangaProgressEntries(account: destination)
            let destinationAnimeByAniList = remoteAnimeByAniListId(destinationAnime)
            let destinationMangaByAniList = remoteMangaByAniListId(destinationManga)
            let animeEntries = sourceAnimeEntries.filter { entry in
                guard let anilistId = entry.anilistId else { return false }
                return shouldWriteAnimeProgress(source: entry, destination: destinationAnimeByAniList[anilistId])
            }
            let mangaEntries = sourceMangaEntries.filter { entry in
                guard let anilistId = entry.anilistId else { return false }
                return shouldWriteMangaProgress(source: entry, destination: destinationMangaByAniList[anilistId])
            }
            let mapped = animeEntries.count + mangaEntries.count
            let alreadyCurrent = sourceAnimeEntries.filter { entry in
                guard let anilistId = entry.anilistId else { return false }
                return !shouldWriteAnimeProgress(source: entry, destination: destinationAnimeByAniList[anilistId])
            }.count + sourceMangaEntries.filter { entry in
                guard let anilistId = entry.anilistId else { return false }
                return !shouldWriteMangaProgress(source: entry, destination: destinationMangaByAniList[anilistId])
            }.count
            let total = sourceAnimeEntries.count + sourceMangaEntries.count
            let unmapped = max(0, total - mapped - alreadyCurrent)
            let preview = TrackerSyncPreview(
                action: action,
                itemsToAdd: 0,
                itemsToAdvance: mapped,
                skipped: total - mapped,
                unmapped: unmapped,
                estimatedAPICalls: estimatedReadCalls(sourceName: "MAL", animeCount: sourceAnimeEntries.count, mangaCount: sourceMangaEntries.count) + estimatedReadCalls(sourceName: "AniList", animeCount: destinationAnime.count, mangaCount: destinationManga.count) + mapped,
                notes: ["MAL IDs are resolved in batches, and only entries that advance AniList are written."]
            )
            return TrackerSyncToolPlan(action: action, preview: preview, animeEntries: animeEntries, mangaEntries: mangaEntries)
        }
    }

    private func performSyncTool(_ plan: TrackerSyncToolPlan) async throws -> TrackerSyncPreview {
        try Task.checkCancellation()
        let action = plan.action
        switch action {
        case .fillEclipseFromAniList:
            _ = try connectedAccount(.anilist)
            await updateSyncToolProgress(detail: "Filling Eclipse anime from AniList...")
            let animeResult = try await fillEclipseFromRemoteAnime(plan.animeEntries, sourceName: "AniList", action: action)
            try await advanceSyncToolProgress(by: plan.animeEntries.count, detail: "Finished AniList anime fill")
            await updateSyncToolProgress(detail: "Filling Eclipse manga from AniList...")
            let mangaResult = try await fillEclipseFromRemoteManga(plan.mangaEntries, sourceName: "AniList", action: action)
            try await advanceSyncToolProgress(by: plan.mangaEntries.count, detail: "Finished AniList manga fill")
            return combineSyncPreviews(action: action, animeResult, mangaResult, note: "AniList fill completed without deleting or downgrading local progress.")

        case .fillEclipseFromMAL:
            _ = try connectedAccount(.myAnimeList)
            await updateSyncToolProgress(detail: "Filling Eclipse anime from MAL...")
            let animeResult = try await fillEclipseFromRemoteAnime(plan.animeEntries, sourceName: "MAL", action: action)
            try await advanceSyncToolProgress(by: plan.animeEntries.count, detail: "Finished MAL anime fill")
            await updateSyncToolProgress(detail: "Filling Eclipse manga from MAL...")
            let mangaResult = try await fillEclipseFromRemoteManga(plan.mangaEntries, sourceName: "MAL", action: action)
            try await advanceSyncToolProgress(by: plan.mangaEntries.count, detail: "Finished MAL manga fill")
            return combineSyncPreviews(action: action, animeResult, mangaResult, note: "MAL fill completed without deleting or downgrading local progress.")

        case .pushEclipseToAniList:
            let account = try connectedAccount(.anilist)
            let anime = localHighestWatchedEpisodes()
            let manga = localHighestReadMangaChapters()
            for (index, entry) in anime.enumerated() {
                try Task.checkCancellation()
                await updateSyncToolProgress(detail: "Pushing anime \(index + 1) of \(anime.count) to AniList...")
                await syncToAniList(account: account, showId: entry.showId, seasonNumber: entry.seasonNumber, episodeNumber: entry.episodeNumber, progress: 1.0)
                try await advanceSyncToolProgress()
            }
            for (index, item) in manga.enumerated() {
                try Task.checkCancellation()
                await updateSyncToolProgress(detail: "Pushing manga \(index + 1) of \(manga.count) to AniList...")
                await sendMangaProgressToAniList(mediaId: item.mangaId, chapterNumber: item.chapter, account: account)
                try await advanceSyncToolProgress()
            }
            return TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: anime.count + manga.count, skipped: 0, unmapped: 0, estimatedAPICalls: 0, notes: ["Eclipse progress push completed."])

        case .pushEclipseToMAL:
            let account = try connectedAccount(.myAnimeList)
            let anime = localHighestWatchedEpisodes()
            let manga = localHighestReadMangaChapters()
            for (index, entry) in anime.enumerated() {
                try Task.checkCancellation()
                await updateSyncToolProgress(detail: "Pushing anime \(index + 1) of \(anime.count) to MAL...")
                await syncToMyAnimeList(account: account, showId: entry.showId, seasonNumber: entry.seasonNumber, episodeNumber: entry.episodeNumber, progress: 1.0)
                try await advanceSyncToolProgress()
            }
            for (index, item) in manga.enumerated() {
                try Task.checkCancellation()
                await updateSyncToolProgress(detail: "Pushing manga \(index + 1) of \(manga.count) to MAL...")
                await sendMangaProgressToMAL(aniListId: item.mangaId, chapterNumber: item.chapter, account: account)
                try await advanceSyncToolProgress()
            }
            return TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: anime.count + manga.count, skipped: 0, unmapped: 0, estimatedAPICalls: 0, notes: ["Eclipse progress push completed."])

        case .portAniListToMAL:
            _ = try connectedAccount(.anilist)
            let destination = try connectedAccount(.myAnimeList)
            var advanced = 0
            var unmapped = 0
            for (index, entry) in plan.animeEntries.enumerated() {
                try Task.checkCancellation()
                await updateSyncToolProgress(detail: "Writing anime \(index + 1) of \(plan.animeEntries.count) to MAL...")
                guard let malId = entry.malId else {
                    unmapped += 1
                    try await advanceSyncToolProgress()
                    continue
                }
                await saveMALAnimeProgress(
                    account: destination,
                    malId: malId,
                    watchedEpisodes: remoteWatchedEpisodes(entry),
                    status: malStatus(fromAniListStatus: entry.status)
                )
                advanced += 1
                try await advanceSyncToolProgress()
            }
            for (index, entry) in plan.mangaEntries.enumerated() {
                try Task.checkCancellation()
                await updateSyncToolProgress(detail: "Writing manga \(index + 1) of \(plan.mangaEntries.count) to MAL...")
                guard let malId = entry.malId else {
                    unmapped += 1
                    try await advanceSyncToolProgress()
                    continue
                }
                await saveMALMangaProgress(
                    account: destination,
                    malId: malId,
                    chaptersRead: remoteReadChapters(entry),
                    status: malMangaStatus(fromAniListStatus: entry.status)
                )
                advanced += 1
                try await advanceSyncToolProgress()
            }
            return TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: advanced, skipped: unmapped, unmapped: unmapped, estimatedAPICalls: advanced, notes: ["AniList to MAL port finished. No entries were deleted."])

        case .portMALToAniList:
            _ = try connectedAccount(.myAnimeList)
            let destination = try connectedAccount(.anilist)
            var advanced = 0
            var unmapped = 0
            for (index, entry) in plan.animeEntries.enumerated() {
                try Task.checkCancellation()
                await updateSyncToolProgress(detail: "Writing anime \(index + 1) of \(plan.animeEntries.count) to AniList...")
                guard let anilistId = entry.anilistId else {
                    unmapped += 1
                    try await advanceSyncToolProgress()
                    continue
                }
                await saveAniListAnimeProgress(
                    account: destination,
                    anilistId: anilistId,
                    watchedEpisodes: remoteWatchedEpisodes(entry),
                    status: aniListStatus(fromMALStatus: entry.status)
                )
                advanced += 1
                try await advanceSyncToolProgress()
            }
            for (index, entry) in plan.mangaEntries.enumerated() {
                try Task.checkCancellation()
                await updateSyncToolProgress(detail: "Writing manga \(index + 1) of \(plan.mangaEntries.count) to AniList...")
                guard let anilistId = entry.anilistId else {
                    unmapped += 1
                    try await advanceSyncToolProgress()
                    continue
                }
                await saveAniListMangaProgress(
                    account: destination,
                    anilistId: anilistId,
                    chaptersRead: remoteReadChapters(entry),
                    status: aniListStatus(fromMALStatus: entry.status)
                )
                advanced += 1
                try await advanceSyncToolProgress()
            }
            return TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: advanced, skipped: unmapped, unmapped: unmapped, estimatedAPICalls: advanced, notes: ["MAL to AniList port finished. No entries were deleted."])
        }
    }

    private func connectedAccount(_ service: TrackerService) throws -> TrackerAccount {
        guard let account = trackerState.getAccount(for: service), account.isConnected else {
            throw NSError(domain: "TrackerSyncTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connect \(service.displayName) first."])
        }
        return account
    }

    private func combineSyncPreviews(action: TrackerSyncToolAction, _ first: TrackerSyncPreview, _ second: TrackerSyncPreview, note: String) -> TrackerSyncPreview {
        TrackerSyncPreview(
            action: action,
            itemsToAdd: first.itemsToAdd + second.itemsToAdd,
            itemsToAdvance: first.itemsToAdvance + second.itemsToAdvance,
            skipped: first.skipped + second.skipped,
            unmapped: first.unmapped + second.unmapped,
            estimatedAPICalls: first.estimatedAPICalls + second.estimatedAPICalls,
            notes: [note]
        )
    }

    private func previewForRemoteFill(action: TrackerSyncToolAction, entries: [RemoteAnimeProgress], sourceName: String) -> TrackerSyncPreview {
        let mapped = entries.filter { $0.anilistId != nil }
        let advanced = mapped.filter { remoteWatchedEpisodes($0) > 0 }.count
        let unmapped = entries.count - mapped.count
        return TrackerSyncPreview(
            action: action,
            itemsToAdd: mapped.count,
            itemsToAdvance: advanced,
            skipped: unmapped,
            unmapped: unmapped,
            estimatedAPICalls: max(2, entries.count * (sourceName == "MAL" ? 2 : 1)),
            notes: ["\(sourceName) fill only adds missing library items and advances incomplete local progress."]
        )
    }

    private func estimatedReadCalls(sourceName: String, animeCount: Int, mangaCount: Int) -> Int {
        switch sourceName {
        case "AniList":
            return listFetchCallCount(itemCount: animeCount, pageSize: 50) + listFetchCallCount(itemCount: mangaCount, pageSize: 50)
        case "MAL":
            let malListReads = listFetchCallCount(itemCount: animeCount, pageSize: malListPageLimit) + listFetchCallCount(itemCount: mangaCount, pageSize: malListPageLimit)
            let aniListBatchResolves = pagedCallCount(itemCount: animeCount, pageSize: 50) + pagedCallCount(itemCount: mangaCount, pageSize: 50)
            return malListReads + aniListBatchResolves
        default:
            return 0
        }
    }

    private func listFetchCallCount(itemCount: Int, pageSize: Int) -> Int {
        max(1, pagedCallCount(itemCount: itemCount, pageSize: pageSize))
    }

    private func pagedCallCount(itemCount: Int, pageSize: Int) -> Int {
        guard itemCount > 0, pageSize > 0 else { return 0 }
        return Int(ceil(Double(itemCount) / Double(pageSize)))
    }

    private func shouldWriteAnimeProgress(source: RemoteAnimeProgress, destination: RemoteAnimeProgress?) -> Bool {
        let sourceProgress = remoteWatchedEpisodes(source)
        guard sourceProgress > 0 || isCompletedStatus(source.status) else { return false }
        guard let destination else { return true }

        let destinationProgress = remoteWatchedEpisodes(destination)
        if sourceProgress > destinationProgress { return true }
        return sourceProgress == destinationProgress && isCompletedStatus(source.status) && !isCompletedStatus(destination.status)
    }

    private func shouldWriteMangaProgress(source: RemoteMangaProgress, destination: RemoteMangaProgress?) -> Bool {
        let sourceProgress = remoteReadChapters(source)
        guard sourceProgress > 0 || isCompletedStatus(source.status) else { return false }
        guard let destination else { return true }

        let destinationProgress = remoteReadChapters(destination)
        if sourceProgress > destinationProgress { return true }
        return sourceProgress == destinationProgress && isCompletedStatus(source.status) && !isCompletedStatus(destination.status)
    }

    private func isCompletedStatus(_ status: String) -> Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "completed"
    }

    private func remoteAnimeByMALId(_ entries: [RemoteAnimeProgress]) -> [Int: RemoteAnimeProgress] {
        entries.reduce(into: [Int: RemoteAnimeProgress]()) { result, entry in
            guard let id = entry.malId else { return }
            if let existing = result[id],
               remoteWatchedEpisodes(existing) > remoteWatchedEpisodes(entry) {
                return
            }
            result[id] = entry
        }
    }

    private func remoteAnimeByAniListId(_ entries: [RemoteAnimeProgress]) -> [Int: RemoteAnimeProgress] {
        entries.reduce(into: [Int: RemoteAnimeProgress]()) { result, entry in
            guard let id = entry.anilistId else { return }
            if let existing = result[id],
               remoteWatchedEpisodes(existing) > remoteWatchedEpisodes(entry) {
                return
            }
            result[id] = entry
        }
    }

    private func remoteMangaByMALId(_ entries: [RemoteMangaProgress]) -> [Int: RemoteMangaProgress] {
        entries.reduce(into: [Int: RemoteMangaProgress]()) { result, entry in
            guard let id = entry.malId else { return }
            if let existing = result[id],
               remoteReadChapters(existing) > remoteReadChapters(entry) {
                return
            }
            result[id] = entry
        }
    }

    private func remoteMangaByAniListId(_ entries: [RemoteMangaProgress]) -> [Int: RemoteMangaProgress] {
        entries.reduce(into: [Int: RemoteMangaProgress]()) { result, entry in
            guard let id = entry.anilistId else { return }
            if let existing = result[id],
               remoteReadChapters(existing) > remoteReadChapters(entry) {
                return
            }
            result[id] = entry
        }
    }
#else
    func previewSyncTool(_ action: TrackerSyncToolAction) {
        guard !isRunningSyncTool else { return }

        Task {
            await MainActor.run {
                self.isRunningSyncTool = true
                self.syncToolStatus = "Building preview..."
                self.syncToolPreview = nil
                self.syncToolProgressCompleted = 0
                self.syncToolProgressTotal = 0
                self.syncToolProgressDetail = nil
                self.syncToolIsLocked = false
            }

            do {
                let plan = try await buildTVSyncToolPlan(for: action)
                await MainActor.run {
                    self.cachedSyncToolPlan = plan
                    self.syncToolPreview = plan.preview
                    self.syncToolStatus = "Preview ready"
                    self.isRunningSyncTool = false
                }
            } catch {
                await MainActor.run {
                    self.syncToolStatus = "Preview failed: \(error.localizedDescription)"
                    self.isRunningSyncTool = false
                }
            }
        }
    }

    func runSyncTool(_ action: TrackerSyncToolAction) {
        guard !isRunningSyncTool else { return }

        let task = Task {
            await MainActor.run {
                self.isRunningSyncTool = true
                self.syncToolStatus = "Running \(action.title)..."
                self.syncToolProgressCompleted = 0
                self.syncToolProgressTotal = 0
                self.syncToolProgressDetail = "Preparing sync..."
            }

            do {
                let plan: TrackerSyncToolPlan
                if let cachedSyncToolPlan, cachedSyncToolPlan.action == action {
                    plan = cachedSyncToolPlan
                } else {
                    plan = try await buildTVSyncToolPlan(for: action)
                    cachedSyncToolPlan = plan
                }
                let total = tvSyncToolOperationCount(for: plan)
                await MainActor.run {
                    self.syncToolProgressCompleted = 0
                    self.syncToolProgressTotal = total
                    self.syncToolProgressDetail = total > 0 ? "0 of \(total) operations complete" : "No write operations needed"
                    self.syncToolIsLocked = plan.preview.estimatedAPICalls >= self.largeSyncAPICallThreshold || total >= self.largeSyncAPICallThreshold
                }
                let result = try await performTVSyncTool(plan)
                await MainActor.run {
                    self.cachedSyncToolPlan = nil
                    self.syncToolPreview = result
                    self.syncToolStatus = "Finished \(action.title)"
                    self.syncToolProgressCompleted = self.syncToolProgressTotal
                    self.syncToolProgressDetail = "Finished"
                    self.syncToolIsLocked = false
                    self.isRunningSyncTool = false
                    self.syncToolTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.syncToolStatus = "Canceled \(action.title)"
                    self.syncToolProgressDetail = "Canceled"
                    self.syncToolIsLocked = false
                    self.isRunningSyncTool = false
                    self.syncToolTask = nil
                }
            } catch {
                await MainActor.run {
                    self.syncToolStatus = "Sync failed: \(error.localizedDescription)"
                    self.syncToolProgressDetail = nil
                    self.syncToolIsLocked = false
                    self.isRunningSyncTool = false
                    self.syncToolTask = nil
                }
            }
        }
        syncToolTask = task
    }

    func cancelSyncTool() {
        syncToolTask?.cancel()
        Task { @MainActor in
            self.syncToolStatus = "Canceling sync..."
            self.syncToolProgressDetail = "Stopping after the current request..."
        }
    }

    private func tvSyncToolOperationCount(for plan: TrackerSyncToolPlan) -> Int {
        switch plan.action {
        case .fillEclipseFromAniList, .fillEclipseFromMAL, .portAniListToMAL, .portMALToAniList:
            return plan.animeEntries.count
        case .pushEclipseToAniList, .pushEclipseToMAL:
            return localHighestWatchedEpisodes().count
        }
    }

    private func updateSyncToolProgress(detail: String?) async {
        await MainActor.run {
            self.syncToolProgressDetail = detail
        }
    }

    private func advanceSyncToolProgress(by amount: Int = 1, detail: String? = nil) async throws {
        try Task.checkCancellation()
        await MainActor.run {
            self.syncToolProgressCompleted = min(self.syncToolProgressCompleted + amount, self.syncToolProgressTotal)
            if let detail {
                self.syncToolProgressDetail = detail
            } else if self.syncToolProgressTotal > 0 {
                self.syncToolProgressDetail = "\(self.syncToolProgressCompleted) of \(self.syncToolProgressTotal) operations complete"
            }
        }
    }

    private func buildTVSyncToolPlan(for action: TrackerSyncToolAction) async throws -> TrackerSyncToolPlan {
        switch action {
        case .fillEclipseFromAniList:
            let account = try connectedAccount(.anilist)
            let entries = try await fetchAniListAnimeProgressEntries(account: account)
            return TrackerSyncToolPlan(
                action: action,
                preview: tvRemoteFillPreview(action: action, entries: entries, sourceName: "AniList"),
                animeEntries: entries
            )

        case .fillEclipseFromMAL:
            let account = try connectedAccount(.myAnimeList)
            let entries = await resolveMALAnimeEntriesToAniList(try await fetchMALAnimeProgressEntries(account: account))
            return TrackerSyncToolPlan(
                action: action,
                preview: tvRemoteFillPreview(action: action, entries: entries, sourceName: "MAL"),
                animeEntries: entries
            )

        case .pushEclipseToAniList:
            _ = try connectedAccount(.anilist)
            let entries = localHighestWatchedEpisodes()
            return TrackerSyncToolPlan(
                action: action,
                preview: TrackerSyncPreview(
                    action: action,
                    itemsToAdd: 0,
                    itemsToAdvance: entries.count,
                    skipped: 0,
                    unmapped: 0,
                    estimatedAPICalls: entries.count * 3,
                    notes: ["Only local anime watch progress is sent from Apple TV."]
                )
            )

        case .pushEclipseToMAL:
            _ = try connectedAccount(.myAnimeList)
            let entries = localHighestWatchedEpisodes()
            return TrackerSyncToolPlan(
                action: action,
                preview: TrackerSyncPreview(
                    action: action,
                    itemsToAdd: 0,
                    itemsToAdvance: entries.count,
                    skipped: 0,
                    unmapped: 0,
                    estimatedAPICalls: entries.count * 4,
                    notes: ["Only local anime watch progress is sent from Apple TV."]
                )
            )

        case .portAniListToMAL:
            let source = try connectedAccount(.anilist)
            let destination = try connectedAccount(.myAnimeList)
            let sourceEntries = try await fetchAniListAnimeProgressEntries(account: source)
            let destinationEntries = try await fetchMALAnimeProgressEntries(account: destination)
            let destinationByMAL = tvRemoteAnimeByMALId(destinationEntries)
            let entries = sourceEntries.filter { entry in
                guard let malId = entry.malId else { return false }
                return shouldWriteTVAnimeProgress(source: entry, destination: destinationByMAL[malId])
            }
            let alreadyCurrent = sourceEntries.filter { entry in
                guard let malId = entry.malId else { return false }
                return !shouldWriteTVAnimeProgress(source: entry, destination: destinationByMAL[malId])
            }.count
            let unmapped = max(0, sourceEntries.count - entries.count - alreadyCurrent)
            return TrackerSyncToolPlan(
                action: action,
                preview: TrackerSyncPreview(
                    action: action,
                    itemsToAdd: 0,
                    itemsToAdvance: entries.count,
                    skipped: sourceEntries.count - entries.count,
                    unmapped: unmapped,
                    estimatedAPICalls: tvEstimatedReadCalls(sourceName: "AniList", itemCount: sourceEntries.count)
                        + tvEstimatedReadCalls(sourceName: "MAL", itemCount: destinationEntries.count)
                        + entries.count,
                    notes: ["Only anime entries that advance MAL are written from Apple TV."]
                ),
                animeEntries: entries
            )

        case .portMALToAniList:
            let source = try connectedAccount(.myAnimeList)
            let destination = try connectedAccount(.anilist)
            let sourceEntries = await resolveMALAnimeEntriesToAniList(try await fetchMALAnimeProgressEntries(account: source))
            let destinationEntries = try await fetchAniListAnimeProgressEntries(account: destination)
            let destinationByAniList = tvRemoteAnimeByAniListId(destinationEntries)
            let entries = sourceEntries.filter { entry in
                guard let anilistId = entry.anilistId else { return false }
                return shouldWriteTVAnimeProgress(source: entry, destination: destinationByAniList[anilistId])
            }
            let alreadyCurrent = sourceEntries.filter { entry in
                guard let anilistId = entry.anilistId else { return false }
                return !shouldWriteTVAnimeProgress(source: entry, destination: destinationByAniList[anilistId])
            }.count
            let unmapped = max(0, sourceEntries.count - entries.count - alreadyCurrent)
            return TrackerSyncToolPlan(
                action: action,
                preview: TrackerSyncPreview(
                    action: action,
                    itemsToAdd: 0,
                    itemsToAdvance: entries.count,
                    skipped: sourceEntries.count - entries.count,
                    unmapped: unmapped,
                    estimatedAPICalls: tvEstimatedReadCalls(sourceName: "MAL", itemCount: sourceEntries.count)
                        + tvEstimatedReadCalls(sourceName: "AniList", itemCount: destinationEntries.count)
                        + entries.count,
                    notes: ["Only anime entries that advance AniList are written from Apple TV."]
                ),
                animeEntries: entries
            )
        }
    }

    private func performTVSyncTool(_ plan: TrackerSyncToolPlan) async throws -> TrackerSyncPreview {
        try Task.checkCancellation()
        let action = plan.action

        switch action {
        case .fillEclipseFromAniList:
            _ = try connectedAccount(.anilist)
            await updateSyncToolProgress(detail: "Filling Eclipse anime from AniList...")
            let result = try await fillEclipseFromRemoteAnime(plan.animeEntries, sourceName: "AniList", action: action)
            try await advanceSyncToolProgress(by: plan.animeEntries.count, detail: "Finished AniList anime fill")
            return result

        case .fillEclipseFromMAL:
            _ = try connectedAccount(.myAnimeList)
            await updateSyncToolProgress(detail: "Filling Eclipse anime from MAL...")
            let result = try await fillEclipseFromRemoteAnime(plan.animeEntries, sourceName: "MAL", action: action)
            try await advanceSyncToolProgress(by: plan.animeEntries.count, detail: "Finished MAL anime fill")
            return result

        case .pushEclipseToAniList:
            let account = try connectedAccount(.anilist)
            let entries = localHighestWatchedEpisodes()
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                await updateSyncToolProgress(detail: "Pushing anime \(index + 1) of \(entries.count) to AniList...")
                await syncToAniList(account: account, showId: entry.showId, seasonNumber: entry.seasonNumber, episodeNumber: entry.episodeNumber, progress: 1.0)
                try await advanceSyncToolProgress()
            }
            return TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: entries.count, skipped: 0, unmapped: 0, estimatedAPICalls: 0, notes: ["Anime progress push completed."])

        case .pushEclipseToMAL:
            let account = try connectedAccount(.myAnimeList)
            let entries = localHighestWatchedEpisodes()
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                await updateSyncToolProgress(detail: "Pushing anime \(index + 1) of \(entries.count) to MAL...")
                await syncToMyAnimeList(account: account, showId: entry.showId, seasonNumber: entry.seasonNumber, episodeNumber: entry.episodeNumber, progress: 1.0)
                try await advanceSyncToolProgress()
            }
            return TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: entries.count, skipped: 0, unmapped: 0, estimatedAPICalls: 0, notes: ["Anime progress push completed."])

        case .portAniListToMAL:
            _ = try connectedAccount(.anilist)
            let destination = try connectedAccount(.myAnimeList)
            var advanced = 0
            var unmapped = 0
            for (index, entry) in plan.animeEntries.enumerated() {
                try Task.checkCancellation()
                await updateSyncToolProgress(detail: "Writing anime \(index + 1) of \(plan.animeEntries.count) to MAL...")
                guard let malId = entry.malId else {
                    unmapped += 1
                    try await advanceSyncToolProgress()
                    continue
                }
                await saveMALAnimeProgress(
                    account: destination,
                    malId: malId,
                    watchedEpisodes: remoteWatchedEpisodes(entry),
                    status: malStatus(fromAniListStatus: entry.status)
                )
                advanced += 1
                try await advanceSyncToolProgress()
            }
            return TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: advanced, skipped: unmapped, unmapped: unmapped, estimatedAPICalls: advanced, notes: ["AniList to MAL anime port finished. No entries were deleted."])

        case .portMALToAniList:
            _ = try connectedAccount(.myAnimeList)
            let destination = try connectedAccount(.anilist)
            var advanced = 0
            var unmapped = 0
            for (index, entry) in plan.animeEntries.enumerated() {
                try Task.checkCancellation()
                await updateSyncToolProgress(detail: "Writing anime \(index + 1) of \(plan.animeEntries.count) to AniList...")
                guard let anilistId = entry.anilistId else {
                    unmapped += 1
                    try await advanceSyncToolProgress()
                    continue
                }
                await saveAniListAnimeProgress(
                    account: destination,
                    anilistId: anilistId,
                    watchedEpisodes: remoteWatchedEpisodes(entry),
                    status: aniListStatus(fromMALStatus: entry.status)
                )
                advanced += 1
                try await advanceSyncToolProgress()
            }
            return TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: advanced, skipped: unmapped, unmapped: unmapped, estimatedAPICalls: advanced, notes: ["MAL to AniList anime port finished. No entries were deleted."])
        }
    }

    private func connectedAccount(_ service: TrackerService) throws -> TrackerAccount {
        guard let account = trackerState.getAccount(for: service), account.isConnected else {
            throw NSError(domain: "TrackerSyncTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connect \(service.displayName) first."])
        }
        return account
    }

    private func tvRemoteFillPreview(action: TrackerSyncToolAction, entries: [RemoteAnimeProgress], sourceName: String) -> TrackerSyncPreview {
        let mapped = entries.filter { $0.anilistId != nil }
        let advanced = mapped.filter { remoteWatchedEpisodes($0) > 0 }.count
        let unmapped = entries.count - mapped.count
        return TrackerSyncPreview(
            action: action,
            itemsToAdd: mapped.count,
            itemsToAdvance: advanced,
            skipped: unmapped,
            unmapped: unmapped,
            estimatedAPICalls: tvEstimatedReadCalls(sourceName: sourceName, itemCount: entries.count),
            notes: ["\(sourceName) anime fill only adds missing items and advances incomplete local progress."]
        )
    }

    private func tvEstimatedReadCalls(sourceName: String, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 1 }
        let pageSize = sourceName == "MAL" ? malListPageLimit : 50
        let pages = Int(ceil(Double(itemCount) / Double(pageSize)))
        return sourceName == "MAL" ? pages * 2 : pages
    }

    private func shouldWriteTVAnimeProgress(source: RemoteAnimeProgress, destination: RemoteAnimeProgress?) -> Bool {
        let sourceProgress = remoteWatchedEpisodes(source)
        guard sourceProgress > 0 || isCompletedStatus(source.status) else { return false }
        guard let destination else { return true }
        let destinationProgress = remoteWatchedEpisodes(destination)
        if sourceProgress > destinationProgress { return true }
        return sourceProgress == destinationProgress && isCompletedStatus(source.status) && !isCompletedStatus(destination.status)
    }

    private func isCompletedStatus(_ status: String) -> Bool {
        status.uppercased() == "COMPLETED" || status.lowercased() == "completed"
    }

    private func tvRemoteAnimeByMALId(_ entries: [RemoteAnimeProgress]) -> [Int: RemoteAnimeProgress] {
        entries.reduce(into: [Int: RemoteAnimeProgress]()) { result, entry in
            guard let id = entry.malId else { return }
            if let existing = result[id], remoteWatchedEpisodes(existing) > remoteWatchedEpisodes(entry) { return }
            result[id] = entry
        }
    }

    private func tvRemoteAnimeByAniListId(_ entries: [RemoteAnimeProgress]) -> [Int: RemoteAnimeProgress] {
        entries.reduce(into: [Int: RemoteAnimeProgress]()) { result, entry in
            guard let id = entry.anilistId else { return }
            if let existing = result[id], remoteWatchedEpisodes(existing) > remoteWatchedEpisodes(entry) { return }
            result[id] = entry
        }
    }
#endif

    private func fetchAniListAnimeProgressEntries(account: TrackerAccount) async throws -> [RemoteAnimeProgress] {
        let userId = try await resolvedAniListUserId(for: account)
        var entriesByMediaId: [Int: RemoteAnimeProgress] = [:]
        var orderedMediaIds: [Int] = []
        var chunk = 1
        var hasNextChunk = true

        while hasNextChunk {
            let query = """
            query($userId: Int!, $chunk: Int!) {
                MediaListCollection(
                    userId: $userId,
                    type: ANIME,
                    chunk: $chunk,
                    perChunk: 500,
                    forceSingleCompletedList: true,
                    status_in: [CURRENT, PLANNING, COMPLETED, PAUSED, DROPPED, REPEATING]
                ) {
                    hasNextChunk
                    lists {
                        status
                        entries {
                            status
                            progress
                            media {
                                id
                                idMal
                                title { romaji english native }
                                episodes
                            }
                        }
                    }
                }
            }
            """

            struct Response: Codable {
                let data: DataWrapper?
                struct DataWrapper: Codable { let MediaListCollection: CollectionData? }
                struct CollectionData: Codable {
                    let hasNextChunk: Bool
                    let lists: [MediaListGroup]
                }
                struct MediaListGroup: Codable {
                    let status: String?
                    let entries: [MediaList]
                }
                struct MediaList: Codable {
                    let status: String?
                    let progress: Int?
                    let media: Media?
                }
                struct Media: Codable {
                    let id: Int
                    let idMal: Int?
                    let title: Title
                    let episodes: Int?
                }
                struct Title: Codable {
                    let romaji: String?
                    let english: String?
                    let native: String?
                }
            }

            var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query,
                "variables": [
                    "userId": userId,
                    "chunk": chunk
                ]
            ])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            guard response.statusCode == 200 else {
                let message = aniListFailureDescription("AniList anime list fetch failed", response: response, data: data)
                Logger.shared.log(message, type: "Tracker")
                throw NSError(domain: "AniList", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let collection = decoded.data?.MediaListCollection else {
                let message = graphQLErrorMessage(from: data) ?? "AniList anime list fetch returned no collection data."
                throw NSError(domain: "AniList", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }

            for group in collection.lists {
                for item in group.entries {
                    guard let media = item.media else { continue }
                    if let malId = media.idMal {
                        cacheMyAnimeListId(malId, forAniListId: media.id, mediaType: "ANIME")
                    }

                    if entriesByMediaId[media.id] == nil {
                        orderedMediaIds.append(media.id)
                    }

                    entriesByMediaId[media.id] = RemoteAnimeProgress(
                        anilistId: media.id,
                        malId: media.idMal,
                        title: media.title.english ?? media.title.romaji ?? media.title.native ?? "Unknown",
                        status: item.status ?? group.status ?? "CURRENT",
                        progress: item.progress ?? 0,
                        totalEpisodes: media.episodes
                    )
                }
            }
            hasNextChunk = collection.hasNextChunk
            chunk += 1
        }

        return orderedMediaIds.compactMap { entriesByMediaId[$0] }
    }

    private func fetchMALAnimeProgressEntries(account: TrackerAccount) async throws -> [RemoteAnimeProgress] {
        var entries: [RemoteAnimeProgress] = []
        var nextURL: URL? = URL(string: "https://api.myanimelist.net/v2/users/@me/animelist?fields=list_status,num_episodes&limit=\(malListPageLimit)&nsfw=true")

        struct Response: Codable {
            let data: [Entry]
            let paging: Paging?
            struct Entry: Codable {
                let node: Node
                let listStatus: ListStatus?

                enum CodingKeys: String, CodingKey {
                    case node
                    case listStatus = "list_status"
                }
            }
            struct Node: Codable {
                let id: Int
                let title: String
                let numEpisodes: Int?

                enum CodingKeys: String, CodingKey {
                    case id, title
                    case numEpisodes = "num_episodes"
                }
            }
            struct ListStatus: Codable {
                let status: String?
                let numEpisodesWatched: Int?

                enum CodingKeys: String, CodingKey {
                    case status
                    case numEpisodesWatched = "num_episodes_watched"
                }
            }
            struct Paging: Codable {
                let next: String?
            }
        }

        while let url = nextURL {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await sendTrackerRequest(request, provider: .myAnimeList)
            guard response.statusCode == 200 else {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                throw NSError(domain: "MAL", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "MAL anime list fetch failed (\(response.statusCode)): \(bodyPreview)"])
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            entries.append(contentsOf: decoded.data.map { item in
                RemoteAnimeProgress(
                    anilistId: nil,
                    malId: item.node.id,
                    title: item.node.title,
                    status: item.listStatus?.status ?? "watching",
                    progress: item.listStatus?.numEpisodesWatched ?? 0,
                    totalEpisodes: item.node.numEpisodes
                )
            })
            nextURL = decoded.paging?.next.flatMap { URL(string: $0) }
        }

        return entries
    }

    private func resolveMALAnimeEntriesToAniList(_ entries: [RemoteAnimeProgress]) async -> [RemoteAnimeProgress] {
        let malIds = entries.compactMap(\.malId)
        let resolvedIds = await resolveAniListIds(fromMALIds: malIds, mediaType: "ANIME")

        return entries.map { entry in
            RemoteAnimeProgress(
                anilistId: entry.malId.flatMap { resolvedIds[$0] },
                malId: entry.malId,
                title: entry.title,
                status: entry.status,
                progress: entry.progress,
                totalEpisodes: entry.totalEpisodes
            )
        }
    }

#if !os(tvOS)
    private func fetchAniListMangaProgressEntries(account: TrackerAccount) async throws -> [RemoteMangaProgress] {
#if os(tvOS)
        // The TV product has no reader surface. Keep sync-tool actions anime-only and
        // never fetch a user's manga library merely because the same tracker account
        // is connected for anime playback.
        return []
#else
        let userId = try await resolvedAniListUserId(for: account)
        var entriesByMediaId: [Int: RemoteMangaProgress] = [:]
        var orderedMediaIds: [Int] = []
        var chunk = 1
        var hasNextChunk = true

        while hasNextChunk {
            let query = """
            query($userId: Int!, $chunk: Int!) {
                MediaListCollection(
                    userId: $userId,
                    type: MANGA,
                    chunk: $chunk,
                    perChunk: 500,
                    forceSingleCompletedList: true,
                    status_in: [CURRENT, PLANNING, COMPLETED, PAUSED, DROPPED, REPEATING]
                ) {
                    hasNextChunk
                    lists {
                        status
                        entries {
                            status
                            progress
                            media {
                                id
                                idMal
                                title { romaji english native }
                                chapters
                            }
                        }
                    }
                }
            }
            """

            struct Response: Codable {
                let data: DataWrapper?
                struct DataWrapper: Codable { let MediaListCollection: CollectionData? }
                struct CollectionData: Codable {
                    let hasNextChunk: Bool
                    let lists: [MediaListGroup]
                }
                struct MediaListGroup: Codable {
                    let status: String?
                    let entries: [MediaList]
                }
                struct MediaList: Codable {
                    let status: String?
                    let progress: Int?
                    let media: Media?
                }
                struct Media: Codable {
                    let id: Int
                    let idMal: Int?
                    let title: Title
                    let chapters: Int?
                }
                struct Title: Codable {
                    let romaji: String?
                    let english: String?
                    let native: String?
                }
            }

            var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query,
                "variables": [
                    "userId": userId,
                    "chunk": chunk
                ]
            ])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            guard response.statusCode == 200 else {
                let message = aniListFailureDescription("AniList manga list fetch failed", response: response, data: data)
                Logger.shared.log(message, type: "Tracker")
                throw NSError(domain: "AniList", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let collection = decoded.data?.MediaListCollection else {
                let message = graphQLErrorMessage(from: data) ?? "AniList manga list fetch returned no collection data."
                throw NSError(domain: "AniList", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }

            for group in collection.lists {
                for item in group.entries {
                    guard let media = item.media else { continue }
                    if let malId = media.idMal {
                        cacheMyAnimeListId(malId, forAniListId: media.id, mediaType: "MANGA")
                    }

                    if entriesByMediaId[media.id] == nil {
                        orderedMediaIds.append(media.id)
                    }

                    entriesByMediaId[media.id] = RemoteMangaProgress(
                        anilistId: media.id,
                        malId: media.idMal,
                        title: media.title.english ?? media.title.romaji ?? media.title.native ?? "Unknown",
                        status: item.status ?? group.status ?? "CURRENT",
                        progress: item.progress ?? 0,
                        totalChapters: media.chapters
                    )
                }
            }
            hasNextChunk = collection.hasNextChunk
            chunk += 1
        }

        return orderedMediaIds.compactMap { entriesByMediaId[$0] }
#endif
    }

    private func fetchMALMangaProgressEntries(account: TrackerAccount) async throws -> [RemoteMangaProgress] {
#if os(tvOS)
        return []
#else
        var entries: [RemoteMangaProgress] = []
        var nextURL: URL? = URL(string: "https://api.myanimelist.net/v2/users/@me/mangalist?fields=list_status,num_chapters&limit=\(malListPageLimit)&nsfw=true")

        struct Response: Codable {
            let data: [Entry]
            let paging: Paging?
            struct Entry: Codable {
                let node: Node
                let listStatus: ListStatus?

                enum CodingKeys: String, CodingKey {
                    case node
                    case listStatus = "list_status"
                }
            }
            struct Node: Codable {
                let id: Int
                let title: String
                let numChapters: Int?

                enum CodingKeys: String, CodingKey {
                    case id, title
                    case numChapters = "num_chapters"
                }
            }
            struct ListStatus: Codable {
                let status: String?
                let numChaptersRead: Int?

                enum CodingKeys: String, CodingKey {
                    case status
                    case numChaptersRead = "num_chapters_read"
                }
            }
            struct Paging: Codable {
                let next: String?
            }
        }

        while let url = nextURL {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await sendTrackerRequest(request, provider: .myAnimeList)
            guard response.statusCode == 200 else {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                throw NSError(domain: "MAL", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "MAL manga list fetch failed (\(response.statusCode)): \(bodyPreview)"])
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            entries.append(contentsOf: decoded.data.map { item in
                RemoteMangaProgress(
                    anilistId: nil,
                    malId: item.node.id,
                    title: item.node.title,
                    status: item.listStatus?.status ?? "reading",
                    progress: item.listStatus?.numChaptersRead ?? 0,
                    totalChapters: item.node.numChapters
                )
            })
            nextURL = decoded.paging?.next.flatMap { URL(string: $0) }
        }

        return entries
#endif
    }

    private func resolveMALMangaEntriesToAniList(_ entries: [RemoteMangaProgress]) async -> [RemoteMangaProgress] {
#if os(tvOS)
        return []
#else
        let malIds = entries.compactMap(\.malId)
        let resolvedIds = await resolveAniListIds(fromMALIds: malIds, mediaType: "MANGA")

        return entries.map { entry in
            RemoteMangaProgress(
                anilistId: entry.malId.flatMap { resolvedIds[$0] },
                malId: entry.malId,
                title: entry.title,
                status: entry.status,
                progress: entry.progress,
                totalChapters: entry.totalChapters
            )
        }
#endif
    }
#endif

    private func resolveAniListIds(fromMALIds malIds: [Int], mediaType: String) async -> [Int: Int] {
        let uniqueIds = Array(Set(malIds))
        guard !uniqueIds.isEmpty else { return [:] }

        var result: [Int: Int] = [:]
        let cached = cachedAniListIds(fromMALIds: uniqueIds, mediaType: mediaType)
        result.merge(cached) { current, _ in current }

        let missing = uniqueIds.filter { cached[$0] == nil }
        for chunk in chunked(missing, size: 50) {
            let fetched = await fetchAniListIdsByMALIds(chunk, mediaType: mediaType)
            result.merge(fetched) { current, _ in current }
            for (malId, anilistId) in fetched {
                cacheAniListId(anilistId, forMALId: malId, mediaType: mediaType)
            }

            let unresolved = chunk.filter { fetched[$0] == nil }
            for malId in unresolved {
                if let anilistId = await getAniListId(fromMALId: malId, mediaType: mediaType) {
                    result[malId] = anilistId
                    cacheAniListId(anilistId, forMALId: malId, mediaType: mediaType)
                }
            }
        }

        return result
    }

    private func fetchAniListIdsByMALIds(_ malIds: [Int], mediaType: String) async -> [Int: Int] {
        guard !malIds.isEmpty else { return [:] }
        let idList = malIds.map(String.init).joined(separator: ", ")
        let query = """
        query {
            Page(perPage: \(malIds.count)) {
                media(type: \(mediaType), idMal_in: [\(idList)]) {
                    id
                    idMal
                }
            }
        }
        """

        struct Response: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable { let Page: PageData }
            struct PageData: Codable { let media: [Media] }
            struct Media: Codable {
                let id: Int
                let idMal: Int?
            }
        }

        do {
            var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            guard response.statusCode == 200 else { return [:] }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.data.Page.media.reduce(into: [Int: Int]()) { result, media in
                if let malId = media.idMal {
                    result[malId] = media.id
                }
            }
        } catch {
            Logger.shared.log("Batch AniList idMal lookup failed for \(malIds.count) \(mediaType) entries: \(error.localizedDescription)", type: "Tracker")
            return [:]
        }
    }

    private func cachedAniListIds(fromMALIds malIds: [Int], mediaType: String) -> [Int: Int] {
#if os(tvOS)
        let cache = malToAniListAnimeIdCache
#else
        let cache = mediaType == "MANGA" ? malToAniListMangaIdCache : malToAniListAnimeIdCache
#endif
        return malIds.reduce(into: [Int: Int]()) { result, malId in
            if let anilistId = cache[malId] {
                result[malId] = anilistId
            }
        }
    }

    private func cacheAniListId(_ anilistId: Int, forMALId malId: Int, mediaType: String) {
#if os(tvOS)
        malToAniListAnimeIdCache[malId] = anilistId
        aniListToMALAnimeIdCache[anilistId] = malId
#else
        if mediaType == "MANGA" {
            malToAniListMangaIdCache[malId] = anilistId
            aniListToMALMangaIdCache[anilistId] = malId
        } else {
            malToAniListAnimeIdCache[malId] = anilistId
            aniListToMALAnimeIdCache[anilistId] = malId
        }
#endif
    }

    private func cachedMyAnimeListId(fromAniListId aniListId: Int, mediaType: String) -> Int? {
#if os(tvOS)
        return aniListToMALAnimeIdCache[aniListId]
#else
        if mediaType == "MANGA" {
            return aniListToMALMangaIdCache[aniListId]
        }
        return aniListToMALAnimeIdCache[aniListId]
#endif
    }

    private func cacheMyAnimeListId(_ malId: Int, forAniListId aniListId: Int, mediaType: String) {
#if os(tvOS)
        aniListToMALAnimeIdCache[aniListId] = malId
        malToAniListAnimeIdCache[malId] = aniListId
#else
        if mediaType == "MANGA" {
            aniListToMALMangaIdCache[aniListId] = malId
            malToAniListMangaIdCache[malId] = aniListId
        } else {
            aniListToMALAnimeIdCache[aniListId] = malId
            malToAniListAnimeIdCache[malId] = aniListId
        }
#endif
    }

    private func chunked<T>(_ values: [T], size: Int) -> [[T]] {
        guard size > 0, !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: size).map { start in
            Array(values[start..<min(start + size, values.count)])
        }
    }

    private func fillEclipseFromRemoteAnime(_ entries: [RemoteAnimeProgress], sourceName: String, action: TrackerSyncToolAction) async throws -> TrackerSyncPreview {
        try Task.checkCancellation()
        let anilistIds = entries.compactMap { $0.anilistId }
        let tmdbMap = await AniListService.shared.mapAniListAnimeIdsToTMDBForImport(anilistIds, tmdbService: TMDBService.shared)
        try Task.checkCancellation()

        let counts = try await MainActor.run { () throws -> (added: Int, advanced: Int, unmapped: Int) in
            let library = LibraryManager.shared
            var added = 0
            var advanced = 0
            var unmapped = 0

            for entry in entries {
                try Task.checkCancellation()
                guard let anilistId = entry.anilistId,
                      let tmdb = tmdbMap[anilistId] else {
                    unmapped += 1
                    continue
                }

                let collectionName = localCollectionName(forRemoteStatus: entry.status, sourceName: sourceName)
                var collection = library.collections.first(where: { $0.name == collectionName })
                if collection == nil {
                    library.createCollection(name: collectionName, description: "Imported from \(sourceName)")
                    collection = library.collections.first(where: { $0.name == collectionName })
                }
                guard let collection else {
                    unmapped += 1
                    continue
                }

                let item = LibraryItem(searchResult: tmdb)
                if !library.isItemInCollection(collection.id, item: item) {
                    library.addItem(to: collection.id, item: item)
                    added += 1
                }

                let watched = remoteWatchedEpisodes(entry)
                if watched > 0 {
                    ProgressManager.shared.bulkMarkEpisodesAsWatched(showId: tmdb.id, seasonNumber: 1, throughEpisode: watched)
                    advanced += 1
                }
            }

            return (added: added, advanced: advanced, unmapped: unmapped)
        }

        return TrackerSyncPreview(
            action: action,
            itemsToAdd: counts.added,
            itemsToAdvance: counts.advanced,
            skipped: counts.unmapped,
            unmapped: counts.unmapped,
            estimatedAPICalls: max(1, entries.count),
            notes: ["\(sourceName) fill completed without deleting or downgrading local progress."]
        )
    }

    private func fillMALAnimeCollectionsForLibraryImport(_ entries: [RemoteAnimeProgress], action: TrackerSyncToolAction) async throws -> TrackerSyncPreview {
        try Task.checkCancellation()
        let anilistIds = entries.compactMap { $0.anilistId }
        let aniMapMatches = await AniListService.shared.mapAniListAnimeIdsToTMDBViaAniMapForMALImport(
            anilistIds,
            tmdbService: TMDBService.shared
        )
        let fallbackIds = anilistIds.filter { aniMapMatches[$0] == nil }
        let fallbackMap = await AniListService.shared.mapAniListAnimeIdsToTMDBForImport(
            fallbackIds,
            tmdbService: TMDBService.shared
        )
        try Task.checkCancellation()

        let counts = try await MainActor.run { () throws -> (added: Int, advanced: Int, unmapped: Int, aniMapMapped: Int, fallbackMapped: Int) in
            let library = LibraryManager.shared
            var added = 0
            var advanced = 0
            var unmapped = 0
            var aniMapMapped = 0
            var fallbackMapped = 0

            for entry in entries {
                try Task.checkCancellation()
                guard let anilistId = entry.anilistId else {
                    unmapped += 1
                    continue
                }

                let tmdb: TMDBSearchResult
                let mappedSeason: Int?
                if let match = aniMapMatches[anilistId] {
                    tmdb = match.tmdbResult
                    mappedSeason = match.tmdbSeason
                    aniMapMapped += 1
                } else if let fallback = fallbackMap[anilistId] {
                    tmdb = fallback
                    mappedSeason = nil
                    fallbackMapped += 1
                } else {
                    unmapped += 1
                    continue
                }

                let collectionName = localCollectionName(forRemoteStatus: entry.status, sourceName: "MAL")
                var collection = library.collections.first(where: { $0.name == collectionName })
                if collection == nil {
                    library.createCollection(name: collectionName, description: "Imported from MAL")
                    collection = library.collections.first(where: { $0.name == collectionName })
                }
                guard let collection else {
                    unmapped += 1
                    continue
                }

                let item = LibraryItem(searchResult: tmdb)
                if !library.isItemInCollection(collection.id, item: item) {
                    library.addItem(to: collection.id, item: item)
                    added += 1
                }

                let watched = remoteWatchedEpisodes(entry)
                guard watched > 0 else { continue }

                if tmdb.isTVShow {
                    ProgressManager.shared.bulkMarkEpisodesAsWatched(
                        showId: tmdb.id,
                        seasonNumber: mappedSeason ?? 1,
                        throughEpisode: watched
                    )
                    advanced += 1
                } else if tmdb.isMovie {
                    ProgressManager.shared.updateMovieProgress(
                        movieId: tmdb.id,
                        title: tmdb.displayTitle,
                        currentTime: 1,
                        totalDuration: 1,
                        posterURL: tmdb.fullPosterURL
                    )
                    advanced += 1
                }
            }

            return (added: added, advanced: advanced, unmapped: unmapped, aniMapMapped: aniMapMapped, fallbackMapped: fallbackMapped)
        }

        Logger.shared.log("MAL anime import mapped \(counts.aniMapMapped) through AniMap and \(counts.fallbackMapped) through title search", type: "Tracker")
        return TrackerSyncPreview(
            action: action,
            itemsToAdd: counts.added,
            itemsToAdvance: counts.advanced,
            skipped: counts.unmapped,
            unmapped: counts.unmapped,
            estimatedAPICalls: max(1, entries.count),
            notes: ["MAL anime lists were imported into Eclipse collections."]
        )
    }

#if !os(tvOS)
    private func fillEclipseFromRemoteManga(_ entries: [RemoteMangaProgress], sourceName: String, action: TrackerSyncToolAction) async throws -> TrackerSyncPreview {
#if os(tvOS)
        return TrackerSyncPreview(
            action: action,
            itemsToAdd: 0,
            itemsToAdvance: 0,
            skipped: entries.count,
            unmapped: 0,
            estimatedAPICalls: 0,
            notes: ["Manga import is unavailable on Apple TV."]
        )
#else
        let counts = try await MainActor.run { () throws -> (advanced: Int, unmapped: Int) in
            var advanced = 0
            var unmapped = 0

            for entry in entries {
                try Task.checkCancellation()
                guard let anilistId = entry.anilistId else {
                    unmapped += 1
                    continue
                }

                let read = remoteReadChapters(entry)
                if read > 0 {
                    MangaReadingProgressManager.shared.bulkMarkChaptersReadForImport(
                        mangaId: anilistId,
                        throughChapter: read,
                        mangaTitle: entry.title,
                        totalChapters: entry.totalChapters
                    )
                    advanced += 1
                }
            }

            return (advanced: advanced, unmapped: unmapped)
        }

        return TrackerSyncPreview(
            action: action,
            itemsToAdd: 0,
            itemsToAdvance: counts.advanced,
            skipped: counts.unmapped,
            unmapped: counts.unmapped,
            estimatedAPICalls: max(1, entries.count),
            notes: ["\(sourceName) manga fill completed without deleting or downgrading local reader progress."]
        )
#endif
    }

    private func fillMALMangaCollectionsForLibraryImport(_ entries: [RemoteMangaProgress], action: TrackerSyncToolAction) async throws -> TrackerSyncPreview {
#if os(tvOS)
        return TrackerSyncPreview(
            action: action,
            itemsToAdd: 0,
            itemsToAdvance: 0,
            skipped: entries.count,
            unmapped: 0,
            estimatedAPICalls: 0,
            notes: ["Manga collections are unavailable on Apple TV."]
        )
#else
        let counts = try await MainActor.run { () throws -> (added: Int, unmapped: Int) in
            let library = MangaLibraryManager.shared
            var added = 0
            var unmapped = 0

            for entry in entries {
                try Task.checkCancellation()
                guard let anilistId = entry.anilistId else {
                    unmapped += 1
                    continue
                }

                let collectionName = localMangaCollectionName(forRemoteStatus: entry.status, sourceName: "MAL")
                var collection = library.collections.first(where: { $0.name == collectionName })
                if collection == nil {
                    library.createCollection(name: collectionName, description: "Imported from MAL")
                    collection = library.collections.first(where: { $0.name == collectionName })
                }
                guard let collection else {
                    unmapped += 1
                    continue
                }

                let item = MangaLibraryItem(
                    aniListId: anilistId,
                    title: entry.title,
                    coverURL: nil,
                    format: nil,
                    totalChapters: entry.totalChapters
                )
                if !library.isItemInCollection(collection.id, item: item) {
                    library.addItem(to: collection.id, item: item)
                    added += 1
                }
            }

            return (added: added, unmapped: unmapped)
        }

        return TrackerSyncPreview(
            action: action,
            itemsToAdd: counts.added,
            itemsToAdvance: 0,
            skipped: counts.unmapped,
            unmapped: counts.unmapped,
            estimatedAPICalls: 0,
            notes: ["MAL manga lists were imported into Kanzen collections."]
        )
#endif
    }
#endif

    private func localHighestWatchedEpisodes() -> [EpisodeProgressEntry] {
        let eligible = ProgressManager.shared.getProgressData().episodeProgress
            .filter {
                ($0.isWatched || $0.progress >= 0.85) &&
                ($0.isAnime == true || $0.playbackContext?.hasAnimeMediaId == true)
            }

        var bestBySeason: [String: EpisodeProgressEntry] = [:]
        for entry in eligible {
            let key = "\(entry.showId)_\(entry.seasonNumber)"
            if let existing = bestBySeason[key], existing.episodeNumber >= entry.episodeNumber {
                continue
            }
            bestBySeason[key] = entry
        }

        return Array(bestBySeason.values)
    }

#if !os(tvOS)
    private func localHighestReadMangaChapters() -> [(mangaId: Int, chapter: Int)] {
#if os(tvOS)
        return []
#else
        MangaReadingProgressManager.shared.progressMap.compactMap { element in
            let mangaId = element.key
            let progress = element.value
            let highest = progress.readChapterNumbers.compactMap { numericChapter(from: $0) }.max()
            return highest.map { (mangaId: mangaId, chapter: $0) }
        }
#endif
    }

    private func numericChapter(from chapter: String) -> Int? {
        let pattern = #"(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: chapter, range: NSRange(chapter.startIndex..., in: chapter)),
              let range = Range(match.range(at: 1), in: chapter) else {
            return nil
        }
        return Int(chapter[range])
    }
#endif

    private func remoteWatchedEpisodes(_ entry: RemoteAnimeProgress) -> Int {
        if entry.status.uppercased() == "COMPLETED" || entry.status.lowercased() == "completed" {
            return max(entry.progress, entry.totalEpisodes ?? 0)
        }
        return max(entry.progress, 0)
    }

#if !os(tvOS)
    private func remoteReadChapters(_ entry: RemoteMangaProgress) -> Int {
        if entry.status.uppercased() == "COMPLETED" || entry.status.lowercased() == "completed" {
            return max(entry.progress, entry.totalChapters ?? 0)
        }
        return max(entry.progress, 0)
    }
#endif

    private func localCollectionName(forRemoteStatus status: String, sourceName: String) -> String {
        let normalized = status.uppercased()
        let base: String
        switch normalized {
        case "CURRENT", "WATCHING":
            base = "Watching"
        case "PLANNING", "PLAN_TO_WATCH":
            base = "Planning"
        case "COMPLETED":
            base = "Completed"
        case "PAUSED", "ON_HOLD":
            base = "Paused"
        case "DROPPED":
            base = "Dropped"
        case "REPEATING":
            base = "Repeating"
        default:
            base = "Tracking"
        }

        return sourceName == "AniList" ? base : "\(sourceName) \(base)"
    }

#if !os(tvOS)
    private func localMangaCollectionName(forRemoteStatus status: String, sourceName: String) -> String {
        let normalized = status.uppercased()
        let base: String
        switch normalized {
        case "CURRENT", "READING":
            base = "Reading"
        case "PLANNING", "PLAN_TO_READ":
            base = "Planning"
        case "COMPLETED":
            base = "Completed"
        case "PAUSED", "ON_HOLD":
            base = "Paused"
        case "DROPPED":
            base = "Dropped"
        case "REPEATING", "REREADING":
            base = "Repeating"
        default:
            base = "Tracking"
        }

        return sourceName == "AniList" ? base : "\(sourceName) \(base)"
    }
#endif

    private func malStatus(fromAniListStatus status: String) -> String {
        switch status.uppercased() {
        case "COMPLETED":
            return "completed"
        case "PAUSED":
            return "on_hold"
        case "DROPPED":
            return "dropped"
        case "PLANNING":
            return "plan_to_watch"
        default:
            return "watching"
        }
    }

#if !os(tvOS)
    private func malMangaStatus(fromAniListStatus status: String) -> String {
        switch status.uppercased() {
        case "COMPLETED":
            return "completed"
        case "PAUSED":
            return "on_hold"
        case "DROPPED":
            return "dropped"
        case "PLANNING":
            return "plan_to_read"
        default:
            return "reading"
        }
    }
#endif

    private func aniListStatus(fromMALStatus status: String) -> String {
        switch status.lowercased() {
        case "completed":
            return "COMPLETED"
        case "on_hold":
            return "PAUSED"
        case "dropped":
            return "DROPPED"
        case "plan_to_watch":
            return "PLANNING"
        default:
            return "CURRENT"
        }
    }

    private func saveAniListAnimeProgress(account: TrackerAccount, anilistId: Int, watchedEpisodes: Int, status: String) async {
        let completedAtClause: String
        if status == "COMPLETED" {
            completedAtClause = """
            , completedAt: {
                        year: \(Calendar.current.component(.year, from: Date()))
                        month: \(Calendar.current.component(.month, from: Date()))
                        day: \(Calendar.current.component(.day, from: Date()))
                    }
            """
        } else {
            completedAtClause = ""
        }

        let mutation = """
        mutation {
            SaveMediaListEntry(
                mediaId: \(anilistId),
                progress: \(max(watchedEpisodes, 0)),
                status: \(status)\(completedAtClause)
            ) {
                id
                progress
                status
            }
        }
        """

        do {
            let url = URL(string: "https://graphql.anilist.co")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": mutation])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            if response.statusCode == 200,
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                Logger.shared.log("AniList sync error: \(errors.first?["message"] as? String ?? "Unknown error")", type: "Tracker")
            } else if response.statusCode == 200 {
                Logger.shared.log("Synced AniList anime \(anilistId): progress=\(watchedEpisodes) status=\(status)", type: "Tracker")
            } else {
                Logger.shared.log("AniList anime sync returned status \(response.statusCode)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync AniList anime \(anilistId): \(error.localizedDescription)", type: "Error")
        }
    }

#if !os(tvOS)
    private func saveAniListMangaProgress(account: TrackerAccount, anilistId: Int, chaptersRead: Int, status: String) async {
        let mutation = """
        mutation {
            SaveMediaListEntry(
                mediaId: \(anilistId),
                progress: \(max(chaptersRead, 0)),
                status: \(status)
            ) {
                id
                progress
                status
            }
        }
        """

        do {
            let url = URL(string: "https://graphql.anilist.co")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": mutation])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            if response.statusCode == 200,
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                ReaderLogger.shared.log("AniList manga sync error: \(errors.first?["message"] as? String ?? "Unknown error")", type: "Tracker")
            } else if response.statusCode == 200 {
                ReaderLogger.shared.log("Synced AniList manga \(anilistId): progress=\(chaptersRead) status=\(status)", type: "Tracker")
            } else {
                ReaderLogger.shared.log("AniList manga sync returned status \(response.statusCode)", type: "Tracker")
            }
        } catch {
            ReaderLogger.shared.log("Failed to sync AniList manga \(anilistId): \(error.localizedDescription)", type: "Error")
        }
    }
#endif

    func disconnectTracker(_ service: TrackerService) {
        trackerState.disconnectAccount(for: service)
#if os(tvOS)
        if service == .trakt {
            traktDeviceAuthTask?.cancel()
            traktDeviceAuthTask = nil
            traktDeviceUserCode = nil
            traktDeviceVerificationURL = nil
            isAuthenticating = false
            webAuthSession = nil
        }
#endif
        if let index = trackerState.accounts.firstIndex(where: { $0.service == service }) {
            trackerState.accounts[index].accessToken = ""
            trackerState.accounts[index].refreshToken = nil
            trackerState.accounts[index].expiresAt = nil
        }
        TrackerCredentialVault.remove(service)
        saveTrackerState()
    }

    // MARK: - Tracker Library Import

    /// Import supported tracker progress into local Eclipse collections.
    @Published var isImportingAniList = false
    @Published var aniListImportError: String?
    @Published var aniListImportProgress: String?
    @Published var isImportingMAL = false
    @Published var malImportError: String?
    @Published var malImportProgress: String?
    @Published var isImportingTrakt = false
    @Published var traktImportError: String?
    @Published var traktImportProgress: String?

    func importAniListToLibrary() {
        guard let account = trackerState.getAccount(for: .anilist), account.isConnected else {
            aniListImportError = "No connected AniList account"
            return
        }

        guard !isImportingAniList else { return }

        // Set the latch before launching the worker task so repeated button taps
        // cannot start overlapping imports before an enqueued MainActor task runs.
        isImportingAniList = true
        aniListImportError = nil
        aniListImportProgress = "Fetching your AniList library..."

        Task {
            setBackupRestoreSyncSuppressed(true)
            defer { setBackupRestoreSyncSuppressed(false) }

            do {
                let animeEntries = try await fetchAniListAnimeProgressEntries(account: account)
#if os(tvOS)
                await MainActor.run {
                    aniListImportProgress = "Adding anime to Eclipse..."
                }

                let animeResult = try await fillEclipseFromRemoteAnime(animeEntries, sourceName: "AniList", action: .fillEclipseFromAniList)
                let imported = animeResult.itemsToAdd + animeResult.itemsToAdvance

                await MainActor.run {
                    isImportingAniList = false
                    aniListImportProgress = nil
                    aniListImportError = nil
                    Logger.shared.log("AniList anime import completed: \(imported) local changes from \(animeEntries.count) entries", type: "Tracker")
                }
#else
                let mangaEntries = try await fetchAniListMangaProgressEntries(account: account)

                await MainActor.run {
                    aniListImportProgress = "Adding items to Eclipse..."
                }

                let animeResult = try await fillEclipseFromRemoteAnime(animeEntries, sourceName: "AniList", action: .fillEclipseFromAniList)
                let mangaResult = try await fillEclipseFromRemoteManga(mangaEntries, sourceName: "AniList", action: .fillEclipseFromAniList)
                let imported = animeResult.itemsToAdd + animeResult.itemsToAdvance + mangaResult.itemsToAdvance

                await MainActor.run {
                    isImportingAniList = false
                    aniListImportProgress = nil
                    aniListImportError = nil
                    Logger.shared.log("AniList import completed: \(imported) local changes from \(animeEntries.count) anime and \(mangaEntries.count) manga entries", type: "Tracker")
                }
#endif
            } catch {
                await MainActor.run {
                    isImportingAniList = false
                    aniListImportProgress = nil
                    aniListImportError = "Import failed: \(error.localizedDescription)"
                    Logger.shared.log("AniList import failed: \(error.localizedDescription)", type: "Error")
                }
            }
        }
    }

    func importMALToLibrary() {
        guard trackerState.getAccount(for: .myAnimeList)?.isConnected == true else {
            malImportError = "No connected MAL account"
            return
        }

        guard !isImportingMAL else { return }

        isImportingMAL = true
        malImportError = nil
        malImportProgress = "Fetching your MAL library..."

        Task {
            setBackupRestoreSyncSuppressed(true)
            defer { setBackupRestoreSyncSuppressed(false) }

            do {
                let account = try await connectedMALAccount()
                let fetchedAnimeEntries = try await fetchMALAnimeProgressEntries(account: account)
#if os(tvOS)
                await MainActor.run {
                    malImportProgress = "Matching MAL anime to app collections..."
                }

                let animeEntries = await resolveMALAnimeEntriesToAniList(fetchedAnimeEntries)
                let mappedAnimeCount = animeEntries.filter { $0.anilistId != nil }.count

                await MainActor.run {
                    malImportProgress = "Adding \(mappedAnimeCount) anime entries to app collections..."
                }

                let animeResult = try await fillMALAnimeCollectionsForLibraryImport(animeEntries, action: .fillEclipseFromMAL)
                let imported = animeResult.itemsToAdd + animeResult.itemsToAdvance

                await MainActor.run {
                    isImportingMAL = false
                    malImportProgress = nil
                    malImportError = nil
                    Logger.shared.log("MAL anime import completed: \(imported) local changes from \(animeEntries.count) entries", type: "Tracker")
                }
#else
                let fetchedMangaEntries = try await fetchMALMangaProgressEntries(account: account)

                await MainActor.run {
                    malImportProgress = "Matching MAL entries to app collections..."
                }

                let animeEntries = await resolveMALAnimeEntriesToAniList(fetchedAnimeEntries)
                let mangaEntries = await resolveMALMangaEntriesToAniList(fetchedMangaEntries)
                let mappedAnimeCount = animeEntries.filter { $0.anilistId != nil }.count
                let mappedMangaCount = mangaEntries.filter { $0.anilistId != nil }.count

                await MainActor.run {
                    malImportProgress = "Adding \(mappedAnimeCount) anime and \(mappedMangaCount) manga entries to app collections..."
                }

                let animeResult = try await fillMALAnimeCollectionsForLibraryImport(animeEntries, action: .fillEclipseFromMAL)
                let mangaCollectionResult = try await fillMALMangaCollectionsForLibraryImport(mangaEntries, action: .fillEclipseFromMAL)
                let mangaResult = try await fillEclipseFromRemoteManga(mangaEntries, sourceName: "MAL", action: .fillEclipseFromMAL)
                let imported = animeResult.itemsToAdd + animeResult.itemsToAdvance + mangaCollectionResult.itemsToAdd + mangaResult.itemsToAdvance

                await MainActor.run {
                    isImportingMAL = false
                    malImportProgress = nil
                    malImportError = nil
                    Logger.shared.log("MAL import completed: \(imported) local changes from \(animeEntries.count) anime and \(mangaEntries.count) manga entries", type: "Tracker")
                }
#endif
            } catch {
                await MainActor.run {
                    isImportingMAL = false
                    malImportProgress = nil
                    malImportError = "Import failed: \(error.localizedDescription)"
                    Logger.shared.log("MAL import failed: \(error.localizedDescription)", type: "Error")
                }
            }
        }
    }

    // MARK: - Trakt Watchlist Sync

    static let traktWatchlistCollectionName = "Trakt Watchlist"

    /// Mirror a local "Trakt Watchlist" collection change up to the Trakt watchlist.
    func pushTraktWatchlistChange(searchResult: TMDBSearchResult, added: Bool) {
        guard trackerState.syncEnabled,
              trackerState.traktWatchlistSync,
              !isBackupRestoreSyncSuppressed(),
              let account = trackerState.getAccount(for: .trakt),
              searchResult.id > 0 else { return }

        let mediaKey = searchResult.isMovie ? "movies" : "shows"
        let tmdbId = searchResult.id
        let path = added ? "sync/watchlist" : "sync/watchlist/remove"
        let payload: [String: Any] = [mediaKey: [["ids": ["tmdb": tmdbId]]]]

        Task {
            do {
                let refreshedAccount = try await refreshedTraktAccountIfNeeded(account)
                _ = try await postTraktJSON(path: path, account: refreshedAccount, payload: payload)
                Logger.shared.log("Trakt watchlist \(added ? "add" : "remove") tmdb=\(tmdbId) type=\(mediaKey)", type: "Tracker")
            } catch {
                Logger.shared.log("Failed Trakt watchlist \(added ? "add" : "remove") tmdb=\(tmdbId): \(error.localizedDescription)", type: "Error")
            }
        }
    }

    /// Pull the Trakt watchlist into the local "Trakt Watchlist" collection. Additive:
    /// never deletes local items (matches Eclipse's "import never downgrades" rule), so a
    /// removal made on another device won't surprise-delete a local entry.
    func refreshTraktWatchlistCollection() {
        guard trackerState.syncEnabled,
              trackerState.traktWatchlistSync,
              let account = trackerState.getAccount(for: .trakt) else { return }

        Task {
            do {
                let refreshedAccount = try await refreshedTraktAccountIfNeeded(account)
                async let showPages = fetchAllTraktPages(path: "users/me/watchlist/shows?extended=full", account: refreshedAccount)
                async let moviePages = fetchAllTraktPages(path: "users/me/watchlist/movies?extended=full", account: refreshedAccount)
                let (showsRaw, moviesRaw) = try await (showPages, moviePages)

                let decoder = JSONDecoder()
                let watchlistShows = try showsRaw.flatMap { try decoder.decode([TraktWatchlistShowResponse].self, from: $0) }
                let watchlistMovies = try moviesRaw.flatMap { try decoder.decode([TraktWatchlistMovieResponse].self, from: $0) }
                let showIds = Array(Set(watchlistShows.compactMap { $0.show.ids.tmdb }))
                let movieIds = Array(Set(watchlistMovies.compactMap { $0.movie.ids.tmdb }))

                var results: [TMDBSearchResult] = []
                for id in showIds {
                    if let detail = try? await TMDBService.shared.getTVShowDetails(id: id) {
                        results.append(Self.tmdbSearchResult(from: detail))
                    }
                }
                for id in movieIds {
                    if let detail = try? await TMDBService.shared.getMovieDetails(id: id) {
                        results.append(Self.tmdbSearchResult(from: detail))
                    }
                }

                let resolvedResults = results
                await MainActor.run {
                    LibraryManager.shared.applyTraktWatchlistPull(resolvedResults)
                }
                Logger.shared.log("Trakt watchlist pull: \(resolvedResults.count) items merged into \(Self.traktWatchlistCollectionName)", type: "Tracker")
            } catch {
                Logger.shared.log("Failed to refresh Trakt watchlist: \(error.localizedDescription)", type: "Error")
            }
        }
    }

    func importTraktToLibrary() {
        guard let account = trackerState.getAccount(for: .trakt), account.isConnected else {
            traktImportError = "No connected Trakt account"
            return
        }

        guard !isImportingTrakt else { return }

        isImportingTrakt = true
        traktImportError = nil
        traktImportProgress = "Fetching your Trakt library..."

        Task {
            setBackupRestoreSyncSuppressed(true)
            defer { setBackupRestoreSyncSuppressed(false) }

            do {
                let refreshedAccount = try await refreshedTraktAccountIfNeeded(account)
                async let watchlistShowPages = fetchAllTraktPages(path: "users/me/watchlist/shows?extended=full", account: refreshedAccount)
                async let watchlistMoviePages = fetchAllTraktPages(path: "users/me/watchlist/movies?extended=full", account: refreshedAccount)
                async let watchedShowData = fetchTraktPlaybackData(path: "users/me/watched/shows", account: refreshedAccount)
                async let watchedMovieData = fetchTraktPlaybackData(path: "users/me/watched/movies", account: refreshedAccount)
                let (watchlistShowsRaw, watchlistMoviesRaw, watchedShowsRaw, watchedMoviesRaw) = try await (
                    watchlistShowPages,
                    watchlistMoviePages,
                    watchedShowData,
                    watchedMovieData
                )

                let decoder = JSONDecoder()
                let watchlistShows = try watchlistShowsRaw.flatMap { try decoder.decode([TraktWatchlistShowResponse].self, from: $0) }
                let watchlistMovies = try watchlistMoviesRaw.flatMap { try decoder.decode([TraktWatchlistMovieResponse].self, from: $0) }
                let watchedShows = try decoder.decode([TraktWatchedShowResponse].self, from: watchedShowsRaw)
                let watchedMovies = try decoder.decode([TraktWatchedMovieResponse].self, from: watchedMoviesRaw)
                let showIds = Array(Set((watchlistShows.compactMap { $0.show.ids.tmdb }) + (watchedShows.compactMap { $0.show.ids.tmdb }))).sorted()
                let movieIds = Array(Set((watchlistMovies.compactMap { $0.movie.ids.tmdb }) + (watchedMovies.compactMap { $0.movie.ids.tmdb }))).sorted()

                await MainActor.run {
                    traktImportProgress = "Matching \(showIds.count) shows and \(movieIds.count) movies to TMDB..."
                }

                var mappedShows: [Int: TMDBSearchResult] = [:]
                for tmdbId in showIds {
                    if let detail = try? await TMDBService.shared.getTVShowDetails(id: tmdbId) {
                        mappedShows[tmdbId] = Self.tmdbSearchResult(from: detail)
                    }
                }

                var mappedMovies: [Int: TMDBSearchResult] = [:]
                for tmdbId in movieIds {
                    if let detail = try? await TMDBService.shared.getMovieDetails(id: tmdbId) {
                        mappedMovies[tmdbId] = Self.tmdbSearchResult(from: detail)
                    }
                }

                await MainActor.run {
                    traktImportProgress = "Adding matched items and exact watched episodes to Eclipse..."
                }

                let resolvedShows = mappedShows
                let resolvedMovies = mappedMovies
                let counts = await MainActor.run { () -> (added: Int, advanced: Int, skipped: Int) in
                    let library = LibraryManager.shared
                    var added = 0
                    var advanced = 0
                    var skipped = 0

                    func collection(named name: String) -> LibraryCollection? {
                        if let existing = library.collections.first(where: { $0.name == name }) {
                            return existing
                        }
                        library.createCollection(name: name, description: "Imported from Trakt")
                        return library.collections.first(where: { $0.name == name })
                    }

                    func add(_ result: TMDBSearchResult, to collectionName: String) {
                        guard let collection = collection(named: collectionName) else {
                            skipped += 1
                            return
                        }
                        let item = LibraryItem(searchResult: result)
                        if !library.isItemInCollection(collection.id, item: item) {
                            library.addItem(to: collection.id, item: item)
                            added += 1
                        }
                    }

                    for entry in watchlistShows {
                        guard let tmdbId = entry.show.ids.tmdb, let result = resolvedShows[tmdbId] else {
                            skipped += 1
                            continue
                        }
                        add(result, to: "Trakt Watchlist")
                    }

                    for entry in watchlistMovies {
                        guard let tmdbId = entry.movie.ids.tmdb, let result = resolvedMovies[tmdbId] else {
                            skipped += 1
                            continue
                        }
                        add(result, to: "Trakt Watchlist")
                    }

                    for entry in watchedShows {
                        guard let tmdbId = entry.show.ids.tmdb, let result = resolvedShows[tmdbId] else {
                            skipped += 1
                            continue
                        }
                        let watchedEpisodeCount = (entry.seasons ?? []).reduce(0) { $0 + $1.episodes.count }
                        let collectionName = (entry.show.airedEpisodes ?? 0) > 0 && watchedEpisodeCount >= (entry.show.airedEpisodes ?? 0)
                            ? "Trakt Completed"
                            : "Trakt Watching"
                        add(result, to: collectionName)

                        var didAdvance = false
                        for season in entry.seasons ?? [] {
                            let watchedEpisodes = season.episodes.map(\.number)
                            guard !watchedEpisodes.isEmpty else { continue }
                            ProgressManager.shared.bulkMarkEpisodeNumbersAsWatched(
                                showId: tmdbId,
                                seasonNumber: season.number,
                                episodeNumbers: watchedEpisodes
                            )
                            didAdvance = true
                        }
                        if didAdvance {
                            advanced += 1
                        }
                    }

                    for entry in watchedMovies {
                        guard let tmdbId = entry.movie.ids.tmdb, let result = resolvedMovies[tmdbId] else {
                            skipped += 1
                            continue
                        }
                        add(result, to: "Trakt Completed")
                        ProgressManager.shared.markMovieAsWatchedForImport(
                            movieId: tmdbId,
                            title: result.displayTitle,
                            posterURL: result.fullPosterURL
                        )
                        advanced += 1
                    }

                    return (added: added, advanced: advanced, skipped: skipped)
                }

                await MainActor.run {
                    isImportingTrakt = false
                    traktImportProgress = nil
                    traktImportError = nil
                    Logger.shared.log("Trakt import completed: \(counts.added) collection additions, \(counts.advanced) progress updates, \(counts.skipped) skipped entries", type: "Tracker")
                }
            } catch {
                await MainActor.run {
                    isImportingTrakt = false
                    traktImportProgress = nil
                    traktImportError = "Import failed: \(error.localizedDescription)"
                    Logger.shared.log("Trakt import failed: \(error.localizedDescription)", type: "Error")
                }
            }
        }
    }

    private static func tmdbSearchResult(from detail: TMDBTVShowDetail) -> TMDBSearchResult {
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

    private static func tmdbSearchResult(from detail: TMDBMovieDetail) -> TMDBSearchResult {
        TMDBSearchResult(
            id: detail.id,
            mediaType: "movie",
            title: detail.title,
            name: nil,
            overview: detail.overview,
            posterPath: detail.posterPath,
            backdropPath: detail.backdropPath,
            releaseDate: detail.releaseDate,
            firstAirDate: nil,
            voteAverage: detail.voteAverage,
            popularity: detail.popularity,
            adult: detail.adult,
            genreIds: detail.genres.map(\.id)
        )
    }
}

#if !os(tvOS)
extension TrackerManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }
}
#endif
