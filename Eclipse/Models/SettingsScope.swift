import Foundation

enum EclipseSettingScope: Sendable {

    case profile

    case services

    case device
}

enum EclipseSettingsSyncPreference {

    static let enabledKey = "eclipseSyncSettingsAcrossDevicesV1"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

enum EclipseSettingsRegistry {

    static let deviceKeys: Set<String> = [
        "autoClearCacheEnabled",
        "autoClearCacheThresholdMB",
        "backgroundHLSPipelineEnabled",
        "downloadAnimeProviderAliasesV1",
        "anime.metadata.details.cache.v2",
        "tmdbFastAnimeAdultKeywordIDs.v1",
        "serviceCloudflareBypassCache",
        "serviceCloudflareInteractiveHosts",
        ServiceJavaScriptQuarantineStore.storageKey,
        "experimentalCloudRestorePendingV1",
        "experimentalCloudSyncPrimaryProviderV1",
        "experimentalICloudSyncEnabled",
        "experimentalICloudSyncLastSeenRemoteModificationAt",

        "experimentalGoogleDriveSyncEnabled",
        "experimentalGoogleDriveSyncLastSeenRemoteModificationAt",
        "experimentalOneDriveSyncEnabled",
        "experimentalOneDriveSyncLastSeenRemoteModificationAt",

        "mediaStateCloudKitSuspendedAfterDeletionV1",
        "mediaStateCloudKitOptInUpgradeNoticeHandledV1",

        "experimentalFeaturesEnabled",

        "eclipseProfilesV1",
        "eclipseActiveProfileIDV1",
        "eclipseDeletedProfileIDsV1",
        "eclipseProfileAsksOnLaunchV1",
        "eclipseSharesServicesAcrossProfilesV1",
        "eclipseSyncSettingsAcrossDevicesV1",

        "showKanzen",
        "hideSplashScreen",

        "eclipseOnboardingCompletedV1",
        "eclipseAppHubNoticeSeenV1"
    ]

    private static let devicePrefixes = [
        "githubRelease",
        "logger",
        "eclipseProfileStoreMigrationV1.",
        "experimentalCloudSync",
        "provider."
    ]

    static let servicesKeys: Set<String> = [
        "autoUpdateServicesEnabled",
        "lastServiceAutoUpdateTimestamp",
        "kanzenAutoUpdateModules",
        "kanzenLastModuleAutoUpdate"
    ]

    private static let servicesPrefixes = [
        "services",
        "skyStream",
        "nuvio",
        "stremio",
        "tvServices",
        "tvOSService",
        "readerExtensions.",
        "kanzenAidoku",

        "contentBlocking"
    ]

