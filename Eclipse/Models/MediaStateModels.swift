import Foundation

enum MediaStateKind: String, Codable, CaseIterable, Sendable {
    case libraryCollection
    case libraryMembership
    case movieProgress
    case episodeProgress
    case showMetadata
    case hiddenUpNext
    case rating
    case setting
    case catalogOrder
}

enum MediaStateSettingScope: String, Codable, Sendable {
    case shared
    case iOS
    case tvOS

    var appliesToCurrentPlatform: Bool {
        switch self {
        case .shared:
            return true
        case .iOS:
#if os(iOS)
            return true
#else
            return false
#endif
        case .tvOS:
#if os(tvOS)
            return true
#else
            return false
#endif
        }
    }
}

struct MediaStateEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let recordName: String
    let kind: MediaStateKind
    var payload: Data
    var modifiedAt: Date
    var deletedAt: Date?
    var revision: Int64
    var settingScope: MediaStateSettingScope
    var isCompleted: Bool
    var isExplicitReset: Bool
    var schemaVersion: Int
    var systemFields: Data?

    init(
        recordName: String,
        kind: MediaStateKind,
        payload: Data,
        modifiedAt: Date,
        deletedAt: Date? = nil,
        revision: Int64 = 1,
        settingScope: MediaStateSettingScope = .shared,
        isCompleted: Bool = false,
        isExplicitReset: Bool = false,
        schemaVersion: Int = MediaStateEnvelope.schemaVersion,
        systemFields: Data? = nil
    ) {
        self.recordName = recordName
        self.kind = kind
        self.payload = payload
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
        self.revision = revision
        self.settingScope = settingScope
        self.isCompleted = isCompleted
        self.isExplicitReset = isExplicitReset
        self.schemaVersion = schemaVersion
        self.systemFields = systemFields
    }

    var isDeleted: Bool { deletedAt != nil }

    func merged(with candidate: MediaStateEnvelope) -> MediaStateEnvelope {
        guard recordName == candidate.recordName, kind == candidate.kind else {
            return candidate.modifiedAt >= modifiedAt ? candidate : self
        }

        if isDeleted || candidate.isDeleted {
            let lhsDate = deletedAt ?? modifiedAt
            let rhsDate = candidate.deletedAt ?? candidate.modifiedAt
            return rhsDate >= lhsDate ? candidate : self
        }

        if kind == .movieProgress || kind == .episodeProgress {
            if candidate.isExplicitReset, candidate.modifiedAt >= modifiedAt {
                return candidate
            }
            if isExplicitReset, modifiedAt >= candidate.modifiedAt {
                return self
            }
            if isCompleted != candidate.isCompleted {
                return isCompleted ? self : candidate
            }
        }

        if candidate.modifiedAt == modifiedAt {
            return candidate.revision >= revision ? candidate : self
        }
        return candidate.modifiedAt > modifiedAt ? candidate : self
    }

    func tombstone(at date: Date = Date()) -> MediaStateEnvelope {
        var result = self
        result.payload = Data()
        result.modifiedAt = date
        result.deletedAt = date
        result.revision += 1
        result.isCompleted = false
        result.isExplicitReset = false
        return result
    }
}

struct MediaStateLocalArchive: Codable, Sendable {
    var records: [String: MediaStateEnvelope]
    var lastLocalRecordNames: Set<String>
    /// CloudKit current-user record name that owns this cache. Optional keeps
    /// archives written before account isolation backward compatible.
    var accountOwnerRecordName: String? = nil
    /// Archived `FileManager.ubiquityIdentityToken` for an early launch-time
    /// stale-cache veto. CloudKit's current-user record ID remains the
    /// authority for selecting an account and enabling writes.
    var ubiquityIdentityTokenData: Data? = nil
    /// Local edits that have not yet been acknowledged by CloudKit. Persisting
    /// this journal keeps an offline edit pending across termination instead of
    /// relying on CKSyncEngine's in-memory pending-change queue.
    var pendingLocalRecordNames: Set<String> = []
    /// The globally persisted managers have already been cleared at an account
    /// boundary and now contain signed-out/unverified local edits. Keeping this
    /// bit beside the quarantined owned archive prevents every offline relaunch
    /// from clearing those local edits again.
    var isAccountNeutralLocalStateActive = false

