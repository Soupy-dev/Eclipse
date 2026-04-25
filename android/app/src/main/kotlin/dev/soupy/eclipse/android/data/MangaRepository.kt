package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.KanzenModuleRecord
import dev.soupy.eclipse.android.core.model.AniListMedia
import dev.soupy.eclipse.android.core.model.MangaLibraryItem
import dev.soupy.eclipse.android.core.model.MangaLibraryCollection
import dev.soupy.eclipse.android.core.model.MangaLibrarySnapshot
import dev.soupy.eclipse.android.core.model.MangaProgress
import dev.soupy.eclipse.android.core.model.displayTitle
import dev.soupy.eclipse.android.core.model.posterUrl
import dev.soupy.eclipse.android.core.js.KanzenModuleRuntime
import dev.soupy.eclipse.android.core.js.ModuleManifest
import dev.soupy.eclipse.android.core.js.ServiceSearchResult
import dev.soupy.eclipse.android.core.network.AniListService
import dev.soupy.eclipse.android.core.network.EclipseHttpClient
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.storage.BackupFileStore
import dev.soupy.eclipse.android.core.storage.MangaStore
import dev.soupy.eclipse.android.core.storage.SettingsStore
import java.net.URI
import java.time.Duration
import java.time.Instant
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

private const val DefaultMangaCollectionId = "android-library"
private const val DefaultMangaCollectionName = "Library"
private const val FavoritesCollectionId = "android-favorites"
private const val FavoritesCollectionName = "Favorites"
private val ModuleAutoUpdateInterval: Duration = Duration.ofHours(24)

data class MangaCatalogSectionSnapshot(
    val id: String,
    val title: String,
    val items: List<MangaCatalogItemSnapshot>,
)

data class MangaCatalogItemSnapshot(
    val id: String,
    val aniListId: Int,
    val title: String,
    val subtitle: String,
    val coverUrl: String? = null,
    val description: String? = null,
    val format: String? = null,
    val totalChapters: Int? = null,
    val moduleId: String? = null,
    val contentParams: String? = null,
    val sourceName: String? = null,
    val isSaved: Boolean = false,
    val isFavorite: Boolean = false,
    val readChapterCount: Int = 0,
    val unreadChapterCount: Int? = null,
    val lastReadChapter: String? = null,
)

data class MangaLibraryItemDraft(
    val aniListId: Int,
    val title: String,
    val coverUrl: String? = null,
    val format: String? = null,
    val totalChapters: Int? = null,
    val moduleId: String? = null,
    val contentParams: String? = null,
    val sourceName: String? = null,
)

data class MangaReadingProgressDraft(
    val aniListId: Int,
    val title: String,
    val coverUrl: String? = null,
    val format: String? = null,
    val totalChapters: Int? = null,
    val moduleId: String? = null,
    val contentParams: String? = null,
    val chapterNumber: Int,
    val isNovel: Boolean = false,
)

data class AniListMangaLibraryImportDraft(
    val media: AniListMedia,
    val status: String? = null,
    val progress: Int = 0,
    val progressVolumes: Int = 0,
    val score: Double = 0.0,
    val updatedAtEpochSeconds: Long? = null,
)

data class MangaImportSummary(
    val snapshot: MangaLibrarySnapshot,
    val importedItems: Int,
    val importedProgress: Int,
    val importedNovels: Int,
)

data class KanzenModuleUpdateSummary(
    val snapshot: MangaLibrarySnapshot,
    val checkedModules: Int,
    val updatedModules: Int,
    val failedModules: Int,
)

data class KanzenReaderChapterSnapshot(
    val number: Int,
    val title: String,
    val params: String,
    val sourceName: String? = null,
)

data class KanzenReaderContentSnapshot(
    val chapterParams: String,
    val imageUrls: List<String> = emptyList(),
    val text: String? = null,
    val isCached: Boolean = false,
    val cacheMessage: String? = null,
)

data class KanzenCatalogDetailSnapshot(
    val title: String? = null,
    val subtitle: String? = null,
    val coverUrl: String? = null,
    val description: String? = null,
    val totalChapters: Int? = null,
)

data class KanzenModuleDraft(
    val moduleUrl: String,
    val displayName: String? = null,
    val isNovel: Boolean = false,
)

private data class FetchedKanzenModule(
    val sourceName: String,
    val authorName: String,
    val iconUrl: String?,
    val version: String,
    val language: String,
    val scriptUrl: String,
    val isNovel: Boolean,
    val moduleData: JsonObject,
)

data class MangaOverviewSnapshot(
    val collections: List<MangaLibraryCollection>,
    val recentProgress: List<Pair<String, MangaProgress>>,
    val recentNovelProgress: List<Pair<String, MangaProgress>>,
    val modules: List<KanzenModuleRecord>,
    val catalogs: List<MangaCatalogSectionSnapshot>,
    val savedCount: Int,
    val readChapterCount: Int,
    val novelCount: Int,
    val novelReadChapterCount: Int,
    val progressByAniListId: Map<Int, MangaProgress>,
    val favoriteAniListIds: Set<Int>,
    val importedFromBackup: Boolean,
)

