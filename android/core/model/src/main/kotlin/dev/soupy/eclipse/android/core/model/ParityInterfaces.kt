package dev.soupy.eclipse.android.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

@Serializable
data class StreamResolutionRequest(
    val target: DetailTarget,
    val sourceIds: List<String> = emptyList(),
    val autoMode: Boolean = false,
)

@Serializable
data class StreamResolutionSnapshot(
    val statusMessage: String,
    val candidates: List<StreamCandidate> = emptyList(),
    val selectedSource: PlayerSource? = null,
)

@Serializable
data class StreamCandidate(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val sourceName: String,
    val qualityScore: Double = 0.0,
    val isPlayable: Boolean = false,
    val unsupportedReason: String? = null,
    val playerSource: PlayerSource? = null,
)

interface StreamResolver {
    suspend fun resolve(request: StreamResolutionRequest): Result<StreamResolutionSnapshot>
}

@Serializable
data class DownloadRequest(
    val id: String,
    val target: DetailTarget,
    val title: String,
    val source: PlayerSource,
    val imageUrl: String? = null,
    val metadata: JsonObject = JsonObject(emptyMap()),
)

@Serializable
data class DownloadProgressSnapshot(
    val id: String,
    val status: DownloadStatus,
    val progressPercent: Float = 0f,
    val downloadedBytes: Long = 0,
    val totalBytes: Long = 0,
    val localUri: String? = null,
    val error: String? = null,
)

interface DownloadEngine {
    suspend fun enqueue(request: DownloadRequest): Result<DownloadProgressSnapshot>
    suspend fun pause(id: String): Result<DownloadProgressSnapshot>
    suspend fun resume(id: String): Result<DownloadProgressSnapshot>
    suspend fun cancel(id: String, deleteFiles: Boolean = false): Result<Unit>
}

@Serializable
data class PlaybackStartRequest(
    val source: PlayerSource,
    val backend: InAppPlayer,
    val resumePositionMs: Long = 0,
    val settings: PlaybackSettingsSnapshot = PlaybackSettingsSnapshot(),
)

@Serializable
data class PlaybackSettingsSnapshot(
    val enableSubtitlesByDefault: Boolean = false,
    val enableVLCSubtitleEditMenu: Boolean = true,
    val defaultSubtitleLanguage: String = "eng",
    val preferredAnimeAudioLanguage: String = "jpn",
    val subtitleForegroundColor: String? = null,
    val subtitleStrokeColor: String? = null,
    val subtitleFontSize: Double = 30.0,
    val subtitleStrokeWidth: Double = 1.0,
    val subtitleVerticalOffset: Double = -6.0,
    val defaultPlaybackSpeed: Double = 1.0,
    val holdSpeed: Double = 2.0,
    val externalPlayer: String = "none",
    val alwaysLandscape: Boolean = false,
    val vlcHeaderProxyEnabled: Boolean = true,
    val pictureInPictureEnabled: Boolean = false,
    val brightnessGestureEnabled: Boolean = false,
    val volumeGestureEnabled: Boolean = false,
    val playerTwoFingerTapPlayPauseEnabled: Boolean = true,
    val doubleTapSeekEnabled: Boolean = true,
    val doubleTapSeekSeconds: Double = 10.0,
    val openSubtitlesEnabled: Boolean = false,
    val openSubtitlesAutoFallbackEnabled: Boolean = true,
    val aniSkipAutoSkip: Boolean = false,
    val skip85sEnabled: Boolean = false,
    val skip85sAlwaysVisible: Boolean = false,
    val showNextEpisodeButton: Boolean = true,
    val nextEpisodeThreshold: Int = 90,
)

interface PlaybackBackend {
    val backend: InAppPlayer
    fun canPlay(source: PlayerSource): Boolean
    suspend fun start(request: PlaybackStartRequest): Result<Unit>
}

@Serializable
data class TrackerAuthRequest(
    val service: String,
    val redirectUri: String,
)

@Serializable
data class TrackerSyncRequest(
    val target: DetailTarget,
    val progressPercent: Float,
    val episodePlaybackContext: EpisodePlaybackContext? = null,
    val completed: Boolean = false,
)

interface TrackerClient {
    suspend fun authUrl(request: TrackerAuthRequest): Result<String>
    suspend fun handleCallback(service: String, callbackUrl: String): Result<TrackerStateSnapshot>
    suspend fun syncProgress(request: TrackerSyncRequest): Result<Unit>
}
