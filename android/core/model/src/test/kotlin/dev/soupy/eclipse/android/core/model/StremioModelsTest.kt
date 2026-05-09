package dev.soupy.eclipse.android.core.model

import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StremioModelsTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun buildsImdbSeriesIdsWhenAddonSupportsImdb() {
        val manifest = StremioManifest(
            id = "addon",
            name = "Addon",
            idPrefixes = listOf("tt"),
        )

        val id = manifest.buildContentId(
            StremioContentIdRequest(
                tmdbId = 100,
                imdbId = "1234567",
                type = "series",
                season = 2,
                episode = 5,
            ),
        )

        assertEquals("tt1234567:2:5", id)
    }

    @Test
    fun fallsBackToTmdbWhenAddonDoesNotSupportImdb() {
        val manifest = StremioManifest(
            id = "addon",
            name = "Addon",
            idPrefixes = listOf("tmdb:"),
        )

        val id = manifest.buildContentId(
            StremioContentIdRequest(
                tmdbId = 100,
                imdbId = "tt1234567",
                type = "movie",
            ),
        )

        assertEquals("tmdb:100", id)
    }

    @Test
    fun returnsNullWhenNoSupportedPrefixCanBeBuilt() {
        val manifest = StremioManifest(
            id = "addon",
            name = "Addon",
            idPrefixes = listOf("kitsu:"),
        )

        assertNull(
            manifest.buildContentId(
                StremioContentIdRequest(
                    tmdbId = 100,
                    imdbId = "tt1234567",
                    type = "movie",
                ),
            ),
        )
    }

    @Test
    fun decodesStringAndDetailedResourcesForSubtitleAddons() {
        val manifest = json.decodeFromString<StremioManifest>(
            """
            {
              "id": "opensubtitles",
              "name": "OpenSubtitles",
              "resources": [
                "stream",
                { "name": "subtitles", "idPrefixes": ["tt"] }
              ]
            }
            """.trimIndent(),
        )

        val id = manifest.buildContentId(
            StremioContentIdRequest(
                tmdbId = 100,
                imdbId = "tt1234567",
                type = "series",
                season = 1,
                episode = 2,
            ),
            resourceName = "subtitles",
        )

        assertTrue(manifest.supportsResource("stream"))
        assertTrue(manifest.supportsResource("subtitles"))
        assertEquals("tt1234567:1:2", id)
    }

    @Test
    fun decodesSubtitleResponsesWithNumericIdsAndNames() {
        val response = json.decodeFromString<StremioSubtitleResponse>(
            """
            {
              "subtitles": [
                {
                  "id": 42,
                  "lang": "eng",
                  "name": "English",
                  "url": "https://subs.example/movie.srt"
                }
              ]
            }
            """.trimIndent(),
        )

        val subtitle = response.subtitles.single()
        assertEquals("42", subtitle.id)
        assertEquals("English", subtitle.displayLabel)
        assertEquals("https://subs.example/movie.srt", subtitle.url)
    }

    @Test
    fun scoresHighQualityDirectStreamsAboveLowQualityStreams() {
        val remux = StremioStream(
            title = "Movie 2160p HDR BluRay Remux",
            url = "https://cdn.example/movie.mkv",
        )
        val cam = StremioStream(
            title = "Movie HDCAM",
            url = "https://cdn.example/cam.mp4",
        )

        assertTrue(remux.isDirectHttp)
        assertTrue(remux.qualityScore() > cam.qualityScore())
        assertTrue(remux.qualityScore() > 0.9)
    }

    @Test
    fun identifiesTorrentLikeStreamsSoCallersCanRejectThem() {
        val infoHashStream = StremioStream(
            title = "Movie 1080p",
            infoHash = "ABC123",
            behaviorHints = StremioStreamBehaviorHints(filename = "Movie File.mkv"),
        )
        val magnetStream = StremioStream(
            title = "Movie 1080p",
            url = "magnet:?xt=urn:btih:ABC123",
        )
        val torrentFileStream = StremioStream(
            title = "Movie 1080p",
            url = "https://cdn.example/movie.torrent?token=abc",
        )
        val directStream = StremioStream(
            title = "Movie 1080p",
            url = "https://cdn.example/movie.mkv",
        )

        assertTrue(infoHashStream.isTorrentLike)
        assertTrue(magnetStream.isTorrentLike)
        assertTrue(torrentFileStream.isTorrentLike)
        assertTrue(!directStream.isTorrentLike)
    }
}