class MangaRepository(
    private val mangaStore: MangaStore,
    private val backupFileStore: BackupFileStore,
    private val aniListService: AniListService,
    private val settingsStore: SettingsStore? = null,
    private val httpClient: EclipseHttpClient = EclipseHttpClient(),
    private val kanzenRuntime: KanzenModuleRuntime? = null,
) {
    suspend fun loadOverview(): Result<MangaOverviewSnapshot> = runCatching {
        coroutineScope {
            val backupDeferred = async { seedFromBackupIfNeeded() }
            val catalogsDeferred = async { aniListService.fetchMangaCatalogs(perPage = 12).orNull() }
            val (seededSnapshot, importedFromBackup) = backupDeferred.await()
            val snapshot = seededSnapshot.autoUpdateModulesIfEnabled(isNovel = false)
            snapshot.toOverview(
                importedFromBackup = importedFromBackup,
                catalogs = catalogsDeferred.await().toCatalogSections(
                    savedAniListIds = snapshot.savedAniListIds(),
                    progressByAniListId = snapshot.progressByAniListId(),
                    favoriteAniListIds = snapshot.favoriteAniListIds(),
                    label = "Manga",
                ),
            )
        }
    }

    suspend fun loadNovelOverview(): Result<MangaOverviewSnapshot> = runCatching {
        coroutineScope {
            val backupDeferred = async { seedFromBackupIfNeeded() }
            val catalogsDeferred = async { aniListService.fetchNovelCatalogs(perPage = 12).orNull() }
            val (seededSnapshot, importedFromBackup) = backupDeferred.await()
            val snapshot = seededSnapshot.autoUpdateModulesIfEnabled(isNovel = true)
            snapshot.toOverview(
                importedFromBackup = importedFromBackup,
                catalogs = catalogsDeferred.await().toCatalogSections(
                    savedAniListIds = snapshot.savedAniListIds(),
                    progressByAniListId = snapshot.progressByAniListId(),
                    favoriteAniListIds = snapshot.favoriteAniListIds(),
                    label = "Novels",
                ),
            )
        }
    }

    suspend fun searchManga(query: String): Result<List<MangaCatalogItemSnapshot>> = runCatching {
        val trimmed = query.trim()
        if (trimmed.isBlank()) return@runCatching emptyList()
        val snapshot = mangaStore.read()
        val aniListResults = aniListService.searchManga(
            query = trimmed,
            page = 1,
            perPage = 24,
        ).orThrow().media.toCatalogItems(
            savedAniListIds = snapshot.savedAniListIds(),
            progressByAniListId = snapshot.progressByAniListId(),
            favoriteAniListIds = snapshot.favoriteAniListIds(),
        )
        aniListResults + snapshot.searchKanzenModules(
            query = trimmed,
            isNovel = false,
        )
    }

    suspend fun searchNovels(query: String): Result<List<MangaCatalogItemSnapshot>> = runCatching {
        val trimmed = query.trim()
        if (trimmed.isBlank()) return@runCatching emptyList()
        val snapshot = mangaStore.read()
        val aniListResults = aniListService.searchNovels(
            query = trimmed,
            page = 1,
            perPage = 24,
        ).orThrow().media.toCatalogItems(
            savedAniListIds = snapshot.savedAniListIds(),
            progressByAniListId = snapshot.progressByAniListId(),
            favoriteAniListIds = snapshot.favoriteAniListIds(),
        )
        aniListResults + snapshot.searchKanzenModules(
            query = trimmed,
            isNovel = true,
        )
    }

    suspend fun saveToLibrary(draft: MangaLibraryItemDraft): Result<MangaLibrarySnapshot> = runCatching {
        require(draft.aniListId != 0) { "Saving manga requires a stable content id." }
        require(draft.title.isNotBlank()) { "Saving manga requires a title." }
        val snapshot = seedFromBackupIfNeeded().first
        val item = MangaLibraryItem(
            aniListId = draft.aniListId,
            title = draft.title,
            coverUrl = draft.coverUrl,
            format = draft.format,
            totalChapters = draft.totalChapters,
            moduleId = draft.moduleId,
            contentParams = draft.contentParams,
            sourceName = draft.sourceName,
            dateAdded = Instant.now().toString(),
        )
        val updated = snapshot.copy(
            collections = snapshot.collections.withSavedManga(item),
        )
        mangaStore.write(updated)
        updated
    }

    suspend fun removeFromLibrary(aniListId: Int): Result<MangaLibrarySnapshot> = runCatching {
        require(aniListId != 0) { "Removing manga requires a stable content id." }
        val snapshot = mangaStore.read()
        val updated = snapshot.copy(
            collections = snapshot.collections.map { collection ->
                collection.copy(items = collection.items.filterNot { item -> item.aniListId == aniListId })
            }.filterNot { collection ->
                collection.id == DefaultMangaCollectionId && collection.items.isEmpty()
            },
        )
        mangaStore.write(updated)
        updated
    }

    suspend fun createCollection(name: String): Result<MangaLibrarySnapshot> = runCatching {
        val trimmed = name.trim()
        require(trimmed.isNotBlank()) { "Collection name is required." }
        val snapshot = seedFromBackupIfNeeded().first
        val existing = snapshot.collections.firstOrNull { collection ->
            collection.name.equals(trimmed, ignoreCase = true)
        }
        if (existing != null) return@runCatching snapshot
        val collection = MangaLibraryCollection(
            id = "android-collection-${trimmed.hashCode().toUInt().toString(16)}",
            name = trimmed,
            description = "Created on Android",
            items = emptyList(),
        )
        val updated = snapshot.copy(collections = snapshot.collections + collection)
        mangaStore.write(updated)
        updated
    }

    suspend fun deleteCollection(collectionId: String): Result<MangaLibrarySnapshot> = runCatching {
        require(collectionId.isNotBlank()) { "Collection id is required." }
        require(!collectionId.isSystemMangaCollectionId()) { "System collections cannot be deleted." }
        val snapshot = seedFromBackupIfNeeded().first
        val updated = snapshot.copy(
            collections = snapshot.collections.filterNot { collection -> collection.id == collectionId },
        )
        mangaStore.write(updated)
        updated
    }

    suspend fun addToCollection(
        collectionId: String,
        aniListId: Int,
    ): Result<MangaLibrarySnapshot> = runCatching {
        require(collectionId.isNotBlank()) { "Collection id is required." }
        require(aniListId != 0) { "Adding to a collection requires a stable content id." }
        val snapshot = seedFromBackupIfNeeded().first
        val item = snapshot.findMangaItem(aniListId)
            ?: error("Save this title before adding it to a collection.")
        val target = snapshot.collections.firstOrNull { collection -> collection.id == collectionId }
            ?: error("Collection was not found.")
        val updated = snapshot.copy(
            collections = snapshot.collections.map { collection ->
                if (collection.id == target.id) {
                    collection.copy(items = listOf(item) + collection.items.filterNot { it.aniListId == aniListId })
                } else {
                    collection
                }
            },
        )
        mangaStore.write(updated)
        updated
    }

    suspend fun removeFromCollection(
        collectionId: String,
        aniListId: Int,
    ): Result<MangaLibrarySnapshot> = runCatching {
        require(collectionId.isNotBlank()) { "Collection id is required." }
        require(!collectionId.isSystemMangaCollectionId()) { "Remove items from the library or favorites controls for system collections." }
        require(aniListId != 0) { "Removing from a collection requires a stable content id." }
        val snapshot = seedFromBackupIfNeeded().first
        val updated = snapshot.copy(
            collections = snapshot.collections.map { collection ->
                if (collection.id == collectionId) {
                    collection.copy(items = collection.items.filterNot { item -> item.aniListId == aniListId })
                } else {
                    collection
                }
            },
        )
        mangaStore.write(updated)
        updated
    }

    suspend fun markNextChapterRead(aniListId: Int): Result<MangaLibrarySnapshot> = runCatching {
        require(aniListId != 0) { "Reading progress requires a stable content id." }
        val snapshot = seedFromBackupIfNeeded().first
        val item = snapshot.findMangaItem(aniListId)
            ?: error("Save this title before tracking chapter progress.")
        val existing = snapshot.progressByAniListId()[aniListId]
        val nextChapter = ((existing?.lastReadChapterNumber() ?: 0) + 1)
            .coerceAtMost(item.totalChapters ?: Int.MAX_VALUE)
        require(nextChapter > 0) { "No readable chapter was found." }
        val updated = snapshot.writeProgressSnapshot(
            MangaReadingProgressDraft(
                aniListId = item.aniListId,
                title = item.title,
                coverUrl = item.coverUrl,
                format = item.format,
                totalChapters = item.totalChapters,
                moduleId = item.moduleId,
                contentParams = item.contentParams,
                chapterNumber = nextChapter,
                isNovel = item.isNovelItem,
            ),
        )
        mangaStore.write(updated)
        updated
    }

    suspend fun markPreviousChapterUnread(aniListId: Int): Result<MangaLibrarySnapshot> = runCatching {
        require(aniListId != 0) { "Reading progress requires a stable content id." }
        val snapshot = seedFromBackupIfNeeded().first
        val item = snapshot.findMangaItem(aniListId)
        val existing = snapshot.progressByAniListId()[aniListId]
            ?: return@runCatching snapshot
        val previousChapter = (existing.lastReadChapterNumber() - 1).coerceAtLeast(0)
        val updated = if (previousChapter <= 0) {
            snapshot.copy(readingProgress = snapshot.readingProgress - aniListId.mangaProgressId())
        } else {
            snapshot.writeProgressSnapshot(
                MangaReadingProgressDraft(
                    aniListId = aniListId,
                    title = existing.title ?: item?.title ?: "Manga $aniListId",
                    coverUrl = existing.coverUrl ?: item?.coverUrl,
                    format = existing.format ?: item?.format,
                    totalChapters = existing.totalChapters ?: item?.totalChapters,
                    moduleId = existing.moduleUUID ?: item?.moduleId,
                    contentParams = existing.contentParams ?: item?.contentParams,
                    chapterNumber = previousChapter,
                    isNovel = existing.isNovel == true || item?.isNovelItem == true,
                ),
            )
        }
        mangaStore.write(updated)
        updated
    }

    suspend fun recordReadingProgress(draft: MangaReadingProgressDraft): Result<MangaLibrarySnapshot> = runCatching {
        require(draft.aniListId != 0) { "Reading progress requires a stable content id." }
        require(draft.chapterNumber > 0) { "Chapter number must be greater than zero." }
        val snapshot = seedFromBackupIfNeeded().first
        val updated = snapshot.writeProgressSnapshot(draft)
        mangaStore.write(updated)
        updated
    }

    suspend fun toggleFavorite(aniListId: Int): Result<MangaLibrarySnapshot> = runCatching {
        require(aniListId != 0) { "Favorites require a stable content id." }
        val snapshot = seedFromBackupIfNeeded().first
        val item = snapshot.findMangaItem(aniListId)
            ?: error("Save this title before favoriting it.")
        val favoriteIds = snapshot.favoriteAniListIds()
        val updatedCollections = if (aniListId in favoriteIds) {
            snapshot.collections.map { collection ->
                if (collection.id == FavoritesCollectionId) {
                    collection.copy(items = collection.items.filterNot { it.aniListId == aniListId })
                } else {
                    collection
                }
            }.filterNot { collection ->
                collection.id == FavoritesCollectionId && collection.items.isEmpty()
            }
        } else {
            snapshot.collections.withFavoriteManga(item)
        }
        val updated = snapshot.copy(collections = updatedCollections)
        mangaStore.write(updated)
        updated
    }

    suspend fun importAniListManga(drafts: List<AniListMangaLibraryImportDraft>): Result<MangaImportSummary> = runCatching {
        val snapshot = seedFromBackupIfNeeded().first
        val uniqueDrafts = drafts
            .filter { draft -> draft.media.id > 0 }
            .distinctBy { draft -> draft.media.id }
        val importedItems = uniqueDrafts.map(AniListMangaLibraryImportDraft::toMangaLibraryItem)
        val importedProgress = uniqueDrafts.mapNotNull(AniListMangaLibraryImportDraft::toReadingProgressEntry)
        val updatedProgress = snapshot.readingProgress
            .filterKeys { key -> importedProgress.none { (id, _) -> id == key } } +
            importedProgress.toMap()
        val updated = snapshot.copy(
            collections = snapshot.collections.withImportedManga(importedItems),
            readingProgress = updatedProgress,
        )
        mangaStore.write(updated)
        MangaImportSummary(
            snapshot = updated,
            importedItems = importedItems.size,
            importedProgress = importedProgress.size,
            importedNovels = importedItems.count(MangaLibraryItem::isNovelItem),
        )
    }

    suspend fun clearReadingProgress(progressId: String): Result<MangaLibrarySnapshot> = runCatching {
        require(progressId.isNotBlank()) { "Reading progress id is required." }
        val snapshot = seedFromBackupIfNeeded().first
        val updated = snapshot.copy(
            readingProgress = snapshot.readingProgress - progressId,
        )
        mangaStore.write(updated)
        updated
    }

    suspend fun addModule(draft: KanzenModuleDraft): Result<MangaLibrarySnapshot> = runCatching {
        val normalizedUrl = draft.moduleUrl.normalizedKanzenModuleUrl()
        val snapshot = seedFromBackupIfNeeded().first
        val manifest = fetchAndValidateKanzenModule(
            httpClient = httpClient,
            moduleUrl = normalizedUrl,
            requestedNovel = draft.isNovel,
            displayNameOverride = draft.displayName,
        )
        val existing = snapshot.modules.firstOrNull { module ->
            module.moduleUrl.equals(normalizedUrl, ignoreCase = true) ||
                module.scriptUrl.equals(manifest.scriptUrl, ignoreCase = true)
        }
        val id = existing?.id?.takeIf(String::isNotBlank) ?: normalizedUrl.toModuleId()
        val record = KanzenModuleRecord(
            id = id,
            sourceName = manifest.sourceName,
            authorName = manifest.authorName,
            iconUrl = manifest.iconUrl,
            version = manifest.version,
            language = manifest.language,
            scriptUrl = manifest.scriptUrl,
            isNovel = manifest.isNovel,
            localPath = existing?.localPath,
            moduleUrl = normalizedUrl,
            isActive = true,
            moduleData = manifest.moduleData,
        )
        val updated = snapshot.copy(
            modules = listOf(record) + snapshot.modules.filterNot { module ->
                module.id == id ||
                    module.moduleUrl.equals(normalizedUrl, ignoreCase = true) ||
                    module.scriptUrl.equals(manifest.scriptUrl, ignoreCase = true)
            },
        )
        mangaStore.write(updated)
        updated
    }

    suspend fun setModuleActive(
        moduleId: String,
        active: Boolean,
    ): Result<MangaLibrarySnapshot> = runCatching {
        require(moduleId.isNotBlank()) { "Module id is required." }
        val snapshot = seedFromBackupIfNeeded().first
        val updated = snapshot.copy(
            modules = snapshot.modules.map { module ->
                if (module.id == moduleId) module.copy(isActive = active) else module
            },
        )
        mangaStore.write(updated)
        updated
    }

    suspend fun removeModule(moduleId: String): Result<MangaLibrarySnapshot> = runCatching {
        require(moduleId.isNotBlank()) { "Module id is required." }
        val snapshot = seedFromBackupIfNeeded().first
        val updated = snapshot.copy(
            modules = snapshot.modules.filterNot { module -> module.id == moduleId },
        )
        mangaStore.write(updated)
        updated
    }

    suspend fun updateModule(moduleId: String): Result<MangaLibrarySnapshot> = runCatching {
        require(moduleId.isNotBlank()) { "Module id is required." }
        val snapshot = seedFromBackupIfNeeded().first
        val existing = snapshot.modules.firstOrNull { module -> module.id == moduleId }
            ?: error("Kanzen module was not found.")
        val refreshed = existing.refreshedModule()
        val updated = snapshot.copy(
            modules = listOf(refreshed) + snapshot.modules.filterNot { module -> module.id == moduleId },
        )
        mangaStore.write(updated)
        updated
    }

    suspend fun updateModules(isNovel: Boolean? = null): Result<KanzenModuleUpdateSummary> = runCatching {
        seedFromBackupIfNeeded().first.updateModules(
            isNovel = isNovel,
            onlyDue = false,
        )
    }

    suspend fun loadKanzenCatalogDetails(
        moduleId: String?,
        contentParams: String?,
        isNovel: Boolean,
    ): Result<KanzenCatalogDetailSnapshot> = runCatching {
        val runtime = kanzenRuntime ?: error("Kanzen runtime is not available on this device.")
        require(!moduleId.isNullOrBlank() && moduleId != "anilist") { "This title is not backed by a Kanzen module." }
        require(!contentParams.isNullOrBlank()) { "This title does not have module content parameters." }
        val module = mangaStore.read().modules.firstOrNull { record ->
            record.id == moduleId && record.isActive && record.isNovel == isNovel
        } ?: error("Kanzen module is not installed or active.")
        val manifest = module.loadIntoRuntime(runtime)
        val details = runtime.details(
            module = manifest,
            params = JsonPrimitive(contentParams),
        ).getOrThrow().detailsPayload()
        KanzenCatalogDetailSnapshot(
            title = details.firstString("title", "name", "englishTitle", "romajiTitle"),
            subtitle = details.firstString("subtitle", "author", "artist", "status", "year"),
            coverUrl = details.firstString(
                "imageURL",
                "imageUrl",
                "image",
                "coverURL",
                "coverUrl",
                "cover",
                "thumbnail",
            ),
            description = details.firstString("description", "synopsis", "summary", "plot"),
            totalChapters = details.firstInt("totalChapters", "chapterCount", "chapters", "episodes"),
        )
    }

    suspend fun loadKanzenReaderChapters(
        moduleId: String?,
        contentParams: String?,
        isNovel: Boolean,
    ): Result<List<KanzenReaderChapterSnapshot>> = runCatching {
        val runtime = kanzenRuntime ?: error("Kanzen runtime is not available on this device.")
        require(!moduleId.isNullOrBlank() && moduleId != "anilist") { "This title is not backed by a Kanzen module." }
        require(!contentParams.isNullOrBlank()) { "This title does not have module content parameters." }
        val module = mangaStore.read().modules.firstOrNull { record ->
            record.id == moduleId && record.isActive && record.isNovel == isNovel
        } ?: error("Kanzen module is not installed or active.")
        val manifest = module.loadIntoRuntime(runtime)
        runtime.chapters(
            module = manifest,
            params = JsonPrimitive(contentParams),
        ).getOrThrow()
            .mapIndexed { index, chapter ->
                KanzenReaderChapterSnapshot(
                    number = chapter.episodeNumber ?: index + 1,
                    title = chapter.title.ifBlank { "Chapter ${chapter.episodeNumber ?: index + 1}" },
                    params = chapter.href,
                    sourceName = chapter.metadata.string("scanlation_group")
                        ?: chapter.metadata.string("sourceName")
                        ?: module.displayName,
                )
            }
            .distinctBy { chapter -> chapter.params }
    }

    suspend fun loadKanzenReaderContent(
        moduleId: String?,
        chapterParams: String?,
        isNovel: Boolean,
    ): Result<KanzenReaderContentSnapshot> = runCatching {
        val runtime = kanzenRuntime ?: error("Kanzen runtime is not available on this device.")
        require(!moduleId.isNullOrBlank() && moduleId != "anilist") { "This title is not backed by a Kanzen module." }
        require(!chapterParams.isNullOrBlank()) { "Choose a module chapter first." }
        val module = mangaStore.read().modules.firstOrNull { record ->
            record.id == moduleId && record.isActive && record.isNovel == isNovel
        } ?: error("Kanzen module is not installed or active.")
        val manifest = module.loadIntoRuntime(runtime)
        val params = JsonPrimitive(chapterParams)
        if (isNovel) {
            KanzenReaderContentSnapshot(
                chapterParams = chapterParams,
                text = runtime.text(manifest, params).getOrThrow()
                    .takeIf { text -> text.isNotBlank() && text != "undefined" },
            )
        } else {
            KanzenReaderContentSnapshot(
                chapterParams = chapterParams,
                imageUrls = runtime.images(manifest, params).getOrThrow()
                    .filter(String::isNotBlank),
            )
        }
    }

    private suspend fun MangaLibrarySnapshot.searchKanzenModules(
        query: String,
        isNovel: Boolean,
    ): List<MangaCatalogItemSnapshot> {
        val runtime = kanzenRuntime ?: return emptyList()
        val savedIds = savedAniListIds()
        val progress = progressByAniListId()
        val favorites = favoriteAniListIds()
        val activeModules = modules.filter { module ->
            module.isActive &&
                module.isNovel == isNovel &&
                !module.scriptUrl.isNullOrBlank()
        }
        if (activeModules.isEmpty()) return emptyList()

        return coroutineScope {
            activeModules.map { module ->
                async {
                    runCatching {
                        val runtimeManifest = module.loadIntoRuntime(runtime)
                        runtime.search(
                            module = runtimeManifest,
                            query = query,
                            page = 0,
                        ).getOrThrow()
                            .map { result ->
                                result.toKanzenCatalogItem(
                                    module = module,
                                    savedAniListIds = savedIds,
                                    progressByAniListId = progress,
                                    favoriteAniListIds = favorites,
                                    isNovel = isNovel,
                                )
                            }
                    }.getOrDefault(emptyList())
                }
            }.flatMap { deferred -> deferred.await() }
                .distinctBy { item -> item.aniListId }
                .take(24)
        }
    }

    private suspend fun KanzenModuleRecord.loadIntoRuntime(runtime: KanzenModuleRuntime): ModuleManifest {
        require(!scriptUrl.isNullOrBlank()) { "Kanzen module ${displayName} does not have a script URL." }
        val runtimeManifest = toRuntimeManifest()
        val script = httpClient.get(scriptUrl.orEmpty()).orThrow()
        runtime.load(
            module = runtimeManifest,
            script = script,
            isNovel = isNovel,
        ).getOrThrow()
        return runtimeManifest
    }

    private suspend fun seedFromBackupIfNeeded(): Pair<MangaLibrarySnapshot, Boolean> {
        val current = mangaStore.read()
        if (current.hasUserData) {
            return current to false
        }

        val imported = backupFileStore.read()
            ?.payload
            ?.toMangaLibrarySnapshot()
            ?.takeIf(MangaLibrarySnapshot::hasUserData)
            ?: return current to false

        mangaStore.write(imported)
        return imported to true
    }

    private suspend fun MangaLibrarySnapshot.autoUpdateModulesIfEnabled(isNovel: Boolean): MangaLibrarySnapshot {
        val enabled = settingsStore?.settings?.first()?.kanzenAutoUpdateModules ?: false
        if (!enabled) return this
        return runCatching {
            updateModules(isNovel = isNovel, onlyDue = true).snapshot
        }.getOrDefault(this)
    }

    private suspend fun MangaLibrarySnapshot.updateModules(
        isNovel: Boolean?,
        onlyDue: Boolean,
    ): KanzenModuleUpdateSummary {
        val candidates = modules.filter { module ->
            (isNovel == null || module.isNovel == isNovel) &&
                module.updateUrlOrNull() != null &&
                (!onlyDue || module.isDueForAutoUpdate())
        }
        if (candidates.isEmpty()) {
            return KanzenModuleUpdateSummary(
                snapshot = this,
                checkedModules = 0,
                updatedModules = 0,
                failedModules = 0,
            )
        }

        var updatedModules = modules
        var updatedCount = 0
        var failedCount = 0
        candidates.forEach { module ->
            runCatching { module.refreshedModule() }
                .onSuccess { refreshed ->
                    updatedCount += 1
                    updatedModules = updatedModules.map { current ->
                        if (current.id == module.id) refreshed else current
                    }
                }
                .onFailure {
                    failedCount += 1
                }
        }

        val updated = copy(modules = updatedModules)
        mangaStore.write(updated)
        return KanzenModuleUpdateSummary(
            snapshot = updated,
            checkedModules = candidates.size,
            updatedModules = updatedCount,
            failedModules = failedCount,
        )
    }

    private suspend fun KanzenModuleRecord.refreshedModule(): KanzenModuleRecord {
        val moduleUrl = updateUrlOrNull() ?: error("Kanzen module does not have an update URL.")
        val normalizedUrl = moduleUrl.normalizedKanzenModuleUrl()
        val manifest = fetchAndValidateKanzenModule(
            httpClient = httpClient,
            moduleUrl = normalizedUrl,
            requestedNovel = isNovel,
            displayNameOverride = null,
        )
        val now = Instant.now().toString()
        return copy(
            sourceName = manifest.sourceName,
            authorName = manifest.authorName,
            iconUrl = manifest.iconUrl,
            version = manifest.version,
            language = manifest.language,
            scriptUrl = manifest.scriptUrl,
            isNovel = manifest.isNovel,
            moduleUrl = normalizedUrl,
            moduleData = manifest.moduleData.withAndroidUpdateMetadata(now),
        )
    }
}

