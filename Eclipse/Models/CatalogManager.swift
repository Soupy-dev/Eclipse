//
//  CatalogManager.swift
//  Eclipse
//
//  Created by Soupy-dev
//

import Foundation
import Combine

class CatalogManager: ObservableObject {
    static let shared = CatalogManager()

    @Published var catalogs: [Catalog] = []
    @Published var performanceModeEnabled: Bool = PerformanceModeSettings.isEnabled

    private let userDefaults = UserDefaults.standard
    private static let legacyCatalogsKey = "enabledCatalogs"

    private var catalogsKey: String
    private var activeProfileID: UUID

    private var activeCatalogStoreIsReadable = false

    init() {
        let profileID = ProfileManager.shared.activeProfileID
        activeProfileID = profileID
        catalogsKey = Self.catalogsKey(for: profileID)
        Self.migrateLegacyStoreIfNeeded()
        loadCatalogs()
    }

    static func catalogsKey(for profileID: UUID) -> String {
        ProfileScopedStorage.defaultsKey(base: legacyCatalogsKey, profileID: profileID)
    }

    private static func migrateLegacyStoreIfNeeded() {
        ProfileScopedStorage.migrateLegacyStoreIfNeeded(marker: "catalogs") {
            let defaults = UserDefaults.standard
            let destinationKey = catalogsKey(for: ProfileManager.defaultProfileID)
            guard defaults.object(forKey: destinationKey) == nil,
                  let legacy = defaults.data(forKey: legacyCatalogsKey) else { return }
            defaults.set(legacy, forKey: destinationKey)
            defaults.removeObject(forKey: legacyCatalogsKey)
        }
    }

    func switchProfile(to profileID: UUID) {
        guard profileID != activeProfileID else { return }
        activeProfileID = profileID
        catalogsKey = Self.catalogsKey(for: profileID)
        performanceModeEnabled = PerformanceModeSettings.isEnabled
        loadCatalogs()
    }

    func catalogsForMediaStateSync(forProfile profileID: UUID) -> [Catalog]? {
        guard profileID != activeProfileID else { return catalogsForMediaStateSync }
        let key = Self.catalogsKey(for: profileID)
        guard userDefaults.object(forKey: key) != nil else {
            return Self.makeBaselineCatalogs(forProfile: profileID).filter(\.isMediaStateSyncEligible)
        }
        guard let data = userDefaults.data(forKey: key) else { return nil }
        guard let stored = try? JSONDecoder().decode([Catalog].self, from: data) else {
            return nil
        }
        let normalized = stored.isEmpty
            ? Self.makeBaselineCatalogs(forProfile: profileID)
            : stored
        return normalized.filter(\.isMediaStateSyncEligible)
    }

    func catalogsForBackup(forProfile profileID: UUID) -> [Catalog]? {
        if profileID == activeProfileID {
            return activeCatalogStoreIsReadable ? catalogs : nil
        }
        let key = Self.catalogsKey(for: profileID)
        guard userDefaults.object(forKey: key) != nil else {
            return Self.makeBaselineCatalogs(forProfile: profileID)
        }
        guard let data = userDefaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([Catalog].self, from: data) else {
            return nil
        }
        return stored.isEmpty ? Self.makeBaselineCatalogs(forProfile: profileID) : stored
    }

    func replaceCatalogsForMediaState(_ newCatalogs: [Catalog], forProfile profileID: UUID) {
        if profileID == activeProfileID {
            replaceCatalogsForMediaState(newCatalogs)
            return
        }

        let storedCatalogs: [Catalog]
        if let storedData = userDefaults.data(forKey: Self.catalogsKey(for: profileID)),
           let decoded = try? JSONDecoder().decode([Catalog].self, from: storedData) {
            storedCatalogs = decoded
        } else {
            storedCatalogs = []
        }
        let localProviderCatalogs = storedCatalogs.filter { !$0.isMediaStateSyncEligible }
        let sharedCatalogs = newCatalogs.filter(\.isMediaStateSyncEligible)
        let normalized = (sharedCatalogs + localProviderCatalogs)
            .sorted { lhs, rhs in
                if lhs.order == rhs.order { return lhs.id < rhs.id }
                return lhs.order < rhs.order
            }
            .enumerated()
            .map { index, catalog -> Catalog in
                var updated = catalog
                updated.order = index
                return updated
            }
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        userDefaults.set(data, forKey: Self.catalogsKey(for: profileID))
    }

