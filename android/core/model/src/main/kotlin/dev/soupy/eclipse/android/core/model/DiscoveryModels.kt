package dev.soupy.eclipse.android.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
sealed interface DetailTarget {
    @Serializable
    @SerialName("tmdb_movie")
    data class TmdbMovie(val id: Int) : DetailTarget

    @Serializable
    @SerialName("tmdb_show")
    data class TmdbShow(val id: Int) : DetailTarget

    @Serializable
    @SerialName("anilist_media")
    data class AniListMediaTarget(val id: Int) : DetailTarget

    @Serializable
    @SerialName("service_media")
    data class ServiceMedia(
        val serviceId: String,
        val href: String,
        val title: String,
        val imageUrl: String? = null,
    ) : DetailTarget
}

data class ExploreMediaCard(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val overview: String? = null,
    val imageUrl: String? = null,
    val backdropUrl: String? = null,
    val badge: String? = null,
    val detailTarget: DetailTarget,
)

data class MediaCarouselSection(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val items: List<ExploreMediaCard> = emptyList(),
)

data class ScheduleEntryCard(
    val id: String,
    val title: String,
    val subtitle: String,
    val imageUrl: String? = null,
    val detailTarget: DetailTarget,
)

data class ScheduleDaySection(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val items: List<ScheduleEntryCard> = emptyList(),
)

