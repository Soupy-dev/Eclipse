import SwiftUI
#if os(iOS)
import AuthenticationServices
import Security
import UIKit
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Network)
import Network
#endif

enum MediaDetailPlatformDefaults {
    static let seasonMenuKey = "seasonMenu"
    static let horizontalEpisodeListKey = "horizontalEpisodeList"

    static var prefersCompactSeasonMenu: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
#else
        false
#endif
    }

    static var prefersHorizontalEpisodes: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
#else
        false
#endif
    }

    static func usesCompactSeasonMenu(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: seasonMenuKey) != nil else {
            return prefersCompactSeasonMenu
        }
        return defaults.bool(forKey: seasonMenuKey)
    }

    static func usesHorizontalEpisodes(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: horizontalEpisodeListKey) != nil else {
            return prefersHorizontalEpisodes
        }
        return defaults.bool(forKey: horizontalEpisodeListKey)
    }
}

enum AppPerformanceOverlaySettings {
    static let enabledKey = "appPerformanceOverlayEnabled"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }
}

/// Shared state for the optional lock button used by both in-app video players.
/// The active lock deliberately lives in UserDefaults so a verified next-episode
/// transition or automatic engine handoff cannot silently unlock the new player.
enum PlayerPlaybackLockSettings {
    static let enabledKey = "playerPlaybackLockEnabled"
    static let lockedKey = "playerPlaybackLocked"
    static let orientationKey = "playerPlaybackLockedOrientation"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }

    static func isLocked(defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults: defaults) && defaults.bool(forKey: lockedKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
        if !enabled {
            defaults.set(false, forKey: lockedKey)
            defaults.removeObject(forKey: orientationKey)
        }
    }

#if os(iOS)
    static func setLocked(
        _ locked: Bool,
        interfaceOrientation: UIInterfaceOrientation?,
        defaults: UserDefaults = .standard
    ) {
        guard locked, isEnabled(defaults: defaults) else {
            defaults.set(false, forKey: lockedKey)
            defaults.removeObject(forKey: orientationKey)
            return
        }

        defaults.set(true, forKey: lockedKey)
        if let rawValue = storedOrientationValue(for: interfaceOrientation) {
            defaults.set(rawValue, forKey: orientationKey)
        }
    }

    static func lockedOrientationMask(defaults: UserDefaults = .standard) -> UIInterfaceOrientationMask? {
        guard isLocked(defaults: defaults),
              let rawValue = defaults.string(forKey: orientationKey) else { return nil }
        switch rawValue {
        case "portrait":
            return .portrait
        case "portraitUpsideDown":
            return .portraitUpsideDown
        case "landscapeLeft":
            return .landscapeLeft
        case "landscapeRight":
            return .landscapeRight
        default:
            return nil
        }
    }

    static func capturedInterfaceOrientation(
        scene: UIWindowScene?,
        viewBounds: CGRect
    ) -> UIInterfaceOrientation? {
        if let orientation = scene?.interfaceOrientation, orientation != .unknown {
            return orientation
        }

        switch UIDevice.current.orientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            guard !viewBounds.isEmpty else { return nil }
            return viewBounds.width >= viewBounds.height ? .landscapeRight : .portrait
        }
    }

    private static func storedOrientationValue(for orientation: UIInterfaceOrientation?) -> String? {
        switch orientation {
        case .portrait:
            return "portrait"
        case .portraitUpsideDown:
            return "portraitUpsideDown"
        case .landscapeLeft:
            return "landscapeLeft"
        case .landscapeRight:
            return "landscapeRight"
        default:
            return nil
        }
    }
#endif
}

/// Platform-neutral preference shared by Settings and the iOS SharePlay
/// coordinator. Keeping the key/default here lets tvOS compile the shared
/// settings model without adding GroupActivities code to the tvOS target.
enum WatchTogetherSettings {
    static let enabledKey = "watchTogetherEnabled"
    static let defaultEnabled = true

    /// Unsigned GitHub releases cannot carry SharePlay's group-session
    /// entitlement, so expose Watch Together only in Apple distribution lanes.
    static var isAvailableInCurrentBuild: Bool {
#if os(iOS)
        Bundle.main.isAppleReviewedDistribution
#else
        false
#endif
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard isAvailableInCurrentBuild else { return false }
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }
}

/// The persisted user preference for Google Cast. Availability is separate from
/// the preference itself so an iPhone/iPad setting can safely travel through
/// backups or iCloud without a tvOS build silently changing it.
enum GoogleCastSettings {
    static let enabledKey = "googleCastEnabled"
    static let defaultEnabled = true

    static var isAvailableInCurrentBuild: Bool {
#if os(iOS) && canImport(GoogleCast)
        true
#else
        false
#endif
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }
}

/// Visual presets for Eclipse's MPV control overlay. The default deliberately
/// preserves the player UI that shipped before skins were introduced.
enum MPVPlayerSkin: String, CaseIterable, Identifiable {
    case defaultSkin = "default"
    case blackAndGold = "blackAndGold"
    case prismatic = "prismatic"
    case cyberpunk = "cyberpunk"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .defaultSkin: return "Default"
        case .blackAndGold: return "Black and Gold"
        case .prismatic: return "Prismatic"
        case .cyberpunk: return "Cyberpunk"
        case .custom: return "Custom"
        }
    }

    var settingsDescription: String {
        switch self {
        case .defaultSkin:
            return "The original Eclipse MPV controls."
        case .blackAndGold:
            return "Warm gold controls over a deep black overlay."
        case .prismatic:
            return "A soft animated spectrum with bright controls."
        case .cyberpunk:
            return "Electric cyan and magenta with a subtle neon sweep."
        case .custom:
            return "Choose your own primary and secondary control colors."
        }
    }

    var defaultAnimationStyle: MPVPlayerSkinAnimationStyle {
        switch self {
        case .defaultSkin, .blackAndGold, .custom: return .glow
        case .prismatic: return .spectrum
        case .cyberpunk: return .sweep
        }
    }
}

enum MPVPlayerSkinAnimationStyle: String, CaseIterable, Identifiable {
    case glow
    case spectrum
    case sweep
    case aurora

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glow: return "Glow"
        case .spectrum: return "Spectrum"
        case .sweep: return "Scan"
        case .aurora: return "Aurora"
        }
    }

    var settingsDescription: String {
        switch self {
        case .glow: return "A soft pulse that breathes with the accent color."
        case .spectrum: return "Slowly cycles through the skin's colors."
        case .sweep: return "A light beam that scans across the controls."
        case .aurora: return "Gently drifting ribbons of color."
        }
    }
}

enum MPVPlayerSkinSettings {
    static let skinKey = "mpvPlayerSkin"
    static let customPrimaryColorKey = "mpvPlayerSkinCustomPrimaryColor"
    static let customSecondaryColorKey = "mpvPlayerSkinCustomSecondaryColor"
    static let animationsEnabledKey = "mpvPlayerSkinAnimationsEnabled"
    static let defaultAnimationsEnabled = true
    static let tintControlsOnlyKey = "mpvPlayerSkinTintControlsOnly"
    static let defaultTintControlsOnly = false
    static let animationStyleKeyPrefix = "mpvPlayerSkinAnimationStyle."

    static func selected(defaults: UserDefaults = .standard) -> MPVPlayerSkin {
        let rawValue = defaults.string(forKey: skinKey) ?? ""
        if rawValue == "cypberpunk" { return .cyberpunk }
        return MPVPlayerSkin(rawValue: rawValue) ?? .defaultSkin
    }

    static func animationsEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: animationsEnabledKey) != nil else {
            return defaultAnimationsEnabled
        }
        return defaults.bool(forKey: animationsEnabledKey)
    }

    static func tintControlsOnly(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: tintControlsOnlyKey) != nil else {
            return defaultTintControlsOnly
        }
        return defaults.bool(forKey: tintControlsOnlyKey)
    }

    static func animationStyle(for skin: MPVPlayerSkin, defaults: UserDefaults = .standard) -> MPVPlayerSkinAnimationStyle {
        if let raw = defaults.string(forKey: animationStyleKeyPrefix + skin.rawValue),
           let style = MPVPlayerSkinAnimationStyle(rawValue: raw) {
            return style
        }
        return skin.defaultAnimationStyle
    }

    static func setAnimationStyle(_ style: MPVPlayerSkinAnimationStyle, for skin: MPVPlayerSkin, defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: animationStyleKeyPrefix + skin.rawValue)
    }
}

// Shared media settings and player configuration.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { self.rawValue }
}

enum MediaDetailElement: String, CaseIterable, Identifiable {
    case actions
    case overview
    case details
    case cast
    case similarTitles
    case ratingNotes
    case traktComments
    case episodes
    case stills
    case trailers

    var id: String { rawValue }

    static let orderStorageKey = "mediaDetailElementOrder"
    static let hiddenStorageKey = "mediaDetailHiddenElements"
    static let legacyShowCastStorageKey = "showCastSection"

    static let defaultOrder: [MediaDetailElement] = [
        .overview,
        .actions,
        .details,
        .cast,
        .ratingNotes,
        .traktComments,
        .episodes,
        .stills,
        .trailers,
        .similarTitles
    ]

    var displayName: String {
        switch self {
        case .actions:
            return "Actions"
        case .overview:
            return "Overview"
        case .details:
            return "Details"
        case .cast:
            return "Cast"
        case .similarTitles:
            return "Similar Titles"
        case .ratingNotes:
            return "Rating & Notes"
        case .traktComments:
            return "Trakt Reviews"
        case .episodes:
            return "Episodes"
        case .stills:
            return "Stills"
        case .trailers:
            return "Trailers"
        }
    }

    var settingsDescription: String {
        switch self {
        case .actions:
            return "Play, download, save, and collection controls."
        case .overview:
            return "Synopsis text for the title."
        case .details:
            return "Runtime, genres, dates, status, and ratings."
        case .cast:
            return "Principal cast list."
        case .similarTitles:
            return "TMDB recommendations related to the current title."
        case .ratingNotes:
            return "Your star rating, notes, and tracker sync shortcuts."
        case .traktComments:
            return "Community reviews and comments from Trakt."
        case .episodes:
            return "Seasons, specials, and episode list for series."
        case .stills:
            return "Backdrop stills and gallery images."
        case .trailers:
            return "Trailer and teaser cards."
        }
    }

    var appliesToMovies: Bool {
        self != .episodes
    }

    var appliesToSeries: Bool {
        true
    }

    static var defaultOrderRawValue: String {
        rawValue(for: defaultOrder)
    }

    static func rawValue(for elements: [MediaDetailElement]) -> String {
        elements.map(\.rawValue).joined(separator: ",")
    }

    static func rawValue(for hiddenElements: Set<MediaDetailElement>) -> String {
        defaultOrder
            .filter { hiddenElements.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    static func orderedElements(from rawValue: String?) -> [MediaDetailElement] {
        var result: [MediaDetailElement] = []
        let rawItems = rawValue?
            .split(separator: ",")
            .map { String($0) } ?? []

        for rawItem in rawItems {
            guard let element = MediaDetailElement(rawValue: rawItem),
                  !result.contains(element) else { continue }
            result.append(element)
        }

        for element in defaultOrder where !result.contains(element) {
            result.append(element)
        }

        return result
    }

    static func orderedElements(defaults: UserDefaults = .standard) -> [MediaDetailElement] {
        orderedElements(from: defaults.string(forKey: orderStorageKey))
    }

    static func hiddenElements(from rawValue: String?, legacyShowCastSection: Bool = true) -> Set<MediaDetailElement> {
        var hidden = Set(
            (rawValue ?? "")
                .split(separator: ",")
                .compactMap { MediaDetailElement(rawValue: String($0)) }
        )

        if (rawValue ?? "").isEmpty, !legacyShowCastSection {
            hidden.insert(.cast)
        }

        return hidden
    }

    static func hiddenElements(defaults: UserDefaults = .standard) -> Set<MediaDetailElement> {
        hiddenElements(
            from: defaults.string(forKey: hiddenStorageKey),
            legacyShowCastSection: defaults.object(forKey: legacyShowCastStorageKey) as? Bool ?? true
        )
    }

    static func isVisible(
        _ element: MediaDetailElement,
        hiddenRawValue: String?,
        legacyShowCastSection: Bool = true
    ) -> Bool {
        !hiddenElements(from: hiddenRawValue, legacyShowCastSection: legacyShowCastSection).contains(element)
    }

    static func saveOrder(_ elements: [MediaDetailElement], defaults: UserDefaults = .standard) {
        defaults.set(rawValue(for: elements), forKey: orderStorageKey)
    }

    static func saveHiddenElements(_ hiddenElements: Set<MediaDetailElement>, defaults: UserDefaults = .standard) {
        defaults.set(rawValue(for: hiddenElements), forKey: hiddenStorageKey)
        defaults.set(!hiddenElements.contains(.cast), forKey: legacyShowCastStorageKey)
    }
}

enum MediaDetailSimilarTitlesSettings {
    static let enabledKey = "mediaDetailSimilarTitlesEnabled"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }
}

enum ServicesSheetPresentationSettings {
    static let stremioStyleEnabledKey = "servicesStremioStyleSheetEnabled"
    static let defaultStremioStyleEnabled = false

    static func usesStremioStyle(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: stremioStyleEnabledKey) == nil
            ? defaultStremioStyleEnabled
            : defaults.bool(forKey: stremioStyleEnabledKey)
    }
}

enum ServicesResultRankingSettings {
    static let minimumSimilarityKey = "servicesResultMinimumSimilarity"
    static let dropMismatchedResultsKey = "servicesDropMismatchedResults"
    static let defaultMinimumSimilarity = 0.85
    static let defaultDropMismatchedResults = true
    static let minimumSimilarityRange = 0.50...1.00

    static func minimumSimilarity(defaults: UserDefaults = .standard) -> Double {
        guard let value = defaults.object(forKey: minimumSimilarityKey) as? NSNumber else {
            return defaultMinimumSimilarity
        }
        return clampedMinimumSimilarity(value.doubleValue)
    }

    static func setMinimumSimilarity(_ value: Double, defaults: UserDefaults = .standard) {
        defaults.set(clampedMinimumSimilarity(value), forKey: minimumSimilarityKey)
    }

    static func dropsMismatchedResults(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: dropMismatchedResultsKey) != nil else {
            return defaultDropMismatchedResults
        }
        return defaults.bool(forKey: dropMismatchedResultsKey)
    }

    static func setDropsMismatchedResults(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: dropMismatchedResultsKey)
    }

    static func clampedMinimumSimilarity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMinimumSimilarity }
        return max(minimumSimilarityRange.lowerBound, min(value, minimumSimilarityRange.upperBound))
    }
}

enum NextEpisodeFillerSettings {
    static let enabledKey = "nextEpisodeSkipFillerEnabled"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }
}

#if !os(tvOS)
enum ReaderDetailElement: String, CaseIterable, Identifiable {
    case overview
    case tags
    case ratingNotes
    case chapters

    var id: String { rawValue }

    static let orderStorageKey = "readerDetailElementOrder"
    static let hiddenStorageKey = "readerDetailHiddenElements"

    static let defaultOrder: [ReaderDetailElement] = [
        .overview,
        .tags,
        .ratingNotes,
        .chapters
    ]

    var displayName: String {
        switch self {
        case .overview:
            return "Overview"
        case .tags:
            return "Tags"
        case .ratingNotes:
            return "Rating & Notes"
        case .chapters:
            return "Chapters"
        }
    }

    var settingsDescription: String {
        switch self {
        case .overview:
            return "Synopsis text for the title."
        case .tags:
            return "Genres, tags, and source categories."
        case .ratingNotes:
            return "Your private star rating and reader notes."
        case .chapters:
            return "Source chapter list, language picker, and reading controls."
        }
    }

    static var defaultOrderRawValue: String {
        rawValue(for: defaultOrder)
    }

    static func rawValue(for elements: [ReaderDetailElement]) -> String {
        elements.map(\.rawValue).joined(separator: ",")
    }

    static func rawValue(for hiddenElements: Set<ReaderDetailElement>) -> String {
        defaultOrder
            .filter { hiddenElements.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    static func orderedElements(from rawValue: String?) -> [ReaderDetailElement] {
        var result: [ReaderDetailElement] = []
        let rawItems = rawValue?
            .split(separator: ",")
            .map { String($0) } ?? []

        for rawItem in rawItems {
            guard let element = ReaderDetailElement(rawValue: rawItem),
                  !result.contains(element) else { continue }
            result.append(element)
        }

        for element in defaultOrder where !result.contains(element) {
            result.append(element)
        }

        return result
    }

    static func orderedElements(defaults: UserDefaults = .standard) -> [ReaderDetailElement] {
        orderedElements(from: defaults.string(forKey: orderStorageKey))
    }

    static func hiddenElements(from rawValue: String?) -> Set<ReaderDetailElement> {
        Set(
            (rawValue ?? "")
                .split(separator: ",")
                .compactMap { ReaderDetailElement(rawValue: String($0)) }
        )
    }

    static func hiddenElements(defaults: UserDefaults = .standard) -> Set<ReaderDetailElement> {
        hiddenElements(from: defaults.string(forKey: hiddenStorageKey))
    }

    static func isVisible(_ element: ReaderDetailElement, hiddenRawValue: String?) -> Bool {
        !hiddenElements(from: hiddenRawValue).contains(element)
    }

    static func saveOrder(_ elements: [ReaderDetailElement], defaults: UserDefaults = .standard) {
        defaults.set(rawValue(for: elements), forKey: orderStorageKey)
    }

    static func saveHiddenElements(_ hiddenElements: Set<ReaderDetailElement>, defaults: UserDefaults = .standard) {
        defaults.set(rawValue(for: hiddenElements), forKey: hiddenStorageKey)
    }
}
#endif

enum MPVRenderBackend: String {
    case metal = "metal"

    static let defaultBackend: MPVRenderBackend = .metal
}

enum MPVMetalQualityProfile: String, CaseIterable, Identifiable {
    case auto = "auto"
    case balanced = "balanced"
    case lowHeat = "lowHeat"
    case sharp = "sharp"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "Auto (Let Eclipse decide for your device)"
        case .balanced:
            return "Balanced"
        case .lowHeat:
            return "Low Heat"
        case .sharp:
            return "Sharp"
        }
    }

