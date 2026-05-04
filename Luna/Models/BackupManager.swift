//
//  BackupManager.swift
//  Luna
//
//  Created by Soupy-dev on 05/01/2026.
//

import Foundation
import UIKit

// MARK: - Backup Data Model

struct BackupData: Codable {
    let version: String
    let createdDate: Date
    
    // Settings
    var accentColor: Data?
    var tmdbLanguage: String
    var selectedAppearance: String
    var enableSubtitlesByDefault: Bool
    var defaultSubtitleLanguage: String
    var enableVLCSubtitleEditMenu: Bool

    var preferredAnimeAudioLanguage: String
    var inAppPlayer: String
    var showScheduleTab: Bool
    var showLocalScheduleTime: Bool

    // Player Settings
    var defaultPlaybackSpeed: Double = 1.0
    var holdSpeedPlayer: Double = 2.0
    var externalPlayer: String = "none"
    var alwaysLandscape: Bool = false
    var aniSkipAutoSkip: Bool = false
    var skip85sEnabled: Bool = false
    var showNextEpisodeButton: Bool = true
    var nextEpisodeThreshold: Double = 0.90
    var vlcHeaderProxyEnabled: Bool = true
    var vlcBrightnessGestureEnabled: Bool = false
    var vlcVolumeGestureEnabled: Bool = false
    var playerTwoFingerTapPlayPauseEnabled: Bool = true
    var vlcDoubleTapSeekEnabled: Bool = true
    var vlcDoubleTapSeekSeconds: Double = 10.0
    var vlcPiPEnabled: Bool = true
    var vlcOpenSubtitlesEnabled: Bool = false
    var vlcOpenSubtitlesAutoFallbackEnabled: Bool = true

    // Subtitle Styling
    var subtitleForegroundColor: Data?
    var subtitleStrokeColor: Data?
    var subtitleStrokeWidth: Double = 1.0
    var subtitleFontSize: Double = 30.0
    var subtitleVerticalOffset: Double = -6.0

    // UI Preferences
    var showKanzen: Bool = false
    var kanzenAutoMode: Bool = false
    var kanzenAutoUpdateModules: Bool = true
    var seasonMenu: Bool = false
    var horizontalEpisodeList: Bool = false
    var useClassicScheduleUI: Bool = false
    var mediaColumnsPortrait: Int = 3
    var mediaColumnsLandscape: Int = 5

    // Manga / Reader
    var readingMode: Int = 2

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

    // Recommendations
    var recommendationCache: [TMDBSearchResult] = []

    // User Ratings
    var userRatings: [String: Int] = [:]
    var userRatingNotes: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case version, createdDate
        case accentColor, tmdbLanguage, selectedAppearance, enableSubtitlesByDefault, defaultSubtitleLanguage, enableVLCSubtitleEditMenu, preferredAnimeAudioLanguage, inAppPlayer, playerChoice, showScheduleTab, showLocalScheduleTime
        case defaultPlaybackSpeed, holdSpeedPlayer, externalPlayer, alwaysLandscape, aniSkipAutoSkip, skip85sEnabled, showNextEpisodeButton, nextEpisodeThreshold, vlcHeaderProxyEnabled
        case vlcBrightnessGestureEnabled, vlcVolumeGestureEnabled, playerTwoFingerTapPlayPauseEnabled, vlcDoubleTapSeekEnabled, vlcDoubleTapSeekSeconds, vlcPiPEnabled, vlcOpenSubtitlesEnabled, vlcOpenSubtitlesAutoFallbackEnabled
        case subtitleForegroundColor, subtitleStrokeColor, subtitleStrokeWidth, subtitleFontSize, subtitleVerticalOffset
        case showKanzen, kanzenAutoMode, kanzenAutoUpdateModules, seasonMenu, horizontalEpisodeList, useClassicScheduleUI, mediaColumnsPortrait, mediaColumnsLandscape
        case readingMode
        case readerFontSize, readerFontFamily, readerFontWeight, readerColorPreset, readerTextAlignment, readerLineSpacing, readerMargin
        case autoClearCacheEnabled, autoClearCacheThresholdMB, highQualityThreshold
        case collections, progressData, trackerState, catalogs, services, stremioAddons
        case mangaCollections, mangaReadingProgress, mangaCatalogs, kanzenModules
        case recommendationCache
        case userRatings, userRatingNotes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        accentColor = try container.decodeIfPresent(Data.self, forKey: .accentColor)
        tmdbLanguage = try container.decodeIfPresent(String.self, forKey: .tmdbLanguage) ?? "en-US"
        selectedAppearance = try container.decodeIfPresent(String.self, forKey: .selectedAppearance) ?? "system"
        enableSubtitlesByDefault = try container.decodeIfPresent(Bool.self, forKey: .enableSubtitlesByDefault) ?? false
        defaultSubtitleLanguage = try container.decodeIfPresent(String.self, forKey: .defaultSubtitleLanguage) ?? "eng"
        enableVLCSubtitleEditMenu = try container.decodeIfPresent(Bool.self, forKey: .enableVLCSubtitleEditMenu) ?? false

        preferredAnimeAudioLanguage = try container.decodeIfPresent(String.self, forKey: .preferredAnimeAudioLanguage) ?? "jpn"
        // Support both new "inAppPlayer" key and legacy "playerChoice" key
        inAppPlayer = try container.decodeIfPresent(String.self, forKey: .inAppPlayer)
            ?? container.decodeIfPresent(String.self, forKey: .playerChoice)
            ?? "VLC"
        showScheduleTab = try container.decodeIfPresent(Bool.self, forKey: .showScheduleTab) ?? true
        showLocalScheduleTime = try container.decodeIfPresent(Bool.self, forKey: .showLocalScheduleTime) ?? true

