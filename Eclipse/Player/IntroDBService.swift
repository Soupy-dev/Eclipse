// Created on 28/02/26.

import Foundation

// MARK: - TheIntroDB API Response Models

private struct IntroDBResponse: Codable {
    let tmdb_id: Int?
    let type: String?
    let intro: [IntroDBSegment]?
    let recap: [IntroDBSegment]?
    let credits: [IntroDBSegment]?
    let preview: [IntroDBSegment]?
}

private struct IntroDBSegment: Codable {
    let start_ms: Int?
    let end_ms: Int?
    let confidence: Double?
    let submission_count: Int?
}

// MARK: - IntroDB.app API Response Models

private struct IntroDBAppResponse: Decodable {
    let imdbId: String?
    let season: Int?
    let episode: Int?
    let segments: IntroDBAppSegmentList?
    let intro: IntroDBAppSegmentList?
    let recap: IntroDBAppSegmentList?
    let outro: IntroDBAppSegmentList?
    let credits: IntroDBAppSegmentList?
    let preview: IntroDBAppSegmentList?

    enum CodingKeys: String, CodingKey {
        case imdbId = "imdb_id"
        case season
        case episode
        case segments
        case intro
        case recap
        case outro
        case credits
        case preview
    }

    init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([IntroDBAppSegment].self) {
            imdbId = nil
            season = nil
            episode = nil
            segments = IntroDBAppSegmentList(segments: list)
            intro = nil
            recap = nil
            outro = nil
            credits = nil
            preview = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        imdbId = try? container.decodeIfPresent(String.self, forKey: .imdbId)
        season = try? container.decodeIfPresent(Int.self, forKey: .season)
        episode = try? container.decodeIfPresent(Int.self, forKey: .episode)
        segments = try? container.decodeIfPresent(IntroDBAppSegmentList.self, forKey: .segments)
        intro = try? container.decodeIfPresent(IntroDBAppSegmentList.self, forKey: .intro)
        recap = try? container.decodeIfPresent(IntroDBAppSegmentList.self, forKey: .recap)
        outro = try? container.decodeIfPresent(IntroDBAppSegmentList.self, forKey: .outro)
        credits = try? container.decodeIfPresent(IntroDBAppSegmentList.self, forKey: .credits)
        preview = try? container.decodeIfPresent(IntroDBAppSegmentList.self, forKey: .preview)
    }
}

private struct IntroDBAppSegmentList: Decodable {
    let segments: [IntroDBAppSegment]

    init(segments: [IntroDBAppSegment]) {
        self.segments = segments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            segments = []
        } else if let list = try? container.decode([IntroDBAppSegment].self) {
            segments = list
        } else if let segment = try? container.decode(IntroDBAppSegment.self), segment.hasAnyTimestamp {
            segments = [segment]
        } else if let wrapper = try? container.decode(IntroDBAppSegmentWrapper.self) {
            segments = wrapper.segments
        } else {
            segments = []
        }
    }
}

private struct IntroDBAppSegmentWrapper: Decodable {
    let segments: [IntroDBAppSegment]

    enum CodingKeys: String, CodingKey {
        case segments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? container.decode([IntroDBAppSegment].self, forKey: .segments) {
            segments = list
        } else if let segment = try? container.decode(IntroDBAppSegment.self, forKey: .segments) {
            segments = segment.hasAnyTimestamp ? [segment] : []
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.segments,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing IntroDB segments wrapper")
            )
        }
    }
}

private struct IntroDBAppSegment: Decodable {
    let segmentType: String?
    let startSec: Double?
    let endSec: Double?
    let startMs: Int?
    let endMs: Int?
    let confidence: Double?
    let submissionCount: Int?

    enum CodingKeys: String, CodingKey {
        case segmentType = "segment_type"
        case type
        case startSec = "start_sec"
        case startSecCamel = "startSec"
        case endSec = "end_sec"
        case endSecCamel = "endSec"
        case startMs = "start_ms"
        case startMsCamel = "startMs"
        case endMs = "end_ms"
        case endMsCamel = "endMs"
        case confidence
        case submissionCount = "submission_count"
        case submissionCountCamel = "submissionCount"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segmentType = (try? container.decodeIfPresent(String.self, forKey: .segmentType))
            ?? (try? container.decodeIfPresent(String.self, forKey: .type))
        startSec = Self.decodeSeconds(from: container, keys: [.startSec, .startSecCamel])
        endSec = Self.decodeSeconds(from: container, keys: [.endSec, .endSecCamel])
        startMs = Self.decodeInteger(from: container, keys: [.startMs, .startMsCamel])
        endMs = Self.decodeInteger(from: container, keys: [.endMs, .endMsCamel])
        confidence = try? container.decodeIfPresent(Double.self, forKey: .confidence)
        submissionCount = Self.decodeInteger(from: container, keys: [.submissionCount, .submissionCountCamel])
    }

