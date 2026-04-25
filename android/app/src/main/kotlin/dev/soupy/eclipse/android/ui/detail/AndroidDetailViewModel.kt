package dev.soupy.eclipse.android.ui.detail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.soupy.eclipse.android.core.storage.SettingsStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import dev.soupy.eclipse.android.data.ContinueWatchingDraft
import dev.soupy.eclipse.android.data.DetailContent
import dev.soupy.eclipse.android.data.DetailRepository
import dev.soupy.eclipse.android.data.DownloadDraft
import dev.soupy.eclipse.android.data.EpisodeProgressDraft
import dev.soupy.eclipse.android.data.LibraryItemDraft
import dev.soupy.eclipse.android.data.MovieProgressDraft
import dev.soupy.eclipse.android.data.orNull
import dev.soupy.eclipse.android.data.ProgressRepository
import dev.soupy.eclipse.android.data.RatingsRepository
import dev.soupy.eclipse.android.data.StreamResolutionRepository
import dev.soupy.eclipse.android.data.StreamEpisodeSelection
import dev.soupy.eclipse.android.data.TrackerPlaybackProgressDraft
import dev.soupy.eclipse.android.data.TrackerRepository
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.EpisodePlaybackContext
import dev.soupy.eclipse.android.core.model.PlayerSource
import dev.soupy.eclipse.android.core.model.SkipSegment
import dev.soupy.eclipse.android.feature.detail.DetailCastRow
import dev.soupy.eclipse.android.feature.detail.DetailEpisodeRow
import dev.soupy.eclipse.android.feature.detail.DetailFactRow
import dev.soupy.eclipse.android.feature.detail.DetailScreenState
import dev.soupy.eclipse.android.feature.detail.DetailStreamRow
import dev.soupy.eclipse.android.core.network.AniSkipService
import dev.soupy.eclipse.android.core.network.IntroDbService
import kotlin.math.roundToInt

