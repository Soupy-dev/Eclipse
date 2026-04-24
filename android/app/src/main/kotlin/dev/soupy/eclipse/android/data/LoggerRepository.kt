package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.AppLogEntry
import dev.soupy.eclipse.android.core.model.AppLogSnapshot
import dev.soupy.eclipse.android.core.storage.LoggerStore

class LoggerRepository(
    private val loggerStore: LoggerStore,
) {
    suspend fun loadSnapshot(): Result<AppLogSnapshot> = runCatching {
        loggerStore.read()
    }

    suspend fun log(tag: String, message: String, level: String = "info"): Result<Unit> = runCatching {
        loggerStore.append(
            AppLogEntry(
                id = "${System.currentTimeMillis()}-${tag.hashCode()}",
                timestamp = System.currentTimeMillis(),
                tag = tag,
                message = message,
                level = level,
            ),
        )
    }

    suspend fun clear(): Result<Unit> = runCatching {
        loggerStore.clear()
    }
}