    var settingsDescription: String {
        switch self {
        case .auto:
            return "Starts sharp and automatically lowers MoltenVK resolution, frame pacing, and high-bit-depth HDR work when the device gets hot, then restores quality as it cools."
        case .balanced:
            return "Caps MoltenVK/sample-buffer output below native 4K while preserving high-bit-depth HDR for lower heat with minimal visible softening."
        case .lowHeat:
            return "Caps MoltenVK/sample-buffer output aggressively and disables high-bit-depth HDR to minimize heat and power use; video looks softer."
        case .sharp:
            return "Allows full-resolution MoltenVK output and high-bit-depth HDR for maximum fidelity at higher power cost."
        }
    }

    static let defaultProfile: MPVMetalQualityProfile = .auto
}

/// Controls the gpu-next (MoltenVK) upscaling + debanding shaders.
enum MPVUpscalingMode: String, CaseIterable, Identifiable {
    /// No quality scaler, no deband - cheap bilinear scaling to fit the screen. The default.
    case off = "off"
    /// EWA Lanczos + deband only for sub-1080p sources (e.g. a 480p/720p stream sharpened toward
    /// 1080p); already-HD video stays on the cheap path. The lightest upscaling mode.
    case upscaleTo1080 = "upscaleTo1080"
    /// EWA Lanczos + deband only for sub-4K sources, with the render target capped around 2160p.
    case upscaleTo4K = "upscaleTo4K"
    /// EWA Lanczos + deband on every source, with the render target capped at roughly one resolution tier above the
    /// source (e.g.
    case oneLevelAlways = "oneLevelAlways"
    /// EWA Lanczos + deband on every source, rendered at full native resolution. Sharpest, costliest
    /// (the former gpu-next "Sharp" scaler behavior).
    case auto = "auto"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .upscaleTo1080: return "Upscale to 1080p"
        case .upscaleTo4K: return "Upscale to 4K"
        case .oneLevelAlways: return "Upscale by one level"
        case .auto: return "Auto (Lanczos + deband)"
        }
    }

    var settingsDescription: String {
        switch self {
        case .off:
            return "No upscaling or debanding - video is scaled cheaply to fit the screen, exactly like the old renderer always did. Lowest heat and battery use."
        case .upscaleTo1080:
            return "Applies Lanczos upscaling and debanding only to below-HD video (under 1080p) that actually benefits - e.g. a 720p stream is sharpened toward 1080p - and leaves already-HD video on the cheap path to save power."
        case .upscaleTo4K:
            return "Applies Lanczos upscaling and debanding to video below 4K and caps the render target around 2160p. Sharper for HD and 1440p sources on high-resolution displays, with a higher power cost."
        case .oneLevelAlways:
            return "Applies Lanczos upscaling and debanding to every source and renders one resolution tier above it (e.g. 1080p toward 1440p), capped at the display. On phone screens HD video is already panel-limited, so this mainly helps below-HD sources and external/AirPlay displays."
        case .auto:
            return "Always applies EWA Lanczos upscaling and debanding at full resolution for the sharpest image, even for video that's already high-resolution. Highest power cost."
        }
    }

    static let defaultMode: MPVUpscalingMode = .off
}

/// "Comfort"/anime-like audio presets applied through mpv audio filters (ffmpeg lavfi: dynamic range compression +
/// loudness.
enum AudioComfortMode: String, CaseIterable, Identifiable {
    /// No processing - the stream's audio is passed through untouched.
    case original
    /// Gentle compression + steady loudness + soft peak limit. Good default for headphones.
    case comfort
    /// Voice-forward: low-rumble cut, stronger compression, mild presence boost around 2.5 kHz.
    case dialogue
    /// Most aggressive: tighter compression, low-end reduction, presence lift, hard peak limit -
    /// the closest to a flat, forward "anime-like" mix that won't stab your ears at night.
    case night

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .comfort: return "Comfort"
        case .dialogue: return "Dialogue"
        case .night: return "Night / Anime-like"
        }
    }

    var settingsDescription: String {
        switch self {
        case .original:
            return "No audio processing - plays the stream's original mix."
        case .comfort:
            return "Gently compresses dynamic range and steadies loudness so quiet dialogue and loud impacts sit closer together, with a soft peak limiter."
        case .dialogue:
            return "Emphasizes voices: cuts low rumble, compresses harder, and lifts presence around 2.5 kHz so speech stays clear."
        case .night:
            return "Strongest leveling - tight compression, reduced low-end boom, a presence lift, and a hard peak limiter so sudden sounds never stab your ears. The most \"anime-like\" mix."
        }
    }

    /// The mpv `af` value. An empty string clears all filters (passthrough). The non-empty values
    /// use the ffmpeg lavfi bridge so they work on any libavfilter-enabled mpv build; if a filter
    /// is unavailable the set simply fails and audio plays unprocessed (logged by the caller).
    var mpvAudioFilterChain: String {
        switch self {
        case .original:
            return ""
        case .comfort:
            return "lavfi=[acompressor=ratio=3:threshold=0.1:attack=20:release=250:makeup=2,dynaudnorm=f=200:g=11:p=0.9:m=10:r=0.5,alimiter=limit=0.9]"
        case .dialogue:
            return "lavfi=[highpass=f=90,acompressor=ratio=4:threshold=0.063:attack=10:release=200:makeup=2,equalizer=f=2500:width_type=q:width=1.4:gain=3.5,dynaudnorm=f=200:g=11:p=0.9:m=10,alimiter=limit=0.9]"
        case .night:
            return "lavfi=[acompressor=ratio=4:threshold=0.05:attack=15:release=250:makeup=2.5,equalizer=f=3000:width_type=q:width=1.5:gain=2,equalizer=f=110:width_type=q:width=1.0:gain=-4,dynaudnorm=f=150:g=9:p=0.9:m=12,alimiter=limit=0.85]"
        }
    }

    static let defaultMode: AudioComfortMode = .original
}

/// Content categories the `AudioComfortMode` processing can be scoped to.
enum AudioComfortContentCategory: String, CaseIterable, Identifiable {
    /// Japanese/Asian animation (anime markers: tracker context, AniList/Kitsu IDs, anime flag).
    case anime
    /// Non-anime animation - western cartoons (TMDB Animation genre 16, not detected as anime).
    case westernAnimation
    /// Everything else (films, series, documentaries).
    case liveAction

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anime: return "Anime"
        case .westernAnimation: return "Western Animation"
        case .liveAction: return "Live Action"
        }
    }

    /// The default scope: apply to all content (equivalent to selecting "All").
    static var defaultScope: Set<AudioComfortContentCategory> { Set(allCases) }
}

/// Controls how the MoltenVK/gpu-next renderer treats standard HDR video.
enum MPVHDRMode: String, CaseIterable, Identifiable {
    /// Pass HDR through to the display when it has EDR headroom; tone-map to SDR otherwise.
    case auto
    /// Always request HDR/EDR output for HDR content, regardless of display detection.
    case hdr
    /// Always tone-map HDR down to SDR for a consistent look across every display.
    case sdr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .hdr: return "Always HDR"
        case .sdr: return "Always SDR"
        }
    }

    var settingsDescription: String {
        switch self {
        case .auto:
            return "Uses HDR/EDR output on capable displays and cleanly tone-maps to SDR everywhere else. Recommended."
        case .hdr:
            return "Always sends HDR content to the display as HDR. May look washed out or too dark on non-HDR screens."
        case .sdr:
            return "Always tone-maps HDR content down to SDR for a consistent picture on any display."
        }
    }

    static let defaultMode: MPVHDRMode = .auto
}

struct MPVRenderBackendSupport {
    static let bundledMPVKitVersion = "eclipse-mpv-metal"
    // The app uses the canonical local override during development and CI checks out the same
    // branch into that path. Exact revision details belong to the MPVKit checkout itself.
    static let bundledMPVKitRevision = "local override"
    static let bundledMPVKitSupportsMoltenVKInlineRendering = true
    static let metalRendererEnabled = true

    #if ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER
    static let moltenVKInlineRendererAvailable = true
    #else
    static let moltenVKInlineRendererAvailable = false
    #endif

    #if ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
    static let sampleBufferPictureInPictureBridgeAvailable = true
    #else
    static let sampleBufferPictureInPictureBridgeAvailable = false
    #endif

    #if ECLIPSE_MPVKIT_METAL_BITMAP_SUBTITLES_VALIDATED
    static let metalBitmapSubtitlesValidated = true
    #else
    static let metalBitmapSubtitlesValidated = false
    #endif
    static let metalBitmapSubtitlesAllowed = true

    #if ECLIPSE_MPVKIT_METAL_LIVE_QUALITY_RECONFIGURE
    static let metalLiveQualityReconfigurationAvailable = true
    #else
    static let metalLiveQualityReconfigurationAvailable = false
    #endif

    static var moltenVKMetalBackendAvailable: Bool {
        bundledMPVKitSupportsMoltenVKInlineRendering
            && moltenVKInlineRendererAvailable
    }

    static var metalIsFullySupported: Bool {
        metalRendererEnabled && moltenVKMetalBackendAvailable
    }

    static var diagnosticsSummary: String {
        [
            "mpvKit=\(bundledMPVKitVersion)",
            "revision=\(bundledMPVKitRevision)",
            "moltenVKInline=\(bundledMPVKitSupportsMoltenVKInlineRendering)",
            "inlineRenderer=\(moltenVKInlineRendererAvailable)",
            "gpuSampleBufferPiP=\(sampleBufferPictureInPictureBridgeAvailable)",
            "moltenVKRendererEnabled=\(metalRendererEnabled)",
            "bitmapSubsAllowed=\(metalBitmapSubtitlesAllowed)",
            "bitmapSubsValidated=\(metalBitmapSubtitlesValidated)",
            "liveQuality=\(metalLiveQualityReconfigurationAvailable)"
        ].joined(separator: " ")
    }

    static var settingsDescription: String {
        if metalIsFullySupported {
            return "MPV uses the MoltenVK gpu-next renderer with a GPU sample-buffer handoff for PiP."
        }
        return "MoltenVK playback is unavailable in this build."
    }

    static var settingsStatusLine: String {
        if metalIsFullySupported {
            return "MoltenVK backend: gpu-next inline renderer with GPU sample-buffer PiP handoff"
        }
        if !metalRendererEnabled {
            return "MoltenVK backend: hidden in this build"
        }
        return "MoltenVK backend: waiting for inline renderer"
    }

    static func fallbackReason(hasMetalDevice: Bool) -> String? {
        guard metalRendererEnabled else { return "MoltenVK renderer hidden in this build" }
        guard hasMetalDevice else { return "MoltenVK device unavailable" }
        guard moltenVKInlineRendererAvailable else {
            return "MPVKit \(bundledMPVKitVersion) bundled in this build does not expose the MoltenVK inline renderer path"
        }
        return nil
    }
}

enum ExperimentalFeatureState {
    static let enabledKey = "experimentalFeaturesEnabled"
    static let lastChangedAtKey = "experimentalFeaturesLastChangedAt"

    static let mpvPreloadEnabledKey = "experimentalMPVPreloadEnabled"
    static let mpvSmoothTransitionEnabledKey = "experimentalMPVSmoothTransitionEnabled"
    static let mpvPreloadCellularEnabledKey = "experimentalMPVPreloadCellularEnabled"
    static let mpvPreloadWifiLimitMBKey = "experimentalMPVPreloadWifiLimitMB"
    static let mpvPreloadCellularLimitMBKey = "experimentalMPVPreloadCellularLimitMB"
    static let mpvPreloadAutoClearKey = "experimentalMPVPreloadAutoClear"
    static let mpvShowRemainingTimeKey = "experimentalMPVShowRemainingTime"
    static let mpvPreciseProgressKey = "experimentalMPVPreciseProgress"
    static let mpvIgnoreSpecialSubtitleStylesKey = "experimentalMPVIgnoreSpecialSubtitleStyles"
    static let iCloudSyncEnabledKey = "experimentalICloudSyncEnabled"

    static let mpvPreloadWifiDefaultLimitMB = 2048
    static let mpvPreloadCellularDefaultLimitMB = 500
    static let mpvPreloadWifiLimitRange = 32...2048
    static let mpvPreloadCellularLimitRange = 8...2048

    static func clampedMPVPreloadWifiLimitMB(_ value: Int) -> Int {
        max(mpvPreloadWifiLimitRange.lowerBound, min(value, mpvPreloadWifiLimitRange.upperBound))
    }

    static func clampedMPVPreloadCellularLimitMB(_ value: Int) -> Int {
        max(mpvPreloadCellularLimitRange.lowerBound, min(value, mpvPreloadCellularLimitRange.upperBound))
    }

    static func resolvedMPVPreloadWifiLimitMB(_ value: Int) -> Int {
        clampedMPVPreloadWifiLimitMB(value > 0 ? value : mpvPreloadWifiDefaultLimitMB)
    }

    static func resolvedMPVPreloadCellularLimitMB(_ value: Int) -> Int {
        clampedMPVPreloadCellularLimitMB(value > 0 ? value : mpvPreloadCellularDefaultLimitMB)
    }

    // Modern interface is the default. Use object(forKey:) so a fresh install
    // (key unset, before registerDefaults runs) still resolves to `true`.
    private(set) static var isEnabledAtLaunch: Bool = {
#if os(tvOS)
        true
#else
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
#endif
    }()

    static func configureLaunchState(defaults: UserDefaults = .standard) {
        registerDefaults(defaults: defaults)
#if os(tvOS)
        isEnabledAtLaunch = true
#else
        isEnabledAtLaunch = (defaults.object(forKey: enabledKey) as? Bool) ?? true
#endif
    }

    static func registerDefaults(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            enabledKey: true,
            mpvPreloadEnabledKey: true,
            mpvSmoothTransitionEnabledKey: true,
            mpvPreloadCellularEnabledKey: false,
            mpvPreloadWifiLimitMBKey: mpvPreloadWifiDefaultLimitMB,
            mpvPreloadCellularLimitMBKey: mpvPreloadCellularDefaultLimitMB,
            mpvPreloadAutoClearKey: true,
            mpvShowRemainingTimeKey: true,
            mpvPreciseProgressKey: true,
            mpvIgnoreSpecialSubtitleStylesKey: false,
            iCloudSyncEnabledKey: false
        ])
    }

    static var currentStoredValue: Bool {
#if os(tvOS)
        true
#else
        UserDefaults.standard.bool(forKey: enabledKey)
#endif
    }

    static func setStoredValue(_ enabled: Bool, defaults: UserDefaults = .standard) {
#if !os(tvOS)
        defaults.set(enabled, forKey: enabledKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastChangedAtKey)
#endif
    }

    static var isMPVPlaybackDefault: Bool {
        let external = UserDefaults.standard.string(forKey: "externalPlayer") ?? ""
        let usesInternalPlayer = external.isEmpty || external == "none" || external == "Default"
        let primary = PlaybackLaunchPlan.make(
            selection: .selected,
            deviceFamily: .current
        ).primary
        return primary == .mpv && usesInternalPlayer
    }

    static var isMetalMPVPlaybackDefault: Bool {
        isMPVPlaybackDefault && MPVRenderBackendSupport.metalIsFullySupported
    }

    static var mpvAdvancedPlaybackUnavailableReason: String? {
        let primary = PlaybackLaunchPlan.make(
            selection: .selected,
            deviceFamily: .current
        ).primary
        guard primary == .mpv else { return "mpv-not-default" }

        let external = UserDefaults.standard.string(forKey: "externalPlayer") ?? ""
        let usesInternalPlayer = external.isEmpty || external == "none" || external == "Default"
        guard usesInternalPlayer else { return "external-player-enabled" }

        guard MPVRenderBackendSupport.metalIsFullySupported else {
            return MPVRenderBackendSupport.fallbackReason(hasMetalDevice: true) ?? "moltenvk-renderer-unavailable"
        }

        return nil
    }

    static var isMPVAdvancedPlaybackAvailable: Bool {
        mpvAdvancedPlaybackUnavailableReason == nil
    }

    static var canUseExperimentalMPVPlayback: Bool {
        isMPVAdvancedPlaybackAvailable
    }
}

#if os(iOS)
private let eclipseCloudSnapshotFileName = "EclipseExperimentalSync-v2.json"
private let eclipseLegacyCloudSnapshotFileName = "EclipseExperimentalSync.json"