    func hasMeaningfulCustomization(forProfile profileID: UUID) -> Bool {
        guard profileID != activeProfileID else { return hasMeaningfulLocalCustomization }
        guard let data = userDefaults.data(forKey: Self.catalogsKey(for: profileID)),
              let stored = try? JSONDecoder().decode([Catalog].self, from: data) else {
            return false
        }
        let normalized = stored.isEmpty
            ? Self.makeBaselineCatalogs(forProfile: profileID)
            : stored
        return normalized != Self.makeBaselineCatalogs(forProfile: profileID)
    }

    func discardStore(forProfile profileID: UUID) {
        guard profileID != activeProfileID else { return }
        userDefaults.removeObject(forKey: Self.catalogsKey(for: profileID))
    }

    private static func makeKidsCatalogs() -> [Catalog] {
        var catalogs: [Catalog] = [
            Catalog(id: "forYou", name: "Just For You", source: .local, isEnabled: true, order: 0),
            Catalog(
                id: Catalog.upNextCatalogId,
                name: "Up Next",
                source: .local,
                isEnabled: true,
                order: 1,
                displayStyle: .continueWatching
            )
        ]
        for (offset, kind) in KidsHomeCatalog.allCases.enumerated() {
            catalogs.append(KidsHomeCatalog.catalog(for: kind, order: catalogs.count + offset))
        }
        catalogs.append(contentsOf: [
            Catalog(id: "networks", name: "Channels", source: .tmdb, isEnabled: true, order: catalogs.count, displayStyle: .network),
            Catalog(id: "genres", name: "Category", source: .tmdb, isEnabled: true, order: catalogs.count + 1, displayStyle: .genre),
            Catalog(id: "companies", name: "Studio", source: .tmdb, isEnabled: true, order: catalogs.count + 2, displayStyle: .company)
        ])
        return catalogs.enumerated().map { index, catalog in
            var updated = catalog
            updated.order = index
            return updated
        }
    }

    static func makeBaselineCatalogs(forProfile profileID: UUID) -> [Catalog] {
        ProfileManager.shared.profile(with: profileID)?.isKidsProfile == true
            ? makeKidsCatalogs()
            : makeDefaultCatalogs()
    }

    private static var baselineCatalogIDs: Set<String> {
        Set(makeDefaultCatalogs().map(\.id)).union(makeKidsCatalogs().map(\.id))
    }

