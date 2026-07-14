import Foundation
import UIKit

// MARK: - Backup Data Model

struct BackupSearchHistory: Codable {
    var queries: [String] = []

    private enum CodingKeys: String, CodingKey {
        case queries
    }

    init(queries: [String] = []) {
        self.queries = Self.sanitizedQueries(queries)
    }

    init(from decoder: Decoder) throws {
        if let values = try? [String](from: decoder) {
            queries = Self.sanitizedQueries(values)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        queries = Self.sanitizedQueries(try container.decodeIfPresent([String].self, forKey: .queries) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(queries, forKey: .queries)
    }

    init(jsonValue: Any?) {
        if let values = jsonValue as? [String] {
            self.init(queries: values)
            return
        }

        if let dictionary = jsonValue as? [String: Any],
           let values = dictionary["queries"] as? [String] {
            self.init(queries: values)
            return
        }

        self.init()
    }

    private static func sanitizedQueries(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                continue
            }
            result.append(trimmed)
            if result.count == 10 { break }
        }
        return result
    }
}

struct BackupData: Codable {
    let version: String
    let createdDate: Date
    
    // Settings
    var accentColor: Data?
    var settingsGradientColor: Data?
    var readerAccentColor: Data?
    var tmdbLanguage: String
    var selectedAppearance: String
    var readerSelectedAppearance: String
    var readerGlobalAppearanceEnabled: Bool
    var readerSettingsGradientColor: Data?
    var enableSubtitlesByDefault: Bool
    var defaultSubtitleLanguage: String
    var playerSubtitleAppearanceEnabled: Bool

    var preferredAutoAudioLanguage: String
    var preferredAnimeAudioLanguage: String
    var inAppPlayer: String
    var showScheduleTab: Bool
    var showLocalScheduleTime: Bool
    var defaultScheduleMode: String = ScheduleMode.anime.rawValue
    var scheduleWindowDays: Int = ScheduleWindow.defaultValue.rawValue
    // Device authorization and pending UNNotificationRequests intentionally stay local.
    // Nil preserves the current notification choices when restoring an older backup.
    var localNotificationSubscriptions: String?
    var localNotificationEpisodeReminders: String?
    var localNotificationEpisodeLeadTime: Int?
    var localNotificationSeasonLeadTime: Int?
    var localNotificationIncludeAnimeSpecials: Bool?

    // Player Settings
    var defaultPlaybackSpeed: Double = 1.0
    var holdSpeedPlayer: Double = 2.0
    var externalPlayer: String = "none"
    var preferDownloadedMedia: Bool = false
    var alwaysLandscape: Bool = false
    var playerPlaybackLockEnabled: Bool = PlayerPlaybackLockSettings.defaultEnabled
    var aniSkipEnabled: Bool = true
    var introDBEnabled: Bool = true
    var introDBAppEnabled: Bool = true
    var aniSkipAutoSkip: Bool = false
    var skip85sEnabled: Bool = false
    var skip85sAlwaysVisible: Bool = false
    var showNextEpisodeButton: Bool = true
    var showEpisodeBrowserButton: Bool = true
    var showPlayerServicesButton: Bool = false
    var showNextEpisodePosterButton: Bool = false
    var nextEpisodeThreshold: Double = 0.90
    var nextEpisodeSkipFillerEnabled: Bool = NextEpisodeFillerSettings.defaultEnabled
    var playerBrightnessGestureEnabled: Bool = false
    var playerVolumeGestureEnabled: Bool = false
    var playerTwoFingerTapPlayPauseEnabled: Bool = true
    var playerCenterTapPlayPauseEnabled: Bool = true
    var playerDoubleTapSeekEnabled: Bool = true
    var playerDoubleTapSeekSeconds: Double = 10.0
    var playerOpenSubtitlesEnabled: Bool = false
    var playerOpenSubtitlesAutoFallbackEnabled: Bool = true
    var playerPerformanceOverlayEnabled: Bool = false
    var mpvForegroundFPS: Int = 30
    var mpvRenderBackend: String = MPVRenderBackend.defaultBackend.rawValue
    var mpvMetalQualityProfile: String = MPVMetalQualityProfile.defaultProfile.rawValue
    var mpvUpscalingMode: String = MPVUpscalingMode.defaultMode.rawValue
    var mpvPlayerSkin: String = MPVPlayerSkin.defaultSkin.rawValue
    var mpvPlayerSkinCustomPrimaryColor: Data?
    var mpvPlayerSkinCustomSecondaryColor: Data?
    var mpvPlayerSkinAnimationsEnabled: Bool = MPVPlayerSkinSettings.defaultAnimationsEnabled
    var mpvPlayerSkinTintControlsOnly: Bool = MPVPlayerSkinSettings.defaultTintControlsOnly
    var mpvPictureInPictureEnabled: Bool = true
    var mpvAppExitPictureInPictureEnabled: Bool = false
    var mpvHDRMode: String = MPVHDRMode.defaultMode.rawValue
    var mpvSurroundSoundEnabled: Bool = true
    var watchTogetherEnabled: Bool = WatchTogetherSettings.defaultEnabled
    var smartInAppPlayerChoosingEnabled: Bool = false
    var experimentalFeaturesEnabled: Bool = false
    var experimentalFeaturesLastChangedAt: Double = 0
    var experimentalMPVPreloadEnabled: Bool = true
    var experimentalMPVSmoothTransitionEnabled: Bool = true
    var experimentalMPVPreloadCellularEnabled: Bool = false
    var experimentalMPVPreloadWifiLimitMB: Int = ExperimentalFeatureState.mpvPreloadWifiDefaultLimitMB
    var experimentalMPVPreloadCellularLimitMB: Int = ExperimentalFeatureState.mpvPreloadCellularDefaultLimitMB
    var experimentalMPVShowRemainingTime: Bool = true
    var experimentalMPVPreciseProgress: Bool = true
    var experimentalMPVIgnoreSpecialSubtitleStyles: Bool = false
    var experimentalMPVPreloadAutoClear: Bool = true
    var experimentalICloudSyncEnabled: Bool = false

    // Subtitle Styling
    var subtitleForegroundColor: Data?
    var subtitleStrokeColor: Data?
    var subtitleStrokeWidth: Double = 1.0
    var subtitleFontSize: Double = 30.0
    var subtitleVerticalOffset: Double = -6.0
    var subtitlesVisible: Bool = false

    // UI Preferences
    var showKanzen: Bool = false
    var hideSplashScreen: Bool?
    var modeSwitchAnimationEnabled: Bool = ModeSwitchAnimationSettings.defaultEnabled
    var kanzenAutoUpdateModules: Bool = true
    var seasonMenu: Bool = false
    var horizontalEpisodeList: Bool = false
    var mediaDetailTitleArtworkEnabled: Bool = MediaDetailTitleArtworkSettings.defaultEnabled
    var mediaDetailSimilarTitlesEnabled: Bool = MediaDetailSimilarTitlesSettings.defaultEnabled
    var useClassicScheduleUI: Bool = false
    var heroBannerCatalogId: String = "trending"
    var heroBannerBehavior: String = HeroBannerBehavior.defaultValue.rawValue
    /// JSON blob of per-catalog home layout overrides (keyed by catalog id). "" when none.
    var homeCatalogLayoutOverrides: String = ""
    var homeAnimatedBackgroundEnabled: Bool?
    var homeAnimatedBackgroundQuality: String = HomeAnimatedBackgroundQuality.defaultValue.rawValue
    var homeAnimatedBackgroundFrameRate: String = HomeAnimatedBackgroundFrameRate.defaultValue.rawValue
    var appPerformanceOverlayEnabled: Bool = AppPerformanceOverlaySettings.defaultEnabled
    var experimentalMediaDesignPreset: String = ExperimentalMediaDesignPreset.defaultValue.rawValue
    var experimentalHeroBleedLevel: String = ExperimentalHeroBleedLevel.defaultValue.rawValue
    var experimentalHomeCardShape: String = ExperimentalHomeCardShape.defaultValue.rawValue
    var experimentalMultiGradientPalette: String = ExperimentalMultiGradientPalette.defaultValue.rawValue
    var experimentalHeroHeightScale: Double = ExperimentalVisualTuning.defaultHeroHeightScale
    var experimentalHeroBleedStrength: Double = ExperimentalVisualTuning.defaultHeroBleedStrength
    var experimentalHeroFadeDistanceScale: Double = ExperimentalVisualTuning.defaultHeroFadeDistanceScale
    var experimentalSectionSpacingScale: Double = ExperimentalVisualTuning.defaultSectionSpacingScale
    var experimentalCardRadiusScale: Double = ExperimentalVisualTuning.defaultCardRadiusScale
    var experimentalMediaCardScale: Double = ExperimentalVisualTuning.defaultMediaCardScale
    var experimentalGlassStrength: Double = ExperimentalVisualTuning.defaultGlassStrength
    var experimentalGradientBaseDarkness: Double = ExperimentalVisualTuning.defaultGradientBaseDarkness
    var experimentalGradientAccentIntensity: Double = ExperimentalVisualTuning.defaultGradientAccentIntensity
    var experimentalGradientScrollMotion: Double = ExperimentalVisualTuning.defaultGradientScrollMotion
    var experimentalGradientUseCustomColors: Bool = false
    var experimentalGradientColorA: Data?
    var experimentalGradientColorB: Data?
    var experimentalGradientColorC: Data?
    var atmosphereStyle: String = AtmosphereStyle.gradient.rawValue
    var atmosphereSolidColorSource: String = AtmosphereSolidColorSource.dominant.rawValue
    var atmosphereSolidColor: Data?
    var readerAtmosphereStyle: String = AtmosphereStyle.gradient.rawValue
    var readerAtmosphereSolidColorSource: String = AtmosphereSolidColorSource.dominant.rawValue
    var readerAtmosphereSolidColor: Data?
    var mediaDetailElementOrder: String = MediaDetailElement.defaultOrderRawValue
    var mediaDetailHiddenElements: String = ""
    var readerDetailElementOrder: String = ReaderDetailElement.defaultOrderRawValue
    var readerDetailHiddenElements: String = ""
    var mediaColumnsPortrait: Int = 3
    var mediaColumnsLandscape: Int = 5

    // Manga / Reader
    var readingMode: Int = 2
    var kanzenReaderMode: String = "webtoon"
    var kanzenReaderModeOverrides: [String: String] = [:]
    var readerDownsampleImages: Bool = true
    var readerCropBorders: Bool = false
    var readerDisableQuickActions: Bool = false
    var readerDisableDoubleTap: Bool = false
    var readerLiveText: Bool = false
    var readerHideBarsOnSwipe: Bool = false
    var readerBackgroundColor: String = "black"
    var readerOrientation: String = "device"
    var readerTapZones: String = "disabled"
    var readerInvertTapZones: Bool = false
    var readerAnimatePageTransitions: Bool = true
    var readerUpscaleImages: Bool = false
    var readerUpscaleMaxHeight: Int = 2000
    var readerUpscaleModelName: String = "None"
    var readerPagesToPreload: Int = 3
    var readerPagedPageLayout: String = "single"
    var readerPagedPageOffset: Bool = false
    var readerPagedPageOffsetOverrides: [String: Bool] = [:]
    var readerSplitWideImages: Bool = false
    var readerReverseSplitOrder: Bool = false
    var readerVerticalInfiniteScroll: Bool = true
    var readerPillarbox: Bool = false
    var readerPillarboxAmount: Double = 15
    var readerPillarboxOrientation: String = "both"
    var readerOrientationLockEnabled: Bool = false
    var readerOrientationLockMask: String = "all"
    var readerReadThresholdPercent: Double = 80

    // Novel Reader
    var readerFontSize: Double = 16
    var readerFontFamily: String = "-apple-system"
    var readerFontWeight: String = "normal"
    var readerColorPreset: Int = 0
    var readerTextAlignment: String = "left"
    var readerLineSpacing: Double = 1.6
    var readerMargin: Double = 4

    // Other
    var autoClearCacheEnabled: Bool = false
    var autoClearCacheThresholdMB: Double = 500
    var highQualityThreshold: Double = 0.9
    var backgroundHLSPipelineEnabled: Bool = false
    var readerDownloadsBackgroundEnabled: Bool = true
    var readerDownloadsWifiOnly: Bool = false
    var readerDownloadsParallelLimit: Int = 2
    var autoUpdateServicesEnabled: Bool = true
    var servicesAutoModeEnabled: Bool = false
    var servicesAutoSelectEpisodesEnabled: Bool = false
    var servicesAutoModeSourceIds: [String] = []
    var servicesAutoModeSourceOrderIds: [String] = []
    var servicesAutoModeQualityPreference: String = AutoModeQualityPreference.defaultPreference.rawValue
    var servicesResultMinimumSimilarity: Double = ServicesResultRankingSettings.defaultMinimumSimilarity
    var servicesDropMismatchedResults: Bool = ServicesResultRankingSettings.defaultDropMismatchedResults
    var servicesStremioStyleSheetEnabled: Bool = ServicesSheetPresentationSettings.defaultStremioStyleEnabled
    var servicesIncludedStreamLanguages: [String] = []
    var servicesHiddenStreamLanguages: [String] = []
    var servicesHideStreamsWithoutLanguageData: Bool = false
    var servicesAssumeOriginalAudio: Bool = false
    var servicesTreatDubbedAnimeAsEnglish: Bool = false
    var servicesHiddenStreamQualities: [Int] = []
    var servicesHideStreamsWithoutDetectedQuality: Bool = false
    /// nil preserves the default of applying rules to every Service/Stremio addon; [] means none.
    var servicesExtraRulesSourceIds: [String]? = nil
    var githubReleaseAutoCheckEnabled: Bool = true
    var githubReleaseUpdateAvailable: Bool = false
    var githubReleaseLatestVersion: String = ""
    var githubReleaseURL: String = ""
    var githubReleaseShowAlertPending: Bool = false
    var githubReleaseLastPromptedVersion: String = ""
    var filterHorrorContent: Bool = false
    var selectedSimilarityAlgorithm: String = SimilarityAlgorithm.hybrid.rawValue
    var performanceModeEnabled: Bool = PerformanceModeSettings.defaultEnabled
    var performanceModeSkipAniListTraversalForAnimeDetails: Bool = false
    var performanceModeFastAnimeCatalogOverrides: [String: Bool] = [:]

    // Kanzen home / search
    var kanzenHomeSelectedSourceID: String = ""
    var kanzenRecentSourceSearches: [String] = []

    // Collections (Library)
    var collections: [BackupCollection] = []
    
    // Progress Tracking
    var progressData: ProgressData = ProgressData()
    
    // Tracker Services (AniList, Trakt, etc.)
    var trackerState: TrackerState = TrackerState()
    
    // Catalogs
    var catalogs: [Catalog] = []

    // Services (custom JS modules)
    var services: [BackupService] = []

    // Stremio addons. Nil means the backup predates this field and restore should leave existing addons alone.
    var stremioAddons: [BackupStremioAddon]? = nil

    // Manga / Kanzen data
    var mangaCollections: [BackupMangaCollection] = []
    var mangaReadingProgress: [String: MangaProgress] = [:]
    var mangaCatalogs: [MangaCatalog] = []
    var kanzenModules: [BackupKanzenModule] = []
    var aidokuState: BackupAidokuState?

    // Recommendations
    var searchHistory: BackupSearchHistory = BackupSearchHistory()
    var recommendationCache: [TMDBSearchResult] = []

    // User Ratings
    var userRatings: [String: Double] = [:]
    var userRatingNotes: [String: String] = [:]

    /// Safe media-state settings that are also eligible for CloudKit sync.
    /// Values are property-list encoded so newer settings do not have to wait
    /// for this backup model to grow another hand-written field.
    var mediaStateSettings: [String: Data]? = nil

    // These presence flags are intentionally not encoded. They let restores of
    // newer backups clear an explicitly empty domain while older backups that
    // predate that domain continue to preserve the device's existing data.
    private(set) var hasMangaCollections = true
    private(set) var hasMangaReadingProgress = true
    private(set) var hasMangaCatalogs = true
    private(set) var hasKanzenModules = true
    private(set) var hasUserRatings = true

    func redactedForExperimentalCloudSync() -> BackupData {
        var snapshot = self

        snapshot.trackerState.accounts = trackerState.accounts.map { account in
            var metadataOnly = account
            metadataOnly.accessToken = ""
            metadataOnly.refreshToken = nil
            metadataOnly.expiresAt = nil
            return metadataOnly
        }

        snapshot.services = services.compactMap(Self.serviceForExperimentalCloudSync)
        snapshot.stremioAddons = stremioAddons?.compactMap(Self.stremioAddonForExperimentalCloudSync)

        snapshot.kanzenModules = kanzenModules.filter {
            Self.cloudSafeURLString($0.moduleurl) != nil &&
            !Self.containsCloudUnsafeSecret($0.moduleurl)
        }

        if var aidokuState = aidokuState {
            aidokuState.installedSources = aidokuState.installedSources.compactMap { source in
                let safeSourceListURL = source.sourceListURL.flatMap(Self.cloudSafeURLString)
                let safePackageURL = source.packageURL.flatMap(Self.cloudSafeURLString)
                return BackupAidokuInstalledSource(
                    id: source.id,
                    name: source.name,
                    version: source.version,
                    languages: source.languages,
                    iconPath: nil,
                    externalIconURL: source.externalIconURL.flatMap(Self.cloudSafeURLString),
                    contentRatingRawValue: source.contentRatingRawValue,
                    sourceListURL: safeSourceListURL,
                    packageURL: safePackageURL,
                    isEnabled: source.isEnabled,
                    order: source.order,
                    lastUpdated: source.lastUpdated,
                    lastError: source.lastError,
                    payloadArchiveData: nil
                )
            }
            snapshot.aidokuState = aidokuState
        }

        // Recommendation results are cache data, not user state.
        snapshot.recommendationCache = []
        return snapshot
    }

