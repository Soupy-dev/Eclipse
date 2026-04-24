package dev.soupy.eclipse.android.ui.downloads

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.DownloadSnapshot
import dev.soupy.eclipse.android.core.model.DownloadStatus
import dev.soupy.eclipse.android.core.model.PlayerSource
import dev.soupy.eclipse.android.core.model.SubtitleTrack
import dev.soupy.eclipse.android.data.DownloadCleanupResult
import dev.soupy.eclipse.android.data.DownloadDraft
import dev.soupy.eclipse.android.data.DownloadsRepository
import dev.soupy.eclipse.android.feature.downloads.DownloadMetric
import dev.soupy.eclipse.android.feature.downloads.DownloadRow
import dev.soupy.eclipse.android.feature.downloads.DownloadsScreenState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.net.URI

class AndroidDownloadsViewModel(
    private val repository: DownloadsRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(DownloadsScreenState())
    val state: StateFlow<DownloadsScreenState> = _state.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, errorMessage = null)
            repository.loadSnapshot()
                .onSuccess { snapshot ->
                    _state.value = snapshot.toUiState(
                        noticeMessage = _state.value.noticeMessage,
                        playerSource = _state.value.playerSource,
                    )
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        isLoading = false,
                        errorMessage = error.message ?: "Unknown downloads error.",
                    )
                }
        }
    }

    fun queueDownload(draft: DownloadDraft) = mutate(
        successMessage = "Queued download on Android.",
    ) {
        repository.queueDownload(draft)
    }

    fun pause(id: String) = mutate(
        successMessage = "Paused download draft.",
    ) {
        repository.pause(id)
    }

    fun resume(id: String) = mutate(
        successMessage = "Resumed queued download draft.",
    ) {
        repository.resume(id)
    }

    fun playOffline(id: String) {
        viewModelScope.launch {
            repository.loadSnapshot()
                .onSuccess { snapshot ->
                    val record = snapshot.items.firstOrNull { it.id == id }
                    val source = record?.localUri?.let { uri ->
                        PlayerSource(
                            uri = uri,
                            title = record.title,
                            mimeType = record.mimeType,
                            subtitles = record.subtitleFileNames.toOfflineSubtitleTracks(uri),
                            isDownloaded = true,
                        )
                    }
                    _state.value = if (source != null) {
                        snapshot.toUiState(
                            noticeMessage = "Playing ${record.title} from Android app storage.",
                            playerSource = source,
                        )
                    } else {
                        snapshot.toUiState(
                            noticeMessage = "This download does not have a local file yet.",
                            playerSource = _state.value.playerSource,
                        )
                    }
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        errorMessage = error.message ?: "Could not open offline download.",
                    )
                }
        }
    }

    fun markComplete(id: String) = mutate(
        successMessage = "Marked download draft complete.",
    ) {
        repository.markComplete(id)
    }

    fun remove(id: String) = mutate(
        successMessage = "Removed download draft.",
    ) {
        repository.remove(id)
    }

    fun clearCompleted() = mutate(
        successMessage = "Cleared completed downloads.",
    ) {
        repository.clearCompleted()
    }

    fun clearTarget(target: DetailTarget) = mutate(
        successMessage = "Removed downloads for this title.",
    ) {
        repository.clearTarget(target)
    }

    fun clearAll() = mutate(
        successMessage = "Cleared the full Android download queue.",
    ) {
        repository.clearAll()
    }

    fun cleanupOrphans() {
        viewModelScope.launch {
            _state.value = _state.value.copy(errorMessage = null)
            repository.cleanupOrphanFiles()
                .onSuccess { result ->
                    _state.value = result.snapshot.toUiState(
                        noticeMessage = result.cleanupMessage(),
                        playerSource = _state.value.playerSource,
                    )
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        isLoading = false,
                        errorMessage = error.message ?: "Could not clean orphaned downloads.",
                    )
                }
        }
    }

    private fun mutate(
        successMessage: String,
        action: suspend () -> Result<DownloadSnapshot>,
    ) {
        viewModelScope.launch {
            _state.value = _state.value.copy(errorMessage = null)
            action()
                .onSuccess { snapshot ->
                    _state.value = snapshot.toUiState(
                        noticeMessage = successMessage,
                        playerSource = _state.value.playerSource,
                    )
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        isLoading = false,
                        errorMessage = error.message ?: "Unknown downloads error.",
                    )
                }
        }
    }
}

