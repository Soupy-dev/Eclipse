//
//  TrackerManager.swift
//  Luna
//
//  Created by Soupy-dev
//

import Foundation
import Combine
#if !os(tvOS)
import AuthenticationServices
#endif
import UIKit

final class TrackerManager: NSObject, ObservableObject {
    static let shared = TrackerManager()

    @Published var trackerState: TrackerState = TrackerState()
    @Published var isAuthenticating = false
    @Published var authError: String?

    private let trackerStateURL: URL
    #if !os(tvOS)
    private var webAuthSession: ASWebAuthenticationSession?
    #endif

    // Cache for TMDB ID -> AniList ID mappings to support anime syncing
    private var anilistIdCache: [Int: Int] = [:]
    private let anilistIdCacheQueue = DispatchQueue(label: "com.luna.anilistIdCache")
    
    // Cache for (TMDB ID, season number) -> AniList ID for anime with multiple AniList entries per season
    private var anilistSeasonIdCache: [String: Int] = [:] // key format: "tmdbId_seasonNumber"
    private let anilistSeasonIdCacheQueue = DispatchQueue(label: "com.luna.anilistSeasonIdCache")

    // Prevent tracker sync bursts during local backup restore.
    private var syncSuppressedDuringBackupRestore = false
    private let backupRestoreSyncQueue = DispatchQueue(label: "com.luna.backupRestoreSync")

    // OAuth config (redirects can be overridden via Info.plist keys AniListRedirectUri / TraktRedirectUri)
    private let anilistClientId = "33908"
    private let anilistClientSecret = "1TeOfbdHy3Uk88UQdE8HKoJDtdI5ARHP4sDCi5Jh"
    private var anilistRedirectUri: String {
        Bundle.main.object(forInfoDictionaryKey: "AniListRedirectUri") as? String ?? "luna://anilist-callback"
    }

    private let traktClientId = "e92207aaef82a1b0b42d5901efa4756b6c417911b7b031b986d37773c234ccab"
    private let traktClientSecret = "03c457ea5986e900f140243c69d616313533cedcc776e42e07a6ddd3ab699035"
    private var traktRedirectUri: String {
        Bundle.main.object(forInfoDictionaryKey: "TraktRedirectUri") as? String ?? "luna://trakt-callback"
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
           let state = try? JSONDecoder().decode(TrackerState.self, from: data) {
            self.trackerState = state
        }
    }

