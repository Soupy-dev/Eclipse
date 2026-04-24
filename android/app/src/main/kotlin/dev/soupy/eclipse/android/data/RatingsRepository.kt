package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.RatingsSnapshot
import dev.soupy.eclipse.android.core.storage.RatingsStore

class RatingsRepository(
    private val ratingsStore: RatingsStore,
) {
    suspend fun loadSnapshot(): Result<RatingsSnapshot> = runCatching {
        ratingsStore.read()
    }

    suspend fun setRating(tmdbId: Int, rating: Int): Result<RatingsSnapshot> = runCatching {
        val snapshot = ratingsStore.read()
        val updated = snapshot.copy(ratings = snapshot.ratings + (tmdbId.toString() to rating.coerceIn(1, 5))).normalized
        ratingsStore.write(updated)
        updated
    }

    suspend fun removeRating(tmdbId: Int): Result<RatingsSnapshot> = runCatching {
        val snapshot = ratingsStore.read()
        val updated = snapshot.copy(ratings = snapshot.ratings - tmdbId.toString())
        ratingsStore.write(updated)
        updated
    }

    suspend fun restoreFromBackup(ratings: Map<String, Int>): Result<RatingsSnapshot> = runCatching {
        val snapshot = RatingsSnapshot(ratings).normalized
        ratingsStore.write(snapshot)
        snapshot
    }

    suspend fun exportRatings(): Map<String, Int> = ratingsStore.read().ratings
}

