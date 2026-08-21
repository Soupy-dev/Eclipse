//
//  SettingsView.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI
#if os(tvOS)
import CoreImage.CIFilterBuiltins
import Network
#endif
#if canImport(StoreKit)
import StoreKit
#endif

struct SettingsView: View {
#if os(tvOS)
    private enum TVFocusTarget: Hashable {
        case services
        case diagnostics
        case logger
    }
#endif

    private let onRootDismiss: (() -> Void)?

    init(onRootDismiss: (() -> Void)? = nil) {
        self.onRootDismiss = onRootDismiss
    }

    @AppStorage("githubReleaseAutoCheckEnabled", store: .standard) private var autoCheckGitHubReleases = true
    @AppStorage("githubReleaseUpdateAvailable", store: .standard) private var githubReleaseUpdateAvailable = false
    @AppStorage("githubReleaseLatestVersion", store: .standard) private var githubReleaseLatestVersion = ""
    @AppStorage("githubReleaseURL", store: .standard) private var githubReleaseURL = ""
    @AppStorage("defaultScheduleMode") private var defaultScheduleModeRaw = ScheduleMode.anime.rawValue
    @AppStorage(ScheduleWindow.storageKey) private var scheduleWindowDays = ScheduleWindow.defaultValue.rawValue
    @AppStorage(PerformanceModeSettings.enabledKey) private var performanceModeEnabled = PerformanceModeSettings.defaultEnabled
    @AppStorage(PerformanceModeSettings.skipAniListTraversalForAnimeDetailsKey) private var skipAniListTraversalForAnimeDetails = false
#if !os(tvOS)
    @AppStorage("showKanzen", store: .standard) private var showKanzen: Bool = false
    @State private var settingsSearchText = ""
    @State private var installedServiceSearchEntries: [SettingsSearchEntry] = []
    @State private var installedStremioSearchEntries: [SettingsSearchEntry] = []
#if os(iOS) && !targetEnvironment(macCatalyst)
    @State private var installedNuvioSearchEntries: [SettingsSearchEntry] = []
#endif
    @State private var notificationAuthorizationDisplayName = "Not enabled"
#else
    @FocusState private var tvFocusTarget: TVFocusTarget?
#endif
    @State private var isCheckingGitHubRelease = false
    @StateObject private var profileManager = ProfileManager.shared

    private let koFiURL = URL(string: "https://ko-fi.com/soupydev")!
    private let discordURL = URL(string: "https://discord.gg/cuhAwNwh25")!
    private var sourceCodeURL: URL { Bundle.main.eclipseSourceURL }
    private let originalProjectURL = URL(string: "https://github.com/cranci1/Luna")!
    private let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    private let privacyPolicyURL = URL(string: "https://soupy-dev.github.io/Eclipse/privacy-policy/")!

    private var defaultScheduleMode: ScheduleMode {
        ScheduleMode.sanitized(defaultScheduleModeRaw)
    }

    private var scheduleWindow: ScheduleWindow {
        ScheduleWindow.sanitized(scheduleWindowDays)
    }

    private var supportsGitHubReleaseUpdates: Bool {
        PlatformCapabilities.current.supportsGitHubUpdates
    }

    private var activeProfileSummary: String {
        guard let active = profileManager.activeProfile else { return "1 profile" }
        return profileManager.profiles.count > 1
            ? "\(active.name) · \(profileManager.profiles.count)"
            : active.name
    }

    private var isAdministrable: Bool {
        profileManager.activeProfile?.isKidsProfile != true
    }

#if !os(tvOS)
    private var filteredSettingsSearchEntries: [SettingsSearchEntry] {
        filteredSettingsSearchEntries(for: settingsSearchText)
    }

