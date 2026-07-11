import Foundation

enum PlaybackSourceKind: String {
    case service
    case stremio
}

struct PlaybackLaunchContext {
    /// Stable identifier shared by stream resolution, player startup, proxy activity, retries,
    /// and Auto Mode fallback so one playback attempt can be reconstructed from the log.
    let traceID: String
    let traceCreatedAt: Date
    let sourceId: String
    let sourceName: String
    let sourceKind: PlaybackSourceKind
    let autoMode: Bool
    let streamURL: String
    let streamName: String?
    let headers: [String: String]
    let subtitles: [String]
    let subtitleNames: [String]?
    let subtitleHeadersByURL: [String: [String: String]]?
    let retryCount: Int
    let titleCandidates: [String]
    /// The service search-result/details URL passed to `extractEpisodes`.
    /// Service pre-staging needs this show-level URL; an individual episode URL cannot be used
    /// to refresh the episode list.
    let serviceContentHref: String?

    init(
        traceID: String = String(UUID().uuidString.prefix(8)),
        traceCreatedAt: Date = Date(),
        sourceId: String,
        sourceName: String,
        sourceKind: PlaybackSourceKind,
        autoMode: Bool,
        streamURL: String,
        streamName: String? = nil,
        headers: [String: String],
        subtitles: [String],
        subtitleNames: [String]?,
        subtitleHeadersByURL: [String: [String: String]]? = nil,
        retryCount: Int,
        titleCandidates: [String] = [],
        serviceContentHref: String? = nil
    ) {
        self.traceID = traceID
        self.traceCreatedAt = traceCreatedAt
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.autoMode = autoMode
        self.streamURL = streamURL
        self.streamName = streamName
        self.headers = headers
        self.subtitles = subtitles
        self.subtitleNames = subtitleNames
        self.subtitleHeadersByURL = subtitleHeadersByURL
        self.retryCount = retryCount
        self.titleCandidates = titleCandidates
        self.serviceContentHref = serviceContentHref
    }
}

struct PlaybackFailureReport {
    let context: PlaybackLaunchContext
    let message: String
    let isSourceFailure: Bool
}