    init(
        records: [String: MediaStateEnvelope],
        lastLocalRecordNames: Set<String>,
        accountOwnerRecordName: String? = nil,
        ubiquityIdentityTokenData: Data? = nil,
        pendingLocalRecordNames: Set<String> = [],
        isAccountNeutralLocalStateActive: Bool = false
    ) {
        self.records = records
        self.lastLocalRecordNames = lastLocalRecordNames
        self.accountOwnerRecordName = accountOwnerRecordName
        self.ubiquityIdentityTokenData = ubiquityIdentityTokenData
        self.pendingLocalRecordNames = pendingLocalRecordNames
        self.isAccountNeutralLocalStateActive = isAccountNeutralLocalStateActive
    }

    private enum CodingKeys: String, CodingKey {
        case records
        case lastLocalRecordNames
        case accountOwnerRecordName
        case ubiquityIdentityTokenData
        case pendingLocalRecordNames
        case isAccountNeutralLocalStateActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decode([String: MediaStateEnvelope].self, forKey: .records)
        lastLocalRecordNames = try container.decode(Set<String>.self, forKey: .lastLocalRecordNames)
        accountOwnerRecordName = try container.decodeIfPresent(String.self, forKey: .accountOwnerRecordName)
        ubiquityIdentityTokenData = try container.decodeIfPresent(Data.self, forKey: .ubiquityIdentityTokenData)
        pendingLocalRecordNames = try container.decodeIfPresent(Set<String>.self, forKey: .pendingLocalRecordNames) ?? []
        isAccountNeutralLocalStateActive = try container.decodeIfPresent(
            Bool.self,
            forKey: .isAccountNeutralLocalStateActive
        ) ?? false
    }

    static let empty = MediaStateLocalArchive(
        records: [:],
        lastLocalRecordNames: [],
        accountOwnerRecordName: nil,
        ubiquityIdentityTokenData: nil,
        pendingLocalRecordNames: [],
        isAccountNeutralLocalStateActive: false
    )
}

struct MediaStateInitialMergeResult: Equatable, Sendable {
    let records: [String: MediaStateEnvelope]
    let pendingRecordNames: [String]
}

/// Controls whether an initial CloudKit fetch may seed the private database
/// from the state currently loaded by the app.
///
/// A normal launch/sign-in deliberately migrates local media state. A direct
/// account switch must not do that: the managers still contain the outgoing
/// account's library and preferences until the incoming account is restored.
enum MediaStateInitialLocalStatePolicy: Equatable, Sendable {
    case migrateLocalState
    case isolateIncomingAccount
}

/// Removes records known to be untouched product defaults from a first local
/// migration. Explicitly persisted/customized records are not value-compared
/// with defaults: choosing a default value can itself be a user preference.
enum MediaStateLocalMigrationPolicy {
    static func recordsEligibleForMigration(
        localSnapshot: [String: MediaStateEnvelope],
        defaultRecordNames: Set<String>
    ) -> [String: MediaStateEnvelope] {
        localSnapshot.filter { !defaultRecordNames.contains($0.key) }
    }

    static func shouldSuppressNewRecord(
        named recordName: String,
        suppressedDefaultRecordNames: Set<String>,
        currentDefaultRecordNames: Set<String>
    ) -> Bool {
        suppressedDefaultRecordNames.contains(recordName) &&
            currentDefaultRecordNames.contains(recordName)
    }

    /// A remote tombstone remains authoritative while the local manager only
    /// exposes an untouched registered/product default. Once the user
    /// explicitly persists a value, it is no longer in
    /// `currentDefaultRecordNames` and may intentionally recreate the record.
    static func shouldSuppressTombstoneResurrection(
        named recordName: String,
        currentDefaultRecordNames: Set<String>
    ) -> Bool {
        currentDefaultRecordNames.contains(recordName)
    }
}

/// Distinguishes a genuinely absent collection domain from an authoritative
/// snapshot whose final collection definitions are all tombstones.
enum MediaStateLibraryRestorePolicy {
    static func hasCollectionDefinitionHistory(
        in records: [MediaStateEnvelope]
    ) -> Bool {
        records.contains { $0.kind == .libraryCollection }
    }
}

