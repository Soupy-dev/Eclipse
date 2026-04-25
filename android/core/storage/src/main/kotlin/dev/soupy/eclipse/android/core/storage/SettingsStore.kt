package dev.soupy.eclipse.android.core.storage

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dev.soupy.eclipse.android.core.model.BackupData
import dev.soupy.eclipse.android.core.model.InAppPlayer
import dev.soupy.eclipse.android.core.model.SimilarityAlgorithm
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private const val SettingsFileName = "eclipse_settings"

private val Context.dataStore by preferencesDataStore(name = SettingsFileName)

data class AppSettings(
    val accentColor: String = "#6D8CFF",
    val tmdbLanguage: String = "en-US",
    val selectedAppearance: String = "system",
    val enableSubtitlesByDefault: Boolean = false,
    val defaultSubtitleLanguage: String = "eng",
    val enableVLCSubtitleEditMenu: Boolean = false,
    val preferredAnimeAudioLanguage: String = "jpn",
    val inAppPlayer: InAppPlayer = InAppPlayer.NORMAL,
    val autoModeEnabled: Boolean = true,
    val autoModeSourceIds: Set<String> = emptySet(),
    val showScheduleTab: Boolean = true,
    val showLocalScheduleTime: Boolean = true,
    val holdSpeedPlayer: Double = 2.0,
    val externalPlayer: String = "none",
    val alwaysLandscape: Boolean = false,
    val aniSkipEnabled: Boolean = true,
    val introDbEnabled: Boolean = true,
    val aniSkipAutoSkip: Boolean = false,
    val skip85sEnabled: Boolean = false,
    val skip85sAlwaysVisible: Boolean = false,
    val showNextEpisodeButton: Boolean = true,
    val nextEpisodeThreshold: Int = 90,
    val vlcHeaderProxyEnabled: Boolean = true,
    val subtitleForegroundColor: String? = null,
    val subtitleStrokeColor: String? = null,
    val subtitleStrokeWidth: Double = 1.0,
    val subtitleFontSize: Double = 30.0,
    val subtitleVerticalOffset: Double = -6.0,
    val showKanzen: Boolean = false,
    val kanzenAutoMode: Boolean = false,
    val kanzenAutoUpdateModules: Boolean = true,
    val autoUpdateServicesEnabled: Boolean = true,
    val lastServiceAutoUpdateTimestamp: Long = 0L,
    val githubReleaseAutoCheckEnabled: Boolean = true,
    val githubReleaseLastCheckTimestamp: Long = 0L,
    val githubReleaseUpdateAvailable: Boolean = false,
    val githubReleaseLatestVersion: String = "",
    val githubReleaseUrl: String = "",
    val githubReleaseShowAlertPending: Boolean = false,
    val githubReleaseLastPromptedVersion: String = "",
    val seasonMenu: Boolean = false,
    val horizontalEpisodeList: Boolean = false,
    val mediaColumnsPortrait: Int = 3,
    val mediaColumnsLandscape: Int = 5,
    val readingMode: Int = 2,
    val readerFontSize: Double = 16.0,
    val readerFontFamily: String = "-apple-system",
    val readerFontWeight: String = "normal",
    val readerColorPreset: Int = 0,
    val readerTextAlignment: String = "left",
    val readerLineSpacing: Double = 1.6,
    val readerMargin: Double = 4.0,
    val autoClearCacheEnabled: Boolean = false,
    val autoClearCacheThresholdMB: Double = 500.0,
    val highQualityThreshold: Double = 0.9,
    val filterHorrorContent: Boolean = false,
    val selectedSimilarityAlgorithm: SimilarityAlgorithm = SimilarityAlgorithm.HYBRID,
)

