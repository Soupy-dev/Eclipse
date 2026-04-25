package dev.soupy.eclipse.android.feature.settings

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts.CreateDocument
import androidx.activity.result.contract.ActivityResultContracts.OpenDocument
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.design.SectionHeading
import dev.soupy.eclipse.android.core.model.InAppPlayer
import dev.soupy.eclipse.android.core.model.SimilarityAlgorithm
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

data class SettingsScreenState(
    val accentColor: String = "#6D8CFF",
    val tmdbLanguage: String = "en-US",
    val selectedAppearance: String = "system",
    val autoModeEnabled: Boolean = true,
    val highQualityThreshold: Double = 0.9,
    val filterHorrorContent: Boolean = false,
    val selectedSimilarityAlgorithm: SimilarityAlgorithm = SimilarityAlgorithm.HYBRID,
    val showNextEpisodeButton: Boolean = true,
    val nextEpisodeThreshold: Int = 90,
    val inAppPlayer: InAppPlayer = InAppPlayer.NORMAL,
    val enableSubtitlesByDefault: Boolean = false,
    val defaultSubtitleLanguage: String = "eng",
    val preferredAnimeAudioLanguage: String = "jpn",
    val holdSpeedPlayer: Double = 2.0,
    val externalPlayer: String = "none",
    val alwaysLandscape: Boolean = false,
    val vlcHeaderProxyEnabled: Boolean = true,
    val subtitleForegroundColor: String? = null,
    val subtitleStrokeColor: String? = null,
    val subtitleStrokeWidth: Double = 1.0,
    val subtitleFontSize: Double = 30.0,
    val subtitleVerticalOffset: Double = -6.0,
    val aniSkipEnabled: Boolean = true,
    val introDbEnabled: Boolean = true,
    val aniSkipAutoSkip: Boolean = false,
    val skip85sEnabled: Boolean = false,
    val skip85sAlwaysVisible: Boolean = false,
    val showScheduleTab: Boolean = true,
    val showKanzen: Boolean = false,
    val seasonMenu: Boolean = false,
    val horizontalEpisodeList: Boolean = false,
    val mediaColumnsPortrait: Int = 3,
    val mediaColumnsLandscape: Int = 5,
    val readingMode: Int = 2,
    val readerFontSize: Double = 16.0,
    val readerFontFamily: String = "-apple-system",
    val readerFontWeight: String = "normal",
    val readerColorPreset: Int = 0,
    val readerLineSpacing: Double = 1.6,
    val readerMargin: Double = 4.0,
    val readerTextAlignment: String = "left",
    val kanzenAutoUpdateModules: Boolean = true,
    val isBackupBusy: Boolean = false,
    val hasLocalBackup: Boolean = false,
    val backupStatusHeadline: String = "No local backup yet",
    val backupStatusMessage: String = "Export a JSON archive or import an existing Luna backup.",
    val catalogs: List<CatalogSettingsRow> = emptyList(),
    val storageMetrics: List<StorageMetricRow> = emptyList(),
    val storageStatus: String = "Storage has not been measured yet.",
    val autoClearCacheEnabled: Boolean = false,
    val autoClearCacheThresholdMB: Double = 500.0,
    val logRows: List<LogSettingsRow> = emptyList(),
    val loggerStatus: String = "No logs captured yet.",
    val trackerSyncEnabled: Boolean = true,
    val trackerRows: List<TrackerSettingsRow> = emptyList(),
    val trackerStatus: String = "No tracker accounts connected yet.",
    val aniListOAuthUrl: String = "",
    val traktOAuthUrl: String = "",
    val autoUpdateServicesEnabled: Boolean = true,
    val githubReleaseAutoCheckEnabled: Boolean = true,
    val githubReleaseUpdateAvailable: Boolean = false,
    val githubReleaseLatestVersion: String = "",
    val githubReleaseUrl: String = "",
    val githubReleaseShowAlertPending: Boolean = false,
    val githubReleaseStatus: String = "Release checks have not run yet.",
    val isCheckingGitHubRelease: Boolean = false,
)

data class CatalogSettingsRow(
    val id: String,
    val name: String,
    val source: String,
    val displayStyle: String,
    val enabled: Boolean,
    val order: Int,
)

data class StorageMetricRow(
    val label: String,
    val value: String,
)

data class LogSettingsRow(
    val id: String,
    val timestamp: String,
    val tag: String,
    val message: String,
    val level: String,
)

data class TrackerSettingsRow(
    val service: String,
    val username: String,
    val tokenPreview: String,
    val isConnected: Boolean,
)

private val AppearanceOptions = listOf(
    "system" to "System",
    "light" to "Light",
    "dark" to "Dark",
)

private val ReaderFontFamilies = listOf(
    "-apple-system" to "System",
    "Georgia" to "Georgia",
    "Times New Roman" to "Times",
    "Helvetica" to "Helvetica",
    "Charter" to "Charter",
    "New York" to "New York",
)

private val ReaderFontWeights = listOf(
    "300" to "Light",
    "normal" to "Regular",
    "600" to "Semibold",
    "bold" to "Bold",
)

private val ReaderColorPresets = listOf(
    "Pure",
    "Warm",
    "Slate",
    "Off-Black",
    "Dark",
)

private enum class SettingsSection(val label: String) {
    BASIC("Basic"),
    DISCOVERY("Discovery"),
    PLAYBACK("Playback"),
    READER("Reader"),
    TRACKERS("Trackers"),
    CATALOGS("Catalogs"),
    DATA("Data"),
    UPDATES("Updates"),
}

