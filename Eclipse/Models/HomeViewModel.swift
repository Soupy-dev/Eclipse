//
//  HomeViewModel.swift
//  Eclipse
//
//  Created by Soupy-dev
//

import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

final class HomeViewModel: ObservableObject {
    @Published var catalogResults: [String: [TMDBSearchResult]] = [:]
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var heroContent: TMDBSearchResult?
    @Published var ambientColor: Color = Color.black
    @Published var hasLoadedContent = false
    @Published var hasCompletedInitialLoad = false
    @Published var hasRenderableStartupContent = false
    @Published var widgetData: [String: [TMDBSearchResult]] = [:]
    @Published var becauseYouWatchedTitle: String = ""
    private var heroCarouselItems: [TMDBSearchResult] = []
    private var heroCarouselIndex = 0
    private var heroLaunchSelectionCatalogId: String?
    private static let maxHeroCarouselItems = 12

    var heroCarouselCount: Int { heroCarouselItems.count }

    var heroCarouselCurrentIndex: Int { min(heroCarouselIndex, max(0, heroCarouselItems.count - 1)) }

    func upcomingHeroCarouselItems(limit: Int) -> [TMDBSearchResult] {
        guard limit > 0, heroCarouselItems.count > 1 else { return [] }
        let itemCount = min(limit, heroCarouselItems.count - 1)
        return (1...itemCount).map { offset in
            heroCarouselItems[(heroCarouselCurrentIndex + offset) % heroCarouselItems.count]
        }
    }
    private var activeLoadTask: Task<Void, Never>?

    private var loadGeneration = UUID()

    init() {

    }

