package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.BackupCatalog
import dev.soupy.eclipse.android.core.model.CatalogSnapshot
import dev.soupy.eclipse.android.core.model.mergedWithDefaultCatalogs
import dev.soupy.eclipse.android.core.storage.CatalogStore

class CatalogRepository(
    private val catalogStore: CatalogStore,
) {
    suspend fun loadSnapshot(): Result<CatalogSnapshot> = runCatching {
        catalogStore.read().merged()
    }

    suspend fun enabledCatalogs(): List<BackupCatalog> = catalogStore.read().merged().enabledCatalogs

    suspend fun restoreFromBackup(catalogs: List<BackupCatalog>): Result<CatalogSnapshot> = runCatching {
        write(CatalogSnapshot(catalogs = catalogs.mergedWithDefaultCatalogs()))
    }

    suspend fun exportCatalogs(): List<BackupCatalog> = catalogStore.read().merged().catalogs

    suspend fun setCatalogEnabled(id: String, enabled: Boolean): Result<CatalogSnapshot> = runCatching {
        val snapshot = catalogStore.read().merged()
        write(
            snapshot.copy(
                catalogs = snapshot.catalogs.map { catalog ->
                    if (catalog.id == id) catalog.copy(isEnabled = enabled) else catalog
                },
            ),
        )
    }

    suspend fun moveCatalog(id: String, direction: Int): Result<CatalogSnapshot> = runCatching {
        val snapshot = catalogStore.read().merged()
        val catalogs = snapshot.catalogs.toMutableList()
        val index = catalogs.indexOfFirst { it.id == id }
        if (index == -1) return@runCatching snapshot
        val newIndex = (index + direction).coerceIn(0, catalogs.lastIndex)
        if (newIndex == index) return@runCatching snapshot
        val moved = catalogs.removeAt(index)
        catalogs.add(newIndex, moved)
        write(CatalogSnapshot(catalogs = catalogs.mapIndexed { order, catalog -> catalog.copy(order = order) }))
    }

    private suspend fun write(snapshot: CatalogSnapshot): CatalogSnapshot {
        val normalized = snapshot.merged()
        catalogStore.write(normalized)
        return normalized
    }
}

private fun CatalogSnapshot.merged(): CatalogSnapshot = copy(
    catalogs = catalogs.mergedWithDefaultCatalogs(),
)

