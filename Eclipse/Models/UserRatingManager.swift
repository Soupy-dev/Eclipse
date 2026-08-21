import Foundation

final class UserRatingManager {
    static let shared = UserRatingManager()

    static let maximumPersistedStoreBytes = 16 * 1_024 * 1_024
    static let notificationProfileIDKey = "profileID"

    struct StoreWriteAuthority: Equatable {
        let profileID: UUID
        let generation: UInt64
        let destination: URL
        let sequence: UInt64
    }

    private struct RatingStore: Codable {
        var ratings: [String: Double] = [:]
        var notes: [String: String] = [:]
    }

    private struct LegacyRatingStore: Codable {
        var ratings: [String: Int] = [:]
        var notes: [String: String] = [:]
    }

    private enum StoreLoadResult {
        case loaded(ratings: [Int: Double], notes: [Int: String])
        case unreadable
        case corrupt
    }

    private var ratings: [Int: Double] = [:]
    private var notes: [Int: String] = [:]

    private var fileURL: URL
    private var activeProfileID: UUID
    private let lock = NSLock()

    private var storeGeneration: UInt64 = 0
    private var storeWriteSequence: UInt64 = 0

    private var activeStoreLoadFailed = false

    private init() {
        let profileID = ProfileManager.shared.activeProfileID
        activeProfileID = profileID
        fileURL = Self.fileURL(for: profileID)
        Self.migrateLegacyStoreIfNeeded()
        adoptStore(Self.load(from: fileURL, profileID: profileID), at: fileURL)
    }

    private func adoptStore(_ result: StoreLoadResult, at url: URL) {
        switch result {
        case .loaded(let loadedRatings, let loadedNotes):
            ratings = loadedRatings
            notes = loadedNotes
            activeStoreLoadFailed = false
        case .corrupt:
            ratings = [:]
            notes = [:]
            activeStoreLoadFailed = !Self.quarantineUnreadableStore(
                at: url,
                profileID: activeProfileID
            )
        case .unreadable:
            ratings = [:]
            notes = [:]
            activeStoreLoadFailed = true
        }
    }

    private static func unreadableMarkerURL(for profileID: UUID) -> URL {
        documentsDirectory.appendingPathComponent(
            "UserRatings-\(ProfileScopedStorage.token(for: profileID)).unreadable.marker"
        )
    }

    private static func markStoreUnreadable(for profileID: UUID) {
        try? Data("unreadable\n".utf8).write(
            to: unreadableMarkerURL(for: profileID),
            options: .atomic
        )
    }

    private static func clearUnreadableMarker(for profileID: UUID) throws {
        let markerURL = unreadableMarkerURL(for: profileID)
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        try FileManager.default.removeItem(at: markerURL)
    }

    private static func quarantineUnreadableStore(at url: URL, profileID: UUID) -> Bool {
        let quarantineURL = documentsDirectory.appendingPathComponent(
            "UserRatings-unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased()).json"
        )
        do {
            try FileManager.default.moveItem(at: url, to: quarantineURL)
            try clearUnreadableMarker(for: profileID)
            Logger.shared.log(
                "UserRatingManager: moved unreadable store aside as \(quarantineURL.lastPathComponent) and started a fresh store",
                type: "Error"
            )
            return true
        } catch {
            markStoreUnreadable(for: profileID)
            Logger.shared.log(
                "UserRatingManager: could not move the unreadable store aside: \(error.localizedDescription)",
                type: "Error"
            )
            return false
        }
    }

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func fileURL(for profileID: UUID) -> URL {
        documentsDirectory.appendingPathComponent(
            ProfileScopedStorage.documentFileName(
                base: "UserRatings",
                fileExtension: "json",
                profileID: profileID
            )
        )
    }

    private static func migrateLegacyStoreIfNeeded() {
        ProfileScopedStorage.migrateLegacyStoreIfNeeded(marker: "ratings") {
            let fileManager = FileManager.default
            let legacyURL = documentsDirectory.appendingPathComponent("UserRatings.json")
            let destinationURL = fileURL(for: ProfileManager.defaultProfileID)
            guard fileManager.fileExists(atPath: legacyURL.path),
                  !fileManager.fileExists(atPath: destinationURL.path) else { return }

            try fileManager.moveItem(at: legacyURL, to: destinationURL)
        }
    }

