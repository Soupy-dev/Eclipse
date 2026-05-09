package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.SourceHealthRecord
import dev.soupy.eclipse.android.core.model.SourceHealthSnapshot
import dev.soupy.eclipse.android.core.model.SourceHealthStatus
import dev.soupy.eclipse.android.core.model.supportsResource
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.network.StremioService
import dev.soupy.eclipse.android.core.storage.ServiceDao
import dev.soupy.eclipse.android.core.storage.ServiceEntity
import dev.soupy.eclipse.android.core.storage.SourceHealthStore
import dev.soupy.eclipse.android.core.storage.StremioAddonDao
import dev.soupy.eclipse.android.core.storage.StremioAddonEntity
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

data class SourceHealthCheckSummary(
    val checked: Int = 0,
    val unhealthy: Int = 0,
    val skipped: Boolean = false,
    val message: String,
)

class SourceHealthRepository(
    private val sourceHealthStore: SourceHealthStore,
    private val serviceDao: ServiceDao,
    private val stremioAddonDao: StremioAddonDao,
    private val stremioService: StremioService,
) {
    private val mutex = Mutex()
    private val _snapshot = MutableStateFlow(SourceHealthSnapshot())
    val snapshot: StateFlow<SourceHealthSnapshot> = _snapshot.asStateFlow()

    suspend fun load() {
        _snapshot.value = sourceHealthStore.read()
    }

    suspend fun runDailyEnabledSourceChecksIfNeeded(force: Boolean = false): SourceHealthCheckSummary {
        val current = currentSnapshot()
        val now = System.currentTimeMillis()
        if (!force && current.lastDailyCheckAt?.let { now - it < DailyCheckMillis } == true) {
            return SourceHealthCheckSummary(skipped = true, message = "Source health was checked recently.")
        }

        val services = serviceDao.observeAll().first().filter(ServiceEntity::enabled)
        val addons = stremioAddonDao.observeAll().first().filter(StremioAddonEntity::enabled)
        if (services.isEmpty() && addons.isEmpty()) {
            return SourceHealthCheckSummary(skipped = true, message = "No enabled sources to check.")
        }

        if (!hasInternetConnection()) {
            services.forEach { service ->
                recordNoInternetSkip(sourceId = service.autoModeId, sourceName = service.name)
            }
            addons.forEach { addon ->
                recordNoInternetSkip(sourceId = addon.autoModeId, sourceName = addon.name.ifBlank { addon.transportUrl })
            }
            return SourceHealthCheckSummary(skipped = true, message = "Skipped source health checks because the network is unavailable.")
        }

        var checked = 0
        var unhealthy = 0
        services.forEach { service ->
            val result = checkServiceEndpoint(service)
            checked += 1
            if (!result.ok) unhealthy += 1
            recordEndpoint(
                sourceId = service.autoModeId,
                sourceName = service.name,
                status = if (result.ok) SourceHealthStatus.HEALTHY else SourceHealthStatus.UNHEALTHY,
                reason = result.reason,
            )
        }
        addons.forEach { addon ->
            val result = checkAddonEndpoint(addon)
            checked += 1
            if (!result.ok) unhealthy += 1
            recordEndpoint(
                sourceId = addon.autoModeId,
                sourceName = addon.name.ifBlank { addon.transportUrl },
                status = if (result.ok) SourceHealthStatus.HEALTHY else SourceHealthStatus.UNHEALTHY,
                reason = result.reason,
            )
        }
        mutate { snapshot -> snapshot.copy(lastDailyCheckAt = now) }

        return SourceHealthCheckSummary(
            checked = checked,
            unhealthy = unhealthy,
            message = when {
                checked == 0 -> "No enabled sources to check."
                unhealthy == 0 -> "Checked $checked source${checked.pluralSuffix()}; all are reachable."
                else -> "Checked $checked source${checked.pluralSuffix()}; $unhealthy need${if (unhealthy == 1) "s" else ""} attention."
            },
        )
    }

    suspend fun recordPlaybackSuccess(sourceId: String?, sourceName: String?) {
        val id = sourceId?.takeIf(String::isNotBlank) ?: return
        updateRecord(sourceId = id, sourceName = sourceName.sourceLabel(id)) { record ->
            record.copy(
                lastPlaybackSuccessAt = System.currentTimeMillis(),
                playbackFailureReason = null,
            )
        }
    }

    suspend fun recordPlaybackFailure(
        sourceId: String?,
        sourceName: String?,
        reason: String,
        isSourceFailure: Boolean,
    ) {
        val id = sourceId?.takeIf(String::isNotBlank) ?: return
        updateRecord(sourceId = id, sourceName = sourceName.sourceLabel(id)) { record ->
            record.copy(
                lastPlaybackFailureAt = System.currentTimeMillis(),
                playbackFailureReason = reason,
                endpointReason = if (isSourceFailure && record.endpointReason.isNullOrBlank()) reason else record.endpointReason,
            )
        }
    }

    private suspend fun recordEndpoint(
        sourceId: String,
        sourceName: String,
        status: SourceHealthStatus,
        reason: String?,
    ) {
        updateRecord(sourceId = sourceId, sourceName = sourceName) { record ->
            record.copy(
                endpointStatus = status,
                endpointReason = reason,
                lastEndpointCheckedAt = System.currentTimeMillis(),
            )
        }
    }

    private suspend fun recordNoInternetSkip(sourceId: String, sourceName: String) {
        updateRecord(sourceId = sourceId, sourceName = sourceName) { record ->
            record.copy(lastNoInternetSkipAt = System.currentTimeMillis())
        }
    }

    private suspend fun currentSnapshot(): SourceHealthSnapshot = mutex.withLock {
        if (_snapshot.value.records.isEmpty() && _snapshot.value.lastDailyCheckAt == null) {
            _snapshot.value = sourceHealthStore.read()
        }
        _snapshot.value
    }

    private suspend fun updateRecord(
        sourceId: String,
        sourceName: String,
        transform: (SourceHealthRecord) -> SourceHealthRecord,
    ) {
        mutate { snapshot ->
            val current = snapshot.records[sourceId] ?: SourceHealthRecord(
                sourceId = sourceId,
                sourceName = sourceName,
            )
            val next = transform(current.copy(sourceName = sourceName))
            snapshot.copy(records = snapshot.records + (sourceId to next))
        }
    }

    private suspend fun mutate(transform: suspend (SourceHealthSnapshot) -> SourceHealthSnapshot) {
        mutex.withLock {
            val next = transform(currentSnapshotUnlocked())
            sourceHealthStore.write(next)
            _snapshot.value = next
        }
    }

    private suspend fun currentSnapshotUnlocked(): SourceHealthSnapshot {
        val current = _snapshot.value
        return if (current.records.isEmpty() && current.lastDailyCheckAt == null) {
            sourceHealthStore.read()
        } else {
            current
        }
    }

    private suspend fun checkServiceEndpoint(service: ServiceEntity): EndpointCheckResult {
        val script = service.scriptUrl?.trim().orEmpty()
        val manifest = service.manifestUrl?.trim().orEmpty()
        return runCatching {
            if (manifest.isNotBlank()) {
                val manifestBody = fetchText(manifest)
                val scriptUrlFromManifest = manifestBody.jsonString("scriptUrl")
                    ?: manifestBody.jsonString("scriptURL")
                if (scriptUrlFromManifest != null) {
                    require(fetchText(scriptUrlFromManifest).isNotBlank()) { "Service script is empty." }
                    return EndpointCheckResult(ok = true)
                }
            }

            require(script.isNotBlank()) { "Service script URL is missing." }
            if (script.looksInlineScript()) {
                EndpointCheckResult(ok = true)
            } else {
                require(fetchText(script).isNotBlank()) { "Service script is empty." }
                EndpointCheckResult(ok = true)
            }
        }.getOrElse { error ->
            EndpointCheckResult(ok = false, reason = error.message ?: "Service endpoint check failed.")
        }
    }

    private suspend fun checkAddonEndpoint(addon: StremioAddonEntity): EndpointCheckResult =
        runCatching {
            val manifest = stremioService.fetchManifest(addon.transportUrl).orThrow()
            require(manifest.resources.isEmpty() || manifest.supportsResource("stream")) {
                "Addon manifest no longer supports streams."
            }
            EndpointCheckResult(ok = true)
        }.getOrElse { error ->
            EndpointCheckResult(ok = false, reason = error.message ?: "Addon endpoint check failed.")
        }

    private suspend fun hasInternetConnection(): Boolean = runCatching {
        httpStatus("https://www.google.com/generate_204", timeoutMillis = 5_000) in 200..399
    }.getOrDefault(false)

    private suspend fun fetchText(url: String): String = withContext(Dispatchers.IO) {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout = 15_000
            requestMethod = "GET"
            setRequestProperty("User-Agent", "Eclipse-Android")
        }
        try {
            require(connection.responseCode in 200..299) {
                "Endpoint returned HTTP ${connection.responseCode}."
            }
            connection.inputStream.bufferedReader().use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }

    private suspend fun httpStatus(url: String, timeoutMillis: Int): Int = withContext(Dispatchers.IO) {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = timeoutMillis
            readTimeout = timeoutMillis
            requestMethod = "GET"
            setRequestProperty("User-Agent", "Eclipse-Android")
        }
        try {
            connection.responseCode
        } finally {
            connection.disconnect()
        }
    }
}

private data class EndpointCheckResult(
    val ok: Boolean,
    val reason: String? = null,
)

private const val DailyCheckMillis = 24L * 60L * 60L * 1_000L

private val ServiceEntity.autoModeId: String
    get() = "service:$id"

private val StremioAddonEntity.autoModeId: String
    get() = "stremio:$transportUrl"

private fun String.looksInlineScript(): Boolean =
    contains('\n') || contains("function ") || contains("searchResults")

private fun String.jsonString(key: String): String? = runCatching {
    (EclipseJson.parseToJsonElement(this) as? JsonObject)
        ?.get(key)
        ?.jsonPrimitive
        ?.contentOrNull
        ?.takeIf(String::isNotBlank)
}.getOrNull()

private fun String?.sourceLabel(sourceId: String): String =
    this?.takeIf(String::isNotBlank)
        ?: sourceId.substringAfter(':', missingDelimiterValue = sourceId)

private fun Int.pluralSuffix(): String = if (this == 1) "" else "s"
