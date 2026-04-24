package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.ExploreMediaCard
import dev.soupy.eclipse.android.core.model.RecommendationCacheSnapshot
import dev.soupy.eclipse.android.core.model.TMDBSearchResult
import dev.soupy.eclipse.android.core.model.hasBackupData
import dev.soupy.eclipse.android.core.model.progressPercent
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.storage.ProgressStore
import dev.soupy.eclipse.android.core.storage.RatingsStore
import dev.soupy.eclipse.android.core.storage.RecommendationStore
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement

class RecommendationRepository(
    private val recommendationStore: RecommendationStore,
    private val progressStore: ProgressStore,
    private val ratingsStore: RatingsStore,
) {
    suspend fun restoreFromBackup(cache: JsonElement): Result<RecommendationCacheSnapshot> = runCatching {
        val snapshot = RecommendationCacheSnapshot(cache)
        recommendationStore.write(snapshot)
        snapshot
    }

    suspend fun exportCache(fallback: JsonElement): JsonElement {
        val snapshot = recommendationStore.read()
        return if (snapshot.items.hasBackupData()) snapshot.items else fallback
    }

    suspend fun justForYou(candidates: List<ExploreMediaCard>, limit: Int = 12): List<ExploreMediaCard> {
        val cached = cachedCards()
        val watchedIds = watchedTmdbIds()
        val ratings = ratingsStore.read().ratings
        val scored = (cached + candidates)
            .distinctBy { it.id }
            .filterNot { card -> card.tmdbKey()?.let { it in watchedIds } == true }
            .sortedWith(
                compareByDescending<ExploreMediaCard> { card -> card.tmdbKey()?.let { ratings[it] }.orZero() }
                    .thenBy { it.title },
            )
        return scored.take(limit)
    }

    suspend fun becauseYouWatched(candidates: List<ExploreMediaCard>, limit: Int = 12): List<ExploreMediaCard> {
        val progress = progressStore.read()
        val watchedIds = watchedTmdbIds()
        val hasTasteSignal = progress.movieProgress.any { it.progressPercent >= 0.2 } ||
            progress.episodeProgress.any { it.progressPercent >= 0.2 } ||
            ratingsStore.read().ratings.isNotEmpty()

        if (!hasTasteSignal) return emptyList()

        return candidates
            .distinctBy { it.id }
            .filterNot { card -> card.tmdbKey()?.let { it in watchedIds } == true }
            .take(limit)
    }

    private suspend fun cachedCards(): List<ExploreMediaCard> {
        val cache = recommendationStore.read().items
        val array = cache as? JsonArray ?: return emptyList()
        return array.mapNotNull { element ->
            runCatching {
                EclipseJson.decodeFromJsonElement<TMDBSearchResult>(element).toExploreMediaCard("Recommended")
            }.getOrNull()
        }
    }

    private suspend fun watchedTmdbIds(): Set<String> {
        val progress = progressStore.read()
        return buildSet {
            progress.movieProgress.filter { it.isWatched || it.progressPercent >= 0.85 }.forEach { add("movie:${it.id}") }
            progress.episodeProgress.filter { it.isWatched || it.progressPercent >= 0.85 }.forEach { add("tv:${it.showId}") }
        }
    }
}

private fun ExploreMediaCard.tmdbKey(): String? = when (val target = detailTarget) {
    is DetailTarget.TmdbMovie -> "movie:${target.id}"
    is DetailTarget.TmdbShow -> "tv:${target.id}"
    is DetailTarget.AniListMediaTarget -> null
}

private fun Int?.orZero(): Int = this ?: 0
