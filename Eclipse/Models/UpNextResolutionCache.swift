import Foundation

final class UpNextResolutionCache: @unchecked Sendable {
    static let shared = UpNextResolutionCache()

    struct Resolution: Codable {

        let seasonNumber: Int?
        let episodeNumber: Int?
        let playbackContext: EpisodePlaybackContext?
        let resolvedAt: Date

        var hasTarget: Bool { seasonNumber != nil && episodeNumber != nil }

        fileprivate var sanitizedForPersistence: Resolution? {
            let timestamp = resolvedAt.timeIntervalSince1970
            guard timestamp.isFinite,
                  timestamp >= 0,
                  timestamp <= Date().timeIntervalSince1970
                    + MediaStateEnvelopeValidator.maximumFutureClockSkew else {
                return nil
            }
            if seasonNumber == nil || episodeNumber == nil {
                guard seasonNumber == nil, episodeNumber == nil else { return nil }
                return Resolution(
                    seasonNumber: nil,
                    episodeNumber: nil,
                    playbackContext: nil,
                    resolvedAt: resolvedAt
                )
            }
            guard let seasonNumber,
                  let episodeNumber,
                  (0...ProgressPersistencePolicy.maximumCoordinate).contains(seasonNumber),
                  (1...ProgressPersistencePolicy.maximumCoordinate).contains(episodeNumber) else {
                return nil
            }
            return Resolution(
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                playbackContext: playbackContext.flatMap {
                    ProgressPersistencePolicy.sanitizedPlaybackContext(
                        $0,
                        expectedLocalEpisodeNumber: episodeNumber
                    )
                },
                resolvedAt: resolvedAt
            )
        }
    }

    private struct Store: Codable {
        var entries: [String: Resolution] = [:]
    }

    private static let positiveTTL: TimeInterval = 7 * 24 * 60 * 60

    private static let negativeTTL: TimeInterval = 12 * 60 * 60
    private static let maximumEntryCount = 300
    static let maximumPersistedStoreBytes = 2 * 1_024 * 1_024

    private let lock = NSLock()
    private var store = Store()
    private var loadedProfileID: UUID?
    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "app.eclipse.soupy.upnext-cache")

    private init() {}

    static func key(showId: Int, seasonNumber: Int, episodeNumber: Int) -> String {
        "\(showId):\(seasonNumber):\(episodeNumber)"
    }

    func resolution(forKey key: String, profile profileID: UUID) -> Resolution? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked(forProfile: profileID)
        guard let entry = store.entries[key], !Self.isExpired(entry) else { return nil }
        return entry
    }

    func store(_ resolution: Resolution, forKey key: String, profile profileID: UUID) {
        guard Self.keyIsValid(key),
              let sanitized = resolution.sanitizedForPersistence else { return }
        lock.lock()
        loadIfNeededLocked(forProfile: profileID)
        store.entries[key] = sanitized
        pruneLocked()
        lock.unlock()
        scheduleSave()
    }

    func discardStore(forProfile profileID: UUID) {
        lock.lock()
        if loadedProfileID == profileID {
            saveWorkItem?.cancel()
            saveWorkItem = nil
            loadedProfileID = nil
            store = Store()
        }
        lock.unlock()
        try? FileManager.default.removeItem(at: Self.fileURL(for: profileID))
    }

    private static let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    private static func fileURL(for profileID: UUID) -> URL {
        documentsDirectory.appendingPathComponent(
            ProfileScopedStorage.documentFileName(
                base: "UpNextResolutions",
                fileExtension: "json",
                profileID: profileID
            )
        )
    }

    private func loadIfNeededLocked(forProfile profileID: UUID) {
        guard loadedProfileID != profileID else { return }

        loadedProfileID = profileID
        store = Store()

        let url = Self.fileURL(for: profileID)
        guard let data = try? BoundedLocalStoreReader.read(
            from: url,
            maximumBytes: Self.maximumPersistedStoreBytes
        ) else { return }
        guard let decoded = try? JSONDecoder().decode(Store.self, from: data) else {
            Logger.shared.log("UpNextResolutionCache: dropping unreadable store", type: "Error")
            return
        }
        store = decoded
        store.entries = Dictionary(
            uniqueKeysWithValues: store.entries.compactMap { key, value in
                guard Self.keyIsValid(key),
                      let sanitized = value.sanitizedForPersistence,
                      !Self.isExpired(sanitized) else { return nil }
                return (key, sanitized)
            }
        )
        pruneLocked()
    }

    private static func isExpired(_ resolution: Resolution) -> Bool {
        let ttl = resolution.hasTarget ? positiveTTL : negativeTTL
        return Date().timeIntervalSince(resolution.resolvedAt) >= ttl
    }

    private static func keyIsValid(_ key: String) -> Bool {
        let components = key.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              let showID = Int(components[0]),
              let seasonNumber = Int(components[1]),
              let episodeNumber = Int(components[2]) else { return false }
        return ProgressPersistencePolicy.validPositiveIdentifier(showID)
            && (0...ProgressPersistencePolicy.maximumCoordinate).contains(seasonNumber)
            && (1...ProgressPersistencePolicy.maximumCoordinate).contains(episodeNumber)
    }

    private func pruneLocked() {
        store.entries = store.entries.filter { !Self.isExpired($0.value) }
        guard store.entries.count > Self.maximumEntryCount else { return }
        let survivors = store.entries
            .sorted { $0.value.resolvedAt > $1.value.resolvedAt }
            .prefix(Self.maximumEntryCount)
        store.entries = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    private func scheduleSave() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.save()
        }
        lock.lock()
        saveWorkItem?.cancel()
        saveWorkItem = workItem
        lock.unlock()
        saveQueue.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func save() {
        lock.lock()
        let profileID = loadedProfileID
        let snapshot = store
        lock.unlock()

        guard let profileID else { return }
        write(snapshot, forProfile: profileID)
    }

    private func write(_ snapshot: Store, forProfile profileID: UUID) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= Self.maximumPersistedStoreBytes else {
                Logger.shared.log("UpNextResolutionCache: refused oversized save", type: "Error")
                return
            }
            try data.write(to: Self.fileURL(for: profileID), options: .atomic)
        } catch {
            Logger.shared.log(
                "UpNextResolutionCache: save failed: \(error.localizedDescription)",
                type: "Error"
            )
        }
    }

    func flushPendingWrites(forProfile outgoing: UUID) {
        lock.lock()
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let owns = loadedProfileID == outgoing
        let snapshot = store
        lock.unlock()

        guard owns else { return }
        write(snapshot, forProfile: outgoing)
    }

    func switchProfile(to profileID: UUID) {
        lock.lock()
        saveWorkItem?.cancel()
        saveWorkItem = nil
        loadedProfileID = nil
        store = Store()
        lock.unlock()
    }
}
