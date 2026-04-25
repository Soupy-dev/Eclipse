package dev.soupy.eclipse.android.data

import android.content.Context
import android.net.Uri
import dev.soupy.eclipse.android.core.model.BackupData
import dev.soupy.eclipse.android.core.model.BackupDocument
import dev.soupy.eclipse.android.core.model.ServiceBackup
import dev.soupy.eclipse.android.core.model.StremioAddonBackup
import dev.soupy.eclipse.android.core.model.hasBackupData
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.storage.BackupFileStore
import dev.soupy.eclipse.android.core.storage.MangaStore
import dev.soupy.eclipse.android.core.storage.ServiceDao
import dev.soupy.eclipse.android.core.storage.ServiceEntity
import dev.soupy.eclipse.android.core.storage.SettingsStore
import dev.soupy.eclipse.android.core.storage.StremioAddonDao
import dev.soupy.eclipse.android.core.storage.StremioAddonEntity
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext

data class BackupStatusSnapshot(
    val hasLocalBackup: Boolean,
    val headline: String,
    val supportingText: String,
)

class BackupRepository(
    private val context: Context,
    private val backupFileStore: BackupFileStore,
    private val settingsStore: SettingsStore,
    private val mangaStore: MangaStore,
    private val serviceDao: ServiceDao,
    private val stremioAddonDao: StremioAddonDao,
    private val progressRepository: ProgressRepository,
    private val libraryRepository: LibraryRepository,
    private val catalogRepository: CatalogRepository,
    private val trackerRepository: TrackerRepository,
    private val ratingsRepository: RatingsRepository,
    private val recommendationRepository: RecommendationRepository,
    private val kanzenRepository: KanzenRepository,
) {
    suspend fun loadStatus(): Result<BackupStatusSnapshot> = runCatching {
        backupFileStore.read().toStatus()
    }

    suspend fun exportToUri(uri: Uri): Result<BackupStatusSnapshot> = runCatching {
        val document = buildDocument()
        val raw = document.encode(EclipseJson)
        writeUri(uri, raw)
        backupFileStore.write(document)
        document.toStatus(
            headline = "Backup exported",
            supportingPrefix = "Saved settings plus ${document.payload.services.size} services and ${document.payload.stremioAddons.orEmpty().size} addons to your selected JSON archive.",
        )
    }

    suspend fun importFromUri(uri: Uri): Result<BackupStatusSnapshot> = runCatching {
        val document = BackupDocument.decode(EclipseJson, readUri(uri))
        applyPayload(document.payload)
        backupFileStore.write(document)
        document.toStatus(
            headline = "Backup imported",
            supportingPrefix = "Restored Android-owned settings plus ${document.payload.services.size} services and ${document.payload.stremioAddons.orEmpty().size} addons from the selected archive.",
        )
    }

    private suspend fun buildDocument(): BackupDocument {
        val existing = backupFileStore.read()
        val payload = existing?.payload
        val settings = settingsStore.settings.first()
        val services = serviceDao.observeAll().first()
        val addons = stremioAddonDao.observeAll().first()
        val manga = mangaStore.read()
        val exportedProgress = progressRepository.exportForBackup(
            payload?.progressData ?: BackupData().progressData,
        )
        val exportedCatalogs = catalogRepository.exportCatalogs()
            .takeIf { it.isNotEmpty() }
            ?: payload?.catalogs.orEmpty()
        val exportedTrackerState = trackerRepository.exportState(
            payload?.trackerState ?: BackupData().trackerState,
        )
        val exportedRecommendationCache = recommendationRepository.exportCache(
            payload?.recommendationCache ?: BackupData().recommendationCache,
        )
        val exportedRatings = ratingsRepository.exportRatings()
            .takeIf { it.isNotEmpty() }
            ?: payload?.userRatings.orEmpty()
        val exportedCollections = libraryRepository.exportCollections()
            .takeIf { it.isNotEmpty() }
            ?: payload?.collections.orEmpty()
        val exportedMangaCollections = manga.takeIf { it.hasUserData }?.toBackupCollections()
            ?: payload?.mangaCollections.orEmpty()
        val exportedMangaProgress = manga.takeIf { it.hasUserData }?.toBackupProgress()
            ?: payload?.mangaReadingProgress.orEmpty()
        val exportedMangaCatalogs = manga.takeIf { it.hasUserData }?.catalogs
            ?: payload?.mangaCatalogs.orEmpty()
        val exportedMangaModules = manga.takeIf { it.hasUserData }?.toBackupModules()
            ?: payload?.kanzenModules.orEmpty()
        val exportedKanzenModules = kanzenRepository.exportModules(exportedMangaModules)

        return BackupDocument(
            payload = BackupData(
                version = payload?.version ?: "1.0",
                createdDate = Instant.now().toString(),
                accentColor = settings.accentColor,
                tmdbLanguage = settings.tmdbLanguage,
                selectedAppearance = settings.selectedAppearance,
                enableSubtitlesByDefault = settings.enableSubtitlesByDefault,
                defaultSubtitleLanguage = settings.defaultSubtitleLanguage,
                enableVLCSubtitleEditMenu = settings.enableVLCSubtitleEditMenu,
                preferredAnimeAudioLanguage = settings.preferredAnimeAudioLanguage,
                inAppPlayer = settings.inAppPlayer,
                showScheduleTab = settings.showScheduleTab,
                showLocalScheduleTime = settings.showLocalScheduleTime,
                holdSpeedPlayer = settings.holdSpeedPlayer,
                externalPlayer = settings.externalPlayer,
                alwaysLandscape = settings.alwaysLandscape,
                aniSkipAutoSkip = settings.aniSkipAutoSkip,
                skip85sEnabled = settings.skip85sEnabled,
                showNextEpisodeButton = settings.showNextEpisodeButton,
                nextEpisodeThreshold = settings.nextEpisodeThreshold / 100.0,
                vlcHeaderProxyEnabled = settings.vlcHeaderProxyEnabled,
                subtitleForegroundColor = settings.subtitleForegroundColor,
                subtitleStrokeColor = settings.subtitleStrokeColor,
                subtitleStrokeWidth = settings.subtitleStrokeWidth,
                subtitleFontSize = settings.subtitleFontSize,
                subtitleVerticalOffset = settings.subtitleVerticalOffset,
                showKanzen = settings.showKanzen,
                kanzenAutoMode = settings.kanzenAutoMode,
                kanzenAutoUpdateModules = settings.kanzenAutoUpdateModules,
                autoUpdateServicesEnabled = settings.autoUpdateServicesEnabled,
                githubReleaseAutoCheckEnabled = settings.githubReleaseAutoCheckEnabled,
                githubReleaseUpdateAvailable = settings.githubReleaseUpdateAvailable,
                githubReleaseLatestVersion = settings.githubReleaseLatestVersion,
                githubReleaseURL = settings.githubReleaseUrl,
                seasonMenu = settings.seasonMenu,
                horizontalEpisodeList = settings.horizontalEpisodeList,
                mediaColumnsPortrait = settings.mediaColumnsPortrait,
                mediaColumnsLandscape = settings.mediaColumnsLandscape,
                readingMode = settings.readingMode,
                readerFontSize = settings.readerFontSize,
                readerFontFamily = settings.readerFontFamily,
                readerFontWeight = settings.readerFontWeight,
                readerColorPreset = settings.readerColorPreset,
                readerTextAlignment = settings.readerTextAlignment,
                readerLineSpacing = settings.readerLineSpacing,
                readerMargin = settings.readerMargin,
                autoClearCacheEnabled = settings.autoClearCacheEnabled,
                autoClearCacheThresholdMB = settings.autoClearCacheThresholdMB,
                highQualityThreshold = settings.highQualityThreshold,
                filterHorrorContent = settings.filterHorrorContent,
                selectedSimilarityAlgorithm = settings.selectedSimilarityAlgorithm.id,
                collections = exportedCollections,
                progressData = exportedProgress,
                trackerState = exportedTrackerState,
                catalogs = exportedCatalogs,
                services = services.map(ServiceEntity::toBackup),
                stremioAddons = addons.map(StremioAddonEntity::toBackup),
                mangaCollections = exportedMangaCollections,
                mangaReadingProgress = exportedMangaProgress,
                mangaProgressData = payload?.mangaProgressData ?: BackupData().mangaProgressData,
                mangaCatalogs = exportedMangaCatalogs,
                kanzenModules = exportedKanzenModules,
                recommendationCache = exportedRecommendationCache,
                userRatings = exportedRatings,
            ),
            unknownKeys = existing?.unknownKeys.orEmpty(),
        )
    }

    private suspend fun applyPayload(payload: BackupData) {
        settingsStore.restoreFromBackup(payload)
        libraryRepository.restoreCollectionsFromBackup(payload.collections).getOrThrow()
        progressRepository.restoreFromBackup(payload.progressData).getOrThrow()
        catalogRepository.restoreFromBackup(payload.catalogs).getOrThrow()
        trackerRepository.restoreFromBackup(payload.trackerState).getOrThrow()
        ratingsRepository.restoreFromBackup(payload.userRatings).getOrThrow()
        recommendationRepository.restoreFromBackup(payload.recommendationCache).getOrThrow()
        kanzenRepository.restoreFromBackup(payload.kanzenModules).getOrThrow()
        mangaStore.write(payload.toMangaLibrarySnapshot())
        val importedServices = syncServices(payload.services)
        val importedAddons = payload.stremioAddons?.let { syncAddons(it) }
            ?: stremioAddonDao.observeAll().first()
        settingsStore.retainAutoModeSources(
            importedServices.mapTo(mutableSetOf()) { "service:${it.id}" }
                .apply { addAll(importedAddons.map { "stremio:${it.transportUrl}" }) },
        )
    }

    private suspend fun syncServices(backups: List<ServiceBackup>): List<ServiceEntity> {
        val current = serviceDao.observeAll().first()
        val currentById = current.associateBy(ServiceEntity::id)
        val now = System.currentTimeMillis()
        val imported = backups.mapIndexed { index, backup ->
            val id = backup.id.ifBlank { backup.resolvedName.slugified() }
            val currentEntity = currentById[id]
            val inferredScriptUrl = backup.resolvedScriptUrl ?: backup.resolvedManifestUrl?.takeIf {
                backup.sourceKind.equals("script", ignoreCase = true)
            }
            val manifestUrl = backup.resolvedManifestUrl?.takeUnless {
                inferredScriptUrl != null &&
                    backup.sourceKind.equals("script", ignoreCase = true) &&
                    it == inferredScriptUrl
            }
            val scriptUrl = inferredScriptUrl
            ServiceEntity(
                id = id,
                name = backup.resolvedName.ifBlank { id },
                manifestUrl = manifestUrl,
                scriptUrl = scriptUrl,
                enabled = backup.active,
                sortIndex = if (backups.any { it.sortIndex != 0L }) backup.sortIndex.toInt() else index,
                sourceKind = backup.sourceKind ?: when {
                    scriptUrl != null && manifestUrl != null -> "manifest+script"
                    scriptUrl != null -> "script"
                    manifestUrl != null -> "manifest"
                    else -> "backup"
                },
                configurationJson = backup.configurationJson ?: currentEntity?.configurationJson,
                createdAt = currentEntity?.createdAt ?: now,
                updatedAt = now,
            )
        }

        current.filterNot { existing -> imported.any { it.id == existing.id } }
            .forEach { stale -> serviceDao.delete(stale) }
        if (imported.isNotEmpty()) {
            serviceDao.upsert(imported)
        }
        return imported
    }

    private suspend fun syncAddons(backups: List<StremioAddonBackup>): List<StremioAddonEntity> {
        val current = stremioAddonDao.observeAll().first()
        val currentByTransport = current.associateBy(StremioAddonEntity::transportUrl)
        val now = System.currentTimeMillis()
        val imported = backups.mapIndexed { index, backup ->
            val transportUrl = backup.resolvedTransportUrl.ifBlank { "addon-${index + 1}" }
            val currentEntity = currentByTransport[transportUrl]
            StremioAddonEntity(
                transportUrl = transportUrl,
                manifestId = backup.resolvedManifestId,
                name = backup.resolvedName.ifBlank { transportUrl },
                enabled = backup.active,
                sortIndex = if (backups.any { it.sortIndex != 0L }) backup.sortIndex.toInt() else index,
                configured = transportUrl.isNotBlank(),
                manifestJson = backup.manifestJson ?: currentEntity?.manifestJson,
                createdAt = currentEntity?.createdAt ?: now,
                updatedAt = now,
            )
        }

        current.filterNot { existing -> imported.any { it.transportUrl == existing.transportUrl } }
            .forEach { stale -> stremioAddonDao.delete(stale) }
        if (imported.isNotEmpty()) {
            stremioAddonDao.upsert(imported)
        }
        return imported
    }

    private suspend fun readUri(uri: Uri): String = withContext(Dispatchers.IO) {
        context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { reader ->
            reader.readText()
        } ?: error("Couldn't open the selected backup file for reading.")
    }

    private suspend fun writeUri(uri: Uri, raw: String) = withContext(Dispatchers.IO) {
        context.contentResolver.openOutputStream(uri, "wt")?.bufferedWriter()?.use { writer ->
            writer.write(raw)
        } ?: error("Couldn't open the selected backup destination for writing.")
    }
}