class AndroidDetailViewModel(
    private val repository: DetailRepository,
    private val streamResolutionRepository: StreamResolutionRepository,
    private val progressRepository: ProgressRepository,
    private val ratingsRepository: RatingsRepository,
    private val trackerRepository: TrackerRepository,
    private val aniSkipService: AniSkipService,
    private val introDbService: IntroDbService,
    private val settingsStore: SettingsStore,
) : ViewModel() {
    private val _state = MutableStateFlow(DetailScreenState())
    val state: StateFlow<DetailScreenState> = _state.asStateFlow()

    private var currentTarget: DetailTarget? = null
    private var currentProgressTarget: DetailTarget? = null
    private var currentRatingTmdbId: Int? = null
    private var skipProviderSettings = SkipProviderSettings()
    private val syncedTrackerProgressKeys = mutableSetOf<String>()

    init {
        viewModelScope.launch {
            settingsStore.settings.collect { settings ->
                skipProviderSettings = SkipProviderSettings(
                    aniSkipEnabled = settings.aniSkipEnabled,
                    introDbEnabled = settings.introDbEnabled,
                )
            }
        }
    }

    fun load(target: DetailTarget?) {
        if (target == null) {
            currentTarget = null
            currentProgressTarget = null
            currentRatingTmdbId = null
            _state.value = DetailScreenState()
            return
        }

        if (target == currentTarget && (_state.value.title.isNotBlank() || _state.value.isLoading)) {
            return
        }

        currentTarget = target
        viewModelScope.launch {
            _state.value = DetailScreenState(hasSelection = true, isLoading = true)
            val result = repository.load(target)
            result
                .onSuccess { content ->
                    currentProgressTarget = content.progressTarget ?: target
                    currentRatingTmdbId = (currentProgressTarget ?: target).tmdbRatingId()
                    val rating = currentRatingTmdbId?.let { id ->
                        ratingsRepository.loadSnapshot().getOrNull()?.ratings?.get(id.toString())
                    }
                    _state.value = content.toUiState(userRating = rating)
                }
                .onFailure { error ->
                    currentProgressTarget = null
                    currentRatingTmdbId = null
                    _state.update {
                        it.copy(
                            hasSelection = true,
                            isLoading = false,
                            errorMessage = error.message ?: "Unknown detail error.",
                        )
                    }
                }
        }
    }

    fun setUserRating(rating: Int) {
        val tmdbId = currentRatingTmdbId ?: return markUnsupportedRating()
        viewModelScope.launch {
            ratingsRepository.setRating(tmdbId, rating)
                .onSuccess {
                    _state.update {
                        it.copy(
                            userRating = rating.coerceIn(1, 5),
                            streamStatusMessage = "Saved rating ${rating.coerceIn(1, 5)}/5.",
                        )
                    }
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(streamStatusMessage = error.message ?: "Could not save rating.")
                    }
                }
        }
    }

    fun clearUserRating() {
        val tmdbId = currentRatingTmdbId ?: return markUnsupportedRating()
        viewModelScope.launch {
            ratingsRepository.removeRating(tmdbId)
                .onSuccess {
                    _state.update {
                        it.copy(userRating = null, streamStatusMessage = "Removed your rating.")
                    }
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(streamStatusMessage = error.message ?: "Could not remove rating.")
                    }
                }
        }
    }

    fun markCurrentWatched() {
        markCurrent(watched = true)
    }

    fun markCurrentUnwatched() {
        markCurrent(watched = false)
    }

    fun markEpisodeWatched(episodeId: String) {
        markEpisode(episodeId = episodeId, watched = true)
    }

    fun markEpisodeUnwatched(episodeId: String) {
        markEpisode(episodeId = episodeId, watched = false)
    }

    fun markPreviousEpisodesWatched(episodeId: String) {
        val target = currentProgressTarget as? DetailTarget.TmdbShow ?: return markUnsupportedProgress()
        val episodes = state.value.episodes
        val episodeIndex = episodes.indexOfFirst { it.id == episodeId }
        if (episodeIndex < 0) return
        val episode = episodes[episodeIndex]
        val localSeasonNumber = episode.seasonNumber ?: return
        val localEpisodeNumber = episode.episodeNumber ?: return
        val previousEpisodes = episodes
            .take(episodeIndex)
            .filter { previous ->
                previous.seasonNumber == localSeasonNumber &&
                    previous.sourceSeasonNumber != null &&
                    previous.sourceEpisodeNumber != null
            }
        if (localEpisodeNumber <= 1 || previousEpisodes.isEmpty()) {
            _state.update { it.copy(streamStatusMessage = "There are no previous episodes in this season.") }
            return
        }
        viewModelScope.launch {
            var failureMessage: String? = null
            previousEpisodes.forEach { previous ->
                progressRepository.markEpisodeWatched(
                    showId = target.id,
                    seasonNumber = previous.sourceSeasonNumber ?: return@forEach,
                    episodeNumber = previous.sourceEpisodeNumber ?: return@forEach,
                    watched = true,
                ).onFailure { error ->
                    failureMessage = error.message ?: "Could not mark previous episodes watched."
                }
            }
            if (failureMessage == null) {
                _state.update {
                    it.copy(streamStatusMessage = "Marked ${previousEpisodes.size} previous episode${if (previousEpisodes.size == 1) "" else "s"} watched.")
                }
            } else {
                _state.update { it.copy(streamStatusMessage = failureMessage) }
            }
        }
    }

    fun retry() {
        load(currentTarget)
    }

    fun resolveStreams() {
        val selectedEpisode = state.value.selectedEpisodeId
            ?.let { id -> state.value.episodes.firstOrNull { it.id == id } }
            ?.toStreamEpisodeSelection()
        resolveStreamsForEpisode(selectedEpisode)
    }

    fun resolveEpisodeStreams(episodeId: String) {
        val episode = state.value.episodes.firstOrNull { it.id == episodeId } ?: return
        val selection = episode.toStreamEpisodeSelection() ?: return
        resolveStreamsForEpisode(selection)
    }

    private fun resolveStreamsForEpisode(episode: StreamEpisodeSelection?) {
        val target = currentTarget ?: return
        if (_state.value.isResolvingStreams) return

        viewModelScope.launch {
            _state.update {
                it.copy(
                    isResolvingStreams = true,
                    streamStatusMessage = episode?.let { selected ->
                        "Resolving addon streams for ${selected.label}..."
                    } ?: "Resolving addon streams...",
                    selectedEpisodeId = episode?.let { selected ->
                        _state.value.episodes.firstOrNull { it.matchesSelection(selected) }?.id
                    } ?: it.selectedEpisodeId,
                    selectedEpisodeLabel = episode?.label ?: it.selectedEpisodeLabel,
                )
            }
            streamResolutionRepository.resolve(target, episode)
                .onSuccess { result ->
                    _state.update { state ->
                        state.copy(
                            isResolvingStreams = false,
                            streamStatusMessage = result.statusMessage,
                            streamCandidates = result.candidates.map { candidate ->
                                DetailStreamRow(
                                    id = candidate.id,
                                    title = candidate.title,
                                    subtitle = candidate.subtitle,
                                    supportingText = candidate.supportingText,
                                    playable = candidate.isPlayable,
                                    playerSource = candidate.playerSource,
                                )
                            },
                            playerSource = result.selectedSource ?: state.playerSource,
                            skipSegments = if (result.selectedSource != null) emptyList() else state.skipSegments,
                            skipStatusMessage = if (result.selectedSource != null) {
                                "Loading skip segments..."
                            } else {
                                state.skipStatusMessage
                            },
                        )
                    }
                    result.selectedSource?.let(::loadSkipSegmentsFor)
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(
                            isResolvingStreams = false,
                            streamStatusMessage = error.message ?: "Stream resolution failed.",
                            streamCandidates = emptyList(),
                        )
                    }
                }
        }
    }

    fun playResolvedStream(streamId: String) {
        val selectedSource = state.value.streamCandidates.firstOrNull { it.id == streamId }?.playerSource
        _state.update { state ->
            state.copy(
                playerSource = selectedSource ?: state.playerSource,
                skipSegments = if (selectedSource != null) emptyList() else state.skipSegments,
                skipStatusMessage = if (selectedSource != null) "Loading skip segments..." else state.skipStatusMessage,
            )
        }
        selectedSource?.let(::loadSkipSegmentsFor)
    }

    fun playNextEpisode() {
        val nextEpisode = nextEpisodeAfterCurrent()
        if (nextEpisode == null) {
            _state.update { it.copy(streamStatusMessage = "No next episode is loaded yet.") }
            return
        }
        val selection = nextEpisode.toStreamEpisodeSelection()
        if (selection == null) {
            _state.update { it.copy(streamStatusMessage = "Next episode metadata is not playable yet.") }
            return
        }
        resolveStreamsForEpisode(selection)
    }

    fun currentPlaybackProgressDraft(
        positionMs: Long,
        durationMs: Long,
        isFinished: Boolean,
    ): ContinueWatchingDraft? {
        val target = currentProgressTarget ?: currentTarget ?: return null
        val snapshot = state.value
        if (snapshot.title.isBlank() || durationMs <= 0L) return null

        val progressPercent = if (isFinished) {
            1f
        } else {
            (positionMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
        }
        if (!isFinished && positionMs < 15_000L && progressPercent < 0.05f) {
            return null
        }

        val selectedEpisode = snapshot.selectedEpisodeId
            ?.let { id -> snapshot.episodes.firstOrNull { it.id == id } }
            ?: snapshot.episodes.firstOrNull()
        recordTypedProgress(
            target = target,
            snapshot = snapshot,
            selectedEpisode = selectedEpisode,
            positionMs = positionMs,
            durationMs = durationMs,
            isFinished = isFinished,
        )
        syncTrackersIfNeeded(
            target = target,
            snapshot = snapshot,
            selectedEpisode = selectedEpisode,
            progressPercent = progressPercent.toDouble(),
            isFinished = isFinished,
        )

        val subtitle = selectedEpisode?.title ?: snapshot.subtitle ?: snapshot.playerSource?.title
        val progressLabel = listOfNotNull(
            selectedEpisode?.subtitle,
            "${(progressPercent * 100f).roundToInt()}% watched",
        ).joinToString(" | ").ifBlank {
            "${(progressPercent * 100f).roundToInt()}% watched"
        }

        return ContinueWatchingDraft(
            detailTarget = target,
            title = snapshot.title,
            subtitle = subtitle,
            imageUrl = snapshot.posterUrl,
            backdropUrl = snapshot.backdropUrl,
            progressPercent = progressPercent,
            progressLabel = progressLabel,
        )
    }

    fun currentLibraryItemDraft(): LibraryItemDraft? {
        val target = currentTarget ?: return null
        val snapshot = state.value
        if (snapshot.title.isBlank()) return null

        return LibraryItemDraft(
            detailTarget = target,
            title = snapshot.title,
            subtitle = snapshot.subtitle,
            overview = snapshot.overview,
            imageUrl = snapshot.posterUrl,
            backdropUrl = snapshot.backdropUrl,
            mediaLabel = snapshot.metadataChips.firstOrNull(),
        )
    }

    fun currentContinueWatchingDraft(): ContinueWatchingDraft? {
        val target = currentTarget ?: return null
        val snapshot = state.value
        if (snapshot.title.isBlank()) return null

        val firstEpisode = snapshot.episodes.firstOrNull()
        return ContinueWatchingDraft(
            detailTarget = target,
            title = snapshot.title,
            subtitle = firstEpisode?.title ?: snapshot.subtitle,
            imageUrl = snapshot.posterUrl,
            backdropUrl = snapshot.backdropUrl,
            progressPercent = if (firstEpisode == null) 0.42f else 0.08f,
            progressLabel = firstEpisode?.let { episode ->
                episode.subtitle?.let { "Resume near $it" } ?: "Resume from ${episode.title}"
            } ?: "Resume from the last saved movie position.",
        )
    }

    fun currentDownloadDraft(): DownloadDraft? {
        val target = currentTarget ?: return null
        val snapshot = state.value
        if (snapshot.title.isBlank()) return null

        val selectedEpisode = snapshot.selectedEpisodeId
            ?.let { id -> snapshot.episodes.firstOrNull { it.id == id } }
            ?: snapshot.episodes.firstOrNull()
        val playbackContext = snapshot.playerSource?.context
        val isEpisodeDraft = selectedEpisode != null || playbackContext != null
        return DownloadDraft(
            detailTarget = target,
            title = snapshot.title,
            subtitle = selectedEpisode?.title ?: snapshot.subtitle,
            imageUrl = snapshot.posterUrl,
            backdropUrl = snapshot.backdropUrl,
            mediaLabel = snapshot.metadataChips.firstOrNull(),
            progressLabel = selectedEpisode?.subtitle?.let { "Preparing offline draft near $it" }
                ?: "Preparing an offline draft from the current source.",
            sourceLabel = snapshot.playerSource?.title ?: if (isEpisodeDraft) {
                "Episode download draft"
            } else {
                "Movie download draft"
            },
            downloadKeySuffix = selectedEpisode?.downloadKeySuffix()
                ?: playbackContext?.downloadKeySuffix(),
            playerSource = snapshot.playerSource,
        )
    }

    private fun recordTypedProgress(
        target: DetailTarget,
        snapshot: DetailScreenState,
        selectedEpisode: DetailEpisodeRow?,
        positionMs: Long,
        durationMs: Long,
        isFinished: Boolean,
    ) {
        val currentSeconds = positionMs.toDouble() / 1000.0
        val durationSeconds = durationMs.toDouble() / 1000.0
        when (target) {
            is DetailTarget.TmdbMovie -> {
                viewModelScope.launch {
                    progressRepository.recordMovieProgress(
                        MovieProgressDraft(
                            movieId = target.id,
                            title = snapshot.title,
                            posterUrl = snapshot.posterUrl,
                            currentTimeSeconds = currentSeconds,
                            totalDurationSeconds = durationSeconds,
                            isFinished = isFinished,
                            lastServiceId = snapshot.playerSource?.serviceId,
                            lastHref = snapshot.playerSource?.serviceHref,
                        ),
                    )
                }
            }
            is DetailTarget.TmdbShow -> {
                val episode = selectedEpisode ?: return
                val seasonNumber = episode.sourceSeasonNumber ?: return
                val episodeNumber = episode.sourceEpisodeNumber ?: return
                viewModelScope.launch {
                    progressRepository.recordEpisodeProgress(
                        EpisodeProgressDraft(
                            showId = target.id,
                            seasonNumber = seasonNumber,
                            episodeNumber = episodeNumber,
                            showTitle = snapshot.title,
                            showPosterUrl = snapshot.posterUrl,
                            anilistMediaId = snapshot.playerSource?.context?.anilistMediaId,
                            currentTimeSeconds = currentSeconds,
                            totalDurationSeconds = durationSeconds,
                            isFinished = isFinished,
                            lastServiceId = snapshot.playerSource?.serviceId,
                            lastHref = snapshot.playerSource?.serviceHref,
                        ),
                    )
                }
            }
            is DetailTarget.AniListMediaTarget,
            is DetailTarget.ServiceMedia -> Unit
        }
    }

    private fun syncTrackersIfNeeded(
        target: DetailTarget,
        snapshot: DetailScreenState,
        selectedEpisode: DetailEpisodeRow?,
        progressPercent: Double,
        isFinished: Boolean,
    ) {
        if (!isFinished && progressPercent < TrackerSyncProgressThreshold) return

        val syncKey = when (target) {
            is DetailTarget.TmdbMovie -> "movie:${target.id}"
            is DetailTarget.TmdbShow -> {
                val episode = selectedEpisode ?: return
                val seasonNumber = episode.sourceSeasonNumber ?: return
                val episodeNumber = episode.sourceEpisodeNumber ?: return
                "show:${target.id}:$seasonNumber:$episodeNumber"
            }
            is DetailTarget.AniListMediaTarget,
            is DetailTarget.ServiceMedia -> return
        }
        if (!syncedTrackerProgressKeys.add(syncKey)) return

        viewModelScope.launch {
            trackerRepository.syncPlaybackProgress(
                TrackerPlaybackProgressDraft(
                    target = target,
                    title = snapshot.title,
                    seasonNumber = selectedEpisode?.sourceSeasonNumber,
                    episodeNumber = selectedEpisode?.sourceEpisodeNumber,
                    anilistMediaId = snapshot.playerSource?.context?.anilistMediaId,
                    progressPercent = progressPercent,
                    isFinished = isFinished,
                    playbackContext = snapshot.playerSource?.context,
                ),
            )
        }
    }

    private fun markCurrent(watched: Boolean) {
        when (val target = currentProgressTarget ?: currentTarget) {
            is DetailTarget.TmdbMovie -> {
                viewModelScope.launch {
                    progressRepository.markMovieWatched(target.id, watched)
                        .onSuccess {
                            _state.update {
                                it.copy(streamStatusMessage = if (watched) "Marked movie watched." else "Marked movie unwatched.")
                            }
                        }
                        .onFailure { error ->
                            _state.update {
                                it.copy(streamStatusMessage = error.message ?: "Could not update movie progress.")
                            }
                        }
                }
            }
            is DetailTarget.TmdbShow -> markLoadedShowEpisodes(target.id, watched)
            is DetailTarget.AniListMediaTarget,
            is DetailTarget.ServiceMedia,
            null -> markUnsupportedProgress()
        }
    }

    private fun markLoadedShowEpisodes(showId: Int, watched: Boolean) {
        val episodes = state.value.episodes.filter {
            it.sourceSeasonNumber != null && it.sourceEpisodeNumber != null
        }
        if (episodes.isEmpty()) {
            markUnsupportedProgress()
            return
        }
        viewModelScope.launch {
            episodes.forEach { episode ->
                progressRepository.markEpisodeWatched(
                    showId = showId,
                    seasonNumber = episode.sourceSeasonNumber ?: return@forEach,
                    episodeNumber = episode.sourceEpisodeNumber ?: return@forEach,
                    watched = watched,
                )
            }
            _state.update {
                it.copy(
                    streamStatusMessage = if (watched) {
                        "Marked ${episodes.size} loaded episodes watched."
                    } else {
                        "Marked ${episodes.size} loaded episodes unwatched."
                    },
                )
            }
        }
    }

    private fun markEpisode(episodeId: String, watched: Boolean) {
        val target = currentProgressTarget as? DetailTarget.TmdbShow ?: return markUnsupportedProgress()
        val episode = state.value.episodes.firstOrNull { it.id == episodeId } ?: return
        val seasonNumber = episode.sourceSeasonNumber ?: return
        val episodeNumber = episode.sourceEpisodeNumber ?: return
        viewModelScope.launch {
            progressRepository.markEpisodeWatched(
                showId = target.id,
                seasonNumber = seasonNumber,
                episodeNumber = episodeNumber,
                watched = watched,
            ).onSuccess {
                _state.update {
                    it.copy(
                        streamStatusMessage = if (watched) {
                            "Marked S${seasonNumber}E${episodeNumber} watched."
                        } else {
                            "Marked S${seasonNumber}E${episodeNumber} unwatched."
                        },
                    )
                }
            }.onFailure { error ->
                _state.update {
                    it.copy(streamStatusMessage = error.message ?: "Could not update episode progress.")
                }
            }
        }
    }

    private fun markUnsupportedProgress() {
        _state.update {
            it.copy(streamStatusMessage = "Progress actions need a TMDB movie or mapped TMDB series.")
        }
    }

    private fun markUnsupportedRating() {
        _state.update {
            it.copy(streamStatusMessage = "Ratings need a TMDB movie or mapped TMDB series.")
        }
    }

    private fun nextEpisodeAfterCurrent(): DetailEpisodeRow? {
        val playableEpisodes = state.value.episodes.filter {
            it.sourceSeasonNumber != null && it.sourceEpisodeNumber != null
        }
        if (playableEpisodes.size < 2) return null
        val currentIndex = state.value.selectedEpisodeId
            ?.let { id -> playableEpisodes.indexOfFirst { it.id == id } }
            ?.takeIf { it >= 0 }
            ?: 0
        return playableEpisodes.getOrNull(currentIndex + 1)
    }

    private fun loadSkipSegmentsFor(source: PlayerSource) {
        val target = currentProgressTarget ?: currentTarget ?: return
        val context = source.context
        viewModelScope.launch {
            val providerSettings = skipProviderSettings
            if (!providerSettings.aniSkipEnabled && !providerSettings.introDbEnabled) {
                _state.update {
                    it.copy(
                        skipSegments = emptyList(),
                        skipStatusMessage = "Skip segment providers are disabled in Settings.",
                    )
                }
                return@launch
            }

            val introSegments = if (providerSettings.introDbEnabled) {
                when (target) {
                    is DetailTarget.TmdbMovie -> introDbService.fetchSkipTimes(
                        tmdbId = target.id,
                    ).orNull().orEmpty()
                    is DetailTarget.TmdbShow -> introDbService.fetchSkipTimes(
                        tmdbId = target.id,
                        seasonNumber = context?.resolvedTMDBSeasonNumber,
                        episodeNumber = context?.resolvedTMDBEpisodeNumber,
                    ).orNull().orEmpty()
                    is DetailTarget.AniListMediaTarget,
                    is DetailTarget.ServiceMedia -> emptyList()
                }
            } else {
                emptyList()
            }
            val aniSkipSegments = if (providerSettings.aniSkipEnabled) context?.anilistMediaId?.let { anilistId ->
                aniSkipService.fetchSkipTimes(
                    anilistId = anilistId,
                    episodeNumber = context.localEpisodeNumber,
                    episodeDurationSeconds = 0.0,
                ).orNull().orEmpty()
            }.orEmpty() else emptyList()

            val merged = (introSegments + aniSkipSegments).mergeSkipSegments()
            _state.update {
                it.copy(
                    skipSegments = merged,
                    skipStatusMessage = when {
                        merged.isEmpty() -> "No skip segments found yet for this source."
                        else -> "Loaded ${merged.size} skip segment${if (merged.size == 1) "" else "s"} for manual${if (merged.isNotEmpty()) "/auto" else ""} skipping."
                    },
                )
            }
        }
    }
}