/// Catalog defaults need the same tombstone authority as collection defaults:
/// no history means "leave local state alone," while deleted/malformed history
/// means restore the neutral catalog baseline instead of re-uploading stale UI.
enum MediaStateCatalogRestorePolicy {
    static func hasCatalogOrderHistory(
        in records: [MediaStateEnvelope]
    ) -> Bool {
        records.contains { $0.kind == .catalogOrder }
    }
}

/// Pure identity decision used by the CKSyncEngine account-change handler.
/// Signed-out edits can return to the same account, but never cross into a
/// different known private database.
enum MediaStateAccountTransitionPolicy {
    static func signInPolicy(
        lastKnownAccountRecordName: String?,
        currentAccountRecordName: String,
        requiresIsolation: Bool
    ) -> MediaStateInitialLocalStatePolicy {
        if requiresIsolation {
            return .isolateIncomingAccount
        }
        guard let lastKnownAccountRecordName else {
            return .migrateLocalState
        }
        return lastKnownAccountRecordName == currentAccountRecordName
            ? .migrateLocalState
            : .isolateIncomingAccount
    }
}

/// Launch-time cache decisions use the local ubiquity token only as negative
/// evidence. A matching token may restore an already account-owned cache while
/// offline; CloudKit's user-record ID is still required before an engine or
/// upload can be created.
enum MediaStateLaunchIdentityEvidence: Equatable, Sendable {
    case sameAccount
    case differentAccountOrSignedOut
    case unavailable
}

enum MediaStateLaunchCacheAction: Equatable, Sendable {
    case restoreOwnedCache
    case isolateLoadedState
    case awaitCloudKitVerification
}

enum MediaStateLaunchCachePolicy {
    static func action(
        hasAccountOwner: Bool,
        evidence: MediaStateLaunchIdentityEvidence
    ) -> MediaStateLaunchCacheAction {
        guard hasAccountOwner else {
            return .awaitCloudKitVerification
        }
        switch evidence {
        case .sameAccount:
            return .restoreOwnedCache
        case .differentAccountOrSignedOut:
            return .isolateLoadedState
        case .unavailable:
            // A known owner's globally persisted manager files are scoped to
            // that same account too. Without matching local identity evidence,
            // fail closed until CloudKit verifies the owner.
            return .isolateLoadedState
        }
    }
}

/// Tiny testable counter used by the process-wide playback lease. `end()`
/// returns true only for the transition from one active session to none.
struct MediaStatePlaybackLeaseCounter: Equatable, Sendable {
    private(set) var activeSessionCount = 0

    mutating func begin() {
        activeSessionCount += 1
    }

    @discardableResult
    mutating func end() -> Bool {
        guard activeSessionCount > 0 else { return false }
        activeSessionCount -= 1
        return activeSessionCount == 0
    }
}

/// First-sync policy that treats an absent local record as "not cached yet",
/// never as a deletion. Only explicit tombstones can remove remote state.
enum MediaStateInitialMergePolicy {
    static func merge(
        fetchedRecords: [String: MediaStateEnvelope],
        localSnapshot: [String: MediaStateEnvelope],
        localStatePolicy: MediaStateInitialLocalStatePolicy = .migrateLocalState
    ) -> MediaStateInitialMergeResult {
        // During a direct account switch, `localSnapshot` still represents the
        // outgoing private database. Returning the fetched records verbatim is
        // the upload boundary: no outgoing record may become a pending save in
        // the incoming account, including when that account is empty.
        guard localStatePolicy == .migrateLocalState else {
            return MediaStateInitialMergeResult(
                records: fetchedRecords,
                pendingRecordNames: []
            )
        }

        var records = fetchedRecords
        var pendingRecordNames: [String] = []

        for (recordName, localEnvelope) in localSnapshot {
            if let fetchedEnvelope = records[recordName] {
                var merged = fetchedEnvelope.merged(with: localEnvelope)
                merged.systemFields = fetchedEnvelope.systemFields
                records[recordName] = merged
                if merged == localEnvelope, merged != fetchedEnvelope {
                    pendingRecordNames.append(recordName)
                }
            } else {
                records[recordName] = localEnvelope
                pendingRecordNames.append(recordName)
            }
        }

        return MediaStateInitialMergeResult(
            records: records,
            pendingRecordNames: pendingRecordNames.sorted()
        )
    }
}

