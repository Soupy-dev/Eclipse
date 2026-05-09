package dev.soupy.eclipse.android.core.network

import dev.soupy.eclipse.android.core.model.StremioContentIdRequest
import dev.soupy.eclipse.android.core.model.StremioManifest
import dev.soupy.eclipse.android.core.model.StremioSubtitle
import dev.soupy.eclipse.android.core.model.StremioSubtitleResponse
import dev.soupy.eclipse.android.core.model.StremioStreamResponse
import dev.soupy.eclipse.android.core.model.buildContentId
import dev.soupy.eclipse.android.core.model.supportsResource
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString

private const val OpenSubtitlesV3BaseUrl = "https://opensubtitles-v3.strem.io"

class StremioService(
    private val httpClient: EclipseHttpClient = EclipseHttpClient(),
) {
    suspend fun fetchManifest(transportUrl: String): NetworkResult<StremioManifest> = decode {
        httpClient.get(transportUrl.ensureManifestUrl())
    }

    suspend fun fetchStreams(
        transportUrl: String,
        type: String,
        id: String,
    ): NetworkResult<StremioStreamResponse> = decode {
        val base = transportUrl.normalizedStremioBaseUrl()
        httpClient.get("$base/stream/$type/${id.encodedPathSegment()}.json")
    }

    suspend fun fetchSubtitles(
        transportUrl: String,
        type: String,
        id: String,
    ): NetworkResult<StremioSubtitleResponse> = decode {
        val base = transportUrl.normalizedStremioBaseUrl()
        httpClient.get("$base/subtitles/$type/${id.encodedPathSegment()}.json")
    }

    suspend fun fetchOpenSubtitlesV3(
        tmdbId: Int,
        imdbId: String?,
        type: String,
        season: Int?,
        episode: Int?,
    ): NetworkResult<List<StremioSubtitle>> {
        val manifest = when (val result = fetchManifest(OpenSubtitlesV3BaseUrl)) {
            is NetworkResult.Success -> result.value
            is NetworkResult.Failure -> return result
        }
        if (!manifest.supportsResource("subtitles")) {
            return NetworkResult.Success(emptyList())
        }

        val contentId = manifest.buildContentId(
            StremioContentIdRequest(
                tmdbId = tmdbId,
                imdbId = imdbId,
                type = type,
                season = season,
                episode = episode,
            ),
            resourceName = "subtitles",
        ) ?: return NetworkResult.Success(emptyList())

        return when (val result = fetchSubtitles(OpenSubtitlesV3BaseUrl, type, contentId)) {
            is NetworkResult.Success -> NetworkResult.Success(
                result.value.subtitles.filter { subtitle -> subtitle.url.isDirectHttpUrl() },
            )

            is NetworkResult.Failure -> result
        }
    }

    private suspend inline fun <reified T> decode(request: () -> NetworkResult<String>): NetworkResult<T> =
        when (val result = request()) {
            is NetworkResult.Success -> try {
                NetworkResult.Success(EclipseJson.decodeFromString<T>(result.value))
            } catch (error: SerializationException) {
                NetworkResult.Failure.Serialization(error)
            }

            is NetworkResult.Failure -> result
        }
}

private fun String.ensureManifestUrl(): String =
    if (endsWith("/manifest.json")) this else removeSuffix("/") + "/manifest.json"

private fun String.normalizedStremioBaseUrl(): String =
    trim().removeSuffix("/").removeSuffix("/manifest.json")

private fun String.encodedPathSegment(): String =
    URLEncoder.encode(this, StandardCharsets.UTF_8.name())
        .replace("+", "%20")
        .replace("%3A", ":")

private fun String?.isDirectHttpUrl(): Boolean =
    this?.startsWith("http://", ignoreCase = true) == true ||
        this?.startsWith("https://", ignoreCase = true) == true
