import Foundation

final class ProfileSettingsStore {
    static let shared = ProfileSettingsStore()

    static var active: UserDefaults { shared.activeStore }

    static var device: UserDefaults { .standard }

    static var services: UserDefaults { sharesServices ? .standard : active }

    private static let sharesServicesKey = "eclipseSharesServicesAcrossProfilesV1"

    static var sharesServices: Bool {
        get { UserDefaults.standard.object(forKey: sharesServicesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: sharesServicesKey) }
    }

    private let lock = NSLock()
    private var cachedStores: [UUID: UserDefaults] = [:]
    private var currentStore: UserDefaults

    private init() {

        let id = ProfileManager.launchActiveProfileID
        let store = Self.makeStore(for: id)
        currentStore = store
        cachedStores[id] = store
    }

    var activeStore: UserDefaults {
        lock.lock()
        defer { lock.unlock() }
        return currentStore
    }

    func switchProfile(to id: UUID) {
        let store = store(for: id)
        lock.lock()
        currentStore = store
        lock.unlock()
    }

    func store(for id: UUID) -> UserDefaults {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedStores[id] {
            return cached
        }
        let store = Self.makeStore(for: id)
        cachedStores[id] = store
        return store
    }

    func discardStore(forProfile id: UUID) {
        guard id != ProfileManager.defaultProfileID else { return }
        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName(for: id))
        lock.lock()
        cachedStores[id] = nil
        lock.unlock()
    }

    func hasExplicitValue(forKey key: String, profile id: UUID) -> Bool {
        let domainName = id == ProfileManager.defaultProfileID
            ? (Bundle.main.bundleIdentifier ?? "app.Eclipse")
            : Self.suiteName(for: id)
        return UserDefaults.standard.persistentDomain(forName: domainName)?[key] != nil
    }

    private static func makeStore(for id: UUID) -> UserDefaults {

        guard id != ProfileManager.defaultProfileID else { return .standard }
        return UserDefaults(suiteName: suiteName(for: id)) ?? .standard
    }

    static func suiteName(for id: UUID) -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.Eclipse"
        return "\(bundleID).profile.\(id.uuidString)"
    }
}
