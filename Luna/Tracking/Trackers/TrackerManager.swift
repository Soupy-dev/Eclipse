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

private enum TrackerRequestProvider: Hashable {
    case anilist
    case myAnimeList
}

private actor TrackerRequestScheduler {
    static let shared = TrackerRequestScheduler()

    private var nextAllowedAt: [TrackerRequestProvider: Date] = [:]
    private var minimumSpacing: [TrackerRequestProvider: TimeInterval] = [
        .anilist: 0.8,
        .myAnimeList: 1.2
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

private struct RemoteAnimeProgress {
    let anilistId: Int?
    let malId: Int?
    let title: String
    let status: String
    let progress: Int
    let totalEpisodes: Int?
}

private struct RemoteMangaProgress {
    let anilistId: Int?
    let malId: Int?
    let title: String
    let status: String
    let progress: Int
    let totalChapters: Int?
}

private struct TrackerSyncToolPlan {
    let action: TrackerSyncToolAction
    let preview: TrackerSyncPreview
    var animeEntries: [RemoteAnimeProgress] = []
    var mangaEntries: [RemoteMangaProgress] = []
}

final class TrackerManager: NSObject, ObservableObject {
    static let shared = TrackerManager()

    @Published var trackerState: TrackerState = TrackerState()
    @Published var isAuthenticating = false
    @Published var authError: String?
    @Published var isRunningSyncTool = false
    @Published var syncToolStatus: String?
    @Published var syncToolPreview: TrackerSyncPreview?
    private var cachedSyncToolPlan: TrackerSyncToolPlan?

    private let trackerStateURL: URL
    #if !os(tvOS)
    private var webAuthSession: ASWebAuthenticationSession?
    #endif

    // Cache for TMDB ID -> AniList ID mappings to support anime syncing
    private var anilistIdCache: [Int: Int] = [:]
    private let anilistIdCacheQueue = DispatchQueue(label: "com.luna.anilistIdCache")

    // Cross-provider ID caches keep sync tools from resolving the same IDs repeatedly.
    private var malToAniListAnimeIdCache: [Int: Int] = [:]
    private var malToAniListMangaIdCache: [Int: Int] = [:]
    private var aniListToMALAnimeIdCache: [Int: Int] = [:]
    private var aniListToMALMangaIdCache: [Int: Int] = [:]
    private var aniListEpisodeCountCache: [Int: Int] = [:]
    private let malListPageLimit = 1000
    
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

    private func sendTrackerRequest(_ request: URLRequest, provider: TrackerRequestProvider, maxRetries: Int = 2) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            await TrackerRequestScheduler.shared.waitForSlot(provider: provider)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "TrackerNetwork", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid tracker response"])
            }

            if let retryDelay = await TrackerRequestScheduler.shared.recordResponse(provider: provider, response: httpResponse),
               attempt < maxRetries - 1 {
                Logger.shared.log("Tracker request paused for rate limit (\(provider)) for \(Int(retryDelay))s", type: "Tracker")
                await MainActor.run {
                    self.syncToolStatus = "Paused for rate limit. Resuming in \(Int(retryDelay))s..."
                }
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                lastError = NSError(domain: "TrackerRateLimit", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Rate limited by tracker"])
                continue
            }

            return (data, httpResponse)
        }

        throw lastError ?? NSError(domain: "TrackerNetwork", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tracker request failed"])
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
        Logger.shared.log("MAL auth URL: \(url?.absoluteString ?? "nil")", type: "Tracker")
        return url
    }

    func startMALAuth() {
        guard let url = getMALAuthURL() else { return }
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

        let accounts = trackerState.accounts.filter { $0.isConnected && ($0.service == .anilist || $0.service == .myAnimeList) }
        guard !accounts.isEmpty else {
            Logger.shared.log("Skipping manga sync (no connected manga tracker account) for \(title) ch \(chapterNumber)", type: "Tracker")
            return
        }

        Logger.shared.log("Starting manga sync for \(title) ch \(chapterNumber) across \(accounts.count) account(s)", type: "Tracker")

        Task {
            guard let mediaId = await getAniListMangaId(title: title) else {
                Logger.shared.log("Could not find AniList manga ID for title \(title)", type: "Tracker")
                return
            }
            for account in accounts {
                switch account.service {
                case .anilist:
                    await sendMangaProgressToAniList(mediaId: mediaId, chapterNumber: chapterNumber, account: account)
                case .myAnimeList:
                    await sendMangaProgressToMAL(aniListId: mediaId, chapterNumber: chapterNumber, account: account)
                case .trakt:
                    break
                }
            }
        }
    }

    /// Sync manga reading progress using a known AniList media ID (skips title lookup).
    func syncMangaProgress(aniListId: Int, chapterNumber: Int) {
        guard trackerState.syncEnabled else {
            Logger.shared.log("Skipping manga sync (sync disabled) for aniListId \(aniListId) ch \(chapterNumber)", type: "Tracker")
            return
        }

        let accounts = trackerState.accounts.filter { $0.isConnected && ($0.service == .anilist || $0.service == .myAnimeList) }
        guard !accounts.isEmpty else {
            Logger.shared.log("Skipping manga sync (no connected manga tracker account) for aniListId \(aniListId) ch \(chapterNumber)", type: "Tracker")
            return
        }

        Logger.shared.log("Starting manga sync for aniListId \(aniListId) ch \(chapterNumber) across \(accounts.count) account(s)", type: "Tracker")

        Task {
            for account in accounts {
                switch account.service {
                case .anilist:
                    await sendMangaProgressToAniList(mediaId: aniListId, chapterNumber: chapterNumber, account: account)
                case .myAnimeList:
                    await sendMangaProgressToMAL(aniListId: aniListId, chapterNumber: chapterNumber, account: account)
                case .trakt:
                    break
                }
            }
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

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            if response.statusCode == 200 {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                    let errorMsg = (errors.first?["message"] as? String) ?? "Unknown error"
                    Logger.shared.log("AniList manga sync error: \(errorMsg)", type: "Tracker")
                } else {
                    Logger.shared.log("Synced manga to AniList: chapter \(chapterNumber) for mediaId \(mediaId)", type: "Tracker")
                }
            } else {
                Logger.shared.log("AniList manga sync returned status \(response.statusCode)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync manga to AniList: \(error.localizedDescription)", type: "Error")
        }
    }

    private func sendMangaProgressToMAL(aniListId: Int, chapterNumber: Int, account: TrackerAccount) async {
        guard let malId = await getMyAnimeListId(fromAniListId: aniListId, mediaType: "MANGA") else {
            Logger.shared.log("Could not find MAL manga ID for AniList manga \(aniListId)", type: "Tracker")
            return
        }

        await saveMALMangaProgress(account: account, malId: malId, chaptersRead: chapterNumber, status: "reading")
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
                case .myAnimeList:
                    if let playbackContext,
                       let anilistMediaId = playbackContext.anilistMediaId {
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

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            if response.statusCode == 200 {
                // Parse response to check for errors
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                    let errorMsg = (errors.first?["message"] as? String) ?? "Unknown error"
                    Logger.shared.log("AniList sync error: \(errorMsg)", type: "Tracker")
                } else {
                    Logger.shared.log("Synced to AniList: mediaId=\(anilistId) S\(seasonNumber)E\(episodeNumber) (\(status))", type: "Tracker")
                }
            } else {
                Logger.shared.log("AniList sync returned status \(response.statusCode)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync to AniList: \(error.localizedDescription)", type: "Error")
        }
    }

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
        await saveMALAnimeProgress(account: account, malId: malId, watchedEpisodes: episodeNumber, status: status)
    }

    private func saveMALAnimeProgress(account: TrackerAccount, malId: Int, watchedEpisodes: Int, status: String) async {
        let url = URL(string: "https://api.myanimelist.net/v2/anime/\(malId)/my_list_status")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncodedBody([
            "status": status,
            "num_watched_episodes": String(max(watchedEpisodes, 0))
        ])

        do {
            let (data, response) = try await sendTrackerRequest(request, provider: .myAnimeList)
            if (200...299).contains(response.statusCode) {
                Logger.shared.log("Synced to MAL: animeId=\(malId) episodes=\(watchedEpisodes) status=\(status)", type: "Tracker")
            } else {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                Logger.shared.log("MAL anime sync returned status \(response.statusCode): \(bodyPreview)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync to MAL: \(error.localizedDescription)", type: "Error")
        }
    }

    private func saveMALMangaProgress(account: TrackerAccount, malId: Int, chaptersRead: Int, status: String) async {
        let url = URL(string: "https://api.myanimelist.net/v2/manga/\(malId)/my_list_status")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncodedBody([
            "status": status,
            "num_chapters_read": String(max(chaptersRead, 0))
        ])

        do {
            let (data, response) = try await sendTrackerRequest(request, provider: .myAnimeList)
            if (200...299).contains(response.statusCode) {
                Logger.shared.log("Synced manga to MAL: mangaId=\(malId) chapters=\(chaptersRead) status=\(status)", type: "Tracker")
            } else {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                Logger.shared.log("MAL manga sync returned status \(response.statusCode): \(bodyPreview)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync manga to MAL: \(error.localizedDescription)", type: "Error")
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
            return decoded.data.Media?.id
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

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            guard response.statusCode == 200 else { return nil }

            struct Response: Codable {
                let data: DataWrapper
                struct DataWrapper: Codable { let Media: MediaData? }
                struct MediaData: Codable { let id: Int }
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.data.Media?.id
        } catch {
            Logger.shared.log("Failed to resolve AniList manga ID: \(error.localizedDescription)", type: "Error")
            return nil
        }
    }

    // MARK: - Sync Tools

    func previewSyncTool(_ action: TrackerSyncToolAction) {
        guard !isRunningSyncTool else { return }

        Task {
            await MainActor.run {
                self.isRunningSyncTool = true
                self.syncToolStatus = "Building preview..."
                self.syncToolPreview = nil
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

        Task {
            await MainActor.run {
                self.isRunningSyncTool = true
                self.syncToolStatus = "Running \(action.title)..."
            }

            do {
                let plan = try await cachedOrBuildSyncToolPlan(for: action)
                let result = try await performSyncTool(plan)
                await MainActor.run {
                    self.cachedSyncToolPlan = nil
                    self.syncToolPreview = result
                    self.syncToolStatus = "Finished \(action.title)"
                    self.isRunningSyncTool = false
                }
            } catch {
                await MainActor.run {
                    self.syncToolStatus = "Sync failed: \(error.localizedDescription)"
                    self.isRunningSyncTool = false
                }
            }
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
            let animeEntries = try await resolveMALAnimeEntriesToAniList(try await fetchMALAnimeProgressEntries(account: account))
            let mangaEntries = try await resolveMALMangaEntriesToAniList(try await fetchMALMangaProgressEntries(account: account))
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
            let sourceAnimeEntries = try await resolveMALAnimeEntriesToAniList(try await fetchMALAnimeProgressEntries(account: account))
            let sourceMangaEntries = try await resolveMALMangaEntriesToAniList(try await fetchMALMangaProgressEntries(account: account))
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
        let action = plan.action
        switch action {
        case .fillEclipseFromAniList:
            _ = try connectedAccount(.anilist)
            let animeResult = await fillEclipseFromRemoteAnime(plan.animeEntries, sourceName: "AniList", action: action)
            let mangaResult = await fillEclipseFromRemoteManga(plan.mangaEntries, sourceName: "AniList", action: action)
            return combineSyncPreviews(action: action, animeResult, mangaResult, note: "AniList fill completed without deleting or downgrading local progress.")

        case .fillEclipseFromMAL:
            _ = try connectedAccount(.myAnimeList)
            let animeResult = await fillEclipseFromRemoteAnime(plan.animeEntries, sourceName: "MAL", action: action)
            let mangaResult = await fillEclipseFromRemoteManga(plan.mangaEntries, sourceName: "MAL", action: action)
            return combineSyncPreviews(action: action, animeResult, mangaResult, note: "MAL fill completed without deleting or downgrading local progress.")

        case .pushEclipseToAniList:
            let account = try connectedAccount(.anilist)
            let anime = localHighestWatchedEpisodes()
            let manga = localHighestReadMangaChapters()
            for entry in anime {
                await syncToAniList(account: account, showId: entry.showId, seasonNumber: entry.seasonNumber, episodeNumber: entry.episodeNumber, progress: 1.0)
            }
            for item in manga {
                await sendMangaProgressToAniList(mediaId: item.mangaId, chapterNumber: item.chapter, account: account)
            }
            return TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: anime.count + manga.count, skipped: 0, unmapped: 0, estimatedAPICalls: 0, notes: ["Eclipse progress push completed."])

        case .pushEclipseToMAL:
            let account = try connectedAccount(.myAnimeList)
            let anime = localHighestWatchedEpisodes()
            let manga = localHighestReadMangaChapters()
            for entry in anime {
                await syncToMyAnimeList(account: account, showId: entry.showId, seasonNumber: entry.seasonNumber, episodeNumber: entry.episodeNumber, progress: 1.0)
            }
            for item in manga {
                await sendMangaProgressToMAL(aniListId: item.mangaId, chapterNumber: item.chapter, account: account)
            }
            return TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: anime.count + manga.count, skipped: 0, unmapped: 0, estimatedAPICalls: 0, notes: ["Eclipse progress push completed."])

        case .portAniListToMAL:
            _ = try connectedAccount(.anilist)
            let destination = try connectedAccount(.myAnimeList)
            var advanced = 0
            var unmapped = 0
            for entry in plan.animeEntries {
                guard let malId = entry.malId else {
                    unmapped += 1
                    continue
                }
                await saveMALAnimeProgress(
                    account: destination,
                    malId: malId,
                    watchedEpisodes: remoteWatchedEpisodes(entry),
                    status: malStatus(fromAniListStatus: entry.status)
                )
                advanced += 1
            }
            for entry in plan.mangaEntries {
                guard let malId = entry.malId else {
                    unmapped += 1
                    continue
                }
                await saveMALMangaProgress(
                    account: destination,
                    malId: malId,
                    chaptersRead: remoteReadChapters(entry),
                    status: malMangaStatus(fromAniListStatus: entry.status)
                )
                advanced += 1
            }
            return TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: advanced, skipped: unmapped, unmapped: unmapped, estimatedAPICalls: advanced, notes: ["AniList to MAL port finished. No entries were deleted."])

        case .portMALToAniList:
            _ = try connectedAccount(.myAnimeList)
            let destination = try connectedAccount(.anilist)
            var advanced = 0
            var unmapped = 0
            for entry in plan.animeEntries {
                guard let anilistId = entry.anilistId else {
                    unmapped += 1
                    continue
                }
                await saveAniListAnimeProgress(
                    account: destination,
                    anilistId: anilistId,
                    watchedEpisodes: remoteWatchedEpisodes(entry),
                    status: aniListStatus(fromMALStatus: entry.status)
                )
                advanced += 1
            }
            for entry in plan.mangaEntries {
                guard let anilistId = entry.anilistId else {
                    unmapped += 1
                    continue
                }
                await saveAniListMangaProgress(
                    account: destination,
                    anilistId: anilistId,
                    chaptersRead: remoteReadChapters(entry),
                    status: aniListStatus(fromMALStatus: entry.status)
                )
                advanced += 1
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

    private func fetchAniListAnimeProgressEntries(account: TrackerAccount) async throws -> [RemoteAnimeProgress] {
        let userId = Int(account.userId) ?? 0
        var entries: [RemoteAnimeProgress] = []
        var page = 1
        var hasNext = true

        while hasNext {
            let query = """
            query {
                Page(page: \(page), perPage: 50) {
                    pageInfo { hasNextPage }
                    mediaList(userId: \(userId), type: ANIME) {
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
            """

            struct Response: Codable {
                let data: DataWrapper
                struct DataWrapper: Codable { let Page: PageData }
                struct PageData: Codable {
                    let pageInfo: PageInfo
                    let mediaList: [MediaList]
                }
                struct PageInfo: Codable { let hasNextPage: Bool }
                struct MediaList: Codable {
                    let status: String?
                    let progress: Int?
                    let media: Media
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
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            guard response.statusCode == 200 else {
                throw NSError(domain: "AniList", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "AniList list fetch failed"])
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            entries.append(contentsOf: decoded.data.Page.mediaList.map { item in
                if let malId = item.media.idMal {
                    cacheMyAnimeListId(malId, forAniListId: item.media.id, mediaType: "ANIME")
                }
                RemoteAnimeProgress(
                    anilistId: item.media.id,
                    malId: item.media.idMal,
                    title: item.media.title.english ?? item.media.title.romaji ?? item.media.title.native ?? "Unknown",
                    status: item.status ?? "CURRENT",
                    progress: item.progress ?? 0,
                    totalEpisodes: item.media.episodes
                )
            })
            hasNext = decoded.data.Page.pageInfo.hasNextPage
            page += 1
        }

        return entries
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
                throw NSError(domain: "MAL", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "MAL list fetch failed"])
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

    private func fetchAniListMangaProgressEntries(account: TrackerAccount) async throws -> [RemoteMangaProgress] {
        let userId = Int(account.userId) ?? 0
        var entries: [RemoteMangaProgress] = []
        var page = 1
        var hasNext = true

        while hasNext {
            let query = """
            query {
                Page(page: \(page), perPage: 50) {
                    pageInfo { hasNextPage }
                    mediaList(userId: \(userId), type: MANGA) {
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
            """

            struct Response: Codable {
                let data: DataWrapper
                struct DataWrapper: Codable { let Page: PageData }
                struct PageData: Codable {
                    let pageInfo: PageInfo
                    let mediaList: [MediaList]
                }
                struct PageInfo: Codable { let hasNextPage: Bool }
                struct MediaList: Codable {
                    let status: String?
                    let progress: Int?
                    let media: Media
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
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

            let (data, response) = try await sendTrackerRequest(request, provider: .anilist)
            guard response.statusCode == 200 else {
                throw NSError(domain: "AniList", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "AniList manga list fetch failed"])
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            entries.append(contentsOf: decoded.data.Page.mediaList.map { item in
                if let malId = item.media.idMal {
                    cacheMyAnimeListId(malId, forAniListId: item.media.id, mediaType: "MANGA")
                }
                RemoteMangaProgress(
                    anilistId: item.media.id,
                    malId: item.media.idMal,
                    title: item.media.title.english ?? item.media.title.romaji ?? item.media.title.native ?? "Unknown",
                    status: item.status ?? "CURRENT",
                    progress: item.progress ?? 0,
                    totalChapters: item.media.chapters
                )
            })
            hasNext = decoded.data.Page.pageInfo.hasNextPage
            page += 1
        }

        return entries
    }

    private func fetchMALMangaProgressEntries(account: TrackerAccount) async throws -> [RemoteMangaProgress] {
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
                throw NSError(domain: "MAL", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "MAL manga list fetch failed"])
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
    }

    private func resolveMALMangaEntriesToAniList(_ entries: [RemoteMangaProgress]) async -> [RemoteMangaProgress] {
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
    }

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
        let cache = mediaType == "MANGA" ? malToAniListMangaIdCache : malToAniListAnimeIdCache
        return malIds.reduce(into: [Int: Int]()) { result, malId in
            if let anilistId = cache[malId] {
                result[malId] = anilistId
            }
        }
    }

    private func cacheAniListId(_ anilistId: Int, forMALId malId: Int, mediaType: String) {
        if mediaType == "MANGA" {
            malToAniListMangaIdCache[malId] = anilistId
            aniListToMALMangaIdCache[anilistId] = malId
        } else {
            malToAniListAnimeIdCache[malId] = anilistId
            aniListToMALAnimeIdCache[anilistId] = malId
        }
    }

    private func cachedMyAnimeListId(fromAniListId aniListId: Int, mediaType: String) -> Int? {
        if mediaType == "MANGA" {
            return aniListToMALMangaIdCache[aniListId]
        }
        return aniListToMALAnimeIdCache[aniListId]
    }

    private func cacheMyAnimeListId(_ malId: Int, forAniListId aniListId: Int, mediaType: String) {
        if mediaType == "MANGA" {
            aniListToMALMangaIdCache[aniListId] = malId
            malToAniListMangaIdCache[malId] = aniListId
        } else {
            aniListToMALAnimeIdCache[aniListId] = malId
            malToAniListAnimeIdCache[malId] = aniListId
        }
    }

    private func chunked<T>(_ values: [T], size: Int) -> [[T]] {
        guard size > 0, !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: size).map { start in
            Array(values[start..<min(start + size, values.count)])
        }
    }

    private func fillEclipseFromRemoteAnime(_ entries: [RemoteAnimeProgress], sourceName: String, action: TrackerSyncToolAction) async -> TrackerSyncPreview {
        let anilistIds = entries.compactMap { $0.anilistId }
        let tmdbMap = await AniListService.shared.mapAniListAnimeIdsToTMDBForImport(anilistIds, tmdbService: TMDBService.shared)

        let counts = await MainActor.run { () -> (added: Int, advanced: Int, unmapped: Int) in
            let library = LibraryManager.shared
            var added = 0
            var advanced = 0
            var unmapped = 0

            for entry in entries {
                guard let anilistId = entry.anilistId,
                      let tmdb = tmdbMap[anilistId] else {
                    unmapped += 1
                    continue
                }

                let collectionName = localCollectionName(forRemoteStatus: entry.status, sourceName: sourceName)
                let collection: LibraryCollection
                if let existing = library.collections.first(where: { $0.name == collectionName }) {
                    collection = existing
                } else {
                    library.createCollection(name: collectionName, description: "Imported from \(sourceName)")
                    collection = library.collections.first(where: { $0.name == collectionName })!
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

    private func fillEclipseFromRemoteManga(_ entries: [RemoteMangaProgress], sourceName: String, action: TrackerSyncToolAction) async -> TrackerSyncPreview {
        let counts = await MainActor.run { () -> (advanced: Int, unmapped: Int) in
            var advanced = 0
            var unmapped = 0

            for entry in entries {
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
    }

    private func localHighestWatchedEpisodes() -> [EpisodeProgressEntry] {
        let eligible = ProgressManager.shared.getProgressData().episodeProgress
            .filter { $0.isWatched || $0.progress >= 0.85 }

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

    private func localHighestReadMangaChapters() -> [(mangaId: Int, chapter: Int)] {
        MangaReadingProgressManager.shared.progressMap.compactMap { element in
            let mangaId = element.key
            let progress = element.value
            let highest = progress.readChapterNumbers.compactMap { numericChapter(from: $0) }.max()
            return highest.map { (mangaId: mangaId, chapter: $0) }
        }
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

    private func remoteWatchedEpisodes(_ entry: RemoteAnimeProgress) -> Int {
        if entry.status.uppercased() == "COMPLETED" || entry.status.lowercased() == "completed" {
            return max(entry.progress, entry.totalEpisodes ?? 0)
        }
        return max(entry.progress, 0)
    }

    private func remoteReadChapters(_ entry: RemoteMangaProgress) -> Int {
        if entry.status.uppercased() == "COMPLETED" || entry.status.lowercased() == "completed" {
            return max(entry.progress, entry.totalChapters ?? 0)
        }
        return max(entry.progress, 0)
    }

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
                Logger.shared.log("AniList manga sync error: \(errors.first?["message"] as? String ?? "Unknown error")", type: "Tracker")
            } else if response.statusCode == 200 {
                Logger.shared.log("Synced AniList manga \(anilistId): progress=\(chaptersRead) status=\(status)", type: "Tracker")
            } else {
                Logger.shared.log("AniList manga sync returned status \(response.statusCode)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync AniList manga \(anilistId): \(error.localizedDescription)", type: "Error")
        }
    }

    func disconnectTracker(_ service: TrackerService) {
        trackerState.disconnectAccount(for: service)
        saveTrackerState()
    }

    // MARK: - Tracker Library Import

    /// Import the user's tracker anime/manga progress into local Eclipse collections and reader progress.
    @Published var isImportingAniList = false
    @Published var aniListImportError: String?
    @Published var aniListImportProgress: String?
    @Published var isImportingMAL = false
    @Published var malImportError: String?
    @Published var malImportProgress: String?

    func importAniListToLibrary() {
        guard let account = trackerState.getAccount(for: .anilist), account.isConnected else {
            aniListImportError = "No connected AniList account"
            return
        }

        guard !isImportingAniList else { return }

        Task { @MainActor in
            isImportingAniList = true
            aniListImportError = nil
            aniListImportProgress = "Fetching your AniList library..."
        }

        Task {
            setBackupRestoreSyncSuppressed(true)
            defer { setBackupRestoreSyncSuppressed(false) }

            do {
                let animeEntries = try await fetchAniListAnimeProgressEntries(account: account)
                let mangaEntries = try await fetchAniListMangaProgressEntries(account: account)

                await MainActor.run {
                    aniListImportProgress = "Adding items to Eclipse..."
                }

                let animeResult = await fillEclipseFromRemoteAnime(animeEntries, sourceName: "AniList", action: .fillEclipseFromAniList)
                let mangaResult = await fillEclipseFromRemoteManga(mangaEntries, sourceName: "AniList", action: .fillEclipseFromAniList)
                let imported = animeResult.itemsToAdd + animeResult.itemsToAdvance + mangaResult.itemsToAdvance

                await MainActor.run {
                    isImportingAniList = false
                    aniListImportProgress = nil
                    aniListImportError = nil
                    Logger.shared.log("AniList import completed: \(imported) local changes from \(animeEntries.count) anime and \(mangaEntries.count) manga entries", type: "Tracker")
                }
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
        guard let account = trackerState.getAccount(for: .myAnimeList), account.isConnected else {
            malImportError = "No connected MAL account"
            return
        }

        guard !isImportingMAL else { return }

        Task { @MainActor in
            isImportingMAL = true
            malImportError = nil
            malImportProgress = "Fetching your MAL library..."
        }

        Task {
            setBackupRestoreSyncSuppressed(true)
            defer { setBackupRestoreSyncSuppressed(false) }

            do {
                let animeEntries = await resolveMALAnimeEntriesToAniList(try await fetchMALAnimeProgressEntries(account: account))
                let mangaEntries = await resolveMALMangaEntriesToAniList(try await fetchMALMangaProgressEntries(account: account))

                await MainActor.run {
                    malImportProgress = "Adding items to Eclipse..."
                }

                let animeResult = await fillEclipseFromRemoteAnime(animeEntries, sourceName: "MAL", action: .fillEclipseFromMAL)
                let mangaResult = await fillEclipseFromRemoteManga(mangaEntries, sourceName: "MAL", action: .fillEclipseFromMAL)
                let imported = animeResult.itemsToAdd + animeResult.itemsToAdvance + mangaResult.itemsToAdvance

                await MainActor.run {
                    isImportingMAL = false
                    malImportProgress = nil
                    malImportError = nil
                    Logger.shared.log("MAL import completed: \(imported) local changes from \(animeEntries.count) anime and \(mangaEntries.count) manga entries", type: "Tracker")
                }
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
