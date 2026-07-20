import AppKit
import AuthenticationServices
import Foundation
import Security

enum MacTrackerService: String, Codable, CaseIterable, Identifiable {
    case anilist
    case myAnimeList
    case trakt

    var id: String { rawValue }
    var name: String {
        switch self {
        case .anilist: "AniList"
        case .myAnimeList: "MyAnimeList"
        case .trakt: "Trakt"
        }
    }
}

struct MacTrackerAccount: Codable, Identifiable {
    var id: MacTrackerService { service }
    let service: MacTrackerService
    let username: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    let userId: String
    var isConnected = true
    var credentialID: String? = nil
}

@MainActor
final class MacTrackerStore: NSObject, ObservableObject {
    static let shared = MacTrackerStore()

    @Published private(set) var accounts: [MacTrackerAccount] = []
    @Published private(set) var isAuthenticating = false
    @Published private(set) var lastActivity: String?
    @Published var errorMessage: String?
    @Published private(set) var importService: MacTrackerService?
    @Published private(set) var importMessage: String?
    @Published private var reconnectRequiredServices: Set<MacTrackerService> = []

    private var session: ASWebAuthenticationSession?
    private var malVerifier: String?
    private let stateURL: URL
    private var lastScrobbleAt: [String: Date] = [:]
    private var scrobblesInFlight: Set<String> = []
    private var pendingForcedScrobbles: [String: MacPlaybackProgress] = [:]
    private var traktRefreshTask: (key: String, task: Task<MacTrackerAccount, Error>)?
    private var malRefreshTask: (key: String, task: Task<MacTrackerAccount, Error>)?
    private var importTask: Task<Void, Never>?
    private var importGeneration = UUID()
    private var animeSyncsInFlight: Set<String> = []
    private var completedAnimeSyncSignatures: Set<String> = []
    private var mangaSyncsInFlight: Set<String> = []
    private var completedMangaSyncSignatures: Set<String> = []
    private var animeMappings: [String: AnimeMapping] = [:]
    private var mangaMappings: [String: MangaMapping] = [:]
    private var persistedAccounts: [MacTrackerAccount] = []
    private var pendingCredentialDeletes: [CredentialReference] = []

    private override init() {
        stateURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackerState.json")
        super.init()
        loadMappingCaches()
        load()
    }

    func account(for service: MacTrackerService) -> MacTrackerAccount? {
        accounts.first { $0.service == service }
    }

    func connectionDetail(for service: MacTrackerService) -> String {
        guard let account = account(for: service) else { return "Not connected" }
        if needsReconnect(service) {
            return "\(account.username) · Reconnect required"
        }
        return account.username
    }

    func needsReconnect(_ service: MacTrackerService) -> Bool {
        if reconnectRequiredServices.contains(service) { return true }
        guard let account = account(for: service),
              let expiry = account.expiresAt, expiry <= Date() else { return false }
        return service == .anilist || account.refreshToken?.isEmpty != false
    }

    func cancelImport() {
        let hadActiveImport = importService != nil
        importGeneration = UUID()
        importTask?.cancel()
        importTask = nil
        importService = nil
        if hadActiveImport {
            importMessage = "Import cancelled. Anything already added or advanced was kept."
        }
    }

