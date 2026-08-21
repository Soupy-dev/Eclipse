import Foundation
import Combine

enum CatalogOrientationOverride: String, Codable, CaseIterable, Identifiable {
    case global
    case automatic
    case landscape
    case poster

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .global: return "Global"
        case .automatic: return "Automatic"
        case .landscape: return "Landscape"
        case .poster: return "Poster"
        }
    }

    var cardShape: ExperimentalHomeCardShape? {
        switch self {
        case .global: return nil
        case .automatic: return .automatic
        case .landscape: return .landscape
        case .poster: return .poster
        }
    }

    init(cardShape: ExperimentalHomeCardShape) {
        switch cardShape {
        case .automatic: self = .automatic
        case .landscape: self = .landscape
        case .poster: self = .poster
        }
    }
}

struct CatalogLayoutOverride: Codable, Equatable {
    var orientation: CatalogOrientationOverride = .global

    var sizeScale: Double? = nil

    var isEmpty: Bool { orientation == .global && sizeScale == nil }

    static let empty = CatalogLayoutOverride()
}

final class HomeCatalogLayoutStore: ObservableObject {
    static let shared = HomeCatalogLayoutStore()

    static let storageKey = "homeCatalogLayoutOverrides"

    static let sizeRange: ClosedRange<Double> = 0.75...1.35

    @Published private var overrides: [String: CatalogLayoutOverride]

    private var userDefaults: UserDefaults { ProfileSettingsStore.active }

    private init() {
        self.overrides = Self.load(from: ProfileSettingsStore.active)
    }

    func reloadForActiveProfile() {
        reloadFromStorage()
    }

    func override(for id: String) -> CatalogLayoutOverride {
        overrides[id] ?? .empty
    }

    func hasOverride(for id: String) -> Bool {
        guard let value = overrides[id] else { return false }
        return !value.isEmpty
    }

    func setOrientation(_ orientation: CatalogOrientationOverride, for id: String) {
        var value = override(for: id)
        value.orientation = orientation
        store(value, for: id)
    }

    func setSizeScale(_ scale: Double?, for id: String) {
        var value = override(for: id)
        if let scale {
            value.sizeScale = min(max(scale, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        } else {
            value.sizeScale = nil
        }
        store(value, for: id)
    }

    func reset(id: String) {
        guard overrides[id] != nil else { return }
        overrides.removeValue(forKey: id)
        persist()
    }

    func resetAll() {
        guard !overrides.isEmpty else { return }
        overrides.removeAll()
        persist()
    }

    func reloadFromStorage() {
        let loaded = Self.load(from: userDefaults)
        if Thread.isMainThread {
            overrides = loaded
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.overrides = loaded
            }
        }
    }

    private func store(_ value: CatalogLayoutOverride, for id: String) {
        if value.isEmpty {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = value
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(overrides) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }

    private static func load(from userDefaults: UserDefaults) -> [String: CatalogLayoutOverride] {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: CatalogLayoutOverride].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
