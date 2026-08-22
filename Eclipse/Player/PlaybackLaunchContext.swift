import Foundation

final class PlaybackProxySessionOwnership {
    final class Lease {
        private let lock = NSLock()
        private var ownership: PlaybackProxySessionOwnership?

        fileprivate init(ownership: PlaybackProxySessionOwnership) {
            self.ownership = ownership
        }

        func release() {
            lock.lock()
            let ownership = ownership
            self.ownership = nil
            lock.unlock()
            ownership?.releaseLease()
        }

        deinit {
            release()
        }
    }

    private let lock = NSLock()
    private let proxyURLs: [URL]
    private let invalidator: (URL) -> Void
    private var activeLeaseCount = 0
    private var hasEverBeenLeased = false
    private var didInvalidate = false

    convenience init(proxyURLs: [URL]) {
        self.init(proxyURLs: proxyURLs) { proxyURL in
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
        }
    }

    init(proxyURLs: [URL], invalidator: @escaping (URL) -> Void) {
        var seen = Set<URL>()
        self.proxyURLs = proxyURLs.filter { seen.insert($0).inserted }
        self.invalidator = invalidator
    }

    func acquireLease() -> Lease? {
        lock.lock()
        guard !didInvalidate, !proxyURLs.isEmpty else {
            lock.unlock()
            return nil
        }
        activeLeaseCount += 1
        hasEverBeenLeased = true
        lock.unlock()
        return Lease(ownership: self)
    }

    func invalidate() {
        if let work = invalidationWorkIfNeeded(force: true) {
            work.urls.forEach(work.invalidator)
        }
    }

    var isInvalidated: Bool {
        lock.lock()
        let value = didInvalidate
        lock.unlock()
        return value
    }

    private func releaseLease() {
        lock.lock()
        if activeLeaseCount > 0 {
            activeLeaseCount -= 1
        }
        let shouldInvalidate = hasEverBeenLeased && activeLeaseCount == 0
        let work = invalidationWorkIfNeededWhileLocked(force: shouldInvalidate)
        lock.unlock()
        if let work {
            work.urls.forEach(work.invalidator)
        }
    }

    private func invalidationWorkIfNeeded(
        force: Bool
    ) -> (urls: [URL], invalidator: (URL) -> Void)? {
        lock.lock()
        let work = invalidationWorkIfNeededWhileLocked(force: force)
        lock.unlock()
        return work
    }

    private func invalidationWorkIfNeededWhileLocked(
        force: Bool
    ) -> (urls: [URL], invalidator: (URL) -> Void)? {
        guard force, !didInvalidate else { return nil }
        didInvalidate = true
        return (proxyURLs, invalidator)
    }

    deinit {
        invalidate()
    }
}

enum PlaybackSourceKind: String {
    case service
    case stremio
    case skyStream
    case nuvio
}

struct PlaybackLaunchContext {

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
    let headersDroppedBySanitizer: [String]?
    let retryCount: Int
    let titleCandidates: [String]

    let serviceContentHref: String?

    let providerContentReference: ProviderContentReference?

    // Runtime-only ownership for short-lived loopback transports. Playback launch
    // contexts are deliberately not Codable, so these capability URLs cannot be
    // persisted with media state or provider references.
    let ephemeralProxyOwnership: PlaybackProxySessionOwnership?

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
        headersDroppedBySanitizer: [String]? = nil,
        retryCount: Int,
        titleCandidates: [String] = [],
        serviceContentHref: String? = nil,
        providerContentReference: ProviderContentReference? = nil,
        ephemeralProxyOwnership: PlaybackProxySessionOwnership? = nil
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
        self.headersDroppedBySanitizer = headersDroppedBySanitizer
        self.retryCount = retryCount
        self.titleCandidates = titleCandidates
        self.serviceContentHref = serviceContentHref
        self.providerContentReference = providerContentReference
        self.ephemeralProxyOwnership = ephemeralProxyOwnership
    }
}

struct PlaybackFailureReport {
    let context: PlaybackLaunchContext
    let message: String
    let isSourceFailure: Bool
}
