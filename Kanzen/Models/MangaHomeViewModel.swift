//
//  MangaHomeViewModel.swift
//  Kanzen
//
//  Created by Eclipse on 2025.
//

import Foundation
import SwiftUI

enum MangaHomeSectionKind: String, Codable {
    case genres
    case hotUpdates
    case latestUpdates
    case popular
    case custom

    static func from(_ value: String?, title: String) -> MangaHomeSectionKind {
        let normalized = (value ?? title)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        if normalized.contains("genre") || normalized.contains("tag") { return .genres }
        if normalized.contains("hot") { return .hotUpdates }
        if normalized.contains("latest") || normalized.contains("recent") || normalized.contains("update") { return .latestUpdates }
        if normalized.contains("popular") || normalized.contains("trend") { return .popular }
        return .custom
    }
}

struct MangaHomeItem: Identifiable, Equatable {
    let id: String
    let title: String
    let imageURL: String
    let params: String
    let subtitle: String?

    let tags: [String]?
    let isContainer: Bool
    let route: MangaContentRoute?
    let readerExtensionItem: ReaderExtensionItem?
    let readerExtensionQuery: MangaHomeSection.ReaderExtensionQuery?

    init?(
        dict: [String: Any],
        module: ModuleDataContainer,
        sectionKind: MangaHomeSectionKind
    ) {
        let title = Self.string(from: dict, keys: ["title", "name", "label"])
        let params = Self.string(from: dict, keys: ["params", "id", "href", "url", "link"])

        guard let title, !title.isEmpty else { return nil }

        let resolvedParams = params?.isEmpty == false ? params! : title
        self.title = title
        self.params = resolvedParams
        self.imageURL = Self.string(from: dict, keys: ["imageURL", "imageUrl", "image", "cover", "coverURL", "poster"]) ?? ""
        self.subtitle = Self.string(from: dict, keys: ["subtitle", "chapter", "episode", "description", "latest"])
        self.tags = Self.stringArray(from: dict, keys: ["tags", "genres", "genre"])

        let rawType = Self.string(from: dict, keys: ["type", "kind"])
        let normalizedType = rawType?.lowercased() ?? ""
        self.isContainer = sectionKind == .genres
            || normalizedType == "genre"
            || normalizedType == "section"
            || normalizedType == "category"

        self.route = .legacyModule(
            moduleUUID: module.id.uuidString,
            contentParams: resolvedParams,
            isNovel: module.moduleData.novel == true
        )
        self.readerExtensionItem = nil
        self.readerExtensionQuery = nil
        self.id = "module:\(module.id.uuidString):\(resolvedParams):\(title)"
    }

    init(
        sourceID: ReaderExtensionSourceID,
        item: ReaderExtensionItem,
        subtitle: String? = nil,
        idSuffix _: String = ""
    ) {
        self.title = item.title
        self.imageURL = item.coverURL?.absoluteString ?? ""
        self.params = item.key
        self.subtitle = subtitle ?? item.author
        self.tags = item.tags
        self.isContainer = false
        self.route = .readerExtension(source: sourceID, itemKey: item.key, legacyStableKey: nil)
        self.readerExtensionItem = item
        self.readerExtensionQuery = nil
        self.id = "readerExtension:\(sourceID.rawValue):item:\(item.key)"
    }

    init(genreOption: KanzenCatalogGenreOption, sectionID: String, query: String) {
        self.title = genreOption.label
        self.imageURL = ""
        self.params = genreOption.identifier
        self.subtitle = nil
        self.tags = nil
        self.isContainer = true
        self.route = nil
        self.readerExtensionItem = nil
        self.readerExtensionQuery = .search(query: query, filters: genreOption.filters)
        self.id = "\(sectionID):genre:\(genreOption.identifier):\(genreOption.label)"
    }

    private static func string(from dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = dict[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = dict[key] as? NSNumber {
                return number.stringValue
            }
            if let value = dict[key], !(value is NSNull) {
                let string = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !string.isEmpty { return string }
            }
        }
        return nil
    }

