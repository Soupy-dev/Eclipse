//
//  KanzenCatalogPresets.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import Foundation

enum KanzenCatalogPresetKind: String, Codable, Hashable, CaseIterable {
    case genre
    case sort
    case genreIndex
}

enum KanzenCatalogBuiltInRow: Hashable {
    case popular
    case latestUpdates

    /// Must stay in step with the titles `readerExtensionHomeSections` gives
    /// the two rows it synthesizes.
    var rowTitle: String {
        switch self {
        case .popular: return "Popular"
        case .latestUpdates: return "Latest Updates"
        }
    }
}

/// The rows `MangaHomeViewModel.readerExtensionHomeSections` builds from the
/// source's own `getPopular`/`getLatest`, so a suggestion can avoid handing the
/// feed a second row with an identical name.
///
/// These rows are *not* interchangeable with the matching sort preset. Weeb
/// Central's `getPopular` selects its Popularity option but leaves `Order` at
/// its declared default of Ascending, so the built-in row is its **least**
/// popular titles while the preset forces Descending. Suppressing the preset
/// would delete the only correct popularity row, which is why the collision is
/// resolved by naming rather than by withholding.
struct KanzenCatalogBuiltInRows: Equatable, Sendable {
    let publishesPopular: Bool
    let publishesLatestUpdates: Bool

    static let none = KanzenCatalogBuiltInRows(
        publishesPopular: false,
        publishesLatestUpdates: false
    )

    init(publishesPopular: Bool, publishesLatestUpdates: Bool) {
        self.publishesPopular = publishesPopular
        self.publishesLatestUpdates = publishesLatestUpdates
    }

    init(source: ReaderExtensionInstalledSource) {
        // `.popular` is in the runtime's required export set, so a JavaScript
        // source that installed at all publishes that row; only `.latest` is a
        // real signal.
        let declaresCapabilities = source.implementation == .javascript
        self.init(
            publishesPopular: !declaresCapabilities
                || source.runtimeCapabilities.contains(.popular),
            publishesLatestUpdates: !declaresCapabilities
                || source.runtimeCapabilities.contains(.latest)
        )
    }

    func publishes(_ row: KanzenCatalogBuiltInRow) -> Bool {
        switch row {
        case .popular: return publishesPopular
        case .latestUpdates: return publishesLatestUpdates
        }
    }

    func claimsTitle(_ title: String) -> Bool {
        let normalized = KanzenCatalogPresetResolver.normalized(title)
        for row in [KanzenCatalogBuiltInRow.popular, .latestUpdates] where publishes(row) {
            if normalized == KanzenCatalogPresetResolver.normalized(row.rowTitle) { return true }
        }
        return false
    }
}

struct KanzenCatalogPreset: Identifiable, Equatable, Hashable {
    let id: String
    let kind: KanzenCatalogPresetKind
    let title: String
    let alternateNames: [String]
    let displayStyle: KanzenCatalogDisplayStyle

    var searchTerms: [String] { [title] + alternateNames }
}

extension KanzenCatalogPreset {
    static let genreIndex = KanzenCatalogPreset(
        id: "widget.genres",
        kind: .genreIndex,
        title: "Genres",
        alternateNames: [],
        displayStyle: .genres
    )

    static let genrePresets: [KanzenCatalogPreset] = [
        genre("action", "Action"),
        genre("adventure", "Adventure"),
        genre("comedy", "Comedy"),
        genre("drama", "Drama"),
        genre("fantasy", "Fantasy"),
        genre("historical", "Historical"),
        genre("horror", "Horror"),
        genre("isekai", "Isekai", ["Another World"]),
        genre("martial-arts", "Martial Arts", ["Murim", "Wuxia"]),
        genre("mystery", "Mystery"),
        genre("psychological", "Psychological"),
        genre("romance", "Romance"),
        genre("school-life", "School Life", ["School"]),
        genre("sci-fi", "Sci-Fi", ["Science Fiction"]),
        genre("slice-of-life", "Slice of Life", ["Slice-of-Life", "Iyashikei"]),
        genre("sports", "Sports", ["Sport"]),
        genre("supernatural", "Supernatural"),
        genre("thriller", "Thriller", ["Suspense"]),
        genre("tragedy", "Tragedy")
    ]

