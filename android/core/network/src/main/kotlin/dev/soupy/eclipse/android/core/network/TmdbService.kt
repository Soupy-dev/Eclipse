package dev.soupy.eclipse.android.core.network

import java.net.URLEncoder
import dev.soupy.eclipse.android.core.model.TMDBMovieDetail
import dev.soupy.eclipse.android.core.model.TMDBSearchResponse
import dev.soupy.eclipse.android.core.model.TMDBSearchResult
import dev.soupy.eclipse.android.core.model.TMDBSeasonDetail
import dev.soupy.eclipse.android.core.model.TMDBTVShowDetail
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString

class TmdbService(
    private val apiKey: String,
    private val baseUrl: String = "https://api.themoviedb.org/3",
    private val language: String = "en-US",
    private val httpClient: EclipseHttpClient = EclipseHttpClient(),
) {
    suspend fun searchMulti(
        query: String,
        page: Int = 1,
        includeAdult: Boolean = false,
    ): NetworkResult<TMDBSearchResponse> = decode {
        httpClient.get(
            "$baseUrl/search/multi?api_key=$apiKey&query=${query.urlEncode()}&page=$page&include_adult=$includeAdult",
        )
    }

    suspend fun tvShowDetail(showId: Int): NetworkResult<TMDBTVShowDetail> = decode {
        httpClient.get("$baseUrl/tv/$showId?api_key=$apiKey&language=$language&append_to_response=external_ids")
    }

    suspend fun seasonDetail(
        showId: Int,
        seasonNumber: Int,
    ): NetworkResult<TMDBSeasonDetail> = decode {
        httpClient.get("$baseUrl/tv/$showId/season/$seasonNumber?api_key=$apiKey&language=$language")
    }

    suspend fun movieDetail(movieId: Int): NetworkResult<TMDBMovieDetail> = decode {
        httpClient.get("$baseUrl/movie/$movieId?api_key=$apiKey&language=$language&append_to_response=external_ids")
    }

    suspend fun trendingAll(page: Int = 1): NetworkResult<List<TMDBSearchResult>> =
        decodeResults("$baseUrl/trending/all/week?api_key=$apiKey&language=$language&page=$page&include_adult=false")

    suspend fun popularMovies(page: Int = 1): NetworkResult<List<TMDBSearchResult>> =
        decodeResults("$baseUrl/movie/popular?api_key=$apiKey&language=$language&page=$page&include_adult=false")

    suspend fun nowPlayingMovies(page: Int = 1): NetworkResult<List<TMDBSearchResult>> =
        decodeResults("$baseUrl/movie/now_playing?api_key=$apiKey&language=$language&page=$page&include_adult=false")

    suspend fun upcomingMovies(page: Int = 1): NetworkResult<List<TMDBSearchResult>> =
        decodeResults("$baseUrl/movie/upcoming?api_key=$apiKey&language=$language&page=$page&include_adult=false")

    suspend fun topRatedMovies(page: Int = 1): NetworkResult<List<TMDBSearchResult>> =
        decodeResults("$baseUrl/movie/top_rated?api_key=$apiKey&language=$language&page=$page&include_adult=false")

    suspend fun popularTv(page: Int = 1): NetworkResult<List<TMDBSearchResult>> =
        decodeResults("$baseUrl/tv/popular?api_key=$apiKey&language=$language&page=$page&include_adult=false")

    suspend fun topRatedTv(page: Int = 1): NetworkResult<List<TMDBSearchResult>> =
        decodeResults("$baseUrl/tv/top_rated?api_key=$apiKey&language=$language&page=$page&include_adult=false")

    suspend fun airingTodayTv(page: Int = 1): NetworkResult<List<TMDBSearchResult>> =
        decodeResults("$baseUrl/tv/airing_today?api_key=$apiKey&language=$language&page=$page&include_adult=false")

    suspend fun onTheAirTv(page: Int = 1): NetworkResult<List<TMDBSearchResult>> =
        decodeResults("$baseUrl/tv/on_the_air?api_key=$apiKey&language=$language&page=$page&include_adult=false")

    private suspend fun decodeResults(url: String): NetworkResult<List<TMDBSearchResult>> =
        when (val result = httpClient.get(url)) {
            is NetworkResult.Success -> try {
                NetworkResult.Success(EclipseJson.decodeFromString<TMDBSearchResponse>(result.value).results)
            } catch (error: SerializationException) {
                NetworkResult.Failure.Serialization(error)
            }

            is NetworkResult.Failure -> result
        }

    private suspend inline fun <reified T> decode(request: () -> NetworkResult<String>): NetworkResult<T> =
        when (val result = request()) {
            is NetworkResult.Success -> try {
                NetworkResult.Success(EclipseJson.decodeFromString<T>(result.value))
            } catch (error: SerializationException) {
                NetworkResult.Failure.Serialization(error)
            }

            is NetworkResult.Failure -> result
        }
}

private fun String.urlEncode(): String = URLEncoder.encode(this, Charsets.UTF_8)