    func switchProfile(to profileID: UUID) {
        lock.lock()
        guard profileID != activeProfileID else {
            lock.unlock()
            return
        }
        storeGeneration = Self.generationAfterAuthoritativeChange(storeGeneration)
        storeWriteSequence &+= 1
        activeProfileID = profileID
        fileURL = Self.fileURL(for: profileID)
        adoptStore(Self.load(from: fileURL, profileID: profileID), at: fileURL)
        lock.unlock()
        postDataDidChange(for: profileID)
    }

    func ratingsAndNotes(forProfile profileID: UUID) -> (ratings: [String: Double], notes: [String: String])? {
        lock.lock()
        let source: (ratings: [Int: Double], notes: [Int: String])
        if profileID == activeProfileID {
            guard !activeStoreLoadFailed else {
                lock.unlock()
                return nil
            }
            source = (ratings, notes)
        } else {
            guard case .loaded(let loadedRatings, let loadedNotes) = Self.load(
                from: Self.fileURL(for: profileID),
                profileID: profileID
            ) else {
                lock.unlock()
                return nil
            }
            source = (loadedRatings, loadedNotes)
        }
        lock.unlock()
        return (
            Dictionary(uniqueKeysWithValues: source.ratings.map { (String($0.key), $0.value) }),
            Dictionary(uniqueKeysWithValues: source.notes.map { (String($0.key), $0.value) })
        )
    }

    @discardableResult
    func restoreRatingsAndNotes(
        ratings backupRatings: [String: Double],
        notes backupNotes: [String: String],
        forProfile profileID: UUID
    ) -> Bool {
        let normalized = Self.normalizedStore(ratings: backupRatings, notes: backupNotes)
        guard let data = try? JSONEncoder().encode(normalized),
              data.count <= Self.maximumPersistedStoreBytes else { return false }

        var didRestore = false
        lock.lock()
        if profileID == activeProfileID {
            didRestore = restoreActiveStoreLocked(normalized, encoded: data)
        } else {
            let destination = Self.fileURL(for: profileID)
            let requiresQuarantine: Bool
            switch Self.load(from: destination, profileID: profileID) {
            case .loaded:
                requiresQuarantine = false
            case .unreadable, .corrupt:
                requiresQuarantine = true
            }
            do {
                try Self.persistAuthoritativeStoreData(
                    data,
                    to: destination,
                    storeRequiresQuarantine: requiresQuarantine
                ) { source in
                    Self.quarantineUnreadableStore(at: source, profileID: profileID)
                }
                try Self.clearUnreadableMarker(for: profileID)
                didRestore = true
            } catch {
                Logger.shared.log(
                    "UserRatingManager: could not persist a restored inactive-profile store: \(error.localizedDescription)",
                    type: "Error"
                )
            }
        }
        lock.unlock()
        if didRestore {
            if ProfileManager.shared.isStillActive(profileID) {
                RecommendationEngine.shared.invalidateCache()
            }
            postDataDidChange(for: profileID)
        }
        return didRestore
    }

    func discardStore(forProfile profileID: UUID) {
        lock.lock()
        guard profileID != activeProfileID else {
            lock.unlock()
            return
        }
        try? FileManager.default.removeItem(at: Self.fileURL(for: profileID))
        try? Self.clearUnreadableMarker(for: profileID)
        lock.unlock()
    }

    func rating(for tmdbId: Int) -> Double? {
        guard ProgressPersistencePolicy.validPositiveIdentifier(tmdbId) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return ratings[tmdbId]
    }

    func note(for tmdbId: Int) -> String {
        guard ProgressPersistencePolicy.validPositiveIdentifier(tmdbId) else { return "" }
        lock.lock()
        defer { lock.unlock() }
        return notes[tmdbId] ?? ""
    }

