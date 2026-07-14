import SwiftUI

enum ExternalPlayer: String, CaseIterable, Identifiable {
    case none = "Default"
    case infuse = "Infuse"
    case vlc = "VLC"
    case outPlayer = "OutPlayer"
    case nPlayer = "nPlayer"
    case senPlayer = "SenPlayer"
    case tracy = "TracyPlayer"
    case vidHub = "VidHub"

    var id: String { rawValue }

    func schemeURL(for urlString: String) -> URL? {
        let url = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString
        switch self {
        case .infuse:
            return URL(string: "infuse://x-callback-url/play?url=\(url)")
        case .vlc:
            return URL(string: "vlc://\(url)")
        case .outPlayer:
            return URL(string: "outplayer://\(url)")
        case .nPlayer:
            return URL(string: "nplayer-\(url)")
        case .senPlayer:
            return URL(string: "senplayer://x-callback-url/play?url=\(url)")
        case .tracy:
            return URL(string: "tracy://open?url=\(url)")
        case .vidHub:
            return URL(string: "open-vidhub://x-callback-url/open?url=\(url)")
        case .none:
            return nil
        }
    }
}

final class PlayerSettingsStore: ObservableObject {
    @Published var playbackEngine: PlaybackEngine {
        didSet { PlaybackEngine.selected = playbackEngine }
    }

    @Published var defaultPlaybackSpeed: Double {
        didSet { UserDefaults.standard.set(defaultPlaybackSpeed, forKey: "defaultPlaybackSpeed") }
    }

    @Published var holdSpeed: Double {
        didSet { UserDefaults.standard.set(holdSpeed, forKey: "holdSpeedPlayer") }
    }

    @Published var externalPlayer: ExternalPlayer {
        didSet { UserDefaults.standard.set(externalPlayer.rawValue, forKey: "externalPlayer") }
    }

    @Published var landscapeOnly: Bool {
        didSet { UserDefaults.standard.set(landscapeOnly, forKey: "alwaysLandscape") }
    }

    @Published var playerPlaybackLockEnabled: Bool {
        didSet { PlayerPlaybackLockSettings.setEnabled(playerPlaybackLockEnabled) }
    }

    #if !os(tvOS)
    @Published var preferDownloadedMedia: Bool {
        didSet { UserDefaults.standard.set(preferDownloadedMedia, forKey: "preferDownloadedMedia") }
    }
    #endif

    @Published var aniSkipAutoSkip: Bool {
        didSet { UserDefaults.standard.set(aniSkipAutoSkip, forKey: "aniSkipAutoSkip") }
    }

    @Published var aniSkipEnabled: Bool {
        didSet { UserDefaults.standard.set(aniSkipEnabled, forKey: "aniSkipEnabled") }
    }

    @Published var introDBEnabled: Bool {
        didSet { UserDefaults.standard.set(introDBEnabled, forKey: "introDBEnabled") }
    }

    @Published var introDBAppEnabled: Bool {
        didSet { UserDefaults.standard.set(introDBAppEnabled, forKey: "introDBAppEnabled") }
    }

    @Published var skip85sEnabled: Bool {
        didSet { UserDefaults.standard.set(skip85sEnabled, forKey: "skip85sEnabled") }
    }

    @Published var skip85sAlwaysVisible: Bool {
        didSet { UserDefaults.standard.set(skip85sAlwaysVisible, forKey: "skip85sAlwaysVisible") }
    }

    @Published var showNextEpisodeButton: Bool {
        didSet { UserDefaults.standard.set(showNextEpisodeButton, forKey: "showNextEpisodeButton") }
    }

    @Published var showEpisodeBrowserButton: Bool {
        didSet { UserDefaults.standard.set(showEpisodeBrowserButton, forKey: "showEpisodeBrowserButton") }
    }

    @Published var showPlayerServicesButton: Bool {
        didSet { UserDefaults.standard.set(showPlayerServicesButton, forKey: PlayerServicesButtonSettings.key) }
    }

    @Published var showNextEpisodePosterButton: Bool {
        didSet { UserDefaults.standard.set(showNextEpisodePosterButton, forKey: "showNextEpisodePosterButton") }
    }

    @Published var nextEpisodeThreshold: Double {
        didSet { UserDefaults.standard.set(nextEpisodeThreshold, forKey: "nextEpisodeThreshold") }
    }

    @Published var nextEpisodeSkipFillerEnabled: Bool {
        didSet { UserDefaults.standard.set(nextEpisodeSkipFillerEnabled, forKey: NextEpisodeFillerSettings.enabledKey) }
    }

    @Published var playerBrightnessGestureEnabled: Bool {
        didSet { UserDefaults.standard.set(playerBrightnessGestureEnabled, forKey: "playerBrightnessGestureEnabled") }
    }

    @Published var playerVolumeGestureEnabled: Bool {
        didSet { UserDefaults.standard.set(playerVolumeGestureEnabled, forKey: "playerVolumeGestureEnabled") }
    }

    @Published var playerTwoFingerTapPlayPauseEnabled: Bool {
        didSet { UserDefaults.standard.set(playerTwoFingerTapPlayPauseEnabled, forKey: "playerTwoFingerTapPlayPauseEnabled") }
    }

    @Published var playerCenterTapPlayPauseEnabled: Bool {
        didSet { UserDefaults.standard.set(playerCenterTapPlayPauseEnabled, forKey: "playerCenterTapPlayPauseEnabled") }
    }

    @Published var playerDoubleTapSeekEnabled: Bool {
        didSet { UserDefaults.standard.set(playerDoubleTapSeekEnabled, forKey: "playerDoubleTapSeekEnabled") }
    }

    @Published var playerDoubleTapSeekSeconds: Double {
        didSet { UserDefaults.standard.set(playerDoubleTapSeekSeconds, forKey: "playerDoubleTapSeekSeconds") }
    }

    @Published var playerOpenSubtitlesEnabled: Bool {
        didSet { UserDefaults.standard.set(playerOpenSubtitlesEnabled, forKey: "playerOpenSubtitlesEnabled") }
    }

    @Published var playerOpenSubtitlesAutoFallbackEnabled: Bool {
        didSet { UserDefaults.standard.set(playerOpenSubtitlesAutoFallbackEnabled, forKey: "playerOpenSubtitlesAutoFallbackEnabled") }
    }

    @Published var playerSubtitleAppearanceEnabled: Bool {
        didSet { UserDefaults.standard.set(playerSubtitleAppearanceEnabled, forKey: "playerSubtitleAppearanceEnabled") }
    }

    @Published var mpvForegroundFPS: Int {
        didSet { UserDefaults.standard.set(mpvForegroundFPS == 60 ? 60 : 30, forKey: "mpvForegroundFPS") }
    }

    @Published var mpvRenderBackend: MPVRenderBackend {
        didSet { UserDefaults.standard.set(mpvRenderBackend.rawValue, forKey: "mpvRenderBackend") }
    }

    @Published var mpvMetalQualityProfile: MPVMetalQualityProfile {
        didSet { UserDefaults.standard.set(mpvMetalQualityProfile.rawValue, forKey: "mpvMetalQualityProfile") }
    }

    @Published var mpvUpscalingMode: MPVUpscalingMode {
        didSet { UserDefaults.standard.set(mpvUpscalingMode.rawValue, forKey: "mpvUpscalingMode") }
    }

    @Published var mpvPlayerSkin: MPVPlayerSkin {
        didSet { UserDefaults.standard.set(mpvPlayerSkin.rawValue, forKey: MPVPlayerSkinSettings.skinKey) }
    }

    @Published var mpvPerformanceOverlayEnabled: Bool {
        didSet { UserDefaults.standard.set(mpvPerformanceOverlayEnabled, forKey: "mpvPerformanceOverlayEnabled") }
    }

    @Published var mpvUseLegacyCPURenderer: Bool {
        didSet { UserDefaults.standard.set(mpvUseLegacyCPURenderer, forKey: "mpvUseLegacyCPURenderer") }
    }

    @Published var mpvAppExitPictureInPictureEnabled: Bool {
        didSet { UserDefaults.standard.set(mpvAppExitPictureInPictureEnabled, forKey: "mpvAppExitPictureInPictureEnabled") }
    }

    @Published var mpvPictureInPictureEnabled: Bool {
        didSet { UserDefaults.standard.set(mpvPictureInPictureEnabled, forKey: "mpvPictureInPictureEnabled") }
    }

    @Published var mpvHDRMode: MPVHDRMode {
        didSet { UserDefaults.standard.set(mpvHDRMode.rawValue, forKey: "mpvHDRMode") }
    }

    @Published var audioComfortMode: AudioComfortMode {
        didSet { UserDefaults.standard.set(audioComfortMode.rawValue, forKey: "audioComfortMode") }
    }

    @Published var audioComfortScopeCategories: Set<AudioComfortContentCategory> {
        didSet { UserDefaults.standard.set(audioComfortScopeCategories.map { $0.rawValue }, forKey: "audioComfortScopeCategories") }
    }

    @Published var mpvSurroundSoundEnabled: Bool {
        didSet { UserDefaults.standard.set(mpvSurroundSoundEnabled, forKey: "mpvSurroundSoundEnabled") }
    }

    @Published var experimentalMPVPreloadEnabled: Bool {
        didSet { UserDefaults.standard.set(experimentalMPVPreloadEnabled, forKey: ExperimentalFeatureState.mpvPreloadEnabledKey) }
    }

    @Published var experimentalMPVSmoothTransitionEnabled: Bool {
        didSet { UserDefaults.standard.set(experimentalMPVSmoothTransitionEnabled, forKey: ExperimentalFeatureState.mpvSmoothTransitionEnabledKey) }
    }

    @Published var experimentalMPVPreloadCellularEnabled: Bool {
        didSet { UserDefaults.standard.set(experimentalMPVPreloadCellularEnabled, forKey: ExperimentalFeatureState.mpvPreloadCellularEnabledKey) }
    }

    @Published var experimentalMPVPreloadWifiLimitMB: Int {
        didSet { UserDefaults.standard.set(ExperimentalFeatureState.clampedMPVPreloadWifiLimitMB(experimentalMPVPreloadWifiLimitMB), forKey: ExperimentalFeatureState.mpvPreloadWifiLimitMBKey) }
    }

    @Published var experimentalMPVPreloadCellularLimitMB: Int {
        didSet { UserDefaults.standard.set(ExperimentalFeatureState.clampedMPVPreloadCellularLimitMB(experimentalMPVPreloadCellularLimitMB), forKey: ExperimentalFeatureState.mpvPreloadCellularLimitMBKey) }
    }

    @Published var experimentalMPVPreloadAutoClearEnabled: Bool {
        didSet { UserDefaults.standard.set(experimentalMPVPreloadAutoClearEnabled, forKey: ExperimentalFeatureState.mpvPreloadAutoClearKey) }
    }

    @Published var experimentalMPVShowRemainingTime: Bool {
        didSet { UserDefaults.standard.set(experimentalMPVShowRemainingTime, forKey: ExperimentalFeatureState.mpvShowRemainingTimeKey) }
    }

    @Published var experimentalMPVPreciseProgress: Bool {
        didSet { UserDefaults.standard.set(experimentalMPVPreciseProgress, forKey: ExperimentalFeatureState.mpvPreciseProgressKey) }
    }

