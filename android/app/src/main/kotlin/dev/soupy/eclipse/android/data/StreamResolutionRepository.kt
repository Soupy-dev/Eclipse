package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.EpisodePlaybackContext
import dev.soupy.eclipse.android.core.model.PlayerSource
import dev.soupy.eclipse.android.core.model.SimilarityAlgorithm
import dev.soupy.eclipse.android.core.model.StremioContentIdRequest
import dev.soupy.eclipse.android.core.model.StremioManifest
import dev.soupy.eclipse.android.core.model.StremioStream
import dev.soupy.eclipse.android.core.model.SubtitleTrack
import dev.soupy.eclipse.android.core.model.buildContentId
import dev.soupy.eclipse.android.core.model.displayTitle
import dev.soupy.eclipse.android.core.model.isDirectHttp
import dev.soupy.eclipse.android.core.model.isTorrentLike
import dev.soupy.eclipse.android.core.model.qualityScore
import dev.soupy.eclipse.android.core.network.AniListService
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.network.StremioService
import dev.soupy.eclipse.android.core.network.TmdbService
import dev.soupy.eclipse.android.core.storage.SettingsStore
import dev.soupy.eclipse.android.core.storage.StremioAddonDao
import dev.soupy.eclipse.android.core.storage.StremioAddonEntity
import kotlinx.coroutines.flow.first
import kotlinx.serialization.decodeFromString

private const val ExactStremioContentMatchFloor = 0.90

data class ResolvedStreamCandidate(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val supportingText: String? = null,
    val addonName: String,
    val isPlayable: Boolean,
    val qualityScore: Double = 0.0,
    val matchScore: Double = 0.0,
    val playerSource: PlayerSource? = null,
)

data class StreamResolutionResult(
    val statusMessage: String,
    val candidates: List<ResolvedStreamCandidate> = emptyList(),
    val selectedSource: PlayerSource? = null,
)

data class StreamEpisodeSelection(
    val seasonNumber: Int,
    val episodeNumber: Int,
    val label: String,
    val localSeasonNumber: Int = seasonNumber,
    val localEpisodeNumber: Int = episodeNumber,
    val anilistMediaId: Int? = null,
)