enum MediaStateSyncPhase: Equatable, Sendable {
    case idle
    case checkingAccount
    case fetching
    case ready
    case localOnly(String)

    var title: String {
        switch self {
        case .idle: return "Not Started"
        case .checkingAccount: return "Checking iCloud"
        case .fetching: return "Restoring Media State"
        case .ready: return "Synced with iCloud"
        case .localOnly: return "Using Local State"
        }
    }

    var message: String {
        switch self {
        case .idle:
            return "Media state sync has not started."
        case .checkingAccount:
            return "Checking the signed-in iCloud account."
        case .fetching:
            return "Fetching remote state before this device is allowed to upload changes."
        case .ready:
            return "Library, progress, ratings, and safe settings are current."
        case .localOnly(let reason):
            return reason
        }
    }
}

enum MediaStateRecordName {
    static func make(kind: MediaStateKind, identifier: String) -> String {
        let safeIdentifier = identifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "#", with: "_")
        return "\(kind.rawValue)|\(safeIdentifier)"
    }

    static func identifier(from recordName: String) -> String? {
        guard let separator = recordName.firstIndex(of: "|") else { return nil }
        return String(recordName[recordName.index(after: separator)...])
    }
}

enum MediaStateSettingRegistry {
    private static let sharedKeys: Set<String> = [
        "tmdbLanguage",
        "enableSubtitlesByDefault",
        "defaultSubtitleLanguage",
        "preferredAutoAudioLanguage",
        "preferredAnimeAudioLanguage",
        "defaultPlaybackSpeed",
        "playerOpenSubtitlesEnabled",
        "playerOpenSubtitlesAutoFallbackEnabled",
        "playerSubtitleAppearanceEnabled",
        "audioComfortMode",
        "audioComfortScopeCategories",
        "mpvSurroundSoundEnabled",
        "watchTogetherEnabled",
        "mpvPictureInPictureEnabled",
        "introDBEnabled",
        "introDBAppEnabled",
        "aniSkipAutoSkip",
        "showNextEpisodeButton",
        "showPlayerServicesButton",
        "nextEpisodeThreshold",
        "servicesAutoModeEnabled",
        "servicesAutoSelectEpisodesEnabled",
        "servicesAutoModeQualityPreference",
        "servicesAutoModeSourceIds",
        "servicesAutoModeSourceOrderIds",
        "servicesIncludedStreamLanguages",
        "servicesHiddenStreamLanguages",
        "servicesHideStreamsWithoutLanguageData",
        "servicesHiddenStreamQualities",
        "servicesHideStreamsWithoutDetectedQuality",
        "servicesExtraRulesSourceIds",
        "mediaDetailElementOrder",
        "mediaDetailHiddenElements",
        "mediaDetailSimilarTitlesEnabled",
        "mediaDetailTitleArtworkEnabled",
        "homeCatalogLayoutOverrides",
        "appearancePalette",
        "appearanceBleedStrength",
        "appearanceBackgroundIntensity",
        "appearanceMotion",
        "atmosphereStyle",
        "homeAnimatedBackgroundEnabled",
        "homeAnimatedBackgroundQuality",
        "homeAnimatedBackgroundFrameRate",
        "mpvPlayerSkinTintControlsOnly",
        "experimentalMediaDesignPreset",
        "experimentalHomeCardShape",
        "experimentalHeroHeightScale",
        "experimentalSectionSpacingScale",
        "experimentalCardRadiusScale",
        "experimentalMediaCardScale",
        "heroBannerCatalogId",
        "heroBannerBehavior",
        "subtitles_fontSize",
        "subtitles_strokeWidth",
        "subtitles_foregroundColor",
        "subtitles_strokeColor",
        "subtitles_closedCaptionBackground",
        "playerSubtitleOverlayBottomConstant",
        "performanceModeEnabled",
        "performanceModeSkipAniListTraversalForAnimeDetails",
        "performanceModeFastAnimeCatalogOverrides"
    ]

