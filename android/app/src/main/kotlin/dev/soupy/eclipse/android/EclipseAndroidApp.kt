package dev.soupy.eclipse.android

import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.material.icons.automirrored.rounded.MenuBook
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesomeMotion
import androidx.compose.material.icons.rounded.DownloadForOffline
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.ImportContacts
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Stream
import androidx.compose.material.icons.rounded.VideoLibrary
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import dev.soupy.eclipse.android.core.design.EclipseBackground
import dev.soupy.eclipse.android.core.design.EclipseTheme
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.PlaybackSettingsSnapshot
import dev.soupy.eclipse.android.data.rememberAppContainer
import dev.soupy.eclipse.android.feature.detail.DetailRoute
import dev.soupy.eclipse.android.feature.detail.DetailCollectionRow
import dev.soupy.eclipse.android.feature.downloads.DownloadsRoute
import dev.soupy.eclipse.android.feature.home.HomeRoute
import dev.soupy.eclipse.android.feature.library.LibraryRoute
import dev.soupy.eclipse.android.feature.manga.MangaRoute
import dev.soupy.eclipse.android.feature.manga.MangaSurfaceMode
import dev.soupy.eclipse.android.feature.manga.MangaReaderSettingsRow
import dev.soupy.eclipse.android.feature.novel.NovelRoute
import dev.soupy.eclipse.android.feature.novel.NovelReaderSettingsRow
import dev.soupy.eclipse.android.feature.schedule.ScheduleRoute
import dev.soupy.eclipse.android.feature.search.SearchRoute
import dev.soupy.eclipse.android.feature.services.ServicesRoute
import dev.soupy.eclipse.android.feature.settings.SettingsRoute
import dev.soupy.eclipse.android.ui.detail.AndroidDetailViewModel
import dev.soupy.eclipse.android.ui.downloads.AndroidDownloadsViewModel
import dev.soupy.eclipse.android.ui.home.AndroidHomeViewModel
import dev.soupy.eclipse.android.ui.library.AndroidLibraryViewModel
import dev.soupy.eclipse.android.ui.manga.AndroidMangaViewModel
import dev.soupy.eclipse.android.ui.novel.AndroidNovelViewModel
import dev.soupy.eclipse.android.ui.rememberFeatureViewModel
import dev.soupy.eclipse.android.ui.schedule.AndroidScheduleViewModel
import dev.soupy.eclipse.android.ui.search.AndroidSearchViewModel
import dev.soupy.eclipse.android.ui.services.AndroidServicesViewModel
import dev.soupy.eclipse.android.ui.settings.AndroidSettingsViewModel

private data class AppDestination(
    val route: String,
    val label: String,
    val icon: ImageVector,
)

private val lunaDestinations = listOf(
    AppDestination("home", "Home", Icons.Rounded.Home),
    AppDestination("schedule", "Schedule", Icons.Rounded.Schedule),
    AppDestination("downloads", "Downloads", Icons.Rounded.DownloadForOffline),
    AppDestination("library", "Library", Icons.Rounded.VideoLibrary),
    AppDestination("search", "Search", Icons.Rounded.Search),
)

private val kanzenDestinations = listOf(
    AppDestination("manga", "Home", Icons.Rounded.Home),
    AppDestination("kanzen-library", "Library", Icons.AutoMirrored.Rounded.MenuBook),
    AppDestination("kanzen-search", "Search", Icons.Rounded.Search),
    AppDestination("kanzen-history", "History", Icons.Rounded.History),
    AppDestination("settings", "Settings", Icons.Rounded.Settings),
)

