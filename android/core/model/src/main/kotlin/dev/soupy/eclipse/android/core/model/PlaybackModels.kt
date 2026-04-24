package dev.soupy.eclipse.android.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class EpisodePlaybackContext(
    val localSeasonNumber: Int,
    val localEpisodeNumber: Int,
    val anilistMediaId: Int? = null,
    val tmdbSeasonNumber: Int? = null,
    val tmdbEpisodeNumber: Int? = null,
    val tmdbEpisodeOffset: Int? = null,
    val isSpecial: Boolean = false,
    val titleOnlySearch: Boolean = false,
) {
    val resolvedTMDBSeasonNumber: Int
        get() = tmdbSeasonNumber ?: localSeasonNumber

    val resolvedTMDBEpisodeNumber: Int
        get() = (tmdbEpisodeNumber ?: localEpisodeNumber) + (tmdbEpisodeOffset ?: 0)

    fun forEpisodeNumber(episodeNumber: Int): EpisodePlaybackContext = copy(
        localEpisodeNumber = episodeNumber,
        tmdbEpisodeNumber = tmdbEpisodeNumber?.let {
            it + (episodeNumber - localEpisodeNumber)
        },
    )
}

@Serializable
sealed interface MediaInfo {
    val isAnime: Boolean
    val posterUrl: String?
    val title: String
}

@Serializable
@SerialName("movie")
data class MovieInfo(
    val id: Int,
    override val title: String,
    override val posterUrl: String? = null,
    override val isAnime: Boolean = false,
) : MediaInfo

@Serializable
@SerialName("episode")
data class EpisodeInfo(
    val showId: Int,
    val seasonNumber: Int,
    val episodeNumber: Int,
    @SerialName("showTitle") override val title: String,
    @SerialName("showPosterURL") override val posterUrl: String? = null,
    override val isAnime: Boolean = false,
) : MediaInfo

@Serializable
enum class InAppPlayer {
    NORMAL,
    VLC,
    MPV,
    EXTERNAL,
}

@Serializable
data class SubtitleTrack(
    val id: String,
    val label: String,
    val language: String? = null,
    val uri: String? = null,
    val format: String? = null,
    val isDefault: Boolean = false,
)

@Serializable
data class AudioTrack(
    val id: String,
    val label: String,
    val language: String? = null,
    val isDefault: Boolean = false,
)

@Serializable
data class PlayerSource(
    val uri: String,
    val title: String? = null,
    val mimeType: String? = null,
    val headers: Map<String, String> = emptyMap(),
    val subtitles: List<SubtitleTrack> = emptyList(),
    val audioTracks: List<AudioTrack> = emptyList(),
    val isDownloaded: Boolean = false,
    val serviceId: String? = null,
    val serviceHref: String? = null,
    val context: EpisodePlaybackContext? = null,
)

@Serializable
enum class SkipType(
    val id: String,
    val displayLabel: String,
) {
    @SerialName("intro")
    INTRO("intro", "Skip Intro"),

    @SerialName("outro")
    OUTRO("outro", "Skip Outro"),

    @SerialName("recap")
    RECAP("recap", "Skip Recap"),

    @SerialName("preview")
    PREVIEW("preview", "Skip Preview"),
}

@Serializable
data class SkipSegment(
    val startTime: Double,
    val endTime: Double,
    val type: SkipType,
) {
    val uniqueKey: String
        get() = "${type.id}_${startTime.toInt()}"

    val durationSeconds: Double
        get() = (endTime - startTime).coerceAtLeast(0.0)

    fun clamped(maxDurationSeconds: Double): SkipSegment? {
        val maxDuration = if (maxDurationSeconds > 0) {
            maxDurationSeconds
        } else {
            Double.MAX_VALUE
        }
        val clampedStart = startTime.coerceAtLeast(0.0)
        val clampedEnd = endTime.coerceAtMost(maxDuration)
        return if (clampedEnd > clampedStart) {
            copy(startTime = clampedStart, endTime = clampedEnd)
        } else {
            null
        }
    }
}


