package dev.soupy.eclipse.android.ui.novel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.soupy.eclipse.android.core.model.MangaLibraryItem
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
import dev.soupy.eclipse.android.feature.novel.NovelCatalogItemRow
import dev.soupy.eclipse.android.feature.novel.NovelCatalogSectionRow
import dev.soupy.eclipse.android.feature.novel.NovelModuleRow
import dev.soupy.eclipse.android.feature.novel.NovelProgressRow
import dev.soupy.eclipse.android.feature.novel.NovelReaderChapterRow
import dev.soupy.eclipse.android.feature.novel.NovelReaderPanelRow
import dev.soupy.eclipse.android.feature.novel.NovelScreenState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class AndroidNovelViewModel(
    private val repository: MangaRepository,
    private val readerCacheRepository: ReaderCacheRepository? = null,
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
                .onSuccess { snapshot ->
                    applyOverview(snapshot)
                    updateReaderCacheStats()
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        isLoading = false,
                        errorMessage = error.message ?: "Novel reading data could not be loaded.",
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
                    reloadAfterModuleMutation("Marked the next novel chapter as read.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update novel progress.")
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
                    reloadAfterModuleMutation("Marked the latest novel chapter unread.")
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(errorMessage = error.message ?: "Could not update novel progress.")
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
                it.copy(reader = nextReader, noticeMessage = "Opened novel reader progress for ${reader.title}.", errorMessage = null)
            } else {
                it.copy(errorMessage = "Save this novel before opening reader progress.")
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
                            contentMessage = "Loading novel chapter $chapterNumber text...",
                            contentError = null,
                            textContent = null,
                        )
                    }
                }
                val cached = readerCacheRepository?.load(
                    moduleId = item.moduleId,
                    chapterParams = selectedChapter.params,
                    isNovel = true,
                )?.getOrNull()
                cached ?: repository.loadKanzenReaderContent(
                    moduleId = item.moduleId,
                    chapterParams = selectedChapter.params,
                    isNovel = true,
                ).getOrElse { error ->
                    _state.update {
                        it.updateReader(aniListId) { reader ->
                            reader.copy(
                                isLoadingContent = false,
                                contentError = error.message ?: "Could not load module chapter text.",
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
                    format = item.format ?: "NOVEL",
                    totalChapters = item.totalChapters,
                    moduleId = item.moduleId,
                    contentParams = item.contentParams,
                    chapterNumber = chapterNumber,
                    isNovel = true,
                ),
            ).onSuccess {
                reloadAfterModuleMutation("Marked novel chapter $chapterNumber as read.")
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
                    it.copy(errorMessage = error.message ?: "Could not update novel reader progress.")
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
        val nextState = NovelScreenState(
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
            readerCacheSummary = previous.readerCacheSummary,
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
                    moduleId = progress.moduleUUID,
                    contentParams = progress.contentParams,
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
        val selectedDetail = previous.selectedDetail?.let { detail ->
            nextState.findCatalogItem(detail.id)
                ?.withDetailFieldsFrom(detail)
                ?: nextState.findCatalogItemByAniListId(detail.aniListId)
                    ?.withDetailFieldsFrom(detail)
                ?: detail.copy(isSaved = detail.aniListId in savedNovelIds)
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

    private fun loadKanzenCatalogDetails(item: NovelCatalogItemRow) {
        viewModelScope.launch {
            repository.loadKanzenCatalogDetails(
                moduleId = item.moduleId,
                contentParams = item.contentParams,
                isNovel = true,
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
                isNovel = true,
                content = content,
            ).onSuccess {
                updateReaderCacheStats()
            }
        }
    }

    private fun preloadNextKanzenChapter(
        reader: NovelReaderPanelRow,
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
                isNovel = true,
            ).getOrNull()
            if (cached != null) return@launch
            repository.loadKanzenReaderContent(
                moduleId = reader.moduleId,
                chapterParams = nextParams,
                isNovel = true,
            ).onSuccess { content ->
                cache.save(
                    moduleId = reader.moduleId,
                    chapterParams = nextParams,
                    isNovel = true,
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

    private fun loadKanzenReaderChapters(reader: NovelReaderPanelRow) {
        viewModelScope.launch {
            repository.loadKanzenReaderChapters(
                moduleId = reader.moduleId,
                contentParams = reader.contentParams,
                isNovel = true,
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
                            contentError = error.message ?: "Could not load Kanzen novel chapters.",
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
                        contentMessage = "Loading novel chapter $chapterNumber text...",
                        contentError = null,
                        textContent = null,
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
                isNovel = true,
            )?.getOrNull()
            val result = cached?.let(Result.Companion::success) ?: repository.loadKanzenReaderContent(
                moduleId = moduleId,
                chapterParams = chapterParams,
                isNovel = true,
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
                            contentError = error.message ?: "Could not load module chapter text.",
                        )
                    }
                }
            }
        }
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
    moduleId = moduleId,
    contentParams = contentParams,
    sourceName = sourceName,
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
    moduleId = moduleId,
    contentParams = contentParams,
    sourceName = sourceName,
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
        ?: savedItems.firstOrNull { it.id == itemId }
        ?: selectedDetail?.takeIf { it.id == itemId }

private fun NovelScreenState.findCatalogItemByAniListId(aniListId: Int): NovelCatalogItemRow? =
    savedItems.firstOrNull { it.aniListId == aniListId }
        ?: searchResults.firstOrNull { it.aniListId == aniListId }
        ?: catalogs.asSequence()
            .flatMap { section -> section.items.asSequence() }
            .firstOrNull { it.aniListId == aniListId }
        ?: selectedDetail?.takeIf { it.aniListId == aniListId }

private val NovelCatalogItemRow.isKanzenBacked: Boolean
    get() = !moduleId.isNullOrBlank() && moduleId != "anilist" && !contentParams.isNullOrBlank()

private fun NovelCatalogItemRow.withKanzenDetails(details: KanzenCatalogDetailSnapshot): NovelCatalogItemRow {
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

private fun NovelCatalogItemRow.withDetailFieldsFrom(detail: NovelCatalogItemRow): NovelCatalogItemRow = copy(
    title = detail.title.takeIf(String::isNotBlank) ?: title,
    subtitle = detail.subtitle.takeIf(String::isNotBlank) ?: subtitle,
    coverUrl = detail.coverUrl ?: coverUrl,
    description = detail.description ?: description,
    totalChapters = detail.totalChapters ?: totalChapters,
    moduleId = detail.moduleId ?: moduleId,
    contentParams = detail.contentParams ?: contentParams,
    sourceName = detail.sourceName ?: sourceName,
)

private fun NovelScreenState.withUpdatedCatalogItem(
    itemId: String,
    replacement: NovelCatalogItemRow,
): NovelScreenState = copy(
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

private fun NovelScreenState.activeReaderPanelFor(aniListId: Int): NovelReaderPanelRow? =
    reader?.takeIf { it.aniListId == aniListId }
        ?: readerPanelFor(aniListId)

private fun NovelScreenState.readerPanelFor(aniListId: Int): NovelReaderPanelRow? =
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

private fun NovelCatalogItemRow.toReaderPanel(): NovelReaderPanelRow {
    val readCount = readChapterCount.coerceAtLeast(lastReadChapter?.toIntOrNull() ?: 0)
    val current = ((lastReadChapter?.toIntOrNull() ?: readCount) + 1)
        .coerceAtLeast(1)
        .coerceAtMost(totalChapters ?: Int.MAX_VALUE)
    return NovelReaderPanelRow(
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

private fun NovelProgressRow.toReaderPanel(): NovelReaderPanelRow {
    val current = (readChapterCount + 1)
        .coerceAtLeast(1)
        .coerceAtMost(unreadChapterCount?.let { readChapterCount + it } ?: Int.MAX_VALUE)
    val total = unreadChapterCount?.let { readChapterCount + it }
    return NovelReaderPanelRow(
        aniListId = aniListId ?: return NovelReaderPanelRow(
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
): List<NovelReaderChapterRow> {
    val lastChapter = totalChapters?.takeIf { it > 0 }
    val start = (currentChapter - 6).coerceAtLeast(1)
    val end = if (lastChapter != null) {
        (start + 17).coerceAtMost(lastChapter)
    } else {
        start + 17
    }
    return (start..end).map { chapter ->
        NovelReaderChapterRow(
            number = chapter,
            isRead = chapter <= readChapterCount,
            isCurrent = chapter == currentChapter,
        )
    }
}

private val NovelReaderPanelRow.isKanzenBacked: Boolean
    get() = !moduleId.isNullOrBlank() && moduleId != "anilist" && !contentParams.isNullOrBlank()

private fun NovelReaderPanelRow.withKanzenChapters(chapters: List<KanzenReaderChapterSnapshot>): NovelReaderPanelRow {
    if (chapters.isEmpty()) {
        return copy(
            isLoadingChapters = false,
            contentError = "No module chapters were returned for this novel.",
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
            NovelReaderChapterRow(
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

private fun NovelReaderPanelRow.withKanzenContent(
    chapterNumber: Int,
    content: KanzenReaderContentSnapshot,
    markRead: Boolean = true,
): NovelReaderPanelRow = copy(
    currentChapter = chapterNumber,
    isLoadingContent = false,
    contentMessage = content.cacheMessage
        ?: content.text?.takeIf { it.isNotBlank() }?.let { "Chapter text loaded." },
    contentError = if (content.text.isNullOrBlank()) "No text was returned for this chapter." else null,
    textContent = content.text,
    chapters = chapters.map { chapter ->
        chapter.copy(
            isCurrent = chapter.number == chapterNumber,
            isRead = chapter.isRead || (markRead && chapter.number <= chapterNumber),
        )
    },
)

private fun NovelReaderPanelRow.mergeRuntimeState(previous: NovelReaderPanelRow): NovelReaderPanelRow {
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
        textContent = previous.textContent,
    )
}

private fun NovelScreenState.updateReader(
    aniListId: Int,
    transform: (NovelReaderPanelRow) -> NovelReaderPanelRow,
): NovelScreenState = copy(
    reader = reader?.let { current ->
        if (current.aniListId == aniListId) transform(current) else current
    },
)

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
    selectedDetail = selectedDetail?.let { row ->
        if (row.aniListId == aniListId) row.copy(isSaved = isSaved) else row
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