private suspend fun fetchAndValidateKanzenModule(
    httpClient: EclipseHttpClient,
    moduleUrl: String,
    requestedNovel: Boolean,
    displayNameOverride: String?,
): FetchedKanzenModule {
    val manifestRaw = httpClient.get(moduleUrl).orThrow()
    val manifestJson = runCatching {
        EclipseJson.parseToJsonElement(manifestRaw).jsonObject
    }.getOrElse { error ->
        throw SerializationException("Kanzen module manifest is not valid JSON.", error)
    }
    val scriptUrl = manifestJson.scriptUrl()
        ?.resolveAgainst(moduleUrl)
        ?: error("Kanzen module manifest is missing scriptURL.")
    val script = httpClient.get(scriptUrl).orThrow()
    script.validateKanzenScript()

    val author = manifestJson.getObject("author")
    val sourceName = displayNameOverride?.trim()?.takeIf(String::isNotBlank)
        ?: manifestJson.string("sourceName")
        ?: moduleUrl.toModuleDisplayName()
    val isNovel = manifestJson.boolean("novel") ?: requestedNovel
    val moduleData = manifestJson.withModuleMetadata(
        sourceName = sourceName,
        moduleUrl = moduleUrl,
        scriptUrl = scriptUrl,
        isNovel = isNovel,
    )
    return FetchedKanzenModule(
        sourceName = sourceName,
        authorName = author?.string("name").orEmpty(),
        iconUrl = manifestJson.string("iconURL")
            ?: manifestJson.string("iconUrl")
            ?: author?.string("iconURL")
            ?: author?.string("icon"),
        version = manifestJson.string("version").orEmpty(),
        language = manifestJson.string("language").orEmpty(),
        scriptUrl = scriptUrl,
        isNovel = isNovel,
        moduleData = moduleData,
    )
}

