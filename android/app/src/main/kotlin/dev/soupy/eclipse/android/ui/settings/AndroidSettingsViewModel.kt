package dev.soupy.eclipse.android.ui.settings

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.soupy.eclipse.android.core.model.InAppPlayer
import dev.soupy.eclipse.android.core.model.SimilarityAlgorithm
import dev.soupy.eclipse.android.core.model.TrackerAccountSnapshot
import dev.soupy.eclipse.android.core.model.TrackerStateSnapshot
import dev.soupy.eclipse.android.core.network.AniListService
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
import dev.soupy.eclipse.android.data.TrackerRepository
import dev.soupy.eclipse.android.data.TrackerSyncSummary
import dev.soupy.eclipse.android.feature.settings.CatalogSettingsRow
import dev.soupy.eclipse.android.feature.settings.LogSettingsRow
import dev.soupy.eclipse.android.feature.settings.SettingsScreenState
import dev.soupy.eclipse.android.feature.settings.StorageMetricRow
import dev.soupy.eclipse.android.feature.settings.TrackerSettingsRow
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
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
    private val releaseRepository: ReleaseRepository,
    private val servicesRepository: ServicesRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(
        SettingsScreenState(
            aniListOAuthUrl = trackerRepository.authorizationUrl("AniList").orEmpty(),
            traktOAuthUrl = trackerRepository.authorizationUrl("Trakt").orEmpty(),
        ),
    )
    val state: StateFlow<SettingsScreenState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            settingsStore.settings.collect { settings ->
                _state.value = _state.value.copy(
                    accentColor = settings.accentColor,
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
                    defaultSubtitleLanguage = settings.defaultSubtitleLanguage,
                    preferredAnimeAudioLanguage = settings.preferredAnimeAudioLanguage,
                    holdSpeedPlayer = settings.holdSpeedPlayer,
                    externalPlayer = settings.externalPlayer,
                    alwaysLandscape = settings.alwaysLandscape,
                    vlcHeaderProxyEnabled = settings.vlcHeaderProxyEnabled,
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
        checkGitHubReleaseIfNeeded()
        autoUpdateServicesIfNeeded()
    }

    fun setAccentColor(value: String) {
        val current = _state.value
        updateAppearance(
            accentColor = value,
            tmdbLanguage = current.tmdbLanguage,
            selectedAppearance = current.selectedAppearance,
        )
    }

    fun setTmdbLanguage(value: String) {
        val current = _state.value
        updateAppearance(
            accentColor = current.accentColor,
            tmdbLanguage = value,
            selectedAppearance = current.selectedAppearance,
        )
    }

    fun setAppearance(value: String) {
        val current = _state.value
        updateAppearance(
            accentColor = current.accentColor,
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
                nextEpisodeThreshold = threshold.coerceIn(70, 98),
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
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
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
            defaultSubtitleLanguage = language,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
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
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = language,
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
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
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
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
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
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
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
            defaultSubtitleLanguage = current.defaultSubtitleLanguage,
            preferredAnimeAudioLanguage = current.preferredAnimeAudioLanguage,
            holdSpeedPlayer = current.holdSpeedPlayer,
            externalPlayer = current.externalPlayer,
            alwaysLandscape = current.alwaysLandscape,
            vlcHeaderProxyEnabled = enabled,
        )
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
        defaultSubtitleLanguage: String,
        preferredAnimeAudioLanguage: String,
        holdSpeedPlayer: Double,
        externalPlayer: String,
        alwaysLandscape: Boolean,
        vlcHeaderProxyEnabled: Boolean,
    ) {
        viewModelScope.launch {
            settingsStore.updatePlayerPreferences(
                enableSubtitlesByDefault = enableSubtitlesByDefault,
                defaultSubtitleLanguage = defaultSubtitleLanguage,
                preferredAnimeAudioLanguage = preferredAnimeAudioLanguage,
                holdSpeedPlayer = holdSpeedPlayer,
                externalPlayer = externalPlayer,
                alwaysLandscape = alwaysLandscape,
                vlcHeaderProxyEnabled = vlcHeaderProxyEnabled,
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
        tmdbLanguage: String,
        selectedAppearance: String,
    ) {
        viewModelScope.launch {
            settingsStore.updateAppearance(
                accentColor = accentColor,
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
        trackerRows = rows,
        trackerStatus = trackerStatus,
    )
}

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

private fun NetworkResult.Failure.toStatusMessage(prefix: String): String = when (this) {
    is NetworkResult.Failure.Http -> "$prefix HTTP $code${body?.takeIf { it.isNotBlank() }?.let { ": $it" }.orEmpty()}"
    is NetworkResult.Failure.Connectivity -> "$prefix ${throwable.message ?: "network unavailable"}"
    is NetworkResult.Failure.Serialization -> "$prefix ${throwable.message ?: "unexpected AniList response"}"
}

private fun TrackerSyncSummary.toMangaSyncStatusMessage(): String = when {
    attemptedAccounts == 0 -> "No connected AniList account is ready to sync manga progress."
    attemptedItems == 0 -> "No AniList manga progress is ready to sync yet."
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