    func loadContent(
        tmdbService: TMDBService,
        catalogManager: CatalogManager,
        contentFilter: TMDBContentFilter,
        showLoading: Bool = true
    ) {

        guard !hasLoadedContent else {
            return
        }
        guard activeLoadTask == nil else {
            return
        }

        if showLoading {
            isLoading = true
        }
        errorMessage = nil
        hasCompletedInitialLoad = false
        if catalogResults.values.allSatisfy(\.isEmpty) && widgetData.values.allSatisfy(\.isEmpty) {
            hasRenderableStartupContent = false
        }

        activeLoadTask = Task {
            let (enabledCatalogSnapshot, performanceModeEnabled, generation) = await MainActor.run {

                _ = StremioAddonManager.shared
                return (catalogManager.getEnabledCatalogs(), catalogManager.performanceModeEnabled, self.loadGeneration)
            }

            // An empty catalog list is a valid user configuration, not a network
            // failure. Finish the load without showing the generic Wi-Fi error.
            if enabledCatalogSnapshot.isEmpty {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.catalogResults = [:]
                    self.widgetData = [:]
                    self.heroContent = nil
                    self.heroCarouselItems = []
                    self.heroCarouselIndex = 0
                    self.heroLaunchSelectionCatalogId = nil
                    self.isLoading = false
                    self.hasLoadedContent = true
                    self.hasCompletedInitialLoad = true
                    self.hasRenderableStartupContent = false
                    self.errorMessage = nil
                    self.activeLoadTask = nil
                }
                return
            }

            let enabledCatalogIds = Set(enabledCatalogSnapshot.map(\.id))
            let needsTopRatedTVShows = enabledCatalogIds.contains("topRatedTVShows") || enabledCatalogIds.contains("bestTVShows")
            let needsTopRatedMovies = enabledCatalogIds.contains("topRatedMovies") || enabledCatalogIds.contains("bestMovies")
            let needsTopRatedAnime = enabledCatalogIds.contains("topRatedAnime") || enabledCatalogIds.contains("bestAnime")

            async let trending: [TMDBSearchResult] = self.loadHomeCatalogIfNeeded("trending", shouldLoad: enabledCatalogIds.contains("trending")) {
                try await tmdbService.getTrending()
            }
            async let popularM: [TMDBMovie] = self.loadHomeCatalogIfNeeded("popularMovies", shouldLoad: enabledCatalogIds.contains("popularMovies")) {
                try await tmdbService.getPopularMovies()
            }
            async let nowPlayingM: [TMDBMovie] = self.loadHomeCatalogIfNeeded("nowPlayingMovies", shouldLoad: enabledCatalogIds.contains("nowPlayingMovies")) {
                try await tmdbService.getNowPlayingMovies()
            }
            async let upcomingM: [TMDBMovie] = self.loadHomeCatalogIfNeeded("upcomingMovies", shouldLoad: enabledCatalogIds.contains("upcomingMovies")) {
                try await tmdbService.getUpcomingMovies()
            }
            async let popularTV: [TMDBTVShow] = self.loadHomeCatalogIfNeeded("popularTVShows", shouldLoad: enabledCatalogIds.contains("popularTVShows")) {
                try await tmdbService.getPopularTVShows()
            }
            async let onTheAirTV: [TMDBTVShow] = self.loadHomeCatalogIfNeeded("onTheAirTV", shouldLoad: enabledCatalogIds.contains("onTheAirTV")) {
                try await tmdbService.getOnTheAirTVShows()
            }
            async let airingTodayTV: [TMDBTVShow] = self.loadHomeCatalogIfNeeded("airingTodayTV", shouldLoad: enabledCatalogIds.contains("airingTodayTV")) {
                try await tmdbService.getAiringTodayTVShows()
            }
            async let topRatedTV: [TMDBTVShow] = self.loadHomeCatalogIfNeeded("topRatedTVShows", shouldLoad: needsTopRatedTVShows) {
                try await tmdbService.getTopRatedTVShows()
            }
            async let topRatedM: [TMDBMovie] = self.loadHomeCatalogIfNeeded("topRatedMovies", shouldLoad: needsTopRatedMovies) {
                try await tmdbService.getTopRatedMovies()
            }
            async let upcomingTV: [TMDBTVShow] = self.loadHomeCatalogIfNeeded("upcomingTV", shouldLoad: enabledCatalogIds.contains("upcomingTV")) {
                try await tmdbService.getUpcomingTVShows()
            }

            let tmdbResults = await (
                trending, popularM, nowPlayingM, upcomingM, popularTV, onTheAirTV,
                airingTodayTV, topRatedTV, topRatedM, upcomingTV
            )
            guard !Task.isCancelled else { return }

            let rawTMDBLoadedCatalogs: [String: [TMDBSearchResult]] = [
                "trending": tmdbResults.0,
                "popularMovies": tmdbResults.1.map { self.movieSearchResult($0) },
                "nowPlayingMovies": tmdbResults.2.map { self.movieSearchResult($0) },
                "upcomingMovies": tmdbResults.3.map { self.movieSearchResult($0) },
                "popularTVShows": tmdbResults.4.map { self.tvSearchResult($0) },
                "onTheAirTV": tmdbResults.5.map { self.tvSearchResult($0) },
                "airingTodayTV": tmdbResults.6.map { self.tvSearchResult($0) },
                "topRatedTVShows": tmdbResults.7.map { self.tvSearchResult($0) },
                "topRatedMovies": tmdbResults.8.map { self.movieSearchResult($0) },
                "upcomingTV": tmdbResults.9.map { self.tvSearchResult($0) }
            ]

            await contentFilter.prepareMaturityRatings(
                for: Array(rawTMDBLoadedCatalogs.values.joined())
            )
            guard !Task.isCancelled else { return }
            let kidsLoadedCatalogs = await self.loadKidsCatalogs(
                tmdbService: tmdbService,
                contentFilter: contentFilter,
                catalogs: enabledCatalogSnapshot
            )
            guard !Task.isCancelled else { return }
            let tmdbLoadedCatalogs = rawTMDBLoadedCatalogs
                .mapValues { contentFilter.filterSearchResults($0) }
                .merging(kidsLoadedCatalogs) { _, kids in kids }
            let tmdbLoadedCatalogCount = tmdbLoadedCatalogs.values.filter { !$0.isEmpty }.count

            if tmdbLoadedCatalogCount > 0 {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.catalogResults = tmdbLoadedCatalogs
                    self.applyHeroBannerSelection()
                    self.errorMessage = nil
                    self.hasRenderableStartupContent = true
                }
            }

