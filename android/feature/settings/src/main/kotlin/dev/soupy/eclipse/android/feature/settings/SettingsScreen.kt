package dev.soupy.eclipse.android.feature.settings

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts.CreateDocument
import androidx.activity.result.contract.ActivityResultContracts.OpenDocument
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
import androidx.compose.ui.unit.dp
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.design.HeroBackdrop
import dev.soupy.eclipse.android.core.design.SectionHeading
import dev.soupy.eclipse.android.core.model.InAppPlayer
import dev.soupy.eclipse.android.core.model.SimilarityAlgorithm
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

data class SettingsScreenState(
    val accentColor: String = "#6D8CFF",
    val tmdbLanguage: String = "en-US",
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
    val aniSkipAutoSkip: Boolean = false,
    val skip85sEnabled: Boolean = false,
    val readingMode: Int = 2,
    val readerFontSize: Double = 16.0,
    val readerLineSpacing: Double = 1.6,
    val readerMargin: Double = 4.0,
    val readerTextAlignment: String = "left",
    val isBackupBusy: Boolean = false,
    val hasLocalBackup: Boolean = false,
    val backupStatusHeadline: String = "No local backup yet",
    val backupStatusMessage: String = "Export a JSON archive from Android Settings or import an existing Luna backup to stage one here.",
    val catalogs: List<CatalogSettingsRow> = emptyList(),
    val storageMetrics: List<StorageMetricRow> = emptyList(),
    val storageStatus: String = "Storage has not been measured yet.",
    val autoClearCacheEnabled: Boolean = false,
    val autoClearCacheThresholdMB: Double = 500.0,
    val logRows: List<LogSettingsRow> = emptyList(),
    val loggerStatus: String = "No Android logs captured yet.",
    val trackerSyncEnabled: Boolean = true,
    val trackerRows: List<TrackerSettingsRow> = emptyList(),
    val trackerStatus: String = "No tracker accounts connected yet.",
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

@Composable
fun SettingsRoute(
    state: SettingsScreenState,
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
    onAniSkipAutoSkipChanged: (Boolean) -> Unit,
    onSkip85sChanged: (Boolean) -> Unit,
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
    onReaderLineSpacingChanged: (Double) -> Unit,
    onReaderMarginChanged: (Double) -> Unit,
    onReaderAlignmentChanged: (String) -> Unit,
    onTrackerManualConnect: (String, String, String) -> Unit,
    onTrackerSyncEnabledChanged: (Boolean) -> Unit,
    onTrackerDisconnect: (String) -> Unit,
    onTrackerSyncNow: () -> Unit,
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

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(18.dp),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
    ) {
        item {
            HeroBackdrop(
                title = "Settings",
                subtitle = "Playback and discovery",
                imageUrl = null,
                supportingText = "Android settings are now backed by DataStore. The auto mode warning is explicit here too: it may not always be accurate.",
            )
        }

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
                        text = "Auto Mode uses this backed threshold before starting a resolved direct stream automatically.",
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

        item {
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        text = "Metadata Language",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = state.tmdbLanguage,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                    Text(
                        text = "This is already flowing from persisted settings, even before the full Android service stack lands.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.74f),
                    )
                }
            }
        }

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
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        text = "Next Episode Threshold",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "${state.nextEpisodeThreshold}% watched",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                    Slider(
                        value = state.nextEpisodeThreshold.toFloat(),
                        onValueChange = { onNextEpisodeThresholdChanged(it.toInt()) },
                        valueRange = 70f..98f,
                    )
                    Text(
                        text = "When playback reporting is connected, Android will use this same threshold to decide when to surface next-episode actions.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.74f),
                    )
                }
            }
        }

        item {
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        text = "Appearance Snapshot",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "Accent ${state.accentColor}",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                    Text(
                        text = "The Android design system is already reading the same class of persisted appearance values we'll need for closer Luna parity.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.74f),
                    )
                }
            }
        }

        item {
            SectionHeading(
                title = "Reader",
                subtitle = "Manga and novel reader defaults restored from Luna backups and persisted on Android.",
            )
        }

        item {
            ReaderSettingsCard(
                state = state,
                onReadingModeChanged = onReadingModeChanged,
                onReaderFontSizeChanged = onReaderFontSizeChanged,
                onReaderLineSpacingChanged = onReaderLineSpacingChanged,
                onReaderMarginChanged = onReaderMarginChanged,
                onReaderAlignmentChanged = onReaderAlignmentChanged,
            )
        }

        item {
            SectionHeading(
                title = "Trackers",
                subtitle = "AniList and Trakt account state restored from backups and persisted on Android.",
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
            )
        }

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

        item {
            SectionHeading(
                title = "Storage",
                subtitle = "Cache and offline usage diagnostics backed by Android app storage.",
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
                subtitle = "Export and restore Luna-compatible JSON archives. Android restores the settings and source state it owns today while preserving the rest for later parity.",
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
    onReaderLineSpacingChanged: (Double) -> Unit,
    onReaderMarginChanged: (Double) -> Unit,
    onReaderAlignmentChanged: (String) -> Unit,
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
) {
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
private fun ReaderAlignmentButtons(
    selected: String,
    onSelected: (String) -> Unit,
) {
    val values = listOf("left", "center", "justify")
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
        }
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
            left = InAppPlayer.MPV,
            right = InAppPlayer.EXTERNAL,
            selected = selected,
            onSelected = onSelected,
        )
    }
}

@Composable
private fun PlayerButtonRow(
    left: InAppPlayer,
    right: InAppPlayer,
    selected: InAppPlayer,
    onSelected: (InAppPlayer) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        PlayerChoiceButton(
            player = left,
            selected = left == selected,
            onSelected = onSelected,
            modifier = Modifier.weight(1f),
        )
        PlayerChoiceButton(
            player = right,
            selected = right == selected,
            onSelected = onSelected,
            modifier = Modifier.weight(1f),
        )
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
        InAppPlayer.MPV -> "mpv"
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
                    "Android also keeps a staged local copy of the archive so later exports can preserve sections that still don't have full UI/runtime parity."
                } else {
                    "Once you export or import here, Android will keep a staged local copy so unsupported backup sections survive later re-exports."
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
