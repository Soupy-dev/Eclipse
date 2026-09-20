#if os(macOS)
import Foundation

@MainActor
final class MacProviderPlaybackResolver {
    private let request: PlaybackRequest
    private let owner: UUID
    private let authority: ProgressManager.ProfileMutationAuthority
    private let serviceGeneration: Int
    private let mangayomiConfigurationGeneration: UUID
    private let watchTogetherIdentity: WatchTogetherPlaybackHandoffIdentity
    private var ownedProxies = Set<URL>()
    private var playbackLaunchContext: PlaybackLaunchContext? { request.launchContext }
    private var mediaInfo: MediaInfo? { request.mediaInfo }
    private var episodePlaybackContext: EpisodePlaybackContext? { request.episodePlaybackContext }
    private var servicesOriginalAudioLanguage: String? { request.servicesOriginalAudioLanguage }
    private var playbackTraceID: String { request.launchContext?.traceID ?? String(UUID().uuidString.prefix(8)) }

    init(request: PlaybackRequest, owner: UUID, authority: ProgressManager.ProfileMutationAuthority) {
        self.request = request
        self.owner = owner
        self.authority = authority
        self.serviceGeneration = ServiceStoreScope.generation
        self.mangayomiConfigurationGeneration = MangayomiMediaManager.shared.generation
        self.watchTogetherIdentity = WatchTogetherCoordinator.shared.playbackHandoffIdentity
    }

    private func isAnimeContent() -> Bool { request.isAnime || request.episodePlaybackContext?.hasAnimeMediaId == true }

    private func isCurrent() -> Bool {
        !Task.isCancelled && ProgressManager.shared.profileMutationAuthorityIsCurrent(authority)
            && ServiceStoreScope.isCurrent(serviceGeneration)
            && MangayomiMediaManager.shared.generation == mangayomiConfigurationGeneration
            && WatchTogetherCoordinator.shared.playbackHandoffIdentity == watchTogetherIdentity
    }

    private func discardOwnedProxies() {
        ownedProxies.forEach { MPVHeaderProxy.shared.invalidateSession(for: $0) }
        ownedProxies.removeAll()
    }

    private func requiresRememberedSourceSelection(_ target: ResolvedNextEpisodeTarget) -> Bool {
        watchTogetherIdentity.sessionID == nil
            && RememberedPlaybackSettings.requiresSourceSelection(
                tmdbID: target.showID, season: target.episode.seasonNumber,
                animeID: target.playbackContext?.anilistMediaId)
    }

    func resolveNext(_ target: ResolvedNextEpisodeTarget) async -> PlaybackRequest? {
        defer { discardOwnedProxies() }
        guard isCurrent(), !requiresRememberedSourceSelection(target),
              let seed = NextEpisodeSeed(request: request) else { return nil }
        let changedIdentity = nextEpisodeChangesAnimeIdentity(nextSeasonNumber: target.episode.seasonNumber, nextContext: target.playbackContext)
        let candidates = orderedNextEpisodePrestageCandidates(showId: seed.showID,
            currentSeasonNumber: seed.currentSeasonNumber, currentEpisodeNumber: seed.currentEpisodeNumber)
        let lookup = nextEpisodeLookupNumbers(currentSeasonNumber: seed.currentSeasonNumber,
            nextSeasonNumber: target.episode.seasonNumber, nextEpisodeNumber: target.episode.episodeNumber,
            nextEpisodeContext: target.playbackContext)
        let nextContext = lookup?.context ?? target.playbackContext
        let season = lookup?.season ?? target.episode.seasonNumber
        let episode = lookup?.episode ?? target.episode.episodeNumber
        var titles = [target.seasonTitleOverride, Optional(target.mediaTitle), target.originalTitle].compactMap { $0 }
        if !changedIdentity { titles.append(contentsOf: request.launchContext?.titleCandidates ?? []) }
        for candidate in candidates {
            guard isCurrent(), !requiresRememberedSourceSelection(target) else { return nil }
            let resolution: NextEpisodePrestageResolution?
            switch candidate {
            case .service(let service, let href):
                guard !changedIdentity else { continue }
                resolution = await resolveServicePrestageCandidate(service: service, knownContentHref: href,
                    nextSeasonNumber: target.episode.seasonNumber, nextEpisodeNumber: target.episode.episodeNumber,
                    nextContext: nextContext, lookupSeason: season, lookupEpisode: episode,
                    isAnime: target.isAnime, originalAudioLanguage: request.servicesOriginalAudioLanguage, titleCandidates: titles)
            case .stremio(let addon):
                guard lookup != nil else { continue }
                resolution = await resolveStremioPrestageCandidate(addon: addon, showId: target.showID,
                    imdbId: target.imdbID, lookupSeason: season, lookupEpisode: episode, nextContext: nextContext,
                    isAnime: target.isAnime, originalAudioLanguage: request.servicesOriginalAudioLanguage, titleCandidates: titles)
            case .skyStream(let provider):
                resolution = await resolveSkyStreamPrestageCandidate(provider: provider, lookupSeason: season,
                    lookupEpisode: episode, nextContext: nextContext, isAnime: target.isAnime,
                    originalAudioLanguage: request.servicesOriginalAudioLanguage, titleCandidates: titles)
            case .nuvio(let scraper):
                guard lookup != nil else { continue }
                resolution = await resolveNuvioPrestageCandidate(scraper: scraper, showId: target.showID,
                    lookupSeason: season, lookupEpisode: episode, isAnime: target.isAnime,
                    originalAudioLanguage: request.servicesOriginalAudioLanguage, titleCandidates: titles)
            }
            guard isCurrent(), !requiresRememberedSourceSelection(target) else { return nil }
            if let resolution { return playbackRequest(resolution, target: target) }
        }
        return nil
    }

    func refresh() async -> PlaybackRequest? {
        defer { discardOwnedProxies() }
        guard isCurrent(), let context = request.launchContext else { return nil }
        let resolution: NextEpisodePrestageResolution?
        if context.sourceKind == .nuvio, let reference = context.providerContentReference?.nuvio,
           reference.isStructurallyValid, reference.sourceID == context.sourceId {
            let streams = await NuvioPluginManager.shared.resolveStreams(scraperID: reference.scraperID,
                tmdbId: reference.tmdbID, mediaType: reference.mediaType, season: reference.season, episode: reference.episode)
            guard isCurrent(), let chosen = streams.first(where: { $0.displayName == context.streamName }) ?? streams.first,
                  chosen.isDirectHTTP, let url = URL(string: chosen.url) else { return nil }
            resolution = .init(streamURL: url, headers: chosen.sanitizedHeaders ?? [:], subtitles: chosen.subtitleURLs,
                subtitleNames: chosen.subtitleNames, subtitleHeadersByURL: chosen.subtitleHeadersByURL,
                streamName: chosen.displayName, sourceId: context.sourceId, sourceName: context.sourceName,
                sourceKind: .nuvio, titleCandidates: context.titleCandidates, serviceContentHref: nil,
                providerContentReference: context.providerContentReference)
        } else if context.sourceKind == .stremio {
            resolution = await resolveCurrentStremioPlaybackSource(context: context)
        } else { resolution = await resolveCurrentProviderPlaybackSource(context: context) }
        guard isCurrent(), let resolution else { return nil }
        return playbackRequest(resolution, target: nil)
    }