@Composable
fun SettingsRoute(
    state: SettingsScreenState,
    onClose: () -> Unit,
    onAccentColorChanged: (String) -> Unit,
    onTmdbLanguageChanged: (String) -> Unit,
    onAppearanceChanged: (String) -> Unit,
    onShowScheduleTabChanged: (Boolean) -> Unit,
    onShowKanzenChanged: (Boolean) -> Unit,
    onSeasonMenuChanged: (Boolean) -> Unit,
    onHorizontalEpisodeListChanged: (Boolean) -> Unit,
    onMediaColumnsPortraitChanged: (Int) -> Unit,
    onMediaColumnsLandscapeChanged: (Int) -> Unit,
    onOpenServices: () -> Unit,
    onAutoUpdateServicesChanged: (Boolean) -> Unit,
    onCheckGitHubRelease: () -> Unit,
    onGitHubReleaseAutoCheckChanged: (Boolean) -> Unit,
    onAutoModeChanged: (Boolean) -> Unit,
    onShowNextEpisodeChanged: (Boolean) -> Unit,
    onNextEpisodeThresholdChanged: (Int) -> Unit,
    onPlayerSelected: (InAppPlayer) -> Unit,
    onEnableSubtitlesByDefaultChanged: (Boolean) -> Unit,
    onDefaultSubtitleLanguageChanged: (String) -> Unit,
    onPreferredAnimeAudioLanguageChanged: (String) -> Unit,
    onHoldSpeedChanged: (Double) -> Unit,
    onExternalPlayerChanged: (String) -> Unit,
    onAlwaysLandscapeChanged: (Boolean) -> Unit,
    onVlcHeaderProxyChanged: (Boolean) -> Unit,
    onSubtitleForegroundColorChanged: (String?) -> Unit,
    onSubtitleStrokeColorChanged: (String?) -> Unit,
    onSubtitleStrokeWidthChanged: (Double) -> Unit,
    onSubtitleFontSizeChanged: (Double) -> Unit,
    onSubtitleVerticalOffsetChanged: (Double) -> Unit,
    onAniSkipEnabledChanged: (Boolean) -> Unit,
    onIntroDbEnabledChanged: (Boolean) -> Unit,
    onAniSkipAutoSkipChanged: (Boolean) -> Unit,
    onSkip85sChanged: (Boolean) -> Unit,
    onSkip85sAlwaysVisibleChanged: (Boolean) -> Unit,
    onCatalogEnabledChanged: (String, Boolean) -> Unit,
    onMoveCatalogUp: (String) -> Unit,
    onMoveCatalogDown: (String) -> Unit,
    onRefreshStorage: () -> Unit,
    onClearCache: () -> Unit,
    onAutoClearCacheEnabledChanged: (Boolean) -> Unit,
    onAutoClearCacheThresholdChanged: (Double) -> Unit,
    onRefreshLogs: () -> Unit,
    onClearLogs: () -> Unit,
    onReadingModeChanged: (Int) -> Unit,
    onReaderFontSizeChanged: (Double) -> Unit,
    onReaderFontFamilyChanged: (String) -> Unit,
    onReaderFontWeightChanged: (String) -> Unit,
    onReaderColorPresetChanged: (Int) -> Unit,
    onReaderLineSpacingChanged: (Double) -> Unit,
    onReaderMarginChanged: (Double) -> Unit,
    onReaderAlignmentChanged: (String) -> Unit,
    onKanzenAutoUpdateModulesChanged: (Boolean) -> Unit,
    onTrackerManualConnect: (String, String, String) -> Unit,
    onTrackerSyncEnabledChanged: (Boolean) -> Unit,
    onTrackerDisconnect: (String) -> Unit,
    onTrackerSyncNow: () -> Unit,
    onAniListImportLibrary: () -> Unit,
    onAniListImportMangaLibrary: () -> Unit,
    onAniListSyncMangaProgress: () -> Unit,
    onExportBackup: (Uri) -> Unit,
    onImportBackup: (Uri) -> Unit,
    onHighQualityThresholdChanged: (Double) -> Unit,
    onFilterHorrorContentChanged: (Boolean) -> Unit,
    onSimilarityAlgorithmChanged: (SimilarityAlgorithm) -> Unit,
) {
    val exportLauncher = rememberLauncherForActivityResult(CreateDocument("application/json")) { uri ->
        uri?.let(onExportBackup)
    }
    val importLauncher = rememberLauncherForActivityResult(OpenDocument()) { uri ->
        uri?.let(onImportBackup)
    }
    var trackerService by rememberSaveable { mutableStateOf("AniList") }
    var trackerUsername by rememberSaveable { mutableStateOf("") }
    var trackerToken by rememberSaveable { mutableStateOf("") }
    var selectedSection by rememberSaveable { mutableStateOf<SettingsSection?>(null) }
    val visibleSection = selectedSection

    BackHandler {
        if (visibleSection == null) {
            onClose()
        } else {
            selectedSection = null
        }
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(18.dp),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
    ) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = "Settings",
                        style = MaterialTheme.typography.headlineLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = visibleSection?.label ?: "Eclipse",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                }
                Button(
                    onClick = {
                        if (visibleSection == null) {
                            onClose()
                        } else {
                            selectedSection = null
                        }
                    },
                ) {
                    Text(if (visibleSection == null) "Done" else "Back")
                }
            }
        }

        if (selectedSection == null) {
            item {
                SettingsOverview(
                    state = state,
                    onSelected = { selectedSection = it },
                    onOpenServices = onOpenServices,
                    onShowKanzenChanged = onShowKanzenChanged,
                )
            }
        }

        if (selectedSection == SettingsSection.BASIC) {
            item {
                SectionHeading(
                    title = "Basic",
                    subtitle = "Language, appearance, layout, updates, and app mode.",
                )
            }

        item {
            AppearanceSettingsCard(
                state = state,
                onAccentColorChanged = onAccentColorChanged,
                onTmdbLanguageChanged = onTmdbLanguageChanged,
                onAppearanceChanged = onAppearanceChanged,
            )
        }

        item {
            DisplayOptionsCard(
                state = state,
                onShowScheduleTabChanged = onShowScheduleTabChanged,
                onShowKanzenChanged = onShowKanzenChanged,
                onSeasonMenuChanged = onSeasonMenuChanged,
                onHorizontalEpisodeListChanged = onHorizontalEpisodeListChanged,
                onMediaColumnsPortraitChanged = onMediaColumnsPortraitChanged,
                onMediaColumnsLandscapeChanged = onMediaColumnsLandscapeChanged,
                onOpenServices = onOpenServices,
            )
        }

        }

        if (selectedSection == SettingsSection.UPDATES) {
        item {
            SectionHeading(
                title = "Updates",
                subtitle = "GitHub releases and provider service update checks.",
            )
        }

        item {
            UpdatesCard(
                state = state,
                onAutoUpdateServicesChanged = onAutoUpdateServicesChanged,
                onGitHubReleaseAutoCheckChanged = onGitHubReleaseAutoCheckChanged,
                onCheckGitHubRelease = onCheckGitHubRelease,
            )
        }
        }

        if (selectedSection == SettingsSection.DISCOVERY) {
        item {
            SectionHeading(
                title = "Discovery",
                subtitle = "Service behavior and catalog matching.",
            )
        }

        item {
            SettingToggleCard(
                title = "Auto Mode",
                description = "Let Eclipse choose the best provider order automatically. This may not always be accurate.",
                checked = state.autoModeEnabled,
                onCheckedChange = onAutoModeChanged,
            )
        }

        item {
            SettingToggleCard(
                title = "Filter Horror Content",
                description = "Hide TMDB movies and TV shows tagged with the horror genre from Home and Search rows.",
                checked = state.filterHorrorContent,
                onCheckedChange = onFilterHorrorContentChanged,
            )
        }

        item {
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        text = "High Quality Threshold",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "${(state.highQualityThreshold * 100).toInt()}% match",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                    Slider(
                        value = state.highQualityThreshold.toFloat(),
                        onValueChange = { onHighQualityThresholdChanged(it.toDouble()) },
                        valueRange = 0f..1f,
                    )
                    Text(
                        text = "Auto Mode uses this threshold before starting a resolved direct stream automatically.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.74f),
                    )
                }
            }
        }

        item {
            SimilarityAlgorithmCard(
                selected = state.selectedSimilarityAlgorithm,
                onSelected = onSimilarityAlgorithmChanged,
            )
        }
        }

        if (selectedSection == SettingsSection.PLAYBACK) {
        item {
            SectionHeading(
                title = "Playback",
                subtitle = "Player defaults and next-episode behavior.",
            )
        }

        item {
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(
                        text = "Preferred Player",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    PlayerButtons(
                        selected = state.inAppPlayer,
                        onSelected = onPlayerSelected,
                    )
                }
            }
        }

        item {
            PlayerPreferencesCard(
                state = state,
                onEnableSubtitlesByDefaultChanged = onEnableSubtitlesByDefaultChanged,
                onDefaultSubtitleLanguageChanged = onDefaultSubtitleLanguageChanged,
                onPreferredAnimeAudioLanguageChanged = onPreferredAnimeAudioLanguageChanged,
                onHoldSpeedChanged = onHoldSpeedChanged,
                onExternalPlayerChanged = onExternalPlayerChanged,
                onAlwaysLandscapeChanged = onAlwaysLandscapeChanged,
                onVlcHeaderProxyChanged = onVlcHeaderProxyChanged,
            )
        }

        item {
            SubtitleSettingsCard(
                state = state,
                onSubtitleForegroundColorChanged = onSubtitleForegroundColorChanged,
                onSubtitleStrokeColorChanged = onSubtitleStrokeColorChanged,
                onSubtitleStrokeWidthChanged = onSubtitleStrokeWidthChanged,
                onSubtitleFontSizeChanged = onSubtitleFontSizeChanged,
                onSubtitleVerticalOffsetChanged = onSubtitleVerticalOffsetChanged,
            )
        }

        item {
            SettingToggleCard(
                title = "Next Episode Button",
                description = "Keep the next-episode CTA visible near the end of playback when we have enough context to offer it.",
                checked = state.showNextEpisodeButton,
                onCheckedChange = onShowNextEpisodeChanged,
            )
        }

        item {
            SettingToggleCard(
                title = "AniSkip",
                description = "Fetch anime skip segments from AniSkip when an AniList episode context is available.",
                checked = state.aniSkipEnabled,
                onCheckedChange = onAniSkipEnabledChanged,
            )
        }

        item {
            SettingToggleCard(
                title = "TheIntroDB",
                description = "Fetch skip segments from TheIntroDB for mapped TMDB movies and episodes.",
                checked = state.introDbEnabled,
                onCheckedChange = onIntroDbEnabledChanged,
            )
        }

        item {
            SettingToggleCard(
                title = "Auto Skip Segments",
                description = "Use fetched AniSkip or TheIntroDB segments to skip intros, recaps, outros, and previews automatically.",
                checked = state.aniSkipAutoSkip,
                onCheckedChange = onAniSkipAutoSkipChanged,
            )
        }

        item {
            SettingToggleCard(
                title = "85s Skip Fallback",
                description = "Show a player control that jumps ahead 85 seconds when structured skip data is unavailable.",
                checked = state.skip85sEnabled,
                onCheckedChange = onSkip85sChanged,
            )
        }

        item {
            SettingToggleCard(
                title = "Always Show Skip 85s",
                description = "Keep the 85 second skip button visible even when structured skip segments are available.",
                checked = state.skip85sAlwaysVisible,
                onCheckedChange = onSkip85sAlwaysVisibleChanged,
            )
        }

        item {
            NextEpisodeThresholdCard(
                value = state.nextEpisodeThreshold,
                onValueChange = onNextEpisodeThresholdChanged,
            )
        }
        }

        if (selectedSection == SettingsSection.READER) {
        item {
            SectionHeading(
                title = "Reader",
                subtitle = "Manga and novel reader defaults.",
            )
        }

        item {
            ReaderSettingsCard(
                state = state,
                onReadingModeChanged = onReadingModeChanged,
                onReaderFontSizeChanged = onReaderFontSizeChanged,
                onReaderFontFamilyChanged = onReaderFontFamilyChanged,
                onReaderFontWeightChanged = onReaderFontWeightChanged,
                onReaderColorPresetChanged = onReaderColorPresetChanged,
                onReaderLineSpacingChanged = onReaderLineSpacingChanged,
                onReaderMarginChanged = onReaderMarginChanged,
                onReaderAlignmentChanged = onReaderAlignmentChanged,
                onKanzenAutoUpdateModulesChanged = onKanzenAutoUpdateModulesChanged,
            )
        }
        }

        if (selectedSection == SettingsSection.TRACKERS) {
        item {
            SectionHeading(
                title = "Trackers",
                subtitle = "AniList and Trakt account state.",
            )
        }

        item {
            TrackerSettingsCard(
                state = state,
                service = trackerService,
                username = trackerUsername,
                token = trackerToken,
                onServiceChanged = { trackerService = it },
                onUsernameChanged = { trackerUsername = it },
                onTokenChanged = { trackerToken = it },
                onConnect = {
                    onTrackerManualConnect(trackerService, trackerUsername, trackerToken)
                    trackerToken = ""
                },
                onSyncEnabledChanged = onTrackerSyncEnabledChanged,
                onDisconnect = onTrackerDisconnect,
                onSyncNow = onTrackerSyncNow,
                onAniListImportLibrary = onAniListImportLibrary,
                onAniListImportMangaLibrary = onAniListImportMangaLibrary,
                onAniListSyncMangaProgress = onAniListSyncMangaProgress,
            )
        }
        }

        if (selectedSection == SettingsSection.CATALOGS) {
        item {
            SectionHeading(
                title = "Catalogs",
                subtitle = "Home rows follow the same enabled state and order that Luna stores in backups.",
            )
        }

        items(state.catalogs, key = { it.id }) { catalog ->
            CatalogSettingsCard(
                catalog = catalog,
                canMoveUp = catalog.order > 0,
                canMoveDown = catalog.order < state.catalogs.lastIndex,
                onEnabledChanged = { enabled -> onCatalogEnabledChanged(catalog.id, enabled) },
                onMoveUp = { onMoveCatalogUp(catalog.id) },
                onMoveDown = { onMoveCatalogDown(catalog.id) },
            )
        }
        }

        if (selectedSection == SettingsSection.DATA) {
        item {
            SectionHeading(
                title = "Storage",
                subtitle = "Cache and offline usage diagnostics.",
            )
        }

        item {
            StorageCard(
                state = state,
                metrics = state.storageMetrics,
                status = state.storageStatus,
                onRefresh = onRefreshStorage,
                onClearCache = onClearCache,
                onAutoClearCacheEnabledChanged = onAutoClearCacheEnabledChanged,
                onAutoClearCacheThresholdChanged = onAutoClearCacheThresholdChanged,
            )
        }

        item {
            SectionHeading(
                title = "Logger",
                subtitle = "Persistent diagnostics for player, backup, source, and storage flows.",
            )
        }

        item {
            LoggerCard(
                rows = state.logRows,
                status = state.loggerStatus,
                onRefresh = onRefreshLogs,
                onClear = onClearLogs,
            )
        }

        item {
            SectionHeading(
                title = "Backup",
                subtitle = "Export and restore Luna-compatible JSON archives.",
            )
        }

        item {
            BackupCard(
                state = state,
                onExportClicked = {
                    exportLauncher.launch(defaultBackupFileName())
                },
                onImportClicked = {
                    importLauncher.launch(arrayOf("application/json", "text/plain"))
                },
            )
        }
        }
    }
}

