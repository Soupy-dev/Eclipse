package dev.soupy.eclipse.android.ui.services

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.soupy.eclipse.android.core.storage.AppSettings
import dev.soupy.eclipse.android.core.storage.SettingsStore
import dev.soupy.eclipse.android.data.ServiceDraft
import dev.soupy.eclipse.android.data.ServiceSourceRecord
import dev.soupy.eclipse.android.data.ServicesRepository
import dev.soupy.eclipse.android.data.ServicesSnapshot
import dev.soupy.eclipse.android.data.StremioAddonRecord
import dev.soupy.eclipse.android.feature.services.ServiceSourceRow
import dev.soupy.eclipse.android.feature.services.ServicesScreenState
import dev.soupy.eclipse.android.feature.services.StremioAddonRow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

class AndroidServicesViewModel(
    private val repository: ServicesRepository,
    private val settingsStore: SettingsStore,
) : ViewModel() {
    private val _state = MutableStateFlow(ServicesScreenState())
    val state: StateFlow<ServicesScreenState> = _state.asStateFlow()

    private val isMutating = MutableStateFlow(false)
    private val errorMessage = MutableStateFlow<String?>(null)
    private val noticeMessage = MutableStateFlow<String?>(null)

    init {
        viewModelScope.launch {
            combine(
                repository.observeSnapshot(),
                settingsStore.settings,
                isMutating,
                errorMessage,
                noticeMessage,
            ) { snapshot, settings, isMutating, errorMessage, noticeMessage ->
                snapshot.toUiState(
                    settings = settings,
                    isMutating = isMutating,
                    errorMessage = errorMessage,
                    noticeMessage = noticeMessage,
                )
            }.collect { state ->
                _state.value = state
            }
        }
    }

    fun setAutoModeEnabled(enabled: Boolean) {
        viewModelScope.launch {
            settingsStore.setAutoModeEnabled(enabled)
        }
    }

    fun setAutoModeSourceEnabled(sourceId: String, enabled: Boolean) {
        viewModelScope.launch {
            settingsStore.setAutoModeSourceEnabled(sourceId, enabled)
        }
    }

    fun addService(
        name: String,
        scriptUrl: String,
        manifestUrl: String?,
    ) = mutate(
        successMessage = "Saved service '$name' on Android.",
    ) {
        repository.addService(
            ServiceDraft(
                name = name,
                scriptUrl = scriptUrl,
                manifestUrl = manifestUrl,
            ),
        ).getOrThrow()
    }

    fun importAddon(transportUrl: String) = mutate(
        successMessage = "Imported Stremio addon manifest.",
    ) {
        repository.importStremioAddon(transportUrl).getOrThrow()
    }

    fun setServiceEnabled(
        id: String,
        autoModeId: String,
        enabled: Boolean,
    ) = mutate(
        successMessage = if (enabled) "Service enabled." else "Service disabled.",
    ) {
        repository.setServiceEnabled(id, enabled).getOrThrow()
        if (!enabled) settingsStore.removeAutoModeSource(autoModeId)
    }

    fun setServiceConfiguration(
        id: String,
        configurationJson: String?,
    ) = mutate(
        successMessage = "Saved provider configuration.",
    ) {
        repository.setServiceConfiguration(id, configurationJson).getOrThrow()
    }

    fun setAddonEnabled(
        transportUrl: String,
        autoModeId: String,
        enabled: Boolean,
    ) = mutate(
        successMessage = if (enabled) "Addon enabled." else "Addon disabled.",
    ) {
        repository.setAddonEnabled(transportUrl, enabled).getOrThrow()
        if (!enabled) settingsStore.removeAutoModeSource(autoModeId)
    }

    fun moveServiceUp(id: String) = moveService(id, ServicesRepository.MoveDirection.UP)

    fun moveServiceDown(id: String) = moveService(id, ServicesRepository.MoveDirection.DOWN)

    fun moveAddonUp(transportUrl: String) = moveAddon(transportUrl, ServicesRepository.MoveDirection.UP)

    fun moveAddonDown(transportUrl: String) = moveAddon(transportUrl, ServicesRepository.MoveDirection.DOWN)

    fun refreshAddon(transportUrl: String) = mutate(
        successMessage = "Refreshed Stremio addon manifest.",
    ) {
        repository.refreshStremioAddon(transportUrl).getOrThrow()
    }

    fun refreshAllAddons() = mutate(
        successMessage = "Updated addon manifests.",
    ) {
        val summary = repository.refreshAllAddons().getOrThrow()
        noticeMessage.value = summary.statusMessage
    }

    fun removeService(
        id: String,
        autoModeId: String,
    ) = mutate(
        successMessage = "Removed service from Android storage.",
    ) {
        repository.removeService(id).getOrThrow()
        settingsStore.removeAutoModeSource(autoModeId)
    }

    fun removeAddon(
        transportUrl: String,
        autoModeId: String,
    ) = mutate(
        successMessage = "Removed addon from Android storage.",
    ) {
        repository.removeAddon(transportUrl).getOrThrow()
        settingsStore.removeAutoModeSource(autoModeId)
    }

    private fun moveService(
        id: String,
        direction: ServicesRepository.MoveDirection,
    ) = mutate(
        successMessage = "Updated service order.",
    ) {
        repository.moveService(id, direction).getOrThrow()
    }

    private fun moveAddon(
        transportUrl: String,
        direction: ServicesRepository.MoveDirection,
    ) = mutate(
        successMessage = "Updated addon order.",
    ) {
        repository.moveAddon(transportUrl, direction).getOrThrow()
    }

    private fun mutate(
        successMessage: String,
        block: suspend () -> Unit,
    ) {
        viewModelScope.launch {
            isMutating.value = true
            errorMessage.value = null
            noticeMessage.value = null

            runCatching { block() }
                .onSuccess {
                    if (noticeMessage.value == null) {
                        noticeMessage.value = successMessage
                    }
                }
                .onFailure { errorMessage.value = it.message ?: "Unknown services error." }

            isMutating.value = false
        }
    }
}

