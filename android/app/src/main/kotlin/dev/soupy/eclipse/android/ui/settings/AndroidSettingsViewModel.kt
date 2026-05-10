package dev.soupy.eclipse.android.ui.settings

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.soupy.eclipse.android.core.model.AniListMedia
import dev.soupy.eclipse.android.core.model.InAppPlayer
import dev.soupy.eclipse.android.core.model.SimilarityAlgorithm
import dev.soupy.eclipse.android.core.model.TrackerAccountSnapshot
import dev.soupy.eclipse.android.core.model.TrackerStateSnapshot
import dev.soupy.eclipse.android.core.model.displayTitle
import dev.soupy.eclipse.android.core.network.AniListService
import dev.soupy.eclipse.android.core.network.MyAnimeListService
import dev.soupy.eclipse.android.core.network.NetworkResult
import dev.soupy.eclipse.android.core.storage.AppSettings
import dev.soupy.eclipse.android.core.storage.SettingsStore
import dev.soupy.eclipse.android.data.AniListLibraryImportDraft
import dev.soupy.eclipse.android.data.AniListMangaLibraryImportDraft
import dev.soupy.eclipse.android.data.BackupRepository
import dev.soupy.eclipse.android.data.BackupStatusSnapshot
import dev.soupy.eclipse.android.data.CacheRepository
import dev.soupy.eclipse.android.data.CatalogRepository
import dev.soupy.eclipse.android.data.LibraryRepository
import dev.soupy.eclipse.android.data.LoggerRepository
import dev.soupy.eclipse.android.data.MangaRepository
import dev.soupy.eclipse.android.data.ReleaseRepository
import dev.soupy.eclipse.android.data.ServicesRepository
import dev.soupy.eclipse.android.data.TrackerAccountDraft
import dev.soupy.eclipse.android.data.TrackerRemoteAnimeProgress
import dev.soupy.eclipse.android.data.TrackerRemoteMangaProgress
import dev.soupy.eclipse.android.data.TrackerRepository
import dev.soupy.eclipse.android.data.TrackerSyncSummary
import dev.soupy.eclipse.android.feature.settings.CatalogSettingsRow
import dev.soupy.eclipse.android.feature.settings.LogSettingsRow
import dev.soupy.eclipse.android.feature.settings.SettingsScreenState
import dev.soupy.eclipse.android.feature.settings.StorageMetricRow
import dev.soupy.eclipse.android.feature.settings.TrackerSyncToolPreviewRow
import dev.soupy.eclipse.android.feature.settings.TrackerToolFillAniList
import dev.soupy.eclipse.android.feature.settings.TrackerToolFillMAL
import dev.soupy.eclipse.android.feature.settings.TrackerToolPortAniListToMAL
import dev.soupy.eclipse.android.feature.settings.TrackerToolPortMALToAniList
import dev.soupy.eclipse.android.feature.settings.TrackerToolPushAniList
import dev.soupy.eclipse.android.feature.settings.TrackerToolPushMAL
import dev.soupy.eclipse.android.feature.settings.TrackerSettingsRow
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class AndroidSettingsViewModel(
    private val settingsStore: SettingsStore,
    private val backupRepository: BackupRepository,
    private val catalogRepository: CatalogRepository,
    private val cacheRepository: CacheRepository,
    private val loggerRepository: LoggerRepository,
    private val trackerRepository: TrackerRepository,
    private val libraryRepository: LibraryRepository,
    private val mangaRepository: MangaRepository,
    private val aniListService: AniListService,
    private val myAnimeListService: MyAnimeListService,
    private val releaseRepository: ReleaseRepository,
    private val servicesRepository: ServicesRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(
        SettingsScreenState(
            aniListOAuthUrl = trackerRepository.authorizationUrl("AniList").orEmpty(),
            myAnimeListOAuthUrl = trackerRepository.authorizationUrl("MyAnimeList").orEmpty(),
            traktOAuthUrl = trackerRepository.authorizationUrl("Trakt").orEmpty(),
        ),
    )
    val state: StateFlow<SettingsScreenState> = _state.asStateFlow()
    private var trackerSyncToolJob: Job? = null

    init {
        viewModelScope.launch {
            settingsStore.settings.collect { settings ->
                _state.value = _state.value.copy(
                    accentColor = settings.accentColor,
                    settingsGradientColor = settings.settingsGradientColor,
                    tmdbLanguage = settings.tmdbLanguage,
                    selectedAppearance = settings.selectedAppearance,
                    autoModeEnabled = settings.autoModeEnabled,
                    highQualityThreshold = settings.highQualityThreshold,
                    filterHorrorContent = settings.filterHorrorContent,
                    selectedSimilarityAlgorithm = settings.selectedSimilarityAlgorithm,
                    showNextEpisodeButton = settings.showNextEpisodeButton,
                    nextEpisodeThreshold = settings.nextEpisodeThreshold,
                    inAppPlayer = settings.inAppPlayer,
                    enableSubtitlesByDefault = settings.enableSubtitlesByDefault,
                    enableVLCSubtitleEditMenu = settings.enableVLCSubtitleEditMenu,
                    defaultSubtitleLanguage = settings.defaultSubtitleLanguage,
                    preferredAnimeAudioLanguage = settings.preferredAnimeAudioLanguage,
                    defaultPlaybackSpeed = settings.defaultPlaybackSpeed,
                    holdSpeedPlayer = settings.holdSpeedPlayer,
                    externalPlayer = settings.externalPlayer,
                    alwaysLandscape = settings.alwaysLandscape,
                    vlcHeaderProxyEnabled = settings.vlcHeaderProxyEnabled,
                    vlcBrightnessGestureEnabled = settings.vlcBrightnessGestureEnabled,
                    vlcVolumeGestureEnabled = settings.vlcVolumeGestureEnabled,
                    playerTwoFingerTapPlayPauseEnabled = settings.playerTwoFingerTapPlayPauseEnabled,
                    vlcDoubleTapSeekEnabled = settings.vlcDoubleTapSeekEnabled,
                    vlcDoubleTapSeekSeconds = settings.vlcDoubleTapSeekSeconds,
                    vlcPiPEnabled = settings.vlcPiPEnabled,
                    vlcOpenSubtitlesEnabled = settings.vlcOpenSubtitlesEnabled,
                    vlcOpenSubtitlesAutoFallbackEnabled = settings.vlcOpenSubtitlesAutoFallbackEnabled,
                    subtitleForegroundColor = settings.subtitleForegroundColor,
                    subtitleStrokeColor = settings.subtitleStrokeColor,
                    subtitleStrokeWidth = settings.subtitleStrokeWidth,
                    subtitleFontSize = settings.subtitleFontSize,
                    subtitleVerticalOffset = settings.subtitleVerticalOffset,
                    aniSkipEnabled = settings.aniSkipEnabled,
                    introDbEnabled = settings.introDbEnabled,
                    aniSkipAutoSkip = settings.aniSkipAutoSkip,
                    skip85sEnabled = settings.skip85sEnabled,
                    skip85sAlwaysVisible = settings.skip85sAlwaysVisible,
                    showScheduleTab = settings.showScheduleTab,
                    showLocalScheduleTime = settings.showLocalScheduleTime,
                    useClassicScheduleUI = settings.useClassicScheduleUI,
                    showKanzen = settings.showKanzen,
                    seasonMenu = settings.seasonMenu,
                    horizontalEpisodeList = settings.horizontalEpisodeList,
                    mediaColumnsPortrait = settings.mediaColumnsPortrait,
                    mediaColumnsLandscape = settings.mediaColumnsLandscape,
                    readingMode = settings.readingMode,
                    readerFontSize = settings.readerFontSize,
                    readerFontFamily = settings.readerFontFamily,
                    readerFontWeight = settings.readerFontWeight,
                    readerColorPreset = settings.readerColorPreset,
                    readerLineSpacing = settings.readerLineSpacing,
                    readerMargin = settings.readerMargin,
                    readerTextAlignment = settings.readerTextAlignment,
                    kanzenAutoMode = settings.kanzenAutoMode,
                    kanzenAutoUpdateModules = settings.kanzenAutoUpdateModules,
                    autoClearCacheEnabled = settings.autoClearCacheEnabled,
                    autoClearCacheThresholdMB = settings.autoClearCacheThresholdMB,
                    autoUpdateServicesEnabled = settings.autoUpdateServicesEnabled,
                    githubReleaseAutoCheckEnabled = settings.githubReleaseAutoCheckEnabled,
                    githubReleaseUpdateAvailable = settings.githubReleaseUpdateAvailable,
                    githubReleaseLatestVersion = settings.githubReleaseLatestVersion,
                    githubReleaseUrl = settings.githubReleaseUrl,
                    githubReleaseShowAlertPending = settings.githubReleaseShowAlertPending,
                    githubReleaseStatus = settings.toGitHubReleaseStatus(),
                )
            }
        }
        refreshBackupStatus()
        refreshCatalogs()
        refreshStorage()
        refreshLogs()
        refreshTrackers()
        runStartupCacheMaintenance()
        runBackgroundAutoChecks()
    }

    fun runBackgroundAutoChecks() {
        checkGitHubReleaseIfNeeded()
        autoUpdateServicesIfNeeded()
    }

    fun setAccentColor(value: String) {
        val current = _state.value
        updateAppearance(
            accentColor = value,
            settingsGradientColor = current.settingsGradientColor,
            tmdbLanguage = current.tmdbLanguage,
            selectedAppearance = current.selectedAppearance,
        )
    }

    fun setSettingsGradientColor(value: String) {
        val current = _state.value
        updateAppearance(
            accentColor = current.accentColor,
            settingsGradientColor = value,
            tmdbLanguage = current.tmdbLanguage,
            selectedAppearance = current.selectedAppearance,
        )
    }

    fun setTmdbLanguage(value: String) {
        val current = _state.value
        updateAppearance(
            accentColor = current.accentColor,
            settingsGradientColor = current.settingsGradientColor,
            tmdbLanguage = value,
            selectedAppearance = current.selectedAppearance,
        )
    }

    fun setAppearance(value: String) {
        val current = _state.value
        updateAppearance(
            accentColor = current.accentColor,
            settingsGradientColor = current.settingsGradientColor,
            tmdbLanguage = current.tmdbLanguage,
            selectedAppearance = value,
        )
    }

    fun setShowScheduleTab(enabled: Boolean) {
        val current = _state.value
        updateNavigation(
            showScheduleTab = enabled,
            showKanzen = current.showKanzen,
        )
    }

    fun setShowLocalScheduleTime(enabled: Boolean) {
        val current = _state.value
        updateScheduleOptions(
            showLocalScheduleTime = enabled,
            useClassicScheduleUI = current.useClassicScheduleUI,
        )
    }

    fun setUseClassicScheduleUi(enabled: Boolean) {
        val current = _state.value
        updateScheduleOptions(
            showLocalScheduleTime = current.showLocalScheduleTime,
            useClassicScheduleUI = enabled,
        )
    }

    fun setShowKanzen(enabled: Boolean) {
        val current = _state.value
        updateNavigation(
            showScheduleTab = current.showScheduleTab,
            showKanzen = enabled,
        )
    }

    fun setSeasonMenu(enabled: Boolean) {
        val current = _state.value
        updateDisplayOptions(
            seasonMenu = enabled,
            horizontalEpisodeList = current.horizontalEpisodeList,
        )
    }

    fun setHorizontalEpisodeList(enabled: Boolean) {
        val current = _state.value
        updateDisplayOptions(
            seasonMenu = current.seasonMenu,
            horizontalEpisodeList = enabled,
        )
    }

    fun setMediaColumnsPortrait(value: Int) {
        val current = _state.value
        viewModelScope.launch {
            settingsStore.updateMediaColumns(
                portrait = value,
                landscape = current.mediaColumnsLandscape,
            )
        }
    }

    fun setMediaColumnsLandscape(value: Int) {
        val current = _state.value
        viewModelScope.launch {
            settingsStore.updateMediaColumns(
                portrait = current.mediaColumnsPortrait,
                landscape = value,
            )
        }
    }

    fun setAutoUpdateServicesEnabled(enabled: Boolean) {
        viewModelScope.launch {
            settingsStore.setAutoUpdateServicesEnabled(enabled)
        }
    }

    fun setGitHubReleaseAutoCheckEnabled(enabled: Boolean) {
        viewModelScope.launch {
            settingsStore.setGitHubReleaseAutoCheckEnabled(enabled)
        }
    }

    fun checkGitHubReleaseNow() {
        viewModelScope.launch {
            _state.value = _state.value.copy(
                isCheckingGitHubRelease = true,
                githubReleaseStatus = "Checking GitHub releases...",
            )
            releaseRepository.checkForUpdates(forcePrompt = true)
                .onSuccess { summary ->
                    _state.value = _state.value.copy(
                        isCheckingGitHubRelease = false,
                        githubReleaseStatus = if (summary.updateAvailable) {
                            "Update available: ${summary.latestVersion}"
                        } else {
                            "App is up to date: ${summary.latestVersion}"
                        },
                    )
                    loggerRepository.log("Updates", _state.value.githubReleaseStatus)
                    refreshLogs()
                }
                .onFailure { error ->
                    val message = error.message ?: "GitHub release check failed."
                    _state.value = _state.value.copy(
                        isCheckingGitHubRelease = false,
                        githubReleaseStatus = message,
                    )
                    loggerRepository.log("Updates", message, level = "error")
                    refreshLogs()
                }
        }
    }

    fun consumeGitHubReleasePrompt() {
        viewModelScope.launch {
            releaseRepository.consumePendingPrompt()
        }
    }

    fun setAutoModeEnabled(enabled: Boolean) {
        viewModelScope.launch {
            settingsStore.setAutoModeEnabled(enabled)
        }
    }

    fun setHighQualityThreshold(threshold: Double) {
        viewModelScope.launch {
            settingsStore.setHighQualityThreshold(threshold)
        }
    }

    fun setFilterHorrorContent(enabled: Boolean) {
        viewModelScope.launch {
            settingsStore.setFilterHorrorContent(enabled)
        }
    }

    fun setSimilarityAlgorithm(algorithm: SimilarityAlgorithm) {
        viewModelScope.launch {
            settingsStore.setSimilarityAlgorithm(algorithm)
        }
    }

    fun setAutoClearCacheEnabled(enabled: Boolean) {
        val current = _state.value
        updateAutoClearCache(
            enabled = enabled,
            thresholdMB = current.autoClearCacheThresholdMB,
        )
    }

    fun setAutoClearCacheThreshold(value: Double) {
        val current = _state.value
        updateAutoClearCache(
            enabled = current.autoClearCacheEnabled,
            thresholdMB = value,
        )
    }

    fun setShowNextEpisodeButton(enabled: Boolean) {
        val current = _state.value
        viewModelScope.launch {
            settingsStore.updatePlayback(
                inAppPlayer = current.inAppPlayer,
                showNextEpisodeButton = enabled,
                nextEpisodeThreshold = current.nextEpisodeThreshold,
            )
        }
    }

    fun setNextEpisodeThreshold(threshold: Int) {
        val current = _state.value
        viewModelScope.launch {
            settingsStore.updatePlayback(
                inAppPlayer = current.inAppPlayer,
                showNextEpisodeButton = current.showNextEpisodeButton,
                nextEpisodeThreshold = threshold.coerceIn(50, 99),
            )
        }
    }

    fun setInAppPlayer(player: InAppPlayer) {
        val current = _state.value
        viewModelScope.launch {
            settingsStore.updatePlayback(
                inAppPlayer = player,
                showNextEpisodeButton = current.showNextEpisodeButton,
                nextEpisodeThreshold = current.nextEpisodeThreshold,
            )
        }
    }

    fun setAniSkipAutoSkip(enabled: Boolean) {
        val current = _state.value
        updateSkipBehavior(
            aniSkipEnabled = current.aniSkipEnabled,
            introDbEnabled = current.introDbEnabled,
            aniSkipAutoSkip = enabled,
            skip85sEnabled = current.skip85sEnabled,
            skip85sAlwaysVisible = current.skip85sAlwaysVisible,
        )
    }

    fun setSkip85sEnabled(enabled: Boolean) {
        val current = _state.value
        updateSkipBehavior(
            aniSkipEnabled = current.aniSkipEnabled,
            introDbEnabled = current.introDbEnabled,
            aniSkipAutoSkip = current.aniSkipAutoSkip,
            skip85sEnabled = enabled,
            skip85sAlwaysVisible = current.skip85sAlwaysVisible,
        )
    }

    fun setAniSkipEnabled(enabled: Boolean) {
        val current = _state.value
        updateSkipBehavior(
            aniSkipEnabled = enabled,
            introDbEnabled = current.introDbEnabled,
            aniSkipAutoSkip = current.aniSkipAutoSkip,
            skip85sEnabled = current.skip85sEnabled,
            skip85sAlwaysVisible = current.skip85sAlwaysVisible,
        )
    }

    fun setIntroDbEnabled(enabled: Boolean) {
        val current = _state.value
        updateSkipBehavior(
            aniSkipEnabled = current.aniSkipEnabled,
            introDbEnabled = enabled,
            aniSkipAutoSkip = current.aniSkipAutoSkip,
            skip85sEnabled = current.skip85sEnabled,
            skip85sAlwaysVisible = current.skip85sAlwaysVisible,
        )
    }

    fun setSkip85sAlwaysVisible(enabled: Boolean) {
        val current = _state.value
        updateSkipBehavior(
            aniSkipEnabled = current.aniSkipEnabled,
            introDbEnabled = current.introDbEnabled,
            aniSkipAutoSkip = current.aniSkipAutoSkip,
            skip85sEnabled = current.skip85sEnabled,
            skip85sAlwaysVisible = enabled,
        )
    }

    private fun updateSkipBehavior(
        aniSkipEnabled: Boolean,
        introDbEnabled: Boolean,
        aniSkipAutoSkip: Boolean,
        skip85sEnabled: Boolean,
        skip85sAlwaysVisible: Boolean,
    ) {
        viewModelScope.launch {
            settingsStore.updateSkipBehavior(
                aniSkipEnabled = aniSkipEnabled,
                introDbEnabled = introDbEnabled,
                aniSkipAutoSkip = aniSkipAutoSkip,
                skip85sEnabled = skip85sEnabled,
                skip85sAlwaysVisible = skip85sAlwaysVisible,
            )
        }
    }

    fun setEnableSubtitlesByDefault(enabled: Boolean) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = enabled,
            enableVLCSubtitleEditMenu = current.enableVLCSubtitleEditMenu,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            defaultPlaybackSpeed = current.defaultPlaybackSpeed,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setEnableVLCSubtitleEditMenu(enabled: Boolean) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            enableVLCSubtitleEditMenu = enabled,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            defaultPlaybackSpeed = current.defaultPlaybackSpeed,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setDefaultSubtitleLanguage(language: String) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            enableVLCSubtitleEditMenu = current.enableVLCSubtitleEditMenu,
            defaultSubtitleLanguage = language,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            defaultPlaybackSpeed = current.defaultPlaybackSpeed,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setPreferredAnimeAudioLanguage(language: String) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            enableVLCSubtitleEditMenu = current.enableVLCSubtitleEditMenu,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = language,
            defaultPlaybackSpeed = current.defaultPlaybackSpeed,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setDefaultPlaybackSpeed(value: Double) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            enableVLCSubtitleEditMenu = current.enableVLCSubtitleEditMenu,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            defaultPlaybackSpeed = value,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setHoldSpeed(value: Double) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            enableVLCSubtitleEditMenu = current.enableVLCSubtitleEditMenu,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            defaultPlaybackSpeed = current.defaultPlaybackSpeed,
            holdSpeedPlayer = value,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setExternalPlayer(value: String) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            enableVLCSubtitleEditMenu = current.enableVLCSubtitleEditMenu,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            defaultPlaybackSpeed = current.defaultPlaybackSpeed,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = value,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setAlwaysLandscape(enabled: Boolean) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            enableVLCSubtitleEditMenu = current.enableVLCSubtitleEditMenu,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            defaultPlaybackSpeed = current.defaultPlaybackSpeed,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = enabled,
            vlcHeaderProxyEnabled = current.vlcHeaderProxyEnabled,
        )
    }

    fun setVlcHeaderProxyEnabled(enabled: Boolean) {
        val current = _state.value
        updatePlayerPreferences(
            enableSubtitlesByDefault = current.enableSubtitlesByDefault,
            enableVLCSubtitleEditMenu = current.enableVLCSubtitleEditMenu,
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            defaultPlaybackSpeed = current.defaultPlaybackSpeed,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = enabled,
        )
    }

    fun setVlcBrightnessGestureEnabled(enabled: Boolean) {
        val current = _state.value
        updatePlayerGestures(current.copy(vlcBrightnessGestureEnabled = enabled))
    }

    fun setVlcVolumeGestureEnabled(enabled: Boolean) {
        val current = _state.value
        updatePlayerGestures(current.copy(vlcVolumeGestureEnabled = enabled))
    }

    fun setPlayerTwoFingerTapPlayPauseEnabled(enabled: Boolean) {
        val current = _state.value
        updatePlayerGestures(current.copy(playerTwoFingerTapPlayPauseEnabled = enabled))
    }

    fun setVlcDoubleTapSeekEnabled(enabled: Boolean) {
        val current = _state.value
        updatePlayerGestures(current.copy(vlcDoubleTapSeekEnabled = enabled))
    }

    fun setVlcDoubleTapSeekSeconds(value: Double) {
        val current = _state.value
        updatePlayerGestures(current.copy(vlcDoubleTapSeekSeconds = value))
    }

    fun setVlcPiPEnabled(enabled: Boolean) {
        val current = _state.value
        updatePlayerGestures(current.copy(vlcPiPEnabled = enabled))
    }

    fun setVlcOpenSubtitlesEnabled(enabled: Boolean) {
        val current = _state.value
        updatePlayerGestures(current.copy(vlcOpenSubtitlesEnabled = enabled))
    }

    fun setVlcOpenSubtitlesAutoFallbackEnabled(enabled: Boolean) {
        val current = _state.value
        updatePlayerGestures(current.copy(vlcOpenSubtitlesAutoFallbackEnabled = enabled))
    }

    fun setSubtitleForegroundColor(value: String?) {
        val current = _state.value
        updateSubtitleStyle(
            foregroundColor = value,
            strokeColor = current.subtitleStrokeColor,
            strokeWidth = current.subtitleStrokeWidth,
            fontSize = current.subtitleFontSize,
            verticalOffset = current.subtitleVerticalOffset,
        )
    }

    fun setSubtitleStrokeColor(value: String?) {
        val current = _state.value
        updateSubtitleStyle(
            foregroundColor = current.subtitleForegroundColor,
            strokeColor = value,
            strokeWidth = current.subtitleStrokeWidth,
            fontSize = current.subtitleFontSize,
            verticalOffset = current.subtitleVerticalOffset,
        )
    }

    fun setSubtitleStrokeWidth(value: Double) {
        val current = _state.value
        updateSubtitleStyle(
            foregroundColor = current.subtitleForegroundColor,
            strokeColor = current.subtitleStrokeColor,
            strokeWidth = value,
            fontSize = current.subtitleFontSize,
            verticalOffset = current.subtitleVerticalOffset,
        )
    }

    fun setSubtitleFontSize(value: Double) {
        val current = _state.value
        updateSubtitleStyle(
            foregroundColor = current.subtitleForegroundColor,
            strokeColor = current.subtitleStrokeColor,
            strokeWidth = current.subtitleStrokeWidth,
            fontSize = value,
            verticalOffset = current.subtitleVerticalOffset,
        )
    }

    fun setSubtitleVerticalOffset(value: Double) {
        val current = _state.value
        updateSubtitleStyle(
            foregroundColor = current.subtitleForegroundColor,
            strokeColor = current.subtitleStrokeColor,
            strokeWidth = current.subtitleStrokeWidth,
            fontSize = current.subtitleFontSize,
            verticalOffset = value,
        )
    }

    private fun updatePlayerPreferences(
        enableSubtitlesByDefault: Boolean,
        enableVLCSubtitleEditMenu: Boolean,
        defaultSubtitleLanguage: String,
        preferredAnimeAudioLanguage: String,
        defaultPlaybackSpeed: Double,
        holdSpeedPlayer: Double,
        externalPlayer: String,
        alwaysLandscape: Boolean,
        vlcHeaderProxyEnabled: Boolean,
    ) {
        viewModelScope.launch {
            settingsStore.updatePlayerPreferences(
                enableSubtitlesByDefault = enableSubtitlesByDefault,
                enableVLCSubtitleEditMenu = enableVLCSubtitleEditMenu,
                defaultSubtitleLanguage = defaultSubtitleLanguage,
                preferredAnimeAudioLanguage = preferredAnimeAudioLanguage,
                defaultPlaybackSpeed = defaultPlaybackSpeed,
                holdSpeedPlayer = holdSpeedPlayer,
                externalPlayer = externalPlayer,
                alwaysLandscape = alwaysLandscape,
                vlcHeaderProxyEnabled = vlcHeaderProxyEnabled,
            )
        }
    }

    private fun updatePlayerGestures(state: SettingsScreenState) {
        viewModelScope.launch {
            settingsStore.updatePlayerGestures(
                vlcBrightnessGestureEnabled = state.vlcBrightnessGestureEnabled,
                vlcVolumeGestureEnabled = state.vlcVolumeGestureEnabled,
                playerTwoFingerTapPlayPauseEnabled = state.playerTwoFingerTapPlayPauseEnabled,
                vlcDoubleTapSeekEnabled = state.vlcDoubleTapSeekEnabled,
                vlcDoubleTapSeekSeconds = state.vlcDoubleTapSeekSeconds,
                vlcPiPEnabled = state.vlcPiPEnabled,
                vlcOpenSubtitlesEnabled = state.vlcOpenSubtitlesEnabled,
                vlcOpenSubtitlesAutoFallbackEnabled = state.vlcOpenSubtitlesAutoFallbackEnabled,
            )
        }
    }

    private fun updateSubtitleStyle(
        foregroundColor: String?,
        strokeColor: String?,
        strokeWidth: Double,
        fontSize: Double,
        verticalOffset: Double,
    ) {
        viewModelScope.launch {
            settingsStore.updateSubtitleStyle(
                foregroundColor = foregroundColor,
                strokeColor = strokeColor,
                strokeWidth = strokeWidth,
                fontSize = fontSize,
                verticalOffset = verticalOffset,
            )
        }
    }

    fun setReadingMode(mode: Int) {
        val current = _state.value
        updateReader(
            readingMode = mode,
            readerFontSize = current.readerFontSize,
            readerFontFamily = current.readerFontFamily,
            readerFontWeight = current.readerFontWeight,
            readerColorPreset = current.readerColorPreset,
            readerLineSpacing = current.readerLineSpacing,
            readerMargin = current.readerMargin,
            readerTextAlignment = current.readerTextAlignment,
        )
    }

    fun setReaderFontSize(value: Double) {
        val current = _state.value
        updateReader(
            readingMode = current.readingMode,
            readerFontSize = value,
            readerFontFamily = current.readerFontFamily,
            readerFontWeight = current.readerFontWeight,
            readerColorPreset = current.readerColorPreset,
            readerLineSpacing = current.readerLineSpacing,
            readerMargin = current.readerMargin,
            readerTextAlignment = current.readerTextAlignment,
        )
    }

    fun setReaderFontFamily(value: String) {
        val current = _state.value
        updateReader(
            readingMode = current.readingMode,
            readerFontSize = current.readerFontSize,
            readerFontFamily = value,
            readerFontWeight = current.readerFontWeight,
            readerColorPreset = current.readerColorPreset,
            readerLineSpacing = current.readerLineSpacing,
            readerMargin = current.readerMargin,
            readerTextAlignment = current.readerTextAlignment,
        )
    }

    fun setReaderFontWeight(value: String) {
        val current = _state.value
        updateReader(
            readingMode = current.readingMode,
            readerFontSize = current.readerFontSize,
            readerFontFamily = current.readerFontFamily,
            readerFontWeight = value,
            readerColorPreset = current.readerColorPreset,
            readerLineSpacing = current.readerLineSpacing,
            readerMargin = current.readerMargin,
            readerTextAlignment = current.readerTextAlignment,
        )
    }

    fun setReaderColorPreset(value: Int) {
        val current = _state.value
        updateReader(
            readingMode = current.readingMode,
            readerFontSize = current.readerFontSize,
            readerFontFamily = current.readerFontFamily,
            readerFontWeight = current.readerFontWeight,
            readerColorPreset = value,
            readerLineSpacing = current.readerLineSpacing,
            readerMargin = current.readerMargin,
            readerTextAlignment = current.readerTextAlignment,
        )
    }

    fun setReaderLineSpacing(value: Double) {
        val current = _state.value
        updateReader(
            readingMode = current.readingMode,
            readerFontSize = current.readerFontSize,
            readerFontFamily = current.readerFontFamily,
            readerFontWeight = current.readerFontWeight,
            readerColorPreset = current.readerColorPreset,
            readerLineSpacing = value,
            readerMargin = current.readerMargin,
            readerTextAlignment = current.readerTextAlignment,
        )
    }

    fun setReaderMargin(value: Double) {
        val current = _state.value
        updateReader(
            readingMode = current.readingMode,
            readerFontSize = current.readerFontSize,
            readerFontFamily = current.readerFontFamily,
            readerFontWeight = current.readerFontWeight,
            readerColorPreset = current.readerColorPreset,
            readerLineSpacing = current.readerLineSpacing,
            readerMargin = value,
            readerTextAlignment = current.readerTextAlignment,
        )
    }

    fun setReaderTextAlignment(alignment: String) {
        val current = _state.value
        updateReader(
            readingMode = current.readingMode,
            readerFontSize = current.readerFontSize,
            readerFontFamily = current.readerFontFamily,
            readerFontWeight = current.readerFontWeight,
            readerColorPreset = current.readerColorPreset,
            readerLineSpacing = current.readerLineSpacing,
            readerMargin = current.readerMargin,
            readerTextAlignment = alignment,
        )
    }

    fun setKanzenAutoUpdateModules(enabled: Boolean) {
        viewModelScope.launch {
            settingsStore.setKanzenAutoUpdateModules(enabled)
        }
    }

    fun setKanzenAutoMode(enabled: Boolean) {
        viewModelScope.launch {
            settingsStore.setKanzenAutoMode(enabled)
        }
    }

    private fun updateReader(
        readingMode: Int,
        readerFontSize: Double,
        readerFontFamily: String,
        readerFontWeight: String,
        readerColorPreset: Int,
        readerLineSpacing: Double,
        readerMargin: Double,
        readerTextAlignment: String,
    ) {
        viewModelScope.launch {
            settingsStore.updateReader(
                readingMode = readingMode,
                readerFontSize = readerFontSize,
                readerFontFamily = readerFontFamily,
                readerFontWeight = readerFontWeight,
                readerColorPreset = readerColorPreset,
                readerLineSpacing = readerLineSpacing,
                readerMargin = readerMargin,
                readerTextAlignment = readerTextAlignment,
            )
        }
    }

    private fun updateAutoClearCache(
        enabled: Boolean,
        thresholdMB: Double,
    ) {
        viewModelScope.launch {
            settingsStore.updateAutoClearCache(
                enabled = enabled,
                thresholdMB = thresholdMB,
            )
        }
    }

    private fun updateAppearance(
        accentColor: String,
        settingsGradientColor: String,
        tmdbLanguage: String,
        selectedAppearance: String,
    ) {
        viewModelScope.launch {
            settingsStore.updateAppearance(
                accentColor = accentColor,
                settingsGradientColor = settingsGradientColor,
                tmdbLanguage = tmdbLanguage,
                selectedAppearance = selectedAppearance,
            )
        }
    }

    private fun updateNavigation(
        showScheduleTab: Boolean,
        showKanzen: Boolean,
    ) {
        viewModelScope.launch {
            settingsStore.updateNavigation(
                showScheduleTab = showScheduleTab,
                showKanzen = showKanzen,
            )
        }
    }

    private fun updateScheduleOptions(
        showLocalScheduleTime: Boolean,
        useClassicScheduleUI: Boolean,
    ) {
        viewModelScope.launch {
            settingsStore.updateScheduleOptions(
                showLocalScheduleTime = showLocalScheduleTime,
                useClassicScheduleUI = useClassicScheduleUI,
            )
        }
    }

    private fun updateDisplayOptions(
        seasonMenu: Boolean,
        horizontalEpisodeList: Boolean,
    ) {
        viewModelScope.launch {
            settingsStore.updateDisplayOptions(
                seasonMenu = seasonMenu,
                horizontalEpisodeList = horizontalEpisodeList,
            )
        }
    }

    fun exportBackup(uri: Uri) = runBackupMutation {
        backupRepository.exportToUri(uri)
    }

    fun importBackup(uri: Uri) = runBackupMutation {
        backupRepository.importFromUri(uri)
    }

    fun setCatalogEnabled(id: String, enabled: Boolean) {
        viewModelScope.launch {
            catalogRepository.setCatalogEnabled(id, enabled)
                .onSuccess { snapshot ->
                    _state.value = _state.value.copy(catalogs = snapshot.catalogs.toUiRows())
                }
        }
    }

    fun moveCatalogUp(id: String) {
        moveCatalog(id, direction = -1)
    }

    fun moveCatalogDown(id: String) {
        moveCatalog(id, direction = 1)
    }

    fun refreshStorage() {
        viewModelScope.launch {
            cacheRepository.loadMetrics()
                .onSuccess { metrics ->
                    _state.value = _state.value.copy(
                        storageMetrics = listOf(
                            StorageMetricRow("Cache", metrics.cacheBytes.toByteCountLabel()),
                            StorageMetricRow("Files", metrics.filesBytes.toByteCountLabel()),
                            StorageMetricRow("Downloads", metrics.downloadBytes.toByteCountLabel()),
                        ),
                        storageStatus = "Measured ${metrics.generatedAt.toReadableClock()}",
                    )
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        storageStatus = error.message ?: "Could not inspect storage yet.",
                    )
                }
        }
    }

    fun clearCache() {
        viewModelScope.launch {
            loggerRepository.log("Storage", "User cleared app cache from settings.")
            cacheRepository.clearCache()
                .onSuccess { metrics ->
                    _state.value = _state.value.copy(
                        storageMetrics = listOf(
                            StorageMetricRow("Cache", metrics.cacheBytes.toByteCountLabel()),
                            StorageMetricRow("Files", metrics.filesBytes.toByteCountLabel()),
                            StorageMetricRow("Downloads", metrics.downloadBytes.toByteCountLabel()),
                        ),
                        storageStatus = "Cache cleared ${metrics.generatedAt.toReadableClock()}",
                    )
                    refreshLogs()
                }
                .onFailure { error ->
                    loggerRepository.log("Storage", error.message ?: "Cache clear failed.", level = "error")
                    _state.value = _state.value.copy(
                        storageStatus = error.message ?: "Could not clear cache.",
                    )
                    refreshLogs()
                }
        }
    }

    private fun runStartupCacheMaintenance() {
        viewModelScope.launch {
            val settings = settingsStore.settings.first()
            if (!settings.autoClearCacheEnabled) return@launch

            val thresholdBytes = (settings.autoClearCacheThresholdMB * 1_000_000).toLong()
            val metrics = cacheRepository.loadMetrics().getOrNull() ?: return@launch
            if (metrics.cacheBytes <= thresholdBytes) return@launch

            loggerRepository.log(
                tag = "Storage",
                message = "Auto-clearing cache because ${metrics.cacheBytes.toByteCountLabel()} exceeds ${settings.autoClearCacheThresholdMB.toInt()} MB.",
            )
            cacheRepository.clearCache()
                .onSuccess { updated ->
                    _state.value = _state.value.copy(
                        storageMetrics = listOf(
                            StorageMetricRow("Cache", updated.cacheBytes.toByteCountLabel()),
                            StorageMetricRow("Files", updated.filesBytes.toByteCountLabel()),
                            StorageMetricRow("Downloads", updated.downloadBytes.toByteCountLabel()),
                        ),
                        storageStatus = "Auto-cleared cache ${updated.generatedAt.toReadableClock()}",
                    )
                    refreshLogs()
                }
                .onFailure { error ->
                    loggerRepository.log(
                        tag = "Storage",
                        message = error.message ?: "Auto-clear cache failed.",
                        level = "error",
                    )
                    refreshLogs()
                }
        }
    }

    fun refreshLogs() {
        viewModelScope.launch {
            loggerRepository.loadSnapshot()
                .onSuccess { snapshot ->
                    _state.value = _state.value.copy(
                        logRows = snapshot.entries.take(8).map { entry ->
                            LogSettingsRow(
                                id = entry.id,
                                timestamp = entry.timestamp.toReadableClock(),
                                tag = entry.tag,
                                message = entry.message,
                                level = entry.level,
                            )
                        },
                        loggerStatus = if (snapshot.entries.isEmpty()) {
                            "No logs captured yet."
                        } else {
                            "${snapshot.entries.size} persistent log entries"
                        },
                    )
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        loggerStatus = error.message ?: "Could not read persistent logs.",
                    )
                }
        }
    }

    fun clearLogs() {
        viewModelScope.launch {
            loggerRepository.clear()
                .onSuccess {
                    _state.value = _state.value.copy(
                        logRows = emptyList(),
                        loggerStatus = "Logs cleared.",
                    )
                }
        }
    }

    fun saveTrackerAccount(
        service: String,
        username: String,
        token: String,
    ) {
        viewModelScope.launch {
            trackerRepository.saveManualAccount(
                TrackerAccountDraft(
                    service = service,
                    username = username,
                    accessToken = token,
                ),
            ).onSuccess { snapshot ->
                _state.value = _state.value.withTrackerState(
                    snapshot = snapshot,
                    status = "Saved ${service.trim().ifBlank { "tracker" }} account.",
                )
                loggerRepository.log("Trackers", "Saved manual tracker account for ${service.trim().ifBlank { "unknown provider" }}.")
                refreshLogs()
            }.onFailure { error ->
                _state.value = _state.value.copy(
                    trackerStatus = error.message ?: "Could not save tracker account.",
                )
            }
        }
    }

    fun handleTrackerOAuthCallback(callbackUri: String) {
        viewModelScope.launch {
            _state.value = _state.value.copy(trackerStatus = "Finishing tracker authorization...")
            trackerRepository.exchangeOAuthCallback(callbackUri)
                .onSuccess { snapshot ->
                    _state.value = _state.value.withTrackerState(
                        snapshot = snapshot,
                        status = "Tracker authorization complete.",
                    )
                    loggerRepository.log("Trackers", "Completed tracker OAuth authorization.")
                    refreshLogs()
                }
                .onFailure { error ->
                    loggerRepository.log(
                        tag = "Trackers",
                        message = error.message ?: "Tracker authorization failed.",
                        level = "error",
                    )
                    _state.value = _state.value.copy(
                        trackerStatus = error.message ?: "Could not finish tracker authorization.",
                    )
                    refreshLogs()
                }
        }
    }

    fun setTrackerSyncEnabled(enabled: Boolean) {
        viewModelScope.launch {
            trackerRepository.setSyncEnabled(enabled)
                .onSuccess { snapshot ->
                    _state.value = _state.value.withTrackerState(
                        snapshot = snapshot,
                        status = if (enabled) "Tracker sync enabled." else "Tracker sync disabled.",
                    )
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        trackerStatus = error.message ?: "Could not update tracker sync.",
                    )
                }
        }
    }

    fun setAutoSyncRatings(enabled: Boolean) {
        viewModelScope.launch {
            trackerRepository.setAutoSyncRatings(enabled)
                .onSuccess { snapshot ->
                    _state.value = _state.value.withTrackerState(
                        snapshot = snapshot,
                        status = if (enabled) "Auto rating sync enabled." else "Auto rating sync disabled.",
                    )
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        trackerStatus = error.message ?: "Could not update rating sync.",
                    )
                }
        }
    }

    fun disconnectTracker(service: String) {
        viewModelScope.launch {
            trackerRepository.disconnect(service)
                .onSuccess { snapshot ->
                    _state.value = _state.value.withTrackerState(
                        snapshot = snapshot,
                        status = "Disconnected $service.",
                    )
                    loggerRepository.log("Trackers", "Disconnected tracker account for $service.")
                    refreshLogs()
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        trackerStatus = error.message ?: "Could not disconnect tracker.",
                    )
                }
        }
    }

    fun syncTrackersNow() {
        viewModelScope.launch {
            _state.value = _state.value.copy(trackerStatus = "Syncing watched progress to trackers...")
            trackerRepository.syncStoredProgress()
                .onSuccess { summary ->
                    _state.value = _state.value.withTrackerState(
                        snapshot = summary.state,
                        status = summary.statusMessage,
                    )
                    loggerRepository.log("Trackers", summary.statusMessage)
                    refreshLogs()
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        trackerStatus = error.message ?: "Tracker sync failed.",
                    )
                }
        }
    }

    fun syncMangaProgressNow() {
        viewModelScope.launch {
            _state.value = _state.value.copy(trackerStatus = "Syncing manga progress to AniList...")
            val mangaSnapshot = mangaRepository.loadSnapshot()
                .getOrElse { error ->
                    val message = error.message ?: "Could not load local manga progress."
                    _state.value = _state.value.copy(trackerStatus = message)
                    loggerRepository.log("Trackers", message, level = "error")
                    refreshLogs()
                    return@launch
                }
            trackerRepository.syncStoredMangaProgress(mangaSnapshot)
                .onSuccess { summary ->
                    val status = summary.toMangaSyncStatusMessage()
                    _state.value = _state.value.withTrackerState(
                        snapshot = summary.state,
                        status = status,
                    )
                    loggerRepository.log("Trackers", status)
                    refreshLogs()
                }
                .onFailure { error ->
                    val message = error.message ?: "Manga tracker sync failed."
                    _state.value = _state.value.copy(trackerStatus = message)
                    loggerRepository.log("Trackers", message, level = "error")
                    refreshLogs()
                }
        }
    }

    fun importAniListLibrary(onImported: () -> Unit = {}) {
        viewModelScope.launch {
            val account = trackerRepository.loadSnapshot()
                .getOrNull()
                ?.aniListAccount()
            if (account == null) {
                _state.value = _state.value.copy(
                    trackerStatus = "Connect an AniList tracker account before importing your AniList library.",
                )
                return@launch
            }

            _state.value = _state.value.copy(trackerStatus = "Importing AniList anime library...")
            when (
                val result = aniListService.fetchAnimeLibrary(
                    accessToken = account.accessToken,
                    username = account.username.takeIf(String::isNotBlank),
                )
            ) {
                is NetworkResult.Success -> {
                    libraryRepository.importAniListAnime(
                        result.value.map { entry ->
                            AniListLibraryImportDraft(
                                media = entry.media,
                                status = entry.status,
                                progress = entry.progress,
                                score = entry.score,
                                updatedAtEpochSeconds = entry.updatedAtEpochSeconds,
                            )
                        },
                    ).onSuccess { summary ->
                        _state.value = _state.value.copy(
                            trackerStatus = "Imported ${summary.importedItems} AniList anime item${if (summary.importedItems == 1) "" else "s"} into Library, including ${summary.importedContinueWatching} resume entr${if (summary.importedContinueWatching == 1) "y" else "ies"}.",
                        )
                        loggerRepository.log("Trackers", "Imported AniList anime library into Library.")
                        refreshLogs()
                        onImported()
                    }.onFailure { error ->
                        _state.value = _state.value.copy(
                            trackerStatus = error.message ?: "Could not import AniList library.",
                        )
                    }
                }
                is NetworkResult.Failure -> {
                    _state.value = _state.value.copy(
                        trackerStatus = result.toStatusMessage("AniList library import failed."),
                    )
                }
            }
        }
    }

    fun importAniListMangaLibrary(onImported: () -> Unit = {}) {
        viewModelScope.launch {
            val account = trackerRepository.loadSnapshot()
                .getOrNull()
                ?.aniListAccount()
            if (account == null) {
                _state.value = _state.value.copy(
                    trackerStatus = "Connect an AniList tracker account before importing your manga library.",
                )
                return@launch
            }

            _state.value = _state.value.copy(trackerStatus = "Importing AniList manga library...")
            when (
                val result = aniListService.fetchMangaLibrary(
                    accessToken = account.accessToken,
                    username = account.username.takeIf(String::isNotBlank),
                )
            ) {
                is NetworkResult.Success -> {
                    mangaRepository.importAniListManga(
                        result.value.map { entry ->
                            AniListMangaLibraryImportDraft(
                                media = entry.media,
                                status = entry.status,
                                progress = entry.progress,
                                progressVolumes = entry.progressVolumes,
                                score = entry.score,
                                updatedAtEpochSeconds = entry.updatedAtEpochSeconds,
                            )
                        },
                    ).onSuccess { summary ->
                        val progressLabel = if (summary.importedProgress == 1) {
                            "progress entry"
                        } else {
                            "progress entries"
                        }
                        _state.value = _state.value.copy(
                            trackerStatus = "Imported ${summary.importedItems} AniList manga item${if (summary.importedItems == 1) "" else "s"} into Manga/Novel, including ${summary.importedProgress} $progressLabel and ${summary.importedNovels} novel item${if (summary.importedNovels == 1) "" else "s"}.",
                        )
                        loggerRepository.log("Trackers", "Imported AniList manga library into Manga/Novel.")
                        refreshLogs()
                        onImported()
                    }.onFailure { error ->
                        _state.value = _state.value.copy(
                            trackerStatus = error.message ?: "Could not import AniList manga library.",
                        )
                    }
                }
                is NetworkResult.Failure -> {
                    _state.value = _state.value.copy(
                        trackerStatus = result.toStatusMessage("AniList manga import failed."),
                    )
                }
            }
        }
    }

    fun importMyAnimeListLibrary(onImported: () -> Unit = {}) {
        viewModelScope.launch {
            val account = trackerRepository.loadSnapshot()
                .getOrNull()
                ?.myAnimeListAccount()
            if (account == null) {
                _state.value = _state.value.copy(
                    trackerStatus = "Connect a MyAnimeList tracker account before importing your MAL library.",
                )
                return@launch
            }

            _state.value = _state.value.copy(trackerStatus = "Fetching your MyAnimeList library...")
            val animeEntries = when (val result = myAnimeListService.fetchAnimeLibrary(account.accessToken)) {
                is NetworkResult.Success -> result.value
                is NetworkResult.Failure -> {
                    _state.value = _state.value.copy(
                        trackerStatus = result.toStatusMessage("MAL anime import failed."),
                    )
                    return@launch
                }
            }
            val mangaEntries = when (val result = myAnimeListService.fetchMangaLibrary(account.accessToken)) {
                is NetworkResult.Success -> result.value
                is NetworkResult.Failure -> {
                    _state.value = _state.value.copy(
                        trackerStatus = result.toStatusMessage("MAL manga import failed."),
                    )
                    return@launch
                }
            }

            _state.value = _state.value.copy(trackerStatus = "Matching MAL entries to AniList...")
            val animeByMalId = when (val result = aniListService.mediaByMalIds(animeEntries.map { it.malId }, mediaType = "ANIME")) {
                is NetworkResult.Success -> result.value
                is NetworkResult.Failure -> {
                    _state.value = _state.value.copy(
                        trackerStatus = result.toStatusMessage("MAL anime matching failed."),
                    )
                    return@launch
                }
            }
            val mangaByMalId = when (val result = aniListService.mediaByMalIds(mangaEntries.map { it.malId }, mediaType = "MANGA")) {
                is NetworkResult.Success -> result.value
                is NetworkResult.Failure -> {
                    _state.value = _state.value.copy(
                        trackerStatus = result.toStatusMessage("MAL manga matching failed."),
                    )
                    return@launch
                }
            }

            val animeDrafts = animeEntries.mapNotNull { entry ->
                val media = animeByMalId[entry.malId] ?: return@mapNotNull null
                AniListLibraryImportDraft(
                    media = media,
                    status = entry.status,
                    progress = entry.watchedForImport(),
                    sourceName = "MAL",
                )
            }
            val mangaDrafts = mangaEntries.mapNotNull { entry ->
                val media = mangaByMalId[entry.malId] ?: return@mapNotNull null
                AniListMangaLibraryImportDraft(
                    media = media,
                    status = entry.status,
                    progress = entry.readForImport(),
                    sourceName = "MAL",
                )
            }
            val skippedAnime = animeEntries.size - animeDrafts.size
            val skippedManga = mangaEntries.size - mangaDrafts.size

            _state.value = _state.value.copy(
                trackerStatus = "Importing ${animeDrafts.size} MAL anime and ${mangaDrafts.size} MAL manga matches...",
            )
            libraryRepository.importAniListAnime(animeDrafts)
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        trackerStatus = error.message ?: "Could not import MAL anime library.",
                    )
                    return@launch
                }
            mangaRepository.importAniListManga(mangaDrafts)
                .onSuccess { summary ->
                    val importedAnime = animeDrafts.size
                    val skipped = skippedAnime + skippedManga
                    _state.value = _state.value.copy(
                        trackerStatus = "Imported $importedAnime MAL anime item${importedAnime.pluralSuffix()} and ${summary.importedItems} MAL manga item${summary.importedItems.pluralSuffix()} with ${summary.importedProgress} reader progress entr${if (summary.importedProgress == 1) "y" else "ies"}${if (skipped > 0) "; skipped $skipped unmapped item${skipped.pluralSuffix()}." else "."}",
                    )
                    loggerRepository.log("Trackers", "Imported MyAnimeList library into Android Library and Manga/Novel.")
                    refreshLogs()
                    onImported()
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        trackerStatus = error.message ?: "Could not import MAL manga library.",
                    )
                }
        }
    }

    fun previewTrackerSyncTool(actionId: String) {
        if (_state.value.isTrackerSyncToolRunning) return
        trackerSyncToolJob?.cancel()
        trackerSyncToolJob = viewModelScope.launch {
            beginTrackerSyncTool(actionId, "Building preview...")
            runCatching { buildTrackerSyncToolPreview(actionId) }
                .onSuccess { preview ->
                    _state.value = _state.value
                        .withTrackerSyncToolPreview(actionId, preview)
                        .copy(
                            isTrackerSyncToolRunning = false,
                            trackerStatus = "Preview ready",
                            trackerSyncToolProgressCompleted = 0,
                            trackerSyncToolProgressTotal = 0,
                            trackerSyncToolProgressDetail = "Preview ready",
                        )
                }
                .onFailure { error ->
                    if (error is CancellationException) {
                        finishCanceledSyncTool(actionId)
                    } else {
                        finishFailedSyncTool("Preview failed: ${error.message ?: "Could not build preview."}")
                    }
                }
            trackerSyncToolJob = null
        }
    }

    fun runTrackerSyncTool(
        actionId: String,
        onImported: () -> Unit = {},
    ) {
        if (_state.value.isTrackerSyncToolRunning) return
        trackerSyncToolJob?.cancel()
        trackerSyncToolJob = viewModelScope.launch {
            beginTrackerSyncTool(actionId, "Running ${actionId.syncToolTitle()}...")
            runCatching { performTrackerSyncTool(actionId, onImported) }
                .onSuccess { preview ->
                    _state.value = _state.value
                        .withTrackerSyncToolPreview(actionId, preview)
                        .copy(
                            isTrackerSyncToolRunning = false,
                            trackerStatus = "Finished ${actionId.syncToolTitle()}",
                            trackerSyncToolProgressCompleted = _state.value.trackerSyncToolProgressTotal,
                            trackerSyncToolProgressDetail = "Finished",
                        )
                    refreshLogs()
                }
                .onFailure { error ->
                    if (error is CancellationException) {
                        finishCanceledSyncTool(actionId)
                    } else {
                        finishFailedSyncTool("Sync failed: ${error.message ?: "Could not finish sync tool."}")
                    }
                }
            trackerSyncToolJob = null
        }
    }

    fun cancelTrackerSyncTool() {
        trackerSyncToolJob?.cancel()
        _state.value = _state.value.copy(
            trackerStatus = "Canceling sync...",
            trackerSyncToolProgressDetail = "Stopping after the current request...",
        )
    }

    private suspend fun buildTrackerSyncToolPreview(actionId: String): TrackerSyncToolPreviewRow =
        when (actionId) {
            TrackerToolFillAniList -> previewFillAniList()
            TrackerToolFillMAL -> previewFillMAL()
            TrackerToolPushAniList -> previewPushTo("AniList")
            TrackerToolPushMAL -> previewPushTo("MyAnimeList")
            TrackerToolPortAniListToMAL -> buildAniListToMALPortPlan().preview
            TrackerToolPortMALToAniList -> buildMALToAniListPortPlan().preview
            else -> error("Unsupported sync tool.")
        }

    private suspend fun performTrackerSyncTool(
        actionId: String,
        onImported: () -> Unit,
    ): TrackerSyncToolPreviewRow {
        val preview = buildTrackerSyncToolPreview(actionId)
        _state.value = _state.value
            .withTrackerSyncToolPreview(actionId, preview)
            .copy(
                trackerSyncToolProgressTotal = preview.syncOperationCount(),
                trackerSyncToolProgressCompleted = 0,
                trackerSyncToolProgressDetail = if (preview.syncOperationCount() > 0) {
                    "0 of ${preview.syncOperationCount()} operations complete"
                } else {
                    "No write operations needed"
                },
            )
        return when (actionId) {
            TrackerToolFillAniList -> fillEclipseFromAniListForTool(onImported)
            TrackerToolFillMAL -> fillEclipseFromMALForTool(onImported)
            TrackerToolPushAniList -> pushEclipseProgressTo("AniList")
            TrackerToolPushMAL -> pushEclipseProgressTo("MyAnimeList")
            TrackerToolPortAniListToMAL -> portAniListToMAL()
            TrackerToolPortMALToAniList -> portMALToAniList()
            else -> error("Unsupported sync tool.")
        }
    }

    private suspend fun previewFillAniList(): TrackerSyncToolPreviewRow {
        val account = trackerRepository.loadSnapshot().getOrThrow().aniListAccount()
            ?: error("Connect AniList first.")
        val animeEntries = fetchAniListAnimeLibrary(account)
        val mangaEntries = fetchAniListMangaLibrary(account)
        return TrackerSyncToolPreviewRow(
            itemsToAdd = animeEntries.size + mangaEntries.size,
            itemsToAdvance = animeEntries.count { it.animeProgressForSync() > 0 } +
                mangaEntries.count { it.mangaProgressForSync() > 0 },
            skipped = 0,
            unmapped = (animeEntries + mangaEntries).count { it.media.id <= 0 },
            estimatedApiCalls = 2,
            notes = listOf("AniList fill reuses Android Library and Manga/Novel import paths; local progress is never deleted or downgraded."),
        )
    }

    private suspend fun previewFillMAL(): TrackerSyncToolPreviewRow {
        val mapped = fetchMappedMALLibraries()
        val mappedAnime = mapped.animeEntries.count { entry -> mapped.animeByMalId[entry.malId] != null }
        val mappedManga = mapped.mangaEntries.count { entry -> mapped.mangaByMalId[entry.malId] != null }
        val unmapped = mapped.animeEntries.size + mapped.mangaEntries.size - mappedAnime - mappedManga
        return TrackerSyncToolPreviewRow(
            itemsToAdd = mappedAnime + mappedManga,
            itemsToAdvance = mapped.animeEntries.count { entry ->
                mapped.animeByMalId[entry.malId] != null && entry.watchedForImport() > 0
            } + mapped.mangaEntries.count { entry ->
                mapped.mangaByMalId[entry.malId] != null && entry.readForImport() > 0
            },
            skipped = unmapped,
            unmapped = unmapped,
            estimatedApiCalls = 4,
            notes = listOf("MAL IDs are resolved in batches through AniList, then imported without overwrites."),
        )
    }

    private suspend fun previewPushTo(service: String): TrackerSyncToolPreviewRow {
        val snapshot = trackerRepository.loadSnapshot().getOrThrow()
        require(snapshot.syncToolAccount(service) != null) { "Connect ${service.syncToolDisplayName()} first." }
        val mangaSnapshot = mangaRepository.loadSnapshot().getOrThrow()
        val counts = trackerRepository.localSyncCandidateCounts(mangaSnapshot).getOrThrow()
        return TrackerSyncToolPreviewRow(
            itemsToAdd = 0,
            itemsToAdvance = counts.totalItems,
            skipped = 0,
            unmapped = 0,
            estimatedApiCalls = if (service.isMyAnimeListService()) {
                counts.animeItems * 4 + counts.mangaItems * 2
            } else {
                counts.animeItems * 3 + counts.mangaItems
            },
            notes = listOf("Local Eclipse progress will only push watched/read progress; it will not delete or downgrade ${service.syncToolDisplayName()}."),
        )
    }

    private suspend fun fillEclipseFromAniListForTool(onImported: () -> Unit): TrackerSyncToolPreviewRow {
        val account = trackerRepository.loadSnapshot().getOrThrow().aniListAccount()
            ?: error("Connect AniList first.")
        setTrackerSyncToolProgress("Filling Eclipse anime from AniList...")
        val animeEntries = fetchAniListAnimeLibrary(account)
        val animeSummary = libraryRepository.importAniListAnime(
            animeEntries.map { entry ->
                AniListLibraryImportDraft(
                    media = entry.media,
                    status = entry.status,
                    progress = entry.progress,
                    score = entry.score,
                    updatedAtEpochSeconds = entry.updatedAtEpochSeconds,
                )
            },
        ).getOrThrow()
        advanceTrackerSyncToolProgress(animeEntries.size, "Finished AniList anime fill")

        setTrackerSyncToolProgress("Filling Eclipse manga from AniList...")
        val mangaEntries = fetchAniListMangaLibrary(account)
        val mangaSummary = mangaRepository.importAniListManga(
            mangaEntries.map { entry ->
                AniListMangaLibraryImportDraft(
                    media = entry.media,
                    status = entry.status,
                    progress = entry.progress,
                    progressVolumes = entry.progressVolumes,
                    score = entry.score,
                    updatedAtEpochSeconds = entry.updatedAtEpochSeconds,
                )
            },
        ).getOrThrow()
        advanceTrackerSyncToolProgress(mangaEntries.size, "Finished AniList manga fill")
        loggerRepository.log("Trackers", "Filled Eclipse from AniList sync tools.")
        onImported()
        return TrackerSyncToolPreviewRow(
            itemsToAdd = animeSummary.importedItems + mangaSummary.importedItems,
            itemsToAdvance = animeSummary.importedContinueWatching + mangaSummary.importedProgress,
            skipped = 0,
            unmapped = 0,
            estimatedApiCalls = 0,
            notes = listOf("AniList fill completed without deleting or downgrading local progress."),
        )
    }

    private suspend fun fillEclipseFromMALForTool(onImported: () -> Unit): TrackerSyncToolPreviewRow {
        setTrackerSyncToolProgress("Matching MAL entries to AniList...")
        val mapped = fetchMappedMALLibraries()
        val animeDrafts = mapped.animeEntries.mapNotNull { entry ->
            val media = mapped.animeByMalId[entry.malId] ?: return@mapNotNull null
            AniListLibraryImportDraft(
                media = media,
                status = entry.status,
                progress = entry.watchedForImport(),
                sourceName = "MAL",
            )
        }
        val mangaDrafts = mapped.mangaEntries.mapNotNull { entry ->
            val media = mapped.mangaByMalId[entry.malId] ?: return@mapNotNull null
            AniListMangaLibraryImportDraft(
                media = media,
                status = entry.status,
                progress = entry.readForImport(),
                sourceName = "MAL",
            )
        }
        val skipped = mapped.animeEntries.size + mapped.mangaEntries.size - animeDrafts.size - mangaDrafts.size

        setTrackerSyncToolProgress("Filling Eclipse anime from MAL...")
        libraryRepository.importAniListAnime(animeDrafts).getOrThrow()
        advanceTrackerSyncToolProgress(animeDrafts.size, "Finished MAL anime fill")
        setTrackerSyncToolProgress("Filling Eclipse manga from MAL...")
        val mangaSummary = mangaRepository.importAniListManga(mangaDrafts).getOrThrow()
        advanceTrackerSyncToolProgress(mangaDrafts.size, "Finished MAL manga fill")
        loggerRepository.log("Trackers", "Filled Eclipse from MyAnimeList sync tools.")
        onImported()
        return TrackerSyncToolPreviewRow(
            itemsToAdd = animeDrafts.size + mangaSummary.importedItems,
            itemsToAdvance = animeDrafts.count { it.progress > 0 } + mangaSummary.importedProgress,
            skipped = skipped,
            unmapped = skipped,
            estimatedApiCalls = 0,
            notes = listOf("MAL fill completed without deleting or downgrading local progress."),
        )
    }

    private suspend fun pushEclipseProgressTo(service: String): TrackerSyncToolPreviewRow {
        val snapshot = trackerRepository.loadSnapshot().getOrThrow()
        require(snapshot.syncToolAccount(service) != null) { "Connect ${service.syncToolDisplayName()} first." }
        val mangaSnapshot = mangaRepository.loadSnapshot().getOrThrow()
        setTrackerSyncToolProgress("Pushing watched progress to ${service.syncToolDisplayName()}...")
        val animeSummary = trackerRepository.syncStoredProgress(
            targetService = service,
            respectSyncEnabled = false,
        ).getOrThrow()
        _state.value = _state.value.withTrackerState(animeSummary.state)
        advanceTrackerSyncToolProgress(animeSummary.attemptedItems, "Finished anime progress push")
        setTrackerSyncToolProgress("Pushing manga progress to ${service.syncToolDisplayName()}...")
        val mangaSummary = trackerRepository.syncStoredMangaProgress(
            snapshot = mangaSnapshot,
            targetService = service,
            respectSyncEnabled = false,
        ).getOrThrow()
        _state.value = _state.value.withTrackerState(mangaSummary.state)
        advanceTrackerSyncToolProgress(mangaSummary.attemptedItems, "Finished manga progress push")
        val synced = animeSummary.syncedItems + mangaSummary.syncedItems
        val skipped = animeSummary.skippedItems + mangaSummary.skippedItems
        val failures = animeSummary.failures + mangaSummary.failures
        loggerRepository.log("Trackers", "Pushed Eclipse progress to ${service.syncToolDisplayName()}: $synced synced, $skipped skipped.")
        return TrackerSyncToolPreviewRow(
            itemsToAdd = 0,
            itemsToAdvance = synced,
            skipped = skipped,
            unmapped = failures.size,
            estimatedApiCalls = 0,
            notes = listOf(
                if (failures.isEmpty()) {
                    "Eclipse progress push completed."
                } else {
                    "Eclipse progress push completed with ${failures.size} issue${failures.size.pluralSuffix()}."
                },
            ),
        )
    }

    private suspend fun portAniListToMAL(): TrackerSyncToolPreviewRow {
        val plan = buildAniListToMALPortPlan()
        setTrackerSyncToolProgress("Writing AniList anime progress to MAL...")
        val animeSummary = trackerRepository.syncRemoteAnimeProgress("MyAnimeList", plan.animeEntries).getOrThrow()
        _state.value = _state.value.withTrackerState(animeSummary.state)
        advanceTrackerSyncToolProgress(animeSummary.attemptedItems, "Finished AniList anime to MAL")
        setTrackerSyncToolProgress("Writing AniList manga progress to MAL...")
        val mangaSummary = trackerRepository.syncRemoteMangaProgress("MyAnimeList", plan.mangaEntries).getOrThrow()
        _state.value = _state.value.withTrackerState(mangaSummary.state)
        advanceTrackerSyncToolProgress(mangaSummary.attemptedItems, "Finished AniList manga to MAL")
        loggerRepository.log("Trackers", "Ported AniList progress to MyAnimeList.")
        return plan.preview.copy(
            itemsToAdvance = animeSummary.syncedItems + mangaSummary.syncedItems,
            skipped = animeSummary.skippedItems + mangaSummary.skippedItems + plan.preview.skipped,
            estimatedApiCalls = 0,
            notes = listOf("AniList to MAL port finished. No entries were deleted."),
        )
    }

    private suspend fun portMALToAniList(): TrackerSyncToolPreviewRow {
        val plan = buildMALToAniListPortPlan()
        setTrackerSyncToolProgress("Writing MAL anime progress to AniList...")
        val animeSummary = trackerRepository.syncRemoteAnimeProgress("AniList", plan.animeEntries).getOrThrow()
        _state.value = _state.value.withTrackerState(animeSummary.state)
        advanceTrackerSyncToolProgress(animeSummary.attemptedItems, "Finished MAL anime to AniList")
        setTrackerSyncToolProgress("Writing MAL manga progress to AniList...")
        val mangaSummary = trackerRepository.syncRemoteMangaProgress("AniList", plan.mangaEntries).getOrThrow()
        _state.value = _state.value.withTrackerState(mangaSummary.state)
        advanceTrackerSyncToolProgress(mangaSummary.attemptedItems, "Finished MAL manga to AniList")
        loggerRepository.log("Trackers", "Ported MyAnimeList progress to AniList.")
        return plan.preview.copy(
            itemsToAdvance = animeSummary.syncedItems + mangaSummary.syncedItems,
            skipped = animeSummary.skippedItems + mangaSummary.skippedItems + plan.preview.skipped,
            estimatedApiCalls = 0,
            notes = listOf("MAL to AniList port finished. No entries were deleted."),
        )
    }

    private fun beginTrackerSyncTool(
        actionId: String,
        detail: String,
    ) {
        _state.value = _state.value.copy(
            activeTrackerSyncToolId = actionId,
            isTrackerSyncToolRunning = true,
            trackerStatus = detail,
            trackerSyncToolProgressCompleted = 0,
            trackerSyncToolProgressTotal = 0,
            trackerSyncToolProgressDetail = detail,
        )
    }

    private fun setTrackerSyncToolProgress(detail: String) {
        _state.value = _state.value.copy(
            trackerStatus = detail,
            trackerSyncToolProgressDetail = detail,
        )
    }

    private fun advanceTrackerSyncToolProgress(
        amount: Int,
        detail: String,
    ) {
        val current = _state.value
        _state.value = current.copy(
            trackerSyncToolProgressCompleted = (current.trackerSyncToolProgressCompleted + amount)
                .coerceAtMost(current.trackerSyncToolProgressTotal.coerceAtLeast(0)),
            trackerSyncToolProgressDetail = detail,
        )
    }

    private fun finishCanceledSyncTool(actionId: String) {
        _state.value = _state.value.copy(
            activeTrackerSyncToolId = actionId,
            isTrackerSyncToolRunning = false,
            trackerStatus = "Canceled ${actionId.syncToolTitle()}",
            trackerSyncToolProgressDetail = "Canceled",
        )
    }

    private fun finishFailedSyncTool(message: String) {
        _state.value = _state.value.copy(
            isTrackerSyncToolRunning = false,
            trackerStatus = message,
            trackerSyncToolProgressDetail = message,
        )
    }

    private suspend fun fetchAniListAnimeLibrary(account: TrackerAccountSnapshot): List<AniListService.LibraryEntry> =
        when (
            val result = aniListService.fetchAnimeLibrary(
                accessToken = account.accessToken,
                username = account.username.takeIf(String::isNotBlank),
            )
        ) {
            is NetworkResult.Success -> result.value
            is NetworkResult.Failure -> error(result.toStatusMessage("AniList anime library fetch failed."))
        }

    private suspend fun fetchAniListMangaLibrary(account: TrackerAccountSnapshot): List<AniListService.LibraryEntry> =
        when (
            val result = aniListService.fetchMangaLibrary(
                accessToken = account.accessToken,
                username = account.username.takeIf(String::isNotBlank),
            )
        ) {
            is NetworkResult.Success -> result.value
            is NetworkResult.Failure -> error(result.toStatusMessage("AniList manga library fetch failed."))
        }

    private suspend fun fetchMALAnimeLibrary(account: TrackerAccountSnapshot): List<MyAnimeListService.AnimeLibraryEntry> =
        when (val result = myAnimeListService.fetchAnimeLibrary(account.accessToken)) {
            is NetworkResult.Success -> result.value
            is NetworkResult.Failure -> error(result.toStatusMessage("MAL anime library fetch failed."))
        }

    private suspend fun fetchMALMangaLibrary(account: TrackerAccountSnapshot): List<MyAnimeListService.MangaLibraryEntry> =
        when (val result = myAnimeListService.fetchMangaLibrary(account.accessToken)) {
            is NetworkResult.Success -> result.value
            is NetworkResult.Failure -> error(result.toStatusMessage("MAL manga library fetch failed."))
        }

    private suspend fun fetchMappedMALLibraries(): MappedMALLibraries {
        val account = trackerRepository.loadSnapshot().getOrThrow().myAnimeListAccount()
            ?: error("Connect MyAnimeList first.")
        val animeEntries = fetchMALAnimeLibrary(account)
        val mangaEntries = fetchMALMangaLibrary(account)
        val animeByMalId = when (val result = aniListService.mediaByMalIds(animeEntries.map { it.malId }, mediaType = "ANIME")) {
            is NetworkResult.Success -> result.value
            is NetworkResult.Failure -> error(result.toStatusMessage("MAL anime matching failed."))
        }
        val mangaByMalId = when (val result = aniListService.mediaByMalIds(mangaEntries.map { it.malId }, mediaType = "MANGA")) {
            is NetworkResult.Success -> result.value
            is NetworkResult.Failure -> error(result.toStatusMessage("MAL manga matching failed."))
        }
        return MappedMALLibraries(
            animeEntries = animeEntries,
            mangaEntries = mangaEntries,
            animeByMalId = animeByMalId,
            mangaByMalId = mangaByMalId,
        )
    }

    private suspend fun buildAniListToMALPortPlan(): TrackerPortPlan {
        val snapshot = trackerRepository.loadSnapshot().getOrThrow()
        val aniListAccount = snapshot.aniListAccount() ?: error("Connect AniList first.")
        snapshot.myAnimeListAccount() ?: error("Connect MyAnimeList first.")
        val sourceAnime = fetchAniListAnimeLibrary(aniListAccount)
        val sourceManga = fetchAniListMangaLibrary(aniListAccount)
        val malAccount = snapshot.myAnimeListAccount() ?: error("Connect MyAnimeList first.")
        val destinationAnimeByMalId = fetchMALAnimeLibrary(malAccount).associateBy { it.malId }
        val destinationMangaByMalId = fetchMALMangaLibrary(malAccount).associateBy { it.malId }
        val mappedAnime = sourceAnime.filter { entry -> entry.media.idMal != null }
        val mappedManga = sourceManga.filter { entry -> entry.media.idMal != null }
        val animeEntries = mappedAnime.mapNotNull { entry ->
            val malId = entry.media.idMal ?: return@mapNotNull null
            val progress = entry.animeProgressForSync()
            val destinationProgress = destinationAnimeByMalId[malId]?.watchedForImport() ?: 0
            if (progress <= destinationProgress) return@mapNotNull null
            TrackerRemoteAnimeProgress(
                aniListId = entry.media.id,
                title = entry.media.displayTitle,
                progress = progress,
                isComplete = entry.isAnimeComplete(),
            )
        }
        val mangaEntries = mappedManga.mapNotNull { entry ->
            val malId = entry.media.idMal ?: return@mapNotNull null
            val progress = entry.mangaProgressForSync()
            val destinationProgress = destinationMangaByMalId[malId]?.readForImport() ?: 0
            if (progress <= destinationProgress) return@mapNotNull null
            TrackerRemoteMangaProgress(
                aniListId = entry.media.id,
                progress = progress,
                isComplete = entry.isMangaComplete(),
            )
        }
        val total = sourceAnime.size + sourceManga.size
        val mapped = mappedAnime.size + mappedManga.size
        val advancing = animeEntries.size + mangaEntries.size
        val unmapped = total - mapped
        return TrackerPortPlan(
            preview = TrackerSyncToolPreviewRow(
                itemsToAdd = 0,
                itemsToAdvance = advancing,
                skipped = total - advancing,
                unmapped = unmapped,
                estimatedApiCalls = total + advancing,
                notes = listOf("Only entries that advance MAL are written; already-current destination entries are skipped."),
            ),
            animeEntries = animeEntries,
            mangaEntries = mangaEntries,
        )
    }

    private suspend fun buildMALToAniListPortPlan(): TrackerPortPlan {
        val snapshot = trackerRepository.loadSnapshot().getOrThrow()
        val mapped = fetchMappedMALLibraries()
        val aniListAccount = snapshot.aniListAccount() ?: error("Connect AniList first.")
        val destinationAnimeByAniListId = fetchAniListAnimeLibrary(aniListAccount).associateBy { it.media.id }
        val destinationMangaByAniListId = fetchAniListMangaLibrary(aniListAccount).associateBy { it.media.id }
        val animeEntries = mapped.animeEntries.mapNotNull { entry ->
            val media = mapped.animeByMalId[entry.malId] ?: return@mapNotNull null
            val progress = entry.watchedForImport()
            val destinationProgress = destinationAnimeByAniListId[media.id]?.animeProgressForSync() ?: 0
            if (progress <= destinationProgress) return@mapNotNull null
            TrackerRemoteAnimeProgress(
                aniListId = media.id,
                title = media.displayTitle,
                progress = progress,
                isComplete = entry.isAnimeComplete(),
            )
        }
        val mangaEntries = mapped.mangaEntries.mapNotNull { entry ->
            val media = mapped.mangaByMalId[entry.malId] ?: return@mapNotNull null
            val progress = entry.readForImport()
            val destinationProgress = destinationMangaByAniListId[media.id]?.mangaProgressForSync() ?: 0
            if (progress <= destinationProgress) return@mapNotNull null
            TrackerRemoteMangaProgress(
                aniListId = media.id,
                progress = progress,
                isComplete = entry.isMangaComplete(),
            )
        }
        val total = mapped.animeEntries.size + mapped.mangaEntries.size
        val mappedCount = mapped.animeEntries.count { entry -> mapped.animeByMalId[entry.malId] != null } +
            mapped.mangaEntries.count { entry -> mapped.mangaByMalId[entry.malId] != null }
        val advancing = animeEntries.size + mangaEntries.size
        val unmapped = total - mappedCount
        return TrackerPortPlan(
            preview = TrackerSyncToolPreviewRow(
                itemsToAdd = 0,
                itemsToAdvance = advancing,
                skipped = total - advancing,
                unmapped = unmapped,
                estimatedApiCalls = total + advancing,
                notes = listOf("MAL IDs are resolved in batches, and only entries that advance AniList are written."),
            ),
            animeEntries = animeEntries,
            mangaEntries = mangaEntries,
        )
    }

    private fun moveCatalog(id: String, direction: Int) {
        viewModelScope.launch {
            catalogRepository.moveCatalog(id, direction)
                .onSuccess { snapshot ->
                    _state.value = _state.value.copy(catalogs = snapshot.catalogs.toUiRows())
                }
        }
    }

    private fun refreshBackupStatus() {
        viewModelScope.launch {
            backupRepository.loadStatus()
                .onSuccess(::applyBackupStatus)
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        hasLocalBackup = false,
                        backupStatusHeadline = "Backup status unavailable",
                        backupStatusMessage = error.message ?: "Could not inspect the staged backup yet.",
                    )
                }
        }
    }

    private fun refreshCatalogs() {
        viewModelScope.launch {
            catalogRepository.loadSnapshot()
                .onSuccess { snapshot ->
                    _state.value = _state.value.copy(catalogs = snapshot.catalogs.toUiRows())
                }
        }
    }

    private fun refreshTrackers() {
        viewModelScope.launch {
            trackerRepository.loadSnapshot()
                .onSuccess { snapshot ->
                    _state.value = _state.value.withTrackerState(snapshot)
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        trackerStatus = error.message ?: "Could not load tracker state.",
                    )
                }
        }
    }

    private fun runBackupMutation(
        action: suspend () -> Result<BackupStatusSnapshot>,
    ) {
        viewModelScope.launch {
            _state.value = _state.value.copy(isBackupBusy = true)
            action()
                .onSuccess { status ->
                    _state.value = _state.value.copy(isBackupBusy = false)
                    applyBackupStatus(status)
                    refreshCatalogs()
                    refreshTrackers()
                }
                .onFailure { error ->
                    _state.value = _state.value.copy(
                        isBackupBusy = false,
                        backupStatusHeadline = "Backup failed",
                        backupStatusMessage = error.message ?: "Could not finish the backup operation.",
                    )
                }
        }
    }

    private fun applyBackupStatus(status: BackupStatusSnapshot) {
        _state.value = _state.value.copy(
            hasLocalBackup = status.hasLocalBackup,
            backupStatusHeadline = status.headline,
            backupStatusMessage = status.supportingText,
        )
    }

    private fun checkGitHubReleaseIfNeeded() {
        viewModelScope.launch {
            releaseRepository.checkForUpdatesIfNeeded()
                .onSuccess { summary ->
                    if (summary != null) {
                        val message = if (summary.updateAvailable) {
                            "Update available: ${summary.latestVersion}"
                        } else {
                            "App is up to date: ${summary.latestVersion}"
                        }
                        _state.value = _state.value.copy(githubReleaseStatus = message)
                        loggerRepository.log("Updates", message)
                        refreshLogs()
                    }
                }
                .onFailure { error ->
                    loggerRepository.log("Updates", error.message ?: "GitHub release check failed.", level = "error")
                    refreshLogs()
                }
        }
    }

    private fun autoUpdateServicesIfNeeded() {
        viewModelScope.launch {
            val settings = settingsStore.settings.first()
            if (!settings.autoUpdateServicesEnabled) return@launch
            val now = System.currentTimeMillis()
            val elapsed = now - settings.lastServiceAutoUpdateTimestamp
            if (elapsed in 0 until ServiceAutoUpdateIntervalMillis) return@launch
            servicesRepository.refreshAllSources()
                .onSuccess { summary ->
                    settingsStore.markServiceAutoUpdateChecked(now)
                    if (
                        summary.refreshedAddons > 0 ||
                        summary.failedAddons > 0 ||
                        summary.refreshedServices > 0 ||
                        summary.failedServices > 0
                    ) {
                        loggerRepository.log("Services", summary.statusMessage)
                        refreshLogs()
                    }
                }
                .onFailure { error ->
                    settingsStore.markServiceAutoUpdateChecked(now)
                    loggerRepository.log("Services", error.message ?: "Service auto-update failed.", level = "error")
                    refreshLogs()
                }
        }
    }
}

