import Foundation
import CryptoKit

#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
#endif

public struct SkyStreamResolutionTarget: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case movie
        case episode
    }

    public var kind: Kind
    public var title: String
    public var aliases: [String]
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var absoluteEpisodeCandidates: [Int]
    public var isAnime: Bool
    public var isSpecial: Bool
    public var wantsDubbed: Bool?
    public var requiresExactIdentity: Bool

    public init(
        kind: Kind,
        title: String,
        aliases: [String] = [],
        year: Int? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        absoluteEpisodeCandidates: [Int] = [],
        isAnime: Bool = false,
        isSpecial: Bool = false,
        wantsDubbed: Bool? = nil,
        requiresExactIdentity: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.aliases = aliases
        self.year = year
        self.season = season
        self.episode = episode
        self.absoluteEpisodeCandidates = absoluteEpisodeCandidates
        self.isAnime = isAnime
        self.isSpecial = isSpecial
        self.wantsDubbed = wantsDubbed
        self.requiresExactIdentity = requiresExactIdentity
    }
}

public enum SkyStreamResolutionMode: Sendable, Hashable {
    case manual
    /// Low-latency first row for the manual picker. Unlike Auto Mode, this never skips a source
    /// merely because its health backoff is active; the full manual pass can expand it later.
    case manualFast
    case autoMode
    case playbackRefresh
    case downloadRefresh

    fileprivate var maximumLoadedCandidates: Int {
        switch self {
        // The full picker may backfill through the same 80-result ceiling used by Services and
        // Stremio. This remains deadline-bound, so a slow provider cannot turn the larger pool
        // into unbounded foreground work. Fast/automatic paths still inspect only their first
        // ranked match.
        case .manual: return 80
        case .manualFast, .autoMode, .playbackRefresh, .downloadRefresh: return 1
        }
    }

    fileprivate var maximumVODProbes: Int {
        switch self {
        case .manual: return 24
        case .manualFast, .autoMode, .playbackRefresh, .downloadRefresh: return 12
        }
    }

    fileprivate var maximumSearchQueries: Int {
        switch self {
        case .manual: return 8
        case .manualFast, .autoMode: return 4
        case .playbackRefresh, .downloadRefresh: return 1
        }
    }

    /// Expiry recovery must execute the provider and VOD preflight again. Reusing any layer of
    /// the normal picker cache can simply hand the caller the same expired URL, cookie, or
    /// manifest graph that triggered recovery.
    fileprivate var bypassesResolutionCaches: Bool {
        switch self {
        case .playbackRefresh, .downloadRefresh: return true
        case .manual, .manualFast, .autoMode: return false
        }
    }

    fileprivate var foregroundResolutionBudget: TimeInterval {
        switch self {
        case .manual: return 30
        case .manualFast: return 12
        case .autoMode: return 18
        case .playbackRefresh, .downloadRefresh: return 20
        }
    }
}

public enum SkyStreamResolutionPurpose: Sendable, Hashable {
    case playback
    case offlineDownload
}

public struct SkyStreamResolvedStream: Sendable, Hashable, Identifiable {
    public var provider: SkyStreamProviderDescriptor
    public var searchRecord: SkyStreamSearchRecord
    public var loadedItem: SkyStreamLoadedItemRecord
    public var episodeRecord: SkyStreamEpisodeRecord?
    public var streamRecord: SkyStreamStreamRecord
    public var playback: SkyStreamValidatedPlaybackDescriptor
    public var contentReference: SkyStreamProviderContentReference

    public var id: String {
        [provider.id, loadedItem.url, episodeRecord?.url ?? "", streamRecord.id]
            .joined(separator: "|")
    }

    public var displayName: String {
        let labels = [
            streamRecord.source,
            streamRecord.name,
            streamRecord.qualityLabel,
            streamRecord.quality.map { "\($0)p" }
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return labels.isEmpty ? provider.displayName : labels.joined(separator: " • ")
    }
}

public enum SkyStreamResolverError: Error, Sendable, Equatable {
    case unavailable
    case providerNotFound
    case providerDisabled
    case unhealthySourceSkipped
    case noConfidentMatch
    case episodeNotFound
    case noVODStreams
    case staleContentReference
    case resolutionTimedOut
}

extension SkyStreamResolverError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "SkyStream resolution is available only on iPhone and iPad."
        case .providerNotFound: return "The SkyStream provider is no longer installed."
        case .providerDisabled: return "The SkyStream provider is disabled."
        case .unhealthySourceSkipped: return "Auto Mode skipped this recently unhealthy source."
        case .noConfidentMatch: return "The provider did not return a confident title match."
        case .episodeNotFound: return "The provider did not return the requested explicit episode."
        case .noVODStreams: return "The provider returned no verified VOD streams."
        case .staleContentReference: return "The saved provider reference belongs to a different content identity."
        case .resolutionTimedOut: return "The SkyStream source took too long to finish resolving."
        }
    }
}

private final class SkyStreamResolverDeadlineCoordinator<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var result: Result<Value, Error>?
    private var isCancelled = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        if isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func installTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        lock.lock()
        operationTask = operation
        timeoutTask = timeout
        let cancelImmediately = result != nil || isCancelled
        lock.unlock()
        if cancelImmediately {
            operation.cancel()
            timeout.cancel()
        }
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard self.result == nil, !isCancelled else {
            lock.unlock()
            return false
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        lock.unlock()
        continuation?.resume(with: result)
        operationTask?.cancel()
        timeoutTask?.cancel()
        return true
    }

    func cancel() {
        lock.lock()
        guard result == nil, !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        operationTask?.cancel()
        timeoutTask?.cancel()
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)

@MainActor
public final class SkyStreamResolver {
    public static let shared = SkyStreamResolver()

    private struct TimedValue<Value> {
        var value: Value
        var expiresAt: Date
    }

    private let pluginManager: SkyStreamPluginManager
    private let runtime: SkyStreamRuntimePool
    private let vodValidator: SkyStreamVODValidator
    private var searchCache: [String: TimedValue<[SkyStreamSearchRecord]>] = [:]
    private var loadCache: [String: TimedValue<SkyStreamLoadedItemRecord>] = [:]
    private var streamCache: [String: TimedValue<[SkyStreamStreamRecord]>] = [:]
    private var runtimePersistenceTasks: [String: Task<Void, Never>] = [:]
    private let maximumSearchCacheEntries = 64
    private let maximumLoadCacheEntries = 48
    private let maximumStreamCacheEntries = 32

    public init(
        pluginManager: SkyStreamPluginManager? = nil,
        runtime: SkyStreamRuntimePool = .shared,
        vodValidator: SkyStreamVODValidator = .shared
    ) {
        self.pluginManager = pluginManager ?? .shared
        self.runtime = runtime
        self.vodValidator = vodValidator
    }