enum CloudSyncProvider: String, CaseIterable, Identifiable, Hashable, Sendable {
    case iCloud = "icloud"
    case googleDrive = "googleDrive"
    case oneDrive = "oneDrive"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iCloud: return "iCloud"
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        }
    }

    var iconName: String {
        switch self {
        case .iCloud: return "icloud.fill"
        case .googleDrive: return "externaldrive.fill"
        case .oneDrive: return "cloud.fill"
        }
    }

    var syncEnabledKey: String {
        switch self {
        case .iCloud: return ExperimentalFeatureState.iCloudSyncEnabledKey
        case .googleDrive: return "experimentalGoogleDriveSyncEnabled"
        case .oneDrive: return "experimentalOneDriveSyncEnabled"
        }
    }

    var lastSeenRemoteModificationKey: String {
        switch self {
        case .iCloud:
            return "experimentalICloudSyncLastSeenRemoteModificationAt"
        case .googleDrive:
            return "experimentalGoogleDriveSyncLastSeenRemoteModificationAt"
        case .oneDrive:
            return "experimentalOneDriveSyncLastSeenRemoteModificationAt"
        }
    }

    var lastSyncedFootprintKey: String {
        "experimentalCloudSyncLastFootprintV1.\(rawValue)"
    }

    var accountIdentityKey: String {
        "experimentalCloudSyncAccountIdentityV1.\(rawValue)"
    }

    var lastSeenRemoteRevisionKey: String {
        "experimentalCloudSyncLastRemoteRevisionV1.\(rawValue)"
    }

    var lastAutomaticAttemptKey: String {
        "experimentalCloudSyncLastAutomaticAttemptV1.\(rawValue)"
    }

    var retryNotBeforeKey: String {
        "experimentalCloudSyncRetryNotBeforeV1.\(rawValue)"
    }

    var lastSuccessfulSyncKey: String {
        "experimentalCloudSyncLastSuccessfulSyncV1.\(rawValue)"
    }

    var requiresAccountConnection: Bool {
        self != .iCloud
    }
}

struct ExperimentalCloudSyncAvailability {
    let isAvailable: Bool
    let statusTitle: String
    let statusMessage: String

    static var current: ExperimentalCloudSyncAvailability {
        let fileManager = FileManager.default
        if fileManager.url(forUbiquityContainerIdentifier: nil) != nil {
            return ExperimentalCloudSyncAvailability(
                isAvailable: true,
                statusTitle: "iCloud Available",
                statusMessage: "This build has access to the signed-in iCloud account. Eclipse can sync selected app state with iCloud, Google Drive, or OneDrive."
            )
        }

        if fileManager.ubiquityIdentityToken == nil {
            return ExperimentalCloudSyncAvailability(
                isAvailable: false,
                statusTitle: "iCloud Account Required",
                statusMessage: "Sign in to iCloud and enable iCloud Drive on this device to use iCloud. Google Drive and OneDrive can still be connected below."
            )
        }

        if isTestFlightBuild {
            return ExperimentalCloudSyncAvailability(
                isAvailable: false,
                statusTitle: "iCloud Container Unavailable",
                statusMessage: "This TestFlight build is installed, but iOS has not exposed Eclipse's iCloud container. Google Drive and OneDrive can still be connected below."
            )
        }

        return ExperimentalCloudSyncAvailability(
            isAvailable: false,
            statusTitle: "iCloud Unavailable",
            statusMessage: "iCloud requires the app entitlement. Google Drive and OneDrive use their own account connections."
        )
    }

    private static var isTestFlightBuild: Bool {
        let channel = Bundle.main.infoDictionary?["EclipseDistributionChannel"] as? String
        return channel?.caseInsensitiveCompare("TestFlight") == .orderedSame
    }
}

enum ExperimentalCloudReconciliationAction: Equatable {
    case restoreRemote
    case concurrentConflict
    case remoteWouldReduceLocalData
}

/// Pure decision seam for the destructive part of whole-snapshot
/// reconciliation. Keeping this independent from provider I/O makes the
/// conflict rules deterministic and directly testable.
struct ExperimentalCloudReconciliationPolicy {
    static func actionForUnseenRemote(
        local: ExperimentalCloudSnapshotFootprint,
        remote: ExperimentalCloudSnapshotFootprint,
        previous: ExperimentalCloudSnapshotFootprint?
    ) -> ExperimentalCloudReconciliationAction {
        let localChangedSinceBaseline: Bool
        if let previous {
            localChangedSinceBaseline = local.hasDifferentContent(than: previous)
        } else {
            localChangedSinceBaseline = local.meaningfulRecordCount > 0
        }

        if localChangedSinceBaseline && local.hasDifferentContent(than: remote) {
            return .concurrentConflict
        }
        if local.hasAnyMoreData(than: remote) {
            return .remoteWouldReduceLocalData
        }
        return .restoreRemote
    }
}

struct ExperimentalCloudSyncErrorPolicy {
    static func requiresFreshAuthorization(statusCode: Int, body: String) -> Bool {
        statusCode == 401 ||
            (statusCode == 400 && body.localizedCaseInsensitiveContains("invalid_grant"))
    }

    static func message(
        provider: CloudSyncProvider,
        statusCode: Int,
        body: String
    ) -> String {
        if requiresFreshAuthorization(statusCode: statusCode, body: body) {
            return "Your \(provider.displayName) connection expired. Connect it again to resume sync."
        }
        if statusCode == 429 ||
            (statusCode == 403 &&
             (body.localizedCaseInsensitiveContains("rateLimit") ||
              body.localizedCaseInsensitiveContains("rate_limit"))) {
            return "\(provider.displayName) is temporarily limiting sync requests. Eclipse will retry later."
        }
        if statusCode == 507 ||
            body.localizedCaseInsensitiveContains("quotaExceeded") ||
            body.localizedCaseInsensitiveContains("storageQuota") {
            return "\(provider.displayName) does not have enough available storage for this snapshot."
        }
        if (500...599).contains(statusCode) {
            return "\(provider.displayName) is temporarily unavailable. Eclipse will retry later."
        }
        if statusCode == 403 {
            return "\(provider.displayName) denied access to Eclipse's app folder. Reconnect the account and try again."
        }
        return "\(provider.displayName) could not complete the sync request (HTTP \(statusCode))."
    }
}

@MainActor
final class ExperimentalCloudSyncManager: ObservableObject {
    static let shared = ExperimentalCloudSyncManager()
    private static let primaryProviderKey = "experimentalCloudSyncPrimaryProviderV1"

    @Published private(set) var isSyncing = false
    @Published private(set) var activeProvider: CloudSyncProvider?
    @Published private(set) var lastStatusMessage: String = ""
    @Published private(set) var lastSyncDate: Date?
    @Published private var providerStatusMessages: [CloudSyncProvider: String] = [:]
    @Published private var providerLastSyncDates: [CloudSyncProvider: Date] = [:]
    @Published private(set) var connectionStateVersion = 0
    @Published private(set) var overwriteWarning: CloudSyncOverwriteWarning?
    @Published private(set) var primaryProvider: CloudSyncProvider?

    private static let snapshotFileName = eclipseCloudSnapshotFileName
    private static let legacySnapshotFileName = eclipseLegacyCloudSnapshotFileName
    private static let maximumCloudControlResponseBytes = 2_000_000
    nonisolated private static let maximumCloudSnapshotBytes = 50_000_000
    private static let maximumCloudErrorPreviewBytes = 32_768
    private static let googleClientID = "871649357486-168i49j7ouc70r4t879112h65kmdilit.apps.googleusercontent.com"
    private static let googleURLScheme = "com.googleusercontent.apps.871649357486-168i49j7ouc70r4t879112h65kmdilit"
    private static let microsoftClientID = "a4361dcd-07d3-46b7-9509-1f8ed0ee03ba"
    private static let microsoftTenant = "common"
    private static let microsoftRedirectURI = "msauth.app.Eclipse.Soupy://auth"

