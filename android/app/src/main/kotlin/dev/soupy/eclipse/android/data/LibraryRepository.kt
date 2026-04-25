package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.ContinueWatchingRecord
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.LibraryItemRecord
import dev.soupy.eclipse.android.core.model.LibrarySnapshot
import dev.soupy.eclipse.android.core.model.MediaLibraryCollection
import dev.soupy.eclipse.android.core.model.AniListMedia
import dev.soupy.eclipse.android.core.model.BackupCollection
import dev.soupy.eclipse.android.core.model.displayTitle
import dev.soupy.eclipse.android.core.model.posterUrl
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.storage.LibraryStore
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement

data class LibraryItemDraft(
    val detailTarget: DetailTarget,
    val title: String,
    val subtitle: String? = null,
    val overview: String? = null,
    val imageUrl: String? = null,
    val backdropUrl: String? = null,
    val mediaLabel: String? = null,
)

data class ContinueWatchingDraft(
    val detailTarget: DetailTarget,
    val title: String,
    val subtitle: String? = null,
    val imageUrl: String? = null,
    val backdropUrl: String? = null,
    val progressPercent: Float = 0f,
    val progressLabel: String? = null,
)

data class AniListLibraryImportDraft(
    val media: AniListMedia,
    val status: String? = null,
    val progress: Int = 0,
    val score: Double = 0.0,
    val updatedAtEpochSeconds: Long? = null,
)

data class LibraryImportSummary(
    val snapshot: LibrarySnapshot,
    val importedItems: Int,
    val importedContinueWatching: Int,
)