private const val ServiceAutoUpdateIntervalMillis = 60L * 60L * 1_000L

private fun AppSettings.toGitHubReleaseStatus(): String = when {
    githubReleaseUpdateAvailable && githubReleaseLatestVersion.isNotBlank() ->
        "Update available: $githubReleaseLatestVersion"
    githubReleaseUpdateAvailable -> "Update available on GitHub."
    githubReleaseLatestVersion.isNotBlank() -> "App is up to date: $githubReleaseLatestVersion"
    githubReleaseLastCheckTimestamp > 0L -> "Last GitHub release check did not find a release."
    else -> "Release checks have not run yet."
}

private fun List<dev.soupy.eclipse.android.core.model.BackupCatalog>.toUiRows(): List<CatalogSettingsRow> =
    sortedBy { it.order }.map { catalog ->
        CatalogSettingsRow(
            id = catalog.id,
            name = catalog.displayName,
            source = catalog.resolvedSource,
            displayStyle = catalog.displayStyle,
            enabled = catalog.isEnabled,
            order = catalog.order,
        )
    }

private fun SettingsScreenState.withTrackerState(
    snapshot: dev.soupy.eclipse.android.core.model.TrackerStateSnapshot,
    status: String? = null,
): SettingsScreenState {
    val rows = snapshot.accounts.map { account ->
        TrackerSettingsRow(
            service = account.service,
            username = account.username,
            tokenPreview = account.accessToken.toTokenPreview(),
            isConnected = account.isConnected,
        )
    }.ifEmpty {
        val provider = snapshot.provider
        val token = snapshot.accessToken
        if (!provider.isNullOrBlank() && !token.isNullOrBlank()) {
            listOf(
                TrackerSettingsRow(
                    service = provider,
                    username = snapshot.userName.orEmpty(),
                    tokenPreview = token.toTokenPreview(),
                    isConnected = true,
                ),
            )
        } else {
            emptyList()
        }
    }
    val trackerStatus = status ?: when {
        rows.isEmpty() -> "No tracker accounts connected yet."
        snapshot.lastSyncDate != null -> "${rows.size} tracker account${if (rows.size == 1) "" else "s"} - last sync ${snapshot.lastSyncDate}"
        else -> "${rows.size} tracker account${if (rows.size == 1) "" else "s"} connected."
    }
    return copy(
        trackerSyncEnabled = snapshot.syncEnabled,
        autoSyncRatings = snapshot.autoSyncRatings,
        trackerRows = rows,
        trackerStatus = trackerStatus,
    )
}