    private static let tvOSKeys: Set<String> = [
        "tvCardDensity",
        "playbackEngine",
        "playerDoubleTapSeekSeconds",
        "tvServicesActiveSourceIds",
        "tvOSServiceSourceActivationOverrides"
    ]

    private static let iOSKeys: Set<String> = [
        // The followed-show list is user intent and should move between the
        // user's iPhone/iPad devices. Authorization and UNNotificationRequest
        // instances remain device-local inside LocalNotificationManager.
        "localNotificationSubscriptions"
    ]

    static var allKeys: Set<String> { sharedKeys.union(tvOSKeys).union(iOSKeys) }

    static func scope(for key: String) -> MediaStateSettingScope? {
        if sharedKeys.contains(key) { return .shared }
        if tvOSKeys.contains(key) { return .tvOS }
        if iOSKeys.contains(key) { return .iOS }
        return nil
    }
}

/// Applies both live setting records and remote tombstones. Keeping this in a
/// small, testable seam prevents a deleted remote preference from surviving in
/// UserDefaults and being uploaded again during the next local capture.
enum MediaStateSettingRestorePolicy {
    static func apply(
        records: [MediaStateEnvelope],
        to defaults: UserDefaults
    ) {
        for envelope in records where envelope.kind == .setting {
            guard envelope.settingScope.appliesToCurrentPlatform,
                  let key = MediaStateRecordName.identifier(from: envelope.recordName),
                  MediaStateSettingRegistry.scope(for: key) == envelope.settingScope else {
                continue
            }

            if envelope.isDeleted {
                defaults.removeObject(forKey: key)
                continue
            }

            guard let value = try? PropertyListSerialization.propertyList(
                from: envelope.payload,
                options: [],
                format: nil
            ) else {
                continue
            }
            defaults.set(value, forKey: key)
        }
    }
}

/// Captures the explicitly persisted settings owned by the media-state store.
///
/// Legacy iCloud snapshots still restore reader data on iPhone/iPad. They must
/// not turn their historical streaming preferences into new CKSyncEngine
/// revisions, including on a first launch where the media archive has not been
/// fetched yet. Keeping missing keys distinct from registered defaults is
/// important: an old snapshot must not make an untouched default explicit.
struct MediaStateLegacyRestoreSettingSnapshot {
    private let persistedValues: [String: Any]
    private let missingKeys: Set<String>

    init(persistentDomain: [String: Any]) {
        let applicableKeys = Set(MediaStateSettingRegistry.allKeys.filter {
            MediaStateSettingRegistry.scope(for: $0)?.appliesToCurrentPlatform == true
        })
        persistedValues = persistentDomain.filter { applicableKeys.contains($0.key) }
        missingKeys = applicableKeys.subtracting(persistedValues.keys)
    }

    func restore(to defaults: UserDefaults) {
        for key in missingKeys {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in persistedValues {
            defaults.set(value, forKey: key)
        }
    }
}

extension Notification.Name {
    static let libraryDataDidChange = Notification.Name("libraryDataDidChange")
    static let userRatingDataDidChange = Notification.Name("userRatingDataDidChange")
    static let catalogDataDidChange = Notification.Name("catalogDataDidChange")
    static let mediaStateDidRestore = Notification.Name("mediaStateDidRestore")
    static let mediaStatePlaybackLeaseDidEnd = Notification.Name("mediaStatePlaybackLeaseDidEnd")
    /// Posted synchronously before a CloudKit account boundary mutates any live media state.
    static let mediaStateWillChangeCurrentUser = Notification.Name("mediaStateWillChangeCurrentUser")
}

enum MediaStateAccountPlaybackBoundary {
    /// NotificationCenter delivery is synchronous for same-queue observers. Keeping the post in a
    /// tiny testable seam guarantees active playback can stop and persist its final outgoing-user
    /// position before the sync manager installs the incoming user's neutral/fetched state.
    static func notifyWillChangeUser(
        notificationCenter: NotificationCenter = .default,
        sender: Any? = nil
    ) {
        notificationCenter.post(
            name: .mediaStateWillChangeCurrentUser,
            object: sender
        )
    }
}