            let requiredAnimeCatalogs = self.requiredAnimeCatalogKinds(
                enabledCatalogIds: enabledCatalogIds,
                needsTopRatedAnime: needsTopRatedAnime
            )
            let animeCatalogs: [AniListService.AniListCatalogKind: [TMDBSearchResult]]
            if performanceModeEnabled {
                animeCatalogs = await self.loadFastAnimeCatalogs(
                    tmdbService: tmdbService,
                    contentFilter: contentFilter,
                    requiredKinds: requiredAnimeCatalogs
                )
            } else {
                animeCatalogs = await self.loadAnimeCatalogs(
                    tmdbService: tmdbService,
                    contentFilter: contentFilter,
                    requiredKinds: requiredAnimeCatalogs
                )
            }
            guard !Task.isCancelled else { return }
            let trendingAnime = animeCatalogs[.trending] ?? []
            let popularAnime = animeCatalogs[.popular] ?? []
            let topRatedAnime = animeCatalogs[.topRated] ?? []
            let airingAnime = animeCatalogs[.airing] ?? []
            let upcomingAnime = animeCatalogs[.upcoming] ?? []

            let animeLoadedCatalogs: [String: [TMDBSearchResult]] = [
                "trendingAnime": trendingAnime,
                "popularAnime": popularAnime,
                "topRatedAnime": topRatedAnime,
                "airingAnime": airingAnime,
                "upcomingAnime": upcomingAnime
            ]
            let loadedCatalogs = tmdbLoadedCatalogs.merging(animeLoadedCatalogs) { _, anime in anime }
            let loadedCatalogCount = loadedCatalogs.values.filter { !$0.isEmpty }.count

            await MainActor.run {
                guard self.loadGeneration == generation else { return }
                self.catalogResults = loadedCatalogs
                self.applyHeroBannerSelection()
                self.errorMessage = nil
                if loadedCatalogCount > 0 {
                    self.hasRenderableStartupContent = true
                }
            }

            async let stremioCatalogs = self.loadStremioCatalogs(
                enabledCatalogs: enabledCatalogSnapshot,
                tmdbService: tmdbService,
                contentFilter: contentFilter
            )
            async let traktCatalogs = self.loadTraktCatalogs(
                enabledCatalogs: enabledCatalogSnapshot,
                tmdbService: tmdbService,
                contentFilter: contentFilter
            )
            async let widgetsLoaded: Void = self.loadWidgetData(
                tmdbService: tmdbService,
                enabledCatalogs: enabledCatalogSnapshot,
                contentFilter: contentFilter,
                generation: generation
            )
            async let recommendationsLoaded: Void = self.loadRecommendationCatalogs(
                enabledCatalogs: enabledCatalogSnapshot,
                tmdbService: tmdbService,
                contentFilter: contentFilter,
                hasLoadedCatalogs: loadedCatalogCount > 0,
                generation: generation
            )

            let loadedStremioCatalogs = await stremioCatalogs
            let loadedTraktCatalogs = await traktCatalogs
            _ = await widgetsLoaded
            _ = await recommendationsLoaded
            guard !Task.isCancelled else { return }

