package dev.soupy.eclipse.android.core.network

import dev.soupy.eclipse.android.core.model.SkipSegment
import dev.soupy.eclipse.android.core.model.SkipType
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString

class IntroDbService(
    private val baseUrl: String = "https://api.theintrodb.org/v2",
    private val httpClient: EclipseHttpClient = EclipseHttpClient(),
) {
    suspend fun fetchSkipTimes(
        tmdbId: Int,
        seasonNumber: Int? = null,
        episodeNumber: Int? = null,
        episodeDurationSeconds: Double = 0.0,
    ): NetworkResult<List<SkipSegment>> {
        val url = buildString {
            append("$baseUrl/media?tmdb_id=$tmdbId")
            seasonNumber?.let { append("&season=$it") }
            episodeNumber?.let { append("&episode=$it") }
        }

        return when (val result = httpClient.get(url)) {
            is NetworkResult.Success -> decode(result.value, episodeDurationSeconds)
            is NetworkResult.Failure.Http -> NetworkResult.Success(emptyList())
            is NetworkResult.Failure.Connectivity -> result
            is NetworkResult.Failure.Serialization -> result
        }
    }

    private fun decode(
        body: String,
        episodeDurationSeconds: Double,
    ): NetworkResult<List<SkipSegment>> = try {
        val response = EclipseJson.decodeFromString<IntroDbResponse>(body)
        val segments = buildList {
            response.intro.orEmpty().mapToSegments(SkipType.INTRO, episodeDurationSeconds).let(::addAll)
            response.recap.orEmpty().mapToSegments(SkipType.RECAP, episodeDurationSeconds).let(::addAll)
            response.credits.orEmpty().mapToSegments(SkipType.OUTRO, episodeDurationSeconds).let(::addAll)
            response.preview.orEmpty().mapToSegments(SkipType.PREVIEW, episodeDurationSeconds).let(::addAll)
        }.sortedBy(SkipSegment::startTime)

        NetworkResult.Success(segments)
    } catch (error: SerializationException) {
        NetworkResult.Failure.Serialization(error)
    }
}

@Serializable
private data class IntroDbResponse(
    @SerialName("tmdb_id") val tmdbId: Int? = null,
    val type: String? = null,
    val intro: List<IntroDbSegment>? = null,
    val recap: List<IntroDbSegment>? = null,
    val credits: List<IntroDbSegment>? = null,
    val preview: List<IntroDbSegment>? = null,
)

@Serializable
private data class IntroDbSegment(
    @SerialName("start_ms") val startMs: Int? = null,
    @SerialName("end_ms") val endMs: Int? = null,
    val confidence: Double? = null,
    @SerialName("submission_count") val submissionCount: Int? = null,
)

private fun List<IntroDbSegment>.mapToSegments(
    type: SkipType,
    episodeDurationSeconds: Double,
): List<SkipSegment> = mapNotNull { segment ->
    val maxDuration = if (episodeDurationSeconds > 0) {
        episodeDurationSeconds
    } else {
        Double.MAX_VALUE
    }
    SkipSegment(
        startTime = segment.startMs?.let { it / 1_000.0 } ?: 0.0,
        endTime = segment.endMs?.let { it / 1_000.0 } ?: maxDuration,
        type = type,
    ).clamped(episodeDurationSeconds)
}