    private let authPresentationContextProvider = CloudSyncAuthPresentationContextProvider()
    private var authenticationSession: ASWebAuthenticationSession?
    private var pendingAutomaticSyncTask: Task<Void, Never>?
    private var pendingChangeDuringSync = false
    private var queuedOverwriteWarnings: [CloudSyncOverwriteWarning] = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        let defaults = UserDefaults.standard
        for provider in CloudSyncProvider.allCases {
            let timestamp = defaults.double(forKey: provider.lastSuccessfulSyncKey)
            guard timestamp > 0 else { continue }
            let date = Date(timeIntervalSince1970: timestamp)
            providerLastSyncDates[provider] = date
            providerStatusMessages[provider] = "Last synced \(Self.relativeSyncTime(for: date))"
        }
        lastSyncDate = providerLastSyncDates.values.max()
        if let rawPrimary = defaults.string(forKey: Self.primaryProviderKey),
           let preferred = CloudSyncProvider(rawValue: rawPrimary),
           defaults.bool(forKey: preferred.syncEnabledKey) {
            primaryProvider = preferred
        } else {
            primaryProvider = CloudSyncProvider.allCases.first {
                defaults.bool(forKey: $0.syncEnabledKey)
            }
            if let primaryProvider {
                defaults.set(primaryProvider.rawValue, forKey: Self.primaryProviderKey)
            } else {
                defaults.removeObject(forKey: Self.primaryProviderKey)
            }
        }
        BackupManager.shared.recoverInterruptedExperimentalCloudRestoreIfNeeded()
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .libraryDataDidChange,
            .progressDataDidChange,
            .userRatingDataDidChange,
            .catalogDataDidChange,
            .skyStreamMetadataDidChange,
            UserDefaults.didChangeNotification
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleAutomaticSync()
                }
            }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        pendingAutomaticSyncTask?.cancel()
    }

    func syncOnActivationIfNeeded(reason: String) {
        guard ExperimentalFeatureState.isEnabledAtLaunch else { return }
        let providers = enabledProvidersForAutomaticSync()
        guard !providers.isEmpty else { return }

        let now = Date()
        let nextAllowedByProvider = Dictionary(uniqueKeysWithValues: providers.map { provider -> (CloudSyncProvider, Date) in
            let defaults = UserDefaults.standard
            let attempt = defaults.double(forKey: provider.lastAutomaticAttemptKey)
            let retry = defaults.double(forKey: provider.retryNotBeforeKey)
            let attemptDate = attempt > 0 ? Date(timeIntervalSince1970: attempt + 300) : .distantPast
            let retryDate = retry > 0 ? Date(timeIntervalSince1970: retry) : .distantPast
            return (provider, max(attemptDate, retryDate))
        })
        let readyProviders = providers.filter { (nextAllowedByProvider[$0] ?? .distantPast) <= now }
        let delayedDates = providers.compactMap { provider -> Date? in
            guard let date = nextAllowedByProvider[provider], date > now else { return nil }
            return date
        }

        if let nextDelayed = delayedDates.min() {
            scheduleAutomaticSync(after: nextDelayed.timeIntervalSince(now), reason: reason)
        }
        guard !readyProviders.isEmpty else {
            return
        }

        syncProviders(readyProviders, reason: reason, automatic: true)
    }

    func syncSnapshot(reason: String = "manual") {
        syncProviders(enabledProvidersForManualSync(), reason: reason)
    }

    func syncSnapshot(provider: CloudSyncProvider, reason: String = "manual") {
        runProviderTask(provider: provider, statusPrefix: "Synced") {
            try await Self.reconcileSnapshot(provider: provider, reason: reason)
        }
    }

    func pushLocalSnapshot(reason: String = "manual") {
        syncSnapshot(provider: .iCloud, reason: reason)
    }

    func restoreRemoteSnapshot() {
        restoreRemoteSnapshot(provider: .iCloud)
    }

    func restoreRemoteSnapshot(provider: CloudSyncProvider) {
        runProviderTask(provider: provider, statusPrefix: "Restored") {
            try await Self.restoreRemoteSnapshotSafely(provider: provider)
        }
    }

    func cancelOverwriteWarning() {
        advanceOverwriteWarning()
    }

    func restoreCloudAfterOverwriteWarning() {
        guard let warning = overwriteWarning else { return }
        advanceOverwriteWarning()
        runProviderTask(provider: warning.provider, statusPrefix: "Restored") {
            try await Self.restoreRemoteSnapshot(provider: warning.provider)
        }
    }

    func replaceCloudAfterOverwriteWarning() {
        guard let warning = overwriteWarning else { return }
        advanceOverwriteWarning()
        runProviderTask(provider: warning.provider, statusPrefix: "Replaced cloud backup") {
            try await Self.writeLocalSnapshot(
                provider: warning.provider,
                reason: "confirmed-destructive-replacement"
            )
        }
    }

    func connectProvider(_ provider: CloudSyncProvider) {
        guard provider.requiresAccountConnection else { return }
        guard !isSyncing else { return }

        isSyncing = true
        activeProvider = provider
        setStatus("Connecting to \(provider.displayName)...", for: provider)

        Task {
            do {
                let token = try await authorize(provider: provider)
                try CloudSyncTokenStore.save(token, for: provider)
                // A newly authorized account must never inherit reconciliation
                // markers from a previously connected account.
                UserDefaults.standard.removeObject(forKey: provider.lastSeenRemoteModificationKey)
                UserDefaults.standard.removeObject(forKey: provider.lastSyncedFootprintKey)
                UserDefaults.standard.removeObject(forKey: provider.lastSeenRemoteRevisionKey)
                setProviderEnabled(provider, enabled: true)
                connectionStateVersion += 1

                let date = try await Self.reconcileSnapshot(provider: provider, reason: "connected")
                completeProviderTask(provider: provider, statusPrefix: "Connected and synced", date: date)
            } catch {
                failProviderTask(provider: provider, error: error)
            }
        }
    }

    func disconnectProvider(_ provider: CloudSyncProvider) {
        guard provider.requiresAccountConnection else { return }
        CloudSyncTokenStore.deleteToken(for: provider)
        setProviderEnabled(provider, enabled: false)
        connectionStateVersion += 1
        let message = "Disconnected from \(provider.displayName)."
        setStatus(message, for: provider)
        lastStatusMessage = message
    }

    func isProviderConnected(_ provider: CloudSyncProvider) -> Bool {
        switch provider {
        case .iCloud:
            return ExperimentalCloudSyncAvailability.current.isAvailable
        case .googleDrive, .oneDrive:
            _ = connectionStateVersion
            return CloudSyncTokenStore.token(for: provider) != nil
        }
    }

    func statusMessage(for provider: CloudSyncProvider) -> String {
        providerStatusMessages[provider] ?? ""
    }

    func lastSyncDate(for provider: CloudSyncProvider) -> Date? {
        providerLastSyncDates[provider]
    }

    func isBusy(_ provider: CloudSyncProvider) -> Bool {
        isSyncing && activeProvider == provider
    }

    func canUseProvider(_ provider: CloudSyncProvider) -> Bool {
        switch provider {
        case .iCloud:
            return ExperimentalCloudSyncAvailability.current.isAvailable
        case .googleDrive, .oneDrive:
            return isProviderConnected(provider)
        }
    }

    func setProviderEnabled(_ provider: CloudSyncProvider, enabled: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: provider.syncEnabledKey)
        if enabled {
            // The most recently enabled provider is the least surprising first
            // authority, while every other enabled provider remains active.
            makePrimary(provider)
        } else if primaryProvider == provider {
            let replacement = CloudSyncProvider.allCases.first {
                $0 != provider && defaults.bool(forKey: $0.syncEnabledKey)
            }
            primaryProvider = replacement
            if let replacement {
                defaults.set(replacement.rawValue, forKey: Self.primaryProviderKey)
            } else {
                defaults.removeObject(forKey: Self.primaryProviderKey)
            }
        }
        connectionStateVersion += 1
    }

    func makePrimary(_ provider: CloudSyncProvider) {
        guard UserDefaults.standard.bool(forKey: provider.syncEnabledKey) else { return }
        primaryProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.primaryProviderKey)
        connectionStateVersion += 1
    }

    private func enabledProvidersForAutomaticSync() -> [CloudSyncProvider] {
        let enabled = CloudSyncProvider.allCases.filter { provider in
            UserDefaults.standard.bool(forKey: provider.syncEnabledKey) && canUseProvider(provider)
        }
        guard !enabled.isEmpty else { return [] }

        let first = primaryProvider.flatMap { enabled.contains($0) ? $0 : nil } ?? enabled[0]
        return [first] + enabled.filter { $0 != first }
    }

    private func scheduleAutomaticSync() {
        guard ExperimentalFeatureState.isEnabledAtLaunch,
              !enabledProvidersForAutomaticSync().isEmpty else {
            return
        }

        if isSyncing {
            pendingChangeDuringSync = true
            return
        }

        scheduleAutomaticSync(after: 2, reason: "local-change")
    }

    private func scheduleAutomaticSync(after delay: TimeInterval, reason: String) {
        pendingAutomaticSyncTask?.cancel()
        pendingAutomaticSyncTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(0, min(delay, 86_400)) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.pendingAutomaticSyncTask = nil
            self.syncOnActivationIfNeeded(reason: reason)
        }
    }

    private func enabledProvidersForManualSync() -> [CloudSyncProvider] {
        let providers = enabledProvidersForAutomaticSync()
        if providers.isEmpty {
            lastStatusMessage = "Enable at least one cloud sync provider first."
        }
        return providers
    }

    private func syncProviders(
        _ providers: [CloudSyncProvider],
        reason: String,
        automatic: Bool = false
    ) {
        guard !providers.isEmpty, !isSyncing else { return }
        if automatic {
            let timestamp = Date().timeIntervalSince1970
            providers.forEach {
                UserDefaults.standard.set(timestamp, forKey: $0.lastAutomaticAttemptKey)
            }
        }
        isSyncing = true
        activeProvider = nil

        Task {
            var syncedCount = 0
            var lastDate: Date?
            var failedProviders: [CloudSyncProvider] = []

            for provider in providers {
                activeProvider = provider
                do {
                    let date = try await Self.reconcileSnapshot(provider: provider, reason: reason)
                    syncedCount += 1
                    lastDate = date
                    setStatus("Synced \(Self.relativeSyncTime(for: date))", for: provider)
                    recordSuccessfulSync(date, for: provider)
                } catch {
                    failedProviders.append(provider)
                    handleProviderFailure(provider: provider, error: error)
                }
            }

            activeProvider = nil
            isSyncing = false
            if let lastDate, syncedCount > 0 {
                lastSyncDate = lastDate
                lastStatusMessage = syncedCount == 1
                    ? "Synced 1 provider \(Self.relativeSyncTime(for: lastDate))"
                    : "Synced \(syncedCount) providers \(Self.relativeSyncTime(for: lastDate))"
            } else {
                lastStatusMessage = "Cloud sync could not complete."
            }
            if automatic, !failedProviders.isEmpty {
                scheduleAutomaticRetry(for: failedProviders)
            }
            scheduleFollowUpIfNeeded(afterSyncing: providers)
        }
    }

    private func runProviderTask(
        provider: CloudSyncProvider,
        statusPrefix: String,
        operation: @escaping () async throws -> Date
    ) {
        guard !isSyncing else { return }
        guard UserDefaults.standard.bool(forKey: provider.syncEnabledKey) else {
            setStatus("Enable \(provider.displayName) sync first.", for: provider)
            return
        }
        guard canUseProvider(provider) else {
            setStatus(unavailableMessage(for: provider), for: provider)
            return
        }

        isSyncing = true
        activeProvider = provider

        Task {
            do {
                let date = try await operation()
                completeProviderTask(provider: provider, statusPrefix: statusPrefix, date: date)
            } catch {
                failProviderTask(provider: provider, error: error)
            }
        }
    }

    private func completeProviderTask(provider: CloudSyncProvider, statusPrefix: String, date: Date) {
        let message = "\(statusPrefix) \(Self.relativeSyncTime(for: date))"
        recordSuccessfulSync(date, for: provider)
        setStatus(message, for: provider)
        lastSyncDate = date
        lastStatusMessage = "\(provider.displayName): \(message)"
        activeProvider = nil
        isSyncing = false
        scheduleFollowUpIfNeeded(afterSyncing: [provider])
    }

    private func failProviderTask(provider: CloudSyncProvider, error: Error) {
        handleProviderFailure(provider: provider, error: error)
        lastStatusMessage = "\(provider.displayName): \(statusMessage(for: provider))"
        activeProvider = nil
        isSyncing = false
        scheduleFollowUpIfNeeded(afterSyncing: [provider])
    }

    private func handleProviderFailure(provider: CloudSyncProvider, error: Error) {
        presentOverwriteWarningIfNeeded(provider: provider, error: error)

        if provider.requiresAccountConnection, Self.requiresFreshAuthorization(error) {
            CloudSyncTokenStore.deleteToken(for: provider)
            setProviderEnabled(provider, enabled: false)
            setStatus("Your \(provider.displayName) connection expired. Connect it again to resume sync.", for: provider)
        } else {
            setStatus(error.localizedDescription, for: provider)
        }

        Logger.shared.log(
            "Cloud sync failed provider=\(provider.rawValue) errorType=\(String(reflecting: type(of: error)))",
            type: "CloudSync"
        )
    }

    private static func requiresFreshAuthorization(_ error: Error) -> Bool {
        switch error {
        case SyncError.authenticationRequired:
            return true
        case let SyncError.remoteRequestFailed(_, statusCode, body):
            return ExperimentalCloudSyncErrorPolicy.requiresFreshAuthorization(
                statusCode: statusCode,
                body: body
            )
        default:
            return false
        }
    }

    private func presentOverwriteWarningIfNeeded(provider: CloudSyncProvider, error: Error) {
        switch error {
        case let SyncError.suspiciousLocalReduction(_, localCount, remoteCount):
            enqueueOverwriteWarning(CloudSyncOverwriteWarning(
                provider: provider,
                localRecordCount: localCount,
                remoteRecordCount: remoteCount,
                direction: .cloudIsFuller
            ))
        case let SyncError.suspiciousRemoteReduction(_, localCount, remoteCount):
            enqueueOverwriteWarning(CloudSyncOverwriteWarning(
                provider: provider,
                localRecordCount: localCount,
                remoteRecordCount: remoteCount,
                direction: .deviceIsFuller
            ))
        case let SyncError.concurrentSnapshotConflict(_, localCount, remoteCount):
            enqueueOverwriteWarning(CloudSyncOverwriteWarning(
                provider: provider,
                localRecordCount: localCount,
                remoteRecordCount: remoteCount,
                direction: .bothChanged
            ))
        default:
            break
        }
    }

    private func enqueueOverwriteWarning(_ warning: CloudSyncOverwriteWarning) {
        queuedOverwriteWarnings.removeAll { $0.provider == warning.provider }
        if overwriteWarning == nil {
            overwriteWarning = warning
        } else if overwriteWarning?.provider != warning.provider {
            queuedOverwriteWarnings.append(warning)
        }
    }

    private func advanceOverwriteWarning() {
        overwriteWarning = nil
        guard !queuedOverwriteWarnings.isEmpty else { return }
        let next = queuedOverwriteWarnings.removeFirst()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, self.overwriteWarning == nil else { return }
            self.overwriteWarning = next
        }
    }

    private func scheduleFollowUpIfNeeded(afterSyncing providers: [CloudSyncProvider]) {
        guard pendingChangeDuringSync else { return }
        pendingChangeDuringSync = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let snapshot = await BackupManager.shared.createExperimentalCloudSnapshot() else {
                self.scheduleAutomaticSync(after: 2, reason: "change-during-sync")
                return
            }
            let hasUnsyncedContent = providers.contains { provider in
                guard let previous = Self.lastSyncedFootprint(provider: provider) else { return true }
                return Self.protectedFootprint(snapshot.footprint, provider: provider)
                    .hasDifferentContent(than: previous)
            }
            if hasUnsyncedContent {
                self.scheduleAutomaticSync(after: 2, reason: "change-during-sync")
            }
        }
    }

    private func scheduleAutomaticRetry(for providers: [CloudSyncProvider]) {
        let now = Date()
        let retryDate = providers.map { provider -> Date in
            let defaults = UserDefaults.standard
            let attempt = defaults.double(forKey: provider.lastAutomaticAttemptKey)
            let cooldown = defaults.double(forKey: provider.retryNotBeforeKey)
            return max(
                attempt > 0 ? Date(timeIntervalSince1970: attempt + 300) : now,
                cooldown > 0 ? Date(timeIntervalSince1970: cooldown) : now
            )
        }.min() ?? now.addingTimeInterval(300)
        scheduleAutomaticSync(
            after: max(1, retryDate.timeIntervalSince(now)),
            reason: "automatic-retry"
        )
    }

    private func setStatus(_ message: String, for provider: CloudSyncProvider) {
        providerStatusMessages[provider] = message
    }

    private func recordSuccessfulSync(_ date: Date, for provider: CloudSyncProvider) {
        providerLastSyncDates[provider] = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: provider.lastSuccessfulSyncKey)
    }

    private func unavailableMessage(for provider: CloudSyncProvider) -> String {
        switch provider {
        case .iCloud:
            return ExperimentalCloudSyncAvailability.current.statusMessage
        case .googleDrive, .oneDrive:
            return "Connect \(provider.displayName) first."
        }
    }

    private func authorize(provider: CloudSyncProvider) async throws -> CloudSyncToken {
        let configuration = try Self.oauthConfiguration(for: provider)
        let verifier = try Self.randomPKCEString(length: 64)
        let challenge = Self.codeChallenge(for: verifier)
        let state = try Self.randomPKCEString(length: 40)
        let callbackURL = try await openAuthorizationSession(
            provider: provider,
            configuration: configuration,
            challenge: challenge,
            state: state
        )
        let parameters = Self.callbackParameters(from: callbackURL)

        guard parameters["state"] == state else {
            throw SyncError.authorizationFailed("The \(provider.displayName) sign-in response could not be verified.")
        }
        if let errorDescription = parameters["error_description"] ?? parameters["error"] {
            throw SyncError.authorizationFailed(errorDescription)
        }
        guard let code = parameters["code"], !code.isEmpty else {
            throw SyncError.authorizationFailed("No authorization code was returned by \(provider.displayName).")
        }

        return try await Self.exchangeAuthorizationCode(
            code,
            verifier: verifier,
            configuration: configuration,
            provider: provider
        )
    }

    private func openAuthorizationSession(
        provider: CloudSyncProvider,
        configuration: OAuthConfiguration,
        challenge: String,
        state: String
    ) async throws -> URL {
        let authURL = try Self.authorizationURL(
            provider: provider,
            configuration: configuration,
            challenge: challenge,
            state: state
        )

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: configuration.callbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.authenticationSession = nil
                }

                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: SyncError.authorizationFailed("Sign-in was cancelled."))
                }
            }

            session.presentationContextProvider = authPresentationContextProvider
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session

            if !session.start() {
                authenticationSession = nil
                continuation.resume(throwing: SyncError.authorizationFailed("Could not open \(provider.displayName) sign-in."))
            }
        }
    }

    private static func reconcileSnapshot(provider: CloudSyncProvider, reason: String) async throws -> Date {
        prepareReconciliationIdentity(provider: provider)

        guard let metadata = try await remoteMetadata(provider: provider) else {
            return try await writeLocalSnapshot(
                provider: provider,
                reason: reason,
                writePrecondition: .remoteMissing
            )
        }

        guard let localSnapshot = await BackupManager.shared.createExperimentalCloudSnapshot() else {
            throw SyncError.snapshotEncodingFailed
        }

        let localFootprint = protectedFootprint(localSnapshot.footprint, provider: provider)

        if hasUnseenRemoteSnapshot(metadata: metadata, provider: provider) {
            let remoteSnapshot = try await readRemoteSnapshot(provider: provider, knownMetadata: metadata)
            guard let decodedRemoteFootprint = BackupManager.shared.experimentalCloudSnapshotFootprint(from: remoteSnapshot.data) else {
                throw SyncError.snapshotInspectionFailed
            }
            let remoteFootprint = protectedFootprint(decodedRemoteFootprint, provider: provider)

            switch ExperimentalCloudReconciliationPolicy.actionForUnseenRemote(
                local: localFootprint,
                remote: remoteFootprint,
                previous: lastSyncedFootprint(provider: provider)
            ) {
            case .concurrentConflict:
                throw SyncError.concurrentSnapshotConflict(
                    provider,
                    localFootprint.meaningfulRecordCount,
                    remoteFootprint.meaningfulRecordCount
                )
            case .remoteWouldReduceLocalData:
                // A newer timestamp is not permission to erase fuller device data.
                // Any protected domain that is richer locally requires an explicit
                // choice before applying the remote snapshot.
                throw SyncError.suspiciousRemoteReduction(
                    provider,
                    localFootprint.meaningfulRecordCount,
                    remoteFootprint.meaningfulRecordCount
                )
            case .restoreRemote:
                break
            }

            Logger.shared.log("Experimental cloud snapshot restoring verified newer remote provider=\(provider.rawValue) reason=\(reason)", type: "CloudSync")
            return try await restoreRemoteSnapshot(
                provider: provider,
                knownMetadata: metadata,
                preparedSnapshot: remoteSnapshot
            )
        }


        if !metadata.isLegacy,
           let previousFootprint = lastSyncedFootprint(provider: provider),
           !localFootprint.hasDifferentContent(than: previousFootprint) {
            markRemoteSnapshotSeen(
                provider: provider,
                fallbackDate: metadata.modifiedAt ?? Date(),
                revision: metadata.revision
            )
            Logger.shared.log(
                "Experimental cloud sync skipped unchanged snapshot provider=\(provider.rawValue) reason=\(reason)",
                type: "CloudSync"
            )
            return Date()
        }

        let needsRemoteSafetyCheck: Bool
        if let previousFootprint = lastSyncedFootprint(provider: provider) {
            needsRemoteSafetyCheck = localFootprint.isSuspiciousReduction(from: previousFootprint)
        } else {
            needsRemoteSafetyCheck = true
        }

        if needsRemoteSafetyCheck {
            // This read occurs only once when adopting the safeguard for an
            // existing provider, or after a suspicious local reduction.
            let remoteSnapshot = try await readRemoteSnapshot(provider: provider, knownMetadata: metadata)
            if let remoteFootprint = BackupManager.shared.experimentalCloudSnapshotFootprint(from: remoteSnapshot.data),
               protectedFootprint(remoteFootprint, provider: provider).hasMeaningfullyMoreData(than: localFootprint) {
                let protectedRemoteFootprint = protectedFootprint(remoteFootprint, provider: provider)
                throw SyncError.suspiciousLocalReduction(
                    provider,
                    localFootprint.meaningfulRecordCount,
                    protectedRemoteFootprint.meaningfulRecordCount
                )
            }
        }

        return try await writeLocalSnapshot(
            provider: provider,
            reason: reason,
            snapshot: localSnapshot,
            writePrecondition: metadata.isLegacy ? .remoteMissing : .remoteMatches(metadata)
        )
    }

    private static func writeLocalSnapshot(
        provider: CloudSyncProvider,
        reason: String,
        snapshot preparedSnapshot: ExperimentalCloudSnapshot? = nil,
        writePrecondition: RemoteWritePrecondition = .unconditional
    ) async throws -> Date {
        let snapshot: ExperimentalCloudSnapshot?
        if let preparedSnapshot {
            snapshot = preparedSnapshot
        } else {
            snapshot = await BackupManager.shared.createExperimentalCloudSnapshot()
        }
        guard let snapshot else {
            throw SyncError.snapshotEncodingFailed
        }
        let data = snapshot.data
        guard data.count <= maximumCloudSnapshotBytes else {
            throw BoundedURLSessionError.responseTooLarge(
                maximumBytes: maximumCloudSnapshotBytes
            )
        }

        let metadata: RemoteSnapshotMetadata
        switch provider {
        case .iCloud:
            metadata = try await writeICloudSnapshot(data: data, precondition: writePrecondition)
        case .googleDrive:
            metadata = try await writeGoogleDriveSnapshot(data: data, precondition: writePrecondition)
        case .oneDrive:
            metadata = try await writeOneDriveSnapshot(data: data, precondition: writePrecondition)
        }

        markRemoteSnapshotSeen(
            provider: provider,
            fallbackDate: metadata.modifiedAt ?? Date(),
            revision: metadata.revision
        )
        saveLastSyncedFootprint(protectedFootprint(snapshot.footprint, provider: provider), provider: provider)
        Logger.shared.log("Experimental cloud snapshot pushed provider=\(provider.rawValue) reason=\(reason) bytes=\(data.count)", type: "CloudSync")
        return Date()
    }

    private static func restoreRemoteSnapshotSafely(provider: CloudSyncProvider) async throws -> Date {
        prepareReconciliationIdentity(provider: provider)
        guard let metadata = try await remoteMetadata(provider: provider) else {
            throw SyncError.noSnapshot(provider)
        }
        guard let localSnapshot = await BackupManager.shared.createExperimentalCloudSnapshot() else {
            throw SyncError.snapshotEncodingFailed
        }

        let remoteSnapshot = try await readRemoteSnapshot(provider: provider, knownMetadata: metadata)
        guard let decodedRemoteFootprint = BackupManager.shared.experimentalCloudSnapshotFootprint(from: remoteSnapshot.data) else {
            throw SyncError.snapshotInspectionFailed
        }

        let localFootprint = protectedFootprint(localSnapshot.footprint, provider: provider)
        let remoteFootprint = protectedFootprint(decodedRemoteFootprint, provider: provider)
        if localFootprint.hasAnyMoreData(than: remoteFootprint) {
            throw SyncError.suspiciousRemoteReduction(
                provider,
                localFootprint.meaningfulRecordCount,
                remoteFootprint.meaningfulRecordCount
            )
        }
        if localFootprint.meaningfulRecordCount > 0,
           localFootprint.hasDifferentContent(than: remoteFootprint) {
            throw SyncError.concurrentSnapshotConflict(
                provider,
                localFootprint.meaningfulRecordCount,
                remoteFootprint.meaningfulRecordCount
            )
        }

        return try await restoreRemoteSnapshot(
            provider: provider,
            knownMetadata: metadata,
            preparedSnapshot: remoteSnapshot
        )
    }

    private static func restoreRemoteSnapshot(
        provider: CloudSyncProvider,
        knownMetadata: RemoteSnapshotMetadata? = nil,
        preparedSnapshot: RemoteSnapshot? = nil
    ) async throws -> Date {
        let data: Data
        let modifiedAt: Date?

        let snapshot: RemoteSnapshot
        if let preparedSnapshot {
            snapshot = preparedSnapshot
        } else {
            snapshot = try await readRemoteSnapshot(provider: provider, knownMetadata: knownMetadata)
        }
        data = snapshot.data
        modifiedAt = snapshot.modifiedAt

        // Keep an in-memory rollback snapshot in case applying a validly
        // decoded remote backup fails partway through a restore.
        let rollbackSnapshot = await BackupManager.shared.createExperimentalCloudSnapshot()
        guard await BackupManager.shared.prepareExperimentalCloudRestoreRecovery(using: rollbackSnapshot) else {
            throw SyncError.restoreRecoveryPreparationFailed
        }

        let didRestore: Bool
        if provider == .iCloud, #available(iOS 17.0, *) {
            didRestore = await MediaStateSyncManager.shared.performLegacySnapshotRestorePreservingMediaState {
                await BackupManager.shared.restoreExperimentalCloudSnapshot(
                    from: data,
                    preserveMediaStateForCloudKit: provider == .iCloud
                )
            }
        } else {
            didRestore = await BackupManager.shared.restoreExperimentalCloudSnapshot(
                from: data,
                preserveMediaStateForCloudKit: provider == .iCloud
            )
        }
        guard didRestore else {
            if let rollbackSnapshot {
                let rolledBack = await BackupManager.shared.restoreExperimentalCloudSnapshot(
                    from: rollbackSnapshot.data,
                    preserveMediaStateForCloudKit: provider == .iCloud
                )
                if rolledBack {
                    BackupManager.shared.completeExperimentalCloudRestoreRecovery()
                    Logger.shared.log("Experimental cloud restore rolled local state back after an apply failure", type: "CloudSync")
                }
            }
            throw SyncError.snapshotRestoreFailed
        }
        BackupManager.shared.completeExperimentalCloudRestoreRecovery()

        markRemoteSnapshotSeen(
            provider: provider,
            fallbackDate: modifiedAt ?? Date(),
            revision: snapshot.revision
        )
        if let localSnapshot = await BackupManager.shared.createExperimentalCloudSnapshot() {
            saveLastSyncedFootprint(
                protectedFootprint(localSnapshot.footprint, provider: provider),
                provider: provider
            )
        } else if let footprint = BackupManager.shared.experimentalCloudSnapshotFootprint(from: data) {
            saveLastSyncedFootprint(protectedFootprint(footprint, provider: provider), provider: provider)
        }
        Logger.shared.log("Experimental cloud snapshot restored provider=\(provider.rawValue) bytes=\(data.count)", type: "CloudSync")
        return Date()
    }

    private static func readRemoteSnapshot(
        provider: CloudSyncProvider,
        knownMetadata: RemoteSnapshotMetadata? = nil
    ) async throws -> RemoteSnapshot {
        switch provider {
        case .iCloud:
            return try await readICloudSnapshot(fileName: knownMetadata?.id ?? snapshotFileName)
        case .googleDrive:
            return try await readGoogleDriveSnapshot(knownMetadata: knownMetadata)
        case .oneDrive:
            return try await readOneDriveSnapshot(knownMetadata: knownMetadata)
        }
    }

    private static func remoteMetadata(provider: CloudSyncProvider) async throws -> RemoteSnapshotMetadata? {
        switch provider {
        case .iCloud:
            return try await iCloudMetadata()
        case .googleDrive:
            return try await googleDriveMetadata()
        case .oneDrive:
            return try await oneDriveMetadata()
        }
    }

    private nonisolated static func iCloudSnapshotURL(fileName: String) throws -> URL {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            throw SyncError.unavailable(.iCloud)
        }

        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents.appendingPathComponent(fileName)
    }

    private nonisolated static func iCloudMetadata() async throws -> RemoteSnapshotMetadata? {
        try await Task.detached(priority: .utility) {
            let currentURL = try iCloudSnapshotURL(fileName: eclipseCloudSnapshotFileName)
            let legacyURL = try iCloudSnapshotURL(fileName: eclipseLegacyCloudSnapshotFileName)
            let url: URL
            let isLegacy: Bool
            if FileManager.default.fileExists(atPath: currentURL.path) {
                url = currentURL
                isLegacy = false
            } else if FileManager.default.fileExists(atPath: legacyURL.path) {
                url = legacyURL
                isLegacy = true
            } else {
                return nil
            }
            return try coordinatedICloudRead(at: url) { coordinatedURL in
                try throwIfICloudVersionsConflict(at: coordinatedURL)
                return RemoteSnapshotMetadata(
                    id: isLegacy ? eclipseLegacyCloudSnapshotFileName : eclipseCloudSnapshotFileName,
                    modifiedAt: remoteModificationDate(at: coordinatedURL),
                    revision: iCloudRevision(at: coordinatedURL),
                    isLegacy: isLegacy
                )
            }
        }.value
    }

    private nonisolated static func writeICloudSnapshot(
        data: Data,
        precondition: RemoteWritePrecondition
    ) async throws -> RemoteSnapshotMetadata {
        try await Task.detached(priority: .utility) {
            let url = try iCloudSnapshotURL(fileName: eclipseCloudSnapshotFileName)
            return try coordinatedICloudWrite(at: url) { coordinatedURL in
                try throwIfICloudVersionsConflict(at: coordinatedURL)
                let currentMetadata: RemoteSnapshotMetadata? = FileManager.default.fileExists(atPath: coordinatedURL.path)
                    ? RemoteSnapshotMetadata(
                        id: nil,
                        modifiedAt: remoteModificationDate(at: coordinatedURL),
                        revision: iCloudRevision(at: coordinatedURL)
                    )
                    : nil
                guard remoteWritePrecondition(precondition, accepts: currentMetadata) else {
                    throw SyncError.remoteChangedDuringSync(.iCloud)
                }
                try data.write(to: coordinatedURL, options: .atomic)
                return RemoteSnapshotMetadata(
                    id: nil,
                    modifiedAt: remoteModificationDate(at: coordinatedURL),
                    revision: iCloudRevision(at: coordinatedURL)
                )
            }
        }.value
    }

    private nonisolated static func readICloudSnapshot(fileName: String) async throws -> RemoteSnapshot {
        try await Task.detached(priority: .utility) {
            let url = try iCloudSnapshotURL(fileName: fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SyncError.noSnapshot(.iCloud)
            }
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            try await waitForCurrentICloudSnapshot(at: url)
            return try coordinatedICloudRead(at: url) { coordinatedURL in
                try throwIfICloudVersionsConflict(at: coordinatedURL)
                let handle = try FileHandle(forReadingFrom: coordinatedURL)
                defer { try? handle.close() }
                var data = Data()
                while data.count <= maximumCloudSnapshotBytes {
                    let remaining = maximumCloudSnapshotBytes + 1 - data.count
                    guard remaining > 0 else { break }
                    let chunk = try handle.read(upToCount: min(1_048_576, remaining)) ?? Data()
                    guard !chunk.isEmpty else { break }
                    data.append(chunk)
                }
                guard data.count <= maximumCloudSnapshotBytes else {
                    throw BoundedURLSessionError.responseTooLarge(maximumBytes: maximumCloudSnapshotBytes)
                }
                return RemoteSnapshot(
                    data: data,
                    modifiedAt: remoteModificationDate(at: coordinatedURL),
                    revision: iCloudRevision(at: coordinatedURL)
                )
            }
        }.value
    }

    /// `startDownloadingUbiquitousItem` only requests a download. Reading the
    /// coordinated URL before Foundation reports `.current` can return a stale
    /// local generation or fail for an offloaded placeholder.
    private nonisolated static func waitForCurrentICloudSnapshot(
        at url: URL,
        timeout: TimeInterval = 45
    ) async throws {
        let fileManager = FileManager.default
        guard fileManager.isUbiquitousItem(at: url) else { return }

        let deadline = Date().addingTimeInterval(timeout)
        let keys: Set<URLResourceKey> = [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemDownloadingErrorKey
        ]

        while Date() < deadline {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            if values.ubiquitousItemDownloadingStatus == .current {
                return
            }
            if values.ubiquitousItemDownloadingError != nil {
                throw SyncError.iCloudDownloadFailed
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw SyncError.iCloudDownloadTimedOut
    }

    private nonisolated static func coordinatedICloudRead<T>(at url: URL, body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try body(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SyncError.invalidResponse(.iCloud) }
        return try result.get()
    }

    private nonisolated static func coordinatedICloudWrite<T>(at url: URL, body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let options: NSFileCoordinator.WritingOptions = FileManager.default.fileExists(atPath: url.path)
            ? .forReplacing
            : []
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinatedURL in
            result = Result { try body(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SyncError.invalidResponse(.iCloud) }
        return try result.get()
    }

    private nonisolated static func throwIfICloudVersionsConflict(at url: URL) throws {
        if let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty {
            throw SyncError.remoteChangedDuringSync(.iCloud)
        }
    }

    private nonisolated static func iCloudRevision(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        let timestamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(timestamp):\(values.fileSize ?? -1)"
    }

    private nonisolated static func remoteModificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private static func googleDriveMetadata() async throws -> RemoteSnapshotMetadata? {
        if let current = try await googleDriveMetadata(fileName: snapshotFileName, isLegacy: false) {
            return current
        }
        return try await googleDriveMetadata(fileName: legacySnapshotFileName, isLegacy: true)
    }

    private static func googleDriveMetadata(
        fileName: String,
        isLegacy: Bool
    ) async throws -> RemoteSnapshotMetadata? {
        let accessToken = try await accessToken(for: .googleDrive)
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "pageSize", value: "6"),
            URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
            URLQueryItem(name: "fields", value: "files(id,modifiedTime,md5Checksum)"),
            URLQueryItem(name: "q", value: "name = '\(fileName)' and 'appDataFolder' in parents and trashed = false")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data = try await validatedData(for: request, provider: .googleDrive)
        let response = try JSONDecoder().decode(GoogleDriveListResponse.self, from: data)
        guard let file = response.files.first else { return nil }
        return RemoteSnapshotMetadata(
            id: file.id,
            modifiedAt: parseRemoteDate(file.modifiedTime),
            revision: file.md5Checksum,
            historicalIDs: isLegacy ? [] : response.files.map(\.id),
            isLegacy: isLegacy
        )
    }

    private static func writeGoogleDriveSnapshot(
        data: Data,
        precondition: RemoteWritePrecondition
    ) async throws -> RemoteSnapshotMetadata {
        let accessToken = try await accessToken(for: .googleDrive)
        let existing: RemoteSnapshotMetadata?
        switch precondition {
        case .remoteMatches(let metadata): existing = metadata
        case .remoteMissing: existing = nil
        case .unconditional: existing = try await googleDriveMetadata()
        }

        let boundary = "EclipseCloudSync-\(UUID().uuidString)"
        let metadata: [String: Any] = [
            "name": snapshotFileName,
            "parents": ["appDataFolder"]
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        let body = multipartBody(metadata: metadataData, fileData: data, boundary: boundary)

        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id,modifiedTime,md5Checksum")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let responseData = try await validatedData(for: request, provider: .googleDrive)
        let file = try JSONDecoder().decode(GoogleDriveFile.self, from: responseData)
        // Drive v3 does not expose a documented atomic content-update
        // precondition. Keep each upload immutable and prune only snapshots
        // outside the recovery window, so concurrent clients cannot destroy
        // the previously valid backup.
        if let existing, existing.historicalIDs.count >= 6 {
            for obsoleteID in existing.historicalIDs.dropFirst(4) {
                var deleteRequest = URLRequest(
                    url: URL(string: "https://www.googleapis.com/drive/v3/files/\(obsoleteID)")!
                )
                deleteRequest.httpMethod = "DELETE"
                deleteRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                _ = try? await validatedData(for: deleteRequest, provider: .googleDrive)
            }
        }
        return RemoteSnapshotMetadata(
            id: file.id,
            modifiedAt: parseRemoteDate(file.modifiedTime),
            revision: file.md5Checksum,
            historicalIDs: [file.id] + (existing?.historicalIDs ?? [])
        )
    }

    private static func readGoogleDriveSnapshot(
        knownMetadata: RemoteSnapshotMetadata? = nil
    ) async throws -> RemoteSnapshot {
        let accessToken = try await accessToken(for: .googleDrive)
        let metadata: RemoteSnapshotMetadata
        if let knownMetadata {
            metadata = knownMetadata
        } else if let fetchedMetadata = try await googleDriveMetadata() {
            metadata = fetchedMetadata
        } else {
            throw SyncError.noSnapshot(.googleDrive)
        }
        guard let fileID = metadata.id,
              !fileID.isEmpty else {
            throw SyncError.noSnapshot(.googleDrive)
        }

        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        return RemoteSnapshot(
            data: try await validatedData(
                for: request,
                provider: .googleDrive,
                maximumResponseBytes: maximumCloudSnapshotBytes
            ),
            modifiedAt: metadata.modifiedAt,
            revision: metadata.revision
        )
    }

    private static func oneDriveMetadata() async throws -> RemoteSnapshotMetadata? {
        if let current = try await oneDriveMetadata(fileName: snapshotFileName, isLegacy: false) {
            return current
        }
        return try await oneDriveMetadata(fileName: legacySnapshotFileName, isLegacy: true)
    }

    private static func oneDriveMetadata(
        fileName: String,
        isLegacy: Bool
    ) async throws -> RemoteSnapshotMetadata? {
        let accessToken = try await accessToken(for: .oneDrive)
        var request = URLRequest(url: oneDriveSnapshotMetadataURL(fileName: fileName))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let data = try await validatedData(
            for: request,
            provider: .oneDrive,
            allowNotFound: true,
            maximumResponseBytes: maximumCloudControlResponseBytes
        ) else {
            return nil
        }

        let item = try JSONDecoder().decode(OneDriveItem.self, from: data)
        return RemoteSnapshotMetadata(
            id: item.id,
            modifiedAt: parseRemoteDate(item.lastModifiedDateTime),
            revision: item.eTag,
            isLegacy: isLegacy
        )
    }

    private static func writeOneDriveSnapshot(
        data: Data,
        precondition: RemoteWritePrecondition
    ) async throws -> RemoteSnapshotMetadata {
        let accessToken = try await accessToken(for: .oneDrive)
        var request = URLRequest(url: oneDriveSnapshotContentURL())
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch precondition {
        case .remoteMissing:
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .remoteMatches(let metadata):
            if let revision = metadata.revision {
                request.setValue(revision, forHTTPHeaderField: "If-Match")
            }
        case .unconditional:
            break
        }
        request.httpBody = data

        let responseData: Data
        do {
            responseData = try await validatedData(for: request, provider: .oneDrive)
        } catch SyncError.remoteRequestFailed(_, 412, _) {
            throw SyncError.remoteChangedDuringSync(.oneDrive)
        }
        let item = try JSONDecoder().decode(OneDriveItem.self, from: responseData)
        return RemoteSnapshotMetadata(id: item.id, modifiedAt: parseRemoteDate(item.lastModifiedDateTime), revision: item.eTag)
    }

    private static func readOneDriveSnapshot(
        knownMetadata: RemoteSnapshotMetadata? = nil
    ) async throws -> RemoteSnapshot {
        let accessToken = try await accessToken(for: .oneDrive)
        let metadata: RemoteSnapshotMetadata
        if let knownMetadata {
            metadata = knownMetadata
        } else if let fetchedMetadata = try await oneDriveMetadata() {
            metadata = fetchedMetadata
        } else {
            throw SyncError.noSnapshot(.oneDrive)
        }

        let contentURL: URL
        if let itemID = metadata.id, !itemID.isEmpty {
            contentURL = URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(itemID)/content")!
        } else {
            contentURL = oneDriveSnapshotContentURL()
        }
        var request = URLRequest(url: contentURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        return RemoteSnapshot(
            data: try await validatedData(
                for: request,
                provider: .oneDrive,
                maximumResponseBytes: maximumCloudSnapshotBytes
            ),
            modifiedAt: metadata.modifiedAt,
            revision: metadata.revision
        )
    }

    private static func oneDriveSnapshotMetadataURL(fileName: String) -> URL {
        URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(fileName)")!
    }

    private static func oneDriveSnapshotContentURL() -> URL {
        URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(snapshotFileName):/content")!
    }

    private static func hasUnseenRemoteSnapshot(metadata: RemoteSnapshotMetadata, provider: CloudSyncProvider) -> Bool {
        if let revision = metadata.revision {
            let lastRevision = UserDefaults.standard.string(forKey: provider.lastSeenRemoteRevisionKey)
            if lastRevision != revision { return true }
        }
        guard let modificationDate = metadata.modifiedAt else { return false }
        let lastSeen = UserDefaults.standard.double(forKey: provider.lastSeenRemoteModificationKey)
        guard lastSeen > 0 else { return true }
        return modificationDate.timeIntervalSince1970 > lastSeen + 0.001
    }

    private nonisolated static func remoteWritePrecondition(
        _ precondition: RemoteWritePrecondition,
        accepts actualMetadata: RemoteSnapshotMetadata?
    ) -> Bool {
        switch precondition {
        case .unconditional:
            return true
        case .remoteMissing:
            return actualMetadata == nil
        case .remoteMatches(let expected):
            guard let actualMetadata else { return false }
            if let expectedRevision = expected.revision,
               let actualRevision = actualMetadata.revision {
                return expectedRevision == actualRevision
            }
            guard let expectedDate = expected.modifiedAt,
                  let actualDate = actualMetadata.modifiedAt else {
                return expected.id == actualMetadata.id
            }
            return abs(expectedDate.timeIntervalSince(actualDate)) < 0.001
        }
    }

    private static func markRemoteSnapshotSeen(
        provider: CloudSyncProvider,
        fallbackDate: Date,
        revision: String?
    ) {
        UserDefaults.standard.set(fallbackDate.timeIntervalSince1970, forKey: provider.lastSeenRemoteModificationKey)
        if let revision {
            UserDefaults.standard.set(revision, forKey: provider.lastSeenRemoteRevisionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: provider.lastSeenRemoteRevisionKey)
        }
    }

    private static func lastSyncedFootprint(provider: CloudSyncProvider) -> ExperimentalCloudSnapshotFootprint? {
        guard let data = UserDefaults.standard.data(forKey: provider.lastSyncedFootprintKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ExperimentalCloudSnapshotFootprint.self, from: data)
    }

    private static func saveLastSyncedFootprint(
        _ footprint: ExperimentalCloudSnapshotFootprint,
        provider: CloudSyncProvider
    ) {
        guard let data = try? JSONEncoder().encode(footprint) else { return }
        UserDefaults.standard.set(data, forKey: provider.lastSyncedFootprintKey)
    }

    private static func protectedFootprint(
        _ footprint: ExperimentalCloudSnapshotFootprint,
        provider: CloudSyncProvider
    ) -> ExperimentalCloudSnapshotFootprint {
        // On iOS 17+, CloudKit owns these media-state domains. The legacy
        // iCloud Documents restore deliberately preserves their local values.
        provider == .iCloud ? footprint.excludingCloudKitMediaState() : footprint
    }

    private static func prepareReconciliationIdentity(provider: CloudSyncProvider) {
        guard provider == .iCloud,
              let token = FileManager.default.ubiquityIdentityToken,
              let currentIdentity = try? NSKeyedArchiver.archivedData(
                withRootObject: token,
                requiringSecureCoding: false
              ) else {
            return
        }

        let defaults = UserDefaults.standard
        if let previousIdentity = defaults.data(forKey: provider.accountIdentityKey),
           !ubiquityIdentity(previousIdentity, matches: token) {
            defaults.removeObject(forKey: provider.lastSeenRemoteModificationKey)
            defaults.removeObject(forKey: provider.lastSyncedFootprintKey)
            defaults.removeObject(forKey: provider.lastSeenRemoteRevisionKey)
            Logger.shared.log("Experimental cloud sync detected an iCloud account change; reconciliation markers cleared", type: "CloudSync")
        }
        defaults.set(currentIdentity, forKey: provider.accountIdentityKey)
    }

    private static func ubiquityIdentity(_ archivedData: Data, matches currentToken: Any) -> Bool {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archivedData) else {
            return false
        }
        unarchiver.requiresSecureCoding = false
        let previousToken = unarchiver.decodeObject(
            forKey: NSKeyedArchiveRootObjectKey
        ) as? NSObjectProtocol
        unarchiver.finishDecoding()
        return previousToken?.isEqual(currentToken) == true
    }

    private static func accessToken(for provider: CloudSyncProvider) async throws -> String {
        guard provider.requiresAccountConnection else {
            throw SyncError.unavailable(provider)
        }
        guard var token = CloudSyncTokenStore.token(for: provider) else {
            throw SyncError.authenticationRequired(provider)
        }

        if token.expiresAt.timeIntervalSinceNow > 90 {
            return token.accessToken
        }

        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw SyncError.authenticationRequired(provider)
        }

        let configuration = try oauthConfiguration(for: provider)
        let refreshed = try await refreshAccessToken(refreshToken, currentToken: token, configuration: configuration, provider: provider)
        token = refreshed
        try CloudSyncTokenStore.save(token, for: provider)
        return token.accessToken
    }

    private static func forceRefreshAccessToken(for provider: CloudSyncProvider) async throws -> String {
        guard provider.requiresAccountConnection,
              let token = CloudSyncTokenStore.token(for: provider),
              let refreshToken = token.refreshToken,
              !refreshToken.isEmpty else {
            throw SyncError.authenticationRequired(provider)
        }
        let configuration = try oauthConfiguration(for: provider)
        let refreshed = try await refreshAccessToken(
            refreshToken,
            currentToken: token,
            configuration: configuration,
            provider: provider
        )
        try CloudSyncTokenStore.save(refreshed, for: provider)
        return refreshed.accessToken
    }

    private static func oauthConfiguration(for provider: CloudSyncProvider) throws -> OAuthConfiguration {
        switch provider {
        case .iCloud:
            throw SyncError.unavailable(provider)
        case .googleDrive:
            return OAuthConfiguration(
                authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
                clientID: googleClientID,
                redirectURI: "\(googleURLScheme):/oauth2redirect",
                callbackScheme: googleURLScheme,
                scopes: ["https://www.googleapis.com/auth/drive.appdata"],
                additionalAuthorizationParameters: [
                    "access_type": "offline",
                    "prompt": "consent"
                ]
            )
        case .oneDrive:
            return OAuthConfiguration(
                authorizationURL: URL(string: "https://login.microsoftonline.com/\(microsoftTenant)/oauth2/v2.0/authorize")!,
                tokenURL: URL(string: "https://login.microsoftonline.com/\(microsoftTenant)/oauth2/v2.0/token")!,
                clientID: microsoftClientID,
                redirectURI: microsoftRedirectURI,
                callbackScheme: "msauth.app.Eclipse.Soupy",
                scopes: ["offline_access", "Files.ReadWrite.AppFolder"],
                additionalAuthorizationParameters: [:]
            )
        }
    }

    private static func authorizationURL(
        provider: CloudSyncProvider,
        configuration: OAuthConfiguration,
        challenge: String,
        state: String
    ) throws -> URL {
        var components = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        if provider == .oneDrive {
            queryItems.append(URLQueryItem(name: "response_mode", value: "query"))
        }

        queryItems.append(contentsOf: configuration.additionalAuthorizationParameters.map {
            URLQueryItem(name: $0.key, value: $0.value)
        })

        components.queryItems = queryItems
        guard let url = components.url else {
            throw SyncError.authorizationFailed("Could not prepare \(provider.displayName) sign-in.")
        }
        return url
    }

    private static func exchangeAuthorizationCode(
        _ code: String,
        verifier: String,
        configuration: OAuthConfiguration,
        provider: CloudSyncProvider
    ) async throws -> CloudSyncToken {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": configuration.redirectURI,
            "scope": configuration.scopes.joined(separator: " ")
        ])

        let data = try await validatedData(for: request, provider: provider)
        let response = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw SyncError.authorizationFailed("\(provider.displayName) did not return a refresh token.")
        }
        return CloudSyncToken(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn ?? 3600)
        )
    }

    private static func refreshAccessToken(
        _ refreshToken: String,
        currentToken: CloudSyncToken,
        configuration: OAuthConfiguration,
        provider: CloudSyncProvider
    ) async throws -> CloudSyncToken {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "scope": configuration.scopes.joined(separator: " ")
        ])

        let data = try await validatedData(for: request, provider: provider)
        let response = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        return CloudSyncToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? currentToken.refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn ?? 3600)
        )
    }

    private static func validatedData(
        for request: URLRequest,
        provider: CloudSyncProvider,
        allowNotFound: Bool,
        maximumResponseBytes: Int
    ) async throws -> Data? {
        var currentRequest = request
        var refreshedAuthorization = false
        let maximumAttempts = 4

        for attempt in 0..<maximumAttempts {
            do {
                let (data, response) = try await URLSession.custom.boundedData(
                    for: currentRequest,
                    maximumResponseBytes: maximumResponseBytes
                )
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SyncError.invalidResponse(provider)
                }

                if allowNotFound, httpResponse.statusCode == 404 {
                    clearProviderCooldown(provider)
                    return nil
                }
                if (200..<300).contains(httpResponse.statusCode) {
                    clearProviderCooldown(provider)
                    return data
                }

                if httpResponse.statusCode == 401,
                   !refreshedAuthorization,
                   currentRequest.value(forHTTPHeaderField: "Authorization") != nil,
                   provider.requiresAccountConnection {
                    let accessToken = try await forceRefreshAccessToken(for: provider)
                    currentRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                    refreshedAuthorization = true
                    continue
                }

                let previewData = data.prefix(maximumCloudErrorPreviewBytes)
                let body = String(data: previewData, encoding: .utf8)
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                let googleQuotaFailure = provider == .googleDrive &&
                    httpResponse.statusCode == 403 &&
                    (body.localizedCaseInsensitiveContains("rateLimit") ||
                     body.localizedCaseInsensitiveContains("rate_limit"))
                let retryable = httpResponse.statusCode == 429 ||
                    httpResponse.statusCode == 503 ||
                    (500...599).contains(httpResponse.statusCode) ||
                    googleQuotaFailure

                if retryable, attempt + 1 < maximumAttempts {
                    let delay = retryDelay(
                        response: httpResponse,
                        attempt: attempt,
                        provider: provider
                    )
                    persistProviderCooldown(provider, delay: delay)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                if retryable {
                    let delay = retryDelay(response: httpResponse, attempt: attempt, provider: provider)
                    persistProviderCooldown(provider, delay: delay)
                }
                throw SyncError.remoteRequestFailed(provider, httpResponse.statusCode, body)
            } catch let error as SyncError {
                throw error
            } catch {
                if attempt + 1 < maximumAttempts,
                   !(error is CancellationError),
                   !(error is BoundedURLSessionError) {
                    let delay = retryDelay(response: nil, attempt: attempt, provider: provider)
                    persistProviderCooldown(provider, delay: delay)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                if !(error is CancellationError), !(error is BoundedURLSessionError) {
                    persistProviderCooldown(provider, delay: 60)
                }
                throw error
            }
        }
        throw SyncError.invalidResponse(provider)
    }

    private static func retryDelay(
        response: HTTPURLResponse?,
        attempt: Int,
        provider: CloudSyncProvider
    ) -> TimeInterval {
        if let value = response?.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return min(max(seconds, 1), 300)
            }
            if let date = parseHTTPDate(value) {
                return min(max(date.timeIntervalSinceNow, 1), 300)
            }
        }
        let base = min(pow(2, Double(attempt)), 64)
        return base + Double.random(in: 0...1)
    }

    private static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }

    private static func persistProviderCooldown(_ provider: CloudSyncProvider, delay: TimeInterval) {
        UserDefaults.standard.set(
            Date().addingTimeInterval(delay).timeIntervalSince1970,
            forKey: provider.retryNotBeforeKey
        )
    }

    private static func clearProviderCooldown(_ provider: CloudSyncProvider) {
        UserDefaults.standard.removeObject(forKey: provider.retryNotBeforeKey)
    }

    private static func validatedData(
        for request: URLRequest,
        provider: CloudSyncProvider
    ) async throws -> Data {
        try await validatedData(
            for: request,
            provider: provider,
            maximumResponseBytes: maximumCloudControlResponseBytes
        )
    }

    private static func validatedData(
        for request: URLRequest,
        provider: CloudSyncProvider,
        maximumResponseBytes: Int
    ) async throws -> Data {
        guard let data = try await validatedData(
            for: request,
            provider: provider,
            allowNotFound: false,
            maximumResponseBytes: maximumResponseBytes
        ) else {
            throw SyncError.invalidResponse(provider)
        }
        return data
    }

    private static func formBody(_ values: [String: String]) -> Data {
        values
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func callbackParameters(from url: URL) -> [String: String] {
        var values: [String: String] = [:]
        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            queryItems.forEach { values[$0.name] = $0.value }
        }
        if let fragment = url.fragment,
           let queryItems = URLComponents(string: "?\(fragment)")?.queryItems {
            queryItems.forEach { values[$0.name] = $0.value }
        }
        return values
    }

    private static func randomPKCEString(length: Int) throws -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SyncError.authorizationFailed("Could not prepare sign-in security data.")
        }
        return String(bytes.map { characters[Int($0) % characters.count] })
    }

    private static func codeChallenge(for verifier: String) -> String {
#if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncoded(Data(digest))
#else
        return verifier
#endif
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func multipartBody(metadata: Data, fileData: Data, boundary: String) -> Data {
        var body = Data()
        append("--\(boundary)\r\n", to: &body)
        append("Content-Type: application/json; charset=UTF-8\r\n\r\n", to: &body)
        body.append(metadata)
        append("\r\n--\(boundary)\r\n", to: &body)
        append("Content-Type: application/json\r\n\r\n", to: &body)
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n", to: &body)
        return body
    }

    private static func append(_ string: String, to data: inout Data) {
        data.append(string.data(using: .utf8) ?? Data())
    }

    private static func parseRemoteDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func relativeSyncTime(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private struct OAuthConfiguration {
        let authorizationURL: URL
        let tokenURL: URL
        let clientID: String
        let redirectURI: String
        let callbackScheme: String
        let scopes: [String]
        let additionalAuthorizationParameters: [String: String]
    }

    private struct OAuthTokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    fileprivate struct CloudSyncToken: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
    }

    private struct RemoteSnapshotMetadata: Sendable {
        let id: String?
        let modifiedAt: Date?
        let revision: String?
        var historicalIDs: [String] = []
        var isLegacy: Bool = false
    }

    private struct RemoteSnapshot: Sendable {
        let data: Data
        let modifiedAt: Date?
        let revision: String?
    }

    private enum RemoteWritePrecondition: Sendable {
        case unconditional
        case remoteMissing
        case remoteMatches(RemoteSnapshotMetadata)
    }

    struct CloudSyncOverwriteWarning: Identifiable {
        enum Direction {
            case cloudIsFuller
            case deviceIsFuller
            case bothChanged
        }

        let provider: CloudSyncProvider
        let localRecordCount: Int
        let remoteRecordCount: Int
        let direction: Direction

        var id: CloudSyncProvider { provider }

        var alertMessage: String {
            switch direction {
            case .cloudIsFuller:
                return "This device has about \(localRecordCount) saved items, while \(provider.displayName) has about \(remoteRecordCount). Eclipse paused before overwriting the fuller cloud backup."
            case .deviceIsFuller:
                return "This device has about \(localRecordCount) saved items, while the newer \(provider.displayName) backup has about \(remoteRecordCount). Eclipse paused before replacing the fuller device data."
            case .bothChanged:
                return "Both this device and the newer \(provider.displayName) backup changed since the last sync. Eclipse paused without replacing either copy. Choose which version to keep."
            }
        }
    }

    private struct GoogleDriveListResponse: Decodable {
        let files: [GoogleDriveFile]
    }

    private struct GoogleDriveFile: Decodable {
        let id: String
        let modifiedTime: String?
        let md5Checksum: String?
    }

    private struct OneDriveItem: Decodable {
        let id: String?
        let lastModifiedDateTime: String?
        let eTag: String?
    }

    private enum SyncError: LocalizedError, Sendable {
        case unavailable(CloudSyncProvider)
        case authenticationRequired(CloudSyncProvider)
        case noSnapshot(CloudSyncProvider)
        case snapshotEncodingFailed
        case snapshotInspectionFailed
        case snapshotRestoreFailed
        case restoreRecoveryPreparationFailed
        case iCloudDownloadFailed
        case iCloudDownloadTimedOut
        case suspiciousLocalReduction(CloudSyncProvider, Int, Int)
        case suspiciousRemoteReduction(CloudSyncProvider, Int, Int)
        case concurrentSnapshotConflict(CloudSyncProvider, Int, Int)
        case remoteChangedDuringSync(CloudSyncProvider)
        case authorizationFailed(String)
        case invalidResponse(CloudSyncProvider)
        case remoteRequestFailed(CloudSyncProvider, Int, String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let provider):
                return "\(provider.displayName) is unavailable for this build or account."
            case .authenticationRequired(let provider):
                return "Connect \(provider.displayName) first."
            case .noSnapshot(let provider):
                return "No \(provider.displayName) snapshot was found."
            case .snapshotEncodingFailed:
                return "Could not prepare a safe cloud snapshot."
            case .snapshotInspectionFailed:
                return "The cloud snapshot could not be safely inspected, so Eclipse left both copies unchanged."
            case .snapshotRestoreFailed:
                return "Could not restore the cloud snapshot."
            case .restoreRecoveryPreparationFailed:
                return "Could not create a local recovery point, so Eclipse did not start the cloud restore."
            case .iCloudDownloadFailed:
                return "iCloud could not download the latest Eclipse snapshot. Check iCloud Drive and try again."
            case .iCloudDownloadTimedOut:
                return "iCloud is still downloading the latest Eclipse snapshot. Eclipse left local data unchanged; try again shortly."
            case .suspiciousLocalReduction(let provider, _, _):
                return "\(provider.displayName) sync paused because this device has substantially less data than the cloud backup."
            case .suspiciousRemoteReduction(let provider, _, _):
                return "\(provider.displayName) restore paused because the cloud snapshot has less data than this device."
            case .concurrentSnapshotConflict(let provider, _, _):
                return "\(provider.displayName) sync paused because both copies changed since the last sync."
            case .remoteChangedDuringSync(let provider):
                return "\(provider.displayName) changed during this sync, so Eclipse left it untouched and will retry safely."
            case .authorizationFailed(let message):
                return message
            case .invalidResponse(let provider):
                return "\(provider.displayName) returned an invalid response."
            case .remoteRequestFailed(let provider, let statusCode, let message):
                return ExperimentalCloudSyncErrorPolicy.message(
                    provider: provider,
                    statusCode: statusCode,
                    body: message
                )
            }
        }
    }
}

