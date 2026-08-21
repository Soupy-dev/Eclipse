//
//  TMDBContentFilter.swift
//  Sora
//
//  Created by Francesco on 11/09/25.
//

import Combine
import Foundation

struct KidsPolicyDetails: Codable, Hashable {
    let isAdult: Bool
    let genreIds: [Int]
    let overview: String?
}

class TMDBContentFilter: ObservableObject {
    static let shared = TMDBContentFilter()

    @Published private(set) var maturityRatingRevision = 0

    private var cancellables = Set<AnyCancellable>()

    @Published var filterHorror: Bool {
        didSet {
            ProfileSettingsStore.active.set(filterHorror, forKey: "filterHorror")
        }
    }

    @Published private(set) var isKidsProfileActive: Bool = ProfileManager.shared.isKidsModeActive

    private let horrorGenreIds = [27]

    private static let kidsBlockedGenreIds: Set<Int> = [27, 53, 80, 10752, 9648, 10768]

    private let explicitCatalogTitleDenylist: Set<String> = [
        "overflow"
    ]

    private static let kidsMetadataDenylist: Set<String> = [
        "blood",
        "brutal",
        "cannibal",
        "carnage",
        "decapitation",
        "demonic",
        "disturbing",
        "drug abuse",
        "drug addiction",
        "gore",
        "graphic violence",
        "grisly",
        "gruesome",
        "hard drugs",
        "homicide",
        "horror",
        "massacre",
        "mutilation",
        "prostitution",
        "psychological horror",
        "rape",
        "sadistic",
        "satanic",
        "self harm",
        "serial killer",
        "sexual assault",
        "slasher",
        "snuff",
        "suicide",
        "torture",
        "violent"
    ]
    private static let adultAnimeMetadataDenylist: Set<String> = [
        "adult animation",
        "adult anime",
        "adult cartoon",
        "adult film",
        "adult video",
        "ecchi",
        "ero anime",
        "eroge",
        "erotica",
        "erotic",
        "erotic animation",
        "erotic anime",
        "explicit sex",
        "explicit sexual",
        "female nudity",
        "hentai",
        "mature anime",
        "mild nudity",
        "nudity",
        "ova hentai",
        "pornographic",
        "pornography",
        "r 18",
        "r18",
        "sex comedy",
        "sexual content",
        "sexually explicit",
        "softcore",
        "uncensored"
    ]