    static let sortPresets: [KanzenCatalogPreset] = [
        KanzenCatalogPreset(
            id: "sort.trending",
            kind: .sort,
            title: "Trending",
            alternateNames: ["Hot", "Trending Now", "Popular (Month)", "Popular (Week)", "Popular Today"],
            displayStyle: .featured
        ),
        KanzenCatalogPreset(
            id: "sort.popular",
            kind: .sort,
            title: "Popular",
            alternateNames: [
                "Popularity",
                "Popular (All Time)",
                "All Time",
                "Number of follows",
                "followedCount",
                "Most Popular",
                "Most Viewed"
            ],
            displayStyle: .featured
        ),
        KanzenCatalogPreset(
            id: "sort.top-rated",
            kind: .sort,
            title: "Top Rated",
            alternateNames: ["Rating", "Rated", "Score", "Best Rated", "rated_avg"],
            displayStyle: .poster
        ),
        KanzenCatalogPreset(
            id: "sort.newest",
            kind: .sort,
            title: "Newest",
            alternateNames: ["Recently Added", "Added", "Content created at", "createdAt", "New Series"],
            displayStyle: .poster
        ),
        KanzenCatalogPreset(
            id: "sort.recently-updated",
            kind: .sort,
            title: "Recently Updated",
            alternateNames: [
                "Latest Updates",
                "Latest Updated",
                "Latest Update",
                "Updated",
                "Latest",
                "Chapter uploded at",
                "latestUploadedChapter"
            ],
            displayStyle: .poster
        )
    ]

    static let builtIn: [KanzenCatalogPreset] = [genreIndex] + genrePresets + sortPresets

    static func preset(id: String) -> KanzenCatalogPreset? {
        builtIn.first { $0.id == id }
    }

    private static func genre(
        _ identifier: String,
        _ title: String,
        _ alternateNames: [String] = []
    ) -> KanzenCatalogPreset {
        KanzenCatalogPreset(
            id: "genre.\(identifier)",
            kind: .genre,
            title: title,
            alternateNames: alternateNames,
            displayStyle: .poster
        )
    }
}

struct KanzenCatalogGenreOption: Equatable {
    let label: String
    let identifier: String
    let filters: [ReaderExtensionFilter]
}

struct KanzenCatalogPresetResolution: Equatable {
    let preset: KanzenCatalogPreset
    let matchedLabel: String
    let filters: [ReaderExtensionFilter]
    let title: String
    let describesItselfExactly: Bool

    init?(
        preset: KanzenCatalogPreset,
        matchedLabel: String,
        filters: [ReaderExtensionFilter],
        builtInRows: KanzenCatalogBuiltInRows
    ) {
        // "Popular" next to the feed's own Popular row leaves the user with two
        // identically named rows and no way to tell which control produced
        // which. The source's own word for the axis is the one disambiguator
        // that is always true; when even that restates a built-in row's name,
        // there is nothing left to distinguish them and the suggestion is
        // withheld instead.
        let trimmedLabel = matchedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle: String
        if !builtInRows.claimsTitle(preset.title) {
            resolvedTitle = preset.title
        } else if !trimmedLabel.isEmpty, !builtInRows.claimsTitle(trimmedLabel) {
            resolvedTitle = trimmedLabel
        } else {
            return nil
        }

        self.preset = preset
        self.matchedLabel = matchedLabel
        self.filters = filters
        title = resolvedTitle
        describesItselfExactly = KanzenCatalogPresetResolver.normalized(matchedLabel)
            == KanzenCatalogPresetResolver.normalized(resolvedTitle)
    }

    var displayStyle: KanzenCatalogDisplayStyle { preset.displayStyle }

    func catalog(
        for sourceID: ReaderExtensionSourceID,
        order: Int = 0,
        isEnabled: Bool = true
    ) -> KanzenCustomCatalog {
        KanzenCustomCatalog(
            title: title,
            sourceID: sourceID,
            query: "",
            filters: filters,
            isEnabled: isEnabled,
            order: order,
            displayStyle: preset.displayStyle,
            presetID: preset.id
        )
    }
}

enum KanzenCatalogPresetResolver {
    static let maximumGenreIndexOptions = 60

    static func resolve(
        _ preset: KanzenCatalogPreset,
        against filters: [ReaderExtensionFilter],
        builtInRows: KanzenCatalogBuiltInRows = .none
    ) -> [ReaderExtensionFilter]? {
        resolution(for: preset, against: filters, builtInRows: builtInRows)?.filters
    }