    private static func makeDefaultCatalogs() -> [Catalog] {
        [
            Catalog(id: "forYou", name: "Just For You", source: .local, isEnabled: true, order: 0),
            Catalog(id: "becauseYouWatched", name: "Because You Watched", source: .local, isEnabled: true, order: 1),
            Catalog(id: "trending", name: "Trending This Week", source: .tmdb, isEnabled: true, order: 2),
            Catalog(id: "popularMovies", name: "Popular Movies", source: .tmdb, isEnabled: true, order: 3),
            Catalog(id: "networks", name: "Network", source: .tmdb, isEnabled: true, order: 4, displayStyle: .network),
            Catalog(id: "nowPlayingMovies", name: "Now Playing Movies", source: .tmdb, isEnabled: false, order: 5),
            Catalog(id: "upcomingMovies", name: "Upcoming Movies", source: .tmdb, isEnabled: false, order: 6),
            Catalog(id: "upcomingTV", name: "Upcoming TV Shows", source: .tmdb, isEnabled: false, order: 7),
            Catalog(id: "popularTVShows", name: "Popular TV Shows", source: .tmdb, isEnabled: true, order: 8),
            Catalog(id: "genres", name: "Category", source: .tmdb, isEnabled: true, order: 9, displayStyle: .genre),
            Catalog(id: "onTheAirTV", name: "On The Air TV Shows", source: .tmdb, isEnabled: false, order: 10),
            Catalog(id: "airingTodayTV", name: "Airing Today TV Shows", source: .tmdb, isEnabled: false, order: 11),
            Catalog(id: "topRatedTVShows", name: "Top Rated TV Shows", source: .tmdb, isEnabled: true, order: 12),
            Catalog(id: "topRatedMovies", name: "Top Rated Movies", source: .tmdb, isEnabled: true, order: 13),
            Catalog(id: "companies", name: "Company", source: .tmdb, isEnabled: true, order: 14, displayStyle: .company),
            Catalog(id: "trendingAnime", name: "Trending Anime", source: .anilist, isEnabled: true, order: 15),
            Catalog(id: "popularAnime", name: "Popular Anime", source: .anilist, isEnabled: true, order: 16),
            Catalog(id: "featured", name: "Featured", source: .tmdb, isEnabled: true, order: 17, displayStyle: .featured),
            Catalog(id: "topRatedAnime", name: "Top Rated Anime", source: .anilist, isEnabled: true, order: 18),
            Catalog(id: "airingAnime", name: "Currently Airing Anime", source: .anilist, isEnabled: false, order: 19),
            Catalog(id: "upcomingAnime", name: "Upcoming Anime", source: .anilist, isEnabled: false, order: 20),
            Catalog(id: "bestTVShows", name: "Best TV Shows", source: .tmdb, isEnabled: false, order: 21, displayStyle: .ranked),
            Catalog(id: "bestMovies", name: "Best Movies", source: .tmdb, isEnabled: false, order: 22, displayStyle: .ranked),
            Catalog(id: "bestAnime", name: "Best Anime", source: .anilist, isEnabled: false, order: 23, displayStyle: .ranked),
            Catalog(id: Catalog.upNextCatalogId, name: "Up Next", source: .local, isEnabled: false, order: 24, displayStyle: .continueWatching),
            Catalog(id: Catalog.traktContinueWatchingCatalogId, name: "Trakt Continue Watching", source: .trakt, isEnabled: false, order: 25, displayStyle: .continueWatching)
        ]
    }

    var hasMeaningfulLocalCustomization: Bool {
        catalogs != Self.makeBaselineCatalogs(forProfile: activeProfileID)
    }

    var catalogsForMediaStateSync: [Catalog]? {
        guard activeCatalogStoreIsReadable else { return nil }
        return catalogs.filter(\.isMediaStateSyncEligible)
    }

    private func loadCatalogs() {

        let defaultCatalogs = Self.makeBaselineCatalogs(forProfile: activeProfileID)

        if userDefaults.object(forKey: catalogsKey) != nil {
            guard let data = userDefaults.data(forKey: catalogsKey) else {
                activeCatalogStoreIsReadable = false
                catalogs = defaultCatalogs
                Logger.shared.log(
                    "CatalogManager: the active profile's catalog store has an unsupported storage type; using an unpersisted baseline until valid data is restored or edited",
                    type: "Error"
                )
                return
            }
            guard let savedCatalogs = try? JSONDecoder().decode([Catalog].self, from: data) else {
                activeCatalogStoreIsReadable = false
                catalogs = defaultCatalogs
                Logger.shared.log(
                    "CatalogManager: the active profile's catalog store is unreadable; using an unpersisted baseline until valid data is restored or edited",
                    type: "Error"
                )
                return
            }
            activeCatalogStoreIsReadable = true

            let isKidsProfile = ProfileManager.shared
                .profile(with: activeProfileID)?.isKidsProfile == true
            let savedHasKidsRows = savedCatalogs.contains { KidsHomeCatalog.from(catalogID: $0.id) != nil }
            let baselineIDs = Self.baselineCatalogIDs
            if isKidsProfile != savedHasKidsRows {

                let userAddedRows = savedCatalogs.filter { !baselineIDs.contains($0.id) }
                self.catalogs = (defaultCatalogs + userAddedRows)
                    .enumerated()
                    .map { index, catalog in
                        var updated = catalog
                        updated.order = index
                        return updated
                    }
                saveCatalogs()
                return
            }

            var merged = savedCatalogs.sorted { $0.order < $1.order }
            let existingIds = Set(savedCatalogs.map { $0.id })
            let missingDefaults = defaultCatalogs.filter { !existingIds.contains($0.id) }
            merged.append(contentsOf: missingDefaults)

            merged = merged.enumerated().map { index, catalog in
                var updated = catalog
                updated.order = index
                return updated
            }

            self.catalogs = merged
            if merged != savedCatalogs {
                saveCatalogs()
            }
            return
        }
        self.catalogs = defaultCatalogs
        saveCatalogs()
    }

