import Foundation

final class UpNextResolutionCache: @unchecked Sendable {
    static let shared = UpNextResolutionCache()

    struct Resolution: Codable {

        let seasonNumber: Int?
        let episodeNumber: Int?
        let playbackContext: EpisodePlaybackContext?
        let resolvedAt: Date

        var hasTarget: Bool { seasonNumber != nil && episodeNumber != nil }
    }

    private struct Store: Codable {
        var entries: [String: Resolution] = [:]
    }

    private static let positiveTTL: TimeInterval = 7 * 24 * 60 * 60

    private static let negativeTTL: TimeInterval = 12 * 60 * 60
    private static let maximumEntryCount = 300

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
        lock.lock()
        loadIfNeededLocked(forProfile: profileID)
        store.entries[key] = resolution
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
        guard let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode(Store.self, from: data) else {
            Logger.shared.log("UpNextResolutionCache: dropping unreadable store", type: "Error")
            return
        }
        store = decoded
        store.entries = store.entries.filter { !Self.isExpired($0.value) }
    }

    private static func isExpired(_ resolution: Resolution) -> Bool {
        let ttl = resolution.hasTarget ? positiveTTL : negativeTTL
        return Date().timeIntervalSince(resolution.resolvedAt) >= ttl
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
