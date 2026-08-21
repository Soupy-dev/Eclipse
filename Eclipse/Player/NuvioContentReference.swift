import Foundation

struct NuvioProviderContentReference: Codable, Hashable, Sendable {
    static let maximumIdentifierLength = 128

    var sourceID: String
    var scraperID: String
    var tmdbID: String
    var mediaType: String
    var season: Int?
    var episode: Int?

    init(
        sourceID: String,
        scraperID: String,
        tmdbID: String,
        mediaType: String,
        season: Int? = nil,
        episode: Int? = nil
    ) {
        self.sourceID = Self.bounded(sourceID) ?? ""
        self.scraperID = Self.bounded(scraperID) ?? ""
        self.tmdbID = Self.bounded(tmdbID) ?? ""
        self.mediaType = Self.bounded(mediaType)?.lowercased() ?? ""
        self.season = Self.boundedNumber(season)
        self.episode = Self.boundedNumber(episode)
    }

    var isStructurallyValid: Bool {
        guard sourceID.hasPrefix("nuvio:"),
              Self.bounded(sourceID) != nil,
              Self.bounded(scraperID) != nil,
              Self.bounded(tmdbID) != nil,
              tmdbID.allSatisfy({ $0.isNumber }),
              mediaType == "movie" || mediaType == "tv" else {
            return false
        }
        if mediaType == "tv" {
            guard let season, let episode, season >= 0, episode >= 0 else { return false }
        }
        return true
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumIdentifierLength else { return nil }
        return trimmed
    }

    private static func boundedNumber(_ value: Int?) -> Int? {
        guard let value, value >= 0, value <= 100_000 else { return nil }
        return value
    }
}
