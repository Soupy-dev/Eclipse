package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.TrackerStateSnapshot
import dev.soupy.eclipse.android.core.storage.TrackerStore

class TrackerRepository(
    private val trackerStore: TrackerStore,
) {
    suspend fun loadSnapshot(): Result<TrackerStateSnapshot> = runCatching {
        trackerStore.read()
    }

    suspend fun restoreFromBackup(snapshot: TrackerStateSnapshot): Result<TrackerStateSnapshot> = runCatching {
        trackerStore.write(snapshot)
        snapshot
    }

    suspend fun exportState(fallback: TrackerStateSnapshot): TrackerStateSnapshot {
        val state = trackerStore.read()
        return if (state.accounts.isNotEmpty() || state.accessToken != null || state.provider != null) {
            state
        } else {
            fallback
        }
    }
}

