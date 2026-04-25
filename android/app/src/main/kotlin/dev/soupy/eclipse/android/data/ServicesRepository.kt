package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.js.ServiceEpisodeLink
import dev.soupy.eclipse.android.core.js.ServiceRuntime
import dev.soupy.eclipse.android.core.js.ServiceRuntimeSource
import dev.soupy.eclipse.android.core.js.ServiceSearchRequest
import dev.soupy.eclipse.android.core.js.ServiceSearchResult
import dev.soupy.eclipse.android.core.js.ServiceStreamResult
import dev.soupy.eclipse.android.core.model.StremioManifest
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.network.StremioService
import dev.soupy.eclipse.android.core.storage.ServiceDao
import dev.soupy.eclipse.android.core.storage.ServiceEntity
import dev.soupy.eclipse.android.core.storage.StremioAddonDao
import dev.soupy.eclipse.android.core.storage.StremioAddonEntity
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

data class ServiceDraft(
    val name: String,
    val scriptUrl: String,
    val manifestUrl: String? = null,
)

data class ServiceSourceRecord(
    val id: String,
    val autoModeId: String,
    val name: String,
    val subtitle: String? = null,
    val configurationJson: String? = null,
    val configurationSummary: String? = null,
    val enabled: Boolean = true,
    val sortIndex: Int = 0,
)

data class StremioAddonRecord(
    val transportUrl: String,
    val autoModeId: String,
    val manifestId: String,
    val name: String,
    val subtitle: String? = null,
    val logoUrl: String? = null,
    val enabled: Boolean = true,
    val sortIndex: Int = 0,
    val configured: Boolean = true,
    val configurable: Boolean = false,
    val configurationRequired: Boolean = false,
    val configurationUrl: String? = null,
    val types: List<String> = emptyList(),
    val resources: List<String> = emptyList(),
    val idPrefixes: List<String> = emptyList(),
    val catalogCount: Int = 0,
)

data class ServicesSnapshot(
    val services: List<ServiceSourceRecord> = emptyList(),
    val stremioAddons: List<StremioAddonRecord> = emptyList(),
)

data class ServicesUpdateSummary(
    val refreshedAddons: Int,
    val failedAddons: Int,
    val refreshedServices: Int = 0,
    val failedServices: Int = 0,
) {
    val statusMessage: String
        get() = when {
            refreshedAddons == 0 && failedAddons == 0 && refreshedServices == 0 && failedServices == 0 ->
                "No services or Stremio addons needed refresh."
            failedAddons == 0 && failedServices == 0 ->
                "Refreshed $refreshedServices service${refreshedServices.pluralSuffix()} and $refreshedAddons Stremio addon${refreshedAddons.pluralSuffix()}."
            else ->
                "Refreshed $refreshedServices service${refreshedServices.pluralSuffix()} and $refreshedAddons addon${refreshedAddons.pluralSuffix()} with ${failedServices + failedAddons} issue${(failedServices + failedAddons).pluralSuffix()}."
        }
}

data class ServiceResolvedDetail(
    val serviceId: String,
    val serviceName: String,
    val href: String,
    val title: String,
    val imageUrl: String? = null,
    val description: String? = null,
    val aliases: String? = null,
    val airdate: String? = null,
    val episodes: List<ServiceEpisodeLink> = emptyList(),
)