    private init() {
        self.filterHorror = ProfileSettingsStore.active.bool(forKey: "filterHorror")
        TMDBMaturityRatingStore.shared.$revision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] revision in
                guard let self, self.isKidsProfileActive else { return }
                self.maturityRatingRevision = revision
            }
            .store(in: &cancellables)
    }

    func activeProfileDidChange() {

        let storedFilterHorror = ProfileSettingsStore.active.bool(forKey: "filterHorror")
        if storedFilterHorror != filterHorror {
            if Thread.isMainThread {
                filterHorror = storedFilterHorror
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.filterHorror = storedFilterHorror
                }
            }
        }
        let isKids = ProfileManager.shared.isKidsModeActive
        guard isKids != isKidsProfileActive else { return }
        if Thread.isMainThread {
            isKidsProfileActive = isKids
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isKidsProfileActive = isKids
            }
        }
    }

    private var kidsModeEnabled: Bool { ProfileManager.shared.isKidsModeActive }

    func prepareMaturityRatings(for results: [TMDBSearchResult]) async {
        guard kidsModeEnabled else { return }
        await TMDBMaturityRatingStore.shared.resolve(
            results.map { (isMovie: $0.isMovie, id: $0.id) }
        )
    }

    func filterSearchResultsResolvingRatings(_ results: [TMDBSearchResult]) async -> [TMDBSearchResult] {
        await prepareMaturityRatings(for: results)
        return filterSearchResults(results)
    }

    func filterFastAnimeSearchResultsResolvingRatings(_ results: [TMDBSearchResult]) async -> [TMDBSearchResult] {
        await prepareMaturityRatings(for: results)
        return filterFastAnimeSearchResults(results)
    }

    func filterContinueWatchingResolvingRatings(
        _ items: [ContinueWatchingItem]
    ) async -> [ContinueWatchingItem] {
        guard ProfileManager.shared.isKidsModeActive else { return items }
        await TMDBMaturityRatingStore.shared.resolve(
            items.map { (isMovie: $0.isMovie, id: $0.tmdbId) }
        )
        return items.filter { item in
            guard TMDBMaturityRatingStore.shared.isAllowedForKids(isMovie: item.isMovie, id: item.tmdbId) else {
                return false
            }
            guard TMDBMaturityRatingStore.shared.kidsDetailPolicyAllows(
                isMovie: item.isMovie,
                id: item.tmdbId
            ) == true else {
                return false
            }

            return Self.kidsTextHeuristicsAllow(title: item.title)
        }
    }

    func filterSearchResults(_ results: [TMDBSearchResult]) -> [TMDBSearchResult] {
        return results.filter { result in
            shouldIncludeCatalogResult(result)
        }
    }

    func filterFastAnimeSearchResults(_ results: [TMDBSearchResult]) -> [TMDBSearchResult] {
        return results.filter { result in
            shouldIncludeCatalogResult(result) && shouldIncludeFastAnimeResult(result)
        }
    }

    func filterMovies(_ movies: [TMDBMovie]) -> [TMDBMovie] {
        return movies.filter { movie in
            guard movie.adult != true else { return false }
            guard shouldIncludeCatalogTitle(movie.title) else { return false }
            guard shouldIncludeForKids(
                title: movie.title,
                overview: movie.overview,
                isMovie: true,
                tmdbID: movie.id
            ) else { return false }
            return shouldIncludeContent(genreIds: movie.genreIds)
        }
    }

    func filterTVShows(_ tvShows: [TMDBTVShow]) -> [TMDBTVShow] {
        return tvShows.filter { tvShow in
            guard tvShow.adult != true else { return false }
            guard shouldIncludeCatalogTitle(tvShow.name) else { return false }
            guard shouldIncludeForKids(
                title: tvShow.name,
                overview: tvShow.overview,
                isMovie: false,
                tmdbID: tvShow.id
            ) else { return false }
            return shouldIncludeContent(genreIds: tvShow.genreIds)
        }
    }

    private func shouldIncludeCatalogResult(_ result: TMDBSearchResult) -> Bool {
        guard result.adult != true else { return false }
        guard shouldIncludeCatalogTitle(result.displayTitle) else { return false }
        guard shouldIncludeForKids(
            title: result.displayTitle,
            overview: result.overview,
            isMovie: result.isMovie,
            tmdbID: result.id
        ) else { return false }

        if kidsModeEnabled, Self.hasExplicitAnimeMetadata(result) { return false }

        if kidsModeEnabled,
           !Self.carriesFullKidsPolicySignals(result),
           TMDBMaturityRatingStore.shared.kidsDetailPolicyAllows(
            isMovie: result.isMovie,
            id: result.id
           ) == false {
            return false
        }
        return shouldIncludeContent(genreIds: result.genreIds)
    }

    private func shouldIncludeForKids(
        title: String,
        overview: String?,
        isMovie: Bool,
        tmdbID: Int
    ) -> Bool {
        guard kidsModeEnabled else { return true }
        guard TMDBMaturityRatingStore.shared.isAllowedForKids(isMovie: isMovie, id: tmdbID) else {
            return false
        }
        let metadataText = [title, overview ?? ""].joined(separator: " ")
        if Self.containsBlockedCatalogText(metadataText, blockedTerms: Self.kidsMetadataDenylist) {
            return false
        }
        return !MaturityRating.containsMatureText(metadataText)
    }

    static func kidsDetailPolicyAllows(
        title: String,
        isAdult: Bool,
        genreIds: [Int],
        overview: String?
    ) -> Bool {
        if isAdult { return false }
        if genreIds.contains(where: kidsBlockedGenreIds.contains) { return false }
        return kidsTextHeuristicsAllow(title: title, overview: overview)
    }

    static func carriesFullKidsPolicySignals(_ result: TMDBSearchResult) -> Bool {
        result.adult != nil && result.genreIds != nil && result.overview != nil
    }

    static func kidsTextHeuristicsAllow(title: String, overview: String? = nil) -> Bool {
        let metadataText = [title, overview ?? ""].joined(separator: " ")
        if containsBlockedCatalogText(metadataText, blockedTerms: kidsMetadataDenylist) {
            return false
        }
        if containsBlockedCatalogText(metadataText, blockedTerms: adultAnimeMetadataDenylist) {
            return false
        }
        return !MaturityRating.containsMatureText(metadataText)
    }

    func kidsPolicyAllowsPlayback(
        isMovie: Bool,
        id: Int,
        title: String,
        persistedDetails: KidsPolicyDetails? = nil
    ) async -> Bool {
        guard kidsModeEnabled else { return true }
        await TMDBMaturityRatingStore.shared.resolve([(isMovie: isMovie, id: id)])
        guard TMDBMaturityRatingStore.shared.isAllowedForKids(isMovie: isMovie, id: id) else {
            return false
        }
        guard Self.kidsTextHeuristicsAllow(title: title) else { return false }

        var hasCompleteAllowedPolicy = false
        if let persistedDetails {
            guard Self.kidsDetailPolicyAllows(
                title: title,
                isAdult: persistedDetails.isAdult,
                genreIds: persistedDetails.genreIds,
                overview: persistedDetails.overview
            ) else { return false }
            hasCompleteAllowedPolicy = true
        }
        if let storedPolicy = TMDBMaturityRatingStore.shared.kidsDetailPolicyAllows(
            isMovie: isMovie,
            id: id
        ) {
            guard storedPolicy else { return false }
            hasCompleteAllowedPolicy = true
        }
        if hasCompleteAllowedPolicy { return true }

        let overview: String?
        let genreIds: [Int]
        let isAdult: Bool
        do {
            if isMovie {
                let detail = try await TMDBService.shared.getMovieDetails(id: id)
                overview = detail.overview
                genreIds = detail.genres.map(\.id)
                isAdult = detail.adult
            } else {
                let detail = try await TMDBService.shared.getTVShowDetails(id: id)
                overview = detail.overview
                genreIds = detail.genres.map(\.id)
                isAdult = detail.adult
            }
        } catch {

            if let persistedDetails {
                return Self.kidsDetailPolicyAllows(
                    title: title,
                    isAdult: persistedDetails.isAdult,
                    genreIds: persistedDetails.genreIds,
                    overview: persistedDetails.overview
                )
            }

            if let allowed = TMDBMaturityRatingStore.shared.kidsDetailPolicyAllows(isMovie: isMovie, id: id) {
                return allowed
            }

            if TMDBMaturityRatingStore.shared.rating(isMovie: isMovie, id: id) == .unknown {
                Logger.shared.log(
                    "Kids gate denied \(isMovie ? "movie" : "tv") \(id): unclassified with no stored policy and no details: \(error.localizedDescription)",
                    type: "Player"
                )
                return false
            }
            Logger.shared.log(
                "Kids gate could not fetch details for \(isMovie ? "movie" : "tv") \(id); the resolved certification stands: \(error.localizedDescription)",
                type: "Player"
            )
            return true
        }

        return Self.kidsDetailPolicyAllows(
            title: title,
            isAdult: isAdult,
            genreIds: genreIds,
            overview: overview
        )
    }

    private func shouldIncludeFastAnimeResult(_ result: TMDBSearchResult) -> Bool {
        !Self.hasExplicitAnimeMetadata(result)
    }

    static func hasExplicitAnimeMetadata(_ result: TMDBSearchResult) -> Bool {
        let metadataText = [result.displayTitle, result.overview ?? ""].joined(separator: " ")
        return containsBlockedCatalogText(metadataText, blockedTerms: adultAnimeMetadataDenylist)
    }

    private func shouldIncludeCatalogTitle(_ title: String) -> Bool {
        let normalized = Self.normalizedCatalogText(title)
        return !explicitCatalogTitleDenylist.contains(normalized)
    }

    private static func containsBlockedCatalogText(_ text: String, blockedTerms: Set<String>) -> Bool {
        let normalized = " \(normalizedCatalogText(text)) "
        return blockedTerms.contains { term in
            normalized.contains(" \(term) ")
        }
    }

    private static func normalizedCatalogText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func shouldIncludeContent(genreIds: [Int]?) -> Bool {
        shouldIncludeContent(resolvedGenreIds: genreIds)
    }

    private func shouldIncludeContent(genres: [TMDBGenre]) -> Bool {
        shouldIncludeContent(resolvedGenreIds: genres.map(\.id))
    }

    private func shouldIncludeContent(resolvedGenreIds genreIds: [Int]?) -> Bool {
        let isKids = kidsModeEnabled
        guard let genreIds, !genreIds.isEmpty else { return true }

        if filterHorror || isKids {
            if genreIds.contains(where: horrorGenreIds.contains) {
                return false
            }
        }

        if isKids, genreIds.contains(where: Self.kidsBlockedGenreIds.contains) {
            return false
        }

        return true
    }
}

