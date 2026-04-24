package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.DownloadRecord
import dev.soupy.eclipse.android.core.model.DownloadSnapshot
import dev.soupy.eclipse.android.core.model.DownloadStatus
import dev.soupy.eclipse.android.core.model.PlayerSource
import dev.soupy.eclipse.android.core.model.SubtitleTrack
import dev.soupy.eclipse.android.core.storage.DownloadsStore
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val BufferSize = 64 * 1024

data class DownloadDraft(
    val detailTarget: DetailTarget,
    val title: String,
    val subtitle: String? = null,
    val imageUrl: String? = null,
    val backdropUrl: String? = null,
    val mediaLabel: String? = null,
    val progressLabel: String? = null,
    val sourceLabel: String? = null,
    val downloadKeySuffix: String? = null,
    val playerSource: PlayerSource? = null,
)

data class DownloadCleanupResult(
    val snapshot: DownloadSnapshot,
    val deletedFiles: Int,
    val deletedBytes: Long,
)

class DownloadsRepository(
    private val downloadsStore: DownloadsStore,
) {
    private val downloadEngine = DirectFileDownloadEngine(downloadsStore)

    suspend fun loadSnapshot(): Result<DownloadSnapshot> = runCatching {
        downloadsStore.read().normalized()
    }

    suspend fun queueDownload(draft: DownloadDraft): Result<DownloadSnapshot> = runCatching {
        val snapshot = downloadsStore.read()
        val key = draft.detailTarget.downloadKey(draft.downloadKeySuffix)
        val existing = snapshot.items.firstOrNull { it.id == key }
        val queued = draft.toRecord(
            id = key,
            existing = existing,
        )
        val withQueued = writeSnapshot(
            snapshot.copy(
                items = listOf(queued) + snapshot.items.filterNot { it.id == key },
            ),
        )

        val sourceUri = queued.sourceUri
        when {
            sourceUri == null -> withQueued
            sourceUri.isTorrentLikeUri() -> writeRecord(
                queued.copy(
                    status = DownloadStatus.FAILED,
                    progressLabel = "Torrent and magnet sources are blocked on Android.",
                    error = "Rejected torrent-like source URI: $sourceUri",
                ),
            )
            !sourceUri.isDirectHttpUrl() -> writeRecord(
                queued.copy(
                    status = DownloadStatus.FAILED,
                    progressLabel = "Only direct HTTP(S) streams can be downloaded by Android right now.",
                    error = "Unsupported source URI: $sourceUri",
                ),
            )
            sourceUri.isHlsPlaylist() -> {
                writeRecord(
                    queued.copy(
                        status = DownloadStatus.DOWNLOADING,
                        progressLabel = "Packaging HLS playlist segments for offline playback.",
                    ),
                )
                writeRecord(downloadEngine.downloadHls(queued))
            }
            else -> {
                writeRecord(
                    queued.copy(
                        status = DownloadStatus.DOWNLOADING,
                        progressLabel = "Downloading direct stream into Android app storage.",
                    ),
                )
                writeRecord(downloadEngine.download(queued))
            }
        }
    }

    suspend fun pause(id: String): Result<DownloadSnapshot> = update(id) { current ->
        current.copy(
            status = DownloadStatus.PAUSED,
            progressLabel = current.progressLabel ?: "Paused before a background-capable worker picked it up.",
        )
    }

    suspend fun resume(id: String): Result<DownloadSnapshot> = update(id) { current ->
        current.copy(
            status = DownloadStatus.QUEUED,
            progressLabel = current.localUri?.let { "Queued to verify the existing offline file." }
                ?: "Queued to retry the direct download.",
            error = null,
        )
    }

    suspend fun markComplete(id: String): Result<DownloadSnapshot> = update(id) { current ->
        current.copy(
            status = DownloadStatus.COMPLETED,
            progressPercent = 1f,
            progressLabel = current.localUri?.let { "Offline file is available in Android app storage." }
                ?: "Marked complete manually.",
            error = null,
        )
    }

    suspend fun remove(id: String): Result<DownloadSnapshot> = runCatching {
        val snapshot = downloadsStore.read()
        snapshot.items.firstOrNull { it.id == id }?.let { record ->
            deleteDownloadedFiles(record)
        }
        writeSnapshot(snapshot.copy(items = snapshot.items.filterNot { it.id == id }))
    }

    suspend fun clearCompleted(): Result<DownloadSnapshot> = runCatching {
        val snapshot = downloadsStore.read()
        snapshot.items
            .filter { it.status == DownloadStatus.COMPLETED }
            .forEach(::deleteDownloadedFiles)
        writeSnapshot(snapshot.copy(items = snapshot.items.filterNot { it.status == DownloadStatus.COMPLETED }))
    }

    suspend fun clearTarget(target: DetailTarget): Result<DownloadSnapshot> = runCatching {
        val snapshot = downloadsStore.read()
        val removed = snapshot.items.filter { it.detailTarget == target }
        removed.forEach(::deleteDownloadedFiles)
        writeSnapshot(snapshot.copy(items = snapshot.items - removed.toSet()))
    }

    suspend fun clearAll(): Result<DownloadSnapshot> = runCatching {
        val snapshot = downloadsStore.read()
        snapshot.items.forEach(::deleteDownloadedFiles)
        writeSnapshot(snapshot.copy(items = emptyList()))
    }

    suspend fun cleanupOrphanFiles(): Result<DownloadCleanupResult> = runCatching {
        val snapshot = downloadsStore.read()
        val directory = downloadsStore.downloadsDirectory().canonicalFile
        val referencedFileNames = snapshot.items
            .flatMap { record -> listOfNotNull(record.localFileName) + record.subtitleFileNames }
            .toSet()
        var deletedFiles = 0
        var deletedBytes = 0L

        directory.listFiles().orEmpty()
            .filter { file -> file.isFile && file.name != "downloads.json" && file.name !in referencedFileNames }
            .forEach { file ->
                val target = file.canonicalFile
                val byteCount = target.length()
                if (target.isInside(directory) && target.delete()) {
                    deletedFiles += 1
                    deletedBytes += byteCount
                }
            }

        DownloadCleanupResult(
            snapshot = writeSnapshot(snapshot),
            deletedFiles = deletedFiles,
            deletedBytes = deletedBytes,
        )
    }

    private suspend fun update(
        id: String,
        transform: (DownloadRecord) -> DownloadRecord,
    ): Result<DownloadSnapshot> = runCatching {
        val snapshot = downloadsStore.read()
        val updated = snapshot.items.map { record ->
            if (record.id == id) {
                transform(record).copy(updatedAt = System.currentTimeMillis())
            } else {
                record
            }
        }
        writeSnapshot(snapshot.copy(items = updated))
    }

    private suspend fun writeRecord(record: DownloadRecord): DownloadSnapshot {
        val snapshot = downloadsStore.read()
        return writeSnapshot(
            snapshot.copy(
                items = listOf(record.copy(updatedAt = System.currentTimeMillis())) +
                    snapshot.items.filterNot { it.id == record.id },
            ),
        )
    }

    private suspend fun writeSnapshot(snapshot: DownloadSnapshot): DownloadSnapshot {
        val normalized = snapshot.normalized()
        downloadsStore.write(normalized)
        return normalized
    }

    private fun deleteDownloadedFiles(record: DownloadRecord) {
        val directory = downloadsStore.downloadsDirectory().canonicalFile
        listOfNotNull(record.localFileName)
            .plus(record.subtitleFileNames)
            .forEach { name ->
                File(directory, name)
                    .canonicalFile
                    .takeIf { file -> file.isInside(directory) && file.exists() }
                    ?.delete()
            }
    }
}