    private func resolveCurrentStremioPlaybackSource(context: PlaybackLaunchContext) async -> NextEpisodePrestageResolution? {
        guard isCurrent(), let reference = context.providerContentReference, reference.hasValidStremioSelection,
              reference.sourceID == context.sourceId,
              let addon = StremioAddonManager.shared.activeStreamAddons.first(where: { SourceHealth.stremioId($0) == context.sourceId }),
              let type = reference.stremioContentType, let contentID = reference.stremioContentID else { return nil }
        let configuredURL = addon.configuredURL
        guard let streams = try? await StremioClient.shared.fetchStreams(baseURL: configuredURL, type: type, id: contentID),
              isCurrent(), StremioAddonManager.shared.activeStreamAddons.contains(where: {
                  $0.id == addon.id && $0.configuredURL == configuredURL
              }), let selected = reference.selectStremioStream(from: streams), selected.isDirectHTTP,
              let url = Self.httpURL(selected.url) else { return nil }
        let subtitles = StremioAddonComponentSettings.allowsSubtitles(sourceID: context.sourceId)
            ? selected.subtitles ?? [] : []
        let pairs = subtitles.prefix(40).compactMap { subtitle -> (String, String)? in
            guard let url = subtitle.url, Self.httpURL(url) != nil else { return nil }
            return (url, subtitle.displayName)
        }
        return .init(streamURL: url, headers: Self.mergedUserAgentHeaders(custom: selected.proxyHeaders),
            subtitles: pairs.map(\.0), subtitleNames: pairs.isEmpty ? nil : pairs.map(\.1), subtitleHeadersByURL: nil,
            streamName: AutoModeStreamSelection.stremioStreamLabel(for: selected), sourceId: context.sourceId,
            sourceName: addon.manifest.name, sourceKind: .stremio, titleCandidates: context.titleCandidates,
            serviceContentHref: nil, providerContentReference: ProviderContentReference.stremio(
                addonID: addon.id, stream: selected, subtitleOrdinal: reference.selectStremioSubtitleIndex(from: subtitles)) ?? reference)
    }

    private func playbackRequest(_ resolution: NextEpisodePrestageResolution, target: ResolvedNextEpisodeTarget?) -> PlaybackRequest {
        let ownership: PlaybackProxySessionOwnership? = resolution.sourceKind == .skyStream
            ? PlaybackProxySessionOwnership(proxyURLs: [resolution.streamURL]) : nil
        ownedProxies.remove(resolution.streamURL)
        let launch = PlaybackLaunchContext(traceID: playbackTraceID, sourceId: resolution.sourceId,
            sourceName: resolution.sourceName, sourceKind: resolution.sourceKind,
            autoMode: target != nil || request.launchContext?.autoMode == true,
            streamURL: resolution.streamURL.absoluteString, streamName: resolution.streamName,
            headers: resolution.headers, subtitles: resolution.subtitles, subtitleNames: resolution.subtitleNames,
            subtitleHeadersByURL: resolution.subtitleHeadersByURL, retryCount: target == nil ? (request.launchContext?.retryCount ?? 0) + 1 : 0,
            titleCandidates: resolution.titleCandidates, serviceContentHref: resolution.serviceContentHref,
            providerContentReference: resolution.providerContentReference, ephemeralProxyOwnership: ownership)
        let media = target.map { MediaInfo.episode(showId: $0.showID, seasonNumber: $0.episode.seasonNumber,
            episodeNumber: $0.episode.episodeNumber, showTitle: $0.mediaTitle, showPosterURL: $0.posterURL, isAnime: $0.isAnime) }
        return PlaybackRequest(url: resolution.streamURL, preset: request.preset, headers: resolution.headers,
            subtitles: resolution.subtitles, subtitleNames: resolution.subtitleNames,
            subtitleHeadersByURL: resolution.subtitleHeadersByURL, externalAudioTracks: resolution.externalAudioTracks, mediaSelectionIntent: request.mediaSelectionIntent,
            mediaInfo: media ?? request.mediaInfo, kidsPolicyDetails: target == nil ? request.kidsPolicyDetails : nil,
            mediaYear: target?.mediaYear ?? request.mediaYear, imdbID: target?.imdbID ?? request.imdbID,
            episodePlaybackContext: target?.playbackContext ?? request.episodePlaybackContext, launchContext: launch,
            title: target?.mediaTitle ?? request.title, artworkURL: target?.posterURL.flatMap(URL.init(string:)) ?? request.artworkURL,
            isAnime: target?.isAnime ?? request.isAnime, isAnimation: target?.isAnimation ?? request.isAnimation,
            originalTMDBSeasonNumber: target?.originalTMDBSeasonNumber ?? request.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: target?.originalTMDBEpisodeNumber ?? request.originalTMDBEpisodeNumber,
            servicesOriginalTitle: target?.originalTitle ?? request.servicesOriginalTitle,
            servicesOriginalAudioLanguage: request.servicesOriginalAudioLanguage,
            onRequestNextEpisode: request.onRequestNextEpisode, onRequestResolvedNextEpisode: request.onRequestResolvedNextEpisode,
            onPlaybackStartupFailure: request.onPlaybackStartupFailure)
    }

    private enum NextEpisodePrestageCandidate {
        case service(Service, contentHref: String?)
        case stremio(StremioAddon)
#if os(macOS)
        case skyStream(SkyStreamProviderDescriptor)
        case nuvio(NuvioPluginScraper)
#endif

        var sourceId: String {
            switch self {
            case .service(let service, _): SourceHealth.serviceId(service)
            case .stremio(let addon): SourceHealth.stremioId(addon)
#if os(macOS)
            case .skyStream(let provider): provider.id
            case .nuvio(let scraper): scraper.id
#endif
            }
        }

        var sourceName: String {
            switch self {
            case .service(let service, _): service.metadata.sourceName
            case .stremio(let addon): addon.manifest.name
#if os(macOS)
            case .skyStream(let provider): provider.displayName
            case .nuvio(let scraper): scraper.displayName
#endif
            }
        }

        var sortIndex: Int64 {
            switch self {
            case .service(let service, _): service.sortIndex
            case .stremio(let addon): addon.sortIndex
#if os(macOS)
            case .skyStream(let provider): Int64(provider.sortIndex)
            case .nuvio: Int64.max
#endif
            }
        }
    }

