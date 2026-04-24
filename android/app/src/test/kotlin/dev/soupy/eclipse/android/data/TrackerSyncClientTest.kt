package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.EpisodePlaybackContext
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class TrackerSyncClientTest {
    @Test
    fun traktHistoryPayloadUsesTmdbShowSeasonAndEpisode() {
        val payload = TrackerSyncItem(
            target = DetailTarget.TmdbShow(42),
            title = "Example Show",
            seasonNumber = 2,
            episodeNumber = 5,
            progressPercent = 0.9,
        ).toTraktHistoryPayload("2026-04-24T12:00:00Z")!!

        val show = payload["shows"]!!.jsonArray.first().jsonObject
        val season = show["seasons"]!!.jsonArray.first().jsonObject
        val episode = season["episodes"]!!.jsonArray.first().jsonObject

        assertEquals("42", show["ids"]!!.jsonObject["tmdb"]!!.jsonPrimitive.content)
        assertEquals("2", season["number"]!!.jsonPrimitive.content)
        assertEquals("5", episode["number"]!!.jsonPrimitive.content)
        assertEquals("2026-04-24T12:00:00Z", episode["watched_at"]!!.jsonPrimitive.content)
    }

    @Test
    fun playbackDraftKeepsAniListLocalEpisodeAndTraktTmdbEpisodeSeparate() {
        val item = TrackerPlaybackProgressDraft(
            target = DetailTarget.TmdbShow(100),
            title = "Mapped Anime",
            seasonNumber = 1,
            episodeNumber = 3,
            anilistMediaId = 9001,
            progressPercent = 0.86,
            playbackContext = EpisodePlaybackContext(
                localSeasonNumber = 1,
                localEpisodeNumber = 3,
                anilistMediaId = 9001,
                tmdbSeasonNumber = 2,
                tmdbEpisodeNumber = 12,
            ),
        ).toTrackerSyncItem()

        assertEquals(2, item.seasonNumber)
        assertEquals(12, item.episodeNumber)
        assertEquals(9001, item.anilistMediaId)
        assertEquals(3, item.anilistEpisodeNumber)
    }

    @Test
    fun aniListMutationTargetsCurrentProgress() {
        val mutation = aniListSaveMediaListMutation(mediaId = 123, progress = 7)

        assertTrue("mediaId: 123" in mutation)
        assertTrue("progress: 7" in mutation)
        assertTrue("status: CURRENT" in mutation)
    }
}
