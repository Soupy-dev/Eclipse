// Copyright 2026 Eclipse contributors
// SPDX-License-Identifier: Apache-2.0
//
// These data-driven adapters are substantially modified Swift ports of the
// generic parser families in kodjodevf/mangayomi-extensions at immutable
// commit 6004f1f8d1a56f882dadb734ce26f50c626a3850:
// dart/manga/multisrc/{madara,mangareader,mangabox,mmrcms,nepnep}.
// No provider list, provider-specific configuration, or website content is
// bundled with Eclipse.
// See Eclipse/Legal/ReaderExtensions/NOTICE.txt for provenance and notices.

import Foundation
import SwiftSoup

enum ReaderExtensionNativeProviderFactory {
    static func make(
        source: ReaderExtensionInstalledSource,
        network: ReaderExtensionNetworkClient,
        approvedDomains: Set<String>,
        consentScopeID: String
    ) throws -> any ReaderSourceProvider {
        let configuration: ReaderExtensionNativeFamilyConfiguration
        switch source.implementation {
        case .madara: configuration = .madara(source: source)
        case .mangaReader: configuration = .mangaReader(source: source)
        case .mangaBox: configuration = .mangaBox(source: source)
        case .mmrcms: configuration = .mmrcms(source: source)
        case .nepNep:
            return ReaderExtensionNepNepProvider(
                source: source,
                network: network,
                approvedDomains: approvedDomains,
                consentScopeID: consentScopeID
            )
        default: throw ReaderExtensionError.unsupportedSource
        }
        return ReaderExtensionGenericHTMLProvider(
            source: source,
            network: network,
            approvedDomains: approvedDomains,
            consentScopeID: consentScopeID,
            configuration: configuration
        )
    }
}

private struct ReaderExtensionNativeFamilyConfiguration {
    var popularPath: (Int) -> String
    var latestPath: (Int) -> String
    var searchPath: (String, Int, [ReaderExtensionFilter]) -> String
    var listContainerSelector: String
    var listAnchorSelector: String
    var listImageSelector: String
    var detailTitleSelector: String
    var detailCoverSelector: String
    var detailDescriptionSelector: String
    var detailAuthorSelector: String
    var detailGenreSelector: String
    var detailStatusSelector: String
    var chapterContainerSelector: String
    var chapterAnchorSelector: String
    var chapterDateSelector: String
    var pageImageSelector: String
    var mmrcmsSuggestionSubdirectory: String?
    var filters: [ReaderExtensionFilter]

    static func madara(source: ReaderExtensionInstalledSource) -> Self {
        let directory = madaraDirectory(for: source.name)
        return ReaderExtensionNativeFamilyConfiguration(
            popularPath: { "/\(directory)/page/\(max(1, $0))/?m_orderby=views" },
            latestPath: { "/\(directory)/page/\(max(1, $0))/?m_orderby=latest" },
            searchPath: { query, page, filters in
                var values = [
                    URLQueryItem(name: "s", value: query),
                    URLQueryItem(name: "post_type", value: "wp-manga")
                ]
                values.append(contentsOf: madaraQueryItems(filters))
                // Upstream drops the page here and serves page 1 forever;
                // WordPress paginates search as /page/N/?s=... on every
                // Madara deployment.
                return path(page <= 1 ? "/" : "/page/\(page)/", queryItems: values)
            },
            listContainerSelector: "div.page-item-detail, div.manga__item, div.c-tabs-item__content",
            listAnchorSelector: "div.post-title a, .tab-thumb a, .item-summary a",
            listImageSelector: "img",
            detailTitleSelector: ".post-title h1, .post-title h3, h1",
            detailCoverSelector: "div.summary_image img, .tab-summary img",
            detailDescriptionSelector: "div.description-summary div.summary__content, .manga-summary, .description-summary",
            detailAuthorSelector: "div.author-content > a, .author-content",
            detailGenreSelector: "div.genres-content a",
            detailStatusSelector: "div.post-content_item:has(.summary-heading:contains(Status)) .summary-content, .post-status .summary-content",
            chapterContainerSelector: "li.wp-manga-chapter",
            chapterAnchorSelector: "a",
            chapterDateSelector: "span.chapter-release-date",
            pageImageSelector: "div.page-break img, li.blocks-gallery-item img, .reading-content img",
            mmrcmsSuggestionSubdirectory: nil,
            filters: madaraFilters
        )
    }

    static func mangaReader(source: ReaderExtensionInstalledSource) -> Self {
        let isSushiScan = source.name == "Sushi-Scan"
        let directory = isSushiScan ? "catalogue" : "manga"
        return ReaderExtensionNativeFamilyConfiguration(
            popularPath: { "/\(directory)/?page=\(max(1, $0))&order=popular" },
            latestPath: { "/\(directory)/?page=\(max(1, $0))&order=update" },
            searchPath: { query, page, filters in
                var values = [URLQueryItem(name: "s", value: query)]
                if !isSushiScan {
                    values.append(URLQueryItem(name: "page", value: String(max(1, page))))
                    values.append(contentsOf: mangaReaderQueryItems(filters))
                    return path("/", queryItems: values)
                }
                return path("/page/\(max(1, page))/", queryItems: values)
            },
            listContainerSelector: ".utao .uta .imgu, .listupd .bs .bsx, .listo .bs .bsx",
            listAnchorSelector: "a",
            listImageSelector: "img",
            detailTitleSelector: "h1.entry-title, .entry-title, .thumb h1",
            detailCoverSelector: ".bigcontent img, .animefull img, .main-info img, .postbody img",
            detailDescriptionSelector: ".desc, .entry-content[itemprop=description]",
            detailAuthorSelector: ".infotable tr:contains(Author) td:last-child, .tsinfo .imptdt:contains(Author) i",
            detailGenreSelector: "div.gnr a, .mgen a, .seriestugenre a",
            detailStatusSelector: ".infotable tr:contains(Status) td:last-child, .tsinfo .imptdt:contains(Status) i",
            chapterContainerSelector: "div.bxcl li, div.cl li, #chapterlist li, ul li:has(div.chbox):has(div.eph-num)",
            chapterAnchorSelector: "a",
            chapterDateSelector: ".chapterdate",
            pageImageSelector: "#readerarea p img, #readerarea > img",
            mmrcmsSuggestionSubdirectory: nil,
            filters: isSushiScan ? [] : mangaReaderFilters
        )
    }

    static func mangaBox(source: ReaderExtensionInstalledSource) -> Self {
        // The current store entries do not carry the old `urlStyle` manifest
        // hint. Mangairo is the sole path-pagination variant in this family,
        // and its catalog name is the upstream dispatch key as well.
        let usesPathPagination = source.name == "Mangairo"
        return ReaderExtensionNativeFamilyConfiguration(
            popularPath: { usesPathPagination ? "/manga-list/type-topview/ctg-all/state-all/page-\(max(1, $0))" : "/manga-list/hot-manga?page=\(max(1, $0))" },
            latestPath: { usesPathPagination ? "/manga-list/type-latest/ctg-all/state-all/page-\(max(1, $0))" : "/manga-list/latest-manga?page=\(max(1, $0))" },
            searchPath: { query, page, filters in
                if !query.isEmpty {
                    let slug = slug(query)
                    let route = usesPathPagination ? "/list/search/\(slug)" : "/search/story/\(slug)"
                    return path(route, queryItems: [URLQueryItem(name: "page", value: String(max(1, page)))])
                }
                let genre = validatedSelection(
                    filterValue(type: "GenreListFilter", in: filters),
                    allowed: Set(mangaBoxGenreOptions.map(\.value)),
                    fallback: "all"
                )
                let sort = validatedSelection(
                    filterValue(type: "SortFilter", in: filters),
                    allowed: ["latest", "newest", "topview"],
                    fallback: "latest"
                )
                let status = validatedSelection(
                    filterValue(type: "StatusFilter", in: filters),
                    allowed: ["all", "completed", "ongoing", "drop"],
                    fallback: "all"
                )
                return path("/genre/\(genre)", queryItems: [
                    URLQueryItem(name: "type", value: sort),
                    URLQueryItem(name: "state", value: status),
                    URLQueryItem(name: "page", value: String(max(1, page)))
                ])
            },
            listContainerSelector: ".genres-item, .list-truyen-item-wrap, .story-item, .story_item_right, .search-story-item, .list-story-item",
            // SwiftSoup does not accept a selector group that begins with a
            // relative combinator (", > a"). Selecting any descendant anchor
            // is the safe generic fallback for the row container.
            listAnchorSelector: "h3 a, h2 a, a",
            listImageSelector: "a img, img",
            detailTitleSelector: "h1, .story-title, .title",
            detailCoverSelector: ".info-image img, .story-info-left img, .manga-info-pic img",
            detailDescriptionSelector: "#contentBox, #story_discription, #noidungm",
            detailAuthorSelector: "tr:has(.table-label:contains(Author)) td:nth-child(2), li:contains(Author) a",
            detailGenreSelector: "tr:has(.table-label:contains(Genres)) td:nth-child(2) a, li:contains(Genres) a",
            detailStatusSelector: "tr:has(.table-label:contains(Status)) td:nth-child(2), li:contains(Status)",
            chapterContainerSelector: "div.chapter-list div.row, ul.row-content-chapter li, div#chapter_list li",
            chapterAnchorSelector: "a",
            chapterDateSelector: "span, p",
            pageImageSelector: "div.container-chapter-reader img, div.panel-read-story img",
            mmrcmsSuggestionSubdirectory: nil,
            filters: usesPathPagination ? [] : mangaBoxFilters
        )
    }

