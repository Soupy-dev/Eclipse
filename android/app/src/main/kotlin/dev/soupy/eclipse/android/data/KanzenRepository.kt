package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.KanzenModuleSnapshot
import dev.soupy.eclipse.android.core.model.ModuleBackup
import dev.soupy.eclipse.android.core.storage.KanzenStore

class KanzenRepository(
    private val kanzenStore: KanzenStore,
) {
    suspend fun loadSnapshot(): Result<KanzenModuleSnapshot> = runCatching {
        kanzenStore.read()
    }

    suspend fun restoreFromBackup(modules: List<ModuleBackup>): Result<KanzenModuleSnapshot> = runCatching {
        val snapshot = KanzenModuleSnapshot(modules)
        kanzenStore.write(snapshot)
        snapshot
    }

    suspend fun exportModules(fallback: List<ModuleBackup>): List<ModuleBackup> {
        val snapshot = kanzenStore.read()
        return snapshot.modules.takeIf { it.isNotEmpty() } ?: fallback
    }
}