class ServicesRepository(
    private val serviceDao: ServiceDao,
    private val stremioAddonDao: StremioAddonDao,
    private val stremioService: StremioService,
    private val serviceRuntime: ServiceRuntime,
) {
    fun observeSnapshot(): Flow<ServicesSnapshot> = combine(
        serviceDao.observeAll(),
        stremioAddonDao.observeAll(),
    ) { services, addons ->
        ServicesSnapshot(
            services = services.map { entity ->
                ServiceSourceRecord(
                    id = entity.id,
                    autoModeId = entity.autoModeId,
                    name = entity.name,
                    subtitle = buildServiceSubtitle(entity),
                    configurationJson = entity.configurationJson,
                    configurationSummary = entity.configurationSummary(),
                    enabled = entity.enabled,
                    sortIndex = entity.sortIndex,
                )
            },
            stremioAddons = addons.map { entity ->
                val manifest = entity.manifest()
                StremioAddonRecord(
                    transportUrl = entity.transportUrl,
                    autoModeId = entity.autoModeId,
                    manifestId = entity.manifestId,
                    name = entity.name,
                    subtitle = manifest?.description ?: entity.transportUrl,
                    logoUrl = manifest?.logoUrl,
                    enabled = entity.enabled,
                    sortIndex = entity.sortIndex,
                    configured = entity.configured,
                    configurable = manifest?.behaviorHints?.configurable == true,
                    configurationRequired = manifest?.behaviorHints?.configurationRequired == true,
                    configurationUrl = manifest?.takeIf { it.behaviorHints.configurable }?.let { entity.transportUrl.configurationUrl() },
                    types = manifest?.types.orEmpty(),
                    resources = manifest?.resources.orEmpty().mapNotNull { resource -> resource.name.takeIf(String::isNotBlank) },
                    idPrefixes = manifest?.idPrefixes.orEmpty().ifEmpty {
                        manifest?.resources.orEmpty().flatMap { resource -> resource.idPrefixes }
                    },
                    catalogCount = manifest?.catalogs.orEmpty().size,
                )
            },
        )
    }

    suspend fun addService(draft: ServiceDraft): Result<Unit> = runCatching {
        val normalizedName = draft.name.trim()
        val normalizedScript = draft.scriptUrl.trim()
        require(normalizedName.isNotEmpty()) { "Give the service a name." }
        require(normalizedScript.isNotEmpty()) { "Provide a script URL for the service." }

        val current = serviceDao.observeAll().first()
        val existing = current.firstOrNull {
            it.name.equals(normalizedName, ignoreCase = true) ||
                it.scriptUrl.equals(normalizedScript, ignoreCase = true)
        }
        val now = System.currentTimeMillis()
        val id = existing?.id ?: normalizedName.slugified()
        val nextSortIndex = existing?.sortIndex ?: current.maxOfOrNull(ServiceEntity::sortIndex)?.plus(1) ?: 0

        serviceDao.upsert(
            ServiceEntity(
                id = id,
                name = normalizedName,
                manifestUrl = draft.manifestUrl?.trim()?.takeIf { it.isNotEmpty() },
                scriptUrl = normalizedScript,
                enabled = existing?.enabled ?: true,
                sortIndex = nextSortIndex,
                sourceKind = if (draft.manifestUrl.isNullOrBlank()) "script" else "manifest+script",
                configurationJson = existing?.configurationJson,
                createdAt = existing?.createdAt ?: now,
                updatedAt = now,
            ),
        )
    }

    suspend fun importStremioAddon(rawTransportUrl: String): Result<Unit> = runCatching {
        val transportUrl = rawTransportUrl.normalizedTransportUrl()
        require(transportUrl.isNotEmpty()) { "Paste a Stremio transport URL first." }

        val manifest = stremioService.fetchManifest(transportUrl).orThrow()
        val current = stremioAddonDao.observeAll().first()
        val existing = current.firstOrNull { it.transportUrl.equals(transportUrl, ignoreCase = true) }
        val now = System.currentTimeMillis()
        val configured = !manifest.behaviorHints.configurationRequired

        stremioAddonDao.upsert(
            StremioAddonEntity(
                transportUrl = transportUrl,
                manifestId = manifest.id.ifBlank { transportUrl },
                name = manifest.name.ifBlank { transportUrl },
                enabled = existing?.enabled ?: configured,
                sortIndex = existing?.sortIndex ?: current.maxOfOrNull(StremioAddonEntity::sortIndex)?.plus(1) ?: 0,
                configured = configured,
                manifestJson = EclipseJson.encodeToString(manifest),
                createdAt = existing?.createdAt ?: now,
                updatedAt = now,
            ),
        )
    }

    suspend fun refreshStremioAddon(transportUrl: String): Result<Unit> = runCatching {
        val current = stremioAddonDao.observeAll().first()
            .firstOrNull { it.transportUrl == transportUrl }
            ?: error("Stremio addon was not found.")
        val manifest = stremioService.fetchManifest(current.transportUrl).orThrow()
        val configured = !manifest.behaviorHints.configurationRequired
        stremioAddonDao.upsert(
            current.copy(
                manifestId = manifest.id.ifBlank { current.transportUrl },
                name = manifest.name.ifBlank { current.name },
                configured = configured,
                enabled = if (configured) current.enabled else false,
                manifestJson = EclipseJson.encodeToString(manifest),
                updatedAt = System.currentTimeMillis(),
            ),
        )
    }

    suspend fun refreshAllAddons(): Result<ServicesUpdateSummary> = runCatching {
        val addons = stremioAddonDao.observeAll().first()
        var refreshed = 0
        var failed = 0
        addons.forEach { addon ->
            refreshStremioAddon(addon.transportUrl)
                .onSuccess { refreshed += 1 }
                .onFailure { failed += 1 }
        }
        ServicesUpdateSummary(
            refreshedAddons = refreshed,
            failedAddons = failed,
        )
    }

    suspend fun refreshAllSources(): Result<ServicesUpdateSummary> = runCatching {
        val services = serviceDao.observeAll().first()
        var refreshedServices = 0
        var failedServices = 0
        services.forEach { service ->
            refreshService(service.id)
                .onSuccess { refreshedServices += 1 }
                .onFailure { failedServices += 1 }
        }
        val addonSummary = refreshAllAddons().getOrElse {
            ServicesUpdateSummary(refreshedAddons = 0, failedAddons = stremioAddonDao.observeAll().first().size)
        }
        addonSummary.copy(
            refreshedServices = refreshedServices,
            failedServices = failedServices,
        )
    }

    suspend fun refreshService(id: String): Result<Unit> = runCatching {
        val service = serviceDao.observeAll().first().firstOrNull { it.id == id }
            ?: error("Service was not found.")
        val script = service.fetchScript()
        serviceRuntime.load(service.toRuntimeSource(script)).getOrThrow()
        serviceDao.upsert(service.copy(updatedAt = System.currentTimeMillis()))
    }

    suspend fun activeSearchSources(): List<ServiceSourceRecord> =
        observeSnapshot().first().services
            .filter(ServiceSourceRecord::enabled)
            .sortedBy(ServiceSourceRecord::sortIndex)

    suspend fun searchService(
        id: String,
        query: String,
    ): Result<List<ServiceSearchResult>> = runCatching {
        require(query.isNotBlank()) { "Search query cannot be blank." }
        val service = serviceDao.observeAll().first().firstOrNull { it.id == id && it.enabled }
            ?: error("Service is disabled or was not found.")
        val script = service.fetchScript()
        serviceRuntime.search(
            ServiceSearchRequest(
                source = service.toRuntimeSource(script),
                query = query,
            ),
        ).getOrThrow()
    }

    suspend fun loadServiceDetail(
        id: String,
        href: String,
        fallbackTitle: String,
        fallbackImageUrl: String?,
    ): Result<ServiceResolvedDetail> = runCatching {
        val service = serviceDao.observeAll().first().firstOrNull { it.id == id && it.enabled }
            ?: error("Service is disabled or was not found.")
        val script = service.fetchScript()
        val source = service.toRuntimeSource(script)
        val details = serviceRuntime.details(source, href).getOrElse { JsonObject(emptyMap()) }
        val episodes = serviceRuntime.episodes(source, href).getOrElse { emptyList() }
        val detailItems = details["items"] as? JsonArray
        val firstDetail = detailItems?.firstOrNull() as? JsonObject ?: details

        ServiceResolvedDetail(
            serviceId = service.id,
            serviceName = service.name,
            href = href,
            title = fallbackTitle,
            imageUrl = fallbackImageUrl,
            description = firstDetail.stringValue("description"),
            aliases = firstDetail.stringValue("aliases"),
            airdate = firstDetail.stringValue("airdate") ?: firstDetail.stringValue("releaseDate"),
            episodes = episodes,
        )
    }

    suspend fun resolveServiceStream(
        id: String,
        href: String,
        softSub: Boolean = false,
    ): Result<ServiceStreamResult> = runCatching {
        val service = serviceDao.observeAll().first().firstOrNull { it.id == id && it.enabled }
            ?: error("Service is disabled or was not found.")
        val script = service.fetchScript()
        serviceRuntime.stream(
            source = service.toRuntimeSource(script),
            href = href,
            softSub = softSub,
        ).getOrThrow()
    }

    suspend fun setServiceEnabled(id: String, enabled: Boolean): Result<Unit> = updateService(id) { service ->
        service.copy(enabled = enabled, updatedAt = System.currentTimeMillis())
    }

    suspend fun setServiceConfiguration(
        id: String,
        configurationJson: String?,
    ): Result<Unit> = updateService(id) { service ->
        val normalized = configurationJson
            ?.trim()
            ?.takeIf { it.isNotBlank() }
            ?.also { raw ->
                require(runCatching { EclipseJson.decodeFromString<JsonObject>(raw) }.isSuccess) {
                    "Service configuration must be a JSON object."
                }
            }
        service.copy(
            configurationJson = normalized,
            updatedAt = System.currentTimeMillis(),
        )
    }

    suspend fun setAddonEnabled(transportUrl: String, enabled: Boolean): Result<Unit> = updateAddon(transportUrl) { addon ->
        addon.copy(enabled = enabled, updatedAt = System.currentTimeMillis())
    }

    suspend fun removeService(id: String): Result<Unit> = runCatching {
        serviceDao.observeAll().first()
            .firstOrNull { it.id == id }
            ?.let { service -> serviceDao.delete(service) }
    }

    suspend fun removeAddon(transportUrl: String): Result<Unit> = runCatching {
        stremioAddonDao.observeAll().first()
            .firstOrNull { it.transportUrl == transportUrl }
            ?.let { addon -> stremioAddonDao.delete(addon) }
    }

    suspend fun moveService(id: String, direction: MoveDirection): Result<Unit> = runCatching {
        val items = serviceDao.observeAll().first()
        val index = items.indexOfFirst { it.id == id }
        val swapIndex = index + direction.delta
        if (index !in items.indices || swapIndex !in items.indices) return@runCatching

        val current = items[index]
        val other = items[swapIndex]
        val now = System.currentTimeMillis()
        serviceDao.upsert(
            listOf(
                current.copy(sortIndex = other.sortIndex, updatedAt = now),
                other.copy(sortIndex = current.sortIndex, updatedAt = now),
            ),
        )
    }

    suspend fun moveAddon(transportUrl: String, direction: MoveDirection): Result<Unit> = runCatching {
        val items = stremioAddonDao.observeAll().first()
        val index = items.indexOfFirst { it.transportUrl == transportUrl }
        val swapIndex = index + direction.delta
        if (index !in items.indices || swapIndex !in items.indices) return@runCatching

        val current = items[index]
        val other = items[swapIndex]
        val now = System.currentTimeMillis()
        stremioAddonDao.upsert(
            listOf(
                current.copy(sortIndex = other.sortIndex, updatedAt = now),
                other.copy(sortIndex = current.sortIndex, updatedAt = now),
            ),
        )
    }

    enum class MoveDirection(val delta: Int) {
        UP(-1),
        DOWN(1),
    }

    private suspend fun updateService(
        id: String,
        transform: (ServiceEntity) -> ServiceEntity,
    ): Result<Unit> = runCatching {
        val current = serviceDao.observeAll().first().firstOrNull { it.id == id } ?: return@runCatching
        serviceDao.upsert(transform(current))
    }

    private suspend fun updateAddon(
        transportUrl: String,
        transform: (StremioAddonEntity) -> StremioAddonEntity,
    ): Result<Unit> = runCatching {
        val current = stremioAddonDao.observeAll().first()
            .firstOrNull { it.transportUrl == transportUrl } ?: return@runCatching
        stremioAddonDao.upsert(transform(current))
    }
}