    var hasAnyTimestamp: Bool {
        startSec != nil || endSec != nil || startMs != nil || endMs != nil
    }

    var resolvedSkipType: SkipType? {
        guard let normalizedType = segmentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedType.isEmpty else {
            return nil
        }
        switch normalizedType {
        case "intro", "op", "opening":
            return .intro
        case "outro", "credits", "ed", "ending":
            return .outro
        case "recap":
            return .recap
        case "preview":
            return .preview
        default:
            return nil
        }
    }

    var debugSummary: String {
        [
            "type=\(segmentType ?? "nil")",
            "startSec=\(startSec.map(formatDebugNumber) ?? "nil")",
            "endSec=\(endSec.map(formatDebugNumber) ?? "nil")",
            "startMs=\(startMs.map(String.init) ?? "nil")",
            "endMs=\(endMs.map(String.init) ?? "nil")"
        ].joined(separator: " ")
    }

    private static func decodeSeconds(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Double? {
        for key in keys {
            if let value = decodeSeconds(from: container, key: key) {
                return value
            }
        }
        return nil
    }

    private static func decodeSeconds(from container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return parseClockOrSeconds(raw)
    }

    private static func decodeInteger(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int(value.rounded())
            }
            if let raw = try? container.decodeIfPresent(String.self, forKey: key),
               let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return Int(value.rounded())
            }
        }
        return nil
    }

    private static func parseClockOrSeconds(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = Double(trimmed) {
            return value
        }

        let parts = trimmed.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private func formatDebugNumber(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.3f", value)
    }
}

// MARK: - TheIntroDB Service

final class IntroDBService {
    static let shared = IntroDBService()

    private let baseURL = "https://api.theintrodb.org/v3"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    /// Fetches skip-time segments from TheIntroDB using TMDB ID.
    func fetchSkipTimes(tmdbId: Int, seasonNumber: Int?, episodeNumber: Int?, episodeDuration: Double) async throws -> [SkipSegment] {
        var urlString = "\(baseURL)/media?tmdb_id=\(tmdbId)"
        if let season = seasonNumber {
            urlString += "&season=\(season)"
        }
        if let episode = episodeNumber {
            urlString += "&episode=\(episode)"
        }
        let durationIsUsable = episodeDuration.isFinite && episodeDuration > 0
        if durationIsUsable {
            urlString += "&duration_ms=\(Int((episodeDuration * 1000).rounded()))"
        }

        guard let url = URL(string: urlString) else {
            Logger.shared.log("IntroDBService: Invalid URL: \(urlString)", type: "Error")
            return []
        }

        Logger.shared.log("IntroDBService: Fetching skip times for tmdbId=\(tmdbId) s=\(seasonNumber ?? -1) ep=\(episodeNumber ?? -1) duration=\(formatSeconds(episodeDuration))", type: "IntroDB")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.shared.log("IntroDBService: Non-HTTP response", type: "Error")
            return []
        }

        guard httpResponse.statusCode == 200 else {
            Logger.shared.log("IntroDBService: HTTP \(httpResponse.statusCode) for tmdbId=\(tmdbId)", type: "IntroDB")
            return []
        }

        let decoded = try JSONDecoder().decode(IntroDBResponse.self, from: data)

        var segments: [SkipSegment] = []
        let maxDuration = episodeDuration.isFinite && episodeDuration > 0 ? episodeDuration : nil

        // Parse intro segments
        if let intros = decoded.intro {
            for seg in intros {
                if let parsed = parseSegment(seg, type: .intro, maxDuration: maxDuration) {
                    segments.append(parsed)
                }
            }
        }

        // Parse recap segments
        if let recaps = decoded.recap {
            for seg in recaps {
                if let parsed = parseSegment(seg, type: .recap, maxDuration: maxDuration) {
                    segments.append(parsed)
                }
            }
        }

