//
//  StremioAddonManager.swift
//  Eclipse
//
//  Created by Soupy on 2026.
//

import CryptoKit
import Foundation

struct StremioResolvedDownloadTransport {
    let streamURL: String
    let headers: [String: String]
    let subtitleURL: String?
    let refreshedReference: ProviderContentReference
    /// Ephemeral user-granted authority for media hosted inside the configured
    /// addon subtree. It must be carried only by the live proxy attempt and is
    /// never encoded into DownloadItem or provider references.
    let configuredOriginAuthority: SkyStreamPinnedOriginAuthority
}

@MainActor
class StremioAddonManager: ObservableObject {
    static let shared = StremioAddonManager()

    @Published var addons: [StremioAddon] = []
    @Published var isDownloading = false
    private var catalogResolutionCache: [String: TMDBSearchResult] = [:]
    private var catalogResolutionMisses: Set<String> = []
    private static let maximumCatalogResolutionEntries = 2_000
    private var imdbResolutionCache: [String: String] = [:]

    var activeAddons: [StremioAddon] {
        addons.filter(isAddonEnabled)
    }

    var activeStreamAddons: [StremioAddon] {
        activeAddons.filter { $0.manifest.supportsStreams }
    }

    var activeSubtitleAddons: [StremioAddon] {
        guard !ContentBlockingSettings.blocksAddonSubtitles() else { return [] }
        return activeAddons.filter {
            $0.manifest.supportsSubtitles && isComponentEnabled($0, .subtitles)
        }
    }

    var activeCatalogAddons: [StremioAddon] {
        guard !ContentBlockingSettings.blocksAddonCatalogs() else { return [] }
        return activeAddons.filter {
            $0.manifest.supportsCatalogs && isComponentEnabled($0, .catalogs)
        }
    }

    func isComponentEnabled(_ addon: StremioAddon, _ component: StremioAddonComponent) -> Bool {
        StremioAddonComponentSettings.isEnabled(
            sourceID: SourceHealth.stremioId(addon),
            component: component
        )
    }

    private init() {
        loadAddons()
        NotificationCenter.default.addObserver(
            forName: ServiceStoreScope.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadAddons()
        }
    }

    func loadAddons() {
        addons = StremioAddonStore.shared.getAddons()

        catalogResolutionCache.removeAll(keepingCapacity: false)
        catalogResolutionMisses.removeAll(keepingCapacity: false)
        CatalogManager.shared.syncStremioAddonCatalogs(
            from: addons,
            activeAddonIDs: Set(addons.filter(\.isActive).map(\.id))
        )
    }

    @discardableResult
    func addAddon(from url: String) async throws -> StremioAddon {

        let scopeEpoch = ServiceStoreScope.generation
        isDownloading = true
        defer { isDownloading = false }

        let manifest = try await StremioClient.shared.fetchManifest(from: url)

        guard manifest.supportsInstallableResources else {
            throw StremioAddonError.noStreamSupport
        }

        let configuredURL = StremioClient.normalizedConfiguredURL(from: url)

        if addons.contains(where: {
            $0.manifest.id == manifest.id
                && StremioClient.normalizedConfiguredURL(from: $0.configuredURL) == configuredURL
        }) {
            throw StremioAddonError.alreadyExists
        }

        let id = generateAddonUUID(manifest: manifest, configuredURL: configuredURL)
        if addons.contains(where: { $0.id == id }) {
            throw StremioAddonError.alreadyExists
        }
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestJSON = String(data: manifestData, encoding: .utf8) ?? ""

        guard ServiceStoreScope.isCurrent(scopeEpoch) else {
            throw StremioAddonError.profileChanged
        }
        StremioAddonStore.shared.storeAddon(
            id: id,
            configuredURL: configuredURL,
            manifestJSON: manifestJSON,
            isActive: true
        )
        PlatformSourceActivation.removeOverride(sourceID: "stremio:\(id.uuidString)")
        if manifest.supportsStreams {
            AutoModeSourceSelection.appendSourceIfNeeded("stremio:\(id.uuidString)")
        }

        loadAddons()
        Logger.shared.log("Stremio: Added addon", type: "Stremio")
        return addons.first(where: { $0.id == id }) ?? StremioAddon(
            id: id,
            configuredURL: configuredURL,
            manifest: manifest,
            isActive: true,
            sortIndex: Int64(addons.count)
        )
    }

    func removeAddon(_ addon: StremioAddon) {
        StremioAddonStore.shared.remove(addon)
        PlatformSourceActivation.removeOverride(sourceID: SourceHealth.stremioId(addon))

        SourceHealthStore.shared.removeRecord(sourceId: SourceHealth.stremioId(addon))
        loadAddons()
    }

    func setAddonState(_ addon: StremioAddon, isActive: Bool) {
#if os(tvOS)
        PlatformSourceActivation.setEnabled(isActive, sourceID: SourceHealth.stremioId(addon))
        loadAddons()
#else
        let manifestData = (try? JSONEncoder().encode(addon.manifest)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        StremioAddonStore.shared.storeAddon(
            id: addon.id,
            configuredURL: addon.configuredURL,
            manifestJSON: manifestData,
            isActive: isActive
        )
        loadAddons()
#endif
    }

    func isAddonEnabled(_ addon: StremioAddon) -> Bool {
        PlatformSourceActivation.isEnabled(
            sourceID: SourceHealth.stremioId(addon),
            sharedValue: addon.isActive
        )
    }

    func reconfigureAddon(
        _ addon: StremioAddon,
        newURL: String,
        requiredScopeGeneration: Int? = nil
    ) async throws {
        let scopeEpoch = requiredScopeGeneration ?? ServiceStoreScope.generation
        try Task.checkCancellation()
        guard ServiceStoreScope.isCurrent(scopeEpoch) else {
            throw StremioAddonError.profileChanged
        }
        let manifest = try await StremioClient.shared.fetchManifest(from: newURL)

        guard manifest.supportsInstallableResources else {
            throw StremioAddonError.noStreamSupport
        }

        let configuredURL = StremioClient.normalizedConfiguredURL(from: newURL)

        let manifestData = try JSONEncoder().encode(manifest)
        let manifestJSON = String(data: manifestData, encoding: .utf8) ?? ""

        try Task.checkCancellation()
        guard ServiceStoreScope.isCurrent(scopeEpoch) else {
            throw StremioAddonError.profileChanged
        }
        StremioAddonStore.shared.storeAddon(
            id: addon.id,
            configuredURL: configuredURL,
            manifestJSON: manifestJSON,
            isActive: addon.isActive
        )

        let sourceId = "stremio:\(addon.id.uuidString)"
        if manifest.supportsStreams {
            AutoModeSourceSelection.appendSourceIfNeeded(sourceId)
        } else {
            AutoModeSourceSelection.removeSource(sourceId)
        }

        loadAddons()
        Logger.shared.log("Stremio: Reconfigured addon", type: "Stremio")
    }

    func moveAddons(fromOffsets: IndexSet, toOffset: Int) {
        var mutable = addons
        mutable.move(fromOffsets: fromOffsets, toOffset: toOffset)

        let entities = StremioAddonStore.shared.getEntities()
        for (index, addon) in mutable.enumerated() {
            if let entity = entities.first(where: { $0.id == addon.id }) {
                entity.sortIndex = Int64(index)
            }
        }

        StremioAddonStore.shared.save()
        loadAddons()
    }

    func refreshAddons() async {

        let scopeEpoch = ServiceStoreScope.generation
        for addon in addons {
            do {
                let manifest = try await StremioClient.shared.fetchManifest(from: addon.configuredURL)
                guard ServiceStoreScope.isCurrent(scopeEpoch) else {
                    Logger.shared.log(
                        "Stremio: abandoned refresh, the services store moved",
                        type: "Stremio"
                    )
                    return
                }
                let manifestData = try JSONEncoder().encode(manifest)
                let manifestJSON = String(data: manifestData, encoding: .utf8) ?? ""

                StremioAddonStore.shared.storeAddon(
                    id: addon.id,
                    configuredURL: addon.configuredURL,
                    manifestJSON: manifestJSON,
                    isActive: addon.isActive
                )

                Logger.shared.log("Stremio: Refreshed addon", type: "Stremio")
            } catch {
                Logger.shared.log(
                    "Stremio: Addon refresh failed reason=\(servicePinnedNetworkErrorToken(error))",
                    type: "Stremio"
                )
            }
        }

        loadAddons()
    }

    struct AddonStreamResult: Identifiable {
        let id = UUID()
        let addon: StremioAddon
        let streams: [StremioStream]
    }

    struct AddonSubtitleResult: Identifiable {
        let id = UUID()
        let addon: StremioAddon
        let subtitle: StremioSubtitle
    }

    /// Re-resolves a durable Stremio selection under its original profile and
    /// service-store authority. Only the addon request and selection intent are
    /// persisted; every media URL/header is freshly returned for one protected
    /// download attempt.
    func resolveDownloadTransport(
        reference: ProviderContentReference,
        ownerProfileID: UUID,
        serviceStoreGeneration: Int
    ) async -> StremioResolvedDownloadTransport? {
        guard reference.hasValidStremioSelection,
              ProfileManager.shared.activeProfileID == ownerProfileID,
              ServiceStoreScope.generation == serviceStoreGeneration,
              let sourceUUID = UUID(
                uuidString: String(reference.sourceID.dropFirst("stremio:".count))
              ),
              let contentType = reference.stremioContentType,
              let contentID = reference.stremioContentID,
              reference.stremioStreamOrdinal != nil,
              let addon = addons.first(where: { $0.id == sourceUUID }),
              isAddonEnabled(addon),
              addon.manifest.supportsStreams else {
            return nil
        }

        let configuredURL = addon.configuredURL
        guard let configuredOriginAuthority = try? SkyStreamPinnedOriginAuthority.stremio(
            configuredBaseURL: configuredURL
        ) else {
            return nil
        }
        let streams: [StremioStream]
        do {
            streams = try await StremioClient.shared.fetchStreams(
                baseURL: configuredURL,
                type: contentType,
                id: contentID
            )
        } catch {
            Logger.shared.log(
                "Stremio: Protected download re-resolution failed reason=\(servicePinnedNetworkErrorToken(error))",
                type: "Download"
            )
            return nil
        }

        guard ProfileManager.shared.activeProfileID == ownerProfileID,
              ServiceStoreScope.generation == serviceStoreGeneration,
              let currentAddon = addons.first(where: { $0.id == sourceUUID }),
              currentAddon.configuredURL == configuredURL,
              isAddonEnabled(currentAddon) else {
            return nil
        }

        let selected = reference.selectStremioStream(from: streams)
        guard let selected,
              selected.isDirectHTTP,
              let streamURL = selected.url else {
            return nil
        }
        let sanitizedHeaders = Self.boundedDownloadHeaders(selected.proxyHeaders ?? [:])

        let subtitleURL: String?
        let refreshedSubtitleOrdinal: Int?
        if let subtitles = selected.subtitles,
           let subtitleOrdinal = reference.selectStremioSubtitleIndex(from: subtitles),
           let candidate = subtitles[subtitleOrdinal].url,
           let parsed = URL(string: candidate),
           let scheme = parsed.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            subtitleURL = candidate
            refreshedSubtitleOrdinal = subtitleOrdinal
        } else {
            subtitleURL = nil
            refreshedSubtitleOrdinal = nil
        }

        guard let refreshedReference = ProviderContentReference.stremio(
            addonID: sourceUUID,
            stream: selected,
            subtitleOrdinal: refreshedSubtitleOrdinal
        ) else {
            return nil
        }
        return StremioResolvedDownloadTransport(
            streamURL: streamURL,
            headers: sanitizedHeaders,
            subtitleURL: subtitleURL,
            refreshedReference: refreshedReference,
            configuredOriginAuthority: configuredOriginAuthority
        )
    }

