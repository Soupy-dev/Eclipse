//
//  TMDBModels.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import Foundation

private struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let skippedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var skippedCount = 0

        while !container.isAtEnd {
            let value = try container.decode(LossyDecodableValue<Element>.self)
            if let element = value.element {
                elements.append(element)
            } else {
                skippedCount += 1
            }
        }

        self.elements = elements
        self.skippedCount = skippedCount
    }
}

private struct LossyDecodableValue<Element: Decodable>: Decodable {
    let element: Element?

    init(from decoder: Decoder) throws {
        element = try? Element(from: decoder)
    }
}

struct TMDBSearchResponse: Decodable {
    let page: Int
    let results: [TMDBSearchResult]
    let totalPages: Int
    let totalResults: Int
    let skippedResultCount: Int

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
        case totalResults = "total_results"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lossyResults = try container.decodeIfPresent(LossyDecodableArray<TMDBSearchResult>.self, forKey: .results)

        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 1
        results = lossyResults?.elements ?? []
        totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages) ?? 1
        totalResults = try container.decodeIfPresent(Int.self, forKey: .totalResults) ?? results.count
        skippedResultCount = lossyResults?.skippedCount ?? 0
    }

    init(page: Int, results: [TMDBSearchResult], totalPages: Int, totalResults: Int, skippedResultCount: Int = 0) {
        self.page = page
        self.results = results
        self.totalPages = totalPages
        self.totalResults = totalResults
        self.skippedResultCount = skippedResultCount
    }
}

struct TMDBFindResponse: Decodable {
    let movieResults: [TMDBMovie]
    let tvResults: [TMDBTVShow]

    enum CodingKeys: String, CodingKey {
        case movieResults = "movie_results"
        case tvResults = "tv_results"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movieResults = (try container.decodeIfPresent(LossyDecodableArray<TMDBMovie>.self, forKey: .movieResults))?.elements ?? []
        tvResults = (try container.decodeIfPresent(LossyDecodableArray<TMDBTVShow>.self, forKey: .tvResults))?.elements ?? []
    }
}

struct AnimeMediaIdentitySeed: Codable, Equatable, Sendable {
    let anilistId: Int
    let malId: Int?
    let kitsuId: Int?
    let format: String?

    init(anilistId: Int, malId: Int? = nil, kitsuId: Int? = nil, format: String? = nil) {
        self.anilistId = anilistId
        self.malId = malId
        self.kitsuId = kitsuId
        self.format = format
    }

    var sanitizedForPersistence: AnimeMediaIdentitySeed? {
        let maximumIdentifier = ProgressPersistencePolicy.maximumIdentifier
        guard anilistId != 0,
              anilistId != Int.min,
              (-maximumIdentifier...maximumIdentifier).contains(anilistId) else {
            return nil
        }
        let safeMAL = malId.flatMap {
            ProgressPersistencePolicy.validPositiveIdentifier($0) ? $0 : nil
        }
        let safeKitsu = kitsuId.flatMap {
            ProgressPersistencePolicy.validPositiveIdentifier($0) ? $0 : nil
        }
        let safeFormat = format.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(64))
        }
        return AnimeMediaIdentitySeed(
            anilistId: anilistId,
            malId: safeMAL,
            kitsuId: safeKitsu,
            format: safeFormat
        )
    }

}

struct TMDBSearchResult: Codable, Identifiable {
    let id: Int
    let mediaType: String
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let popularity: Double
    let adult: Bool?
    let genreIds: [Int]?
    let originalLanguage: String?
    let originCountry: [String]?
    let voteCount: Int?

    let isAnimeHint: Bool?

    let animeIdentitySeed: AnimeMediaIdentitySeed?

    enum CodingKeys: String, CodingKey {
        case id, overview, popularity, adult
        case mediaType = "media_type"
        case title, name
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case genreIds = "genre_ids"
        case originalLanguage = "original_language"
        case originCountry = "origin_country"
        case voteCount = "vote_count"
        case isAnimeHint = "is_anime_hint"
        case animeIdentitySeed = "anime_identity_seed"
    }