private fun MangaLibrarySnapshot.toOverview(
    importedFromBackup: Boolean,
    catalogs: List<MangaCatalogSectionSnapshot>,
): MangaOverviewSnapshot {
    val progressEntries = readingProgress.entries
        .sortedByDescending { (_, progress) -> progress.lastReadDate.orEmpty() }
        .take(8)
    val novelProgressEntries = readingProgress.entries
        .filter { (_, progress) -> progress.isNovelProgress }
        .sortedByDescending { (_, progress) -> progress.lastReadDate.orEmpty() }
        .take(8)
    val allNovelProgress = readingProgress.values.filter(MangaProgress::isNovelProgress)
    val progressByAniListId = progressByAniListId()
    val favoriteAniListIds = favoriteAniListIds()

    return MangaOverviewSnapshot(
        collections = collections,
        recentProgress = progressEntries.map { (id, progress) -> id to progress },
        recentNovelProgress = novelProgressEntries.map { (id, progress) -> id to progress },
        modules = modules,
        catalogs = catalogs,
        savedCount = collections.flatMap(MangaLibraryCollection::items)
            .distinctBy { item -> item.aniListId }
            .size,
        readChapterCount = readingProgress.values.sumOf { progress -> progress.readChapterNumbers.size },
        novelCount = allNovelProgress.size,
        novelReadChapterCount = allNovelProgress.sumOf { progress -> progress.readChapterNumbers.size },
        progressByAniListId = progressByAniListId,
        favoriteAniListIds = favoriteAniListIds,
        importedFromBackup = importedFromBackup,
    )
}

