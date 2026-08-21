import Combine
import CryptoKit
import Foundation

struct Profile: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String

    var avatarSymbol: String

    var avatarColorHex: String

    var avatarPhotoData: Data?

    var pinHash: String?
    var isKidsProfile: Bool
    var createdAt: Date

    var pinChangedAt: Date?
    var kidsFlagChangedAt: Date?

    var hasRejectedPINHash = false

    init(
        id: UUID = UUID(),
        name: String,
        avatarSymbol: String = ProfileAvatar.defaultSymbol,
        avatarColorHex: String = ProfileAvatar.defaultColorHex,
        avatarPhotoData: Data? = nil,
        pinHash: String? = nil,
        isKidsProfile: Bool = false,
        createdAt: Date = Date(),
        pinChangedAt: Date? = nil,
        kidsFlagChangedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarSymbol = avatarSymbol
        self.avatarColorHex = avatarColorHex
        self.avatarPhotoData = avatarPhotoData
        let sanitizedPINHash = ProfilePINHasher.sanitizedHash(pinHash)
        self.pinHash = sanitizedPINHash
        self.isKidsProfile = isKidsProfile
        self.createdAt = createdAt
        self.pinChangedAt = pinHash != nil && sanitizedPINHash == nil ? nil : pinChangedAt
        self.kidsFlagChangedAt = kidsFlagChangedAt
        self.hasRejectedPINHash = pinHash != nil && sanitizedPINHash == nil
    }

    var isLocked: Bool {
        guard let pinHash else { return false }
        return ProfilePINHasher.sanitizedHash(pinHash) != nil
    }

    func applyingSyncedRecord(_ remote: Profile) -> Profile {
        guard remote.id == id else { return remote }
        var merged = remote

        let localPINStamp = pinChangedAt ?? .distantPast
        let remotePINStamp = remote.pinChangedAt ?? .distantPast
        if remote.hasRejectedPINHash || localPINStamp > remotePINStamp ||
            (localPINStamp == remotePINStamp && isLocked && !remote.isLocked) {
            merged.pinHash = pinHash
            merged.pinChangedAt = pinChangedAt
            merged.hasRejectedPINHash = hasRejectedPINHash
        }

        let localKidsStamp = kidsFlagChangedAt ?? .distantPast
        let remoteKidsStamp = remote.kidsFlagChangedAt ?? .distantPast
        if localKidsStamp > remoteKidsStamp ||
            (localKidsStamp == remoteKidsStamp && isKidsProfile && !remote.isKidsProfile) {
            merged.isKidsProfile = isKidsProfile
            merged.kidsFlagChangedAt = kidsFlagChangedAt
        }

        return merged
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, avatarSymbol, avatarColorHex, avatarPhotoData
        case pinHash, isKidsProfile, createdAt
        case pinChangedAt, kidsFlagChangedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        avatarSymbol = try container.decodeIfPresent(String.self, forKey: .avatarSymbol)
            ?? ProfileAvatar.defaultSymbol
        avatarColorHex = try container.decodeIfPresent(String.self, forKey: .avatarColorHex)
            ?? ProfileAvatar.defaultColorHex
        avatarPhotoData = try container.decodeIfPresent(Data.self, forKey: .avatarPhotoData)

        let storedPINHash = try container.decodeIfPresent(String.self, forKey: .pinHash)
        pinHash = ProfilePINHasher.sanitizedHash(storedPINHash)
        hasRejectedPINHash = storedPINHash != nil && pinHash == nil
        isKidsProfile = try container.decodeIfPresent(Bool.self, forKey: .isKidsProfile) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        let decodedPINChangedAt = try container.decodeIfPresent(Date.self, forKey: .pinChangedAt)
        pinChangedAt = hasRejectedPINHash ? nil : decodedPINChangedAt
        kidsFlagChangedAt = try container.decodeIfPresent(Date.self, forKey: .kidsFlagChangedAt)
    }
}

enum ProfileAvatar {
    static let defaultSymbol = "theatermasks.fill"
    static let defaultColorHex = "#5E8BFF"

    static let symbols: [String] = [
        "theatermasks.fill",
        "film.fill",
        "ticket.fill",
        "square.stack.3d.up.fill",
        "character.book.closed.fill",
        "books.vertical.fill",
        "bookmark.fill",
        "scroll.fill",
        "text.bubble.fill",
        "paintbrush.pointed.fill",
        "crown.fill",
        "flame.fill",
        "wand.and.stars",
        "eye.fill",
        "headphones",
        "globe.asia.australia.fill"
    ]

    static let colorHexes: [String] = [
        "#5E8BFF",
        "#E14D5A",
        "#D57C10",
        "#12A39C",
        "#22A855",
        "#A55BEF",
        "#EE5AA8",
        "#5A6B8F"
    ]

    static let maximumPhotoBytes = 96 * 1024
}

enum ProfilePINHasher {
    static let pinLength = 4