    init(
        id: Int,
        mediaType: String,
        title: String?,
        name: String?,
        overview: String?,
        posterPath: String?,
        backdropPath: String?,
        releaseDate: String?,
        firstAirDate: String?,
        voteAverage: Double?,
        popularity: Double,
        adult: Bool?,
        genreIds: [Int]?,
        originalLanguage: String? = nil,
        originCountry: [String]? = nil,
        voteCount: Int? = nil,
        isAnimeHint: Bool? = nil,
        animeIdentitySeed: AnimeMediaIdentitySeed? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.title = title
        self.name = name
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.releaseDate = releaseDate
        self.firstAirDate = firstAirDate
        self.voteAverage = voteAverage
        self.popularity = popularity
        self.adult = adult
        self.genreIds = genreIds
        self.originalLanguage = originalLanguage
        self.originCountry = originCountry
        self.voteCount = voteCount
        self.isAnimeHint = isAnimeHint
        self.animeIdentitySeed = animeIdentitySeed?.sanitizedForPersistence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(Int.self, forKey: .id)
        guard let validatedID = RemoteMediaNumericBoundary.positiveIdentifier(rawID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "TMDB search-result identifier is outside the supported range."
            )
        }
        id = validatedID
        mediaType = try container.decode(String.self, forKey: .mediaType)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        posterPath = try container.decodeIfPresent(String.self, forKey: .posterPath)
        backdropPath = try container.decodeIfPresent(String.self, forKey: .backdropPath)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        firstAirDate = try container.decodeIfPresent(String.self, forKey: .firstAirDate)
        let decodedVoteAverage = try container.decodeIfPresent(Double.self, forKey: .voteAverage)
        guard decodedVoteAverage.map({ $0.isFinite && (0...10).contains($0) }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .voteAverage,
                in: container,
                debugDescription: "TMDB search-result score is outside the supported range."
            )
        }
        voteAverage = decodedVoteAverage
        let decodedPopularity = try container.decodeIfPresent(Double.self, forKey: .popularity) ?? 0
        guard decodedPopularity.isFinite, decodedPopularity >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .popularity,
                in: container,
                debugDescription: "TMDB search-result popularity is outside the supported range."
            )
        }
        popularity = decodedPopularity
        adult = try container.decodeIfPresent(Bool.self, forKey: .adult)
        let decodedGenreIDs = try container.decodeIfPresent([Int].self, forKey: .genreIds)
        guard (decodedGenreIDs?.count ?? 0) <= 128,
              decodedGenreIDs?.allSatisfy({
                  RemoteMediaNumericBoundary.positiveIdentifier($0) != nil
              }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .genreIds,
                in: container,
                debugDescription: "TMDB search-result genres contain unsupported identifiers."
            )
        }
        genreIds = decodedGenreIDs
        originalLanguage = try container.decodeIfPresent(String.self, forKey: .originalLanguage)
        originCountry = try container.decodeIfPresent([String].self, forKey: .originCountry)
        let decodedVoteCount = try container.decodeIfPresent(Int.self, forKey: .voteCount)
        guard decodedVoteCount.map({
            (0...RemoteMediaNumericBoundary.maximumIdentifier).contains($0)
        }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .voteCount,
                in: container,
                debugDescription: "TMDB search-result vote count is outside the supported range."
            )
        }
        voteCount = decodedVoteCount
        isAnimeHint = try container.decodeIfPresent(Bool.self, forKey: .isAnimeHint)
        animeIdentitySeed = try container
            .decodeIfPresent(AnimeMediaIdentitySeed.self, forKey: .animeIdentitySeed)?
            .sanitizedForPersistence
    }

    var displayTitle: String {
        return title ?? name ?? "Unknown Title"
    }

    var displayDate: String {
        return releaseDate ?? firstAirDate ?? ""
    }

    var isMovie: Bool {
        return mediaType == "movie"
    }

    var isTVShow: Bool {
        return mediaType == "tv"
    }

    var fullPosterURL: String? {
        guard let posterPath = posterPath else { return nil }
        if posterPath.lowercased().hasPrefix("http://") || posterPath.lowercased().hasPrefix("https://") {
            return posterPath
        }
        return "\(TMDBService.tmdbImageBaseURL)\(posterPath)"
    }

    var fullBackdropURL: String? {
        guard let backdropPath = backdropPath else { return nil }
        if backdropPath.lowercased().hasPrefix("http://") || backdropPath.lowercased().hasPrefix("https://") {
            return backdropPath
        }
        return "\(TMDBService.tmdbImageBaseURL)\(backdropPath)"
    }

    var stableIdentity: String {
        "\(mediaType)-\(id)"
    }

    /// User-controlled backups and peer/cloud payloads can persist this model
    /// without passing through TMDB's network decoder. Keep identity-sized
    /// integers within the range used by progress and episode-key arithmetic,
    /// while retaining an otherwise usable neighboring result.
    var sanitizedForPersistence: TMDBSearchResult? {
        guard ProgressPersistencePolicy.validPositiveIdentifier(id) else {
            return nil
        }
        let normalizedMediaType = mediaType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedMediaType == "movie" || normalizedMediaType == "tv",
              popularity.isFinite,
              voteAverage.map({ $0.isFinite && (0...10).contains($0) }) ?? true,
              voteCount.map({ (0...ProgressPersistencePolicy.maximumIdentifier).contains($0) }) ?? true else {
            return nil
        }
        let safeGenreIDs = genreIds.map { values in
            Array(values.filter(ProgressPersistencePolicy.validPositiveIdentifier).prefix(128))
        }
        return TMDBSearchResult(
            id: id,
            mediaType: normalizedMediaType,
            title: title,
            name: name,
            overview: overview,
            posterPath: posterPath,
            backdropPath: backdropPath,
            releaseDate: releaseDate,
            firstAirDate: firstAirDate,
            voteAverage: voteAverage,
            popularity: popularity,
            adult: adult,
            genreIds: safeGenreIDs,
            originalLanguage: originalLanguage,
            originCountry: originCountry,
            voteCount: voteCount,
            isAnimeHint: isAnimeHint,
            animeIdentitySeed: animeIdentitySeed?.sanitizedForPersistence
        )
    }

    func withAnimeIdentitySeed(_ seed: AnimeMediaIdentitySeed?) -> TMDBSearchResult {
        TMDBSearchResult(
            id: id,
            mediaType: mediaType,
            title: title,
            name: name,
            overview: overview,
            posterPath: posterPath,
            backdropPath: backdropPath,
            releaseDate: releaseDate,
            firstAirDate: firstAirDate,
            voteAverage: voteAverage,
            popularity: popularity,
            adult: adult,
            genreIds: genreIds,
            originalLanguage: originalLanguage,
            originCountry: originCountry,
            voteCount: voteCount,
            isAnimeHint: isAnimeHint,
            animeIdentitySeed: seed?.sanitizedForPersistence
        )
    }
}