private val MangaProgress.isNovelProgress: Boolean
    get() = isNovel == true || format.equals("NOVEL", ignoreCase = true) || format.equals("LIGHT_NOVEL", ignoreCase = true)

private fun KanzenModuleRecord.toRuntimeManifest(): ModuleManifest = ModuleManifest(
    id = id.ifBlank { moduleUrl ?: scriptUrl ?: displayName },
    name = displayName,
    version = version,
    entrypoint = scriptUrl,
)

private fun ServiceSearchResult.toKanzenCatalogItem(
    module: KanzenModuleRecord,
    savedAniListIds: Set<Int>,
    progressByAniListId: Map<Int, MangaProgress>,
    favoriteAniListIds: Set<Int>,
    isNovel: Boolean,
): MangaCatalogItemSnapshot {
    val stableId = module.stableContentId(href)
    val progress = progressByAniListId[stableId]
    val readCount = progress?.readChapterNumbers?.size ?: 0
    return MangaCatalogItemSnapshot(
        id = "kanzen-${module.id.toKanzenSearchIdStem()}-${stableId.toString().removePrefix("-")}",
        aniListId = stableId,
        title = title,
        subtitle = listOfNotNull(
            module.displayName,
            subtitle,
            if (isNovel) "Novel module" else "Manga module",
        ).joinToString(" - "),
        coverUrl = image,
        description = subtitle,
        format = if (isNovel) "NOVEL" else "MANGA",
        moduleId = module.id,
        contentParams = href,
        sourceName = module.displayName,
        isSaved = stableId in savedAniListIds,
        isFavorite = stableId in favoriteAniListIds,
        readChapterCount = readCount,
        unreadChapterCount = progress?.totalChapters?.let { (it - readCount).coerceAtLeast(0) },
        lastReadChapter = progress?.lastReadChapter,
    )
}

