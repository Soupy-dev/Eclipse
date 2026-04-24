package dev.soupy.eclipse.android

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.automirrored.rounded.MenuBook
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesomeMotion
import androidx.compose.material.icons.rounded.DownloadForOffline
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.ImportContacts
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Stream
import androidx.compose.material.icons.rounded.VideoLibrary
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation.NavDestination.Companion.hierarchy
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
import dev.soupy.eclipse.android.feature.downloads.DownloadsRoute
import dev.soupy.eclipse.android.feature.home.HomeRoute
import dev.soupy.eclipse.android.feature.library.LibraryRoute
import dev.soupy.eclipse.android.feature.manga.MangaRoute
import dev.soupy.eclipse.android.feature.novel.NovelRoute
import dev.soupy.eclipse.android.feature.schedule.ScheduleRoute
import dev.soupy.eclipse.android.feature.search.SearchRoute
import dev.soupy.eclipse.android.feature.services.ServicesRoute
import dev.soupy.eclipse.android.feature.settings.SettingsRoute
import dev.soupy.eclipse.android.ui.detail.AndroidDetailViewModel
import dev.soupy.eclipse.android.ui.downloads.AndroidDownloadsViewModel
import dev.soupy.eclipse.android.ui.home.AndroidHomeViewModel
import dev.soupy.eclipse.android.ui.library.AndroidLibraryViewModel
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

private val destinations = listOf(
    AppDestination("home", "Home", Icons.Rounded.Home),
    AppDestination("search", "Search", Icons.Rounded.Search),
    AppDestination("detail", "Detail", Icons.Rounded.AutoAwesomeMotion),
    AppDestination("schedule", "Schedule", Icons.Rounded.Schedule),
    AppDestination("services", "Services", Icons.Rounded.Stream),
    AppDestination("library", "Library", Icons.Rounded.VideoLibrary),
    AppDestination("downloads", "Downloads", Icons.Rounded.DownloadForOffline),
    AppDestination("settings", "Settings", Icons.Rounded.Settings),
    AppDestination("manga", "Manga", Icons.AutoMirrored.Rounded.MenuBook),
    AppDestination("novel", "Novel", Icons.Rounded.ImportContacts),
)

@Composable
fun EclipseAndroidApp() {
    val appContainer = rememberAppContainer()
    val homeViewModel = rememberFeatureViewModel("home") {
        AndroidHomeViewModel(appContainer.homeRepository)
    }
    val searchViewModel = rememberFeatureViewModel("search") {
        AndroidSearchViewModel(appContainer.searchRepository)
    }
    val detailViewModel = rememberFeatureViewModel("detail") {
        AndroidDetailViewModel(
            repository = appContainer.detailRepository,
            streamResolutionRepository = appContainer.streamResolutionRepository,
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
    val playbackSettings = PlaybackSettingsSnapshot(
        aniSkipAutoSkip = settingsState.aniSkipAutoSkip,
        skip85sEnabled = settingsState.skip85sEnabled,
        showNextEpisodeButton = settingsState.showNextEpisodeButton,
        nextEpisodeThreshold = settingsState.nextEpisodeThreshold,
    )

    var selectedDetailTarget by remember { mutableStateOf<DetailTarget?>(null) }

    LaunchedEffect(selectedDetailTarget) {
        detailViewModel.load(selectedDetailTarget)
    }

    EclipseTheme {
        EclipseBackground {
            val navController = rememberNavController()
            val navBackStackEntry by navController.currentBackStackEntryAsState()
            val currentDestination = navBackStackEntry?.destination

            Scaffold(
                containerColor = androidx.compose.ui.graphics.Color.Transparent,
                bottomBar = {
                    NavigationBar(
                        containerColor = androidx.compose.ui.graphics.Color(0xCC11111A),
                    ) {
                        destinations.forEach { destination ->
                            val selected = currentDestination
                                ?.hierarchy
                                ?.any { it.route == destination.route } == true
                            NavigationBarItem(
                                selected = selected,
                                onClick = {
                                    navController.navigate(destination.route) {
                                        launchSingleTop = true
                                        restoreState = true
                                        popUpTo(navController.graph.startDestinationId) {
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
                            onSelect = { target ->
                                selectedDetailTarget = target
                                navController.navigate("detail")
                            },
                        )
                    }
                    composable("detail") {
                        DetailRoute(
                            state = detailState,
                            onRetry = detailViewModel::retry,
                            onSaveToLibrary = {
                                detailViewModel.currentLibraryItemDraft()?.let(libraryViewModel::toggleSaved)
                            },
                            onQueueResume = {
                                detailViewModel.currentContinueWatchingDraft()
                                    ?.let(libraryViewModel::recordContinueWatching)
                            },
                            onQueueDownload = {
                                detailViewModel.currentDownloadDraft()
                                    ?.let(downloadsViewModel::queueDownload)
                            },
                            onResolveStreams = detailViewModel::resolveStreams,
                            onPlayStream = detailViewModel::playResolvedStream,
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
                            onImportAddon = servicesViewModel::importAddon,
                            onToggleServiceEnabled = servicesViewModel::setServiceEnabled,
                            onToggleAddonEnabled = servicesViewModel::setAddonEnabled,
                            onMoveServiceUp = servicesViewModel::moveServiceUp,
                            onMoveServiceDown = servicesViewModel::moveServiceDown,
                            onMoveAddonUp = servicesViewModel::moveAddonUp,
                            onMoveAddonDown = servicesViewModel::moveAddonDown,
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
                            onMarkComplete = downloadsViewModel::markComplete,
                            onRemove = downloadsViewModel::remove,
                            onClearCompleted = downloadsViewModel::clearCompleted,
                        )
                    }
                    composable("settings") {
                        SettingsRoute(
                            state = settingsState,
                            onAutoModeChanged = settingsViewModel::setAutoModeEnabled,
                            onShowNextEpisodeChanged = settingsViewModel::setShowNextEpisodeButton,
                            onNextEpisodeThresholdChanged = settingsViewModel::setNextEpisodeThreshold,
                            onPlayerSelected = settingsViewModel::setInAppPlayer,
                            onAniSkipAutoSkipChanged = settingsViewModel::setAniSkipAutoSkip,
                            onSkip85sChanged = settingsViewModel::setSkip85sEnabled,
                            onExportBackup = settingsViewModel::exportBackup,
                            onImportBackup = settingsViewModel::importBackup,
                        )
                    }
                    composable("manga") { MangaRoute() }
                    composable("novel") { NovelRoute() }
                }
            }
        }
    }
}