private fun ServiceEntity.toBackup(): ServiceBackup = ServiceBackup(
    id = id,
    name = name,
    manifestUrl = manifestUrl,
    scriptUrl = scriptUrl,
    enabled = enabled,
    isActive = enabled,
    sortIndex = sortIndex.toLong(),
    sourceKind = sourceKind,
    configurationJson = configurationJson,
)

private fun StremioAddonEntity.toBackup(): StremioAddonBackup = StremioAddonBackup(
    id = manifestId,
    name = name,
    manifestUrl = transportUrl,
    transportUrl = transportUrl,
    enabled = enabled,
    isActive = enabled,
    sortIndex = sortIndex.toLong(),
    sourceKind = "stremio-addon",
    configuredURL = transportUrl,
    manifestJson = manifestJson,
)

private fun BackupDocument?.toStatus(): BackupStatusSnapshot = if (this == null) {
    BackupStatusSnapshot(
        hasLocalBackup = false,
        headline = "No local backup yet",
        supportingText = "Export a JSON archive from Settings or import an existing Luna backup to stage one on Android.",
    )
} else {
    toStatus(
        headline = "Local backup ready",
        supportingPrefix = "A Luna-compatible JSON archive is staged locally for re-export and future parity work.",
    )
}

private fun BackupDocument.toStatus(
    headline: String,
    supportingPrefix: String,
): BackupStatusSnapshot {
    val createdDate = payload.createdDate?.toReadableTimestamp() ?: "unknown date"
    val preservedSections = buildList {
        if (payload.collections.isNotEmpty()) add("collections")
        if (payload.progressData.hasBackupData()) add("progress")
        if (payload.catalogs.isNotEmpty()) add("catalogs")
        if (payload.mangaCollections.isNotEmpty() || payload.mangaReadingProgress.isNotEmpty() || payload.mangaProgressData.hasBackupData()) add("manga")
        if (payload.kanzenModules.isNotEmpty()) add("modules")
        if (payload.recommendationCache.hasBackupData() || payload.userRatings.isNotEmpty()) add("personalization")
    }
    val preservationText = if (preservedSections.isEmpty()) {
        " The rest of the archive is ready for later Android parity work."
    } else {
        " Preserving ${preservedSections.joinToString()} data so a later export won't drop it while those Android flows are still being built."
    }

    return BackupStatusSnapshot(
        hasLocalBackup = true,
        headline = headline,
        supportingText = "$supportingPrefix Created $createdDate.$preservationText",
    )
}

private fun String.toReadableTimestamp(): String = runCatching {
    Instant.parse(this)
        .atZone(ZoneId.systemDefault())
        .format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm"))
}.getOrElse { this }

private fun String.slugified(): String = trim()
    .lowercase()
    .replace(Regex("[^a-z0-9]+"), "-")
    .trim('-')
    .ifBlank { "service-${System.currentTimeMillis()}" }
