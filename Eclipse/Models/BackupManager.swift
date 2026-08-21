//
//  BackupManager.swift
//  Eclipse
//
//  Created by Soupy-dev on 05/01/2026.
//

import CoreData
import Darwin
import Foundation
import UIKit
#if canImport(CryptoKit)
import CryptoKit

private extension KeyedDecodingContainer {
    /// `contains` also returns true for explicit `null`. Restore authority must
    /// require a payload that actually decoded, while still accepting an
    /// explicit empty collection as authoritative.
    func decodePresence<Value: Decodable>(
        of type: Value.Type,
        forKey key: Key
    ) -> Bool {
        (try? decodeIfPresent(type, forKey: key)) != nil
    }
}

private func decodeBackupJSONValue<Value: Decodable>(
    _ type: Value.Type,
    from value: Any?,
    using decoder: JSONDecoder
) -> Value? {
    guard let value,
          !(value is NSNull),
          JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value) else {
        return nil
    }
    return try? decoder.decode(type, from: data)
}
#endif

struct BackupProfileSnapshot: Codable {
    var id: UUID
    var name: String
    var avatarSymbol: String
    var avatarColorHex: String
    var avatarPhotoData: Data?
    var isKidsProfile: Bool
    var createdAt: Date

    var pinHash: String? = nil

    var pinChangedAt: Date? = nil
    var kidsFlagChangedAt: Date? = nil

    var collections: [BackupCollection] = []
    var progressData: ProgressData = ProgressData()
    var trackerState: TrackerState = TrackerState()
    var catalogs: [Catalog] = []
    var userRatings: [String: Double] = [:]
    var userRatingNotes: [String: String] = [:]
    var searchHistory: BackupSearchHistory = BackupSearchHistory()

    var progressWasCaptured: Bool = true
    var ratingsWereCaptured: Bool = true
    var collectionsWereCaptured: Bool = true
    var catalogsWereCaptured: Bool = true
    var trackerStateWasCaptured: Bool = true
    var trackerCredentialsAndRosterWereCaptured: Bool = false

    var mangaCollectionsWereCaptured: Bool = true
    var mangaReadingProgressWasCaptured: Bool = true
    var mangaCatalogsWereCaptured: Bool = true
    var customCatalogsWereCaptured: Bool = true

    var mangaCollections: [BackupMangaCollection] = []
    var mangaReadingProgress: [String: MangaProgress] = [:]
    var mangaCatalogs: [MangaCatalog] = []
    var customCatalogs: [KanzenCustomCatalog] = []

    var settings: [String: Data] = [:]

    var services: [BackupService]? = nil
    var stremioAddons: [BackupStremioAddon]? = nil
    var skyStream: SkyStreamBackupSnapshot? = nil
    var nuvioPlugins: NuvioStoredPluginsState? = nil

    var readerExtensionsState: BackupReaderExtensionState? = nil
    var readerPrivateCloudConfigurationData: Data? = nil

    // Decode-only compatibility for backups written before Reader Extensions.
    var aidokuState: BackupAidokuState? = nil

    var skyStreamStateData: Data? = nil

    var servicesSettings: [String: Data] = [:]
    var servicesSettingsWereCaptured: Bool = false
}

extension BackupProfileSnapshot {
    enum CodingKeys: String, CodingKey {
        case id, name, avatarSymbol, avatarColorHex, avatarPhotoData, isKidsProfile, createdAt, pinHash
        case pinChangedAt, kidsFlagChangedAt
        case collections, progressData, trackerState, catalogs, userRatings, userRatingNotes, searchHistory
        case progressWasCaptured, ratingsWereCaptured, collectionsWereCaptured, catalogsWereCaptured
        case trackerStateWasCaptured, trackerCredentialsAndRosterWereCaptured
        case mangaCollectionsWereCaptured, mangaReadingProgressWasCaptured, mangaCatalogsWereCaptured
        case customCatalogsWereCaptured
        case mangaCollections, mangaReadingProgress, mangaCatalogs
        case customCatalogs
        case settings
        case services, stremioAddons, skyStream, nuvioPlugins
        case readerExtensionsState, readerPrivateCloudConfigurationData
        case aidokuState, skyStreamStateData, servicesSettings
        case servicesSettingsWereCaptured
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),

            avatarSymbol: try container.decodeIfPresent(String.self, forKey: .avatarSymbol)
                ?? ProfileAvatar.defaultSymbol,
            avatarColorHex: try container.decodeIfPresent(String.self, forKey: .avatarColorHex)
                ?? ProfileAvatar.defaultColorHex,
            avatarPhotoData: try container.decodeIfPresent(Data.self, forKey: .avatarPhotoData),
            isKidsProfile: try container.decodeIfPresent(Bool.self, forKey: .isKidsProfile) ?? false,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0),
            pinHash: try container.decodeIfPresent(String.self, forKey: .pinHash),
            pinChangedAt: try container.decodeIfPresent(Date.self, forKey: .pinChangedAt),
            kidsFlagChangedAt: try container.decodeIfPresent(Date.self, forKey: .kidsFlagChangedAt)
        )
        let decodedCollections = try container.decodeIfPresent(
            [BackupCollection].self,
            forKey: .collections
        )
        let decodedProgress = try container.decodeIfPresent(
            ProgressData.self,
            forKey: .progressData
        )
        let decodedTrackerState = try container.decodeIfPresent(
            TrackerState.self,
            forKey: .trackerState
        )
        let decodedCatalogs = try container.decodeIfPresent(
            [Catalog].self,
            forKey: .catalogs
        )
        let decodedRatings = try container.decodeIfPresent(
            [String: Double].self,
            forKey: .userRatings
        )
        let decodedRatingNotes = try container.decodeIfPresent(
            [String: String].self,
            forKey: .userRatingNotes
        )

        collections = BackupData.sanitizedCollections(decodedCollections ?? [])
        progressData = BackupData.sanitizedProgressData(decodedProgress ?? ProgressData())
        trackerState = decodedTrackerState ?? TrackerState()
        catalogs = decodedCatalogs ?? []
        userRatings = BackupData.sanitizedUserRatings(decodedRatings ?? [:])
        userRatingNotes = BackupData.sanitizedUserRatingNotes(decodedRatingNotes ?? [:])
        searchHistory = try container.decodeIfPresent(BackupSearchHistory.self, forKey: .searchHistory)
            ?? BackupSearchHistory()
        let decodedMangaCollections = try container.decodeIfPresent(
            [BackupMangaCollection].self,
            forKey: .mangaCollections
        )
        let decodedMangaReadingProgress = try container.decodeIfPresent(
            [String: MangaProgress].self,
            forKey: .mangaReadingProgress
        )
        let decodedMangaCatalogs = try container.decodeIfPresent(
            [MangaCatalog].self,
            forKey: .mangaCatalogs
        )
        let decodedCustomCatalogs = try container.decodeIfPresent(
            [KanzenCustomCatalog].self,
            forKey: .customCatalogs
        )

        // A capture flag cannot turn an omitted (or explicit null) payload into
        // authoritative empty state. Older profile snapshots did not write the
        // flags, so a present payload remains the backwards-compatible signal
        // that the domain was captured. Ratings and notes are restored as one
        // transaction and therefore require both halves of the pair.
        progressWasCaptured = Self.domainWasCaptured(
            explicitFlag: try container.decodeIfPresent(Bool.self, forKey: .progressWasCaptured),
            flagIsPresent: container.contains(.progressWasCaptured),
            payloadIsPresent: decodedProgress != nil
        )
        ratingsWereCaptured = Self.domainWasCaptured(
            explicitFlag: try container.decodeIfPresent(Bool.self, forKey: .ratingsWereCaptured),
            flagIsPresent: container.contains(.ratingsWereCaptured),
            payloadIsPresent: decodedRatings != nil && decodedRatingNotes != nil
        )
        collectionsWereCaptured = Self.domainWasCaptured(
            explicitFlag: try container.decodeIfPresent(Bool.self, forKey: .collectionsWereCaptured),
            flagIsPresent: container.contains(.collectionsWereCaptured),
            payloadIsPresent: decodedCollections != nil
        )
        catalogsWereCaptured = Self.domainWasCaptured(
            explicitFlag: try container.decodeIfPresent(Bool.self, forKey: .catalogsWereCaptured),
            flagIsPresent: container.contains(.catalogsWereCaptured),
            payloadIsPresent: decodedCatalogs != nil
        )
        trackerStateWasCaptured = Self.domainWasCaptured(
            explicitFlag: try container.decodeIfPresent(Bool.self, forKey: .trackerStateWasCaptured),
            flagIsPresent: container.contains(.trackerStateWasCaptured),
            payloadIsPresent: decodedTrackerState != nil
        )
        let decodedTrackerCredentialsAndRosterWereCaptured = try container.decodeIfPresent(
            Bool.self,
            forKey: .trackerCredentialsAndRosterWereCaptured
        ) ?? false
        trackerCredentialsAndRosterWereCaptured = trackerStateWasCaptured
            && decodedTrackerCredentialsAndRosterWereCaptured
        mangaCollectionsWereCaptured = Self.domainWasCaptured(
            explicitFlag: try container.decodeIfPresent(Bool.self, forKey: .mangaCollectionsWereCaptured),
            flagIsPresent: container.contains(.mangaCollectionsWereCaptured),
            payloadIsPresent: decodedMangaCollections != nil
        )
        mangaReadingProgressWasCaptured = Self.domainWasCaptured(
            explicitFlag: try container.decodeIfPresent(Bool.self, forKey: .mangaReadingProgressWasCaptured),
            flagIsPresent: container.contains(.mangaReadingProgressWasCaptured),
            payloadIsPresent: decodedMangaReadingProgress != nil
        )
        mangaCatalogsWereCaptured = Self.domainWasCaptured(
            explicitFlag: try container.decodeIfPresent(Bool.self, forKey: .mangaCatalogsWereCaptured),
            flagIsPresent: container.contains(.mangaCatalogsWereCaptured),
            payloadIsPresent: decodedMangaCatalogs != nil
        )
        customCatalogsWereCaptured = Self.domainWasCaptured(
            explicitFlag: try container.decodeIfPresent(Bool.self, forKey: .customCatalogsWereCaptured),
            flagIsPresent: container.contains(.customCatalogsWereCaptured),
            payloadIsPresent: decodedCustomCatalogs != nil
        )
        mangaCollections = decodedMangaCollections ?? []
        mangaReadingProgress = decodedMangaReadingProgress ?? [:]
        mangaCatalogs = decodedMangaCatalogs ?? []
        customCatalogs = decodedCustomCatalogs ?? []
        settings = try container.decodeIfPresent([String: Data].self, forKey: .settings) ?? [:]
        services = try container.decodeIfPresent([BackupService].self, forKey: .services)
        stremioAddons = try container.decodeIfPresent([BackupStremioAddon].self, forKey: .stremioAddons)
        skyStream = try container.decodeIfPresent(SkyStreamBackupSnapshot.self, forKey: .skyStream)
        nuvioPlugins = try container.decodeIfPresent(NuvioStoredPluginsState.self, forKey: .nuvioPlugins)
        aidokuState = try container.decodeIfPresent(BackupAidokuState.self, forKey: .aidokuState)
            .map(BackupData.aidokuStateWithoutExecutablePayloads)
        readerExtensionsState = try container.decodeIfPresent(
            BackupReaderExtensionState.self,
            forKey: .readerExtensionsState
        ) ?? aidokuState.map(BackupReaderExtensionState.migratingLegacyAidoku)
        readerPrivateCloudConfigurationData = Self.boundedReaderPrivateCloudConfigurationData(
            try? container.decodeIfPresent(
                Data.self,
                forKey: .readerPrivateCloudConfigurationData
            )
        )
        skyStreamStateData = try container.decodeIfPresent(Data.self, forKey: .skyStreamStateData)
        let decodedServicesSettings = try container.decodeIfPresent(
            [String: Data].self,
            forKey: .servicesSettings
        ) ?? [:]
        let safeServicesSettings = BackupData.servicesSettingsForExperimentalCloudSync(
            decodedServicesSettings
        )
        servicesSettings = safeServicesSettings ?? [:]
        servicesSettingsWereCaptured = (
            try container.decodeIfPresent(Bool.self, forKey: .servicesSettingsWereCaptured)
                ?? false
        ) && safeServicesSettings != nil
    }

    private static func domainWasCaptured(
        explicitFlag: Bool?,
        flagIsPresent: Bool,
        payloadIsPresent: Bool
    ) -> Bool {
        payloadIsPresent && (!flagIsPresent || explicitFlag == true)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(avatarSymbol, forKey: .avatarSymbol)
        try container.encode(avatarColorHex, forKey: .avatarColorHex)
        try container.encodeIfPresent(avatarPhotoData, forKey: .avatarPhotoData)
        try container.encode(isKidsProfile, forKey: .isKidsProfile)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(pinHash, forKey: .pinHash)
        try container.encodeIfPresent(pinChangedAt, forKey: .pinChangedAt)
        try container.encodeIfPresent(kidsFlagChangedAt, forKey: .kidsFlagChangedAt)
        try container.encode(BackupData.sanitizedCollections(collections), forKey: .collections)
        try container.encode(BackupData.sanitizedProgressData(progressData), forKey: .progressData)
        try container.encode(trackerState, forKey: .trackerState)
        try container.encode(catalogs, forKey: .catalogs)
        try container.encode(BackupData.sanitizedUserRatings(userRatings), forKey: .userRatings)
        try container.encode(BackupData.sanitizedUserRatingNotes(userRatingNotes), forKey: .userRatingNotes)
        try container.encode(searchHistory, forKey: .searchHistory)
        try container.encode(progressWasCaptured, forKey: .progressWasCaptured)
        try container.encode(ratingsWereCaptured, forKey: .ratingsWereCaptured)
        try container.encode(collectionsWereCaptured, forKey: .collectionsWereCaptured)
        try container.encode(catalogsWereCaptured, forKey: .catalogsWereCaptured)
        try container.encode(trackerStateWasCaptured, forKey: .trackerStateWasCaptured)
        try container.encode(
            trackerStateWasCaptured && trackerCredentialsAndRosterWereCaptured,
            forKey: .trackerCredentialsAndRosterWereCaptured
        )
        try container.encode(mangaCollectionsWereCaptured, forKey: .mangaCollectionsWereCaptured)
        try container.encode(mangaReadingProgressWasCaptured, forKey: .mangaReadingProgressWasCaptured)
        try container.encode(mangaCatalogsWereCaptured, forKey: .mangaCatalogsWereCaptured)
        try container.encode(customCatalogsWereCaptured, forKey: .customCatalogsWereCaptured)
        try container.encode(mangaCollections, forKey: .mangaCollections)
        try container.encode(mangaReadingProgress, forKey: .mangaReadingProgress)
        try container.encode(mangaCatalogs, forKey: .mangaCatalogs)
        try container.encode(customCatalogs, forKey: .customCatalogs)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(services, forKey: .services)
        try container.encodeIfPresent(stremioAddons, forKey: .stremioAddons)
        try container.encodeIfPresent(skyStream, forKey: .skyStream)
        try container.encodeIfPresent(nuvioPlugins, forKey: .nuvioPlugins)
        try container.encodeIfPresent(readerExtensionsState?.sanitized(), forKey: .readerExtensionsState)
        try container.encodeIfPresent(
            Self.boundedReaderPrivateCloudConfigurationData(
                readerPrivateCloudConfigurationData
            ),
            forKey: .readerPrivateCloudConfigurationData
        )
        try container.encodeIfPresent(skyStreamStateData, forKey: .skyStreamStateData)
        let safeServicesSettings = BackupData.servicesSettingsForExperimentalCloudSync(
            servicesSettings
        )
        try container.encode(safeServicesSettings ?? [:], forKey: .servicesSettings)
        try container.encode(
            servicesSettingsWereCaptured && safeServicesSettings != nil,
            forKey: .servicesSettingsWereCaptured
        )
    }

    static let maximumReaderPrivateCloudConfigurationBytes = 8 * 1_024 * 1_024

    static func boundedReaderPrivateCloudConfigurationData(_ data: Data?) -> Data? {
        guard let data,
              !data.isEmpty,
              data.count <= maximumReaderPrivateCloudConfigurationBytes else {
            return nil
        }
        return data
    }
}

struct BackupData: Codable {
    static let currentCloudSchemaVersion = "2.0"

    let version: String
    let createdDate: Date

    var servicesSettings: [String: Data]? = nil
    var servicesSettingsWereCaptured: Bool = false

    var sharesServices: Bool? = nil

    var profiles: [BackupProfileSnapshot]? = nil

    var skyStreamSharedPayloads: [BackupSkyStreamSharedPayload]? = nil
    var nuvioSharedPayloads: [BackupNuvioSharedPayload]? = nil

    var activeProfileID: UUID? = nil

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

    var localNotificationSubscriptions: String?
    var localNotificationEpisodeReminders: String?
    var localNotificationEpisodeLeadTime: Int?
    var localNotificationSeasonLeadTime: Int?
    var localNotificationIncludeAnimeSpecials: Bool?

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
    var mpvNeuralUpscaler: String = MPVNeuralUpscaler.defaultUpscaler.rawValue
    var mpvNeuralUpscalerTV: String = MPVNeuralUpscaler.defaultUpscaler.rawValue
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
    var experimentalFeaturesEnabled: Bool?
    var experimentalFeaturesLastChangedAt: Double?
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

    var subtitleForegroundColor: Data?
    var subtitleStrokeColor: Data?
    var subtitleStrokeWidth: Double = 1.0
    var subtitleFontSize: Double = 30.0
    var subtitleVerticalOffset: Double = -6.0
    var subtitlesVisible: Bool = false

    var showKanzen: Bool = false
    var hideSplashScreen: Bool?
    var modeSwitchAnimationEnabled: Bool = ModeSwitchAnimationSettings.defaultEnabled
    var kanzenAutoUpdateModules: Bool = true
    var seasonMenu: Bool = false
    var horizontalEpisodeList: Bool = false
    var mediaDetailTitleArtworkEnabled: Bool = MediaDetailTitleArtworkSettings.defaultEnabled
    var mediaDetailAlternatePosterEnabled: Bool = MediaDetailAlternatePosterSettings.defaultEnabled
    var mediaDetailSimilarTitlesEnabled: Bool = MediaDetailSimilarTitlesSettings.defaultEnabled
    var useClassicScheduleUI: Bool = false
    var heroBannerCatalogId: String = "trending"
    var heroBannerBehavior: String = HeroBannerBehavior.defaultValue.rawValue

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

    var readerFontSize: Double = 16
    var readerFontFamily: String = "-apple-system"
    var readerFontWeight: String = "normal"
    var readerColorPreset: Int = 0
    var readerTextAlignment: String = "left"
    var readerLineSpacing: Double = 1.6
    var readerMargin: Double = 4

    var autoClearCacheEnabled: Bool = false
    var autoClearCacheThresholdMB: Double = 500
    var highQualityThreshold: Double = 0.9
    var backgroundHLSPipelineEnabled: Bool = false
    var readerDownloadsBackgroundEnabled: Bool = true
    var readerDownloadsWifiOnly: Bool = false
    var readerDownloadsParallelLimit: Int = 2
    var autoUpdateServicesEnabled: Bool = true
    var servicesAutoModeEnabled: Bool = AutoModeSettings.defaultEnabled
    var servicesAutoSelectEpisodesEnabled: Bool = false
    var servicesAutoModeErrorIntelligenceEnabled: Bool = AutoModeErrorIntelligenceSettings.defaultEnabled
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

    var kanzenHomeSelectedSourceID: String = ""
    var kanzenRecentSourceSearches: [String] = []

    var collections: [BackupCollection] = []

    var progressData: ProgressData = ProgressData()

    var trackerState: TrackerState = TrackerState()

    var catalogs: [Catalog] = []

    var services: [BackupService] = []

    var stremioAddons: [BackupStremioAddon]? = nil

    var skyStream: SkyStreamBackupSnapshot? = nil

    var nuvioPlugins: NuvioStoredPluginsState? = nil

    var mangaCollections: [BackupMangaCollection] = []
    var mangaReadingProgress: [String: MangaProgress] = [:]
    var mangaCatalogs: [MangaCatalog] = []
    var customCatalogs: [KanzenCustomCatalog] = []
    var kanzenModules: [BackupKanzenModule] = []
    var readerExtensionsState: BackupReaderExtensionState?

    // Decode-only compatibility. New backups never encode Aidoku metadata or payloads.
    var aidokuState: BackupAidokuState?

    var searchHistory: BackupSearchHistory = BackupSearchHistory()
    var recommendationCache: [TMDBSearchResult] = []

    var userRatings: [String: Double] = [:]
    var userRatingNotes: [String: String] = [:]

    var mediaStateSettings: [String: Data]? = nil

    private(set) var hasMangaCollections = true
    private(set) var hasMangaReadingProgress = true
    private(set) var hasMangaCatalogs = true
    private(set) var hasCustomCatalogs = true
    private(set) var hasKanzenModules = true
    private(set) var hasUserRatings = true
    private(set) var hasCollections = true
    private(set) var hasProgressData = true
    private(set) var hasTrackerState = true
    private(set) var hasCatalogs = true
    private(set) var hasServices = true

    // Top-level scalar settings predate profile snapshots and are still read
    // for legacy backups. Keep per-key decode authority so a syntactically
    // valid but incomplete backup cannot turn omitted/null settings into the
    // decoder defaults and overwrite the destination with them.
    fileprivate(set) var decodedTopLevelSettingKeys: Set<String> = []
    fileprivate(set) var allTopLevelSettingsWereCaptured = true

    func redactedForExperimentalCloudSync(
        stripSkyStreamArchives: Bool = false
    ) -> BackupData {
        var snapshot = self

        snapshot.progressData.movieProgress = progressData.movieProgress.map { entry in
            var redacted = entry
            redacted.lastHref = nil
            redacted.lastContentReference = nil
            return redacted
        }
        snapshot.progressData.episodeProgress = progressData.episodeProgress.map { entry in
            var redacted = entry
            redacted.lastHref = nil
            redacted.lastContentReference = nil
            return redacted
        }

        let safeServices = Self.servicesForExperimentalCloudSync(services)
        let safeStremioAddons = stremioAddons.flatMap(
            Self.stremioAddonsForExperimentalCloudSync
        )
        if let safeServices, let safeStremioAddons {
            snapshot.services = safeServices
            snapshot.stremioAddons = safeStremioAddons
        } else {
            snapshot.services = []
            snapshot.hasServices = false
            snapshot.stremioAddons = nil
        }
        snapshot.skyStream = skyStream.flatMap {
            Self.skyStreamSnapshotForExperimentalCloudSync(
                $0,
                stripArchives: stripSkyStreamArchives
            )
        }

        snapshot.nuvioPlugins = nuvioPlugins.flatMap(Self.nuvioStateForExperimentalCloudSync)

        snapshot.profiles = profiles?.map { profileSnapshot in
            var redacted = profileSnapshot

            let safeServices = profileSnapshot.services.flatMap(
                Self.servicesForExperimentalCloudSync
            )
            let safeAddons = profileSnapshot.stremioAddons.flatMap(
                Self.stremioAddonsForExperimentalCloudSync
            )
            if let safeServices, let safeAddons {
                redacted.services = safeServices
                redacted.stremioAddons = safeAddons
            } else {
                redacted.services = nil
                redacted.stremioAddons = nil
            }
            redacted.nuvioPlugins = profileSnapshot.nuvioPlugins.flatMap(
                Self.nuvioStateForExperimentalCloudSync
            )
            redacted.readerExtensionsState = profileSnapshot.readerExtensionsState?.sanitized()
            redacted.aidokuState = nil
            redacted.skyStream = profileSnapshot.skyStream.flatMap {
                Self.skyStreamSnapshotForExperimentalCloudSync($0, stripArchives: true)
            }
            redacted.skyStreamStateData = nil
            redacted.progressData.movieProgress = profileSnapshot.progressData.movieProgress.map { entry in
                var entryCopy = entry
                entryCopy.lastHref = nil
                entryCopy.lastContentReference = nil
                return entryCopy
            }
            redacted.progressData.episodeProgress = profileSnapshot.progressData.episodeProgress.map { entry in
                var entryCopy = entry
                entryCopy.lastHref = nil
                entryCopy.lastContentReference = nil
                return entryCopy
            }
            return redacted
        }

        let safeKanzenModules = kanzenModules.filter {
            Self.cloudSafeManifestURL($0.moduleurl) != nil
        }
        snapshot.kanzenModules = safeKanzenModules
        snapshot.hasKanzenModules = hasKanzenModules
            && safeKanzenModules.count == kanzenModules.count

        snapshot.readerExtensionsState = readerExtensionsState?.sanitized()
        snapshot.aidokuState = nil

        snapshot.servicesSettings = Self.servicesSettingsForExperimentalCloudSync(servicesSettings)
        snapshot.servicesSettingsWereCaptured = servicesSettingsWereCaptured
            && snapshot.servicesSettings != nil
        snapshot.profiles = snapshot.profiles?.map { profileSnapshot in
            var redacted = profileSnapshot
            let settings = Self.servicesSettingsForExperimentalCloudSync(
                profileSnapshot.servicesSettings
            )
            redacted.servicesSettings = settings ?? [:]
            redacted.servicesSettingsWereCaptured = profileSnapshot.servicesSettingsWereCaptured
                && settings != nil
            return redacted
        }

        snapshot.skyStreamSharedPayloads = nil
        snapshot.nuvioSharedPayloads = nil
        snapshot.readerUpscaleModelName = "None"
        snapshot.experimentalICloudSyncEnabled = false

        snapshot.recommendationCache = []
        return snapshot
    }

    var privateCloudConfigurationWasCapturedCompletely: Bool {
        guard let sharesServices,
              let profiles,
              !profiles.isEmpty,
              let activeProfileID,
              profiles.contains(where: { $0.id == activeProfileID }),
              hasServices,
              stremioAddons != nil,
              servicesSettingsWereCaptured else {
            return false
        }

#if !os(tvOS)
        if PlatformCapabilities.current.supportsReader {
            guard Self.readerExtensionStateWasCapturedCompletely(readerExtensionsState) else {
                return false
            }
        }
#endif

        if PlatformCapabilities.current.supportsSkyStreamPlugins {
            guard let skyStream,
                  SkyStreamPrivateCloudConfigurationPolicy
                    .snapshotHasCompleteConfiguration(skyStream) else {
                return false
            }
        }
        if PlatformCapabilities.current.supportsNuvioPlugins,
           nuvioPlugins == nil {
            return false
        }

        for profile in profiles {
            guard profile.trackerStateWasCaptured,
                  profile.trackerCredentialsAndRosterWereCaptured else {
                return false
            }
#if !os(tvOS)
            if PlatformCapabilities.current.supportsReader {
                guard Self.readerExtensionStateWasCapturedCompletely(
                    profile.readerExtensionsState
                ),
                Self.readerPrivateCloudConfigurationWasCapturedCompletely(
                    profile.readerPrivateCloudConfigurationData,
                    profileID: profile.id
                ) else {
                    return false
                }
            }
#endif
            if !sharesServices {
                guard profile.services != nil,
                      profile.stremioAddons != nil,
                      profile.servicesSettingsWereCaptured else {
                    return false
                }
                if PlatformCapabilities.current.supportsSkyStreamPlugins {
                    guard let skyStream = profile.skyStream,
                          SkyStreamPrivateCloudConfigurationPolicy
                            .snapshotHasCompleteConfiguration(skyStream) else {
                        return false
                    }
                }
                if PlatformCapabilities.current.supportsNuvioPlugins,
                   profile.nuvioPlugins == nil {
                    return false
                }
            }
        }
        return true
    }

#if !os(tvOS)
    private static func readerExtensionStateWasCapturedCompletely(
        _ state: BackupReaderExtensionState?
    ) -> Bool {
        guard let state else { return false }
        return (try? state.runtimeSnapshot()) != nil
    }

    private static func readerPrivateCloudConfigurationWasCapturedCompletely(
        _ data: Data?,
        profileID: UUID
    ) -> Bool {
        guard let data = BackupProfileSnapshot
            .boundedReaderPrivateCloudConfigurationData(data),
              let configuration = try? JSONDecoder().decode(
                ReaderExtensionPrivateCloudConfiguration.self,
                from: data
              ),
              configuration.profileID == profileID,
              (try? ReaderExtensionPrivateCloudConfigurationPolicy.validate(
                configuration
              )) != nil else {
            return false
        }
        return true
    }

    mutating func removeReaderDomainsWithoutCompletePrivateCloudAuthority() {
        guard PlatformCapabilities.current.supportsReader else { return }

        let originalProfiles = profiles
        let activeProfileHasCompleteReaderAuthority = activeProfileID.flatMap { activeID in
            originalProfiles?.first(where: { $0.id == activeID })
        }.map { profile in
            Self.readerExtensionStateWasCapturedCompletely(profile.readerExtensionsState)
                && Self.readerPrivateCloudConfigurationWasCapturedCompletely(
                    profile.readerPrivateCloudConfigurationData,
                    profileID: profile.id
                )
        } == true

        profiles = originalProfiles?.map { profile in
            guard Self.readerExtensionStateWasCapturedCompletely(profile.readerExtensionsState),
                  Self.readerPrivateCloudConfigurationWasCapturedCompletely(
                    profile.readerPrivateCloudConfigurationData,
                    profileID: profile.id
                  ) else {
                var preserved = profile
                preserved.readerExtensionsState = nil
                preserved.readerPrivateCloudConfigurationData = nil
                preserved.aidokuState = nil
                return preserved
            }
            return profile
        }

        guard Self.readerExtensionStateWasCapturedCompletely(readerExtensionsState),
              activeProfileHasCompleteReaderAuthority else {
            readerExtensionsState = nil
            aidokuState = nil
            return
        }
    }
#endif

    fileprivate static let cloudUnsafeServicesSettingsKeys: Set<String> = [
        "nuvioPluginsState.v1",
        "nuvioPluginsState.v2",
        "nuvioMissingCodeRepairCursor.v1",
        "skyStreamPendingSafeCloudSnapshot.v1",
        "lastServiceAutoUpdateTimestamp",
        "kanzenLastModuleAutoUpdate",
        "kanzenAidokuInstalledSources",
        "kanzenAidokuSourceLists",
        "readerExtensions.repositories.v1",
        "readerExtensions.installedSources.v1",
        "readerExtensions.approvedDomains.v1"
    ]

    fileprivate static func isTypedOrLegacyReaderSourceSetting(_ key: String) -> Bool {
        key.hasPrefix("kanzenAidoku") || key.hasPrefix("readerExtensions.")
    }

    fileprivate static func servicesSettingsForExperimentalCloudSync(
        _ settings: [String: Data]?
    ) -> [String: Data]? {
        guard let settings else { return nil }
        guard settings.count <= BackupManager.maximumProfileSettingKeys else { return nil }
        var safe: [String: Data] = [:]
        for (key, data) in settings {
            if cloudUnsafeServicesSettingsKeys.contains(key)
                || isTypedOrLegacyReaderSourceSetting(key) {
                continue
            }
            guard key.utf8.count <= 512,
                  EclipseSettingsRegistry.scope(for: key) == .services,
                  data.count <= BackupManager.maximumProfileSettingValueBytes,
                  BackupManager.validatedBackupSettingValue(
                    from: data,
                    forKey: key
                  ) != nil else {
                return nil
            }
            safe[key] = data
        }
        return safe
    }

    static func servicesForExperimentalCloudSync(
        _ services: [BackupService]
    ) -> [BackupService]? {
        guard services.count <= MediaStateServiceSourcesPayload.maximumServices,
              Set(services.map(\.id)).count == services.count else {
            return nil
        }
        let safe = services.compactMap(serviceForExperimentalCloudSync)
        return safe.count == services.count ? safe : nil
    }

    static func stremioAddonsForExperimentalCloudSync(
        _ addons: [BackupStremioAddon]
    ) -> [BackupStremioAddon]? {
        guard addons.count <= MediaStateServiceSourcesPayload.maximumStremioAddons,
              Set(addons.map(\.id)).count == addons.count else {
            return nil
        }
        let safe = addons.compactMap(stremioAddonForExperimentalCloudSync)
        return safe.count == addons.count ? safe : nil
    }

    fileprivate static func aidokuStateWithoutExecutablePayloads(
        _ incoming: BackupAidokuState
    ) -> BackupAidokuState {
        var state = incoming
        state.installedSources = incoming.installedSources.map { source in
            BackupAidokuInstalledSource(
                id: source.id,
                name: source.name,
                version: source.version,
                languages: source.languages,
                iconPath: source.iconPath,
                externalIconURL: source.externalIconURL,
                contentRatingRawValue: source.contentRatingRawValue,
                sourceListURL: source.sourceListURL,
                packageURL: source.packageURL,
                isEnabled: source.isEnabled,
                order: source.order,
                lastUpdated: source.lastUpdated,
                lastError: source.lastError,
                packageDigest: source.packageDigest,
                payloadArchiveData: nil
            )
        }
        state.sharedPayloads = nil
        return state
    }

    static func nuvioStateForExperimentalCloudSync(
        _ state: NuvioStoredPluginsState
    ) -> NuvioStoredPluginsState? {
        let bounded = NuvioPluginStore.bounded(state)
        guard !bounded.wasBounded,
              bounded.state.repositories.allSatisfy({
                  PrivateCloudSourceURLPolicy.validatedHTTPURLString($0.manifestUrl) != nil
              }),
              bounded.state.scrapers.allSatisfy({
                  PrivateCloudSourceURLPolicy.validatedHTTPURLString($0.repositoryUrl) != nil
              }) else {
            return nil
        }
        return bounded.state
    }

    static func nuvioMetadataForMediaState(
        persistedValue: Any?
    ) -> Data? {
        let state: NuvioStoredPluginsState
        if let persistedValue {
            guard let persistedData = persistedValue as? Data else { return nil }
            guard NuvioPluginStore.persistedStateDataIsWithinLimit(persistedData),
                  let decoded = try? JSONDecoder().decode(
                    NuvioStoredPluginsState.self,
                    from: persistedData
                  ) else {
                return nil
            }
            state = decoded
        } else {
            state = NuvioStoredPluginsState()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let safeState = nuvioStateForExperimentalCloudSync(state),
              let encoded = try? encoder.encode(safeState), !encoded.isEmpty,
           encoded.count <= MediaStateServiceSourcesPayload.maximumNuvioMetadataBytes else {
            return nil
        }
        return encoded
    }

    static func nuvioRestorePlanForExperimentalCloudSync(
        incoming: NuvioStoredPluginsState,
        current: NuvioStoredPluginsState
    ) -> ExperimentalCloudNuvioRestorePlan {
        guard let safeIncoming = nuvioStateForExperimentalCloudSync(incoming),
              let safeCurrent = nuvioStateForExperimentalCloudSync(current) else {
            return ExperimentalCloudNuvioRestorePlan(
                state: current,
                deviceLocalSourceIDs: Set(
                    current.repositories.map(\.id) + current.scrapers.map(\.id)
                )
            )
        }
        let boundedCurrent = safeCurrent
        let safeCurrentRepositoryIDs = Set(safeCurrent.repositories.map(\.id))

        let deviceLocalRepositories = boundedCurrent.repositories.filter {
            !safeCurrentRepositoryIDs.contains($0.id)
        }
        let deviceLocalRepositoryIDs = Set(deviceLocalRepositories.map(\.id))
        let deviceLocalScrapers = boundedCurrent.scrapers.filter {
            deviceLocalRepositoryIDs.contains($0.repositoryId)
        }

        var merged = safeIncoming
        merged.repositories.append(contentsOf: deviceLocalRepositories.filter { repository in
            !merged.repositories.contains(where: { $0.id == repository.id })
        })
        merged.scrapers.append(contentsOf: deviceLocalScrapers.filter { scraper in
            !merged.scrapers.contains(where: { $0.id == scraper.id })
        })

        let survivingScraperIDs = Set(merged.scrapers.map(\.id))
        let incomingScraperIDs = Set(safeIncoming.scrapers.map(\.id))
        let deviceLocalScraperIDs = Set(deviceLocalScrapers.map(\.id))
        merged.scraperSettings = safeIncoming.scraperSettings.filter {
            incomingScraperIDs.contains($0.key)
        }
        for (scraperID, settings) in boundedCurrent.scraperSettings
        where deviceLocalScraperIDs.contains(scraperID)
            && survivingScraperIDs.contains(scraperID) {
            merged.scraperSettings[scraperID] = settings
        }
        merged = NuvioPluginStore.bounded(merged).state

        let mergedRepositoryIDs = Set(merged.repositories.map(\.id))
        let mergedScraperIDs = Set(merged.scrapers.map(\.id))
        let survivingDeviceLocalRepositoryIDs = deviceLocalRepositoryIDs.intersection(
            mergedRepositoryIDs
        )
        let survivingDeviceLocalScraperIDs = Set(deviceLocalScrapers.map(\.id)).intersection(
            mergedScraperIDs
        )
        return ExperimentalCloudNuvioRestorePlan(
            state: merged,
            deviceLocalSourceIDs: survivingDeviceLocalRepositoryIDs.union(
                survivingDeviceLocalScraperIDs
            )
        )
    }

    private static func cloudSafeManifestURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cloudSafeURLString(value) != nil,
              let components = URLComponents(string: trimmed),
              components.fragment == nil else {
            return nil
        }
        return value
    }

    private static func cloudSafeURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !containsCloudUnsafeSecretInURL(trimmed),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",

              components.user == nil,
              components.password == nil,
              let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,

              (components.percentEncodedQuery ?? "").isEmpty,
              !containsCredentialShapedPathSegment(components.percentEncodedPath) else {
            return nil
        }

        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func containsCredentialShapedPathSegment(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        if lowercased.contains("x-amz-") || lowercased.contains("x-goog-") { return true }
        return path.split(separator: "/").contains { $0.hasPrefix("eyJ") }
    }

    private static func containsCloudUnsafeSecretInURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else {
            return containsCloudUnsafeSecret(value)
        }
        if let user = components.user, containsCloudUnsafeSecret(user) { return true }
        if let password = components.password, !password.isEmpty { return true }
        if let query = components.percentEncodedQuery, containsCloudUnsafeSecret(query) { return true }
        if let fragment = components.percentEncodedFragment,
           containsCloudUnsafeSecret(fragment) { return true }
        return components.percentEncodedPath
            .split(separator: "/")
            .contains { $0.contains("=") && containsCloudUnsafeSecret(String($0)) }
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

    static func serviceForExperimentalCloudSync(_ service: BackupService) -> BackupService? {
        guard service.jsonMetadata.utf8.count <= 128 * 1_024,
              service.jsScript.utf8.count <= 512 * 1_024,
              let safeURL = PrivateCloudSourceURLPolicy.validatedHTTPURLString(
                service.url
              ) else {
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

    static func stremioAddonForExperimentalCloudSync(
        _ addon: BackupStremioAddon
    ) -> BackupStremioAddon? {
        guard addon.manifestJSON.utf8.count <= 256 * 1_024,
              let safeURL = PrivateCloudSourceURLPolicy.validatedHTTPURLString(
                addon.configuredURL
              ) else {
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

    static func skyStreamSnapshotForExperimentalCloudSync(
        _ incoming: SkyStreamBackupSnapshot,
        stripArchives: Bool = false
    ) -> SkyStreamBackupSnapshot? {
        let configurationIsComplete = SkyStreamPrivateCloudConfigurationPolicy
            .snapshotHasCompleteConfiguration(incoming)
        guard incoming.privateCloudConfigurationIsComplete != true
                || configurationIsComplete else {
            return nil
        }
        let validatedURL: (String) -> String? = configurationIsComplete
            ? skyStreamPrivateCloudURLString
            : skyStreamCloudSafeURLString

        func resolvedURL(_ rawValue: String, relativeTo baseURL: URL) -> String? {
            guard let resolved = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }
            return validatedURL(resolved.absoluteString)
        }

        func sanitizedPluginManifest(
            _ incomingManifest: SkyStreamPluginManifest,
            relativeTo baseURL: URL? = nil
        ) -> SkyStreamPluginManifest? {
            func configuredURL(_ rawValue: String) -> String? {
                if let baseURL {
                    return resolvedURL(rawValue, relativeTo: baseURL)
                }
                return validatedURL(rawValue)
            }

            var manifest = incomingManifest
            manifest.additionalFields = [:]
            if !manifest.baseURL.isEmpty {
                guard let baseURL = configuredURL(manifest.baseURL) else { return nil }
                manifest.baseURL = baseURL
            }
            if let iconURL = manifest.iconURL {
                guard let validatedIconURL = configuredURL(iconURL) else { return nil }
                manifest.iconURL = validatedIconURL
            }
            if let domains = manifest.domains {
                var sanitizedDomains: [SkyStreamPluginDomain] = []
                sanitizedDomains.reserveCapacity(domains.count)
                for incomingDomain in domains {
                    guard let domainURL = configuredURL(incomingDomain.url) else { return nil }
                    var domain = incomingDomain
                    domain.url = domainURL
                    domain.additionalFields = [:]
                    sanitizedDomains.append(domain)
                }
                manifest.domains = sanitizedDomains
            }
            if let providers = manifest.providers {
                var sanitizedProviders: [SkyStreamPluginProvider] = []
                sanitizedProviders.reserveCapacity(providers.count)
                for incomingProvider in providers {
                    var provider = incomingProvider
                    if let baseURL = provider.baseURL {
                        guard let validatedBaseURL = configuredURL(baseURL) else { return nil }
                        provider.baseURL = validatedBaseURL
                    }
                    if let iconURL = provider.iconURL {
                        guard let validatedIconURL = configuredURL(iconURL) else { return nil }
                        provider.iconURL = validatedIconURL
                    }
                    provider.additionalFields = [:]
                    sanitizedProviders.append(provider)
                }
                manifest.providers = sanitizedProviders
            }
            return manifest
        }

        var repositories: [SkyStreamRepositoryBackupSnapshot] = []
        repositories.reserveCapacity(incoming.repositories.count)
        for repository in incoming.repositories {
            guard let sourceURL = validatedURL(repository.sourceURL),
                  let baseURL = URL(string: sourceURL) else { return nil }
            var sanitized = repository
            sanitized.sourceURL = sourceURL
            sanitized.additionalFields = [:]
            let rawPluginListURLs = sanitized.pluginListURLs.isEmpty
                ? (sanitized.manifest?.pluginLists ?? [])
                : sanitized.pluginListURLs
            var pluginListURLs: [String] = []
            pluginListURLs.reserveCapacity(rawPluginListURLs.count)
            for rawValue in rawPluginListURLs {
                guard let resolved = resolvedURL(rawValue, relativeTo: baseURL) else { return nil }
                pluginListURLs.append(resolved)
            }
            sanitized.pluginListURLs = pluginListURLs
            sanitized.lastRefreshedAt = nil
            sanitized.frozenAt = nil
            guard !sanitized.pluginListURLs.isEmpty else { return nil }
            if var manifest = sanitized.manifest {
                guard sanitized.kind == .repository,
                      SkyStreamRepositoryManifest.isSupportedManifestVersion(
                          manifest.manifestVersion
                      ) else { return nil }
                for rawValue in manifest.pluginLists {
                    guard resolvedURL(rawValue, relativeTo: baseURL) != nil else { return nil }
                }
                manifest.additionalFields = [:]
                manifest.pluginLists = sanitized.pluginListURLs
                var includedRepositories: [String] = []
                includedRepositories.reserveCapacity(manifest.includedRepositories.count)
                for rawValue in manifest.includedRepositories {
                    guard let resolved = resolvedURL(rawValue, relativeTo: baseURL) else { return nil }
                    includedRepositories.append(resolved)
                }
                manifest.includedRepositories = includedRepositories
                var embeddedPlugins: [SkyStreamPluginListEntry] = []
                embeddedPlugins.reserveCapacity(manifest.plugins.count)
                for incomingEntry in manifest.plugins {
                    guard let archiveURL = resolvedURL(incomingEntry.url, relativeTo: baseURL),
                          let embeddedManifest = sanitizedPluginManifest(
                            incomingEntry.manifest,
                            relativeTo: baseURL
                          ) else { return nil }
                    var entry = incomingEntry
                    entry.url = archiveURL
                    entry.manifest = embeddedManifest
                    entry.additionalFields = [:]
                    embeddedPlugins.append(entry)
                }
                manifest.plugins = embeddedPlugins
                if let iconURL = manifest.iconURL {
                    guard let validatedIconURL = resolvedURL(iconURL, relativeTo: baseURL) else {
                        return nil
                    }
                    manifest.iconURL = validatedIconURL
                }
                if let websiteURL = manifest.websiteURL {
                    guard let validatedWebsiteURL = resolvedURL(
                        websiteURL,
                        relativeTo: baseURL
                    ) else { return nil }
                    manifest.websiteURL = validatedWebsiteURL
                }
                sanitized.manifest = manifest
            } else {
                guard sanitized.kind == .pluginList else { return nil }
            }
            guard SkyStreamBackupMetadataPolicy.isBounded(repository: sanitized) else {
                return nil
            }
            repositories.append(sanitized)
        }
        repositories.sort { $0.sourceURL < $1.sourceURL }

        var aggregateArchiveBytes = 0
        var plugins: [SkyStreamPluginBackupSnapshot] = []
        plugins.reserveCapacity(incoming.plugins.count)
        for plugin in incoming.plugins {
            guard let sourceURL = validatedURL(plugin.state.provenance.sourceURL) else {
                return nil
            }
            var sanitized = plugin
            if stripArchives {
                sanitized.archivePayload = nil
                sanitized.payloadWasRedacted = true
            } else if let archive = plugin.archivePayload {
                let digest = SHA256.hash(data: archive)
                    .map { String(format: "%02x", $0) }
                    .joined()
                let (nextAggregateBytes, overflow) = aggregateArchiveBytes.addingReportingOverflow(
                    archive.count
                )
                if archive.count <= 20 * 1_024 * 1_024,
                   digest.caseInsensitiveCompare(plugin.state.archiveSHA256) == .orderedSame,
                   !overflow,
                   nextAggregateBytes <= 64 * 1_024 * 1_024 {
                    aggregateArchiveBytes = nextAggregateBytes
                    sanitized.archivePayload = archive
                    sanitized.payloadWasRedacted = false
                } else {
                    sanitized.archivePayload = nil
                    sanitized.payloadWasRedacted = true
                }
            } else {
                sanitized.archivePayload = nil
                sanitized.payloadWasRedacted = true
            }
            sanitized.additionalFields = [:]
            sanitized.state.additionalFields = [:]
            sanitized.state.payloadRelativePath = ""
            sanitized.state.runtimeStorage = nil
            if configurationIsComplete {
                guard SkyStreamPrivateCloudConfigurationPolicy
                    .preferencesAreCompleteAndBounded(sanitized.state.preferences) else {
                    return nil
                }
            } else {
                sanitized.state.preferences = sanitized.state.preferences.filter { key, value in
                    !value.isSecret &&
                        !value.isRedacted &&
                        !containsCloudUnsafeSecret(key)
                }
            }
            sanitized.state.preferences = sanitized.state.preferences.mapValues { value in
                var canonical = value
                canonical.updatedAt = nil
                return canonical
            }
            sanitized.preferencesWereRedacted = !configurationIsComplete

            sanitized.state.provenance.sourceURL = sourceURL
            if let repositoryURL = sanitized.state.provenance.repositoryURL {
                guard let validatedRepositoryURL = validatedURL(repositoryURL) else { return nil }
                sanitized.state.provenance.repositoryURL = validatedRepositoryURL
            }
            if let pluginListURL = sanitized.state.provenance.pluginListURL {
                guard let validatedPluginListURL = validatedURL(pluginListURL) else { return nil }
                sanitized.state.provenance.pluginListURL = validatedPluginListURL
            }
            sanitized.state.provenance.additionalFields = [:]
            sanitized.state.provenance.pinnedAt = Date(timeIntervalSince1970: 0)
            sanitized.state.provenance.frozenAt = nil
            sanitized.state.provenance.expectedArchiveSHA256 = sanitized.state.archiveSHA256
            if let selectedDomainURL = sanitized.state.selectedDomainURL {
                guard let validatedSelectedDomainURL = validatedURL(selectedDomainURL) else {
                    return nil
                }
                sanitized.state.selectedDomainURL = validatedSelectedDomainURL
            }
            sanitized.state.providers = sanitized.state.providers.filter {
                $0.removedAt == nil
            }.map { provider in
                var provider = provider
                provider.removedAt = nil
                provider.additionalFields = [:]
                return provider
            }.sorted { $0.id < $1.id }

            guard let manifest = sanitizedPluginManifest(sanitized.state.manifest) else {
                return nil
            }
            sanitized.state.manifest = manifest
            sanitized.state.compatibility.reasons = sanitized.state.compatibility.reasons.map { reason in
                var reason = reason
                reason.additionalFields = [:]
                return reason
            }
            sanitized.state.installedAt = Date(timeIntervalSince1970: 0)
            sanitized.state.updatedAt = Date(timeIntervalSince1970: 0)
            sanitized.state.compatibility = .untested
            let usesDynamicProviders = sanitized.state.usesDynamicProviders == true
                || sanitized.state.manifest.providers?.isEmpty == true
            sanitized.state.usesDynamicProviders = usesDynamicProviders
            if usesDynamicProviders {
                sanitized.state.manifest.providers = []
            }
            if let selectedDomainURL = sanitized.state.selectedDomainURL,
               sanitized.state.manifest.domains?.contains(where: {
                    $0.url == selectedDomainURL
               }) != true {
                return nil
            }
            guard SkyStreamBackupMetadataPolicy.isBounded(pluginState: sanitized.state) else {
                return nil
            }
            plugins.append(sanitized)
        }
        plugins.sort { $0.id < $1.id }
        return SkyStreamBackupSnapshot(
            schemaVersion: incoming.schemaVersion,
            repositories: repositories,
            plugins: plugins,
            createdAt: Date(timeIntervalSince1970: 0),
            isSafeCloudSnapshot: true,
            privateCloudConfigurationIsComplete: configurationIsComplete ? true : nil,
            additionalFields: [:]
        )
    }

    private static func skyStreamPrivateCloudURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              value == trimmed,
              value.utf8.count <= 8 * 1_024,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.host?.isEmpty == false,
              components.url?.absoluteString == value else {
            return nil
        }
        return value
    }

    private static func skyStreamCloudSafeURLString(_ value: String) -> String? {
        guard let sanitized = cloudSafeURLString(value),
              var components = URLComponents(string: sanitized),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.queryItems?.isEmpty != false else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }

    static func captureMediaStateSettings(from defaults: UserDefaults? = nil) -> [String: Data] {
        var result: [String: Data] = [:]
        for key in MediaStateSettingRegistry.allKeys {
            let defaults = defaults ?? ProfileSettingsStore.store(for: key)
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

    static func restoreMediaStateSettings(
        _ settings: [String: Data]?,
        to defaults: UserDefaults? = nil,
        appliesProfileScopedWrites: Bool = true,
        appliesServicesScopedWrites: Bool = true
    ) {
        guard let settings else { return }
        for (key, data) in settings {
            switch EclipseSettingsRegistry.scope(for: key) {
            case .profile where !appliesProfileScopedWrites:
                continue
            case .services where !appliesServicesScopedWrites:
                continue
            case .profile, .services, .device:
                break
            }
            let defaults = defaults ?? ProfileSettingsStore.store(for: key)
            guard MediaStateSettingRegistry.scope(for: key)?.appliesToCurrentPlatform == true,
                  let value = MediaStateSettingValueValidator.validatedValue(
                      from: data,
                      forKey: key
                  ) else {
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
        case playerBrightnessGestureEnabled, playerVolumeGestureEnabled, vlcBrightnessGestureEnabled, vlcVolumeGestureEnabled, playerTwoFingerTapPlayPauseEnabled, playerCenterTapPlayPauseEnabled, playerDoubleTapSeekEnabled, vlcDoubleTapSeekEnabled, playerDoubleTapSeekSeconds, vlcDoubleTapSeekSeconds, playerOpenSubtitlesEnabled, vlcOpenSubtitlesEnabled, playerOpenSubtitlesAutoFallbackEnabled, vlcOpenSubtitlesAutoFallbackEnabled, playerPerformanceOverlayEnabled, mpvForegroundFPS, mpvRenderBackend, mpvMetalQualityProfile, mpvUpscalingMode, mpvNeuralUpscaler, mpvNeuralUpscalerTV, mpvPlayerSkin, mpvPlayerSkinCustomPrimaryColor, mpvPlayerSkinCustomSecondaryColor, mpvPlayerSkinAnimationsEnabled, mpvPlayerSkinTintControlsOnly, mpvPictureInPictureEnabled, mpvAppExitPictureInPictureEnabled, mpvHDRMode, mpvSurroundSoundEnabled, watchTogetherEnabled, smartInAppPlayerChoosingEnabled, experimentalFeaturesEnabled, experimentalFeaturesLastChangedAt, experimentalMPVPreloadEnabled, experimentalMPVSmoothTransitionEnabled, experimentalMPVPreloadCellularEnabled, experimentalMPVPreloadWifiLimitMB, experimentalMPVPreloadCellularLimitMB, experimentalMPVShowRemainingTime, experimentalMPVPreciseProgress, experimentalMPVIgnoreSpecialSubtitleStyles, experimentalMPVPreloadAutoClear, experimentalICloudSyncEnabled
        case subtitleForegroundColor, subtitleStrokeColor, subtitleStrokeWidth, subtitleFontSize, subtitleVerticalOffset, subtitlesVisible
        case showKanzen, hideSplashScreen, modeSwitchAnimationEnabled, kanzenAutoUpdateModules, seasonMenu, horizontalEpisodeList, mediaDetailTitleArtworkEnabled, mediaDetailAlternatePosterEnabled, mediaDetailSimilarTitlesEnabled, useClassicScheduleUI, heroBannerCatalogId, heroBannerBehavior, homeCatalogLayoutOverrides, homeAnimatedBackgroundEnabled, homeAnimatedBackgroundQuality, homeAnimatedBackgroundFrameRate, appPerformanceOverlayEnabled, experimentalMediaDesignPreset, experimentalHeroBleedLevel, experimentalHomeCardShape, experimentalMultiGradientPalette, experimentalHeroHeightScale, experimentalHeroBleedStrength, experimentalHeroFadeDistanceScale, experimentalSectionSpacingScale, experimentalCardRadiusScale, experimentalMediaCardScale, experimentalGlassStrength, experimentalGradientBaseDarkness, experimentalGradientAccentIntensity, experimentalGradientScrollMotion, experimentalGradientUseCustomColors, experimentalGradientColorA, experimentalGradientColorB, experimentalGradientColorC, atmosphereStyle, atmosphereSolidColorSource, atmosphereSolidColor, readerAtmosphereStyle, readerAtmosphereSolidColorSource, readerAtmosphereSolidColor, mediaDetailElementOrder, mediaDetailHiddenElements, readerDetailElementOrder, readerDetailHiddenElements, mediaColumnsPortrait, mediaColumnsLandscape
        case readingMode, kanzenReaderMode, kanzenReaderModeOverrides, readerDownsampleImages, readerCropBorders, readerDisableQuickActions, readerDisableDoubleTap, readerLiveText, readerHideBarsOnSwipe, readerBackgroundColor, readerOrientation, readerTapZones, readerInvertTapZones, readerAnimatePageTransitions, readerUpscaleImages, readerUpscaleMaxHeight, readerUpscaleModelName, readerPagesToPreload, readerPagedPageLayout, readerPagedPageOffset, readerPagedPageOffsetOverrides, readerSplitWideImages, readerReverseSplitOrder, readerVerticalInfiniteScroll, readerPillarbox, readerPillarboxAmount, readerPillarboxOrientation, readerOrientationLockEnabled, readerOrientationLockMask, readerReadThresholdPercent
        case readerFontSize, readerFontFamily, readerFontWeight, readerColorPreset, readerTextAlignment, readerLineSpacing, readerMargin
        case autoClearCacheEnabled, autoClearCacheThresholdMB, highQualityThreshold, backgroundHLSPipelineEnabled, readerDownloadsBackgroundEnabled, readerDownloadsWifiOnly, readerDownloadsParallelLimit, autoUpdateServicesEnabled, servicesAutoModeEnabled, servicesAutoSelectEpisodesEnabled, servicesAutoModeErrorIntelligenceEnabled, servicesAutoModeSourceIds, servicesAutoModeSourceOrderIds, servicesAutoModeQualityPreference, servicesResultMinimumSimilarity, servicesDropMismatchedResults, servicesStremioStyleSheetEnabled, servicesIncludedStreamLanguages, servicesHiddenStreamLanguages, servicesHideStreamsWithoutLanguageData, servicesAssumeOriginalAudio, servicesTreatDubbedAnimeAsEnglish, servicesHiddenStreamQualities, servicesHideStreamsWithoutDetectedQuality, servicesExtraRulesSourceIds, githubReleaseAutoCheckEnabled, githubReleaseUpdateAvailable, githubReleaseLatestVersion, githubReleaseURL, githubReleaseShowAlertPending, githubReleaseLastPromptedVersion, filterHorrorContent = "filterHorror", selectedSimilarityAlgorithm, performanceModeEnabled, performanceModeSkipAniListTraversalForAnimeDetails, performanceModeFastAnimeCatalogOverrides
        case kanzenHomeSelectedSourceID, kanzenRecentSourceSearches
        case collections, progressData, trackerState, catalogs, services, stremioAddons, skyStream, nuvioPlugins
        case mangaCollections, mangaReadingProgress, mangaCatalogs, customCatalogs, kanzenModules
        case readerExtensionsState, aidokuState
        case searchHistory, recommendationCache
        case userRatings, userRatingNotes
        case mediaStateSettings

        case profiles, activeProfileID
        case topLevelSettingKeys
        case servicesSettings, servicesSettingsWereCaptured
        case sharesServices
        case skyStreamSharedPayloads, nuvioSharedPayloads
    }

    private static let nonSettingCodingKeyRawValues: Set<String> = [
        "version", "createdDate",
        "collections", "progressData", "trackerState", "catalogs", "services",
        "stremioAddons", "skyStream", "nuvioPlugins",
        "mangaCollections", "mangaReadingProgress", "mangaCatalogs",
        "customCatalogs", "kanzenModules", "readerExtensionsState", "aidokuState",
        "searchHistory", "recommendationCache", "userRatings", "userRatingNotes",
        "mediaStateSettings", "profiles", "activeProfileID", "topLevelSettingKeys", "servicesSettings",
        "servicesSettingsWereCaptured",
        "sharesServices", "skyStreamSharedPayloads", "nuvioSharedPayloads"
    ]

    private static func decodedSettingKeyRawValues(
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> Set<String> {
        Set(container.allKeys.compactMap { key in
            guard !nonSettingCodingKeyRawValues.contains(key.rawValue),
                  (try? container.decodeNil(forKey: key)) == false else {
                return nil
            }
            return key.rawValue
        })
    }

    private struct LossyRecommendationResults: Decodable {
        let values: [TMDBSearchResult]

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            let maximumCount = 10_000
            if let count = container.count, count > maximumCount {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Recommendation cache contains too many items."
                )
            }
            var decoded: [TMDBSearchResult] = []
            decoded.reserveCapacity(min(container.count ?? 0, maximumCount))
            var consumedCount = 0
            while !container.isAtEnd {
                guard consumedCount < maximumCount else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Recommendation cache contains too many items."
                    )
                }
                let candidate = try container.decode(LossyRecommendationResult.self)
                consumedCount += 1
                if let value = candidate.value {
                    decoded.append(value)
                }
            }
            values = decoded
        }
    }

    private struct LossyRecommendationResult: Decodable {
        let value: TMDBSearchResult?

        init(from decoder: Decoder) throws {
            value = try? TMDBSearchResult(from: decoder)
        }
    }

    fileprivate static func sanitizedDeclaredTopLevelSettingKeys(
        _ values: [String]?
    ) -> Set<String> {
        guard let values else { return [] }
        return Set(values.prefix(512).compactMap { rawKey in
            guard let key = CodingKeys(rawValue: rawKey),
                  !nonSettingCodingKeyRawValues.contains(key.rawValue) else {
                return nil
            }
            return key.rawValue
        })
    }

    static func decodedTopLevelSettingKeys(fromJSONObject json: [String: Any]) -> Set<String> {
        let candidates = Set(json.compactMap { rawKey, value -> String? in
            guard !(value is NSNull),
                  let key = CodingKeys(rawValue: rawKey),
                  !nonSettingCodingKeyRawValues.contains(key.rawValue) else {
                return nil
            }
            return key.rawValue
        })
        guard !candidates.isEmpty else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func strictlyDecodes(_ keys: Set<String>) -> Bool {
            var probe: [String: Any] = [
                "version": currentCloudSchemaVersion,
                "createdDate": "1970-01-01T00:00:00Z"
            ]
            for key in keys {
                probe[key] = json[key]
            }
            guard JSONSerialization.isValidJSONObject(probe),
                  let data = try? JSONSerialization.data(withJSONObject: probe) else {
                return false
            }
            return (try? decoder.decode(BackupData.self, from: data)) != nil
        }

        // The common lenient path is a malformed independent domain, not a
        // malformed setting. Validate the whole setting aggregate once, then
        // fall back to isolated probes only when one member is bad.
        if strictlyDecodes(candidates) { return candidates }
        return Set(candidates.filter { strictlyDecodes([$0]) })
    }

    static func topLevelSettingIsAuthoritative(
        storageKey: String,
        decodedWireKeys: Set<String>,
        allSettingsWereCaptured: Bool = false
    ) -> Bool {
        if allSettingsWereCaptured { return true }
        return settingWireKeys(forStorageKey: storageKey).contains {
            decodedWireKeys.contains($0)
        }
    }

    private static func settingWireKeys(forStorageKey storageKey: String) -> [String] {
        if storageKey.hasPrefix("kanzenReaderMode.") {
            return ["kanzenReaderModeOverrides"]
        }
        if storageKey.hasPrefix("Reader.pagedPageOffset.") {
            return ["readerPagedPageOffsetOverrides"]
        }
        if storageKey.hasPrefix("Reader.") {
            let suffix = storageKey.dropFirst("Reader.".count)
            guard let first = suffix.first else { return [] }
            return ["reader" + String(first).uppercased() + String(suffix.dropFirst())]
        }
        switch storageKey {
        case "eclipseThemeGradientColor":
            return ["settingsGradientColor"]
        case "readerThemeGradientColor":
            return ["readerSettingsGradientColor"]
        case "readerSelectedAppearance":
            return ["readerSelectedAppearance", "selectedAppearance"]
        case "readerAtmosphereStyle":
            return ["readerAtmosphereStyle", "atmosphereStyle"]
        case "readerAtmosphereSolidColorSource":
            return ["readerAtmosphereSolidColorSource", "atmosphereSolidColorSource"]
        case "kanzenReaderMode":
            return ["kanzenReaderMode", "readingMode"]
        case "playbackEngine", "inAppPlayer":
            return ["inAppPlayer", "playerChoice"]
        case "playerSubtitleAppearanceEnabled":
            return ["playerSubtitleAppearanceEnabled", "enableVLCSubtitleEditMenu"]
        case "showEpisodeBrowserButton":
            return ["showEpisodeBrowserButton", "showVLCEpisodeBrowserButton"]
        case "playerBrightnessGestureEnabled":
            return ["playerBrightnessGestureEnabled", "vlcBrightnessGestureEnabled"]
        case "playerVolumeGestureEnabled":
            return ["playerVolumeGestureEnabled", "vlcVolumeGestureEnabled"]
        case "playerDoubleTapSeekEnabled":
            return ["playerDoubleTapSeekEnabled", "vlcDoubleTapSeekEnabled"]
        case "playerDoubleTapSeekSeconds":
            return ["playerDoubleTapSeekSeconds", "vlcDoubleTapSeekSeconds"]
        case "playerOpenSubtitlesEnabled":
            return ["playerOpenSubtitlesEnabled", "vlcOpenSubtitlesEnabled"]
        case "playerOpenSubtitlesAutoFallbackEnabled":
            return ["playerOpenSubtitlesAutoFallbackEnabled", "vlcOpenSubtitlesAutoFallbackEnabled"]
        case "subtitles_foregroundColor":
            return ["subtitleForegroundColor"]
        case "subtitles_strokeColor":
            return ["subtitleStrokeColor"]
        case "subtitles_strokeWidth":
            return ["subtitleStrokeWidth"]
        case "subtitles_fontSize":
            return ["subtitleFontSize"]
        case "playerSubtitleOverlayBottomConstant":
            return ["subtitleVerticalOffset"]
        case "subtitles_isVisible":
            return ["subtitlesVisible"]
        case "showCastSection":
            return ["mediaDetailHiddenElements"]
        default:
            return [storageKey]
        }
    }

    func topLevelSettingIsAuthoritative(storageKey: String) -> Bool {
        Self.topLevelSettingIsAuthoritative(
            storageKey: storageKey,
            decodedWireKeys: decodedTopLevelSettingKeys,
            allSettingsWereCaptured: allTopLevelSettingsWereCaptured
        )
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

        inAppPlayer = Settings.normalizedInAppPlayer(
            try container.decodeIfPresent(String.self, forKey: .inAppPlayer)
                ?? container.decodeIfPresent(String.self, forKey: .playerChoice)
        )
        showScheduleTab = try container.decodeIfPresent(Bool.self, forKey: .showScheduleTab) ?? true
        showLocalScheduleTime = try container.decodeIfPresent(Bool.self, forKey: .showLocalScheduleTime) ?? true
        defaultScheduleMode = ScheduleMode.sanitizedRawValue(try container.decodeIfPresent(String.self, forKey: .defaultScheduleMode))
        scheduleWindowDays = ScheduleWindow.sanitizedDays(try container.decodeIfPresent(Int.self, forKey: .scheduleWindowDays))
        localNotificationSubscriptions = Self.sanitizedLocalNotificationSubscriptions(
            try container.decodeIfPresent(String.self, forKey: .localNotificationSubscriptions)
        )
        localNotificationEpisodeReminders = Self.sanitizedLocalNotificationEpisodeReminders(
            try container.decodeIfPresent(String.self, forKey: .localNotificationEpisodeReminders)
        )
        localNotificationEpisodeLeadTime = Self.sanitizedLocalNotificationEpisodeLeadTime(
            try container.decodeIfPresent(Int.self, forKey: .localNotificationEpisodeLeadTime)
        )
        localNotificationSeasonLeadTime = Self.sanitizedLocalNotificationSeasonLeadTime(
            try container.decodeIfPresent(Int.self, forKey: .localNotificationSeasonLeadTime)
        )
        localNotificationIncludeAnimeSpecials = try container.decodeIfPresent(Bool.self, forKey: .localNotificationIncludeAnimeSpecials)

        defaultPlaybackSpeed = Self.sanitizedDefaultPlaybackSpeed(
            try container.decodeIfPresent(Double.self, forKey: .defaultPlaybackSpeed)
        )
        holdSpeedPlayer = Self.sanitizedHoldSpeedPlayer(
            try container.decodeIfPresent(Double.self, forKey: .holdSpeedPlayer)
        )
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
        nextEpisodeThreshold = Self.sanitizedNextEpisodeThreshold(
            try container.decodeIfPresent(Double.self, forKey: .nextEpisodeThreshold)
        )
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
        playerDoubleTapSeekSeconds = Self.sanitizedPlayerDoubleTapSeekSeconds(
            try container.decodeIfPresent(Double.self, forKey: .playerDoubleTapSeekSeconds)
                ?? container.decodeIfPresent(Double.self, forKey: .vlcDoubleTapSeekSeconds)
        )
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
        mpvNeuralUpscaler = Self.sanitizedMPVNeuralUpscaler(try container.decodeIfPresent(String.self, forKey: .mpvNeuralUpscaler))
        mpvNeuralUpscalerTV = Self.sanitizedMPVNeuralUpscaler(try container.decodeIfPresent(String.self, forKey: .mpvNeuralUpscalerTV))
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
        experimentalFeaturesEnabled = try container.decodeIfPresent(Bool.self, forKey: .experimentalFeaturesEnabled)
        experimentalFeaturesLastChangedAt = Self.sanitizedExperimentalFeaturesLastChangedAt(
            try container.decodeIfPresent(Double.self, forKey: .experimentalFeaturesLastChangedAt)
        )
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

        subtitleForegroundColor = try Self.decodeColorData(from: container, forKey: .subtitleForegroundColor)
        subtitleStrokeColor = try Self.decodeColorData(from: container, forKey: .subtitleStrokeColor)
        subtitleStrokeWidth = Self.sanitizedSubtitleStrokeWidth(
            try container.decodeIfPresent(Double.self, forKey: .subtitleStrokeWidth)
        )
        subtitleFontSize = Self.sanitizedSubtitleFontSize(
            try container.decodeIfPresent(Double.self, forKey: .subtitleFontSize)
        )
        subtitleVerticalOffset = Self.sanitizedSubtitleVerticalOffset(
            try container.decodeIfPresent(Double.self, forKey: .subtitleVerticalOffset)
        )
        subtitlesVisible = try container.decodeIfPresent(Bool.self, forKey: .subtitlesVisible) ?? false

        showKanzen = try container.decodeIfPresent(Bool.self, forKey: .showKanzen) ?? false
        hideSplashScreen = try container.decodeIfPresent(Bool.self, forKey: .hideSplashScreen)
        modeSwitchAnimationEnabled = try container.decodeIfPresent(Bool.self, forKey: .modeSwitchAnimationEnabled) ?? ModeSwitchAnimationSettings.defaultEnabled
        kanzenAutoUpdateModules = try container.decodeIfPresent(Bool.self, forKey: .kanzenAutoUpdateModules) ?? true
        seasonMenu = try container.decodeIfPresent(Bool.self, forKey: .seasonMenu) ?? false
        horizontalEpisodeList = try container.decodeIfPresent(Bool.self, forKey: .horizontalEpisodeList) ?? false
        mediaDetailTitleArtworkEnabled = try container.decodeIfPresent(Bool.self, forKey: .mediaDetailTitleArtworkEnabled) ?? MediaDetailTitleArtworkSettings.defaultEnabled
        mediaDetailAlternatePosterEnabled = try container.decodeIfPresent(Bool.self, forKey: .mediaDetailAlternatePosterEnabled) ?? MediaDetailAlternatePosterSettings.defaultEnabled
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

        readerFontSize = Self.sanitizedReaderFontSize(
            try container.decodeIfPresent(Double.self, forKey: .readerFontSize)
        )
        readerFontFamily = try container.decodeIfPresent(String.self, forKey: .readerFontFamily) ?? "-apple-system"
        readerFontWeight = try container.decodeIfPresent(String.self, forKey: .readerFontWeight) ?? "normal"
        readerColorPreset = try container.decodeIfPresent(Int.self, forKey: .readerColorPreset) ?? 0
        readerTextAlignment = try container.decodeIfPresent(String.self, forKey: .readerTextAlignment) ?? "left"
        readerLineSpacing = Self.sanitizedReaderLineSpacing(
            try container.decodeIfPresent(Double.self, forKey: .readerLineSpacing)
        )
        readerMargin = Self.sanitizedReaderMargin(
            try container.decodeIfPresent(Double.self, forKey: .readerMargin)
        )

        autoClearCacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoClearCacheEnabled) ?? false
        autoClearCacheThresholdMB = Self.sanitizedAutoClearCacheThresholdMB(
            try container.decodeIfPresent(Double.self, forKey: .autoClearCacheThresholdMB)
        )
        highQualityThreshold = Self.sanitizedHighQualityThreshold(
            try container.decodeIfPresent(Double.self, forKey: .highQualityThreshold)
        )
        backgroundHLSPipelineEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundHLSPipelineEnabled) ?? false
        readerDownloadsBackgroundEnabled = try container.decodeIfPresent(Bool.self, forKey: .readerDownloadsBackgroundEnabled) ?? true
        readerDownloadsWifiOnly = try container.decodeIfPresent(Bool.self, forKey: .readerDownloadsWifiOnly) ?? false
        readerDownloadsParallelLimit = Self.sanitizedReaderDownloadsParallelLimit(try container.decodeIfPresent(Int.self, forKey: .readerDownloadsParallelLimit))
        autoUpdateServicesEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateServicesEnabled) ?? true
        servicesAutoModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .servicesAutoModeEnabled) ?? AutoModeSettings.defaultEnabled
        servicesAutoSelectEpisodesEnabled = try container.decodeIfPresent(Bool.self, forKey: .servicesAutoSelectEpisodesEnabled) ?? false
        servicesAutoModeErrorIntelligenceEnabled = try container.decodeIfPresent(Bool.self, forKey: .servicesAutoModeErrorIntelligenceEnabled) ?? AutoModeErrorIntelligenceSettings.defaultEnabled
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

        let decodedCollections = try container.decodeIfPresent(
            [BackupCollection].self,
            forKey: .collections
        )
        let decodedProgress = try container.decodeIfPresent(
            ProgressData.self,
            forKey: .progressData
        )
        let decodedTrackerState = try container.decodeIfPresent(
            TrackerState.self,
            forKey: .trackerState
        )
        let decodedCatalogs = try container.decodeIfPresent(
            [Catalog].self,
            forKey: .catalogs
        )
        let decodedServices = try container.decodeIfPresent(
            [BackupService].self,
            forKey: .services
        )
        collections = Self.sanitizedCollections(decodedCollections ?? [])
        progressData = Self.sanitizedProgressData(decodedProgress ?? ProgressData())
        trackerState = decodedTrackerState ?? TrackerState()
        catalogs = decodedCatalogs ?? []
        services = decodedServices ?? []
        stremioAddons = try container.decodeIfPresent([BackupStremioAddon].self, forKey: .stremioAddons)
        skyStream = try container.decodeIfPresent(SkyStreamBackupSnapshot.self, forKey: .skyStream)
        nuvioPlugins = try container.decodeIfPresent(NuvioStoredPluginsState.self, forKey: .nuvioPlugins)
        mangaCollections = try container.decodeIfPresent([BackupMangaCollection].self, forKey: .mangaCollections) ?? []
        mangaReadingProgress = try container.decodeIfPresent([String: MangaProgress].self, forKey: .mangaReadingProgress) ?? [:]
        mangaCatalogs = try container.decodeIfPresent([MangaCatalog].self, forKey: .mangaCatalogs) ?? []
        customCatalogs = try container.decodeIfPresent([KanzenCustomCatalog].self, forKey: .customCatalogs) ?? []
        kanzenModules = try container.decodeIfPresent([BackupKanzenModule].self, forKey: .kanzenModules) ?? []
        aidokuState = try container.decodeIfPresent(BackupAidokuState.self, forKey: .aidokuState)
            .map(Self.aidokuStateWithoutExecutablePayloads)
        readerExtensionsState = try container.decodeIfPresent(
            BackupReaderExtensionState.self,
            forKey: .readerExtensionsState
        ) ?? aidokuState.map(BackupReaderExtensionState.migratingLegacyAidoku)
        searchHistory = try container.decodeIfPresent(BackupSearchHistory.self, forKey: .searchHistory) ?? BackupSearchHistory()
        let decodedRecommendationCache = try? container.decodeIfPresent(
            LossyRecommendationResults.self,
            forKey: .recommendationCache
        )
        recommendationCache = Self.sanitizedRecommendationCache(
            decodedRecommendationCache?.values ?? []
        )
        let decodedUserRatings = Self.decodeUserRatingsIfPresent(from: container)
        let decodedUserRatingNotes = try container.decodeIfPresent(
            [String: String].self,
            forKey: .userRatingNotes
        )
        userRatings = decodedUserRatings ?? [:]
        userRatingNotes = Self.sanitizedUserRatingNotes(decodedUserRatingNotes ?? [:])
        mediaStateSettings = try container.decodeIfPresent([String: Data].self, forKey: .mediaStateSettings)

        let decodedServicesSettings = try container.decodeIfPresent(
            [String: Data].self,
            forKey: .servicesSettings
        )
        servicesSettings = Self.servicesSettingsForExperimentalCloudSync(
            decodedServicesSettings
        )
        servicesSettingsWereCaptured = (
            try container.decodeIfPresent(Bool.self, forKey: .servicesSettingsWereCaptured)
                ?? false
        ) && servicesSettings != nil
        sharesServices = try container.decodeIfPresent(Bool.self, forKey: .sharesServices)
        profiles = try container.decodeIfPresent([BackupProfileSnapshot].self, forKey: .profiles)
        activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        skyStreamSharedPayloads = try container.decodeIfPresent(
            [BackupSkyStreamSharedPayload].self,
            forKey: .skyStreamSharedPayloads
        )
        nuvioSharedPayloads = try container.decodeIfPresent(
            [BackupNuvioSharedPayload].self,
            forKey: .nuvioSharedPayloads
        )
        hasCollections = decodedCollections != nil
        hasProgressData = decodedProgress != nil
        hasTrackerState = decodedTrackerState != nil
        hasCatalogs = decodedCatalogs != nil
        hasServices = decodedServices != nil
        hasMangaCollections = container.decodePresence(of: [BackupMangaCollection].self, forKey: .mangaCollections)
        hasMangaReadingProgress = container.decodePresence(of: [String: MangaProgress].self, forKey: .mangaReadingProgress)
        hasMangaCatalogs = container.decodePresence(of: [MangaCatalog].self, forKey: .mangaCatalogs)
        hasCustomCatalogs = container.decodePresence(of: [KanzenCustomCatalog].self, forKey: .customCatalogs)
        hasKanzenModules = container.decodePresence(of: [BackupKanzenModule].self, forKey: .kanzenModules)
        hasUserRatings = decodedUserRatings != nil && decodedUserRatingNotes != nil
        allTopLevelSettingsWereCaptured = false
        let decodedSettingKeys = Self.decodedSettingKeyRawValues(in: container)
        if container.contains(.topLevelSettingKeys) {
            let declaredKeys = try? container.decode(
                [String].self,
                forKey: .topLevelSettingKeys
            )
            decodedTopLevelSettingKeys = decodedSettingKeys.intersection(
                Self.sanitizedDeclaredTopLevelSettingKeys(declaredKeys)
            )
        } else {
            // Backward compatibility: legacy backups predate the authority
            // list, so each successfully decoded scalar key authorizes itself.
            decodedTopLevelSettingKeys = decodedSettingKeys
        }
        let decodedOptionalColorSettings: [(String, Data?)] = [
            (CodingKeys.accentColor.rawValue, accentColor),
            (CodingKeys.settingsGradientColor.rawValue, settingsGradientColor),
            (CodingKeys.readerAccentColor.rawValue, readerAccentColor),
            (CodingKeys.readerSettingsGradientColor.rawValue, readerSettingsGradientColor),
            (CodingKeys.mpvPlayerSkinCustomPrimaryColor.rawValue, mpvPlayerSkinCustomPrimaryColor),
            (CodingKeys.mpvPlayerSkinCustomSecondaryColor.rawValue, mpvPlayerSkinCustomSecondaryColor),
            (CodingKeys.subtitleForegroundColor.rawValue, subtitleForegroundColor),
            (CodingKeys.subtitleStrokeColor.rawValue, subtitleStrokeColor),
            (CodingKeys.experimentalGradientColorA.rawValue, experimentalGradientColorA),
            (CodingKeys.experimentalGradientColorB.rawValue, experimentalGradientColorB),
            (CodingKeys.experimentalGradientColorC.rawValue, experimentalGradientColorC),
            (CodingKeys.atmosphereSolidColor.rawValue, atmosphereSolidColor),
            (CodingKeys.readerAtmosphereSolidColor.rawValue, readerAtmosphereSolidColor)
        ]
        for (key, value) in decodedOptionalColorSettings where value == nil {
            decodedTopLevelSettingKeys.remove(key)
        }
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
        if !allTopLevelSettingsWereCaptured {
            try container.encode(
                decodedTopLevelSettingKeys.sorted(),
                forKey: .topLevelSettingKeys
            )
        }
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
        try container.encodeIfPresent(
            Self.sanitizedLocalNotificationSubscriptions(localNotificationSubscriptions),
            forKey: .localNotificationSubscriptions
        )
        try container.encodeIfPresent(
            Self.sanitizedLocalNotificationEpisodeReminders(localNotificationEpisodeReminders),
            forKey: .localNotificationEpisodeReminders
        )
        try container.encodeIfPresent(
            Self.sanitizedLocalNotificationEpisodeLeadTime(localNotificationEpisodeLeadTime),
            forKey: .localNotificationEpisodeLeadTime
        )
        try container.encodeIfPresent(
            Self.sanitizedLocalNotificationSeasonLeadTime(localNotificationSeasonLeadTime),
            forKey: .localNotificationSeasonLeadTime
        )
        try container.encodeIfPresent(localNotificationIncludeAnimeSpecials, forKey: .localNotificationIncludeAnimeSpecials)

        try container.encode(Self.sanitizedDefaultPlaybackSpeed(defaultPlaybackSpeed), forKey: .defaultPlaybackSpeed)
        try container.encode(Self.sanitizedHoldSpeedPlayer(holdSpeedPlayer), forKey: .holdSpeedPlayer)
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
        try container.encode(Self.sanitizedNextEpisodeThreshold(nextEpisodeThreshold), forKey: .nextEpisodeThreshold)
        try container.encode(nextEpisodeSkipFillerEnabled, forKey: .nextEpisodeSkipFillerEnabled)
        try container.encode(playerBrightnessGestureEnabled, forKey: .playerBrightnessGestureEnabled)
        try container.encode(playerVolumeGestureEnabled, forKey: .playerVolumeGestureEnabled)
        try container.encode(playerTwoFingerTapPlayPauseEnabled, forKey: .playerTwoFingerTapPlayPauseEnabled)
        try container.encode(playerCenterTapPlayPauseEnabled, forKey: .playerCenterTapPlayPauseEnabled)
        try container.encode(playerDoubleTapSeekEnabled, forKey: .playerDoubleTapSeekEnabled)
        try container.encode(Self.sanitizedPlayerDoubleTapSeekSeconds(playerDoubleTapSeekSeconds), forKey: .playerDoubleTapSeekSeconds)
        try container.encode(playerOpenSubtitlesEnabled, forKey: .playerOpenSubtitlesEnabled)
        try container.encode(playerOpenSubtitlesAutoFallbackEnabled, forKey: .playerOpenSubtitlesAutoFallbackEnabled)
        try container.encode(playerPerformanceOverlayEnabled, forKey: .playerPerformanceOverlayEnabled)
        try container.encode(mpvForegroundFPS, forKey: .mpvForegroundFPS)
        try container.encode(mpvRenderBackend, forKey: .mpvRenderBackend)
        try container.encode(mpvMetalQualityProfile, forKey: .mpvMetalQualityProfile)
        try container.encode(mpvUpscalingMode, forKey: .mpvUpscalingMode)
        try container.encode(mpvNeuralUpscaler, forKey: .mpvNeuralUpscaler)
        try container.encode(mpvNeuralUpscalerTV, forKey: .mpvNeuralUpscalerTV)
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
        try container.encodeIfPresent(experimentalFeaturesEnabled, forKey: .experimentalFeaturesEnabled)
        try container.encodeIfPresent(
            Self.sanitizedExperimentalFeaturesLastChangedAt(experimentalFeaturesLastChangedAt),
            forKey: .experimentalFeaturesLastChangedAt
        )
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

        try container.encodeIfPresent(subtitleForegroundColor, forKey: .subtitleForegroundColor)
        try container.encodeIfPresent(subtitleStrokeColor, forKey: .subtitleStrokeColor)
        try container.encode(Self.sanitizedSubtitleStrokeWidth(subtitleStrokeWidth), forKey: .subtitleStrokeWidth)
        try container.encode(Self.sanitizedSubtitleFontSize(subtitleFontSize), forKey: .subtitleFontSize)
        try container.encode(Self.sanitizedSubtitleVerticalOffset(subtitleVerticalOffset), forKey: .subtitleVerticalOffset)
        try container.encode(subtitlesVisible, forKey: .subtitlesVisible)

        try container.encode(showKanzen, forKey: .showKanzen)
        try container.encodeIfPresent(hideSplashScreen, forKey: .hideSplashScreen)
        try container.encode(modeSwitchAnimationEnabled, forKey: .modeSwitchAnimationEnabled)
        try container.encode(kanzenAutoUpdateModules, forKey: .kanzenAutoUpdateModules)
        try container.encode(seasonMenu, forKey: .seasonMenu)
        try container.encode(horizontalEpisodeList, forKey: .horizontalEpisodeList)
        try container.encode(mediaDetailTitleArtworkEnabled, forKey: .mediaDetailTitleArtworkEnabled)
        try container.encode(mediaDetailAlternatePosterEnabled, forKey: .mediaDetailAlternatePosterEnabled)
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
        try container.encode(Self.sanitizedReaderReadThresholdPercent(readerReadThresholdPercent), forKey: .readerReadThresholdPercent)

        try container.encode(Self.sanitizedReaderFontSize(readerFontSize), forKey: .readerFontSize)
        try container.encode(readerFontFamily, forKey: .readerFontFamily)
        try container.encode(readerFontWeight, forKey: .readerFontWeight)
        try container.encode(readerColorPreset, forKey: .readerColorPreset)
        try container.encode(readerTextAlignment, forKey: .readerTextAlignment)
        try container.encode(Self.sanitizedReaderLineSpacing(readerLineSpacing), forKey: .readerLineSpacing)
        try container.encode(Self.sanitizedReaderMargin(readerMargin), forKey: .readerMargin)

        try container.encode(autoClearCacheEnabled, forKey: .autoClearCacheEnabled)
        try container.encode(Self.sanitizedAutoClearCacheThresholdMB(autoClearCacheThresholdMB), forKey: .autoClearCacheThresholdMB)
        try container.encode(Self.sanitizedHighQualityThreshold(highQualityThreshold), forKey: .highQualityThreshold)
        try container.encode(backgroundHLSPipelineEnabled, forKey: .backgroundHLSPipelineEnabled)
        try container.encode(readerDownloadsBackgroundEnabled, forKey: .readerDownloadsBackgroundEnabled)
        try container.encode(readerDownloadsWifiOnly, forKey: .readerDownloadsWifiOnly)
        try container.encode(Self.sanitizedReaderDownloadsParallelLimit(readerDownloadsParallelLimit), forKey: .readerDownloadsParallelLimit)
        try container.encode(autoUpdateServicesEnabled, forKey: .autoUpdateServicesEnabled)
        try container.encode(servicesAutoModeEnabled, forKey: .servicesAutoModeEnabled)
        try container.encode(servicesAutoSelectEpisodesEnabled, forKey: .servicesAutoSelectEpisodesEnabled)
        try container.encode(servicesAutoModeErrorIntelligenceEnabled, forKey: .servicesAutoModeErrorIntelligenceEnabled)
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

        if hasCollections {
            try container.encode(Self.sanitizedCollections(collections), forKey: .collections)
        }
        if hasProgressData {
            try container.encode(Self.sanitizedProgressData(progressData), forKey: .progressData)
        }
        if hasTrackerState {
            try container.encode(trackerState, forKey: .trackerState)
        }
        if hasCatalogs {
            try container.encode(catalogs, forKey: .catalogs)
        }
        if hasServices {
            try container.encode(services, forKey: .services)
        }
        try container.encodeIfPresent(stremioAddons, forKey: .stremioAddons)
        try container.encodeIfPresent(skyStream, forKey: .skyStream)
        try container.encodeIfPresent(nuvioPlugins, forKey: .nuvioPlugins)
        if hasMangaCollections {
            try container.encode(mangaCollections, forKey: .mangaCollections)
        }
        if hasMangaReadingProgress {
            try container.encode(mangaReadingProgress, forKey: .mangaReadingProgress)
        }
        if hasMangaCatalogs {
            try container.encode(mangaCatalogs, forKey: .mangaCatalogs)
        }
        if hasCustomCatalogs || !customCatalogs.isEmpty {
            try container.encode(customCatalogs, forKey: .customCatalogs)
        }
        if hasKanzenModules {
            try container.encode(kanzenModules, forKey: .kanzenModules)
        }
        try container.encodeIfPresent(readerExtensionsState?.sanitized(), forKey: .readerExtensionsState)
        try container.encode(searchHistory, forKey: .searchHistory)
        try container.encode(
            Self.sanitizedRecommendationCache(recommendationCache),
            forKey: .recommendationCache
        )
        if hasUserRatings {
            try container.encode(Self.sanitizedUserRatings(userRatings), forKey: .userRatings)
            try container.encode(Self.sanitizedUserRatingNotes(userRatingNotes), forKey: .userRatingNotes)
        }
        try container.encodeIfPresent(mediaStateSettings, forKey: .mediaStateSettings)
        let safeServicesSettings = Self.servicesSettingsForExperimentalCloudSync(
            servicesSettings
        )
        try container.encodeIfPresent(safeServicesSettings, forKey: .servicesSettings)
        try container.encode(
            servicesSettingsWereCaptured && safeServicesSettings != nil,
            forKey: .servicesSettingsWereCaptured
        )
        try container.encodeIfPresent(sharesServices, forKey: .sharesServices)
        try container.encodeIfPresent(profiles, forKey: .profiles)
        try container.encodeIfPresent(activeProfileID, forKey: .activeProfileID)
        try container.encodeIfPresent(skyStreamSharedPayloads, forKey: .skyStreamSharedPayloads)
        try container.encodeIfPresent(nuvioSharedPayloads, forKey: .nuvioSharedPayloads)
    }

    init(
        version: String = BackupData.currentCloudSchemaVersion,
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
        mpvNeuralUpscaler: String = MPVNeuralUpscaler.defaultUpscaler.rawValue,
        mpvNeuralUpscalerTV: String = MPVNeuralUpscaler.defaultUpscaler.rawValue,
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
        experimentalFeaturesEnabled: Bool? = nil,
        experimentalFeaturesLastChangedAt: Double? = nil,
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

        subtitleForegroundColor: Data? = nil,
        subtitleStrokeColor: Data? = nil,
        subtitleStrokeWidth: Double = 1.0,
        subtitleFontSize: Double = 30.0,
        subtitleVerticalOffset: Double = -6.0,
        subtitlesVisible: Bool = false,

        showKanzen: Bool = false,
        hideSplashScreen: Bool? = nil,
        modeSwitchAnimationEnabled: Bool = ModeSwitchAnimationSettings.defaultEnabled,
        kanzenAutoUpdateModules: Bool = true,
        seasonMenu: Bool = false,
        horizontalEpisodeList: Bool = false,
        mediaDetailTitleArtworkEnabled: Bool = MediaDetailTitleArtworkSettings.defaultEnabled,
        mediaDetailAlternatePosterEnabled: Bool = MediaDetailAlternatePosterSettings.defaultEnabled,
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

        readerFontSize: Double = 16,
        readerFontFamily: String = "-apple-system",
        readerFontWeight: String = "normal",
        readerColorPreset: Int = 0,
        readerTextAlignment: String = "left",
        readerLineSpacing: Double = 1.6,
        readerMargin: Double = 4,

        autoClearCacheEnabled: Bool = false,
        autoClearCacheThresholdMB: Double = 500,
        highQualityThreshold: Double = 0.9,
        backgroundHLSPipelineEnabled: Bool = false,
        readerDownloadsBackgroundEnabled: Bool = true,
        readerDownloadsWifiOnly: Bool = false,
        readerDownloadsParallelLimit: Int = 2,
        autoUpdateServicesEnabled: Bool = true,
        servicesAutoModeEnabled: Bool = AutoModeSettings.defaultEnabled,
        servicesAutoSelectEpisodesEnabled: Bool = false,
        servicesAutoModeErrorIntelligenceEnabled: Bool = AutoModeErrorIntelligenceSettings.defaultEnabled,
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
        skyStream: SkyStreamBackupSnapshot? = nil,
        nuvioPlugins: NuvioStoredPluginsState? = nil,
        mangaCollections: [BackupMangaCollection] = [],
        mangaReadingProgress: [String: MangaProgress] = [:],
        mangaCatalogs: [MangaCatalog] = [],
        customCatalogs: [KanzenCustomCatalog] = [],
        kanzenModules: [BackupKanzenModule] = [],
        readerExtensionsState: BackupReaderExtensionState? = nil,
        aidokuState: BackupAidokuState? = nil,
        searchHistory: BackupSearchHistory = BackupSearchHistory(),
        recommendationCache: [TMDBSearchResult] = [],
        userRatings: [String: Double] = [:],
        userRatingNotes: [String: String] = [:],
        mediaStateSettings: [String: Data]? = nil,
        collectionsPresent: Bool = true,
        progressDataPresent: Bool = true,
        trackerStatePresent: Bool = true,
        catalogsPresent: Bool = true,
        servicesPresent: Bool = true,
        mangaCollectionsPresent: Bool = true,
        mangaReadingProgressPresent: Bool = true,
        mangaCatalogsPresent: Bool = true,
        customCatalogsPresent: Bool = true,
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
        self.localNotificationSubscriptions = Self.sanitizedLocalNotificationSubscriptions(
            localNotificationSubscriptions
        )
        self.localNotificationEpisodeReminders = Self.sanitizedLocalNotificationEpisodeReminders(
            localNotificationEpisodeReminders
        )
        self.localNotificationEpisodeLeadTime = Self.sanitizedLocalNotificationEpisodeLeadTime(
            localNotificationEpisodeLeadTime
        )
        self.localNotificationSeasonLeadTime = Self.sanitizedLocalNotificationSeasonLeadTime(
            localNotificationSeasonLeadTime
        )
        self.localNotificationIncludeAnimeSpecials = localNotificationIncludeAnimeSpecials

        self.defaultPlaybackSpeed = Self.sanitizedDefaultPlaybackSpeed(defaultPlaybackSpeed)
        self.holdSpeedPlayer = Self.sanitizedHoldSpeedPlayer(holdSpeedPlayer)
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
        self.nextEpisodeThreshold = Self.sanitizedNextEpisodeThreshold(nextEpisodeThreshold)
        self.nextEpisodeSkipFillerEnabled = nextEpisodeSkipFillerEnabled
        self.playerBrightnessGestureEnabled = playerBrightnessGestureEnabled
        self.playerVolumeGestureEnabled = playerVolumeGestureEnabled
        self.playerTwoFingerTapPlayPauseEnabled = playerTwoFingerTapPlayPauseEnabled
        self.playerCenterTapPlayPauseEnabled = playerCenterTapPlayPauseEnabled
        self.playerDoubleTapSeekEnabled = playerDoubleTapSeekEnabled
        self.playerDoubleTapSeekSeconds = Self.sanitizedPlayerDoubleTapSeekSeconds(playerDoubleTapSeekSeconds)
        self.playerOpenSubtitlesEnabled = playerOpenSubtitlesEnabled
        self.playerOpenSubtitlesAutoFallbackEnabled = playerOpenSubtitlesAutoFallbackEnabled
        self.playerPerformanceOverlayEnabled = playerPerformanceOverlayEnabled
        self.mpvForegroundFPS = Self.sanitizedMPVForegroundFPS(mpvForegroundFPS)
        self.mpvRenderBackend = Self.sanitizedMPVRenderBackend(mpvRenderBackend)
        self.mpvMetalQualityProfile = Self.sanitizedMPVMetalQualityProfile(mpvMetalQualityProfile)
        self.mpvUpscalingMode = Self.sanitizedMPVUpscalingMode(mpvUpscalingMode)
        self.mpvNeuralUpscaler = Self.sanitizedMPVNeuralUpscaler(mpvNeuralUpscaler)
        self.mpvNeuralUpscalerTV = Self.sanitizedMPVNeuralUpscaler(mpvNeuralUpscalerTV)
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
        self.experimentalFeaturesLastChangedAt = Self.sanitizedExperimentalFeaturesLastChangedAt(
            experimentalFeaturesLastChangedAt
        )
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
        self.subtitleStrokeWidth = Self.sanitizedSubtitleStrokeWidth(subtitleStrokeWidth)
        self.subtitleFontSize = Self.sanitizedSubtitleFontSize(subtitleFontSize)
        self.subtitleVerticalOffset = Self.sanitizedSubtitleVerticalOffset(subtitleVerticalOffset)
        self.subtitlesVisible = subtitlesVisible

        self.showKanzen = showKanzen
        self.hideSplashScreen = hideSplashScreen
        self.modeSwitchAnimationEnabled = modeSwitchAnimationEnabled
        self.kanzenAutoUpdateModules = kanzenAutoUpdateModules
        self.seasonMenu = seasonMenu
        self.horizontalEpisodeList = horizontalEpisodeList
        self.mediaDetailTitleArtworkEnabled = mediaDetailTitleArtworkEnabled
        self.mediaDetailAlternatePosterEnabled = mediaDetailAlternatePosterEnabled
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

        self.readerFontSize = Self.sanitizedReaderFontSize(readerFontSize)
        self.readerFontFamily = readerFontFamily
        self.readerFontWeight = readerFontWeight
        self.readerColorPreset = readerColorPreset
        self.readerTextAlignment = readerTextAlignment
        self.readerLineSpacing = Self.sanitizedReaderLineSpacing(readerLineSpacing)
        self.readerMargin = Self.sanitizedReaderMargin(readerMargin)

        self.autoClearCacheEnabled = autoClearCacheEnabled
        self.autoClearCacheThresholdMB = Self.sanitizedAutoClearCacheThresholdMB(autoClearCacheThresholdMB)
        self.highQualityThreshold = Self.sanitizedHighQualityThreshold(highQualityThreshold)
        self.backgroundHLSPipelineEnabled = backgroundHLSPipelineEnabled
        self.readerDownloadsBackgroundEnabled = readerDownloadsBackgroundEnabled
        self.readerDownloadsWifiOnly = readerDownloadsWifiOnly
        self.readerDownloadsParallelLimit = Self.sanitizedReaderDownloadsParallelLimit(readerDownloadsParallelLimit)
        self.autoUpdateServicesEnabled = autoUpdateServicesEnabled
        self.servicesAutoModeEnabled = servicesAutoModeEnabled
        self.servicesAutoSelectEpisodesEnabled = servicesAutoSelectEpisodesEnabled
        self.servicesAutoModeErrorIntelligenceEnabled = servicesAutoModeErrorIntelligenceEnabled
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

        self.collections = Self.sanitizedCollections(collections)
        self.progressData = Self.sanitizedProgressData(progressData)
        self.trackerState = trackerState
        self.catalogs = catalogs
        self.services = services
        self.stremioAddons = stremioAddons
        self.skyStream = skyStream
        self.nuvioPlugins = nuvioPlugins
        self.mangaCollections = mangaCollections
        self.mangaReadingProgress = mangaReadingProgress
        self.mangaCatalogs = mangaCatalogs
        self.customCatalogs = customCatalogs
        self.kanzenModules = kanzenModules
        self.aidokuState = aidokuState.map(Self.aidokuStateWithoutExecutablePayloads)
        self.readerExtensionsState = readerExtensionsState
            ?? self.aidokuState.map(BackupReaderExtensionState.migratingLegacyAidoku)
        self.searchHistory = searchHistory
        self.recommendationCache = Self.sanitizedRecommendationCache(recommendationCache)
        self.userRatings = Self.sanitizedUserRatings(userRatings)
        self.userRatingNotes = Self.sanitizedUserRatingNotes(userRatingNotes)
        self.mediaStateSettings = mediaStateSettings
        self.hasCollections = collectionsPresent
        self.hasProgressData = progressDataPresent
        self.hasTrackerState = trackerStatePresent
        self.hasCatalogs = catalogsPresent
        self.hasServices = servicesPresent
        self.hasMangaCollections = mangaCollectionsPresent
        self.hasMangaReadingProgress = mangaReadingProgressPresent
        self.hasMangaCatalogs = mangaCatalogsPresent
        self.hasCustomCatalogs = customCatalogsPresent
        self.hasKanzenModules = kanzenModulesPresent
        self.hasUserRatings = userRatingsPresent
    }

    private static func decodeUserRatingsIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [String: Double]? {
        if let ratings = try? container.decodeIfPresent([String: Double].self, forKey: .userRatings) {
            return sanitizedUserRatings(ratings)
        }

        if let ratings = try? container.decodeIfPresent([String: Int].self, forKey: .userRatings) {
            return sanitizedUserRatings(ratings.mapValues(Double.init))
        }

        return nil
    }

    static func canonicalPositiveTMDBIdentifier(_ rawValue: String) -> String? {
        guard let value = Int(rawValue),
              ProgressPersistencePolicy.validPositiveIdentifier(value),
              rawValue == String(value) else {
            return nil
        }
        return rawValue
    }

    static func sanitizedCollections(_ collections: [BackupCollection]) -> [BackupCollection] {
        collections.map(\.sanitizedForPersistence)
    }

    static func sanitizedRecommendationCache(
        _ results: [TMDBSearchResult]
    ) -> [TMDBSearchResult] {
        Array(results.compactMap(\.sanitizedForPersistence).prefix(10_000))
    }

    static func sanitizedUserRatings(_ ratings: [String: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: ratings.compactMap { key, value -> (String, Double)? in
            guard let identifier = canonicalPositiveTMDBIdentifier(key) else { return nil }
            let finiteValue = value.isFinite ? value : 0.5
            let halfStepValue = (finiteValue * 2).rounded() / 2
            return (identifier, max(0.5, min(10, halfStepValue)))
        })
    }

    static func sanitizedUserRatingNotes(_ notes: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: notes.compactMap { key, value -> (String, String)? in
            guard let identifier = canonicalPositiveTMDBIdentifier(key) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (identifier, trimmed)
        })
    }

    static func sanitizedProgressData(
        _ source: ProgressData,
        preservingDeviceLocalReferences: Bool = false
    ) -> ProgressData {
        ProgressPersistencePolicy.sanitized(
            source,
            preservingDeviceLocalReferences: preservingDeviceLocalReferences
        )
    }

    private static func isPlausibleProgressClock(_ value: Date, now: Date) -> Bool {
        let seconds = value.timeIntervalSince1970
        return seconds.isFinite
            && seconds >= 0
            && seconds <= now.timeIntervalSince1970
                + MediaStateEnvelopeValidator.maximumFutureClockSkew
    }

    private static func sanitizedProgressTimes(
        currentTime: Double,
        totalDuration: Double
    ) -> (currentTime: Double, totalDuration: Double)? {
        guard currentTime.isFinite,
              totalDuration.isFinite,
              currentTime >= 0,
              totalDuration >= 0 else {
            return nil
        }
        guard totalDuration > 0 else {
            return currentTime == 0 ? (0, 0) : nil
        }
        return (currentTime, max(totalDuration, currentTime))
    }

    private static func progressEntry<Entry: Encodable>(
        _ candidate: Entry,
        isPreferredOver existing: Entry
    ) -> Bool {
        let candidateDate: Date
        let existingDate: Date
        if let candidate = candidate as? MovieProgressEntry,
           let existing = existing as? MovieProgressEntry {
            candidateDate = candidate.lastUpdated
            existingDate = existing.lastUpdated
        } else if let candidate = candidate as? EpisodeProgressEntry,
                  let existing = existing as? EpisodeProgressEntry {
            candidateDate = candidate.lastUpdated
            existingDate = existing.lastUpdated
        } else {
            return false
        }
        if candidateDate != existingDate { return candidateDate > existingDate }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let candidateData = try? encoder.encode(candidate),
              let existingData = try? encoder.encode(existing) else {
            return false
        }
        return existingData.lexicographicallyPrecedes(candidateData)
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

    static func sanitizedMPVNeuralUpscaler(_ value: String?) -> String {
        guard let value,
              let upscaler = MPVNeuralUpscaler(rawValue: value) else {
            return MPVNeuralUpscaler.defaultUpscaler.rawValue
        }
        return upscaler.rawValue
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

    /// Backup data crosses JSON, property-list, and legacy dictionary
    /// boundaries. Keep every persisted floating-point setting finite before
    /// it can poison an entire JSONEncoder operation, and constrain it to the
    /// same range the live settings UI accepts.
    static func sanitizedFiniteNumericSetting(
        _ value: Double?,
        defaultValue: Double,
        range: ClosedRange<Double>,
        defaultsWhenNonPositive: Bool = false
    ) -> Double {
        guard let value,
              value.isFinite,
              !defaultsWhenNonPositive || value > 0 else {
            return defaultValue
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func sanitizedDefaultPlaybackSpeed(_ value: Double?) -> Double {
        sanitizedFiniteNumericSetting(
            value,
            defaultValue: 1,
            range: 0.25...3,
            defaultsWhenNonPositive: true
        )
    }

    static func sanitizedHoldSpeedPlayer(_ value: Double?) -> Double {
        sanitizedFiniteNumericSetting(
            value,
            defaultValue: 2,
            range: 0.1...3,
            defaultsWhenNonPositive: true
        )
    }

    static func sanitizedNextEpisodeThreshold(_ value: Double?) -> Double {
        sanitizedFiniteNumericSetting(
            value,
            defaultValue: 0.9,
            range: 0.5...0.99,
            defaultsWhenNonPositive: true
        )
    }

    static func sanitizedPlayerDoubleTapSeekSeconds(_ value: Double?) -> Double {
        sanitizedFiniteNumericSetting(
            value,
            defaultValue: 10,
            range: 5...60,
            defaultsWhenNonPositive: true
        )
    }

    static func sanitizedExperimentalFeaturesLastChangedAt(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, Date.distantFuture.timeIntervalSince1970)
    }

    static func sanitizedSubtitleStrokeWidth(_ value: Double?) -> Double {
        sanitizedFiniteNumericSetting(value, defaultValue: 1, range: 0...10)
    }

    static func sanitizedSubtitleFontSize(_ value: Double?) -> Double {
        sanitizedFiniteNumericSetting(
            value,
            defaultValue: 30,
            range: 8...96,
            defaultsWhenNonPositive: true
        )
    }

    static func sanitizedSubtitleVerticalOffset(_ value: Double?) -> Double {
        sanitizedFiniteNumericSetting(value, defaultValue: -6, range: -24...24)
    }

    static func sanitizedReaderFontSize(_ value: Double?) -> Double {
        sanitizedFiniteNumericSetting(
            value,
            defaultValue: 16,
            range: 12...32,
            defaultsWhenNonPositive: true
        )
    }

    static func sanitizedReaderLineSpacing(_ value: Double?) -> Double {
        sanitizedFiniteNumericSetting(
            value,
            defaultValue: 1.6,
            range: 1...3,
            defaultsWhenNonPositive: true
        )
    }

    static func sanitizedReaderMargin(_ value: Double?) -> Double {
        sanitizedFiniteNumericSetting(value, defaultValue: 4, range: 0...30)
    }

    static func sanitizedAutoClearCacheThresholdMB(_ value: Double?) -> Double {
        sanitizedFiniteNumericSetting(
            value,
            defaultValue: 500,
            range: 100...5_000,
            defaultsWhenNonPositive: true
        )
    }

    static func sanitizedHighQualityThreshold(_ value: Double?) -> Double {
        sanitizedFiniteNumericSetting(value, defaultValue: 0.9, range: 0...1)
    }

    private static let maximumLocalNotificationJSONBytes = 262_144
    private static let maximumLocalNotificationSubscriptions = 256
    private static let maximumLocalNotificationReminders = 512
    private static let maximumLocalNotificationNestedValues = 512
    private static let maximumLocalNotificationStringLength = 512
    private static let maximumLocalNotificationTitleLength = 1_024
    private static let maximumLocalNotificationFutureInterval: TimeInterval = 10 * 366 * 24 * 60 * 60

    static func sanitizedLocalNotificationSubscriptions(_ value: String?) -> String? {
        guard let data = boundedLocalNotificationJSONData(value),
              let decoded = try? JSONDecoder().decode(
                [LocalMediaNotificationSubscription].self,
                from: data
              ) else {
            return nil
        }

        let maximumDate = Date().addingTimeInterval(maximumLocalNotificationFutureInterval)
        var seenIDs = Set<String>()
        let sanitized = decoded.compactMap { subscription -> LocalMediaNotificationSubscription? in
            guard seenIDs.count < maximumLocalNotificationSubscriptions,
                  let id = boundedLocalNotificationString(subscription.id),
                  seenIDs.insert(id).inserted,
                  subscription.tmdbID > 0,
                  subscription.tmdbID <= Int(Int32.max),
                  let title = boundedLocalNotificationString(
                    subscription.title,
                    maximumLength: maximumLocalNotificationTitleLength
                  ) else {
                return nil
            }

            let aliases = boundedLocalNotificationStrings(
                subscription.titleAliases + [title],
                maximumCount: 32,
                maximumLength: maximumLocalNotificationTitleLength
            )
            let animeMediaIDs = boundedPositiveLocalNotificationIDs(subscription.animeMediaIDs)
            let animeSpecialMediaIDs = boundedPositiveLocalNotificationIDs(
                subscription.animeSpecialMediaIDs
            ).subtracting(animeMediaIDs)
            let knownWesternSeasonIDs = boundedPositiveLocalNotificationIDs(
                subscription.knownWesternSeasonIDs
            )
            let mutedEpisodeKeys = Set(
                boundedLocalNotificationStrings(
                    Array(subscription.mutedEpisodeKeys),
                    maximumCount: maximumLocalNotificationNestedValues
                )
            )
            var mutedEpisodeExpirations: [String: Date] = [:]
            for (rawKey, expiration) in subscription.mutedEpisodeExpirations
                .sorted(by: { $0.key < $1.key }) {
                guard mutedEpisodeExpirations.count < maximumLocalNotificationNestedValues,
                      let key = boundedLocalNotificationString(rawKey),
                      mutedEpisodeKeys.contains(key),
                      let date = boundedLocalNotificationDate(
                        expiration,
                        maximumDate: maximumDate
                      ) else {
                    continue
                }
                mutedEpisodeExpirations[key] = date
            }

            let seasonPremieres = subscription.seasonPremieres
                .prefix(128)
                .compactMap { premiere -> LocalSeasonPremiere? in
                    guard let premiereID = boundedLocalNotificationString(premiere.id),
                          let premiereTitle = boundedLocalNotificationString(
                            premiere.title,
                            maximumLength: maximumLocalNotificationTitleLength
                          ),
                          let seasonLabel = boundedLocalNotificationString(premiere.seasonLabel) else {
                        return nil
                    }
                    let seasonNumber = premiere.seasonNumber.flatMap {
                        (0...10_000).contains($0) ? $0 : nil
                    }
                    let sourceMediaID = premiere.sourceMediaID.flatMap {
                        $0 > 0 && $0 <= Int(Int32.max) ? $0 : nil
                    }
                    return LocalSeasonPremiere(
                        id: premiereID,
                        title: premiereTitle,
                        seasonLabel: seasonLabel,
                        premiereDate: premiere.premiereDate.flatMap {
                            boundedLocalNotificationDate($0, maximumDate: maximumDate)
                        },
                        hasExactTime: premiere.hasExactTime,
                        seasonNumber: seasonNumber,
                        sourceMediaID: sourceMediaID
                    )
                }

            return LocalMediaNotificationSubscription(
                id: id,
                source: subscription.source,
                tmdbID: subscription.tmdbID,
                title: title,
                titleAliases: aliases.isEmpty ? [title] : aliases,
                animeMediaIDs: animeMediaIDs,
                animeSpecialMediaIDs: animeSpecialMediaIDs,
                knownWesternSeasonIDs: knownWesternSeasonIDs,
                episodeNotifications: subscription.episodeNotifications,
                futureSeasonNotifications: subscription.futureSeasonNotifications,
                mutedEpisodeKeys: mutedEpisodeKeys,
                mutedEpisodeExpirations: mutedEpisodeExpirations,
                seasonPremieres: seasonPremieres,
                hasCompleteAnimeSeasonBaseline: subscription.hasCompleteAnimeSeasonBaseline,
                hasCompleteWesternSeasonBaseline: subscription.hasCompleteWesternSeasonBaseline,
                dateAdded: boundedLocalNotificationDate(
                    subscription.dateAdded,
                    maximumDate: maximumDate
                ) ?? Date(timeIntervalSince1970: 0)
            )
        }
        guard decoded.isEmpty || !sanitized.isEmpty else { return nil }
        return encodedBoundedLocalNotificationJSONString(sanitized)
    }

    static func sanitizedLocalNotificationEpisodeReminders(_ value: String?) -> String? {
        guard let data = boundedLocalNotificationJSONData(value),
              let decoded = try? JSONDecoder().decode(
                [LocalEpisodeNotificationReminder].self,
                from: data
              ) else {
            return nil
        }

        let maximumDate = Date().addingTimeInterval(maximumLocalNotificationFutureInterval)
        var seenIDs = Set<String>()
        let sanitized = decoded.compactMap { reminder -> LocalEpisodeNotificationReminder? in
            guard seenIDs.count < maximumLocalNotificationReminders,
                  let id = boundedLocalNotificationString(reminder.id),
                  seenIDs.insert(id).inserted,
                  reminder.sourceMediaID > 0,
                  reminder.sourceMediaID <= Int(Int32.max),
                  reminder.episode > 0,
                  reminder.episode <= 1_000_000,
                  let title = boundedLocalNotificationString(
                    reminder.title,
                    maximumLength: maximumLocalNotificationTitleLength
                  ),
                  let airingAt = boundedLocalNotificationDate(
                    reminder.airingAt,
                    maximumDate: maximumDate
                  ) else {
                return nil
            }
            let tmdbID = reminder.tmdbID.flatMap {
                $0 > 0 && $0 <= Int(Int32.max) ? $0 : nil
            }
            let season = reminder.season.flatMap {
                (0...10_000).contains($0) ? $0 : nil
            }
            return LocalEpisodeNotificationReminder(
                id: id,
                source: reminder.source,
                sourceMediaID: reminder.sourceMediaID,
                tmdbID: tmdbID,
                tmdbMediaType: tmdbID == nil ? nil : reminder.tmdbMediaType,
                title: title,
                season: season,
                episode: reminder.episode,
                airingAt: airingAt,
                hasKnownAiringTime: reminder.hasKnownAiringTime,
                isStreamingRelease: reminder.isStreamingRelease,
                isAnimeSpecial: reminder.isAnimeSpecial
            )
        }
        guard decoded.isEmpty || !sanitized.isEmpty else { return nil }
        return encodedBoundedLocalNotificationJSONString(sanitized)
    }

    static func sanitizedLocalNotificationEpisodeLeadTime(_ value: Int?) -> Int? {
        value.flatMap(EpisodeNotificationLeadTime.init(rawValue:))?.rawValue
    }

    static func sanitizedLocalNotificationSeasonLeadTime(_ value: Int?) -> Int? {
        value.flatMap(SeasonNotificationLeadTime.init(rawValue:))?.rawValue
    }

    private static func boundedLocalNotificationJSONData(_ value: String?) -> Data? {
        guard let value,
              let data = value.data(using: .utf8),
              data.count <= maximumLocalNotificationJSONBytes else {
            return nil
        }
        return data
    }

    private static func encodedBoundedLocalNotificationJSONString<T: Encodable>(
        _ value: T
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              data.count <= maximumLocalNotificationJSONBytes else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func boundedLocalNotificationString(
        _ value: String,
        maximumLength: Int = maximumLocalNotificationStringLength
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumLength))
    }

    private static func boundedLocalNotificationStrings(
        _ values: [String],
        maximumCount: Int,
        maximumLength: Int = maximumLocalNotificationStringLength
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard result.count < maximumCount,
                  let bounded = boundedLocalNotificationString(
                    value,
                    maximumLength: maximumLength
                  ),
                  seen.insert(bounded).inserted else {
                continue
            }
            result.append(bounded)
        }
        return result
    }

    private static func boundedPositiveLocalNotificationIDs(_ values: Set<Int>) -> Set<Int> {
        Set(
            values
                .filter { $0 > 0 && $0 <= Int(Int32.max) }
                .sorted()
                .prefix(maximumLocalNotificationNestedValues)
        )
    }

    private static func boundedLocalNotificationDate(
        _ value: Date,
        maximumDate: Date
    ) -> Date? {
        let seconds = value.timeIntervalSince1970
        guard seconds.isFinite,
              seconds >= 0,
              seconds <= maximumDate.timeIntervalSince1970 else {
            return nil
        }
        return value
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
        if let double = value as? Double,
           double.isFinite,
           let exact = Int(exactly: double) {
            return exact
        }
        return defaultValue
    }

    static func optionalDouble(from value: Any?, defaultValue: Double) -> Double {
        if let double = value as? Double, double.isFinite { return double }
        if let int = value as? Int { return Double(int) }
        return defaultValue.isFinite ? defaultValue : 0
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

extension BackupData: @unchecked Sendable {}

struct BackupService: Codable, Equatable {
    let id: UUID
    let url: String
    let jsonMetadata: String
    let jsScript: String
    let isActive: Bool
    let sortIndex: Int64
}

struct BackupStremioAddon: Codable, Equatable {
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

struct ExperimentalCloudNuvioRestorePlan: Equatable {
    let state: NuvioStoredPluginsState
    let deviceLocalSourceIDs: Set<String>
}

enum ExperimentalCloudLocalSourceSelectionPolicy {
    static func membership(
        current: [String],
        incoming: [String],
        preserving deviceLocalSourceIDs: Set<String>
    ) -> [String] {
        let sanitizedCurrent = BackupData.sanitizedStringList(current)
        var seen = Set<String>()
        var result = BackupData.sanitizedStringList(incoming).filter {
            !deviceLocalSourceIDs.contains($0) && seen.insert($0).inserted
        }
        result.append(contentsOf: sanitizedCurrent.filter {
            deviceLocalSourceIDs.contains($0) && seen.insert($0).inserted
        })
        return BackupData.sanitizedStringList(result)
    }

    static func order(
        current: [String],
        incoming: [String],
        preserving deviceLocalSourceIDs: Set<String>
    ) -> [String] {
        let sanitizedCurrent = BackupData.sanitizedStringList(current)
        let restoredShared = BackupData.sanitizedStringList(incoming).filter {
            !deviceLocalSourceIDs.contains($0)
        }
        var sharedIterator = restoredShared.makeIterator()
        var result: [String] = []
        var seen = Set<String>()

        // Preserve the receiver-only entries in their existing slots while
        // allowing the accepted cloud order to replace every shared slot.
        for currentID in sanitizedCurrent {
            let next = deviceLocalSourceIDs.contains(currentID)
                ? currentID
                : sharedIterator.next()
            if let next, seen.insert(next).inserted { result.append(next) }
        }
        while let next = sharedIterator.next() {
            if seen.insert(next).inserted { result.append(next) }
        }
        for localID in sanitizedCurrent where deviceLocalSourceIDs.contains(localID) {
            if seen.insert(localID).inserted { result.append(localID) }
        }
        return BackupData.sanitizedStringList(result)
    }

    static func restoredValue(
        _ incoming: Any,
        forKey key: String,
        currentStore: UserDefaults,
        preserving deviceLocalSourceIDs: Set<String>
    ) -> Any {
        guard !deviceLocalSourceIDs.isEmpty,
              let incomingValues = incoming as? [String] else { return incoming }
        let currentValues = currentStore.stringArray(forKey: key) ?? []
        switch key {
        case "servicesAutoModeSourceIds", "servicesExtraRulesSourceIds":
            return membership(
                current: currentValues,
                incoming: incomingValues,
                preserving: deviceLocalSourceIDs
            )
        case "servicesAutoModeSourceOrderIds":
            return order(
                current: currentValues,
                incoming: incomingValues,
                preserving: deviceLocalSourceIDs
            )
        default:
            return incoming
        }
    }
}

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
            $0.sortIndex == $1.sortIndex
                ? $0.id.uuidString < $1.id.uuidString
                : $0.sortIndex < $1.sortIndex
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
            $0.sortIndex == $1.sortIndex
                ? $0.id.uuidString < $1.id.uuidString
                : $0.sortIndex < $1.sortIndex
        }
    }
}

struct BackupMangaCollection: Codable {
    let id: UUID
    let name: String
    let items: [MangaLibraryItem]
    let description: String?
}

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

private enum BackupAidokuLegacyWirePolicy {
    static let maximumInstalledSources = 512
    static let maximumSourceLists = 100
    static let maximumLanguages = 128
    static let maximumSourceIDBytes = 192
    static let maximumNameBytes = 512
    static let maximumLanguageBytes = 32
    static let maximumPathBytes = 4 * 1_024
    static let maximumURLBytes = 16 * 1_024
    static let maximumErrorBytes = 4 * 1_024

    private static let sourceIDCharacters = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: ".-_")
    )
    private static let languageCharacters = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-_")
    )

    static func sourceID(_ rawValue: String, codingPath: [CodingKey]) throws -> String {
        let value = rawValue.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumSourceIDBytes,
              value.unicodeScalars.allSatisfy(sourceIDCharacters.contains) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "Legacy Reader source identity is invalid."
            ))
        }
        return value
    }

    static func requiredString(
        _ rawValue: String,
        maximumBytes: Int,
        field: String,
        codingPath: [CodingKey]
    ) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "Legacy Reader source \(field) is invalid."
            ))
        }
        return value
    }

    static func optionalString(
        _ rawValue: String?,
        maximumBytes: Int,
        field: String,
        codingPath: [CodingKey]
    ) throws -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "Legacy Reader source \(field) is invalid."
            ))
        }
        return value
    }

    static func language(_ rawValue: String, codingPath: [CodingKey]) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty,
              value.utf8.count <= maximumLanguageBytes,
              value.unicodeScalars.allSatisfy(languageCharacters.contains) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "Legacy Reader source language is invalid."
            ))
        }
        return value
    }

    static func isSafeDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (-62_135_596_800...253_402_300_799).contains(seconds)
    }

    static func isSafeDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

private struct BackupAidokuBoundedLanguages: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        if let count = container.count, count > BackupAidokuLegacyWirePolicy.maximumLanguages {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Legacy Reader source language list is too large."
            )
        }
        var result: [String] = []
        var seen = Set<String>()
        var decodedCount = 0
        while !container.isAtEnd {
            guard decodedCount < BackupAidokuLegacyWirePolicy.maximumLanguages else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Legacy Reader source language list is too large."
                )
            }
            decodedCount += 1
            let value = try BackupAidokuLegacyWirePolicy.language(
                container.decode(String.self),
                codingPath: container.codingPath
            )
            if seen.insert(value).inserted { result.append(value) }
        }
        values = result.sorted()
    }
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

    var packageDigest: String? = nil
    let payloadArchiveData: Data?
}

extension BackupAidokuInstalledSource {
    private enum CodingKeys: String, CodingKey {
        case id, name, version, languages, iconPath, externalIconURL
        case contentRatingRawValue, sourceListURL, packageURL, isEnabled, order
        case lastUpdated, lastError, packageDigest, payloadArchiveData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try BackupAidokuLegacyWirePolicy.sourceID(
            container.decode(String.self, forKey: .id),
            codingPath: container.codingPath + [CodingKeys.id]
        )
        name = try BackupAidokuLegacyWirePolicy.requiredString(
            container.decode(String.self, forKey: .name),
            maximumBytes: BackupAidokuLegacyWirePolicy.maximumNameBytes,
            field: "name",
            codingPath: container.codingPath + [CodingKeys.name]
        )

        let decodedVersion = try container.decode(Int.self, forKey: .version)
        guard (0...Int(Int32.max)).contains(decodedVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Legacy Reader source version is invalid."
            )
        }
        version = decodedVersion
        languages = try container.decode(
            BackupAidokuBoundedLanguages.self,
            forKey: .languages
        ).values
        iconPath = try BackupAidokuLegacyWirePolicy.optionalString(
            container.decodeIfPresent(String.self, forKey: .iconPath),
            maximumBytes: BackupAidokuLegacyWirePolicy.maximumPathBytes,
            field: "icon path",
            codingPath: container.codingPath + [CodingKeys.iconPath]
        )
        externalIconURL = try BackupAidokuLegacyWirePolicy.optionalString(
            container.decodeIfPresent(String.self, forKey: .externalIconURL),
            maximumBytes: BackupAidokuLegacyWirePolicy.maximumURLBytes,
            field: "external icon URL",
            codingPath: container.codingPath + [CodingKeys.externalIconURL]
        )

        let decodedRating = try container.decode(Int.self, forKey: .contentRatingRawValue)
        guard (0...3).contains(decodedRating) else {
            throw DecodingError.dataCorruptedError(
                forKey: .contentRatingRawValue,
                in: container,
                debugDescription: "Legacy Reader source content rating is invalid."
            )
        }
        contentRatingRawValue = decodedRating
        sourceListURL = try BackupAidokuLegacyWirePolicy.optionalString(
            container.decodeIfPresent(String.self, forKey: .sourceListURL),
            maximumBytes: BackupAidokuLegacyWirePolicy.maximumURLBytes,
            field: "source-list URL",
            codingPath: container.codingPath + [CodingKeys.sourceListURL]
        )
        packageURL = try BackupAidokuLegacyWirePolicy.optionalString(
            container.decodeIfPresent(String.self, forKey: .packageURL),
            maximumBytes: BackupAidokuLegacyWirePolicy.maximumURLBytes,
            field: "package URL",
            codingPath: container.codingPath + [CodingKeys.packageURL]
        )
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)

        let decodedOrder = try container.decode(Int.self, forKey: .order)
        guard (0...10_000).contains(decodedOrder) else {
            throw DecodingError.dataCorruptedError(
                forKey: .order,
                in: container,
                debugDescription: "Legacy Reader source order is invalid."
            )
        }
        order = decodedOrder

        let decodedDate = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        guard decodedDate.map(BackupAidokuLegacyWirePolicy.isSafeDate) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .lastUpdated,
                in: container,
                debugDescription: "Legacy Reader source update date is invalid."
            )
        }
        lastUpdated = decodedDate
        lastError = try BackupAidokuLegacyWirePolicy.optionalString(
            container.decodeIfPresent(String.self, forKey: .lastError),
            maximumBytes: BackupAidokuLegacyWirePolicy.maximumErrorBytes,
            field: "error",
            codingPath: container.codingPath + [CodingKeys.lastError]
        )
        if let decodedDigest = try container.decodeIfPresent(String.self, forKey: .packageDigest) {
            guard BackupAidokuLegacyWirePolicy.isSafeDigest(decodedDigest) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .packageDigest,
                    in: container,
                    debugDescription: "Legacy Reader source package digest is invalid."
                )
            }
            packageDigest = decodedDigest.lowercased()
        } else {
            packageDigest = nil
        }

        // Executable legacy archives are intentionally never materialized from a
        // backup. The key remains decode-recognized solely for old wire input.
        payloadArchiveData = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(languages, forKey: .languages)
        try container.encodeIfPresent(iconPath, forKey: .iconPath)
        try container.encodeIfPresent(externalIconURL, forKey: .externalIconURL)
        try container.encode(contentRatingRawValue, forKey: .contentRatingRawValue)
        try container.encodeIfPresent(sourceListURL, forKey: .sourceListURL)
        try container.encodeIfPresent(packageURL, forKey: .packageURL)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(order, forKey: .order)
        try container.encodeIfPresent(lastUpdated, forKey: .lastUpdated)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encodeIfPresent(packageDigest, forKey: .packageDigest)
        // Never write executable provider archive bytes into a new backup.
    }
}

private struct BackupAidokuBoundedInstalledSources: Decodable {
    let values: [BackupAidokuInstalledSource]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        if let count = container.count, count > BackupAidokuLegacyWirePolicy.maximumInstalledSources {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Legacy Reader installed-source list is too large."
            )
        }
        var result: [BackupAidokuInstalledSource] = []
        var seen = Set<String>()
        while !container.isAtEnd {
            guard result.count < BackupAidokuLegacyWirePolicy.maximumInstalledSources else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Legacy Reader installed-source list is too large."
                )
            }
            let source = try container.decode(BackupAidokuInstalledSource.self)
            guard seen.insert(source.id).inserted else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Legacy Reader installed-source identities must be unique."
                )
            }
            result.append(source)
        }
        values = result
    }
}

private struct BackupAidokuDecodedSourceListRecord: Decodable {
    let value: BackupAidokuSourceListRecord

    private enum CodingKeys: String, CodingKey {
        case url, name, sourceCount, lastRefresh, lastError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try BackupAidokuLegacyWirePolicy.requiredString(
            container.decode(String.self, forKey: .url),
            maximumBytes: BackupAidokuLegacyWirePolicy.maximumURLBytes,
            field: "source-list URL",
            codingPath: container.codingPath + [CodingKeys.url]
        )
        let name = try BackupAidokuLegacyWirePolicy.requiredString(
            container.decode(String.self, forKey: .name),
            maximumBytes: BackupAidokuLegacyWirePolicy.maximumNameBytes,
            field: "source-list name",
            codingPath: container.codingPath + [CodingKeys.name]
        )
        let sourceCount = try container.decode(Int.self, forKey: .sourceCount)
        guard (0...Int(Int32.max)).contains(sourceCount) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceCount,
                in: container,
                debugDescription: "Legacy Reader source-list count is invalid."
            )
        }
        let lastRefresh = try container.decodeIfPresent(Date.self, forKey: .lastRefresh)
        guard lastRefresh.map(BackupAidokuLegacyWirePolicy.isSafeDate) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .lastRefresh,
                in: container,
                debugDescription: "Legacy Reader source-list refresh date is invalid."
            )
        }
        let lastError = try BackupAidokuLegacyWirePolicy.optionalString(
            container.decodeIfPresent(String.self, forKey: .lastError),
            maximumBytes: BackupAidokuLegacyWirePolicy.maximumErrorBytes,
            field: "source-list error",
            codingPath: container.codingPath + [CodingKeys.lastError]
        )
        value = BackupAidokuSourceListRecord(
            url: url,
            name: name,
            sourceCount: sourceCount,
            lastRefresh: lastRefresh,
            lastError: lastError
        )
    }
}

private struct BackupAidokuBoundedSourceLists: Decodable {
    let values: [BackupAidokuSourceListRecord]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        if let count = container.count, count > BackupAidokuLegacyWirePolicy.maximumSourceLists {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Legacy Reader source-list metadata is too large."
            )
        }
        var result: [BackupAidokuSourceListRecord] = []
        while !container.isAtEnd {
            guard result.count < BackupAidokuLegacyWirePolicy.maximumSourceLists else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Legacy Reader source-list metadata is too large."
                )
            }
            result.append(try container.decode(BackupAidokuDecodedSourceListRecord.self).value)
        }
        values = result
    }
}

struct BackupSkyStreamSharedPayload: Codable {
    let packageID: String

    let payloadRelativePath: String
    let scriptSHA256: String
    let archiveSHA256: String
    let script: Data
    let archive: Data?
}

struct BackupNuvioSharedPayload: Codable {
    let repositoryID: String

    let scraperID: String
    let codeFileName: String
    let code: String
}

struct NuvioSharedPayloadMigrationResult {
    var backup: BackupData
    var migratedPayloadCount: Int
    var refusedPayloadCount: Int
}

struct BackupAidokuState: Codable {
    var sourceLists: [BackupAidokuSourceListRecord] = []
    var installedSources: [BackupAidokuInstalledSource] = []
    var showMatureSources: Bool = false
    var autoUpdateSources: Bool = true
    var lastAutoUpdate: Date?

    var sharedPayloads: [String: Data]? = nil
}

extension BackupAidokuState {
    private enum CodingKeys: String, CodingKey {
        case sourceLists, installedSources, showMatureSources, autoUpdateSources
        case lastAutoUpdate, sharedPayloads
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceLists = try container.decodeIfPresent(
            BackupAidokuBoundedSourceLists.self,
            forKey: .sourceLists
        )?.values ?? []
        installedSources = try container.decodeIfPresent(
            BackupAidokuBoundedInstalledSources.self,
            forKey: .installedSources
        )?.values ?? []
        showMatureSources = try container.decodeIfPresent(Bool.self, forKey: .showMatureSources) ?? false
        autoUpdateSources = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateSources) ?? true
        let decodedDate = try container.decodeIfPresent(Date.self, forKey: .lastAutoUpdate)
        guard decodedDate.map(BackupAidokuLegacyWirePolicy.isSafeDate) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .lastAutoUpdate,
                in: container,
                debugDescription: "Legacy Reader auto-update date is invalid."
            )
        }
        lastAutoUpdate = decodedDate

        // Old shared archives contain executable provider packages. Do not ask
        // Decoder to materialize their keys or base64 bodies at ingress.
        sharedPayloads = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceLists, forKey: .sourceLists)
        try container.encode(installedSources, forKey: .installedSources)
        try container.encode(showMatureSources, forKey: .showMatureSources)
        try container.encode(autoUpdateSources, forKey: .autoUpdateSources)
        try container.encodeIfPresent(lastAutoUpdate, forKey: .lastAutoUpdate)
        // Never write executable shared provider archives into a new backup.
    }
}

/// Inert metadata retained for reconnecting library entries that were backed by Aidoku.
/// Source-list/package URLs and executable bytes are deliberately not carried forward.
struct BackupLegacyAidokuSourceMetadata: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let version: Int
    let languages: [String]
    let originHost: String?
    let contentRatingRawValue: Int
    let isEnabled: Bool
    let order: Int
    let lastUpdated: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, version, languages, originHost, contentRatingRawValue
        case isEnabled, order, lastUpdated
    }

    fileprivate init?(_ source: BackupAidokuInstalledSource) {
        let canonicalID = source.id.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedIDCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_")
        )
        guard !canonicalID.isEmpty,
              canonicalID.utf8.count <= 192,
              canonicalID.unicodeScalars.allSatisfy(allowedIDCharacters.contains) else {
            return nil
        }

        id = canonicalID
        name = Self.boundedString(source.name, maximumUTF8Bytes: 512) ?? canonicalID
        version = Swift.min(Swift.max(0, source.version), Int(Int32.max))
        languages = Array(
            Set(
                source.languages.compactMap {
                    Self.boundedString(
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                        maximumUTF8Bytes: 32
                    )
                }
            )
        ).sorted().prefix(BackupAidokuLegacyWirePolicy.maximumLanguages).map { $0 }
        originHost = Self.safeOriginHost(source.packageURL)
        contentRatingRawValue = min(max(source.contentRatingRawValue, 0), 3)
        isEnabled = source.isEnabled
        order = min(max(source.order, 0), 10_000)
        lastUpdated = source.lastUpdated.flatMap { Self.isSafeDate($0) ? $0 : nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedID = try container.decode(String.self, forKey: .id)
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedIDCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_")
        )
        guard !decodedID.isEmpty,
              decodedID.utf8.count <= 192,
              decodedID.unicodeScalars.allSatisfy(allowedIDCharacters.contains) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Legacy Reader source identity is invalid."
            )
        }
        id = decodedID

        let decodedName = try container.decode(String.self, forKey: .name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decodedName.isEmpty,
              decodedName.utf8.count <= 512,
              !decodedName.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "Legacy Reader source name is invalid."
            )
        }
        name = decodedName

        let decodedVersion = try container.decode(Int.self, forKey: .version)
        guard (0...Int(Int32.max)).contains(decodedVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Legacy Reader source version is invalid."
            )
        }
        version = decodedVersion

        var languageContainer = try container.nestedUnkeyedContainer(forKey: .languages)
        if let count = languageContainer.count,
           count > BackupAidokuLegacyWirePolicy.maximumLanguages {
            throw DecodingError.dataCorruptedError(
                forKey: .languages,
                in: container,
                debugDescription: "Legacy Reader source language list is too large."
            )
        }
        var decodedLanguages: [String] = []
        var seenLanguages = Set<String>()
        let allowedLanguageCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        while !languageContainer.isAtEnd {
            guard decodedLanguages.count < BackupAidokuLegacyWirePolicy.maximumLanguages else {
                throw DecodingError.dataCorruptedError(
                    forKey: .languages,
                    in: container,
                    debugDescription: "Legacy Reader source language list is too large."
                )
            }
            let language = try languageContainer.decode(String.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !language.isEmpty,
                  language.utf8.count <= 32,
                  language.unicodeScalars.allSatisfy(allowedLanguageCharacters.contains) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .languages,
                    in: container,
                    debugDescription: "Legacy Reader source language is invalid."
                )
            }
            if seenLanguages.insert(language).inserted {
                decodedLanguages.append(language)
            }
        }
        languages = decodedLanguages.sorted()

        if let decodedHost = try container.decodeIfPresent(String.self, forKey: .originHost) {
            guard let safeHost = Self.safeStoredOriginHost(decodedHost) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .originHost,
                    in: container,
                    debugDescription: "Legacy Reader source origin host is invalid."
                )
            }
            originHost = safeHost
        } else {
            originHost = nil
        }

        let decodedRating = try container.decode(Int.self, forKey: .contentRatingRawValue)
        guard (0...3).contains(decodedRating) else {
            throw DecodingError.dataCorruptedError(
                forKey: .contentRatingRawValue,
                in: container,
                debugDescription: "Legacy Reader source content rating is invalid."
            )
        }
        contentRatingRawValue = decodedRating
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)

        let decodedOrder = try container.decode(Int.self, forKey: .order)
        guard (0...10_000).contains(decodedOrder) else {
            throw DecodingError.dataCorruptedError(
                forKey: .order,
                in: container,
                debugDescription: "Legacy Reader source order is invalid."
            )
        }
        order = decodedOrder

        let decodedDate = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        guard decodedDate.map(Self.isSafeDate) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .lastUpdated,
                in: container,
                debugDescription: "Legacy Reader source update date is invalid."
            )
        }
        lastUpdated = decodedDate
    }

    var legacyStableKeyPrefix: String {
        "aidoku:\(id):"
    }

    private static func safeOriginHost(_ rawValue: String?) -> String? {
        guard let rawValue,
              rawValue.utf8.count <= 4_096,
              let components = URLComponents(string: rawValue),
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              host.utf8.count <= 253 else { return nil }
        return host
    }

    private static func safeStoredOriginHost(_ rawValue: String) -> String? {
        var candidate = rawValue.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while candidate.hasSuffix(".") { candidate.removeLast() }
        guard !candidate.isEmpty,
              candidate.utf8.count <= 253,
              !candidate.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }),
              !candidate.contains("/"),
              !candidate.contains("?"),
              !candidate.contains("#"),
              !candidate.contains("@") else {
            return nil
        }
        let authority = candidate.contains(":") ? "[\(candidate)]" : candidate
        guard let components = URLComponents(string: "https://\(authority)"),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              components.host?.lowercased() == candidate else {
            return nil
        }
        return candidate
    }

    private static func isSafeDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (-62_135_596_800...253_402_300_799).contains(seconds)
    }

    private static func boundedString(_ value: String, maximumUTF8Bytes: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        if trimmed.utf8.count <= maximumUTF8Bytes { return trimmed }
        var result = ""
        for character in trimmed {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumUTF8Bytes else { break }
            result = candidate
        }
        return result.isEmpty ? nil : result
    }
}

/// The portable Reader Extensions backup envelope. `metadataJSON` is a bounded encoding of
/// `ReaderExtensionBackupSnapshot`; its validation rejects executable, authentication, domain
/// approval, local-file, and content-digest fields before it can enter a backup or cloud state.
struct BackupReaderExtensionState: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let maximumMetadataBytes = 2 * 1_024 * 1_024
    static let maximumInstalledSources = 1_000
    static let maximumRepositories = 100
    static let maximumLegacySources = 512

    var schemaVersion: Int = currentSchemaVersion
    var metadataJSON: Data?
    var installedSourceCount: Int
    var legacyAidokuSources: [BackupLegacyAidokuSourceMetadata]
    var showMatureSources: Bool
    var autoUpdateSources: Bool
    var lastAutoUpdate: Date?

    init(
        metadataJSON: Data?,
        installedSourceCount: Int,
        legacyAidokuSources: [BackupLegacyAidokuSourceMetadata] = [],
        showMatureSources: Bool,
        autoUpdateSources: Bool,
        lastAutoUpdate: Date?
    ) {
        self.metadataJSON = Self.sanitizedMetadataJSON(metadataJSON)
        self.installedSourceCount = min(max(installedSourceCount, 0), Self.maximumInstalledSources)
        self.legacyAidokuSources = Self.sanitizedLegacySources(legacyAidokuSources)
        self.showMatureSources = showMatureSources
        self.autoUpdateSources = autoUpdateSources
        self.lastAutoUpdate = lastAutoUpdate
    }

    var sourceCountForCompatibility: Int {
        min(
            Self.maximumInstalledSources,
            installedSourceCount + legacyAidokuSources.count
        )
    }

    static func migratingLegacyAidoku(_ incoming: BackupAidokuState) -> Self {
        let metadata = sanitizedLegacySources(
            incoming.installedSources.compactMap(BackupLegacyAidokuSourceMetadata.init)
        )
        return Self(
            metadataJSON: nil,
            installedSourceCount: 0,
            legacyAidokuSources: metadata,
            showMatureSources: incoming.showMatureSources,
            autoUpdateSources: incoming.autoUpdateSources,
            lastAutoUpdate: incoming.lastAutoUpdate
        )
    }

    func sanitized() -> Self {
        Self(
            metadataJSON: metadataJSON,
            installedSourceCount: installedSourceCount,
            legacyAidokuSources: legacyAidokuSources,
            showMatureSources: showMatureSources,
            autoUpdateSources: autoUpdateSources,
            lastAutoUpdate: lastAutoUpdate
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, metadataJSON, installedSourceCount, legacyAidokuSources
        case showMatureSources, autoUpdateSources, lastAutoUpdate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        schemaVersion = Self.currentSchemaVersion
        metadataJSON = decodedSchema == Self.currentSchemaVersion
            ? Self.sanitizedMetadataJSON(
                try container.decodeIfPresent(Data.self, forKey: .metadataJSON)
            )
            : nil
        installedSourceCount = min(
            max(try container.decodeIfPresent(Int.self, forKey: .installedSourceCount) ?? 0, 0),
            Self.maximumInstalledSources
        )
        let decodedLegacySources = try container.decodeIfPresent(
            BoundedLegacySources.self,
            forKey: .legacyAidokuSources
        )?.values ?? []
        let sanitizedLegacySources = Self.sanitizedLegacySources(decodedLegacySources)
        guard decodedLegacySources.count <= Self.maximumLegacySources,
              sanitizedLegacySources.count == decodedLegacySources.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .legacyAidokuSources,
                in: container,
                debugDescription: "Legacy Reader source metadata is invalid or too large."
            )
        }
        legacyAidokuSources = sanitizedLegacySources
        showMatureSources = try container.decodeIfPresent(Bool.self, forKey: .showMatureSources) ?? false
        autoUpdateSources = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateSources) ?? true
        lastAutoUpdate = try container.decodeIfPresent(Date.self, forKey: .lastAutoUpdate)
    }

    func encode(to encoder: Encoder) throws {
        let state = sanitized()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(state.metadataJSON, forKey: .metadataJSON)
        try container.encode(state.installedSourceCount, forKey: .installedSourceCount)
        try container.encode(state.legacyAidokuSources, forKey: .legacyAidokuSources)
        try container.encode(state.showMatureSources, forKey: .showMatureSources)
        try container.encode(state.autoUpdateSources, forKey: .autoUpdateSources)
        try container.encodeIfPresent(state.lastAutoUpdate, forKey: .lastAutoUpdate)
    }

    fileprivate static func sanitizedMetadataJSON(_ data: Data?) -> Data? {
        guard let data,
              !data.isEmpty,
              data.count <= maximumMetadataBytes,
              (try? ReaderExtensionJSONPreflight.validate(data, limits: .init(
                  maximumBytes: maximumMetadataBytes,
                  maximumDepth: 18,
                  maximumContainerEntries: maximumInstalledSources,
                  maximumTopLevelEntries: 5,
                  maximumTotalTokens: 256_000,
                  // Decoded metadata strings are capped at 32 KiB below;
                  // allow the bounded expansion introduced by JSON escaping.
                  maximumStringBytes: 64 * 1_024
              ))) != nil,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: [
                  "repositories",
                  "installedSources",
                  "showMatureSources",
                  "autoUpdateSources",
                  "lastAutoUpdate"
              ]),
              (dictionary["repositories"] as? [Any])?.count ?? 0 <= maximumRepositories,
              (dictionary["installedSources"] as? [Any])?.count ?? 0 <= maximumInstalledSources,
              metadataObjectIsSafe(dictionary, depth: 0),
              JSONSerialization.isValidJSONObject(dictionary),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: dictionary,
                  options: [.sortedKeys]
              ),
              canonical.count <= maximumMetadataBytes else {
            return nil
        }
        return canonical
    }

    private static func metadataObjectIsSafe(_ value: Any, depth: Int) -> Bool {
        guard depth <= 16 else { return false }
        if let dictionary = value as? [String: Any] {
            guard dictionary.count <= 256 else { return false }
            for (key, nestedValue) in dictionary {
                guard key.utf8.count <= 128,
                      !isForbiddenMetadataKey(key),
                      sensitiveMetadataFieldIsEmpty(key: key, value: nestedValue),
                      metadataObjectIsSafe(nestedValue, depth: depth + 1) else {
                    return false
                }
            }
            return true
        }
        if let array = value as? [Any] {
            return array.count <= maximumInstalledSources
                && array.allSatisfy { metadataObjectIsSafe($0, depth: depth + 1) }
        }
        if let string = value as? String {
            return string.utf8.count <= 32 * 1_024
        }
        return value is NSNumber || value is NSNull
    }

    private static func isForbiddenMetadataKey(_ key: String) -> Bool {
        switch key.lowercased().replacingOccurrences(of: "_", with: "") {
        case "script", "sourcecode", "code", "payload", "archive", "archivepayload",
             "cookie", "cookies", "secret", "secrets", "authorization", "headers",
             "approveddomains", "approvedhosts", "localfilename", "localpath",
             "contentdigest", "scriptdigest", "packagesha256", "payloadsha256":
            return true
        default:
            return false
        }
    }

    private static func sensitiveMetadataFieldIsEmpty(key: String, value: Any) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "_", with: "")
        if normalized.hasSuffix("contentdigest") || normalized == "declareddomains" {
            if value is NSNull { return true }
            if let array = value as? [Any] { return array.isEmpty }
            return false
        }
        return true
    }

    fileprivate static func sanitizedLegacySources(
        _ sources: [BackupLegacyAidokuSourceMetadata]
    ) -> [BackupLegacyAidokuSourceMetadata] {
        var seen = Set<String>()
        return sources.sorted {
            if $0.order == $1.order { return $0.id < $1.id }
            return $0.order < $1.order
        }.filter {
            seen.insert($0.id).inserted
        }.prefix(maximumLegacySources).map { $0 }
    }

    fileprivate static func decodeLegacySources(
        from data: Data
    ) throws -> [BackupLegacyAidokuSourceMetadata] {
        guard !data.isEmpty, data.count <= maximumMetadataBytes else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Legacy Reader source metadata is too large.")
            )
        }
        let decoded = try JSONDecoder().decode(BoundedLegacySources.self, from: data).values
        let sanitized = sanitizedLegacySources(decoded)
        guard sanitized.count == decoded.count else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Legacy Reader source metadata contains duplicate identities.")
            )
        }
        return sanitized
    }

    private struct BoundedLegacySources: Decodable {
        let values: [BackupLegacyAidokuSourceMetadata]

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            if let count = container.count, count > BackupReaderExtensionState.maximumLegacySources {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Legacy Reader source metadata is too large."
                )
            }
            var decoded: [BackupLegacyAidokuSourceMetadata] = []
            decoded.reserveCapacity(
                Swift.min(
                    container.count ?? 0,
                    BackupReaderExtensionState.maximumLegacySources
                )
            )
            while !container.isAtEnd {
                guard decoded.count < BackupReaderExtensionState.maximumLegacySources else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Legacy Reader source metadata is too large."
                    )
                }
                decoded.append(try container.decode(BackupLegacyAidokuSourceMetadata.self))
            }
            values = decoded
        }
    }
}

#if !os(tvOS)
enum BackupReaderExtensionStateError: LocalizedError {
    case unsafeMetadata
    case unreadableMetadata
    case restoreVerificationFailed

    var errorDescription: String? {
        switch self {
        case .unsafeMetadata:
            return "Reader Extension metadata contained a non-portable or unsafe field."
        case .unreadableMetadata:
            return "Reader Extension metadata could not be decoded."
        case .restoreVerificationFailed:
            return "Reader Extension metadata did not verify after persistence."
        }
    }
}

extension BackupReaderExtensionState {
    static let legacyAidokuSourcesStorageKey = "readerExtensions.legacyAidokuSources.v1"

    init(
        snapshot: ReaderExtensionBackupSnapshot,
        legacyAidokuSources: [BackupLegacyAidokuSourceMetadata] = []
    ) throws {
        guard snapshot.repositories.count <= Self.maximumRepositories,
              snapshot.installedSources.count <= Self.maximumInstalledSources,
              legacyAidokuSources.count <= Self.maximumLegacySources else {
            throw BackupReaderExtensionStateError.unsafeMetadata
        }
        let portableSnapshot = ReaderExtensionBackupSnapshot(
            repositories: snapshot.repositories,
            installedSources: snapshot.installedSources.map { $0.metadataForBackup() },
            showMatureSources: snapshot.showMatureSources,
            autoUpdateSources: snapshot.autoUpdateSources,
            lastAutoUpdate: snapshot.lastAutoUpdate
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(portableSnapshot)
        guard let safeMetadata = Self.sanitizedMetadataJSON(encoded) else {
            throw BackupReaderExtensionStateError.unsafeMetadata
        }
        self.init(
            metadataJSON: safeMetadata,
            installedSourceCount: portableSnapshot.installedSources.count,
            legacyAidokuSources: legacyAidokuSources,
            showMatureSources: portableSnapshot.showMatureSources,
            autoUpdateSources: portableSnapshot.autoUpdateSources,
            lastAutoUpdate: portableSnapshot.lastAutoUpdate
        )
    }

    static func capture(
        from store: UserDefaults,
        preferenceStore: UserDefaults? = nil
    ) throws -> Self {
        let snapshot = try ReaderExtensionPersistence.backupSnapshot(
            from: store,
            preferenceStore: preferenceStore
        )
        let legacySources: [BackupLegacyAidokuSourceMetadata]
        if let data = store.data(forKey: legacyAidokuSourcesStorageKey) {
            do {
                legacySources = try Self.decodeLegacySources(from: data)
            } catch {
                throw BackupReaderExtensionStateError.unreadableMetadata
            }
        } else {
            legacySources = []
        }
        return try Self(snapshot: snapshot, legacyAidokuSources: legacySources)
    }

    func runtimeSnapshot() throws -> ReaderExtensionBackupSnapshot {
        if let metadataJSON {
            guard Self.sanitizedMetadataJSON(metadataJSON) != nil,
                  let decoded = try? JSONDecoder().decode(
                      ReaderExtensionBackupSnapshot.self,
                      from: metadataJSON
                  ) else {
                throw BackupReaderExtensionStateError.unreadableMetadata
            }
            return ReaderExtensionBackupSnapshot(
                repositories: Array(decoded.repositories.prefix(Self.maximumRepositories)),
                installedSources: Array(
                    decoded.installedSources
                        .map { $0.metadataForBackup() }
                        .prefix(Self.maximumInstalledSources)
                ),
                showMatureSources: decoded.showMatureSources,
                autoUpdateSources: decoded.autoUpdateSources,
                lastAutoUpdate: decoded.lastAutoUpdate
            )
        }
        guard installedSourceCount == 0 else {
            throw BackupReaderExtensionStateError.unreadableMetadata
        }
        return ReaderExtensionBackupSnapshot(
            repositories: [],
            installedSources: [],
            showMatureSources: showMatureSources,
            autoUpdateSources: autoUpdateSources,
            lastAutoUpdate: lastAutoUpdate
        )
    }

    /// Portable backups intentionally contain no executable bytes and mark
    /// every source for revalidation. When applying a recurring cloud/manual
    /// snapshot on a device that already has the *same* verified software,
    /// retain only that device-local runtime state. A new device or any change
    /// to code provenance, license, scope, parser configuration, capabilities,
    /// or preference schema remains inert until its repository is revalidated.
    static func mergingVerifiedLocalRuntime(
        into portable: ReaderExtensionBackupSnapshot,
        localSources: [ReaderExtensionInstalledSource]
    ) -> ReaderExtensionBackupSnapshot {
        let localByID = Dictionary(localSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = portable
        result.installedSources = portable.installedSources.map { incoming in
            guard let local = localByID[incoming.id],
                  localRuntimeCanBeRetained(local),
                  runtimeIdentityMatches(incoming, local) else {
                return incoming
            }
            var merged = incoming
            merged.activeContentDigest = local.activeContentDigest
            merged.rollbackContentDigest = local.rollbackContentDigest
            merged.rollbackSourceSnapshot = local.rollbackSourceSnapshot
            merged.declaredDomains = local.declaredDomains
            merged.requiresReinstall = false
            merged.lastError = nil
            return merged
        }
        return result
    }

    private static func localRuntimeCanBeRetained(
        _ source: ReaderExtensionInstalledSource
    ) -> Bool {
        guard !source.requiresReinstall,
              source.implementation != .unsupportedNative,
              source.license.kind.permitsInstallation else { return false }
        if source.implementation == .javascript {
            guard let digest = source.activeContentDigest,
                  digest.count == 64,
                  digest.allSatisfy(\.isHexDigit) else { return false }
        }
        return true
    }

    private static func runtimeIdentityMatches(
        _ incoming: ReaderExtensionInstalledSource,
        _ local: ReaderExtensionInstalledSource
    ) -> Bool {
        func sameURL(_ lhs: URL?, _ rhs: URL?) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none): return true
            case (.some(let lhs), .some(let rhs)):
                return ReaderExtensionURLCanonicalizer.canonicalString(lhs)
                    == ReaderExtensionURLCanonicalizer.canonicalString(rhs)
            default: return false
            }
        }

        return incoming.id == local.id
            && incoming.upstreamID == local.upstreamID
            && incoming.repositoryID == local.repositoryID
            && sameURL(incoming.repositoryURL, local.repositoryURL)
            && sameURL(incoming.baseURL, local.baseURL)
            && sameURL(incoming.apiURL, local.apiURL)
            && sameURL(incoming.sourceCodeURL, local.sourceCodeURL)
            && incoming.language.lowercased() == local.language.lowercased()
            && incoming.languageSelectionVersion == local.languageSelectionVersion
            && incoming.mediaType == local.mediaType
            && incoming.implementation == local.implementation
            && incoming.version == local.version
            && incoming.maturity == local.maturity
            && incoming.license.provenanceFingerprint == local.license.provenanceFingerprint
            && incoming.hasCloudflare == local.hasCloudflare
            && incoming.dateFormat == local.dateFormat
            && incoming.dateFormatLocale == local.dateFormatLocale
            && incoming.additionalParameters == local.additionalParameters
            && incoming.codeProvenanceFingerprint == local.codeProvenanceFingerprint
            && incoming.runtimeCapabilities == local.runtimeCapabilities
            && incoming.preferenceSchemaFingerprint == local.preferenceSchemaFingerprint
            && incoming.secretPreferenceKeys == local.secretPreferenceKeys
    }

    func restore(
        to store: UserDefaults,
        preferenceStore: UserDefaults? = nil,
        postRestoreVerification: (() throws -> Void)? = nil
    ) throws {
        let portableSnapshot = try runtimeSnapshot()
        let localSources: [ReaderExtensionInstalledSource]
        if let persisted = try? ReaderExtensionPersistence.loadInstalledSources(from: store),
           let contentStore = try? ReaderExtensionContentStore() {
            // Reuse the runtime's exact-byte/shape reconciliation before any
            // local state is treated as trusted. Missing/corrupt JS or invalid
            // metadata becomes inert instead of being carried through sync.
            localSources = ReaderExtensionPersistence.reconcileExecutableContent(
                persisted,
                contentStore: contentStore
            ).sources
        } else {
            localSources = []
        }
        let legacy = Self.sanitizedLegacySources(legacyAidokuSources)
        let encodedLegacy = try JSONEncoder().encode(legacy)
        guard encodedLegacy.count <= Self.maximumMetadataBytes else {
            throw BackupReaderExtensionStateError.unsafeMetadata
        }

        let metadataKeys = [
            ReaderExtensionPersistence.repositoriesKey,
            ReaderExtensionPersistence.installedSourcesKey,
            Self.legacyAidokuSourcesStorageKey
        ]
        let global = UserDefaults.standard
        let globalKeys = [
            ReaderExtensionPersistence.showMatureSourcesKey,
            ReaderExtensionPersistence.autoUpdateSourcesKey,
            ReaderExtensionPersistence.lastAutoUpdateKey
        ]
        let previousMetadataValues = metadataKeys.map { ($0, store.object(forKey: $0)) }
        let previousGlobalValues = globalKeys.map { ($0, global.object(forKey: $0)) }
        let previousPreferenceOverlay = preferenceStore.map {
            (
                data: $0.object(forKey: ReaderExtensionPersistence.preferenceOverlayKey),
                marker: $0.object(forKey: ReaderExtensionPersistence.preferenceOverlayMigrationKey)
            )
        }
        do {
            try ReaderExtensionPersistence.restorePortableMetadata(
                portableSnapshot,
                retainingVerifiedRuntimeFrom: localSources,
                to: store,
                preferenceStore: preferenceStore
            )
            if legacy.isEmpty {
                store.removeObject(forKey: Self.legacyAidokuSourcesStorageKey)
            } else {
                store.set(encodedLegacy, forKey: Self.legacyAidokuSourcesStorageKey)
            }
            let verification = try ReaderExtensionPersistence.backupSnapshot(
                from: store,
                preferenceStore: preferenceStore
            )
            let expected = try Self(
                snapshot: portableSnapshot,
                legacyAidokuSources: legacy
            ).runtimeSnapshot()
            let restoredLegacy: [BackupLegacyAidokuSourceMetadata]
            if let data = store.data(forKey: Self.legacyAidokuSourcesStorageKey) {
                restoredLegacy = try Self.decodeLegacySources(from: data)
            } else {
                restoredLegacy = []
            }
            guard ReaderExtensionPersistence.metadataSnapshotsArePersistenceEquivalent(
                verification,
                expected
            ),
                  Self.sanitizedLegacySources(restoredLegacy) == legacy else {
                throw BackupReaderExtensionStateError.restoreVerificationFailed
            }
            try postRestoreVerification?()
        } catch {
            for (key, value) in previousMetadataValues {
                if let value {
                    store.set(value, forKey: key)
                } else {
                    store.removeObject(forKey: key)
                }
            }
            for (key, value) in previousGlobalValues {
                if let value {
                    global.set(value, forKey: key)
                } else {
                    global.removeObject(forKey: key)
                }
            }
            if let preferenceStore, let previousPreferenceOverlay {
                if let value = previousPreferenceOverlay.data {
                    preferenceStore.set(value, forKey: ReaderExtensionPersistence.preferenceOverlayKey)
                } else {
                    preferenceStore.removeObject(forKey: ReaderExtensionPersistence.preferenceOverlayKey)
                }
                if let value = previousPreferenceOverlay.marker {
                    preferenceStore.set(value, forKey: ReaderExtensionPersistence.preferenceOverlayMigrationKey)
                } else {
                    preferenceStore.removeObject(forKey: ReaderExtensionPersistence.preferenceOverlayMigrationKey)
                }
            }
            _ = store.synchronize()
            _ = global.synchronize()
            if let preferenceStore { _ = preferenceStore.synchronize() }
            throw error
        }
    }
}

struct ReaderExtensionLegacyItemReference: Identifiable, Hashable, Sendable {
    let legacySourceID: String
    let legacyItemKey: String
    let title: String?
    let author: String?
    let coverURL: String?
    let occurrenceCount: Int

    var id: String {
        ReaderExtensionAidokuMigration.legacyStableKey(
            sourceID: legacySourceID,
            itemKey: legacyItemKey
        )
    }
}

struct ReaderExtensionLegacyReconnectCandidate: Identifiable, Hashable, Sendable {
    let legacySource: BackupLegacyAidokuSourceMetadata
    let installedSource: ReaderExtensionInstalledSource
    let matchesUpstreamSourceID: Bool
    let matchesOriginHost: Bool
    let matchesLanguage: Bool
    let matchesSourceName: Bool

    var id: String {
        "\(legacySource.id)->\(installedSource.id.rawValue)"
    }

    /// Automatic source mapping is deliberately conservative. Item mapping still requires
    /// an explicit canonical-key/detail verifier before any durable route is changed.
    var isStrongUniqueMatchCandidate: Bool {
        matchesUpstreamSourceID && matchesOriginHost && matchesLanguage
    }
}

struct ReaderExtensionLegacyItemResolution: Hashable, Sendable {
    let legacyItemKey: String
    let readerExtensionItemKey: String

    init(legacyItemKey: String, readerExtensionItemKey: String) {
        self.legacyItemKey = legacyItemKey
        self.readerExtensionItemKey = readerExtensionItemKey
    }
}

/// What a verifier learned about one legacy title. `absent` is a definitive
/// answer — the replacement source responded and does not carry the title — so
/// its route is kept and marked unavailable rather than blocking the whole
/// source. `interrupted` means the source could not answer at all right now, so
/// a later attempt can still succeed and nothing may be committed yet.
enum ReaderExtensionLegacyItemVerification: Hashable, Sendable {
    case resolved(String)
    case absent
    case interrupted
}

struct ReaderExtensionLegacyReconnectProgress: Equatable, Sendable {
    let checked: Int
    let total: Int
    let resolved: Int
}

struct ReaderExtensionLegacyReconnectReport: Equatable, Sendable {
    let legacySourceID: String
    let installedSourceID: ReaderExtensionSourceID
    let itemCount: Int
    let routeCount: Int
    let changedStoreCount: Int
    /// The legacy item keys deliberately left as `aidoku` routes because the
    /// replacement source answered that it does not carry them. The caller
    /// needs the keys, not just the count, to mark exactly those titles as
    /// confirmed absent rather than merely not-yet-reconnected.
    let retainedItemKeys: Set<String>

    var retainedItemCount: Int { retainedItemKeys.count }

    init(
        legacySourceID: String,
        installedSourceID: ReaderExtensionSourceID,
        itemCount: Int,
        routeCount: Int,
        changedStoreCount: Int,
        retainedItemKeys: Set<String> = []
    ) {
        self.legacySourceID = legacySourceID
        self.installedSourceID = installedSourceID
        self.itemCount = itemCount
        self.routeCount = routeCount
        self.changedStoreCount = changedStoreCount
        self.retainedItemKeys = retainedItemKeys
    }
}

enum ReaderExtensionLegacyReconnectError: LocalizedError {
    case unreadableProfileRoster
    case unreadableStore(String)
    case storeTooLarge(String)
    case invalidSourceIdentity
    case installedSourceNotFound
    case itemVerificationRequired(String)
    case itemVerificationInterrupted(resolved: Int, remaining: Int)
    case noItemsResolved
    case conflictingItemResolution(String)
    case storeChangedDuringVerification(String)
    case rewriteVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableProfileRoster:
            return "Reader source reconnection is paused because the profile roster is unreadable."
        case .unreadableStore(let label):
            return "Reader source reconnection is paused because \(label) is unreadable."
        case .storeTooLarge(let label):
            return "Reader source reconnection is paused because \(label) exceeds the safety limit."
        case .invalidSourceIdentity:
            return "The selected Reader source has an invalid identity."
        case .installedSourceNotFound:
            return "The selected Reader source is no longer installed."
        case .itemVerificationRequired:
            return "Every legacy title must be verified against the replacement source before reconnecting."
        case .itemVerificationInterrupted(let resolved, let remaining):
            return "The replacement source stopped answering with \(remaining) title\(remaining == 1 ? "" : "s") left to check. \(resolved) already matched and \(resolved == 1 ? "was" : "were") saved, so trying again picks up where this left off."
        case .noItemsResolved:
            return "None of the saved titles could be found on the replacement source, so nothing was changed."
        case .conflictingItemResolution:
            return "The replacement source returned conflicting title identities."
        case .storeChangedDuringVerification:
            return "Reader data changed while the source was being verified. Try reconnecting again."
        case .rewriteVerificationFailed:
            return "The reconnected Reader data could not be verified, so the original data was restored."
        }
    }

    /// Progress survives these, so the caller should invite a retry rather than
    /// report the source as permanently unmigratable.
    var isResumable: Bool {
        switch self {
        case .itemVerificationInterrupted, .storeChangedDuringVerification:
            return true
        default:
            return false
        }
    }
}

/// A format-preserving, model-independent route transformer used by migration and tests.
/// It only rewrites dictionaries in a `route` field (or an exact top-level route object),
/// plus the separate Reader download `provider` metadata. Stable IDs and `routeKey` fields
/// are never rewritten.
enum ReaderExtensionLegacyRouteRewriter {
    /// What to do with a route whose legacy item key has no verified
    /// replacement. `require` is the original all-or-nothing contract. `retain`
    /// leaves that route byte-identical so a source where a handful of titles
    /// no longer exist can still migrate the rest; the retained routes stay
    /// `aidoku` and are marked unavailable by the migration rescan.
    enum UnresolvedItemPolicy: Hashable, Sendable {
        case require
        case retain
    }

    struct Mapping: Hashable, Sendable {
        let legacySourceID: String
        let installedSourceID: ReaderExtensionSourceID
        let itemKeys: [String: String]
        let mediaType: ReaderExtensionMediaType
        let unresolvedItems: UnresolvedItemPolicy

        init(
            legacySourceID: String,
            installedSourceID: ReaderExtensionSourceID,
            itemKeys: [String: String],
            mediaType: ReaderExtensionMediaType,
            unresolvedItems: UnresolvedItemPolicy = .require
        ) {
            self.legacySourceID = legacySourceID
            self.installedSourceID = installedSourceID
            self.itemKeys = itemKeys
            self.mediaType = mediaType
            self.unresolvedItems = unresolvedItems
        }
    }

    struct Result: Sendable {
        let data: Data
        let routeCount: Int
        let providerCount: Int
        let retainedCount: Int

        init(data: Data, routeCount: Int, providerCount: Int, retainedCount: Int = 0) {
            self.data = data
            self.routeCount = routeCount
            self.providerCount = providerCount
            self.retainedCount = retainedCount
        }
    }

    private static let maximumDocumentBytes = 32 * 1_024 * 1_024
    private static let maximumDepth = 64
    private static let maximumContainerEntries = 20_256
    private static let maximumTotalTokens = 1_000_000
    private static let maximumStringBytes = 64 * 1_024
    private static let maximumItemKeyBytes = 8 * 1_024

    static func references(
        in data: Data,
        legacySourceID: String? = nil
    ) throws -> [ReaderExtensionLegacyItemReference] {
        let object = try decodedObject(from: data, label: "Reader metadata")
        return try references(in: object, legacySourceID: legacySourceID)
    }

    private static func references(
        in object: Any,
        legacySourceID: String? = nil
    ) throws -> [ReaderExtensionLegacyItemReference] {
        var occurrences: [(sourceID: String, itemKey: String, title: String?, author: String?, coverURL: String?)] = []
        try collectReferences(
            from: object,
            parentKey: nil,
            enclosingDictionary: nil,
            legacySourceID: legacySourceID,
            depth: 0,
            into: &occurrences
        )

        var grouped: [String: ReaderExtensionLegacyItemReference] = [:]
        for occurrence in occurrences {
            let stableKey = ReaderExtensionAidokuMigration.legacyStableKey(
                sourceID: occurrence.sourceID,
                itemKey: occurrence.itemKey
            )
            if let existing = grouped[stableKey] {
                grouped[stableKey] = ReaderExtensionLegacyItemReference(
                    legacySourceID: existing.legacySourceID,
                    legacyItemKey: existing.legacyItemKey,
                    title: existing.title ?? occurrence.title,
                    author: existing.author ?? occurrence.author,
                    coverURL: existing.coverURL ?? occurrence.coverURL,
                    occurrenceCount: existing.occurrenceCount + 1
                )
            } else {
                grouped[stableKey] = ReaderExtensionLegacyItemReference(
                    legacySourceID: occurrence.sourceID,
                    legacyItemKey: occurrence.itemKey,
                    title: occurrence.title,
                    author: occurrence.author,
                    coverURL: occurrence.coverURL,
                    occurrenceCount: 1
                )
            }
        }
        return grouped.values.sorted { lhs, rhs in
            if lhs.legacySourceID == rhs.legacySourceID {
                return lhs.legacyItemKey < rhs.legacyItemKey
            }
            return lhs.legacySourceID < rhs.legacySourceID
        }
    }

    static func rewrite(_ data: Data, mapping: Mapping) throws -> Result {
        guard mapping.installedSourceID.isValid,
              !mapping.legacySourceID.isEmpty,
              !mapping.itemKeys.isEmpty else {
            throw ReaderExtensionLegacyReconnectError.invalidSourceIdentity
        }
        let object = try decodedObject(from: data, label: "Reader metadata")
        var routeCount = 0
        var providerCount = 0
        var retainedCount = 0
        let rewritten = try rewriteValue(
            object,
            parentKey: nil,
            mapping: mapping,
            depth: 0,
            routeCount: &routeCount,
            providerCount: &providerCount,
            retainedCount: &retainedCount
        )
        guard JSONSerialization.isValidJSONObject(rewritten) else {
            throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed("Reader metadata")
        }
        let encoded = try JSONSerialization.data(withJSONObject: rewritten, options: [.sortedKeys])
        guard encoded.count <= maximumDocumentBytes else {
            throw ReaderExtensionLegacyReconnectError.storeTooLarge("Reader metadata")
        }
        // Under `.retain` some legacy routes are meant to survive, but only the
        // ones with no *usable* replacement — which includes a mapped key the
        // credential guard rejected. Anything else still here means the walk
        // missed a route it was asked to rewrite.
        let remaining = try references(in: encoded, legacySourceID: mapping.legacySourceID)
        let unexpected = remaining.filter {
            validatedMappedItemKey(
                mapping.itemKeys[$0.legacyItemKey],
                legacyItemKey: $0.legacyItemKey
            ) != nil
        }
        guard unexpected.isEmpty,
              mapping.unresolvedItems == .retain || remaining.isEmpty else {
            throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed("Reader metadata")
        }
        return Result(
            data: encoded,
            routeCount: routeCount,
            providerCount: providerCount,
            retainedCount: retainedCount
        )
    }

    static func validate(_ data: Data, label: String) throws {
        let object = try decodedObject(from: data, label: label)
        _ = try references(in: object)
    }

    private static func decodedObject(from data: Data, label: String) throws -> Any {
        guard !data.isEmpty else {
            throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
        }
        guard data.count <= maximumDocumentBytes else {
            throw ReaderExtensionLegacyReconnectError.storeTooLarge(label)
        }
        do {
            try ReaderExtensionJSONPreflight.validate(data, limits: .init(
                maximumBytes: maximumDocumentBytes,
                maximumDepth: maximumDepth,
                maximumContainerEntries: maximumContainerEntries,
                maximumTopLevelEntries: maximumContainerEntries,
                maximumTotalTokens: maximumTotalTokens,
                maximumStringBytes: maximumStringBytes
            ))
        } catch ReaderExtensionError.contentTooLarge {
            throw ReaderExtensionLegacyReconnectError.storeTooLarge(label)
        } catch {
            throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
        }
    }

    private static func collectReferences(
        from value: Any,
        parentKey: String?,
        enclosingDictionary: [String: Any]?,
        legacySourceID: String?,
        depth: Int,
        into output: inout [(
            sourceID: String,
            itemKey: String,
            title: String?,
            author: String?,
            coverURL: String?
        )]
    ) throws {
        guard depth <= maximumDepth else {
            throw ReaderExtensionLegacyReconnectError.unreadableStore("Reader metadata")
        }
        if let dictionary = value as? [String: Any] {
            if isRoutePosition(parentKey: parentKey, dictionary: dictionary),
               let identity = legacyIdentity(in: dictionary),
               legacySourceID == nil || identity.sourceID == legacySourceID {
                output.append((
                    identity.sourceID,
                    identity.itemKey,
                    boundedContextString(enclosingDictionary?["title"])
                        ?? boundedContextString(enclosingDictionary?["mangaTitle"]),
                    boundedContextString(enclosingDictionary?["author"]),
                    boundedContextString(enclosingDictionary?["coverURL"])
                        ?? boundedContextString(enclosingDictionary?["cover"])
                ))
            }
            for (key, nested) in dictionary {
                try collectReferences(
                    from: nested,
                    parentKey: key,
                    enclosingDictionary: dictionary,
                    legacySourceID: legacySourceID,
                    depth: depth + 1,
                    into: &output
                )
            }
        } else if let array = value as? [Any] {
            for nested in array {
                try collectReferences(
                    from: nested,
                    parentKey: parentKey,
                    enclosingDictionary: enclosingDictionary,
                    legacySourceID: legacySourceID,
                    depth: depth + 1,
                    into: &output
                )
            }
        }
    }

    private static func rewriteValue(
        _ value: Any,
        parentKey: String?,
        mapping: Mapping,
        depth: Int,
        routeCount: inout Int,
        providerCount: inout Int,
        retainedCount: inout Int
    ) throws -> Any {
        guard depth <= maximumDepth else {
            throw ReaderExtensionLegacyReconnectError.unreadableStore("Reader metadata")
        }
        if var dictionary = value as? [String: Any] {
            if isRoutePosition(parentKey: parentKey, dictionary: dictionary),
               let identity = legacyIdentity(in: dictionary),
               identity.sourceID == mapping.legacySourceID {
                guard let newItemKey = validatedMappedItemKey(
                    mapping.itemKeys[identity.itemKey],
                    legacyItemKey: identity.itemKey
                ) else {
                    guard mapping.unresolvedItems == .retain else {
                        throw ReaderExtensionLegacyReconnectError.itemVerificationRequired(identity.itemKey)
                    }
                    retainedCount += 1
                    return dictionary
                }
                routeCount += 1
                var rewritten: [String: Any] = [
                    "kind": "readerExtension",
                    "source": mapping.installedSourceID.rawValue,
                    "itemKey": newItemKey
                ]
                // MangaContentRoute's decoder throws on a legacyStableKey that
                // is not trimmed, bounded and control-character free, and a
                // throw there quarantines the whole library store on the next
                // launch. The old Aidoku identifiers are unvalidated, so a key
                // that cannot round-trip is omitted; stableKey then falls back
                // to the readerExtension spelling, which loses nothing.
                if let legacyStableKey = ReaderExtensionAidokuMigration.persistableLegacyStableKey(
                    sourceID: identity.sourceID,
                    itemKey: identity.itemKey
                ) {
                    rewritten["legacyStableKey"] = legacyStableKey
                }
                return rewritten
            }

            if parentKey == "provider",
               let identity = legacyIdentity(in: dictionary),
               identity.sourceID == mapping.legacySourceID {
                if let newItemKey = validatedMappedItemKey(
                    mapping.itemKeys[identity.itemKey],
                    legacyItemKey: identity.itemKey
                ) {
                    dictionary["kind"] = "readerExtension"
                    dictionary["sourceId"] = mapping.installedSourceID.rawValue
                    dictionary["mangaKey"] = newItemKey
                    dictionary["isNovel"] = mapping.mediaType == .novel
                    providerCount += 1
                } else {
                    guard mapping.unresolvedItems == .retain else {
                        throw ReaderExtensionLegacyReconnectError.itemVerificationRequired(identity.itemKey)
                    }
                    retainedCount += 1
                }
            }

            for (key, nested) in dictionary {
                dictionary[key] = try rewriteValue(
                    nested,
                    parentKey: key,
                    mapping: mapping,
                    depth: depth + 1,
                    routeCount: &routeCount,
                    providerCount: &providerCount,
                    retainedCount: &retainedCount
                )
            }
            return dictionary
        }
        if let array = value as? [Any] {
            return try array.map {
                try rewriteValue(
                    $0,
                    parentKey: parentKey,
                    mapping: mapping,
                    depth: depth + 1,
                    routeCount: &routeCount,
                    providerCount: &providerCount,
                    retainedCount: &retainedCount
                )
            }
        }
        return value
    }

    private static func isRoutePosition(
        parentKey: String?,
        dictionary: [String: Any]
    ) -> Bool {
        if parentKey == "route" { return true }
        guard parentKey == nil else { return false }
        let routeKeys = Set(["kind", "sourceId", "mangaKey"])
        return Set(dictionary.keys).isSubset(of: routeKeys)
    }

    private static func legacyIdentity(
        in dictionary: [String: Any]
    ) -> (sourceID: String, itemKey: String)? {
        guard dictionary["kind"] as? String == "aidoku",
              let sourceID = boundedIdentityString(dictionary["sourceId"]),
              let itemKey = boundedIdentityString(dictionary["mangaKey"]) else {
            return nil
        }
        return (sourceID, itemKey)
    }

    private static func boundedIdentityString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumItemKeyBytes else { return nil }
        return trimmed
    }

    private static func validatedMappedItemKey(
        _ value: String?,
        legacyItemKey: String
    ) -> String? {
        guard let value = boundedIdentityString(value) else { return nil }
        // Reject a resolver accidentally returning a complete stable key instead of the
        // provider's canonical item key.
        guard value != ReaderExtensionAidokuMigration.legacyStableKey(
            sourceID: "",
            itemKey: legacyItemKey
        ), !value.hasPrefix("aidoku:") else { return nil }
        // Reconnect rewrites the provider-facing item key into ordinary
        // library, progress, tracker, and download metadata. Apply the same
        // credential-bearing URL guard used for newly discovered items so a
        // provider cannot persist userinfo or signed/token query values while
        // the separate legacyStableKey continues to preserve the exact old
        // `aidoku:<source>:<item>` identity.
        return ReaderExtensionSecurityPolicy.persistableProviderContentKey(value)
    }

    private static func boundedContextString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(2_048))
    }
}

/// A resumable record of what the replacement source has already said about each
/// legacy title. Verifying one title costs up to eight sequential provider
/// requests, so a 200-title source is ~1,600 of them; before this existed a
/// single rate limit part-way through discarded every already-matched title and
/// the retry started from zero.
///
/// Nothing here is authoritative. Every cached key is revalidated by
/// `ReaderExtensionLegacyRouteRewriter.validatedMappedItemKey` before it can
/// reach a route, and an unreadable ledger is discarded rather than quarantined
/// — losing a cache only costs time, so it must never be able to block a
/// migration the way an unreadable store does.
struct ReaderExtensionReconnectLedger: Codable, Equatable, Sendable {
    struct SourceRecord: Codable, Equatable, Sendable {
        var resolved: [String: String] = [:]
        var absent: [String: Date] = [:]
        var interruptions: [String: Int] = [:]
        /// The exact executable these answers came from. `ReaderExtensionSourceID`
        /// is a hash of repository, upstream id, language and media type, so it
        /// survives version bumps, reinstalls and the automatic rollback a
        /// runtime failure triggers — replaying a v1.4 mapping onto v1.3 would
        /// repoint the library at keys that source cannot open.
        var sourceFingerprint: String?
        var updatedAt = Date(timeIntervalSince1970: 0)

        var entryCount: Int { resolved.count + absent.count + interruptions.count }
    }

    var records: [String: SourceRecord] = [:]
}

enum ReaderExtensionReconnectLedgerStore {
    static let storageBase = "readerExtensions.legacyReconnectLedger.v1"
    static let maximumPairs = 32
    static let maximumEntriesPerPair = 20_000
    static let maximumKeyBytes = 8 * 1_024
    /// A title missing today can be added tomorrow, so a definitive "absent"
    /// only suppresses re-checking for a week.
    static let absentRecheckInterval: TimeInterval = 7 * 24 * 60 * 60

    struct Handle {
        let defaults: UserDefaults
        let profileID: UUID

        init(defaults: UserDefaults, profileID: UUID) {
            self.defaults = defaults
            self.profileID = profileID
        }
    }

    static func storageKey(for profileID: UUID) -> String {
        ProfileScopedStorage.defaultsKey(base: storageBase, profileID: profileID)
    }

    static func pairKey(
        legacySourceID: String,
        installedSourceID: ReaderExtensionSourceID
    ) -> String {
        "\(legacySourceID)\u{001F}\(installedSourceID.rawValue)"
    }

    static func load(from store: UserDefaults, profileID: UUID) -> ReaderExtensionReconnectLedger {
        guard let data = store.data(forKey: storageKey(for: profileID)), !data.isEmpty else {
            return ReaderExtensionReconnectLedger()
        }
        guard let decoded = try? JSONDecoder().decode(
            ReaderExtensionReconnectLedger.self,
            from: data
        ) else {
            ReaderLogger.shared.log(
                "ReaderExtensionReconnectLedger: discarded an unreadable verification cache; titles will be rechecked",
                type: "Reader"
            )
            return ReaderExtensionReconnectLedger()
        }
        return decoded
    }

    static func fingerprint(of source: ReaderExtensionInstalledSource) -> String {
        "\(source.version)\u{001F}\(source.activeContentDigest ?? "")"
    }

    static func record(
        in ledger: ReaderExtensionReconnectLedger,
        legacySourceID: String,
        installedSourceID: ReaderExtensionSourceID,
        matching installedSource: ReaderExtensionInstalledSource? = nil
    ) -> ReaderExtensionReconnectLedger.SourceRecord {
        let key = pairKey(legacySourceID: legacySourceID, installedSourceID: installedSourceID)
        guard let stored = ledger.records[key] else {
            return ReaderExtensionReconnectLedger.SourceRecord()
        }
        guard let installedSource else { return stored }
        guard stored.sourceFingerprint == fingerprint(of: installedSource) else {
            ReaderLogger.shared.log(
                "ReaderExtensionReconnectLedger: dropped cached verifications from a different build of the replacement source",
                type: "Reader"
            )
            return ReaderExtensionReconnectLedger.SourceRecord()
        }
        return stored
    }

    static func isKnownAbsent(
        _ legacyItemKey: String,
        in record: ReaderExtensionReconnectLedger.SourceRecord,
        now: Date = Date()
    ) -> Bool {
        guard let checkedAt = record.absent[legacyItemKey] else { return false }
        let age = now.timeIntervalSince(checkedAt)
        return age >= 0 && age < absentRecheckInterval
    }

    @discardableResult
    static func save(
        _ record: ReaderExtensionReconnectLedger.SourceRecord,
        legacySourceID: String,
        installedSourceID: ReaderExtensionSourceID,
        matching installedSource: ReaderExtensionInstalledSource? = nil,
        using handle: Handle,
        now: Date = Date()
    ) -> Bool {
        var ledger = load(from: handle.defaults, profileID: handle.profileID)
        var stamped = bounded(record)
        stamped.updatedAt = now
        if let installedSource { stamped.sourceFingerprint = fingerprint(of: installedSource) }
        let key = pairKey(legacySourceID: legacySourceID, installedSourceID: installedSourceID)
        if stamped.entryCount == 0 {
            ledger.records[key] = nil
        } else {
            ledger.records[key] = stamped
        }
        if ledger.records.count > maximumPairs {
            let survivors = ledger.records
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(maximumPairs)
            ledger.records = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        }
        let storageKey = storageKey(for: handle.profileID)
        guard !ledger.records.isEmpty else {
            handle.defaults.removeObject(forKey: storageKey)
            return true
        }
        guard let data = try? JSONEncoder().encode(ledger) else {
            ReaderLogger.shared.log(
                "ReaderExtensionReconnectLedger: could not encode the verification cache; the next attempt restarts",
                type: "Reader"
            )
            return false
        }
        handle.defaults.set(data, forKey: storageKey)
        return true
    }

    static func forget(
        legacySourceID: String,
        installedSourceID: ReaderExtensionSourceID,
        using handle: Handle
    ) {
        save(
            ReaderExtensionReconnectLedger.SourceRecord(),
            legacySourceID: legacySourceID,
            installedSourceID: installedSourceID,
            using: handle
        )
    }

    private static func bounded(
        _ record: ReaderExtensionReconnectLedger.SourceRecord
    ) -> ReaderExtensionReconnectLedger.SourceRecord {
        var trimmed = record
        trimmed.resolved = trimmed.resolved.filter { isStorableKey($0.key) && isStorableKey($0.value) }
        trimmed.absent = trimmed.absent.filter { isStorableKey($0.key) }
        trimmed.interruptions = trimmed.interruptions.filter { isStorableKey($0.key) && $0.value > 0 }
        // Resolved keys are the expensive ones to rediscover, so the retry
        // counters and then the absent entries give way first when a
        // pathological store overflows the bound.
        if trimmed.entryCount > maximumEntriesPerPair {
            trimmed.interruptions = [:]
        }
        if trimmed.entryCount > maximumEntriesPerPair {
            let absentBudget = max(0, maximumEntriesPerPair - trimmed.resolved.count)
            trimmed.absent = Dictionary(
                uniqueKeysWithValues: trimmed.absent
                    .sorted { $0.value > $1.value }
                    .prefix(absentBudget)
                    .map { ($0.key, $0.value) }
            )
        }
        if trimmed.resolved.count > maximumEntriesPerPair {
            trimmed.resolved = Dictionary(
                uniqueKeysWithValues: trimmed.resolved
                    .sorted { $0.key < $1.key }
                    .prefix(maximumEntriesPerPair)
                    .map { ($0.key, $0.value) }
            )
            trimmed.absent = [:]
        }
        return trimmed
    }

    private static func isStorableKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumKeyBytes
    }
}

/// A bounded write-ahead journal for the multi-store reconnect transaction. The journal is
/// durably written and re-read before any store changes. If the process stops mid-transaction,
/// recovery rolls a prepared transaction back or a committed transaction forward, but only
/// after confirming every current value is a recorded original or replacement.
enum ReaderExtensionReconnectTransactionJournal {
    private enum Phase: String, Codable {
        case prepared
        case committed
    }

    enum Value: Codable, Equatable, Sendable {
        case absent
        case data(Data)
        case string(String)
    }

    enum Location: Codable, Hashable, Sendable {
        case standardDefaults(key: String)
        case file(path: String)
        case metadataDefaults(scope: String, key: String)
    }

    struct Entry: Codable, Equatable, Sendable {
        let location: Location
        let original: Value
        let replacement: Value
    }

    private struct Record: Codable {
        let schemaVersion: Int
        let transactionID: UUID
        let createdAt: Date
        let phase: Phase
        let entries: [Entry]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case transactionID
            case createdAt
            case phase
            case entries
        }

        init(
            schemaVersion: Int,
            transactionID: UUID,
            createdAt: Date,
            phase: Phase,
            entries: [Entry]
        ) {
            self.schemaVersion = schemaVersion
            self.transactionID = transactionID
            self.createdAt = createdAt
            self.phase = phase
            self.entries = entries
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            transactionID = try container.decode(UUID.self, forKey: .transactionID)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            entries = try container.decode([Entry].self, forKey: .entries)
            // Version 1 journals predate the commit marker. Treating them as prepared
            // preserves their original fail-safe rollback behavior.
            phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .prepared
        }
    }

    static let maximumJournalBytes = 128 * 1_024 * 1_024
    static let maximumEntryCount = 20_256
    private static let maximumLocationBytes = 4 * 1_024
    private static let maximumStringBytes = 16 * 1_024
    private static let maximumValueBytes = 32 * 1_024 * 1_024

    static func prepare(entries: [Entry], at url: URL) throws {
        guard !entries.isEmpty, entries.count <= maximumEntryCount,
              Set(entries.map(\.location)).count == entries.count else {
            throw ReaderExtensionLegacyReconnectError.storeTooLarge(
                "Reader reconnect transaction"
            )
        }
        try validate(entries)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ReaderExtensionLegacyReconnectError.storeChangedDuringVerification(
                "Reader reconnect transaction"
            )
        }

        let record = Record(
            schemaVersion: 2,
            transactionID: UUID(),
            createdAt: Date(),
            phase: .prepared,
            entries: entries
        )

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protectedDirectory.setResourceValues(values)
        do {
            try write(record, at: url)
            let persisted = try loadRecord(at: url)
            guard persisted.transactionID == record.transactionID,
                  persisted.phase == .prepared,
                  persisted.entries == entries else {
                throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                    "Reader reconnect transaction"
                )
            }
        } catch let error as ReaderExtensionLegacyReconnectError {
            try? FileManager.default.removeItem(at: url)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                "Reader reconnect transaction"
            )
        }
    }

    /// Durably records the transaction decision before its final target checkpoint. If the
    /// process stops after this marker reaches disk, recovery completes every replacement;
    /// without it, recovery restores every original value.
    static func markCommitted(at url: URL) throws {
        let record = try loadRecord(at: url)
        if record.phase == .committed { return }
        let committed = Record(
            schemaVersion: 2,
            transactionID: record.transactionID,
            createdAt: record.createdAt,
            phase: .committed,
            entries: record.entries
        )
        do {
            try write(committed, at: url)
            let persisted = try loadRecord(at: url)
            guard persisted.transactionID == committed.transactionID,
                  persisted.phase == .committed,
                  persisted.entries == committed.entries else {
                throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                    "Reader reconnect transaction"
                )
            }
        } catch let error as ReaderExtensionLegacyReconnectError {
            throw error
        } catch {
            throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                "Reader reconnect transaction"
            )
        }
    }

    static func recoverIfPresent(
        at url: URL,
        read: (Location) throws -> Value,
        apply: (Value, Location) throws -> Void
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let record = try loadRecord(at: url)

        // Validate the entire transaction before touching a single location.
        for entry in record.entries {
            let current = try read(entry.location)
            guard current == entry.original || current == entry.replacement else {
                throw ReaderExtensionLegacyReconnectError.storeChangedDuringVerification(
                    "Reader reconnect transaction"
                )
            }
        }
        let shouldCommit = record.phase == .committed
        let orderedEntries = shouldCommit ? record.entries : Array(record.entries.reversed())
        for entry in orderedEntries {
            let destination = shouldCommit ? entry.replacement : entry.original
            // Re-check at the write boundary as well as in the all-or-nothing preflight.
            // This refuses a newly introduced third state instead of overwriting it with a
            // stale journal value.
            let current = try read(entry.location)
            guard current == entry.original || current == entry.replacement else {
                throw ReaderExtensionLegacyReconnectError.storeChangedDuringVerification(
                    "Reader reconnect transaction"
                )
            }
            if current != destination {
                try apply(destination, entry.location)
            }
        }
        for entry in record.entries {
            let destination = shouldCommit ? entry.replacement : entry.original
            guard try read(entry.location) == destination else {
                throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                    "Reader reconnect transaction"
                )
            }
        }
        // `apply` is required to durably checkpoint its target. Consequently, once every
        // destination has been re-read, removing and fsyncing the journal cannot expose a
        // mixed transaction after a restart.
        try clear(at: url)
        return true
    }

    private static func loadRecord(at url: URL) throws -> Record {
        let data: Data
        do {
            data = try BoundedLocalStoreReader.read(
                from: url,
                maximumBytes: maximumJournalBytes
            )
        } catch {
            throw ReaderExtensionLegacyReconnectError.unreadableStore(
                "Reader reconnect transaction"
            )
        }
        return try decodeAndValidate(data)
    }

    private static func write(_ record: Record, at url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        guard data.count <= maximumJournalBytes else {
            throw ReaderExtensionLegacyReconnectError.storeTooLarge(
                "Reader reconnect transaction"
            )
        }
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        try synchronizeFileAndDirectory(url)
        guard try BoundedLocalStoreReader.read(
            from: url,
            maximumBytes: maximumJournalBytes
        ) == data else {
            throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                "Reader reconnect transaction"
            )
        }
    }

    static func clear(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            try synchronizeDirectory(url.deletingLastPathComponent())
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                    "Reader reconnect transaction"
                )
            }
        } catch let error as ReaderExtensionLegacyReconnectError {
            throw error
        } catch {
            throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                "Reader reconnect transaction"
            )
        }
    }

    private static func decodeAndValidate(_ data: Data) throws -> Record {
        guard !data.isEmpty, data.count <= maximumJournalBytes else {
            throw ReaderExtensionLegacyReconnectError.storeTooLarge(
                "Reader reconnect transaction"
            )
        }
        let record: Record
        do {
            record = try PropertyListDecoder().decode(Record.self, from: data)
        } catch {
            throw ReaderExtensionLegacyReconnectError.unreadableStore(
                "Reader reconnect transaction"
            )
        }
        guard (record.schemaVersion == 1 || record.schemaVersion == 2),
              record.schemaVersion == 2 || record.phase == .prepared,
              !record.entries.isEmpty,
              record.entries.count <= maximumEntryCount,
              Set(record.entries.map(\.location)).count == record.entries.count else {
            throw ReaderExtensionLegacyReconnectError.unreadableStore(
                "Reader reconnect transaction"
            )
        }
        try validate(record.entries)
        return record
    }

    private static func validate(_ entries: [Entry]) throws {
        for entry in entries {
            switch entry.location {
            case .standardDefaults(let key):
                guard isBounded(key, maximum: maximumLocationBytes) else {
                    throw ReaderExtensionLegacyReconnectError.unreadableStore(
                        "Reader reconnect transaction"
                    )
                }
            case .file(let path):
                guard path.hasPrefix("/"), isBounded(path, maximum: maximumLocationBytes) else {
                    throw ReaderExtensionLegacyReconnectError.unreadableStore(
                        "Reader reconnect transaction"
                    )
                }
            case .metadataDefaults(let scope, let key):
                guard isBounded(scope, maximum: maximumLocationBytes),
                      isBounded(key, maximum: maximumLocationBytes) else {
                    throw ReaderExtensionLegacyReconnectError.unreadableStore(
                        "Reader reconnect transaction"
                    )
                }
            }
            try validate(entry.original)
            try validate(entry.replacement)
        }
    }

    private static func validate(_ value: Value) throws {
        switch value {
        case .absent:
            return
        case .data(let data):
            guard data.count <= maximumValueBytes else {
                throw ReaderExtensionLegacyReconnectError.storeTooLarge(
                    "Reader reconnect transaction"
                )
            }
        case .string(let string):
            guard isBounded(string, maximum: maximumStringBytes) else {
                throw ReaderExtensionLegacyReconnectError.storeTooLarge(
                    "Reader reconnect transaction"
                )
            }
        }
    }

    private static func isBounded(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
    }

    static func synchronizeFileAndDirectory(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Owns the data-safe Aidoku reconnect seam. It does not perform title matching and it does
/// not contact a provider itself; callers supply canonical item-key verification explicitly.
enum ReaderExtensionLegacyReconnectManager {
    typealias ItemKeyVerifier = @Sendable (
        _ legacyItem: ReaderExtensionLegacyItemReference,
        _ installedSource: ReaderExtensionInstalledSource
    ) async throws -> ReaderExtensionLegacyItemVerification

    typealias ReconnectProgressObserver = @MainActor (ReaderExtensionLegacyReconnectProgress) -> Void

    static let quarantineKey = "readerExtensions.legacyReconnectQuarantine.v1"
    private static let maximumRouteStoreCount = 20_000
    private static let maximumRouteStoreBytes = 32 * 1_024 * 1_024
    private static let maximumTotalRouteStoreBytes = 256 * 1_024 * 1_024
    private static let metadataScopeStandard = "standard"
    private static let metadataScopePrimary = "primary"
    private static let metadataScopeProfilePrefix = "profile:"
    private static let journalFileName = "legacy-reconnect-journal.v1.plist"

    private enum StoreLocation: Hashable {
        case defaults(key: String, label: String)
        case file(url: URL, label: String)

        var label: String {
            switch self {
            case .defaults(_, let label), .file(_, let label): return label
            }
        }
    }

    private struct StoreSnapshot {
        let location: StoreLocation
        let originalData: Data
        let references: [ReaderExtensionLegacyItemReference]
    }

    private struct LegacyMetadataStoreSnapshot {
        let store: UserDefaults
        let journalScope: String
        let label: String
        let originalData: Data?
        let sources: [BackupLegacyAidokuSourceMetadata]
        let selectedHomeSourceID: String?
        let originalInstalledSourcesData: Data?
        let installedSources: [ReaderExtensionInstalledSource]
    }

    private enum PlannedMutationTarget {
        case route(StoreLocation)
        case metadata(store: UserDefaults, key: String, label: String)
    }

    private struct PlannedMutation {
        let target: PlannedMutationTarget
        let journalLocation: ReaderExtensionReconnectTransactionJournal.Location
        let original: ReaderExtensionReconnectTransactionJournal.Value
        let replacement: ReaderExtensionReconnectTransactionJournal.Value
    }

    private static let selectedHomeSourceKey = "kanzenHomeSelectedSourceID"

    private static var transactionJournalURL: URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ReaderExtensions", isDirectory: true)
        return root.appendingPathComponent(journalFileName)
    }

    static func legacySources(
        in store: UserDefaults = ProfileSettingsStore.services
    ) -> [BackupLegacyAidokuSourceMetadata] {
        ReaderExtensionAidokuMigration.legacySources(in: store)
    }

    static func candidates(
        legacySources: [BackupLegacyAidokuSourceMetadata],
        installedSources: [ReaderExtensionInstalledSource]
    ) -> [ReaderExtensionLegacyReconnectCandidate] {
        legacySources.flatMap { legacy in
            installedSources.compactMap { installed in
                let idMatch = canonicalIdentifier(legacy.id)
                    == canonicalIdentifier(installed.upstreamID)
                let legacyHost = canonicalHost(legacy.originHost)
                let installedHosts = Set([
                    installed.baseURL.host,
                    installed.apiURL?.host,
                    installed.sourceCodeURL?.host,
                    installed.repositoryURL.host
                ].compactMap(canonicalHost))
                let hostMatch = legacyHost.map(installedHosts.contains) ?? false
                let legacyLanguages = Set(legacy.languages.compactMap(canonicalLanguage))
                let installedLanguage = canonicalLanguage(installed.language)
                let languageMatch = installedLanguage.map(legacyLanguages.contains) ?? false
                let sourceNameMatch = canonicalSourceName(legacy.name)
                    == canonicalSourceName(installed.name)
                // Aidoku retained the package host (usually the community
                // repository), while Mangayomi IDs are numeric and provider
                // hosts differ. Name + language is therefore useful only as a
                // manual candidate-discovery seam; automatic reconnect still
                // requires the existing strong identity evidence below.
                guard idMatch || (hostMatch && languageMatch)
                        || (sourceNameMatch && languageMatch) else { return nil }
                return ReaderExtensionLegacyReconnectCandidate(
                    legacySource: legacy,
                    installedSource: installed,
                    matchesUpstreamSourceID: idMatch,
                    matchesOriginHost: hostMatch,
                    matchesLanguage: languageMatch,
                    matchesSourceName: sourceNameMatch
                )
            }
        }.sorted { lhs, rhs in
            if lhs.isStrongUniqueMatchCandidate != rhs.isStrongUniqueMatchCandidate {
                return lhs.isStrongUniqueMatchCandidate
            }
            if lhs.legacySource.order != rhs.legacySource.order {
                return lhs.legacySource.order < rhs.legacySource.order
            }
            return lhs.installedSource.sortIndex < rhs.installedSource.sortIndex
        }
    }

    static func uniqueStrongCandidates(
        legacySources: [BackupLegacyAidokuSourceMetadata],
        installedSources: [ReaderExtensionInstalledSource]
    ) -> [ReaderExtensionLegacyReconnectCandidate] {
        let strong = candidates(
            legacySources: legacySources,
            installedSources: installedSources
        ).filter(\.isStrongUniqueMatchCandidate)
        return Dictionary(grouping: strong, by: { $0.legacySource.id })
            .values
            .compactMap { $0.count == 1 ? $0[0] : nil }
            .sorted { $0.legacySource.order < $1.legacySource.order }
    }

    static func legacyItems(sourceID: String) throws -> [ReaderExtensionLegacyItemReference] {
        let snapshots = try routeStoreSnapshots(legacySourceID: sourceID)
        return mergedReferences(snapshots.flatMap(\.references))
    }

    /// Restores an interrupted reconnect before Reader managers consume any partially
    /// rewritten route or source store. Recovery is idempotent and removes the journal only
    /// after every original value has been verified.
    @discardableResult
    static func recoverInterruptedReconnectIfNeeded(
        servicesStore: UserDefaults = ProfileSettingsStore.services
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: transactionJournalURL.path) else {
            return false
        }
        let targets = try journalTargets(servicesStore: servicesStore)
        return try ReaderExtensionReconnectTransactionJournal.recoverIfPresent(
            at: transactionJournalURL,
            read: { location in
                guard let target = targets[location] else {
                    throw ReaderExtensionLegacyReconnectError.unreadableStore(
                        "Reader reconnect transaction"
                    )
                }
                return try currentValue(for: target)
            },
            apply: { value, location in
                guard let target = targets[location] else {
                    throw ReaderExtensionLegacyReconnectError.unreadableStore(
                        "Reader reconnect transaction"
                    )
                }
                try applyValue(value, to: target)
            }
        )
    }

    static func markRecoveryQuarantined(_ error: Error) {
        markQuarantined(error)
    }

    @MainActor
    static func reconnect(
        legacySourceID: String,
        to installedSource: ReaderExtensionInstalledSource,
        resolutions: [ReaderExtensionLegacyItemResolution],
        servicesStore: UserDefaults = ProfileSettingsStore.services
    ) throws -> ReaderExtensionLegacyReconnectReport {
        var mapping: [String: String] = [:]
        for resolution in resolutions {
            if let existing = mapping[resolution.legacyItemKey],
               existing != resolution.readerExtensionItemKey {
                throw ReaderExtensionLegacyReconnectError.conflictingItemResolution(
                    resolution.legacyItemKey
                )
            }
            mapping[resolution.legacyItemKey] = resolution.readerExtensionItemKey
        }
        return try reconnectVerified(
            legacySourceID: legacySourceID,
            to: installedSource,
            itemKeys: mapping,
            servicesStore: servicesStore
        )
    }

    /// Verifies every legacy title against the replacement source and commits
    /// what matched. The sweep is resumable: each answer is written to the
    /// ledger as it arrives, so an interrupted run costs only the titles it had
    /// not reached yet. Titles the source definitively does not carry keep their
    /// `aidoku` routes instead of blocking the whole source.
    /// Stopping the sweep this many answers into an unbroken run of "the source
    /// is not responding" is what separates a rate limit from one awkward title.
    static let maximumConsecutiveInterruptions = 3
    /// A title that fails this many times while the source is demonstrably
    /// answering other titles is treated as absent, so one permanently
    /// unanswerable entry cannot block every title behind it forever.
    static let maximumItemInterruptions = 3

    @MainActor
    static func reconnect(
        legacySourceID: String,
        to installedSource: ReaderExtensionInstalledSource,
        servicesStore: UserDefaults = ProfileSettingsStore.services,
        unresolvedItems: ReaderExtensionLegacyRouteRewriter.UnresolvedItemPolicy = .require,
        ledger ledgerHandle: ReaderExtensionReconnectLedgerStore.Handle? = nil,
        progress: ReconnectProgressObserver? = nil,
        verifyItemKey: ItemKeyVerifier
    ) async throws -> ReaderExtensionLegacyReconnectReport {
        let initialSnapshots = try routeStoreSnapshots(legacySourceID: legacySourceID)
        let items = mergedReferences(initialSnapshots.flatMap(\.references))
        let handle = ledgerHandle ?? ReaderExtensionReconnectLedgerStore.Handle(
            defaults: .standard,
            profileID: ProfileManager.shared.activeProfileID
        )
        var record = ReaderExtensionReconnectLedgerStore.record(
            in: ReaderExtensionReconnectLedgerStore.load(
                from: handle.defaults,
                profileID: handle.profileID
            ),
            legacySourceID: legacySourceID,
            installedSourceID: installedSource.id,
            matching: installedSource
        )
        let alreadyMigratedSomething = !record.resolved.isEmpty
        var resolutions = record.resolved
        var checked = 0
        var consecutiveInterruptions = 0
        var interruptedThisRun: [String] = []
        var sourceAnsweredAtLeastOnce = false

        func publishProgress() {
            progress?(ReaderExtensionLegacyReconnectProgress(
                checked: checked,
                total: items.count,
                resolved: items.reduce(into: 0) {
                    if resolutions[$1.legacyItemKey] != nil { $0 += 1 }
                }
            ))
        }

        func persist() {
            ReaderExtensionReconnectLedgerStore.save(
                record,
                legacySourceID: legacySourceID,
                installedSourceID: installedSource.id,
                matching: installedSource,
                using: handle
            )
        }

        publishProgress()
        for item in items {
            let key = item.legacyItemKey
            guard resolutions[key] == nil,
                  !ReaderExtensionReconnectLedgerStore.isKnownAbsent(key, in: record) else {
                checked += 1
                publishProgress()
                continue
            }
            switch try await verifyItemKey(item, installedSource) {
            case .resolved(let resolved):
                resolutions[key] = resolved
                record.resolved[key] = resolved
                record.absent[key] = nil
                record.interruptions[key] = nil
                consecutiveInterruptions = 0
                sourceAnsweredAtLeastOnce = true
            case .absent:
                record.absent[key] = Date()
                record.resolved[key] = nil
                record.interruptions[key] = nil
                resolutions[key] = nil
                consecutiveInterruptions = 0
                sourceAnsweredAtLeastOnce = true
            case .interrupted:
                // Keep going. Stopping at the first one means a single title the
                // source will never answer for hides every title sorted after
                // it from every future run, which is exactly the resumability
                // this is supposed to provide.
                interruptedThisRun.append(key)
                consecutiveInterruptions += 1
            }
            persist()
            checked += 1
            publishProgress()
            if consecutiveInterruptions >= Self.maximumConsecutiveInterruptions { break }
        }

        // An interruption only counts against a title when the source proved it
        // was answering other titles in the same run. Otherwise a rate limit
        // would slowly demote perfectly present titles to absent.
        if sourceAnsweredAtLeastOnce {
            for key in interruptedThisRun {
                let attempts = (record.interruptions[key] ?? 0) + 1
                if attempts >= Self.maximumItemInterruptions {
                    record.interruptions[key] = nil
                    record.absent[key] = Date()
                } else {
                    record.interruptions[key] = attempts
                }
            }
            persist()
        }

        let unverified = items.filter {
            resolutions[$0.legacyItemKey] == nil
                && !ReaderExtensionReconnectLedgerStore.isKnownAbsent($0.legacyItemKey, in: record)
        }
        guard unverified.isEmpty else {
            throw ReaderExtensionLegacyReconnectError.itemVerificationInterrupted(
                resolved: resolutions.count,
                remaining: unverified.count
            )
        }

        // Everything still carrying a legacy route was already answered for in
        // an earlier run, so there is nothing new to commit. Reporting that as a
        // failure would file a source that migrated fine as permanently broken.
        guard items.contains(where: { resolutions[$0.legacyItemKey] != nil }) else {
            guard alreadyMigratedSomething else {
                throw ReaderExtensionLegacyReconnectError.noItemsResolved
            }
            return ReaderExtensionLegacyReconnectReport(
                legacySourceID: legacySourceID,
                installedSourceID: installedSource.id,
                itemCount: 0,
                routeCount: 0,
                changedStoreCount: 0,
                retainedItemKeys: Set(items.map(\.legacyItemKey))
            )
        }

        // The sweep can run for minutes, so a saved title added or a chapter
        // read meanwhile must not throw the whole run away. Under `.retain` it
        // cannot do harm: the transaction re-reads every store, an entry with no
        // verified replacement simply keeps its own route, and each store is
        // still checked byte-for-byte against its recorded original immediately
        // before and after it is written.
        let report = try reconnectVerified(
            legacySourceID: legacySourceID,
            to: installedSource,
            itemKeys: resolutions,
            unresolvedItems: unresolvedItems,
            servicesStore: servicesStore
        )
        if report.retainedItemCount == 0 {
            ReaderExtensionReconnectLedgerStore.forget(
                legacySourceID: legacySourceID,
                installedSourceID: installedSource.id,
                using: handle
            )
        }
        return report
    }

    /// Called by the legacy artifact cleanup gate. Any unreadable profile/route store is
    /// quarantined and keeps old files from being destructively removed.
    static func preflightStoresForCleanup() -> Bool {
        do {
            _ = try recoverInterruptedReconnectIfNeeded()
            _ = try routeStoreSnapshots(legacySourceID: nil)
            _ = try legacyMetadataStoreSnapshots(primary: ProfileSettingsStore.services)
            UserDefaults.standard.removeObject(forKey: quarantineKey)
            return true
        } catch {
            markQuarantined(error)
            return false
        }
    }

    @MainActor
    private static func reconnectVerified(
        legacySourceID: String,
        to installedSource: ReaderExtensionInstalledSource,
        itemKeys: [String: String],
        unresolvedItems: ReaderExtensionLegacyRouteRewriter.UnresolvedItemPolicy = .require,
        servicesStore: UserDefaults
    ) throws -> ReaderExtensionLegacyReconnectReport {
        _ = try recoverInterruptedReconnectIfNeeded(servicesStore: servicesStore)
        guard installedSource.id.isValid else {
            throw ReaderExtensionLegacyReconnectError.invalidSourceIdentity
        }
        let currentSnapshots = try routeStoreSnapshots(legacySourceID: legacySourceID)
        let items = mergedReferences(currentSnapshots.flatMap(\.references))
        let presentKeys = Set(items.map(\.legacyItemKey))
        // A ledger entry for a title that has already been rewritten, or that
        // was removed from the library since it was verified, must not widen
        // what this transaction touches.
        let effectiveItemKeys = itemKeys.filter { presentKeys.contains($0.key) }
        let retainedKeys = presentKeys.subtracting(effectiveItemKeys.keys)
        switch unresolvedItems {
        case .require:
            if let unverified = retainedKeys.sorted().first {
                throw ReaderExtensionLegacyReconnectError.itemVerificationRequired(unverified)
            }
        case .retain:
            guard presentKeys.isEmpty || !effectiveItemKeys.isEmpty else {
                throw ReaderExtensionLegacyReconnectError.noItemsResolved
            }
        }

        let mapping = ReaderExtensionLegacyRouteRewriter.Mapping(
            legacySourceID: legacySourceID,
            installedSourceID: installedSource.id,
            itemKeys: effectiveItemKeys,
            mediaType: installedSource.mediaType,
            unresolvedItems: unresolvedItems
        )
        var mutations: [(snapshot: StoreSnapshot, replacement: Data)] = []
        var routeCount = 0
        for snapshot in currentSnapshots where !snapshot.references.isEmpty {
            let result = try ReaderExtensionLegacyRouteRewriter.rewrite(
                snapshot.originalData,
                mapping: mapping
            )
            if result.routeCount > 0 || result.providerCount > 0 {
                mutations.append((snapshot, result.data))
                routeCount += result.routeCount
            }
        }

        let legacyMetadataStores: [LegacyMetadataStoreSnapshot]
        do {
            legacyMetadataStores = try legacyMetadataStoreSnapshots(
                primary: servicesStore
            )
        } catch {
            markQuarantined(error)
            throw error
        }
        // A sweep runs for minutes, so the replacement can be uninstalled while
        // it is in flight. The installed-sources mutation is planned only for a
        // store that still lists it, so without this the routes would silently
        // be repointed at a source that is gone and can never be offered as a
        // candidate again. Judge that only against stores that actually carry an
        // inventory — no inventory anywhere is no evidence either way, not
        // evidence of an uninstall.
        let inventories = legacyMetadataStores.filter { !$0.installedSources.isEmpty }
        guard inventories.isEmpty || inventories.contains(where: { store in
            store.installedSources.contains { $0.id == installedSource.id }
        }) else {
            throw ReaderExtensionLegacyReconnectError.installedSourceNotFound
        }
        // Retained routes still spell `aidoku:<source>`, so that source's entry
        // has to stay in the legacy metadata. Dropping it would leave routes
        // whose source can never be identified again: the leftover scan would
        // find no candidate to offer, and the retry the user is being invited to
        // make would have nothing to match against.
        let transactionMutations = try plannedMutations(
            routeMutations: mutations,
            metadataStores: legacyMetadataStores,
            legacySourceID: legacySourceID,
            installedSource: installedSource,
            retainsLegacySource: !retainedKeys.isEmpty
        )
        for mutation in transactionMutations {
            guard try currentValue(for: mutation.target) == mutation.original else {
                throw ReaderExtensionLegacyReconnectError.storeChangedDuringVerification(
                    mutationLabel(mutation.target)
                )
            }
        }
        try ReaderExtensionReconnectTransactionJournal.prepare(
            entries: transactionMutations.map {
                ReaderExtensionReconnectTransactionJournal.Entry(
                    location: $0.journalLocation,
                    original: $0.original,
                    replacement: $0.replacement
                )
            },
            at: transactionJournalURL
        )
        do {
            for mutation in transactionMutations {
                guard try currentValue(for: mutation.target) == mutation.original else {
                    throw ReaderExtensionLegacyReconnectError.storeChangedDuringVerification(
                        mutationLabel(mutation.target)
                    )
                }
                try applyValue(mutation.replacement, to: mutation.target)
                guard try currentValue(for: mutation.target) == mutation.replacement else {
                    throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                        mutationLabel(mutation.target)
                    )
                }
            }

            for mutation in mutations {
                guard let persisted = try read(mutation.snapshot.location) else {
                    throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                        mutation.snapshot.location.label
                    )
                }
                let survivors = Set(
                    try ReaderExtensionLegacyRouteRewriter.references(
                        in: persisted,
                        legacySourceID: legacySourceID
                    ).map(\.legacyItemKey)
                )
                guard survivors.isSubset(of: retainedKeys) else {
                    throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                        mutation.snapshot.location.label
                    )
                }
                // The store's own reader has to accept what was just written.
                // Without this the rewrite can commit a document the library or
                // download index rejects on the next launch, which quarantines
                // the whole store — a rollback here costs nothing by comparison.
                try validatePersistedSchema(persisted, at: mutation.snapshot.location)
            }
            for metadataStore in legacyMetadataStores {
                let remaining = try ReaderExtensionAidokuMigration.validatedLegacySources(
                    in: metadataStore.store
                )
                let stillListed = remaining.contains { $0.id == legacySourceID }
                let shouldStillBeListed = !retainedKeys.isEmpty
                    && metadataStore.sources.contains { $0.id == legacySourceID }
                guard stillListed == shouldStillBeListed else {
                    throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                        "Reader source metadata"
                    )
                }
            }

            // The durable decision separates rollback from roll-forward recovery. Reapply
            // every replacement after that decision so the journal is only removed once all
            // file and preferences targets have been checkpointed durably.
            try ReaderExtensionReconnectTransactionJournal.markCommitted(
                at: transactionJournalURL
            )
            for mutation in transactionMutations {
                try applyValue(mutation.replacement, to: mutation.target)
                guard try currentValue(for: mutation.target) == mutation.replacement else {
                    throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                        mutationLabel(mutation.target)
                    )
                }
            }
            try ReaderExtensionReconnectTransactionJournal.clear(
                at: transactionJournalURL
            )
        } catch {
            let transactionError = error
            do {
                _ = try recoverInterruptedReconnectIfNeeded(
                    servicesStore: servicesStore
                )
            } catch {
                markQuarantined(error)
                throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                    "Reader reconnect transaction"
                )
            }
            // If the commit marker was durable, recovery deliberately completed every
            // replacement. Treat that as success; a prepared transaction was restored and
            // must still report the initiating failure.
            let completedCommittedTransaction = (try? transactionMutations.allSatisfy {
                try currentValue(for: $0.target) == $0.replacement
            }) == true
            guard completedCommittedTransaction else {
                markQuarantined(transactionError)
                throw transactionError
            }
        }

        UserDefaults.standard.removeObject(forKey: quarantineKey)
        reloadLiveReaderStores()
        return ReaderExtensionLegacyReconnectReport(
            legacySourceID: legacySourceID,
            installedSourceID: installedSource.id,
            itemCount: effectiveItemKeys.count,
            routeCount: routeCount,
            changedStoreCount: mutations.count,
            retainedItemKeys: retainedKeys
        )
    }

    private static func routeStoreSnapshots(
        legacySourceID: String?
    ) throws -> [StoreSnapshot] {
        do {
            let locations = try storeLocations()
            guard locations.count <= maximumRouteStoreCount else {
                throw ReaderExtensionLegacyReconnectError.storeTooLarge("Reader store index")
            }
            var totalBytes = 0
            var snapshots: [StoreSnapshot] = []
            snapshots.reserveCapacity(locations.count)
            for location in locations {
                guard let data = try read(location) else { continue }
                let (nextTotal, overflow) = totalBytes.addingReportingOverflow(data.count)
                guard !overflow, nextTotal <= maximumTotalRouteStoreBytes else {
                    throw ReaderExtensionLegacyReconnectError.storeTooLarge("Reader stores")
                }
                totalBytes = nextTotal
                try ReaderExtensionLegacyRouteRewriter.validate(data, label: location.label)
                try validatePersistedSchema(data, at: location)
                snapshots.append(StoreSnapshot(
                    location: location,
                    originalData: data,
                    references: try ReaderExtensionLegacyRouteRewriter.references(
                        in: data,
                        legacySourceID: legacySourceID
                    )
                ))
            }
            return snapshots
        } catch {
            markQuarantined(error)
            throw error
        }
    }

    private static func validatePersistedSchema(
        _ data: Data,
        at location: StoreLocation
    ) throws {
        let valid: Bool
        switch location {
        case .defaults(let key, _)
            where key == "mangaLibraryCollections"
                || key.hasPrefix("mangaLibraryCollections."):
            valid = MangaLibraryManager.persistedCollectionsSchemaIsValid(data)

        case .defaults(let key, _)
            where key == "mangaReadingProgress"
                || key.hasPrefix("mangaReadingProgress."):
            valid = MangaReadingProgressManager.persistedProgressSchemaIsValid(data)

        case .file(let url, _)
            where url.lastPathComponent == ".reader_downloads.json":
            valid = ReaderDownloadManager.persistedIndexSchemaIsValid(data)

        case .file(let url, _)
            where url.lastPathComponent == "chapter.json":
            valid = ReaderDownloadManager.persistedChapterManifestSchemaIsValid(data)

        case .file(let url, _)
            where url.lastPathComponent.hasPrefix("UserRatings")
                && url.pathExtension.lowercased() == "json":
            valid = UserRatingManager.persistedStoreSchemaIsValid(data)

        default:
            valid = false
        }
        guard valid else {
            throw ReaderExtensionLegacyReconnectError.unreadableStore(location.label)
        }
    }

    private static func legacyMetadataStoreSnapshots(
        primary: UserDefaults
    ) throws -> [LegacyMetadataStoreSnapshot] {
        let manager = ProfileManager.shared
        guard manager.rosterStoreIsReadable else {
            throw ReaderExtensionLegacyReconnectError.unreadableProfileRoster
        }
        let standard = UserDefaults.standard
        let profileStores: [(UUID, UserDefaults)] = manager.profiles.map {
            ($0.id, ProfileSettingsStore.shared.store(for: $0.id))
        }
        func stableScope(for store: UserDefaults) -> String {
            if ObjectIdentifier(store) == ObjectIdentifier(standard) {
                return metadataScopeStandard
            }
            if let profile = profileStores.first(where: {
                ObjectIdentifier($0.1) == ObjectIdentifier(store)
            }) {
                return metadataScopeProfilePrefix + profile.0.uuidString
            }
            return metadataScopePrimary
        }
        var stores: [(UserDefaults, String, String)] = [(
            primary,
            "active Reader source metadata",
            stableScope(for: primary)
        )]
        stores.append((standard, "shared Reader source metadata", metadataScopeStandard))
        stores.append(contentsOf: manager.profiles.map {
            (
                ProfileSettingsStore.shared.store(for: $0.id),
                "Reader source metadata \(ProfileScopedStorage.token(for: $0.id))",
                metadataScopeProfilePrefix + $0.id.uuidString
            )
        })
        var seen = Set<ObjectIdentifier>()
        return try stores.compactMap { store, label, scope in
            guard seen.insert(ObjectIdentifier(store)).inserted else { return nil }
            let selectedValue = store.object(forKey: selectedHomeSourceKey)
            guard selectedValue == nil || selectedValue is String else {
                throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
            }
            let value = store.object(
                forKey: BackupReaderExtensionState.legacyAidokuSourcesStorageKey
            )
            guard value != nil else {
                let installedSourcesValue = store.object(
                    forKey: ReaderExtensionPersistence.installedSourcesKey
                )
                guard installedSourcesValue == nil || installedSourcesValue is Data else {
                    throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
                }
                let installedSourcesData = installedSourcesValue as? Data
                let installedSources = try decodedInstalledSources(
                    installedSourcesData,
                    label: label
                )
                return LegacyMetadataStoreSnapshot(
                    store: store,
                    journalScope: scope,
                    label: label,
                    originalData: nil,
                    sources: [],
                    selectedHomeSourceID: selectedValue as? String,
                    originalInstalledSourcesData: installedSourcesData,
                    installedSources: installedSources
                )
            }
            guard let data = value as? Data else {
                throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
            }
            let decoded: [BackupLegacyAidokuSourceMetadata]
            do {
                decoded = try ReaderExtensionAidokuMigration.validatedLegacySources(data: data)
            } catch {
                throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
            }
            let installedSourcesValue = store.object(
                forKey: ReaderExtensionPersistence.installedSourcesKey
            )
            guard installedSourcesValue == nil || installedSourcesValue is Data else {
                throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
            }
            let installedSourcesData = installedSourcesValue as? Data
            let installedSources = try decodedInstalledSources(
                installedSourcesData,
                label: label
            )
            return LegacyMetadataStoreSnapshot(
                store: store,
                journalScope: scope,
                label: label,
                originalData: data,
                sources: decoded,
                selectedHomeSourceID: selectedValue as? String,
                originalInstalledSourcesData: installedSourcesData,
                installedSources: installedSources
            )
        }
    }

    private static func decodedInstalledSources(
        _ data: Data?,
        label: String
    ) throws -> [ReaderExtensionInstalledSource] {
        guard let data else { return [] }
        guard !data.isEmpty, data.count <= BackupReaderExtensionState.maximumMetadataBytes else {
            throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            try ReaderExtensionPersistence.validateInstalledSourceStoreJSON(
                data,
                maximumBytes: BackupReaderExtensionState.maximumMetadataBytes
            )
            return try decoder.decode([ReaderExtensionInstalledSource].self, from: data)
        } catch {
            throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
        }
    }

    private static func installedSourcesData(
        _ installedSources: [ReaderExtensionInstalledSource],
        applying legacySource: BackupLegacyAidokuSourceMetadata,
        to sourceID: ReaderExtensionSourceID
    ) throws -> Data {
        var ordered = installedSources.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        guard let index = ordered.firstIndex(where: { $0.id == sourceID }) else {
            throw ReaderExtensionLegacyReconnectError.installedSourceNotFound
        }
        var replacement = ordered.remove(at: index)
        replacement.enabled = legacySource.isEnabled
        let destination = min(max(legacySource.order, 0), ordered.count)
        ordered.insert(replacement, at: destination)
        for index in ordered.indices { ordered[index].sortIndex = index }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ordered)
        guard data.count <= BackupReaderExtensionState.maximumMetadataBytes else {
            throw ReaderExtensionLegacyReconnectError.storeTooLarge(
                "Reader source metadata"
            )
        }
        return data
    }

    private static func plannedMutations(
        routeMutations: [(snapshot: StoreSnapshot, replacement: Data)],
        metadataStores: [LegacyMetadataStoreSnapshot],
        legacySourceID: String,
        installedSource: ReaderExtensionInstalledSource,
        retainsLegacySource: Bool = false
    ) throws -> [PlannedMutation] {
        var result: [PlannedMutation] = routeMutations.map { mutation in
            let journalLocation: ReaderExtensionReconnectTransactionJournal.Location
            switch mutation.snapshot.location {
            case .defaults(let key, _):
                journalLocation = .standardDefaults(key: key)
            case .file(let url, _):
                journalLocation = .file(path: url.standardizedFileURL.path)
            }
            return PlannedMutation(
                target: .route(mutation.snapshot.location),
                journalLocation: journalLocation,
                original: .data(mutation.snapshot.originalData),
                replacement: .data(mutation.replacement)
            )
        }

        for metadataStore in metadataStores {
            guard let legacySource = metadataStore.sources.first(where: {
                $0.id == legacySourceID
            }) else { continue }

            if !retainsLegacySource {
                let remainingSources = metadataStore.sources.filter { $0.id != legacySourceID }
                let legacyReplacement: ReaderExtensionReconnectTransactionJournal.Value
                if remainingSources.isEmpty {
                    legacyReplacement = .absent
                } else {
                    let data = try JSONEncoder().encode(remainingSources)
                    guard data.count <= BackupReaderExtensionState.maximumMetadataBytes else {
                        throw ReaderExtensionLegacyReconnectError.storeTooLarge(
                            metadataStore.label
                        )
                    }
                    legacyReplacement = .data(data)
                }
                result.append(PlannedMutation(
                    target: .metadata(
                        store: metadataStore.store,
                        key: BackupReaderExtensionState.legacyAidokuSourcesStorageKey,
                        label: metadataStore.label
                    ),
                    journalLocation: .metadataDefaults(
                        scope: metadataStore.journalScope,
                        key: BackupReaderExtensionState.legacyAidokuSourcesStorageKey
                    ),
                    original: metadataStore.originalData.map {
                        ReaderExtensionReconnectTransactionJournal.Value.data($0)
                    } ?? .absent,
                    replacement: legacyReplacement
                ))
            }

            // Order, enabled state and the Discover selection describe a source
            // that has finished moving. Re-applying them on every later partial
            // run would silently undo a manual reorder, re-disable a source the
            // user just enabled, and yank Discover onto a source Settings still
            // lists as pending.
            guard !retainsLegacySource else { continue }

            if metadataStore.selectedHomeSourceID == "aidoku:\(legacySourceID)" {
                result.append(PlannedMutation(
                    target: .metadata(
                        store: metadataStore.store,
                        key: selectedHomeSourceKey,
                        label: metadataStore.label
                    ),
                    journalLocation: .metadataDefaults(
                        scope: metadataStore.journalScope,
                        key: selectedHomeSourceKey
                    ),
                    original: metadataStore.selectedHomeSourceID.map {
                        ReaderExtensionReconnectTransactionJournal.Value.string($0)
                    } ?? .absent,
                    replacement: .string(
                        "readerExtension:\(installedSource.id.rawValue)"
                    )
                ))
            }

            if metadataStore.installedSources.contains(where: {
                $0.id == installedSource.id
            }) {
                let replacement = try installedSourcesData(
                    metadataStore.installedSources,
                    applying: legacySource,
                    to: installedSource.id
                )
                result.append(PlannedMutation(
                    target: .metadata(
                        store: metadataStore.store,
                        key: ReaderExtensionPersistence.installedSourcesKey,
                        label: metadataStore.label
                    ),
                    journalLocation: .metadataDefaults(
                        scope: metadataStore.journalScope,
                        key: ReaderExtensionPersistence.installedSourcesKey
                    ),
                    original: metadataStore.originalInstalledSourcesData.map {
                        ReaderExtensionReconnectTransactionJournal.Value.data($0)
                    } ?? .absent,
                    replacement: .data(replacement)
                ))
            }
        }

        guard !result.isEmpty,
              Set(result.map(\.journalLocation)).count == result.count else {
            throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                "Reader reconnect transaction"
            )
        }
        return result
    }

    private static func mutationLabel(_ target: PlannedMutationTarget) -> String {
        switch target {
        case .route(let location): return location.label
        case .metadata(_, _, let label): return label
        }
    }

    private static func currentValue(
        for target: PlannedMutationTarget
    ) throws -> ReaderExtensionReconnectTransactionJournal.Value {
        switch target {
        case .route(let location):
            return try read(location).map {
                ReaderExtensionReconnectTransactionJournal.Value.data($0)
            } ?? .absent
        case .metadata(let store, let key, let label):
            let value = store.object(forKey: key)
            if value == nil { return .absent }
            if let data = value as? Data { return .data(data) }
            if let string = value as? String { return .string(string) }
            throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
        }
    }

    private static func applyValue(
        _ value: ReaderExtensionReconnectTransactionJournal.Value,
        to target: PlannedMutationTarget
    ) throws {
        switch target {
        case .route(let location):
            switch value {
            case .data(let data):
                try write(data, to: location)
            case .absent:
                switch location {
                case .defaults(let key, _):
                    UserDefaults.standard.removeObject(forKey: key)
                    try synchronize(
                        UserDefaults.standard,
                        label: location.label
                    )
                case .file(let url, _):
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                        try ReaderExtensionReconnectTransactionJournal.synchronizeDirectory(
                            url.deletingLastPathComponent()
                        )
                    }
                }
            case .string:
                throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                    location.label
                )
            }
        case .metadata(let store, let key, let label):
            switch value {
            case .absent: store.removeObject(forKey: key)
            case .data(let data): store.set(data, forKey: key)
            case .string(let string): store.set(string, forKey: key)
            }
            try synchronize(store, label: label)
            guard try currentValue(for: target) == value else {
                throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(label)
            }
        }
    }

    private static func synchronize(_ store: UserDefaults, label: String) throws {
        guard store.synchronize() else {
            throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(label)
        }
    }

    private static func journalTargets(
        servicesStore: UserDefaults
    ) throws -> [ReaderExtensionReconnectTransactionJournal.Location: PlannedMutationTarget] {
        var targets: [ReaderExtensionReconnectTransactionJournal.Location: PlannedMutationTarget] = [:]
        for location in try storeLocations() {
            let journalLocation: ReaderExtensionReconnectTransactionJournal.Location
            switch location {
            case .defaults(let key, _):
                journalLocation = .standardDefaults(key: key)
            case .file(let url, _):
                journalLocation = .file(path: url.standardizedFileURL.path)
            }
            targets[journalLocation] = .route(location)
        }
        let allowedKeys = [
            BackupReaderExtensionState.legacyAidokuSourcesStorageKey,
            selectedHomeSourceKey,
            ReaderExtensionPersistence.installedSourcesKey
        ]
        var metadataStores: [(scope: String, store: UserDefaults)] = [
            (metadataScopeStandard, .standard),
            (metadataScopePrimary, servicesStore)
        ]
        if ProfileManager.shared.rosterStoreIsReadable {
            metadataStores.append(contentsOf: ProfileManager.shared.profiles.map {
                (
                    metadataScopeProfilePrefix + $0.id.uuidString,
                    ProfileSettingsStore.shared.store(for: $0.id)
                )
            })
        }
        for metadata in metadataStores {
            for key in allowedKeys {
                targets[.metadataDefaults(scope: metadata.scope, key: key)] = .metadata(
                    store: metadata.store,
                    key: key,
                    label: "Reader reconnect transaction"
                )
            }
        }
        return targets
    }

    private static func storeLocations() throws -> [StoreLocation] {
        let manager = ProfileManager.shared
        guard manager.rosterStoreIsReadable else {
            throw ReaderExtensionLegacyReconnectError.unreadableProfileRoster
        }
        let profileIDs = Array(
            Set(manager.profiles.map(\.id)).union([ProfileManager.defaultProfileID])
        ).sorted { $0.uuidString < $1.uuidString }

        var locations: [StoreLocation] = [
            .defaults(key: "mangaLibraryCollections", label: "legacy Reader library"),
            .defaults(key: "mangaReadingProgress", label: "legacy Reader progress")
        ]
        for profileID in profileIDs {
            let token = ProfileScopedStorage.token(for: profileID)
            locations.append(
                .defaults(
                    key: MangaLibraryManager.storageKey(for: profileID),
                    label: "Reader library \(token)"
                )
            )
            locations.append(
                .defaults(
                    key: MangaReadingProgressManager.storageKey(for: profileID),
                    label: "Reader progress \(token)"
                )
            )
            locations.append(
                .file(
                    url: UserRatingManager.fileURL(for: profileID),
                    label: "Reader ratings \(token)"
                )
            )
        }

        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        locations.append(
            .file(
                url: documents.appendingPathComponent("UserRatings.json"),
                label: "legacy Reader ratings"
            )
        )
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let downloadRoot = appSupport.appendingPathComponent("KanzenDownloads", isDirectory: true)
        locations.append(
            .file(
                url: downloadRoot.appendingPathComponent(".reader_downloads.json"),
                label: "Reader download index"
            )
        )
        if fileManager.fileExists(atPath: downloadRoot.path) {
            let rootValues = try? downloadRoot.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard rootValues?.isDirectory == true, rootValues?.isSymbolicLink != true else {
                throw ReaderExtensionLegacyReconnectError.unreadableStore(
                    "Reader download directory"
                )
            }
            var traversalFailed = false
            guard let enumerator = fileManager.enumerator(
            at: downloadRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                traversalFailed = true
                return false
            }
            ) else {
                throw ReaderExtensionLegacyReconnectError.unreadableStore(
                    "Reader download directory"
                )
            }
            var manifestCount = 0
            for case let url as URL in enumerator where url.lastPathComponent == "chapter.json" {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                manifestCount += 1
                guard manifestCount <= maximumRouteStoreCount else {
                    throw ReaderExtensionLegacyReconnectError.storeTooLarge(
                        "Reader download manifests"
                    )
                }
                locations.append(
                    .file(url: url, label: "Reader download chapter manifest")
                )
            }
            guard !traversalFailed else {
                throw ReaderExtensionLegacyReconnectError.unreadableStore(
                    "Reader download directory"
                )
            }
        }
        return Array(Set(locations)).sorted { $0.label < $1.label }
    }

    private static func read(_ location: StoreLocation) throws -> Data? {
        switch location {
        case .defaults(let key, let label):
            let value = UserDefaults.standard.object(forKey: key)
            guard value != nil else { return nil }
            guard let data = value as? Data,
                  !data.isEmpty,
                  data.count <= maximumRouteStoreBytes else {
                throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
            }
            return data
        case .file(let url, let label):
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true,
                  let fileSize = values?.fileSize,
                  fileSize > 0,
                  fileSize <= maximumRouteStoreBytes else {
                throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
            }
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count == fileSize else {
                    throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
                }
                return data
            } catch {
                if error is ReaderExtensionLegacyReconnectError { throw error }
                throw ReaderExtensionLegacyReconnectError.unreadableStore(label)
            }
        }
    }

    private static func write(_ data: Data, to location: StoreLocation) throws {
        switch location {
        case .defaults(let key, _):
            UserDefaults.standard.set(data, forKey: key)
            try synchronize(UserDefaults.standard, label: location.label)
            guard UserDefaults.standard.data(forKey: key) == data else {
                throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(
                    location.label
                )
            }
        case .file(let url, let label):
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                try ReaderExtensionReconnectTransactionJournal.synchronizeFileAndDirectory(url)
                guard try Data(contentsOf: url) == data else {
                    throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(label)
                }
            } catch let error as ReaderExtensionLegacyReconnectError {
                throw error
            } catch {
                throw ReaderExtensionLegacyReconnectError.rewriteVerificationFailed(label)
            }
        }
    }

    private static func mergedReferences(
        _ references: [ReaderExtensionLegacyItemReference]
    ) -> [ReaderExtensionLegacyItemReference] {
        var merged: [String: ReaderExtensionLegacyItemReference] = [:]
        for reference in references {
            if let existing = merged[reference.id] {
                merged[reference.id] = ReaderExtensionLegacyItemReference(
                    legacySourceID: reference.legacySourceID,
                    legacyItemKey: reference.legacyItemKey,
                    title: existing.title ?? reference.title,
                    author: existing.author ?? reference.author,
                    coverURL: existing.coverURL ?? reference.coverURL,
                    occurrenceCount: existing.occurrenceCount + reference.occurrenceCount
                )
            } else {
                merged[reference.id] = reference
            }
        }
        return merged.values.sorted { $0.id < $1.id }
    }

    private static func canonicalIdentifier(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func canonicalSourceName(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func canonicalHost(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !value.isEmpty else { return nil }
        while value.hasSuffix(".") { value.removeLast() }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value.isEmpty ? nil : value
    }

    private static func canonicalLanguage(_ value: String) -> String? {
        let canonical = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "_", with: "-")
        guard !canonical.isEmpty else { return nil }
        return canonical.split(separator: "-").first.map(String.init)
    }

    private static func markQuarantined(_ error: Error) {
        UserDefaults.standard.set(
            [
                "failedAt": Date().timeIntervalSince1970,
                "reason": String(reflecting: type(of: error))
            ] as [String: Any],
            forKey: quarantineKey
        )
        Logger.shared.log(
            "Reader Extensions: legacy reconnect preflight quarantined an unreadable Reader store; cleanup is deferred",
            type: "Storage"
        )
    }

    @MainActor
    private static func reloadLiveReaderStores() {
        _ = try? ReaderExtensionManager.shared.reloadPersistedStateAfterRestore()
        let manager = ProfileManager.shared
        guard manager.rosterStoreIsReadable else { return }
        for profile in manager.profiles {
            if let collections = MangaLibraryManager.shared.collectionsSnapshot(
                forProfile: profile.id
            ) {
                MangaLibraryManager.shared.applyRestoredCollections(
                    collections,
                    forProfile: profile.id
                )
            }
            if let progress = MangaReadingProgressManager.shared.progressSnapshot(
                forProfile: profile.id
            ) {
                MangaReadingProgressManager.shared.applyRestoredProgress(
                    progress,
                    forProfile: profile.id
                )
            }
        }
        NotificationCenter.default.post(
            name: .readerExtensionLegacyRoutesDidReconnect,
            object: nil
        )
    }
}

extension Notification.Name {
    static let readerExtensionLegacyRoutesDidReconnect = Notification.Name(
        "readerExtensionLegacyRoutesDidReconnect"
    )
}

/// One-shot, profile-aware conversion of the old Aidoku metadata store. It never opens an
/// `.aix`, restores a package archive, contacts a legacy list URL, or executes old source code.
enum ReaderExtensionAidokuMigration {
    static let completionKey = "readerExtensions.aidokuMigrationComplete.v1"
    static let quarantineKey = "readerExtensions.aidokuMigrationQuarantine.v1"

    private static let legacyKeys = [
        "kanzenAidokuSourceLists",
        "kanzenAidokuInstalledSources",
        "kanzenAidokuShowMatureSources",
        "kanzenAidokuAutoUpdateSources",
        "kanzenAidokuLastAutoUpdate",
        "kanzenAidokuPendingPackageRepairIDs"
    ]

    private static let transactionKeys = [
        ReaderExtensionPersistence.repositoriesKey,
        ReaderExtensionPersistence.installedSourcesKey,
        ReaderExtensionPersistence.showMatureSourcesKey,
        ReaderExtensionPersistence.autoUpdateSourcesKey,
        ReaderExtensionPersistence.lastAutoUpdateKey,
        BackupReaderExtensionState.legacyAidokuSourcesStorageKey,
        completionKey,
        quarantineKey
    ] + legacyKeys

    private enum MigrationError: LocalizedError {
        case unreadableLegacyMetadata
        case unsafeLegacyMetadata
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .unreadableLegacyMetadata:
                return "Legacy Reader source metadata is unreadable."
            case .unsafeLegacyMetadata:
                return "Legacy Reader source metadata failed validation."
            case .verificationFailed:
                return "Legacy Reader source migration did not verify."
            }
        }
    }

    private struct PersistedAidokuSource: Decodable {
        let id: String
        let name: String
        let version: Int
        let languages: [String]
        let externalIconURL: String?
        let contentRatingRawValue: Int
        let sourceListURL: String?
        let packageURL: String?
        let isEnabled: Bool
        let order: Int
        let lastUpdated: Date?
        let packageDigest: String?

        private enum CodingKeys: String, CodingKey {
            case id, name, version, languages, externalIconURL, contentRatingRawValue
            case sourceListURL, packageURL, isEnabled, order, lastUpdated, packageDigest
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try BackupAidokuLegacyWirePolicy.sourceID(
                container.decode(String.self, forKey: .id),
                codingPath: container.codingPath + [CodingKeys.id]
            )
            if let decodedName = try container.decodeIfPresent(String.self, forKey: .name) {
                name = try BackupAidokuLegacyWirePolicy.requiredString(
                    decodedName,
                    maximumBytes: BackupAidokuLegacyWirePolicy.maximumNameBytes,
                    field: "name",
                    codingPath: container.codingPath + [CodingKeys.name]
                )
            } else {
                name = id
            }
            let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
            guard (0...Int(Int32.max)).contains(decodedVersion) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: container,
                    debugDescription: "Legacy Reader source version is invalid."
                )
            }
            version = decodedVersion
            languages = try container.decodeIfPresent(
                BackupAidokuBoundedLanguages.self,
                forKey: .languages
            )?.values ?? []
            externalIconURL = try BackupAidokuLegacyWirePolicy.optionalString(
                container.decodeIfPresent(String.self, forKey: .externalIconURL),
                maximumBytes: BackupAidokuLegacyWirePolicy.maximumURLBytes,
                field: "external icon URL",
                codingPath: container.codingPath + [CodingKeys.externalIconURL]
            )
            let decodedRating = try container.decodeIfPresent(
                Int.self,
                forKey: .contentRatingRawValue
            ) ?? 0
            guard (0...3).contains(decodedRating) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .contentRatingRawValue,
                    in: container,
                    debugDescription: "Legacy Reader source content rating is invalid."
                )
            }
            contentRatingRawValue = decodedRating
            sourceListURL = try BackupAidokuLegacyWirePolicy.optionalString(
                container.decodeIfPresent(String.self, forKey: .sourceListURL),
                maximumBytes: BackupAidokuLegacyWirePolicy.maximumURLBytes,
                field: "source-list URL",
                codingPath: container.codingPath + [CodingKeys.sourceListURL]
            )
            packageURL = try BackupAidokuLegacyWirePolicy.optionalString(
                container.decodeIfPresent(String.self, forKey: .packageURL),
                maximumBytes: BackupAidokuLegacyWirePolicy.maximumURLBytes,
                field: "package URL",
                codingPath: container.codingPath + [CodingKeys.packageURL]
            )
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            let decodedOrder = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
            guard (0...10_000).contains(decodedOrder) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .order,
                    in: container,
                    debugDescription: "Legacy Reader source order is invalid."
                )
            }
            order = decodedOrder
            let decodedDate = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
            guard decodedDate.map(BackupAidokuLegacyWirePolicy.isSafeDate) ?? true else {
                throw DecodingError.dataCorruptedError(
                    forKey: .lastUpdated,
                    in: container,
                    debugDescription: "Legacy Reader source update date is invalid."
                )
            }
            lastUpdated = decodedDate
            if let decodedDigest = try container.decodeIfPresent(String.self, forKey: .packageDigest) {
                guard BackupAidokuLegacyWirePolicy.isSafeDigest(decodedDigest) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .packageDigest,
                        in: container,
                        debugDescription: "Legacy Reader source package digest is invalid."
                    )
                }
                packageDigest = decodedDigest.lowercased()
            } else {
                packageDigest = nil
            }
        }

        var backupRecord: BackupAidokuInstalledSource {
            BackupAidokuInstalledSource(
                id: id,
                name: name,
                version: version,
                languages: languages,
                iconPath: nil,
                externalIconURL: externalIconURL,
                contentRatingRawValue: contentRatingRawValue,
                sourceListURL: sourceListURL,
                packageURL: packageURL,
                isEnabled: isEnabled,
                order: order,
                lastUpdated: lastUpdated,
                lastError: nil,
                packageDigest: packageDigest,
                payloadArchiveData: nil
            )
        }
    }

    private struct BoundedPersistedAidokuSources: Decodable {
        let values: [PersistedAidokuSource]

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            if let count = container.count,
               count > BackupAidokuLegacyWirePolicy.maximumInstalledSources {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Legacy Reader installed-source list is too large."
                )
            }
            var result: [PersistedAidokuSource] = []
            var seen = Set<String>()
            while !container.isAtEnd {
                guard result.count < BackupAidokuLegacyWirePolicy.maximumInstalledSources else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Legacy Reader installed-source list is too large."
                    )
                }
                let source = try container.decode(PersistedAidokuSource.self)
                guard seen.insert(source.id).inserted else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Legacy Reader installed-source identities must be unique."
                    )
                }
                result.append(source)
            }
            values = result
        }
    }

    /// Returns false whenever a Reader migration or metadata store cannot be verified.
    /// Callers must stay inert rather than normalizing an unreadable store into an empty
    /// one. The reconnect preflight gates only destructive legacy-artifact cleanup, never
    /// runtime availability.
    @discardableResult
    static func runAllKnownProfilesIfNeeded() -> Bool {
        let recoveredInterruptedReconnect: Bool
        do {
            recoveredInterruptedReconnect = try ReaderExtensionLegacyReconnectManager
                .recoverInterruptedReconnectIfNeeded()
        } catch {
            ReaderExtensionLegacyReconnectManager.markRecoveryQuarantined(error)
            return false
        }
        if recoveredInterruptedReconnect {
            NotificationCenter.default.post(
                name: .readerExtensionLegacyRoutesDidReconnect,
                object: nil
            )
        }
        let profileManager = ProfileManager.shared
        var stores: [(label: String, store: UserDefaults)] = [
            ("shared", UserDefaults.standard)
        ]
        if profileManager.rosterStoreIsReadable {
            stores.append(contentsOf: profileManager.profiles.compactMap { profile in
                guard profile.id != ProfileManager.defaultProfileID else { return nil }
                return (profile.id.uuidString, ProfileSettingsStore.shared.store(for: profile.id))
            })
        }

        var allStoresVerified = profileManager.rosterStoreIsReadable
        for entry in stores {
            do {
                try migrateStoreIfNeeded(entry.store)
                try validateRuntimeState(in: entry.store)
            } catch {
                allStoresVerified = false
                markQuarantined(entry.store, label: entry.label, error: error)
                Logger.shared.log(
                    "Reader Extensions: quarantined unreadable legacy metadata for profile scope \(entry.label) (\(error.localizedDescription)); old packages remain inert and cleanup will retry after repair",
                    type: "Storage"
                )
            }
        }

        guard allStoresVerified,
              stores.allSatisfy({ $0.store.bool(forKey: completionKey) }),
              stores.allSatisfy({ $0.store.object(forKey: quarantineKey) == nil }) else {
            return false
        }
        if ReaderExtensionLegacyReconnectManager.preflightStoresForCleanup() {
            removeLegacyArtifactsIfSafe()
        }
        return true
    }

    /// Validates current Reader Extension metadata even after the one-shot legacy marker
    /// has been set. This prevents a later corrupt value from being treated as an empty
    /// repository/source/preference collection by a live manager.
    static func validateRuntimeState(in store: UserDefaults) throws {
        _ = try ReaderExtensionPersistence.loadRepositories(from: store)
        let sources = try ReaderExtensionPersistence.loadInstalledSources(from: store)
        _ = try ReaderExtensionPersistence.applyingPreferenceOverlay(
            to: sources,
            from: store
        )
    }

    static func legacySources(
        in store: UserDefaults = ProfileSettingsStore.services
    ) -> [BackupLegacyAidokuSourceMetadata] {
        (try? validatedLegacySources(in: store)) ?? []
    }

    static func validatedLegacySources(
        in store: UserDefaults = ProfileSettingsStore.services
    ) throws -> [BackupLegacyAidokuSourceMetadata] {
        guard let value = store.object(
            forKey: BackupReaderExtensionState.legacyAidokuSourcesStorageKey
        ) else {
            return []
        }
        guard let data = value as? Data else {
            throw MigrationError.unreadableLegacyMetadata
        }
        return try validatedLegacySources(data: data)
    }

    static func validatedLegacySources(
        data: Data
    ) throws -> [BackupLegacyAidokuSourceMetadata] {
        guard !data.isEmpty,
              data.count <= BackupReaderExtensionState.maximumMetadataBytes else {
            throw MigrationError.unreadableLegacyMetadata
        }
        do {
            return try BackupReaderExtensionState.decodeLegacySources(from: data)
        } catch {
            throw MigrationError.unsafeLegacyMetadata
        }
    }

    static func removeReconnectedLegacySource(
        id: String,
        in store: UserDefaults = ProfileSettingsStore.services
    ) throws {
        let remaining = try validatedLegacySources(in: store).filter { $0.id != id }
        if remaining.isEmpty {
            store.removeObject(forKey: BackupReaderExtensionState.legacyAidokuSourcesStorageKey)
        } else {
            let encoded = try JSONEncoder().encode(remaining)
            guard encoded.count <= BackupReaderExtensionState.maximumMetadataBytes else {
                throw MigrationError.unsafeLegacyMetadata
            }
            store.set(encoded, forKey: BackupReaderExtensionState.legacyAidokuSourcesStorageKey)
        }
    }

    static func legacyStableKey(sourceID: String, itemKey: String) -> String {
        "aidoku:\(sourceID):\(itemKey)"
    }

    /// The composed key, or nil when the legacy identifiers make one that
    /// `MangaContentRoute`'s decoder would reject. Writing a rejected key is
    /// not a cosmetic problem: the decode throws, and the library store is
    /// quarantined wholesale on the next load.
    static func persistableLegacyStableKey(sourceID: String, itemKey: String) -> String? {
        let composed = legacyStableKey(sourceID: sourceID, itemKey: itemKey)
        guard composed == composed.trimmingCharacters(in: .whitespacesAndNewlines),
              composed.utf8.count <= 32 * 1_024,
              !composed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            return nil
        }
        return composed
    }

    static func hasQuarantinedMetadata(
        in store: UserDefaults = ProfileSettingsStore.services
    ) -> Bool {
        store.object(forKey: quarantineKey) != nil
    }

    static func migrateStoreIfNeeded(_ store: UserDefaults) throws {
        let containsLegacyState = legacyKeys.contains { store.object(forKey: $0) != nil }
        if store.bool(forKey: completionKey), !containsLegacyState { return }

        let previousValues = transactionKeys.map { ($0, store.object(forKey: $0)) }
        do {
            guard let legacyState = try legacyState(in: store) else {
                store.set(true, forKey: completionKey)
                store.removeObject(forKey: quarantineKey)
                return
            }

            let migratedLegacySources = legacyState.installedSources.compactMap(
                BackupLegacyAidokuSourceMetadata.init
            )
            guard migratedLegacySources.count == legacyState.installedSources.count else {
                throw MigrationError.unsafeLegacyMetadata
            }

            let existingSnapshot = try ReaderExtensionPersistence.backupSnapshot(from: store)
            let existingLegacySources = try validatedLegacySources(in: store)
            var seenLegacySourceIDs = Set<String>()
            let mergedLegacySources = (existingLegacySources + migratedLegacySources).filter {
                seenLegacySourceIDs.insert($0.id).inserted
            }
            let hasExplicitReaderExtensionState = !existingSnapshot.repositories.isEmpty
                || !existingSnapshot.installedSources.isEmpty
                || store.object(forKey: ReaderExtensionPersistence.showMatureSourcesKey) != nil
                || store.object(forKey: ReaderExtensionPersistence.autoUpdateSourcesKey) != nil
            let mergedSnapshot = ReaderExtensionBackupSnapshot(
                repositories: existingSnapshot.repositories,
                installedSources: existingSnapshot.installedSources,
                showMatureSources: hasExplicitReaderExtensionState
                    ? existingSnapshot.showMatureSources
                    : legacyState.showMatureSources,
                autoUpdateSources: hasExplicitReaderExtensionState
                    ? existingSnapshot.autoUpdateSources
                    : legacyState.autoUpdateSources,
                lastAutoUpdate: existingSnapshot.lastAutoUpdate ?? legacyState.lastAutoUpdate
            )
            let portableState = try BackupReaderExtensionState(
                snapshot: mergedSnapshot,
                legacyAidokuSources: mergedLegacySources
            )
            try portableState.restore(to: store)

            legacyKeys.forEach(store.removeObject(forKey:))
            store.set(true, forKey: completionKey)
            store.removeObject(forKey: quarantineKey)

            let persistedLegacyIDs = Set(
                try validatedLegacySources(in: store).map(\.id)
            )
            guard legacyKeys.allSatisfy({ store.object(forKey: $0) == nil }),
                  store.bool(forKey: completionKey),
                  persistedLegacyIDs.isSuperset(
                    of: Set(migratedLegacySources.map(\.id))
                  ) else {
                throw MigrationError.verificationFailed
            }
        } catch {
            for (key, value) in previousValues {
                if let value {
                    store.set(value, forKey: key)
                } else {
                    store.removeObject(forKey: key)
                }
            }
            throw error
        }
    }

    private static func legacyState(in store: UserDefaults) throws -> BackupAidokuState? {
        guard legacyKeys.contains(where: { store.object(forKey: $0) != nil }) else {
            return nil
        }
        let installedSources: [BackupAidokuInstalledSource]
        if let data = store.data(forKey: "kanzenAidokuInstalledSources") {
            guard data.count <= BackupReaderExtensionState.maximumMetadataBytes,
                  let decoded = try? JSONDecoder().decode(
                      BoundedPersistedAidokuSources.self,
                      from: data
                  ) else {
                throw MigrationError.unreadableLegacyMetadata
            }
            installedSources = decoded.values.map(\.backupRecord)
        } else {
            installedSources = []
        }
        return BackupAidokuState(
            sourceLists: [],
            installedSources: installedSources,
            showMatureSources: store.bool(forKey: "kanzenAidokuShowMatureSources"),
            autoUpdateSources: store.object(forKey: "kanzenAidokuAutoUpdateSources") == nil
                ? true
                : store.bool(forKey: "kanzenAidokuAutoUpdateSources"),
            lastAutoUpdate: store.object(forKey: "kanzenAidokuLastAutoUpdate") as? Date,
            sharedPayloads: nil
        )
    }

    private static func markQuarantined(
        _ store: UserDefaults,
        label: String,
        error: Error
    ) {
        store.set(
            [
                "failedAt": Date().timeIntervalSince1970,
                "profileScope": String(label.prefix(64)),
                "reason": String(reflecting: type(of: error)),
                "detail": String(error.localizedDescription.prefix(256))
            ] as [String: Any],
            forKey: quarantineKey
        )
        store.removeObject(forKey: completionKey)
    }

    private static func removeLegacyArtifactsIfSafe() {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].standardizedFileURL
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .standardizedFileURL
        let targets = [
            applicationSupport.appendingPathComponent("KanzenAidoku", isDirectory: true),
            caches.appendingPathComponent("ReaderAidokuZipCache", isDirectory: true),
            caches.appendingPathComponent("KanzenAidoku", isDirectory: true)
        ]
        let allowedNames = Set(["KanzenAidoku", "ReaderAidokuZipCache"])
        var removedCount = 0
        for target in targets {
            let standardized = target.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard allowedNames.contains(standardized.lastPathComponent),
                  standardized.deletingLastPathComponent() == applicationSupport
                    || standardized.deletingLastPathComponent() == caches,
                  fileManager.fileExists(atPath: standardized.path),
                  values?.isDirectory == true,
                  values?.isSymbolicLink != true else {
                continue
            }
            do {
                try fileManager.removeItem(at: standardized)
                removedCount += 1
            } catch {
                Logger.shared.log(
                    "Reader Extensions: legacy Reader artifact cleanup will retry (\(standardized.lastPathComponent))",
                    type: "Storage"
                )
            }
        }
        let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL
        let legacyTemporaryPrefix = "kanzen-aidoku-"
        let temporaryCandidates = ((try? fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { url in
                let name = url.lastPathComponent
                guard name.hasPrefix(legacyTemporaryPrefix) else { return false }
                let suffix = String(name.dropFirst(legacyTemporaryPrefix.count))
                return UUID(uuidString: suffix) != nil
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(256)
        for candidate in temporaryCandidates {
            let standardized = candidate.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard standardized.deletingLastPathComponent() == temporaryRoot,
                  values?.isDirectory == true,
                  values?.isSymbolicLink != true else { continue }
            do {
                try fileManager.removeItem(at: standardized)
                removedCount += 1
            } catch {
                Logger.shared.log(
                    "Reader Extensions: legacy Reader temporary-package cleanup will retry",
                    type: "Storage"
                )
            }
        }
        if removedCount > 0 {
            Logger.shared.log(
                "Reader Extensions: removed \(removedCount) verified legacy package/cache location(s)",
                type: "Storage"
            )
        }
    }
}
#endif

struct ExperimentalCloudSnapshotFootprint: Codable, Equatable {
    static let maximumDomainRecordCount = 10_000_000

    let libraryItems: Int
    let movieProgress: Int
    let episodeProgress: Int
    let mangaLibraryItems: Int
    let mangaReadingProgress: Int
    let userRatings: Int
    let services: Int
    let stremioAddons: Int
    let skyStreamSources: Int
    let kanzenModules: Int
    let aidokuSources: Int
    let contentDigest: String?
    let contentDigestExcludingCloudKitMediaState: String?

    init(snapshot: BackupData, encodedData: Data) {
        libraryItems = Self.boundedSum(snapshot.collections.map { $0.items.count })
        movieProgress = Self.boundedCount(snapshot.progressData.movieProgress.count)
        episodeProgress = Self.boundedCount(snapshot.progressData.episodeProgress.count)
        mangaLibraryItems = Self.boundedSum(snapshot.mangaCollections.map { $0.items.count })
        mangaReadingProgress = Self.boundedCount(snapshot.mangaReadingProgress.count)
        userRatings = Self.boundedCount(snapshot.userRatings.count)
        services = Self.boundedCount(snapshot.services.count)
        stremioAddons = Self.boundedCount(snapshot.stremioAddons?.count ?? 0)
        skyStreamSources = Self.boundedSum([
            snapshot.skyStream?.repositories.count ?? 0,
            snapshot.skyStream?.plugins.count ?? 0
        ])
        kanzenModules = Self.boundedCount(snapshot.kanzenModules.count)
        // Keep the encoded field name for cloud-schema compatibility while counting the
        // replacement Reader Extensions domain (including unresolved legacy reconnect rows).
        aidokuSources = Self.boundedCount(
            snapshot.readerExtensionsState?.sourceCountForCompatibility
                ?? snapshot.aidokuState?.installedSources.count
                ?? 0
        )
        let digests = Self.stableContentDigests(for: encodedData)
        contentDigest = digests.full
        contentDigestExcludingCloudKitMediaState = digests.excludingCloudKitMediaState
    }

    var meaningfulRecordCount: Int {
        Self.safeSum(counts)
    }

    func isSuspiciousReduction(from previous: Self) -> Bool {
        zip(previous.counts, counts).contains { oldCount, newCount in
            guard newCount < oldCount else { return false }
            if newCount == 0 { return true }
            let removed = oldCount - newCount
            let majorityThreshold = oldCount / 2 + oldCount % 2
            return removed >= 3 && removed >= majorityThreshold
        }
    }

    func hasMeaningfullyMoreData(than other: Self) -> Bool {
        other.isSuspiciousReduction(from: self)
    }

    func hasAnyMoreData(than other: Self) -> Bool {
        zip(counts, other.counts).contains { currentCount, otherCount in
            currentCount > otherCount
        }
    }

    func hasDifferentContent(than other: Self) -> Bool {
        if let contentDigest, let otherDigest = other.contentDigest {
            return contentDigest != otherDigest
        }
        return counts != other.counts
    }

    func excludingCloudKitMediaState() -> Self {
        Self(
            libraryItems: 0,
            movieProgress: 0,
            episodeProgress: 0,
            mangaLibraryItems: mangaLibraryItems,
            mangaReadingProgress: mangaReadingProgress,
            userRatings: 0,
            services: services,
            stremioAddons: stremioAddons,
            skyStreamSources: skyStreamSources,
            kanzenModules: kanzenModules,
            aidokuSources: aidokuSources,
            contentDigest: contentDigestExcludingCloudKitMediaState,
            contentDigestExcludingCloudKitMediaState: contentDigestExcludingCloudKitMediaState
        )
    }

    init(
        libraryItems: Int,
        movieProgress: Int,
        episodeProgress: Int,
        mangaLibraryItems: Int,
        mangaReadingProgress: Int,
        userRatings: Int,
        services: Int,
        stremioAddons: Int,
        skyStreamSources: Int,
        kanzenModules: Int,
        aidokuSources: Int,
        contentDigest: String?,
        contentDigestExcludingCloudKitMediaState: String?
    ) {
        self.libraryItems = Self.boundedCount(libraryItems)
        self.movieProgress = Self.boundedCount(movieProgress)
        self.episodeProgress = Self.boundedCount(episodeProgress)
        self.mangaLibraryItems = Self.boundedCount(mangaLibraryItems)
        self.mangaReadingProgress = Self.boundedCount(mangaReadingProgress)
        self.userRatings = Self.boundedCount(userRatings)
        self.services = Self.boundedCount(services)
        self.stremioAddons = Self.boundedCount(stremioAddons)
        self.skyStreamSources = Self.boundedCount(skyStreamSources)
        self.kanzenModules = Self.boundedCount(kanzenModules)
        self.aidokuSources = Self.boundedCount(aidokuSources)
        self.contentDigest = contentDigest
        self.contentDigestExcludingCloudKitMediaState = contentDigestExcludingCloudKitMediaState
    }

    private enum CodingKeys: String, CodingKey {
        case libraryItems, movieProgress, episodeProgress, mangaLibraryItems
        case mangaReadingProgress, userRatings, services, stremioAddons
        case skyStreamSources, kanzenModules, aidokuSources, contentDigest
        case contentDigestExcludingCloudKitMediaState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryItems = try Self.decodeCount(from: container, forKey: .libraryItems)
        movieProgress = try Self.decodeCount(from: container, forKey: .movieProgress)
        episodeProgress = try Self.decodeCount(from: container, forKey: .episodeProgress)
        mangaLibraryItems = try Self.decodeCount(from: container, forKey: .mangaLibraryItems)
        mangaReadingProgress = try Self.decodeCount(from: container, forKey: .mangaReadingProgress)
        userRatings = try Self.decodeCount(from: container, forKey: .userRatings)
        services = try Self.decodeCount(from: container, forKey: .services)
        stremioAddons = try Self.decodeCount(from: container, forKey: .stremioAddons)
        skyStreamSources = try Self.decodeCount(from: container, forKey: .skyStreamSources)
        kanzenModules = try Self.decodeCount(from: container, forKey: .kanzenModules)
        aidokuSources = try Self.decodeCount(from: container, forKey: .aidokuSources)
        contentDigest = try container.decodeIfPresent(String.self, forKey: .contentDigest)
        contentDigestExcludingCloudKitMediaState = try container.decodeIfPresent(
            String.self,
            forKey: .contentDigestExcludingCloudKitMediaState
        )
    }

    private var counts: [Int] {
        [
            libraryItems,
            movieProgress,
            episodeProgress,
            mangaLibraryItems,
            mangaReadingProgress,
            userRatings,
            services,
            stremioAddons,
            skyStreamSources,
            kanzenModules,
            aidokuSources
        ]
    }

    private static func decodeCount(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Int {
        let value = try container.decodeIfPresent(Int.self, forKey: key) ?? 0
        guard (0...maximumDomainRecordCount).contains(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Snapshot footprint count is negative or exceeds its bound."
            )
        }
        return value
    }

    private static func boundedCount(_ value: Int) -> Int {
        min(max(0, value), maximumDomainRecordCount)
    }

    private static func boundedSum(_ values: [Int]) -> Int {
        min(safeSum(values), maximumDomainRecordCount)
    }

    private static func safeSum(_ values: [Int]) -> Int {
        values.reduce(into: 0) { total, value in
            let nonnegative = max(0, value)
            let (sum, overflow) = total.addingReportingOverflow(nonnegative)
            total = overflow ? Int.max : sum
        }
    }

    private static func stableContentDigests(
        for data: Data
    ) -> (full: String?, excludingCloudKitMediaState: String?) {
#if canImport(CryptoKit)
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        object.removeValue(forKey: "createdDate")
        object.removeValue(forKey: "version")
        [
            "githubReleaseUpdateAvailable",
            "githubReleaseLatestVersion",
            "githubReleaseURL",
            "githubReleaseShowAlertPending",
            "githubReleaseLastPromptedVersion",
            "localNotificationSubscriptions",
            "localNotificationEpisodeReminders"
        ].forEach { object.removeValue(forKey: $0) }
        if var skyStream = object["skyStream"] as? [String: Any] {
            skyStream.removeValue(forKey: "createdAt")
            object["skyStream"] = skyStream
        }
        object = scrubTransientCloudMetadata(object) as? [String: Any] ?? object
        guard let normalizedData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return (nil, nil)
        }
        let full = SHA256.hash(data: normalizedData)
            .map { String(format: "%02x", $0) }
            .joined()
#if DEBUG
        if ProcessInfo.processInfo.environment["ECLIPSE_DEBUG_DIGEST_DUMP"] == "1",
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            try? normalizedData.write(
                to: documents.appendingPathComponent("digest-dump-\(stamp)-\(String(full.prefix(8))).json")
            )
        }
#endif
        var excludingMediaState = object
        [
            "collections",
            "progressData",
            "userRatings",
            "userRatingNotes",
            "catalogs",
            "mediaStateSettings"
        ].forEach { excludingMediaState.removeValue(forKey: $0) }
        if let profiles = excludingMediaState["profiles"] as? [[String: Any]] {
            let canonicalProfileKeys: Set<String> = [

                "name", "avatarSymbol", "avatarColorHex", "avatarPhotoData",
                "isKidsProfile", "createdAt", "pinHash", "pinChangedAt",
                "kidsFlagChangedAt",

                "collections", "progressData", "catalogs", "userRatings",
                "userRatingNotes", "progressWasCaptured",
                "ratingsWereCaptured", "collectionsWereCaptured",
                "catalogsWereCaptured"
            ]
            excludingMediaState["profiles"] = profiles.map { profile in
                var sourceAndReaderOnly = profile.filter {
                    !canonicalProfileKeys.contains($0.key)
                }
                if var settings = sourceAndReaderOnly["settings"] as? [String: Any] {
                    for key in Array(settings.keys)
                    where MediaStateSettingRegistry.scope(for: key) != nil {
                        settings.removeValue(forKey: key)
                    }
                    sourceAndReaderOnly["settings"] = settings
                }
                return sourceAndReaderOnly
            }
        }
        guard let mediaIndependentData = try? JSONSerialization.data(
            withJSONObject: excludingMediaState,
            options: [.sortedKeys]
        ) else {
            return (full, nil)
        }
        let excluding = SHA256.hash(data: mediaIndependentData)
            .map { String(format: "%02x", $0) }
            .joined()
        return (full, excluding)
#else
        return (nil, nil)
#endif
    }

    private static func scrubTransientCloudMetadata(_ value: Any) -> Any {
        let transientKeys: Set<String> = [
            "createdAt", "lastRefresh", "lastRefreshedAt", "lastError", "lastUpdated",
            "installedAt", "updatedAt", "pinnedAt", "evaluatedAt",
            "lastAutoUpdate", "detectedAt", "lastSourceRefresh", "sourceRefreshError"
        ]
        let embeddedJSONBlobKeys: Set<String> = ["metadataJSON"]
        let unorderedStringSetKeys: Set<String> = [
            "runtimeCapabilities", "secretPreferenceKeys", "declaredDomains", "userApprovedDomains"
        ]
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                guard !transientKeys.contains(entry.key) else { return }
                if embeddedJSONBlobKeys.contains(entry.key),
                   let normalized = normalizedEmbeddedJSONBlobForDigest(entry.value) {
                    result[entry.key] = normalized
                    return
                }
                if unorderedStringSetKeys.contains(entry.key),
                   let strings = entry.value as? [String] {
                    result[entry.key] = strings.sorted()
                    return
                }
                result[entry.key] = scrubTransientCloudMetadata(entry.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(scrubTransientCloudMetadata)
        }
        return value
    }

    private static func normalizedEmbeddedJSONBlobForDigest(_ value: Any) -> String? {
        guard let base64 = value as? String,
              let data = Data(base64Encoded: base64),
              let decoded = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let scrubbed = scrubTransientCloudMetadata(decoded)
        guard JSONSerialization.isValidJSONObject(scrubbed),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: scrubbed,
                  options: [.sortedKeys]
              ) else {
            return nil
        }
        return String(decoding: canonical, as: UTF8.self)
    }
}

struct ExperimentalCloudSnapshot: @unchecked Sendable {
    let data: Data
    let footprint: ExperimentalCloudSnapshotFootprint
}

struct ExperimentalCloudRestoreResult: Sendable {
    let authoritativeTrackerProfileIDs: Set<UUID>
}

#if !os(tvOS)
enum ReaderExtensionRestoreReloadPolicy {
    static func restoreSurvives(_ error: Error) -> Bool {
        guard let readerError = error as? ReaderExtensionError else { return false }
        return readerError == .runtimeUnavailable
    }
}
#endif

enum ExperimentalCloudBackupDomainReadiness {
    case ready
    case loading
    case unavailable
}

enum ManualBackupRestoreScope: Sendable {
    case thisDeviceOnly
    case replaceEverywhere

    var keepsChangesOnThisDevice: Bool {
        switch self {
        case .thisDeviceOnly:
            return true
        case .replaceEverywhere:
            return false
        }
    }
}

enum BackupReaderUpscaleModelRestorePolicy {
    static func modelNameToApply(
        incoming: String,
        preservesDeviceLocalSelection: Bool
    ) -> String? {
        preservesDeviceLocalSelection ? nil : incoming
    }
}

enum ExperimentalCloudSnapshotPreparation: @unchecked Sendable {
    case ready(ExperimentalCloudSnapshot)
    case deferredWhileSourcesLoad
    case sourcesUnavailable
    case failed

    var snapshot: ExperimentalCloudSnapshot? {
        guard case let .ready(snapshot) = self else { return nil }
        return snapshot
    }
}

struct ExperimentalCloudRestoreBoundaryContext: Codable, Equatable, Sendable {
    let providerRawValue: String
    let generation: Int
    let pendingIdentity: String?
    let outgoingProfileIDs: [UUID]
    let restoredTrackerProfileIDs: [UUID]

    init(
        providerRawValue: String,
        generation: Int,
        pendingIdentity: String?,
        outgoingProfileIDs: [UUID],
        restoredTrackerProfileIDs: [UUID] = []
    ) {
        self.providerRawValue = providerRawValue
        self.generation = generation
        self.pendingIdentity = pendingIdentity
        self.outgoingProfileIDs = outgoingProfileIDs
        self.restoredTrackerProfileIDs = restoredTrackerProfileIDs
    }

    private enum CodingKeys: String, CodingKey {
        case providerRawValue
        case generation
        case pendingIdentity
        case outgoingProfileIDs
        case restoredTrackerProfileIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerRawValue = try container.decode(String.self, forKey: .providerRawValue)
        generation = try container.decode(Int.self, forKey: .generation)
        pendingIdentity = try container.decodeIfPresent(String.self, forKey: .pendingIdentity)
        outgoingProfileIDs = try container.decode([UUID].self, forKey: .outgoingProfileIDs)
        restoredTrackerProfileIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .restoredTrackerProfileIDs
        ) ?? []
    }
}

enum ExperimentalCloudTrackerAccountBoundaryPolicy {
    static func profileIDsToClear(
        outgoingProfileIDs: Set<UUID>,
        restoredTrackerProfileIDs: Set<UUID>
    ) -> Set<UUID> {
        outgoingProfileIDs.subtracting(restoredTrackerProfileIDs)
    }
}

enum ExperimentalCloudRestoreRecoveryKind: String, Codable, Sendable {
    case ordinaryCloudRestore
    case accountBoundary
}

enum ExperimentalCloudRestoreTransactionState: String, Codable, Sendable {

    case preparing
    case prepared

    case keepLocalWriteAuthorized

    case commitAuthorized

    case completed
}

struct ExperimentalCloudRestoreRecoveryManifest: Codable, Sendable {
    let schemaVersion: Int
    let transactionID: UUID
    var state: ExperimentalCloudRestoreTransactionState
    let recoveryKind: ExperimentalCloudRestoreRecoveryKind
    var accountBoundaryContext: ExperimentalCloudRestoreBoundaryContext?
    let hasCanonicalArchiveRecovery: Bool
    let hasMediaStateRecoveryTransaction: Bool
    let keepLocalTransportPayloadByteCount: Int?
    let keepLocalTransportPayloadSHA256: String?

    init(
        transactionID: UUID,
        state: ExperimentalCloudRestoreTransactionState,
        accountBoundaryContext: ExperimentalCloudRestoreBoundaryContext?,
        hasCanonicalArchiveRecovery: Bool,
        hasMediaStateRecoveryTransaction: Bool,
        keepLocalTransportPayload: Data? = nil
    ) {
        schemaVersion = 2
        self.transactionID = transactionID
        self.state = state
        recoveryKind = accountBoundaryContext == nil
            ? .ordinaryCloudRestore
            : .accountBoundary
        self.accountBoundaryContext = accountBoundaryContext
        self.hasCanonicalArchiveRecovery = hasCanonicalArchiveRecovery
        self.hasMediaStateRecoveryTransaction = hasMediaStateRecoveryTransaction
        keepLocalTransportPayloadByteCount = keepLocalTransportPayload?.count
#if canImport(CryptoKit)
        keepLocalTransportPayloadSHA256 = keepLocalTransportPayload.map {
            SHA256.hash(data: $0)
                .map { String(format: "%02x", $0) }
                .joined()
        }
#else
        keepLocalTransportPayloadSHA256 = keepLocalTransportPayload == nil ? nil : ""
#endif
    }

    var hasKeepLocalTransportPayload: Bool {
        keepLocalTransportPayloadByteCount != nil
            && keepLocalTransportPayloadSHA256 != nil
    }

    func validatesKeepLocalTransportPayload(_ payload: Data) -> Bool {
        guard let expectedByteCount = keepLocalTransportPayloadByteCount,
              let expectedDigest = keepLocalTransportPayloadSHA256,
              payload.count == expectedByteCount else {
            return false
        }
#if canImport(CryptoKit)
        let digest = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
        return digest == expectedDigest
#else
        return expectedDigest.isEmpty
#endif
    }
}

struct ExperimentalCloudKeepLocalReplay: @unchecked Sendable {
    let transactionID: UUID
    let context: ExperimentalCloudRestoreBoundaryContext
    let snapshot: ExperimentalCloudSnapshot
}

enum ExperimentalCloudTrackerCleanupAuthority: Sendable {
    case none
    case authorized(ExperimentalCloudRestoreBoundaryContext)
    case blocked
}

struct ExperimentalCloudRestoreRecoveryOwnership: Codable, Sendable {
    let schemaVersion: Int
    let transactionID: UUID
    let recoveryKind: ExperimentalCloudRestoreRecoveryKind
    let payloadByteCount: Int
    let payloadSHA256: String

    init(
        transactionID: UUID,
        recoveryKind: ExperimentalCloudRestoreRecoveryKind,
        payload: Data
    ) {
        schemaVersion = 1
        self.transactionID = transactionID
        self.recoveryKind = recoveryKind
        payloadByteCount = payload.count
#if canImport(CryptoKit)
        payloadSHA256 = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
#else
        payloadSHA256 = ""
#endif
    }

    func validates(
        transactionID expectedTransactionID: UUID,
        recoveryKind expectedRecoveryKind: ExperimentalCloudRestoreRecoveryKind,
        payload: Data
    ) -> Bool {
        guard schemaVersion == 1,
              transactionID == expectedTransactionID,
              recoveryKind == expectedRecoveryKind,
              payloadByteCount == payload.count else {
            return false
        }
#if canImport(CryptoKit)
        let digest = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
        return payloadSHA256 == digest
#else
        return payloadSHA256.isEmpty
#endif
    }
}

extension Notification.Name {
    static let experimentalCloudRestoreRecoveryDidComplete = Notification.Name(
        "experimentalCloudRestoreRecoveryDidComplete"
    )
}

struct BackupCollection: Codable {
    private static let maximumItemCount = 100_000

    let id: UUID
    let name: String
    let items: [LibraryItem]
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, items, description
    }

    /// Consume each array element through its own decoder so one hostile media
    /// identity cannot make a present collection (or neighboring valid items)
    /// disappear. The collection's `items` key remains required: missing/null
    /// still fails the collection decode and therefore cannot acquire empty
    /// replacement authority.
    private struct LossyLibraryItems: Decodable {
        let values: [LibraryItem]

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            if let count = container.count,
               count > BackupCollection.maximumItemCount {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Backup collection contains too many items."
                )
            }
            var decoded: [LibraryItem] = []
            decoded.reserveCapacity(
                min(container.count ?? 0, BackupCollection.maximumItemCount)
            )
            var consumedCount = 0
            while !container.isAtEnd {
                guard consumedCount < BackupCollection.maximumItemCount else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Backup collection contains too many items."
                    )
                }
                let candidate = try container.decode(LossyLibraryItem.self)
                consumedCount += 1
                if let value = candidate.value {
                    decoded.append(value)
                }
            }
            values = decoded
        }
    }

    private struct LossyLibraryItem: Decodable {
        let value: LibraryItem?

        init(from decoder: Decoder) throws {
            value = try? LibraryItem(from: decoder)
        }
    }

    init(id: UUID, name: String, items: [LibraryItem], description: String?) {
        self.id = id
        self.name = name
        self.items = Self.sanitizedItems(items)
        self.description = description
    }

    init(from collection: LibraryCollection) {
        self.init(
            id: collection.id,
            name: collection.name,
            items: collection.items,
            description: collection.description
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            items: try container.decode(LossyLibraryItems.self, forKey: .items).values,
            description: try container.decodeIfPresent(String.self, forKey: .description)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(Self.sanitizedItems(items), forKey: .items)
        try container.encodeIfPresent(description, forKey: .description)
    }

    var sanitizedForPersistence: BackupCollection {
        BackupCollection(id: id, name: name, items: items, description: description)
    }

    func toLibraryCollection() -> LibraryCollection {
        LibraryCollection(
            id: id,
            name: name,
            items: Self.sanitizedItems(items),
            description: description
        )
    }

    private static func sanitizedItems(_ items: [LibraryItem]) -> [LibraryItem] {
        Array(items.compactMap { item -> LibraryItem? in
            guard let result = item.searchResult.sanitizedForPersistence else { return nil }
            return LibraryItem(searchResult: result, dateAdded: item.dateAdded)
        }.prefix(maximumItemCount))
    }
}

class BackupManager {
    static let shared = BackupManager()

    static func topLevelDomainIsAuthoritative(
        payloadWasDecoded: Bool,
        profileCaptureFlag: Bool?
    ) -> Bool {
        payloadWasDecoded && (profileCaptureFlag ?? true)
    }

    private let manualBackupFailureLock = NSLock()
    private var manualBackupFailureReason: String?

    var lastManualBackupFailureReason: String? {
        manualBackupFailureLock.lock()
        defer { manualBackupFailureLock.unlock() }
        return manualBackupFailureReason
    }

    private func recordManualBackupFailureReason(_ reason: String?) {
        manualBackupFailureLock.lock()
        defer { manualBackupFailureLock.unlock() }
        manualBackupFailureReason = reason
    }

    private enum BackupCreationError: LocalizedError {
        case sharedSourcePayloadBudgetExceeded(Int)
        case activeProfileChanged
        case profileRosterUnreadable
        case activeProfileCompatibilityDomainsUnreadable([String])
        case privateCloudConfigurationIncomplete

        var errorDescription: String? {
            switch self {
            case .sharedSourcePayloadBudgetExceeded(let count):
                return "Backup needs \(count) additional inactive-profile source payload(s). Remove unused packages or reduce their size before exporting."
            case .activeProfileChanged:
                return "The active profile or profile roster changed while the backup was being captured. Try exporting again."
            case .profileRosterUnreadable:
                return "The saved profile roster could not be read, so Eclipse refused to export an authoritative fallback roster. Restore a valid backup or edit the profile roster, then try again."
            case .activeProfileCompatibilityDomainsUnreadable(let domains):
                return "The active profile's \(domains.joined(separator: ", ")) data could not be read. Eclipse refused to create a backup whose legacy compatibility copy could erase healthy data when restored by an older version."
            case .privateCloudConfigurationIncomplete:
                return "A private cloud configuration domain could not be captured completely, so Eclipse left the existing cloud snapshot unchanged."
            }
        }
    }

    private enum BackupRestoreError: LocalizedError {
        case activeProfileChanged

        var errorDescription: String? {
            "The active profile or profile roster changed while the restore was starting. Try importing again."
        }
    }

    private struct ActiveProfileScopeToken: Equatable {
        let profileID: UUID
        let servicesGeneration: Int
        let rosterGeneration: UInt64
    }

    private struct BackupApplicationResult {
        let authoritativeTrackerProfileIDs: Set<UUID>
    }

    private struct ScopedBackupApplicationResult {
        let scope: ActiveProfileScopeToken
        let authoritativeTrackerProfileIDs: Set<UUID>
    }

    private struct PrivateConfigurationRestoreResult {
        let wasRestored: Bool
        let authoritativeTrackerProfileIDs: Set<UUID>
    }

    private struct ShareServicesRestoreTransaction {
        let previousValue: Bool
        let requestedValue: Bool
        let activeProfileID: UUID
        let targetUsesSharedDefaults: Bool
        let targetStoreSnapshot: ServiceStoreScope.StoreFileSnapshot?
        let targetSettingsBeforeTransition: [String: Data]

        var didSwitch: Bool { previousValue != requestedValue }
    }

    private struct ShareServicesRestoreStart {
        let transaction: ShareServicesRestoreTransaction
        let scope: ActiveProfileScopeToken
    }

    private struct BackupCaptureContext {
        let scope: ActiveProfileScopeToken
        let profiles: [Profile]
    }

    static let maximumManualBackupFileBytes = 128 * 1_024 * 1_024

    private static let maximumExperimentalCloudSnapshotBytes = 50_000_000

    private static let maximumSharedSourcePayloadBytes = 32 * 1_024 * 1_024

    private static let maximumSkyStreamScriptBytes = 10 * 1_024 * 1_024
    private static let maximumSkyStreamArchiveBytes = 20 * 1_024 * 1_024


    private let fileManager = FileManager.default
    private let dateFormatter = ISO8601DateFormatter()

    private var opaqueSkyStreamStorageRootURL: URL? {
        guard let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return root
            .appendingPathComponent("Eclipse", isDirectory: true)
            .appendingPathComponent("SkyStream", isDirectory: true)
    }

    private var manualOpaqueSkyStreamSnapshotURL: URL? {
        opaqueSkyStreamStorageRootURL?.appendingPathComponent(
            SkyStreamOpaqueStorageLayout.manualBackupFilename,
            isDirectory: false
        )
    }

    private var cloudOpaqueSkyStreamSnapshotURL: URL? {
        opaqueSkyStreamStorageRootURL?.appendingPathComponent(
            SkyStreamOpaqueStorageLayout.experimentalCloudBackupFilename,
            isDirectory: false
        )
    }

    private var legacyOpaqueSkyStreamSnapshotURL: URL? {
        opaqueSkyStreamStorageRootURL?.appendingPathComponent(
            SkyStreamOpaqueStorageLayout.legacySharedFilename,
            isDirectory: false
        )
    }

    private func loadOpaqueSkyStreamSnapshot(preferringSafeCloud: Bool) -> SkyStreamBackupSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manualCandidates = [manualOpaqueSkyStreamSnapshotURL, legacyOpaqueSkyStreamSnapshotURL]
            .compactMap { $0 }
            .map { ($0, Self.maximumManualBackupFileBytes, false) }
        let cloudCandidates = [cloudOpaqueSkyStreamSnapshotURL]
            .compactMap { $0 }
            .map { ($0, Self.maximumExperimentalCloudSnapshotBytes, true) }
        let candidates = preferringSafeCloud
            ? cloudCandidates + manualCandidates
            : manualCandidates + cloudCandidates
        for (url, maximumBytes, requiresSafeCloudFlag) in candidates {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= maximumBytes,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count <= maximumBytes,
                  let snapshot = try? decoder.decode(SkyStreamBackupSnapshot.self, from: data),
                  !requiresSafeCloudFlag || snapshot.isSafeCloudSnapshot else {
                continue
            }
            return snapshot
        }
        return nil
    }

    private func persistOpaqueSkyStreamSnapshot(_ snapshot: SkyStreamBackupSnapshot) throws {
        let canonicalSnapshot: SkyStreamBackupSnapshot
        let maximumBytes: Int
        let url: URL
        if snapshot.isSafeCloudSnapshot {
            guard let sanitized = BackupData.skyStreamSnapshotForExperimentalCloudSync(snapshot),
                  let cloudURL = cloudOpaqueSkyStreamSnapshotURL else {
                throw CocoaError(.fileReadCorruptFile)
            }
            canonicalSnapshot = sanitized
            maximumBytes = Self.maximumExperimentalCloudSnapshotBytes
            url = cloudURL
        } else {
            guard let manualURL = manualOpaqueSkyStreamSnapshotURL else {
                throw CocoaError(.fileNoSuchFile)
            }
            canonicalSnapshot = snapshot
            maximumBytes = Self.maximumManualBackupFileBytes
            url = manualURL
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(canonicalSnapshot)
        guard data.count <= maximumBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try data.write(to: url, options: .atomic)
        for filename in SkyStreamOpaqueStorageLayout.filenamesInvalidatedAfterWrite(
            isSafeCloudSnapshot: snapshot.isSafeCloudSnapshot
        ) {
            let staleURL = url.deletingLastPathComponent().appendingPathComponent(filename)
            if fileManager.fileExists(atPath: staleURL.path) {
                try fileManager.removeItem(at: staleURL)
            }
        }
    }

    private func clearAdoptedOpaqueSkyStreamSnapshot(isSafeCloudSnapshot: Bool) {
        let candidates: [URL?]
        if isSafeCloudSnapshot {
            candidates = [cloudOpaqueSkyStreamSnapshotURL]
        } else {
            candidates = [
                manualOpaqueSkyStreamSnapshotURL,
                legacyOpaqueSkyStreamSnapshotURL,
                cloudOpaqueSkyStreamSnapshotURL
            ]
        }
        for url in candidates.compactMap({ $0 }) where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                Logger.shared.log(
                    "Failed to clear adopted opaque SkyStream snapshot errorType=\(String(reflecting: type(of: error)))",
                    type: "Error"
                )
            }
        }
    }

    private func performOnMainThread(_ work: () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func activeProfileScopeToken() -> ActiveProfileScopeToken {
        var token = ActiveProfileScopeToken(
            profileID: ProfileManager.defaultProfileID,
            servicesGeneration: -1,
            rosterGeneration: 0
        )
        performOnMainThread {
            token = ActiveProfileScopeToken(
                profileID: ProfileManager.shared.activeProfileID,
                servicesGeneration: ServiceStoreScope.generation,
                rosterGeneration: ProfileManager.shared.rosterGeneration
            )
        }
        return token
    }

    private func backupCaptureContext() -> BackupCaptureContext? {
        var context: BackupCaptureContext?
        performOnMainThread {
            let manager = ProfileManager.shared
            guard let profiles = manager.profilesForMediaStateSync else { return }
            context = BackupCaptureContext(
                scope: ActiveProfileScopeToken(
                    profileID: manager.activeProfileID,
                    servicesGeneration: ServiceStoreScope.generation,
                    rosterGeneration: manager.rosterGeneration
                ),
                profiles: profiles
            )
        }
        return context
    }

    private func activeProfileScopeIsCurrent(
        _ token: ActiveProfileScopeToken,
        includingRoster: Bool = true
    ) -> Bool {
        var isCurrent = false
        performOnMainThread {
            isCurrent = ProfileManager.shared.activeProfileID == token.profileID
                && ServiceStoreScope.isCurrent(token.servicesGeneration)
                && (!includingRoster
                    || ProfileManager.shared.rosterGeneration == token.rosterGeneration)
        }
        return isCurrent
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

    static func trackerStateWithoutCredentials(_ state: TrackerState) -> TrackerState {
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

    private struct LegacyCloudMediaStateAuthority {
        let profileID: UUID
        let settings: MediaStateLegacyRestoreSettingSnapshot

        let collections: [LibraryCollection]?
        let progress: ProgressData?
        let ratings: (values: [String: Double], notes: [String: String])?
        let catalogs: [Catalog]?
    }

    private func captureLegacyCloudMediaStateAuthority() -> LegacyCloudMediaStateAuthority {
        let defaults = UserDefaults.standard
        let persistentDomain: [String: Any]
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            persistentDomain = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
        } else {

            persistentDomain = defaults.dictionaryRepresentation()
        }

        var collections: [LibraryCollection]?
        var progress: ProgressData?
        var ratings: (values: [String: Double], notes: [String: String])?
        var catalogs: [Catalog]?
        performOnMainThread {

            let profileManager = ProfileManager.shared
            guard profileManager.rosterStoreIsReadable else { return }
            let owner = profileManager.activeProfileID
            collections = LibraryManager.shared.collections(forProfile: owner)
            progress = ProgressManager.shared.progressData(forProfile: owner)
            if let pair = UserRatingManager.shared.ratingsAndNotes(forProfile: owner) {
                ratings = (values: pair.ratings, notes: pair.notes)
            }
            catalogs = CatalogManager.shared.catalogsForBackup(forProfile: owner)
        }

        return LegacyCloudMediaStateAuthority(
            profileID: ProfileManager.shared.activeProfileID,
            settings: MediaStateLegacyRestoreSettingSnapshot(persistentDomain: persistentDomain),
            collections: collections,
            progress: progress,
            ratings: ratings,
            catalogs: catalogs
        )
    }

    private func restoreLegacyCloudMediaStateAuthority(_ authority: LegacyCloudMediaStateAuthority) {
        performOnMainThread {
            let defaults = UserDefaults.standard
            authority.settings.restore(to: defaults)

            if let collections = authority.collections {
                LibraryManager.shared.replaceCollectionsForMediaState(collections)
            }
            if let progress = authority.progress {
                ProgressManager.shared.replaceProgressDataForRestore(
                    progress,
                    expectedProfileID: authority.profileID
                )
            }
            if let ratings = authority.ratings {
                UserRatingManager.shared.restoreRatingsAndNotes(
                    ratings: ratings.values,
                    notes: ratings.notes
                )
            }

            if let catalogs = authority.catalogs {
                let catalogManager = CatalogManager.shared
                catalogManager.setPerformanceModeEnabled(
                    defaults.bool(forKey: PerformanceModeSettings.enabledKey)
                )
                catalogManager.catalogs = catalogs
                catalogManager.saveCatalogs()
            }

            HomeCatalogLayoutStore.shared.reloadFromStorage()
            Task { @MainActor in
                EclipseTheme.shared.reloadMediaAppearanceFromDefaults()
            }
        }
    }

    func createBackup() -> URL? {
        recordManualBackupFailureReason(nil)
        guard isSkyStreamBackupDomainReady() else {
            Logger.shared.log(
                "Backup deferred because the SkyStream plugin manager is still loading; no partial backup was written",
                type: "Info"
            )
            recordManualBackupFailureReason(
                "Sources are still loading. Wait a moment and try again."
            )
            return nil
        }
        do {
            let backupData = try gatherBackupData()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let jsonData = try encoder.encode(backupData)
            guard jsonData.count <= Self.maximumManualBackupFileBytes else {
                Logger.shared.log(
                    "Backup was not written because the encoded document exceeded the 128 MB safety limit",
                    type: "Error"
                )
                recordManualBackupFailureReason(
                    "The backup exceeded the 128 MB safety limit. Remove large source packages and try again."
                )
                return nil
            }

            let timestamp = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let filename = "Eclipse_Backup_\(formatter.string(from: timestamp)).json"

            let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let backupURL = documentsDir.appendingPathComponent(filename)

            try jsonData.write(to: backupURL, options: .atomic)
            Logger.shared.log("Backup created at: \(backupURL.path)", type: "Info")

            return backupURL
        } catch {
            Logger.shared.log("Failed to create backup: \(error.localizedDescription)", type: "Error")
            recordManualBackupFailureReason(error.localizedDescription)
            return nil
        }
    }

    func createExperimentalCloudSnapshotData() async -> Data? {
        await createExperimentalCloudSnapshot()?.data
    }

    @MainActor
    func createAccountBoundaryRecoverySnapshot() -> ExperimentalCloudSnapshot? {
        prepareAccountBoundaryRecoverySnapshot().snapshot
    }

    @MainActor
    func prepareAccountBoundaryRecoverySnapshot() -> ExperimentalCloudSnapshotPreparation {
        switch skyStreamBackupDomainReadiness() {
        case .ready:
            break
        case .loading:
            Logger.shared.log(
                "Account-boundary recovery snapshot deferred while SkyStream state is loading",
                type: "CloudSync"
            )
            return .deferredWhileSourcesLoad
        case .unavailable:
            Logger.shared.log(
                "Account-boundary recovery snapshot refused because SkyStream state failed to load",
                type: "CloudSync"
            )
            return .sourcesUnavailable
        }
        do {
            let snapshot = try gatherBackupData(
                useSafeCloudSkyStreamSnapshot: true,
                includePrivateCloudRecoveryPayloads: true
            )
            guard snapshot.privateCloudConfigurationWasCapturedCompletely else {
                throw BackupCreationError.privateCloudConfigurationIncomplete
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            guard data.count <= Self.maximumManualBackupFileBytes else {
                throw BoundedURLSessionError.responseTooLarge(
                    maximumBytes: Self.maximumManualBackupFileBytes
                )
            }
            return .ready(
                ExperimentalCloudSnapshot(
                    data: data,
                    footprint: ExperimentalCloudSnapshotFootprint(
                        snapshot: snapshot,
                        encodedData: data
                    )
                )
            )
        } catch {
            Logger.shared.log(
                "Failed to create protected account-boundary recovery snapshot: \(error.localizedDescription)",
                type: "CloudSync"
            )
            return .failed
        }
    }

    var backupDomainReadiness: ExperimentalCloudBackupDomainReadiness {
        skyStreamBackupDomainReadiness()
    }

    var isBackupDomainReadyForSnapshots: Bool {
        isSkyStreamBackupDomainReady()
    }

    func createExperimentalCloudSnapshot() async -> ExperimentalCloudSnapshot? {
        await prepareExperimentalCloudSnapshot().snapshot
    }

    func prepareExperimentalCloudSnapshot() async -> ExperimentalCloudSnapshotPreparation {
        switch skyStreamBackupDomainReadiness() {
        case .ready:
            break
        case .loading:
            Logger.shared.log(
                "Experimental cloud snapshot deferred while SkyStream state is loading",
                type: "CloudSync"
            )
            return .deferredWhileSourcesLoad
        case .unavailable:
            Logger.shared.log(
                "Experimental cloud snapshot refused because SkyStream state failed to load",
                type: "CloudSync"
            )
            return .sourcesUnavailable
        }
        do {
            let snapshot = try gatherBackupData(useSafeCloudSkyStreamSnapshot: true)
                .redactedForExperimentalCloudSync(stripSkyStreamArchives: true)
            guard snapshot.privateCloudConfigurationWasCapturedCompletely else {
                throw BackupCreationError.privateCloudConfigurationIncomplete
            }
            return .ready(try await Task.detached(priority: .utility) {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                var boundedSnapshot = snapshot
                var data = try encoder.encode(boundedSnapshot)

                if data.count > Self.maximumExperimentalCloudSnapshotBytes,
                   var skyStream = boundedSnapshot.skyStream {
                    let archiveIndexes = skyStream.plugins.indices
                        .filter { skyStream.plugins[$0].archivePayload != nil }
                        .sorted {
                            (skyStream.plugins[$0].archivePayload?.count ?? 0)
                                > (skyStream.plugins[$1].archivePayload?.count ?? 0)
                        }
                    for index in archiveIndexes {
                        skyStream.plugins[index].archivePayload = nil
                        skyStream.plugins[index].payloadWasRedacted = true
                        boundedSnapshot.skyStream = skyStream
                        data = try encoder.encode(boundedSnapshot)
                        if data.count <= Self.maximumExperimentalCloudSnapshotBytes { break }
                    }
                }

                guard data.count <= Self.maximumExperimentalCloudSnapshotBytes else {
                    throw BoundedURLSessionError.responseTooLarge(
                        maximumBytes: Self.maximumExperimentalCloudSnapshotBytes
                    )
                }
                return ExperimentalCloudSnapshot(
                    data: data,
                    footprint: ExperimentalCloudSnapshotFootprint(
                        snapshot: boundedSnapshot,
                        encodedData: data
                    )
                )
            }.value)
        } catch {
            Logger.shared.log("Failed to create experimental iCloud snapshot: \(error.localizedDescription)", type: "iCloud")
            return .failed
        }
    }

    func experimentalCloudSnapshotFootprint(from data: Data) -> ExperimentalCloudSnapshotFootprint? {
        do {
            guard Self.experimentalCloudSnapshotSchemaIsSupported(data) else {
                Logger.shared.log("Cloud snapshot uses a newer unsupported schema", type: "CloudSync")
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(BackupData.self, from: data).redactedForExperimentalCloudSync()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let canonicalData = try encoder.encode(snapshot)
            return ExperimentalCloudSnapshotFootprint(snapshot: snapshot, encodedData: canonicalData)
        } catch {
            Logger.shared.log("Failed to inspect experimental cloud snapshot: \(error.localizedDescription)", type: "CloudSync")
            return nil
        }
    }

    func restoreExperimentalCloudSnapshot(
        from data: Data,
        preserveMediaStateForCloudKit: Bool = true
    ) async -> ExperimentalCloudRestoreResult? {
        var shareServicesTransaction: ShareServicesRestoreTransaction?
        do {
            guard Self.experimentalCloudSnapshotSchemaIsSupported(data) else {
                Logger.shared.log("Refused to restore a newer unsupported cloud schema", type: "CloudSync")
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var snapshot = try decoder.decode(BackupData.self, from: data).redactedForExperimentalCloudSync()
            snapshot.removeReaderDomainsWithoutCompletePrivateCloudAuthority()
            let intendedScope = activeProfileScopeToken()
            let restoreStart = try await beginShareServicesRestoreTransaction(
                for: snapshot,
                expectedScope: intendedScope
            )
            let transaction = restoreStart.transaction
            shareServicesTransaction = transaction
            let restoreScope = restoreStart.scope
            snapshot.progressData = Self.mergingDeviceLocalProviderReferences(
                into: snapshot.progressData,
                current: ProgressManager.shared.getProgressData()
            )
            let ownsTopLevelSources = appliesTopLevelSourceData(
                snapshot,
                activeProfileID: restoreScope.profileID
            )
            guard await restoreSkyStreamSnapshotAndWaitIfSupported(
                ownsTopLevelSources ? snapshot.skyStream : nil,
                expectedScope: restoreScope
            ) else {
                await restoreShareServicesModeAfterFailedRestore(transaction)
                return nil
            }
            guard await restoreNuvioSnapshotIfSupported(
                ownsTopLevelSources ? snapshot.nuvioPlugins : nil,
                expectedScope: restoreScope,
                preservingDeviceLocalCloudState: true
            ) else {
                await restoreShareServicesModeAfterFailedRestore(transaction)
                return nil
            }
            guard let postApply = await applyBackupDataIfScopeIsCurrent(
                snapshot,
                refreshCloudSources: true,
                preservingLegacyCloudMediaState: preserveMediaStateForCloudKit,
                preservingDeviceLocalReaderModelSelection: true,
                expectedScope: restoreScope
            ) else {
                await restoreShareServicesModeAfterFailedRestore(transaction)
                return nil
            }
            let postApplyScope = postApply.scope

            await SkyStreamPluginManager.shared.captureSourceDefaultsState(
                expectedScopeGeneration: postApplyScope.servicesGeneration
            )

            await repairActiveProfileSkyStreamStateIfNeeded(
                snapshot,
                expectedScope: postApplyScope
            )
            guard await reloadSourceManagersAfterRestore(
                expectedScope: postApplyScope,
                toleratesInertReaderRuntime: true
            ) else {
                await restoreShareServicesModeAfterFailedRestore(transaction)
                return nil
            }
            completeShareServicesRestoreTransaction(transaction)
            return ExperimentalCloudRestoreResult(
                authoritativeTrackerProfileIDs: postApply.authoritativeTrackerProfileIDs
            )
        } catch {
            if let shareServicesTransaction {
                await restoreShareServicesModeAfterFailedRestore(shareServicesTransaction)
            }
            Logger.shared.log("Failed to restore experimental iCloud snapshot: \(error.localizedDescription)", type: "iCloud")
            return nil
        }
    }

    private static func experimentalCloudSnapshotSchemaIsSupported(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String else {
            return true
        }
        return compareSchemaVersion(version, to: BackupData.currentCloudSchemaVersion) != .orderedDescending
    }

    private static func compareSchemaVersion(_ lhs: String, to rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func mergingDeviceLocalProviderReferences(
        into incoming: ProgressData,
        current: ProgressData
    ) -> ProgressData {
        let currentMovies = Dictionary(
            current.movieProgress.map { ($0.id, $0) },
            uniquingKeysWith: { existing, candidate in
                candidate.lastUpdated >= existing.lastUpdated ? candidate : existing
            }
        )
        let currentEpisodes = Dictionary(
            current.episodeProgress.map { ($0.id, $0) },
            uniquingKeysWith: { existing, candidate in
                candidate.lastUpdated >= existing.lastUpdated ? candidate : existing
            }
        )

        var merged = incoming
        merged.movieProgress = incoming.movieProgress.map { entry in
            guard let local = currentMovies[entry.id] else { return entry }
            var result = entry
            result.lastHref = local.lastHref
            result.lastContentReference = local.lastContentReference
            result.lastServiceId = local.lastServiceId ?? entry.lastServiceId
            result.lastSourceId = local.lastSourceId ?? entry.lastSourceId
            return result
        }
        merged.episodeProgress = incoming.episodeProgress.map { entry in
            guard let local = currentEpisodes[entry.id] else { return entry }
            var result = entry
            result.lastHref = local.lastHref
            result.lastContentReference = local.lastContentReference
            result.lastServiceId = local.lastServiceId ?? entry.lastServiceId
            result.lastSourceId = local.lastSourceId ?? entry.lastSourceId
            return result
        }
        return merged
    }

    private static let experimentalCloudRestorePendingKey = "experimentalCloudRestorePendingV1"
    private static let experimentalCloudRestoreRecoveryPrefix = "CloudSyncRestoreRecovery."
    private static let experimentalCloudRestoreRecoverySuffix = ".json"
    private static let experimentalCloudRestoreOwnershipSuffix = ".owner.json"
    private static let experimentalCloudRestoreTransportSuffix = ".transport.json"
    private static let legacyExperimentalCloudRestoreRecoveryFilename = "CloudSyncRestoreRecovery.json"
    private static let maximumExperimentalCloudRestoreManifestBytes = 64 * 1_024
    private static let maximumExperimentalCloudRestoreOwnershipBytes = 16 * 1_024
    private static let maximumExperimentalCloudRestoreIdentityBytes = 4 * 1_024

    private enum ExperimentalCloudRestoreManifestLoadResult {
        case missing
        case unavailable(String)
        case invalid(String)
        case loaded(ExperimentalCloudRestoreRecoveryManifest)
    }

    private enum LegacyExperimentalCloudRestoreLoadResult {
        case missing
        case unavailable(String)
        case invalid(String)
        case loaded(Data)
    }

    private enum AuthorizedAccountBoundaryReplayDisposition {
        case adoptPending(CloudSyncProvider)
        case alreadyAdopted(CloudSyncProvider)
        case supersededConnection(CloudSyncProvider)
        case unavailable
        case invalid
    }

    private var activeExperimentalCloudRestoreTransactionID: UUID?
    private var experimentalCloudRestoreRecoveryTask: Task<Void, Never>?

    private static var experimentalCloudRestoreDirectoryURL: URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = applicationSupport.appendingPathComponent("Eclipse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static var legacyExperimentalCloudRestoreRecoveryURL: URL? {
        experimentalCloudRestoreDirectoryURL?.appendingPathComponent(
            legacyExperimentalCloudRestoreRecoveryFilename
        )
    }

    private static func experimentalCloudRestoreRecoveryURL(transactionID: UUID) -> URL? {
        experimentalCloudRestoreDirectoryURL?.appendingPathComponent(
            "\(experimentalCloudRestoreRecoveryPrefix)\(transactionID.uuidString)\(experimentalCloudRestoreRecoverySuffix)"
        )
    }

    private static func experimentalCloudRestoreOwnershipURL(transactionID: UUID) -> URL? {
        experimentalCloudRestoreDirectoryURL?.appendingPathComponent(
            "\(experimentalCloudRestoreRecoveryPrefix)\(transactionID.uuidString)\(experimentalCloudRestoreOwnershipSuffix)"
        )
    }

    private static func experimentalCloudRestoreTransportURL(transactionID: UUID) -> URL? {
        experimentalCloudRestoreDirectoryURL?.appendingPathComponent(
            "\(experimentalCloudRestoreRecoveryPrefix)\(transactionID.uuidString)\(experimentalCloudRestoreTransportSuffix)"
        )
    }

    private static var experimentalCloudRestoreManifestURL: URL? {
        experimentalCloudRestoreDirectoryURL?
            .appendingPathComponent("CloudSyncRestoreRecovery.manifest.json")
    }

    private static func isValidExperimentalCloudRestoreBoundaryContext(
        _ context: ExperimentalCloudRestoreBoundaryContext
    ) -> Bool {
        guard let provider = CloudSyncProvider(rawValue: context.providerRawValue),
              provider.requiresAccountConnection,
              context.generation >= 0,
              (context.pendingIdentity?.utf8.count ?? 0)
                <= maximumExperimentalCloudRestoreIdentityBytes,
              context.outgoingProfileIDs.count <= ProfileManager.maximumProfiles,
              Set(context.outgoingProfileIDs).count
                == context.outgoingProfileIDs.count,
              context.restoredTrackerProfileIDs.count <= ProfileManager.maximumProfiles,
              Set(context.restoredTrackerProfileIDs).count
                == context.restoredTrackerProfileIDs.count else {
            return false
        }
        return true
    }

    private static func experimentalCloudRestoreBoundaryAuthorityMatches(
        _ prepared: ExperimentalCloudRestoreBoundaryContext,
        _ committing: ExperimentalCloudRestoreBoundaryContext
    ) -> Bool {
        prepared.providerRawValue == committing.providerRawValue
            && prepared.generation == committing.generation
            && prepared.pendingIdentity == committing.pendingIdentity
            && prepared.outgoingProfileIDs == committing.outgoingProfileIDs
    }

    private static func boundedExperimentalCloudRestoreData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        let data = handle.readData(ofLength: maximumBytes + 1)
        guard data.count <= maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private static func loadExperimentalCloudRestoreManifest()
        -> ExperimentalCloudRestoreManifestLoadResult {
        guard let url = experimentalCloudRestoreManifestURL else {
            return .unavailable("Application Support is unavailable")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        let data: Data
        do {
            data = try boundedExperimentalCloudRestoreData(
                at: url,
                maximumBytes: maximumExperimentalCloudRestoreManifestBytes
            )
        } catch {
            return .unavailable(String(reflecting: type(of: error)))
        }
        let manifest: ExperimentalCloudRestoreRecoveryManifest
        do {
            manifest = try JSONDecoder().decode(
                ExperimentalCloudRestoreRecoveryManifest.self,
                from: data
            )
        } catch {
            return .invalid("manifest decode failed")
        }
        guard manifest.schemaVersion == 2 else {
            return .invalid("unsupported manifest schema")
        }
        switch (manifest.recoveryKind, manifest.accountBoundaryContext) {
        case (.ordinaryCloudRestore, nil):
            guard !manifest.hasCanonicalArchiveRecovery else {
                return .invalid("ordinary recovery claimed a canonical sidecar")
            }
        case (.accountBoundary, .some(let context)):
            guard isValidExperimentalCloudRestoreBoundaryContext(context) else {
                return .invalid("account-boundary context is invalid")
            }
        case (.ordinaryCloudRestore, .some), (.accountBoundary, nil):
            return .invalid("manifest kind and context disagree")
        }
        guard !manifest.hasCanonicalArchiveRecovery
                || manifest.hasMediaStateRecoveryTransaction else {
            return .invalid("canonical recovery is missing its media-state transaction")
        }
        if manifest.recoveryKind == .accountBoundary,
           manifest.hasCanonicalArchiveRecovery != manifest.hasMediaStateRecoveryTransaction {
            return .invalid("account-boundary media-state flags disagree")
        }
        if manifest.state == .commitAuthorized,
           manifest.recoveryKind != .accountBoundary {
            return .invalid("ordinary recovery cannot authorize an account-boundary commit")
        }
        let hasKeepLocalByteCount = manifest.keepLocalTransportPayloadByteCount != nil
        let hasKeepLocalDigest = manifest.keepLocalTransportPayloadSHA256 != nil
        guard hasKeepLocalByteCount == hasKeepLocalDigest else {
            return .invalid("keep-local payload ownership is incomplete")
        }
        if let byteCount = manifest.keepLocalTransportPayloadByteCount {
            guard manifest.recoveryKind == .accountBoundary,
                  byteCount > 0,
                  byteCount <= maximumExperimentalCloudSnapshotBytes,
                  let digest = manifest.keepLocalTransportPayloadSHA256,
                  digest.utf8.count <= 128,
                  manifest.accountBoundaryContext?.outgoingProfileIDs.isEmpty == true else {
                return .invalid("keep-local payload ownership is invalid")
            }
        }
        if manifest.state == .keepLocalWriteAuthorized,
           !manifest.hasKeepLocalTransportPayload {
            return .invalid("authorized keep-local recovery has no transport payload")
        }
        return .loaded(manifest)
    }

    private static func authorizedReplayDisposition(
        for context: ExperimentalCloudRestoreBoundaryContext
    ) -> AuthorizedAccountBoundaryReplayDisposition {
        guard let provider = CloudSyncProvider(rawValue: context.providerRawValue),
              provider.requiresAccountConnection else {
            return .invalid
        }
        let defaults = UserDefaults.standard
        let currentGeneration = defaults.integer(forKey: provider.accountGenerationKey)
        if currentGeneration > context.generation {
            return .supersededConnection(provider)
        }
        guard currentGeneration == context.generation else {
            return .invalid
        }

        let boundaryIsPending = defaults.bool(forKey: provider.accountBoundaryPendingKey)
        let parkedIdentity = defaults.string(forKey: provider.pendingAccountIdentityKey)
        let currentIdentity = defaults.string(forKey: provider.accountIdentityKey)
        let identityIsUnresolved = defaults.bool(forKey: provider.accountIdentityUnresolvedKey)
        let isFullyAdopted: Bool
        if let pendingIdentity = context.pendingIdentity {
            isFullyAdopted = !boundaryIsPending
                && parkedIdentity == nil
                && currentIdentity == pendingIdentity
                && !identityIsUnresolved
        } else {
            isFullyAdopted = !boundaryIsPending
                && parkedIdentity == nil
                && identityIsUnresolved
        }
        if isFullyAdopted {
            return .alreadyAdopted(provider)
        }

        let hasMatchingPendingEvidence: Bool
        if let pendingIdentity = context.pendingIdentity {
            hasMatchingPendingEvidence = parkedIdentity == pendingIdentity
                || currentIdentity == pendingIdentity
        } else {
            hasMatchingPendingEvidence = boundaryIsPending || identityIsUnresolved
        }
        guard (parkedIdentity == nil || parkedIdentity == context.pendingIdentity),
              hasMatchingPendingEvidence else {
            return .invalid
        }

        guard UIApplication.shared.isProtectedDataAvailable else {
            return .unavailable
        }
        guard CloudSyncTokenStore.hasToken(for: provider) else {
            return .invalid
        }
        return .adoptPending(provider)
    }

    static func accountBoundaryTrackerCleanupAuthority()
        -> ExperimentalCloudTrackerCleanupAuthority {
        switch loadExperimentalCloudRestoreManifest() {
        case .missing:

            return UserDefaults.standard.bool(
                forKey: experimentalCloudRestorePendingKey
            ) ? .blocked : .none
        case .unavailable, .invalid:

            return .blocked
        case .loaded(let manifest):
            switch manifest.state {
            case .preparing, .completed:
                return .none
            case .prepared:

                return manifest.hasKeepLocalTransportPayload ? .none : .blocked
            case .keepLocalWriteAuthorized:
                return .none
            case .commitAuthorized:
                break
            }
            guard let context = manifest.accountBoundaryContext else {
                return .blocked
            }

            return .authorized(context)
        }
    }

    private static func loadLegacyExperimentalCloudRestoreSnapshot()
        -> LegacyExperimentalCloudRestoreLoadResult {
        guard let url = legacyExperimentalCloudRestoreRecoveryURL else {
            return .unavailable("Application Support is unavailable")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                return .invalid("legacy recovery is not a regular file")
            }
            if let fileSize = values.fileSize,
               fileSize > maximumExperimentalCloudSnapshotBytes {
                return .invalid("legacy recovery exceeds the cloud snapshot limit")
            }
            let data = try boundedExperimentalCloudRestoreData(
                at: url,
                maximumBytes: maximumExperimentalCloudSnapshotBytes
            )
            guard experimentalCloudSnapshotSchemaIsSupported(data) else {
                return .invalid("legacy recovery uses an unsupported schema")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(BackupData.self, from: data)

            let safeSnapshot = decoded.redactedForExperimentalCloudSync()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let safeData = try encoder.encode(safeSnapshot)
            guard safeData.count <= maximumExperimentalCloudSnapshotBytes else {
                return .invalid("sanitized legacy recovery exceeds the cloud snapshot limit")
            }
            return .loaded(safeData)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return .unavailable("protected data is unavailable")
        } catch {
            return .invalid("legacy recovery validation failed")
        }
    }

    private static func writeExperimentalCloudRestoreManifest(
        _ manifest: ExperimentalCloudRestoreRecoveryManifest
    ) throws {
        guard let url = experimentalCloudRestoreManifestURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= maximumExperimentalCloudRestoreManifestBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private static func boundExperimentalCloudRestoreSnapshot(
        for manifest: ExperimentalCloudRestoreRecoveryManifest
    ) -> (url: URL, data: Data)? {
        guard let url = experimentalCloudRestoreRecoveryURL(
                transactionID: manifest.transactionID
              ),
              let ownershipURL = experimentalCloudRestoreOwnershipURL(
                transactionID: manifest.transactionID
              ),
              let data = try? boundedExperimentalCloudRestoreData(
                at: url,

                maximumBytes: maximumManualBackupFileBytes
              ),
              let ownershipData = try? boundedExperimentalCloudRestoreData(
                at: ownershipURL,
                maximumBytes: maximumExperimentalCloudRestoreOwnershipBytes
              ),
              let ownership = try? JSONDecoder().decode(
                ExperimentalCloudRestoreRecoveryOwnership.self,
                from: ownershipData
              ),
              ownership.validates(
                transactionID: manifest.transactionID,
                recoveryKind: manifest.recoveryKind,
                payload: data
              ) else {
            return nil
        }
        return (url, data)
    }

    private static func normalizedKeepLocalTransportPayload(from data: Data) throws -> Data {
        guard !data.isEmpty,
              data.count <= maximumManualBackupFileBytes,
              experimentalCloudSnapshotSchemaIsSupported(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BackupData.self, from: data)
        let safeSnapshot = decoded.redactedForExperimentalCloudSync(
            stripSkyStreamArchives: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let safeData = try encoder.encode(safeSnapshot)
        guard !safeData.isEmpty,
              safeData.count <= maximumExperimentalCloudSnapshotBytes else {
            throw BoundedURLSessionError.responseTooLarge(
                maximumBytes: maximumExperimentalCloudSnapshotBytes
            )
        }
        return safeData
    }

    private static func boundKeepLocalTransportPayload(
        for manifest: ExperimentalCloudRestoreRecoveryManifest
    ) -> Data? {
        guard manifest.hasKeepLocalTransportPayload,
              let url = experimentalCloudRestoreTransportURL(
                transactionID: manifest.transactionID
              ),
              let data = try? boundedExperimentalCloudRestoreData(
                at: url,
                maximumBytes: maximumExperimentalCloudSnapshotBytes
              ),
              manifest.validatesKeepLocalTransportPayload(data),
              experimentalCloudSnapshotSchemaIsSupported(data) else {
            return nil
        }
        return data
    }

    @MainActor
    func authorizedExperimentalCloudKeepLocalReplay()
        -> ExperimentalCloudKeepLocalReplay? {
        guard case .loaded(let manifest) = Self.loadExperimentalCloudRestoreManifest(),
              manifest.state == .keepLocalWriteAuthorized,
              activeExperimentalCloudRestoreTransactionID == manifest.transactionID,
              let context = manifest.accountBoundaryContext,
              let data = Self.boundKeepLocalTransportPayload(for: manifest),
              let footprint = experimentalCloudSnapshotFootprint(from: data) else {
            return nil
        }
        return ExperimentalCloudKeepLocalReplay(
            transactionID: manifest.transactionID,
            context: context,
            snapshot: ExperimentalCloudSnapshot(data: data, footprint: footprint)
        )
    }

    @MainActor
    func rebindAuthorizedExperimentalCloudKeepLocalReplay(
        providerRawValue: String,
        generation: Int,
        verifiedPendingIdentity: String
    ) -> ExperimentalCloudKeepLocalReplay? {
        guard !verifiedPendingIdentity.isEmpty,
              verifiedPendingIdentity.utf8.count
                <= Self.maximumExperimentalCloudRestoreIdentityBytes,
              case .loaded(var manifest) = Self.loadExperimentalCloudRestoreManifest(),
              manifest.state == .keepLocalWriteAuthorized,
              activeExperimentalCloudRestoreTransactionID == manifest.transactionID,
              let previousContext = manifest.accountBoundaryContext,
              previousContext.providerRawValue == providerRawValue,
              previousContext.pendingIdentity == verifiedPendingIdentity,
              previousContext.outgoingProfileIDs.isEmpty,
              generation >= previousContext.generation,
              let provider = CloudSyncProvider(rawValue: providerRawValue),
              provider.requiresAccountConnection,
              Self.boundKeepLocalTransportPayload(for: manifest) != nil else {
            return nil
        }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: provider.accountBoundaryPendingKey),
              defaults.integer(forKey: provider.accountGenerationKey) == generation,
              defaults.string(forKey: provider.pendingAccountIdentityKey)
                == verifiedPendingIdentity,
              CloudSyncTokenStore.hasToken(for: provider),
              defaults.synchronize() else {
            return nil
        }

        let reboundContext = ExperimentalCloudRestoreBoundaryContext(
            providerRawValue: providerRawValue,
            generation: generation,
            pendingIdentity: verifiedPendingIdentity,
            outgoingProfileIDs: []
        )
        guard Self.isValidExperimentalCloudRestoreBoundaryContext(reboundContext) else {
            return nil
        }
        if manifest.accountBoundaryContext != reboundContext {
            manifest.accountBoundaryContext = reboundContext
            do {
                try Self.writeExperimentalCloudRestoreManifest(manifest)
            } catch {
                Logger.shared.log(
                    "Could not rebind keep-local recovery to the verified account connection: \(error.localizedDescription)",
                    type: "CloudSync"
                )
                return nil
            }
        }
        return authorizedExperimentalCloudKeepLocalReplay()
    }

    private static func boundExperimentalCloudRestoreOwnershipIsValidForCleanup(
        _ manifest: ExperimentalCloudRestoreRecoveryManifest
    ) -> Bool {
        guard let recoveryURL = experimentalCloudRestoreRecoveryURL(
                transactionID: manifest.transactionID
              ),
              let ownershipURL = experimentalCloudRestoreOwnershipURL(
                transactionID: manifest.transactionID
              ) else {
            return false
        }
        let fileManager = FileManager.default
        let snapshotExists = fileManager.fileExists(atPath: recoveryURL.path)
        let ownershipExists = fileManager.fileExists(atPath: ownershipURL.path)
        if snapshotExists,
           boundExperimentalCloudRestoreSnapshot(for: manifest) == nil {
            return false
        }
        if manifest.hasKeepLocalTransportPayload,
           let transportURL = experimentalCloudRestoreTransportURL(
                transactionID: manifest.transactionID
           ),
           fileManager.fileExists(atPath: transportURL.path),
           boundKeepLocalTransportPayload(for: manifest) == nil {
            return false
        }
        if snapshotExists {
            return true
        }
        guard ownershipExists else { return true }
        guard let ownershipData = try? boundedExperimentalCloudRestoreData(
                at: ownershipURL,
                maximumBytes: maximumExperimentalCloudRestoreOwnershipBytes
              ),
              let ownership = try? JSONDecoder().decode(
                ExperimentalCloudRestoreRecoveryOwnership.self,
                from: ownershipData
              ) else {
            return false
        }
        return ownership.schemaVersion == 1
            && ownership.transactionID == manifest.transactionID
            && ownership.recoveryKind == manifest.recoveryKind
    }

    @MainActor
    func prepareExperimentalCloudRestoreRecovery(
        using snapshot: ExperimentalCloudSnapshot,
        accountBoundaryContext: ExperimentalCloudRestoreBoundaryContext? = nil,
        keepLocalTransportSnapshot: ExperimentalCloudSnapshot? = nil
    ) -> Bool {
        guard experimentalCloudRestoreRecoveryTask == nil,
              activeExperimentalCloudRestoreTransactionID == nil else {
            Logger.shared.log(
                "Refused to overwrite an unfinished cloud restore transaction",
                type: "CloudSync"
            )
            return false
        }

        switch Self.loadExperimentalCloudRestoreManifest() {
        case .loaded(let manifest) where manifest.state == .completed:
            activeExperimentalCloudRestoreTransactionID = manifest.transactionID
            guard durablyClearExperimentalCloudRestorePendingMirror(),
                  cleanupExperimentalCloudRestoreArtifacts(for: manifest) else {
                return false
            }
        case .missing:
            guard !UserDefaults.standard.bool(forKey: Self.experimentalCloudRestorePendingKey),
                  cleanupOrphanedExperimentalCloudRestoreArtifacts() else {
                Logger.shared.log(
                    "Refused to replace a cloud restore whose manifest is missing",
                    type: "CloudSync"
                )
                return false
            }
        case .loaded, .unavailable, .invalid:
            Logger.shared.log(
                "Refused to overwrite an unfinished or unreadable cloud restore transaction",
                type: "CloudSync"
            )
            return false
        }

        let keepLocalTransportPayload: Data?
        do {
            keepLocalTransportPayload = try keepLocalTransportSnapshot.map {
                try Self.normalizedKeepLocalTransportPayload(from: $0.data)
            }
        } catch {
            Logger.shared.log(
                "Refused an invalid keep-local transport recovery payload: \(error.localizedDescription)",
                type: "CloudSync"
            )
            return false
        }

        let transactionID = UUID()
        guard let url = Self.experimentalCloudRestoreRecoveryURL(transactionID: transactionID),
              let ownershipURL = Self.experimentalCloudRestoreOwnershipURL(
                transactionID: transactionID
              ),
              keepLocalTransportPayload == nil
                || Self.experimentalCloudRestoreTransportURL(transactionID: transactionID) != nil else {
            return false
        }
        let recoveryKind: ExperimentalCloudRestoreRecoveryKind = accountBoundaryContext == nil
            ? .ordinaryCloudRestore
            : .accountBoundary
        guard snapshot.data.count <= Self.maximumManualBackupFileBytes,
              accountBoundaryContext.map(Self.isValidExperimentalCloudRestoreBoundaryContext)
                ?? true,
              keepLocalTransportPayload == nil
                || (accountBoundaryContext?.outgoingProfileIDs.isEmpty == true) else {
            Logger.shared.log(
                "Refused an oversized or invalid cloud restore recovery point",
                type: "CloudSync"
            )
            return false
        }

        var intendsCanonicalArchiveRecovery = false
        var intendsMediaStateRecovery = false
#if os(iOS)
        if #available(iOS 17.0, *) {
            intendsMediaStateRecovery = true
            intendsCanonicalArchiveRecovery = accountBoundaryContext != nil
        }
#else
        guard accountBoundaryContext == nil else {
            return false
        }
#endif
        var manifest = ExperimentalCloudRestoreRecoveryManifest(
            transactionID: transactionID,
            state: .preparing,
            accountBoundaryContext: accountBoundaryContext,
            hasCanonicalArchiveRecovery: intendsCanonicalArchiveRecovery,
            hasMediaStateRecoveryTransaction: intendsMediaStateRecovery,
            keepLocalTransportPayload: keepLocalTransportPayload
        )
        activeExperimentalCloudRestoreTransactionID = transactionID
        var manifestWasPersisted = false
        var mediaStateRecoveryWasAttempted = false
        do {
            try snapshot.data.write(to: url, options: [.atomic, .completeFileProtection])
            let ownership = ExperimentalCloudRestoreRecoveryOwnership(
                transactionID: transactionID,
                recoveryKind: recoveryKind,
                payload: snapshot.data
            )
            let ownershipData = try JSONEncoder().encode(ownership)
            try ownershipData.write(
                to: ownershipURL,
                options: [.atomic, .completeFileProtection]
            )
            if let keepLocalTransportPayload,
               let transportURL = Self.experimentalCloudRestoreTransportURL(
                    transactionID: transactionID
               ) {
                try keepLocalTransportPayload.write(
                    to: transportURL,
                    options: [.atomic, .completeFileProtection]
                )
            }

            try Self.writeExperimentalCloudRestoreManifest(manifest)
            manifestWasPersisted = true
            UserDefaults.standard.set(true, forKey: Self.experimentalCloudRestorePendingKey)
            guard UserDefaults.standard.synchronize() else {
                throw CocoaError(.fileWriteUnknown)
            }
#if os(iOS)
            if #available(iOS 17.0, *) {
                mediaStateRecoveryWasAttempted = true
                if accountBoundaryContext != nil {
                    guard MediaStateSyncManager.shared
                        .prepareRemoteAccountBoundaryArchiveRecovery(transactionID: transactionID) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                } else {
                    guard MediaStateSyncManager.shared
                        .suspendMediaStateSyncForPreparedRecovery(transactionID: transactionID) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            }
#endif
            manifest.state = .prepared
            try Self.writeExperimentalCloudRestoreManifest(manifest)
            return true
        } catch {

            var mediaStateReleaseSucceeded = !intendsMediaStateRecovery
#if os(iOS)
            if mediaStateRecoveryWasAttempted, #available(iOS 17.0, *) {
                if intendsCanonicalArchiveRecovery {
                    mediaStateReleaseSucceeded = MediaStateSyncManager.shared
                        .completeRemoteAccountBoundaryArchiveRecovery(
                        transactionID: transactionID
                    )
                } else {
                    mediaStateReleaseSucceeded = MediaStateSyncManager.shared
                        .completeMediaStateSyncPreparedRecovery(transactionID: transactionID)
                }
            }
#endif
            if manifestWasPersisted {

                _ = discardPreparingExperimentalCloudRestore(
                    manifest,
                    mediaStateReleaseAlreadySucceeded: mediaStateReleaseSucceeded
                )
            } else {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: ownershipURL)
                if let transportURL = Self.experimentalCloudRestoreTransportURL(
                    transactionID: transactionID
                ) {
                    try? FileManager.default.removeItem(at: transportURL)
                }
                activeExperimentalCloudRestoreTransactionID = nil
            }
            Logger.shared.log(
                "Could not persist cloud restore recovery snapshot: \(error.localizedDescription)",
                type: "CloudSync"
            )
            return false
        }
    }

    @MainActor
    private func discardPreparingExperimentalCloudRestore(
        _ manifest: ExperimentalCloudRestoreRecoveryManifest,
        mediaStateReleaseAlreadySucceeded: Bool = false
    ) -> Bool {
        guard case .loaded(var current) = Self.loadExperimentalCloudRestoreManifest(),
              current.transactionID == manifest.transactionID,
              current.state == .preparing,
              activeExperimentalCloudRestoreTransactionID == current.transactionID else {
            return false
        }
        if current.hasMediaStateRecoveryTransaction,
           !mediaStateReleaseAlreadySucceeded,
           !releaseMediaStateRecoveryTransaction(for: current) {
            return false
        }
        guard durablyClearExperimentalCloudRestorePendingMirror() else {
            return false
        }
        current.state = .completed
        do {
            try Self.writeExperimentalCloudRestoreManifest(current)
        } catch {
            Logger.shared.log(
                "Could not abandon an incomplete cloud restore preparation: \(error.localizedDescription)",
                type: "CloudSync"
            )
            return false
        }
        return cleanupExperimentalCloudRestoreArtifacts(for: current)
    }

    @MainActor
    func authorizeExperimentalCloudKeepLocalWrite(
        context: ExperimentalCloudRestoreBoundaryContext
    ) -> Bool {
        guard case .loaded(var manifest) = Self.loadExperimentalCloudRestoreManifest(),
              manifest.state == .prepared,
              manifest.accountBoundaryContext == context,
              manifest.hasKeepLocalTransportPayload,
              Self.boundKeepLocalTransportPayload(for: manifest) != nil,
              activeExperimentalCloudRestoreTransactionID == manifest.transactionID else {
            return false
        }
        manifest.state = .keepLocalWriteAuthorized
        do {
            try Self.writeExperimentalCloudRestoreManifest(manifest)
            return true
        } catch {
            Logger.shared.log(
                "Could not authorize keep-local provider replay: \(error.localizedDescription)",
                type: "CloudSync"
            )
            return false
        }
    }

    @MainActor
    func authorizeExperimentalCloudRestoreCommit(
        context: ExperimentalCloudRestoreBoundaryContext
    ) -> Bool {
        guard case .loaded(var manifest) = Self.loadExperimentalCloudRestoreManifest(),
              manifest.state == .prepared || manifest.state == .keepLocalWriteAuthorized,
              let preparedContext = manifest.accountBoundaryContext,
              Self.experimentalCloudRestoreBoundaryAuthorityMatches(
                preparedContext,
                context
              ),
              Self.isValidExperimentalCloudRestoreBoundaryContext(context),
              activeExperimentalCloudRestoreTransactionID == manifest.transactionID else {
            return false
        }
        if manifest.state == .keepLocalWriteAuthorized {
            guard let provider = CloudSyncProvider(rawValue: context.providerRawValue),
                  UserDefaults.standard.bool(
                    forKey: provider.accountBoundaryPendingKey
                  ),
                  UserDefaults.standard.integer(
                    forKey: provider.accountGenerationKey
                  ) == context.generation,
                  UserDefaults.standard.string(
                    forKey: provider.pendingAccountIdentityKey
                  ) == context.pendingIdentity else {
                return false
            }
        }
        manifest.accountBoundaryContext = context
        manifest.state = .commitAuthorized
        do {
            try Self.writeExperimentalCloudRestoreManifest(manifest)
            return true
        } catch {
            Logger.shared.log(
                "Could not authorize the account-boundary recovery commit: \(error.localizedDescription)",
                type: "CloudSync"
            )
            return false
        }
    }

    @MainActor
    @discardableResult
    func completeExperimentalCloudRestoreRecovery() -> Bool {
        guard case .loaded(var manifest) = Self.loadExperimentalCloudRestoreManifest(),
              activeExperimentalCloudRestoreTransactionID == manifest.transactionID,
              manifest.state != .preparing,
              manifest.state != .keepLocalWriteAuthorized else {
            return false
        }
        if manifest.state == .commitAuthorized {
#if os(iOS)
            guard let context = manifest.accountBoundaryContext,
                  completeAuthorizedAccountBoundary(context) else {
                Logger.shared.log(
                    "Authorized account-boundary recovery remains pending",
                    type: "CloudSync"
                )
                return false
            }
#else
            return false
#endif
        }
        guard durablyClearExperimentalCloudRestorePendingMirror() else {
            return false
        }
        if manifest.state != .completed {
            manifest.state = .completed
            do {
                try Self.writeExperimentalCloudRestoreManifest(manifest)
            } catch {
                Logger.shared.log(
                    "Could not mark cloud restore recovery complete: \(error.localizedDescription)",
                    type: "CloudSync"
                )
                return false
            }
        }
        return cleanupExperimentalCloudRestoreArtifacts(for: manifest)
    }

    @MainActor
    func recoverInterruptedExperimentalCloudRestoreIfNeeded() {
        guard experimentalCloudRestoreRecoveryTask == nil else { return }
        let defaults = UserDefaults.standard
        switch Self.loadExperimentalCloudRestoreManifest() {
        case .missing:
            if defaults.bool(forKey: Self.experimentalCloudRestorePendingKey) {
                switch Self.loadLegacyExperimentalCloudRestoreSnapshot() {
                case .loaded(let safeCloudData):
                    recoverLegacyExperimentalCloudRestore(safeCloudData)
                case .unavailable(let reason):
                    Logger.shared.log(
                        "Legacy cloud restore recovery is waiting for protected data (\(reason))",
                        type: "CloudSync"
                    )
                case .invalid(let reason):
                    Logger.shared.log(
                        "Legacy cloud restore recovery is blocked by an invalid snapshot (\(reason))",
                        type: "CloudSync"
                    )
                case .missing:
                    Logger.shared.log(
                        "Cloud restore recovery is blocked because both its manifest and legacy snapshot are missing",
                        type: "CloudSync"
                    )
                }
                return
            }
            if cleanupOrphanedExperimentalCloudRestoreArtifacts() {
                resumeSyncAfterExperimentalCloudRestoreRecovery()
            }
        case .unavailable(let reason):
            Logger.shared.log(
                "Cloud restore recovery is waiting for protected data (\(reason))",
                type: "CloudSync"
            )
        case .invalid(let reason):
            Logger.shared.log(
                "Cloud restore recovery is blocked by an invalid manifest (\(reason))",
                type: "CloudSync"
            )
        case .loaded(let manifest):
            if let activeExperimentalCloudRestoreTransactionID,
               activeExperimentalCloudRestoreTransactionID != manifest.transactionID {
                Logger.shared.log(
                    "Cloud restore recovery refused a mismatched active transaction",
                    type: "CloudSync"
                )
                return
            }
            activeExperimentalCloudRestoreTransactionID = manifest.transactionID
            switch manifest.state {
            case .preparing:

                if discardPreparingExperimentalCloudRestore(manifest) {
                    Logger.shared.log(
                        "Discarded an interrupted cloud restore preparation",
                        type: "CloudSync"
                    )
                }
            case .completed:
                guard durablyClearExperimentalCloudRestorePendingMirror() else { return }
                _ = cleanupExperimentalCloudRestoreArtifacts(for: manifest)
            case .commitAuthorized:

                if completeExperimentalCloudRestoreRecovery() {
                    Logger.shared.log(
                        "Finalized an interrupted committed account-boundary restore",
                        type: "CloudSync"
                    )
                }
            case .keepLocalWriteAuthorized:

                Logger.shared.log(
                    "Authorized keep-local cloud recovery is waiting for provider replay",
                    type: "CloudSync"
                )
            case .prepared:
                recoverPreparedExperimentalCloudRestore(manifest)
            }
        }
    }

    @MainActor
    private func recoverLegacyExperimentalCloudRestore(_ safeCloudData: Data) {
        guard experimentalCloudRestoreRecoveryTask == nil else { return }
        experimentalCloudRestoreRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.experimentalCloudRestoreRecoveryTask = nil }
            guard await self.restoreExperimentalCloudSnapshot(
                from: safeCloudData,
                preserveMediaStateForCloudKit: false
            ) != nil else {
                Logger.shared.log(
                    "Legacy cloud restore recovery remains pending",
                    type: "CloudSync"
                )
                return
            }

            guard self.durablyClearExperimentalCloudRestorePendingMirror() else {
                Logger.shared.log(
                    "Legacy cloud restore recovery could not durably commit",
                    type: "CloudSync"
                )
                return
            }
            guard self.cleanupOrphanedExperimentalCloudRestoreArtifacts() else {
                Logger.shared.log(
                    "Legacy cloud restore completed but its stale artifact could not be removed",
                    type: "CloudSync"
                )
                return
            }
            self.resumeSyncAfterExperimentalCloudRestoreRecovery()
            Logger.shared.log(
                "Recovered local state from the released cloud restore format",
                type: "CloudSync"
            )
        }
    }

    @MainActor
    private func recoverPreparedExperimentalCloudRestore(
        _ manifest: ExperimentalCloudRestoreRecoveryManifest
    ) {
        guard Self.boundExperimentalCloudRestoreSnapshot(for: manifest) != nil else {
            Logger.shared.log(
                "Prepared cloud restore recovery snapshot ownership is missing or invalid",
                type: "CloudSync"
            )
            return
        }
        experimentalCloudRestoreRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.experimentalCloudRestoreRecoveryTask = nil }
            let restored = await self.restorePreparedExperimentalCloudRestore(manifest)
            if restored, self.completeExperimentalCloudRestoreRecovery() {
                Logger.shared.log(
                    "Recovered local state after an interrupted cloud restore",
                    type: "CloudSync"
                )
            } else {
                Logger.shared.log(
                    "Interrupted cloud restore recovery remains pending",
                    type: "CloudSync"
                )
            }
        }
    }

    @MainActor
    private func restorePreparedExperimentalCloudRestore(
        _ manifest: ExperimentalCloudRestoreRecoveryManifest
    ) async -> Bool {
        guard let boundSnapshot = Self.boundExperimentalCloudRestoreSnapshot(
            for: manifest
        ) else {
            return false
        }
        switch manifest.recoveryKind {
        case .accountBoundary:
            guard let context = manifest.accountBoundaryContext else { return false }
            let protectedProfileIDs = Set(context.outgoingProfileIDs)
            TrackerManager.shared.beginTentativeAccountBoundaryCredentialPreservation(
                profileIDs: protectedProfileIDs
            )
            let restoredLocalState = await restoreBackup(from: boundSnapshot.url)
            guard restoredLocalState else { return false }
            guard manifest.hasCanonicalArchiveRecovery else {

                TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
                    profileIDs: protectedProfileIDs
                )
                return true
            }
#if os(iOS)
            if #available(iOS 17.0, *) {
                let restoredCanonicalArchive = MediaStateSyncManager.shared
                    .restoreRemoteAccountBoundaryArchiveRecovery(
                        transactionID: manifest.transactionID
                    )
                if restoredCanonicalArchive {
                    TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
                        profileIDs: protectedProfileIDs
                    )
                }
                return restoredCanonicalArchive
            }
#endif
            return false
        case .ordinaryCloudRestore:
            return await restoreBackup(from: boundSnapshot.url)
        }
    }

    @MainActor
    func rollbackPreparedExperimentalCloudRestoreRecovery() async -> Bool {
        guard case .loaded(let manifest) = Self.loadExperimentalCloudRestoreManifest(),
              activeExperimentalCloudRestoreTransactionID == manifest.transactionID else {
            return false
        }
        if manifest.state == .commitAuthorized {
            return completeExperimentalCloudRestoreRecovery()
        }
        guard manifest.state == .prepared,
              Self.boundExperimentalCloudRestoreSnapshot(for: manifest) != nil else {
            return false
        }
        let restored = await restorePreparedExperimentalCloudRestore(manifest)
        guard restored else { return false }
        return completeExperimentalCloudRestoreRecovery()
    }

#if os(iOS)
    @MainActor
    private func completeAuthorizedAccountBoundary(
        _ context: ExperimentalCloudRestoreBoundaryContext
    ) -> Bool {
        let disposition = Self.authorizedReplayDisposition(for: context)
        let identityPersisted: Bool
        switch disposition {
        case .adoptPending(let provider):
            let defaults = UserDefaults.standard
            if let pendingIdentity = context.pendingIdentity {
                defaults.set(pendingIdentity, forKey: provider.accountIdentityKey)
                defaults.removeObject(forKey: provider.accountIdentityUnresolvedKey)
            } else {
                defaults.removeObject(forKey: provider.accountIdentityKey)
                defaults.set(true, forKey: provider.accountIdentityUnresolvedKey)
            }
            defaults.removeObject(forKey: provider.pendingAccountIdentityKey)
            defaults.removeObject(forKey: provider.accountBoundaryPendingKey)
            identityPersisted = defaults.synchronize()
        case .alreadyAdopted:
            identityPersisted = UserDefaults.standard.synchronize()
        case .supersededConnection:

            identityPersisted = true
        case .unavailable, .invalid:
            return false
        }
        guard identityPersisted else { return false }

        let profileIDs = Set(context.outgoingProfileIDs)
        let cleanupProfileIDs = ExperimentalCloudTrackerAccountBoundaryPolicy.profileIDsToClear(
            outgoingProfileIDs: profileIDs,
            restoredTrackerProfileIDs: Set(context.restoredTrackerProfileIDs)
        )
        TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
            profileIDs: profileIDs
        )
        var trackerCleanupIsDurablyProtected = true
        for profileID in cleanupProfileIDs {
            trackerCleanupIsDurablyProtected = TrackerManager.shared
                .clearStoreForConfirmedAccountBoundary(profileID: profileID)
                && trackerCleanupIsDurablyProtected
        }
        guard trackerCleanupIsDurablyProtected else { return false }
        if #available(iOS 17.0, *) {
            return MediaStateSyncManager.shared.finalizeMediaStateRemoteAccountBoundary()
        }
        return true
    }
#endif

    @MainActor
    private func durablyClearExperimentalCloudRestorePendingMirror() -> Bool {
        UserDefaults.standard.set(false, forKey: Self.experimentalCloudRestorePendingKey)
        guard UserDefaults.standard.synchronize() else {
            Logger.shared.log(
                "Could not durably clear the cloud restore pending mirror",
                type: "CloudSync"
            )
            return false
        }
        return true
    }

    @MainActor
    private func releaseMediaStateRecoveryTransaction(
        for manifest: ExperimentalCloudRestoreRecoveryManifest
    ) -> Bool {
        guard manifest.hasMediaStateRecoveryTransaction else { return true }
#if os(iOS)
        if #available(iOS 17.0, *) {
            if manifest.hasCanonicalArchiveRecovery {
                return MediaStateSyncManager.shared
                    .completeRemoteAccountBoundaryArchiveRecovery(
                        transactionID: manifest.transactionID
                    )
            }
            return MediaStateSyncManager.shared
                .completeMediaStateSyncPreparedRecovery(
                    transactionID: manifest.transactionID
                )
        }
#endif
        return false
    }

    @MainActor
    private func cleanupExperimentalCloudRestoreArtifacts(
        for manifest: ExperimentalCloudRestoreRecoveryManifest
    ) -> Bool {
        guard case .loaded(let current) = Self.loadExperimentalCloudRestoreManifest(),
              current.transactionID == manifest.transactionID,
              current.state == .completed,
              Self.boundExperimentalCloudRestoreOwnershipIsValidForCleanup(manifest) else {
            return false
        }
        let fileManager = FileManager.default
        for url in [
            Self.experimentalCloudRestoreRecoveryURL(transactionID: manifest.transactionID),
            Self.experimentalCloudRestoreOwnershipURL(transactionID: manifest.transactionID),
            Self.experimentalCloudRestoreTransportURL(transactionID: manifest.transactionID)
        ].compactMap({ $0 }) where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                Logger.shared.log(
                    "Could not remove protected cloud restore recovery artifact: \(error.localizedDescription)",
                    type: "CloudSync"
                )
                return false
            }
        }
        if manifest.hasMediaStateRecoveryTransaction,
           !releaseMediaStateRecoveryTransaction(for: manifest) {
            Logger.shared.log(
                "Could not complete the bound media-state recovery transaction",
                type: "CloudSync"
            )
            return false
        }
        guard let manifestURL = Self.experimentalCloudRestoreManifestURL else { return false }
        do {
            if fileManager.fileExists(atPath: manifestURL.path) {
                try fileManager.removeItem(at: manifestURL)
            }
        } catch {
            Logger.shared.log(
                "Could not remove completed cloud restore manifest: \(error.localizedDescription)",
                type: "CloudSync"
            )
            return false
        }
        activeExperimentalCloudRestoreTransactionID = nil
        resumeSyncAfterExperimentalCloudRestoreRecovery()
        return true
    }

    @MainActor
    private func cleanupOrphanedExperimentalCloudRestoreArtifacts() -> Bool {
        guard case .missing = Self.loadExperimentalCloudRestoreManifest(),
              !UserDefaults.standard.bool(forKey: Self.experimentalCloudRestorePendingKey) else {
            return false
        }
        let fileManager = FileManager.default
        var succeeded = true
        guard let directory = Self.experimentalCloudRestoreDirectoryURL else {
            return false
        }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            Logger.shared.log(
                "Could not enumerate orphaned cloud restore recovery artifacts: \(error.localizedDescription)",
                type: "CloudSync"
            )
            return false
        }
        for url in urls {
            let name = url.lastPathComponent
            let isLegacy = name == Self.legacyExperimentalCloudRestoreRecoveryFilename
            let isBoundRecovery = name.hasPrefix(Self.experimentalCloudRestoreRecoveryPrefix)
                && name.hasSuffix(Self.experimentalCloudRestoreRecoverySuffix)
                && name != "CloudSyncRestoreRecovery.manifest.json"
            guard isLegacy || isBoundRecovery else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                succeeded = false
                Logger.shared.log(
                    "Could not remove orphaned cloud restore recovery artifact: \(error.localizedDescription)",
                    type: "CloudSync"
                )
            }
        }
#if os(iOS)
        if #available(iOS 17.0, *),
           !MediaStateSyncManager.shared.completeRemoteAccountBoundaryArchiveRecovery(
                transactionID: nil
           ) {
            succeeded = false
        }
#endif
        return succeeded
    }

    @MainActor
    private func resumeSyncAfterExperimentalCloudRestoreRecovery() {
        if #available(iOS 17.0, tvOS 17.0, *) {
            MediaStateSyncBootstrap.resumeAfterAccountBoundaryRecovery()
        }
        NotificationCenter.default.post(
            name: .experimentalCloudRestoreRecoveryDidComplete,
            object: nil
        )
    }

private struct ScopedSettingsDefaults {

    var appliesProfileScopedWrites = true

    var appliesServicesScopedWrites = true

    var decodedTopLevelSettingKeys: Set<String>? = nil

    var allTopLevelSettingsWereCaptured = true

    private func store(_ key: String) -> UserDefaults {
        ProfileSettingsStore.store(for: key)
    }

    private func canWrite(_ key: String) -> Bool {
        if let decodedTopLevelSettingKeys,
           !BackupData.topLevelSettingIsAuthoritative(
                storageKey: key,
                decodedWireKeys: decodedTopLevelSettingKeys,
                allSettingsWereCaptured: allTopLevelSettingsWereCaptured
           ) {
            return false
        }
        switch EclipseSettingsRegistry.scope(for: key) {
        case .profile: return appliesProfileScopedWrites
        case .services: return appliesServicesScopedWrites
        case .device: return true
        }
    }

    func set(_ value: Any?, forKey key: String) {
        guard canWrite(key) else { return }
        store(key).set(value, forKey: key)
    }
    func removeObject(forKey key: String) {
        guard canWrite(key) else { return }
        store(key).removeObject(forKey: key)
    }
    func object(forKey key: String) -> Any? { store(key).object(forKey: key) }
    func string(forKey key: String) -> String? { store(key).string(forKey: key) }
    func bool(forKey key: String) -> Bool { store(key).bool(forKey: key) }
    func integer(forKey key: String) -> Int { store(key).integer(forKey: key) }
    func double(forKey key: String) -> Double { store(key).double(forKey: key) }
    func data(forKey key: String) -> Data? { store(key).data(forKey: key) }
    func stringArray(forKey key: String) -> [String]? { store(key).stringArray(forKey: key) }

    func dictionaryRepresentation() -> [String: Any] {
        ProfileSettingsStore.active.dictionaryRepresentation()
    }
}

    private func gatherBackupData(
        useSafeCloudSkyStreamSnapshot: Bool = false,
        includePrivateCloudRecoveryPayloads: Bool = false
    ) throws -> BackupData {

        guard let captureContext = backupCaptureContext() else {
            Logger.shared.log(
                "BackupManager: refused to export an unreadable profile roster",
                type: "Error"
            )
            throw BackupCreationError.profileRosterUnreadable
        }
        let capturedScope = captureContext.scope
        let activeProfileID = capturedScope.profileID
        let userDefaults = ScopedSettingsDefaults()

        var accentColorData: Data?
        if let colorData = userDefaults.data(forKey: "accentColor") {
            accentColorData = colorData
        }
        let settingsGradientColor = userDefaults.data(forKey: "eclipseThemeGradientColor")
        let readerAccentColor = userDefaults.data(forKey: "readerAccentColor")
        let readerSettingsGradientColor = userDefaults.data(forKey: "readerThemeGradientColor")

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
        let localNotificationSubscriptions = BackupData.sanitizedLocalNotificationSubscriptions(
            userDefaults.string(forKey: "localNotificationSubscriptions")
        )
        let localNotificationEpisodeReminders = BackupData.sanitizedLocalNotificationEpisodeReminders(
            userDefaults.string(forKey: "localNotificationEpisodeReminders")
        )
        let localNotificationEpisodeLeadTime = BackupData.sanitizedLocalNotificationEpisodeLeadTime(
            userDefaults.object(forKey: "localNotificationEpisodeLeadTime") as? Int
        )
        let localNotificationSeasonLeadTime = BackupData.sanitizedLocalNotificationSeasonLeadTime(
            userDefaults.object(forKey: "localNotificationSeasonLeadTime") as? Int
        )
        let localNotificationIncludeAnimeSpecials = userDefaults.object(forKey: "localNotificationIncludeAnimeSpecials") as? Bool

        let defaultPlaybackSpeed = BackupData.sanitizedDefaultPlaybackSpeed(
            userDefaults.double(forKey: "defaultPlaybackSpeed")
        )
        let holdSpeedPlayer = BackupData.sanitizedHoldSpeedPlayer(
            userDefaults.double(forKey: "holdSpeedPlayer")
        )
        let externalPlayer = userDefaults.string(forKey: "externalPlayer") ?? "none"
        let preferDownloadedMedia = userDefaults.bool(forKey: "preferDownloadedMedia")
        let alwaysLandscape = userDefaults.bool(forKey: "alwaysLandscape")
        let playerPlaybackLockEnabled = PlayerPlaybackLockSettings.isEnabled()
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
        let showPlayerServicesButton = PlayerServicesButtonSettings.isEnabled()
        let showNextEpisodePosterButton = userDefaults.bool(forKey: "showNextEpisodePosterButton")
        let nextEpisodeThreshold = BackupData.sanitizedNextEpisodeThreshold(
            userDefaults.double(forKey: "nextEpisodeThreshold")
        )
        let nextEpisodeSkipFillerEnabled = NextEpisodeFillerSettings.isEnabled()
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
        let playerDoubleTapSeekSeconds = BackupData.sanitizedPlayerDoubleTapSeekSeconds(
            savedDoubleTapSeekSeconds
        )
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
        let mpvNeuralUpscaler = BackupData.sanitizedMPVNeuralUpscaler(userDefaults.string(forKey: "mpvNeuralUpscaler"))
        let mpvNeuralUpscalerTV = BackupData.sanitizedMPVNeuralUpscaler(userDefaults.string(forKey: "mpvNeuralUpscalerTV"))
        let mpvPlayerSkin = BackupData.sanitizedMPVPlayerSkin(userDefaults.string(forKey: MPVPlayerSkinSettings.skinKey))
        let mpvPlayerSkinCustomPrimaryColor = userDefaults.data(forKey: MPVPlayerSkinSettings.customPrimaryColorKey)
        let mpvPlayerSkinCustomSecondaryColor = userDefaults.data(forKey: MPVPlayerSkinSettings.customSecondaryColorKey)
        let mpvPlayerSkinAnimationsEnabled = MPVPlayerSkinSettings.animationsEnabled()
        let mpvPlayerSkinTintControlsOnly = MPVPlayerSkinSettings.tintControlsOnly()
        let mpvPictureInPictureEnabled = userDefaults.object(forKey: "mpvPictureInPictureEnabled") as? Bool ?? true
        let mpvAppExitPictureInPictureEnabled = userDefaults.bool(forKey: "mpvAppExitPictureInPictureEnabled")
        let mpvHDRMode = MPVHDRMode(rawValue: userDefaults.string(forKey: "mpvHDRMode") ?? MPVHDRMode.defaultMode.rawValue)?.rawValue ?? MPVHDRMode.defaultMode.rawValue
        let mpvSurroundSoundEnabled = userDefaults.object(forKey: "mpvSurroundSoundEnabled") == nil ? true : userDefaults.bool(forKey: "mpvSurroundSoundEnabled")
        let watchTogetherEnabled = userDefaults.object(forKey: WatchTogetherSettings.enabledKey) == nil
            ? WatchTogetherSettings.defaultEnabled
            : userDefaults.bool(forKey: WatchTogetherSettings.enabledKey)
        let smartInAppPlayerChoosingEnabled = false
        ExperimentalFeatureState.registerDefaults()
        let experimentalFeaturesEnabled = userDefaults.bool(forKey: ExperimentalFeatureState.enabledKey)
        let experimentalFeaturesLastChangedAt = BackupData.sanitizedExperimentalFeaturesLastChangedAt(
            userDefaults.double(forKey: ExperimentalFeatureState.lastChangedAtKey)
        )
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

        let subtitleForegroundColor = userDefaults.data(forKey: "subtitles_foregroundColor")
        let subtitleStrokeColor = userDefaults.data(forKey: "subtitles_strokeColor")
        let subtitleStrokeWidth = BackupData.sanitizedSubtitleStrokeWidth(
            userDefaults.double(forKey: "subtitles_strokeWidth")
        )
        let subtitleFontSize = BackupData.sanitizedSubtitleFontSize(
            userDefaults.double(forKey: "subtitles_fontSize")
        )
        let subtitleVerticalOffset: Double
        if userDefaults.object(forKey: "playerSubtitleOverlayBottomConstant") != nil {
            subtitleVerticalOffset = BackupData.sanitizedSubtitleVerticalOffset(
                userDefaults.double(forKey: "playerSubtitleOverlayBottomConstant")
            )
        } else if userDefaults.object(forKey: "vlcSubtitleOverlayBottomConstant") != nil {
            subtitleVerticalOffset = BackupData.sanitizedSubtitleVerticalOffset(
                userDefaults.double(forKey: "vlcSubtitleOverlayBottomConstant")
            )
        } else {
            subtitleVerticalOffset = -6.0
        }
        let subtitlesVisible = userDefaults.bool(forKey: "subtitles_isVisible")

        let showKanzen = userDefaults.bool(forKey: "showKanzen")
        let hideSplashScreen = userDefaults.bool(forKey: "hideSplashScreen")
        let modeSwitchAnimationEnabled = ModeSwitchAnimationSettings.isEnabled()
        let kanzenAutoUpdateModules = ModuleManager.isAutoUpdateEnabled
        let seasonMenu = MediaDetailPlatformDefaults.usesCompactSeasonMenu()
        let horizontalEpisodeList = MediaDetailPlatformDefaults.usesHorizontalEpisodes()
        let mediaDetailTitleArtworkEnabled = MediaDetailTitleArtworkSettings.isEnabled()
        let mediaDetailAlternatePosterEnabled = MediaDetailAlternatePosterSettings.isEnabled()
        let mediaDetailSimilarTitlesEnabled = MediaDetailSimilarTitlesSettings.isEnabled()
        let useClassicScheduleUI = userDefaults.bool(forKey: "useClassicScheduleUI")
        let heroBannerCatalogId = BackupData.sanitizedNonEmptyString(userDefaults.string(forKey: "heroBannerCatalogId"), defaultValue: "trending")
        let heroBannerBehavior = BackupData.sanitizedHeroBannerBehavior(userDefaults.string(forKey: "heroBannerBehavior"))
        let homeCatalogLayoutOverrides = userDefaults.data(forKey: HomeCatalogLayoutStore.storageKey).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let homeAnimatedBackgroundEnabled = HomeAnimatedBackgroundSettings.isEnabled()
        let homeAnimatedBackgroundQuality = BackupData.sanitizedHomeAnimatedBackgroundQuality(userDefaults.string(forKey: HomeAnimatedBackgroundQuality.storageKey))
        let homeAnimatedBackgroundFrameRate = BackupData.sanitizedHomeAnimatedBackgroundFrameRate(userDefaults.string(forKey: HomeAnimatedBackgroundFrameRate.storageKey))
        let appPerformanceOverlayEnabled = AppPerformanceOverlaySettings.isEnabled()
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
        let mediaDetailHiddenElements = MediaDetailElement.rawValue(for: MediaDetailElement.hiddenElements())
        let readerDetailElementOrder = BackupData.sanitizedReaderDetailElementOrder(userDefaults.string(forKey: ReaderDetailElement.orderStorageKey))
        let readerDetailHiddenElements = ReaderDetailElement.rawValue(for: ReaderDetailElement.hiddenElements())
        let mediaColumnsPortrait = userDefaults.object(forKey: "mediaColumnsPortrait") != nil ? userDefaults.integer(forKey: "mediaColumnsPortrait") : 3
        let mediaColumnsLandscape = userDefaults.object(forKey: "mediaColumnsLandscape") != nil ? userDefaults.integer(forKey: "mediaColumnsLandscape") : 5

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

        let readerFontSize = BackupData.sanitizedReaderFontSize(
            userDefaults.double(forKey: "readerFontSize")
        )
        let readerFontFamily = userDefaults.string(forKey: "readerFontFamily") ?? "-apple-system"
        let readerFontWeight = userDefaults.string(forKey: "readerFontWeight") ?? "normal"
        let readerColorPreset = userDefaults.integer(forKey: "readerColorPreset")
        let readerTextAlignment = userDefaults.string(forKey: "readerTextAlignment") ?? "left"
        let readerLineSpacing = BackupData.sanitizedReaderLineSpacing(
            userDefaults.double(forKey: "readerLineSpacing")
        )
        let readerMargin = BackupData.sanitizedReaderMargin(
            userDefaults.object(forKey: "readerMargin") != nil
                ? userDefaults.double(forKey: "readerMargin")
                : nil
        )

        let autoClearCacheEnabled = userDefaults.bool(forKey: "autoClearCacheEnabled")
        let autoClearCacheThresholdMB = BackupData.sanitizedAutoClearCacheThresholdMB(
            userDefaults.double(forKey: "autoClearCacheThresholdMB")
        )
        let highQualityThreshold = BackupData.sanitizedHighQualityThreshold(
            userDefaults.object(forKey: "highQualityThreshold") as? Double
        )
        let backgroundHLSPipelineEnabled = userDefaults.bool(forKey: "backgroundHLSPipelineEnabled")
        let readerDownloadsBackgroundEnabled = userDefaults.object(forKey: "readerDownloadsBackgroundEnabled") == nil ? true : userDefaults.bool(forKey: "readerDownloadsBackgroundEnabled")
        let readerDownloadsWifiOnly = userDefaults.bool(forKey: "readerDownloadsWifiOnly")
        let readerDownloadsParallelLimit = BackupData.sanitizedReaderDownloadsParallelLimit(BackupData.optionalInt(from: userDefaults.object(forKey: "readerDownloadsParallelLimit"), defaultValue: 2))
        let autoUpdateServicesEnabled = userDefaults.object(forKey: "autoUpdateServicesEnabled") == nil ? true : userDefaults.bool(forKey: "autoUpdateServicesEnabled")
        let servicesAutoModeEnabled = AutoModeSettings.isEnabled()
        let servicesAutoSelectEpisodesEnabled = userDefaults.bool(forKey: "servicesAutoSelectEpisodesEnabled")
        let servicesAutoModeErrorIntelligenceEnabled = AutoModeErrorIntelligenceSettings.isEnabled()
        let servicesAutoModeSourceIds = BackupData.sanitizedStringList(userDefaults.stringArray(forKey: "servicesAutoModeSourceIds"))
        let servicesAutoModeSourceOrderIds = BackupData.sanitizedStringList(userDefaults.stringArray(forKey: "servicesAutoModeSourceOrderIds"))
        let servicesAutoModeQualityPreference = AutoModeQualityPreference.sanitizedRawValue(userDefaults.string(forKey: AutoModeQualityPreference.storageKey))
        let servicesResultMinimumSimilarity = ServicesResultRankingSettings.minimumSimilarity()
        let servicesDropMismatchedResults = ServicesResultRankingSettings.dropsMismatchedResults()
        let servicesStremioStyleSheetEnabled = ServicesSheetPresentationSettings.usesStremioStyle()
        let servicesIncludedStreamLanguages = StreamLanguageFilter.includedLanguages()
        let servicesHiddenStreamLanguages = StreamLanguageFilter.hiddenLanguages()
        let servicesHideStreamsWithoutLanguageData = StreamLanguageFilter.hidesStreamsWithoutLanguageData()
        let servicesAssumeOriginalAudio = StreamLanguageFilter.assumesOriginalAudio()
        let servicesTreatDubbedAnimeAsEnglish = StreamLanguageFilter.treatsDubbedAnimeAsEnglish()
        let servicesHiddenStreamQualities = StreamLanguageFilter.hiddenQualityHeights()
        let servicesHideStreamsWithoutDetectedQuality = StreamLanguageFilter.hidesStreamsWithoutDetectedQuality()
        let servicesExtraRulesSourceIds = StreamLanguageFilter.extraRulesSourceIds()
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
        if let historyData = userDefaults.data(forKey: "searchHistory") {
            if let decoded = BackupSearchHistory.decodedQueries(from: historyData) {
                searchHistory = BackupSearchHistory(queries: decoded, wasCaptured: true)
            } else {
                searchHistory = BackupSearchHistory()
            }
        } else {
            searchHistory = BackupSearchHistory(wasCaptured: true)
        }

        let libraryManager = LibraryManager.shared
        let activeCollections = libraryManager.collections(forProfile: activeProfileID)

        let progressManager = ProgressManager.shared
        let activeProgress = progressManager.progressData(forProfile: activeProfileID)
        let activeRatings = UserRatingManager.shared.ratingsAndNotes(forProfile: activeProfileID)

        let activeCatalogs = CatalogManager.shared.catalogsForBackup(forProfile: activeProfileID)
        let activeMangaCollections = MangaLibraryManager.shared
            .collectionsSnapshot(forProfile: activeProfileID)
        let activeMangaProgress = MangaReadingProgressManager.shared
            .progressSnapshot(forProfile: activeProfileID)
        let activeMangaCatalogs = MangaCatalogManager.shared
            .catalogsSnapshot(forProfile: activeProfileID)
        let activeCustomCatalogs = KanzenCustomCatalogManager.shared
            .catalogsSnapshot(forProfile: activeProfileID)
        let trackerManager = TrackerManager.shared
        let activeTrackerState: TrackerState? = {
            if Thread.isMainThread {
                return useSafeCloudSkyStreamSnapshot
                    ? trackerManager.trackerStateForPrivateCloudExport(
                        forProfile: activeProfileID
                    )
                    : trackerManager.trackerState(forProfile: activeProfileID)
            }
            return DispatchQueue.main.sync {
                useSafeCloudSkyStreamSnapshot
                    ? trackerManager.trackerStateForPrivateCloudExport(
                        forProfile: activeProfileID
                    )
                    : trackerManager.trackerState(forProfile: activeProfileID)
            }
        }()
        var unreadableCompatibilityDomains: [String] = []
        if activeCollections == nil { unreadableCompatibilityDomains.append("library") }
        if activeProgress == nil { unreadableCompatibilityDomains.append("progress") }
        if activeRatings == nil { unreadableCompatibilityDomains.append("ratings") }
        if activeCatalogs == nil { unreadableCompatibilityDomains.append("catalogs") }
        if activeTrackerState == nil { unreadableCompatibilityDomains.append("trackers") }
        if activeMangaCollections == nil {
            unreadableCompatibilityDomains.append("Reader library")
        }
        if activeMangaProgress == nil {
            unreadableCompatibilityDomains.append("Reader progress")
        }
        if activeMangaCatalogs == nil {
            unreadableCompatibilityDomains.append("Reader catalogs")
        }
        if activeCustomCatalogs == nil {
            unreadableCompatibilityDomains.append("Reader custom catalogs")
        }
        guard unreadableCompatibilityDomains.isEmpty,
              let activeCollections,
              let activeProgress,
              let activeRatings,
              let activeCatalogs,
              let activeMangaCollections,
              let activeMangaProgress,
              let activeMangaCatalogs,
              let activeCustomCatalogs,
              let activeTrackerState else {
            Logger.shared.log(
                "BackupManager: refused to export unreadable active-profile legacy domains (\(unreadableCompatibilityDomains.joined(separator: ", ")))",
                type: "Error"
            )
            throw BackupCreationError.activeProfileCompatibilityDomainsUnreadable(
                unreadableCompatibilityDomains
            )
        }
        let backupCollections = activeCollections.map { BackupCollection(from: $0) }
        let progressData = activeProgress

        let trackerState = useSafeCloudSkyStreamSnapshot
            ? activeTrackerState
            : Self.trackerStateWithoutCredentials(activeTrackerState)

        let catalogs = activeCatalogs

        let sourceCapture: (services: [BackupService], addons: [BackupStremioAddon])? = {
            do {
                let services = try ServiceStore.shared.backupRows().map { row in
                    BackupService(
                        id: row.id,
                        url: row.url,
                        jsonMetadata: row.jsonMetadata,
                        jsScript: row.jsScript,
                        isActive: row.isActive,
                        sortIndex: row.sortIndex
                    )
                }
                let addons = try StremioAddonStore.shared.backupRows().map { row in
                    let resolvedURL = StremioConfiguredURLVault.resolve(
                        addonID: row.id,
                        persistedURL: row.configuredURL,
                        profileID: activeProfileID
                    )
                    guard !StremioConfiguredURLVault.isUnresolvedReference(resolvedURL) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    return BackupStremioAddon(
                        id: row.id,
                        configuredURL: resolvedURL,
                        manifestJSON: row.manifestJSON,
                        isActive: row.isActive,
                        sortIndex: row.sortIndex
                    )
                }
                return (services, addons)
            } catch {
                Logger.shared.log(
                    "BackupManager: active Service/Stremio source capture was unavailable; the source roster was omitted",
                    type: "Storage"
                )
                return nil
            }
        }()
        let services = sourceCapture?.services ?? []
        let stremioAddons = sourceCapture?.addons

        var nuvioPlugins: NuvioStoredPluginsState? = nil
        performOnMainThread {
            MainActor.assumeIsolated {
                let nuvioManager = NuvioPluginManager.shared
                guard nuvioManager.isLoaded else { return }
                nuvioPlugins = nuvioManager.backupState()
            }
        }

        var skyStream: SkyStreamBackupSnapshot? = nil
        var skyStreamBackupError: Error?
#if os(iOS) && !targetEnvironment(macCatalyst)
        var skyStreamManualCapturePlan: SkyStreamManualBackupCapturePlan?
        if let opaqueSnapshot = loadOpaqueSkyStreamSnapshot(
            preferringSafeCloud: useSafeCloudSkyStreamSnapshot
        ) {

            skyStream = useSafeCloudSkyStreamSnapshot
                ? BackupData.skyStreamSnapshotForExperimentalCloudSync(
                    opaqueSnapshot,
                    stripArchives: !includePrivateCloudRecoveryPayloads
                )
                : opaqueSnapshot
        } else {
            performOnMainThread {
                MainActor.assumeIsolated {
                    let manager = SkyStreamPluginManager.shared
                    guard manager.isLoaded else { return }
                    if useSafeCloudSkyStreamSnapshot {
                        skyStream = includePrivateCloudRecoveryPayloads
                            ? manager.completePrivateCloudBackupSnapshot()
                            : manager.completePrivateCloudMetadataSnapshot()
                    } else {
                        do {

                            skyStreamManualCapturePlan = try manager.manualBackupCapturePlan()
                        } catch {
                            skyStreamBackupError = error
                        }
                    }
                }
            }
        }
        if let skyStreamManualCapturePlan, skyStreamBackupError == nil {
            do {
                skyStream = try SkyStreamPluginManager.materializeManualBackupSnapshot(
                    skyStreamManualCapturePlan
                )
            } catch {
                skyStreamBackupError = error
            }
        }
#else
        if let opaqueSnapshot = loadOpaqueSkyStreamSnapshot(
            preferringSafeCloud: useSafeCloudSkyStreamSnapshot
        ) {
            skyStream = useSafeCloudSkyStreamSnapshot
                ? BackupData.skyStreamSnapshotForExperimentalCloudSync(
                    opaqueSnapshot,
                    stripArchives: !includePrivateCloudRecoveryPayloads
                )
                : opaqueSnapshot
        }
#endif
        if let skyStreamBackupError { throw skyStreamBackupError }

        let mangaCollections = activeMangaCollections.map { collection in
            BackupMangaCollection(
                id: collection.id,
                name: collection.name,
                items: collection.items,
                description: collection.description
            )
        }

        let mangaReadingProgress = Dictionary(
            uniqueKeysWithValues: activeMangaProgress
                .map { ("\($0.key)", $0.value) }
        )

        let mangaCatalogs = activeMangaCatalogs

        let customCatalogs = activeCustomCatalogs

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
        let readerExtensionsState: BackupReaderExtensionState?
        do {
            readerExtensionsState = try BackupReaderExtensionState.capture(
                from: ProfileSettingsStore.services,
                preferenceStore: ProfileSettingsStore.active
            )
        } catch {
            if useSafeCloudSkyStreamSnapshot {
                readerExtensionsState = nil
                Logger.shared.log(
                    "Backup: active Reader Extension metadata is unreadable; omitted from cloud snapshot rather than recorded as empty",
                    type: "Storage"
                )
            } else {
                throw error
            }
        }
#else
        let readerExtensionsState: BackupReaderExtensionState? = nil
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
            mpvNeuralUpscaler: mpvNeuralUpscaler,
            mpvNeuralUpscalerTV: mpvNeuralUpscalerTV,
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
            mediaDetailAlternatePosterEnabled: mediaDetailAlternatePosterEnabled,
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
            servicesAutoModeErrorIntelligenceEnabled: servicesAutoModeErrorIntelligenceEnabled,
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
            skyStream: skyStream,
            nuvioPlugins: nuvioPlugins,
            mangaCollections: mangaCollections,
            mangaReadingProgress: mangaReadingProgress,
            mangaCatalogs: mangaCatalogs,
            customCatalogs: customCatalogs,
            kanzenModules: kanzenModules,
            readerExtensionsState: readerExtensionsState,
            searchHistory: searchHistory,
            recommendationCache: RecommendationEngine.shared.getRecommendationCache(),
            userRatings: activeRatings.ratings,
            userRatingNotes: activeRatings.notes,
            mediaStateSettings: BackupData.captureMediaStateSettings(),
            servicesPresent: sourceCapture != nil,
            kanzenModulesPresent: !ModuleManager.shared.metadataStoreFailedToLoad
        )

        var backupWithProfiles = backup

        if let servicesSettings = Self.captureServicesScopedSettings() {
            backupWithProfiles.servicesSettings = servicesSettings
            backupWithProfiles.servicesSettingsWereCaptured = true
        } else {
            backupWithProfiles.servicesSettings = nil
            backupWithProfiles.servicesSettingsWereCaptured = false
        }
        backupWithProfiles.sharesServices = ProfileSettingsStore.sharesServices
        backupWithProfiles.profiles = try Self.captureProfileSnapshots(
            profiles: captureContext.profiles,
            includeCloudSourceMetadata: useSafeCloudSkyStreamSnapshot,
            requireReadableReaderExtensionMetadata: !useSafeCloudSkyStreamSnapshot,
            includePrivateCloudTrackerCredentials: useSafeCloudSkyStreamSnapshot
        )
        if useSafeCloudSkyStreamSnapshot,
           let capturedActiveTracker = backupWithProfiles.profiles?.first(where: {
               $0.id == activeProfileID
                    && $0.trackerStateWasCaptured
                    && $0.trackerCredentialsAndRosterWereCaptured
           }) {
            backupWithProfiles.trackerState = capturedActiveTracker.trackerState
        }
        backupWithProfiles.activeProfileID = activeProfileID

        if !useSafeCloudSkyStreamSnapshot || includePrivateCloudRecoveryPayloads {
            try Self.captureSharedSourcePayloads(into: &backupWithProfiles)
        }
        guard activeProfileScopeIsCurrent(capturedScope) else {
            Logger.shared.log(
                "BackupManager: discarded a backup captured across a profile scope or roster change",
                type: "Error"
            )
            throw BackupCreationError.activeProfileChanged
        }
        return backupWithProfiles
    }

    private static func captureSharedSourcePayloads(into backup: inout BackupData) throws {
        guard !ProfileSettingsStore.sharesServices,
              let snapshots = backup.profiles else { return }
        guard let activeProfileID = backup.activeProfileID else {
            throw BackupCreationError.activeProfileChanged
        }
        let inactiveSnapshots = snapshots.filter { $0.id != activeProfileID }
        guard !inactiveSnapshots.isEmpty else { return }

        var remainingBytes = maximumSharedSourcePayloadBytes
        var skippedForBudget = 0

        var coveredPayloadPaths = Set<String>()
        var coveredArchiveHashes = Set<String>()
        var skyStreamPayloads: [BackupSkyStreamSharedPayload] = []
        for snapshot in inactiveSnapshots {
            guard let document = snapshot.skyStreamStateData,
                  let plugins = decodedSkyStreamInstalledPlugins(document) else { continue }
            for plugin in plugins where coveredPayloadPaths.insert(plugin.payloadRelativePath).inserted {
                let archiveHash = plugin.archiveSHA256.lowercased()
                let carriesArchive = !coveredArchiveHashes.contains(archiveHash)
                guard let payload = sharedSkyStreamPayload(
                    for: plugin,
                    includingArchive: carriesArchive
                ) else { continue }
                let byteCount = payload.script.count + (payload.archive?.count ?? 0)
                guard byteCount <= remainingBytes else {
                    skippedForBudget += 1
                    continue
                }
                remainingBytes -= byteCount
                skyStreamPayloads.append(payload)

                if payload.archive != nil {
                    coveredArchiveHashes.insert(archiveHash)
                }
            }
        }
        if !skyStreamPayloads.isEmpty {
            backup.skyStreamSharedPayloads = skyStreamPayloads
        }

        var coveredNuvioFiles = Set<String>()
        var nuvioPayloads: [BackupNuvioSharedPayload] = []
        for snapshot in inactiveSnapshots {
            for scraper in snapshot.nuvioPlugins?.scrapers ?? [] {
                let identity = "\(scraper.repositoryId)/\(scraper.codeFileName)"
                guard coveredNuvioFiles.insert(identity).inserted,
                      let code = NuvioPluginStore.shared.readCode(
                        repositoryID: scraper.repositoryId,
                        codeFileName: scraper.codeFileName
                      ) else { continue }
                let byteCount = code.utf8.count
                guard byteCount <= remainingBytes else {
                    skippedForBudget += 1
                    continue
                }
                remainingBytes -= byteCount
                nuvioPayloads.append(
                    BackupNuvioSharedPayload(
                        repositoryID: scraper.repositoryId,
                        scraperID: scraper.id,
                        codeFileName: scraper.codeFileName,
                        code: code
                    )
                )
            }
        }
        if !nuvioPayloads.isEmpty {
            backup.nuvioSharedPayloads = nuvioPayloads
        }

        if skippedForBudget > 0 {
            Logger.shared.log(
                "BackupManager: refused an incomplete export because \(skippedForBudget) inactive-profile source payload(s) exceeded the shared-payload budget",
                type: "Error"
            )
            throw BackupCreationError.sharedSourcePayloadBudgetExceeded(skippedForBudget)
        }
        if !skyStreamPayloads.isEmpty || !nuvioPayloads.isEmpty {
            Logger.shared.log(
                "BackupManager: carried \(skyStreamPayloads.count) SkyStream and \(nuvioPayloads.count) Nuvio payload(s) for inactive profiles",
                type: "Services"
            )
        }
    }

    private static func sharedSkyStreamPayload(
        for plugin: SkyStreamInstalledPluginState,
        includingArchive: Bool
    ) -> BackupSkyStreamSharedPayload? {
        guard let payloadURL = sharedSkyStreamPayloadURL(relativePath: plugin.payloadRelativePath),
              let script = try? Data(
                contentsOf: payloadURL.appendingPathComponent("plugin.js", isDirectory: false),
                options: [.mappedIfSafe]
              ),
              script.count <= maximumSkyStreamScriptBytes,
              sha256Hex(script).caseInsensitiveCompare(plugin.scriptSHA256) == .orderedSame else {
            Logger.shared.log(
                "BackupManager: could not carry the SkyStream payload for \(plugin.id); its script is missing or does not match the hash its profile recorded",
                type: "Error"
            )
            return nil
        }

        var archive: Data?
        if includingArchive,
           let archiveURL = sharedSkyStreamArchiveURL(
            packageID: plugin.id,
            archiveSHA256: plugin.archiveSHA256
           ),
           let bytes = try? Data(contentsOf: archiveURL, options: [.mappedIfSafe]),
           bytes.count <= maximumSkyStreamArchiveBytes,
           sha256Hex(bytes).caseInsensitiveCompare(plugin.archiveSHA256) == .orderedSame {
            archive = bytes
        }

        return BackupSkyStreamSharedPayload(
            packageID: plugin.id,
            payloadRelativePath: plugin.payloadRelativePath,
            scriptSHA256: plugin.scriptSHA256.lowercased(),
            archiveSHA256: plugin.archiveSHA256.lowercased(),
            script: script,
            archive: archive
        )
    }

    private struct SkyStreamPersistedInstalls: Decodable {
        let installedPlugins: [SkyStreamInstalledPluginState]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            installedPlugins = try container.decodeIfPresent(
                [SkyStreamInstalledPluginState].self,
                forKey: .installedPlugins
            ) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case installedPlugins
        }
    }

    private static func decodedSkyStreamInstalledPlugins(_ document: Data) -> [SkyStreamInstalledPluginState]? {
        guard document.count <= 8 * 1_024 * 1_024,
              let decoded = try? JSONDecoder().decode(SkyStreamPersistedInstalls.self, from: document) else {
            return nil
        }
        return decoded.installedPlugins
    }

    private static var sharedSkyStreamRootURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return support.appendingPathComponent("SkyStream", isDirectory: true).standardizedFileURL
    }

    private static func sharedSkyStreamPayloadURL(relativePath: String) -> URL? {
        guard let root = sharedSkyStreamRootURL,
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.split(separator: "/").contains("..") else { return nil }
        let packageRoot = root
            .appendingPathComponent("Packages", isDirectory: true)
            .standardizedFileURL
        let url = root.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
        guard url.path.hasPrefix(packageRoot.path + "/") else { return nil }
        return url
    }

    private static func sharedSkyStreamArchiveURL(packageID: String, archiveSHA256: String) -> URL? {
        guard let root = sharedSkyStreamRootURL,
              SkyStreamStableID.isValidPackageName(packageID),
              isSHA256Hex(archiveSHA256) else { return nil }
        return root
            .appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent(packageID, isDirectory: true)
            .appendingPathComponent("\(archiveSHA256.lowercased()).sky", isDirectory: false)
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.count == 64 && normalized.allSatisfy(\.isHexDigit)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func migratingNuvioSharedPayloadsForRestore(
        _ source: BackupData,
        writeCode: (_ code: String, _ repositoryID: String, _ scraperID: String) throws -> String
    ) -> NuvioSharedPayloadMigrationResult {
        var backup = source
        var migratedPayloads: [BackupNuvioSharedPayload] = []
        var migratedPayloadCount = 0
        var refusedPayloadCount = 0
        for payload in source.nuvioSharedPayloads ?? [] {
            let legacyName = NuvioPluginSupport.codeFileName(forScraperID: payload.scraperID)
            let contentAddressedName = NuvioPluginStore.codeFileName(
                forScraperID: payload.scraperID,
                code: payload.code
            )
            guard !payload.code.isEmpty,
                  payload.code.utf8.count <= NuvioPluginStore.Bounds.codeBytes,
                  payload.codeFileName == legacyName
                    || payload.codeFileName == contentAddressedName,
                  backupContainsNuvioPayloadReference(backup, payload: payload) else {
                refusedPayloadCount += 1
                continue
            }
            let writtenName: String
            do {
                writtenName = try writeCode(
                    payload.code,
                    payload.repositoryID,
                    payload.scraperID
                )
            } catch {
                refusedPayloadCount += 1
                continue
            }
            guard writtenName == contentAddressedName else {
                refusedPayloadCount += 1
                continue
            }
            var rewrittenCount = replaceNuvioPayloadReferences(
                in: &backup.nuvioPlugins,
                payload: payload,
                codeFileName: writtenName
            )
            if var profiles = backup.profiles {
                for index in profiles.indices {
                    rewrittenCount += replaceNuvioPayloadReferences(
                        in: &profiles[index].nuvioPlugins,
                        payload: payload,
                        codeFileName: writtenName
                    )
                }
                backup.profiles = profiles
            }
            guard rewrittenCount > 0 else {
                refusedPayloadCount += 1
                continue
            }
            migratedPayloads.append(BackupNuvioSharedPayload(
                repositoryID: payload.repositoryID,
                scraperID: payload.scraperID,
                codeFileName: writtenName,
                code: payload.code
            ))
            migratedPayloadCount += 1
        }
        backup.nuvioSharedPayloads = migratedPayloads.isEmpty ? nil : migratedPayloads
        return NuvioSharedPayloadMigrationResult(
            backup: backup,
            migratedPayloadCount: migratedPayloadCount,
            refusedPayloadCount: refusedPayloadCount
        )
    }

    private static func backupContainsNuvioPayloadReference(
        _ backup: BackupData,
        payload: BackupNuvioSharedPayload
    ) -> Bool {
        if nuvioStateContainsPayloadReference(backup.nuvioPlugins, payload: payload) {
            return true
        }
        return backup.profiles?.contains(where: {
            nuvioStateContainsPayloadReference($0.nuvioPlugins, payload: payload)
        }) == true
    }

    private static func nuvioStateContainsPayloadReference(
        _ state: NuvioStoredPluginsState?,
        payload: BackupNuvioSharedPayload
    ) -> Bool {
        state?.scrapers.contains(where: {
            $0.id == payload.scraperID
                && $0.repositoryId == payload.repositoryID
                && $0.codeFileName == payload.codeFileName
        }) == true
    }

    @discardableResult
    private static func replaceNuvioPayloadReferences(
        in state: inout NuvioStoredPluginsState?,
        payload: BackupNuvioSharedPayload,
        codeFileName: String
    ) -> Int {
        guard var restoredState = state else { return 0 }
        var replacedCount = 0
        restoredState.scrapers = restoredState.scrapers.map { scraper in
            guard scraper.id == payload.scraperID,
                  scraper.repositoryId == payload.repositoryID,
                  scraper.codeFileName == payload.codeFileName else {
                return scraper
            }
            replacedCount += 1
            return NuvioPluginScraper(
                id: scraper.id,
                providerKey: scraper.providerKey,
                repositoryId: scraper.repositoryId,
                repositoryUrl: scraper.repositoryUrl,
                name: scraper.name,
                description: scraper.description,
                author: scraper.author,
                version: scraper.version,
                filename: scraper.filename,
                codeFileName: codeFileName,
                supportedTypes: scraper.supportedTypes,
                enabled: scraper.enabled,
                manifestEnabled: scraper.manifestEnabled,
                declaresSettings: scraper.declaresSettings,
                logo: scraper.logo,
                contentLanguage: scraper.contentLanguage,
                formats: scraper.formats
            )
        }
        state = restoredState
        return replacedCount
    }

    private func migratingNuvioSharedPayloadsForRestore(_ source: BackupData) -> BackupData {
        let store = NuvioPluginStore.shared
        let migration = Self.migratingNuvioSharedPayloadsForRestore(source) {
            code, repositoryID, scraperID in
            try store.writeCode(
                code,
                repositoryID: repositoryID,
                scraperID: scraperID
            )
        }
        if migration.migratedPayloadCount > 0 || migration.refusedPayloadCount > 0 {
            Logger.shared.log(
                "BackupManager: migrated \(migration.migratedPayloadCount) Nuvio shared payload(s) to content-addressed storage; refused \(migration.refusedPayloadCount)",
                type: "Services"
            )
        }
        return migration.backup
    }

    private func restoreSharedSourcePayloads(_ backup: BackupData) {
        var restoredScripts = 0
        var refusedPayloads = 0
        for payload in backup.skyStreamSharedPayloads ?? [] {
            guard let payloadURL = Self.sharedSkyStreamPayloadURL(
                relativePath: payload.payloadRelativePath
            ),
                  payload.script.count <= Self.maximumSkyStreamScriptBytes,
                  Self.isSHA256Hex(payload.scriptSHA256),
                  Self.sha256Hex(payload.script)
                    .caseInsensitiveCompare(payload.scriptSHA256) == .orderedSame else {
                refusedPayloads += 1
                continue
            }

            let scriptURL = payloadURL.appendingPathComponent("plugin.js", isDirectory: false)
            if !fileManager.fileExists(atPath: scriptURL.path) {
                do {
                    try fileManager.createDirectory(
                        at: payloadURL,
                        withIntermediateDirectories: true
                    )
                    try payload.script.write(to: scriptURL, options: .atomic)
                    restoredScripts += 1
                } catch {
                    Logger.shared.log(
                        "BackupManager: could not write the shared SkyStream payload for \(payload.packageID): \(error.localizedDescription)",
                        type: "Error"
                    )
                    continue
                }
            }

            guard let archive = payload.archive,
                  archive.count <= Self.maximumSkyStreamArchiveBytes,
                  Self.sha256Hex(archive)
                    .caseInsensitiveCompare(payload.archiveSHA256) == .orderedSame,
                  let archiveURL = Self.sharedSkyStreamArchiveURL(
                    packageID: payload.packageID,
                    archiveSHA256: payload.archiveSHA256
                  ),
                  !fileManager.fileExists(atPath: archiveURL.path) else { continue }
            try? fileManager.createDirectory(
                at: archiveURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? archive.write(to: archiveURL, options: .atomic)
        }

        var restoredNuvioFiles = 0
        let nuvioStore = NuvioPluginStore.shared
        for payload in backup.nuvioSharedPayloads ?? [] {
            let usesContentAddressedName = payload.codeFileName == NuvioPluginStore.codeFileName(
                forScraperID: payload.scraperID,
                code: payload.code
            )
            guard !payload.code.isEmpty,
                  payload.code.utf8.count <= NuvioPluginStore.Bounds.codeBytes,
                  usesContentAddressedName else {
                refusedPayloads += 1
                continue
            }
            guard !nuvioStore.hasCode(
                repositoryID: payload.repositoryID,
                codeFileName: payload.codeFileName
            ) else { continue }
            do {
                _ = try nuvioStore.writeCode(
                    payload.code,
                    repositoryID: payload.repositoryID,
                    scraperID: payload.scraperID
                )
                restoredNuvioFiles += 1
            } catch {
                refusedPayloads += 1
            }
        }

        if restoredScripts > 0 || restoredNuvioFiles > 0 || refusedPayloads > 0 {
            Logger.shared.log(
                "BackupManager: restored \(restoredScripts) SkyStream and \(restoredNuvioFiles) Nuvio shared payload(s); refused \(refusedPayloads)",
                type: "Services"
            )
        }
    }

    private static func captureProfileSnapshots(
        profiles: [Profile],
        includeCloudSourceMetadata: Bool,
        requireReadableReaderExtensionMetadata: Bool,
        includePrivateCloudTrackerCredentials: Bool
    ) throws -> [BackupProfileSnapshot] {
        try profiles.map { profile in
            var snapshot = BackupProfileSnapshot(
                id: profile.id,
                name: profile.name,
                avatarSymbol: profile.avatarSymbol,
                avatarColorHex: profile.avatarColorHex,
                avatarPhotoData: profile.avatarPhotoData,
                isKidsProfile: profile.isKidsProfile,
                createdAt: profile.createdAt,
                pinHash: profile.pinHash,
                pinChangedAt: profile.pinChangedAt,
                kidsFlagChangedAt: profile.kidsFlagChangedAt
            )
            if let progress = ProgressManager.shared.progressData(forProfile: profile.id) {
                snapshot.progressData = progress
            } else {
                snapshot.progressWasCaptured = false
                Logger.shared.log(
                    "BackupManager: profile \(profile.id)'s progress store could not be read; its watch history is absent from this backup rather than recorded as empty",
                    type: "Error"
                )
            }
            if let ratings = UserRatingManager.shared.ratingsAndNotes(forProfile: profile.id) {
                snapshot.userRatings = ratings.ratings
                snapshot.userRatingNotes = ratings.notes
            } else {
                snapshot.ratingsWereCaptured = false
                Logger.shared.log(
                    "BackupManager: profile \(profile.id)'s ratings store could not be read; its ratings are absent from this backup rather than recorded as empty",
                    type: "Error"
                )
            }
            if let collections = LibraryManager.shared.collections(forProfile: profile.id) {
                snapshot.collections = collections.map(BackupCollection.init(from:))
            } else {
                snapshot.collectionsWereCaptured = false
                Logger.shared.log(
                    "BackupManager: profile \(profile.id)'s library store could not be read; its collections are absent from this backup rather than recorded as empty",
                    type: "Error"
                )
            }
            if let catalogs = CatalogManager.shared.catalogsForBackup(forProfile: profile.id) {
                snapshot.catalogs = catalogs
            } else {
                snapshot.catalogsWereCaptured = false
                Logger.shared.log(
                    "BackupManager: profile \(profile.id)'s catalog store could not be read; its catalog ordering is absent from this backup rather than recorded as defaults",
                    type: "Error"
                )
            }

            let trackerState = includePrivateCloudTrackerCredentials
                ? TrackerManager.shared.trackerStateForPrivateCloudExport(
                    forProfile: profile.id
                )
                : TrackerManager.shared.trackerState(forProfile: profile.id)
            if let trackerState {
                snapshot.trackerState = includePrivateCloudTrackerCredentials
                    ? trackerState
                    : Self.trackerStateWithoutCredentials(trackerState)
                snapshot.trackerCredentialsAndRosterWereCaptured =
                    includePrivateCloudTrackerCredentials
            } else {
                snapshot.trackerStateWasCaptured = false
                snapshot.trackerCredentialsAndRosterWereCaptured = false
                Logger.shared.log(
                    "BackupManager: profile \(profile.id)'s tracker state could not be read; its tracker metadata is absent from this backup rather than recorded as disconnected",
                    type: "Error"
                )
            }
            snapshot.settings = captureProfileScopedSettings(forProfile: profile.id)

            if let historyData = ProfileSettingsStore.shared.store(for: profile.id).data(forKey: "searchHistory") {
                if let queries = BackupSearchHistory.decodedQueries(from: historyData) {
                    snapshot.searchHistory = BackupSearchHistory(queries: queries, wasCaptured: true)
                }
            } else {
                snapshot.searchHistory = BackupSearchHistory(wasCaptured: true)
            }
            try captureProfileSources(
                into: &snapshot,
                profileID: profile.id,
                includeCloudSourceMetadata: includeCloudSourceMetadata,
                requireReadableReaderExtensionMetadata: requireReadableReaderExtensionMetadata
            )
#if !os(tvOS)
            if let collections = MangaLibraryManager.shared.collectionsSnapshot(forProfile: profile.id) {
                snapshot.mangaCollections = collections.map {
                    BackupMangaCollection(
                        id: $0.id,
                        name: $0.name,
                        items: $0.items,
                        description: $0.description
                    )
                }
            } else {
                snapshot.mangaCollectionsWereCaptured = false
                Logger.shared.log(
                    "BackupManager: profile \(profile.id)'s Reader library is unreadable; omitted rather than recorded as empty",
                    type: "Storage"
                )
            }
            if let progress = MangaReadingProgressManager.shared.progressSnapshot(forProfile: profile.id) {
                snapshot.mangaReadingProgress = progress.reduce(into: [String: MangaProgress]()) {
                    $0[String($1.key)] = $1.value
                }
            } else {
                snapshot.mangaReadingProgressWasCaptured = false
                Logger.shared.log(
                    "BackupManager: profile \(profile.id)'s Reader progress is unreadable; omitted rather than recorded as empty",
                    type: "Storage"
                )
            }
            if let catalogs = MangaCatalogManager.shared.catalogsSnapshot(forProfile: profile.id) {
                snapshot.mangaCatalogs = catalogs
            } else {
                snapshot.mangaCatalogsWereCaptured = false
                Logger.shared.log(
                    "BackupManager: profile \(profile.id)'s Reader catalogs are unreadable; omitted rather than recorded as empty",
                    type: "Storage"
                )
            }
            if let customCatalogs = KanzenCustomCatalogManager.shared.catalogsSnapshot(forProfile: profile.id) {
                snapshot.customCatalogs = customCatalogs
            } else {
                snapshot.customCatalogsWereCaptured = false
                Logger.shared.log(
                    "BackupManager: profile \(profile.id)'s Reader custom catalogs are unreadable; omitted rather than recorded as empty",
                    type: "Storage"
                )
            }
#endif
            return snapshot
        }
    }

    private static func captureServicesScopedSettings() -> [String: Data]? {
        let store = ProfileSettingsStore.services
        let domainName: String
        if ProfileSettingsStore.sharesServices
            || ProfileManager.shared.activeProfileID == ProfileManager.defaultProfileID {
            domainName = Bundle.main.bundleIdentifier ?? "app.Eclipse"
        } else {
            domainName = ProfileSettingsStore.suiteName(for: ProfileManager.shared.activeProfileID)
        }
        let domain = UserDefaults.standard.persistentDomain(forName: domainName) ?? [:]

        var result: [String: Data] = [:]
        for (key, _) in domain where EclipseSettingsRegistry.scope(for: key) == .services
            && !BackupData.isTypedOrLegacyReaderSourceSetting(key) {
            guard let value = store.object(forKey: key),
                  let data = try? PropertyListSerialization.data(
                    fromPropertyList: value,
                    format: .binary,
                    options: 0
                  ),
                  data.count <= maximumProfileSettingValueBytes else {
                return nil
            }
            result[key] = data
        }
        return BackupData.servicesSettingsForExperimentalCloudSync(result)
    }

#if !os(tvOS)
    static func captureReaderExtensionState(
        metadataStore: UserDefaults,
        preferenceStore: UserDefaults
    ) throws -> BackupReaderExtensionState {
        try BackupReaderExtensionState.capture(
            from: metadataStore,
            preferenceStore: preferenceStore
        )
    }

    /// Applies untrusted Reader backup metadata transactionally. A rejected
    /// incoming payload is not evidence that the already-verified local store
    /// is corrupt, so this path must never set the legacy migration quarantine
    /// that gates Reader and completed offline downloads at startup.
    @discardableResult
    static func restoreReaderExtensionStatePreservingLocalOnFailure(
        _ state: BackupReaderExtensionState,
        metadataStore: UserDefaults,
        preferenceStore: UserDefaults,
        context: String,
        postRestoreVerification: (() throws -> Void)? = nil
    ) -> Bool {
        do {
            try state.restore(
                to: metadataStore,
                preferenceStore: preferenceStore,
                postRestoreVerification: postRestoreVerification
            )
            return true
        } catch {
            Logger.shared.log(
                "BackupManager: rejected Reader Extension metadata for \(context); existing local Reader state was preserved",
                type: "Storage"
            )
            return false
        }
    }
#endif

    private func restoreProfileSources(
        _ snapshot: BackupProfileSnapshot,
        into store: UserDefaults,
        profileID: UUID,
        preservingDeviceLocalNuvioCloudState: Bool = false
    ) -> Bool {

        let currentNuvioState = preservingDeviceLocalNuvioCloudState
            ? NuvioPluginStore(defaults: store).load()
            : nil
        let nuvioRestorePlan = snapshot.nuvioPlugins.map { incoming in
            guard let currentNuvioState else {
                return ExperimentalCloudNuvioRestorePlan(
                    state: incoming,
                    deviceLocalSourceIDs: []
                )
            }
            return BackupData.nuvioRestorePlanForExperimentalCloudSync(
                incoming: incoming,
                current: currentNuvioState
            )
        }
        let preservedDeviceLocalNuvioSourceIDs: Set<String>
        if let nuvioRestorePlan {
            preservedDeviceLocalNuvioSourceIDs = nuvioRestorePlan.deviceLocalSourceIDs
        } else if let currentNuvioState {
            // A missing captured domain has no source-deletion authority.
            preservedDeviceLocalNuvioSourceIDs = Set(
                currentNuvioState.repositories.map(\.id)
                    + currentNuvioState.scrapers.map(\.id)
            )
        } else {
            preservedDeviceLocalNuvioSourceIDs = []
        }

        Self.restoreServicesSettings(
            snapshot.servicesSettings,
            capturedCompletely: snapshot.servicesSettingsWereCaptured,
            to: store,
            preserving: preservedDeviceLocalNuvioSourceIDs
        )

        if let nuvio = nuvioRestorePlan?.state,
           let encoded = try? JSONEncoder().encode(nuvio) {
            store.set(encoded, forKey: "nuvioPluginsState.v2")
        }

        if let skyStream = snapshot.skyStream, skyStream.isSafeCloudSnapshot {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let encoded = try? encoder.encode(skyStream), encoded.count <= 50_000_000 {
                store.set(encoded, forKey: SkyStreamPluginManager.pendingSafeCloudSnapshotKey)
            }
        }

        let readerConfigurationWasRestored = restoreProfileReaderConfiguration(
            snapshot,
            into: store,
            profileID: profileID
        )

        guard let services = snapshot.services, let addons = snapshot.stremioAddons else {
            return readerConfigurationWasRestored
        }

        if profileID == ProfileManager.shared.activeProfileID {
            restoreActiveProfileSources(services: services, addons: addons)
            return readerConfigurationWasRestored
        }

        ServiceStoreScope.restoreSources(
            services: services.map {
                ServiceStoreScope.RestoredService(
                    id: $0.id,
                    url: $0.url,
                    jsonMetadata: $0.jsonMetadata,
                    jsScript: $0.jsScript,
                    isActive: $0.isActive,
                    sortIndex: $0.sortIndex
                )
            },
            addons: addons.map {
                ServiceStoreScope.RestoredAddon(
                    id: $0.id,
                    configuredURL: $0.configuredURL,
                    manifestJSON: $0.manifestJSON,
                    isActive: $0.isActive,
                    sortIndex: $0.sortIndex
                )
            },
            skyStreamStateData: snapshot.skyStreamStateData,
            forProfile: profileID
        )
        return readerConfigurationWasRestored
    }

    private func restoreProfileReaderConfiguration(
        _ snapshot: BackupProfileSnapshot,
        into store: UserDefaults,
        profileID: UUID,
        permitsUnrosteredProfile: Bool = false
    ) -> Bool {
#if !os(tvOS)
        guard PlatformCapabilities.current.supportsReader else { return true }
        let readerMetadataStore = ProfileSettingsStore.sharesServices
            ? UserDefaults.standard
            : store
        guard let readerState = snapshot.readerExtensionsState
            ?? snapshot.aidokuState.map(BackupReaderExtensionState.migratingLegacyAidoku) else {
            return snapshot.readerPrivateCloudConfigurationData == nil
        }
        guard let rawConfigurationData = snapshot.readerPrivateCloudConfigurationData else {
            return Self.restoreReaderExtensionStatePreservingLocalOnFailure(
                readerState,
                metadataStore: readerMetadataStore,
                preferenceStore: store,
                context: "profile \(profileID)"
            )
        }
        guard let configurationData = BackupProfileSnapshot
            .boundedReaderPrivateCloudConfigurationData(rawConfigurationData) else {
            Logger.shared.log(
                "BackupManager: rejected Reader private-cloud configuration for profile \(profileID); existing local Reader configuration was preserved",
                type: "Storage"
            )
            return false
        }
        var configurationWasRestored = false
        performOnMainThread {
            MainActor.assumeIsolated {
                do {
                    let configuration = try JSONDecoder().decode(
                        ReaderExtensionPrivateCloudConfiguration.self,
                        from: configurationData
                    )
                    let previousSources = try ReaderExtensionPersistence
                        .applyingPreferenceOverlay(
                            to: ReaderExtensionPersistence.loadInstalledSources(
                                from: readerMetadataStore
                            ),
                            from: store
                        )
                    let restored = Self.restoreReaderExtensionStatePreservingLocalOnFailure(
                        readerState,
                        metadataStore: readerMetadataStore,
                        preferenceStore: store,
                        context: "profile \(profileID)",
                        postRestoreVerification: {
                            try ReaderExtensionPersistence.applyPrivateCloudConfiguration(
                                configuration,
                                profileID: profileID,
                                metadataStore: readerMetadataStore,
                                preferenceStore: store,
                                previousSources: previousSources,
                                postMutationVerification: {
                                    guard readerMetadataStore.synchronize(),
                                          store.synchronize(),
                                          UserDefaults.standard.synchronize() else {
                                        throw ReaderExtensionError.persistenceFailed(
                                            "Reader private-cloud restore was not persisted"
                                        )
                                    }
                                }
                            )
                        }
                    )
                    configurationWasRestored = restored
                    guard restored, !permitsUnrosteredProfile,
                          profileID == ProfileManager.shared.activeProfileID else { return }
                    do {
                        _ = try ReaderExtensionManager.shared.reloadAfterExternalRestore()
                    } catch {
                        Logger.shared.log(
                            "BackupManager: restored Reader private-cloud configuration for profile \(profileID), but the active Reader state could not reload",
                            type: "Storage"
                        )
                    }
                } catch {
                    Logger.shared.log(
                        "BackupManager: rejected Reader private-cloud configuration for profile \(profileID); existing local Reader configuration was preserved",
                        type: "Storage"
                    )
                }
            }
        }
        return configurationWasRestored
#else
        return true
#endif
    }

    private func restoreActiveProfileSources(
        services: [BackupService],
        addons: [BackupStremioAddon]
    ) {
        let serviceStore = ServiceStore.shared
        for existing in serviceStore.getServices() {
            serviceStore.remove(existing)
        }
        for (index, service) in services.enumerated() {

            guard let script = ServiceStoreScope.securedScriptForRestore(
                service.jsScript,
                serviceID: service.id,
                profileID: ProfileManager.shared.activeProfileID
            ) else { continue }
            serviceStore.storeService(
                id: service.id,
                url: service.url,
                jsonMetadata: service.jsonMetadata,
                jsScript: script,
                isActive: service.isActive,
                sortIndex: Int64(index)
            )
        }

        let stremioStore = StremioAddonStore.shared
        stremioStore.removeAll()
        for (index, addon) in addons.enumerated() {

            guard !StremioConfiguredURLVault.isUnresolvedReference(addon.configuredURL) else {
                continue
            }
            guard let manifestData = addon.manifestJSON.data(using: .utf8),
                  let manifest = try? JSONDecoder().decode(StremioManifest.self, from: manifestData),
                  manifest.supportsInstallableResources else {
                Logger.shared.log("Skipping invalid Stremio addon from profile snapshot: \(addon.id)", type: "Stremio")
                continue
            }
            stremioStore.storeAddon(
                id: addon.id,
                configuredURL: addon.configuredURL,
                manifestJSON: addon.manifestJSON,
                isActive: addon.isActive,
                sortIndex: Int64(index)
            )
        }

        Task { @MainActor in
            ServiceManager.shared.loadServicesFromCloud()
            StremioAddonManager.shared.loadAddons()
        }
    }

    private static func captureProfileSources(
        into snapshot: inout BackupProfileSnapshot,
        profileID: UUID,
        includeCloudSourceMetadata: Bool,
        requireReadableReaderExtensionMetadata: Bool
    ) throws {
        let store = ProfileSettingsStore.shared.store(for: profileID)
#if !os(tvOS)
        do {
            let readerMetadataStore = ProfileSettingsStore.sharesServices
                ? UserDefaults.standard
                : store
            snapshot.readerExtensionsState = try captureReaderExtensionState(
                metadataStore: readerMetadataStore,
                preferenceStore: store
            )
        } catch {
            if requireReadableReaderExtensionMetadata {
                throw error
            }
            Logger.shared.log(
                "Backup: profile \(profileID)'s Reader Extension metadata is unreadable; omitted from cloud snapshot",
                type: "Storage"
            )
        }
        if includeCloudSourceMetadata {
            var configurationData: Data?
            BackupManager.shared.performOnMainThread {
                MainActor.assumeIsolated {
                    do {
                        let configuration = try ReaderExtensionManager.shared
                            .capturePrivateCloudConfiguration(for: profileID)
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        configurationData = BackupProfileSnapshot
                            .boundedReaderPrivateCloudConfigurationData(
                                try encoder.encode(configuration)
                            )
                    } catch {
                        Logger.shared.log(
                            "Backup: profile \(profileID)'s Reader private-cloud configuration is unreadable; omitted rather than recorded as empty",
                            type: "Storage"
                        )
                    }
                }
            }
            snapshot.readerPrivateCloudConfigurationData = configurationData
        }
#endif
        guard !ProfileSettingsStore.sharesServices else { return }

        typealias CapturedSources = (
            services: [BackupService],
            addons: [BackupStremioAddon],
            skyStreamState: Data?,
            skyStreamStateWasCaptured: Bool
        )
        let captured = ServiceStoreScope.withReadOnlyStore(forProfile: profileID) { context -> Result<CapturedSources, Error> in
            Result {
                let serviceRequest = NSFetchRequest<NSManagedObject>(entityName: "ServiceEntity")
                let serviceEntities = try context.fetch(serviceRequest)
                var serviceRowsWereComplete = true
                let services = serviceEntities.compactMap { entity -> BackupService? in
                    guard let id = entity.value(forKey: "id") as? UUID else {
                        serviceRowsWereComplete = false
                        return nil
                    }
                    return BackupService(
                        id: id,
                        url: entity.value(forKey: "url") as? String ?? "",
                        jsonMetadata: entity.value(forKey: "jsonMetadata") as? String ?? "",
                        jsScript: entity.value(forKey: "jsScript") as? String ?? "",
                        isActive: entity.value(forKey: "isActive") as? Bool ?? true,
                        sortIndex: entity.value(forKey: "sortIndex") as? Int64 ?? 0
                    )
                }

                let addonRequest = NSFetchRequest<NSManagedObject>(entityName: "StremioAddonEntity")
                let addonEntities = try context.fetch(addonRequest)
                var addonRowsWereComplete = true
                let addons = addonEntities.compactMap { entity -> BackupStremioAddon? in
                    guard let id = entity.value(forKey: "id") as? UUID else {
                        addonRowsWereComplete = false
                        return nil
                    }
                    let persisted = entity.value(forKey: "configuredURL") as? String ?? ""
                    let configuredURL = StremioConfiguredURLVault.resolve(
                        addonID: id,
                        persistedURL: persisted,
                        profileID: profileID
                    )
                    guard !StremioConfiguredURLVault.isUnresolvedReference(configuredURL) else {
                        addonRowsWereComplete = false
                        return nil
                    }
                    return BackupStremioAddon(
                        id: id,
                        configuredURL: configuredURL,
                        manifestJSON: entity.value(forKey: "manifestJSON") as? String ?? "",
                        isActive: entity.value(forKey: "isActive") as? Bool ?? true,
                        sortIndex: entity.value(forKey: "sortIndex") as? Int64 ?? 0
                    )
                }
                guard serviceRowsWereComplete,
                      addonRowsWereComplete,
                      services.count == serviceEntities.count,
                      addons.count == addonEntities.count else {
                    throw CocoaError(.coderInvalidValue)
                }

                let stateRequest = NSFetchRequest<NSManagedObject>(entityName: "SkyStreamStateEntity")
                stateRequest.predicate = NSPredicate(format: "id == %@", SkyStreamStateEntity.singletonID)
                stateRequest.fetchLimit = 1
                let stateEntity = try context.fetch(stateRequest).first
                let skyStreamState: Data?
                let skyStreamStateWasCaptured: Bool
                if stateEntity == nil {
                    skyStreamState = nil
                    skyStreamStateWasCaptured = true
                } else if let json = stateEntity?.value(forKey: "jsonState") as? String,
                   let data = json.data(using: .utf8),
                   data.count <= 8 * 1_024 * 1_024 {
                    skyStreamState = data
                    skyStreamStateWasCaptured = true
                } else {
                    skyStreamState = nil
                    skyStreamStateWasCaptured = false
                }
                return (
                    services,
                    addons,
                    skyStreamState,
                    skyStreamStateWasCaptured
                )
            }
        }

        if case .success(let values)? = captured {
            snapshot.services = values.services
            snapshot.stremioAddons = values.addons
            snapshot.skyStreamStateData = values.skyStreamState
            if includeCloudSourceMetadata,
               PlatformCapabilities.current.supportsSkyStreamPlugins,
               values.skyStreamStateWasCaptured {
                if let stateData = values.skyStreamState {
                    var safeSnapshot: SkyStreamBackupSnapshot?
                    let capture = {
                        MainActor.assumeIsolated {
                            safeSnapshot = SkyStreamPluginManager.completePrivateCloudMetadataSnapshot(
                                fromPersistedStateData: stateData
                            )
                        }
                    }
                    if Thread.isMainThread {
                        capture()
                    } else {
                        DispatchQueue.main.sync(execute: capture)
                    }
                    snapshot.skyStream = safeSnapshot
                } else {
                    snapshot.skyStream = SkyStreamBackupSnapshot(
                        repositories: [],
                        plugins: [],
                        createdAt: Date(timeIntervalSince1970: 0),
                        isSafeCloudSnapshot: true,
                        privateCloudConfigurationIsComplete: true
                    )
                }
            }
        } else {
            if case .failure(let error)? = captured {
                Logger.shared.log(
                    "Backup: source fetch failed for profile \(profileID): \(error.localizedDescription)",
                    type: "Storage"
                )
            }
            Logger.shared.log(
                "Backup: could not read the services database for profile \(profileID); its sources are absent from this backup rather than recorded as empty",
                type: "Storage"
            )
        }

        let domainName = profileID == ProfileManager.defaultProfileID
            ? (Bundle.main.bundleIdentifier ?? "app.Eclipse")
            : ProfileSettingsStore.suiteName(for: profileID)
        let domain = UserDefaults.standard.persistentDomain(forName: domainName) ?? [:]
        var servicesSettings: [String: Data] = [:]
        for (key, _) in domain where EclipseSettingsRegistry.scope(for: key) == .services
            && !BackupData.isTypedOrLegacyReaderSourceSetting(key)
            && !BackupData.cloudUnsafeServicesSettingsKeys.contains(key) {
            guard let value = store.object(forKey: key),
                  let data = try? PropertyListSerialization.data(
                    fromPropertyList: value,
                    format: .binary,
                    options: 0
                  ), data.count <= maximumProfileSettingValueBytes else {
                snapshot.servicesSettings = [:]
                snapshot.servicesSettingsWereCaptured = false
                return
            }
            servicesSettings[key] = data
        }
        if let safeSettings = BackupData.servicesSettingsForExperimentalCloudSync(
            servicesSettings
        ) {
            snapshot.servicesSettings = safeSettings
            snapshot.servicesSettingsWereCaptured = true
        }

        if includeCloudSourceMetadata,
           PlatformCapabilities.current.supportsNuvioPlugins {
            let nuvioStore = NuvioPluginStore(defaults: store)
            let state = nuvioStore.load()
            if !nuvioStore.stateWritesSuspended {
                snapshot.nuvioPlugins = state
            }
        } else if let data = store.data(forKey: "nuvioPluginsState.v2"),
                  let state = try? JSONDecoder().decode(
                    NuvioStoredPluginsState.self,
                    from: data
                  ) {
            snapshot.nuvioPlugins = state
        }
    }

    private static let deviceLocalProfileSettingKeys: Set<String> = [
        "searchHistory",
        "eclipseServicesSettingsSeededV1",
        "appearanceMigratedV1",
        "experimentalMPVPreloadHashedCacheKeysMigrated",
        "sourceHealthRecordsV1",
        "sourceHealthLastDailyCheckTimestamp",
        "trackerPendingCredentialDeletions.v1",
        "trackerPendingDiscardedProfileCleanup.v1",
        "traktHistoryWriteReceipts.v1",
        "localNotificationFutureMetadataRefreshDates",
        "Reader.upscaleModelName"
    ]

    private static let deviceLocalProfileSettingPrefixes = [
        "libraryCollections",
        "enabledCatalogs",
        "mangaLibraryCollections",
        "mangaReadingProgress",
        "kanzenMangaCatalogs",
        "kanzenCustomCatalogs",
        "kanzenReaderLegacyUnavailableV1",
        "readerExtensions.legacyReconnectLedger",
        "mediaStateCloudKitSuspended",
        "experimentalCloudSync",
        "experimentalICloudSync",
        "experimentalGoogleDriveSync",
        "experimentalOneDriveSync"
    ]

    static let maximumProfileSettingValueBytes = 512 * 1_024
    static let maximumProfileSettingKeys = 1_024

    static func carriesProfileScopedSetting(_ key: String) -> Bool {
        isEclipseSettingKey(key)
            && EclipseSettingsRegistry.scope(for: key) == .profile
            && !deviceLocalProfileSettingKeys.contains(key)
            && !deviceLocalProfileSettingPrefixes.contains(where: key.hasPrefix)
    }

    static func validatedBackupSettingValue(from data: Data, forKey key: String) -> Any? {
        guard data.count <= maximumProfileSettingValueBytes else { return nil }
        if let scope = MediaStateSettingRegistry.scope(for: key) {
            guard scope.appliesToCurrentPlatform else { return nil }
            return MediaStateSettingValueValidator.validatedValue(from: data, forKey: key)
        }
        return try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
    }

    static func servicesSettingParticipatesInPrivateCloud(_ key: String) -> Bool {
        EclipseSettingsRegistry.scope(for: key) == .services
            && !BackupData.cloudUnsafeServicesSettingsKeys.contains(key)
            && !BackupData.isTypedOrLegacyReaderSourceSetting(key)
    }

    static func missingAuthoritativeServicesSettingKeys(
        current: Set<String>,
        incoming: Set<String>,
        capturedCompletely: Bool
    ) -> [String] {
        guard capturedCompletely else { return [] }
        return current.filter {
            servicesSettingParticipatesInPrivateCloud($0)
                && !incoming.contains($0)
        }.sorted()
    }

    private static func restoreServicesSettings(
        _ settings: [String: Data],
        capturedCompletely: Bool,
        to store: UserDefaults,
        preserving deviceLocalSourceIDs: Set<String>
    ) {
        let keys = orderedRawServicesSettingKeys(settings)
        let incomingKeys = Set(keys)
        let missingKeys = missingAuthoritativeServicesSettingKeys(
            current: Set(store.dictionaryRepresentation().keys),
            incoming: incomingKeys,
            capturedCompletely: capturedCompletely
        )
        for key in missingKeys {
            let resetValue = ExperimentalCloudLocalSourceSelectionPolicy.restoredValue(
                [String](),
                forKey: key,
                currentStore: store,
                preserving: deviceLocalSourceIDs
            )
            if let retained = resetValue as? [String], !retained.isEmpty {
                store.set(retained, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
        for key in keys.prefix(maximumProfileSettingKeys) {
            guard let data = settings[key],
                  let decodedValue = validatedBackupSettingValue(
                    from: data,
                    forKey: key
                  ) else { continue }
            let value = ExperimentalCloudLocalSourceSelectionPolicy.restoredValue(
                decodedValue,
                forKey: key,
                currentStore: store,
                preserving: deviceLocalSourceIDs
            )
            store.set(value, forKey: key)
        }
    }

    private static func orderedRawServicesSettingKeys(
        _ settings: [String: Data]
    ) -> [String] {
        settings.keys.filter {
            servicesSettingParticipatesInPrivateCloud($0)
        }.sorted { lhs, rhs in
            let lhsIsRegistered = MediaStateSettingRegistry.scope(for: lhs) != nil
            let rhsIsRegistered = MediaStateSettingRegistry.scope(for: rhs) != nil
            if lhsIsRegistered != rhsIsRegistered { return lhsIsRegistered }
            return lhs < rhs
        }
    }

    private static func isEclipseSettingKey(_ key: String) -> Bool {
        if key.hasPrefix("Reader.") { return true }
        guard let first = key.first, first.isASCII, first.isLowercase else { return false }
        return !key.hasPrefix("com.")
    }

    private static func captureProfileScopedSettings(forProfile profileID: UUID) -> [String: Data] {
        let store = ProfileSettingsStore.shared.store(for: profileID)
        let domainName = profileID == ProfileManager.defaultProfileID
            ? (Bundle.main.bundleIdentifier ?? "app.Eclipse")
            : ProfileSettingsStore.suiteName(for: profileID)
        let domain = UserDefaults.standard.persistentDomain(forName: domainName) ?? [:]

        var seen = Set(MediaStateSettingRegistry.allKeys.filter(carriesProfileScopedSetting))
        var keys = seen.sorted()
        keys.append(contentsOf: domain.keys.filter {
            carriesProfileScopedSetting($0) && seen.insert($0).inserted
        }.sorted())

        var result: [String: Data] = [:]
        var skippedOversizedKeys = 0
        for key in keys {
            guard result.count < maximumProfileSettingKeys else { break }
            guard let value = store.object(forKey: key),
                  PropertyListSerialization.propertyList(value, isValidFor: .binary),
                  let data = try? PropertyListSerialization.data(
                    fromPropertyList: value,
                    format: .binary,
                    options: 0
                  ) else {
                continue
            }
            guard data.count <= maximumProfileSettingValueBytes else {
                skippedOversizedKeys += 1
                continue
            }
            result[key] = data
        }
        if skippedOversizedKeys > 0 {
            Logger.shared.log(
                "BackupManager: skipped \(skippedOversizedKeys) oversized profile setting(s) for profile \(profileID)",
                type: "Info"
            )
        }
        return result
    }

    private func isSkyStreamBackupDomainReady() -> Bool {
        skyStreamBackupDomainReadiness() == .ready
    }

    private func skyStreamBackupDomainReadiness() -> ExperimentalCloudBackupDomainReadiness {
#if os(iOS) && !targetEnvironment(macCatalyst)
        var readiness = ExperimentalCloudBackupDomainReadiness.loading
        performOnMainThread {
            readiness = MainActor.assumeIsolated {
                let manager = SkyStreamPluginManager.shared
                if manager.isLoaded { return .ready }
                return manager.lastErrorMessage == nil ? .loading : .unavailable
            }
        }
        return readiness
#else
        return .ready
#endif
    }

    func restoreManualBackup(
        from url: URL,
        scope: ManualBackupRestoreScope
    ) async -> Bool {
#if os(iOS)
        guard let syncSession = await MainActor.run(body: {
            ExperimentalCloudSyncManager.shared.beginManualRestore(
                keepsChangesOnThisDevice: scope.keepsChangesOnThisDevice
            )
        }) else {
            Logger.shared.log(
                "Backup restore waited because a cloud operation is still active",
                type: "CloudSync"
            )
            return false
        }

        let succeeded: Bool
        if #available(iOS 17.0, *) {
            succeeded = await MediaStateSyncManager.shared
                .performAuthoritativeSnapshotRestore {
                    await self.restoreBackup(from: url)
                }
        } else {
            succeeded = await restoreBackup(from: url)
        }
        await MainActor.run {
            ExperimentalCloudSyncManager.shared.finishManualRestore(
                syncSession,
                succeeded: succeeded
            )
        }
        return succeeded
#else
        return await restoreBackup(from: url)
#endif
    }

    func restoreBackup(
        from url: URL,
        preservesSyncedMediaState: Bool = false
    ) async -> Bool {
        do {
            let jsonData = try BoundedLocalStoreReader.read(
                from: url,
                maximumBytes: Self.maximumManualBackupFileBytes
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var backupData: BackupData

            do {
                backupData = try decoder.decode(BackupData.self, from: jsonData)
                backupData = migratingNuvioSharedPayloadsForRestore(backupData)
                Logger.shared.log("Backup decoded successfully", type: "Info")
            } catch {
                Logger.shared.log("Standard decode failed, attempting lenient restore: \(error.localizedDescription)", type: "Info")

                guard let decodedBackupData = tryLenientDecode(from: jsonData) else {
                    Logger.shared.log("Lenient decode also failed", type: "Error")
                    return false
                }
                let backupData = migratingNuvioSharedPayloadsForRestore(decodedBackupData)

                Logger.shared.log("Lenient decode succeeded with partial data", type: "Info")
                let intendedScope = activeProfileScopeToken()
                let restoreStart = try await beginShareServicesRestoreTransaction(
                    for: backupData,
                    expectedScope: intendedScope
                )
                let shareServicesTransaction = restoreStart.transaction
                let restoreScope = restoreStart.scope

                let ownsTopLevelSources = appliesTopLevelSourceData(
                    backupData,
                    activeProfileID: restoreScope.profileID
                )
                guard await restoreSkyStreamSnapshotAndWaitIfSupported(
                    ownsTopLevelSources ? backupData.skyStream : nil,
                    expectedScope: restoreScope
                ) else {
                    await restoreShareServicesModeAfterFailedRestore(shareServicesTransaction)
                    return false
                }
                guard await restoreNuvioSnapshotIfSupported(
                    ownsTopLevelSources ? backupData.nuvioPlugins : nil,
                    expectedScope: restoreScope
                ) else {
                    await restoreShareServicesModeAfterFailedRestore(shareServicesTransaction)
                    return false
                }
                guard let postApply = await applyBackupDataIfScopeIsCurrent(
                    backupData,
                    preservingLegacyCloudMediaState: preservesSyncedMediaState,
                    expectedScope: restoreScope
                ) else {
                    await restoreShareServicesModeAfterFailedRestore(shareServicesTransaction)
                    return false
                }
                let postApplyScope = postApply.scope
                await SkyStreamPluginManager.shared.captureSourceDefaultsState(
                    expectedScopeGeneration: postApplyScope.servicesGeneration
                )
                await repairActiveProfileSkyStreamStateIfNeeded(
                    backupData,
                    expectedScope: postApplyScope
                )
                guard await reloadSourceManagersAfterRestore(
                expectedScope: postApplyScope,
                toleratesInertReaderRuntime: true
            ) else {
                    await restoreShareServicesModeAfterFailedRestore(shareServicesTransaction)
                    return false
                }
                completeShareServicesRestoreTransaction(shareServicesTransaction)
                return true
            }

            let intendedScope = activeProfileScopeToken()
            let restoreStart = try await beginShareServicesRestoreTransaction(
                for: backupData,
                expectedScope: intendedScope
            )
            let shareServicesTransaction = restoreStart.transaction
            let restoreScope = restoreStart.scope
            let ownsTopLevelSources = appliesTopLevelSourceData(
                backupData,
                activeProfileID: restoreScope.profileID
            )
            guard await restoreSkyStreamSnapshotAndWaitIfSupported(
                ownsTopLevelSources ? backupData.skyStream : nil,
                expectedScope: restoreScope
            ) else {
                await restoreShareServicesModeAfterFailedRestore(shareServicesTransaction)
                return false
            }
            guard await restoreNuvioSnapshotIfSupported(
                ownsTopLevelSources ? backupData.nuvioPlugins : nil,
                expectedScope: restoreScope
            ) else {
                await restoreShareServicesModeAfterFailedRestore(shareServicesTransaction)
                return false
            }
            guard let postApply = await applyBackupDataIfScopeIsCurrent(
                backupData,
                preservingLegacyCloudMediaState: preservesSyncedMediaState,
                expectedScope: restoreScope
            ) else {
                await restoreShareServicesModeAfterFailedRestore(shareServicesTransaction)
                return false
            }
            let postApplyScope = postApply.scope
            await SkyStreamPluginManager.shared.captureSourceDefaultsState(
                expectedScopeGeneration: postApplyScope.servicesGeneration
            )
            await repairActiveProfileSkyStreamStateIfNeeded(
                backupData,
                expectedScope: postApplyScope
            )
            guard await reloadSourceManagersAfterRestore(
                expectedScope: postApplyScope,
                toleratesInertReaderRuntime: true
            ) else {
                await restoreShareServicesModeAfterFailedRestore(shareServicesTransaction)
                return false
            }
            completeShareServicesRestoreTransaction(shareServicesTransaction)
            return true
        } catch {
            Logger.shared.log("Failed to restore backup: \(error.localizedDescription)", type: "Error")
            return false
        }
    }

    private func tryLenientDecode(from jsonData: Data) -> BackupData? {
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        let lenientDecoder = JSONDecoder()
        lenientDecoder.dateDecodingStrategy = .iso8601

        let createdDate: Date
        if let dateString = json["createdDate"] as? String {
            let formatter = ISO8601DateFormatter()
            createdDate = formatter.date(from: dateString) ?? Date()
        } else {
            createdDate = Date()
        }

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
        let localNotificationSubscriptions = BackupData.sanitizedLocalNotificationSubscriptions(
            json["localNotificationSubscriptions"] as? String
        )
        let localNotificationEpisodeReminders = BackupData.sanitizedLocalNotificationEpisodeReminders(
            json["localNotificationEpisodeReminders"] as? String
        )
        let localNotificationEpisodeLeadTime = BackupData.sanitizedLocalNotificationEpisodeLeadTime(
            json["localNotificationEpisodeLeadTime"] as? Int
        )
        let localNotificationSeasonLeadTime = BackupData.sanitizedLocalNotificationSeasonLeadTime(
            json["localNotificationSeasonLeadTime"] as? Int
        )
        let localNotificationIncludeAnimeSpecials = json["localNotificationIncludeAnimeSpecials"] as? Bool

        let defaultPlaybackSpeed = BackupData.sanitizedDefaultPlaybackSpeed(
            json["defaultPlaybackSpeed"] as? Double
        )
        let holdSpeedPlayer = BackupData.sanitizedHoldSpeedPlayer(
            json["holdSpeedPlayer"] as? Double
        )
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
        let nextEpisodeThreshold = BackupData.sanitizedNextEpisodeThreshold(
            json["nextEpisodeThreshold"] as? Double
        )
        let nextEpisodeSkipFillerEnabled = json["nextEpisodeSkipFillerEnabled"] as? Bool ?? NextEpisodeFillerSettings.defaultEnabled
        let playerBrightnessGestureEnabled = json["playerBrightnessGestureEnabled"] as? Bool ?? json["vlcBrightnessGestureEnabled"] as? Bool ?? false
        let playerVolumeGestureEnabled = json["playerVolumeGestureEnabled"] as? Bool ?? json["vlcVolumeGestureEnabled"] as? Bool ?? false
        let playerTwoFingerTapPlayPauseEnabled = json["playerTwoFingerTapPlayPauseEnabled"] as? Bool ?? true
        let playerCenterTapPlayPauseEnabled = json["playerCenterTapPlayPauseEnabled"] as? Bool ?? true
        let playerDoubleTapSeekEnabled = json["playerDoubleTapSeekEnabled"] as? Bool ?? json["vlcDoubleTapSeekEnabled"] as? Bool ?? true
        let playerDoubleTapSeekSeconds = BackupData.sanitizedPlayerDoubleTapSeekSeconds(
            json["playerDoubleTapSeekSeconds"] as? Double
                ?? json["vlcDoubleTapSeekSeconds"] as? Double
        )
        let playerOpenSubtitlesEnabled = json["playerOpenSubtitlesEnabled"] as? Bool ?? json["vlcOpenSubtitlesEnabled"] as? Bool ?? false
        let playerOpenSubtitlesAutoFallbackEnabled = json["playerOpenSubtitlesAutoFallbackEnabled"] as? Bool ?? json["vlcOpenSubtitlesAutoFallbackEnabled"] as? Bool ?? true
        let playerPerformanceOverlayEnabled = json["playerPerformanceOverlayEnabled"] as? Bool ?? false
        let mpvForegroundFPSRaw = BackupData.optionalInt(
            from: json["mpvForegroundFPS"],
            defaultValue: 30
        )
        let mpvForegroundFPS = mpvForegroundFPSRaw == 60 ? 60 : 30
        let mpvRenderBackend = BackupData.sanitizedMPVRenderBackend(json["mpvRenderBackend"] as? String)
        let mpvMetalQualityProfile = BackupData.sanitizedMPVMetalQualityProfile(json["mpvMetalQualityProfile"] as? String)
        let mpvUpscalingMode = BackupData.sanitizedMPVUpscalingMode(json["mpvUpscalingMode"] as? String)
        let mpvNeuralUpscaler = BackupData.sanitizedMPVNeuralUpscaler(json["mpvNeuralUpscaler"] as? String)
        let mpvNeuralUpscalerTV = BackupData.sanitizedMPVNeuralUpscaler(json["mpvNeuralUpscalerTV"] as? String)
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
        let smartInAppPlayerChoosingEnabled = json["smartInAppPlayerChoosingEnabled"] as? Bool ?? false
        let experimentalFeaturesEnabled = json["experimentalFeaturesEnabled"] as? Bool
        let experimentalFeaturesLastChangedAt = BackupData.sanitizedExperimentalFeaturesLastChangedAt(
            json["experimentalFeaturesLastChangedAt"] as? Double
        )
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

        let subtitleForegroundColor = BackupData.backupColorData(from: json["subtitleForegroundColor"])
        let subtitleStrokeColor = BackupData.backupColorData(from: json["subtitleStrokeColor"])
        let subtitleStrokeWidth = BackupData.sanitizedSubtitleStrokeWidth(
            json["subtitleStrokeWidth"] as? Double
        )
        let subtitleFontSize = BackupData.sanitizedSubtitleFontSize(
            json["subtitleFontSize"] as? Double
        )
        let subtitleVerticalOffset = BackupData.sanitizedSubtitleVerticalOffset(
            json["subtitleVerticalOffset"] as? Double
        )
        let subtitlesVisible = json["subtitlesVisible"] as? Bool ?? false

        let showKanzen = json["showKanzen"] as? Bool ?? false
        let hideSplashScreen = json["hideSplashScreen"] as? Bool
        let modeSwitchAnimationEnabled = json["modeSwitchAnimationEnabled"] as? Bool ?? ModeSwitchAnimationSettings.defaultEnabled
        let kanzenAutoUpdateModules = json["kanzenAutoUpdateModules"] as? Bool ?? true
        let seasonMenu = json["seasonMenu"] as? Bool ?? false
        let horizontalEpisodeList = json["horizontalEpisodeList"] as? Bool ?? false
        let mediaDetailTitleArtworkEnabled = json["mediaDetailTitleArtworkEnabled"] as? Bool ?? MediaDetailTitleArtworkSettings.defaultEnabled
        let mediaDetailAlternatePosterEnabled = json["mediaDetailAlternatePosterEnabled"] as? Bool ?? MediaDetailAlternatePosterSettings.defaultEnabled
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

        let readerFontSize = BackupData.sanitizedReaderFontSize(
            json["readerFontSize"] as? Double
        )
        let readerFontFamily = json["readerFontFamily"] as? String ?? "-apple-system"
        let readerFontWeight = json["readerFontWeight"] as? String ?? "normal"
        let readerColorPreset = json["readerColorPreset"] as? Int ?? 0
        let readerTextAlignment = json["readerTextAlignment"] as? String ?? "left"
        let readerLineSpacing = BackupData.sanitizedReaderLineSpacing(
            json["readerLineSpacing"] as? Double
        )
        let readerMargin = BackupData.sanitizedReaderMargin(
            json["readerMargin"] as? Double
        )

        let autoClearCacheEnabled = json["autoClearCacheEnabled"] as? Bool ?? false
        let autoClearCacheThresholdMB = BackupData.sanitizedAutoClearCacheThresholdMB(
            json["autoClearCacheThresholdMB"] as? Double
        )
        let highQualityThreshold = BackupData.sanitizedHighQualityThreshold(
            json["highQualityThreshold"] as? Double
        )
        let backgroundHLSPipelineEnabled = json["backgroundHLSPipelineEnabled"] as? Bool ?? false
        let readerDownloadsBackgroundEnabled = json["readerDownloadsBackgroundEnabled"] as? Bool ?? true
        let readerDownloadsWifiOnly = json["readerDownloadsWifiOnly"] as? Bool ?? false
        let readerDownloadsParallelLimit = BackupData.sanitizedReaderDownloadsParallelLimit(BackupData.optionalInt(from: json["readerDownloadsParallelLimit"], defaultValue: 2))
        let autoUpdateServicesEnabled = json["autoUpdateServicesEnabled"] as? Bool ?? true
        let servicesAutoModeEnabled = json["servicesAutoModeEnabled"] as? Bool ?? AutoModeSettings.defaultEnabled
        let servicesAutoSelectEpisodesEnabled = json["servicesAutoSelectEpisodesEnabled"] as? Bool ?? false
        let servicesAutoModeErrorIntelligenceEnabled = json["servicesAutoModeErrorIntelligenceEnabled"] as? Bool ?? AutoModeErrorIntelligenceSettings.defaultEnabled
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

        // Lenient restore may salvage independent fields, but a destructive
        // domain is authoritative only when its entire payload decodes. A
        // malformed member must not turn the rest into a partial replacement.
        let decodedCollections = decodeBackupJSONValue(
            [BackupCollection].self,
            from: json["collections"],
            using: lenientDecoder
        )
        let decodedProgressData = decodeBackupJSONValue(
            ProgressData.self,
            from: json["progressData"],
            using: lenientDecoder
        )
        let decodedTrackerState = decodeBackupJSONValue(
            TrackerState.self,
            from: json["trackerState"],
            using: lenientDecoder
        )
        let decodedCatalogs = decodeBackupJSONValue(
            [Catalog].self,
            from: json["catalogs"],
            using: lenientDecoder
        )
        let decodedServices = decodeBackupJSONValue(
            [BackupService].self,
            from: json["services"],
            using: lenientDecoder
        )
        let collections = decodedCollections ?? []
        let progressData = decodedProgressData ?? ProgressData()
        let trackerState = decodedTrackerState ?? TrackerState()
        let catalogs = decodedCatalogs ?? []
        let services = decodedServices ?? []

        let stremioAddons = decodeBackupJSONValue(
            [BackupStremioAddon].self,
            from: json["stremioAddons"],
            using: lenientDecoder
        )

        var skyStream: SkyStreamBackupSnapshot? = nil
        if let skyStreamValue = json["skyStream"],
           JSONSerialization.isValidJSONObject(skyStreamValue),
           let skyStreamJSON = try? JSONSerialization.data(withJSONObject: skyStreamValue) {
            skyStream = try? lenientDecoder.decode(SkyStreamBackupSnapshot.self, from: skyStreamJSON)
        }

        var nuvioPlugins: NuvioStoredPluginsState? = nil
        if let nuvioValue = json["nuvioPlugins"],
           JSONSerialization.isValidJSONObject(nuvioValue),
           let nuvioJSON = try? JSONSerialization.data(withJSONObject: nuvioValue) {
            nuvioPlugins = try? lenientDecoder.decode(NuvioStoredPluginsState.self, from: nuvioJSON)
        }

        let decodedMangaCollections = decodeBackupJSONValue(
            [BackupMangaCollection].self,
            from: json["mangaCollections"],
            using: lenientDecoder
        )
        let decodedMangaReadingProgress = decodeBackupJSONValue(
            [String: MangaProgress].self,
            from: json["mangaReadingProgress"],
            using: lenientDecoder
        )
        let decodedMangaCatalogs = decodeBackupJSONValue(
            [MangaCatalog].self,
            from: json["mangaCatalogs"],
            using: lenientDecoder
        )
        let decodedCustomCatalogs = decodeBackupJSONValue(
            [KanzenCustomCatalog].self,
            from: json["customCatalogs"],
            using: lenientDecoder
        )
        let decodedKanzenModules = decodeBackupJSONValue(
            [BackupKanzenModule].self,
            from: json["kanzenModules"],
            using: lenientDecoder
        )
        let mangaCollections = decodedMangaCollections ?? []
        let mangaReadingProgress = decodedMangaReadingProgress ?? [:]
        let mangaCatalogs = decodedMangaCatalogs ?? []
        let customCatalogs = decodedCustomCatalogs ?? []
        let kanzenModules = decodedKanzenModules ?? []

        var aidokuState: BackupAidokuState?
        if let aidokuDict = json["aidokuState"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: aidokuDict),
           let decoded = try? lenientDecoder.decode(BackupAidokuState.self, from: data) {
            aidokuState = BackupData.aidokuStateWithoutExecutablePayloads(decoded)
        }

        var readerExtensionsState: BackupReaderExtensionState?
        if let readerExtensionsDictionary = json["readerExtensionsState"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: readerExtensionsDictionary),
           let decoded = try? lenientDecoder.decode(BackupReaderExtensionState.self, from: data) {
            readerExtensionsState = decoded.sanitized()
        } else if let aidokuState {
            readerExtensionsState = BackupReaderExtensionState.migratingLegacyAidoku(aidokuState)
        }

        let searchHistory = BackupSearchHistory(jsonValue: json["searchHistory"])

        var recommendationCache: [TMDBSearchResult] = []
        if let recsData = json["recommendationCache"] as? [[String: Any]] {
            for dict in recsData {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let rec = try? lenientDecoder.decode(TMDBSearchResult.self, from: data) {
                    recommendationCache.append(rec)
                }
            }
        }

        let decodedUserRatings: [String: Double]? = decodeBackupJSONValue(
            [String: Double].self,
            from: json["userRatings"],
            using: lenientDecoder
        ) ?? decodeBackupJSONValue(
            [String: Int].self,
            from: json["userRatings"],
            using: lenientDecoder
        ).map { $0.mapValues(Double.init) }
        let decodedUserRatingNotes = decodeBackupJSONValue(
            [String: String].self,
            from: json["userRatingNotes"],
            using: lenientDecoder
        )
        let userRatings = BackupData.sanitizedUserRatings(decodedUserRatings ?? [:])
        let userRatingNotes = BackupData.sanitizedUserRatingNotes(decodedUserRatingNotes ?? [:])

        let mediaStateSettings = BackupData.mediaStateSettings(fromJSONValue: json["mediaStateSettings"])
        let collectionsPresent = decodedCollections != nil
        let progressDataPresent = decodedProgressData != nil
        let trackerStatePresent = decodedTrackerState != nil
        let catalogsPresent = decodedCatalogs != nil
        let servicesPresent = decodedServices != nil
        let mangaCollectionsPresent = decodedMangaCollections != nil
        let mangaReadingProgressPresent = decodedMangaReadingProgress != nil
        let mangaCatalogsPresent = decodedMangaCatalogs != nil
        let customCatalogsPresent = decodedCustomCatalogs != nil
        let kanzenModulesPresent = decodedKanzenModules != nil
        let userRatingsPresent = decodedUserRatings != nil && decodedUserRatingNotes != nil

        var lenient = BackupData(
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
            mpvNeuralUpscaler: mpvNeuralUpscaler,
            mpvNeuralUpscalerTV: mpvNeuralUpscalerTV,
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
            mediaDetailAlternatePosterEnabled: mediaDetailAlternatePosterEnabled,
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
            servicesAutoModeErrorIntelligenceEnabled: servicesAutoModeErrorIntelligenceEnabled,
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
            skyStream: skyStream,
            nuvioPlugins: nuvioPlugins,
            mangaCollections: mangaCollections,
            mangaReadingProgress: mangaReadingProgress,
            mangaCatalogs: mangaCatalogs,
            customCatalogs: customCatalogs,
            kanzenModules: kanzenModules,
            readerExtensionsState: readerExtensionsState,
            aidokuState: aidokuState,
            searchHistory: searchHistory,
            recommendationCache: recommendationCache,
            userRatings: userRatings,
            userRatingNotes: userRatingNotes,
            mediaStateSettings: mediaStateSettings,
            collectionsPresent: collectionsPresent,
            progressDataPresent: progressDataPresent,
            trackerStatePresent: trackerStatePresent,
            catalogsPresent: catalogsPresent,
            servicesPresent: servicesPresent,
            mangaCollectionsPresent: mangaCollectionsPresent,
            mangaReadingProgressPresent: mangaReadingProgressPresent,
            mangaCatalogsPresent: mangaCatalogsPresent,
            customCatalogsPresent: customCatalogsPresent,
            kanzenModulesPresent: kanzenModulesPresent,
            userRatingsPresent: userRatingsPresent
        )

        if let profilesJSON = json["profiles"], !(profilesJSON is NSNull) {
            guard let decodedProfiles = decodeBackupJSONValue(
                [BackupProfileSnapshot].self,
                from: profilesJSON,
                using: lenientDecoder
            ) else {
                Logger.shared.log(
                    "Lenient decode refused an unreadable profile roster",
                    type: "Error"
                )
                return nil
            }
            lenient.profiles = decodedProfiles
        } else if json["profiles"] is NSNull {
            Logger.shared.log(
                "Lenient decode found a null profile roster; only independently authoritative top-level domains can restore",
                type: "Info"
            )
        }
        lenient.activeProfileID = (json["activeProfileID"] as? String).flatMap(UUID.init(uuidString:))

        lenient.sharesServices = json["sharesServices"] as? Bool
        if let servicesJSON = json["servicesSettings"],
           let servicesData = try? JSONSerialization.data(withJSONObject: servicesJSON),
           let decodedServices = try? lenientDecoder.decode([String: Data].self, from: servicesData) {
            lenient.servicesSettings = decodedServices
        }

        if let payloadsJSON = json["skyStreamSharedPayloads"],
           let payloadsData = try? JSONSerialization.data(withJSONObject: payloadsJSON),
           let decoded = try? lenientDecoder.decode([BackupSkyStreamSharedPayload].self, from: payloadsData) {
            lenient.skyStreamSharedPayloads = decoded
        }
        if let payloadsJSON = json["nuvioSharedPayloads"],
           let payloadsData = try? JSONSerialization.data(withJSONObject: payloadsJSON),
           let decoded = try? lenientDecoder.decode([BackupNuvioSharedPayload].self, from: payloadsData) {
            lenient.nuvioSharedPayloads = decoded
        }
        lenient.allTopLevelSettingsWereCaptured = false
        let decodedSettingKeys = BackupData.decodedTopLevelSettingKeys(
            fromJSONObject: json
        )
        if json.keys.contains("topLevelSettingKeys") {
            lenient.decodedTopLevelSettingKeys = decodedSettingKeys.intersection(
                BackupData.sanitizedDeclaredTopLevelSettingKeys(
                    json["topLevelSettingKeys"] as? [String]
                )
            )
        } else {
            lenient.decodedTopLevelSettingKeys = decodedSettingKeys
        }
        return lenient
    }

    @MainActor
    private func restoreNuvioSnapshotIfSupported(
        _ snapshot: NuvioStoredPluginsState?,
        expectedScope: ActiveProfileScopeToken,
        preservingDeviceLocalCloudState: Bool = false
    ) async -> Bool {
        guard ProfileManager.shared.activeProfileID == expectedScope.profileID,
              ServiceStoreScope.isCurrent(expectedScope.servicesGeneration),
              ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration else {
            return false
        }
        guard let snapshot else { return true }
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard PlatformCapabilities.current.supportsNuvioPlugins else { return true }
        let manager = NuvioPluginManager.shared
        manager.load()
        guard ProfileManager.shared.activeProfileID == expectedScope.profileID,
              ServiceStoreScope.isCurrent(expectedScope.servicesGeneration),
              ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration else {
            return false
        }
        let stateToRestore: NuvioStoredPluginsState
        if preservingDeviceLocalCloudState {
            stateToRestore = BackupData.nuvioRestorePlanForExperimentalCloudSync(
                incoming: snapshot,
                current: manager.backupState() ?? NuvioStoredPluginsState()
            ).state
        } else {
            stateToRestore = snapshot
        }
        let result = await manager.restoreBackupState(
            stateToRestore,
            expectedScopeGeneration: expectedScope.servicesGeneration
        )
        guard result.restoreWasPersisted, !result.wasInterrupted else {
            return false
        }
#endif
        return ProfileManager.shared.activeProfileID == expectedScope.profileID
            && ServiceStoreScope.isCurrent(expectedScope.servicesGeneration)
            && ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration
    }

    @MainActor
    private func restoreSkyStreamSnapshotAndWaitIfSupported(
        _ snapshot: SkyStreamBackupSnapshot?,
        expectedScope: ActiveProfileScopeToken
    ) async -> Bool {
        guard ProfileManager.shared.activeProfileID == expectedScope.profileID,
              ServiceStoreScope.isCurrent(expectedScope.servicesGeneration),
              ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration else {
            return false
        }
        guard let snapshot else { return true }

#if os(iOS) && !targetEnvironment(macCatalyst)
        if !PlatformCapabilities.current.supportsSkyStreamPlugins {
            do {

                try persistOpaqueSkyStreamSnapshot(snapshot)
                return ProfileManager.shared.activeProfileID == expectedScope.profileID
                    && ServiceStoreScope.isCurrent(expectedScope.servicesGeneration)
                    && ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration
            } catch {
                Logger.shared.log(
                    "Failed to preserve disabled SkyStream restore errorType=\(String(reflecting: type(of: error)))",
                    type: snapshot.isSafeCloudSnapshot ? "CloudSync" : "Error"
                )
                return false
            }
        }
        let safeSnapshot = snapshot.isSafeCloudSnapshot
            ? BackupData.skyStreamSnapshotForExperimentalCloudSync(snapshot)
            : nil
        if snapshot.isSafeCloudSnapshot, safeSnapshot == nil {
            Logger.shared.log("Refused invalid safe SkyStream backup metadata", type: "CloudSync")
            return false
        }

        let manager = SkyStreamPluginManager.shared
        await manager.reloadPersistedStateAfterRestore()
        guard manager.isLoaded, !Task.isCancelled,
              ProfileManager.shared.activeProfileID == expectedScope.profileID,
              ServiceStoreScope.isCurrent(expectedScope.servicesGeneration),
              ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration else {
            let context = snapshot.isSafeCloudSnapshot ? "cloud metadata merge" : "manual restore"
            Logger.shared.log(
                "SkyStream \(context) skipped because the plugin manager did not finish loading",
                type: snapshot.isSafeCloudSnapshot ? "CloudSync" : "Error"
            )
            return false
        }
        do {
            if let safeSnapshot {
                let result = try await manager.restoreSafeCloudSnapshot(safeSnapshot)
                if result.isComplete {
                    clearAdoptedOpaqueSkyStreamSnapshot(isSafeCloudSnapshot: true)
                    Logger.shared.log("Safe SkyStream cloud metadata merged", type: "CloudSync")
                } else {
                    Logger.shared.log(
                        "Safe SkyStream cloud metadata partially merged unresolvedCount=\(result.unresolvedPackageIDs.count)",
                        type: "CloudSync"
                    )
                }
            } else {
                try await manager.restoreManualBackupSnapshot(snapshot)
                clearAdoptedOpaqueSkyStreamSnapshot(isSafeCloudSnapshot: false)
                Logger.shared.log("Authoritative SkyStream manual backup restored", type: "Info")
            }
            return ProfileManager.shared.activeProfileID == expectedScope.profileID
                && ServiceStoreScope.isCurrent(expectedScope.servicesGeneration)
                && ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration
        } catch {
            let context = snapshot.isSafeCloudSnapshot ? "cloud metadata merge" : "manual restore"
            Logger.shared.log(
                "Failed SkyStream \(context) errorType=\(String(reflecting: type(of: error)))",
                type: snapshot.isSafeCloudSnapshot ? "CloudSync" : "Error"
            )
            return false
        }
#else
        do {

            try persistOpaqueSkyStreamSnapshot(snapshot)
            return ProfileManager.shared.activeProfileID == expectedScope.profileID
                && ServiceStoreScope.isCurrent(expectedScope.servicesGeneration)
                && ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration
        } catch {
            Logger.shared.log(
                "Failed to preserve opaque SkyStream backup errorType=\(String(reflecting: type(of: error)))",
                type: snapshot.isSafeCloudSnapshot ? "CloudSync" : "Error"
            )
            return false
        }
#endif
    }

    private func repairActiveProfileSkyStreamStateIfNeeded(
        _ backup: BackupData,
        expectedScope: ActiveProfileScopeToken
    ) async {
        guard !ProfileSettingsStore.sharesServices else { return }

        guard activeProfileScopeIsCurrent(expectedScope, includingRoster: false) else { return }
        let activeProfileID = expectedScope.profileID
        guard let owner = backup.activeProfileID, owner != activeProfileID else { return }
        guard let stateData = backup.profiles?
            .first(where: { $0.id == activeProfileID })?
            .skyStreamStateData else { return }
        do {
            try await ServiceStore.shared.saveSkyStreamStateData(
                stateData,
                expectedScopeGeneration: expectedScope.servicesGeneration
            )
        } catch {
            Logger.shared.log(
                "BackupManager: could not restore the active profile's own SkyStream state after an owner-mismatched restore: \(error.localizedDescription)",
                type: "Error"
            )
            return
        }
        Logger.shared.log(
            "BackupManager: applied the active profile's own SkyStream state over the top-level owner's (\(owner))",
            type: "Services"
        )
    }

    private func appliesTopLevelSourceData(_ backup: BackupData, activeProfileID: UUID) -> Bool {
        if backup.sharesServices ?? ProfileSettingsStore.sharesServices { return true }

        guard currentProfileRosterIsReadable() else { return false }
        guard let owner = backup.activeProfileID else { return true }
        return owner == activeProfileID
    }

    private func currentActiveProfileID() -> UUID {
        var id = ProfileManager.defaultProfileID
        performOnMainThread {
            id = ProfileManager.shared.activeProfileID
        }
        return id
    }

    private func currentProfileRosterIsReadable() -> Bool {
        var isReadable = false
        performOnMainThread {
            isReadable = ProfileManager.shared.rosterStoreIsReadable
        }
        return isReadable
    }

    @MainActor
    private func applyBackupDataIfScopeIsCurrent(
        _ backup: BackupData,
        refreshCloudSources: Bool = false,
        preservingLegacyCloudMediaState: Bool = false,
        preservingDeviceLocalReaderModelSelection: Bool = false,
        expectedScope: ActiveProfileScopeToken
    ) -> ScopedBackupApplicationResult? {
        guard ProfileManager.shared.activeProfileID == expectedScope.profileID,
              ServiceStoreScope.isCurrent(expectedScope.servicesGeneration),
              ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration else {
            Logger.shared.log(
                "BackupManager: aborted restore because the active profile changed",
                type: "Error"
            )
            return nil
        }
        let mediaStateAuthority = preservingLegacyCloudMediaState
            ? captureLegacyCloudMediaStateAuthority()
            : nil
        let application = applyBackupData(
            backup,
            refreshCloudSources: refreshCloudSources,
            preservingCanonicalMediaState: preservingLegacyCloudMediaState,
            preservingDeviceLocalReaderModelSelection: preservingDeviceLocalReaderModelSelection
        )
        if let mediaStateAuthority {
            restoreLegacyCloudMediaStateAuthority(mediaStateAuthority)
        }
        guard let application else { return nil }
        performOnMainThread {
            HomeCatalogLayoutStore.shared.reloadFromStorage()
            EclipseTheme.shared.reloadForActiveProfile()
            AlgorithmManager.shared.reloadForActiveProfile()
            AccentColorManager.shared.reloadForActiveProfile()
            Settings.current?.reloadForActiveProfile()
        }

        return ScopedBackupApplicationResult(
            scope: ActiveProfileScopeToken(
                profileID: ProfileManager.shared.activeProfileID,
                servicesGeneration: ServiceStoreScope.generation,
                rosterGeneration: ProfileManager.shared.rosterGeneration
            ),
            authoritativeTrackerProfileIDs: application.authoritativeTrackerProfileIDs
        )
    }

    private func applyShareServicesModeIfNeeded(_ backup: BackupData) {
        guard let sharesServices = backup.sharesServices,
              sharesServices != ProfileSettingsStore.sharesServices else { return }
        ProfileSettingsStore.sharesServices = sharesServices
        performOnMainThread {
            ServiceStoreScope.activeProfileDidChange()
        }
        Logger.shared.log(
            "BackupManager: applied the backup's Share Services mode (\(sharesServices)) before restoring sources",
            type: "Services"
        )
    }

    @MainActor
    private func beginShareServicesRestoreTransaction(
        for backup: BackupData,
        expectedScope: ActiveProfileScopeToken
    ) throws -> ShareServicesRestoreStart {
        guard ProfileManager.shared.activeProfileID == expectedScope.profileID,
              ServiceStoreScope.isCurrent(expectedScope.servicesGeneration),
              ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration else {
            throw BackupRestoreError.activeProfileChanged
        }
        let previousValue = ProfileSettingsStore.sharesServices
        let requestedValue = backup.sharesServices ?? previousValue
        let activeProfileID = ProfileManager.shared.activeProfileID
        let targetUsesSharedDefaults = requestedValue
            || activeProfileID == ProfileManager.defaultProfileID
        let targetStoreURL = targetUsesSharedDefaults
            ? ServiceStoreScope.sharedStoreURL
            : ServiceStoreScope.scopedStoreURL(forProfile: activeProfileID)

        ServiceStoreScope.willChangeActiveProfile()
        let targetStoreSnapshot = try ServiceStoreScope.captureStoreFileSnapshot(
            at: targetStoreURL,
            scopedVaultProfileID: targetUsesSharedDefaults ? nil : activeProfileID
        )
        let targetSettings = captureServicesSettingsForRollback(
            profileID: activeProfileID,
            usesSharedDefaults: targetUsesSharedDefaults
        )
        let transaction = ShareServicesRestoreTransaction(
            previousValue: previousValue,
            requestedValue: requestedValue,
            activeProfileID: activeProfileID,
            targetUsesSharedDefaults: targetUsesSharedDefaults,
            targetStoreSnapshot: targetStoreSnapshot,
            targetSettingsBeforeTransition: targetSettings
        )

        if transaction.didSwitch {
            ProfileSettingsStore.sharesServices = requestedValue
            ServiceStoreScope.activeProfileDidChange(notifyObservers: false)
            Logger.shared.log(
                "BackupManager: applied the backup's Share Services mode (\(requestedValue)) before restoring sources",
                type: "Services"
            )
        }
        let postTransitionScope = ActiveProfileScopeToken(
            profileID: ProfileManager.shared.activeProfileID,
            servicesGeneration: ServiceStoreScope.generation,
            rosterGeneration: ProfileManager.shared.rosterGeneration
        )
        guard transaction.activeProfileID == postTransitionScope.profileID,
              postTransitionScope.rosterGeneration == expectedScope.rosterGeneration else {
            throw BackupRestoreError.activeProfileChanged
        }
        return ShareServicesRestoreStart(
            transaction: transaction,
            scope: postTransitionScope
        )
    }

    private func captureServicesSettingsForRollback(
        profileID: UUID,
        usesSharedDefaults: Bool
    ) -> [String: Data] {
        let domainName = usesSharedDefaults
            ? (Bundle.main.bundleIdentifier ?? "app.Eclipse")
            : ProfileSettingsStore.suiteName(for: profileID)
        let domain = UserDefaults.standard.persistentDomain(forName: domainName) ?? [:]
        return domain.reduce(into: [String: Data]()) { result, entry in
            guard entry.key == "eclipseServicesSettingsSeededV1"
                    || EclipseSettingsRegistry.scope(for: entry.key) == .services,
                  let data = try? PropertyListSerialization.data(
                    fromPropertyList: entry.value,
                    format: .binary,
                    options: 0
                  ) else { return }
            result[entry.key] = data
        }
    }

    private func restoreServicesSettingsAfterFailedTransition(
        _ transaction: ShareServicesRestoreTransaction
    ) {
        let profileID = transaction.activeProfileID
        let store = transaction.targetUsesSharedDefaults
            ? UserDefaults.standard
            : ProfileSettingsStore.shared.store(for: profileID)
        let domainName = transaction.targetUsesSharedDefaults
            ? (Bundle.main.bundleIdentifier ?? "app.Eclipse")
            : ProfileSettingsStore.suiteName(for: profileID)
        let currentDomain = UserDefaults.standard.persistentDomain(forName: domainName) ?? [:]
        for key in currentDomain.keys where key == "eclipseServicesSettingsSeededV1"
            || EclipseSettingsRegistry.scope(for: key) == .services {
            store.removeObject(forKey: key)
        }
        for (key, data) in transaction.targetSettingsBeforeTransition {
            guard let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) else { continue }
            store.set(value, forKey: key)
        }
    }

    @MainActor
    private func restoreShareServicesModeAfterFailedRestore(
        _ transaction: ShareServicesRestoreTransaction
    ) async {
        if transaction.didSwitch {
            ProfileSettingsStore.sharesServices = transaction.previousValue
            ServiceStoreScope.activeProfileDidChange(notifyObservers: false)
        } else {
            ServiceStoreScope.willChangeActiveProfile()
        }
        if let snapshot = transaction.targetStoreSnapshot {
            do {
                try ServiceStoreScope.restoreStoreFileSnapshot(snapshot)
            } catch {
                Logger.shared.log(
                    "BackupManager: failed to restore the pre-attempt services database: \(error.localizedDescription)",
                    type: "Error"
                )
            }
            ServiceStoreScope.discardStoreFileSnapshot(snapshot)
        }
        restoreServicesSettingsAfterFailedTransition(transaction)
        _ = await reloadSourceManagersAfterRestore(
            expectedScope: activeProfileScopeToken(),
            toleratesInertReaderRuntime: true
        )
        Logger.shared.log(
            "BackupManager: restored Share Services mode and scoped source state after a failed restore",
            type: "Services"
        )
    }

    private func completeShareServicesRestoreTransaction(
        _ transaction: ShareServicesRestoreTransaction
    ) {
        if let snapshot = transaction.targetStoreSnapshot {
            ServiceStoreScope.discardStoreFileSnapshot(snapshot)
        }
    }

    @MainActor
    func prepareReaderExtensionAuthenticationForAccountBoundary(
        outgoingProfileIDs: Set<UUID>
    ) -> Bool {
#if os(iOS)
        do {
            let result = try ReaderExtensionProfileAuthenticationLifecycle
                .prepareForProfileStoreDeletion(
                    profileIDs: Array(outgoingProfileIDs)
                )
            if let error = result.firstError {
                Logger.shared.log(
                    "BackupManager: Reader authentication cleanup remains durably pending at the account boundary: \(error.localizedDescription)",
                    type: "Storage"
                )
            }
        } catch {
            Logger.shared.log(
                "BackupManager: refused to clear Reader metadata because authentication cleanup could not be checkpointed: \(error.localizedDescription)",
                type: "Storage"
            )
            return false
        }
#else
        _ = outgoingProfileIDs
#endif
        return true
    }

    @MainActor
    func replaceActiveSourcesWithAccountNeutralState(
        outgoingProfileIDs: Set<UUID>,
        readerAuthenticationCleanupPrepared: Bool = false
    ) -> Bool {
        if !readerAuthenticationCleanupPrepared,
           !prepareReaderExtensionAuthenticationForAccountBoundary(
                outgoingProfileIDs: outgoingProfileIDs
           ) {
            return false
        }
        let serviceStore = ServiceStore.shared
        TVServiceSettingVault.removeAllAccountsForAccountBoundary()
        StremioConfiguredURLVault.removeAllAccountsForAccountBoundary()

        let clearedServices = serviceStore.removeAllServicesForAccountBoundary()
        let clearedAddons = StremioAddonStore.shared.removeAll()
        let clearedSkyStream = serviceStore.clearSkyStreamStateDataForAccountBoundary()

        let defaults = ProfileSettingsStore.services
#if !os(tvOS)
        let retainedServicesKeys: Set<String> = [
            ReaderExtensionPersistence.pendingAuthenticationCleanupKey
        ]
#else
        let retainedServicesKeys: Set<String> = []
#endif
        for key in defaults.dictionaryRepresentation().keys
            where EclipseSettingsRegistry.scope(for: key) == .services
                && !retainedServicesKeys.contains(key) {
            defaults.removeObject(forKey: key)
        }

#if os(iOS)
        let clearedModules = ModuleManager.shared.replaceWithAccountNeutralMetadata()
        do {
            try BackupReaderExtensionState(
                metadataJSON: nil,
                installedSourceCount: 0,
                showMatureSources: false,
                autoUpdateSources: true,
                lastAutoUpdate: nil
            ).restore(to: defaults)
            defaults.removeObject(
                forKey: BackupReaderExtensionState.legacyAidokuSourcesStorageKey
            )
        } catch {
            Logger.shared.log(
                "BackupManager: could not clear Reader Extension metadata at the account boundary",
                type: "Storage"
            )
            return false
        }
#else
        let clearedModules = true
#endif

        ServiceManager.shared.loadServicesFromCloud()
        StremioAddonManager.shared.loadAddons()
        SourceHealthStore.shared.reloadPersistedStateAfterRestore()
#if os(iOS) && !targetEnvironment(macCatalyst)
        NuvioPluginManager.shared.load()
#endif

        return clearedServices && clearedAddons && clearedSkyStream && clearedModules
    }

    @MainActor
    func reloadSourceManagersAfterAccountBoundary() async -> Bool {
        await reloadSourceManagersAfterRestore(
            expectedScope: activeProfileScopeToken(),
            toleratesInertReaderRuntime: true
        )
    }

    @MainActor
    private func reloadSourceManagersAfterRestore(
        expectedScope: ActiveProfileScopeToken,
        toleratesInertReaderRuntime: Bool = false
    ) async -> Bool {
        guard ProfileManager.shared.activeProfileID == expectedScope.profileID,
              ServiceStoreScope.isCurrent(expectedScope.servicesGeneration),
              ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration else {
            return false
        }

        ServiceManager.shared.loadServicesFromCloud()
        StremioAddonManager.shared.loadAddons()
        SourceHealthStore.shared.reloadPersistedStateAfterRestore()

        await SkyStreamPluginManager.shared.reloadPersistedStateAfterRestore()
        guard ProfileManager.shared.activeProfileID == expectedScope.profileID,
              ServiceStoreScope.isCurrent(expectedScope.servicesGeneration),
              ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration else {
            return false
        }

#if os(iOS) && !targetEnvironment(macCatalyst)
        if PlatformCapabilities.current.supportsNuvioPlugins {
            guard await NuvioPluginManager.shared.reloadPersistedStateAfterRestore(
                expectedScopeGeneration: expectedScope.servicesGeneration
            ) else { return false }
        }
#endif
#if !os(tvOS)
        do {
            guard try ReaderExtensionManager.shared.reloadPersistedStateAfterRestore() else {
                return false
            }
        } catch {
            guard toleratesInertReaderRuntime,
                  ReaderExtensionRestoreReloadPolicy.restoreSurvives(error) else {
                Logger.shared.log(
                    "BackupManager: Reader Extension metadata could not reload after restore: \(error.localizedDescription)",
                    type: "Storage"
                )
                return false
            }
            Logger.shared.log(
                "BackupManager: Reader Extensions stayed inert after restore; every other restored domain stands",
                type: "Storage"
            )
        }
#endif

        return ProfileManager.shared.activeProfileID == expectedScope.profileID
            && ServiceStoreScope.isCurrent(expectedScope.servicesGeneration)
            && ProfileManager.shared.rosterGeneration == expectedScope.rosterGeneration
    }

    private func applyBackupData(
        _ backup: BackupData,
        refreshCloudSources: Bool = false,
        preservingCanonicalMediaState: Bool = false,
        preservingDeviceLocalReaderModelSelection: Bool = false
    ) -> BackupApplicationResult? {
        var trackerManager: TrackerManager!
        performOnMainThread {
            trackerManager = TrackerManager.shared
        }
        trackerManager.setBackupRestoreSyncSuppressed(true)
        defer {
            trackerManager.setBackupRestoreSyncSuppressed(false)
        }

        let topLevelOwner = backup.activeProfileID

        let activeProfileID = currentActiveProfileID()
        var appliesTopLevelPerProfileData = currentProfileRosterIsReadable()
            && !preservingCanonicalMediaState
        if appliesTopLevelPerProfileData,
           let topLevelOwner {
            appliesTopLevelPerProfileData = topLevelOwner == activeProfileID
        }
        if !appliesTopLevelPerProfileData {
            Logger.shared.log(
                "BackupManager: the top-level payload belongs to profile \(topLevelOwner?.uuidString ?? "?"), which is not active here; it will be restored from the per-profile roster instead",
                type: "Info"
            )
        }

        let topLevelSnapshot = topLevelOwner.flatMap { owner in
            backup.profiles?.first { $0.id == owner }
        }
        let appliesTopLevelCollections = appliesTopLevelPerProfileData
            && Self.topLevelDomainIsAuthoritative(
                payloadWasDecoded: backup.hasCollections,
                profileCaptureFlag: topLevelSnapshot?.collectionsWereCaptured
            )
        let appliesTopLevelProgress = appliesTopLevelPerProfileData
            && Self.topLevelDomainIsAuthoritative(
                payloadWasDecoded: backup.hasProgressData,
                profileCaptureFlag: topLevelSnapshot?.progressWasCaptured
            )
        let appliesTopLevelRatings = appliesTopLevelPerProfileData
            && Self.topLevelDomainIsAuthoritative(
                payloadWasDecoded: backup.hasUserRatings,
                profileCaptureFlag: topLevelSnapshot?.ratingsWereCaptured
            )
        let appliesTopLevelCatalogs = appliesTopLevelPerProfileData
            && Self.topLevelDomainIsAuthoritative(
                payloadWasDecoded: backup.hasCatalogs,
                profileCaptureFlag: topLevelSnapshot?.catalogsWereCaptured
            )
        let appliesTopLevelTracker = appliesTopLevelPerProfileData
            && Self.topLevelDomainIsAuthoritative(
                payloadWasDecoded: backup.hasTrackerState,
                profileCaptureFlag: topLevelSnapshot?.trackerStateWasCaptured
            )
        let appliesTopLevelMangaCollections = appliesTopLevelPerProfileData
            && (topLevelSnapshot?.mangaCollectionsWereCaptured ?? true)
        let appliesTopLevelMangaProgress = appliesTopLevelPerProfileData
            && (topLevelSnapshot?.mangaReadingProgressWasCaptured ?? true)
        let appliesTopLevelMangaCatalogs = appliesTopLevelPerProfileData
            && (topLevelSnapshot?.mangaCatalogsWereCaptured ?? true)
        let appliesTopLevelCustomCatalogs = appliesTopLevelPerProfileData
            && (topLevelSnapshot?.customCatalogsWereCaptured ?? true)
        if appliesTopLevelPerProfileData,
           !appliesTopLevelCollections || !appliesTopLevelProgress || !appliesTopLevelRatings
            || !appliesTopLevelCatalogs || !appliesTopLevelTracker {
            Logger.shared.log(
                "BackupManager: the top-level payload is missing domains its own profile could not capture (collections=\(appliesTopLevelCollections) progress=\(appliesTopLevelProgress) ratings=\(appliesTopLevelRatings) catalogs=\(appliesTopLevelCatalogs) tracker=\(appliesTopLevelTracker)); this device keeps its own copy of those",
                type: "Error"
            )
        }

        let appliesTopLevelSources = appliesTopLevelSourceData(backup, activeProfileID: activeProfileID)
        if !appliesTopLevelSources {
            Logger.shared.log(
                "BackupManager: the top-level sources belong to profile \(topLevelOwner?.uuidString ?? "?") and services are not shared; this profile keeps its own sources",
                type: "Services"
            )
        }

        let userDefaults = ScopedSettingsDefaults(
            appliesProfileScopedWrites: appliesTopLevelPerProfileData,
            appliesServicesScopedWrites: appliesTopLevelSources,
            decodedTopLevelSettingKeys: backup.decodedTopLevelSettingKeys,
            allTopLevelSettingsWereCaptured: backup.allTopLevelSettingsWereCaptured
        )

        let preservesLocalSkySourceSettings = backup.skyStream == nil
            || backup.skyStream?.isSafeCloudSnapshot == true

        let preservesLocalNuvioSourceSettings = backup.nuvioPlugins == nil
        let currentAutoModeSourceIds = userDefaults.stringArray(
            forKey: "servicesAutoModeSourceIds"
        ) ?? []
        let currentAutoModeSourceOrderIds = userDefaults.stringArray(
            forKey: "servicesAutoModeSourceOrderIds"
        ) ?? []
        let currentExtraRulesSourceIds = StreamLanguageFilter.extraRulesSourceIds()
        var preservedLocalSourceIDs = Set<String>()
        if preservesLocalSkySourceSettings {
            preservedLocalSourceIDs.formUnion(currentAutoModeSourceIds.filter(
                StreamLanguageFilter.isValidSkyStreamSourceID
            ))
            preservedLocalSourceIDs.formUnion(currentAutoModeSourceOrderIds.filter(
                StreamLanguageFilter.isValidSkyStreamSourceID
            ))
            preservedLocalSourceIDs.formUnion((currentExtraRulesSourceIds ?? []).filter(
                StreamLanguageFilter.isValidSkyStreamSourceID
            ))
        }
        if preservesLocalNuvioSourceSettings {
            preservedLocalSourceIDs.formUnion(currentAutoModeSourceIds.filter(
                StreamLanguageFilter.isValidNuvioSourceID
            ))
            preservedLocalSourceIDs.formUnion(currentAutoModeSourceOrderIds.filter(
                StreamLanguageFilter.isValidNuvioSourceID
            ))
            preservedLocalSourceIDs.formUnion((currentExtraRulesSourceIds ?? []).filter(
                StreamLanguageFilter.isValidNuvioSourceID
            ))
        }
        if refreshCloudSources,
           appliesTopLevelSources,
           let incomingNuvioState = backup.nuvioPlugins {
            let currentNuvioState = NuvioPluginStore(
                defaults: ProfileSettingsStore.services
            ).load()
            preservedLocalSourceIDs.formUnion(
                BackupData.nuvioRestorePlanForExperimentalCloudSync(
                    incoming: incomingNuvioState,
                    current: currentNuvioState
                ).deviceLocalSourceIDs
            )
        }
        if refreshCloudSources {
            for service in ServiceStore.shared.getServices() {
                let metadata = (try? JSONEncoder().encode(service.metadata))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let backupService = BackupService(
                    id: service.id,
                    url: service.url,
                    jsonMetadata: metadata,
                    jsScript: service.jsScript,
                    isActive: service.isActive,
                    sortIndex: service.sortIndex
                )
                if BackupData.serviceForExperimentalCloudSync(backupService) == nil {
                    preservedLocalSourceIDs.insert("service:\(service.id.uuidString)")
                }
            }
            for addon in StremioAddonStore.shared.getAddons() {
                let manifestJSON = (try? JSONEncoder().encode(addon.manifest))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let backupAddon = BackupStremioAddon(
                    id: addon.id,
                    configuredURL: addon.configuredURL,
                    manifestJSON: manifestJSON,
                    isActive: addon.isActive,
                    sortIndex: addon.sortIndex
                )
                if BackupData.stremioAddonForExperimentalCloudSync(backupAddon) == nil {
                    preservedLocalSourceIDs.insert("stremio:\(addon.id.uuidString)")
                }
            }
        }
        let preservedExtraRulesLocalSourceIds = (currentExtraRulesSourceIds
            ?? currentAutoModeSourceOrderIds).filter(preservedLocalSourceIDs.contains)

        if !preservingCanonicalMediaState {
            BackupData.restoreMediaStateSettings(
                backup.mediaStateSettings,
                appliesProfileScopedWrites: appliesTopLevelPerProfileData,
                appliesServicesScopedWrites: appliesTopLevelSources
            )
        }

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

        userDefaults.set(restoredEngine.rawValue, forKey: "inAppPlayer")
        userDefaults.set(backup.showScheduleTab, forKey: "showScheduleTab")
        userDefaults.set(backup.showLocalScheduleTime, forKey: "showLocalScheduleTime")
        userDefaults.set(ScheduleMode.sanitizedRawValue(backup.defaultScheduleMode), forKey: "defaultScheduleMode")
        userDefaults.set(ScheduleWindow.sanitizedDays(backup.scheduleWindowDays), forKey: ScheduleWindow.storageKey)
        if let value = BackupData.sanitizedLocalNotificationSubscriptions(
            backup.localNotificationSubscriptions
        ) {
            userDefaults.set(value, forKey: "localNotificationSubscriptions")
        }
        if let value = BackupData.sanitizedLocalNotificationEpisodeReminders(
            backup.localNotificationEpisodeReminders
        ) {
            userDefaults.set(value, forKey: "localNotificationEpisodeReminders")
        }
        if let value = BackupData.sanitizedLocalNotificationEpisodeLeadTime(
            backup.localNotificationEpisodeLeadTime
        ) {
            userDefaults.set(value, forKey: "localNotificationEpisodeLeadTime")
        }
        if let value = BackupData.sanitizedLocalNotificationSeasonLeadTime(
            backup.localNotificationSeasonLeadTime
        ) {
            userDefaults.set(value, forKey: "localNotificationSeasonLeadTime")
        }
        if let value = backup.localNotificationIncludeAnimeSpecials {
            userDefaults.set(value, forKey: "localNotificationIncludeAnimeSpecials")
        }

        userDefaults.set(
            BackupData.sanitizedDefaultPlaybackSpeed(backup.defaultPlaybackSpeed),
            forKey: "defaultPlaybackSpeed"
        )
        userDefaults.set(
            BackupData.sanitizedHoldSpeedPlayer(backup.holdSpeedPlayer),
            forKey: "holdSpeedPlayer"
        )
        userDefaults.set(backup.externalPlayer, forKey: "externalPlayer")
        userDefaults.set(backup.preferDownloadedMedia, forKey: "preferDownloadedMedia")
        userDefaults.set(backup.alwaysLandscape, forKey: "alwaysLandscape")

        if appliesTopLevelPerProfileData,
           backup.topLevelSettingIsAuthoritative(
                storageKey: PlayerPlaybackLockSettings.enabledKey
           ) {
            PlayerPlaybackLockSettings.setEnabled(backup.playerPlaybackLockEnabled)
        }
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
        userDefaults.set(
            BackupData.sanitizedNextEpisodeThreshold(backup.nextEpisodeThreshold),
            forKey: "nextEpisodeThreshold"
        )
        userDefaults.set(backup.nextEpisodeSkipFillerEnabled, forKey: NextEpisodeFillerSettings.enabledKey)
        userDefaults.set(backup.playerBrightnessGestureEnabled, forKey: "playerBrightnessGestureEnabled")
        userDefaults.set(backup.playerVolumeGestureEnabled, forKey: "playerVolumeGestureEnabled")
        userDefaults.set(backup.playerTwoFingerTapPlayPauseEnabled, forKey: "playerTwoFingerTapPlayPauseEnabled")
        userDefaults.set(backup.playerCenterTapPlayPauseEnabled, forKey: "playerCenterTapPlayPauseEnabled")
        userDefaults.set(backup.playerDoubleTapSeekEnabled, forKey: "playerDoubleTapSeekEnabled")
        userDefaults.set(
            BackupData.sanitizedPlayerDoubleTapSeekSeconds(
                backup.playerDoubleTapSeekSeconds
            ),
            forKey: "playerDoubleTapSeekSeconds"
        )
        userDefaults.set(backup.playerOpenSubtitlesEnabled, forKey: "playerOpenSubtitlesEnabled")
        userDefaults.set(backup.playerOpenSubtitlesAutoFallbackEnabled, forKey: "playerOpenSubtitlesAutoFallbackEnabled")
        userDefaults.set(backup.playerPerformanceOverlayEnabled, forKey: "playerPerformanceOverlayEnabled")
        userDefaults.set(backup.mpvForegroundFPS == 60 ? 60 : 30, forKey: "mpvForegroundFPS")
        userDefaults.set(BackupData.sanitizedMPVRenderBackend(backup.mpvRenderBackend), forKey: "mpvRenderBackend")
        userDefaults.set(BackupData.sanitizedMPVMetalQualityProfile(backup.mpvMetalQualityProfile), forKey: "mpvMetalQualityProfile")
        userDefaults.set(BackupData.sanitizedMPVUpscalingMode(backup.mpvUpscalingMode), forKey: "mpvUpscalingMode")
        userDefaults.set(BackupData.sanitizedMPVNeuralUpscaler(backup.mpvNeuralUpscaler), forKey: "mpvNeuralUpscaler")
        userDefaults.set(BackupData.sanitizedMPVNeuralUpscaler(backup.mpvNeuralUpscalerTV), forKey: "mpvNeuralUpscalerTV")
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
        if let experimentalFeaturesEnabled = backup.experimentalFeaturesEnabled {
            userDefaults.set(experimentalFeaturesEnabled, forKey: ExperimentalFeatureState.enabledKey)
            userDefaults.set(
                BackupData.sanitizedExperimentalFeaturesLastChangedAt(
                    backup.experimentalFeaturesLastChangedAt
                ) ?? 0,
                forKey: ExperimentalFeatureState.lastChangedAtKey
            )
        }
        userDefaults.set(backup.experimentalMPVPreloadEnabled, forKey: ExperimentalFeatureState.mpvPreloadEnabledKey)
        userDefaults.set(backup.experimentalMPVSmoothTransitionEnabled, forKey: ExperimentalFeatureState.mpvSmoothTransitionEnabledKey)
        userDefaults.set(backup.experimentalMPVPreloadCellularEnabled, forKey: ExperimentalFeatureState.mpvPreloadCellularEnabledKey)
        userDefaults.set(ExperimentalFeatureState.clampedMPVPreloadWifiLimitMB(backup.experimentalMPVPreloadWifiLimitMB), forKey: ExperimentalFeatureState.mpvPreloadWifiLimitMBKey)
        userDefaults.set(ExperimentalFeatureState.clampedMPVPreloadCellularLimitMB(backup.experimentalMPVPreloadCellularLimitMB), forKey: ExperimentalFeatureState.mpvPreloadCellularLimitMBKey)
        userDefaults.set(backup.experimentalMPVShowRemainingTime, forKey: ExperimentalFeatureState.mpvShowRemainingTimeKey)
        userDefaults.set(backup.experimentalMPVPreciseProgress, forKey: ExperimentalFeatureState.mpvPreciseProgressKey)
        userDefaults.set(backup.experimentalMPVIgnoreSpecialSubtitleStyles, forKey: ExperimentalFeatureState.mpvIgnoreSpecialSubtitleStylesKey)
        userDefaults.set(backup.experimentalMPVPreloadAutoClear, forKey: ExperimentalFeatureState.mpvPreloadAutoClearKey)

        if let fgColor = backup.subtitleForegroundColor {
            userDefaults.set(fgColor, forKey: "subtitles_foregroundColor")
        }
        if let strokeColor = backup.subtitleStrokeColor {
            userDefaults.set(strokeColor, forKey: "subtitles_strokeColor")
        }
        userDefaults.set(
            BackupData.sanitizedSubtitleStrokeWidth(backup.subtitleStrokeWidth),
            forKey: "subtitles_strokeWidth"
        )
        userDefaults.set(
            BackupData.sanitizedSubtitleFontSize(backup.subtitleFontSize),
            forKey: "subtitles_fontSize"
        )
        userDefaults.set(
            BackupData.sanitizedSubtitleVerticalOffset(backup.subtitleVerticalOffset),
            forKey: "playerSubtitleOverlayBottomConstant"
        )
        userDefaults.set(backup.subtitlesVisible, forKey: "subtitles_isVisible")

        userDefaults.set(backup.showKanzen, forKey: "showKanzen")
        if let hideSplashScreen = backup.hideSplashScreen {
            userDefaults.set(hideSplashScreen, forKey: "hideSplashScreen")
        }
        userDefaults.set(backup.modeSwitchAnimationEnabled, forKey: ModeSwitchAnimationSettings.enabledKey)
        userDefaults.set(backup.kanzenAutoUpdateModules, forKey: "kanzenAutoUpdateModules")
        userDefaults.set(backup.seasonMenu, forKey: "seasonMenu")
        userDefaults.set(backup.horizontalEpisodeList, forKey: "horizontalEpisodeList")
        userDefaults.set(backup.mediaDetailTitleArtworkEnabled, forKey: MediaDetailTitleArtworkSettings.enabledKey)
        userDefaults.set(backup.mediaDetailAlternatePosterEnabled, forKey: MediaDetailAlternatePosterSettings.enabledKey)
        userDefaults.set(backup.mediaDetailSimilarTitlesEnabled, forKey: MediaDetailSimilarTitlesSettings.enabledKey)
        userDefaults.set(backup.useClassicScheduleUI, forKey: "useClassicScheduleUI")
        userDefaults.set(BackupData.sanitizedNonEmptyString(backup.heroBannerCatalogId, defaultValue: "trending"), forKey: "heroBannerCatalogId")
        userDefaults.set(BackupData.sanitizedHeroBannerBehavior(backup.heroBannerBehavior), forKey: "heroBannerBehavior")
        if let overridesData = backup.homeCatalogLayoutOverrides.data(using: .utf8), !backup.homeCatalogLayoutOverrides.isEmpty {
            userDefaults.set(overridesData, forKey: HomeCatalogLayoutStore.storageKey)
        } else {
            userDefaults.removeObject(forKey: HomeCatalogLayoutStore.storageKey)
        }

        if appliesTopLevelPerProfileData {
            HomeCatalogLayoutStore.shared.reloadFromStorage()
        }
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
        if let readerUpscaleModelName = BackupReaderUpscaleModelRestorePolicy.modelNameToApply(
            incoming: backup.readerUpscaleModelName,
            preservesDeviceLocalSelection: preservingDeviceLocalReaderModelSelection
        ) {
            userDefaults.set(readerUpscaleModelName, forKey: "Reader.upscaleModelName")
        }
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

        userDefaults.set(
            BackupData.sanitizedReaderFontSize(backup.readerFontSize),
            forKey: "readerFontSize"
        )
        userDefaults.set(backup.readerFontFamily, forKey: "readerFontFamily")
        userDefaults.set(backup.readerFontWeight, forKey: "readerFontWeight")
        userDefaults.set(backup.readerColorPreset, forKey: "readerColorPreset")
        userDefaults.set(backup.readerTextAlignment, forKey: "readerTextAlignment")
        userDefaults.set(
            BackupData.sanitizedReaderLineSpacing(backup.readerLineSpacing),
            forKey: "readerLineSpacing"
        )
        userDefaults.set(
            BackupData.sanitizedReaderMargin(backup.readerMargin),
            forKey: "readerMargin"
        )

        userDefaults.set(backup.autoClearCacheEnabled, forKey: "autoClearCacheEnabled")
        userDefaults.set(
            BackupData.sanitizedAutoClearCacheThresholdMB(
                backup.autoClearCacheThresholdMB
            ),
            forKey: "autoClearCacheThresholdMB"
        )
        userDefaults.set(
            BackupData.sanitizedHighQualityThreshold(backup.highQualityThreshold),
            forKey: "highQualityThreshold"
        )
        userDefaults.set(backup.backgroundHLSPipelineEnabled, forKey: "backgroundHLSPipelineEnabled")
        userDefaults.set(backup.readerDownloadsBackgroundEnabled, forKey: "readerDownloadsBackgroundEnabled")
        userDefaults.set(backup.readerDownloadsWifiOnly, forKey: "readerDownloadsWifiOnly")
        userDefaults.set(BackupData.sanitizedReaderDownloadsParallelLimit(backup.readerDownloadsParallelLimit), forKey: "readerDownloadsParallelLimit")
        userDefaults.set(backup.autoUpdateServicesEnabled, forKey: "autoUpdateServicesEnabled")
        userDefaults.set(backup.servicesAutoModeEnabled, forKey: "servicesAutoModeEnabled")
        userDefaults.set(backup.servicesAutoSelectEpisodesEnabled, forKey: "servicesAutoSelectEpisodesEnabled")
        userDefaults.set(backup.servicesAutoModeErrorIntelligenceEnabled, forKey: AutoModeErrorIntelligenceSettings.enabledKey)
        let restoredAutoModeSourceIds = ExperimentalCloudLocalSourceSelectionPolicy.membership(
            current: currentAutoModeSourceIds,
            incoming: backup.servicesAutoModeSourceIds,
            preserving: preservedLocalSourceIDs
        )
        let orderedAutoModeSourceIds = BackupData.sanitizedStringList(backup.servicesAutoModeSourceOrderIds)
        let restoredAutoModeSourceOrderIds = ExperimentalCloudLocalSourceSelectionPolicy.order(
            current: currentAutoModeSourceOrderIds,
            incoming: orderedAutoModeSourceIds + restoredAutoModeSourceIds.filter {
                !orderedAutoModeSourceIds.contains($0)
            },
            preserving: preservedLocalSourceIDs
        )
        userDefaults.set(restoredAutoModeSourceIds, forKey: "servicesAutoModeSourceIds")
        userDefaults.set(restoredAutoModeSourceOrderIds, forKey: "servicesAutoModeSourceOrderIds")
        userDefaults.set(AutoModeQualityPreference.sanitizedRawValue(backup.servicesAutoModeQualityPreference), forKey: AutoModeQualityPreference.storageKey)

        if appliesTopLevelSources {
            if backup.topLevelSettingIsAuthoritative(
                storageKey: ServicesResultRankingSettings.minimumSimilarityKey
            ) {
                ServicesResultRankingSettings.setMinimumSimilarity(backup.servicesResultMinimumSimilarity)
            }
            if backup.topLevelSettingIsAuthoritative(
                storageKey: ServicesResultRankingSettings.dropMismatchedResultsKey
            ) {
                ServicesResultRankingSettings.setDropsMismatchedResults(backup.servicesDropMismatchedResults)
            }
            if backup.topLevelSettingIsAuthoritative(storageKey: "servicesIncludedStreamLanguages") {
                StreamLanguageFilter.setIncludedLanguages(backup.servicesIncludedStreamLanguages)
            }
            if backup.topLevelSettingIsAuthoritative(storageKey: "servicesHiddenStreamLanguages") {
                StreamLanguageFilter.setHiddenLanguages(backup.servicesHiddenStreamLanguages)
            }
            if backup.topLevelSettingIsAuthoritative(storageKey: "servicesHideStreamsWithoutLanguageData") {
                StreamLanguageFilter.setHidesStreamsWithoutLanguageData(backup.servicesHideStreamsWithoutLanguageData)
            }
            if backup.topLevelSettingIsAuthoritative(storageKey: "servicesAssumeOriginalAudio") {
                StreamLanguageFilter.setAssumesOriginalAudio(backup.servicesAssumeOriginalAudio)
            }
            if backup.topLevelSettingIsAuthoritative(storageKey: "servicesTreatDubbedAnimeAsEnglish") {
                StreamLanguageFilter.setTreatsDubbedAnimeAsEnglish(backup.servicesTreatDubbedAnimeAsEnglish)
            }
            if backup.topLevelSettingIsAuthoritative(storageKey: "servicesHiddenStreamQualities") {
                StreamLanguageFilter.setHiddenQualityHeights(backup.servicesHiddenStreamQualities)
            }
            if backup.topLevelSettingIsAuthoritative(storageKey: "servicesHideStreamsWithoutDetectedQuality") {
                StreamLanguageFilter.setHidesStreamsWithoutDetectedQuality(backup.servicesHideStreamsWithoutDetectedQuality)
            }
        }
        userDefaults.set(backup.servicesStremioStyleSheetEnabled, forKey: ServicesSheetPresentationSettings.stremioStyleEnabledKey)
        let restoredExtraRulesSourceIds: [String]?
        if backup.servicesExtraRulesSourceIds == nil,
           currentExtraRulesSourceIds == nil {

            restoredExtraRulesSourceIds = nil
        } else {
            let restoredBase = backup.servicesExtraRulesSourceIds
                .map(BackupData.sanitizedStringList)
                ?? restoredAutoModeSourceOrderIds
            restoredExtraRulesSourceIds = ExperimentalCloudLocalSourceSelectionPolicy.membership(
                current: preservedExtraRulesLocalSourceIds,
                incoming: restoredBase,
                preserving: preservedLocalSourceIDs
            )
        }
        if appliesTopLevelSources,
           backup.topLevelSettingIsAuthoritative(storageKey: "servicesExtraRulesSourceIds") {
            StreamLanguageFilter.setExtraRulesSourceIds(restoredExtraRulesSourceIds)
        }
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

        if appliesTopLevelPerProfileData,
           backup.topLevelSettingIsAuthoritative(
                storageKey: PerformanceModeSettings.fastAnimeCatalogOverridesKey
           ) {
            PerformanceModeSettings.fastAnimeCatalogOverrides = backup.performanceModeFastAnimeCatalogOverrides
        }

        if appliesTopLevelPerProfileData,
           backup.searchHistory.wasCaptured || !backup.searchHistory.queries.isEmpty,
           let searchHistoryData = try? JSONEncoder().encode(backup.searchHistory.queries) {
            userDefaults.set(searchHistoryData, forKey: "searchHistory")
        }
        performOnMainThread {

            if appliesTopLevelPerProfileData,
               backup.topLevelSettingIsAuthoritative(storageKey: "filterHorror") {
                TMDBContentFilter.shared.filterHorror = backup.filterHorrorContent
            }
            if appliesTopLevelPerProfileData,
               backup.topLevelSettingIsAuthoritative(storageKey: "selectedSimilarityAlgorithm") {
                AlgorithmManager.shared.selectedAlgorithm = SimilarityAlgorithm(rawValue: BackupData.sanitizedSimilarityAlgorithm(backup.selectedSimilarityAlgorithm)) ?? .hybrid
            }

            let settings = Settings.shared
            let theme = EclipseTheme.shared
            settings.objectWillChange.send()
            theme.objectWillChange.send()
        }

        if appliesTopLevelCollections {
            let restoredCollections = backup.collections.map { $0.toLibraryCollection() }
            performOnMainThread {

                LibraryManager.shared.replaceCollectionsForMediaState(restoredCollections)
            }
        }

        if appliesTopLevelProgress {
            let progressManager = ProgressManager.shared
            progressManager.replaceProgressDataForRestore(
                BackupData.sanitizedProgressData(
                    backup.progressData,
                    preservingDeviceLocalReferences: true
                ),
                expectedProfileID: activeProfileID
            )
        }

        if appliesTopLevelTracker,
           topLevelSnapshot?.trackerCredentialsAndRosterWereCaptured != true {
            performOnMainThread {
                let restoredTrackerState = topLevelSnapshot?.trackerCredentialsAndRosterWereCaptured == true
                    ? topLevelSnapshot?.trackerState ?? backup.trackerState
                    : backup.trackerState
                _ = trackerManager.applyRestoredTrackerState(
                    restoredTrackerState,
                    forProfile: activeProfileID,
                    credentialsAndRosterAreAuthoritative:
                        topLevelSnapshot?.trackerCredentialsAndRosterWereCaptured == true
                )
            }
        }

        let restoredPerformanceModeEnabled = backup.topLevelSettingIsAuthoritative(
            storageKey: PerformanceModeSettings.enabledKey
        ) ? backup.performanceModeEnabled : PerformanceModeSettings.isEnabled
        if !appliesTopLevelPerProfileData {
            performOnMainThread {
                CatalogManager.shared.setPerformanceModeEnabled(PerformanceModeSettings.isEnabled)
            }
        } else if appliesTopLevelCatalogs, backup.catalogs.isEmpty {
            performOnMainThread {
                CatalogManager.shared.replaceCatalogsForMediaState([])
                CatalogManager.shared.setPerformanceModeEnabled(restoredPerformanceModeEnabled)
            }
        } else if appliesTopLevelCatalogs {
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
                catalogManager.setPerformanceModeEnabled(restoredPerformanceModeEnabled)
                catalogManager.catalogs = merged
                catalogManager.saveCatalogs()
            }
        } else {
            performOnMainThread {
                let catalogManager = CatalogManager.shared
                catalogManager.setPerformanceModeEnabled(restoredPerformanceModeEnabled)
                catalogManager.saveCatalogs()
            }
        }

        applyShareServicesModeIfNeeded(backup)

        let serviceStore = ServiceStore.shared
        let appliesTopLevelServices = appliesTopLevelSources && backup.hasServices
        let existingServices = appliesTopLevelServices ? serviceStore.getServices() : []
        let incomingServices = (appliesTopLevelServices ? backup.services : []).sorted(by: {
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

            guard let script = ServiceStoreScope.securedScriptForRestore(
                svc.jsScript,
                serviceID: svc.id,
                profileID: activeProfileID
            ) else { continue }
            serviceStore.storeService(
                id: svc.id,
                url: svc.url,
                jsonMetadata: svc.jsonMetadata,
                jsScript: script,
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

        if appliesTopLevelSources, let stremioAddons = backup.stremioAddons {
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

            let resolvedURLsByAddonID: [UUID: String] = addonsToRestore.reduce(into: [:]) { result, addon in
                let resolved = StremioConfiguredURLVault.resolve(
                    addonID: addon.id,
                    persistedURL: addon.configuredURL
                )
                guard resolved != addon.configuredURL else { return }
                result[addon.id] = resolved
            }

            if refreshCloudSources {
                for addon in stremioStore.getAddons() where !deviceLocalAddonIDs.contains(addon.id) {
                    stremioStore.remove(addon)
                }
            } else {
                stremioStore.removeAll()
            }

            for addon in addonsToRestore where !deviceLocalAddonIDs.contains(addon.id) {

                let storedURL = resolvedURLsByAddonID[addon.id] ?? addon.configuredURL
                let configuredURL = storedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if StremioConfiguredURLVault.isUnresolvedReference(configuredURL) {
                    Logger.shared.log(
                        "Skipping Stremio addon \(addon.id) from backup: its configured URL was stored in this device's Keychain and is not in the backup. Re-add it to restore it.",
                        type: "Stremio"
                    )
                    continue
                }
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

        }

        if appliesTopLevelMangaCollections, backup.hasMangaCollections {
            let restoredMangaCollections = backup.mangaCollections.map { bc in
                MangaLibraryCollection(id: bc.id, name: bc.name, items: bc.items, description: bc.description)
            }
            performOnMainThread {
                MangaLibraryManager.shared.collections = restoredMangaCollections
            }
        }

        if appliesTopLevelMangaProgress, backup.hasMangaReadingProgress {
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

        if appliesTopLevelMangaCatalogs, backup.hasMangaCatalogs {
            let mangaCatalogManager = MangaCatalogManager.shared
            mangaCatalogManager.catalogs = backup.mangaCatalogs
            mangaCatalogManager.saveCatalogs()
        }

        if appliesTopLevelCustomCatalogs, backup.hasCustomCatalogs {
            let restoredCustomCatalogs = backup.customCatalogs
            performOnMainThread {
                KanzenCustomCatalogManager.shared.applyRestoredCatalogs(
                    restoredCustomCatalogs,
                    forProfile: activeProfileID
                )
            }
        }

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
        if appliesTopLevelSources,
           topLevelSnapshot?.readerPrivateCloudConfigurationData == nil,
           let readerState = backup.readerExtensionsState
                ?? backup.aidokuState.map(BackupReaderExtensionState.migratingLegacyAidoku) {
            _ = Self.restoreReaderExtensionStatePreservingLocalOnFailure(
                readerState,
                metadataStore: ProfileSettingsStore.services,
                preferenceStore: ProfileSettingsStore.active,
                context: "active profile"
            )
        }
#endif

        if appliesTopLevelPerProfileData, !backup.recommendationCache.isEmpty {
            RecommendationEngine.shared.restoreRecommendationCache(backup.recommendationCache)
        }

        if appliesTopLevelRatings, backup.hasUserRatings {
            UserRatingManager.shared.restoreRatingsAndNotes(
                ratings: BackupData.sanitizedUserRatings(backup.userRatings),
                notes: BackupData.sanitizedUserRatingNotes(backup.userRatingNotes)
            )
        }

        if appliesTopLevelSources, let servicesSettings = backup.servicesSettings {
            let store = ProfileSettingsStore.services
            Self.restoreServicesSettings(
                servicesSettings,
                capturedCompletely: backup.servicesSettingsWereCaptured,
                to: store,
                preserving: refreshCloudSources ? preservedLocalSourceIDs : []
            )
        }

        restoreSharedSourcePayloads(backup)

        let privateConfigurationRestore = restoreProfileSnapshots(
            backup,
            preservingCanonicalMediaState: preservingCanonicalMediaState,
            preservingDeviceLocalNuvioCloudState: refreshCloudSources
        )
        guard privateConfigurationRestore.wasRestored else {
            Logger.shared.log(
                "BackupManager: private cloud configuration did not persist durably; restore requires rollback",
                type: "CloudSync"
            )
            return nil
        }

        guard ProfileManager.shared.rosterStoreIsReadable else {
            Logger.shared.log(
                "BackupManager: restore did not contain a valid profile roster; the unreadable local roster remains quarantined",
                type: "Error"
            )
            return nil
        }

#if os(iOS)
        Task { @MainActor in
            await LocalNotificationManager.shared.reloadPersistedSelectionsAfterRestore()
        }
#endif

        Logger.shared.log("Backup restored successfully", type: "Info")
        return BackupApplicationResult(
            authoritativeTrackerProfileIDs:
                privateConfigurationRestore.authoritativeTrackerProfileIDs
        )
    }

    static let maximumProfileNameUTF8Bytes = ProfileManager.maximumNameUTF8Bytes
    static let maximumProfileAvatarSymbolUTF8Bytes = ProfileManager.maximumAvatarSymbolUTF8Bytes

    static func sanitizedProfileSnapshotForRestore(
        _ source: BackupProfileSnapshot,
        now: Date = Date()
    ) -> BackupProfileSnapshot? {
        var snapshot = source
        guard let name = ProfileManager.sanitizedName(source.name) else { return nil }
        snapshot.name = name
        snapshot.avatarSymbol = ProfileManager.sanitizedAvatarSymbol(source.avatarSymbol)
        snapshot.avatarColorHex = ProfileManager.sanitizedAvatarColorHex(source.avatarColorHex)
        if snapshot.avatarPhotoData?.isEmpty == true
            || (snapshot.avatarPhotoData?.count ?? 0) > ProfileAvatar.maximumPhotoBytes {
            snapshot.avatarPhotoData = nil
        }

        let sanitizedPINHash = ProfilePINHasher.sanitizedHash(source.pinHash)
        snapshot.pinHash = sanitizedPINHash
        snapshot.createdAt = sanitizedRequiredProfileClock(source.createdAt, now: now)
        snapshot.pinChangedAt = sanitizedPINHash == nil && source.pinHash != nil
            ? nil
            : sanitizedOptionalProfileClock(source.pinChangedAt, now: now)
        snapshot.kidsFlagChangedAt = sanitizedOptionalProfileClock(
            source.kidsFlagChangedAt,
            now: now
        )
        snapshot.readerExtensionsState = (
            source.readerExtensionsState
                ?? source.aidokuState.map(BackupReaderExtensionState.migratingLegacyAidoku)
        )?.sanitized()
        snapshot.readerPrivateCloudConfigurationData = BackupProfileSnapshot
            .boundedReaderPrivateCloudConfigurationData(
                source.readerPrivateCloudConfigurationData
            )
        snapshot.aidokuState = nil
        snapshot.servicesSettings = BackupData.servicesSettingsForExperimentalCloudSync(
            source.servicesSettings
        ) ?? [:]
        return snapshot
    }

    private static func sanitizedRequiredProfileClock(_ value: Date, now: Date) -> Date {
        let seconds = value.timeIntervalSince1970
        let maximum = now.timeIntervalSince1970
            + MediaStateEnvelopeValidator.maximumFutureClockSkew
        guard seconds.isFinite else { return now }
        if seconds < 0 { return Date(timeIntervalSince1970: 0) }
        if seconds > maximum { return now }
        return value
    }

    private static func sanitizedOptionalProfileClock(_ value: Date?, now: Date) -> Date? {
        guard let value else { return nil }
        let seconds = value.timeIntervalSince1970
        let maximum = now.timeIntervalSince1970
            + MediaStateEnvelopeValidator.maximumFutureClockSkew
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds > maximum ? now : value
    }

    static func profileSnapshotsAdmittedForRestore(
        _ snapshots: [BackupProfileSnapshot],
        existingProfileIDs: Set<UUID>,
        admittingUnrosteredPrivateConfiguration: Bool = false
    ) -> [BackupProfileSnapshot] {
        var seenIDs = Set<UUID>()
        var candidates: [BackupProfileSnapshot] = []
        candidates.reserveCapacity(min(snapshots.count, ProfileManager.maximumProfiles))

        let now = Date()
        for rawSnapshot in snapshots {
            guard let snapshot = sanitizedProfileSnapshotForRestore(rawSnapshot, now: now),
                  seenIDs.insert(snapshot.id).inserted else { continue }
            candidates.append(snapshot)
        }

        let existingCandidateIDs = Set(
            candidates.lazy
                .filter { existingProfileIDs.contains($0.id) }
                .prefix(ProfileManager.maximumProfiles)
                .map(\.id)
        )
        let newcomerCapacity = max(
            0,
            ProfileManager.maximumProfiles - (
                admittingUnrosteredPrivateConfiguration
                    ? existingCandidateIDs.count
                    : existingProfileIDs.count
            )
        )
        var admittedNewcomers = 0
        var admitted: [BackupProfileSnapshot] = []
        admitted.reserveCapacity(min(candidates.count, ProfileManager.maximumProfiles))
        for snapshot in candidates {
            if existingCandidateIDs.contains(snapshot.id) {
                admitted.append(snapshot)
            } else if admittedNewcomers < newcomerCapacity {
                admittedNewcomers += 1
                admitted.append(snapshot)
            }
        }
        return admitted
    }

    private func restoreProfileSnapshots(
        _ backup: BackupData,
        preservingCanonicalMediaState: Bool = false,
        preservingDeviceLocalNuvioCloudState: Bool = false
    ) -> PrivateConfigurationRestoreResult {
        guard let snapshots = backup.profiles, !snapshots.isEmpty else {
            if let owner = backup.activeProfileID,
               owner != ProfileManager.shared.activeProfileID {
                Logger.shared.log(
                    "BackupManager: this backup holds a single profile (\(owner)) and was restored into \(ProfileManager.shared.activeProfileID)",
                    type: "Info"
                )
            }
            return PrivateConfigurationRestoreResult(
                wasRestored: true,
                authoritativeTrackerProfileIDs: []
            )
        }
        var existingProfileIDs = Set<UUID>()
        performOnMainThread {
            let manager = ProfileManager.shared

            existingProfileIDs = manager.rosterStoreIsReadable
                ? Set(manager.profiles.map(\.id))
                : []
        }
        let admittedSnapshots = Self.profileSnapshotsAdmittedForRestore(
            snapshots,
            existingProfileIDs: existingProfileIDs,
            admittingUnrosteredPrivateConfiguration: preservingCanonicalMediaState
        )
        if admittedSnapshots.count != snapshots.count {
            Logger.shared.log(
                "BackupManager: admitted \(admittedSnapshots.count) of \(snapshots.count) unique, valid profile snapshot(s) within the roster cap",
                type: "Error"
            )
        }

        var acceptedProfileIDs = Set<UUID>()
        if preservingCanonicalMediaState {
            acceptedProfileIDs = Set(admittedSnapshots.map(\.id))
        } else {
            performOnMainThread {

                acceptedProfileIDs = ProfileManager.shared.mergeProfilesFromBackup(
                admittedSnapshots.map {
                    Profile(
                        id: $0.id,
                        name: $0.name,
                        avatarSymbol: $0.avatarSymbol,
                        avatarColorHex: $0.avatarColorHex,
                        avatarPhotoData: $0.avatarPhotoData,
                        pinHash: $0.pinHash,
                        isKidsProfile: $0.isKidsProfile,
                        createdAt: $0.createdAt,
                        pinChangedAt: $0.pinChangedAt,
                        kidsFlagChangedAt: $0.kidsFlagChangedAt
                    )
                }
                )

            }
        }

        var privateConfigurationWasRestored = true
        var authoritativeTrackerProfileIDs = Set<UUID>()
        for snapshot in admittedSnapshots {
            let id = snapshot.id
            let isUnrosteredCanonicalProfile = preservingCanonicalMediaState
                && !existingProfileIDs.contains(id)
            guard acceptedProfileIDs.contains(id) else {
                Logger.shared.log(
                    "BackupManager: skipped profile \(id)'s data; the roster merge did not admit it",
                    type: "Error"
                )
                continue
            }

            if !preservingCanonicalMediaState, snapshot.progressWasCaptured {
                ProgressManager.shared.applyRestoredProgressData(
                    BackupData.sanitizedProgressData(
                        snapshot.progressData,
                        preservingDeviceLocalReferences: true
                    ),
                    forProfile: id
                )
            }
            if !preservingCanonicalMediaState, snapshot.ratingsWereCaptured {
                UserRatingManager.shared.restoreRatingsAndNotes(
                    ratings: BackupData.sanitizedUserRatings(snapshot.userRatings),
                    notes: BackupData.sanitizedUserRatingNotes(snapshot.userRatingNotes),
                    forProfile: id
                )
            }
            if !preservingCanonicalMediaState, snapshot.collectionsWereCaptured {
                performOnMainThread {
                    LibraryManager.shared.replaceCollectionsForMediaState(
                        snapshot.collections.map { $0.toLibraryCollection() },
                        forProfile: id
                    )
                }
            }
            if !snapshot.progressWasCaptured
                || !snapshot.ratingsWereCaptured
                || !snapshot.collectionsWereCaptured
                || !snapshot.catalogsWereCaptured
                || !snapshot.mangaCollectionsWereCaptured
                || !snapshot.mangaReadingProgressWasCaptured
                || !snapshot.mangaCatalogsWereCaptured
                || !snapshot.customCatalogsWereCaptured {
                Logger.shared.log(
                    "BackupManager: profile \(id) restored without unreadable domains (progress=\(snapshot.progressWasCaptured) ratings=\(snapshot.ratingsWereCaptured) collections=\(snapshot.collectionsWereCaptured) catalogs=\(snapshot.catalogsWereCaptured) readerLibrary=\(snapshot.mangaCollectionsWereCaptured) readerProgress=\(snapshot.mangaReadingProgressWasCaptured) readerCatalogs=\(snapshot.mangaCatalogsWereCaptured) readerCustomCatalogs=\(snapshot.customCatalogsWereCaptured)); the destination keeps its own copy",
                    type: "Info"
                )
            }
            if !preservingCanonicalMediaState,
               snapshot.catalogsWereCaptured {
                CatalogManager.shared.replaceCatalogsForMediaState(snapshot.catalogs, forProfile: id)
            }
            if snapshot.trackerStateWasCaptured,
               (!isUnrosteredCanonicalProfile
                || snapshot.trackerCredentialsAndRosterWereCaptured) {
                var trackerStateWasRestored = false
                performOnMainThread {
                    trackerStateWasRestored = TrackerManager.shared.applyRestoredTrackerState(
                        snapshot.trackerState,
                        forProfile: id,
                        credentialsAndRosterAreAuthoritative:
                            snapshot.trackerCredentialsAndRosterWereCaptured,
                        permitsUnrosteredProfile: isUnrosteredCanonicalProfile
                    )
                }
                if snapshot.trackerCredentialsAndRosterWereCaptured,
                   !trackerStateWasRestored {
                    privateConfigurationWasRestored = false
                } else if snapshot.trackerCredentialsAndRosterWereCaptured,
                          trackerStateWasRestored {
                    authoritativeTrackerProfileIDs.insert(id)
                }
            }

            let store = ProfileSettingsStore.shared.store(for: id)

            if isUnrosteredCanonicalProfile {
                if snapshot.readerPrivateCloudConfigurationData != nil {
                    privateConfigurationWasRestored = restoreProfileReaderConfiguration(
                        snapshot,
                        into: store,
                        profileID: id,
                        permitsUnrosteredProfile: true
                    ) && privateConfigurationWasRestored
                }
                continue
            }

            if snapshot.searchHistory.wasCaptured || !snapshot.searchHistory.queries.isEmpty,
               let searchHistoryData = try? JSONEncoder().encode(snapshot.searchHistory.queries) {
                store.set(searchHistoryData, forKey: "searchHistory")
            }
            let preservesNuvioStateForThisDestination = preservingDeviceLocalNuvioCloudState
                && existingProfileIDs.contains(id)
                && (!ProfileSettingsStore.sharesServices
                    || id == ProfileManager.defaultProfileID)
            let readerConfigurationWasRestored = restoreProfileSources(
                snapshot,
                into: store,
                profileID: id,
                preservingDeviceLocalNuvioCloudState: preservesNuvioStateForThisDestination
            )
            if snapshot.readerPrivateCloudConfigurationData != nil,
               !readerConfigurationWasRestored {
                privateConfigurationWasRestored = false
            }

            var appliedSettingCount = 0
            for (key, data) in snapshot.settings where Self.carriesProfileScopedSetting(key) {
                if preservingCanonicalMediaState,
                   MediaStateSettingRegistry.scope(for: key) != nil {
                    continue
                }
                guard appliedSettingCount < Self.maximumProfileSettingKeys else { break }
                guard let value = Self.validatedBackupSettingValue(
                    from: data,
                    forKey: key
                ) else { continue }
                store.set(value, forKey: key)
                appliedSettingCount += 1
            }
#if !os(tvOS)
            performOnMainThread {
                if snapshot.mangaCollectionsWereCaptured {
                    MangaLibraryManager.shared.applyRestoredCollections(
                        snapshot.mangaCollections.map {
                            MangaLibraryCollection(
                                id: $0.id,
                                name: $0.name,
                                items: $0.items,
                                description: $0.description
                            )
                        },
                        forProfile: id
                    )
                }
                if snapshot.mangaReadingProgressWasCaptured {
                    MangaReadingProgressManager.shared.applyRestoredProgress(
                        snapshot.mangaReadingProgress.reduce(into: [Int: MangaProgress]()) { result, entry in
                            guard let key = Int(entry.key) else { return }
                            result[key] = entry.value
                        },
                        forProfile: id
                    )
                }
                if snapshot.mangaCatalogsWereCaptured {
                    MangaCatalogManager.shared.applyRestoredCatalogs(snapshot.mangaCatalogs, forProfile: id)
                }
                if snapshot.customCatalogsWereCaptured {
                    KanzenCustomCatalogManager.shared.applyRestoredCatalogs(
                        snapshot.customCatalogs,
                        forProfile: id
                    )
                }
            }
#endif
        }
        Logger.shared.log(
            "BackupManager: restored \(admittedSnapshots.filter { acceptedProfileIDs.contains($0.id) }.count) of \(snapshots.count) profiles from the backup",
            type: "Info"
        )
        return PrivateConfigurationRestoreResult(
            wasRestored: privateConfigurationWasRestored,
            authoritativeTrackerProfileIDs: authoritativeTrackerProfileIDs
        )
    }
}