    private struct NextEpisodePrestageResolution {
        let streamURL: URL
        let headers: [String: String]
        let subtitles: [String]
        let subtitleNames: [String]?
        let subtitleHeadersByURL: [String: [String: String]]?
        let streamName: String?
        let sourceId: String
        let sourceName: String
        let sourceKind: PlaybackSourceKind
        let titleCandidates: [String]
        let serviceContentHref: String?
        let providerContentReference: ProviderContentReference?
        var externalAudioTracks: [PlaybackExternalAudioTrack] = []
    }

    private func orderedNextEpisodePrestageCandidates(
        showId: Int,
        currentSeasonNumber: Int,
        currentEpisodeNumber: Int
    ) -> [NextEpisodePrestageCandidate] {
        let launch = playbackLaunchContext
        let recorded = ProgressManager.shared.findEpisode(
            showId: showId,
            season: currentSeasonNumber,
            episode: currentEpisodeNumber
        )
        var candidates: [NextEpisodePrestageCandidate] = ServiceManager.shared.activeServices.map { service in
            let sourceId = SourceHealth.serviceId(service)
            let launchHref = launch?.sourceId == sourceId ? launch?.serviceContentHref : nil
            let recordedHref = recorded?.lastServiceId == service.id ? recorded?.lastHref : nil
            return .service(service, contentHref: launchHref ?? recordedHref)
        }
        candidates.append(contentsOf: StremioAddonManager.shared.activeStreamAddons.map {
            .stremio($0)
        })
#if os(macOS)
        if PlatformCapabilities.current.supportsSkyStreamPlugins {
            candidates.append(contentsOf: SkyStreamPluginManager.shared.providers
                .filter(\.isEnabled)
                .map { .skyStream($0) })
        }
        if PlatformCapabilities.current.supportsNuvioPlugins {
            candidates.append(contentsOf: NuvioPluginManager.shared.activeScrapers
                .map { .nuvio($0) })
        }
#endif

        candidates.removeAll {
            SourceHealthStore.shared.shouldSkipForAutoMode(sourceId: $0.sourceId)
        }

        candidates.sort { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName) == .orderedAscending
        }
        let candidateById = candidates.reduce(into: [String: NextEpisodePrestageCandidate]()) { result, candidate in

            if result[candidate.sourceId] == nil {
                result[candidate.sourceId] = candidate
            }
        }
        let orderedIds = AutoModeSourceSelection.orderedSelectedSourceIds(
            availableSourceIds: candidates.map(\.sourceId)
        )
        candidates = orderedIds.compactMap { candidateById[$0] }

        if let currentSourceId = launch?.sourceId,
           let current = candidateById[currentSourceId] {
            candidates.removeAll { $0.sourceId == currentSourceId }
            candidates.insert(current, at: 0)
        }
        return candidates
    }


    private func resolveServicePrestageCandidate(
        service: Service,
        knownContentHref: String?,
        nextSeasonNumber: Int,
        nextEpisodeNumber: Int,
        nextContext: EpisodePlaybackContext?,
        lookupSeason: Int,
        lookupEpisode: Int,
        isAnime: Bool,
        originalAudioLanguage: String?,
        titleCandidates: [String],
        preferredStreamName: String? = nil
    ) async -> NextEpisodePrestageResolution? {
        let knownContentHref = Self.normalizedNonemptyString(knownContentHref)
        if let knownContentHref,
           let resolved = await resolveServicePrestageCandidate(
                service: service,
                contentHref: knownContentHref,
                nextSeasonNumber: nextSeasonNumber,
                nextEpisodeNumber: nextEpisodeNumber,
                nextContext: nextContext,
                lookupSeason: lookupSeason,
                lookupEpisode: lookupEpisode,
                isAnime: isAnime,
                originalAudioLanguage: originalAudioLanguage,
                titleCandidates: titleCandidates,
                preferredStreamName: preferredStreamName
           ) {
            return resolved
        }

        guard let discovered = await discoverServiceContentHref(
            service: service,
            titleCandidates: titleCandidates,
            seasonNumber: nextSeasonNumber,
            episodeNumber: nextEpisodeNumber,
            isAnime: isAnime
        ), discovered != knownContentHref else { return nil }

        return await resolveServicePrestageCandidate(
            service: service,
            contentHref: discovered,
            nextSeasonNumber: nextSeasonNumber,
            nextEpisodeNumber: nextEpisodeNumber,
            nextContext: nextContext,
            lookupSeason: lookupSeason,
            lookupEpisode: lookupEpisode,
            isAnime: isAnime,
            originalAudioLanguage: originalAudioLanguage,
            titleCandidates: titleCandidates,
            preferredStreamName: preferredStreamName
        )
    }

    private func resolveServicePrestageCandidate(
        service: Service,
        contentHref: String,
        nextSeasonNumber: Int,
        nextEpisodeNumber: Int,
        nextContext: EpisodePlaybackContext?,
        lookupSeason: Int,
        lookupEpisode: Int,
        isAnime: Bool,
        originalAudioLanguage: String?,
        titleCandidates: [String],
        preferredStreamName: String? = nil
    ) async -> NextEpisodePrestageResolution? {
        let jsController = JSController()
        jsController.loadScript(service.jsScript, service: service)
        let episodes = await fetchServiceEpisodes(jsController: jsController, service: service, contentHref: contentHref)
        guard isCurrent() else { return nil }
        let nextHref: String?
        if let source = service.mangayomiSource {
            nextHref = MangayomiEpisodeSelectionPolicy.matchingEpisodes(
                episodes, sourceID: source.id, isMovie: false,
                seasonNumber: nextSeasonNumber, episodeNumber: nextEpisodeNumber, context: nextContext
            ).first?.href
        } else {
            nextHref = Self.nextEpisodeHref(
                episodes: episodes,
                seasonNumber: nextSeasonNumber,
                episodeNumber: nextEpisodeNumber,
                context: nextContext,
                resolvedSeasonNumber: lookupSeason,
                resolvedEpisodeNumber: lookupEpisode,
                isAnime: isAnime
            )
        }
        guard let nextHref else { return nil }

        let result = await fetchServiceStreams(jsController: jsController, service: service, episodeHref: nextHref)
        guard isCurrent(),
              let selected = Self.selectPrewarmStream(
                streams: result.streams,
                sources: result.sources,
                sourceId: SourceHealth.serviceId(service),
                isAnime: isAnime,
                originalAudioLanguage: originalAudioLanguage,
                preferredLabel: preferredStreamName
              ),
              let streamURL = Self.httpURL(selected.url) else {
            return nil
        }

        let subtitles = Self.serviceSubtitleSelection(
            entries: (selected.subtitleEntries ?? []) + (result.subtitles ?? [])
        )
        let subtitleHeaders = selected.subtitleHeadersByURL?.filter {
            subtitles.urls.contains($0.key)
        }
        return NextEpisodePrestageResolution(
            streamURL: streamURL,
            headers: Self.mergedPlaybackHeaders(baseURL: service.metadata.baseUrl, custom: selected.headers),
            subtitles: subtitles.urls,
            subtitleNames: subtitles.names,
            subtitleHeadersByURL: subtitleHeaders?.isEmpty == false ? subtitleHeaders : nil,
            streamName: selected.label,
            sourceId: SourceHealth.serviceId(service),
            sourceName: service.metadata.sourceName,
            sourceKind: .service,
            titleCandidates: titleCandidates,
            serviceContentHref: contentHref,
            providerContentReference: nil,
            externalAudioTracks: selected.externalAudioTracks
        )
    }

    private func resolveStremioPrestageCandidate(
        addon: StremioAddon,
        showId: Int,
        imdbId: String?,
        lookupSeason: Int,
        lookupEpisode: Int,
        nextContext: EpisodePlaybackContext?,
        isAnime: Bool,
        originalAudioLanguage: String?,
        titleCandidates: [String]
    ) async -> NextEpisodePrestageResolution? {
        let sourceId = SourceHealth.stremioId(addon)
        let streams = await StremioAddonManager.shared.fetchStreamsFromAddon(
            addon,
            tmdbId: showId,
            imdbId: imdbId,
            type: "series",
            season: lookupSeason,
            episode: lookupEpisode,
            anilistId: nextContext?.positiveAniListMediaId
                ?? nextContext?.anilistMediaId,
            playbackContext: nextContext,
            titleCandidates: titleCandidates
        )
        guard isCurrent() else { return nil }
        let direct = streams.filter {
            $0.isDirectHTTP && !StreamLanguageFilter.shouldHide(
                stremio: $0,
                sourceId: sourceId,
                originalAudioLanguage: originalAudioLanguage,
                isAnime: isAnime
            )
        }
        let rankedStream = AutoModeStreamSelection.bestStremioStream(
            from: direct,
            sourceId: sourceId,
            streamsAreFiltered: true,
            isAnime: isAnime,
            originalAudioLanguage: originalAudioLanguage
        ) ?? (direct.count == 1 ? direct.first : nil)
        guard let stream = rankedStream,
              let streamURL = Self.httpURL(stream.url) else {
            return nil
        }

        let embeddedSubtitles = StremioAddonComponentSettings.allowsSubtitles(sourceID: sourceId)
            ? stream.subtitles ?? [] : []
        let subtitlePairs = embeddedSubtitles.compactMap { subtitle -> (String, String)? in
            guard let url = subtitle.url, Self.httpURL(url) != nil else { return nil }
            return (url, subtitle.displayName)
        }
        return NextEpisodePrestageResolution(
            streamURL: streamURL,
            headers: Self.mergedUserAgentHeaders(custom: stream.proxyHeaders),
            subtitles: subtitlePairs.map(\.0),
            subtitleNames: subtitlePairs.isEmpty ? nil : subtitlePairs.map(\.1),
            subtitleHeadersByURL: nil,
            streamName: AutoModeStreamSelection.stremioStreamLabel(for: stream),
            sourceId: sourceId,
            sourceName: addon.manifest.name,
            sourceKind: .stremio,
            titleCandidates: titleCandidates,
            serviceContentHref: nil,
            providerContentReference: ProviderContentReference.stremio(addonID: addon.id, stream: stream, subtitleOrdinal: nil)
        )
    }