    private static func cloudSafeURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !containsCloudUnsafeSecret(trimmed),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let safeItems = queryItems.filter { item in
                !containsCloudUnsafeSecret(item.name) &&
                !(item.value.map(containsCloudUnsafeSecret) ?? false)
            }
            components.queryItems = safeItems.isEmpty ? nil : safeItems
        }
        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func containsCloudUnsafeSecret(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        let secretMarkers = [
            "access_token",
            "refresh_token",
            "authorization",
            "bearer ",
            "api_key",
            "apikey",
            "password",
            "passwd",
            "session",
            "secret",
            "token="
        ]
        return secretMarkers.contains { lowercased.contains($0) }
    }

    /// Returns the cloud-safe representation of a service, or nil when its
    /// install URL/script may contain device-local credentials. The same
    /// classification is reused during restore so omitted private sources are
    /// preserved locally rather than mistaken for remote deletions.
    static func serviceForExperimentalCloudSync(_ service: BackupService) -> BackupService? {
        guard let safeURL = cloudSafeURLString(service.url),
              !containsCloudUnsafeSecret(service.jsonMetadata),
              !containsCloudUnsafeSecret(service.jsScript) else {
            return nil
        }
        return BackupService(
            id: service.id,
            url: safeURL,
            jsonMetadata: service.jsonMetadata,
            jsScript: service.jsScript,
            isActive: service.isActive,
            sortIndex: service.sortIndex
        )
    }

    /// Configured Stremio paths and query strings commonly contain opaque
    /// provider/debrid tokens without a helpful `token=` marker. Only a bare
    /// HTTP(S) origin is safe to copy through the redacted cloud snapshot.
    static func stremioAddonForExperimentalCloudSync(
        _ addon: BackupStremioAddon
    ) -> BackupStremioAddon? {
        guard let safeURL = cloudSafeURLString(addon.configuredURL),
              let components = URLComponents(string: safeURL),
              components.user == nil,
              components.password == nil,
              components.queryItems?.isEmpty != false,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              !containsCloudUnsafeSecret(addon.manifestJSON) else {
            return nil
        }
        return BackupStremioAddon(
            id: addon.id,
            configuredURL: safeURL,
            manifestJSON: addon.manifestJSON,
            isActive: addon.isActive,
            sortIndex: addon.sortIndex
        )
    }

    static func captureMediaStateSettings(from defaults: UserDefaults = .standard) -> [String: Data] {
        var result: [String: Data] = [:]
        for key in MediaStateSettingRegistry.allKeys {
            guard MediaStateSettingRegistry.scope(for: key)?.appliesToCurrentPlatform == true,
                  let value = defaults.object(forKey: key),
                  PropertyListSerialization.propertyList(value, isValidFor: .binary),
                  let data = try? PropertyListSerialization.data(
                    fromPropertyList: value,
                    format: .binary,
                    options: 0
                  ) else {
                continue
            }
            result[key] = data
        }
        return result
    }

    static func restoreMediaStateSettings(_ settings: [String: Data]?, to defaults: UserDefaults = .standard) {
        guard let settings else { return }
        for (key, data) in settings {
            guard MediaStateSettingRegistry.scope(for: key)?.appliesToCurrentPlatform == true,
                  let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
                continue
            }
            defaults.set(value, forKey: key)
        }
    }

    static func mediaStateSettings(fromJSONValue value: Any?) -> [String: Data]? {
        guard let values = value as? [String: Any] else { return nil }
        let decoded = values.reduce(into: [String: Data]()) { result, item in
            guard let base64 = item.value as? String,
                  let data = Data(base64Encoded: base64) else { return }
            result[item.key] = data
        }
        return decoded
    }

    enum CodingKeys: String, CodingKey {
        case version, createdDate
        case accentColor, settingsGradientColor, readerAccentColor, tmdbLanguage, selectedAppearance, readerSelectedAppearance, readerGlobalAppearanceEnabled, readerSettingsGradientColor, enableSubtitlesByDefault, defaultSubtitleLanguage, playerSubtitleAppearanceEnabled, enableVLCSubtitleEditMenu, preferredAutoAudioLanguage, preferredAnimeAudioLanguage, inAppPlayer, playerChoice, showScheduleTab, showLocalScheduleTime, defaultScheduleMode, scheduleWindowDays
        case localNotificationSubscriptions, localNotificationEpisodeReminders, localNotificationEpisodeLeadTime, localNotificationSeasonLeadTime, localNotificationIncludeAnimeSpecials
        case defaultPlaybackSpeed, holdSpeedPlayer, externalPlayer, preferDownloadedMedia, alwaysLandscape, playerPlaybackLockEnabled, aniSkipEnabled, introDBEnabled, introDBAppEnabled, aniSkipAutoSkip, skip85sEnabled, skip85sAlwaysVisible, showNextEpisodeButton, showEpisodeBrowserButton, showVLCEpisodeBrowserButton, showPlayerServicesButton, showNextEpisodePosterButton, nextEpisodeThreshold, nextEpisodeSkipFillerEnabled, vlcHeaderProxyEnabled
        case playerBrightnessGestureEnabled, playerVolumeGestureEnabled, vlcBrightnessGestureEnabled, vlcVolumeGestureEnabled, playerTwoFingerTapPlayPauseEnabled, playerCenterTapPlayPauseEnabled, playerDoubleTapSeekEnabled, vlcDoubleTapSeekEnabled, playerDoubleTapSeekSeconds, vlcDoubleTapSeekSeconds, playerOpenSubtitlesEnabled, vlcOpenSubtitlesEnabled, playerOpenSubtitlesAutoFallbackEnabled, vlcOpenSubtitlesAutoFallbackEnabled, playerPerformanceOverlayEnabled, mpvForegroundFPS, mpvRenderBackend, mpvMetalQualityProfile, mpvUpscalingMode, mpvPlayerSkin, mpvPlayerSkinCustomPrimaryColor, mpvPlayerSkinCustomSecondaryColor, mpvPlayerSkinAnimationsEnabled, mpvPlayerSkinTintControlsOnly, mpvPictureInPictureEnabled, mpvAppExitPictureInPictureEnabled, mpvHDRMode, mpvSurroundSoundEnabled, watchTogetherEnabled, smartInAppPlayerChoosingEnabled, experimentalFeaturesEnabled, experimentalFeaturesLastChangedAt, experimentalMPVPreloadEnabled, experimentalMPVSmoothTransitionEnabled, experimentalMPVPreloadCellularEnabled, experimentalMPVPreloadWifiLimitMB, experimentalMPVPreloadCellularLimitMB, experimentalMPVShowRemainingTime, experimentalMPVPreciseProgress, experimentalMPVIgnoreSpecialSubtitleStyles, experimentalMPVPreloadAutoClear, experimentalICloudSyncEnabled
        case subtitleForegroundColor, subtitleStrokeColor, subtitleStrokeWidth, subtitleFontSize, subtitleVerticalOffset, subtitlesVisible
        case showKanzen, hideSplashScreen, modeSwitchAnimationEnabled, kanzenAutoUpdateModules, seasonMenu, horizontalEpisodeList, mediaDetailTitleArtworkEnabled, mediaDetailSimilarTitlesEnabled, useClassicScheduleUI, heroBannerCatalogId, heroBannerBehavior, homeCatalogLayoutOverrides, homeAnimatedBackgroundEnabled, homeAnimatedBackgroundQuality, homeAnimatedBackgroundFrameRate, appPerformanceOverlayEnabled, experimentalMediaDesignPreset, experimentalHeroBleedLevel, experimentalHomeCardShape, experimentalMultiGradientPalette, experimentalHeroHeightScale, experimentalHeroBleedStrength, experimentalHeroFadeDistanceScale, experimentalSectionSpacingScale, experimentalCardRadiusScale, experimentalMediaCardScale, experimentalGlassStrength, experimentalGradientBaseDarkness, experimentalGradientAccentIntensity, experimentalGradientScrollMotion, experimentalGradientUseCustomColors, experimentalGradientColorA, experimentalGradientColorB, experimentalGradientColorC, atmosphereStyle, atmosphereSolidColorSource, atmosphereSolidColor, readerAtmosphereStyle, readerAtmosphereSolidColorSource, readerAtmosphereSolidColor, mediaDetailElementOrder, mediaDetailHiddenElements, readerDetailElementOrder, readerDetailHiddenElements, mediaColumnsPortrait, mediaColumnsLandscape
        case readingMode, kanzenReaderMode, kanzenReaderModeOverrides, readerDownsampleImages, readerCropBorders, readerDisableQuickActions, readerDisableDoubleTap, readerLiveText, readerHideBarsOnSwipe, readerBackgroundColor, readerOrientation, readerTapZones, readerInvertTapZones, readerAnimatePageTransitions, readerUpscaleImages, readerUpscaleMaxHeight, readerUpscaleModelName, readerPagesToPreload, readerPagedPageLayout, readerPagedPageOffset, readerPagedPageOffsetOverrides, readerSplitWideImages, readerReverseSplitOrder, readerVerticalInfiniteScroll, readerPillarbox, readerPillarboxAmount, readerPillarboxOrientation, readerOrientationLockEnabled, readerOrientationLockMask, readerReadThresholdPercent
        case readerFontSize, readerFontFamily, readerFontWeight, readerColorPreset, readerTextAlignment, readerLineSpacing, readerMargin
        case autoClearCacheEnabled, autoClearCacheThresholdMB, highQualityThreshold, backgroundHLSPipelineEnabled, readerDownloadsBackgroundEnabled, readerDownloadsWifiOnly, readerDownloadsParallelLimit, autoUpdateServicesEnabled, servicesAutoModeEnabled, servicesAutoSelectEpisodesEnabled, servicesAutoModeSourceIds, servicesAutoModeSourceOrderIds, servicesAutoModeQualityPreference, servicesResultMinimumSimilarity, servicesDropMismatchedResults, servicesStremioStyleSheetEnabled, servicesIncludedStreamLanguages, servicesHiddenStreamLanguages, servicesHideStreamsWithoutLanguageData, servicesAssumeOriginalAudio, servicesTreatDubbedAnimeAsEnglish, servicesHiddenStreamQualities, servicesHideStreamsWithoutDetectedQuality, servicesExtraRulesSourceIds, githubReleaseAutoCheckEnabled, githubReleaseUpdateAvailable, githubReleaseLatestVersion, githubReleaseURL, githubReleaseShowAlertPending, githubReleaseLastPromptedVersion, filterHorrorContent = "filterHorror", selectedSimilarityAlgorithm, performanceModeEnabled, performanceModeSkipAniListTraversalForAnimeDetails, performanceModeFastAnimeCatalogOverrides
        case kanzenHomeSelectedSourceID, kanzenRecentSourceSearches
        case collections, progressData, trackerState, catalogs, services, stremioAddons
        case mangaCollections, mangaReadingProgress, mangaCatalogs, kanzenModules, aidokuState
        case searchHistory, recommendationCache
        case userRatings, userRatingNotes
        case mediaStateSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        accentColor = try Self.decodeColorData(from: container, forKey: .accentColor)
        settingsGradientColor = try Self.decodeColorData(from: container, forKey: .settingsGradientColor)
        readerAccentColor = try Self.decodeColorData(from: container, forKey: .readerAccentColor)
        tmdbLanguage = try container.decodeIfPresent(String.self, forKey: .tmdbLanguage) ?? "en-US"
        selectedAppearance = Self.sanitizedAppearance(try container.decodeIfPresent(String.self, forKey: .selectedAppearance))
        readerSelectedAppearance = Self.sanitizedAppearance(
            try container.decodeIfPresent(String.self, forKey: .readerSelectedAppearance)
                ?? selectedAppearance
        )
        readerGlobalAppearanceEnabled = try container.decodeIfPresent(Bool.self, forKey: .readerGlobalAppearanceEnabled) ?? true
        readerSettingsGradientColor = try Self.decodeColorData(from: container, forKey: .readerSettingsGradientColor)
        enableSubtitlesByDefault = try container.decodeIfPresent(Bool.self, forKey: .enableSubtitlesByDefault) ?? false
        defaultSubtitleLanguage = try container.decodeIfPresent(String.self, forKey: .defaultSubtitleLanguage) ?? "eng"
        playerSubtitleAppearanceEnabled = try container.decodeIfPresent(Bool.self, forKey: .playerSubtitleAppearanceEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .enableVLCSubtitleEditMenu)
            ?? true

        preferredAutoAudioLanguage = try container.decodeIfPresent(String.self, forKey: .preferredAutoAudioLanguage) ?? "eng"
        preferredAnimeAudioLanguage = try container.decodeIfPresent(String.self, forKey: .preferredAnimeAudioLanguage) ?? "jpn"
        // Support both new "inAppPlayer" key and legacy "playerChoice" key
        inAppPlayer = Settings.normalizedInAppPlayer(
            try container.decodeIfPresent(String.self, forKey: .inAppPlayer)
                ?? container.decodeIfPresent(String.self, forKey: .playerChoice)
        )
        showScheduleTab = try container.decodeIfPresent(Bool.self, forKey: .showScheduleTab) ?? true
        showLocalScheduleTime = try container.decodeIfPresent(Bool.self, forKey: .showLocalScheduleTime) ?? true
        defaultScheduleMode = ScheduleMode.sanitizedRawValue(try container.decodeIfPresent(String.self, forKey: .defaultScheduleMode))
        scheduleWindowDays = ScheduleWindow.sanitizedDays(try container.decodeIfPresent(Int.self, forKey: .scheduleWindowDays))
        localNotificationSubscriptions = try container.decodeIfPresent(String.self, forKey: .localNotificationSubscriptions)
        localNotificationEpisodeReminders = try container.decodeIfPresent(String.self, forKey: .localNotificationEpisodeReminders)
        localNotificationEpisodeLeadTime = try container.decodeIfPresent(Int.self, forKey: .localNotificationEpisodeLeadTime)
        localNotificationSeasonLeadTime = try container.decodeIfPresent(Int.self, forKey: .localNotificationSeasonLeadTime)
        localNotificationIncludeAnimeSpecials = try container.decodeIfPresent(Bool.self, forKey: .localNotificationIncludeAnimeSpecials)

        // Player settings
        defaultPlaybackSpeed = try container.decodeIfPresent(Double.self, forKey: .defaultPlaybackSpeed) ?? 1.0
        holdSpeedPlayer = try container.decodeIfPresent(Double.self, forKey: .holdSpeedPlayer) ?? 2.0
        externalPlayer = try container.decodeIfPresent(String.self, forKey: .externalPlayer) ?? "none"
        preferDownloadedMedia = try container.decodeIfPresent(Bool.self, forKey: .preferDownloadedMedia) ?? false
        alwaysLandscape = try container.decodeIfPresent(Bool.self, forKey: .alwaysLandscape) ?? false
        playerPlaybackLockEnabled = try container.decodeIfPresent(Bool.self, forKey: .playerPlaybackLockEnabled) ?? PlayerPlaybackLockSettings.defaultEnabled
        aniSkipEnabled = try container.decodeIfPresent(Bool.self, forKey: .aniSkipEnabled) ?? true
        introDBEnabled = try container.decodeIfPresent(Bool.self, forKey: .introDBEnabled) ?? true
        introDBAppEnabled = try container.decodeIfPresent(Bool.self, forKey: .introDBAppEnabled) ?? true
        aniSkipAutoSkip = try container.decodeIfPresent(Bool.self, forKey: .aniSkipAutoSkip) ?? false
        skip85sEnabled = try container.decodeIfPresent(Bool.self, forKey: .skip85sEnabled) ?? false
        skip85sAlwaysVisible = try container.decodeIfPresent(Bool.self, forKey: .skip85sAlwaysVisible) ?? false
        showNextEpisodeButton = try container.decodeIfPresent(Bool.self, forKey: .showNextEpisodeButton) ?? true
        showEpisodeBrowserButton = try container.decodeIfPresent(Bool.self, forKey: .showEpisodeBrowserButton)
            ?? container.decodeIfPresent(Bool.self, forKey: .showVLCEpisodeBrowserButton)
            ?? true
        showPlayerServicesButton = try container.decodeIfPresent(Bool.self, forKey: .showPlayerServicesButton) ?? false
        showNextEpisodePosterButton = try container.decodeIfPresent(Bool.self, forKey: .showNextEpisodePosterButton) ?? false
        nextEpisodeThreshold = try container.decodeIfPresent(Double.self, forKey: .nextEpisodeThreshold) ?? 0.90
        nextEpisodeSkipFillerEnabled = try container.decodeIfPresent(Bool.self, forKey: .nextEpisodeSkipFillerEnabled) ?? NextEpisodeFillerSettings.defaultEnabled
        playerBrightnessGestureEnabled = try container.decodeIfPresent(Bool.self, forKey: .playerBrightnessGestureEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .vlcBrightnessGestureEnabled)
            ?? false
        playerVolumeGestureEnabled = try container.decodeIfPresent(Bool.self, forKey: .playerVolumeGestureEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .vlcVolumeGestureEnabled)
            ?? false
        playerTwoFingerTapPlayPauseEnabled = try container.decodeIfPresent(Bool.self, forKey: .playerTwoFingerTapPlayPauseEnabled) ?? true
        playerCenterTapPlayPauseEnabled = try container.decodeIfPresent(Bool.self, forKey: .playerCenterTapPlayPauseEnabled) ?? true
        playerDoubleTapSeekEnabled = try container.decodeIfPresent(Bool.self, forKey: .playerDoubleTapSeekEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .vlcDoubleTapSeekEnabled)
            ?? true
        playerDoubleTapSeekSeconds = try container.decodeIfPresent(Double.self, forKey: .playerDoubleTapSeekSeconds)
            ?? container.decodeIfPresent(Double.self, forKey: .vlcDoubleTapSeekSeconds)
            ?? 10.0
        playerOpenSubtitlesEnabled = try container.decodeIfPresent(Bool.self, forKey: .playerOpenSubtitlesEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .vlcOpenSubtitlesEnabled)
            ?? false
        playerOpenSubtitlesAutoFallbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .playerOpenSubtitlesAutoFallbackEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .vlcOpenSubtitlesAutoFallbackEnabled)
            ?? true
        playerPerformanceOverlayEnabled = try container.decodeIfPresent(Bool.self, forKey: .playerPerformanceOverlayEnabled) ?? false
        mpvForegroundFPS = Self.sanitizedMPVForegroundFPS(try container.decodeIfPresent(Int.self, forKey: .mpvForegroundFPS) ?? 30)
        mpvRenderBackend = Self.sanitizedMPVRenderBackend(try container.decodeIfPresent(String.self, forKey: .mpvRenderBackend))
        mpvMetalQualityProfile = Self.sanitizedMPVMetalQualityProfile(try container.decodeIfPresent(String.self, forKey: .mpvMetalQualityProfile))
        mpvUpscalingMode = Self.sanitizedMPVUpscalingMode(try container.decodeIfPresent(String.self, forKey: .mpvUpscalingMode))
        mpvPlayerSkin = Self.sanitizedMPVPlayerSkin(try container.decodeIfPresent(String.self, forKey: .mpvPlayerSkin))
        mpvPlayerSkinCustomPrimaryColor = try Self.decodeColorData(from: container, forKey: .mpvPlayerSkinCustomPrimaryColor)
        mpvPlayerSkinCustomSecondaryColor = try Self.decodeColorData(from: container, forKey: .mpvPlayerSkinCustomSecondaryColor)
        mpvPlayerSkinAnimationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .mpvPlayerSkinAnimationsEnabled) ?? MPVPlayerSkinSettings.defaultAnimationsEnabled
        mpvPlayerSkinTintControlsOnly = try container.decodeIfPresent(Bool.self, forKey: .mpvPlayerSkinTintControlsOnly) ?? MPVPlayerSkinSettings.defaultTintControlsOnly
        mpvPictureInPictureEnabled = try container.decodeIfPresent(Bool.self, forKey: .mpvPictureInPictureEnabled) ?? true
        mpvAppExitPictureInPictureEnabled = try container.decodeIfPresent(Bool.self, forKey: .mpvAppExitPictureInPictureEnabled) ?? false
        mpvHDRMode = MPVHDRMode(rawValue: try container.decodeIfPresent(String.self, forKey: .mpvHDRMode) ?? MPVHDRMode.defaultMode.rawValue)?.rawValue ?? MPVHDRMode.defaultMode.rawValue
        mpvSurroundSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .mpvSurroundSoundEnabled) ?? true
        watchTogetherEnabled = try container.decodeIfPresent(Bool.self, forKey: .watchTogetherEnabled) ?? WatchTogetherSettings.defaultEnabled
        smartInAppPlayerChoosingEnabled = try container.decodeIfPresent(Bool.self, forKey: .smartInAppPlayerChoosingEnabled) ?? false
        experimentalFeaturesEnabled = try container.decodeIfPresent(Bool.self, forKey: .experimentalFeaturesEnabled) ?? false
        experimentalFeaturesLastChangedAt = try container.decodeIfPresent(Double.self, forKey: .experimentalFeaturesLastChangedAt) ?? 0
        experimentalMPVPreloadEnabled = try container.decodeIfPresent(Bool.self, forKey: .experimentalMPVPreloadEnabled) ?? true
        experimentalMPVSmoothTransitionEnabled = try container.decodeIfPresent(Bool.self, forKey: .experimentalMPVSmoothTransitionEnabled) ?? true
        experimentalMPVPreloadCellularEnabled = try container.decodeIfPresent(Bool.self, forKey: .experimentalMPVPreloadCellularEnabled) ?? false
        experimentalMPVPreloadWifiLimitMB = ExperimentalFeatureState.resolvedMPVPreloadWifiLimitMB(try container.decodeIfPresent(Int.self, forKey: .experimentalMPVPreloadWifiLimitMB) ?? ExperimentalFeatureState.mpvPreloadWifiDefaultLimitMB)
        experimentalMPVPreloadCellularLimitMB = ExperimentalFeatureState.resolvedMPVPreloadCellularLimitMB(try container.decodeIfPresent(Int.self, forKey: .experimentalMPVPreloadCellularLimitMB) ?? ExperimentalFeatureState.mpvPreloadCellularDefaultLimitMB)
        experimentalMPVShowRemainingTime = try container.decodeIfPresent(Bool.self, forKey: .experimentalMPVShowRemainingTime) ?? true
        experimentalMPVPreciseProgress = try container.decodeIfPresent(Bool.self, forKey: .experimentalMPVPreciseProgress) ?? true
        experimentalMPVIgnoreSpecialSubtitleStyles = try container.decodeIfPresent(Bool.self, forKey: .experimentalMPVIgnoreSpecialSubtitleStyles) ?? false
        experimentalMPVPreloadAutoClear = try container.decodeIfPresent(Bool.self, forKey: .experimentalMPVPreloadAutoClear) ?? true
        experimentalICloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .experimentalICloudSyncEnabled) ?? false

        // Subtitle styling
        subtitleForegroundColor = try Self.decodeColorData(from: container, forKey: .subtitleForegroundColor)
        subtitleStrokeColor = try Self.decodeColorData(from: container, forKey: .subtitleStrokeColor)
        subtitleStrokeWidth = try container.decodeIfPresent(Double.self, forKey: .subtitleStrokeWidth) ?? 1.0
        subtitleFontSize = try container.decodeIfPresent(Double.self, forKey: .subtitleFontSize) ?? 30.0
        subtitleVerticalOffset = try container.decodeIfPresent(Double.self, forKey: .subtitleVerticalOffset) ?? -6.0
        subtitlesVisible = try container.decodeIfPresent(Bool.self, forKey: .subtitlesVisible) ?? false

        // UI preferences
        showKanzen = try container.decodeIfPresent(Bool.self, forKey: .showKanzen) ?? false
        hideSplashScreen = try container.decodeIfPresent(Bool.self, forKey: .hideSplashScreen)
        modeSwitchAnimationEnabled = try container.decodeIfPresent(Bool.self, forKey: .modeSwitchAnimationEnabled) ?? ModeSwitchAnimationSettings.defaultEnabled
        kanzenAutoUpdateModules = try container.decodeIfPresent(Bool.self, forKey: .kanzenAutoUpdateModules) ?? true
        seasonMenu = try container.decodeIfPresent(Bool.self, forKey: .seasonMenu) ?? false
        horizontalEpisodeList = try container.decodeIfPresent(Bool.self, forKey: .horizontalEpisodeList) ?? false
        mediaDetailTitleArtworkEnabled = try container.decodeIfPresent(Bool.self, forKey: .mediaDetailTitleArtworkEnabled) ?? MediaDetailTitleArtworkSettings.defaultEnabled
        mediaDetailSimilarTitlesEnabled = try container.decodeIfPresent(Bool.self, forKey: .mediaDetailSimilarTitlesEnabled) ?? MediaDetailSimilarTitlesSettings.defaultEnabled
        useClassicScheduleUI = try container.decodeIfPresent(Bool.self, forKey: .useClassicScheduleUI) ?? false
        heroBannerCatalogId = Self.sanitizedNonEmptyString(try container.decodeIfPresent(String.self, forKey: .heroBannerCatalogId), defaultValue: "trending")
        homeCatalogLayoutOverrides = try container.decodeIfPresent(String.self, forKey: .homeCatalogLayoutOverrides) ?? ""
        homeAnimatedBackgroundEnabled = try container.decodeIfPresent(Bool.self, forKey: .homeAnimatedBackgroundEnabled)
        homeAnimatedBackgroundQuality = Self.sanitizedHomeAnimatedBackgroundQuality(try container.decodeIfPresent(String.self, forKey: .homeAnimatedBackgroundQuality))
        homeAnimatedBackgroundFrameRate = Self.sanitizedHomeAnimatedBackgroundFrameRate(try container.decodeIfPresent(String.self, forKey: .homeAnimatedBackgroundFrameRate))
        appPerformanceOverlayEnabled = try container.decodeIfPresent(Bool.self, forKey: .appPerformanceOverlayEnabled) ?? AppPerformanceOverlaySettings.defaultEnabled
        heroBannerBehavior = Self.sanitizedHeroBannerBehavior(try container.decodeIfPresent(String.self, forKey: .heroBannerBehavior))
        experimentalMediaDesignPreset = Self.sanitizedExperimentalMediaDesignPreset(try container.decodeIfPresent(String.self, forKey: .experimentalMediaDesignPreset))
        experimentalHeroBleedLevel = Self.sanitizedExperimentalHeroBleedLevel(try container.decodeIfPresent(String.self, forKey: .experimentalHeroBleedLevel))
        experimentalHomeCardShape = Self.sanitizedExperimentalHomeCardShape(try container.decodeIfPresent(String.self, forKey: .experimentalHomeCardShape))
        experimentalMultiGradientPalette = Self.sanitizedExperimentalMultiGradientPalette(try container.decodeIfPresent(String.self, forKey: .experimentalMultiGradientPalette))
        experimentalHeroHeightScale = Self.sanitizedExperimentalHeroHeightScale(try container.decodeIfPresent(Double.self, forKey: .experimentalHeroHeightScale))
        experimentalHeroBleedStrength = Self.sanitizedExperimentalHeroBleedStrength(try container.decodeIfPresent(Double.self, forKey: .experimentalHeroBleedStrength))
        experimentalHeroFadeDistanceScale = Self.sanitizedExperimentalHeroFadeDistanceScale(try container.decodeIfPresent(Double.self, forKey: .experimentalHeroFadeDistanceScale))
        experimentalSectionSpacingScale = Self.sanitizedExperimentalSectionSpacingScale(try container.decodeIfPresent(Double.self, forKey: .experimentalSectionSpacingScale))
        experimentalCardRadiusScale = Self.sanitizedExperimentalCardRadiusScale(try container.decodeIfPresent(Double.self, forKey: .experimentalCardRadiusScale))
        experimentalMediaCardScale = Self.sanitizedExperimentalMediaCardScale(try container.decodeIfPresent(Double.self, forKey: .experimentalMediaCardScale))
        experimentalGlassStrength = Self.sanitizedExperimentalGlassStrength(try container.decodeIfPresent(Double.self, forKey: .experimentalGlassStrength))
        experimentalGradientBaseDarkness = Self.sanitizedExperimentalGradientBaseDarkness(try container.decodeIfPresent(Double.self, forKey: .experimentalGradientBaseDarkness))
        experimentalGradientAccentIntensity = Self.sanitizedExperimentalGradientAccentIntensity(try container.decodeIfPresent(Double.self, forKey: .experimentalGradientAccentIntensity))
        experimentalGradientScrollMotion = Self.sanitizedExperimentalGradientScrollMotion(try container.decodeIfPresent(Double.self, forKey: .experimentalGradientScrollMotion))
        experimentalGradientUseCustomColors = try container.decodeIfPresent(Bool.self, forKey: .experimentalGradientUseCustomColors) ?? false
        experimentalGradientColorA = try Self.decodeColorData(from: container, forKey: .experimentalGradientColorA)
        experimentalGradientColorB = try Self.decodeColorData(from: container, forKey: .experimentalGradientColorB)
        experimentalGradientColorC = try Self.decodeColorData(from: container, forKey: .experimentalGradientColorC)
        atmosphereStyle = Self.sanitizedAtmosphereStyle(try container.decodeIfPresent(String.self, forKey: .atmosphereStyle))
        atmosphereSolidColorSource = Self.sanitizedAtmosphereSolidColorSource(try container.decodeIfPresent(String.self, forKey: .atmosphereSolidColorSource))
        atmosphereSolidColor = try Self.decodeColorData(from: container, forKey: .atmosphereSolidColor)
        readerAtmosphereStyle = Self.sanitizedAtmosphereStyle(
            try container.decodeIfPresent(String.self, forKey: .readerAtmosphereStyle)
                ?? atmosphereStyle
        )
        readerAtmosphereSolidColorSource = Self.sanitizedAtmosphereSolidColorSource(
            try container.decodeIfPresent(String.self, forKey: .readerAtmosphereSolidColorSource)
                ?? atmosphereSolidColorSource
        )
        readerAtmosphereSolidColor = try Self.decodeColorData(from: container, forKey: .readerAtmosphereSolidColor)
        mediaDetailElementOrder = Self.sanitizedMediaDetailElementOrder(try container.decodeIfPresent(String.self, forKey: .mediaDetailElementOrder))
        mediaDetailHiddenElements = Self.sanitizedMediaDetailHiddenElements(try container.decodeIfPresent(String.self, forKey: .mediaDetailHiddenElements))
        readerDetailElementOrder = Self.sanitizedReaderDetailElementOrder(try container.decodeIfPresent(String.self, forKey: .readerDetailElementOrder))
        readerDetailHiddenElements = Self.sanitizedReaderDetailHiddenElements(try container.decodeIfPresent(String.self, forKey: .readerDetailHiddenElements))
        mediaColumnsPortrait = try container.decodeIfPresent(Int.self, forKey: .mediaColumnsPortrait) ?? 3
        mediaColumnsLandscape = try container.decodeIfPresent(Int.self, forKey: .mediaColumnsLandscape) ?? 5

        // Manga / Reader
        readingMode = try container.decodeIfPresent(Int.self, forKey: .readingMode) ?? 2
        if let decodedKanzenReaderMode = try container.decodeIfPresent(String.self, forKey: .kanzenReaderMode) {
            kanzenReaderMode = Self.sanitizedKanzenReaderMode(decodedKanzenReaderMode)
        } else {
            kanzenReaderMode = Self.kanzenReaderModeRawValue(forReadingMode: readingMode)
        }
        kanzenReaderModeOverrides = Self.sanitizedKanzenReaderModeOverrides(try container.decodeIfPresent([String: String].self, forKey: .kanzenReaderModeOverrides))
        readerDownsampleImages = try container.decodeIfPresent(Bool.self, forKey: .readerDownsampleImages) ?? true
        readerCropBorders = try container.decodeIfPresent(Bool.self, forKey: .readerCropBorders) ?? false
        readerDisableQuickActions = try container.decodeIfPresent(Bool.self, forKey: .readerDisableQuickActions) ?? false
        readerDisableDoubleTap = try container.decodeIfPresent(Bool.self, forKey: .readerDisableDoubleTap) ?? false
        readerLiveText = try container.decodeIfPresent(Bool.self, forKey: .readerLiveText) ?? false
        readerHideBarsOnSwipe = try container.decodeIfPresent(Bool.self, forKey: .readerHideBarsOnSwipe) ?? false
        readerBackgroundColor = Self.sanitizedReaderBackgroundColor(try container.decodeIfPresent(String.self, forKey: .readerBackgroundColor))
        readerOrientation = Self.sanitizedReaderOrientation(try container.decodeIfPresent(String.self, forKey: .readerOrientation))
        readerTapZones = Self.sanitizedReaderTapZones(try container.decodeIfPresent(String.self, forKey: .readerTapZones))
        readerInvertTapZones = try container.decodeIfPresent(Bool.self, forKey: .readerInvertTapZones) ?? false
        readerAnimatePageTransitions = try container.decodeIfPresent(Bool.self, forKey: .readerAnimatePageTransitions) ?? true
        readerUpscaleImages = try container.decodeIfPresent(Bool.self, forKey: .readerUpscaleImages) ?? false
        readerUpscaleMaxHeight = Self.sanitizedReaderUpscaleMaxHeight(try container.decodeIfPresent(Int.self, forKey: .readerUpscaleMaxHeight))
        readerUpscaleModelName = try container.decodeIfPresent(String.self, forKey: .readerUpscaleModelName) ?? "None"
        readerPagesToPreload = Self.sanitizedReaderPagesToPreload(try container.decodeIfPresent(Int.self, forKey: .readerPagesToPreload))
        readerPagedPageLayout = Self.sanitizedReaderPagedPageLayout(try container.decodeIfPresent(String.self, forKey: .readerPagedPageLayout))
        readerPagedPageOffset = try container.decodeIfPresent(Bool.self, forKey: .readerPagedPageOffset) ?? false
        readerPagedPageOffsetOverrides = Self.sanitizedReaderPagedPageOffsetOverrides(try container.decodeIfPresent([String: Bool].self, forKey: .readerPagedPageOffsetOverrides))
        readerSplitWideImages = try container.decodeIfPresent(Bool.self, forKey: .readerSplitWideImages) ?? false
        readerReverseSplitOrder = try container.decodeIfPresent(Bool.self, forKey: .readerReverseSplitOrder) ?? false
        readerVerticalInfiniteScroll = try container.decodeIfPresent(Bool.self, forKey: .readerVerticalInfiniteScroll) ?? true
        readerPillarbox = try container.decodeIfPresent(Bool.self, forKey: .readerPillarbox) ?? false
        readerPillarboxAmount = Self.sanitizedReaderPillarboxAmount(try container.decodeIfPresent(Double.self, forKey: .readerPillarboxAmount))
        readerPillarboxOrientation = Self.sanitizedReaderPillarboxOrientation(try container.decodeIfPresent(String.self, forKey: .readerPillarboxOrientation))
        readerOrientationLockEnabled = try container.decodeIfPresent(Bool.self, forKey: .readerOrientationLockEnabled) ?? false
        readerOrientationLockMask = Self.sanitizedReaderOrientationLockMask(try container.decodeIfPresent(String.self, forKey: .readerOrientationLockMask))
        readerReadThresholdPercent = Self.sanitizedReaderReadThresholdPercent(try container.decodeIfPresent(Double.self, forKey: .readerReadThresholdPercent))

        // Novel Reader
        readerFontSize = try container.decodeIfPresent(Double.self, forKey: .readerFontSize) ?? 16
        readerFontFamily = try container.decodeIfPresent(String.self, forKey: .readerFontFamily) ?? "-apple-system"
        readerFontWeight = try container.decodeIfPresent(String.self, forKey: .readerFontWeight) ?? "normal"
        readerColorPreset = try container.decodeIfPresent(Int.self, forKey: .readerColorPreset) ?? 0
        readerTextAlignment = try container.decodeIfPresent(String.self, forKey: .readerTextAlignment) ?? "left"
        readerLineSpacing = try container.decodeIfPresent(Double.self, forKey: .readerLineSpacing) ?? 1.6
        readerMargin = try container.decodeIfPresent(Double.self, forKey: .readerMargin) ?? 4

        // Other
        autoClearCacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoClearCacheEnabled) ?? false
        autoClearCacheThresholdMB = try container.decodeIfPresent(Double.self, forKey: .autoClearCacheThresholdMB) ?? 500
        highQualityThreshold = try container.decodeIfPresent(Double.self, forKey: .highQualityThreshold) ?? 0.9
        backgroundHLSPipelineEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundHLSPipelineEnabled) ?? false
        readerDownloadsBackgroundEnabled = try container.decodeIfPresent(Bool.self, forKey: .readerDownloadsBackgroundEnabled) ?? true
        readerDownloadsWifiOnly = try container.decodeIfPresent(Bool.self, forKey: .readerDownloadsWifiOnly) ?? false
        readerDownloadsParallelLimit = Self.sanitizedReaderDownloadsParallelLimit(try container.decodeIfPresent(Int.self, forKey: .readerDownloadsParallelLimit))
        autoUpdateServicesEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateServicesEnabled) ?? true
        servicesAutoModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .servicesAutoModeEnabled) ?? false
        servicesAutoSelectEpisodesEnabled = try container.decodeIfPresent(Bool.self, forKey: .servicesAutoSelectEpisodesEnabled) ?? false
        servicesAutoModeSourceIds = Self.sanitizedStringList(try container.decodeIfPresent([String].self, forKey: .servicesAutoModeSourceIds))
        servicesAutoModeSourceOrderIds = Self.sanitizedStringList(try container.decodeIfPresent([String].self, forKey: .servicesAutoModeSourceOrderIds))
        servicesAutoModeQualityPreference = AutoModeQualityPreference.sanitizedRawValue(try container.decodeIfPresent(String.self, forKey: .servicesAutoModeQualityPreference))
        servicesResultMinimumSimilarity = Self.sanitizedServicesResultMinimumSimilarity(try container.decodeIfPresent(Double.self, forKey: .servicesResultMinimumSimilarity))
        servicesDropMismatchedResults = try container.decodeIfPresent(Bool.self, forKey: .servicesDropMismatchedResults) ?? ServicesResultRankingSettings.defaultDropMismatchedResults
        servicesStremioStyleSheetEnabled = try container.decodeIfPresent(Bool.self, forKey: .servicesStremioStyleSheetEnabled) ?? ServicesSheetPresentationSettings.defaultStremioStyleEnabled
        servicesIncludedStreamLanguages = StreamLanguageFilter.sanitizedLanguageList(try container.decodeIfPresent([String].self, forKey: .servicesIncludedStreamLanguages) ?? [])
        servicesHiddenStreamLanguages = StreamLanguageFilter.sanitizedLanguageList(try container.decodeIfPresent([String].self, forKey: .servicesHiddenStreamLanguages) ?? [])
        servicesHideStreamsWithoutLanguageData = try container.decodeIfPresent(Bool.self, forKey: .servicesHideStreamsWithoutLanguageData) ?? false
        servicesAssumeOriginalAudio = try container.decodeIfPresent(Bool.self, forKey: .servicesAssumeOriginalAudio) ?? false
        servicesTreatDubbedAnimeAsEnglish = try container.decodeIfPresent(Bool.self, forKey: .servicesTreatDubbedAnimeAsEnglish) ?? false
        servicesHiddenStreamQualities = StreamLanguageFilter.sanitizedQualityHeights(try container.decodeIfPresent([Int].self, forKey: .servicesHiddenStreamQualities) ?? [])
        servicesHideStreamsWithoutDetectedQuality = try container.decodeIfPresent(Bool.self, forKey: .servicesHideStreamsWithoutDetectedQuality) ?? false
        if let decodedSourceIds = try container.decodeIfPresent([String].self, forKey: .servicesExtraRulesSourceIds) {
            servicesExtraRulesSourceIds = StreamLanguageFilter.sanitizedExtraRulesSourceIds(decodedSourceIds)
        } else {
            servicesExtraRulesSourceIds = nil
        }
        githubReleaseAutoCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .githubReleaseAutoCheckEnabled) ?? true
        githubReleaseUpdateAvailable = try container.decodeIfPresent(Bool.self, forKey: .githubReleaseUpdateAvailable) ?? false
        githubReleaseLatestVersion = try container.decodeIfPresent(String.self, forKey: .githubReleaseLatestVersion) ?? ""
        githubReleaseURL = try container.decodeIfPresent(String.self, forKey: .githubReleaseURL) ?? ""
        githubReleaseShowAlertPending = try container.decodeIfPresent(Bool.self, forKey: .githubReleaseShowAlertPending) ?? false
        githubReleaseLastPromptedVersion = try container.decodeIfPresent(String.self, forKey: .githubReleaseLastPromptedVersion) ?? ""
        filterHorrorContent = try container.decodeIfPresent(Bool.self, forKey: .filterHorrorContent) ?? false
        selectedSimilarityAlgorithm = Self.sanitizedSimilarityAlgorithm(try container.decodeIfPresent(String.self, forKey: .selectedSimilarityAlgorithm))
        performanceModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .performanceModeEnabled) ?? PerformanceModeSettings.defaultEnabled
        performanceModeSkipAniListTraversalForAnimeDetails = try container.decodeIfPresent(Bool.self, forKey: .performanceModeSkipAniListTraversalForAnimeDetails) ?? false
        let decodedPerformanceOverrides = try container.decodeIfPresent([String: Bool].self, forKey: .performanceModeFastAnimeCatalogOverrides) ?? [:]
        performanceModeFastAnimeCatalogOverrides = decodedPerformanceOverrides.filter { PerformanceModeSettings.animeCatalogIds.contains($0.key) }
        kanzenHomeSelectedSourceID = try container.decodeIfPresent(String.self, forKey: .kanzenHomeSelectedSourceID) ?? ""
        kanzenRecentSourceSearches = try container.decodeIfPresent([String].self, forKey: .kanzenRecentSourceSearches) ?? []

        collections = try container.decodeIfPresent([BackupCollection].self, forKey: .collections) ?? []
        progressData = try container.decodeIfPresent(ProgressData.self, forKey: .progressData) ?? ProgressData()
        trackerState = try container.decodeIfPresent(TrackerState.self, forKey: .trackerState) ?? TrackerState()
        catalogs = try container.decodeIfPresent([Catalog].self, forKey: .catalogs) ?? []
        services = try container.decodeIfPresent([BackupService].self, forKey: .services) ?? []
        stremioAddons = try container.decodeIfPresent([BackupStremioAddon].self, forKey: .stremioAddons)
        mangaCollections = try container.decodeIfPresent([BackupMangaCollection].self, forKey: .mangaCollections) ?? []
        mangaReadingProgress = try container.decodeIfPresent([String: MangaProgress].self, forKey: .mangaReadingProgress) ?? [:]
        mangaCatalogs = try container.decodeIfPresent([MangaCatalog].self, forKey: .mangaCatalogs) ?? []
        kanzenModules = try container.decodeIfPresent([BackupKanzenModule].self, forKey: .kanzenModules) ?? []
        aidokuState = try container.decodeIfPresent(BackupAidokuState.self, forKey: .aidokuState)
        searchHistory = try container.decodeIfPresent(BackupSearchHistory.self, forKey: .searchHistory) ?? BackupSearchHistory()
        recommendationCache = try container.decodeIfPresent([TMDBSearchResult].self, forKey: .recommendationCache) ?? []
        userRatings = Self.decodeUserRatings(from: container)
        userRatingNotes = try container.decodeIfPresent([String: String].self, forKey: .userRatingNotes) ?? [:]
        mediaStateSettings = try container.decodeIfPresent([String: Data].self, forKey: .mediaStateSettings)
        hasMangaCollections = container.contains(.mangaCollections)
        hasMangaReadingProgress = container.contains(.mangaReadingProgress)
        hasMangaCatalogs = container.contains(.mangaCatalogs)
        hasKanzenModules = container.contains(.kanzenModules)
        hasUserRatings = container.contains(.userRatings) || container.contains(.userRatingNotes)
    }

    static func decodeColorData(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Data? {
        if let data = try? container.decodeIfPresent(Data.self, forKey: key) {
            return data
        }
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return backupColorData(from: string)
        }
        return nil
    }

    static func backupColorData(from value: Any?) -> Data? {
        if let data = value as? Data {
            return data
        }
        guard let string = value as? String else {
            return nil
        }
        if let colorData = archivedColorData(fromHexString: string) {
            return colorData
        }
        return Data(base64Encoded: string)
    }

    private static func archivedColorData(fromHexString rawValue: String) -> Data? {
        let raw = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        guard raw.count == 6 || raw.count == 8, raw.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        let scanner = Scanner(string: raw)
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value) else {
            return nil
        }
        let alpha: CGFloat
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        if raw.count == 8 {
            alpha = CGFloat((value >> 24) & 0xFF) / 255.0
            red = CGFloat((value >> 16) & 0xFF) / 255.0
            green = CGFloat((value >> 8) & 0xFF) / 255.0
            blue = CGFloat(value & 0xFF) / 255.0
        } else {
            alpha = 1.0
            red = CGFloat((value >> 16) & 0xFF) / 255.0
            green = CGFloat((value >> 8) & 0xFF) / 255.0
            blue = CGFloat(value & 0xFF) / 255.0
        }
        let color = UIColor(red: red, green: green, blue: blue, alpha: alpha)
        return try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(createdDate, forKey: .createdDate)
        try container.encodeIfPresent(accentColor, forKey: .accentColor)
        try container.encodeIfPresent(settingsGradientColor, forKey: .settingsGradientColor)
        try container.encodeIfPresent(readerAccentColor, forKey: .readerAccentColor)
        try container.encode(tmdbLanguage, forKey: .tmdbLanguage)
        try container.encode(Self.sanitizedAppearance(selectedAppearance), forKey: .selectedAppearance)
        try container.encode(Self.sanitizedAppearance(readerSelectedAppearance), forKey: .readerSelectedAppearance)
        try container.encode(readerGlobalAppearanceEnabled, forKey: .readerGlobalAppearanceEnabled)
        try container.encodeIfPresent(readerSettingsGradientColor, forKey: .readerSettingsGradientColor)
        try container.encode(enableSubtitlesByDefault, forKey: .enableSubtitlesByDefault)
        try container.encode(defaultSubtitleLanguage, forKey: .defaultSubtitleLanguage)
        try container.encode(playerSubtitleAppearanceEnabled, forKey: .playerSubtitleAppearanceEnabled)

        try container.encode(preferredAutoAudioLanguage, forKey: .preferredAutoAudioLanguage)
        try container.encode(preferredAnimeAudioLanguage, forKey: .preferredAnimeAudioLanguage)
        try container.encode(inAppPlayer, forKey: .inAppPlayer)
        try container.encode(showScheduleTab, forKey: .showScheduleTab)
        try container.encode(showLocalScheduleTime, forKey: .showLocalScheduleTime)
        try container.encode(ScheduleMode.sanitizedRawValue(defaultScheduleMode), forKey: .defaultScheduleMode)
        try container.encode(ScheduleWindow.sanitizedDays(scheduleWindowDays), forKey: .scheduleWindowDays)
        try container.encodeIfPresent(localNotificationSubscriptions, forKey: .localNotificationSubscriptions)
        try container.encodeIfPresent(localNotificationEpisodeReminders, forKey: .localNotificationEpisodeReminders)
        try container.encodeIfPresent(localNotificationEpisodeLeadTime, forKey: .localNotificationEpisodeLeadTime)
        try container.encodeIfPresent(localNotificationSeasonLeadTime, forKey: .localNotificationSeasonLeadTime)
        try container.encodeIfPresent(localNotificationIncludeAnimeSpecials, forKey: .localNotificationIncludeAnimeSpecials)

        // Player settings
        try container.encode(defaultPlaybackSpeed, forKey: .defaultPlaybackSpeed)
        try container.encode(holdSpeedPlayer, forKey: .holdSpeedPlayer)
        try container.encode(externalPlayer, forKey: .externalPlayer)
        try container.encode(preferDownloadedMedia, forKey: .preferDownloadedMedia)
        try container.encode(alwaysLandscape, forKey: .alwaysLandscape)
        try container.encode(playerPlaybackLockEnabled, forKey: .playerPlaybackLockEnabled)
        try container.encode(aniSkipEnabled, forKey: .aniSkipEnabled)
        try container.encode(introDBEnabled, forKey: .introDBEnabled)
        try container.encode(introDBAppEnabled, forKey: .introDBAppEnabled)
        try container.encode(aniSkipAutoSkip, forKey: .aniSkipAutoSkip)
        try container.encode(skip85sEnabled, forKey: .skip85sEnabled)
        try container.encode(skip85sAlwaysVisible, forKey: .skip85sAlwaysVisible)
        try container.encode(showNextEpisodeButton, forKey: .showNextEpisodeButton)
        try container.encode(showEpisodeBrowserButton, forKey: .showEpisodeBrowserButton)
        try container.encode(showPlayerServicesButton, forKey: .showPlayerServicesButton)
        try container.encode(showNextEpisodePosterButton, forKey: .showNextEpisodePosterButton)
        try container.encode(nextEpisodeThreshold, forKey: .nextEpisodeThreshold)
        try container.encode(nextEpisodeSkipFillerEnabled, forKey: .nextEpisodeSkipFillerEnabled)
        try container.encode(playerBrightnessGestureEnabled, forKey: .playerBrightnessGestureEnabled)
        try container.encode(playerVolumeGestureEnabled, forKey: .playerVolumeGestureEnabled)
        try container.encode(playerTwoFingerTapPlayPauseEnabled, forKey: .playerTwoFingerTapPlayPauseEnabled)
        try container.encode(playerCenterTapPlayPauseEnabled, forKey: .playerCenterTapPlayPauseEnabled)
        try container.encode(playerDoubleTapSeekEnabled, forKey: .playerDoubleTapSeekEnabled)
        try container.encode(playerDoubleTapSeekSeconds, forKey: .playerDoubleTapSeekSeconds)
        try container.encode(playerOpenSubtitlesEnabled, forKey: .playerOpenSubtitlesEnabled)
        try container.encode(playerOpenSubtitlesAutoFallbackEnabled, forKey: .playerOpenSubtitlesAutoFallbackEnabled)
        try container.encode(playerPerformanceOverlayEnabled, forKey: .playerPerformanceOverlayEnabled)
        try container.encode(mpvForegroundFPS, forKey: .mpvForegroundFPS)
        try container.encode(mpvRenderBackend, forKey: .mpvRenderBackend)
        try container.encode(mpvMetalQualityProfile, forKey: .mpvMetalQualityProfile)
        try container.encode(mpvUpscalingMode, forKey: .mpvUpscalingMode)
        try container.encode(Self.sanitizedMPVPlayerSkin(mpvPlayerSkin), forKey: .mpvPlayerSkin)
        try container.encodeIfPresent(mpvPlayerSkinCustomPrimaryColor, forKey: .mpvPlayerSkinCustomPrimaryColor)
        try container.encodeIfPresent(mpvPlayerSkinCustomSecondaryColor, forKey: .mpvPlayerSkinCustomSecondaryColor)
        try container.encode(mpvPlayerSkinAnimationsEnabled, forKey: .mpvPlayerSkinAnimationsEnabled)
        try container.encode(mpvPlayerSkinTintControlsOnly, forKey: .mpvPlayerSkinTintControlsOnly)
        try container.encode(mpvPictureInPictureEnabled, forKey: .mpvPictureInPictureEnabled)
        try container.encode(mpvAppExitPictureInPictureEnabled, forKey: .mpvAppExitPictureInPictureEnabled)
        try container.encode(mpvHDRMode, forKey: .mpvHDRMode)
        try container.encode(mpvSurroundSoundEnabled, forKey: .mpvSurroundSoundEnabled)
        try container.encode(watchTogetherEnabled, forKey: .watchTogetherEnabled)
        try container.encode(smartInAppPlayerChoosingEnabled, forKey: .smartInAppPlayerChoosingEnabled)
        try container.encode(experimentalFeaturesEnabled, forKey: .experimentalFeaturesEnabled)
        try container.encode(experimentalFeaturesLastChangedAt, forKey: .experimentalFeaturesLastChangedAt)
        try container.encode(experimentalMPVPreloadEnabled, forKey: .experimentalMPVPreloadEnabled)
        try container.encode(experimentalMPVSmoothTransitionEnabled, forKey: .experimentalMPVSmoothTransitionEnabled)
        try container.encode(experimentalMPVPreloadCellularEnabled, forKey: .experimentalMPVPreloadCellularEnabled)
        try container.encode(ExperimentalFeatureState.clampedMPVPreloadWifiLimitMB(experimentalMPVPreloadWifiLimitMB), forKey: .experimentalMPVPreloadWifiLimitMB)
        try container.encode(ExperimentalFeatureState.clampedMPVPreloadCellularLimitMB(experimentalMPVPreloadCellularLimitMB), forKey: .experimentalMPVPreloadCellularLimitMB)
        try container.encode(experimentalMPVShowRemainingTime, forKey: .experimentalMPVShowRemainingTime)
        try container.encode(experimentalMPVPreciseProgress, forKey: .experimentalMPVPreciseProgress)
        try container.encode(experimentalMPVIgnoreSpecialSubtitleStyles, forKey: .experimentalMPVIgnoreSpecialSubtitleStyles)
        try container.encode(experimentalMPVPreloadAutoClear, forKey: .experimentalMPVPreloadAutoClear)
        try container.encode(experimentalICloudSyncEnabled, forKey: .experimentalICloudSyncEnabled)

        // Subtitle styling
        try container.encodeIfPresent(subtitleForegroundColor, forKey: .subtitleForegroundColor)
        try container.encodeIfPresent(subtitleStrokeColor, forKey: .subtitleStrokeColor)
        try container.encode(subtitleStrokeWidth, forKey: .subtitleStrokeWidth)
        try container.encode(subtitleFontSize, forKey: .subtitleFontSize)
        try container.encode(subtitleVerticalOffset, forKey: .subtitleVerticalOffset)
        try container.encode(subtitlesVisible, forKey: .subtitlesVisible)

        // UI preferences
        try container.encode(showKanzen, forKey: .showKanzen)
        try container.encodeIfPresent(hideSplashScreen, forKey: .hideSplashScreen)
        try container.encode(modeSwitchAnimationEnabled, forKey: .modeSwitchAnimationEnabled)
        try container.encode(kanzenAutoUpdateModules, forKey: .kanzenAutoUpdateModules)
        try container.encode(seasonMenu, forKey: .seasonMenu)
        try container.encode(horizontalEpisodeList, forKey: .horizontalEpisodeList)
        try container.encode(mediaDetailTitleArtworkEnabled, forKey: .mediaDetailTitleArtworkEnabled)
        try container.encode(mediaDetailSimilarTitlesEnabled, forKey: .mediaDetailSimilarTitlesEnabled)
        try container.encode(useClassicScheduleUI, forKey: .useClassicScheduleUI)
        try container.encode(heroBannerCatalogId, forKey: .heroBannerCatalogId)
        try container.encode(homeCatalogLayoutOverrides, forKey: .homeCatalogLayoutOverrides)
        try container.encodeIfPresent(homeAnimatedBackgroundEnabled, forKey: .homeAnimatedBackgroundEnabled)
        try container.encode(Self.sanitizedHomeAnimatedBackgroundQuality(homeAnimatedBackgroundQuality), forKey: .homeAnimatedBackgroundQuality)
        try container.encode(Self.sanitizedHomeAnimatedBackgroundFrameRate(homeAnimatedBackgroundFrameRate), forKey: .homeAnimatedBackgroundFrameRate)
        try container.encode(appPerformanceOverlayEnabled, forKey: .appPerformanceOverlayEnabled)
        try container.encode(Self.sanitizedHeroBannerBehavior(heroBannerBehavior), forKey: .heroBannerBehavior)
        try container.encode(Self.sanitizedExperimentalMediaDesignPreset(experimentalMediaDesignPreset), forKey: .experimentalMediaDesignPreset)
        try container.encode(Self.sanitizedExperimentalHeroBleedLevel(experimentalHeroBleedLevel), forKey: .experimentalHeroBleedLevel)
        try container.encode(Self.sanitizedExperimentalHomeCardShape(experimentalHomeCardShape), forKey: .experimentalHomeCardShape)
        try container.encode(Self.sanitizedExperimentalMultiGradientPalette(experimentalMultiGradientPalette), forKey: .experimentalMultiGradientPalette)
        try container.encode(Self.sanitizedExperimentalHeroHeightScale(experimentalHeroHeightScale), forKey: .experimentalHeroHeightScale)
        try container.encode(Self.sanitizedExperimentalHeroBleedStrength(experimentalHeroBleedStrength), forKey: .experimentalHeroBleedStrength)
        try container.encode(Self.sanitizedExperimentalHeroFadeDistanceScale(experimentalHeroFadeDistanceScale), forKey: .experimentalHeroFadeDistanceScale)
        try container.encode(Self.sanitizedExperimentalSectionSpacingScale(experimentalSectionSpacingScale), forKey: .experimentalSectionSpacingScale)
        try container.encode(Self.sanitizedExperimentalCardRadiusScale(experimentalCardRadiusScale), forKey: .experimentalCardRadiusScale)
        try container.encode(Self.sanitizedExperimentalMediaCardScale(experimentalMediaCardScale), forKey: .experimentalMediaCardScale)
        try container.encode(Self.sanitizedExperimentalGlassStrength(experimentalGlassStrength), forKey: .experimentalGlassStrength)
        try container.encode(Self.sanitizedExperimentalGradientBaseDarkness(experimentalGradientBaseDarkness), forKey: .experimentalGradientBaseDarkness)
        try container.encode(Self.sanitizedExperimentalGradientAccentIntensity(experimentalGradientAccentIntensity), forKey: .experimentalGradientAccentIntensity)
        try container.encode(Self.sanitizedExperimentalGradientScrollMotion(experimentalGradientScrollMotion), forKey: .experimentalGradientScrollMotion)
        try container.encode(experimentalGradientUseCustomColors, forKey: .experimentalGradientUseCustomColors)
        try container.encodeIfPresent(experimentalGradientColorA, forKey: .experimentalGradientColorA)
        try container.encodeIfPresent(experimentalGradientColorB, forKey: .experimentalGradientColorB)
        try container.encodeIfPresent(experimentalGradientColorC, forKey: .experimentalGradientColorC)
        try container.encode(Self.sanitizedAtmosphereStyle(atmosphereStyle), forKey: .atmosphereStyle)
        try container.encode(Self.sanitizedAtmosphereSolidColorSource(atmosphereSolidColorSource), forKey: .atmosphereSolidColorSource)
        try container.encodeIfPresent(atmosphereSolidColor, forKey: .atmosphereSolidColor)
        try container.encode(Self.sanitizedAtmosphereStyle(readerAtmosphereStyle), forKey: .readerAtmosphereStyle)
        try container.encode(Self.sanitizedAtmosphereSolidColorSource(readerAtmosphereSolidColorSource), forKey: .readerAtmosphereSolidColorSource)
        try container.encodeIfPresent(readerAtmosphereSolidColor, forKey: .readerAtmosphereSolidColor)
        try container.encode(Self.sanitizedMediaDetailElementOrder(mediaDetailElementOrder), forKey: .mediaDetailElementOrder)
        try container.encode(Self.sanitizedMediaDetailHiddenElements(mediaDetailHiddenElements), forKey: .mediaDetailHiddenElements)
        try container.encode(Self.sanitizedReaderDetailElementOrder(readerDetailElementOrder), forKey: .readerDetailElementOrder)
        try container.encode(Self.sanitizedReaderDetailHiddenElements(readerDetailHiddenElements), forKey: .readerDetailHiddenElements)
        try container.encode(mediaColumnsPortrait, forKey: .mediaColumnsPortrait)
        try container.encode(mediaColumnsLandscape, forKey: .mediaColumnsLandscape)

        // Manga / Reader
        try container.encode(readingMode, forKey: .readingMode)
        try container.encode(Self.sanitizedKanzenReaderMode(kanzenReaderMode), forKey: .kanzenReaderMode)
        try container.encode(Self.sanitizedKanzenReaderModeOverrides(kanzenReaderModeOverrides), forKey: .kanzenReaderModeOverrides)
        try container.encode(readerDownsampleImages, forKey: .readerDownsampleImages)
        try container.encode(readerCropBorders, forKey: .readerCropBorders)
        try container.encode(readerDisableQuickActions, forKey: .readerDisableQuickActions)
        try container.encode(readerDisableDoubleTap, forKey: .readerDisableDoubleTap)
        try container.encode(readerLiveText, forKey: .readerLiveText)
        try container.encode(readerHideBarsOnSwipe, forKey: .readerHideBarsOnSwipe)
        try container.encode(Self.sanitizedReaderBackgroundColor(readerBackgroundColor), forKey: .readerBackgroundColor)
        try container.encode(Self.sanitizedReaderOrientation(readerOrientation), forKey: .readerOrientation)
        try container.encode(Self.sanitizedReaderTapZones(readerTapZones), forKey: .readerTapZones)
        try container.encode(readerInvertTapZones, forKey: .readerInvertTapZones)
        try container.encode(readerAnimatePageTransitions, forKey: .readerAnimatePageTransitions)
        try container.encode(readerUpscaleImages, forKey: .readerUpscaleImages)
        try container.encode(Self.sanitizedReaderUpscaleMaxHeight(readerUpscaleMaxHeight), forKey: .readerUpscaleMaxHeight)
        try container.encode(readerUpscaleModelName, forKey: .readerUpscaleModelName)
        try container.encode(Self.sanitizedReaderPagesToPreload(readerPagesToPreload), forKey: .readerPagesToPreload)
        try container.encode(Self.sanitizedReaderPagedPageLayout(readerPagedPageLayout), forKey: .readerPagedPageLayout)
        try container.encode(readerPagedPageOffset, forKey: .readerPagedPageOffset)
        try container.encode(Self.sanitizedReaderPagedPageOffsetOverrides(readerPagedPageOffsetOverrides), forKey: .readerPagedPageOffsetOverrides)
        try container.encode(readerSplitWideImages, forKey: .readerSplitWideImages)
        try container.encode(readerReverseSplitOrder, forKey: .readerReverseSplitOrder)
        try container.encode(readerVerticalInfiniteScroll, forKey: .readerVerticalInfiniteScroll)
        try container.encode(readerPillarbox, forKey: .readerPillarbox)
        try container.encode(Self.sanitizedReaderPillarboxAmount(readerPillarboxAmount), forKey: .readerPillarboxAmount)
        try container.encode(Self.sanitizedReaderPillarboxOrientation(readerPillarboxOrientation), forKey: .readerPillarboxOrientation)
        try container.encode(readerOrientationLockEnabled, forKey: .readerOrientationLockEnabled)
        try container.encode(Self.sanitizedReaderOrientationLockMask(readerOrientationLockMask), forKey: .readerOrientationLockMask)
        try container.encode(readerReadThresholdPercent, forKey: .readerReadThresholdPercent)

        // Novel Reader
        try container.encode(readerFontSize, forKey: .readerFontSize)
        try container.encode(readerFontFamily, forKey: .readerFontFamily)
        try container.encode(readerFontWeight, forKey: .readerFontWeight)
        try container.encode(readerColorPreset, forKey: .readerColorPreset)
        try container.encode(readerTextAlignment, forKey: .readerTextAlignment)
        try container.encode(readerLineSpacing, forKey: .readerLineSpacing)
        try container.encode(readerMargin, forKey: .readerMargin)

        // Other
        try container.encode(autoClearCacheEnabled, forKey: .autoClearCacheEnabled)
        try container.encode(autoClearCacheThresholdMB, forKey: .autoClearCacheThresholdMB)
        try container.encode(highQualityThreshold, forKey: .highQualityThreshold)
        try container.encode(backgroundHLSPipelineEnabled, forKey: .backgroundHLSPipelineEnabled)
        try container.encode(readerDownloadsBackgroundEnabled, forKey: .readerDownloadsBackgroundEnabled)
        try container.encode(readerDownloadsWifiOnly, forKey: .readerDownloadsWifiOnly)
        try container.encode(Self.sanitizedReaderDownloadsParallelLimit(readerDownloadsParallelLimit), forKey: .readerDownloadsParallelLimit)
        try container.encode(autoUpdateServicesEnabled, forKey: .autoUpdateServicesEnabled)
        try container.encode(servicesAutoModeEnabled, forKey: .servicesAutoModeEnabled)
        try container.encode(servicesAutoSelectEpisodesEnabled, forKey: .servicesAutoSelectEpisodesEnabled)
        try container.encode(Self.sanitizedStringList(servicesAutoModeSourceIds), forKey: .servicesAutoModeSourceIds)
        try container.encode(Self.sanitizedStringList(servicesAutoModeSourceOrderIds), forKey: .servicesAutoModeSourceOrderIds)
        try container.encode(AutoModeQualityPreference.sanitizedRawValue(servicesAutoModeQualityPreference), forKey: .servicesAutoModeQualityPreference)
        try container.encode(Self.sanitizedServicesResultMinimumSimilarity(servicesResultMinimumSimilarity), forKey: .servicesResultMinimumSimilarity)
        try container.encode(servicesDropMismatchedResults, forKey: .servicesDropMismatchedResults)
        try container.encode(servicesStremioStyleSheetEnabled, forKey: .servicesStremioStyleSheetEnabled)
        try container.encode(StreamLanguageFilter.sanitizedLanguageList(servicesIncludedStreamLanguages), forKey: .servicesIncludedStreamLanguages)
        try container.encode(StreamLanguageFilter.sanitizedLanguageList(servicesHiddenStreamLanguages), forKey: .servicesHiddenStreamLanguages)
        try container.encode(servicesHideStreamsWithoutLanguageData, forKey: .servicesHideStreamsWithoutLanguageData)
        try container.encode(servicesAssumeOriginalAudio, forKey: .servicesAssumeOriginalAudio)
        try container.encode(servicesTreatDubbedAnimeAsEnglish, forKey: .servicesTreatDubbedAnimeAsEnglish)
        try container.encode(StreamLanguageFilter.sanitizedQualityHeights(servicesHiddenStreamQualities), forKey: .servicesHiddenStreamQualities)
        try container.encode(servicesHideStreamsWithoutDetectedQuality, forKey: .servicesHideStreamsWithoutDetectedQuality)
        if let servicesExtraRulesSourceIds {
            try container.encode(
                StreamLanguageFilter.sanitizedExtraRulesSourceIds(servicesExtraRulesSourceIds),
                forKey: .servicesExtraRulesSourceIds
            )
        }
        try container.encode(githubReleaseAutoCheckEnabled, forKey: .githubReleaseAutoCheckEnabled)
        try container.encode(githubReleaseUpdateAvailable, forKey: .githubReleaseUpdateAvailable)
        try container.encode(githubReleaseLatestVersion, forKey: .githubReleaseLatestVersion)
        try container.encode(githubReleaseURL, forKey: .githubReleaseURL)
        try container.encode(githubReleaseShowAlertPending, forKey: .githubReleaseShowAlertPending)
        try container.encode(githubReleaseLastPromptedVersion, forKey: .githubReleaseLastPromptedVersion)
        try container.encode(filterHorrorContent, forKey: .filterHorrorContent)
        try container.encode(Self.sanitizedSimilarityAlgorithm(selectedSimilarityAlgorithm), forKey: .selectedSimilarityAlgorithm)
        try container.encode(performanceModeEnabled, forKey: .performanceModeEnabled)
        try container.encode(performanceModeSkipAniListTraversalForAnimeDetails, forKey: .performanceModeSkipAniListTraversalForAnimeDetails)
        try container.encode(performanceModeFastAnimeCatalogOverrides.filter { PerformanceModeSettings.animeCatalogIds.contains($0.key) }, forKey: .performanceModeFastAnimeCatalogOverrides)
        try container.encode(kanzenHomeSelectedSourceID, forKey: .kanzenHomeSelectedSourceID)
        try container.encode(kanzenRecentSourceSearches, forKey: .kanzenRecentSourceSearches)

        try container.encode(collections, forKey: .collections)
        try container.encode(progressData, forKey: .progressData)
        try container.encode(trackerState, forKey: .trackerState)
        try container.encode(catalogs, forKey: .catalogs)
        try container.encode(services, forKey: .services)
        try container.encodeIfPresent(stremioAddons, forKey: .stremioAddons)
        try container.encode(mangaCollections, forKey: .mangaCollections)
        try container.encode(mangaReadingProgress, forKey: .mangaReadingProgress)
        try container.encode(mangaCatalogs, forKey: .mangaCatalogs)
        try container.encode(kanzenModules, forKey: .kanzenModules)
        try container.encodeIfPresent(aidokuState, forKey: .aidokuState)
        try container.encode(searchHistory, forKey: .searchHistory)
        try container.encode(recommendationCache, forKey: .recommendationCache)
        try container.encode(userRatings, forKey: .userRatings)
        try container.encode(userRatingNotes, forKey: .userRatingNotes)
        try container.encodeIfPresent(mediaStateSettings, forKey: .mediaStateSettings)
    }
    
    init(
        version: String = "1.0",
        createdDate: Date,
        accentColor: Data? = nil,
        settingsGradientColor: Data? = nil,
        readerAccentColor: Data? = nil,
        tmdbLanguage: String,
        selectedAppearance: String,
        readerSelectedAppearance: String = "system",
        readerGlobalAppearanceEnabled: Bool = true,
        readerSettingsGradientColor: Data? = nil,
        enableSubtitlesByDefault: Bool,
        defaultSubtitleLanguage: String,
        playerSubtitleAppearanceEnabled: Bool,

        preferredAutoAudioLanguage: String,
        preferredAnimeAudioLanguage: String,
        inAppPlayer: String,
        showScheduleTab: Bool,
        showLocalScheduleTime: Bool,
        defaultScheduleMode: String = ScheduleMode.anime.rawValue,
        scheduleWindowDays: Int = ScheduleWindow.defaultValue.rawValue,
        localNotificationSubscriptions: String? = nil,
        localNotificationEpisodeReminders: String? = nil,
        localNotificationEpisodeLeadTime: Int? = nil,
        localNotificationSeasonLeadTime: Int? = nil,
        localNotificationIncludeAnimeSpecials: Bool? = nil,

        // Player settings
        defaultPlaybackSpeed: Double = 1.0,
        holdSpeedPlayer: Double = 2.0,
        externalPlayer: String = "none",
        preferDownloadedMedia: Bool = false,
        alwaysLandscape: Bool = false,
        playerPlaybackLockEnabled: Bool = PlayerPlaybackLockSettings.defaultEnabled,
        aniSkipEnabled: Bool = true,
        introDBEnabled: Bool = true,
        introDBAppEnabled: Bool = true,
        aniSkipAutoSkip: Bool = false,
        skip85sEnabled: Bool = false,
        skip85sAlwaysVisible: Bool = false,
        showNextEpisodeButton: Bool = true,
        showEpisodeBrowserButton: Bool = true,
        showPlayerServicesButton: Bool = false,
        showNextEpisodePosterButton: Bool = false,
        nextEpisodeThreshold: Double = 0.90,
        nextEpisodeSkipFillerEnabled: Bool = NextEpisodeFillerSettings.defaultEnabled,
        playerBrightnessGestureEnabled: Bool = false,
        playerVolumeGestureEnabled: Bool = false,
        playerTwoFingerTapPlayPauseEnabled: Bool = true,
        playerCenterTapPlayPauseEnabled: Bool = true,
        playerDoubleTapSeekEnabled: Bool = true,
        playerDoubleTapSeekSeconds: Double = 10.0,
        playerOpenSubtitlesEnabled: Bool = false,
        playerOpenSubtitlesAutoFallbackEnabled: Bool = true,
        playerPerformanceOverlayEnabled: Bool = false,
        mpvForegroundFPS: Int = 30,
        mpvRenderBackend: String = MPVRenderBackend.defaultBackend.rawValue,
        mpvMetalQualityProfile: String = MPVMetalQualityProfile.defaultProfile.rawValue,
        mpvUpscalingMode: String = MPVUpscalingMode.defaultMode.rawValue,
        mpvPlayerSkin: String = MPVPlayerSkin.defaultSkin.rawValue,
        mpvPlayerSkinCustomPrimaryColor: Data? = nil,
        mpvPlayerSkinCustomSecondaryColor: Data? = nil,
        mpvPlayerSkinAnimationsEnabled: Bool = MPVPlayerSkinSettings.defaultAnimationsEnabled,
        mpvPlayerSkinTintControlsOnly: Bool = MPVPlayerSkinSettings.defaultTintControlsOnly,
        mpvPictureInPictureEnabled: Bool = true,
        mpvAppExitPictureInPictureEnabled: Bool = false,
        mpvHDRMode: String = MPVHDRMode.defaultMode.rawValue,
        mpvSurroundSoundEnabled: Bool = true,
        watchTogetherEnabled: Bool = WatchTogetherSettings.defaultEnabled,
        smartInAppPlayerChoosingEnabled: Bool = false,
        experimentalFeaturesEnabled: Bool = false,
        experimentalFeaturesLastChangedAt: Double = 0,
        experimentalMPVPreloadEnabled: Bool = true,
        experimentalMPVSmoothTransitionEnabled: Bool = true,
        experimentalMPVPreloadCellularEnabled: Bool = false,
        experimentalMPVPreloadWifiLimitMB: Int = ExperimentalFeatureState.mpvPreloadWifiDefaultLimitMB,
        experimentalMPVPreloadCellularLimitMB: Int = ExperimentalFeatureState.mpvPreloadCellularDefaultLimitMB,
        experimentalMPVShowRemainingTime: Bool = true,
        experimentalMPVPreciseProgress: Bool = true,
        experimentalMPVIgnoreSpecialSubtitleStyles: Bool = false,
        experimentalMPVPreloadAutoClear: Bool = true,
        experimentalICloudSyncEnabled: Bool = false,

        // Subtitle styling
        subtitleForegroundColor: Data? = nil,
        subtitleStrokeColor: Data? = nil,
        subtitleStrokeWidth: Double = 1.0,
        subtitleFontSize: Double = 30.0,
        subtitleVerticalOffset: Double = -6.0,
        subtitlesVisible: Bool = false,

        // UI preferences
        showKanzen: Bool = false,
        hideSplashScreen: Bool? = nil,
        modeSwitchAnimationEnabled: Bool = ModeSwitchAnimationSettings.defaultEnabled,
        kanzenAutoUpdateModules: Bool = true,
        seasonMenu: Bool = false,
        horizontalEpisodeList: Bool = false,
        mediaDetailTitleArtworkEnabled: Bool = MediaDetailTitleArtworkSettings.defaultEnabled,
        mediaDetailSimilarTitlesEnabled: Bool = MediaDetailSimilarTitlesSettings.defaultEnabled,
        useClassicScheduleUI: Bool = false,
        heroBannerCatalogId: String = "trending",
        heroBannerBehavior: String = HeroBannerBehavior.defaultValue.rawValue,
        homeCatalogLayoutOverrides: String = "",
        homeAnimatedBackgroundEnabled: Bool? = nil,
        homeAnimatedBackgroundQuality: String = HomeAnimatedBackgroundQuality.defaultValue.rawValue,
        homeAnimatedBackgroundFrameRate: String = HomeAnimatedBackgroundFrameRate.defaultValue.rawValue,
        appPerformanceOverlayEnabled: Bool = AppPerformanceOverlaySettings.defaultEnabled,
        experimentalMediaDesignPreset: String = ExperimentalMediaDesignPreset.defaultValue.rawValue,
        experimentalHeroBleedLevel: String = ExperimentalHeroBleedLevel.defaultValue.rawValue,
        experimentalHomeCardShape: String = ExperimentalHomeCardShape.defaultValue.rawValue,
        experimentalMultiGradientPalette: String = ExperimentalMultiGradientPalette.defaultValue.rawValue,
        experimentalHeroHeightScale: Double = ExperimentalVisualTuning.defaultHeroHeightScale,
        experimentalHeroBleedStrength: Double = ExperimentalVisualTuning.defaultHeroBleedStrength,
        experimentalHeroFadeDistanceScale: Double = ExperimentalVisualTuning.defaultHeroFadeDistanceScale,
        experimentalSectionSpacingScale: Double = ExperimentalVisualTuning.defaultSectionSpacingScale,
        experimentalCardRadiusScale: Double = ExperimentalVisualTuning.defaultCardRadiusScale,
        experimentalMediaCardScale: Double = ExperimentalVisualTuning.defaultMediaCardScale,
        experimentalGlassStrength: Double = ExperimentalVisualTuning.defaultGlassStrength,
        experimentalGradientBaseDarkness: Double = ExperimentalVisualTuning.defaultGradientBaseDarkness,
        experimentalGradientAccentIntensity: Double = ExperimentalVisualTuning.defaultGradientAccentIntensity,
        experimentalGradientScrollMotion: Double = ExperimentalVisualTuning.defaultGradientScrollMotion,
        experimentalGradientUseCustomColors: Bool = false,
        experimentalGradientColorA: Data? = nil,
        experimentalGradientColorB: Data? = nil,
        experimentalGradientColorC: Data? = nil,
        atmosphereStyle: String = AtmosphereStyle.gradient.rawValue,
        atmosphereSolidColorSource: String = AtmosphereSolidColorSource.dominant.rawValue,
        atmosphereSolidColor: Data? = nil,
        readerAtmosphereStyle: String = AtmosphereStyle.gradient.rawValue,
        readerAtmosphereSolidColorSource: String = AtmosphereSolidColorSource.dominant.rawValue,
        readerAtmosphereSolidColor: Data? = nil,
        mediaDetailElementOrder: String = MediaDetailElement.defaultOrderRawValue,
        mediaDetailHiddenElements: String = "",
        readerDetailElementOrder: String = ReaderDetailElement.defaultOrderRawValue,
        readerDetailHiddenElements: String = "",
        mediaColumnsPortrait: Int = 3,
        mediaColumnsLandscape: Int = 5,

        // Manga / Reader
        readingMode: Int = 2,
        kanzenReaderMode: String = "webtoon",
        kanzenReaderModeOverrides: [String: String] = [:],
        readerDownsampleImages: Bool = true,
        readerCropBorders: Bool = false,
        readerDisableQuickActions: Bool = false,
        readerDisableDoubleTap: Bool = false,
        readerLiveText: Bool = false,
        readerHideBarsOnSwipe: Bool = false,
        readerBackgroundColor: String = "black",
        readerOrientation: String = "device",
        readerTapZones: String = "disabled",
        readerInvertTapZones: Bool = false,
        readerAnimatePageTransitions: Bool = true,
        readerUpscaleImages: Bool = false,
        readerUpscaleMaxHeight: Int = 2000,
        readerUpscaleModelName: String = "None",
        readerPagesToPreload: Int = 3,
        readerPagedPageLayout: String = "single",
        readerPagedPageOffset: Bool = false,
        readerPagedPageOffsetOverrides: [String: Bool] = [:],
        readerSplitWideImages: Bool = false,
        readerReverseSplitOrder: Bool = false,
        readerVerticalInfiniteScroll: Bool = true,
        readerPillarbox: Bool = false,
        readerPillarboxAmount: Double = 15,
        readerPillarboxOrientation: String = "both",
        readerOrientationLockEnabled: Bool = false,
        readerOrientationLockMask: String = "all",
        readerReadThresholdPercent: Double = 80,

        // Novel Reader
        readerFontSize: Double = 16,
        readerFontFamily: String = "-apple-system",
        readerFontWeight: String = "normal",
        readerColorPreset: Int = 0,
        readerTextAlignment: String = "left",
        readerLineSpacing: Double = 1.6,
        readerMargin: Double = 4,

        // Other
        autoClearCacheEnabled: Bool = false,
        autoClearCacheThresholdMB: Double = 500,
        highQualityThreshold: Double = 0.9,
        backgroundHLSPipelineEnabled: Bool = false,
        readerDownloadsBackgroundEnabled: Bool = true,
        readerDownloadsWifiOnly: Bool = false,
        readerDownloadsParallelLimit: Int = 2,
        autoUpdateServicesEnabled: Bool = true,
        servicesAutoModeEnabled: Bool = false,
        servicesAutoSelectEpisodesEnabled: Bool = false,
        servicesAutoModeSourceIds: [String] = [],
        servicesAutoModeSourceOrderIds: [String] = [],
        servicesAutoModeQualityPreference: String = AutoModeQualityPreference.defaultPreference.rawValue,
        servicesResultMinimumSimilarity: Double = ServicesResultRankingSettings.defaultMinimumSimilarity,
        servicesDropMismatchedResults: Bool = ServicesResultRankingSettings.defaultDropMismatchedResults,
        servicesStremioStyleSheetEnabled: Bool = ServicesSheetPresentationSettings.defaultStremioStyleEnabled,
        servicesIncludedStreamLanguages: [String] = [],
        servicesHiddenStreamLanguages: [String] = [],
        servicesHideStreamsWithoutLanguageData: Bool = false,
        servicesAssumeOriginalAudio: Bool = false,
        servicesTreatDubbedAnimeAsEnglish: Bool = false,
        servicesHiddenStreamQualities: [Int] = [],
        servicesHideStreamsWithoutDetectedQuality: Bool = false,
        servicesExtraRulesSourceIds: [String]? = nil,
        githubReleaseAutoCheckEnabled: Bool = true,
        githubReleaseUpdateAvailable: Bool = false,
        githubReleaseLatestVersion: String = "",
        githubReleaseURL: String = "",
        githubReleaseShowAlertPending: Bool = false,
        githubReleaseLastPromptedVersion: String = "",
        filterHorrorContent: Bool = false,
        selectedSimilarityAlgorithm: String = SimilarityAlgorithm.hybrid.rawValue,
        performanceModeEnabled: Bool = PerformanceModeSettings.defaultEnabled,
        performanceModeSkipAniListTraversalForAnimeDetails: Bool = false,
        performanceModeFastAnimeCatalogOverrides: [String: Bool] = [:],
        kanzenHomeSelectedSourceID: String = "",
        kanzenRecentSourceSearches: [String] = [],

        collections: [BackupCollection] = [],
        progressData: ProgressData = ProgressData(),
        trackerState: TrackerState = TrackerState(),
        catalogs: [Catalog] = [],
        services: [BackupService] = [],
        stremioAddons: [BackupStremioAddon]? = nil,
        mangaCollections: [BackupMangaCollection] = [],
        mangaReadingProgress: [String: MangaProgress] = [:],
        mangaCatalogs: [MangaCatalog] = [],
        kanzenModules: [BackupKanzenModule] = [],
        aidokuState: BackupAidokuState? = nil,
        searchHistory: BackupSearchHistory = BackupSearchHistory(),
        recommendationCache: [TMDBSearchResult] = [],
        userRatings: [String: Double] = [:],
        userRatingNotes: [String: String] = [:],
        mediaStateSettings: [String: Data]? = nil,
        mangaCollectionsPresent: Bool = true,
        mangaReadingProgressPresent: Bool = true,
        mangaCatalogsPresent: Bool = true,
        kanzenModulesPresent: Bool = true,
        userRatingsPresent: Bool = true
    ) {
        self.version = version
        self.createdDate = createdDate
        self.accentColor = accentColor
        self.settingsGradientColor = settingsGradientColor
        self.readerAccentColor = readerAccentColor
        self.tmdbLanguage = tmdbLanguage
        self.selectedAppearance = Self.sanitizedAppearance(selectedAppearance)
        self.readerSelectedAppearance = Self.sanitizedAppearance(readerSelectedAppearance)
        self.readerGlobalAppearanceEnabled = readerGlobalAppearanceEnabled
        self.readerSettingsGradientColor = readerSettingsGradientColor
        self.enableSubtitlesByDefault = enableSubtitlesByDefault
        self.defaultSubtitleLanguage = defaultSubtitleLanguage
        self.playerSubtitleAppearanceEnabled = playerSubtitleAppearanceEnabled

        self.preferredAutoAudioLanguage = preferredAutoAudioLanguage
        self.preferredAnimeAudioLanguage = preferredAnimeAudioLanguage
        self.inAppPlayer = Settings.normalizedInAppPlayer(inAppPlayer)
        self.showScheduleTab = showScheduleTab
        self.showLocalScheduleTime = showLocalScheduleTime
        self.defaultScheduleMode = ScheduleMode.sanitizedRawValue(defaultScheduleMode)
        self.scheduleWindowDays = ScheduleWindow.sanitizedDays(scheduleWindowDays)
        self.localNotificationSubscriptions = localNotificationSubscriptions
        self.localNotificationEpisodeReminders = localNotificationEpisodeReminders
        self.localNotificationEpisodeLeadTime = localNotificationEpisodeLeadTime
        self.localNotificationSeasonLeadTime = localNotificationSeasonLeadTime
        self.localNotificationIncludeAnimeSpecials = localNotificationIncludeAnimeSpecials

        self.defaultPlaybackSpeed = defaultPlaybackSpeed
        self.holdSpeedPlayer = holdSpeedPlayer
        self.externalPlayer = externalPlayer
        self.preferDownloadedMedia = preferDownloadedMedia
        self.alwaysLandscape = alwaysLandscape
        self.playerPlaybackLockEnabled = playerPlaybackLockEnabled
        self.aniSkipEnabled = aniSkipEnabled
        self.introDBEnabled = introDBEnabled
        self.introDBAppEnabled = introDBAppEnabled
        self.aniSkipAutoSkip = aniSkipAutoSkip
        self.skip85sEnabled = skip85sEnabled
        self.skip85sAlwaysVisible = skip85sAlwaysVisible
        self.showNextEpisodeButton = showNextEpisodeButton
        self.showEpisodeBrowserButton = showEpisodeBrowserButton
        self.showPlayerServicesButton = showPlayerServicesButton
        self.showNextEpisodePosterButton = showNextEpisodePosterButton
        self.nextEpisodeThreshold = nextEpisodeThreshold
        self.nextEpisodeSkipFillerEnabled = nextEpisodeSkipFillerEnabled
        self.playerBrightnessGestureEnabled = playerBrightnessGestureEnabled
        self.playerVolumeGestureEnabled = playerVolumeGestureEnabled
        self.playerTwoFingerTapPlayPauseEnabled = playerTwoFingerTapPlayPauseEnabled
        self.playerCenterTapPlayPauseEnabled = playerCenterTapPlayPauseEnabled
        self.playerDoubleTapSeekEnabled = playerDoubleTapSeekEnabled
        self.playerDoubleTapSeekSeconds = playerDoubleTapSeekSeconds
        self.playerOpenSubtitlesEnabled = playerOpenSubtitlesEnabled
        self.playerOpenSubtitlesAutoFallbackEnabled = playerOpenSubtitlesAutoFallbackEnabled
        self.playerPerformanceOverlayEnabled = playerPerformanceOverlayEnabled
        self.mpvForegroundFPS = Self.sanitizedMPVForegroundFPS(mpvForegroundFPS)
        self.mpvRenderBackend = Self.sanitizedMPVRenderBackend(mpvRenderBackend)
        self.mpvMetalQualityProfile = Self.sanitizedMPVMetalQualityProfile(mpvMetalQualityProfile)
        self.mpvUpscalingMode = Self.sanitizedMPVUpscalingMode(mpvUpscalingMode)
        self.mpvPlayerSkin = Self.sanitizedMPVPlayerSkin(mpvPlayerSkin)
        self.mpvPlayerSkinCustomPrimaryColor = mpvPlayerSkinCustomPrimaryColor
        self.mpvPlayerSkinCustomSecondaryColor = mpvPlayerSkinCustomSecondaryColor
        self.mpvPlayerSkinAnimationsEnabled = mpvPlayerSkinAnimationsEnabled
        self.mpvPlayerSkinTintControlsOnly = mpvPlayerSkinTintControlsOnly
        self.mpvPictureInPictureEnabled = mpvPictureInPictureEnabled
        self.mpvAppExitPictureInPictureEnabled = mpvAppExitPictureInPictureEnabled
        self.mpvHDRMode = MPVHDRMode(rawValue: mpvHDRMode)?.rawValue ?? MPVHDRMode.defaultMode.rawValue
        self.mpvSurroundSoundEnabled = mpvSurroundSoundEnabled
        self.watchTogetherEnabled = watchTogetherEnabled
        self.smartInAppPlayerChoosingEnabled = smartInAppPlayerChoosingEnabled
        self.experimentalFeaturesEnabled = experimentalFeaturesEnabled
        self.experimentalFeaturesLastChangedAt = experimentalFeaturesLastChangedAt
        self.experimentalMPVPreloadEnabled = experimentalMPVPreloadEnabled
        self.experimentalMPVSmoothTransitionEnabled = experimentalMPVSmoothTransitionEnabled
        self.experimentalMPVPreloadCellularEnabled = experimentalMPVPreloadCellularEnabled
        self.experimentalMPVPreloadWifiLimitMB = ExperimentalFeatureState.clampedMPVPreloadWifiLimitMB(experimentalMPVPreloadWifiLimitMB)
        self.experimentalMPVPreloadCellularLimitMB = ExperimentalFeatureState.clampedMPVPreloadCellularLimitMB(experimentalMPVPreloadCellularLimitMB)
        self.experimentalMPVShowRemainingTime = experimentalMPVShowRemainingTime
        self.experimentalMPVPreciseProgress = experimentalMPVPreciseProgress
        self.experimentalMPVIgnoreSpecialSubtitleStyles = experimentalMPVIgnoreSpecialSubtitleStyles
        self.experimentalMPVPreloadAutoClear = experimentalMPVPreloadAutoClear
        self.experimentalICloudSyncEnabled = experimentalICloudSyncEnabled

        self.subtitleForegroundColor = subtitleForegroundColor
        self.subtitleStrokeColor = subtitleStrokeColor
        self.subtitleStrokeWidth = subtitleStrokeWidth
        self.subtitleFontSize = subtitleFontSize
        self.subtitleVerticalOffset = subtitleVerticalOffset
        self.subtitlesVisible = subtitlesVisible

        self.showKanzen = showKanzen
        self.hideSplashScreen = hideSplashScreen
        self.modeSwitchAnimationEnabled = modeSwitchAnimationEnabled
        self.kanzenAutoUpdateModules = kanzenAutoUpdateModules
        self.seasonMenu = seasonMenu
        self.horizontalEpisodeList = horizontalEpisodeList
        self.mediaDetailTitleArtworkEnabled = mediaDetailTitleArtworkEnabled
        self.mediaDetailSimilarTitlesEnabled = mediaDetailSimilarTitlesEnabled
        self.useClassicScheduleUI = useClassicScheduleUI
        self.heroBannerCatalogId = Self.sanitizedNonEmptyString(heroBannerCatalogId, defaultValue: "trending")
        self.heroBannerBehavior = Self.sanitizedHeroBannerBehavior(heroBannerBehavior)
        self.homeCatalogLayoutOverrides = homeCatalogLayoutOverrides
        self.homeAnimatedBackgroundEnabled = homeAnimatedBackgroundEnabled
        self.homeAnimatedBackgroundQuality = Self.sanitizedHomeAnimatedBackgroundQuality(homeAnimatedBackgroundQuality)
        self.homeAnimatedBackgroundFrameRate = Self.sanitizedHomeAnimatedBackgroundFrameRate(homeAnimatedBackgroundFrameRate)
        self.appPerformanceOverlayEnabled = appPerformanceOverlayEnabled
        self.experimentalMediaDesignPreset = Self.sanitizedExperimentalMediaDesignPreset(experimentalMediaDesignPreset)
        self.experimentalHeroBleedLevel = Self.sanitizedExperimentalHeroBleedLevel(experimentalHeroBleedLevel)
        self.experimentalHomeCardShape = Self.sanitizedExperimentalHomeCardShape(experimentalHomeCardShape)
        self.experimentalMultiGradientPalette = Self.sanitizedExperimentalMultiGradientPalette(experimentalMultiGradientPalette)
        self.experimentalHeroHeightScale = Self.sanitizedExperimentalHeroHeightScale(experimentalHeroHeightScale)
        self.experimentalHeroBleedStrength = Self.sanitizedExperimentalHeroBleedStrength(experimentalHeroBleedStrength)
        self.experimentalHeroFadeDistanceScale = Self.sanitizedExperimentalHeroFadeDistanceScale(experimentalHeroFadeDistanceScale)
        self.experimentalSectionSpacingScale = Self.sanitizedExperimentalSectionSpacingScale(experimentalSectionSpacingScale)
        self.experimentalCardRadiusScale = Self.sanitizedExperimentalCardRadiusScale(experimentalCardRadiusScale)
        self.experimentalMediaCardScale = Self.sanitizedExperimentalMediaCardScale(experimentalMediaCardScale)
        self.experimentalGlassStrength = Self.sanitizedExperimentalGlassStrength(experimentalGlassStrength)
        self.experimentalGradientBaseDarkness = Self.sanitizedExperimentalGradientBaseDarkness(experimentalGradientBaseDarkness)
        self.experimentalGradientAccentIntensity = Self.sanitizedExperimentalGradientAccentIntensity(experimentalGradientAccentIntensity)
        self.experimentalGradientScrollMotion = Self.sanitizedExperimentalGradientScrollMotion(experimentalGradientScrollMotion)
        self.experimentalGradientUseCustomColors = experimentalGradientUseCustomColors
        self.experimentalGradientColorA = experimentalGradientColorA
        self.experimentalGradientColorB = experimentalGradientColorB
        self.experimentalGradientColorC = experimentalGradientColorC
        self.atmosphereStyle = Self.sanitizedAtmosphereStyle(atmosphereStyle)
        self.atmosphereSolidColorSource = Self.sanitizedAtmosphereSolidColorSource(atmosphereSolidColorSource)
        self.atmosphereSolidColor = atmosphereSolidColor
        self.readerAtmosphereStyle = Self.sanitizedAtmosphereStyle(readerAtmosphereStyle)
        self.readerAtmosphereSolidColorSource = Self.sanitizedAtmosphereSolidColorSource(readerAtmosphereSolidColorSource)
        self.readerAtmosphereSolidColor = readerAtmosphereSolidColor
        self.mediaDetailElementOrder = Self.sanitizedMediaDetailElementOrder(mediaDetailElementOrder)
        self.mediaDetailHiddenElements = Self.sanitizedMediaDetailHiddenElements(mediaDetailHiddenElements)
        self.readerDetailElementOrder = Self.sanitizedReaderDetailElementOrder(readerDetailElementOrder)
        self.readerDetailHiddenElements = Self.sanitizedReaderDetailHiddenElements(readerDetailHiddenElements)
        self.mediaColumnsPortrait = mediaColumnsPortrait
        self.mediaColumnsLandscape = mediaColumnsLandscape

        self.readingMode = readingMode
        self.kanzenReaderMode = Self.sanitizedKanzenReaderMode(kanzenReaderMode)
        self.kanzenReaderModeOverrides = Self.sanitizedKanzenReaderModeOverrides(kanzenReaderModeOverrides)
        self.readerDownsampleImages = readerDownsampleImages
        self.readerCropBorders = readerCropBorders
        self.readerDisableQuickActions = readerDisableQuickActions
        self.readerDisableDoubleTap = readerDisableDoubleTap
        self.readerLiveText = readerLiveText
        self.readerHideBarsOnSwipe = readerHideBarsOnSwipe
        self.readerBackgroundColor = Self.sanitizedReaderBackgroundColor(readerBackgroundColor)
        self.readerOrientation = Self.sanitizedReaderOrientation(readerOrientation)
        self.readerTapZones = Self.sanitizedReaderTapZones(readerTapZones)
        self.readerInvertTapZones = readerInvertTapZones
        self.readerAnimatePageTransitions = readerAnimatePageTransitions
        self.readerUpscaleImages = readerUpscaleImages
        self.readerUpscaleMaxHeight = Self.sanitizedReaderUpscaleMaxHeight(readerUpscaleMaxHeight)
        self.readerUpscaleModelName = readerUpscaleModelName
        self.readerPagesToPreload = Self.sanitizedReaderPagesToPreload(readerPagesToPreload)
        self.readerPagedPageLayout = Self.sanitizedReaderPagedPageLayout(readerPagedPageLayout)
        self.readerPagedPageOffset = readerPagedPageOffset
        self.readerPagedPageOffsetOverrides = Self.sanitizedReaderPagedPageOffsetOverrides(readerPagedPageOffsetOverrides)
        self.readerSplitWideImages = readerSplitWideImages
        self.readerReverseSplitOrder = readerReverseSplitOrder
        self.readerVerticalInfiniteScroll = readerVerticalInfiniteScroll
        self.readerPillarbox = readerPillarbox
        self.readerPillarboxAmount = Self.sanitizedReaderPillarboxAmount(readerPillarboxAmount)
        self.readerPillarboxOrientation = Self.sanitizedReaderPillarboxOrientation(readerPillarboxOrientation)
        self.readerOrientationLockEnabled = readerOrientationLockEnabled
        self.readerOrientationLockMask = Self.sanitizedReaderOrientationLockMask(readerOrientationLockMask)
        self.readerReadThresholdPercent = Self.sanitizedReaderReadThresholdPercent(readerReadThresholdPercent)

        self.readerFontSize = readerFontSize
        self.readerFontFamily = readerFontFamily
        self.readerFontWeight = readerFontWeight
        self.readerColorPreset = readerColorPreset
        self.readerTextAlignment = readerTextAlignment
        self.readerLineSpacing = readerLineSpacing
        self.readerMargin = readerMargin

        self.autoClearCacheEnabled = autoClearCacheEnabled
        self.autoClearCacheThresholdMB = autoClearCacheThresholdMB
        self.highQualityThreshold = highQualityThreshold
        self.backgroundHLSPipelineEnabled = backgroundHLSPipelineEnabled
        self.readerDownloadsBackgroundEnabled = readerDownloadsBackgroundEnabled
        self.readerDownloadsWifiOnly = readerDownloadsWifiOnly
        self.readerDownloadsParallelLimit = Self.sanitizedReaderDownloadsParallelLimit(readerDownloadsParallelLimit)
        self.autoUpdateServicesEnabled = autoUpdateServicesEnabled
        self.servicesAutoModeEnabled = servicesAutoModeEnabled
        self.servicesAutoSelectEpisodesEnabled = servicesAutoSelectEpisodesEnabled
        self.servicesAutoModeSourceIds = Self.sanitizedStringList(servicesAutoModeSourceIds)
        self.servicesAutoModeSourceOrderIds = Self.sanitizedStringList(servicesAutoModeSourceOrderIds)
        self.servicesAutoModeQualityPreference = AutoModeQualityPreference.sanitizedRawValue(servicesAutoModeQualityPreference)
        self.servicesResultMinimumSimilarity = Self.sanitizedServicesResultMinimumSimilarity(servicesResultMinimumSimilarity)
        self.servicesDropMismatchedResults = servicesDropMismatchedResults
        self.servicesStremioStyleSheetEnabled = servicesStremioStyleSheetEnabled
        self.servicesIncludedStreamLanguages = StreamLanguageFilter.sanitizedLanguageList(servicesIncludedStreamLanguages)
        self.servicesHiddenStreamLanguages = StreamLanguageFilter.sanitizedLanguageList(servicesHiddenStreamLanguages)
        self.servicesHideStreamsWithoutLanguageData = servicesHideStreamsWithoutLanguageData
        self.servicesAssumeOriginalAudio = servicesAssumeOriginalAudio
        self.servicesTreatDubbedAnimeAsEnglish = servicesTreatDubbedAnimeAsEnglish
        self.servicesHiddenStreamQualities = StreamLanguageFilter.sanitizedQualityHeights(servicesHiddenStreamQualities)
        self.servicesHideStreamsWithoutDetectedQuality = servicesHideStreamsWithoutDetectedQuality
        self.servicesExtraRulesSourceIds = servicesExtraRulesSourceIds.map(StreamLanguageFilter.sanitizedExtraRulesSourceIds)
        self.githubReleaseAutoCheckEnabled = githubReleaseAutoCheckEnabled
        self.githubReleaseUpdateAvailable = githubReleaseUpdateAvailable
        self.githubReleaseLatestVersion = githubReleaseLatestVersion
        self.githubReleaseURL = githubReleaseURL
        self.githubReleaseShowAlertPending = githubReleaseShowAlertPending
        self.githubReleaseLastPromptedVersion = githubReleaseLastPromptedVersion
        self.filterHorrorContent = filterHorrorContent
        self.selectedSimilarityAlgorithm = Self.sanitizedSimilarityAlgorithm(selectedSimilarityAlgorithm)
        self.performanceModeEnabled = performanceModeEnabled
        self.performanceModeSkipAniListTraversalForAnimeDetails = performanceModeSkipAniListTraversalForAnimeDetails
        self.performanceModeFastAnimeCatalogOverrides = performanceModeFastAnimeCatalogOverrides.filter { PerformanceModeSettings.animeCatalogIds.contains($0.key) }
        self.kanzenHomeSelectedSourceID = kanzenHomeSelectedSourceID
        self.kanzenRecentSourceSearches = Self.sanitizedStringList(kanzenRecentSourceSearches)

        self.collections = collections
        self.progressData = progressData
        self.trackerState = trackerState
        self.catalogs = catalogs
        self.services = services
        self.stremioAddons = stremioAddons
        self.mangaCollections = mangaCollections
        self.mangaReadingProgress = mangaReadingProgress
        self.mangaCatalogs = mangaCatalogs
        self.kanzenModules = kanzenModules
        self.aidokuState = aidokuState
        self.searchHistory = searchHistory
        self.recommendationCache = recommendationCache
        self.userRatings = userRatings
        self.userRatingNotes = userRatingNotes
        self.mediaStateSettings = mediaStateSettings
        self.hasMangaCollections = mangaCollectionsPresent
        self.hasMangaReadingProgress = mangaReadingProgressPresent
        self.hasMangaCatalogs = mangaCatalogsPresent
        self.hasKanzenModules = kanzenModulesPresent
        self.hasUserRatings = userRatingsPresent
    }

    private static func decodeUserRatings(from container: KeyedDecodingContainer<CodingKeys>) -> [String: Double] {
        if let ratings = try? container.decodeIfPresent([String: Double].self, forKey: .userRatings) {
            return normalizeUserRatings(ratings)
        }

        if let ratings = try? container.decodeIfPresent([String: Int].self, forKey: .userRatings) {
            return normalizeUserRatings(ratings.mapValues(Double.init))
        }

        return [:]
    }

    private static func normalizeUserRatings(_ ratings: [String: Double]) -> [String: Double] {
        ratings.mapValues { value in
            let finiteValue = value.isFinite ? value : 0.5
            let halfStepValue = (finiteValue * 2).rounded() / 2
            return max(0.5, min(10, halfStepValue))
        }
    }

    static func sanitizedMPVForegroundFPS(_ value: Int) -> Int {
        value == 60 ? 60 : 30
    }

    static func sanitizedMPVRenderBackend(_: String?) -> String {
        MPVRenderBackend.defaultBackend.rawValue
    }

    static func sanitizedMPVMetalQualityProfile(_ value: String?) -> String {
        guard let value,
              let profile = MPVMetalQualityProfile(rawValue: value) else {
            return MPVMetalQualityProfile.defaultProfile.rawValue
        }
        return profile.rawValue
    }

    static func sanitizedMPVUpscalingMode(_ value: String?) -> String {
        guard let value,
              let mode = MPVUpscalingMode(rawValue: value) else {
            return MPVUpscalingMode.defaultMode.rawValue
        }
        return mode.rawValue
    }

    static func sanitizedMPVPlayerSkin(_ value: String?) -> String {
        if value == "cypberpunk" { return MPVPlayerSkin.cyberpunk.rawValue }
        return MPVPlayerSkin(rawValue: value ?? "")?.rawValue ?? MPVPlayerSkin.defaultSkin.rawValue
    }

    static func sanitizedMediaDetailElementOrder(_ value: String?) -> String {
        MediaDetailElement.rawValue(for: MediaDetailElement.orderedElements(from: value))
    }

    static func sanitizedMediaDetailHiddenElements(_ value: String?) -> String {
        MediaDetailElement.rawValue(for: MediaDetailElement.hiddenElements(from: value, legacyShowCastSection: true))
    }

    static func sanitizedReaderDetailElementOrder(_ value: String?) -> String {
        ReaderDetailElement.rawValue(for: ReaderDetailElement.orderedElements(from: value))
    }

    static func sanitizedReaderDetailHiddenElements(_ value: String?) -> String {
        ReaderDetailElement.rawValue(for: ReaderDetailElement.hiddenElements(from: value))
    }

    static func sanitizedReaderReadThresholdPercent(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 80 }
        return max(50, min(value, 100))
    }

    static func sanitizedNonEmptyString(_ value: String?, defaultValue: String) -> String {
        guard let value else { return defaultValue }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultValue : trimmed
    }

    static func sanitizedAppearance(_ value: String?) -> String {
        guard let value,
              let appearance = Appearance(rawValue: value) else {
            return Appearance.system.rawValue
        }
        return appearance.rawValue
    }

    static func sanitizedHeroBannerBehavior(_ value: String?) -> String {
        guard let value,
              let behavior = HeroBannerBehavior(rawValue: value) else {
            return HeroBannerBehavior.defaultValue.rawValue
        }
        return behavior.rawValue
    }

    static func sanitizedHomeAnimatedBackgroundQuality(_ value: String?) -> String {
        HomeAnimatedBackgroundQuality.resolved(value).rawValue
    }

    static func sanitizedHomeAnimatedBackgroundFrameRate(_ value: String?) -> String {
        HomeAnimatedBackgroundFrameRate.resolved(value).rawValue
    }

    static func sanitizedExperimentalMediaDesignPreset(_ value: String?) -> String {
        guard let value,
              let preset = ExperimentalMediaDesignPreset(rawValue: value) else {
            return ExperimentalMediaDesignPreset.defaultValue.rawValue
        }
        return preset.rawValue
    }

    static func sanitizedExperimentalHeroBleedLevel(_ value: String?) -> String {
        guard let value,
              let level = ExperimentalHeroBleedLevel(rawValue: value) else {
            return ExperimentalHeroBleedLevel.defaultValue.rawValue
        }
        return level.rawValue
    }

    static func sanitizedExperimentalHomeCardShape(_ value: String?) -> String {
        guard let value,
              let shape = ExperimentalHomeCardShape(rawValue: value) else {
            return ExperimentalHomeCardShape.defaultValue.rawValue
        }
        return shape.rawValue
    }

    static func sanitizedExperimentalMultiGradientPalette(_ value: String?) -> String {
        guard let value,
              let palette = ExperimentalMultiGradientPalette(rawValue: value) else {
            return ExperimentalMultiGradientPalette.defaultValue.rawValue
        }
        return palette.rawValue
    }

    static func sanitizedExperimentalHeroHeightScale(_ value: Double?) -> Double {
        ExperimentalVisualTuning.sanitizedHeroHeightScale(value)
    }

    static func sanitizedExperimentalHeroBleedStrength(_ value: Double?) -> Double {
        ExperimentalVisualTuning.sanitizedHeroBleedStrength(value)
    }

    static func sanitizedExperimentalHeroFadeDistanceScale(_ value: Double?) -> Double {
        ExperimentalVisualTuning.sanitizedHeroFadeDistanceScale(value)
    }

    static func sanitizedExperimentalSectionSpacingScale(_ value: Double?) -> Double {
        ExperimentalVisualTuning.sanitizedSectionSpacingScale(value)
    }

    static func sanitizedExperimentalCardRadiusScale(_ value: Double?) -> Double {
        ExperimentalVisualTuning.sanitizedCardRadiusScale(value)
    }

    static func sanitizedExperimentalMediaCardScale(_ value: Double?) -> Double {
        ExperimentalVisualTuning.sanitizedMediaCardScale(value)
    }

    static func sanitizedExperimentalGlassStrength(_ value: Double?) -> Double {
        ExperimentalVisualTuning.sanitizedGlassStrength(value)
    }

    static func sanitizedExperimentalGradientBaseDarkness(_ value: Double?) -> Double {
        ExperimentalVisualTuning.sanitizedGradientBaseDarkness(value)
    }

    static func sanitizedExperimentalGradientAccentIntensity(_ value: Double?) -> Double {
        ExperimentalVisualTuning.sanitizedGradientAccentIntensity(value)
    }

    static func sanitizedExperimentalGradientScrollMotion(_ value: Double?) -> Double {
        ExperimentalVisualTuning.sanitizedGradientScrollMotion(value)
    }

    static func sanitizedAtmosphereStyle(_ value: String?) -> String {
        guard let value,
              let style = AtmosphereStyle(rawValue: value) else {
            return AtmosphereStyle.gradient.rawValue
        }
        return style.rawValue
    }

    static func sanitizedAtmosphereSolidColorSource(_ value: String?) -> String {
        guard let value,
              let source = AtmosphereSolidColorSource(rawValue: value) else {
            return AtmosphereSolidColorSource.dominant.rawValue
        }
        return source.rawValue
    }

    static func defaultKanzenReaderModeRawValue() -> String {
#if !os(tvOS)
        return KanzenReaderMode.currentDefault().rawValue
#else
        return "webtoon"
#endif
    }

    static func sanitizedKanzenReaderMode(_ value: String?) -> String {
#if !os(tvOS)
        guard let value,
              let mode = KanzenReaderMode(rawValue: value) else {
            return defaultKanzenReaderModeRawValue()
        }
        return mode.rawValue
#else
        let allowed = Set(["ltr", "rtl", "webtoon"])
        guard let value, allowed.contains(value) else { return "webtoon" }
        return value
#endif
    }

    static func readingModeRawValue(forKanzenReaderMode value: String) -> Int {
        switch sanitizedKanzenReaderMode(value) {
        case "ltr": return ReadingMode.LTR.rawValue
        case "rtl": return ReadingMode.RTL.rawValue
        case "vertical": return ReadingMode.VERTICAL.rawValue
        default: return ReadingMode.WEBTOON.rawValue
        }
    }

    static func kanzenReaderModeRawValue(forReadingMode value: Int) -> String {
        switch ReadingMode(rawValue: value) ?? .WEBTOON {
        case .LTR: return "ltr"
        case .RTL: return "rtl"
        case .VERTICAL: return "vertical"
        case .WEBTOON: return "webtoon"
        }
    }

    static func sanitizedKanzenReaderModeOverrides(_ values: [String: String]?) -> [String: String] {
        guard let values else { return [:] }
        return values.reduce(into: [String: String]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = sanitizedKanzenReaderMode(item.value)
        }
    }

    static func sanitizedReaderOrientation(_ value: String?) -> String {
        guard let value else { return "device" }
        let allowed = Set(["device", "portrait", "landscape", "all"])
        return allowed.contains(value) ? value : "device"
    }

    static func sanitizedReaderTapZones(_ value: String?) -> String {
        guard let value else { return "disabled" }
        let allowed = Set(["auto", "left-right", "l-shaped", "kindle", "edge", "disabled"])
        return allowed.contains(value) ? value : "disabled"
    }

    static func sanitizedReaderUpscaleMaxHeight(_ value: Int?) -> Int {
        guard let value else { return 2000 }
        return max(800, min(value, 6000))
    }

    static func sanitizedReaderPagedPageOffsetOverrides(_ values: [String: Bool]?) -> [String: Bool] {
        guard let values else { return [:] }
        return values.reduce(into: [String: Bool]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = item.value
        }
    }

    static func sanitizedReaderBackgroundColor(_ value: String?) -> String {
        guard let value else { return "black" }
        let allowed = Set(["black", "white", "system", "auto"])
        return allowed.contains(value) ? value : "black"
    }

    static func sanitizedReaderPagesToPreload(_ value: Int?) -> Int {
        guard let value else { return 3 }
        return max(1, min(value, 10))
    }

    static func sanitizedReaderPagedPageLayout(_ value: String?) -> String {
        guard let value else { return "single" }
        let allowed = Set(["single", "double", "auto"])
        return allowed.contains(value) ? value : "single"
    }

    static func sanitizedReaderPillarboxAmount(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 15 }
        return max(5, min(value, 95))
    }

    static func sanitizedReaderPillarboxOrientation(_ value: String?) -> String {
        guard let value else { return "both" }
        let allowed = Set(["both", "portrait", "landscape"])
        return allowed.contains(value) ? value : "both"
    }

    static func sanitizedReaderOrientationLockMask(_ value: String?) -> String {
        guard let value else { return "all" }
        let allowed = Set(["portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight", "landscape", "all"])
        return allowed.contains(value) ? value : "all"
    }

    static func sanitizedReaderDownloadsParallelLimit(_ value: Int?) -> Int {
        guard let value else { return 2 }
        return max(1, min(value, 4))
    }

    static func sanitizedStringList(_ values: [String]?) -> [String] {
        var result: [String] = []
        for value in values ?? [] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func sanitizedSimilarityAlgorithm(_ value: String?) -> String {
        guard let value,
              let algorithm = SimilarityAlgorithm(rawValue: value) else {
            return SimilarityAlgorithm.hybrid.rawValue
        }
        return algorithm.rawValue
    }

    static func sanitizedServicesResultMinimumSimilarity(_ value: Double?) -> Double {
        ServicesResultRankingSettings.clampedMinimumSimilarity(
            value ?? ServicesResultRankingSettings.defaultMinimumSimilarity
        )
    }

    static func optionalInt(from value: Any?, defaultValue: Int) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return defaultValue
    }

    static func optionalDouble(from value: Any?, defaultValue: Double) -> Double {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return defaultValue
    }

    static func stringList(from value: Any?) -> [String] {
        value as? [String] ?? []
    }

    static func intList(from value: Any?) -> [Int] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { value in
            if let intValue = value as? Int { return intValue }
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String { return Int(string) }
            return nil
        }
    }

}

