package dev.soupy.eclipse.android.ui.manga

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.soupy.eclipse.android.core.model.MangaProgress
import dev.soupy.eclipse.android.data.KanzenModuleDraft
import dev.soupy.eclipse.android.data.MangaCatalogItemSnapshot
import dev.soupy.eclipse.android.data.MangaLibraryItemDraft
import dev.soupy.eclipse.android.data.MangaOverviewSnapshot
import dev.soupy.eclipse.android.data.MangaRepository
import dev.soupy.eclipse.android.feature.manga.MangaCatalogItemRow
import dev.soupy.eclipse.android.feature.manga.MangaCatalogSectionRow
import dev.soupy.eclipse.android.feature.manga.MangaCollectionRow
import dev.soupy.eclipse.android.feature.manga.MangaModuleRow
import dev.soupy.eclipse.android.feature.manga.MangaProgressRow
import dev.soupy.eclipse.android.feature.manga.MangaScreenState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class AndroidMangaViewModel(
    private val repository: MangaRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(MangaScreenState(isLoading = true))
    val state: StateFlow<MangaScreenState> = _state.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, errorMessage = null)
            repository.loadOverview()
                .onSuccess(::applyOverview)
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        isLoading = false,
                        errorMessage = error.message ?: "Manga library data could not be loaded.",
                    )
                }
        }
    }

    fun updateQuery(query: String) {
        _state.update { it.copy(query = query, errorMessage = null) }
    }

    fun search() {
        val query = _state.value.query.trim()
        if (query.isBlank()) {
            _state.update { it.copy(searchResults = emptyList(), isSearching = false, errorMessage = null) }
            return
        }

        viewModelScope.launch {
            _state.update { it.copy(isSearching = true, errorMessage = null, noticeMessage = null) }
            repository.searchManga(query)
                .onSuccess { results ->
                    _state.update {
                        it.copy(
                            isSearching = false,
                            searchResults = results.map(MangaCatalogItemSnapshot::toRow),
                            noticeMessage = if (results.isEmpty()) "No AniList manga results for \"$query\"." else null,
                        )
                    }
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(
                            isSearching = false,
                            errorMessage = error.message ?: "Manga search could not finish.",
                        )
                    }
                }
        }
    }

    fun saveItem(itemId: String) {
        val item = _state.value.findCatalogItem(itemId) ?: return
        viewModelScope.launch {
            repository.saveToLibrary(item.toDraft())
                .onSuccess {
                    reloadAfterLibraryMutation(
                        notice = "Saved ${item.title} to your manga library.",
                        aniListId = item.aniListId,
                        isSaved = true,
                    )
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not save manga.")
                    }
                }
        }
    }

    fun removeItem(aniListId: Int) {
        viewModelScope.launch {
            repository.removeFromLibrary(aniListId)
                .onSuccess {
                    reloadAfterLibraryMutation(
                        notice = "Removed manga from your library.",
                        aniListId = aniListId,
                        isSaved = false,
                    )
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not remove manga.")
                    }
                }
        }
    }

    fun readNextChapter(aniListId: Int) {
        viewModelScope.launch {
            repository.markNextChapterRead(aniListId)
                .onSuccess {
                    reloadAfterModuleMutation("Marked the next manga chapter as read.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update reading progress.")
                    }
                }
        }
    }

    fun unreadLastChapter(aniListId: Int) {
        viewModelScope.launch {
            repository.markPreviousChapterUnread(aniListId)
                .onSuccess {
                    reloadAfterModuleMutation("Marked the latest manga chapter unread.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update reading progress.")
                    }
                }
        }
    }

    fun toggleFavorite(aniListId: Int) {
        viewModelScope.launch {
            repository.toggleFavorite(aniListId)
                .onSuccess {
                    reloadAfterModuleMutation("Updated manga favorites.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update favorite manga.")
                    }
                }
        }
    }

    fun clearReadingProgress(progressId: String) {
        viewModelScope.launch {
            repository.clearReadingProgress(progressId)
                .onSuccess {
                    reloadAfterModuleMutation("Reset reading progress.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not reset reading progress.")
                    }
                }
        }
    }

    fun addModule(moduleUrl: String) {
        viewModelScope.launch {
            repository.addModule(
                KanzenModuleDraft(
                    moduleUrl = moduleUrl,
                    isNovel = false,
                ),
            ).onSuccess {
                reloadAfterModuleMutation("Saved Kanzen manga module.")
            }.onFailure { error ->
                _state.update {
                    it.copy(errorMessage = error.message ?: "Could not add Kanzen module.")
                }
            }
        }
    }

    fun setModuleActive(
        moduleId: String,
        active: Boolean,
    ) {
        viewModelScope.launch {
            repository.setModuleActive(moduleId, active)
                .onSuccess {
                    reloadAfterModuleMutation(if (active) "Module enabled." else "Module disabled.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update Kanzen module.")
                    }
                }
        }
    }

    fun removeModule(moduleId: String) {
        viewModelScope.launch {
            repository.removeModule(moduleId)
                .onSuccess {
                    reloadAfterModuleMutation("Removed Kanzen module.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not remove Kanzen module.")
                    }
                }
        }
    }

    fun updateModule(moduleId: String) {
        viewModelScope.launch {
            repository.updateModule(moduleId)
                .onSuccess {
                    reloadAfterModuleMutation("Updated Kanzen module metadata and script.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update Kanzen module.")
                    }
                }
        }
    }

    fun updateAllModules() {
        viewModelScope.launch {
            repository.updateModules(isNovel = false)
                .onSuccess { summary ->
                    reloadAfterModuleMutation(summary.toNotice("Kanzen manga modules"))
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update Kanzen modules.")
                    }
                }
        }
    }

    private suspend fun reloadAfterLibraryMutation(
        notice: String,
        aniListId: Int,
        isSaved: Boolean,
    ) {
        _state.update { it.withSavedFlag(aniListId, isSaved).copy(noticeMessage = notice) }
        repository.loadOverview()
            .onSuccess { applyOverview(it, notice) }
            .onFailure { error ->
                _state.update {
                    it.copy(errorMessage = error.message ?: "Manga library changed, but refresh failed.")
                }
            }
    }

    private suspend fun reloadAfterModuleMutation(notice: String) {
        _state.update { it.copy(noticeMessage = notice, errorMessage = null) }
        repository.loadOverview()
            .onSuccess { applyOverview(it, notice) }
            .onFailure { error ->
                _state.update {
                    it.copy(errorMessage = error.message ?: "Kanzen modules changed, but refresh failed.")
                }
            }
    }

    private fun applyOverview(
        snapshot: MangaOverviewSnapshot,
        notice: String? = null,
    ) {
        val previous = _state.value
        val savedIds = snapshot.collections
            .flatMap { collection -> collection.items }
            .map { item -> item.aniListId }
            .toSet()
        _state.value = MangaScreenState(
            isLoading = false,
            query = previous.query,
            isSearching = false,
            noticeMessage = notice ?: previous.noticeMessage,
            savedCount = snapshot.savedCount,
            readChapterCount = snapshot.readChapterCount,
            novelCount = snapshot.novelCount,
            importedFromBackup = snapshot.importedFromBackup,
            searchResults = previous.searchResults.map { row ->
                row.copy(isSaved = row.aniListId in savedIds)
            },
            savedItems = snapshot.collections
                .flatMap { collection -> collection.items }
                .distinctBy { item -> item.aniListId }
                .map { item ->
                    val progress = snapshot.progressByAniListId[item.aniListId]
                    val readCount = progress?.readChapterNumbers?.size ?: 0
                    MangaCatalogItemRow(
                        id = "saved-manga-${item.aniListId}",
                        aniListId = item.aniListId,
                        title = item.title,
                        subtitle = listOfNotNull(
                            item.format?.replace('_', ' '),
                            item.totalChapters?.let { "$it chapters" },
                            item.dateAdded?.take(10)?.let { "saved $it" },
                        ).joinToString(" - "),
                        coverUrl = item.coverUrl,
                        format = item.format,
                        totalChapters = item.totalChapters,
                        isSaved = true,
                        isFavorite = item.aniListId in snapshot.favoriteAniListIds,
                        readChapterCount = readCount,
                        unreadChapterCount = item.totalChapters?.let { (it - readCount).coerceAtLeast(0) },
                        lastReadChapter = progress?.lastReadChapter,
                    )
                },
            catalogs = snapshot.catalogs.map { section ->
                MangaCatalogSectionRow(
                    id = section.id,
                    title = section.title,
                    items = section.items.map(MangaCatalogItemSnapshot::toRow),
                )
            },
            collections = snapshot.collections.map { collection ->
                MangaCollectionRow(
                    id = collection.id.ifBlank { collection.name },
                    name = collection.name,
                    subtitle = listOfNotNull(
                        "${collection.items.size} saved",
                        collection.description,
                    ).joinToString(" - "),
                )
            },
            recent = snapshot.recentProgress.map { (id, progress) ->
                val aniListId = progress.aniListIdFromProgressId(id)
                val readCount = progress.readChapterNumbers.size
                MangaProgressRow(
                    id = id,
                    aniListId = aniListId,
                    title = progress.title ?: "Manga $id",
                    subtitle = listOfNotNull(
                        progress.lastReadChapter?.let { "Chapter $it" },
                        progress.format,
                    ).joinToString(" - "),
                    coverUrl = progress.coverUrl,
                    readChapterCount = readCount,
                    unreadChapterCount = progress.totalChapters?.let { (it - readCount).coerceAtLeast(0) },
                )
            },
            modules = snapshot.modules.map { module ->
                MangaModuleRow(
                    id = module.id,
                    name = module.displayName,
                    subtitle = listOfNotNull(
                        module.version.takeIf(String::isNotBlank)?.let { "v$it" },
                        module.language.takeIf(String::isNotBlank),
                        if (module.isNovel) "Novel" else "Manga",
                    ).joinToString(" - "),
                    isActive = module.isActive,
                )
            },
        )
    }
}