class LibraryRepository(
    private val libraryStore: LibraryStore,
    private val progressRepository: ProgressRepository,
) {
    suspend fun loadSnapshot(): Result<LibrarySnapshot> = runCatching {
        libraryStore.read().withDefaultCollections().withProgressContinueWatching().normalized()
    }

    suspend fun toggleSaved(draft: LibraryItemDraft): Result<LibrarySnapshot> = runCatching {
        val snapshot = libraryStore.read()
        val key = draft.detailTarget.storageKey()
        val alreadySaved = snapshot.savedItems.any { it.id == key }
        val updatedSaved = if (alreadySaved) {
            snapshot.savedItems.filterNot { it.id == key }
        } else {
            listOf(draft.toRecord(key)) + snapshot.savedItems.filterNot { it.id == key }
        }
        val updatedCollections = if (alreadySaved) {
            snapshot.collections
        } else {
            snapshot.collections.withItemInCollection(
                collectionId = BookmarksCollectionId,
                itemId = key,
            )
        }

        writeSnapshot(snapshot.copy(savedItems = updatedSaved, collections = updatedCollections))
    }

    suspend fun recordContinueWatching(draft: ContinueWatchingDraft): Result<LibrarySnapshot> =
        syncContinueWatching(draft)

    suspend fun importAniListAnime(drafts: List<AniListLibraryImportDraft>): Result<LibraryImportSummary> = runCatching {
        val snapshot = libraryStore.read()
        val uniqueDrafts = drafts
            .filter { it.media.id > 0 }
            .distinctBy { it.media.id }
        val importedSaved = uniqueDrafts.map { draft ->
            draft.toLibraryRecord(id = DetailTarget.AniListMediaTarget(draft.media.id).storageKey())
        }
        val importedContinueWatching = uniqueDrafts.mapNotNull(AniListLibraryImportDraft::toContinueWatchingRecord)
        val importedSavedIds = importedSaved.map(LibraryItemRecord::id).toSet()
        val importedContinueWatchingIds = importedContinueWatching.map(ContinueWatchingRecord::id).toSet()
        val importedCollections = snapshot.collections.withAniListStatusCollections(uniqueDrafts)

        val updated = writeSnapshot(
            snapshot.copy(
                savedItems = importedSaved + snapshot.savedItems.filterNot { it.id in importedSavedIds },
                continueWatching = importedContinueWatching +
                    snapshot.continueWatching.filterNot { it.id in importedContinueWatchingIds },
                collections = importedCollections,
            ),
        )

        LibraryImportSummary(
            snapshot = updated,
            importedItems = importedSaved.size,
            importedContinueWatching = importedContinueWatching.size,
        )
    }

    suspend fun syncContinueWatching(draft: ContinueWatchingDraft): Result<LibrarySnapshot> = runCatching {
        val snapshot = libraryStore.read()
        val key = draft.detailTarget.storageKey()
        val normalizedDraft = draft.copy(progressPercent = draft.progressPercent.coerceIn(0f, 1f))
        val updatedContinueWatching = if (normalizedDraft.progressPercent >= ContinueWatchingCompletionThreshold) {
            snapshot.continueWatching.filterNot { it.id == key }
        } else {
            listOf(normalizedDraft.toRecord(key)) +
                snapshot.continueWatching.filterNot { it.id == key }
        }

        writeSnapshot(
            snapshot.copy(
                continueWatching = updatedContinueWatching.take(20),
            ),
        )
    }

    suspend fun removeSaved(id: String): Result<LibrarySnapshot> = runCatching {
        val snapshot = libraryStore.read()
        writeSnapshot(
            snapshot.copy(
                savedItems = snapshot.savedItems.filterNot { it.id == id },
                collections = snapshot.collections.map { collection ->
                    collection.copy(
                        itemIds = collection.itemIds.filterNot { it == id },
                        updatedAt = System.currentTimeMillis(),
                    )
                },
            ),
        )
    }

    suspend fun removeContinueWatching(id: String): Result<LibrarySnapshot> = runCatching {
        val snapshot = libraryStore.read()
        if (id.startsWith("progress:")) {
            progressRepository.removeContinueWatching(id).getOrThrow()
        }
        writeSnapshot(
            snapshot.copy(
                continueWatching = snapshot.continueWatching.filterNot { it.id == id },
            ),
        )
    }

    suspend fun createCollection(
        name: String,
        description: String? = null,
    ): Result<LibrarySnapshot> = runCatching {
        val trimmed = name.trim()
        require(trimmed.isNotBlank()) { "Collection name is required." }
        val snapshot = libraryStore.read().withDefaultCollections()
        require(snapshot.collections.none { it.name.equals(trimmed, ignoreCase = true) }) {
            "A collection named $trimmed already exists."
        }
        val now = System.currentTimeMillis()
        val collection = MediaLibraryCollection(
            id = "media-collection-${trimmed.slugified()}",
            name = trimmed,
            description = description?.trim()?.takeIf { it.isNotBlank() },
            createdAt = now,
            updatedAt = now,
        )
        writeSnapshot(snapshot.copy(collections = snapshot.collections + collection))
    }

    suspend fun deleteCollection(id: String): Result<LibrarySnapshot> = runCatching {
        require(id != BookmarksCollectionId) { "Bookmarks cannot be deleted." }
        val snapshot = libraryStore.read().withDefaultCollections()
        writeSnapshot(snapshot.copy(collections = snapshot.collections.filterNot { it.id == id }))
    }

    suspend fun addToCollection(
        collectionId: String,
        itemId: String,
    ): Result<LibrarySnapshot> = runCatching {
        val snapshot = libraryStore.read().withDefaultCollections()
        require(snapshot.savedItems.any { it.id == itemId }) { "Save this title before adding it to a collection." }
        require(snapshot.collections.any { it.id == collectionId }) { "Collection was not found." }
        writeSnapshot(
            snapshot.copy(
                collections = snapshot.collections.withItemInCollection(collectionId, itemId),
            ),
        )
    }

    suspend fun saveToCollection(
        collectionId: String,
        draft: LibraryItemDraft,
    ): Result<LibrarySnapshot> = runCatching {
        val snapshot = libraryStore.read().withDefaultCollections()
        require(snapshot.collections.any { it.id == collectionId }) { "Collection was not found." }
        val key = draft.detailTarget.storageKey()
        val updatedSavedItems = listOf(draft.toRecord(key)) + snapshot.savedItems.filterNot { it.id == key }
        writeSnapshot(
            snapshot.copy(
                savedItems = updatedSavedItems,
                collections = snapshot.collections.withItemInCollection(collectionId, key),
            ),
        )
    }

    suspend fun removeFromCollection(
        collectionId: String,
        itemId: String,
    ): Result<LibrarySnapshot> = runCatching {
        val snapshot = libraryStore.read().withDefaultCollections()
        writeSnapshot(
            snapshot.copy(
                collections = snapshot.collections.map { collection ->
                    if (collection.id == collectionId) {
                        collection.copy(
                            itemIds = collection.itemIds.filterNot { it == itemId },
                            updatedAt = System.currentTimeMillis(),
                        )
                    } else {
                        collection
                    }
                },
            ),
        )
    }

    suspend fun exportCollections(): List<BackupCollection> {
        val snapshot = libraryStore.read().withDefaultCollections().normalized()
        val recordsById = snapshot.savedItems.associateBy { it.id }
        return snapshot.collections.map { collection ->
            BackupCollection(
                id = collection.id,
                name = collection.name,
                description = collection.description,
                items = collection.itemIds.mapNotNull { itemId ->
                    recordsById[itemId]?.let { record -> EclipseJson.encodeToJsonElement(record) }
                },
            )
        }
    }

    suspend fun restoreCollectionsFromBackup(collections: List<BackupCollection>): Result<LibrarySnapshot> = runCatching {
        if (collections.isEmpty()) return@runCatching loadSnapshot().getOrThrow()
        val snapshot = libraryStore.read().withDefaultCollections()
        val importedRecords = collections.flatMap { collection ->
            collection.items.mapNotNull { item ->
                runCatching { EclipseJson.decodeFromJsonElement<LibraryItemRecord>(item) }.getOrNull()
            }
        }.distinctBy { it.id }
        val importedIds = importedRecords.map { it.id }.toSet()
        val importedCollections = collections.map { collection ->
            MediaLibraryCollection(
                id = collection.id.ifBlank { collection.name.slugified() },
                name = collection.name.ifBlank { "Collection" },
                description = collection.description,
                itemIds = collection.items.mapNotNull { item ->
                    runCatching { EclipseJson.decodeFromJsonElement<LibraryItemRecord>(item).id }.getOrNull()
                },
            )
        }
        writeSnapshot(
            snapshot.copy(
                savedItems = importedRecords + snapshot.savedItems.filterNot { it.id in importedIds },
                collections = importedCollections + snapshot.collections.filterNot { existing ->
                    importedCollections.any { it.id == existing.id }
                },
            ),
        )
    }

    private suspend fun writeSnapshot(snapshot: LibrarySnapshot): LibrarySnapshot {
        val normalized = snapshot.withDefaultCollections().withProgressContinueWatching().normalized()
        libraryStore.write(normalized)
        return normalized
    }

    private suspend fun LibrarySnapshot.withProgressContinueWatching(): LibrarySnapshot {
        val progressRecords = progressRepository.continueWatching()
        val manualRecords = continueWatching.filterNot { it.id.startsWith("progress:") }
        return copy(
            continueWatching = (progressRecords + manualRecords)
                .distinctBy { it.id }
                .sortedByDescending { it.updatedAt }
                .take(20),
        )
    }
}