    private static let digestHexLength = 64
    private static let saltHexLength = 32
    private static let acceptedHashCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 64
        return cache
    }()

    static func isValid(pin: String) -> Bool {
        let bytes = Array(pin.utf8)
        return bytes.count == pinLength && bytes.allSatisfy { (48...57).contains($0) }
    }

    static func isWellFormedHash(_ hash: String) -> Bool {
        let parts = hash.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == saltHexLength,
              isLowercaseHex(parts[0]) else { return false }
        return parts[1].count == digestHexLength && isLowercaseHex(parts[1])
    }

    static func sanitizedHash(_ hash: String?) -> String? {
        guard let hash, isWellFormedHash(hash), belongsToAcceptedPIN(hash) else { return nil }
        return hash
    }

    private static func belongsToAcceptedPIN(_ hash: String) -> Bool {
        let cacheKey = hash as NSString
        if let cached = acceptedHashCache.object(forKey: cacheKey) {
            return cached.boolValue
        }
        let parts = hash.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let salt = data(fromHex: String(parts[0])),
              let expected = data(fromHex: String(parts[1])) else {
            acceptedHashCache.setObject(NSNumber(value: false), forKey: cacheKey)
            return false
        }

        let expectedBytes = Array(expected)
        var candidate = Array(salt) + [UInt8](repeating: 0, count: pinLength)
        let pinOffset = candidate.count - pinLength
        var isAccepted = false
        for value in 0...9_999 {
            var remainder = value
            for offset in stride(from: candidate.count - 1, through: pinOffset, by: -1) {
                candidate[offset] = UInt8(48 + remainder % 10)
                remainder /= 10
            }
            if constantTimeEqual(Array(SHA256.hash(data: candidate)), expectedBytes) {
                isAccepted = true
                break
            }
        }
        acceptedHashCache.setObject(NSNumber(value: isAccepted), forKey: cacheKey)
        return isAccepted
    }

    private static func isLowercaseHex(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    static func makeHash(for pin: String) -> String? {
        guard isValid(pin: pin) else { return nil }
        var saltBytes = [UInt8](repeating: 0, count: 16)
        for index in saltBytes.indices {
            saltBytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        let salt = Data(saltBytes)
        let hash = "\(hexString(salt)):\(digest(pin: pin, salt: salt))"
        acceptedHashCache.setObject(NSNumber(value: true), forKey: hash as NSString)
        return hash
    }

    static func verify(pin: String, against storedHash: String) -> Bool {
        guard isValid(pin: pin), isWellFormedHash(storedHash) else { return false }
        let parts = storedHash.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let salt = data(fromHex: String(parts[0])) else {
            return false
        }
        let candidate = digest(pin: pin, salt: salt)

        let expected = Array(String(parts[1]).utf8)
        let actual = Array(candidate.utf8)
        guard expected.count == actual.count else { return false }
        return constantTimeEqual(actual, expected)
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func digest(pin: String, salt: Data) -> String {
        var input = salt
        input.append(contentsOf: Array(pin.utf8))
        return hexString(Data(SHA256.hash(data: input)))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func hexString(_ data: Data) -> String {
        var characters = [UInt8]()
        characters.reserveCapacity(data.count * 2)
        for byte in data {
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }

    private static func data(fromHex hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

enum ProfileScopedStorage {
    static func documentFileName(base: String, fileExtension: String, profileID: UUID) -> String {
        "\(base)-\(token(for: profileID)).\(fileExtension)"
    }

    static func defaultsKey(base: String, profileID: UUID) -> String {
        "\(base).\(token(for: profileID))"
    }

    static func token(for profileID: UUID) -> String {
        profileID.uuidString.lowercased()
    }

    static func migrateLegacyStoreIfNeeded(marker: String, migrate: () throws -> Void) {
        let key = "eclipseProfileStoreMigrationV1.\(marker)"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        do {
            try migrate()
            defaults.set(true, forKey: key)
        } catch {
            Logger.shared.log(
                "ProfileScopedStorage: legacy '\(marker)' migration failed, will retry next launch: \(error.localizedDescription)",
                type: "Error"
            )
        }
    }
}

extension Notification.Name {

    static let activeProfileDidChange = Notification.Name("activeProfileDidChange")

    static let profileListDidChange = Notification.Name("profileListDidChange")
}

final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    static let defaultProfileID = UUID(uuidString: "EC115E00-0000-4000-A000-000000000001")!

    static let maximumProfiles = 6
    static let maximumNameUTF8Bytes = 256
    static let maximumAvatarSymbolUTF8Bytes = 128

    @Published private(set) var profiles: [Profile]
    @Published private(set) var activeProfileID: UUID

    private(set) var rosterGeneration: UInt64 = 0

    private(set) var rosterStoreIsReadable: Bool

    var profilesForMediaStateSync: [Profile]? {
        rosterStoreIsReadable ? profiles : nil
    }

    private let stateLock = NSLock()
    private var cachedKidsModeActive: Bool

    private static let profilesKey = "eclipseProfilesV1"

    static let activeProfileStorageKey = "eclipseActiveProfileIDV1"

    private static let storedRosterAtLaunch: (profiles: [Profile], isReadable: Bool) = loadStoredRoster()

    static let launchActiveProfileID: UUID = {
        let roster = storedRosterAtLaunch.profiles
        let storedActive = UserDefaults.standard
            .string(forKey: activeProfileStorageKey)
            .flatMap(UUID.init(uuidString:))
        if let storedActive, roster.contains(where: { $0.id == storedActive }) {
            return storedActive
        }
        return roster.first?.id ?? defaultProfileID
    }()

    private static func loadStoredRoster() -> (profiles: [Profile], isReadable: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: profilesKey) != nil else {
            return ([makeDefaultProfile()], true)
        }
        if let data = defaults.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data),
           let sanitized = sanitizedAuthoritativeRoster(decoded),
           isValidAuthoritativeRoster(sanitized) {
            return (sanitized, true)
        }

        Logger.shared.log(
            "ProfileManager: the stored profile roster is unreadable; using an unpersisted default until valid data is restored or explicitly edited",
            type: "Error"
        )
        return ([makeDefaultProfile()], false)
    }

    private init() {
        let defaults = UserDefaults.standard

        asksOnLaunch = defaults.object(forKey: Self.asksOnLaunchKey) as? Bool ?? true
        let stored = Self.storedRosterAtLaunch
        let loaded = stored.profiles
        rosterStoreIsReadable = stored.isReadable
        profiles = loaded

        let resolvedActive = Self.launchActiveProfileID
        activeProfileID = resolvedActive
        cachedKidsModeActive = loaded.first { $0.id == resolvedActive }?.isKidsProfile ?? false
        locallyDeletedProfileIDs = Self.loadLocallyDeletedProfileIDs()

            .subtracting(loaded.map(\.id))

        persist()

        ProfileSettingsStore.shared.switchProfile(to: resolvedActive)
    }

    static func makeDefaultProfile() -> Profile {
        Profile(
            id: defaultProfileID,
            name: "Me",
            avatarSymbol: ProfileAvatar.defaultSymbol,
            avatarColorHex: ProfileAvatar.defaultColorHex,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func isValidAuthoritativeRoster(_ candidates: [Profile]) -> Bool {
        let now = Date()
        guard !candidates.isEmpty,
              candidates.count <= maximumProfiles,
              Set(candidates.map(\.id)).count == candidates.count,
              candidates.contains(where: { !$0.isKidsProfile }) else {
            return false
        }
        return candidates.allSatisfy { profile in
            sanitizedName(profile.name) == profile.name
                && sanitizedAvatarSymbol(profile.avatarSymbol) == profile.avatarSymbol
                && sanitizedAvatarColorHex(profile.avatarColorHex) == profile.avatarColorHex
                && (profile.avatarPhotoData?.count ?? 0) <= ProfileAvatar.maximumPhotoBytes
                && !profile.hasRejectedPINHash
                && isPlausibleClock(profile.createdAt, now: now)
                && (profile.pinChangedAt.map { isPlausibleClock($0, now: now) } ?? true)
                && (profile.kidsFlagChangedAt.map { isPlausibleClock($0, now: now) } ?? true)
        }
    }

    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID }
    }

    func profile(with id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    var isKidsModeActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedKidsModeActive
    }

    var hasMultipleProfiles: Bool { profiles.count > 1 }

    private static let asksOnLaunchKey = "eclipseProfileAsksOnLaunchV1"

    @Published var asksOnLaunch: Bool {
        didSet {
            guard asksOnLaunch != oldValue else { return }
            guard activeProfile?.isKidsProfile != true else {
                asksOnLaunch = oldValue
                return
            }
            UserDefaults.standard.set(asksOnLaunch, forKey: Self.asksOnLaunchKey)
        }
    }

    var shouldPresentLaunchPicker: Bool {

        if activeProfile?.isLocked == true { return true }
        guard hasMultipleProfiles else { return false }
        return asksOnLaunch
    }

    var launchProfileRequiringUnlock: Profile? {
        guard let active = activeProfile, active.isLocked else { return nil }

        guard !asksOnLaunch || !hasMultipleProfiles else { return nil }
        return active
    }

    @discardableResult
    func createProfile(
        name: String,
        avatarSymbol: String = ProfileAvatar.defaultSymbol,
        avatarColorHex: String = ProfileAvatar.defaultColorHex,
        avatarPhotoData: Data? = nil,
        isKidsProfile: Bool = false
    ) -> Profile? {
        guard let sanitizedName = Self.sanitizedName(name),
              profiles.count < Self.maximumProfiles else { return nil }

        let profile = Profile(
            name: sanitizedName,
            avatarSymbol: Self.sanitizedAvatarSymbol(avatarSymbol),
            avatarColorHex: Self.sanitizedAvatarColorHex(avatarColorHex),
            avatarPhotoData: Self.sanitizedPhotoData(avatarPhotoData),
            isKidsProfile: isKidsProfile
        )
        profiles.append(profile)
        didMutateProfiles()
        return profile
    }

    @discardableResult
    func mergeProfilesFromBackup(_ incoming: [Profile]) -> Set<UUID> {
        if !rosterStoreIsReadable {
            return replaceUnreadableRosterFromBackup(incoming)
        }
        var didChange = false
        var activeKidsFlagChanged = false
        var acceptedProfileIDs = Set<UUID>()
        for rawProfile in incoming {
            guard let profile = Self.sanitizedProfileForRoster(rawProfile) else { continue }
            let name = profile.name
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                acceptedProfileIDs.insert(profile.id)
                var merged = profiles[index]
                merged.name = name
                merged.avatarSymbol = profile.avatarSymbol
                merged.avatarColorHex = profile.avatarColorHex
                merged.avatarPhotoData = Self.sanitizedPhotoData(profile.avatarPhotoData)

                if !merged.isLocked {
                    merged.pinHash = ProfilePINHasher.sanitizedHash(profile.pinHash)
                    merged.hasRejectedPINHash = false
                }

                let wantsKids = merged.isKidsProfile || profile.isKidsProfile
                if wantsKids, !merged.isKidsProfile, !canConvertToKidsProfile(id: merged.id) {
                    Logger.shared.log(
                        "ProfileManager: a backup would have made the last non-kids profile a kids profile; kept \(merged.id) administrable",
                        type: "Error"
                    )
                } else {
                    merged.isKidsProfile = wantsKids
                }
                guard merged != profiles[index] else { continue }
                let pinChanged = merged.pinHash != profiles[index].pinHash
                let kidsFlagChanged = merged.isKidsProfile != profiles[index].isKidsProfile

                let now = Date()
                if pinChanged { merged.pinChangedAt = now }
                if kidsFlagChanged { merged.kidsFlagChangedAt = now }
                if kidsFlagChanged, merged.id == activeProfileID {
                    activeKidsFlagChanged = true
                }
                profiles[index] = merged
                didChange = true
            } else {

                guard !locallyDeletedProfileIDs.contains(profile.id) else {
                    Logger.shared.log(
                        "ProfileManager: refused to resurrect profile \(profile.id) because it was deleted on this device",
                        type: "Info"
                    )
                    continue
                }
                guard profiles.count < Self.maximumProfiles else {
                    Logger.shared.log(
                        "ProfileManager: backup roster exceeds \(Self.maximumProfiles) profiles; skipped \(profile.id)",
                        type: "Error"
                    )
                    continue
                }
                var added = profile
                added.name = name
                added.avatarPhotoData = Self.sanitizedPhotoData(profile.avatarPhotoData)
                added.pinHash = ProfilePINHasher.sanitizedHash(profile.pinHash)
                added.hasRejectedPINHash = false
                profiles.append(added)
                acceptedProfileIDs.insert(added.id)
                didChange = true
            }
        }
        guard didChange else { return acceptedProfileIDs }
        profiles.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.createdAt < rhs.createdAt
        }
        UserDefaults.standard.set(
            locallyDeletedProfileIDs.map(\.uuidString),
            forKey: Self.deletedProfilesKey
        )
        didMutateProfiles()

        if activeKidsFlagChanged {
            republishForActiveKidsModeChange()
        }
        return acceptedProfileIDs
    }

    private func replaceUnreadableRosterFromBackup(_ incoming: [Profile]) -> Set<UUID> {
        var seenIDs = Set<UUID>()
        var resolved: [Profile] = []
        resolved.reserveCapacity(min(incoming.count, Self.maximumProfiles))

        for rawProfile in incoming {
            guard let profile = Self.sanitizedProfileForRoster(rawProfile) else { continue }
            let name = profile.name
            guard !name.isEmpty,
                  seenIDs.insert(profile.id).inserted,
                  resolved.count < Self.maximumProfiles else { continue }
            var candidate = profile
            candidate.name = name
            candidate.avatarPhotoData = Self.sanitizedPhotoData(profile.avatarPhotoData)
            candidate.pinHash = ProfilePINHasher.sanitizedHash(profile.pinHash)
            candidate.hasRejectedPINHash = false
            resolved.append(candidate)
        }
        guard !resolved.isEmpty else {
            Logger.shared.log(
                "ProfileManager: an unreadable roster was not replaced because the backup contained no valid profiles",
                type: "Error"
            )
            return []
        }

        if resolved.allSatisfy(\.isKidsProfile) {
            let anchorIndex = resolved.indices.min {
                if resolved[$0].createdAt == resolved[$1].createdAt {
                    return resolved[$0].id.uuidString < resolved[$1].id.uuidString
                }
                return resolved[$0].createdAt < resolved[$1].createdAt
            } ?? resolved.startIndex
            let incomingStamp = resolved[anchorIndex].kidsFlagChangedAt?
                .timeIntervalSinceReferenceDate ?? Date.distantPast.timeIntervalSinceReferenceDate
            let correctionStamp = max(Date().timeIntervalSinceReferenceDate, incomingStamp).nextUp
            guard correctionStamp.isFinite else {
                Logger.shared.log(
                    "ProfileManager: refused a backup roster whose kids restriction clock cannot be safely advanced",
                    type: "Error"
                )
                return []
            }
            resolved[anchorIndex].isKidsProfile = false
            resolved[anchorIndex].kidsFlagChangedAt = Date(
                timeIntervalSinceReferenceDate: correctionStamp
            )
        }

        resolved.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.createdAt < rhs.createdAt
        }
        guard Self.isValidAuthoritativeRoster(resolved) else {
            Logger.shared.log(
                "ProfileManager: refused an invalid backup roster while the saved roster remains unreadable",
                type: "Error"
            )
            return []
        }

        let previousActive = activeProfileID
        let previousKidsFlag = profiles.first { $0.id == previousActive }?.isKidsProfile
        profiles = resolved
        rosterStoreIsReadable = true
        rosterGeneration &+= 1
        locallyDeletedProfileIDs.subtract(resolved.map(\.id))

        if !resolved.contains(where: { $0.id == previousActive }) {

            applyActiveProfile(resolved[0].id)
        } else {
            refreshKidsModeCache()
            let currentKidsFlag = resolved.first { $0.id == previousActive }?.isKidsProfile
            if let previousKidsFlag,
               let currentKidsFlag,
               previousKidsFlag != currentKidsFlag {
                republishForActiveKidsModeChange()
            }
        }

        UserDefaults.standard.set(
            locallyDeletedProfileIDs.map(\.uuidString),
            forKey: Self.deletedProfilesKey
        )
        persist()
        NotificationCenter.default.post(name: .profileListDidChange, object: self)
        return Set(resolved.map(\.id))
    }

    func isStillActive(_ owner: UUID) -> Bool {
        activeProfileID == owner
    }

    func canConvertToKidsProfile(id: UUID) -> Bool {
        profiles.contains { $0.id != id && !$0.isKidsProfile }
    }

    func canDeleteWithoutStrandingAdministration(id: UUID) -> Bool {
        guard let target = profile(with: id), !target.isKidsProfile else { return true }
        return profiles.contains { $0.id != id && !$0.isKidsProfile }
    }

    func updateProfile(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard var sanitized = Self.sanitizedProfileForRoster(profile) else { return }
        sanitized.avatarPhotoData = Self.sanitizedPhotoData(profile.avatarPhotoData)
        sanitized.pinHash = ProfilePINHasher.sanitizedHash(profile.pinHash)
        sanitized.hasRejectedPINHash = false

        if sanitized.isKidsProfile, !profiles[index].isKidsProfile, !canConvertToKidsProfile(id: sanitized.id) {
            Logger.shared.log(
                "ProfileManager: refused to make the last non-kids profile a kids profile; nothing would be able to undo it",
                type: "Error"
            )
            return
        }
        if sanitized.pinHash == profiles[index].pinHash {
            sanitized.pinChangedAt = profiles[index].pinChangedAt
        }
        if sanitized.isKidsProfile == profiles[index].isKidsProfile {
            sanitized.kidsFlagChangedAt = profiles[index].kidsFlagChangedAt
        }
        guard profiles[index] != sanitized else { return }
        let kidsFlagChanged = profiles[index].isKidsProfile != sanitized.isKidsProfile

        let now = Date()
        if sanitized.pinHash != profiles[index].pinHash {
            sanitized.pinChangedAt = now
        }
        if kidsFlagChanged {
            sanitized.kidsFlagChangedAt = now
        }
        profiles[index] = sanitized
        didMutateProfiles()

        if kidsFlagChanged, sanitized.id == activeProfileID {
            republishForActiveKidsModeChange()
        }
    }

    private func republishForActiveKidsModeChange() {
        CatalogManager.shared.reloadCatalogsForKidsModeChange()
        TMDBContentFilter.shared.activeProfileDidChange()

        RecommendationEngine.shared.invalidateCache()
#if !os(tvOS)
        MangaCatalogManager.shared.switchProfile(to: activeProfileID)
        ReaderContentFilter.shared.activeProfileDidChange()
#endif
        NotificationCenter.default.post(name: .activeProfileDidChange, object: self)
    }

    func renameProfile(_ id: UUID, to name: String) {
        guard var profile = profile(with: id) else { return }
        profile.name = name
        updateProfile(profile)
    }

    func setKidsProfile(_ isKids: Bool, for id: UUID) {
        guard var profile = profile(with: id) else { return }
        profile.isKidsProfile = isKids
        updateProfile(profile)
    }

    func setPIN(_ pin: String, for id: UUID) -> Bool {
        guard var profile = profile(with: id),
              let hash = ProfilePINHasher.makeHash(for: pin) else { return false }
        profile.pinHash = hash
        updateProfile(profile)
        return true
    }

    func clearPIN(for id: UUID) {
        guard var profile = profile(with: id), profile.pinHash != nil else { return }
        profile.pinHash = nil
        updateProfile(profile)
    }

    func verifyPIN(_ pin: String, for id: UUID) -> Bool {
        guard let profile = profile(with: id), profile.isLocked, let hash = profile.pinHash else {
            return true
        }
        return ProfilePINHasher.verify(pin: pin, against: hash)
    }

    @discardableResult
    func deleteProfile(_ id: UUID) -> Bool {
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else {
            return false
        }

        guard id != Self.defaultProfileID else {
            Logger.shared.log(
                "ProfileManager: refused to delete the default profile; its settings and services are the install-wide stores and cannot be reclaimed",
                type: "Error"
            )
            return false
        }

        guard canDeleteWithoutStrandingAdministration(id: id) else {
            Logger.shared.log(
                "ProfileManager: refused to delete the last non-kids profile; no profile would be able to administer the roster",
                type: "Error"
            )
            return false
        }
        guard prepareReaderAuthenticationForProfileRemoval([id]) else {
            return false
        }
        if id == activeProfileID {
            let fallback = profiles.first { $0.id != id } ?? profiles[0]
            switchProfile(to: fallback.id)
        }
        profiles.remove(at: index)
        recordLocalDeletion(of: id)

        ProfileSettingsStore.shared.discardStore(forProfile: id)
        for store in ProfileScopedStoreRegistry.all {
            store.discardStore(forProfile: id)
        }
#if os(iOS)
        LocalNotificationManager.shared.discardStore(forProfile: id)
#endif

        didMutateProfiles()
        return true
    }

    private(set) var locallyDeletedProfileIDs: Set<UUID> = []

    private static let deletedProfilesKey = "eclipseDeletedProfileIDsV1"

    func wasDeletedLocally(_ id: UUID) -> Bool {
        locallyDeletedProfileIDs.contains(id)
    }

    private func recordLocalDeletion(of id: UUID) {
        locallyDeletedProfileIDs.insert(id)
        UserDefaults.standard.set(
            locallyDeletedProfileIDs.map(\.uuidString),
            forKey: Self.deletedProfilesKey
        )
    }

    private static func loadLocallyDeletedProfileIDs() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: deletedProfilesKey) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    func switchProfile(to id: UUID) {
        guard id != activeProfileID, profiles.contains(where: { $0.id == id }) else { return }
        applyActiveProfile(id)
    }

    private func applyActiveProfile(_ id: UUID) {
        let outgoing = activeProfileID

#if os(iOS)
        // Invalidate held Reader providers synchronously at the profile
        // boundary, before any async scope-reload observer can run. This also
        // closes an A -> B -> A race where a suspended mutation might otherwise
        // see the same UUID again and publish stale state.
        ReaderExtensionAuthenticationGenerationRegistry.revokeNamespace(
            outgoing.uuidString
        )
#endif

        for store in ProfileScopedStoreRegistry.all {
            store.flushPendingWrites(forProfile: outgoing)
        }
#if os(iOS)
        LocalNotificationManager.shared.flushPendingWrites(forProfile: outgoing)
#endif

        ServiceStoreScope.willChangeActiveProfile()
        ProfileSettingsStore.shared.switchProfile(to: id)
        activeProfileID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeProfileStorageKey)
        refreshKidsModeCache()

        ProgressManager.shared.switchProfile(to: id)
        LibraryManager.shared.switchProfile(to: id)
        UserRatingManager.shared.switchProfile(to: id)
        CatalogManager.shared.switchProfile(to: id)

        RecommendationEngine.shared.switchProfile(to: id)

        TrackerManager.shared.switchProfile(to: id)
        UpNextResolutionCache.shared.switchProfile(to: id)

        ServiceStoreScope.activeProfileDidChange()
        TMDBContentFilter.shared.activeProfileDidChange()
