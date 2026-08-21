//
//  KanzenCustomCatalog.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct KanzenCustomCatalogDigest: Equatable {
    struct Selection: Equatable {
        let title: String
        let label: String
    }

    var query: String = ""
    var selections: [Selection] = []
    var included: [String] = []
    var excluded: [String] = []
    var texts: [Selection] = []

    var isEmpty: Bool {
        query.isEmpty && selections.isEmpty && included.isEmpty && excluded.isEmpty && texts.isEmpty
    }

    var components: [String] {
        var components: [String] = []
        if !query.isEmpty { components.append("\u{201C}\(query)\u{201D}") }
        components.append(contentsOf: selections.map { "\($0.title): \($0.label)" })
        components.append(contentsOf: texts.map { "\($0.title): \($0.label)" })
        if !included.isEmpty { components.append("Include \(included.joined(separator: ", "))") }
        if !excluded.isEmpty { components.append("Exclude \(excluded.joined(separator: ", "))") }
        return components
    }
}

enum KanzenCatalogDisplayStyle: String, Codable, CaseIterable {
    case poster
    case featured
    case genres

    var displayName: String {
        switch self {
        case .poster: return "Poster Row"
        case .featured: return "Featured Banners"
        case .genres: return "Genre Cards"
        }
    }

    var summary: String {
        switch self {
        case .poster: return "A horizontal strip of cover art."
        case .featured: return "Large banner cards with the cover behind the title."
        case .genres: return "Tappable genre cards that open a filtered grid."
        }
    }

    var isQueryBacked: Bool { self != .genres }
}

struct KanzenCustomCatalog: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var sourceID: ReaderExtensionSourceID
    var query: String
    var filters: [ReaderExtensionFilter]
    var isEnabled: Bool
    var order: Int
    var displayStyle: KanzenCatalogDisplayStyle
    var presetID: String?

    init(
        id: UUID = UUID(),
        title: String,
        sourceID: ReaderExtensionSourceID,
        query: String,
        filters: [ReaderExtensionFilter],
        isEnabled: Bool = true,
        order: Int = 0,
        displayStyle: KanzenCatalogDisplayStyle = .poster,
        presetID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceID = sourceID
        self.query = query
        self.filters = filters
        self.isEnabled = isEnabled
        self.order = order
        self.displayStyle = displayStyle
        self.presetID = presetID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourceID
        case query
        case filters
        case isEnabled
        case order
        case displayStyle
        case presetID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        sourceID = try container.decode(ReaderExtensionSourceID.self, forKey: .sourceID)
        query = try container.decode(String.self, forKey: .query)
        filters = try container.decode([ReaderExtensionFilter].self, forKey: .filters)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        order = try container.decode(Int.self, forKey: .order)
        displayStyle = try container
            .decodeIfPresent(String.self, forKey: .displayStyle)
            .flatMap(KanzenCatalogDisplayStyle.init(rawValue:)) ?? .poster
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID)
    }

    var isPreset: Bool { presetID != nil }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        return Self.suggestedTitle(query: query, filters: filters)
    }

    var sectionID: String {
        "readerExtension:\(sourceID.rawValue):catalog:\(id.uuidString)"
    }

    var digest: KanzenCustomCatalogDigest {
        Self.digest(query: query, filters: filters)
    }

    var summary: String {
        guard displayStyle.isQueryBacked else {
            return "Genre cards from this source's own genre list"
        }
        let components = digest.components
        guard !components.isEmpty else { return "Everything this source returns" }
        return components.joined(separator: " \u{00b7} ")
    }

    static func suggestedTitle(query: String, filters: [ReaderExtensionFilter]) -> String {
        suggestedTitle(from: digest(query: query, filters: filters))
    }

    static func suggestedTitle(from digest: KanzenCustomCatalogDigest) -> String {
        let candidate: String
        if !digest.included.isEmpty {
            candidate = digest.included.prefix(3).joined(separator: " + ")
        } else if let selection = digest.selections.first {
            candidate = selection.label
        } else if !digest.query.isEmpty {
            candidate = digest.query
        } else if let text = digest.texts.first {
            candidate = text.label
        } else {
            return "New Catalog"
        }
        return String(candidate.prefix(48))
    }

    static func digest(query: String, filters: [ReaderExtensionFilter]) -> KanzenCustomCatalogDigest {
        var digest = KanzenCustomCatalogDigest()
        digest.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        walk(filters) { filter in
            switch filter.kind {
            case .select, .sort:
                guard !isAtDeclaredDefault(filter),
                      let index = filter.resolvedOptionIndex,
                      filter.options.indices.contains(index) else { return }
                let direction: String
                if filter.kind == .sort, let ascending = filter.sortAscending {
                    direction = ascending ? " \u{2191}" : " \u{2193}"
                } else {
                    direction = ""
                }
                digest.selections.append(
                    .init(title: filter.title, label: "\(filter.options[index].label)\(direction)")
                )
            case .toggle:
                if case .bool(true) = filter.value { digest.included.append(filter.title) }
            case .triState:
                guard case .number(let state) = filter.value else { return }
                if state == 1 { digest.included.append(filter.title) }
                if state == 2 { digest.excluded.append(filter.title) }
            case .text:
                guard case .string(let text) = filter.value else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { digest.texts.append(.init(title: filter.title, label: trimmed)) }
            case .group, .header, .separator:
                break
            }
        }
        return digest
    }

    private static func walk(
        _ filters: [ReaderExtensionFilter],
        depth: Int = 0,
        visit: (ReaderExtensionFilter) -> Void
    ) {
        guard depth < 8 else { return }
        for filter in filters {
            visit(filter)
            walk(filter.children, depth: depth + 1, visit: visit)
        }
    }

    private static func isAtDeclaredDefault(_ filter: ReaderExtensionFilter) -> Bool {
        guard let index = filter.resolvedOptionIndex else { return true }
        switch filter.abiState {
        case .number(let declared):
            return Int(exactly: declared) == index
        case .object(let declared):
            guard case .number(let declaredIndex)? = declared["index"],
                  Int(exactly: declaredIndex) == index else {
                return false
            }
            guard case .bool(let declaredAscending)? = declared["ascending"] else { return true }
            return declaredAscending == (filter.sortAscending ?? false)
        default:
            return false
        }
    }
}

