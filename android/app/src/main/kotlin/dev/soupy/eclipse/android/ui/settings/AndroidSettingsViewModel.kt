package dev.soupy.eclipse.android.ui.settings

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.soupy.eclipse.android.core.model.InAppPlayer
import dev.soupy.eclipse.android.core.model.SimilarityAlgorithm
import dev.soupy.eclipse.android.core.model.TrackerAccountSnapshot
import dev.soupy.eclipse.android.core.model.TrackerStateSnapshot
import dev.soupy.eclipse.android.core.network.AniListService
import dev.soupy.eclipse.android.core.network.NetworkResult
import dev.soupy.eclipse.android.core.storage.SettingsStore
import dev.soupy.eclipse.android.data.AniListLibraryImportDraft
import dev.soupy.eclipse.android.data.AniListMangaLibraryImportDraft
import dev.soupy.eclipse.android.data.BackupRepository
import dev.soupy.eclipse.android.data.BackupStatusSnapshot
import dev.soupy.eclipse.android.data.CacheRepository
import dev.soupy.eclipse.android.data.CatalogRepository
import dev.soupy.eclipse.android.data.LibraryRepository
import dev.soupy.eclipse.android.data.LoggerRepository
import dev.soupy.eclipse.android.data.MangaRepository
import dev.soupy.eclipse.android.data.TrackerAccountDraft
import dev.soupy.eclipse.android.data.TrackerRepository
import dev.soupy.eclipse.android.feature.settings.CatalogSettingsRow
import dev.soupy.eclipse.android.feature.settings.LogSettingsRow
import dev.soupy.eclipse.android.feature.settings.SettingsScreenState
import dev.soupy.eclipse.android.feature.settings.StorageMetricRow
import dev.soupy.eclipse.android.feature.settings.TrackerSettingsRow
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class AndroidSettingsViewModel(
    private val settingsStore: SettingsStore,
    private val backupRepository: BackupRepository,
    private val catalogRepository: CatalogRepository,
    private val cacheRepository: CacheRepository,
    private val loggerRepository: LoggerRepository,
    private val trackerRepository: TrackerRepository,
    private val libraryRepository: LibraryRepository,
    private val mangaRepository: MangaRepository,
    private val aniListService: AniListService,
) : ViewModel() {
    private val _state = MutableStateFlow(SettingsScreenState())
    val state: StateFlow<SettingsScreenState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            settingsStore.settings.collect { settings ->
                _state.value = _state.value.copy(
                    accentColor = settings.accentColor,
                    tmdbLanguage = settings.tmdbLanguage,
                    autoModeEnabled = settings.autoModeEnabled,
                    highQualityThreshold = settings.highQualityThreshold,
                    filterHorrorContent = settings.filterHorrorContent,
                    selectedSimilarityAlgorithm = settings.selectedSimilarityAlgorithm,
                    showNextEpisodeButton = settings.showNextEpisodeButton,
                    nextEpisodeThreshold = settings.nextEpisodeThreshold,
                    inAppPlayer = settings.inAppPlayer,
                    enableSubtitlesByDefault = settings.enableSubtitlesByDefault,
                    defaultSubtitleLanguage = settings.defaultSubtitleLanguage,
                    preferredAnimeAudioLanguage = settings.preferredAnimeAudioLanguage,
                    holdSpeedPlayer = settings.holdSpeedPlayer,
                    externalPlayer = settings.externalPlayer,
                    alwaysLandscape = settings.alwaysLandscape,
                    vlcHeaderProxyEnabled = settings.vlcHeaderProxyEnabled,
                    subtitleForegroundColor = settings.subtitleForegroundColor,
                    subtitleStrokeColor = settings.subtitleStrokeColor,
                    subtitleStrokeWidth = settings.subtitleStrokeWidth,
                    subtitleFontSize = settings.subtitleFontSize,
                    subtitleVerticalOffset = settings.subtitleVerticalOffset,
                    aniSkipAutoSkip = settings.aniSkipAutoSkip,
                    skip85sEnabled = settings.skip85sEnabled,
                    readingMode = settings.readingMode,
                    readerFontSize = settings.readerFontSize,
                    readerLineSpacing = settings.readerLineSpacing,
                    readerMargin = settings.readerMargin,
                    readerTextAlignment = settings.readerTextAlignment,
                    kanzenAutoUpdateModules = settings.kanzenAutoUpdateModules,
                    autoClearCacheEnabled = settings.autoClearCacheEnabled,
                    autoClearCacheThresholdMB = settings.autoClearCacheThresholdMB,
                )
            }
        }
        refreshBackupStatus()
        refreshCatalogs()
        refreshStorage()
        refreshLogs()
        refreshTrackers()
        runStartupCacheMaintenance()
    }

    fun setAutoModeEnabled(enabled: Boolean) {
        viewModelScope.launch {
            settingsStore.setAutoModeEnabled(enabled)
        }
    }

    fun setHighQualityThreshold(threshold: Double) {
        viewModelScope.launch {
            settingsStore.setHighQualityThreshold(threshold)
        }
    }

    fun setFilterHorrorContent(enabled: Boolean) {
        viewModelScope.launch {
            settingsStore.setFilterHorrorContent(enabled)
        }
    }

    fun setSimilarityAlgorithm(algorithm: SimilarityAlgorithm) {
        viewModelScope.launch {
            settingsStore.setSimilarityAlgorithm(algorithm)
        }
    }

    fun setAutoClearCacheEnabled(enabled: Boolean) {
        val current = _state.value
        updateAutoClearCache(
            enabled = enabled,
            thresholdMB = current.autoClearCacheThresholdMB,
        )
    }

    fun setAutoClearCacheThreshold(value: Double) {
        val current = _state.value
        updateAutoClearCache(
            enabled = current.autoClearCacheEnabled,
            thresholdMB = value,
        )
    }

    fun setShowNextEpisodeButton(enabled: Boolean) {
        val current = _state.value
        viewModelScope.launch {
            settingsStore.updatePlayback(
                inAppPlayer = current.inAppPlayer,
                showNextEpisodeButton = enabled,
                nextEpisodeThreshold = current.nextEpisodeThreshold,
            )
        }
    }

    fun setNextEpisodeThreshold(threshold: Int) {
        val current = _state.value
        viewModelScope.launch {
            settingsStore.updatePlayback(
                inAppPlayer = current.inAppPlayer,
                showNextEpisodeButton = current.showNextEpisodeButton,
                nextEpisodeThreshold = threshold.coerceIn(70, 98),
            )
        }
    }

    fun setInAppPlayer(player: InAppPlayer) {
        val current = _state.value
        viewModelScope.launch {
            settingsStore.updatePlayback(
                inAppPlayer = player,
                showNextEpisodeButton = current.showNextEpisodeButton,
                nextEpisodeThreshold = current.nextEpisodeThreshold,
            )
        }
    }

    fun setAniSkipAutoSkip(enabled: Boolean) {
        val current = _state.value
        viewModelScope.launch {
            settingsStore.updateSkipBehavior(
                aniSkipAutoSkip = enabled,
                skip85sEnabled = current.skip85sEnabled,
            )
        }
    }

    fun setSkip85sEnabled(enabled: Boolean) {
        val current = _state.value
        viewModelScope.launch {
            settingsStore.updateSkipBehavior(
                aniSkipAutoSkip = current.aniSkipAutoSkip,
                skip85sEnabled = enabled,
            )
        }
    }

    fun setEnableSubtitlesByDefault(enabled: Boolean) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = enabled,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setDefaultSubtitleLanguage(language: String) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            defaultSubtitleLanguage = language,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setPreferredAnimeAudioLanguage(language: String) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = language,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setHoldSpeed(value: Double) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            holdSpeedPlayer = value,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setExternalPlayer(value: String) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = value,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setAlwaysLandscape(enabled: Boolean) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = enabled,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setVlcHeaderProxyEnabled(enabled: Boolean) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = enabled,
        )
    }

    fun setSubtitleForegroundColor(value: String?) {
        val current = _state.value
        updateSubtitleStyle(
            foregroundColor = value,
            strokeColor = current.subtitleStrokeColor,
            strokeWidth = current.subtitleStrokeWidth,
            fontSize = current.subtitleFontSize,
            verticalOffset = current.subtitleVerticalOffset,
        )
    }

    fun setSubtitleStrokeColor(value: String?) {
        val current = _state.value
        updateSubtitleStyle(
            foregroundColor = current.subtitleForegroundColor,
            strokeColor = value,
            strokeWidth = current.subtitleStrokeWidth,
            fontSize = current.subtitleFontSize,
            verticalOffset = current.subtitleVerticalOffset,
        )
    }

    fun setSubtitleStrokeWidth(value: Double) {
        val current = _state.value
        updateSubtitleStyle(
            foregroundColor = current.subtitleForegroundColor,
            strokeColor = current.subtitleStrokeColor,
            strokeWidth = value,
            fontSize = current.subtitleFontSize,
            verticalOffset = current.subtitleVerticalOffset,
        )
    }

    fun setSubtitleFontSize(value: Double) {
        val current = _state.value
        updateSubtitleStyle(
            foregroundColor = current.subtitleForegroundColor,
            strokeColor = current.subtitleStrokeColor,
            strokeWidth = current.subtitleStrokeWidth,
            fontSize = value,
            verticalOffset = current.subtitleVerticalOffset,
        )
    }

    fun setSubtitleVerticalOffset(value: Double) {
        val current = _state.value
        updateSubtitleStyle(
            foregroundColor = current.subtitleForegroundColor,
            strokeColor = current.subtitleStrokeColor,
            strokeWidth = current.subtitleStrokeWidth,
            fontSize = current.subtitleFontSize,
            verticalOffset = value,
        )
    }

    private fun updatePlayerPreferences(
        enableSubtitlesByDefault: Boolean,
        defaultSubtitleLanguage: String,
        preferredAnimeAudioLanguage: String,
        holdSpeedPlayer: Double,
        externalPlayer: String,
        alwaysLandscape: Boolean,
        vlcHeaderProxyEnabled: Boolean,
    ) {
        viewModelScope.launch {
            settingsStore.updatePlayerPreferences(
                enableSubtitlesByDefault = enableSubtitlesByDefault,
                defaultSubtitleLanguage = defaultSubtitleLanguage,
                preferredAnimeAudioLanguage = preferredAnimeAudioLanguage,
                holdSpeedPlayer = holdSpeedPlayer,
                externalPlayer = externalPlayer,
                alwaysLandscape = alwaysLandscape,
                vlcHeaderProxyEnabled = vlcHeaderProxyEnabled,
            )
        }
    }

    private fun updateSubtitleStyle(
        foregroundColor: String?,
        strokeColor: String?,
        strokeWidth: Double,
        fontSize: Double,
        verticalOffset: Double,
    ) {
        viewModelScope.launch {
            settingsStore.updateSubtitleStyle(
                foregroundColor = foregroundColor,
                strokeColor = strokeColor,
                strokeWidth = strokeWidth,
                fontSize = fontSize,
                verticalOffset = verticalOffset,
            )
        }
    }

    fun setReadingMode(mode: Int) {
        val current = _state.value
        updateReader(
            readingMode = mode,
            readerFontSize = current.readerFontSize,
            readerLineSpacing = current.readerLineSpacing,
            readerMargin = current.readerMargin,
            readerTextAlignment = current.readerTextAlignment,
        )
    }

    fun setReaderFontSize(value: Double) {
        val current = _state.value
        updateReader(
            readingMode = current.readingMode,
            readerFontSize = value,
            readerLineSpacing = current.readerLineSpacing,
            readerMargin = current.readerMargin,
            readerTextAlignment = current.readerTextAlignment,
        )
    }

    fun setReaderLineSpacing(value: Double) {
        val current = _state.value
        updateReader(
            readingMode = current.readingMode,
            readerFontSize = current.readerFontSize,
            readerLineSpacing = value,
            readerMargin = current.readerMargin,
            readerTextAlignment = current.readerTextAlignment,
        )
    }

    fun setReaderMargin(value: Double) {
        val current = _state.value
        updateReader(
            readingMode = current.readingMode,
            readerFontSize = current.readerFontSize,
            readerLineSpacing = current.readerLineSpacing,
            readerMargin = value,
            readerTextAlignment = current.readerTextAlignment,
        )
    }

    fun setReaderTextAlignment(alignment: String) {
        val current = _state.value
        updateReader(
            readingMode = current.readingMode,
            readerFontSize = current.readerFontSize,
            readerLineSpacing = current.readerLineSpacing,
            readerMargin = current.readerMargin,
            readerTextAlignment = alignment,
        )
    }

    fun setKanzenAutoUpdateModules(enabled: Boolean) {
        viewModelScope.launch {
            settingsStore.setKanzenAutoUpdateModules(enabled)
        }
    }

    private fun updateReader(
        readingMode: Int,
        readerFontSize: Double,
        readerLineSpacing: Double,
        readerMargin: Double,
        readerTextAlignment: String,
    ) {
        viewModelScope.launch {
            settingsStore.updateReader(
                readingMode = readingMode,
                readerFontSize = readerFontSize,
                readerLineSpacing = readerLineSpacing,
                readerMargin = readerMargin,
                readerTextAlignment = readerTextAlignment,
            )
        }
    }

    private fun updateAutoClearCache(
        enabled: Boolean,
        thresholdMB: Double,
    ) {
        viewModelScope.launch {
            settingsStore.updateAutoClearCache(
                enabled = enabled,
                thresholdMB = thresholdMB,
            )
        }
    }

    fun exportBackup(uri: Uri) = runBackupMutation {
        backupRepository.exportToUri(uri)
    }

    fun importBackup(uri: Uri) = runBackupMutation {
        backupRepository.importFromUri(uri)
    }

    fun setCatalogEnabled(id: String, enabled: Boolean) {
        viewModelScope.launch {
            catalogRepository.setCatalogEnabled(id, enabled)
                .onSuccess { snapshot ->
                    _state.value = _state.value.copy(catalogs = snapshot.catalogs.toUiRows())
                }
        }
    }

    fun moveCatalogUp(id: String) {
        moveCatalog(id, direction = -1)
    }

    fun moveCatalogDown(id: String) {
        moveCatalog(id, direction = 1)
    }

    fun refreshStorage() {
        viewModelScope.launch {
            cacheRepository.loadMetrics()
                .onSuccess { metrics ->
                    _state.value = _state.value.copy(
                        storageMetrics = listOf(
                            StorageMetricRow("Cache", metrics.cacheBytes.toByteCountLabel()),
                            StorageMetricRow("Files", metrics.filesBytes.toByteCountLabel()),
                            StorageMetricRow("Downloads", metrics.downloadBytes.toByteCountLabel()),
                        ),
                        storageStatus = "Measured ${metrics.generatedAt.toReadableClock()}",
                    )
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        storageStatus = error.message ?: "Android could not inspect storage yet.",
                    )
                }
        }
    }

    fun clearCache() {
        viewModelScope.launch {
            loggerRepository.log("Storage", "User cleared app cache from Android settings.")
            cacheRepository.clearCache()
                .onSuccess { metrics ->
                    _state.value = _state.value.copy(
                        storageMetrics = listOf(
                            StorageMetricRow("Cache", metrics.cacheBytes.toByteCountLabel()),
                            StorageMetricRow("Files", metrics.filesBytes.toByteCountLabel()),
                            StorageMetricRow("Downloads", metrics.downloadBytes.toByteCountLabel()),
                        ),
                        storageStatus = "Cache cleared ${metrics.generatedAt.toReadableClock()}",
                    )
                    refreshLogs()
                }
                .onFailure { error ->
                    loggerRepository.log("Storage", error.message ?: "Cache clear failed.", level = "error")
                    _state.value = _state.value.copy(
                        storageStatus = error.message ?: "Android could not clear cache.",
                    )
                    refreshLogs()
                }
        }
    }

    private fun runStartupCacheMaintenance() {
        viewModelScope.launch {
            val settings = settingsStore.settings.first()
            if (!settings.autoClearCacheEnabled) return@launch

            val thresholdBytes = (settings.autoClearCacheThresholdMB * 1_000_000).toLong()
            val metrics = cacheRepository.loadMetrics().getOrNull() ?: return@launch
            if (metrics.cacheBytes <= thresholdBytes) return@launch

            loggerRepository.log(
                tag = "Storage",
                message = "Auto-clearing cache because ${metrics.cacheBytes.toByteCountLabel()} exceeds ${settings.autoClearCacheThresholdMB.toInt()} MB.",
            )
            cacheRepository.clearCache()
                .onSuccess { updated ->
                    _state.value = _state.value.copy(
                        storageMetrics = listOf(
                            StorageMetricRow("Cache", updated.cacheBytes.toByteCountLabel()),
                            StorageMetricRow("Files", updated.filesBytes.toByteCountLabel()),
                            StorageMetricRow("Downloads", updated.downloadBytes.toByteCountLabel()),
                        ),
                        storageStatus = "Auto-cleared cache ${updated.generatedAt.toReadableClock()}",
                    )
                    refreshLogs()
                }
                .onFailure { error ->
                    loggerRepository.log(
                        tag = "Storage",
                        message = error.message ?: "Auto-clear cache failed.",
                        level = "error",
                    )
                    refreshLogs()
                }
        }
    }

    fun refreshLogs() {
        viewModelScope.launch {
            loggerRepository.loadSnapshot()
                .onSuccess { snapshot ->
                    _state.value = _state.value.copy(
                        logRows = snapshot.entries.take(8).map { entry ->
                            LogSettingsRow(
                                id = entry.id,
                                timestamp = entry.timestamp.toReadableClock(),
                                tag = entry.tag,
                                message = entry.message,
                                level = entry.level,
                            )
                        },
                        loggerStatus = if (snapshot.entries.isEmpty()) {
                            "No Android logs captured yet."
                        } else {
                            "${snapshot.entries.size} persistent log entries"
                        },
                    )
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        loggerStatus = error.message ?: "Android could not read persistent logs.",
                    )
                }
        }
    }

    fun clearLogs() {
        viewModelScope.launch {
            loggerRepository.clear()
                .onSuccess {
                    _state.value = _state.value.copy(
                        logRows = emptyList(),
                        loggerStatus = "Logs cleared.",
                    )
                }
        }
    }

    fun saveTrackerAccount(
        service: String,
        username: String,
        token: String,
    ) {
        viewModelScope.launch {
            trackerRepository.saveManualAccount(
                TrackerAccountDraft(
                    service = service,
                    username = username,
                    accessToken = token,
                ),
            ).onSuccess { snapshot ->
                _state.value = _state.value.withTrackerState(
                    snapshot = snapshot,
                    status = "Saved ${service.trim().ifBlank { "tracker" }} account.",
                )
                loggerRepository.log("Trackers", "Saved manual tracker account for ${service.trim().ifBlank { "unknown provider" }}.")
                refreshLogs()
            }.onFailure { error ->
                _state.value = _state.value.copy(
                    trackerStatus = error.message ?: "Android could not save tracker account.",
                )
            }
        }
    }

    fun setTrackerSyncEnabled(enabled: Boolean) {
        viewModelScope.launch {
            trackerRepository.setSyncEnabled(enabled)
                .onSuccess { snapshot ->
                    _state.value = _state.value.withTrackerState(
                        snapshot = snapshot,
                        status = if (enabled) "Tracker sync enabled." else "Tracker sync disabled.",
                    )
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        trackerStatus = error.message ?: "Android could not update tracker sync.",
                    )
                }
        }
    }

    fun disconnectTracker(service: String) {
        viewModelScope.launch {
            trackerRepository.disconnect(service)
                .onSuccess { snapshot ->
                    _state.value = _state.value.withTrackerState(
                        snapshot = snapshot,
                        status = "Disconnected $service.",
                    )
                    loggerRepository.log("Trackers", "Disconnected tracker account for $service.")
                    refreshLogs()
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        trackerStatus = error.message ?: "Android could not disconnect tracker.",
                    )
                }
        }
    }

    fun syncTrackersNow() {
        viewModelScope.launch {
            _state.value = _state.value.copy(trackerStatus = "Syncing watched progress to trackers...")
            trackerRepository.syncStoredProgress()
                .onSuccess { summary ->
                    _state.value = _state.value.withTrackerState(
                        snapshot = summary.state,
                        status = summary.statusMessage,
                    )
                    loggerRepository.log("Trackers", summary.statusMessage)
                    refreshLogs()
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        trackerStatus = error.message ?: "Android tracker sync failed.",
                    )
                }
        }
    }

    fun importAniListLibrary(onImported: () -> Unit = {}) {
        viewModelScope.launch {
            val account = trackerRepository.loadSnapshot()
                .getOrNull()
                ?.aniListAccount()
            if (account == null) {
                _state.value = _state.value.copy(
                    trackerStatus = "Connect an AniList tracker account before importing your AniList library.",
                )
                return@launch
            }

            _state.value = _state.value.copy(trackerStatus = "Importing AniList anime library...")
            when (
                val result = aniListService.fetchAnimeLibrary(
                    accessToken = account.accessToken,
                    username = account.username.takeIf(String::isNotBlank),
                )
            ) {
                is NetworkResult.Success -> {
                    libraryRepository.importAniListAnime(
                        result.value.map { entry ->
                            AniListLibraryImportDraft(
                                media = entry.media,
                                status = entry.status,
                                progress = entry.progress,
                                score = entry.score,
                                updatedAtEpochSeconds = entry.updatedAtEpochSeconds,
                            )
                        },
                    ).onSuccess { summary ->
                        _state.value = _state.value.copy(
                            trackerStatus = "Imported ${summary.importedItems} AniList anime item${if (summary.importedItems == 1) "" else "s"} into Library, including ${summary.importedContinueWatching} resume entr${if (summary.importedContinueWatching == 1) "y" else "ies"}.",
                        )
                        loggerRepository.log("Trackers", "Imported AniList anime library into Android Library.")
                        refreshLogs()
                        onImported()
                    }.onFailure { error ->
                        _state.value = _state.value.copy(
                            trackerStatus = error.message ?: "Android could not import AniList library.",
                        )
                    }
                }
                is NetworkResult.Failure -> {
                    _state.value = _state.value.copy(
                        trackerStatus = result.toStatusMessage("AniList library import failed."),
                    )
                }
            }
        }
    }

    fun importAniListMangaLibrary(onImported: () -> Unit = {}) {
        viewModelScope.launch {
            val account = trackerRepository.loadSnapshot()
                .getOrNull()
                ?.aniListAccount()
            if (account == null) {
                _state.value = _state.value.copy(
                    trackerStatus = "Connect an AniList tracker account before importing your manga library.",
                )
                return@launch
            }

            _state.value = _state.value.copy(trackerStatus = "Importing AniList manga library...")
            when (
                val result = aniListService.fetchMangaLibrary(
                    accessToken = account.accessToken,
                    username = account.username.takeIf(String::isNotBlank),
                )
            ) {
                is NetworkResult.Success -> {
                    mangaRepository.importAniListManga(
                        result.value.map { entry ->
                            AniListMangaLibraryImportDraft(
                                media = entry.media,
                                status = entry.status,
                                progress = entry.progress,
                                progressVolumes = entry.progressVolumes,
                                score = entry.score,
                                updatedAtEpochSeconds = entry.updatedAtEpochSeconds,
                            )
                        },
                    ).onSuccess { summary ->
                        val progressLabel = if (summary.importedProgress == 1) {
                            "progress entry"
                        } else {
                            "progress entries"
                        }
                        _state.value = _state.value.copy(
                            trackerStatus = "Imported ${summary.importedItems} AniList manga item${if (summary.importedItems == 1) "" else "s"} into Manga/Novel, including ${summary.importedProgress} $progressLabel and ${summary.importedNovels} novel item${if (summary.importedNovels == 1) "" else "s"}.",
                        )
                        loggerRepository.log("Trackers", "Imported AniList manga library into Android Manga/Novel.")
                        refreshLogs()
                        onImported()
                    }.onFailure { error ->
                        _state.value = _state.value.copy(
                            trackerStatus = error.message ?: "Android could not import AniList manga library.",
                        )
                    }
                }
                is NetworkResult.Failure -> {
                    _state.value = _state.value.copy(
                        trackerStatus = result.toStatusMessage("AniList manga import failed."),
                    )
                }
            }
        }
    }

    private fun moveCatalog(id: String, direction: Int) {
        viewModelScope.launch {
            catalogRepository.moveCatalog(id, direction)
                .onSuccess { snapshot ->
                    _state.value = _state.value.copy(catalogs = snapshot.catalogs.toUiRows())
                }
        }
    }

    private fun refreshBackupStatus() {
        viewModelScope.launch {
            backupRepository.loadStatus()
                .onSuccess(::applyBackupStatus)
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        hasLocalBackup = false,
                        backupStatusHeadline = "Backup status unavailable",
                        backupStatusMessage = error.message ?: "Android couldn't inspect the staged backup yet.",
                    )
                }
        }
    }

    private fun refreshCatalogs() {
        viewModelScope.launch {
            catalogRepository.loadSnapshot()
                .onSuccess { snapshot ->
                    _state.value = _state.value.copy(catalogs = snapshot.catalogs.toUiRows())
                }
        }
    }

    private fun refreshTrackers() {
        viewModelScope.launch {
            trackerRepository.loadSnapshot()
                .onSuccess { snapshot ->
                    _state.value = _state.value.withTrackerState(snapshot)
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        trackerStatus = error.message ?: "Android could not load tracker state.",
                    )
                }
        }
    }

    private fun runBackupMutation(
        action: suspend () -> Result<BackupStatusSnapshot>,
    ) {
        viewModelScope.launch {
            _state.value = _state.value.copy(isBackupBusy = true)
            action()
                .onSuccess { status ->
                    _state.value = _state.value.copy(isBackupBusy = false)
                    applyBackupStatus(status)
                    refreshCatalogs()
                    refreshTrackers()
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        isBackupBusy = false,
                        backupStatusHeadline = "Backup failed",
                        backupStatusMessage = error.message ?: "Android couldn't finish the backup operation.",
                    )
                }
        }
    }

    private fun applyBackupStatus(status: BackupStatusSnapshot) {
        _state.value = _state.value.copy(
            hasLocalBackup = status.hasLocalBackup,
            backupStatusHeadline = status.headline,
            backupStatusMessage = status.supportingText,
        )
    }
}