    @Published var experimentalMPVIgnoreSpecialSubtitleStyles: Bool {
        didSet { UserDefaults.standard.set(experimentalMPVIgnoreSpecialSubtitleStyles, forKey: ExperimentalFeatureState.mpvIgnoreSpecialSubtitleStylesKey) }
    }

    private static func migratedBool(genericKey: String, legacyKey: String, defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: genericKey) == nil {
            let value = UserDefaults.standard.object(forKey: legacyKey) as? Bool ?? defaultValue
            UserDefaults.standard.set(value, forKey: genericKey)
            return value
        }
        return UserDefaults.standard.bool(forKey: genericKey)
    }

    private static func migratedDouble(genericKey: String, legacyKey: String, defaultValue: Double) -> Double {
        if UserDefaults.standard.object(forKey: genericKey) == nil {
            let value = UserDefaults.standard.double(forKey: legacyKey)
            let resolved = value > 0 ? value : defaultValue
            UserDefaults.standard.set(resolved, forKey: genericKey)
            return resolved
        }
        let value = UserDefaults.standard.double(forKey: genericKey)
        return value > 0 ? value : defaultValue
    }

    init() {
        self.playbackEngine = PlaybackEngine.selected
        let savedDefaultSpeed = UserDefaults.standard.double(forKey: "defaultPlaybackSpeed")
        self.defaultPlaybackSpeed = savedDefaultSpeed > 0 ? savedDefaultSpeed : 1.0

        let savedSpeed = UserDefaults.standard.double(forKey: "holdSpeedPlayer")
        self.holdSpeed = savedSpeed > 0 ? savedSpeed : 2.0

        let raw = UserDefaults.standard.string(forKey: "externalPlayer") ?? ExternalPlayer.none.rawValue
        self.externalPlayer = ExternalPlayer(rawValue: raw) ?? .none

        self.landscapeOnly = UserDefaults.standard.bool(forKey: "alwaysLandscape")
        self.playerPlaybackLockEnabled = PlayerPlaybackLockSettings.isEnabled()

        #if !os(tvOS)
        self.preferDownloadedMedia = UserDefaults.standard.bool(forKey: "preferDownloadedMedia")
        #endif

        self.aniSkipAutoSkip = UserDefaults.standard.bool(forKey: "aniSkipAutoSkip")

        if UserDefaults.standard.object(forKey: "aniSkipEnabled") == nil {
            self.aniSkipEnabled = true
        } else {
            self.aniSkipEnabled = UserDefaults.standard.bool(forKey: "aniSkipEnabled")
        }

        if UserDefaults.standard.object(forKey: "introDBEnabled") == nil {
            self.introDBEnabled = true
        } else {
            self.introDBEnabled = UserDefaults.standard.bool(forKey: "introDBEnabled")
        }

        if UserDefaults.standard.object(forKey: "introDBAppEnabled") == nil {
            self.introDBAppEnabled = true
        } else {
            self.introDBAppEnabled = UserDefaults.standard.bool(forKey: "introDBAppEnabled")
        }

        self.skip85sEnabled = UserDefaults.standard.bool(forKey: "skip85sEnabled")
        self.skip85sAlwaysVisible = UserDefaults.standard.bool(forKey: "skip85sAlwaysVisible")

        // Default to true if key has never been set
        if UserDefaults.standard.object(forKey: "showNextEpisodeButton") == nil {
            self.showNextEpisodeButton = true
        } else {
            self.showNextEpisodeButton = UserDefaults.standard.bool(forKey: "showNextEpisodeButton")
        }

        if UserDefaults.standard.object(forKey: "showEpisodeBrowserButton") == nil {
            let legacy = UserDefaults.standard.object(forKey: "showVLCEpisodeBrowserButton") as? Bool ?? true
            UserDefaults.standard.set(legacy, forKey: "showEpisodeBrowserButton")
            self.showEpisodeBrowserButton = legacy
        } else {
            self.showEpisodeBrowserButton = UserDefaults.standard.bool(forKey: "showEpisodeBrowserButton")
        }
        self.showPlayerServicesButton = PlayerServicesButtonSettings.isEnabled()

        self.showNextEpisodePosterButton = UserDefaults.standard.bool(forKey: "showNextEpisodePosterButton")

        let savedThreshold = UserDefaults.standard.double(forKey: "nextEpisodeThreshold")
        self.nextEpisodeThreshold = savedThreshold > 0 ? savedThreshold : 0.90
        self.nextEpisodeSkipFillerEnabled = NextEpisodeFillerSettings.isEnabled()

        self.playerBrightnessGestureEnabled = Self.migratedBool(genericKey: "playerBrightnessGestureEnabled", legacyKey: "vlcBrightnessGestureEnabled", defaultValue: false)
        self.playerVolumeGestureEnabled = Self.migratedBool(genericKey: "playerVolumeGestureEnabled", legacyKey: "vlcVolumeGestureEnabled", defaultValue: false)

        if UserDefaults.standard.object(forKey: "playerTwoFingerTapPlayPauseEnabled") == nil {
            if let legacy = UserDefaults.standard.object(forKey: "mpvTwoFingerTapEnabled") as? Bool {
                UserDefaults.standard.set(legacy, forKey: "playerTwoFingerTapPlayPauseEnabled")
                self.playerTwoFingerTapPlayPauseEnabled = legacy
            } else {
                UserDefaults.standard.set(true, forKey: "playerTwoFingerTapPlayPauseEnabled")
                self.playerTwoFingerTapPlayPauseEnabled = true
            }
        } else {
            self.playerTwoFingerTapPlayPauseEnabled = UserDefaults.standard.bool(forKey: "playerTwoFingerTapPlayPauseEnabled")
        }

        if UserDefaults.standard.object(forKey: "playerCenterTapPlayPauseEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "playerCenterTapPlayPauseEnabled")
            self.playerCenterTapPlayPauseEnabled = true
        } else {
            self.playerCenterTapPlayPauseEnabled = UserDefaults.standard.bool(forKey: "playerCenterTapPlayPauseEnabled")
        }

        self.playerDoubleTapSeekEnabled = Self.migratedBool(genericKey: "playerDoubleTapSeekEnabled", legacyKey: "vlcDoubleTapSeekEnabled", defaultValue: true)
        self.playerDoubleTapSeekSeconds = Self.migratedDouble(genericKey: "playerDoubleTapSeekSeconds", legacyKey: "vlcDoubleTapSeekSeconds", defaultValue: 10.0)
        self.playerOpenSubtitlesEnabled = Self.migratedBool(genericKey: "playerOpenSubtitlesEnabled", legacyKey: "vlcOpenSubtitlesEnabled", defaultValue: false)
        self.playerOpenSubtitlesAutoFallbackEnabled = Self.migratedBool(genericKey: "playerOpenSubtitlesAutoFallbackEnabled", legacyKey: "vlcOpenSubtitlesAutoFallbackEnabled", defaultValue: true)
        self.playerSubtitleAppearanceEnabled = Self.migratedBool(genericKey: "playerSubtitleAppearanceEnabled", legacyKey: "enableVLCSubtitleEditMenu", defaultValue: true)

        self.mpvForegroundFPS = UserDefaults.standard.integer(forKey: "mpvForegroundFPS") == 60 ? 60 : 30
        self.mpvRenderBackend = .defaultBackend
        UserDefaults.standard.set(MPVRenderBackend.defaultBackend.rawValue, forKey: "mpvRenderBackend")
        let metalQualityRaw = UserDefaults.standard.string(forKey: "mpvMetalQualityProfile") ?? MPVMetalQualityProfile.defaultProfile.rawValue
        self.mpvMetalQualityProfile = MPVMetalQualityProfile(rawValue: metalQualityRaw) ?? .defaultProfile
        let upscalingRaw = UserDefaults.standard.string(forKey: "mpvUpscalingMode") ?? MPVUpscalingMode.defaultMode.rawValue
        self.mpvUpscalingMode = MPVUpscalingMode(rawValue: upscalingRaw) ?? .defaultMode
        self.mpvPlayerSkin = MPVPlayerSkinSettings.selected()
        self.mpvPerformanceOverlayEnabled = UserDefaults.standard.bool(forKey: "mpvPerformanceOverlayEnabled")
        self.mpvUseLegacyCPURenderer = UserDefaults.standard.bool(forKey: "mpvUseLegacyCPURenderer")
        self.mpvAppExitPictureInPictureEnabled = UserDefaults.standard.bool(forKey: "mpvAppExitPictureInPictureEnabled")
        self.mpvPictureInPictureEnabled = UserDefaults.standard.object(forKey: "mpvPictureInPictureEnabled") as? Bool ?? true
        let hdrModeRaw = UserDefaults.standard.string(forKey: "mpvHDRMode") ?? MPVHDRMode.defaultMode.rawValue
        self.mpvHDRMode = MPVHDRMode(rawValue: hdrModeRaw) ?? .defaultMode
        let audioComfortModeRaw = UserDefaults.standard.string(forKey: "audioComfortMode") ?? AudioComfortMode.defaultMode.rawValue
        self.audioComfortMode = AudioComfortMode(rawValue: audioComfortModeRaw) ?? .defaultMode
        if let rawScopes = UserDefaults.standard.array(forKey: "audioComfortScopeCategories") as? [String] {
            self.audioComfortScopeCategories = Set(rawScopes.compactMap { AudioComfortContentCategory(rawValue: $0) })
        } else {
            self.audioComfortScopeCategories = AudioComfortContentCategory.defaultScope
        }
        self.mpvSurroundSoundEnabled = UserDefaults.standard.object(forKey: "mpvSurroundSoundEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "mpvSurroundSoundEnabled")

        ExperimentalFeatureState.registerDefaults()
        self.experimentalMPVPreloadEnabled = UserDefaults.standard.bool(forKey: ExperimentalFeatureState.mpvPreloadEnabledKey)
        self.experimentalMPVSmoothTransitionEnabled = UserDefaults.standard.bool(forKey: ExperimentalFeatureState.mpvSmoothTransitionEnabledKey)
        self.experimentalMPVPreloadCellularEnabled = UserDefaults.standard.bool(forKey: ExperimentalFeatureState.mpvPreloadCellularEnabledKey)
        let wifiLimit = UserDefaults.standard.integer(forKey: ExperimentalFeatureState.mpvPreloadWifiLimitMBKey)
        self.experimentalMPVPreloadWifiLimitMB = ExperimentalFeatureState.resolvedMPVPreloadWifiLimitMB(wifiLimit)
        let cellularLimit = UserDefaults.standard.integer(forKey: ExperimentalFeatureState.mpvPreloadCellularLimitMBKey)
        self.experimentalMPVPreloadCellularLimitMB = ExperimentalFeatureState.resolvedMPVPreloadCellularLimitMB(cellularLimit)
        self.experimentalMPVPreloadAutoClearEnabled = (UserDefaults.standard.object(forKey: ExperimentalFeatureState.mpvPreloadAutoClearKey) as? Bool) ?? true
        self.experimentalMPVShowRemainingTime = UserDefaults.standard.bool(forKey: ExperimentalFeatureState.mpvShowRemainingTimeKey)
        self.experimentalMPVPreciseProgress = UserDefaults.standard.bool(forKey: ExperimentalFeatureState.mpvPreciseProgressKey)
        self.experimentalMPVIgnoreSpecialSubtitleStyles = UserDefaults.standard.bool(forKey: ExperimentalFeatureState.mpvIgnoreSpecialSubtitleStylesKey)
    }
}