private fun SettingsScreenState.withTrackerSyncToolPreview(
    actionId: String,
    preview: TrackerSyncToolPreviewRow,
): SettingsScreenState =
    copy(
        activeTrackerSyncToolId = actionId,
        trackerSyncTools = trackerSyncTools.map { tool ->
            if (tool.id == actionId) tool.copy(preview = preview) else tool
        },
    )

private fun TrackerSyncToolPreviewRow.syncOperationCount(): Int =
    (itemsToAdd + itemsToAdvance + skipped).coerceAtLeast(0)

private fun String.syncToolTitle(): String = when (this) {
    TrackerToolFillAniList -> "Fill Eclipse From AniList"
    TrackerToolFillMAL -> "Fill Eclipse From MAL"
    TrackerToolPushAniList -> "Push Eclipse To AniList"
    TrackerToolPushMAL -> "Push Eclipse To MAL"
    TrackerToolPortAniListToMAL -> "Port AniList To MAL"
    TrackerToolPortMALToAniList -> "Port MAL To AniList"
    else -> "Sync Tool"
}

private fun String.syncToolDisplayName(): String =
    if (isMyAnimeListService()) "MyAnimeList" else this

private fun TrackerStateSnapshot.syncToolAccount(service: String): TrackerAccountSnapshot? =
    if (service.isMyAnimeListService()) myAnimeListAccount() else aniListAccount()

