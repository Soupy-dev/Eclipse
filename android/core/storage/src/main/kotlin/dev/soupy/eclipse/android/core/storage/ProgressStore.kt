package dev.soupy.eclipse.android.core.storage

import android.content.Context
import dev.soupy.eclipse.android.core.model.ProgressDataBackup
import kotlinx.serialization.json.Json

class ProgressStore(
    context: Context,
    json: Json,
) {
    private val store = JsonFileStore(
        context = context,
        relativePath = "progress/progress.json",
        serializer = ProgressDataBackup.serializer(),
        json = json,
    )

    suspend fun read(): ProgressDataBackup = store.read() ?: ProgressDataBackup()

    suspend fun write(snapshot: ProgressDataBackup) {
        store.write(snapshot)
    }
}