enum PlayerSettingsSearchTarget: String, Hashable {
    case defaultPlaybackSpeed
    case holdSpeed
    case forceLandscape
    case playbackLock
    case servicesButton
    case externalPlayer
    case inAppPlayer
    case preferDownloadedEpisodes
    case mpvSettings
    case subtitleDefaults
    case enableSubtitlesByDefault
    case defaultSubtitleLanguage
    case autoAudioLanguage
    case preferredAnimeAudio
    case subtitleAppearance
    case subtitleEditMenu
    case subtitleTextColor
    case subtitleStrokeColor
    case subtitleStrokeWidth
    case subtitleFontSize
    case subtitleVerticalPosition
    case captionBackground
    case resetSubtitleStyle
    case moltenVKQuality
    case playbackGestures
    case brightnessGesture
    case volumeGesture
    case twoFingerPlayPause
    case centerTapPlayPause
    case doubleTapSeek
    case seekAmount
    case openSubtitles
    case openSubtitlesAutoFallback
    case skipSegments
    case aniSkip
    case theIntroDB
    case introDB
    case autoSkip
    case skip85sFallback
    case alwaysShowSkip85s
    case nextEpisode
    case episodeBrowserButton
    case showNextEpisodeButton
    case useEpisodePoster
    case skipFillerEpisodes
    case appearanceThreshold
    case streamWarmupCache
    case nextEpisodeStaging
    case allowCellularWarmup
    case autoClearWarmupCache
    case wifiCacheLimit
    case cellularCacheLimit
    case showRemainingTime
    case preciseProgressAdjustment
    case ignoreSpecialSubtitleStyles
    case pictureInPicture
    case pipWhenLeavingApp
    case upscaling
    case performanceOverlay
    case sampleBufferRenderer
    case hdrOutput
    case surroundSound
    case comfortAudio
    case comfortAudioApplyToAll
    case inlineFrameRate
    case playerSkin

    var anchorID: String {
        "player-settings-search-\(rawValue)"
    }

    var isMPVSettingsTarget: Bool {
        let usesAVPlayer: Bool
#if os(tvOS)
        usesAVPlayer = PlaybackEngine.selected == .avPlayer
#else
        usesAVPlayer = PlaybackLaunchPlan.make(
            selection: .selected,
            deviceFamily: .current
        ).primary == .avPlayer
#endif
        if usesAVPlayer {
            switch self {
            case .subtitleDefaults,
                 .enableSubtitlesByDefault,
                 .defaultSubtitleLanguage,
                 .autoAudioLanguage,
                 .preferredAnimeAudio,
                 .subtitleAppearance,
                 .subtitleTextColor,
                 .subtitleStrokeColor,
                 .subtitleStrokeWidth,
                 .subtitleFontSize,
                 .subtitleVerticalPosition,
                 .captionBackground,
                 .resetSubtitleStyle,
                 .seekAmount,
                 .nextEpisode,
                 .showNextEpisodeButton,
                 .appearanceThreshold,
                 .pictureInPicture:
                return false
#if !os(tvOS)
            case .playbackGestures,
                 .doubleTapSeek,
                 .pipWhenLeavingApp:
                return false
#endif
#if os(tvOS)
            case .theIntroDB,
                 .introDB,
                 .autoSkip:
                return false
#endif
            default:
                break
            }
        }
        switch self {
        case .defaultPlaybackSpeed,
             .holdSpeed,
             .forceLandscape,
             .playbackLock,
             .servicesButton,
             .externalPlayer,
             .inAppPlayer,
             .preferDownloadedEpisodes:
            return false
        default:
            return true
        }
    }

    var expandedGroup: String? {
        switch self {
        case .subtitleDefaults,
             .enableSubtitlesByDefault,
             .defaultSubtitleLanguage,
             .autoAudioLanguage,
             .preferredAnimeAudio:
            return "subDefaults"
        case .subtitleAppearance,
             .subtitleEditMenu,
             .subtitleTextColor,
             .subtitleStrokeColor,
             .subtitleStrokeWidth,
             .subtitleFontSize,
             .subtitleVerticalPosition,
             .captionBackground,
             .resetSubtitleStyle:
            return "subAppearance"
        case .playbackGestures,
             .brightnessGesture,
             .volumeGesture,
             .twoFingerPlayPause,
             .centerTapPlayPause,
             .doubleTapSeek:
            return "gestures"
        case .seekAmount:
#if os(tvOS)
            return "remote"
#else
            return "gestures"
#endif
        case .pictureInPicture,
             .pipWhenLeavingApp,
             .moltenVKQuality,
             .upscaling,
             .performanceOverlay,
             .sampleBufferRenderer,
             .hdrOutput,
             .surroundSound,
             .comfortAudio,
             .comfortAudioApplyToAll,
             .inlineFrameRate:
            return "rendering"
        case .openSubtitles, .openSubtitlesAutoFallback:
            return "openSubs"
        case .skipSegments,
             .aniSkip,
             .theIntroDB,
             .introDB,
             .autoSkip,
             .skip85sFallback,
             .alwaysShowSkip85s:
            return "skip"
        case .nextEpisode,
             .episodeBrowserButton,
             .showNextEpisodeButton,
             .useEpisodePoster,
             .skipFillerEpisodes,
             .appearanceThreshold:
            return "nextEp"
        case .streamWarmupCache,
             .nextEpisodeStaging,
             .allowCellularWarmup,
             .autoClearWarmupCache,
             .wifiCacheLimit,
             .cellularCacheLimit,
             .showRemainingTime,
             .preciseProgressAdjustment,
             .ignoreSpecialSubtitleStyles:
            return "experimental"
        case .defaultPlaybackSpeed,
             .holdSpeed,
             .forceLandscape,
             .playbackLock,
             .servicesButton,
             .externalPlayer,
             .inAppPlayer,
             .preferDownloadedEpisodes,
             .mpvSettings,
             .playerSkin:
            return nil
        }
    }
}

private struct MPVPlayerSkinSettingsView: View {
    @Binding var selection: MPVPlayerSkin
    @AppStorage(MPVPlayerSkinSettings.customPrimaryColorKey) private var customPrimaryColorData = Data()
    @AppStorage(MPVPlayerSkinSettings.customSecondaryColorKey) private var customSecondaryColorData = Data()
    @AppStorage(MPVPlayerSkinSettings.animationsEnabledKey) private var animationsEnabled = MPVPlayerSkinSettings.defaultAnimationsEnabled
    @AppStorage(MPVPlayerSkinSettings.tintControlsOnlyKey) private var tintControlsOnly = MPVPlayerSkinSettings.defaultTintControlsOnly
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationPhase = false
    @State private var animationStyle: MPVPlayerSkinAnimationStyle = .glow

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                playerPreview(for: selection, style: animationStyle, large: true, animated: true)
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)

                GlassSection(header: "Presets") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(MPVPlayerSkin.allCases) { skin in
                            skinButton(skin)
                        }
                    }
                    .padding(12)
                }

                if selection == .custom {
                    GlassSection(header: "Custom Colors") {
                        VStack(spacing: 0) {
#if !os(tvOS)
                            GlassDetailRow(title: "Primary Color", subtitle: "Icons, progress, and the main control glow.") {
                                ColorPicker("", selection: customColorBinding(
                                    data: $customPrimaryColorData,
                                    fallback: UIColor(red: 0.20, green: 0.86, blue: 1.00, alpha: 1.00)
                                ))
                                .labelsHidden()
                            }
                            GlassDivider(leadingInset: 16)
                            GlassDetailRow(title: "Secondary Color", subtitle: "Overlay accents and supporting controls.") {
                                ColorPicker("", selection: customColorBinding(
                                    data: $customSecondaryColorData,
                                    fallback: UIColor(red: 0.72, green: 0.31, blue: 1.00, alpha: 1.00)
                                ))
                                .labelsHidden()
                            }
#else
                            GlassDetailRow(title: "Custom Colors", subtitle: "Custom color editing is available in Eclipse on iPhone and iPad.") {
                                EmptyView()
                            }
#endif
                        }
                    }
                }

                if selection != .defaultSkin {
                    GlassSection(header: "Coloring") {
                        GlassDetailRow(title: "Tint Controls Only", subtitle: "Color the buttons and menus but keep the standard dark player background.") {
                            Toggle("", isOn: $tintControlsOnly)
                                .labelsHidden()
                                .tint(primaryColor(for: selection))
                        }
                    }
                }

                GlassSection(header: "Motion") {
                    VStack(spacing: 0) {
                        GlassDetailRow(title: "Skin Animations", subtitle: "Use subtle glows and color movement in animated skins.") {
                            Toggle("", isOn: $animationsEnabled)
                                .labelsHidden()
                                .tint(primaryColor(for: selection))
                        }
                        if animationsEnabled && selection != .defaultSkin {
                            GlassDivider(leadingInset: 16)
                            GlassDetailRow(title: "Animation Style", subtitle: animationStyle.settingsDescription) {
                                Picker("", selection: $animationStyle) {
                                    ForEach(MPVPlayerSkinAnimationStyle.allCases) { style in
                                        Text(style.displayName).tag(style)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(.white.opacity(0.7))
                            }
                        }
                    }
                }
                GlassSectionFooter("Reduce Motion always disables skin animation. The Default skin keeps the original MPV appearance.")
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Player Skin")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .onAppear {
            animationStyle = MPVPlayerSkinSettings.animationStyle(for: selection)
            startPreviewAnimationIfNeeded()
        }
        .onChange(of: animationsEnabled) { enabled in
            if enabled {
                startPreviewAnimationIfNeeded()
            } else {
                stopPreviewAnimation()
            }
        }
        .onChange(of: reduceMotion) { reduced in
            if reduced { stopPreviewAnimation() } else { startPreviewAnimationIfNeeded() }
        }
        .onChange(of: selection) { newSkin in
            animationStyle = MPVPlayerSkinSettings.animationStyle(for: newSkin)
        }
        .onChange(of: animationStyle) { newStyle in
            MPVPlayerSkinSettings.setAnimationStyle(newStyle, for: selection)
            startPreviewAnimationIfNeeded()
        }
        .onDisappear {
            stopPreviewAnimation()
        }
    }

    private func startPreviewAnimationIfNeeded() {
        guard animationsEnabled, !reduceMotion, !animationPhase else { return }
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
            animationPhase = true
        }
    }

    private func stopPreviewAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            animationPhase = false
        }
    }

    private func skinButton(_ skin: MPVPlayerSkin) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selection = skin
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                playerPreview(for: skin, style: MPVPlayerSkinSettings.animationStyle(for: skin), large: false, animated: false)
                HStack(spacing: 6) {
                    Text(skin.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if selection == skin {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(primaryColor(for: skin))
                    }
                }
                Text(skin.settingsDescription)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.58))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(selection == skin ? 0.52 : 0.30))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selection == skin ? primaryColor(for: skin).opacity(0.9) : Color.white.opacity(0.10), lineWidth: selection == skin ? 1.5 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func playerPreview(for skin: MPVPlayerSkin, style: MPVPlayerSkinAnimationStyle, large: Bool, animated: Bool) -> some View {
        let primary = primaryColor(for: skin)
        let secondary = secondaryColor(for: skin)
        let shouldAnimate = animated && animationsEnabled && !reduceMotion && skin != .defaultSkin
        let drifting = shouldAnimate && animationPhase && style == .aurora
        return ZStack {
            LinearGradient(
                colors: previewBackgroundColors(for: skin),
                startPoint: drifting ? .topTrailing : .topLeading,
                endPoint: drifting ? .bottomLeading : .bottomTrailing
            )

            if style == .spectrum {
                AngularGradient(colors: [primary, .purple, secondary, .cyan, primary], center: .center)
                    .opacity(shouldAnimate && animationPhase ? 0.22 : 0.12)
                    .hueRotation(.degrees(shouldAnimate && animationPhase ? 55 : 0))
            } else if style == .sweep {
                LinearGradient(colors: [.clear, primary.opacity(0.24), .clear, secondary.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                    .offset(y: shouldAnimate && animationPhase ? (large ? 44 : 18) : (large ? -44 : -18))
            } else if style == .aurora {
                LinearGradient(colors: [primary.opacity(0.22), .clear, secondary.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(shouldAnimate && animationPhase ? 0.9 : 0.5)
            }

            VStack(spacing: large ? 16 : 8) {
                HStack {
                    Image(systemName: "xmark")
                    Spacer()
                    Text("Eclipse Player")
                        .font(large ? .caption.weight(.semibold) : .system(size: 7, weight: .semibold))
                    Spacer()
                    Image(systemName: "captions.bubble")
                }
                .foregroundColor(primary)

                HStack(spacing: large ? 28 : 12) {
                    Image(systemName: "gobackward.10")
                    Image(systemName: "play.fill")
                        .font(large ? .title2 : .caption)
                        .padding(large ? 14 : 7)
                        .background(Circle().fill(secondary.opacity(0.28)))
                        .shadow(color: primary.opacity(shouldAnimate && animationPhase ? 0.75 : 0.30), radius: shouldAnimate && animationPhase ? 12 : 4)
                    Image(systemName: "goforward.10")
                }
                .foregroundColor(primary)

                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: large ? 4 : 2)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(LinearGradient(colors: [primary, secondary], startPoint: .leading, endPoint: .trailing))
                            .frame(maxWidth: .infinity)
                            .scaleEffect(x: 0.58, anchor: .leading)
                    }
            }
            .padding(large ? 18 : 9)
        }
        .frame(height: large ? 178 : 84)
        .clipShape(RoundedRectangle(cornerRadius: large ? 20 : 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: large ? 20 : 10, style: .continuous)
                .stroke(primary.opacity(0.28), lineWidth: 1)
        )
    }

    private func primaryColor(for skin: MPVPlayerSkin) -> Color {
        switch skin {
        case .defaultSkin: return .white
        case .blackAndGold: return Color(red: 0.92, green: 0.73, blue: 0.27)
        case .prismatic: return Color(red: 0.48, green: 0.94, blue: 1.00)
        case .cyberpunk: return Color(red: 0.10, green: 0.95, blue: 1.00)
        case .custom:
            return storedColor(customPrimaryColorData, fallback: UIColor(red: 0.20, green: 0.86, blue: 1.00, alpha: 1.00))
        }
    }

    private func secondaryColor(for skin: MPVPlayerSkin) -> Color {
        switch skin {
        case .defaultSkin: return .white
        case .blackAndGold: return Color(red: 1.00, green: 0.91, blue: 0.61)
        case .prismatic: return Color(red: 0.98, green: 0.39, blue: 0.84)
        case .cyberpunk: return Color(red: 1.00, green: 0.18, blue: 0.72)
        case .custom:
            return storedColor(customSecondaryColorData, fallback: UIColor(red: 0.72, green: 0.31, blue: 1.00, alpha: 1.00))
        }
    }

    private func previewBackgroundColors(for skin: MPVPlayerSkin) -> [Color] {
        switch skin {
        case .defaultSkin: return [.black.opacity(0.96), Color(white: 0.12)]
        case .blackAndGold: return [.black, Color(red: 0.16, green: 0.11, blue: 0.02)]
        case .prismatic: return [Color(red: 0.05, green: 0.03, blue: 0.13), Color(red: 0.17, green: 0.04, blue: 0.20), Color(red: 0.02, green: 0.13, blue: 0.18)]
        case .cyberpunk: return [Color(red: 0.01, green: 0.03, blue: 0.10), Color(red: 0.10, green: 0.01, blue: 0.14)]
        case .custom: return [.black, secondaryColor(for: skin).opacity(0.24)]
        }
    }

    private func storedColor(_ data: Data, fallback: UIColor) -> Color {
        guard !data.isEmpty,
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) else {
            return Color(fallback)
        }
        return Color(color)
    }

    private func customColorBinding(data: Binding<Data>, fallback: UIColor) -> Binding<Color> {
        Binding(
            get: { storedColor(data.wrappedValue, fallback: fallback) },
            set: { color in
                let uiColor = UIColor(color)
                if let archived = try? NSKeyedArchiver.archivedData(withRootObject: uiColor, requiringSecureCoding: false) {
                    data.wrappedValue = archived
                }
            }
        )
    }
}