private fun TrackerStateSnapshot.aniListAccount(): TrackerAccountSnapshot? {
    val modern = accounts.firstOrNull { account ->
        account.isConnected &&
            account.accessToken.isNotBlank() &&
            account.service.equals("AniList", ignoreCase = true)
    }
    if (modern != null) return modern

    val provider = provider ?: return null
    val token = accessToken ?: return null
    return if (provider.equals("AniList", ignoreCase = true) && token.isNotBlank()) {
        TrackerAccountSnapshot(
            service = provider,
            username = userName.orEmpty(),
            accessToken = token,
            refreshToken = refreshToken,
            isConnected = true,
        )
    } else {
        null
    }
}

private fun TrackerStateSnapshot.myAnimeListAccount(): TrackerAccountSnapshot? {
    val modern = accounts.firstOrNull { account ->
        account.isConnected &&
            account.accessToken.isNotBlank() &&
            account.service.isMyAnimeListService()
    }
    if (modern != null) return modern

    val provider = provider ?: return null
    val token = accessToken ?: return null
    return if (provider.isMyAnimeListService() && token.isNotBlank()) {
        TrackerAccountSnapshot(
            service = provider,
            username = userName.orEmpty(),
            accessToken = token,
            refreshToken = refreshToken,
            isConnected = true,
        )
    } else {
        null
    }
}