    static func mmrcms(source: ReaderExtensionInstalledSource) -> Self {
        let subdirectory: String
        switch source.name {
        case "Scan VF": subdirectory = ""
        case "Read Comics Online": subdirectory = "comic"
        default: subdirectory = "manga"
        }
        return ReaderExtensionNativeFamilyConfiguration(
            popularPath: { "/filterList?page=\(max(1, $0))&sortBy=views&asc=false" },
            latestPath: { "/latest-release?page=\(max(1, $0))" },
            searchPath: { query, _, _ in
                path("/search", queryItems: [URLQueryItem(name: "query", value: query)])
            },
            listContainerSelector: "div.chapter-container, div.media, div.mangalist div.manga-item",
            listAnchorSelector: ".media-heading a, .manga-heading a, a",
            listImageSelector: "img",
            detailTitleSelector: ".panel-heading, .listmanga-header, .widget-title",
            detailCoverSelector: ".row img.img-responsive",
            detailDescriptionSelector: ".row .well",
            detailAuthorSelector: ".panel-body h3:contains(Author) + div, .row .dl-horizontal dt:contains(Author) + dd",
            detailGenreSelector: ".panel-body h3:contains(Categories) + div a, .row .dl-horizontal dt:contains(Categories) + dd a",
            detailStatusSelector: ".panel-body h3:contains(Status) + div, .row .dl-horizontal dt:contains(Status) + dd",
            chapterContainerSelector: "ul.chapters > li:not(.btn)",
            chapterAnchorSelector: ".chapter-title-rtl a, a",
            chapterDateSelector: ".date-chapter-title-rtl",
            pageImageSelector: "#all img.img-responsive[data-src], #all img.img-responsive",
            mmrcmsSuggestionSubdirectory: subdirectory,
            filters: []
        )
    }

    private static let madaraFilters: [ReaderExtensionFilter] = [
        ReaderExtensionFilter(
            key: "AuthorFilter", title: "Author", kind: .text,
            options: [], value: .string(""), abiType: "AuthorFilter"
        ),
        ReaderExtensionFilter(
            key: "ArtistFilter", title: "Artist", kind: .text,
            options: [], value: .string(""), abiType: "ArtistFilter"
        ),
        ReaderExtensionFilter(
            key: "YearFilter", title: "Year of Released", kind: .text,
            options: [], value: .string(""), abiType: "YearFilter"
        ),
        ReaderExtensionFilter(
            key: "StatusFilter", title: "Status", kind: .group,
            options: [], value: .string(""), abiType: "StatusFilter",
            children: [
                toggleFilter(key: "status.end", title: "Completed", parameterValue: "end"),
                toggleFilter(key: "status.on-going", title: "Ongoing", parameterValue: "on-going"),
                toggleFilter(key: "status.canceled", title: "Canceled", parameterValue: "canceled"),
                toggleFilter(key: "status.on-hold", title: "On Hold", parameterValue: "on-hold")
            ]
        ),
        ReaderExtensionFilter(
            key: "OrderByFilter", title: "Order By", kind: .select,
            options: [
                .init(label: "Relevance", value: ""),
                .init(label: "Latest", value: "latest"),
                .init(label: "A-Z", value: "alphabet"),
                .init(label: "Rating", value: "rating"),
                .init(label: "Trending", value: "trending"),
                .init(label: "Most Views", value: "views"),
                .init(label: "New", value: "new-manga")
            ],
            value: .string(""), abiType: "OrderByFilter"
        ),
        ReaderExtensionFilter(
            key: "AdultContentFilter", title: "Adult Content", kind: .select,
            options: [
                .init(label: "All", value: ""),
                .init(label: "None", value: "0"),
                .init(label: "Only", value: "1")
            ],
            value: .string(""), abiType: "AdultContentFilter"
        )
    ]

    private static let mangaReaderFilters: [ReaderExtensionFilter] = [
        ReaderExtensionFilter(
            key: "separator", title: "", kind: .separator,
            options: [], value: .string(""), abiType: "SeparatorFilter"
        ),
        ReaderExtensionFilter(
            key: "AuthorFilter", title: "Author", kind: .text,
            options: [], value: .string(""), abiType: "AuthorFilter"
        ),
        ReaderExtensionFilter(
            key: "YearFilter", title: "Year", kind: .text,
            options: [], value: .string(""), abiType: "YearFilter"
        ),
        ReaderExtensionFilter(
            key: "StatusFilter", title: "Status", kind: .select,
            options: [
                .init(label: "All", value: ""),
                .init(label: "Ongoing", value: "ongoing"),
                .init(label: "Completed", value: "completed"),
                .init(label: "Hiatus", value: "hiatus"),
                .init(label: "Dropped", value: "dropped")
            ],
            value: .string(""), abiType: "StatusFilter"
        ),
        ReaderExtensionFilter(
            key: "TypeFilter", title: "Type", kind: .select,
            options: [
                .init(label: "All", value: ""),
                .init(label: "Manga", value: "Manga"),
                .init(label: "Manhwa", value: "Manhwa"),
                .init(label: "Manhua", value: "Manhua"),
                .init(label: "Comic", value: "Comic")
            ],
            value: .string(""), abiType: "TypeFilter"
        ),
        ReaderExtensionFilter(
            key: "OrderByFilter", title: "Sort By", kind: .select,
            options: [
                .init(label: "Default", value: ""),
                .init(label: "A-Z", value: "title"),
                .init(label: "Z-A", value: "titlereverse"),
                .init(label: "Latest Update", value: "update"),
                .init(label: "Latest Added", value: "latest"),
                .init(label: "Popular", value: "popular")
            ],
            value: .string(""), abiType: "OrderByFilter"
        ),
        ReaderExtensionFilter(
            key: "genre-exclusion-header",
            title: "Genre exclusion is not available for all sources",
            kind: .header,
            options: [], value: .string(""), abiType: "HeaderFilter"
        ),
        ReaderExtensionFilter(
            key: "GenreListFilter", title: "Genre", kind: .group,
            options: [], value: .string(""), abiType: "GenreListFilter",
            children: [
                ReaderExtensionFilter(
                    key: "genre-placeholder",
                    title: "Press reset to attempt to fetch genres",
                    kind: .triState,
                    options: [], value: .number(0),
                    abiType: "TriStateFilter", abiValue: .string("")
                )
            ]
        )
    ]

    private static let mangaBoxGenreOptions: [ReaderExtensionFilterOption] = [
        .init(label: "ALL", value: "all"),
        .init(label: "Action", value: "action"),
        .init(label: "Adult", value: "adult"),
        .init(label: "Adventure", value: "adventure"),
        .init(label: "Comedy", value: "comedy"),
        .init(label: "Cooking", value: "cooking"),
        .init(label: "Doujinshi", value: "doujinshi"),
        .init(label: "Drama", value: "drama"),
        .init(label: "Ecchi", value: "ecchi"),
        .init(label: "Fantasy", value: "fantasy"),
        .init(label: "Gender Bender", value: "gender-bender"),
        .init(label: "Harem", value: "harem"),
        .init(label: "Historical", value: "historical"),
        .init(label: "Horror", value: "horror"),
        .init(label: "Isekai", value: "isekai"),
        .init(label: "Josei", value: "josei"),
        .init(label: "Manhua", value: "manhua"),
        .init(label: "Manhwa", value: "manhwa"),
        .init(label: "Martial arts", value: "martial-arts"),
        .init(label: "Mature", value: "mature"),
        .init(label: "Mecha", value: "mecha"),
        .init(label: "Medical", value: "medical"),
        .init(label: "Mystery", value: "mystery"),
        .init(label: "One shot", value: "one-shot"),
        .init(label: "Psychological", value: "psychological"),
        .init(label: "Reincarnation", value: "reincarnation"),
        .init(label: "Romance", value: "romance"),
        .init(label: "School life", value: "school-life"),
        .init(label: "Sci fi", value: "sci-fi"),
        .init(label: "Seinen", value: "seinen"),
        .init(label: "Shoujo", value: "shoujo"),
        .init(label: "Shoujo ai", value: "shoujo-ai"),
        .init(label: "Shounen", value: "shounen"),
        .init(label: "Shounen ai", value: "shounen-ai"),
        .init(label: "Slice of life", value: "slice-of-life"),
        .init(label: "Smut", value: "smut"),
        .init(label: "Sports", value: "sports"),
        .init(label: "Supernatural", value: "supernatural"),
        .init(label: "Survival", value: "survival"),
        .init(label: "System", value: "system"),
        .init(label: "Thriller", value: "thriller"),
        .init(label: "Tragedy", value: "tragedy"),
        .init(label: "Webtoons", value: "webtoons"),
        .init(label: "Yaoi", value: "yaoi"),
        .init(label: "Yuri", value: "yuri")
    ]

