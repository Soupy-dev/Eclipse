package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.MediaCarouselSection
import dev.soupy.eclipse.android.core.model.TMDBSearchResult
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.ExploreMediaCard
import dev.soupy.eclipse.android.core.model.isMovie
import dev.soupy.eclipse.android.core.model.isTVShow
import dev.soupy.eclipse.android.core.network.AniListService
import dev.soupy.eclipse.android.core.network.NetworkResult
import dev.soupy.eclipse.android.core.network.TmdbService
import dev.soupy.eclipse.android.core.storage.SearchHistoryStore
import dev.soupy.eclipse.android.core.storage.SettingsStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private const val HorrorGenreId = 27
const val TmdbSearchSourceId = "tmdb"

data class SearchContent(
    val sections: List<MediaCarouselSection> = emptyList(),
    val recentQueries: List<String> = emptyList(),
)

data class SearchSourceOption(
    val id: String,
    val label: String,
    val subtitle: String? = null,
    val isTmdb: Boolean = false,
)

class SearchRepository(
    private val tmdbService: TmdbService,
    private val aniListService: AniListService,
    private val servicesRepository: ServicesRepository,
    private val searchHistoryStore: SearchHistoryStore,
    private val settingsStore: SettingsStore,
    private val tmdbEnabled: Boolean,
) {
    suspend fun recentQueries(): List<String> = searchHistoryStore.read().queries

    fun observeSearchSources(): Flow<List<SearchSourceOption>> =
        servicesRepository.observeSnapshot().map { snapshot ->
            buildList {
                add(
                    SearchSourceOption(
                        id = TmdbSearchSourceId,
                        label = "TMDB",
                        subtitle = "Movies and TV shows",
                        isTmdb = true,
                    ),
                )
                snapshot.services
                    .filter(ServiceSourceRecord::enabled)
                    .sortedBy(ServiceSourceRecord::sortIndex)
                    .forEach { service ->
                        add(
                            SearchSourceOption(
                                id = service.id,
                                label = service.name,
                                subtitle = service.configurationSummary ?: service.subtitle,
                            ),
                        )
                    }
            }
        }

    suspend fun search(
        query: String,
        sourceId: String = TmdbSearchSourceId,
    ): Result<SearchContent> = runCatching {
        require(query.isNotBlank()) { "Search query cannot be blank." }

        val recentQueries = searchHistoryStore.read().remember(query).also { searchHistoryStore.write(it) }.queries
        if (sourceId != TmdbSearchSourceId) {
            val results = servicesRepository.searchService(sourceId, query).getOrThrow()
                .take(48)
                .mapIndexed { index, result ->
                    ExploreMediaCard(
                        id = "service-$sourceId-${result.href.hashCode()}-$index",
                        title = result.title,
                        subtitle = result.subtitle,
                        imageUrl = result.image,
                        backdropUrl = result.image,
                        badge = "Service",
                        detailTarget = DetailTarget.ServiceMedia(
                            serviceId = sourceId,
                            href = result.href,
                            title = result.title,
                            imageUrl = result.image,
                        ),
                    )
                }
            return@runCatching SearchContent(
                recentQueries = recentQueries,
                sections = if (results.isEmpty()) {
                    emptyList()
                } else {
                    listOf(MediaCarouselSection("search-service-$sourceId", "Service Results", "Results from your selected source", results))
                },
            )
        }

        val settings = settingsStore.settings.first()
        val firstTmdbPage = if (tmdbEnabled) {
            tmdbService.searchMulti(query = query, page = 1).orThrow()
        } else {
            dev.soupy.eclipse.android.core.model.TMDBSearchResponse(results = emptyList())
        }
        val extraTmdbPages = if (tmdbEnabled && firstTmdbPage.totalPages > 1) {
            (2..minOf(firstTmdbPage.totalPages, 3))
                .flatMap { page -> tmdbService.searchMulti(query = query, page = page).orEmptyResponse().results }
        } else {
            emptyList()
        }
        val tmdbResults = (firstTmdbPage.results + extraTmdbPages)
            .filter { it.isMovie || it.isTVShow }
            .withoutFilteredHorror(settings.filterHorrorContent)
            .distinctBy { "${it.mediaType}:${it.id}" }
            .take(48)
            .map { it.toExploreMediaCard() }

        SearchContent(
            recentQueries = recentQueries,
            sections = if (tmdbResults.isEmpty()) {
                emptyList()
            } else {
                listOf(MediaCarouselSection("search-tmdb", "Search Results", "Movies and TV shows", tmdbResults))
            },
        )
    }
}

private fun NetworkResult<dev.soupy.eclipse.android.core.model.TMDBSearchResponse>.orEmptyResponse():
    dev.soupy.eclipse.android.core.model.TMDBSearchResponse = when (this) {
        is NetworkResult.Success -> value
        is NetworkResult.Failure -> dev.soupy.eclipse.android.core.model.TMDBSearchResponse(results = emptyList())
    }

private fun List<TMDBSearchResult>.withoutFilteredHorror(enabled: Boolean): List<TMDBSearchResult> =
    if (enabled) {
        filterNot { result -> HorrorGenreId in result.genreIds }
    } else {
        this
    }
