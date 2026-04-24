package dev.soupy.eclipse.android.core.storage

import android.content.Context
import dev.soupy.eclipse.android.core.model.RatingsSnapshot
import kotlinx.serialization.json.Json

class RatingsStore(
    context: Context,
    json: Json,
) {
    private val store = JsonFileStore(
        context = context,
        relativePath = "personalization/ratings.json",
        serializer = RatingsSnapshot.serializer(),
        json = json,
    )

    suspend fun read(): RatingsSnapshot = store.read()?.normalized ?: RatingsSnapshot()

    suspend fun write(snapshot: RatingsSnapshot) {
        store.write(snapshot.normalized)
    }
}

