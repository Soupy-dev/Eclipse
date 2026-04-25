package dev.soupy.eclipse.android.ui.manga

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.soupy.eclipse.android.core.model.MangaProgress
import dev.soupy.eclipse.android.data.KanzenCatalogDetailSnapshot
import dev.soupy.eclipse.android.data.KanzenModuleDraft
import dev.soupy.eclipse.android.data.KanzenReaderChapterSnapshot
import dev.soupy.eclipse.android.data.KanzenReaderContentSnapshot
import dev.soupy.eclipse.android.data.MangaCatalogItemSnapshot
import dev.soupy.eclipse.android.data.MangaLibraryItemDraft
import dev.soupy.eclipse.android.data.MangaOverviewSnapshot
import dev.soupy.eclipse.android.data.MangaReadingProgressDraft
import dev.soupy.eclipse.android.data.MangaRepository
import dev.soupy.eclipse.android.data.ReaderCacheRepository
import dev.soupy.eclipse.android.feature.manga.MangaCatalogItemRow
import dev.soupy.eclipse.android.feature.manga.MangaCatalogSectionRow
import dev.soupy.eclipse.android.feature.manga.MangaCollectionRow
import dev.soupy.eclipse.android.feature.manga.MangaModuleRow
import dev.soupy.eclipse.android.feature.manga.MangaProgressRow
import dev.soupy.eclipse.android.feature.manga.MangaReaderChapterRow
import dev.soupy.eclipse.android.feature.manga.MangaReaderPanelRow
import dev.soupy.eclipse.android.feature.manga.MangaScreenState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class AndroidMangaViewModel(
    private val repository: MangaRepository,
    private val readerCacheRepository: ReaderCacheRepository? = null,
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
                .onSuccess { snapshot ->
                    applyOverview(snapshot)
                    updateReaderCacheStats()
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        isLoading = false,
                        errorMessage = error.message ?: "Manga library data could not be loaded.",
                    )
                }
        }
    }

    fun clearReaderCache() {
        val cache = readerCacheRepository ?: return
        viewModelScope.launch {
            cache.clear()
                .onSuccess { previousStats ->
                    val notice = if (previousStats.fileCount == 0) {
                        "Reader cache was already empty."
                    } else {
                        "Cleared reader cache (${previousStats.displayText.removeSuffix(".")})."
                    }
                    _state.update {
                        it.copy(
                            noticeMessage = notice,
                            errorMessage = null,
                            readerCacheSummary = "Reader cache empty.",
                        )
                    }
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not clear reader cache.")
                    }
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

    fun openDetail(itemId: String) {
        val item = _state.value.findCatalogItem(itemId) ?: return
        _state.update {
            it.copy(
                selectedDetail = item,
                isDetailLoading = item.isKanzenBacked,
                detailError = null,
                noticeMessage = null,
                errorMessage = null,
            )
        }
        if (item.isKanzenBacked) {
            loadKanzenCatalogDetails(item)
        }
    }

    fun closeDetail() {
        _state.update {
            it.copy(
                selectedDetail = null,
                isDetailLoading = false,
                detailError = null,
            )
        }
    }

    fun readNextChapter(aniListId: Int) {
        val reader = _state.value.activeReaderPanelFor(aniListId)
        val nextRuntimeChapter = reader
            ?.takeIf { it.isKanzenBacked }
            ?.chapters
            ?.filter { chapter -> chapter.number > reader.currentChapter }
            ?.minByOrNull { chapter -> chapter.number }
        if (nextRuntimeChapter != null) {
            readChapter(aniListId, nextRuntimeChapter.number)
            return
        }
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

    fun readPreviousChapter(aniListId: Int) {
        val reader = _state.value.activeReaderPanelFor(aniListId) ?: return
        val previousRuntimeChapter = reader.chapters
            .filter { chapter -> chapter.number < reader.currentChapter }
            .maxByOrNull { chapter -> chapter.number }
        val previousParams = previousRuntimeChapter?.params
        if (reader.isKanzenBacked && !previousParams.isNullOrBlank()) {
            loadKanzenChapterContent(
                aniListId = aniListId,
                chapterNumber = previousRuntimeChapter.number,
                chapterParams = previousParams,
            )
            return
        }
        val previousChapter = previousRuntimeChapter?.number ?: (reader.currentChapter - 1).coerceAtLeast(1)
        _state.update {
            it.updateReader(aniListId) { current ->
                current.copy(
                    currentChapter = previousChapter,
                    chapters = current.chapters.map { chapter ->
                        chapter.copy(isCurrent = chapter.number == previousChapter)
                    },
                )
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

    fun openReader(aniListId: Int) {
        val reader = _state.value.readerPanelFor(aniListId)
        _state.update {
            if (reader != null) {
                val nextReader = if (reader.isKanzenBacked) {
                    reader.copy(isLoadingChapters = true, contentError = null)
                } else {
                    reader
                }
                it.copy(reader = nextReader, noticeMessage = "Opened manga reader progress for ${reader.title}.", errorMessage = null)
            } else {
                it.copy(errorMessage = "Save this manga before opening reader progress.")
            }
        }
        if (reader?.isKanzenBacked == true) {
            loadKanzenReaderChapters(reader)
        }
    }

    fun closeReader() {
        _state.update { it.copy(reader = null) }
    }

    fun readChapter(
        aniListId: Int,
        chapterNumber: Int,
    ) {
        val item = _state.value.activeReaderPanelFor(aniListId) ?: return
        val selectedChapter = item.chapters.firstOrNull { chapter -> chapter.number == chapterNumber }
        viewModelScope.launch {
            val content = if (item.isKanzenBacked && !selectedChapter?.params.isNullOrBlank()) {
                _state.update {
                    it.updateReader(aniListId) { reader ->
                        reader.copy(
                            currentChapter = chapterNumber,
                            isLoadingContent = true,
                            contentMessage = "Loading manga chapter $chapterNumber pages...",
                            contentError = null,
                            pageImageUrls = emptyList(),
                        )
                    }
                }
                val cached = readerCacheRepository?.load(
                    moduleId = item.moduleId,
                    chapterParams = selectedChapter.params,
                    isNovel = false,
                )?.getOrNull()
                cached ?: repository.loadKanzenReaderContent(
                    moduleId = item.moduleId,
                    chapterParams = selectedChapter.params,
                    isNovel = false,
                ).getOrElse { error ->
                    _state.update {
                        it.updateReader(aniListId) { reader ->
                            reader.copy(
                                isLoadingContent = false,
                                contentError = error.message ?: "Could not load module chapter pages.",
                            )
                        }
                    }
                    null
                }
            } else {
                null
            }
            repository.recordReadingProgress(
                MangaReadingProgressDraft(
                    aniListId = aniListId,
                    title = item.title,
                    coverUrl = item.coverUrl,
                    format = item.format,
                    totalChapters = item.totalChapters,
                    moduleId = item.moduleId,
                    contentParams = item.contentParams,
                    chapterNumber = chapterNumber,
                    isNovel = false,
                ),
            ).onSuccess {
                reloadAfterModuleMutation("Marked manga chapter $chapterNumber as read.")
                content?.let { loaded ->
                    _state.update {
                        it.updateReader(aniListId) { reader ->
                            reader.withKanzenContent(
                                chapterNumber = chapterNumber,
                                content = loaded,
                            )
                        }
                    }
                }
            }.onFailure { error ->
                _state.update {
                    it.copy(errorMessage = error.message ?: "Could not update manga reader progress.")
                }
            }
            content?.let { loaded ->
                if (!loaded.isCached && !selectedChapter?.params.isNullOrBlank()) {
                    cacheKanzenChapter(
                        moduleId = item.moduleId,
                        chapterParams = selectedChapter.params,
                        content = loaded,
                    )
                }
                preloadNextKanzenChapter(
                    reader = item,
                    currentChapterNumber = chapterNumber,
                )
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

    fun createCollection(name: String) {
        viewModelScope.launch {
            repository.createCollection(name)
                .onSuccess {
                    reloadAfterModuleMutation("Created manga collection.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not create manga collection.")
                    }
                }
        }
    }

    fun deleteCollection(collectionId: String) {
        viewModelScope.launch {
            repository.deleteCollection(collectionId)
                .onSuccess {
                    reloadAfterModuleMutation("Deleted manga collection.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not delete manga collection.")
                    }
                }
        }
    }

    fun addItemToCollection(
        collectionId: String,
        aniListId: Int,
    ) {
        viewModelScope.launch {
            repository.addToCollection(collectionId, aniListId)
                .onSuccess {
                    reloadAfterModuleMutation("Added manga to collection.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not add manga to collection.")
                    }
                }
        }
    }

    fun removeItemFromCollection(
        collectionId: String,
        aniListId: Int,
    ) {
        viewModelScope.launch {
            repository.removeFromCollection(collectionId, aniListId)
                .onSuccess {
                    reloadAfterModuleMutation("Removed manga from collection.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not remove manga from collection.")
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
        val nextState = MangaScreenState(
            isLoading = false,
            query = previous.query,
            isSearching = false,
            noticeMessage = notice ?: previous.noticeMessage,
            savedCount = snapshot.savedCount,
            readChapterCount = snapshot.readChapterCount,
            novelCount = snapshot.novelCount,
            importedFromBackup = snapshot.importedFromBackup,
            readerCacheSummary = previous.readerCacheSummary,
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
                        moduleId = item.moduleId,
                        contentParams = item.contentParams,
                        sourceName = item.sourceName,
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
                    itemIds = collection.items.map { item -> item.aniListId }.toSet(),
                    isEditable = !collection.isSystemCollection,
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
                    moduleId = progress.moduleUUID,
                    contentParams = progress.contentParams,
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
        val selectedDetail = previous.selectedDetail?.let { detail ->
            nextState.findCatalogItem(detail.id)
                ?.withDetailFieldsFrom(detail)
                ?: nextState.findCatalogItemByAniListId(detail.aniListId)
                    ?.withDetailFieldsFrom(detail)
                ?: detail.copy(isSaved = detail.aniListId in savedIds)
        }
        _state.value = nextState.copy(
            selectedDetail = selectedDetail,
            isDetailLoading = previous.isDetailLoading,
            detailError = previous.detailError,
            reader = previous.reader?.let { reader ->
                nextState.readerPanelFor(reader.aniListId)?.mergeRuntimeState(reader)
            },
        )
    }

    private fun loadKanzenCatalogDetails(item: MangaCatalogItemRow) {
        viewModelScope.launch {
            repository.loadKanzenCatalogDetails(
                moduleId = item.moduleId,
                contentParams = item.contentParams,
                isNovel = false,
            ).onSuccess { details ->
                _state.update { state ->
                    val current = state.findCatalogItem(item.id) ?: item
                    val enriched = current.withKanzenDetails(details)
                    state.withUpdatedCatalogItem(item.id, enriched).copy(
                        selectedDetail = state.selectedDetail?.let { detail ->
                            if (detail.id == item.id || detail.aniListId == item.aniListId) {
                                detail.withKanzenDetails(details)
                            } else {
                                detail
                            }
                        },
                        isDetailLoading = false,
                        detailError = null,
                    )
                }
            }.onFailure { error ->
                _state.update {
                    it.copy(
                        isDetailLoading = false,
                        detailError = error.message ?: "Could not load module details.",
                    )
                }
            }
        }
    }

    private fun cacheKanzenChapter(
        moduleId: String?,
        chapterParams: String?,
        content: KanzenReaderContentSnapshot,
    ) {
        val cache = readerCacheRepository ?: return
        viewModelScope.launch {
            cache.save(
                moduleId = moduleId,
                chapterParams = chapterParams,
                isNovel = false,
                content = content,
            ).onSuccess {
                updateReaderCacheStats()
            }
        }
    }

    private fun preloadNextKanzenChapter(
        reader: MangaReaderPanelRow,
        currentChapterNumber: Int,
    ) {
        val cache = readerCacheRepository ?: return
        if (!reader.isKanzenBacked) return
        val nextChapter = reader.chapters
            .filter { chapter -> chapter.number > currentChapterNumber }
            .minByOrNull { chapter -> chapter.number }
            ?: return
        val nextParams = nextChapter.params?.takeIf(String::isNotBlank) ?: return
        viewModelScope.launch {
            val cached = cache.load(
                moduleId = reader.moduleId,
                chapterParams = nextParams,
                isNovel = false,
            ).getOrNull()
            if (cached != null) return@launch
            repository.loadKanzenReaderContent(
                moduleId = reader.moduleId,
                chapterParams = nextParams,
                isNovel = false,
            ).onSuccess { content ->
                cache.save(
                    moduleId = reader.moduleId,
                    chapterParams = nextParams,
                    isNovel = false,
                    content = content,
                ).onSuccess {
                    updateReaderCacheStats()
                }
            }
        }
    }

    private suspend fun updateReaderCacheStats() {
        readerCacheRepository?.stats()
            ?.onSuccess { stats ->
                _state.update { it.copy(readerCacheSummary = stats.displayText) }
            }
    }

    private fun loadKanzenReaderChapters(reader: MangaReaderPanelRow) {
        viewModelScope.launch {
            repository.loadKanzenReaderChapters(
                moduleId = reader.moduleId,
                contentParams = reader.contentParams,
                isNovel = false,
            ).onSuccess { chapters ->
                _state.update {
                    it.updateReader(reader.aniListId) { current ->
                        current.withKanzenChapters(chapters)
                    }
                }
            }.onFailure { error ->
                _state.update {
                    it.updateReader(reader.aniListId) { current ->
                        current.copy(
                            isLoadingChapters = false,
                            contentError = error.message ?: "Could not load Kanzen module chapters.",
                        )
                    }
                }
            }
        }
    }

    private fun loadKanzenChapterContent(
        aniListId: Int,
        chapterNumber: Int,
        chapterParams: String?,
    ) {
        viewModelScope.launch {
            _state.update {
                it.updateReader(aniListId) { reader ->
                    reader.copy(
                        currentChapter = chapterNumber,
                        isLoadingContent = true,
                        contentMessage = "Loading manga chapter $chapterNumber pages...",
                        contentError = null,
                        pageImageUrls = emptyList(),
                        chapters = reader.chapters.map { chapter ->
                            chapter.copy(isCurrent = chapter.number == chapterNumber)
                        },
                    )
                }
            }
            val moduleId = _state.value.reader?.moduleId
            val cached = readerCacheRepository?.load(
                moduleId = moduleId,
                chapterParams = chapterParams,
                isNovel = false,
            )?.getOrNull()
            val result = cached?.let(Result.Companion::success) ?: repository.loadKanzenReaderContent(
                moduleId = moduleId,
                chapterParams = chapterParams,
                isNovel = false,
            )
            result.onSuccess { content ->
                _state.update {
                    it.updateReader(aniListId) { reader ->
                        reader.withKanzenContent(
                            chapterNumber = chapterNumber,
                            content = content,
                            markRead = false,
                        )
                    }
                }
                if (!content.isCached) {
                    cacheKanzenChapter(
                        moduleId = moduleId,
                        chapterParams = chapterParams,
                        content = content,
                    )
                }
            }.onFailure { error ->
                _state.update {
                    it.updateReader(aniListId) { reader ->
                        reader.copy(
                            isLoadingContent = false,
                            contentError = error.message ?: "Could not load module chapter pages.",
                        )
                    }
                }
            }
        }
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
    moduleId = moduleId,
    contentParams = contentParams,
    sourceName = sourceName,
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
    moduleId = moduleId,
    contentParams = contentParams,
    sourceName = sourceName,
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
        ?: savedItems.firstOrNull { it.id == itemId }
        ?: selectedDetail?.takeIf { it.id == itemId }

private fun MangaScreenState.findCatalogItemByAniListId(aniListId: Int): MangaCatalogItemRow? =
    savedItems.firstOrNull { it.aniListId == aniListId }
        ?: searchResults.firstOrNull { it.aniListId == aniListId }
        ?: catalogs.asSequence()
            .flatMap { section -> section.items.asSequence() }
            .firstOrNull { it.aniListId == aniListId }
        ?: selectedDetail?.takeIf { it.aniListId == aniListId }

private val MangaCatalogItemRow.isKanzenBacked: Boolean
    get() = !moduleId.isNullOrBlank() && moduleId != "anilist" && !contentParams.isNullOrBlank()

private fun MangaCatalogItemRow.withKanzenDetails(details: KanzenCatalogDetailSnapshot): MangaCatalogItemRow {
    val detailSubtitle = details.subtitle?.trim()?.takeIf(String::isNotBlank)
    return copy(
        title = details.title?.trim()?.takeIf(String::isNotBlank) ?: title,
        subtitle = detailSubtitle?.let { subtitle ->
            listOfNotNull(sourceName?.takeIf(String::isNotBlank), subtitle)
                .distinct()
                .joinToString(" - ")
        } ?: subtitle,
        coverUrl = details.coverUrl?.trim()?.takeIf(String::isNotBlank) ?: coverUrl,
        description = details.description?.trim()?.takeIf(String::isNotBlank) ?: description,
        totalChapters = details.totalChapters ?: totalChapters,
    )
}

private fun MangaCatalogItemRow.withDetailFieldsFrom(detail: MangaCatalogItemRow): MangaCatalogItemRow = copy(
    title = detail.title.takeIf(String::isNotBlank) ?: title,
    subtitle = detail.subtitle.takeIf(String::isNotBlank) ?: subtitle,
    coverUrl = detail.coverUrl ?: coverUrl,
    description = detail.description ?: description,
    totalChapters = detail.totalChapters ?: totalChapters,
    moduleId = detail.moduleId ?: moduleId,
    contentParams = detail.contentParams ?: contentParams,
    sourceName = detail.sourceName ?: sourceName,
)

private fun MangaScreenState.withUpdatedCatalogItem(
    itemId: String,
    replacement: MangaCatalogItemRow,
): MangaScreenState = copy(
    searchResults = searchResults.map { row ->
        if (row.id == itemId || row.aniListId == replacement.aniListId) {
            row.withDetailFieldsFrom(replacement)
        } else {
            row
        }
    },
    savedItems = savedItems.map { row ->
        if (row.id == itemId || row.aniListId == replacement.aniListId) {
            row.withDetailFieldsFrom(replacement)
        } else {
            row
        }
    },
    catalogs = catalogs.map { section ->
        section.copy(
            items = section.items.map { row ->
                if (row.id == itemId || row.aniListId == replacement.aniListId) {
                    row.withDetailFieldsFrom(replacement)
                } else {
                    row
                }
            },
        )
    },
)

private fun MangaScreenState.activeReaderPanelFor(aniListId: Int): MangaReaderPanelRow? =
    reader?.takeIf { it.aniListId == aniListId }
        ?: readerPanelFor(aniListId)

private fun MangaScreenState.readerPanelFor(aniListId: Int): MangaReaderPanelRow? =
    savedItems.firstOrNull { it.aniListId == aniListId }
        ?.toReaderPanel()
        ?: searchResults.firstOrNull { it.aniListId == aniListId && it.isSaved }
            ?.toReaderPanel()
        ?: catalogs.asSequence()
            .flatMap { section -> section.items.asSequence() }
            .firstOrNull { it.aniListId == aniListId && it.isSaved }
            ?.toReaderPanel()
        ?: selectedDetail?.takeIf { it.aniListId == aniListId && it.isSaved }
            ?.toReaderPanel()
        ?: recent.firstOrNull { it.aniListId == aniListId }
            ?.toReaderPanel()

private fun MangaCatalogItemRow.toReaderPanel(): MangaReaderPanelRow {
    val readCount = readChapterCount.coerceAtLeast(lastReadChapter?.toIntOrNull() ?: 0)
    val current = ((lastReadChapter?.toIntOrNull() ?: readCount) + 1)
        .coerceAtLeast(1)
        .coerceAtMost(totalChapters ?: Int.MAX_VALUE)
    return MangaReaderPanelRow(
        aniListId = aniListId,
        title = title,
        coverUrl = coverUrl,
        format = format,
        totalChapters = totalChapters,
        moduleId = moduleId,
        contentParams = contentParams,
        sourceName = sourceName,
        readChapterCount = readCount,
        unreadChapterCount = totalChapters?.let { (it - readCount).coerceAtLeast(0) },
        lastReadChapter = lastReadChapter,
        currentChapter = current,
        chapters = chapterWindow(
            currentChapter = current,
            totalChapters = totalChapters,
            readChapterCount = readCount,
        ),
    )
}

private fun MangaProgressRow.toReaderPanel(): MangaReaderPanelRow {
    val current = (readChapterCount + 1)
        .coerceAtLeast(1)
        .coerceAtMost(unreadChapterCount?.let { readChapterCount + it } ?: Int.MAX_VALUE)
    val total = unreadChapterCount?.let { readChapterCount + it }
    return MangaReaderPanelRow(
        aniListId = aniListId ?: return MangaReaderPanelRow(
            aniListId = 0,
            title = title,
            coverUrl = coverUrl,
        ),
        title = title,
        coverUrl = coverUrl,
        moduleId = moduleId,
        contentParams = contentParams,
        sourceName = sourceName,
        totalChapters = total,
        readChapterCount = readChapterCount,
        unreadChapterCount = unreadChapterCount,
        currentChapter = current,
        chapters = chapterWindow(
            currentChapter = current,
            totalChapters = total,
            readChapterCount = readChapterCount,
        ),
    )
}

private fun chapterWindow(
    currentChapter: Int,
    totalChapters: Int?,
    readChapterCount: Int,
): List<MangaReaderChapterRow> {
    val lastChapter = totalChapters?.takeIf { it > 0 }
    val start = (currentChapter - 6).coerceAtLeast(1)
    val end = if (lastChapter != null) {
        (start + 17).coerceAtMost(lastChapter)
    } else {
        start + 17
    }
    return (start..end).map { chapter ->
        MangaReaderChapterRow(
            number = chapter,
            isRead = chapter <= readChapterCount,
            isCurrent = chapter == currentChapter,
        )
    }
}

private val MangaReaderPanelRow.isKanzenBacked: Boolean
    get() = !moduleId.isNullOrBlank() && moduleId != "anilist" && !contentParams.isNullOrBlank()

private fun MangaReaderPanelRow.withKanzenChapters(chapters: List<KanzenReaderChapterSnapshot>): MangaReaderPanelRow {
    if (chapters.isEmpty()) {
        return copy(
            isLoadingChapters = false,
            contentError = "No module chapters were returned for this manga.",
        )
    }
    val nextChapter = chapters.firstOrNull { chapter -> chapter.number > readChapterCount }?.number
        ?: chapters.first().number
    return copy(
        totalChapters = chapters.size,
        unreadChapterCount = (chapters.size - readChapterCount).coerceAtLeast(0),
        currentChapter = nextChapter,
        isLoadingChapters = false,
        contentError = null,
        chapters = chapters.map { chapter ->
            MangaReaderChapterRow(
                number = chapter.number,
                title = chapter.title,
                params = chapter.params,
                sourceName = chapter.sourceName,
                isRead = chapter.number <= readChapterCount,
                isCurrent = chapter.number == nextChapter,
            )
        },
    )
}

private fun MangaReaderPanelRow.withKanzenContent(
    chapterNumber: Int,
    content: KanzenReaderContentSnapshot,
    markRead: Boolean = true,
): MangaReaderPanelRow = copy(
    currentChapter = chapterNumber,
    isLoadingContent = false,
    contentMessage = content.cacheMessage
        ?: content.imageUrls.takeIf { it.isNotEmpty() }?.let { "${it.size} pages loaded." },
    contentError = if (content.imageUrls.isEmpty()) "No page images were returned for this chapter." else null,
    pageImageUrls = content.imageUrls,
    chapters = chapters.map { chapter ->
        chapter.copy(
            isCurrent = chapter.number == chapterNumber,
            isRead = chapter.isRead || (markRead && chapter.number <= chapterNumber),
        )
    },
)

private fun MangaReaderPanelRow.mergeRuntimeState(previous: MangaReaderPanelRow): MangaReaderPanelRow {
    val runtimeChapters = previous.chapters.takeIf { rows -> rows.any { row -> row.params != null } } ?: chapters
    return copy(
        currentChapter = previous.currentChapter,
        chapters = runtimeChapters.map { chapter ->
            chapter.copy(
                isRead = chapter.number <= readChapterCount || chapter.isRead,
                isCurrent = chapter.number == previous.currentChapter,
            )
        },
        isLoadingChapters = previous.isLoadingChapters,
        isLoadingContent = previous.isLoadingContent,
        contentMessage = previous.contentMessage,
        contentError = previous.contentError,
        pageImageUrls = previous.pageImageUrls,
    )
}

private fun MangaScreenState.updateReader(
    aniListId: Int,
    transform: (MangaReaderPanelRow) -> MangaReaderPanelRow,
): MangaScreenState = copy(
    reader = reader?.let { current ->
        if (current.aniListId == aniListId) transform(current) else current
    },
)

private val dev.soupy.eclipse.android.core.model.MangaLibraryCollection.isSystemCollection: Boolean
    get() = id.equals("android-library", ignoreCase = true) ||
        id.equals("android-favorites", ignoreCase = true) ||
        name.equals("Library", ignoreCase = true) ||
        name.equals("Favorites", ignoreCase = true)

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
    selectedDetail = selectedDetail?.let { row ->
        if (row.aniListId == aniListId) row.copy(isSaved = isSaved) else row
    },
)

private fun dev.soupy.eclipse.android.data.KanzenModuleUpdateSummary.toNotice(label: String): String =
    if (checkedModules == 0) {
        "No $label had update URLs ready."
    } else {
        "Updated $updatedModules of $checkedModules $label${if (failedModules > 0) "; $failedModules failed validation or fetch." else "."}"
    }