    private static let mangaBoxFilters: [ReaderExtensionFilter] = [
        ReaderExtensionFilter(
            key: "text-search-warning",
            title: "NOTE: The filter is ignored when using text search.",
            kind: .header,
            options: [], value: .string(""), abiType: "HeaderFilter"
        ),
        ReaderExtensionFilter(
            key: "SortFilter", title: "Order by:", kind: .select,
            options: [
                .init(label: "Latest", value: "latest"),
                .init(label: "Newest", value: "newest"),
                .init(label: "Top read", value: "topview")
            ],
            value: .string("latest"), abiType: "SortFilter"
        ),
        ReaderExtensionFilter(
            key: "StatusFilter", title: "Status:", kind: .select,
            options: [
                .init(label: "ALL", value: "all"),
                .init(label: "Completed", value: "completed"),
                .init(label: "Ongoing", value: "ongoing"),
                .init(label: "Dropped", value: "drop")
            ],
            value: .string("all"), abiType: "StatusFilter"
        ),
        ReaderExtensionFilter(
            key: "GenreListFilter", title: "Category:", kind: .select,
            options: mangaBoxGenreOptions,
            value: .string("all"), abiType: "GenreListFilter"
        )
    ]

    private static func toggleFilter(
        key: String,
        title: String,
        parameterValue: String
    ) -> ReaderExtensionFilter {
        ReaderExtensionFilter(
            key: key, title: title, kind: .toggle,
            options: [], value: .bool(false),
            abiType: "CheckBoxFilter", abiValue: .string(parameterValue)
        )
    }

    private static func madaraQueryItems(_ filters: [ReaderExtensionFilter]) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        for filter in filters {
            switch filterType(filter) {
            case "AuthorFilter":
                if let value = nonemptyFilterValue(filter) {
                    items.append(URLQueryItem(name: "author", value: value))
                }
            case "ArtistFilter":
                if let value = nonemptyFilterValue(filter) {
                    items.append(URLQueryItem(name: "artist", value: value))
                }
            case "YearFilter":
                if let value = nonemptyFilterValue(filter) {
                    items.append(URLQueryItem(name: "release", value: value))
                }
            case "StatusFilter":
                for child in filter.children where isToggleSelected(child) {
                    let value = parameterValue(child)
                    if !value.isEmpty {
                        items.append(URLQueryItem(name: "status[]", value: value))
                    }
                }
            case "OrderByFilter":
                if let value = nonemptyFilterValue(filter) {
                    items.append(URLQueryItem(name: "m_orderby", value: value))
                }
            case "AdultContentFilter":
                if let value = nonemptyFilterValue(filter) {
                    items.append(URLQueryItem(name: "adult", value: value))
                }
            case "GenreListFilter":
                for child in filter.children where isToggleSelected(child) || triState(child) == 1 {
                    let value = parameterValue(child)
                    if !value.isEmpty {
                        items.append(URLQueryItem(name: "genre[]", value: "\(value),"))
                    }
                }
            default:
                continue
            }
        }
        return items
    }

    private static func mangaReaderQueryItems(_ filters: [ReaderExtensionFilter]) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        for filter in filters {
            switch filterType(filter) {
            case "AuthorFilter":
                items.append(URLQueryItem(name: "author", value: stringValue(filter)))
            case "YearFilter":
                items.append(URLQueryItem(name: "yearx", value: stringValue(filter)))
            case "StatusFilter":
                items.append(URLQueryItem(name: "status", value: stringValue(filter)))
            case "TypeFilter":
                items.append(URLQueryItem(name: "type", value: stringValue(filter)))
            case "OrderByFilter":
                items.append(URLQueryItem(name: "order", value: stringValue(filter)))
            case "GenreListFilter":
                let included = filter.children
                    .filter { triState($0) == 1 }
                    .map(parameterValue)
                    .filter { !$0.isEmpty }
                let excluded = filter.children
                    .filter { triState($0) == 2 }
                    .map(parameterValue)
                    .filter { !$0.isEmpty }
                if !included.isEmpty {
                    items.append(URLQueryItem(
                        name: "genres[]",
                        value: included.joined(separator: ",") + ","
                    ))
                }
                if !excluded.isEmpty {
                    items.append(URLQueryItem(
                        name: "genres[]",
                        value: excluded.map { "-\($0)" }.joined(separator: ",") + ","
                    ))
                }
            default:
                continue
            }
        }
        return items
    }

    private static func filterType(_ filter: ReaderExtensionFilter) -> String {
        filter.abiType ?? filter.key
    }

    private static func filterValue(
        type: String,
        in filters: [ReaderExtensionFilter]
    ) -> String? {
        filters.first { filterType($0) == type }.map(stringValue)
    }

    private static func stringValue(_ filter: ReaderExtensionFilter) -> String {
        switch filter.value {
        case .string(let value): return value
        case .stringList(let values): return values.joined(separator: ",")
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return String(value)
        case .secretReference: return ""
        }
    }

    private static func nonemptyFilterValue(_ filter: ReaderExtensionFilter) -> String? {
        let value = stringValue(filter)
        return value.isEmpty ? nil : value
    }

    private static func isToggleSelected(_ filter: ReaderExtensionFilter) -> Bool {
        if case .bool(let value) = filter.value { return value }
        return triState(filter) == 1
    }

    private static func triState(_ filter: ReaderExtensionFilter) -> Int {
        switch filter.value {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value) ?? 0
        case .bool(let value): return value ? 1 : 0
        case .stringList, .secretReference: return 0
        }
    }

    private static func parameterValue(_ filter: ReaderExtensionFilter) -> String {
        if let abiValue = filter.abiValue,
           case .string(let value) = abiValue {
            return value
        }
        return filter.key
    }

    private static func validatedSelection(
        _ value: String?,
        allowed: Set<String>,
        fallback: String
    ) -> String {
        guard let value, allowed.contains(value) else { return fallback }
        return value
    }

    private static func madaraDirectory(for sourceName: String) -> String {
        [
            "Olaoe": "works",
            "Mangax Core": "works",
            "Azora": "series",
            "Manga Crab": "series",
            "KlikManga": "series",
            "Hwago": "komik"
        ][sourceName] ?? "manga"
    }

    private static func path(_ path: String, queryItems: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.path = path
        components.queryItems = queryItems
        return components.string ?? path
    }

    private static func slug(_ input: String) -> String {
        input.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

/// Native parsers run over attacker-controlled DOMs. A small HTML document can
/// select the same nested text through hundreds of ancestor rows, so bounding
/// only the response and row count is not enough: the retained Swift models
/// need their own field and aggregate budgets.
private enum ReaderExtensionNativeOutputPolicy {
    static let maximumIdentityBytes = 16 * 1_024
    static let maximumTitleBytes = 16 * 1_024
    static let maximumDescriptionBytes = 256 * 1_024
    static let maximumPersonBytes = 16 * 1_024
    static let maximumStatusTextBytes = 4 * 1_024
    static let maximumTagBytes = 4 * 1_024
    static let maximumTagCount = 200
    static let maximumDateTextBytes = 2 * 1_024
    static let maximumURLBytes = 16 * 1_024
    static let maximumModelsBytesPerOperation = 2 * 1_024 * 1_024
    static let modelOverheadBytes = 128

    static func optionalText(_ raw: String?, maximumBytes: Int) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= maximumBytes else { throw ReaderExtensionError.contentTooLarge }
        return value.isEmpty ? nil : value
    }

    static func requiredText(_ raw: String, maximumBytes: Int) throws -> String {
        guard let value = try optionalText(raw, maximumBytes: maximumBytes) else {
            throw ReaderExtensionError.resultInvalid("native source returned an empty required field")
        }
        return value
    }

    static func validatedURL(_ url: URL?) throws -> URL? {
        guard let url else { return nil }
        guard url.absoluteString.utf8.count <= maximumURLBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        return url
    }

    static func validatedIdentity(_ raw: String) throws -> String {
        guard let value = ReaderExtensionSecurityPolicy.persistableProviderContentKey(
            raw,
            maximumBytes: maximumIdentityBytes
        ) else {
            throw ReaderExtensionError.resultInvalid("native source returned an invalid identity")
        }
        return value
    }
}

