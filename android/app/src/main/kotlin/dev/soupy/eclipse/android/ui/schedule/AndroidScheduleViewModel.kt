package dev.soupy.eclipse.android.ui.schedule

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import dev.soupy.eclipse.android.data.ScheduleRepository
import dev.soupy.eclipse.android.feature.schedule.ScheduleScreenState

class AndroidScheduleViewModel(
    private val repository: ScheduleRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(ScheduleScreenState(isLoading = true))
    val state: StateFlow<ScheduleScreenState> = _state.asStateFlow()

    init {
        refresh()
    }

    fun refresh(localTimeZone: Boolean = true) {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, errorMessage = null) }
            repository.loadSchedule(localTimeZone = localTimeZone)
                .onSuccess { sections ->
                    _state.value = ScheduleScreenState(
                        isLoading = false,
                        showLocalScheduleTime = localTimeZone,
                        useClassicScheduleUI = _state.value.useClassicScheduleUI,
                        days = sections,
                    )
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(
                            isLoading = false,
                            errorMessage = error.message ?: "Unknown schedule error.",
                        )
                    }
                }
        }
    }
}