struct PlayerSettingsView: View {
    let initialSearchTarget: PlayerSettingsSearchTarget?
    private let showsMPVSettingsOnly: Bool
    @StateObject private var accentColorManager = AccentColorManager.shared
    @StateObject private var store = PlayerSettingsStore()
    @Environment(\.dismiss) private var dismiss
#if !os(tvOS)
    @Environment(\.eclipseSettingsSearchPresentation) private var settingsSearchPresentation
#endif
    @State private var subtitleTextColorName: String = "White"
    @State private var subtitleStrokeColorName: String = "Black"
    @State private var subtitleStrokeWidth: Double = 1.0
    @State private var subtitleFontSizePresetName: String = "Medium"
    @State private var subtitleVerticalOffset: Double = -6.0
    @State private var subtitleClosedCaptionBackground: Bool = false
    @State private var expandedGroups: Set<String> = []
    @State private var didFocusInitialSearchTarget = false
    @AppStorage("enableSubtitlesByDefault") private var enableSubtitlesByDefault = false
    @AppStorage("defaultSubtitleLanguage") private var defaultSubtitleLanguage = "eng"
    @AppStorage("preferredAutoAudioLanguage") private var preferredAutoAudioLanguage = "eng"
    @AppStorage("preferredAnimeAudioLanguage") private var preferredAnimeAudioLanguage = "jpn"
    private let playbackSpeedOptions: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private let doubleTapSeekOptions: [Double] = [5, 10, 15, 20, 30, 45, 60]
    #if !os(tvOS)
    private let mpvForegroundFPSOptions: [Int] = [30, 60]
    #endif

    init(initialSearchTarget: PlayerSettingsSearchTarget? = nil) {
        let reachableTarget = Self.reachableSearchTarget(initialSearchTarget)
        self.initialSearchTarget = reachableTarget
        self.showsMPVSettingsOnly = reachableTarget?.isMPVSettingsTarget == true
    }

    private static func reachableSearchTarget(
        _ target: PlayerSettingsSearchTarget?
    ) -> PlayerSettingsSearchTarget? {
        guard let target else { return nil }
        switch target {
        case .pipWhenLeavingApp:
#if os(tvOS)
            return .pictureInPicture
#else
            let masterEnabled = UserDefaults.standard.object(forKey: "mpvPictureInPictureEnabled") as? Bool ?? true
            return masterEnabled ? target : .pictureInPicture
#endif
        case .appearanceThreshold, .useEpisodePoster, .skipFillerEpisodes:
#if os(tvOS)
            if target != .appearanceThreshold { return .showNextEpisodeButton }
#endif
            let nextEnabled = UserDefaults.standard.object(forKey: "showNextEpisodeButton") as? Bool ?? true
            return nextEnabled ? target : .showNextEpisodeButton
        case .openSubtitlesAutoFallback:
            return UserDefaults.standard.bool(forKey: "playerOpenSubtitlesEnabled")
                ? target
                : .openSubtitles
        default:
            return target
        }
    }

    private var accent: Color { accentColorManager.currentAccentColor }

    private var metalRenderingSettingsAvailable: Bool {
        #if os(tvOS)
        true
        #else
        MPVRenderBackendSupport.metalIsFullySupported
        #endif
    }

    private var canUseMetalMPVAdvancedSettings: Bool {
        #if os(tvOS)
        return store.playbackEngine != .avPlayer
        #else
        PlaybackLaunchPlan.make(
            selection: store.playbackEngine,
            deviceFamily: .current
        ).primary == .mpv
            && store.externalPlayer == .none
        #endif
    }

    private var usesMPVSettings: Bool {
        #if os(tvOS)
        store.playbackEngine != .avPlayer
        #else
        PlaybackLaunchPlan.make(
            selection: store.playbackEngine,
            deviceFamily: .current
        ).primary == .mpv
        #endif
    }

    private var playerSettingsFooter: String {
        #if os(tvOS)
        "Apple TV playback, subtitle, remote, and display settings."
        #else
        "In-app playback, subtitle, and gesture settings."
        #endif
    }

    private var pictureInPictureSettingsDescription: String {
        #if os(tvOS)
        "Show the Picture in Picture button when supported."
        #else
        "Show Picture in Picture controls when the current stream supports them."
        #endif
    }

    private var surroundSoundSettingsDescription: String {
#if os(tvOS)
        "Use surround audio when the stream and audio route support it."
#else
        "Use surround audio on supported receivers. Built-in speakers stay stereo."
#endif
    }

    private var defaultPlayerSettingsDisabled: Bool {
        #if os(tvOS)
        false
        #else
        store.externalPlayer != .none
        #endif
    }

    private var mpvLockedFooter: String {
        #if os(tvOS)
        "Choose Automatic or MPV to use MPV features."
        #else
        "Use MPV, Default external playback, and MoltenVK to unlock advanced features."
        #endif
    }

    private var mpvAdvancedRequirementMessage: String {
        #if os(tvOS)
        if store.playbackEngine == .avPlayer {
            return "Choose Automatic or MPV to use advanced features."
        }
        return "Advanced features use the MoltenVK renderer."
        #else
        if PlaybackLaunchPlan.make(
            selection: store.playbackEngine,
            deviceFamily: .current
        ).primary != .mpv {
            return "Set MPV as the in-app player to use advanced features."
        }
        if store.externalPlayer != .none {
            return "Set external playback to Default to use advanced features."
        }
        if !MPVRenderBackendSupport.metalIsFullySupported {
            return "This build needs the MoltenVK renderer for advanced features."
        }
        return "Advanced features use the MoltenVK renderer."
        #endif
    }

    private var mpvQualityDescription: String {
        switch store.mpvMetalQualityProfile {
        case .auto:
            return "Balances picture quality and heat automatically. Recommended."
        case .balanced:
            return "Uses less heat with little loss in quality."
        case .lowHeat:
            return "Uses the least power, but video may look softer."
        case .sharp:
            return "Prioritizes picture quality and uses more power."
        }
    }

    private var mpvUpscalingDescription: String {
        switch store.mpvUpscalingMode {
        case .off:
            return "No enhancement. Uses the least power."
        case .upscaleTo1080:
            return "Enhances video below 1080p while saving power on HD."
        case .upscaleTo4K:
            return "Enhances video below 4K. Uses more power."
        case .oneLevelAlways:
            return "Enhances every video by one resolution step."
        case .auto:
            return "Sharpest picture. Uses the most power."
        }
    }