private fun KanzenModuleRecord.stableContentId(contentParams: String): Int {
    val positive = "$id:$contentParams".hashCode() and Int.MAX_VALUE
    return -positive.coerceAtLeast(1)
}

private fun KanzenModuleRecord.updateUrlOrNull(): String? =
    moduleUrl
        ?: moduleData.jsonObjectOrNull()?.string("moduleURL")
        ?: moduleData.jsonObjectOrNull()?.string("moduleUrl")

private fun KanzenModuleRecord.isDueForAutoUpdate(now: Instant = Instant.now()): Boolean {
    val lastChecked = moduleData.jsonObjectOrNull()
        ?.string("androidLastCheckedAt")
        ?.let { value -> runCatching { Instant.parse(value) }.getOrNull() }
        ?: return true
    return lastChecked.plus(ModuleAutoUpdateInterval).isBefore(now)
}

private fun AniListService.MangaCatalogs?.toCatalogSections(
    savedAniListIds: Set<Int>,
    progressByAniListId: Map<Int, MangaProgress> = emptyMap(),
    favoriteAniListIds: Set<Int> = emptySet(),
    label: String,
): List<MangaCatalogSectionSnapshot> =
    listOfNotNull(
        this?.trending?.toCatalogSection("trending", "Trending $label", savedAniListIds, progressByAniListId, favoriteAniListIds),
        this?.popular?.toCatalogSection("popular", "Popular $label", savedAniListIds, progressByAniListId, favoriteAniListIds),
        this?.topRated?.toCatalogSection("top-rated", "Top Rated $label", savedAniListIds, progressByAniListId, favoriteAniListIds),
        this?.recentlyUpdated?.toCatalogSection("updated", "Recently Updated", savedAniListIds, progressByAniListId, favoriteAniListIds),
    ).filter { it.items.isNotEmpty() }

private fun List<AniListMedia>.toCatalogSection(
    id: String,
    title: String,
    savedAniListIds: Set<Int>,
    progressByAniListId: Map<Int, MangaProgress>,
    favoriteAniListIds: Set<Int>,
): MangaCatalogSectionSnapshot = MangaCatalogSectionSnapshot(
    id = id,
    title = title,
    items = take(12).toCatalogItems(savedAniListIds, progressByAniListId, favoriteAniListIds),
)

private fun List<AniListMedia>.toCatalogItems(
    savedAniListIds: Set<Int>,
    progressByAniListId: Map<Int, MangaProgress> = emptyMap(),
    favoriteAniListIds: Set<Int> = emptySet(),
): List<MangaCatalogItemSnapshot> =
    map { media ->
        val progress = progressByAniListId[media.id]
        val readCount = progress?.readChapterNumbers?.size ?: 0
        MangaCatalogItemSnapshot(
            id = "anilist-manga-${media.id}",
            aniListId = media.id,
            title = media.displayTitle,
            subtitle = listOfNotNull(
                media.format?.replace('_', ' '),
                media.chapters?.let { "$it chapters" },
                media.volumes?.let { "$it volumes" },
                media.status?.replace('_', ' '),
            ).joinToString(" - "),
            coverUrl = media.posterUrl,
            description = media.description?.stripHtmlTags(),
            format = media.format,
            totalChapters = media.chapters,
            isSaved = media.id in savedAniListIds,
            isFavorite = media.id in favoriteAniListIds,
            readChapterCount = readCount,
            unreadChapterCount = media.chapters?.let { (it - readCount).coerceAtLeast(0) },
            lastReadChapter = progress?.lastReadChapter,
        )
    }