private struct ReaderExtensionNativeModelBudget {
    private var consumedBytes = 0

    mutating func consume(_ item: ReaderExtensionItem) throws {
        var fields: [String?] = [
            item.key,
            item.title,
            item.url?.absoluteString,
            item.coverURL?.absoluteString,
            item.description,
            item.author,
            item.artist
        ]
        fields.append(contentsOf: item.tags.map(Optional.some))
        try validate(item.key, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumIdentityBytes)
        try validate(item.title, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes)
        try validate(item.url?.absoluteString, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumURLBytes)
        try validate(item.coverURL?.absoluteString, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumURLBytes)
        try validate(item.description, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumDescriptionBytes)
        try validate(item.author, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumPersonBytes)
        try validate(item.artist, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumPersonBytes)
        guard item.tags.count <= ReaderExtensionNativeOutputPolicy.maximumTagCount else {
            throw ReaderExtensionError.contentTooLarge
        }
        for tag in item.tags {
            try validate(tag, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTagBytes)
        }
        try consume(fields)
    }

    mutating func consume(_ chapter: ReaderExtensionChapter) throws {
        try validate(chapter.key, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumIdentityBytes)
        try validate(chapter.title, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes)
        try validate(chapter.url?.absoluteString, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumURLBytes)
        try validate(chapter.scanlator, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumPersonBytes)
        try validate(chapter.thumbnailURL?.absoluteString, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumURLBytes)
        try validate(chapter.summary, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumDescriptionBytes)
        try consume([
            chapter.key,
            chapter.title,
            chapter.url?.absoluteString,
            chapter.scanlator,
            chapter.thumbnailURL?.absoluteString,
            chapter.summary
        ])
    }

    mutating func consume(_ page: ReaderExtensionPage) throws {
        try validate(page.key, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumIdentityBytes)
        try validate(page.url.absoluteString, maximumBytes: ReaderExtensionNativeOutputPolicy.maximumURLBytes)
        var fields: [String?] = [page.key, page.url.absoluteString]
        for (name, value) in page.transientRequestHeaders {
            fields.append(name)
            fields.append(value)
        }
        try consume(fields)
    }

    private func validate(_ value: String?, maximumBytes: Int) throws {
        guard (value?.utf8.count ?? 0) <= maximumBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
    }

    private mutating func consume(_ fields: [String?]) throws {
        var addedBytes = ReaderExtensionNativeOutputPolicy.modelOverheadBytes
        for field in fields {
            let count = field?.utf8.count ?? 0
            guard count <= ReaderExtensionNativeOutputPolicy.maximumModelsBytesPerOperation - addedBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            addedBytes += count
        }
        guard addedBytes <= ReaderExtensionNativeOutputPolicy.maximumModelsBytesPerOperation - consumedBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        consumedBytes += addedBytes
    }
}

private final class ReaderExtensionGenericHTMLProvider: ReaderSourceProvider {
    let source: ReaderExtensionInstalledSource
    private let network: ReaderExtensionNetworkClient
    private let approvedDomains: Set<String>
    private let consentScopeID: String
    private let configuration: ReaderExtensionNativeFamilyConfiguration

    init(
        source: ReaderExtensionInstalledSource,
        network: ReaderExtensionNetworkClient,
        approvedDomains: Set<String>,
        consentScopeID: String,
        configuration: ReaderExtensionNativeFamilyConfiguration
    ) {
        self.source = source
        self.network = network
        self.approvedDomains = approvedDomains
        self.consentScopeID = consentScopeID
        self.configuration = configuration
    }

    func popular(page: Int) async throws -> ReaderExtensionPagedResult {
        try await listing(path: configuration.popularPath(page))
    }

    func latest(page: Int) async throws -> ReaderExtensionPagedResult {
        try await listing(path: configuration.latestPath(page))
    }

    func search(query: String, page: Int, filters: [ReaderExtensionFilter]) async throws -> ReaderExtensionPagedResult {
        if let subdirectory = configuration.mmrcmsSuggestionSubdirectory {
            guard !query.isEmpty else {
                return ReaderExtensionPagedResult(items: [], hasNextPage: false)
            }
            return try await mmrcmsSuggestions(
                path: configuration.searchPath(query, page, filters),
                subdirectory: subdirectory
            )
        }
        return try await listing(path: configuration.searchPath(query, page, filters))
    }

    func detail(itemKey: String) async throws -> ReaderExtensionItem {
        let url = try resolve(itemKey)
        let document = try await document(url: url)
        let statusText = try document.firstText(
            configuration.detailStatusSelector,
            maximumBytes: ReaderExtensionNativeOutputPolicy.maximumStatusTextBytes
        )
        let item = ReaderExtensionItem(
            key: try ReaderExtensionNativeOutputPolicy.validatedIdentity(canonicalKey(url)),
            title: try ReaderExtensionNativeOutputPolicy.requiredText(
                try document.firstText(
                    configuration.detailTitleSelector,
                    maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
                ) ?? url.lastPathComponent,
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
            ),
            url: url,
            coverURL: ReaderExtensionSecurityPolicy.validatedAssetURL(
                try document.firstURL(configuration.detailCoverSelector, attributes: ["data-src", "data-lazy-src", "src"], relativeTo: source.baseURL),
                sourceID: source.id,
                approvedDomains: approvedDomains,
                consentScopeID: consentScopeID
            ),
            description: try document.firstText(
                configuration.detailDescriptionSelector,
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumDescriptionBytes
            ),
            author: try document.firstText(
                configuration.detailAuthorSelector,
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumPersonBytes
            ),
            status: ReaderExtensionNativeParsing.status(statusText),
            tags: try document.texts(
                configuration.detailGenreSelector,
                maximumCount: ReaderExtensionNativeOutputPolicy.maximumTagCount,
                maximumBytesEach: ReaderExtensionNativeOutputPolicy.maximumTagBytes
            ),
            maturity: source.maturity
        )
        var budget = ReaderExtensionNativeModelBudget()
        try budget.consume(item)
        return item
    }

    func chapters(itemKey: String) async throws -> [ReaderExtensionChapter] {
        let url = try resolve(itemKey)
        var document = try await document(url: url)
        var rows = try document.select(configuration.chapterContainerSelector).array()
        if rows.isEmpty, source.implementation == .madara {
            // The AJAX endpoint is the primary chapter carrier on current
            // Madara themes, so a transport failure must surface instead of
            // rendering as a series with no chapters. Themes that predate the
            // endpoint answer with an error page, which parses to zero rows
            // and legitimately falls back to the inline (possibly empty) list.
            let ajaxURL = url.appendingPathComponent("ajax/chapters")
            let response = try await request(url: ajaxURL, method: .post)
            guard response.body.count <= ReaderExtensionSecurityPolicy.maximumDOMBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            document = try ReaderExtensionNativeHTMLParser.parse(
                response.bodyString,
                baseURL: ajaxURL.absoluteString
            )
            rows = try document.select(configuration.chapterContainerSelector).array()
        }
        var budget = ReaderExtensionNativeModelBudget()
        var chapters: [ReaderExtensionChapter] = []
        chapters.reserveCapacity(min(rows.count, 10_000))
        for row in rows.prefix(10_000) {
            guard let anchor = try row.select(configuration.chapterAnchorSelector).first(),
                  let href = try anchor.boundedAttribute(
                    "href",
                    maximumBytes: ReaderExtensionNativeOutputPolicy.maximumURLBytes
                  ),
                  let chapterURL = URL(string: href, relativeTo: url)?.absoluteURL else { continue }
            _ = try ReaderExtensionNativeOutputPolicy.validatedURL(chapterURL)
            let title = try anchor.boundedText(
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
            ) ?? ReaderExtensionNativeOutputPolicy.requiredText(
                chapterURL.lastPathComponent,
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
            )
            let dateElement = try row.select(configuration.chapterDateSelector).first()
            let dateText = try dateElement?.boundedText(
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumDateTextBytes
            )
            let chapter = ReaderExtensionChapter(
                key: try ReaderExtensionNativeOutputPolicy.validatedIdentity(canonicalKey(chapterURL)),
                title: title,
                url: chapterURL,
                uploadedAt: ReaderExtensionNativeParsing.date(dateText, source: source),
                scanlator: nil,
                isFiller: false,
                thumbnailURL: nil,
                summary: nil
            )
            try budget.consume(chapter)
            chapters.append(chapter)
        }
        return chapters
    }

