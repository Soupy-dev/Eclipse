import Foundation
import Combine
import SwiftUI

struct MangaCatalog: Identifiable, Codable, Equatable {
    let id: String
    var title: String?
    var type: String?
    var manifestURL: String?
    var name: String
    var source: String
    var isEnabled: Bool
    var order: Int
    var displayStyle: String

    var displayName: String {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty { return candidate }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return id
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case type
        case manifestURL = "manifestUrl"
        case legacyManifestURL = "manifestURL"
        case name
        case source
        case isEnabled
        case order
        case displayStyle
    }

    init(
        id: String,
        title: String? = nil,
        type: String? = nil,
        manifestURL: String? = nil,
        name: String? = nil,
        source: String? = nil,
        isEnabled: Bool = true,
        order: Int = 0,
        displayStyle: String = "standard"
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.manifestURL = manifestURL
        self.name = name ?? title ?? id
        self.source = source ?? type ?? "Local"
        self.isEnabled = isEnabled
        self.order = order
        self.displayStyle = displayStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)
        let decodedType = try container.decodeIfPresent(String.self, forKey: .type)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
        let decodedSource = try container.decodeIfPresent(String.self, forKey: .source)
        let decodedManifestURL = try container.decodeIfPresent(String.self, forKey: .manifestURL)
            ?? container.decodeIfPresent(String.self, forKey: .legacyManifestURL)

        self.init(
            id: decodedId,
            title: decodedTitle,
            type: decodedType,
            manifestURL: decodedManifestURL,
            name: decodedName,
            source: decodedSource,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            order: try container.decodeIfPresent(Int.self, forKey: .order) ?? 0,
            displayStyle: try container.decodeIfPresent(String.self, forKey: .displayStyle) ?? "standard"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(manifestURL, forKey: .manifestURL)
        try container.encode(name, forKey: .name)
        try container.encode(source, forKey: .source)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(order, forKey: .order)
        try container.encode(displayStyle, forKey: .displayStyle)
    }
}

final class MangaCatalogManager {
    static let shared = MangaCatalogManager()

    var catalogs: [MangaCatalog] = []

    private let userDefaults = UserDefaults.standard
    private let catalogsKey = "kanzenMangaCatalogs"

    private init() {
        loadCatalogs()
    }

    func loadCatalogs() {
        guard let data = userDefaults.data(forKey: catalogsKey),
              let decoded = try? JSONDecoder().decode([MangaCatalog].self, from: data) else {
            catalogs = []
            return
        }
        catalogs = decoded.sorted { $0.order < $1.order }
    }

    func saveCatalogs() {
        if let data = try? JSONEncoder().encode(catalogs) {
            userDefaults.set(data, forKey: catalogsKey)
        }
    }

    func getEnabledCatalogs() -> [MangaCatalog] {
        catalogs
            .filter(\.isEnabled)
            .sorted { $0.order < $1.order }
    }

    func toggleCatalog(id: String) {
        guard let index = catalogs.firstIndex(where: { $0.id == id }) else { return }
        catalogs[index].isEnabled.toggle()
        saveCatalogs()
    }

    func moveCatalog(from offsets: IndexSet, to destination: Int) {
        catalogs.move(fromOffsets: offsets, toOffset: destination)
        for index in catalogs.indices {
            catalogs[index].order = index
        }
        saveCatalogs()
    }
}

enum MangaHomeSourceKind: String, Codable {
    case aidoku
    case legacyModule
}

struct MangaHomeSource: Identifiable, Equatable {
    let id: String
    let name: String
    let iconURL: String
    let kind: MangaHomeSourceKind
    let aidokuSource: AidokuInstalledSource?
    let module: ModuleDataContainer?
    var isEnabled: Bool
    var order: Int

    var isAidoku: Bool { kind == .aidoku }
    var isLegacyModule: Bool { kind == .legacyModule }

    var sourceId: String? {
        aidokuSource?.id
    }

    var moduleUUID: UUID? {
        module?.id
    }

    static func aidoku(_ source: AidokuInstalledSource, order: Int) -> MangaHomeSource {
        MangaHomeSource(
            id: "aidoku:\(source.id)",
            name: source.name,
            iconURL: source.iconURLString,
            kind: .aidoku,
            aidokuSource: source,
            module: nil,
            isEnabled: source.isEnabled,
            order: order
        )
    }

    static func legacyModule(_ module: ModuleDataContainer, preference: MangaHomeSourcePreference, orderOffset: Int) -> MangaHomeSource {
        MangaHomeSource(
            id: "module:\(module.id.uuidString)",
            name: module.moduleData.sourceName,
            iconURL: module.moduleData.iconURL,
            kind: .legacyModule,
            aidokuSource: nil,
            module: module,
            isEnabled: preference.isEnabled,
            order: orderOffset + preference.order
        )
    }
}

