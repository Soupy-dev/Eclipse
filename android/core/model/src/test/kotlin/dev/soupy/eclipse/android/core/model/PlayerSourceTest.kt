package dev.soupy.eclipse.android.core.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class PlayerSourceTest {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    @Test
    fun serviceMetadataRoundTripsThroughPlayerSource() {
        val source = PlayerSource(
            uri = "https://example.test/video.m3u8",
            serviceId = "stremio:https://addon.example.test/manifest.json",
            serviceHref = "tt1234567:1:2",
        )

        val decoded = json.decodeFromString<PlayerSource>(json.encodeToString(source))

        assertEquals(source.serviceId, decoded.serviceId)
        assertEquals(source.serviceHref, decoded.serviceHref)
    }

    @Test
    fun serviceMetadataDefaultsToNullForOlderSources() {
        val decoded = json.decodeFromString<PlayerSource>(
            """{"uri":"https://example.test/video.mp4"}""",
        )

        assertNull(decoded.serviceId)
        assertNull(decoded.serviceHref)
    }
}