    private static func stringArray(from dict: [String: Any], keys: [String]) -> [String]? {
        for key in keys {
            guard let values = dict[key] as? [Any] else { continue }
            let strings = values.compactMap { value -> String? in
                if value is NSNull { return nil }
                let string = (value as? String) ?? String(describing: value)
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if !strings.isEmpty { return strings }
        }
        return nil
    }
}

struct MangaHomeSection: Identifiable, Equatable {
    enum ReaderExtensionQuery: Equatable {
        case popular
        case latest
        case search(query: String, filters: [ReaderExtensionFilter])
    }

    let id: String
    let title: String
    let kind: MangaHomeSectionKind
    var items: [MangaHomeItem]
    let readerExtensionQuery: ReaderExtensionQuery?
    /// Only custom catalogs are published with no items — the user asked for
    /// that row by name, so an empty or failed load has to say so instead of
    /// silently disappearing the way Popular and Latest do.
    let placeholderMessage: String?
    let displayStyle: KanzenCatalogDisplayStyle

    init?(dict: [String: Any], module: ModuleDataContainer) {
        guard
            let title = Self.string(from: dict, keys: ["title", "name", "label"]),
            !title.isEmpty
        else { return nil }

        let rawKind = Self.string(from: dict, keys: ["kind", "type"])
        let kind = MangaHomeSectionKind.from(rawKind, title: title)
        let sectionId = Self.string(from: dict, keys: ["id", "sectionId", "href", "params", "slug"]) ?? Self.slug(title)
        let rawItems = Self.array(from: dict, keys: ["items", "data", "results", "manga", "entries", "list"])

        self.id = "module:\(module.id.uuidString):section:\(sectionId)"
        self.title = title
        self.kind = kind
        self.items = ReaderContentFilter.shared.filterHomeItems(
            rawItems
                .compactMap { MangaHomeItem(dict: $0, module: module, sectionKind: kind) }
                .prefix(MangaHomeViewModel.maxRetainedItemsPerSection)
                .map { $0 }
        )
        self.readerExtensionQuery = nil
        self.placeholderMessage = nil
        self.displayStyle = .poster
    }

    static func section(
        title: String,
        id: String,
        kind: MangaHomeSectionKind,
        items: [MangaHomeItem],
        readerExtensionQuery: ReaderExtensionQuery? = nil,
        placeholderMessage: String? = nil,
        displayStyle: KanzenCatalogDisplayStyle = .poster
    ) -> MangaHomeSection {
        MangaHomeSection(
            id: id,
            title: title,
            kind: kind,
            items: items,
            readerExtensionQuery: readerExtensionQuery,
            placeholderMessage: placeholderMessage,
            displayStyle: displayStyle
        )
    }

    private init(
        id: String,
        title: String,
        kind: MangaHomeSectionKind,
        items: [MangaHomeItem],
        readerExtensionQuery: ReaderExtensionQuery?,
        placeholderMessage: String?,
        displayStyle: KanzenCatalogDisplayStyle
    ) {
        self.id = id
        self.title = title
        self.kind = kind

        self.items = ReaderContentFilter.shared.filterHomeItems(items)
        self.readerExtensionQuery = readerExtensionQuery
        self.placeholderMessage = placeholderMessage
        self.displayStyle = displayStyle
    }