class SettingsStore(
    private val context: Context,
) {
    val settings: Flow<AppSettings> = context.dataStore.data.map(::toAppSettings)

    suspend fun updateAppearance(
        accentColor: String,
        tmdbLanguage: String,
        selectedAppearance: String,
    ) {
        context.dataStore.edit { prefs ->
            prefs[Keys.accentColor] = accentColor.trim().ifBlank { "#6D8CFF" }
            prefs[Keys.tmdbLanguage] = tmdbLanguage.trim().ifBlank { "en-US" }
            prefs[Keys.selectedAppearance] = selectedAppearance.normalizedAppearance()
        }
    }

    suspend fun updatePlayback(
        inAppPlayer: InAppPlayer,
        showNextEpisodeButton: Boolean,
        nextEpisodeThreshold: Int,
    ) {
        context.dataStore.edit { prefs ->
            prefs[Keys.inAppPlayer] = inAppPlayer.name
            prefs[Keys.showNextEpisodeButton] = showNextEpisodeButton
            prefs[Keys.nextEpisodeThreshold] = nextEpisodeThreshold.coerceIn(70, 98)
        }
    }

    suspend fun updateSkipBehavior(
        aniSkipEnabled: Boolean,
        introDbEnabled: Boolean,
        aniSkipAutoSkip: Boolean,
        skip85sEnabled: Boolean,
        skip85sAlwaysVisible: Boolean,
    ) {
        context.dataStore.edit { prefs ->
            prefs[Keys.aniSkipEnabled] = aniSkipEnabled
            prefs[Keys.introDbEnabled] = introDbEnabled
            prefs[Keys.aniSkipAutoSkip] = aniSkipAutoSkip
            prefs[Keys.skip85sEnabled] = skip85sEnabled
            prefs[Keys.skip85sAlwaysVisible] = skip85sAlwaysVisible
        }
    }

    suspend fun updatePlayerPreferences(
        enableSubtitlesByDefault: Boolean,
        defaultSubtitleLanguage: String,
        preferredAnimeAudioLanguage: String,
        holdSpeedPlayer: Double,
        externalPlayer: String,
        alwaysLandscape: Boolean,
        vlcHeaderProxyEnabled: Boolean,
    ) {
        context.dataStore.edit { prefs ->
            prefs[Keys.enableSubtitlesByDefault] = enableSubtitlesByDefault
            prefs[Keys.defaultSubtitleLanguage] = defaultSubtitleLanguage.normalizedLanguageCode("eng")
            prefs[Keys.preferredAnimeAudioLanguage] = preferredAnimeAudioLanguage.normalizedLanguageCode("jpn")
            prefs[Keys.holdSpeedPlayer] = holdSpeedPlayer.coerceIn(1.25, 3.0)
            prefs[Keys.externalPlayer] = externalPlayer.trim().ifBlank { "none" }
            prefs[Keys.alwaysLandscape] = alwaysLandscape
            prefs[Keys.vlcHeaderProxyEnabled] = vlcHeaderProxyEnabled
        }
    }

    suspend fun updateSubtitleStyle(
        foregroundColor: String?,
        strokeColor: String?,
        strokeWidth: Double,
        fontSize: Double,
        verticalOffset: Double,
    ) {
        context.dataStore.edit { prefs ->
            foregroundColor.normalizedOptionalColor()?.let { value ->
                prefs[Keys.subtitleForegroundColor] = value
            } ?: prefs.remove(Keys.subtitleForegroundColor)
            strokeColor.normalizedOptionalColor()?.let { value ->
                prefs[Keys.subtitleStrokeColor] = value
            } ?: prefs.remove(Keys.subtitleStrokeColor)
            prefs[Keys.subtitleStrokeWidth] = strokeWidth.coerceIn(0.0, 8.0)
            prefs[Keys.subtitleFontSize] = fontSize.coerceIn(16.0, 54.0)
            prefs[Keys.subtitleVerticalOffset] = verticalOffset.coerceIn(-20.0, 20.0)
        }
    }

    suspend fun updateReader(
        readingMode: Int,
        readerFontSize: Double,
        readerFontFamily: String,
        readerFontWeight: String,
        readerColorPreset: Int,
        readerLineSpacing: Double,
        readerMargin: Double,
        readerTextAlignment: String,
    ) {
        context.dataStore.edit { prefs ->
            prefs[Keys.readingMode] = readingMode.coerceIn(0, 3)
            prefs[Keys.readerFontSize] = readerFontSize.coerceIn(12.0, 32.0)
            prefs[Keys.readerFontFamily] = readerFontFamily.trim().ifBlank { "-apple-system" }
            prefs[Keys.readerFontWeight] = readerFontWeight.trim().ifBlank { "normal" }
            prefs[Keys.readerColorPreset] = readerColorPreset.coerceIn(0, 4)
            prefs[Keys.readerLineSpacing] = readerLineSpacing.coerceIn(1.0, 2.4)
            prefs[Keys.readerMargin] = readerMargin.coerceIn(0.0, 12.0)
            prefs[Keys.readerTextAlignment] = readerTextAlignment.normalizedTextAlignment()
        }
    }

    suspend fun updateNavigation(
        showScheduleTab: Boolean,
        showKanzen: Boolean,
    ) {
        context.dataStore.edit { prefs ->
            prefs[Keys.showScheduleTab] = showScheduleTab
            prefs[Keys.showKanzen] = showKanzen
        }
    }

    suspend fun updateDisplayOptions(
        seasonMenu: Boolean,
        horizontalEpisodeList: Boolean,
    ) {
        context.dataStore.edit { prefs ->
            prefs[Keys.seasonMenu] = seasonMenu
            prefs[Keys.horizontalEpisodeList] = horizontalEpisodeList
        }
    }

    suspend fun updateMediaColumns(
        portrait: Int,
        landscape: Int,
    ) {
        context.dataStore.edit { prefs ->
            prefs[Keys.mediaColumnsPortrait] = portrait.coerceIn(2, 6)
            prefs[Keys.mediaColumnsLandscape] = landscape.coerceIn(3, 8)
        }
    }

    suspend fun setKanzenAutoUpdateModules(enabled: Boolean) {
        context.dataStore.edit { prefs ->
            prefs[Keys.kanzenAutoUpdateModules] = enabled
        }
    }

    suspend fun setAutoUpdateServicesEnabled(enabled: Boolean) {
        context.dataStore.edit { prefs ->
            prefs[Keys.autoUpdateServicesEnabled] = enabled
        }
    }

    suspend fun markServiceAutoUpdateChecked(timestampMillis: Long = System.currentTimeMillis()) {
        context.dataStore.edit { prefs ->
            prefs[Keys.lastServiceAutoUpdateTimestamp] = timestampMillis
        }
    }

    suspend fun setGitHubReleaseAutoCheckEnabled(enabled: Boolean) {
        context.dataStore.edit { prefs ->
            prefs[Keys.githubReleaseAutoCheckEnabled] = enabled
        }
    }

    suspend fun saveGitHubReleaseCheck(
        latestVersion: String,
        releaseUrl: String,
        updateAvailable: Boolean,
        prompt: Boolean,
        checkedAtMillis: Long = System.currentTimeMillis(),
    ) {
        context.dataStore.edit { prefs ->
            prefs[Keys.githubReleaseLastCheckTimestamp] = checkedAtMillis
            prefs[Keys.githubReleaseLatestVersion] = latestVersion
            prefs[Keys.githubReleaseUrl] = releaseUrl
            prefs[Keys.githubReleaseUpdateAvailable] = updateAvailable
            prefs[Keys.githubReleaseShowAlertPending] = prompt
        }
    }

    suspend fun consumeGitHubReleasePrompt() {
        context.dataStore.edit { prefs ->
            val latestVersion = prefs[Keys.githubReleaseLatestVersion].orEmpty()
            prefs[Keys.githubReleaseShowAlertPending] = false
            if (latestVersion.isNotBlank()) {
                prefs[Keys.githubReleaseLastPromptedVersion] = latestVersion
            }
        }
    }

    suspend fun setAutoModeEnabled(enabled: Boolean) {
        context.dataStore.edit { prefs ->
            prefs[Keys.autoModeEnabled] = enabled
        }
    }

    suspend fun setHighQualityThreshold(threshold: Double) {
        context.dataStore.edit { prefs ->
            prefs[Keys.highQualityThreshold] = threshold.coerceIn(0.0, 1.0)
        }
    }

    suspend fun setFilterHorrorContent(enabled: Boolean) {
        context.dataStore.edit { prefs ->
            prefs[Keys.filterHorrorContent] = enabled
        }
    }

    suspend fun setSimilarityAlgorithm(algorithm: SimilarityAlgorithm) {
        context.dataStore.edit { prefs ->
            prefs[Keys.selectedSimilarityAlgorithm] = algorithm.id
        }
    }

    suspend fun updateAutoClearCache(
        enabled: Boolean,
        thresholdMB: Double,
    ) {
        context.dataStore.edit { prefs ->
            prefs[Keys.autoClearCacheEnabled] = enabled
            prefs[Keys.autoClearCacheThresholdMB] = thresholdMB.coerceIn(50.0, 5_000.0)
        }
    }

    suspend fun setAutoModeSourceEnabled(sourceId: String, enabled: Boolean) {
        context.dataStore.edit { prefs ->
            val current = prefs[Keys.autoModeSourceIds] ?: emptySet()
            prefs[Keys.autoModeSourceIds] = if (enabled) {
                current + sourceId
            } else {
                current - sourceId
            }
        }
    }

    suspend fun removeAutoModeSource(sourceId: String) {
        context.dataStore.edit { prefs ->
            val current = prefs[Keys.autoModeSourceIds] ?: emptySet()
            prefs[Keys.autoModeSourceIds] = current - sourceId
        }
    }

    suspend fun retainAutoModeSources(allowedSourceIds: Set<String>) {
        context.dataStore.edit { prefs ->
            val current = prefs[Keys.autoModeSourceIds] ?: emptySet()
            prefs[Keys.autoModeSourceIds] = current.intersect(allowedSourceIds)
        }
    }

    suspend fun restoreFromBackup(payload: BackupData) {
        context.dataStore.edit { prefs ->
            prefs[Keys.accentColor] = payload.accentColor ?: "#6D8CFF"
            prefs[Keys.tmdbLanguage] = payload.tmdbLanguage
            prefs[Keys.selectedAppearance] = payload.selectedAppearance
            prefs[Keys.enableSubtitlesByDefault] = payload.enableSubtitlesByDefault
            prefs[Keys.defaultSubtitleLanguage] = payload.defaultSubtitleLanguage
            prefs[Keys.enableVLCSubtitleEditMenu] = payload.enableVLCSubtitleEditMenu
            prefs[Keys.preferredAnimeAudioLanguage] = payload.preferredAnimeAudioLanguage
            prefs[Keys.inAppPlayer] = payload.resolvedInAppPlayer.name
            prefs[Keys.showScheduleTab] = payload.showScheduleTab
            prefs[Keys.showLocalScheduleTime] = payload.showLocalScheduleTime
            prefs[Keys.holdSpeedPlayer] = payload.holdSpeedPlayer
            prefs[Keys.externalPlayer] = payload.externalPlayer
            prefs[Keys.alwaysLandscape] = payload.alwaysLandscape
            prefs[Keys.aniSkipEnabled] = true
            prefs[Keys.introDbEnabled] = true
            prefs[Keys.aniSkipAutoSkip] = payload.aniSkipAutoSkip
            prefs[Keys.skip85sEnabled] = payload.skip85sEnabled
            prefs[Keys.skip85sAlwaysVisible] = false
            prefs[Keys.showNextEpisodeButton] = payload.showNextEpisodeButton
            prefs[Keys.nextEpisodeThreshold] = payload.nextEpisodeThresholdPercent()
            prefs[Keys.vlcHeaderProxyEnabled] = payload.vlcHeaderProxyEnabled
            val subtitleForegroundColor = payload.subtitleForegroundColor
            if (subtitleForegroundColor != null) {
                prefs[Keys.subtitleForegroundColor] = subtitleForegroundColor
            } else {
                prefs.remove(Keys.subtitleForegroundColor)
            }
            val subtitleStrokeColor = payload.subtitleStrokeColor
            if (subtitleStrokeColor != null) {
                prefs[Keys.subtitleStrokeColor] = subtitleStrokeColor
            } else {
                prefs.remove(Keys.subtitleStrokeColor)
            }
            prefs[Keys.subtitleStrokeWidth] = payload.subtitleStrokeWidth
            prefs[Keys.subtitleFontSize] = payload.subtitleFontSize
            prefs[Keys.subtitleVerticalOffset] = payload.subtitleVerticalOffset
            prefs[Keys.showKanzen] = payload.showKanzen
            prefs[Keys.kanzenAutoMode] = payload.kanzenAutoMode
            prefs[Keys.kanzenAutoUpdateModules] = payload.kanzenAutoUpdateModules
            prefs[Keys.autoUpdateServicesEnabled] = payload.autoUpdateServicesEnabled
            prefs[Keys.githubReleaseAutoCheckEnabled] = payload.githubReleaseAutoCheckEnabled
            prefs[Keys.githubReleaseUpdateAvailable] = payload.githubReleaseUpdateAvailable
            prefs[Keys.githubReleaseLatestVersion] = payload.githubReleaseLatestVersion
            prefs[Keys.githubReleaseUrl] = payload.githubReleaseURL
            prefs[Keys.seasonMenu] = payload.seasonMenu
            prefs[Keys.horizontalEpisodeList] = payload.horizontalEpisodeList
            prefs[Keys.mediaColumnsPortrait] = payload.mediaColumnsPortrait
            prefs[Keys.mediaColumnsLandscape] = payload.mediaColumnsLandscape
            prefs[Keys.readingMode] = payload.readingMode
            prefs[Keys.readerFontSize] = payload.readerFontSize
            prefs[Keys.readerFontFamily] = payload.readerFontFamily
            prefs[Keys.readerFontWeight] = payload.readerFontWeight
            prefs[Keys.readerColorPreset] = payload.readerColorPreset
            prefs[Keys.readerTextAlignment] = payload.readerTextAlignment
            prefs[Keys.readerLineSpacing] = payload.readerLineSpacing
            prefs[Keys.readerMargin] = payload.readerMargin
            prefs[Keys.autoClearCacheEnabled] = payload.autoClearCacheEnabled
            prefs[Keys.autoClearCacheThresholdMB] = payload.autoClearCacheThresholdMB
            prefs[Keys.highQualityThreshold] = payload.highQualityThreshold
            prefs[Keys.filterHorrorContent] = payload.filterHorrorContent
            prefs[Keys.selectedSimilarityAlgorithm] = SimilarityAlgorithm
                .fromId(payload.selectedSimilarityAlgorithm)
                .id
        }
    }

    private fun toAppSettings(preferences: Preferences): AppSettings = AppSettings(
        accentColor = preferences[Keys.accentColor] ?: "#6D8CFF",
        tmdbLanguage = preferences[Keys.tmdbLanguage] ?: "en-US",
        selectedAppearance = preferences[Keys.selectedAppearance] ?: "system",
        enableSubtitlesByDefault = preferences[Keys.enableSubtitlesByDefault] ?: false,
        defaultSubtitleLanguage = preferences[Keys.defaultSubtitleLanguage] ?: "eng",
        enableVLCSubtitleEditMenu = preferences[Keys.enableVLCSubtitleEditMenu] ?: false,
        preferredAnimeAudioLanguage = preferences[Keys.preferredAnimeAudioLanguage] ?: "jpn",
        inAppPlayer = preferences[Keys.inAppPlayer]?.toInAppPlayer() ?: InAppPlayer.NORMAL,
        autoModeEnabled = preferences[Keys.autoModeEnabled] ?: true,
        autoModeSourceIds = preferences[Keys.autoModeSourceIds] ?: emptySet(),
        showScheduleTab = preferences[Keys.showScheduleTab] ?: true,
        showLocalScheduleTime = preferences[Keys.showLocalScheduleTime] ?: true,
        holdSpeedPlayer = preferences[Keys.holdSpeedPlayer] ?: 2.0,
        externalPlayer = preferences[Keys.externalPlayer] ?: "none",
        alwaysLandscape = preferences[Keys.alwaysLandscape] ?: false,
        aniSkipEnabled = preferences[Keys.aniSkipEnabled] ?: true,
        introDbEnabled = preferences[Keys.introDbEnabled] ?: true,
        aniSkipAutoSkip = preferences[Keys.aniSkipAutoSkip] ?: false,
        skip85sEnabled = preferences[Keys.skip85sEnabled] ?: false,
        skip85sAlwaysVisible = preferences[Keys.skip85sAlwaysVisible] ?: false,
        showNextEpisodeButton = preferences[Keys.showNextEpisodeButton] ?: true,
        nextEpisodeThreshold = preferences[Keys.nextEpisodeThreshold] ?: 90,
        vlcHeaderProxyEnabled = preferences[Keys.vlcHeaderProxyEnabled] ?: true,
        subtitleForegroundColor = preferences[Keys.subtitleForegroundColor],
        subtitleStrokeColor = preferences[Keys.subtitleStrokeColor],
        subtitleStrokeWidth = preferences[Keys.subtitleStrokeWidth] ?: 1.0,
        subtitleFontSize = preferences[Keys.subtitleFontSize] ?: 30.0,
        subtitleVerticalOffset = preferences[Keys.subtitleVerticalOffset] ?: -6.0,
        showKanzen = preferences[Keys.showKanzen] ?: false,
        kanzenAutoMode = preferences[Keys.kanzenAutoMode] ?: false,
        kanzenAutoUpdateModules = preferences[Keys.kanzenAutoUpdateModules] ?: true,
        autoUpdateServicesEnabled = preferences[Keys.autoUpdateServicesEnabled] ?: true,
        lastServiceAutoUpdateTimestamp = preferences[Keys.lastServiceAutoUpdateTimestamp] ?: 0L,
        githubReleaseAutoCheckEnabled = preferences[Keys.githubReleaseAutoCheckEnabled] ?: true,
        githubReleaseLastCheckTimestamp = preferences[Keys.githubReleaseLastCheckTimestamp] ?: 0L,
        githubReleaseUpdateAvailable = preferences[Keys.githubReleaseUpdateAvailable] ?: false,
        githubReleaseLatestVersion = preferences[Keys.githubReleaseLatestVersion] ?: "",
        githubReleaseUrl = preferences[Keys.githubReleaseUrl] ?: "",
        githubReleaseShowAlertPending = preferences[Keys.githubReleaseShowAlertPending] ?: false,
        githubReleaseLastPromptedVersion = preferences[Keys.githubReleaseLastPromptedVersion] ?: "",
        seasonMenu = preferences[Keys.seasonMenu] ?: false,
        horizontalEpisodeList = preferences[Keys.horizontalEpisodeList] ?: false,
        mediaColumnsPortrait = preferences[Keys.mediaColumnsPortrait] ?: 3,
        mediaColumnsLandscape = preferences[Keys.mediaColumnsLandscape] ?: 5,
        readingMode = preferences[Keys.readingMode] ?: 2,
        readerFontSize = preferences[Keys.readerFontSize] ?: 16.0,
        readerFontFamily = preferences[Keys.readerFontFamily] ?: "-apple-system",
        readerFontWeight = preferences[Keys.readerFontWeight] ?: "normal",
        readerColorPreset = preferences[Keys.readerColorPreset] ?: 0,
        readerTextAlignment = preferences[Keys.readerTextAlignment] ?: "left",
        readerLineSpacing = preferences[Keys.readerLineSpacing] ?: 1.6,
        readerMargin = preferences[Keys.readerMargin] ?: 4.0,
        autoClearCacheEnabled = preferences[Keys.autoClearCacheEnabled] ?: false,
        autoClearCacheThresholdMB = preferences[Keys.autoClearCacheThresholdMB] ?: 500.0,
        highQualityThreshold = preferences[Keys.highQualityThreshold] ?: 0.9,
        filterHorrorContent = preferences[Keys.filterHorrorContent] ?: false,
        selectedSimilarityAlgorithm = SimilarityAlgorithm.fromId(preferences[Keys.selectedSimilarityAlgorithm]),
    )

    private object Keys {
        val accentColor = stringPreferencesKey("accent_color")
        val tmdbLanguage = stringPreferencesKey("tmdb_language")
        val selectedAppearance = stringPreferencesKey("selected_appearance")
        val enableSubtitlesByDefault = booleanPreferencesKey("enable_subtitles_by_default")
        val defaultSubtitleLanguage = stringPreferencesKey("default_subtitle_language")
        val enableVLCSubtitleEditMenu = booleanPreferencesKey("enable_vlc_subtitle_edit_menu")
        val preferredAnimeAudioLanguage = stringPreferencesKey("preferred_anime_audio_language")
        val inAppPlayer = stringPreferencesKey("in_app_player")
        val autoModeEnabled = booleanPreferencesKey("auto_mode_enabled")
        val autoModeSourceIds = stringSetPreferencesKey("auto_mode_source_ids")
        val showScheduleTab = booleanPreferencesKey("show_schedule_tab")
        val showLocalScheduleTime = booleanPreferencesKey("show_local_schedule_time")
        val holdSpeedPlayer = doublePreferencesKey("hold_speed_player")
        val externalPlayer = stringPreferencesKey("external_player")
        val alwaysLandscape = booleanPreferencesKey("always_landscape")
        val aniSkipEnabled = booleanPreferencesKey("aniskip_enabled")
        val introDbEnabled = booleanPreferencesKey("introdb_enabled")
        val aniSkipAutoSkip = booleanPreferencesKey("aniskip_auto_skip")
        val skip85sEnabled = booleanPreferencesKey("skip_85s_enabled")
        val skip85sAlwaysVisible = booleanPreferencesKey("skip_85s_always_visible")
        val showNextEpisodeButton = booleanPreferencesKey("show_next_episode_button")
        val nextEpisodeThreshold = intPreferencesKey("next_episode_threshold")
        val vlcHeaderProxyEnabled = booleanPreferencesKey("vlc_header_proxy_enabled")
        val subtitleForegroundColor = stringPreferencesKey("subtitle_foreground_color")
        val subtitleStrokeColor = stringPreferencesKey("subtitle_stroke_color")
        val subtitleStrokeWidth = doublePreferencesKey("subtitle_stroke_width")
        val subtitleFontSize = doublePreferencesKey("subtitle_font_size")
        val subtitleVerticalOffset = doublePreferencesKey("subtitle_vertical_offset")
        val showKanzen = booleanPreferencesKey("show_kanzen")
        val kanzenAutoMode = booleanPreferencesKey("kanzen_auto_mode")
        val kanzenAutoUpdateModules = booleanPreferencesKey("kanzen_auto_update_modules")
        val autoUpdateServicesEnabled = booleanPreferencesKey("auto_update_services_enabled")
        val lastServiceAutoUpdateTimestamp = androidx.datastore.preferences.core.longPreferencesKey("last_service_auto_update_timestamp")
        val githubReleaseAutoCheckEnabled = booleanPreferencesKey("github_release_auto_check_enabled")
        val githubReleaseLastCheckTimestamp = androidx.datastore.preferences.core.longPreferencesKey("github_release_last_check_timestamp")
        val githubReleaseUpdateAvailable = booleanPreferencesKey("github_release_update_available")
        val githubReleaseLatestVersion = stringPreferencesKey("github_release_latest_version")
        val githubReleaseUrl = stringPreferencesKey("github_release_url")
        val githubReleaseShowAlertPending = booleanPreferencesKey("github_release_show_alert_pending")
        val githubReleaseLastPromptedVersion = stringPreferencesKey("github_release_last_prompted_version")
        val seasonMenu = booleanPreferencesKey("season_menu")
        val horizontalEpisodeList = booleanPreferencesKey("horizontal_episode_list")
        val mediaColumnsPortrait = intPreferencesKey("media_columns_portrait")
        val mediaColumnsLandscape = intPreferencesKey("media_columns_landscape")
        val readingMode = intPreferencesKey("reading_mode")
        val readerFontSize = doublePreferencesKey("reader_font_size")
        val readerFontFamily = stringPreferencesKey("reader_font_family")
        val readerFontWeight = stringPreferencesKey("reader_font_weight")
        val readerColorPreset = intPreferencesKey("reader_color_preset")
        val readerTextAlignment = stringPreferencesKey("reader_text_alignment")
        val readerLineSpacing = doublePreferencesKey("reader_line_spacing")
        val readerMargin = doublePreferencesKey("reader_margin")
        val autoClearCacheEnabled = booleanPreferencesKey("auto_clear_cache_enabled")
        val autoClearCacheThresholdMB = doublePreferencesKey("auto_clear_cache_threshold_mb")
        val highQualityThreshold = doublePreferencesKey("high_quality_threshold")
        val filterHorrorContent = booleanPreferencesKey("filter_horror_content")
        val selectedSimilarityAlgorithm = stringPreferencesKey("selected_similarity_algorithm")
    }
}

private fun String.toInAppPlayer(): InAppPlayer = when (trim().lowercase()) {
    "vlc" -> InAppPlayer.VLC
    "mpv" -> InAppPlayer.EXTERNAL
    "external", "outplayer", "outside" -> InAppPlayer.EXTERNAL
    "normal", "default", "media3", "exoplayer" -> InAppPlayer.NORMAL
    else -> runCatching { InAppPlayer.valueOf(this) }.getOrDefault(InAppPlayer.NORMAL)
}

private fun String.normalizedLanguageCode(fallback: String): String =
    trim()
        .lowercase()
        .replace('_', '-')
        .takeIf { it.isNotBlank() }
        ?: fallback

private fun String.normalizedAppearance(): String =
    when (trim().lowercase()) {
        "light" -> "light"
        "dark" -> "dark"
        else -> "system"
    }

private fun String.normalizedTextAlignment(): String =
    when (trim().lowercase()) {
        "center" -> "center"
        "right" -> "right"
        "justify" -> "justify"
        else -> "left"
    }

private fun String?.normalizedOptionalColor(): String? =
    this?.trim()
        ?.takeIf { it.isNotBlank() && it != "none" }
        ?.let { value ->
            if (value.startsWith("#")) value else "#$value"
        }