    func setRating(_ value: Double, for tmdbId: Int) {
        guard ProgressPersistencePolicy.validPositiveIdentifier(tmdbId) else { return }
        let clamped = Self.normalizedRating(value)
        lock.lock()
        ratings[tmdbId] = clamped
        let request = captureStoreWriteLocked()
        lock.unlock()
        if persist(request) {
            postDataDidChange(for: request.authority.profileID)
        }
        RecommendationEngine.shared.invalidateCache()
    }

    func removeRating(for tmdbId: Int) {
        guard ProgressPersistencePolicy.validPositiveIdentifier(tmdbId) else { return }
        lock.lock()
        ratings.removeValue(forKey: tmdbId)
        let request = captureStoreWriteLocked()
        lock.unlock()
        if persist(request) {
            postDataDidChange(for: request.authority.profileID)
        }
        RecommendationEngine.shared.invalidateCache()
    }

    func setNote(_ value: String, for tmdbId: Int) {
        guard ProgressPersistencePolicy.validPositiveIdentifier(tmdbId) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if trimmed.isEmpty {
            notes.removeValue(forKey: tmdbId)
        } else {
            notes[tmdbId] = value
        }
        let request = captureStoreWriteLocked()
        lock.unlock()
        if persist(request) {
            postDataDidChange(for: request.authority.profileID)
        }
    }

    func allRatings() -> [(tmdbId: Int, stars: Double)] {
        lock.lock()
        defer { lock.unlock() }
        return ratings.map { (tmdbId: $0.key, stars: $0.value) }
    }