@Composable
private fun SettingsOverview(
    state: SettingsScreenState,
    onSelected: (SettingsSection) -> Unit,
    onOpenServices: () -> Unit,
    onShowKanzenChanged: (Boolean) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        SettingsOverviewGroup(title = "Basic") {
            SettingsMenuRow(
                title = "Language",
                subtitle = state.tmdbLanguage,
                onClick = { onSelected(SettingsSection.BASIC) },
            )
            SettingsMenuRow(
                title = "Content Filters",
                subtitle = if (state.filterHorrorContent) "Horror hidden" else "All enabled",
                onClick = { onSelected(SettingsSection.DISCOVERY) },
            )
            SettingsMenuRow(
                title = "Matching Algorithm",
                subtitle = state.selectedSimilarityAlgorithm.name.lowercase().replaceFirstChar { it.titlecase() },
                onClick = { onSelected(SettingsSection.DISCOVERY) },
            )
            SettingsMenuRow(
                title = "Media Player",
                subtitle = state.inAppPlayer.name.lowercase().replaceFirstChar { it.titlecase() },
                onClick = { onSelected(SettingsSection.PLAYBACK) },
            )
            SettingsMenuRow(
                title = "Appearance",
                subtitle = state.selectedAppearance.replaceFirstChar { it.titlecase() },
                onClick = { onSelected(SettingsSection.BASIC) },
            )
            SettingsMenuRow(
                title = "Catalogs",
                subtitle = "${state.catalogs.count { it.enabled }} enabled",
                onClick = { onSelected(SettingsSection.CATALOGS) },
            )
            SettingsMenuRow(
                title = "Services",
                subtitle = if (state.autoUpdateServicesEnabled) "Auto update on" else "Auto update off",
                onClick = onOpenServices,
            )
            SettingsMenuRow(
                title = "Trackers",
                subtitle = "${state.trackerRows.count { it.isConnected }} connected",
                onClick = { onSelected(SettingsSection.TRACKERS) },
            )
        }

        SettingsOverviewGroup(title = "Data") {
            SettingsMenuRow(
                title = "Storage",
                subtitle = state.storageStatus,
                onClick = { onSelected(SettingsSection.DATA) },
            )
            SettingsMenuRow(
                title = "Backup & Restore",
                subtitle = state.backupStatusHeadline,
                onClick = { onSelected(SettingsSection.DATA) },
            )
            SettingsMenuRow(
                title = "Logger",
                subtitle = state.loggerStatus,
                onClick = { onSelected(SettingsSection.DATA) },
            )
        }

        SettingsOverviewGroup(title = "Others") {
            SettingInlineToggle(
                title = "Switch to Reader Mode",
                checked = state.showKanzen,
                onCheckedChange = onShowKanzenChanged,
            )
            SettingsMenuRow(
                title = "Reader",
                subtitle = ReaderModeLabel(state.readingMode),
                onClick = { onSelected(SettingsSection.READER) },
            )
        }

        SettingsOverviewGroup(title = "Updates") {
            SettingsMenuRow(
                title = "GitHub Releases",
                subtitle = state.githubReleaseStatus,
                onClick = { onSelected(SettingsSection.UPDATES) },
            )
            SettingsMenuRow(
                title = "Service Auto Update",
                subtitle = if (state.autoUpdateServicesEnabled) "Hourly checks enabled" else "Manual checks only",
                onClick = { onSelected(SettingsSection.UPDATES) },
            )
            SettingsStaticRow(
                title = "Version Info",
                subtitle = state.githubReleaseLatestVersion.ifBlank { "No release check yet" },
            )
        }
    }
}