        // Player settings
        defaultPlaybackSpeed = try container.decodeIfPresent(Double.self, forKey: .defaultPlaybackSpeed) ?? 1.0
        holdSpeedPlayer = try container.decodeIfPresent(Double.self, forKey: .holdSpeedPlayer) ?? 2.0
        externalPlayer = try container.decodeIfPresent(String.self, forKey: .externalPlayer) ?? "none"
        alwaysLandscape = try container.decodeIfPresent(Bool.self, forKey: .alwaysLandscape) ?? false
        aniSkipAutoSkip = try container.decodeIfPresent(Bool.self, forKey: .aniSkipAutoSkip) ?? false
        skip85sEnabled = try container.decodeIfPresent(Bool.self, forKey: .skip85sEnabled) ?? false
        showNextEpisodeButton = try container.decodeIfPresent(Bool.self, forKey: .showNextEpisodeButton) ?? true
        nextEpisodeThreshold = try container.decodeIfPresent(Double.self, forKey: .nextEpisodeThreshold) ?? 0.90
        vlcHeaderProxyEnabled = try container.decodeIfPresent(Bool.self, forKey: .vlcHeaderProxyEnabled) ?? true
        vlcBrightnessGestureEnabled = try container.decodeIfPresent(Bool.self, forKey: .vlcBrightnessGestureEnabled) ?? false
        vlcVolumeGestureEnabled = try container.decodeIfPresent(Bool.self, forKey: .vlcVolumeGestureEnabled) ?? false
        playerTwoFingerTapPlayPauseEnabled = try container.decodeIfPresent(Bool.self, forKey: .playerTwoFingerTapPlayPauseEnabled) ?? true
        vlcDoubleTapSeekEnabled = try container.decodeIfPresent(Bool.self, forKey: .vlcDoubleTapSeekEnabled) ?? true
        vlcDoubleTapSeekSeconds = try container.decodeIfPresent(Double.self, forKey: .vlcDoubleTapSeekSeconds) ?? 10.0
        vlcPiPEnabled = try container.decodeIfPresent(Bool.self, forKey: .vlcPiPEnabled) ?? true
        vlcOpenSubtitlesEnabled = try container.decodeIfPresent(Bool.self, forKey: .vlcOpenSubtitlesEnabled) ?? false
        vlcOpenSubtitlesAutoFallbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .vlcOpenSubtitlesAutoFallbackEnabled) ?? true

        // Subtitle styling
        subtitleForegroundColor = try container.decodeIfPresent(Data.self, forKey: .subtitleForegroundColor)
        subtitleStrokeColor = try container.decodeIfPresent(Data.self, forKey: .subtitleStrokeColor)
        subtitleStrokeWidth = try container.decodeIfPresent(Double.self, forKey: .subtitleStrokeWidth) ?? 1.0
        subtitleFontSize = try container.decodeIfPresent(Double.self, forKey: .subtitleFontSize) ?? 30.0
        subtitleVerticalOffset = try container.decodeIfPresent(Double.self, forKey: .subtitleVerticalOffset) ?? -6.0

        // UI preferences
        showKanzen = try container.decodeIfPresent(Bool.self, forKey: .showKanzen) ?? false
        kanzenAutoMode = try container.decodeIfPresent(Bool.self, forKey: .kanzenAutoMode) ?? false
        kanzenAutoUpdateModules = try container.decodeIfPresent(Bool.self, forKey: .kanzenAutoUpdateModules) ?? true
        seasonMenu = try container.decodeIfPresent(Bool.self, forKey: .seasonMenu) ?? false
        horizontalEpisodeList = try container.decodeIfPresent(Bool.self, forKey: .horizontalEpisodeList) ?? false
        useClassicScheduleUI = try container.decodeIfPresent(Bool.self, forKey: .useClassicScheduleUI) ?? false
        mediaColumnsPortrait = try container.decodeIfPresent(Int.self, forKey: .mediaColumnsPortrait) ?? 3
        mediaColumnsLandscape = try container.decodeIfPresent(Int.self, forKey: .mediaColumnsLandscape) ?? 5

        // Manga / Reader
        readingMode = try container.decodeIfPresent(Int.self, forKey: .readingMode) ?? 2

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
        recommendationCache = try container.decodeIfPresent([TMDBSearchResult].self, forKey: .recommendationCache) ?? []
        userRatings = try container.decodeIfPresent([String: Int].self, forKey: .userRatings) ?? [:]
        userRatingNotes = try container.decodeIfPresent([String: String].self, forKey: .userRatingNotes) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(createdDate, forKey: .createdDate)
        try container.encodeIfPresent(accentColor, forKey: .accentColor)
        try container.encode(tmdbLanguage, forKey: .tmdbLanguage)
        try container.encode(selectedAppearance, forKey: .selectedAppearance)
        try container.encode(enableSubtitlesByDefault, forKey: .enableSubtitlesByDefault)
        try container.encode(defaultSubtitleLanguage, forKey: .defaultSubtitleLanguage)
        try container.encode(enableVLCSubtitleEditMenu, forKey: .enableVLCSubtitleEditMenu)

        try container.encode(preferredAnimeAudioLanguage, forKey: .preferredAnimeAudioLanguage)
        try container.encode(inAppPlayer, forKey: .inAppPlayer)
        try container.encode(showScheduleTab, forKey: .showScheduleTab)
        try container.encode(showLocalScheduleTime, forKey: .showLocalScheduleTime)

        // Player settings
        try container.encode(defaultPlaybackSpeed, forKey: .defaultPlaybackSpeed)
        try container.encode(holdSpeedPlayer, forKey: .holdSpeedPlayer)
        try container.encode(externalPlayer, forKey: .externalPlayer)
        try container.encode(alwaysLandscape, forKey: .alwaysLandscape)
        try container.encode(aniSkipAutoSkip, forKey: .aniSkipAutoSkip)
        try container.encode(skip85sEnabled, forKey: .skip85sEnabled)
        try container.encode(showNextEpisodeButton, forKey: .showNextEpisodeButton)
        try container.encode(nextEpisodeThreshold, forKey: .nextEpisodeThreshold)
        try container.encode(vlcHeaderProxyEnabled, forKey: .vlcHeaderProxyEnabled)
        try container.encode(vlcBrightnessGestureEnabled, forKey: .vlcBrightnessGestureEnabled)
        try container.encode(vlcVolumeGestureEnabled, forKey: .vlcVolumeGestureEnabled)
        try container.encode(playerTwoFingerTapPlayPauseEnabled, forKey: .playerTwoFingerTapPlayPauseEnabled)
        try container.encode(vlcDoubleTapSeekEnabled, forKey: .vlcDoubleTapSeekEnabled)
        try container.encode(vlcDoubleTapSeekSeconds, forKey: .vlcDoubleTapSeekSeconds)
        try container.encode(vlcPiPEnabled, forKey: .vlcPiPEnabled)
        try container.encode(vlcOpenSubtitlesEnabled, forKey: .vlcOpenSubtitlesEnabled)
        try container.encode(vlcOpenSubtitlesAutoFallbackEnabled, forKey: .vlcOpenSubtitlesAutoFallbackEnabled)

        // Subtitle styling
        try container.encodeIfPresent(subtitleForegroundColor, forKey: .subtitleForegroundColor)
        try container.encodeIfPresent(subtitleStrokeColor, forKey: .subtitleStrokeColor)
        try container.encode(subtitleStrokeWidth, forKey: .subtitleStrokeWidth)
        try container.encode(subtitleFontSize, forKey: .subtitleFontSize)
        try container.encode(subtitleVerticalOffset, forKey: .subtitleVerticalOffset)

        // UI preferences
        try container.encode(showKanzen, forKey: .showKanzen)
        try container.encode(kanzenAutoMode, forKey: .kanzenAutoMode)
        try container.encode(kanzenAutoUpdateModules, forKey: .kanzenAutoUpdateModules)
        try container.encode(seasonMenu, forKey: .seasonMenu)
        try container.encode(horizontalEpisodeList, forKey: .horizontalEpisodeList)
        try container.encode(useClassicScheduleUI, forKey: .useClassicScheduleUI)
        try container.encode(mediaColumnsPortrait, forKey: .mediaColumnsPortrait)
        try container.encode(mediaColumnsLandscape, forKey: .mediaColumnsLandscape)

        // Manga / Reader
        try container.encode(readingMode, forKey: .readingMode)

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
        try container.encode(recommendationCache, forKey: .recommendationCache)
        try container.encode(userRatings, forKey: .userRatings)
        try container.encode(userRatingNotes, forKey: .userRatingNotes)
    }
    
    init(
        version: String = "1.0",
        createdDate: Date,
        accentColor: Data? = nil,
        tmdbLanguage: String,
        selectedAppearance: String,
        enableSubtitlesByDefault: Bool,
        defaultSubtitleLanguage: String,
        enableVLCSubtitleEditMenu: Bool,

        preferredAnimeAudioLanguage: String,
        inAppPlayer: String,
        showScheduleTab: Bool,
        showLocalScheduleTime: Bool,

        // Player settings
        defaultPlaybackSpeed: Double = 1.0,
        holdSpeedPlayer: Double = 2.0,
        externalPlayer: String = "none",
        alwaysLandscape: Bool = false,
        aniSkipAutoSkip: Bool = false,
        skip85sEnabled: Bool = false,
        showNextEpisodeButton: Bool = true,
        nextEpisodeThreshold: Double = 0.90,
        vlcHeaderProxyEnabled: Bool = true,
        vlcBrightnessGestureEnabled: Bool = false,
        vlcVolumeGestureEnabled: Bool = false,
        playerTwoFingerTapPlayPauseEnabled: Bool = true,
        vlcDoubleTapSeekEnabled: Bool = true,
        vlcDoubleTapSeekSeconds: Double = 10.0,
        vlcPiPEnabled: Bool = true,
        vlcOpenSubtitlesEnabled: Bool = false,
        vlcOpenSubtitlesAutoFallbackEnabled: Bool = true,

        // Subtitle styling
        subtitleForegroundColor: Data? = nil,
        subtitleStrokeColor: Data? = nil,
        subtitleStrokeWidth: Double = 1.0,
        subtitleFontSize: Double = 30.0,
        subtitleVerticalOffset: Double = -6.0,

        // UI preferences
        showKanzen: Bool = false,
        kanzenAutoMode: Bool = false,
        kanzenAutoUpdateModules: Bool = true,
        seasonMenu: Bool = false,
        horizontalEpisodeList: Bool = false,
        useClassicScheduleUI: Bool = false,
        mediaColumnsPortrait: Int = 3,
        mediaColumnsLandscape: Int = 5,

        // Manga / Reader
        readingMode: Int = 2,

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
        recommendationCache: [TMDBSearchResult] = [],
        userRatings: [String: Int] = [:],
        userRatingNotes: [String: String] = [:]
    ) {
        self.version = version
        self.createdDate = createdDate
        self.accentColor = accentColor
        self.tmdbLanguage = tmdbLanguage
        self.selectedAppearance = selectedAppearance
        self.enableSubtitlesByDefault = enableSubtitlesByDefault
        self.defaultSubtitleLanguage = defaultSubtitleLanguage
        self.enableVLCSubtitleEditMenu = enableVLCSubtitleEditMenu

        self.preferredAnimeAudioLanguage = preferredAnimeAudioLanguage
        self.inAppPlayer = inAppPlayer
        self.showScheduleTab = showScheduleTab
        self.showLocalScheduleTime = showLocalScheduleTime

        self.defaultPlaybackSpeed = defaultPlaybackSpeed
        self.holdSpeedPlayer = holdSpeedPlayer
        self.externalPlayer = externalPlayer
        self.alwaysLandscape = alwaysLandscape
        self.aniSkipAutoSkip = aniSkipAutoSkip
        self.skip85sEnabled = skip85sEnabled
        self.showNextEpisodeButton = showNextEpisodeButton
        self.nextEpisodeThreshold = nextEpisodeThreshold
        self.vlcHeaderProxyEnabled = vlcHeaderProxyEnabled
        self.vlcBrightnessGestureEnabled = vlcBrightnessGestureEnabled
        self.vlcVolumeGestureEnabled = vlcVolumeGestureEnabled
        self.playerTwoFingerTapPlayPauseEnabled = playerTwoFingerTapPlayPauseEnabled
        self.vlcDoubleTapSeekEnabled = vlcDoubleTapSeekEnabled
        self.vlcDoubleTapSeekSeconds = vlcDoubleTapSeekSeconds
        self.vlcPiPEnabled = vlcPiPEnabled
        self.vlcOpenSubtitlesEnabled = vlcOpenSubtitlesEnabled
        self.vlcOpenSubtitlesAutoFallbackEnabled = vlcOpenSubtitlesAutoFallbackEnabled

        self.subtitleForegroundColor = subtitleForegroundColor
        self.subtitleStrokeColor = subtitleStrokeColor
        self.subtitleStrokeWidth = subtitleStrokeWidth
        self.subtitleFontSize = subtitleFontSize
        self.subtitleVerticalOffset = subtitleVerticalOffset

        self.showKanzen = showKanzen
        self.kanzenAutoMode = kanzenAutoMode
        self.kanzenAutoUpdateModules = kanzenAutoUpdateModules
        self.seasonMenu = seasonMenu
        self.horizontalEpisodeList = horizontalEpisodeList
        self.useClassicScheduleUI = useClassicScheduleUI
        self.mediaColumnsPortrait = mediaColumnsPortrait
        self.mediaColumnsLandscape = mediaColumnsLandscape

        self.readingMode = readingMode

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
        self.recommendationCache = recommendationCache
        self.userRatings = userRatings
        self.userRatingNotes = userRatingNotes
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
    
    /// Gathers all user data for backup
    private func gatherBackupData() -> BackupData {
        let userDefaults = UserDefaults.standard
        
        // Get accent color
        var accentColorData: Data?
        if let colorData = userDefaults.data(forKey: "accentColor") {
            accentColorData = colorData
        }
        
        // Get settings
        let selectedAppearance = userDefaults.string(forKey: "selectedAppearance") ?? "system"
        let enableSubtitlesByDefault = userDefaults.bool(forKey: "enableSubtitlesByDefault")
        let defaultSubtitleLanguage = userDefaults.string(forKey: "defaultSubtitleLanguage") ?? "eng"
        let enableVLCSubtitleEditMenu = userDefaults.bool(forKey: "enableVLCSubtitleEditMenu")

        let preferredAnimeAudioLanguage = userDefaults.string(forKey: "preferredAnimeAudioLanguage") ?? "jpn"
        let inAppPlayer = userDefaults.string(forKey: "inAppPlayer") ?? "VLC"
        let tmdbLanguage = userDefaults.string(forKey: "tmdbLanguage") ?? "en-US"
        let showScheduleTab = userDefaults.bool(forKey: "showScheduleTab")
        let showLocalScheduleTime = userDefaults.bool(forKey: "showLocalScheduleTime")
        
        // Player settings
        let savedDefaultPlaybackSpeed = userDefaults.double(forKey: "defaultPlaybackSpeed")
        let defaultPlaybackSpeed = savedDefaultPlaybackSpeed > 0 ? savedDefaultPlaybackSpeed : 1.0
        let savedHoldSpeed = userDefaults.double(forKey: "holdSpeedPlayer")
        let holdSpeedPlayer = savedHoldSpeed > 0 ? savedHoldSpeed : 2.0
        let externalPlayer = userDefaults.string(forKey: "externalPlayer") ?? "none"
        let alwaysLandscape = userDefaults.bool(forKey: "alwaysLandscape")
        let aniSkipAutoSkip = userDefaults.bool(forKey: "aniSkipAutoSkip")
        let skip85sEnabled = userDefaults.bool(forKey: "skip85sEnabled")
        let showNextEpisodeButton = userDefaults.object(forKey: "showNextEpisodeButton") == nil ? true : userDefaults.bool(forKey: "showNextEpisodeButton")
        let savedNextThreshold = userDefaults.double(forKey: "nextEpisodeThreshold")
        let nextEpisodeThreshold = savedNextThreshold > 0 ? savedNextThreshold : 0.90
        let vlcHeaderProxyEnabled = userDefaults.object(forKey: "vlcHeaderProxyEnabled") as? Bool ?? true
        let vlcBrightnessGestureEnabled = userDefaults.bool(forKey: "vlcBrightnessGestureEnabled")
        let vlcVolumeGestureEnabled = userDefaults.bool(forKey: "vlcVolumeGestureEnabled")
        let playerTwoFingerTapPlayPauseEnabled: Bool
        if userDefaults.object(forKey: "playerTwoFingerTapPlayPauseEnabled") == nil {
            playerTwoFingerTapPlayPauseEnabled = userDefaults.object(forKey: "mpvTwoFingerTapEnabled") as? Bool ?? true
        } else {
            playerTwoFingerTapPlayPauseEnabled = userDefaults.bool(forKey: "playerTwoFingerTapPlayPauseEnabled")
        }
        let vlcDoubleTapSeekEnabled = userDefaults.object(forKey: "vlcDoubleTapSeekEnabled") == nil ? true : userDefaults.bool(forKey: "vlcDoubleTapSeekEnabled")
        let savedDoubleTapSeekSeconds = userDefaults.double(forKey: "vlcDoubleTapSeekSeconds")
        let vlcDoubleTapSeekSeconds = savedDoubleTapSeekSeconds > 0 ? savedDoubleTapSeekSeconds : 10.0
        let vlcPiPEnabled = userDefaults.object(forKey: "vlcPiPEnabled") == nil ? true : userDefaults.bool(forKey: "vlcPiPEnabled")
        let vlcOpenSubtitlesEnabled = userDefaults.bool(forKey: "vlcOpenSubtitlesEnabled")
        let vlcOpenSubtitlesAutoFallbackEnabled = userDefaults.object(forKey: "vlcOpenSubtitlesAutoFallbackEnabled") == nil ? true : userDefaults.bool(forKey: "vlcOpenSubtitlesAutoFallbackEnabled")

        // Subtitle styling
        let subtitleForegroundColor = userDefaults.data(forKey: "subtitles_foregroundColor")
        let subtitleStrokeColor = userDefaults.data(forKey: "subtitles_strokeColor")
        let savedStrokeWidth = userDefaults.double(forKey: "subtitles_strokeWidth")
        let subtitleStrokeWidth = savedStrokeWidth >= 0 ? savedStrokeWidth : 1.0
        let savedFontSize = userDefaults.double(forKey: "subtitles_fontSize")
        let subtitleFontSize = savedFontSize > 0 ? savedFontSize : 30.0
        let subtitleVerticalOffset = userDefaults.object(forKey: "vlcSubtitleOverlayBottomConstant") != nil
            ? userDefaults.double(forKey: "vlcSubtitleOverlayBottomConstant") : -6.0

        // UI preferences
        let showKanzen = userDefaults.bool(forKey: "showKanzen")
        let kanzenAutoMode = userDefaults.bool(forKey: "kanzenAutoMode")
        let kanzenAutoUpdateModules = ModuleManager.isAutoUpdateEnabled
        let seasonMenu = userDefaults.bool(forKey: "seasonMenu")
        let horizontalEpisodeList = userDefaults.bool(forKey: "horizontalEpisodeList")
        let useClassicScheduleUI = userDefaults.bool(forKey: "useClassicScheduleUI")
        let mediaColumnsPortrait = userDefaults.object(forKey: "mediaColumnsPortrait") != nil ? userDefaults.integer(forKey: "mediaColumnsPortrait") : 3
        let mediaColumnsLandscape = userDefaults.object(forKey: "mediaColumnsLandscape") != nil ? userDefaults.integer(forKey: "mediaColumnsLandscape") : 5

        // Manga / Reader
        let readingMode = userDefaults.object(forKey: "readingMode") != nil ? userDefaults.integer(forKey: "readingMode") : ReadingMode.WEBTOON.rawValue

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
            trackerState = trackerManager.trackerState
        } else {
            trackerState = DispatchQueue.main.sync {
                trackerManager.trackerState
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
        
        let backup = BackupData(
            createdDate: Date(),
            accentColor: accentColorData,
            tmdbLanguage: tmdbLanguage,
            selectedAppearance: selectedAppearance,
            enableSubtitlesByDefault: enableSubtitlesByDefault,
            defaultSubtitleLanguage: defaultSubtitleLanguage,
            enableVLCSubtitleEditMenu: enableVLCSubtitleEditMenu,

            preferredAnimeAudioLanguage: preferredAnimeAudioLanguage,
            inAppPlayer: inAppPlayer,
            showScheduleTab: showScheduleTab,
            showLocalScheduleTime: showLocalScheduleTime,

            defaultPlaybackSpeed: defaultPlaybackSpeed,
            holdSpeedPlayer: holdSpeedPlayer,
            externalPlayer: externalPlayer,
            alwaysLandscape: alwaysLandscape,
            aniSkipAutoSkip: aniSkipAutoSkip,
            skip85sEnabled: skip85sEnabled,
            showNextEpisodeButton: showNextEpisodeButton,
            nextEpisodeThreshold: nextEpisodeThreshold,
            vlcHeaderProxyEnabled: vlcHeaderProxyEnabled,
            vlcBrightnessGestureEnabled: vlcBrightnessGestureEnabled,
            vlcVolumeGestureEnabled: vlcVolumeGestureEnabled,
            playerTwoFingerTapPlayPauseEnabled: playerTwoFingerTapPlayPauseEnabled,
            vlcDoubleTapSeekEnabled: vlcDoubleTapSeekEnabled,
            vlcDoubleTapSeekSeconds: vlcDoubleTapSeekSeconds,
            vlcPiPEnabled: vlcPiPEnabled,
            vlcOpenSubtitlesEnabled: vlcOpenSubtitlesEnabled,
            vlcOpenSubtitlesAutoFallbackEnabled: vlcOpenSubtitlesAutoFallbackEnabled,

            subtitleForegroundColor: subtitleForegroundColor,
            subtitleStrokeColor: subtitleStrokeColor,
            subtitleStrokeWidth: subtitleStrokeWidth,
            subtitleFontSize: subtitleFontSize,
            subtitleVerticalOffset: subtitleVerticalOffset,

            showKanzen: showKanzen,
            kanzenAutoMode: kanzenAutoMode,
            kanzenAutoUpdateModules: kanzenAutoUpdateModules,
            seasonMenu: seasonMenu,
            horizontalEpisodeList: horizontalEpisodeList,
            useClassicScheduleUI: useClassicScheduleUI,
            mediaColumnsPortrait: mediaColumnsPortrait,
            mediaColumnsLandscape: mediaColumnsLandscape,

            readingMode: readingMode,

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
            recommendationCache: RecommendationEngine.shared.getRecommendationCache(),
            userRatings: UserRatingManager.shared.getRatingsForBackup(),
            userRatingNotes: UserRatingManager.shared.getNotesForBackup()
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
        let accentColor = json["accentColor"] as? Data
        let tmdbLanguage = json["tmdbLanguage"] as? String ?? "en-US"
        let selectedAppearance = json["selectedAppearance"] as? String ?? "system"
        let enableSubtitlesByDefault = json["enableSubtitlesByDefault"] as? Bool ?? false
        let defaultSubtitleLanguage = json["defaultSubtitleLanguage"] as? String ?? "eng"
        let enableVLCSubtitleEditMenu = json["enableVLCSubtitleEditMenu"] as? Bool ?? false
        let preferredAnimeAudioLanguage = json["preferredAnimeAudioLanguage"] as? String ?? "jpn"
        let inAppPlayer = json["inAppPlayer"] as? String ?? json["playerChoice"] as? String ?? "VLC"
        let showScheduleTab = json["showScheduleTab"] as? Bool ?? true
        let showLocalScheduleTime = json["showLocalScheduleTime"] as? Bool ?? true

        // Player settings
        let defaultPlaybackSpeed = json["defaultPlaybackSpeed"] as? Double ?? 1.0
        let holdSpeedPlayer = json["holdSpeedPlayer"] as? Double ?? 2.0
        let externalPlayer = json["externalPlayer"] as? String ?? "none"
        let alwaysLandscape = json["alwaysLandscape"] as? Bool ?? false
        let aniSkipAutoSkip = json["aniSkipAutoSkip"] as? Bool ?? false
        let skip85sEnabled = json["skip85sEnabled"] as? Bool ?? false
        let showNextEpisodeButton = json["showNextEpisodeButton"] as? Bool ?? true
        let nextEpisodeThreshold = json["nextEpisodeThreshold"] as? Double ?? 0.90
        let vlcHeaderProxyEnabled = json["vlcHeaderProxyEnabled"] as? Bool ?? true
        let vlcBrightnessGestureEnabled = json["vlcBrightnessGestureEnabled"] as? Bool ?? false
        let vlcVolumeGestureEnabled = json["vlcVolumeGestureEnabled"] as? Bool ?? false
        let playerTwoFingerTapPlayPauseEnabled = json["playerTwoFingerTapPlayPauseEnabled"] as? Bool ?? true
        let vlcDoubleTapSeekEnabled = json["vlcDoubleTapSeekEnabled"] as? Bool ?? true
        let vlcDoubleTapSeekSeconds = json["vlcDoubleTapSeekSeconds"] as? Double ?? 10.0
        let vlcPiPEnabled = json["vlcPiPEnabled"] as? Bool ?? true
        let vlcOpenSubtitlesEnabled = json["vlcOpenSubtitlesEnabled"] as? Bool ?? false
        let vlcOpenSubtitlesAutoFallbackEnabled = json["vlcOpenSubtitlesAutoFallbackEnabled"] as? Bool ?? true

        // Subtitle styling
        let subtitleForegroundColor = json["subtitleForegroundColor"] as? Data
        let subtitleStrokeColor = json["subtitleStrokeColor"] as? Data
        let subtitleStrokeWidth = json["subtitleStrokeWidth"] as? Double ?? 1.0
        let subtitleFontSize = json["subtitleFontSize"] as? Double ?? 30.0
        let subtitleVerticalOffset = json["subtitleVerticalOffset"] as? Double ?? -6.0

        // UI preferences
        let showKanzen = json["showKanzen"] as? Bool ?? false
        let kanzenAutoMode = json["kanzenAutoMode"] as? Bool ?? false
        let kanzenAutoUpdateModules = json["kanzenAutoUpdateModules"] as? Bool ?? true
        let seasonMenu = json["seasonMenu"] as? Bool ?? false
        let horizontalEpisodeList = json["horizontalEpisodeList"] as? Bool ?? false
        let useClassicScheduleUI = json["useClassicScheduleUI"] as? Bool ?? false
        let mediaColumnsPortrait = json["mediaColumnsPortrait"] as? Int ?? 3
        let mediaColumnsLandscape = json["mediaColumnsLandscape"] as? Int ?? 5

        // Manga / Reader
        let readingMode = json["readingMode"] as? Int ?? 2

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

        var recommendationCache: [TMDBSearchResult] = []
        if let recsData = json["recommendationCache"] as? [[String: Any]] {
            for dict in recsData {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let rec = try? JSONDecoder().decode(TMDBSearchResult.self, from: data) {
                    recommendationCache.append(rec)
                }
            }
        }

        var userRatings: [String: Int] = [:]
        if let ratingsDict = json["userRatings"] as? [String: Int] {
            userRatings = ratingsDict
        }

        var userRatingNotes: [String: String] = [:]
        if let notesDict = json["userRatingNotes"] as? [String: String] {
            userRatingNotes = notesDict
        }
        
        return BackupData(
            version: version,
            createdDate: createdDate,
            accentColor: accentColor,
            tmdbLanguage: tmdbLanguage,
            selectedAppearance: selectedAppearance,
            enableSubtitlesByDefault: enableSubtitlesByDefault,
            defaultSubtitleLanguage: defaultSubtitleLanguage,
            enableVLCSubtitleEditMenu: enableVLCSubtitleEditMenu,
            preferredAnimeAudioLanguage: preferredAnimeAudioLanguage,
            inAppPlayer: inAppPlayer,
            showScheduleTab: showScheduleTab,
            showLocalScheduleTime: showLocalScheduleTime,
            defaultPlaybackSpeed: defaultPlaybackSpeed,
            holdSpeedPlayer: holdSpeedPlayer,
            externalPlayer: externalPlayer,
            alwaysLandscape: alwaysLandscape,
            aniSkipAutoSkip: aniSkipAutoSkip,
            skip85sEnabled: skip85sEnabled,
            showNextEpisodeButton: showNextEpisodeButton,
            nextEpisodeThreshold: nextEpisodeThreshold,
            vlcHeaderProxyEnabled: vlcHeaderProxyEnabled,
            vlcBrightnessGestureEnabled: vlcBrightnessGestureEnabled,
            vlcVolumeGestureEnabled: vlcVolumeGestureEnabled,
            playerTwoFingerTapPlayPauseEnabled: playerTwoFingerTapPlayPauseEnabled,
            vlcDoubleTapSeekEnabled: vlcDoubleTapSeekEnabled,
            vlcDoubleTapSeekSeconds: vlcDoubleTapSeekSeconds,
            vlcPiPEnabled: vlcPiPEnabled,
            vlcOpenSubtitlesEnabled: vlcOpenSubtitlesEnabled,
            vlcOpenSubtitlesAutoFallbackEnabled: vlcOpenSubtitlesAutoFallbackEnabled,
            subtitleForegroundColor: subtitleForegroundColor,
            subtitleStrokeColor: subtitleStrokeColor,
            subtitleStrokeWidth: subtitleStrokeWidth,
            subtitleFontSize: subtitleFontSize,
            subtitleVerticalOffset: subtitleVerticalOffset,
            showKanzen: showKanzen,
            kanzenAutoMode: kanzenAutoMode,
            kanzenAutoUpdateModules: kanzenAutoUpdateModules,
            seasonMenu: seasonMenu,
            horizontalEpisodeList: horizontalEpisodeList,
            useClassicScheduleUI: useClassicScheduleUI,
            mediaColumnsPortrait: mediaColumnsPortrait,
            mediaColumnsLandscape: mediaColumnsLandscape,
            readingMode: readingMode,
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
            recommendationCache: recommendationCache,
            userRatings: userRatings,
            userRatingNotes: userRatingNotes
        )
    }
    
    /// Applies backup data to all managers and UserDefaults
    private func applyBackupData(_ backup: BackupData) -> Bool {
        let trackerManager = TrackerManager.shared
        trackerManager.setBackupRestoreSyncSuppressed(true)
        defer {
            trackerManager.setBackupRestoreSyncSuppressed(false)
        }

        let userDefaults = UserDefaults.standard
        
        // Restore settings
        if let accentColorData = backup.accentColor {
            userDefaults.set(accentColorData, forKey: "accentColor")
        }
        userDefaults.set(backup.tmdbLanguage, forKey: "tmdbLanguage")
        userDefaults.set(backup.selectedAppearance, forKey: "selectedAppearance")
        userDefaults.set(backup.enableSubtitlesByDefault, forKey: "enableSubtitlesByDefault")
        userDefaults.set(backup.defaultSubtitleLanguage, forKey: "defaultSubtitleLanguage")
        // Forced on by app policy: backup value is intentionally ignored here and this flag remains enabled.
        userDefaults.set(true, forKey: "enableVLCSubtitleEditMenu")

        userDefaults.set(backup.preferredAnimeAudioLanguage, forKey: "preferredAnimeAudioLanguage")
        userDefaults.set(backup.inAppPlayer, forKey: "inAppPlayer")
        userDefaults.set(backup.showScheduleTab, forKey: "showScheduleTab")
        userDefaults.set(backup.showLocalScheduleTime, forKey: "showLocalScheduleTime")

        // Player settings
        userDefaults.set(backup.defaultPlaybackSpeed, forKey: "defaultPlaybackSpeed")
        userDefaults.set(backup.holdSpeedPlayer, forKey: "holdSpeedPlayer")
        userDefaults.set(backup.externalPlayer, forKey: "externalPlayer")
        userDefaults.set(backup.alwaysLandscape, forKey: "alwaysLandscape")
        userDefaults.set(backup.aniSkipAutoSkip, forKey: "aniSkipAutoSkip")
        userDefaults.set(backup.skip85sEnabled, forKey: "skip85sEnabled")
        userDefaults.set(backup.showNextEpisodeButton, forKey: "showNextEpisodeButton")
        userDefaults.set(backup.nextEpisodeThreshold, forKey: "nextEpisodeThreshold")
        // Forced on by app policy: backup value is intentionally ignored here and this flag remains enabled.
        userDefaults.set(true, forKey: "vlcHeaderProxyEnabled")
        userDefaults.set(backup.vlcBrightnessGestureEnabled, forKey: "vlcBrightnessGestureEnabled")
        userDefaults.set(backup.vlcVolumeGestureEnabled, forKey: "vlcVolumeGestureEnabled")
        userDefaults.set(backup.playerTwoFingerTapPlayPauseEnabled, forKey: "playerTwoFingerTapPlayPauseEnabled")
        userDefaults.set(backup.vlcDoubleTapSeekEnabled, forKey: "vlcDoubleTapSeekEnabled")
        userDefaults.set(backup.vlcDoubleTapSeekSeconds, forKey: "vlcDoubleTapSeekSeconds")
        userDefaults.set(backup.vlcPiPEnabled, forKey: "vlcPiPEnabled")
        userDefaults.set(backup.vlcOpenSubtitlesEnabled, forKey: "vlcOpenSubtitlesEnabled")
        userDefaults.set(backup.vlcOpenSubtitlesAutoFallbackEnabled, forKey: "vlcOpenSubtitlesAutoFallbackEnabled")

        // Subtitle styling
        if let fgColor = backup.subtitleForegroundColor {
            userDefaults.set(fgColor, forKey: "subtitles_foregroundColor")
        }
        if let strokeColor = backup.subtitleStrokeColor {
            userDefaults.set(strokeColor, forKey: "subtitles_strokeColor")
        }
        userDefaults.set(backup.subtitleStrokeWidth, forKey: "subtitles_strokeWidth")
        userDefaults.set(backup.subtitleFontSize, forKey: "subtitles_fontSize")
        userDefaults.set(backup.subtitleVerticalOffset, forKey: "vlcSubtitleOverlayBottomConstant")

        // UI preferences
        userDefaults.set(backup.showKanzen, forKey: "showKanzen")
        userDefaults.set(backup.kanzenAutoMode, forKey: "kanzenAutoMode")
        userDefaults.set(backup.kanzenAutoUpdateModules, forKey: "kanzenAutoUpdateModules")
        userDefaults.set(backup.seasonMenu, forKey: "seasonMenu")
        userDefaults.set(backup.horizontalEpisodeList, forKey: "horizontalEpisodeList")
        userDefaults.set(backup.useClassicScheduleUI, forKey: "useClassicScheduleUI")
        userDefaults.set(backup.mediaColumnsPortrait, forKey: "mediaColumnsPortrait")
        userDefaults.set(backup.mediaColumnsLandscape, forKey: "mediaColumnsLandscape")

        // Manga / Reader
        userDefaults.set(backup.readingMode, forKey: "readingMode")

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
        
        // Reload Settings singleton to pick up changes
        let settings = Settings.shared
        DispatchQueue.main.async {
            settings.objectWillChange.send()
        }
        
        // Restore collections
        let libraryManager = LibraryManager.shared
        libraryManager.collections = backup.collections.map { $0.toLibraryCollection() }
        // Collections are auto-saved in LibraryManager
        
        // Restore progress data in bulk to avoid per-entry tracker sync bursts (prevents AniList 429)
        let progressManager = ProgressManager.shared
        progressManager.replaceProgressDataForRestore(backup.progressData)
        
        // Restore tracker state, including connected AniList/MAL/Trakt accounts and sync settings.
        let restoreTrackerState = {
            trackerManager.trackerState = backup.trackerState
            trackerManager.saveTrackerState()
        }
        if Thread.isMainThread {
            restoreTrackerState()
        } else {
            DispatchQueue.main.sync(execute: restoreTrackerState)
        }
        
        // Restore catalogs (merge to preserve new defaults like widget catalogs)
        let catalogManager = CatalogManager.shared
        if !backup.catalogs.isEmpty {
            var merged = backup.catalogs
            let existingIds = Set(merged.map { $0.id })
            let currentDefaults = catalogManager.catalogs.filter { !existingIds.contains($0.id) }
            merged.append(contentsOf: currentDefaults)
            merged = merged.enumerated().map { index, catalog in
                var updated = catalog
                updated.order = index
                return updated
            }
            catalogManager.catalogs = merged
        }
        catalogManager.saveCatalogs()

        // Restore services (clear existing, then insert)
        let serviceStore = ServiceStore.shared
        let existingServices = serviceStore.getServices()
        existingServices.forEach { serviceStore.remove($0) }
        for svc in backup.services {
            serviceStore.storeService(id: svc.id, url: svc.url, jsonMetadata: svc.jsonMetadata, jsScript: svc.jsScript, isActive: svc.isActive)
        }

        // Restore Stremio addons only when the backup explicitly contains this field.
        // Older backups did not know about Stremio addons, so they must not wipe the current device's addons.
        if let stremioAddons = backup.stremioAddons {
            let stremioStore = StremioAddonStore.shared
            stremioStore.removeAll()

            let sortedAddons = stremioAddons.sorted {
                if $0.sortIndex == $1.sortIndex {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.sortIndex < $1.sortIndex
            }

            for addon in sortedAddons {
                let configuredURL = addon.configuredURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !configuredURL.isEmpty,
                      let manifestData = addon.manifestJSON.data(using: .utf8),
                      let manifest = try? JSONDecoder().decode(StremioManifest.self, from: manifestData),
                      manifest.supportsStreams else {
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

            Task { @MainActor in
                StremioAddonManager.shared.loadAddons()
            }
        }

        // Restore manga library collections
        let mangaLibraryManager = MangaLibraryManager.shared
        if !backup.mangaCollections.isEmpty {
            mangaLibraryManager.collections = backup.mangaCollections.map { bc in
                MangaLibraryCollection(id: bc.id, name: bc.name, items: bc.items, description: bc.description)
            }
        }

        // Restore manga reading progress
        if !backup.mangaReadingProgress.isEmpty {
            let mangaProgressMap = Dictionary(uniqueKeysWithValues:
                backup.mangaReadingProgress.compactMap { key, value -> (Int, MangaProgress)? in
                    guard let id = Int(key) else { return nil }
                    return (id, value)
                }
            )
            MangaReadingProgressManager.shared.replaceProgressMapForRestore(mangaProgressMap)
        }

        // Restore manga catalogs
        if !backup.mangaCatalogs.isEmpty {
            let mangaCatalogManager = MangaCatalogManager.shared
            mangaCatalogManager.catalogs = backup.mangaCatalogs
            mangaCatalogManager.saveCatalogs()
        }

        // Restore Kanzen modules
        if !backup.kanzenModules.isEmpty {
            let kanzenModuleManager = ModuleManager.shared
            for mod in backup.kanzenModules {
                if !kanzenModuleManager.modules.contains(where: { $0.id == mod.id }) {
                    let container = ModuleDataContainer(
                        id: mod.id,
                        moduleData: mod.moduleData,
                        localPath: mod.localPath,
                        moduleurl: mod.moduleurl,
                        isActive: mod.isActive
                    )
                    kanzenModuleManager.modules.append(container)
                }
            }
            kanzenModuleManager.saveModules()
        }

        // Restore recommendation cache
        if !backup.recommendationCache.isEmpty {
            RecommendationEngine.shared.restoreRecommendationCache(backup.recommendationCache)
        }

        // Restore user ratings and private notes without triggering tracker writes.
        if !backup.userRatings.isEmpty || !backup.userRatingNotes.isEmpty {
            UserRatingManager.shared.restoreRatingsAndNotes(
                ratings: backup.userRatings,
                notes: backup.userRatingNotes
            )
        }
        
        Logger.shared.log("Backup restored successfully", type: "Info")
        return true
    }
}
