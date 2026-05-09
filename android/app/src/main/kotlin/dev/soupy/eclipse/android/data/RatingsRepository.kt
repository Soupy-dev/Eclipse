package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.RatingsSnapshot
import dev.soupy.eclipse.android.core.model.normalizedUserRatingOutOf10
import dev.soupy.eclipse.android.core.storage.RatingsStore

class RatingsRepository(
    private val ratingsStore: RatingsStore,
) {
    suspend fun loadSnapshot(): Result<RatingsSnapshot> = runCatching {
        ratingsStore.read()
    }

    suspend fun setRating(tmdbId: Int, rating: Double): Result<RatingsSnapshot> = runCatching {
        val snapshot = ratingsStore.read()
        val updated = snapshot.copy(
            ratings = snapshot.ratings + (tmdbId.toString() to normalizedUserRatingOutOf10(rating)),
        ).normalized
        ratingsStore.write(updated)
        updated
    }

    suspend fun removeRating(tmdbId: Int): Result<RatingsSnapshot> = runCatching {
        val snapshot = ratingsStore.read()
        val updated = snapshot.copy(ratings = snapshot.ratings - tmdbId.toString())
        ratingsStore.write(updated)
        updated
    }

    suspend fun setNote(tmdbId: Int, note: String): Result<RatingsSnapshot> = runCatching {
        val snapshot = ratingsStore.read()
        val key = tmdbId.toString()
        val updated = snapshot.copy(
            notes = if (note.isBlank()) snapshot.notes - key else snapshot.notes + (key to note),
        ).normalized
        ratingsStore.write(updated)
        updated
    }

    suspend fun restoreFromBackup(
        ratings: Map<String, Double>,
        notes: Map<String, String>,
    ): Result<RatingsSnapshot> = runCatching {
        val snapshot = RatingsSnapshot(ratings = ratings, notes = notes).normalized
        ratingsStore.write(snapshot)
        snapshot
    }

    suspend fun exportRatings(): Map<String, Double> = ratingsStore.read().ratings

    suspend fun exportNotes(): Map<String, String> = ratingsStore.read().notes
}