@Composable
private fun SettingsOverviewGroup(
    title: String,
    content: @Composable () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.tertiary,
        )
        GlassPanel {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                content()
            }
        }
    }
}

@Composable
private fun SettingsMenuRow(
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.62f),
            )
        }
        Text(
            text = ">",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.tertiary,
        )
    }
}

@Composable
private fun SettingsStaticRow(
    title: String,
    subtitle: String,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = subtitle,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.62f),
        )
    }
}

@Composable
private fun AppearanceSettingsCard(
    state: SettingsScreenState,
    onAccentColorChanged: (String) -> Unit,
    onTmdbLanguageChanged: (String) -> Unit,
    onAppearanceChanged: (String) -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(
                text = "Appearance",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            OutlinedTextField(
                value = state.accentColor,
                onValueChange = onAccentColorChanged,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Accent Color") },
                singleLine = true,
            )
            OutlinedTextField(
                value = state.tmdbLanguage,
                onValueChange = onTmdbLanguageChanged,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("TMDB Language") },
                singleLine = true,
            )
            OptionButtonGroup(
                title = "Theme",
                selected = state.selectedAppearance,
                options = AppearanceOptions,
                onSelected = onAppearanceChanged,
            )
        }
    }
}

@Composable
private fun DisplayOptionsCard(
    state: SettingsScreenState,
    onShowScheduleTabChanged: (Boolean) -> Unit,
    onShowKanzenChanged: (Boolean) -> Unit,
    onSeasonMenuChanged: (Boolean) -> Unit,
    onHorizontalEpisodeListChanged: (Boolean) -> Unit,
    onMediaColumnsPortraitChanged: (Int) -> Unit,
    onMediaColumnsLandscapeChanged: (Int) -> Unit,
    onOpenServices: () -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(
                text = "Navigation and Layout",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            SettingInlineToggle(
                title = "Show Schedule Tab",
                checked = state.showScheduleTab,
                onCheckedChange = onShowScheduleTabChanged,
            )
            SettingInlineToggle(
                title = "Kanzen Mode",
                checked = state.showKanzen,
                onCheckedChange = onShowKanzenChanged,
            )
            SettingInlineToggle(
                title = "Alternative Season Menu",
                checked = state.seasonMenu,
                onCheckedChange = onSeasonMenuChanged,
            )
            SettingInlineToggle(
                title = "Horizontal Episode List",
                checked = state.horizontalEpisodeList,
                onCheckedChange = onHorizontalEpisodeListChanged,
            )
            ReaderValueSlider(
                title = "Portrait Search Columns",
                valueLabel = state.mediaColumnsPortrait.toString(),
                value = state.mediaColumnsPortrait.toFloat(),
                valueRange = 2f..6f,
                onValueChange = { onMediaColumnsPortraitChanged(it.toInt()) },
            )
            ReaderValueSlider(
                title = "Landscape Search Columns",
                valueLabel = state.mediaColumnsLandscape.toString(),
                value = state.mediaColumnsLandscape.toFloat(),
                valueRange = 3f..8f,
                onValueChange = { onMediaColumnsLandscapeChanged(it.toInt()) },
            )
            OutlinedButton(
                onClick = onOpenServices,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Open Provider Services")
            }
        }
    }
}