enum KanzenCustomCatalogError: LocalizedError, Equatable {
    case sourceLimitReached(Int)
    case filterSetTooLarge
    case notEditableFromKidsProfile

    var errorDescription: String? {
        switch self {
        case .sourceLimitReached(let limit):
            return "A source can hold at most \(limit) custom catalogs. Delete one before saving another."
        case .filterSetTooLarge:
            return "This source's filter selection is too large to save as a catalog."
        case .notEditableFromKidsProfile:
            return "Custom catalogs cannot be changed from a kids profile."
        }
    }
}

final class KanzenCustomCatalogManager: ObservableObject {
    static let shared = KanzenCustomCatalogManager()

    static let maximumCatalogsPerSource = 12
    static let maximumEncodedCatalogBytes = 512 * 1_024
    static let maximumTitleLength = 80

    @Published private(set) var catalogs: [KanzenCustomCatalog] = []

    private static let baseStorageKey = "kanzenCustomCatalogs"

    private let userDefaults: UserDefaults
    private var storageKey: String
    private var activeProfileID: UUID

    private convenience init() {
        self.init(defaults: .standard, profileID: ProfileManager.shared.activeProfileID)
    }

    init(defaults: UserDefaults, profileID: UUID) {
        userDefaults = defaults
        activeProfileID = profileID
        storageKey = Self.storageKey(for: profileID)
        catalogs = Self.adopt(forKey: storageKey, defaults: defaults)
    }

    static func storageKey(for profileID: UUID) -> String {
        ProfileScopedStorage.defaultsKey(base: baseStorageKey, profileID: profileID)
    }

    func switchProfile(to profileID: UUID) {
        guard profileID != activeProfileID else { return }
        activeProfileID = profileID
        storageKey = Self.storageKey(for: profileID)
        catalogs = Self.adopt(forKey: storageKey, defaults: userDefaults)
    }

    func discardStore(forProfile profileID: UUID) {
        guard profileID != activeProfileID else { return }
        userDefaults.removeObject(forKey: Self.storageKey(for: profileID))
    }

    func catalogsSnapshot(forProfile profileID: UUID) -> [KanzenCustomCatalog]? {
        let key = profileID == activeProfileID ? storageKey : Self.storageKey(for: profileID)
        guard let data = userDefaults.data(forKey: key) else {
            return []
        }
        guard let decoded = try? JSONDecoder().decode([KanzenCustomCatalog].self, from: data) else {
            ReaderLogger.shared.log(
                "KanzenCustomCatalogManager: profile \(profileID) has an unreadable custom catalog store; preserving its bytes",
                type: "Error"
            )
            return nil
        }
        return decoded.sorted { $0.order < $1.order }
    }

    func applyRestoredCatalogs(_ restored: [KanzenCustomCatalog], forProfile profileID: UUID) {
        guard profileID != activeProfileID else {
            catalogs = restored.sorted { $0.order < $1.order }
            persist()
            return
        }
        guard let data = try? JSONEncoder().encode(restored) else { return }
        userDefaults.set(data, forKey: Self.storageKey(for: profileID))
    }

