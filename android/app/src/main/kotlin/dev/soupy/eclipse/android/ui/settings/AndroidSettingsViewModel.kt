package dev.soupy.eclipse.android.ui.settings

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.soupy.eclipse.android.core.model.InAppPlayer
import dev.soupy.eclipse.android.core.storage.SettingsStore
import dev.soupy.eclipse.android.data.BackupRepository
import dev.soupy.eclipse.android.data.BackupStatusSnapshot
import dev.soupy.eclipse.android.data.CacheRepository
import dev.soupy.eclipse.android.data.CatalogRepository
import dev.soupy.eclipse.android.data.LoggerRepository
import dev.soupy.eclipse.android.feature.settings.CatalogSettingsRow
import dev.soupy.eclipse.android.feature.settings.LogSettingsRow
import dev.soupy.eclipse.android.feature.settings.SettingsScreenState
import dev.soupy.eclipse.android.feature.settings.StorageMetricRow
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

class AndroidSettingsViewModel(
    private val settingsStore: SettingsStore,
    private val backupRepository: BackupRepository,
    private val catalogRepository: CatalogRepository,
    private val cacheRepository: CacheRepository,
    private val loggerRepository: LoggerRepository,
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
                    showNextEpisodeButton = settings.showNextEpisodeButton,
                    nextEpisodeThreshold = settings.nextEpisodeThreshold,
                    inAppPlayer = settings.inAppPlayer,
                    aniSkipAutoSkip = settings.aniSkipAutoSkip,
                    skip85sEnabled = settings.skip85sEnabled,
                    readingMode = settings.readingMode,
                    readerFontSize = settings.readerFontSize,
                    readerLineSpacing = settings.readerLineSpacing,
                    readerMargin = settings.readerMargin,
                    readerTextAlignment = settings.readerTextAlignment,
                )
            }
        }
        refreshBackupStatus()
        refreshCatalogs()
        refreshStorage()
        refreshLogs()
    }

    fun setAutoModeEnabled(enabled: Boolean) {
        viewModelScope.launch {
            settingsStore.setAutoModeEnabled(enabled)
        }
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