struct TMDBMovieSearchResponse: Decodable {
    let page: Int
    let results: [TMDBMovie]
    let totalPages: Int
    let totalResults: Int
    let skippedResultCount: Int

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
        case totalResults = "total_results"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lossyResults = try container.decodeIfPresent(LossyDecodableArray<TMDBMovie>.self, forKey: .results)

        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 1
        results = lossyResults?.elements ?? []
        totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages) ?? 1
        totalResults = try container.decodeIfPresent(Int.self, forKey: .totalResults) ?? results.count
        skippedResultCount = lossyResults?.skippedCount ?? 0
    }

    init(page: Int, results: [TMDBMovie], totalPages: Int, totalResults: Int, skippedResultCount: Int = 0) {
        self.page = page
        self.results = results
        self.totalPages = totalPages
        self.totalResults = totalResults
        self.skippedResultCount = skippedResultCount
    }
}

struct TMDBTVSearchResponse: Decodable {
    let page: Int
    let results: [TMDBTVShow]
    let totalPages: Int
    let totalResults: Int
    let skippedResultCount: Int

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
        case totalResults = "total_results"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lossyResults = try container.decodeIfPresent(LossyDecodableArray<TMDBTVShow>.self, forKey: .results)

        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 1
        results = lossyResults?.elements ?? []
        totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages) ?? 1
        totalResults = try container.decodeIfPresent(Int.self, forKey: .totalResults) ?? results.count
        skippedResultCount = lossyResults?.skippedCount ?? 0
    }

    init(page: Int, results: [TMDBTVShow], totalPages: Int, totalResults: Int, skippedResultCount: Int = 0) {
        self.page = page
        self.results = results
        self.totalPages = totalPages
        self.totalResults = totalResults
        self.skippedResultCount = skippedResultCount
    }
}