// Codable wrapper for Service
struct BackupService: Codable {
    let id: UUID
    let url: String
    let jsonMetadata: String
    let jsScript: String
    let isActive: Bool
    let sortIndex: Int64
}

struct BackupStremioAddon: Codable {
    let id: UUID
    let configuredURL: String
    let manifestJSON: String
    let isActive: Bool
    let sortIndex: Int64

    init(id: UUID, configuredURL: String, manifestJSON: String, isActive: Bool, sortIndex: Int64) {
        self.id = id
        self.configuredURL = configuredURL
        self.manifestJSON = manifestJSON
        self.isActive = isActive
        self.sortIndex = sortIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        configuredURL = try container.decodeIfPresent(String.self, forKey: .configuredURL) ?? ""
        manifestJSON = try container.decodeIfPresent(String.self, forKey: .manifestJSON) ?? ""
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        sortIndex = try container.decodeIfPresent(Int64.self, forKey: .sortIndex) ?? 0
    }
}

/// A redacted cloud snapshot intentionally omits sources whose configuration
/// may contain credentials. Those omissions are not deletion signals. Safe
/// sources still use replacement semantics so a deletion made on another
/// device propagates normally.
enum ExperimentalCloudSourceRestorePolicy {
    static func services(
        current: [BackupService],
        incoming: [BackupService]
    ) -> [BackupService] {
        let deviceLocal = current.filter {
            BackupData.serviceForExperimentalCloudSync($0) == nil
        }
        let deviceLocalIDs = Set(deviceLocal.map(\.id))
        return (incoming.filter { !deviceLocalIDs.contains($0.id) } + deviceLocal).sorted {
            if $0.sortIndex == $1.sortIndex {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.sortIndex < $1.sortIndex
        }
    }

    static func stremioAddons(
        current: [BackupStremioAddon],
        incoming: [BackupStremioAddon]
    ) -> [BackupStremioAddon] {
        let deviceLocal = current.filter {
            BackupData.stremioAddonForExperimentalCloudSync($0) == nil
        }
        let deviceLocalIDs = Set(deviceLocal.map(\.id))
        return (incoming.filter { !deviceLocalIDs.contains($0.id) } + deviceLocal).sorted {
            if $0.sortIndex == $1.sortIndex {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.sortIndex < $1.sortIndex
        }
    }
}

// Codable wrapper for MangaLibraryCollection
struct BackupMangaCollection: Codable {
    let id: UUID
    let name: String
    let items: [MangaLibraryItem]
    let description: String?
}

// Codable wrapper for Kanzen modules
struct BackupKanzenModule: Codable {
    let id: UUID
    let moduleData: ModuleData
    let localPath: String
    let moduleurl: String
    let isActive: Bool
}

struct BackupAidokuSourceListRecord: Codable {
    let url: String
    let name: String
    let sourceCount: Int
    let lastRefresh: Date?
    let lastError: String?
}

struct BackupAidokuInstalledSource: Codable {
    let id: String
    let name: String
    let version: Int
    let languages: [String]
    let iconPath: String?
    let externalIconURL: String?
    let contentRatingRawValue: Int
    let sourceListURL: String?
    let packageURL: String?
    let isEnabled: Bool
    let order: Int
    let lastUpdated: Date?
    let lastError: String?
    let payloadArchiveData: Data?
}

struct BackupAidokuState: Codable {
    var sourceLists: [BackupAidokuSourceListRecord] = []
    var installedSources: [BackupAidokuInstalledSource] = []
    var showMatureSources: Bool = false
    var autoUpdateSources: Bool = true
    var lastAutoUpdate: Date?
}

// Codable wrapper for LibraryCollection
struct BackupCollection: Codable {
    let id: UUID
    let name: String
    let items: [LibraryItem]
    let description: String?
    
    init(from collection: LibraryCollection) {
        self.id = collection.id
        self.name = collection.name
        self.items = collection.items
        self.description = collection.description
    }
    
    func toLibraryCollection() -> LibraryCollection {
        return LibraryCollection(id: id, name: name, items: items, description: description)
    }
}

// MARK: - Backup Manager

class BackupManager {
    static let shared = BackupManager()
    
    private let fileManager = FileManager.default
    private let dateFormatter = ISO8601DateFormatter()

    private func performOnMainThread(_ work: () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private static func parseUserRatings(_ ratings: [String: Any]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: ratings.compactMap { key, value -> (String, Double)? in
            let numericValue: Double?
            if let number = value as? NSNumber {
                numericValue = number.doubleValue
            } else if let value = value as? Double {
                numericValue = value
            } else if let value = value as? Int {
                numericValue = Double(value)
            } else {
                numericValue = nil
            }

            guard let numericValue else { return nil }
            let finiteValue = numericValue.isFinite ? numericValue : 0.5
            let halfStepValue = (finiteValue * 2).rounded() / 2
            return (key, max(0.5, min(10, halfStepValue)))
        })
    }

    private static func trackerStateWithoutCredentials(_ state: TrackerState) -> TrackerState {
        var sanitized = state
        sanitized.accounts = state.accounts.map { account in
            var metadataOnly = account
            metadataOnly.accessToken = ""
            metadataOnly.refreshToken = nil
            metadataOnly.expiresAt = nil
            return metadataOnly
        }
        return sanitized
    }

    /// State already owned by CKSyncEngine when the legacy iCloud Documents
    /// snapshot restores. Capturing the live managers, rather than the local
    /// media archive, also protects first launch while the initial CloudKit
    /// fetch is still in flight or the archive is empty.
    private struct LegacyCloudMediaStateAuthority {
        let settings: MediaStateLegacyRestoreSettingSnapshot
        let collections: [LibraryCollection]
        let progress: ProgressData
        let ratings: [String: Double]
        let ratingNotes: [String: String]
        let catalogs: [Catalog]
    }

    private func captureLegacyCloudMediaStateAuthority() -> LegacyCloudMediaStateAuthority {
        let defaults = UserDefaults.standard
        let persistentDomain: [String: Any]
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            persistentDomain = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
        } else {
            // Test/extension processes may not expose a bundle identifier. Use
            // the visible domain as a conservative fallback so a legacy restore
            // still cannot replace the values currently driving the app.
            persistentDomain = defaults.dictionaryRepresentation()
        }

        var collections: [LibraryCollection] = []
        var progress = ProgressData()
        var ratings: [String: Double] = [:]
        var ratingNotes: [String: String] = [:]
        var catalogs: [Catalog] = []
        performOnMainThread {
            collections = LibraryManager.shared.collections
            progress = ProgressManager.shared.getProgressData()
            ratings = UserRatingManager.shared.getRatingsForBackup()
            ratingNotes = UserRatingManager.shared.getNotesForBackup()
            catalogs = CatalogManager.shared.catalogs
        }

        return LegacyCloudMediaStateAuthority(
            settings: MediaStateLegacyRestoreSettingSnapshot(persistentDomain: persistentDomain),
            collections: collections,
            progress: progress,
            ratings: ratings,
            ratingNotes: ratingNotes,
            catalogs: catalogs
        )
    }

    private func restoreLegacyCloudMediaStateAuthority(_ authority: LegacyCloudMediaStateAuthority) {
        performOnMainThread {
            let defaults = UserDefaults.standard
            authority.settings.restore(to: defaults)

            LibraryManager.shared.replaceCollectionsForMediaState(authority.collections)
            ProgressManager.shared.replaceProgressDataForRestore(authority.progress)
            UserRatingManager.shared.restoreRatingsAndNotes(
                ratings: authority.ratings,
                notes: authority.ratingNotes
            )

            let catalogManager = CatalogManager.shared
            catalogManager.setPerformanceModeEnabled(
                defaults.bool(forKey: PerformanceModeSettings.enabledKey)
            )
            catalogManager.catalogs = authority.catalogs
            catalogManager.saveCatalogs()

            HomeCatalogLayoutStore.shared.reloadFromStorage()
            Task { @MainActor in
                EclipseTheme.shared.reloadMediaAppearanceFromDefaults()
            }
        }
    }
    
    // MARK: - Export Backup
    
    /// Creates a backup file and returns the URL
    func createBackup() -> URL? {
        let backupData = gatherBackupData()
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            
            let jsonData = try encoder.encode(backupData)
            
            // Create filename with timestamp
            let timestamp = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let filename = "Eclipse_Backup_\(formatter.string(from: timestamp)).json"
            
            // Use Documents directory instead of temporary
            let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let backupURL = documentsDir.appendingPathComponent(filename)
            
            try jsonData.write(to: backupURL, options: .atomic)
            Logger.shared.log("Backup created at: \(backupURL.path)", type: "Info")
            
            return backupURL
        } catch {
            Logger.shared.log("Failed to create backup: \(error.localizedDescription)", type: "Error")
            return nil
        }
    }