private class DirectFileDownloadEngine(
    private val downloadsStore: DownloadsStore,
) {
    suspend fun download(record: DownloadRecord): DownloadRecord = withContext(Dispatchers.IO) {
        val sourceUri = record.sourceUri ?: return@withContext record.copy(
            status = DownloadStatus.FAILED,
            error = "No source URI was captured for this download.",
        )

        runCatching {
            val directory = downloadsStore.downloadsDirectory()
            val outputFile = File(directory, record.outputFileName(sourceUri))
            var downloadedBytes = 0L
            var totalBytes = 0L

            val connection = URL(sourceUri).openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = true
                record.requestHeaders.forEach { (name, value) ->
                    connection.setRequestProperty(name, value)
                }
                connection.connectTimeout = 20_000
                connection.readTimeout = 30_000
                connection.connect()

                val status = connection.responseCode
                if (status !in 200..299) {
                    error("HTTP $status while downloading ${record.title}")
                }

                totalBytes = connection.contentLengthLong.coerceAtLeast(0L)
                connection.inputStream.use { input ->
                    outputFile.outputStream().use { output ->
                        val buffer = ByteArray(BufferSize)
                        while (true) {
                            val read = input.read(buffer)
                            if (read < 0) break
                            output.write(buffer, 0, read)
                            downloadedBytes += read
                        }
                    }
                }
            } finally {
                connection.disconnect()
            }

            val subtitleFiles = record.subtitleTracks.downloadSubtitles(directory, record.id)
            record.copy(
                status = DownloadStatus.COMPLETED,
                progressPercent = 1f,
                progressLabel = buildString {
                    append("Downloaded ")
                    append(downloadedBytes.toByteCountLabel())
                    if (subtitleFiles.isNotEmpty()) {
                        append(" with ${subtitleFiles.size} subtitle file")
                        if (subtitleFiles.size != 1) append("s")
                    }
                    append(" into Android app storage.")
                },
                downloadedBytes = downloadedBytes,
                totalBytes = totalBytes.takeIf { it > 0 } ?: downloadedBytes,
                localFileName = outputFile.name,
                localUri = outputFile.toURI().toString(),
                subtitleFileNames = subtitleFiles,
                error = null,
            )
        }.getOrElse { error ->
            record.copy(
                status = DownloadStatus.FAILED,
                progressLabel = "Direct download failed: ${error.message ?: "unknown error"}",
                error = error.message ?: error::class.simpleName,
            )
        }
    }

    suspend fun downloadHls(record: DownloadRecord): DownloadRecord = withContext(Dispatchers.IO) {
        val sourceUri = record.sourceUri ?: return@withContext record.copy(
            status = DownloadStatus.FAILED,
            error = "No HLS playlist URI was captured for this download.",
        )

        runCatching {
            val directory = downloadsStore.downloadsDirectory()
            val outputFile = File(directory, "${record.id.safeFileStem()}.ts")
            val hls = HlsPlaylistDownloader(
                headers = record.requestHeaders,
                outputFile = outputFile,
            )
            val result = hls.download(URL(sourceUri))
            val subtitleFiles = record.subtitleTracks.downloadSubtitles(directory, record.id)

            record.copy(
                status = DownloadStatus.COMPLETED,
                progressPercent = 1f,
                progressLabel = buildString {
                    append("Packaged ${result.segmentCount} HLS segment")
                    if (result.segmentCount != 1) append("s")
                    append(" (${result.downloadedBytes.toByteCountLabel()}) into Android app storage.")
                    if (subtitleFiles.isNotEmpty()) {
                        append(" Added ${subtitleFiles.size} subtitle file")
                        if (subtitleFiles.size != 1) append("s")
                        append(".")
                    }
                },
                downloadedBytes = result.downloadedBytes,
                totalBytes = result.downloadedBytes,
                localFileName = outputFile.name,
                localUri = outputFile.toURI().toString(),
                subtitleFileNames = subtitleFiles,
                error = null,
            )
        }.getOrElse { error ->
            record.copy(
                status = DownloadStatus.FAILED,
                progressLabel = "HLS packaging failed: ${error.message ?: "unknown error"}",
                error = error.message ?: error::class.simpleName,
            )
        }
    }
}

