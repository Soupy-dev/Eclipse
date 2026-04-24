package dev.soupy.eclipse.android.core.storage

import android.content.Context
import dev.soupy.eclipse.android.core.model.RecommendationCacheSnapshot
import kotlinx.serialization.json.Json

class RecommendationStore(
    context: Context,
    json: Json,
) {
    private val store = JsonFileStore(
        context = context,
        relativePath = "personalization/recommendations.json",
        serializer = RecommendationCacheSnapshot.serializer(),
        json = json,
    )

    suspend fun read(): RecommendationCacheSnapshot = store.read() ?: RecommendationCacheSnapshot()

    suspend fun write(snapshot: RecommendationCacheSnapshot) {
        store.write(snapshot)
    }
}