    func pages(chapterKey: String) async throws -> [ReaderExtensionPage] {
        let url = try resolve(chapterKey)
        let document = try await document(url: url)
        var urls = try document.urls(configuration.pageImageSelector, attributes: ["data-src", "data-lazy-src", "src"], relativeTo: url)
        if urls.count <= 1, let body = try? document.outerHtml(),
           let range = body.range(of: "\\\"images\\\"\\s*:\\s*(\\[[^;]+?\\])", options: .regularExpression),
           let data = String(body[range]).split(separator: ":", maxSplits: 1).last?.data(using: .utf8) {
            try ReaderExtensionJSONPreflight.validate(data, limits: .init(
                maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
                maximumDepth: 8,
                maximumContainerEntries: 10_000,
                maximumTopLevelEntries: 10_000,
                maximumTotalTokens: 20_000,
                maximumStringBytes: ReaderExtensionNativeOutputPolicy.maximumURLBytes
            ))
            guard let strings = try? JSONDecoder().decode([String].self, from: data),
                  strings.count <= 10_000 else {
                throw ReaderExtensionError.resultInvalid("native page list is invalid")
            }
            urls = strings.compactMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        }
        var seen = Set<String>()
        var budget = ReaderExtensionNativeModelBudget()
        var pages: [ReaderExtensionPage] = []
        pages.reserveCapacity(min(urls.count, 10_000))
        for pageURL in urls.prefix(10_000) {
            _ = try ReaderExtensionNativeOutputPolicy.validatedURL(pageURL)
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(pageURL)
            try ReaderExtensionSecurityPolicy.validateNotArchive(data: Data(), response: nil, url: pageURL)
            guard seen.insert(pageURL.absoluteString).inserted else { continue }
            let page = ReaderExtensionPage(
                key: pageURL.absoluteString,
                url: pageURL,
                headers: [:]
            )
            try budget.consume(page)
            pages.append(page)
        }
        return pages
    }

    func filters() async throws -> [ReaderExtensionFilter] { configuration.filters }

    func preferences() async throws -> [ReaderExtensionPreference] {
        []
    }

    private func listing(path: String) async throws -> ReaderExtensionPagedResult {
        let url = try resolve(path)
        let document = try await document(url: url)
        let rows = try document.select(configuration.listContainerSelector).array()
        var budget = ReaderExtensionNativeModelBudget()
        var items: [ReaderExtensionItem] = []
        items.reserveCapacity(min(rows.count, ReaderExtensionSecurityPolicy.maximumResultRows))
        for row in rows.prefix(ReaderExtensionSecurityPolicy.maximumResultRows) {
            guard let anchor = try row.select(configuration.listAnchorSelector).first(),
                  let href = try anchor.boundedAttribute(
                    "href",
                    maximumBytes: ReaderExtensionNativeOutputPolicy.maximumURLBytes
                  ),
                  let itemURL = URL(string: href, relativeTo: source.baseURL)?.absoluteURL,
                  let itemKey = ReaderExtensionSecurityPolicy.persistableProviderContentKey(
                    canonicalKey(itemURL),
                    maximumBytes: ReaderExtensionNativeOutputPolicy.maximumIdentityBytes
                  ) else { continue }
            _ = try ReaderExtensionNativeOutputPolicy.validatedURL(itemURL)
            let title = try anchor.boundedAttribute(
                "title",
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
            ) ?? anchor.boundedText(
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
            ) ?? ReaderExtensionNativeOutputPolicy.requiredText(
                itemURL.lastPathComponent,
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
            )
            let item = ReaderExtensionItem(
                key: itemKey,
                title: title,
                url: itemURL,
                coverURL: ReaderExtensionSecurityPolicy.validatedAssetURL(
                    try row.firstURL(configuration.listImageSelector, attributes: ["data-src", "data-lazy-src", "src"], relativeTo: source.baseURL),
                    sourceID: source.id,
                    approvedDomains: approvedDomains,
                    consentScopeID: consentScopeID
                ),
                maturity: source.maturity
            )
            try budget.consume(item)
            items.append(item)
        }
        // These HTML families do not expose a reliable response-side page
        // count. Only claim another page when the returned document contains
        // a concrete next-page link; a nonempty final page is not evidence.
        let nextPageSelector = "a[rel=next][href], a.next[href], a.nextpostslink[href], li.next a[href], .nav-previous a[href], .pagination li.active + li a[href]"
        let hasNextPage = try document.select(nextPageSelector).first() != nil
        return ReaderExtensionPagedResult(items: items, hasNextPage: hasNextPage)
    }

    private func mmrcmsSuggestions(
        path: String,
        subdirectory: String
    ) async throws -> ReaderExtensionPagedResult {
        let url = try resolve(path)
        let response = try await request(url: url, method: .get)
        guard response.body.count <= ReaderExtensionSecurityPolicy.maximumDOMBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        try ReaderExtensionJSONPreflight.validate(response.body, limits: .init(
            maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
            maximumDepth: 8,
            maximumContainerEntries: 10_000,
            maximumTopLevelEntries: 100,
            maximumTotalTokens: 50_000,
            maximumStringBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
        ))
        guard let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let suggestions = root["suggestions"] as? [[String: Any]] else {
            throw ReaderExtensionError.resultInvalid("MMRCMS search suggestions are invalid")
        }

        var budget = ReaderExtensionNativeModelBudget()
        var items: [ReaderExtensionItem] = []
        items.reserveCapacity(min(suggestions.count, ReaderExtensionSecurityPolicy.maximumResultRows))
        for suggestion in suggestions.prefix(ReaderExtensionSecurityPolicy.maximumResultRows) {
            guard let rawTitle = suggestion["value"] as? String,
                  let rawIdentifier = suggestion["data"] as? String,
                  let title = try ReaderExtensionNativeOutputPolicy.optionalText(
                    rawTitle,
                    maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
                  ),
                  let identifier = try ReaderExtensionNativeOutputPolicy.optionalText(
                    rawIdentifier,
                    maximumBytes: ReaderExtensionNativeOutputPolicy.maximumIdentityBytes
                  ),
                  let itemURL = mmrcmsItemURL(
                    identifier: identifier,
                    subdirectory: subdirectory
                  ) else { continue }
            _ = try ReaderExtensionNativeOutputPolicy.validatedURL(itemURL)
            let coverURL = source.baseURL
                .appendingPathComponent("uploads")
                .appendingPathComponent("manga")
                .appendingPathComponent(itemURL.lastPathComponent)
                .appendingPathComponent("cover")
                .appendingPathComponent("cover_250x350.jpg")
            let item = ReaderExtensionItem(
                key: try ReaderExtensionNativeOutputPolicy.validatedIdentity(canonicalKey(itemURL)),
                title: title,
                url: itemURL,
                coverURL: ReaderExtensionSecurityPolicy.validatedAssetURL(
                    coverURL,
                    sourceID: source.id,
                    approvedDomains: approvedDomains,
                    consentScopeID: consentScopeID
                ),
                maturity: source.maturity
            )
            try budget.consume(item)
            items.append(item)
        }
        return ReaderExtensionPagedResult(items: items, hasNextPage: false)
    }

    private func mmrcmsItemURL(
        identifier: String,
        subdirectory: String
    ) -> URL? {
        guard !identifier.contains("\\"),
              !identifier.contains("?"),
              !identifier.contains("#"),
              !identifier.contains(":") else { return nil }
        let segments = identifier.split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.isEmpty,
              segments.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        var url = source.baseURL
        if !subdirectory.isEmpty {
            url.appendPathComponent(subdirectory)
        }
        for segment in segments {
            url.appendPathComponent(String(segment))
        }
        guard ReaderExtensionSecurityPolicy.canonicalHost(of: url)
                == ReaderExtensionSecurityPolicy.canonicalHost(of: source.baseURL) else {
            return nil
        }
        return url
    }

    private func document(url: URL) async throws -> Document {
        let response = try await request(url: url, method: .get)
        guard response.body.count <= ReaderExtensionSecurityPolicy.maximumDOMBytes else { throw ReaderExtensionError.contentTooLarge }
        return try ReaderExtensionNativeHTMLParser.parse(
            response.bodyString,
            baseURL: response.finalURL.absoluteString
        )
    }

    private func request(url: URL, method: ReaderExtensionNetworkRequest.Method) async throws -> ReaderExtensionNetworkResponse {
        try await network.request(ReaderExtensionNetworkRequest(
            method: method,
            url: url,
            sourceID: source.id,
            approvedDomains: approvedDomains,
            baseDomain: source.baseURL.host,
            hostGeneratedOriginReferer: source.baseURL
        ))
    }

    private func resolve(_ key: String) throws -> URL {
        guard let url = URL(string: key, relativeTo: source.baseURL)?.absoluteURL else {
            throw ReaderExtensionError.resultInvalid("invalid source URL")
        }
        return url
    }