        // Parse credits to map to .outro (functionally equivalent - "Skip Outro")
        if let credits = decoded.credits {
            for seg in credits {
                if let parsed = parseSegment(seg, type: .outro, maxDuration: maxDuration) {
                    segments.append(parsed)
                }
            }
        }

        // Parse preview segments
        if let previews = decoded.preview {
            for seg in previews {
                if let parsed = parseSegment(seg, type: .preview, maxDuration: maxDuration) {
                    segments.append(parsed)
                }
            }
        }

        Logger.shared.log(
            "IntroDBService: Found \(segments.count) skip segments for tmdbId=\(tmdbId): "
            + segments.map { "\($0.type.rawValue) \(formatSeconds($0.startTime))-\(formatSeconds($0.endTime))s" }.joined(separator: ", "),
            type: "IntroDB"
        )

        return segments
    }

    /// Converts a TheIntroDB segment (milliseconds, nullable) into a SkipSegment (seconds).
    /// Intro/recap ranges may omit the start when they begin at 0, but need an end.
    /// Credits/preview ranges need a start and may omit the end when they run to media end.
    private func parseSegment(_ seg: IntroDBSegment, type: SkipType, maxDuration: Double?) -> SkipSegment? {
        let startSec: Double
        if let rawStart = seg.start_ms {
            startSec = Double(rawStart) / 1000.0
        } else if type.allowsMissingStart {
            startSec = 0
        } else {
            return nil
        }
        guard startSec.isFinite else { return nil }

        let endSec: Double
        if let rawEnd = seg.end_ms {
            endSec = Double(rawEnd) / 1000.0
        } else if type.allowsMissingEnd, let maxDuration {
            endSec = maxDuration
        } else {
            return nil
        }
        guard endSec.isFinite else { return nil }

        let clampedStart = max(0, startSec)
        let clampedEnd = maxDuration.map { min($0, endSec) } ?? endSec
        guard clampedEnd > clampedStart else { return nil }

        return SkipSegment(startTime: clampedStart, endTime: clampedEnd, type: type)
    }

    private func formatSeconds(_ value: Double) -> String {
        guard value.isFinite else { return "nil" }
        return "\(Int(value.rounded()))"
    }
}

// MARK: - IntroDB.app Service

final class IntroDBAppService {
    static let shared = IntroDBAppService()

    private let baseURL = URL(string: "https://api.introdb.app")!
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    /// Fetches skip-time segments from introdb.app using IMDb ID.
    /// No API key is required for read access.
    func fetchSkipTimes(imdbId: String, seasonNumber: Int?, episodeNumber: Int?, episodeDuration: Double) async throws -> [SkipSegment] {
        let cleanIMDbId = imdbId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIMDbId.isEmpty else { return [] }

        var components = URLComponents(url: baseURL.appendingPathComponent("segments"), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "imdb_id", value: cleanIMDbId)]
        if let seasonNumber {
            queryItems.append(URLQueryItem(name: "season", value: String(seasonNumber)))
        }
        if let episodeNumber {
            queryItems.append(URLQueryItem(name: "episode", value: String(episodeNumber)))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            Logger.shared.log("IntroDBAppService: Invalid URL for imdbId=\(cleanIMDbId)", type: "Error")
            return []
        }

