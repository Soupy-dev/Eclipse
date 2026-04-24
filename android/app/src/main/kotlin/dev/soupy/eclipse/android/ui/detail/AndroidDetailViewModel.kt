package dev.soupy.eclipse.android.ui.detail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import dev.soupy.eclipse.android.data.ContinueWatchingDraft
import dev.soupy.eclipse.android.data.DetailContent
import dev.soupy.eclipse.android.data.DetailRepository
import dev.soupy.eclipse.android.data.DownloadDraft
import dev.soupy.eclipse.android.data.EpisodeProgressDraft
import dev.soupy.eclipse.android.data.LibraryItemDraft
import dev.soupy.eclipse.android.data.MovieProgressDraft
import dev.soupy.eclipse.android.data.ProgressRepository
import dev.soupy.eclipse.android.data.StreamResolutionRepository
import dev.soupy.eclipse.android.data.StreamEpisodeSelection
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.feature.detail.DetailEpisodeRow
import dev.soupy.eclipse.android.feature.detail.DetailScreenState
import dev.soupy.eclipse.android.feature.detail.DetailStreamRow
import kotlin.math.roundToInt

class AndroidDetailViewModel(
    private val repository: DetailRepository,
    private val streamResolutionRepository: StreamResolutionRepository,
    private val progressRepository: ProgressRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(DetailScreenState())
    val state: StateFlow<DetailScreenState> = _state.asStateFlow()

    private var currentTarget: DetailTarget? = null

    fun load(target: DetailTarget?) {
        if (target == null) {
            currentTarget = null
            _state.value = DetailScreenState()
            return
        }

        if (target == currentTarget && (_state.value.title.isNotBlank() || _state.value.isLoading)) {
            return
        }

        currentTarget = target
        viewModelScope.launch {
            _state.value = DetailScreenState(hasSelection = true, isLoading = true)
            repository.load(target)
                .onSuccess { content ->
                    _state.value = content.toUiState()
                }
                .onFailure { error ->
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
                        _state.value.episodes.firstOrNull {
                            it.seasonNumber == selected.seasonNumber && it.episodeNumber == selected.episodeNumber
                        }?.id
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
                        )
                    }
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(
                            isResolvingStreams = false,
                            streamStatusMessage = error.message ?: "Android stream resolution failed.",
                            streamCandidates = emptyList(),
                        )
                    }
                }
        }
    }

    fun playResolvedStream(streamId: String) {
        _state.update { state ->
            state.copy(
                playerSource = state.streamCandidates.firstOrNull { it.id == streamId }?.playerSource
                    ?: state.playerSource,
            )
        }
    }

    fun currentPlaybackProgressDraft(
        positionMs: Long,
        durationMs: Long,
        isFinished: Boolean,
    ): ContinueWatchingDraft? {
        val target = currentTarget ?: return null
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
            } ?: "Resume from the last saved movie position once playback reporting is wired.",
        )
    }

    fun currentDownloadDraft(): DownloadDraft? {
        val target = currentTarget ?: return null
        val snapshot = state.value
        if (snapshot.title.isBlank()) return null

        val firstEpisode = snapshot.episodes.firstOrNull()
        return DownloadDraft(
            detailTarget = target,
            title = snapshot.title,
            subtitle = firstEpisode?.title ?: snapshot.subtitle,
            imageUrl = snapshot.posterUrl,
            backdropUrl = snapshot.backdropUrl,
            mediaLabel = snapshot.metadataChips.firstOrNull(),
            progressLabel = firstEpisode?.subtitle?.let { "Preparing offline draft near $it" }
                ?: "Preparing an offline draft while Android source resolution lands.",
            sourceLabel = snapshot.playerSource?.title ?: if (firstEpisode == null) {
                "Movie download draft"
            } else {
                "Episode download draft"
            },
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
                        ),
                    )
                }
            }
            is DetailTarget.TmdbShow -> {
                val episode = selectedEpisode ?: return
                val seasonNumber = episode.seasonNumber ?: return
                val episodeNumber = episode.episodeNumber ?: return
                viewModelScope.launch {
                    progressRepository.recordEpisodeProgress(
                        EpisodeProgressDraft(
                            showId = target.id,
                            seasonNumber = seasonNumber,
                            episodeNumber = episodeNumber,
                            showTitle = snapshot.title,
                            showPosterUrl = snapshot.posterUrl,
                            currentTimeSeconds = currentSeconds,
                            totalDurationSeconds = durationSeconds,
                            isFinished = isFinished,
                        ),
                    )
                }
            }
            is DetailTarget.AniListMediaTarget -> Unit
        }
    }
}

private fun DetailContent.toUiState(): DetailScreenState = DetailScreenState(
    hasSelection = true,
    isLoading = false,
    title = title,
    subtitle = subtitle,
    overview = overview,
    posterUrl = posterUrl,
    backdropUrl = backdropUrl,
    metadataChips = metadataChips,
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
        )
    },
)

private fun DetailEpisodeRow.toStreamEpisodeSelection(): StreamEpisodeSelection? {
    val season = seasonNumber ?: return null
    val episode = episodeNumber ?: return null
    return StreamEpisodeSelection(
        seasonNumber = season,
        episodeNumber = episode,
        label = "S${season}E${episode}",
    )
}