    private func canonicalKey(_ url: URL) -> String {
        if ReaderExtensionSecurityPolicy.canonicalHost(of: url)
            == ReaderExtensionSecurityPolicy.canonicalHost(of: source.baseURL) {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            components?.scheme = nil; components?.host = nil; components?.port = nil; components?.fragment = nil
            return components?.string ?? url.path
        }
        return ReaderExtensionURLCanonicalizer.canonicalString(url)
    }
}

private final class ReaderExtensionNepNepProvider: ReaderSourceProvider {
    let source: ReaderExtensionInstalledSource
    private let network: ReaderExtensionNetworkClient
    private let approvedDomains: Set<String>
    private let consentScopeID: String

    init(
        source: ReaderExtensionInstalledSource,
        network: ReaderExtensionNetworkClient,
        approvedDomains: Set<String>,
        consentScopeID: String
    ) {
        self.source = source
        self.network = network
        self.approvedDomains = approvedDomains
        self.consentScopeID = consentScopeID
    }

    func popular(page: Int) async throws -> ReaderExtensionPagedResult {
        try await Self.sorted(directory(), by: "vm", ascending: false)
            .paged(source: source, approvedDomains: approvedDomains, consentScopeID: consentScopeID, page: page)
    }

    func latest(page: Int) async throws -> ReaderExtensionPagedResult {
        try await Self.sorted(directory(), by: "lt", ascending: false)
            .paged(source: source, approvedDomains: approvedDomains, consentScopeID: consentScopeID, page: page)
    }

    func search(query: String, page: Int, filters: [ReaderExtensionFilter]) async throws -> ReaderExtensionPagedResult {
        let normalizedQuery = Self.normalized(query)
        var rows = Self.sorted(try await directory(), by: "lt", ascending: false)
            .filter { normalizedQuery.isEmpty || Self.normalized(Self.rowString($0, key: "s")).contains(normalizedQuery) }

        for filter in filters {
            switch filter.abiType ?? filter.key {
            case "YearFilter":
                rows = Self.filter(rows, field: "y", contains: Self.stringValue(filter))
            case "AuthorFilter":
                rows = Self.filter(rows, field: "a", contains: Self.stringValue(filter))
            case "ScanStatusFilter":
                rows = Self.filter(rows, field: "ss", containsSelectionFrom: filter)
            case "PublishStatusFilter":
                rows = Self.filter(rows, field: "ps", containsSelectionFrom: filter)
            case "TypeFilter":
                rows = Self.filter(rows, field: "t", containsSelectionFrom: filter)
            case "TranslationFilter":
                let selection = Self.stringValue(filter)
                if !selection.isEmpty, selection != "Any" {
                    rows = Self.filter(rows, field: "o", contains: "yes")
                }
            case "SortFilter":
                let field: String
                switch Self.stringValue(filter) {
                case "Alphabetically": field = "s"
                case "Date updated": field = "v"
                default: field = "ls"
                }
                rows = Self.sorted(rows, by: field, ascending: filter.sortAscending ?? false)
            case "GenresFilter":
                let included = filter.children
                    .filter { Self.triState($0) == 1 }
                    .map(Self.parameterValue)
                    .filter { !$0.isEmpty }
                let excluded = filter.children
                    .filter { Self.triState($0) == 2 }
                    .map(Self.parameterValue)
                    .filter { !$0.isEmpty }
                for genre in included {
                    rows = Self.filter(rows, field: "g", contains: genre)
                }
                for genre in excluded {
                    let normalizedGenre = Self.normalized(genre)
                    rows = rows.filter {
                        !Self.normalized(Self.rowString($0, key: "g")).contains(normalizedGenre)
                    }
                }
            default:
                continue
            }
        }

        return try rows.paged(
            source: source,
            approvedDomains: approvedDomains,
            consentScopeID: consentScopeID,
            page: page
        )
    }

    func filters() async throws -> [ReaderExtensionFilter] { Self.filterSchema }

    func detail(itemKey: String) async throws -> ReaderExtensionItem {
        let url = source.baseURL.appendingPathComponent("manga").appendingPathComponent(itemKey)
        let doc = try await document(url)
        let statusText = try doc.firstText(
            "li:contains(Status) a",
            maximumBytes: ReaderExtensionNativeOutputPolicy.maximumStatusTextBytes
        )
        let item = ReaderExtensionItem(
            key: try ReaderExtensionNativeOutputPolicy.validatedIdentity(itemKey),
            title: try ReaderExtensionNativeOutputPolicy.requiredText(
                try doc.firstText(
                    "h1, .panel-title",
                    maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
                ) ?? itemKey,
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
            ),
            url: url,
            coverURL: ReaderExtensionSecurityPolicy.validatedAssetURL(
                try doc.firstURL("img.img-responsive, .row img", attributes: ["src", "data-src"], relativeTo: source.baseURL),
                sourceID: source.id,
                approvedDomains: approvedDomains,
                consentScopeID: consentScopeID
            ),
            description: try doc.firstText(
                "li:contains(Description) div, .description",
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumDescriptionBytes
            ),
            author: try doc.firstText(
                "li:contains(Author) a",
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumPersonBytes
            ),
            status: ReaderExtensionNativeParsing.status(statusText),
            tags: try doc.texts(
                "li:contains(Genre) a",
                maximumCount: ReaderExtensionNativeOutputPolicy.maximumTagCount,
                maximumBytesEach: ReaderExtensionNativeOutputPolicy.maximumTagBytes
            ),
            maturity: source.maturity
        )
        var budget = ReaderExtensionNativeModelBudget()
        try budget.consume(item)
        return item
    }

