package dev.soupy.eclipse.android.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement

private const val WatchedThreshold = 0.85

val DefaultCatalogs: List<BackupCatalog> = listOf(
    BackupCatalog(id = "forYou", name = "Just For You", source = "Local", isEnabled = true, order = 0),
    BackupCatalog(id = "becauseYouWatched", name = "Because You Watched", source = "Local", isEnabled = true, order = 1),
    BackupCatalog(id = "trending", name = "Trending This Week", source = "TMDB", isEnabled = true, order = 2),
    BackupCatalog(id = "popularMovies", name = "Popular Movies", source = "TMDB", isEnabled = true, order = 3),
    BackupCatalog(id = "networks", name = "Network", source = "TMDB", isEnabled = true, order = 4, displayStyle = "network"),
    BackupCatalog(id = "nowPlayingMovies", name = "Now Playing Movies", source = "TMDB", isEnabled = false, order = 5),
    BackupCatalog(id = "upcomingMovies", name = "Upcoming Movies", source = "TMDB", isEnabled = false, order = 6),
    BackupCatalog(id = "popularTVShows", name = "Popular TV Shows", source = "TMDB", isEnabled = true, order = 7),
    BackupCatalog(id = "genres", name = "Category", source = "TMDB", isEnabled = true, order = 8, displayStyle = "genre"),
    BackupCatalog(id = "onTheAirTV", name = "On The Air TV Shows", source = "TMDB", isEnabled = false, order = 9),
    BackupCatalog(id = "airingTodayTV", name = "Airing Today TV Shows", source = "TMDB", isEnabled = false, order = 10),
    BackupCatalog(id = "topRatedTVShows", name = "Top Rated TV Shows", source = "TMDB", isEnabled = true, order = 11),
    BackupCatalog(id = "topRatedMovies", name = "Top Rated Movies", source = "TMDB", isEnabled = true, order = 12),
    BackupCatalog(id = "companies", name = "Company", source = "TMDB", isEnabled = true, order = 13, displayStyle = "company"),
    BackupCatalog(id = "trendingAnime", name = "Trending Anime", source = "AniList", isEnabled = true, order = 14),
    BackupCatalog(id = "popularAnime", name = "Popular Anime", source = "AniList", isEnabled = true, order = 15),
    BackupCatalog(id = "featured", name = "Featured", source = "TMDB", isEnabled = true, order = 16, displayStyle = "featured"),
    BackupCatalog(id = "topRatedAnime", name = "Top Rated Anime", source = "AniList", isEnabled = true, order = 17),
    BackupCatalog(id = "airingAnime", name = "Currently Airing Anime", source = "AniList", isEnabled = false, order = 18),
    BackupCatalog(id = "upcomingAnime", name = "Upcoming Anime", source = "AniList", isEnabled = false, order = 19),
    BackupCatalog(id = "bestTVShows", name = "Best TV Shows", source = "TMDB", isEnabled = false, order = 20, displayStyle = "ranked"),
    BackupCatalog(id = "bestMovies", name = "Best Movies", source = "TMDB", isEnabled = false, order = 21, displayStyle = "ranked"),
    BackupCatalog(id = "bestAnime", name = "Best Anime", source = "AniList", isEnabled = false, order = 22, displayStyle = "ranked"),
)

@Serializable
data class CatalogSnapshot(
    val catalogs: List<BackupCatalog> = DefaultCatalogs,
) {
    val enabledCatalogs: List<BackupCatalog>
        get() = catalogs.filter { it.isEnabled }.sortedBy { it.order }
}

@Serializable
data class RatingsSnapshot(
    val ratings: Map<String, Int> = emptyMap(),
) {
    val normalized: RatingsSnapshot
        get() = copy(ratings = ratings.mapValues { (_, value) -> value.coerceIn(1, 5) })
}

@Serializable
data class RecommendationCacheSnapshot(
    val items: JsonElement = JsonArray(emptyList()),
)

@Serializable
data class KanzenModuleSnapshot(
    val modules: List<ModuleBackup> = emptyList(),
)

@Serializable
data class CacheMetricsSnapshot(
    val cacheBytes: Long = 0,
    val filesBytes: Long = 0,
    val downloadBytes: Long = 0,
    val generatedAt: Long = 0,
)

@Serializable
data class AppLogEntry(
    val id: String,
    val timestamp: Long,
    val tag: String,
    val message: String,
    val level: String = "info",
)

@Serializable
data class AppLogSnapshot(
    val entries: List<AppLogEntry> = emptyList(),
) {
    fun append(entry: AppLogEntry, maxEntries: Int = 500): AppLogSnapshot =
        copy(entries = (listOf(entry) + entries).take(maxEntries))
}

@Serializable
data class SearchHistorySnapshot(
    val queries: List<String> = emptyList(),
) {
    fun remember(query: String, maxQueries: Int = 12): SearchHistorySnapshot {
        val normalized = query.trim()
        if (normalized.isBlank()) return this
        return copy(
            queries = (listOf(normalized) + queries.filterNot { it.equals(normalized, ignoreCase = true) })
                .take(maxQueries),
        )
    }
}

val MovieProgressBackup.progressPercent: Double
    get() = if (totalDuration > 0.0) (currentTime / totalDuration).coerceIn(0.0, 1.0) else 0.0

val EpisodeProgressBackup.progressPercent: Double
    get() = if (totalDuration > 0.0) (currentTime / totalDuration).coerceIn(0.0, 1.0) else 0.0

val ProgressDataBackup.hasUserData: Boolean
    get() = movieProgress.isNotEmpty() || episodeProgress.isNotEmpty() || showMetadata.isNotEmpty()

fun List<BackupCatalog>.mergedWithDefaultCatalogs(): List<BackupCatalog> {
    val savedById = associateBy { it.id }
    val savedIds = savedById.keys
    val merged = this.sortedBy { it.order } + DefaultCatalogs.filterNot { it.id in savedIds }
    return merged.mapIndexed { index, catalog ->
        val default = DefaultCatalogs.firstOrNull { it.id == catalog.id }
        catalog.copy(
            name = catalog.name ?: default?.name,
            source = catalog.source ?: default?.source,
            title = catalog.title ?: default?.title,
            order = index,
            displayStyle = catalog.displayStyle.ifBlank { default?.displayStyle ?: "standard" },
        )
    }
}

fun MovieProgressBackup.withWatchedThreshold(): MovieProgressBackup = copy(
    isWatched = isWatched || progressPercent >= WatchedThreshold,
)

fun EpisodeProgressBackup.withWatchedThreshold(): EpisodeProgressBackup = copy(
    isWatched = isWatched || progressPercent >= WatchedThreshold,
)
