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
    val aniSkipAutoSkip: Boolean = false,
    val skip85sEnabled: Boolean = false,
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
)

class SettingsStore(
    private val context: Context,
) {
    val settings: Flow<AppSettings> = context.dataStore.data.map(::toAppSettings)

    suspend fun updateAppearance(
        accentColor: String,
        tmdbLanguage: String,
    ) {
        context.dataStore.edit { prefs ->
            prefs[Keys.accentColor] = accentColor
            prefs[Keys.tmdbLanguage] = tmdbLanguage
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
        aniSkipAutoSkip: Boolean,
        skip85sEnabled: Boolean,
    ) {
        context.dataStore.edit { prefs ->
            prefs[Keys.aniSkipAutoSkip] = aniSkipAutoSkip
            prefs[Keys.skip85sEnabled] = skip85sEnabled
        }
    }

    suspend fun setAutoModeEnabled(enabled: Boolean) {
        context.dataStore.edit { prefs ->
            prefs[Keys.autoModeEnabled] = enabled
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
            prefs[Keys.aniSkipAutoSkip] = payload.aniSkipAutoSkip
            prefs[Keys.skip85sEnabled] = payload.skip85sEnabled
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
        aniSkipAutoSkip = preferences[Keys.aniSkipAutoSkip] ?: false,
        skip85sEnabled = preferences[Keys.skip85sEnabled] ?: false,
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
        val aniSkipAutoSkip = booleanPreferencesKey("aniskip_auto_skip")
        val skip85sEnabled = booleanPreferencesKey("skip_85s_enabled")
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
    }
}

private fun String.toInAppPlayer(): InAppPlayer = when (trim().lowercase()) {
    "vlc" -> InAppPlayer.VLC
    "mpv" -> InAppPlayer.MPV
    "external", "outplayer", "outside" -> InAppPlayer.EXTERNAL
    "normal", "default", "media3", "exoplayer" -> InAppPlayer.NORMAL
    else -> runCatching { InAppPlayer.valueOf(this) }.getOrDefault(InAppPlayer.NORMAL)
}