    func chapters(itemKey: String) async throws -> [ReaderExtensionChapter] {
        let url = source.baseURL.appendingPathComponent("manga").appendingPathComponent(itemKey)
        let html = try await response(url).bodyString
        guard let json = ReaderExtensionNativeParsing.substring(html, after: "vm.Chapters = ", before: ";"),
              let data = json.data(using: .utf8) else { return [] }
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
            maximumDepth: 16,
            maximumContainerEntries: 10_000,
            maximumTopLevelEntries: 10_000,
            maximumTotalTokens: 250_000,
            maximumStringBytes: ReaderExtensionNativeOutputPolicy.maximumDescriptionBytes
        ))
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= 10_000 else { return [] }
        var budget = ReaderExtensionNativeModelBudget()
        var chapters: [ReaderExtensionChapter] = []
        chapters.reserveCapacity(min(rows.count, 10_000))
        for row in rows.prefix(10_000) {
            guard let encoded = (row["Chapter"] as? String) ?? (row["Chapter"] as? NSNumber).map({ String(describing: $0) }),
                  let path = Self.chapterPathComponent(encoded) else { continue }
            let fallbackType = (row["Type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter"
            let title = try ReaderExtensionNativeOutputPolicy.requiredText(
                (row["ChapterName"] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
                    ?? "\(fallbackType) \(Self.chapterImageNumber(encoded, cleaned: true))",
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
            )
            let key = "/read-online/\(itemKey)\(path)"
            let chapter = ReaderExtensionChapter(
                key: try ReaderExtensionNativeOutputPolicy.validatedIdentity(key),
                title: title,
                url: try ReaderExtensionNativeOutputPolicy.validatedURL(
                    URL(string: key, relativeTo: source.baseURL)?.absoluteURL
                ),
                uploadedAt: ReaderExtensionNativeParsing.date(row["Date"] as? String, source: source),
                scanlator: nil,
                isFiller: false,
                thumbnailURL: nil,
                summary: nil
            )
            try budget.consume(chapter)
            chapters.append(chapter)
        }
        return chapters
    }

    // Faithful ports of upstream NepNep's chapterURLEncode/chapterImage: the
    // directory's packed chapter code ("100010") is never a URL or image
    // number verbatim — every chapter open 404s without this decode.
    static func chapterPathComponent(_ encoded: String) -> String? {
        guard encoded.count >= 2,
              encoded.allSatisfy(\.isNumber),
              let value = Int(encoded),
              let indexDigit = encoded.first.flatMap({ Int(String($0)) }),
              let pathDigit = encoded.last.flatMap({ Int(String($0)) }) else { return nil }
        let index = indexDigit != 1 ? "-index-\(indexDigit)" : ""
        let digits: Int
        if value < 100_100 {
            digits = 4
        } else if value < 101_000 {
            digits = 3
        } else if value < 110_000 {
            digits = 2
        } else {
            digits = 1
        }
        guard digits <= encoded.count - 1 else { return nil }
        let start = encoded.index(encoded.startIndex, offsetBy: digits)
        let number = String(encoded[start..<encoded.index(before: encoded.endIndex)])
        let suffix = pathDigit != 0 ? ".\(pathDigit)" : ""
        return "-chapter-\(number)\(suffix)\(index).html"
    }

    static func chapterImageNumber(_ encoded: String, cleaned: Bool) -> String {
        guard encoded.count >= 2, encoded.allSatisfy(\.isNumber) else { return encoded }
        var number = String(encoded.dropFirst().dropLast())
        if cleaned {
            number = String(number.drop(while: { $0 == "0" }))
        }
        let part = encoded.last.flatMap { Int(String($0)) } ?? 0
        if part == 0 {
            return number.isEmpty ? "0" : number
        }
        return "\(number).\(part)"
    }

    func pages(chapterKey: String) async throws -> [ReaderExtensionPage] {
        guard let url = URL(string: chapterKey, relativeTo: source.baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            throw ReaderExtensionError.resultInvalid("NepNep chapter URL is invalid")
        }
        let html = try await response(url).bodyString
        guard let raw = ReaderExtensionNativeParsing.substring(html, after: "vm.CurChapter = ", before: ";"),
              let data = raw.data(using: .utf8) else { return [] }
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
            maximumDepth: 12,
            maximumContainerEntries: 200,
            maximumTopLevelEntries: 200,
            maximumTotalTokens: 2_000,
            maximumStringBytes: ReaderExtensionNativeOutputPolicy.maximumDescriptionBytes
        ))
        guard let chapter = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = ReaderExtensionNativeParsing.substring(html, after: "vm.CurPathName = \"", before: "\"") else { return [] }
        let count = Int(String(describing: chapter["Page"] ?? "0")) ?? 0
        guard count > 0, count <= 10_000 else { return [] }
        let directory = (chapter["Directory"] as? String).flatMap { $0 == "null" || $0.isEmpty ? nil : $0 + "/" } ?? ""
        let slug = chapterKey.replacingOccurrences(of: "^.*?/read-online/", with: "", options: .regularExpression).replacingOccurrences(of: "-chapter-.*$", with: "", options: .regularExpression)
        let number = Self.chapterImageNumber(String(describing: chapter["Chapter"] ?? "0"), cleaned: false)
        guard let imageHost = ReaderExtensionSecurityPolicy.canonicalHost(path) else {
            throw ReaderExtensionError.resultInvalid("NepNep image host is invalid")
        }
        let imageAuthority = imageHost.contains(":") ? "[\(imageHost)]" : imageHost
        var budget = ReaderExtensionNativeModelBudget()
        var pages: [ReaderExtensionPage] = []
        pages.reserveCapacity(count)
        for index in 1...count {
            let value = "https://\(imageAuthority)/manga/\(slug)/\(directory)\(number)-\(String(format: "%03d", index)).png"
            guard let pageURL = URL(string: value) else { continue }
            _ = try ReaderExtensionNativeOutputPolicy.validatedURL(pageURL)
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(pageURL, requireHTTPS: true)
            try ReaderExtensionSecurityPolicy.validateNotArchive(data: Data(), response: nil, url: pageURL)
            let page = ReaderExtensionPage(key: value, url: pageURL, headers: [:])
            try budget.consume(page)
            pages.append(page)
        }
        return pages
    }

    private func directory() async throws -> [[String: Any]] {
        let html = try await response(source.baseURL.appendingPathComponent("search")).bodyString
        guard let raw = ReaderExtensionNativeParsing.substring(html, after: "vm.Directory = ", before: "vm.GetIntValue"),
              let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start <= end,
              let data = String(raw[start...end]).data(using: .utf8) else {
            throw ReaderExtensionError.resultInvalid("NepNep directory data is missing")
        }
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
            maximumDepth: 16,
            maximumContainerEntries: 20_000,
            maximumTopLevelEntries: 20_000,
            maximumTotalTokens: 400_000,
            maximumStringBytes: ReaderExtensionNativeOutputPolicy.maximumDescriptionBytes
        ))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= 20_000 else {
            throw ReaderExtensionError.resultInvalid("NepNep directory data is invalid")
        }
        let boundedRows = rows
        for row in boundedRows {
            if let title = row["s"] as? String,
               title.utf8.count > ReaderExtensionNativeOutputPolicy.maximumTitleBytes {
                throw ReaderExtensionError.contentTooLarge
            }
            for key in ["cover", "imageUrl"] {
                if let value = row[key] as? String,
                   value.utf8.count > ReaderExtensionNativeOutputPolicy.maximumURLBytes {
                    throw ReaderExtensionError.contentTooLarge
                }
            }
            if let identity = row["i"] as? String,
               identity.utf8.count > ReaderExtensionNativeOutputPolicy.maximumIdentityBytes {
                throw ReaderExtensionError.contentTooLarge
            }
        }
        return boundedRows
    }

    private func response(_ url: URL) async throws -> ReaderExtensionNetworkResponse {
        let result = try await network.request(ReaderExtensionNetworkRequest(
            url: url,
            sourceID: source.id,
            approvedDomains: approvedDomains,
            baseDomain: source.baseURL.host,
            hostGeneratedOriginReferer: source.baseURL
        ))
        guard result.body.count <= ReaderExtensionSecurityPolicy.maximumDOMBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        return result
    }

    private func document(_ url: URL) async throws -> Document {
        let result = try await response(url)
        guard result.body.count <= ReaderExtensionSecurityPolicy.maximumDOMBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        return try ReaderExtensionNativeHTMLParser.parse(
            result.bodyString,
            baseURL: result.finalURL.absoluteString
        )
    }

    private static let genreNames = [
        "Action", "Adult", "Adventure", "Comedy", "Doujinshi", "Drama",
        "Ecchi", "Fantasy", "Gender Bender", "Harem", "Hentai",
        "Historical", "Horror", "Isekai", "Josei", "Lolicon",
        "Martial Arts", "Mature", "Mecha", "Mystery", "Psychological",
        "Romance", "School Life", "Sci-fi", "Seinen", "Shotacon",
        "Shoujo", "Shoujo Ai", "Shounen", "Shounen Ai", "Slice of Life",
        "Smut", "Sports", "Supernatural", "Tragedy", "Yaoi", "Yuri"
    ]

    private static let filterSchema: [ReaderExtensionFilter] = [
        ReaderExtensionFilter(
            key: "YearFilter", title: "Years", kind: .text,
            options: [], value: .string(""), abiType: "YearFilter"
        ),
        ReaderExtensionFilter(
            key: "AuthorFilter", title: "Author", kind: .text,
            options: [], value: .string(""), abiType: "AuthorFilter"
        ),
        ReaderExtensionFilter(
            key: "ScanStatusFilter", title: "Scan Status", kind: .select,
            options: ["Any", "Complete", "Discontinued", "Hiatus", "Incomplete", "Ongoing"]
                .map { .init(label: $0, value: $0) },
            value: .string("Any"), abiType: "ScanStatusFilter"
        ),
        ReaderExtensionFilter(
            key: "PublishStatusFilter", title: "Publish Status", kind: .select,
            options: ["Any", "Cancelled", "Complete", "Discontinued", "Hiatus", "Incomplete", "Ongoing", "Unfinished"]
                .map { .init(label: $0, value: $0) },
            value: .string("Any"), abiType: "PublishStatusFilter"
        ),
        ReaderExtensionFilter(
            key: "TypeFilter", title: "Type", kind: .select,
            options: ["Any", "Doujinshi", "Manga", "Manhua", "Manhwa", "OEL", "One-shot"]
                .map { .init(label: $0, value: $0) },
            value: .string("Any"), abiType: "TypeFilter"
        ),
        ReaderExtensionFilter(
            key: "TranslationFilter", title: "Translation", kind: .select,
            options: ["Any", "Official Only"].map { .init(label: $0, value: $0) },
            value: .string("Any"), abiType: "TranslationFilter"
        ),
        ReaderExtensionFilter(
            key: "SortFilter", title: "Sort", kind: .sort,
            options: ["Alphabetically", "Date updated", "Popularity"]
                .map { .init(label: $0, value: $0) },
            value: .string("Popularity"), abiType: "SortFilter",
            sortAscending: false
        ),
        ReaderExtensionFilter(
            key: "GenresFilter", title: "Genres", kind: .group,
            options: [], value: .string(""), abiType: "GenresFilter",
            children: genreNames.map { genre in
                ReaderExtensionFilter(
                    key: "genre.\(genre.lowercased().replacingOccurrences(of: " ", with: "-"))",
                    title: genre,
                    kind: .triState,
                    options: [],
                    value: .number(0),
                    abiType: "TriStateFilter",
                    abiValue: .string(genre)
                )
            }
        )
    ]

    private static func filter(
        _ rows: [[String: Any]],
        field: String,
        containsSelectionFrom filter: ReaderExtensionFilter
    ) -> [[String: Any]] {
        let selection = stringValue(filter)
        guard !selection.isEmpty, selection != "Any" else { return rows }
        return self.filter(rows, field: field, contains: selection)
    }

    private static func filter(
        _ rows: [[String: Any]],
        field: String,
        contains value: String
    ) -> [[String: Any]] {
        let needle = normalized(value)
        guard !needle.isEmpty else { return rows }
        return rows.filter { normalized(rowString($0, key: field)).contains(needle) }
    }

    private static func sorted(
        _ rows: [[String: Any]],
        by field: String,
        ascending: Bool
    ) -> [[String: Any]] {
        rows.sorted { left, right in
            let leftNumber = numericValue(left[field])
            let rightNumber = numericValue(right[field])
            if let leftNumber, let rightNumber, leftNumber != rightNumber {
                return ascending ? leftNumber < rightNumber : leftNumber > rightNumber
            }
            let comparison = rowString(left, key: field).localizedCaseInsensitiveCompare(
                rowString(right, key: field)
            )
            guard comparison != .orderedSame else { return false }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func rowString(_ row: [String: Any], key: String) -> String {
        if let value = row[key] as? String { return value }
        if let values = row[key] as? [String] { return values.joined(separator: ",") }
        if let number = row[key] as? NSNumber { return number.stringValue }
        return ""
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    private static func stringValue(_ filter: ReaderExtensionFilter) -> String {
        if case .string(let value) = filter.value { return value }
        return ""
    }

    private static func triState(_ filter: ReaderExtensionFilter) -> Int {
        switch filter.value {
        case .number(let value): return Int(value)
        case .bool(let value): return value ? 1 : 0
        case .string(let value): return Int(value) ?? 0
        case .stringList, .secretReference: return 0
        }
    }

    private static func parameterValue(_ filter: ReaderExtensionFilter) -> String {
        if let abiValue = filter.abiValue,
           case .string(let value) = abiValue {
            return value
        }
        return filter.title
    }
}

private enum ReaderExtensionNativeHTMLParser {
    static func parse(_ html: String, baseURL: String) throws -> Document {
        try ReaderExtensionHTMLPreflight.validate(
            html,
            maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
            maximumNodeTokens: ReaderExtensionSecurityPolicy.maximumDOMElementsPerDocument
        )
        let document = try SwiftSoup.parse(html, baseURL)
        guard try document.getAllElements().size()
            <= ReaderExtensionSecurityPolicy.maximumDOMElementsPerDocument else {
            throw ReaderExtensionError.contentTooLarge
        }
        return document
    }
}

private enum ReaderExtensionNativeParsing {
    static func status(_ text: String?) -> ReaderExtensionPublicationStatus {
        let value = text?.lowercased() ?? ""
        if value.contains("complete") || value.contains("finished") || value.contains("conclu") || value.contains("finalizado") { return .completed }
        if value.contains("hiatus") || value.contains("hold") || value.contains("paus") { return .hiatus }
        if value.contains("cancel") || value.contains("drop") || value.contains("aband") { return .cancelled }
        if value.contains("ongoing") || value.contains("publishing") || value.contains("curso") || value.contains("andamento") { return .ongoing }
        return .unknown
    }

    static func date(_ text: String?, source: ReaderExtensionInstalledSource) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let seconds = TimeInterval(text), seconds > 1_000_000 { return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: source.dateFormatLocale?.replacingOccurrences(of: "_", with: "-") ?? "en_US_POSIX")
        formatter.dateFormat = source.dateFormat ?? "MMMM dd, yyyy"
        if let parsed = formatter.date(from: trimmed) { return parsed }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    static func substring(_ source: String, after prefix: String, before suffix: String) -> String? {
        guard let start = source.range(of: prefix)?.upperBound, let end = source.range(of: suffix, range: start..<source.endIndex)?.lowerBound else { return nil }
        return String(source[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array where Element == [String: Any] {
    static var nepNepDirectoryPageSize: Int { 60 }

    // Upstream NepNep hands the app the whole ~8,000-row directory in one
    // result. Slicing it here keeps every row reachable through ordinary
    // load-more paging instead of hard-truncating at the first result cap.
    func paged(
        source: ReaderExtensionInstalledSource,
        approvedDomains: Set<String>,
        consentScopeID: String,
        page: Int = 1
    ) throws -> ReaderExtensionPagedResult {
        let pageSize = Self.nepNepDirectoryPageSize
        let start = Swift.max(0, (Swift.max(1, page) - 1) * pageSize)
        guard start < count else {
            return ReaderExtensionPagedResult(items: [], hasNextPage: false)
        }
        let end = Swift.min(count, start + pageSize)
        var budget = ReaderExtensionNativeModelBudget()
        var items: [ReaderExtensionItem] = []
        items.reserveCapacity(end - start)
        for row in self[start..<end] {
            guard let rawTitle = row["s"] as? String else { continue }
            let title = try ReaderExtensionNativeOutputPolicy.requiredText(
                rawTitle,
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumTitleBytes
            )
            guard let key = ReaderExtensionSecurityPolicy.persistableProviderContentKey(
                String(describing: row["i"] ?? title),
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumIdentityBytes
            ) else { continue }
            let rawCover = (row["cover"] as? String)
                ?? (row["imageUrl"] as? String)
                ?? (row["i"] as? String).map { "https://temp.compsci88.com/cover/\($0).jpg" }
            if let rawCover,
               rawCover.utf8.count > ReaderExtensionNativeOutputPolicy.maximumURLBytes {
                throw ReaderExtensionError.contentTooLarge
            }
            let candidate = rawCover.flatMap {
                URL(string: $0, relativeTo: source.baseURL)?.absoluteURL
            }
            let coverURL = ReaderExtensionSecurityPolicy.validatedAssetURL(
                candidate,
                sourceID: source.id,
                approvedDomains: approvedDomains,
                consentScopeID: consentScopeID
            )
            let item = ReaderExtensionItem(key: key, title: title, coverURL: coverURL, maturity: source.maturity)
            try budget.consume(item)
            items.append(item)
        }
        return ReaderExtensionPagedResult(items: items, hasNextPage: end < count)
    }
}

private extension Element {
    func firstText(_ selector: String, maximumBytes: Int) throws -> String? {
        guard let element = try select(selector).first() else { return nil }
        return try element.boundedText(maximumBytes: maximumBytes)
    }

    func texts(_ selector: String, maximumCount: Int, maximumBytesEach: Int) throws -> [String] {
        var values: [String] = []
        values.reserveCapacity(min(maximumCount, 32))
        for element in try select(selector).array().prefix(maximumCount) {
            if let value = try element.boundedText(maximumBytes: maximumBytesEach) {
                values.append(value)
            }
        }
        return values
    }

    func boundedText(maximumBytes: Int) throws -> String? {
        try ReaderExtensionNativeOutputPolicy.optionalText(
            try text(),
            maximumBytes: maximumBytes
        )
    }

    func boundedAttribute(_ attribute: String, maximumBytes: Int) throws -> String? {
        try ReaderExtensionNativeOutputPolicy.optionalText(
            try attr(attribute),
            maximumBytes: maximumBytes
        )
    }

    func firstURL(_ selector: String, attributes: [String], relativeTo baseURL: URL) throws -> URL? {
        guard let element = try select(selector).first() else { return nil }
        for attribute in attributes {
            guard let raw = try element.boundedAttribute(
                attribute,
                maximumBytes: ReaderExtensionNativeOutputPolicy.maximumURLBytes
            ) else { continue }
            let value = raw.split(separator: " ").first.map(String.init) ?? raw
            if let url = URL(string: value.hasPrefix("//") ? "https:\(value)" : value, relativeTo: baseURL)?.absoluteURL {
                return try ReaderExtensionNativeOutputPolicy.validatedURL(url)
            }
        }
        return nil
    }

    func urls(_ selector: String, attributes: [String], relativeTo baseURL: URL) throws -> [URL] {
        let elements = try select(selector).array()
        var values: [URL] = []
        values.reserveCapacity(min(elements.count, 10_000))
        for element in elements.prefix(10_000) {
            for attribute in attributes {
                guard let raw = try element.boundedAttribute(
                    attribute,
                    maximumBytes: ReaderExtensionNativeOutputPolicy.maximumURLBytes
                ) else { continue }
                let value = raw.split(separator: " ").first.map(String.init) ?? raw
                if !value.hasPrefix("data:"),
                   let url = URL(string: value.hasPrefix("//") ? "https:\(value)" : value, relativeTo: baseURL)?.absoluteURL,
                   let validated = try ReaderExtensionNativeOutputPolicy.validatedURL(url) {
                    values.append(validated)
                    break
                }
            }
        }
        return values
    }
}