private data class MappedMALLibraries(
    val animeEntries: List<MyAnimeListService.AnimeLibraryEntry>,
    val mangaEntries: List<MyAnimeListService.MangaLibraryEntry>,
    val animeByMalId: Map<Int, AniListMedia>,
    val mangaByMalId: Map<Int, AniListMedia>,
)

private data class TrackerPortPlan(
    val preview: TrackerSyncToolPreviewRow,
    val animeEntries: List<TrackerRemoteAnimeProgress>,
    val mangaEntries: List<TrackerRemoteMangaProgress>,
)

private fun AniListService.LibraryEntry.animeProgressForSync(): Int =
    if (status?.equals("COMPLETED", ignoreCase = true) == true) {
        maxOf(progress, media.episodes ?: 0)
    } else {
        progress.coerceAtLeast(0)
    }

private fun AniListService.LibraryEntry.mangaProgressForSync(): Int =
    if (status?.equals("COMPLETED", ignoreCase = true) == true) {
        maxOf(progress, media.chapters ?: 0)
    } else {
        progress.coerceAtLeast(0)
    }

private fun AniListService.LibraryEntry.isAnimeComplete(): Boolean =
    status?.equals("COMPLETED", ignoreCase = true) == true ||
        media.episodes?.takeIf { it > 0 }?.let { animeProgressForSync() >= it } == true

