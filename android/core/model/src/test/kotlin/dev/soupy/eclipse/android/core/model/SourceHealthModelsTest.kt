package dev.soupy.eclipse.android.core.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SourceHealthModelsTest {
    @Test
    fun unhealthyFreshEndpointShowsWarningAndAutoModeSkip() {
        val now = 1_000_000L
        val snapshot = SourceHealthSnapshot(
            records = mapOf(
                "stremio:test" to SourceHealthRecord(
                    sourceId = "stremio:test",
                    sourceName = "Test",
                    endpointStatus = SourceHealthStatus.UNHEALTHY,
                    endpointReason = "Manifest returned HTTP 404.",
                    lastEndpointCheckedAt = now - 1_000L,
                ),
            ),
        )

        val state = snapshot.displayStateFor("stremio:test", now)

        assertEquals(SourceHealthDisplayKind.WARNING, state.kind)
        assertEquals("Manifest returned HTTP 404.", state.warningText)
        assertTrue(snapshot.shouldSkipForAutoMode("stremio:test", now))
    }

    @Test
    fun playbackFailureOverridesStaleHealthyEndpoint() {
        val now = 2_000_000L
        val snapshot = SourceHealthSnapshot(
            records = mapOf(
                "service:test" to SourceHealthRecord(
                    sourceId = "service:test",
                    sourceName = "Test",
                    endpointStatus = SourceHealthStatus.HEALTHY,
                    lastEndpointCheckedAt = now - 40L * 60L * 60L * 1_000L,
                    lastPlaybackFailureAt = now - 10_000L,
                    playbackFailureReason = "Stream returned HTTP 403.",
                ),
            ),
        )

        val state = snapshot.displayStateFor("service:test", now)

        assertEquals(SourceHealthDisplayKind.PLAYBACK_ISSUE, state.kind)
        assertEquals("Stream returned HTTP 403.", state.warningText)
        assertFalse(snapshot.shouldSkipForAutoMode("service:test", now))
    }
}