    private var mpvHDRDescription: String {
        switch store.mpvHDRMode {
        case .auto:
            return "Uses HDR on compatible displays and SDR everywhere else. Recommended."
        case .hdr:
            return "Forces HDR and may look wrong on non-HDR displays."
        case .sdr:
            return "Converts HDR to SDR for a consistent picture."
        }
    }

    private var comfortAudioDescription: String {
        switch store.audioComfortMode {
        case .original:
            return "Plays the original audio mix."
        case .comfort:
            return "Keeps dialogue and loud moments closer in volume."
        case .dialogue:
            return "Makes voices clearer."
        case .night:
            return "Reduces sudden loud sounds for late-night viewing."
        }
    }

    var body: some View {
        Group {
            if showsMPVSettingsOnly {
                mpvSettingsPage
            } else {
                playerOverview
            }
        }
        .onAppear {
            refreshPlayerSubtitleStyleStateFromDefaults()
        }
    }

    private var playerOverview: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: 22) {
                // MARK: - Default Player
                VStack(spacing: 8) {
                    GlassSection(header: "Default Player") {
                        VStack(spacing: 0) {
                            GlassDetailRow(title: "Default Playback Speed", subtitle: "Speed used when a video starts.") {
                                Picker("", selection: $store.defaultPlaybackSpeed) {
                                    ForEach(playbackSpeedOptions, id: \.self) { speed in
                                        Text(formatSpeed(speed)).tag(speed)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(.white.opacity(0.7))
                            }
                            .id(PlayerSettingsSearchTarget.defaultPlaybackSpeed.anchorID)

#if !os(tvOS)
                            GlassDivider(leadingInset: 16)
                            GlassDetailRow(title: String(format: "Hold Speed: %.1fx", store.holdSpeed), subtitle: "Value of long-press speed playback in the player.") {
                                Stepper("", value: $store.holdSpeed, in: 0.1...3, step: 0.1)
                                    .labelsHidden()
                            }
                            .id(PlayerSettingsSearchTarget.holdSpeed.anchorID)
#endif

                            #if !os(tvOS)
                            GlassDivider(leadingInset: 16)
                            GlassDetailRow(title: "Force Landscape", subtitle: "Force landscape orientation in the video player.") {
                                Toggle("", isOn: $store.landscapeOnly)
                                    .labelsHidden()
                                    .tint(accent)
                            }
                            .id(PlayerSettingsSearchTarget.forceLandscape.anchorID)
                            #endif
                        }
                    }
                    .disabled(defaultPlayerSettingsDisabled)

                    GlassSectionFooter("This setting works exclusively with the Default media player.")
                }

                // MARK: - Media Player
                VStack(spacing: 8) {
                    GlassSection(header: "Media Player") {
                        VStack(spacing: 0) {
                        #if !os(tvOS)
                        GlassDetailRow(title: "Media Player", subtitle: "The app must be installed and accept the provided scheme.") {
                            Picker("", selection: $store.externalPlayer) {
                                ForEach(ExternalPlayer.allCases) { player in
                                    Text(player.rawValue).tag(player)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.white.opacity(0.7))
                        }
                        .id(PlayerSettingsSearchTarget.externalPlayer.anchorID)

                        GlassDivider(leadingInset: 16)
#endif

                        GlassDetailRow(title: "Playback Engine", subtitle: store.playbackEngine.settingsDescription) {
                            Picker("", selection: $store.playbackEngine) {
                                ForEach(PlaybackEngine.availableSelections(deviceFamily: .current)) { engine in
                                    Text(engine.displayName).tag(engine)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.white.opacity(0.7))
                        }
                        .id(PlayerSettingsSearchTarget.inAppPlayer.anchorID)

#if !os(tvOS)
                        GlassDivider(leadingInset: 16)

                        GlassDetailRow(
                            title: "Playback Lock Button",
                            subtitle: "Show a lock on both in-app player overlays. It holds orientation and blocks closing until unlocked; Next Episode remains available."
                        ) {
                            Toggle("", isOn: $store.playerPlaybackLockEnabled)
                                .labelsHidden()
                                .tint(accent)
                        }
                        .id(PlayerSettingsSearchTarget.playbackLock.anchorID)

                        GlassDivider(leadingInset: 16)

                        GlassDetailRow(
                            title: "Services Button",
                            subtitle: "Show a button in both in-app players that opens manual source selection for the current movie or episode. Auto-Select Episodes still applies."
                        ) {
                            Toggle("", isOn: $store.showPlayerServicesButton)
                                .labelsHidden()
                                .tint(accent)
                        }
                        .id(PlayerSettingsSearchTarget.servicesButton.anchorID)

                        GlassDivider(leadingInset: 16)

                        GlassDetailRow(title: "Prefer Downloaded Episodes", subtitle: "When a matching download exists, play it from detail pages instead of streaming.") {
                            Toggle("", isOn: $store.preferDownloadedMedia)
                                .labelsHidden()
                                .tint(accent)
                        }
                        .id(PlayerSettingsSearchTarget.preferDownloadedEpisodes.anchorID)
#endif
                        }
                    }
#if !os(tvOS)
                    if isIPad {
                        GlassSectionFooter("MPV is the default on iPad. If it has repeated playback or rendering problems, try AVPlayer or Automatic. Some instability comes from iPadOS, hardware decoding, or device-specific renderer behavior and is not necessarily an Eclipse bug.")
                    }
#endif
                }

                // MARK: - MPV Player
                if usesMPVSettings {
                    VStack(spacing: 8) {
                        GlassSection(header: "MPV Player") {
                            NavigationLink {
                                searchableMPVSettingsPage
                            } label: {
                                GlassDetailRow(
                                    icon: "play.rectangle.fill",
                                    iconColor: .indigo,
                                    title: "MPV Player Settings",
                                    subtitle: "Rendering, subtitles, gestures, PiP, skipping, and next episode."
                                ) {
                                    valueChevron("Open")
                                }
                            }
                            .buttonStyle(.plain)
                            .id(PlayerSettingsSearchTarget.mpvSettings.anchorID)
                        }
                        GlassSectionFooter("MPV controls load only when you open this page.")
                    }
                } else {
                    #if os(tvOS)
                    VStack(spacing: 8) {
                        GlassSection(header: "Playback") {
                            VStack(spacing: 0) {
                                subtitleDefaultsGroup
                                GlassDivider()
                                subtitleAppearanceGroup
                                GlassDivider()
                                remoteControlsGroup
                                GlassDivider()
                                skipSegmentsGroup
                                GlassDivider()
                                nextEpisodeGroup
                                if PlatformCapabilities.current.supportsPictureInPicture {
                                    GlassDivider()
                                    settingsToggleRow(
                                        title: "Picture in Picture",
                                        detail: "Show Apple's manual Picture in Picture control when the selected stream supports it.",
                                        binding: $store.mpvPictureInPictureEnabled
                                    )
                                }
                            }
                        }
                        GlassSectionFooter("These settings apply to Apple's system player. MPV-only rendering controls remain unavailable while AVPlayer is selected.")
                    }
                    #endif
#if !os(tvOS)
                    VStack(spacing: 8) {
                        GlassSection(header: "AVPlayer Core") {
                            VStack(spacing: 0) {
                                subtitleDefaultsGroup
                                GlassDivider()
                                subtitleAppearanceGroup
                                GlassDivider()
                                avPlayerGesturesGroup
                                GlassDivider()
                                avPlayerNextEpisodeGroup
                                if PlatformCapabilities.current.supportsPictureInPicture {
                                    GlassDivider()
                                    settingsToggleRow(
                                        title: "Picture in Picture",
                                        detail: pictureInPictureSettingsDescription,
                                        binding: $store.mpvPictureInPictureEnabled
                                    )
                                    .id(PlayerSettingsSearchTarget.pictureInPicture.anchorID)
                                    if store.mpvPictureInPictureEnabled {
                                        GlassDivider(leadingInset: 16)
                                        settingsToggleRow(
                                            title: "PiP When Leaving App",
                                            detail: "Start Picture in Picture automatically when you leave Eclipse.",
                                            binding: $store.mpvAppExitPictureInPictureEnabled
                                        )
                                        .id(PlayerSettingsSearchTarget.pipWhenLeavingApp.anchorID)
                                    }
                                }
                            }
                        }
                        GlassSectionFooter("These settings apply to Apple's system player. External subtitle overlays stay in the full player; embedded captions can continue in PiP.")
                    }
#endif
                    VStack(spacing: 8) {
                        GlassSection(header: "MPV Advanced Features") {
                            HStack(spacing: 10) {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.white.opacity(0.5))
                                Text("Requires MoltenVK MPV")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.5))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        GlassSectionFooter(mpvLockedFooter)
                    }
                }
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .onAppear {
                focusInitialSearchTarget(using: scrollProxy)
            }
        }
        .navigationTitle("Media Player")
        .background(SettingsGradientBackground(allowsAnimatedBackground: false).ignoresSafeArea())
        .eclipseDarkToolbar()
    }

    private var mpvSettingsPage: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if usesMPVSettings {
                        GlassSection(header: "MPV Player") {
                            VStack(spacing: 0) {
                                NavigationLink(destination: MPVPlayerSkinSettingsView(selection: $store.mpvPlayerSkin)) {
                                    GlassDetailRow(
                                        icon: "paintpalette.fill",
                                        iconColor: .pink,
                                        title: "Player Skin",
                                        subtitle: "Customize the MPV control overlay."
                                    ) {
                                        valueChevron(store.mpvPlayerSkin.displayName)
                                    }
                                }
                                .buttonStyle(.plain)
                                .id(PlayerSettingsSearchTarget.playerSkin.anchorID)
                                GlassDivider()
                                subtitleDefaultsGroup
                                GlassDivider()
                                subtitleAppearanceGroup
                                GlassDivider()
                                mpvRenderingGroup
                                GlassDivider()
                                #if os(tvOS)
                                remoteControlsGroup
                                GlassDivider()
                                skipSegmentsGroup
                                GlassDivider()
                                nextEpisodeGroup
                                #else
                                gesturesGroup
                                #endif
#if !os(tvOS)
                                GlassDivider()
                                openSubtitlesGroup
                                GlassDivider()
                                skipSegmentsGroup
                                GlassDivider()
                                if canUseMetalMPVAdvancedSettings {
                                    experimentalMPVDisclosure
                                } else {
                                    HStack(spacing: 10) {
                                        Image(systemName: "lock.fill")
                                            .foregroundColor(.white.opacity(0.5))
                                        Text(mpvAdvancedRequirementMessage)
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.5))
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                }
                                GlassDivider()
                                nextEpisodeGroup
#endif
                            }
                        }
                        .id(PlayerSettingsSearchTarget.mpvSettings.anchorID)
                        GlassSectionFooter(playerSettingsFooter)
                    } else {
                        GlassSection(header: "MPV Player") {
                            HStack(spacing: 10) {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.white.opacity(0.5))
                                Text(mpvAdvancedRequirementMessage)
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.5))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .id(PlayerSettingsSearchTarget.mpvSettings.anchorID)
                        GlassSectionFooter(mpvLockedFooter)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .onAppear {
                focusInitialSearchTarget(using: scrollProxy)
            }
        }
        .navigationTitle("MPV Player")
        .background(SettingsGradientBackground(allowsAnimatedBackground: false).ignoresSafeArea())
        .eclipseDarkToolbar()
        .onAppear {
            refreshPlayerSubtitleStyleStateFromDefaults()
        }
    }

    @ViewBuilder
    private var searchableMPVSettingsPage: some View {
#if os(tvOS)
        mpvSettingsPage
#else
        if let settingsSearchPresentation {
            SettingsSearchContainer(
                text: settingsSearchPresentation.text,
                showsResults: true,
                content: mpvSettingsPage,
                results: settingsSearchPresentation.results
            )
        } else {
            mpvSettingsPage
        }
#endif
    }

    // MARK: - MPV disclosure groups

    @ViewBuilder
    private var subtitleDefaultsGroup: some View {
        disclosureHeader("Subtitle Defaults", icon: "captions.bubble", iconColor: .blue, key: "subDefaults")
            .id(PlayerSettingsSearchTarget.subtitleDefaults.anchorID)
        if isExpanded("subDefaults") {
            GlassDivider(leadingInset: 16)
            settingsToggleRow(
                title: "Enable Subtitles by Default",
                detail: "Automatically load and display subtitles when available.",
                binding: $enableSubtitlesByDefault
            )
            .id(PlayerSettingsSearchTarget.enableSubtitlesByDefault.anchorID)

            GlassDivider(leadingInset: 16)

            NavigationLink(destination: PlayerLanguageSelectionView(
                title: "Default Subtitle Language",
                selectedLanguage: $defaultSubtitleLanguage
            )) {
                GlassDetailRow(title: "Default Subtitle Language", subtitle: "Language preference for subtitles.") {
                    valueChevron(getLanguageName(defaultSubtitleLanguage))
                }
            }
            .buttonStyle(.plain)
            .id(PlayerSettingsSearchTarget.defaultSubtitleLanguage.anchorID)

            GlassDivider(leadingInset: 16)

            NavigationLink(destination: PlayerLanguageSelectionView(
                title: "Auto Audio Language",
                selectedLanguage: $preferredAutoAudioLanguage
            )) {
                GlassDetailRow(title: "Auto Audio Language", subtitle: "Preferred audio language for movies and non-anime shows.") {
                    valueChevron(getLanguageName(preferredAutoAudioLanguage))
                }
            }
            .buttonStyle(.plain)
            .id(PlayerSettingsSearchTarget.autoAudioLanguage.anchorID)

            GlassDivider(leadingInset: 16)

            NavigationLink(destination: PlayerLanguageSelectionView(
                title: "Preferred Anime Audio",
                selectedLanguage: $preferredAnimeAudioLanguage
            )) {
                GlassDetailRow(title: "Preferred Anime Audio", subtitle: "Audio language for anime content.") {
                    valueChevron(getLanguageName(preferredAnimeAudioLanguage))
                }
            }
            .buttonStyle(.plain)
            .id(PlayerSettingsSearchTarget.preferredAnimeAudio.anchorID)
        }
    }

    @ViewBuilder
    private var subtitleAppearanceGroup: some View {
        disclosureHeader("Subtitle Appearance", icon: "textformat.size", iconColor: .purple, key: "subAppearance")
            .id(PlayerSettingsSearchTarget.subtitleAppearance.anchorID)
        if isExpanded("subAppearance") {
#if !os(tvOS)
            if usesMPVSettings {
                GlassDivider(leadingInset: 16)
                settingsToggleRow(
                    title: "Subtitle Edit Menu",
                    detail: "Show subtitle style controls in the player.",
                    binding: $store.playerSubtitleAppearanceEnabled
                )
                .id(PlayerSettingsSearchTarget.subtitleEditMenu.anchorID)
            }
#endif

            GlassDivider(leadingInset: 16)
            GlassDetailRow(title: "Subtitle Text Color", subtitle: "Default color for in-app subtitle rendering.") {
                Picker("", selection: subtitleTextColorBinding) {
                    ForEach(subtitleTextColorOptions.map(\.name), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white.opacity(0.7))
            }
            .id(PlayerSettingsSearchTarget.subtitleTextColor.anchorID)

            GlassDivider(leadingInset: 16)
            GlassDetailRow(title: "Subtitle Stroke Color", subtitle: "Outline color for in-app subtitle rendering.") {
                Picker("", selection: subtitleStrokeColorBinding) {
                    ForEach(subtitleStrokeColorOptions.map(\.name), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white.opacity(0.7))
            }
            .id(PlayerSettingsSearchTarget.subtitleStrokeColor.anchorID)

            GlassDivider(leadingInset: 16)
            GlassDetailRow(title: "Subtitle Stroke Width", subtitle: "Outline thickness for in-app subtitle rendering.") {
                Picker("", selection: subtitleStrokeWidthBinding) {
                    Text("None").tag(0.0)
                    Text("Thin").tag(0.5)
                    Text("Normal").tag(1.0)
                    Text("Medium").tag(1.5)
                    Text("Thick").tag(2.0)
                }
                .pickerStyle(.menu)
                .tint(.white.opacity(0.7))
            }
            .id(PlayerSettingsSearchTarget.subtitleStrokeWidth.anchorID)

            GlassDivider(leadingInset: 16)
            GlassDetailRow(title: "Subtitle Font Size", subtitle: "Named size presets for in-app subtitle rendering.") {
                Picker("", selection: subtitleFontSizePresetBinding) {
                    ForEach(subtitleFontSizeOptions.map(\.name), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white.opacity(0.7))
            }
            .id(PlayerSettingsSearchTarget.subtitleFontSize.anchorID)

            GlassDivider(leadingInset: 16)
            GlassDetailRow(title: "Subtitle Vertical Position", subtitle: "Where subtitles sit on screen. Matches the in-player menu.") {
                Picker("", selection: subtitleVerticalOffsetBinding) {
                    Text("Highest").tag(-24.0)
                    Text("Higher").tag(-16.0)
                    Text("Default").tag(-6.0)
                    Text("Lower").tag(6.0)
                    Text("Lowest").tag(18.0)
                }
                .pickerStyle(.menu)
                .tint(.white.opacity(0.7))
            }
            .id(PlayerSettingsSearchTarget.subtitleVerticalPosition.anchorID)

            GlassDivider(leadingInset: 16)
            settingsToggleRow(
                title: "Caption Background",
                detail: "Show a translucent box behind subtitles for better visibility, like YouTube captions.",
                binding: subtitleClosedCaptionBackgroundBinding
            )
            .id(PlayerSettingsSearchTarget.captionBackground.anchorID)

            GlassDivider(leadingInset: 16)
            Button(action: resetPlayerSubtitleStyleDefaults) {
                GlassDetailRow(icon: "arrow.counterclockwise", iconColor: .orange, title: "Reset Subtitle Style", subtitle: "Restore default subtitle text color, stroke, width, and font size.") {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
            .id(PlayerSettingsSearchTarget.resetSubtitleStyle.anchorID)
        }
    }

    @ViewBuilder
    private var mpvRenderingGroup: some View {
        disclosureHeader("MPV Rendering", icon: "display", iconColor: .cyan, key: "rendering")
        if isExpanded("rendering") {
            GlassDivider(leadingInset: 16)
            if metalRenderingSettingsAvailable {
                #if !os(tvOS)
                GlassDetailRow(title: "MoltenVK Quality", subtitle: mpvQualityDescription) {
                    Picker("", selection: $store.mpvMetalQualityProfile) {
                        ForEach(MPVMetalQualityProfile.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white.opacity(0.7))
                }
                .id(PlayerSettingsSearchTarget.moltenVKQuality.anchorID)

                GlassDivider(leadingInset: 16)
                #endif
                #if !os(tvOS)
                GlassDetailRow(title: "Upscaling", subtitle: mpvUpscalingDescription + " Applies on the next playback with MoltenVK only.") {
                    Picker("", selection: $store.mpvUpscalingMode) {
                        ForEach(MPVUpscalingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white.opacity(0.7))
                }
                .id(PlayerSettingsSearchTarget.upscaling.anchorID)
                #endif

                #if !os(tvOS)
                GlassDivider(leadingInset: 16)
                settingsToggleRow(
                    title: "Performance Overlay",
                    detail: "Show playback performance and current quality on screen.",
                    binding: $store.mpvPerformanceOverlayEnabled
                )
                .id(PlayerSettingsSearchTarget.performanceOverlay.anchorID)

                GlassDivider(leadingInset: 16)
                settingsToggleRow(
                    title: "Use Sample-Buffer Renderer",
                    detail: "Use MoltenVK's sample-buffer path instead of gpu-next. Applies on the next playback.",
                    binding: $store.mpvUseLegacyCPURenderer
                )
                .id(PlayerSettingsSearchTarget.sampleBufferRenderer.anchorID)
                #endif

#if !os(tvOS)
                GlassDivider(leadingInset: 16)
                GlassDetailRow(title: "HDR Output", subtitle: mpvHDRDescription) {
                    Picker("", selection: $store.mpvHDRMode) {
                        ForEach(MPVHDRMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white.opacity(0.7))
                }
                .id(PlayerSettingsSearchTarget.hdrOutput.anchorID)
#endif

                GlassDivider(leadingInset: 16)
            }

            settingsToggleRow(
                title: "Surround Sound",
                detail: surroundSoundSettingsDescription,
                binding: $store.mpvSurroundSoundEnabled
            )
            .id(PlayerSettingsSearchTarget.surroundSound.anchorID)

            #if !os(tvOS)
            GlassDivider(leadingInset: 16)
            GlassDetailRow(title: "Comfort Audio", subtitle: comfortAudioDescription) {
                Picker("", selection: $store.audioComfortMode) {
                    ForEach(AudioComfortMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white.opacity(0.7))
            }
            .id(PlayerSettingsSearchTarget.comfortAudio.anchorID)

            if store.audioComfortMode != .original {
                GlassDivider(leadingInset: 16)
                settingsToggleRow(
                    title: "Apply to All",
                    detail: "Apply the audio mode to every kind of content. Turn off to choose specific types below.",
                    binding: Binding(
                        get: { store.audioComfortScopeCategories == Set(AudioComfortContentCategory.allCases) },
                        set: { isOn in store.audioComfortScopeCategories = isOn ? Set(AudioComfortContentCategory.allCases) : [] }
                    )
                )
                .id(PlayerSettingsSearchTarget.comfortAudioApplyToAll.anchorID)
                ForEach(AudioComfortContentCategory.allCases) { category in
                    let detail: String = {
                        switch category {
                        case .anime: return "Japanese/Asian animation."
                        case .westernAnimation: return "Cartoons and other non-anime animation."
                        case .liveAction: return "Films, series - everything that isn't animation."
                        }
                    }()
                    GlassDivider(leadingInset: 16)
                    settingsToggleRow(
                        title: category.displayName,
                        detail: detail,
                        binding: Binding(
                            get: { store.audioComfortScopeCategories.contains(category) },
                            set: { isOn in
                                var set = store.audioComfortScopeCategories
                                if isOn { set.insert(category) } else { set.remove(category) }
                                store.audioComfortScopeCategories = set
                            }
                        )
                    )
                }
            }
            #endif

            #if !os(tvOS)
            GlassDivider(leadingInset: 16)
            GlassDetailRow(title: "Inline Frame Rate", subtitle: "Use 60 fps only for 60 fps video.") {
                Picker("", selection: $store.mpvForegroundFPS) {
                    ForEach(mpvForegroundFPSOptions, id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white.opacity(0.7))
            }
            .id(PlayerSettingsSearchTarget.inlineFrameRate.anchorID)
            #endif

            if PlatformCapabilities.current.supportsPictureInPicture {
                GlassDivider(leadingInset: 16)
                settingsToggleRow(
                    title: "Picture in Picture",
                    detail: pictureInPictureSettingsDescription,
                    binding: $store.mpvPictureInPictureEnabled
                )
                .id(PlayerSettingsSearchTarget.pictureInPicture.anchorID)
            }
            #if !os(tvOS)
            if store.mpvPictureInPictureEnabled {
                GlassDivider(leadingInset: 16)
                settingsToggleRow(
                    title: "PiP When Leaving App",
                    detail: "Start Picture in Picture automatically when you leave Eclipse.",
                    binding: $store.mpvAppExitPictureInPictureEnabled
                )
                .id(PlayerSettingsSearchTarget.pipWhenLeavingApp.anchorID)
            }
            #endif
        }
    }

    @ViewBuilder
    private var remoteControlsGroup: some View {
        disclosureHeader("Remote Controls", icon: "appletvremote.gen4.fill", iconColor: .green, key: "remote")
        if isExpanded("remote") {
            GlassDivider(leadingInset: 16)
            GlassDetailRow(title: "Seek Amount", subtitle: "Seconds moved by remote skip commands and Picture in Picture controls.") {
                Picker("", selection: $store.playerDoubleTapSeekSeconds) {
                    ForEach(doubleTapSeekOptions, id: \.self) { seconds in
                        Text("\(Int(seconds))s").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white.opacity(0.7))
            }
            GlassDivider(leadingInset: 16)
            GlassDetailRow(title: "Match Content", subtitle: "Eclipse automatically requests the video's native frame rate. Apple TV display settings decide whether a mode switch is allowed.") {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
    }

    @ViewBuilder
    private var gesturesGroup: some View {
        disclosureHeader("Playback Gestures", icon: "hand.draw", iconColor: .green, key: "gestures")
            .id(PlayerSettingsSearchTarget.playbackGestures.anchorID)
        if isExpanded("gestures") {
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Brightness Gesture", detail: "Use a left-side vertical drag for screen brightness.", binding: $store.playerBrightnessGestureEnabled)
                .id(PlayerSettingsSearchTarget.brightnessGesture.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Volume Gesture", detail: "Use a right-side vertical drag for system volume.", binding: $store.playerVolumeGestureEnabled)
                .id(PlayerSettingsSearchTarget.volumeGesture.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Two-Finger Play/Pause", detail: "Toggle play and pause with a two-finger tap.", binding: $store.playerTwoFingerTapPlayPauseEnabled)
                .id(PlayerSettingsSearchTarget.twoFingerPlayPause.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Center-Tap Play/Pause", detail: "Tap the center of the video to play or pause without opening controls.", binding: $store.playerCenterTapPlayPauseEnabled)
                .id(PlayerSettingsSearchTarget.centerTapPlayPause.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Double-Tap Seek", detail: "Double-tap the left or right side of the video to seek.", binding: $store.playerDoubleTapSeekEnabled)
                .id(PlayerSettingsSearchTarget.doubleTapSeek.anchorID)
            GlassDivider(leadingInset: 16)
            GlassDetailRow(title: "Seek Amount", subtitle: "Seek \(Int(store.playerDoubleTapSeekSeconds)) seconds with skip buttons, PiP, and double-tap when enabled.") {
#if os(tvOS)
                Picker("", selection: $store.playerDoubleTapSeekSeconds) {
                    ForEach(doubleTapSeekOptions, id: \.self) { seconds in
                        Text("\(Int(seconds))s").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white.opacity(0.7))
#else
                Stepper("", value: $store.playerDoubleTapSeekSeconds, in: 5...60, step: 5)
                    .labelsHidden()
#endif
            }
            .id(PlayerSettingsSearchTarget.seekAmount.anchorID)
        }
    }

    @ViewBuilder
    private var avPlayerGesturesGroup: some View {
        disclosureHeader("Playback Gestures", icon: "hand.draw", iconColor: .green, key: "gestures")
            .id(PlayerSettingsSearchTarget.playbackGestures.anchorID)
        if isExpanded("gestures") {
            GlassDivider(leadingInset: 16)
            settingsToggleRow(
                title: "Double-Tap Seek",
                detail: "Double-tap the left or right side of the video to seek without replacing Apple's controls.",
                binding: $store.playerDoubleTapSeekEnabled
            )
            .id(PlayerSettingsSearchTarget.doubleTapSeek.anchorID)
            GlassDivider(leadingInset: 16)
            GlassDetailRow(
                title: "Seek Amount",
                subtitle: "Seek \(Int(store.playerDoubleTapSeekSeconds)) seconds with double-tap and system skip controls."
            ) {
                Stepper("", value: $store.playerDoubleTapSeekSeconds, in: 5...60, step: 5)
                    .labelsHidden()
            }
            .id(PlayerSettingsSearchTarget.seekAmount.anchorID)
        }
    }

    @ViewBuilder
    private var openSubtitlesGroup: some View {
        disclosureHeader("OpenSubtitles", icon: "globe", iconColor: .indigo, key: "openSubs")
        if isExpanded("openSubs") {
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "OpenSubtitles", detail: "Enable subtitle search through the Stremio OpenSubtitles v3 add-on.", binding: $store.playerOpenSubtitlesEnabled)
                .id(PlayerSettingsSearchTarget.openSubtitles.anchorID)

            if store.playerOpenSubtitlesEnabled {
                GlassDivider(leadingInset: 16)
                settingsToggleRow(title: "Use as Auto Fallback", detail: "When auto subtitles are on, search OpenSubtitles if the selected language is missing locally.", binding: $store.playerOpenSubtitlesAutoFallbackEnabled)
                    .id(PlayerSettingsSearchTarget.openSubtitlesAutoFallback.anchorID)
            }
        }
    }

    @ViewBuilder
    private var skipSegmentsGroup: some View {
        disclosureHeader("Skip Segments", icon: "forward.fill", iconColor: .pink, key: "skip")
            .id(PlayerSettingsSearchTarget.skipSegments.anchorID)
        if isExpanded("skip") {
#if !os(tvOS)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "AniSkip", detail: "Fetch skip segments from AniSkip for anime content.", binding: $store.aniSkipEnabled)
                .id(PlayerSettingsSearchTarget.aniSkip.anchorID)
#endif
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "TheIntroDB", detail: "Fetch skip segments from TheIntroDB for all content.", binding: $store.introDBEnabled)
                .id(PlayerSettingsSearchTarget.theIntroDB.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "IntroDB", detail: "Fetch skip segments from introdb.app using IMDb IDs when other skip sources return nothing.", binding: $store.introDBAppEnabled)
                .id(PlayerSettingsSearchTarget.introDB.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Auto Skip", detail: "Automatically skip intros, outros, recaps, and previews when detected. A skip button is always shown regardless of this setting.", binding: $store.aniSkipAutoSkip)
                .id(PlayerSettingsSearchTarget.autoSkip.anchorID)
#if !os(tvOS)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Skip 85s Fallback", detail: "Show a skip 85 seconds button when no skip data is returned for the current episode.", binding: $store.skip85sEnabled)
                .id(PlayerSettingsSearchTarget.skip85sFallback.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Always Show Skip 85s", detail: "Keep the Skip 85s button visible even when skip segments are available.", binding: $store.skip85sAlwaysVisible)
                .id(PlayerSettingsSearchTarget.alwaysShowSkip85s.anchorID)
#endif
        }
    }

    @ViewBuilder
    private var nextEpisodeGroup: some View {
        disclosureHeader("Next Episode", icon: "forward.end.fill", iconColor: .yellow, key: "nextEp")
            .id(PlayerSettingsSearchTarget.nextEpisode.anchorID)
        if isExpanded("nextEp") {
#if !os(tvOS)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Episode Browser Button", detail: "Show the episode drawer button over the player.", binding: $store.showEpisodeBrowserButton)
                .id(PlayerSettingsSearchTarget.episodeBrowserButton.anchorID)
#endif
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Show Next Episode Button", detail: "Display a button near the end of an episode to quickly open stream search for the next episode.", binding: $store.showNextEpisodeButton)
                .id(PlayerSettingsSearchTarget.showNextEpisodeButton.anchorID)

            if store.showNextEpisodeButton {
                #if !os(tvOS)
                GlassDivider(leadingInset: 16)
                settingsToggleRow(title: "Use Episode Poster", detail: "Show the next episode image, number, and title when available.", binding: $store.showNextEpisodePosterButton)
                    .id(PlayerSettingsSearchTarget.useEpisodePoster.anchorID)

                #if os(iOS)
                GlassDivider(leadingInset: 16)
                settingsToggleRow(
                    title: "Skip Filler Episodes",
                    detail: "For anime, Next Episode and pre-staging jump to the next episode not marked as filler. If filler data is unavailable, Eclipse uses the normal next episode.",
                    binding: $store.nextEpisodeSkipFillerEnabled
                )
                .id(PlayerSettingsSearchTarget.skipFillerEpisodes.anchorID)
                #endif
                #endif

                GlassDivider(leadingInset: 16)
                GlassDetailRow(title: "Appearance Threshold", subtitle: "How far into the episode (%) before the button appears. Default is 90%.") {
                    HStack(spacing: 8) {
                        Text("\(Int(store.nextEpisodeThreshold * 100))%")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
#if os(tvOS)
                        Picker("", selection: $store.nextEpisodeThreshold) {
                            ForEach(Array(stride(from: 0.50, through: 0.99, by: 0.05)), id: \.self) { value in
                                Text("\(Int(value * 100))%").tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white.opacity(0.7))
#else
                        Stepper("", value: $store.nextEpisodeThreshold, in: 0.50...0.99, step: 0.05)
                            .labelsHidden()
#endif
                    }
                }
                .id(PlayerSettingsSearchTarget.appearanceThreshold.anchorID)
            }
        }
    }

    @ViewBuilder
    private var avPlayerNextEpisodeGroup: some View {
        disclosureHeader("Next Episode", icon: "forward.end.fill", iconColor: .yellow, key: "nextEp")
            .id(PlayerSettingsSearchTarget.nextEpisode.anchorID)
        if isExpanded("nextEp") {
            GlassDivider(leadingInset: 16)
            settingsToggleRow(
                title: "Show Next Episode Button",
                detail: "Show a verified next-episode button near the end. It never advances without a tap.",
                binding: $store.showNextEpisodeButton
            )
            .id(PlayerSettingsSearchTarget.showNextEpisodeButton.anchorID)
            if store.showNextEpisodeButton {
                GlassDivider(leadingInset: 16)
                GlassDetailRow(
                    title: "Appearance Threshold",
                    subtitle: "How far into the episode before the button appears."
                ) {
                    HStack(spacing: 8) {
                        Text("\(Int(store.nextEpisodeThreshold * 100))%")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
                        Stepper("", value: $store.nextEpisodeThreshold, in: 0.50...0.99, step: 0.05)
                            .labelsHidden()
                    }
                }
                .id(PlayerSettingsSearchTarget.appearanceThreshold.anchorID)
            }
        }
    }

    // MARK: - Helpers

    private func isExpanded(_ key: String) -> Bool {
        expandedGroups.contains(key)
    }

    private func toggleGroup(_ key: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedGroups.contains(key) {
                expandedGroups.remove(key)
            } else {
                expandedGroups.insert(key)
            }
        }
    }

    private func disclosureHeader(_ title: String, icon: String, iconColor: Color, key: String) -> some View {
        Button {
            toggleGroup(key)
        } label: {
            GlassDetailRow(icon: icon, iconColor: iconColor, title: title) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded(key) ? 90 : 0))
            }
        }
        .buttonStyle(.plain)
    }

    private func valueChevron(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    private func getLanguageName(_ code: String) -> String {
        let languages: [String: String] = [
            "eng": "English",
            "jpn": "Japanese",
            "zho": "Chinese",
            "kor": "Korean",
            "spa": "Spanish",
            "fra": "French",
            "deu": "German",
            "ita": "Italian",
            "por": "Portuguese",
            "rus": "Russian"
        ]
        return languages[code] ?? code.uppercased()
    }

    private func formatSpeed(_ speed: Double) -> String {
        let oneDecimal = (speed * 10).rounded() / 10
        if abs(speed - oneDecimal) < 0.001 {
            return String(format: "%.1fx", speed)
        }
        return String(format: "%.2fx", speed)
    }

    private func focusInitialSearchTarget(using scrollProxy: ScrollViewProxy) {
        guard !didFocusInitialSearchTarget, let initialSearchTarget else { return }
        didFocusInitialSearchTarget = true

        if let expandedGroup = initialSearchTarget.expandedGroup {
            expandedGroups.insert(expandedGroup)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 0.28)) {
                scrollProxy.scrollTo(initialSearchTarget.anchorID, anchor: .center)
            }
        }
    }

    private func settingsToggleRow(title: String, detail: String, binding: Binding<Bool>) -> some View {
        GlassDetailRow(title: title, subtitle: detail) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(accentColorManager.currentAccentColor)
        }
    }

    #if !os(tvOS)
    @ViewBuilder
    private var experimentalMPVDisclosure: some View {
        disclosureHeader("MPV Advanced", icon: "sparkles", iconColor: .purple, key: "experimental")
        if isExpanded("experimental") {
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Stream Warmup Cache", detail: "Keep a small amount of stream data for faster retries and reloads.", binding: $store.experimentalMPVPreloadEnabled)
                .id(PlayerSettingsSearchTarget.streamWarmupCache.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Next Episode Staging", detail: "Warm the next episode near the end of playback. Requires Auto Mode.", binding: $store.experimentalMPVSmoothTransitionEnabled)
                .id(PlayerSettingsSearchTarget.nextEpisodeStaging.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Allow Cellular Warmup", detail: "Allow small stream warmups on cellular data.", binding: $store.experimentalMPVPreloadCellularEnabled)
                .id(PlayerSettingsSearchTarget.allowCellularWarmup.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Auto-Clear Warmup Cache", detail: "Remove warmup data when Eclipse launches. Recommended.", binding: $store.experimentalMPVPreloadAutoClearEnabled)
                .id(PlayerSettingsSearchTarget.autoClearWarmupCache.anchorID)
            GlassDivider(leadingInset: 16)
            GlassDetailRow(title: "Wi-Fi Cache Limit", subtitle: "\(store.experimentalMPVPreloadWifiLimitMB) MB for stream warmup.") {
                Stepper("", value: $store.experimentalMPVPreloadWifiLimitMB, in: ExperimentalFeatureState.mpvPreloadWifiLimitRange, step: 32)
                    .labelsHidden()
            }
            .id(PlayerSettingsSearchTarget.wifiCacheLimit.anchorID)
            GlassDivider(leadingInset: 16)
            GlassDetailRow(title: "Cellular Cache Limit", subtitle: "\(store.experimentalMPVPreloadCellularLimitMB) MB for stream warmup.") {
                Stepper("", value: $store.experimentalMPVPreloadCellularLimitMB, in: ExperimentalFeatureState.mpvPreloadCellularLimitRange, step: 8)
                    .labelsHidden()
            }
            .id(PlayerSettingsSearchTarget.cellularCacheLimit.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Show Remaining Time", detail: "Show time left in player controls.", binding: $store.experimentalMPVShowRemainingTime)
                .id(PlayerSettingsSearchTarget.showRemainingTime.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Precise Progress Adjustment", detail: "Make progress slider adjustments finer.", binding: $store.experimentalMPVPreciseProgress)
                .id(PlayerSettingsSearchTarget.preciseProgressAdjustment.anchorID)
            GlassDivider(leadingInset: 16)
            settingsToggleRow(title: "Ignore Special Subtitle Styles", detail: "Use Eclipse's subtitle style instead of embedded effects. May reduce heat; applies on next playback.", binding: $store.experimentalMPVIgnoreSpecialSubtitleStyles)
                .id(PlayerSettingsSearchTarget.ignoreSpecialSubtitleStyles.anchorID)
            GlassSectionFooter("Warmup and staging are optional speed-ups. They depend on the stream and never affect normal playback.")
        }
    }
    #endif

    private var subtitleTextColorOptions: [(name: String, color: UIColor)] {
        [("White", .white), ("Yellow", .yellow), ("Cyan", .cyan), ("Green", .green), ("Magenta", .magenta)]
    }

    private var subtitleStrokeColorOptions: [(name: String, color: UIColor)] {
        [("Black", .black), ("Dark Gray", .darkGray), ("White", .white), ("None", .clear)]
    }

    private var subtitleTextColorBinding: Binding<String> {
        Binding(
            get: { subtitleTextColorName },
            set: { selectedName in
                subtitleTextColorName = selectedName
                if let selected = subtitleTextColorOptions.first(where: { $0.name == selectedName })?.color {
                    saveSubtitleColor(selected, forKey: "subtitles_foregroundColor")
                }
            }
        )
    }

    private var subtitleStrokeColorBinding: Binding<String> {
        Binding(
            get: { subtitleStrokeColorName },
            set: { selectedName in
                subtitleStrokeColorName = selectedName
                if let selected = subtitleStrokeColorOptions.first(where: { $0.name == selectedName })?.color {
                    saveSubtitleColor(selected, forKey: "subtitles_strokeColor")
                }
            }
        )
    }

    private var subtitleStrokeWidthBinding: Binding<Double> {
        Binding(
            get: { subtitleStrokeWidth },
            set: {
                let clamped = max(0, min($0, 2.0))
                subtitleStrokeWidth = clamped
                UserDefaults.standard.set(clamped, forKey: "subtitles_strokeWidth")
            }
        )
    }

    private var subtitleFontSizeOptions: [(name: String, size: Double)] {
        [
            ("Very Small", 20.0),
            ("Small", 24.0),
            ("Medium", 30.0),
            ("Large", 34.0),
            ("Extra Large", 38.0),
            ("Huge", 42.0),
            ("Extra Huge", 46.0)
        ]
    }

    private var subtitleFontSizePresetBinding: Binding<String> {
        Binding(
            get: { subtitleFontSizePresetName },
            set: { selectedName in
                subtitleFontSizePresetName = selectedName
                if let selected = subtitleFontSizeOptions.first(where: { $0.name == selectedName }) {
                    UserDefaults.standard.set(selected.size, forKey: "subtitles_fontSize")
                }
            }
        )
    }

    private var subtitleVerticalOffsetBinding: Binding<Double> {
        Binding(
            get: { subtitleVerticalOffset },
            set: { selectedValue in
                let clamped = max(-24, min(selectedValue, 24))
                subtitleVerticalOffset = clamped
                UserDefaults.standard.set(clamped, forKey: "playerSubtitleOverlayBottomConstant")
            }
        )
    }

    private var subtitleClosedCaptionBackgroundBinding: Binding<Bool> {
        Binding(
            get: { subtitleClosedCaptionBackground },
            set: {
                subtitleClosedCaptionBackground = $0
                UserDefaults.standard.set($0, forKey: "subtitles_closedCaptionBackground")
            }
        )
    }

    private func loadSubtitleColor(forKey key: String, defaultColor: UIColor) -> UIColor {
        guard let data = UserDefaults.standard.data(forKey: key),
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) else {
            return defaultColor
        }
        return color
    }

    private func saveSubtitleColor(_ color: UIColor, forKey key: String) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func resetPlayerSubtitleStyleDefaults() {
        saveSubtitleColor(.white, forKey: "subtitles_foregroundColor")
        saveSubtitleColor(.black, forKey: "subtitles_strokeColor")
        UserDefaults.standard.set(1.0, forKey: "subtitles_strokeWidth")
        UserDefaults.standard.set(30.0, forKey: "subtitles_fontSize")
        UserDefaults.standard.set(-6.0, forKey: "playerSubtitleOverlayBottomConstant")
        UserDefaults.standard.set(false, forKey: "subtitles_closedCaptionBackground")
        refreshPlayerSubtitleStyleStateFromDefaults()
    }

    private func refreshPlayerSubtitleStyleStateFromDefaults() {
        let textColor = loadSubtitleColor(forKey: "subtitles_foregroundColor", defaultColor: .white)
        subtitleTextColorName = subtitleTextColorOptions.first(where: { $0.color.isEqual(textColor) })?.name ?? "White"

        let strokeColor = loadSubtitleColor(forKey: "subtitles_strokeColor", defaultColor: .black)
        subtitleStrokeColorName = subtitleStrokeColorOptions.first(where: { $0.color.isEqual(strokeColor) })?.name ?? "Black"

        if UserDefaults.standard.object(forKey: "subtitles_strokeWidth") != nil {
            let savedStrokeWidth = UserDefaults.standard.double(forKey: "subtitles_strokeWidth")
            subtitleStrokeWidth = max(0, min(savedStrokeWidth, 2.0))
        } else {
            subtitleStrokeWidth = 1.0
        }

        let savedFontSize = UserDefaults.standard.double(forKey: "subtitles_fontSize")
        let resolvedFontSize = savedFontSize > 0 ? savedFontSize : 30.0
        if let exact = subtitleFontSizeOptions.first(where: { abs($0.size - resolvedFontSize) < 0.01 }) {
            subtitleFontSizePresetName = exact.name
        } else {
            let nearest = subtitleFontSizeOptions.min(by: { abs($0.size - resolvedFontSize) < abs($1.size - resolvedFontSize) })
            subtitleFontSizePresetName = nearest?.name ?? "Medium"
        }

        if UserDefaults.standard.object(forKey: "playerSubtitleOverlayBottomConstant") == nil,
           UserDefaults.standard.object(forKey: "vlcSubtitleOverlayBottomConstant") != nil {
            UserDefaults.standard.set(UserDefaults.standard.double(forKey: "vlcSubtitleOverlayBottomConstant"), forKey: "playerSubtitleOverlayBottomConstant")
        }
        let savedBottomConstant = UserDefaults.standard.double(forKey: "playerSubtitleOverlayBottomConstant")
        subtitleVerticalOffset = UserDefaults.standard.object(forKey: "playerSubtitleOverlayBottomConstant") != nil ? max(-24, min(savedBottomConstant, 24)) : -6.0

        subtitleClosedCaptionBackground = UserDefaults.standard.bool(forKey: "subtitles_closedCaptionBackground")
    }
}
