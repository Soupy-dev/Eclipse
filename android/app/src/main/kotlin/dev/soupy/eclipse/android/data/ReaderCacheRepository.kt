package dev.soupy.eclipse.android.data

import android.content.Context
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class ReaderCacheRepository(
    context: Context,
) {
    private val root = File(context.cacheDir, "reader-cache")

    suspend fun stats(): Result<ReaderCacheStats> = runCatching {
        withContext(Dispatchers.IO) {
            statsSnapshot()
        }
    }

    suspend fun clear(): Result<ReaderCacheStats> = runCatching {
        withContext(Dispatchers.IO) {
            val current = statsSnapshot()
            if (root.exists()) {
                root.deleteRecursively()
            }
            current
        }
    }

    suspend fun load(
        moduleId: String?,
        chapterParams: String?,
        isNovel: Boolean,
    ): Result<KanzenReaderContentSnapshot?> = runCatching {
        withContext(Dispatchers.IO) {
            val directory = cacheDirectory(moduleId, chapterParams, isNovel) ?: return@withContext null
            if (!directory.isDirectory) return@withContext null
            val textFile = File(directory, "chapter.txt")
            if (isNovel && textFile.isFile) {
                return@withContext KanzenReaderContentSnapshot(
                    chapterParams = chapterParams.orEmpty(),
                    text = textFile.readText(),
                    isCached = true,
                    cacheMessage = "Loaded chapter text from reader cache.",
                )
            }
            val pages = directory.listFiles()
                .orEmpty()
                .filter { file -> file.isFile && file.name.startsWith("page-") }
                .sortedBy(File::getName)
                .map { file -> file.toURI().toString() }
            pages.takeIf(List<String>::isNotEmpty)?.let { imageUris ->
                KanzenReaderContentSnapshot(
                    chapterParams = chapterParams.orEmpty(),
                    imageUrls = imageUris,
                    isCached = true,
                    cacheMessage = "Loaded ${imageUris.size} cached page${if (imageUris.size == 1) "" else "s"}.",
                )
            }
        }
    }

    suspend fun save(
        moduleId: String?,
        chapterParams: String?,
        isNovel: Boolean,
        content: KanzenReaderContentSnapshot,
    ): Result<KanzenReaderContentSnapshot> = runCatching {
        withContext(Dispatchers.IO) {
            val directory = cacheDirectory(moduleId, chapterParams, isNovel)
                ?: return@withContext content
            directory.mkdirs()
            if (isNovel) {
                content.text?.takeIf(String::isNotBlank)?.let { text ->
                    File(directory, "chapter.txt").writeText(text)
                    return@withContext content.copy(
                        isCached = true,
                        cacheMessage = "Cached chapter text for offline reading.",
                    )
                }
                return@withContext content
            }

            val cachedPages = content.imageUrls.mapIndexedNotNull { index, imageUrl ->
                cacheImage(
                    imageUrl = imageUrl,
                    target = File(directory, "page-${index.toString().padStart(4, '0')}${imageUrl.extensionOrDefault()}"),
                )
            }
            if (cachedPages.isEmpty()) {
                content
            } else {
                val cachedNames = cachedPages.map(File::getName).toSet()
                directory.listFiles()
                    .orEmpty()
                    .filter { file -> file.isFile && file.name.startsWith("page-") && file.name !in cachedNames }
                    .forEach(File::delete)
                content.copy(
                    imageUrls = cachedPages.map { file -> file.toURI().toString() },
                    isCached = true,
                    cacheMessage = "Cached ${cachedPages.size} page${if (cachedPages.size == 1) "" else "s"} for offline reading.",
                )
            }
        }
    }

    private fun cacheDirectory(
        moduleId: String?,
        chapterParams: String?,
        isNovel: Boolean,
    ): File? {
        if (moduleId.isNullOrBlank() || moduleId == "anilist" || chapterParams.isNullOrBlank()) {
            return null
        }
        return File(root, "${if (isNovel) "novel" else "manga"}-${"$moduleId|$chapterParams".sha256()}")
    }

    private fun statsSnapshot(): ReaderCacheStats {
        if (!root.isDirectory) return ReaderCacheStats()
        val entries = root.listFiles()
            .orEmpty()
            .count(File::isDirectory)
        val files = root.walkTopDown()
            .filter(File::isFile)
            .toList()
        return ReaderCacheStats(
            entryCount = entries,
            fileCount = files.size,
            byteCount = files.sumOf(File::length),
        )
    }

    private fun cacheImage(
        imageUrl: String,
        target: File,
    ): File? {
        val uri = runCatching { URI(imageUrl) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        if (scheme == "file") return File(uri).takeIf(File::isFile)
        if (scheme != "http" && scheme != "https") return null
        if (target.isFile && target.length() > 0L) return target

        val temp = File(target.parentFile, "${target.name}.tmp")
        return runCatching {
            target.parentFile?.mkdirs()
            val connection = uri.toURL().openConnection() as HttpURLConnection
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("User-Agent", "Eclipse Android Reader Cache")
            connection.inputStream.use { input ->
                temp.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            if (temp.length() <= 0L) {
                temp.delete()
                return null
            }
            if (target.exists()) target.delete()
            temp.renameTo(target)
            target
        }.getOrElse {
            temp.delete()
            null
        }
    }
}

data class ReaderCacheStats(
    val entryCount: Int = 0,
    val fileCount: Int = 0,
    val byteCount: Long = 0L,
) {
    val displayText: String
        get() = if (fileCount == 0) {
            "Reader cache empty."
        } else {
            "$entryCount cached ${if (entryCount == 1) "chapter" else "chapters"}, " +
                "$fileCount ${if (fileCount == 1) "file" else "files"}, ${byteCount.toHumanSize()}."
        }
}

private fun String.sha256(): String =
    MessageDigest.getInstance("SHA-256")
        .digest(toByteArray())
        .joinToString("") { byte -> "%02x".format(byte) }

private fun String.extensionOrDefault(): String {
    val path = runCatching { URI(this).path.orEmpty() }.getOrDefault("")
    val extension = path.substringAfterLast('.', missingDelimiterValue = "")
        .lowercase()
        .takeIf { value -> value.length in 2..5 && value.all { it.isLetterOrDigit() } }
        ?: "img"
    return ".$extension"
}

private fun Long.toHumanSize(): String =
    when {
        this >= 1024L * 1024L -> "${this / (1024L * 1024L)} MB"
        this >= 1024L -> "${this / 1024L} KB"
        else -> "$this B"
    }