    func saveCatalogs() {
        if let data = try? JSONEncoder().encode(catalogs) {
            userDefaults.set(data, forKey: catalogsKey)
            activeCatalogStoreIsReadable = true
        }
        NotificationCenter.default.post(name: .catalogDataDidChange, object: self)

        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func replaceCatalogsForMediaState(_ newCatalogs: [Catalog]) {
        let localProviderCatalogs = catalogs.filter { !$0.isMediaStateSyncEligible }
        let sharedCatalogs = newCatalogs.filter(\.isMediaStateSyncEligible)
        catalogs = (sharedCatalogs + localProviderCatalogs)
            .sorted { lhs, rhs in
                if lhs.order == rhs.order { return lhs.id < rhs.id }
                return lhs.order < rhs.order
            }
            .enumerated().map { index, catalog in
            var updated = catalog
            updated.order = index
            return updated
        }
        saveCatalogs()
    }

    func reloadCatalogsForKidsModeChange() {
        loadCatalogs()
    }

    func resetCatalogsForMediaStateAccountChange() {
        userDefaults.removeObject(forKey: catalogsKey)
        loadCatalogs()
    }

    func toggleCatalog(id: String) {
        guard let catalog = catalogs.first(where: { $0.id == id }),
              isCatalogVisible(catalog) else {
            return
        }

        if performanceModeEnabled,
           PerformanceModeSettings.isAnimeCatalog(catalog) {
            let current = isCatalogEffectivelyEnabled(catalog)
            setFastAnimeCatalogEnabled(id: id, isEnabled: !current)
            return
        }

        if let index = catalogs.firstIndex(where: { $0.id == id }) {
            catalogs[index].isEnabled.toggle()
            saveCatalogs()
        }
    }

    func setPerformanceModeEnabled(_ enabled: Bool) {
        guard performanceModeEnabled != enabled else { return }
        PerformanceModeSettings.isEnabled = enabled
        performanceModeEnabled = enabled
    }

    func isCatalogLockedByPerformanceMode(_ catalog: Catalog) -> Bool {
        performanceModeEnabled && PerformanceModeSettings.isAnimeCatalog(catalog)
    }

    func isCatalogEffectivelyEnabled(_ catalog: Catalog) -> Bool {
        guard performanceModeEnabled, PerformanceModeSettings.isAnimeCatalog(catalog) else {
            return catalog.isEnabled
        }
        return PerformanceModeSettings.fastAnimeCatalogEnabled(id: catalog.id, fallback: catalog.isEnabled)
    }

    func setFastAnimeCatalogEnabled(id: String, isEnabled: Bool) {
        guard let catalog = catalogs.first(where: { $0.id == id }),
              PerformanceModeSettings.isAnimeCatalog(catalog) else {
            return
        }
        PerformanceModeSettings.setFastAnimeCatalogEnabled(id: id, isEnabled: isEnabled)
        catalogs = catalogs
    }

    var traktPublicListCatalogs: [Catalog] {
        catalogs
            .filter { $0.source == .trakt && $0.traktListEndpointPath != nil && isCatalogVisible($0) }
            .sorted { $0.order < $1.order }
    }

    func addTraktPublicListCatalog(
        name rawName: String?,
        listId: Int?,
        listUser: String?,
        listSlug: String?,
        mediaType: String,
        sortBy: String,
        sortHow: String
    ) {
        let normalizedUser = listUser?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSlug = listSlug?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (listId ?? 0) > 0 || (normalizedUser?.isEmpty == false && normalizedSlug?.isEmpty == false) else { return }
        let normalizedMediaType = Catalog.normalizedTraktListMediaType(mediaType)
        let catalogId = Catalog.traktPublicListCatalogId(
            listId: listId,
            listUser: normalizedUser,
            listSlug: normalizedSlug,
            mediaType: normalizedMediaType
        )
        let trimmedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let listLabel = listId.map { "\($0)" } ?? normalizedSlug ?? "Custom"
        let fallbackName = normalizedMediaType == "movies"
            ? "Trakt List \(listLabel) Movies"
            : "Trakt List \(listLabel) Shows"
        let nextOrder = (catalogs.map(\.order).max() ?? -1) + 1
        let catalog = Catalog(
            id: catalogId,
            name: trimmedName.isEmpty ? fallbackName : trimmedName,
            source: .trakt,
            isEnabled: true,
            order: nextOrder,
            traktListId: listId,
            traktListUser: normalizedUser,
            traktListSlug: normalizedSlug,
            traktListMediaType: normalizedMediaType,
            traktListSortBy: sortBy,
            traktListSortHow: sortHow
        )

        if let index = catalogs.firstIndex(where: { $0.id == catalogId }) {
            let existing = catalogs[index]
            catalogs[index] = catalog.updatingUserState(isEnabled: existing.isEnabled, order: existing.order)
        } else {
            catalogs.append(catalog)
        }
        normalizeOrdersAndSave(sortFirst: true)
    }

    func removeTraktPublicListCatalog(id: String) {
        guard catalogs.contains(where: { $0.id == id && $0.source == .trakt }) else { return }
        catalogs.removeAll { $0.id == id && $0.source == .trakt }
        normalizeOrdersAndSave(sortFirst: true)
    }

    func moveCatalog(from: IndexSet, to: Int) {
        catalogs.move(fromOffsets: from, toOffset: to)
        normalizeOrdersAndSave(sortFirst: false)
    }

    var visibleCatalogs: [Catalog] {
        catalogs.filter { isCatalogVisible($0) }.sorted { $0.order < $1.order }
    }

    func moveVisibleCatalog(from source: IndexSet, to destination: Int) {
        var visible = visibleCatalogs
        visible.move(fromOffsets: source, toOffset: destination)
        var visibleIterator = visible.makeIterator()

        catalogs = catalogs.map { catalog in
            guard isCatalogVisible(catalog) else { return catalog }
            return visibleIterator.next() ?? catalog
        }
        normalizeOrdersAndSave(sortFirst: false)
    }

    func getEnabledCatalogs() -> [Catalog] {
        catalogs.filter {
            isCatalogVisible($0) && isCatalogEffectivelyEnabled($0) && isCatalogAllowedByContentBlocking($0)
        }.sorted { $0.order < $1.order }
    }

    func isCatalogEnabled(id: String) -> Bool {
        guard let catalog = catalogs.first(where: { $0.id == id }) else { return false }
        return isCatalogVisible(catalog) && isCatalogEffectivelyEnabled(catalog) && isCatalogAllowedByContentBlocking(catalog)
    }

    private var activeStremioAddonIDs: Set<UUID> = []

    func isCatalogAllowedByContentBlocking(_ catalog: Catalog) -> Bool {
        guard catalog.source == .stremio else { return true }
        if ContentBlockingSettings.blocksAddonCatalogs() { return false }

        if let addonId = catalog.stremioAddonId, !activeStremioAddonIDs.contains(addonId) {
            return false
        }
        if let addonId = catalog.stremioAddonId {
            return StremioAddonComponentSettings.isEnabled(
                sourceID: "stremio:\(addonId.uuidString)",
                component: .catalogs
            )
        }
        return true
    }

    func isCatalogVisible(_ catalog: Catalog) -> Bool {
        if catalog.requiresTraktConnection {
            return TrackerManager.shared.trackerState.getAccount(for: .trakt) != nil
        }
        return true
    }

    func syncStremioAddonCatalogs(from addons: [StremioAddon], activeAddonIDs: Set<UUID>) {
        activeStremioAddonIDs = activeAddonIDs
        let addonCatalogs = addons.flatMap { addon in
            addon.manifest.homeCatalogs.compactMap { stremioCatalog -> Catalog? in
                guard !stremioCatalog.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let mediaType = stremioCatalog.eclipseMediaType else {
                    return nil
                }
                let catalogId = Catalog.stremioCatalogId(addon: addon, stremioCatalog: stremioCatalog)
                let name = Self.stremioCatalogDisplayName(stremioCatalog: stremioCatalog)
                return Catalog(
                    id: catalogId,
                    name: name,
                    source: .stremio,
                    isEnabled: true,
                    order: 0,
                    stremioAddonId: addon.id,
                    stremioAddonName: addon.manifest.name,
                    stremioCatalogId: stremioCatalog.id,
                    stremioCatalogType: stremioCatalog.type,
                    stremioMediaType: mediaType
                )
            }
        }

        let validStremioIds = Set(addonCatalogs.map(\.id))
        var existingById = Dictionary(
            catalogs.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        var merged = catalogs.filter { catalog in
            catalog.source != .stremio || validStremioIds.contains(catalog.id)
        }

        var indexByID = Dictionary(
            merged.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        var nextOrder = (merged.map(\.order).max() ?? -1) + 1

        for addonCatalog in addonCatalogs {
            if let index = indexByID[addonCatalog.id] {
                let existing = merged[index]
                merged[index] = addonCatalog.updatingUserState(isEnabled: existing.isEnabled, order: existing.order)
            } else if let existing = existingById[addonCatalog.id] {
                indexByID[addonCatalog.id] = merged.count
                merged.append(addonCatalog.updatingUserState(isEnabled: existing.isEnabled, order: existing.order))
            } else {
                indexByID[addonCatalog.id] = merged.count
                merged.append(addonCatalog.updatingUserState(isEnabled: true, order: nextOrder))
                nextOrder += 1
            }
            existingById[addonCatalog.id] = addonCatalog
        }

        merged = merged
            .sorted { $0.order < $1.order }
            .enumerated()
            .map { index, catalog in
                var updated = catalog
                updated.order = index
                return updated
            }

        guard merged.map(\.id) != catalogs.map(\.id) ||
              zip(merged, catalogs).contains(where: { $0.name != $1.name || $0.isEnabled != $1.isEnabled || $0.order != $1.order }) else {
            return
        }

        catalogs = merged
        saveCatalogs()
    }

    private func normalizeOrdersAndSave(sortFirst: Bool) {
        let orderedCatalogs = sortFirst ? catalogs.sorted { $0.order < $1.order } : catalogs
        catalogs = orderedCatalogs.enumerated().map { index, catalog in
            var updated = catalog
            updated.order = index
            return updated
        }
        saveCatalogs()
    }

    private static func stremioCatalogDisplayName(stremioCatalog: StremioCatalog) -> String {
        let rawName = stremioCatalog.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawName?.isEmpty == false ? rawName! : stremioCatalog.type.capitalized
    }
}

enum PerformanceModeSettings {
    static let enabledKey = "performanceModeEnabled"
    static let skipAniListTraversalForAnimeDetailsKey = "performanceModeSkipAniListTraversalForAnimeDetails"
    static let fastAnimeCatalogOverridesKey = "performanceModeFastAnimeCatalogOverrides"
    static let defaultEnabled = true

    static let animeCatalogIds: Set<String> = [
        "trendingAnime",
        "popularAnime",
        "topRatedAnime",
        "airingAnime",
        "upcomingAnime",
        "bestAnime"
    ]

    private static var defaults: UserDefaults { ProfileSettingsStore.active }

    static var isEnabled: Bool {
        get { (defaults.object(forKey: enabledKey) as? Bool) ?? defaultEnabled }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    static var skipsAniListTraversalForAnimeDetails: Bool {
        get { defaults.bool(forKey: skipAniListTraversalForAnimeDetailsKey) }
        set { defaults.set(newValue, forKey: skipAniListTraversalForAnimeDetailsKey) }
    }

    static var fastAnimeCatalogOverrides: [String: Bool] {
        get {
            guard let data = defaults.data(forKey: fastAnimeCatalogOverridesKey),
                  let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
                return [:]
            }
            return decoded.filter { animeCatalogIds.contains($0.key) }
        }
        set {
            let sanitized = newValue.filter { animeCatalogIds.contains($0.key) }
            guard let data = try? JSONEncoder().encode(sanitized) else { return }
            defaults.set(data, forKey: fastAnimeCatalogOverridesKey)
        }
    }

    static func isAnimeCatalog(_ catalog: Catalog) -> Bool {
        catalog.source == .anilist && animeCatalogIds.contains(catalog.id)
    }

    static func fastAnimeCatalogEnabled(id: String, fallback: Bool) -> Bool {
        fastAnimeCatalogOverrides[id] ?? fallback
    }

    static func setFastAnimeCatalogEnabled(id: String, isEnabled: Bool) {
        guard animeCatalogIds.contains(id) else { return }
        var overrides = fastAnimeCatalogOverrides
        overrides[id] = isEnabled
        fastAnimeCatalogOverrides = overrides
    }

    static func detailCacheKey(for stableIdentity: String) -> String {
        var modes: [String] = []
        if isEnabled {
            modes.append("performanceMode")
        }
        if skipsAniListTraversalForAnimeDetails {
            modes.append("skipAniListTraversal")
        }
        guard !modes.isEmpty else { return stableIdentity }
        return "\(stableIdentity):\(modes.joined(separator: ":"))"
    }
}

struct Catalog: Identifiable, Codable, Equatable {
    static let upNextCatalogId = "upNext"
    static let traktContinueWatchingCatalogId = "traktContinueWatching"

    let id: String
    let name: String
    let source: CatalogSource
    var isEnabled: Bool
    var order: Int
    var displayStyle: CatalogDisplayStyle
    var stremioAddonId: UUID?
    var stremioAddonName: String?
    var stremioCatalogId: String?
    var stremioCatalogType: String?
    var stremioMediaType: String?

    var isMediaStateSyncEligible: Bool { source != .stremio }
    var traktListId: Int?
    var traktListUser: String?
    var traktListSlug: String?
    var traktListMediaType: String?
    var traktListSortBy: String?
    var traktListSortHow: String?

    enum CodingKeys: String, CodingKey {
        case id, name, source, isEnabled, order, displayStyle
        case stremioAddonId, stremioAddonName, stremioCatalogId, stremioCatalogType, stremioMediaType
        case traktListId, traktListUser, traktListSlug, traktListMediaType, traktListSortBy, traktListSortHow
    }

    enum CatalogSource: String, Codable, Equatable {
        case tmdb = "TMDB"
        case anilist = "AniList"
        case local = "Local"
        case stremio = "Stremio"
        case trakt = "Trakt"
    }

    enum CatalogDisplayStyle: String, Codable, Equatable {
        case standard
        case network
        case genre
        case company
        case ranked
        case featured
        case continueWatching
    }

    init(
        id: String,
        name: String,
        source: CatalogSource,
        isEnabled: Bool,
        order: Int,
        displayStyle: CatalogDisplayStyle = .standard,
        stremioAddonId: UUID? = nil,
        stremioAddonName: String? = nil,
        stremioCatalogId: String? = nil,
        stremioCatalogType: String? = nil,
        stremioMediaType: String? = nil,
        traktListId: Int? = nil,
        traktListUser: String? = nil,
        traktListSlug: String? = nil,
        traktListMediaType: String? = nil,
        traktListSortBy: String? = nil,
        traktListSortHow: String? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.isEnabled = isEnabled
        self.order = order
        self.displayStyle = displayStyle
        self.stremioAddonId = stremioAddonId
        self.stremioAddonName = stremioAddonName
        self.stremioCatalogId = stremioCatalogId
        self.stremioCatalogType = stremioCatalogType
        self.stremioMediaType = stremioMediaType
        self.traktListId = traktListId
        self.traktListUser = traktListUser
        self.traktListSlug = traktListSlug
        self.traktListMediaType = traktListMediaType
        self.traktListSortBy = traktListSortBy
        self.traktListSortHow = traktListSortHow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(CatalogSource.self, forKey: .source)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        order = try container.decode(Int.self, forKey: .order)
        displayStyle = try container.decodeIfPresent(CatalogDisplayStyle.self, forKey: .displayStyle) ?? .standard
        stremioAddonId = try container.decodeIfPresent(UUID.self, forKey: .stremioAddonId)
        stremioAddonName = try container.decodeIfPresent(String.self, forKey: .stremioAddonName)
        stremioCatalogId = try container.decodeIfPresent(String.self, forKey: .stremioCatalogId)
        stremioCatalogType = try container.decodeIfPresent(String.self, forKey: .stremioCatalogType)
        stremioMediaType = try container.decodeIfPresent(String.self, forKey: .stremioMediaType)
        traktListId = try container.decodeIfPresent(Int.self, forKey: .traktListId)
        traktListUser = try container.decodeIfPresent(String.self, forKey: .traktListUser)
        traktListSlug = try container.decodeIfPresent(String.self, forKey: .traktListSlug)
        traktListMediaType = try container.decodeIfPresent(String.self, forKey: .traktListMediaType)
        traktListSortBy = try container.decodeIfPresent(String.self, forKey: .traktListSortBy)
        traktListSortHow = try container.decodeIfPresent(String.self, forKey: .traktListSortHow)
    }

    static func stremioCatalogId(addon: StremioAddon, stremioCatalog: StremioCatalog) -> String {
        "stremio:\(addon.id.uuidString):\(stremioCatalog.type):\(stremioCatalog.id)"
    }

    static func traktPublicListCatalogId(listId: Int?, listUser: String?, listSlug: String?, mediaType: String) -> String {
        let normalizedMediaType = normalizedTraktListMediaType(mediaType)
        if let listId, listId > 0 {
            return "trakt:list:\(normalizedMediaType):\(listId)"
        }

        let user = listUser?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let slug = listSlug?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return "trakt:list:\(normalizedMediaType):\(user):\(slug)"
    }

    static func normalizedTraktListMediaType(_ mediaType: String?) -> String {
        let value = mediaType?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value == "movies" || value == "movie" ? "movies" : "shows"
    }

    var traktListEndpointPath: String? {
        if let traktListId, traktListId > 0 {
            return "lists/\(traktListId)"
        }

        guard let user = traktListUser?.trimmingCharacters(in: .whitespacesAndNewlines),
              let slug = traktListSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
              !user.isEmpty,
              !slug.isEmpty,
              let encodedUser = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        return "users/\(encodedUser)/lists/\(encodedSlug)"
    }

    var traktListDisplayIdentifier: String? {
        if let traktListId, traktListId > 0 {
            return "\(traktListId)"
        }
        guard let user = traktListUser?.trimmingCharacters(in: .whitespacesAndNewlines),
              let slug = traktListSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
              !user.isEmpty,
              !slug.isEmpty else {
            return nil
        }
        return "\(user)/\(slug)"
    }

    var requiresTraktConnection: Bool {
        source == .trakt
    }

    func updatingUserState(isEnabled: Bool, order: Int) -> Catalog {
        Catalog(
            id: id,
            name: name,
            source: source,
            isEnabled: isEnabled,
            order: order,
            displayStyle: displayStyle,
            stremioAddonId: stremioAddonId,
            stremioAddonName: stremioAddonName,
            stremioCatalogId: stremioCatalogId,
            stremioCatalogType: stremioCatalogType,
            stremioMediaType: stremioMediaType,
            traktListId: traktListId,
            traktListUser: traktListUser,
            traktListSlug: traktListSlug,
            traktListMediaType: traktListMediaType,
            traktListSortBy: traktListSortBy,
            traktListSortHow: traktListSortHow
        )
    }
}