    static func resolution(
        for preset: KanzenCatalogPreset,
        against filters: [ReaderExtensionFilter],
        builtInRows: KanzenCatalogBuiltInRows = .none
    ) -> KanzenCatalogPresetResolution? {
        switch preset.kind {
        case .genre:
            return genreResolution(for: preset, against: filters, builtInRows: builtInRows)
        case .sort:
            return sortResolution(for: preset, against: filters, builtInRows: builtInRows)
        case .genreIndex:
            return genreIndexResolution(for: preset, against: filters, builtInRows: builtInRows)
        }
    }

    static func resolutions(
        against filters: [ReaderExtensionFilter],
        builtInRows: KanzenCatalogBuiltInRows
    ) -> [KanzenCatalogPresetResolution] {
        KanzenCatalogPreset.builtIn.compactMap {
            resolution(for: $0, against: filters, builtInRows: builtInRows)
        }
    }

    static func genreOptions(in filters: [ReaderExtensionFilter]) -> [KanzenCatalogGenreOption] {
        guard let groupIndex = genreGroupCandidates(in: filters).first else { return [] }
        let children = filters[groupIndex].children
        return children.indices.prefix(maximumGenreIndexOptions).compactMap { childIndex in
            let child = children[childIndex]
            let label = child.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            var resolved = filters
            select(&resolved[groupIndex].children[childIndex])
            return KanzenCatalogGenreOption(
                label: label,
                identifier: optionIdentifier(for: child),
                filters: resolved
            )
        }
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static let genreGroupNames = [
        "genre", "genres",
        "tag", "tags",
        "category", "categories",
        "theme", "themes",
        "demographic", "demographics"
    ]

    private static func genreResolution(
        for preset: KanzenCatalogPreset,
        against filters: [ReaderExtensionFilter],
        builtInRows: KanzenCatalogBuiltInRows
    ) -> KanzenCatalogPresetResolution? {
        let attempts = matchAttempts(for: preset)
        guard !attempts.isEmpty else { return nil }
        let candidates = genreGroupCandidates(in: filters)
        guard !candidates.isEmpty else { return nil }

        for attempt in attempts {
            for groupIndex in candidates {
                guard let childIndex = genreChildIndex(in: filters[groupIndex], matching: attempt) else { continue }
                var resolved = filters
                select(&resolved[groupIndex].children[childIndex])
                return KanzenCatalogPresetResolution(
                    preset: preset,
                    matchedLabel: filters[groupIndex].children[childIndex].title,
                    filters: resolved,
                    builtInRows: builtInRows
                )
            }
        }
        return nil
    }

    private static func sortResolution(
        for preset: KanzenCatalogPreset,
        against filters: [ReaderExtensionFilter],
        builtInRows: KanzenCatalogBuiltInRows
    ) -> KanzenCatalogPresetResolution? {
        let attempts = matchAttempts(for: preset)
        guard !attempts.isEmpty else { return nil }
        let candidates = sortNodeCandidates(in: filters)
        guard !candidates.isEmpty else { return nil }

        guard let hit = sortOptionHit(attempts: attempts, candidates: candidates, in: filters) else { return nil }
        var resolved = filters
        apply(optionIndex: hit.option, to: &resolved[hit.node])
        if let direction = descendingDirection(in: resolved), direction.node != hit.node {
            apply(optionIndex: direction.option, to: &resolved[direction.node])
        }
        return KanzenCatalogPresetResolution(
            preset: preset,
            matchedLabel: filters[hit.node].options[hit.option].label,
            filters: resolved,
            builtInRows: builtInRows
        )
    }

    private static func sortOptionHit(
        attempts: [String],
        candidates: [Int],
        in filters: [ReaderExtensionFilter]
    ) -> (node: Int, option: Int)? {
        for attempt in attempts {
            for nodeIndex in candidates {
                if let option = filters[nodeIndex].options.firstIndex(where: { normalized($0.label) == attempt }) {
                    return (nodeIndex, option)
                }
            }
        }
        for attempt in attempts {
            for nodeIndex in candidates {
                if let option = filters[nodeIndex].options.firstIndex(where: { normalized($0.value) == attempt }) {
                    return (nodeIndex, option)
                }
            }
        }
        return nil
    }

    private static func genreIndexResolution(
        for preset: KanzenCatalogPreset,
        against filters: [ReaderExtensionFilter],
        builtInRows: KanzenCatalogBuiltInRows
    ) -> KanzenCatalogPresetResolution? {
        guard let groupIndex = genreGroupCandidates(in: filters).first else { return nil }
        return KanzenCatalogPresetResolution(
            preset: preset,
            matchedLabel: filters[groupIndex].title,
            filters: filters,
            builtInRows: builtInRows
        )
    }

    private static func genreGroupCandidates(in filters: [ReaderExtensionFilter]) -> [Int] {
        var candidates: [(index: Int, rank: Int, options: Int)] = []
        for (index, filter) in filters.enumerated() {
            guard filter.kind == .group, !filter.children.isEmpty else { continue }
            guard filter.children.allSatisfy({ $0.kind == .toggle || $0.kind == .triState }) else { continue }
            guard let rank = genreGroupRank(filter) else { continue }
            candidates.append((index, rank, filter.children.count))
        }
        return candidates
            .sorted { left, right in
                if left.rank != right.rank { return left.rank < right.rank }
                if left.options != right.options { return left.options > right.options }
                return left.index < right.index
            }
            .map(\.index)
    }

    private static func genreGroupRank(_ filter: ReaderExtensionFilter) -> Int? {
        if let abiType = filter.abiType, normalized(abiType).contains("genre") { return 0 }
        let title = normalized(filter.title)
        guard !title.isEmpty else { return nil }
        if let exact = genreGroupNames.firstIndex(of: title) { return 1 + exact }
        if let contained = genreGroupNames.firstIndex(where: { title.contains($0) }) { return 100 + contained }
        return nil
    }

    private static func genreChildIndex(in group: ReaderExtensionFilter, matching candidate: String) -> Int? {
        group.children.firstIndex {
            ($0.kind == .toggle || $0.kind == .triState) && normalized($0.title) == candidate
        }
    }

    private static func sortNodeCandidates(in filters: [ReaderExtensionFilter]) -> [Int] {
        var candidates: [(index: Int, rank: Int)] = []
        for (index, filter) in filters.enumerated() {
            guard filter.options.count > 1, !isDirectionControl(filter) else { continue }
            if filter.kind == .sort {
                candidates.append((index, 0))
                continue
            }
            guard filter.kind == .select else { continue }
            let title = normalized(filter.title)
            if title == "sort" || title == "sortby" {
                candidates.append((index, 1))
            } else if title.contains("sort") {
                candidates.append((index, 2))
            } else if title == "orderby" {
                candidates.append((index, 3))
            } else if title == "order" {
                candidates.append((index, 4))
            }
        }
        return candidates
            .sorted { left, right in
                left.rank != right.rank ? left.rank < right.rank : left.index < right.index
            }
            .map(\.index)
    }

    private static func descendingDirection(in filters: [ReaderExtensionFilter]) -> (node: Int, option: Int)? {
        for (index, filter) in filters.enumerated() where isDirectionControl(filter) {
            let option = filter.options.firstIndex {
                let label = normalized($0.label)
                return label == "descending" || label == "desc" || normalized($0.value) == "desc"
            }
            if let option { return (index, option) }
        }
        return nil
    }

    private static func isDirectionControl(_ filter: ReaderExtensionFilter) -> Bool {
        guard filter.kind == .select || filter.kind == .sort, filter.options.count == 2 else { return false }
        let labels = Set(filter.options.map { normalized($0.label) })
        let values = Set(filter.options.map { normalized($0.value) })
        let spelled: Set<String> = ["ascending", "descending"]
        let abbreviated: Set<String> = ["asc", "desc"]
        return labels == spelled || labels == abbreviated || values == abbreviated
    }

    private static func apply(optionIndex: Int, to filter: inout ReaderExtensionFilter) {
        guard filter.options.indices.contains(optionIndex) else { return }
        filter.selectedOptionIndex = optionIndex
        filter.value = .string(filter.options[optionIndex].value)
        if filter.kind == .sort { filter.sortAscending = false }
    }

    private static func select(_ filter: inout ReaderExtensionFilter) {
        switch filter.kind {
        case .triState: filter.value = .number(1)
        default: filter.value = .bool(true)
        }
    }

    private static func optionIdentifier(for child: ReaderExtensionFilter) -> String {
        if case .string(let value)? = child.abiValue, !value.isEmpty { return value }
        return child.key
    }

    private static func matchAttempts(for preset: KanzenCatalogPreset) -> [String] {
        let terms = preset.searchTerms.map { normalized($0) }
        return deduplicated(terms + terms.flatMap { pluralVariants($0) })
    }

    private static func deduplicated(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for term in terms where !term.isEmpty && seen.insert(term).inserted {
            ordered.append(term)
        }
        return ordered
    }

    private static func pluralVariants(_ term: String) -> [String] {
        guard !term.isEmpty else { return [] }
        if term.hasSuffix("s") { return [String(term.dropLast())] }
        return [term + "s"]
    }
}