    private static func string(from dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = dict[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = dict[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func array(from dict: [String: Any], keys: [String]) -> [[String: Any]] {
        for key in keys {
            if let array = dict[key] as? [[String: Any]] {
                return array
            }
            if let array = dict[key] as? [Any] {
                return array.compactMap { $0 as? [String: Any] }
            }
        }
        return []
    }

    static func slug(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

enum MangaHomeLoadState: Equatable {
    case idle
    case loading
    case loaded
    case unsupported
    case failed(String)
}

final class MangaHomeViewModel: ObservableObject {
    static let maxSections = 8
    static let maxRetainedItemsPerSection = 30
    static let maxVisibleItemsPerSection = 15

    @Published var sources: [MangaHomeSource] = []
    @Published var selectedSourceID: String?
    @Published var sectionsBySource: [String: [MangaHomeSection]] = [:]
    @Published var loadStates: [String: MangaHomeLoadState] = [:]

    private let selectedSourceKey = "kanzenHomeSelectedSourceID"
    private var loadTokens: [String: UUID] = [:]
    private var readerExtensionLoadTasks: [String: Task<Void, Never>] = [:]

    var selectedSource: MangaHomeSource? {
        guard let selectedSourceID else { return nil }
        return sources.first { $0.id == selectedSourceID }
    }

    func discardCachedSections() {
        readerExtensionLoadTasks.values.forEach { $0.cancel() }
        readerExtensionLoadTasks.removeAll()
        sectionsBySource.removeAll()
        loadStates.removeAll()
        loadTokens.removeAll()
    }

    func updateSources(_ newSources: [MangaHomeSource]) {
        sources = newSources

        let savedID = ProfileSettingsStore.active.string(forKey: selectedSourceKey)
        if let savedID, newSources.contains(where: { $0.id == savedID }) {
            selectedSourceID = savedID
        } else if let selectedSourceID, newSources.contains(where: { $0.id == selectedSourceID }) {
            self.selectedSourceID = selectedSourceID
        } else {
            selectedSourceID = newSources.first?.id
        }
    }

    func selectSource(_ source: MangaHomeSource) {
        selectedSourceID = source.id
        ProfileSettingsStore.active.set(source.id, forKey: selectedSourceKey)
        loadHome(for: source, force: false)
    }

    func loadSelectedSource(force: Bool = false) {
        guard let source = selectedSource else { return }
        loadHome(for: source, force: force)
    }

    /// A catalog edit can target any source, not just the visible one, and
    /// `loadHome(force: false)` short-circuits on a cached section list. Drop
    /// every cache so an unvisited source rebuilds when it is next selected,
    /// and reload the one on screen immediately.
    func reloadForCatalogChange() {
        let visible = selectedSourceID
        for sourceID in sectionsBySource.keys where sourceID != visible {
            readerExtensionLoadTasks[sourceID]?.cancel()
            readerExtensionLoadTasks[sourceID] = nil
            loadTokens[sourceID] = nil
            sectionsBySource[sourceID] = nil
            loadStates[sourceID] = nil
        }
        loadSelectedSource(force: true)
    }

    func loadHome(for source: MangaHomeSource, force: Bool = false) {
        if force {
            readerExtensionLoadTasks[source.id]?.cancel()
            readerExtensionLoadTasks[source.id] = nil
        } else if sectionsBySource[source.id] != nil
                    || readerExtensionLoadTasks[source.id] != nil {
            // Manager/header/cache publications can cause the Home view to
            // resynchronize while the initial source load is still running.
            // Coalesce that work instead of issuing duplicate Popular/Latest
            // operations against the same extension.
            return
        }

        let token = UUID()
        loadTokens[source.id] = token
        loadStates[source.id] = .loading

        switch source.kind {
        case .readerExtension:
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadReaderExtensionHome(for: source, token: token)
                if self.loadTokens[source.id] == token {
                    self.readerExtensionLoadTasks[source.id] = nil
                }
            }
            readerExtensionLoadTasks[source.id] = task
        case .aidoku:
            sectionsBySource[source.id] = []
            loadStates[source.id] = .failed("This previous Reader source must be reconnected.")
        case .legacyModule:
            loadLegacyModuleHome(for: source, token: token)
        }
    }

    struct SectionPage {
        let items: [MangaHomeItem]

        let sourceHasMore: Bool
    }

    static func loadSectionItems(source: MangaHomeSource, section: MangaHomeSection, page: Int) async throws -> SectionPage {
        let raw = try await loadSectionItemsUnfiltered(source: source, section: section, page: page)
        return SectionPage(
            items: ReaderContentFilter.shared.filterHomeItems(raw.items),
            sourceHasMore: raw.sourceHasMore
        )
    }

    private struct UnfilteredSectionPage {
        let items: [MangaHomeItem]
        let sourceHasMore: Bool
    }

    private static func loadSectionItemsUnfiltered(
        source: MangaHomeSource,
        section: MangaHomeSection,
        page: Int
    ) async throws -> UnfilteredSectionPage {
        switch source.kind {
        case .readerExtension:
            guard let sourceID = source.sourceID else {
                throw ReaderExtensionError.sourceNotFound
            }
            let provider = try await ReaderExtensionManager.shared.provider(for: sourceID)
            let result: ReaderExtensionPagedResult
            switch section.readerExtensionQuery {
            case .popular:
                result = try await provider.popular(page: max(page, 1))
            case .latest:
                result = try await provider.latest(page: max(page, 1))
            case .search(let query, let filters):
                result = try await provider.search(query: query, page: max(page, 1), filters: filters)
            case nil:
                return UnfilteredSectionPage(items: [], sourceHasMore: false)
            }
            return UnfilteredSectionPage(
                items: result.items
                    .prefix(Self.maxRetainedItemsPerSection)
                    .map { MangaHomeItem(sourceID: sourceID, item: $0) },
                sourceHasMore: result.hasNextPage
            )

        case .aidoku:
            throw ReaderExtensionError.sourceNotFound

        case .legacyModule:
            guard let module = source.module else {
                return UnfilteredSectionPage(items: [], sourceHasMore: false)
            }
            let engine = KanzenEngine()
            let script = try ModuleManager.shared.getModuleScript(module: module)
            try await engine.loadScript(script, module: module)
            let rawSectionId = section.id.components(separatedBy: ":section:").last ?? section.id
            let rawItems = try await engine.homeSectionItems(
                sectionId: rawSectionId,
                page: page
            )
            let items = (rawItems ?? [])
                .compactMap { MangaHomeItem(dict: $0, module: module, sectionKind: section.kind) }
                .prefix(Self.maxRetainedItemsPerSection)
                .map { $0 }
            return UnfilteredSectionPage(items: items, sourceHasMore: !items.isEmpty)
        }
    }

    @MainActor
    static func readerExtensionHomeSections(
        provider: any ReaderSourceProvider,
        sourceID: ReaderExtensionSourceID
    ) async -> (sections: [MangaHomeSection], failures: [Error]) {
        func capture(
            _ work: () async throws -> ReaderExtensionPagedResult
        ) async -> Result<ReaderExtensionPagedResult, Error> {
            do { return .success(try await work()) }
            catch { return .failure(error) }
        }

        let supportsLatest = provider.source.implementation != .javascript
            || provider.source.runtimeCapabilities.contains(.latest)
        // Each provider already serializes its own operations, so starting
        // these concurrently adds no latency benefit and complicates Sendable
        // isolation. Fail each synthesized section independently instead.
        let popularResult = await capture { try await provider.popular(page: 1) }
        let latestResult: Result<ReaderExtensionPagedResult, Error>? = supportsLatest
            ? await capture { try await provider.latest(page: 1) }
            : nil

        var sections: [MangaHomeSection] = []
        var failures: [Error] = []
        switch popularResult {
        case .success(let popular):
            let items = popular.items.prefix(Self.maxRetainedItemsPerSection).map {
                MangaHomeItem(sourceID: sourceID, item: $0, idSuffix: "popular")
            }
            if !items.isEmpty {
                sections.append(.section(
                    title: "Popular",
                    id: "readerExtension:\(sourceID.rawValue):popular",
                    kind: .popular,
                    items: items,
                    readerExtensionQuery: .popular
                ))
            }
        case .failure(let error):
            failures.append(error)
        }
        if let latestResult {
            switch latestResult {
            case .success(let latest):
                let items = latest.items.prefix(Self.maxRetainedItemsPerSection).map {
                    MangaHomeItem(sourceID: sourceID, item: $0, idSuffix: "latest")
                }
                if !items.isEmpty {
                    sections.append(.section(
                        title: "Latest Updates",
                        id: "readerExtension:\(sourceID.rawValue):latest",
                        kind: .latestUpdates,
                        items: items,
                        readerExtensionQuery: .latest
                    ))
                }
            case .failure(let error):
                failures.append(error)
            }
        }
        return (sections, failures)
    }

    @MainActor
    static func customCatalogSection(
        provider: any ReaderSourceProvider,
        sourceID: ReaderExtensionSourceID,
        catalog: KanzenCustomCatalog,
        sourceFilterTree: [ReaderExtensionFilter]? = nil
    ) async -> MangaHomeSection {
        guard catalog.displayStyle.isQueryBacked else {
            return genreWidgetSection(catalog: catalog, sourceFilterTree: sourceFilterTree)
        }

        let query = MangaHomeSection.ReaderExtensionQuery.search(
            query: catalog.query,
            filters: catalog.filters
        )
        do {
            let result = try await provider.search(query: catalog.query, page: 1, filters: catalog.filters)
            let items = result.items
                .prefix(Self.maxRetainedItemsPerSection)
                .map { MangaHomeItem(sourceID: sourceID, item: $0) }
            return .section(
                title: catalog.displayTitle,
                id: catalog.sectionID,
                kind: .custom,
                items: items,
                readerExtensionQuery: query,
                placeholderMessage: items.isEmpty ? "This catalog returned nothing." : nil,
                displayStyle: catalog.displayStyle
            )
        } catch {
            ReaderLogger.shared.log(
                "Custom catalog failed source=\(sourceID.rawValue.prefix(12)) catalog=\(catalog.id.uuidString.prefix(8)): \(error.localizedDescription)",
                type: "ReaderExtensionHome"
            )
            return .section(
                title: catalog.displayTitle,
                id: catalog.sectionID,
                kind: .custom,
                items: [],
                readerExtensionQuery: query,
                placeholderMessage: error.localizedDescription,
                displayStyle: catalog.displayStyle
            )
        }
    }

    @MainActor
    static func genreWidgetSection(
        catalog: KanzenCustomCatalog,
        sourceFilterTree: [ReaderExtensionFilter]?
    ) -> MangaHomeSection {
        let tree: [ReaderExtensionFilter]
        if let sourceFilterTree, !sourceFilterTree.isEmpty {
            tree = sourceFilterTree
        } else {
            tree = catalog.filters
        }

        let items = KanzenCatalogPresetResolver.genreOptions(in: tree).map {
            MangaHomeItem(genreOption: $0, sectionID: catalog.sectionID, query: catalog.query)
        }
        return .section(
            title: catalog.displayTitle,
            id: catalog.sectionID,
            kind: .genres,
            items: items,
            readerExtensionQuery: nil,
            placeholderMessage: items.isEmpty ? "This source did not publish a genre list." : nil,
            displayStyle: .genres
        )
    }

    @MainActor
    static func sourceFilterTree(
        provider: any ReaderSourceProvider,
        sourceID: ReaderExtensionSourceID
    ) async -> [ReaderExtensionFilter] {
        do {
            return try await provider.filters()
        } catch {
            ReaderLogger.shared.log(
                "Genre widget filter list failed source=\(sourceID.rawValue.prefix(12)): \(error.localizedDescription)",
                type: "ReaderExtensionHome"
            )
            return []
        }
    }

    @MainActor
    private func loadReaderExtensionHome(for source: MangaHomeSource, token: UUID) async {
        guard loadTokens[source.id] == token, let sourceID = source.sourceID else { return }

        do {
            let provider = try ReaderExtensionManager.shared.provider(for: sourceID)
            let catalogs = KanzenCustomCatalogManager.shared.enabledCatalogs(for: sourceID)
            let outcome = await Self.readerExtensionHomeSections(provider: provider, sourceID: sourceID)
            let sections = outcome.sections
            let failures = outcome.failures

            guard loadTokens[source.id] == token else { return }
            sectionsBySource[source.id] = sections
            if !sections.isEmpty {
                loadStates[source.id] = .loaded
            } else if !catalogs.isEmpty {
                loadStates[source.id] = .loading
            } else if let failure = failures.first {
                loadStates[source.id] = .failed(failure.localizedDescription)
            } else {
                loadStates[source.id] = .unsupported
            }

            var filterTree: [ReaderExtensionFilter]?
            for catalog in catalogs {
                guard loadTokens[source.id] == token else { return }
                if !catalog.displayStyle.isQueryBacked, filterTree == nil {
                    filterTree = await Self.sourceFilterTree(provider: provider, sourceID: sourceID)
                    guard loadTokens[source.id] == token else { return }
                }
                let section = await Self.customCatalogSection(
                    provider: provider,
                    sourceID: sourceID,
                    catalog: catalog,
                    sourceFilterTree: filterTree
                )
                guard loadTokens[source.id] == token else { return }
                sectionsBySource[source.id, default: []].append(section)
                loadStates[source.id] = .loaded
            }

            if !failures.isEmpty {
                ReaderLogger.shared.log(
                    "Reader Extension home loaded with \(failures.count) unavailable section(s) source=\(sourceID.rawValue.prefix(12))",
                    type: "ReaderExtensionHome"
                )
            }
        } catch {
            guard loadTokens[source.id] == token else { return }
            sectionsBySource[source.id] = []
            loadStates[source.id] = .failed(error.localizedDescription)
            ReaderLogger.shared.log(
                "Reader Extension home failed source=\(sourceID.rawValue.prefix(12)): \(error.localizedDescription)",
                type: "ReaderExtensionHome"
            )
        }
    }

    private func loadLegacyModuleHome(for source: MangaHomeSource, token: UUID) {
        guard let module = source.module else {
            loadStates[source.id] = .unsupported
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.loadTokens[source.id] == token {
                    self.readerExtensionLoadTasks[source.id] = nil
                }
            }
            let engine = KanzenEngine()
            do {
                let script = try ModuleManager.shared.getModuleScript(module: module)
                try await engine.loadScript(script, module: module)
                try Task.checkCancellation()

                guard self.loadTokens[source.id] == token else { return }
                guard let rawSections = try await engine.homeSections(page: 0) else {
                    self.sectionsBySource[source.id] = []
                    self.loadStates[source.id] = .unsupported
                    return
                }

                var sections = rawSections
                    .compactMap { MangaHomeSection(dict: $0, module: module) }
                    .prefix(Self.maxSections)
                    .map { $0 }

                for index in sections.indices where sections[index].items.isEmpty {
                    try Task.checkCancellation()
                    guard self.loadTokens[source.id] == token else { return }
                    let sectionID = sections[index].id
                        .components(separatedBy: ":section:").last ?? sections[index].id
                    let rawItems = try await engine.homeSectionItems(
                        sectionId: sectionID,
                        page: 0
                    )
                    sections[index].items = (rawItems ?? [])
                        .compactMap {
                            MangaHomeItem(
                                dict: $0,
                                module: module,
                                sectionKind: sections[index].kind
                            )
                        }
                        .prefix(Self.maxRetainedItemsPerSection)
                        .map { $0 }
                }

                guard self.loadTokens[source.id] == token else { return }
                self.sectionsBySource[source.id] = sections.filter { !$0.items.isEmpty }
                self.loadStates[source.id] = .loaded
            } catch {
                guard !Task.isCancelled,
                      self.loadTokens[source.id] == token else { return }
                self.sectionsBySource[source.id] = []
                self.loadStates[source.id] = .failed(error.localizedDescription)
            }
        }
        readerExtensionLoadTasks[source.id] = task
    }

}