private data class HlsDownloadResult(
    val segmentCount: Int,
    val downloadedBytes: Long,
)

private data class HlsVariant(
    val url: URL,
    val bandwidth: Int,
)

private data class HlsSegment(
    val url: URL,
    val sequenceNumber: Long,
)

private data class HlsEncryptionKey(
    val method: String,
    val keyUrl: URL,
    val iv: ByteArray?,
)

private data class HlsDecryptionKey(
    val bytes: ByteArray,
    val iv: ByteArray?,
)

private data class HlsMediaPlaylist(
    val segments: List<HlsSegment>,
    val initSegmentUrl: URL?,
    val encryptionKey: HlsEncryptionKey?,
)

private class HlsPlaylistDownloader(
    private val headers: Map<String, String>,
    private val outputFile: File,
) {
    fun download(playlistUrl: URL): HlsDownloadResult {
        val firstPlaylist = fetchText(playlistUrl)
        val mediaPlaylistUrl: URL
        val mediaPlaylist: String

        if (firstPlaylist.contains("#EXT-X-STREAM-INF")) {
            val bestVariant = parseMasterPlaylist(firstPlaylist, playlistUrl)
                .maxByOrNull(HlsVariant::bandwidth)
                ?: error("HLS master playlist did not contain playable variants.")
            mediaPlaylistUrl = bestVariant.url
            mediaPlaylist = fetchText(bestVariant.url)
        } else {
            mediaPlaylistUrl = playlistUrl
            mediaPlaylist = firstPlaylist
        }

        val parsed = parseMediaPlaylist(mediaPlaylist, mediaPlaylistUrl)
        if (parsed.segments.isEmpty()) {
            error("HLS media playlist did not contain any segments.")
        }

        val decryptionKey = parsed.encryptionKey?.let { key ->
            if (!key.method.equals("AES-128", ignoreCase = true)) {
                error("Unsupported HLS encryption method ${key.method}.")
            }
            HlsDecryptionKey(
                bytes = fetchBytes(key.keyUrl),
                iv = key.iv,
            )
        }

        var downloadedBytes = 0L
        outputFile.outputStream().use { output ->
            parsed.initSegmentUrl?.let { initUrl ->
                val initBytes = fetchBytes(initUrl)
                output.write(initBytes)
                downloadedBytes += initBytes.size
            }

            parsed.segments.forEach { segment ->
                val rawBytes = fetchBytes(segment.url)
                val segmentBytes = if (decryptionKey != null) {
                    decryptAes128(
                        data = rawBytes,
                        keyBytes = decryptionKey.bytes,
                        iv = decryptionKey.iv ?: segment.sequenceNumber.toAesIv(),
                    )
                } else {
                    rawBytes
                }
                output.write(segmentBytes)
                downloadedBytes += segmentBytes.size
            }
        }

        return HlsDownloadResult(
            segmentCount = parsed.segments.size,
            downloadedBytes = downloadedBytes,
        )
    }

    private fun parseMasterPlaylist(content: String, baseUrl: URL): List<HlsVariant> {
        val lines = content.lineSequence().map(String::trim).toList()
        val variants = mutableListOf<HlsVariant>()
        var lastBandwidth = -1
        lines.forEach { line ->
            when {
                line.startsWith("#EXT-X-STREAM-INF:") -> {
                    lastBandwidth = line.substringAfter(':').parseAttribute("BANDWIDTH")?.toIntOrNull() ?: 0
                }
                line.isNotEmpty() && !line.startsWith("#") && lastBandwidth >= 0 -> {
                    variants += HlsVariant(
                        url = URL(baseUrl, line),
                        bandwidth = lastBandwidth,
                    )
                    lastBandwidth = -1
                }
            }
        }
        return variants
    }

    private fun parseMediaPlaylist(content: String, baseUrl: URL): HlsMediaPlaylist {
        val lines = content.lineSequence().map(String::trim).toList()
        val segments = mutableListOf<HlsSegment>()
        var mediaSequence = 0L
        var nextSequence = 0L
        var initSegmentUrl: URL? = null
        var encryptionKey: HlsEncryptionKey? = null

        lines.forEach { line ->
            when {
                line.startsWith("#EXT-X-MEDIA-SEQUENCE:") -> {
                    mediaSequence = line.substringAfter(':').toLongOrNull() ?: 0L
                    nextSequence = mediaSequence
                }
                line.startsWith("#EXT-X-MAP:") -> {
                    val attrs = line.substringAfter(':')
                    if (attrs.parseAttribute("BYTERANGE") != null) {
                        error("HLS init segments with BYTERANGE are not supported yet.")
                    }
                    initSegmentUrl = attrs.parseAttribute("URI")?.let { uri -> URL(baseUrl, uri) }
                }
                line.startsWith("#EXT-X-KEY:") -> {
                    val attrs = line.substringAfter(':')
                    val method = attrs.parseAttribute("METHOD") ?: "NONE"
                    if (method.equals("NONE", ignoreCase = true)) {
                        encryptionKey = null
                    } else {
                        val uri = attrs.parseAttribute("URI")
                            ?: error("Encrypted HLS playlist is missing EXT-X-KEY URI.")
                        encryptionKey = HlsEncryptionKey(
                            method = method,
                            keyUrl = URL(baseUrl, uri),
                            iv = attrs.parseAttribute("IV")?.hexToBytes(),
                        )
                    }
                }
                line.startsWith("#EXT-X-BYTERANGE:") -> {
                    error("HLS segments with BYTERANGE are not supported yet.")
                }
                line.isNotEmpty() && !line.startsWith("#") -> {
                    segments += HlsSegment(
                        url = URL(baseUrl, line),
                        sequenceNumber = nextSequence,
                    )
                    nextSequence += 1
                }
            }
        }

        return HlsMediaPlaylist(
            segments = segments,
            initSegmentUrl = initSegmentUrl,
            encryptionKey = encryptionKey,
        )
    }

    private fun fetchText(url: URL): String = fetchBytes(url).toString(Charsets.UTF_8)

    private fun fetchBytes(url: URL): ByteArray {
        val connection = url.openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = true
            headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            connection.connectTimeout = 20_000
            connection.readTimeout = 30_000
            connection.connect()
            val status = connection.responseCode
            if (status !in 200..299) {
                error("HTTP $status while fetching HLS resource ${url.toExternalForm()}")
            }
            return connection.inputStream.use { input -> input.readBytes() }
        } finally {
            connection.disconnect()
        }
    }
}