    func createExperimentalCloudSnapshotData() -> Data? {
        let snapshot = gatherBackupData().redactedForExperimentalCloudSync()

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(snapshot)
        } catch {
            Logger.shared.log("Failed to create experimental iCloud snapshot: \(error.localizedDescription)", type: "iCloud")
            return nil
        }
    }

    func restoreExperimentalCloudSnapshot(
        from data: Data,
        preserveMediaStateForCloudKit: Bool = true
    ) -> Bool {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(BackupData.self, from: data).redactedForExperimentalCloudSync()
            let mediaStateAuthority = preserveMediaStateForCloudKit
                ? captureLegacyCloudMediaStateAuthority()
                : nil
            let restored = applyBackupData(snapshot, refreshCloudSources: true)
            if let mediaStateAuthority {
                restoreLegacyCloudMediaStateAuthority(mediaStateAuthority)
            }
            return restored
        } catch {
            Logger.shared.log("Failed to restore experimental iCloud snapshot: \(error.localizedDescription)", type: "iCloud")
            return false
        }
    }
    
    /// Gathers all user data for backup
    private func gatherBackupData() -> BackupData {
        let userDefaults = UserDefaults.standard
        
        // Get accent color
        var accentColorData: Data?
        if let colorData = userDefaults.data(forKey: "accentColor") {
            accentColorData = colorData
        }
        let settingsGradientColor = userDefaults.data(forKey: "eclipseThemeGradientColor")
        let readerAccentColor = userDefaults.data(forKey: "readerAccentColor")
        let readerSettingsGradientColor = userDefaults.data(forKey: "readerThemeGradientColor")
        
        // Get settings
        let selectedAppearance = BackupData.sanitizedAppearance(userDefaults.string(forKey: "selectedAppearance"))
        let readerSelectedAppearance = BackupData.sanitizedAppearance(userDefaults.string(forKey: "readerSelectedAppearance") ?? selectedAppearance)
        let readerGlobalAppearanceEnabled = userDefaults.object(forKey: "readerGlobalAppearanceEnabled") == nil ? true : userDefaults.bool(forKey: "readerGlobalAppearanceEnabled")
        let enableSubtitlesByDefault = userDefaults.bool(forKey: "enableSubtitlesByDefault")
        let defaultSubtitleLanguage = userDefaults.string(forKey: "defaultSubtitleLanguage") ?? "eng"
        let playerSubtitleAppearanceEnabled: Bool
        if userDefaults.object(forKey: "playerSubtitleAppearanceEnabled") == nil {
            playerSubtitleAppearanceEnabled = userDefaults.object(forKey: "enableVLCSubtitleEditMenu") as? Bool ?? true
        } else {
            playerSubtitleAppearanceEnabled = userDefaults.bool(forKey: "playerSubtitleAppearanceEnabled")
        }

        let preferredAutoAudioLanguage = userDefaults.string(forKey: "preferredAutoAudioLanguage") ?? "eng"
        let preferredAnimeAudioLanguage = userDefaults.string(forKey: "preferredAnimeAudioLanguage") ?? "jpn"
        let inAppPlayer = PlaybackEngine.selected(
            persistedEngine: userDefaults.string(forKey: PlaybackEngine.defaultsKey),
            legacyInAppPlayer: userDefaults.object(forKey: "inAppPlayer") as? String,
            deviceFamily: .current
        ).rawValue
        let tmdbLanguage = userDefaults.string(forKey: "tmdbLanguage") ?? "en-US"
        let showScheduleTab = userDefaults.bool(forKey: "showScheduleTab")
        let showLocalScheduleTime = userDefaults.bool(forKey: "showLocalScheduleTime")
        let defaultScheduleMode = ScheduleMode.sanitizedRawValue(userDefaults.string(forKey: "defaultScheduleMode"))
        let scheduleWindowDays = ScheduleWindow.sanitizedDays(userDefaults.object(forKey: ScheduleWindow.storageKey) as? Int)
        let localNotificationSubscriptions = userDefaults.string(forKey: "localNotificationSubscriptions")
        let localNotificationEpisodeReminders = userDefaults.string(forKey: "localNotificationEpisodeReminders")
        let localNotificationEpisodeLeadTime = userDefaults.object(forKey: "localNotificationEpisodeLeadTime") as? Int
        let localNotificationSeasonLeadTime = userDefaults.object(forKey: "localNotificationSeasonLeadTime") as? Int
        let localNotificationIncludeAnimeSpecials = userDefaults.object(forKey: "localNotificationIncludeAnimeSpecials") as? Bool
        
        // Player settings
        let savedDefaultPlaybackSpeed = userDefaults.double(forKey: "defaultPlaybackSpeed")
        let defaultPlaybackSpeed = savedDefaultPlaybackSpeed > 0 ? savedDefaultPlaybackSpeed : 1.0
        let savedHoldSpeed = userDefaults.double(forKey: "holdSpeedPlayer")
        let holdSpeedPlayer = savedHoldSpeed > 0 ? savedHoldSpeed : 2.0
        let externalPlayer = userDefaults.string(forKey: "externalPlayer") ?? "none"
        let preferDownloadedMedia = userDefaults.bool(forKey: "preferDownloadedMedia")
        let alwaysLandscape = userDefaults.bool(forKey: "alwaysLandscape")
        let playerPlaybackLockEnabled = PlayerPlaybackLockSettings.isEnabled(defaults: userDefaults)
        let aniSkipEnabled = userDefaults.object(forKey: "aniSkipEnabled") == nil ? true : userDefaults.bool(forKey: "aniSkipEnabled")
        let introDBEnabled = userDefaults.object(forKey: "introDBEnabled") == nil ? true : userDefaults.bool(forKey: "introDBEnabled")
        let introDBAppEnabled = userDefaults.object(forKey: "introDBAppEnabled") == nil ? true : userDefaults.bool(forKey: "introDBAppEnabled")
        let aniSkipAutoSkip = userDefaults.bool(forKey: "aniSkipAutoSkip")
        let skip85sEnabled = userDefaults.bool(forKey: "skip85sEnabled")
        let skip85sAlwaysVisible = userDefaults.bool(forKey: "skip85sAlwaysVisible")
        let showNextEpisodeButton = userDefaults.object(forKey: "showNextEpisodeButton") == nil ? true : userDefaults.bool(forKey: "showNextEpisodeButton")
        let showEpisodeBrowserButton = userDefaults.object(forKey: "showEpisodeBrowserButton") == nil
            ? (userDefaults.object(forKey: "showVLCEpisodeBrowserButton") as? Bool ?? true)
            : userDefaults.bool(forKey: "showEpisodeBrowserButton")
        let showPlayerServicesButton = PlayerServicesButtonSettings.isEnabled(defaults: userDefaults)
        let showNextEpisodePosterButton = userDefaults.bool(forKey: "showNextEpisodePosterButton")
        let savedNextThreshold = userDefaults.double(forKey: "nextEpisodeThreshold")
        let nextEpisodeThreshold = savedNextThreshold > 0 ? savedNextThreshold : 0.90
        let nextEpisodeSkipFillerEnabled = NextEpisodeFillerSettings.isEnabled(defaults: userDefaults)
        let playerBrightnessGestureEnabled = userDefaults.object(forKey: "playerBrightnessGestureEnabled") == nil
            ? (userDefaults.object(forKey: "vlcBrightnessGestureEnabled") as? Bool ?? false)
            : userDefaults.bool(forKey: "playerBrightnessGestureEnabled")
        let playerVolumeGestureEnabled = userDefaults.object(forKey: "playerVolumeGestureEnabled") == nil
            ? (userDefaults.object(forKey: "vlcVolumeGestureEnabled") as? Bool ?? false)
            : userDefaults.bool(forKey: "playerVolumeGestureEnabled")
        let playerTwoFingerTapPlayPauseEnabled: Bool
        if userDefaults.object(forKey: "playerTwoFingerTapPlayPauseEnabled") == nil {
            playerTwoFingerTapPlayPauseEnabled = userDefaults.object(forKey: "mpvTwoFingerTapEnabled") as? Bool ?? true
        } else {
            playerTwoFingerTapPlayPauseEnabled = userDefaults.bool(forKey: "playerTwoFingerTapPlayPauseEnabled")
        }
        let playerCenterTapPlayPauseEnabled = userDefaults.object(forKey: "playerCenterTapPlayPauseEnabled") == nil ? true : userDefaults.bool(forKey: "playerCenterTapPlayPauseEnabled")
        let playerDoubleTapSeekEnabled = userDefaults.object(forKey: "playerDoubleTapSeekEnabled") == nil
            ? (userDefaults.object(forKey: "vlcDoubleTapSeekEnabled") as? Bool ?? true)
            : userDefaults.bool(forKey: "playerDoubleTapSeekEnabled")
        let savedDoubleTapSeekSeconds = userDefaults.object(forKey: "playerDoubleTapSeekSeconds") == nil
            ? userDefaults.double(forKey: "vlcDoubleTapSeekSeconds")
            : userDefaults.double(forKey: "playerDoubleTapSeekSeconds")
        let playerDoubleTapSeekSeconds = savedDoubleTapSeekSeconds > 0 ? savedDoubleTapSeekSeconds : 10.0
        let playerOpenSubtitlesEnabled = userDefaults.object(forKey: "playerOpenSubtitlesEnabled") == nil
            ? (userDefaults.object(forKey: "vlcOpenSubtitlesEnabled") as? Bool ?? false)
            : userDefaults.bool(forKey: "playerOpenSubtitlesEnabled")
        let playerOpenSubtitlesAutoFallbackEnabled = userDefaults.object(forKey: "playerOpenSubtitlesAutoFallbackEnabled") == nil
            ? (userDefaults.object(forKey: "vlcOpenSubtitlesAutoFallbackEnabled") as? Bool ?? true)
            : userDefaults.bool(forKey: "playerOpenSubtitlesAutoFallbackEnabled")
        let playerPerformanceOverlayEnabled = false
        let mpvForegroundFPS = userDefaults.integer(forKey: "mpvForegroundFPS") == 60 ? 60 : 30
        let mpvRenderBackend = BackupData.sanitizedMPVRenderBackend(userDefaults.string(forKey: "mpvRenderBackend"))
        let mpvMetalQualityProfile = BackupData.sanitizedMPVMetalQualityProfile(userDefaults.string(forKey: "mpvMetalQualityProfile"))
        let mpvUpscalingMode = BackupData.sanitizedMPVUpscalingMode(userDefaults.string(forKey: "mpvUpscalingMode"))
        let mpvPlayerSkin = BackupData.sanitizedMPVPlayerSkin(userDefaults.string(forKey: MPVPlayerSkinSettings.skinKey))
        let mpvPlayerSkinCustomPrimaryColor = userDefaults.data(forKey: MPVPlayerSkinSettings.customPrimaryColorKey)
        let mpvPlayerSkinCustomSecondaryColor = userDefaults.data(forKey: MPVPlayerSkinSettings.customSecondaryColorKey)
        let mpvPlayerSkinAnimationsEnabled = MPVPlayerSkinSettings.animationsEnabled(defaults: userDefaults)
        let mpvPlayerSkinTintControlsOnly = MPVPlayerSkinSettings.tintControlsOnly(defaults: userDefaults)
        let mpvPictureInPictureEnabled = userDefaults.object(forKey: "mpvPictureInPictureEnabled") as? Bool ?? true
        let mpvAppExitPictureInPictureEnabled = userDefaults.bool(forKey: "mpvAppExitPictureInPictureEnabled")
        let mpvHDRMode = MPVHDRMode(rawValue: userDefaults.string(forKey: "mpvHDRMode") ?? MPVHDRMode.defaultMode.rawValue)?.rawValue ?? MPVHDRMode.defaultMode.rawValue
        let mpvSurroundSoundEnabled = userDefaults.object(forKey: "mpvSurroundSoundEnabled") == nil ? true : userDefaults.bool(forKey: "mpvSurroundSoundEnabled")
        let watchTogetherEnabled = WatchTogetherSettings.isEnabled(defaults: userDefaults)
        let smartInAppPlayerChoosingEnabled = false
        ExperimentalFeatureState.registerDefaults(defaults: userDefaults)
        let experimentalFeaturesEnabled = userDefaults.bool(forKey: ExperimentalFeatureState.enabledKey)
        let experimentalFeaturesLastChangedAt = userDefaults.double(forKey: ExperimentalFeatureState.lastChangedAtKey)
        let experimentalMPVPreloadEnabled = userDefaults.bool(forKey: ExperimentalFeatureState.mpvPreloadEnabledKey)
        let experimentalMPVSmoothTransitionEnabled = userDefaults.bool(forKey: ExperimentalFeatureState.mpvSmoothTransitionEnabledKey)
        let experimentalMPVPreloadCellularEnabled = userDefaults.bool(forKey: ExperimentalFeatureState.mpvPreloadCellularEnabledKey)
        let experimentalMPVPreloadWifiLimitMB = ExperimentalFeatureState.resolvedMPVPreloadWifiLimitMB(userDefaults.integer(forKey: ExperimentalFeatureState.mpvPreloadWifiLimitMBKey))
        let experimentalMPVPreloadCellularLimitMB = ExperimentalFeatureState.resolvedMPVPreloadCellularLimitMB(userDefaults.integer(forKey: ExperimentalFeatureState.mpvPreloadCellularLimitMBKey))
        let experimentalMPVShowRemainingTime = userDefaults.bool(forKey: ExperimentalFeatureState.mpvShowRemainingTimeKey)
        let experimentalMPVPreciseProgress = userDefaults.bool(forKey: ExperimentalFeatureState.mpvPreciseProgressKey)
        let experimentalMPVIgnoreSpecialSubtitleStyles = userDefaults.bool(forKey: ExperimentalFeatureState.mpvIgnoreSpecialSubtitleStylesKey)
        let experimentalMPVPreloadAutoClear = userDefaults.bool(forKey: ExperimentalFeatureState.mpvPreloadAutoClearKey)
        let experimentalICloudSyncEnabled = userDefaults.bool(forKey: ExperimentalFeatureState.iCloudSyncEnabledKey)

        // Subtitle styling
        let subtitleForegroundColor = userDefaults.data(forKey: "subtitles_foregroundColor")
        let subtitleStrokeColor = userDefaults.data(forKey: "subtitles_strokeColor")
        let savedStrokeWidth = userDefaults.double(forKey: "subtitles_strokeWidth")
        let subtitleStrokeWidth = savedStrokeWidth >= 0 ? savedStrokeWidth : 1.0
        let savedFontSize = userDefaults.double(forKey: "subtitles_fontSize")
        let subtitleFontSize = savedFontSize > 0 ? savedFontSize : 30.0
        let subtitleVerticalOffset: Double
        if userDefaults.object(forKey: "playerSubtitleOverlayBottomConstant") != nil {
            subtitleVerticalOffset = userDefaults.double(forKey: "playerSubtitleOverlayBottomConstant")
        } else if userDefaults.object(forKey: "vlcSubtitleOverlayBottomConstant") != nil {
            subtitleVerticalOffset = userDefaults.double(forKey: "vlcSubtitleOverlayBottomConstant")
        } else {
            subtitleVerticalOffset = -6.0
        }
        let subtitlesVisible = userDefaults.bool(forKey: "subtitles_isVisible")

        // UI preferences
        let showKanzen = userDefaults.bool(forKey: "showKanzen")
        let hideSplashScreen = userDefaults.bool(forKey: "hideSplashScreen")
        let modeSwitchAnimationEnabled = ModeSwitchAnimationSettings.isEnabled(defaults: userDefaults)
        let kanzenAutoUpdateModules = ModuleManager.isAutoUpdateEnabled
        let seasonMenu = MediaDetailPlatformDefaults.usesCompactSeasonMenu(defaults: userDefaults)
        let horizontalEpisodeList = MediaDetailPlatformDefaults.usesHorizontalEpisodes(defaults: userDefaults)
        let mediaDetailTitleArtworkEnabled = MediaDetailTitleArtworkSettings.isEnabled(defaults: userDefaults)
        let mediaDetailSimilarTitlesEnabled = MediaDetailSimilarTitlesSettings.isEnabled(defaults: userDefaults)
        let useClassicScheduleUI = userDefaults.bool(forKey: "useClassicScheduleUI")
        let heroBannerCatalogId = BackupData.sanitizedNonEmptyString(userDefaults.string(forKey: "heroBannerCatalogId"), defaultValue: "trending")
        let heroBannerBehavior = BackupData.sanitizedHeroBannerBehavior(userDefaults.string(forKey: "heroBannerBehavior"))
        let homeCatalogLayoutOverrides = userDefaults.data(forKey: HomeCatalogLayoutStore.storageKey).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let homeAnimatedBackgroundEnabled = HomeAnimatedBackgroundSettings.isEnabled(defaults: userDefaults)
        let homeAnimatedBackgroundQuality = BackupData.sanitizedHomeAnimatedBackgroundQuality(userDefaults.string(forKey: HomeAnimatedBackgroundQuality.storageKey))
        let homeAnimatedBackgroundFrameRate = BackupData.sanitizedHomeAnimatedBackgroundFrameRate(userDefaults.string(forKey: HomeAnimatedBackgroundFrameRate.storageKey))
        let appPerformanceOverlayEnabled = AppPerformanceOverlaySettings.isEnabled(defaults: userDefaults)
        let experimentalMediaDesignPreset = BackupData.sanitizedExperimentalMediaDesignPreset(userDefaults.string(forKey: ExperimentalMediaDesignPreset.storageKey))
        let experimentalHeroBleedLevel = BackupData.sanitizedExperimentalHeroBleedLevel(userDefaults.string(forKey: ExperimentalHeroBleedLevel.storageKey))
        let experimentalHomeCardShape = BackupData.sanitizedExperimentalHomeCardShape(userDefaults.string(forKey: ExperimentalHomeCardShape.storageKey))
        let experimentalMultiGradientPalette = BackupData.sanitizedExperimentalMultiGradientPalette(userDefaults.string(forKey: ExperimentalMultiGradientPalette.storageKey))
        let experimentalHeroHeightScale = BackupData.sanitizedExperimentalHeroHeightScale(BackupData.optionalDouble(from: userDefaults.object(forKey: ExperimentalVisualTuning.heroHeightScaleKey), defaultValue: ExperimentalVisualTuning.defaultHeroHeightScale))
        let experimentalHeroBleedStrength = BackupData.sanitizedExperimentalHeroBleedStrength(BackupData.optionalDouble(from: userDefaults.object(forKey: ExperimentalVisualTuning.heroBleedStrengthKey), defaultValue: ExperimentalVisualTuning.defaultHeroBleedStrength))
        let experimentalHeroFadeDistanceScale = BackupData.sanitizedExperimentalHeroFadeDistanceScale(BackupData.optionalDouble(from: userDefaults.object(forKey: ExperimentalVisualTuning.heroFadeDistanceScaleKey), defaultValue: ExperimentalVisualTuning.defaultHeroFadeDistanceScale))
        let experimentalSectionSpacingScale = BackupData.sanitizedExperimentalSectionSpacingScale(BackupData.optionalDouble(from: userDefaults.object(forKey: ExperimentalVisualTuning.sectionSpacingScaleKey), defaultValue: ExperimentalVisualTuning.defaultSectionSpacingScale))
        let experimentalCardRadiusScale = BackupData.sanitizedExperimentalCardRadiusScale(BackupData.optionalDouble(from: userDefaults.object(forKey: ExperimentalVisualTuning.cardRadiusScaleKey), defaultValue: ExperimentalVisualTuning.defaultCardRadiusScale))
        let experimentalMediaCardScale = BackupData.sanitizedExperimentalMediaCardScale(BackupData.optionalDouble(from: userDefaults.object(forKey: ExperimentalVisualTuning.mediaCardScaleKey), defaultValue: ExperimentalVisualTuning.defaultMediaCardScale))
        let experimentalGlassStrength = BackupData.sanitizedExperimentalGlassStrength(BackupData.optionalDouble(from: userDefaults.object(forKey: ExperimentalVisualTuning.glassStrengthKey), defaultValue: ExperimentalVisualTuning.defaultGlassStrength))
        let experimentalGradientBaseDarkness = BackupData.sanitizedExperimentalGradientBaseDarkness(BackupData.optionalDouble(from: userDefaults.object(forKey: ExperimentalVisualTuning.gradientBaseDarknessKey), defaultValue: ExperimentalVisualTuning.defaultGradientBaseDarkness))
        let experimentalGradientAccentIntensity = BackupData.sanitizedExperimentalGradientAccentIntensity(BackupData.optionalDouble(from: userDefaults.object(forKey: ExperimentalVisualTuning.gradientAccentIntensityKey), defaultValue: ExperimentalVisualTuning.defaultGradientAccentIntensity))
        let experimentalGradientScrollMotion = BackupData.sanitizedExperimentalGradientScrollMotion(BackupData.optionalDouble(from: userDefaults.object(forKey: ExperimentalVisualTuning.gradientScrollMotionKey), defaultValue: ExperimentalVisualTuning.defaultGradientScrollMotion))
        let experimentalGradientUseCustomColors = userDefaults.bool(forKey: ExperimentalVisualTuning.gradientUseCustomColorsKey)
        let experimentalGradientColorA = userDefaults.data(forKey: ExperimentalVisualTuning.gradientColorAKey)
        let experimentalGradientColorB = userDefaults.data(forKey: ExperimentalVisualTuning.gradientColorBKey)
        let experimentalGradientColorC = userDefaults.data(forKey: ExperimentalVisualTuning.gradientColorCKey)
        let atmosphereStyle = BackupData.sanitizedAtmosphereStyle(userDefaults.string(forKey: "atmosphereStyle"))
        let atmosphereSolidColorSource = BackupData.sanitizedAtmosphereSolidColorSource(userDefaults.string(forKey: "atmosphereSolidColorSource"))
        let atmosphereSolidColor = userDefaults.data(forKey: "atmosphereSolidColor")
        let readerAtmosphereStyle = BackupData.sanitizedAtmosphereStyle(userDefaults.string(forKey: "readerAtmosphereStyle") ?? atmosphereStyle)
        let readerAtmosphereSolidColorSource = BackupData.sanitizedAtmosphereSolidColorSource(userDefaults.string(forKey: "readerAtmosphereSolidColorSource") ?? atmosphereSolidColorSource)
        let readerAtmosphereSolidColor = userDefaults.data(forKey: "readerAtmosphereSolidColor")
        let mediaDetailElementOrder = BackupData.sanitizedMediaDetailElementOrder(userDefaults.string(forKey: MediaDetailElement.orderStorageKey))
        let mediaDetailHiddenElements = MediaDetailElement.rawValue(for: MediaDetailElement.hiddenElements(defaults: userDefaults))
        let readerDetailElementOrder = BackupData.sanitizedReaderDetailElementOrder(userDefaults.string(forKey: ReaderDetailElement.orderStorageKey))
        let readerDetailHiddenElements = ReaderDetailElement.rawValue(for: ReaderDetailElement.hiddenElements(defaults: userDefaults))
        let mediaColumnsPortrait = userDefaults.object(forKey: "mediaColumnsPortrait") != nil ? userDefaults.integer(forKey: "mediaColumnsPortrait") : 3
        let mediaColumnsLandscape = userDefaults.object(forKey: "mediaColumnsLandscape") != nil ? userDefaults.integer(forKey: "mediaColumnsLandscape") : 5

        // Manga / Reader
        let readingMode = userDefaults.object(forKey: "readingMode") != nil ? userDefaults.integer(forKey: "readingMode") : ReadingMode.WEBTOON.rawValue
        let kanzenReaderMode = BackupData.sanitizedKanzenReaderMode(userDefaults.string(forKey: "kanzenReaderMode") ?? BackupData.defaultKanzenReaderModeRawValue())
        let userDefaultsSnapshot = userDefaults.dictionaryRepresentation()
        let kanzenReaderModeOverrides = BackupData.sanitizedKanzenReaderModeOverrides(
            userDefaultsSnapshot.reduce(into: [String: String]()) { result, item in
                guard item.key.hasPrefix("kanzenReaderMode."),
                      let value = item.value as? String else { return }
                result[String(item.key.dropFirst("kanzenReaderMode.".count))] = value
            }
        )
        let readerDownsampleImages = userDefaults.object(forKey: "Reader.downsampleImages") == nil ? true : userDefaults.bool(forKey: "Reader.downsampleImages")
        let readerCropBorders = userDefaults.bool(forKey: "Reader.cropBorders")
        let readerDisableQuickActions = userDefaults.bool(forKey: "Reader.disableQuickActions")
        let readerDisableDoubleTap = userDefaults.bool(forKey: "Reader.disableDoubleTap")
        let readerLiveText = userDefaults.bool(forKey: "Reader.liveText")
        let readerHideBarsOnSwipe = userDefaults.bool(forKey: "Reader.hideBarsOnSwipe")
        let readerBackgroundColor = BackupData.sanitizedReaderBackgroundColor(userDefaults.string(forKey: "Reader.backgroundColor"))
        let readerOrientation = BackupData.sanitizedReaderOrientation(userDefaults.string(forKey: "Reader.orientation"))
        let readerTapZones = BackupData.sanitizedReaderTapZones(userDefaults.string(forKey: "Reader.tapZones"))
        let readerInvertTapZones = userDefaults.bool(forKey: "Reader.invertTapZones")
        let readerAnimatePageTransitions = userDefaults.object(forKey: "Reader.animatePageTransitions") == nil ? true : userDefaults.bool(forKey: "Reader.animatePageTransitions")
        let readerUpscaleImages = userDefaults.bool(forKey: "Reader.upscaleImages")
        let readerUpscaleMaxHeight = BackupData.sanitizedReaderUpscaleMaxHeight(BackupData.optionalInt(from: userDefaults.object(forKey: "Reader.upscaleMaxHeight"), defaultValue: 2000))
        let readerUpscaleModelName = userDefaults.string(forKey: "Reader.upscaleModelName") ?? "None"
        let readerPagesToPreload = BackupData.sanitizedReaderPagesToPreload(BackupData.optionalInt(from: userDefaults.object(forKey: "Reader.pagesToPreload"), defaultValue: 3))
        let readerPagedPageLayout = BackupData.sanitizedReaderPagedPageLayout(userDefaults.string(forKey: "Reader.pagedPageLayout"))
        let readerPagedPageOffset = userDefaults.bool(forKey: "Reader.pagedPageOffset")
        let readerPagedPageOffsetOverrides = BackupData.sanitizedReaderPagedPageOffsetOverrides(
            userDefaultsSnapshot.reduce(into: [String: Bool]()) { result, item in
                guard item.key.hasPrefix("Reader.pagedPageOffset."),
                      let value = item.value as? Bool else { return }
                result[String(item.key.dropFirst("Reader.pagedPageOffset.".count))] = value
            }
        )
        let readerSplitWideImages = userDefaults.bool(forKey: "Reader.splitWideImages")
        let readerReverseSplitOrder = userDefaults.bool(forKey: "Reader.reverseSplitOrder")
        let readerVerticalInfiniteScroll = userDefaults.object(forKey: "Reader.verticalInfiniteScroll") == nil ? true : userDefaults.bool(forKey: "Reader.verticalInfiniteScroll")
        let readerPillarbox = userDefaults.bool(forKey: "Reader.pillarbox")
        let readerPillarboxAmount = BackupData.sanitizedReaderPillarboxAmount(BackupData.optionalDouble(from: userDefaults.object(forKey: "Reader.pillarboxAmount"), defaultValue: 15))
        let readerPillarboxOrientation = BackupData.sanitizedReaderPillarboxOrientation(userDefaults.string(forKey: "Reader.pillarboxOrientation"))
        let readerOrientationLockEnabled = userDefaults.bool(forKey: "readerOrientationLockEnabled")
        let readerOrientationLockMask = BackupData.sanitizedReaderOrientationLockMask(userDefaults.string(forKey: "readerOrientationLockMask"))
        let readerReadThresholdPercent = BackupData.sanitizedReaderReadThresholdPercent(userDefaults.object(forKey: "readerReadThresholdPercent") as? Double)

        // Novel Reader
        let savedReaderFontSize = userDefaults.double(forKey: "readerFontSize")
        let readerFontSize = savedReaderFontSize > 0 ? savedReaderFontSize : 16
        let readerFontFamily = userDefaults.string(forKey: "readerFontFamily") ?? "-apple-system"
        let readerFontWeight = userDefaults.string(forKey: "readerFontWeight") ?? "normal"
        let readerColorPreset = userDefaults.integer(forKey: "readerColorPreset")
        let readerTextAlignment = userDefaults.string(forKey: "readerTextAlignment") ?? "left"
        let savedReaderLineSpacing = userDefaults.double(forKey: "readerLineSpacing")
        let readerLineSpacing = savedReaderLineSpacing > 0 ? savedReaderLineSpacing : 1.6
        let savedReaderMargin = userDefaults.object(forKey: "readerMargin") != nil ? userDefaults.double(forKey: "readerMargin") : 4
        let readerMargin = savedReaderMargin

        // Other
        let autoClearCacheEnabled = userDefaults.bool(forKey: "autoClearCacheEnabled")
        let savedCacheThreshold = userDefaults.double(forKey: "autoClearCacheThresholdMB")
        let autoClearCacheThresholdMB = savedCacheThreshold > 0 ? savedCacheThreshold : 500
        let savedQualityThreshold = userDefaults.object(forKey: "highQualityThreshold") as? Double ?? 0.9
        let highQualityThreshold = savedQualityThreshold
        let backgroundHLSPipelineEnabled = userDefaults.bool(forKey: "backgroundHLSPipelineEnabled")
        let readerDownloadsBackgroundEnabled = userDefaults.object(forKey: "readerDownloadsBackgroundEnabled") == nil ? true : userDefaults.bool(forKey: "readerDownloadsBackgroundEnabled")
        let readerDownloadsWifiOnly = userDefaults.bool(forKey: "readerDownloadsWifiOnly")
        let readerDownloadsParallelLimit = BackupData.sanitizedReaderDownloadsParallelLimit(BackupData.optionalInt(from: userDefaults.object(forKey: "readerDownloadsParallelLimit"), defaultValue: 2))
        let autoUpdateServicesEnabled = userDefaults.object(forKey: "autoUpdateServicesEnabled") == nil ? true : userDefaults.bool(forKey: "autoUpdateServicesEnabled")
        let servicesAutoModeEnabled = userDefaults.bool(forKey: "servicesAutoModeEnabled")
        let servicesAutoSelectEpisodesEnabled = userDefaults.bool(forKey: "servicesAutoSelectEpisodesEnabled")
        let servicesAutoModeSourceIds = BackupData.sanitizedStringList(userDefaults.stringArray(forKey: "servicesAutoModeSourceIds"))
        let servicesAutoModeSourceOrderIds = BackupData.sanitizedStringList(userDefaults.stringArray(forKey: "servicesAutoModeSourceOrderIds"))
        let servicesAutoModeQualityPreference = AutoModeQualityPreference.sanitizedRawValue(userDefaults.string(forKey: AutoModeQualityPreference.storageKey))
        let servicesResultMinimumSimilarity = ServicesResultRankingSettings.minimumSimilarity(defaults: userDefaults)
        let servicesDropMismatchedResults = ServicesResultRankingSettings.dropsMismatchedResults(defaults: userDefaults)
        let servicesStremioStyleSheetEnabled = ServicesSheetPresentationSettings.usesStremioStyle(defaults: userDefaults)
        let servicesIncludedStreamLanguages = StreamLanguageFilter.includedLanguages(defaults: userDefaults)
        let servicesHiddenStreamLanguages = StreamLanguageFilter.hiddenLanguages(defaults: userDefaults)
        let servicesHideStreamsWithoutLanguageData = StreamLanguageFilter.hidesStreamsWithoutLanguageData(defaults: userDefaults)
        let servicesAssumeOriginalAudio = StreamLanguageFilter.assumesOriginalAudio(defaults: userDefaults)
        let servicesTreatDubbedAnimeAsEnglish = StreamLanguageFilter.treatsDubbedAnimeAsEnglish(defaults: userDefaults)
        let servicesHiddenStreamQualities = StreamLanguageFilter.hiddenQualityHeights(defaults: userDefaults)
        let servicesHideStreamsWithoutDetectedQuality = StreamLanguageFilter.hidesStreamsWithoutDetectedQuality(defaults: userDefaults)
        let servicesExtraRulesSourceIds = StreamLanguageFilter.extraRulesSourceIds(defaults: userDefaults)
        let githubReleaseAutoCheckEnabled = userDefaults.object(forKey: "githubReleaseAutoCheckEnabled") == nil ? true : userDefaults.bool(forKey: "githubReleaseAutoCheckEnabled")
        let githubReleaseUpdateAvailable = userDefaults.bool(forKey: "githubReleaseUpdateAvailable")
        let githubReleaseLatestVersion = userDefaults.string(forKey: "githubReleaseLatestVersion") ?? ""
        let githubReleaseURL = userDefaults.string(forKey: "githubReleaseURL") ?? ""
        let githubReleaseShowAlertPending = userDefaults.bool(forKey: "githubReleaseShowAlertPending")
        let githubReleaseLastPromptedVersion = userDefaults.string(forKey: "githubReleaseLastPromptedVersion") ?? ""
        let filterHorrorContent = userDefaults.bool(forKey: "filterHorror")
        let selectedSimilarityAlgorithm = BackupData.sanitizedSimilarityAlgorithm(userDefaults.string(forKey: "selectedSimilarityAlgorithm"))
        let performanceModeEnabled = PerformanceModeSettings.isEnabled
        let performanceModeSkipAniListTraversalForAnimeDetails = PerformanceModeSettings.skipsAniListTraversalForAnimeDetails
        let performanceModeFastAnimeCatalogOverrides = PerformanceModeSettings.fastAnimeCatalogOverrides
        let kanzenHomeSelectedSourceID = userDefaults.string(forKey: "kanzenHomeSelectedSourceID") ?? ""
        let kanzenRecentSourceSearches = BackupData.sanitizedStringList(userDefaults.stringArray(forKey: "kanzenRecentSourceSearches"))
        let searchHistory: BackupSearchHistory
        if let historyData = userDefaults.data(forKey: "searchHistory"),
           let decoded = try? JSONDecoder().decode([String].self, from: historyData) {
            searchHistory = BackupSearchHistory(queries: decoded)
        } else {
            searchHistory = BackupSearchHistory()
        }
        
        // Get library collections
        let libraryManager = LibraryManager.shared
        let backupCollections = libraryManager.collections.map { BackupCollection(from: $0) }
        
        // Get progress data - read directly from the internal storage
        let progressManager = ProgressManager.shared
        let progressData = progressManager.getProgressData()
        
        // Get tracker state, including connected AniList/MAL/Trakt accounts and sync settings.
        let trackerManager = TrackerManager.shared
        let trackerState: TrackerState
        if Thread.isMainThread {
            trackerState = Self.trackerStateWithoutCredentials(trackerManager.trackerState)
        } else {
            trackerState = DispatchQueue.main.sync {
                Self.trackerStateWithoutCredentials(trackerManager.trackerState)
            }
        }
        
        // Get catalogs
        let catalogManager = CatalogManager.shared
        let catalogs = catalogManager.catalogs

        // Get services
        let services = ServiceStore.shared.getServices().map { service -> BackupService in
            let metadataData = (try? JSONEncoder().encode(service.metadata)) ?? Data()
            let metadataString = String(data: metadataData, encoding: .utf8) ?? "{}"
            return BackupService(id: service.id, url: service.url, jsonMetadata: metadataString, jsScript: service.jsScript, isActive: service.isActive, sortIndex: service.sortIndex)
        }

        // Get Stremio addons directly from CoreData entities so configured URLs and raw manifests survive backup exactly.
        let stremioAddons = StremioAddonStore.shared.getEntities().compactMap { entity -> BackupStremioAddon? in
            guard
                let id = entity.id,
                let configuredURL = entity.configuredURL,
                let manifestJSON = entity.manifestJSON
            else {
                return nil
            }

            return BackupStremioAddon(
                id: id,
                configuredURL: configuredURL,
                manifestJSON: manifestJSON,
                isActive: entity.isActive,
                sortIndex: entity.sortIndex
            )
        }

        // Get manga library collections
        let mangaLibraryManager = MangaLibraryManager.shared
        let mangaCollections = mangaLibraryManager.collections.map { collection in
            BackupMangaCollection(
                id: collection.id,
                name: collection.name,
                items: collection.items,
                description: collection.description
            )
        }

        // Get manga reading progress
        let mangaProgressManager = MangaReadingProgressManager.shared
        let mangaReadingProgress = Dictionary(
            uniqueKeysWithValues: mangaProgressManager.progressMap.map { ("\($0.key)", $0.value) }
        )

        // Get manga catalogs
        let mangaCatalogManager = MangaCatalogManager.shared
        let mangaCatalogs = mangaCatalogManager.catalogs

        // Get Kanzen modules
        let kanzenModules = ModuleManager.shared.modules.map { mod in
            BackupKanzenModule(
                id: mod.id,
                moduleData: mod.moduleData,
                localPath: mod.localPath,
                moduleurl: mod.moduleurl,
                isActive: mod.isActive
            )
        }

#if !os(tvOS)
        let aidokuState = AidokuBackupBridge.backupSnapshotFromDisk()
#else
        let aidokuState: BackupAidokuState? = nil
#endif
        
        let backup = BackupData(
            createdDate: Date(),
            accentColor: accentColorData,
            settingsGradientColor: settingsGradientColor,
            readerAccentColor: readerAccentColor,
            tmdbLanguage: tmdbLanguage,
            selectedAppearance: selectedAppearance,
            readerSelectedAppearance: readerSelectedAppearance,
            readerGlobalAppearanceEnabled: readerGlobalAppearanceEnabled,
            readerSettingsGradientColor: readerSettingsGradientColor,
            enableSubtitlesByDefault: enableSubtitlesByDefault,
            defaultSubtitleLanguage: defaultSubtitleLanguage,
            playerSubtitleAppearanceEnabled: playerSubtitleAppearanceEnabled,

            preferredAutoAudioLanguage: preferredAutoAudioLanguage,
            preferredAnimeAudioLanguage: preferredAnimeAudioLanguage,
            inAppPlayer: inAppPlayer,
            showScheduleTab: showScheduleTab,
            showLocalScheduleTime: showLocalScheduleTime,
            defaultScheduleMode: defaultScheduleMode,
            scheduleWindowDays: scheduleWindowDays,
            localNotificationSubscriptions: localNotificationSubscriptions,
            localNotificationEpisodeReminders: localNotificationEpisodeReminders,
            localNotificationEpisodeLeadTime: localNotificationEpisodeLeadTime,
            localNotificationSeasonLeadTime: localNotificationSeasonLeadTime,
            localNotificationIncludeAnimeSpecials: localNotificationIncludeAnimeSpecials,

            defaultPlaybackSpeed: defaultPlaybackSpeed,
            holdSpeedPlayer: holdSpeedPlayer,
            externalPlayer: externalPlayer,
            preferDownloadedMedia: preferDownloadedMedia,
            alwaysLandscape: alwaysLandscape,
            playerPlaybackLockEnabled: playerPlaybackLockEnabled,
            aniSkipEnabled: aniSkipEnabled,
            introDBEnabled: introDBEnabled,
            introDBAppEnabled: introDBAppEnabled,
            aniSkipAutoSkip: aniSkipAutoSkip,
            skip85sEnabled: skip85sEnabled,
            skip85sAlwaysVisible: skip85sAlwaysVisible,
            showNextEpisodeButton: showNextEpisodeButton,
            showEpisodeBrowserButton: showEpisodeBrowserButton,
            showPlayerServicesButton: showPlayerServicesButton,
            showNextEpisodePosterButton: showNextEpisodePosterButton,
            nextEpisodeThreshold: nextEpisodeThreshold,
            nextEpisodeSkipFillerEnabled: nextEpisodeSkipFillerEnabled,
            playerBrightnessGestureEnabled: playerBrightnessGestureEnabled,
            playerVolumeGestureEnabled: playerVolumeGestureEnabled,
            playerTwoFingerTapPlayPauseEnabled: playerTwoFingerTapPlayPauseEnabled,
            playerCenterTapPlayPauseEnabled: playerCenterTapPlayPauseEnabled,
            playerDoubleTapSeekEnabled: playerDoubleTapSeekEnabled,
            playerDoubleTapSeekSeconds: playerDoubleTapSeekSeconds,
            playerOpenSubtitlesEnabled: playerOpenSubtitlesEnabled,
            playerOpenSubtitlesAutoFallbackEnabled: playerOpenSubtitlesAutoFallbackEnabled,
            playerPerformanceOverlayEnabled: playerPerformanceOverlayEnabled,
            mpvForegroundFPS: mpvForegroundFPS,
            mpvRenderBackend: mpvRenderBackend,
            mpvMetalQualityProfile: mpvMetalQualityProfile,
            mpvUpscalingMode: mpvUpscalingMode,
            mpvPlayerSkin: mpvPlayerSkin,
            mpvPlayerSkinCustomPrimaryColor: mpvPlayerSkinCustomPrimaryColor,
            mpvPlayerSkinCustomSecondaryColor: mpvPlayerSkinCustomSecondaryColor,
            mpvPlayerSkinAnimationsEnabled: mpvPlayerSkinAnimationsEnabled,
            mpvPlayerSkinTintControlsOnly: mpvPlayerSkinTintControlsOnly,
            mpvPictureInPictureEnabled: mpvPictureInPictureEnabled,
            mpvAppExitPictureInPictureEnabled: mpvAppExitPictureInPictureEnabled,
            mpvHDRMode: mpvHDRMode,
            mpvSurroundSoundEnabled: mpvSurroundSoundEnabled,
            watchTogetherEnabled: watchTogetherEnabled,
            smartInAppPlayerChoosingEnabled: smartInAppPlayerChoosingEnabled,
            experimentalFeaturesEnabled: experimentalFeaturesEnabled,
            experimentalFeaturesLastChangedAt: experimentalFeaturesLastChangedAt,
            experimentalMPVPreloadEnabled: experimentalMPVPreloadEnabled,
            experimentalMPVSmoothTransitionEnabled: experimentalMPVSmoothTransitionEnabled,
            experimentalMPVPreloadCellularEnabled: experimentalMPVPreloadCellularEnabled,
            experimentalMPVPreloadWifiLimitMB: experimentalMPVPreloadWifiLimitMB,
            experimentalMPVPreloadCellularLimitMB: experimentalMPVPreloadCellularLimitMB,
            experimentalMPVShowRemainingTime: experimentalMPVShowRemainingTime,
            experimentalMPVPreciseProgress: experimentalMPVPreciseProgress,
            experimentalMPVIgnoreSpecialSubtitleStyles: experimentalMPVIgnoreSpecialSubtitleStyles,
            experimentalMPVPreloadAutoClear: experimentalMPVPreloadAutoClear,
            experimentalICloudSyncEnabled: experimentalICloudSyncEnabled,

            subtitleForegroundColor: subtitleForegroundColor,
            subtitleStrokeColor: subtitleStrokeColor,
            subtitleStrokeWidth: subtitleStrokeWidth,
            subtitleFontSize: subtitleFontSize,
            subtitleVerticalOffset: subtitleVerticalOffset,
            subtitlesVisible: subtitlesVisible,

            showKanzen: showKanzen,
            hideSplashScreen: hideSplashScreen,
            modeSwitchAnimationEnabled: modeSwitchAnimationEnabled,
            kanzenAutoUpdateModules: kanzenAutoUpdateModules,
            seasonMenu: seasonMenu,
            horizontalEpisodeList: horizontalEpisodeList,
            mediaDetailTitleArtworkEnabled: mediaDetailTitleArtworkEnabled,
            mediaDetailSimilarTitlesEnabled: mediaDetailSimilarTitlesEnabled,
            useClassicScheduleUI: useClassicScheduleUI,
            heroBannerCatalogId: heroBannerCatalogId,
            heroBannerBehavior: heroBannerBehavior,
            homeCatalogLayoutOverrides: homeCatalogLayoutOverrides,
            homeAnimatedBackgroundEnabled: homeAnimatedBackgroundEnabled,
            homeAnimatedBackgroundQuality: homeAnimatedBackgroundQuality,
            homeAnimatedBackgroundFrameRate: homeAnimatedBackgroundFrameRate,
            appPerformanceOverlayEnabled: appPerformanceOverlayEnabled,
            experimentalMediaDesignPreset: experimentalMediaDesignPreset,
            experimentalHeroBleedLevel: experimentalHeroBleedLevel,
            experimentalHomeCardShape: experimentalHomeCardShape,
            experimentalMultiGradientPalette: experimentalMultiGradientPalette,
            experimentalHeroHeightScale: experimentalHeroHeightScale,
            experimentalHeroBleedStrength: experimentalHeroBleedStrength,
            experimentalHeroFadeDistanceScale: experimentalHeroFadeDistanceScale,
            experimentalSectionSpacingScale: experimentalSectionSpacingScale,
            experimentalCardRadiusScale: experimentalCardRadiusScale,
            experimentalMediaCardScale: experimentalMediaCardScale,
            experimentalGlassStrength: experimentalGlassStrength,
            experimentalGradientBaseDarkness: experimentalGradientBaseDarkness,
            experimentalGradientAccentIntensity: experimentalGradientAccentIntensity,
            experimentalGradientScrollMotion: experimentalGradientScrollMotion,
            experimentalGradientUseCustomColors: experimentalGradientUseCustomColors,
            experimentalGradientColorA: experimentalGradientColorA,
            experimentalGradientColorB: experimentalGradientColorB,
            experimentalGradientColorC: experimentalGradientColorC,
            atmosphereStyle: atmosphereStyle,
            atmosphereSolidColorSource: atmosphereSolidColorSource,
            atmosphereSolidColor: atmosphereSolidColor,
            readerAtmosphereStyle: readerAtmosphereStyle,
            readerAtmosphereSolidColorSource: readerAtmosphereSolidColorSource,
            readerAtmosphereSolidColor: readerAtmosphereSolidColor,
            mediaDetailElementOrder: mediaDetailElementOrder,
            mediaDetailHiddenElements: mediaDetailHiddenElements,
            readerDetailElementOrder: readerDetailElementOrder,
            readerDetailHiddenElements: readerDetailHiddenElements,
            mediaColumnsPortrait: mediaColumnsPortrait,
            mediaColumnsLandscape: mediaColumnsLandscape,

            readingMode: readingMode,
            kanzenReaderMode: kanzenReaderMode,
            kanzenReaderModeOverrides: kanzenReaderModeOverrides,
            readerDownsampleImages: readerDownsampleImages,
            readerCropBorders: readerCropBorders,
            readerDisableQuickActions: readerDisableQuickActions,
            readerDisableDoubleTap: readerDisableDoubleTap,
            readerLiveText: readerLiveText,
            readerHideBarsOnSwipe: readerHideBarsOnSwipe,
            readerBackgroundColor: readerBackgroundColor,
            readerOrientation: readerOrientation,
            readerTapZones: readerTapZones,
            readerInvertTapZones: readerInvertTapZones,
            readerAnimatePageTransitions: readerAnimatePageTransitions,
            readerUpscaleImages: readerUpscaleImages,
            readerUpscaleMaxHeight: readerUpscaleMaxHeight,
            readerUpscaleModelName: readerUpscaleModelName,
            readerPagesToPreload: readerPagesToPreload,
            readerPagedPageLayout: readerPagedPageLayout,
            readerPagedPageOffset: readerPagedPageOffset,
            readerPagedPageOffsetOverrides: readerPagedPageOffsetOverrides,
            readerSplitWideImages: readerSplitWideImages,
            readerReverseSplitOrder: readerReverseSplitOrder,
            readerVerticalInfiniteScroll: readerVerticalInfiniteScroll,
            readerPillarbox: readerPillarbox,
            readerPillarboxAmount: readerPillarboxAmount,
            readerPillarboxOrientation: readerPillarboxOrientation,
            readerOrientationLockEnabled: readerOrientationLockEnabled,
            readerOrientationLockMask: readerOrientationLockMask,
            readerReadThresholdPercent: readerReadThresholdPercent,

            readerFontSize: readerFontSize,
            readerFontFamily: readerFontFamily,
            readerFontWeight: readerFontWeight,
            readerColorPreset: readerColorPreset,
            readerTextAlignment: readerTextAlignment,
            readerLineSpacing: readerLineSpacing,
            readerMargin: readerMargin,

            autoClearCacheEnabled: autoClearCacheEnabled,
            autoClearCacheThresholdMB: autoClearCacheThresholdMB,
            highQualityThreshold: highQualityThreshold,
            backgroundHLSPipelineEnabled: backgroundHLSPipelineEnabled,
            readerDownloadsBackgroundEnabled: readerDownloadsBackgroundEnabled,
            readerDownloadsWifiOnly: readerDownloadsWifiOnly,
            readerDownloadsParallelLimit: readerDownloadsParallelLimit,
            autoUpdateServicesEnabled: autoUpdateServicesEnabled,
            servicesAutoModeEnabled: servicesAutoModeEnabled,
            servicesAutoSelectEpisodesEnabled: servicesAutoSelectEpisodesEnabled,
            servicesAutoModeSourceIds: servicesAutoModeSourceIds,
            servicesAutoModeSourceOrderIds: servicesAutoModeSourceOrderIds,
            servicesAutoModeQualityPreference: servicesAutoModeQualityPreference,
            servicesResultMinimumSimilarity: servicesResultMinimumSimilarity,
            servicesDropMismatchedResults: servicesDropMismatchedResults,
            servicesStremioStyleSheetEnabled: servicesStremioStyleSheetEnabled,
            servicesIncludedStreamLanguages: servicesIncludedStreamLanguages,
            servicesHiddenStreamLanguages: servicesHiddenStreamLanguages,
            servicesHideStreamsWithoutLanguageData: servicesHideStreamsWithoutLanguageData,
            servicesAssumeOriginalAudio: servicesAssumeOriginalAudio,
            servicesTreatDubbedAnimeAsEnglish: servicesTreatDubbedAnimeAsEnglish,
            servicesHiddenStreamQualities: servicesHiddenStreamQualities,
            servicesHideStreamsWithoutDetectedQuality: servicesHideStreamsWithoutDetectedQuality,
            servicesExtraRulesSourceIds: servicesExtraRulesSourceIds,
            githubReleaseAutoCheckEnabled: githubReleaseAutoCheckEnabled,
            githubReleaseUpdateAvailable: githubReleaseUpdateAvailable,
            githubReleaseLatestVersion: githubReleaseLatestVersion,
            githubReleaseURL: githubReleaseURL,
            githubReleaseShowAlertPending: githubReleaseShowAlertPending,
            githubReleaseLastPromptedVersion: githubReleaseLastPromptedVersion,
            filterHorrorContent: filterHorrorContent,
            selectedSimilarityAlgorithm: selectedSimilarityAlgorithm,
            performanceModeEnabled: performanceModeEnabled,
            performanceModeSkipAniListTraversalForAnimeDetails: performanceModeSkipAniListTraversalForAnimeDetails,
            performanceModeFastAnimeCatalogOverrides: performanceModeFastAnimeCatalogOverrides,
            kanzenHomeSelectedSourceID: kanzenHomeSelectedSourceID,
            kanzenRecentSourceSearches: kanzenRecentSourceSearches,

            collections: backupCollections,
            progressData: progressData,
            trackerState: trackerState,
            catalogs: catalogs,
            services: services,
            stremioAddons: stremioAddons,
            mangaCollections: mangaCollections,
            mangaReadingProgress: mangaReadingProgress,
            mangaCatalogs: mangaCatalogs,
            kanzenModules: kanzenModules,
            aidokuState: aidokuState,
            searchHistory: searchHistory,
            recommendationCache: RecommendationEngine.shared.getRecommendationCache(),
            userRatings: UserRatingManager.shared.getRatingsForBackup(),
            userRatingNotes: UserRatingManager.shared.getNotesForBackup(),
            mediaStateSettings: BackupData.captureMediaStateSettings(from: userDefaults)
        )
        
        return backup
    }
    
    // MARK: - Import Backup
    
    /// Restores data from a backup file
    func restoreBackup(from url: URL) -> Bool {
        do {
            let jsonData = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            // Try to decode the backup data
            // If it fails completely, try manual parsing to extract what we can
            let backupData: BackupData
            
            do {
                backupData = try decoder.decode(BackupData.self, from: jsonData)
                Logger.shared.log("Backup decoded successfully", type: "Info")
            } catch {
                Logger.shared.log("Standard decode failed, attempting lenient restore: \(error.localizedDescription)", type: "Info")
                
                // Try to parse as much as we can manually
                guard let backupData = tryLenientDecode(from: jsonData) else {
                    Logger.shared.log("Lenient decode also failed", type: "Error")
                    return false
                }
                
                Logger.shared.log("Lenient decode succeeded with partial data", type: "Info")
                return applyBackupData(backupData)
            }
            
            return applyBackupData(backupData)
        } catch {
            Logger.shared.log("Failed to restore backup: \(error.localizedDescription)", type: "Error")
            return false
        }
    }
    
    /// Attempts to decode backup data leniently, accepting whatever fields are valid
    private func tryLenientDecode(from jsonData: Data) -> BackupData? {
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }
        
        // Parse createdDate - required field
        let createdDate: Date
        if let dateString = json["createdDate"] as? String {
            let formatter = ISO8601DateFormatter()
            createdDate = formatter.date(from: dateString) ?? Date()
        } else {
            createdDate = Date()
        }
        
        // Extract optional fields with defaults
        let version = json["version"] as? String ?? "1.0"
        let accentColor = BackupData.backupColorData(from: json["accentColor"])
        let settingsGradientColor = BackupData.backupColorData(from: json["settingsGradientColor"])
        let readerAccentColor = BackupData.backupColorData(from: json["readerAccentColor"])
        let readerSettingsGradientColor = BackupData.backupColorData(from: json["readerSettingsGradientColor"])
        let tmdbLanguage = json["tmdbLanguage"] as? String ?? "en-US"
        let selectedAppearance = BackupData.sanitizedAppearance(json["selectedAppearance"] as? String)
        let readerSelectedAppearance = BackupData.sanitizedAppearance(json["readerSelectedAppearance"] as? String ?? selectedAppearance)
        let readerGlobalAppearanceEnabled = json["readerGlobalAppearanceEnabled"] as? Bool ?? true
        let enableSubtitlesByDefault = json["enableSubtitlesByDefault"] as? Bool ?? false
        let defaultSubtitleLanguage = json["defaultSubtitleLanguage"] as? String ?? "eng"
        let playerSubtitleAppearanceEnabled = json["playerSubtitleAppearanceEnabled"] as? Bool
            ?? json["enableVLCSubtitleEditMenu"] as? Bool
            ?? true
        let preferredAutoAudioLanguage = json["preferredAutoAudioLanguage"] as? String ?? "eng"
        let preferredAnimeAudioLanguage = json["preferredAnimeAudioLanguage"] as? String ?? "jpn"
        let inAppPlayer = Settings.normalizedInAppPlayer(json["inAppPlayer"] as? String ?? json["playerChoice"] as? String)
        let showScheduleTab = json["showScheduleTab"] as? Bool ?? true
        let showLocalScheduleTime = json["showLocalScheduleTime"] as? Bool ?? true
        let defaultScheduleMode = ScheduleMode.sanitizedRawValue(json["defaultScheduleMode"] as? String)
        let scheduleWindowDays = ScheduleWindow.sanitizedDays(json["scheduleWindowDays"] as? Int)
        let localNotificationSubscriptions = json["localNotificationSubscriptions"] as? String
        let localNotificationEpisodeReminders = json["localNotificationEpisodeReminders"] as? String
        let localNotificationEpisodeLeadTime = json["localNotificationEpisodeLeadTime"] as? Int
        let localNotificationSeasonLeadTime = json["localNotificationSeasonLeadTime"] as? Int
        let localNotificationIncludeAnimeSpecials = json["localNotificationIncludeAnimeSpecials"] as? Bool

        // Player settings
        let defaultPlaybackSpeed = json["defaultPlaybackSpeed"] as? Double ?? 1.0
        let holdSpeedPlayer = json["holdSpeedPlayer"] as? Double ?? 2.0
        let externalPlayer = json["externalPlayer"] as? String ?? "none"
        let preferDownloadedMedia = json["preferDownloadedMedia"] as? Bool ?? false
        let alwaysLandscape = json["alwaysLandscape"] as? Bool ?? false
        let playerPlaybackLockEnabled = json["playerPlaybackLockEnabled"] as? Bool ?? PlayerPlaybackLockSettings.defaultEnabled
        let aniSkipEnabled = json["aniSkipEnabled"] as? Bool ?? true
        let introDBEnabled = json["introDBEnabled"] as? Bool ?? true
        let introDBAppEnabled = json["introDBAppEnabled"] as? Bool ?? true
        let aniSkipAutoSkip = json["aniSkipAutoSkip"] as? Bool ?? false
        let skip85sEnabled = json["skip85sEnabled"] as? Bool ?? false
        let skip85sAlwaysVisible = json["skip85sAlwaysVisible"] as? Bool ?? false
        let showNextEpisodeButton = json["showNextEpisodeButton"] as? Bool ?? true
        let showEpisodeBrowserButton = json["showEpisodeBrowserButton"] as? Bool ?? json["showVLCEpisodeBrowserButton"] as? Bool ?? true
        let showPlayerServicesButton = json["showPlayerServicesButton"] as? Bool ?? false
        let showNextEpisodePosterButton = json["showNextEpisodePosterButton"] as? Bool ?? false
        let nextEpisodeThreshold = json["nextEpisodeThreshold"] as? Double ?? 0.90
        let nextEpisodeSkipFillerEnabled = json["nextEpisodeSkipFillerEnabled"] as? Bool ?? NextEpisodeFillerSettings.defaultEnabled
        let playerBrightnessGestureEnabled = json["playerBrightnessGestureEnabled"] as? Bool ?? json["vlcBrightnessGestureEnabled"] as? Bool ?? false
        let playerVolumeGestureEnabled = json["playerVolumeGestureEnabled"] as? Bool ?? json["vlcVolumeGestureEnabled"] as? Bool ?? false
        let playerTwoFingerTapPlayPauseEnabled = json["playerTwoFingerTapPlayPauseEnabled"] as? Bool ?? true
        let playerCenterTapPlayPauseEnabled = json["playerCenterTapPlayPauseEnabled"] as? Bool ?? true
        let playerDoubleTapSeekEnabled = json["playerDoubleTapSeekEnabled"] as? Bool ?? json["vlcDoubleTapSeekEnabled"] as? Bool ?? true
        let playerDoubleTapSeekSeconds = json["playerDoubleTapSeekSeconds"] as? Double ?? json["vlcDoubleTapSeekSeconds"] as? Double ?? 10.0
        let playerOpenSubtitlesEnabled = json["playerOpenSubtitlesEnabled"] as? Bool ?? json["vlcOpenSubtitlesEnabled"] as? Bool ?? false
        let playerOpenSubtitlesAutoFallbackEnabled = json["playerOpenSubtitlesAutoFallbackEnabled"] as? Bool ?? json["vlcOpenSubtitlesAutoFallbackEnabled"] as? Bool ?? true
        let playerPerformanceOverlayEnabled = json["playerPerformanceOverlayEnabled"] as? Bool ?? false
        let mpvForegroundFPSRaw = json["mpvForegroundFPS"] as? Int ?? (json["mpvForegroundFPS"] as? Double).map(Int.init) ?? 30
        let mpvForegroundFPS = mpvForegroundFPSRaw == 60 ? 60 : 30
        let mpvRenderBackend = BackupData.sanitizedMPVRenderBackend(json["mpvRenderBackend"] as? String)
        let mpvMetalQualityProfile = BackupData.sanitizedMPVMetalQualityProfile(json["mpvMetalQualityProfile"] as? String)
        let mpvUpscalingMode = BackupData.sanitizedMPVUpscalingMode(json["mpvUpscalingMode"] as? String)
        let mpvPlayerSkin = BackupData.sanitizedMPVPlayerSkin(json["mpvPlayerSkin"] as? String)
        let mpvPlayerSkinCustomPrimaryColor = BackupData.backupColorData(from: json["mpvPlayerSkinCustomPrimaryColor"])
        let mpvPlayerSkinCustomSecondaryColor = BackupData.backupColorData(from: json["mpvPlayerSkinCustomSecondaryColor"])
        let mpvPlayerSkinAnimationsEnabled = json["mpvPlayerSkinAnimationsEnabled"] as? Bool ?? MPVPlayerSkinSettings.defaultAnimationsEnabled
        let mpvPlayerSkinTintControlsOnly = json["mpvPlayerSkinTintControlsOnly"] as? Bool ?? MPVPlayerSkinSettings.defaultTintControlsOnly
        let mpvPictureInPictureEnabled = json["mpvPictureInPictureEnabled"] as? Bool ?? true
        let mpvAppExitPictureInPictureEnabled = json["mpvAppExitPictureInPictureEnabled"] as? Bool ?? false
        let mpvHDRMode = MPVHDRMode(rawValue: json["mpvHDRMode"] as? String ?? MPVHDRMode.defaultMode.rawValue)?.rawValue ?? MPVHDRMode.defaultMode.rawValue
        let mpvSurroundSoundEnabled = json["mpvSurroundSoundEnabled"] as? Bool ?? true
        let watchTogetherEnabled = json["watchTogetherEnabled"] as? Bool ?? WatchTogetherSettings.defaultEnabled
        let smartInAppPlayerChoosingEnabled = false
        let experimentalFeaturesEnabled = json["experimentalFeaturesEnabled"] as? Bool ?? false
        let experimentalFeaturesLastChangedAt = json["experimentalFeaturesLastChangedAt"] as? Double ?? 0
        let experimentalMPVPreloadEnabled = json["experimentalMPVPreloadEnabled"] as? Bool ?? true
        let experimentalMPVSmoothTransitionEnabled = json["experimentalMPVSmoothTransitionEnabled"] as? Bool ?? true
        let experimentalMPVPreloadCellularEnabled = json["experimentalMPVPreloadCellularEnabled"] as? Bool ?? false
        let experimentalMPVPreloadWifiLimitMB = ExperimentalFeatureState.resolvedMPVPreloadWifiLimitMB(BackupData.optionalInt(from: json["experimentalMPVPreloadWifiLimitMB"], defaultValue: ExperimentalFeatureState.mpvPreloadWifiDefaultLimitMB))
        let experimentalMPVPreloadCellularLimitMB = ExperimentalFeatureState.resolvedMPVPreloadCellularLimitMB(BackupData.optionalInt(from: json["experimentalMPVPreloadCellularLimitMB"], defaultValue: ExperimentalFeatureState.mpvPreloadCellularDefaultLimitMB))
        let experimentalMPVShowRemainingTime = json["experimentalMPVShowRemainingTime"] as? Bool ?? true
        let experimentalMPVPreciseProgress = json["experimentalMPVPreciseProgress"] as? Bool ?? true
        let experimentalMPVIgnoreSpecialSubtitleStyles = json["experimentalMPVIgnoreSpecialSubtitleStyles"] as? Bool ?? false
        let experimentalMPVPreloadAutoClear = json["experimentalMPVPreloadAutoClear"] as? Bool ?? true
        let experimentalICloudSyncEnabled = json["experimentalICloudSyncEnabled"] as? Bool ?? false

        // Subtitle styling
        let subtitleForegroundColor = BackupData.backupColorData(from: json["subtitleForegroundColor"])
        let subtitleStrokeColor = BackupData.backupColorData(from: json["subtitleStrokeColor"])
        let subtitleStrokeWidth = json["subtitleStrokeWidth"] as? Double ?? 1.0
        let subtitleFontSize = json["subtitleFontSize"] as? Double ?? 30.0
        let subtitleVerticalOffset = json["subtitleVerticalOffset"] as? Double ?? -6.0
        let subtitlesVisible = json["subtitlesVisible"] as? Bool ?? false

        // UI preferences
        let showKanzen = json["showKanzen"] as? Bool ?? false
        let hideSplashScreen = json["hideSplashScreen"] as? Bool
        let modeSwitchAnimationEnabled = json["modeSwitchAnimationEnabled"] as? Bool ?? ModeSwitchAnimationSettings.defaultEnabled
        let kanzenAutoUpdateModules = json["kanzenAutoUpdateModules"] as? Bool ?? true
        let seasonMenu = json["seasonMenu"] as? Bool ?? false
        let horizontalEpisodeList = json["horizontalEpisodeList"] as? Bool ?? false
        let mediaDetailTitleArtworkEnabled = json["mediaDetailTitleArtworkEnabled"] as? Bool ?? MediaDetailTitleArtworkSettings.defaultEnabled
        let mediaDetailSimilarTitlesEnabled = json["mediaDetailSimilarTitlesEnabled"] as? Bool ?? MediaDetailSimilarTitlesSettings.defaultEnabled
        let useClassicScheduleUI = json["useClassicScheduleUI"] as? Bool ?? false
        let heroBannerCatalogId = BackupData.sanitizedNonEmptyString(json["heroBannerCatalogId"] as? String, defaultValue: "trending")
        let heroBannerBehavior = BackupData.sanitizedHeroBannerBehavior(json["heroBannerBehavior"] as? String)
        let homeCatalogLayoutOverrides = json["homeCatalogLayoutOverrides"] as? String ?? ""
        let homeAnimatedBackgroundEnabled = json["homeAnimatedBackgroundEnabled"] as? Bool
        let homeAnimatedBackgroundQuality = BackupData.sanitizedHomeAnimatedBackgroundQuality(json["homeAnimatedBackgroundQuality"] as? String)
        let homeAnimatedBackgroundFrameRate = BackupData.sanitizedHomeAnimatedBackgroundFrameRate(json["homeAnimatedBackgroundFrameRate"] as? String)
        let appPerformanceOverlayEnabled = json["appPerformanceOverlayEnabled"] as? Bool ?? AppPerformanceOverlaySettings.defaultEnabled
        let experimentalMediaDesignPreset = BackupData.sanitizedExperimentalMediaDesignPreset(json["experimentalMediaDesignPreset"] as? String)
        let experimentalHeroBleedLevel = BackupData.sanitizedExperimentalHeroBleedLevel(json["experimentalHeroBleedLevel"] as? String)
        let experimentalHomeCardShape = BackupData.sanitizedExperimentalHomeCardShape(json["experimentalHomeCardShape"] as? String)
        let experimentalMultiGradientPalette = BackupData.sanitizedExperimentalMultiGradientPalette(json["experimentalMultiGradientPalette"] as? String)
        let experimentalHeroHeightScale = BackupData.sanitizedExperimentalHeroHeightScale(BackupData.optionalDouble(from: json["experimentalHeroHeightScale"], defaultValue: ExperimentalVisualTuning.defaultHeroHeightScale))
        let experimentalHeroBleedStrength = BackupData.sanitizedExperimentalHeroBleedStrength(BackupData.optionalDouble(from: json["experimentalHeroBleedStrength"], defaultValue: ExperimentalVisualTuning.defaultHeroBleedStrength))
        let experimentalHeroFadeDistanceScale = BackupData.sanitizedExperimentalHeroFadeDistanceScale(BackupData.optionalDouble(from: json["experimentalHeroFadeDistanceScale"], defaultValue: ExperimentalVisualTuning.defaultHeroFadeDistanceScale))
        let experimentalSectionSpacingScale = BackupData.sanitizedExperimentalSectionSpacingScale(BackupData.optionalDouble(from: json["experimentalSectionSpacingScale"], defaultValue: ExperimentalVisualTuning.defaultSectionSpacingScale))
        let experimentalCardRadiusScale = BackupData.sanitizedExperimentalCardRadiusScale(BackupData.optionalDouble(from: json["experimentalCardRadiusScale"], defaultValue: ExperimentalVisualTuning.defaultCardRadiusScale))
        let experimentalMediaCardScale = BackupData.sanitizedExperimentalMediaCardScale(BackupData.optionalDouble(from: json["experimentalMediaCardScale"], defaultValue: ExperimentalVisualTuning.defaultMediaCardScale))
        let experimentalGlassStrength = BackupData.sanitizedExperimentalGlassStrength(BackupData.optionalDouble(from: json["experimentalGlassStrength"], defaultValue: ExperimentalVisualTuning.defaultGlassStrength))
        let experimentalGradientBaseDarkness = BackupData.sanitizedExperimentalGradientBaseDarkness(BackupData.optionalDouble(from: json["experimentalGradientBaseDarkness"], defaultValue: ExperimentalVisualTuning.defaultGradientBaseDarkness))
        let experimentalGradientAccentIntensity = BackupData.sanitizedExperimentalGradientAccentIntensity(BackupData.optionalDouble(from: json["experimentalGradientAccentIntensity"], defaultValue: ExperimentalVisualTuning.defaultGradientAccentIntensity))
        let experimentalGradientScrollMotion = BackupData.sanitizedExperimentalGradientScrollMotion(BackupData.optionalDouble(from: json["experimentalGradientScrollMotion"], defaultValue: ExperimentalVisualTuning.defaultGradientScrollMotion))
        let experimentalGradientUseCustomColors = json["experimentalGradientUseCustomColors"] as? Bool ?? false
        let experimentalGradientColorA = BackupData.backupColorData(from: json["experimentalGradientColorA"])
        let experimentalGradientColorB = BackupData.backupColorData(from: json["experimentalGradientColorB"])
        let experimentalGradientColorC = BackupData.backupColorData(from: json["experimentalGradientColorC"])
        let atmosphereStyle = BackupData.sanitizedAtmosphereStyle(json["atmosphereStyle"] as? String)
        let atmosphereSolidColorSource = BackupData.sanitizedAtmosphereSolidColorSource(json["atmosphereSolidColorSource"] as? String)
        let atmosphereSolidColor = BackupData.backupColorData(from: json["atmosphereSolidColor"])
        let readerAtmosphereStyle = BackupData.sanitizedAtmosphereStyle(json["readerAtmosphereStyle"] as? String ?? atmosphereStyle)
        let readerAtmosphereSolidColorSource = BackupData.sanitizedAtmosphereSolidColorSource(json["readerAtmosphereSolidColorSource"] as? String ?? atmosphereSolidColorSource)
        let readerAtmosphereSolidColor = BackupData.backupColorData(from: json["readerAtmosphereSolidColor"])
        let mediaDetailElementOrder = BackupData.sanitizedMediaDetailElementOrder(json["mediaDetailElementOrder"] as? String)
        let mediaDetailHiddenElements = BackupData.sanitizedMediaDetailHiddenElements(json["mediaDetailHiddenElements"] as? String)
        let readerDetailElementOrder = BackupData.sanitizedReaderDetailElementOrder(json["readerDetailElementOrder"] as? String)
        let readerDetailHiddenElements = BackupData.sanitizedReaderDetailHiddenElements(json["readerDetailHiddenElements"] as? String)
        let mediaColumnsPortrait = json["mediaColumnsPortrait"] as? Int ?? 3
        let mediaColumnsLandscape = json["mediaColumnsLandscape"] as? Int ?? 5

        // Manga / Reader
        let readingMode = BackupData.optionalInt(from: json["readingMode"], defaultValue: 2)
        let kanzenReaderMode = (json["kanzenReaderMode"] as? String).map(BackupData.sanitizedKanzenReaderMode)
            ?? BackupData.kanzenReaderModeRawValue(forReadingMode: readingMode)
        let kanzenReaderModeOverrides = BackupData.sanitizedKanzenReaderModeOverrides(json["kanzenReaderModeOverrides"] as? [String: String])
        let readerDownsampleImages = json["readerDownsampleImages"] as? Bool ?? true
        let readerCropBorders = json["readerCropBorders"] as? Bool ?? false
        let readerDisableQuickActions = json["readerDisableQuickActions"] as? Bool ?? false
        let readerDisableDoubleTap = json["readerDisableDoubleTap"] as? Bool ?? false
        let readerLiveText = json["readerLiveText"] as? Bool ?? false
        let readerHideBarsOnSwipe = json["readerHideBarsOnSwipe"] as? Bool ?? false
        let readerBackgroundColor = BackupData.sanitizedReaderBackgroundColor(json["readerBackgroundColor"] as? String)
        let readerOrientation = BackupData.sanitizedReaderOrientation(json["readerOrientation"] as? String)
        let readerTapZones = BackupData.sanitizedReaderTapZones(json["readerTapZones"] as? String)
        let readerInvertTapZones = json["readerInvertTapZones"] as? Bool ?? false
        let readerAnimatePageTransitions = json["readerAnimatePageTransitions"] as? Bool ?? true
        let readerUpscaleImages = json["readerUpscaleImages"] as? Bool ?? false
        let readerUpscaleMaxHeight = BackupData.sanitizedReaderUpscaleMaxHeight(BackupData.optionalInt(from: json["readerUpscaleMaxHeight"], defaultValue: 2000))
        let readerUpscaleModelName = json["readerUpscaleModelName"] as? String ?? "None"
        let readerPagesToPreload = BackupData.sanitizedReaderPagesToPreload(BackupData.optionalInt(from: json["readerPagesToPreload"], defaultValue: 3))
        let readerPagedPageLayout = BackupData.sanitizedReaderPagedPageLayout(json["readerPagedPageLayout"] as? String)
        let readerPagedPageOffset = json["readerPagedPageOffset"] as? Bool ?? false
        let readerPagedPageOffsetOverrides = BackupData.sanitizedReaderPagedPageOffsetOverrides(json["readerPagedPageOffsetOverrides"] as? [String: Bool])
        let readerSplitWideImages = json["readerSplitWideImages"] as? Bool ?? false
        let readerReverseSplitOrder = json["readerReverseSplitOrder"] as? Bool ?? false
        let readerVerticalInfiniteScroll = json["readerVerticalInfiniteScroll"] as? Bool ?? true
        let readerPillarbox = json["readerPillarbox"] as? Bool ?? false
        let readerPillarboxAmount = BackupData.sanitizedReaderPillarboxAmount(BackupData.optionalDouble(from: json["readerPillarboxAmount"], defaultValue: 15))
        let readerPillarboxOrientation = BackupData.sanitizedReaderPillarboxOrientation(json["readerPillarboxOrientation"] as? String)
        let readerOrientationLockEnabled = json["readerOrientationLockEnabled"] as? Bool ?? false
        let readerOrientationLockMask = BackupData.sanitizedReaderOrientationLockMask(json["readerOrientationLockMask"] as? String)
        let readerReadThresholdPercent = BackupData.sanitizedReaderReadThresholdPercent(json["readerReadThresholdPercent"] as? Double)

        // Novel Reader
        let readerFontSize = json["readerFontSize"] as? Double ?? 16
        let readerFontFamily = json["readerFontFamily"] as? String ?? "-apple-system"
        let readerFontWeight = json["readerFontWeight"] as? String ?? "normal"
        let readerColorPreset = json["readerColorPreset"] as? Int ?? 0
        let readerTextAlignment = json["readerTextAlignment"] as? String ?? "left"
        let readerLineSpacing = json["readerLineSpacing"] as? Double ?? 1.6
        let readerMargin = json["readerMargin"] as? Double ?? 4

        // Other
        let autoClearCacheEnabled = json["autoClearCacheEnabled"] as? Bool ?? false
        let autoClearCacheThresholdMB = json["autoClearCacheThresholdMB"] as? Double ?? 500
        let highQualityThreshold = json["highQualityThreshold"] as? Double ?? 0.9
        let backgroundHLSPipelineEnabled = json["backgroundHLSPipelineEnabled"] as? Bool ?? false
        let readerDownloadsBackgroundEnabled = json["readerDownloadsBackgroundEnabled"] as? Bool ?? true
        let readerDownloadsWifiOnly = json["readerDownloadsWifiOnly"] as? Bool ?? false
        let readerDownloadsParallelLimit = BackupData.sanitizedReaderDownloadsParallelLimit(BackupData.optionalInt(from: json["readerDownloadsParallelLimit"], defaultValue: 2))
        let autoUpdateServicesEnabled = json["autoUpdateServicesEnabled"] as? Bool ?? true
        let servicesAutoModeEnabled = json["servicesAutoModeEnabled"] as? Bool ?? false
        let servicesAutoSelectEpisodesEnabled = json["servicesAutoSelectEpisodesEnabled"] as? Bool ?? false
        let servicesAutoModeSourceIds = BackupData.sanitizedStringList(BackupData.stringList(from: json["servicesAutoModeSourceIds"]))
        let servicesAutoModeSourceOrderIds = BackupData.sanitizedStringList(BackupData.stringList(from: json["servicesAutoModeSourceOrderIds"]))
        let servicesAutoModeQualityPreference = AutoModeQualityPreference.sanitizedRawValue(json["servicesAutoModeQualityPreference"] as? String)
        let servicesResultMinimumSimilarity = BackupData.sanitizedServicesResultMinimumSimilarity(
            BackupData.optionalDouble(from: json["servicesResultMinimumSimilarity"], defaultValue: ServicesResultRankingSettings.defaultMinimumSimilarity)
        )
        let servicesDropMismatchedResults = json["servicesDropMismatchedResults"] as? Bool ?? ServicesResultRankingSettings.defaultDropMismatchedResults
        let servicesStremioStyleSheetEnabled = json["servicesStremioStyleSheetEnabled"] as? Bool ?? ServicesSheetPresentationSettings.defaultStremioStyleEnabled
        let servicesIncludedStreamLanguages = StreamLanguageFilter.sanitizedLanguageList(BackupData.stringList(from: json["servicesIncludedStreamLanguages"]))
        let servicesHiddenStreamLanguages = StreamLanguageFilter.sanitizedLanguageList(BackupData.stringList(from: json["servicesHiddenStreamLanguages"]))
        let servicesHideStreamsWithoutLanguageData = json["servicesHideStreamsWithoutLanguageData"] as? Bool ?? false
        let servicesAssumeOriginalAudio = json["servicesAssumeOriginalAudio"] as? Bool ?? false
        let servicesTreatDubbedAnimeAsEnglish = json["servicesTreatDubbedAnimeAsEnglish"] as? Bool ?? false
        let servicesHiddenStreamQualities = StreamLanguageFilter.sanitizedQualityHeights(BackupData.intList(from: json["servicesHiddenStreamQualities"]))
        let servicesHideStreamsWithoutDetectedQuality = json["servicesHideStreamsWithoutDetectedQuality"] as? Bool ?? false
        let servicesExtraRulesSourceIds: [String]?
        if let rawSourceIds = json["servicesExtraRulesSourceIds"] as? [String] {
            servicesExtraRulesSourceIds = StreamLanguageFilter.sanitizedExtraRulesSourceIds(rawSourceIds)
        } else {
            servicesExtraRulesSourceIds = nil
        }
        let githubReleaseAutoCheckEnabled = json["githubReleaseAutoCheckEnabled"] as? Bool ?? true
        let githubReleaseUpdateAvailable = json["githubReleaseUpdateAvailable"] as? Bool ?? false
        let githubReleaseLatestVersion = json["githubReleaseLatestVersion"] as? String ?? ""
        let githubReleaseURL = json["githubReleaseURL"] as? String ?? ""
        let githubReleaseShowAlertPending = json["githubReleaseShowAlertPending"] as? Bool ?? false
        let githubReleaseLastPromptedVersion = json["githubReleaseLastPromptedVersion"] as? String ?? ""
        let filterHorrorContent = json["filterHorror"] as? Bool ?? false
        let selectedSimilarityAlgorithm = BackupData.sanitizedSimilarityAlgorithm(json["selectedSimilarityAlgorithm"] as? String)
        let performanceModeEnabled = json["performanceModeEnabled"] as? Bool ?? PerformanceModeSettings.defaultEnabled
        let performanceModeSkipAniListTraversalForAnimeDetails = json["performanceModeSkipAniListTraversalForAnimeDetails"] as? Bool ?? false
        let rawPerformanceModeOverrides = json["performanceModeFastAnimeCatalogOverrides"] as? [String: Bool] ?? [:]
        let performanceModeFastAnimeCatalogOverrides = rawPerformanceModeOverrides.filter { PerformanceModeSettings.animeCatalogIds.contains($0.key) }
        let kanzenHomeSelectedSourceID = json["kanzenHomeSelectedSourceID"] as? String ?? ""
        let kanzenRecentSourceSearches = BackupData.stringList(from: json["kanzenRecentSourceSearches"])
        
        // Try to decode complex objects individually
        var collections: [BackupCollection] = []
        if let collectionsData = json["collections"] as? [[String: Any]] {
            Logger.shared.log("Found \(collectionsData.count) collections in backup", type: "Info")
            for (index, collectionDict) in collectionsData.enumerated() {
                do {
                    let collectionJSON = try JSONSerialization.data(withJSONObject: collectionDict)
                    let collectionDecoder = JSONDecoder()
                    collectionDecoder.dateDecodingStrategy = .iso8601
                    let collection = try collectionDecoder.decode(BackupCollection.self, from: collectionJSON)
                    collections.append(collection)
                    Logger.shared.log("Successfully decoded collection \(index + 1): \(collection.name) with \(collection.items.count) items", type: "Info")
                } catch {
                    Logger.shared.log("Failed to decode collection \(index + 1): \(error.localizedDescription)", type: "Error")
                    // Try to extract at least the name for debugging
                    if let name = collectionDict["name"] as? String {
                        Logger.shared.log("  Collection name was: \(name)", type: "Error")
                    }
                }
            }
            Logger.shared.log("Successfully decoded \(collections.count) out of \(collectionsData.count) collections", type: "Info")
        } else {
            Logger.shared.log("No collections array found in backup", type: "Info")
        }
        
        var progressData = ProgressData()
        if let progressDict = json["progressData"] as? [String: Any],
           let progressJSON = try? JSONSerialization.data(withJSONObject: progressDict),
           let decoded = try? JSONDecoder().decode(ProgressData.self, from: progressJSON) {
            progressData = decoded
        }
        
        var trackerState = TrackerState()
        if let trackerDict = json["trackerState"] as? [String: Any],
           let trackerJSON = try? JSONSerialization.data(withJSONObject: trackerDict),
           let decoded = try? JSONDecoder().decode(TrackerState.self, from: trackerJSON) {
            trackerState = decoded
        }
        
        var catalogs: [Catalog] = []
        if let catalogsData = json["catalogs"] as? [[String: Any]] {
            for catalogDict in catalogsData {
                if let catalogJSON = try? JSONSerialization.data(withJSONObject: catalogDict),
                   let catalog = try? JSONDecoder().decode(Catalog.self, from: catalogJSON) {
                    catalogs.append(catalog)
                }
            }
        }
        
        var services: [BackupService] = []
        if let servicesData = json["services"] as? [[String: Any]] {
            for serviceDict in servicesData {
                if let serviceJSON = try? JSONSerialization.data(withJSONObject: serviceDict),
                   let service = try? JSONDecoder().decode(BackupService.self, from: serviceJSON) {
                    services.append(service)
                }
            }
        }

        var stremioAddons: [BackupStremioAddon]? = nil
        if let stremioData = json["stremioAddons"] as? [[String: Any]] {
            var decodedAddons: [BackupStremioAddon] = []
            for addonDict in stremioData {
                if let addonJSON = try? JSONSerialization.data(withJSONObject: addonDict),
                   let addon = try? JSONDecoder().decode(BackupStremioAddon.self, from: addonJSON) {
                    decodedAddons.append(addon)
                }
            }
            stremioAddons = decodedAddons
        }

        // Manga data
        var mangaCollections: [BackupMangaCollection] = []
        if let mangaColData = json["mangaCollections"] as? [[String: Any]] {
            for dict in mangaColData {
                if let data = try? JSONSerialization.data(withJSONObject: dict) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let col = try? decoder.decode(BackupMangaCollection.self, from: data) {
                        mangaCollections.append(col)
                    }
                }
            }
        }

        var mangaReadingProgress: [String: MangaProgress] = [:]
        if let progressDict = json["mangaReadingProgress"] as? [String: Any],
           let progressJSON = try? JSONSerialization.data(withJSONObject: progressDict),
           let decoded = try? JSONDecoder().decode([String: MangaProgress].self, from: progressJSON) {
            mangaReadingProgress = decoded
        }

        var mangaCatalogs: [MangaCatalog] = []
        if let catalogsData = json["mangaCatalogs"] as? [[String: Any]] {
            for dict in catalogsData {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let cat = try? JSONDecoder().decode(MangaCatalog.self, from: data) {
                    mangaCatalogs.append(cat)
                }
            }
        }

        var kanzenModules: [BackupKanzenModule] = []
        if let modulesData = json["kanzenModules"] as? [[String: Any]] {
            for dict in modulesData {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let mod = try? JSONDecoder().decode(BackupKanzenModule.self, from: data) {
                    kanzenModules.append(mod)
                }
            }
        }

        var aidokuState: BackupAidokuState?
        if let aidokuDict = json["aidokuState"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: aidokuDict),
           let decoded = try? JSONDecoder().decode(BackupAidokuState.self, from: data) {
            aidokuState = decoded
        }

        let searchHistory = BackupSearchHistory(jsonValue: json["searchHistory"])

        var recommendationCache: [TMDBSearchResult] = []
        if let recsData = json["recommendationCache"] as? [[String: Any]] {
            for dict in recsData {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let rec = try? JSONDecoder().decode(TMDBSearchResult.self, from: data) {
                    recommendationCache.append(rec)
                }
            }
        }

        var userRatings: [String: Double] = [:]
        if let ratingsDict = json["userRatings"] as? [String: Any] {
            userRatings = Self.parseUserRatings(ratingsDict)
        }

        var userRatingNotes: [String: String] = [:]
        if let notesDict = json["userRatingNotes"] as? [String: String] {
            userRatingNotes = notesDict
        }

        let mediaStateSettings = BackupData.mediaStateSettings(fromJSONValue: json["mediaStateSettings"])
        let mangaCollectionsPresent = json["mangaCollections"] != nil
        let mangaReadingProgressPresent = json["mangaReadingProgress"] != nil
        let mangaCatalogsPresent = json["mangaCatalogs"] != nil
        let kanzenModulesPresent = json["kanzenModules"] != nil
        let userRatingsPresent = json["userRatings"] != nil || json["userRatingNotes"] != nil
        
        return BackupData(
            version: version,
            createdDate: createdDate,
            accentColor: accentColor,
            settingsGradientColor: settingsGradientColor,
            readerAccentColor: readerAccentColor,
            tmdbLanguage: tmdbLanguage,
            selectedAppearance: selectedAppearance,
            readerSelectedAppearance: readerSelectedAppearance,
            readerGlobalAppearanceEnabled: readerGlobalAppearanceEnabled,
            readerSettingsGradientColor: readerSettingsGradientColor,
            enableSubtitlesByDefault: enableSubtitlesByDefault,
            defaultSubtitleLanguage: defaultSubtitleLanguage,
            playerSubtitleAppearanceEnabled: playerSubtitleAppearanceEnabled,
            preferredAutoAudioLanguage: preferredAutoAudioLanguage,
            preferredAnimeAudioLanguage: preferredAnimeAudioLanguage,
            inAppPlayer: inAppPlayer,
            showScheduleTab: showScheduleTab,
            showLocalScheduleTime: showLocalScheduleTime,
            defaultScheduleMode: defaultScheduleMode,
            scheduleWindowDays: scheduleWindowDays,
            localNotificationSubscriptions: localNotificationSubscriptions,
            localNotificationEpisodeReminders: localNotificationEpisodeReminders,
            localNotificationEpisodeLeadTime: localNotificationEpisodeLeadTime,
            localNotificationSeasonLeadTime: localNotificationSeasonLeadTime,
            localNotificationIncludeAnimeSpecials: localNotificationIncludeAnimeSpecials,
            defaultPlaybackSpeed: defaultPlaybackSpeed,
            holdSpeedPlayer: holdSpeedPlayer,
            externalPlayer: externalPlayer,
            preferDownloadedMedia: preferDownloadedMedia,
            alwaysLandscape: alwaysLandscape,
            playerPlaybackLockEnabled: playerPlaybackLockEnabled,
            aniSkipEnabled: aniSkipEnabled,
            introDBEnabled: introDBEnabled,
            introDBAppEnabled: introDBAppEnabled,
            aniSkipAutoSkip: aniSkipAutoSkip,
            skip85sEnabled: skip85sEnabled,
            skip85sAlwaysVisible: skip85sAlwaysVisible,
            showNextEpisodeButton: showNextEpisodeButton,
            showEpisodeBrowserButton: showEpisodeBrowserButton,
            showPlayerServicesButton: showPlayerServicesButton,
            showNextEpisodePosterButton: showNextEpisodePosterButton,
            nextEpisodeThreshold: nextEpisodeThreshold,
            nextEpisodeSkipFillerEnabled: nextEpisodeSkipFillerEnabled,
            playerBrightnessGestureEnabled: playerBrightnessGestureEnabled,
            playerVolumeGestureEnabled: playerVolumeGestureEnabled,
            playerTwoFingerTapPlayPauseEnabled: playerTwoFingerTapPlayPauseEnabled,
            playerCenterTapPlayPauseEnabled: playerCenterTapPlayPauseEnabled,
            playerDoubleTapSeekEnabled: playerDoubleTapSeekEnabled,
            playerDoubleTapSeekSeconds: playerDoubleTapSeekSeconds,
            playerOpenSubtitlesEnabled: playerOpenSubtitlesEnabled,
            playerOpenSubtitlesAutoFallbackEnabled: playerOpenSubtitlesAutoFallbackEnabled,
            playerPerformanceOverlayEnabled: playerPerformanceOverlayEnabled,
            mpvForegroundFPS: mpvForegroundFPS,
            mpvRenderBackend: mpvRenderBackend,
            mpvMetalQualityProfile: mpvMetalQualityProfile,
            mpvUpscalingMode: mpvUpscalingMode,
            mpvPlayerSkin: mpvPlayerSkin,
            mpvPlayerSkinCustomPrimaryColor: mpvPlayerSkinCustomPrimaryColor,
            mpvPlayerSkinCustomSecondaryColor: mpvPlayerSkinCustomSecondaryColor,
            mpvPlayerSkinAnimationsEnabled: mpvPlayerSkinAnimationsEnabled,
            mpvPlayerSkinTintControlsOnly: mpvPlayerSkinTintControlsOnly,
            mpvPictureInPictureEnabled: mpvPictureInPictureEnabled,
            mpvAppExitPictureInPictureEnabled: mpvAppExitPictureInPictureEnabled,
            mpvHDRMode: mpvHDRMode,
            mpvSurroundSoundEnabled: mpvSurroundSoundEnabled,
            watchTogetherEnabled: watchTogetherEnabled,
            smartInAppPlayerChoosingEnabled: smartInAppPlayerChoosingEnabled,
            experimentalFeaturesEnabled: experimentalFeaturesEnabled,
            experimentalFeaturesLastChangedAt: experimentalFeaturesLastChangedAt,
            experimentalMPVPreloadEnabled: experimentalMPVPreloadEnabled,
            experimentalMPVSmoothTransitionEnabled: experimentalMPVSmoothTransitionEnabled,
            experimentalMPVPreloadCellularEnabled: experimentalMPVPreloadCellularEnabled,
            experimentalMPVPreloadWifiLimitMB: experimentalMPVPreloadWifiLimitMB,
            experimentalMPVPreloadCellularLimitMB: experimentalMPVPreloadCellularLimitMB,
            experimentalMPVShowRemainingTime: experimentalMPVShowRemainingTime,
            experimentalMPVPreciseProgress: experimentalMPVPreciseProgress,
            experimentalMPVIgnoreSpecialSubtitleStyles: experimentalMPVIgnoreSpecialSubtitleStyles,
            experimentalMPVPreloadAutoClear: experimentalMPVPreloadAutoClear,
            experimentalICloudSyncEnabled: experimentalICloudSyncEnabled,
            subtitleForegroundColor: subtitleForegroundColor,
            subtitleStrokeColor: subtitleStrokeColor,
            subtitleStrokeWidth: subtitleStrokeWidth,
            subtitleFontSize: subtitleFontSize,
            subtitleVerticalOffset: subtitleVerticalOffset,
            subtitlesVisible: subtitlesVisible,
            showKanzen: showKanzen,
            hideSplashScreen: hideSplashScreen,
            modeSwitchAnimationEnabled: modeSwitchAnimationEnabled,
            kanzenAutoUpdateModules: kanzenAutoUpdateModules,
            seasonMenu: seasonMenu,
            horizontalEpisodeList: horizontalEpisodeList,
            mediaDetailTitleArtworkEnabled: mediaDetailTitleArtworkEnabled,
            mediaDetailSimilarTitlesEnabled: mediaDetailSimilarTitlesEnabled,
            useClassicScheduleUI: useClassicScheduleUI,
            heroBannerCatalogId: heroBannerCatalogId,
            heroBannerBehavior: heroBannerBehavior,
            homeCatalogLayoutOverrides: homeCatalogLayoutOverrides,
            homeAnimatedBackgroundEnabled: homeAnimatedBackgroundEnabled,
            homeAnimatedBackgroundQuality: homeAnimatedBackgroundQuality,
            homeAnimatedBackgroundFrameRate: homeAnimatedBackgroundFrameRate,
            appPerformanceOverlayEnabled: appPerformanceOverlayEnabled,
            experimentalMediaDesignPreset: experimentalMediaDesignPreset,
            experimentalHeroBleedLevel: experimentalHeroBleedLevel,
            experimentalHomeCardShape: experimentalHomeCardShape,
            experimentalMultiGradientPalette: experimentalMultiGradientPalette,
            experimentalHeroHeightScale: experimentalHeroHeightScale,
            experimentalHeroBleedStrength: experimentalHeroBleedStrength,
            experimentalHeroFadeDistanceScale: experimentalHeroFadeDistanceScale,
            experimentalSectionSpacingScale: experimentalSectionSpacingScale,
            experimentalCardRadiusScale: experimentalCardRadiusScale,
            experimentalMediaCardScale: experimentalMediaCardScale,
            experimentalGlassStrength: experimentalGlassStrength,
            experimentalGradientBaseDarkness: experimentalGradientBaseDarkness,
            experimentalGradientAccentIntensity: experimentalGradientAccentIntensity,
            experimentalGradientScrollMotion: experimentalGradientScrollMotion,
            experimentalGradientUseCustomColors: experimentalGradientUseCustomColors,
            experimentalGradientColorA: experimentalGradientColorA,
            experimentalGradientColorB: experimentalGradientColorB,
            experimentalGradientColorC: experimentalGradientColorC,
            atmosphereStyle: atmosphereStyle,
            atmosphereSolidColorSource: atmosphereSolidColorSource,
            atmosphereSolidColor: atmosphereSolidColor,
            readerAtmosphereStyle: readerAtmosphereStyle,
            readerAtmosphereSolidColorSource: readerAtmosphereSolidColorSource,
            readerAtmosphereSolidColor: readerAtmosphereSolidColor,
            mediaDetailElementOrder: mediaDetailElementOrder,
            mediaDetailHiddenElements: mediaDetailHiddenElements,
            readerDetailElementOrder: readerDetailElementOrder,
            readerDetailHiddenElements: readerDetailHiddenElements,
            mediaColumnsPortrait: mediaColumnsPortrait,
            mediaColumnsLandscape: mediaColumnsLandscape,
            readingMode: readingMode,
            kanzenReaderMode: kanzenReaderMode,
            kanzenReaderModeOverrides: kanzenReaderModeOverrides,
            readerDownsampleImages: readerDownsampleImages,
            readerCropBorders: readerCropBorders,
            readerDisableQuickActions: readerDisableQuickActions,
            readerDisableDoubleTap: readerDisableDoubleTap,
            readerLiveText: readerLiveText,
            readerHideBarsOnSwipe: readerHideBarsOnSwipe,
            readerBackgroundColor: readerBackgroundColor,
            readerOrientation: readerOrientation,
            readerTapZones: readerTapZones,
            readerInvertTapZones: readerInvertTapZones,
            readerAnimatePageTransitions: readerAnimatePageTransitions,
            readerUpscaleImages: readerUpscaleImages,
            readerUpscaleMaxHeight: readerUpscaleMaxHeight,
            readerUpscaleModelName: readerUpscaleModelName,
            readerPagesToPreload: readerPagesToPreload,
            readerPagedPageLayout: readerPagedPageLayout,
            readerPagedPageOffset: readerPagedPageOffset,
            readerPagedPageOffsetOverrides: readerPagedPageOffsetOverrides,
            readerSplitWideImages: readerSplitWideImages,
            readerReverseSplitOrder: readerReverseSplitOrder,
            readerVerticalInfiniteScroll: readerVerticalInfiniteScroll,
            readerPillarbox: readerPillarbox,
            readerPillarboxAmount: readerPillarboxAmount,
            readerPillarboxOrientation: readerPillarboxOrientation,
            readerOrientationLockEnabled: readerOrientationLockEnabled,
            readerOrientationLockMask: readerOrientationLockMask,
            readerReadThresholdPercent: readerReadThresholdPercent,
            readerFontSize: readerFontSize,
            readerFontFamily: readerFontFamily,
            readerFontWeight: readerFontWeight,
            readerColorPreset: readerColorPreset,
            readerTextAlignment: readerTextAlignment,
            readerLineSpacing: readerLineSpacing,
            readerMargin: readerMargin,
            autoClearCacheEnabled: autoClearCacheEnabled,
            autoClearCacheThresholdMB: autoClearCacheThresholdMB,
            highQualityThreshold: highQualityThreshold,
            backgroundHLSPipelineEnabled: backgroundHLSPipelineEnabled,
            readerDownloadsBackgroundEnabled: readerDownloadsBackgroundEnabled,
            readerDownloadsWifiOnly: readerDownloadsWifiOnly,
            readerDownloadsParallelLimit: readerDownloadsParallelLimit,
            autoUpdateServicesEnabled: autoUpdateServicesEnabled,
            servicesAutoModeEnabled: servicesAutoModeEnabled,
            servicesAutoSelectEpisodesEnabled: servicesAutoSelectEpisodesEnabled,
            servicesAutoModeSourceIds: servicesAutoModeSourceIds,
            servicesAutoModeSourceOrderIds: servicesAutoModeSourceOrderIds,
            servicesAutoModeQualityPreference: servicesAutoModeQualityPreference,
            servicesResultMinimumSimilarity: servicesResultMinimumSimilarity,
            servicesDropMismatchedResults: servicesDropMismatchedResults,
            servicesStremioStyleSheetEnabled: servicesStremioStyleSheetEnabled,
            servicesIncludedStreamLanguages: servicesIncludedStreamLanguages,
            servicesHiddenStreamLanguages: servicesHiddenStreamLanguages,
            servicesHideStreamsWithoutLanguageData: servicesHideStreamsWithoutLanguageData,
            servicesAssumeOriginalAudio: servicesAssumeOriginalAudio,
            servicesTreatDubbedAnimeAsEnglish: servicesTreatDubbedAnimeAsEnglish,
            servicesHiddenStreamQualities: servicesHiddenStreamQualities,
            servicesHideStreamsWithoutDetectedQuality: servicesHideStreamsWithoutDetectedQuality,
            servicesExtraRulesSourceIds: servicesExtraRulesSourceIds,
            githubReleaseAutoCheckEnabled: githubReleaseAutoCheckEnabled,
            githubReleaseUpdateAvailable: githubReleaseUpdateAvailable,
            githubReleaseLatestVersion: githubReleaseLatestVersion,
            githubReleaseURL: githubReleaseURL,
            githubReleaseShowAlertPending: githubReleaseShowAlertPending,
            githubReleaseLastPromptedVersion: githubReleaseLastPromptedVersion,
            filterHorrorContent: filterHorrorContent,
            selectedSimilarityAlgorithm: selectedSimilarityAlgorithm,
            performanceModeEnabled: performanceModeEnabled,
            performanceModeSkipAniListTraversalForAnimeDetails: performanceModeSkipAniListTraversalForAnimeDetails,
            performanceModeFastAnimeCatalogOverrides: performanceModeFastAnimeCatalogOverrides,
            kanzenHomeSelectedSourceID: kanzenHomeSelectedSourceID,
            kanzenRecentSourceSearches: kanzenRecentSourceSearches,
            collections: collections,
            progressData: progressData,
            trackerState: trackerState,
            catalogs: catalogs,
            services: services,
            stremioAddons: stremioAddons,
            mangaCollections: mangaCollections,
            mangaReadingProgress: mangaReadingProgress,
            mangaCatalogs: mangaCatalogs,
            kanzenModules: kanzenModules,
            aidokuState: aidokuState,
            searchHistory: searchHistory,
            recommendationCache: recommendationCache,
            userRatings: userRatings,
            userRatingNotes: userRatingNotes,
            mediaStateSettings: mediaStateSettings,
            mangaCollectionsPresent: mangaCollectionsPresent,
            mangaReadingProgressPresent: mangaReadingProgressPresent,
            mangaCatalogsPresent: mangaCatalogsPresent,
            kanzenModulesPresent: kanzenModulesPresent,
            userRatingsPresent: userRatingsPresent
        )
    }
    
    /// Applies backup data to all managers and UserDefaults
    private func applyBackupData(_ backup: BackupData, refreshCloudSources: Bool = false) -> Bool {
        var trackerManager: TrackerManager!
        performOnMainThread {
            trackerManager = TrackerManager.shared
        }
        trackerManager.setBackupRestoreSyncSuppressed(true)
        defer {
            trackerManager.setBackupRestoreSyncSuppressed(false)
        }

        let userDefaults = UserDefaults.standard

        // Restore the shared safe-settings envelope first. Hand-written fields
        // below remain authoritative for older/newer schema migrations.
        BackupData.restoreMediaStateSettings(backup.mediaStateSettings, to: userDefaults)
        
        // Restore settings
        if let accentColorData = backup.accentColor {
            userDefaults.set(accentColorData, forKey: "accentColor")
        }
        if let settingsGradientColor = backup.settingsGradientColor {
            userDefaults.set(settingsGradientColor, forKey: "eclipseThemeGradientColor")
        }
        if let readerAccentColor = backup.readerAccentColor {
            userDefaults.set(readerAccentColor, forKey: "readerAccentColor")
        }
        if let readerSettingsGradientColor = backup.readerSettingsGradientColor {
            userDefaults.set(readerSettingsGradientColor, forKey: "readerThemeGradientColor")
        }
        userDefaults.set(backup.tmdbLanguage, forKey: "tmdbLanguage")
        userDefaults.set(BackupData.sanitizedAppearance(backup.selectedAppearance), forKey: "selectedAppearance")
        userDefaults.set(BackupData.sanitizedAppearance(backup.readerSelectedAppearance), forKey: "readerSelectedAppearance")
        userDefaults.set(backup.readerGlobalAppearanceEnabled, forKey: "readerGlobalAppearanceEnabled")
        userDefaults.set(backup.enableSubtitlesByDefault, forKey: "enableSubtitlesByDefault")
        userDefaults.set(backup.defaultSubtitleLanguage, forKey: "defaultSubtitleLanguage")
        userDefaults.set(backup.playerSubtitleAppearanceEnabled, forKey: "playerSubtitleAppearanceEnabled")

        userDefaults.set(backup.preferredAutoAudioLanguage, forKey: "preferredAutoAudioLanguage")
        userDefaults.set(backup.preferredAnimeAudioLanguage, forKey: "preferredAnimeAudioLanguage")
        let restoredEngineRaw = Settings.normalizedInAppPlayer(backup.inAppPlayer)
        let decodedEngine = PlaybackEngine(rawValue: restoredEngineRaw)
            ?? PlaybackEngine.defaultSelection(deviceFamily: .current)
        let restoredEngine = PlaybackEngine.supportedSelection(
            decodedEngine,
            deviceFamily: .current
        )
        userDefaults.set(restoredEngine.rawValue, forKey: PlaybackEngine.defaultsKey)
        // Keep the legacy key readable by older Eclipse builds after applying this device's
        // supported-selection policy.
        userDefaults.set(restoredEngine.rawValue, forKey: "inAppPlayer")
        userDefaults.set(backup.showScheduleTab, forKey: "showScheduleTab")
        userDefaults.set(backup.showLocalScheduleTime, forKey: "showLocalScheduleTime")
        userDefaults.set(ScheduleMode.sanitizedRawValue(backup.defaultScheduleMode), forKey: "defaultScheduleMode")
        userDefaults.set(ScheduleWindow.sanitizedDays(backup.scheduleWindowDays), forKey: ScheduleWindow.storageKey)
        if let value = backup.localNotificationSubscriptions {
            userDefaults.set(value, forKey: "localNotificationSubscriptions")
        }
        if let value = backup.localNotificationEpisodeReminders {
            userDefaults.set(value, forKey: "localNotificationEpisodeReminders")
        }
        if let value = backup.localNotificationEpisodeLeadTime {
            userDefaults.set(value, forKey: "localNotificationEpisodeLeadTime")
        }
        if let value = backup.localNotificationSeasonLeadTime {
            userDefaults.set(value, forKey: "localNotificationSeasonLeadTime")
        }
        if let value = backup.localNotificationIncludeAnimeSpecials {
            userDefaults.set(value, forKey: "localNotificationIncludeAnimeSpecials")
        }

        // Player settings
        userDefaults.set(backup.defaultPlaybackSpeed, forKey: "defaultPlaybackSpeed")
        userDefaults.set(backup.holdSpeedPlayer, forKey: "holdSpeedPlayer")
        userDefaults.set(backup.externalPlayer, forKey: "externalPlayer")
        userDefaults.set(backup.preferDownloadedMedia, forKey: "preferDownloadedMedia")
        userDefaults.set(backup.alwaysLandscape, forKey: "alwaysLandscape")
        PlayerPlaybackLockSettings.setEnabled(backup.playerPlaybackLockEnabled, defaults: userDefaults)
        userDefaults.set(backup.aniSkipEnabled, forKey: "aniSkipEnabled")
        userDefaults.set(backup.introDBEnabled, forKey: "introDBEnabled")
        userDefaults.set(backup.introDBAppEnabled, forKey: "introDBAppEnabled")
        userDefaults.set(backup.aniSkipAutoSkip, forKey: "aniSkipAutoSkip")
        userDefaults.set(backup.skip85sEnabled, forKey: "skip85sEnabled")
        userDefaults.set(backup.skip85sAlwaysVisible, forKey: "skip85sAlwaysVisible")
        userDefaults.set(backup.showNextEpisodeButton, forKey: "showNextEpisodeButton")
        userDefaults.set(backup.showEpisodeBrowserButton, forKey: "showEpisodeBrowserButton")
        userDefaults.set(backup.showPlayerServicesButton, forKey: PlayerServicesButtonSettings.key)
        userDefaults.set(backup.showNextEpisodePosterButton, forKey: "showNextEpisodePosterButton")
        userDefaults.set(backup.nextEpisodeThreshold, forKey: "nextEpisodeThreshold")
        userDefaults.set(backup.nextEpisodeSkipFillerEnabled, forKey: NextEpisodeFillerSettings.enabledKey)
        userDefaults.set(backup.playerBrightnessGestureEnabled, forKey: "playerBrightnessGestureEnabled")
        userDefaults.set(backup.playerVolumeGestureEnabled, forKey: "playerVolumeGestureEnabled")
        userDefaults.set(backup.playerTwoFingerTapPlayPauseEnabled, forKey: "playerTwoFingerTapPlayPauseEnabled")
        userDefaults.set(backup.playerCenterTapPlayPauseEnabled, forKey: "playerCenterTapPlayPauseEnabled")
        userDefaults.set(backup.playerDoubleTapSeekEnabled, forKey: "playerDoubleTapSeekEnabled")
        userDefaults.set(backup.playerDoubleTapSeekSeconds, forKey: "playerDoubleTapSeekSeconds")
        userDefaults.set(backup.playerOpenSubtitlesEnabled, forKey: "playerOpenSubtitlesEnabled")
        userDefaults.set(backup.playerOpenSubtitlesAutoFallbackEnabled, forKey: "playerOpenSubtitlesAutoFallbackEnabled")
        userDefaults.set(backup.playerPerformanceOverlayEnabled, forKey: "playerPerformanceOverlayEnabled")
        userDefaults.set(backup.mpvForegroundFPS == 60 ? 60 : 30, forKey: "mpvForegroundFPS")
        userDefaults.set(BackupData.sanitizedMPVRenderBackend(backup.mpvRenderBackend), forKey: "mpvRenderBackend")
        userDefaults.set(BackupData.sanitizedMPVMetalQualityProfile(backup.mpvMetalQualityProfile), forKey: "mpvMetalQualityProfile")
        userDefaults.set(BackupData.sanitizedMPVUpscalingMode(backup.mpvUpscalingMode), forKey: "mpvUpscalingMode")
        userDefaults.set(BackupData.sanitizedMPVPlayerSkin(backup.mpvPlayerSkin), forKey: MPVPlayerSkinSettings.skinKey)
        if let primaryColor = backup.mpvPlayerSkinCustomPrimaryColor {
            userDefaults.set(primaryColor, forKey: MPVPlayerSkinSettings.customPrimaryColorKey)
        } else {
            userDefaults.removeObject(forKey: MPVPlayerSkinSettings.customPrimaryColorKey)
        }
        if let secondaryColor = backup.mpvPlayerSkinCustomSecondaryColor {
            userDefaults.set(secondaryColor, forKey: MPVPlayerSkinSettings.customSecondaryColorKey)
        } else {
            userDefaults.removeObject(forKey: MPVPlayerSkinSettings.customSecondaryColorKey)
        }
        userDefaults.set(backup.mpvPlayerSkinAnimationsEnabled, forKey: MPVPlayerSkinSettings.animationsEnabledKey)
        userDefaults.set(backup.mpvPlayerSkinTintControlsOnly, forKey: MPVPlayerSkinSettings.tintControlsOnlyKey)
        userDefaults.set(backup.mpvPictureInPictureEnabled, forKey: "mpvPictureInPictureEnabled")
        userDefaults.set(backup.mpvAppExitPictureInPictureEnabled, forKey: "mpvAppExitPictureInPictureEnabled")
        userDefaults.set(MPVHDRMode(rawValue: backup.mpvHDRMode)?.rawValue ?? MPVHDRMode.defaultMode.rawValue, forKey: "mpvHDRMode")
        userDefaults.set(backup.mpvSurroundSoundEnabled, forKey: "mpvSurroundSoundEnabled")
        userDefaults.set(backup.watchTogetherEnabled, forKey: WatchTogetherSettings.enabledKey)
        userDefaults.set(backup.smartInAppPlayerChoosingEnabled, forKey: "smartInAppPlayerChoosingEnabled")
        userDefaults.set(backup.experimentalFeaturesEnabled, forKey: ExperimentalFeatureState.enabledKey)
        userDefaults.set(backup.experimentalFeaturesLastChangedAt, forKey: ExperimentalFeatureState.lastChangedAtKey)
        userDefaults.set(backup.experimentalMPVPreloadEnabled, forKey: ExperimentalFeatureState.mpvPreloadEnabledKey)
        userDefaults.set(backup.experimentalMPVSmoothTransitionEnabled, forKey: ExperimentalFeatureState.mpvSmoothTransitionEnabledKey)
        userDefaults.set(backup.experimentalMPVPreloadCellularEnabled, forKey: ExperimentalFeatureState.mpvPreloadCellularEnabledKey)
        userDefaults.set(ExperimentalFeatureState.clampedMPVPreloadWifiLimitMB(backup.experimentalMPVPreloadWifiLimitMB), forKey: ExperimentalFeatureState.mpvPreloadWifiLimitMBKey)
        userDefaults.set(ExperimentalFeatureState.clampedMPVPreloadCellularLimitMB(backup.experimentalMPVPreloadCellularLimitMB), forKey: ExperimentalFeatureState.mpvPreloadCellularLimitMBKey)
        userDefaults.set(backup.experimentalMPVShowRemainingTime, forKey: ExperimentalFeatureState.mpvShowRemainingTimeKey)
        userDefaults.set(backup.experimentalMPVPreciseProgress, forKey: ExperimentalFeatureState.mpvPreciseProgressKey)
        userDefaults.set(backup.experimentalMPVIgnoreSpecialSubtitleStyles, forKey: ExperimentalFeatureState.mpvIgnoreSpecialSubtitleStylesKey)
        userDefaults.set(backup.experimentalMPVPreloadAutoClear, forKey: ExperimentalFeatureState.mpvPreloadAutoClearKey)
        userDefaults.set(backup.experimentalICloudSyncEnabled && ExperimentalCloudSyncAvailability.current.isAvailable, forKey: ExperimentalFeatureState.iCloudSyncEnabledKey)

        // Subtitle styling
        if let fgColor = backup.subtitleForegroundColor {
            userDefaults.set(fgColor, forKey: "subtitles_foregroundColor")
        }
        if let strokeColor = backup.subtitleStrokeColor {
            userDefaults.set(strokeColor, forKey: "subtitles_strokeColor")
        }
        userDefaults.set(backup.subtitleStrokeWidth, forKey: "subtitles_strokeWidth")
        userDefaults.set(backup.subtitleFontSize, forKey: "subtitles_fontSize")
        userDefaults.set(backup.subtitleVerticalOffset, forKey: "playerSubtitleOverlayBottomConstant")
        userDefaults.set(backup.subtitlesVisible, forKey: "subtitles_isVisible")

        // UI preferences
        userDefaults.set(backup.showKanzen, forKey: "showKanzen")
        if let hideSplashScreen = backup.hideSplashScreen {
            userDefaults.set(hideSplashScreen, forKey: "hideSplashScreen")
        }
        userDefaults.set(backup.modeSwitchAnimationEnabled, forKey: ModeSwitchAnimationSettings.enabledKey)
        userDefaults.set(backup.kanzenAutoUpdateModules, forKey: "kanzenAutoUpdateModules")
        userDefaults.set(backup.seasonMenu, forKey: "seasonMenu")
        userDefaults.set(backup.horizontalEpisodeList, forKey: "horizontalEpisodeList")
        userDefaults.set(backup.mediaDetailTitleArtworkEnabled, forKey: MediaDetailTitleArtworkSettings.enabledKey)
        userDefaults.set(backup.mediaDetailSimilarTitlesEnabled, forKey: MediaDetailSimilarTitlesSettings.enabledKey)
        userDefaults.set(backup.useClassicScheduleUI, forKey: "useClassicScheduleUI")
        userDefaults.set(BackupData.sanitizedNonEmptyString(backup.heroBannerCatalogId, defaultValue: "trending"), forKey: "heroBannerCatalogId")
        userDefaults.set(BackupData.sanitizedHeroBannerBehavior(backup.heroBannerBehavior), forKey: "heroBannerBehavior")
        if let overridesData = backup.homeCatalogLayoutOverrides.data(using: .utf8), !backup.homeCatalogLayoutOverrides.isEmpty {
            userDefaults.set(overridesData, forKey: HomeCatalogLayoutStore.storageKey)
        } else {
            userDefaults.removeObject(forKey: HomeCatalogLayoutStore.storageKey)
        }
        HomeCatalogLayoutStore.shared.reloadFromStorage()
        if let homeAnimatedBackgroundEnabled = backup.homeAnimatedBackgroundEnabled {
            userDefaults.set(homeAnimatedBackgroundEnabled, forKey: HomeAnimatedBackgroundSettings.enabledKey)
        }
        userDefaults.set(BackupData.sanitizedHomeAnimatedBackgroundQuality(backup.homeAnimatedBackgroundQuality), forKey: HomeAnimatedBackgroundQuality.storageKey)
        userDefaults.set(BackupData.sanitizedHomeAnimatedBackgroundFrameRate(backup.homeAnimatedBackgroundFrameRate), forKey: HomeAnimatedBackgroundFrameRate.storageKey)
        userDefaults.set(backup.appPerformanceOverlayEnabled, forKey: AppPerformanceOverlaySettings.enabledKey)
        userDefaults.set(BackupData.sanitizedExperimentalMediaDesignPreset(backup.experimentalMediaDesignPreset), forKey: ExperimentalMediaDesignPreset.storageKey)
        userDefaults.set(BackupData.sanitizedExperimentalHeroBleedLevel(backup.experimentalHeroBleedLevel), forKey: ExperimentalHeroBleedLevel.storageKey)
        userDefaults.set(BackupData.sanitizedExperimentalHomeCardShape(backup.experimentalHomeCardShape), forKey: ExperimentalHomeCardShape.storageKey)
        userDefaults.set(BackupData.sanitizedExperimentalMultiGradientPalette(backup.experimentalMultiGradientPalette), forKey: ExperimentalMultiGradientPalette.storageKey)
        userDefaults.set(BackupData.sanitizedExperimentalHeroHeightScale(backup.experimentalHeroHeightScale), forKey: ExperimentalVisualTuning.heroHeightScaleKey)
        userDefaults.set(BackupData.sanitizedExperimentalHeroBleedStrength(backup.experimentalHeroBleedStrength), forKey: ExperimentalVisualTuning.heroBleedStrengthKey)
        userDefaults.set(BackupData.sanitizedExperimentalHeroFadeDistanceScale(backup.experimentalHeroFadeDistanceScale), forKey: ExperimentalVisualTuning.heroFadeDistanceScaleKey)
        userDefaults.set(BackupData.sanitizedExperimentalSectionSpacingScale(backup.experimentalSectionSpacingScale), forKey: ExperimentalVisualTuning.sectionSpacingScaleKey)
        userDefaults.set(BackupData.sanitizedExperimentalCardRadiusScale(backup.experimentalCardRadiusScale), forKey: ExperimentalVisualTuning.cardRadiusScaleKey)
        userDefaults.set(BackupData.sanitizedExperimentalMediaCardScale(backup.experimentalMediaCardScale), forKey: ExperimentalVisualTuning.mediaCardScaleKey)
        userDefaults.set(BackupData.sanitizedExperimentalGlassStrength(backup.experimentalGlassStrength), forKey: ExperimentalVisualTuning.glassStrengthKey)
        userDefaults.set(BackupData.sanitizedExperimentalGradientBaseDarkness(backup.experimentalGradientBaseDarkness), forKey: ExperimentalVisualTuning.gradientBaseDarknessKey)
        userDefaults.set(BackupData.sanitizedExperimentalGradientAccentIntensity(backup.experimentalGradientAccentIntensity), forKey: ExperimentalVisualTuning.gradientAccentIntensityKey)
        userDefaults.set(BackupData.sanitizedExperimentalGradientScrollMotion(backup.experimentalGradientScrollMotion), forKey: ExperimentalVisualTuning.gradientScrollMotionKey)
        userDefaults.set(backup.experimentalGradientUseCustomColors, forKey: ExperimentalVisualTuning.gradientUseCustomColorsKey)
        if let experimentalGradientColorA = backup.experimentalGradientColorA {
            userDefaults.set(experimentalGradientColorA, forKey: ExperimentalVisualTuning.gradientColorAKey)
        }
        if let experimentalGradientColorB = backup.experimentalGradientColorB {
            userDefaults.set(experimentalGradientColorB, forKey: ExperimentalVisualTuning.gradientColorBKey)
        }
        if let experimentalGradientColorC = backup.experimentalGradientColorC {
            userDefaults.set(experimentalGradientColorC, forKey: ExperimentalVisualTuning.gradientColorCKey)
        }
        userDefaults.set(BackupData.sanitizedAtmosphereStyle(backup.atmosphereStyle), forKey: "atmosphereStyle")
        userDefaults.set(BackupData.sanitizedAtmosphereSolidColorSource(backup.atmosphereSolidColorSource), forKey: "atmosphereSolidColorSource")
        if let atmosphereSolidColor = backup.atmosphereSolidColor {
            userDefaults.set(atmosphereSolidColor, forKey: "atmosphereSolidColor")
        }
        userDefaults.set(BackupData.sanitizedAtmosphereStyle(backup.readerAtmosphereStyle), forKey: "readerAtmosphereStyle")
        userDefaults.set(BackupData.sanitizedAtmosphereSolidColorSource(backup.readerAtmosphereSolidColorSource), forKey: "readerAtmosphereSolidColorSource")
        if let readerAtmosphereSolidColor = backup.readerAtmosphereSolidColor {
            userDefaults.set(readerAtmosphereSolidColor, forKey: "readerAtmosphereSolidColor")
        }
        let restoredMediaDetailHiddenElements = BackupData.sanitizedMediaDetailHiddenElements(backup.mediaDetailHiddenElements)
        userDefaults.set(BackupData.sanitizedMediaDetailElementOrder(backup.mediaDetailElementOrder), forKey: MediaDetailElement.orderStorageKey)
        userDefaults.set(restoredMediaDetailHiddenElements, forKey: MediaDetailElement.hiddenStorageKey)
        userDefaults.set(!MediaDetailElement.hiddenElements(from: restoredMediaDetailHiddenElements, legacyShowCastSection: true).contains(.cast), forKey: MediaDetailElement.legacyShowCastStorageKey)
        userDefaults.set(BackupData.sanitizedReaderDetailElementOrder(backup.readerDetailElementOrder), forKey: ReaderDetailElement.orderStorageKey)
        userDefaults.set(BackupData.sanitizedReaderDetailHiddenElements(backup.readerDetailHiddenElements), forKey: ReaderDetailElement.hiddenStorageKey)
        userDefaults.set(backup.mediaColumnsPortrait, forKey: "mediaColumnsPortrait")
        userDefaults.set(backup.mediaColumnsLandscape, forKey: "mediaColumnsLandscape")

        // Manga / Reader
        userDefaults.set(backup.readingMode, forKey: "readingMode")
        let restoredKanzenReaderMode = BackupData.sanitizedKanzenReaderMode(backup.kanzenReaderMode)
        userDefaults.set(restoredKanzenReaderMode, forKey: "kanzenReaderMode")
        BackupData.sanitizedKanzenReaderModeOverrides(backup.kanzenReaderModeOverrides).forEach { key, value in
            userDefaults.set(value, forKey: "kanzenReaderMode.\(key)")
        }
        userDefaults.set(backup.readerDownsampleImages, forKey: "Reader.downsampleImages")
        userDefaults.set(backup.readerCropBorders, forKey: "Reader.cropBorders")
        userDefaults.set(backup.readerDisableQuickActions, forKey: "Reader.disableQuickActions")
        userDefaults.set(backup.readerDisableDoubleTap, forKey: "Reader.disableDoubleTap")
        userDefaults.set(backup.readerLiveText, forKey: "Reader.liveText")
        userDefaults.set(backup.readerHideBarsOnSwipe, forKey: "Reader.hideBarsOnSwipe")
        userDefaults.set(BackupData.sanitizedReaderBackgroundColor(backup.readerBackgroundColor), forKey: "Reader.backgroundColor")
        userDefaults.set(BackupData.sanitizedReaderOrientation(backup.readerOrientation), forKey: "Reader.orientation")
        userDefaults.set(BackupData.sanitizedReaderTapZones(backup.readerTapZones), forKey: "Reader.tapZones")
        userDefaults.set(backup.readerInvertTapZones, forKey: "Reader.invertTapZones")
        userDefaults.set(backup.readerAnimatePageTransitions, forKey: "Reader.animatePageTransitions")
        userDefaults.set(backup.readerUpscaleImages, forKey: "Reader.upscaleImages")
        userDefaults.set(BackupData.sanitizedReaderUpscaleMaxHeight(backup.readerUpscaleMaxHeight), forKey: "Reader.upscaleMaxHeight")
        userDefaults.set(backup.readerUpscaleModelName, forKey: "Reader.upscaleModelName")
        userDefaults.set(BackupData.sanitizedReaderPagesToPreload(backup.readerPagesToPreload), forKey: "Reader.pagesToPreload")
        userDefaults.set(BackupData.sanitizedReaderPagedPageLayout(backup.readerPagedPageLayout), forKey: "Reader.pagedPageLayout")
        userDefaults.set(backup.readerPagedPageOffset, forKey: "Reader.pagedPageOffset")
        BackupData.sanitizedReaderPagedPageOffsetOverrides(backup.readerPagedPageOffsetOverrides).forEach { key, value in
            userDefaults.set(value, forKey: "Reader.pagedPageOffset.\(key)")
        }
        userDefaults.set(backup.readerSplitWideImages, forKey: "Reader.splitWideImages")
        userDefaults.set(backup.readerReverseSplitOrder, forKey: "Reader.reverseSplitOrder")
        userDefaults.set(backup.readerVerticalInfiniteScroll, forKey: "Reader.verticalInfiniteScroll")
        userDefaults.set(backup.readerPillarbox, forKey: "Reader.pillarbox")
        userDefaults.set(BackupData.sanitizedReaderPillarboxAmount(backup.readerPillarboxAmount), forKey: "Reader.pillarboxAmount")
        userDefaults.set(BackupData.sanitizedReaderPillarboxOrientation(backup.readerPillarboxOrientation), forKey: "Reader.pillarboxOrientation")
        userDefaults.set(backup.readerOrientationLockEnabled, forKey: "readerOrientationLockEnabled")
        userDefaults.set(BackupData.sanitizedReaderOrientationLockMask(backup.readerOrientationLockMask), forKey: "readerOrientationLockMask")
        userDefaults.set(BackupData.sanitizedReaderReadThresholdPercent(backup.readerReadThresholdPercent), forKey: "readerReadThresholdPercent")

        // Novel Reader
        userDefaults.set(backup.readerFontSize, forKey: "readerFontSize")
        userDefaults.set(backup.readerFontFamily, forKey: "readerFontFamily")
        userDefaults.set(backup.readerFontWeight, forKey: "readerFontWeight")
        userDefaults.set(backup.readerColorPreset, forKey: "readerColorPreset")
        userDefaults.set(backup.readerTextAlignment, forKey: "readerTextAlignment")
        userDefaults.set(backup.readerLineSpacing, forKey: "readerLineSpacing")
        userDefaults.set(backup.readerMargin, forKey: "readerMargin")

        // Other
        userDefaults.set(backup.autoClearCacheEnabled, forKey: "autoClearCacheEnabled")
        userDefaults.set(backup.autoClearCacheThresholdMB, forKey: "autoClearCacheThresholdMB")
        userDefaults.set(backup.highQualityThreshold, forKey: "highQualityThreshold")
        userDefaults.set(backup.backgroundHLSPipelineEnabled, forKey: "backgroundHLSPipelineEnabled")
        userDefaults.set(backup.readerDownloadsBackgroundEnabled, forKey: "readerDownloadsBackgroundEnabled")
        userDefaults.set(backup.readerDownloadsWifiOnly, forKey: "readerDownloadsWifiOnly")
        userDefaults.set(BackupData.sanitizedReaderDownloadsParallelLimit(backup.readerDownloadsParallelLimit), forKey: "readerDownloadsParallelLimit")
        userDefaults.set(backup.autoUpdateServicesEnabled, forKey: "autoUpdateServicesEnabled")
        userDefaults.set(backup.servicesAutoModeEnabled, forKey: "servicesAutoModeEnabled")
        userDefaults.set(backup.servicesAutoSelectEpisodesEnabled, forKey: "servicesAutoSelectEpisodesEnabled")
        let restoredAutoModeSourceIds = BackupData.sanitizedStringList(backup.servicesAutoModeSourceIds)
        let restoredAutoModeSourceIdSet = Set(restoredAutoModeSourceIds)
        let orderedAutoModeSourceIds = BackupData.sanitizedStringList(backup.servicesAutoModeSourceOrderIds)
            .filter { restoredAutoModeSourceIdSet.contains($0) }
        let restoredAutoModeSourceOrderIds = orderedAutoModeSourceIds + restoredAutoModeSourceIds.filter { !orderedAutoModeSourceIds.contains($0) }
        userDefaults.set(restoredAutoModeSourceIds, forKey: "servicesAutoModeSourceIds")
        userDefaults.set(restoredAutoModeSourceOrderIds, forKey: "servicesAutoModeSourceOrderIds")
        userDefaults.set(AutoModeQualityPreference.sanitizedRawValue(backup.servicesAutoModeQualityPreference), forKey: AutoModeQualityPreference.storageKey)
        ServicesResultRankingSettings.setMinimumSimilarity(backup.servicesResultMinimumSimilarity, defaults: userDefaults)
        ServicesResultRankingSettings.setDropsMismatchedResults(backup.servicesDropMismatchedResults, defaults: userDefaults)
        userDefaults.set(backup.servicesStremioStyleSheetEnabled, forKey: ServicesSheetPresentationSettings.stremioStyleEnabledKey)
        StreamLanguageFilter.setIncludedLanguages(backup.servicesIncludedStreamLanguages, defaults: userDefaults)
        StreamLanguageFilter.setHiddenLanguages(backup.servicesHiddenStreamLanguages, defaults: userDefaults)
        StreamLanguageFilter.setHidesStreamsWithoutLanguageData(backup.servicesHideStreamsWithoutLanguageData, defaults: userDefaults)
        StreamLanguageFilter.setAssumesOriginalAudio(backup.servicesAssumeOriginalAudio, defaults: userDefaults)
        StreamLanguageFilter.setTreatsDubbedAnimeAsEnglish(backup.servicesTreatDubbedAnimeAsEnglish, defaults: userDefaults)
        StreamLanguageFilter.setHiddenQualityHeights(backup.servicesHiddenStreamQualities, defaults: userDefaults)
        StreamLanguageFilter.setHidesStreamsWithoutDetectedQuality(backup.servicesHideStreamsWithoutDetectedQuality, defaults: userDefaults)
        StreamLanguageFilter.setExtraRulesSourceIds(backup.servicesExtraRulesSourceIds, defaults: userDefaults)
        userDefaults.set(backup.githubReleaseAutoCheckEnabled, forKey: "githubReleaseAutoCheckEnabled")
        userDefaults.set(backup.githubReleaseUpdateAvailable, forKey: "githubReleaseUpdateAvailable")
        userDefaults.set(backup.githubReleaseLatestVersion, forKey: "githubReleaseLatestVersion")
        userDefaults.set(backup.githubReleaseURL, forKey: "githubReleaseURL")
        userDefaults.set(backup.githubReleaseShowAlertPending, forKey: "githubReleaseShowAlertPending")
        userDefaults.set(backup.githubReleaseLastPromptedVersion, forKey: "githubReleaseLastPromptedVersion")
        userDefaults.set(backup.filterHorrorContent, forKey: "filterHorror")
        userDefaults.set(BackupData.sanitizedSimilarityAlgorithm(backup.selectedSimilarityAlgorithm), forKey: "selectedSimilarityAlgorithm")
        userDefaults.set(backup.kanzenHomeSelectedSourceID, forKey: "kanzenHomeSelectedSourceID")
        userDefaults.set(backup.kanzenRecentSourceSearches, forKey: "kanzenRecentSourceSearches")
        userDefaults.set(backup.performanceModeEnabled, forKey: PerformanceModeSettings.enabledKey)
        userDefaults.set(backup.performanceModeSkipAniListTraversalForAnimeDetails, forKey: PerformanceModeSettings.skipAniListTraversalForAnimeDetailsKey)
        PerformanceModeSettings.fastAnimeCatalogOverrides = backup.performanceModeFastAnimeCatalogOverrides
        if let searchHistoryData = try? JSONEncoder().encode(backup.searchHistory.queries) {
            userDefaults.set(searchHistoryData, forKey: "searchHistory")
        }
        performOnMainThread {
            TMDBContentFilter.shared.filterHorror = backup.filterHorrorContent
            AlgorithmManager.shared.selectedAlgorithm = SimilarityAlgorithm(rawValue: BackupData.sanitizedSimilarityAlgorithm(backup.selectedSimilarityAlgorithm)) ?? .hybrid

            // Reload Settings singleton to pick up changes
            let settings = Settings.shared
            let theme = EclipseTheme.shared
            settings.objectWillChange.send()
            theme.objectWillChange.send()
        }
        
        // Restore collections
        let restoredCollections = backup.collections.map { $0.toLibraryCollection() }
        performOnMainThread {
            LibraryManager.shared.collections = restoredCollections
        }
        // Collections are auto-saved in LibraryManager
        
        // Restore progress data in bulk to avoid per-entry tracker sync bursts (prevents AniList 429)
        let progressManager = ProgressManager.shared
        progressManager.replaceProgressDataForRestore(backup.progressData)
        
        // Tracker credentials are never written to backups. Merge metadata and
        // preferences while retaining credentials already held by this device.
        let restoreTrackerState = {
            var restoredState = backup.trackerState
            restoredState.accounts = backup.trackerState.accounts.compactMap { incoming in
                if !incoming.accessToken.isEmpty {
                    // Backward compatibility for older user-created backups.
                    return incoming
                }
                return trackerManager.trackerState.accounts.first(where: { $0.service == incoming.service })
            }
            trackerManager.trackerState = restoredState
            trackerManager.saveTrackerState()
        }
        performOnMainThread(restoreTrackerState)
        
        // Restore catalogs (merge to preserve new defaults like widget catalogs)
        if !backup.catalogs.isEmpty {
            var merged = backup.catalogs
            let existingIds = Set(merged.map { $0.id })
            var currentDefaults: [Catalog] = []
            performOnMainThread {
                currentDefaults = CatalogManager.shared.catalogs.filter { !existingIds.contains($0.id) }
            }
            merged.append(contentsOf: currentDefaults)
            merged = merged.enumerated().map { index, catalog in
                var updated = catalog
                updated.order = index
                return updated
            }
            performOnMainThread {
                let catalogManager = CatalogManager.shared
                catalogManager.setPerformanceModeEnabled(backup.performanceModeEnabled)
                catalogManager.catalogs = merged
                catalogManager.saveCatalogs()
            }
        } else {
            performOnMainThread {
                let catalogManager = CatalogManager.shared
                catalogManager.setPerformanceModeEnabled(backup.performanceModeEnabled)
                catalogManager.saveCatalogs()
            }
        }

        // Normal file backups are authoritative replacements. Redacted cloud
        // snapshots replace only cloud-eligible sources and retain device-local
        // providers that were omitted because they may contain credentials.
        let serviceStore = ServiceStore.shared
        let existingServices = serviceStore.getServices()
        let incomingServices = backup.services.sorted(by: {
            if $0.sortIndex == $1.sortIndex {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.sortIndex < $1.sortIndex
        })
        let servicesToRestore: [BackupService]
        var deviceLocalServiceIDs = Set<UUID>()
        if refreshCloudSources {
            let currentServices = existingServices.map { service in
                let metadata = (try? JSONEncoder().encode(service.metadata))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return BackupService(
                    id: service.id,
                    url: service.url,
                    jsonMetadata: metadata,
                    jsScript: service.jsScript,
                    isActive: service.isActive,
                    sortIndex: service.sortIndex
                )
            }
            deviceLocalServiceIDs = Set(currentServices.compactMap { service in
                BackupData.serviceForExperimentalCloudSync(service) == nil ? service.id : nil
            })
            servicesToRestore = ExperimentalCloudSourceRestorePolicy.services(
                current: currentServices,
                incoming: incomingServices
            )
        } else {
            servicesToRestore = incomingServices
        }
        let servicesToRemove = refreshCloudSources
            ? existingServices.filter { !deviceLocalServiceIDs.contains($0.id) }
            : existingServices
        servicesToRemove.forEach { serviceStore.remove($0) }
        for svc in servicesToRestore where !deviceLocalServiceIDs.contains(svc.id) {
            serviceStore.storeService(
                id: svc.id,
                url: svc.url,
                jsonMetadata: svc.jsonMetadata,
                jsScript: svc.jsScript,
                isActive: svc.isActive,
                sortIndex: svc.sortIndex
            )
        }
        if refreshCloudSources {
            let entities = serviceStore.getEntities()
            for (index, service) in servicesToRestore.enumerated() {
                entities.first(where: { $0.id == service.id })?.sortIndex = Int64(index)
            }
            serviceStore.save()
        }
        Task { @MainActor in
            ServiceManager.shared.loadServicesFromCloud()
        }

        // Restore Stremio addons only when the backup explicitly contains this field.
        // Older backups did not know about Stremio addons, so they must not wipe the current device's addons.
        if let stremioAddons = backup.stremioAddons {
            let stremioStore = StremioAddonStore.shared
            let incomingAddons = stremioAddons.sorted {
                if $0.sortIndex == $1.sortIndex {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.sortIndex < $1.sortIndex
            }
            let addonsToRestore: [BackupStremioAddon]
            var deviceLocalAddonIDs = Set<UUID>()
            if refreshCloudSources {
                let currentAddons = stremioStore.getAddons().map { addon in
                    let manifestJSON = (try? JSONEncoder().encode(addon.manifest))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    return BackupStremioAddon(
                        id: addon.id,
                        configuredURL: addon.configuredURL,
                        manifestJSON: manifestJSON,
                        isActive: addon.isActive,
                        sortIndex: addon.sortIndex
                    )
                }
                deviceLocalAddonIDs = Set(currentAddons.compactMap { addon in
                    BackupData.stremioAddonForExperimentalCloudSync(addon) == nil ? addon.id : nil
                })
                addonsToRestore = ExperimentalCloudSourceRestorePolicy.stremioAddons(
                    current: currentAddons,
                    incoming: incomingAddons
                )
            } else {
                addonsToRestore = incomingAddons
            }
            if refreshCloudSources {
                for addon in stremioStore.getAddons() where !deviceLocalAddonIDs.contains(addon.id) {
                    stremioStore.remove(addon)
                }
            } else {
                stremioStore.removeAll()
            }

            for addon in addonsToRestore where !deviceLocalAddonIDs.contains(addon.id) {
                let configuredURL = addon.configuredURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !configuredURL.isEmpty,
                      let manifestData = addon.manifestJSON.data(using: .utf8),
                      let manifest = try? JSONDecoder().decode(StremioManifest.self, from: manifestData),
                      manifest.supportsInstallableResources else {
                    Logger.shared.log("Skipping invalid Stremio addon from backup: \(addon.id)", type: "Stremio")
                    continue
                }

                stremioStore.storeAddon(
                    id: addon.id,
                    configuredURL: configuredURL,
                    manifestJSON: addon.manifestJSON,
                    isActive: addon.isActive,
                    sortIndex: addon.sortIndex
                )
            }
            if refreshCloudSources {
                let entities = stremioStore.getEntities()
                for (index, addon) in addonsToRestore.enumerated() {
                    entities.first(where: { $0.id == addon.id })?.sortIndex = Int64(index)
                }
                stremioStore.save()
            }

            Task { @MainActor in
                StremioAddonManager.shared.loadAddons()
            }
        }

        // Restore manga library collections. An explicitly empty array is a
        // real cleared state; only older backups that omit the field preserve
        // the destination's existing data.
        if backup.hasMangaCollections {
            let restoredMangaCollections = backup.mangaCollections.map { bc in
                MangaLibraryCollection(id: bc.id, name: bc.name, items: bc.items, description: bc.description)
            }
            performOnMainThread {
                MangaLibraryManager.shared.collections = restoredMangaCollections
            }
        }

        // Restore manga reading progress, including an explicit empty map.
        if backup.hasMangaReadingProgress {
            let mangaProgressMap = Dictionary(
                backup.mangaReadingProgress.compactMap { key, value -> (Int, MangaProgress)? in
                    guard let id = Int(key) else { return nil }
                    return (id, value)
                },
                uniquingKeysWith: { _, incoming in incoming }
            )
            performOnMainThread {
                MangaReadingProgressManager.shared.replaceProgressMapForRestore(mangaProgressMap)
            }
        }

        // Restore manga catalogs, including an explicit empty list.
        if backup.hasMangaCatalogs {
            let mangaCatalogManager = MangaCatalogManager.shared
            mangaCatalogManager.catalogs = backup.mangaCatalogs
            mangaCatalogManager.saveCatalogs()
        }

        // Restore Kanzen modules as a replacement so removed modules do not
        // survive on the destination. ModuleManager will re-download missing
        // local script files from each module's script URL when needed.
        if backup.hasKanzenModules {
            let restoredModules = backup.kanzenModules.map { mod in
                ModuleDataContainer(
                    id: mod.id,
                    moduleData: mod.moduleData,
                    localPath: mod.localPath,
                    moduleurl: mod.moduleurl,
                    isActive: mod.isActive
                )
            }
            performOnMainThread {
                let kanzenModuleManager = ModuleManager.shared
                kanzenModuleManager.modules = restoredModules
                kanzenModuleManager.saveModules()
            }
        }

#if !os(tvOS)
        if let aidokuState = backup.aidokuState {
            AidokuBackupBridge.restoreBackupSnapshotToDisk(aidokuState)
            Task { @MainActor in
                await AidokuSourceManager.shared.reloadPersistedStateAfterRestore()
            }
        }
#endif

        // Restore recommendation cache
        if !backup.recommendationCache.isEmpty {
            RecommendationEngine.shared.restoreRecommendationCache(backup.recommendationCache)
        }

        // Restore user ratings and private notes without triggering tracker
        // writes. Empty maps are authoritative when present in the backup.
        if backup.hasUserRatings {
            UserRatingManager.shared.restoreRatingsAndNotes(
                ratings: backup.userRatings,
                notes: backup.userRatingNotes
            )
        }

#if os(iOS)
        Task { @MainActor in
            await LocalNotificationManager.shared.reloadPersistedSelectionsAfterRestore()
        }
#endif
        
        Logger.shared.log("Backup restored successfully", type: "Info")
        return true
    }
}
