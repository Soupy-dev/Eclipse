package dev.soupy.eclipse.android.ui.settings

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.soupy.eclipse.android.core.model.InAppPlayer
import dev.soupy.eclipse.android.core.storage.SettingsStore
import dev.soupy.eclipse.android.data.BackupRepository
import dev.soupy.eclipse.android.data.BackupStatusSnapshot
import dev.soupy.eclipse.android.data.CatalogRepository
import dev.soupy.eclipse.android.feature.settings.CatalogSettingsRow
import dev.soupy.eclipse.android.feature.settings.SettingsScreenState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

class AndroidSettingsViewModel(
    private val settingsStore: SettingsStore,
    private val backupRepository: BackupRepository,
    private val catalogRepository: CatalogRepository,
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
                )
            }
        }
        refreshBackupStatus()
        refreshCatalogs()
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