private final class CloudSyncAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

private enum CloudSyncTokenStore {
    private static let service = "app.Eclipse.Soupy.cloud-sync"

    static func token(for provider: CloudSyncProvider) -> ExperimentalCloudSyncManager.CloudSyncToken? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(ExperimentalCloudSyncManager.CloudSyncToken.self, from: data)
    }

    static func save(_ token: ExperimentalCloudSyncManager.CloudSyncToken, for provider: CloudSyncProvider) throws {
        let data = try JSONEncoder().encode(token)
        let lookup = baseQuery(for: provider)
        let updatedValues: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, updatedValues as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        let status: OSStatus
        if updateStatus == errSecItemNotFound {
            var attributes = lookup
            attributes.merge(updatedValues) { _, new in new }
            status = SecItemAdd(attributes as CFDictionary, nil)
        } else {
            status = updateStatus
        }
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not store \(provider.displayName) credentials in Keychain."]
            )
        }
    }

    static func deleteToken(for provider: CloudSyncProvider) {
        SecItemDelete(baseQuery(for: provider) as CFDictionary)
    }

    private static func baseQuery(for provider: CloudSyncProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
    }
}
#endif

#if !os(tvOS)
struct ExperimentalMPVPreloadCachedStarter {
    let data: Data
    let contentType: String?
    let totalLength: Int64?
    let statusCode: Int
    let isPlaylist: Bool
}

