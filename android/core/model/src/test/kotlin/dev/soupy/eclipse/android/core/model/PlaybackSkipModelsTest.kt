package dev.soupy.eclipse.android.core.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PlaybackSkipModelsTest {
    @Test
    fun uniqueKeyMatchesIosShape() {
        val segment = SkipSegment(
            startTime = 12.9,
            endTime = 90.0,
            type = SkipType.INTRO,
        )

        assertEquals("intro_12", segment.uniqueKey)
        assertEquals("Skip Intro", segment.type.displayLabel)
    }

    @Test
    fun clampedFiltersInvalidSegments() {
        assertNull(
            SkipSegment(
                startTime = 95.0,
                endTime = 90.0,
                type = SkipType.OUTRO,
            ).clamped(maxDurationSeconds = 120.0),
        )
    }

    @Test
    fun clampedBoundsSegmentToDuration() {
        val segment = SkipSegment(
            startTime = -5.0,
            endTime = 125.0,
            type = SkipType.RECAP,
        ).clamped(maxDurationSeconds = 90.0)

        assertEquals(0.0, segment?.startTime)
        assertEquals(90.0, segment?.endTime)
        assertEquals(90.0, segment?.durationSeconds)
    }
}
