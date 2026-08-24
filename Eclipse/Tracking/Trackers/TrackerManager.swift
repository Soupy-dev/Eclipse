//
//  TrackerManager.swift
//  Eclipse
//
//  Created by Soupy-dev
//

import Foundation
import Combine
import AuthenticationServices
import Security
import UIKit
import CryptoKit

enum TraktOAuthRefreshFailureDisposition: Equatable {
    case authenticationRequired
    case other
}

enum TraktOAuthRefreshFailurePolicy {
    static let maximumResponseBytes = 16 * 1_024
    static let maximumErrorCodeBytes = 64

    static func disposition(
        statusCode: Int,
        responseData: Data
    ) -> TraktOAuthRefreshFailureDisposition {
        guard statusCode == 400,
              responseData.count <= maximumResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: responseData),
              let response = object as? [String: Any],
              let rawError = response["error"] as? String,
              rawError.utf8.count <= maximumErrorCodeBytes else {
            return .other
        }

        let error = rawError
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return error == "invalid_grant" ? .authenticationRequired : .other
    }

    static func responseDiagnostic(from responseData: Data, limit: Int = 12) -> String {
        let digest = SHA256.hash(data: responseData)
            .map { String(format: "%02x", $0) }
            .joined()
        return "bytes=\(responseData.count) token=\(digest.prefix(max(8, min(limit, 32))))"
    }
}

struct TraktOAuthRefreshFailure: LocalizedError {
    let statusCode: Int
    let diagnostic: String
    let disposition: TraktOAuthRefreshFailureDisposition

    init(statusCode: Int, responseData: Data) {
        self.statusCode = statusCode
        self.diagnostic = TraktOAuthRefreshFailurePolicy.responseDiagnostic(
            from: responseData
        )
        self.disposition = TraktOAuthRefreshFailurePolicy.disposition(
            statusCode: statusCode,
            responseData: responseData
        )
    }

    var errorDescription: String? {
        "Trakt token refresh failed with status \(statusCode): \(diagnostic)"
    }
}

struct TraktAuthenticationCredentialIdentity: Equatable {
    let owner: UUID
    let accountBoundaryGeneration: UInt64
    let userId: String
    let accessToken: String
    let refreshToken: String?
}

struct TraktAuthenticationRequiredLatchStore {
    private var identities: [UUID: TraktAuthenticationCredentialIdentity] = [:]
    private var presentedOwners = Set<UUID>()

    mutating func install(
        failedIdentity: TraktAuthenticationCredentialIdentity,
        currentIdentity: TraktAuthenticationCredentialIdentity
    ) -> Bool {
        guard failedIdentity == currentIdentity else { return false }
        guard identities[failedIdentity.owner] != failedIdentity else { return false }
        identities[failedIdentity.owner] = failedIdentity
        presentedOwners.remove(failedIdentity.owner)
        return true
    }

    mutating func blocks(_ currentIdentity: TraktAuthenticationCredentialIdentity) -> Bool {
        guard let identity = identities[currentIdentity.owner] else { return false }
        guard identity == currentIdentity else {
            identities.removeValue(forKey: currentIdentity.owner)
            presentedOwners.remove(currentIdentity.owner)
            return false
        }
        return true
    }

    mutating func shouldPresent(
        _ currentIdentity: TraktAuthenticationCredentialIdentity
    ) -> Bool {
        guard blocks(currentIdentity),
              !presentedOwners.contains(currentIdentity.owner) else {
            return false
        }
        presentedOwners.insert(currentIdentity.owner)
        return true
    }

    func hasLatch(for owner: UUID) -> Bool {
        identities[owner] != nil
    }

    mutating func deactivate(_ owner: UUID) {
        presentedOwners.remove(owner)
    }

    mutating func clear(_ owner: UUID) {
        identities.removeValue(forKey: owner)
        presentedOwners.remove(owner)
    }
}

struct TraktAuthenticationRequiredError: LocalizedError {
    var errorDescription: String? {
        "Trakt session expired. Reconnect Trakt in Settings."
    }
}

enum TrackerCredentialStoragePolicy {
    static let primarySynchronizable = false
    static let legacySynchronizable = true
}

private enum TrackerCredentialVault {
    private struct Credentials: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?

        let username: String?
        let userId: String?
    }

    private static let service = "app.Eclipse.Soupy.tracker-credentials"
    private static let maximumCredentialBytes = 128 * 1_024
    private static let maximumIdentityBytes = 1_024
    private static let maximumEncodedCredentialBytes = 384 * 1_024

    enum HydrationResult {
        case found(TrackerAccount, identityIsKeychainBound: Bool)

        case absent
        case temporarilyUnavailable(OSStatus)
    }

    enum IdentityBoundDiscoveryResult {
        case found(TrackerAccount)

        case notRecoverable
        case temporarilyUnavailable(OSStatus)
    }

    static func store(_ account: TrackerAccount, profileID: UUID) -> Bool {
        let credentials = Credentials(
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            expiresAt: account.expiresAt,
            username: account.username,
            userId: account.userId
        )
        guard !credentials.accessToken.isEmpty,
              credentials.accessToken.utf8.count <= maximumCredentialBytes,
              (credentials.refreshToken?.utf8.count ?? 0) <= maximumCredentialBytes,
              !account.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !account.userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              account.username.utf8.count <= maximumIdentityBytes,
              account.userId.utf8.count <= maximumIdentityBytes,
              let data = try? JSONEncoder().encode(credentials),
              data.count <= maximumEncodedCredentialBytes else { return false }

        let lookup = query(
            for: account.service,
            profileID: profileID,
            synchronizable: TrackerCredentialStoragePolicy.primarySynchronizable
        )
        let updatedValues: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, updatedValues as CFDictionary)
        if updateStatus == errSecSuccess {
            _ = removeLegacySynchronizable(account.service, profileID: profileID)
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }

        var attributes = lookup
        attributes.merge(updatedValues) { _, new in new }
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { return false }
        _ = removeLegacySynchronizable(account.service, profileID: profileID)
        return true
    }

    static func hydrate(_ account: TrackerAccount, profileID: UUID) -> HydrationResult {
        switch hydrate(
            account,
            profileID: profileID,
            synchronizable: TrackerCredentialStoragePolicy.primarySynchronizable
        ) {
        case .found(let hydrated, let identityIsKeychainBound):
            return .found(hydrated, identityIsKeychainBound: identityIsKeychainBound)
        case .temporarilyUnavailable(let status):
            return .temporarilyUnavailable(status)
        case .absent:
            break
        }

        let legacy = hydrate(
            account,
            profileID: profileID,
            synchronizable: TrackerCredentialStoragePolicy.legacySynchronizable
        )
        guard case .found(let hydrated, let identityIsKeychainBound) = legacy else {
            return legacy
        }

        if store(hydrated, profileID: profileID) {
            return .found(hydrated, identityIsKeychainBound: identityIsKeychainBound)
        }
        return .temporarilyUnavailable(errSecNotAvailable)
    }

    private static func hydrate(
        _ account: TrackerAccount,
        profileID: UUID,
        synchronizable: Bool
    ) -> HydrationResult {
        var attributes = query(
            for: account.service,
            profileID: profileID,
            synchronizable: synchronizable
        )
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess else {
            return status == errSecItemNotFound
                ? .absent
                : .temporarilyUnavailable(status)
        }
        guard let data = result as? Data,
              data.count <= maximumEncodedCredentialBytes,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
              !credentials.accessToken.isEmpty,
              credentials.accessToken.utf8.count <= maximumCredentialBytes,
              (credentials.refreshToken?.utf8.count ?? 0) <= maximumCredentialBytes else {

            return .temporarilyUnavailable(errSecDecode)
        }

        let hasStoredUsername = credentials.username != nil
        let hasStoredUserId = credentials.userId != nil
        guard hasStoredUsername == hasStoredUserId else {

            return .temporarilyUnavailable(errSecDecode)
        }

        let identityIsKeychainBound = hasStoredUsername && hasStoredUserId
        let username: String
        let userId: String
        if identityIsKeychainBound {
            guard let storedUsername = credentials.username,
                  let storedUserId = credentials.userId,
                  !storedUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !storedUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  storedUsername.utf8.count <= maximumIdentityBytes,
                  storedUserId.utf8.count <= maximumIdentityBytes else {
                return .temporarilyUnavailable(errSecDecode)
            }
            username = storedUsername
            userId = storedUserId
        } else {

            guard !account.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !account.userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  account.username.utf8.count <= maximumIdentityBytes,
                  account.userId.utf8.count <= maximumIdentityBytes else {
                return .temporarilyUnavailable(errSecDecode)
            }
            username = account.username
            userId = account.userId
        }

        return .found(
            TrackerAccount(
                service: account.service,
                username: username,
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken,
                expiresAt: credentials.expiresAt,
                userId: userId,
                isConnected: true
            ),
            identityIsKeychainBound: identityIsKeychainBound
        )
    }

    static func discoverIdentityBound(
        _ serviceType: TrackerService,
        profileID: UUID
    ) -> IdentityBoundDiscoveryResult {
        let placeholder = TrackerAccount(
            service: serviceType,
            username: "",
            accessToken: "",
            refreshToken: nil,
            expiresAt: nil,
            userId: "",
            isConnected: true
        )
        switch hydrate(placeholder, profileID: profileID) {
        case .found(let account, let identityIsKeychainBound):
            return identityIsKeychainBound ? .found(account) : .notRecoverable
        case .absent:
            return .notRecoverable
        case .temporarilyUnavailable(let status):
            return .temporarilyUnavailable(status)
        }
    }

    @discardableResult
    static func remove(_ serviceType: TrackerService, profileID: UUID) -> Bool {
        let synchronizedStatus = SecItemDelete(
            query(
                for: serviceType,
                profileID: profileID,
                synchronizable: TrackerCredentialStoragePolicy.legacySynchronizable
            ) as CFDictionary
        )
        let legacyStatus = SecItemDelete(
            query(
                for: serviceType,
                profileID: profileID,
                synchronizable: TrackerCredentialStoragePolicy.primarySynchronizable
            ) as CFDictionary
        )
        return deletionSucceeded(synchronizedStatus) && deletionSucceeded(legacyStatus)
    }

    static func accountName(for serviceType: TrackerService, profileID: UUID) -> String {
        guard profileID != ProfileManager.defaultProfileID else { return serviceType.rawValue }
        return "\(serviceType.rawValue)#\(ProfileScopedStorage.token(for: profileID))"
    }

    private static func query(
        for serviceType: TrackerService,
        profileID: UUID,
        synchronizable: Bool
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName(for: serviceType, profileID: profileID),
            kSecAttrSynchronizable as String: synchronizable
        ]
    }

    @discardableResult
    private static func removeLegacySynchronizable(
        _ serviceType: TrackerService,
        profileID: UUID
    ) -> Bool {
        deletionSucceeded(
            SecItemDelete(
                query(
                    for: serviceType,
                    profileID: profileID,
                    synchronizable: TrackerCredentialStoragePolicy.legacySynchronizable
                ) as CFDictionary
            )
        )
    }

    private static func deletionSucceeded(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }
}

private enum TrackerRequestProvider: Hashable {
    case anilist
    case myAnimeList
    case trakt
}

struct TrackerRateLimitHeaderPolicy {
    static let maximumDelay: TimeInterval = 120

    static func retryDelay(_ rawValue: String?, fallback: TimeInterval = 5) -> TimeInterval {
        guard let rawValue,
              let parsed = TimeInterval(rawValue),
              parsed.isFinite else {
            return fallback
        }
        return min(max(parsed, 1), maximumDelay)
    }

    static func minimumSpacing(_ rawLimit: String?) -> TimeInterval? {
        guard let rawLimit,
              let limit = Double(rawLimit),
              limit.isFinite,
              limit > 0 else {
            return nil
        }
        let calculated = 60 / limit
        guard calculated.isFinite else { return nil }
        return min(max(calculated, 0.8), maximumDelay)
    }

    static func resetDelay(_ rawReset: String?, now: Date) -> TimeInterval? {
        guard let rawReset,
              let reset = TimeInterval(rawReset),
              reset.isFinite else {
            return nil
        }
        let delay = reset - now.timeIntervalSince1970
        guard delay.isFinite, delay > 0, delay <= maximumDelay else { return nil }
        return delay
    }

    static func sleepNanoseconds(for delay: TimeInterval) -> UInt64? {
        guard delay.isFinite,
              delay >= 0,
              delay <= maximumDelay else {
            return nil
        }
        let nanoseconds = (delay * 1_000_000_000).rounded(.up)
        guard nanoseconds.isFinite else { return nil }
        return UInt64(exactly: nanoseconds)
    }

    static func displaySeconds(for delay: TimeInterval) -> Int? {
        guard delay.isFinite,
              delay >= 0,
              delay <= maximumDelay else {
            return nil
        }
        return Int(exactly: delay.rounded(.up))
    }
}

struct TrackerWatchSyncDedupeRegistration: Equatable {
    fileprivate let key: String
    fileprivate let attemptID: UUID
}

struct TrackerWatchSyncDedupeGate {
    private enum Entry {
        case inFlight(startedAt: Date, attemptID: UUID)
        case completed(at: Date)

        var date: Date {
            switch self {
            case .inFlight(let startedAt, _): startedAt
            case .completed(let completedAt): completedAt
            }
        }
    }

    private var entries: [String: Entry] = [:]

    mutating func begin(
        key: String,
        now: Date,
        completedInterval: TimeInterval,
        staleInFlightInterval: TimeInterval
    ) -> TrackerWatchSyncDedupeRegistration? {
        entries = entries.filter { _, entry in
            switch entry {
            case .inFlight:
                return now.timeIntervalSince(entry.date) < staleInFlightInterval
            case .completed:
                return now.timeIntervalSince(entry.date) < completedInterval
            }
        }

        guard entries[key] == nil else { return nil }
        let registration = TrackerWatchSyncDedupeRegistration(
            key: key,
            attemptID: UUID()
        )
        entries[key] = .inFlight(
            startedAt: now,
            attemptID: registration.attemptID
        )
        return registration
    }

    mutating func finish(
        registration: TrackerWatchSyncDedupeRegistration,
        succeeded: Bool,
        now: Date
    ) {
        guard case .inFlight(_, let attemptID) = entries[registration.key],
              attemptID == registration.attemptID else { return }
        if succeeded {
            entries[registration.key] = .completed(at: now)
        } else {
            entries.removeValue(forKey: registration.key)
        }
    }
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
        if delay > 0.001,
           let nanoseconds = TrackerRateLimitHeaderPolicy.sleepNanoseconds(for: delay) {
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    func recordResponse(provider: TrackerRequestProvider, response: HTTPURLResponse) -> TimeInterval? {
        if provider == .anilist,
           let spacing = TrackerRateLimitHeaderPolicy.minimumSpacing(
            response.value(forHTTPHeaderField: "X-RateLimit-Limit")
           ) {
            minimumSpacing[provider] = spacing
        }

        if response.statusCode == 429 {
            let pause = TrackerRateLimitHeaderPolicy.retryDelay(
                response.value(forHTTPHeaderField: "Retry-After")
            )
            nextAllowedAt[provider] = max(nextAllowedAt[provider] ?? .distantPast, Date().addingTimeInterval(pause))
            return pause
        }

        let now = Date()
        if provider == .anilist,
           let remainingValue = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           let remaining = Int(remainingValue),
           remaining <= 1,
           let resetDelay = TrackerRateLimitHeaderPolicy.resetDelay(
            response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
            now: now
           ) {
            let resetDate = now.addingTimeInterval(resetDelay)
            nextAllowedAt[provider] = max(nextAllowedAt[provider] ?? .distantPast, resetDate)
        }

        return nil
    }
}

private struct AniListRatingSyncResponse {
    let statusCode: Int
    let diagnostic: String
    let graphQLError: String?

    var succeeded: Bool {
        (200...299).contains(statusCode) && graphQLError == nil
    }
}

enum TrackerRemoteProgressBoundary {
    static let maximumRemoteEntryCount = 100_000
    static let maximumPageCount = 1_000

    static func positiveIdentifier(_ value: Int?) -> Int? {
        guard let value, ProgressPersistencePolicy.validPositiveIdentifier(value) else {
            return nil
        }
        return value
    }

    static func watchedEpisodeCount(
        progress: Int,
        totalEpisodes: Int?,
        status: String
    ) -> Int? {
        guard (0...ProgressPersistencePolicy.maximumBulkEpisodeMutationCount).contains(progress),
              totalEpisodes.map({
                  (0...ProgressPersistencePolicy.maximumBulkEpisodeMutationCount).contains($0)
              }) ?? true else {
            return nil
        }
        let completed = status.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "completed"
        return completed ? max(progress, totalEpisodes ?? 0) : progress
    }

    static func pageCallCount(itemCount: Int, pageSize: Int) -> Int? {
        guard itemCount >= 0,
              itemCount <= maximumRemoteEntryCount,
              pageSize > 0 else { return nil }
        guard itemCount > 0 else { return 0 }
        let quotient = itemCount / pageSize
        let remainder = itemCount % pageSize
        let pages = quotient + (remainder == 0 ? 0 : 1)
        return pages <= maximumPageCount ? pages : nil
    }

    static func isAllowedMALPageURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "api.myanimelist.net"
            && components.port == nil
            && components.path == "/v2/users/@me/animelist"
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

private extension RemoteAnimeProgress {
    init?(
        validatingAniListID anilistId: Int?,
        malID malId: Int?,
        title: String,
        status: String,
        progress: Int,
        totalEpisodes: Int?
    ) {
        let safeAniListID = TrackerRemoteProgressBoundary.positiveIdentifier(anilistId)
        let safeMALID = TrackerRemoteProgressBoundary.positiveIdentifier(malId)
        guard (anilistId == nil || safeAniListID != nil),
              (malId == nil || safeMALID != nil),
              safeAniListID != nil || safeMALID != nil,
              TrackerRemoteProgressBoundary.watchedEpisodeCount(
                progress: progress,
                totalEpisodes: totalEpisodes,
                status: status
              ) != nil else {
            return nil
        }
        self.anilistId = safeAniListID
        self.malId = safeMALID
        self.title = String(title.prefix(1_024))
        self.status = String(status.prefix(64))
        self.progress = progress
        self.totalEpisodes = totalEpisodes
    }
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

    let owner: UUID

    var accountSnapshots: [TrackerAccount] = []
    let preview: TrackerSyncPreview
    var animeEntries: [RemoteAnimeProgress] = []
#if !os(tvOS)
    var mangaEntries: [RemoteMangaProgress] = []
#endif
}

private struct TraktHistoryWriteReceipt: Codable {
    let owner: UUID
    let watchedAt: Date
    var lastAttemptAt: Date
    var confirmedAt: Date?

    var receiptID: UUID?
}

enum TraktHistoryReceiptDecision: Equatable {
    case suppressConfirmed
    case waitForReconciliation
    case reconcile
}

struct TraktHistoryReceiptReconciliationPolicy {
    static func canonicalMinute(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return date }
        return Date(timeIntervalSince1970: floor(seconds / 60) * 60)
    }

    static func containsReceipt(
        watchedAt: Date,
        historyWatchedAt: [Date]
    ) -> Bool {
        let receiptMinute = canonicalMinute(watchedAt)
        return historyWatchedAt.contains {
            canonicalMinute($0) == receiptMinute
        }
    }

    static func decision(
        lastAttemptAt: Date,
        confirmedAt: Date?,
        now: Date,
        reconciliationDelay: TimeInterval,
        confirmedInterval: TimeInterval
    ) -> TraktHistoryReceiptDecision {
        if let confirmedAt,
           now.timeIntervalSince(confirmedAt) < confirmedInterval {
            return .suppressConfirmed
        }
        if now.timeIntervalSince(lastAttemptAt) < reconciliationDelay {
            return .waitForReconciliation
        }
        return .reconcile
    }
}

private enum TraktHistoryWriteAttemptDisposition {
    case send
    case reconcile
    case suppressConfirmed
    case deferPending

    var ownsInFlightClaim: Bool {
        switch self {
        case .send, .reconcile:
            return true
        case .suppressConfirmed, .deferPending:
            return false
        }
    }
}

private struct TraktHistoryWriteAttempt {
    let key: String
    let watchedAt: Date
    let receiptID: UUID
    let disposition: TraktHistoryWriteAttemptDisposition
}

private enum TraktHistoryReconciliationResult {
    case found
    case absent(account: TrackerAccount)
    case unavailable
}

private struct TraktHistoryEntry: Decodable {
    let watchedAt: String

    enum CodingKeys: String, CodingKey {
        case watchedAt = "watched_at"
    }
}

struct TrackerPrivateCloudExportAuthority: Equatable {
    let profileID: UUID
    let rosterGeneration: UInt64
    let operationGeneration: UInt64
    let accountBoundaryGeneration: UInt64
    let serviceGenerations: [TrackerService: UInt64]
}

enum TrackerPrivateCloudCredentialMaterialization {
    case found(TrackerAccount)
    case unavailable
}

enum TrackerPrivateCloudExportPolicy {
    static func incomingCredentialIsAuthoritative(_ account: TrackerAccount) -> Bool {
        account.isConnected && !account.accessToken.isEmpty
    }

    static func preferredCredentialBearingAccount(
        incoming: TrackerAccount,
        local: TrackerAccount?,
        credentialsAndRosterAreAuthoritative: Bool
    ) -> TrackerAccount? {
        if credentialsAndRosterAreAuthoritative,
           incomingCredentialIsAuthoritative(incoming) {
            return incoming
        }
        guard let local,
              local.isConnected,
              !local.accessToken.isEmpty else {
            return incomingCredentialIsAuthoritative(incoming) ? incoming : nil
        }
        return local
    }

    static func disconnectedTombstone(_ account: TrackerAccount) -> TrackerAccount {
        var tombstone = account
        tombstone.isConnected = false
        tombstone.accessToken = ""
        tombstone.refreshToken = nil
        tombstone.expiresAt = nil
        return tombstone
    }

    static func omittedConnectedAccounts(
        existing: [TrackerAccount],
        incoming: [TrackerAccount],
        credentialsAndRosterAreAuthoritative: Bool
    ) -> [TrackerAccount] {
        guard credentialsAndRosterAreAuthoritative else { return [] }
        let incomingServices = Set(incoming.map(\.service))
        return existing.filter {
            $0.isConnected && !incomingServices.contains($0.service)
        }
    }

    static func materializedState(
        from state: TrackerState,
        hydrate: (TrackerAccount) -> TrackerPrivateCloudCredentialMaterialization
    ) -> TrackerState? {
        var materialized = state
        var accounts: [TrackerAccount] = []
        accounts.reserveCapacity(state.accounts.count)

        for original in state.accounts {
            guard original.isConnected else {
                var disconnected = original
                disconnected.accessToken = ""
                disconnected.refreshToken = nil
                disconnected.expiresAt = nil
                accounts.append(disconnected)
                continue
            }

            guard case .found(let hydrated) = hydrate(original),
                  hydrated.service == original.service,
                  hydrated.isConnected,
                  !hydrated.accessToken.isEmpty else {
                return nil
            }
            accounts.append(hydrated)
        }

        materialized.accounts = accounts
        return materialized
    }

    static func authorityRemainedCurrent(
        before: TrackerPrivateCloudExportAuthority,
        after: TrackerPrivateCloudExportAuthority,
        profileStillExists: Bool,
        cleanupIsPending: Bool
    ) -> Bool {
        before == after && profileStillExists && !cleanupIsPending
    }
}

enum TrackerPrivateCloudRestoreTransaction {
    static func apply(
        services: [TrackerService] = TrackerService.allCases,
        previous: [TrackerService: TrackerAccount],
        incoming: [TrackerService: TrackerAccount],
        applyCredential: (TrackerService, TrackerAccount?) -> Bool,
        persistTargetState: () -> Bool,
        authorityIsCurrent: () -> Bool,
        restoreCredential: (TrackerService, TrackerAccount?) -> Bool,
        restorePreviousState: () -> Bool
    ) -> Bool {
        func rollback() -> Bool {
            var succeeded = true
            for service in services.reversed() {
                succeeded = restoreCredential(service, previous[service]) && succeeded
            }
            return restorePreviousState() && succeeded
        }

        for service in services {
            guard authorityIsCurrent(),
                  applyCredential(service, incoming[service]) else {
                _ = rollback()
                return false
            }
        }
        guard authorityIsCurrent(), persistTargetState(), authorityIsCurrent() else {
            _ = rollback()
            return false
        }
        return true
    }
}

final class TrackerManager: NSObject, ObservableObject {
    static let shared = TrackerManager()
    private static let pendingCredentialDeletionDefaultsKey = "trackerPendingCredentialDeletions.v1"
    private static let pendingDiscardedProfileCleanupDefaultsKey = "trackerPendingDiscardedProfileCleanup.v1"
    private static let traktHistoryWriteReceiptsDefaultsKey = "traktHistoryWriteReceipts.v1"
    private static let maximumTrackerDeletionJournalBytes = 256 * 1_024
    private static let maximumCredentialDeletionMarkerCount = 512
    private static let maximumDiscardedProfileCleanupMarkerCount = 512
    private static let maximumTraktHistoryWriteReceiptBytes = 512 * 1_024
    private static let maximumTraktHistoryWriteReceiptCount = 512
    private static let maximumTrackerIdentityBytes = 1_024
    private static let maximumTrackerCredentialBytes = 128 * 1_024
    static let maximumPersistedTrackerStateBytes = 8 * 1_024 * 1_024

    @Published var trackerState: TrackerState = TrackerState()
    @Published var isAuthenticating = false
    @Published var authError: String?
    @Published var authenticationNotice: TrackerAuthenticationNotice?
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

    private var trackerStateURL: URL
    private var activeProfileID: UUID
    private let trackerStatePersistenceQueue = DispatchQueue(
        label: "app.eclipse.soupy.tracker-state-persistence",
        qos: .utility
    )
    private var webAuthSession: ASWebAuthenticationSession?

    private var unreadableTrackerStateProfileIDs = Set<UUID>()

    private var credentialHydrationPendingProfileIDs = Set<UUID>()

    private struct PendingTrackerStatePersistence {
        let id: UUID
        let accountBoundaryGeneration: UInt64
        var state: TrackerState
    }
    private var pendingTrackerStatePersistence: [UUID: PendingTrackerStatePersistence] = [:]

    private var pendingCredentialOnlyAccounts: [UUID: [TrackerService: TrackerAccount]] = [:]

    private var pendingCredentialDeletions: [UUID: Set<TrackerService>] = [:]

    private var accountBoundaryGenerations: [UUID: UInt64] = [:]

    private var trackerServiceGenerations: [UUID: [TrackerService: UInt64]] = [:]

    private var tentativelyPreservedAccountBoundaryProfileIDs = Set<UUID>()

    private var accountBoundaryQuarantinedProfileIDs = Set<UUID>()

    private var accountBoundaryRecoveryBlocksAllTrackerOperations = false

    private var pendingDiscardedProfileCleanupIDs = Set<UUID>()

    private var credentialDeletionJournalIsUnreadable = false
    private var discardedProfileCleanupJournalIsUnreadable = false

    private var unpersistedCredentialDeletionAuthority: [UUID: Set<TrackerService>] = [:]
    private var unpersistedDiscardedProfileCleanupIDs = Set<UUID>()

    private var trackerStateReloadPendingAfterDeletionJournalRecovery = false
    private let trackerStateStatusLock = NSLock()

    private let credentialDeletionPersistenceLock = NSLock()
    private struct TrackerProfileOperationAuthority {
        let owner: UUID
        let operationGeneration: UInt64
    }

    private struct TrackerOperationAuthority {
        let owner: UUID
        let operationGeneration: UInt64
        let accountBoundaryGeneration: UInt64
        let serviceGeneration: UInt64
        let progressAuthority: ProgressManager.ProfileMutationAuthority?
        let service: TrackerService
        let userId: String
        let accessToken: String
        let refreshToken: String?

        func matches(_ account: TrackerAccount) -> Bool {
            service == account.service
                && userId == account.userId
                && accessToken == account.accessToken
                && refreshToken == account.refreshToken
        }

        func replacingCredential(with account: TrackerAccount) -> TrackerOperationAuthority {
            TrackerOperationAuthority(
                owner: owner,
                operationGeneration: operationGeneration,
                accountBoundaryGeneration: accountBoundaryGeneration,
                serviceGeneration: serviceGeneration,
                progressAuthority: progressAuthority,
                service: account.service,
                userId: account.userId,
                accessToken: account.accessToken,
                refreshToken: account.refreshToken
            )
        }
    }

    private struct WebAuthenticationAuthority {
        let id: UUID
        let owner: UUID
        let service: TrackerService
        let accountBoundaryGeneration: UInt64
        let serviceGeneration: UInt64
    }
    private var webAuthenticationAuthority: WebAuthenticationAuthority?
#if os(tvOS)
    private var traktDeviceAuthTask: Task<Void, Never>?
#endif

    private var anilistIdCache: [Int: Int] = [:]
    private let anilistIdCacheQueue = DispatchQueue(label: "app.eclipse.soupy.anilistIdCache")

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

    private var anilistSeasonIdCache: [String: Int] = [:]
    private let anilistSeasonIdCacheQueue = DispatchQueue(label: "app.eclipse.soupy.anilistSeasonIdCache")

    private var backupRestoreSyncSuppressionCount = 0
    // Revokes queued tracker operations across every profile activation and
    // both boundaries of a restore-suppression window. The latter matters for
    // work captured while nested restore code is still suppressed.
    private var trackerOperationGeneration: UInt64 = 0
    private let backupRestoreSyncQueue = DispatchQueue(label: "app.eclipse.soupy.backupRestoreSync")
    private var watchSyncDedupeGate = TrackerWatchSyncDedupeGate()
    private let recentWatchSyncQueue = DispatchQueue(label: "app.eclipse.soupy.recentWatchSync")
    private let watchSyncDedupeInterval: TimeInterval = 60
    private var recentTraktPlaybackSyncKeys: [String: Date] = [:]
    private let recentTraktPlaybackSyncQueue = DispatchQueue(label: "app.eclipse.soupy.recentTraktPlaybackSync")
    private let traktPlaybackSyncInterval: TimeInterval = 30
    private var traktHistoryWriteReceipts: [String: TraktHistoryWriteReceipt] = [:]
    private var traktHistoryWritesInFlight: [String: UUID] = [:]
    private let traktHistoryWriteReceiptQueue = DispatchQueue(label: "app.eclipse.soupy.traktHistoryWriteReceipts")

    private var traktHistoryReceiptJournalIsUnreadable = false
    private var traktHistoryReceiptJournalNeedsPersistence = false
    private let traktHistoryReceiptFutureTolerance: TimeInterval = 5 * 60
    private let traktHistoryReceiptTimeToLive: TimeInterval = 60 * 60 * 24 * 7
    private let traktHistoryReconciliationDelay: TimeInterval = 2 * 60
    private let traktHistoryReconciliationPageLimit = 100
    private let traktHistoryReconciliationMaximumPages = 5
    private let traktHistoryReconciliationMaximumPageBytes = 512 * 1_024
    private var traktMediaIdCache: [String: Int] = [:]
    private let traktMediaIdCacheQueue = DispatchQueue(label: "app.eclipse.soupy.traktMediaIdCache")

    private struct TraktTokenRefreshAttempt {
        let id: UUID
        let accountBoundaryGeneration: UInt64
        let serviceGeneration: UInt64
        let userId: String
        let accessToken: String
        let refreshToken: String
        let task: Task<TrackerAccount, Error>

        func matches(
            account: TrackerAccount,
            refreshToken: String,
            accountBoundaryGeneration: UInt64,
            serviceGeneration: UInt64
        ) -> Bool {
            self.accountBoundaryGeneration == accountBoundaryGeneration
                && self.serviceGeneration == serviceGeneration
                && userId == account.userId
                && accessToken == account.accessToken
                && self.refreshToken == refreshToken
        }
    }
    private var traktTokenRefreshTasks: [UUID: TraktTokenRefreshAttempt] = [:]
    private let traktAuthenticationRequiredLatchLock = NSLock()
    private var traktAuthenticationRequiredLatches = TraktAuthenticationRequiredLatchStore()

    private struct MALTokenRefreshAttempt {
        let id: UUID
        let accountBoundaryGeneration: UInt64
        let serviceGeneration: UInt64
        let userId: String
        let accessToken: String
        let refreshToken: String
        let task: Task<TrackerAccount, Error>

        func matches(
            account: TrackerAccount,
            refreshToken: String,
            accountBoundaryGeneration: UInt64,
            serviceGeneration: UInt64
        ) -> Bool {
            self.accountBoundaryGeneration == accountBoundaryGeneration
                && self.serviceGeneration == serviceGeneration
                && userId == account.userId
                && accessToken == account.accessToken
                && self.refreshToken == refreshToken
        }
    }
    private var malTokenRefreshTasks: [UUID: MALTokenRefreshAttempt] = [:]
    private var traktContinueWatchingCache: (owner: UUID, accountUserId: String, fetchedAt: Date, items: [ContinueWatchingItem])?
    private let traktContinueWatchingCacheQueue = DispatchQueue(label: "app.eclipse.soupy.traktContinueWatchingCache")
    private let traktContinueWatchingCacheTTL: TimeInterval = 90
    private var traktCommentsCache: [String: (fetchedAt: Date, items: [TraktCommentReview])] = [:]
    private var traktRatingsCache: [String: (fetchedAt: Date, rating: TraktMediaRating)] = [:]
    private var traktRelatedCache: [String: (fetchedAt: Date, items: [TMDBSearchResult])] = [:]
    private let traktFeatureCacheQueue = DispatchQueue(label: "app.eclipse.soupy.traktFeatureCache")
    private let traktFeatureCacheTTL: TimeInterval = 10 * 60
    private var traktScrobbleLastActionByKey: [String: TraktScrobbleAction] = [:]
    private var traktScrobbleLastStampByKey: [String: (action: TraktScrobbleAction, progress: Double, sentAt: Date)] = [:]
    private var traktScrobblePendingByKey: [String: (id: UUID, action: TraktScrobbleAction, progress: Double, queuedAt: Date)] = [:]
    private var traktScrobbleFailureStampByKey: [String: (action: TraktScrobbleAction, progress: Double, failedAt: Date)] = [:]
    private let traktScrobbleQueue = DispatchQueue(label: "app.eclipse.soupy.traktScrobbleDedupe")
    private let traktScrobbleMinimumInterval: TimeInterval = 8
    private let traktScrobbleStartRefreshMinimumInterval: TimeInterval = 20
    private let traktScrobbleFailureCooldown: TimeInterval = 60
    private let traktScrobbleProgressWindow: Double = 1.5

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

    static func trackerAccountsAreStructurallyValid(
        _ accounts: [TrackerAccount]
    ) -> Bool {
        guard accounts.count <= TrackerService.allCases.count,
              Set(accounts.map(\.service)).count == accounts.count else {
            return false
        }

        return accounts.allSatisfy { account in
            let username = account.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let userId = account.userId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty,
                  !userId.isEmpty,
                  account.username.utf8.count <= maximumTrackerIdentityBytes,
                  account.userId.utf8.count <= maximumTrackerIdentityBytes,
                  account.accessToken.utf8.count <= maximumTrackerCredentialBytes else {
                return false
            }
            if let refreshToken = account.refreshToken,
               refreshToken.utf8.count > maximumTrackerCredentialBytes {
                return false
            }
            return true
        }
    }

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
        self.activeProfileID = ProfileManager.shared.activeProfileID
        self.trackerStateURL = Self.stateURL(for: ProfileManager.shared.activeProfileID)
        super.init()
        loadTraktHistoryWriteReceipts()
        loadPendingCredentialDeletionMarkers()
        loadPendingDiscardedProfileCleanupMarkers()
        retryPendingDiscardedProfileCleanup()
        let quarantinedProfileIDs = completeCommittedAccountBoundaryCleanupBeforeLoadingState()
        retryPendingCredentialDeletions()
        if accountBoundaryRecoveryBlocksStateAccess() {
            if trackerDeletionJournalsBlockOperations() {
                markTrackerStateReloadPendingAfterDeletionJournalRecovery()
            }
            trackerState = TrackerState()
        } else if quarantinedProfileIDs.contains(activeProfileID)
                    || discardedProfileCleanupIsPending(activeProfileID) {

            markTrackerStateUnreadable(activeProfileID)
            trackerState = TrackerState()
        } else {
            loadTrackerState()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(profileRosterDidChange),
            name: .profileListDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(retryActiveProfileCredentialHydration),
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(retryActiveProfileCredentialHydration),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
#if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(experimentalCloudRestoreRecoveryDidComplete),
            name: .experimentalCloudRestoreRecoveryDidComplete,
            object: nil
        )
#endif
    }

    private static func stateURL(for profileID: UUID) -> URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard profileID != ProfileManager.defaultProfileID else {
            return documentsDirectory.appendingPathComponent("TrackerState.json")
        }
        return documentsDirectory.appendingPathComponent(
            ProfileScopedStorage.documentFileName(
                base: "TrackerState",
                fileExtension: "json",
                profileID: profileID
            )
        )
    }

    private static func trackerDeletionJournalURL(fileName: String) -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = applicationSupport.appendingPathComponent("Eclipse", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory.appendingPathComponent(fileName, isDirectory: false)
        } catch {
            return nil
        }
    }

    private static var credentialDeletionJournalURL: URL? {
        trackerDeletionJournalURL(fileName: "TrackerCredentialDeletions.json")
    }

    private static var discardedProfileCleanupJournalURL: URL? {
        trackerDeletionJournalURL(fileName: "TrackerDiscardedProfileCleanup.json")
    }

    func switchProfile(to profileID: UUID) {
        guard profileID != activeProfileID else { return }
        withTraktAuthenticationRequiredLatches {
            $0.deactivate(activeProfileID)
        }
        abandonPendingTraktScrobbles(for: activeProfileID)
        invalidateTrackerOperationAuthority()
        flushPendingWrites(forProfile: activeProfileID)
        activeProfileID = profileID
        trackerStateURL = Self.stateURL(for: profileID)
        trackerState = TrackerState()
        invalidateTraktContinueWatchingCache()
        cachedSyncToolPlan = nil
        syncToolTask?.cancel()
        authError = nil
        authenticationNotice = nil
        if trackerDeletionJournalsBlockOperations() {
            markTrackerStateReloadPendingAfterDeletionJournalRecovery()
        }
        if accountBoundaryRecoveryBlocksStateAccess()
            || accountBoundaryIsQuarantined(profileID)
            || discardedProfileCleanupIsPending(profileID) {
            if !accountBoundaryRecoveryBlocksStateAccess() {
                markTrackerStateUnreadable(profileID)
            }
            return
        }
        if let pending = pendingTrackerState(forProfile: profileID) {

            trackerState = pending
        } else {
            loadTrackerState(forProfile: profileID)
        }
        presentLatchedTraktAuthenticationNoticeIfNeeded(owner: profileID)
    }

    func flushPendingWrites(forProfile outgoing: UUID) {
        saveTrackerState(forProfile: outgoing)
    }

    func trackerState(forProfile profileID: UUID) -> TrackerState? {
        guard !accountBoundaryRecoveryBlocksStateAccess(),
              !accountBoundaryIsQuarantined(profileID),
              !discardedProfileCleanupIsPending(profileID),
              !trackerStateIsUnreadable(profileID) else { return nil }
        guard profileID != activeProfileID else { return trackerState }
        if let pending = pendingTrackerState(forProfile: profileID) {
            return pending
        }
        return readPersistedTrackerState(forProfile: profileID)
    }

    func trackerStateForPrivateCloudExport(forProfile profileID: UUID) -> TrackerState? {
        guard ProfileManager.shared.rosterStoreIsReadable,
              ProfileManager.shared.profile(with: profileID) != nil,
              !accountBoundaryRecoveryBlocksStateAccess(),
              !accountBoundaryIsQuarantined(profileID),
              !discardedProfileCleanupIsPending(profileID),
              !isDiscarded(profileID),
              !isBackupRestoreSyncSuppressed(),
              let before = privateCloudExportAuthority(forProfile: profileID),
              let source = trackerState(forProfile: profileID),
              Self.trackerAccountsAreStructurallyValid(source.accounts),
              let materialized = TrackerPrivateCloudExportPolicy.materializedState(
                from: source,
                hydrate: { [weak self] account in
                    guard let self else { return .unavailable }
                    switch self.hydrateTrackerCredential(
                        account,
                        profileID: profileID
                    ) {
                    case .found(let hydrated, _):
                        return .found(hydrated)
                    case .absent, .temporarilyUnavailable:
                        return .unavailable
                    }
                }
              ),
              Self.trackerAccountsAreStructurallyValid(materialized.accounts),
              let encoded = try? JSONEncoder().encode(materialized),
              encoded.count <= Self.maximumPersistedTrackerStateBytes,
              let after = privateCloudExportAuthority(forProfile: profileID),
              TrackerPrivateCloudExportPolicy.authorityRemainedCurrent(
                before: before,
                after: after,
                profileStillExists: ProfileManager.shared.profile(with: profileID) != nil,
                cleanupIsPending: accountBoundaryRecoveryBlocksStateAccess()
                    || accountBoundaryIsQuarantined(profileID)
                    || discardedProfileCleanupIsPending(profileID)
                    || isDiscarded(profileID)
                    || isBackupRestoreSyncSuppressed()
              ) else {
            Logger.shared.log(
                "TrackerManager: private-cloud credential capture was unavailable for profile \(profileID)",
                type: "Tracker"
            )
            return nil
        }
        return materialized
    }

    private func privateCloudExportAuthority(
        forProfile profileID: UUID
    ) -> TrackerPrivateCloudExportAuthority? {
        guard ProfileManager.shared.rosterStoreIsReadable,
              ProfileManager.shared.profile(with: profileID) != nil,
              !trackerDeletionJournalsBlockOperations(),
              !accountBoundaryIsQuarantined(profileID),
              !discardedProfileCleanupIsPending(profileID),
              !isDiscarded(profileID) else {
            return nil
        }
        return TrackerPrivateCloudExportAuthority(
            profileID: profileID,
            rosterGeneration: ProfileManager.shared.rosterGeneration,
            operationGeneration: trackerOperationGenerationSnapshot(),
            accountBoundaryGeneration: accountBoundaryGeneration(for: profileID),
            serviceGenerations: Dictionary(
                uniqueKeysWithValues: TrackerService.allCases.map { service in
                    (service, trackerServiceGeneration(for: service, profileID: profileID))
                }
            )
        )
    }

    private enum PrivateCloudTrackerStateFileSnapshot {
        case missing
        case present(Data)
    }

    private func privateCloudTrackerStateFileSnapshot(
        forProfile profileID: UUID
    ) -> PrivateCloudTrackerStateFileSnapshot? {
        let url = Self.stateURL(for: profileID)
        return trackerStatePersistenceQueue.sync {
            guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count <= Self.maximumPersistedTrackerStateBytes else { return nil }
            return .present(data)
        }
    }

    private func persistPrivateCloudTrackerState(
        _ state: TrackerState,
        forProfile profileID: UUID
    ) -> Bool {
        var redacted = state
        redacted.accounts = state.accounts.map { account in
            var account = account
            account.accessToken = ""
            account.refreshToken = nil
            account.expiresAt = nil
            return account
        }
        guard let encoded = try? JSONEncoder().encode(redacted),
              encoded.count <= Self.maximumPersistedTrackerStateBytes else { return false }
        let url = Self.stateURL(for: profileID)
        return trackerStatePersistenceQueue.sync {
            do {
                try encoded.write(to: url, options: .atomic)
                return try Data(contentsOf: url, options: [.mappedIfSafe]) == encoded
            } catch {
                return false
            }
        }
    }

    private func restorePrivateCloudTrackerStateFile(
        _ snapshot: PrivateCloudTrackerStateFileSnapshot,
        forProfile profileID: UUID
    ) -> Bool {
        let url = Self.stateURL(for: profileID)
        return trackerStatePersistenceQueue.sync {
            do {
                switch snapshot {
                case .missing:
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    return !FileManager.default.fileExists(atPath: url.path)
                case .present(let data):
                    try data.write(to: url, options: .atomic)
                    return try Data(contentsOf: url, options: [.mappedIfSafe]) == data
                }
            } catch {
                return false
            }
        }
    }

    private func privateCloudTrackerCredentialSnapshot(
        state: TrackerState?,
        profileID: UUID
    ) -> [TrackerService: TrackerAccount]? {
        var result: [TrackerService: TrackerAccount] = [:]
        for service in TrackerService.allCases {
            if let account = state?.accounts.first(where: {
                $0.service == service && $0.isConnected
            }) {
                switch TrackerCredentialVault.hydrate(account, profileID: profileID) {
                case .found(let hydrated, _):
                    result[service] = hydrated
                    continue
                case .temporarilyUnavailable:
                    return nil
                case .absent:
                    break
                }
            }
            switch TrackerCredentialVault.discoverIdentityBound(service, profileID: profileID) {
            case .found(let account):
                result[service] = account
            case .notRecoverable:
                break
            case .temporarilyUnavailable:
                return nil
            }
        }
        return result
    }

    private func privateCloudTrackerCredentialMatches(
        _ expected: TrackerAccount?,
        service: TrackerService,
        profileID: UUID
    ) -> Bool {
        switch (expected, TrackerCredentialVault.discoverIdentityBound(service, profileID: profileID)) {
        case (.none, .notRecoverable):
            return true
        case (.some(let expected), .found(let actual)):
            return expected.service == actual.service
                && expected.username == actual.username
                && expected.accessToken == actual.accessToken
                && expected.refreshToken == actual.refreshToken
                && expected.expiresAt == actual.expiresAt
                && expected.userId == actual.userId
                && expected.isConnected == actual.isConnected
        case (.none, .found), (.none, .temporarilyUnavailable),
             (.some, .notRecoverable), (.some, .temporarilyUnavailable):
            return false
        }
    }

    private func replacePrivateCloudTrackerCredential(
        _ account: TrackerAccount?,
        service: TrackerService,
        profileID: UUID
    ) -> Bool {
        let mutated: Bool
        if let account {
            mutated = account.service == service
                && TrackerCredentialVault.store(account, profileID: profileID)
        } else {
            mutated = TrackerCredentialVault.remove(service, profileID: profileID)
        }
        return mutated && privateCloudTrackerCredentialMatches(
            account,
            service: service,
            profileID: profileID
        )
    }

    private func applyPrivateCloudTrackerState(
        _ incoming: TrackerState,
        forProfile profileID: UUID,
        permitsUnrosteredProfile: Bool
    ) -> Bool {
        guard permitsUnrosteredProfile
                || ProfileManager.shared.profile(with: profileID) != nil,
              let previousStateFile = privateCloudTrackerStateFileSnapshot(
                forProfile: profileID
              ) else { return false }
        let previousState = trackerState(forProfile: profileID)
        let rosterGeneration = ProfileManager.shared.rosterGeneration
        let operationGeneration = trackerOperationGenerationSnapshot()
        let accountGeneration = accountBoundaryGeneration(for: profileID)
        let serviceGenerations = Dictionary(
            uniqueKeysWithValues: TrackerService.allCases.map {
                ($0, trackerServiceGeneration(for: $0, profileID: profileID))
            }
        )
        let pending = retainPendingTrackerState(incoming, forProfile: profileID)
        credentialDeletionPersistenceLock.lock()
        guard let previousCredentials = privateCloudTrackerCredentialSnapshot(
            state: previousState,
            profileID: profileID
        ) else {
            credentialDeletionPersistenceLock.unlock()
            clearPendingTrackerState(forProfile: profileID, matching: pending.id)
            return false
        }
        let incomingCredentials = Dictionary(
            uniqueKeysWithValues: incoming.accounts.compactMap { account in
                account.isConnected ? (account.service, account) : nil
            }
        )
        let authorityIsCurrent = {
            self.isBackupRestoreSyncSuppressed()
                && !self.trackerDeletionJournalsBlockOperations()
                && !self.accountBoundaryIsQuarantined(profileID)
                && !self.discardedProfileCleanupIsPending(profileID)
                && !self.isDiscarded(profileID)
                && ProfileManager.shared.rosterGeneration == rosterGeneration
                && (permitsUnrosteredProfile
                    || ProfileManager.shared.profile(with: profileID) != nil)
                && Self.trackerOperationAuthorityIsCurrent(
                    authorityGeneration: operationGeneration,
                    currentGeneration: self.trackerOperationGenerationSnapshot()
                )
                && self.accountBoundaryGenerationIsCurrent(
                    accountGeneration,
                    for: profileID
                )
                && serviceGenerations.allSatisfy {
                    self.trackerServiceGenerationIsCurrent(
                        $0.value,
                        service: $0.key,
                        profileID: profileID
                    )
                }
                && self.pendingTrackerStateAuthorityIsCurrent(
                    pending,
                    forProfile: profileID
                )
        }
        let succeeded = TrackerPrivateCloudRestoreTransaction.apply(
            previous: previousCredentials,
            incoming: incomingCredentials,
            applyCredential: { service, account in
                self.replacePrivateCloudTrackerCredential(
                    account,
                    service: service,
                    profileID: profileID
                )
            },
            persistTargetState: {
                self.persistPrivateCloudTrackerState(incoming, forProfile: profileID)
            },
            authorityIsCurrent: authorityIsCurrent,
            restoreCredential: { service, account in
                self.replacePrivateCloudTrackerCredential(
                    account,
                    service: service,
                    profileID: profileID
                )
            },
            restorePreviousState: {
                self.restorePrivateCloudTrackerStateFile(
                    previousStateFile,
                    forProfile: profileID
                )
            }
        )
        credentialDeletionPersistenceLock.unlock()
        clearPendingTrackerState(forProfile: profileID, matching: pending.id)
        for service in TrackerService.allCases {
            _ = invalidateTrackerServiceAuthority(service, profileID: profileID)
        }
        guard succeeded else { return false }
        clearCredentialHydrationPending(profileID)
        if profileID == activeProfileID {
            trackerState = incoming
            invalidateTraktContinueWatchingCache()
            cachedSyncToolPlan = nil
        }
        return true
    }

    @discardableResult
    func applyRestoredTrackerState(
        _ incoming: TrackerState,
        forProfile profileID: UUID,
        credentialsAndRosterAreAuthoritative: Bool = false,
        permitsUnrosteredProfile: Bool = false
    ) -> Bool {
        guard isBackupRestoreSyncSuppressed(),
              !trackerDeletionJournalsBlockOperations(),
              !accountBoundaryIsQuarantined(profileID),
              !discardedProfileCleanupIsPending(profileID),
              !isDiscarded(profileID),
              Self.trackerAccountsAreStructurallyValid(incoming.accounts),
              !credentialsAndRosterAreAuthoritative
                || incoming.accounts.allSatisfy({
                    !$0.isConnected
                        || TrackerPrivateCloudExportPolicy.incomingCredentialIsAuthoritative($0)
                }) else {
            Logger.shared.log(
                "TrackerManager: refused malformed tracker-account metadata while restoring profile \(profileID)",
                type: "Error"
            )
            return false
        }
        if credentialsAndRosterAreAuthoritative {
            return applyPrivateCloudTrackerState(
                incoming,
                forProfile: profileID,
                permitsUnrosteredProfile: permitsUnrosteredProfile
            )
        }
        let existing = trackerState(forProfile: profileID)
        var restored = incoming
        restored.accounts = incoming.accounts.compactMap { account -> TrackerAccount? in
            guard account.isConnected else {
                _ = removeTrackerCredentialOutcome(
                    account.service,
                    profileID: profileID
                )
                return TrackerPrivateCloudExportPolicy.disconnectedTombstone(account)
            }

            let localConnectedAccount = existing?.accounts.first {
                $0.service == account.service && $0.isConnected
            }
            if let preferred = TrackerPrivateCloudExportPolicy.preferredCredentialBearingAccount(
                incoming: account,
                local: localConnectedAccount,
                credentialsAndRosterAreAuthoritative: credentialsAndRosterAreAuthoritative
            ) {
                return preferred
            }
            if var localDeletion = existing?.accounts.first(where: {
                $0.service == account.service && !$0.isConnected
            }) {
                let outcome = removeTrackerCredentialOutcome(
                    account.service,
                    profileID: profileID
                )
                if !outcome.removed
                    || credentialDeletionIsPending(account.service, profileID: profileID) {
                    localDeletion.accessToken = ""
                    localDeletion.refreshToken = nil
                    localDeletion.expiresAt = nil
                    return localDeletion
                }
            }

            if let local = localConnectedAccount {
                switch hydrateTrackerCredential(local, profileID: profileID) {
                case .found(let hydrated, _):
                    return hydrated
                case .absent:

                    break
                case .temporarilyUnavailable(let status):
                    markCredentialHydrationPending(profileID)
                    Logger.shared.log(
                        "TrackerManager: deferred restored \(account.service.rawValue) credential hydration for profile \(profileID) (Keychain status \(status))",
                        type: "Tracker"
                    )
                    return local
                }
            }

            switch hydrateTrackerCredential(account, profileID: profileID) {
            case .found(let hydrated, let identityIsKeychainBound):
                guard identityIsKeychainBound else {
                    Logger.shared.log(
                        "TrackerManager: skipped restored \(account.service.rawValue) metadata for profile \(profileID); the legacy Keychain credential has no locally bound provider identity",
                        type: "Error"
                    )
                    return nil
                }
                return hydrated
            case .absent:
                return nil
            case .temporarilyUnavailable(let status):

                Logger.shared.log(
                    "TrackerManager: skipped unbound restored \(account.service.rawValue) metadata for profile \(profileID) while Keychain was unavailable (status \(status))",
                    type: "Error"
                )
                return nil
            }
        }

        let omittedConnectedAccounts = TrackerPrivateCloudExportPolicy.omittedConnectedAccounts(
            existing: existing?.accounts ?? [],
            incoming: incoming.accounts,
            credentialsAndRosterAreAuthoritative: credentialsAndRosterAreAuthoritative
        )
        if credentialsAndRosterAreAuthoritative {
            for local in omittedConnectedAccounts {
                _ = removeTrackerCredentialOutcome(local.service, profileID: profileID)
                restored.accounts.append(
                    TrackerPrivateCloudExportPolicy.disconnectedTombstone(local)
                )
            }
        }

        let incomingServices = Set(incoming.accounts.map(\.service))
        for local in existing?.accounts ?? [] where !credentialsAndRosterAreAuthoritative
            && local.isConnected && !incomingServices.contains(local.service) {
            if !local.accessToken.isEmpty {
                restored.accounts.append(local)
                continue
            }
            switch hydrateTrackerCredential(local, profileID: profileID) {
            case .found(let hydrated, _):
                restored.accounts.append(hydrated)
            case .absent:
                break
            case .temporarilyUnavailable(let status):
                markCredentialHydrationPending(profileID)
                restored.accounts.append(local)
                Logger.shared.log(
                    "TrackerManager: deferred preservation of local \(local.service.rawValue) credentials while restoring profile \(profileID) (Keychain status \(status))",
                    type: "Tracker"
                )
            }
        }

        guard preserveUnreadableTrackerStateBeforeRestore(profileID) else {
            Logger.shared.log(
                "TrackerManager: refused to overwrite unreadable tracker-state bytes during restore for profile \(profileID)",
                type: "Error"
            )
            return false
        }
        clearUnreadableTrackerState(profileID)

        guard profileID != activeProfileID else {
            trackerState = restored
            saveTrackerState(forProfile: profileID)
            return true
        }

        queueTrackerStatePersistence(restored, forProfile: profileID)
        return true
    }

    private var discardedProfileIDs = Set<UUID>()
    private let discardedProfileLock = NSLock()

    private func markDiscarded(_ profileID: UUID) {
        discardedProfileLock.lock()
        discardedProfileIDs.insert(profileID)
        discardedProfileLock.unlock()
    }

    private func isDiscarded(_ profileID: UUID) -> Bool {
        discardedProfileLock.lock()
        defer { discardedProfileLock.unlock() }
        return discardedProfileIDs.contains(profileID)
    }

    private func trackerStateIsUnreadable(_ profileID: UUID) -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return unreadableTrackerStateProfileIDs.contains(profileID)
    }

    private func preserveUnreadableTrackerStateBeforeRestore(_ profileID: UUID) -> Bool {
        guard trackerStateIsUnreadable(profileID) else { return true }
        let source = Self.stateURL(for: profileID)
        guard FileManager.default.fileExists(atPath: source.path) else { return true }
        let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let rescue = documentsDirectory.appendingPathComponent(
            "TrackerState-\(ProfileScopedStorage.token(for: profileID))-unreadable-\(UUID().uuidString.lowercased()).json"
        )
        do {
            try FileManager.default.copyItem(at: source, to: rescue)
            return true
        } catch {
            Logger.shared.log(
                "TrackerManager: could not preserve unreadable tracker-state bytes: \(error.localizedDescription)",
                type: "Error"
            )
            return false
        }
    }

    private func accountBoundaryIsQuarantined(_ profileID: UUID) -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return accountBoundaryQuarantinedProfileIDs.contains(profileID)
    }

    private func accountBoundaryRecoveryGloballyBlocksOperations() -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return accountBoundaryRecoveryBlocksAllTrackerOperations
    }

    private func trackerDeletionJournalsBlockOperations() -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return credentialDeletionJournalIsUnreadable
            || discardedProfileCleanupJournalIsUnreadable
            || pendingCredentialDeletions.values.contains(where: { !$0.isEmpty })
            || !unpersistedCredentialDeletionAuthority.isEmpty
            || !unpersistedDiscardedProfileCleanupIDs.isEmpty
    }

    private func trackerDeletionJournalSourcesAreUnreadable() -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return credentialDeletionJournalIsUnreadable
            || discardedProfileCleanupJournalIsUnreadable
    }

    private func markTrackerStateReloadPendingAfterDeletionJournalRecovery() {
        trackerStateStatusLock.lock()
        trackerStateReloadPendingAfterDeletionJournalRecovery = true
        trackerStateStatusLock.unlock()
    }

    private func consumeTrackerStateReloadPendingAfterDeletionJournalRecovery() -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        guard trackerStateReloadPendingAfterDeletionJournalRecovery else { return false }
        trackerStateReloadPendingAfterDeletionJournalRecovery = false
        return true
    }

    private func accountBoundaryRecoveryBlocksStateAccess() -> Bool {
        if trackerDeletionJournalsBlockOperations() {
            return true
        }
        return accountBoundaryRecoveryGloballyBlocksOperations()
            && !isBackupRestoreSyncSuppressed()
    }

    private func accountBoundaryRecoveryBlocksNetworkOperations() -> Bool {
        if trackerDeletionJournalsBlockOperations()
            || accountBoundaryRecoveryGloballyBlocksOperations() {
            return true
        }
#if os(iOS)
        return MediaStateAccountBoundaryRecoveryGate.isBlockingSync
#else
        return false
#endif
    }

    private func setAccountBoundaryRecoveryGlobalBlock(_ blocked: Bool) {
        trackerStateStatusLock.lock()
        accountBoundaryRecoveryBlocksAllTrackerOperations = blocked
        trackerStateStatusLock.unlock()
    }

    private func trackerProfileAcceptsOperations(_ profileID: UUID) -> Bool {
        !accountBoundaryRecoveryBlocksNetworkOperations()
            && !accountBoundaryIsQuarantined(profileID)
            && !discardedProfileCleanupIsPending(profileID)
            && !isDiscarded(profileID)
    }

    private func trackerReconnectIsAllowed(
        _ service: TrackerService,
        owner: UUID
    ) -> Bool {
        guard trackerProfileAcceptsOperations(owner) else {
            authError = "\(service.displayName) cannot reconnect until account cleanup finishes."
            isAuthenticating = false
            return false
        }
        return true
    }

    private func markAccountBoundaryQuarantined(_ profileID: UUID) {
        trackerStateStatusLock.lock()
        accountBoundaryQuarantinedProfileIDs.insert(profileID)
        unreadableTrackerStateProfileIDs.insert(profileID)
        trackerStateStatusLock.unlock()
    }

    private func clearAccountBoundaryQuarantine(_ profileID: UUID) {
        trackerStateStatusLock.lock()
        accountBoundaryQuarantinedProfileIDs.remove(profileID)
        unreadableTrackerStateProfileIDs.remove(profileID)
        trackerStateStatusLock.unlock()
    }

    private func markTrackerStateUnreadable(_ profileID: UUID) {
        trackerStateStatusLock.lock()
        unreadableTrackerStateProfileIDs.insert(profileID)
        trackerStateStatusLock.unlock()
    }

    private func clearUnreadableTrackerState(_ profileID: UUID) {
        trackerStateStatusLock.lock()
        unreadableTrackerStateProfileIDs.remove(profileID)
        trackerStateStatusLock.unlock()
    }

    private func markCredentialHydrationPending(_ profileID: UUID) {
        trackerStateStatusLock.lock()
        credentialHydrationPendingProfileIDs.insert(profileID)
        trackerStateStatusLock.unlock()
    }

    private func clearCredentialHydrationPending(_ profileID: UUID) {
        trackerStateStatusLock.lock()
        credentialHydrationPendingProfileIDs.remove(profileID)
        trackerStateStatusLock.unlock()
    }

    private func credentialHydrationIsPending(_ profileID: UUID) -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return credentialHydrationPendingProfileIDs.contains(profileID)
    }

    private func retainPendingTrackerState(_ state: TrackerState, forProfile profileID: UUID) -> PendingTrackerStatePersistence {
        trackerStateStatusLock.lock()
        let pending = PendingTrackerStatePersistence(
            id: UUID(),
            accountBoundaryGeneration: accountBoundaryGenerations[profileID] ?? 0,
            state: state
        )
        pendingTrackerStatePersistence[profileID] = pending
        trackerStateStatusLock.unlock()
        return pending
    }

    private func accountBoundaryGeneration(for profileID: UUID) -> UInt64 {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return accountBoundaryGenerations[profileID] ?? 0
    }

    private func accountBoundaryGenerationIsCurrent(_ generation: UInt64, for profileID: UUID) -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return (accountBoundaryGenerations[profileID] ?? 0) == generation
    }

    private func trackerServiceGeneration(
        for service: TrackerService,
        profileID: UUID
    ) -> UInt64 {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return trackerServiceGenerations[profileID]?[service] ?? 0
    }

    private func trackerServiceGenerationIsCurrent(
        _ generation: UInt64,
        service: TrackerService,
        profileID: UUID
    ) -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return (trackerServiceGenerations[profileID]?[service] ?? 0) == generation
    }

    @discardableResult
    private func invalidateTrackerServiceAuthority(
        _ service: TrackerService,
        profileID: UUID
    ) -> UInt64 {
        trackerStateStatusLock.lock()
        let next = (trackerServiceGenerations[profileID]?[service] ?? 0) &+ 1
        trackerServiceGenerations[profileID, default: [:]][service] = next
        trackerStateStatusLock.unlock()
        return next
    }

    private func operationAuthority(
        for account: TrackerAccount,
        owner: UUID,
        progressAuthority: ProgressManager.ProfileMutationAuthority? = nil,
        operationGeneration: UInt64? = nil
    ) -> TrackerOperationAuthority {
        TrackerOperationAuthority(
            owner: owner,
            operationGeneration: operationGeneration ?? trackerOperationGenerationSnapshot(),
            accountBoundaryGeneration: accountBoundaryGeneration(for: owner),
            serviceGeneration: trackerServiceGeneration(
                for: account.service,
                profileID: owner
            ),
            progressAuthority: progressAuthority,
            service: account.service,
            userId: account.userId,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken
        )
    }

    private func profileOperationAuthority(
        for owner: UUID
    ) -> TrackerProfileOperationAuthority {
        TrackerProfileOperationAuthority(
            owner: owner,
            operationGeneration: trackerOperationGenerationSnapshot()
        )
    }

    private func profileOperationAuthorityIsCurrent(
        _ authority: TrackerProfileOperationAuthority
    ) -> Bool {
        activeProfileID == authority.owner
            && ProfileManager.shared.isStillActive(authority.owner)
            && trackerOperationAuthorityIsCurrent(authority.operationGeneration)
    }

    private func beginAuthenticationAuthority(
        for service: TrackerService,
        owner: UUID
    ) -> WebAuthenticationAuthority {
#if !os(tvOS)
        webAuthSession?.cancel()
#endif
        webAuthSession = nil
        if service == .myAnimeList {
            malTokenRefreshTasks[owner]?.task.cancel()
            malTokenRefreshTasks[owner] = nil
        } else if service == .trakt {
            traktTokenRefreshTasks[owner]?.task.cancel()
            traktTokenRefreshTasks[owner] = nil
        }
        let authority = WebAuthenticationAuthority(
            id: UUID(),
            owner: owner,
            service: service,
            accountBoundaryGeneration: accountBoundaryGeneration(for: owner),
            serviceGeneration: invalidateTrackerServiceAuthority(
                service,
                profileID: owner
            )
        )
        webAuthenticationAuthority = authority
        return authority
    }

    private func authenticationAuthorityIsCurrent(
        _ authority: WebAuthenticationAuthority
    ) -> Bool {
        guard let current = webAuthenticationAuthority else { return false }
        return current.id == authority.id
            && current.owner == authority.owner
            && current.service == authority.service
            && current.accountBoundaryGeneration == authority.accountBoundaryGeneration
            && current.serviceGeneration == authority.serviceGeneration
            && accountBoundaryGenerationIsCurrent(
                authority.accountBoundaryGeneration,
                for: authority.owner
            )
            && trackerServiceGenerationIsCurrent(
                authority.serviceGeneration,
                service: authority.service,
                profileID: authority.owner
            )
    }

    private func finishAuthenticationAuthority(
        _ authority: WebAuthenticationAuthority
    ) {
        guard webAuthenticationAuthority?.id == authority.id else { return }
        webAuthenticationAuthority = nil
        webAuthSession = nil
    }

    private func authenticationAuthority(
        owner: UUID,
        service: TrackerService,
        accountBoundaryGeneration: UInt64?,
        serviceGeneration: UInt64?,
        authenticationID: UUID?
    ) -> WebAuthenticationAuthority {
        if let accountBoundaryGeneration,
           let serviceGeneration,
           let authenticationID {
            return WebAuthenticationAuthority(
                id: authenticationID,
                owner: owner,
                service: service,
                accountBoundaryGeneration: accountBoundaryGeneration,
                serviceGeneration: serviceGeneration
            )
        }

        return beginAuthenticationAuthority(for: service, owner: owner)
    }

    private func operationAuthorityIsCurrent(
        _ authority: TrackerOperationAuthority,
        requireSameCredential: Bool = true
    ) async -> Bool {
        guard activeProfileID == authority.owner,
              ProfileManager.shared.isStillActive(authority.owner),
              trackerOperationAuthorityIsCurrent(authority.operationGeneration),
              authority.progressAuthority.map(
                  ProgressManager.shared.profileMutationAuthorityIsCurrent
              ) ?? true,
              !accountBoundaryIsQuarantined(authority.owner),
              !discardedProfileCleanupIsPending(authority.owner),
              accountBoundaryGenerationIsCurrent(
                  authority.accountBoundaryGeneration,
                  for: authority.owner
              ),
              trackerServiceGenerationIsCurrent(
                  authority.serviceGeneration,
                  service: authority.service,
                  profileID: authority.owner
              ) else {
            return false
        }
        do {
            let expected = TrackerAccount(
                service: authority.service,
                username: "authority",
                accessToken: authority.accessToken,
                refreshToken: authority.refreshToken,
                expiresAt: nil,
                userId: authority.userId,
                isConnected: true
            )
            try await requireTrackerAccountStillConnected(
                expected,
                owner: authority.owner,
                requireSameCredential: requireSameCredential
            )
            return true
        } catch {
            return false
        }
    }

    static func resolvedPlaybackOperationOwner(
        requiredOwner: UUID?,
        progressAuthorityOwner: UUID?,
        progressAuthorityIsCurrent: Bool,
        trackerProfileID: UUID,
        activeProfileID: UUID
    ) -> UUID? {
        guard progressAuthorityOwner == nil || progressAuthorityIsCurrent else {
            return nil
        }
        let owner = requiredOwner ?? progressAuthorityOwner ?? activeProfileID
        guard progressAuthorityOwner == nil || progressAuthorityOwner == owner,
              trackerProfileID == owner,
              activeProfileID == owner else {
            return nil
        }
        return owner
    }

    private func resolvedPlaybackOperationOwner(
        requiredOwner: UUID?,
        progressAuthority: ProgressManager.ProfileMutationAuthority?
    ) -> UUID? {
        let activeOwner = ProfileManager.shared.activeProfileID
        return Self.resolvedPlaybackOperationOwner(
            requiredOwner: requiredOwner,
            progressAuthorityOwner: progressAuthority?.profileID,
            progressAuthorityIsCurrent: progressAuthority.map(
                ProgressManager.shared.profileMutationAuthorityIsCurrent
            ) ?? true,
            trackerProfileID: activeProfileID,
            activeProfileID: activeOwner
        )
    }

    @discardableResult
    private func invalidateAccountBoundary(for profileID: UUID) -> UInt64 {
        trackerStateStatusLock.lock()
        let next = (accountBoundaryGenerations[profileID] ?? 0) &+ 1
        accountBoundaryGenerations[profileID] = next
        trackerStateStatusLock.unlock()
        return next
    }

    private func pendingTrackerStateEntry(forProfile profileID: UUID) -> PendingTrackerStatePersistence? {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return pendingTrackerStatePersistence[profileID]
    }

    private func pendingTrackerState(forProfile profileID: UUID) -> TrackerState? {
        pendingTrackerStateEntry(forProfile: profileID)?.state
    }

    private func pendingTrackerStateAuthorityIsCurrent(
        _ pending: PendingTrackerStatePersistence,
        forProfile profileID: UUID
    ) -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return pendingTrackerStatePersistence[profileID]?.id == pending.id
            && (accountBoundaryGenerations[profileID] ?? 0)
                == pending.accountBoundaryGeneration
    }

    @discardableResult
    private func updatePendingTrackerState(
        _ state: TrackerState,
        forProfile profileID: UUID,
        matching id: UUID
    ) -> Bool {
        trackerStateStatusLock.lock()
        let matched = pendingTrackerStatePersistence[profileID]?.id == id
        if matched {
            pendingTrackerStatePersistence[profileID]?.state = state
        }
        trackerStateStatusLock.unlock()
        return matched
    }

    private func clearPendingTrackerState(forProfile profileID: UUID, matching id: UUID) {
        trackerStateStatusLock.lock()
        if pendingTrackerStatePersistence[profileID]?.id == id {
            pendingTrackerStatePersistence.removeValue(forKey: profileID)
        }
        trackerStateStatusLock.unlock()
    }

    private func allPendingTrackerStateEntries() -> [(UUID, PendingTrackerStatePersistence)] {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return Array(pendingTrackerStatePersistence)
    }

    private func retainPendingCredentialOnlyAccount(_ account: TrackerAccount, forProfile profileID: UUID) {
        trackerStateStatusLock.lock()
        pendingCredentialOnlyAccounts[profileID, default: [:]][account.service] = account
        trackerStateStatusLock.unlock()
    }

    private func allPendingCredentialOnlyAccounts() -> [(UUID, TrackerAccount)] {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return pendingCredentialOnlyAccounts.flatMap { profileID, accounts in
            accounts.values.map { (profileID, $0) }
        }
    }

    private func pendingCredentialOnlyAccountIsCurrent(
        _ account: TrackerAccount,
        forProfile profileID: UUID
    ) -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        guard let pending = pendingCredentialOnlyAccounts[profileID]?[account.service] else {
            return false
        }
        return pending.username == account.username
            && pending.userId == account.userId
            && pending.accessToken == account.accessToken
            && pending.refreshToken == account.refreshToken
            && pending.expiresAt == account.expiresAt
            && pending.isConnected == account.isConnected
    }

    private func clearPendingCredentialOnlyAccount(
        matching account: TrackerAccount,
        forProfile profileID: UUID
    ) {
        trackerStateStatusLock.lock()
        if let pending = pendingCredentialOnlyAccounts[profileID]?[account.service],
           pending.username == account.username,
           pending.userId == account.userId,
           pending.accessToken == account.accessToken,
           pending.refreshToken == account.refreshToken,
           pending.expiresAt == account.expiresAt,
           pending.isConnected == account.isConnected {
            pendingCredentialOnlyAccounts[profileID]?.removeValue(forKey: account.service)
            if pendingCredentialOnlyAccounts[profileID]?.isEmpty == true {
                pendingCredentialOnlyAccounts.removeValue(forKey: profileID)
            }
        }
        trackerStateStatusLock.unlock()
    }

    private func scrubPendingPersistenceForDisconnect(
        _ service: TrackerService,
        profileID: UUID
    ) {
        trackerStateStatusLock.lock()
        if let pending = pendingTrackerStatePersistence[profileID] {
            var state = pending.state
            if let index = state.accounts.firstIndex(where: { $0.service == service }) {
                state.accounts[index].isConnected = false
                state.accounts[index].accessToken = ""
                state.accounts[index].refreshToken = nil
                state.accounts[index].expiresAt = nil
            }
            pendingTrackerStatePersistence[profileID] = PendingTrackerStatePersistence(
                id: UUID(),
                accountBoundaryGeneration: pending.accountBoundaryGeneration,
                state: state
            )
        }
        pendingCredentialOnlyAccounts[profileID]?.removeValue(forKey: service)
        if pendingCredentialOnlyAccounts[profileID]?.isEmpty == true {
            pendingCredentialOnlyAccounts.removeValue(forKey: profileID)
        }
        trackerStateStatusLock.unlock()
    }

    private enum StringMarkerJournalProbe {
        case absent
        case valid([String])
        case unreadable

        var values: [String]? {
            guard case .valid(let values) = self else { return nil }
            return values
        }

        var isUnreadable: Bool {
            if case .unreadable = self { return true }
            return false
        }
    }

    private static func markerJournalErrorIsFileNotFound(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        return nsError.code == CocoaError.Code.fileNoSuchFile.rawValue
            || nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue
    }

    private struct MarkerJournalPersistenceResult {
        let defaultsSucceeded: Bool
        let sidecarSucceeded: Bool

        var published: Bool {
            defaultsSucceeded || sidecarSucceeded
        }

        var cleared: Bool {
            defaultsSucceeded && sidecarSucceeded
        }
    }

    private func probeDefaultsStringMarkerJournal(
        key: String,
        maximumCount: Int,
        validator: (String) -> Bool
    ) -> StringMarkerJournalProbe {
        let defaults = UserDefaults.standard
        guard let object = defaults.object(forKey: key) else { return .absent }
        guard let values = object as? [String], values.count <= maximumCount else {
            return .unreadable
        }
        var totalBytes = 0
        for value in values {
            let byteCount = value.utf8.count
            guard byteCount <= Self.maximumTrackerDeletionJournalBytes,
                  totalBytes <= Self.maximumTrackerDeletionJournalBytes - byteCount,
                  validator(value) else {
                return .unreadable
            }
            totalBytes += byteCount
        }
        return .valid(values)
    }

    private func probeSidecarStringMarkerJournal(
        url: URL?,
        maximumCount: Int,
        validator: (String) -> Bool
    ) -> StringMarkerJournalProbe {

        guard let url else { return .unreadable }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let fileSize = (attributes[.size] as? NSNumber)?.intValue,
                  fileSize <= Self.maximumTrackerDeletionJournalBytes else {
                return .unreadable
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(
                upToCount: Self.maximumTrackerDeletionJournalBytes + 1
            ) ?? Data()
            guard data.count <= Self.maximumTrackerDeletionJournalBytes,
                  let values = try? JSONDecoder().decode([String].self, from: data),
                  values.count <= maximumCount else {
                return .unreadable
            }
            var totalBytes = 0
            for value in values {
                let byteCount = value.utf8.count
                guard byteCount <= Self.maximumTrackerDeletionJournalBytes,
                      totalBytes <= Self.maximumTrackerDeletionJournalBytes - byteCount,
                      validator(value) else {
                    return .unreadable
                }
                totalBytes += byteCount
            }
            return .valid(values)
        } catch {
            if Self.markerJournalErrorIsFileNotFound(error) {
                return .absent
            }
            return .unreadable
        }
    }

    private func persistStringMarkerJournal(
        values: [String],
        defaultsKey: String,
        sidecarURL: URL?,
        maximumCount: Int
    ) -> MarkerJournalPersistenceResult {
        guard values.count <= maximumCount,
              let encoded = try? JSONEncoder().encode(values),
              encoded.count <= Self.maximumTrackerDeletionJournalBytes else {
            return MarkerJournalPersistenceResult(
                defaultsSucceeded: false,
                sidecarSucceeded: false
            )
        }

        let defaults = UserDefaults.standard
        defaults.set(values, forKey: defaultsKey)
        let defaultsSucceeded = defaults.synchronize()

        var sidecarSucceeded = false
        if let sidecarURL {
            do {
                if values.isEmpty {
                    try FileManager.default.removeItem(at: sidecarURL)
                } else {
                    try encoded.write(to: sidecarURL, options: .atomic)
                }
                sidecarSucceeded = true
            } catch {
                sidecarSucceeded = values.isEmpty
                    && Self.markerJournalErrorIsFileNotFound(error)
            }
        }
        return MarkerJournalPersistenceResult(
            defaultsSucceeded: defaultsSucceeded,
            sidecarSucceeded: sidecarSucceeded
        )
    }

    private func parsedCredentialDeletionMarker(
        _ marker: String
    ) -> (profileID: UUID, service: TrackerService)? {
        guard marker.utf8.count <= 128 else { return nil }
        let parts = marker.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let profileID = UUID(uuidString: String(parts[0])),
              let service = TrackerService(rawValue: String(parts[1])) else { return nil }
        return (profileID, service)
    }

    private func credentialDeletionIsPending(_ service: TrackerService, profileID: UUID) -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return pendingCredentialDeletions[profileID]?.contains(service) == true
    }

    @discardableResult
    private func markCredentialDeletionPending(
        _ service: TrackerService,
        profileID: UUID
    ) -> Bool {
        credentialDeletionPersistenceLock.lock()
        defer { credentialDeletionPersistenceLock.unlock() }
        return markCredentialDeletionPendingLocked(service, profileID: profileID)
    }

    private func markCredentialDeletionPendingLocked(
        _ service: TrackerService,
        profileID: UUID
    ) -> Bool {
        trackerStateStatusLock.lock()
        pendingCredentialDeletions[profileID, default: []].insert(service)
        let markers = serializedPendingCredentialDeletionMarkersLocked()
        guard !credentialDeletionJournalIsUnreadable,
              markers.count <= Self.maximumCredentialDeletionMarkerCount else {
            unpersistedCredentialDeletionAuthority[profileID, default: []].insert(service)
            trackerStateStatusLock.unlock()
            return false
        }
        trackerStateStatusLock.unlock()

        let persistence = persistStringMarkerJournal(
            values: markers,
            defaultsKey: Self.pendingCredentialDeletionDefaultsKey,
            sidecarURL: Self.credentialDeletionJournalURL,
            maximumCount: Self.maximumCredentialDeletionMarkerCount
        )
        trackerStateStatusLock.lock()
        if persistence.published {
            unpersistedCredentialDeletionAuthority[profileID]?.remove(service)
            if unpersistedCredentialDeletionAuthority[profileID]?.isEmpty == true {
                unpersistedCredentialDeletionAuthority.removeValue(forKey: profileID)
            }
        } else {
            unpersistedCredentialDeletionAuthority[profileID, default: []].insert(service)
        }
        trackerStateStatusLock.unlock()

        return persistence.published
    }

    @discardableResult
    private func clearCredentialDeletionPending(
        _ service: TrackerService,
        profileID: UUID
    ) -> Bool {
        credentialDeletionPersistenceLock.lock()
        defer { credentialDeletionPersistenceLock.unlock() }
        return clearCredentialDeletionPendingLocked(service, profileID: profileID)
    }

    private func clearCredentialDeletionPendingLocked(
        _ service: TrackerService,
        profileID: UUID
    ) -> Bool {
        trackerStateStatusLock.lock()
        let wasPending = pendingCredentialDeletions[profileID]?.contains(service) == true
        guard wasPending else {
            unpersistedCredentialDeletionAuthority[profileID]?.remove(service)
            if unpersistedCredentialDeletionAuthority[profileID]?.isEmpty == true {
                unpersistedCredentialDeletionAuthority.removeValue(forKey: profileID)
            }
            trackerStateStatusLock.unlock()
            return true
        }
        guard !credentialDeletionJournalIsUnreadable else {
            trackerStateStatusLock.unlock()
            return false
        }

        let markers: [String] = pendingCredentialDeletions.flatMap { candidateProfileID, services in
            services.compactMap { candidateService -> String? in
                guard candidateProfileID != profileID || candidateService != service else {
                    return nil
                }
                return "\(candidateProfileID.uuidString.lowercased())|\(candidateService.rawValue)"
            }
        }.sorted()
        guard markers.count <= Self.maximumCredentialDeletionMarkerCount else {
            trackerStateStatusLock.unlock()
            return false
        }
        trackerStateStatusLock.unlock()
        let persistence = persistStringMarkerJournal(
            values: markers,
            defaultsKey: Self.pendingCredentialDeletionDefaultsKey,
            sidecarURL: Self.credentialDeletionJournalURL,
            maximumCount: Self.maximumCredentialDeletionMarkerCount
        )
        guard persistence.cleared else {

            trackerStateStatusLock.lock()
            let rollbackMarkers = serializedPendingCredentialDeletionMarkersLocked()
            trackerStateStatusLock.unlock()
            _ = persistStringMarkerJournal(
                values: rollbackMarkers,
                defaultsKey: Self.pendingCredentialDeletionDefaultsKey,
                sidecarURL: Self.credentialDeletionJournalURL,
                maximumCount: Self.maximumCredentialDeletionMarkerCount
            )
            return false
        }
        trackerStateStatusLock.lock()
        pendingCredentialDeletions[profileID]?.remove(service)
        if pendingCredentialDeletions[profileID]?.isEmpty == true {
            pendingCredentialDeletions.removeValue(forKey: profileID)
        }
        unpersistedCredentialDeletionAuthority[profileID]?.remove(service)
        if unpersistedCredentialDeletionAuthority[profileID]?.isEmpty == true {
            unpersistedCredentialDeletionAuthority.removeValue(forKey: profileID)
        }
        trackerStateStatusLock.unlock()
        return true
    }

    private func serializedPendingCredentialDeletionMarkersLocked() -> [String] {
        pendingCredentialDeletions.flatMap { profileID, services in
            services.map { "\(profileID.uuidString.lowercased())|\($0.rawValue)" }
        }.sorted()
    }

    private func loadPendingCredentialDeletionMarkers() {
        credentialDeletionPersistenceLock.lock()
        defer { credentialDeletionPersistenceLock.unlock() }
        let validator = { [weak self] (marker: String) -> Bool in
            self?.parsedCredentialDeletionMarker(marker) != nil
        }
        let defaultsProbe = probeDefaultsStringMarkerJournal(
            key: Self.pendingCredentialDeletionDefaultsKey,
            maximumCount: Self.maximumCredentialDeletionMarkerCount,
            validator: validator
        )
        let sidecarProbe = probeSidecarStringMarkerJournal(
            url: Self.credentialDeletionJournalURL,
            maximumCount: Self.maximumCredentialDeletionMarkerCount,
            validator: validator
        )
        let journalIsUnreadable = defaultsProbe.isUnreadable || sidecarProbe.isUnreadable
        let markers = (defaultsProbe.values ?? []) + (sidecarProbe.values ?? [])
        var loaded: [UUID: Set<TrackerService>] = [:]
        for marker in markers {
            guard let parsed = parsedCredentialDeletionMarker(marker) else { continue }
            loaded[parsed.profileID, default: []].insert(parsed.service)
        }
        trackerStateStatusLock.lock()
        let wasUnreadable = credentialDeletionJournalIsUnreadable
        for (profileID, services) in loaded {
            pendingCredentialDeletions[profileID, default: []].formUnion(services)
        }
        credentialDeletionJournalIsUnreadable = journalIsUnreadable
        let canonical = serializedPendingCredentialDeletionMarkersLocked()
        trackerStateStatusLock.unlock()

        if journalIsUnreadable {
            if !wasUnreadable {
                Logger.shared.log(
                    "TrackerManager: credential-deletion journal is malformed, oversized, or unavailable; tracker operations remain fail-closed and existing bytes were preserved",
                    type: "Error"
                )
            }
            return
        }
        if wasUnreadable {
            Logger.shared.log(
                "TrackerManager: credential-deletion journal became readable; retrying its preserved deletion authority",
                type: "Tracker"
            )
        }
        if !canonical.isEmpty {

            let persistence = persistStringMarkerJournal(
                values: canonical,
                defaultsKey: Self.pendingCredentialDeletionDefaultsKey,
                sidecarURL: Self.credentialDeletionJournalURL,
                maximumCount: Self.maximumCredentialDeletionMarkerCount
            )
            if persistence.published {
                trackerStateStatusLock.lock()
                for marker in canonical {
                    guard let parsed = parsedCredentialDeletionMarker(marker) else { continue }
                    unpersistedCredentialDeletionAuthority[parsed.profileID]?
                        .remove(parsed.service)
                    if unpersistedCredentialDeletionAuthority[parsed.profileID]?.isEmpty == true {
                        unpersistedCredentialDeletionAuthority.removeValue(
                            forKey: parsed.profileID
                        )
                    }
                }
                trackerStateStatusLock.unlock()
            }
        }
    }

    private func allPendingCredentialDeletions() -> [(UUID, TrackerService)] {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return pendingCredentialDeletions.flatMap { profileID, services in
            services.map { (profileID, $0) }
        }
    }

    private func resolveUnpersistedCredentialDeletionAuthority(
        _ service: TrackerService,
        profileID: UUID
    ) {
        trackerStateStatusLock.lock()
        unpersistedCredentialDeletionAuthority[profileID]?.remove(service)
        if unpersistedCredentialDeletionAuthority[profileID]?.isEmpty == true {
            unpersistedCredentialDeletionAuthority.removeValue(forKey: profileID)
        }
        trackerStateStatusLock.unlock()
    }

    private func loadPendingDiscardedProfileCleanupMarkers() {

        trackerStateStatusLock.lock()
        let validator = { (value: String) -> Bool in
            value.utf8.count <= 64 && UUID(uuidString: value) != nil
        }
        let defaultsProbe = probeDefaultsStringMarkerJournal(
            key: Self.pendingDiscardedProfileCleanupDefaultsKey,
            maximumCount: Self.maximumDiscardedProfileCleanupMarkerCount,
            validator: validator
        )
        let sidecarProbe = probeSidecarStringMarkerJournal(
            url: Self.discardedProfileCleanupJournalURL,
            maximumCount: Self.maximumDiscardedProfileCleanupMarkerCount,
            validator: validator
        )
        let journalIsUnreadable = defaultsProbe.isUnreadable || sidecarProbe.isUnreadable
        let values = (defaultsProbe.values ?? []) + (sidecarProbe.values ?? [])
        let loaded = Set(values.compactMap(UUID.init(uuidString:)))
        let wasUnreadable = discardedProfileCleanupJournalIsUnreadable
        pendingDiscardedProfileCleanupIDs.formUnion(loaded)
        discardedProfileCleanupJournalIsUnreadable = journalIsUnreadable
        let canonical = pendingDiscardedProfileCleanupIDs
            .map { $0.uuidString.lowercased() }
            .sorted()
        if !journalIsUnreadable, !canonical.isEmpty {
            let persisted = persistPendingDiscardedProfileCleanupMarkersLocked()
            if persisted {
                unpersistedDiscardedProfileCleanupIDs.subtract(
                    pendingDiscardedProfileCleanupIDs
                )
            }
        }
        trackerStateStatusLock.unlock()
        discardedProfileLock.lock()
        discardedProfileIDs.formUnion(loaded)
        discardedProfileLock.unlock()

        if journalIsUnreadable {
            if !wasUnreadable {
                Logger.shared.log(
                    "TrackerManager: discarded-profile cleanup journal is malformed, oversized, or unavailable; tracker operations remain fail-closed and existing bytes were preserved",
                    type: "Error"
                )
            }
            return
        }
        if wasUnreadable {
            Logger.shared.log(
                "TrackerManager: discarded-profile cleanup journal became readable; retrying its preserved cleanup authority",
                type: "Tracker"
            )
        }
    }

    private func persistPendingDiscardedProfileCleanupMarkersLocked(
        requiresAllStores: Bool = false
    ) -> Bool {
        guard !discardedProfileCleanupJournalIsUnreadable else { return false }
        let values = pendingDiscardedProfileCleanupIDs
            .map { $0.uuidString.lowercased() }
            .sorted()
        guard values.count <= Self.maximumDiscardedProfileCleanupMarkerCount else {
            return false
        }
        let persistence = persistStringMarkerJournal(
            values: values,
            defaultsKey: Self.pendingDiscardedProfileCleanupDefaultsKey,
            sidecarURL: Self.discardedProfileCleanupJournalURL,
            maximumCount: Self.maximumDiscardedProfileCleanupMarkerCount
        )

        return requiresAllStores || values.isEmpty
            ? persistence.cleared
            : persistence.published
    }

    @discardableResult
    private func markDiscardedProfileCleanupPending(_ profileID: UUID) -> Bool {
        trackerStateStatusLock.lock()
        pendingDiscardedProfileCleanupIDs.insert(profileID)
        let succeeded = persistPendingDiscardedProfileCleanupMarkersLocked()
        if succeeded {
            unpersistedDiscardedProfileCleanupIDs.remove(profileID)
        } else {
            unpersistedDiscardedProfileCleanupIDs.insert(profileID)
        }
        trackerStateStatusLock.unlock()
        discardedProfileLock.lock()
        discardedProfileIDs.insert(profileID)
        discardedProfileLock.unlock()
        return succeeded
    }

    @discardableResult
    private func clearDiscardedProfileCleanupPending(_ profileID: UUID) -> Bool {
        trackerStateStatusLock.lock()
        let previous = pendingDiscardedProfileCleanupIDs
        pendingDiscardedProfileCleanupIDs.remove(profileID)
        let succeeded = persistPendingDiscardedProfileCleanupMarkersLocked(
            requiresAllStores: true
        )
        if !succeeded {
            pendingDiscardedProfileCleanupIDs = previous
            _ = persistPendingDiscardedProfileCleanupMarkersLocked()
        } else {
            unpersistedDiscardedProfileCleanupIDs.remove(profileID)
        }
        trackerStateStatusLock.unlock()
        return succeeded
    }

    private func discardedProfileCleanupIsPending(_ profileID: UUID) -> Bool {
        trackerStateStatusLock.lock()
        defer { trackerStateStatusLock.unlock() }
        return pendingDiscardedProfileCleanupIDs.contains(profileID)
    }

    private struct CredentialRemovalOutcome {
        let removed: Bool

        let deletionIsDurablyProtected: Bool
    }

    private func removeTrackerCredentialOutcome(
        _ service: TrackerService,
        profileID: UUID,
        pendingAuthority: PendingTrackerStatePersistence? = nil
    ) -> CredentialRemovalOutcome {
        credentialDeletionPersistenceLock.lock()
        defer { credentialDeletionPersistenceLock.unlock() }
        if let pendingAuthority,
           !pendingTrackerStateAuthorityIsCurrent(
               pendingAuthority,
               forProfile: profileID
           ) {
            return CredentialRemovalOutcome(
                removed: false,
                deletionIsDurablyProtected: false
            )
        }
        return removeTrackerCredentialOutcomeLocked(service, profileID: profileID)
    }

    private func removeTrackerCredentialOutcomeLocked(
        _ service: TrackerService,
        profileID: UUID
    ) -> CredentialRemovalOutcome {
        let removed = TrackerCredentialVault.remove(service, profileID: profileID)
        if removed {

            resolveUnpersistedCredentialDeletionAuthority(
                service,
                profileID: profileID
            )
            _ = clearCredentialDeletionPendingLocked(service, profileID: profileID)
            return CredentialRemovalOutcome(
                removed: true,
                deletionIsDurablyProtected: true
            )
        } else {
            return CredentialRemovalOutcome(
                removed: false,
                deletionIsDurablyProtected: markCredentialDeletionPendingLocked(
                    service,
                    profileID: profileID
                )
            )
        }
    }

    @discardableResult
    private func removeTrackerCredential(
        _ service: TrackerService,
        profileID: UUID,
        pendingAuthority: PendingTrackerStatePersistence? = nil
    ) -> Bool {
        removeTrackerCredentialOutcome(
            service,
            profileID: profileID,
            pendingAuthority: pendingAuthority
        ).removed
    }

    private func storeTrackerCredential(
        _ account: TrackerAccount,
        profileID: UUID,
        pendingAuthority: PendingTrackerStatePersistence? = nil,
        pendingCredentialOnlyAuthority: TrackerAccount? = nil
    ) -> Bool {
        credentialDeletionPersistenceLock.lock()
        defer { credentialDeletionPersistenceLock.unlock() }
        if let pendingAuthority,
           !pendingTrackerStateAuthorityIsCurrent(
               pendingAuthority,
               forProfile: profileID
           ) {
            return false
        }
        if let pendingCredentialOnlyAuthority,
           !pendingCredentialOnlyAccountIsCurrent(
               pendingCredentialOnlyAuthority,
               forProfile: profileID
           ) {
            return false
        }
        guard !trackerDeletionJournalsBlockOperations() else { return false }
        if credentialDeletionIsPending(account.service, profileID: profileID) {
            guard removeTrackerCredentialOutcomeLocked(
                    account.service,
                    profileID: profileID
                  ).removed,
                  !credentialDeletionIsPending(account.service, profileID: profileID) else {
                return false
            }
        }
        return TrackerCredentialVault.store(account, profileID: profileID)
    }

    private func hydrateTrackerCredential(
        _ account: TrackerAccount,
        profileID: UUID,
        pendingAuthority: PendingTrackerStatePersistence? = nil
    ) -> TrackerCredentialVault.HydrationResult {
        credentialDeletionPersistenceLock.lock()
        defer { credentialDeletionPersistenceLock.unlock() }
        if let pendingAuthority,
           !pendingTrackerStateAuthorityIsCurrent(
               pendingAuthority,
               forProfile: profileID
           ) {
            return .temporarilyUnavailable(errSecInteractionNotAllowed)
        }
        guard !trackerDeletionJournalsBlockOperations() else {
            return .temporarilyUnavailable(errSecInteractionNotAllowed)
        }
        if credentialDeletionIsPending(account.service, profileID: profileID) {
            guard removeTrackerCredentialOutcomeLocked(
                    account.service,
                    profileID: profileID
                  ).removed else {
                return .temporarilyUnavailable(errSecInteractionNotAllowed)
            }
            return .absent
        }
        return TrackerCredentialVault.hydrate(account, profileID: profileID)
    }

    private func recoverIdentityBoundCredentialRows(
        in state: inout TrackerState,
        profileID: UUID
    ) -> (changed: Bool, unavailable: Bool) {
        guard !trackerDeletionJournalsBlockOperations() else {
            return (false, true)
        }
        var changed = false
        var unavailable = false
        let representedServices = Set(state.accounts.map(\.service))

        for service in TrackerService.allCases where !representedServices.contains(service) {
            credentialDeletionPersistenceLock.lock()
            if credentialDeletionIsPending(service, profileID: profileID) {
                let outcome = removeTrackerCredentialOutcomeLocked(
                    service,
                    profileID: profileID
                )
                credentialDeletionPersistenceLock.unlock()
                if !outcome.removed {
                    unavailable = true
                }
                continue
            }
            let discovery = TrackerCredentialVault.discoverIdentityBound(
                service,
                profileID: profileID
            )
            credentialDeletionPersistenceLock.unlock()
            switch discovery {
            case .found(let account):
                state.accounts.append(account)
                changed = true
            case .notRecoverable:
                break
            case .temporarilyUnavailable:
                unavailable = true
            }
        }
        return (changed, unavailable)
    }

    @objc private func profileRosterDidChange() {
        let liveProfileIDs = Set(ProfileManager.shared.profiles.map(\.id))
        discardedProfileLock.lock()
        let revived = discardedProfileIDs.intersection(liveProfileIDs)
        discardedProfileLock.unlock()
        guard !revived.isEmpty else { return }
        for profileID in revived where discardedProfileCleanupIsPending(profileID) {
            _ = performDiscardedProfileCleanup(profileID)
        }
        let safeToRevive = revived.filter { !discardedProfileCleanupIsPending($0) }
        discardedProfileLock.lock()
        discardedProfileIDs.subtract(safeToRevive)
        discardedProfileLock.unlock()
        Logger.shared.log(
            "TrackerManager: \(safeToRevive.count) previously discarded profile(s) completed cleanup and are writable again",
            type: "Tracker"
        )
    }

    @discardableResult
    private func performDiscardedProfileCleanup(_ profileID: UUID) -> Bool {
        guard !trackerDeletionJournalSourcesAreUnreadable() else { return false }
        let stateURL = Self.stateURL(for: profileID)
        let removedStateFile = trackerStatePersistenceQueue.sync {
            do {
                if FileManager.default.fileExists(atPath: stateURL.path) {
                    try FileManager.default.removeItem(at: stateURL)
                }
                return true
            } catch {
                return false
            }
        }

        var cleanupIsDurablyProtected = removedStateFile
        for service in TrackerService.allCases {
            let outcome = removeTrackerCredentialOutcome(service, profileID: profileID)
            cleanupIsDurablyProtected = outcome.deletionIsDurablyProtected
                && cleanupIsDurablyProtected
        }
        cleanupIsDurablyProtected = clearTraktHistoryWriteReceipts(for: profileID)
            && cleanupIsDurablyProtected

        guard cleanupIsDurablyProtected else { return false }
        clearUnreadableTrackerState(profileID)
        clearCredentialHydrationPending(profileID)
        if let pending = pendingTrackerStateEntry(forProfile: profileID) {
            clearPendingTrackerState(forProfile: profileID, matching: pending.id)
        }
        trackerStateStatusLock.lock()
        pendingCredentialOnlyAccounts.removeValue(forKey: profileID)
        trackerStateStatusLock.unlock()
        return clearDiscardedProfileCleanupPending(profileID)
    }

    private func retryPendingDiscardedProfileCleanup() {
        guard !trackerDeletionJournalSourcesAreUnreadable() else { return }
        trackerStateStatusLock.lock()
        let profileIDs = pendingDiscardedProfileCleanupIDs
        trackerStateStatusLock.unlock()
        for profileID in profileIDs {
            if performDiscardedProfileCleanup(profileID),
               ProfileManager.shared.profile(with: profileID) != nil {
                discardedProfileLock.lock()
                discardedProfileIDs.remove(profileID)
                discardedProfileLock.unlock()
            }
        }
    }

    func discardStore(forProfile profileID: UUID) {
        guard profileID != activeProfileID else { return }

        _ = invalidateAccountBoundary(for: profileID)
        withTraktAuthenticationRequiredLatches {
            $0.clear(profileID)
        }
        traktTokenRefreshTasks[profileID]?.task.cancel()
        traktTokenRefreshTasks[profileID] = nil
        malTokenRefreshTasks[profileID]?.task.cancel()
        malTokenRefreshTasks[profileID] = nil
        trackerStateStatusLock.lock()
        let preservesForTentativeBoundary = tentativelyPreservedAccountBoundaryProfileIDs
            .contains(profileID)
        trackerStateStatusLock.unlock()
        guard !preservesForTentativeBoundary else { return }
        let journalWasPublished = markDiscardedProfileCleanupPending(profileID)
        let cleanupSucceeded = performDiscardedProfileCleanup(profileID)
        if !cleanupSucceeded {

            let retryWasPublished = markDiscardedProfileCleanupPending(profileID)
            if !journalWasPublished && !retryWasPublished {
                Logger.shared.log(
                    "TrackerManager: discarded profile \(profileID) cleanup could not publish durable retry authority",
                    type: "Error"
                )
            }
        }
    }

    func beginTentativeAccountBoundaryCredentialPreservation(
        profileIDs: Set<UUID>
    ) {
        trackerStateStatusLock.lock()
        tentativelyPreservedAccountBoundaryProfileIDs.formUnion(profileIDs)
        trackerStateStatusLock.unlock()
    }

    func endTentativeAccountBoundaryCredentialPreservation(
        profileIDs: Set<UUID>
    ) {
        trackerStateStatusLock.lock()
        tentativelyPreservedAccountBoundaryProfileIDs.subtract(profileIDs)
        trackerStateStatusLock.unlock()
    }

    @discardableResult
    @MainActor
    func clearStoreForConfirmedAccountBoundary(profileID: UUID) -> Bool {
        markAccountBoundaryQuarantined(profileID)
        _ = invalidateAccountBoundary(for: profileID)
        withTraktAuthenticationRequiredLatches {
            $0.clear(profileID)
        }
        var cleanupIsDurablyProtected = true

        syncToolTask?.cancel()
        syncToolTask = nil
        cachedSyncToolPlan = nil
        traktTokenRefreshTasks[profileID]?.task.cancel()
        traktTokenRefreshTasks[profileID] = nil
        malTokenRefreshTasks[profileID]?.task.cancel()
        malTokenRefreshTasks[profileID] = nil

        let isActiveProfile = profileID == activeProfileID
        if isActiveProfile {
#if !os(tvOS)
            webAuthSession?.cancel()
#endif
            webAuthSession = nil
            pendingMALCodeVerifier = nil
            pendingTraktOAuthState = nil
#if os(tvOS)
            traktDeviceAuthTask?.cancel()
            traktDeviceAuthTask = nil
            traktDeviceUserCode = nil
            traktDeviceVerificationURL = nil
#endif
            isAuthenticating = false
            authError = nil
            authenticationNotice = nil
            isRunningSyncTool = false
            syncToolStatus = nil
            syncToolPreview = nil
            syncToolProgressCompleted = 0
            syncToolProgressTotal = 0
            syncToolProgressDetail = nil
            syncToolIsLocked = false
        }

        trackerStateStatusLock.lock()
        pendingTrackerStatePersistence.removeValue(forKey: profileID)
        pendingCredentialOnlyAccounts.removeValue(forKey: profileID)
        credentialHydrationPendingProfileIDs.remove(profileID)
        trackerStateStatusLock.unlock()

        let stateURL = Self.stateURL(for: profileID)
        let removedStateFile = trackerStatePersistenceQueue.sync {
            do {
                if FileManager.default.fileExists(atPath: stateURL.path) {
                    try FileManager.default.removeItem(at: stateURL)
                }
                return true
            } catch {
                Logger.shared.log(
                    "TrackerManager: failed to remove tracker state at a confirmed account boundary for profile \(profileID): \(error.localizedDescription)",
                    type: "Error"
                )
                return false
            }
        }
        cleanupIsDurablyProtected = cleanupIsDurablyProtected && removedStateFile

        for service in TrackerService.allCases {
            let outcome = removeTrackerCredentialOutcome(service, profileID: profileID)
            cleanupIsDurablyProtected = cleanupIsDurablyProtected
                && outcome.deletionIsDurablyProtected
        }

        if isActiveProfile {
            trackerState = TrackerState()
        }

        recentWatchSyncQueue.sync {
            watchSyncDedupeGate = TrackerWatchSyncDedupeGate()
        }
        recentTraktPlaybackSyncQueue.sync {
            recentTraktPlaybackSyncKeys.removeAll()
        }
        cleanupIsDurablyProtected = clearTraktHistoryWriteReceipts(for: profileID)
            && cleanupIsDurablyProtected
        traktContinueWatchingCacheQueue.sync {
            traktContinueWatchingCache = nil
        }
        traktScrobbleQueue.sync {
            traktScrobbleLastActionByKey.removeAll()
            traktScrobbleLastStampByKey.removeAll()
            traktScrobblePendingByKey.removeAll()
            traktScrobbleFailureStampByKey.removeAll()
        }
        if cleanupIsDurablyProtected {
            clearAccountBoundaryQuarantine(profileID)
        }
        return cleanupIsDurablyProtected
    }

    private func readPersistedTrackerState(forProfile profileID: UUID) -> TrackerState? {
        guard !accountBoundaryRecoveryBlocksStateAccess(),
              !trackerStateIsUnreadable(profileID) else { return nil }
        let stateURL = Self.stateURL(for: profileID)
        return trackerStatePersistenceQueue.sync {
            guard !accountBoundaryRecoveryBlocksStateAccess(),
                  !trackerStateIsUnreadable(profileID) else { return nil }
            guard FileManager.default.fileExists(atPath: stateURL.path) else {
                return TrackerState()
            }
            do {
                let data = try BoundedLocalStoreReader.read(
                    from: stateURL,
                    maximumBytes: Self.maximumPersistedTrackerStateBytes
                )
                return try JSONDecoder().decode(TrackerState.self, from: data)
            } catch {
                markTrackerStateUnreadable(profileID)
                Logger.shared.log(
                    "TrackerManager: refused to treat unreadable tracker state as empty for profile \(profileID): \(error.localizedDescription)",
                    type: "Error"
                )
                return nil
            }
        }
    }

    private func loadTrackerState(forProfile profileID: UUID? = nil) {
        let profileID = profileID ?? activeProfileID
        guard !accountBoundaryRecoveryBlocksStateAccess(),
              !accountBoundaryIsQuarantined(profileID),
              !discardedProfileCleanupIsPending(profileID) else { return }
        guard var state = readPersistedTrackerState(forProfile: profileID) else { return }
        guard Self.trackerAccountsAreStructurallyValid(state.accounts) else {
            markTrackerStateUnreadable(profileID)
            Logger.shared.log(
                "TrackerManager: refused structurally invalid tracker state for profile \(profileID)",
                type: "Error"
            )
            return
        }
        var migratedPlaintextCredentials = false
        var removedDefinitelyAbsentCredential = false
        var recoveredIdentityBoundCredential = false
        var hydrationUnavailable = false
        state.accounts = state.accounts.compactMap { account in
            guard account.isConnected else {
                if removeTrackerCredential(account.service, profileID: profileID) {
                    removedDefinitelyAbsentCredential = true
                    return nil
                }
                hydrationUnavailable = true
                return account
            }
            if !account.accessToken.isEmpty {
                guard storeTrackerCredential(account, profileID: profileID) else {
                    hydrationUnavailable = true
                    return account
                }
                migratedPlaintextCredentials = true
            }
            switch hydrateTrackerCredential(account, profileID: profileID) {
            case .found(let hydrated, let identityIsKeychainBound):
                if !identityIsKeychainBound {

                    if storeTrackerCredential(hydrated, profileID: profileID) {
                        migratedPlaintextCredentials = true
                    } else {
                        hydrationUnavailable = true
                    }
                }
                return hydrated
            case .absent:
                removedDefinitelyAbsentCredential = true
                return nil
            case .temporarilyUnavailable(let status):
                hydrationUnavailable = true
                Logger.shared.log(
                    "TrackerManager: deferred \(account.service.rawValue) credential hydration for profile \(profileID) (Keychain status \(status))",
                    type: "Tracker"
                )
                return account
            }
        }
        let discovered = recoverIdentityBoundCredentialRows(
            in: &state,
            profileID: profileID
        )
        recoveredIdentityBoundCredential = discovered.changed
        hydrationUnavailable = hydrationUnavailable || discovered.unavailable
        self.trackerState = state
        if hydrationUnavailable {
            markCredentialHydrationPending(profileID)

            queueTrackerStatePersistence(state, forProfile: profileID)
        } else {
            clearCredentialHydrationPending(profileID)
            if migratedPlaintextCredentials
                || removedDefinitelyAbsentCredential
                || recoveredIdentityBoundCredential {
                saveTrackerState(forProfile: profileID)
            }
        }
    }

    @objc private func retryActiveProfileCredentialHydration() {
        let retry = { [weak self] in
            guard let self else { return }

            self.loadPendingCredentialDeletionMarkers()
            self.loadPendingDiscardedProfileCleanupMarkers()
            guard !self.trackerDeletionJournalSourcesAreUnreadable() else {
                return
            }
            self.retryPendingDiscardedProfileCleanup()
#if os(iOS)

            _ = self.completeCommittedAccountBoundaryCleanupBeforeLoadingState()
            guard !self.accountBoundaryRecoveryGloballyBlocksOperations() else {
                return
            }
#endif

            self.retryPendingCredentialDeletions()
            guard !self.trackerDeletionJournalsBlockOperations() else {
                return
            }
            if self.consumeTrackerStateReloadPendingAfterDeletionJournalRecovery() {
                let profileID = self.activeProfileID
                self.trackerState = TrackerState()
                if let pending = self.pendingTrackerState(forProfile: profileID) {
                    self.trackerState = pending
                } else {
                    self.loadTrackerState(forProfile: profileID)
                }
            }
            let profileID = self.activeProfileID
            if self.credentialHydrationIsPending(profileID),
               !self.trackerStateIsUnreadable(profileID) {
                var stillUnavailable = false
                var changed = false
                self.trackerState.accounts = self.trackerState.accounts.compactMap { account in
                    guard account.isConnected, account.accessToken.isEmpty else { return account }
                    switch self.hydrateTrackerCredential(account, profileID: profileID) {
                    case .found(let hydrated, _):
                        changed = true
                        return hydrated
                    case .absent:
                        changed = true
                        return nil
                    case .temporarilyUnavailable:
                        stillUnavailable = true
                        return account
                    }
                }
                let discovered = self.recoverIdentityBoundCredentialRows(
                    in: &self.trackerState,
                    profileID: profileID
                )
                changed = changed || discovered.changed
                stillUnavailable = stillUnavailable || discovered.unavailable
                if stillUnavailable {
                    self.markCredentialHydrationPending(profileID)
                } else {
                    self.clearCredentialHydrationPending(profileID)
                    if changed {
                        self.saveTrackerState(forProfile: profileID)
                    }
                }
            }
            self.retryPendingTrackerStatePersistence()
            self.retryPendingCredentialOnlyAccounts()
            self.presentLatchedTraktAuthenticationNoticeIfNeeded(owner: self.activeProfileID)
        }
        if Thread.isMainThread {
            retry()
        } else {
            DispatchQueue.main.async(execute: retry)
        }
    }

    @objc private func experimentalCloudRestoreRecoveryDidComplete() {
        let reload = { [weak self] in
            guard let self else { return }
#if os(iOS)

            guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync else {
                self.setAccountBoundaryRecoveryGlobalBlock(true)
                return
            }
            guard case .none = BackupManager.accountBoundaryTrackerCleanupAuthority() else {
                _ = self.completeCommittedAccountBoundaryCleanupBeforeLoadingState()
                return
            }
#endif
            self.reloadTrackerStateAfterCompletedCloudRecovery()
        }
        if Thread.isMainThread {
            reload()
        } else {
            DispatchQueue.main.async(execute: reload)
        }
    }

    private func reloadTrackerStateAfterCompletedCloudRecovery() {
        setAccountBoundaryRecoveryGlobalBlock(false)
        trackerStateStatusLock.lock()
        let quarantined = accountBoundaryQuarantinedProfileIDs
        accountBoundaryQuarantinedProfileIDs.removeAll()
        unreadableTrackerStateProfileIDs.subtract(quarantined)
        trackerStateStatusLock.unlock()

        retryPendingDiscardedProfileCleanup()
        retryPendingCredentialDeletions()
        guard !trackerDeletionJournalsBlockOperations() else {
            trackerState = TrackerState()
            markTrackerStateReloadPendingAfterDeletionJournalRecovery()
            return
        }
        let profileID = activeProfileID
        trackerState = TrackerState()
        if let pending = pendingTrackerState(forProfile: profileID) {
            trackerState = pending
        } else {
            loadTrackerState(forProfile: profileID)
        }
        retryPendingTrackerStatePersistence()
        retryPendingCredentialOnlyAccounts()
    }

    func saveTrackerState(forProfile profileID: UUID? = nil) {
        let profileID = profileID ?? activeProfileID
        guard !accountBoundaryRecoveryBlocksStateAccess(),
              !isDiscarded(profileID),
              !trackerStateIsUnreadable(profileID),
              profileID == activeProfileID else { return }
        queueTrackerStatePersistence(trackerState, forProfile: profileID)
    }

    private enum CredentialSafePersistencePreparation {
        case ready(materialized: TrackerState, redacted: TrackerState)
        case unavailable(String)
    }

    private func credentialSafePersistencePreparation(
        _ state: TrackerState,
        forProfile profileID: UUID,
        pendingAuthority: PendingTrackerStatePersistence
    ) -> CredentialSafePersistencePreparation {
        guard pendingTrackerStateAuthorityIsCurrent(
            pendingAuthority,
            forProfile: profileID
        ) else {
            return .unavailable("pending persistence authority was superseded")
        }
        guard Self.trackerAccountsAreStructurallyValid(state.accounts) else {
            return .unavailable("tracker-account metadata failed structural validation")
        }
        var materialized = state
        var accounts: [TrackerAccount] = []
        accounts.reserveCapacity(state.accounts.count)

        for original in state.accounts {
            var account = original
            if account.isConnected {
                if account.accessToken.isEmpty {
                    switch hydrateTrackerCredential(
                        account,
                        profileID: profileID,
                        pendingAuthority: pendingAuthority
                    ) {
                    case .found(let hydrated, _):
                        account = hydrated
                    case .absent:

                        continue
                    case .temporarilyUnavailable(let status):
                        return .unavailable("credential hydration status \(status)")
                    }
                }
                guard storeTrackerCredential(
                    account,
                    profileID: profileID,
                    pendingAuthority: pendingAuthority
                ) else {
                    return .unavailable("credential store failed")
                }
            } else if !removeTrackerCredential(
                account.service,
                profileID: profileID,
                pendingAuthority: pendingAuthority
            ) {
                return .unavailable("credential removal failed")
            }
            accounts.append(account)
        }

        materialized.accounts = accounts
        var redacted = materialized
        redacted.accounts = materialized.accounts.map { account in
            var account = account
            account.accessToken = ""
            account.refreshToken = nil
            account.expiresAt = nil
            return account
        }
        return .ready(materialized: materialized, redacted: redacted)
    }

    private func queueTrackerStatePersistence(_ state: TrackerState, forProfile profileID: UUID) {
        guard !accountBoundaryRecoveryBlocksStateAccess(),
              !isDiscarded(profileID),
              !trackerStateIsUnreadable(profileID) else { return }
        let pending = retainPendingTrackerState(state, forProfile: profileID)
        attemptPendingTrackerStatePersistence(pending, forProfile: profileID)
    }

    private func retryPendingTrackerStatePersistence() {
        guard !accountBoundaryRecoveryBlocksStateAccess() else { return }
        for (profileID, pending) in allPendingTrackerStateEntries() {
            attemptPendingTrackerStatePersistence(pending, forProfile: profileID)
        }
    }

    private func retryPendingCredentialOnlyAccounts() {
        guard !accountBoundaryRecoveryBlocksStateAccess() else { return }
        for (profileID, account) in allPendingCredentialOnlyAccounts() {
            guard !isDiscarded(profileID),
                  ProfileManager.shared.profile(with: profileID) != nil else { continue }
            guard storeTrackerCredential(
                account,
                profileID: profileID,
                pendingCredentialOnlyAuthority: account
            ) else { continue }
            clearPendingCredentialOnlyAccount(
                matching: account,
                forProfile: profileID
            )
        }
    }

    private func retryPendingCredentialDeletions() {
        guard !trackerDeletionJournalSourcesAreUnreadable() else { return }
        for (profileID, service) in allPendingCredentialDeletions() {
            guard removeTrackerCredential(service, profileID: profileID) else { continue }
            if profileID == activeProfileID,
               let index = trackerState.accounts.firstIndex(where: {
                   $0.service == service
               }) {
                trackerState.accounts[index].isConnected = false
                trackerState.accounts[index].accessToken = ""
                trackerState.accounts[index].refreshToken = nil
                trackerState.accounts[index].expiresAt = nil
            }
        }
    }

    private func completeCommittedAccountBoundaryCleanupBeforeLoadingState() -> Set<UUID> {
        var quarantinedProfileIDs = Set<UUID>()
#if os(iOS)
        let cleanupAuthority = BackupManager.accountBoundaryTrackerCleanupAuthority()
        let recoveryGateIsBlocking = MediaStateAccountBoundaryRecoveryGate.isBlockingSync
        switch cleanupAuthority {
        case .none:
            if recoveryGateIsBlocking {
                setAccountBoundaryRecoveryGlobalBlock(true)
            } else if accountBoundaryRecoveryGloballyBlocksOperations() {

                reloadTrackerStateAfterCompletedCloudRecovery()
            }
            return quarantinedProfileIDs
        case .blocked:
            setAccountBoundaryRecoveryGlobalBlock(true)
            return quarantinedProfileIDs
        case .authorized(let context):
            setAccountBoundaryRecoveryGlobalBlock(true)
            let cleanupProfileIDs = ExperimentalCloudTrackerAccountBoundaryPolicy.profileIDsToClear(
                outgoingProfileIDs: Set(context.outgoingProfileIDs),
                restoredTrackerProfileIDs: Set(context.restoredTrackerProfileIDs)
            )
            for profileID in cleanupProfileIDs {
                quarantinedProfileIDs.insert(profileID)

                markAccountBoundaryQuarantined(profileID)
                var profileCleanupIsDurablyProtected = true
                _ = invalidateAccountBoundary(for: profileID)
                let stateURL = Self.stateURL(for: profileID)
                let removedStateFile = trackerStatePersistenceQueue.sync {
                    do {
                        if FileManager.default.fileExists(atPath: stateURL.path) {
                            try FileManager.default.removeItem(at: stateURL)
                        }
                        return true
                    } catch {
                        return false
                    }
                }
                profileCleanupIsDurablyProtected = profileCleanupIsDurablyProtected && removedStateFile
                for service in TrackerService.allCases {
                    let outcome = removeTrackerCredentialOutcome(service, profileID: profileID)
                    profileCleanupIsDurablyProtected = profileCleanupIsDurablyProtected
                        && outcome.deletionIsDurablyProtected
                }
                profileCleanupIsDurablyProtected = clearTraktHistoryWriteReceipts(for: profileID)
                    && profileCleanupIsDurablyProtected
                if !profileCleanupIsDurablyProtected {
                    Logger.shared.log(
                        "TrackerManager: committed account-boundary cleanup remains quarantined for profile \(profileID) and will retry",
                        type: "Tracker"
                    )
                }

            }
        }
#endif
        return quarantinedProfileIDs
    }

    private func attemptPendingTrackerStatePersistence(
        _ pending: PendingTrackerStatePersistence,
        forProfile profileID: UUID
    ) {
        guard !accountBoundaryRecoveryBlocksStateAccess(),
              !isDiscarded(profileID),
              !trackerStateIsUnreadable(profileID),
              pendingTrackerStateAuthorityIsCurrent(pending, forProfile: profileID),
              ProfileManager.shared.profile(with: profileID) != nil else { return }

        let state = profileID == activeProfileID ? trackerState : pending.state
        switch credentialSafePersistencePreparation(
            state,
            forProfile: profileID,
            pendingAuthority: pending
        ) {
        case .unavailable(let reason):
            Logger.shared.log(
                "TrackerManager: deferred tracker-state persistence for profile \(profileID); \(reason). Existing disk bytes were preserved.",
                type: "Error"
            )
        case .ready(let materialized, let redacted):
            guard updatePendingTrackerState(
                materialized,
                forProfile: profileID,
                matching: pending.id
            ) else { return }
            persistStateSnapshot(
                redacted,
                forProfile: profileID,
                pendingAuthority: pending
            ) { [weak self] succeeded in
                guard succeeded else { return }
                self?.clearPendingTrackerState(forProfile: profileID, matching: pending.id)
            }
        }
    }

    private func persistStateSnapshot(
        _ state: TrackerState,
        forProfile profileID: UUID,
        pendingAuthority: PendingTrackerStatePersistence,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !accountBoundaryRecoveryBlocksStateAccess(),
              !isDiscarded(profileID),
              !trackerStateIsUnreadable(profileID),
              pendingTrackerStateAuthorityIsCurrent(
                  pendingAuthority,
                  forProfile: profileID
              ) else {
            completion?(false)
            return
        }

        guard state.accounts.allSatisfy({
            $0.accessToken.isEmpty && ($0.refreshToken?.isEmpty != false)
        }) else {
            Logger.shared.log(
                "TrackerManager: blocked an attempt to serialize tracker credentials outside Keychain",
                type: "Error"
            )
            completion?(false)
            return
        }
        let stateURL = Self.stateURL(for: profileID)
        trackerStatePersistenceQueue.async { [weak self] in
            guard let self,
                  !self.accountBoundaryRecoveryBlocksStateAccess(),
                  !self.isDiscarded(profileID),
                  !self.trackerStateIsUnreadable(profileID),
                  self.pendingTrackerStateAuthorityIsCurrent(
                      pendingAuthority,
                      forProfile: profileID
                  ),
                  let encoded = try? JSONEncoder().encode(state),
                  encoded.count <= Self.maximumPersistedTrackerStateBytes else {
                completion?(false)
                return
            }
            do {
                try encoded.write(to: stateURL, options: .atomic)
                completion?(true)
            } catch {
                Logger.shared.log(
                    "TrackerManager: failed to persist tracker state for profile \(profileID): \(error.localizedDescription)",
                    type: "Error"
                )
                completion?(false)
            }
        }
    }

    private func persistDisconnectedStateSynchronously(
        service: TrackerService,
        profileID: UUID
    ) -> Bool {
        guard profileID == activeProfileID,
              !trackerStateIsUnreadable(profileID) else { return false }
        var state = trackerState
        if let index = state.accounts.firstIndex(where: { $0.service == service }) {
            state.accounts[index].isConnected = false
            state.accounts[index].accessToken = ""
            state.accounts[index].refreshToken = nil
            state.accounts[index].expiresAt = nil
        } else {
            state.accounts.append(
                TrackerAccount(
                    service: service,
                    username: "Disconnected",
                    accessToken: "",
                    refreshToken: nil,
                    expiresAt: nil,
                    userId: "local-disconnect-tombstone",
                    isConnected: false
                )
            )
        }
        state.accounts = state.accounts.map { account in
            var redacted = account
            redacted.accessToken = ""
            redacted.refreshToken = nil
            redacted.expiresAt = nil
            return redacted
        }
        guard Self.trackerAccountsAreStructurallyValid(state.accounts),
              let encoded = try? JSONEncoder().encode(state),
              encoded.count <= Self.maximumPersistedTrackerStateBytes else { return false }
        let stateURL = Self.stateURL(for: profileID)
        return trackerStatePersistenceQueue.sync {
            do {
                try encoded.write(to: stateURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    @MainActor
    @discardableResult
    func commitCompletedSignIn(
        _ account: TrackerAccount,
        forProfile owner: UUID,
        accountBoundaryGeneration: UInt64,
        serviceGeneration: UInt64
    ) -> Bool {
        guard trackerProfileAcceptsOperations(owner),
              accountBoundaryGenerationIsCurrent(accountBoundaryGeneration, for: owner),
              trackerServiceGenerationIsCurrent(
                  serviceGeneration,
                  service: account.service,
                  profileID: owner
              ) else {
            Logger.shared.log(
                "TrackerManager: dropped a completed \(account.service.rawValue) sign-in because its cloud-account boundary changed",
                type: "Tracker"
            )
            return false
        }
        if account.service == .trakt {
            traktTokenRefreshTasks[owner]?.task.cancel()
            traktTokenRefreshTasks[owner] = nil
            withTraktAuthenticationRequiredLatches {
                $0.clear(owner)
            }
        } else if account.service == .myAnimeList {
            malTokenRefreshTasks[owner]?.task.cancel()
            malTokenRefreshTasks[owner] = nil
        }
        isAuthenticating = false
        guard activeProfileID == owner else {

            persistAccountIntoInactiveProfile(account, profileID: owner)
            Logger.shared.log(
                "TrackerManager: \(account.service.displayName) sign-in completed after a profile switch; stored it against profile \(owner) instead of the active one",
                type: "Tracker"
            )
            return true
        }
        trackerState.addOrUpdateAccount(account)
        saveTrackerState(forProfile: owner)
        authError = nil
        clearAuthenticationNotice(for: account.service)
        return true
    }

    @MainActor
    private func commitRefreshedAccount(
        _ account: TrackerAccount,
        replacing previousAccount: TrackerAccount,
        forProfile owner: UUID,
        accountBoundaryGeneration: UInt64,
        serviceGeneration: UInt64
    ) throws {
        guard account.service == previousAccount.service,
              account.userId == previousAccount.userId else {

            throw CancellationError()
        }
        guard trackerProfileAcceptsOperations(owner),
              accountBoundaryGenerationIsCurrent(accountBoundaryGeneration, for: owner),
              trackerServiceGenerationIsCurrent(
                  serviceGeneration,
                  service: previousAccount.service,
                  profileID: owner
              ) else {
            Logger.shared.log(
                "TrackerManager: dropped a refreshed \(account.service.rawValue) credential because its cloud-account boundary changed",
                type: "Tracker"
            )
            throw CancellationError()
        }

        guard let state = trackerState(forProfile: owner),
              var current = state.accounts.first(where: {
                  $0.service == previousAccount.service && $0.isConnected
              }) else {

            throw CancellationError()
        }
        if current.accessToken.isEmpty {
            switch hydrateTrackerCredential(current, profileID: owner) {
            case .found(let hydrated, _):
                current = hydrated
            case .absent, .temporarilyUnavailable:
                throw CancellationError()
            }
        }
        if current.userId == account.userId,
           current.accessToken == account.accessToken,
           current.refreshToken == account.refreshToken {

            return
        }
        guard current.userId == previousAccount.userId,
              current.accessToken == previousAccount.accessToken,
              current.refreshToken == previousAccount.refreshToken else {

            throw CancellationError()
        }
        guard activeProfileID == owner else {
            persistAccountIntoInactiveProfile(account, profileID: owner)
            if account.service == .trakt {
                _ = traktAuthenticationIsLatched(
                    owner: owner,
                    accountBoundaryGeneration: accountBoundaryGeneration,
                    account: account
                )
            }
            Logger.shared.log(
                "TrackerManager: \(account.service.displayName) token refresh completed after a profile switch; stored it against profile \(owner)",
                type: "Tracker"
            )
            return
        }
        trackerState.addOrUpdateAccount(account)
        saveTrackerState(forProfile: owner)
        let traktAuthenticationRemainsLatched = account.service == .trakt
            && traktAuthenticationIsLatched(
                owner: owner,
                accountBoundaryGeneration: accountBoundaryGeneration,
                account: account
            )
        if !traktAuthenticationRemainsLatched {
            clearAuthenticationNotice(for: account.service)
        }
    }

    private func requireOwner(
        _ owner: UUID,
        operationGeneration: UInt64? = nil
    ) throws {
        guard !accountBoundaryRecoveryBlocksNetworkOperations(),
              ProfileManager.shared.isStillActive(owner),
              (operationGeneration.map {
                  Self.trackerOperationAuthorityIsCurrent(
                      authorityGeneration: $0,
                      currentGeneration: trackerOperationGenerationSnapshot()
                  )
              } ?? true) else {
            Logger.shared.log(
                "TrackerManager: abandoned an import commit; its profile or cloud-account authority changed while it ran",
                type: "Tracker"
            )
            throw CancellationError()
        }
    }

    private func persistAccountIntoInactiveProfile(_ account: TrackerAccount, profileID: UUID) {

        guard !isDiscarded(profileID), ProfileManager.shared.profile(with: profileID) != nil else {
            removeTrackerCredential(account.service, profileID: profileID)
            Logger.shared.log(
                "TrackerManager: dropped a late \(account.service.rawValue) credential for a deleted profile",
                type: "Tracker"
            )
            return
        }
        guard var state = trackerState(forProfile: profileID) else {

            if !storeTrackerCredential(account, profileID: profileID) {
                retainPendingCredentialOnlyAccount(account, forProfile: profileID)
            }
            Logger.shared.log(
                "TrackerManager: kept refreshed \(account.service.rawValue) credentials in Keychain or memory but did not overwrite unreadable tracker state for profile \(profileID)",
                type: "Error"
            )
            return
        }
        state.addOrUpdateAccount(account)

        queueTrackerStatePersistence(state, forProfile: profileID)
    }

    func checkForExpiredTrackerSessions() {
        let now = Date()
        let owner = activeProfileID
        presentLatchedTraktAuthenticationNoticeIfNeeded(owner: owner)
        for account in trackerState.accounts where account.isConnected {
            guard let expiresAt = account.expiresAt, expiresAt <= now else { continue }

            switch account.service {
            case .anilist:

                reportAuthenticationRequired(for: .anilist, owner: owner)
            case .myAnimeList:

                if account.refreshToken?.isEmpty != false {
                    reportAuthenticationRequired(for: account.service, owner: owner)
                }
            case .trakt:

                if account.refreshToken?.isEmpty != false {
                    installTraktAuthenticationRequiredLatch(
                        authority: operationAuthority(for: account, owner: owner)
                    )
                }
            }
        }
    }

    func reconnectTracker(_ service: TrackerService) {
        if authenticationNotice?.service == service {
            authenticationNotice = nil
        }
        authError = nil

        switch service {
        case .anilist:
            startAniListAuth()
        case .myAnimeList:
            startMALAuth()
        case .trakt:
            startTraktAuth()
        }
    }

    private func withTraktAuthenticationRequiredLatches<Result>(
        _ operation: (inout TraktAuthenticationRequiredLatchStore) -> Result
    ) -> Result {
        traktAuthenticationRequiredLatchLock.lock()
        defer { traktAuthenticationRequiredLatchLock.unlock() }
        return operation(&traktAuthenticationRequiredLatches)
    }

    private func traktAuthenticationCredentialIdentity(
        owner: UUID,
        accountBoundaryGeneration: UInt64,
        account: TrackerAccount
    ) -> TraktAuthenticationCredentialIdentity {
        TraktAuthenticationCredentialIdentity(
            owner: owner,
            accountBoundaryGeneration: accountBoundaryGeneration,
            userId: account.userId,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken
        )
    }

    private func presentLatchedTraktAuthenticationNoticeIfNeeded(owner: UUID) {
        let presentation: () -> Void = { [weak self] in
            guard let self else { return }
            self.presentLatchedTraktAuthenticationNoticeOnMain(owner: owner)
        }
        if Thread.isMainThread {
            presentation()
        } else {
            DispatchQueue.main.async(execute: presentation)
        }
    }

    private func presentLatchedTraktAuthenticationNoticeOnMain(owner: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeProfileID == owner,
              let account = trackerState.getAccount(for: .trakt) else {
            return
        }
        let identity = traktAuthenticationCredentialIdentity(
            owner: owner,
            accountBoundaryGeneration: accountBoundaryGeneration(for: owner),
            account: account
        )
        guard traktAuthenticationIsLatched(
            owner: owner,
            accountBoundaryGeneration: identity.accountBoundaryGeneration,
            account: account
        ) else { return }
        let shouldPresent = withTraktAuthenticationRequiredLatches {
            $0.shouldPresent(identity)
        }
        guard shouldPresent else { return }

        let notice = TrackerAuthenticationNotice(service: .trakt)
        if authenticationNotice != notice {
            authenticationNotice = notice
            Logger.shared.log("Trakt authorization expired; user login required", type: "Tracker")
        }
        authError = notice.message
    }

    private func installTraktAuthenticationRequiredLatch(
        authority: TrackerOperationAuthority
    ) {
        guard authority.service == .trakt,
              activeProfileID == authority.owner,
              ProfileManager.shared.isStillActive(authority.owner),
              trackerProfileAcceptsOperations(authority.owner),
              trackerOperationAuthorityIsCurrent(authority.operationGeneration),
              accountBoundaryGenerationIsCurrent(
                  authority.accountBoundaryGeneration,
                  for: authority.owner
              ),
              trackerServiceGenerationIsCurrent(
                  authority.serviceGeneration,
                  service: .trakt,
                  profileID: authority.owner
              ),
              let currentAccount = trackerState.getAccount(for: .trakt),
              authority.matches(currentAccount) else {
            return
        }

        let failedIdentity = TraktAuthenticationCredentialIdentity(
            owner: authority.owner,
            accountBoundaryGeneration: authority.accountBoundaryGeneration,
            userId: authority.userId,
            accessToken: authority.accessToken,
            refreshToken: authority.refreshToken
        )
        let currentIdentity = traktAuthenticationCredentialIdentity(
            owner: authority.owner,
            accountBoundaryGeneration: authority.accountBoundaryGeneration,
            account: currentAccount
        )
        let installed = withTraktAuthenticationRequiredLatches {
            $0.install(
                failedIdentity: failedIdentity,
                currentIdentity: currentIdentity
            )
        }
        guard installed else {
            presentLatchedTraktAuthenticationNoticeIfNeeded(owner: authority.owner)
            return
        }
        presentLatchedTraktAuthenticationNoticeIfNeeded(owner: authority.owner)
    }

    private func handleTraktRefreshFailure(
        _ error: Error,
        authority: TrackerOperationAuthority
    ) {
        guard let failure = error as? TraktOAuthRefreshFailure,
              failure.disposition == .authenticationRequired else {
            return
        }
        installTraktAuthenticationRequiredLatch(authority: authority)
    }

    private func traktAuthenticationIsLatched(
        owner: UUID,
        accountBoundaryGeneration: UInt64,
        account: TrackerAccount
    ) -> Bool {
        let identity = traktAuthenticationCredentialIdentity(
            owner: owner,
            accountBoundaryGeneration: accountBoundaryGeneration,
            account: account
        )
        let latchState = withTraktAuthenticationRequiredLatches { latches in
            let hadLatch = latches.hasLatch(for: owner)
            let isLatched = latches.blocks(identity)
            return (hadLatch, isLatched)
        }
        if latchState.0, !latchState.1 {
            clearTraktAuthenticationNoticeIfMatching(owner: owner)
        }
        return latchState.1
    }

    private func clearTraktAuthenticationNoticeIfMatching(owner: UUID) {
        let clearing = { [weak self] in
            guard let self, self.activeProfileID == owner else { return }
            let matchingMessage = TrackerAuthenticationNotice(service: .trakt).message
            if self.authenticationNotice?.service == .trakt {
                self.authenticationNotice = nil
            }
            if self.authError == matchingMessage {
                self.authError = nil
            }
        }
        if Thread.isMainThread {
            clearing()
        } else {
            DispatchQueue.main.async(execute: clearing)
        }
    }

    private func traktOperationIsBlockedByAuthentication(
        owner: UUID,
        account: TrackerAccount
    ) -> Bool {
        guard traktAuthenticationIsLatched(
            owner: owner,
            accountBoundaryGeneration: accountBoundaryGeneration(for: owner),
            account: account
        ) else {
            return false
        }
        presentLatchedTraktAuthenticationNoticeIfNeeded(owner: owner)
        return true
    }

    private static func isTraktAuthenticationRequiredError(_ error: Error) -> Bool {
        if error is TraktAuthenticationRequiredError {
            return true
        }
        guard let failure = error as? TraktOAuthRefreshFailure else { return false }
        return failure.disposition == .authenticationRequired
    }

    private func reportAuthenticationRequired(for service: TrackerService, owner: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.activeProfileID == owner else {
                Logger.shared.log(
                    "TrackerManager: dropped a \(service.displayName) login-required notice; its owning profile is no longer active",
                    type: "Plugin"
                )
                return
            }
            guard self.trackerState.accounts.contains(where: { $0.service == service && $0.isConnected }) else {
                return
            }

            let notice = TrackerAuthenticationNotice(service: service)
            if self.authenticationNotice != notice {
                self.authenticationNotice = notice
                Logger.shared.log("\(service.displayName) authorization expired; user login required", type: "Tracker")
            }
            self.authError = notice.message
        }
    }

    @MainActor
    private func clearAuthenticationNotice(for service: TrackerService) {
        let matchingMessage = TrackerAuthenticationNotice(service: service).message
        if authenticationNotice?.service == service {
            authenticationNotice = nil
        }
        if authError == matchingMessage {
            authError = nil
        }
    }

    private static func malRefreshFailureRequiresLogin(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "MALAuth" && nsError.code == 401
    }

    func setSyncEnabled(_ enabled: Bool) {
        trackerState.syncEnabled = enabled
        saveTrackerState()
    }

#if !os(tvOS)
    func setReaderSyncEnabled(_ enabled: Bool) {
        trackerState.readerSyncEnabled = enabled
        saveTrackerState()
    }
#endif

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

            refreshTraktWatchlistCollection()
        }
    }

    func hasConnectedAccount(_ service: TrackerService) -> Bool {
        trackerState.getAccount(for: service) != nil
    }

    func setBackupRestoreSyncSuppressed(_ suppressed: Bool) {
        let isSuppressed = backupRestoreSyncQueue.sync { () -> Bool in
            // Bump on begin and end. A pre-restore authority is stale as soon
            // as suppression begins; an authority accidentally captured while
            // suppressed is stale once the window closes.
            trackerOperationGeneration &+= 1
            if suppressed {
                backupRestoreSyncSuppressionCount += 1
            } else {
                backupRestoreSyncSuppressionCount = max(
                    backupRestoreSyncSuppressionCount - 1,
                    0
                )
            }
            return backupRestoreSyncSuppressionCount > 0
        }
        // Every generation transition revokes the tasks represented by these
        // pending entries. Drop them immediately so a newly-authorized task
        // is not suppressed while an old completion drains.
        traktScrobbleQueue.sync {
            traktScrobblePendingByKey.removeAll()
        }
        Logger.shared.log(
            "Tracker sync suppression during backup restore: \(isSuppressed ? "enabled" : "disabled")",
            type: "Tracker"
        )
    }

    private func isBackupRestoreSyncSuppressed() -> Bool {
        backupRestoreSyncQueue.sync {
            backupRestoreSyncSuppressionCount > 0
        }
    }

    private func trackerOperationGenerationSnapshot() -> UInt64 {
        backupRestoreSyncQueue.sync { trackerOperationGeneration }
    }

    @discardableResult
    private func invalidateTrackerOperationAuthority() -> UInt64 {
        backupRestoreSyncQueue.sync {
            trackerOperationGeneration &+= 1
            return trackerOperationGeneration
        }
    }

    private func trackerOperationAuthorityIsCurrent(_ generation: UInt64) -> Bool {
        backupRestoreSyncQueue.sync {
            backupRestoreSyncSuppressionCount == 0
                && Self.trackerOperationAuthorityIsCurrent(
                    authorityGeneration: generation,
                    currentGeneration: trackerOperationGeneration
                )
        }
    }

    static func trackerOperationAuthorityIsCurrent(
        authorityGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        authorityGeneration == currentGeneration
    }

    private func loadTraktHistoryWriteReceipts() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.traktHistoryWriteReceiptsDefaultsKey) else {
            return
        }
        guard data.count <= Self.maximumTraktHistoryWriteReceiptBytes,
              var decoded = try? JSONDecoder().decode(
                  [String: TraktHistoryWriteReceipt].self,
                  from: data
              ),
              decoded.count <= Self.maximumTraktHistoryWriteReceiptCount,
              traktHistoryWriteReceiptsAreValid(decoded, now: Date()) else {
            traktHistoryReceiptJournalIsUnreadable = true
            Logger.shared.log(
                "TrackerManager: Trakt history write-ahead journal is unreadable; history POSTs remain fail-closed",
                type: "Error"
            )
            return
        }

        var migratedReceiptIdentity = false
        for key in decoded.keys where decoded[key]?.receiptID == nil {
            decoded[key]?.receiptID = UUID()
            migratedReceiptIdentity = true
        }

        traktHistoryWriteReceiptQueue.sync {
            traktHistoryWriteReceipts = decoded
            let pruned = pruneTraktHistoryWriteReceiptsLocked(now: Date())
            if (migratedReceiptIdentity || pruned),
               !persistTraktHistoryWriteReceiptsLocked() {
                traktHistoryReceiptJournalNeedsPersistence = true
            }
        }
    }

    private func traktHistoryWriteReceiptsAreValid(
        _ receipts: [String: TraktHistoryWriteReceipt],
        now: Date
    ) -> Bool {
        let lowercaseHexCharacters = Set("0123456789abcdef")
        return receipts.allSatisfy { key, receipt in
            guard key.count == 64,
                  key.allSatisfy({ lowercaseHexCharacters.contains($0) }),
                  traktHistoryReceiptDateIsPlausible(receipt.watchedAt, now: now),
                  traktHistoryReceiptDateIsPlausible(receipt.lastAttemptAt, now: now) else {
                return false
            }
            guard let confirmedAt = receipt.confirmedAt else { return true }
            return traktHistoryReceiptDateIsPlausible(confirmedAt, now: now)
        }
    }

    private func traktHistoryWriteReceiptKey(
        owner: UUID,
        accountUserId: String,
        kind: String,
        traktId: Int
    ) -> String {
        let components = [
            owner.uuidString.lowercased(),
            accountUserId,
            kind,
            String(traktId)
        ]
        let unambiguous = components
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(unambiguous.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func beginTraktHistoryWrite(
        owner: UUID,
        accountUserId: String,
        kind: String,
        traktId: Int
    ) -> TraktHistoryWriteAttempt? {
        let key = traktHistoryWriteReceiptKey(
            owner: owner,
            accountUserId: accountUserId,
            kind: kind,
            traktId: traktId
        )

        return traktHistoryWriteReceiptQueue.sync {
            guard !traktHistoryReceiptJournalIsUnreadable else { return nil }
            let now = Date()
            if pruneTraktHistoryWriteReceiptsLocked(now: now) {
                traktHistoryReceiptJournalNeedsPersistence = true
            }
            if traktHistoryReceiptJournalNeedsPersistence,
               !persistTraktHistoryWriteReceiptsLocked() {
                return nil
            }

            if var receipt = traktHistoryWriteReceipts[key], receipt.receiptID == nil {
                receipt.receiptID = UUID()
                traktHistoryWriteReceipts[key] = receipt
                guard persistTraktHistoryWriteReceiptsLocked() else {
                    return nil
                }
            }

            if let inFlightReceiptID = traktHistoryWritesInFlight[key],
               let receipt = traktHistoryWriteReceipts[key],
               receipt.receiptID == inFlightReceiptID {
                return TraktHistoryWriteAttempt(
                    key: key,
                    watchedAt: receipt.watchedAt,
                    receiptID: inFlightReceiptID,
                    disposition: .deferPending
                )
            }
            traktHistoryWritesInFlight.removeValue(forKey: key)

            if var receipt = traktHistoryWriteReceipts[key] {
                guard let receiptID = receipt.receiptID else { return nil }
                let decision = TraktHistoryReceiptReconciliationPolicy.decision(
                    lastAttemptAt: receipt.lastAttemptAt,
                    confirmedAt: receipt.confirmedAt,
                    now: now,
                    reconciliationDelay: traktHistoryReconciliationDelay,
                    confirmedInterval: watchSyncDedupeInterval
                )
                switch decision {
                case .suppressConfirmed:
                    return TraktHistoryWriteAttempt(
                        key: key,
                        watchedAt: receipt.watchedAt,
                        receiptID: receiptID,
                        disposition: .suppressConfirmed
                    )
                case .waitForReconciliation:
                    return TraktHistoryWriteAttempt(
                        key: key,
                        watchedAt: receipt.watchedAt,
                        receiptID: receiptID,
                        disposition: .deferPending
                    )
                case .reconcile:
                    let previousReceipt = receipt
                    receipt.lastAttemptAt = now
                    traktHistoryWriteReceipts[key] = receipt
                    guard persistTraktHistoryWriteReceiptsLocked() else {
                        traktHistoryWriteReceipts[key] = previousReceipt
                        _ = persistTraktHistoryWriteReceiptsLocked()
                        return TraktHistoryWriteAttempt(
                            key: key,
                            watchedAt: receipt.watchedAt,
                            receiptID: receiptID,
                            disposition: .deferPending
                        )
                    }
                    traktHistoryWritesInFlight[key] = receiptID
                    return TraktHistoryWriteAttempt(
                        key: key,
                        watchedAt: receipt.watchedAt,
                        receiptID: receiptID,
                        disposition: .reconcile
                    )
                }
            }

            let previousReceipts = traktHistoryWriteReceipts
            if traktHistoryWriteReceipts.count >= Self.maximumTraktHistoryWriteReceiptCount {
                let overflow = traktHistoryWriteReceipts.count - Self.maximumTraktHistoryWriteReceiptCount + 1
                let evictableKeys = traktHistoryWriteReceipts
                    .filter { entryKey, receipt in
                        traktHistoryWritesInFlight[entryKey] != receipt.receiptID
                    }
                    .sorted { $0.value.lastAttemptAt < $1.value.lastAttemptAt }
                    .prefix(overflow)
                    .map(\.key)
                guard evictableKeys.count == overflow else { return nil }
                for evictedKey in evictableKeys {
                    traktHistoryWriteReceipts.removeValue(forKey: evictedKey)
                }
            }
            let watchedAt = TraktHistoryReceiptReconciliationPolicy.canonicalMinute(now)
            let receiptID = UUID()
            let receipt = TraktHistoryWriteReceipt(
                owner: owner,
                watchedAt: watchedAt,
                lastAttemptAt: now,
                confirmedAt: nil,
                receiptID: receiptID
            )
            traktHistoryWriteReceipts[key] = receipt

            guard traktHistoryWriteReceipts[key] != nil,
                  persistTraktHistoryWriteReceiptsLocked() else {
                traktHistoryWriteReceipts = previousReceipts
                _ = persistTraktHistoryWriteReceiptsLocked()
                return nil
            }

            traktHistoryWritesInFlight[key] = receiptID
            return TraktHistoryWriteAttempt(
                key: key,
                watchedAt: receipt.watchedAt,
                receiptID: receiptID,
                disposition: .send
            )
        }
    }

    private func confirmTraktHistoryWrite(_ attempt: TraktHistoryWriteAttempt) {
        traktHistoryWriteReceiptQueue.sync {
            guard !traktHistoryReceiptJournalIsUnreadable else { return }
            guard var receipt = traktHistoryWriteReceipts[attempt.key],
                  receipt.watchedAt == attempt.watchedAt,
                  receipt.receiptID == attempt.receiptID else {
                return
            }
            let now = Date()
            receipt.lastAttemptAt = now
            receipt.confirmedAt = now
            traktHistoryWriteReceipts[attempt.key] = receipt
            if !persistTraktHistoryWriteReceiptsLocked() {

                traktHistoryReceiptJournalNeedsPersistence = true
            }
        }
    }

    private func abandonTraktHistoryWriteReceipt(_ attempt: TraktHistoryWriteAttempt) {
        traktHistoryWriteReceiptQueue.sync {
            guard !traktHistoryReceiptJournalIsUnreadable else { return }
            guard case .send = attempt.disposition,
                  traktHistoryWriteReceipts[attempt.key]?.watchedAt == attempt.watchedAt,
                  traktHistoryWriteReceipts[attempt.key]?.receiptID == attempt.receiptID else {
                return
            }
            let previousReceipts = traktHistoryWriteReceipts
            let previousWritesInFlight = traktHistoryWritesInFlight
            traktHistoryWriteReceipts.removeValue(forKey: attempt.key)
            if traktHistoryWritesInFlight[attempt.key] == attempt.receiptID {
                traktHistoryWritesInFlight.removeValue(forKey: attempt.key)
            }
            guard persistTraktHistoryWriteReceiptsLocked() else {

                traktHistoryWriteReceipts = previousReceipts
                traktHistoryWritesInFlight = previousWritesInFlight
                _ = persistTraktHistoryWriteReceiptsLocked()
                return
            }
        }
    }

    private func finishTraktHistoryWriteAttempt(_ attempt: TraktHistoryWriteAttempt) {
        traktHistoryWriteReceiptQueue.sync {
            guard traktHistoryWritesInFlight[attempt.key] == attempt.receiptID else { return }
            traktHistoryWritesInFlight.removeValue(forKey: attempt.key)
        }
    }

    private func reconcileTraktHistoryWrite(
        _ attempt: TraktHistoryWriteAttempt,
        mediaType: String,
        traktId: Int,
        account: TrackerAccount,
        owner: UUID,
        authority: TrackerOperationAuthority,
        allowsRefreshRetry: Bool = true
    ) async -> TraktHistoryReconciliationResult {
        guard authority.owner == owner,
              authority.matches(account),
              (mediaType == "episodes" || mediaType == "movies"),
              traktId > 0,
              !traktClientId.isEmpty,
              let bounds = traktHistoryReconciliationDateBounds(for: attempt.watchedAt) else {
            return .unavailable
        }

        var declaredPageCount: Int?
        for page in 1...traktHistoryReconciliationMaximumPages {
            guard var components = URLComponents(
                string: "https://api.trakt.tv/sync/history/\(mediaType)/\(traktId)"
            ) else {
                return .unavailable
            }
            components.queryItems = [
                URLQueryItem(name: "start_at", value: bounds.start),
                URLQueryItem(name: "end_at", value: bounds.end),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: String(traktHistoryReconciliationPageLimit))
            ]
            guard let url = components.url else { return .unavailable }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("2", forHTTPHeaderField: "trakt-api-version")

            do {
                let (data, response) = try await sendTrackerRequest(
                    request,
                    provider: .trakt,
                    maxRetries: 2,
                    reportRateLimitStatus: false,
                    reportAuthenticationFailure: !allowsRefreshRetry,
                    beforeAttempt: { [weak self] in
                        guard let self,
                              await self.operationAuthorityIsCurrent(authority) else {
                            throw CancellationError()
                        }
                    }
                )

                if response.statusCode == 401, allowsRefreshRetry {
                    let refreshed = try await refreshedTraktAccountIfNeeded(
                        account,
                        force: true,
                        requiredOwner: owner,
                        requiredAuthority: authority
                    )
                    guard refreshed.userId == account.userId else {
                        return .unavailable
                    }
                    return await reconcileTraktHistoryWrite(
                        attempt,
                        mediaType: mediaType,
                        traktId: traktId,
                        account: refreshed,
                        owner: owner,
                        authority: authority.replacingCredential(with: refreshed),
                        allowsRefreshRetry: false
                    )
                }

                guard response.statusCode == 200,
                      data.count <= traktHistoryReconciliationMaximumPageBytes,
                      let entries = try? JSONDecoder().decode(
                          [TraktHistoryEntry].self,
                          from: data
                      ),
                      entries.count <= traktHistoryReconciliationPageLimit else {
                    return .unavailable
                }

                let watchedDates = entries.compactMap {
                    parseTraktHistoryWatchedAt($0.watchedAt)
                }
                guard watchedDates.count == entries.count else {
                    return .unavailable
                }
                if TraktHistoryReceiptReconciliationPolicy.containsReceipt(
                    watchedAt: attempt.watchedAt,
                    historyWatchedAt: watchedDates
                ) {
                    return .found
                }

                guard let rawPage = response.value(
                          forHTTPHeaderField: "X-Pagination-Page"
                      ),
                      let responsePage = Self.boundedPaginationInteger(
                          rawPage,
                          in: 1...traktHistoryReconciliationMaximumPages
                      ),
                      responsePage == page,
                      let rawPageLimit = response.value(
                          forHTTPHeaderField: "X-Pagination-Limit"
                      ),
                      let responsePageLimit = Self.boundedPaginationInteger(
                          rawPageLimit,
                          in: 1...traktHistoryReconciliationPageLimit
                      ),
                      entries.count <= responsePageLimit,
                      let rawPageCount = response.value(
                          forHTTPHeaderField: "X-Pagination-Page-Count"
                      ),
                      let pageCount = Self.boundedPaginationInteger(
                          rawPageCount,
                          in: 0...traktHistoryReconciliationMaximumPages
                      ),
                      declaredPageCount == nil || declaredPageCount == pageCount else {

                    return .unavailable
                }
                declaredPageCount = pageCount
                if pageCount == 0 {
                    guard page == 1, entries.isEmpty else { return .unavailable }
                    return await authoritativeTraktHistoryAbsence(
                        account: account,
                        owner: owner,
                        authority: authority
                    )
                }
                guard page <= pageCount else { return .unavailable }
                if page == pageCount {
                    return await authoritativeTraktHistoryAbsence(
                        account: account,
                        owner: owner,
                        authority: authority
                    )
                }
            } catch {
                Logger.shared.log(
                    "Trakt history reconciliation failed for \(mediaType) \(traktId): \(error.localizedDescription)",
                    type: "Tracker"
                )
                return .unavailable
            }
        }

        return .unavailable
    }

    private func authoritativeTraktHistoryAbsence(
        account: TrackerAccount,
        owner: UUID,
        authority: TrackerOperationAuthority
    ) async -> TraktHistoryReconciliationResult {
        guard authority.owner == owner,
              authority.matches(account),
              await operationAuthorityIsCurrent(authority) else {
            return .unavailable
        }
        return .absent(account: account)
    }

    private func traktHistoryReconciliationDateBounds(
        for watchedAt: Date
    ) -> (start: String, end: String)? {
        guard let utcTimeZone = TimeZone(secondsFromGMT: 0) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone
        let day = calendar.startOfDay(for: watchedAt)
        guard let start = calendar.date(byAdding: .day, value: -1, to: day),
              let end = calendar.date(byAdding: .day, value: 1, to: day) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: start), formatter.string(from: end))
    }

    private func parseTraktHistoryWatchedAt(_ value: String) -> Date? {
        guard value.utf8.count <= 64 else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    static func boundedPaginationInteger(
        _ rawValue: String,
        in allowedRange: ClosedRange<Int>
    ) -> Int? {
        guard let value = Int(rawValue), allowedRange.contains(value) else {
            return nil
        }
        return value
    }

    @discardableResult
    private func clearTraktHistoryWriteReceipts(for owner: UUID) -> Bool {
        traktHistoryWriteReceiptQueue.sync {
            guard !traktHistoryReceiptJournalIsUnreadable else { return false }
            let previousReceipts = traktHistoryWriteReceipts
            let previousWritesInFlight = traktHistoryWritesInFlight
            let previousCount = traktHistoryWriteReceipts.count
            traktHistoryWriteReceipts = traktHistoryWriteReceipts.filter { _, receipt in
                receipt.owner != owner
            }
            if traktHistoryWriteReceipts.count != previousCount {
                traktHistoryWritesInFlight = traktHistoryWritesInFlight.filter {
                    traktHistoryWriteReceipts[$0.key]?.receiptID == $0.value
                }
                guard persistTraktHistoryWriteReceiptsLocked() else {

                    traktHistoryWriteReceipts = previousReceipts
                    traktHistoryWritesInFlight = previousWritesInFlight
                    _ = persistTraktHistoryWriteReceiptsLocked()
                    return false
                }
            } else if traktHistoryReceiptJournalNeedsPersistence,
                      !persistTraktHistoryWriteReceiptsLocked() {
                return false
            }
            return true
        }
    }

    @discardableResult
    private func pruneTraktHistoryWriteReceiptsLocked(now: Date) -> Bool {
        let previousCount = traktHistoryWriteReceipts.count

        traktHistoryWriteReceipts = traktHistoryWriteReceipts.filter { _, receipt in
            if let confirmedAt = receipt.confirmedAt {
                return now.timeIntervalSince(confirmedAt) < watchSyncDedupeInterval
            }
            return now.timeIntervalSince(receipt.lastAttemptAt) < traktHistoryReceiptTimeToLive
        }
        return traktHistoryWriteReceipts.count != previousCount
    }

    private func traktHistoryReceiptDateIsPlausible(_ date: Date, now: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
            && date.timeIntervalSince(now) <= traktHistoryReceiptFutureTolerance
    }

    @discardableResult
    private func persistTraktHistoryWriteReceiptsLocked() -> Bool {
        let defaults = UserDefaults.standard
        guard !traktHistoryWriteReceipts.isEmpty else {
            defaults.removeObject(forKey: Self.traktHistoryWriteReceiptsDefaultsKey)
            let succeeded = defaults.synchronize()
            traktHistoryReceiptJournalNeedsPersistence = !succeeded
            return succeeded
        }
        guard let data = try? JSONEncoder().encode(traktHistoryWriteReceipts),
              data.count <= Self.maximumTraktHistoryWriteReceiptBytes else {
            traktHistoryReceiptJournalNeedsPersistence = true
            return false
        }
        defaults.set(data, forKey: Self.traktHistoryWriteReceiptsDefaultsKey)
        let succeeded = defaults.synchronize()
        traktHistoryReceiptJournalNeedsPersistence = !succeeded
        return succeeded
    }

    private func traktWatchedAtString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private enum WatchSyncStart {
        case untracked
        case tracked(TrackerWatchSyncDedupeRegistration)
        case duplicate
    }

    static func normalizedWatchSyncProgress(_ progress: Double) -> Double? {
        guard progress.isFinite else { return nil }
        let percent: Double
        if progress <= 0 {
            percent = 0
        } else if progress <= 1.0 {
            percent = progress * 100.0
        } else {
            percent = progress
        }
        guard percent.isFinite else { return nil }
        return min(max(percent, 0), 100)
    }

    static func watchSyncLogPercent(_ progress: Double) -> Int? {
        guard let normalized = normalizedWatchSyncProgress(progress) else { return nil }
        return Int(exactly: normalized.rounded())
    }

    private func beginWatchSync(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        progress: Double,
        isMovie: Bool,
        playbackContext: EpisodePlaybackContext?,
        owner: UUID,
        account: TrackerAccount
    ) -> WatchSyncStart {
        guard let normalizedProgress = Self.normalizedWatchSyncProgress(progress),
              normalizedProgress >= 85 else {
            return .untracked
        }

        let providerKey = playbackContext?.anilistMediaId.map { String($0) } ?? "none"
        let specialKey = playbackContext?.isSpecial == true ? "special" : "regular"

        let accountKey = "\(account.service.rawValue.utf8.count):\(account.service.rawValue)\(account.userId.utf8.count):\(account.userId)"
        let key = "\(owner.uuidString.lowercased())|\(accountKey)|\(isMovie ? "movie" : "episode")|\(showId)|\(seasonNumber)|\(episodeNumber)|\(providerKey)|\(specialKey)|watched"
        let now = Date()
        var registration: TrackerWatchSyncDedupeRegistration?
        recentWatchSyncQueue.sync {
            registration = watchSyncDedupeGate.begin(
                key: key,
                now: now,
                completedInterval: watchSyncDedupeInterval,
                staleInFlightInterval: watchSyncDedupeInterval * 10
            )
        }

        guard let registration else {
            let logPercent = Self.watchSyncLogPercent(normalizedProgress) ?? 0
            Logger.shared.log("Skipping duplicate or in-flight watched sync for TMDB \(showId) S\(seasonNumber)E\(episodeNumber) \(logPercent)%", type: "Tracker")
            return .duplicate
        }
        return .tracked(registration)
    }

    private func finishWatchSync(
        registration: TrackerWatchSyncDedupeRegistration?,
        succeeded: Bool
    ) {
        guard let registration else { return }
        recentWatchSyncQueue.sync {
            watchSyncDedupeGate.finish(
                registration: registration,
                succeeded: succeeded,
                now: Date()
            )
        }
    }

    private func sendTrackerRequest(
        _ request: URLRequest,
        provider: TrackerRequestProvider,
        maxRetries: Int = 2,
        reportRateLimitStatus: Bool = true,
        reportAuthenticationFailure: Bool = true,
        beforeAttempt: (() async throws -> Void)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let owner = await MainActor.run { self.activeProfileID }
        let isAniListRead = provider == .anilist
            && AniListGraphQLDocumentPolicy.isReadOnly(request)
        var lastError: Error?

        for attempt in 0..<maxRetries {
            await TrackerRequestScheduler.shared.waitForSlot(provider: provider)
            try Task.checkCancellation()
            guard !accountBoundaryRecoveryBlocksNetworkOperations() else {
                throw CancellationError()
            }

            try await beforeAttempt?()

            if isAniListRead, let endpoint = request.url {
                try await AnimeProviderHealthCenter.shared.admitAniListRead(
                    endpoint: endpoint
                )
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                if isAniListRead {
                    AnimeProviderHealthCenter.shared.recordAniListFailure(error)
                }
                throw error
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                let error = NSError(domain: "TrackerNetwork", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid tracker response"])
                if isAniListRead {
                    AnimeProviderHealthCenter.shared.recordAniListFailure(error)
                }
                throw error
            }

            if isAniListRead {
                if httpResponse.statusCode != 200 || graphQLErrorMessage(from: data) != nil {
                    recordAniListTrackerReadFailure(
                        response: httpResponse,
                        data: data
                    )
                } else {
                    AnimeProviderHealthCenter.shared.recordAniListSuccess()
                }
            }

            if let retryDelay = await TrackerRequestScheduler.shared.recordResponse(provider: provider, response: httpResponse),
               attempt < maxRetries - 1,
               let displaySeconds = TrackerRateLimitHeaderPolicy.displaySeconds(for: retryDelay),
               let sleepNanoseconds = TrackerRateLimitHeaderPolicy.sleepNanoseconds(for: retryDelay) {
                Logger.shared.log("Tracker request paused for rate limit (\(provider)) for \(displaySeconds)s", type: "Tracker")
                if reportRateLimitStatus {
                    await MainActor.run {
                        self.syncToolStatus = "Paused for rate limit. Resuming in \(displaySeconds)s..."
                        self.syncToolProgressDetail = "Paused for rate limit. Resuming in \(displaySeconds)s..."
                    }
                }
                try await Task.sleep(nanoseconds: sleepNanoseconds)
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

            if reportAuthenticationFailure {
                reportAuthenticationFailureIfNeeded(
                    request: request,
                    provider: provider,
                    response: httpResponse,
                    data: data,
                    owner: owner
                )
            }

            return (data, httpResponse)
        }

        throw lastError ?? NSError(domain: "TrackerNetwork", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tracker request failed"])
    }

    private func recordAniListTrackerReadFailure(
        response: HTTPURLResponse,
        data: Data
    ) {
        let providerMessage = graphQLErrorMessage(from: data)
        let exposesOutageSignal = providerMessage?.localizedCaseInsensitiveContains("temporarily disabled") == true
            || providerMessage?.localizedCaseInsensitiveContains("severe stability issues") == true
        let description = exposesOutageSignal
            ? "AniList tracker read failed (HTTP \(response.statusCode)): \(providerMessage ?? "Provider unavailable")"
            : "AniList tracker read failed (HTTP \(response.statusCode))"
        AnimeProviderHealthCenter.shared.recordAniListFailure(
            NSError(
                domain: "AniList",
                code: response.statusCode,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        )
    }

    private func requireTrackerAccountStillConnected(
        _ expected: TrackerAccount,
        owner: UUID,
        requireSameCredential: Bool = true
    ) async throws {
        try await MainActor.run {
            guard self.activeProfileID == owner,
                  ProfileManager.shared.isStillActive(owner),
                  ProfileManager.shared.profiles.contains(where: { $0.id == owner }),
                  self.trackerProfileAcceptsOperations(owner) else {
                throw CancellationError()
            }
            guard let state = self.trackerState(forProfile: owner),
                  var current = state.accounts.first(where: {
                      $0.service == expected.service && $0.isConnected
                  }) else {
                throw CancellationError()
            }

            if current.accessToken.isEmpty {
                switch self.hydrateTrackerCredential(current, profileID: owner) {
                case .found(let hydrated, _):
                    current = hydrated
                case .absent, .temporarilyUnavailable:
                    throw CancellationError()
                }
            }

            guard current.service == expected.service,
                  current.userId == expected.userId else {
                throw CancellationError()
            }

            if requireSameCredential,
               (current.accessToken != expected.accessToken
                    || current.refreshToken != expected.refreshToken) {
                throw CancellationError()
            }
        }
    }

    private func reportAuthenticationFailureIfNeeded(
        request: URLRequest,
        provider: TrackerRequestProvider,
        response: HTTPURLResponse,
        data: Data,
        owner: UUID
    ) {
        guard request.value(forHTTPHeaderField: "Authorization")?.lowercased().hasPrefix("bearer ") == true else {
            return
        }

        let responseText = graphQLErrorMessage(from: data)?.lowercased() ?? ""
        let isAuthenticationFailure = response.statusCode == 401
            || (provider == .anilist && (
                responseText.contains("invalid token")
                    || responseText.contains("invalid_token")
                    || responseText.contains("unauthorized")
            ))
        guard isAuthenticationFailure else { return }

        switch provider {
        case .anilist:
            reportAuthenticationRequired(for: .anilist, owner: owner)
        case .myAnimeList:
            reportAuthenticationRequired(for: .myAnimeList, owner: owner)
        case .trakt:
            reportAuthenticationRequired(for: .trakt, owner: owner)
        }
    }

    private func graphQLErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]],
              let first = errors.first else {
            return nil
        }
        return first["message"] as? String
    }

    private func responseBodyPreview(from data: Data, limit: Int = 12) -> String {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "bytes=\(data.count) token=\(digest.prefix(max(8, min(limit, 32))))"
    }

    private func aniListFailureDescription(_ prefix: String, response: HTTPURLResponse, data: Data) -> String {
        return "\(prefix) (\(response.statusCode)): \(responseBodyPreview(from: data))"
    }

    private func resolvedAniListUserId(
        for account: TrackerAccount,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> Int {
        if let requiredAuthority {
            guard requiredAuthority.matches(account),
                  await operationAuthorityIsCurrent(requiredAuthority) else {
                throw CancellationError()
            }
        }
        if let userId = Int(account.userId), userId > 0 {
            return userId
        }
        let viewer = try await fetchAniListUser(token: account.accessToken)
        if let requiredAuthority,
           !(await operationAuthorityIsCurrent(requiredAuthority)) {
            throw CancellationError()
        }
        return viewer.id
    }

    private func connectedMALAccount(requiredOwner: UUID? = nil) async throws -> TrackerAccount {
        let account = try connectedAccount(.myAnimeList)
        return try await refreshedMALAccountIfNeeded(account, requiredOwner: requiredOwner)
    }

    @MainActor
    private func refreshedMALAccountIfNeeded(
        _ account: TrackerAccount,
        force: Bool = false,
        requiredOwner: UUID? = nil,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> TrackerAccount {
        guard account.service == .myAnimeList else { return account }

        let owner = activeProfileID
        if let requiredOwner, owner != requiredOwner {
            throw CancellationError()
        }
        let authority = requiredAuthority ?? operationAuthority(
            for: account,
            owner: owner
        )
        let enforcesOperationAuthority = requiredAuthority.map { _ in true } ?? false
        guard trackerProfileAcceptsOperations(owner),
              authority.owner == owner,
              authority.matches(account),
              !enforcesOperationAuthority || (
                  trackerOperationAuthorityIsCurrent(authority.operationGeneration)
                      && (authority.progressAuthority.map(
                          ProgressManager.shared.profileMutationAuthorityIsCurrent
                      ) ?? true)
              ),
              accountBoundaryGenerationIsCurrent(
                  authority.accountBoundaryGeneration,
                  for: owner
              ),
              trackerServiceGenerationIsCurrent(
                  authority.serviceGeneration,
                  service: .myAnimeList,
                  profileID: owner
              ),
              let latestAccount = trackerState.getAccount(for: .myAnimeList),
              latestAccount.userId == account.userId,
              latestAccount.accessToken == account.accessToken,
              latestAccount.refreshToken == account.refreshToken else {
            throw CancellationError()
        }

        if let existing = malTokenRefreshTasks[owner],
           let refreshToken = latestAccount.refreshToken,
           !refreshToken.isEmpty,
           existing.matches(
                account: latestAccount,
                refreshToken: refreshToken,
                accountBoundaryGeneration: authority.accountBoundaryGeneration,
                serviceGeneration: authority.serviceGeneration
           ) {
            defer {
                if malTokenRefreshTasks[owner]?.id == existing.id {
                    malTokenRefreshTasks[owner] = nil
                }
            }
            let refreshed = try await existing.task.value
            guard refreshed.service == latestAccount.service,
                  refreshed.userId == latestAccount.userId,
                  !enforcesOperationAuthority || (
                      trackerOperationAuthorityIsCurrent(authority.operationGeneration)
                          && (authority.progressAuthority.map(
                              ProgressManager.shared.profileMutationAuthorityIsCurrent
                          ) ?? true)
                  ) else {
                throw CancellationError()
            }
            try commitRefreshedAccount(
                refreshed,
                replacing: latestAccount,
                forProfile: owner,
                accountBoundaryGeneration: authority.accountBoundaryGeneration,
                serviceGeneration: authority.serviceGeneration
            )
            return refreshed
        }

        if !force {
            guard let expiresAt = latestAccount.expiresAt else { return latestAccount }
            guard expiresAt.timeIntervalSinceNow <= tokenRefreshLeeway else { return latestAccount }
        }

        guard let refreshToken = latestAccount.refreshToken, !refreshToken.isEmpty else {
            reportAuthenticationRequired(for: .myAnimeList, owner: owner)
            throw NSError(
                domain: "MALAuth",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "MAL session expired. Reconnect MyAnimeList, then import again."]
            )
        }

        if let existing = malTokenRefreshTasks[owner] {

            existing.task.cancel()
            if malTokenRefreshTasks[owner]?.id == existing.id {
                malTokenRefreshTasks[owner] = nil
            }
        }

        let attemptID = UUID()
        guard accountBoundaryGenerationIsCurrent(
                  authority.accountBoundaryGeneration,
                  for: owner
              ),
              !enforcesOperationAuthority || (
                  trackerOperationAuthorityIsCurrent(authority.operationGeneration)
                      && (authority.progressAuthority.map(
                          ProgressManager.shared.profileMutationAuthorityIsCurrent
                      ) ?? true)
              ),
              trackerServiceGenerationIsCurrent(
                  authority.serviceGeneration,
                  service: .myAnimeList,
                  profileID: owner
              ) else {
            throw CancellationError()
        }
        let refreshTask = Task { [weak self] () throws -> TrackerAccount in
            guard let self else {
                throw NSError(
                    domain: "MALAuth",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Tracker manager unavailable"]
                )
            }
            let token = try await self.refreshMALToken(refreshToken)
            var refreshedAccount = latestAccount
            refreshedAccount.updateTokens(
                access: token.accessToken,
                refresh: token.refreshToken ?? refreshToken,
                expiresAt: token.expiresIn.map {
                    Date().addingTimeInterval(TimeInterval($0))
                } ?? Date().addingTimeInterval(30 * 24 * 60 * 60)
            )
            return refreshedAccount
        }
        malTokenRefreshTasks[owner] = MALTokenRefreshAttempt(
            id: attemptID,
            accountBoundaryGeneration: authority.accountBoundaryGeneration,
            serviceGeneration: authority.serviceGeneration,
            userId: latestAccount.userId,
            accessToken: latestAccount.accessToken,
            refreshToken: refreshToken,
            task: refreshTask
        )
        defer {
            if malTokenRefreshTasks[owner]?.id == attemptID {
                malTokenRefreshTasks[owner] = nil
            }
        }

        do {
            let refreshedAccount = try await refreshTask.value
            guard refreshedAccount.service == latestAccount.service,
                  refreshedAccount.userId == latestAccount.userId,
                  !enforcesOperationAuthority || (
                      trackerOperationAuthorityIsCurrent(authority.operationGeneration)
                          && (authority.progressAuthority.map(
                              ProgressManager.shared.profileMutationAuthorityIsCurrent
                          ) ?? true)
                  ) else {
                throw CancellationError()
            }
            try commitRefreshedAccount(
                refreshedAccount,
                replacing: latestAccount,
                forProfile: owner,
                accountBoundaryGeneration: authority.accountBoundaryGeneration,
                serviceGeneration: authority.serviceGeneration
            )
            Logger.shared.log(
                force
                    ? "MAL token refreshed after invalid_token response"
                    : "MAL token refreshed before tracker library operation",
                type: "Tracker"
            )
            return refreshedAccount
        } catch {
            if Self.malRefreshFailureRequiresLogin(error) {
                reportAuthenticationRequired(for: .myAnimeList, owner: owner)
            }
            throw error
        }
    }

    @MainActor
    private func refreshedTraktAccountIfNeeded(
        _ account: TrackerAccount,
        force: Bool = false,
        requiredOwner: UUID? = nil,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> TrackerAccount {
        guard account.service == .trakt else { return account }

        if let requiredOwner, activeProfileID != requiredOwner {
            throw CancellationError()
        }
        let owner = activeProfileID
        let authority = requiredAuthority ?? operationAuthority(for: account, owner: owner)
        let enforcesOperationAuthority = requiredAuthority.map { _ in true } ?? false
        guard trackerProfileAcceptsOperations(owner),
              authority.owner == owner,
              authority.matches(account),
              !enforcesOperationAuthority || (
                  trackerOperationAuthorityIsCurrent(authority.operationGeneration)
                      && (authority.progressAuthority.map(
                          ProgressManager.shared.profileMutationAuthorityIsCurrent
                      ) ?? true)
              ),
              accountBoundaryGenerationIsCurrent(
                  authority.accountBoundaryGeneration,
                  for: owner
              ),
              trackerServiceGenerationIsCurrent(
                  authority.serviceGeneration,
                  service: .trakt,
                  profileID: owner
              ),
              let latestAccount = trackerState.getAccount(for: .trakt),
              latestAccount.userId == account.userId,
              latestAccount.accessToken == account.accessToken,
              latestAccount.refreshToken == account.refreshToken else {
            throw CancellationError()
        }

        if traktAuthenticationIsLatched(
            owner: owner,
            accountBoundaryGeneration: authority.accountBoundaryGeneration,
            account: latestAccount
        ) {
            presentLatchedTraktAuthenticationNoticeIfNeeded(owner: owner)
            throw TraktAuthenticationRequiredError()
        }

        if let existing = traktTokenRefreshTasks[owner],
           let refreshToken = latestAccount.refreshToken,
           !refreshToken.isEmpty,
           existing.matches(
                account: latestAccount,
                refreshToken: refreshToken,
                accountBoundaryGeneration: authority.accountBoundaryGeneration,
                serviceGeneration: authority.serviceGeneration
           ) {
            defer {
                if traktTokenRefreshTasks[owner]?.id == existing.id {
                    traktTokenRefreshTasks[owner] = nil
                }
            }
            do {
                let refreshed = try await existing.task.value
                guard refreshed.service == latestAccount.service,
                      refreshed.userId == latestAccount.userId,
                      !enforcesOperationAuthority || (
                          trackerOperationAuthorityIsCurrent(authority.operationGeneration)
                              && (authority.progressAuthority.map(
                                  ProgressManager.shared.profileMutationAuthorityIsCurrent
                              ) ?? true)
                      ) else {
                    throw CancellationError()
                }
                try commitRefreshedAccount(
                    refreshed,
                    replacing: latestAccount,
                    forProfile: owner,
                    accountBoundaryGeneration: authority.accountBoundaryGeneration,
                    serviceGeneration: authority.serviceGeneration
                )
                return refreshed
            } catch {
                handleTraktRefreshFailure(error, authority: authority)
                throw error
            }
        }

        if !force {
            guard let expiresAt = latestAccount.expiresAt else { return latestAccount }
            guard expiresAt.timeIntervalSinceNow <= tokenRefreshLeeway else { return latestAccount }
        }

        guard let refreshToken = latestAccount.refreshToken, !refreshToken.isEmpty else {
            installTraktAuthenticationRequiredLatch(authority: authority)
            throw TraktAuthenticationRequiredError()
        }

        if let existing = traktTokenRefreshTasks[owner] {
            existing.task.cancel()
            if traktTokenRefreshTasks[owner]?.id == existing.id {
                traktTokenRefreshTasks[owner] = nil
            }
        }

        let attemptID = UUID()
        guard accountBoundaryGenerationIsCurrent(
                  authority.accountBoundaryGeneration,
                  for: owner
              ),
              !enforcesOperationAuthority || (
                  trackerOperationAuthorityIsCurrent(authority.operationGeneration)
                      && (authority.progressAuthority.map(
                          ProgressManager.shared.profileMutationAuthorityIsCurrent
                      ) ?? true)
              ),
              trackerServiceGenerationIsCurrent(
                  authority.serviceGeneration,
                  service: .trakt,
                  profileID: owner
              ) else {
            throw CancellationError()
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
        traktTokenRefreshTasks[owner] = TraktTokenRefreshAttempt(
            id: attemptID,
            accountBoundaryGeneration: authority.accountBoundaryGeneration,
            serviceGeneration: authority.serviceGeneration,
            userId: latestAccount.userId,
            accessToken: latestAccount.accessToken,
            refreshToken: refreshToken,
            task: refreshTask
        )
        defer {
            if traktTokenRefreshTasks[owner]?.id == attemptID {
                traktTokenRefreshTasks[owner] = nil
            }
        }

        do {
            let refreshedAccount = try await refreshTask.value
            guard refreshedAccount.service == latestAccount.service,
                  refreshedAccount.userId == latestAccount.userId,
                  !enforcesOperationAuthority || (
                      trackerOperationAuthorityIsCurrent(authority.operationGeneration)
                          && (authority.progressAuthority.map(
                              ProgressManager.shared.profileMutationAuthorityIsCurrent
                          ) ?? true)
                  ) else {
                throw CancellationError()
            }
            try commitRefreshedAccount(
                refreshedAccount,
                replacing: latestAccount,
                forProfile: owner,
                accountBoundaryGeneration: authority.accountBoundaryGeneration,
                serviceGeneration: authority.serviceGeneration
            )
            Logger.shared.log("Trakt token refreshed before tracker operation", type: "Tracker")
            return refreshedAccount
        } catch {
            handleTraktRefreshFailure(error, authority: authority)
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
        authority: WebAuthenticationAuthority,
        onCode: @escaping (String) -> Void
    ) {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.authenticationAuthorityIsCurrent(authority) else { return }

                if let error {
                    self.finishAuthenticationAuthority(authority)
                    self.authError = "\(providerName) sign-in did not complete: \(error.localizedDescription)"
                    self.isAuthenticating = false
                    return
                }

                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                      !code.isEmpty else {
                    self.finishAuthenticationAuthority(authority)
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
            finishAuthenticationAuthority(authority)
            authError = "\(providerName) sign-in could not be opened on Apple TV."
            isAuthenticating = false
        }
    }
#endif

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
        let owner = activeProfileID
        guard trackerReconnectIsAllowed(.anilist, owner: owner) else { return }
        authError = nil
        isAuthenticating = true

        let authority = beginAuthenticationAuthority(for: .anilist, owner: owner)

        #if os(tvOS)
        startTVOAuthSession(
            url: url,
            providerName: "AniList",
            authority: authority
        ) { [weak self] code in
            self?.handleAniListCallback(
                code: code,
                owner: owner,
                accountBoundaryGeneration: authority.accountBoundaryGeneration,
                serviceGeneration: authority.serviceGeneration,
                authenticationID: authority.id
            )
        }
        #else
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "luna") { [weak self] callbackURL, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.finishAuthenticationAuthority(authority)
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                }
                Logger.shared.log("AniList auth error: \(error.localizedDescription)", type: "Error")
                return
            }

            guard let callbackURL = callbackURL else {
                Logger.shared.log("AniList callback URL is nil", type: "Error")
                DispatchQueue.main.async {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.finishAuthenticationAuthority(authority)
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
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.finishAuthenticationAuthority(authority)
                    self.authError = "Invalid AniList callback - failed to extract code"
                    self.isAuthenticating = false
                }
                return
            }

            Logger.shared.log("AniList code extracted successfully", type: "Tracker")
            self.handleAniListCallback(
                code: code,
                owner: owner,
                accountBoundaryGeneration: authority.accountBoundaryGeneration,
                serviceGeneration: authority.serviceGeneration,
                authenticationID: authority.id
            )
        }

        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        webAuthSession = session
        if !session.start() {
            finishAuthenticationAuthority(authority)
            authError = "AniList sign-in could not be opened."
            isAuthenticating = false
        }
        #endif
    }

    func handleAniListCallback(
        code: String,
        owner: UUID? = nil,
        accountBoundaryGeneration: UInt64? = nil,
        serviceGeneration: UInt64? = nil,
        authenticationID: UUID? = nil
    ) {
        let owner = owner ?? activeProfileID
        let authority = authenticationAuthority(
            owner: owner,
            service: .anilist,
            accountBoundaryGeneration: accountBoundaryGeneration,
            serviceGeneration: serviceGeneration,
            authenticationID: authenticationID
        )
        guard authenticationAuthorityIsCurrent(authority) else { return }
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
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    let committed = self.commitCompletedSignIn(
                        account,
                        forProfile: owner,
                        accountBoundaryGeneration: authority.accountBoundaryGeneration,
                        serviceGeneration: authority.serviceGeneration
                    )
                    if committed {
                        self.finishAuthenticationAuthority(authority)
                        Logger.shared.log("AniList account saved", type: "Tracker")
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.finishAuthenticationAuthority(authority)
                    self.authError = "AniList auth failed: \(error.localizedDescription)"
                    self.isAuthenticating = false
                    Logger.shared.log("AniList auth error: \(error.localizedDescription)", type: "Error")
                }
            }
        }
    }

    func handleAniListPinAuth(token: String) {
        let owner = activeProfileID
        guard trackerReconnectIsAllowed(.anilist, owner: owner) else { return }
        isAuthenticating = true
        let authority = beginAuthenticationAuthority(for: .anilist, owner: owner)
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
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.commitCompletedSignIn(
                        account,
                        forProfile: owner,
                        accountBoundaryGeneration: authority.accountBoundaryGeneration,
                        serviceGeneration: authority.serviceGeneration
                    )
                    self.finishAuthenticationAuthority(authority)
                }
            } catch {
                await MainActor.run {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.finishAuthenticationAuthority(authority)
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
        guard !accountBoundaryRecoveryBlocksNetworkOperations() else {
            throw CancellationError()
        }
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

        guard !accountBoundaryRecoveryBlocksNetworkOperations() else {
            throw CancellationError()
        }
        try await AnimeProviderHealthCenter.shared.admitAniListRead(endpoint: url)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            AnimeProviderHealthCenter.shared.recordAniListFailure(error)
            throw error
        }
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

        if let httpResponse {
            if statusCode != 200 || graphQLErrorMessage(from: data) != nil {
                recordAniListTrackerReadFailure(
                    response: httpResponse,
                    data: data
                )
            } else {
                AnimeProviderHealthCenter.shared.recordAniListSuccess()
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

        Logger.shared.log("MAL authorization URL prepared", type: "Tracker")
        return url
    }

    func startMALAuth() {
        guard let url = getMALAuthURL() else { return }
        let owner = activeProfileID
        guard trackerReconnectIsAllowed(.myAnimeList, owner: owner) else {
            pendingMALCodeVerifier = nil
            return
        }
        authError = nil
        isAuthenticating = true

        let authority = beginAuthenticationAuthority(for: .myAnimeList, owner: owner)

        #if os(tvOS)
        startTVOAuthSession(
            url: url,
            providerName: "MyAnimeList",
            authority: authority
        ) { [weak self] code in
            self?.handleMALCallback(
                code: code,
                owner: owner,
                accountBoundaryGeneration: authority.accountBoundaryGeneration,
                serviceGeneration: authority.serviceGeneration,
                authenticationID: authority.id
            )
        }
        #else
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "luna") { [weak self] callbackURL, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.finishAuthenticationAuthority(authority)
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
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.finishAuthenticationAuthority(authority)
                    self.authError = "Invalid MAL callback - failed to extract code"
                    self.isAuthenticating = false
                }
                return
            }

            Logger.shared.log("MAL code extracted successfully", type: "Tracker")
            self.handleMALCallback(
                code: code,
                owner: owner,
                accountBoundaryGeneration: authority.accountBoundaryGeneration,
                serviceGeneration: authority.serviceGeneration,
                authenticationID: authority.id
            )
        }

        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        webAuthSession = session
        if !session.start() {
            finishAuthenticationAuthority(authority)
            pendingMALCodeVerifier = nil
            authError = "MyAnimeList sign-in could not be opened."
            isAuthenticating = false
        }
        #endif
    }

    func handleMALCallback(
        code: String,
        owner: UUID? = nil,
        accountBoundaryGeneration: UInt64? = nil,
        serviceGeneration: UInt64? = nil,
        authenticationID: UUID? = nil
    ) {
        let owner = owner ?? activeProfileID
        let authority = authenticationAuthority(
            owner: owner,
            service: .myAnimeList,
            accountBoundaryGeneration: accountBoundaryGeneration,
            serviceGeneration: serviceGeneration,
            authenticationID: authenticationID
        )
        guard authenticationAuthorityIsCurrent(authority),
              let codeVerifier = pendingMALCodeVerifier else { return }
        isAuthenticating = true
        Task {
            do {
                let token = try await exchangeMALCode(code, codeVerifier: codeVerifier)
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
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    let committed = self.commitCompletedSignIn(
                        account,
                        forProfile: owner,
                        accountBoundaryGeneration: authority.accountBoundaryGeneration,
                        serviceGeneration: authority.serviceGeneration
                    )
                    if committed {
                        self.pendingMALCodeVerifier = nil
                        self.finishAuthenticationAuthority(authority)
                        Logger.shared.log("MAL account saved", type: "Tracker")
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.pendingMALCodeVerifier = nil
                    self.finishAuthenticationAuthority(authority)
                    self.authError = "MAL auth failed: \(error.localizedDescription)"
                    self.isAuthenticating = false
                    Logger.shared.log("MAL auth error: \(error.localizedDescription)", type: "Error")
                }
            }
        }
    }

    func handleMALPinAuth(token: String) {
        let owner = activeProfileID
        guard trackerReconnectIsAllowed(.myAnimeList, owner: owner) else { return }
        isAuthenticating = true
        let authority = beginAuthenticationAuthority(for: .myAnimeList, owner: owner)
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
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.commitCompletedSignIn(
                        account,
                        forProfile: owner,
                        accountBoundaryGeneration: authority.accountBoundaryGeneration,
                        serviceGeneration: authority.serviceGeneration
                    )
                    self.finishAuthenticationAuthority(authority)
                }
            } catch {
                await MainActor.run {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.finishAuthenticationAuthority(authority)
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                }
            }
        }
    }

    private func exchangeMALCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> MALAuthResponse {
        let url = URL(string: "https://myanimelist.net/v1/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "client_id": malClientId,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": malRedirectUri
        ]
        if let secret = malClientSecret {
            body["client_secret"] = secret
        }
        request.httpBody = formURLEncodedBody(body)

        let (data, response) = try await sendTrackerRequest(request, provider: .myAnimeList)
        guard response.statusCode == 200 else {
            let diagnostic = responseBodyPreview(from: data)
            throw NSError(domain: "MALAuth", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "MAL token request failed: \(diagnostic)"])
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
            let diagnostic = responseBodyPreview(from: data)
            throw NSError(domain: "MALAuth", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "MAL token refresh failed: \(diagnostic)"])
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

        let owner = activeProfileID
        guard trackerReconnectIsAllowed(.trakt, owner: owner) else { return }
        traktDeviceAuthTask?.cancel()
        authError = nil
        isAuthenticating = true
        traktDeviceUserCode = nil
        traktDeviceVerificationURL = nil

        let authority = beginAuthenticationAuthority(for: .trakt, owner: owner)
        traktDeviceAuthTask = Task { [weak self] in
            guard let self else { return }
            do {
                let device = try await self.requestTraktDeviceCode()
                try await MainActor.run {
                    guard self.authenticationAuthorityIsCurrent(authority) else {
                        throw CancellationError()
                    }
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
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    let committed = self.commitCompletedSignIn(
                        account,
                        forProfile: owner,
                        accountBoundaryGeneration: authority.accountBoundaryGeneration,
                        serviceGeneration: authority.serviceGeneration
                    )
                    if committed {
                        self.traktDeviceUserCode = nil
                        self.traktDeviceVerificationURL = nil
                        self.finishAuthenticationAuthority(authority)
                        self.traktDeviceAuthTask = nil
                        Logger.shared.log("Trakt device authorization completed", type: "Tracker")
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.finishAuthenticationAuthority(authority)
                    self.isAuthenticating = false
                    self.traktDeviceAuthTask = nil
                }
            } catch {
                await MainActor.run {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.authError = "Trakt device authorization failed: \(error.localizedDescription)"
                    self.isAuthenticating = false
                    self.finishAuthenticationAuthority(authority)
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
        guard !accountBoundaryRecoveryBlocksNetworkOperations() else {
            throw CancellationError()
        }
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

            guard !accountBoundaryRecoveryBlocksNetworkOperations() else {
                throw CancellationError()
            }
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
        let owner = activeProfileID
        guard trackerReconnectIsAllowed(.trakt, owner: owner) else {
            pendingTraktOAuthState = nil
            return
        }
        authError = nil
        isAuthenticating = true

        let authority = beginAuthenticationAuthority(for: .trakt, owner: owner)

        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "luna") { [weak self] callbackURL, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.pendingTraktOAuthState = nil
                    self.finishAuthenticationAuthority(authority)
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                }
                Logger.shared.log("Trakt auth error: \(error.localizedDescription)", type: "Error")
                return
            }

            guard let callbackURL = callbackURL else {
                Logger.shared.log("Trakt callback URL is nil", type: "Error")
                DispatchQueue.main.async {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.pendingTraktOAuthState = nil
                    self.finishAuthenticationAuthority(authority)
                    self.authError = "Trakt callback URL is nil"
                    self.isAuthenticating = false
                }
                return
            }

            Logger.shared.log("Trakt authorization callback received", type: "Tracker")

            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                Logger.shared.log("Failed to extract code from Trakt callback", type: "Error")
                DispatchQueue.main.async {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.pendingTraktOAuthState = nil
                    self.finishAuthenticationAuthority(authority)
                    self.authError = "Invalid Trakt callback - failed to extract code"
                    self.isAuthenticating = false
                }
                return
            }

            let callbackState = components.queryItems?.first(where: { $0.name == "state" })?.value
            if callbackState != oauthState {
                Logger.shared.log("Rejected Trakt callback with invalid OAuth state.", type: "Error")
                DispatchQueue.main.async {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.pendingTraktOAuthState = nil
                    self.finishAuthenticationAuthority(authority)
                    self.authError = "Invalid Trakt callback state. Please try connecting again."
                    self.isAuthenticating = false
                }
                return
            }

            Logger.shared.log("Trakt code extracted successfully", type: "Tracker")
            self.handleTraktCallback(
                code: code,
                owner: owner,
                accountBoundaryGeneration: authority.accountBoundaryGeneration,
                serviceGeneration: authority.serviceGeneration,
                authenticationID: authority.id
            )
        }

        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        webAuthSession = session
        if !session.start() {
            pendingTraktOAuthState = nil
            finishAuthenticationAuthority(authority)
            authError = "Trakt sign-in could not be opened."
            isAuthenticating = false
        }
#endif
    }

    func handleTraktCallback(
        code: String,
        owner: UUID? = nil,
        accountBoundaryGeneration: UInt64? = nil,
        serviceGeneration: UInt64? = nil,
        authenticationID: UUID? = nil
    ) {
        let owner = owner ?? activeProfileID
        let authority = authenticationAuthority(
            owner: owner,
            service: .trakt,
            accountBoundaryGeneration: accountBoundaryGeneration,
            serviceGeneration: serviceGeneration,
            authenticationID: authenticationID
        )
        guard authenticationAuthorityIsCurrent(authority) else { return }
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
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    let committed = self.commitCompletedSignIn(
                        account,
                        forProfile: owner,
                        accountBoundaryGeneration: authority.accountBoundaryGeneration,
                        serviceGeneration: authority.serviceGeneration
                    )
                    if committed {
                        self.pendingTraktOAuthState = nil
                        self.finishAuthenticationAuthority(authority)
                        Logger.shared.log("Trakt account saved", type: "Tracker")
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.pendingTraktOAuthState = nil
                    self.finishAuthenticationAuthority(authority)
                    self.authError = "Trakt auth failed: \(error.localizedDescription)"
                    self.isAuthenticating = false
                    Logger.shared.log("Trakt auth error: \(error.localizedDescription)", type: "Error")
                }
            }
        }
    }

    func handleTraktPinAuth(token: String) {
        let owner = activeProfileID
        guard trackerReconnectIsAllowed(.trakt, owner: owner) else { return }
        isAuthenticating = true
        let authority = beginAuthenticationAuthority(for: .trakt, owner: owner)
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
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.commitCompletedSignIn(
                        account,
                        forProfile: owner,
                        accountBoundaryGeneration: authority.accountBoundaryGeneration,
                        serviceGeneration: authority.serviceGeneration
                    )
                    self.finishAuthenticationAuthority(authority)
                }
            } catch {
                await MainActor.run {
                    guard self.authenticationAuthorityIsCurrent(authority) else { return }
                    self.finishAuthenticationAuthority(authority)
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

        guard !accountBoundaryRecoveryBlocksNetworkOperations() else {
            throw CancellationError()
        }
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

        guard !accountBoundaryRecoveryBlocksNetworkOperations() else {
            throw CancellationError()
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            throw TraktOAuthRefreshFailure(
                statusCode: statusCode,
                responseData: data
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

        guard !accountBoundaryRecoveryBlocksNetworkOperations() else {
            throw CancellationError()
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? -1

        Logger.shared.log("Trakt user response status: \(statusCode)", type: "Tracker")
        Logger.shared.log("Trakt user response data length: \(data.count) bytes", type: "Tracker")

        guard (200...299).contains(statusCode) else {
            let diagnostic = responseBodyPreview(from: data)
            throw NSError(
                domain: "TraktAuth",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Trakt user request failed with status \(statusCode): \(diagnostic)"]
            )
        }

        do {
            return try JSONDecoder().decode(TraktUserSettingsResponse.self, from: data).user
        } catch {
            Logger.shared.log("Failed to decode Trakt user response: \(error.localizedDescription)", type: "Error")
            throw error
        }
    }

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

        guard trackerState.readerSyncEnabled else {
            ReaderLogger.shared.log("Skipping manga sync (Reader sync disabled) for \(title) ch \(chapterNumber)", type: "Tracker")
            return
        }

        let owner = ProfileManager.shared.activeProfileID
        let accounts = trackerState.accounts.filter {
            $0.isConnected
                && !$0.accessToken.isEmpty
                && ($0.service == .anilist || $0.service == .myAnimeList)
        }
        guard !accounts.isEmpty else {
            ReaderLogger.shared.log("Skipping manga sync (no connected manga tracker account) for \(title) ch \(chapterNumber)", type: "Tracker")
            return
        }
        let profileAuthority = profileOperationAuthority(for: owner)
        let accountAuthorities = accounts.reduce(into: [TrackerService: TrackerOperationAuthority]()) {
            $0[$1.service] = operationAuthority(
                for: $1,
                owner: owner,
                operationGeneration: profileAuthority.operationGeneration
            )
        }

        ReaderLogger.shared.log("Starting manga sync for \(title) ch \(chapterNumber) across \(accounts.count) account(s)", type: "Tracker")

        Task {
            guard profileOperationAuthorityIsCurrent(profileAuthority) else { return }
            guard let match = await resolveMangaTrackerMatch(
                title: title,
                totalChapters: totalChapters,
                format: format,
                routeKey: routeKey,
                knownAniListId: knownAniListId,
                knownMALId: knownMALId,
                requiredProfileAuthority: profileAuthority,
                requiredMALAuthority: accountAuthorities[.myAnimeList]
            ) else {
                ReaderLogger.shared.log("Skipping manga sync for \(title): no confident tracker match", type: "Tracker")
                return
            }

            for account in accounts {
                guard profileOperationAuthorityIsCurrent(profileAuthority),
                      let authority = accountAuthorities[account.service] else { return }
                switch account.service {
                case .anilist:
                    if let aniListId = match.aniListId {
                        await sendMangaProgressToAniList(
                            mediaId: aniListId,
                            chapterNumber: chapterNumber,
                            account: account,
                            owner: owner,
                            requiredAuthority: authority
                        )
                    } else {
                        ReaderLogger.shared.log("Skipping AniList manga sync for \(title): resolved match has no AniList ID", type: "Tracker")
                    }
                case .myAnimeList:
                    if let malId = match.malId {
                        await sendMangaProgressToMAL(
                            malId: malId,
                            chapterNumber: chapterNumber,
                            account: account,
                            owner: owner,
                            requiredAuthority: authority
                        )
                    } else if let aniListId = match.aniListId {
                        await sendMangaProgressToMAL(
                            aniListId: aniListId,
                            chapterNumber: chapterNumber,
                            account: account,
                            owner: owner,
                            requiredProfileAuthority: profileAuthority,
                            requiredAuthority: authority
                        )
                    } else {
                        ReaderLogger.shared.log("Skipping MAL manga sync for \(title): resolved match has no MAL ID", type: "Tracker")
                    }
                case .trakt:
                    break
                }
            }
        }
    }

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

        guard trackerState.readerSyncEnabled else {
            ReaderLogger.shared.log("Skipping manga sync (Reader sync disabled) for aniListId \(aniListId) ch \(chapterNumber)", type: "Tracker")
            return
        }

        let owner = ProfileManager.shared.activeProfileID
        let accounts = trackerState.accounts.filter {
            $0.isConnected
                && !$0.accessToken.isEmpty
                && ($0.service == .anilist || $0.service == .myAnimeList)
        }
        guard !accounts.isEmpty else {
            ReaderLogger.shared.log("Skipping manga sync (no connected manga tracker account) for aniListId \(aniListId) ch \(chapterNumber)", type: "Tracker")
            return
        }
        let profileAuthority = profileOperationAuthority(for: owner)
        let accountAuthorities = accounts.reduce(into: [TrackerService: TrackerOperationAuthority]()) {
            $0[$1.service] = operationAuthority(
                for: $1,
                owner: owner,
                operationGeneration: profileAuthority.operationGeneration
            )
        }

        ReaderLogger.shared.log("Starting manga sync for aniListId \(aniListId) ch \(chapterNumber) across \(accounts.count) account(s)", type: "Tracker")
        Task {
            for account in accounts {
                guard profileOperationAuthorityIsCurrent(profileAuthority),
                      let authority = accountAuthorities[account.service] else { return }
                switch account.service {
                case .anilist:
                    await sendMangaProgressToAniList(
                        mediaId: aniListId,
                        chapterNumber: chapterNumber,
                        account: account,
                        owner: owner,
                        requiredAuthority: authority
                    )
                case .myAnimeList:
                    if let malId {
                        await sendMangaProgressToMAL(
                            malId: malId,
                            chapterNumber: chapterNumber,
                            account: account,
                            owner: owner,
                            requiredAuthority: authority
                        )
                    } else {
                        await sendMangaProgressToMAL(
                            aniListId: aniListId,
                            chapterNumber: chapterNumber,
                            account: account,
                            owner: owner,
                            requiredProfileAuthority: profileAuthority,
                            requiredAuthority: authority
                        )
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

        let owner = ProfileManager.shared.activeProfileID
        let accounts = trackerState.accounts.filter {
            $0.isConnected
                && !$0.accessToken.isEmpty
                && ($0.service == .anilist || $0.service == .myAnimeList)
        }
        guard !accounts.isEmpty else {
            Logger.shared.log("Skipping rating sync (no connected AniList/MAL account) for TMDB \(tmdbId)", type: "Tracker")
            return
        }
        let profileAuthority = profileOperationAuthority(for: owner)
        let accountAuthorities = accounts.reduce(into: [TrackerService: TrackerOperationAuthority]()) {
            $0[$1.service] = operationAuthority(
                for: $1,
                owner: owner,
                operationGeneration: profileAuthority.operationGeneration
            )
        }
        Task {
            var resolvedAniListId = cachedAniListId(for: tmdbId)
            if resolvedAniListId == nil {
                resolvedAniListId = await getAniListMediaId(
                    tmdbId: tmdbId,
                    requiredProfileAuthority: profileAuthority
                )
            }
            guard profileOperationAuthorityIsCurrent(profileAuthority),
                  let aniListId = resolvedAniListId else {
                Logger.shared.log("Could not find AniList ID for rating sync, TMDB \(tmdbId)", type: "Tracker")
                return
            }

            for account in accounts {
                guard profileOperationAuthorityIsCurrent(profileAuthority),
                      let authority = accountAuthorities[account.service] else { return }
                switch account.service {
                case .anilist:
                    await saveAniListRatingAndNote(
                        account: account,
                        anilistId: aniListId,
                        rating: clampedRating,
                        note: nil,
                        owner: owner,
                        requiredAuthority: authority
                    )
                case .myAnimeList:
                    guard let malId = await getMyAnimeListId(
                        fromAniListId: aniListId,
                        mediaType: "ANIME",
                        requiredProfileAuthority: profileAuthority
                    ), profileOperationAuthorityIsCurrent(profileAuthority) else {
                        Logger.shared.log("Could not find MAL anime ID for rating sync, AniList \(aniListId)", type: "Tracker")
                        continue
                    }
                    await saveMALAnimeRatingAndNote(
                        account: account,
                        malId: malId,
                        rating: clampedRating,
                        note: nil,
                        owner: owner,
                        requiredAuthority: authority
                    )
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

        let owner = ProfileManager.shared.activeProfileID
        guard let account = trackerState.getAccount(for: service), account.isConnected else {
            Logger.shared.log("Skipping rating note sync (no connected \(service.displayName) account) for TMDB \(tmdbId)", type: "Tracker")
            return
        }
        let profileAuthority = profileOperationAuthority(for: owner)
        let authority = operationAuthority(
            for: account,
            owner: owner,
            operationGeneration: profileAuthority.operationGeneration
        )
        Task {
            var resolvedAniListId = cachedAniListId(for: tmdbId)
            if resolvedAniListId == nil {
                resolvedAniListId = await getAniListMediaId(
                    tmdbId: tmdbId,
                    requiredProfileAuthority: profileAuthority
                )
            }
            guard profileOperationAuthorityIsCurrent(profileAuthority),
                  let aniListId = resolvedAniListId else {
                Logger.shared.log("Could not find AniList ID for rating note sync, TMDB \(tmdbId)", type: "Tracker")
                return
            }

            switch service {
            case .anilist:
                await saveAniListRatingAndNote(
                    account: account,
                    anilistId: aniListId,
                    rating: clampedRating,
                    note: note,
                    owner: owner,
                    requiredAuthority: authority
                )
            case .myAnimeList:
                guard let malId = await getMyAnimeListId(
                    fromAniListId: aniListId,
                    mediaType: "ANIME",
                    requiredProfileAuthority: profileAuthority
                ), profileOperationAuthorityIsCurrent(profileAuthority) else {
                    Logger.shared.log("Could not find MAL anime ID for rating note sync, AniList \(aniListId)", type: "Tracker")
                    return
                }
                await saveMALAnimeRatingAndNote(
                    account: account,
                    malId: malId,
                    rating: clampedRating,
                    note: note,
                    owner: owner,
                    requiredAuthority: authority
                )
            case .trakt:
                break
            }
        }
    }

#if !os(tvOS)

    private func updateReaderTrackerMatchIfStillOwned(
        owner: UUID,
        requiredProfileAuthority: TrackerProfileOperationAuthority,
        mangaId: Int,
        aniListId: Int?,
        malId: Int?,
        confidence: Double
    ) async {
        await MainActor.run {
            guard profileOperationAuthorityIsCurrent(requiredProfileAuthority),
                  requiredProfileAuthority.owner == owner else {
                ReaderLogger.shared.log(
                    "Skipped a resolved reader tracker match because the active profile changed",
                    type: "Tracker"
                )
                return
            }
            MangaReadingProgressManager.shared.updateTrackerMatch(
                mangaId: mangaId,
                aniListId: aniListId,
                malId: malId,
                confidence: confidence
            )
        }
    }

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

        guard trackerState.readerSyncEnabled else {
            ReaderLogger.shared.log("Skipping reader rating sync (Reader sync disabled) for \(title)", type: "Tracker")
            return
        }

        let allowedServices: Set<TrackerService> = service.map { [$0] } ?? [.anilist, .myAnimeList]
        let owner = ProfileManager.shared.activeProfileID
        let accounts = trackerState.accounts.filter {
            $0.isConnected
                && !$0.accessToken.isEmpty
                && allowedServices.contains($0.service)
                && ($0.service == .anilist || $0.service == .myAnimeList)
        }
        guard !accounts.isEmpty else {
            ReaderLogger.shared.log("Skipping reader rating sync (no connected AniList/MAL account) for \(title)", type: "Tracker")
            return
        }
        let profileAuthority = profileOperationAuthority(for: owner)
        let accountAuthorities = accounts.reduce(into: [TrackerService: TrackerOperationAuthority]()) {
            $0[$1.service] = operationAuthority(
                for: $1,
                owner: owner,
                operationGeneration: profileAuthority.operationGeneration
            )
        }
        Task {
            guard profileOperationAuthorityIsCurrent(profileAuthority) else { return }
            guard let match = await resolveMangaTrackerMatch(
                title: title,
                totalChapters: totalChapters,
                format: format,
                routeKey: routeKey,
                knownAniListId: knownAniListId,
                knownMALId: knownMALId,
                requiredProfileAuthority: profileAuthority,
                requiredMALAuthority: accountAuthorities[.myAnimeList]
            ) else {
                ReaderLogger.shared.log("Skipping reader rating sync for \(title): no confident tracker match", type: "Tracker")
                return
            }

            await updateReaderTrackerMatchIfStillOwned(
                owner: owner,
                requiredProfileAuthority: profileAuthority,
                mangaId: localMangaId,
                aniListId: match.aniListId,
                malId: match.malId,
                confidence: match.confidence
            )

            var resolvedAniListId = match.aniListId
            var resolvedMALId = match.malId

            for account in accounts {
                guard profileOperationAuthorityIsCurrent(profileAuthority),
                      let authority = accountAuthorities[account.service] else { return }
                switch account.service {
                case .anilist:
                    if resolvedAniListId == nil, let malId = resolvedMALId {
                        resolvedAniListId = await getAniListId(
                            fromMALId: malId,
                            mediaType: "MANGA",
                            requiredProfileAuthority: profileAuthority
                        )
                    }
                    guard profileOperationAuthorityIsCurrent(profileAuthority),
                          let aniListId = resolvedAniListId else {
                        ReaderLogger.shared.log("Skipping AniList reader rating sync for \(title): no AniList manga ID", type: "Tracker")
                        continue
                    }
                    await updateReaderTrackerMatchIfStillOwned(
                        owner: owner,
                        requiredProfileAuthority: profileAuthority,
                        mangaId: localMangaId,
                        aniListId: aniListId,
                        malId: resolvedMALId,
                        confidence: match.confidence
                    )
                    await saveAniListMangaRatingAndNote(
                        account: account,
                        anilistId: aniListId,
                        rating: clampedRating,
                        note: note,
                        owner: owner,
                        requiredAuthority: authority
                    )

                case .myAnimeList:
                    if resolvedMALId == nil, let aniListId = resolvedAniListId {
                        resolvedMALId = await getMyAnimeListId(
                            fromAniListId: aniListId,
                            mediaType: "MANGA",
                            requiredProfileAuthority: profileAuthority
                        )
                    }
                    guard profileOperationAuthorityIsCurrent(profileAuthority),
                          let malId = resolvedMALId else {
                        ReaderLogger.shared.log("Skipping MAL reader rating sync for \(title): no MAL manga ID", type: "Tracker")
                        continue
                    }
                    await updateReaderTrackerMatchIfStillOwned(
                        owner: owner,
                        requiredProfileAuthority: profileAuthority,
                        mangaId: localMangaId,
                        aniListId: resolvedAniListId,
                        malId: malId,
                        confidence: match.confidence
                    )
                    await saveMALMangaRatingAndNote(
                        account: account,
                        malId: malId,
                        rating: clampedRating,
                        note: note,
                        owner: owner,
                        requiredAuthority: authority
                    )

                case .trakt:
                    break
                }
            }
        }
    }
#endif

#if !os(tvOS)
    private func saveAniListMangaRatingAndNote(
        account: TrackerAccount,
        anilistId: Int,
        rating: Double,
        note: String?,
        owner: UUID,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async {
        let clampedRating = Self.normalizedRatingOutOf10(rating)
        let displayRating = Self.ratingDisplayString(clampedRating)
        do {
            let firstResult = try await sendAniListRatingAndNoteRequest(
                account: account,
                anilistId: anilistId,
                rating: clampedRating,
                note: note,
                includeCurrentStatus: false,
                owner: owner,
                requiredAuthority: requiredAuthority
            )

            if firstResult.succeeded {
                ReaderLogger.shared.log("Synced AniList manga rating \(displayRating)/10\(note == nil ? "" : " and notes") for mediaId \(anilistId)", type: "Tracker")
                return
            }

            if firstResult.statusCode == 400 {
                ReaderLogger.shared.log("AniList manga rating sync returned 400; retrying with CURRENT status for mediaId \(anilistId): \(firstResult.diagnostic)", type: "Tracker")
                let retryResult = try await sendAniListRatingAndNoteRequest(
                    account: account,
                    anilistId: anilistId,
                    rating: clampedRating,
                    note: note,
                    includeCurrentStatus: true,
                    owner: owner,
                    requiredAuthority: requiredAuthority
                )

                if retryResult.succeeded {
                    ReaderLogger.shared.log("Synced AniList manga rating \(displayRating)/10\(note == nil ? "" : " and notes") for mediaId \(anilistId) after creating a list entry", type: "Tracker")
                } else if retryResult.graphQLError != nil {
                    ReaderLogger.shared.log("AniList manga rating sync error after retry: \(retryResult.diagnostic)", type: "Tracker")
                } else {
                    ReaderLogger.shared.log("AniList manga rating sync returned status \(retryResult.statusCode) after retry: \(retryResult.diagnostic)", type: "Tracker")
                }
                return
            }

            if firstResult.graphQLError != nil {
                ReaderLogger.shared.log("AniList manga rating sync error: \(firstResult.diagnostic)", type: "Tracker")
            } else {
                ReaderLogger.shared.log("AniList manga rating sync returned status \(firstResult.statusCode): \(firstResult.diagnostic)", type: "Tracker")
            }
        } catch {
            ReaderLogger.shared.log("Failed to sync AniList manga rating \(anilistId): \(error.localizedDescription)", type: "Error")
        }
    }
#endif

    private func saveAniListRatingAndNote(
        account: TrackerAccount,
        anilistId: Int,
        rating: Double,
        note: String?,
        owner: UUID,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async {
        let clampedRating = Self.normalizedRatingOutOf10(rating)
        let displayRating = Self.ratingDisplayString(clampedRating)
        do {
            let firstResult = try await sendAniListRatingAndNoteRequest(
                account: account,
                anilistId: anilistId,
                rating: clampedRating,
                note: note,
                includeCurrentStatus: false,
                owner: owner,
                requiredAuthority: requiredAuthority
            )

            if firstResult.succeeded {
                Logger.shared.log("Synced AniList rating \(displayRating)/10\(note == nil ? "" : " and notes") for mediaId \(anilistId)", type: "Tracker")
                return
            }

            if firstResult.statusCode == 400 {
                Logger.shared.log("AniList rating sync returned 400; retrying with CURRENT status for mediaId \(anilistId): \(firstResult.diagnostic)", type: "Tracker")
                let retryResult = try await sendAniListRatingAndNoteRequest(
                    account: account,
                    anilistId: anilistId,
                    rating: clampedRating,
                    note: note,
                    includeCurrentStatus: true,
                    owner: owner,
                    requiredAuthority: requiredAuthority
                )

                if retryResult.succeeded {
                    Logger.shared.log("Synced AniList rating \(displayRating)/10\(note == nil ? "" : " and notes") for mediaId \(anilistId) after creating a list entry", type: "Tracker")
                } else if retryResult.graphQLError != nil {
                    Logger.shared.log("AniList rating sync error after retry: \(retryResult.diagnostic)", type: "Tracker")
                } else {
                    Logger.shared.log("AniList rating sync returned status \(retryResult.statusCode) after retry: \(retryResult.diagnostic)", type: "Tracker")
                }
                return
            }

            if firstResult.graphQLError != nil {
                Logger.shared.log("AniList rating sync error: \(firstResult.diagnostic)", type: "Tracker")
            } else {
                Logger.shared.log("AniList rating sync returned status \(firstResult.statusCode): \(firstResult.diagnostic)", type: "Tracker")
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
        includeCurrentStatus: Bool,
        owner: UUID,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> AniListRatingSyncResponse {
        let authority = requiredAuthority ?? operationAuthority(for: account, owner: owner)
        guard authority.owner == owner, authority.matches(account) else {
            throw CancellationError()
        }
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

        let (data, response) = try await sendTrackerRequest(
            request,
            provider: .anilist,
            beforeAttempt: { [weak self] in
                guard let self,
                      await self.operationAuthorityIsCurrent(authority) else {
                    throw CancellationError()
                }
            }
        )
        let diagnostic = responseBodyPreview(from: data)
        let graphQLError = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { json -> String? in
                guard let errors = json["errors"] as? [[String: Any]], !errors.isEmpty else {
                    return nil
                }
                return errors.first?["message"] as? String ?? "Unknown error"
            }

        return AniListRatingSyncResponse(
            statusCode: response.statusCode,
            diagnostic: diagnostic,
            graphQLError: graphQLError
        )
    }

    private func sendMALListStatusRequest(
        account: TrackerAccount,
        mediaPath: String,
        mediaId: Int,
        values: [String: String],
        allowsRefreshRetry: Bool = true,
        owner: UUID,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let authority = requiredAuthority ?? operationAuthority(for: account, owner: owner)
        guard authority.owner == owner, authority.matches(account) else {
            throw CancellationError()
        }
        let resolvedAccount = try await refreshedMALAccountIfNeeded(
            account,
            requiredOwner: owner,
            requiredAuthority: authority
        )
        guard resolvedAccount.userId == account.userId else {
            Logger.shared.log(
                "Skipped MAL \(mediaPath) write for id \(mediaId); the connected account changed while it was queued",
                type: "Tracker"
            )
            throw CancellationError()
        }
        let account = resolvedAccount
        let requestAuthority = authority.replacingCredential(with: account)
        let url = URL(string: "https://api.myanimelist.net/v2/\(mediaPath)/\(mediaId)/my_list_status")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncodedBody(values)

        let (data, response) = try await sendTrackerRequest(
            request,
            provider: .myAnimeList,
            reportAuthenticationFailure: !allowsRefreshRetry,
            beforeAttempt: { [weak self] in
                guard let self else { throw CancellationError() }
                guard await self.operationAuthorityIsCurrent(requestAuthority) else {
                    throw CancellationError()
                }
            }
        )
        if response.statusCode == 401, allowsRefreshRetry {
            let diagnostic = responseBodyPreview(from: data)
            Logger.shared.log("MAL \(mediaPath) list status returned 401; refreshing token and retrying once: \(diagnostic)", type: "Tracker")
            let refreshed = try await refreshedMALAccountIfNeeded(
                account,
                force: true,
                requiredOwner: owner,
                requiredAuthority: requestAuthority
            )
            return try await sendMALListStatusRequest(
                account: refreshed,
                mediaPath: mediaPath,
                mediaId: mediaId,
                values: values,
                allowsRefreshRetry: false,
                owner: owner,
                requiredAuthority: requestAuthority.replacingCredential(with: refreshed)
            )
        }

        return (data, response)
    }

    private func saveMALAnimeRatingAndNote(
        account: TrackerAccount,
        malId: Int,
        rating: Double,
        note: String?,
        owner: UUID,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async {
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
                values: values,
                owner: owner,
                requiredAuthority: requiredAuthority
            )
            if (200...299).contains(response.statusCode) {
                let malSuffix = malRating == Int(clampedRating) && clampedRating.truncatingRemainder(dividingBy: 1) == 0
                    ? ""
                    : " as \(malRating)/10"
                Logger.shared.log("Synced MAL rating \(displayRating)/10\(malSuffix)\(note == nil ? "" : " and comments") for animeId \(malId)", type: "Tracker")
            } else {
                let diagnostic = responseBodyPreview(from: data)
                Logger.shared.log("MAL rating sync returned status \(response.statusCode): \(diagnostic)", type: "Tracker")
            }
        } catch {
            Logger.shared.log("Failed to sync MAL rating \(malId): \(error.localizedDescription)", type: "Error")
        }
    }

#if !os(tvOS)
    private func sendMangaProgressToAniList(
        mediaId: Int,
        chapterNumber: Int,
        account: TrackerAccount,
        owner: UUID,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async {
        let authority = requiredAuthority ?? operationAuthority(for: account, owner: owner)
        guard authority.owner == owner, authority.matches(account) else { return }
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

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .anilist,
                beforeAttempt: { [weak self] in
                    guard let self,
                          await self.operationAuthorityIsCurrent(authority) else {
                        throw CancellationError()
                    }
                }
            )
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

    private func sendMangaProgressToMAL(
        aniListId: Int,
        chapterNumber: Int,
        account: TrackerAccount,
        owner: UUID,
        requiredProfileAuthority: TrackerProfileOperationAuthority? = nil,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async {
        guard let malId = await getMyAnimeListId(
            fromAniListId: aniListId,
            mediaType: "MANGA",
            requiredProfileAuthority: requiredProfileAuthority
        ), requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else {
            ReaderLogger.shared.log("Could not find MAL manga ID for AniList manga \(aniListId)", type: "Tracker")
            return
        }

        await sendMangaProgressToMAL(
            malId: malId,
            chapterNumber: chapterNumber,
            account: account,
            owner: owner,
            requiredAuthority: requiredAuthority
        )
    }

    private func sendMangaProgressToMAL(
        malId: Int,
        chapterNumber: Int,
        account: TrackerAccount,
        owner: UUID,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async {
        await saveMALMangaProgress(
            account: account,
            malId: malId,
            chaptersRead: chapterNumber,
            status: "reading",
            owner: owner,
            requiredAuthority: requiredAuthority
        )
    }
#endif

    func syncWatchProgress(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        progress: Double,
        isMovie: Bool = false,
        isAnime: Bool = false,
        playbackContext: EpisodePlaybackContext? = nil,
        requiredOwner: UUID? = nil,
        progressAuthority: ProgressManager.ProfileMutationAuthority? = nil
    ) {
        guard let owner = resolvedPlaybackOperationOwner(
            requiredOwner: requiredOwner,
            progressAuthority: progressAuthority
        ) else {
            Logger.shared.log(
                "Skipping watch sync because its originating profile is no longer active",
                type: "Tracker"
            )
            return
        }
        guard let progressPercentForLog = Self.watchSyncLogPercent(progress) else {
            Logger.shared.log(
                "Skipping watch sync with non-finite progress for TMDB \(showId) S\(seasonNumber)E\(episodeNumber)",
                type: "Tracker"
            )
            return
        }
        guard !isBackupRestoreSyncSuppressed() else {
            Logger.shared.log("Skipping watch sync (backup restore in progress) for TMDB \(showId) S\(seasonNumber)E\(episodeNumber) \(progressPercentForLog)%", type: "Tracker")
            return
        }

        guard trackerState.syncEnabled else {
            Logger.shared.log("Skipping watch sync (sync disabled) for TMDB \(showId) S\(seasonNumber)E\(episodeNumber) \(progressPercentForLog)%", type: "Tracker")
            return
        }

        let connectedAccounts = trackerState.accounts.filter { $0.isConnected && !$0.accessToken.isEmpty }
        guard !connectedAccounts.isEmpty else {
            Logger.shared.log("Skipping watch sync (no connected tracker accounts) for TMDB \(showId) S\(seasonNumber)E\(episodeNumber) \(progressPercentForLog)%", type: "Tracker")
            return
        }

        let playbackAniListMediaId = playbackContext?.positiveAniListMediaId
        let playbackMALMediaId = playbackContext?.exactMALMediaId
        let canSyncAnimeTrackers = isAnime || playbackAniListMediaId != nil || playbackMALMediaId != nil
        let eligibleAccounts = connectedAccounts.filter { account in
            guard account.service == .trakt || canSyncAnimeTrackers else {
                Logger.shared.log(
                    "Skipping \(account.service.displayName) watch sync for non-anime TMDB \(showId) S\(seasonNumber)E\(episodeNumber)",
                    type: "Tracker"
                )
                return false
            }
            return true
        }
        guard !eligibleAccounts.isEmpty else { return }

        let syncAttempts: [(account: TrackerAccount, authority: TrackerOperationAuthority, registration: TrackerWatchSyncDedupeRegistration?)] = eligibleAccounts.compactMap { account in
            let authority = operationAuthority(
                for: account,
                owner: owner,
                progressAuthority: progressAuthority
            )
            switch beginWatchSync(
                showId: showId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                progress: progress,
                isMovie: isMovie,
                playbackContext: playbackContext,
                owner: owner,
                account: account
            ) {
            case .untracked:
                return (account, authority, nil)
            case .tracked(let registration):
                return (account, authority, registration)
            case .duplicate:
                return nil
            }
        }
        guard !syncAttempts.isEmpty else { return }

        Logger.shared.log("Starting watch sync for TMDB \(showId) S\(seasonNumber)E\(episodeNumber) \(progressPercentForLog)% across \(syncAttempts.count) account(s)", type: "Tracker")

        Task {
            for attempt in syncAttempts {
                let account = attempt.account
                var succeeded = false
                Logger.shared.log("Syncing \(account.service) account \(account.username) for TMDB \(showId) S\(seasonNumber)E\(episodeNumber)", type: "Tracker")
                switch account.service {
                case .anilist:
                    if let playbackContext,
                       let anilistMediaId = playbackAniListMediaId {
                        succeeded = await syncToAniListMediaId(
                            account: account,
                            anilistId: anilistMediaId,
                            showId: showId,
                            seasonNumber: playbackContext.localSeasonNumber,
                            episodeNumber: playbackContext.localEpisodeNumber,
                            progress: progress,
                            owner: owner,
                            authority: attempt.authority
                        )
                    } else if let playbackContext,
                              let malMediaId = playbackMALMediaId {
                        var exactAniListID = cachedAniListSeasonId(
                            tmdbId: showId,
                            seasonNumber: playbackContext.localSeasonNumber
                        )
                        if exactAniListID == nil {
                            exactAniListID = await getAniListId(
                                fromMALId: malMediaId,
                                mediaType: "ANIME"
                            )
                        }
                        if let exactAniListID {
                            succeeded = await syncToAniListMediaId(
                                account: account,
                                anilistId: exactAniListID,
                                showId: showId,
                                seasonNumber: playbackContext.localSeasonNumber,
                                episodeNumber: playbackContext.localEpisodeNumber,
                                progress: progress,
                                owner: owner,
                                authority: attempt.authority
                            )
                        } else {
                            Logger.shared.log("Could not resolve exact AniList identity for MAL fallback mediaId=\(malMediaId)", type: "Tracker")
                            succeeded = false
                        }
                    } else {
                        succeeded = await syncToAniList(account: account, showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber, progress: progress, owner: owner, authority: attempt.authority)
                    }
                case .myAnimeList:
                    if let playbackContext,
                       let malMediaId = playbackMALMediaId {
                        succeeded = await syncToMyAnimeList(
                            account: account,
                            malId: malMediaId,
                            episodeNumber: playbackContext.localEpisodeNumber,
                            progress: progress,
                            owner: owner,
                            authority: attempt.authority
                        )
                    } else if let playbackContext,
                              let anilistMediaId = playbackAniListMediaId {
                        succeeded = await syncToMyAnimeList(
                            account: account,
                            anilistId: anilistMediaId,
                            episodeNumber: playbackContext.localEpisodeNumber,
                            progress: progress,
                            owner: owner,
                            authority: attempt.authority
                        )
                    } else {
                        succeeded = await syncToMyAnimeList(account: account, showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber, progress: progress, owner: owner, authority: attempt.authority)
                    }
                case .trakt:
                    let resolvedTrakt = resolvedTraktEpisodeNumbers(
                        seasonNumber: seasonNumber,
                        episodeNumber: episodeNumber,
                        playbackContext: playbackContext
                    )
                    if resolvedTrakt != nil || canUseTraktAnimeFallback(playbackContext) {
                        succeeded = await syncToTrakt(
                            account: account,
                            showId: showId,
                            resolved: resolvedTrakt,
                            progress: progress,
                            playbackContext: playbackContext,
                            owner: owner,
                            authority: attempt.authority
                        )
                    }
                }

                finishWatchSync(
                    registration: attempt.registration,
                    succeeded: succeeded
                )
            }
        }
    }

    @discardableResult
    private func syncToAniList(
        account: TrackerAccount,
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        progress: Double,
        owner: UUID,
        authority: TrackerOperationAuthority? = nil
    ) async -> Bool {
        let authority = authority ?? operationAuthority(for: account, owner: owner)

        var anilistId: Int? = cachedAniListSeasonId(tmdbId: showId, seasonNumber: seasonNumber)

        if anilistId == nil {
            anilistId = await getAniListMediaId(tmdbId: showId)
        }

        guard let anilistId = anilistId else {
            Logger.shared.log("Could not find AniList ID for TMDB ID \(showId) S\(seasonNumber)", type: "Tracker")
            return false
        }

        return await syncToAniListMediaId(
            account: account,
            anilistId: anilistId,
            showId: showId,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            progress: progress,
            owner: owner,
            authority: authority
        )
    }

    @discardableResult
    private func syncToAniListMediaId(
        account: TrackerAccount,
        anilistId: Int,
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        progress: Double,
        owner: UUID,
        authority: TrackerOperationAuthority
    ) async -> Bool {

        let totalEpisodes = await getAniListEpisodeCount(mediaId: anilistId)
        let isFinalEpisode = (totalEpisodes ?? 0) > 0 && episodeNumber >= (totalEpisodes ?? 0)
        let normalStatus = isFinalEpisode ? "COMPLETED" : "CURRENT"
        let status: String?
#if os(iOS)
        switch await fetchAniListAnimeListStatus(
            account: account,
            mediaId: anilistId,
            owner: owner,
            authority: authority
        ) {
        case .loaded(let currentStatus):
            status = currentStatus?.uppercased() == "REPEATING" ? "REPEATING" : normalStatus
        case .unavailable:

            status = nil
        }
#else
        status = normalStatus
#endif
        let statusClause = status.map { ",\n                status: \($0)" } ?? ""

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

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .anilist,
                beforeAttempt: { [weak self] in
                    guard let self else { throw CancellationError() }
                    guard await self.operationAuthorityIsCurrent(authority) else {
                        throw CancellationError()
                    }
                }
            )
            if response.statusCode == 200 {

                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                    let errorMsg = (errors.first?["message"] as? String) ?? "Unknown error"
                    Logger.shared.log("AniList sync error: \(errorMsg)", type: "Tracker")
                    return false
                } else {
                    Logger.shared.log("Synced to AniList: mediaId=\(anilistId) S\(seasonNumber)E\(episodeNumber) (\(status ?? "status preserved"))", type: "Tracker")
                    return true
                }
            } else {
                Logger.shared.log("AniList sync returned status \(response.statusCode)", type: "Tracker")
                return false
            }
        } catch {
            Logger.shared.log("Failed to sync to AniList: \(error.localizedDescription)", type: "Error")
            return false
        }
    }

#if os(iOS)
    private enum AniListAnimeListStatusLookup {
        case loaded(String?)
        case unavailable
    }

    private func fetchAniListAnimeListStatus(
        account: TrackerAccount,
        mediaId: Int,
        owner: UUID,
        authority: TrackerOperationAuthority
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

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .anilist,
                beforeAttempt: { [weak self] in
                    guard let self else { throw CancellationError() }
                    guard await self.operationAuthorityIsCurrent(authority) else {
                        throw CancellationError()
                    }
                }
            )
            guard response.statusCode == 200 else {
                Logger.shared.log("AniList status lookup returned \(response.statusCode) for mediaId=\(mediaId); preserving server status", type: "Tracker")
                return .unavailable
            }
            if graphQLErrorMessage(from: data) != nil {
                Logger.shared.log(
                    "AniList status lookup failed for mediaId=\(mediaId): \(responseBodyPreview(from: data))",
                    type: "Tracker"
                )
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

    @discardableResult
    private func syncToMyAnimeList(account: TrackerAccount, showId: Int, seasonNumber: Int, episodeNumber: Int, progress: Double, owner: UUID, authority: TrackerOperationAuthority? = nil) async -> Bool {
        let authority = authority ?? operationAuthority(for: account, owner: owner)
        var anilistId: Int? = cachedAniListSeasonId(tmdbId: showId, seasonNumber: seasonNumber)

        if anilistId == nil {
            anilistId = await getAniListMediaId(tmdbId: showId)
        }

        guard let anilistId = anilistId else {
            Logger.shared.log("Could not find AniList ID for MAL sync, TMDB \(showId) S\(seasonNumber)", type: "Tracker")
            return false
        }

        return await syncToMyAnimeList(account: account, anilistId: anilistId, episodeNumber: episodeNumber, progress: progress, owner: owner, authority: authority)
    }

    @discardableResult
    private func syncToMyAnimeList(account: TrackerAccount, anilistId: Int, episodeNumber: Int, progress: Double, owner: UUID, authority: TrackerOperationAuthority? = nil) async -> Bool {
        let authority = authority ?? operationAuthority(for: account, owner: owner)
        let malProgress = progress <= 1.0 ? progress * 100.0 : progress
        guard malProgress >= 85 else {
            Logger.shared.log("Skipping MAL anime sync below watched threshold for AniList \(anilistId) E\(episodeNumber)", type: "Tracker")
            return false
        }

        guard let malId = await getMyAnimeListId(fromAniListId: anilistId, mediaType: "ANIME") else {
            Logger.shared.log("Could not find MAL anime ID for AniList \(anilistId)", type: "Tracker")
            return false
        }

        let totalEpisodes = await getAniListEpisodeCount(mediaId: anilistId)
        let status = ((totalEpisodes ?? 0) > 0 && episodeNumber >= (totalEpisodes ?? 0)) ? "completed" : "watching"
        return await saveMALAnimeProgress(
            account: account,
            malId: malId,
            watchedEpisodes: episodeNumber,
            status: status,
            preserveRewatching: true,
            owner: owner,
            authority: authority
        )
    }

    @discardableResult
    private func syncToMyAnimeList(account: TrackerAccount, malId: Int, episodeNumber: Int, progress: Double, owner: UUID, authority: TrackerOperationAuthority? = nil) async -> Bool {
        let authority = authority ?? operationAuthority(for: account, owner: owner)
        let malProgress = progress <= 1.0 ? progress * 100.0 : progress
        guard malProgress >= 85 else {
            Logger.shared.log("Skipping MAL anime sync below watched threshold for MAL \(malId) E\(episodeNumber)", type: "Tracker")
            return false
        }

#if os(iOS)

        let status = "watching"
#else
        let status = malProgress >= 95 ? "completed" : "watching"
#endif
        return await saveMALAnimeProgress(
            account: account,
            malId: malId,
            watchedEpisodes: episodeNumber,
            status: status,
            preserveRewatching: true,
            owner: owner,
            authority: authority
        )
    }

    @discardableResult
    private func saveMALAnimeProgress(
        account: TrackerAccount,
        malId: Int,
        watchedEpisodes: Int,
        status: String,
        preserveRewatching: Bool = false,
        owner: UUID,
        authority: TrackerOperationAuthority? = nil
    ) async -> Bool {
        let authority = authority ?? operationAuthority(for: account, owner: owner)
        var values = [
            "status": status,
            "num_watched_episodes": String(max(watchedEpisodes, 0))
        ]

#if os(iOS)
        if preserveRewatching {
            switch await fetchMALAnimePlaybackState(
                account: account,
                malId: malId,
                owner: owner,
                authority: authority
            ) {
            case .loaded(let state):
                if state.isRewatching {

                    values.removeValue(forKey: "status")
                    values["is_rewatching"] = "true"
                } else if let totalEpisodes = state.totalEpisodes, totalEpisodes > 0 {
                    values["status"] = watchedEpisodes >= totalEpisodes ? "completed" : "watching"
                }
            case .unavailable:

                values.removeValue(forKey: "status")
            }
        }
#endif

        do {
            let (data, response) = try await sendMALListStatusRequest(
                account: account,
                mediaPath: "anime",
                mediaId: malId,
                values: values,
                owner: owner,
                requiredAuthority: authority
            )
            if (200...299).contains(response.statusCode) {
                Logger.shared.log("Synced to MAL: animeId=\(malId) episodes=\(watchedEpisodes) status=\(values["status"] ?? "preserved")", type: "Tracker")
                return true
            } else {
                let diagnostic = responseBodyPreview(from: data)
                Logger.shared.log("MAL anime sync returned status \(response.statusCode): \(diagnostic)", type: "Tracker")
                return false
            }
        } catch {
            Logger.shared.log("Failed to sync to MAL: \(error.localizedDescription)", type: "Error")
            return false
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
        owner: UUID,
        authority: TrackerOperationAuthority
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
            let url = URL(string: "https://api.myanimelist.net/v2/anime/\(malId)?fields=my_list_status,num_episodes")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .myAnimeList,
                reportAuthenticationFailure: false,
                beforeAttempt: { [weak self] in
                    guard let self else { throw CancellationError() }
                    guard await self.operationAuthorityIsCurrent(authority) else {
                        throw CancellationError()
                    }
                }
            )
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
    private func saveMALMangaProgress(
        account: TrackerAccount,
        malId: Int,
        chaptersRead: Int,
        status: String,
        owner: UUID,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async {
        let values = [
            "status": status,
            "num_chapters_read": String(max(chaptersRead, 0))
        ]

        do {
            let (data, response) = try await sendMALListStatusRequest(
                account: account,
                mediaPath: "manga",
                mediaId: malId,
                values: values,
                owner: owner,
                requiredAuthority: requiredAuthority
            )
            if (200...299).contains(response.statusCode) {
                ReaderLogger.shared.log("Synced manga to MAL: mangaId=\(malId) chapters=\(chaptersRead) status=\(status)", type: "Tracker")
            } else {
                let diagnostic = responseBodyPreview(from: data)
                ReaderLogger.shared.log("MAL manga sync returned status \(response.statusCode): \(diagnostic)", type: "Tracker")
            }
        } catch {
            ReaderLogger.shared.log("Failed to sync manga to MAL: \(error.localizedDescription)", type: "Error")
        }
    }

    private func saveMALMangaRatingAndNote(
        account: TrackerAccount,
        malId: Int,
        rating: Double,
        note: String?,
        owner: UUID,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async {
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
                values: values,
                owner: owner,
                requiredAuthority: requiredAuthority
            )
            if (200...299).contains(response.statusCode) {
                let malSuffix = malRating == Int(clampedRating) && clampedRating.truncatingRemainder(dividingBy: 1) == 0
                    ? ""
                    : " as \(malRating)/10"
                ReaderLogger.shared.log("Synced MAL manga rating \(displayRating)/10\(malSuffix)\(note == nil ? "" : " and comments") for mangaId \(malId)", type: "Tracker")
            } else {
                let diagnostic = responseBodyPreview(from: data)
                ReaderLogger.shared.log("MAL manga rating sync returned status \(response.statusCode): \(diagnostic)", type: "Tracker")
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
        force: Bool = false,
        requiredOwner: UUID? = nil,
        progressAuthority: ProgressManager.ProfileMutationAuthority? = nil
    ) {
        guard let owner = resolvedPlaybackOperationOwner(
            requiredOwner: requiredOwner,
            progressAuthority: progressAuthority
        ) else {
            Logger.shared.log(
                "Skipping Trakt episode progress because its originating profile is no longer active",
                type: "Tracker"
            )
            return
        }
        guard !isBackupRestoreSyncSuppressed(), trackerState.syncEnabled else { return }
        guard progress.isFinite, progress > 0 else { return }
        guard let account = trackerState.getAccount(for: .trakt) else { return }
        guard !traktOperationIsBlockedByAuthentication(owner: owner, account: account) else { return }

        if trackerState.liveTraktScrobbling {
            guard force else { return }
            scrobbleTraktPlayback(
                .stop,
                for: .episode(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber),
                progress: progress,
                playbackContext: playbackContext,
                force: force,
                requiredOwner: owner,
                progressAuthority: progressAuthority
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
        let key = "\(owner.uuidString.lowercased())|episode|\(showId)|\(keySeason)|\(keyEpisode)"
        guard shouldStartTraktPlaybackSync(key: key, force: force) else { return }
        let authority = operationAuthority(
            for: account,
            owner: owner,
            progressAuthority: progressAuthority
        )
        Task {
            await syncToTrakt(
                account: account,
                showId: showId,
                resolved: resolved,
                progress: progress,
                playbackContext: playbackContext,
                owner: owner,
                authority: authority
            )
        }
    }

    func syncTraktMoviePlaybackProgress(
        movieId: Int,
        progress: Double,
        force: Bool = false,
        requiredOwner: UUID? = nil,
        progressAuthority: ProgressManager.ProfileMutationAuthority? = nil
    ) {
        guard let owner = resolvedPlaybackOperationOwner(
            requiredOwner: requiredOwner,
            progressAuthority: progressAuthority
        ) else {
            Logger.shared.log(
                "Skipping Trakt movie progress because its originating profile is no longer active",
                type: "Tracker"
            )
            return
        }
        guard !isBackupRestoreSyncSuppressed(), trackerState.syncEnabled else { return }
        guard progress.isFinite, progress > 0 else { return }
        guard let account = trackerState.getAccount(for: .trakt) else { return }
        guard !traktOperationIsBlockedByAuthentication(owner: owner, account: account) else { return }

        if trackerState.liveTraktScrobbling {
            guard force else { return }
            scrobbleTraktPlayback(
                .stop,
                for: .movie(id: movieId, title: ""),
                progress: progress,
                force: force,
                requiredOwner: owner,
                progressAuthority: progressAuthority
            )
            return
        }

        let key = "\(owner.uuidString.lowercased())|movie|\(movieId)"
        guard shouldStartTraktPlaybackSync(key: key, force: force) else { return }
        let authority = operationAuthority(
            for: account,
            owner: owner,
            progressAuthority: progressAuthority
        )
        Task {
            await syncMovieToTrakt(account: account, movieId: movieId, progress: progress, owner: owner, authority: authority)
        }
    }

    func scrobbleTraktPlayback(
        _ action: TraktScrobbleAction,
        for mediaInfo: MediaInfo,
        progress: Double,
        playbackContext: EpisodePlaybackContext? = nil,
        force: Bool = false,
        requiredOwner: UUID? = nil,
        progressAuthority: ProgressManager.ProfileMutationAuthority? = nil
    ) {
        guard let owner = resolvedPlaybackOperationOwner(
            requiredOwner: requiredOwner,
            progressAuthority: progressAuthority
        ) else {
            Logger.shared.log(
                "Skipping Trakt scrobble because its originating profile is no longer active",
                type: "Tracker"
            )
            return
        }
        guard !isBackupRestoreSyncSuppressed(),
              trackerState.syncEnabled,
              trackerState.liveTraktScrobbling else { return }
        guard progress.isFinite else { return }
        let normalizedProgress = normalizedTraktScrobbleProgress(progress)
        if action != .start {
            guard normalizedProgress > 0 else { return }
        }
        guard let account = trackerState.getAccount(for: .trakt) else { return }
        guard !traktOperationIsBlockedByAuthentication(owner: owner, account: account) else { return }
        guard let mediaKey = traktScrobbleKey(for: mediaInfo, playbackContext: playbackContext) else { return }
        let key = "\(owner.uuidString.lowercased())|\(mediaKey)"
        guard let pendingID = shouldQueueTraktScrobble(
            action: action,
            key: key,
            progress: normalizedProgress,
            force: force
        ) else { return }
        let authority = operationAuthority(
            for: account,
            owner: owner,
            progressAuthority: progressAuthority
        )

        Task {
            let outcome = await sendTraktScrobble(
                action: action,
                account: account,
                mediaInfo: mediaInfo,
                progress: normalizedProgress,
                playbackContext: playbackContext,
                owner: owner,
                authority: authority
            )
            finishTraktScrobble(
                action: action,
                key: key,
                progress: normalizedProgress,
                pendingID: pendingID,
                outcome: outcome
            )
        }
    }

    @MainActor
    func fetchTraktContinueWatchingItems(
        requiredOwner: UUID
    ) async -> [ContinueWatchingItem] {
        let owner = activeProfileID
        guard requiredOwner == owner,
              ProfileManager.shared.isStillActive(owner),
              let account = trackerState.getAccount(for: .trakt) else {
            return []
        }
        let authority = operationAuthority(for: account, owner: owner)

        if let cached = cachedTraktContinueWatchingItems(for: account, owner: owner) {
            guard await operationAuthorityIsCurrent(authority) else { return [] }
            return cached
        }
        guard !traktOperationIsBlockedByAuthentication(owner: owner, account: account) else {
            return []
        }

        do {
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(
                account,
                requiredOwner: owner,
                requiredAuthority: authority
            )
            let requestAuthority = authority.replacingCredential(with: refreshedAccount)
            guard await operationAuthorityIsCurrent(requestAuthority) else {
                throw CancellationError()
            }
            guard !traktClientId.isEmpty else {
                Logger.shared.log("Skipping Trakt Continue Watching fetch because TRAKT_CLIENT_ID is not configured.", type: "Tracker")
                return []
            }

            async let upNextData = fetchTraktPlaybackData(
                path: "sync/progress/up_next",
                account: refreshedAccount,
                owner: owner,
                requiredAuthority: requestAuthority
            )
            async let episodeData = fetchTraktPlaybackData(
                path: "sync/playback/episodes",
                account: refreshedAccount,
                owner: owner,
                requiredAuthority: requestAuthority
            )
            async let movieData = fetchTraktPlaybackData(
                path: "sync/playback/movies",
                account: refreshedAccount,
                owner: owner,
                requiredAuthority: requestAuthority
            )
            let (upNextPlaybackData, episodePlaybackData, moviePlaybackData) = try await (upNextData, episodeData, movieData)
            guard await operationAuthorityIsCurrent(requestAuthority) else {
                throw CancellationError()
            }

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

            guard await operationAuthorityIsCurrent(requestAuthority) else {
                throw CancellationError()
            }
            storeTraktContinueWatchingItems(items, for: refreshedAccount, owner: owner)
            return items
        } catch let error where Self.isTraktAuthenticationRequiredError(error) {
            return []
        } catch is CancellationError {
            return []
        } catch {
            Logger.shared.log("Failed to fetch Trakt Continue Watching: \(error.localizedDescription)", type: "Error")
            return []
        }
    }

    private func cachedTraktContinueWatchingItems(
        for account: TrackerAccount,
        owner: UUID
    ) -> [ContinueWatchingItem]? {
        let now = Date()
        return traktContinueWatchingCacheQueue.sync {
            guard let cache = traktContinueWatchingCache,
                  cache.owner == owner,
                  cache.accountUserId == account.userId,
                  now.timeIntervalSince(cache.fetchedAt) < traktContinueWatchingCacheTTL else {
                return nil
            }
            return cache.items
        }
    }

    private func storeTraktContinueWatchingItems(
        _ items: [ContinueWatchingItem],
        for account: TrackerAccount,
        owner: UUID
    ) {
        traktContinueWatchingCacheQueue.sync {
            traktContinueWatchingCache = (owner, account.userId, Date(), items)
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

            let filtered = await TMDBContentFilter.shared.filterSearchResultsResolvingRatings(resolved)
            storeTraktRelated(filtered, key: cacheKey)
            return filtered
        } catch {
            Logger.shared.log("Failed to load Trakt related for \(cacheKey): \(error.localizedDescription)", type: "Error")
            return []
        }
    }

    private func fetchTraktPlaybackData(
        path: String,
        account: TrackerAccount,
        allowsRefreshRetry: Bool = true,
        owner: UUID? = nil,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> Data {
        let owner = owner ?? activeProfileID
        let authority = requiredAuthority ?? operationAuthority(for: account, owner: owner)
        guard authority.owner == owner, authority.matches(account) else {
            throw CancellationError()
        }
        let url = URL(string: "https://api.trakt.tv/\(path)")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")

        let (data, response) = try await sendTrackerRequest(
            request,
            provider: .trakt,
            reportRateLimitStatus: false,
            reportAuthenticationFailure: !allowsRefreshRetry,
            beforeAttempt: { [weak self] in
                guard let self,
                      await self.operationAuthorityIsCurrent(authority) else {
                    throw CancellationError()
                }
            }
        )
        let statusCode = response.statusCode
        if statusCode == 401, allowsRefreshRetry {
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(
                account,
                force: true,
                requiredOwner: owner,
                requiredAuthority: authority
            )
            return try await fetchTraktPlaybackData(
                path: path,
                account: refreshedAccount,
                allowsRefreshRetry: false,
                owner: owner,
                requiredAuthority: authority.replacingCredential(with: refreshedAccount)
            )
        }
        guard statusCode == 200 else {
            let diagnostic = responseBodyPreview(from: data)
            throw NSError(domain: "Trakt", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Trakt \(path) returned status \(statusCode): \(diagnostic)"])
        }
        return data
    }

    private func fetchAllTraktPages(
        path: String,
        account: TrackerAccount,
        limit: Int = 100,
        owner: UUID? = nil,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> [Data] {
        let owner = owner ?? activeProfileID
        let authority = requiredAuthority ?? operationAuthority(for: account, owner: owner)
        guard authority.owner == owner, authority.matches(account) else {
            throw CancellationError()
        }
        var pages: [Data] = []
        var page = 1

        while true {
            let separator = path.contains("?") ? "&" : "?"
            let data = try await fetchTraktPlaybackData(
                path: "\(path)\(separator)page=\(page)&limit=\(limit)",
                account: account,
                owner: owner,
                requiredAuthority: authority
            )
            pages.append(data)

            let count = (try JSONSerialization.jsonObject(with: data) as? [Any])?.count ?? 0
            guard count >= limit else { return pages }
            page += 1
        }
    }

    private func fetchTraktData(
        path: String,
        account: TrackerAccount? = nil,
        allowsRefreshRetry: Bool = true,
        owner requiredOwner: UUID? = nil,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> Data {
        guard !traktClientId.isEmpty else {
            throw NSError(domain: "Trakt", code: -1, userInfo: [NSLocalizedDescriptionKey: "TRAKT_CLIENT_ID is not configured."])
        }

        let refreshedAccount: TrackerAccount?
        let requestAuthority: TrackerOperationAuthority?
        let owner: UUID?
        if let account {
            let resolvedOwner = requiredOwner ?? activeProfileID
            let authority = requiredAuthority ?? operationAuthority(
                for: account,
                owner: resolvedOwner
            )
            let refreshed = try await refreshedTraktAccountIfNeeded(
                account,
                requiredOwner: resolvedOwner,
                requiredAuthority: authority
            )
            refreshedAccount = refreshed
            requestAuthority = authority.replacingCredential(with: refreshed)
            owner = resolvedOwner
        } else {
            refreshedAccount = nil
            requestAuthority = nil
            owner = nil
        }

        let url = URL(string: "https://api.trakt.tv/\(path)")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        if let refreshedAccount {
            request.setValue("Bearer \(refreshedAccount.accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await sendTrackerRequest(
            request,
            provider: .trakt,
            reportRateLimitStatus: false,
            reportAuthenticationFailure: !allowsRefreshRetry,
            beforeAttempt: { [weak self] in
                guard let requestAuthority else { return }
                guard let self,
                      await self.operationAuthorityIsCurrent(requestAuthority) else {
                    throw CancellationError()
                }
            }
        )
        if response.statusCode == 401, let account = refreshedAccount, allowsRefreshRetry {
            guard let owner, let requestAuthority else { throw CancellationError() }
            let forcedRefresh = try await refreshedTraktAccountIfNeeded(
                account,
                force: true,
                requiredOwner: owner,
                requiredAuthority: requestAuthority
            )
            return try await fetchTraktData(
                path: path,
                account: forcedRefresh,
                allowsRefreshRetry: false,
                owner: owner,
                requiredAuthority: requestAuthority.replacingCredential(with: forcedRefresh)
            )
        }
        guard (200...299).contains(response.statusCode) else {
            let diagnostic = responseBodyPreview(from: data)
            throw NSError(domain: "Trakt", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Trakt \(path) returned status \(response.statusCode): \(diagnostic)"])
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
        let owner = ProfileManager.shared.activeProfileID
        guard let account = trackerState.getAccount(for: .trakt) else { return }
        let authority = operationAuthority(for: account, owner: owner)

        Task {
            do {
                let refreshedAccount = try await refreshedTraktAccountIfNeeded(
                    account,
                    requiredOwner: owner,
                    requiredAuthority: authority
                )
                guard refreshedAccount.userId == account.userId else {
                    Logger.shared.log("Skipped Trakt playback removal \(playbackId); the connected account changed while it was queued", type: "Tracker")
                    return
                }
                guard !traktClientId.isEmpty else { return }
                try await deleteTraktPlaybackItem(
                    playbackId,
                    account: refreshedAccount,
                    owner: owner,
                    authority: authority.replacingCredential(with: refreshedAccount)
                )
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
        let owner = ProfileManager.shared.activeProfileID
        guard let account = trackerState.getAccount(for: .trakt) else { return }
        let authority = operationAuthority(for: account, owner: owner)

        Task {
            do {
                let refreshedAccount = try await refreshedTraktAccountIfNeeded(
                    account,
                    requiredOwner: owner,
                    requiredAuthority: authority
                )
                guard refreshedAccount.userId == account.userId else {
                    Logger.shared.log("Skipped Trakt Up Next hide tmdb=\(tmdbId); the connected account changed while it was queued", type: "Tracker")
                    return
                }
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
                _ = try await postTraktJSON(
                    path: "users/hidden/progress_watched",
                    account: refreshedAccount,
                    payload: payload,
                    owner: owner,
                    requiredAuthority: authority.replacingCredential(with: refreshedAccount)
                )
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

    private func deleteTraktPlaybackItem(
        _ playbackId: Int,
        account: TrackerAccount,
        allowsRefreshRetry: Bool = true,
        owner: UUID,
        authority: TrackerOperationAuthority
    ) async throws {
        let url = URL(string: "https://api.trakt.tv/sync/playback/\(playbackId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(traktClientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")

        let (data, response) = try await sendTrackerRequest(
            request,
            provider: .trakt,
            reportRateLimitStatus: false,
            reportAuthenticationFailure: !allowsRefreshRetry,
            beforeAttempt: { [weak self] in
                guard let self else { throw CancellationError() }
                guard await self.operationAuthorityIsCurrent(authority) else {
                    throw CancellationError()
                }
            }
        )
        let statusCode = response.statusCode
        if statusCode == 401, allowsRefreshRetry {
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(
                account,
                force: true,
                requiredOwner: owner,
                requiredAuthority: authority
            )
            guard refreshedAccount.userId == account.userId else {
                Logger.shared.log(
                    "Skipped Trakt playback remove retry for \(playbackId); the connected account changed while the request was in flight",
                    type: "Tracker"
                )
                throw CancellationError()
            }
            return try await deleteTraktPlaybackItem(
                playbackId,
                account: refreshedAccount,
                allowsRefreshRetry: false,
                owner: owner,
                authority: authority.replacingCredential(with: refreshedAccount)
            )
        }
        guard (200...299).contains(statusCode) else {
            let diagnostic = responseBodyPreview(from: data)
            throw NSError(domain: "Trakt", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Trakt playback remove returned status \(statusCode): \(diagnostic)"])
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
    ) -> UUID? {
        let now = Date()
        return traktScrobbleQueue.sync { () -> UUID? in
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
                    return nil
                }

                if action == .start, traktScrobbleLastActionByKey[key] == .start {
                    guard let stamp = traktScrobbleLastStampByKey[key] else {
                        return nil
                    }
                    if now.timeIntervalSince(stamp.sentAt) < traktScrobbleStartRefreshMinimumInterval {
                        return nil
                    }
                }

                if let pending = traktScrobblePendingByKey[key] {
                    if action == .start, pending.action == .start {
                        return nil
                    }
                    if pending.action == action,
                       now.timeIntervalSince(pending.queuedAt) < traktScrobbleMinimumInterval,
                       abs(pending.progress - progress) <= traktScrobbleProgressWindow {
                        return nil
                    }
                }

                if let stamp = traktScrobbleLastStampByKey[key],
                   stamp.action == action,
                   now.timeIntervalSince(stamp.sentAt) < traktScrobbleMinimumInterval,
                   abs(stamp.progress - progress) <= traktScrobbleProgressWindow {
                    return nil
                }

                if action != .start,
                   let lastAction = traktScrobbleLastActionByKey[key],
                   lastAction == action,
                   let stamp = traktScrobbleLastStampByKey[key],
                   abs(stamp.progress - progress) <= traktScrobbleProgressWindow {
                    return nil
                }
            }

            let pendingID = UUID()
            traktScrobblePendingByKey[key] = (pendingID, action, progress, now)
            return pendingID
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

    private func abandonPendingTraktScrobbles(for owner: UUID) {
        let ownerPrefix = owner.uuidString.lowercased() + "|"
        traktScrobbleQueue.sync {
            traktScrobblePendingByKey = traktScrobblePendingByKey.filter {
                !$0.key.hasPrefix(ownerPrefix)
            }
        }
    }

    private enum TraktScrobbleSendOutcome {
        case sent
        case failed
        case cancelled
    }

    static func traktScrobbleCompletionRecordsFailure(
        sent: Bool,
        cancelled: Bool
    ) -> Bool {
        !sent && !cancelled
    }

    static func traktScrobblePendingCompletionIsCurrent(
        expectedID: UUID,
        currentID: UUID?
    ) -> Bool {
        expectedID == currentID
    }

    private func finishTraktScrobble(
        action: TraktScrobbleAction,
        key: String,
        progress: Double,
        pendingID: UUID,
        outcome: TraktScrobbleSendOutcome
    ) {
        let now = Date()
        traktScrobbleQueue.sync {
            guard let pending = traktScrobblePendingByKey[key],
                  Self.traktScrobblePendingCompletionIsCurrent(
                    expectedID: pendingID,
                    currentID: pending.id
                  ),
                  pending.action == action,
                  abs(pending.progress - progress) <= 0.1 else { return }

            traktScrobblePendingByKey.removeValue(forKey: key)
            switch outcome {
            case .sent:
                traktScrobbleLastActionByKey[key] = action
                traktScrobbleLastStampByKey[key] = (action, progress, now)
                traktScrobbleFailureStampByKey.removeValue(forKey: key)
            case .failed:
                traktScrobbleFailureStampByKey[key] = (action, progress, now)
            case .cancelled:
                break
            }
        }
    }

    private func sendTraktScrobble(
        action: TraktScrobbleAction,
        account: TrackerAccount,
        mediaInfo: MediaInfo,
        progress: Double,
        playbackContext: EpisodePlaybackContext?,
        owner: UUID,
        authority: TrackerOperationAuthority
    ) async -> TraktScrobbleSendOutcome {
        do {
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(
                account,
                requiredOwner: owner,
                requiredAuthority: authority
            )
            guard refreshedAccount.userId == account.userId else {
                Logger.shared.log("Skipped Trakt scrobble \(action.rawValue); the connected account changed while it was queued", type: "Tracker")
                return .cancelled
            }
            let requestAuthority = authority.replacingCredential(with: refreshedAccount)
            let payload: [String: Any]

            switch mediaInfo {
            case .movie(let movieId, let title, _, _):
                guard let traktId = await getTraktIdFromTmdbId(movieId, mediaType: .movie) else {
                    guard await operationAuthorityIsCurrent(requestAuthority) else {
                        return .cancelled
                    }
                    Logger.shared.log("Skipping Trakt scrobble \(action.rawValue); no Trakt movie ID for TMDB \(movieId)", type: "Tracker")
                    return .failed
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

                guard resolved != nil || canUseTraktAnimeFallback(playbackContext) else { return .failed }
                guard let traktId = await getTraktIdFromTmdbId(showId, mediaType: .show) else {
                    guard await operationAuthorityIsCurrent(requestAuthority) else {
                        return .cancelled
                    }
                    Logger.shared.log("Skipping Trakt scrobble \(action.rawValue); no Trakt show ID for TMDB \(showId)", type: "Tracker")
                    return .failed
                }
                guard let traktEpisodeId = await resolveTraktEpisodeIdForSync(
                    showTraktId: traktId,
                    resolved: resolved,
                    playbackContext: playbackContext,
                    account: refreshedAccount,
                    owner: owner,
                    authority: requestAuthority
                ) else {
                    guard await operationAuthorityIsCurrent(requestAuthority) else {
                        return .cancelled
                    }
                    return .failed
                }
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
                maxRetries: action == .stop ? 3 : 2,
                owner: owner,
                requiredAuthority: requestAuthority
            )

            if action != .start {
                invalidateTraktContinueWatchingCache()
            }
            let logPercent = Self.watchSyncLogPercent(progress) ?? 0
            Logger.shared.log("Trakt scrobble \(action.rawValue) sent at \(logPercent)%", type: "Tracker")
            return .sent
        } catch let error where Self.isTraktAuthenticationRequiredError(error) {
            return .cancelled
        } catch is CancellationError {
            Logger.shared.log(
                "Cancelled stale Trakt scrobble \(action.rawValue) without installing a failure cooldown",
                type: "Tracker"
            )
            return .cancelled
        } catch {
            Logger.shared.log("Failed Trakt scrobble \(action.rawValue): \(error.localizedDescription)", type: "Error")
            return .failed
        }
    }

    @discardableResult
    private func syncToTrakt(account: TrackerAccount, showId: Int, resolved: (season: Int, episode: Int)?, progress: Double, playbackContext: EpisodePlaybackContext?, owner: UUID, authority: TrackerOperationAuthority? = nil) async -> Bool {
        do {
            let authority = authority ?? operationAuthority(for: account, owner: owner)
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(
                account,
                requiredOwner: owner,
                requiredAuthority: authority
            )
            guard refreshedAccount.userId == account.userId else {
                Logger.shared.log("Skipped Trakt history write for TMDB \(showId); the connected account changed while it was queued", type: "Tracker")
                return false
            }
            let requestAuthority = authority.replacingCredential(with: refreshedAccount)
            guard let traktId = await getTraktIdFromTmdbId(showId, mediaType: .show) else {
                Logger.shared.log("Could not find Trakt ID for TMDB show ID \(showId)", type: "Tracker")
                return false
            }
            guard let traktEpisodeId = await resolveTraktEpisodeIdForSync(
                showTraktId: traktId,
                resolved: resolved,
                playbackContext: playbackContext,
                account: refreshedAccount,
                owner: owner,
                authority: requestAuthority
            ) else {
                return false
            }

            let logSeason = resolved?.season ?? -1
            let logEpisode = resolved?.episode ?? (playbackContext?.animeAbsoluteEpisodeNumber ?? -1)
            let traktProgress = progress <= 1.0 ? progress * 100.0 : progress
            guard traktProgress >= 85 else {
                return await scrobblePause(account: refreshedAccount, traktEpisodeId: traktEpisodeId, seasonNumber: logSeason, episodeNumber: logEpisode, progress: traktProgress, owner: owner, authority: requestAuthority)
            }

            guard let writeAttempt = beginTraktHistoryWrite(
                owner: owner,
                accountUserId: refreshedAccount.userId,
                kind: "episode",
                traktId: traktEpisodeId
            ) else {
                Logger.shared.log(
                    "Skipped Trakt history write for TMDB \(showId); its retry receipt could not be persisted",
                    type: "Error"
                )
                return false
            }
            defer {
                if writeAttempt.disposition.ownsInFlightClaim {
                    finishTraktHistoryWriteAttempt(writeAttempt)
                }
            }
            guard await operationAuthorityIsCurrent(requestAuthority) else {
                abandonTraktHistoryWriteReceipt(writeAttempt)
                return false
            }

            var accountForWrite = refreshedAccount
            switch writeAttempt.disposition {
            case .suppressConfirmed:
                Logger.shared.log(
                    "Skipped recently confirmed Trakt history write for S\(logSeason)E\(logEpisode)",
                    type: "Tracker"
                )
                return true
            case .deferPending:
                Logger.shared.log(
                    "Deferred ambiguous Trakt history write for S\(logSeason)E\(logEpisode) until it can be reconciled",
                    type: "Tracker"
                )
                return false
            case .reconcile:
                switch await reconcileTraktHistoryWrite(
                    writeAttempt,
                    mediaType: "episodes",
                    traktId: traktEpisodeId,
                    account: refreshedAccount,
                    owner: owner,
                    authority: requestAuthority
                ) {
                case .found:
                    confirmTraktHistoryWrite(writeAttempt)
                    Logger.shared.log(
                        "Reconciled ambiguous Trakt history write for S\(logSeason)E\(logEpisode); no retry sent",
                        type: "Tracker"
                    )
                    return true
                case .absent(let reconciledAccount):
                    accountForWrite = reconciledAccount
                case .unavailable:
                    Logger.shared.log(
                        "Kept ambiguous Trakt history write pending for S\(logSeason)E\(logEpisode); history could not prove absence",
                        type: "Tracker"
                    )
                    return false
                }
            case .send:
                break
            }

            let payload: [String: Any] = [
                "episodes": [
                    [
                        "watched_at": traktWatchedAtString(writeAttempt.watchedAt),
                        "ids": ["trakt": traktEpisodeId]
                    ]
                ]
            ]
            let data = try await postTraktJSON(
                path: "sync/history",
                account: accountForWrite,
                payload: payload,
                maxRetries: 1,
                owner: owner,
                requiredAccountBoundaryGeneration: requestAuthority.accountBoundaryGeneration,
                requiredAuthority: requestAuthority.replacingCredential(with: accountForWrite)
            )
            confirmTraktHistoryWrite(writeAttempt)
            Logger.shared.log("Trakt sync response: \(responseBodyPreview(from: data))", type: "Tracker")
            Logger.shared.log("Synced to Trakt: S\(logSeason)E\(logEpisode) (watched)", type: "Tracker")
            return true
        } catch let error where Self.isTraktAuthenticationRequiredError(error) {
            return false
        } catch {
            Logger.shared.log("Failed to sync to Trakt: \(error.localizedDescription)", type: "Error")
            return false
        }
    }

    private func syncMovieToTrakt(account: TrackerAccount, movieId: Int, progress: Double, owner: UUID, authority: TrackerOperationAuthority? = nil) async {
        do {
            let authority = authority ?? operationAuthority(for: account, owner: owner)
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(
                account,
                requiredOwner: owner,
                requiredAuthority: authority
            )
            guard refreshedAccount.userId == account.userId else {
                Logger.shared.log("Skipped Trakt movie history write for TMDB \(movieId); the connected account changed while it was queued", type: "Tracker")
                return
            }
            let requestAuthority = authority.replacingCredential(with: refreshedAccount)
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
                    progress: traktProgress,
                    owner: owner,
                    authority: requestAuthority
                )
                return
            }

            guard let writeAttempt = beginTraktHistoryWrite(
                owner: owner,
                accountUserId: refreshedAccount.userId,
                kind: "movie",
                traktId: traktId
            ) else {
                Logger.shared.log(
                    "Skipped Trakt movie history write for TMDB \(movieId); its retry receipt could not be persisted",
                    type: "Error"
                )
                return
            }
            defer {
                if writeAttempt.disposition.ownsInFlightClaim {
                    finishTraktHistoryWriteAttempt(writeAttempt)
                }
            }
            guard await operationAuthorityIsCurrent(requestAuthority) else {
                abandonTraktHistoryWriteReceipt(writeAttempt)
                return
            }

            var accountForWrite = refreshedAccount
            switch writeAttempt.disposition {
            case .suppressConfirmed:
                Logger.shared.log(
                    "Skipped recently confirmed Trakt movie history write for TMDB \(movieId)",
                    type: "Tracker"
                )
                return
            case .deferPending:
                Logger.shared.log(
                    "Deferred ambiguous Trakt movie history write for TMDB \(movieId) until it can be reconciled",
                    type: "Tracker"
                )
                return
            case .reconcile:
                switch await reconcileTraktHistoryWrite(
                    writeAttempt,
                    mediaType: "movies",
                    traktId: traktId,
                    account: refreshedAccount,
                    owner: owner,
                    authority: requestAuthority
                ) {
                case .found:
                    confirmTraktHistoryWrite(writeAttempt)
                    Logger.shared.log(
                        "Reconciled ambiguous Trakt movie history write for TMDB \(movieId); no retry sent",
                        type: "Tracker"
                    )
                    return
                case .absent(let reconciledAccount):
                    accountForWrite = reconciledAccount
                case .unavailable:
                    Logger.shared.log(
                        "Kept ambiguous Trakt movie history write pending for TMDB \(movieId); history could not prove absence",
                        type: "Tracker"
                    )
                    return
                }
            case .send:
                break
            }

            let payload: [String: Any] = [
                "movies": [
                    [
                        "ids": ["trakt": traktId],
                        "watched_at": traktWatchedAtString(writeAttempt.watchedAt)
                    ]
                ]
            ]
            _ = try await postTraktJSON(
                path: "sync/history",
                account: accountForWrite,
                payload: payload,
                maxRetries: 1,
                owner: owner,
                requiredAccountBoundaryGeneration: requestAuthority.accountBoundaryGeneration,
                requiredAuthority: requestAuthority.replacingCredential(with: accountForWrite)
            )
            confirmTraktHistoryWrite(writeAttempt)
            Logger.shared.log("Synced movie to Trakt: TMDB \(movieId) (watched)", type: "Tracker")
        } catch let error where Self.isTraktAuthenticationRequiredError(error) {
            return
        } catch {
            Logger.shared.log("Failed to sync movie to Trakt: \(error.localizedDescription)", type: "Error")
        }
    }

    @discardableResult
    private func scrobblePause(account: TrackerAccount, traktEpisodeId: Int, seasonNumber: Int, episodeNumber: Int, progress: Double, owner: UUID, authority: TrackerOperationAuthority) async -> Bool {
        let payload: [String: Any] = [
            "progress": normalizedTraktScrobbleProgress(progress),
            "episode": ["ids": ["trakt": traktEpisodeId]]
        ]

        do {
            _ = try await postTraktJSON(
                path: "scrobble/pause",
                account: account,
                payload: payload,
                owner: owner,
                requiredAuthority: authority
            )
            let logPercent = Self.watchSyncLogPercent(progress) ?? 0
            Logger.shared.log("Scrobbled to Trakt: S\(seasonNumber)E\(episodeNumber) \(logPercent)%", type: "Tracker")
            return true
        } catch let error where Self.isTraktAuthenticationRequiredError(error) {
            return false
        } catch {
            Logger.shared.log("Failed to scrobble to Trakt: \(error.localizedDescription)", type: "Error")
            return false
        }
    }

    private func scrobbleMoviePause(account: TrackerAccount, traktId: Int, title: String, year: Int, progress: Double, owner: UUID, authority: TrackerOperationAuthority) async {
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
                ],
                owner: owner,
                requiredAuthority: authority
            )
            let logPercent = Self.watchSyncLogPercent(progress) ?? 0
            Logger.shared.log("Scrobbled movie to Trakt: \(logPercent)%", type: "Tracker")
        } catch let error where Self.isTraktAuthenticationRequiredError(error) {
            return
        } catch {
            Logger.shared.log("Failed to scrobble movie to Trakt: \(error.localizedDescription)", type: "Error")
        }
    }

    private func normalizedTraktScrobbleProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
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
        maxRetries: Int = 2,
        owner: UUID,
        requiredAccountBoundaryGeneration: UInt64? = nil,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> Data {
        guard !traktClientId.isEmpty else {
            throw NSError(domain: "Trakt", code: -1, userInfo: [NSLocalizedDescriptionKey: "TRAKT_CLIENT_ID is not configured."])
        }

        let authority = requiredAuthority ?? operationAuthority(for: account, owner: owner)
        guard authority.owner == owner,
              authority.matches(account),
              (requiredAccountBoundaryGeneration == nil
                || requiredAccountBoundaryGeneration == authority.accountBoundaryGeneration) else {
            throw CancellationError()
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
            reportRateLimitStatus: false,
            reportAuthenticationFailure: !allowsRefreshRetry,
            beforeAttempt: { [weak self] in
                guard let self else { throw CancellationError() }
                guard await self.operationAuthorityIsCurrent(authority) else {
                    throw CancellationError()
                }
            }
        )
        let statusCode = response.statusCode
        if statusCode == 401, allowsRefreshRetry {
            let refreshedAccount = try await refreshedTraktAccountIfNeeded(
                account,
                force: true,
                requiredOwner: owner,
                requiredAuthority: authority
            )
            guard refreshedAccount.userId == account.userId else {
                Logger.shared.log(
                    "Skipped Trakt \(path) retry; the connected account changed while the request was in flight",
                    type: "Tracker"
                )
                throw CancellationError()
            }
            return try await postTraktJSON(
                path: path,
                account: refreshedAccount,
                payload: payload,
                allowsRefreshRetry: false,
                additionalAcceptedStatusCodes: additionalAcceptedStatusCodes,
                maxRetries: maxRetries,
                owner: owner,
                requiredAccountBoundaryGeneration: requiredAccountBoundaryGeneration,
                requiredAuthority: authority.replacingCredential(with: refreshedAccount)
            )
        }
        guard (200...299).contains(statusCode) || additionalAcceptedStatusCodes.contains(statusCode) else {
            let diagnostic = responseBodyPreview(from: data)
            throw NSError(domain: "Trakt", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Trakt \(path) returned status \(statusCode): \(diagnostic)"])
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
                let diagnostic = responseBodyPreview(from: data)
                Logger.shared.log("Trakt tmdb lookup failed (HTTP \(response.statusCode)): \(diagnostic)", type: "Tracker")
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

    private func getTraktEpisodeId(showTraktId: Int, seasonNumber: Int, episodeNumber: Int, account: TrackerAccount, owner: UUID? = nil, authority: TrackerOperationAuthority? = nil) async -> Int? {
        let cacheKey = "episode|\(showTraktId)|\(seasonNumber)|\(episodeNumber)"
        if let cached = traktMediaIdCacheQueue.sync(execute: { traktMediaIdCache[cacheKey] }) {
            return cached
        }

        do {
            let data = try await fetchTraktPlaybackData(
                path: "shows/\(showTraktId)/seasons/\(seasonNumber)/episodes/\(episodeNumber)",
                account: account,
                owner: owner,
                requiredAuthority: authority
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

    private func traktFlattenedEpisodeId(showTraktId: Int, absoluteEpisodeNumber: Int, account: TrackerAccount, owner: UUID? = nil, authority: TrackerOperationAuthority? = nil) async -> Int? {
        guard absoluteEpisodeNumber > 0 else { return nil }
        let cacheKey = "episode-abs|\(showTraktId)|\(absoluteEpisodeNumber)"
        if let cached = traktMediaIdCacheQueue.sync(execute: { traktMediaIdCache[cacheKey] }) {
            return cached
        }

        do {
            let data = try await fetchTraktPlaybackData(
                path: "shows/\(showTraktId)/seasons?extended=episodes",
                account: account,
                owner: owner,
                requiredAuthority: authority
            )
            let seasons = try JSONDecoder().decode([TraktSeasonWithEpisodes].self, from: data)

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

    private func resolveTraktEpisodeIdForSync(
        showTraktId: Int,
        resolved: (season: Int, episode: Int)?,
        playbackContext: EpisodePlaybackContext?,
        account: TrackerAccount,
        owner: UUID? = nil,
        authority: TrackerOperationAuthority? = nil
    ) async -> Int? {
        if let resolved,
           let directId = await getTraktEpisodeId(
                showTraktId: showTraktId,
                seasonNumber: resolved.season,
                episodeNumber: resolved.episode,
                account: account,
                owner: owner,
                authority: authority
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
            account: account,
            owner: owner,
            authority: authority
        )
    }

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

    private func getMyAnimeListId(
        fromAniListId aniListId: Int,
        mediaType: String,
        requiredProfileAuthority: TrackerProfileOperationAuthority? = nil
    ) async -> Int? {
        if let requiredProfileAuthority,
           !profileOperationAuthorityIsCurrent(requiredProfileAuthority) {
            return nil
        }
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

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .anilist,
                beforeAttempt: { [weak self] in
                    guard let requiredProfileAuthority else { return }
                    guard let self,
                          self.profileOperationAuthorityIsCurrent(requiredProfileAuthority) else {
                        throw CancellationError()
                    }
                }
            )
            guard response.statusCode == 200,
                  requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else { return nil }

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

    private func getAniListId(
        fromMALId malId: Int,
        mediaType: String,
        requiredProfileAuthority: TrackerProfileOperationAuthority? = nil
    ) async -> Int? {
        if let requiredProfileAuthority,
           !profileOperationAuthorityIsCurrent(requiredProfileAuthority) {
            return nil
        }
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

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .anilist,
                beforeAttempt: { [weak self] in
                    guard let requiredProfileAuthority else { return }
                    guard let self,
                          self.profileOperationAuthorityIsCurrent(requiredProfileAuthority) else {
                        throw CancellationError()
                    }
                }
            )
            guard response.statusCode == 200,
                  requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else { return nil }

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
        await getAniListMediaId(
            tmdbId: tmdbId,
            requiredProfileAuthority: nil
        )
    }

    private func getAniListMediaId(
        tmdbId: Int,
        requiredProfileAuthority: TrackerProfileOperationAuthority?
    ) async -> Int? {

        if let requiredProfileAuthority,
           !profileOperationAuthorityIsCurrent(requiredProfileAuthority) {
            return nil
        }

        if let cachedId = cachedAniListId(for: tmdbId) {
            return cachedId
        }

        var candidateTitles: [String] = []
        var firstAirYear: Int?

        if let detail = try? await TMDBService.shared.getTVShowDetails(id: tmdbId) {
            guard requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else { return nil }
            candidateTitles.append(detail.name)
            if let original = detail.originalName { candidateTitles.append(original) }

            if let firstAirDate = detail.firstAirDate, let year = Int(firstAirDate.prefix(4)) {
                firstAirYear = year
            }

            if let alt = try? await TMDBService.shared.getTVShowAlternativeTitles(id: tmdbId) {
                guard requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else { return nil }
                candidateTitles.append(contentsOf: alt.results.map { $0.title })
            }
        }

        var seen = Set<String>()
        let titles = candidateTitles.compactMap { title -> String? in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed.lowercased()) else { return nil }
            seen.insert(trimmed.lowercased())
            return trimmed
        }

        for title in titles {
            if let id = await searchAniListId(
                byTitle: title,
                seasonYear: firstAirYear,
                requiredProfileAuthority: requiredProfileAuthority
            ) {
                guard requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else { return nil }
                cacheAniListId(tmdbId: tmdbId, anilistId: id)
                Logger.shared.log("Resolved AniList ID \(id) for TMDB \(tmdbId) using title '" + title + "'", type: "Tracker")
                return id
            }
        }

        Logger.shared.log("AniList lookup failed for TMDB ID \(tmdbId) after trying \(titles.count) title(s)", type: "Tracker")
        return nil
    }

    private func searchAniListId(
        byTitle title: String,
        seasonYear: Int?,
        requiredProfileAuthority: TrackerProfileOperationAuthority? = nil
    ) async -> Int? {
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

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .anilist,
                beforeAttempt: { [weak self] in
                    guard let requiredProfileAuthority else { return }
                    guard let self,
                          self.profileOperationAuthorityIsCurrent(requiredProfileAuthority) else {
                        throw CancellationError()
                    }
                }
            )
            guard response.statusCode == 200,
                  requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else { return nil }

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

    private func resolveMangaTrackerMatch(
        title: String,
        totalChapters: Int?,
        format: String?,
        routeKey: String?,
        knownAniListId: Int?,
        knownMALId: Int?,
        requiredProfileAuthority: TrackerProfileOperationAuthority? = nil,
        requiredMALAuthority: TrackerOperationAuthority? = nil
    ) async -> MangaTrackerMatch? {
        guard requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else {
            return nil
        }
        if let knownAniListId, knownAniListId > 0 {
            let match = MangaTrackerMatch(aniListId: knownAniListId, malId: knownMALId, title: title, confidence: 100)
            if let routeKey {
                cacheMangaTrackerMatch(match, for: routeKey)
            }
            return match
        }

        if let knownMALId, knownMALId > 0, knownAniListId == nil {
            let aniListId = await getAniListId(
                fromMALId: knownMALId,
                mediaType: "MANGA",
                requiredProfileAuthority: requiredProfileAuthority
            )
            guard requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else {
                return nil
            }
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

        async let aniListMatch = searchAniListMangaTrackerMatch(
            title: title,
            totalChapters: totalChapters,
            format: format,
            requiredProfileAuthority: requiredProfileAuthority
        )
        async let malMatch = searchMALMangaTrackerMatch(
            title: title,
            totalChapters: totalChapters,
            format: format,
            requiredProfileAuthority: requiredProfileAuthority,
            requiredAuthority: requiredMALAuthority
        )

        let resolvedAniList = await aniListMatch
        let resolvedMAL = await malMatch
        guard requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else {
            return nil
        }
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
            match = await reconciledMangaTrackerMatch(
                aniListMatch: acceptedAniList,
                malMatch: acceptedMAL,
                fallbackTitle: title,
                requiredProfileAuthority: requiredProfileAuthority
            )
        } else if let acceptedAniList {
            match = acceptedAniList
        } else if let acceptedMAL {
            match = await mangaTrackerMatchResolvingAniListFromMAL(
                acceptedMAL,
                requiredProfileAuthority: requiredProfileAuthority
            )
        } else {
            match = nil
        }

        guard requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true,
              let match, match.isUsable else { return nil }
        cacheMangaTrackerMatch(match, for: cacheKey)
        return match
    }

    private func searchAniListMangaTrackerMatch(
        title: String,
        totalChapters: Int?,
        format: String?,
        requiredProfileAuthority: TrackerProfileOperationAuthority? = nil
    ) async -> MangaTrackerMatch? {
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

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .anilist,
                beforeAttempt: { [weak self] in
                    guard let requiredProfileAuthority else { return }
                    guard let self,
                          self.profileOperationAuthorityIsCurrent(requiredProfileAuthority) else {
                        throw CancellationError()
                    }
                }
            )
            guard response.statusCode == 200,
                  requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else { return nil }

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

    private func searchMALMangaTrackerMatch(
        title: String,
        totalChapters: Int?,
        format: String?,
        requiredProfileAuthority: TrackerProfileOperationAuthority? = nil,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async -> MangaTrackerMatch? {
        guard requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else {
            return nil
        }
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
            var requestAuthority: TrackerOperationAuthority?
            if !malClientId.isEmpty {
                request.setValue(malClientId, forHTTPHeaderField: "X-MAL-CLIENT-ID")
            } else if let requiredAuthority,
                      let account = trackerState.accounts.first(where: {
                          $0.isConnected
                              && $0.service == .myAnimeList
                              && requiredAuthority.matches($0)
                      }),
                      let refreshed = try? await refreshedMALAccountIfNeeded(
                          account,
                          requiredOwner: requiredAuthority.owner,
                          requiredAuthority: requiredAuthority
                      ) {
                requestAuthority = requiredAuthority.replacingCredential(with: refreshed)
                request.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
            } else if case nil = requiredAuthority,
                      let account = trackerState.accounts.first(where: { $0.isConnected && $0.service == .myAnimeList }),
                      let refreshed = try? await refreshedMALAccountIfNeeded(account) {
                requestAuthority = operationAuthority(for: refreshed, owner: activeProfileID)
                request.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
            } else {
                return nil
            }

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .myAnimeList,
                beforeAttempt: { [weak self] in
                    guard let self else { throw CancellationError() }
                    if let requiredProfileAuthority,
                       !self.profileOperationAuthorityIsCurrent(requiredProfileAuthority) {
                        throw CancellationError()
                    }
                    if let requestAuthority,
                       !(await self.operationAuthorityIsCurrent(requestAuthority)) {
                        throw CancellationError()
                    }
                }
            )
            guard response.statusCode == 200,
                  requiredProfileAuthority.map(profileOperationAuthorityIsCurrent) ?? true else { return nil }

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
        fallbackTitle: String,
        requiredProfileAuthority: TrackerProfileOperationAuthority? = nil
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
            return await preferredSingleProviderMangaMatch(
                aniListMatch: aniListMatch,
                malMatch: malMatch,
                requiredProfileAuthority: requiredProfileAuthority
            )
        }

        if let aniListId = aniListMatch.aniListId, let malId = malMatch.malId {
            if let mappedAniListId = await getAniListId(
                fromMALId: malId,
                mediaType: "MANGA",
                requiredProfileAuthority: requiredProfileAuthority
            ) {
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
                return await preferredSingleProviderMangaMatch(
                    aniListMatch: aniListMatch,
                    malMatch: malMatch,
                    requiredProfileAuthority: requiredProfileAuthority
                )
            }
        }

        ReaderLogger.shared.log(
            "Manga tracker resolver could not cross-confirm AniList/MAL matches for '\(fallbackTitle)'. Using higher-confidence provider only.",
            type: "Tracker"
        )
        return await preferredSingleProviderMangaMatch(
            aniListMatch: aniListMatch,
            malMatch: malMatch,
            requiredProfileAuthority: requiredProfileAuthority
        )
    }

    private func preferredSingleProviderMangaMatch(
        aniListMatch: MangaTrackerMatch,
        malMatch: MangaTrackerMatch,
        requiredProfileAuthority: TrackerProfileOperationAuthority? = nil
    ) async -> MangaTrackerMatch {
        if aniListMatch.confidence >= malMatch.confidence {
            return aniListMatch
        }
        return await mangaTrackerMatchResolvingAniListFromMAL(
            malMatch,
            requiredProfileAuthority: requiredProfileAuthority
        )
    }

    private func mangaTrackerMatchResolvingAniListFromMAL(
        _ match: MangaTrackerMatch,
        requiredProfileAuthority: TrackerProfileOperationAuthority? = nil
    ) async -> MangaTrackerMatch {
        guard match.aniListId == nil, let malId = match.malId else { return match }
        let aniListId = await getAniListId(
            fromMALId: malId,
            mediaType: "MANGA",
            requiredProfileAuthority: requiredProfileAuthority
        )
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

    private func validateSyncToolAuthority(
        owner: UUID,
        accounts: [TrackerAccount]
    ) async throws {
        try Task.checkCancellation()
        try requireOwner(owner)
        for account in accounts {

            try await requireTrackerAccountStillConnected(
                account,
                owner: owner,
                requireSameCredential: false
            )
        }
        try requireOwner(owner)
        try Task.checkCancellation()
    }

    private func validateSyncToolPlan(_ plan: TrackerSyncToolPlan) async throws {
        try await validateSyncToolAuthority(
            owner: plan.owner,
            accounts: plan.accountSnapshots
        )
    }

    private func finalizedSyncToolPlan(_ plan: TrackerSyncToolPlan) async throws -> TrackerSyncToolPlan {
        try await validateSyncToolPlan(plan)
        return plan
    }

    private func finalizedSyncToolResult(
        _ result: TrackerSyncPreview,
        plan: TrackerSyncToolPlan
    ) async throws -> TrackerSyncPreview {
        try await validateSyncToolPlan(plan)
        return result
    }

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
                try await validateSyncToolPlan(plan)
                try await MainActor.run {
                    try self.requireOwner(plan.owner)
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
                try await MainActor.run {
                    try self.requireOwner(plan.owner)
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

        if let cachedSyncToolPlan,
           cachedSyncToolPlan.action == action,
           cachedSyncToolPlan.owner == ProfileManager.shared.activeProfileID {
            try await validateSyncToolPlan(cachedSyncToolPlan)
            return cachedSyncToolPlan
        }
        let plan = try await buildSyncToolPlan(for: action)
        try await validateSyncToolPlan(plan)
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

        let owner = ProfileManager.shared.activeProfileID
        try requireOwner(owner)
        switch action {
        case .fillEclipseFromAniList:
            let account = try connectedAccount(.anilist)
            let animeEntries = try await fetchAniListAnimeProgressEntries(account: account)
            try await validateSyncToolAuthority(owner: owner, accounts: [account])
            let mangaEntries = try await fetchAniListMangaProgressEntries(account: account)
            try await validateSyncToolAuthority(owner: owner, accounts: [account])
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
            return try await finalizedSyncToolPlan(TrackerSyncToolPlan(
                action: action,
                owner: owner,
                accountSnapshots: [account],
                preview: preview,
                animeEntries: animeEntries,
                mangaEntries: mangaEntries
            ))

        case .fillEclipseFromMAL:
            let account = try connectedAccount(.myAnimeList)
            let fetchedAnimeEntries = try await fetchMALAnimeProgressEntries(account: account)
            try await validateSyncToolAuthority(owner: owner, accounts: [account])
            let animeEntries = await resolveMALAnimeEntriesToAniList(fetchedAnimeEntries)
            try await validateSyncToolAuthority(owner: owner, accounts: [account])
            let fetchedMangaEntries = try await fetchMALMangaProgressEntries(account: account)
            try await validateSyncToolAuthority(owner: owner, accounts: [account])
            let mangaEntries = await resolveMALMangaEntriesToAniList(fetchedMangaEntries)
            try await validateSyncToolAuthority(owner: owner, accounts: [account])
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
            return try await finalizedSyncToolPlan(TrackerSyncToolPlan(
                action: action,
                owner: owner,
                accountSnapshots: [account],
                preview: preview,
                animeEntries: animeEntries,
                mangaEntries: mangaEntries
            ))

        case .pushEclipseToAniList:
            let account = try connectedAccount(.anilist)
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
            return try await finalizedSyncToolPlan(TrackerSyncToolPlan(
                action: action,
                owner: owner,
                accountSnapshots: [account],
                preview: preview
            ))

        case .pushEclipseToMAL:
            let account = try connectedAccount(.myAnimeList)
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
            return try await finalizedSyncToolPlan(TrackerSyncToolPlan(
                action: action,
                owner: owner,
                accountSnapshots: [account],
                preview: preview
            ))

        case .portAniListToMAL:
            let account = try connectedAccount(.anilist)
            let destination = try connectedAccount(.myAnimeList)
            let sourceAnimeEntries = try await fetchAniListAnimeProgressEntries(account: account)
            try await validateSyncToolAuthority(owner: owner, accounts: [account, destination])
            let sourceMangaEntries = try await fetchAniListMangaProgressEntries(account: account)
            try await validateSyncToolAuthority(owner: owner, accounts: [account, destination])
            let destinationAnime = try await fetchMALAnimeProgressEntries(account: destination)
            try await validateSyncToolAuthority(owner: owner, accounts: [account, destination])
            let destinationManga = try await fetchMALMangaProgressEntries(account: destination)
            try await validateSyncToolAuthority(owner: owner, accounts: [account, destination])
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
            return try await finalizedSyncToolPlan(TrackerSyncToolPlan(
                action: action,
                owner: owner,
                accountSnapshots: [account, destination],
                preview: preview,
                animeEntries: animeEntries,
                mangaEntries: mangaEntries
            ))

        case .portMALToAniList:
            let account = try connectedAccount(.myAnimeList)
            let destination = try connectedAccount(.anilist)
            let fetchedSourceAnimeEntries = try await fetchMALAnimeProgressEntries(account: account)
            try await validateSyncToolAuthority(owner: owner, accounts: [account, destination])
            let sourceAnimeEntries = await resolveMALAnimeEntriesToAniList(fetchedSourceAnimeEntries)
            try await validateSyncToolAuthority(owner: owner, accounts: [account, destination])
            let fetchedSourceMangaEntries = try await fetchMALMangaProgressEntries(account: account)
            try await validateSyncToolAuthority(owner: owner, accounts: [account, destination])
            let sourceMangaEntries = await resolveMALMangaEntriesToAniList(fetchedSourceMangaEntries)
            try await validateSyncToolAuthority(owner: owner, accounts: [account, destination])
            let destinationAnime = try await fetchAniListAnimeProgressEntries(account: destination)
            try await validateSyncToolAuthority(owner: owner, accounts: [account, destination])
            let destinationManga = try await fetchAniListMangaProgressEntries(account: destination)
            try await validateSyncToolAuthority(owner: owner, accounts: [account, destination])
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
            return try await finalizedSyncToolPlan(TrackerSyncToolPlan(
                action: action,
                owner: owner,
                accountSnapshots: [account, destination],
                preview: preview,
                animeEntries: animeEntries,
                mangaEntries: mangaEntries
            ))
        }
    }

    private func performSyncTool(_ plan: TrackerSyncToolPlan) async throws -> TrackerSyncPreview {
        try await validateSyncToolPlan(plan)
        let action = plan.action
        switch action {
        case .fillEclipseFromAniList:
            _ = try connectedAccount(.anilist)
            await updateSyncToolProgress(detail: "Filling Eclipse anime from AniList...")
            let animeResult = try await fillEclipseFromRemoteAnime(plan.animeEntries, sourceName: "AniList", action: action, owner: plan.owner)
            try await advanceSyncToolProgress(by: plan.animeEntries.count, detail: "Finished AniList anime fill")
            await updateSyncToolProgress(detail: "Filling Eclipse manga from AniList...")
            let mangaResult = try await fillEclipseFromRemoteManga(plan.mangaEntries, sourceName: "AniList", action: action, owner: plan.owner)
            try await advanceSyncToolProgress(by: plan.mangaEntries.count, detail: "Finished AniList manga fill")
            return try await finalizedSyncToolResult(
                combineSyncPreviews(action: action, animeResult, mangaResult, note: "AniList fill completed without deleting or downgrading local progress."),
                plan: plan
            )

        case .fillEclipseFromMAL:
            _ = try connectedAccount(.myAnimeList)
            await updateSyncToolProgress(detail: "Filling Eclipse anime from MAL...")
            let animeResult = try await fillEclipseFromRemoteAnime(plan.animeEntries, sourceName: "MAL", action: action, owner: plan.owner)
            try await advanceSyncToolProgress(by: plan.animeEntries.count, detail: "Finished MAL anime fill")
            await updateSyncToolProgress(detail: "Filling Eclipse manga from MAL...")
            let mangaResult = try await fillEclipseFromRemoteManga(plan.mangaEntries, sourceName: "MAL", action: action, owner: plan.owner)
            try await advanceSyncToolProgress(by: plan.mangaEntries.count, detail: "Finished MAL manga fill")
            return try await finalizedSyncToolResult(
                combineSyncPreviews(action: action, animeResult, mangaResult, note: "MAL fill completed without deleting or downgrading local progress."),
                plan: plan
            )

        case .pushEclipseToAniList:
            let account = try connectedAccount(.anilist)
            let anime = localHighestWatchedEpisodes()
            let manga = localHighestReadMangaChapters()
            for (index, entry) in anime.enumerated() {
                try await validateSyncToolPlan(plan)
                await updateSyncToolProgress(detail: "Pushing anime \(index + 1) of \(anime.count) to AniList...")
                await syncToAniList(
                    account: account,
                    showId: entry.showId,
                    seasonNumber: entry.seasonNumber,
                    episodeNumber: entry.episodeNumber,
                    progress: 1.0,
                    owner: plan.owner
                )
                try await validateSyncToolPlan(plan)
                try await advanceSyncToolProgress()
            }
            for (index, item) in manga.enumerated() {
                try await validateSyncToolPlan(plan)
                await updateSyncToolProgress(detail: "Pushing manga \(index + 1) of \(manga.count) to AniList...")
                await sendMangaProgressToAniList(
                    mediaId: item.mangaId,
                    chapterNumber: item.chapter,
                    account: account,
                    owner: plan.owner
                )
                try await validateSyncToolPlan(plan)
                try await advanceSyncToolProgress()
            }
            return try await finalizedSyncToolResult(
                TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: anime.count + manga.count, skipped: 0, unmapped: 0, estimatedAPICalls: 0, notes: ["Eclipse progress push completed."]),
                plan: plan
            )

        case .pushEclipseToMAL:
            let account = try connectedAccount(.myAnimeList)
            let anime = localHighestWatchedEpisodes()
            let manga = localHighestReadMangaChapters()
            for (index, entry) in anime.enumerated() {
                try await validateSyncToolPlan(plan)
                await updateSyncToolProgress(detail: "Pushing anime \(index + 1) of \(anime.count) to MAL...")
                await syncToMyAnimeList(account: account, showId: entry.showId, seasonNumber: entry.seasonNumber, episodeNumber: entry.episodeNumber, progress: 1.0, owner: plan.owner)
                try await validateSyncToolPlan(plan)
                try await advanceSyncToolProgress()
            }
            for (index, item) in manga.enumerated() {
                try await validateSyncToolPlan(plan)
                await updateSyncToolProgress(detail: "Pushing manga \(index + 1) of \(manga.count) to MAL...")
                await sendMangaProgressToMAL(aniListId: item.mangaId, chapterNumber: item.chapter, account: account, owner: plan.owner)
                try await validateSyncToolPlan(plan)
                try await advanceSyncToolProgress()
            }
            return try await finalizedSyncToolResult(
                TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: anime.count + manga.count, skipped: 0, unmapped: 0, estimatedAPICalls: 0, notes: ["Eclipse progress push completed."]),
                plan: plan
            )

        case .portAniListToMAL:
            _ = try connectedAccount(.anilist)
            let destination = try connectedAccount(.myAnimeList)
            var advanced = 0
            var unmapped = 0
            for (index, entry) in plan.animeEntries.enumerated() {
                try await validateSyncToolPlan(plan)
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
                    status: malStatus(fromAniListStatus: entry.status),
                    owner: plan.owner
                )
                try await validateSyncToolPlan(plan)
                advanced += 1
                try await advanceSyncToolProgress()
            }
            for (index, entry) in plan.mangaEntries.enumerated() {
                try await validateSyncToolPlan(plan)
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
                    status: malMangaStatus(fromAniListStatus: entry.status),
                    owner: plan.owner
                )
                try await validateSyncToolPlan(plan)
                advanced += 1
                try await advanceSyncToolProgress()
            }
            return try await finalizedSyncToolResult(
                TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: advanced, skipped: unmapped, unmapped: unmapped, estimatedAPICalls: advanced, notes: ["AniList to MAL port finished. No entries were deleted."]),
                plan: plan
            )

        case .portMALToAniList:
            _ = try connectedAccount(.myAnimeList)
            let destination = try connectedAccount(.anilist)
            var advanced = 0
            var unmapped = 0
            for (index, entry) in plan.animeEntries.enumerated() {
                try await validateSyncToolPlan(plan)
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
                    status: aniListStatus(fromMALStatus: entry.status),
                    owner: plan.owner
                )
                try await validateSyncToolPlan(plan)
                advanced += 1
                try await advanceSyncToolProgress()
            }
            for (index, entry) in plan.mangaEntries.enumerated() {
                try await validateSyncToolPlan(plan)
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
                    status: aniListStatus(fromMALStatus: entry.status),
                    owner: plan.owner
                )
                try await validateSyncToolPlan(plan)
                advanced += 1
                try await advanceSyncToolProgress()
            }
            return try await finalizedSyncToolResult(
                TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: advanced, skipped: unmapped, unmapped: unmapped, estimatedAPICalls: advanced, notes: ["MAL to AniList port finished. No entries were deleted."]),
                plan: plan
            )
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
        let multiplier = sourceName == "MAL" ? 2 : 1
        let (estimatedCalls, overflow) = entries.count.multipliedReportingOverflow(by: multiplier)
        return TrackerSyncPreview(
            action: action,
            itemsToAdd: mapped.count,
            itemsToAdvance: advanced,
            skipped: unmapped,
            unmapped: unmapped,
            estimatedAPICalls: max(2, overflow ? Int.max : estimatedCalls),
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
        TrackerRemoteProgressBoundary.pageCallCount(
            itemCount: itemCount,
            pageSize: pageSize
        ) ?? TrackerRemoteProgressBoundary.maximumPageCount
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
                try await validateSyncToolPlan(plan)
                try await MainActor.run {
                    try self.requireOwner(plan.owner)
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
                if let cachedSyncToolPlan,
                   cachedSyncToolPlan.action == action,
                   cachedSyncToolPlan.owner == ProfileManager.shared.activeProfileID {
                    try await validateSyncToolPlan(cachedSyncToolPlan)
                    plan = cachedSyncToolPlan
                } else {
                    plan = try await buildTVSyncToolPlan(for: action)
                    try await validateSyncToolPlan(plan)
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
                try await MainActor.run {
                    try self.requireOwner(plan.owner)
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
        let owner = ProfileManager.shared.activeProfileID
        try requireOwner(owner)
        switch action {
        case .fillEclipseFromAniList:
            let account = try connectedAccount(.anilist)
            let entries = try await fetchAniListAnimeProgressEntries(account: account)
            try await validateSyncToolAuthority(owner: owner, accounts: [account])
            return try await finalizedSyncToolPlan(TrackerSyncToolPlan(
                action: action,
                owner: owner,
                accountSnapshots: [account],
                preview: tvRemoteFillPreview(action: action, entries: entries, sourceName: "AniList"),
                animeEntries: entries
            ))

        case .fillEclipseFromMAL:
            let account = try connectedAccount(.myAnimeList)
            let fetchedEntries = try await fetchMALAnimeProgressEntries(account: account)
            try await validateSyncToolAuthority(owner: owner, accounts: [account])
            let entries = await resolveMALAnimeEntriesToAniList(fetchedEntries)
            try await validateSyncToolAuthority(owner: owner, accounts: [account])
            return try await finalizedSyncToolPlan(TrackerSyncToolPlan(
                action: action,
                owner: owner,
                accountSnapshots: [account],
                preview: tvRemoteFillPreview(action: action, entries: entries, sourceName: "MAL"),
                animeEntries: entries
            ))

        case .pushEclipseToAniList:
            let account = try connectedAccount(.anilist)
            let entries = localHighestWatchedEpisodes()
            return try await finalizedSyncToolPlan(TrackerSyncToolPlan(
                action: action,
                owner: owner,
                accountSnapshots: [account],
                preview: TrackerSyncPreview(
                    action: action,
                    itemsToAdd: 0,
                    itemsToAdvance: entries.count,
                    skipped: 0,
                    unmapped: 0,
                    estimatedAPICalls: entries.count * 3,
                    notes: ["Only local anime watch progress is sent from Apple TV."]
                )
            ))

        case .pushEclipseToMAL:
            let account = try connectedAccount(.myAnimeList)
            let entries = localHighestWatchedEpisodes()
            return try await finalizedSyncToolPlan(TrackerSyncToolPlan(
                action: action,
                owner: owner,
                accountSnapshots: [account],
                preview: TrackerSyncPreview(
                    action: action,
                    itemsToAdd: 0,
                    itemsToAdvance: entries.count,
                    skipped: 0,
                    unmapped: 0,
                    estimatedAPICalls: entries.count * 4,
                    notes: ["Only local anime watch progress is sent from Apple TV."]
                )
            ))

        case .portAniListToMAL:
            let source = try connectedAccount(.anilist)
            let destination = try connectedAccount(.myAnimeList)
            let sourceEntries = try await fetchAniListAnimeProgressEntries(account: source)
            try await validateSyncToolAuthority(owner: owner, accounts: [source, destination])
            let destinationEntries = try await fetchMALAnimeProgressEntries(account: destination)
            try await validateSyncToolAuthority(owner: owner, accounts: [source, destination])
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
            return try await finalizedSyncToolPlan(TrackerSyncToolPlan(
                action: action,
                owner: owner,
                accountSnapshots: [source, destination],
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
            ))

        case .portMALToAniList:
            let source = try connectedAccount(.myAnimeList)
            let destination = try connectedAccount(.anilist)
            let fetchedSourceEntries = try await fetchMALAnimeProgressEntries(account: source)
            try await validateSyncToolAuthority(owner: owner, accounts: [source, destination])
            let sourceEntries = await resolveMALAnimeEntriesToAniList(fetchedSourceEntries)
            try await validateSyncToolAuthority(owner: owner, accounts: [source, destination])
            let destinationEntries = try await fetchAniListAnimeProgressEntries(account: destination)
            try await validateSyncToolAuthority(owner: owner, accounts: [source, destination])
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
            return try await finalizedSyncToolPlan(TrackerSyncToolPlan(
                action: action,
                owner: owner,
                accountSnapshots: [source, destination],
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
            ))
        }
    }

    private func performTVSyncTool(_ plan: TrackerSyncToolPlan) async throws -> TrackerSyncPreview {
        try await validateSyncToolPlan(plan)
        let action = plan.action

        switch action {
        case .fillEclipseFromAniList:
            _ = try connectedAccount(.anilist)
            await updateSyncToolProgress(detail: "Filling Eclipse anime from AniList...")
            let result = try await fillEclipseFromRemoteAnime(plan.animeEntries, sourceName: "AniList", action: action, owner: plan.owner)
            try await advanceSyncToolProgress(by: plan.animeEntries.count, detail: "Finished AniList anime fill")
            return try await finalizedSyncToolResult(result, plan: plan)

        case .fillEclipseFromMAL:
            _ = try connectedAccount(.myAnimeList)
            await updateSyncToolProgress(detail: "Filling Eclipse anime from MAL...")
            let result = try await fillEclipseFromRemoteAnime(plan.animeEntries, sourceName: "MAL", action: action, owner: plan.owner)
            try await advanceSyncToolProgress(by: plan.animeEntries.count, detail: "Finished MAL anime fill")
            return try await finalizedSyncToolResult(result, plan: plan)

        case .pushEclipseToAniList:
            let account = try connectedAccount(.anilist)
            let entries = localHighestWatchedEpisodes()
            for (index, entry) in entries.enumerated() {
                try await validateSyncToolPlan(plan)
                await updateSyncToolProgress(detail: "Pushing anime \(index + 1) of \(entries.count) to AniList...")
                await syncToAniList(
                    account: account,
                    showId: entry.showId,
                    seasonNumber: entry.seasonNumber,
                    episodeNumber: entry.episodeNumber,
                    progress: 1.0,
                    owner: plan.owner
                )
                try await validateSyncToolPlan(plan)
                try await advanceSyncToolProgress()
            }
            return try await finalizedSyncToolResult(
                TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: entries.count, skipped: 0, unmapped: 0, estimatedAPICalls: 0, notes: ["Anime progress push completed."]),
                plan: plan
            )

        case .pushEclipseToMAL:
            let account = try connectedAccount(.myAnimeList)
            let entries = localHighestWatchedEpisodes()
            for (index, entry) in entries.enumerated() {
                try await validateSyncToolPlan(plan)
                await updateSyncToolProgress(detail: "Pushing anime \(index + 1) of \(entries.count) to MAL...")
                await syncToMyAnimeList(account: account, showId: entry.showId, seasonNumber: entry.seasonNumber, episodeNumber: entry.episodeNumber, progress: 1.0, owner: plan.owner)
                try await validateSyncToolPlan(plan)
                try await advanceSyncToolProgress()
            }
            return try await finalizedSyncToolResult(
                TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: entries.count, skipped: 0, unmapped: 0, estimatedAPICalls: 0, notes: ["Anime progress push completed."]),
                plan: plan
            )

        case .portAniListToMAL:
            _ = try connectedAccount(.anilist)
            let destination = try connectedAccount(.myAnimeList)
            var advanced = 0
            var unmapped = 0
            for (index, entry) in plan.animeEntries.enumerated() {
                try await validateSyncToolPlan(plan)
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
                    status: malStatus(fromAniListStatus: entry.status),
                    owner: plan.owner
                )
                try await validateSyncToolPlan(plan)
                advanced += 1
                try await advanceSyncToolProgress()
            }
            return try await finalizedSyncToolResult(
                TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: advanced, skipped: unmapped, unmapped: unmapped, estimatedAPICalls: advanced, notes: ["AniList to MAL anime port finished. No entries were deleted."]),
                plan: plan
            )

        case .portMALToAniList:
            _ = try connectedAccount(.myAnimeList)
            let destination = try connectedAccount(.anilist)
            var advanced = 0
            var unmapped = 0
            for (index, entry) in plan.animeEntries.enumerated() {
                try await validateSyncToolPlan(plan)
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
                    status: aniListStatus(fromMALStatus: entry.status),
                    owner: plan.owner
                )
                try await validateSyncToolPlan(plan)
                advanced += 1
                try await advanceSyncToolProgress()
            }
            return try await finalizedSyncToolResult(
                TrackerSyncPreview(action: action, itemsToAdd: 0, itemsToAdvance: advanced, skipped: unmapped, unmapped: unmapped, estimatedAPICalls: advanced, notes: ["MAL to AniList anime port finished. No entries were deleted."]),
                plan: plan
            )
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
        let pages = TrackerRemoteProgressBoundary.pageCallCount(
            itemCount: itemCount,
            pageSize: pageSize
        ) ?? TrackerRemoteProgressBoundary.maximumPageCount
        return sourceName == "MAL" ? min(pages * 2, Int.max) : pages
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

    private func fetchAniListAnimeProgressEntries(
        account: TrackerAccount,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> [RemoteAnimeProgress] {
        let userId = try await resolvedAniListUserId(
            for: account,
            requiredAuthority: requiredAuthority
        )
        var entriesByMediaId: [Int: RemoteAnimeProgress] = [:]
        var orderedMediaIds: [Int] = []
        var chunk = 1
        var hasNextChunk = true
        var pageCount = 0

        while hasNextChunk {
            guard pageCount < TrackerRemoteProgressBoundary.maximumPageCount else {
                throw NSError(domain: "AniList", code: -4, userInfo: [NSLocalizedDescriptionKey: "AniList anime list exceeded the supported page limit."])
            }
            pageCount += 1
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

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .anilist,
                beforeAttempt: { [weak self] in
                    guard let requiredAuthority else { return }
                    guard let self,
                          await self.operationAuthorityIsCurrent(requiredAuthority) else {
                        throw CancellationError()
                    }
                }
            )
            guard response.statusCode == 200 else {
                let message = aniListFailureDescription("AniList anime list fetch failed", response: response, data: data)
                Logger.shared.log(message, type: "Tracker")
                throw NSError(domain: "AniList", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }

            guard data.count <= 8 * 1_024 * 1_024 else {
                throw BoundedURLSessionError.responseTooLarge(maximumBytes: 8 * 1_024 * 1_024)
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let collection = decoded.data?.MediaListCollection else {
                let message = graphQLErrorMessage(from: data) != nil
                    ? "AniList anime list fetch failed: \(responseBodyPreview(from: data))"
                    : "AniList anime list fetch returned no collection data."
                throw NSError(domain: "AniList", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }

            guard collection.lists.count <= TrackerRemoteProgressBoundary.maximumRemoteEntryCount,
                  collection.lists.allSatisfy({
                      $0.entries.count <= TrackerRemoteProgressBoundary.maximumRemoteEntryCount
                  }) else {
                throw NSError(domain: "AniList", code: -4, userInfo: [NSLocalizedDescriptionKey: "AniList anime list exceeded the supported row limit."])
            }

            for group in collection.lists {
                for item in group.entries {
                    guard let media = item.media else { continue }
                    guard let entry = RemoteAnimeProgress(
                        validatingAniListID: media.id,
                        malID: media.idMal,
                        title: media.title.english ?? media.title.romaji ?? media.title.native ?? "Unknown",
                        status: item.status ?? group.status ?? "CURRENT",
                        progress: item.progress ?? 0,
                        totalEpisodes: media.episodes
                    ) else {
                        throw NSError(domain: "AniList", code: -4, userInfo: [NSLocalizedDescriptionKey: "AniList anime list contained unsupported numeric values."])
                    }
                    if let malId = entry.malId, let anilistId = entry.anilistId {
                        cacheMyAnimeListId(malId, forAniListId: anilistId, mediaType: "ANIME")
                    }

                    guard let anilistId = entry.anilistId else { continue }
                    if entriesByMediaId[anilistId] == nil {
                        guard orderedMediaIds.count < TrackerRemoteProgressBoundary.maximumRemoteEntryCount else {
                            throw NSError(domain: "AniList", code: -4, userInfo: [NSLocalizedDescriptionKey: "AniList anime list exceeded the supported entry limit."])
                        }
                        orderedMediaIds.append(anilistId)
                    }

                    entriesByMediaId[anilistId] = entry
                }
            }
            hasNextChunk = collection.hasNextChunk
            guard !hasNextChunk || chunk < TrackerRemoteProgressBoundary.maximumPageCount else {
                throw NSError(domain: "AniList", code: -4, userInfo: [NSLocalizedDescriptionKey: "AniList anime list returned an invalid continuation."])
            }
            chunk += 1
        }

        return orderedMediaIds.compactMap { entriesByMediaId[$0] }
    }

    private func fetchMALAnimeProgressEntries(
        account: TrackerAccount,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> [RemoteAnimeProgress] {
        var entries: [RemoteAnimeProgress] = []
        var nextURL: URL? = URL(string: "https://api.myanimelist.net/v2/users/@me/animelist?fields=list_status,num_episodes&limit=\(malListPageLimit)&nsfw=true")
        var seenPageURLs = Set<URL>()
        var pageCount = 0

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
            guard pageCount < TrackerRemoteProgressBoundary.maximumPageCount,
                  TrackerRemoteProgressBoundary.isAllowedMALPageURL(url),
                  seenPageURLs.insert(url).inserted else {
                throw NSError(domain: "MAL", code: -4, userInfo: [NSLocalizedDescriptionKey: "MAL anime list returned an invalid or repeated continuation."])
            }
            pageCount += 1
            var request = URLRequest(url: url)
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .myAnimeList,
                beforeAttempt: { [weak self] in
                    guard let requiredAuthority else { return }
                    guard let self,
                          await self.operationAuthorityIsCurrent(requiredAuthority) else {
                        throw CancellationError()
                    }
                }
            )
            guard response.statusCode == 200 else {
                let diagnostic = responseBodyPreview(from: data)
                throw NSError(domain: "MAL", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "MAL anime list fetch failed (\(response.statusCode)): \(diagnostic)"])
            }

            guard data.count <= 8 * 1_024 * 1_024 else {
                throw BoundedURLSessionError.responseTooLarge(maximumBytes: 8 * 1_024 * 1_024)
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard decoded.data.count <= TrackerRemoteProgressBoundary.maximumRemoteEntryCount,
                  decoded.data.count <= TrackerRemoteProgressBoundary.maximumRemoteEntryCount - entries.count else {
                throw NSError(domain: "MAL", code: -4, userInfo: [NSLocalizedDescriptionKey: "MAL anime list exceeded the supported entry limit."])
            }
            for item in decoded.data {
                guard let entry = RemoteAnimeProgress(
                    validatingAniListID: nil,
                    malID: item.node.id,
                    title: item.node.title,
                    status: item.listStatus?.status ?? "watching",
                    progress: item.listStatus?.numEpisodesWatched ?? 0,
                    totalEpisodes: item.node.numEpisodes
                ) else {
                    throw NSError(domain: "MAL", code: -4, userInfo: [NSLocalizedDescriptionKey: "MAL anime list contained unsupported numeric values."])
                }
                entries.append(entry)
            }
            if let rawNext = decoded.paging?.next {
                guard rawNext.utf8.count <= 8 * 1_024,
                      let parsedNext = URL(string: rawNext),
                      TrackerRemoteProgressBoundary.isAllowedMALPageURL(parsedNext),
                      !seenPageURLs.contains(parsedNext) else {
                    throw NSError(domain: "MAL", code: -4, userInfo: [NSLocalizedDescriptionKey: "MAL anime list returned an invalid continuation."])
                }
                nextURL = parsedNext
            } else {
                nextURL = nil
            }
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
    private func fetchAniListMangaProgressEntries(
        account: TrackerAccount,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> [RemoteMangaProgress] {
        let userId = try await resolvedAniListUserId(
            for: account,
            requiredAuthority: requiredAuthority
        )
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

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .anilist,
                beforeAttempt: { [weak self] in
                    guard let requiredAuthority else { return }
                    guard let self,
                          await self.operationAuthorityIsCurrent(requiredAuthority) else {
                        throw CancellationError()
                    }
                }
            )
            guard response.statusCode == 200 else {
                let message = aniListFailureDescription("AniList manga list fetch failed", response: response, data: data)
                Logger.shared.log(message, type: "Tracker")
                throw NSError(domain: "AniList", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let collection = decoded.data?.MediaListCollection else {
                let message = graphQLErrorMessage(from: data) != nil
                    ? "AniList manga list fetch failed: \(responseBodyPreview(from: data))"
                    : "AniList manga list fetch returned no collection data."
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
    }

    private func fetchMALMangaProgressEntries(
        account: TrackerAccount,
        requiredAuthority: TrackerOperationAuthority? = nil
    ) async throws -> [RemoteMangaProgress] {
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

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .myAnimeList,
                beforeAttempt: { [weak self] in
                    guard let requiredAuthority else { return }
                    guard let self,
                          await self.operationAuthorityIsCurrent(requiredAuthority) else {
                        throw CancellationError()
                    }
                }
            )
            guard response.statusCode == 200 else {
                let diagnostic = responseBodyPreview(from: data)
                throw NSError(domain: "MAL", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "MAL manga list fetch failed (\(response.statusCode)): \(diagnostic)"])
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

    private func fillEclipseFromRemoteAnime(
        _ entries: [RemoteAnimeProgress],
        sourceName: String,
        action: TrackerSyncToolAction,
        owner: UUID,
        requiredOperationGeneration: UInt64? = nil
    ) async throws -> TrackerSyncPreview {
        try Task.checkCancellation()
        let anilistIds = entries.compactMap { $0.anilistId }
        let tmdbMap = await AniListService.shared.mapAniListAnimeIdsToTMDBForImport(anilistIds, tmdbService: TMDBService.shared)
        try Task.checkCancellation()

        let counts = try await MainActor.run { () throws -> (added: Int, advanced: Int, unmapped: Int) in
            try self.requireOwner(owner, operationGeneration: requiredOperationGeneration)
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
                    ProgressManager.shared.bulkMarkEpisodesAsWatched(
                        showId: tmdb.id,
                        seasonNumber: 1,
                        throughEpisode: watched,
                        owner: owner
                    )
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

    private func fillMALAnimeCollectionsForLibraryImport(
        _ entries: [RemoteAnimeProgress],
        action: TrackerSyncToolAction,
        owner: UUID,
        requiredOperationGeneration: UInt64? = nil
    ) async throws -> TrackerSyncPreview {
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
            try self.requireOwner(owner, operationGeneration: requiredOperationGeneration)
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
                        throughEpisode: watched,
                        owner: owner
                    )
                    advanced += 1
                } else if tmdb.isMovie {
                    ProgressManager.shared.updateMovieProgress(
                        movieId: tmdb.id,
                        title: tmdb.displayTitle,
                        currentTime: 1,
                        totalDuration: 1,
                        posterURL: tmdb.fullPosterURL,
                        owner: owner
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

    private func fillEclipseFromRemoteManga(
        _ entries: [RemoteMangaProgress],
        sourceName: String,
        action: TrackerSyncToolAction,
        owner: UUID,
        requiredOperationGeneration: UInt64? = nil
    ) async throws -> TrackerSyncPreview {
        let counts = try await MainActor.run { () throws -> (advanced: Int, unmapped: Int) in
            try self.requireOwner(owner, operationGeneration: requiredOperationGeneration)
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
    }

    private func fillMALMangaCollectionsForLibraryImport(
        _ entries: [RemoteMangaProgress],
        action: TrackerSyncToolAction,
        owner: UUID,
        requiredOperationGeneration: UInt64? = nil
    ) async throws -> TrackerSyncPreview {
        let counts = try await MainActor.run { () throws -> (added: Int, unmapped: Int) in
            try self.requireOwner(owner, operationGeneration: requiredOperationGeneration)
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
#endif

    private func remoteWatchedEpisodes(_ entry: RemoteAnimeProgress) -> Int {
        TrackerRemoteProgressBoundary.watchedEpisodeCount(
            progress: entry.progress,
            totalEpisodes: entry.totalEpisodes,
            status: entry.status
        ) ?? 0
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

    private func saveAniListAnimeProgress(
        account: TrackerAccount,
        anilistId: Int,
        watchedEpisodes: Int,
        status: String,
        owner: UUID
    ) async {
        let authority = operationAuthority(for: account, owner: owner)
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

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .anilist,
                beforeAttempt: { [weak self] in
                    guard let self,
                          await self.operationAuthorityIsCurrent(authority) else {
                        throw CancellationError()
                    }
                }
            )
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
    private func saveAniListMangaProgress(
        account: TrackerAccount,
        anilistId: Int,
        chaptersRead: Int,
        status: String,
        owner: UUID
    ) async {
        let authority = operationAuthority(for: account, owner: owner)
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

            let (data, response) = try await sendTrackerRequest(
                request,
                provider: .anilist,
                beforeAttempt: { [weak self] in
                    guard let self,
                          await self.operationAuthorityIsCurrent(authority) else {
                        throw CancellationError()
                    }
                }
            )
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
        let owner = activeProfileID
        guard trackerProfileAcceptsOperations(owner) else {
            Logger.shared.log(
                "TrackerManager: refused to disconnect \(service.rawValue) while account cleanup owns tracker state",
                type: "Tracker"
            )
            return
        }
        _ = invalidateTrackerServiceAuthority(service, profileID: owner)
        if let authority = webAuthenticationAuthority,
           authority.owner == owner,
           authority.service == service {
#if !os(tvOS)
            webAuthSession?.cancel()
#endif
            finishAuthenticationAuthority(authority)
            isAuthenticating = false
        }
        if service == .trakt {
            traktTokenRefreshTasks[owner]?.task.cancel()
            traktTokenRefreshTasks[owner] = nil
            withTraktAuthenticationRequiredLatches {
                $0.clear(owner)
            }
            pendingTraktOAuthState = nil
        } else if service == .myAnimeList {
            malTokenRefreshTasks[owner]?.task.cancel()
            malTokenRefreshTasks[owner] = nil
            pendingMALCodeVerifier = nil
        }

        let deletionJournalWasPublished = markCredentialDeletionPending(
            service,
            profileID: owner
        )
        scrubPendingPersistenceForDisconnect(service, profileID: owner)
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
        let disconnectedStatePersisted = persistDisconnectedStateSynchronously(
            service: service,
            profileID: owner
        )
        let removal = removeTrackerCredentialOutcome(service, profileID: owner)
        if deletionJournalWasPublished
            || disconnectedStatePersisted
            || removal.deletionIsDurablyProtected {

            resolveUnpersistedCredentialDeletionAuthority(
                service,
                profileID: owner
            )
        } else {
            Logger.shared.log(
                "TrackerManager: \(service.rawValue) disconnect could not persist its journal or disconnected state and Keychain deletion failed; tracker operations remain fail-closed in this process",
                type: "Error"
            )
        }
        saveTrackerState(forProfile: owner)
        let matchingMessage = TrackerAuthenticationNotice(service: service).message
        if authenticationNotice?.service == service {
            authenticationNotice = nil
        }
        if authError == matchingMessage {
            authError = nil
        }
    }

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

        let owner = ProfileManager.shared.activeProfileID
        let authority = operationAuthority(for: account, owner: owner)

        guard !isImportingAniList else { return }

        isImportingAniList = true
        aniListImportError = nil
        aniListImportProgress = "Fetching your AniList library..."

        Task {
            var suppressesOutgoingSync = false
            defer {
                if suppressesOutgoingSync {
                    setBackupRestoreSyncSuppressed(false)
                }
            }

            do {
                let animeEntries = try await fetchAniListAnimeProgressEntries(
                    account: account,
                    requiredAuthority: authority
                )
#if os(tvOS)
                await MainActor.run {
                    aniListImportProgress = "Adding anime to Eclipse..."
                }

                guard await operationAuthorityIsCurrent(authority) else {
                    throw CancellationError()
                }
                setBackupRestoreSyncSuppressed(true)
                suppressesOutgoingSync = true
                let applyGeneration = trackerOperationGenerationSnapshot()
                let animeResult = try await fillEclipseFromRemoteAnime(
                    animeEntries,
                    sourceName: "AniList",
                    action: .fillEclipseFromAniList,
                    owner: owner,
                    requiredOperationGeneration: applyGeneration
                )
                let imported = animeResult.itemsToAdd + animeResult.itemsToAdvance

                await MainActor.run {
                    isImportingAniList = false
                    aniListImportProgress = nil
                    aniListImportError = nil
                    Logger.shared.log("AniList anime import completed: \(imported) local changes from \(animeEntries.count) entries", type: "Tracker")
                }
#else
                let mangaEntries = try await fetchAniListMangaProgressEntries(
                    account: account,
                    requiredAuthority: authority
                )

                await MainActor.run {
                    aniListImportProgress = "Adding items to Eclipse..."
                }

                guard await operationAuthorityIsCurrent(authority) else {
                    throw CancellationError()
                }
                setBackupRestoreSyncSuppressed(true)
                suppressesOutgoingSync = true
                let applyGeneration = trackerOperationGenerationSnapshot()
                let animeResult = try await fillEclipseFromRemoteAnime(
                    animeEntries,
                    sourceName: "AniList",
                    action: .fillEclipseFromAniList,
                    owner: owner,
                    requiredOperationGeneration: applyGeneration
                )
                let mangaResult = try await fillEclipseFromRemoteManga(
                    mangaEntries,
                    sourceName: "AniList",
                    action: .fillEclipseFromAniList,
                    owner: owner,
                    requiredOperationGeneration: applyGeneration
                )
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
        guard let account = trackerState.getAccount(for: .myAnimeList),
              account.isConnected else {
            malImportError = "No connected MAL account"
            return
        }

        let owner = ProfileManager.shared.activeProfileID
        let authority = operationAuthority(for: account, owner: owner)

        guard !isImportingMAL else { return }

        isImportingMAL = true
        malImportError = nil
        malImportProgress = "Fetching your MAL library..."

        Task {
            var suppressesOutgoingSync = false
            defer {
                if suppressesOutgoingSync {
                    setBackupRestoreSyncSuppressed(false)
                }
            }

            do {
                let refreshedAccount = try await refreshedMALAccountIfNeeded(
                    account,
                    requiredOwner: owner,
                    requiredAuthority: authority
                )
                let requestAuthority = authority.replacingCredential(with: refreshedAccount)
                let fetchedAnimeEntries = try await fetchMALAnimeProgressEntries(
                    account: refreshedAccount,
                    requiredAuthority: requestAuthority
                )
#if os(tvOS)
                await MainActor.run {
                    malImportProgress = "Matching MAL anime to app collections..."
                }

                let animeEntries = await resolveMALAnimeEntriesToAniList(fetchedAnimeEntries)
                let mappedAnimeCount = animeEntries.filter { $0.anilistId != nil }.count

                await MainActor.run {
                    malImportProgress = "Adding \(mappedAnimeCount) anime entries to app collections..."
                }

                guard await operationAuthorityIsCurrent(requestAuthority) else {
                    throw CancellationError()
                }
                setBackupRestoreSyncSuppressed(true)
                suppressesOutgoingSync = true
                let applyGeneration = trackerOperationGenerationSnapshot()
                let animeResult = try await fillMALAnimeCollectionsForLibraryImport(
                    animeEntries,
                    action: .fillEclipseFromMAL,
                    owner: owner,
                    requiredOperationGeneration: applyGeneration
                )
                let imported = animeResult.itemsToAdd + animeResult.itemsToAdvance

                await MainActor.run {
                    isImportingMAL = false
                    malImportProgress = nil
                    malImportError = nil
                    Logger.shared.log("MAL anime import completed: \(imported) local changes from \(animeEntries.count) entries", type: "Tracker")
                }
#else
                let fetchedMangaEntries = try await fetchMALMangaProgressEntries(
                    account: refreshedAccount,
                    requiredAuthority: requestAuthority
                )

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

                guard await operationAuthorityIsCurrent(requestAuthority) else {
                    throw CancellationError()
                }
                setBackupRestoreSyncSuppressed(true)
                suppressesOutgoingSync = true
                let applyGeneration = trackerOperationGenerationSnapshot()
                let animeResult = try await fillMALAnimeCollectionsForLibraryImport(
                    animeEntries,
                    action: .fillEclipseFromMAL,
                    owner: owner,
                    requiredOperationGeneration: applyGeneration
                )
                let mangaCollectionResult = try await fillMALMangaCollectionsForLibraryImport(
                    mangaEntries,
                    action: .fillEclipseFromMAL,
                    owner: owner,
                    requiredOperationGeneration: applyGeneration
                )
                let mangaResult = try await fillEclipseFromRemoteManga(
                    mangaEntries,
                    sourceName: "MAL",
                    action: .fillEclipseFromMAL,
                    owner: owner,
                    requiredOperationGeneration: applyGeneration
                )
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

    static let traktWatchlistCollectionName = "Trakt Watchlist"

    func pushTraktWatchlistChange(searchResult: TMDBSearchResult, added: Bool) {
        let owner = ProfileManager.shared.activeProfileID
        guard trackerState.syncEnabled,
              trackerState.traktWatchlistSync,
              !isBackupRestoreSyncSuppressed(),
              let account = trackerState.getAccount(for: .trakt),
              searchResult.id > 0 else { return }

        let mediaKey = searchResult.isMovie ? "movies" : "shows"
        let tmdbId = searchResult.id
        let path = added ? "sync/watchlist" : "sync/watchlist/remove"
        let payload: [String: Any] = [mediaKey: [["ids": ["tmdb": tmdbId]]]]
        let authority = operationAuthority(for: account, owner: owner)

        Task {
            do {
                let refreshedAccount = try await refreshedTraktAccountIfNeeded(
                    account,
                    requiredOwner: owner,
                    requiredAuthority: authority
                )
                guard refreshedAccount.userId == account.userId else {
                    Logger.shared.log("Skipped Trakt watchlist \(added ? "add" : "remove") tmdb=\(tmdbId); the connected account changed while it was queued", type: "Tracker")
                    return
                }
                _ = try await postTraktJSON(
                    path: path,
                    account: refreshedAccount,
                    payload: payload,
                    owner: owner,
                    requiredAuthority: authority.replacingCredential(with: refreshedAccount)
                )
                Logger.shared.log("Trakt watchlist \(added ? "add" : "remove") tmdb=\(tmdbId) type=\(mediaKey)", type: "Tracker")
            } catch {
                Logger.shared.log("Failed Trakt watchlist \(added ? "add" : "remove") tmdb=\(tmdbId): \(error.localizedDescription)", type: "Error")
            }
        }
    }

    func refreshTraktWatchlistCollection() {
        guard trackerState.syncEnabled,
              trackerState.traktWatchlistSync,
              let account = trackerState.getAccount(for: .trakt) else { return }

        let owner = ProfileManager.shared.activeProfileID
        let authority = operationAuthority(for: account, owner: owner)

        Task {
            do {
                let refreshedAccount = try await refreshedTraktAccountIfNeeded(
                    account,
                    requiredOwner: owner,
                    requiredAuthority: authority
                )
                let requestAuthority = authority.replacingCredential(with: refreshedAccount)
                async let showPages = fetchAllTraktPages(
                    path: "users/me/watchlist/shows?extended=full",
                    account: refreshedAccount,
                    owner: owner,
                    requiredAuthority: requestAuthority
                )
                async let moviePages = fetchAllTraktPages(
                    path: "users/me/watchlist/movies?extended=full",
                    account: refreshedAccount,
                    owner: owner,
                    requiredAuthority: requestAuthority
                )
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
                guard await operationAuthorityIsCurrent(requestAuthority) else {
                    throw CancellationError()
                }
                try await MainActor.run {
                    try self.requireOwner(owner)
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

        let owner = ProfileManager.shared.activeProfileID
        let authority = operationAuthority(for: account, owner: owner)

        guard !isImportingTrakt else { return }

        isImportingTrakt = true
        traktImportError = nil
        traktImportProgress = "Fetching your Trakt library..."

        Task {
            var suppressesOutgoingSync = false
            defer {
                if suppressesOutgoingSync {
                    setBackupRestoreSyncSuppressed(false)
                }
            }

            do {
                let refreshedAccount = try await refreshedTraktAccountIfNeeded(
                    account,
                    requiredOwner: owner,
                    requiredAuthority: authority
                )
                let requestAuthority = authority.replacingCredential(with: refreshedAccount)
                async let watchlistShowPages = fetchAllTraktPages(
                    path: "users/me/watchlist/shows?extended=full",
                    account: refreshedAccount,
                    owner: owner,
                    requiredAuthority: requestAuthority
                )
                async let watchlistMoviePages = fetchAllTraktPages(
                    path: "users/me/watchlist/movies?extended=full",
                    account: refreshedAccount,
                    owner: owner,
                    requiredAuthority: requestAuthority
                )
                async let watchedShowData = fetchTraktPlaybackData(
                    path: "users/me/watched/shows",
                    account: refreshedAccount,
                    owner: owner,
                    requiredAuthority: requestAuthority
                )
                async let watchedMovieData = fetchTraktPlaybackData(
                    path: "users/me/watched/movies",
                    account: refreshedAccount,
                    owner: owner,
                    requiredAuthority: requestAuthority
                )
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
                guard await operationAuthorityIsCurrent(requestAuthority) else {
                    throw CancellationError()
                }
                setBackupRestoreSyncSuppressed(true)
                suppressesOutgoingSync = true
                let applyGeneration = trackerOperationGenerationSnapshot()
                let counts = try await MainActor.run { () throws -> (added: Int, advanced: Int, skipped: Int) in
                    try self.requireOwner(owner, operationGeneration: applyGeneration)
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
                        let remoteSeasons = entry.seasons ?? []
                        guard remoteSeasons.count <= ProgressPersistencePolicy.maximumBulkEpisodeMutationCount,
                              let watchedEpisodeCount = RemoteMediaNumericBoundary.boundedSum(
                                remoteSeasons.map { $0.episodes.count },
                                maximum: ProgressPersistencePolicy.maximumBulkEpisodeMutationCount
                              ) else {
                            skipped += 1
                            continue
                        }
                        let safeAiredEpisodeCount = entry.show.airedEpisodes.flatMap {
                            (0...ProgressPersistencePolicy.maximumBulkEpisodeMutationCount).contains($0)
                                ? $0
                                : nil
                        }
                        let collectionName = (safeAiredEpisodeCount ?? 0) > 0
                            && watchedEpisodeCount >= (safeAiredEpisodeCount ?? 0)
                            ? "Trakt Completed"
                            : "Trakt Watching"
                        add(result, to: collectionName)

                        var didAdvance = false
                        for season in remoteSeasons {
                            let watchedEpisodes = season.episodes.map(\.number)
                            guard ProgressPersistencePolicy.exactEpisodeMutationNumbers(
                                showID: tmdbId,
                                seasonNumber: season.number,
                                episodeNumbers: watchedEpisodes
                            ) != nil else { continue }
                            ProgressManager.shared.bulkMarkEpisodeNumbersAsWatched(
                                showId: tmdbId,
                                seasonNumber: season.number,
                                episodeNumbers: watchedEpisodes,
                                owner: owner
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
                            posterURL: result.fullPosterURL,
                            owner: owner
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