final class ExperimentalMPVPreloadManager {
    static let shared = ExperimentalMPVPreloadManager()

    private let fileManager = FileManager.default
    private let maxStarterBytes = 8 * 1024 * 1024
    private let maxStarterAge: TimeInterval = 30 * 60
    private let cacheKeyMigrationDefaultsKey = "experimentalMPVPreloadHashedCacheKeysMigrated"
    private var activeKeys = Set<String>()
    private let lock = NSLock()
#if canImport(Network)
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "dev.soupy.eclipse.experimental-mpv-preload.path")
    private var currentPath: NWPath?
#endif

    var cacheDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("ExperimentalMPVPreload", isDirectory: true)
    }

    private init() {
#if canImport(Network)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.currentPath = path
        }
        pathMonitor.start(queue: pathQueue)
#endif
        migrateLegacyCacheFileNamesIfNeeded()
        // On launch, bound the leftover cache to the configured size limit (evicting the oldest starters) rather than
        // wiping it wholesale.
        if Self.autoClearEnabled {
            pruneCacheIfNeeded(limitBytes: currentCacheLimitBytes())
        }
    }

    static var autoClearEnabled: Bool {
        (UserDefaults.standard.object(forKey: ExperimentalFeatureState.mpvPreloadAutoClearKey) as? Bool) ?? true
    }

    var cacheSizeBytes: Int64 {
        directorySize(at: cacheDirectory)
    }

    func shouldUsePlaybackProxy(for url: URL) -> Bool {
        playbackProxySkipReason(for: url) == nil
    }

    func playbackProxySkipReason(for url: URL) -> String? {
        if let reason = ExperimentalFeatureState.mpvAdvancedPlaybackUnavailableReason {
            return reason
        }
        guard UserDefaults.standard.bool(forKey: ExperimentalFeatureState.mpvPreloadEnabledKey) else {
            return "warmup-disabled"
        }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return "non-http-url" }
        guard !isLoopbackURL(url) else { return "loopback-proxy-url" }
        let path = url.pathExtension.lowercased()
        return isWarmupCompatiblePathExtension(path) ? nil : "unsupported-extension-\(path.isEmpty ? "empty" : path)"
    }

    func clearCache() {
        try? fileManager.removeItem(at: cacheDirectory)
        lock.lock()
        activeKeys.removeAll()
        lock.unlock()
    }

    func noteNextEpisodeCandidate(showId: Int, seasonNumber: Int, episodeNumber: Int) {
        if let reason = ExperimentalFeatureState.mpvAdvancedPlaybackUnavailableReason {
            Logger.shared.log(
                "MPV advanced smooth transition skipped show=\(showId) S\(seasonNumber)E\(episodeNumber) reason=\(reason)",
                type: "MPV"
            )
            return
        }
        guard UserDefaults.standard.bool(forKey: ExperimentalFeatureState.mpvSmoothTransitionEnabledKey) else {
            Logger.shared.log(
                "MPV advanced smooth transition skipped show=\(showId) S\(seasonNumber)E\(episodeNumber) reason=staging-disabled",
                type: "MPV"
            )
            return
        }
        Logger.shared.log(
            "MPV advanced smooth transition staged candidate show=\(showId) S\(seasonNumber)E\(episodeNumber)",
            type: "MPV"
        )
    }

    func prewarm(url: URL, headers: [String: String]?, label: String) {
        let safeLabel = label.isEmpty ? "unknown" : label
        let headerKeys = (headers ?? [:]).keys.sorted().joined(separator: ",")
        if let reason = ExperimentalFeatureState.mpvAdvancedPlaybackUnavailableReason {
            Logger.shared.log("MPV warmup skipped for \(safeLabel): \(reason)", type: "MPV")
            return
        }
        if let skipReason = preloadSkipReason(for: url) {
            Logger.shared.log("MPV warmup skipped for \(safeLabel): \(skipReason)", type: "MPV")
            return
        }

        if cachedStarter(for: url, headers: headers) != nil {
            Logger.shared.log("MPV warmup cache already ready for \(safeLabel) target=\(logURLSummary(url)) headerKeys=[\(headerKeys)]", type: "MPV")
            return
        }

        let key = cacheKey(for: url, headers: headers)
        guard reserveActiveKey(key) else {
            Logger.shared.log("MPV warmup coalesced for \(safeLabel) target=\(logURLSummary(url)) headerKeys=[\(headerKeys)]", type: "MPV")
            return
        }

        Logger.shared.log("MPV warmup started for \(safeLabel) target=\(logURLSummary(url)) key=\(String(key.prefix(8))) headerKeys=[\(headerKeys)] limitBytes=\(currentCacheLimitBytes())", type: "MPV")

        Task.detached(priority: .utility) { [self] in
            defer {
                releaseActiveKey(key)
            }
            guard !Task.isCancelled else { return }
            await writeStarterCache(url: url, headers: headers, key: key, label: label)
        }
    }

    func cachedStarter(for url: URL, headers: [String: String]?) -> ExperimentalMPVPreloadCachedStarter? {
        let key = cacheKey(for: url, headers: headers)
        let dataURL = starterURL(forKey: key)
        let metadataURL = starterMetadataURL(forKey: key)

        // Reserve only this cache key while validating its data/metadata pair.
        // The global lock protects the reservation itself, never the JSON
        // decode or the (up to 8 MiB) disk read. A writer for this same key is
        // therefore excluded without serializing unrelated cache I/O or
        // blocking player startup behind another key's disk access.
        guard reserveActiveKey(key) else { return nil }
        defer { releaseActiveKey(key) }

        guard let metadata = try? JSONDecoder().decode(StarterMetadata.self, from: Data(contentsOf: metadataURL)),
              Date().timeIntervalSince1970 - metadata.storedAt <= maxStarterAge,
              let data = try? Data(contentsOf: dataURL),
              !data.isEmpty,
              data.count == metadata.dataLength else {
            try? fileManager.removeItem(at: dataURL)
            try? fileManager.removeItem(at: metadataURL)
            return nil
        }

        return ExperimentalMPVPreloadCachedStarter(
            data: data,
            contentType: metadata.contentType,
            totalLength: metadata.totalLength,
            statusCode: metadata.statusCode,
            isPlaylist: metadata.isPlaylist
        )
    }

    func cachedStarter(
        for url: URL,
        headers: [String: String]?,
        waitForActiveWarmupUpTo timeout: TimeInterval
    ) async -> ExperimentalMPVPreloadCachedStarter? {
        let key = cacheKey(for: url, headers: headers)
        guard isActiveKey(key), timeout > 0 else {
            // Ordinary misses must not inherit the warmup grace period. Read the cache once and
            // let playback continue immediately unless this exact URL/header key is being staged.
            return cachedStarter(for: url, headers: headers)
        }

        let waitStartedAt = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while isActiveKey(key), Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return nil
            }
        }

        // A timed-out warmup may be between its two atomic file writes. Do not inspect (and
        // potentially invalidate) that partial pair; playback can fall through while staging
        // finishes in the background.
        guard !Task.isCancelled, !isActiveKey(key) else { return nil }
        let starter = cachedStarter(for: url, headers: headers)
        if let starter {
            let waitMilliseconds = Int(Date().timeIntervalSince(waitStartedAt) * 1_000)
            Logger.shared.log("MPV warmup cache became available target=\(logURLSummary(url)) waitMs=\(waitMilliseconds) bytes=\(starter.data.count)", type: "MPV")
        }
        return starter
    }

    private func reserveActiveKey(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeKeys.insert(key).inserted
    }

    private func releaseActiveKey(_ key: String) {
        lock.lock()
        activeKeys.remove(key)
        lock.unlock()
    }

    private func isActiveKey(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeKeys.contains(key)
    }

    private func preloadSkipReason(for url: URL) -> String? {
        guard UserDefaults.standard.bool(forKey: ExperimentalFeatureState.mpvPreloadEnabledKey) else { return "warmup-disabled" }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return "non-http-url" }
        guard !isLoopbackURL(url) else { return "loopback-proxy-url" }
        guard ProcessInfo.processInfo.isLowPowerModeEnabled == false else { return "low-power-mode" }
        guard ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return "thermal-pressure" }
        guard freeDiskBytes() > 750 * 1024 * 1024 else { return "low-disk-space" }
        if let networkSkipReason = currentNetworkPreloadSkipReason() {
            return networkSkipReason
        }
        // A full cache no longer blocks warmup: writeStarterCache() trims the oldest starters
        // back under the limit after writing, so reaching the limit evicts and keeps staging
        // going rather than stalling until the next relaunch.
        let path = url.pathExtension.lowercased()
        return isWarmupCompatiblePathExtension(path) ? nil : "unsupported-extension-\(path)"
    }

    private func isWarmupCompatiblePathExtension(_ path: String) -> Bool {
        path.isEmpty || [
            "m3u8",
            "m3u",
            "mp4",
            "m4v",
            "m4s",
            "mkv",
            "mov",
            "ts",
            "aac",
            "mp3"
        ].contains(path)
    }

    private func isLoopbackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func currentNetworkPreloadSkipReason() -> String? {
#if canImport(Network)
        guard let currentPath else { return "network-path-pending" }
        guard currentPath.status == .satisfied else { return "network-unsatisfied" }
        if currentPath.usesInterfaceType(.cellular),
           !UserDefaults.standard.bool(forKey: ExperimentalFeatureState.mpvPreloadCellularEnabledKey) {
            return "cellular-disabled"
        }
#endif
        return nil
    }

    private func currentCacheLimitBytes() -> Int64 {
#if canImport(Network)
        if currentPath?.usesInterfaceType(.cellular) == true {
            let mb = UserDefaults.standard.integer(forKey: ExperimentalFeatureState.mpvPreloadCellularLimitMBKey)
            return Int64(ExperimentalFeatureState.resolvedMPVPreloadCellularLimitMB(mb)) * 1024 * 1024
        }
#endif
        let mb = UserDefaults.standard.integer(forKey: ExperimentalFeatureState.mpvPreloadWifiLimitMBKey)
        return Int64(ExperimentalFeatureState.resolvedMPVPreloadWifiLimitMB(mb)) * 1024 * 1024
    }

    private func writeStarterCache(url: URL, headers: [String: String]?, key: String, label: String) async {
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
            headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            if url.pathExtension.lowercased() != "m3u8" {
                request.setValue("bytes=0-\(maxStarterBytes - 1)", forHTTPHeaderField: "Range")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                Logger.shared.log("MPV warmup skipped for \(label): empty-or-invalid-response target=\(logURLSummary(url))", type: "MPV")
                return
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type")
            let rangeInfo = parseContentRange(http.value(forHTTPHeaderField: "Content-Range"))
            let isPlaylist = isLikelyPlaylist(url: url, contentType: contentType)
            if isPlaylist {
                await writeHLSMediaStarterCache(playlistURL: url, data: data, headers: headers, label: label, depth: 0)
                return
            }

            let totalLength = rangeInfo?.totalLength
                ?? (http.expectedContentLength >= 0 ? http.expectedContentLength : nil)
            let isUsableRangeStarter = http.statusCode == 206 && rangeInfo?.start == 0
            guard isUsableRangeStarter else {
                Logger.shared.log("MPV warmup skipped for \(label): upstream-did-not-provide-usable-starter status=\(http.statusCode) range=\(http.value(forHTTPHeaderField: "Content-Range") ?? "nil") target=\(logURLSummary(url))", type: "MPV")
                return
            }

            let trimmed = data.count > maxStarterBytes ? data.prefix(maxStarterBytes) : data[...]
            let starterData = Data(trimmed)
            let target = starterURL(forKey: key)
            let metadata = StarterMetadata(
                statusCode: http.statusCode,
                contentType: contentType,
                totalLength: totalLength,
                isPlaylist: false,
                dataLength: starterData.count,
                storedAt: Date().timeIntervalSince1970
            )
            try starterData.write(to: target, options: .atomic)
            try JSONEncoder().encode(metadata).write(to: starterMetadataURL(forKey: key), options: .atomic)
            pruneCacheIfNeeded(limitBytes: currentCacheLimitBytes())
            Logger.shared.log("MPV warmup cached bytes=\(starterData.count) status=\(http.statusCode) playlist=false totalLength=\(totalLength.map(String.init) ?? "unknown") target=\(logURLSummary(url)) label=\(label)", type: "MPV")
        } catch {
            Logger.shared.log("MPV warmup skipped for \(label): \(error.localizedDescription) target=\(logURLSummary(url))", type: "MPV")
        }
    }

    private func writeHLSMediaStarterCache(
        playlistURL: URL,
        data: Data,
        headers: [String: String]?,
        label: String,
        depth: Int
    ) async {
        guard depth < 2 else {
            Logger.shared.log("MPV warmup skipped for \(label): hls-playlist-depth-limit target=\(logURLSummary(playlistURL))", type: "MPV")
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            Logger.shared.log("MPV warmup skipped for \(label): hls-playlist-not-utf8 target=\(logURLSummary(playlistURL))", type: "MPV")
            return
        }

        let plan = hlsWarmupPlan(from: text, playlistURL: playlistURL)
        if let variantURL = plan.variantURL {
            do {
                let (variantData, response) = try await fetchHLSPlaylistData(url: variantURL, headers: headers)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      !variantData.isEmpty else {
                    Logger.shared.log("MPV warmup skipped for \(label): hls-variant-invalid target=\(logURLSummary(variantURL))", type: "MPV")
                    return
                }
                Logger.shared.log("MPV warmup HLS master selected variant target=\(logURLSummary(variantURL)) playlist=\(logURLSummary(playlistURL))", type: "MPV")
                await writeHLSMediaStarterCache(
                    playlistURL: variantURL,
                    data: variantData,
                    headers: headers,
                    label: "\(label) HLS variant",
                    depth: depth + 1
                )
            } catch {
                Logger.shared.log("MPV warmup skipped for \(label): hls-variant-fetch-failed error=\(error.localizedDescription) target=\(logURLSummary(variantURL))", type: "MPV")
            }
            return
        }

        let targets = hlsMediaWarmupTargets(mapURL: plan.mapURL, segmentURL: plan.segmentURL)
        guard !targets.isEmpty else {
            Logger.shared.log("MPV warmup skipped for \(label): hls-no-media-target playlist=\(logURLSummary(playlistURL))", type: "MPV")
            return
        }

        Logger.shared.log("MPV warmup HLS media targets count=\(targets.count) playlist=\(logURLSummary(playlistURL)) targets=[\(targets.map { logURLSummary($0) }.joined(separator: ","))]", type: "MPV")
        var reservedTargets: [(url: URL, key: String)] = []
        for target in targets {
            let key = cacheKey(for: target, headers: headers)
            if reserveActiveKey(key) {
                reservedTargets.append((url: target, key: key))
            } else {
                Logger.shared.log("MPV warmup coalesced for \(label) HLS media target=\(logURLSummary(target))", type: "MPV")
            }
        }

        // Reserve the map and first segment together before either fetch begins. MPV commonly asks
        // for both back-to-back, so the second key must already be visible to the proxy while the
        // first target is still downloading.
        var pendingKeys = Set(reservedTargets.map { $0.key })
        defer {
            for key in pendingKeys {
                releaseActiveKey(key)
            }
        }

        for target in reservedTargets {
            guard !Task.isCancelled else { return }
            await writeStarterCache(
                url: target.url,
                headers: headers,
                key: target.key,
                label: "\(label) HLS media"
            )
            pendingKeys.remove(target.key)
            releaseActiveKey(target.key)
        }
    }

    private func fetchHLSPlaylistData(url: URL, headers: [String: String]?) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await URLSession.shared.data(for: request)
    }

    private func pruneCacheIfNeeded(limitBytes: Int64) {
        let directory = cacheDirectory
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard var files = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )?.compactMap({ item -> (url: URL, size: Int64, modified: Date)? in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                return nil
            }
            return (url, Int64(fileSize), values.contentModificationDate ?? .distantPast)
        }) else {
            return
        }

        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > limitBytes else { return }

        // Don't evict starters that are mid-write (in-flight warmups), the just-staged next episode, and any concurrent
        // warmup, so.
        lock.lock()
        let protectedKeys = activeKeys
        lock.unlock()

        files.sort { $0.modified < $1.modified }
        for file in files where total > limitBytes {
            let key = file.url.deletingPathExtension().lastPathComponent
            if protectedKeys.contains(key) { continue }
            try? fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }

    private func cacheKey(for url: URL, headers: [String: String]?) -> String {
        let headerSignature = (headers ?? [:])
            .map { "\($0.key.lowercased()):\($0.value)" }
            .sorted()
            .joined(separator: "\n")
        let raw = Array("\(url.absoluteString)\n\(headerSignature)".utf8)
#if canImport(CryptoKit)
        return SHA256.hash(data: Data(raw)).map { String(format: "%02x", $0) }.joined()
#else
        let hash = fnv1a64(raw)
        return String(format: "%016llx", hash)
#endif
    }

    private func starterURL(forKey key: String) -> URL {
        cacheDirectory.appendingPathComponent(key).appendingPathExtension("starter")
    }

    private func starterMetadataURL(forKey key: String) -> URL {
        cacheDirectory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private func logURLSummary(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "unknown")\(url.path)"
    }

    private func hlsWarmupPlan(from text: String, playlistURL: URL) -> HLSWarmupPlan {
        let baseURL = playlistURL.deletingLastPathComponent()
        var awaitingVariantURL = false
        var variantURL: URL?
        var mapURL: URL?
        var segmentURL: URL?

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("#") {
                if trimmed.range(of: "#EXT-X-STREAM-INF", options: [.caseInsensitive]) != nil {
                    awaitingVariantURL = true
                } else if trimmed.range(of: "#EXT-X-MAP", options: [.caseInsensitive]) != nil,
                          mapURL == nil,
                          let reference = hlsURIAttribute(in: trimmed) {
                    mapURL = resolvedHLSURL(reference, baseURL: baseURL)
                }
                continue
            }

            if awaitingVariantURL {
                variantURL = resolvedHLSURL(trimmed, baseURL: baseURL)
                break
            }

            if segmentURL == nil {
                segmentURL = resolvedHLSURL(trimmed, baseURL: baseURL)
            }

            if mapURL != nil, segmentURL != nil {
                break
            }
        }

        return HLSWarmupPlan(variantURL: variantURL, mapURL: mapURL, segmentURL: segmentURL)
    }

    private func hlsURIAttribute(in line: String) -> String? {
        guard let keyRange = line.range(of: "URI=", options: [.caseInsensitive]) else { return nil }
        let valueStart = keyRange.upperBound
        guard valueStart < line.endIndex else { return nil }

        if line[valueStart] == "\"" {
            let contentStart = line.index(after: valueStart)
            guard contentStart <= line.endIndex,
                  let contentEnd = line[contentStart...].firstIndex(of: "\"") else {
                return nil
            }
            return String(line[contentStart..<contentEnd])
        }

        let valueEnd = line[valueStart...].firstIndex(of: ",") ?? line.endIndex
        let value = String(line[valueStart..<valueEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func resolvedHLSURL(_ reference: String, baseURL: URL) -> URL? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.lowercased().hasPrefix("data:"),
              let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return resolved
    }

    private func hlsMediaWarmupTargets(mapURL: URL?, segmentURL: URL?) -> [URL] {
        var seen = Set<String>()
        var targets: [URL] = []
        for url in [mapURL, segmentURL].compactMap({ $0 }) {
            let key = url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            targets.append(url)
        }
        return targets
    }

    private func isLikelyPlaylist(url: URL, contentType: String?) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || ext == "m3u" {
            return true
        }
        let lower = contentType?.lowercased() ?? ""
        return lower.contains("mpegurl") || lower.contains("application/vnd.apple.mpegurl")
    }

    private func parseContentRange(_ value: String?) -> (start: Int64, end: Int64, totalLength: Int64?)? {
        guard let value else { return nil }
        let lower = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.hasPrefix("bytes ") else { return nil }
        let rangeAndTotal = lower.dropFirst("bytes ".count).split(separator: "/", maxSplits: 1).map(String.init)
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1).map(String.init)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]) else {
            return nil
        }
        let total = rangeAndTotal[1] == "*" ? nil : Int64(rangeAndTotal[1])
        return (start, end, total)
    }

    private func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    private func migrateLegacyCacheFileNamesIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: cacheKeyMigrationDefaultsKey) else { return }
        try? fileManager.removeItem(at: cacheDirectory)
        UserDefaults.standard.set(true, forKey: cacheKeyMigrationDefaultsKey)
    }

    private struct StarterMetadata: Codable {
        let statusCode: Int
        let contentType: String?
        let totalLength: Int64?
        let isPlaylist: Bool
        let dataLength: Int
        let storedAt: TimeInterval
    }

    private struct HLSWarmupPlan {
        let variantURL: URL?
        let mapURL: URL?
        let segmentURL: URL?
    }

    private func directorySize(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                continue
            }
            total += Int64(fileSize)
        }
        return total
    }

    private func freeDiskBytes() -> Int64 {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
#if os(tvOS)
        let attributes = try? fileManager.attributesOfFileSystem(forPath: caches.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
#else
        let values = try? caches.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
#endif
    }
}
#endif

