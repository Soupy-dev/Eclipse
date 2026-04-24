package dev.soupy.eclipse.android.data

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import dev.soupy.eclipse.android.BuildConfig
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.network.AniListService
import dev.soupy.eclipse.android.core.network.AniSkipService
import dev.soupy.eclipse.android.core.network.IntroDbService
import dev.soupy.eclipse.android.core.network.StremioService
import dev.soupy.eclipse.android.core.network.TmdbService
import dev.soupy.eclipse.android.core.storage.BackupFileStore
import dev.soupy.eclipse.android.core.storage.CatalogStore
import dev.soupy.eclipse.android.core.storage.DownloadsStore
import dev.soupy.eclipse.android.core.storage.EclipseDatabase
import dev.soupy.eclipse.android.core.storage.KanzenStore
import dev.soupy.eclipse.android.core.storage.LibraryStore
import dev.soupy.eclipse.android.core.storage.LoggerStore
import dev.soupy.eclipse.android.core.storage.MangaStore
import dev.soupy.eclipse.android.core.storage.ProgressStore
import dev.soupy.eclipse.android.core.storage.RatingsStore
import dev.soupy.eclipse.android.core.storage.RecommendationStore
import dev.soupy.eclipse.android.core.storage.SearchHistoryStore
import dev.soupy.eclipse.android.core.storage.SettingsStore
import dev.soupy.eclipse.android.core.storage.TrackerStore

class EclipseAppContainer(
    context: Context,
) {
    private val tmdbApiKey = BuildConfig.TMDB_API_KEY
    private val database: EclipseDatabase = EclipseDatabase.build(context)

    val tmdbService: TmdbService = TmdbService(apiKey = tmdbApiKey)
    val aniListService: AniListService = AniListService()
    val aniSkipService: AniSkipService = AniSkipService()
    val introDbService: IntroDbService = IntroDbService()
    val stremioService: StremioService = StremioService()
    val settingsStore: SettingsStore = SettingsStore(context)
    private val libraryStore: LibraryStore = LibraryStore(
        context = context,
        json = EclipseJson,
    )
    private val progressStore: ProgressStore = ProgressStore(
        context = context,
        json = EclipseJson,
    )
    private val catalogStore: CatalogStore = CatalogStore(
        context = context,
        json = EclipseJson,
    )
    private val ratingsStore: RatingsStore = RatingsStore(
        context = context,
        json = EclipseJson,
    )
    private val trackerStore: TrackerStore = TrackerStore(
        context = context,
        json = EclipseJson,
    )
    private val recommendationStore: RecommendationStore = RecommendationStore(
        context = context,
        json = EclipseJson,
    )
    private val kanzenStore: KanzenStore = KanzenStore(
        context = context,
        json = EclipseJson,
    )
    private val loggerStore: LoggerStore = LoggerStore(
        context = context,
        json = EclipseJson,
    )
    private val searchHistoryStore: SearchHistoryStore = SearchHistoryStore(
        context = context,
        json = EclipseJson,
    )
    private val backupFileStore: BackupFileStore = BackupFileStore(
        context = context,
        json = EclipseJson,
    )
    private val downloadsStore: DownloadsStore = DownloadsStore(
        context = context,
        json = EclipseJson,
    )
    private val mangaStore: MangaStore = MangaStore(
        context = context,
        json = EclipseJson,
    )

    val progressRepository: ProgressRepository = ProgressRepository(
        progressStore = progressStore,
    )
    val catalogRepository: CatalogRepository = CatalogRepository(
        catalogStore = catalogStore,
    )
    val ratingsRepository: RatingsRepository = RatingsRepository(
        ratingsStore = ratingsStore,
    )
    val trackerRepository: TrackerRepository = TrackerRepository(
        trackerStore = trackerStore,
        progressRepository = progressRepository,
    )
    val recommendationRepository: RecommendationRepository = RecommendationRepository(
        recommendationStore = recommendationStore,
        progressStore = progressStore,
        ratingsStore = ratingsStore,
    )
    val kanzenRepository: KanzenRepository = KanzenRepository(
        kanzenStore = kanzenStore,
    )
    val loggerRepository: LoggerRepository = LoggerRepository(
        loggerStore = loggerStore,
    )
    val cacheRepository: CacheRepository = CacheRepository(
        context = context,
    )
    val homeRepository: HomeRepository = HomeRepository(
        tmdbService = tmdbService,
        aniListService = aniListService,
        catalogRepository = catalogRepository,
        recommendationRepository = recommendationRepository,
        settingsStore = settingsStore,
        tmdbEnabled = tmdbApiKey.isNotBlank(),
    )
    private val animeTmdbMapper: AnimeTmdbMapper = AnimeTmdbMapper(
        tmdbService = tmdbService,
    )
    val searchRepository: SearchRepository = SearchRepository(
        tmdbService = tmdbService,
        aniListService = aniListService,
        searchHistoryStore = searchHistoryStore,
        settingsStore = settingsStore,
        tmdbEnabled = tmdbApiKey.isNotBlank(),
    )
    val detailRepository: DetailRepository = DetailRepository(
        tmdbService = tmdbService,
        aniListService = aniListService,
        animeTmdbMapper = animeTmdbMapper,
    )
    val streamResolutionRepository: StreamResolutionRepository = StreamResolutionRepository(
        tmdbService = tmdbService,
        aniListService = aniListService,
        animeTmdbMapper = animeTmdbMapper,
        stremioService = stremioService,
        stremioAddonDao = database.stremioAddonDao(),
        settingsStore = settingsStore,
    )
    val scheduleRepository: ScheduleRepository = ScheduleRepository(
        aniListService = aniListService,
    )
    val libraryRepository: LibraryRepository = LibraryRepository(
        libraryStore = libraryStore,
        progressRepository = progressRepository,
    )
    val servicesRepository: ServicesRepository = ServicesRepository(
        serviceDao = database.serviceDao(),
        stremioAddonDao = database.stremioAddonDao(),
        stremioService = stremioService,
    )
    val backupRepository: BackupRepository = BackupRepository(
        context = context,
        backupFileStore = backupFileStore,
        settingsStore = settingsStore,
        mangaStore = mangaStore,
        serviceDao = database.serviceDao(),
        stremioAddonDao = database.stremioAddonDao(),
        progressRepository = progressRepository,
        catalogRepository = catalogRepository,
        trackerRepository = trackerRepository,
        ratingsRepository = ratingsRepository,
        recommendationRepository = recommendationRepository,
        kanzenRepository = kanzenRepository,
    )
    val downloadsRepository: DownloadsRepository = DownloadsRepository(
        downloadsStore = downloadsStore,
    )
    val mangaRepository: MangaRepository = MangaRepository(
        mangaStore = mangaStore,
        backupFileStore = backupFileStore,
        aniListService = aniListService,
        settingsStore = settingsStore,
    )
}

@Composable
fun rememberAppContainer(): EclipseAppContainer {
    val context = LocalContext.current.applicationContext
    return remember(context) {
        EclipseAppContainer(context)
    }
}