private fun DownloadSnapshot.toUiState(
    noticeMessage: String? = null,
    playerSource: PlayerSource? = null,
): DownloadsScreenState {
    val first = items.firstOrNull()
    val queuedCount = items.count { it.status == DownloadStatus.QUEUED }
    val pausedCount = items.count { it.status == DownloadStatus.PAUSED }
    val downloadingCount = items.count { it.status == DownloadStatus.DOWNLOADING }
    val completedCount = items.count { it.status == DownloadStatus.COMPLETED }
    val targetCounts = items
        .groupingBy { it.detailTarget }
        .eachCount()

    return DownloadsScreenState(
        isLoading = false,
        noticeMessage = noticeMessage,
        playerSource = playerSource,
        heroTitle = first?.title ?: "Downloads",
        heroSubtitle = when {
            downloadingCount > 0 -> "Downloading"
            completedCount > 0 -> "Offline queue"
            queuedCount > 0 -> "Queued downloads"
            pausedCount > 0 -> "Paused downloads"
            else -> "Offline queue"
        },
        heroImageUrl = first?.backdropUrl ?: first?.imageUrl,
        heroSupportingText = when {
            items.isEmpty() ->
                "Android persists offline queue metadata and can save direct streams once a playable source is resolved."
            downloadingCount > 0 ->
                "Android is saving direct streams or packaging HLS segments into app-private storage."
            completedCount > 0 ->
                "Completed direct downloads now survive app restarts with local file metadata."
            else ->
                "These entries keep offline flow state real while unsupported source types are rejected before download."
        },
        metrics = listOf(
            DownloadMetric(
                label = "Queued",
                value = queuedCount.toString(),
                supportingText = "Waiting for a direct source or retry.",
            ),
            DownloadMetric(
                label = "Active",
                value = downloadingCount.toString(),
                supportingText = "Direct stream transfer in progress.",
            ),
            DownloadMetric(
                label = "Paused",
                value = pausedCount.toString(),
                supportingText = "Held until you resume the same draft.",
            ),
            DownloadMetric(
                label = "Done",
                value = completedCount.toString(),
                supportingText = "Offline files with local metadata.",
            ),
        ),
        items = items.map { record ->
            DownloadRow(
                id = record.id,
                title = record.title,
                subtitle = record.subtitle,
                imageUrl = record.imageUrl,
                backdropUrl = record.backdropUrl,
                mediaLabel = record.mediaLabel,
                statusLabel = when (record.status) {
                    DownloadStatus.QUEUED -> "Queued"
                    DownloadStatus.DOWNLOADING -> "Downloading"
                    DownloadStatus.PAUSED -> "Paused"
                    DownloadStatus.COMPLETED -> "Completed"
                    DownloadStatus.FAILED -> "Failed"
                },
                progressPercent = record.progressPercent,
                progressLabel = record.progressLabel ?: record.localUri?.let { "Stored locally as ${record.localFileName}" },
                sourceLabel = record.sourceLabel,
                hasDirectSource = !record.sourceUri.isNullOrBlank(),
                subtitleCount = record.subtitleTracks.size,
                detailTarget = record.detailTarget,
                canPause = record.status == DownloadStatus.QUEUED || record.status == DownloadStatus.DOWNLOADING,
                canResume = record.status == DownloadStatus.PAUSED || record.status == DownloadStatus.FAILED,
                canMarkComplete = record.status != DownloadStatus.COMPLETED,
                canPlayOffline = record.status == DownloadStatus.COMPLETED && !record.localUri.isNullOrBlank(),
                removeTargetLabel = if ((targetCounts[record.detailTarget] ?: 0) > 1) {
                    record.detailTarget.removeTargetLabel()
                } else {
                    null
                },
            )
        },
    )
}

private fun DetailTarget.removeTargetLabel(): String = when (this) {
    is DetailTarget.AniListMediaTarget -> "Remove Anime"
    is DetailTarget.TmdbMovie -> "Remove Movie"
    is DetailTarget.TmdbShow -> "Remove Show"
}

private fun List<String>.toOfflineSubtitleTracks(localUri: String): List<SubtitleTrack> {
    if (isEmpty()) return emptyList()
    val directory = runCatching { File(URI(localUri)).parentFile }.getOrNull() ?: return emptyList()
    return mapIndexed { index, fileName ->
        SubtitleTrack(
            id = "offline-subtitle-${index + 1}",
            label = "Offline Subtitle ${index + 1}",
            uri = File(directory, fileName).toURI().toString(),
        )
    }
}

private fun DownloadCleanupResult.cleanupMessage(): String =
    if (deletedFiles == 0) {
        "No orphaned download files were found."
    } else {
        "Removed $deletedFiles orphaned download file${if (deletedFiles == 1) "" else "s"} (${deletedBytes.toByteCountLabel()})."
    }

private fun Long.toByteCountLabel(): String {
    if (this < 1_000) return "$this B"
    val units = listOf("KB", "MB", "GB")
    var value = this / 1_000.0
    var unit = units.first()
    for (candidate in units.drop(1)) {
        if (value < 1_000.0) break
        value /= 1_000.0
        unit = candidate
    }
    return "%.1f %s".format(value, unit)
}
