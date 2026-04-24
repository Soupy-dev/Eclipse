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

    suspend fun clearCache(): Result<CacheMetricsSnapshot> = runCatching {
        withContext(Dispatchers.IO) {
            val cacheRoot = context.cacheDir.canonicalFile
            cacheRoot.listFiles().orEmpty().forEach { child ->
                child.deleteInside(cacheRoot)
            }
        }
        loadMetrics().getOrThrow()
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

private fun File.deleteInside(root: File) {
    val target = canonicalFile
    check(target.path.startsWith(root.path)) {
        "Refusing to delete outside app cache."
    }
    if (target.isDirectory) {
        target.listFiles().orEmpty().forEach { child -> child.deleteInside(root) }
    }
    target.delete()
}