    private static func logDroppedDownloadHeaders(
        _ names: [String],
        unusable: [String],
        hostManaged: [String]
    ) {
        if !hostManaged.isEmpty {
            Logger.shared.log(
                "Stremio download headers removed as host-managed names=[\(hostManaged.sorted().joined(separator: ","))];"
                    + " the transport writes its own value for these, so the addon's version never reaches the wire",
                type: "Stremio"
            )
        }
        if !names.isEmpty {
            Logger.shared.log(
                "Stremio download headers dropped by Eclipse droppedKeys=[\(names.sorted().joined(separator: ","))]"
                    + " caps=64/128B/16KiB/64KiB; a 403 on the download after this is Eclipse's header set, not the addon's",
                type: "Stremio"
            )
        }
        if !unusable.isEmpty {
            Logger.shared.log(
                "Stremio download headers unusable names=[\(unusable.sorted().joined(separator: ","))];"
                    + " the addon supplied a header name or value Eclipse cannot put on the wire, so this is the addon's data, not an Eclipse cap",
                type: "Stremio"
            )
        }
    }

    private static func boundedDownloadHeaders(_ headers: [String: String]) -> [String: String] {
        let managedNames: Set<String> = [
            "accept-encoding", "connection", "content-length", "host", "keep-alive",
            "proxy-authenticate", "proxy-authorization", "proxy-connection", "te",
            "trailer", "transfer-encoding", "upgrade"
        ]
        let validNameCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        var accepted: [String: String] = [:]
        var totalBytes = 0
        var droppedNames: [String] = []
        var unusableNames: [String] = []
        var hostManagedNames: [String] = []
        for (rawName, rawValue) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameIsValid = !name.isEmpty && name.unicodeScalars.allSatisfy {
                $0.value < 128 && validNameCharacters.contains($0)
            }
            let valueIsValid = value.unicodeScalars.allSatisfy {
                $0.value == 9 || $0.value >= 32 && $0.value != 127
            }
            let entryBytes = name.utf8.count + value.utf8.count + 4
            guard accepted.count < 64,
                  name.utf8.count <= 128,
                  value.utf8.count <= 16 * 1_024,
                  entryBytes <= 64 * 1_024 - totalBytes,
                  nameIsValid,
                  valueIsValid,
                  !managedNames.contains(name.lowercased()) else {
                if !name.isEmpty,
                   nameIsValid,
                   valueIsValid,
                   !managedNames.contains(name.lowercased()) {
                    droppedNames.append(name.lowercased())
                } else if managedNames.contains(name.lowercased()) {
                    hostManagedNames.append(name.lowercased())
                } else {
                    unusableNames.append(name.isEmpty ? "<empty>" : name.lowercased())
                }
                continue
            }
            accepted[name] = value
            totalBytes += entryBytes
        }
        logDroppedDownloadHeaders(
            droppedNames,
            unusable: unusableNames,
            hostManaged: hostManagedNames
        )
        return accepted
    }

    private struct RankedCatalogMeta {
        let catalog: StremioCatalog
        let meta: StremioMetaPreview
        let score: Double
        let query: String
    }

    func fetchStreamsFromAddons(
        tmdbId: Int,
        imdbId: String?,
        type: String,
        season: Int?,
        episode: Int?,
        anilistId: Int? = nil,
        playbackContext: EpisodePlaybackContext? = nil,
        titleCandidates: [String] = [],
        expectedYear: Int? = nil,
        onResult: @MainActor @escaping (StremioAddon, [StremioStream]) -> Void,
        onOutcome: @MainActor @escaping (StremioAddon, StremioAddonOutcome) -> Void = { _, _ in },
        onComplete: @MainActor @escaping () -> Void
    ) async {
        guard let lookupCoordinates = Self.safeLookupCoordinates(
            type: type,
            season: season,
            episode: episode,
            playbackContext: playbackContext
        ) else {
            Logger.shared.log("Stremio: Skipping MAL fallback stream lookup without exact TMDB coordinates", type: "Stremio")
            onComplete()
            return
        }
        let active = activeStreamAddons
        Logger.shared.log("Stremio: Fetching streams from \(active.count) active addon(s)", type: "Stremio")
        guard !active.isEmpty else {
            Logger.shared.log("Stremio: No active stream addons, skipping", type: "Stremio")
            onComplete()
            return
        }

        let client = StremioClient.shared
        async let resolvedIMDbIDTask = resolveIMDbID(
            tmdbId: tmdbId,
            providedIMDbID: imdbId,
            type: type
        )
        async let effectivePlaybackContextTask = Self.enrichedPlaybackContextForKitsuIfNeeded(
            playbackContext,
            addons: active,
            type: type,
            titleCandidates: titleCandidates,
            expectedYear: expectedYear
        )
        let (resolvedIMDbID, effectivePlaybackContext) = await (
            resolvedIMDbIDTask,
            effectivePlaybackContextTask
        )
        let maxConcurrent = 2

        await withTaskGroup(of: (StremioAddon, [StremioStream], StremioAddonOutcome)?.self) { group in
            var nextIndex = 0

            while nextIndex < active.count && nextIndex < maxConcurrent {
                let addon = active[nextIndex]
                group.addTask {
                    await Self.fetchStreamsForAddon(
                        addon,
                        client: client,
                        tmdbId: tmdbId,
                        imdbId: resolvedIMDbID,
                        type: type,
                        season: lookupCoordinates.season,
                        episode: lookupCoordinates.episode,
                        anilistId: anilistId,
                        playbackContext: effectivePlaybackContext,
                        titleCandidates: titleCandidates,
                        expectedYear: expectedYear
                    )
                }
                nextIndex += 1
            }

            for await result in group {
                if let (addon, streams, outcome) = result {
                    await MainActor.run {
                        onResult(addon, streams)
                        onOutcome(addon, outcome)
                    }
                }

                if nextIndex < active.count {
                    let addon = active[nextIndex]
                    group.addTask {
                        await Self.fetchStreamsForAddon(
                            addon,
                            client: client,
                            tmdbId: tmdbId,
                            imdbId: resolvedIMDbID,
                            type: type,
                            season: lookupCoordinates.season,
                            episode: lookupCoordinates.episode,
                            anilistId: anilistId,
                            playbackContext: effectivePlaybackContext,
                            titleCandidates: titleCandidates,
                            expectedYear: expectedYear
                        )
                    }
                    nextIndex += 1
                }
            }
        }

        onComplete()
    }

    func fetchStreamsFromAddon(
        _ addon: StremioAddon,
        tmdbId: Int,
        imdbId: String?,
        type: String,
        season: Int?,
        episode: Int?,
        anilistId: Int? = nil,
        playbackContext: EpisodePlaybackContext? = nil,
        titleCandidates: [String] = [],
        expectedYear: Int? = nil
    ) async -> [StremioStream] {
        guard addon.manifest.supportsStreams else {
            Logger.shared.log("Stremio: Skipping stream fetch for subtitle-only addon", type: "Stremio")
            return []
        }
        guard let lookupCoordinates = Self.safeLookupCoordinates(
            type: type,
            season: season,
            episode: episode,
            playbackContext: playbackContext
        ) else {
            Logger.shared.log("Stremio: Skipping MAL fallback stream lookup without exact TMDB coordinates", type: "Stremio")
            return []
        }

        async let resolvedIMDbIDTask = resolveIMDbID(
            tmdbId: tmdbId,
            providedIMDbID: imdbId,
            type: type
        )
        async let effectivePlaybackContextTask = Self.enrichedPlaybackContextForKitsuIfNeeded(
            playbackContext,
            addons: [addon],
            type: type,
            titleCandidates: titleCandidates,
            expectedYear: expectedYear
        )
        let (resolvedIMDbID, effectivePlaybackContext) = await (
            resolvedIMDbIDTask,
            effectivePlaybackContextTask
        )

        return await Self.resolveStreamsForAddon(
            addon,
            client: StremioClient.shared,
            tmdbId: tmdbId,
            imdbId: resolvedIMDbID,
            type: type,
            season: lookupCoordinates.season,
            episode: lookupCoordinates.episode,
            anilistId: anilistId,
            playbackContext: effectivePlaybackContext,
            titleCandidates: titleCandidates,
            expectedYear: expectedYear
        ).streams
    }

    func fetchSubtitlesFromAddons(
        tmdbId: Int,
        imdbId: String?,
        type: String,
        season: Int?,
        episode: Int?,
        anilistId: Int? = nil,
        playbackContext: EpisodePlaybackContext? = nil,
        titleCandidates: [String] = [],
        expectedYear: Int? = nil
    ) async -> [AddonSubtitleResult] {
        guard let lookupCoordinates = Self.safeLookupCoordinates(
            type: type,
            season: season,
            episode: episode,
            playbackContext: playbackContext
        ) else {
            Logger.shared.log("Stremio: Skipping MAL fallback subtitle lookup without exact TMDB coordinates", type: "Stremio")
            return []
        }
        let active = activeSubtitleAddons.filter { addon in
            addon.manifest.supportsResource("subtitles", type: type)
        }
        Logger.shared.log("Stremio: Fetching subtitles from \(active.count) active addon(s)", type: "Stremio")
        guard !active.isEmpty else { return [] }

        let client = StremioClient.shared
        async let resolvedIMDbIDTask = resolveIMDbID(
            tmdbId: tmdbId,
            providedIMDbID: imdbId,
            type: type
        )
        async let effectivePlaybackContextTask = Self.enrichedPlaybackContextForKitsuIfNeeded(
            playbackContext,
            addons: active,
            type: type,
            titleCandidates: titleCandidates,
            expectedYear: expectedYear,
            resourceName: "subtitles"
        )
        let (resolvedIMDbID, effectivePlaybackContext) = await (
            resolvedIMDbIDTask,
            effectivePlaybackContextTask
        )
        let maxConcurrent = 2

        var results: [AddonSubtitleResult] = []
        await withTaskGroup(of: (StremioAddon, [StremioSubtitle]).self) { group in
            var nextIndex = 0

            while nextIndex < active.count && nextIndex < maxConcurrent {
                let addon = active[nextIndex]
                group.addTask {
                    let subtitles = await Self.resolveSubtitlesForAddon(
                        addon,
                        client: client,
                        tmdbId: tmdbId,
                        imdbId: resolvedIMDbID,
                        type: type,
                        season: lookupCoordinates.season,
                        episode: lookupCoordinates.episode,
                        anilistId: anilistId,
                        playbackContext: effectivePlaybackContext
                    )
                    return (addon, subtitles)
                }
                nextIndex += 1
            }

            for await (addon, subtitles) in group {
                results.append(contentsOf: subtitles.map { subtitle in
                    AddonSubtitleResult(addon: addon, subtitle: subtitle)
                })

                if nextIndex < active.count {
                    let addon = active[nextIndex]
                    group.addTask {
                        let subtitles = await Self.resolveSubtitlesForAddon(
                            addon,
                            client: client,
                            tmdbId: tmdbId,
                            imdbId: resolvedIMDbID,
                            type: type,
                            season: lookupCoordinates.season,
                            episode: lookupCoordinates.episode,
                            anilistId: anilistId,
                            playbackContext: effectivePlaybackContext
                        )
                        return (addon, subtitles)
                    }
                    nextIndex += 1
                }
            }
        }

        return Self.dedupeSubtitleResults(results)
    }

    func fetchCatalogItems(for catalog: Catalog, tmdbService: TMDBService, limit: Int = 15) async -> [TMDBSearchResult] {
        guard catalog.source == .stremio,
              let addonId = catalog.stremioAddonId,
              let catalogId = catalog.stremioCatalogId,
              let catalogType = catalog.stremioCatalogType else {
            return []
        }

        guard CatalogManager.shared.isCatalogEnabled(id: catalog.id) else {
            Logger.shared.log("Stremio: Catalog skipped because it is disabled", type: "Stremio")
            return []
        }

        guard let addon = activeCatalogAddons.first(where: { $0.id == addonId }) else {
            Logger.shared.log("Stremio: Catalog skipped because addon is inactive or missing", type: "Stremio")
            return []
        }

        guard let stremioCatalog = addon.manifest.homeCatalogs.first(where: {
            $0.id == catalogId && $0.type == catalogType
        }) else {
            Logger.shared.log("Stremio: Catalog skipped because manifest no longer exposes a compatible feed", type: "Stremio")
            return []
        }

        do {
            let metas = try await StremioClient.shared.fetchCatalogMetas(
                baseURL: addon.configuredURL,
                catalog: stremioCatalog,
                skip: stremioCatalog.shouldSendInitialSkip ? 0 : nil
            )
            guard CatalogManager.shared.isCatalogEnabled(id: catalog.id) else {
                Logger.shared.log("Stremio: Discarded catalog response because it was disabled during fetch", type: "Stremio")
                return []
            }
            let results = await resolveCatalogMetas(
                metas,
                catalog: stremioCatalog,
                addon: addon,
                tmdbService: tmdbService,
                limit: limit
            )
            guard CatalogManager.shared.isCatalogEnabled(id: catalog.id) else {
                Logger.shared.log("Stremio: Discarded catalog results because it was disabled during resolution", type: "Stremio")
                return []
            }
            Logger.shared.log("Stremio: Catalog resolved \(results.count) item(s) from \(metas.count) meta preview(s)", type: "Stremio")
            return results
        } catch {
            Logger.shared.log(
                "Stremio: Catalog fetch failed reason=\(servicePinnedNetworkErrorToken(error))",
                type: "Stremio"
            )
            return []
        }
    }

    private func resolveCatalogMetas(
        _ metas: [StremioMetaPreview],
        catalog: StremioCatalog,
        addon: StremioAddon,
        tmdbService: TMDBService,
        limit: Int
    ) async -> [TMDBSearchResult] {
        var results: [TMDBSearchResult] = []
        var seen = Set<String>()
        let candidateLimit = max(limit * 2, limit)

        for meta in metas.prefix(candidateLimit) {
            if Task.isCancelled { break }
            guard let result = await resolveCatalogMeta(meta, catalog: catalog, addon: addon, tmdbService: tmdbService),
                  seen.insert(result.stableIdentity).inserted else {
                continue
            }
            results.append(result)
            if results.count >= limit { break }
        }

        return results
    }

    private func resolveCatalogMeta(
        _ meta: StremioMetaPreview,
        catalog: StremioCatalog,
        addon: StremioAddon,
        tmdbService: TMDBService
    ) async -> TMDBSearchResult? {
        guard let mediaType = Self.eclipseMediaType(from: meta.type) ?? catalog.eclipseMediaType else {
            return nil
        }

        let cacheKey = "\(addon.id.uuidString)|\(catalog.id)|\(mediaType)|\(meta.id)"
        if let cached = catalogResolutionCache[cacheKey] {
            return cached
        }
        if catalogResolutionMisses.contains(cacheKey) {
            return nil
        }

        if let tmdbId = meta.tmdbId ?? Self.tmdbId(from: meta.id) {
            let result = Self.searchResult(
                from: meta,
                tmdbId: tmdbId,
                mediaType: mediaType,
                isAnimeHint: Self.isAnimeCatalogMeta(meta, catalog: catalog)
            )
            if catalogResolutionCache.count < Self.maximumCatalogResolutionEntries {
                catalogResolutionCache[cacheKey] = result
            }
            return result
        }

        if let imdbId = StremioClient.normalizedIMDbID(meta.imdbId ?? Self.imdbId(from: meta.id)) {
            do {
                if let result = try await tmdbService.findByIMDbId(imdbId, preferredMediaType: mediaType) {
                    if catalogResolutionCache.count < Self.maximumCatalogResolutionEntries {
                        catalogResolutionCache[cacheKey] = result
                    }
                    return result
                }
            } catch {
                Logger.shared.log(
                    "Stremio: Catalog meta IMDb resolution failed reason=\(servicePinnedNetworkErrorToken(error))",
                    type: "Stremio"
                )

                return nil
            }
        }

        if catalogResolutionMisses.count < Self.maximumCatalogResolutionEntries {
            catalogResolutionMisses.insert(cacheKey)
        }
        return nil
    }

    private static func eclipseMediaType(from stremioType: String?) -> String? {
        guard let stremioType else { return nil }
        let normalized = stremioType.lowercased()
        if normalized == "movie" { return "movie" }
        if normalized == "series" || normalized == "tv" || normalized == "anime" { return "tv" }
        return nil
    }

    private static func tmdbId(from stremioId: String) -> Int? {
        let lowercased = stremioId.lowercased()
        let prefixes = ["tmdb:", "tmdb_id:"]
        for prefix in prefixes where lowercased.hasPrefix(prefix) {
            let remainder = String(stremioId.dropFirst(prefix.count))
            for component in remainder.split(separator: ":") {
                if let id = Int(component) {
                    return id
                }
            }
        }
        return nil
    }

    private static func imdbId(from stremioId: String) -> String? {
        let pattern = #"^tt\d+"#
        guard let range = stremioId.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(stremioId[range])
    }

    private static func searchResult(
        from meta: StremioMetaPreview,
        tmdbId: Int,
        mediaType: String,
        isAnimeHint: Bool
    ) -> TMDBSearchResult {
        let releaseDate = catalogDate(from: meta.released) ?? meta.releaseInfo
        let rating = Double(meta.imdbRating ?? "")
        return TMDBSearchResult(
            id: tmdbId,
            mediaType: mediaType,
            title: mediaType == "movie" ? meta.name : nil,
            name: mediaType == "tv" ? meta.name : nil,
            overview: meta.description,
            posterPath: meta.poster,
            backdropPath: meta.background,
            releaseDate: mediaType == "movie" ? releaseDate : nil,
            firstAirDate: mediaType == "tv" ? releaseDate : nil,
            voteAverage: rating,
            popularity: 0,
            adult: nil,
            genreIds: isAnimeHint ? [16] : nil,
            isAnimeHint: isAnimeHint
        )
    }

    private static func isAnimeCatalogMeta(
        _ meta: StremioMetaPreview,
        catalog: StremioCatalog
    ) -> Bool {
        guard (eclipseMediaType(from: meta.type) ?? catalog.eclipseMediaType) == "tv" else {
            return false
        }
        let labels = (meta.genres ?? []) + [catalog.id, catalog.name ?? ""]
        return labels.contains { label in
            label.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .contains("anime")
        }
    }

    private static func catalogDate(from value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.count >= 10 {
            return String(value.prefix(10))
        }
        return value
    }

    private func resolveIMDbID(
        tmdbId: Int,
        providedIMDbID: String?,
        type: String
    ) async -> String? {
        let normalizedType = type.lowercased()
        let cacheType = normalizedType == "movie" ? "movie" : "series"
        let cacheKey = "\(cacheType)|\(tmdbId)"

        if let provided = StremioClient.normalizedIMDbID(providedIMDbID) {
            imdbResolutionCache[cacheKey] = provided
            return provided
        }
        if let cached = imdbResolutionCache[cacheKey] {
            return cached
        }
        guard tmdbId > 0 else { return nil }

        do {
            let resolved: String?
            switch normalizedType {
            case "movie":
                resolved = try await TMDBService.shared.getMovieDetails(id: tmdbId).imdbId
            case "series", "tv":
                resolved = try await TMDBService.shared.getTVShowDetails(id: tmdbId).externalIds?.imdbId
            default:
                resolved = nil
            }

            guard let normalized = StremioClient.normalizedIMDbID(resolved) else {
                Logger.shared.log("Stremio: TMDB-to-IMDb fallback found no IMDb ID", type: "Stremio")
                return nil
            }

            imdbResolutionCache[cacheKey] = normalized
            Logger.shared.log("Stremio: TMDB-to-IMDb fallback resolved", type: "Stremio")
            return normalized
        } catch {
            Logger.shared.log(
                "Stremio: TMDB-to-IMDb fallback failed reason=\(servicePinnedNetworkErrorToken(error))",
                type: "Stremio"
            )
            return nil
        }
    }

    private static func fetchStreamsForAddon(
        _ addon: StremioAddon,
        client: StremioClient,
        tmdbId: Int,
        imdbId: String?,
        type: String,
        season: Int?,
        episode: Int?,
        anilistId: Int?,
        playbackContext: EpisodePlaybackContext?,
        titleCandidates: [String],
        expectedYear: Int?
    ) async -> (StremioAddon, [StremioStream], StremioAddonOutcome)? {
        let resolution = await resolveStreamsForAddon(
            addon,
            client: client,
            tmdbId: tmdbId,
            imdbId: imdbId,
            type: type,
            season: season,
            episode: episode,
            anilistId: anilistId,
            playbackContext: playbackContext,
            titleCandidates: titleCandidates,
            expectedYear: expectedYear
        )
        Logger.shared.log(
            "Stremio: Addon ledger endpoint=\(StremioClient.redactedEndpointDescription(from: addon.configuredURL)) outcome=\(resolution.outcome.diagnosticToken) streams=\(resolution.streams.count)",
            type: "Stremio"
        )
        return (addon, resolution.streams, resolution.outcome)
    }

    private static func enrichedPlaybackContextForKitsuIfNeeded(
        _ playbackContext: EpisodePlaybackContext?,
        addons: [StremioAddon],
        type: String,
        titleCandidates: [String],
        expectedYear: Int?,
        resourceName: String = "stream"
    ) async -> EpisodePlaybackContext? {
        guard type == "series",
              let playbackContext,
              playbackContext.kitsuMediaId == nil,
              playbackContext.positiveAniListMediaId != nil,
              !playbackContext.isSpecial,
              !playbackContext.titleOnlySearch,
              addons.contains(where: { supportsKitsuContentIds($0, resourceName: resourceName) }),
              !titleCandidates.isEmpty else {
            return playbackContext
        }

        let kitsuId = await KitsuAnimeIDLookup.shared.resolveAnimeId(
            titleCandidates: titleCandidates,
            expectedEpisodeCount: playbackContext.animeSeasonEpisodeCount,
            expectedYear: expectedYear,
            cacheHint: playbackContext.positiveAniListMediaId
        )

        guard let kitsuId else {
            Logger.shared.log("Stremio: Kitsu lookup found no safe match", type: "Stremio")
            return playbackContext
        }

        Logger.shared.log("Stremio: Kitsu lookup resolved", type: "Stremio")
        return playbackContext.withKitsuMediaId(kitsuId)
    }

    private static func supportsKitsuContentIds(_ addon: StremioAddon, resourceName: String) -> Bool {
        let prefixes = resourceName == "subtitles"
            ? (addon.manifest.subtitleIdPrefixes ?? [])
            : (addon.manifest.streamIdPrefixes ?? [])
        return explicitlySupportsKitsuContentIds(prefixes)
    }

    private static func safeLookupCoordinates(
        type: String,
        season: Int?,
        episode: Int?,
        playbackContext: EpisodePlaybackContext?
    ) -> (season: Int?, episode: Int?)? {
        guard type == "series",
              let context = playbackContext,
              context.hasAnimeMediaId else {
            return (season, episode)
        }
        // Only ever UPGRADE a coordinate to the AniMap-resolved one. Withholding it entirely
        // contacted zero addons for a MAL-only id, and returning (nil, nil) made every
        // IMDb/TMDB-only addon (Comet, MediaFusion, Jackettio, AIOStreams) unreachable for any
        // anime with no episode-level AniMap mapping. The caller's numbers are TMDB's own.
        return (
            context.resolvedTMDBSeasonNumber ?? season,
            context.resolvedTMDBEpisodeNumber ?? episode
        )
    }

    static func explicitlySupportsKitsuContentIds(_ prefixes: [String]?) -> Bool {
        guard let prefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains { prefix in
            let normalized = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "kitsu" || normalized == "kitsu:"
        }
    }

    private static func resolveStreamsForAddon(
        _ addon: StremioAddon,
        client: StremioClient,
        tmdbId: Int,
        imdbId: String?,
        type: String,
        season: Int?,
        episode: Int?,
        anilistId: Int?,
        playbackContext: EpisodePlaybackContext?,
        titleCandidates: [String],
        expectedYear: Int?
    ) async -> (streams: [StremioStream], outcome: StremioAddonOutcome) {
        guard addon.manifest.supportsStreams else {
            return ([], .noResults)
        }
        Logger.shared.log(
            "Stremio: Starting addon fetch endpoint=\(StremioClient.redactedEndpointDescription(from: addon.configuredURL))",
            type: "Stremio"
        )

        let contentIds = client.buildContentIds(
            tmdbId: tmdbId,
            imdbId: imdbId,
            type: type,
            season: season,
            episode: episode,
            anilistId: anilistId,
            anilistSeason: animeLocalStremioSeason(from: playbackContext),
            anilistEpisode: animeLocalStremioEpisode(from: playbackContext),
            kitsuId: playbackContext?.kitsuMediaId,
            kitsuEpisode: animeLocalKitsuEpisode(from: playbackContext),
            alternateSeason: animeLocalSeriesSeason(from: playbackContext),
            alternateEpisode: animeLocalSeriesEpisode(from: playbackContext),
            allowParentSeriesIDs: true,
            addon: addon
        )

        var lastError: Error?
        var directStreams: [StremioStream] = []
        var directHitCount = 0
        var torrentOnlyCount = 0
        var externalOnlyCount = 0

        func resolution(for streams: [StremioStream]) -> (streams: [StremioStream], outcome: StremioAddonOutcome) {
            if !streams.isEmpty {
                return (streams, .results(count: streams.count))
            }
            if torrentOnlyCount > 0 {
                return ([], .unplayableOnly(count: torrentOnlyCount))
            }
            if externalOnlyCount > 0 {
                return ([], .externalOnly(count: externalOnlyCount))
            }
            if let lastError {
                if let eclipseRefusal = eclipseRefusalReason(lastError) {
                    Logger.shared.log(
                        "Stremio addon=\(addon.manifest.name) returned nothing because Eclipse refused its response: \(eclipseRefusal). This empty result is an Eclipse problem, not a dead addon.",
                        type: "Stremio"
                    )
                    return ([], .appFailure(eclipseRefusal))
                }
                return ([], .addonError(addonErrorReason(lastError)))
            }
            return ([], .noResults)
        }

        for (candidateIndex, contentId) in contentIds.enumerated() {
            if Task.isCancelled {
                Logger.shared.log("Stremio: Cancelled lookup before candidate \(candidateIndex + 1)/\(contentIds.count)", type: "Stremio")
                return resolution(for: dedupeStreams(directStreams))
            }
            Logger.shared.log(
                "Stremio: Requesting stream candidate \(candidateIndex + 1)/\(contentIds.count) contentIDBytes=\(contentId.utf8.count)",
                type: "Stremio"
            )

            do {
                let fetched = try await client.fetchStreamOutcome(
                    baseURL: addon.configuredURL,
                    type: type,
                    id: contentId,
                    retryEmptyResponse: candidateIndex == 0
                )
                let streams = fetched.streams
                torrentOnlyCount = max(torrentOnlyCount, fetched.torrentOnlyCount)
                externalOnlyCount = max(externalOnlyCount, fetched.externalOnlyCount)
                Logger.shared.log("Stremio: Stream candidate returned \(streams.count) stream(s)", type: "Stremio")
                if !streams.isEmpty {
                    directHitCount += 1
                    directStreams.append(contentsOf: streams)
                }
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    Logger.shared.log("Stremio: Cancelled lookup while requesting candidate \(candidateIndex + 1)/\(contentIds.count)", type: "Stremio")
                    return resolution(for: dedupeStreams(directStreams))
                }
                lastError = error
                Logger.shared.log(
                    "Stremio: Stream candidate failed reason=\(servicePinnedNetworkErrorToken(error))",
                    type: "Stremio"
                )
            }
        }

        let dedupedDirectStreams = dedupeStreams(directStreams)
        if !dedupedDirectStreams.isEmpty {
            Logger.shared.log("Stremio: Merged \(dedupedDirectStreams.count) stream(s) from \(directHitCount) direct content ID(s)", type: "Stremio")
            return (dedupedDirectStreams, .results(count: dedupedDirectStreams.count))
        }

        if contentIds.isEmpty {
            Logger.shared.log("Stremio: No direct content ID; trying catalog fallback if available", type: "Stremio")
        } else if let lastError {
            Logger.shared.log(
                "Stremio: Exhausted content IDs reason=\(servicePinnedNetworkErrorToken(lastError))",
                type: "Stremio"
            )
        }

        let fallbackStreams = await fetchStreamsByCatalogSearch(
            addon,
            client: client,
            requestedType: type,
            season: season,
            episode: episode,
            playbackContext: playbackContext,
            titleCandidates: titleCandidates,
            expectedYear: expectedYear
        )
        if !fallbackStreams.isEmpty {
            return (fallbackStreams, .results(count: fallbackStreams.count))
        }

        return resolution(for: [])
    }

    private static func eclipseRefusalReason(_ error: Error?) -> String? {
        guard let error else { return nil }
        if error is BoundedURLSessionError {
            return "the response was larger than Eclipse's own limit"
        }
        if let compatibility = error as? ServiceCompatibilityError,
           compatibility == .responseTooLarge {
            return "the response was larger than Eclipse's own limit"
        }
        if let envelope = error as? SkyStreamJSONEnvelopeError {
            switch envelope {
            case .excessiveDepth, .excessiveTokens, .excessiveContainerValues, .excessiveTokenBytes:
                return "its response went past Eclipse's own JSON envelope limits"
            case .empty, .malformedStructure:
                return nil
            }
        }
        return nil
    }

    private static func addonErrorReason(_ error: Error) -> String {
        if let compatibility = error as? ServiceCompatibilityError {
            return compatibility.localizedDescription
        }
        if let stremioError = error as? StremioClient.StremioError {
            return stremioError.localizedDescription
        }
        return ""
    }

    private static func resolveSubtitlesForAddon(
        _ addon: StremioAddon,
        client: StremioClient,
        tmdbId: Int,
        imdbId: String?,
        type: String,
        season: Int?,
        episode: Int?,
        anilistId: Int?,
        playbackContext: EpisodePlaybackContext?
    ) async -> [StremioSubtitle] {
        guard addon.manifest.supportsSubtitles,
              addon.manifest.supportsResource("subtitles", type: type) else {
            return []
        }
        let contentIds = client.buildContentIds(
            tmdbId: tmdbId,
            imdbId: imdbId,
            type: type,
            season: season,
            episode: episode,
            anilistId: anilistId,
            anilistSeason: animeLocalStremioSeason(from: playbackContext),
            anilistEpisode: animeLocalStremioEpisode(from: playbackContext),
            kitsuId: playbackContext?.kitsuMediaId,
            kitsuEpisode: animeLocalKitsuEpisode(from: playbackContext),
            alternateSeason: animeLocalSeriesSeason(from: playbackContext),
            alternateEpisode: animeLocalSeriesEpisode(from: playbackContext),
            allowParentSeriesIDs: true,
            idPrefixes: addon.manifest.subtitleIdPrefixes,
            addonName: addon.manifest.name
        )

        guard !contentIds.isEmpty else {
            Logger.shared.log("Stremio: No supported subtitle content ID", type: "Stremio")
            return []
        }

        var subtitles: [StremioSubtitle] = []
        for contentId in contentIds {
            do {
                let fetched = try await client.fetchSubtitles(
                    baseURL: addon.configuredURL,
                    type: type,
                    id: contentId
                )
                Logger.shared.log("Stremio: Subtitle candidate returned \(fetched.count) subtitle(s)", type: "Stremio")
                subtitles.append(contentsOf: fetched)
            } catch {
                Logger.shared.log(
                    "Stremio: Subtitle candidate failed reason=\(servicePinnedNetworkErrorToken(error))",
                    type: "Stremio"
                )
            }
        }

        return dedupeSubtitles(subtitles)
    }

    private static func fetchStreamsByCatalogSearch(
        _ addon: StremioAddon,
        client: StremioClient,
        requestedType: String,
        season: Int?,
        episode: Int?,
        playbackContext: EpisodePlaybackContext?,
        titleCandidates: [String],
        expectedYear: Int?
    ) async -> [StremioStream] {
        let searchQueries = normalizedSearchQueries(titleCandidates)
        guard !searchQueries.isEmpty else {
            Logger.shared.log("Stremio: Catalog fallback skipped because no title candidates were available", type: "Stremio")
            return []
        }

        let catalogs = addon.manifest.searchableCatalogs
            .filter { $0.supportsType(requestedType) }
            .prefix(3)

        guard !catalogs.isEmpty else {
            Logger.shared.log("Stremio: Catalog fallback unavailable; no searchable catalog", type: "Stremio")
            return []
        }

        var ranked = [RankedCatalogMeta]()
        for catalog in catalogs {
            for query in searchQueries.prefix(4) {
                do {
                    let metas = try await client.fetchCatalogMetas(
                        baseURL: addon.configuredURL,
                        catalog: catalog,
                        searchQuery: query
                    )
                    ranked.append(contentsOf: metas.prefix(12).compactMap { meta in
                        guard metaMatchesRequestedType(meta, catalog: catalog, requestedType: requestedType) else {
                            return nil
                        }
                        let score = catalogMetaScore(
                            meta,
                            titleCandidates: titleCandidates,
                            expectedYear: expectedYear
                        )
                        guard score >= 0.78 else { return nil }
                        return RankedCatalogMeta(catalog: catalog, meta: meta, score: score, query: query)
                    })
                } catch {
                    Logger.shared.log(
                        "Stremio: Catalog fallback query failed queryBytes=\(query.utf8.count) reason=\(servicePinnedNetworkErrorToken(error))",
                        type: "Stremio"
                    )
                }
            }
        }

        let candidates = ranked
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.0001 {
                    return lhs.score > rhs.score
                }
                return lhs.meta.name.count < rhs.meta.name.count
            }
            .prefix(5)

        guard !candidates.isEmpty else {
            Logger.shared.log("Stremio: Catalog fallback found no confident match", type: "Stremio")
            return []
        }

        for candidate in candidates {
            Logger.shared.log(
                "Stremio: Catalog fallback trying candidate score=\(String(format: "%.2f", candidate.score)) queryBytes=\(candidate.query.utf8.count)",
                type: "Stremio"
            )
            let streams = await fetchStreamsForCatalogMeta(
                candidate.meta,
                catalog: candidate.catalog,
                addon: addon,
                client: client,
                requestedType: requestedType,
                season: season,
                episode: episode,
                playbackContext: playbackContext
            )
            if !streams.isEmpty {
                Logger.shared.log("Stremio: Catalog fallback resolved \(streams.count) stream(s)", type: "Stremio")
                return streams
            }
        }

        Logger.shared.log("Stremio: Catalog fallback exhausted confident matches", type: "Stremio")
        return []
    }

    private static func fetchStreamsForCatalogMeta(
        _ preview: StremioMetaPreview,
        catalog: StremioCatalog,
        addon: StremioAddon,
        client: StremioClient,
        requestedType: String,
        season: Int?,
        episode: Int?,
        playbackContext: EpisodePlaybackContext?
    ) async -> [StremioStream] {
        let streamType = preview.type ?? catalog.type
        let directPreviewStreams = streamsFromMeta(preview, season: season, episode: episode, playbackContext: playbackContext)
        if !directPreviewStreams.isEmpty {
            return directPreviewStreams
        }

        var meta = preview
        if addon.manifest.supportsMeta {
            do {
                if let fetched = try await client.fetchMeta(baseURL: addon.configuredURL, type: streamType, id: preview.id) {
                    meta = fetched
                    let metaStreams = streamsFromMeta(fetched, season: season, episode: episode, playbackContext: playbackContext)
                    if !metaStreams.isEmpty {
                        return metaStreams
                    }
                }
            } catch {
                Logger.shared.log(
                    "Stremio: Catalog fallback meta fetch failed reason=\(servicePinnedNetworkErrorToken(error))",
                    type: "Stremio"
                )
            }
        }

        for contentId in streamIdsFromMeta(meta, requestedType: requestedType, season: season, episode: episode, playbackContext: playbackContext) {
            do {
                let streams = try await client.fetchStreams(
                    baseURL: addon.configuredURL,
                    type: streamType,
                    id: contentId
                )
                if !streams.isEmpty {
                    return streams
                }
            } catch {
                Logger.shared.log(
                    "Stremio: Catalog fallback stream fetch failed reason=\(servicePinnedNetworkErrorToken(error))",
                    type: "Stremio"
                )
            }
        }

        return []
    }

    private static func streamsFromMeta(_ meta: StremioMetaPreview, season: Int?, episode: Int?, playbackContext: EpisodePlaybackContext?) -> [StremioStream] {
        guard let videos = meta.videos else { return [] }

        let matchingVideos: [StremioVideo]
        if let season, let episode {
            let exactMatches = videos.filter { $0.season == season && $0.episode == episode }
            matchingVideos = exactMatches.isEmpty ? autoEpisodeMatches(videos: videos, playbackContext: playbackContext) : exactMatches
        } else if let defaultVideoId = meta.behaviorHints?.defaultVideoId,
                  let defaultVideo = videos.first(where: { $0.id == defaultVideoId }) {
            matchingVideos = [defaultVideo]
        } else {
            matchingVideos = videos
        }

        return dedupeStreams(
            matchingVideos
                .flatMap { $0.streams ?? [] }
                .filter { $0.isDirectHTTP }
        )
    }

    private static func streamIdsFromMeta(_ meta: StremioMetaPreview, requestedType: String, season: Int?, episode: Int?, playbackContext: EpisodePlaybackContext?) -> [String] {
        var candidates = [String]()

        if let season, let episode {
            if let videoId = meta.videos?.first(where: { $0.season == season && $0.episode == episode })?.id {
                candidates.append(videoId)
            }
            candidates.append(contentsOf: autoEpisodeMatches(videos: meta.videos ?? [], playbackContext: playbackContext).map(\.id))
            if isKitsuMetaId(meta.id) {
                if let localEpisode = animeLocalKitsuEpisode(from: playbackContext) {
                    candidates.append(kitsuStreamId(from: meta.id, episode: localEpisode))
                } else if episode > 0 {
                    candidates.append(kitsuStreamId(from: meta.id, episode: episode))
                }
            } else {
                candidates.append("\(meta.id):\(season):\(episode)")
                if let localSeason = animeLocalSeriesSeason(from: playbackContext),
                   let localEpisode = animeLocalSeriesEpisode(from: playbackContext) {
                    candidates.append("\(meta.id):\(localSeason):\(localEpisode)")
                }
                if shouldTrySeasonScopedAnimeMetaId(meta.id, playbackContext: playbackContext),
                   let localSeason = animeLocalStremioSeason(from: playbackContext),
                   let localEpisode = animeLocalStremioEpisode(from: playbackContext) {
                    candidates.append("\(meta.id):\(localSeason):\(localEpisode)")
                }
            }
        } else if requestedType == "movie" {
            candidates.append(meta.id)
        } else if let defaultVideoId = meta.behaviorHints?.defaultVideoId {
            candidates.append(defaultVideoId)
        }

        if candidates.isEmpty {
            candidates.append(meta.id)
        }

        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func animeLocalStremioSeason(from context: EpisodePlaybackContext?) -> Int? {
        guard let context,
              !context.isSpecial,
              !context.titleOnlySearch,
              context.positiveAniListMediaId != nil,
              context.localEpisodeNumber > 0 else {
            return nil
        }
        return 1
    }

    private static func animeLocalStremioEpisode(from context: EpisodePlaybackContext?) -> Int? {
        guard let context,
              context.positiveAniListMediaId != nil,
              (context.isSpecial || !context.titleOnlySearch),
              context.localEpisodeNumber > 0 else {
            return nil
        }
        return context.localEpisodeNumber
    }

    private static func animeLocalKitsuEpisode(from context: EpisodePlaybackContext?) -> Int? {
        guard let context,
              context.kitsuMediaId != nil,
              (context.isSpecial || !context.titleOnlySearch),
              context.localEpisodeNumber > 0 else {
            return nil
        }
        return context.localEpisodeNumber
    }

    private static func animeLocalSeriesSeason(from context: EpisodePlaybackContext?) -> Int? {
        guard let context,
              !context.isSpecial,
              !context.titleOnlySearch,
              context.positiveAniListMediaId != nil,
              context.localSeasonNumber > 0 else {
            return nil
        }
        return context.localSeasonNumber
    }

    private static func animeLocalSeriesEpisode(from context: EpisodePlaybackContext?) -> Int? {
        guard let context,
              !context.isSpecial,
              !context.titleOnlySearch,
              context.positiveAniListMediaId != nil,
              context.localEpisodeNumber > 0 else {
            return nil
        }
        return context.localEpisodeNumber
    }

    private static func shouldTrySeasonScopedAnimeMetaId(_ metaId: String, playbackContext: EpisodePlaybackContext?) -> Bool {
        guard playbackContext?.positiveAniListMediaId != nil else { return false }
        let lowercased = metaId.lowercased()
        return !lowercased.hasPrefix("tt") &&
            !lowercased.hasPrefix("imdb:") &&
            !lowercased.hasPrefix("tmdb:") &&
            !lowercased.hasPrefix("kitsu:")
    }

    private static func isKitsuMetaId(_ metaId: String) -> Bool {
        metaId.lowercased().hasPrefix("kitsu:")
    }

    private static func kitsuStreamId(from metaId: String, episode: Int) -> String {
        let parts = metaId.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 3,
           let last = parts.last,
           Int(last) != nil {
            return metaId
        }
        return "\(metaId):\(episode)"
    }

    private static func autoEpisodeMatches(videos: [StremioVideo], playbackContext: EpisodePlaybackContext?) -> [StremioVideo] {
        guard let context = playbackContext,
              !context.isSpecial,
              !context.titleOnlySearch,
              let seasonEpisodeCount = context.animeSeasonEpisodeCount,
              seasonEpisodeCount > 0,
              context.localEpisodeNumber > 0 else {
            return []
        }

        let episodeNumbers = videos.compactMap(\.episode)
        guard let maxEpisode = episodeNumbers.max() else { return [] }

        if let absoluteEpisode = context.animeAbsoluteEpisodeNumber,
           absoluteEpisode > 0,
           maxEpisode > seasonEpisodeCount {
            return videos.filter { $0.episode == absoluteEpisode }
        }

        if maxEpisode <= seasonEpisodeCount {
            return videos.filter { $0.episode == context.localEpisodeNumber }
        }

        return []
    }

    private static func metaMatchesRequestedType(_ meta: StremioMetaPreview, catalog: StremioCatalog, requestedType: String) -> Bool {
        let metaType = meta.type ?? catalog.type
        return metaType == requestedType
            || (requestedType == "series" && (metaType == "tv" || metaType == "anime"))
    }

    private static func catalogMetaScore(_ meta: StremioMetaPreview, titleCandidates: [String], expectedYear: Int?) -> Double {
        let titleScores = titleCandidates.map { titleSimilarity(expected: $0, result: meta.name) }
        var score = titleScores.max() ?? 0

        if let expectedYear, let releaseYear = releaseYear(from: meta) {
            let distance = abs(expectedYear - releaseYear)
            if distance == 0 {
                score += 0.08
            } else if distance == 1 {
                score += 0.03
            } else if distance > 3 {
                score -= 0.12
            }
        }

        return min(max(score, 0), 1)
    }

    private static func titleSimilarity(expected: String, result: String) -> Double {
        let expectedCanonical = normalizedTitle(expected)
        let resultCanonical = normalizedTitle(result)
        guard !expectedCanonical.isEmpty, !resultCanonical.isEmpty else { return 0 }

        let raw = HybridSimilarity.calculateSimilarity(original: expected, result: result)
        let canonical = HybridSimilarity.calculateSimilarity(original: expectedCanonical, result: resultCanonical)
        let token = tokenOverlapScore(expectedCanonical, resultCanonical)

        var score = max(raw, canonical) * 0.68 + token * 0.32
        if expectedCanonical == resultCanonical {
            score += 0.12
        } else if expectedCanonical.contains(resultCanonical) || resultCanonical.contains(expectedCanonical) {
            score += 0.05
        }
        return min(max(score, 0), 1)
    }

    private static func normalizedSearchQueries(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { stripEpisodeSuffix(from: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert(normalizedTitle($0)).inserted }
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripEpisodeSuffix(from title: String) -> String {
        let patterns = [
            #"(?i)\s*-\s*S\d{1,3}E\d{1,4}$"#,
            #"(?i)\s*S\d{1,3}E\d{1,4}$"#,
            #"(?i)\s*-\s*E\d{1,4}$"#,
            #"(?i)\s*E\d{1,4}$"#,
            #"(?i)\s*episode\s+\d{1,4}$"#
        ]

        var stripped = title
        for pattern in patterns {
            if let range = stripped.range(of: pattern, options: .regularExpression) {
                stripped.removeSubrange(range)
                break
            }
        }
        return stripped
    }

    private static func tokenOverlapScore(_ lhs: String, _ rhs: String) -> Double {
        let ignored: Set<String> = ["a", "an", "and", "the", "of", "to", "in", "on", "tv", "series", "episode"]
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        return Double(lhsTokens.intersection(rhsTokens).count) / Double(max(lhsTokens.count, rhsTokens.count))
    }

    private static func releaseYear(from meta: StremioMetaPreview) -> Int? {
        let source = meta.releaseInfo ?? meta.released
        guard let source else { return nil }
        let pattern = #"\b(19|20)\d{2}\b"#
        guard let range = source.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return Int(source[range])
    }

    private static func dedupeStreams(_ streams: [StremioStream]) -> [StremioStream] {
        var seen = Set<String>()
        return streams.filter { stream in
            let key = stream.url ?? stream.infoHash ?? stream.id
            return seen.insert(key).inserted
        }
    }

    private static func dedupeSubtitles(_ subtitles: [StremioSubtitle]) -> [StremioSubtitle] {
        var seen = Set<String>()
        return subtitles.filter { subtitle in
            guard let url = subtitle.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else {
                return false
            }
            return seen.insert(url.lowercased()).inserted
        }
    }

    private static func dedupeSubtitleResults(_ results: [AddonSubtitleResult]) -> [AddonSubtitleResult] {
        var seen = Set<String>()
        return results
            .sorted { lhs, rhs in
                if lhs.addon.sortIndex != rhs.addon.sortIndex {
                    return lhs.addon.sortIndex < rhs.addon.sortIndex
                }
                return lhs.addon.manifest.name.localizedCaseInsensitiveCompare(rhs.addon.manifest.name) == .orderedAscending
            }
            .filter { result in
                guard let url = result.subtitle.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !url.isEmpty else {
                    return false
                }
                return seen.insert(url.lowercased()).inserted
            }
    }

    private func generateAddonUUID(manifest: StremioManifest, configuredURL: String) -> UUID {
        let input = "\(manifest.id)|\(configuredURL)"
        let hash = SHA256.hash(data: Data(input.utf8))
        let hashBytes = Array(hash)
        return UUID(uuid: (
            hashBytes[0], hashBytes[1], hashBytes[2], hashBytes[3],
            hashBytes[4], hashBytes[5], hashBytes[6], hashBytes[7],
            hashBytes[8], hashBytes[9], hashBytes[10], hashBytes[11],
            hashBytes[12], hashBytes[13], hashBytes[14], hashBytes[15]
        ))
    }

    enum StremioAddonError: LocalizedError {
        case noStreamSupport
        case alreadyExists

        case profileChanged

        var errorDescription: String? {
            switch self {
            case .noStreamSupport: return "This addon does not support streams, subtitles, or catalogs"
            case .alreadyExists: return "This addon is already installed"
            case .profileChanged: return "The active profile changed while this addon was being added. Try again."
            }
        }
    }
}

struct KitsuLookupQueryCache {
    enum Entry: Equatable {
        case match(Int)
        case noMatch
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    init(capacity: Int = 512) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func entry(for key: String) -> Entry? {
        entries[key]
    }

    mutating func store(_ entry: Entry, for key: String) {
        if entries.updateValue(entry, forKey: key) == nil {
            insertionOrder.append(key)
        }

        let overflow = entries.count - capacity
        guard overflow > 0 else { return }
        let evictedKeys = insertionOrder.prefix(overflow)
        for evictedKey in evictedKeys {
            entries.removeValue(forKey: evictedKey)
        }
        insertionOrder.removeFirst(overflow)
    }
}

enum StremioRetryAfterPolicy {
    static let fallbackSeconds: TimeInterval = 5
    static let maximumSeconds: TimeInterval = 120

    static func delaySeconds(from rawValue: String?) -> TimeInterval {
        guard let rawValue,
              let parsed = TimeInterval(
                rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              parsed.isFinite else {
            return fallbackSeconds
        }
        return min(max(parsed, 1), maximumSeconds)
    }

    static func normalizedSchedulerDate(_ value: Date, now: Date) -> Date {
        let interval = value.timeIntervalSince(now)
        guard interval.isFinite else { return now }
        if interval > maximumSeconds {
            return now.addingTimeInterval(maximumSeconds)
        }
        return value
    }
}

private actor KitsuAnimeIDLookup {
    private enum FetchResult {
        case response(KitsuSearchResponse)
        case unavailable
        case rateLimited
        case cancelled
    }

    static let shared = KitsuAnimeIDLookup()

    private let endpoint = URL(string: "https://kitsu.io/api/edge/anime")!
    private var positiveCacheByHint: [Int: Int] = [:]
    private var queryCache = KitsuLookupQueryCache()
    private var nextAvailableAt = Date.distantPast
    private var rateLimitedUntil = Date.distantPast
    private let minimumSpacing: TimeInterval = 0.4

    func resolveAnimeId(
        titleCandidates: [String],
        expectedEpisodeCount: Int?,
        expectedYear: Int?,
        cacheHint: Int?
    ) async -> Int? {
        if let cacheHint, let cached = positiveCacheByHint[cacheHint] {
            return cached
        }
        let now = Date()
        rateLimitedUntil = StremioRetryAfterPolicy.normalizedSchedulerDate(
            rateLimitedUntil,
            now: now
        )
        nextAvailableAt = StremioRetryAfterPolicy.normalizedSchedulerDate(
            nextAvailableAt,
            now: now
        )
        guard rateLimitedUntil <= now else {
            return nil
        }

        let queries = searchQueries(from: titleCandidates).prefix(5)
        guard !queries.isEmpty else { return nil }

        for query in queries {
            let cacheKey = "\(normalizedTitle(query))|\(expectedEpisodeCount?.description ?? "-")|\(expectedYear?.description ?? "-")"
            if let cached = queryCache.entry(for: cacheKey) {
                switch cached {
                case .match(let id):
                    if let cacheHint {
                        positiveCacheByHint[cacheHint] = id
                    }
                    return id
                case .noMatch:

                    continue
                }
            }

            let response: KitsuSearchResponse
            switch await fetchKitsuSearch(query: query) {
            case .response(let value):
                response = value
            case .unavailable:
                continue
            case .rateLimited:

                return nil
            case .cancelled:
                return nil
            }

            if let match = bestMatch(
                in: response.data,
                titleCandidates: titleCandidates,
                expectedEpisodeCount: expectedEpisodeCount,
                expectedYear: expectedYear
            ) {
                queryCache.store(.match(match.id), for: cacheKey)
                if let cacheHint {
                    positiveCacheByHint[cacheHint] = match.id
                }
                Logger.shared.log(
                    "Stremio: Kitsu title lookup matched score=\(String(format: "%.2f", match.score)) queryBytes=\(query.utf8.count)",
                    type: "Stremio"
                )
                return match.id
            }

            queryCache.store(.noMatch, for: cacheKey)
        }

        return nil
    }

    private func fetchKitsuSearch(query: String) async -> FetchResult {
        do {
            try await waitForSlot()
        } catch {
            return .cancelled
        }
        guard !Task.isCancelled else { return .cancelled }
        let dispatchDate = Date()
        rateLimitedUntil = StremioRetryAfterPolicy.normalizedSchedulerDate(
            rateLimitedUntil,
            now: dispatchDate
        )
        guard rateLimitedUntil <= dispatchDate else { return .rateLimited }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return .unavailable
        }
        components.queryItems = [
            URLQueryItem(name: "filter[text]", value: query),
            URLQueryItem(name: "page[limit]", value: "5"),
            URLQueryItem(name: "fields[anime]", value: "slug,canonicalTitle,titles,startDate,episodeCount")
        ]

        guard let url = components.url else { return .unavailable }

        do {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.boundedData(
                for: request,
                maximumResponseBytes: 512 * 1024
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                return .unavailable
            }

            if httpResponse.statusCode == 429 {
                pauseUntilRetryAfter(httpResponse)
                Logger.shared.log("Stremio: Kitsu title lookup rate limited", type: "Stremio")
                return .rateLimited
            }

            guard httpResponse.statusCode == 200 else {
                Logger.shared.log(
                    "Stremio: Kitsu title lookup failed status=\(httpResponse.statusCode) queryBytes=\(query.utf8.count)",
                    type: "Stremio"
                )
                return .unavailable
            }

            try SkyStreamJSONEnvelopeValidator.validate(
                data,
                limits: .init(
                    maximumDepth: 12,
                    maximumTokens: 20_000,
                    maximumValuesPerContainer: 512,
                    maximumStringBytes: 4 * 1_024,
                    maximumScalarTokenBytes: 128
                )
            )
            return .response(try JSONDecoder().decode(KitsuSearchResponse.self, from: data))
        } catch {
            if Task.isCancelled
                || error is CancellationError
                || (error as? URLError)?.code == .cancelled {
                return .cancelled
            }
            Logger.shared.log(
                "Stremio: Kitsu title lookup failed queryLength=\(query.utf8.count) error=\(servicePinnedNetworkErrorToken(error))",
                type: "Stremio"
            )
            return .unavailable
        }
    }

    private func waitForSlot() async throws {
        try Task.checkCancellation()
        let now = Date()
        nextAvailableAt = StremioRetryAfterPolicy.normalizedSchedulerDate(
            nextAvailableAt,
            now: now
        )
        let reservedSlot = max(now, nextAvailableAt)
        nextAvailableAt = reservedSlot.addingTimeInterval(minimumSpacing)

        let delay = reservedSlot.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try Task.checkCancellation()
    }

    private func pauseUntilRetryAfter(_ response: HTTPURLResponse) {
        let retryAfter = StremioRetryAfterPolicy.delaySeconds(
            from: response.value(forHTTPHeaderField: "Retry-After")
        )
        let now = Date()
        rateLimitedUntil = StremioRetryAfterPolicy.normalizedSchedulerDate(
            rateLimitedUntil,
            now: now
        )
        nextAvailableAt = StremioRetryAfterPolicy.normalizedSchedulerDate(
            nextAvailableAt,
            now: now
        )
        let cooldown = now.addingTimeInterval(retryAfter)
        rateLimitedUntil = max(rateLimitedUntil, cooldown)
        nextAvailableAt = max(nextAvailableAt, cooldown)
    }

    private func bestMatch(
        in items: [KitsuAnime],
        titleCandidates: [String],
        expectedEpisodeCount: Int?,
        expectedYear: Int?
    ) -> (id: Int, title: String, score: Double)? {
        items.compactMap { item -> (id: Int, title: String, score: Double)? in
            guard let id = Int(item.id), id > 0 else { return nil }
            let titles = item.attributes.matchableTitles
            guard !titles.isEmpty else { return nil }

            let titleScore = titleCandidates
                .flatMap { candidate in titles.map { titleSimilarity(expected: candidate, result: $0) } }
                .max() ?? 0
            guard titleScore >= 0.82 else { return nil }

            var score = titleScore
            if let expectedEpisodeCount,
               expectedEpisodeCount > 0,
               let actualEpisodeCount = item.attributes.episodeCount,
               actualEpisodeCount > 0 {
                let distance = abs(actualEpisodeCount - expectedEpisodeCount)
                if distance == 0 {
                    score += 0.08
                } else if distance == 1 {
                    score += 0.03
                } else if distance > max(2, expectedEpisodeCount / 4) {
                    score -= 0.12
                }
            }

            if let expectedYear,
               let startDate = item.attributes.startDate,
               let actualYear = Int(startDate.prefix(4)) {
                let distance = abs(actualYear - expectedYear)
                if distance == 0 {
                    score += 0.05
                } else if distance > 2 {
                    score -= 0.08
                }
            }

            guard score >= 0.84 else { return nil }
            return (id, item.attributes.displayTitle, min(score, 1))
        }
        .sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.0001 {
                return lhs.score > rhs.score
            }
            return lhs.title.count < rhs.title.count
        }
        .first
    }

    private func searchQueries(from values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { stripEpisodeSuffix(from: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert(normalizedTitle($0)).inserted }
    }

    private func titleSimilarity(expected: String, result: String) -> Double {
        let expectedCanonical = normalizedTitle(expected)
        let resultCanonical = normalizedTitle(result)
        guard !expectedCanonical.isEmpty, !resultCanonical.isEmpty else { return 0 }

        let raw = HybridSimilarity.calculateSimilarity(original: expected, result: result)
        let canonical = HybridSimilarity.calculateSimilarity(original: expectedCanonical, result: resultCanonical)
        let token = tokenOverlapScore(expectedCanonical, resultCanonical)

        var score = max(raw, canonical) * 0.68 + token * 0.32
        if expectedCanonical == resultCanonical {
            score += 0.12
        } else if expectedCanonical.contains(resultCanonical) || resultCanonical.contains(expectedCanonical) {
            score += 0.05
        }
        return min(max(score, 0), 1)
    }

    private func normalizedTitle(_ title: String) -> String {
        title
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripEpisodeSuffix(from title: String) -> String {
        let patterns = [
            #"(?i)\s*-\s*S\d{1,3}E\d{1,4}$"#,
            #"(?i)\s*S\d{1,3}E\d{1,4}$"#,
            #"(?i)\s*-\s*E\d{1,4}$"#,
            #"(?i)\s*E\d{1,4}$"#,
            #"(?i)\s*episode\s+\d{1,4}$"#
        ]

        var stripped = title
        for pattern in patterns {
            if let range = stripped.range(of: pattern, options: .regularExpression) {
                stripped.removeSubrange(range)
                break
            }
        }
        return stripped
    }

    private func tokenOverlapScore(_ lhs: String, _ rhs: String) -> Double {
        let ignored: Set<String> = ["a", "an", "and", "the", "of", "to", "in", "on", "tv", "series", "episode"]
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        return Double(lhsTokens.intersection(rhsTokens).count) / Double(max(lhsTokens.count, rhsTokens.count))
    }

    private struct KitsuSearchResponse: Decodable {
        let data: [KitsuAnime]
    }

    private struct KitsuAnime: Decodable {
        let id: String
        let attributes: Attributes

        struct Attributes: Decodable {
            let slug: String?
            let canonicalTitle: String?
            let titles: [String: String?]?
            let startDate: String?
            let episodeCount: Int?

            var displayTitle: String {
                canonicalTitle ?? titles?.values.compactMap { $0 }.first ?? slug ?? "unknown"
            }

            var matchableTitles: [String] {
                var seen = Set<String>()
                return ([canonicalTitle, slug] + (titles?.values.compactMap { $0 }.map(Optional.some) ?? []))
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .filter { seen.insert($0.lowercased()).inserted }
            }
        }
    }
}