    func getRatingsForBackup() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: ratings.map { (String($0.key), $0.value) })
    }

    func getNotesForBackup() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: notes.map { (String($0.key), $0.value) })
    }

    @discardableResult
    func restoreRatingsAndNotes(
        ratings backupRatings: [String: Double],
        notes backupNotes: [String: String]
    ) -> Bool {
        let normalized = Self.normalizedStore(ratings: backupRatings, notes: backupNotes)
        guard let data = try? JSONEncoder().encode(normalized),
              data.count <= Self.maximumPersistedStoreBytes else { return false }
        lock.lock()
        let owner = activeProfileID
        let didRestore = restoreActiveStoreLocked(normalized, encoded: data)
        lock.unlock()
        if didRestore {
            RecommendationEngine.shared.invalidateCache()
            postDataDidChange(for: owner)
        }
        return didRestore
    }

    @discardableResult
    func restoreRatings(_ backup: [String: Int]) -> Bool {
        restoreLegacyRatings(backup.mapValues(Double.init))
    }

    @discardableResult
    func restoreRatings(_ backup: [String: Double]) -> Bool {
        restoreLegacyRatings(backup)
    }

    private func restoreLegacyRatings(_ backup: [String: Double]) -> Bool {
        lock.lock()
        let owner = activeProfileID
        let existingNotes = Dictionary(
            uniqueKeysWithValues: notes.map { (String($0.key), $0.value) }
        )
        lock.unlock()
        // The owner is captured with the notes. If a profile switch happens
        // now, the scoped restore updates the original profile instead of
        // mixing its notes into whichever profile became active.
        return restoreRatingsAndNotes(
            ratings: backup,
            notes: existingNotes,
            forProfile: owner
        )
    }

    private func currentStore() -> RatingStore {
        RatingStore(
            ratings: Dictionary(uniqueKeysWithValues: ratings.map { (String($0.key), $0.value) }),
            notes: Dictionary(uniqueKeysWithValues: notes.map { (String($0.key), $0.value) })
        )
    }

    private struct StoreWriteRequest {
        let authority: StoreWriteAuthority
        let store: RatingStore
        let storeLoadFailed: Bool
    }

    private func captureStoreWriteLocked() -> StoreWriteRequest {
        storeWriteSequence &+= 1
        return StoreWriteRequest(
            authority: StoreWriteAuthority(
                profileID: activeProfileID,
                generation: storeGeneration,
                destination: fileURL,
                sequence: storeWriteSequence
            ),
            store: currentStore(),
            storeLoadFailed: activeStoreLoadFailed
        )
    }

    @discardableResult
    private func persist(_ request: StoreWriteRequest) -> Bool {
        guard let jsonData = try? JSONEncoder().encode(request.store),
              jsonData.count <= Self.maximumPersistedStoreBytes else {
            Logger.shared.log(
                "UserRatingManager: refused to persist an oversized rating store",
                type: "Error"
            )
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard Self.storeWriteAuthorityIsCurrent(
            request.authority,
            currentProfileID: activeProfileID,
            currentGeneration: storeGeneration,
            currentDestination: fileURL,
            currentSequence: storeWriteSequence
        ) else {
            return false
        }
        guard !request.storeLoadFailed, !activeStoreLoadFailed else {
            Logger.shared.log(
                "UserRatingManager: refused to save over a store that failed to load",
                type: "Error"
            )
            return false
        }
        do {
            try jsonData.write(to: request.authority.destination, options: .atomic)
            return true
        } catch {
            Logger.shared.log(
                "UserRatingManager: failed to persist ratings: \(error.localizedDescription)",
                type: "Error"
            )
            return false
        }
    }

    private func restoreActiveStoreLocked(_ store: RatingStore, encoded data: Data) -> Bool {
        do {
            try Self.persistAuthoritativeStoreData(
                data,
                to: fileURL,
                storeRequiresQuarantine: activeStoreLoadFailed
            ) { source in
                Self.quarantineUnreadableStore(
                    at: source,
                    profileID: activeProfileID
                )
            }
            try Self.clearUnreadableMarker(for: activeProfileID)
        } catch {
            Logger.shared.log(
                "UserRatingManager: could not persist an authoritative rating restore: \(error.localizedDescription)",
                type: "Error"
            )
            return false
        }
        storeGeneration = Self.generationAfterAuthoritativeChange(storeGeneration)
        storeWriteSequence &+= 1
        ratings = Self.parseRatings(store.ratings)
        notes = Self.parseNotes(store.notes)
        activeStoreLoadFailed = false
        return true
    }

    /// Quarantine must finish before an authoritative replacement can touch
    /// the destination. This injectable seam lets regression tests force a
    /// quarantine failure and verify that the prior bytes remain unchanged.
    static func persistAuthoritativeStoreData(
        _ data: Data,
        to destination: URL,
        storeRequiresQuarantine: Bool,
        quarantine: (URL) -> Bool
    ) throws {
        if storeRequiresQuarantine,
           FileManager.default.fileExists(atPath: destination.path),
           !quarantine(destination) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try data.write(to: destination, options: .atomic)
    }

    static func storeWriteAuthorityIsCurrent(
        _ authority: StoreWriteAuthority,
        currentProfileID: UUID,
        currentGeneration: UInt64,
        currentDestination: URL,
        currentSequence: UInt64
    ) -> Bool {
        authority.profileID == currentProfileID
            && authority.generation == currentGeneration
            && authority.destination == currentDestination
            && authority.sequence == currentSequence
    }

    static func generationAfterAuthoritativeChange(_ generation: UInt64) -> UInt64 {
        generation &+ 1
    }

    static func notificationBelongsToActiveProfile(_ notification: Notification) -> Bool {
        guard notification.name == .userRatingDataDidChange,
              let profileID = notification.userInfo?[notificationProfileIDKey] as? UUID else {
            return true
        }
        return ProfileManager.shared.isStillActive(profileID)
    }

    private func postDataDidChange(for profileID: UUID) {
        NotificationCenter.default.post(
            name: .userRatingDataDidChange,
            object: self,
            userInfo: [Self.notificationProfileIDKey: profileID]
        )
    }

    private static func normalizedStore(
        ratings: [String: Double],
        notes: [String: String]
    ) -> RatingStore {
        RatingStore(
            ratings: Dictionary(
                ratings.compactMap { key, value in
                    guard let intKey = Int(key),
                          ProgressPersistencePolicy.validPositiveIdentifier(intKey) else {
                        return nil
                    }
                    return (String(intKey), normalizedRating(value))
                },
                uniquingKeysWith: { _, incoming in incoming }
            ),
            notes: Dictionary(
                notes.compactMap { key, value in
                    guard let intKey = Int(key),
                          ProgressPersistencePolicy.validPositiveIdentifier(intKey) else {
                        return nil
                    }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    return (String(intKey), trimmed)
                },
                uniquingKeysWith: { _, incoming in incoming }
            )
        )
    }

    private static func load(from url: URL, profileID: UUID) -> StoreLoadResult {
        let markerURL = unreadableMarkerURL(for: profileID)
        let hasUnreadableMarker = FileManager.default.fileExists(atPath: markerURL.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if hasUnreadableMarker {
                do {
                    try clearUnreadableMarker(for: profileID)
                } catch {
                    return .unreadable
                }
            }
            return .loaded(ratings: [:], notes: [:])
        }
        guard !hasUnreadableMarker else {
            Logger.shared.log(
                "UserRatingManager: preserved a previously unreadable store at \(url.lastPathComponent)",
                type: "Error"
            )
            return .unreadable
        }

        let data: Data
        do {
            data = try BoundedLocalStoreReader.read(
                from: url,
                maximumBytes: maximumPersistedStoreBytes
            )
        } catch {
            markStoreUnreadable(for: profileID)
            Logger.shared.log(
                "UserRatingManager: store at \(url.lastPathComponent) could not be read: \(error.localizedDescription)",
                type: "Error"
            )
            return .unreadable
        }

        if let store = try? JSONDecoder().decode(RatingStore.self, from: data) {
            return .loaded(
                ratings: parseRatings(store.ratings),
                notes: parseNotes(store.notes)
            )
        }

        if let store = try? JSONDecoder().decode(LegacyRatingStore.self, from: data) {
            return .loaded(
                ratings: parseRatings(store.ratings.mapValues(Double.init)),
                notes: parseNotes(store.notes)
            )
        }

        if let legacyRatings = try? JSONDecoder().decode([String: Double].self, from: data) {
            return .loaded(ratings: parseRatings(legacyRatings), notes: [:])
        }

        if let legacyRatings = try? JSONDecoder().decode([String: Int].self, from: data) {
            return .loaded(ratings: parseRatings(legacyRatings.mapValues(Double.init)), notes: [:])
        }

        Logger.shared.log(
            "UserRatingManager: store at \(url.lastPathComponent) has an unsupported or corrupt format; moving it aside",
            type: "Error"
        )
        return .corrupt
    }

    static func persistedStoreSchemaIsValid(_ data: Data) -> Bool {
        guard data.count <= maximumPersistedStoreBytes else { return false }
        let decoder = JSONDecoder()
        return (try? decoder.decode(RatingStore.self, from: data)) != nil
            || (try? decoder.decode(LegacyRatingStore.self, from: data)) != nil
            || (try? decoder.decode([String: Double].self, from: data)) != nil
            || (try? decoder.decode([String: Int].self, from: data)) != nil
    }

    private static func parseRatings(_ source: [String: Double]) -> [Int: Double] {
        Dictionary(
            source.compactMap { key, value in
                guard let intKey = Int(key),
                      ProgressPersistencePolicy.validPositiveIdentifier(intKey) else {
                    return nil
                }
                return (intKey, normalizedRating(value))
            },
            uniquingKeysWith: { _, incoming in incoming }
        )
    }

    private static func parseNotes(_ source: [String: String]) -> [Int: String] {
        Dictionary(
            source.compactMap { key, value in
                guard let intKey = Int(key),
                      ProgressPersistencePolicy.validPositiveIdentifier(intKey) else {
                    return nil
                }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return (intKey, value)
            },
            uniquingKeysWith: { _, incoming in incoming }
        )
    }

    private static func normalizedRating(_ value: Double) -> Double {
        let finiteValue = value.isFinite ? value : 0.5
        let halfStepValue = (finiteValue * 2).rounded() / 2
        return max(0.5, min(10, halfStepValue))
    }
}
