package dev.soupy.eclipse.android.core.network

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString

class MyAnimeListService(
    private val baseUrl: String = "https://api.myanimelist.net/v2",
    private val httpClient: EclipseHttpClient = EclipseHttpClient(),
) {
    data class AnimeLibraryEntry(
        val malId: Int,
        val title: String,
        val status: String,
        val progress: Int,
        val totalEpisodes: Int?,
    )

    data class MangaLibraryEntry(
        val malId: Int,
        val title: String,
        val status: String,
        val progress: Int,
        val totalChapters: Int?,
    )

    suspend fun fetchAnimeLibrary(accessToken: String): NetworkResult<List<AnimeLibraryEntry>> =
        fetchPagedLibrary(
            accessToken = accessToken,
            initialUrl = "$baseUrl/users/@me/animelist?fields=list_status,num_episodes&limit=$MalListPageLimit&nsfw=true",
            decode = { body ->
                EclipseJson.decodeFromString<AnimeListResponse>(body).let { response ->
                    response.data.map { entry ->
                        AnimeLibraryEntry(
                            malId = entry.node.id,
                            title = entry.node.title,
                            status = entry.listStatus?.status ?: "watching",
                            progress = entry.listStatus?.numEpisodesWatched ?: 0,
                            totalEpisodes = entry.node.numEpisodes,
                        )
                    } to response.paging?.next
                }
            },
        )

    suspend fun fetchMangaLibrary(accessToken: String): NetworkResult<List<MangaLibraryEntry>> =
        fetchPagedLibrary(
            accessToken = accessToken,
            initialUrl = "$baseUrl/users/@me/mangalist?fields=list_status,num_chapters&limit=$MalListPageLimit&nsfw=true",
            decode = { body ->
                EclipseJson.decodeFromString<MangaListResponse>(body).let { response ->
                    response.data.map { entry ->
                        MangaLibraryEntry(
                            malId = entry.node.id,
                            title = entry.node.title,
                            status = entry.listStatus?.status ?: "reading",
                            progress = entry.listStatus?.numChaptersRead ?: 0,
                            totalChapters = entry.node.numChapters,
                        )
                    } to response.paging?.next
                }
            },
        )

    private suspend fun <Entry> fetchPagedLibrary(
        accessToken: String,
        initialUrl: String,
        decode: (String) -> Pair<List<Entry>, String?>,
    ): NetworkResult<List<Entry>> {
        val token = accessToken.trim()
        if (token.isBlank()) {
            return NetworkResult.Failure.Http(401, "MyAnimeList access token is required.")
        }

        val entries = mutableListOf<Entry>()
        var nextUrl: String? = initialUrl
        while (!nextUrl.isNullOrBlank()) {
            when (
                val result = httpClient.get(
                    url = nextUrl,
                    headers = token.authorizationHeaders(),
                )
            ) {
                is NetworkResult.Success -> {
                    try {
                        val (pageEntries, next) = decode(result.value)
                        entries += pageEntries
                        nextUrl = next
                    } catch (error: SerializationException) {
                        return NetworkResult.Failure.Serialization(error)
                    } catch (error: IllegalArgumentException) {
                        return NetworkResult.Failure.Serialization(
                            SerializationException(error.message ?: "MyAnimeList response could not be decoded.", error),
                        )
                    }
                }
                is NetworkResult.Failure -> return result
            }
        }
        return NetworkResult.Success(entries)
    }

    @Serializable
    private data class AnimeListResponse(
        val data: List<AnimeEntry> = emptyList(),
        val paging: Paging? = null,
    )

    @Serializable
    private data class AnimeEntry(
        val node: AnimeNode,
        @SerialName("list_status") val listStatus: AnimeListStatus? = null,
    )

    @Serializable
    private data class AnimeNode(
        val id: Int,
        val title: String,
        @SerialName("num_episodes") val numEpisodes: Int? = null,
    )

    @Serializable
    private data class AnimeListStatus(
        val status: String? = null,
        @SerialName("num_episodes_watched") val numEpisodesWatched: Int? = null,
    )

    @Serializable
    private data class MangaListResponse(
        val data: List<MangaEntry> = emptyList(),
        val paging: Paging? = null,
    )

    @Serializable
    private data class MangaEntry(
        val node: MangaNode,
        @SerialName("list_status") val listStatus: MangaListStatus? = null,
    )

    @Serializable
    private data class MangaNode(
        val id: Int,
        val title: String,
        @SerialName("num_chapters") val numChapters: Int? = null,
    )

    @Serializable
    private data class MangaListStatus(
        val status: String? = null,
        @SerialName("num_chapters_read") val numChaptersRead: Int? = null,
    )

    @Serializable
    private data class Paging(
        val next: String? = null,
    )
}

private const val MalListPageLimit = 100

private fun String.authorizationHeaders(): Map<String, String> =
    mapOf("Authorization" to "Bearer ${trim()}")