private fun List<dev.soupy.eclipse.android.core.model.BackupCatalog>.toUiRows(): List<CatalogSettingsRow> =
    sortedBy { it.order }.map { catalog ->
        CatalogSettingsRow(
            id = catalog.id,
            name = catalog.displayName,
            source = catalog.resolvedSource,
            displayStyle = catalog.displayStyle,
            enabled = catalog.isEnabled,
            order = catalog.order,
        )
    }

private fun SettingsScreenState.withTrackerState(
    snapshot: dev.soupy.eclipse.android.core.model.TrackerStateSnapshot,
    status: String? = null,
): SettingsScreenState {
    val rows = snapshot.accounts.map { account ->
        TrackerSettingsRow(
            service = account.service,
            username = account.username,
            tokenPreview = account.accessToken.toTokenPreview(),
            isConnected = account.isConnected,
        )
    }.ifEmpty {
        val provider = snapshot.provider
        val token = snapshot.accessToken
        if (!provider.isNullOrBlank() && !token.isNullOrBlank()) {
            listOf(
                TrackerSettingsRow(
                    service = provider,
                    username = snapshot.userName.orEmpty(),
                    tokenPreview = token.toTokenPreview(),
                    isConnected = true,
                ),
            )
        } else {
            emptyList()
        }
    }
    val trackerStatus = status ?: when {
        rows.isEmpty() -> "No tracker accounts connected yet."
        snapshot.lastSyncDate != null -> "${rows.size} tracker account${if (rows.size == 1) "" else "s"} - last sync ${snapshot.lastSyncDate}"
        else -> "${rows.size} tracker account${if (rows.size == 1) "" else "s"} connected."
    }
    return copy(
        trackerSyncEnabled = snapshot.syncEnabled,
        trackerRows = rows,
        trackerStatus = trackerStatus,
    )
}

