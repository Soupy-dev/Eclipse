package dev.soupy.eclipse.android.data

import android.content.Context
import dev.soupy.eclipse.android.core.model.CacheMetricsSnapshot
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class CacheRepository(
    private val context: Context,
) {
    suspend fun loadMetrics(): Result<CacheMetricsSnapshot> = runCatching {
        withContext(Dispatchers.IO) {
            CacheMetricsSnapshot(
                cacheBytes = context.cacheDir.safeSize(),
                filesBytes = context.filesDir.safeSize(),
                downloadBytes = File(context.filesDir, "downloads").safeSize(),
                generatedAt = System.currentTimeMillis(),
            )
        }
    }
}

private fun File.safeSize(): Long =
    runCatching {
        if (!exists()) {
            0L
        } else {
            walkTopDown().filter { it.isFile }.sumOf { it.length() }
        }
    }.getOrDefault(0L)

