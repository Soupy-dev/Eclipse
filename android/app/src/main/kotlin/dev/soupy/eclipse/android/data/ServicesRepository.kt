package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.StremioManifest
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.network.StremioService
import dev.soupy.eclipse.android.core.storage.ServiceDao
import dev.soupy.eclipse.android.core.storage.ServiceEntity
import dev.soupy.eclipse.android.core.storage.StremioAddonDao
import dev.soupy.eclipse.android.core.storage.StremioAddonEntity
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString

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

class ServicesRepository(
    private val serviceDao: ServiceDao,
    private val stremioAddonDao: StremioAddonDao,
    private val stremioService: StremioService,
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

    suspend fun setServiceEnabled(id: String, enabled: Boolean): Result<Unit> = updateService(id) { service ->
        service.copy(enabled = enabled, updatedAt = System.currentTimeMillis())
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