@Composable
private fun UpdatesCard(
    state: SettingsScreenState,
    onAutoUpdateServicesChanged: (Boolean) -> Unit,
    onGitHubReleaseAutoCheckChanged: (Boolean) -> Unit,
    onCheckGitHubRelease: () -> Unit,
) {
    val uriHandler = LocalUriHandler.current
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(
                text = "Updates",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            SettingInlineToggle(
                title = "Auto-Update Services",
                checked = state.autoUpdateServicesEnabled,
                onCheckedChange = onAutoUpdateServicesChanged,
            )
            SettingInlineToggle(
                title = "Auto-check GitHub Releases",
                checked = state.githubReleaseAutoCheckEnabled,
                onCheckedChange = onGitHubReleaseAutoCheckChanged,
            )
            Text(
                text = state.githubReleaseStatus,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
            )
            if (state.githubReleaseUpdateAvailable) {
                Text(
                    text = state.githubReleaseLatestVersion.ifBlank { "Update available" },
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.tertiary,
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Button(
                    onClick = onCheckGitHubRelease,
                    enabled = !state.isCheckingGitHubRelease,
                    modifier = Modifier.weight(1f),
                ) {
                    Text(if (state.isCheckingGitHubRelease) "Checking..." else "Check")
                }
                OutlinedButton(
                    onClick = { uriHandler.openUri(state.githubReleaseUrl) },
                    enabled = state.githubReleaseUrl.isNotBlank(),
                    modifier = Modifier.weight(1f),
                ) {
                    Text("Open Release")
                }
            }
        }
    }
}

@Composable
private fun NextEpisodeThresholdCard(
    value: Int,
    onValueChange: (Int) -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                text = "Next Episode Threshold",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "$value% watched",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.tertiary,
            )
            Slider(
                value = value.toFloat(),
                onValueChange = { onValueChange(it.toInt()) },
                valueRange = 70f..98f,
            )
            Text(
                text = "Eclipse uses this threshold to surface next-episode actions during playback.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.74f),
            )
        }
    }
}

@Composable
private fun SimilarityAlgorithmCard(
    selected: SimilarityAlgorithm,
    onSelected: (SimilarityAlgorithm) -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                text = "Matching Algorithm",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            SimilarityAlgorithm.entries.forEach { algorithm ->
                if (algorithm == selected) {
                    Button(
                        onClick = { onSelected(algorithm) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(algorithm.displayName)
                    }
                } else {
                    OutlinedButton(
                        onClick = { onSelected(algorithm) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(algorithm.displayName)
                    }
                }
                Text(
                    text = algorithm.description,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.68f),
                )
            }
        }
    }
}

