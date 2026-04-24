package dev.soupy.eclipse.android.core.storage

import android.content.Context
import dev.soupy.eclipse.android.core.model.SearchHistorySnapshot
import kotlinx.serialization.json.Json

class SearchHistoryStore(
    context: Context,
    json: Json,
) {
    private val store = JsonFileStore(
        context = context,
        relativePath = "search/recent.json",
        serializer = SearchHistorySnapshot.serializer(),
        json = json,
    )

    suspend fun read(): SearchHistorySnapshot = store.read() ?: SearchHistorySnapshot()

    suspend fun write(snapshot: SearchHistorySnapshot) {
        store.write(snapshot)
    }
}