private suspend fun ServiceEntity.fetchScript(): String {
    val candidate = scriptUrl?.trim().orEmpty()
    require(candidate.isNotBlank()) { "Service ${name} does not have a script URL." }
    if (candidate.contains('\n') || candidate.contains("function ") || candidate.contains("searchResults")) {
        return candidate
    }
    return withContext(Dispatchers.IO) {
        val connection = (URL(candidate).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 20_000
            requestMethod = "GET"
            setRequestProperty("User-Agent", "Eclipse-Android")
        }
        try {
            require(connection.responseCode in 200..299) {
                "Could not download ${name}'s script (${connection.responseCode})."
            }
            connection.inputStream.bufferedReader().use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }
}

private fun ServiceEntity.toRuntimeSource(script: String): ServiceRuntimeSource {
    val settings = configurationJson
        ?.takeIf { it.isNotBlank() }
        ?.let { raw -> runCatching { EclipseJson.decodeFromString<JsonObject>(raw) }.getOrNull() }
        ?: JsonObject(emptyMap())
    return ServiceRuntimeSource(
        id = id,
        name = name,
        script = script,
        baseUrl = scriptUrl?.substringBeforeLast('/', missingDelimiterValue = scriptUrl ?: ""),
        settings = settings,
    )
}

private fun JsonObject.stringValue(key: String): String? =
    this[key]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }

private val ServiceEntity.autoModeId: String
    get() = "service:$id"

private val StremioAddonEntity.autoModeId: String
    get() = "stremio:$transportUrl"

private fun buildServiceSubtitle(entity: ServiceEntity): String? = when {
    !entity.scriptUrl.isNullOrBlank() && !entity.manifestUrl.isNullOrBlank() ->
        "${entity.scriptUrl} | ${entity.manifestUrl}"
    !entity.scriptUrl.isNullOrBlank() -> entity.scriptUrl
    !entity.manifestUrl.isNullOrBlank() -> entity.manifestUrl
    else -> entity.sourceKind
}

private fun ServiceEntity.configurationSummary(): String? {
    val raw = configurationJson?.takeIf { it.isNotBlank() } ?: return null
    val count = runCatching {
        EclipseJson.decodeFromString<JsonObject>(raw).size
    }.getOrDefault(0)
    return when (count) {
        0 -> "Configuration saved"
        1 -> "1 provider setting saved"
        else -> "$count provider settings saved"
    }
}

private fun StremioAddonEntity.manifest(): StremioManifest? = manifestJson?.runCatching {
    EclipseJson.decodeFromString<StremioManifest>(this)
}?.getOrNull()

private fun String.slugified(): String = trim()
    .lowercase()
    .replace(Regex("[^a-z0-9]+"), "-")
    .trim('-')
    .ifBlank { "service-${System.currentTimeMillis()}" }

private fun String.normalizedTransportUrl(): String = trim()
    .removeSuffix("/manifest.json")
    .removeSuffix("/")

private fun String.configurationUrl(): String =
    trim()
        .removeSuffix("/manifest.json")
        .removeSuffix("/")
        .let { base ->
            if (base.endsWith("/configure", ignoreCase = true)) base else "$base/configure"
        }

private fun Int.pluralSuffix(): String = if (this == 1) "" else "s"