struct MangaHomeSourcePreference: Codable {
    var isEnabled: Bool
    var order: Int
}

final class MangaHomeSourceManager: ObservableObject {
    static let shared = MangaHomeSourceManager()

    @Published private var legacyPreferences: [String: MangaHomeSourcePreference] = [:]

    private let storageKey = "kanzenLegacyHomeSourcePreferences"

    private init() {
        loadPreferences()
    }

    func refreshSources(from modules: [ModuleDataContainer]) {
        reconcile(modules: legacyMangaModules(from: modules))
    }

    @MainActor
    func allSources(
        aidokuManager: AidokuSourceManager,
        modules: [ModuleDataContainer],
        includeDisabledAidoku: Bool = true
    ) -> [MangaHomeSource] {
        let aidokuMetadata = includeDisabledAidoku
            ? aidokuManager.installedSources.filter { aidokuManager.showMatureSources || !$0.isMature }
            : aidokuManager.enabledSources()

        let aidokuSources = aidokuMetadata
            .sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .enumerated()
            .map { index, source in
                MangaHomeSource.aidoku(source, order: index)
            }

        // Home feeds are Aidoku-only. Legacy JS modules remain available through
        // compatibility routes, but they do not expose reliable home sections.
        return aidokuSources
    }

    @MainActor
    func enabledSources(
        aidokuManager: AidokuSourceManager,
        modules: [ModuleDataContainer]
    ) -> [MangaHomeSource] {
        allSources(aidokuManager: aidokuManager, modules: modules, includeDisabledAidoku: false)
            .filter(\.isEnabled)
    }

    func legacySources(from modules: [ModuleDataContainer], orderOffset: Int = 0) -> [MangaHomeSource] {
        let sourceModules = legacyMangaModules(from: modules)

        return sourceModules.map { module in
            let key = module.id.uuidString
            let preference = legacyPreferences[key] ?? MangaHomeSourcePreference(
                isEnabled: true,
                order: defaultOrder(for: module, in: sourceModules)
            )

            return MangaHomeSource.legacyModule(module, preference: preference, orderOffset: orderOffset)
        }
        .sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func toggleLegacySource(id: String) {
        let key = normalizedLegacyKey(id)
        var preference = legacyPreferences[key] ?? MangaHomeSourcePreference(
            isEnabled: true,
            order: legacyPreferences.count
        )
        preference.isEnabled.toggle()
        legacyPreferences[key] = preference
        savePreferences()
    }

    func moveLegacySource(from offsets: IndexSet, to destination: Int, modules: [ModuleDataContainer]) {
        var orderedIds = legacySources(from: modules).compactMap(\.moduleUUID).map(\.uuidString)
        orderedIds.move(fromOffsets: offsets, toOffset: destination)

        for (index, id) in orderedIds.enumerated() {
            var preference = legacyPreferences[id] ?? MangaHomeSourcePreference(isEnabled: true, order: index)
            preference.order = index
            legacyPreferences[id] = preference
        }

        savePreferences()
    }

    private func legacyMangaModules(from modules: [ModuleDataContainer]) -> [ModuleDataContainer] {
        modules.filter { $0.moduleData.novel != true }
    }

    private func reconcile(modules: [ModuleDataContainer]) {
        let validIds = Set(modules.map { $0.id.uuidString })
        var changed = false

        for key in legacyPreferences.keys where !validIds.contains(key) {
            legacyPreferences.removeValue(forKey: key)
            changed = true
        }

        for (index, module) in modules.enumerated() {
            let key = module.id.uuidString
            if legacyPreferences[key] == nil {
                legacyPreferences[key] = MangaHomeSourcePreference(isEnabled: true, order: index)
                changed = true
            }
        }

        if changed {
            savePreferences()
        }
    }

    private func defaultOrder(for module: ModuleDataContainer, in modules: [ModuleDataContainer]) -> Int {
        modules.firstIndex(where: { $0.id == module.id }) ?? legacyPreferences.count
    }

    private func normalizedLegacyKey(_ id: String) -> String {
        id.replacingOccurrences(of: "module:", with: "")
    }

    private func loadPreferences() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([String: MangaHomeSourcePreference].self, from: data)
        else {
            if let oldData = UserDefaults.standard.data(forKey: "kanzenHomeSourcePreferences"),
               let oldDecoded = try? JSONDecoder().decode([String: MangaHomeSourcePreference].self, from: oldData) {
                legacyPreferences = oldDecoded
            }
            return
        }

        legacyPreferences = decoded
    }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(legacyPreferences) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        objectWillChange.send()
    }
}