@Composable
private fun PlayerPreferencesCard(
    state: SettingsScreenState,
    onEnableSubtitlesByDefaultChanged: (Boolean) -> Unit,
    onDefaultSubtitleLanguageChanged: (String) -> Unit,
    onPreferredAnimeAudioLanguageChanged: (String) -> Unit,
    onHoldSpeedChanged: (Double) -> Unit,
    onExternalPlayerChanged: (String) -> Unit,
    onAlwaysLandscapeChanged: (Boolean) -> Unit,
    onVlcHeaderProxyChanged: (Boolean) -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(
                text = "Player Defaults",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            SettingInlineToggle(
                title = "Subtitles On By Default",
                checked = state.enableSubtitlesByDefault,
                onCheckedChange = onEnableSubtitlesByDefaultChanged,
            )
            OutlinedTextField(
                value = state.defaultSubtitleLanguage,
                onValueChange = onDefaultSubtitleLanguageChanged,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Default Subtitle Language") },
                singleLine = true,
            )
            OutlinedTextField(
                value = state.preferredAnimeAudioLanguage,
                onValueChange = onPreferredAnimeAudioLanguageChanged,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Preferred Anime Audio") },
                singleLine = true,
            )
            OutlinedTextField(
                value = state.externalPlayer,
                onValueChange = onExternalPlayerChanged,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("External Player Package") },
                singleLine = true,
            )
            ReaderValueSlider(
                title = "Hold Speed",
                valueLabel = "%.2fx".format(state.holdSpeedPlayer),
                value = state.holdSpeedPlayer.toFloat(),
                valueRange = 1.25f..3.0f,
                onValueChange = { onHoldSpeedChanged(it.toDouble()) },
            )
            SettingInlineToggle(
                title = "Always Landscape",
                checked = state.alwaysLandscape,
                onCheckedChange = onAlwaysLandscapeChanged,
            )
            SettingInlineToggle(
                title = "VLC Header Proxy",
                checked = state.vlcHeaderProxyEnabled,
                onCheckedChange = onVlcHeaderProxyChanged,
            )
        }
    }
}

@Composable
private fun SubtitleSettingsCard(
    state: SettingsScreenState,
    onSubtitleForegroundColorChanged: (String?) -> Unit,
    onSubtitleStrokeColorChanged: (String?) -> Unit,
    onSubtitleStrokeWidthChanged: (Double) -> Unit,
    onSubtitleFontSizeChanged: (Double) -> Unit,
    onSubtitleVerticalOffsetChanged: (Double) -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(
                text = "Subtitle Style",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            OutlinedTextField(
                value = state.subtitleForegroundColor.orEmpty(),
                onValueChange = { onSubtitleForegroundColorChanged(it) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Text Color") },
                singleLine = true,
            )
            OutlinedTextField(
                value = state.subtitleStrokeColor.orEmpty(),
                onValueChange = { onSubtitleStrokeColorChanged(it) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Outline Color") },
                singleLine = true,
            )
            ReaderValueSlider(
                title = "Font Size",
                valueLabel = "${state.subtitleFontSize.toInt()} sp",
                value = state.subtitleFontSize.toFloat(),
                valueRange = 16f..54f,
                onValueChange = { onSubtitleFontSizeChanged(it.toDouble()) },
            )
            ReaderValueSlider(
                title = "Outline Width",
                valueLabel = "%.1f".format(state.subtitleStrokeWidth),
                value = state.subtitleStrokeWidth.toFloat(),
                valueRange = 0f..8f,
                onValueChange = { onSubtitleStrokeWidthChanged(it.toDouble()) },
            )
            ReaderValueSlider(
                title = "Vertical Offset",
                valueLabel = "%.0f".format(state.subtitleVerticalOffset),
                value = state.subtitleVerticalOffset.toFloat(),
                valueRange = -20f..20f,
                onValueChange = { onSubtitleVerticalOffsetChanged(it.toDouble()) },
            )
        }
    }
}

@Composable
private fun ReaderSettingsCard(
    state: SettingsScreenState,
    onReadingModeChanged: (Int) -> Unit,
    onReaderFontSizeChanged: (Double) -> Unit,
    onReaderFontFamilyChanged: (String) -> Unit,
    onReaderFontWeightChanged: (String) -> Unit,
    onReaderColorPresetChanged: (Int) -> Unit,
    onReaderLineSpacingChanged: (Double) -> Unit,
    onReaderMarginChanged: (Double) -> Unit,
    onReaderAlignmentChanged: (String) -> Unit,
    onKanzenAutoUpdateModulesChanged: (Boolean) -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(
                text = "Reading Mode",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            ReaderModeButtons(
                selected = state.readingMode,
                onSelected = onReadingModeChanged,
            )
            ReaderValueSlider(
                title = "Font Size",
                valueLabel = "${state.readerFontSize.toInt()} pt",
                value = state.readerFontSize.toFloat(),
                valueRange = 12f..32f,
                onValueChange = { onReaderFontSizeChanged(it.toDouble()) },
            )
            ReaderOptionButtons(
                title = "Font Family",
                selected = state.readerFontFamily,
                options = ReaderFontFamilies,
                onSelected = onReaderFontFamilyChanged,
            )
            ReaderOptionButtons(
                title = "Font Weight",
                selected = state.readerFontWeight,
                options = ReaderFontWeights,
                onSelected = onReaderFontWeightChanged,
            )
            ReaderColorPresetButtons(
                selected = state.readerColorPreset,
                onSelected = onReaderColorPresetChanged,
            )
            ReaderValueSlider(
                title = "Line Spacing",
                valueLabel = "%.1fx".format(state.readerLineSpacing),
                value = state.readerLineSpacing.toFloat(),
                valueRange = 1.0f..2.4f,
                onValueChange = { onReaderLineSpacingChanged(it.toDouble()) },
            )
            ReaderValueSlider(
                title = "Margin",
                valueLabel = "${state.readerMargin.toInt()}",
                value = state.readerMargin.toFloat(),
                valueRange = 0f..12f,
                onValueChange = { onReaderMarginChanged(it.toDouble()) },
            )
            Text(
                text = "Text Alignment",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            ReaderAlignmentButtons(
                selected = state.readerTextAlignment,
                onSelected = onReaderAlignmentChanged,
            )
            SettingInlineToggle(
                title = "Auto-Update Kanzen Modules",
                checked = state.kanzenAutoUpdateModules,
                onCheckedChange = onKanzenAutoUpdateModulesChanged,
            )
        }
    }
}

@Composable
private fun TrackerSettingsCard(
    state: SettingsScreenState,
    service: String,
    username: String,
    token: String,
    onServiceChanged: (String) -> Unit,
    onUsernameChanged: (String) -> Unit,
    onTokenChanged: (String) -> Unit,
    onConnect: () -> Unit,
    onSyncEnabledChanged: (Boolean) -> Unit,
    onDisconnect: (String) -> Unit,
    onSyncNow: () -> Unit,
    onAniListImportLibrary: () -> Unit,
    onAniListImportMangaLibrary: () -> Unit,
    onAniListSyncMangaProgress: () -> Unit,
) {
    val hasAniListAccount = state.trackerRows.any { row ->
        row.isConnected && row.service.equals("AniList", ignoreCase = true)
    }
    val uriHandler = LocalUriHandler.current
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = "Sync Progress",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = state.trackerStatus,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.76f),
                    )
                }
                Switch(
                    checked = state.trackerSyncEnabled,
                    onCheckedChange = onSyncEnabledChanged,
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Button(
                    onClick = { uriHandler.openUri(state.aniListOAuthUrl) },
                    enabled = state.aniListOAuthUrl.isNotBlank(),
                    modifier = Modifier.weight(1f),
                ) {
                    Text("Connect AniList")
                }
                OutlinedButton(
                    onClick = { uriHandler.openUri(state.traktOAuthUrl) },
                    enabled = state.traktOAuthUrl.isNotBlank(),
                    modifier = Modifier.weight(1f),
                ) {
                    Text("Connect Trakt")
                }
            }

            OutlinedTextField(
                value = service,
                onValueChange = onServiceChanged,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Provider") },
                singleLine = true,
            )
            OutlinedTextField(
                value = username,
                onValueChange = onUsernameChanged,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Username") },
                singleLine = true,
            )
            OutlinedTextField(
                value = token,
                onValueChange = onTokenChanged,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Token or PIN") },
                singleLine = true,
            )
            Button(
                onClick = onConnect,
                enabled = service.isNotBlank() && token.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Save Tracker")
            }
            OutlinedButton(
                onClick = onSyncNow,
                enabled = state.trackerSyncEnabled && state.trackerRows.isNotEmpty(),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Sync Now")
            }
            OutlinedButton(
                onClick = onAniListImportLibrary,
                enabled = hasAniListAccount,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Import AniList Anime Library")
            }
            OutlinedButton(
                onClick = onAniListImportMangaLibrary,
                enabled = hasAniListAccount,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Import AniList Manga Library")
            }
            OutlinedButton(
                onClick = onAniListSyncMangaProgress,
                enabled = hasAniListAccount,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Sync Manga Progress")
            }

            state.trackerRows.forEach { row ->
                TrackerAccountRow(
                    row = row,
                    onDisconnect = { onDisconnect(row.service) },
                )
            }
        }
    }
}

