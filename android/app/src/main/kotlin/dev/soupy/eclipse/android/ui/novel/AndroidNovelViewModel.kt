package dev.soupy.eclipse.android.ui.novel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.soupy.eclipse.android.core.model.MangaLibraryItem
import dev.soupy.eclipse.android.core.model.MangaProgress
import dev.soupy.eclipse.android.data.KanzenModuleDraft
import dev.soupy.eclipse.android.data.MangaCatalogItemSnapshot
import dev.soupy.eclipse.android.data.MangaLibraryItemDraft
import dev.soupy.eclipse.android.data.MangaOverviewSnapshot
import dev.soupy.eclipse.android.data.MangaRepository
import dev.soupy.eclipse.android.feature.novel.NovelCatalogItemRow
import dev.soupy.eclipse.android.feature.novel.NovelCatalogSectionRow
import dev.soupy.eclipse.android.feature.novel.NovelModuleRow
import dev.soupy.eclipse.android.feature.novel.NovelProgressRow
import dev.soupy.eclipse.android.feature.novel.NovelScreenState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class AndroidNovelViewModel(
    private val repository: MangaRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(NovelScreenState(isLoading = true))
    val state: StateFlow<NovelScreenState> = _state.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, errorMessage = null)
            repository.loadNovelOverview()
                .onSuccess(::applyOverview)
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        isLoading = false,
                        errorMessage = error.message ?: "Novel reading data could not be loaded.",
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
            repository.searchNovels(query)
                .onSuccess { results ->
                    _state.update {
                        it.copy(
                            isSearching = false,
                            searchResults = results.map(MangaCatalogItemSnapshot::toRow),
                            noticeMessage = if (results.isEmpty()) "No AniList novel results for \"$query\"." else null,
                        )
                    }
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(
                            isSearching = false,
                            errorMessage = error.message ?: "Novel search could not finish.",
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
                        notice = "Saved ${item.title} to your novel library.",
                        aniListId = item.aniListId,
                        isSaved = true,
                    )
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not save novel.")
                    }
                }
        }
    }

    fun removeItem(aniListId: Int) {
        viewModelScope.launch {
            repository.removeFromLibrary(aniListId)
                .onSuccess {
                    reloadAfterLibraryMutation(
                        notice = "Removed novel from your library.",
                        aniListId = aniListId,
                        isSaved = false,
                    )
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not remove novel.")
                    }
                }
        }
    }

    fun readNextChapter(aniListId: Int) {
        viewModelScope.launch {
            repository.markNextChapterRead(aniListId)
                .onSuccess {
                    reloadAfterModuleMutation("Marked the next novel chapter as read.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update novel progress.")
                    }
                }
        }
    }

    fun unreadLastChapter(aniListId: Int) {
        viewModelScope.launch {
            repository.markPreviousChapterUnread(aniListId)
                .onSuccess {
                    reloadAfterModuleMutation("Marked the latest novel chapter unread.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update novel progress.")
                    }
                }
        }
    }

    fun toggleFavorite(aniListId: Int) {
        viewModelScope.launch {
            repository.toggleFavorite(aniListId)
                .onSuccess {
                    reloadAfterModuleMutation("Updated novel favorites.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update favorite novel.")
                    }
                }
        }
    }

    fun clearReadingProgress(progressId: String) {
        viewModelScope.launch {
            repository.clearReadingProgress(progressId)
                .onSuccess {
                    reloadAfterModuleMutation("Reset novel reading progress.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not reset novel reading progress.")
                    }
                }
        }
    }

    fun addModule(moduleUrl: String) {
        viewModelScope.launch {
            repository.addModule(
                KanzenModuleDraft(
                    moduleUrl = moduleUrl,
                    isNovel = true,
                ),
            ).onSuccess {
                reloadAfterModuleMutation("Saved Kanzen novel module.")
            }.onFailure { error ->
                _state.update {
                    it.copy(errorMessage = error.message ?: "Could not add Kanzen novel module.")
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
                    reloadAfterModuleMutation(if (active) "Novel module enabled." else "Novel module disabled.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update Kanzen novel module.")
                    }
                }
        }
    }

    fun removeModule(moduleId: String) {
        viewModelScope.launch {
            repository.removeModule(moduleId)
                .onSuccess {
                    reloadAfterModuleMutation("Removed Kanzen novel module.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not remove Kanzen novel module.")
                    }
                }
        }
    }

    fun updateModule(moduleId: String) {
        viewModelScope.launch {
            repository.updateModule(moduleId)
                .onSuccess {
                    reloadAfterModuleMutation("Updated Kanzen novel module metadata and script.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update Kanzen novel module.")
                    }
                }
        }
    }

    fun updateAllModules() {
        viewModelScope.launch {
            repository.updateModules(isNovel = true)
                .onSuccess { summary ->
                    reloadAfterModuleMutation(summary.toNotice("Kanzen novel modules"))
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update Kanzen novel modules.")
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
        repository.loadNovelOverview()
            .onSuccess { applyOverview(it, notice) }
            .onFailure { error ->
                _state.update {
                    it.copy(errorMessage = error.message ?: "Novel library changed, but refresh failed.")
                }
            }
    }

    private suspend fun reloadAfterModuleMutation(notice: String) {
        _state.update { it.copy(noticeMessage = notice, errorMessage = null) }
        repository.loadNovelOverview()
            .onSuccess { applyOverview(it, notice) }
            .onFailure { error ->
                _state.update {
                    it.copy(errorMessage = error.message ?: "Kanzen novel modules changed, but refresh failed.")
                }
            }
    }

    private fun applyOverview(
        snapshot: MangaOverviewSnapshot,
        notice: String? = null,
    ) {
        val previous = _state.value
        val savedNovelItems = snapshot.collections
            .flatMap { collection -> collection.items }
            .filter(MangaLibraryItem::isNovelItem)
            .distinctBy { item -> item.aniListId }
        val savedNovelIds = savedNovelItems.map(MangaLibraryItem::aniListId).toSet()
        _state.value = NovelScreenState(
            isLoading = false,
            query = previous.query,
            isSearching = false,
            noticeMessage = notice ?: previous.noticeMessage,
            novelCount = (
                savedNovelIds.map(Int::toString) +
                    snapshot.recentNovelProgress.map { (id, _) -> id }
                ).toSet().size,
            readChapterCount = snapshot.novelReadChapterCount,
            importedFromBackup = snapshot.importedFromBackup,
            searchResults = previous.searchResults.map { row ->
                row.copy(isSaved = row.aniListId in savedNovelIds)
            },
            savedItems = savedNovelItems.map { item ->
                val progress = snapshot.progressByAniListId[item.aniListId]
                val readCount = progress?.readChapterNumbers?.size ?: 0
                NovelCatalogItemRow(
                    id = "saved-novel-${item.aniListId}",
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
                NovelCatalogSectionRow(
                    id = section.id,
                    title = section.title,
                    items = section.items.map(MangaCatalogItemSnapshot::toRow),
                )
            },
            recent = snapshot.recentNovelProgress.map { (id, progress) ->
                val aniListId = progress.aniListIdFromProgressId(id)
                val readCount = progress.readChapterNumbers.size
                NovelProgressRow(
                    id = id,
                    aniListId = aniListId,
                    title = progress.title ?: "Novel $id",
                    subtitle = listOfNotNull(
                        progress.lastReadChapter?.let { "Chapter $it" },
                        progress.format,
                    ).joinToString(" - "),
                    coverUrl = progress.coverUrl,
                    readChapterCount = readCount,
                    unreadChapterCount = progress.totalChapters?.let { (it - readCount).coerceAtLeast(0) },
                )
            },
            modules = snapshot.modules
                .filter { module -> module.isNovel }
                .map { module ->
                    NovelModuleRow(
                        id = module.id,
                        name = module.displayName,
                        subtitle = listOfNotNull(
                            module.version.takeIf(String::isNotBlank)?.let { "v$it" },
                            module.language.takeIf(String::isNotBlank),
                        ).joinToString(" - "),
                        isActive = module.isActive,
                    )
            },
        )
    }
}

private fun MangaCatalogItemSnapshot.toRow(): NovelCatalogItemRow = NovelCatalogItemRow(
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

private fun NovelCatalogItemRow.toDraft(): MangaLibraryItemDraft = MangaLibraryItemDraft(
    aniListId = aniListId,
    title = title,
    coverUrl = coverUrl,
    format = format ?: "NOVEL",
    totalChapters = totalChapters,
)

private fun MangaProgress.aniListIdFromProgressId(id: String): Int? =
    contentParams?.substringAfter("anilist:", missingDelimiterValue = "")?.toIntOrNull()
        ?: id.substringAfter("anilist-manga:", missingDelimiterValue = "").toIntOrNull()
        ?: id.toIntOrNull()

private fun NovelScreenState.findCatalogItem(itemId: String): NovelCatalogItemRow? =
    searchResults.firstOrNull { it.id == itemId }
        ?: catalogs.asSequence()
            .flatMap { section -> section.items.asSequence() }
            .firstOrNull { it.id == itemId }

private fun NovelScreenState.withSavedFlag(
    aniListId: Int,
    isSaved: Boolean,
): NovelScreenState = copy(
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

private val MangaLibraryItem.isNovelItem: Boolean
    get() = format.equals("NOVEL", ignoreCase = true) ||
        format.equals("LIGHT_NOVEL", ignoreCase = true)

private fun dev.soupy.eclipse.android.data.KanzenModuleUpdateSummary.toNotice(label: String): String =
    if (checkedModules == 0) {
        "No $label had update URLs ready."
    } else {
        "Updated $updatedModules of $checkedModules $label${if (failedModules > 0) "; $failedModules failed validation or fetch." else "."}"
    }