    func connect(_ service: MacTrackerService) {
        guard !isAuthenticating else { return }
        errorMessage = nil
        do {
            let request = try authorizationRequest(for: service)
            isAuthenticating = true
            let auth = ASWebAuthenticationSession(
                url: request.url,
                callbackURLScheme: request.callbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.errorMessage = error.localizedDescription
                        self.isAuthenticating = false
                        self.session = nil
                        self.malVerifier = nil
                        return
                    }
                    guard let callbackURL,
                          self.callback(callbackURL, matches: request.callbackURL),
                          let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "code" })?.value else {
                        self.errorMessage = "The tracker returned an invalid callback."
                        self.isAuthenticating = false
                        self.session = nil
                        self.malVerifier = nil
                        return
                    }
                    if let expectedState = request.state {
                        let received = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "state" })?.value
                        guard received == expectedState else {
                            self.errorMessage = "The tracker returned an invalid security state."
                            self.isAuthenticating = false
                            self.session = nil
                            self.malVerifier = nil
                            return
                        }
                    }
                    await self.completeConnection(service, code: code)
                }
            }
            auth.presentationContextProvider = self
            auth.prefersEphemeralWebBrowserSession = true
            guard auth.start() else {
                isAuthenticating = false
                errorMessage = "The sign-in window could not be opened."
                malVerifier = nil
                return
            }
            session = auth
        } catch {
            isAuthenticating = false
            errorMessage = error.localizedDescription
        }
    }

    func disconnect(_ service: MacTrackerService) {
        if importService == service { cancelImport() }
        let removedMetadata = persistedAccounts.filter { $0.service == service }
        guard !removedMetadata.isEmpty else { return }
        let candidateMetadata = persistedAccounts.filter { $0.service != service }
        let candidateDeletes = uniqueReferences(
            pendingCredentialDeletes + removedMetadata.map(CredentialReference.init(account:))
        )
        guard persist(candidateMetadata, pendingDeletes: candidateDeletes) else {
            errorMessage = "The tracker account metadata could not be saved. Nothing was changed."
            return
        }
        if service == .trakt {
            traktRefreshTask?.task.cancel()
            traktRefreshTask = nil
            pendingForcedScrobbles.removeAll()
            lastScrobbleAt.removeAll()
            lastActivity = nil
        } else if service == .myAnimeList {
            malRefreshTask?.task.cancel()
            malRefreshTask = nil
        }
        persistedAccounts = candidateMetadata.map(redacted)
        pendingCredentialDeletes = candidateDeletes
        accounts.removeAll { $0.service == service }
        reconnectRequiredServices.remove(service)
        let cleaned = cleanupCredentialTombstones()
        errorMessage = cleaned
            ? nil
            : "The tracker was disconnected locally, but old Keychain credentials are still queued for secure cleanup."
    }

    func scrobble(_ progress: MacPlaybackProgress, force: Bool = false) async {
        if trackerSyncEnabled {
            await syncAnimePlayback(progress, force: force)
        }
        await scrobbleTrakt(progress, force: force)
    }

    private func scrobbleTrakt(_ progress: MacPlaybackProgress, force: Bool) async {
        guard UserDefaults.standard.object(forKey: "macLiveTraktScrobbling") as? Bool ?? true,
              var account = account(for: .trakt) else { return }
        if scrobblesInFlight.contains(progress.id) {
            if force { pendingForcedScrobbles[progress.id] = progress }
            return
        }
        let dispatchedAt = Date()
        if !force, dispatchedAt.timeIntervalSince(lastScrobbleAt[progress.id] ?? .distantPast) < 30 { return }
        scrobblesInFlight.insert(progress.id)
        lastScrobbleAt[progress.id] = dispatchedAt
        defer {
            scrobblesInFlight.remove(progress.id)
            if let pending = pendingForcedScrobbles.removeValue(forKey: progress.id) {
                Task { @MainActor [weak self] in await self?.scrobble(pending, force: true) }
            }
        }
        do {
            account = try await refreshedTraktAccountIfNeeded(account)
            guard accountMatchesCurrentGeneration(account) else { return }
            let action = progress.isWatched ? "stop" : (force ? "pause" : "start")
            var media: [String: Any]
            if progress.identity.isEpisode {
                media = [
                    "episode": ["season": progress.identity.season ?? 1, "number": progress.identity.episode ?? 1],
                    "show": ["ids": ["tmdb": progress.identity.item.id]]
                ]
            } else {
                media = ["movie": ["ids": ["tmdb": progress.identity.item.id]]]
            }
            media["progress"] = progress.isWatched ? 100 : progress.fraction * 100
            media["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
            media["app_date"] = "2026-07-15"
            var request = URLRequest(url: URL(string: "https://api.trakt.tv/scrobble/\(action)")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(try credential("TraktClientID"), forHTTPHeaderField: "trakt-api-key")
            request.setValue("2", forHTTPHeaderField: "trakt-api-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: media)
            let (_, http) = try await trackerData(for: request, service: .trakt)
            if http.statusCode == 401 || http.statusCode == 403 {
                reconnectRequiredServices.insert(.trakt)
                throw TrackerError.reconnectRequired(.trakt)
            }
            guard 200..<300 ~= http.statusCode else { throw TrackerError.http(http.statusCode) }
            guard accountMatchesCurrentGeneration(account) else { return }
            lastScrobbleAt[progress.id] = Date()
            lastActivity = "Trakt updated \(progress.identity.displayTitle)"
            if pendingCredentialDeletes.isEmpty { errorMessage = nil }
        } catch {
            if error is CancellationError { return }
            if let trackerError = error as? TrackerError, case .accountChanged = trackerError { return }
            if let trackerError = error as? TrackerError,
               case .reconnectRequired(let requiredService) = trackerError {
                reconnectRequiredServices.insert(requiredService)
            }
            guard accountMatchesCurrentGeneration(account) else { return }
            errorMessage = "Trakt sync failed: \(error.localizedDescription)"
        }
    }

    private func refreshedTraktAccountIfNeeded(_ account: MacTrackerAccount) async throws -> MacTrackerAccount {
        guard let expiry = account.expiresAt, expiry.timeIntervalSinceNow < 300 else { return account }
        guard let refreshToken = account.refreshToken, !refreshToken.isEmpty else {
            reconnectRequiredServices.insert(.trakt)
            throw TrackerError.reconnectRequired(.trakt)
        }
        let key = credentialGenerationKey(account)
        if let active = traktRefreshTask, active.key == key {
            return try await active.task.value
        }
        let task = Task { @MainActor [weak self] () throws -> MacTrackerAccount in
            guard let self else { throw CancellationError() }
            return try await self.performTraktRefresh(account, refreshToken: refreshToken)
        }
        traktRefreshTask = (key, task)
        defer {
            if traktRefreshTask?.key == key { traktRefreshTask = nil }
        }
        return try await task.value
    }

    private func performTraktRefresh(_ account: MacTrackerAccount, refreshToken: String) async throws -> MacTrackerAccount {
        let clientID = try credential("TraktClientID")
        let secret = try credential("TraktClientSecret")
        let redirect = configured("TraktRedirectUri", fallback: "luna://trakt-callback")
        let token: TraktToken
        do {
            token = try await jsonRequest(
                "https://api.trakt.tv/oauth/token", method: "POST",
                json: ["refresh_token": refreshToken, "client_id": clientID, "client_secret": secret, "redirect_uri": redirect, "grant_type": "refresh_token"]
            )
        } catch let error as TrackerError {
            switch error {
            case .http(400), .http(401), .http(403):
                reconnectRequiredServices.insert(.trakt)
                throw TrackerError.reconnectRequired(.trakt)
            default:
                throw error
            }
        }
        try Task.checkCancellation()
        guard accountMatchesCurrentGeneration(account) else { throw TrackerError.accountChanged }
        var refreshed = account
        refreshed.accessToken = token.accessToken
        refreshed.refreshToken = token.refreshToken
        refreshed.expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        refreshed.credentialID = Self.credentialID()
        guard CredentialVault.store(refreshed) else { throw TrackerError.keychain }
        let stagedReference = CredentialReference(account: refreshed)
        let previousMetadata = persistedAccounts.filter { $0.service == .trakt }
        var candidateMetadata = persistedAccounts.filter { $0.service != .trakt }
        candidateMetadata.append(redacted(refreshed))
        let candidateDeletes = uniqueReferences(
            pendingCredentialDeletes + previousMetadata.map(CredentialReference.init(account:))
        )
        guard persist(candidateMetadata, pendingDeletes: candidateDeletes) else {
            let stagedCleaned = CredentialVault.remove(stagedReference)
            throw stagedCleaned ? TrackerError.persistence : TrackerError.persistenceAndCleanup
        }
        persistedAccounts = candidateMetadata.map(redacted)
        pendingCredentialDeletes = candidateDeletes
        accounts.removeAll { $0.service == .trakt }
        accounts.append(refreshed)
        if !cleanupCredentialTombstones() {
            errorMessage = "Trakt refreshed, but old Keychain credentials are still queued for secure cleanup."
        }
        return refreshed
    }

    private func refreshedMALAccountIfNeeded(
        _ account: MacTrackerAccount,
        force: Bool = false
    ) async throws -> MacTrackerAccount {
        guard force || (account.expiresAt?.timeIntervalSinceNow ?? .greatestFiniteMagnitude) < 300 else {
            return account
        }
        guard let refreshToken = account.refreshToken, !refreshToken.isEmpty else {
            reconnectRequiredServices.insert(.myAnimeList)
            throw TrackerError.reconnectRequired(.myAnimeList)
        }
        let key = credentialGenerationKey(account)
        if let active = malRefreshTask, active.key == key {
            return try await active.task.value
        }
        let task = Task { @MainActor [weak self] () throws -> MacTrackerAccount in
            guard let self else { throw CancellationError() }
            return try await self.performMALRefresh(account, refreshToken: refreshToken)
        }
        malRefreshTask = (key, task)
        defer {
            if malRefreshTask?.key == key { malRefreshTask = nil }
        }
        return try await task.value
    }

    private func performMALRefresh(_ account: MacTrackerAccount, refreshToken: String) async throws -> MacTrackerAccount {
        let clientID = try credential("MALClientID")
        var fields = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        let secret = configured("MALClientSecret", fallback: "")
        if !secret.isEmpty { fields["client_secret"] = secret }
        let token: MALToken
        do {
            token = try await formRequest("https://myanimelist.net/v1/oauth2/token", fields: fields)
        } catch let error as TrackerError {
            switch error {
            case .http(400), .http(401), .http(403):
                reconnectRequiredServices.insert(.myAnimeList)
                throw TrackerError.reconnectRequired(.myAnimeList)
            default:
                throw error
            }
        }
        try Task.checkCancellation()
        guard accountMatchesCurrentGeneration(account) else { throw TrackerError.accountChanged }

        var refreshed = account
        refreshed.accessToken = token.accessToken
        refreshed.refreshToken = token.refreshToken ?? refreshToken
        refreshed.expiresAt = token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        refreshed.credentialID = Self.credentialID()
        guard CredentialVault.store(refreshed) else { throw TrackerError.keychain }

        let stagedReference = CredentialReference(account: refreshed)
        let previousMetadata = persistedAccounts.filter { $0.service == .myAnimeList }
        var candidateMetadata = persistedAccounts.filter { $0.service != .myAnimeList }
        candidateMetadata.append(redacted(refreshed))
        let candidateDeletes = uniqueReferences(
            pendingCredentialDeletes + previousMetadata.map(CredentialReference.init(account:))
        )
        guard persist(candidateMetadata, pendingDeletes: candidateDeletes) else {
            let stagedCleaned = CredentialVault.remove(stagedReference)
            throw stagedCleaned ? TrackerError.persistence : TrackerError.persistenceAndCleanup
        }
        persistedAccounts = candidateMetadata.map(redacted)
        pendingCredentialDeletes = candidateDeletes
        accounts.removeAll { $0.service == .myAnimeList }
        accounts.append(refreshed)
        if !cleanupCredentialTombstones() {
            errorMessage = "MyAnimeList refreshed, but old Keychain credentials are still queued for secure cleanup."
        }
        return refreshed
    }

    private func completeConnection(_ service: MacTrackerService, code: String) async {
        do {
            var account: MacTrackerAccount
            switch service {
            case .anilist: account = try await connectAniList(code: code)
            case .myAnimeList: account = try await connectMAL(code: code)
            case .trakt: account = try await connectTrakt(code: code)
            }
            if service == .trakt {
                traktRefreshTask?.task.cancel()
                traktRefreshTask = nil
            } else if service == .myAnimeList {
                malRefreshTask?.task.cancel()
                malRefreshTask = nil
            }
            account.credentialID = Self.credentialID()
            let previousMetadata = persistedAccounts.filter { $0.service == service }
            var candidateMetadata = persistedAccounts.filter { $0.service != service }
            candidateMetadata.append(redacted(account))
            guard CredentialVault.store(account) else { throw TrackerError.keychain }
            let stagedReference = CredentialReference(account: account)
            let candidateDeletes = uniqueReferences(
                pendingCredentialDeletes + previousMetadata.map(CredentialReference.init(account:))
            )
            guard persist(candidateMetadata, pendingDeletes: candidateDeletes) else {
                let stagedCleaned = CredentialVault.remove(stagedReference)
                throw stagedCleaned ? TrackerError.persistence : TrackerError.persistenceAndCleanup
            }
            persistedAccounts = candidateMetadata.map(redacted)
            pendingCredentialDeletes = candidateDeletes
            accounts.removeAll { $0.service == service }
            accounts.append(account)
            reconnectRequiredServices.remove(service)
            errorMessage = cleanupCredentialTombstones()
                ? nil
                : "\(service.name) connected, but old Keychain credentials are still queued for secure cleanup."
        } catch {
            errorMessage = error.localizedDescription
        }
        isAuthenticating = false
        session = nil
        malVerifier = nil
    }

    private func authorizationRequest(for service: MacTrackerService) throws -> AuthorizationRequest {
        switch service {
        case .anilist:
            let clientID = try credential("AniListClientID")
            let redirect = configured("AniListRedirectUri", fallback: "luna://anilist-callback")
            guard let callbackURL = URL(string: redirect), let callbackScheme = callbackURL.scheme else { throw TrackerError.invalidURL }
            let state = Self.oauthState()
            return AuthorizationRequest(
                url: try url("https://anilist.co/api/v2/oauth/authorize", items: [
                    .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
                    .init(name: "response_type", value: "code"), .init(name: "state", value: state)
                ]), callbackScheme: callbackScheme, callbackURL: callbackURL, state: state
            )
        case .myAnimeList:
            let clientID = try credential("MALClientID")
            let redirect = configured("MALRedirectUri", fallback: "luna://mal-callback")
            guard let callbackURL = URL(string: redirect), let callbackScheme = callbackURL.scheme else { throw TrackerError.invalidURL }
            let verifier = String((0..<96).compactMap { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~".randomElement() })
            let state = Self.oauthState()
            malVerifier = verifier
            return AuthorizationRequest(
                url: try url("https://myanimelist.net/v1/oauth2/authorize", items: [
                    .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID),
                    .init(name: "redirect_uri", value: redirect), .init(name: "code_challenge", value: verifier),
                    .init(name: "code_challenge_method", value: "plain"), .init(name: "state", value: state)
                ]), callbackScheme: callbackScheme, callbackURL: callbackURL, state: state
            )
        case .trakt:
            let clientID = try credential("TraktClientID")
            _ = try credential("TraktClientSecret")
            let redirect = configured("TraktRedirectUri", fallback: "luna://trakt-callback")
            guard let callbackURL = URL(string: redirect), let callbackScheme = callbackURL.scheme else { throw TrackerError.invalidURL }
            let state = Self.oauthState()
            return AuthorizationRequest(
                url: try url("https://trakt.tv/oauth/authorize", items: [
                    .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
                    .init(name: "response_type", value: "code"), .init(name: "state", value: state)
                ]), callbackScheme: callbackScheme, callbackURL: callbackURL, state: state
            )
        }
    }

    private func connectAniList(code: String) async throws -> MacTrackerAccount {
        let clientID = try credential("AniListClientID")
        let secret = try credential("AniListClientSecret")
        let redirect = configured("AniListRedirectUri", fallback: "luna://anilist-callback")
        let token: AniListToken = try await jsonRequest(
            "https://anilist.co/api/v2/oauth/token", method: "POST",
            json: ["grant_type": "authorization_code", "client_id": clientID, "client_secret": secret, "redirect_uri": redirect, "code": code]
        )
        let viewer: AniListViewerResponse = try await jsonRequest(
            "https://graphql.anilist.co", method: "POST", json: ["query": "query { viewer: Viewer { id name } }"] , bearer: token.accessToken
        )
        return MacTrackerAccount(
            service: .anilist, username: viewer.data.viewer.name, accessToken: token.accessToken,
            refreshToken: nil, expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
            userId: String(viewer.data.viewer.id)
        )
    }

    private func connectMAL(code: String) async throws -> MacTrackerAccount {
        guard let verifier = malVerifier else { throw TrackerError.invalidCallback }
        let clientID = try credential("MALClientID")
        let redirect = configured("MALRedirectUri", fallback: "luna://mal-callback")
        var fields = [
            "client_id": clientID, "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirect
        ]
        let secret = configured("MALClientSecret", fallback: "")
        if !secret.isEmpty { fields["client_secret"] = secret }
        let token: MALToken = try await formRequest("https://myanimelist.net/v1/oauth2/token", fields: fields)
        let user: MALUser = try await getRequest("https://api.myanimelist.net/v2/users/@me", bearer: token.accessToken)
        return MacTrackerAccount(
            service: .myAnimeList, username: user.name, accessToken: token.accessToken,
            refreshToken: token.refreshToken, expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            userId: String(user.id)
        )
    }

    private func connectTrakt(code: String) async throws -> MacTrackerAccount {
        let clientID = try credential("TraktClientID")
        let secret = try credential("TraktClientSecret")
        let redirect = configured("TraktRedirectUri", fallback: "luna://trakt-callback")
        let token: TraktToken = try await jsonRequest(
            "https://api.trakt.tv/oauth/token", method: "POST",
            json: ["code": code, "client_id": clientID, "client_secret": secret, "redirect_uri": redirect, "grant_type": "authorization_code"]
        )
        var request = URLRequest(url: URL(string: "https://api.trakt.tv/users/settings")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        let settings: TraktSettings = try await send(request)
        return MacTrackerAccount(
            service: .trakt, username: settings.user.username, accessToken: token.accessToken,
            refreshToken: token.refreshToken, expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
            userId: settings.user.ids.trakt.map(String.init) ?? settings.user.ids.slug
        )
    }

    func syncRating(_ rating: Double?, for item: MacMediaItem) async {
        guard trackerSyncEnabled, trackerAutoSyncRatings,
              let rating, rating.isFinite, rating > 0,
              accounts.contains(where: { $0.service == .anilist || $0.service == .myAnimeList }) else { return }
        do {
            guard let mapping = try await resolveAnimeMapping(
                for: item,
                season: item.mediaType == "tv" ? 1 : nil,
                episode: nil
            ) else { return }
            let normalized = max(0.5, min(10, (rating * 2).rounded() / 2))
            var failures: [String] = []
            var didUpdate = false
            for originalAccount in accounts where originalAccount.service != .trakt {
                guard accountMatchesCurrentGeneration(originalAccount) else { continue }
                do {
                    switch originalAccount.service {
                    case .anilist:
                        try ensureAniListAccountIsUsable(originalAccount)
                        try await saveAniListRating(account: originalAccount, mapping: mapping, rating: normalized)
                    case .myAnimeList:
                        guard mapping.malID != nil else { continue }
                        let refreshed = try await refreshedMALAccountIfNeeded(originalAccount)
                        try await saveMALRating(account: refreshed, mapping: mapping, rating: normalized)
                    case .trakt:
                        continue
                    }
                    didUpdate = true
                } catch is CancellationError {
                    return
                } catch {
                    if let message = trackerSyncFailureMessage(error, service: originalAccount.service) {
                        failures.append(message)
                    }
                }
            }
            if didUpdate { lastActivity = "Anime tracker ratings updated for \(item.title)" }
            if !failures.isEmpty {
                errorMessage = "Anime rating sync was only partly successful. \(failures.joined(separator: " "))"
            } else if pendingCredentialDeletes.isEmpty {
                errorMessage = nil
            }
        } catch {
            if error is CancellationError { return }
            errorMessage = "Anime rating sync failed: \(error.localizedDescription)"
        }
    }

    func syncMangaProgress(title: String, chapterNumber: Double, totalChapters: Int?) async {
        guard trackerSyncEnabled, trackerReaderSyncEnabled,
              chapterNumber.isFinite, chapterNumber > 0,
              accounts.contains(where: { $0.service == .anilist || $0.service == .myAnimeList }) else { return }
        let chapter = Int(floor(chapterNumber))
        guard chapter > 0 else { return }
        let baseKey = "\(Self.normalizedTitle(title))|\(chapter)"
        guard mangaSyncsInFlight.insert(baseKey).inserted else { return }
        defer { mangaSyncsInFlight.remove(baseKey) }

        do {
            guard let mapping = try await resolveMangaMapping(title: title) else { return }
            var failures: [String] = []
            var didUpdate = false
            for originalAccount in accounts where originalAccount.service != .trakt {
                let signature = "\(credentialGenerationKey(originalAccount))|\(mapping.anilistID)|\(chapter)"
                guard !completedMangaSyncSignatures.contains(signature),
                      accountMatchesCurrentGeneration(originalAccount) else { continue }
                do {
                    switch originalAccount.service {
                    case .anilist:
                        try ensureAniListAccountIsUsable(originalAccount)
                        try await saveAniListMangaProgress(
                            account: originalAccount,
                            mapping: mapping,
                            chapter: chapter,
                            totalChapters: totalChapters
                        )
                    case .myAnimeList:
                        guard mapping.malID != nil else { continue }
                        let refreshed = try await refreshedMALAccountIfNeeded(originalAccount)
                        try await saveMALMangaProgress(
                            account: refreshed,
                            mapping: mapping,
                            chapter: chapter,
                            totalChapters: totalChapters
                        )
                    case .trakt:
                        continue
                    }
                    completedMangaSyncSignatures.insert(signature)
                    didUpdate = true
                } catch is CancellationError {
                    return
                } catch {
                    if let message = trackerSyncFailureMessage(error, service: originalAccount.service) {
                        failures.append(message)
                    }
                }
            }
            trimCompletedSignatures()
            if didUpdate { lastActivity = "Anime tracker reading progress updated for \(title)" }
            if !failures.isEmpty {
                errorMessage = "Manga tracker sync was only partly successful. \(failures.joined(separator: " "))"
            } else if pendingCredentialDeletes.isEmpty {
                errorMessage = nil
            }
        } catch {
            if error is CancellationError { return }
            errorMessage = "Manga tracker sync failed: \(error.localizedDescription)"
        }
    }

    func importLibrary(from service: MacTrackerService) {
        guard service == .anilist || service == .myAnimeList,
              importService == nil,
              let account = account(for: service) else { return }
        importService = service
        importMessage = "Fetching your \(service.name) anime library…"
        errorMessage = nil
        let generation = UUID()
        importGeneration = generation
        importTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runLibraryImport(from: service, account: account, generation: generation)
        }
    }

    private func runLibraryImport(
        from service: MacTrackerService,
        account originalAccount: MacTrackerAccount,
        generation: UUID
    ) async {
        var added = 0
        var advanced = 0
        var unmatched = 0
        do {
            let account: MacTrackerAccount
            switch service {
            case .anilist:
                try ensureAniListAccountIsUsable(originalAccount)
                account = originalAccount
            case .myAnimeList:
                account = try await refreshedMALAccountIfNeeded(originalAccount)
            case .trakt:
                return
            }
            guard accountMatchesCurrentGeneration(account) else { throw TrackerError.accountChanged }
            var entries = service == .anilist
                ? try await fetchAniListAnimeLibrary(account: account)
                : try await fetchMALAnimeLibrary(account: account)
            if service == .myAnimeList {
                importMessage = "Resolving MyAnimeList IDs through AniList…"
                let idMap = try await resolveAniListIDs(
                    malIDs: entries.compactMap(\.malID)
                )
                entries = entries.map { entry in
                    RemoteAnimeEntry(
                        anilistID: entry.malID.flatMap { idMap[$0] },
                        malID: entry.malID,
                        title: entry.title,
                        status: entry.status,
                        progress: entry.progress,
                        totalEpisodes: entry.totalEpisodes,
                        format: entry.format
                    )
                }
            }
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                guard importGeneration == generation else { throw CancellationError() }
                guard accountMatchesCurrentGeneration(account) else { throw TrackerError.accountChanged }
                if index == 0 || index.isMultiple(of: 5) {
                    importMessage = "Matching \(index + 1) of \(entries.count) \(service.name) entries…"
                }
                do {
                    guard let mapping = try await resolveImportMapping(entry),
                          let item = try await fetchTMDBItem(for: mapping) else {
                        unmatched += 1
                        continue
                    }
                    if MacCatalogStore.shared.addToLibraryIfNeeded(item) { added += 1 }
                    let reportedTotal = entry.totalEpisodes ?? 0
                    let safeRemoteTotal = reportedTotal > 0 ? min(reportedTotal, 5_000) : 5_000
                    let watched = max(0, min(entry.progress, safeRemoteTotal))
                    let safeOffset = max(0, mapping.episodeOffset)
                    let translatedWatched = min(5_000, watched + safeOffset)
                    let firstTranslatedEpisode = min(5_000, safeOffset + 1)
                    let hasSafeProgressTarget = item.mediaType == "movie" || (mapping.tmdbSeason ?? 0) > 0
                    if watched > 0, hasSafeProgressTarget {
                        advanced += MacMediaStateStore.shared.importWatchedProgress(
                            item: item,
                            season: item.mediaType == "tv" ? (mapping.tmdbSeason ?? 1) : nil,
                            fromEpisode: item.mediaType == "movie" ? 1 : firstTranslatedEpisode,
                            throughEpisode: item.mediaType == "movie" ? 1 : translatedWatched
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as TrackerError {
                    if case .http(404) = error {
                        unmatched += 1
                    } else {
                        throw error
                    }
                } catch {
                    throw error
                }
            }
            importMessage = "Imported \(added) new title\(added == 1 ? "" : "s") and advanced \(advanced) watched item\(advanced == 1 ? "" : "s"). \(unmatched) could not be matched safely."
            lastActivity = "\(service.name) library import finished"
            if pendingCredentialDeletes.isEmpty { errorMessage = nil }
        } catch is CancellationError {
            if importGeneration == generation {
                importMessage = "Import cancelled after adding \(added) title\(added == 1 ? "" : "s") and advancing \(advanced) watched item\(advanced == 1 ? "" : "s"). Those changes were kept."
            }
        } catch {
            if importGeneration == generation {
                if let trackerError = error as? TrackerError,
                   case .reconnectRequired(let requiredService) = trackerError {
                    reconnectRequiredServices.insert(requiredService)
                }
                importMessage = "\(service.name) import stopped. Anything already added or advanced was kept."
                errorMessage = error.localizedDescription
            }
        }
        guard importGeneration == generation else { return }
        if importService == service {
            importTask = nil
            importService = nil
        }
    }

    private func syncAnimePlayback(_ progress: MacPlaybackProgress, force: Bool) async {
        guard progress.isWatched || progress.fraction >= 0.85,
              progress.identity.item.id > 0,
              accounts.contains(where: { $0.service == .anilist || $0.service == .myAnimeList }) else { return }
        if progress.identity.isEpisode, progress.identity.season == 0 { return }
        let flightKey = progress.identity.progressID
        guard animeSyncsInFlight.insert(flightKey).inserted else { return }
        defer { animeSyncsInFlight.remove(flightKey) }

        do {
            let item = progress.identity.item
            let localEpisode = progress.identity.isEpisode ? (progress.identity.episode ?? 1) : 1
            guard (1...5_000).contains(localEpisode) else { return }
            guard let mapping = try await resolveAnimeMapping(
                for: item,
                season: progress.identity.season,
                episode: progress.identity.isEpisode ? localEpisode : nil
            ) else { return }
            let providerEpisode = max(1, localEpisode + mapping.episodeOffset)
            var failures: [String] = []
            var didUpdate = false
            for originalAccount in accounts where originalAccount.service != .trakt {
                let signature = "\(credentialGenerationKey(originalAccount))|\(mapping.anilistID)|\(providerEpisode)"
                guard !completedAnimeSyncSignatures.contains(signature),
                      accountMatchesCurrentGeneration(originalAccount) else { continue }
                do {
                    switch originalAccount.service {
                    case .anilist:
                        try ensureAniListAccountIsUsable(originalAccount)
                        try await saveAniListProgress(
                            account: originalAccount,
                            mapping: mapping,
                            watchedEpisodes: providerEpisode
                        )
                    case .myAnimeList:
                        guard mapping.malID != nil else { continue }
                        let refreshed = try await refreshedMALAccountIfNeeded(originalAccount)
                        try await saveMALAnimeProgress(
                            account: refreshed,
                            mapping: mapping,
                            watchedEpisodes: providerEpisode
                        )
                    case .trakt:
                        continue
                    }
                    completedAnimeSyncSignatures.insert(signature)
                    didUpdate = true
                } catch is CancellationError {
                    return
                } catch {
                    if let message = trackerSyncFailureMessage(error, service: originalAccount.service) {
                        failures.append(message)
                    }
                }
            }
            trimCompletedSignatures()
            if didUpdate { lastActivity = "Anime trackers updated \(progress.identity.displayTitle)" }
            if !failures.isEmpty {
                errorMessage = "Anime progress sync was only partly successful. \(failures.joined(separator: " "))"
            } else if pendingCredentialDeletes.isEmpty {
                errorMessage = nil
            }
        } catch {
            if error is CancellationError { return }
            if let trackerError = error as? TrackerError, case .accountChanged = trackerError { return }
            errorMessage = "Anime progress sync failed: \(error.localizedDescription)"
        }
        _ = force
    }

    private var trackerSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: "macTrackerSyncEnabled") as? Bool ?? true
    }

    private var trackerAutoSyncRatings: Bool {
        UserDefaults.standard.object(forKey: "macTrackerAutoSyncRatings") as? Bool ?? false
    }

    private var trackerReaderSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: "macTrackerReaderSyncEnabled") as? Bool ?? true
    }

    private func trackerSyncFailureMessage(_ error: Error, service: MacTrackerService) -> String? {
        if let trackerError = error as? TrackerError {
            switch trackerError {
            case .accountChanged:
                return nil
            case .reconnectRequired(let requiredService):
                reconnectRequiredServices.insert(requiredService)
            default:
                break
            }
        }
        return "\(service.name): \(error.localizedDescription)"
    }

    private func ensureAniListAccountIsUsable(_ account: MacTrackerAccount) throws {
        if let expiry = account.expiresAt, expiry <= Date() {
            reconnectRequiredServices.insert(.anilist)
            throw TrackerError.reconnectRequired(.anilist)
        }
    }

    private func loadMappingCaches() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "macTrackerAnimeMappings.v3"),
           let decoded = try? JSONDecoder().decode([String: AnimeMapping].self, from: data) {
            animeMappings = decoded.filter { $0.value.cachedAt.timeIntervalSinceNow > -30 * 24 * 60 * 60 }
        }
        if let data = defaults.data(forKey: "macTrackerMangaMappings.v1"),
           let decoded = try? JSONDecoder().decode([String: MangaMapping].self, from: data) {
            mangaMappings = decoded.filter { $0.value.cachedAt.timeIntervalSinceNow > -30 * 24 * 60 * 60 }
        }
    }

    private func persistMappingCaches() {
        if let data = try? JSONEncoder().encode(animeMappings) {
            UserDefaults.standard.set(data, forKey: "macTrackerAnimeMappings.v3")
        }
        if let data = try? JSONEncoder().encode(mangaMappings) {
            UserDefaults.standard.set(data, forKey: "macTrackerMangaMappings.v1")
        }
    }

    private func resolveAnimeMapping(
        for item: MacMediaItem,
        season: Int?,
        episode: Int?
    ) async throws -> AnimeMapping? {
        let resolvedSeason = item.mediaType == "tv" ? (season ?? 1) : nil
        if let resolvedSeason, !(1...100).contains(resolvedSeason) { return nil }
        let key = "\(item.stableID)|s\(resolvedSeason ?? 0)|e\(episode ?? 0)"
        if let cached = animeMappings[key], cached.cachedAt.timeIntervalSinceNow > -30 * 24 * 60 * 60 {
            return cached
        }

        let descriptor = try await fetchTMDBDescriptor(item: item)
        guard descriptor.isAnime else { return nil }
        let aniMapKey = item.mediaType == "movie" ? "tmdb_movie" : "tmdb_show"
        let mappings = try await fetchAniMapMappings(value: item.id, mappingKey: aniMapKey)
        let filtered = mappings.filter { mapping in
            guard mapping.anilistID != nil else { return false }
            if item.mediaType == "movie" { return mapping.tmdbMovieID == item.id }
            guard mapping.tmdbShowID == item.id else { return false }
            let type = mapping.mediaType?.uppercased()
            return type != "MOVIE" && type != "SPECIAL" && type != "OVA"
        }
        let exact = item.mediaType == "movie"
            ? filtered
            : filtered.filter { $0.tmdbSeason == resolvedSeason }
        let fallback = item.mediaType == "tv" && resolvedSeason == 1
            ? filtered.filter { $0.tmdbSeason == nil || $0.tmdbSeason == 1 }
            : []
        let candidates = exact.isEmpty ? fallback : exact
        let uniqueIDs = Array(Set(candidates.compactMap(\.anilistID).filter { $0 > 0 }))
        if uniqueIDs.count == 1,
           let node = try await fetchAniListMedia(id: uniqueIDs[0], type: "ANIME") {
            let chosen = candidates.first { $0.anilistID == node.id }
            guard let offset = Self.safeEpisodeOffset(chosen?.episodeOffset) else { return nil }
            if episode == nil, offset > 0 { return nil }
            if let episode {
                let upperBound = node.episodes.map { offset + min(5_000, max(0, $0)) } ?? 5_000
                guard episode > offset, episode <= upperBound else { return nil }
            }
            let mapping = AnimeMapping(
                anilistID: node.id,
                malID: node.malID,
                episodeCount: node.episodes,
                tmdbSeason: resolvedSeason,
                episodeOffset: -offset,
                isMovie: item.mediaType == "movie",
                provenance: "AniMap",
                cachedAt: Date()
            )
            animeMappings[key] = mapping
            persistMappingCaches()
            return mapping
        }
        if uniqueIDs.count > 1 {
            guard let episode else { return nil }
            var segmentMatches: [(AniMapMapping, AniListMediaNode)] = []
            for id in uniqueIDs {
                guard let node = try await fetchAniListMedia(id: id, type: "ANIME") else { continue }
                for candidate in candidates where candidate.anilistID == id {
                    guard let offset = Self.safeEpisodeOffset(candidate.episodeOffset) else { continue }
                    let upperBound = node.episodes.map { offset + min(5_000, max(0, $0)) } ?? 5_000
                    if episode > offset, episode <= upperBound {
                        segmentMatches.append((candidate, node))
                    }
                }
            }
            var seenSegmentIDs: Set<Int> = []
            let distinctMatches = segmentMatches.filter { seenSegmentIDs.insert($0.1.id).inserted }
            guard distinctMatches.count == 1, let selected = distinctMatches.first else { return nil }
            guard let selectedOffset = Self.safeEpisodeOffset(selected.0.episodeOffset) else { return nil }
            let mapping = AnimeMapping(
                anilistID: selected.1.id,
                malID: selected.1.malID,
                episodeCount: selected.1.episodes,
                tmdbSeason: resolvedSeason,
                episodeOffset: -selectedOffset,
                isMovie: item.mediaType == "movie",
                provenance: "AniMap episode segment",
                cachedAt: Date()
            )
            animeMappings[key] = mapping
            persistMappingCaches()
            return mapping
        }

        let year = try await trackerYear(for: item, season: resolvedSeason, descriptor: descriptor)
        if item.mediaType == "tv", (resolvedSeason ?? 1) > 1, year == nil { return nil }
        for title in descriptor.candidateTitles {
            if let node = try await searchAniListMedia(title: title, year: year, type: "ANIME") {
                let mapping = AnimeMapping(
                    anilistID: node.id,
                    malID: node.malID,
                    episodeCount: node.episodes,
                    tmdbSeason: resolvedSeason,
                    episodeOffset: 0,
                    isMovie: item.mediaType == "movie",
                    provenance: "verified title/year",
                    cachedAt: Date()
                )
                animeMappings[key] = mapping
                persistMappingCaches()
                return mapping
            }
        }
        return nil
    }

    private func resolveMangaMapping(title: String) async throws -> MangaMapping? {
        let key = Self.normalizedTitle(title)
        guard !key.isEmpty else { return nil }
        if let cached = mangaMappings[key], cached.cachedAt.timeIntervalSinceNow > -30 * 24 * 60 * 60 {
            return cached
        }
        guard let node = try await searchAniListMedia(title: title, year: nil, type: "MANGA") else { return nil }
        let mapping = MangaMapping(
            anilistID: node.id,
            malID: node.malID,
            chapterCount: node.chapters,
            cachedAt: Date()
        )
        mangaMappings[key] = mapping
        persistMappingCaches()
        return mapping
    }

    private func fetchAniListMedia(id: Int, type: String) async throws -> AniListMediaNode? {
        let query = """
        query($id: Int!) {
            Media(id: $id, type: \(type)) {
                id idMal episodes chapters format
                title { romaji english native }
                synonyms
                startDate { year }
            }
        }
        """
        let data = try await aniListGraphQL(query: query, variables: ["id": id], account: nil)
        return try JSONDecoder().decode(AniListMediaResponse.self, from: data).data?.media
    }

    private func searchAniListMedia(title: String, year: Int?, type: String) async throws -> AniListMediaNode? {
        let query = """
        query($search: String!, $year: Int) {
            Page(page: 1, perPage: 10) {
                media(search: $search, type: \(type), seasonYear: $year, sort: SEARCH_MATCH) {
                    id idMal episodes chapters format
                    title { romaji english native }
                    synonyms
                    startDate { year }
                }
            }
        }
        """
        var variables: [String: Any] = ["search": title]
        if let year { variables["year"] = year }
        let data = try await aniListGraphQL(query: query, variables: variables, account: nil)
        let nodes = try JSONDecoder().decode(AniListSearchResponse.self, from: data).data?.page?.media ?? []
        let ranked = nodes.map { node in
            (node, Self.matchScore(query: title, candidates: node.allTitles, expectedYear: year, candidateYear: node.startDate?.year))
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 90 else { return nil }
        if ranked.count > 1, ranked[1].1 >= best.1 - 3, ranked[1].0.id != best.0.id { return nil }
        return best.0
    }

    nonisolated private static func matchScore(
        query: String,
        candidates: [String],
        expectedYear: Int?,
        candidateYear: Int?
    ) -> Int {
        let needle = normalizedTitle(query)
        guard !needle.isEmpty else { return 0 }
        var titleScore = 0
        for candidate in candidates {
            let value = normalizedTitle(candidate)
            if value == needle { titleScore = max(titleScore, 100) }
            else if value.contains(needle) || needle.contains(value) { titleScore = max(titleScore, 82) }
            else {
                let lhs = Set(needle.split(separator: " ").map(String.init))
                let rhs = Set(value.split(separator: " ").map(String.init))
                let union = lhs.union(rhs).count
                if union > 0 { titleScore = max(titleScore, Int((Double(lhs.intersection(rhs).count) / Double(union)) * 80)) }
            }
        }
        guard let expectedYear else { return titleScore }
        guard let candidateYear else { return titleScore - 15 }
        let delta = abs(expectedYear - candidateYear)
        if delta == 0 { return titleScore + 20 }
        if delta == 1 { return titleScore + 8 }
        return titleScore - min(30, delta * 5)
    }

    nonisolated private static func normalizedTitle(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
            .reduce(into: "") { result, character in
                if character == " ", result.last == " " { return }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func safeEpisodeOffset(_ value: Int?) -> Int? {
        let offset = value ?? 0
        return (0..<5_000).contains(offset) ? offset : nil
    }

    private func fetchTMDBDescriptor(item: MacMediaItem) async throws -> TMDBTrackerDescriptor {
        let kind = item.mediaType == "movie" ? "movie" : "tv"
        let data = try await tmdbData(path: "/3/\(kind)/\(item.id)")
        let value = try JSONDecoder().decode(TMDBTrackerDetail.self, from: data)
        return TMDBTrackerDescriptor(
            titles: [value.title, value.name, value.originalTitle, value.originalName, item.title].compactMap { $0 },
            genreIDs: value.genres.map(\.id),
            originalLanguage: value.originalLanguage,
            date: value.releaseDate ?? value.firstAirDate
        )
    }

    private func trackerYear(
        for item: MacMediaItem,
        season: Int?,
        descriptor: TMDBTrackerDescriptor
    ) async throws -> Int? {
        if item.mediaType == "tv", let season {
            if let data = try? await tmdbData(path: "/3/tv/\(item.id)/season/\(season)"),
               let value = try? JSONDecoder().decode(TMDBTrackerSeason.self, from: data),
               let year = value.airDate.flatMap({ Int($0.prefix(4)) }) {
                return year
            }
        }
        return descriptor.date.flatMap { Int($0.prefix(4)) }
    }

    private func tmdbData(path: String) async throws -> Data {
        let apiKey = try credential("TMDB_API_KEY")
        var components = URLComponents(string: "https://api.themoviedb.org\(path)")
        components?.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components?.url, url.scheme == "https", url.host == "api.themoviedb.org" else {
            throw TrackerError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await MacTrackerNetwork.session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw TrackerError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard http.url?.scheme?.lowercased() == "https", http.url?.host == "api.themoviedb.org" else {
            throw TrackerError.invalidURL
        }
        guard data.count <= 10_000_000 else { throw TrackerError.responseTooLarge }
        return data
    }

    private func fetchAniMapMappings(value: Int, mappingKey: String) async throws -> [AniMapMapping] {
        guard value > 0, ["tmdb_show", "tmdb_movie", "anilist"].contains(mappingKey) else {
            throw TrackerError.invalidURL
        }
        let base = URL(string: "https://animap.s0n1c.ca")!
            .appendingPathComponent("mappings")
            .appendingPathComponent(String(value))
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mapping_key", value: mappingKey)]
        guard let url = components?.url, url.scheme == "https", url.host == "animap.s0n1c.ca" else {
            throw TrackerError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await MacTrackerNetwork.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TrackerError.http(0) }
        guard http.url?.scheme?.lowercased() == "https", http.url?.host == "animap.s0n1c.ca" else {
            throw TrackerError.invalidURL
        }
        if http.statusCode == 404 { return [] }
        guard http.statusCode == 200 else { throw TrackerError.http(http.statusCode) }
        guard data.count <= 2_000_000 else { throw TrackerError.responseTooLarge }
        return try JSONDecoder().decode(AniMapMappingList.self, from: data).mappings
    }

    private func fetchAniListAnimeLibrary(account: MacTrackerAccount) async throws -> [RemoteAnimeEntry] {
        guard let userID = Int(account.userId), userID > 0 else { throw TrackerError.invalidCallback }
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
                        status progress
                        media {
                            id idMal episodes format
                            title { romaji english native }
                        }
                    }
                }
            }
        }
        """
        var result: [Int: RemoteAnimeEntry] = [:]
        var chunk = 1
        var hasNext = true
        while hasNext, chunk <= 40 {
            try Task.checkCancellation()
            let data = try await aniListGraphQL(
                query: query,
                variables: ["userId": userID, "chunk": chunk],
                account: account
            )
            guard let collection = try JSONDecoder().decode(AniListLibraryResponse.self, from: data).data?.collection else {
                throw TrackerError.provider("AniList returned no library data.")
            }
            for list in collection.lists {
                for entry in list.entries {
                    guard let media = entry.media else { continue }
                    let value = RemoteAnimeEntry(
                        anilistID: media.id,
                        malID: media.malID,
                        title: media.preferredTitle,
                        status: entry.status ?? list.status ?? "CURRENT",
                        progress: entry.progress ?? 0,
                        totalEpisodes: media.episodes,
                        format: media.format
                    )
                    if value.progress >= (result[media.id]?.progress ?? -1) { result[media.id] = value }
                }
            }
            hasNext = collection.hasNextChunk
            chunk += 1
        }
        guard !hasNext else {
            throw TrackerError.provider("AniList returned more library pages than Eclipse can import safely.")
        }
        return result.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func fetchMALAnimeLibrary(
        account: MacTrackerAccount,
        allowsRefreshRetry: Bool = true
    ) async throws -> [RemoteAnimeEntry] {
        var nextURL = URL(string: "https://api.myanimelist.net/v2/users/@me/animelist?fields=list_status,num_episodes,media_type&limit=1000&nsfw=true")
        var seen: Set<URL> = []
        var entries: [RemoteAnimeEntry] = []
        var pageCount = 0
        while let url = nextURL, pageCount < 100 {
            try Task.checkCancellation()
            guard url.scheme == "https", url.host == "api.myanimelist.net",
                  url.path == "/v2/users/@me/animelist", seen.insert(url).inserted else {
                throw TrackerError.invalidURL
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await trackerData(for: request, service: .myAnimeList)
            if response.statusCode == 401, allowsRefreshRetry {
                let refreshed = try await refreshedMALAccountIfNeeded(account, force: true)
                return try await fetchMALAnimeLibrary(account: refreshed, allowsRefreshRetry: false)
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                reconnectRequiredServices.insert(.myAnimeList)
                throw TrackerError.reconnectRequired(.myAnimeList)
            }
            guard response.statusCode == 200 else { throw TrackerError.http(response.statusCode) }
            let page = try JSONDecoder().decode(MALLibraryResponse.self, from: data)
            entries.append(contentsOf: page.data.map { row in
                RemoteAnimeEntry(
                    anilistID: nil,
                    malID: row.node.id,
                    title: row.node.title,
                    status: row.listStatus?.status ?? "watching",
                    progress: row.listStatus?.episodesWatched ?? 0,
                    totalEpisodes: row.node.episodes,
                    format: row.node.mediaType
                )
            })
            if let next = page.paging?.next {
                guard let candidate = URL(string: next),
                      candidate.scheme == "https", candidate.host == "api.myanimelist.net",
                      candidate.path == "/v2/users/@me/animelist" else {
                    throw TrackerError.invalidURL
                }
                nextURL = candidate
            } else {
                nextURL = nil
            }
            pageCount += 1
        }
        guard nextURL == nil else {
            throw TrackerError.provider("MyAnimeList returned more library pages than Eclipse can import safely.")
        }
        return entries
    }

    private func resolveAniListIDs(malIDs: [Int]) async throws -> [Int: Int] {
        let identifiers = Array(Set(malIDs.filter { $0 > 0 })).sorted()
        var result: [Int: Int] = [:]
        for start in stride(from: 0, to: identifiers.count, by: 50) {
            try Task.checkCancellation()
            let end = min(start + 50, identifiers.count)
            let chunk = identifiers[start..<end]
            let idList = chunk.map(String.init).joined(separator: ", ")
            let data = try await aniListGraphQL(
                query: "query { Page(perPage: \(chunk.count)) { media(type: ANIME, idMal_in: [\(idList)]) { id idMal } } }",
                variables: [:],
                account: nil
            )
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = root["data"] as? [String: Any],
                  let page = values["Page"] as? [String: Any],
                  let media = page["media"] as? [[String: Any]] else {
                throw TrackerError.provider("AniList returned invalid ID mapping data.")
            }
            for row in media {
                guard let malID = (row["idMal"] as? NSNumber)?.intValue,
                      let anilistID = (row["id"] as? NSNumber)?.intValue else { continue }
                result[malID] = anilistID
            }
        }
        return result
    }

    private func resolveImportMapping(_ entry: RemoteAnimeEntry) async throws -> ImportMapping? {
        guard let anilistID = entry.anilistID, anilistID > 0 else { return nil }
        let mappings = try await fetchAniMapMappings(value: anilistID, mappingKey: "anilist")
            .filter { $0.anilistID == nil || $0.anilistID == anilistID }
            .filter { mapping in
                let type = mapping.mediaType?.uppercased()
                let hasMovie = mapping.tmdbMovieID.map { $0 > 0 } == true
                let hasShow = mapping.tmdbShowID.map { $0 > 0 } == true
                if type == "MOVIE" || type == "SPECIAL" || type == "OVA" {
                    return hasMovie
                }
                return hasShow || hasMovie
            }
        let ranked = mappings.sorted { Self.importMappingScore($0) > Self.importMappingScore($1) }
        guard let mapping = ranked.first else { return nil }
        let mappedType = mapping.mediaType?.uppercased()
        if mappedType == "MOVIE" || mappedType == "SPECIAL" || mappedType == "OVA" {
            guard let movieID = mapping.tmdbMovieID, movieID > 0 else { return nil }
            return ImportMapping(
                anilistID: anilistID,
                malID: entry.malID,
                tmdbID: movieID,
                mediaType: "movie",
                tmdbSeason: nil,
                episodeOffset: 0
            )
        }
        if let movieID = mapping.tmdbMovieID, movieID > 0,
           mapping.tmdbShowID.map({ $0 > 0 }) != true {
            return ImportMapping(
                anilistID: anilistID,
                malID: entry.malID,
                tmdbID: movieID,
                mediaType: "movie",
                tmdbSeason: nil,
                episodeOffset: 0
            )
        }
        guard let showID = mapping.tmdbShowID, showID > 0,
              let episodeOffset = Self.safeEpisodeOffset(mapping.episodeOffset) else { return nil }
        let tmdbSeason = mapping.tmdbSeason.flatMap { (1...100).contains($0) ? $0 : nil }
        return ImportMapping(
            anilistID: anilistID,
            malID: entry.malID,
            tmdbID: showID,
            mediaType: "tv",
            tmdbSeason: tmdbSeason,
            episodeOffset: episodeOffset
        )
    }

    private static func importMappingScore(_ mapping: AniMapMapping) -> Int {
        var score = 0
        if ["MOVIE", "SPECIAL", "OVA"].contains(mapping.mediaType?.uppercased() ?? ""),
           mapping.tmdbMovieID != nil { score += 50 }
        if mapping.tmdbShowID != nil { score += 40 }
        if mapping.tmdbMovieID != nil { score += 30 }
        if mapping.tmdbSeason != nil { score += 5 }
        return score
    }

    private func fetchTMDBItem(for mapping: ImportMapping) async throws -> MacMediaItem? {
        let data = try await tmdbData(path: "/3/\(mapping.mediaType)/\(mapping.tmdbID)")
        let value = try JSONDecoder().decode(TMDBTrackerDetail.self, from: data)
        let title = value.title ?? value.name ?? value.originalTitle ?? value.originalName
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return MacMediaItem(
            id: mapping.tmdbID,
            mediaType: mapping.mediaType,
            title: title,
            overview: value.overview ?? "",
            posterPath: value.posterPath,
            backdropPath: value.backdropPath,
            date: value.releaseDate ?? value.firstAirDate,
            rating: value.voteAverage ?? 0
        )
    }

    private func trimCompletedSignatures() {
        if completedAnimeSyncSignatures.count > 2_000 { completedAnimeSyncSignatures.removeAll(keepingCapacity: true) }
        if completedMangaSyncSignatures.count > 2_000 { completedMangaSyncSignatures.removeAll(keepingCapacity: true) }
    }

    private func saveAniListProgress(
        account: MacTrackerAccount,
        mapping: AnimeMapping,
        watchedEpisodes: Int
    ) async throws {
        let state = try await fetchAniListState(account: account, mediaID: mapping.anilistID, type: "ANIME")
        let targetProgress = max(watchedEpisodes, state?.progress ?? 0)
        guard targetProgress > (state?.progress ?? -1) else { return }

        let status: String?
        if let state {
            if state.status == "REPEATING" {
                status = "REPEATING"
            } else if let total = mapping.episodeCount, total > 0, targetProgress >= total {
                status = "COMPLETED"
            } else {
                status = "CURRENT"
            }
        } else if let total = mapping.episodeCount, total > 0, targetProgress >= total {
            status = "COMPLETED"
        } else {
            status = "CURRENT"
        }
        try await saveAniListListEntry(
            account: account,
            mediaID: mapping.anilistID,
            progressKey: "progress",
            progress: targetProgress,
            status: status,
            score: nil
        )
    }

    private func saveAniListMangaProgress(
        account: MacTrackerAccount,
        mapping: MangaMapping,
        chapter: Int,
        totalChapters: Int?
    ) async throws {
        let state = try await fetchAniListState(account: account, mediaID: mapping.anilistID, type: "MANGA")
        let targetProgress = max(chapter, state?.progress ?? 0)
        guard targetProgress > (state?.progress ?? -1) else { return }
        let total = totalChapters ?? mapping.chapterCount
        let status: String?
        if let state {
            if state.status == "REPEATING" {
                status = "REPEATING"
            } else if let total, total > 0, targetProgress >= total {
                status = "COMPLETED"
            } else {
                status = "CURRENT"
            }
        } else if let total, total > 0, targetProgress >= total {
            status = "COMPLETED"
        } else {
            status = "CURRENT"
        }
        try await saveAniListListEntry(
            account: account,
            mediaID: mapping.anilistID,
            progressKey: "progress",
            progress: targetProgress,
            status: status,
            score: nil
        )
    }

    private func saveAniListRating(
        account: MacTrackerAccount,
        mapping: AnimeMapping,
        rating: Double
    ) async throws {
        do {
            try await saveAniListListEntry(
                account: account,
                mediaID: mapping.anilistID,
                progressKey: nil,
                progress: nil,
                status: nil,
                score: rating
            )
        } catch let error as TrackerError {
            switch error {
            case .provider, .http(400): break
            default: throw error
            }
            try await saveAniListListEntry(
                account: account,
                mediaID: mapping.anilistID,
                progressKey: nil,
                progress: nil,
                status: "CURRENT",
                score: rating
            )
        }
    }

    private func saveAniListListEntry(
        account: MacTrackerAccount,
        mediaID: Int,
        progressKey: String?,
        progress: Int?,
        status: String?,
        score: Double?
    ) async throws {
        guard accountMatchesCurrentGeneration(account) else { throw TrackerError.accountChanged }
        var declarations = ["$mediaId: Int!"]
        var arguments = ["mediaId: $mediaId"]
        var variables: [String: Any] = ["mediaId": mediaID]
        if let progressKey, let progress {
            declarations.append("$progress: Int!")
            arguments.append("\(progressKey): $progress")
            variables["progress"] = progress
        }
        if let status {
            declarations.append("$status: MediaListStatus!")
            arguments.append("status: $status")
            variables["status"] = status
        }
        if let score {
            declarations.append("$scoreRaw: Int!")
            arguments.append("scoreRaw: $scoreRaw")
            variables["scoreRaw"] = max(1, min(100, Int((score * 10).rounded())))
        }
        if status == "COMPLETED" {
            let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            declarations.append("$completedAt: FuzzyDateInput")
            arguments.append("completedAt: $completedAt")
            variables["completedAt"] = [
                "year": components.year ?? 0,
                "month": components.month ?? 0,
                "day": components.day ?? 0
            ]
        }
        let query = """
        mutation(\(declarations.joined(separator: ", "))) {
            SaveMediaListEntry(\(arguments.joined(separator: ", "))) {
                id
                progress
                progressVolumes
                status
                score
            }
        }
        """
        _ = try await aniListGraphQL(query: query, variables: variables, account: account)
        guard accountMatchesCurrentGeneration(account) else { throw TrackerError.accountChanged }
    }

    private func fetchAniListState(
        account: MacTrackerAccount,
        mediaID: Int,
        type: String
    ) async throws -> AniListRemoteState? {
        let query = """
        query($mediaId: Int!) {
            Media(id: $mediaId, type: \(type)) {
                mediaListEntry { progress progressVolumes status score }
            }
        }
        """
        let data = try await aniListGraphQL(
            query: query,
            variables: ["mediaId": mediaID],
            account: account
        )
        return try JSONDecoder().decode(AniListStateResponse.self, from: data).data?.media?.mediaListEntry
    }

    private func saveMALAnimeProgress(
        account: MacTrackerAccount,
        mapping: AnimeMapping,
        watchedEpisodes: Int
    ) async throws {
        let state = try await fetchMALState(account: account, mediaPath: "anime", mediaID: mapping.malID ?? 0)
        let target = max(watchedEpisodes, state?.progress ?? 0)
        guard target > (state?.progress ?? -1), let malID = mapping.malID else { return }
        var values = ["num_watched_episodes": String(target)]
        if let state {
            if state.isRepeating {
                values["is_rewatching"] = "true"
            } else if state.status == "completed" {
                values["status"] = "completed"
            } else if let total = state.total ?? mapping.episodeCount, total > 0, target >= total {
                values["status"] = "completed"
            } else {
                values["status"] = "watching"
            }
        } else if let total = mapping.episodeCount, total > 0, target >= total {
            values["status"] = "completed"
        } else {
            values["status"] = "watching"
        }
        let activeAccount = self.account(for: .myAnimeList) ?? account
        _ = try await sendMALListStatusRequest(
            account: activeAccount,
            mediaPath: "anime",
            mediaID: malID,
            values: values
        )
    }

    private func saveMALMangaProgress(
        account: MacTrackerAccount,
        mapping: MangaMapping,
        chapter: Int,
        totalChapters: Int?
    ) async throws {
        guard let malID = mapping.malID else { return }
        let state = try await fetchMALState(account: account, mediaPath: "manga", mediaID: malID)
        let target = max(chapter, state?.progress ?? 0)
        guard target > (state?.progress ?? -1) else { return }
        var values = ["num_chapters_read": String(target)]
        if let state {
            if state.isRepeating {
                values["is_rereading"] = "true"
            } else if state.status == "completed" {
                values["status"] = "completed"
            } else if let total = state.total ?? totalChapters ?? mapping.chapterCount, total > 0, target >= total {
                values["status"] = "completed"
            } else {
                values["status"] = "reading"
            }
        } else if let total = totalChapters ?? mapping.chapterCount, total > 0, target >= total {
            values["status"] = "completed"
        } else {
            values["status"] = "reading"
        }
        let activeAccount = self.account(for: .myAnimeList) ?? account
        _ = try await sendMALListStatusRequest(
            account: activeAccount,
            mediaPath: "manga",
            mediaID: malID,
            values: values
        )
    }

    private func saveMALRating(
        account: MacTrackerAccount,
        mapping: AnimeMapping,
        rating: Double
    ) async throws {
        guard let malID = mapping.malID else { return }
        _ = try await sendMALListStatusRequest(
            account: account,
            mediaPath: "anime",
            mediaID: malID,
            values: ["score": String(max(1, min(10, Int(rating.rounded()))))]
        )
    }

    private func fetchMALState(
        account: MacTrackerAccount,
        mediaPath: String,
        mediaID: Int,
        allowsRefreshRetry: Bool = true
    ) async throws -> MALRemoteState? {
        guard mediaID > 0 else { throw TrackerError.invalidURL }
        let progressField = mediaPath == "anime" ? "num_episodes_watched" : "num_chapters_read"
        let totalField = mediaPath == "anime" ? "num_episodes" : "num_chapters"
        let repeatingField = mediaPath == "anime" ? "is_rewatching" : "is_rereading"
        let address = "https://api.myanimelist.net/v2/\(mediaPath)/\(mediaID)?fields=my_list_status,\(totalField)"
        var request = URLRequest(url: URL(string: address)!)
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await trackerData(for: request, service: .myAnimeList)
        if response.statusCode == 401, allowsRefreshRetry {
            let refreshed = try await refreshedMALAccountIfNeeded(account, force: true)
            return try await fetchMALState(
                account: refreshed,
                mediaPath: mediaPath,
                mediaID: mediaID,
                allowsRefreshRetry: false
            )
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            reconnectRequiredServices.insert(.myAnimeList)
            throw TrackerError.reconnectRequired(.myAnimeList)
        }
        guard response.statusCode == 200 else { throw TrackerError.http(response.statusCode) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let list = json?["my_list_status"] as? [String: Any] else { return nil }
        return MALRemoteState(
            progress: (list[progressField] as? NSNumber)?.intValue ?? 0,
            status: list["status"] as? String,
            isRepeating: (list[repeatingField] as? Bool) == true,
            total: (json?[totalField] as? NSNumber)?.intValue
        )
    }

    private func sendMALListStatusRequest(
        account: MacTrackerAccount,
        mediaPath: String,
        mediaID: Int,
        values: [String: String],
        allowsRefreshRetry: Bool = true
    ) async throws -> Data {
        guard accountMatchesCurrentGeneration(account) else { throw TrackerError.accountChanged }
        let address = "https://api.myanimelist.net/v2/\(mediaPath)/\(mediaID)/my_list_status"
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = values.sorted { $0.key < $1.key }.map {
            "\($0.key.formEncoded)=\($0.value.formEncoded)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await trackerData(for: request, service: .myAnimeList)
        if response.statusCode == 401, allowsRefreshRetry {
            let refreshed = try await refreshedMALAccountIfNeeded(account, force: true)
            return try await sendMALListStatusRequest(
                account: refreshed,
                mediaPath: mediaPath,
                mediaID: mediaID,
                values: values,
                allowsRefreshRetry: false
            )
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            reconnectRequiredServices.insert(.myAnimeList)
            throw TrackerError.reconnectRequired(.myAnimeList)
        }
        guard 200..<300 ~= response.statusCode else { throw TrackerError.http(response.statusCode) }
        guard accountMatchesCurrentGeneration(account) else { throw TrackerError.accountChanged }
        return data
    }

    private func aniListGraphQL(
        query: String,
        variables: [String: Any],
        account: MacTrackerAccount?
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let account {
            try ensureAniListAccountIsUsable(account)
            guard accountMatchesCurrentGeneration(account) else { throw TrackerError.accountChanged }
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await trackerData(for: request, service: .anilist)
        if response.statusCode == 401 || response.statusCode == 403 {
            reconnectRequiredServices.insert(.anilist)
            throw TrackerError.reconnectRequired(.anilist)
        }
        guard 200..<300 ~= response.statusCode else { throw TrackerError.http(response.statusCode) }
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            throw TrackerError.provider((errors.first?["message"] as? String) ?? "AniList rejected the request.")
        }
        if let account, !accountMatchesCurrentGeneration(account) { throw TrackerError.accountChanged }
        return data
    }

    private func trackerData(
        for request: URLRequest,
        service: MacTrackerService,
        maximumAttempts: Int = 3
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              Self.allowedHost(url.host, for: service) else { throw TrackerError.invalidURL }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            try await MacTrackerRequestGate.shared.wait(for: service)
            let (data, response) = try await MacTrackerNetwork.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TrackerError.http(0) }
            guard let finalURL = http.url, finalURL.scheme?.lowercased() == "https",
                  Self.allowedHost(finalURL.host, for: service) else { throw TrackerError.invalidURL }
            guard data.count <= 20_000_000 else { throw TrackerError.responseTooLarge }
            if http.statusCode == 429, attempt + 1 < maximumAttempts {
                let retry = min(120, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(attempt + 1) * 2))
                attempt += 1
                await MacTrackerRequestGate.shared.pause(for: service, seconds: retry)
                continue
            }
            if (500...599).contains(http.statusCode), attempt + 1 < maximumAttempts {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt)))
                continue
            }
            return (data, http)
        }
    }

    private static func allowedHost(_ host: String?, for service: MacTrackerService) -> Bool {
        guard let host = host?.lowercased() else { return false }
        switch service {
        case .anilist: return host == "graphql.anilist.co" || host == "anilist.co"
        case .myAnimeList: return host == "api.myanimelist.net" || host == "myanimelist.net"
        case .trakt: return host == "api.trakt.tv" || host == "trakt.tv"
        }
    }

    private func jsonRequest<T: Decodable>(_ address: String, method: String, json: [String: String], bearer: String? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await send(request)
    }

    private func formRequest<T: Decodable>(_ address: String, fields: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields.sorted { $0.key < $1.key }.map {
            "\($0.key.formEncoded)=\($0.value.formEncoded)"
        }.joined(separator: "&").data(using: .utf8)
        return try await send(request)
    }

    private func getRequest<T: Decodable>(_ address: String, bearer: String) async throws -> T {
        var request = URLRequest(url: URL(string: address)!)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        guard let originalURL = request.url,
              originalURL.scheme?.lowercased() == "https",
              originalURL.host?.isEmpty == false else {
            throw TrackerError.invalidURL
        }
        let (data, response) = try await MacTrackerNetwork.session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw TrackerError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == request.url?.host?.lowercased() else {
            throw TrackerError.invalidURL
        }
        guard data.count <= 5_000_000 else { throw TrackerError.responseTooLarge }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func credential(_ key: String) throws -> String {
        let value = configured(key, fallback: "")
        guard !value.isEmpty else { throw TrackerError.missingCredential(key) }
        return value
    }

    private func configured(_ key: String, fallback: String) -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.contains("$(") ? fallback : value
    }

    private func url(_ address: String, items: [URLQueryItem]) throws -> URL {
        var components = URLComponents(string: address)
        components?.queryItems = items
        guard let value = components?.url else { throw TrackerError.invalidURL }
        return value
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        guard let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            errorMessage = "Tracker metadata could not be read. The existing file was preserved unchanged."
            return
        }
        guard state.version <= 2 else {
            errorMessage = "Tracker metadata was created by a newer Eclipse version and was preserved unchanged."
            return
        }

        let originalMetadata = state.accounts.map(redacted)
        persistedAccounts = originalMetadata
        pendingCredentialDeletes = uniqueReferences(state.pendingCredentialDeletes)

        var originalResolved: [MacTrackerAccount] = []
        var candidateResolved: [MacTrackerAccount] = []
        var candidateMetadata = originalMetadata
        var candidateDeletes = pendingCredentialDeletes
        var stagedReferences: [CredentialReference] = []
        var unresolvedCount = 0
        var migrationStoreFailed = false

        for (index, metadata) in originalMetadata.enumerated() {
            switch CredentialVault.hydrate(metadata) {
            case .resolved(let account):
                originalResolved.append(account)
                guard metadata.credentialID == nil else {
                    candidateResolved.append(account)
                    continue
                }

                var migrated = account
                migrated.credentialID = Self.credentialID()
                guard CredentialVault.store(migrated) else {
                    migrationStoreFailed = true
                    candidateResolved.append(account)
                    continue
                }
                let staged = CredentialReference(account: migrated)
                stagedReferences.append(staged)
                candidateMetadata[index] = redacted(migrated)
                candidateResolved.append(migrated)
                candidateDeletes.append(CredentialReference(account: metadata))

            case .missing, .corrupt, .unavailable:
                unresolvedCount += 1
            }
        }

        candidateDeletes = uniqueReferences(candidateDeletes)
        if !stagedReferences.isEmpty {
            if persist(candidateMetadata, pendingDeletes: candidateDeletes) {
                persistedAccounts = candidateMetadata.map(redacted)
                pendingCredentialDeletes = candidateDeletes
                accounts = candidateResolved
            } else {
                let stagedCleaned = stagedReferences.allSatisfy(CredentialVault.remove)
                persistedAccounts = originalMetadata
                pendingCredentialDeletes = uniqueReferences(state.pendingCredentialDeletes)
                accounts = originalResolved
                errorMessage = stagedCleaned
                    ? "Legacy tracker credentials remain usable, but their secure migration could not be committed."
                    : "Legacy tracker credentials remain usable, but migration and staged Keychain cleanup both need another attempt."
            }
        } else {
            accounts = originalResolved
        }

        if !cleanupCredentialTombstones(), errorMessage == nil {
            errorMessage = "Some old tracker credentials still need secure Keychain cleanup."
        } else if migrationStoreFailed, errorMessage == nil {
            errorMessage = "Legacy tracker credentials remain usable, but their secure migration needs another attempt."
        } else if (state.hadCorruptAccounts || state.hadCorruptCredentialDeletes || unresolvedCount > 0), errorMessage == nil {
            errorMessage = "Some tracker metadata or Keychain credentials could not be resolved. Valid account metadata was preserved."
        }
    }

    @discardableResult
    private func persist(_ candidate: [MacTrackerAccount], pendingDeletes: [CredentialReference]) -> Bool {
        let state = PersistedState(
            accounts: candidate.map(redacted),
            pendingCredentialDeletes: uniqueReferences(pendingDeletes)
        )
        do {
            let data = try JSONEncoder().encode(state)
            try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: stateURL, options: .atomic)
            return true
        } catch { return false }
    }

    private func redacted(_ account: MacTrackerAccount) -> MacTrackerAccount {
        var copy = account
        copy.accessToken = ""
        copy.refreshToken = nil
        copy.expiresAt = nil
        return copy
    }

    private func accountMatchesCurrentGeneration(_ expected: MacTrackerAccount) -> Bool {
        guard let current = account(for: expected.service), current.userId == expected.userId else { return false }
        if let credentialID = expected.credentialID {
            return current.credentialID == credentialID
        }
        return current.credentialID == nil && current.accessToken == expected.accessToken
    }

    private func credentialGenerationKey(_ account: MacTrackerAccount) -> String {
        if let credentialID = account.credentialID {
            return "\(account.service.rawValue):\(account.userId):\(credentialID)"
        }
        return "\(account.service.rawValue):\(account.userId):legacy"
    }

    private func uniqueReferences(_ references: [CredentialReference]) -> [CredentialReference] {
        var seen: Set<CredentialReference> = []
        return references.filter { seen.insert($0).inserted }
    }

    @discardableResult
    private func cleanupCredentialTombstones() -> Bool {
        guard !pendingCredentialDeletes.isEmpty else { return true }
        let remaining = pendingCredentialDeletes.filter { !CredentialVault.remove($0) }
        guard remaining != pendingCredentialDeletes else { return false }
        guard persist(persistedAccounts, pendingDeletes: remaining) else { return false }
        pendingCredentialDeletes = remaining
        return remaining.isEmpty
    }

    private func callback(_ callbackURL: URL, matches expectedURL: URL) -> Bool {
        guard let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: expectedURL, resolvingAgainstBaseURL: false),
              callback.fragment == nil,
              callback.scheme?.lowercased() == expected.scheme?.lowercased(),
              callback.host?.lowercased() == expected.host?.lowercased() else { return false }
        let callbackPath = callback.percentEncodedPath.isEmpty ? "/" : callback.percentEncodedPath
        let expectedPath = expected.percentEncodedPath.isEmpty ? "/" : expected.percentEncodedPath
        return callbackPath == expectedPath
    }

    private static func oauthState() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func credentialID() -> String {
        UUID().uuidString.lowercased()
    }
}

extension MacTrackerStore: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}

private extension MacTrackerStore {
    struct AuthorizationRequest { let url: URL; let callbackScheme: String; let callbackURL: URL; let state: String? }
    struct CredentialReference: Codable, Hashable {
        let service: MacTrackerService
        let credentialID: String?

        init(service: MacTrackerService, credentialID: String?) {
            self.service = service
            self.credentialID = credentialID
        }

        init(account: MacTrackerAccount) {
            service = account.service
            credentialID = account.credentialID
        }
    }

    struct FailableDecodable<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    struct PersistedState: Codable {
        var version = 2
        var accounts: [MacTrackerAccount]
        var pendingCredentialDeletes: [CredentialReference]
        var syncEnabled = true
        var autoSyncRatings = false
        var autoSyncReaderRatings = false
        var mergeTraktContinueWatching = false
        var liveTraktScrobbling = true
        var traktPublicCatalogsEnabled = false
        var traktCommentsEnabled = false
        var traktRelatedEnabled = false
        var traktAnimeEpisodeMapping = true
        var traktWatchlistSync = false
        var lastSyncDate: Date?
        var hadCorruptAccounts = false
        var hadCorruptCredentialDeletes = false

        enum CodingKeys: String, CodingKey {
            case version, accounts, pendingCredentialDeletes
            case syncEnabled, autoSyncRatings, autoSyncReaderRatings, mergeTraktContinueWatching
            case liveTraktScrobbling, traktPublicCatalogsEnabled, traktCommentsEnabled, traktRelatedEnabled
            case traktAnimeEpisodeMapping, traktWatchlistSync, lastSyncDate
        }

        init(accounts: [MacTrackerAccount], pendingCredentialDeletes: [CredentialReference]) {
            self.accounts = accounts
            self.pendingCredentialDeletes = pendingCredentialDeletes
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            let decodedAccounts = try values.decodeIfPresent(
                [FailableDecodable<MacTrackerAccount>].self,
                forKey: .accounts
            ) ?? []
            accounts = decodedAccounts.compactMap(\.value)
            hadCorruptAccounts = decodedAccounts.contains { $0.value == nil }
            let decodedDeletes = try values.decodeIfPresent(
                [FailableDecodable<CredentialReference>].self,
                forKey: .pendingCredentialDeletes
            ) ?? []
            pendingCredentialDeletes = decodedDeletes.compactMap(\.value)
            hadCorruptCredentialDeletes = decodedDeletes.contains { $0.value == nil }
            syncEnabled = try values.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? true
            autoSyncRatings = try values.decodeIfPresent(Bool.self, forKey: .autoSyncRatings) ?? false
            autoSyncReaderRatings = try values.decodeIfPresent(Bool.self, forKey: .autoSyncReaderRatings) ?? false
            mergeTraktContinueWatching = try values.decodeIfPresent(Bool.self, forKey: .mergeTraktContinueWatching) ?? false
            liveTraktScrobbling = try values.decodeIfPresent(Bool.self, forKey: .liveTraktScrobbling) ?? true
            traktPublicCatalogsEnabled = try values.decodeIfPresent(Bool.self, forKey: .traktPublicCatalogsEnabled) ?? false
            traktCommentsEnabled = try values.decodeIfPresent(Bool.self, forKey: .traktCommentsEnabled) ?? false
            traktRelatedEnabled = try values.decodeIfPresent(Bool.self, forKey: .traktRelatedEnabled) ?? false
            traktAnimeEpisodeMapping = try values.decodeIfPresent(Bool.self, forKey: .traktAnimeEpisodeMapping) ?? true
            traktWatchlistSync = try values.decodeIfPresent(Bool.self, forKey: .traktWatchlistSync) ?? false
            lastSyncDate = try values.decodeIfPresent(Date.self, forKey: .lastSyncDate)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(version, forKey: .version)
            try values.encode(accounts, forKey: .accounts)
            try values.encode(pendingCredentialDeletes, forKey: .pendingCredentialDeletes)
            try values.encode(syncEnabled, forKey: .syncEnabled)
            try values.encode(autoSyncRatings, forKey: .autoSyncRatings)
            try values.encode(autoSyncReaderRatings, forKey: .autoSyncReaderRatings)
            try values.encode(mergeTraktContinueWatching, forKey: .mergeTraktContinueWatching)
            try values.encode(liveTraktScrobbling, forKey: .liveTraktScrobbling)
            try values.encode(traktPublicCatalogsEnabled, forKey: .traktPublicCatalogsEnabled)
            try values.encode(traktCommentsEnabled, forKey: .traktCommentsEnabled)
            try values.encode(traktRelatedEnabled, forKey: .traktRelatedEnabled)
            try values.encode(traktAnimeEpisodeMapping, forKey: .traktAnimeEpisodeMapping)
            try values.encode(traktWatchlistSync, forKey: .traktWatchlistSync)
            try values.encodeIfPresent(lastSyncDate, forKey: .lastSyncDate)
        }
    }

    struct AnimeMapping: Codable {
        let anilistID: Int
        let malID: Int?
        let episodeCount: Int?
        let tmdbSeason: Int?
        let episodeOffset: Int
        let isMovie: Bool
        let provenance: String
        let cachedAt: Date
    }

    struct MangaMapping: Codable {
        let anilistID: Int
        let malID: Int?
        let chapterCount: Int?
        let cachedAt: Date
    }

    struct RemoteAnimeEntry {
        let anilistID: Int?
        let malID: Int?
        let title: String
        let status: String
        let progress: Int
        let totalEpisodes: Int?
        let format: String?
    }

    struct ImportMapping {
        let anilistID: Int
        let malID: Int?
        let tmdbID: Int
        let mediaType: String
        let tmdbSeason: Int?
        let episodeOffset: Int
    }

    struct AniMapMapping: Decodable {
        let anilistID: Int?
        let tmdbShowID: Int?
        let tmdbMovieID: Int?
        let tmdbSeason: Int?
        let episodeOffset: Int?
        let mediaType: String?

        enum CodingKeys: String, CodingKey {
            case anilistID = "anilist_id"
            case tmdbShowID = "tmdb_show_id"
            case tmdbMovieID = "tmdb_movie_id"
            case tmdbSeason = "tmdb_season"
            case episodeOffset = "tvdb_epoffset"
            case mediaType = "media_type"
        }
    }

    struct AniMapMappingList: Decodable {
        let mappings: [AniMapMapping]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let values = try? container.decode([AniMapMapping].self) {
                mappings = values
            } else if let value = try? container.decode(AniMapMapping.self) {
                mappings = [value]
            } else {
                mappings = []
            }
        }
    }

    struct TMDBTrackerDescriptor {
        let titles: [String]
        let genreIDs: [Int]
        let originalLanguage: String?
        let date: String?

        var candidateTitles: [String] {
            var seen: Set<String> = []
            return titles.compactMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = MacTrackerStore.normalizedTitle(trimmed)
                guard !trimmed.isEmpty, seen.insert(key).inserted else { return nil }
                return trimmed
            }
        }

        var isAnime: Bool {
            genreIDs.contains(16)
                && ["ja", "ko", "zh", "cn"].contains(originalLanguage?.lowercased() ?? "")
        }
    }

    struct TMDBTrackerDetail: Decodable {
        struct Genre: Decodable { let id: Int }
        let title: String?
        let name: String?
        let originalTitle: String?
        let originalName: String?
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let releaseDate: String?
        let firstAirDate: String?
        let originalLanguage: String?
        let voteAverage: Double?
        let genres: [Genre]

        enum CodingKeys: String, CodingKey {
            case title, name, overview, genres
            case originalTitle = "original_title"
            case originalName = "original_name"
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
            case originalLanguage = "original_language"
            case voteAverage = "vote_average"
        }
    }

    struct TMDBTrackerSeason: Decodable {
        let airDate: String?
        enum CodingKeys: String, CodingKey { case airDate = "air_date" }
    }

    struct AniListMediaNode: Decodable {
        struct Title: Decodable { let romaji: String?; let english: String?; let native: String? }
        struct StartDate: Decodable { let year: Int? }
        let id: Int
        let malID: Int?
        let episodes: Int?
        let chapters: Int?
        let format: String?
        let title: Title
        let synonyms: [String]?
        let startDate: StartDate?

        enum CodingKeys: String, CodingKey {
            case id, episodes, chapters, format, title, synonyms, startDate
            case malID = "idMal"
        }

        var allTitles: [String] {
            [title.english, title.romaji, title.native].compactMap { $0 } + (synonyms ?? [])
        }

        var preferredTitle: String {
            title.english ?? title.romaji ?? title.native ?? "Unknown"
        }
    }

    struct AniListMediaResponse: Decodable {
        let data: DataValue?
        struct DataValue: Decodable {
            let media: AniListMediaNode?
            enum CodingKeys: String, CodingKey { case media = "Media" }
        }
    }

    struct AniListSearchResponse: Decodable {
        let data: DataValue?
        struct DataValue: Decodable {
            let page: Page?
            enum CodingKeys: String, CodingKey { case page = "Page" }
        }
        struct Page: Decodable { let media: [AniListMediaNode] }
    }

    struct AniListIDResponse: Decodable {
        let data: DataValue?
        struct DataValue: Decodable {
            let media: IDValue?
            enum CodingKeys: String, CodingKey { case media = "Media" }
        }
        struct IDValue: Decodable { let id: Int }
    }

    struct AniListRemoteState: Decodable {
        let progress: Int?
        let progressVolumes: Int?
        let status: String?
        let score: Double?
    }

    struct AniListStateResponse: Decodable {
        let data: DataValue?
        struct DataValue: Decodable {
            let media: MediaValue?
            enum CodingKeys: String, CodingKey { case media = "Media" }
        }
        struct MediaValue: Decodable { let mediaListEntry: AniListRemoteState? }
    }

    struct MALRemoteState {
        let progress: Int
        let status: String?
        let isRepeating: Bool
        let total: Int?
    }

    struct AniListLibraryResponse: Decodable {
        let data: DataValue?
        struct DataValue: Decodable {
            let collection: Collection?
            enum CodingKeys: String, CodingKey { case collection = "MediaListCollection" }
        }
        struct Collection: Decodable { let hasNextChunk: Bool; let lists: [List] }
        struct List: Decodable { let status: String?; let entries: [Entry] }
        struct Entry: Decodable { let status: String?; let progress: Int?; let media: AniListMediaNode? }
    }

    struct MALLibraryResponse: Decodable {
        struct Row: Decodable {
            struct Node: Decodable {
                let id: Int
                let title: String
                let episodes: Int?
                let mediaType: String?
                enum CodingKeys: String, CodingKey {
                    case id, title
                    case episodes = "num_episodes"
                    case mediaType = "media_type"
                }
            }
            struct ListStatus: Decodable {
                let status: String?
                let episodesWatched: Int?
                enum CodingKeys: String, CodingKey {
                    case status
                    case episodesWatched = "num_episodes_watched"
                }
            }
            let node: Node
            let listStatus: ListStatus?
            enum CodingKeys: String, CodingKey { case node; case listStatus = "list_status" }
        }
        struct Paging: Decodable { let next: String? }
        let data: [Row]
        let paging: Paging?
    }

    struct AniListToken: Decodable {
        let accessToken: String; let expiresIn: Int
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", expiresIn = "expires_in" }
    }
    struct AniListViewerResponse: Decodable { let data: DataValue; struct DataValue: Decodable { let viewer: User }; struct User: Decodable { let id: Int; let name: String } }
    struct MALToken: Decodable {
        let accessToken: String; let refreshToken: String?; let expiresIn: Int?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in" }
    }
    struct MALUser: Decodable { let id: Int; let name: String }
    struct TraktToken: Decodable {
        let accessToken: String; let refreshToken: String; let expiresIn: Int
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in" }
    }
    struct TraktSettings: Decodable { let user: User; struct User: Decodable { let username: String; let ids: IDs }; struct IDs: Decodable { let trakt: Int?; let slug: String } }
    enum TrackerError: LocalizedError {
        case invalidURL, invalidCallback, keychain, persistence, persistenceAndCleanup, accountChanged
        case missingCredential(String), http(Int), reconnectRequired(MacTrackerService), provider(String), responseTooLarge
        var errorDescription: String? {
            switch self {
            case .invalidURL: "The tracker authorization URL is invalid."
            case .invalidCallback: "The tracker returned an invalid callback."
            case .keychain: "The tracker credentials could not be saved securely."
            case .persistence: "The tracker account metadata could not be saved. Nothing was changed."
            case .persistenceAndCleanup: "No tracker account change was committed, and an unreferenced staged Keychain credential still needs secure cleanup."
            case .accountChanged: "The tracker account changed while its credentials were refreshing."
            case .missingCredential(let key): "\(key) is not configured in Build.local.xcconfig."
            case .http(let code): "The tracker request returned HTTP \(code)."
            case .reconnectRequired(let service): "\(service.name) needs to be reconnected."
            case .provider(let message): message
            case .responseTooLarge: "The tracker response exceeded Eclipse's safe size limit."
            }
        }
    }

    enum CredentialVault {
        enum HydrationResult {
            case resolved(MacTrackerAccount)
            case missing
            case corrupt
            case unavailable(OSStatus)
        }

        private struct Secret: Codable {
            let service: MacTrackerService
            let userId: String
            let credentialID: String
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Date?
        }

        private struct LegacySecret: Codable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Date?
        }

        private static let service = "app.Eclipse.Soupy.tracker-credentials"

        static func store(_ account: MacTrackerAccount) -> Bool {
            guard let credentialID = account.credentialID,
                  let data = try? JSONEncoder().encode(Secret(
                    service: account.service,
                    userId: account.userId,
                    credentialID: credentialID,
                    accessToken: account.accessToken,
                    refreshToken: account.refreshToken,
                    expiresAt: account.expiresAt
                  )) else { return false }
            let reference = CredentialReference(account: account)
            let query = base(reference)
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            let stored: Bool
            if updateStatus == errSecSuccess {
                stored = true
            } else if updateStatus == errSecItemNotFound {
                var insertion = query
                insertion[kSecValueData as String] = data
                insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                stored = SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
            } else {
                stored = false
            }
            guard stored else { return false }
            guard case .resolved(let verified) = hydrate(account) else {
                _ = remove(reference)
                return false
            }
            let verifiedExactly = verified.service == account.service
                && verified.userId == account.userId
                && verified.credentialID == account.credentialID
                && verified.accessToken == account.accessToken
                && verified.refreshToken == account.refreshToken
            if !verifiedExactly { _ = remove(reference) }
            return verifiedExactly
        }

        static func hydrate(_ account: MacTrackerAccount) -> HydrationResult {
            let reference = CredentialReference(account: account)
            var query = base(reference)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else {
                return status == errSecItemNotFound ? .missing : .unavailable(status)
            }
            guard let data = result as? Data else { return .corrupt }

            var copy = account
            if let credentialID = account.credentialID {
                guard let secret = try? JSONDecoder().decode(Secret.self, from: data),
                      secret.service == account.service,
                      secret.userId == account.userId,
                      secret.credentialID == credentialID else { return .corrupt }
                copy.accessToken = secret.accessToken
                copy.refreshToken = secret.refreshToken
                copy.expiresAt = secret.expiresAt
            } else {
                guard let secret = try? JSONDecoder().decode(LegacySecret.self, from: data) else { return .corrupt }
                copy.accessToken = secret.accessToken
                copy.refreshToken = secret.refreshToken
                copy.expiresAt = secret.expiresAt
            }
            return .resolved(copy)
        }

        static func remove(_ reference: CredentialReference) -> Bool {
            let status = SecItemDelete(base(reference) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        private static func base(_ reference: CredentialReference) -> [String: Any] {
            let account = reference.credentialID.map { "\(reference.service.rawValue):\($0)" }
                ?? reference.service.rawValue
            return [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
        }
    }
}

private enum MacTrackerNetwork {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(
            configuration: configuration,
            delegate: MacStrictRedirectDelegate(),
            delegateQueue: nil
        )
    }()
}

private final class MacStrictRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
              originalURL.scheme?.lowercased() == "https",
              let redirectedURL = request.url,
              redirectedURL.scheme?.lowercased() == "https",
              redirectedURL.host?.lowercased() == originalURL.host?.lowercased() else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private actor MacTrackerRequestGate {
    static let shared = MacTrackerRequestGate()
    private var nextAvailable: [MacTrackerService: Date] = [:]

    func wait(for service: MacTrackerService) async throws {
        let now = Date()
        let spacing: TimeInterval
        switch service {
        case .anilist: spacing = 0.75
        case .myAnimeList: spacing = 1.2
        case .trakt: spacing = 0.2
        }
        let reserved = max(now, nextAvailable[service] ?? now)
        nextAvailable[service] = reserved.addingTimeInterval(spacing)
        if reserved > now {
            try await Task.sleep(for: .seconds(reserved.timeIntervalSince(now)))
        }
    }

    func pause(for service: MacTrackerService, seconds: TimeInterval) {
        let pausedUntil = Date().addingTimeInterval(max(0, seconds))
        nextAvailable[service] = max(nextAvailable[service] ?? pausedUntil, pausedUntil)
    }
}

private extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self
    }
}
