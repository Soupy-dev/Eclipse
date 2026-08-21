import Foundation

struct KidsDiscoverQuery: Equatable, Sendable {
    enum Sort: String, Sendable {
        case popularity = "popularity.desc"
        case rating = "vote_average.desc"
        case newest = "primary_release_date.desc"
    }

    enum GenreMatch: String, Sendable {
        case any = "|"
        case all = ","
    }

    var mediaType: String
    var genreIDs: [Int]
    var genreMatch: GenreMatch = .any
    var sort: Sort = .popularity

    var certificationCeiling: String?

    var minimumVoteCount: Int?

    static let excludedGenreIDs = [27, 53, 80, 10752, 9648, 10768, 10749]
}

enum KidsHomeCatalog: String, CaseIterable {
    case familyMovies
    case cartoonMovies
    case kidsTV
    case animatedSeries
    case adventureMovies
    case funnyMovies
    case fantasyMovies
    case topRatedFamily
    case newForKids

    var catalogID: String { "kids.\(rawValue)" }

    var displayName: String {
        switch self {
        case .familyMovies: return "Family Movies"
        case .cartoonMovies: return "Cartoons"
        case .kidsTV: return "Kids TV"
        case .animatedSeries: return "Animated Series"
        case .adventureMovies: return "Adventures"
        case .funnyMovies: return "Funny Stuff"
        case .fantasyMovies: return "Magic & Fantasy"
        case .topRatedFamily: return "Best Family Films"
        case .newForKids: return "New for Kids"
        }
    }

    var query: KidsDiscoverQuery {
        switch self {
        case .familyMovies:
            return KidsDiscoverQuery(mediaType: "movie", genreIDs: [10751], certificationCeiling: "PG")
        case .cartoonMovies:
            return KidsDiscoverQuery(mediaType: "movie", genreIDs: [16], certificationCeiling: "PG")
        case .kidsTV:
            return KidsDiscoverQuery(mediaType: "tv", genreIDs: [10762])
        case .animatedSeries:

            return KidsDiscoverQuery(mediaType: "tv", genreIDs: [16, 10751], genreMatch: .all)
        case .adventureMovies:
            return KidsDiscoverQuery(mediaType: "movie", genreIDs: [12], certificationCeiling: "PG")
        case .funnyMovies:
            return KidsDiscoverQuery(
                mediaType: "movie",
                genreIDs: [35, 10751],
                genreMatch: .all,
                certificationCeiling: "PG"
            )
        case .fantasyMovies:
            return KidsDiscoverQuery(mediaType: "movie", genreIDs: [14], certificationCeiling: "PG")
        case .topRatedFamily:
            return KidsDiscoverQuery(
                mediaType: "movie",
                genreIDs: [10751],
                sort: .rating,
                certificationCeiling: "PG",
                minimumVoteCount: 500
            )
        case .newForKids:
            return KidsDiscoverQuery(
                mediaType: "movie",
                genreIDs: [10751, 16],
                sort: .newest,
                certificationCeiling: "PG",
                minimumVoteCount: 20
            )
        }
    }

    static func catalog(for value: KidsHomeCatalog, order: Int) -> Catalog {
        Catalog(
            id: value.catalogID,
            name: value.displayName,
            source: .tmdb,
            isEnabled: true,
            order: order,
            displayStyle: value == .topRatedFamily ? .ranked : .standard
        )
    }

    static func from(catalogID: String) -> KidsHomeCatalog? {
        allCases.first { $0.catalogID == catalogID }
    }
}