private fun AniListService.LibraryEntry.isMangaComplete(): Boolean =
    status?.equals("COMPLETED", ignoreCase = true) == true ||
        media.chapters?.takeIf { it > 0 }?.let { mangaProgressForSync() >= it } == true

private fun MyAnimeListService.AnimeLibraryEntry.isAnimeComplete(): Boolean =
    status.equals("completed", ignoreCase = true) ||
        totalEpisodes?.takeIf { it > 0 }?.let { watchedForImport() >= it } == true

private fun MyAnimeListService.MangaLibraryEntry.isMangaComplete(): Boolean =
    status.equals("completed", ignoreCase = true) ||
        totalChapters?.takeIf { it > 0 }?.let { readForImport() >= it } == true

private fun MyAnimeListService.AnimeLibraryEntry.watchedForImport(): Int =
    if (status.equals("completed", ignoreCase = true)) {
        maxOf(progress, totalEpisodes ?: 0)
    } else {
        progress.coerceAtLeast(0)
    }

private fun MyAnimeListService.MangaLibraryEntry.readForImport(): Int =
    if (status.equals("completed", ignoreCase = true)) {
        maxOf(progress, totalChapters ?: 0)
    } else {
        progress.coerceAtLeast(0)
    }

private fun NetworkResult.Failure.toStatusMessage(prefix: String): String = when (this) {
    is NetworkResult.Failure.Http -> "$prefix HTTP $code${body?.takeIf { it.isNotBlank() }?.let { ": $it" }.orEmpty()}"
    is NetworkResult.Failure.Connectivity -> "$prefix ${throwable.message ?: "network unavailable"}"
    is NetworkResult.Failure.Serialization -> "$prefix ${throwable.message ?: "unexpected tracker response"}"
}