private fun DownloadSnapshot.normalized(): DownloadSnapshot = copy(
    items = items
        .map { it.copy(progressPercent = it.progressPercent.coerceIn(0f, 1f)) }
        .sortedByDescending(DownloadRecord::updatedAt),
)

private fun DownloadDraft.toRecord(
    id: String,
    existing: DownloadRecord?,
): DownloadRecord {
    val resolvedSource = playerSource
    return DownloadRecord(
        id = id,
        detailTarget = detailTarget,
        title = title,
        subtitle = subtitle,
        imageUrl = imageUrl,
        backdropUrl = backdropUrl,
        mediaLabel = mediaLabel,
        status = DownloadStatus.QUEUED,
        progressPercent = existing?.takeIf { it.status != DownloadStatus.COMPLETED }?.progressPercent ?: 0f,
        progressLabel = progressLabel ?: if (resolvedSource != null) {
            "Direct stream captured. Android will attempt an offline file transfer now."
        } else {
            "Queued for offline preparation while Android waits for source resolution."
        },
        sourceLabel = sourceLabel
            ?: resolvedSource?.title
            ?: existing?.sourceLabel
            ?: "Pending source resolution",
        sourceUri = resolvedSource?.uri ?: existing?.sourceUri,
        mimeType = resolvedSource?.mimeType ?: existing?.mimeType,
        requestHeaders = resolvedSource?.headers ?: existing?.requestHeaders.orEmpty(),
        subtitleTracks = resolvedSource?.subtitles ?: existing?.subtitleTracks.orEmpty(),
        downloadedBytes = existing?.downloadedBytes ?: 0,
        totalBytes = existing?.totalBytes ?: 0,
        localFileName = existing?.localFileName,
        localUri = existing?.localUri,
        subtitleFileNames = existing?.subtitleFileNames.orEmpty(),
        error = null,
        addedAt = existing?.addedAt ?: System.currentTimeMillis(),
        updatedAt = System.currentTimeMillis(),
    )
}

