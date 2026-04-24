package dev.soupy.eclipse.android.core.network

import kotlin.math.min
import dev.soupy.eclipse.android.core.model.AniListAiringScheduleEntry
import dev.soupy.eclipse.android.core.model.AniListMedia
import dev.soupy.eclipse.android.core.model.AniListPageResponse
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString

class AniListService(
    private val baseUrl: String = "https://graphql.anilist.co",
    private val httpClient: EclipseHttpClient = EclipseHttpClient(),
) {
    data class HomeCatalogs(
        val trending: List<AniListMedia> = emptyList(),
        val popular: List<AniListMedia> = emptyList(),
        val topRated: List<AniListMedia> = emptyList(),
        val airing: List<AniListMedia> = emptyList(),
        val upcoming: List<AniListMedia> = emptyList(),
    )

    data class MangaCatalogs(
        val trending: List<AniListMedia> = emptyList(),
        val popular: List<AniListMedia> = emptyList(),
        val topRated: List<AniListMedia> = emptyList(),
        val recentlyUpdated: List<AniListMedia> = emptyList(),
    )

    suspend fun searchAnime(
        query: String,
        page: Int = 1,
        perPage: Int = 20,
    ): NetworkResult<AniListPageResponse> {
        val body = EclipseJson.encodeToString(
            AniListRequest.serializer(),
            AniListRequest(
                query = SEARCH_QUERY,
                variables = AniListVariables(search = query, page = page, perPage = perPage),
            ),
        )

        return when (val result = httpClient.postJson(baseUrl, body)) {
            is NetworkResult.Success -> try {
                val response = EclipseJson.decodeFromString(AniListEnvelope.serializer(), result.value)
                NetworkResult.Success(response.data.page)
            } catch (error: SerializationException) {
                NetworkResult.Failure.Serialization(error)
            }

            is NetworkResult.Failure -> result
        }
    }

    suspend fun searchManga(
        query: String,
        page: Int = 1,
        perPage: Int = 20,
    ): NetworkResult<AniListPageResponse> {
        val body = EclipseJson.encodeToString(
            AniListRequest.serializer(),
            AniListRequest(
                query = MANGA_SEARCH_QUERY,
                variables = AniListVariables(search = query, page = page, perPage = perPage),
            ),
        )

        return when (val result = httpClient.postJson(baseUrl, body)) {
            is NetworkResult.Success -> try {
                val response = EclipseJson.decodeFromString(AniListEnvelope.serializer(), result.value)
                NetworkResult.Success(response.data.page)
            } catch (error: SerializationException) {
                NetworkResult.Failure.Serialization(error)
            }

            is NetworkResult.Failure -> result
        }
    }

    suspend fun searchNovels(
        query: String,
        page: Int = 1,
        perPage: Int = 20,
    ): NetworkResult<AniListPageResponse> {
        val body = EclipseJson.encodeToString(
            AniListRequest.serializer(),
            AniListRequest(
                query = NOVEL_SEARCH_QUERY,
                variables = AniListVariables(search = query, page = page, perPage = perPage),
            ),
        )

        return when (val result = httpClient.postJson(baseUrl, body)) {
            is NetworkResult.Success -> try {
                val response = EclipseJson.decodeFromString(AniListEnvelope.serializer(), result.value)
                NetworkResult.Success(response.data.page)
            } catch (error: SerializationException) {
                NetworkResult.Failure.Serialization(error)
            }

            is NetworkResult.Failure -> result
        }
    }

    suspend fun mediaById(mediaId: Int): NetworkResult<AniListMedia> {
        val body = EclipseJson.encodeToString(
            AniListRequest.serializer(),
            AniListRequest(
                query = MEDIA_QUERY,
                variables = AniListVariables(id = mediaId),
            ),
        )

        return when (val result = httpClient.postJson(baseUrl, body)) {
            is NetworkResult.Success -> try {
                val response = EclipseJson.decodeFromString(AniListMediaEnvelope.serializer(), result.value)
                NetworkResult.Success(response.data.media)
            } catch (error: SerializationException) {
                NetworkResult.Failure.Serialization(error)
            }

            is NetworkResult.Failure -> result
        }
    }

    suspend fun fetchHomeCatalogs(perPage: Int = 18): NetworkResult<HomeCatalogs> {
        val body = EclipseJson.encodeToString(
            AniListRequest.serializer(),
            AniListRequest(
                query = HOME_CATALOGS_QUERY,
                variables = AniListVariables(perPage = perPage),
            ),
        )

        return when (val result = httpClient.postJson(baseUrl, body)) {
            is NetworkResult.Success -> try {
                val response = EclipseJson.decodeFromString(HomeCatalogsEnvelope.serializer(), result.value)
                NetworkResult.Success(
                    HomeCatalogs(
                        trending = response.data.trending.media,
                        popular = response.data.popular.media,
                        topRated = response.data.topRated.media,
                        airing = response.data.airing.media,
                        upcoming = response.data.upcoming.media,
                    ),
                )
            } catch (error: SerializationException) {
                NetworkResult.Failure.Serialization(error)
            }

            is NetworkResult.Failure -> result
        }
    }

    suspend fun fetchMangaCatalogs(perPage: Int = 18): NetworkResult<MangaCatalogs> {
        val body = EclipseJson.encodeToString(
            AniListRequest.serializer(),
            AniListRequest(
                query = MANGA_CATALOGS_QUERY,
                variables = AniListVariables(perPage = perPage),
            ),
        )

        return when (val result = httpClient.postJson(baseUrl, body)) {
            is NetworkResult.Success -> try {
                val response = EclipseJson.decodeFromString(MangaCatalogsEnvelope.serializer(), result.value)
                NetworkResult.Success(
                    MangaCatalogs(
                        trending = response.data.trending.media,
                        popular = response.data.popular.media,
                        topRated = response.data.topRated.media,
                        recentlyUpdated = response.data.recentlyUpdated.media,
                    ),
                )
            } catch (error: SerializationException) {
                NetworkResult.Failure.Serialization(error)
            }

            is NetworkResult.Failure -> result
        }
    }

    suspend fun fetchNovelCatalogs(perPage: Int = 18): NetworkResult<MangaCatalogs> {
        val body = EclipseJson.encodeToString(
            AniListRequest.serializer(),
            AniListRequest(
                query = NOVEL_CATALOGS_QUERY,
                variables = AniListVariables(perPage = perPage),
            ),
        )

        return when (val result = httpClient.postJson(baseUrl, body)) {
            is NetworkResult.Success -> try {
                val response = EclipseJson.decodeFromString(MangaCatalogsEnvelope.serializer(), result.value)
                NetworkResult.Success(
                    MangaCatalogs(
                        trending = response.data.trending.media,
                        popular = response.data.popular.media,
                        topRated = response.data.topRated.media,
                        recentlyUpdated = response.data.recentlyUpdated.media,
                    ),
                )
            } catch (error: SerializationException) {
                NetworkResult.Failure.Serialization(error)
            }

            is NetworkResult.Failure -> result
        }
    }

    suspend fun fetchAiringSchedule(
        daysAhead: Int = 7,
        perPage: Int = 100,
    ): NetworkResult<List<AniListAiringScheduleEntry>> {
        val now = (System.currentTimeMillis() / 1000L).toInt()
        val until = now + daysAhead * 24 * 60 * 60
        val body = EclipseJson.encodeToString(
            AniListRequest.serializer(),
            AniListRequest(
                query = AIRING_SCHEDULE_QUERY,
                variables = AniListVariables(
                    page = 1,
                    perPage = min(perPage, 100),
                    airingAtGreater = now,
                    airingAtLesser = until,
                ),
            ),
        )

        return when (val result = httpClient.postJson(baseUrl, body)) {
            is NetworkResult.Success -> try {
                val response = EclipseJson.decodeFromString(AiringScheduleEnvelope.serializer(), result.value)
                NetworkResult.Success(response.data.page.airingSchedules)
            } catch (error: SerializationException) {
                NetworkResult.Failure.Serialization(error)
            }

            is NetworkResult.Failure -> result
        }
    }

    @Serializable
    private data class AniListRequest(
        val query: String,
        val variables: AniListVariables,
    )

    @Serializable
    private data class AniListVariables(
        val search: String? = null,
        val page: Int = 1,
        val perPage: Int = 20,
        val id: Int? = null,
        val airingAtGreater: Int? = null,
        val airingAtLesser: Int? = null,
    )

    @Serializable
    private data class AniListEnvelope(
        val data: AniListData,
    )

    @Serializable
    private data class AniListData(
        @SerialName("Page") val page: AniListPageResponse,
    )

    @Serializable
    private data class AniListMediaEnvelope(
        val data: AniListMediaData,
    )

    @Serializable
    private data class AniListMediaData(
        @SerialName("Media") val media: AniListMedia,
    )

    @Serializable
    private data class HomeCatalogsEnvelope(
        val data: HomeCatalogsData,
    )

    @Serializable
    private data class HomeCatalogsData(
        val trending: AniListPageResponse = AniListPageResponse(),
        val popular: AniListPageResponse = AniListPageResponse(),
        val topRated: AniListPageResponse = AniListPageResponse(),
        val airing: AniListPageResponse = AniListPageResponse(),
        val upcoming: AniListPageResponse = AniListPageResponse(),
    )

    @Serializable
    private data class MangaCatalogsEnvelope(
        val data: MangaCatalogsData,
    )

    @Serializable
    private data class MangaCatalogsData(
        val trending: AniListPageResponse = AniListPageResponse(),
        val popular: AniListPageResponse = AniListPageResponse(),
        val topRated: AniListPageResponse = AniListPageResponse(),
        val recentlyUpdated: AniListPageResponse = AniListPageResponse(),
    )

    @Serializable
    private data class AiringScheduleEnvelope(
        val data: AiringScheduleData,
    )

    @Serializable
    private data class AiringScheduleData(
        @SerialName("Page") val page: AiringSchedulePage,
    )

    @Serializable
    private data class AiringSchedulePage(
        @SerialName("airingSchedules") val airingSchedules: List<AniListAiringScheduleEntry> = emptyList(),
    )

    private companion object {
        const val SEARCH_QUERY = """
            query SearchAnime(${'$'}search: String, ${'$'}page: Int, ${'$'}perPage: Int) {
              Page(page: ${'$'}page, perPage: ${'$'}perPage) {
                pageInfo {
                  currentPage
                  hasNextPage
                  perPage
                  total
                }
                media(search: ${'$'}search, type: ANIME) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  season
                  seasonYear
                  episodes
                  duration
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                  nextAiringEpisode {
                    episode
                    timeUntilAiring
                    airingAt
                  }
                }
              }
            }
        """

        const val MEDIA_QUERY = """
            query MediaById(${'$'}id: Int) {
              Media(id: ${'$'}id, type: ANIME) {
                id
                idMal
                description(asHtml: false)
                format
                season
                seasonYear
                episodes
                duration
                status
                bannerImage
                isAdult
                type
                synonyms
                genres
                title {
                  romaji
                  english
                  native
                  userPreferred
                }
                coverImage {
                  extraLarge
                  large
                  medium
                  color
                }
                nextAiringEpisode {
                  episode
                  timeUntilAiring
                  airingAt
                }
                relations {
                  edges {
                    relationType
                    node {
                      id
                      idMal
                      description(asHtml: false)
                      format
                      season
                      seasonYear
                      episodes
                      duration
                      status
                      bannerImage
                      isAdult
                      type
                      synonyms
                      genres
                      title {
                        romaji
                        english
                        native
                        userPreferred
                      }
                      coverImage {
                        extraLarge
                        large
                        medium
                        color
                      }
                      nextAiringEpisode {
                        episode
                        timeUntilAiring
                        airingAt
                      }
                    }
                  }
                }
              }
            }
        """

        const val MANGA_SEARCH_QUERY = """
            query SearchManga(${'$'}search: String, ${'$'}page: Int, ${'$'}perPage: Int) {
              Page(page: ${'$'}page, perPage: ${'$'}perPage) {
                pageInfo {
                  currentPage
                  hasNextPage
                  perPage
                  total
                }
                media(search: ${'$'}search, type: MANGA) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  chapters
                  volumes
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                }
              }
            }
        """

        const val NOVEL_SEARCH_QUERY = """
            query SearchNovels(${'$'}search: String, ${'$'}page: Int, ${'$'}perPage: Int) {
              Page(page: ${'$'}page, perPage: ${'$'}perPage) {
                pageInfo {
                  currentPage
                  hasNextPage
                  perPage
                  total
                }
                media(search: ${'$'}search, type: MANGA, format_in: [NOVEL]) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  chapters
                  volumes
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                }
              }
            }
        """

        const val HOME_CATALOGS_QUERY = """
            query HomeAnimeCatalogs(${'$'}perPage: Int) {
              trending: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: ANIME, sort: TRENDING_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  season
                  seasonYear
                  episodes
                  duration
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                  nextAiringEpisode {
                    episode
                    timeUntilAiring
                    airingAt
                  }
                }
              }
              popular: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: ANIME, sort: POPULARITY_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  season
                  seasonYear
                  episodes
                  duration
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                  nextAiringEpisode {
                    episode
                    timeUntilAiring
                    airingAt
                  }
                }
              }
              topRated: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: ANIME, sort: SCORE_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  season
                  seasonYear
                  episodes
                  duration
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                  nextAiringEpisode {
                    episode
                    timeUntilAiring
                    airingAt
                  }
                }
              }
              airing: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: ANIME, status: RELEASING, sort: POPULARITY_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  season
                  seasonYear
                  episodes
                  duration
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                  nextAiringEpisode {
                    episode
                    timeUntilAiring
                    airingAt
                  }
                }
              }
              upcoming: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: ANIME, status: NOT_YET_RELEASED, sort: POPULARITY_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  season
                  seasonYear
                  episodes
                  duration
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                  nextAiringEpisode {
                    episode
                    timeUntilAiring
                    airingAt
                  }
                }
              }
            }
        """

        const val MANGA_CATALOGS_QUERY = """
            query MangaCatalogs(${'$'}perPage: Int) {
              trending: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: MANGA, sort: TRENDING_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  chapters
                  volumes
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                }
              }
              popular: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: MANGA, sort: POPULARITY_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  chapters
                  volumes
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                }
              }
              topRated: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: MANGA, sort: SCORE_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  chapters
                  volumes
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                }
              }
              recentlyUpdated: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: MANGA, sort: UPDATED_AT_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  chapters
                  volumes
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                }
              }
            }
        """

        const val NOVEL_CATALOGS_QUERY = """
            query NovelCatalogs(${'$'}perPage: Int) {
              trending: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: MANGA, format_in: [NOVEL], sort: TRENDING_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  chapters
                  volumes
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                }
              }
              popular: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: MANGA, format_in: [NOVEL], sort: POPULARITY_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  chapters
                  volumes
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                }
              }
              topRated: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: MANGA, format_in: [NOVEL], sort: SCORE_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  chapters
                  volumes
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                }
              }
              recentlyUpdated: Page(page: 1, perPage: ${'$'}perPage) {
                media(type: MANGA, format_in: [NOVEL], sort: UPDATED_AT_DESC) {
                  id
                  idMal
                  description(asHtml: false)
                  format
                  chapters
                  volumes
                  status
                  bannerImage
                  isAdult
                  synonyms
                  genres
                  title {
                    romaji
                    english
                    native
                    userPreferred
                  }
                  coverImage {
                    extraLarge
                    large
                    medium
                    color
                  }
                }
              }
            }
        """

        const val AIRING_SCHEDULE_QUERY = """
            query AiringSchedule(${'$'}page: Int, ${'$'}perPage: Int, ${'$'}airingAtGreater: Int, ${'$'}airingAtLesser: Int) {
              Page(page: ${'$'}page, perPage: ${'$'}perPage) {
                airingSchedules(
                  airingAt_greater: ${'$'}airingAtGreater,
                  airingAt_lesser: ${'$'}airingAtLesser,
                  sort: TIME
                ) {
                  id
                  episode
                  airingAt
                  media {
                    id
                    format
                    title {
                      romaji
                      english
                      native
                      userPreferred
                    }
                    coverImage {
                      extraLarge
                      large
                      medium
                      color
                    }
                  }
                }
              }
            }
        """
    }
}