private fun MangaLibrarySnapshot.savedAniListIds(): Set<Int> =
    collections.flatMap(MangaLibraryCollection::items)
        .map(MangaLibraryItem::aniListId)
        .toSet()

private fun MangaLibrarySnapshot.favoriteAniListIds(): Set<Int> =
    collections.firstOrNull { collection ->
        collection.id == FavoritesCollectionId || collection.name.equals(FavoritesCollectionName, ignoreCase = true)
    }?.items.orEmpty()
        .map(MangaLibraryItem::aniListId)
        .toSet()

private fun MangaLibrarySnapshot.progressByAniListId(): Map<Int, MangaProgress> =
    readingProgress.mapNotNull { (id, progress) ->
        val aniListId = progress.contentParams?.substringAfter("anilist:", missingDelimiterValue = "")
            ?.toIntOrNull()
            ?: id.substringAfter("anilist-manga:", missingDelimiterValue = "").toIntOrNull()
            ?: id.toIntOrNull()
        aniListId?.let { it to progress }
    }.toMap()

private fun MangaLibrarySnapshot.findMangaItem(aniListId: Int): MangaLibraryItem? =
    collections.asSequence()
        .flatMap { collection -> collection.items.asSequence() }
        .firstOrNull { item -> item.aniListId == aniListId }

private fun MangaLibrarySnapshot.writeProgressSnapshot(draft: MangaReadingProgressDraft): MangaLibrarySnapshot {
    val chapterNumber = draft.chapterNumber.coerceAtLeast(1)
    val chapters = (1..chapterNumber.coerceAtMost(20_000)).map(Int::toString).toSet()
    val now = Instant.now().toString()
    val progress = MangaProgress(
        readChapterNumbers = chapters,
        lastReadChapter = chapterNumber.toString(),
        lastReadDate = now,
        title = draft.title,
        coverUrl = draft.coverUrl,
        format = draft.format,
        totalChapters = draft.totalChapters,
        moduleUUID = draft.moduleId ?: "anilist",
        contentParams = draft.contentParams ?: "anilist:${draft.aniListId}",
        isNovel = draft.isNovel,
    )
    return copy(readingProgress = readingProgress + (draft.aniListId.mangaProgressId() to progress))
}

private fun String.toKanzenSearchIdStem(): String =
    replace(Regex("[^A-Za-z0-9._-]+"), "_")
        .trim('_')
        .ifBlank { "module" }

private fun MangaProgress.lastReadChapterNumber(): Int =
    lastReadChapter?.toIntOrNull()
        ?: readChapterNumbers.mapNotNull(String::toIntOrNull).maxOrNull()
        ?: 0

private fun Int.mangaProgressId(): String = "anilist-manga:$this"

private fun String.isSystemMangaCollectionId(): Boolean =
    equals(DefaultMangaCollectionId, ignoreCase = true) ||
        equals(FavoritesCollectionId, ignoreCase = true)

private fun AniListMangaLibraryImportDraft.toMangaLibraryItem(): MangaLibraryItem {
    val updatedAt = updatedAtEpochSeconds?.takeIf { it > 0 }?.let { Instant.ofEpochSecond(it).toString() }
        ?: Instant.now().toString()
    return MangaLibraryItem(
        aniListId = media.id,
        title = media.displayTitle,
        coverUrl = media.posterUrl,
        format = media.format,
        totalChapters = media.chapters,
        dateAdded = updatedAt,
    )
}

private fun AniListMangaLibraryImportDraft.toReadingProgressEntry(): Pair<String, MangaProgress>? {
    val readChapter = progress.takeIf { it > 0 } ?: return null
    val totalChapters = media.chapters
    val updatedAt = updatedAtEpochSeconds?.takeIf { it > 0 }?.let { Instant.ofEpochSecond(it).toString() }
        ?: Instant.now().toString()
    val chapters = (1..readChapter.coerceAtMost(20_000)).map(Int::toString).toSet()
    val progress = MangaProgress(
        readChapterNumbers = chapters,
        lastReadChapter = readChapter.toString(),
        lastReadDate = updatedAt,
        title = media.displayTitle,
        coverUrl = media.posterUrl,
        format = media.format,
        totalChapters = totalChapters,
        moduleUUID = "anilist",
        contentParams = "anilist:${media.id}",
        isNovel = media.isNovelMedia,
    )
    return media.mangaProgressId to progress
}

private val AniListMedia.mangaProgressId: String
    get() = "anilist-manga:$id"

private val AniListMedia.isNovelMedia: Boolean
    get() = format.equals("NOVEL", ignoreCase = true) ||
        format.equals("LIGHT_NOVEL", ignoreCase = true)

private val MangaLibraryItem.isNovelItem: Boolean
    get() = format.equals("NOVEL", ignoreCase = true) ||
        format.equals("LIGHT_NOVEL", ignoreCase = true)

private fun List<MangaLibraryCollection>.withImportedManga(
    items: List<MangaLibraryItem>,
): List<MangaLibraryCollection> {
    if (items.isEmpty()) return this
    val importedIds = items.map(MangaLibraryItem::aniListId).toSet()
    val targetIndex = indexOfFirst { collection ->
        collection.id == DefaultMangaCollectionId ||
            collection.name.equals(DefaultMangaCollectionName, ignoreCase = true)
    }
    val target = if (targetIndex >= 0) {
        this[targetIndex].copy(
            id = this[targetIndex].id.ifBlank { DefaultMangaCollectionId },
            items = items + this[targetIndex].items.filterNot { existing -> existing.aniListId in importedIds },
        )
    } else {
        MangaLibraryCollection(
            id = DefaultMangaCollectionId,
            name = DefaultMangaCollectionName,
            description = "Imported from AniList on Android",
            items = items,
        )
    }

    return if (targetIndex >= 0) {
        mapIndexed { index, collection ->
            if (index == targetIndex) target else collection
        }
    } else {
        listOf(target) + this
    }
}