private const val ContinueWatchingCompletionThreshold = 0.97f
private const val BookmarksCollectionId = "media-bookmarks"

private fun LibrarySnapshot.normalized(): LibrarySnapshot = copy(
    savedItems = savedItems.sortedByDescending { it.updatedAt },
    continueWatching = continueWatching.sortedByDescending { it.updatedAt },
    collections = collections
        .map { collection ->
            collection.copy(itemIds = collection.itemIds.distinct().filter { itemId ->
                savedItems.any { it.id == itemId }
            })
        }
        .sortedWith(compareBy<MediaLibraryCollection> { it.id != BookmarksCollectionId }.thenBy { it.name.lowercase() }),
)

private fun LibrarySnapshot.withDefaultCollections(): LibrarySnapshot {
    if (collections.any { it.id == BookmarksCollectionId || it.name.equals("Bookmarks", ignoreCase = true) }) return this
    return copy(
        collections = listOf(
            MediaLibraryCollection(
                id = BookmarksCollectionId,
                name = "Bookmarks",
                description = "Your bookmarked media",
            ),
        ) + collections,
    )
}

private fun List<MediaLibraryCollection>.withItemInCollection(
    collectionId: String,
    itemId: String,
): List<MediaLibraryCollection> = map { collection ->
    if (collection.id == collectionId || collection.name.equals("Bookmarks", ignoreCase = true) && collectionId == BookmarksCollectionId) {
        collection.copy(
            itemIds = (listOf(itemId) + collection.itemIds.filterNot { it == itemId }).distinct(),
            updatedAt = System.currentTimeMillis(),
        )
    } else {
        collection
    }
}