@Composable
private fun TrackerAccountRow(
    row: TrackerSettingsRow,
    onDisconnect: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    text = row.service,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = listOf(
                        row.username.ifBlank { "No username" },
                        row.tokenPreview,
                        if (row.isConnected) "Connected" else "Disconnected",
                    ).joinToString(" - "),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.tertiary,
                )
            }
            OutlinedButton(onClick = onDisconnect) {
                Text("Disconnect")
            }
        }
    }
}

private fun ReaderModeLabel(mode: Int): String = when (mode) {
    0 -> "Paged"
    1 -> "Webtoon"
    2 -> "Auto"
    else -> "Mode $mode"
}

@Composable
private fun ReaderModeButtons(
    selected: Int,
    onSelected: (Int) -> Unit,
) {
    val modes = listOf(
        0 to "Paged",
        1 to "Webtoon",
        2 to "Auto",
    )
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        modes.forEach { (mode, label) ->
            if (mode == selected) {
                Button(
                    onClick = { onSelected(mode) },
                    modifier = Modifier.weight(1f),
                ) {
                    Text(label)
                }
            } else {
                OutlinedButton(
                    onClick = { onSelected(mode) },
                    modifier = Modifier.weight(1f),
                ) {
                    Text(label)
                }
            }
        }
    }
}

@Composable
private fun OptionButtonGroup(
    title: String,
    selected: String,
    options: List<Pair<String, String>>,
    onSelected: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            options.forEach { (value, label) ->
                if (value.equals(selected, ignoreCase = true)) {
                    Button(
                        onClick = { onSelected(value) },
                        modifier = Modifier.weight(1f),
                    ) {
                        Text(label)
                    }
                } else {
                    OutlinedButton(
                        onClick = { onSelected(value) },
                        modifier = Modifier.weight(1f),
                    ) {
                        Text(label)
                    }
                }
            }
        }
    }
}

@Composable
private fun ReaderOptionButtons(
    title: String,
    selected: String,
    options: List<Pair<String, String>>,
    onSelected: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface,
        )
        options.chunked(3).forEach { chunk ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                chunk.forEach { (value, label) ->
                    if (value.equals(selected, ignoreCase = true)) {
                        Button(
                            onClick = { onSelected(value) },
                            modifier = Modifier.weight(1f),
                        ) {
                            Text(label)
                        }
                    } else {
                        OutlinedButton(
                            onClick = { onSelected(value) },
                            modifier = Modifier.weight(1f),
                        ) {
                            Text(label)
                        }
                    }
                }
                repeat(3 - chunk.size) {
                    Column(modifier = Modifier.weight(1f)) {}
                }
            }
        }
    }
}

@Composable
private fun ReaderColorPresetButtons(
    selected: Int,
    onSelected: (Int) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = "Reader Color Theme",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            ReaderColorPresets.chunked(3).forEachIndexed { chunkIndex, chunk ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    chunk.forEachIndexed { indexInChunk, label ->
                        val index = chunkIndex * 3 + indexInChunk
                        if (index == selected) {
                            Button(
                                onClick = { onSelected(index) },
                                modifier = Modifier.weight(1f),
                            ) {
                                Text(label)
                            }
                        } else {
                            OutlinedButton(
                                onClick = { onSelected(index) },
                                modifier = Modifier.weight(1f),
                            ) {
                                Text(label)
                            }
                        }
                    }
                    repeat(3 - chunk.size) {
                        Column(modifier = Modifier.weight(1f)) {}
                    }
                }
            }
        }
    }
}

@Composable
private fun ReaderAlignmentButtons(
    selected: String,
    onSelected: (String) -> Unit,
) {
    val values = listOf("left", "center", "right", "justify")
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        values.forEach { value ->
            val label = value.replaceFirstChar { it.uppercase() }
            if (value == selected) {
                Button(
                    onClick = { onSelected(value) },
                    modifier = Modifier.weight(1f),
                ) {
                    Text(label)
                }
            } else {
                OutlinedButton(
                    onClick = { onSelected(value) },
                    modifier = Modifier.weight(1f),
                ) {
                    Text(label)
                }
            }
        }
    }
}

@Composable
private fun ReaderValueSlider(
    title: String,
    valueLabel: String,
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    onValueChange: (Float) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = valueLabel,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.tertiary,
            )
        }
        Slider(
            value = value,
            onValueChange = onValueChange,
            valueRange = valueRange,
        )
    }
}

