package dev.soupy.eclipse.android.core.model

import kotlinx.serialization.Serializable

@Serializable
data class LibraryItemRecord(
    val id: String,
    val detailTarget: DetailTarget,
    val title: String,
    val subtitle: String? = null,
    val overview: String? = null,
    val imageUrl: String? = null,
    val backdropUrl: String? = null,
    val mediaLabel: String? = null,
    val addedAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
)

@Serializable
data class ContinueWatchingRecord(
    val id: String,
    val detailTarget: DetailTarget,
    val title: String,
    val subtitle: String? = null,
    val imageUrl: String? = null,
    val backdropUrl: String? = null,
    val progressPercent: Float = 0f,
    val progressLabel: String? = null,
    val updatedAt: Long = System.currentTimeMillis(),
)

@Serializable
data class MediaLibraryCollection(
    val id: String,
    val name: String,
    val description: String? = null,
    val itemIds: List<String> = emptyList(),
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
)

@Serializable
data class LibrarySnapshot(
    val savedItems: List<LibraryItemRecord> = emptyList(),
    val continueWatching: List<ContinueWatchingRecord> = emptyList(),
    val collections: List<MediaLibraryCollection> = emptyList(),
)