private fun TrackerStateSnapshot.aniListAccount(): TrackerAccountSnapshot? {
    val modern = accounts.firstOrNull { account ->
        account.isConnected &&
            account.accessToken.isNotBlank() &&
            account.service.equals("AniList", ignoreCase = true)
    }
    if (modern != null) return modern

    val provider = provider ?: return null
    val token = accessToken ?: return null
    return if (provider.equals("AniList", ignoreCase = true) && token.isNotBlank()) {
        TrackerAccountSnapshot(
            service = provider,
            username = userName.orEmpty(),
            accessToken = token,
            refreshToken = refreshToken,
            isConnected = true,
        )
    } else {
        null
    }
}

private fun NetworkResult.Failure.toStatusMessage(prefix: String): String = when (this) {
    is NetworkResult.Failure.Http -> "$prefix HTTP $code${body?.takeIf { it.isNotBlank() }?.let { ": $it" }.orEmpty()}"
    is NetworkResult.Failure.Connectivity -> "$prefix ${throwable.message ?: "network unavailable"}"
    is NetworkResult.Failure.Serialization -> "$prefix ${throwable.message ?: "unexpected AniList response"}"
}

private fun String.toTokenPreview(): String =
    when {
        isBlank() -> "No token"
        length <= 8 -> "token saved"
        else -> "${take(4)}...${takeLast(4)}"
    }

private fun Long.toByteCountLabel(): String {
    val units = listOf("B", "KB", "MB", "GB")
    var value = toDouble().coerceAtLeast(0.0)
    var unitIndex = 0
    while (value >= 1024.0 && unitIndex < units.lastIndex) {
        value /= 1024.0
        unitIndex += 1
    }
    return if (unitIndex == 0) {
        "${value.toLong()} ${units[unitIndex]}"
    } else {
        "%.1f %s".format(value, units[unitIndex])
    }
}

private fun Long.toReadableClock(): String =
    runCatching {
        Instant.ofEpochMilli(this)
            .atZone(ZoneId.systemDefault())
            .format(DateTimeFormatter.ofPattern("MMM d, h:mm a"))
    }.getOrDefault("unknown time")