private fun List<SubtitleTrack>.downloadSubtitles(directory: File, downloadId: String): List<String> =
    mapIndexedNotNull { index, subtitle ->
        val subtitleUri = subtitle.uri?.takeIf { it.isDirectHttpUrl() } ?: return@mapIndexedNotNull null
        runCatching {
            val extension = subtitleUri.fileExtension(default = "vtt")
            val file = File(directory, "${downloadId.safeFileStem()}_sub_${index + 1}.$extension")
            val connection = URL(subtitleUri).openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = true
                connection.connectTimeout = 15_000
                connection.readTimeout = 20_000
                connection.connect()
                if (connection.responseCode !in 200..299) return@runCatching null
                connection.inputStream.use { input ->
                    file.outputStream().use { output -> input.copyTo(output) }
                }
                file.name
            } finally {
                connection.disconnect()
            }
        }.getOrNull()
    }

private fun DownloadRecord.outputFileName(sourceUri: String): String {
    val extension = sourceUri.fileExtension(
        default = when {
            mimeType?.contains("mp4", ignoreCase = true) == true -> "mp4"
            mimeType?.contains("matroska", ignoreCase = true) == true -> "mkv"
            else -> "mp4"
        },
    )
    return "${id.safeFileStem()}.$extension"
}

private fun DetailTarget.downloadKey(suffix: String?): String {
    val base = when (this) {
        is DetailTarget.AniListMediaTarget -> "download:anilist:$id"
        is DetailTarget.TmdbMovie -> "download:tmdb_movie:$id"
        is DetailTarget.TmdbShow -> "download:tmdb_show:$id"
    }
    val cleanSuffix = suffix
        ?.trim()
        ?.takeIf { it.isNotBlank() }
        ?.safeFileStem()
    return cleanSuffix?.let { "$base:$it" } ?: base
}

