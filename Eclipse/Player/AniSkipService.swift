import Foundation

enum SkipType: String, Codable {
    case intro
    case outro
    case recap
    case preview

    var displayLabel: String {
        switch self {
        case .intro: return "Skip Intro"
        case .outro: return "Skip Outro"
        case .recap: return "Skip Recap"
        case .preview: return "Skip Preview"
        }
    }
}

struct SkipSegment {
    let startTime: Double
    let endTime: Double
    let type: SkipType

    var uniqueKey: String {
        guard startTime >= 0,
              let seconds = Int(exactly: startTime.rounded(.towardZero)) else {
            return "\(type.rawValue)_unknown"
        }
        return "\(type.rawValue)_\(seconds)"
    }
}

private struct AniSkipResponse: Codable {
    let found: Bool
    let results: [AniSkipResult]?
    let statusCode: Int
}

private struct AniSkipResult: Codable {
    let interval: AniSkipInterval
    let skipType: String
    let skipId: String
    let episodeLength: Double
}

private struct AniSkipInterval: Codable {
    let startTime: Double
    let endTime: Double
}

final class AniSkipService {
    static let shared = AniSkipService()

    private let baseURL = "https://api.aniskip.com/v2"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    func fetchSkipTimes(malId: Int, episodeNumber: Int, episodeDuration: Double) async throws -> [SkipSegment] {
        let episodeLength = Self.episodeLengthParameter(for: episodeDuration)
        let durationIsUsable = episodeLength > 0
        let durationParam = "&episodeLength=\(episodeLength)"
        let urlString = "\(baseURL)/skip-times/\(malId)/\(episodeNumber)?types[]=op&types[]=ed&types[]=recap&types[]=mixed-op&types[]=mixed-ed\(durationParam)"

        guard let url = URL(string: urlString) else {
            Logger.shared.log("AniSkipService: Invalid URL: \(urlString)", type: "Error")
            return []
        }

        Logger.shared.log("AniSkipService: Fetching skip times for malId=\(malId) ep=\(episodeNumber) duration=\(formatSeconds(episodeDuration))", type: "AniSkip")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.shared.log("AniSkipService: Non-HTTP response", type: "Error")
            return []
        }

        guard httpResponse.statusCode == 200 else {
            Logger.shared.log("AniSkipService: HTTP \(httpResponse.statusCode) for malId=\(malId) ep=\(episodeNumber)", type: "AniSkip")
            return []
        }

        let decoded = try JSONDecoder().decode(AniSkipResponse.self, from: data)

        guard decoded.found, let results = decoded.results else {
            Logger.shared.log("AniSkipService: No skip times found for malId=\(malId) ep=\(episodeNumber)", type: "AniSkip")
            return []
        }

        let segments = results.compactMap { result -> SkipSegment? in
            let skipType: SkipType
            switch result.skipType {
            case "op", "mixed-op":
                skipType = .intro
            case "ed", "mixed-ed":
                skipType = .outro
            case "recap":
                skipType = .recap
            default:
                return nil
            }

            guard result.interval.startTime.isFinite, result.interval.endTime.isFinite else { return nil }
            let start = max(0, result.interval.startTime)
            let end = durationIsUsable ? min(episodeDuration, result.interval.endTime) : result.interval.endTime
            guard end > start else { return nil }

            return SkipSegment(startTime: start, endTime: end, type: skipType)
        }

        Logger.shared.log(
            "AniSkipService: Found \(segments.count) skip segments for malId=\(malId) ep=\(episodeNumber): "
            + segments.map { "\($0.type.rawValue) \(formatSeconds($0.startTime))-\(formatSeconds($0.endTime))s" }.joined(separator: ", "),
            type: "AniSkip"
        )

        return segments
    }

    static func episodeLengthParameter(for duration: Double) -> Int {
        guard duration > 0,
              let seconds = Int(exactly: duration.rounded(.towardZero)) else { return 0 }
        return seconds
    }

    private func formatSeconds(_ value: Double) -> String {
        guard value.isFinite else { return "nil" }
        let rounded = value.rounded()
        return Int(exactly: rounded).map(String.init) ?? String(rounded)
    }
}