struct TMDBMovie: Codable, Identifiable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double
    let popularity: Double
    let adult: Bool?
    let genreIds: [Int]?
    let originalLanguage: String?
    let originCountry: [String]?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, popularity, adult
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case voteAverage = "vote_average"
        case genreIds = "genre_ids"
        case originalLanguage = "original_language"
        case originCountry = "origin_country"
    }

    var fullPosterURL: String? {
        guard let posterPath = posterPath else { return nil }
        return "\(TMDBService.tmdbImageBaseURL)\(posterPath)"
    }

    var fullBackdropURL: String? {
        guard let backdropPath = backdropPath else { return nil }
        return "\(TMDBService.tmdbImageBaseURL)\(backdropPath)"
    }

    var asSearchResult: TMDBSearchResult {
        return TMDBSearchResult(
            id: id,
            mediaType: "movie",
            title: title,
            name: nil,
            overview: overview,
            posterPath: posterPath,
            backdropPath: backdropPath,
            releaseDate: releaseDate,
            firstAirDate: nil,
            voteAverage: voteAverage,
            popularity: popularity,
            adult: adult,
            genreIds: genreIds,
            originalLanguage: originalLanguage,
            originCountry: originCountry
        )
    }
}

struct TMDBTVShow: Codable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let voteAverage: Double
    let popularity: Double
    let genreIds: [Int]?
    let adult: Bool?
    let originalLanguage: String?
    let originCountry: [String]?
    let voteCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, popularity, adult
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case genreIds = "genre_ids"
        case originalLanguage = "original_language"
        case originCountry = "origin_country"
        case voteCount = "vote_count"
    }

    var fullPosterURL: String? {
        guard let posterPath = posterPath else { return nil }
        return "\(TMDBService.tmdbImageBaseURL)\(posterPath)"
    }

    var fullBackdropURL: String? {
        guard let backdropPath = backdropPath else { return nil }
        return "\(TMDBService.tmdbImageBaseURL)\(backdropPath)"
    }

    var asSearchResult: TMDBSearchResult {
        return TMDBSearchResult(
            id: id,
            mediaType: "tv",
            title: nil,
            name: name,
            overview: overview,
            posterPath: posterPath,
            backdropPath: backdropPath,
            releaseDate: nil,
            firstAirDate: firstAirDate,
            voteAverage: voteAverage,
            popularity: popularity,
            adult: adult,
            genreIds: genreIds,
            originalLanguage: originalLanguage,
            originCountry: originCountry,
            voteCount: voteCount
        )
    }
}

