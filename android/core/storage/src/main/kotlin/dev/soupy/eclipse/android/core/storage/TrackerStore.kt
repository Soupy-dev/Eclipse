package dev.soupy.eclipse.android.core.storage

import android.content.Context
import dev.soupy.eclipse.android.core.model.TrackerStateSnapshot
import kotlinx.serialization.json.Json

class TrackerStore(
    context: Context,
    json: Json,
) {
    private val store = JsonFileStore(
        context = context,
        relativePath = "trackers/tracker-state.json",
        serializer = TrackerStateSnapshot.serializer(),
        json = json,
    )

    suspend fun read(): TrackerStateSnapshot = store.read() ?: TrackerStateSnapshot()

    suspend fun write(snapshot: TrackerStateSnapshot) {
        store.write(snapshot)
    }
}