class StreamResolutionRepository(
    private val tmdbService: TmdbService,
    private val aniListService: AniListService,
    private val animeTmdbMapper: AnimeTmdbMapper,
    private val stremioService: StremioService,
    private val stremioAddonDao: StremioAddonDao,
    private val settingsStore: SettingsStore,
) {
    suspend fun resolve(
        target: DetailTarget,
        episode: StreamEpisodeSelection? = null,
    ): Result<StreamResolutionResult> = runCatching {
        val request = buildRequest(target, episode)
        val settings = settingsStore.settings.first()
        val addons = stremioAddonDao.observeAll().first()
            .filter(StremioAddonEntity::enabled)
            .let { enabled ->
                val selectedAddonIds = enabled
                    .map { addon -> "stremio:${addon.transportUrl}" }
                    .filter { it in settings.autoModeSourceIds }
                if (settings.autoModeEnabled && selectedAddonIds.isNotEmpty()) {
                    enabled.filter { addon -> "stremio:${addon.transportUrl}" in selectedAddonIds }
                } else {
                    enabled
                }
            }
            .filter { addon ->
                val manifest = addon.manifest()
                manifest == null || manifest.types.isEmpty() || request.type in manifest.types
            }

        if (addons.isEmpty()) {
            return@runCatching StreamResolutionResult(
                statusMessage = "No enabled Stremio addons are ready for ${request.type}. Import one in Services first, or include it in Auto Mode if you want Android to prefer selected addons.",
            )
        }

        var rejectedTorrentCount = 0
        val candidates = buildList {
            addons.forEach { addon ->
                val addonLabel = addon.name.ifBlank { addon.transportUrl }
                val manifest = addon.manifest()
                val contentId = manifest?.buildContentId(request.toContentIdRequest())
                    ?: StremioManifest().buildContentId(request.toContentIdRequest())
                if (contentId == null) {
                    return@forEach
                }
                stremioService.fetchStreams(
                    transportUrl = addon.transportUrl,
                    type = request.type,
                    id = contentId,
                ).orNull()?.streams.orEmpty()
                    .filter { stream ->
                        if (stream.isTorrentLike) {
                            rejectedTorrentCount += 1
                            false
                        } else {
                            true
                        }
                    }
                    .mapIndexed { index, stream ->
                        stream.toResolvedCandidate(
                            addon = addon,
                            addonLabel = addonLabel,
                            requestSummary = request.summary,
                            requestTitles = request.matchTitles,
                            contentId = contentId,
                            playbackContext = request.playbackContext,
                            similarityAlgorithm = settings.selectedSimilarityAlgorithm,
                            index = index,
                        )
                    }
                    .let(::addAll)
            }
        }.sortedWith(
            compareByDescending<ResolvedStreamCandidate> { it.isPlayable }
                .thenByDescending { it.matchScore }
                .thenByDescending { it.qualityScore }
                .thenBy { it.addonName.lowercase() }
                .thenBy { it.title.lowercase() },
        )

        if (candidates.isEmpty()) {
            return@runCatching StreamResolutionResult(
                statusMessage = if (rejectedTorrentCount > 0) {
                    "Android rejected $rejectedTorrentCount torrent or magnet result${if (rejectedTorrentCount == 1) "" else "s"} for ${request.summary}. No safe direct HTTP(S) streams were returned."
                } else {
                    "The enabled addons didn't return any safe direct HTTP(S) streams for ${request.summary} yet."
                },
            )
        }

        val threshold = settings.highQualityThreshold.coerceIn(0.0, 1.0)
        val autoSelectedCandidate = candidates.firstOrNull { candidate ->
            settings.autoModeEnabled &&
                candidate.isPlayable &&
                candidate.matchScore >= threshold
        }
        val playable = autoSelectedCandidate?.playerSource
        val playableCount = candidates.count(ResolvedStreamCandidate::isPlayable)
        val pendingCount = candidates.size - playableCount

        StreamResolutionResult(
            statusMessage = when {
                playable == null && !settings.autoModeEnabled && playableCount > 0 ->
                    "Resolved $playableCount direct HTTP(S) stream${if (playableCount == 1) "" else "s"} for ${request.summary}. Auto Mode is off, so pick one manually.${rejectedTorrentCount.rejectionSuffix()}"
                playable == null && settings.autoModeEnabled && playableCount > 0 ->
                    "Resolved $playableCount direct HTTP(S) stream${if (playableCount == 1) "" else "s"} for ${request.summary}, but none met the Auto Mode match threshold (${(threshold * 100).toInt()}%). Pick one manually or lower the threshold.${rejectedTorrentCount.rejectionSuffix()}"
                playable != null && pendingCount > 0 ->
                    "Resolved $playableCount direct HTTP(S) stream${if (playableCount == 1) "" else "s"} plus $pendingCount unsupported non-torrent result${if (pendingCount == 1) "" else "s"} for ${request.summary}.${rejectedTorrentCount.rejectionSuffix()}"
                playable != null ->
                    "Resolved $playableCount direct HTTP(S) stream${if (playableCount == 1) "" else "s"} for ${request.summary}.${rejectedTorrentCount.rejectionSuffix()}"
                else ->
                    "Found ${candidates.size} non-torrent stream result${if (candidates.size == 1) "" else "s"} for ${request.summary}, but Android only accepts direct HTTP(S) playback URLs.${rejectedTorrentCount.rejectionSuffix()}"
            },
            candidates = candidates,
            selectedSource = playable,
        )
    }

    private suspend fun buildRequest(
        target: DetailTarget,
        episode: StreamEpisodeSelection?,
    ): StremioRequest = when (target) {
        is DetailTarget.TmdbMovie -> {
            val movie = tmdbService.movieDetail(target.id).orThrow()
            val imdbId = movie.externalIds?.imdbId?.takeIf { it.isNotBlank() }
            StremioRequest(
                type = "movie",
                tmdbId = target.id,
                imdbId = imdbId,
                season = null,
                episode = null,
                summary = movie.title.ifBlank { imdbId ?: "tmdb:${target.id}" },
                matchTitles = listOfNotNull(movie.title, imdbId),
            )
        }

        is DetailTarget.TmdbShow -> {
            val show = tmdbService.tvShowDetail(target.id).orThrow()
            val imdbId = show.externalIds?.imdbId?.takeIf { it.isNotBlank() }
            val selectedEpisode = episode ?: firstPlayableEpisode(target.id)
            StremioRequest(
                type = "series",
                tmdbId = target.id,
                imdbId = imdbId,
                season = selectedEpisode.seasonNumber,
                episode = selectedEpisode.episodeNumber,
                summary = "${show.name} ${selectedEpisode.label}",
                matchTitles = listOf(show.name),
                playbackContext = selectedEpisode.toPlaybackContext(),
            )
        }

        is DetailTarget.AniListMediaTarget -> {
            val media = aniListService.mediaById(target.id).orThrow()
            val match = animeTmdbMapper.findBestMatch(media)
                ?: error("Android couldn't match this AniList anime to TMDB yet, so Stremio episode IDs could not be built.")

            when (val tmdbTarget = match.target) {
                is DetailTarget.TmdbMovie -> {
                    val movie = tmdbService.movieDetail(tmdbTarget.id).orThrow()
                    StremioRequest(
                        type = "movie",
                        tmdbId = tmdbTarget.id,
                        imdbId = movie.externalIds?.imdbId?.takeIf { it.isNotBlank() },
                        season = null,
                        episode = null,
                        summary = "${media.displayTitle} via ${match.title}",
                        matchTitles = listOf(media.displayTitle, match.title, movie.title),
                    )
                }

                is DetailTarget.TmdbShow -> {
                    val show = tmdbService.tvShowDetail(tmdbTarget.id).orThrow()
                    val selectedEpisode = episode ?: firstPlayableEpisode(tmdbTarget.id, match.tmdbSeasonNumber)
                    StremioRequest(
                        type = "series",
                        tmdbId = tmdbTarget.id,
                        imdbId = show.externalIds?.imdbId?.takeIf { it.isNotBlank() },
                        season = selectedEpisode.seasonNumber,
                        episode = selectedEpisode.episodeNumber,
                        summary = "${media.displayTitle} ${selectedEpisode.label} via ${match.title}",
                        matchTitles = listOf(media.displayTitle, match.title, show.name),
                        playbackContext = selectedEpisode
                            .copy(anilistMediaId = selectedEpisode.anilistMediaId ?: media.id)
                            .toPlaybackContext(),
                    )
                }

                is DetailTarget.AniListMediaTarget -> error("AniList-to-AniList stream mapping is not supported.")
            }
        }
    }

    private suspend fun firstPlayableEpisode(
        showId: Int,
        preferredSeasonNumber: Int? = null,
    ): StreamEpisodeSelection {
        val show = tmdbService.tvShowDetail(showId).orThrow()
        val firstSeason = preferredSeasonNumber
            ?.let { preferred -> show.seasons.firstOrNull { it.seasonNumber == preferred && it.episodeCount > 0 } }
            ?: show.seasons.firstOrNull { it.seasonNumber > 0 && it.episodeCount > 0 }
            ?: show.seasons.firstOrNull { it.episodeCount > 0 }
            ?: error("This series doesn't expose any seasons yet, so Android can't resolve Stremio episode streams.")
        val seasonDetail = tmdbService.seasonDetail(showId, firstSeason.seasonNumber).orThrow()
        val firstEpisode = seasonDetail.episodes.firstOrNull { it.episodeNumber > 0 }
            ?: error("This series doesn't expose a playable episode yet for Android stream resolution.")

        return StreamEpisodeSelection(
            seasonNumber = firstSeason.seasonNumber,
            episodeNumber = firstEpisode.episodeNumber,
            label = "S${firstSeason.seasonNumber}E${firstEpisode.episodeNumber}",
        )
    }
}

