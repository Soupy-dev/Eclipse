package dev.soupy.eclipse.android.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class AniListTitle(
    val romaji: String? = null,
    val english: String? = null,
    val native: String? = null,
    val userPreferred: String? = null,
)

val AniListTitle.primary: String
    get() = userPreferred ?: english ?: romaji ?: native.orEmpty()

@Serializable
data class AniListCoverImage(
    val extraLarge: String? = null,
    val large: String? = null,
    val medium: String? = null,
    val color: String? = null,
)

val AniListCoverImage.bestAvailableUrl: String?
    get() = extraLarge ?: large ?: medium

@Serializable
data class AniListAiringEpisode(
    val episode: Int = 0,
    @SerialName("timeUntilAiring") val timeUntilAiring: Int = 0,
    @SerialName("airingAt") val airingAt: Int = 0,
)

@Serializable
data class AniListRelatedMedia(
    @SerialName("relationType") val relationType: String? = null,
    val node: AniListMedia? = null,
)

@Serializable
data class AniListRelations(
    val edges: List<AniListRelatedMedia> = emptyList(),
)

@Serializable
data class AniListMedia(
    val id: Int = 0,
    @SerialName("idMal") val idMal: Int? = null,
    val title: AniListTitle = AniListTitle(),
    val description: String? = null,
    val format: String? = null,
    val season: String? = null,
    @SerialName("seasonYear") val seasonYear: Int? = null,
    val episodes: Int? = null,
    val chapters: Int? = null,
    val volumes: Int? = null,
    val duration: Int? = null,
    val status: String? = null,
    @SerialName("bannerImage") val bannerImage: String? = null,
    @SerialName("coverImage") val coverImage: AniListCoverImage = AniListCoverImage(),
    @SerialName("isAdult") val isAdult: Boolean = false,
    @SerialName("nextAiringEpisode") val nextAiringEpisode: AniListAiringEpisode? = null,
    val synonyms: List<String> = emptyList(),
    val genres: List<String> = emptyList(),
    val type: String? = null,
    val relations: AniListRelations = AniListRelations(),
)

val AniListMedia.posterUrl: String?
    get() = coverImage.bestAvailableUrl

val AniListMedia.displayTitle: String
    get() = title.primary.ifBlank { "Unknown" }

val AniListMedia.relationEdges: List<AniListRelatedMedia>
    get() = relations.edges

@Serializable
data class AniListEpisode(
    val id: Int = 0,
    val number: Int = 0,
    val title: String? = null,
    val description: String? = null,
    val image: String? = null,
    val airDate: String? = null,
    val runtimeMinutes: Int? = null,
    val tmdbSeasonNumber: Int? = null,
    val tmdbEpisodeNumber: Int? = null,
    val isSpecial: Boolean = false,
)

@Serializable
data class AniListPageInfo(
    @SerialName("currentPage") val currentPage: Int = 1,
    @SerialName("hasNextPage") val hasNextPage: Boolean = false,
    @SerialName("perPage") val perPage: Int = 0,
    @SerialName("total") val total: Int = 0,
)

@Serializable
data class AniListPageResponse(
    @SerialName("pageInfo") val pageInfo: AniListPageInfo = AniListPageInfo(),
    val media: List<AniListMedia> = emptyList(),
)

@Serializable
data class AniListAiringScheduleMedia(
    val id: Int = 0,
    val title: AniListTitle = AniListTitle(),
    val format: String? = null,
    @SerialName("coverImage") val coverImage: AniListCoverImage = AniListCoverImage(),
)

val AniListAiringScheduleMedia.displayTitle: String
    get() = title.primary.ifBlank { "Unknown" }

@Serializable
data class AniListAiringScheduleEntry(
    val id: Int = 0,
    val episode: Int = 0,
    @SerialName("airingAt") val airingAtEpochSeconds: Long = 0,
    val media: AniListAiringScheduleMedia = AniListAiringScheduleMedia(),
)