class Settings: ObservableObject {
    static let shared = Settings()

    @Published var accentColor: Color {
        didSet {
            saveAccentColor(accentColor)
        }
    }
#if !os(tvOS)
    @Published var readerAccentColor: Color {
        didSet {
            saveReaderAccentColor(readerAccentColor)
        }
    }
#endif
    @Published var selectedAppearance: Appearance {
        didSet {
            UserDefaults.standard.set(selectedAppearance.rawValue, forKey: "selectedAppearance")
            updateAppearance()
        }
    }
#if !os(tvOS)
    @Published var readerSelectedAppearance: Appearance {
        didSet {
            UserDefaults.standard.set(readerSelectedAppearance.rawValue, forKey: "readerSelectedAppearance")
            updateAppearance()
        }
    }
#endif

    var effectiveAccentColor: Color {
#if os(tvOS)
        accentColor
#else
        UserDefaults.standard.bool(forKey: "showKanzen") && !EclipseTheme.shared.globalAppearanceEnabled ? readerAccentColor : accentColor
#endif
    }

    var effectiveAppearance: Appearance {
#if os(tvOS)
        selectedAppearance
#else
        UserDefaults.standard.bool(forKey: "showKanzen") && !EclipseTheme.shared.globalAppearanceEnabled ? readerSelectedAppearance : selectedAppearance
#endif
    }