#if os(macOS)
    private func resolveNuvioPrestageCandidate(
        scraper: NuvioPluginScraper,
        showId: Int,
        lookupSeason: Int,
        lookupEpisode: Int,
        isAnime: Bool,
        originalAudioLanguage: String?,
        titleCandidates: [String]
    ) async -> NextEpisodePrestageResolution? {
        guard PlatformCapabilities.current.supportsNuvioPlugins,
              scraper.isRunnable,
              showId > 0 else {
            return nil
        }

        let streams = await NuvioPluginManager.shared.resolveStreams(
            scraperID: scraper.id,
            tmdbId: String(showId),
            mediaType: "tv",
            season: lookupSeason,
            episode: lookupEpisode
        )
        guard isCurrent() else { return nil }

        let allowed = streams.filter { stream in
            !StreamLanguageFilter.shouldHide(
                languageHints: stream.languageHints,
                metadata: [stream.displayName] + stream.metadataHints,
                sourceId: scraper.id,
                originalAudioLanguage: originalAudioLanguage,
                isAnime: isAnime
            )
        }
        guard let chosen = AutoModeStreamSelection.bestNuvioStream(from: allowed),
              let streamURL = URL(string: chosen.url) else {
            return nil
        }

        let reference = NuvioProviderContentReference(
            sourceID: scraper.id,
            scraperID: scraper.id,
            tmdbID: String(showId),
            mediaType: "tv",
            season: lookupSeason,
            episode: lookupEpisode
        )
        guard reference.isStructurallyValid else { return nil }

        var headers: [String: String] = ["User-Agent": URLSession.randomUserAgent]
        for (key, value) in chosen.sanitizedHeaders ?? [:] {
            headers[key] = value
        }

        return NextEpisodePrestageResolution(
            streamURL: streamURL,
            headers: headers,
            subtitles: chosen.subtitleURLs,
            subtitleNames: chosen.subtitleNames,
            subtitleHeadersByURL: chosen.subtitleHeadersByURL,
            streamName: chosen.displayName,
            sourceId: scraper.id,
            sourceName: scraper.displayName,
            sourceKind: .nuvio,
            titleCandidates: titleCandidates,
            serviceContentHref: nil,
            providerContentReference: .nuvio(reference)
        )
    }

    private func resolveSkyStreamPrestageCandidate(
        provider: SkyStreamProviderDescriptor,
        lookupSeason: Int,
        lookupEpisode: Int,
        nextContext: EpisodePlaybackContext?,
        isAnime: Bool,
        originalAudioLanguage: String?,
        titleCandidates: [String]
    ) async -> NextEpisodePrestageResolution? {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins,
              provider.isEnabled,
              let title = titleCandidates.first,
              !title.isEmpty else {
            return nil
        }
        let absoluteCandidates = [
            nextContext?.animeAbsoluteEpisodeNumber,
            nextContext?.resolvedTMDBEpisodeNumber
        ].compactMap { $0 }
        let target = SkyStreamResolutionTarget(
            kind: .episode,
            title: title,
            aliases: Array(titleCandidates.dropFirst()),
            year: nil,
            season: lookupSeason,
            episode: lookupEpisode,
            absoluteEpisodeCandidates: absoluteCandidates,
            isAnime: isAnime,
            isSpecial: nextContext?.isSpecial == true,
            wantsDubbed: nil,

            requiresExactIdentity: true
        )

        do {
            let values = try await SkyStreamResolver.shared.resolve(
                sourceID: provider.id,
                target: target,
                mode: .autoMode,
                originalAudioLanguage: originalAudioLanguage
            )
            guard isCurrent(),
                  let resolved = values.first,
                  resolved.provider.id == provider.id,
                  resolved.contentReference.sourceID == provider.id,
                  !StreamLanguageFilter.shouldHide(
                    languageHints: [],
                    metadata: [resolved.displayName],
                    sourceId: provider.id,
                    originalAudioLanguage: originalAudioLanguage,
                    isAnime: isAnime
                  ) else {
                return nil
            }
            return makeSkyStreamPlaybackResolution(
                resolved,
                titleCandidates: titleCandidates,
                traceID: "next-\(playbackTraceID)"
            )
        } catch is CancellationError {
            return nil
        } catch {
            Logger.shared.log(
                "SkyStream: next-episode staging failed source=\(provider.id) errorType=\(String(reflecting: type(of: error)))",
                type: "MPV"
            )
            return nil
        }
    }

    private func makeSkyStreamPlaybackResolution(
        _ resolved: SkyStreamResolvedStream,
        titleCandidates: [String],
        traceID: String
    ) -> NextEpisodePrestageResolution? {
        guard let proxyURL = MPVHeaderProxy.shared.makeSkyStreamProxyURL(
            for: resolved.playback,
            traceID: traceID
        ) else {
            return nil
        }
        guard let subtitleProxyURLs = MPVHeaderProxy.shared.skyStreamSubtitleProxyURLs(
            for: resolved.playback,
            streamProxyURL: proxyURL
        ) else {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
            return nil
        }
        if !isCurrent() {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
            return nil
        }

        let descriptor = resolved.playback
        let subtitles = descriptor.subtitles.compactMap { subtitle -> String? in
                var components = URLComponents(
                    url: subtitle.remoteURL.url.absoluteURL,
                    resolvingAgainstBaseURL: false
                )
                components?.fragment = nil
                let key = components?.url?.absoluteString
                    ?? subtitle.remoteURL.url.absoluteURL.absoluteString
                return subtitleProxyURLs[key]?.absoluteString
        }
        guard subtitles.count == descriptor.subtitles.count else {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
            return nil
        }
        ownedProxies.insert(proxyURL)
        let subtitleNames = descriptor.subtitles.map {
            $0.label ?? $0.language ?? "Subtitle"
        }
        return NextEpisodePrestageResolution(
            streamURL: proxyURL,
            headers: [:],
            subtitles: subtitles,
            subtitleNames: subtitleNames.isEmpty ? nil : subtitleNames,
            subtitleHeadersByURL: nil,
            streamName: resolved.displayName,
            sourceId: resolved.provider.id,
            sourceName: resolved.provider.displayName,
            sourceKind: .skyStream,
            titleCandidates: titleCandidates,
            serviceContentHref: nil,
            providerContentReference: .skyStream(resolved.contentReference)
        )
    }