private data class SkipProviderSettings(
    val aniSkipEnabled: Boolean = true,
    val introDbEnabled: Boolean = true,
)

private fun DetailContent.toUiState(userRating: Int?): DetailScreenState = DetailScreenState(
    hasSelection = true,
    isLoading = false,
    title = title,
    subtitle = subtitle,
    overview = overview,
    posterUrl = posterUrl,
    backdropUrl = backdropUrl,
    metadataChips = metadataChips,
    detailFacts = detailFacts.map {
        DetailFactRow(
            label = it.label,
            value = it.value,
        )
    },
    contentRating = contentRating,
    userRating = userRating,
    cast = cast.map {
        DetailCastRow(
            id = it.id,
            name = it.name,
            role = it.role,
            imageUrl = it.imageUrl,
        )
    },
    episodesTitle = episodesTitle,
    episodes = episodes.map {
        DetailEpisodeRow(
            id = it.id,
            title = it.title,
            subtitle = it.subtitle,
            imageUrl = it.imageUrl,
            overview = it.overview,
            seasonNumber = it.seasonNumber,
            episodeNumber = it.episodeNumber,
            runtimeMinutes = it.runtimeMinutes,
            tmdbSeasonNumber = it.tmdbSeasonNumber,
            tmdbEpisodeNumber = it.tmdbEpisodeNumber,
            isSpecial = it.isSpecial,
            titleOnlySearch = it.titleOnlySearch,
            searchTitle = it.searchTitle,
            serviceHref = it.serviceHref,
        )
    },
    isMovie = isMovie,
)

