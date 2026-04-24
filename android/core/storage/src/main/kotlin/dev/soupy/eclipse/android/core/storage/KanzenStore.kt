package dev.soupy.eclipse.android.core.storage

import android.content.Context
import dev.soupy.eclipse.android.core.model.KanzenModuleSnapshot
import kotlinx.serialization.json.Json

class KanzenStore(
    context: Context,
    json: Json,
) {
    private val store = JsonFileStore(
        context = context,
        relativePath = "kanzen/modules.json",
        serializer = KanzenModuleSnapshot.serializer(),
        json = json,
    )

    suspend fun read(): KanzenModuleSnapshot = store.read() ?: KanzenModuleSnapshot()

    suspend fun write(snapshot: KanzenModuleSnapshot) {
        store.write(snapshot)
    }
}

