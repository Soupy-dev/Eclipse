package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.TrackerAccountSnapshot
import dev.soupy.eclipse.android.core.model.TrackerStateSnapshot
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.EpisodeProgressBackup
import dev.soupy.eclipse.android.core.model.MovieProgressBackup
import dev.soupy.eclipse.android.core.model.progressPercent
import dev.soupy.eclipse.android.core.storage.TrackerStore
import java.time.Instant

data class TrackerAccountDraft(
    val service: String,
    val username: String,
    val accessToken: String,
    val refreshToken: String? = null,
    val userId: String = "",
)

class TrackerRepository(
    private val trackerStore: TrackerStore,
    private val progressRepository: ProgressRepository,
    private val syncClient: TrackerSyncClient = TrackerSyncClient(),
) {
    suspend fun loadSnapshot(): Result<TrackerStateSnapshot> = runCatching {
        trackerStore.read()
    }

    suspend fun restoreFromBackup(snapshot: TrackerStateSnapshot): Result<TrackerStateSnapshot> = runCatching {
        trackerStore.write(snapshot)
        snapshot
    }

    suspend fun saveManualAccount(draft: TrackerAccountDraft): Result<TrackerStateSnapshot> = runCatching {
        val service = draft.service.trim().ifBlank { "Tracker" }
        val accessToken = draft.accessToken.trim()
        require(accessToken.isNotBlank()) { "Tracker token or PIN is required." }

        val current = trackerStore.read()
        val account = TrackerAccountSnapshot(
            service = service,
            username = draft.username.trim(),
            accessToken = accessToken,
            refreshToken = draft.refreshToken?.trim()?.takeIf(String::isNotBlank),
            userId = draft.userId.trim(),
            isConnected = true,
        )
        val accounts = listOf(account) + current.accounts.filterNot {
            it.service.equals(service, ignoreCase = true)
        }
        val updated = current.copy(
            accounts = accounts,
            syncEnabled = current.syncEnabled,
            lastSyncDate = current.lastSyncDate,
            provider = service,
            accessToken = accessToken,
            refreshToken = account.refreshToken,
            userName = account.username.takeIf(String::isNotBlank),
        )
        trackerStore.write(updated)
        updated
    }

    suspend fun setSyncEnabled(enabled: Boolean): Result<TrackerStateSnapshot> = runCatching {
        val updated = trackerStore.read().copy(syncEnabled = enabled)
        trackerStore.write(updated)
        updated
    }

    suspend fun markSyncAttempted(): Result<TrackerStateSnapshot> = runCatching {
        val updated = trackerStore.read().copy(lastSyncDate = Instant.now().toString())
        trackerStore.write(updated)
        updated
    }

    suspend fun syncPlaybackProgress(draft: TrackerPlaybackProgressDraft): Result<TrackerSyncSummary> = runCatching {
        syncItems(listOf(draft.toTrackerSyncItem()))
    }

    suspend fun syncStoredProgress(): Result<TrackerSyncSummary> = runCatching {
        val progress = progressRepository.loadSnapshot().getOrThrow()
        val showTitles = progress.showMetadata.mapValues { (_, metadata) -> metadata.title }
        val items = progress.movieProgress
            .filter { it.isWatched || it.progressPercent >= TrackerWatchedThreshold }
            .map(MovieProgressBackup::toTrackerSyncItem) +
            progress.episodeProgress
                .filter { it.isWatched || it.progressPercent >= TrackerWatchedThreshold }
                .map { episode -> episode.toTrackerSyncItem(showTitles[episode.showId.toString()]) }

        syncItems(items)
    }

    suspend fun disconnect(service: String): Result<TrackerStateSnapshot> = runCatching {
        val normalized = service.trim()
        require(normalized.isNotBlank()) { "Tracker service is required." }
        val current = trackerStore.read()
        val accounts = current.accounts.filterNot {
            it.service.equals(normalized, ignoreCase = true)
        }
        val primary = accounts.firstOrNull()
        val updated = current.copy(
            accounts = accounts,
            provider = primary?.service,
            accessToken = primary?.accessToken,
            refreshToken = primary?.refreshToken,
            userName = primary?.username,
        )
        trackerStore.write(updated)
        updated
    }

    suspend fun exportState(fallback: TrackerStateSnapshot): TrackerStateSnapshot {
        val state = trackerStore.read()
        return if (state.accounts.isNotEmpty() || state.accessToken != null || state.provider != null) {
            state
        } else {
            fallback
        }
    }

    private suspend fun syncItems(items: List<TrackerSyncItem>): TrackerSyncSummary {
        val state = trackerStore.read()
        val accounts = state.connectedAccounts()
        if (!state.syncEnabled || accounts.isEmpty() || items.isEmpty()) {
            return TrackerSyncSummary(
                state = state,
                attemptedAccounts = if (state.syncEnabled) accounts.size else 0,
                attemptedItems = items.size,
                skippedItems = if (!state.syncEnabled) items.size else 0,
            )
        }

        var syncedItems = 0
        var skippedItems = 0
        val failures = mutableListOf<String>()

        accounts.forEach { account ->
            items.forEach { item ->
                val result = syncClient.sync(account, item)
                when {
                    result.synced -> syncedItems += 1
                    result.skipped -> skippedItems += 1
                    result.message != null -> failures += result.message
                    else -> skippedItems += 1
                }
            }
        }

        val updatedState = if (syncedItems > 0 || failures.isNotEmpty()) {
            state.copy(lastSyncDate = Instant.now().toString())
        } else {
            state
        }
        if (updatedState != state) {
            trackerStore.write(updatedState)
        }

        return TrackerSyncSummary(
            state = updatedState,
            attemptedAccounts = accounts.size,
            attemptedItems = items.size,
            syncedItems = syncedItems,
            skippedItems = skippedItems,
            failures = failures,
        )
    }
}

private fun TrackerStateSnapshot.connectedAccounts(): List<TrackerAccountSnapshot> {
    val modern = accounts.filter { it.isConnected && it.accessToken.isNotBlank() }
    if (modern.isNotEmpty()) return modern
    val provider = provider?.takeIf { it.isNotBlank() }
    val token = accessToken?.takeIf { it.isNotBlank() }
    return if (provider != null && token != null) {
        listOf(
            TrackerAccountSnapshot(
                service = provider,
                username = userName.orEmpty(),
                accessToken = token,
                refreshToken = refreshToken,
                isConnected = true,
            ),
        )
    } else {
        emptyList()
    }
}

private fun MovieProgressBackup.toTrackerSyncItem(): TrackerSyncItem = TrackerSyncItem(
    target = DetailTarget.TmdbMovie(id),
    title = title.ifBlank { "Movie $id" },
    progressPercent = progressPercent,
    isFinished = isWatched,
)

private fun EpisodeProgressBackup.toTrackerSyncItem(showTitle: String?): TrackerSyncItem = TrackerSyncItem(
    target = DetailTarget.TmdbShow(showId),
    title = showTitle?.takeIf { it.isNotBlank() } ?: "Show $showId",
    seasonNumber = seasonNumber,
    episodeNumber = episodeNumber,
    anilistMediaId = anilistMediaId,
    anilistEpisodeNumber = episodeNumber,
    progressPercent = progressPercent,
    isFinished = isWatched,
)