private fun TrackerSyncSummary.toMangaSyncStatusMessage(): String = when {
    attemptedAccounts == 0 -> "No connected AniList or MyAnimeList account is ready to sync manga progress."
    attemptedItems == 0 -> "No tracker-backed manga progress is ready to sync yet."
    failures.isNotEmpty() && syncedItems == 0 -> "Manga progress sync failed: ${failures.first()}"
    failures.isNotEmpty() -> "Synced $syncedItems manga item${syncedItems.pluralSuffix()} with ${failures.size} issue${failures.size.pluralSuffix()}."
    syncedItems > 0 -> "Synced $syncedItems manga item${syncedItems.pluralSuffix()} to AniList."
    else -> "Manga progress sync skipped $skippedItems item${skippedItems.pluralSuffix()} with no remote updates."
}

private fun Int.pluralSuffix(): String = if (this == 1) "" else "s"

private fun String.toTokenPreview(): String =
    when {
        isBlank() -> "No token"
        length <= 8 -> "token saved"
        else -> "${take(4)}...${takeLast(4)}"
    }

private fun String.isMyAnimeListService(): Boolean {
    val normalized = lowercase().replace(Regex("[^a-z0-9]+"), "")
    return normalized == "myanimelist" || normalized == "mal"
}

private fun Long.toByteCountLabel(): String {
    val units = listOf("B", "KB", "MB", "GB")
    var value = toDouble().coerceAtLeast(0.0)
    var unitIndex = 0
    while (value >= 1024.0 && unitIndex < units.lastIndex) {
        value /= 1024.0
        unitIndex += 1
    }
    return if (unitIndex == 0) {
        "${value.toLong()} ${units[unitIndex]}"
    } else {
        "%.1f %s".format(value, units[unitIndex])
    }
}

private fun Long.toReadableClock(): String =
    runCatching {
        Instant.ofEpochMilli(this)
            .atZone(ZoneId.systemDefault())
            .format(DateTimeFormatter.ofPattern("MMM d, h:mm a"))
    }.getOrDefault("unknown time")