private fun MangaCatalogItemSnapshot.toRow(): MangaCatalogItemRow = MangaCatalogItemRow(
    id = id,
    aniListId = aniListId,
    title = title,
    subtitle = subtitle,
    coverUrl = coverUrl,
    description = description,
    format = format,
    totalChapters = totalChapters,
    isSaved = isSaved,
    isFavorite = isFavorite,
    readChapterCount = readChapterCount,
    unreadChapterCount = unreadChapterCount,
    lastReadChapter = lastReadChapter,
)

private fun MangaCatalogItemRow.toDraft(): MangaLibraryItemDraft = MangaLibraryItemDraft(
    aniListId = aniListId,
    title = title,
    coverUrl = coverUrl,
    format = format,
    totalChapters = totalChapters,
)

private fun MangaProgress.aniListIdFromProgressId(id: String): Int? =
    contentParams?.substringAfter("anilist:", missingDelimiterValue = "")?.toIntOrNull()
        ?: id.substringAfter("anilist-manga:", missingDelimiterValue = "").toIntOrNull()
        ?: id.toIntOrNull()

private fun MangaScreenState.findCatalogItem(itemId: String): MangaCatalogItemRow? =
    searchResults.firstOrNull { it.id == itemId }
        ?: catalogs.asSequence()
            .flatMap { section -> section.items.asSequence() }
            .firstOrNull { it.id == itemId }

private fun MangaScreenState.withSavedFlag(
    aniListId: Int,
    isSaved: Boolean,
): MangaScreenState = copy(
    searchResults = searchResults.map { row ->
        if (row.aniListId == aniListId) row.copy(isSaved = isSaved) else row
    },
    catalogs = catalogs.map { section ->
        section.copy(
            items = section.items.map { row ->
                if (row.aniListId == aniListId) row.copy(isSaved = isSaved) else row
            },
        )
    },
)

private fun dev.soupy.eclipse.android.data.KanzenModuleUpdateSummary.toNotice(label: String): String =
    if (checkedModules == 0) {
        "No $label had update URLs ready."
    } else {
        "Updated $updatedModules of $checkedModules $label${if (failedModules > 0) "; $failedModules failed validation or fetch." else "."}"
    }