@Composable
private fun StorageCard(
    state: SettingsScreenState,
    metrics: List<StorageMetricRow>,
    status: String,
    onRefresh: () -> Unit,
    onClearCache: () -> Unit,
    onAutoClearCacheEnabledChanged: (Boolean) -> Unit,
    onAutoClearCacheThresholdChanged: (Double) -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SettingInlineToggle(
                title = "Auto Clear Cache",
                checked = state.autoClearCacheEnabled,
                onCheckedChange = onAutoClearCacheEnabledChanged,
            )
            ReaderValueSlider(
                title = "Cache Limit",
                valueLabel = "${state.autoClearCacheThresholdMB.toInt()} MB",
                value = state.autoClearCacheThresholdMB.toFloat(),
                valueRange = 50f..5_000f,
                onValueChange = { onAutoClearCacheThresholdChanged(it.toDouble()) },
            )
            Text(
                text = status,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
            )
            metrics.forEach { metric ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        text = metric.label,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = metric.value,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Button(
                    onClick = onRefresh,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("Refresh")
                }
                OutlinedButton(
                    onClick = onClearCache,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("Clear Cache")
                }
            }
        }
    }
}

@Composable
private fun LoggerCard(
    rows: List<LogSettingsRow>,
    status: String,
    onRefresh: () -> Unit,
    onClear: () -> Unit,
) {
    val context = LocalContext.current
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                text = status,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
            )
            rows.forEach { row ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = "${row.timestamp} | ${row.tag} | ${row.level}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                    Text(
                        text = row.message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Button(
                    onClick = onRefresh,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("Refresh")
                }
                OutlinedButton(
                    onClick = onClear,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("Clear Logs")
                }
            }
            OutlinedButton(
                onClick = {
                    val shareIntent = Intent(Intent.ACTION_SEND)
                        .setType("text/plain")
                        .putExtra(Intent.EXTRA_SUBJECT, "Eclipse logs")
                        .putExtra(Intent.EXTRA_TEXT, rows.toShareText(status))
                    context.startActivity(Intent.createChooser(shareIntent, "Share Logs"))
                },
                enabled = rows.isNotEmpty(),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Share Logs")
            }
        }
    }
}

private fun List<LogSettingsRow>.toShareText(status: String): String =
    buildString {
        appendLine("Eclipse Logs")
        appendLine(status)
        appendLine()
        this@toShareText.forEach { row ->
            append(row.timestamp)
            append(" | ")
            append(row.tag)
            append(" | ")
            append(row.level)
            append(" | ")
            appendLine(row.message)
        }
    }

@Composable
private fun CatalogSettingsCard(
    catalog: CatalogSettingsRow,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    onEnabledChanged: (Boolean) -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = catalog.name,
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "${catalog.source} | ${catalog.displayStyle}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                }
                Switch(
                    checked = catalog.enabled,
                    onCheckedChange = onEnabledChanged,
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedButton(
                    onClick = onMoveUp,
                    enabled = canMoveUp,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("Move Up")
                }
                OutlinedButton(
                    onClick = onMoveDown,
                    enabled = canMoveDown,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("Move Down")
                }
            }
        }
    }
}

@Composable
private fun SettingToggleCard(
    title: String,
    description: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    GlassPanel {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = description,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.75f),
                )
            }
            Switch(
                checked = checked,
                onCheckedChange = onCheckedChange,
            )
        }
    }
}

@Composable
private fun SettingInlineToggle(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
        )
    }
}

@Composable
private fun PlayerButtons(
    selected: InAppPlayer,
    onSelected: (InAppPlayer) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        PlayerButtonRow(
            left = InAppPlayer.NORMAL,
            right = InAppPlayer.VLC,
            selected = selected,
            onSelected = onSelected,
        )
        PlayerButtonRow(
            left = InAppPlayer.EXTERNAL,
            right = null,
            selected = selected,
            onSelected = onSelected,
        )
    }
}

@Composable
private fun PlayerButtonRow(
    left: InAppPlayer,
    right: InAppPlayer?,
    selected: InAppPlayer,
    onSelected: (InAppPlayer) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        PlayerChoiceButton(
            player = left,
            selected = left == selected || selected == InAppPlayer.MPV && left == InAppPlayer.EXTERNAL,
            onSelected = onSelected,
            modifier = Modifier.weight(1f),
        )
        if (right != null) {
            PlayerChoiceButton(
                player = right,
                selected = right == selected,
                onSelected = onSelected,
                modifier = Modifier.weight(1f),
            )
        } else {
            Column(modifier = Modifier.weight(1f)) {}
        }
    }
}

@Composable
private fun PlayerChoiceButton(
    player: InAppPlayer,
    selected: Boolean,
    onSelected: (InAppPlayer) -> Unit,
    modifier: Modifier = Modifier,
) {
    val label = when (player) {
        InAppPlayer.NORMAL -> "Normal"
        InAppPlayer.VLC -> "VLC"
        InAppPlayer.MPV -> "External"
        InAppPlayer.EXTERNAL -> "External"
    }

    if (selected) {
        Button(
            onClick = { onSelected(player) },
            modifier = modifier,
        ) {
            Text(label)
        }
    } else {
        OutlinedButton(
            onClick = { onSelected(player) },
            modifier = modifier,
        ) {
            Text(label)
        }
    }
}

@Composable
private fun BackupCard(
    state: SettingsScreenState,
    onExportClicked: () -> Unit,
    onImportClicked: () -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                text = state.backupStatusHeadline,
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = state.backupStatusMessage,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.76f),
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Button(
                    onClick = onExportClicked,
                    enabled = !state.isBackupBusy,
                    modifier = Modifier.weight(1f),
                ) {
                    Text(if (state.isBackupBusy) "Working..." else "Export Backup")
                }
                OutlinedButton(
                    onClick = onImportClicked,
                    enabled = !state.isBackupBusy,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("Import Backup")
                }
            }
            Text(
                text = if (state.hasLocalBackup) {
                    "Eclipse keeps a staged local copy so later exports preserve every section."
                } else {
                    "Once you export or import here, Eclipse will keep a staged local copy for later re-exports."
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.tertiary,
            )
        }
    }
}

private fun defaultBackupFileName(): String = buildString {
    append("eclipse-backup-")
    append(LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss")))
    append(".json")
}