        Logger.shared.log("IntroDBAppService: Fetching skip times for imdbId=\(cleanIMDbId) s=\(seasonNumber ?? -1) ep=\(episodeNumber ?? -1) duration=\(formatSeconds(episodeDuration))", type: "IntroDB")

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.shared.log("IntroDBAppService: Non-HTTP response", type: "Error")
            return []
        }

        guard httpResponse.statusCode == 200 else {
            Logger.shared.log("IntroDBAppService: HTTP \(httpResponse.statusCode) for imdbId=\(cleanIMDbId)", type: "IntroDB")
            return []
        }

        let decoded = try JSONDecoder().decode(IntroDBAppResponse.self, from: data)
        let maxDuration = episodeDuration.isFinite && episodeDuration > 0 ? episodeDuration : nil

        var segments: [SkipSegment] = []
        segments.append(contentsOf: parseTypedSegments(decoded.segments, maxDuration: maxDuration))
        segments.append(contentsOf: parseSegments(decoded.intro, type: .intro, maxDuration: maxDuration))
        segments.append(contentsOf: parseSegments(decoded.recap, type: .recap, maxDuration: maxDuration))
        segments.append(contentsOf: parseSegments(decoded.outro, type: .outro, maxDuration: maxDuration))
        segments.append(contentsOf: parseSegments(decoded.credits, type: .outro, maxDuration: maxDuration))
        segments.append(contentsOf: parseSegments(decoded.preview, type: .preview, maxDuration: maxDuration))

        Logger.shared.log(
            "IntroDBAppService: Found \(segments.count) skip segments for imdbId=\(cleanIMDbId): "
            + segments.map { "\($0.type.rawValue) \(formatSeconds($0.startTime))-\(formatSeconds($0.endTime))s" }.joined(separator: ", "),
            type: "IntroDB"
        )

        return dedupe(segments).sorted { $0.startTime < $1.startTime }
    }

    private func parseSegments(_ list: IntroDBAppSegmentList?, type: SkipType, maxDuration: Double?) -> [SkipSegment] {
        (list?.segments ?? []).enumerated().compactMap { index, segment in
            let parsed = parseSegment(segment, type: type, maxDuration: maxDuration)
            logParsedSegment(segment, parsed: parsed, label: type.rawValue, index: index)
            return parsed
        }
    }

    private func parseTypedSegments(_ list: IntroDBAppSegmentList?, maxDuration: Double?) -> [SkipSegment] {
        (list?.segments ?? []).enumerated().compactMap { index, segment in
            guard let type = segment.resolvedSkipType else {
                Logger.shared.log("IntroDBAppService: Dropped typed segment[\(index)] unknown type raw={\(segment.debugSummary)}", type: "IntroDB")
                return nil
            }
            let parsed = parseSegment(segment, type: type, maxDuration: maxDuration)
            logParsedSegment(segment, parsed: parsed, label: "typed-\(type.rawValue)", index: index)
            return parsed
        }
    }

    private func parseSegment(_ seg: IntroDBAppSegment, type: SkipType, maxDuration: Double?) -> SkipSegment? {
        let decodedStart = seg.startSec ?? seg.startMs.map { Double($0) / 1000.0 }
        let decodedEnd = seg.endSec ?? seg.endMs.map { Double($0) / 1000.0 }

        let startSec: Double
        if let decodedStart {
            startSec = decodedStart
        } else if type.allowsMissingStart {
            startSec = 0
        } else {
            return nil
        }
        guard startSec.isFinite else { return nil }

        let resolvedEnd: Double
        if let decodedEnd {
            resolvedEnd = decodedEnd
        } else if type.allowsMissingEnd, let maxDuration {
            resolvedEnd = maxDuration
        } else {
            return nil
        }
        guard resolvedEnd.isFinite else { return nil }

        let clampedStart = max(0, startSec)
        let clampedEnd = maxDuration.map { min($0, resolvedEnd) } ?? resolvedEnd
        guard clampedEnd > clampedStart else { return nil }

        return SkipSegment(startTime: clampedStart, endTime: clampedEnd, type: type)
    }

    private func logParsedSegment(_ raw: IntroDBAppSegment, parsed: SkipSegment?, label: String, index: Int) {
        let parsedText = parsed.map { "\($0.type.rawValue) \(formatSeconds($0.startTime))-\(formatSeconds($0.endTime))s" } ?? "nil"
        Logger.shared.log("IntroDBAppService: Parsed \(label)[\(index)] raw={\(raw.debugSummary)} -> \(parsedText)", type: "IntroDB")
    }

    private func dedupe(_ segments: [SkipSegment]) -> [SkipSegment] {
        var seen = Set<String>()
        return segments.filter { segment in
            let key = "\(segment.type.rawValue)-\(Int(segment.startTime.rounded()))-\(Int(segment.endTime.rounded()))"
            return seen.insert(key).inserted
        }
    }

    private func formatSeconds(_ value: Double) -> String {
        guard value.isFinite else { return "nil" }
        return "\(Int(value.rounded()))"
    }
}

private extension SkipType {
    var allowsMissingStart: Bool {
        switch self {
        case .intro, .recap:
            return true
        case .outro, .preview:
            return false
        }
    }

    var allowsMissingEnd: Bool {
        switch self {
        case .intro, .recap:
            return false
        case .outro, .preview:
            return true
        }
    }
}
