package dev.soupy.eclipse.android.core.model
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

private val qualityPatterns = listOf(
    "2160p" to 1.00,
    "4k" to 1.00,
    "1080p" to 0.90,
    "720p" to 0.72,
    "480p" to 0.48,
    "cam" to -0.35,
    "hdcam" to -0.35,
    "telesync" to -0.30,
    " ts " to -0.30,
)

@Serializable
data class StremioManifestBehaviorHints(
    val configurable: Boolean = false,
    @SerialName("configurationRequired") val configurationRequired: Boolean = false,
)

@Serializable
data class StremioResourceDescriptor(
    val name: String = "",
    val types: List<String> = emptyList(),
    @SerialName("idPrefixes") val idPrefixes: List<String> = emptyList(),
)

@Serializable
data class StremioManifest(
    val id: String = "",
    val version: String = "",
    val name: String = "",
    val description: String? = null,
    @SerialName("logo") val logoUrl: String? = null,
    val background: String? = null,
    val resources: List<StremioResourceDescriptor> = emptyList(),
    @SerialName("idPrefixes") val idPrefixes: List<String> = emptyList(),
    val types: List<String> = emptyList(),
    val catalogs: List<JsonObject> = emptyList(),
    @SerialName("behaviorHints") val behaviorHints: StremioManifestBehaviorHints = StremioManifestBehaviorHints(),
)

@Serializable
data class StremioProxyHeaders(
    val request: Map<String, String> = emptyMap(),
    val response: Map<String, String> = emptyMap(),
)

@Serializable
data class StremioSubtitle(
    val id: String? = null,
    val lang: String? = null,
    val label: String? = null,
    val url: String? = null,
)

@Serializable
data class StremioStreamBehaviorHints(
    @SerialName("bingeGroup") val bingeGroup: String? = null,
    @SerialName("filename") val filename: String? = null,
    @SerialName("notWebReady") val notWebReady: Boolean = false,
    @SerialName("proxyHeaders") val proxyHeaders: StremioProxyHeaders? = null,
)

@Serializable
data class StremioStream(
    val name: String? = null,
    val title: String? = null,
    val description: String? = null,
    val url: String? = null,
    @SerialName("ytId") val ytId: String? = null,
    val infoHash: String? = null,
    val fileIdx: Int? = null,
    val subtitles: List<StremioSubtitle> = emptyList(),
    @SerialName("behaviorHints") val behaviorHints: StremioStreamBehaviorHints? = null,
)

@Serializable
data class StremioStreamResponse(
    val streams: List<StremioStream> = emptyList(),
)

@Serializable
data class StremioAddon(
    val transportUrl: String,
    val manifest: StremioManifest,
    val enabled: Boolean = true,
    val sortIndex: Int = 0,
)

@Serializable
data class StremioContentIdRequest(
    val tmdbId: Int,
    val imdbId: String? = null,
    val type: String,
    val season: Int? = null,
    val episode: Int? = null,
)

val StremioStream.isDirectHttp: Boolean
    get() = url?.startsWith("http://") == true || url?.startsWith("https://") == true

val StremioStream.isTorrentLike: Boolean
    get() = !infoHash.isNullOrBlank() ||
        url?.startsWith("magnet:", ignoreCase = true) == true ||
        url?.contains("btih:", ignoreCase = true) == true ||
        url?.endsWith(".torrent", ignoreCase = true) == true

fun StremioManifest.buildContentId(request: StremioContentIdRequest): String? {
    val prefixes = idPrefixes.ifEmpty {
        resources
            .filter { resource -> resource.name.equals("stream", ignoreCase = true) }
            .flatMap(StremioResourceDescriptor::idPrefixes)
    }
    val supportsAny = prefixes.isEmpty()
    val supportsImdb = supportsAny || prefixes.any { prefix ->
        prefix == "tt" || prefix == "imdb" || prefix == "imdb:"
    }
    val supportsTmdb = supportsAny || prefixes.any { prefix ->
        prefix == "tmdb" || prefix == "tmdb:"
    }

    if (supportsImdb) {
        val imdb = request.imdbId?.takeIf { it.isNotBlank() }?.let { value ->
            if (value.startsWith("tt")) value else "tt$value"
        }
        if (imdb != null) {
            return if (request.type == "series" && request.season != null && request.episode != null) {
                "$imdb:${request.season}:${request.episode}"
            } else {
                imdb
            }
        }
    }

    if (supportsTmdb) {
        return if (request.type == "series" && request.season != null && request.episode != null) {
            "tmdb:${request.tmdbId}:${request.season}:${request.episode}"
        } else {
            "tmdb:${request.tmdbId}"
        }
    }

    return null
}

fun StremioStream.qualityScore(): Double {
    val haystack = listOfNotNull(
        name,
        title,
        description,
        behaviorHints?.filename,
    ).joinToString(" ").lowercase()

    val base = qualityPatterns.firstOrNull { (needle, _) -> haystack.contains(needle) }?.second ?: 0.50
    val hdrBoost = if (haystack.contains("hdr") || haystack.contains("dolby vision") || haystack.contains("dv")) 0.04 else 0.0
    val remuxBoost = if (haystack.contains("remux") || haystack.contains("bluray")) 0.04 else 0.0
    val webBoost = if (haystack.contains("web-dl") || haystack.contains("webrip")) 0.02 else 0.0
    val notWebReadyPenalty = if (behaviorHints?.notWebReady == true) 0.08 else 0.0

    return (base + hdrBoost + remuxBoost + webBoost - notWebReadyPenalty).coerceIn(0.0, 1.0)
}