private fun List<MediaLibraryCollection>.withAniListStatusCollections(
    drafts: List<AniListLibraryImportDraft>,
): List<MediaLibraryCollection> {
    val now = System.currentTimeMillis()
    val grouped = drafts
        .groupBy { it.status.toDisplayStatus() ?: "AniList" }
        .mapValues { (_, entries) ->
            entries.map { DetailTarget.AniListMediaTarget(it.media.id).storageKey() }.distinct()
        }
    val keyedCollections = associateBy { it.name.lowercase() }.toMutableMap()
    grouped.forEach { (status, ids) ->
        val name = status.ifBlank { "AniList" }
        val key = name.lowercase()
        val existing = keyedCollections[key]
        keyedCollections[key] = if (existing == null) {
            MediaLibraryCollection(
                id = "anilist-${name.slugified()}",
                name = name,
                description = "Imported from AniList.",
                itemIds = ids,
                createdAt = now,
                updatedAt = now,
            )
        } else {
            existing.copy(
                itemIds = (ids + existing.itemIds).distinct(),
                updatedAt = now,
            )
        }
    }
    return keyedCollections.values.toList()
}

private fun LibraryItemDraft.toRecord(id: String): LibraryItemRecord = LibraryItemRecord(
    id = id,
    detailTarget = detailTarget,
    title = title,
    subtitle = subtitle,
    overview = overview,
    imageUrl = imageUrl,
    backdropUrl = backdropUrl,
    mediaLabel = mediaLabel,
)

private fun ContinueWatchingDraft.toRecord(id: String): ContinueWatchingRecord = ContinueWatchingRecord(
    id = id,
    detailTarget = detailTarget,
    title = title,
    subtitle = subtitle,
    imageUrl = imageUrl,
    backdropUrl = backdropUrl,
    progressPercent = progressPercent.coerceIn(0f, 1f),
    progressLabel = progressLabel,
)

private fun AniListLibraryImportDraft.toLibraryRecord(id: String): LibraryItemRecord {
    val updatedAtMillis = updatedAtEpochSeconds?.takeIf { it > 0 }?.let { it * 1_000L } ?: System.currentTimeMillis()
    return LibraryItemRecord(
        id = id,
        detailTarget = DetailTarget.AniListMediaTarget(media.id),
        title = media.displayTitle,
        subtitle = importSubtitle(),
        overview = media.description,
        imageUrl = media.posterUrl,
        backdropUrl = media.bannerImage,
        mediaLabel = listOfNotNull("AniList", status.toDisplayStatus()).joinToString(" - "),
        addedAt = updatedAtMillis,
        updatedAt = updatedAtMillis,
    )
}

private fun AniListLibraryImportDraft.toContinueWatchingRecord(): ContinueWatchingRecord? {
    val episodeCount = media.episodes?.takeIf { it > 0 } ?: return null
    if (progress <= 0 || progress >= episodeCount) return null
    val updatedAtMillis = updatedAtEpochSeconds?.takeIf { it > 0 }?.let { it * 1_000L } ?: System.currentTimeMillis()
    return ContinueWatchingRecord(
        id = DetailTarget.AniListMediaTarget(media.id).storageKey(),
        detailTarget = DetailTarget.AniListMediaTarget(media.id),
        title = media.displayTitle,
        subtitle = "Episode ${progress + 1}",
        imageUrl = media.posterUrl,
        backdropUrl = media.bannerImage,
        progressPercent = (progress.toFloat() / episodeCount.toFloat()).coerceIn(0f, 0.96f),
        progressLabel = "AniList progress $progress/$episodeCount",
        updatedAt = updatedAtMillis,
    )
}

private fun AniListLibraryImportDraft.importSubtitle(): String? =
    listOfNotNull(
        status.toDisplayStatus(),
        media.format?.replace('_', ' '),
        media.episodes?.takeIf { it > 0 }?.let { episodes -> "$episodes episodes" },
        progress.takeIf { it > 0 }?.let { "Progress $it" },
    ).joinToString(" - ").takeIf { it.isNotBlank() }

private fun String?.toDisplayStatus(): String? =
    this?.trim()
        ?.takeIf(String::isNotBlank)
        ?.lowercase()
        ?.split('_', ' ')
        ?.joinToString(" ") { token -> token.replaceFirstChar { it.uppercase() } }

private fun String.slugified(): String =
    lowercase()
        .replace(Regex("[^a-z0-9]+"), "-")
        .trim('-')
        .ifBlank { "collection-${System.currentTimeMillis()}" }

private fun DetailTarget.storageKey(): String = when (this) {
    is DetailTarget.AniListMediaTarget -> "anilist:$id"
    is DetailTarget.TmdbMovie -> "tmdb_movie:$id"
    is DetailTarget.TmdbShow -> "tmdb_show:$id"
}