    private func filteredSettingsSearchEntries(for searchText: String) -> [SettingsSearchEntry] {
        let query = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else { return [] }

        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return settingsSearchEntries
            .filter { entry in
                let haystack = ([entry.title, entry.location] + entry.keywords)
                    .joined(separator: " ")
                    .lowercased()
                return terms.allSatisfy(haystack.contains)
            }
            .sorted { lhs, rhs in
                let lhsTitle = lhs.title.lowercased()
                let rhsTitle = rhs.title.lowercased()
                let lhsStarts = lhsTitle.hasPrefix(query)
                let rhsStarts = rhsTitle.hasPrefix(query)
                if lhsStarts != rhsStarts { return lhsStarts }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private static let baseSettingsSearchEntries: [SettingsSearchEntry] = {
        var entries: [SettingsSearchEntry] = [
            .init(id: "performance-mode", title: "Performance Mode", location: "Basic", icon: "bolt.fill", color: .yellow, keywords: ["fast", "AniList", "catalog"], action: .destination(.performance)),
            .init(id: "media-player", title: "Media Player", location: "Basic", icon: "play.fill", color: .white, keywords: ["MPV", "VLC", "AVPlayer", "default player"], action: .destination(.player)),
            .init(id: "playback-speed", title: "Default Playback Speed", location: "Media Player > Default Player", icon: "gauge.with.dots.needle.50percent", color: .orange, keywords: ["playback speed", "rate", "speed"], action: .destination(.playerTarget(.defaultPlaybackSpeed))),
            .init(id: "hold-speed", title: "Hold Speed", location: "Media Player > Default Player", icon: "hand.tap", color: .orange, keywords: ["long press", "temporary speed", "hold playback speed"], action: .destination(.playerTarget(.holdSpeed))),
            .init(id: "force-landscape", title: "Force Landscape", location: "Media Player > Default Player", icon: "rectangle.rotate", color: .orange, keywords: ["orientation", "rotate", "landscape"], action: .destination(.playerTarget(.forceLandscape))),
            .init(id: "playback-lock", title: "Playback Lock Button", location: "Media Player > Media Player", icon: "lock.rectangle", color: .orange, keywords: ["lock video", "orientation lock", "prevent exit", "child lock"], action: .destination(.playerTarget(.playbackLock))),
            .init(id: "player-services-button", title: "Services Button", location: "Media Player > Media Player", icon: "rectangle.stack.fill", color: .indigo, keywords: ["change source", "choose stream", "services sheet", "addons", "player source"], action: .destination(.playerTarget(.servicesButton))),
            .init(id: "external-player", title: "External Media Player", location: "Media Player > Media Player", icon: "arrow.up.right.square", color: .white, keywords: ["external playback", "VLC", "scheme"], action: .destination(.playerTarget(.externalPlayer))),
            .init(id: "in-app-player", title: "Playback Engine", location: "Media Player > Media Player", icon: "play.rectangle", color: .white, keywords: ["internal player", "automatic", "iPad", "AVPlayer", "MPV", "renderer"], action: .destination(.playerTarget(.inAppPlayer))),
            .init(id: "prefer-downloaded", title: "Prefer Downloaded Episodes", location: "Media Player > Media Player", icon: "arrow.down.circle", color: .green, keywords: ["downloads", "offline", "local playback"], action: .destination(.playerTarget(.preferDownloadedEpisodes))),
            .init(id: "mpv-player-settings", title: "MPV Player Settings", location: "Media Player", icon: "play.rectangle", color: .indigo, keywords: ["MPV", "MoltenVK", "rendering", "subtitles", "gestures", "PiP"], action: .destination(.playerTarget(.mpvSettings))),
            .init(id: "subtitles", title: "Subtitle Defaults", location: "Media Player > Player Controls", icon: "captions.bubble", color: .cyan, keywords: ["subtitle settings", "captions", "OpenSubtitles", "default subtitle language"], action: .destination(.playerTarget(.subtitleDefaults))),
            .init(id: "enable-subtitles", title: "Enable Subtitles by Default", location: "Media Player > Subtitle Defaults", icon: "captions.bubble.fill", color: .cyan, keywords: ["subtitles on", "captions on", "automatic subtitles"], action: .destination(.playerTarget(.enableSubtitlesByDefault))),
            .init(id: "default-subtitle-language", title: "Default Subtitle Language", location: "Media Player > Subtitle Defaults", icon: "character.bubble", color: .cyan, keywords: ["caption language", "subtitle language", "preferred subtitles"], action: .destination(.playerTarget(.defaultSubtitleLanguage))),
            .init(id: "anime-audio", title: "Preferred Anime Audio", location: "Media Player > Subtitle Defaults", icon: "waveform", color: .pink, keywords: ["anime audio", "sub", "dub", "Japanese", "English"], action: .destination(.playerTarget(.preferredAnimeAudio))),
            .init(id: "auto-language", title: "Auto Audio Language", location: "Media Player > Subtitle Defaults", icon: "character.bubble", color: .mint, keywords: ["auto language", "audio", "non-anime", "movies", "shows", "preferred language"], action: .destination(.playerTarget(.autoAudioLanguage))),
            .init(id: "subtitle-appearance", title: "Subtitle Appearance", location: "Media Player > Subtitle Appearance", icon: "textformat.size", color: .purple, keywords: ["subtitle style", "caption style", "text"], action: .destination(.playerTarget(.subtitleAppearance))),
            .init(id: "subtitle-edit-menu", title: "Subtitle Edit Menu", location: "Media Player > Subtitle Appearance", icon: "slider.horizontal.3", color: .purple, keywords: ["subtitle controls", "style controls"], action: .destination(.playerTarget(.subtitleEditMenu))),
            .init(id: "subtitle-text-color", title: "Subtitle Text Color", location: "Media Player > Subtitle Appearance", icon: "textformat", color: .purple, keywords: ["caption color", "font color"], action: .destination(.playerTarget(.subtitleTextColor))),
            .init(id: "subtitle-stroke", title: "Subtitle Stroke", location: "Media Player > Subtitle Appearance", icon: "textformat.alt", color: .purple, keywords: ["outline", "border", "stroke color", "stroke width"], action: .destination(.playerTarget(.subtitleStrokeColor))),
            .init(id: "subtitle-font-size", title: "Subtitle Font Size", location: "Media Player > Subtitle Appearance", icon: "textformat.size", color: .purple, keywords: ["caption size", "text size", "font"], action: .destination(.playerTarget(.subtitleFontSize))),
            .init(id: "subtitle-position", title: "Subtitle Vertical Position", location: "Media Player > Subtitle Appearance", icon: "arrow.up.and.down.text.horizontal", color: .purple, keywords: ["caption position", "subtitle offset", "vertical offset"], action: .destination(.playerTarget(.subtitleVerticalPosition))),
            .init(id: "caption-background", title: "Caption Background", location: "Media Player > Subtitle Appearance", icon: "rectangle.fill", color: .purple, keywords: ["subtitle background", "caption box", "visibility"], action: .destination(.playerTarget(.captionBackground))),
            .init(id: "player-gestures", title: "Playback Gestures", location: "Media Player > Player Controls", icon: "hand.tap", color: .purple, keywords: ["player gestures", "double tap", "seek", "brightness", "volume"], action: .destination(.playerTarget(.playbackGestures))),
            .init(id: "brightness-gesture", title: "Brightness Gesture", location: "Media Player > Playback Gestures", icon: "sun.max", color: .purple, keywords: ["brightness drag", "left side gesture"], action: .destination(.playerTarget(.brightnessGesture))),
            .init(id: "volume-gesture", title: "Volume Gesture", location: "Media Player > Playback Gestures", icon: "speaker.wave.2", color: .purple, keywords: ["volume drag", "right side gesture"], action: .destination(.playerTarget(.volumeGesture))),
            .init(id: "two-finger-play-pause", title: "Two-Finger Play/Pause", location: "Media Player > Playback Gestures", icon: "hand.tap", color: .purple, keywords: ["two finger", "pause gesture", "play gesture"], action: .destination(.playerTarget(.twoFingerPlayPause))),
            .init(id: "center-tap-play-pause", title: "Center-Tap Play/Pause", location: "Media Player > Playback Gestures", icon: "playpause", color: .purple, keywords: ["center tap", "pause gesture", "play gesture"], action: .destination(.playerTarget(.centerTapPlayPause))),
            .init(id: "double-tap-seek", title: "Double-Tap Seek", location: "Media Player > Playback Gestures", icon: "forward.end", color: .purple, keywords: ["double tap", "skip gesture", "seek gesture"], action: .destination(.playerTarget(.doubleTapSeek))),
            .init(id: "seek-amount", title: "Seek Amount", location: "Media Player > Playback Gestures", icon: "gobackward.10", color: .purple, keywords: ["skip seconds", "seek seconds", "jump"], action: .destination(.playerTarget(.seekAmount))),
            .init(id: "picture-in-picture", title: "Picture in Picture", location: "Media Player > Player Controls", icon: "pip", color: .indigo, keywords: ["PiP", "background playback"], action: .destination(.playerTarget(.pictureInPicture))),
            .init(id: "pip-when-leaving", title: "PiP When Leaving App", location: "Media Player > Player Controls", icon: "pip", color: .indigo, keywords: ["automatic picture in picture", "background playback", "exit app"], action: .destination(.playerTarget(.pipWhenLeavingApp))),
            .init(id: "moltenvk-quality", title: "MoltenVK Quality", location: "Media Player > MPV Rendering", icon: "sparkles.rectangle.stack", color: .cyan, keywords: ["Metal", "render quality", "heat", "power"], action: .destination(.playerTarget(.moltenVKQuality))),
            .init(id: "upscaling", title: "Upscaling", location: "Media Player > MPV Rendering", icon: "sparkles.rectangle.stack", color: .cyan, keywords: ["upscale", "resolution", "1080p", "4K", "MoltenVK"], action: .destination(.playerTarget(.upscaling))),
            .init(id: "neural-upscaling", title: "Enhanced Upscaling", location: "Media Player > MPV Rendering", icon: "sparkles.rectangle.stack", color: .cyan, keywords: ["ArtCNN", "FSR", "FidelityFX", "anime upscale", "animation", "shader", "neural", "spatial", "sharpen", "MoltenVK"], action: .destination(.playerTarget(.neuralUpscaling))),
            .init(id: "performance-overlay", title: "Performance Overlay", location: "Media Player > MPV Rendering", icon: "gauge.with.dots.needle.67percent", color: .cyan, keywords: ["fps", "stats", "playback performance", "quality"], action: .destination(.playerTarget(.performanceOverlay))),
            .init(id: "sample-buffer-renderer", title: "Sample-Buffer Renderer", location: "Media Player > MPV Rendering", icon: "rectangle.3.group", color: .cyan, keywords: ["sample buffer", "gpu-next", "renderer"], action: .destination(.playerTarget(.sampleBufferRenderer))),
            .init(id: "hdr-output", title: "HDR Output", location: "Media Player > MPV Rendering", icon: "sun.max.fill", color: .cyan, keywords: ["high dynamic range", "Dolby Vision", "video range"], action: .destination(.playerTarget(.hdrOutput))),
            .init(id: "surround-sound", title: "Surround Sound", location: "Media Player > MPV Rendering", icon: "hifispeaker.2", color: .cyan, keywords: ["audio route", "receiver", "stereo"], action: .destination(.playerTarget(.surroundSound))),
            .init(id: "comfort-audio", title: "Comfort Audio", location: "Media Player > MPV Rendering", icon: "ear", color: .cyan, keywords: ["dynamic range", "night mode", "audio comfort", "volume"], action: .destination(.playerTarget(.comfortAudio))),
            .init(id: "inline-frame-rate", title: "Inline Frame Rate", location: "Media Player > MPV Rendering", icon: "film", color: .cyan, keywords: ["60 fps", "30 fps", "frame rate", "fps"], action: .destination(.playerTarget(.inlineFrameRate))),
            .init(id: "player-skin", title: "Player Skin", location: "Media Player > MPV Player", icon: "paintpalette.fill", color: .pink, keywords: ["MPV UI", "theme", "Black and Gold", "Prismatic", "Cyberpunk", "Custom"], action: .destination(.playerTarget(.playerSkin))),
            .init(id: "open-subtitles", title: "OpenSubtitles", location: "Media Player > OpenSubtitles", icon: "globe", color: .indigo, keywords: ["subtitle search", "Stremio addon", "subtitle provider"], action: .destination(.playerTarget(.openSubtitles))),
            .init(id: "open-subtitles-fallback", title: "Use OpenSubtitles as Auto Fallback", location: "Media Player > OpenSubtitles", icon: "arrow.triangle.branch", color: .indigo, keywords: ["automatic subtitle fallback", "missing subtitles"], action: .destination(.playerTarget(.openSubtitlesAutoFallback))),
            .init(id: "skip-segments", title: "Skip Segments", location: "Media Player > Skip Segments", icon: "forward.fill", color: .pink, keywords: ["intro", "outro", "recap", "AniSkip", "IntroDB"], action: .destination(.playerTarget(.skipSegments))),
            .init(id: "auto-skip", title: "Auto Skip", location: "Media Player > Skip Segments", icon: "forward.fill", color: .pink, keywords: ["skip intro", "skip outro", "automatic skipping"], action: .destination(.playerTarget(.autoSkip))),
            .init(id: "next-episode", title: "Next Episode", location: "Media Player > Next Episode", icon: "forward.end.fill", color: .yellow, keywords: ["episode button", "episode drawer", "up next"], action: .destination(.playerTarget(.nextEpisode))),
            .init(id: "episode-browser-button", title: "Episode Browser Button", location: "Media Player > Next Episode", icon: "list.bullet.rectangle", color: .yellow, keywords: ["episode drawer", "episode list"], action: .destination(.playerTarget(.episodeBrowserButton))),
            .init(id: "show-next-episode", title: "Show Next Episode Button", location: "Media Player > Next Episode", icon: "forward.end.fill", color: .yellow, keywords: ["up next button", "next episode prompt"], action: .destination(.playerTarget(.showNextEpisodeButton))),
            .init(id: "episode-poster", title: "Use Episode Poster", location: "Media Player > Next Episode", icon: "photo", color: .yellow, keywords: ["next episode image", "poster"], action: .destination(.playerTarget(.useEpisodePoster))),
            .init(id: "skip-filler", title: "Skip Filler Episodes", location: "Media Player > Next Episode", icon: "forward.end.fill", color: .yellow, keywords: ["anime filler", "filler skip"], action: .destination(.playerTarget(.skipFillerEpisodes))),
            .init(id: "next-episode-threshold", title: "Next Episode Appearance Threshold", location: "Media Player > Next Episode", icon: "chart.bar.xaxis", color: .yellow, keywords: ["next episode percentage", "90 percent", "button timing"], action: .destination(.playerTarget(.appearanceThreshold))),
            .init(id: "watch-together", title: "Watch Together", location: "Basic", icon: "person.2.wave.2", color: .green, keywords: ["SharePlay", "FaceTime", "sync", "secure", "group", "enable", "disable", "MPV", "MoltenVK"], action: .destination(.watchTogether)),
            .init(id: "appearance", title: "Appearance", location: "Basic", icon: "paintbrush.fill", color: .purple, keywords: ["theme", "layout", "home", "details", "artwork", "UI"], action: .destination(.appearance)),
            .init(id: "appearance-background-style", title: "Background Style", location: "Appearance > Theme", icon: "rectangle.fill", color: .purple, keywords: ["gradient", "solid", "background"], action: .destination(.appearanceTarget(.backgroundStyle))),
            .init(id: "appearance-color-bleed", title: "Color Bleed", location: "Appearance > Theme", icon: "paintbrush.pointed", color: .purple, keywords: ["banner color", "background wash", "intensity"], action: .destination(.appearanceTarget(.colorBleed))),
            .init(id: "appearance-background-intensity", title: "Background Intensity", location: "Appearance > Theme", icon: "sun.max", color: .purple, keywords: ["lighten", "darken", "background brightness"], action: .destination(.appearanceTarget(.backgroundIntensity))),
            .init(id: "appearance-interface", title: "Interface", location: "Appearance > Interface", icon: "rectangle.3.group", color: .purple, keywords: ["modern", "classic", "restart", "layout style"], action: .destination(.appearanceTarget(.interface))),
            .init(id: "appearance-global", title: "Global Appearance", location: "Appearance > Interface", icon: "paintbrush", color: .purple, keywords: ["media mode", "reader mode", "shared theme"], action: .destination(.appearanceTarget(.globalAppearance))),
            .init(id: "appearance-accent", title: "Accent Color", location: "Appearance > Interface", icon: "paintpalette", color: .purple, keywords: ["tint", "buttons", "links", "interactive color"], action: .destination(.appearanceTarget(.accentColor))),
            .init(id: "appearance-animated-background", title: "Animated Background", location: "Appearance > Motion & Startup", icon: "sparkles", color: .purple, keywords: ["ambient motion", "background animation", "motion"], action: .destination(.appearanceTarget(.animatedBackground))),
            .init(id: "appearance-animation-quality", title: "Animation Quality", location: "Appearance > Motion & Startup", icon: "dial.medium", color: .purple, keywords: ["low", "medium", "high", "FPS", "background quality"], action: .destination(.appearanceTarget(.animationQuality))),
            .init(id: "appearance-animation-frame-rate", title: "Animation Frame Rate", location: "Appearance > Motion & Startup", icon: "speedometer", color: .purple, keywords: ["20 FPS", "30 FPS", "smooth", "battery", "background motion"], action: .destination(.appearanceTarget(.animationFrameRate))),
            .init(id: "appearance-app-performance-overlay", title: "App Performance Overlay", location: "Appearance > Motion & Startup", icon: "gauge.with.dots.needle.67percent", color: .cyan, keywords: ["CPU", "RAM", "memory", "thermal", "stats", "logs", "spikes", "app performance", "home performance"], action: .destination(.appearanceTarget(.appPerformanceOverlay))),
            .init(id: "appearance-hide-splash", title: "Hide Splash Screen", location: "Appearance > Motion & Startup", icon: "rectangle.slash", color: .purple, keywords: ["launch screen", "startup", "splash"], action: .destination(.appearanceTarget(.hideSplashScreen))),
            .init(id: "appearance-season-menu", title: "Alternative Season Menu", location: "Appearance > Detail Pages", icon: "list.bullet", color: .purple, keywords: ["season dropdown", "specials", "OVAs"], action: .destination(.appearanceTarget(.alternativeSeasonMenu))),
            .init(id: "appearance-horizontal-episodes", title: "Horizontal Episode List", location: "Appearance > Detail Pages", icon: "rectangle.split.3x1", color: .purple, keywords: ["episode layout", "vertical episodes"], action: .destination(.appearanceTarget(.horizontalEpisodeList))),
            .init(id: "appearance-unaired-episodes", title: "Show Unaired Episodes", location: "Appearance > Detail Pages", icon: "calendar.badge.clock", color: .purple, keywords: ["hide future episodes", "upcoming episodes", "aired episodes", "episode visibility"], action: .destination(.appearanceTarget(.showUnairedEpisodes))),
            .init(id: "appearance-title-art", title: "TMDB Title Art", location: "Appearance > Detail Pages", icon: "text.below.photo", color: .purple, keywords: ["logo artwork", "title logo", "media artwork"], action: .destination(.appearanceTarget(.tmdbTitleArt))),
            .init(id: "appearance-library-bookmarks", title: "Show Bookmarks", location: "Appearance > Library", icon: "bookmark", color: .purple, keywords: ["hide bookmarks", "library sections", "collections only"], action: .destination(.appearanceTarget(.libraryBookmarks))),
            .init(id: "appearance-library-layout", title: "Collection Layout", location: "Appearance > Library", icon: "rectangle.grid.1x2", color: .purple, keywords: ["library collections", "horizontal", "vertical", "grid"], action: .destination(.appearanceTarget(.libraryCollectionLayout))),
            .init(id: "schedule", title: "Schedule", location: "Basic", icon: "calendar", color: .red, keywords: ["calendar", "anime", "western", "default tab", "range", "days"], action: .destination(.schedule)),
            .init(id: "schedule-range", title: "Schedule Range", location: "Schedule", icon: "calendar.badge.clock", color: .red, keywords: ["7 days", "14 days", "21 days", "30 days", "window", "performance", "upcoming episodes"], action: .destination(.schedule)),
            .init(id: "notifications", title: "Notifications", location: "Basic", icon: "bell.badge.fill", color: .orange, keywords: ["alerts", "reminders", "episodes", "airing", "seasons", "local"], action: .destination(.notifications)),
            .init(id: "notification-access", title: "Notification Access", location: "Notifications > Access", icon: "bell.fill", color: .orange, keywords: ["permission", "allowed", "denied", "iOS settings"], action: .destination(.notificationsTarget(.access))),
            .init(id: "episode-reminder-timing", title: "Episode Reminder Timing", location: "Notifications > Timing", icon: "clock.badge", color: .orange, keywords: ["airtime", "before", "episode alert"], action: .destination(.notificationsTarget(.timing))),
            .init(id: "notification-center-history", title: "Notification Center", location: "Notifications > Manage", icon: "bell.and.waves.left.and.right.fill", color: .orange, keywords: ["history", "recent alerts", "delivered", "opened"], action: .destination(.notificationHistory)),
            .init(id: "notification-following", title: "Following", location: "Notifications > Manage", icon: "bell.badge", color: .orange, keywords: ["followed shows", "episodes", "automatic reminders", "subscriptions"], action: .destination(.notificationFollowing)),
            .init(id: "future-season-alerts", title: "Future Season Alerts", location: "Notifications > Following", icon: "calendar.badge.clock", color: .orange, keywords: ["upcoming season", "sequel", "premiere", "announcement"], action: .destination(.notificationFollowing)),
            .init(id: "notification-individual-episodes", title: "Individual Episodes", location: "Notifications > Manage", icon: "calendar.badge.plus", color: .orange, keywords: ["one-off reminder", "schedule bell", "upcoming episode"], action: .destination(.notificationEpisodes)),
            .init(id: "catalogs", title: "Catalogs", location: "Basic", icon: "square.grid.2x2", color: .green, keywords: ["home rows", "discover", "TMDB"], action: .destination(.catalogs)),
            .init(id: "services-auto-update", title: "Auto-Update Sources", location: "Services", icon: "arrow.triangle.2.circlepath", color: .mint, keywords: ["service updates", "auto-update services", "update sources", "startup"], action: .destination(.servicesTarget(.autoUpdateServices))),
            .init(id: "services-auto-mode", title: "Auto Mode", location: "Services", icon: "wand.and.stars", color: .indigo, keywords: ["automatic source", "source order", "auto download"], action: .destination(.servicesTarget(.autoMode))),
            .init(id: "services-auto-select-episodes", title: "Auto-Select Episodes", location: "Services > Auto Mode", icon: "forward.end.fill", color: .indigo, keywords: ["automatic episode selection", "next episode", "auto source"], action: .destination(.servicesTarget(.autoSelectEpisodes))),
            .init(id: "services-auto-quality", title: "Auto Quality", location: "Services > Auto Mode", icon: "dial.medium", color: .indigo, keywords: ["automatic quality", "resolution", "stream quality"], action: .destination(.servicesTarget(.autoQuality))),
            .init(id: "services-quality-preference", title: "Auto Quality Preference", location: "Services > Auto Mode", icon: "slider.horizontal.3", color: .indigo, keywords: ["preferred quality", "1080p", "720p", "best quality"], action: .destination(.servicesTarget(.autoQualityPreference))),
            .init(id: "services-auto-mode-error-intelligence", title: "Auto Mode Error Intelligence", location: "Services > Auto Mode", icon: "checkmark.shield", color: .indigo, keywords: ["dead source", "skip broken", "stream check", "unavailable", "preflight"], action: .destination(.servicesTarget(.autoModeErrorIntelligence))),
            .init(id: "services-block-addon-subtitles", title: "Block Add-on Subtitles", location: "Services > Extra Source Settings > Content Blocking", icon: "captions.bubble.fill", color: .orange, keywords: ["subtitle kill switch", "disable addon subtitles", "content blocking"], action: .destination(.servicesTarget(.blockAddonSubtitles))),
            .init(id: "services-block-addon-catalogs", title: "Block Add-on Catalogs", location: "Services > Extra Source Settings > Content Blocking", icon: "square.grid.2x2.fill", color: .orange, keywords: ["catalog kill switch", "disable addon catalogs", "content blocking"], action: .destination(.servicesTarget(.blockAddonCatalogs))),
            .init(id: "services-include-language", title: "Languages to Include", location: "Services > Extra Source Settings", icon: "checkmark.bubble", color: .green, keywords: ["include language", "allow", "whitelist", "streams", "Stremio"], action: .destination(.servicesTarget(.languagesToInclude))),
            .init(id: "services-exclude-language", title: "Languages to Exclude", location: "Services > Extra Source Settings", icon: "xmark.bubble", color: .red, keywords: ["exclude language", "block", "hide", "streams", "Stremio"], action: .destination(.servicesTarget(.languagesToExclude))),
            .init(id: "services-assume-original-audio", title: "Assume Original Language", location: "Services > Extra Source Settings", icon: "waveform", color: .orange, keywords: ["original language", "untagged streams", "missing language", "TMDB language", "stream language"], action: .destination(.servicesTarget(.assumeOriginalAudio))),
            .init(id: "services-dubbed-anime-english", title: "Treat Dubbed Anime Streams as English", location: "Services > Extra Source Settings", icon: "waveform.and.mic", color: .orange, keywords: ["dubbed anime", "anime dub", "english audio", "english filter", "stream language"], action: .destination(.servicesTarget(.treatDubbedAnimeAsEnglish))),
            .init(id: "services-stremio-style", title: "Stremio-Style Stream List", location: "Services > Extra Source Settings", icon: "rectangle.grid.1x2", color: .blue, keywords: ["stream list", "layout", "flat", "results", "Stremio"], action: .destination(.servicesTarget(.stremioStyleSheet))),
            .init(id: "services-ranking-similarity", title: "Ranking Similarity", location: "Services > Extra Source Settings", icon: "chart.bar.xaxis", color: .orange, keywords: ["similarity percentage", "matching threshold", "rank results", "title match"], action: .destination(.servicesTarget(.rankingSimilarity))),
            .init(id: "services-drop-unmatched", title: "Drop Unmatched Search Results", location: "Services > Extra Source Settings", icon: "line.3.horizontal.decrease.circle", color: .orange, keywords: ["drop streams", "drop unmatched service results", "similarity filter", "mismatched results", "auto mode"], action: .destination(.servicesTarget(.dropMismatchedResults))),
            .init(id: "services-missing-language", title: "Hide Streams Without Language Data", location: "Services > Extra Source Settings", icon: "questionmark.bubble", color: .orange, keywords: ["unknown", "missing", "untagged"], action: .destination(.servicesTarget(.missingLanguageData))),
            .init(id: "services-qualities-to-hide", title: "Qualities to Hide", location: "Services > Extra Source Settings", icon: "eye.slash", color: .orange, keywords: ["hide resolution", "720p", "1080p", "4K", "quality filter"], action: .destination(.servicesTarget(.qualitiesToHide))),
            .init(id: "services-hide-qualityless", title: "Hide Streams Without Detected Quality", location: "Services > Extra Source Settings", icon: "questionmark.bubble", color: .orange, keywords: ["unknown quality", "missing resolution", "untagged quality"], action: .destination(.servicesTarget(.hideStreamsWithoutDetectedQuality))),
            .init(id: "services-extra-rules-sources", title: "Apply Extra Rules To", location: "Services > Extra Source Settings", icon: "line.3.horizontal.decrease.circle", color: .orange, keywords: ["service filter scope", "addon filter scope", "source rules"], action: .destination(.servicesTarget(.applyExtraRulesTo))),
            .init(id: "stremio-addons", title: "Stremio Addons", location: "Services", icon: "shippingbox", color: .blue, keywords: ["addon", "configure", "install"], action: .destination(.services)),
            .init(id: "trackers", title: "Trackers", location: "Basic", icon: "chart.bar.fill", color: .pink, keywords: ["Trakt", "MyAnimeList", "MAL", "AniList", "SIMKL"], action: .destination(.trackers)),
            .init(id: "storage", title: "Storage", location: "Data", icon: "internaldrive", color: .gray, keywords: ["downloads", "cache", "files", "clear"], action: .destination(.storage)),
            .init(id: "backup", title: "Backup & Restore", location: "Data", icon: "arrow.triangle.2.circlepath", color: .teal, keywords: ["export", "import", "settings"], action: .destination(.backup)),
            .init(id: "logger", title: "Logger", location: "Data", icon: "doc.text", color: .yellow, keywords: ["logs", "diagnostics", "errors", "export"], action: .destination(.logger)),
            .init(id: "support", title: "Support Eclipse", location: "Support", icon: "heart.fill", color: .pink, keywords: ["tip", "donate", "Ko-fi", "Discord"], action: .anchor("settings-support")),
            .init(id: "reader-mode", title: "Switch to Reader Mode", location: "Others", icon: "book.fill", color: .orange, keywords: ["Kanzen", "manga", "reader"], action: .readerMode),
            .init(id: "legal", title: "Legal & Source", location: "Others", icon: "scroll.fill", color: .cyan, keywords: ["privacy", "license", "GitHub", "source code"], action: .destination(.legal))
        ]

        if ExperimentalFeatureState.isEnabledAtLaunch
            || MediaStateCloudKitSuspension.needsUserVisibleResume {
            entries.append(.init(id: "cloud-sync", title: "Cloud Sync", location: "Data", icon: "cloud", color: .blue, keywords: ["iCloud", "sync", "library", "progress", "settings", "preferences", "across devices", "resume"], action: .destination(.cloud)))
        }

        if ExperimentalFeatureState.isEnabledAtLaunch {
            entries.append(contentsOf: [
                .init(id: "warmup-cache", title: "Stream Warmup Cache", location: "Media Player > MPV Advanced", icon: "bolt.horizontal.circle", color: .purple, keywords: ["preload", "warmup", "buffer", "faster retries"], action: .destination(.playerTarget(.streamWarmupCache))),
                .init(id: "next-episode-staging", title: "Next Episode Staging", location: "Media Player > MPV Advanced", icon: "forward.end.fill", color: .purple, keywords: ["preload next episode", "prewarm", "smooth transition"], action: .destination(.playerTarget(.nextEpisodeStaging))),
                .init(id: "cellular-warmup", title: "Allow Cellular Warmup", location: "Media Player > MPV Advanced", icon: "antenna.radiowaves.left.and.right", color: .purple, keywords: ["cellular preload", "mobile data"], action: .destination(.playerTarget(.allowCellularWarmup))),
                .init(id: "warmup-auto-clear", title: "Auto-Clear Warmup Cache", location: "Media Player > MPV Advanced", icon: "trash", color: .purple, keywords: ["clear preload", "cache cleanup"], action: .destination(.playerTarget(.autoClearWarmupCache))),
                .init(id: "wifi-cache-limit", title: "Wi-Fi Cache Limit", location: "Media Player > MPV Advanced", icon: "wifi", color: .purple, keywords: ["preload size", "wifi buffer", "MB"], action: .destination(.playerTarget(.wifiCacheLimit))),
                .init(id: "cellular-cache-limit", title: "Cellular Cache Limit", location: "Media Player > MPV Advanced", icon: "antenna.radiowaves.left.and.right", color: .purple, keywords: ["preload size", "cellular buffer", "MB"], action: .destination(.playerTarget(.cellularCacheLimit))),
                .init(id: "remaining-time", title: "Show Remaining Time", location: "Media Player > MPV Advanced", icon: "clock", color: .purple, keywords: ["time left", "player controls"], action: .destination(.playerTarget(.showRemainingTime))),
                .init(id: "precise-progress", title: "Precise Progress Adjustment", location: "Media Player > MPV Advanced", icon: "slider.horizontal.3", color: .purple, keywords: ["fine progress", "scrubbing"], action: .destination(.playerTarget(.preciseProgressAdjustment))),
                .init(id: "ignore-subtitle-styles", title: "Ignore Special Subtitle Styles", location: "Media Player > MPV Advanced", icon: "textformat", color: .purple, keywords: ["embedded subtitle effects", "subtitle override"], action: .destination(.playerTarget(.ignoreSpecialSubtitleStyles)))
            ])
        }
        if !WatchTogetherSettings.isAvailableInCurrentBuild {
            entries.removeAll { $0.id == "watch-together" }
        }
        if PlatformCapabilities.current.supportsGitHubUpdates {
            entries.append(.init(id: "updates", title: "App Updates", location: "Updates", icon: "arrow.triangle.2.circlepath", color: .mint, keywords: ["GitHub releases", "check", "auto check", "latest version"], action: .anchor("settings-updates")))
        }

        return entries
    }()

    private var settingsSearchEntries: [SettingsSearchEntry] {
        var entries = Self.baseSettingsSearchEntries
            + installedServiceSearchEntries
            + installedStremioSearchEntries
#if os(iOS) && !targetEnvironment(macCatalyst)
        entries += installedNuvioSearchEntries
#endif
        if !isAdministrable {
            entries.removeAll { $0.id == "backup" || $0.id == "cloud-sync" }
        }
        return entries
    }

    private static func makeInstalledServiceSearchEntries(_ services: [Service]) -> [SettingsSearchEntry] {
        services.map { service in
            let sourceID = "service:\(service.id.uuidString)"
            return SettingsSearchEntry(
                id: "installed-service-\(service.id.uuidString)",
                title: service.metadata.sourceName,
                location: "Services > Installed Services",
                icon: "shippingbox",
                color: .green,
                keywords: [
                    "service",
                    "installed",
                    service.metadata.author.name,
                    service.metadata.language,
                    service.metadata.version,
                    service.url
                ],
                action: .destination(.servicesTarget(.installedSource(sourceID)))
            )
        }
    }

    private static func makeInstalledStremioSearchEntries(_ addons: [StremioAddon]) -> [SettingsSearchEntry] {
        addons.map { addon in
            let sourceID = "stremio:\(addon.id.uuidString)"
            return SettingsSearchEntry(
                id: "installed-addon-\(addon.id.uuidString)",
                title: addon.manifest.name,
                location: "Services > Installed Stremio Addons",
                icon: "play.circle",
                color: .blue,
                keywords: [
                    "addon",
                    "Stremio",
                    "installed",
                    addon.manifest.id,
                    addon.manifest.description ?? "",
                    addon.configuredURL
                ],
                action: .destination(.servicesTarget(.installedSource(sourceID)))
            )
        }
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    private static func makeInstalledNuvioSearchEntries(
        _ state: NuvioStoredPluginsState
    ) -> [SettingsSearchEntry] {
        let repositoryNames = state.repositories.reduce(into: [String: String]()) { names, repository in
            if names[repository.id] == nil {
                names[repository.id] = repository.displayName
            }
        }
        return state.scrapers.map { scraper in
            SettingsSearchEntry(
                id: "installed-nuvio-\(scraper.id)",
                title: scraper.displayName,
                location: "Services > Installed Nuvio Providers",
                icon: "puzzlepiece.extension",
                color: .purple,
                keywords: [
                    "Nuvio",
                    "plugin",
                    "provider",
                    "installed",
                    scraper.providerKey,
                    scraper.description,
                    scraper.author ?? "",
                    scraper.version,
                    repositoryNames[scraper.repositoryId] ?? ""
                ] + scraper.contentLanguage,
                action: .destination(.servicesTarget(.installedSource(scraper.id)))
            )
        }
    }
#endif

#endif

    var body: some View {
        Group {
        #if os(tvOS)
            settingsContent
        #else
            if #available(iOS 16.0, *) {
                NavigationStack {
                    settingsRootSearchableContent(settingsRootContent)
                }
            } else {
                NavigationView {
                    settingsRootSearchableContent(settingsRootContent)
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        #endif
        }
        .onAppear {
            AppPerformanceRuntimeContext.shared.setSurface("settings")
        }
#if !os(tvOS)

        .onReceive(ServiceManager.shared.$services) { services in
            installedServiceSearchEntries = Self.makeInstalledServiceSearchEntries(services)
        }
        .onReceive(StremioAddonManager.shared.$addons) { addons in
            installedStremioSearchEntries = Self.makeInstalledStremioSearchEntries(addons)
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        .onReceive(NuvioPluginManager.shared.$state) { state in
            installedNuvioSearchEntries = Self.makeInstalledNuvioSearchEntries(state)
        }
#endif
        .onReceive(LocalNotificationManager.shared.$authorizationStatus) { _ in
            notificationAuthorizationDisplayName = LocalNotificationManager.shared.authorizationDisplayName
        }
#endif
    }

#if !os(tvOS)

    private func settingsSearchableContent<Content: View>(
        _ content: @autoclosure @escaping () -> Content
    ) -> some View {
        ScopedSettingsSearchContainer(
            content: content,
            results: { query in AnyView(subpageSettingsSearchResults(for: query)) }
        )
    }

    private func settingsRootSearchableContent<Content: View>(
        _ content: Content
    ) -> some View {
        SettingsSearchContainer(
            text: $settingsSearchText,
            showsResults: false,
            content: content,
            results: { query in AnyView(subpageSettingsSearchResults(for: query)) }
        )
    }

    @ViewBuilder
    private var settingsRootContent: some View {
        if let onRootDismiss {
            settingsContent
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: onRootDismiss) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                        }
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .global)
                        .onEnded { value in
                            let horizontalDistance = value.translation.width
                            let verticalDistance = abs(value.translation.height)
                            let projectedDistance = value.predictedEndTranslation.width
                            let startedAtLeadingEdge = value.startLocation.x <= 36
                            let isMostlyHorizontal = horizontalDistance > verticalDistance * 1.5
                            let reachesDismissDistance = horizontalDistance >= 80
                            let isFastRightFlick = horizontalDistance >= 32 && projectedDistance >= 112

                            guard startedAtLeadingEdge,
                                  horizontalDistance > 0,
                                  isMostlyHorizontal,
                                  (reachesDismissDistance || isFastRightFlick) else {
                                return
                            }

                            onRootDismiss()
                        }
                )
        } else {
            settingsContent
        }
    }
#endif

    private var settingsContent: some View {
        #if os(tvOS)
        List {
            settingsListContent
        }
        .listStyle(.grouped)
        .scrollClipDisabled()
        #else
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: ExperimentalFeatureState.isEnabledAtLaunch ? 22 : 28) {
                    if settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

                GlassSection(header: "Support") {
                    VStack(spacing: 0) {
                        if Bundle.main.allowsExternalDonationLinks {
                            Text("Help support the app. Any amount helps keep the app free for everyone. Thanks for using the app and supporting development!")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.62))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)

                            GlassDivider(leadingInset: 14)

                            Link(destination: koFiURL) {
                                GlassSettingsRow(icon: "cup.and.saucer.fill", iconColor: .cyan, title: "Support on Ko-fi") {
                                    Text("Optional")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                            .buttonStyle(.plain)

                            GlassDivider()
                        } else {
                            #if canImport(StoreKit)
                            NavigationLink(destination: settingsSearchableContent(StoreKitSupportView())) {
                                GlassSettingsRow(icon: "heart.fill", iconColor: .pink, title: "Support Eclipse") {
                                    HStack(spacing: 4) {
                                        Text("Tips")
                                            .font(.subheadline)
                                            .foregroundColor(.white.opacity(0.5))
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.3))
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            GlassDivider()
                            #endif
                        }

                        Link(destination: discordURL) {
                            GlassSettingsRow(icon: "bubble.left.and.bubble.right.fill", iconColor: .indigo, title: "Join Discord") {
                                Text("Community")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .id("settings-support")

                GlassSection(header: "Basic") {
                    VStack(spacing: 0) {
                        NavigationLink(destination: settingsSearchableContent(PerformanceModeSettingsView())) {
                            GlassSettingsRow(icon: "bolt.fill", iconColor: .yellow, title: "Performance Mode") {
                                HStack(spacing: 4) {
                                    Text(performanceModeEnabled || skipAniListTraversalForAnimeDetails ? "On" : "Off")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: settingsSearchableContent(PlayerSettingsView())) {
                            GlassSettingsRow(icon: "play.fill", iconColor: .white, title: "Media Player")
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        if WatchTogetherSettings.isAvailableInCurrentBuild {
                            NavigationLink(destination: settingsSearchableContent(WatchTogetherSettingsView())) {
                                GlassSettingsRow(icon: "person.2.wave.2", iconColor: .green, title: "Watch Together") {
                                    HStack(spacing: 4) {
                                        Text("SharePlay")
                                            .font(.subheadline)
                                            .foregroundColor(.white.opacity(0.5))
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.3))
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            GlassDivider()
                        }

                        NavigationLink(destination: settingsSearchableContent(AlternativeUIView())) {
                            GlassSettingsRow(icon: "paintbrush.fill", iconColor: .purple, title: "Appearance")
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: settingsSearchableContent(ScheduleSettingsView())) {
                            GlassSettingsRow(icon: "calendar", iconColor: .red, title: "Schedule") {
                                HStack(spacing: 4) {
                                    Text("\(defaultScheduleMode.displayName) · \(scheduleWindow.rawValue) days")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: settingsSearchableContent(NotificationSettingsView())) {
                            GlassSettingsRow(icon: "bell.badge.fill", iconColor: .orange, title: "Notifications") {
                                HStack(spacing: 4) {
                                    Text(notificationAuthorizationDisplayName)
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: settingsSearchableContent(CatalogsSettingsView())) {
                            GlassSettingsRow(icon: "square.grid.2x2", iconColor: .green, title: "Catalogs")
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: settingsSearchableContent(ServicesView())) {
                            GlassSettingsRow(icon: "server.rack", iconColor: .indigo, title: "Services")
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: settingsSearchableContent(TrackersSettingsView())) {
                            GlassSettingsRow(icon: "chart.bar.fill", iconColor: .pink, title: "Trackers")
                        }
                        .buttonStyle(.plain)
                    }
                }

                GlassSection(header: "Profiles") {
                    VStack(spacing: 0) {
                        NavigationLink(destination: settingsSearchableContent(ProfilesSettingsView())) {
                            GlassSettingsRow(icon: "person.2.fill", iconColor: .mint, title: "Profiles") {
                                HStack(spacing: 4) {
                                    Text(activeProfileSummary)
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                GlassSection(header: "Data") {
                    VStack(spacing: 0) {
                        NavigationLink(destination: settingsSearchableContent(StorageView())) {
                            GlassSettingsRow(icon: "internaldrive", iconColor: .gray, title: "Storage")
                        }
                        .buttonStyle(.plain)

                        if isAdministrable {
                            GlassDivider()

                            NavigationLink(destination: settingsSearchableContent(BackupManagementView())) {
                                GlassSettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .teal, title: "Backup & Restore")
                            }
                            .buttonStyle(.plain)

                            if ExperimentalFeatureState.isEnabledAtLaunch
                                || MediaStateCloudKitSuspension.needsUserVisibleResume {
                                GlassDivider()

                                NavigationLink(destination: settingsSearchableContent(ExperimentalCloudSyncView())) {
                                    GlassSettingsRow(icon: "cloud", iconColor: .blue, title: "Cloud Sync") {
                                        Text("Available")
                                            .font(.subheadline)
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        GlassDivider()

                        NavigationLink(destination: settingsSearchableContent(LoggerView())) {
                            GlassSettingsRow(icon: "doc.text", iconColor: .yellow, title: "Logger")
                        }
                        .buttonStyle(.plain)
                    }
                }

                GlassSection(header: "Others") {
                    VStack(spacing: 0) {
                        Button {
                            showKanzen = true
                        } label: {
                            GlassSettingsRow(icon: "book.fill", iconColor: .orange, title: "Switch to Reader Mode")
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: settingsSearchableContent(LegalNoticeView(
                            sourceCodeURL: sourceCodeURL,
                            originalProjectURL: originalProjectURL,
                            licenseURL: licenseURL,
                            privacyPolicyURL: privacyPolicyURL
                        ))) {
                            GlassSettingsRow(icon: "scroll.fill", iconColor: .cyan, title: "Legal & Source")
                        }
                        .buttonStyle(.plain)
                    }
                }

                if supportsGitHubReleaseUpdates {
                    GlassSection(header: "Updates") {
                        VStack(spacing: 0) {
                            GlassSettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .mint, title: "Auto-check GitHub Releases") {
                                Toggle("", isOn: $autoCheckGitHubReleases)
                                    .labelsHidden()
                                    .tint(.mint)
                            }

                            GlassDivider()

                            Button {
                                performManualGitHubReleaseCheck()
                            } label: {
                                GlassSettingsRow(icon: "arrow.clockwise", iconColor: .cyan, title: "Check for Updates") {
                                    if isCheckingGitHubRelease {
                                        EclipseLoadingIndicator()
                                            .tint(.white.opacity(0.6))
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.3))
                                    }
                                }
                            }
                            .disabled(isCheckingGitHubRelease)
                            .buttonStyle(.plain)

                            if githubReleaseUpdateAvailable {
                                GlassDivider()

                                if let releaseURL = URL(string: githubReleaseURL), !githubReleaseURL.isEmpty {
                                    Link(destination: releaseURL) {
                                        GlassSettingsRow(icon: "arrow.down.circle.fill", iconColor: .green, title: "Open Latest Release") {
                                            Text(githubReleaseLatestVersion.isEmpty ? "Update Available" : githubReleaseLatestVersion)
                                                .font(.subheadline)
                                                .foregroundColor(.green.opacity(0.9))
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .id("settings-updates")
                }

                VStack(spacing: 4) {
                    Text("Eclipse v\(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.3))

                    if supportsGitHubReleaseUpdates && githubReleaseUpdateAvailable {
                        Text(githubReleaseLatestVersion.isEmpty ? "Update available on GitHub" : "Update available: \(githubReleaseLatestVersion)")
                            .font(.footnote)
                            .foregroundColor(.green.opacity(0.85))
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 30)
                    } else {
                        settingsSearchResults(scrollProxy: scrollProxy)
                    }
                }
                .padding(.top, ExperimentalFeatureState.isEnabledAtLaunch ? 12 : 16)
            }
            .navigationTitle("Settings")
            .background(SettingsGradientBackground().ignoresSafeArea())
            .eclipseDarkToolbar()
        }
        #endif
    }

#if !os(tvOS)
    @ViewBuilder
    private func settingsSearchResults(scrollProxy: ScrollViewProxy) -> some View {
        let entries = filteredSettingsSearchEntries

        if entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Text("No Settings Found")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("Try a setting name, feature, or service.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
        } else {
            GlassSection(header: "Search Results") {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        settingsSearchLink(for: entry, scrollProxy: scrollProxy)
                        if index < entries.count - 1 {
                            GlassDivider()
                        }
                    }
                }
            }
        }
    }

    private func subpageSettingsSearchEntries(for query: String) -> [SettingsSearchEntry] {
        filteredSettingsSearchEntries(for: query).filter { entry in
            if case .anchor = entry.action {
                return false
            }
            return true
        }
    }

    @ViewBuilder
    private func subpageSettingsSearchResults(for query: String) -> some View {
        let entries = subpageSettingsSearchEntries(for: query)

        ScrollView {
            LazyVStack(spacing: 22) {
                if entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                        Text("No Settings Found")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("Try a setting name, feature, or service.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70)
                } else {
                    GlassSection(header: "Search Results") {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                settingsSearchSuggestionLink(for: entry)
                                if index < entries.count - 1 {
                                    GlassDivider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 30)
        }
        .navigationTitle("Search Settings")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }

    @ViewBuilder
    private func settingsSearchSuggestionLink(for entry: SettingsSearchEntry) -> some View {
        switch entry.action {
        case .destination(let destination):
            NavigationLink(destination: LazySettingsPage { settingsSearchDestination(destination) }) {
                settingsSearchRow(entry)
            }
            .buttonStyle(.plain)
        case .anchor:
            Button {
                settingsSearchText = ""
            } label: {
                settingsSearchRow(entry)
            }
            .buttonStyle(.plain)
        case .readerMode:
            Button {
                settingsSearchText = ""
                showKanzen = true
            } label: {
                settingsSearchRow(entry)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func settingsSearchLink(for entry: SettingsSearchEntry, scrollProxy: ScrollViewProxy) -> some View {
        switch entry.action {
        case .destination(let destination):
            NavigationLink(destination: LazySettingsPage { settingsSearchDestination(destination) }) {
                settingsSearchRow(entry)
            }
            .buttonStyle(.plain)
        case .anchor(let anchor):
            Button {
                settingsSearchText = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        scrollProxy.scrollTo(anchor, anchor: .top)
                    }
                }
            } label: {
                settingsSearchRow(entry)
            }
            .buttonStyle(.plain)
        case .readerMode:
            Button {
                settingsSearchText = ""
                showKanzen = true
            } label: {
                settingsSearchRow(entry)
            }
            .buttonStyle(.plain)
        }
    }

    private func settingsSearchRow(_ entry: SettingsSearchEntry) -> some View {
        GlassSettingsRow(icon: entry.icon, iconColor: entry.color, title: entry.title) {
            HStack(spacing: 6) {
                Text(entry.location)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    private func settingsSearchDestination(_ destination: SettingsSearchDestination) -> AnyView {
        switch destination {
        case .performance:
            return AnyView(settingsSearchableContent(PerformanceModeSettingsView()))
        case .player:
            return AnyView(settingsSearchableContent(PlayerSettingsView()))
        case .playerTarget(let target):
            return AnyView(settingsSearchableContent(PlayerSettingsView(initialSearchTarget: target)))
        case .watchTogether:
            return AnyView(settingsSearchableContent(WatchTogetherSettingsView()))
        case .appearance:
            return AnyView(settingsSearchableContent(AlternativeUIView()))
        case .appearanceTarget(let target):
            return AnyView(settingsSearchableContent(AlternativeUIView(initialSearchTarget: target)))
        case .schedule:
            return AnyView(settingsSearchableContent(ScheduleSettingsView()))
        case .notifications:
            return AnyView(settingsSearchableContent(NotificationSettingsView()))
        case .notificationsTarget(let target):
            return AnyView(settingsSearchableContent(NotificationSettingsView(initialSearchTarget: target)))
        case .notificationHistory:
            return AnyView(settingsSearchableContent(NotificationHistorySettingsView()))
        case .notificationFollowing:
            return AnyView(settingsSearchableContent(NotificationFollowingSettingsView()))
        case .notificationEpisodes:
            return AnyView(settingsSearchableContent(NotificationEpisodeRemindersSettingsView()))
        case .catalogs:
            return AnyView(settingsSearchableContent(CatalogsSettingsView()))
        case .services:
            return AnyView(settingsSearchableContent(ServicesView()))
        case .servicesTarget(let target):
            return AnyView(settingsSearchableContent(ServicesView(initialSearchTarget: target)))
        case .trackers:
            return AnyView(settingsSearchableContent(TrackersSettingsView()))
        case .storage:
            return AnyView(settingsSearchableContent(StorageView()))
        case .backup:
            return AnyView(settingsSearchableContent(BackupManagementView()))
        case .cloud:
            return AnyView(settingsSearchableContent(ExperimentalCloudSyncView()))
        case .logger:
            return AnyView(settingsSearchableContent(LoggerView()))
        case .legal:
            return AnyView(settingsSearchableContent(LegalNoticeView(
                sourceCodeURL: sourceCodeURL,
                originalProjectURL: originalProjectURL,
                licenseURL: licenseURL,
                privacyPolicyURL: privacyPolicyURL
            )))
        }
    }
#endif

    @ViewBuilder
    private var settingsListContent: some View {
#if os(tvOS) && canImport(StoreKit)
        TVSupportSettingsSection()
#endif

        Section {
            NavigationLink(destination: PerformanceModeSettingsView()) {
                Text("Performance Mode")
            }
        } header: {
            Text("TMDB Settings")
        }

        Section {
            NavigationLink(destination: PlayerSettingsView()) { Text("Media Player") }
            NavigationLink(destination: AlternativeUIView()) { Text("Appearance") }
                .accessibilityIdentifier("tv.settings.appearance")
            NavigationLink(destination: ScheduleSettingsView()) { Text("Schedule") }
            NavigationLink(destination: CatalogsSettingsView()) { Text("Catalogs") }
                .accessibilityIdentifier("tv.settings.catalogs")
            #if os(tvOS)
            NavigationLink(destination: ServicesView()
                .onAppear {
                    tvFocusTarget = nil
                }
                .onDisappear {
                    restoreTVFocus(to: .services)
                }
            ) { Text("Services") }
            .focused($tvFocusTarget, equals: .services)
            .accessibilityIdentifier("tv.settings.services")
            #else
            NavigationLink(destination: ServicesView()) { Text("Services") }
            #endif
            NavigationLink(destination: TrackersSettingsView()) { Text("Trackers") }
            NavigationLink(destination: ProfilesSettingsView()) { Text("Profiles") }
        }

        Section {
#if os(tvOS)
            NavigationLink(destination: TVDataSettingsView()) { Text("Cloud Sync & Cache") }
#endif
        } header: {
            Text("Data")
        }

        Section {
#if os(tvOS)
            NavigationLink(destination: TVDiagnosticsView()
                .onAppear {

                    tvFocusTarget = nil
                }
                .onDisappear {
                    restoreTVFocus(to: .diagnostics)
                }
            ) {
                Text("Diagnostics")
            }
            .focused($tvFocusTarget, equals: .diagnostics)
            .accessibilityIdentifier("tv.settings.diagnostics")

            NavigationLink(destination: LoggerView()
                .onAppear {
                    tvFocusTarget = nil
                }
                .onDisappear {
                    restoreTVFocus(to: .logger)
                }
            ) {
                Text("Logger")
            }
            .focused($tvFocusTarget, equals: .logger)
            .accessibilityIdentifier("tv.settings.logger")
#endif
            NavigationLink(destination: LegalNoticeView(
                sourceCodeURL: sourceCodeURL,
                originalProjectURL: originalProjectURL,
                licenseURL: licenseURL,
                privacyPolicyURL: privacyPolicyURL
            )) {
                Text("Legal & Source")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Eclipse v\(Bundle.main.appVersion) (\(Bundle.main.buildNumber)). Updates are delivered by the App Store.")
        }
    }

    private func performManualGitHubReleaseCheck() {
        guard supportsGitHubReleaseUpdates, !isCheckingGitHubRelease else { return }
        Task {
            await MainActor.run {
                isCheckingGitHubRelease = true
            }
            await GitHubReleaseChecker.checkForUpdates(force: true)
            await MainActor.run {
                isCheckingGitHubRelease = false
            }
        }
    }

#if os(tvOS)
    private func restoreTVFocus(to target: TVFocusTarget) {
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(180))
            tvFocusTarget = target
        }
    }
#endif
}

#if !os(tvOS)
struct SettingsSearchPresentation {
    let results: (String) -> AnyView
}

struct LazySettingsPage<Content: View>: View {
    private let build: () -> Content

    init(_ build: @escaping () -> Content) {
        self.build = build
    }

    var body: some View {
        build()
    }
}

struct ScopedSettingsSearchContainer<Content: View>: View {
    @State private var text = ""
    let content: () -> Content
    let results: (String) -> AnyView

    var body: some View {
        SettingsSearchContainer(
            text: $text,
            showsResults: true,
            content: content(),
            results: results
        )
    }
}

private struct SettingsSearchPresentationKey: EnvironmentKey {
    static let defaultValue: SettingsSearchPresentation? = nil
}

extension EnvironmentValues {
    var eclipseSettingsSearchPresentation: SettingsSearchPresentation? {
        get { self[SettingsSearchPresentationKey.self] }
        set { self[SettingsSearchPresentationKey.self] = newValue }
    }
}

struct SettingsSearchContainer<Content: View>: View {
    @Binding var text: String
    let showsResults: Bool
    let content: Content
    let results: (String) -> AnyView

    private var hasQuery: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        displayedContent
            .searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search settings"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .environment(
                \.eclipseSettingsSearchPresentation,
                SettingsSearchPresentation(results: results)
            )
    }

    @ViewBuilder
    private var displayedContent: some View {
        if showsResults && hasQuery {
            results(text)
        } else {
            content
        }
    }
}

private enum SettingsSearchDestination: Hashable {
    case performance
    case player
    case playerTarget(PlayerSettingsSearchTarget)
    case watchTogether
    case appearance
    case appearanceTarget(AppearanceSettingsSearchTarget)
    case schedule
    case notifications
    case notificationsTarget(NotificationSettingsSearchTarget)
    case notificationHistory
    case notificationFollowing
    case notificationEpisodes
    case catalogs
    case services
    case servicesTarget(ServicesSettingsSearchTarget)
    case trackers
    case storage
    case backup
    case cloud
    case logger
    case legal
}

private enum NotificationSettingsSearchTarget: String, Hashable {
    case access
    case timing
    case manage
}

private enum SettingsSearchAction: Hashable {
    case destination(SettingsSearchDestination)
    case anchor(String)
    case readerMode
}

private struct SettingsSearchEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let location: String
    let icon: String
    let color: Color
    let keywords: [String]
    let action: SettingsSearchAction

    static func == (lhs: SettingsSearchEntry, rhs: SettingsSearchEntry) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct WatchTogetherSettingsView: View {
    @AppStorage(WatchTogetherSettings.enabledKey)
    private var watchTogetherEnabled = WatchTogetherSettings.defaultEnabled

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundColor(.green)
                    Text("Watch Together")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text("Secure, synchronized playback through Apple SharePlay.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.62))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 18)

                GlassSection(header: "Availability") {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable Watch Together")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                            Text("Available only when playing with MPV's MoltenVK renderer. The player button stays hidden in AVPlayer and while this setting is off.")
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.58))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: $watchTogetherEnabled)
                            .labelsHidden()
                            .tint(.green)
                    }
                    .padding(14)
                }

                GlassSection(header: "How It Works") {
                    VStack(spacing: 0) {
                        WatchTogetherInfoRow(
                            icon: "1.circle.fill",
                            title: "Use MPV with MoltenVK",
                            detail: "Start the movie or episode with the MoltenVK MPV renderer. Watch Together is not available in Normal AVPlayer."
                        )
                        GlassDivider()
                        WatchTogetherInfoRow(
                            icon: "2.circle.fill",
                            title: "Tap Watch Together",
                            detail: "Use the group button in the player and choose SharePlay."
                        )
                        GlassDivider()
                        WatchTogetherInfoRow(
                            icon: "3.circle.fill",
                            title: "Open the same title",
                            detail: "Each participant resolves and plays their own stream; controls then stay synchronized."
                        )
                    }
                }

                GlassSection(header: "Privacy & Security") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("SharePlay messages are limited to people in the Apple group session.", systemImage: "lock.shield.fill")
                        Label("SharePlay displays the title; sync messages contain only play, pause, seek, and an opaque media identifier.", systemImage: "arrow.left.arrow.right")
                        Label("Stream URLs, request headers, cookies, subtitles, and provider credentials never leave your device.", systemImage: "eye.slash.fill")
                    }
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.72))
                    .padding(14)
                }

                Text("Requires SharePlay. Eclipse can start an invitation, or join an existing FaceTime or Messages group. Participants need access to the same title in Eclipse.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.48))
                    .padding(.horizontal, 12)
            }
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
        .navigationTitle("Watch Together")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .onChange(of: watchTogetherEnabled) { enabled in
            if enabled {
                WatchTogetherCoordinator.shared.start()
            } else {
                WatchTogetherCoordinator.shared.declinePendingDisabledSession()
                WatchTogetherCoordinator.shared.leaveSession()
            }
        }
    }
}

private struct WatchTogetherInfoRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

private struct NotificationSettingsView: View {
    let initialSearchTarget: NotificationSettingsSearchTarget?

    @Environment(\.eclipseSettingsSearchPresentation) private var settingsSearchPresentation
    @StateObject private var manager = LocalNotificationManager.shared
    @AppStorage(LocalNotificationManager.episodeLeadTimeKey)
    private var episodeLeadTimeRaw = EpisodeNotificationLeadTime.atAirtime.rawValue
    @AppStorage(LocalNotificationManager.seasonLeadTimeKey)
    private var seasonLeadTimeRaw = SeasonNotificationLeadTime.oneDay.rawValue
    @AppStorage(LocalNotificationManager.includeAnimeSpecialsKey)
    private var includeAnimeSpecials = false
    @State private var notice: LocalNotificationNotice?
    @State private var didScrollToInitialTarget = false
    @State private var showingClearConfirmation = false

    init(initialSearchTarget: NotificationSettingsSearchTarget? = nil) {
        self.initialSearchTarget = initialSearchTarget
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 22) {
                    accessSection
                        .id(NotificationSettingsSearchTarget.access.rawValue)
                    timingSection
                        .id(NotificationSettingsSearchTarget.timing.rawValue)
                    manageSection
                        .id(NotificationSettingsSearchTarget.manage.rawValue)
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .onAppear {
                Task {
                    await manager.refreshAuthorizationStatus()
                    await manager.syncDeliveredNotificationHistory()
                }
                guard let initialSearchTarget, !didScrollToInitialTarget else { return }
                didScrollToInitialTarget = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo(initialSearchTarget.rawValue, anchor: .top)
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .alert(item: $notice) { notice in
            if notice.offersSettings {
                return Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    primaryButton: .default(Text("Open Settings"), action: openSystemSettings),
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            "Remove all notification follows and reminders?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                Task { await manager.clearAllSelections() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var accessSection: some View {
        GlassSection(header: "Access") {
            VStack(spacing: 0) {
                GlassSettingsRow(
                    icon: manager.canScheduleNotifications ? "bell.fill" : "bell.slash.fill",
                    iconColor: manager.canScheduleNotifications ? .green : .orange,
                    title: "Notification Access"
                ) {
                    Text(manager.authorizationDisplayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(manager.authorizationStatus == .denied ? .orange : .white.opacity(0.58))
                }

                GlassDivider()

                Button {
                    if manager.authorizationStatus == .denied {
                        openSystemSettings()
                    } else {
                        Task {
                            let result = await manager.requestAuthorization()
                            notice = LocalNotificationNotice.from(result)
                        }
                    }
                } label: {
                    GlassSettingsRow(
                        icon: manager.authorizationStatus == .denied ? "gear" : "checkmark.circle.fill",
                        iconColor: .orange,
                        title: manager.authorizationStatus == .denied ? "Open iOS Settings" : "Enable Notifications"
                    ) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                .buttonStyle(.plain)
                .disabled(manager.canScheduleNotifications)

                if manager.canScheduleNotifications {
                    GlassDivider()
                    Button {
                        Task { await manager.refreshSchedulesIfNeeded(force: true) }
                    } label: {
                        GlassSettingsRow(icon: "arrow.clockwise", iconColor: .cyan, title: "Refresh Reminders") {
                            if manager.isRefreshing {
                                ProgressView().tint(.white)
                            } else {
                                Text("\(manager.managedPendingRequestCount) scheduled")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.isRefreshing || !manager.hasNotificationSelections)
                }
            }
        }
    }

    private var timingSection: some View {
        GlassSection(header: "Timing") {
            VStack(spacing: 0) {
                GlassSettingsRow(icon: "clock.badge", iconColor: .orange, title: "Episode Reminders") {
                    Picker("Episode Reminders", selection: $episodeLeadTimeRaw) {
                        ForEach(EpisodeNotificationLeadTime.allCases) { timing in
                            Text(timing.displayName).tag(timing.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(.white.opacity(0.72))
                }

                GlassDivider()

                GlassSettingsRow(icon: "calendar.badge.clock", iconColor: .purple, title: "Season Premieres") {
                    Picker("Season Premieres", selection: $seasonLeadTimeRaw) {
                        ForEach(SeasonNotificationLeadTime.allCases) { timing in
                            Text(timing.displayName).tag(timing.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(.white.opacity(0.72))
                }

                GlassDivider()

                GlassSettingsRow(icon: "sparkles.tv", iconColor: .pink, title: "Anime Specials & OVAs") {
                    Toggle("", isOn: $includeAnimeSpecials)
                        .labelsHidden()
                        .tint(.pink)
                }
            }
        }
        .onChange(of: episodeLeadTimeRaw) { _ in
            Task { await manager.rescheduleForPreferenceChange() }
        }
        .onChange(of: seasonLeadTimeRaw) { _ in
            Task { await manager.rescheduleForPreferenceChange() }
        }
        .onChange(of: includeAnimeSpecials) { _ in
            Task {
                await manager.rescheduleForPreferenceChange(
                    invalidateExcludedAnimeSpecialRequests: true
                )
            }
        }
    }

    private var manageSection: some View {
        VStack(spacing: 12) {
            GlassSection(header: "Manage") {
                VStack(spacing: 0) {
                    NavigationLink(destination: searchableDestination(NotificationHistorySettingsView())) {
                        notificationManagementRow(
                            icon: "bell.and.waves.left.and.right.fill",
                            color: .orange,
                            title: "Notification Center",
                            summary: notificationHistorySummary
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Notification Center")
                    .accessibilityValue(notificationHistorySummary)

                    GlassDivider()

                    NavigationLink(destination: searchableDestination(NotificationFollowingSettingsView())) {
                        notificationManagementRow(
                            icon: "bell.badge",
                            color: .purple,
                            title: "Following",
                            summary: followingSummary
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Following")
                    .accessibilityValue(followingSummary)

                    GlassDivider()

                    NavigationLink(destination: searchableDestination(NotificationEpisodeRemindersSettingsView())) {
                        notificationManagementRow(
                            icon: "calendar.badge.plus",
                            color: .cyan,
                            title: "Individual Episodes",
                            summary: episodeReminderSummary
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Individual Episodes")
                    .accessibilityValue(episodeReminderSummary)
                }
            }

            if manager.hasNotificationSelections {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Text("Remove All Notification Selections")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var notificationHistorySummary: String {
        countSummary(
            manager.notificationHistoryCount,
            empty: "No recent alerts",
            singular: "recent alert",
            plural: "recent alerts"
        )
    }

    private var followingSummary: String {
        countSummary(
            manager.subscriptions.count,
            empty: "No shows",
            singular: "show",
            plural: "shows"
        )
    }

    private var episodeReminderSummary: String {
        countSummary(
            manager.episodeReminders.count,
            empty: "No reminders",
            singular: "reminder",
            plural: "reminders"
        )
    }

    private func countSummary(
        _ count: Int,
        empty: String,
        singular: String,
        plural: String
    ) -> String {
        if count == 0 { return empty }
        return count == 1 ? "1 \(singular)" : "\(count) \(plural)"
    }

    private func notificationManagementRow(
        icon: String,
        color: Color,
        title: String,
        summary: String
    ) -> some View {
        GlassSettingsRow(icon: icon, iconColor: color, title: title) {
            HStack(spacing: 5) {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    private func searchableDestination<Content: View>(
        _ content: @autoclosure @escaping () -> Content
    ) -> AnyView {
        guard let presentation = settingsSearchPresentation else {
            return AnyView(LazySettingsPage(content))
        }
        return AnyView(ScopedSettingsSearchContainer(
            content: content,
            results: presentation.results
        ))
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct NotificationHistorySettingsView: View {
    private static let pageSize = 40

    @StateObject private var manager = LocalNotificationManager.shared
    @Environment(\.eclipseWindowSceneSessionIdentifier) private var windowSceneSessionIdentifier
    @State private var entries: [LocalNotificationHistoryEntry] = []
    @State private var nextCursor: LocalNotificationHistoryCursor?
    @State private var hasMore = false
    @State private var didLoad = false
    @State private var isLoading = false
    @State private var isApplyingLocalMutation = false
    @State private var pendingReload = false
    @State private var showingClearConfirmation = false
    @State private var showingHistorySaveError = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                GlassSection(header: "Recent Alerts") {
                    if !didLoad && isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text("Loading notification history…")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.62))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    } else if entries.isEmpty {
                        NotificationSettingsEmptyRow(
                            icon: "bell.slash",
                            title: "No observed alerts",
                            detail: "Notifications Eclipse observes after delivery will appear here."
                        )
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                NotificationHistorySettingsRow(
                                    entry: entry,
                                    isDisabled: isLoading || isApplyingLocalMutation,
                                    onOpen: {
                                        manager.openNotificationHistoryEntry(
                                            entry,
                                            sceneSessionIdentifier: windowSceneSessionIdentifier
                                        )
                                    },
                                    onDelete: { await delete(entry) }
                                )

                                if index < entries.count - 1 || hasMore {
                                    GlassDivider(leadingInset: 16)
                                }
                            }

                            if hasMore {
                                Button {
                                    Task { await loadMore() }
                                } label: {
                                    HStack(spacing: 9) {
                                        if isLoading {
                                            ProgressView()
                                                .tint(.white)
                                        } else {
                                            Image(systemName: "arrow.down.circle")
                                        }
                                        Text(loadMoreTitle)
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .foregroundColor(.orange)
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 48)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoading)
                                .accessibilityHint("Loads the next 40 observed alerts.")
                            }
                        }
                    }
                }

                GlassSectionFooter("Eclipse keeps the latest 1,000 observed alerts on this device. This is not a guaranteed complete log: an alert cleared from iOS Notification Center before Eclipse next opens can be missing.")
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Notification Center")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if manager.notificationHistoryCount > 0 {
                    Button("Clear All", role: .destructive) {
                        showingClearConfirmation = true
                    }
                    .disabled(isLoading || isApplyingLocalMutation)
                }
            }
        }
        .task {
            await reloadHistory(syncDelivered: true, retainingLoadedCount: false)
        }
        .refreshable {
            await reloadHistory(syncDelivered: true, retainingLoadedCount: true)
        }
        .onChange(of: manager.notificationHistoryRevision) { _ in
            guard didLoad else { return }
            guard !isLoading, !isApplyingLocalMutation else {
                pendingReload = true
                return
            }
            Task {
                await reloadHistory(syncDelivered: false, retainingLoadedCount: true)
            }
        }
        .confirmationDialog(
            "Clear all observed history and remove Eclipse alerts from iOS Notification Center?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                Task { await clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn’t Update History", isPresented: $showingHistorySaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Eclipse could not save that change. Your notification history and the matching iOS alert were left intact.")
        }
    }

    private var loadMoreTitle: String {
        let remaining = max(0, manager.notificationHistoryCount - entries.count)
        return remaining > 0 ? "Load More (\(remaining) remaining)" : "Load More"
    }

    private func reloadHistory(
        syncDelivered: Bool,
        retainingLoadedCount: Bool
    ) async {
        guard !isLoading else {
            pendingReload = true
            return
        }
        let startingRevision = manager.notificationHistoryRevision
        isLoading = true
        defer {
            isLoading = false
            didLoad = true
            if manager.notificationHistoryRevision != startingRevision {
                pendingReload = true
            }
            schedulePendingReloadIfNeeded()
        }

        if syncDelivered {
            await manager.syncDeliveredNotificationHistory()
        }

        let targetCount = retainingLoadedCount
            ? max(Self.pageSize, entries.count)
            : Self.pageSize
        var reloaded: [LocalNotificationHistoryEntry] = []
        var cursor: LocalNotificationHistoryCursor?
        var lastPage: LocalNotificationHistoryPage?

        repeat {
            let page = await manager.notificationHistoryPage(
                after: cursor,
                limit: Self.pageSize
            )
            reloaded.append(contentsOf: page.entries)
            cursor = page.nextCursor
            lastPage = page
            if !page.hasMore || page.entries.isEmpty { break }
        } while reloaded.count < targetCount

        guard !Task.isCancelled else { return }
        entries = reloaded
        nextCursor = lastPage?.nextCursor
        hasMore = lastPage?.hasMore ?? false
    }

    private func loadMore() async {
        guard !isLoading, hasMore, let nextCursor else { return }
        let startingRevision = manager.notificationHistoryRevision
        isLoading = true
        defer {
            isLoading = false
            if manager.notificationHistoryRevision != startingRevision {
                pendingReload = true
            }
            schedulePendingReloadIfNeeded()
        }

        let page = await manager.notificationHistoryPage(
            after: nextCursor,
            limit: Self.pageSize
        )
        guard !Task.isCancelled else { return }
        let existingIDs = Set(entries.map(\.id))
        entries.append(contentsOf: page.entries.filter { !existingIDs.contains($0.id) })
        self.nextCursor = page.nextCursor
        hasMore = page.hasMore
    }

    private func delete(_ entry: LocalNotificationHistoryEntry) async {
        guard !isApplyingLocalMutation, !isLoading else { return }
        isApplyingLocalMutation = true
        let retainedCount = entries.count
        let succeeded = await manager.deleteNotificationHistoryEntry(entry)
        guard succeeded else {
            isApplyingLocalMutation = false
            showingHistorySaveError = true
            return
        }
        entries.removeAll { $0.id == entry.id }
        pendingReload = false
        await reloadHistory(
            syncDelivered: false,
            retainingLoadedCount: retainedCount > Self.pageSize
        )
        isApplyingLocalMutation = false
        schedulePendingReloadIfNeeded()
    }

    private func clearHistory() async {
        guard !isApplyingLocalMutation, !isLoading else { return }
        isApplyingLocalMutation = true
        let succeeded = await manager.clearNotificationHistory()
        guard succeeded else {
            isApplyingLocalMutation = false
            showingHistorySaveError = true
            return
        }
        pendingReload = false
        await reloadHistory(syncDelivered: false, retainingLoadedCount: false)
        isApplyingLocalMutation = false
        schedulePendingReloadIfNeeded()
    }

    private func schedulePendingReloadIfNeeded() {
        guard pendingReload, !isLoading, !isApplyingLocalMutation else { return }
        pendingReload = false
        Task {
            await reloadHistory(syncDelivered: false, retainingLoadedCount: true)
        }
    }
}

private struct NotificationFollowingSettingsView: View {
    @StateObject private var manager = LocalNotificationManager.shared
    @State private var notice: LocalNotificationNotice?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                GlassSection(header: "Following") {
                    if manager.subscriptions.isEmpty {
                        NotificationSettingsEmptyRow(
                            icon: "bell.badge",
                            title: "No followed shows",
                            detail: "Use the bell on a show’s detail page to follow episodes or future seasons."
                        )
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(manager.subscriptions.enumerated()), id: \.element.id) { index, subscription in
                                NotificationSubscriptionSettingsRow(
                                    subscription: subscription,
                                    onNotice: { notice = $0 }
                                )
                                if index < manager.subscriptions.count - 1 {
                                    GlassDivider(leadingInset: 16)
                                }
                            }
                        }
                    }
                }

                GlassSectionFooter("Each followed title can alert for upcoming episodes, future seasons, or both. Turning both options off removes the title from Following.")
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Following")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .alert(item: $notice) { notificationSettingsAlert($0) }
    }
}

private struct NotificationEpisodeRemindersSettingsView: View {
    @StateObject private var manager = LocalNotificationManager.shared

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                GlassSection(header: "Individual Episodes") {
                    if manager.episodeReminders.isEmpty {
                        NotificationSettingsEmptyRow(
                            icon: "calendar.badge.plus",
                            title: "No episode reminders",
                            detail: "Use the bell beside an upcoming entry in Schedule to create a one-off reminder."
                        )
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(manager.episodeReminders.enumerated()), id: \.element.id) { index, reminder in
                                NotificationEpisodeReminderSettingsRow(reminder: reminder)
                                if index < manager.episodeReminders.count - 1 {
                                    GlassDivider(leadingInset: 16)
                                }
                            }
                        }
                    }
                }

                GlassSectionFooter("These are one-off episode choices. Automatic reminders from followed shows are managed separately under Following.")
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Individual Episodes")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }
}

private struct NotificationSettingsEmptyRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}

private struct NotificationHistorySettingsRow: View {
    let entry: LocalNotificationHistoryEntry
    let isDisabled: Bool
    let onOpen: () -> Void
    let onDelete: () async -> Void

    @State private var isDeleting = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: icon)
                        .foregroundColor(iconColor)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        if !entry.subtitle.isEmpty {
                            Text(entry.subtitle)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.58))
                                .lineLimit(1)
                        }

                        if !entry.body.isEmpty {
                            Text(entry.body)
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.62))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text("\(kindLabel) · \(Self.dateFormatter.string(from: entry.deliveredAt))")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.42))
                    }

                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(historyAccessibilityLabel)
            .accessibilityHint("Opens the related item in Schedule.")

            Button(role: .destructive) {
                guard !isDeleting else { return }
                isDeleting = true
                Task {
                    await onDelete()
                    isDeleting = false
                }
            } label: {
                ZStack {
                    if isDeleting {
                        ProgressView()
                            .tint(.red)
                    } else {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.9))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled || isDeleting)
            .accessibilityLabel("Delete \(displayTitle) from notification history")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var displayTitle: String {
        let candidates = [entry.title, entry.mediaTitle]
        return candidates.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? "Eclipse Notification"
    }

    private var icon: String {
        switch entry.kind {
        case .episode: return "bell.fill"
        case .batch: return "bell.badge.fill"
        case .season: return "calendar.badge.clock"
        case .scheduleFallback: return "calendar"
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .episode, .batch: return .orange
        case .season: return .purple
        case .scheduleFallback: return .cyan
        }
    }

    private var kindLabel: String {
        switch entry.kind {
        case .episode: return "Episode"
        case .batch: return "Episode batch"
        case .season: return "Season"
        case .scheduleFallback: return "Schedule"
        }
    }

    private var historyAccessibilityLabel: String {
        let body = entry.body.isEmpty ? "" : ", \(entry.body)"
        return "\(displayTitle)\(body), \(kindLabel), delivered \(Self.dateFormatter.string(from: entry.deliveredAt))"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct NotificationEpisodeReminderSettingsRow: View {
    @StateObject private var manager = LocalNotificationManager.shared
    @State private var isDeleting = false

    let reminder: LocalEpisodeNotificationReminder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .foregroundColor(.orange)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(role: .destructive) {
                guard !isDeleting else { return }
                isDeleting = true
                Task {
                    await manager.removeEpisodeReminder(id: reminder.id)
                    isDeleting = false
                }
            } label: {
                ZStack {
                    if isDeleting {
                        ProgressView()
                            .tint(.red)
                    } else {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.9))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
            .accessibilityLabel("Remove reminder for \(summary) of \(reminder.title)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        let episode: String
        if reminder.source == .western, let season = reminder.season, season > 0 {
            episode = "Season \(season), episode \(reminder.episode)"
        } else {
            episode = "Episode \(reminder.episode)"
        }
        return "\(episode) · \(Self.dateFormatter.string(from: reminder.airingAt))"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private func notificationSettingsAlert(_ notice: LocalNotificationNotice) -> Alert {
    if notice.offersSettings {
        return Alert(
            title: Text(notice.title),
            message: Text(notice.message),
            primaryButton: .default(Text("Open Settings")) {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            },
            secondaryButton: .cancel()
        )
    }
    return Alert(
        title: Text(notice.title),
        message: Text(notice.message),
        dismissButton: .default(Text("OK"))
    )
}

private struct NotificationSubscriptionSettingsRow: View {
    @StateObject private var manager = LocalNotificationManager.shared
    @State private var isUpdating = false
    let subscription: LocalMediaNotificationSubscription
    let onNotice: (LocalNotificationNotice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                Image(systemName: subscription.source == .anime ? "sparkles" : "tv.fill")
                    .foregroundColor(subscription.source == .anime ? .pink : .blue)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subscription.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(subscription.source.displayName)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.48))
                }
                Spacer()
                Button(role: .destructive) {
                    guard !isUpdating else { return }
                    isUpdating = true
                    Task { await manager.removeSubscription(id: subscription.id) }
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red.opacity(0.88))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isUpdating)
                .accessibilityLabel("Unfollow \(subscription.title)")
            }

            HStack(spacing: 16) {
                compactToggle(title: "Episodes", isOn: subscription.episodeNotifications) { enabled in
                    update(episodes: enabled, seasons: subscription.futureSeasonNotifications)
                }
                compactToggle(title: "Future Seasons", isOn: subscription.futureSeasonNotifications) { enabled in
                    update(episodes: subscription.episodeNotifications, seasons: enabled)
                }
            }
            .padding(.leading, 39)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func compactToggle(title: String, isOn: Bool, action: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundColor(.white.opacity(0.65))
            Toggle("", isOn: Binding(get: { isOn }, set: action))
                .labelsHidden()
                .scaleEffect(0.82)
                .tint(.orange)
                .disabled(isUpdating)
                .accessibilityLabel(title)
        }
    }

    private func update(episodes: Bool, seasons: Bool) {
        guard !isUpdating else { return }
        isUpdating = true
        Task {
            let result = await manager.updateMediaSubscription(
                source: subscription.source,
                tmdbID: subscription.tmdbID,
                title: subscription.title,
                titleAliases: subscription.titleAliases,
                animeMediaIDs: subscription.animeMediaIDs,
                animeSpecialMediaIDs: subscription.animeSpecialMediaIDs,
                westernSeasonIDs: subscription.knownWesternSeasonIDs,
                episodeNotifications: episodes,
                futureSeasonNotifications: seasons
            )
            if let notice = LocalNotificationNotice.from(result) {
                onNotice(notice)
            }
            isUpdating = false
        }
    }
}
#endif

#if os(tvOS)
private struct TVDiagnosticsView: View {
    @StateObject private var network = TVNetworkStatusMonitor()
    @StateObject private var syncManager = MediaStateSyncManager.shared

    var body: some View {
        List {
            Section("Build") {
                LabeledContent("App", value: "Eclipse")
                    .focusable()
                LabeledContent("Version", value: Bundle.main.appVersion)
                    .focusable()
                LabeledContent("Build", value: Bundle.main.buildNumber)
                    .focusable()
            }

            Section("Playback") {
                LabeledContent("Selected Engine", value: PlaybackEngine.selected.displayName)
                    .focusable()
                LabeledContent("MPV Metal", value: MPVTVRenderer.isAvailable ? "Available" : "Unavailable")
                    .focusable()
                LabeledContent("Fallback", value: "AVPlayer")
                    .focusable()
            }

            Section("Status") {
                LabeledContent("Network", value: network.summary)
                    .focusable()
                LabeledContent("Cloud Sync", value: syncManager.phase.title)
                    .focusable()
                if syncManager.lastErrorMessage != nil {
                    LabeledContent("Last Sync Error", value: "CloudKit availability")
                        .focusable()
                }
            }

            Section {
                Text("Provider URLs, authorization tokens, cookies, and request headers are intentionally omitted.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .focusable()
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("Diagnostics")
        .accessibilityIdentifier("tv.settings.diagnostics.screen")
    }
}

@MainActor
private final class TVNetworkStatusMonitor: ObservableObject {
    @Published private(set) var summary = "Checking"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.eclipse.tv.network-status")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                switch path.status {
                case .satisfied:
                    self.summary = path.isExpensive ? "Online (constrained route)" : "Online"
                case .requiresConnection:
                    self.summary = "Connection required"
                case .unsatisfied:
                    self.summary = "Offline"
                @unknown default:
                    self.summary = "Unknown"
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

private struct TVDataSettingsView: View {
    @AppStorage(
        ExperimentalFeatureState.iCloudSyncEnabledKey,
        store: ProfileSettingsStore.device
    ) private var iCloudSyncEnabled = false
    @StateObject private var syncManager = MediaStateSyncManager.shared
    @StateObject private var profileManager = ProfileManager.shared
    @State private var cacheMessage = ""
    @State private var showResetCacheConfirmation = false

    private var isAdministrable: Bool {
        profileManager.activeProfile?.isKidsProfile != true
    }

    private var iCloudSyncBinding: Binding<Bool> {
        Binding(
            get: { iCloudSyncEnabled },
            set: { enabled in
                guard isAdministrable else { return }
                iCloudSyncEnabled = enabled
            }
        )
    }

    var body: some View {
        List {
            Section {
                Toggle("Sync with iCloud", isOn: iCloudSyncBinding)
                    .disabled(!isAdministrable)

                if iCloudSyncEnabled {
                    Label(syncManager.phase.title, systemImage: syncManager.phase == .ready ? "checkmark.icloud.fill" : "icloud.fill")
                    Text(syncManager.phase.message)
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Button(syncManager.phase == .ready ? "Sync Now" : "Retry Sync") {
                        guard isAdministrable else { return }
                        syncManager.syncNow()
                    }
                    .disabled(!isAdministrable)
                } else {
                    Text("Media state stays on this Apple TV until you turn sync on.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Cloud Sync")
            } footer: {
                Text("Cloud Sync starts off. Turning it on stores library, playback progress, TV-safe preferences, installed-source configuration, and tracker credentials in your private iCloud database. Turning it off stops syncing without deleting either copy. Cloud-provider login tokens, ephemeral playback URLs, and session cookies stay local.")
            }

            Section {
                Button("Reset TV Cache", role: .destructive) {
                    guard isAdministrable else { return }
                    showResetCacheConfirmation = true
                }
                .disabled(!isAdministrable)
                if !cacheMessage.isEmpty {
                    Text(cacheMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text(iCloudSyncEnabled
                    ? "This removes temporary artwork, metadata, player files, and the local sync cache. It refetches media state without creating CloudKit deletion records or removing the remote library."
                    : "This removes temporary artwork, metadata, and player files. Your local library and the remote iCloud copy are not changed while sync is off.")
            }
        }
        .navigationTitle("Cloud Sync & Cache")
        .alert("Reset TV Cache?", isPresented: $showResetCacheConfirmation) {
            Button("Reset", role: .destructive) {
                guard isAdministrable else { return }
                let purgeResult = TVPurgeableCache.clear()
                if iCloudSyncEnabled {
                    syncManager.resetLocalCacheWithoutDeletingRemoteState()
                    cacheMessage = "\(purgeResult) Media state is being restored from iCloud when available."
                } else {
                    cacheMessage = purgeResult
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(iCloudSyncEnabled
                ? "This removes temporary artwork, metadata, player files, and the local sync cache. Your remote iCloud library is not deleted."
                : "This removes temporary artwork, metadata, and player files. Your local library and remote iCloud copy are not deleted.")
        }
        .onChange(of: iCloudSyncEnabled) { enabled in
            MediaStateSyncBootstrap.setCloudKitSyncEnabled(enabled)
        }
    }
}

private enum TVPurgeableCache {
    static func clear() -> String {
        let fileManager = FileManager.default
        guard let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return "The cache directory is unavailable."
        }

        do {
            for item in try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
                try? fileManager.removeItem(at: item)
            }
            URLCache.shared.removeAllCachedResponses()
            return "Purgeable cache cleared."
        } catch {
            Logger.shared.log("tvOS cache clear failed: \(error.localizedDescription)", type: "Storage")
            return "Eclipse could not clear every cache file."
        }
    }
}
#endif

#if os(tvOS)
private struct TVFocusableInfoBlock<Content: View>: View {
    @FocusState private var isFocused: Bool
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.08 : 0))
            )
            .focusable()
            .focused($isFocused)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
#endif

let supportTermsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
let supportPrivacyPolicyURL = URL(string: "https://soupy-dev.github.io/Eclipse/privacy-policy/")!

#if canImport(StoreKit)
private struct SupportProductDefinition {
    let id: String
    let fallbackName: String
    let fallbackPrice: String
    let icon: String
    let color: Color

    var isConfigured: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum SupportPurchaseCatalog {
    static let definitions: [SupportProductDefinition] = [
        SupportProductDefinition(
            id: "idkbruh",
            fallbackName: "Tip",
            fallbackPrice: "$1",
            icon: "heart.fill",
            color: .pink
        ),
        SupportProductDefinition(
            id: "idkbruh2",
            fallbackName: "Big Tip",
            fallbackPrice: "$5",
            icon: "heart.circle.fill",
            color: .purple
        ),
        SupportProductDefinition(
            id: "idkbruh3",
            fallbackName: "Huge Tip",
            fallbackPrice: "$10",
            icon: "sparkles",
            color: .orange
        )
    ]

    static var productIDs: [String] {
        configuredDefinitions.map(\.id)
    }

    static var configuredProductCount: Int {
        configuredDefinitions.count
    }

    static var configuredDefinitions: [SupportProductDefinition] {
        definitions.filter(\.isConfigured)
    }

    static func definition(for productID: String) -> SupportProductDefinition? {
        definitions.first { $0.id == productID }
    }

    static func order(for productID: String) -> Int {
        definitions.firstIndex { $0.id == productID } ?? Int.max
    }
}

@MainActor
private final class SupportPurchaseStore: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var purchasingProductID: String?
    @Published private(set) var message: String?

    var hasConfiguredProducts: Bool {
        SupportPurchaseCatalog.configuredProductCount > 0
    }

    func loadProducts() async {
        guard !isLoading, hasConfiguredProducts else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let loadedProducts = try await Product.products(for: SupportPurchaseCatalog.productIDs)
            products = loadedProducts.sorted {
                SupportPurchaseCatalog.order(for: $0.id) < SupportPurchaseCatalog.order(for: $1.id)
            }
            message = products.isEmpty
                ? "StoreKit did not return these products yet. Tap a row to try again."
                : nil
        } catch {
            message = "Unable to load support purchases. Tap a row to try again."
        }
    }

    func reloadProducts() async {
        guard !isLoading else { return }
        products = []
        await loadProducts()
    }

    func purchase(_ product: Product) async {
        purchasingProductID = product.id
        message = nil
        defer { purchasingProductID = nil }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verifiedTransaction(from: verification)
                await transaction.finish()
                message = "Thanks for supporting Eclipse."
            case .pending:
                message = "Purchase pending approval."
            case .userCancelled:
                message = nil
            @unknown default:
                message = "Purchase could not be completed."
            }
        } catch {
            message = "Purchase could not be completed."
        }
    }

    private func verifiedTransaction(
        from result: VerificationResult<StoreKit.Transaction>
    ) throws -> StoreKit.Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified(_, _):
            throw SupportPurchaseError.unverifiedTransaction
        }
    }
}

#if os(tvOS)
private struct TVSupportSettingsSection: View {
    @StateObject private var store = SupportPurchaseStore()

    var body: some View {
        Group {
            if !Bundle.main.allowsExternalDonationLinks, !store.products.isEmpty {
                Section {
                    NavigationLink("Support Eclipse", destination: StoreKitSupportView())
                } header: {
                    Text("Support")
                } footer: {
                    Text("Purchases use the App Store on this Apple TV. External donation and community links are not shown in the TV app.")
                }
            }
        }
        .task { await store.loadProducts() }
    }
}
#endif

private enum SupportPurchaseError: Error {
    case unverifiedTransaction
}

private struct StoreKitSupportView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "Support") {
                    StoreKitSupportSection()
                }

                GlassSectionFooter("Support purchases are optional and do not unlock features.")

                GlassSection(header: "Legal") {
                    VStack(spacing: 0) {
                        storeLinkRow(title: "Terms of Use (EULA)", icon: "doc.text.fill", color: .blue, url: supportTermsOfUseURL)
                        GlassDivider(leadingInset: 16)
                        storeLinkRow(title: "Privacy Policy", icon: "hand.raised.fill", color: .teal, url: supportPrivacyPolicyURL)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Support Eclipse")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }

    private func storeLinkRow(title: String, icon: String, color: Color, url: URL) -> some View {
#if os(tvOS)
        TVFocusableInfoBlock {
            VStack(alignment: .leading, spacing: 12) {
                GlassDetailRow(icon: icon, iconColor: color, title: title) {
                    Text("Scan QR")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }

                HStack(spacing: 18) {
                    if let image = supportQRCode(for: url) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 150, height: 150)
                            .background(Color.white)
                            .accessibilityLabel("QR code for \(title)")
                    }
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
#else
        Link(destination: url) {
            GlassDetailRow(icon: icon, iconColor: color, title: title) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
#endif
    }

#if os(tvOS)
    private func supportQRCode(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
#endif
}

private struct StoreKitSupportSection: View {
    @StateObject private var store = SupportPurchaseStore()

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose an optional way to support Eclipse.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            GlassDivider(leadingInset: 14)

            if !store.hasConfiguredProducts {
                SupportPurchaseStatusRow(
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    title: "Tips Unavailable",
                    subtitle: "Product IDs need to be configured."
                )
            } else if store.isLoading && store.products.isEmpty {
                SupportPurchaseStatusRow(
                    icon: "hourglass",
                    color: .blue,
                    title: "Loading Tips",
                    subtitle: "Checking App Store availability."
                )
            } else if store.products.isEmpty {
                ForEach(Array(SupportPurchaseCatalog.configuredDefinitions.enumerated()), id: \.element.id) { index, definition in
                    Button {
                        Task { await store.reloadProducts() }
                    } label: {
                        StoreKitSupportPreviewRow(definition: definition)
                    }
                    .buttonStyle(.plain)

                    if index < SupportPurchaseCatalog.configuredProductCount - 1 {
                        GlassDivider()
                    }
                }

                GlassDivider(leadingInset: 14)

                Text("Prices load from the App Store when these purchases become available.")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.56))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(store.products.enumerated()), id: \.element.id) { index, product in
                    StoreKitSupportButton(product: product, store: store)

                    if index < store.products.count - 1 {
                        GlassDivider()
                    }
                }
            }

            if let message = store.message, !message.isEmpty {
                GlassDivider(leadingInset: 14)
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.56))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .task {
            await store.loadProducts()
        }
    }
}

private struct StoreKitSupportPreviewRow: View {
    let definition: SupportProductDefinition

    var body: some View {
        GlassSettingsRow(icon: definition.icon, iconColor: definition.color, title: definition.fallbackName) {
            HStack(spacing: 6) {
                Text(definition.fallbackPrice)
                    .font(.subheadline)
                    .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.32))
            }
        }
    }
}

private struct StoreKitSupportButton: View {
    let product: Product
    @ObservedObject var store: SupportPurchaseStore

    private var definition: SupportProductDefinition? {
        SupportPurchaseCatalog.definition(for: product.id)
    }

    private var isPurchasing: Bool {
        store.purchasingProductID == product.id
    }

    private var displayTitle: String {
        product.displayName.isEmpty ? (definition?.fallbackName ?? "Tip") : product.displayName
    }

    private var priceText: String {
        product.displayPrice
    }

    var body: some View {
        Button {
            Task { await store.purchase(product) }
        } label: {
            GlassSettingsRow(
                icon: definition?.icon ?? "heart.fill",
                iconColor: definition?.color ?? .pink,
                title: displayTitle
            ) {
                HStack(spacing: 6) {
                    if isPurchasing {
                        EclipseLoadingIndicator(diameter: 16)
                    }

                    Text(isPurchasing ? "Purchasing" : priceText)
                        .font(.subheadline)
                        .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing || store.purchasingProductID != nil)
    }
}

private struct SupportPurchaseStatusRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        GlassSettingsRow(icon: icon, iconColor: color, title: title) {
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
        }
    }
}

#endif

struct ScheduleSettingsView: View {
    @AppStorage("defaultScheduleMode") private var defaultScheduleModeRaw = ScheduleMode.anime.rawValue
    @AppStorage(ScheduleWindow.storageKey) private var scheduleWindowDays = ScheduleWindow.defaultValue.rawValue
    @StateObject private var accentColorManager = AccentColorManager.shared

    private var selectedMode: ScheduleMode {
        ScheduleMode.sanitized(defaultScheduleModeRaw)
    }

    private var selectedWindow: ScheduleWindow {
        ScheduleWindow.sanitized(scheduleWindowDays)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "Schedule Tab") {
                    VStack(spacing: 0) {
                        ForEach(Array(ScheduleMode.allCases.enumerated()), id: \.element.id) { index, mode in
                            GlassSelectionRow(
                                title: mode.displayName,
                                subtitle: mode.description,
                                isSelected: selectedMode == mode,
                                accent: accentColorManager.currentAccentColor
                            ) {
                                defaultScheduleModeRaw = mode.rawValue
                            }

                            if index < ScheduleMode.allCases.count - 1 {
                                GlassDivider(leadingInset: 16)
                            }
                        }
                    }
                }

                GlassSectionFooter("Choose which schedule opens first when you select the Schedule tab. You can still switch modes inside the tab.")

                GlassSection(header: "Schedule Range") {
                    VStack(spacing: 0) {
                        ForEach(Array(ScheduleWindow.allCases.enumerated()), id: \.element.id) { index, window in
                            GlassSelectionRow(
                                title: window.displayName,
                                subtitle: window.description,
                                isSelected: selectedWindow == window,
                                accent: accentColorManager.currentAccentColor
                            ) {
                                guard scheduleWindowDays != window.rawValue else { return }
                                scheduleWindowDays = window.rawValue
#if os(iOS)
                                Task {
                                    await LocalNotificationManager.shared.scheduleWindowDidChange()
                                }
#endif
                            }

                            if index < ScheduleWindow.allCases.count - 1 {
                                GlassDivider(leadingInset: 16)
                            }
                        }
                    }
                }

                GlassSectionFooter("Performance warning: This range also controls automatic episode notification checks and delayed startup warming. Longer ranges—especially 21 or 30 days—can load more slowly and use more data, particularly during provider fallback. Eclipse still schedules only the nearest 48 managed reminders. \(ScheduleWindow.defaultValue.rawValue) days remains the recommended default.")
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Schedule")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }
}

struct LegalNoticeView: View {
    let sourceCodeURL: URL
    let originalProjectURL: URL
    let licenseURL: URL
    let privacyPolicyURL: URL

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "Documents & Attribution") {
                    VStack(spacing: 0) {
                        destinationRow(
                            title: "Eclipse License & Source",
                            icon: "chevron.left.forwardslash.chevron.right",
                            color: .cyan,
                            destination: EclipseLicenseAndSourceView(
                                sourceCodeURL: sourceCodeURL,
                                originalProjectURL: originalProjectURL,
                                licenseURL: licenseURL
                            )
                        )
                        GlassDivider()
                        destinationRow(
                            title: "Privacy & Terms",
                            icon: "hand.raised.fill",
                            color: .teal,
                            destination: LegalPrivacyAndTermsView(privacyPolicyURL: privacyPolicyURL)
                        )
                        GlassDivider()
                        destinationRow(
                            title: "Open-Source Licenses",
                            icon: "doc.text.fill",
                            color: .blue,
                            destination: OpenSourceLicensesView()
                        )
                        GlassDivider()
                        destinationRow(
                            title: "Credits & Acknowledgements",
                            icon: "person.3.fill",
                            color: .indigo,
                            destination: ThirdPartyAcknowledgementsView()
                        )
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Legal & Source")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }

    private func destinationRow<Destination: View>(
        title: String,
        icon: String,
        color: Color,
        destination: Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            GlassDetailRow(icon: icon, iconColor: color, title: title) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct EclipseLicenseAndSourceView: View {
    let sourceCodeURL: URL
    let originalProjectURL: URL
    let licenseURL: URL

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "License") {
                    VStack(spacing: 0) {
                        LegalInfoText("Eclipse is released under the GNU General Public License version 3.")
                        GlassDivider(leadingInset: 16)
                        LegalExternalLinkRow(title: "View GPLv3 License", icon: "doc.plaintext.fill", color: .blue, url: licenseURL)
                        GlassDivider(leadingInset: 16)
                        LegalInfoText("This program comes with no warranty, to the extent permitted by law.")
                    }
                }

                GlassSection(header: "Corresponding Source") {
                    VStack(spacing: 0) {
                        LegalInfoText("Eclipse is a GPL-licensed media app with substantial original changes by Soupy-dev. Official releases identify the exact source used for the app and playback framework.")
                        GlassDivider(leadingInset: 16)
                        LegalExternalLinkRow(
                            title: revisionTitle("Eclipse Source", revision: Bundle.main.eclipseSourceRevision),
                            icon: "chevron.left.forwardslash.chevron.right",
                            color: .cyan,
                            url: sourceCodeURL
                        )
                        GlassDivider(leadingInset: 16)
                        LegalExternalLinkRow(
                            title: revisionTitle("MPVKit Build Source", revision: Bundle.main.mpvKitSourceRevision),
                            icon: "play.rectangle.fill",
                            color: .purple,
                            url: Bundle.main.mpvKitSourceURL
                        )
                        GlassDivider(leadingInset: 16)
                        LegalExternalLinkRow(title: "Luna — Original Upstream Project", icon: "arrow.up.right.square.fill", color: .indigo, url: originalProjectURL)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("License & Source")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }

    private func revisionTitle(_ title: String, revision: String?) -> String {
        guard let revision else { return title }
        return "\(title) · \(revision.prefix(12))"
    }
}

private struct LegalPrivacyAndTermsView: View {
    let privacyPolicyURL: URL

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "Privacy") {
                    VStack(spacing: 0) {
                        LegalInfoText("Eclipse's privacy policy explains what data the app stores locally and how optional third-party services are handled.")
                        GlassDivider(leadingInset: 16)
                        LegalInfoText("Cloud Sync starts off on each device. When you turn it on, selected app data, including your library, progress, installed-source configuration, provider settings, and tracker sessions, may sync through your private cloud account. Reproducing that setup on another device can include source code, credentials, and capability-bearing URLs inside the private cloud payload. Turning Cloud Sync off stops syncing without deleting either the local or remote copy. Cloud-provider login tokens, ephemeral playback URLs, session cookies, downloads, caches, and logs are excluded. Eclipse adds no analytics SDK.")
                        GlassDivider(leadingInset: 16)
                        LegalExternalLinkRow(title: "Privacy Policy", icon: "hand.raised.fill", color: .teal, url: privacyPolicyURL)
                    }
                }

                GlassSection(header: "Terms") {
                    VStack(spacing: 0) {
                        LegalInfoText("App Store and TestFlight distributions use Apple's standard Licensed Application End User License Agreement.")
                        GlassDivider(leadingInset: 16)
                        LegalExternalLinkRow(title: "Terms of Use (EULA)", icon: "doc.text.fill", color: .blue, url: supportTermsOfUseURL)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Privacy & Terms")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }
}

private struct LegalInfoText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.7))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }
}

private struct LegalExternalLinkRow: View {
    let title: String
    let icon: String
    let color: Color
    let url: URL

    var body: some View {
#if os(tvOS)
        TVFocusableInfoBlock {
            VStack(alignment: .leading, spacing: 12) {
                GlassDetailRow(icon: icon, iconColor: color, title: title) {
                    Text("Scan QR")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }

                HStack(spacing: 18) {
                    if let image = qrCode {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 150, height: 150)
                            .background(Color.white)
                            .accessibilityLabel("QR code for \(title)")
                    }

                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
#else
        Link(destination: url) {
            GlassDetailRow(icon: icon, iconColor: color, title: title) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
#endif
    }

#if os(tvOS)
    private var qrCode: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
#endif
}

private struct OpenSourceLicenseDocument: Identifiable {
    let url: URL
    let title: String

    var id: URL { url }
}

private struct OpenSourceLicenseGroup: Identifiable {
    let title: String
    let documents: [OpenSourceLicenseDocument]

    var id: String { title }
}

private struct OpenSourceLicensesView: View {
    private static let inventory = document(
        "Third-Party Notices & Inventory",
        file: "THIRD-PARTY-NOTICES"
    )

    private static let groups: [OpenSourceLicenseGroup] = {
        var readerAndShaderDocuments = documents([
            ("ArtCNN Shader — MIT", "LICENSE-MIT-ArtCNN"),
            ("FidelityFX FSR Shader — MIT", "LICENSE-MIT-FidelityFX-FSR"),
            ("Shader Components — GPL 3.0", "LICENSE-GPL-3.0"),
            ("Shader Components — LGPL 3.0", "LICENSE-LGPL-3.0")
        ], subdirectory: "Shaders")
#if !os(tvOS)
        readerAndShaderDocuments.insert(contentsOf: documents([
            ("Reader Extensions — Provenance & Notices", "NOTICE"),
            ("Reader Extensions — Apache 2.0", "LICENSE-APACHE-2.0")
        ], subdirectory: "ReaderExtensions"), at: 0)
#endif

        return [
            OpenSourceLicenseGroup(title: "App Libraries", documents: documents([
                ("Kingfisher — MIT", "Kingfisher-MIT"),
                ("Nuke — MIT", "Nuke-MIT"),
                ("PLCrashReporter — MIT", "PLCrashReporter-MIT"),
                ("SwiftSoup — MIT", "SwiftSoup-MIT"),
                ("Texture — Apache 2.0", "Texture-Apache-2.0"),
                ("ZIPFoundation — MIT", "ZIPFoundation-MIT")
            ])),
            OpenSourceLicenseGroup(title: "Playback & MPVKit", documents: documents([
                ("FFmpeg", "FFmpeg-License"),
                ("FreeType — FreeType License", "FreeType-FTL"),
                ("FreeType — GPL 2.0", "FreeType-License"),
                ("FriBidi — LGPL 2.1", "FriBidi-LGPL-2.1"),
                ("GMP — GPL 2.0", "GMP-GPL-2.0"),
                ("GMP — LGPL 3.0", "GMP-LGPL-3.0"),
                ("GnuTLS — GPL 3.0", "GnuTLS-GPL-3.0"),
                ("GnuTLS — LGPL 2.1", "GnuTLS-LGPL-2.1"),
                ("HarfBuzz", "HarfBuzz-License"),
                ("Little CMS — MIT", "LittleCMS-MIT"),
                ("MPVKit — LGPL 3.0", "MPVKit-LGPL-3.0"),
                ("MoltenVK — Apache 2.0", "MoltenVK-Apache-2.0"),
                ("Nettle — LGPL 3.0", "Nettle-LGPL-3.0"),
                ("OpenSSL — Apache 2.0", "OpenSSL-Apache-2.0"),
                ("Samba — GPL 3.0", "Samba-GPL-3.0"),
                ("SPIRV-Cross — Apache 2.0", "SPIRV-Cross-Apache-2.0"),
                ("SPIRV-Headers — MIT", "SPIRV-Headers-MIT"),
                ("SPIRV-Tools — Apache 2.0", "SPIRV-Tools-Apache-2.0"),
                ("dav1d — BSD 2-Clause", "dav1d-BSD-2-Clause"),
                ("glslang", "glslang-License"),
                ("libass — ISC", "libass-ISC"),
                ("libbluray — LGPL 2.1", "libbluray-LGPL-2.1"),
                ("libdovi — MIT", "libdovi-MIT"),
                ("libplacebo — LGPL 2.1", "libplacebo-LGPL-2.1"),
                ("libunibreak — zlib", "libunibreak-zlib"),
                ("mpv — Copyright & License", "mpv-Copyright"),
                ("shaderc — Apache 2.0", "shaderc-Apache-2.0"),
                ("uavs3d — BSD 3-Clause", "uavs3d-BSD-3-Clause"),
                ("uchardet — MPL 1.1", "uchardet-MPL-1.1")
            ])),
            OpenSourceLicenseGroup(title: "Reader & Shaders", documents: readerAndShaderDocuments),
            OpenSourceLicenseGroup(title: "Common License Texts", documents: documents([
                ("GNU GPL 2.0", "GPL-2.0"),
                ("GNU GPL 3.0", "GPL-3.0"),
                ("GNU LGPL 2.1", "LGPL-2.1"),
                ("GNU LGPL 3.0", "LGPL-3.0")
            ]))
        ].filter { !$0.documents.isEmpty }
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let inventory = Self.inventory {
                    GlassSection(header: "Overview") {
                        documentRow(inventory)
                    }
                }

                GlassSection(header: "License Categories") {
                    VStack(spacing: 0) {
                        ForEach(Array(Self.groups.enumerated()), id: \.element.id) { index, group in
                            NavigationLink(destination: OpenSourceLicenseGroupView(group: group)) {
                                GlassDetailRow(icon: icon(for: group), iconColor: color(for: group), title: group.title) {
                                    HStack(spacing: 7) {
                                        Text("\(group.documents.count)")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.5))
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.3))
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            if index < Self.groups.count - 1 {
                                GlassDivider(leadingInset: 16)
                            }
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Open-Source Licenses")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }

    private func documentRow(_ document: OpenSourceLicenseDocument) -> some View {
        NavigationLink(destination: OpenSourceLicenseDocumentView(document: document)) {
            GlassDetailRow(icon: "doc.text.fill", iconColor: .teal, title: document.title) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
    }

    private func icon(for group: OpenSourceLicenseGroup) -> String {
        switch group.title {
        case "App Libraries": return "shippingbox.fill"
        case "Playback & MPVKit": return "play.rectangle.fill"
        case "Reader & Shaders": return "wand.and.stars"
        default: return "doc.plaintext.fill"
        }
    }

    private func color(for group: OpenSourceLicenseGroup) -> Color {
        switch group.title {
        case "App Libraries": return .blue
        case "Playback & MPVKit": return .purple
        case "Reader & Shaders": return .orange
        default: return .gray
        }
    }

    private static func documents(
        _ entries: [(title: String, file: String)],
        subdirectory: String = "OpenSourceLicenses"
    ) -> [OpenSourceLicenseDocument] {
        entries.compactMap { document($0.title, file: $0.file, subdirectory: subdirectory) }
    }

    private static func document(
        _ title: String,
        file: String,
        subdirectory: String = "OpenSourceLicenses"
    ) -> OpenSourceLicenseDocument? {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt", subdirectory: subdirectory) else {
            return nil
        }
        return OpenSourceLicenseDocument(url: url, title: title)
    }
}

private struct OpenSourceLicenseGroupView: View {
    let group: OpenSourceLicenseGroup

    var body: some View {
        ScrollView {
            GlassSection(header: group.title) {
                VStack(spacing: 0) {
                    ForEach(Array(group.documents.enumerated()), id: \.element.id) { index, document in
                        NavigationLink(destination: OpenSourceLicenseDocumentView(document: document)) {
                            GlassDetailRow(icon: "doc.plaintext", iconColor: .blue, title: document.title) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.3))
                            }
                        }
                        .buttonStyle(.plain)

                        if index < group.documents.count - 1 {
                            GlassDivider(leadingInset: 16)
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle(group.title)
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }
}

private struct OpenSourceLicenseDocumentView: View {
    let document: OpenSourceLicenseDocument

    var body: some View {
        ScrollView {
            Text(contents)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white.opacity(0.74))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle(document.title)
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }

    private var contents: String {
        (try? String(contentsOf: document.url, encoding: .utf8))
            ?? "This bundled legal document could not be loaded."
    }
}

private struct ThirdPartyAcknowledgement: Identifiable {
    let title: String
    let detail: String
    let projectURL: URL
    let licenseName: String?
    let licenseURL: URL?
    let sourceURL: URL?

    var id: String { title }

    init(_ title: String, detail: String, project: String, licenseName: String? = nil, license: String? = nil, source: String? = nil) {
        self.title = title
        self.detail = detail
        self.projectURL = URL(string: project)!
        self.licenseName = licenseName
        self.licenseURL = license.flatMap(URL.init(string:))
        self.sourceURL = source.flatMap(URL.init(string:))
    }
}

private struct ThirdPartyAcknowledgementsView: View {
    private static let mpvKitBuildSource = Bundle.main.mpvKitSourceURL.absoluteString
    private static let mpvKitBuildLicense: String = {
        guard let revision = Bundle.main.mpvKitSourceRevision else {
            return "https://github.com/Soupy-dev/MPVKit/blob/eclipse-mpv-metal/LICENSE"
        }
        return "https://github.com/Soupy-dev/MPVKit/blob/\(revision)/LICENSE"
    }()
    private static let lineage: [ThirdPartyAcknowledgement] = sharedLineage + iOSOnlyLineage

    private static let sharedLineage: [ThirdPartyAcknowledgement] = [
        .init("Luna", detail: "Original upstream project from which Eclipse was derived.", project: "https://github.com/cranci1/Luna", licenseName: "GPLv3", license: "https://github.com/cranci1/Luna/blob/main/LICENSE"),
        .init("SoraCore", detail: "cranci1's service runtime. No longer linked as a dependency, but Eclipse's local service runtime and network layer are adapted from it.", project: "https://github.com/cranci1/SoraCore", licenseName: "GPLv3", license: "https://github.com/cranci1/SoraCore/blob/main/LICENSE"),
        .init("SkyStream", detail: "Akash's independent project defined the plugin format supported by Eclipse's compatibility layer. SkyStream plugins are not bundled with Eclipse.", project: "https://github.com/akashdh11/skystream"),
        .init("SkyStream Tools", detail: "Reference SDK and extractor behavior adapted by Eclipse's local SkyStream compatibility layer.", project: "https://github.com/akashdh11/skystream-tools", licenseName: "GPLv3", license: "https://github.com/akashdh11/skystream-tools/blob/main/LICENSE")
    ]

#if os(tvOS)
    private static let iOSOnlyLineage: [ThirdPartyAcknowledgement] = []
#else
    private static let iOSOnlyLineage: [ThirdPartyAcknowledgement] = [
        .init("Eclipse Reader Extensions", detail: "Eclipse's substantially modified Swift implementation adapts Apache-2.0 interface and runtime behavior from Mangayomi revision 4eec7aca and five generic parser families from the archived official Mangayomi Extensions revision 6004f1f8. Eclipse bundles no provider catalog, provider scripts, provider logos, or site-specific parser configuration.", project: "https://github.com/kodjodevf/mangayomi/tree/4eec7aca6f1c8bd563d0bc79bcf895f46bb30b74", licenseName: "Apache 2.0", license: "https://github.com/kodjodevf/mangayomi/blob/4eec7aca6f1c8bd563d0bc79bcf895f46bb30b74/LICENSE", source: "https://github.com/kodjodevf/mangayomi-extensions/tree/6004f1f8d1a56f882dadb734ce26f50c626a3850")
    ]
#endif

    private static let libraries: [ThirdPartyAcknowledgement] = (sharedLibraries + iOSOnlyLibraries)
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

    private static let sharedLibraries: [ThirdPartyAcknowledgement] = [
        .init("Kingfisher", detail: "Copyright © 2019 Wei Wang.", project: "https://github.com/onevcat/Kingfisher", licenseName: "MIT", license: "https://github.com/onevcat/Kingfisher/blob/master/LICENSE"),
        .init("PLCrashReporter", detail: "Copyright © Microsoft Corporation and © 2008–2014 Plausible Labs Cooperative, Inc.", project: "https://github.com/microsoft/plcrashreporter", licenseName: "License", license: "https://github.com/microsoft/plcrashreporter/blob/master/LICENSE")
    ]

#if os(tvOS)
    private static let iOSOnlyLibraries: [ThirdPartyAcknowledgement] = []
#else
    private static let iOSOnlyLibraries: [ThirdPartyAcknowledgement] = [
        .init("Nuke", detail: "Copyright © 2015–2026 Alexander Grebenyuk.", project: "https://github.com/kean/Nuke", licenseName: "MIT", license: "https://github.com/kean/Nuke/blob/main/LICENSE"),
        .init("SwiftSoup", detail: "Version 2.13.6 at immutable revision ead56133. Copyright © 2009–2025 Jonathan Hedley; Swift port © 2016–2025 Nabil Chatbi. The full MIT license is included in the app's bundled open-source license documents.", project: "https://github.com/scinfu/SwiftSoup/tree/ead56133a693d0184d8c2db1a6d6394410cacfd6", licenseName: "MIT", license: "https://github.com/scinfu/SwiftSoup/blob/ead56133a693d0184d8c2db1a6d6394410cacfd6/LICENSE"),
        .init("Texture / AsyncDisplayKit", detail: "Created by Pinterest as a continuation of AsyncDisplayKit, originally developed by Facebook.", project: "https://github.com/Skittyblock/Texture", licenseName: "Apache 2.0", license: "https://github.com/Skittyblock/Texture/blob/master/LICENSE"),
        .init("ZIPFoundation", detail: "Copyright © 2017–2025 Thomas Zoechling.", project: "https://github.com/weichsel/ZIPFoundation", licenseName: "MIT", license: "https://github.com/weichsel/ZIPFoundation/blob/development/LICENSE")
    ]
#endif

    private static let playback: [ThirdPartyAcknowledgement] = [
        .init("Eclipse MPVKit fork", detail: "Eclipse's in-app playback framework, based on MPVKit. Official builds link the exact framework source revision.", project: mpvKitBuildSource, licenseName: "LGPLv3 / GPL components", license: mpvKitBuildLicense),
        .init("MPVKit", detail: "Original Apple-platform mpv framework.", project: "https://github.com/mpvkit/MPVKit", licenseName: "LGPLv3 / GPL components", license: "https://github.com/mpvkit/MPVKit/blob/main/LICENSE"),
        .init("mpv", detail: "Media player and playback engine.", project: "https://github.com/mpv-player/mpv", licenseName: "GPLv2+ / LGPLv2.1+", license: "https://github.com/mpv-player/mpv/blob/master/Copyright"),
        .init("FFmpeg", detail: "Multimedia codecs, demuxing, filtering, and related playback components.", project: "https://github.com/FFmpeg/FFmpeg", licenseName: "LGPLv2.1+ / GPLv2+", license: "https://github.com/FFmpeg/FFmpeg/blob/master/LICENSE.md"),
        .init("MoltenVK", detail: "Vulkan implementation for Apple platforms used by the MoltenVK renderer.", project: "https://github.com/KhronosGroup/MoltenVK", licenseName: "Apache 2.0", license: "https://github.com/KhronosGroup/MoltenVK/blob/main/LICENSE"),
        .init("ArtCNN", detail: "Copyright © 2024 Joao Chrisostomo, Kacper Michajłow. The ArtCNN C4F16 and C4F16 DS shaders are bundled as Eclipse's animation Enhanced Upscaling options, and are what Automatic selects for animated content. Their activation threshold is relaxed from 1.3x to 1.05x scaling so small high-density phone enlargements can still benefit.", project: "https://github.com/Artoriuz/ArtCNN", licenseName: "MIT", license: "https://github.com/Artoriuz/ArtCNN/blob/main/LICENSE"),
        .init("AMD FidelityFX Super Resolution 1", detail: "Copyright © 2021 Advanced Micro Devices, Inc. FSR 1 EASU and RCAS are bundled as Eclipse's live-action Enhanced Upscaling option, and are what Automatic selects for live action. Eclipse's mpv GLSL adaptation is based on hooke007's AMD_FSR1_RT port and fixes RGB MAIN-stage processing, conservative noise-aware sharpening, and a 1.05x activation threshold, with no additional user setting.", project: "https://github.com/GPUOpen-Effects/FidelityFX-FSR", licenseName: "MIT", license: "https://github.com/GPUOpen-Effects/FidelityFX-FSR/blob/master/license.txt", source: "https://github.com/Soupy-dev/Eclipse/blob/main/Eclipse/Player/Shaders/AMD_FSR1_EASU_RCAS.glsl")
    ]

    private static let services: [ThirdPartyAcknowledgement] = iOSOnlyServices + sharedServices

    private static let iOSOnlyServices: [ThirdPartyAcknowledgement] = []

    private static let sharedServices: [ThirdPartyAcknowledgement] = [
        .init("TMDB", detail: "Movie and television metadata and images. This product uses the TMDB API but is not endorsed or certified by TMDB.", project: "https://www.themoviedb.org"),
        .init("AniList", detail: "Anime and manga metadata, schedules, and optional tracking.", project: "https://anilist.co"),
        .init("MyAnimeList", detail: "Optional anime and manga tracking.", project: "https://myanimelist.net"),
        .init("Trakt", detail: "Optional movie and television tracking, ratings, and schedules.", project: "https://trakt.tv"),
        .init("TVmaze", detail: "Television schedule metadata.", project: "https://www.tvmaze.com"),
        .init("Jikan", detail: "Unofficial MyAnimeList API used for supplemental anime episode metadata.", project: "https://jikan.moe"),
        .init("Kitsu", detail: "Anime identity metadata used for season and episode matching.", project: "https://kitsu.io"),
        .init("AniMap", detail: "Anime identity and season mapping data.", project: "https://animap.s0n1c.ca"),
        .init("AniSkip", detail: "Anime skip-segment data.", project: "https://aniskip.com"),
        .init("TheIntroDB", detail: "Intro, recap, outro, credits, and preview skip-segment data.", project: "https://theintrodb.org"),
        .init("IntroDB", detail: "IMDb-based skip-segment data used as an optional fallback.", project: "https://introdb.app"),
        .init("OpenSubtitles", detail: "Optional subtitle discovery through the Stremio OpenSubtitles addon.", project: "https://www.opensubtitles.com"),
        .init("Stremio", detail: "Addon protocol used for optional user-installed addons.", project: "https://github.com/Stremio/stremio-addon-sdk")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "Acknowledgement Categories") {
                    VStack(spacing: 0) {
                        categoryRow(
                            title: "Project Lineage & Compatibility",
                            icon: "point.3.connected.trianglepath.dotted",
                            color: .indigo,
                            items: Self.lineage
                        )
                        GlassDivider(leadingInset: 16)
                        categoryRow(
                            title: "App Libraries",
                            icon: "shippingbox.fill",
                            color: .blue,
                            items: Self.libraries
                        )
                        GlassDivider(leadingInset: 16)
                        categoryRow(
                            title: "Playback & Shaders",
                            icon: "play.rectangle.fill",
                            color: .purple,
                            items: Self.playback
                        )
                        GlassDivider(leadingInset: 16)
                        categoryRow(
                            title: "Data, Tracking & Services",
                            icon: "network",
                            color: .teal,
                            items: Self.services
                        )
                    }
                }

                GlassSection(header: "Notice") {
                    Text("Names and trademarks belong to their respective owners. These acknowledgements do not imply affiliation or endorsement. Each project and service remains subject to its linked license or terms. Eclipse's corresponding source is available from the License & Source page.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.68))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Credits & Acknowledgements")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }

    private func categoryRow(
        title: String,
        icon: String,
        color: Color,
        items: [ThirdPartyAcknowledgement]
    ) -> some View {
        NavigationLink(destination: ThirdPartyAcknowledgementCategoryView(title: title, items: items)) {
            GlassDetailRow(icon: icon, iconColor: color, title: title) {
                HStack(spacing: 7) {
                    Text("\(items.count)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.3))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ThirdPartyAcknowledgementCategoryView: View {
    let title: String
    let items: [ThirdPartyAcknowledgement]

    var body: some View {
        ScrollView {
            GlassSection(header: title) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        acknowledgementRow(item)
                        if index < items.count - 1 {
                            GlassDivider(leadingInset: 16)
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle(title)
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }

    private func acknowledgementRow(_ item: ThirdPartyAcknowledgement) -> some View {
#if os(tvOS)
        TVFocusableInfoBlock {
            acknowledgementRowContent(item)
        }
#else
        acknowledgementRowContent(item)
#endif
    }

    private func acknowledgementRowContent(_ item: ThirdPartyAcknowledgement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.headline)
                .foregroundColor(.white)

            Text(item.detail)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)

#if os(tvOS)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.projectURL.absoluteString)
                if let licenseName = item.licenseName, let licenseURL = item.licenseURL {
                    Text("\(licenseName): \(licenseURL.absoluteString)")
                }
                if let sourceURL = item.sourceURL {
                    Text("Source: \(sourceURL.absoluteString)")
                }
            }
            .font(.caption)
            .foregroundColor(.white.opacity(0.68))
#else
            HStack(spacing: 16) {
                Link("Project", destination: item.projectURL)
                if let licenseName = item.licenseName, let licenseURL = item.licenseURL {
                    Link(licenseName, destination: licenseURL)
                }
                if let sourceURL = item.sourceURL {
                    Link("Source", destination: sourceURL)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(.cyan)
#endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

struct PerformanceModeSettingsView: View {
    @ObservedObject private var catalogManager = CatalogManager.shared
    @AppStorage(PerformanceModeSettings.skipAniListTraversalForAnimeDetailsKey) private var skipAniListTraversalForAnimeDetails = false
    @StateObject private var accentColorManager = AccentColorManager.shared

    private var accent: Color { accentColorManager.currentAccentColor }

    private var performanceModeBinding: Binding<Bool> {
        Binding(
            get: { catalogManager.performanceModeEnabled },
            set: { catalogManager.setPerformanceModeEnabled($0) }
        )
    }

    private var animeCatalogs: [Catalog] {
        catalogManager.catalogs.filter { PerformanceModeSettings.isAnimeCatalog($0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection {
                    GlassDetailRow(icon: "bolt.fill", iconColor: .yellow, title: "Performance Mode") {
                        Toggle("", isOn: performanceModeBinding)
                            .labelsHidden()
                            .tint(accent)
                    }
                }
                GlassSectionFooter("Performance Mode keeps anime-heavy home catalogs on the faster AniList-backed path and locks those anime catalog rows to their performance-safe source. Detail pages still load full metadata when opened.")

                GlassSection {
                    GlassDetailRow(icon: "hare.fill", iconColor: .orange, title: "Skip AniList Traversal for Anime Details") {
                        Toggle("", isOn: $skipAniListTraversalForAnimeDetails)
                            .labelsHidden()
                            .tint(accent)
                    }
                }
                GlassSectionFooter("Some anime services, season mappings, specials, OVAs, and tracker matching may be less accurate or unavailable.")

                if !animeCatalogs.isEmpty {
                    GlassSection(header: "Affected Catalogs") {
                        VStack(spacing: 0) {
                            ForEach(Array(animeCatalogs.enumerated()), id: \.element.id) { index, catalog in
                                GlassDetailRow(icon: "bolt.fill", iconColor: .yellow, title: catalog.name) {
                                    Text(catalogManager.isCatalogEffectivelyEnabled(catalog) ? "Enabled" : "Hidden")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.5))
                                }

                                if index < animeCatalogs.count - 1 {
                                    GlassDivider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Performance Mode")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }

}

#if !os(tvOS)
struct ExperimentalCloudSyncView: View {
    @AppStorage(ExperimentalFeatureState.iCloudSyncEnabledKey, store: ProfileSettingsStore.device) private var iCloudSyncEnabled = false
    @AppStorage(EclipseSettingsSyncPreference.enabledKey, store: ProfileSettingsStore.device) private var syncSettingsAcrossDevices = true
    @AppStorage(CloudSyncTotalBudget.storageKey, store: .standard) private var cloudSyncTotalBudgetBytes = 0
    @State private var pendingCloudDataDeletionProvider: CloudSyncProvider?

    private var resolvedCloudSyncBudget: CloudSyncTotalBudget {
        CloudSyncTotalBudget(rawValue: cloudSyncTotalBudgetBytes) ?? .fallback
    }
    @State private var showSettingsSyncDirectionChoice = false
    @State private var showSettingsSyncDirectionFailure = false
    @AppStorage(CloudSyncProvider.googleDrive.syncEnabledKey, store: ProfileSettingsStore.device) private var googleDriveSyncEnabled = false
    @AppStorage(CloudSyncProvider.oneDrive.syncEnabledKey, store: ProfileSettingsStore.device) private var oneDriveSyncEnabled = false
    @StateObject private var cloudSyncManager = ExperimentalCloudSyncManager.shared
    @StateObject private var accentColorManager = AccentColorManager.shared
    @StateObject private var profileManager = ProfileManager.shared

    private var availability: ExperimentalCloudSyncAvailability {
        ExperimentalCloudSyncAvailability.current
    }

    private var accent: Color { accentColorManager.currentAccentColor }

    private var isAdministrable: Bool {
        profileManager.activeProfile?.isKidsProfile != true
    }

    private var includedData: [(String, String)] {
        [
            ("Settings", "gearshape"),
            ("Profiles, avatars, and kids mode", "person.2"),
            ("Libraries and collections", "books.vertical"),
            ("Watch and read progress", "play.rectangle"),
            ("Catalogs, services, addons, and plugins", "server.rack"),
            ("Tracker connections and preferences", "chart.bar")
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection {
                    HStack(spacing: 14) {
                        Image(systemName: "cloud.fill")
                            .font(.title2)
                            .foregroundColor(accent)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cloud Sync")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("Automatically keep selected Eclipse data in sync through iCloud, Google Drive, or OneDrive.")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                if isAdministrable {
                    GlassSection(header: "Preferences") {
                        VStack(spacing: 0) {
                            GlassSettingsRow(
                                icon: "slider.horizontal.3",
                                iconColor: .blue,
                                title: "Sync Settings Across Devices"
                            ) {
                                Toggle("", isOn: Binding(
                                    get: { syncSettingsAcrossDevices },
                                    set: { isOn in
                                        guard isAdministrable else { return }
                                        if isOn {
                                            showSettingsSyncDirectionChoice = true
                                        } else {
                                            syncSettingsAcrossDevices = false
                                        }
                                    }
                                ))
                                    .labelsHidden()
                                    .tint(.blue)
                            }

                            GlassDivider()

                            GlassSettingsRow(
                                icon: "externaldrive.badge.checkmark",
                                iconColor: .teal,
                                title: "Cloud Storage Budget"
                            ) {
                                Menu {
                                    ForEach(CloudSyncTotalBudget.allCases) { budget in
                                        Button {
                                            cloudSyncTotalBudgetBytes = budget.rawValue
                                        } label: {
                                            if budget.rawValue == resolvedCloudSyncBudget.rawValue {
                                                Label(budget.displayName, systemImage: "checkmark")
                                            } else {
                                                Text(budget.displayName)
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(resolvedCloudSyncBudget.displayName)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption2)
                                    }
                                    .foregroundColor(.white.opacity(0.7))
                                }
                            }
                        }
                    }
                    GlassSectionFooter("Keep preferences such as subtitle appearance, audio language, player behaviour, and home layout the same on every device signed in to your account. Turn this off to give this device its own settings. Your library, watch progress, and ratings keep syncing either way.")
                    GlassSectionFooter("Cloud Storage Budget is the most space Eclipse will take up in one connected cloud account. Eclipse keeps a few recent copies so it can recover from a bad sync; when the total approaches the budget, the oldest copies are removed first. Your newest backup is always kept, even if it is larger than the budget, so backing up never silently stops. Each device applies its own budget, and this figure covers Eclipse's own files only — not any version history your cloud provider keeps on its side.")

                    providerSection(.iCloud)
                    providerSection(.googleDrive)
                    providerSection(.oneDrive)

                    if #available(iOS 17.0, *) {
                        CloudSyncHealthSection()
                    }

                    if ExperimentalFeatureState.isEnabledAtLaunch {
                        GlassSectionFooter("Eclipse checks enabled providers at launch, when the app becomes active, after local changes, and about every 15 minutes while the app remains open. Provider rate limits may delay a retry.")
                    } else {
                        GlassSectionFooter("Experimental Features are off, so Eclipse does not create full-app backup snapshots automatically. Provider switches still control media-state sync, and Sync Now writes a single snapshot on demand.")
                    }
                    GlassSectionFooter("Multiple providers can stay active. The Primary provider is synced first; Eclipse then safely merges the result with the other enabled providers.")
                } else {
                    GlassSectionFooter("This is a kids profile, so it cannot connect providers, sync, or restore cloud data. Switch to a grown-up profile to make those changes.")
                }

                GlassSection(header: "Notice") {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundColor(.orange)
                            .frame(width: 30)

                        Text("Eclipse is not responsible for changes, loss, restrictions, suspension, or other issues affecting your chosen cloud service. Use Cloud Sync at your own risk. iCloud, Google Drive, OneDrive, Apple, Google, and Microsoft are trademarks of their respective owners and are not affiliated with Eclipse.")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                GlassSectionFooter("Installed-source settings and tracker credentials are included so another device can reproduce your setup. Downloaded media, preload caches, images, logs, temporary files, cloud-provider login tokens, ephemeral playback URLs, and session cookies are excluded.")

                GlassSection(header: "Included Data") {
                    VStack(spacing: 0) {
                        ForEach(Array(includedData.enumerated()), id: \.offset) { index, item in
                            GlassDetailRow(icon: item.1, iconColor: .blue, title: item.0) {
                                EmptyView()
                            }

                            if index < includedData.count - 1 {
                                GlassDivider()
                            }
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Cloud Sync")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .alert(
            "Cloud Sync Needs Your Choice",
            isPresented: Binding(
                get: {
                    cloudSyncManager.overwriteWarning != nil
                        && isAdministrable
                        && !cloudSyncManager.isSyncing
                },
                set: { _ in }
            ),
            presenting: cloudSyncManager.overwriteWarning
        ) { warning in
            Button(
                "Restore Cloud Data",
                role: warning.direction == .accountChanged ? .destructive : nil
            ) {
                restoreCloudAfterOverwriteWarning()
            }
            Button("Replace Cloud Backup", role: .destructive) {
                replaceCloudAfterOverwriteWarning()
            }
            Button("Cancel", role: .cancel) {
                cloudSyncManager.cancelOverwriteWarning()
            }
        } message: { warning in
            Text(warning.alertMessage)
        }
        .alert("Which Settings Should Win?", isPresented: $showSettingsSyncDirectionChoice) {
            Button("Use My Other Devices") {
                guard isAdministrable else { return }
                let enabled = MediaStateSyncBootstrap.adoptRemoteSettingsAfterEnablingSync()
                syncSettingsAcrossDevices = enabled
                showSettingsSyncDirectionFailure = !enabled
            }
            Button("Use This Device") {
                guard isAdministrable else { return }
                let enabled = MediaStateSyncBootstrap.publishLocalSettingsAfterEnablingSync()
                syncSettingsAcrossDevices = enabled
                showSettingsSyncDirectionFailure = !enabled
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your settings may have changed on this device while syncing was off. \"Use My Other Devices\" replaces this device's settings with the ones already shared across your account. \"Use This Device\" makes these settings the shared ones and updates your other devices. Settings sync stays off until you choose.")
        }
        .alert("Settings Sync Is Paused", isPresented: $showSettingsSyncDirectionFailure) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Eclipse could not change the settings-sync direction while a restore, account change, or recovery is still active. Settings sync remains off. Wait for Cloud Sync to become ready, then try again.")
        }
        .adaptiveConfirmationDialog(
            "Delete Cloud Data",
            isPresented: Binding(
                get: { pendingCloudDataDeletionProvider != nil },
                set: { if !$0 { pendingCloudDataDeletionProvider = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let provider = pendingCloudDataDeletionProvider {
                    deleteCloudData(provider)
                }
                pendingCloudDataDeletionProvider = nil
            }
            Button("Cancel", role: .cancel) {
                pendingCloudDataDeletionProvider = nil
            }
        } message: {
            Text(cloudDataDeletionMessage)
        }
        .onAppear {
            cloudSyncManager.refreshRemoteUsageForVisibleProviders()
            cloudSyncManager.refreshConnectedAccountEmails()
        }
        .onChange(of: iCloudSyncEnabled) { enabled in
            cloudSyncManager.setProviderEnabled(.iCloud, enabled: enabled)
            if enabled, cloudSyncManager.isAppleAccountMediaStateSuspended {
                cloudSyncManager.resumeAppleAccountMediaStateSync()
            }
            if enabled {
                cloudSyncManager.syncSnapshot(provider: .iCloud, reason: "enabled")
            }
        }
        .onChange(of: googleDriveSyncEnabled) { enabled in
            cloudSyncManager.setProviderEnabled(.googleDrive, enabled: enabled)
            if enabled {
                cloudSyncManager.syncSnapshot(provider: .googleDrive, reason: "enabled")
            }
        }
        .onChange(of: oneDriveSyncEnabled) { enabled in
            cloudSyncManager.setProviderEnabled(.oneDrive, enabled: enabled)
            if enabled {
                cloudSyncManager.syncSnapshot(provider: .oneDrive, reason: "enabled")
            }
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: CloudSyncProvider) -> some View {
        let connected = cloudSyncManager.isProviderConnected(provider)
        let enabled = syncEnabled(for: provider)
        let canUse = cloudSyncManager.canUseProvider(provider)

        GlassSection(header: provider.displayName) {
            VStack(spacing: 0) {
                GlassDetailRow(icon: provider.iconName, iconColor: providerColor(provider), title: providerTitle(provider)) {
                    Text(providerStateText(provider, connected: connected, enabled: enabled))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(providerStateColor(provider, connected: connected, enabled: enabled))
                }

                if let email = cloudSyncManager.connectedAccountEmail(for: provider) {
                    GlassDivider()

                    GlassDetailRow(
                        icon: "person.crop.circle",
                        iconColor: providerColor(provider),
                        title: "Connected Account"
                    ) {
                        Text(email)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                if provider.requiresAccountConnection {
                    GlassDivider()

                    Button {
                        guard isAdministrable else { return }
                        if connected {
                            cloudSyncManager.disconnectProvider(provider)
                        } else {
                            cloudSyncManager.connectProvider(provider)
                        }
                    } label: {
                        GlassDetailRow(
                            icon: connected ? "xmark.circle" : "link",
                            iconColor: connected ? .red : providerColor(provider),
                            title: connected ? "Disconnect" : "Connect"
                        ) {
                            providerAccessory(provider)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAdministrable || cloudSyncManager.isSyncing)
                }

                GlassDivider()

                GlassDetailRow(icon: "arrow.triangle.2.circlepath", iconColor: providerColor(provider), title: "Sync with \(provider.displayName)") {
                    Toggle("", isOn: syncBinding(for: provider))
                        .labelsHidden()
                        .tint(accent)
                        .disabled(!isAdministrable || !canUse || cloudSyncManager.isSyncing)
                }

                if provider == .iCloud, cloudSyncManager.isAppleAccountMediaStateSuspended {
                    GlassDivider()

                    Button {
                        guard isAdministrable else { return }
                        cloudSyncManager.resumeAppleAccountMediaStateSync()
                    } label: {
                        GlassDetailRow(
                            icon: "arrow.clockwise.icloud",
                            iconColor: providerColor(provider),
                            title: "Resume Library Sync"
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAdministrable || cloudSyncManager.isSyncing)
                }

                if enabled, cloudSyncManager.primaryProvider != provider {
                    GlassDivider()

                    Button {
                        guard isAdministrable else { return }
                        cloudSyncManager.makePrimary(provider)
                    } label: {
                        GlassDetailRow(icon: "star", iconColor: .yellow, title: "Make Primary") {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAdministrable || cloudSyncManager.isSyncing)
                }

                GlassDivider()

                Button {
                    guard isAdministrable else { return }
                    cloudSyncManager.syncSnapshot(provider: provider, reason: "manual")
                } label: {
                    GlassDetailRow(icon: "arrow.triangle.2.circlepath", iconColor: .cyan, title: "Sync Now") {
                        providerAccessory(provider)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!isAdministrable || !enabled || !canUse || cloudSyncManager.isSyncing)

                GlassDivider()

                Button {
                    restoreRemoteSnapshot(provider)
                } label: {
                    GlassDetailRow(icon: "arrow.down.doc", iconColor: .indigo, title: "Restore from \(provider.displayName)") {
                        providerAccessory(provider)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!isAdministrable || !enabled || !canUse || cloudSyncManager.isSyncing)

                if connected {
                    GlassDivider(leadingInset: 16)

                    GlassDetailRow(
                        icon: "externaldrive.fill",
                        iconColor: providerColor(provider),
                        title: "Storage Used"
                    ) {
                        if cloudSyncManager.isMeasuringRemoteUsage(for: provider) {
                            EclipseLoadingIndicator()
                                .tint(.white.opacity(0.6))
                        } else {
                            Text(storageUsedText(for: provider))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.white.opacity(0.55))
                        }
                    }
                }

                if isAdministrable {
                    GlassDivider(leadingInset: 16)

                    Button {
                        guard isAdministrable else { return }
                        pendingCloudDataDeletionProvider = provider
                    } label: {
                        GlassDetailRow(
                            icon: "trash",
                            iconColor: .red,
                            title: "Delete Cloud Data"
                        ) {
                            providerAccessory(provider)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!connected || cloudSyncManager.isSyncing)
                }

                let status = cloudSyncManager.statusMessage(for: provider)
                if !status.isEmpty {
                    GlassDivider(leadingInset: 16)
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else if provider == .iCloud && !availability.isAvailable {
                    GlassDivider(leadingInset: 16)
                    Text(availability.statusMessage)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private func restoreRemoteSnapshot(_ provider: CloudSyncProvider) {
        guard isAdministrable else { return }
        cloudSyncManager.restoreRemoteSnapshot(provider: provider)
    }

    private func deleteCloudData(_ provider: CloudSyncProvider) {
        guard isAdministrable else { return }
        cloudSyncManager.deleteRemoteData(for: provider)
    }

    private func storageUsedText(for provider: CloudSyncProvider) -> String {
        guard let usage = cloudSyncManager.remoteUsage(for: provider) else {
            return "Unavailable"
        }
        guard !usage.isEmpty else { return "Not synced yet" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let used = formatter.string(fromByteCount: usage.byteCount)
        let prefix = usage.isComplete ? used : "About \(used)"
        guard !resolvedCloudSyncBudget.isUnlimited else { return prefix }
        return "\(prefix) of \(resolvedCloudSyncBudget.displayName)"
    }

    private var cloudDataDeletionMessage: String {
        let provider = pendingCloudDataDeletionProvider
        let name = provider?.displayName ?? "this provider"
        var message = "This removes every Eclipse backup file from \(name) and cannot be undone. Nothing on this device is deleted, and Eclipse stops uploading backup files here afterwards."
        if provider == .iCloud {
            message += cloudSyncManager.canDeleteAppleAccountMediaState
                ? "\n\nThis covers Eclipse's backup files in iCloud Drive and the library and watch progress Eclipse keeps in your Apple account. This device then stops syncing library and watch progress through your Apple account until you tap Resume Library Sync here."
                : "\n\nThis covers Eclipse's backup files in iCloud Drive. This device cannot reach Eclipse's iCloud database, so library and watch progress stored there are left alone."
        }
        message += provider == .iCloud && cloudSyncManager.canDeleteAppleAccountMediaState
            ? "\n\nYour other devices are not erased and keep syncing. The next one you open uploads its own copy again, so delete from each device you want the account to stay empty for."
            : "\n\nYour other devices are not erased. If any of them still has sync on, the next one you open will upload its own copy again — turn sync off there first if you want the account to stay empty."
        return message
    }

    private func restoreCloudAfterOverwriteWarning() {
        guard isAdministrable else { return }
        cloudSyncManager.restoreCloudAfterOverwriteWarning()
    }

    private func replaceCloudAfterOverwriteWarning() {
        guard isAdministrable else { return }
        cloudSyncManager.replaceCloudAfterOverwriteWarning()
    }

    @ViewBuilder
    private func providerAccessory(_ provider: CloudSyncProvider) -> some View {
        if cloudSyncManager.isBusy(provider) {
            EclipseLoadingIndicator()
                .tint(.white.opacity(0.6))
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    private func providerTitle(_ provider: CloudSyncProvider) -> String {
        switch provider {
        case .iCloud:
            return availability.statusTitle
        case .googleDrive, .oneDrive:
            return provider.displayName
        }
    }

    private func providerStateText(_ provider: CloudSyncProvider, connected: Bool, enabled: Bool) -> String {
        switch provider {
        case .iCloud:
            guard connected else { return "Unavailable" }
            if enabled, cloudSyncManager.primaryProvider == provider { return "Primary · On" }
            return enabled ? "On" : "Off"
        case .googleDrive, .oneDrive:
            guard connected else { return "Not Connected" }
            if enabled, cloudSyncManager.primaryProvider == provider { return "Primary · On" }
            return enabled ? "On" : "Connected"
        }
    }

    private func providerStateColor(_ provider: CloudSyncProvider, connected: Bool, enabled: Bool) -> Color {
        guard connected else { return .orange }
        return enabled ? .green : .white.opacity(0.55)
    }

    private func providerColor(_ provider: CloudSyncProvider) -> Color {
        switch provider {
        case .iCloud:
            return .blue
        case .googleDrive:
            return .green
        case .oneDrive:
            return .cyan
        }
    }

    private func syncEnabled(for provider: CloudSyncProvider) -> Bool {
        switch provider {
        case .iCloud:
            return iCloudSyncEnabled
        case .googleDrive:
            return googleDriveSyncEnabled
        case .oneDrive:
            return oneDriveSyncEnabled
        }
    }

    private func syncBinding(for provider: CloudSyncProvider) -> Binding<Bool> {
        switch provider {
        case .iCloud:
            return Binding(
                get: { iCloudSyncEnabled },
                set: { enabled in
                    guard isAdministrable else { return }
                    iCloudSyncEnabled = enabled
                }
            )
        case .googleDrive:
            return Binding(
                get: { googleDriveSyncEnabled },
                set: { enabled in
                    guard isAdministrable else { return }
                    googleDriveSyncEnabled = enabled
                }
            )
        case .oneDrive:
            return Binding(
                get: { oneDriveSyncEnabled },
                set: { enabled in
                    guard isAdministrable else { return }
                    oneDriveSyncEnabled = enabled
                }
            )
        }
    }
}

@available(iOS 17.0, *)
private struct CloudSyncHealthSection: View {
    @StateObject private var mediaStateSyncManager = MediaStateSyncManager.shared
    @State private var showRecoveryConfirmation = false
    @State private var showRecoveryFailure = false

    var body: some View {
        if let detail = mediaStateSyncManager.canonicalArchiveUnavailabilityDetail {
            GlassSection(header: "Sync Health") {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "exclamationmark.icloud.fill")
                            .font(.title3)
                            .foregroundColor(.orange)
                            .frame(width: 30)

                        Text(detail)
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    if mediaStateSyncManager.isRetainingAccountBoundaryRecovery {
                        GlassDivider()

                        Button {
                            showRecoveryConfirmation = true
                        } label: {
                            GlassDetailRow(
                                icon: "arrow.counterclockwise.circle",
                                iconColor: .orange,
                                title: "Restore From Recovery Point"
                            ) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.3))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            GlassSectionFooter("This device's media state needs recovery, so cloud uploads are paused and incoming sync is held to protect your other devices.")
                .alert("Restore From Recovery Point", isPresented: $showRecoveryConfirmation) {
                    Button("Restore and Resume Sync", role: .destructive) {
                        showRecoveryFailure = !mediaStateSyncManager
                            .recoverRetainedAccountBoundaryArchiveAfterUserConfirmation()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Eclipse kept a recovery point from before the interrupted account change. Restoring it replaces this device's media state with that recovery point and resumes sync. The unreadable data stays on this device.")
                }
                .alert("Recovery Not Completed", isPresented: $showRecoveryFailure) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Eclipse could not finish the recovery and left the recovery point in place. Try again after relaunching the app.")
                }
        } else if mediaStateSyncManager.isRetainingAccountBoundaryRecovery {
            GlassSection(header: "Sync Health") {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3)
                        .foregroundColor(.orange)
                        .frame(width: 30)

                    Text("A sync recovery point is waiting to finish. Cloud uploads stay paused until Eclipse completes it, usually at the next app activation.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }
}
#endif