struct TMDBMovieDetail: Codable, Identifiable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double
    let popularity: Double
    let runtime: Int?
    let genres: [TMDBGenre]
    let tagline: String?
    let status: String?
    let budget: Int?
    let revenue: Int?
    let imdbId: String?
    let originalLanguage: String?
    let originalTitle: String?
    let adult: Bool
    let voteCount: Int
    let releaseDates: TMDBReleaseDates?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, popularity, runtime, genres, tagline, status, budget, revenue, adult
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case voteAverage = "vote_average"
        case imdbId = "imdb_id"
        case originalLanguage = "original_language"
        case originalTitle = "original_title"
        case voteCount = "vote_count"
        case releaseDates = "release_dates"
    }

    var fullPosterURL: String? {
        guard let posterPath = posterPath else { return nil }
        return "\(TMDBService.tmdbImageBaseURL)\(posterPath)"
    }

    var fullBackdropURL: String? {
        guard let backdropPath = backdropPath else { return nil }
        return "\(TMDBService.tmdbImageBaseURL)\(backdropPath)"
    }

    var runtimeFormatted: String {
        guard let runtime = runtime, runtime > 0 else { return "Unknown" }
        let hours = runtime / 60
        let minutes = runtime % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    var yearFromReleaseDate: String {
        guard let releaseDate = releaseDate, !releaseDate.isEmpty else { return "Unknown" }
        return String(releaseDate.prefix(4))
    }
}

struct TMDBExternalIds: Codable {
    let imdbId: String?
    let freebaseMid: String?
    let freebaseId: String?
    let tvdbId: Int?
    let tvrageId: Int?
    let facebookId: String?
    let instagramId: String?
    let twitterId: String?

    enum CodingKeys: String, CodingKey {
        case imdbId = "imdb_id"
        case freebaseMid = "freebase_mid"
        case freebaseId = "freebase_id"
        case tvdbId = "tvdb_id"
        case tvrageId = "tvrage_id"
        case facebookId = "facebook_id"
        case instagramId = "instagram_id"
        case twitterId = "twitter_id"
    }
}

struct TMDBTVShowDetail: Codable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let lastAirDate: String?
    let voteAverage: Double
    let popularity: Double
    let genres: [TMDBGenre]
    let tagline: String?
    let status: String?
    let originalLanguage: String?
    let originalName: String?
    let adult: Bool
    let voteCount: Int
    let numberOfSeasons: Int?
    let numberOfEpisodes: Int?
    let episodeRunTime: [Int]?
    let inProduction: Bool?
    let languages: [String]?
    let originCountry: [String]?
    let type: String?
    let contentRatings: TMDBContentRatings?
    let externalIds: TMDBExternalIds?
    let nextEpisodeToAir: TMDBEpisode?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, popularity, genres, tagline, status, adult, languages, type
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
        case lastAirDate = "last_air_date"
        case voteAverage = "vote_average"
        case originalLanguage = "original_language"
        case originalName = "original_name"
        case voteCount = "vote_count"
        case numberOfSeasons = "number_of_seasons"
        case numberOfEpisodes = "number_of_episodes"
        case episodeRunTime = "episode_run_time"
        case inProduction = "in_production"
        case originCountry = "origin_country"
        case contentRatings = "content_ratings"
        case externalIds = "external_ids"
        case nextEpisodeToAir = "next_episode_to_air"
    }

    var fullPosterURL: String? {
        guard let posterPath = posterPath else { return nil }
        return "\(TMDBService.tmdbImageBaseURL)\(posterPath)"
    }

    var fullBackdropURL: String? {
        guard let backdropPath = backdropPath else { return nil }
        return "\(TMDBService.tmdbImageBaseURL)\(backdropPath)"
    }

    var yearFromFirstAirDate: String {
        guard let firstAirDate = firstAirDate, !firstAirDate.isEmpty else { return "Unknown" }
        return String(firstAirDate.prefix(4))
    }

    var episodeRuntimeFormatted: String {
        guard let runtime = episodeRunTime?.first, runtime > 0 else { return "Unknown" }
        return "\(runtime)m"
    }
}

struct TMDBGenre: Codable, Identifiable {
    let id: Int
    let name: String
}

struct TMDBSeason: Codable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let seasonNumber: Int
    let episodeCount: Int
    let airDate: String?

    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case posterPath = "poster_path"
        case seasonNumber = "season_number"
        case episodeCount = "episode_count"
        case airDate = "air_date"
    }

    var fullPosterURL: String? {
        guard let posterPath = posterPath else { return nil }

        if posterPath.hasPrefix("http") { return posterPath }
        return "\(TMDBService.tmdbImageBaseURL)\(posterPath)"
    }
}

