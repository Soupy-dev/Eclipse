import Foundation

class TMDBContentFilter: ObservableObject {
    static let shared = TMDBContentFilter()
    
    @Published var filterHorror: Bool {
        didSet {
            UserDefaults.standard.set(filterHorror, forKey: "filterHorror")
        }
    }
    
    private let horrorGenreIds = [27]
    private let explicitCatalogTitleDenylist: Set<String> = [
        "overflow"
    ]
    private let adultAnimeMetadataDenylist: Set<String> = [
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
        self.filterHorror = UserDefaults.standard.bool(forKey: "filterHorror")
    }
    
    // MARK: - Filter Functions
    
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
            return shouldIncludeContent(genreIds: movie.genreIds)
        }
    }
    
    func filterTVShows(_ tvShows: [TMDBTVShow]) -> [TMDBTVShow] {
        return tvShows.filter { tvShow in
            guard tvShow.adult != true else { return false }
            guard shouldIncludeCatalogTitle(tvShow.name) else { return false }
            return shouldIncludeContent(genreIds: tvShow.genreIds)
        }
    }

    private func shouldIncludeCatalogResult(_ result: TMDBSearchResult) -> Bool {
        guard result.adult != true else { return false }
        guard shouldIncludeCatalogTitle(result.displayTitle) else { return false }
        return shouldIncludeContent(genreIds: result.genreIds)
    }

    private func shouldIncludeFastAnimeResult(_ result: TMDBSearchResult) -> Bool {
        let metadataText = [result.displayTitle, result.overview ?? ""].joined(separator: " ")
        return !containsBlockedCatalogText(metadataText, blockedTerms: adultAnimeMetadataDenylist)
    }

    private func shouldIncludeCatalogTitle(_ title: String) -> Bool {
        let normalized = normalizedCatalogText(title)
        return !explicitCatalogTitleDenylist.contains(normalized)
    }

    private func containsBlockedCatalogText(_ text: String, blockedTerms: Set<String>) -> Bool {
        let normalized = " \(normalizedCatalogText(text)) "
        return blockedTerms.contains { term in
            normalized.contains(" \(term) ")
        }
    }

    private func normalizedCatalogText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    
    private func shouldIncludeContent(genreIds: [Int]?) -> Bool {
        if filterHorror {
            if let genreIds = genreIds {
                let containsHorror = genreIds.contains { genreId in
                    horrorGenreIds.contains(genreId)
                }
                if containsHorror {
                    return false
                }
            }
        }
        
        return true
    }
    
    private func shouldIncludeContent(genres: [TMDBGenre]) -> Bool {
        if filterHorror {
            let containsHorror = genres.contains { genre in
                horrorGenreIds.contains(genre.id)
            }
            if containsHorror {
                return false
            }
        }
        
        return true
    }
}
