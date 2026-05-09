package dev.soupy.eclipse.android.core.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class ParityModelsTest {
    @Test
    fun catalogMergePreservesSavedRowsAndAddsIosDefaults() {
        val saved = listOf(
            BackupCatalog(
                id = "popularMovies",
                name = "My Movies",
                source = "TMDB",
                isEnabled = false,
                order = 0,
            ),
            BackupCatalog(
                id = "forYou",
                name = "Just For You",
                source = "Local",
                isEnabled = true,
                order = 1,
            ),
        )

        val merged = saved.mergedWithDefaultCatalogs()

        assertEquals(DefaultCatalogs.size, merged.size)
        assertEquals("popularMovies", merged[0].id)
        assertEquals("My Movies", merged[0].displayName)
        assertFalse(merged[0].isEnabled)
        assertTrue(merged.any { it.id == "bestAnime" && it.displayStyle == "ranked" })
        assertEquals(merged.indices.toList(), merged.map { it.order })
    }

    @Test
    fun progressEntriesApplyIosWatchedThreshold() {
        val movie = MovieProgressBackup(
            id = 1,
            currentTime = 85.0,
            totalDuration = 100.0,
        ).withWatchedThreshold()
        val episode = EpisodeProgressBackup(
            id = "ep_2_s1_e1",
            showId = 2,
            seasonNumber = 1,
            episodeNumber = 1,
            currentTime = 84.0,
            totalDuration = 100.0,
        ).withWatchedThreshold()

        assertTrue(movie.isWatched)
        assertFalse(episode.isWatched)
        assertEquals(0.84, episode.progressPercent)
    }

    @Test
    fun ratingsSnapshotClampsBackupValues() {
        val snapshot = RatingsSnapshot(
            ratings = mapOf(
                "1" to 0.0,
                "2" to 3.25,
                "3" to 12.0,
            ),
            notes = mapOf("2" to "  keep  ", "3" to "   "),
        ).normalized

        assertEquals(0.5, snapshot.ratings.getValue("1"))
        assertEquals(3.5, snapshot.ratings.getValue("2"))
        assertEquals(10.0, snapshot.ratings.getValue("3"))
        assertEquals("keep", snapshot.notes.getValue("2"))
        assertEquals(false, snapshot.notes.containsKey("3"))
    }

    @Test
    fun ratingsSnapshotDecodesLegacyIntegerRatings() {
        val snapshot = Json.decodeFromString<RatingsSnapshot>("""{"ratings":{"42":7}}""").normalized

        assertEquals(7.0, snapshot.ratings.getValue("42"))
    }

    @Test
    fun trackerSnapshotPreservesAutoRatingSyncFlag() {
        val json = Json.encodeToString(TrackerStateSnapshot(autoSyncRatings = true))
        val decoded = Json.decodeFromString<TrackerStateSnapshot>(json)
        val legacyDecoded = Json.decodeFromString<TrackerStateSnapshot>("{}")

        assertTrue(decoded.autoSyncRatings)
        assertFalse(legacyDecoded.autoSyncRatings)
    }

    @Test
    fun tmdbRatingsPreferUsCertificationAndContentRating() {
        val releaseDates = TMDBReleaseDatesResponse(
            results = listOf(
                TMDBReleaseDateCountry(
                    countryCode = "CA",
                    releaseDates = listOf(TMDBReleaseDateEntry(certification = "14A")),
                ),
                TMDBReleaseDateCountry(
                    countryCode = "US",
                    releaseDates = listOf(
                        TMDBReleaseDateEntry(certification = ""),
                        TMDBReleaseDateEntry(certification = "PG-13"),
                    ),
                ),
            ),
        )
        val contentRatings = TMDBContentRatingsResponse(
            results = listOf(
                TMDBContentRating(countryCode = "GB", rating = "15"),
                TMDBContentRating(countryCode = "US", rating = "TV-MA"),
            ),
        )

        assertEquals("PG-13", releaseDates.usCertification)
        assertEquals("TV-MA", contentRatings.usRating)
    }

    @Test
    fun searchHistoryMovesRepeatedQueriesToFront() {
        val history = SearchHistorySnapshot(listOf("Dune", "Alien"))
            .remember("alien")
            .remember("Severance")

        assertEquals(listOf("Severance", "alien", "Dune"), history.queries)
    }
}
