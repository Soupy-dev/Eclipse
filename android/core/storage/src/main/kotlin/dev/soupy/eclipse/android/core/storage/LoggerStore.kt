package dev.soupy.eclipse.android.core.storage

import android.content.Context
import dev.soupy.eclipse.android.core.model.AppLogEntry
import dev.soupy.eclipse.android.core.model.AppLogSnapshot
import kotlinx.serialization.json.Json

class LoggerStore(
    context: Context,
    json: Json,
) {
    private val store = JsonFileStore(
        context = context,
        relativePath = "logs/app-log.json",
        serializer = AppLogSnapshot.serializer(),
        json = json,
    )

    suspend fun read(): AppLogSnapshot = store.read() ?: AppLogSnapshot()

    suspend fun append(entry: AppLogEntry) {
        store.write(read().append(entry))
    }

    suspend fun clear() {
        store.write(AppLogSnapshot())
    }
}