private fun DetailTarget.tmdbRatingId(): Int? = when (this) {
    is DetailTarget.TmdbMovie -> id
    is DetailTarget.TmdbShow -> id
    is DetailTarget.AniListMediaTarget -> null
    is DetailTarget.ServiceMedia -> null
}

private fun DetailEpisodeRow.toStreamEpisodeSelection(): StreamEpisodeSelection? {
    val localSeason = seasonNumber ?: tmdbSeasonNumber ?: return null
    val localEpisode = episodeNumber ?: tmdbEpisodeNumber ?: return null
    val useTitleOnly = titleOnlySearch || (isSpecial && (tmdbSeasonNumber == null || tmdbEpisodeNumber == null))
    val season = if (useTitleOnly) null else tmdbSeasonNumber ?: localSeason
    val episode = if (useTitleOnly) null else tmdbEpisodeNumber ?: localEpisode
    return StreamEpisodeSelection(
        seasonNumber = season,
        episodeNumber = episode,
        label = if (isSpecial) "Special E$localEpisode" else "S${localSeason}E${localEpisode}",
        localSeasonNumber = localSeason,
        localEpisodeNumber = localEpisode,
        searchTitle = searchTitle ?: title,
        isSpecial = isSpecial,
        titleOnlySearch = useTitleOnly,
        serviceHref = serviceHref,
    )
}