    public func resolve(
        sourceID: String,
        target: SkyStreamResolutionTarget,
        mode: SkyStreamResolutionMode,
        preferredStreamLabel: String? = nil,
        purpose: SkyStreamResolutionPurpose = .playback,
        originalAudioLanguage: String? = nil
    ) async throws -> [SkyStreamResolvedStream] {
        try await withResolutionDeadline(mode: mode) { [self] in
            try await resolveWithoutDeadline(
                sourceID: sourceID,
                target: target,
                mode: mode,
                preferredStreamLabel: preferredStreamLabel,
                purpose: purpose,
                originalAudioLanguage: originalAudioLanguage
            )
        }
    }

    private func resolveWithoutDeadline(
        sourceID: String,
        target: SkyStreamResolutionTarget,
        mode: SkyStreamResolutionMode,
        preferredStreamLabel: String?,
        purpose: SkyStreamResolutionPurpose,
        originalAudioLanguage: String?
    ) async throws -> [SkyStreamResolvedStream] {
        pruneCaches()
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamResolverError.unavailable
        }
        guard let authority = pluginManager.runtimeAuthoritySnapshot(sourceID: sourceID) else {
            throw SkyStreamResolverError.providerNotFound
        }
        let provider = authority.provider
        let plugin = authority.plugin
        guard provider.isEnabled else { throw SkyStreamResolverError.providerDisabled }
        if mode == .autoMode,
           SourceHealthStore.shared.shouldSkipForAutoMode(sourceId: sourceID) {
            throw SkyStreamResolverError.unhealthySourceSkipped
        }

        let configuration = try runtimeConfiguration(
            plugin: plugin,
            provider: provider,
            authorityRevision: authority.revision
        )
        let hits: [SkyStreamSearchRecord]
        do {
            hits = try await rankedSearchHits(
                configuration: configuration,
                provider: provider,
                target: target,
                mode: mode
            )
        } catch {
            try Self.rethrowIfCancelled(error)
            recordOperationalFailure(error, provider: provider)
            throw error
        }
        guard !hits.isEmpty else { throw SkyStreamResolverError.noConfidentMatch }