    // In-App Player Settings
    private func migratedBool(genericKey: String, legacyKey: String, defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: genericKey) == nil {
            let value = UserDefaults.standard.object(forKey: legacyKey) as? Bool ?? defaultValue
            UserDefaults.standard.set(value, forKey: genericKey)
            return value
        }
        return UserDefaults.standard.bool(forKey: genericKey)
    }

    private func migratedDouble(genericKey: String, legacyKey: String, defaultValue: Double) -> Double {
        if UserDefaults.standard.object(forKey: genericKey) == nil {
            let value = UserDefaults.standard.double(forKey: legacyKey)
            let resolved = value > 0 ? value : defaultValue
            UserDefaults.standard.set(resolved, forKey: genericKey)
            return resolved
        }
        let value = UserDefaults.standard.double(forKey: genericKey)
        return value > 0 ? value : defaultValue
    }

    static func normalizedInAppPlayer(_ rawValue: String?) -> String {
        guard let raw = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else {
            return PlaybackEngine.automatic.rawValue
        }
        switch raw {
        case "mpv", "vlc": return PlaybackEngine.mpv.rawValue
        case "normal", "avplayer", "av player": return PlaybackEngine.avPlayer.rawValue
        case "automatic", "auto": return PlaybackEngine.automatic.rawValue
        default: return PlaybackEngine.automatic.rawValue
        }
    }

    var enableSubtitlesByDefault: Bool {
        get { UserDefaults.standard.bool(forKey: "enableSubtitlesByDefault") }
        set { UserDefaults.standard.set(newValue, forKey: "enableSubtitlesByDefault") }
    }

    var defaultSubtitleLanguage: String {
        get { UserDefaults.standard.string(forKey: "defaultSubtitleLanguage") ?? "eng" }
        set { UserDefaults.standard.set(newValue, forKey: "defaultSubtitleLanguage") }
    }

    var preferredAnimeAudioLanguage: String {
        get { UserDefaults.standard.string(forKey: "preferredAnimeAudioLanguage") ?? "jpn" }
        set { UserDefaults.standard.set(newValue, forKey: "preferredAnimeAudioLanguage") }
    }

    var preferredAutoAudioLanguage: String {
        get { UserDefaults.standard.string(forKey: "preferredAutoAudioLanguage") ?? "eng" }
        set { UserDefaults.standard.set(newValue, forKey: "preferredAutoAudioLanguage") }
    }

    var playerBrightnessGestureEnabled: Bool {
        get { migratedBool(genericKey: "playerBrightnessGestureEnabled", legacyKey: "vlcBrightnessGestureEnabled", defaultValue: false) }
        set { UserDefaults.standard.set(newValue, forKey: "playerBrightnessGestureEnabled") }
    }

    var playerVolumeGestureEnabled: Bool {
        get { migratedBool(genericKey: "playerVolumeGestureEnabled", legacyKey: "vlcVolumeGestureEnabled", defaultValue: false) }
        set { UserDefaults.standard.set(newValue, forKey: "playerVolumeGestureEnabled") }
    }

    var playerTwoFingerTapPlayPauseEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "playerTwoFingerTapPlayPauseEnabled") == nil {
                if let legacyValue = UserDefaults.standard.object(forKey: "mpvTwoFingerTapEnabled") as? Bool {
                    UserDefaults.standard.set(legacyValue, forKey: "playerTwoFingerTapPlayPauseEnabled")
                    return legacyValue
                }
                UserDefaults.standard.set(true, forKey: "playerTwoFingerTapPlayPauseEnabled")
            }
            return UserDefaults.standard.bool(forKey: "playerTwoFingerTapPlayPauseEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "playerTwoFingerTapPlayPauseEnabled") }
    }

    var defaultPlaybackSpeed: Double {
        get {
            let savedSpeed = UserDefaults.standard.double(forKey: "defaultPlaybackSpeed")
            return savedSpeed > 0 ? savedSpeed : 1.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "defaultPlaybackSpeed") }
    }

    var playerDoubleTapSeekEnabled: Bool {
        get { migratedBool(genericKey: "playerDoubleTapSeekEnabled", legacyKey: "vlcDoubleTapSeekEnabled", defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: "playerDoubleTapSeekEnabled") }
    }

    var playerDoubleTapSeekSeconds: Double {
        get { migratedDouble(genericKey: "playerDoubleTapSeekSeconds", legacyKey: "vlcDoubleTapSeekSeconds", defaultValue: 10.0) }
        set { UserDefaults.standard.set(newValue, forKey: "playerDoubleTapSeekSeconds") }
    }

    var playerOpenSubtitlesEnabled: Bool {
        get { migratedBool(genericKey: "playerOpenSubtitlesEnabled", legacyKey: "vlcOpenSubtitlesEnabled", defaultValue: false) }
        set { UserDefaults.standard.set(newValue, forKey: "playerOpenSubtitlesEnabled") }
    }

    var playerOpenSubtitlesAutoFallbackEnabled: Bool {
        get { migratedBool(genericKey: "playerOpenSubtitlesAutoFallbackEnabled", legacyKey: "vlcOpenSubtitlesAutoFallbackEnabled", defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: "playerOpenSubtitlesAutoFallbackEnabled") }
    }

    var playerPerformanceOverlayEnabled: Bool {
        get { false }
        set { UserDefaults.standard.set(false, forKey: "playerPerformanceOverlayEnabled") }
    }

    var mpvForegroundFPS: Int {
        get {
            UserDefaults.standard.integer(forKey: "mpvForegroundFPS") == 60 ? 60 : 30
        }
        set {
            UserDefaults.standard.set(newValue == 60 ? 60 : 30, forKey: "mpvForegroundFPS")
        }
    }

    var mpvRenderBackend: MPVRenderBackend {
        get {
            UserDefaults.standard.set(MPVRenderBackend.defaultBackend.rawValue, forKey: "mpvRenderBackend")
            return .defaultBackend
        }
        set {
            UserDefaults.standard.set(MPVRenderBackend.defaultBackend.rawValue, forKey: "mpvRenderBackend")
        }
    }

    var mpvMetalQualityProfile: MPVMetalQualityProfile {
        get {
            let raw = UserDefaults.standard.string(forKey: "mpvMetalQualityProfile")
                ?? MPVMetalQualityProfile.defaultProfile.rawValue
            return MPVMetalQualityProfile(rawValue: raw) ?? .defaultProfile
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "mpvMetalQualityProfile")
        }
    }

    /// gpu-next upscaling/deband shader mode. Read by the
    /// MoltenVK inline renderer; independent of `mpvMetalQualityProfile` (heat). Off by default.
    var mpvUpscalingMode: MPVUpscalingMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "mpvUpscalingMode")
                ?? MPVUpscalingMode.defaultMode.rawValue
            return MPVUpscalingMode(rawValue: raw) ?? .defaultMode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "mpvUpscalingMode")
        }
    }

    /// Shows the on-screen MoltenVK/mpv performance HUD (CPU, thermal state, active quality profile).
    /// Off by default; toggled from Player settings to MPV Rendering.
    var mpvPerformanceOverlayEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "mpvPerformanceOverlayEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "mpvPerformanceOverlayEnabled") }
    }

    /// The GPU gpu-next renderer (MoltenVK with direct VideoToolbox decode preferred) is the default MoltenVK renderer.
    var mpvUseLegacyCPURenderer: Bool {
        get { UserDefaults.standard.bool(forKey: "mpvUseLegacyCPURenderer") }
        set { UserDefaults.standard.set(newValue, forKey: "mpvUseLegacyCPURenderer") }
    }

    var mpvAppExitPictureInPictureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "mpvAppExitPictureInPictureEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "mpvAppExitPictureInPictureEnabled") }
    }

    /// Master Picture-in-Picture switch (default on). When off, the PiP button is hidden, the
    /// background warm of the separate PiP player is skipped, and auto-PiP-on-background is disabled.
    var mpvPictureInPictureEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "mpvPictureInPictureEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "mpvPictureInPictureEnabled") }
    }

    var mpvHDRMode: MPVHDRMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "mpvHDRMode")
                ?? MPVHDRMode.defaultMode.rawValue
            return MPVHDRMode(rawValue: raw) ?? .defaultMode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "mpvHDRMode")
        }
    }

    /// "Comfort"/anime-like audio processing preset (dynamic range compression + loudness
    /// normalization + peak limiting via mpv audio filters). `original` (off) by default.
    var audioComfortMode: AudioComfortMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "audioComfortMode")
                ?? AudioComfortMode.defaultMode.rawValue
            return AudioComfortMode(rawValue: raw) ?? .defaultMode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "audioComfortMode")
        }
    }

    /// The set of content categories the `audioComfortMode` processing applies to (multi-select:
    /// anime / western animation / live action). The full set is the "All" behavior and the
    /// default. Persisted as an array of rawValues; an empty stored array means "apply to none".
    var audioComfortScopeCategories: Set<AudioComfortContentCategory> {
        get {
            guard let raw = UserDefaults.standard.array(forKey: "audioComfortScopeCategories") as? [String] else {
                return AudioComfortContentCategory.defaultScope
            }
            return Set(raw.compactMap { AudioComfortContentCategory(rawValue: $0) })
        }
        set {
            UserDefaults.standard.set(newValue.map { $0.rawValue }, forKey: "audioComfortScopeCategories")
        }
    }

    /// Whether the player may request multichannel (5.1/7.1) PCM output on routes that
    /// support it (USB-C/HDMI/AirPlay). Built-in speakers always remain stereo. Defaults on.
    var mpvSurroundSoundEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "mpvSurroundSoundEnabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "mpvSurroundSoundEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "mpvSurroundSoundEnabled")
        }
    }

    var watchTogetherEnabled: Bool {
        get { WatchTogetherSettings.isEnabled() }
        set { UserDefaults.standard.set(newValue, forKey: WatchTogetherSettings.enabledKey) }
    }

    var googleCastEnabled: Bool {
        get { GoogleCastSettings.isEnabled() }
        set { UserDefaults.standard.set(newValue, forKey: GoogleCastSettings.enabledKey) }
    }

    var smartInAppPlayerChoosingEnabled: Bool {
        get { false }
        set { UserDefaults.standard.set(false, forKey: "smartInAppPlayerChoosingEnabled") }
    }

    var playerSubtitleAppearanceEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "playerSubtitleAppearanceEnabled") == nil {
                let legacy = UserDefaults.standard.object(forKey: "enableVLCSubtitleEditMenu") as? Bool ?? true
                UserDefaults.standard.set(legacy, forKey: "playerSubtitleAppearanceEnabled")
                return legacy
            }
            return UserDefaults.standard.bool(forKey: "playerSubtitleAppearanceEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "playerSubtitleAppearanceEnabled") }
    }

    enum PlayerChoice: String {
        case mpv
    }

    var playerChoice: PlayerChoice {
        get {
            let normalized = Self.normalizedInAppPlayer(UserDefaults.standard.string(forKey: "inAppPlayer"))
            if normalized != UserDefaults.standard.string(forKey: "inAppPlayer") {
                UserDefaults.standard.set(normalized, forKey: "inAppPlayer")
            }
            return .mpv
        }
        set {
            UserDefaults.standard.set("mpv", forKey: "inAppPlayer")
        }
    }

    init() {
        let resolvedAccentColor: Color
        if let colorData = UserDefaults.standard.data(forKey: "accentColor"),
           let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData) {
            resolvedAccentColor = Color(uiColor)
        } else {
            resolvedAccentColor = .accentColor
        }
        self.accentColor = resolvedAccentColor
#if !os(tvOS)
        if let colorData = UserDefaults.standard.data(forKey: "readerAccentColor"),
           let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData) {
            self.readerAccentColor = Color(uiColor)
        } else {
            self.readerAccentColor = resolvedAccentColor
        }
#endif
        let resolvedAppearance: Appearance
        if let appearanceRawValue = UserDefaults.standard.string(forKey: "selectedAppearance"),
           let appearance = Appearance(rawValue: appearanceRawValue) {
            resolvedAppearance = appearance
        } else {
            resolvedAppearance = .system
        }
        self.selectedAppearance = resolvedAppearance
#if !os(tvOS)
        if let appearanceRawValue = UserDefaults.standard.string(forKey: "readerSelectedAppearance"),
           let appearance = Appearance(rawValue: appearanceRawValue) {
            self.readerSelectedAppearance = appearance
        } else {
            self.readerSelectedAppearance = resolvedAppearance
        }
#endif
        updateAppearance()
    }

    private func saveAccentColor(_ color: Color) {

        let uiColor = UIColor(color)
        do {
            let colorData = try NSKeyedArchiver.archivedData(withRootObject: uiColor, requiringSecureCoding: false)
            UserDefaults.standard.set(colorData, forKey: "accentColor")
        } catch {
#if os(tvOS)
            Logger.shared.log("Failed to save accent color: \(error.localizedDescription)", type: "Settings")
#else
            ReaderLogger.shared.log("Failed to save accent color: \(error.localizedDescription)")
#endif
        }
    }

#if !os(tvOS)
    private func saveReaderAccentColor(_ color: Color) {
        let uiColor = UIColor(color)
        do {
            let colorData = try NSKeyedArchiver.archivedData(withRootObject: uiColor, requiringSecureCoding: false)
            UserDefaults.standard.set(colorData, forKey: "readerAccentColor")
        } catch {
            ReaderLogger.shared.log("Failed to save reader accent color: \(error.localizedDescription)")
        }
    }
#endif

    func updateAppearance() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard !windows.isEmpty else { return }

        let style: UIUserInterfaceStyle
        switch effectiveAppearance {
        case .system:
            style = .unspecified
        case .light:
            style = .light
        case .dark:
            style = .dark
        }
        for window in windows {
            window.overrideUserInterfaceStyle = style
        }
    }
}