    func saveTrackerState() {
        DispatchQueue.global(qos: .background).async {
            if let encoded = try? JSONEncoder().encode(self.trackerState) {
                try? encoded.write(to: self.trackerStateURL)
            }
        }
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

    // MARK: - AniList Authentication

    func getAniListAuthURL() -> URL? {
        var components = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: anilistClientId),
            URLQueryItem(name: "redirect_uri", value: anilistRedirectUri),
            URLQueryItem(name: "response_type", value: "code")
        ]
        let url = components?.url
        Logger.shared.log("AniList auth URL: \(url?.absoluteString ?? "nil")", type: "Tracker")
        return url
    }

    func startAniListAuth() {
        guard let url = getAniListAuthURL() else { return }
        authError = nil
        isAuthenticating = true

        #if os(tvOS)
        UIApplication.shared.open(url) { _ in }
        DispatchQueue.main.async {
            self.isAuthenticating = false
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

            Logger.shared.log("AniList callback URL: \(callbackURL.absoluteString)", type: "Tracker")

            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                Logger.shared.log("Failed to extract code from AniList callback. URL: \(callbackURL.absoluteString)", type: "Error")
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
        let url = URL(string: "https://anilist.co/api/v2/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": anilistClientId,
            "client_secret": anilistClientSecret,
            "redirect_uri": anilistRedirectUri,
            "code": code
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.shared.log("Exchanging AniList code for token", type: "Tracker")
        Logger.shared.log("AniList request: client_id=\(anilistClientId), client_secret length=\(anilistClientSecret.count), redirect_uri=\(anilistRedirectUri)", type: "Tracker")        

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? -1

        Logger.shared.log("AniList token response status: \(statusCode)", type: "Tracker")
        Logger.shared.log("AniList response data length: \(data.count) bytes", type: "Tracker")

        if let responseString = String(data: data, encoding: .utf8) {
            Logger.shared.log("AniList response: \(responseString)", type: "Tracker")
        }

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

        if let responseString = String(data: data, encoding: .utf8) {
            Logger.shared.log("AniList user response: \(responseString)", type: "Tracker")
        }

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

    // MARK: - Trakt Authentication

    func getTraktAuthURL() -> URL? {
        var components = URLComponents(string: "https://trakt.tv/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: traktClientId),
            URLQueryItem(name: "redirect_uri", value: traktRedirectUri),
            URLQueryItem(name: "response_type", value: "code")
        ]
        let url = components?.url
        Logger.shared.log("Trakt auth URL: \(url?.absoluteString ?? "nil")", type: "Tracker")
        return url
    }

    func startTraktAuth() {
        guard let url = getTraktAuthURL() else { return }
        authError = nil
        isAuthenticating = true

        #if os(tvOS)
        UIApplication.shared.open(url) { _ in }
        DispatchQueue.main.async {
            self.isAuthenticating = false
        }
        #else
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "luna") { [weak self] callbackURL, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                }
                Logger.shared.log("Trakt auth error: \(error.localizedDescription)", type: "Error")
                return
            }

            guard let callbackURL = callbackURL else {
                Logger.shared.log("Trakt callback URL is nil", type: "Error")
                DispatchQueue.main.async {
                    self.authError = "Trakt callback URL is nil"
                    self.isAuthenticating = false
                }
                return
            }

            Logger.shared.log("Trakt callback URL: \(callbackURL.absoluteString)", type: "Tracker")

            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                Logger.shared.log("Failed to extract code from Trakt callback. URL: \(callbackURL.absoluteString)", type: "Error")
                DispatchQueue.main.async {
                    self.authError = "Invalid Trakt callback - failed to extract code"
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
                    self.isAuthenticating = false
                    self.authError = nil
                    Logger.shared.log("Trakt account saved", type: "Tracker")
                }
            } catch {
                await MainActor.run {
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

        if let responseString = String(data: data, encoding: .utf8) {
            Logger.shared.log("Trakt response: \(responseString)", type: "Tracker")
        }

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

    private func fetchTraktUser(token: String) async throws -> TraktUser {
        let url = URL(string: "https://api.trakt.tv/users/me")!
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

        if let responseString = String(data: data, encoding: .utf8) {
            Logger.shared.log("Trakt user response: \(responseString)", type: "Tracker")
        }

        do {
            return try JSONDecoder().decode(TraktUser.self, from: data)
        } catch {
            Logger.shared.log("Failed to decode Trakt user response: \(error.localizedDescription)", type: "Error")
            throw error
        }
    }

    // MARK: - Sync Methods

    func cacheAniListId(tmdbId: Int, anilistId: Int) {
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

    func syncMangaProgress(title: String, chapterNumber: Int) {
        guard trackerState.syncEnabled else {
            Logger.shared.log("Skipping manga sync (sync disabled) for \(title) ch \(chapterNumber)", type: "Tracker")
            return
        }

        guard let account = trackerState.getAccount(for: .anilist), account.isConnected else {
            Logger.shared.log("Skipping manga sync (no connected AniList account) for \(title) ch \(chapterNumber)", type: "Tracker")
            return
        }

        Logger.shared.log("Starting manga sync to AniList for \(title) ch \(chapterNumber)", type: "Tracker")

        Task {
            guard let mediaId = await getAniListMangaId(title: title) else {
                Logger.shared.log("Could not find AniList manga ID for title \(title)", type: "Tracker")
                return
            }
            await sendMangaProgressToAniList(mediaId: mediaId, chapterNumber: chapterNumber, account: account)
        }
    }

    /// Sync manga reading progress using a known AniList media ID (skips title lookup).
    func syncMangaProgress(aniListId: Int, chapterNumber: Int) {
        guard trackerState.syncEnabled else {
            Logger.shared.log("Skipping manga sync (sync disabled) for aniListId \(aniListId) ch \(chapterNumber)", type: "Tracker")
            return
        }

        guard let account = trackerState.getAccount(for: .anilist), account.isConnected else {
            Logger.shared.log("Skipping manga sync (no connected AniList account) for aniListId \(aniListId) ch \(chapterNumber)", type: "Tracker")
            return
        }

        Logger.shared.log("Starting manga sync to AniList for aniListId \(aniListId) ch \(chapterNumber)", type: "Tracker")

        Task {
            await sendMangaProgressToAniList(mediaId: aniListId, chapterNumber: chapterNumber, account: account)
        }
    }

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

            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                    let errorMsg = (errors.first?["message"] as? String) ?? "Unknown error"
                    Logger.shared.log("AniList manga sync error: \(errorMsg)", type: "Tracker")
                } else {
                    Logger.shared.log("Synced manga to AniList: chapter \(chapterNumber) for mediaId \(mediaId)", type: "Tracker")
                }
            } else {
                Logger.shared.log("AniList manga sync returned status \((response as? HTTPURLResponse)?.statusCode ?? -1)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync manga to AniList: \(error.localizedDescription)", type: "Error")
        }
    }

    func syncWatchProgress(showId: Int, seasonNumber: Int, episodeNumber: Int, progress: Double, isMovie: Bool = false, playbackContext: EpisodePlaybackContext? = nil) {
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

        Logger.shared.log("Starting watch sync for TMDB \(showId) S\(seasonNumber)E\(episodeNumber) \(Int(progress))% across \(connectedAccounts.count) account(s)", type: "Tracker")     

        Task {
            for account in connectedAccounts {
                Logger.shared.log("Syncing \(account.service) account \(account.username) for TMDB \(showId) S\(seasonNumber)E\(episodeNumber)", type: "Tracker")
                switch account.service {
                case .anilist:
                    if let playbackContext,
                       let anilistMediaId = playbackContext.anilistMediaId {
                        await syncToAniListMediaId(
                            account: account,
                            anilistId: anilistMediaId,
                            showId: showId,
                            seasonNumber: playbackContext.localSeasonNumber,
                            episodeNumber: playbackContext.localEpisodeNumber,
                            progress: progress
                        )
                    } else {
                        await syncToAniList(account: account, showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber, progress: progress)
                    }
                case .trakt:
                    if let playbackContext, playbackContext.isSpecial {
                        if let tmdbSeason = playbackContext.resolvedTMDBSeasonNumber,
                           let tmdbEpisode = playbackContext.resolvedTMDBEpisodeNumber {
                            await syncToTrakt(account: account, showId: showId, seasonNumber: tmdbSeason, episodeNumber: tmdbEpisode, progress: progress)
                        } else {
                            Logger.shared.log("Skipping Trakt sync for special without TMDB episode mapping: TMDB \(showId) S\(seasonNumber)E\(episodeNumber)", type: "Tracker")
                        }
                    } else {
                        await syncToTrakt(account: account, showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber, progress: progress)
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
        let status = isFinalEpisode ? "COMPLETED" : "CURRENT"

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
                progress: \(episodeNumber),
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

            let body: [String: Any] = ["query": mutation]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                // Parse response to check for errors
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                    let errorMsg = (errors.first?["message"] as? String) ?? "Unknown error"
                    Logger.shared.log("AniList sync error: \(errorMsg)", type: "Tracker")
                } else {
                    Logger.shared.log("Synced to AniList: mediaId=\(anilistId) S\(seasonNumber)E\(episodeNumber) (\(status))", type: "Tracker")
                }
            } else {
                Logger.shared.log("AniList sync returned status \((response as? HTTPURLResponse)?.statusCode ?? -1)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync to AniList: \(error.localizedDescription)", type: "Error")
        }
    }


    private func syncToTrakt(account: TrackerAccount, showId: Int, seasonNumber: Int, episodeNumber: Int, progress: Double) async {
        // First, get the Trakt ID from TMDB ID
        guard let traktId = await getTraktIdFromTmdbId(showId) else {
            Logger.shared.log("Could not find Trakt ID for TMDB ID \(showId)", type: "Tracker")
            return
        }

        let traktProgress = progress <= 1.0 ? progress * 100.0 : progress

        // Only mark as watched if progress >= 85% (following NuvioStreaming pattern)
        guard traktProgress >= 85 else {
            // For progress < 85%, use scrobble pause instead
            await scrobblePause(account: account, traktId: traktId, seasonNumber: seasonNumber, episodeNumber: episodeNumber, progress: traktProgress)
            return
        }

        // Mark episode as watched with proper payload structure
        let watchedAt = ISO8601DateFormatter().string(from: Date())
        let payload: [String: Any] = [
            "shows": [
                [
                    "ids": [
                        "trakt": traktId
                    ],
                    "seasons": [
                        [
                            "number": seasonNumber,
                            "episodes": [
                                [
                                    "number": episodeNumber,
                                    "watched_at": watchedAt
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        do {
            let url = URL(string: "https://api.trakt.tv/sync/history")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("2", forHTTPHeaderField: "trakt-api-version")

            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            
            if statusCode == 201 {
                // Log the response to see what was actually added
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    Logger.shared.log("Trakt sync response: \(json)", type: "Tracker")
                }
                Logger.shared.log("Synced to Trakt: S\(seasonNumber)E\(episodeNumber) (watched)", type: "Tracker")
            } else {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                Logger.shared.log("Trakt sync returned status \(statusCode): \(bodyPreview)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync to Trakt: \(error.localizedDescription)", type: "Error")
        }
    }

    private func scrobblePause(account: TrackerAccount, traktId: Int, seasonNumber: Int, episodeNumber: Int, progress: Double) async {
        let payload: [String: Any] = [
            "progress": progress,
            "episode": [
                "season": seasonNumber,
                "number": episodeNumber
            ]
        ]

        do {
            let url = URL(string: "https://api.trakt.tv/scrobble/pause")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("2", forHTTPHeaderField: "trakt-api-version")

            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (_, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 201 {
                Logger.shared.log("Scrobbled to Trakt: S\(seasonNumber)E\(episodeNumber) \(Int(progress))%", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to scrobble to Trakt: \(error.localizedDescription)", type: "Error")
        }
    }

    private func getTraktIdFromTmdbId(_ tmdbId: Int) async -> Int? {
        do {
            let url = URL(string: "https://api.trakt.tv/search/tmdb/\(tmdbId)?type=show")!
            var request = URLRequest(url: url)
            request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
            request.setValue("2", forHTTPHeaderField: "trakt-api-version")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                Logger.shared.log("Trakt tmdb lookup failed (HTTP \(status)): \(bodyPreview)", type: "Tracker")
                return nil
            }

            struct SearchResult: Codable {
                let show: ShowData?
                struct ShowData: Codable {
                    let ids: IDData
                    struct IDData: Codable { let trakt: Int }
                }
            }

            if let results = try JSONDecoder().decode([SearchResult].self, from: data).first,
               let traktId = results.show?.ids.trakt {
                return traktId
            }
            return nil
        } catch {
            Logger.shared.log("Failed to get Trakt ID: \(error.localizedDescription)", type: "Error")
            return nil
        }
    }


    // MARK: - Helper Methods

    private func getAniListEpisodeCount(mediaId: Int) async -> Int? {
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

            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.data.Media?.episodes
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

            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.data.Page.media.first?.id
        } catch {
            Logger.shared.log("AniList title search failed for \(title): \(error.localizedDescription)", type: "Tracker")
            return nil
        }
    }

    private func getAniListMangaId(title: String) async -> Int? {
        let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
        let query = """
        query {
            Media(search: "\(escaped)", type: MANGA) {
                id
            }
        }
        """

        do {
            let url = URL(string: "https://graphql.anilist.co")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = ["query": query]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, _) = try await URLSession.shared.data(for: request)

            struct Response: Codable {
                let data: DataWrapper
                struct DataWrapper: Codable { let Media: MediaData? }
                struct MediaData: Codable { let id: Int }
            }

            let response = try JSONDecoder().decode(Response.self, from: data)
            return response.data.Media?.id
        } catch {
            Logger.shared.log("Failed to resolve AniList manga ID: \(error.localizedDescription)", type: "Error")
            return nil
        }
    }

    func disconnectTracker(_ service: TrackerService) {
        trackerState.disconnectAccount(for: service)
        saveTrackerState()
    }

    // MARK: - AniList Library Import

    /// Import the user's AniList anime lists (Watching, Planning, Completed) into local library collections.
    /// Uses the standard AniList→TMDB matching pipeline so items are consistent with the rest of the app.
    @Published var isImportingAniList = false
    @Published var aniListImportError: String?
    @Published var aniListImportProgress: String?

    func importAniListToLibrary() {
        guard let account = trackerState.getAccount(for: .anilist), account.isConnected else {
            aniListImportError = "No connected AniList account"
            return
        }

        guard !isImportingAniList else { return }

        Task { @MainActor in
            isImportingAniList = true
            aniListImportError = nil
            aniListImportProgress = "Fetching your AniList library…"
        }

        Task {
            do {
                let userId = Int(account.userId) ?? 0
                let lists = try await AniListService.shared.fetchUserAnimeListsForImport(
                    token: account.accessToken,
                    userId: userId,
                    tmdbService: TMDBService.shared
                )

                await MainActor.run {
                    aniListImportProgress = "Adding items to library…"
                }

                let library = LibraryManager.shared
                let mapping: [(name: String, items: [AniListService.AniListImportEntry])] = [
                    ("Watching",  lists.watching),
                    ("Planning",  lists.planning),
                    ("Completed", lists.completed),
                    ("Paused",    lists.paused),
                    ("Dropped",   lists.dropped),
                    ("Repeating", lists.repeating),
                ]

                // Suppress tracker sync during import to avoid syncing back to AniList
                setBackupRestoreSyncSuppressed(true)

                await MainActor.run {
                    for (collectionName, importEntries) in mapping where !importEntries.isEmpty {
                        // Find or create the collection
                        let collection: LibraryCollection
                        if let existing = library.collections.first(where: { $0.name == collectionName }) {
                            collection = existing
                        } else {
                            library.createCollection(name: collectionName, description: "Imported from AniList")
                            collection = library.collections.first(where: { $0.name == collectionName })!
                        }

                        var added = 0
                        for entry in importEntries {
                            let item = LibraryItem(searchResult: entry.tmdbResult)
                            if !library.isItemInCollection(collection.id, item: item) {
                                library.addItem(to: collection.id, item: item)
                                added += 1
                            }

                            // Import episode watch progress into ProgressManager
                            if entry.episodesWatched > 0 {
                                ProgressManager.shared.bulkMarkEpisodesAsWatched(
                                    showId: entry.tmdbResult.id,
                                    seasonNumber: 1,
                                    throughEpisode: entry.episodesWatched
                                )
                            }
                        }
                        Logger.shared.log("AniList import: Added \(added) new items to '\(collectionName)' (\(importEntries.count) total matched)", type: "Tracker")
                    }

                    let totalImported = mapping.reduce(0) { $0 + $1.items.count }
                    isImportingAniList = false
                    aniListImportProgress = nil
                    aniListImportError = nil
                    Logger.shared.log("AniList import completed: \(totalImported) total items across \(mapping.filter { !$0.items.isEmpty }.count) collections", type: "Tracker")
                }

                setBackupRestoreSyncSuppressed(false)
            } catch {
                setBackupRestoreSyncSuppressed(false)
                await MainActor.run {
                    isImportingAniList = false
                    aniListImportProgress = nil
                    aniListImportError = "Import failed: \(error.localizedDescription)"
                    Logger.shared.log("AniList import failed: \(error.localizedDescription)", type: "Error")
                }
            }
        }
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