        var lastOperationalError: Error?
        var didLoadCandidate = false
        for hit in hits.prefix(mode.maximumLoadedCandidates) {
            try Task.checkCancellation()
            let loaded: SkyStreamLoadedItemRecord
            do {
                loaded = try await load(
                    hit.url,
                    configuration: configuration,
                    bypassCache: mode.bypassesResolutionCaches
                )
                didLoadCandidate = true
            } catch {
                try Self.rethrowIfCancelled(error)
                lastOperationalError = error
                continue
            }
            guard Self.matchesMediaGuards(loaded, target: target) else { continue }
            let selectedEpisode: SkyStreamEpisodeRecord?
            switch target.kind {
            case .movie:
                selectedEpisode = nil
            case .episode:
                selectedEpisode = Self.selectExplicitEpisode(from: loaded.episodes, target: target)
                guard selectedEpisode != nil else { continue }
            }

            var streams = selectedEpisode?.streams ?? loaded.streams
            if streams.isEmpty { streams = hit.streams }
            if streams.isEmpty {
                let episodeURL = selectedEpisode?.url.trimmingCharacters(in: .whitespacesAndNewlines)
                let streamURL = episodeURL?.isEmpty == false ? episodeURL! : loaded.url
                do {
                    streams = try await loadStreams(
                        streamURL,
                        configuration: configuration,
                        bypassCache: mode.bypassesResolutionCaches
                    )
                } catch {
                    try Self.rethrowIfCancelled(error)
                    lastOperationalError = error
                    continue
                }
            }
            streams = Self.rankedAndDeduplicatedStreams(
                streams,
                preferredStreamLabel: preferredStreamLabel
            )
            streams = streams.filter {
                Self.streamPassesConfiguredRules(
                    $0,
                    loaded: loaded,
                    episode: selectedEpisode,
                    sourceID: sourceID,
                    target: target,
                    originalAudioLanguage: originalAudioLanguage
                )
            }
            let accepted = try await validateStreams(
                Array(streams.prefix(mode.maximumVODProbes)),
                plugin: plugin,
                provider: provider,
                hit: hit,
                loaded: loaded,
                selectedEpisode: selectedEpisode,
                target: target,
                mode: mode,
                purpose: purpose,
                authorityRevision: authority.revision
            )
            if !accepted.isEmpty {
                try ensureProviderStillCurrent(
                    initialProvider: provider,
                    initialPlugin: plugin,
                    initialAuthorityRevision: authority.revision
                )
                SourceHealthStore.shared.recordEndpoint(
                    sourceId: sourceID,
                    sourceName: provider.displayName,
                    status: .healthy,
                    reason: nil
                )
                // Commit package-scoped storage only after a complete successful resolution.
                // Failed/cancelled ABI calls may have mutated their temporary runtime store and
                // must not turn that partial state into durable user data.
                scheduleRuntimeSnapshotPersistence(for: plugin)
                return accepted
            }
        }
        if !didLoadCandidate, let lastOperationalError {
            recordOperationalFailure(lastOperationalError, provider: provider)
            throw lastOperationalError
        }
        throw target.kind == .episode
            ? SkyStreamResolverError.episodeNotFound
            : SkyStreamResolverError.noVODStreams
    }

    public func refresh(
        _ reference: SkyStreamProviderContentReference,
        mode: SkyStreamResolutionMode = .playbackRefresh
    ) async throws -> [SkyStreamResolvedStream] {
        try await withResolutionDeadline(mode: mode) { [self] in
            try await refreshWithoutDeadline(reference, mode: mode)
        }
    }

    private func refreshWithoutDeadline(
        _ reference: SkyStreamProviderContentReference,
        mode: SkyStreamResolutionMode
    ) async throws -> [SkyStreamResolvedStream] {
        pruneCaches()
        guard reference.isStructurallyValid else {
            throw SkyStreamResolverError.staleContentReference
        }
        let sourceID = reference.sourceID
        guard let authority = pluginManager.runtimeAuthoritySnapshot(sourceID: sourceID),
              authority.plugin.id == reference.packageName else {
            throw SkyStreamResolverError.providerNotFound
        }
        let provider = authority.provider
        let plugin = authority.plugin
        if let expectedHash = reference.scriptSHA256,
           expectedHash.caseInsensitiveCompare(plugin.scriptSHA256) != .orderedSame {
            throw SkyStreamResolverError.staleContentReference
        }
        if let expectedVersion = reference.pluginVersion,
           expectedVersion != plugin.manifest.version {
            throw SkyStreamResolverError.staleContentReference
        }
        guard provider.isEnabled else { throw SkyStreamResolverError.providerDisabled }
        guard let title = reference.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw SkyStreamResolverError.staleContentReference
        }
        let target = SkyStreamResolutionTarget(
            kind: reference.season != nil || reference.episode != nil ? .episode : .movie,
            title: title,
            year: reference.year,
            season: reference.season,
            episode: reference.episode,
            requiresExactIdentity: true
        )

        if !reference.loadedItemURL.isEmpty {
            do {
                return try await refreshUsingStoredProviderURLs(
                    reference,
                    plugin: plugin,
                    provider: provider,
                    authorityRevision: authority.revision,
                    target: target,
                    mode: mode
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch SkyStreamResolverError.staleContentReference {
                throw SkyStreamResolverError.staleContentReference
            } catch {
                // Provider item identifiers can expire or disappear independently of stream
                // URLs. Fall back to one exact search instead of failing refresh outright.
            }
        }
        return try await resolveWithoutDeadline(
            sourceID: sourceID,
            target: target,
            mode: mode,
            preferredStreamLabel: reference.preferredStreamLabel,
            purpose: mode == .downloadRefresh ? .offlineDownload : .playback,
            originalAudioLanguage: nil
        )
    }

    /// Fast refresh path for the bounded, device-local provider identifiers retained by a
    /// content reference. It still re-executes `load`/`loadStreams`, current settings filters,
    /// payload identity checks, and the complete VOD validator; no previously playable URL is
    /// trusted or handed directly to playback.
    private func refreshUsingStoredProviderURLs(
        _ reference: SkyStreamProviderContentReference,
        plugin: SkyStreamInstalledPluginState,
        provider: SkyStreamProviderDescriptor,
        authorityRevision: UUID,
        target: SkyStreamResolutionTarget,
        mode: SkyStreamResolutionMode
    ) async throws -> [SkyStreamResolvedStream] {
        try Task.checkCancellation()
        let configuration = try runtimeConfiguration(
            plugin: plugin,
            provider: provider,
            authorityRevision: authorityRevision
        )
        let loaded = try await load(
            reference.loadedItemURL,
            configuration: configuration,
            bypassCache: true
        )
        guard Self.matchesMediaGuards(loaded, target: target) else {
            throw SkyStreamResolverError.staleContentReference
        }

        let selectedEpisode: SkyStreamEpisodeRecord?
        switch target.kind {
        case .movie:
            selectedEpisode = nil
        case .episode:
            selectedEpisode = Self.selectExplicitEpisode(
                from: loaded.episodes,
                target: target,
                preferredURL: reference.selectedEpisodeURL
            )
            guard selectedEpisode != nil else {
                throw SkyStreamResolverError.episodeNotFound
            }
        }

        var streams = selectedEpisode?.streams ?? loaded.streams
        if streams.isEmpty {
            let episodeURL = selectedEpisode?.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let streamURL = episodeURL?.isEmpty == false ? episodeURL! : loaded.url
            streams = try await loadStreams(
                streamURL,
                configuration: configuration,
                bypassCache: true
            )
        }
        streams = Self.rankedAndDeduplicatedStreams(
            streams,
            preferredStreamLabel: reference.preferredStreamLabel
        ).filter {
            Self.streamPassesConfiguredRules(
                $0,
                loaded: loaded,
                episode: selectedEpisode,
                sourceID: provider.id,
                target: target,
                originalAudioLanguage: nil
            )
        }

        let syntheticHit = SkyStreamSearchRecord(
            title: loaded.title,
            url: reference.loadedItemURL,
            posterURL: loaded.posterURL,
            contentType: loaded.contentType,
            year: loaded.year,
            score: loaded.score,
            durationMinutes: loaded.durationMinutes,
            status: loaded.status,
            description: loaded.description,
            providerName: loaded.providerName,
            alternateTitles: loaded.alternateTitles,
            headers: loaded.headers,
            syncData: loaded.syncData,
            streams: loaded.streams,
            additionalFields: loaded.additionalFields
        )
        let accepted = try await validateStreams(
            Array(streams.prefix(mode.maximumVODProbes)),
            plugin: plugin,
            provider: provider,
            hit: syntheticHit,
            loaded: loaded,
            selectedEpisode: selectedEpisode,
            target: target,
            mode: mode,
            purpose: mode == .downloadRefresh ? .offlineDownload : .playback,
            authorityRevision: authorityRevision
        )
        guard !accepted.isEmpty else {
            throw target.kind == .episode
                ? SkyStreamResolverError.episodeNotFound
                : SkyStreamResolverError.noVODStreams
        }
        try ensureProviderStillCurrent(
            initialProvider: provider,
            initialPlugin: plugin,
            initialAuthorityRevision: authorityRevision
        )
        SourceHealthStore.shared.recordEndpoint(
            sourceId: provider.id,
            sourceName: provider.displayName,
            status: .healthy,
            reason: nil
        )
        scheduleRuntimeSnapshotPersistence(for: plugin)
        return accepted
    }

    public func cancel(packageName: String, providerID: String?) async {
        await runtime.cancel(packageName: packageName, providerID: providerID)
    }

    private func withResolutionDeadline<Value: Sendable>(
        mode: SkyStreamResolutionMode,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let coordinator = SkyStreamResolverDeadlineCoordinator<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                coordinator.install(continuation)
                let operationTask = Task { @MainActor in
                    do {
                        coordinator.resolve(.success(try await operation()))
                    } catch {
                        coordinator.resolve(.failure(error))
                    }
                }
                let timeoutTask = Task {
                    do {
                        var remaining = mode.foregroundResolutionBudget
                        while remaining > 0 {
                            try await Task.sleep(nanoseconds: 100_000_000)
                            if UIApplication.shared.applicationState == .active {
                                remaining -= 0.1
                            }
                        }
                        coordinator.resolve(.failure(SkyStreamResolverError.resolutionTimedOut))
                    } catch {
                        // The operation or caller already won the race.
                    }
                }
                coordinator.installTasks(operation: operationTask, timeout: timeoutTask)
            }
        } onCancel: {
            coordinator.cancel()
        }
    }

    private func recordOperationalFailure(
        _ error: Error,
        provider: SkyStreamProviderDescriptor
    ) {
        let endpointReason: String?
        switch error {
        case let runtime as SkyStreamRuntimeError:
            switch runtime {
            case .operationTimedOut:
                endpointReason = "Provider resolution timed out"
            case .scriptMissing, .scriptIntegrityMismatch, .scriptEvaluationFailed, .missingExport:
                endpointReason = "Installed provider failed its runtime integrity check"
            default:
                endpointReason = nil
            }
        case let security as SkyStreamSecurityError:
            switch security {
            case .dnsResolutionFailed, .dnsReturnedNoAddresses, .invalidResponse, .tooManyRedirects:
                endpointReason = "Provider network request failed"
            default:
                endpointReason = nil
            }
        default:
            endpointReason = nil
        }

        if let endpointReason {
            SourceHealthStore.shared.recordEndpoint(
                sourceId: provider.id,
                sourceName: provider.displayName,
                status: .unhealthy,
                reason: endpointReason
            )
        } else {
            SourceHealthStore.shared.recordPlaybackFailure(
                sourceId: provider.id,
                sourceName: provider.displayName,
                reason: "Provider resolution failed",
                isSourceFailure: true
            )
        }
    }

    private static func rethrowIfCancelled(_ error: Error) throws {
        if Task.isCancelled
            || error is CancellationError
            || (error as? SkyStreamRuntimeError) == .cancelled
            || (error as? SkyStreamSecurityError) == .cancelled {
            throw CancellationError()
        }
    }

    private func rankedSearchHits(
        configuration: SkyStreamRuntimeConfiguration,
        provider: SkyStreamProviderDescriptor,
        target: SkyStreamResolutionTarget,
        mode: SkyStreamResolutionMode
    ) async throws -> [SkyStreamSearchRecord] {
        var hits: [SkyStreamSearchRecord] = []
        var seen = Set<String>()
        let ladder = Self.queryLadder(for: target)
        var queries = Array(ladder.prefix(mode.maximumSearchQueries))
        if !queries.contains(where: { $0.caseInsensitiveCompare(target.title) == .orderedSame }) {
            queries.append(target.title)
        }
        for query in queries.prefix(mode.maximumSearchQueries) {
            try Task.checkCancellation()
            let cacheKey = [provider.id, configuration.fingerprint, query.lowercased()]
                .joined(separator: "|")
            let values: [SkyStreamSearchRecord]
            if !mode.bypassesResolutionCaches,
               let cached = searchCache[cacheKey], cached.expiresAt > Date() {
                values = cached.value
            } else {
                values = try await runtime.search(using: configuration, query: query)
                searchCache[cacheKey] = TimedValue(
                    value: Array(values.prefix(300)),
                    expiresAt: Date().addingTimeInterval(120)
                )
                pruneCaches()
            }
            for value in values where seen.insert(value.url).inserted {
                hits.append(value)
                if hits.count == 300 { break }
            }
            if hits.contains(where: {
                Self.matchesMediaGuards($0, target: target)
                    && Self.matchScore($0, target: target) >= 0.98
            }) {
                break
            }
            if hits.count == 300 { break }
        }

        return hits
            .filter { Self.matchesMediaGuards($0, target: target) }
            .map { ($0, Self.matchScore($0, target: target)) }
            .filter {
                Self.acceptsTitleMatch(
                    score: $0.1,
                    requiresExactIdentity: target.requiresExactIdentity
                )
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return ($0.0.score ?? 0) > ($1.0.score ?? 0)
            }
            .map { $0.0 }
    }

    private func load(
        _ url: String,
        configuration: SkyStreamRuntimeConfiguration,
        bypassCache: Bool = false
    ) async throws -> SkyStreamLoadedItemRecord {
        let key = [
            SkyStreamStableID.sourceID(
                packageName: configuration.manifest.packageName,
                providerID: configuration.providerID
            ),
            configuration.fingerprint,
            url
        ]
            .joined(separator: "|")
        if !bypassCache, let cached = loadCache[key], cached.expiresAt > Date() {
            return cached.value
        }
        let loaded = try await runtime.load(using: configuration, url: url)
        loadCache[key] = TimedValue(value: loaded, expiresAt: Date().addingTimeInterval(120))
        pruneCaches()
        return loaded
    }

    private func loadStreams(
        _ url: String,
        configuration: SkyStreamRuntimeConfiguration,
        bypassCache: Bool = false
    ) async throws -> [SkyStreamStreamRecord] {
        let key = [
            SkyStreamStableID.sourceID(
                packageName: configuration.manifest.packageName,
                providerID: configuration.providerID
            ),
            configuration.fingerprint,
            url
        ]
            .joined(separator: "|")
        if !bypassCache, let cached = streamCache[key], cached.expiresAt > Date() {
            return cached.value
        }
        let streams = try await runtime.loadStreams(using: configuration, url: url)
        streamCache[key] = TimedValue(
            value: Array(streams.prefix(1_200)),
            expiresAt: Date().addingTimeInterval(45)
        )
        pruneCaches()
        return streams
    }

    private func validateStreams(
        _ streams: [SkyStreamStreamRecord],
        plugin: SkyStreamInstalledPluginState,
        provider: SkyStreamProviderDescriptor,
        hit: SkyStreamSearchRecord,
        loaded: SkyStreamLoadedItemRecord,
        selectedEpisode: SkyStreamEpisodeRecord?,
        target: SkyStreamResolutionTarget,
        mode: SkyStreamResolutionMode,
        purpose: SkyStreamResolutionPurpose,
        authorityRevision: UUID
    ) async throws -> [SkyStreamResolvedStream] {
        guard !streams.isEmpty else { return [] }
        let identity = SkyStreamVODValidationIdentity(
            packageID: plugin.id,
            providerID: provider.providerID ?? "root",
            payloadSHA256: plugin.scriptSHA256,
            generation: Self.generation(plugin),
            authorityRevision: authorityRevision
        )
        let candidates = streams.map { stream in
            (stream, Self.rawCandidate(
                stream,
                loaded: loaded,
                episode: selectedEpisode
            ))
        }

        var acceptedByID: [String: SkyStreamValidatedPlaybackDescriptor] = [:]
        if mode == .manual {
            // VOD probes are intentionally only two-wide. This gives the manual picker
            // progressive speed without letting one provider starve playback refresh work.
            for start in stride(from: 0, to: candidates.count, by: 2) {
                try Task.checkCancellation()
                let batch = Array(candidates[start..<min(start + 2, candidates.count)])
                var validationWasCancelled = false
                await withTaskGroup(
                    of: (String, SkyStreamValidatedPlaybackDescriptor?, Bool).self
                ) { group in
                    for pair in batch {
                        group.addTask { [vodValidator] in
                            do {
                                let value = try await vodValidator.validate(
                                    pair.1,
                                    identity: identity,
                                    bypassCache: mode.bypassesResolutionCaches
                                )
                                guard Self.descriptor(value, isUsableFor: purpose) else {
                                    return (pair.0.id, nil, false)
                                }
                                return (pair.0.id, value, false)
                            } catch is CancellationError {
                                return (pair.0.id, nil, true)
                            } catch {
                                return (pair.0.id, nil, false)
                            }
                        }
                    }
                    for await value in group {
                        if value.2 {
                            validationWasCancelled = true
                            group.cancelAll()
                        } else if let descriptor = value.1 {
                            acceptedByID[value.0] = descriptor
                        }
                    }
                }
                if validationWasCancelled || Task.isCancelled { throw CancellationError() }
                if acceptedByID.count >= 8 { break }
            }
        } else {
            for pair in candidates {
                try Task.checkCancellation()
                do {
                    let descriptor = try await vodValidator.validate(
                        pair.1,
                        identity: identity,
                        bypassCache: mode.bypassesResolutionCaches
                    )
                    guard Self.descriptor(descriptor, isUsableFor: purpose) else { continue }
                    acceptedByID[pair.0.id] = descriptor
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
        }

        return streams.compactMap { stream in
            guard let playback = acceptedByID[stream.id] else { return nil }
            let reference = SkyStreamProviderContentReference(
                packageName: plugin.id,
                providerID: provider.providerID,
                scriptSHA256: plugin.scriptSHA256,
                pluginVersion: plugin.manifest.version,
                loadedItemURL: loaded.url,
                selectedEpisodeURL: selectedEpisode?.url,
                season: selectedEpisode?.season ?? target.season,
                episode: selectedEpisode?.episode ?? target.episode,
                preferredStreamLabel: Self.streamLabel(stream),
                contentType: loaded.contentType ?? hit.contentType,
                title: loaded.title.isEmpty ? hit.title : loaded.title,
                year: loaded.year ?? hit.year
            )
            return SkyStreamResolvedStream(
                provider: provider,
                searchRecord: hit,
                loadedItem: loaded,
                episodeRecord: selectedEpisode,
                streamRecord: stream,
                playback: playback,
                contentReference: reference
            )
        }
    }

    private func runtimeConfiguration(
        plugin: SkyStreamInstalledPluginState,
        provider: SkyStreamProviderDescriptor,
        authorityRevision: UUID
    ) throws -> SkyStreamRuntimeConfiguration {
        let scriptURL = try pluginManager.runtimeScriptURL(for: plugin)
        let providerManifest = plugin.manifest.providers?.first(where: {
            $0.id == provider.providerID
        })
        let baseURL = provider.selectedDomainURL
            ?? providerManifest?.baseURL
            ?? plugin.manifest.baseURL
        var runtimeManifest = plugin.manifest
        if plugin.usesDynamicProviders == true {
            // Discovered providers are persisted for Eclipse's stable source rows, but the
            // package bootstrap manifest remains the original empty-provider declaration.
            runtimeManifest.providers = []
        }
        let store = SkyStreamRuntimeDataStore(
            snapshot: .init(
                storage: plugin.runtimeStorage ?? [:],
                preferences: plugin.preferences.mapValues(\.value)
            )
        )
        struct RuntimePreferenceFingerprintValue: Encodable {
            let key: String
            let value: SkyStreamJSONValue
            let isSecret: Bool
            let isRedacted: Bool
        }
        // Fingerprint exactly the bounded preference values the runtime can observe, plus their
        // trust classification. `updatedAt` is synchronization metadata and must not create fresh
        // contexts or evade a quarantine when behavior is otherwise unchanged.
        let effectivePreferences = store.snapshot().preferences
        let fingerprintPreferences: [RuntimePreferenceFingerprintValue] = effectivePreferences
            .keys.sorted().compactMap { key -> RuntimePreferenceFingerprintValue? in
            guard let value = effectivePreferences[key], let metadata = plugin.preferences[key] else {
                return nil
            }
            return RuntimePreferenceFingerprintValue(
                key: key,
                value: value,
                isSecret: metadata.isSecret,
                isRedacted: metadata.isRedacted
            )
            }
        let preferenceEncoder = JSONEncoder()
        preferenceEncoder.outputFormatting = [.sortedKeys]
        let preferenceData = try preferenceEncoder.encode(fingerprintPreferences)
        let provenance = plugin.provenance
        let behavioralOwnerURL: String?
        let behavioralSourceURL: String?
        switch provenance.kind {
        case .repository:
            behavioralOwnerURL = provenance.repositoryURL ?? provenance.sourceURL
            behavioralSourceURL = nil
        case .directArchive:
            behavioralOwnerURL = provenance.sourceURL
            behavioralSourceURL = provenance.sourceURL
        case .backup:
            behavioralOwnerURL = provenance.repositoryURL ?? provenance.sourceURL
            behavioralSourceURL = provenance.sourceURL
        }
        let trustIdentity = [
            provenance.kind.rawValue,
            Self.canonicalTrustURL(behavioralOwnerURL) ?? "",
            Self.canonicalTrustURL(behavioralSourceURL) ?? "",
            Self.canonicalTrustURL(provenance.pluginListURL) ?? "",
            provenance.repositoryPackageName ?? ""
        ].joined(separator: "\u{1f}")
        var trustConfigurationData = Data()
        trustConfigurationData.append(preferenceData)
        trustConfigurationData.append(UInt8(0))
        trustConfigurationData.append(Data(trustIdentity.utf8))
        let settingsFingerprint = SHA256.hash(data: trustConfigurationData)
            .map { String(format: "%02x", $0) }
            .joined()
        return SkyStreamRuntimeConfiguration(
            manifest: runtimeManifest,
            providerID: provider.providerID,
            exposesProviderID: providerManifest?.baseURL?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty != false,
            baseURL: baseURL,
            scriptURL: scriptURL,
            expectedScriptSHA256: plugin.scriptSHA256,
            settingsFingerprint: settingsFingerprint,
            authorityRevision: authorityRevision,
            dataStore: store
        )
    }

    private func ensureProviderStillCurrent(
        initialProvider: SkyStreamProviderDescriptor,
        initialPlugin: SkyStreamInstalledPluginState,
        initialAuthorityRevision: UUID
    ) throws {
        guard let current = pluginManager.runtimeAuthoritySnapshot(sourceID: initialProvider.id) else {
            throw SkyStreamResolverError.staleContentReference
        }
        let currentProvider = current.provider
        let currentPlugin = current.plugin
        guard current.revision == initialAuthorityRevision,
              currentProvider.isEnabled,
              currentProvider.packageName == initialProvider.packageName,
              currentProvider.providerID == initialProvider.providerID,
              currentProvider.selectedDomainURL == initialProvider.selectedDomainURL,
              currentPlugin.scriptSHA256.caseInsensitiveCompare(initialPlugin.scriptSHA256) == .orderedSame,
              currentPlugin.archiveSHA256.caseInsensitiveCompare(initialPlugin.archiveSHA256) == .orderedSame,
              currentPlugin.manifest.version == initialPlugin.manifest.version,
              currentPlugin.payloadRelativePath == initialPlugin.payloadRelativePath,
              currentPlugin.selectedDomainURL == initialPlugin.selectedDomainURL else {
            throw SkyStreamResolverError.staleContentReference
        }
    }

    func invalidateCachesForPackage(_ packageName: String) {
        searchCache.removeAll(keepingCapacity: true)
        loadCache.removeAll(keepingCapacity: true)
        streamCache.removeAll(keepingCapacity: true)
        runtimePersistenceTasks.removeValue(forKey: packageName)?.cancel()
    }

    private static func canonicalTrustURL(_ rawValue: String?) -> String? {
        guard let rawValue,
              var components = URLComponents(string: rawValue) else { return rawValue }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.string ?? rawValue
    }

    private func pruneCaches(now: Date = Date()) {
        searchCache = searchCache.filter { $0.value.expiresAt > now }
        loadCache = loadCache.filter { $0.value.expiresAt > now }
        streamCache = streamCache.filter { $0.value.expiresAt > now }
        Self.trimCache(&searchCache, maximumEntries: maximumSearchCacheEntries)
        Self.trimCache(&loadCache, maximumEntries: maximumLoadCacheEntries)
        Self.trimCache(&streamCache, maximumEntries: maximumStreamCacheEntries)
    }

    private static func trimCache<Value>(
        _ cache: inout [String: TimedValue<Value>],
        maximumEntries: Int
    ) {
        guard cache.count > maximumEntries else { return }
        for key in cache.sorted(by: {
            if $0.value.expiresAt != $1.value.expiresAt {
                return $0.value.expiresAt < $1.value.expiresAt
            }
            return $0.key < $1.key
        }).prefix(cache.count - maximumEntries).map(\.key) {
            cache.removeValue(forKey: key)
        }
    }

    private func scheduleRuntimeSnapshotPersistence(for plugin: SkyStreamInstalledPluginState) {
        let packageName = plugin.id
        let scriptSHA256 = plugin.scriptSHA256
        runtimePersistenceTasks[packageName]?.cancel()
        runtimePersistenceTasks[packageName] = Task { [runtime, pluginManager] in
            // Fast/full picker passes commonly finish back-to-back. Coalesce them into one disk
            // transaction and snapshot the actor only after the final successful pass settles.
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let snapshot = await runtime.storageSnapshot(packageName: packageName) else { return }
            guard !Task.isCancelled else { return }
            do {
                try await pluginManager.persistRuntimeSnapshot(
                    packageName: packageName,
                    expectedScriptSHA256: scriptSHA256,
                    snapshot: snapshot
                )
            } catch {
                Logger.shared.log(
                    "SkyStream: runtime state persistence failed package=\(packageName) error=\(String(describing: type(of: error)))",
                    type: "SkyStream"
                )
            }
        }
    }

    private static func queryLadder(for target: SkyStreamResolutionTarget) -> [String] {
        let titles = boundedUniqueStrings([target.title] + target.aliases, maximum: 8)
        guard let primaryTitle = titles.first else { return [] }

        func decoratedQueries(for title: String) -> [String] {
            var values: [String] = []
            switch target.kind {
            case .movie:
                if let year = target.year { values.append("\(title) \(year)") }
            case .episode:
                if let season = target.season, let episode = target.episode {
                    values.append(String(format: "%@ S%02dE%02d", title, season, episode))
                    values.append("\(title) \(season)x\(episode)")
                    values.append("\(title) Season \(season) Episode \(episode)")
                }
                for absolute in target.absoluteEpisodeCandidates.prefix(3) {
                    values.append("\(title) Episode \(absolute)")
                    values.append("\(title) \(absolute)")
                }
                if target.isSpecial { values.append("\(title) Special") }
                if target.isAnime, target.wantsDubbed == true { values.append("\(title) Dub") }
            }
            return values
        }

        // Auto Mode has a four-query budget. Reserve those first slots for canonical/romaji/
        // localized/cour aliases instead of exhausting them on decorations of only one title.
        // Manual mode then gains the primary episode forms before less common aliases.
        var queries = Array(titles.prefix(4))
        queries.append(contentsOf: decoratedQueries(for: primaryTitle))
        queries.append(contentsOf: titles.dropFirst(4))
        for alias in titles.dropFirst() {
            queries.append(contentsOf: decoratedQueries(for: alias))
        }
        return boundedUniqueStrings(queries, maximum: 12)
    }

    private static func boundedUniqueStrings(_ values: [String], maximum: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else { continue }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
            if result.count == maximum { break }
        }
        return result
    }

    nonisolated static func titleMatchScore(
        candidateTitle: String,
        candidateAlternateTitles: [String],
        target: SkyStreamResolutionTarget
    ) -> Double {
        let expectedTitles = [target.title] + target.aliases
        let returnedTitles = [candidateTitle] + candidateAlternateTitles
        return expectedTitles.lazy.flatMap { expected in
            returnedTitles.lazy.map { returned in
                HybridSimilarity.calculateSimilarity(original: expected, result: returned)
            }
        }.max() ?? 0
    }

    /// SkyStream's identity boundary is intentionally independent of the Services result-ranking
    /// preference. Plugin search hits below 85% are never loaded, while exact handoffs retain the
    /// stricter 90% boundary.
    nonisolated static func acceptsTitleMatch(
        score: Double,
        requiresExactIdentity: Bool
    ) -> Bool {
        score >= (requiresExactIdentity ? 0.90 : 0.85)
    }

    private static func matchScore(_ hit: SkyStreamSearchRecord, target: SkyStreamResolutionTarget) -> Double {
        titleMatchScore(
            candidateTitle: hit.title,
            candidateAlternateTitles: hit.alternateTitles,
            target: target
        )
    }

    private static func matchesMediaGuards(
        _ hit: SkyStreamSearchRecord,
        target: SkyStreamResolutionTarget
    ) -> Bool {
        if let expectedYear = target.year, let year = hit.year, abs(expectedYear - year) > 1 {
            return false
        }
        if let type = hit.contentType?.rawValue.lowercased() {
            switch target.kind {
            case .movie where type.contains("series") || type.contains("show") || type.contains("tv"):
                return false
            case .episode where type.contains("movie"):
                return false
            default:
                break
            }
            if type.contains("live") { return false }
        }
        return true
    }

    private static func matchesMediaGuards(
        _ loaded: SkyStreamLoadedItemRecord,
        target: SkyStreamResolutionTarget,
        permitsMissingTitle: Bool = false
    ) -> Bool {
        let hit = SkyStreamSearchRecord(
            title: loaded.title,
            url: loaded.url,
            contentType: loaded.contentType,
            year: loaded.year
        )
        guard matchesMediaGuards(hit, target: target) else { return false }
        if target.requiresExactIdentity, !permitsMissingTitle, !target.title.isEmpty {
            // Search ranking accepts canonical, localized, romaji, and cour aliases. Apply the
            // same identity vocabulary after `load()` so a provider cannot pass search with a
            // legitimate alias and then be rejected solely for returning that alias as its title.
            let score = titleMatchScore(
                candidateTitle: loaded.title,
                candidateAlternateTitles: loaded.alternateTitles,
                target: target
            )
            return acceptsTitleMatch(score: score, requiresExactIdentity: true)
        }
        return true
    }

    nonisolated static func selectExplicitEpisode(
        from episodes: [SkyStreamEpisodeRecord],
        target: SkyStreamResolutionTarget,
        preferredURL: String? = nil
    ) -> SkyStreamEpisodeRecord? {
        guard target.kind == .episode else { return nil }
        let labelMatchers = explicitEpisodeIdentityMatchers()

        func firstMatching(
            _ predicate: (SkyStreamEpisodeRecord) -> Bool
        ) -> SkyStreamEpisodeRecord? {
            if let preferredURL,
               let preferred = episodes.first(where: {
                   $0.url == preferredURL && predicate($0)
               }) {
                return preferred
            }
            return episodes.first(where: predicate)
        }

        if let season = target.season, let episode = target.episode,
           let exact = firstMatching({ $0.season == season && $0.episode == episode }) {
            return exact
        }
        let numbers = Set(([target.episode].compactMap { $0 }) + target.absoluteEpisodeCandidates)
        if target.isSpecial,
           let special = firstMatching({
               ($0.season == 0 || $0.name.localizedCaseInsensitiveContains("special"))
                   && ($0.episode.map(numbers.contains) ?? numbers.isEmpty)
           }) {
            return special
        }

        guard !numbers.isEmpty else { return nil }

        // The SDK makes season optional, while its Episode helper materializes an omitted season
        // as zero. Accept that representation only when the returned positive episode number is
        // unambiguous; array position is never treated as identity.
        let numberMatches = episodes.filter {
            guard ($0.season == nil || $0.season == 0),
                  $0.episode.map(numbers.contains) == true,
                  !episodeNameLooksSpecial($0.name) else {
                return false
            }
            guard let labelIdentity = explicitEpisodeIdentity(
                in: $0.name,
                matchers: labelMatchers
            ) else {
                return true
            }
            guard numbers.contains(labelIdentity.episode) else { return false }
            if let parsedSeason = labelIdentity.season,
               let targetSeason = target.season {
                return parsedSeason == targetSeason
                    && target.episode.map { $0 == labelIdentity.episode } != false
            }
            return true
        }
        if let preferredURL,
           let preferred = numberMatches.first(where: { $0.url == preferredURL }) {
            return preferred
        }
        if numberMatches.count == 1 {
            return numberMatches[0]
        }

        // Some conforming plugins omit both numeric fields and put the identity in the label.
        // Parse only explicit episode forms; URL digits and array order are intentionally ignored
        // because either can silently select a different season.
        let labelMatches = episodes.filter { candidate in
            guard !episodeNameLooksSpecial(candidate.name),
                  let identity = explicitEpisodeIdentity(
                    in: candidate.name,
                    matchers: labelMatchers
                  ),
                  numbers.contains(identity.episode) else {
                return false
            }
            if let parsedSeason = identity.season,
               let targetSeason = target.season {
                return parsedSeason == targetSeason
                    && target.episode.map { $0 == identity.episode } != false
            }
            return true
        }
        if let preferredURL,
           let preferred = labelMatches.first(where: { $0.url == preferredURL }) {
            return preferred
        }
        return labelMatches.count == 1 ? labelMatches[0] : nil
    }

    private nonisolated static func episodeNameLooksSpecial(_ name: String) -> Bool {
        name.range(
            of: #"(?i)(?:^|[^a-z0-9])(?:special|ova|oad)(?:$|[^a-z0-9])"#,
            options: .regularExpression
        ) != nil
    }

    private struct EpisodeIdentityMatcher {
        let regex: NSRegularExpression
        let seasonGroup: Int?
        let episodeGroup: Int
    }

    private nonisolated static func explicitEpisodeIdentityMatchers() -> [EpisodeIdentityMatcher] {
        let specifications: [(pattern: String, seasonGroup: Int?, episodeGroup: Int)] = [
            (#"(?i)(?:^|[^a-z0-9])s\s*0*(\d{1,3})\s*[-._ ]*e\s*0*(\d{1,4})(?:$|[^0-9])"#, 1, 2),
            (#"(?i)(?:^|[^0-9])0*(\d{1,3})\s*x\s*0*(\d{1,4})(?:$|[^0-9])"#, 1, 2),
            (#"(?i)(?:^|[^a-z0-9])season\s+0*(\d{1,3})\D{0,12}(?:episode|ep\.?)\s*[-:#]?\s*0*(\d{1,4})(?:$|[^0-9])"#, 1, 2),
            (#"(?i)(?:^|[^a-z0-9])(?:episode|ep\.?)\s*[-:#]?\s*0*(\d{1,4})(?:$|[^0-9])"#, nil, 1)
        ]
        return specifications.compactMap { specification in
            guard let regex = try? NSRegularExpression(pattern: specification.pattern) else {
                return nil
            }
            return EpisodeIdentityMatcher(
                regex: regex,
                seasonGroup: specification.seasonGroup,
                episodeGroup: specification.episodeGroup
            )
        }
    }

    private nonisolated static func explicitEpisodeIdentity(
        in name: String,
        matchers: [EpisodeIdentityMatcher]
    ) -> (season: Int?, episode: Int)? {
        let source = name as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        for matcher in matchers {
            guard let match = matcher.regex.firstMatch(in: name, range: fullRange) else {
                continue
            }
            let episodeRange = match.range(at: matcher.episodeGroup)
            guard episodeRange.location != NSNotFound,
                  let episode = Int(source.substring(with: episodeRange)),
                  episode > 0 else {
                continue
            }
            let season: Int?
            if let seasonGroup = matcher.seasonGroup {
                let seasonRange = match.range(at: seasonGroup)
                season = seasonRange.location == NSNotFound
                    ? nil
                    : Int(source.substring(with: seasonRange))
            } else {
                season = nil
            }
            return (season, episode)
        }
        return nil
    }

    private static func rankedAndDeduplicatedStreams(
        _ streams: [SkyStreamStreamRecord],
        preferredStreamLabel: String?
    ) -> [SkyStreamStreamRecord] {
        var seen = Set<String>()
        let unique = streams.filter {
            seen.insert($0.id).inserted
        }
        let preference = AutoModeQualityPreference.current
        let normalizedPreferredLabel = preferredStreamLabel.map(normalizedStreamLabel)
        let ranked = unique.enumerated().map { index, stream in
            (
                index: index,
                stream: stream,
                matchesPreferred: normalizedPreferredLabel.map {
                    normalizedStreamLabel(streamLabel(stream)) == $0
                } ?? false,
                score: AutoModeStreamSelection.streamPreferenceScore(
                    label: streamRankingLabel(stream),
                    preference: preference,
                    index: index
                )
            )
        }
        return ranked.sorted { lhs, rhs in
            if lhs.matchesPreferred != rhs.matchesPreferred {
                return lhs.matchesPreferred
            }
            return lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }.map(\.stream)
    }

    private static func normalizedStreamLabel(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    nonisolated private static func descriptor(
        _ descriptor: SkyStreamValidatedPlaybackDescriptor,
        isUsableFor purpose: SkyStreamResolutionPurpose
    ) -> Bool {
        guard purpose == .offlineDownload else { return true }
        switch descriptor.mediaKind {
        case .direct:
            return descriptor.proxyOptions == nil
                && descriptor.acceptedManifests.isEmpty
                && (descriptor.finiteContentLength ?? 0) > 0
        case .hls:
            return DownloadManager.skyStreamHLSRejectionReason(descriptor) == nil
        case .dash:
            return false
        }
    }

    private static func streamPassesConfiguredRules(
        _ stream: SkyStreamStreamRecord,
        loaded: SkyStreamLoadedItemRecord,
        episode: SkyStreamEpisodeRecord?,
        sourceID: String,
        target: SkyStreamResolutionTarget,
        originalAudioLanguage: String?
    ) -> Bool {
        guard let configuration = StreamLanguageFilter.configuration(sourceId: sourceID) else {
            return true
        }
        let languageHints = boundedMetadataValues(
            stream.additionalFields,
            matching: ["audio", "language", "languages", "lang", "dub", "dubbed"]
        )
        var metadata = [
            stream.source,
            stream.name,
            stream.qualityLabel,
            stream.quality.map { "\($0)p" },
            stream.mediaType,
            streamURLMetadataHint(stream),
            episode?.dubStatus?.rawValue,
            loaded.providerName
        ].compactMap { $0 }
        metadata.append(contentsOf: boundedMetadataValues(
            stream.additionalFields,
            matching: ["server", "codec", "audio", "quality", "resolution", "language", "lang"]
        ))
        return !StreamLanguageFilter.shouldHide(
            languageHints: languageHints,
            metadata: metadata,
            configuration: configuration,
            originalAudioLanguage: originalAudioLanguage,
            isAnime: target.isAnime
        )
    }

    private static func boundedMetadataValues(
        _ values: [String: SkyStreamJSONValue],
        matching allowedKeys: Set<String>
    ) -> [String] {
        var result: [String] = []
        for key in values.keys.sorted() where allowedKeys.contains(key.lowercased()) {
            guard let value = values[key] else { continue }
            switch value {
            case .string(let string):
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.utf8.count <= 256 { result.append(trimmed) }
            case .array(let entries):
                for entry in entries.prefix(8) {
                    guard case .string(let string) = entry else { continue }
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed.utf8.count <= 128 { result.append(trimmed) }
                }
            case .null, .boolean, .integer, .number, .object:
                break
            }
            if result.count >= 16 { break }
        }
        return Array(result.prefix(16))
    }

    private static func streamLabel(_ stream: SkyStreamStreamRecord) -> String {
        [
            stream.source,
            stream.name,
            stream.qualityLabel,
            stream.quality.map { "\($0)p" },
            stream.mediaType
        ].compactMap { $0 }.joined(separator: " ")
    }

    private static func streamRankingLabel(_ stream: SkyStreamStreamRecord) -> String {
        [streamLabel(stream), streamURLMetadataHint(stream)]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private static func streamURLMetadataHint(_ stream: SkyStreamStreamRecord) -> String? {
        // Normal provider URLs often carry the only language/quality marker in their filename.
        // Do not feed large MAGIC/generated-manifest payloads into ranking regular expressions.
        guard stream.url.utf8.count <= 16_384 else { return nil }
        return stream.url
    }

    nonisolated static func rawCandidate(
        _ stream: SkyStreamStreamRecord,
        loaded: SkyStreamLoadedItemRecord,
        episode: SkyStreamEpisodeRecord?
    ) -> SkyStreamRawStreamCandidate {
        func extraString(_ key: String) -> String? {
            guard case .string(let value)? = stream.additionalFields[key] else { return nil }
            return value
        }
        func extraBool(_ key: String) -> Bool {
            guard case .boolean(let value)? = stream.additionalFields[key] else { return false }
            return value
        }
        let subtitles = stream.subtitles.map {
            SkyStreamRawSubtitleCandidate(
                url: $0.url,
                label: $0.label,
                language: $0.language,
                headers: $0.headers
            )
        }
        return SkyStreamRawStreamCandidate(
            url: stream.url,
            headers: stream.headers,
            referer: stream.referer,
            mediaType: stream.mediaType,
            subtitles: subtitles,
            isLive: extraBool("isLive")
                || stream.mediaType?.localizedCaseInsensitiveContains("live") == true,
            infoHash: extraString("infoHash"),
            torrentURL: extraString("torrentUrl") ?? extraString("torrentURL"),
            drmKeyID: stream.drmKeyID,
            drmKey: stream.drmKey,
            licenseURL: stream.licenseURL,
            // SkyStream's item-level playbackPolicy is display metadata (for example,
            // "Internal Player Only"), not a stream-level external-player requirement.
            // MoltenVK still has to pass the normal URL, live, torrent, and DRM checks.
            externalPlayerPolicy: nil,
            policyHints: [:]
        )
    }

    private static func generation(_ plugin: SkyStreamInstalledPluginState) -> UInt64 {
        let prefix = String(plugin.scriptSHA256.prefix(16))
        return (UInt64(prefix, radix: 16) ?? 0) ^ UInt64(max(0, plugin.manifest.version))
    }
}

#else

@MainActor
public final class SkyStreamResolver {
    public static let shared = SkyStreamResolver()
    public init() {}

    public func resolve(
        sourceID: String,
        target: SkyStreamResolutionTarget,
        mode: SkyStreamResolutionMode
    ) async throws -> [SkyStreamResolvedStream] {
        throw SkyStreamResolverError.unavailable
    }
}

#endif