struct TMDBEpisode: Codable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let stillPath: String?
    let episodeNumber: Int
    let seasonNumber: Int
    let airDate: String?
    let runtime: Int?
    let voteAverage: Double
    let voteCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, overview, runtime
        case stillPath = "still_path"
        case episodeNumber = "episode_number"
        case seasonNumber = "season_number"
        case airDate = "air_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
    }

    var fullStillURL: String? {
        guard let stillPath = stillPath else { return nil }
        return "\(TMDBService.tmdbImageBaseURL)\(stillPath)"
    }

    var runtimeFormatted: String {
        guard let runtime = runtime, runtime > 0 else { return "Unknown" }
        return "\(runtime)m"
    }
}

struct TMDBSeasonDetail: Codable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let seasonNumber: Int
    let airDate: String?
    let episodes: [TMDBEpisode]

    enum CodingKeys: String, CodingKey {
        case id, name, overview, episodes
        case posterPath = "poster_path"
        case seasonNumber = "season_number"
        case airDate = "air_date"
    }

    var fullPosterURL: String? {
        guard let posterPath = posterPath else { return nil }
        if posterPath.hasPrefix("http") { return posterPath }
        return "\(TMDBService.tmdbImageBaseURL)\(posterPath)"
    }
}

struct TMDBTVShowWithSeasons: Codable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let lastAirDate: String?
    let voteAverage: Double
    let popularity: Double
    let genres: [TMDBGenre]
    let tagline: String?
    let status: String?
    let originalLanguage: String?
    let originalName: String?
    let adult: Bool
    let voteCount: Int
    let numberOfSeasons: Int?
    let numberOfEpisodes: Int?
    let episodeRunTime: [Int]?
    let inProduction: Bool?
    let languages: [String]?
    let originCountry: [String]?
    let type: String?
    let seasons: [TMDBSeason]
    let contentRatings: TMDBContentRatings?
    let externalIds: TMDBExternalIds?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, popularity, genres, tagline, status, adult, languages, type, seasons
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
        case lastAirDate = "last_air_date"
        case voteAverage = "vote_average"
        case originalLanguage = "original_language"
        case originalName = "original_name"
        case voteCount = "vote_count"
        case numberOfSeasons = "number_of_seasons"
        case numberOfEpisodes = "number_of_episodes"
        case episodeRunTime = "episode_run_time"
        case inProduction = "in_production"
        case originCountry = "origin_country"
        case contentRatings = "content_ratings"
        case externalIds = "external_ids"
    }

    var fullPosterURL: String? {
        guard let posterPath = posterPath else { return nil }
        return "\(TMDBService.tmdbImageBaseURL)\(posterPath)"
    }

    var fullBackdropURL: String? {
        guard let backdropPath = backdropPath else { return nil }
        return "\(TMDBService.tmdbImageBaseURL)\(backdropPath)"
    }

    var yearFromFirstAirDate: String {
        guard let firstAirDate = firstAirDate, !firstAirDate.isEmpty else { return "Unknown" }
        return String(firstAirDate.prefix(4))
    }

    var episodeRuntimeFormatted: String {
        guard let runtime = episodeRunTime?.first, runtime > 0 else { return "Unknown" }
        return "\(runtime)m"
    }
}

extension TMDBEpisode {
    var isValidRemotePayload: Bool {
        RemoteMediaNumericBoundary.positiveIdentifier(id) != nil
            && RemoteMediaNumericBoundary.seasonNumber(seasonNumber, allowsZero: true) != nil
            && RemoteMediaNumericBoundary.episodeNumber(episodeNumber) != nil
            && (runtime.map({ (0...24 * 60).contains($0) }) ?? true)
            && voteAverage.isFinite
            && (0...10).contains(voteAverage)
            && (0...RemoteMediaNumericBoundary.maximumIdentifier).contains(voteCount)
    }
}