private data class StremioRequest(
    val type: String,
    val tmdbId: Int,
    val imdbId: String?,
    val season: Int?,
    val episode: Int?,
    val summary: String,
    val matchTitles: List<String> = emptyList(),
    val playbackContext: EpisodePlaybackContext? = null,
) {
    fun toContentIdRequest(): StremioContentIdRequest = StremioContentIdRequest(
        tmdbId = tmdbId,
        imdbId = imdbId,
        type = type,
        season = season,
        episode = episode,
    )
}

private fun StremioStream.toResolvedCandidate(
    addon: StremioAddonEntity,
    addonLabel: String,
    requestSummary: String,
    requestTitles: List<String>,
    contentId: String,
    playbackContext: EpisodePlaybackContext?,
    similarityAlgorithm: SimilarityAlgorithm,
    index: Int,
): ResolvedStreamCandidate {
    val directUrl = url?.takeIf { isDirectHttp }
    val sourceQualityScore = qualityScore()
    val rawMatchScore = titleMatchScore(
        expectedTitles = requestTitles,
        candidateText = listOfNotNull(title, name, description, behaviorHints?.filename).joinToString(" "),
        algorithm = similarityAlgorithm,
    )
    val matchScore = if (directUrl != null) {
        maxOf(rawMatchScore, ExactStremioContentMatchFloor)
    } else {
        rawMatchScore
    }
    val playerSource = directUrl?.let {
        PlayerSource(
            uri = it,
            title = title ?: name ?: addonLabel,
            headers = behaviorHints?.proxyHeaders?.request.orEmpty(),
            subtitles = subtitles.mapNotNull { subtitle ->
                subtitle.url?.let { subtitleUrl ->
                    SubtitleTrack(
                        id = subtitle.id ?: "$addonLabel-$index-${subtitle.lang ?: "sub"}",
                        label = subtitle.label ?: subtitle.lang ?: "Subtitle",
                        language = subtitle.lang,
                        uri = subtitleUrl,
                    )
                }
            },
            serviceId = "stremio:${addon.transportUrl}",
            serviceHref = contentId,
            context = playbackContext,
        )
    }

    val stateText = when {
        directUrl != null -> "Direct stream"
        ytId != null -> "YouTube handoff pending"
        else -> "Unsupported non-HTTP stream format"
    }

    return ResolvedStreamCandidate(
        id = "${addon.transportUrl}#$index",
        title = title ?: name ?: addonLabel,
        subtitle = addonLabel,
        supportingText = listOfNotNull(
            description?.takeIf { it.isNotBlank() },
            stateText,
            "Match ${(matchScore * 100).toInt()}",
            "Quality ${(sourceQualityScore * 100).toInt()}",
            behaviorHints?.filename,
            "$requestSummary via $contentId".takeIf { playerSource != null && description.isNullOrBlank() },
        ).joinToString(" | ").ifBlank { null },
        addonName = addonLabel,
        isPlayable = playerSource != null,
        qualityScore = sourceQualityScore,
        matchScore = matchScore,
        playerSource = playerSource,
    )
}

private fun StremioAddonEntity.manifest(): StremioManifest? = manifestJson?.runCatching {
    EclipseJson.decodeFromString<StremioManifest>(this)
}?.getOrNull()

private fun StreamEpisodeSelection.toPlaybackContext(): EpisodePlaybackContext = EpisodePlaybackContext(
    localSeasonNumber = localSeasonNumber,
    localEpisodeNumber = localEpisodeNumber,
    anilistMediaId = anilistMediaId,
    tmdbSeasonNumber = seasonNumber,
    tmdbEpisodeNumber = episodeNumber,
)

private fun Int.rejectionSuffix(): String =
    if (this > 0) {
        " Rejected $this torrent or magnet result${if (this == 1) "" else "s"}."
    } else {
        ""
    }