    static let profileKeys: Set<String> = [
        MediaStateServiceSourcesPayload.settingKey,
        "tmdbLanguage",
        "enableSubtitlesByDefault",
        "defaultSubtitleLanguage",
        "preferredAutoAudioLanguage",
        "preferredAnimeAudioLanguage",
        "defaultPlaybackSpeed",
        "playerOpenSubtitlesEnabled",
        "playerOpenSubtitlesAutoFallbackEnabled",
        "playerSubtitleAppearanceEnabled",
        "audioComfortMode",
        "audioComfortScopeCategories",
        "mpvSurroundSoundEnabled",
        "watchTogetherEnabled",
        "mpvPictureInPictureEnabled",
        "introDBEnabled",
        "introDBAppEnabled",
        "aniSkipAutoSkip",
        "showNextEpisodeButton",
        "showPlayerServicesButton",
        "nextEpisodeThreshold",
        "mediaDetailElementOrder",
        "mediaDetailHiddenElements",
        "mediaDetailSimilarTitlesEnabled",
        "mediaDetailTitleArtworkEnabled",
        "mediaDetailAlternatePosterEnabled",
        "homeCatalogLayoutOverrides",
        "appearancePalette",
        "appearanceBleedStrength",
        "appearanceBackgroundIntensity",
        "appearanceMotion",
        "atmosphereStyle",
        "homeAnimatedBackgroundEnabled",
        "homeAnimatedBackgroundQuality",
        "homeAnimatedBackgroundFrameRate",
        "mpvPlayerSkinTintControlsOnly",
        "experimentalMediaDesignPreset",
        "experimentalHomeCardShape",
        "experimentalHeroHeightScale",
        "experimentalSectionSpacingScale",
        "experimentalCardRadiusScale",
        "experimentalMediaCardScale",
        "heroBannerCatalogId",
        "heroBannerBehavior",
        "subtitles_fontSize",
        "subtitles_strokeWidth",
        "subtitles_foregroundColor",
        "subtitles_strokeColor",
        "subtitles_closedCaptionBackground",
        "playerSubtitleOverlayBottomConstant",
        "performanceModeEnabled",
        "performanceModeSkipAniListTraversalForAnimeDetails",
        "performanceModeFastAnimeCatalogOverrides",
        "tvCardDensity",
        "playbackEngine",
        "playerDoubleTapSeekSeconds",

        "localNotificationSubscriptions",
        "localNotificationEpisodeReminders",
        "localNotificationEpisodeLeadTime",
        "localNotificationSeasonLeadTime",
        "localNotificationIncludeAnimeSpecials",

        "atmosphereSolidColorSource",
        "atmosphereSolidColor",
        "appearanceCustomColors",
        "accentColor",
        "eclipseThemeGradientColor",
        "selectedAppearance",

        "defaultScheduleMode",
        "scheduleWindowDays",
        "showLocalScheduleTime",
        "libraryShowBookmarksSection",
        "showUnairedEpisodes",
        "mediaDetailAgeRatingEnabled",
        "browseFilterPreferences",
        "selectedSimilarityAlgorithm",
        "highQualityThreshold",

        "mpvPlayerSkin",
        "mpvPlayerSkinCustomPrimaryColor",
        "mpvPlayerSkinCustomSecondaryColor",
        "mpvPlayerSkinAnimationsEnabled",
        "mpvPlayerSkinAnimationStyle.default",
        "mpvPlayerSkinAnimationStyle.blackAndGold",
        "mpvPlayerSkinAnimationStyle.prismatic",
        "mpvPlayerSkinAnimationStyle.cyberpunk",
        "mpvPlayerSkinAnimationStyle.custom",

        "playerDoubleTapSeekEnabled",
        "playerBrightnessGestureEnabled",
        "playerVolumeGestureEnabled",
        "playerTwoFingerTapPlayPauseEnabled",
        "playerCenterTapPlayPauseEnabled",
        "playerPlaybackLockEnabled",
        "holdSpeedPlayer",
        "aniSkipEnabled",
        "skip85sEnabled",
        "skip85sAlwaysVisible",
        "showEpisodeBrowserButton",
        "showNextEpisodePosterButton",
        "nextEpisodeSkipFillerEnabled",
        "mpvAppExitPictureInPictureEnabled",
        "preferDownloadedMedia",

        "modeSwitchAnimationEnabled",

        "readerGlobalAppearanceEnabled",
        "readerAppearancePalette",
        "readerAppearanceBleedStrength",
        "readerAppearanceBackgroundIntensity",
        "readerAppearanceMotion",
        "readerAppearanceCustomColors",
        "readerAtmosphereStyle",
        "readerAtmosphereSolidColorSource",
        "readerAtmosphereSolidColor",
        "readerThemeGradientColor",
        "readerAccentColor",
        "readerSelectedAppearance",

        "readerFontSize",
        "readerFontFamily",
        "readerFontWeight",
        "readerColorPreset",
        "readerTextAlignment",
        "readerLineSpacing",
        "readerMargin",

        "readerDetailElementOrder",
        "readerDetailHiddenElements",
        "readerReadThresholdPercent",
        "kanzenReaderMode",

        "Reader.downsampleImages",
        "Reader.cropBorders",
        "Reader.disableQuickActions",
        "Reader.disableDoubleTap",
        "Reader.liveText",
        "Reader.hideBarsOnSwipe",
        "Reader.backgroundColor",
        "Reader.tapZones",
        "Reader.invertTapZones",
        "Reader.animatePageTransitions",
        "Reader.pagesToPreload",
        "Reader.splitWideImages",
        "Reader.reverseSplitOrder",
        "Reader.verticalInfiniteScroll"
    ]

    static func explicitScope(for key: String) -> EclipseSettingScope? {
        if deviceKeys.contains(key) { return .device }
        if devicePrefixes.contains(where: key.hasPrefix) { return .device }
        if servicesKeys.contains(key) { return .services }
        if servicesPrefixes.contains(where: key.hasPrefix) { return .services }
        if profileKeys.contains(key) { return .profile }
        return nil
    }

    static func scope(for key: String) -> EclipseSettingScope {
        explicitScope(for: key) ?? .profile
    }

    static func settingsSyncStore(for key: String) -> UserDefaults {
        switch scope(for: key) {
        case .profile:
            return ProfileSettingsStore.active
        case .services, .device:
            return ProfileSettingsStore.device
        }
    }
}

extension ProfileSettingsStore {

    static func store(for key: String) -> UserDefaults {
        switch EclipseSettingsRegistry.scope(for: key) {
        case .profile: return active
        case .services: return services
        case .device: return device
        }
    }
}