extension TMDBSeasonDetail {
    var isValidRemotePayload: Bool {
        guard RemoteMediaNumericBoundary.positiveIdentifier(id) != nil,
              RemoteMediaNumericBoundary.seasonNumber(seasonNumber, allowsZero: true) != nil,
              episodes.count <= RemoteMediaNumericBoundary.maximumEpisodeCount else {
            return false
        }
        var seenEpisodeNumbers = Set<Int>()
        var seenEpisodeIDs = Set<Int>()
        for episode in episodes {
            guard episode.isValidRemotePayload,
                  episode.seasonNumber == seasonNumber,
                  seenEpisodeNumbers.insert(episode.episodeNumber).inserted,
                  seenEpisodeIDs.insert(episode.id).inserted else {
                return false
            }
        }
        return true
    }
}

extension TMDBSeason {
    var isValidRemotePayload: Bool {
        RemoteMediaNumericBoundary.positiveIdentifier(id) != nil
            && RemoteMediaNumericBoundary.seasonNumber(seasonNumber, allowsZero: true) != nil
            && (0...RemoteMediaNumericBoundary.maximumEpisodeCount).contains(episodeCount)
    }
}

extension TMDBTVShowDetail {
    var isValidRemotePayload: Bool {
        guard RemoteMediaNumericBoundary.positiveIdentifier(id) != nil,
              voteAverage.isFinite,
              (0...10).contains(voteAverage),
              popularity.isFinite,
              popularity >= 0,
              (0...RemoteMediaNumericBoundary.maximumIdentifier).contains(voteCount),
              genres.count <= 128,
              genres.allSatisfy({ RemoteMediaNumericBoundary.positiveIdentifier($0.id) != nil }),
              numberOfSeasons.map({
                  (0...RemoteMediaNumericBoundary.maximumSeasonNumber).contains($0)
              }) ?? true,
              numberOfEpisodes.map({
                  (0...RemoteMediaNumericBoundary.maximumTotalEpisodeCount).contains($0)
              }) ?? true,
              validRemoteEpisodeRuntimes(episodeRunTime),
              languages.map({ $0.count <= 128 }) ?? true,
              originCountry.map({ $0.count <= 128 }) ?? true,
              nextEpisodeToAir.map(\.isValidRemotePayload) ?? true else {
            return false
        }
        return true
    }
}

extension TMDBTVShowWithSeasons {
    var isValidRemotePayload: Bool {
        guard RemoteMediaNumericBoundary.positiveIdentifier(id) != nil,
              voteAverage.isFinite,
              (0...10).contains(voteAverage),
              popularity.isFinite,
              popularity >= 0,
              (0...RemoteMediaNumericBoundary.maximumIdentifier).contains(voteCount),
              genres.count <= 128,
              genres.allSatisfy({ RemoteMediaNumericBoundary.positiveIdentifier($0.id) != nil }),
              seasons.count <= RemoteMediaNumericBoundary.maximumSeasonNumber,
              numberOfSeasons.map({
                  (0...RemoteMediaNumericBoundary.maximumSeasonNumber).contains($0)
              }) ?? true,
              numberOfEpisodes.map({
                  (0...RemoteMediaNumericBoundary.maximumTotalEpisodeCount).contains($0)
              }) ?? true,
              validRemoteEpisodeRuntimes(episodeRunTime),
              languages.map({ $0.count <= 128 }) ?? true,
              originCountry.map({ $0.count <= 128 }) ?? true else {
            return false
        }

        var seenSeasonNumbers = Set<Int>()
        var seenSeasonIDs = Set<Int>()
        var representedEpisodes = 0
        for season in seasons {
            guard season.isValidRemotePayload,
                  seenSeasonNumbers.insert(season.seasonNumber).inserted,
                  seenSeasonIDs.insert(season.id).inserted,
                  season.episodeCount <= RemoteMediaNumericBoundary.maximumTotalEpisodeCount - representedEpisodes else {
                return false
            }
            representedEpisodes += season.episodeCount
        }
        return true
    }
}

private func validRemoteEpisodeRuntimes(_ values: [Int]?) -> Bool {
    guard let values else { return true }
    return values.count <= 64 && values.allSatisfy { (0...24 * 60).contains($0) }
}