@Composable
fun EclipseAndroidApp(
    trackerCallbackUri: String? = null,
    onTrackerCallbackConsumed: () -> Unit = {},
) {
    val appContainer = rememberAppContainer()
    val homeViewModel = rememberFeatureViewModel("home") {
        AndroidHomeViewModel(appContainer.homeRepository)
    }
    val searchViewModel = rememberFeatureViewModel("search") {
        AndroidSearchViewModel(
            repository = appContainer.searchRepository,
            settingsStore = appContainer.settingsStore,
        )
    }
    val detailViewModel = rememberFeatureViewModel("detail") {
        AndroidDetailViewModel(
            repository = appContainer.detailRepository,
            streamResolutionRepository = appContainer.streamResolutionRepository,
            progressRepository = appContainer.progressRepository,
            ratingsRepository = appContainer.ratingsRepository,
            trackerRepository = appContainer.trackerRepository,
            aniSkipService = appContainer.aniSkipService,
            introDbService = appContainer.introDbService,
            settingsStore = appContainer.settingsStore,
        )
    }
    val scheduleViewModel = rememberFeatureViewModel("schedule") {
        AndroidScheduleViewModel(appContainer.scheduleRepository)
    }
    val libraryViewModel = rememberFeatureViewModel("library") {
        AndroidLibraryViewModel(appContainer.libraryRepository)
    }
    val servicesViewModel = rememberFeatureViewModel("services") {
        AndroidServicesViewModel(
            repository = appContainer.servicesRepository,
            settingsStore = appContainer.settingsStore,
        )
    }
    val downloadsViewModel = rememberFeatureViewModel("downloads") {
        AndroidDownloadsViewModel(appContainer.downloadsRepository)
    }
    val settingsViewModel = rememberFeatureViewModel("settings") {
        AndroidSettingsViewModel(
            settingsStore = appContainer.settingsStore,
            backupRepository = appContainer.backupRepository,
            catalogRepository = appContainer.catalogRepository,
            cacheRepository = appContainer.cacheRepository,
            loggerRepository = appContainer.loggerRepository,
            trackerRepository = appContainer.trackerRepository,
            libraryRepository = appContainer.libraryRepository,
            mangaRepository = appContainer.mangaRepository,
            aniListService = appContainer.aniListService,
            releaseRepository = appContainer.releaseRepository,
            servicesRepository = appContainer.servicesRepository,
        )
    }
    val mangaViewModel = rememberFeatureViewModel("manga") {
        AndroidMangaViewModel(
            repository = appContainer.mangaRepository,
            readerCacheRepository = appContainer.readerCacheRepository,
        )
    }
    val novelViewModel = rememberFeatureViewModel("novel") {
        AndroidNovelViewModel(
            repository = appContainer.mangaRepository,
            readerCacheRepository = appContainer.readerCacheRepository,
        )
    }

    val homeState by homeViewModel.state.collectAsState()
    val searchState by searchViewModel.state.collectAsState()
    val detailState by detailViewModel.state.collectAsState()
    val scheduleState by scheduleViewModel.state.collectAsState()
    val libraryState by libraryViewModel.state.collectAsState()
    val servicesState by servicesViewModel.state.collectAsState()
    val downloadsState by downloadsViewModel.state.collectAsState()
    val settingsState by settingsViewModel.state.collectAsState()
    val mangaState by mangaViewModel.state.collectAsState()
    val novelState by novelViewModel.state.collectAsState()
    val playbackSettings = PlaybackSettingsSnapshot(
        enableSubtitlesByDefault = settingsState.enableSubtitlesByDefault,
        defaultSubtitleLanguage = settingsState.defaultSubtitleLanguage,
        preferredAnimeAudioLanguage = settingsState.preferredAnimeAudioLanguage,
        subtitleForegroundColor = settingsState.subtitleForegroundColor,
        subtitleStrokeColor = settingsState.subtitleStrokeColor,
        subtitleFontSize = settingsState.subtitleFontSize,
        subtitleStrokeWidth = settingsState.subtitleStrokeWidth,
        subtitleVerticalOffset = settingsState.subtitleVerticalOffset,
        holdSpeed = settingsState.holdSpeedPlayer,
        externalPlayer = settingsState.externalPlayer,
        alwaysLandscape = settingsState.alwaysLandscape,
        vlcHeaderProxyEnabled = settingsState.vlcHeaderProxyEnabled,
        aniSkipAutoSkip = settingsState.aniSkipAutoSkip,
        skip85sEnabled = settingsState.skip85sEnabled,
        skip85sAlwaysVisible = settingsState.skip85sAlwaysVisible,
        showNextEpisodeButton = settingsState.showNextEpisodeButton,
        nextEpisodeThreshold = settingsState.nextEpisodeThreshold,
    )
    val mangaReaderSettings = MangaReaderSettingsRow(
        readingMode = settingsState.readingMode,
        readerFontSize = settingsState.readerFontSize,
        readerFontFamily = settingsState.readerFontFamily,
        readerFontWeight = settingsState.readerFontWeight,
        readerColorPreset = settingsState.readerColorPreset,
        readerLineSpacing = settingsState.readerLineSpacing,
        readerMargin = settingsState.readerMargin,
        readerTextAlignment = settingsState.readerTextAlignment,
    )
    val novelReaderSettings = NovelReaderSettingsRow(
        readingMode = settingsState.readingMode,
        readerFontSize = settingsState.readerFontSize,
        readerFontFamily = settingsState.readerFontFamily,
        readerFontWeight = settingsState.readerFontWeight,
        readerColorPreset = settingsState.readerColorPreset,
        readerLineSpacing = settingsState.readerLineSpacing,
        readerMargin = settingsState.readerMargin,
        readerTextAlignment = settingsState.readerTextAlignment,
    )

    var selectedDetailTarget by remember { mutableStateOf<DetailTarget?>(null) }
    var settingsReturnRoute by remember { mutableStateOf("home") }

    LaunchedEffect(selectedDetailTarget) {
        detailViewModel.load(selectedDetailTarget)
    }

    LaunchedEffect(trackerCallbackUri) {
        val callbackUri = trackerCallbackUri?.takeIf { it.isNotBlank() } ?: return@LaunchedEffect
        settingsViewModel.handleTrackerOAuthCallback(callbackUri)
        onTrackerCallbackConsumed()
    }

    val visibleDestinations = remember(settingsState.showScheduleTab, settingsState.showKanzen) {
        if (settingsState.showKanzen) {
            kanzenDestinations
        } else {
            lunaDestinations.filter { destination ->
                destination.route != "schedule" || settingsState.showScheduleTab
            }
        }
    }

    EclipseTheme(
        accentColor = settingsState.accentColor,
        appearance = settingsState.selectedAppearance,
    ) {
        EclipseBackground(appearance = settingsState.selectedAppearance) {
            val uriHandler = LocalUriHandler.current
            val navController = rememberNavController()
            val navBackStackEntry by navController.currentBackStackEntryAsState()
            val currentDestination = navBackStackEntry?.destination
            val currentRoute = currentDestination?.route

            LaunchedEffect(settingsState.showKanzen) {
                navController.navigate(if (settingsState.showKanzen) "manga" else "home") {
                    launchSingleTop = true
                }
            }

            if (settingsState.githubReleaseShowAlertPending) {
                AlertDialog(
                    onDismissRequest = settingsViewModel::consumeGitHubReleasePrompt,
                    title = { Text("Update Available") },
                    text = {
                        Text(
                            settingsState.githubReleaseLatestVersion
                                .takeIf { it.isNotBlank() }
                                ?.let { "A new Eclipse release ($it) is available on GitHub." }
                                ?: "A new Eclipse release is available on GitHub.",
                        )
                    },
                    confirmButton = {
                        TextButton(
                            onClick = {
                                settingsViewModel.consumeGitHubReleasePrompt()
                                settingsState.githubReleaseUrl.takeIf { it.isNotBlank() }?.let(uriHandler::openUri)
                            },
                        ) {
                            Text("Open Release")
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = settingsViewModel::consumeGitHubReleasePrompt) {
                            Text("Later")
                        }
                    },
                )
            }

            Scaffold(
                containerColor = androidx.compose.ui.graphics.Color.Transparent,
                contentWindowInsets = WindowInsets(0.dp),
                floatingActionButton = {
                    if (!settingsState.showKanzen && currentRoute in lunaDestinations.map { it.route }) {
                        FloatingActionButton(
                            onClick = {
                                settingsReturnRoute = currentRoute ?: "home"
                                navController.navigate("settings") {
                                    launchSingleTop = true
                                }
                            },
                            containerColor = androidx.compose.ui.graphics.Color(0xEE1F2433),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Settings,
                                contentDescription = "Settings",
                            )
                        }
                    }
                },
                bottomBar = {
                    if (currentRoute != "settings") {
                        NavigationBar(
                            containerColor = androidx.compose.ui.graphics.Color(0xCC11111A),
                        ) {
                            visibleDestinations.forEach { destination ->
                                val selected = currentDestination
                                    ?.hierarchy
                                    ?.any { it.route == destination.route } == true
                                NavigationBarItem(
                                    selected = selected,
                                    onClick = {
                                        navController.navigate(destination.route) {
                                            launchSingleTop = true
                                            restoreState = true
                                            popUpTo(navController.graph.findStartDestination().id) {
                                                saveState = true
                                            }
                                        }
                                    },
                                    icon = {
                                        Icon(
                                            imageVector = destination.icon,
                                            contentDescription = destination.label,
                                        )
                                    },
                                    label = { Text(destination.label) },
                                )
                            }
                        }
                    }
                },
            ) { innerPadding ->
                NavHost(
                    navController = navController,
                    startDestination = "home",
                    modifier = Modifier.padding(innerPadding),
                ) {
                    composable("home") {
                        HomeRoute(
                            state = homeState,
                            onRefresh = homeViewModel::refresh,
                            onSelect = { target ->
                                selectedDetailTarget = target
                                navController.navigate("detail")
                            },
                        )
                    }
                    composable("search") {
                        SearchRoute(
                            state = searchState,
                            onQueryChange = searchViewModel::updateQuery,
                            onSearch = searchViewModel::search,
                            onRecentQuery = searchViewModel::selectRecentQuery,
                            onSourceSelected = searchViewModel::selectSource,
                            onSelect = { target ->
                                selectedDetailTarget = target
                                navController.navigate("detail")
                            },
                        )
                    }
                    composable("detail") {
                        val currentLibraryDraft = detailViewModel.currentLibraryItemDraft()
                        DetailRoute(
                            state = detailState.copy(
                                seasonMenu = settingsState.seasonMenu,
                                horizontalEpisodeList = settingsState.horizontalEpisodeList,
                                collections = libraryState.collections.map { collection ->
                                    DetailCollectionRow(
                                        id = collection.id,
                                        name = collection.name,
                                        isSelected = currentLibraryDraft?.let { draft ->
                                            collection.items.any { item -> item.detailTarget == draft.detailTarget }
                                        } == true,
                                    )
                                },
                            ),
                            onRetry = detailViewModel::retry,
                            onSaveToLibrary = {
                                detailViewModel.currentLibraryItemDraft()?.let(libraryViewModel::toggleSaved)
                            },
                            onAddToCollection = { collectionId ->
                                detailViewModel.currentLibraryItemDraft()
                                    ?.let { draft -> libraryViewModel.saveToCollection(collectionId, draft) }
                            },
                            onQueueResume = {
                                detailViewModel.currentContinueWatchingDraft()
                                    ?.let(libraryViewModel::recordContinueWatching)
                            },
                            onQueueDownload = {
                                detailViewModel.currentDownloadDraft()
                                    ?.let(downloadsViewModel::queueDownload)
                            },
                            onSetRating = detailViewModel::setUserRating,
                            onClearRating = detailViewModel::clearUserRating,
                            onMarkWatched = detailViewModel::markCurrentWatched,
                            onMarkUnwatched = detailViewModel::markCurrentUnwatched,
                            onResolveStreams = detailViewModel::resolveStreams,
                            onResolveEpisodeStreams = detailViewModel::resolveEpisodeStreams,
                            onMarkEpisodeWatched = detailViewModel::markEpisodeWatched,
                            onMarkEpisodeUnwatched = detailViewModel::markEpisodeUnwatched,
                            onMarkPreviousEpisodesWatched = detailViewModel::markPreviousEpisodesWatched,
                            onPlayStream = detailViewModel::playResolvedStream,
                            onPlayNextEpisode = detailViewModel::playNextEpisode,
                            onPlaybackProgress = { progress ->
                                detailViewModel.currentPlaybackProgressDraft(
                                    positionMs = progress.positionMs,
                                    durationMs = progress.durationMs,
                                    isFinished = progress.isFinished,
                                )?.let(libraryViewModel::syncContinueWatching)
                            },
                            preferredPlayer = settingsState.inAppPlayer,
                            playbackSettings = playbackSettings,
                        )
                    }
                    composable("schedule") {
                        ScheduleRoute(
                            state = scheduleState,
                            onRefresh = scheduleViewModel::refresh,
                            onSelect = { target ->
                                selectedDetailTarget = target
                                navController.navigate("detail")
                            },
                        )
                    }
                    composable("services") {
                        ServicesRoute(
                            state = servicesState,
                            onAutoModeChanged = servicesViewModel::setAutoModeEnabled,
                            onAutoModeSourceChanged = servicesViewModel::setAutoModeSourceEnabled,
                            onAddService = servicesViewModel::addService,
                            onSaveServiceConfiguration = servicesViewModel::setServiceConfiguration,
                            onImportAddon = servicesViewModel::importAddon,
                            onToggleServiceEnabled = servicesViewModel::setServiceEnabled,
                            onToggleAddonEnabled = servicesViewModel::setAddonEnabled,
                            onMoveServiceUp = servicesViewModel::moveServiceUp,
                            onMoveServiceDown = servicesViewModel::moveServiceDown,
                            onMoveAddonUp = servicesViewModel::moveAddonUp,
                            onMoveAddonDown = servicesViewModel::moveAddonDown,
                            onRefreshAddon = servicesViewModel::refreshAddon,
                            onRefreshAllAddons = servicesViewModel::refreshAllAddons,
                            onRemoveService = servicesViewModel::removeService,
                            onRemoveAddon = servicesViewModel::removeAddon,
                        )
                    }
                    composable("library") {
                        LibraryRoute(
                            state = libraryState,
                            onRefresh = libraryViewModel::refresh,
                            onSelect = { target ->
                                selectedDetailTarget = target
                                navController.navigate("detail")
                            },
                            onRemoveSaved = libraryViewModel::removeSaved,
                            onRemoveContinueWatching = libraryViewModel::removeContinueWatching,
                            onCreateCollection = libraryViewModel::createCollection,
                            onDeleteCollection = libraryViewModel::deleteCollection,
                            onRemoveFromCollection = libraryViewModel::removeFromCollection,
                        )
                    }
                    composable("downloads") {
                        DownloadsRoute(
                            state = downloadsState,
                            onRefresh = downloadsViewModel::refresh,
                            onSelect = { target ->
                                selectedDetailTarget = target
                                navController.navigate("detail")
                            },
                            onPause = downloadsViewModel::pause,
                            onResume = downloadsViewModel::resume,
                            onPlayOffline = downloadsViewModel::playOffline,
                            onMarkComplete = downloadsViewModel::markComplete,
                            onRemoveLocalFile = downloadsViewModel::removeLocalFile,
                            onRemove = downloadsViewModel::remove,
                            onPauseAll = downloadsViewModel::pauseAll,
                            onResumeAll = downloadsViewModel::resumeAll,
                            onRetryFailed = downloadsViewModel::retryFailed,
                            onCancelActive = downloadsViewModel::cancelActive,
                            onClearCompleted = downloadsViewModel::clearCompleted,
                            onClearTarget = downloadsViewModel::clearTarget,
                            onClearAll = downloadsViewModel::clearAll,
                            onCleanupOrphans = downloadsViewModel::cleanupOrphans,
                            onVerifyFiles = downloadsViewModel::verifyFiles,
                            preferredPlayer = settingsState.inAppPlayer,
                            playbackSettings = playbackSettings,
                        )
                    }
                    composable("settings") {
                        SettingsRoute(
                            state = settingsState,
                            onClose = {
                                if (!navController.popBackStack()) {
                                    navController.navigate(if (settingsState.showKanzen) "manga" else settingsReturnRoute) {
                                        launchSingleTop = true
                                        restoreState = true
                                        popUpTo(navController.graph.findStartDestination().id) {
                                            saveState = true
                                        }
                                    }
                                }
                            },
                            onAccentColorChanged = settingsViewModel::setAccentColor,
                            onTmdbLanguageChanged = settingsViewModel::setTmdbLanguage,
                            onAppearanceChanged = settingsViewModel::setAppearance,
                            onShowScheduleTabChanged = settingsViewModel::setShowScheduleTab,
                            onShowKanzenChanged = settingsViewModel::setShowKanzen,
                            onSeasonMenuChanged = settingsViewModel::setSeasonMenu,
                            onHorizontalEpisodeListChanged = settingsViewModel::setHorizontalEpisodeList,
                            onMediaColumnsPortraitChanged = settingsViewModel::setMediaColumnsPortrait,
                            onMediaColumnsLandscapeChanged = settingsViewModel::setMediaColumnsLandscape,
                            onOpenServices = { navController.navigate("services") },
                            onAutoUpdateServicesChanged = settingsViewModel::setAutoUpdateServicesEnabled,
                            onCheckGitHubRelease = settingsViewModel::checkGitHubReleaseNow,
                            onGitHubReleaseAutoCheckChanged = settingsViewModel::setGitHubReleaseAutoCheckEnabled,
                            onAutoModeChanged = settingsViewModel::setAutoModeEnabled,
                            onShowNextEpisodeChanged = settingsViewModel::setShowNextEpisodeButton,
                            onNextEpisodeThresholdChanged = settingsViewModel::setNextEpisodeThreshold,
                            onPlayerSelected = settingsViewModel::setInAppPlayer,
                            onEnableSubtitlesByDefaultChanged = settingsViewModel::setEnableSubtitlesByDefault,
                            onDefaultSubtitleLanguageChanged = settingsViewModel::setDefaultSubtitleLanguage,
                            onPreferredAnimeAudioLanguageChanged = settingsViewModel::setPreferredAnimeAudioLanguage,
                            onHoldSpeedChanged = settingsViewModel::setHoldSpeed,
                            onExternalPlayerChanged = settingsViewModel::setExternalPlayer,
                            onAlwaysLandscapeChanged = settingsViewModel::setAlwaysLandscape,
                            onVlcHeaderProxyChanged = settingsViewModel::setVlcHeaderProxyEnabled,
                            onSubtitleForegroundColorChanged = settingsViewModel::setSubtitleForegroundColor,
                            onSubtitleStrokeColorChanged = settingsViewModel::setSubtitleStrokeColor,
                            onSubtitleStrokeWidthChanged = settingsViewModel::setSubtitleStrokeWidth,
                            onSubtitleFontSizeChanged = settingsViewModel::setSubtitleFontSize,
                            onSubtitleVerticalOffsetChanged = settingsViewModel::setSubtitleVerticalOffset,
                            onAniSkipEnabledChanged = settingsViewModel::setAniSkipEnabled,
                            onIntroDbEnabledChanged = settingsViewModel::setIntroDbEnabled,
                            onAniSkipAutoSkipChanged = settingsViewModel::setAniSkipAutoSkip,
                            onSkip85sChanged = settingsViewModel::setSkip85sEnabled,
                            onSkip85sAlwaysVisibleChanged = settingsViewModel::setSkip85sAlwaysVisible,
                            onCatalogEnabledChanged = settingsViewModel::setCatalogEnabled,
                            onMoveCatalogUp = settingsViewModel::moveCatalogUp,
                            onMoveCatalogDown = settingsViewModel::moveCatalogDown,
                            onRefreshStorage = settingsViewModel::refreshStorage,
                            onClearCache = settingsViewModel::clearCache,
                            onAutoClearCacheEnabledChanged = settingsViewModel::setAutoClearCacheEnabled,
                            onAutoClearCacheThresholdChanged = settingsViewModel::setAutoClearCacheThreshold,
                            onRefreshLogs = settingsViewModel::refreshLogs,
                            onClearLogs = settingsViewModel::clearLogs,
                            onReadingModeChanged = settingsViewModel::setReadingMode,
                            onReaderFontSizeChanged = settingsViewModel::setReaderFontSize,
                            onReaderFontFamilyChanged = settingsViewModel::setReaderFontFamily,
                            onReaderFontWeightChanged = settingsViewModel::setReaderFontWeight,
                            onReaderColorPresetChanged = settingsViewModel::setReaderColorPreset,
                            onReaderLineSpacingChanged = settingsViewModel::setReaderLineSpacing,
                            onReaderMarginChanged = settingsViewModel::setReaderMargin,
                            onReaderAlignmentChanged = settingsViewModel::setReaderTextAlignment,
                            onKanzenAutoUpdateModulesChanged = settingsViewModel::setKanzenAutoUpdateModules,
                            onTrackerManualConnect = settingsViewModel::saveTrackerAccount,
                            onTrackerSyncEnabledChanged = settingsViewModel::setTrackerSyncEnabled,
                            onTrackerDisconnect = settingsViewModel::disconnectTracker,
                            onTrackerSyncNow = settingsViewModel::syncTrackersNow,
                            onAniListImportLibrary = {
                                settingsViewModel.importAniListLibrary(libraryViewModel::refresh)
                            },
                            onAniListImportMangaLibrary = {
                                settingsViewModel.importAniListMangaLibrary {
                                    mangaViewModel.refresh()
                                    novelViewModel.refresh()
                                }
                            },
                            onAniListSyncMangaProgress = settingsViewModel::syncMangaProgressNow,
                            onExportBackup = settingsViewModel::exportBackup,
                            onImportBackup = settingsViewModel::importBackup,
                            onHighQualityThresholdChanged = settingsViewModel::setHighQualityThreshold,
                            onFilterHorrorContentChanged = settingsViewModel::setFilterHorrorContent,
                            onSimilarityAlgorithmChanged = settingsViewModel::setSimilarityAlgorithm,
                        )
                    }
                    composable("manga") {
                        MangaRoute(
                            state = mangaState.copy(readerSettings = mangaReaderSettings),
                            surfaceMode = MangaSurfaceMode.HOME,
                            onRefresh = mangaViewModel::refresh,
                            onQueryChange = mangaViewModel::updateQuery,
                            onSearch = mangaViewModel::search,
                            onSaveItem = mangaViewModel::saveItem,
                            onRemoveItem = mangaViewModel::removeItem,
                            onOpenDetail = mangaViewModel::openDetail,
                            onCloseDetail = mangaViewModel::closeDetail,
                            onReadNext = mangaViewModel::readNextChapter,
                            onUnreadLast = mangaViewModel::unreadLastChapter,
                            onReadPrevious = mangaViewModel::readPreviousChapter,
                            onOpenReader = mangaViewModel::openReader,
                            onCloseReader = mangaViewModel::closeReader,
                            onReadChapter = mangaViewModel::readChapter,
                            onToggleFavorite = mangaViewModel::toggleFavorite,
                            onClearProgress = mangaViewModel::clearReadingProgress,
                            onAddModule = mangaViewModel::addModule,
                            onSetModuleActive = mangaViewModel::setModuleActive,
                            onUpdateModule = mangaViewModel::updateModule,
                            onUpdateAllModules = mangaViewModel::updateAllModules,
                            onRemoveModule = mangaViewModel::removeModule,
                            onClearReaderCache = mangaViewModel::clearReaderCache,
                            onCreateCollection = mangaViewModel::createCollection,
                            onDeleteCollection = mangaViewModel::deleteCollection,
                            onAddItemToCollection = mangaViewModel::addItemToCollection,
                            onRemoveItemFromCollection = mangaViewModel::removeItemFromCollection,
                        )
                    }
                    composable("kanzen-library") {
                        MangaRoute(
                            state = mangaState.copy(readerSettings = mangaReaderSettings),
                            surfaceMode = MangaSurfaceMode.LIBRARY,
                            onRefresh = mangaViewModel::refresh,
                            onQueryChange = mangaViewModel::updateQuery,
                            onSearch = mangaViewModel::search,
                            onSaveItem = mangaViewModel::saveItem,
                            onRemoveItem = mangaViewModel::removeItem,
                            onOpenDetail = mangaViewModel::openDetail,
                            onCloseDetail = mangaViewModel::closeDetail,
                            onReadNext = mangaViewModel::readNextChapter,
                            onUnreadLast = mangaViewModel::unreadLastChapter,
                            onReadPrevious = mangaViewModel::readPreviousChapter,
                            onOpenReader = mangaViewModel::openReader,
                            onCloseReader = mangaViewModel::closeReader,
                            onReadChapter = mangaViewModel::readChapter,
                            onToggleFavorite = mangaViewModel::toggleFavorite,
                            onClearProgress = mangaViewModel::clearReadingProgress,
                            onAddModule = mangaViewModel::addModule,
                            onSetModuleActive = mangaViewModel::setModuleActive,
                            onUpdateModule = mangaViewModel::updateModule,
                            onUpdateAllModules = mangaViewModel::updateAllModules,
                            onRemoveModule = mangaViewModel::removeModule,
                            onClearReaderCache = mangaViewModel::clearReaderCache,
                            onCreateCollection = mangaViewModel::createCollection,
                            onDeleteCollection = mangaViewModel::deleteCollection,
                            onAddItemToCollection = mangaViewModel::addItemToCollection,
                            onRemoveItemFromCollection = mangaViewModel::removeItemFromCollection,
                        )
                    }
                    composable("kanzen-search") {
                        MangaRoute(
                            state = mangaState.copy(readerSettings = mangaReaderSettings),
                            surfaceMode = MangaSurfaceMode.SEARCH,
                            onRefresh = mangaViewModel::refresh,
                            onQueryChange = mangaViewModel::updateQuery,
                            onSearch = mangaViewModel::search,
                            onSaveItem = mangaViewModel::saveItem,
                            onRemoveItem = mangaViewModel::removeItem,
                            onOpenDetail = mangaViewModel::openDetail,
                            onCloseDetail = mangaViewModel::closeDetail,
                            onReadNext = mangaViewModel::readNextChapter,
                            onUnreadLast = mangaViewModel::unreadLastChapter,
                            onReadPrevious = mangaViewModel::readPreviousChapter,
                            onOpenReader = mangaViewModel::openReader,
                            onCloseReader = mangaViewModel::closeReader,
                            onReadChapter = mangaViewModel::readChapter,
                            onToggleFavorite = mangaViewModel::toggleFavorite,
                            onClearProgress = mangaViewModel::clearReadingProgress,
                            onAddModule = mangaViewModel::addModule,
                            onSetModuleActive = mangaViewModel::setModuleActive,
                            onUpdateModule = mangaViewModel::updateModule,
                            onUpdateAllModules = mangaViewModel::updateAllModules,
                            onRemoveModule = mangaViewModel::removeModule,
                            onClearReaderCache = mangaViewModel::clearReaderCache,
                            onCreateCollection = mangaViewModel::createCollection,
                            onDeleteCollection = mangaViewModel::deleteCollection,
                            onAddItemToCollection = mangaViewModel::addItemToCollection,
                            onRemoveItemFromCollection = mangaViewModel::removeItemFromCollection,
                        )
                    }
                    composable("kanzen-history") {
                        MangaRoute(
                            state = mangaState.copy(readerSettings = mangaReaderSettings),
                            surfaceMode = MangaSurfaceMode.HISTORY,
                            onRefresh = mangaViewModel::refresh,
                            onQueryChange = mangaViewModel::updateQuery,
                            onSearch = mangaViewModel::search,
                            onSaveItem = mangaViewModel::saveItem,
                            onRemoveItem = mangaViewModel::removeItem,
                            onOpenDetail = mangaViewModel::openDetail,
                            onCloseDetail = mangaViewModel::closeDetail,
                            onReadNext = mangaViewModel::readNextChapter,
                            onUnreadLast = mangaViewModel::unreadLastChapter,
                            onReadPrevious = mangaViewModel::readPreviousChapter,
                            onOpenReader = mangaViewModel::openReader,
                            onCloseReader = mangaViewModel::closeReader,
                            onReadChapter = mangaViewModel::readChapter,
                            onToggleFavorite = mangaViewModel::toggleFavorite,
                            onClearProgress = mangaViewModel::clearReadingProgress,
                            onAddModule = mangaViewModel::addModule,
                            onSetModuleActive = mangaViewModel::setModuleActive,
                            onUpdateModule = mangaViewModel::updateModule,
                            onUpdateAllModules = mangaViewModel::updateAllModules,
                            onRemoveModule = mangaViewModel::removeModule,
                            onClearReaderCache = mangaViewModel::clearReaderCache,
                            onCreateCollection = mangaViewModel::createCollection,
                            onDeleteCollection = mangaViewModel::deleteCollection,
                            onAddItemToCollection = mangaViewModel::addItemToCollection,
                            onRemoveItemFromCollection = mangaViewModel::removeItemFromCollection,
                        )
                    }
                    composable("novel") {
                        NovelRoute(
                            state = novelState.copy(readerSettings = novelReaderSettings),
                            onRefresh = novelViewModel::refresh,
                            onQueryChange = novelViewModel::updateQuery,
                            onSearch = novelViewModel::search,
                            onSaveItem = novelViewModel::saveItem,
                            onRemoveItem = novelViewModel::removeItem,
                            onOpenDetail = novelViewModel::openDetail,
                            onCloseDetail = novelViewModel::closeDetail,
                            onReadNext = novelViewModel::readNextChapter,
                            onUnreadLast = novelViewModel::unreadLastChapter,
                            onReadPrevious = novelViewModel::readPreviousChapter,
                            onOpenReader = novelViewModel::openReader,
                            onCloseReader = novelViewModel::closeReader,
                            onReadChapter = novelViewModel::readChapter,
                            onToggleFavorite = novelViewModel::toggleFavorite,
                            onClearProgress = novelViewModel::clearReadingProgress,
                            onAddModule = novelViewModel::addModule,
                            onSetModuleActive = novelViewModel::setModuleActive,
                            onUpdateModule = novelViewModel::updateModule,
                            onUpdateAllModules = novelViewModel::updateAllModules,
                            onRemoveModule = novelViewModel::removeModule,
                            onClearReaderCache = novelViewModel::clearReaderCache,
                        )
                    }
                }
            }
        }
    }
}