private fun List<MangaLibraryCollection>.withFavoriteManga(
    item: MangaLibraryItem,
): List<MangaLibraryCollection> {
    val existingIndex = indexOfFirst { collection ->
        collection.id == FavoritesCollectionId ||
            collection.name.equals(FavoritesCollectionName, ignoreCase = true)
    }
    val favoriteCollection = if (existingIndex >= 0) {
        this[existingIndex].copy(
            id = FavoritesCollectionId,
            name = FavoritesCollectionName,
            items = listOf(item) + this[existingIndex].items.filterNot { existing -> existing.aniListId == item.aniListId },
        )
    } else {
        MangaLibraryCollection(
            id = FavoritesCollectionId,
            name = FavoritesCollectionName,
            description = "Bookmarked on Android",
            items = listOf(item),
        )
    }

    return if (existingIndex >= 0) {
        mapIndexed { index, collection ->
            if (index == existingIndex) favoriteCollection else collection
        }
    } else {
        listOf(favoriteCollection) + this
    }
}

private fun List<MangaLibraryCollection>.withSavedManga(
    item: MangaLibraryItem,
): List<MangaLibraryCollection> {
    val withoutDuplicate = map { collection ->
        collection.copy(items = collection.items.filterNot { existing -> existing.aniListId == item.aniListId })
    }
    val existingIndex = withoutDuplicate.indexOfFirst { collection ->
        collection.id == DefaultMangaCollectionId || collection.name.equals(DefaultMangaCollectionName, ignoreCase = true)
    }
    val targetCollection = if (existingIndex >= 0) {
        withoutDuplicate[existingIndex].copy(
            id = withoutDuplicate[existingIndex].id.ifBlank { DefaultMangaCollectionId },
            items = listOf(item) + withoutDuplicate[existingIndex].items,
        )
    } else {
        MangaLibraryCollection(
            id = DefaultMangaCollectionId,
            name = DefaultMangaCollectionName,
            description = "Saved on Android",
            items = listOf(item),
        )
    }

    return if (existingIndex >= 0) {
        withoutDuplicate.mapIndexed { index, collection ->
            if (index == existingIndex) targetCollection else collection
        }
    } else {
        listOf(targetCollection) + withoutDuplicate
    }
}

private fun String.normalizedKanzenModuleUrl(): String {
    val trimmed = trim()
    require(trimmed.isNotBlank()) { "Paste a Kanzen module URL first." }
    val uri = runCatching { URI(trimmed) }.getOrElse {
        throw IllegalArgumentException("Kanzen module URL is not valid.")
    }
    val scheme = uri.scheme?.lowercase()
    require(scheme == "http" || scheme == "https") { "Kanzen modules must use http or https URLs." }
    require(!uri.host.isNullOrBlank()) { "Kanzen module URL needs a host." }
    return uri.normalize().toString().trimEnd('/')
}

private fun String.toModuleId(): String =
    "kanzen-${hashCode().toUInt().toString(16)}"

private fun String.toModuleDisplayName(): String {
    val uri = runCatching { URI(this) }.getOrNull()
    val pathName = uri?.path
        ?.substringAfterLast('/')
        ?.substringBeforeLast('.')
        ?.takeIf(String::isNotBlank)
    return pathName ?: uri?.host?.removePrefix("www.") ?: "Kanzen Module"
}

private fun JsonElement?.withModuleMetadata(
    sourceName: String,
    moduleUrl: String,
    scriptUrl: String?,
    isNovel: Boolean,
): JsonObject {
    val current = this as? JsonObject ?: JsonObject(emptyMap())
    val preservedSourceName = current.string("sourceName")
    val preservedScriptUrl = current.string("scriptURL") ?: current.string("scriptUrl")
    return JsonObject(
        current + mapOf(
            "sourceName" to JsonPrimitive(preservedSourceName ?: sourceName),
            "moduleURL" to JsonPrimitive(moduleUrl),
            "moduleUrl" to JsonPrimitive(moduleUrl),
            "scriptURL" to JsonPrimitive(preservedScriptUrl ?: scriptUrl.orEmpty()),
            "novel" to JsonPrimitive(isNovel),
        ),
    )
}

private fun JsonElement.withAndroidUpdateMetadata(timestamp: String): JsonObject {
    val current = this as? JsonObject ?: JsonObject(emptyMap())
    return JsonObject(
        current + mapOf(
            "androidLastCheckedAt" to JsonPrimitive(timestamp),
            "androidLastUpdatedAt" to JsonPrimitive(timestamp),
        ),
    )
}

private fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull

private fun JsonObject.boolean(key: String): Boolean? =
    (this[key] as? JsonPrimitive)?.let { primitive ->
        primitive.booleanOrNull ?: primitive.contentOrNull?.toBooleanStrictOrNull()
    }

private fun JsonObject.firstString(vararg keys: String): String? =
    keys.firstNotNullOfOrNull { key ->
        string(key)?.trim()?.takeIf(String::isNotBlank)
    }

private fun JsonObject.firstInt(vararg keys: String): Int? =
    keys.firstNotNullOfOrNull { key ->
        val value = (this[key] as? JsonPrimitive)?.contentOrNull?.trim() ?: return@firstNotNullOfOrNull null
        (value.toIntOrNull() ?: Regex("""\d+""").find(value)?.value?.toIntOrNull())
            ?.takeIf { it > 0 }
    }

private fun JsonObject.getObject(key: String): JsonObject? =
    this[key] as? JsonObject

private fun JsonObject.detailsPayload(): JsonObject =
    getObject("details")
        ?: getObject("data")
        ?: getObject("result")
        ?: this

private fun JsonElement.jsonObjectOrNull(): JsonObject? =
    this as? JsonObject

private fun JsonObject.scriptUrl(): String? =
    string("scriptURL") ?: string("scriptUrl")

private fun String.resolveAgainst(baseUrl: String): String {
    val uri = runCatching { URI(this) }.getOrNull()
    if (uri?.isAbsolute == true) return uri.normalize().toString()
    val base = URI(baseUrl)
    return base.resolve(this).normalize().toString()
}

private fun String.validateKanzenScript() {
    require(isNotBlank()) { "Kanzen script is empty." }
    require(Regex("""\bsearchResults\b""").containsMatchIn(this)) {
        "Kanzen script must define searchResults."
    }
    val extractors = listOf("extractDetails", "extractChapters", "extractImages", "extractText")
    require(extractors.any { functionName -> Regex("""\b$functionName\b""").containsMatchIn(this) }) {
        "Kanzen script must define at least one extract function."
    }
}
