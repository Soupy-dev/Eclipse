package dev.soupy.eclipse.android.ui.search

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import dev.soupy.eclipse.android.data.SearchRepository
import dev.soupy.eclipse.android.core.storage.SettingsStore
import dev.soupy.eclipse.android.feature.search.SearchScreenState

class AndroidSearchViewModel(
    private val repository: SearchRepository,
    private val settingsStore: SettingsStore,
) : ViewModel() {
    private val _state = MutableStateFlow(SearchScreenState())
    val state: StateFlow<SearchScreenState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            _state.update { it.copy(recentQueries = repository.recentQueries()) }
        }
        viewModelScope.launch {
            settingsStore.settings.collect { settings ->
                _state.update {
                    it.copy(
                        mediaColumnsPortrait = settings.mediaColumnsPortrait,
                        mediaColumnsLandscape = settings.mediaColumnsLandscape,
                    )
                }
            }
        }
    }

    fun updateQuery(query: String) {
        _state.update {
            it.copy(
                query = query,
                errorMessage = null,
                sections = if (query.isBlank()) emptyList() else it.sections,
            )
        }
    }

    fun selectRecentQuery(query: String) {
        _state.update { it.copy(query = query) }
        search()
    }

    fun search() {
        val query = _state.value.query.trim()
        if (query.isBlank()) {
            _state.update { it.copy(sections = emptyList(), errorMessage = null, isSearching = false) }
            return
        }

        viewModelScope.launch {
            _state.update { it.copy(isSearching = true, errorMessage = null) }
            repository.search(query)
                .onSuccess { result ->
                    _state.update {
                        it.copy(
                            isSearching = false,
                            sections = result.sections,
                            recentQueries = result.recentQueries,
                        )
                    }
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(
                            isSearching = false,
                            errorMessage = error.message ?: "Unknown search error.",
                            sections = emptyList(),
                        )
                    }
                }
        }
    }
}