struct TMDBAlternativeTitles: Codable {
    let id: Int
    let titles: [TMDBAlternativeTitle]
}

struct TMDBAlternativeTitle: Codable {
    let iso31661: String
    let title: String
    let type: String?

    enum CodingKeys: String, CodingKey {
        case title, type
        case iso31661 = "iso_3166_1"
    }
}

struct TMDBTVAlternativeTitles: Codable {
    let id: Int
    let results: [TMDBTVAlternativeTitle]
}

struct TMDBTVAlternativeTitle: Codable {
    let iso31661: String
    let title: String
    let type: String?

    enum CodingKeys: String, CodingKey {
        case title, type
        case iso31661 = "iso_3166_1"
    }
}

struct TMDBReleaseDates: Codable {
    let results: [TMDBReleaseDateResult]
}

struct TMDBReleaseDateResult: Codable {
    let iso31661: String
    let releaseDates: [TMDBReleaseDate]

    enum CodingKeys: String, CodingKey {
        case iso31661 = "iso_3166_1"
        case releaseDates = "release_dates"
    }
}

struct TMDBReleaseDate: Codable {
    let certification: String
    let iso6391: String?
    let note: String?
    let releaseDate: String
    let type: Int

    enum CodingKeys: String, CodingKey {
        case certification, note, type
        case iso6391 = "iso_639_1"
        case releaseDate = "release_date"
    }
}

struct TMDBContentRatings: Codable {
    let results: [TMDBContentRating]
}

struct TMDBContentRating: Codable {
    let descriptors: [String]?
    let iso31661: String
    let rating: String

    enum CodingKeys: String, CodingKey {
        case descriptors, rating
        case iso31661 = "iso_3166_1"
    }
}

struct TMDBImagesResponse: Codable {
    let id: Int
    let backdrops: [TMDBImage]?
    let logos: [TMDBImage]?
    let posters: [TMDBImage]?
}

struct TMDBImage: Codable {
    let aspectRatio: Double
    let height: Int
    let width: Int
    let filePath: String
    let iso6391: String?
    let voteAverage: Double?
    let voteCount: Int?

    enum CodingKeys: String, CodingKey {
        case height, width
        case aspectRatio = "aspect_ratio"
        case filePath = "file_path"
        case iso6391 = "iso_639_1"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
    }

    var fullURL: String {
        return "\(TMDBService.tmdbImageBaseURL)\(filePath)"
    }
}

struct TMDBVideosResponse: Codable {
    let id: Int
    let results: [TMDBVideo]
}

struct TMDBVideo: Codable, Identifiable {
    let id: String
    let iso6391: String?
    let iso31661: String?
    let name: String
    let key: String
    let site: String
    let size: Int?
    let type: String
    let official: Bool?
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, key, site, size, type, official
        case iso6391 = "iso_639_1"
        case iso31661 = "iso_3166_1"
        case publishedAt = "published_at"
    }

    var isTrailerLike: Bool {
        let normalizedType = type.lowercased()
        return normalizedType == "trailer" || normalizedType == "teaser" || normalizedType.contains("clip")
    }

    var playbackURL: URL? {
        switch site.lowercased() {
        case "youtube":
            return URL(string: "https://www.youtube.com/watch?v=\(key)")
        case "vimeo":
            return URL(string: "https://vimeo.com/\(key)")
        default:
            return nil
        }
    }

    var thumbnailURL: URL? {
        guard site.lowercased() == "youtube" else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(key)/hqdefault.jpg")
    }
}

struct TMDBCreditsResponse: Codable {
    let id: Int
    let cast: [TMDBCastMember]
}

struct TMDBCastMember: Codable, Identifiable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?
    let order: Int?
    let knownForDepartment: String?
    let popularity: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, character, order, popularity
        case profilePath = "profile_path"
        case knownForDepartment = "known_for_department"
    }

    var fullProfileURL: String? {
        guard let profilePath = profilePath else { return nil }
        return "\(TMDBService.tmdbImageBaseURL)\(profilePath)"
    }
}