#endif

    private func discoverServiceContentHref(
        service: Service,
        titleCandidates: [String],
        seasonNumber: Int,
        episodeNumber: Int,
        isAnime: Bool
    ) async -> String? {
        let queries = servicePrestageSearchQueries(
            titleCandidates: titleCandidates,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            isAnime: isAnime
        )
        var results: [SearchItem] = []
        var seenHrefs = Set<String>()

        for query in queries.prefix(4) {
            guard isCurrent() else { return nil }
            let found = await ServiceManager.shared.searchSingleActiveService(service: service, query: query)
            results.append(contentsOf: found.filter { seenHrefs.insert($0.href).inserted })
            if let exact = bestServicePrestageResult(results, titleCandidates: titleCandidates), exact.score >= 0.93 {
                return exact.result.href
            }
        }
        guard let best = bestServicePrestageResult(results, titleCandidates: titleCandidates), best.score >= 0.85 else {
            return nil
        }
        return best.result.href
    }

    private func fetchServiceEpisodes(
        jsController: JSController,
        service: Service,
        contentHref: String
    ) async -> [EpisodeLink] {
        await withCheckedContinuation { continuation in
            jsController.fetchEpisodesJS(url: contentHref, module: service) { [jsController] episodes in
                _ = jsController
                continuation.resume(returning: episodes)
            }
        }
    }

    private func fetchServiceStreams(
        jsController: JSController,
        service: Service,
        episodeHref: String
    ) async -> ServiceStreamExtractionResult {
        await withCheckedContinuation { continuation in
            jsController.fetchStreamUrlJS(
                episodeUrl: episodeHref,
                softsub: service.metadata.softsub ?? false,
                module: service
            ) { [jsController] result in
                _ = jsController
                continuation.resume(returning: result)
            }
        }
    }


    private func servicePrestageSearchQueries(
        titleCandidates: [String],
        seasonNumber: Int,
        episodeNumber: Int,
        isAnime: Bool
    ) -> [String] {
        var queries: [String] = []
        for title in titleCandidates.prefix(2) {
            queries.append(isAnime ? "\(title) E\(episodeNumber)" : "\(title) S\(seasonNumber)E\(episodeNumber)")
            queries.append(title)
        }
        var seen = Set<String>()
        return queries.filter { seen.insert(Self.normalizedTitleKey($0)).inserted }
    }

    private func bestServicePrestageResult(
        _ results: [SearchItem],
        titleCandidates: [String]
    ) -> (result: SearchItem, score: Double)? {
        results.enumerated().compactMap { index, result -> (Int, SearchItem, Double)? in
            let score = titleCandidates.map {
                AlgorithmManager.shared.calculateSimilarity(original: $0, result: result.title)
            }.max() ?? 0
            return (index, result, score)
        }
        .max { lhs, rhs in
            if abs(lhs.2 - rhs.2) < 0.0001 { return lhs.0 > rhs.0 }
            return lhs.2 < rhs.2
        }
        .map { ($0.1, $0.2) }
    }

    private static func nextEpisodeHref(
        episodes: [EpisodeLink],
        seasonNumber: Int,
        episodeNumber: Int,
        context: EpisodePlaybackContext?,
        resolvedSeasonNumber: Int?,
        resolvedEpisodeNumber: Int?,
        isAnime: Bool
    ) -> String? {
        guard !episodes.isEmpty else { return nil }

        var seasons: [[EpisodeLink]] = []
        var current: [EpisodeLink] = []
        var last = 0
        for ep in episodes {
            if ep.number == 1 || ep.number <= last {
                if !current.isEmpty { seasons.append(current); current = [] }
            }
            current.append(ep)
            last = ep.number
        }
        if !current.isEmpty { seasons.append(current) }

        let index = seasonNumber - 1
        if index >= 0, index < seasons.count,
           let match = seasons[index].first(where: { $0.number == episodeNumber }) {
            return match.href
        }
        guard isAnime,
              let context,
              !context.isSpecial,
              let seasonEpisodeCount = context.animeSeasonEpisodeCount,
              seasonEpisodeCount > 0 else {

            if seasons.count <= 1, let match = episodes.first(where: { $0.number == episodeNumber }) {
                return match.href
            }
            return nil
        }

        let stats = sourceEpisodeListStats(episodes)
        if stats.maxNumber > seasonEpisodeCount {
            let candidates = nextEpisodeBundledNumberCandidates(
                context: context,
                resolvedSeasonNumber: resolvedSeasonNumber,
                resolvedEpisodeNumber: resolvedEpisodeNumber,
                localEpisodeNumber: episodeNumber
            )
            if let bundled = firstUniqueEpisodeHref(episodes: episodes, numbers: candidates) {
                return bundled
            }
        }

        if stats.count <= seasonEpisodeCount,
           stats.maxNumber <= seasonEpisodeCount,
           let singleSeason = uniqueEpisodeHref(episodes: episodes, number: episodeNumber) {
            return singleSeason
        }

        if seasonNumber <= 1,
           let match = episodes.first(where: { $0.number == episodeNumber }) {
            return match.href
        }
        return nil
    }

    private static func sourceEpisodeListStats(_ episodes: [EpisodeLink]) -> (count: Int, maxNumber: Int) {
        let numbers = episodes.map(\.number)
        return (numbers.count, numbers.max() ?? 0)
    }

    private static func nextEpisodeBundledNumberCandidates(
        context: EpisodePlaybackContext,
        resolvedSeasonNumber: Int?,
        resolvedEpisodeNumber: Int?,
        localEpisodeNumber: Int
    ) -> [Int] {
        var numbers: [Int] = []
        if let absoluteEpisode = context.animeAbsoluteEpisodeNumber {
            numbers.append(absoluteEpisode)
        }
        if resolvedSeasonNumber == 1, let resolvedEpisodeNumber {
            numbers.append(resolvedEpisodeNumber)
        }

        var seen = Set<Int>()
        return numbers
            .filter { $0 > 0 && $0 != localEpisodeNumber }
            .filter { seen.insert($0).inserted }
    }

    private static func firstUniqueEpisodeHref(episodes: [EpisodeLink], numbers: [Int]) -> String? {
        for number in numbers {
            if let href = uniqueEpisodeHref(episodes: episodes, number: number) {
                return href
            }
        }
        return nil
    }

    private static func uniqueEpisodeHref(episodes: [EpisodeLink], number: Int) -> String? {
        let matches = episodes.filter { $0.number == number }
        guard matches.count == 1 else { return nil }
        return matches.first?.href
    }

    private static func selectPrewarmStream(
        streams: [String]?,
        sources: [[String: Any]]?,
        sourceId: String,
        isAnime: Bool = false,
        originalAudioLanguage: String?,
        preferredLabel: String? = nil
    ) -> (url: String, headers: [String: String]?, label: String, subtitleEntries: [String]?, subtitleHeadersByURL: [String: [String: String]]?, externalAudioTracks: [PlaybackExternalAudioTrack])? {
        var candidates: [(url: String, headers: [String: String]?, label: String, scoreLabel: String, subtitleEntries: [String]?, subtitleHeadersByURL: [String: [String: String]]?, externalAudioTracks: [PlaybackExternalAudioTrack])] = []
        if let sources = sources, !sources.isEmpty {
            for (index, source) in sources.enumerated() {
                guard let raw = ["streamUrl", "url", "file", "src", "link", "stream"]
                    .lazy
                    .compactMap({ source[$0] as? String })
                    .first(where: { !$0.isEmpty }) else { continue }
                let displayLabel = stringValues(
                    in: source,
                    keys: ["title", "name", "label", "quality"]
                ).first ?? "Stream \(index + 1)"
                let metadata = stringValues(
                    in: source,
                    keys: StreamLanguageFilter.sourceMetadataHintKeys
                )
                let languageHints = stringValues(
                    in: source,
                    keys: StreamLanguageFilter.sourceLanguageHintKeys
                )
                guard !StreamLanguageFilter.shouldHide(
                    languageHints: languageHints,
                    metadata: metadata + [raw],
                    sourceId: sourceId,
                    originalAudioLanguage: originalAudioLanguage,
                    isAnime: isAnime
                ) else { continue }
                candidates.append((
                    raw,
                    headersFromAny(source["headers"]),
                    displayLabel,
                    (metadata + [raw]).joined(separator: " "),
                    serviceSubtitleEntries(in: source),
                    serviceSubtitleHeaders(in: source),
                    PlaybackExternalAudioTrack.serviceTracks(in: source)
                ))
            }
        } else if let streams = streams {
            var index = 0
            var unnamedCount = 1
            while index < streams.count {
                let entry = streams[index]
                let raw: String
                let label: String
                if httpURL(entry) != nil {
                    raw = entry
                    label = "Stream \(unnamedCount)"
                    unnamedCount += 1
                    index += 1
                } else if index + 1 < streams.count,
                          httpURL(streams[index + 1]) != nil {
                    raw = streams[index + 1]
                    label = normalizedNonemptyString(entry) ?? "Stream"
                    index += 2
                } else {
                    index += 1
                    continue
                }
                guard !StreamLanguageFilter.shouldHide(
                    languageHints: [],
                    metadata: [label, raw],
                    sourceId: sourceId,
                    originalAudioLanguage: originalAudioLanguage,
                    isAnime: isAnime
                ) else { continue }
                candidates.append((raw, nil, label, "\(label) \(raw)", nil, nil, []))
            }
        }

        guard !candidates.isEmpty else { return nil }
        if let preferredLabel = normalizedNonemptyString(preferredLabel) {
            let preferredKey = normalizedTitleKey(preferredLabel)
            if let matched = candidates.first(where: {
                normalizedTitleKey($0.label) == preferredKey
            }) {
                return (
                    matched.url,
                    matched.headers,
                    matched.label,
                    matched.subtitleEntries,
                    matched.subtitleHeadersByURL,
                    matched.externalAudioTracks
                )
            }
        }
        if candidates.count == 1 {
            let candidate = candidates[0]
            return (candidate.url, candidate.headers, candidate.label, candidate.subtitleEntries, candidate.subtitleHeadersByURL, candidate.externalAudioTracks)
        }

        let preference = AutoModeQualityPreference.current
        guard preference.usesAutomaticSelection,
              candidates.contains(where: { AutoModeStreamSelection.streamLabelHasDetectedQuality($0.scoreLabel) }) else {
            return nil
        }

        let best = candidates.enumerated().max {
            AutoModeStreamSelection.streamPreferenceScore(label: $0.element.scoreLabel, preference: preference, index: $0.offset)
                < AutoModeStreamSelection.streamPreferenceScore(label: $1.element.scoreLabel, preference: preference, index: $1.offset)
        }?.element
        guard let best else { return nil }
        return (best.url, best.headers, best.label, best.subtitleEntries, best.subtitleHeadersByURL, best.externalAudioTracks)
    }

    private static func serviceSubtitleEntries(in source: [String: Any]) -> [String]? {
        var entries: [String] = []
        if let subtitle = normalizedNonemptyString(source["subtitle"] as? String) {
            entries.append(subtitle)
        }
        if let subtitles = source["subtitles"] as? [String] {
            entries.append(contentsOf: subtitles.compactMap(normalizedNonemptyString))
        }
        if let subtitles = source["subtitles"] as? [[String: Any]] {
            for (index, subtitle) in subtitles.enumerated() {
                guard let url = firstStringValue(in: subtitle, keys: ["url", "file", "src"]),
                      httpURL(url) != nil else { continue }
                let name = firstStringValue(in: subtitle, keys: ["title", "name", "label", "lang", "language"])
                    ?? "Subtitle \(index + 1)"
                entries.append(contentsOf: [name, url])
            }
        }
        return entries.isEmpty ? nil : entries
    }

    private static func serviceSubtitleHeaders(in source: [String: Any]) -> [String: [String: String]]? {
        guard let subtitles = source["subtitles"] as? [[String: Any]] else { return nil }
        var result: [String: [String: String]] = [:]
        for subtitle in subtitles {
            guard let url = firstStringValue(in: subtitle, keys: ["url", "file", "src"]),
                  httpURL(url) != nil,
                  let headers = headersFromAny(subtitle["headers"]),
                  !headers.isEmpty else { continue }
            result[url] = headers
        }
        return result.isEmpty ? nil : result
    }

    private static func firstStringValue(in source: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { normalizedNonemptyString(source[$0] as? String) }.first
    }

    private static func serviceSubtitleSelection(entries: [String]) -> (urls: [String], names: [String]?) {
        var pairs: [(url: String, name: String)] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if httpURL(entry) != nil {
                pairs.append((entry, "Subtitle \(pairs.count + 1)"))
                index += 1
                continue
            }
            let nextIndex = index + 1
            if nextIndex < entries.count {
                let url = entries[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if httpURL(url) != nil {
                    pairs.append((url, entry.isEmpty ? "Subtitle \(pairs.count + 1)" : entry))
                    index += 2
                    continue
                }
            }
            index += 1
        }

        var seen = Set<String>()
        pairs = pairs.filter { seen.insert($0.url).inserted }
        return (pairs.map(\.url), pairs.isEmpty ? nil : pairs.map(\.name))
    }

    private static func httpURL(_ rawValue: String?) -> URL? {
        guard let value = normalizedNonemptyString(rawValue),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private static func normalizedNonemptyString(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func strippingEpisodeSuffix(_ title: String) -> String {
        let patterns = [
            #"(?i)\s*-?\s*S\d{1,3}E\d{1,4}$"#,
            #"(?i)\s*-?\s*E\d{1,4}$"#,
            #"(?i)\s*episode\s+\d{1,4}$"#
        ]
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in patterns {
            if let range = result.range(of: pattern, options: .regularExpression) {
                result.removeSubrange(range)
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedTitleKey(_ title: String) -> String {
        title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringValues(in source: [String: Any], keys: [String]) -> [String] {
        keys.flatMap { key -> [String] in
            guard let rawValue = source[key] else { return [] }
            if let value = streamMetadataString(from: rawValue) {
                return [value]
            }
            if let values = rawValue as? [Any] {
                return values.compactMap(streamMetadataString(from:))
            }
            return []
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    private static func streamMetadataString(from value: Any) -> String? {
        if value is Bool || value is NSNull { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func headersFromAny(_ value: Any?) -> [String: String]? {
        guard let value, !(value is NSNull) else { return nil }
        if let headers = value as? [String: String] { return headers }
        if let dict = value as? [String: Any] {
            var out: [String: String] = [:]
            for (key, val) in dict {
                if let s = val as? String { out[key] = s }
                else if let n = val as? NSNumber { out[key] = n.stringValue }
                else if !(val is NSNull) { out[key] = String(describing: val) }
            }
            return out.isEmpty ? nil : out
        }
        return nil
    }

    private static func mergedPlaybackHeaders(baseURL: String, custom: [String: String]?) -> [String: String] {
        var finalHeaders: [String: String] = [
            "Origin": baseURL,
            "Referer": baseURL,
            "User-Agent": URLSession.randomUserAgent
        ]
        if let custom {
            for (k, v) in custom { finalHeaders[k] = v }
            if finalHeaders["User-Agent"] == nil {
                finalHeaders["User-Agent"] = URLSession.randomUserAgent
            }
        }
        return finalHeaders
    }

    private static func mergedUserAgentHeaders(custom: [String: String]?) -> [String: String] {
        var finalHeaders: [String: String] = ["User-Agent": URLSession.randomUserAgent]
        if let custom {
            for (k, v) in custom { finalHeaders[k] = v }
        }
        return finalHeaders
    }


    private func nextEpisodeLookupNumbers(
        currentSeasonNumber: Int,
        nextSeasonNumber: Int,
        nextEpisodeNumber: Int,
        nextEpisodeContext: EpisodePlaybackContext?
    ) -> (season: Int?, episode: Int?, context: EpisodePlaybackContext?)? {
        let isAnime = isAnimeContent()

        let nextContext = nextEpisodeContext ?? (
            !isAnime && nextSeasonNumber == currentSeasonNumber
                ? episodePlaybackContext?.forEpisodeNumber(nextEpisodeNumber)
                : nil
        )

        if isAnime && nextContext == nil {
            return nil
        }

        if let context = nextContext, context.isSpecial {
            guard let season = context.resolvedTMDBSeasonNumber,
                  let episode = context.resolvedTMDBEpisodeNumber else {
                return nil
            }
            return (season, episode, nextContext)
        }

        let season = nextContext?.resolvedTMDBSeasonNumber ?? nextSeasonNumber
        let episode = nextContext?.resolvedTMDBEpisodeNumber ?? nextEpisodeNumber
        return (season, episode, nextContext)
    }

    private func nextEpisodeChangesAnimeIdentity(
        nextSeasonNumber: Int,
        nextContext: EpisodePlaybackContext?
    ) -> Bool {
        guard isAnimeContent() else { return false }
        guard let nextContext else { return true }
        guard let currentContext = episodePlaybackContext else {
            return nextContext.localSeasonNumber != nextSeasonNumber
                || nextContext.hasAnimeMediaId
        }
        let currentProviderID = currentContext.positiveAniListMediaId
            ?? currentContext.anilistMediaId
        let nextProviderID = nextContext.positiveAniListMediaId
            ?? nextContext.anilistMediaId
        return currentContext.localSeasonNumber != nextContext.localSeasonNumber
            || currentProviderID != nextProviderID
            || currentContext.kitsuMediaId != nextContext.kitsuMediaId
            || currentContext.isSpecial != nextContext.isSpecial
    }


    private func resolveCurrentProviderPlaybackSource(
        context: PlaybackLaunchContext
    ) async -> NextEpisodePrestageResolution? {
#if os(macOS)
        if context.sourceKind == .skyStream {
            return await resolveCurrentSkyStreamPlaybackSource(context: context)
        }
#endif
        guard context.sourceKind == .service,
              let service = ServiceManager.shared.activeServices.first(where: {
                  SourceHealth.serviceId($0) == context.sourceId
              }),
              let contentHref = Self.normalizedNonemptyString(context.serviceContentHref) else {
            return nil
        }

        let isAnime = isAnimeContent()
        let originalAudioLanguage = servicesOriginalAudioLanguage
        switch mediaInfo {
        case .episode(_, let seasonNumber, let episodeNumber, _, _, _):
            return await resolveServicePrestageCandidate(
                service: service,
                knownContentHref: contentHref,
                nextSeasonNumber: seasonNumber,
                nextEpisodeNumber: episodeNumber,
                nextContext: episodePlaybackContext,
                lookupSeason: episodePlaybackContext?.resolvedTMDBSeasonNumber ?? seasonNumber,
                lookupEpisode: episodePlaybackContext?.resolvedTMDBEpisodeNumber ?? episodeNumber,
                isAnime: isAnime,
                originalAudioLanguage: originalAudioLanguage,
                titleCandidates: context.titleCandidates,
                preferredStreamName: context.streamName
            )

        case .movie:
            let jsController = JSController()
            jsController.loadScript(service.jsScript, service: service)
            let episodes = await fetchServiceEpisodes(
                jsController: jsController,
                service: service,
                contentHref: contentHref
            )
            guard isCurrent() else { return nil }
            let streamHref: String
            if let source = service.mangayomiSource {
                guard let exact = MangayomiEpisodeSelectionPolicy.matchingEpisodes(
                    episodes, sourceID: source.id, isMovie: true, seasonNumber: nil, episodeNumber: nil, context: nil
                ).first else { return nil }
                streamHref = exact.href
            } else {
                streamHref = episodes.first?.href ?? contentHref
            }
            let result = await fetchServiceStreams(
                jsController: jsController,
                service: service,
                episodeHref: streamHref
            )
            guard isCurrent(),
                  let selected = Self.selectPrewarmStream(
                      streams: result.streams,
                      sources: result.sources,
                      sourceId: context.sourceId,
                      isAnime: isAnime,
                      originalAudioLanguage: originalAudioLanguage,
                      preferredLabel: context.streamName
                  ),
                  let streamURL = Self.httpURL(selected.url) else {
                return nil
            }
            let subtitles = Self.serviceSubtitleSelection(
                entries: (selected.subtitleEntries ?? []) + (result.subtitles ?? [])
            )
            let subtitleHeaders = selected.subtitleHeadersByURL?.filter {
                subtitles.urls.contains($0.key)
            }
            return NextEpisodePrestageResolution(
                streamURL: streamURL,
                headers: Self.mergedPlaybackHeaders(
                    baseURL: service.metadata.baseUrl,
                    custom: selected.headers
                ),
                subtitles: subtitles.urls,
                subtitleNames: subtitles.names,
                subtitleHeadersByURL: subtitleHeaders?.isEmpty == false ? subtitleHeaders : nil,
                streamName: selected.label,
                sourceId: context.sourceId,
                sourceName: service.metadata.sourceName,
                sourceKind: .service,
                titleCandidates: context.titleCandidates,
                serviceContentHref: contentHref,
                providerContentReference: nil,
                externalAudioTracks: selected.externalAudioTracks
            )

        case nil:
            return nil
        }
    }

#if os(macOS)
    private func resolveCurrentSkyStreamPlaybackSource(
        context: PlaybackLaunchContext
    ) async -> NextEpisodePrestageResolution? {
        guard context.sourceKind == .skyStream,
              let providerReference = context.providerContentReference,
              providerReference.kind == .skyStream,
              providerReference.sourceID == context.sourceId,
              let reference = providerReference.skyStream,
              reference.sourceID == context.sourceId,
              reference.isStructurallyValid,
              skyStreamReferenceMatchesCurrentMedia(reference) else {
            return nil
        }

        do {
            let values = try await SkyStreamResolver.shared.refresh(
                reference,
                mode: .playbackRefresh,
                originalAudioLanguage: servicesOriginalAudioLanguage
            )
            guard isCurrent(),
                  let resolved = values.first,
                  resolved.provider.id == context.sourceId,
                  resolved.contentReference.sourceID == context.sourceId,
                  resolved.contentReference.isStructurallyValid,
                  resolved.playback.identity.packageID == reference.packageName,
                  resolved.playback.identity.providerID == (reference.providerID ?? "root"),
                  reference.scriptSHA256.map({
                    resolved.playback.identity.payloadSHA256.caseInsensitiveCompare($0) == .orderedSame
                  }) ?? true else {
                return nil
            }
            return makeSkyStreamPlaybackResolution(
                resolved,
                titleCandidates: context.titleCandidates,
                traceID: "refresh-\(context.traceID)"
            )
        } catch is CancellationError {
            return nil
        } catch {
            Logger.shared.log(
                "SkyStream: playback refresh failed source=\(context.sourceId) errorType=\(String(reflecting: type(of: error)))",
                type: "MPV"
            )
            return nil
        }
    }

    private func skyStreamReferenceMatchesCurrentMedia(
        _ reference: SkyStreamProviderContentReference
    ) -> Bool {
        switch mediaInfo {
        case .movie:
            return reference.season == nil && reference.episode == nil
        case .episode(_, let localSeason, let localEpisode, _, _, _):
            guard let referenceSeason = reference.season,
                  let referenceEpisode = reference.episode,
                  referenceSeason >= 0,
                  referenceEpisode > 0 else {
                return false
            }
            var acceptedCoordinates = Set(["\(localSeason):\(localEpisode)"])
            if let context = episodePlaybackContext {
                if let season = context.resolvedTMDBSeasonNumber,
                   let episode = context.resolvedTMDBEpisodeNumber {
                    acceptedCoordinates.insert("\(season):\(episode)")
                }
                if let absolute = context.animeAbsoluteEpisodeNumber, absolute > 0 {
                    acceptedCoordinates.insert("1:\(absolute)")
                }
            }
            return acceptedCoordinates.contains("\(referenceSeason):\(referenceEpisode)")
        case nil:
            return false
        }
    }
#endif

}
#endif