private val DetailEpisodeRow.sourceSeasonNumber: Int?
    get() = tmdbSeasonNumber ?: seasonNumber

private val DetailEpisodeRow.sourceEpisodeNumber: Int?
    get() = tmdbEpisodeNumber ?: episodeNumber

private fun DetailEpisodeRow.downloadKeySuffix(): String? {
    val season = sourceSeasonNumber ?: return null
    val episode = sourceEpisodeNumber ?: return null
    return "s${season}_e${episode}"
}

private fun EpisodePlaybackContext.downloadKeySuffix(): String =
    "s${resolvedTMDBSeasonNumber}_e${resolvedTMDBEpisodeNumber}"

private fun DetailEpisodeRow.matchesSelection(selection: StreamEpisodeSelection): Boolean =
    sourceSeasonNumber == selection.seasonNumber &&
        sourceEpisodeNumber == selection.episodeNumber &&
        (seasonNumber ?: sourceSeasonNumber) == selection.localSeasonNumber &&
        (episodeNumber ?: sourceEpisodeNumber) == selection.localEpisodeNumber

private fun List<SkipSegment>.mergeSkipSegments(): List<SkipSegment> =
    sortedWith(
        compareBy<SkipSegment> { it.startTime }
            .thenBy { it.endTime }
            .thenBy { it.type.id },
    )
        .distinctBy { segment ->
            "${segment.type.id}:${segment.startTime.toInt()}:${segment.endTime.toInt()}"
        }

private const val TrackerSyncProgressThreshold = 0.85