#if os(iOS)

        LocalNotificationManager.shared.switchProfile(to: id)
#endif

        Settings.current?.reloadForActiveProfile()
        EclipseTheme.shared.reloadForActiveProfile()
        AccentColorManager.shared.reloadForActiveProfile()
        AlgorithmManager.shared.reloadForActiveProfile()
        HomeCatalogLayoutStore.shared.reloadForActiveProfile()
        LocalizationManager.shared.reloadForActiveProfile()
#if !os(tvOS)

        MangaLibraryManager.shared.switchProfile(to: id)
        MangaReadingProgressManager.shared.switchProfile(to: id)
        MangaCatalogManager.shared.switchProfile(to: id)
        KanzenCustomCatalogManager.shared.switchProfile(to: id)
        ReaderContentFilter.shared.activeProfileDidChange()
#endif

        NotificationCenter.default.post(name: .activeProfileDidChange, object: self)
    }

    func replaceProfilesForMediaState(
        _ incoming: [Profile],
        allowsEmptyRosterForConfirmedAccountBoundary: Bool = false
    ) {

        guard allowsEmptyRosterForConfirmedAccountBoundary
                || !incoming.isEmpty
                || profiles.count <= 1 else {
            Logger.shared.log(
                "ProfileManager: refused an empty sync roster while \(profiles.count) profiles exist here; kept them rather than reclaiming their stores",
                type: "Error"
            )
            return
        }
        let incomingIDs = incoming.map(\.id)
        guard Set(incomingIDs).count == incomingIDs.count,
              !incoming.contains(where: \.hasRejectedPINHash) else {
            Logger.shared.log(
                "ProfileManager: refused an invalid or duplicate sync roster rather than applying it authoritatively",
                type: "Error"
            )
            return
        }
        var resolved = incoming.compactMap { incomingProfile -> Profile? in
            var recoverable = incomingProfile
            if Self.sanitizedName(recoverable.name) == nil {

                guard let local = profiles.first(where: { $0.id == recoverable.id }) else {
                    return nil
                }
                recoverable.name = local.name
            }
            guard var candidate = Self.sanitizedProfileForRoster(recoverable) else {
                return nil
            }

            candidate.pinHash = ProfilePINHasher.sanitizedHash(candidate.pinHash)
            candidate.hasRejectedPINHash = false
            candidate.avatarPhotoData = Self.sanitizedPhotoData(candidate.avatarPhotoData)
            return candidate
        }

        if resolved.count > Self.maximumProfiles {
            resolved.sort { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.createdAt < rhs.createdAt
            }
            let localIDs = Set(profiles.map(\.id))
            var admitted = resolved.filter { localIDs.contains($0.id) }
            var skippedIDs: [UUID] = []
            for profile in resolved where !localIDs.contains(profile.id) {
                if admitted.count < Self.maximumProfiles {
                    admitted.append(profile)
                } else {
                    skippedIDs.append(profile.id)
                }
            }
            if !skippedIDs.isEmpty {
                Logger.shared.log(
                    "ProfileManager: a merged roster exceeds \(Self.maximumProfiles) profiles; skipped \(skippedIDs.map(\.uuidString).joined(separator: ", "))",
                    type: "Error"
                )
            }
            resolved = admitted
        }

        if !resolved.isEmpty, resolved.allSatisfy(\.isKidsProfile) {

            let anchorIndex = resolved.indices.min {
                if resolved[$0].createdAt == resolved[$1].createdAt {
                    return resolved[$0].id.uuidString < resolved[$1].id.uuidString
                }
                return resolved[$0].createdAt < resolved[$1].createdAt
            } ?? 0
            let incomingStamp = resolved[anchorIndex].kidsFlagChangedAt?
                .timeIntervalSinceReferenceDate ?? Date.distantPast.timeIntervalSinceReferenceDate
            let correctionStamp = max(Date().timeIntervalSinceReferenceDate, incomingStamp).nextUp
            guard correctionStamp.isFinite else {
                Logger.shared.log(
                    "ProfileManager: refused an all-kids roster whose restriction clock cannot be safely advanced",
                    type: "Error"
                )
                return
            }
            resolved[anchorIndex].isKidsProfile = false

            resolved[anchorIndex].kidsFlagChangedAt = Date(
                timeIntervalSinceReferenceDate: correctionStamp
            )
            Logger.shared.log(
                "ProfileManager: an incoming roster had no grown-up profile; kept \(resolved[anchorIndex].id) administrable so the install stays recoverable",
                type: "Error"
            )
        }
        if resolved.isEmpty {
            resolved = [Self.makeDefaultProfile()]
        }
        guard Self.isValidAuthoritativeRoster(resolved) else {
            Logger.shared.log(
                "ProfileManager: refused a merged roster that failed the authoritative roster invariant",
                type: "Error"
            )
            return
        }
        resolved.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.createdAt < rhs.createdAt
        }
        let repairsUnreadableRoster = !rosterStoreIsReadable
        guard resolved != profiles || repairsUnreadableRoster else { return }

        let previousActive = activeProfileID

        let previousKidsFlag = profiles.first { $0.id == previousActive }?.isKidsProfile

        let resolvedIDs = Set(resolved.map(\.id))
        let removedIDs = profiles.map(\.id).filter { !resolvedIDs.contains($0) }
        guard prepareReaderAuthenticationForProfileRemoval(removedIDs) else {
            return
        }
        profiles = resolved
        rosterStoreIsReadable = true
        rosterGeneration &+= 1

        locallyDeletedProfileIDs.subtract(resolved.map(\.id))
        persist()

        if !resolved.contains(where: { $0.id == previousActive }) {
            applyActiveProfile(resolved[0].id)
        } else {
            refreshKidsModeCache()
            let currentKidsFlag = resolved.first { $0.id == previousActive }?.isKidsProfile
            if let previousKidsFlag, let currentKidsFlag, previousKidsFlag != currentKidsFlag {

                republishForActiveKidsModeChange()
            }
        }

        for profileID in removedIDs {
            ProfileSettingsStore.shared.discardStore(forProfile: profileID)
            for store in ProfileScopedStoreRegistry.all {
                store.discardStore(forProfile: profileID)
            }
#if os(iOS)
            LocalNotificationManager.shared.discardStore(forProfile: profileID)
#endif
        }
        NotificationCenter.default.post(name: .profileListDidChange, object: self)
    }

    /// Reader credentials are device-only and outlive profile UserDefaults.
    /// A crash-durable namespace tombstone must therefore exist before the
    /// roster or scoped stores forget the UUID. Keychain failure after that
    /// checkpoint is safe: deletion proceeds, while a same-UUID restore stays
    /// fenced until the global journal can verify cleanup on retry.
    private func prepareReaderAuthenticationForProfileRemoval(
        _ profileIDs: [UUID]
    ) -> Bool {
        guard !profileIDs.isEmpty else { return true }
#if os(iOS)
        do {
            let result = try ReaderExtensionProfileAuthenticationLifecycle
                .prepareForProfileStoreDeletion(profileIDs: profileIDs)
            if let error = result.firstError {
                Logger.shared.log(
                    "ProfileManager: Reader authentication cleanup remains pending for deleted profile namespace(s): \(error.localizedDescription)",
                    type: "Error"
                )
            }
            return true
        } catch {
            Logger.shared.log(
                "ProfileManager: refused to remove profile metadata because Reader authentication cleanup could not be checkpointed: \(error.localizedDescription)",
                type: "Error"
            )
            return false
        }
#else
        return true
#endif
    }

    private func didMutateProfiles() {

        rosterStoreIsReadable = true
        rosterGeneration &+= 1
        persist()
        refreshKidsModeCache()
        NotificationCenter.default.post(name: .profileListDidChange, object: self)
    }

    private func persist() {
        guard rosterStoreIsReadable else { return }
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: Self.profilesKey)

        let storedActive = profiles.contains { $0.id == activeProfileID }
            ? activeProfileID
            : (profiles.first?.id ?? activeProfileID)
        UserDefaults.standard.set(storedActive.uuidString, forKey: Self.activeProfileStorageKey)
    }

    private func refreshKidsModeCache() {
        let isKids = profiles.first { $0.id == activeProfileID }?.isKidsProfile ?? false
        stateLock.lock()
        cachedKidsModeActive = isKids
        stateLock.unlock()
    }

    private static func sanitizedPhotoData(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        guard data.count <= ProfileAvatar.maximumPhotoBytes else { return nil }
        return data
    }

    static func sanitizedProfileForRoster(
        _ source: Profile,
        now: Date = Date()
    ) -> Profile? {
        guard let name = sanitizedName(source.name) else { return nil }
        var result = source
        result.name = name
        result.avatarSymbol = sanitizedAvatarSymbol(source.avatarSymbol)
        result.avatarColorHex = sanitizedAvatarColorHex(source.avatarColorHex)
        result.avatarPhotoData = sanitizedPhotoData(source.avatarPhotoData)
        result.createdAt = sanitizedRequiredClock(source.createdAt, now: now)
        result.pinChangedAt = sanitizedOptionalClock(source.pinChangedAt, now: now)
        result.kidsFlagChangedAt = sanitizedOptionalClock(source.kidsFlagChangedAt, now: now)
        return result
    }

    private static func sanitizedAuthoritativeRoster(_ candidates: [Profile]) -> [Profile]? {
        let now = Date()
        var result: [Profile] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard let sanitized = sanitizedProfileForRoster(candidate, now: now) else {
                return nil
            }
            result.append(sanitized)
        }
        return result
    }

    static func sanitizedName(_ rawValue: String) -> String? {
        var withoutControls = ""
        withoutControls.reserveCapacity(rawValue.count)
        for scalar in rawValue.unicodeScalars
        where !CharacterSet.controlCharacters.contains(scalar) {
            withoutControls.unicodeScalars.append(scalar)
        }
        let trimmed = withoutControls.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return boundedStringPrefix(trimmed, maximumUTF8Bytes: maximumNameUTF8Bytes)
    }

    static func sanitizedAvatarSymbol(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumAvatarSymbolUTF8Bytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 46, 48...57, 65...90, 95, 97...122:
                      return true
                  default:
                      return false
                  }
              }) else {
            return ProfileAvatar.defaultSymbol
        }
        return value
    }

    static func sanitizedAvatarColorHex(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let bytes = Array(value.utf8)
        guard bytes.count == 7,
              bytes.first == 35,
              bytes.dropFirst().allSatisfy({ byte in
                  (48...57).contains(byte) || (65...70).contains(byte)
              }) else {
            return ProfileAvatar.defaultColorHex
        }
        return value
    }

    private static func boundedStringPrefix(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> String {
        guard value.utf8.count > maximumUTF8Bytes else { return value }
        var result = ""
        var byteCount = 0
        for character in value {
            let fragment = String(character)
            let fragmentBytes = fragment.utf8.count
            guard byteCount + fragmentBytes <= maximumUTF8Bytes else { break }
            result.append(character)
            byteCount += fragmentBytes
        }
        return result
    }

    private static func isPlausibleClock(_ value: Date, now: Date) -> Bool {
        let seconds = value.timeIntervalSince1970
        return seconds.isFinite
            && seconds >= 0
            && seconds <= now.timeIntervalSince1970
                + MediaStateEnvelopeValidator.maximumFutureClockSkew
    }

    private static func sanitizedRequiredClock(_ value: Date, now: Date) -> Date {
        let seconds = value.timeIntervalSince1970
        guard seconds.isFinite else { return now }
        if seconds < 0 { return Date(timeIntervalSince1970: 0) }
        if !isPlausibleClock(value, now: now) { return now }
        return value
    }

    private static func sanitizedOptionalClock(_ value: Date?, now: Date) -> Date? {
        guard let value else { return nil }
        let seconds = value.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return isPlausibleClock(value, now: now) ? value : now
    }
}