extension TMDBContentFilter {

    enum KidsAccessDecision {
        case allowed
        case denied
        case unresolved
    }

    static let kidsAccessResolveBudget: TimeInterval = 2

    func kidsAccessDecision(for result: TMDBSearchResult) -> KidsAccessDecision {
        guard kidsModeEnabled else { return .allowed }

        guard result.id > 0 else { return .denied }
        guard TMDBMaturityRatingStore.shared.rating(isMovie: result.isMovie, id: result.id) != nil else {
            return .unresolved
        }

        return shouldIncludeCatalogResult(result) ? .allowed : .denied
    }

    func resolveKidsAccess(for result: TMDBSearchResult) async -> KidsAccessDecision {
        let immediate = kidsAccessDecision(for: result)
        guard case .unresolved = immediate else { return immediate }

        Task {
            await TMDBMaturityRatingStore.shared.resolve([(isMovie: result.isMovie, id: result.id)])
        }

        let deadline = Date().addingTimeInterval(TMDBContentFilter.kidsAccessResolveBudget)
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 80_000_000)
            let decision = kidsAccessDecision(for: result)
            if decision != .unresolved { return decision }
        }

        Logger.shared.log(
            "Kids gate: denied \(result.isMovie ? "movie" : "tv")/\(result.id) — no certification within \(TMDBContentFilter.kidsAccessResolveBudget)s",
            type: "TMDB"
        )
        return .denied
    }
}