            await MainActor.run {

                guard self.loadGeneration == generation else { return }
                let currentlyEnabledCatalogIds = Set(catalogManager.getEnabledCatalogs().map(\.id))
                let enabledStremioCatalogs = loadedStremioCatalogs.filter {
                    currentlyEnabledCatalogIds.contains($0.key)
                }
                if !enabledStremioCatalogs.isEmpty {
                    self.catalogResults.merge(enabledStremioCatalogs) { _, stremio in stremio }
                }
                if !loadedTraktCatalogs.isEmpty {
                    self.catalogResults.merge(loadedTraktCatalogs) { _, trakt in trakt }
                }

                let finalLoadedCount = self.catalogResults.values.filter { !$0.isEmpty }.count
                    + self.widgetData.values.filter { !$0.isEmpty }.count
                self.applyHeroBannerSelection()
                self.isLoading = false
                self.hasLoadedContent = finalLoadedCount > 0
                self.hasCompletedInitialLoad = true
                self.hasRenderableStartupContent = finalLoadedCount > 0
                self.errorMessage = finalLoadedCount == 0
                    ? "Unable to load home catalogs. Check your internet connection and API configuration, then try again."
                    : nil
                self.activeLoadTask = nil
            }
        }
    }

    private func loadRecommendationCatalogs(
        enabledCatalogs: [Catalog],
        tmdbService: TMDBService,
        contentFilter: TMDBContentFilter,
        hasLoadedCatalogs: Bool,
        generation: UUID
    ) async {
        guard hasLoadedCatalogs else { return }

        let owner = await MainActor.run { ProfileManager.shared.activeProfileID }

        if enabledCatalogs.contains(where: { $0.id == "forYou" }) {
            let currentResults = await MainActor.run { self.catalogResults }
            let rawForYou = await RecommendationEngine.shared.generateRecommendations(
                catalogResults: currentResults,
                tmdbService: tmdbService
            )
            await contentFilter.prepareMaturityRatings(for: rawForYou)
            let forYou = contentFilter.filterSearchResults(rawForYou)
            if !forYou.isEmpty {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    guard ProfileManager.shared.isStillActive(owner) else { return }
                    self.catalogResults["forYou"] = forYou
                    self.applyHeroBannerSelection()
                }
            }
        }

        if enabledCatalogs.contains(where: { $0.id == "becauseYouWatched" }) {
            let (bywTitle, rawBYWResults) = await RecommendationEngine.shared.generateBecauseYouWatched(
                tmdbService: tmdbService
            )
            await contentFilter.prepareMaturityRatings(for: rawBYWResults)
            let bywResults = contentFilter.filterSearchResults(rawBYWResults)
            if !bywResults.isEmpty {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    guard ProfileManager.shared.isStillActive(owner) else { return }
                    self.catalogResults["becauseYouWatched"] = bywResults
                    self.becauseYouWatchedTitle = bywTitle
                    self.applyHeroBannerSelection()
                }
            }
        }
    }

    private func loadKidsCatalogs(
        tmdbService: TMDBService,
        contentFilter: TMDBContentFilter,
        catalogs: [Catalog]
    ) async -> [String: [TMDBSearchResult]] {
        let kinds = catalogs.compactMap { KidsHomeCatalog.from(catalogID: $0.id) }
        guard !kinds.isEmpty else { return [:] }

        var raw: [String: [TMDBSearchResult]] = [:]
        await withTaskGroup(of: (String, [TMDBSearchResult]).self) { group in
            for kind in kinds {
                group.addTask {
                    let items = (try? await tmdbService.discoverForKids(query: kind.query)) ?? []
                    return (kind.catalogID, items)
                }
            }
            for await (id, items) in group {
                raw[id] = items
            }
        }

        await contentFilter.prepareMaturityRatings(for: Array(raw.values.joined()))
        return raw.mapValues { contentFilter.filterSearchResults($0) }
    }

    private func loadHomeCatalog<T>(_ id: String, fetch: () async throws -> [T]) async -> [T] {
        do {
            let items = try await fetch()
            Logger.shared.log("HomeViewModel: catalog \(id) loaded count=\(items.count)", type: "TMDB")
            return items
        } catch {
            Logger.shared.log("HomeViewModel: catalog \(id) failed: \(error.localizedDescription)", type: "Error")
            return []
        }
    }

    private func loadHomeCatalogIfNeeded<T>(
        _ id: String,
        shouldLoad: Bool,
        fetch: () async throws -> [T]
    ) async -> [T] {
        guard shouldLoad else { return [] }
        return await loadHomeCatalog(id, fetch: fetch)
    }

    private func requiredAnimeCatalogKinds(
        enabledCatalogIds: Set<String>,
        needsTopRatedAnime: Bool
    ) -> Set<AniListService.AniListCatalogKind> {
        var kinds = Set<AniListService.AniListCatalogKind>()
        if enabledCatalogIds.contains("trendingAnime") { kinds.insert(.trending) }
        if enabledCatalogIds.contains("popularAnime") { kinds.insert(.popular) }
        if needsTopRatedAnime { kinds.insert(.topRated) }
        if enabledCatalogIds.contains("airingAnime") { kinds.insert(.airing) }
        if enabledCatalogIds.contains("upcomingAnime") { kinds.insert(.upcoming) }
        return kinds
    }

    private func loadAnimeCatalogs(
        tmdbService: TMDBService,
        contentFilter: TMDBContentFilter,
        requiredKinds: Set<AniListService.AniListCatalogKind>
    ) async -> [AniListService.AniListCatalogKind: [TMDBSearchResult]] {
        guard !requiredKinds.isEmpty else { return [:] }

        do {
            let catalogs = try await AniListService.shared.fetchAnimeCatalogs(
                kinds: requiredKinds,
                tmdbService: tmdbService
            )

            await contentFilter.prepareMaturityRatings(
                for: Array(catalogs.values.joined())
            )
            var filtered: [AniListService.AniListCatalogKind: [TMDBSearchResult]] = [:]
            for (kind, items) in catalogs {
                let allowed = contentFilter.filterFastAnimeSearchResults(items)
                if !allowed.isEmpty {
                    filtered[kind] = allowed
                }
            }
            let loadedSummary = filtered
                .map { "\(String(describing: $0.key))=\($0.value.count)" }
                .sorted()
                .joined(separator: ",")
            Logger.shared.log("HomeViewModel: enabled anime catalogs loaded \(loadedSummary)", type: "AniList")
            return filtered
        } catch {
            Logger.shared.log("HomeViewModel: anime catalogs failed: \(error.localizedDescription)", type: "Error")
            return [:]
        }
    }

    private func loadFastAnimeCatalogs(
        tmdbService: TMDBService,
        contentFilter: TMDBContentFilter,
        requiredKinds: Set<AniListService.AniListCatalogKind>
    ) async -> [AniListService.AniListCatalogKind: [TMDBSearchResult]] {
        guard !requiredKinds.isEmpty else { return [:] }

        var loaded: [AniListService.AniListCatalogKind: [TMDBSearchResult]] = [:]
        for kind in requiredKinds {
            guard let fastKind = fastAnimeCatalogKind(for: kind) else { continue }
            let items: [TMDBSearchResult] = await loadHomeCatalog("fastAnime:\(kind)") {
                try await tmdbService.getFastAnimeCatalog(kind: fastKind, limit: 20)
            }
            await contentFilter.prepareMaturityRatings(for: items)
            let filtered = contentFilter.filterFastAnimeSearchResults(items)
            if !filtered.isEmpty {
                loaded[kind] = filtered
            }
        }

        let loadedSummary = loaded
            .map { "\(String(describing: $0.key))=\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        Logger.shared.log("HomeViewModel: performance anime catalogs loaded \(loadedSummary.isEmpty ? "none" : loadedSummary)", type: "TMDB")
        return loaded
    }

    private func fastAnimeCatalogKind(for kind: AniListService.AniListCatalogKind) -> TMDBService.FastAnimeCatalogKind? {
        switch kind {
        case .trending:
            return .trending
        case .popular:
            return .popular
        case .topRated:
            return .topRated
        case .airing:
            return .airing
        case .upcoming:
            return .upcoming
        }
    }

    private func loadStremioCatalogs(
        enabledCatalogs: [Catalog],
        tmdbService: TMDBService,
        contentFilter: TMDBContentFilter
    ) async -> [String: [TMDBSearchResult]] {
        let catalogs = enabledCatalogs.filter { $0.source == .stremio }
        guard !catalogs.isEmpty else { return [:] }

        var loaded: [String: [TMDBSearchResult]] = [:]
        for catalog in catalogs {
            if Task.isCancelled { break }
            let items = await StremioAddonManager.shared.fetchCatalogItems(
                for: catalog,
                tmdbService: tmdbService,
                limit: 15
            )
            await contentFilter.prepareMaturityRatings(for: items)
            let filtered = contentFilter.filterSearchResults(items)
            if !filtered.isEmpty {
                loaded[catalog.id] = filtered
            }
        }

        let summary = loaded
            .map { "\($0.key)=\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        Logger.shared.log("HomeViewModel: Stremio catalogs loaded \(summary.isEmpty ? "none" : summary)", type: "Stremio")
        return loaded
    }

    private func loadTraktCatalogs(
        enabledCatalogs: [Catalog],
        tmdbService: TMDBService,
        contentFilter: TMDBContentFilter
    ) async -> [String: [TMDBSearchResult]] {
        let catalogs = enabledCatalogs.filter { $0.source == .trakt }
        guard !catalogs.isEmpty else { return [:] }

        var loaded: [String: [TMDBSearchResult]] = [:]
        for catalog in catalogs {
            if Task.isCancelled { break }
            let items = await TrackerManager.shared.fetchTraktPublicListCatalogItems(
                for: catalog,
                tmdbService: tmdbService,
                limit: 15
            )
            await contentFilter.prepareMaturityRatings(for: items)
            let filtered = contentFilter.filterSearchResults(items)
            if !filtered.isEmpty {
                loaded[catalog.id] = filtered
            }
        }

        let summary = loaded
            .map { "\($0.key)=\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        Logger.shared.log("HomeViewModel: Trakt public catalogs loaded \(summary.isEmpty ? "none" : summary)", type: "Tracker")
        return loaded
    }

    private func movieSearchResult(_ movie: TMDBMovie) -> TMDBSearchResult {
        TMDBSearchResult(
            id: movie.id,
            mediaType: "movie",
            title: movie.title,
            name: nil,
            overview: movie.overview,
            posterPath: movie.posterPath,
            backdropPath: movie.backdropPath,
            releaseDate: movie.releaseDate,
            firstAirDate: nil,
            voteAverage: movie.voteAverage,
            popularity: movie.popularity,
            adult: movie.adult,
            genreIds: movie.genreIds
        )
    }

    private func tvSearchResult(_ show: TMDBTVShow) -> TMDBSearchResult {
        TMDBSearchResult(
            id: show.id,
            mediaType: "tv",
            title: nil,
            name: show.name,
            overview: show.overview,
            posterPath: show.posterPath,
            backdropPath: show.backdropPath,
            releaseDate: nil,
            firstAirDate: show.firstAirDate,
            voteAverage: show.voteAverage,
            popularity: show.popularity,
            adult: show.adult,
            genreIds: show.genreIds
        )
    }

    func loadWidgetData(
        tmdbService: TMDBService,
        enabledCatalogs: [Catalog],
        contentFilter: TMDBContentFilter,
        generation: UUID
    ) async {
            guard !Task.isCancelled else { return }

            let rankedMappings: [(catalogId: String, sourceKey: String)] = [
                ("bestTVShows", "topRatedTVShows"),
                ("bestMovies", "topRatedMovies"),
                ("bestAnime", "topRatedAnime")
            ]
            let currentResults = await MainActor.run { self.catalogResults }
            for mapping in rankedMappings {
                if enabledCatalogs.contains(where: { $0.id == mapping.catalogId }),
                   let items = currentResults[mapping.sourceKey], !items.isEmpty {
                    await MainActor.run {
                        guard self.loadGeneration == generation else { return }
                        self.widgetData[mapping.catalogId] = items
                        self.applyHeroBannerSelection()
                    }
                }
            }

            if enabledCatalogs.contains(where: { $0.id == "networks" }) {
                await withTaskGroup(of: (Int, [TMDBSearchResult]).self) { group in
                    for network in WidgetNetwork.active {
                        group.addTask {
                            let results = await contentFilter.filterSearchResultsResolvingRatings((try? await tmdbService.discoverByNetwork(networkId: network.id)) ?? [])
                            return (network.id, results)
                        }
                    }
                    for await (networkId, results) in group {
                        guard !Task.isCancelled else { return }
                        if !results.isEmpty {
                            await MainActor.run {
                                guard self.loadGeneration == generation else { return }
                                self.widgetData["network_\(networkId)"] = results
                                self.applyHeroBannerSelection()
                            }
                        }
                    }
                }
            }

            if enabledCatalogs.contains(where: { $0.id == "genres" }) {
                await withTaskGroup(of: (Int, [TMDBSearchResult]).self) { group in
                    for genre in WidgetGenre.active {
                        group.addTask {
                            let results = await contentFilter.filterSearchResultsResolvingRatings((try? await tmdbService.discoverByGenre(genreId: genre.id)) ?? [])
                            return (genre.id, results)
                        }
                    }
                    for await (genreId, results) in group {
                        guard !Task.isCancelled else { return }
                        if !results.isEmpty {
                            await MainActor.run {
                                guard self.loadGeneration == generation else { return }
                                self.widgetData["genre_\(genreId)"] = results
                                self.applyHeroBannerSelection()
                            }
                        }
                    }
                }
            }

            if enabledCatalogs.contains(where: { $0.id == "companies" }) {
                await withTaskGroup(of: (Int, [TMDBSearchResult]).self) { group in
                    for company in WidgetCompany.active {
                        group.addTask {
                            let results = await contentFilter.filterSearchResultsResolvingRatings((try? await tmdbService.discoverByCompany(companyId: company.id)) ?? [])
                            return (company.id, results)
                        }
                    }
                    for await (companyId, results) in group {
                        guard !Task.isCancelled else { return }
                        if !results.isEmpty {
                            await MainActor.run {
                                guard self.loadGeneration == generation else { return }
                                self.widgetData["company_\(companyId)"] = results
                                self.applyHeroBannerSelection()
                            }
                        }
                    }
                }
            }

            if enabledCatalogs.contains(where: { $0.id == "featured" }) {
                guard !Task.isCancelled else { return }
                let randomGenre = WidgetGenre.active.randomElement() ?? WidgetGenre.active[0]
                let results = await contentFilter.filterSearchResultsResolvingRatings((try? await tmdbService.discoverByGenre(genreId: randomGenre.id, mediaType: "tv")) ?? [])
                if !results.isEmpty {
                    await MainActor.run {
                        guard self.loadGeneration == generation else { return }
                        self.widgetData["featured"] = results
                        self.widgetData["featured_genreName"] = []
                        self.applyHeroBannerSelection()
                    }

                    await MainActor.run {
                        guard self.loadGeneration == generation else { return }
                        self.featuredGenreName = randomGenre.name
                    }
            }
        }
    }

    @Published var featuredGenreName: String = ""

    func refreshHeroContentForSettingsChange() {
        applyHeroBannerSelection()
    }

    func advanceHeroCarouselIfNeeded(by offset: Int = 1) {
        let behaviorRaw = ProfileSettingsStore.active.string(forKey: "heroBannerBehavior") ?? HeroBannerBehavior.defaultValue.rawValue
        guard HeroBannerBehavior(rawValue: behaviorRaw) == .carousel else { return }
        guard heroCarouselItems.count > 1 else { return }
        let count = heroCarouselItems.count
        let normalizedOffset = ((offset % count) + count) % count
        guard normalizedOffset != 0 else { return }
        heroCarouselIndex = (heroCarouselIndex + normalizedOffset) % count
        heroContent = heroCarouselItems[heroCarouselIndex]
    }

    private func applyHeroBannerSelection() {
        let catalogId = ProfileSettingsStore.active.string(forKey: "heroBannerCatalogId") ?? "trending"
        let behaviorRaw = ProfileSettingsStore.active.string(forKey: "heroBannerBehavior") ?? HeroBannerBehavior.defaultValue.rawValue
        let behavior = HeroBannerBehavior(rawValue: behaviorRaw) ?? .defaultValue
        let rawCandidates = heroCandidates(for: catalogId)
#if os(iOS)
        let iPadBackdropCandidates = rawCandidates.filter { $0.fullBackdropURL != nil }
        let candidates = UIDevice.current.userInterfaceIdiom == .pad && !iPadBackdropCandidates.isEmpty
            ? iPadBackdropCandidates
            : rawCandidates
#elseif os(tvOS)
        let tvBackdropCandidates = rawCandidates.filter { $0.fullBackdropURL != nil }
        let candidates = tvBackdropCandidates.isEmpty ? rawCandidates : tvBackdropCandidates
#else
        let candidates = rawCandidates
#endif

        guard !candidates.isEmpty else { return }

        switch behavior {
        case .static:
            heroCarouselItems = candidates
            heroLaunchSelectionCatalogId = nil
            heroCarouselIndex = 0
            heroContent = candidates.first
        case .carousel:

            heroCarouselItems = Array(candidates.prefix(Self.maxHeroCarouselItems))
            heroLaunchSelectionCatalogId = nil
            if let current = heroContent,
               let currentIndex = heroCarouselItems.firstIndex(where: { $0.stableIdentity == current.stableIdentity }) {
                heroCarouselIndex = currentIndex
            } else {
                heroCarouselIndex = 0
                heroContent = heroCarouselItems.first
            }
        case .launch:
            heroCarouselItems = candidates
            if heroLaunchSelectionCatalogId == catalogId,
               let current = heroContent,
               let currentIndex = candidates.firstIndex(where: { $0.stableIdentity == current.stableIdentity }) {
                heroCarouselIndex = currentIndex
                return
            }
            let selectedIndex = candidates.indices.randomElement() ?? candidates.startIndex
            heroLaunchSelectionCatalogId = catalogId
            heroCarouselIndex = selectedIndex
            heroContent = candidates[selectedIndex]
        }
    }

    private func heroCandidates(for catalogId: String) -> [TMDBSearchResult] {
        if let items = catalogResults[catalogId], !items.isEmpty {
            return items
        }

        if let items = widgetData[catalogId], !items.isEmpty {
            return items
        }

        if catalogId == "networks" {
            let items = WidgetNetwork.active.flatMap { widgetData["network_\($0.id)"] ?? [] }
            if !items.isEmpty { return items }
        }

        if catalogId == "genres" {
            let items = WidgetGenre.active.flatMap { widgetData["genre_\($0.id)"] ?? [] }
            if !items.isEmpty { return items }
        }

        if catalogId == "companies" {
            let items = WidgetCompany.active.flatMap { widgetData["company_\($0.id)"] ?? [] }
            if !items.isEmpty { return items }
        }

        if let trending = catalogResults["trending"], !trending.isEmpty {
            return trending
        }

        for kind in KidsHomeCatalog.allCases {
            if let items = catalogResults[kind.catalogID], !items.isEmpty {
                return items
            }
        }
        return catalogResults
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .first?
            .value ?? []
    }

    func resetContent(
        preserveVisibleContent: Bool = false,
        invalidateRecommendations: Bool = true
    ) {
        activeLoadTask?.cancel()
        activeLoadTask = nil

        loadGeneration = UUID()
        if !preserveVisibleContent {
            catalogResults = [:]
            widgetData = [:]
            isLoading = true
            heroContent = nil
            heroLaunchSelectionCatalogId = nil
            featuredGenreName = ""
            becauseYouWatchedTitle = ""
            hasRenderableStartupContent = false
        }
        errorMessage = nil
        hasLoadedContent = false
        hasCompletedInitialLoad = false
        if invalidateRecommendations {
            RecommendationEngine.shared.invalidateCache()
        }
    }
}