private fun ServicesSnapshot.toUiState(
    settings: AppSettings,
    isMutating: Boolean,
    errorMessage: String?,
    noticeMessage: String?,
): ServicesScreenState {
    val selectedSourceIds = settings.autoModeSourceIds
    val serviceRows = services.map { it.toUiRow(selectedSourceIds) }
    val addonRows = stremioAddons.map { it.toUiRow(selectedSourceIds) }
    val autoModeSelectedCount = serviceRows.count { it.enabled && it.selectedInAutoMode } +
        addonRows.count { it.enabled && it.selectedInAutoMode }

    return ServicesScreenState(
        isLoading = false,
        isMutating = isMutating,
        errorMessage = errorMessage,
        noticeMessage = noticeMessage,
        autoModeEnabled = settings.autoModeEnabled,
        autoModeSelectedCount = autoModeSelectedCount,
        serviceCount = serviceRows.size,
        addonCount = addonRows.size,
        services = serviceRows,
        stremioAddons = addonRows,
    )
}

private fun ServiceSourceRecord.toUiRow(selectedSourceIds: Set<String>): ServiceSourceRow = ServiceSourceRow(
    id = id,
    autoModeId = autoModeId,
    name = name,
    subtitle = subtitle,
    configurationJson = configurationJson,
    configurationSummary = configurationSummary,
    enabled = enabled,
    selectedInAutoMode = autoModeId in selectedSourceIds,
)

private fun StremioAddonRecord.toUiRow(selectedSourceIds: Set<String>): StremioAddonRow = StremioAddonRow(
    transportUrl = transportUrl,
    autoModeId = autoModeId,
    name = name,
    subtitle = subtitle,
    enabled = enabled,
    selectedInAutoMode = autoModeId in selectedSourceIds,
    configured = configured,
    configurable = configurable,
    configurationRequired = configurationRequired,
    configurationUrl = configurationUrl,
    types = types,
    resources = resources,
    idPrefixes = idPrefixes,
    catalogCount = catalogCount,
)