    func catalogs(for sourceID: ReaderExtensionSourceID) -> [KanzenCustomCatalog] {
        catalogs
            .filter { $0.sourceID == sourceID }
            .sorted { $0.order < $1.order }
    }

    func enabledCatalogs(for sourceID: ReaderExtensionSourceID) -> [KanzenCustomCatalog] {
        catalogs(for: sourceID).filter(\.isEnabled)
    }

    func canAddCatalog(for sourceID: ReaderExtensionSourceID) -> Bool {
        var held = 0
        for catalog in catalogs where catalog.sourceID == sourceID {
            held += 1
            if held >= Self.maximumCatalogsPerSource { return false }
        }
        return true
    }

    func catalog(forPresetID presetID: String, sourceID: ReaderExtensionSourceID) -> KanzenCustomCatalog? {
        catalogs.first { $0.sourceID == sourceID && $0.presetID == presetID }
    }

    func presetIDs(for sourceID: ReaderExtensionSourceID) -> Set<String> {
        var identifiers: Set<String> = []
        for catalog in catalogs where catalog.sourceID == sourceID {
            guard let presetID = catalog.presetID else { continue }
            identifiers.insert(presetID)
        }
        return identifiers
    }

    @discardableResult
    func save(_ catalog: KanzenCustomCatalog) throws -> KanzenCustomCatalog {
        guard !ProfileManager.shared.isKidsModeActive else {
            throw KanzenCustomCatalogError.notEditableFromKidsProfile
        }

        var stored = catalog
        stored.title = String(
            catalog.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumTitleLength)
        )
        stored.query = catalog.query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let encoded = try? JSONEncoder().encode(stored),
              encoded.count <= Self.maximumEncodedCatalogBytes else {
            throw KanzenCustomCatalogError.filterSetTooLarge
        }

        if let index = catalogs.firstIndex(where: { $0.id == stored.id }) {
            stored.order = catalogs[index].order
            catalogs[index] = stored
        } else {
            guard canAddCatalog(for: stored.sourceID) else {
                throw KanzenCustomCatalogError.sourceLimitReached(Self.maximumCatalogsPerSource)
            }
            stored.order = (catalogs.map(\.order).max() ?? -1) + 1
            catalogs.append(stored)
        }

        persist()
        return stored
    }

    func remove(id: UUID) {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        guard catalogs.contains(where: { $0.id == id }) else { return }
        catalogs.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ isEnabled: Bool, id: UUID) {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        guard let index = catalogs.firstIndex(where: { $0.id == id }),
              catalogs[index].isEnabled != isEnabled else { return }
        catalogs[index].isEnabled = isEnabled
        persist()
    }

    func move(from offsets: IndexSet, to destination: Int, within sourceID: ReaderExtensionSourceID) {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        var ordered = catalogs(for: sourceID)
        guard !ordered.isEmpty else { return }
        ordered.move(fromOffsets: offsets, toOffset: destination)

        let orderSlots = catalogs
            .filter { $0.sourceID == sourceID }
            .map(\.order)
            .sorted()
        for (slot, catalog) in zip(orderSlots, ordered) {
            guard let index = catalogs.firstIndex(where: { $0.id == catalog.id }) else { continue }
            catalogs[index].order = slot
        }
        catalogs.sort { $0.order < $1.order }
        persist()
    }

    /// Deliberately synchronous. Deferring the write onto a serial queue meant
    /// `adopt` had to drain it with `persistQueue.sync`, so constructing a
    /// second manager from the main thread deadlocked against a write in
    /// flight. Encoding a handful of catalogs costs microseconds and was never
    /// the source of the screen's lag — the per-body-pass digest walks were.
    private func persist() {
        guard let data = try? JSONEncoder().encode(catalogs) else {
            ReaderLogger.shared.log(
                "KanzenCustomCatalogManager: refusing to persist an unencodable catalog set",
                type: "Error"
            )
            return
        }
        userDefaults.set(data, forKey: storageKey)
    }

    private static func adopt(forKey key: String, defaults: UserDefaults) -> [KanzenCustomCatalog] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let decoded = try? JSONDecoder().decode([KanzenCustomCatalog].self, from: data) else {
            quarantineUnreadableStore(forKey: key, defaults: defaults)
            return []
        }
        return decoded.sorted { $0.order < $1.order }
    }

    private static func quarantineUnreadableStore(forKey key: String, defaults: UserDefaults) {
        guard let data = defaults.data(forKey: key) else { return }
        let quarantineKey = "\(key)-unreadable-\(Int(Date().timeIntervalSince1970))"
        defaults.set(data, forKey: quarantineKey)
        defaults.removeObject(forKey: key)
        ReaderLogger.shared.log(
            "KanzenCustomCatalogManager: moved an unreadable catalog store aside as \(quarantineKey) and started a fresh store",
            type: "Error"
        )
    }
}
