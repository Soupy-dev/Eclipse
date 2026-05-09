package dev.soupy.eclipse.android.core.storage

import android.content.Context
import dev.soupy.eclipse.android.core.model.SourceHealthSnapshot
import kotlinx.serialization.json.Json

class SourceHealthStore(
    context: Context,
    json: Json,
) {
    private val store = JsonFileStore(
        context = context,
        relativePath = "services/source-health.json",
        serializer = SourceHealthSnapshot.serializer(),
        json = json,
    )

    suspend fun read(): SourceHealthSnapshot = store.read() ?: SourceHealthSnapshot()

    suspend fun write(snapshot: SourceHealthSnapshot) {
        store.write(snapshot)
    }
}
