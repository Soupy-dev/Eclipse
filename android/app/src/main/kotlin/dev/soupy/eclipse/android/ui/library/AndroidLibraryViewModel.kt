package dev.soupy.eclipse.android.ui.library

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import dev.soupy.eclipse.android.data.ContinueWatchingDraft
import dev.soupy.eclipse.android.data.LibraryItemDraft
import dev.soupy.eclipse.android.data.LibraryRepository
import dev.soupy.eclipse.android.core.model.LibrarySnapshot
import dev.soupy.eclipse.android.feature.library.ContinueWatchingRow
import dev.soupy.eclipse.android.feature.library.LibraryCollectionRow
import dev.soupy.eclipse.android.feature.library.LibraryMetric
import dev.soupy.eclipse.android.feature.library.LibrarySavedItemRow
import dev.soupy.eclipse.android.feature.library.LibraryScreenState

class AndroidLibraryViewModel(
    private val repository: LibraryRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(LibraryScreenState())
    val state: StateFlow<LibraryScreenState> = _state.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, errorMessage = null) }
            repository.loadSnapshot()
                .onSuccess { snapshot ->
                    _state.value = snapshot.toUiState()
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(
                            isLoading = false,
                            errorMessage = error.message ?: "Unknown library error.",
                        )
                    }
                }
        }
    }

    fun toggleSaved(draft: LibraryItemDraft) {
        viewModelScope.launch {
            repository.toggleSaved(draft)
                .onSuccess { snapshot -> _state.value = snapshot.toUiState() }
        }
    }

    fun recordContinueWatching(draft: ContinueWatchingDraft) {
        syncContinueWatching(draft)
    }

    fun syncContinueWatching(draft: ContinueWatchingDraft) {
        viewModelScope.launch {
            repository.syncContinueWatching(draft)
                .onSuccess { snapshot -> _state.value = snapshot.toUiState() }
        }
    }

    fun removeSaved(id: String) {
        viewModelScope.launch {
            repository.removeSaved(id)
                .onSuccess { snapshot -> _state.value = snapshot.toUiState() }
        }
    }

    fun removeContinueWatching(id: String) {
        viewModelScope.launch {
            repository.removeContinueWatching(id)
                .onSuccess { snapshot -> _state.value = snapshot.toUiState() }
        }
    }

    fun createCollection(name: String) {
        viewModelScope.launch {
            repository.createCollection(name)
                .onSuccess { snapshot -> _state.value = snapshot.toUiState() }
                .onFailure { error ->
                    _state.update { it.copy(errorMessage = error.message ?: "Could not create collection.") }
                }
        }
    }

    fun deleteCollection(id: String) {
        viewModelScope.launch {
            repository.deleteCollection(id)
                .onSuccess { snapshot -> _state.value = snapshot.toUiState() }
                .onFailure { error ->
                    _state.update { it.copy(errorMessage = error.message ?: "Could not delete collection.") }
                }
        }
    }

    fun addToCollection(collectionId: String, itemId: String) {
        viewModelScope.launch {
            repository.addToCollection(collectionId, itemId)
                .onSuccess { snapshot -> _state.value = snapshot.toUiState() }
                .onFailure { error ->
                    _state.update { it.copy(errorMessage = error.message ?: "Could not add to collection.") }
                }
        }
    }

    fun saveToCollection(collectionId: String, draft: LibraryItemDraft) {
        viewModelScope.launch {
            repository.saveToCollection(collectionId, draft)
                .onSuccess { snapshot -> _state.value = snapshot.toUiState() }
                .onFailure { error ->
                    _state.update { it.copy(errorMessage = error.message ?: "Could not add to collection.") }
                }
        }
    }

    fun removeFromCollection(collectionId: String, itemId: String) {
        viewModelScope.launch {
            repository.removeFromCollection(collectionId, itemId)
                .onSuccess { snapshot -> _state.value = snapshot.toUiState() }
                .onFailure { error ->
                    _state.update { it.copy(errorMessage = error.message ?: "Could not remove from collection.") }
                }
        }
    }
}

private fun LibrarySnapshot.toUiState(): LibraryScreenState {
    val savedRowsById = savedItems.associate { record ->
        record.id to LibrarySavedItemRow(
            id = record.id,
            title = record.title,
            subtitle = record.subtitle,
            overview = record.overview,
            imageUrl = record.imageUrl,
            backdropUrl = record.backdropUrl,
            mediaLabel = record.mediaLabel,
            detailTarget = record.detailTarget,
        )
    }
    val heroTitle = continueWatching.firstOrNull()?.title
        ?: savedItems.firstOrNull()?.title
        ?: "Library"
    val heroImageUrl = continueWatching.firstOrNull()?.backdropUrl
        ?: continueWatching.firstOrNull()?.imageUrl
        ?: savedItems.firstOrNull()?.backdropUrl
        ?: savedItems.firstOrNull()?.imageUrl
    val heroSupportingText = when {
        continueWatching.isNotEmpty() ->
            "Playback updates resume state automatically for supported streams."
        savedItems.isNotEmpty() ->
            "Saved titles stay available across app restarts."
        else ->
            "Saved titles, collections, and continue watching will appear here."
    }

    return LibraryScreenState(
        isLoading = false,
        heroTitle = heroTitle,
        heroSubtitle = when {
            continueWatching.isNotEmpty() -> "Continue Watching"
            savedItems.isNotEmpty() -> "Saved titles"
            else -> "Saved media"
        },
        heroImageUrl = heroImageUrl,
        heroSupportingText = heroSupportingText,
        metrics = listOf(
            LibraryMetric(
                label = "Saved",
                value = savedItems.size.toString(),
                supportingText = "Pinned titles that stay outside resume state.",
            ),
            LibraryMetric(
                label = "Collections",
                value = collections.size.toString(),
                supportingText = "Bookmarks and custom media groups restored through Luna backups.",
            ),
            LibraryMetric(
                label = "Resume",
                value = continueWatching.size.toString(),
                supportingText = "Playback callbacks now keep supported sessions in sync automatically.",
            ),
        ),
        continueWatching = continueWatching.map { record ->
            ContinueWatchingRow(
                id = record.id,
                title = record.title,
                subtitle = record.subtitle,
                imageUrl = record.imageUrl,
                backdropUrl = record.backdropUrl,
                progressPercent = record.progressPercent,
                progressLabel = record.progressLabel,
                detailTarget = record.detailTarget,
            )
        },
        savedItems = savedRowsById.values.toList(),
        collections = collections.map { collection ->
            LibraryCollectionRow(
                id = collection.id,
                name = collection.name,
                description = collection.description,
                itemCount = collection.itemIds.size,
                items = collection.itemIds.mapNotNull(savedRowsById::get),
                canDelete = !collection.name.equals("Bookmarks", ignoreCase = true),
            )
        },
    )
}
