package dev.soupy.eclipse.android.data

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import dev.soupy.eclipse.android.core.model.BackupCatalog
import dev.soupy.eclipse.android.core.model.ExploreMediaCard
import dev.soupy.eclipse.android.core.model.MediaCarouselSection
import dev.soupy.eclipse.android.core.model.isMovie
import dev.soupy.eclipse.android.core.model.isTVShow
import dev.soupy.eclipse.android.core.network.AniListService
import dev.soupy.eclipse.android.core.network.TmdbService

data class HomeContent(
    val hero: ExploreMediaCard? = null,
    val sections: List<MediaCarouselSection> = emptyList(),
)

class HomeRepository(
    private val tmdbService: TmdbService,
    private val aniListService: AniListService,
    private val catalogRepository: CatalogRepository,
    private val recommendationRepository: RecommendationRepository,
    private val tmdbEnabled: Boolean,
) {
    suspend fun loadHome(): Result<HomeContent> = runCatching {
        coroutineScope {
            val enabledCatalogsDeferred = async { catalogRepository.enabledCatalogs() }
            val trendingDeferred = async {
                if (tmdbEnabled) tmdbService.trendingAll()
                else dev.soupy.eclipse.android.core.network.NetworkResult.Success(emptyList<dev.soupy.eclipse.android.core.model.TMDBSearchResult>())
            }
            val popularMoviesDeferred = async {
                if (tmdbEnabled) tmdbService.popularMovies()
                else dev.soupy.eclipse.android.core.network.NetworkResult.Success(emptyList<dev.soupy.eclipse.android.core.model.TMDBSearchResult>())
            }
            val nowPlayingMoviesDeferred = async {
                if (tmdbEnabled) tmdbService.nowPlayingMovies()
                else dev.soupy.eclipse.android.core.network.NetworkResult.Success(emptyList<dev.soupy.eclipse.android.core.model.TMDBSearchResult>())
            }
            val upcomingMoviesDeferred = async {
                if (tmdbEnabled) tmdbService.upcomingMovies()
                else dev.soupy.eclipse.android.core.network.NetworkResult.Success(emptyList<dev.soupy.eclipse.android.core.model.TMDBSearchResult>())
            }
            val popularTvDeferred = async {
                if (tmdbEnabled) tmdbService.popularTv()
                else dev.soupy.eclipse.android.core.network.NetworkResult.Success(emptyList<dev.soupy.eclipse.android.core.model.TMDBSearchResult>())
            }
            val airingTodayDeferred = async {
                if (tmdbEnabled) tmdbService.airingTodayTv()
                else dev.soupy.eclipse.android.core.network.NetworkResult.Success(emptyList<dev.soupy.eclipse.android.core.model.TMDBSearchResult>())
            }
            val onTheAirDeferred = async {
                if (tmdbEnabled) tmdbService.onTheAirTv()
                else dev.soupy.eclipse.android.core.network.NetworkResult.Success(emptyList<dev.soupy.eclipse.android.core.model.TMDBSearchResult>())
            }
            val topRatedTvDeferred = async {
                if (tmdbEnabled) tmdbService.topRatedTv()
                else dev.soupy.eclipse.android.core.network.NetworkResult.Success(emptyList<dev.soupy.eclipse.android.core.model.TMDBSearchResult>())
            }
            val topRatedMoviesDeferred = async {
                if (tmdbEnabled) tmdbService.topRatedMovies()
                else dev.soupy.eclipse.android.core.network.NetworkResult.Success(emptyList<dev.soupy.eclipse.android.core.model.TMDBSearchResult>())
            }
            val animeCatalogsDeferred = async { aniListService.fetchHomeCatalogs() }

            val enabledCatalogs = enabledCatalogsDeferred.await()
            val sections = run {
                val trending = trendingDeferred.await().orEmptyList()
                    .filter { it.isMovie || it.isTVShow }
                    .take(12)
                    .map { it.toExploreMediaCard("Trending") }
                val popularMovies = popularMoviesDeferred.await().orEmptyList().take(12).map { it.toExploreMediaCard("Movie") }
                val nowPlayingMovies = nowPlayingMoviesDeferred.await().orEmptyList().take(12).map { it.toExploreMediaCard("Now playing") }
                val upcomingMovies = upcomingMoviesDeferred.await().orEmptyList().take(12).map { it.toExploreMediaCard("Upcoming") }
                val popularTv = popularTvDeferred.await().orEmptyList().take(12).map { it.toExploreMediaCard("Series") }
                val airingToday = airingTodayDeferred.await().orEmptyList().take(12).map { it.toExploreMediaCard("Airing today") }
                val onTheAir = onTheAirDeferred.await().orEmptyList().take(12).map { it.toExploreMediaCard("On the air") }
                val topRatedTv = topRatedTvDeferred.await().orEmptyList().take(12).map { it.toExploreMediaCard("Top rated") }
                val topRatedMovies = topRatedMoviesDeferred.await().orEmptyList().take(12).map { it.toExploreMediaCard("Top rated") }
                val animeCatalogs = animeCatalogsDeferred.await().orThrow()
                val animeTrending = animeCatalogs.trending.take(12).map { it.toExploreMediaCard("Anime") }
                val animePopular = animeCatalogs.popular.take(12).map { it.toExploreMediaCard("Anime") }
                val animeAiring = animeCatalogs.airing.take(12).map { it.toExploreMediaCard("Airing") }
                val animeUpcoming = animeCatalogs.upcoming.take(12).map { it.toExploreMediaCard("Upcoming") }
                val animeTop = animeCatalogs.topRated.take(12).map { it.toExploreMediaCard("Top rated") }
                val tmdbPool = (trending + popularMovies + nowPlayingMovies + upcomingMovies + popularTv + airingToday + onTheAir + topRatedTv + topRatedMovies)
                    .distinctBy { it.id }
                val justForYou = recommendationRepository.justForYou(tmdbPool)
                val becauseYouWatched = recommendationRepository.becauseYouWatched(tmdbPool)

                val sectionByCatalogId = buildMap {
                    put("forYou", MediaCarouselSection("local-for-you", "Just For You", "Scored from your Android progress, ratings, and restored iOS recommendation cache", justForYou))
                    put("becauseYouWatched", MediaCarouselSection("local-because-you-watched", "Because You Watched", "More picks shaped by your watched and resume history", becauseYouWatched))
                    put("trending", MediaCarouselSection("tmdb-trending", "Trending This Week", "Live TMDB discovery feed", trending))
                    put("popularMovies", MediaCarouselSection("tmdb-movies", "Popular Movies", "What people are queueing right now", popularMovies))
                    put("networks", MediaCarouselSection("tmdb-networks", "Network", "Series-first browse row that mirrors Luna's network widget surface", popularTv.map { it.copy(badge = "Network") }))
                    put("nowPlayingMovies", MediaCarouselSection("tmdb-now-playing", "Now Playing Movies", "Fresh theatrical and streaming movie picks", nowPlayingMovies))
                    put("upcomingMovies", MediaCarouselSection("tmdb-upcoming-movies", "Upcoming Movies", "Movies arriving soon", upcomingMovies))
                    put("popularTVShows", MediaCarouselSection("tmdb-tv", "Popular TV Shows", "The TV side of the current Luna browse flow", popularTv))
                    put("genres", MediaCarouselSection("tmdb-genres", "Category", "Genre-style discovery backed by mixed TMDB signals", tmdbPool.map { it.copy(badge = "Category") }.take(12)))
                    put("onTheAirTV", MediaCarouselSection("tmdb-on-the-air", "On The Air TV Shows", "Currently running series from TMDB", onTheAir))
                    put("airingTodayTV", MediaCarouselSection("tmdb-airing", "Airing Today TV Shows", "Shows with fresh TV episodes today", airingToday))
                    put("topRatedTVShows", MediaCarouselSection("tmdb-top-tv", "Top Rated TV Shows", "High-signal TV picks from TMDB", topRatedTv))
                    put("topRatedMovies", MediaCarouselSection("tmdb-top-movies", "Top Rated Movies", "High-signal movie picks from TMDB", topRatedMovies))
                    put("companies", MediaCarouselSection("tmdb-companies", "Company", "Studio-style movie discovery backed by TMDB popularity", popularMovies.map { it.copy(badge = "Company") }))
                    put("trendingAnime", MediaCarouselSection("anime-trending", "Trending Anime", "AniList-powered anime discovery", animeTrending))
                    put("popularAnime", MediaCarouselSection("anime-popular", "Popular Anime", "Frequently watched AniList anime picks", animePopular))
                    put("featured", MediaCarouselSection("tmdb-featured", "Featured", "A broader featured mix from current TMDB discovery", tmdbPool.take(12).map { it.copy(badge = "Featured") }))
                    put("topRatedAnime", MediaCarouselSection("anime-top", "Top Rated Anime", "Score-sorted AniList picks", animeTop))
                    put("airingAnime", MediaCarouselSection("anime-airing", "Currently Airing Anime", "What's actively rolling out now", animeAiring))
                    put("upcomingAnime", MediaCarouselSection("anime-upcoming", "Upcoming Anime", "Not-yet-released anime with strong interest", animeUpcoming))
                    put("bestTVShows", MediaCarouselSection("tmdb-best-tv", "Best TV Shows", "Ranked TV shows from TMDB top-rated data", topRatedTv))
                    put("bestMovies", MediaCarouselSection("tmdb-best-movies", "Best Movies", "Ranked movies from TMDB top-rated data", topRatedMovies))
                    put("bestAnime", MediaCarouselSection("anime-best", "Best Anime", "Ranked anime from AniList score data", animeTop))
                }

                enabledCatalogs
                    .mapNotNull { catalog -> sectionByCatalogId[catalog.id]?.forCatalog(catalog) }
                    .filter { it.items.isNotEmpty() }
            }

            if (sections.isEmpty()) {
                error("No TMDB or AniList browse sections were available.")
            }

            HomeContent(
                hero = sections.firstNotNullOfOrNull { it.items.firstOrNull() },
                sections = sections,
            )
        }
    }
}

private fun MediaCarouselSection.forCatalog(catalog: BackupCatalog): MediaCarouselSection = copy(
    id = "catalog-${catalog.id}",
    title = catalog.displayName,
    subtitle = when (catalog.displayStyle) {
        "network" -> subtitle ?: "Network browse"
        "genre" -> subtitle ?: "Genre browse"
        "company" -> subtitle ?: "Company browse"
        "ranked" -> subtitle ?: "Ranked list"
        "featured" -> subtitle ?: "Featured picks"
        else -> subtitle
    },
)