private fun File.isInside(root: File): Boolean =
    path == root.path || path.startsWith(root.path + File.separator)

private fun String.isDirectHttpUrl(): Boolean =
    startsWith("http://", ignoreCase = true) || startsWith("https://", ignoreCase = true)

private fun String.isTorrentLikeUri(): Boolean {
    val clean = trim()
    return clean.startsWith("magnet:", ignoreCase = true) ||
        clean.contains("btih:", ignoreCase = true) ||
        clean.substringBefore('?').substringBefore('#').endsWith(".torrent", ignoreCase = true)
}

private fun String.isHlsPlaylist(): Boolean =
    substringBefore('?').endsWith(".m3u8", ignoreCase = true)

private fun String.fileExtension(default: String): String {
    val cleanPath = substringBefore('?').substringBefore('#')
    val extension = cleanPath.substringAfterLast('.', missingDelimiterValue = "")
        .takeIf { it.length in 2..5 && it.all(Char::isLetterOrDigit) }
        ?: default
    return extension.lowercase()
}

private fun String.safeFileStem(): String = replace(Regex("[^A-Za-z0-9._-]+"), "_")
    .trim('_')
    .ifBlank { "download_${System.currentTimeMillis()}" }

private fun String.parseAttribute(key: String): String? {
    val prefix = "$key="
    var index = 0
    while (index < length) {
        val nextComma = indexOf(',', startIndex = index).takeIf { it >= 0 } ?: length
        val partStart = index
        val keyStart = substring(partStart, nextComma).indexOf(prefix)
        if (keyStart == 0) {
            val valueStart = partStart + prefix.length
            if (valueStart < length && this[valueStart] == '"') {
                val endQuote = indexOf('"', startIndex = valueStart + 1).takeIf { it >= 0 } ?: length
                return substring(valueStart + 1, endQuote)
            }
            return substring(valueStart, nextComma)
        }
        index = nextComma + 1
    }
    return null
}

private fun String.hexToBytes(): ByteArray {
    val clean = removePrefix("0x").removePrefix("0X")
    require(clean.length % 2 == 0) { "Invalid hex length." }
    return ByteArray(clean.length / 2) { index ->
        clean.substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}

private fun Long.toAesIv(): ByteArray = ByteBuffer.allocate(16)
    .putLong(0L)
    .putLong(this)
    .array()

private fun decryptAes128(
    data: ByteArray,
    keyBytes: ByteArray,
    iv: ByteArray,
): ByteArray {
    require(keyBytes.size == 16) { "HLS AES-128 key must be 16 bytes." }
    require(iv.size == 16) { "HLS AES-128 IV must be 16 bytes." }
    val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
    cipher.init(
        Cipher.DECRYPT_MODE,
        SecretKeySpec(keyBytes, "AES"),
        IvParameterSpec(iv),
    )
    return cipher.doFinal(data)
}

private fun Long.toByteCountLabel(): String {
    if (this < 1_000) return "$this B"
    val units = listOf("KB", "MB", "GB")
    var value = this / 1_000.0
    var unit = units.first()
    for (candidate in units.drop(1)) {
        if (value < 1_000.0) break
        value /= 1_000.0
        unit = candidate
    }
    return String.format("%.1f %s", value, unit)
}
