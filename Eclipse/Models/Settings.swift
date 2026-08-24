import SwiftUI
#if os(iOS)
import AuthenticationServices
import Combine
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

    static func usesCompactSeasonMenu(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        guard defaults.object(forKey: seasonMenuKey) != nil else {
            return prefersCompactSeasonMenu
        }
        return defaults.bool(forKey: seasonMenuKey)
    }

    static func usesHorizontalEpisodes(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        guard defaults.object(forKey: horizontalEpisodeListKey) != nil else {
            return prefersHorizontalEpisodes
        }
        return defaults.bool(forKey: horizontalEpisodeListKey)
    }
}

enum MediaDetailEpisodeVisibilitySettings {
    static let showUnairedEpisodesKey = "showUnairedEpisodes"
    static let defaultShowUnairedEpisodes = true
}

enum LibraryCollectionLayout: String, CaseIterable, Identifiable {
    case horizontal
    case vertical

    static let defaultValue: LibraryCollectionLayout = .horizontal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .horizontal:
            return "Horizontal"
        case .vertical:
            return "Vertical"
        }
    }
}

enum LibraryDisplaySettings {
    static let showBookmarksSectionKey = "libraryShowBookmarksSection"
    static let collectionLayoutKey = "libraryCollectionLayout"
    static let defaultShowBookmarksSection = true

    static func showsBookmarksSection(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        guard defaults.object(forKey: showBookmarksSectionKey) != nil else {
            return defaultShowBookmarksSection
        }
        return defaults.bool(forKey: showBookmarksSectionKey)
    }

    static func collectionLayout(defaults: UserDefaults = ProfileSettingsStore.active) -> LibraryCollectionLayout {
        guard let rawValue = defaults.string(forKey: collectionLayoutKey),
              let layout = LibraryCollectionLayout(rawValue: rawValue) else {
            return .defaultValue
        }
        return layout
    }
}

enum AppPerformanceOverlaySettings {
    static let enabledKey = "appPerformanceOverlayEnabled"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }
}

enum PlayerPlaybackLockSettings {
    static let enabledKey = "playerPlaybackLockEnabled"
    static let lockedKey = "playerPlaybackLocked"
    static let orientationKey = "playerPlaybackLockedOrientation"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }

    static func isLocked(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        isEnabled(defaults: defaults) && defaults.bool(forKey: lockedKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = ProfileSettingsStore.active) {
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
        defaults: UserDefaults = ProfileSettingsStore.active
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

    static func lockedOrientationMask(defaults: UserDefaults = ProfileSettingsStore.active) -> UIInterfaceOrientationMask? {
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

enum WatchTogetherSettings {
    static let enabledKey = "watchTogetherEnabled"
    static let defaultEnabled = true

    static var isAvailableInCurrentBuild: Bool {
#if os(iOS)
        Bundle.main.isAppleReviewedDistribution
#else
        false
#endif
    }

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        guard isAvailableInCurrentBuild else { return false }
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }
}

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

    static func selected(defaults: UserDefaults = ProfileSettingsStore.active) -> MPVPlayerSkin {
        let rawValue = defaults.string(forKey: skinKey) ?? ""
        if rawValue == "cypberpunk" { return .cyberpunk }
        return MPVPlayerSkin(rawValue: rawValue) ?? .defaultSkin
    }

    static func animationsEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        guard defaults.object(forKey: animationsEnabledKey) != nil else {
            return defaultAnimationsEnabled
        }
        return defaults.bool(forKey: animationsEnabledKey)
    }

    static func tintControlsOnly(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        guard defaults.object(forKey: tintControlsOnlyKey) != nil else {
            return defaultTintControlsOnly
        }
        return defaults.bool(forKey: tintControlsOnlyKey)
    }

    static func animationStyle(for skin: MPVPlayerSkin, defaults: UserDefaults = ProfileSettingsStore.active) -> MPVPlayerSkinAnimationStyle {
        if let raw = defaults.string(forKey: animationStyleKeyPrefix + skin.rawValue),
           let style = MPVPlayerSkinAnimationStyle(rawValue: raw) {
            return style
        }
        return skin.defaultAnimationStyle
    }

    static func setAnimationStyle(_ style: MPVPlayerSkinAnimationStyle, for skin: MPVPlayerSkin, defaults: UserDefaults = ProfileSettingsStore.active) {
        defaults.set(style.rawValue, forKey: animationStyleKeyPrefix + skin.rawValue)
    }
}

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

    static func orderedElements(defaults: UserDefaults = ProfileSettingsStore.active) -> [MediaDetailElement] {
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

    static func hiddenElements(defaults: UserDefaults = ProfileSettingsStore.active) -> Set<MediaDetailElement> {
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

    static func saveOrder(_ elements: [MediaDetailElement], defaults: UserDefaults = ProfileSettingsStore.active) {
        defaults.set(rawValue(for: elements), forKey: orderStorageKey)
    }

    static func saveHiddenElements(_ hiddenElements: Set<MediaDetailElement>, defaults: UserDefaults = ProfileSettingsStore.active) {
        defaults.set(rawValue(for: hiddenElements), forKey: hiddenStorageKey)
        defaults.set(!hiddenElements.contains(.cast), forKey: legacyShowCastStorageKey)
    }
}

enum MediaDetailSimilarTitlesSettings {
    static let enabledKey = "mediaDetailSimilarTitlesEnabled"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }
}

enum ServicesSheetPresentationSettings {
    static let stremioStyleEnabledKey = "servicesStremioStyleSheetEnabled"
    static let defaultStremioStyleEnabled = false

    static func usesStremioStyle(defaults: UserDefaults = ProfileSettingsStore.services) -> Bool {
        defaults.object(forKey: stremioStyleEnabledKey) == nil
            ? defaultStremioStyleEnabled
            : defaults.bool(forKey: stremioStyleEnabledKey)
    }
}

enum AutoModeSettings {
    static let enabledKey = "servicesAutoModeEnabled"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.services) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }
}

enum AutoModeErrorIntelligenceSettings {
    static let enabledKey = "servicesAutoModeErrorIntelligenceEnabled"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.services) -> Bool {
        defaults.object(forKey: enabledKey) == nil
            ? defaultEnabled
            : defaults.bool(forKey: enabledKey)
    }
}

enum ServicesResultRankingSettings {
    static let minimumSimilarityKey = "servicesResultMinimumSimilarity"
    static let dropMismatchedResultsKey = "servicesDropMismatchedResults"
    static let defaultMinimumSimilarity = 0.85
    static let defaultDropMismatchedResults = true
    static let minimumSimilarityRange = 0.50...1.00

    static func minimumSimilarity(defaults: UserDefaults = ProfileSettingsStore.services) -> Double {
        guard let value = defaults.object(forKey: minimumSimilarityKey) as? NSNumber else {
            return defaultMinimumSimilarity
        }
        return clampedMinimumSimilarity(value.doubleValue)
    }

    static func setMinimumSimilarity(_ value: Double, defaults: UserDefaults = ProfileSettingsStore.services) {
        defaults.set(clampedMinimumSimilarity(value), forKey: minimumSimilarityKey)
    }

    static func dropsMismatchedResults(defaults: UserDefaults = ProfileSettingsStore.services) -> Bool {
        guard defaults.object(forKey: dropMismatchedResultsKey) != nil else {
            return defaultDropMismatchedResults
        }
        return defaults.bool(forKey: dropMismatchedResultsKey)
    }

    static func setDropsMismatchedResults(_ enabled: Bool, defaults: UserDefaults = ProfileSettingsStore.services) {
        defaults.set(enabled, forKey: dropMismatchedResultsKey)
    }

    static func clampedMinimumSimilarity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMinimumSimilarity }
        return max(minimumSimilarityRange.lowerBound, min(value, minimumSimilarityRange.upperBound))
    }
}

enum ContentBlockingSettings {
    static let blockAddonSubtitlesKey = "contentBlockingBlockAddonSubtitles"
    static let blockAddonCatalogsKey = "contentBlockingBlockAddonCatalogs"
    static let defaultBlockAddonSubtitles = false
    static let defaultBlockAddonCatalogs = false

    static func blocksAddonSubtitles(defaults: UserDefaults = ProfileSettingsStore.services) -> Bool {
        guard defaults.object(forKey: blockAddonSubtitlesKey) != nil else {
            return defaultBlockAddonSubtitles
        }
        return defaults.bool(forKey: blockAddonSubtitlesKey)
    }

    static func setBlocksAddonSubtitles(_ enabled: Bool, defaults: UserDefaults = ProfileSettingsStore.services) {
        defaults.set(enabled, forKey: blockAddonSubtitlesKey)
    }

    static func blocksAddonCatalogs(defaults: UserDefaults = ProfileSettingsStore.services) -> Bool {
        guard defaults.object(forKey: blockAddonCatalogsKey) != nil else {
            return defaultBlockAddonCatalogs
        }
        return defaults.bool(forKey: blockAddonCatalogsKey)
    }

    static func setBlocksAddonCatalogs(_ enabled: Bool, defaults: UserDefaults = ProfileSettingsStore.services) {
        defaults.set(enabled, forKey: blockAddonCatalogsKey)
    }
}

enum StremioAddonComponent: String, CaseIterable {
    case catalogs
    case subtitles
}

enum StremioAddonComponentSettings {
    private static func storageKey(sourceID: String, component: StremioAddonComponent) -> String {
        "stremioAddonComponent.\(component.rawValue).\(sourceID)"
    }

    static func isEnabled(
        sourceID: String,
        component: StremioAddonComponent,
        defaults: UserDefaults = ProfileSettingsStore.services
    ) -> Bool {
        let key = storageKey(sourceID: sourceID, component: component)
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    static func setEnabled(
        _ enabled: Bool,
        sourceID: String,
        component: StremioAddonComponent,
        defaults: UserDefaults = ProfileSettingsStore.services
    ) {
        defaults.set(enabled, forKey: storageKey(sourceID: sourceID, component: component))
    }
}

enum NextEpisodeFillerSettings {
    static let enabledKey = "nextEpisodeSkipFillerEnabled"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
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

    static func orderedElements(defaults: UserDefaults = ProfileSettingsStore.active) -> [ReaderDetailElement] {
        orderedElements(from: defaults.string(forKey: orderStorageKey))
    }

    static func hiddenElements(from rawValue: String?) -> Set<ReaderDetailElement> {
        Set(
            (rawValue ?? "")
                .split(separator: ",")
                .compactMap { ReaderDetailElement(rawValue: String($0)) }
        )
    }

    static func hiddenElements(defaults: UserDefaults = ProfileSettingsStore.active) -> Set<ReaderDetailElement> {
        hiddenElements(from: defaults.string(forKey: hiddenStorageKey))
    }

    static func isVisible(_ element: ReaderDetailElement, hiddenRawValue: String?) -> Bool {
        !hiddenElements(from: hiddenRawValue).contains(element)
    }

    static func saveOrder(_ elements: [ReaderDetailElement], defaults: UserDefaults = ProfileSettingsStore.active) {
        defaults.set(rawValue(for: elements), forKey: orderStorageKey)
    }

    static func saveHiddenElements(_ hiddenElements: Set<ReaderDetailElement>, defaults: UserDefaults = ProfileSettingsStore.active) {
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

enum MPVUpscalingMode: String, CaseIterable, Identifiable {

    case off = "off"

    case upscaleTo1080 = "upscaleTo1080"

    case upscaleTo4K = "upscaleTo4K"

    case oneLevelAlways = "oneLevelAlways"

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

enum MPVNeuralUpscaler: String, CaseIterable, Identifiable {

    case off = "off"

    case automatic = "automatic"

    case anime = "anime"

    case animeLowBitrate = "animeLowBitrate"

    case general = "general"

    var id: String { rawValue }

    var shaderResource: (name: String, extension: String)? {
        switch self {
        case .off, .automatic: return nil
        case .anime: return ("ArtCNN_C4F16", "glsl")
        case .animeLowBitrate: return ("ArtCNN_C4F16_DS", "glsl")
        case .general: return ("AMD_FSR1_EASU_RCAS", "glsl")
        }
    }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .automatic: return "Automatic"
        case .anime: return "Animation (ArtCNN)"
        case .animeLowBitrate: return "Animation, Low Bitrate"
        case .general: return "Live Action (FSR 1)"
        }
    }

    var isConvolutional: Bool {
        switch self {
        case .off, .automatic, .general: return false
        case .anime, .animeLowBitrate: return true
        }
    }

    static let offeredUpscalers: [MPVNeuralUpscaler] = [.off, .automatic, .anime, .general]

    static let defaultUpscaler: MPVNeuralUpscaler = .off
}

enum AudioComfortMode: String, CaseIterable, Identifiable {

    case original

    case comfort

    case dialogue

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

enum AudioComfortContentCategory: String, CaseIterable, Identifiable {

    case anime

    case westernAnimation

    case liveAction

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anime: return "Anime"
        case .westernAnimation: return "Western Animation"
        case .liveAction: return "Live Action"
        }
    }

    static var defaultScope: Set<AudioComfortContentCategory> { Set(allCases) }
}

enum MPVHDRMode: String, CaseIterable, Identifiable {

    case auto

    case hdr

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

    private(set) static var isEnabledAtLaunch: Bool = {
#if os(tvOS)
        true
#else
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
#endif
    }()

    static func configureLaunchState(defaults: UserDefaults = ProfileSettingsStore.device) {
        registerDefaults(defaults: defaults)
#if os(tvOS)
        isEnabledAtLaunch = true
#else
        isEnabledAtLaunch = (defaults.object(forKey: enabledKey) as? Bool) ?? true
#endif
    }

    static func registerDefaults(defaults: UserDefaults = ProfileSettingsStore.device) {
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

    static func setStoredValue(_ enabled: Bool, defaults: UserDefaults = ProfileSettingsStore.device) {
#if !os(tvOS)
        defaults.set(enabled, forKey: enabledKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastChangedAtKey)
#endif
    }

    static var isMPVPlaybackDefault: Bool {
        let external = ProfileSettingsStore.active.string(forKey: "externalPlayer") ?? ""
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

        let external = ProfileSettingsStore.active.string(forKey: "externalPlayer") ?? ""
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

struct CloudSyncRemoteUsage: Equatable, Sendable {
    var byteCount: Int64
    var objectCount: Int
    var isComplete: Bool

    var isEmpty: Bool { objectCount == 0 }
}

enum CloudSyncTotalBudget: Int, CaseIterable, Identifiable, Sendable {
    case compact = 25_000_000
    case standard = 50_000_000
    case generous = 100_000_000
    case large = 250_000_000
    case unlimited = 9_223_372_036_854_775_807

    nonisolated static let storageKey = "experimentalCloudSyncTotalBudgetBytesV1"
    nonisolated static let fallback: CloudSyncTotalBudget = .standard

    nonisolated static let reservedSnapshotCopies = 2
    nonisolated static let defaultRetainedSnapshotCopies = 4

    var id: Int { rawValue }

    var isUnlimited: Bool { self == .unlimited }

    var displayName: String {
        switch self {
        case .compact: return "25 MB"
        case .standard: return "50 MB"
        case .generous: return "100 MB"
        case .large: return "250 MB"
        case .unlimited: return "No Limit"
        }
    }

    nonisolated static var current: CloudSyncTotalBudget {
        CloudSyncTotalBudget(
            rawValue: UserDefaults.standard.integer(forKey: storageKey)
        ) ?? fallback
    }

    func retainedSnapshotCopies(forSnapshotBytes bytes: Int) -> Int {
        guard !isUnlimited else { return Self.defaultRetainedSnapshotCopies }
        guard bytes > 0 else { return Self.defaultRetainedSnapshotCopies }
        return max(
            Self.reservedSnapshotCopies,
            min(Self.defaultRetainedSnapshotCopies, rawValue / bytes - 1)
        )
    }
}

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

    var accountEmailKey: String {
        "experimentalCloudSyncAccountEmailV1.\(rawValue)"
    }

    var accountIdentityUnresolvedKey: String {
        "experimentalCloudSyncAccountIdentityUnresolvedV1.\(rawValue)"
    }

    var pendingAccountIdentityKey: String {
        "experimentalCloudSyncPendingAccountIdentityV1.\(rawValue)"
    }

    var accountBoundaryPendingKey: String {
        "experimentalCloudSyncAccountBoundaryPendingV1.\(rawValue)"
    }

    var accountGenerationKey: String {
        "experimentalCloudSyncAccountGenerationV1.\(rawValue)"
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

struct ExperimentalCloudManualRestoreSession: Sendable {
    let enabledProviders: Set<CloudSyncProvider>
    let primaryProvider: CloudSyncProvider?
    let keepsChangesOnThisDevice: Bool
}

enum ExperimentalCloudManualRestorePolicy {
    static func enabledProvidersAfterRestore(
        _ session: ExperimentalCloudManualRestoreSession,
        succeeded: Bool
    ) -> Set<CloudSyncProvider> {
        succeeded && !session.keepsChangesOnThisDevice
            ? session.enabledProviders
            : []
    }

    static func queuesAuthoritativeSync(
        _ session: ExperimentalCloudManualRestoreSession,
        succeeded: Bool
    ) -> Bool {
        succeeded
            && !session.keepsChangesOnThisDevice
            && !session.enabledProviders.isEmpty
    }
}

enum CloudSyncSourceLoadingDeferral {
    enum Action: Equatable {
        case retry(streakStartedAt: Date)
        case escalate
    }

    static func action(
        streakStartedAt: Date?,
        now: Date,
        grace: TimeInterval
    ) -> Action {
        let startedAt = streakStartedAt ?? now
        guard now.timeIntervalSince(startedAt) < grace else { return .escalate }
        return .retry(streakStartedAt: startedAt)
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

enum ExperimentalCloudAutomaticFailureAction: Equatable {
    case retry
    case awaitOverwriteDecision
}

struct ExperimentalCloudAutomaticSyncPolicy {
    static func eligibleProviders(
        from orderedProviders: [CloudSyncProvider],
        pendingOverwriteDecisionProviders: Set<CloudSyncProvider>
    ) -> [CloudSyncProvider] {
        orderedProviders.filter {
            !pendingOverwriteDecisionProviders.contains($0)
        }
    }
}

struct ExperimentalCloudRetryBudget {
    static let maximumCumulativeDelay: TimeInterval = 30

    static func permits(delay: TimeInterval, after accumulatedDelay: TimeInterval) -> Bool {
        shouldRetry(
            delay: delay,
            after: accumulatedDelay,
            isCancelled: false
        )
    }

    static func shouldRetry(
        delay: TimeInterval,
        after accumulatedDelay: TimeInterval,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled
            && delay.isFinite
            && accumulatedDelay.isFinite
            && delay >= 0
            && accumulatedDelay + delay <= maximumCumulativeDelay
    }
}

struct ExperimentalCloudPersistedSchedule {
    static let maximumFutureSkew: TimeInterval = 7 * 24 * 60 * 60

    static func date(
        timestamp: TimeInterval,
        adding offset: TimeInterval = 0,
        now: Date
    ) -> Date? {
        let nowTimestamp = now.timeIntervalSince1970
        guard timestamp.isFinite,
              offset.isFinite,
              nowTimestamp.isFinite,
              timestamp > 0 else {
            return nil
        }
        let total = timestamp + offset
        guard total.isFinite,
              total >= 0,
              total <= nowTimestamp + maximumFutureSkew else {
            return nil
        }
        return Date(timeIntervalSince1970: total)
    }
}

enum ExperimentalCanonicalMediaStateBundlePresence: Equatable {
    case absent
    case invalidEmpty
    case present(Data)

    static func classify(_ data: Data?) -> ExperimentalCanonicalMediaStateBundlePresence {
        guard let data else { return .absent }
        guard !data.isEmpty else { return .invalidEmpty }
        return .present(data)
    }
}

struct ExperimentalCanonicalRestorePolicy {
    static func preservesCanonicalMediaState(
        transportIsAvailable: Bool,
        crossesAccountBoundary: Bool,
        canonicalBundleIsPresent: Bool
    ) -> Bool {
        transportIsAvailable && !(crossesAccountBoundary && !canonicalBundleIsPresent)
    }
}

struct ExperimentalCanonicalRemoteAuthorityPolicy {
    static func permitsAccountBoundaryUse(_ revision: MediaStateRemoteRevision?) -> Bool {
        revision?.isComplete != false
    }
}

struct ExperimentalCloudProviderStatusPolicy {
    static func mediaStateFailure(
        providerDisplayName: String,
        detail: String
    ) -> String {
        let sanitizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedDetail.isEmpty else {
            return "Library and watch progress could not sync through \(providerDisplayName)."
        }
        return "Library and watch progress could not sync through \(providerDisplayName). \(sanitizedDetail)"
    }

    static func visibleStatus(
        mediaStateFailure: String?,
        snapshotStatus: String?
    ) -> String? {
        if let mediaStateFailure, !mediaStateFailure.isEmpty {
            return mediaStateFailure
        }
        if let snapshotStatus, !snapshotStatus.isEmpty {
            return snapshotStatus
        }
        return nil
    }
}

struct ExperimentalGoogleDriveSnapshotWritePolicy {
    static func matchesExpectedCandidates(
        _ actual: [String],
        expected: [String]
    ) -> Bool {
        Set(actual) == Set(expected)
    }

    static func confirmsUploadedCandidate(
        expected: [String],
        uploadedID: String,
        observed: [String],
        headID: String?
    ) -> Bool {
        headID == uploadedID && Set(observed) == Set(expected).union([uploadedID])
    }
}

struct ExperimentalGoogleDriveMediaStateCompactionPolicy {
    static func canReplaceAndReduceCandidateSet(completeCandidateCount: Int) -> Bool {
        completeCandidateCount >= 2
    }
}

struct ExperimentalGoogleDriveListingCompletenessPolicy {
    static func isComplete(
        listedObjectCount: Int,
        recognizedCandidateCount: Int
    ) -> Bool {
        listedObjectCount >= 0
            && recognizedCandidateCount >= 0
            && listedObjectCount == recognizedCandidateCount
    }

    static func permitsMutation(isComplete: Bool) -> Bool {
        isComplete
    }
}

struct ExperimentalCloudPaginationGuard {
    static let maximumPages = 1_000
    static let maximumObjects = 100_000
    static let maximumCursorBytes = 8 * 1_024
    static let oneDriveChildrenPath = "/v1.0/me/drive/special/approot/children"

    private(set) var pageCount = 0
    private(set) var objectCount = 0
    private var seenCursors: Set<String> = []

    mutating func beginPage(cursor: String?) -> Bool {
        guard pageCount < Self.maximumPages else { return false }
        if let cursor {
            guard !cursor.isEmpty,
                  cursor.utf8.count <= Self.maximumCursorBytes,
                  seenCursors.insert(cursor).inserted else { return false }
        } else if pageCount != 0 {
            return false
        }
        pageCount += 1
        return true
    }

    mutating func recordObjects(_ count: Int, maximum: Int = maximumObjects) -> Bool {
        guard count >= 0, maximum >= 0 else { return false }
        let (next, overflow) = objectCount.addingReportingOverflow(count)
        guard !overflow, next <= maximum else { return false }
        objectCount = next
        return true
    }

    static func exactOneDriveNextURL(_ value: String?) -> URL? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= maximumCursorBytes,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "graph.microsoft.com",
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.percentEncodedPath == oneDriveChildrenPath else {
            return nil
        }
        return components.url
    }

    static func addingNonnegativeUsage(_ value: Int64, to total: Int64) -> Int64? {
        guard value >= 0, total >= 0 else { return nil }
        let (result, overflow) = total.addingReportingOverflow(value)
        return overflow ? nil : result
    }
}

struct ExperimentalOAuthExpiryPolicy {
    static let fallback: TimeInterval = 3_600
    static let minimum: TimeInterval = 1
    static let maximum: TimeInterval = 30 * 24 * 60 * 60

    static func normalized(_ value: TimeInterval?) -> TimeInterval {
        guard let value,
              value.isFinite,
              value >= minimum,
              value <= maximum else { return fallback }
        return value
    }
}

struct ExperimentalCloudAccountGenerationPolicy {
    static func next(after value: Int) -> Int {
        value &+ 1
    }
}

struct ExperimentalOneDriveWritePolicy {
    static func usableETag(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func isConflictStatus(_ statusCode: Int) -> Bool {
        statusCode == 409 || statusCode == 412 || statusCode == 428
    }
}

struct ExperimentalOneDriveBundleCompletenessPolicy {
    static func isComplete(
        metadataIsComplete: Bool,
        contentByteCount: Int?
    ) -> Bool {
        metadataIsComplete && (contentByteCount ?? 0) > 0
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
    @Published private var mediaStateTransportFailures: [CloudSyncProvider: String] = [:]
    @Published private var cloudKitMediaStateFailure: String?
    @Published private var providerLastSyncDates: [CloudSyncProvider: Date] = [:]
    @Published private(set) var connectionStateVersion = 0
    @Published private(set) var overwriteWarning: CloudSyncOverwriteWarning?
    @Published private var providerRemoteUsage: [CloudSyncProvider: CloudSyncRemoteUsage] = [:]
    @Published private var measuringUsageProviders: Set<CloudSyncProvider> = []
    private var refreshingAccountEmailProviders: Set<CloudSyncProvider> = []
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

    private static func persistedScheduleDate(
        defaults: UserDefaults,
        key: String,
        adding offset: TimeInterval = 0,
        now: Date
    ) -> Date? {
        let timestamp = defaults.double(forKey: key)
        guard timestamp != 0 else { return nil }
        guard let date = ExperimentalCloudPersistedSchedule.date(
            timestamp: timestamp,
            adding: offset,
            now: now
        ) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return date
    }

    private let authPresentationContextProvider = CloudSyncAuthPresentationContextProvider()
    private var authenticationSession: ASWebAuthenticationSession?
    private var pendingAutomaticSyncTask: Task<Void, Never>?
    private var cloudKitErrorObservation: AnyCancellable?
    private var pendingChangeDuringSync = false
    private var manualRestoreInterlockActive = false
    private var pendingIdentityRevalidations: Set<CloudSyncProvider> = []
    private var queuedOverwriteWarnings: [CloudSyncOverwriteWarning] = []
    private var sourceLoadingDeferralStartedAt: Date?
    private var observers: [NSObjectProtocol] = []

    private static let sourceLoadingRetryDelay: TimeInterval = 10
    private static let sourceLoadingDeferralGrace: TimeInterval = 90

    private var cloudSyncActionsAreAdministrable: Bool {
        ProfileManager.shared.activeProfile?.isKidsProfile != true
    }

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
        rehydratePendingAccountBoundaryWarnings()
        if #available(iOS 17.0, *) {
            cloudKitErrorObservation = MediaStateSyncManager.shared.$lastErrorMessage
                .removeDuplicates()
                .sink { [weak self] detail in
                    Task { @MainActor [weak self] in
                        self?.updateCloudKitMediaStateFailure(detail)
                    }
                }
        }
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
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard UserRatingManager.notificationBelongsToActiveProfile(notification) else {
                    return
                }
                Task { @MainActor in
                    self?.scheduleAutomaticSync()
                }
            }
        }
        for name in [Notification.Name.playerDidClose, .mediaStatePlaybackLeaseDidEnd] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
                            isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
                        ) else { return }
                        self?.scheduleAutomaticSync()
                    }
                }
            )
        }
        for name in [
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.didBecomeActiveNotification
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        BackupManager.shared.recoverInterruptedExperimentalCloudRestoreIfNeeded()
                        self?.resumeAuthorizedKeepLocalRecoveryIfNeeded()
                        self?.rehydratePendingAccountBoundaryWarnings()
                        self?.scheduleAutomaticSync()
                    }
                }
            )
        }
        observers.append(
            center.addObserver(
                forName: .experimentalCloudRestoreRecoveryDidComplete,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.rehydratePendingAccountBoundaryWarnings()
                    self?.scheduleAutomaticSync()
                }
            }
        )
        Task { @MainActor [weak self] in
            self?.resumeAuthorizedKeepLocalRecoveryIfNeeded()
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        pendingAutomaticSyncTask?.cancel()
    }

    func beginManualRestore(
        keepsChangesOnThisDevice: Bool
    ) -> ExperimentalCloudManualRestoreSession? {
        guard cloudSyncActionsAreAdministrable,
              !manualRestoreInterlockActive else {
            lastStatusMessage = "Cloud sync is busy. Wait for it to finish before restoring a backup."
            return nil
        }

        let enabledProviders = Set(CloudSyncProvider.allCases.filter {
            UserDefaults.standard.bool(forKey: $0.syncEnabledKey)
        })
        let session = ExperimentalCloudManualRestoreSession(
            enabledProviders: enabledProviders,
            primaryProvider: primaryProvider,
            keepsChangesOnThisDevice: keepsChangesOnThisDevice
        )

        pendingAutomaticSyncTask?.cancel()
        pendingAutomaticSyncTask = nil
        pendingChangeDuringSync = false
        if #available(iOS 17.0, *) {
            MediaStateRemoteTransportCoordinator.shared.invalidateActiveSyncPasses()
        }

        guard !isSyncing else {
            applyProviderEnablement([], preferredPrimary: nil)
            lastStatusMessage = "Cloud sync was turned off safely. Wait for the active operation to finish, then restore the backup again."
            return nil
        }

        manualRestoreInterlockActive = true
        applyProviderEnablement([], preferredPrimary: nil)
        return session
    }

    func finishManualRestore(
        _ session: ExperimentalCloudManualRestoreSession,
        succeeded: Bool
    ) {
        guard manualRestoreInterlockActive else { return }

        let restoredProviders = ExperimentalCloudManualRestorePolicy
            .enabledProvidersAfterRestore(session, succeeded: succeeded)
        applyProviderEnablement(
            restoredProviders,
            preferredPrimary: session.primaryProvider
        )
        manualRestoreInterlockActive = false

        if ExperimentalCloudManualRestorePolicy.queuesAuthoritativeSync(
            session,
            succeeded: succeeded
        ) {
            let providers = enabledProvidersForAutomaticSync()
            if !providers.isEmpty {
                syncProviders(
                    providers,
                    reason: "manual-backup-authoritative-restore"
                )
            }
        } else if !session.enabledProviders.isEmpty {
            let message = succeeded
                ? "Backup restored on this device. Cloud sync stays off here until you turn a provider on again."
                : "Backup restore did not finish. Cloud sync was left off to protect your other devices."
            lastStatusMessage = message
            for provider in session.enabledProviders {
                setStatus(message, for: provider)
            }
        }
    }

    private func applyProviderEnablement(
        _ enabledProviders: Set<CloudSyncProvider>,
        preferredPrimary: CloudSyncProvider?
    ) {
        let defaults = UserDefaults.standard
        for provider in CloudSyncProvider.allCases {
            defaults.set(
                enabledProviders.contains(provider),
                forKey: provider.syncEnabledKey
            )
            if !enabledProviders.contains(provider) {
                mediaStateTransportFailures.removeValue(forKey: provider)
            }
        }

        let selectedPrimary = preferredPrimary.flatMap {
            enabledProviders.contains($0) ? $0 : nil
        } ?? CloudSyncProvider.allCases.first(where: enabledProviders.contains)
        primaryProvider = selectedPrimary
        if let selectedPrimary {
            defaults.set(selectedPrimary.rawValue, forKey: Self.primaryProviderKey)
        } else {
            defaults.removeObject(forKey: Self.primaryProviderKey)
        }

        MediaStateSyncBootstrap.setCloudKitSyncEnabled(
            enabledProviders.contains(.iCloud)
        )
        connectionStateVersion += 1
    }

    private func rehydratePendingAccountBoundaryWarnings() {

        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync else { return }
        let defaults = UserDefaults.standard
        for provider in CloudSyncProvider.allCases where provider.requiresAccountConnection {
            guard defaults.bool(forKey: provider.accountBoundaryPendingKey),
                  CloudSyncTokenStore.token(for: provider) != nil else { continue }
            let storedIdentity = defaults.string(forKey: provider.accountIdentityKey)
            let identityWasUnresolved = defaults.bool(forKey: provider.accountIdentityUnresolvedKey)
            let parkedIdentity = defaults.string(forKey: provider.pendingAccountIdentityKey)
            if !identityWasUnresolved, parkedIdentity == nil {
                revalidatePendingAccountBoundary(provider: provider, storedIdentity: storedIdentity)
                continue
            }
            enqueueOverwriteWarning(
                CloudSyncOverwriteWarning(
                    provider: provider,
                    localRecordCount: 0,
                    remoteRecordCount: 0,
                    direction: .accountChanged
                )
            )
            providerStatusMessages[provider] =
                "Choose which copy to keep before syncing this account."
        }
    }

    private func revalidatePendingAccountBoundary(provider: CloudSyncProvider, storedIdentity: String?) {
        guard !pendingIdentityRevalidations.contains(provider) else { return }
        pendingIdentityRevalidations.insert(provider)
        let generation = UserDefaults.standard.integer(forKey: provider.accountGenerationKey)
        providerStatusMessages[provider] = "Confirming the connected \(provider.displayName) account..."
        Task {
            defer { pendingIdentityRevalidations.remove(provider) }
            let fetchedAccount: CloudAccountIdentity?
            do {
                fetchedAccount = try await Self.fetchAccountIdentity(provider: provider)
            } catch {
                setStatus("Could not confirm the \(provider.displayName) account yet. Eclipse will retry.", for: provider)
                return
            }
            let defaults = UserDefaults.standard
            guard defaults.integer(forKey: provider.accountGenerationKey) == generation,
                  defaults.bool(forKey: provider.accountBoundaryPendingKey) else { return }
            let fetched = fetchedAccount?.stableIdentifier
            guard let fetched, !fetched.isEmpty else {
                setStatus("Could not confirm the \(provider.displayName) account yet. Eclipse will retry.", for: provider)
                return
            }
            Self.storeAccountEmail(fetchedAccount?.email, for: provider)
            connectionStateVersion += 1
            if let storedIdentity, fetched != storedIdentity {
                defaults.set(fetched, forKey: provider.pendingAccountIdentityKey)
                setStatus("Choose which copy to keep before syncing this account.", for: provider)
                enqueueOverwriteWarning(
                    CloudSyncOverwriteWarning(
                        provider: provider,
                        localRecordCount: 0,
                        remoteRecordCount: 0,
                        direction: .accountChanged
                    )
                )
                return
            }
            defaults.set(fetched, forKey: provider.accountIdentityKey)
            defaults.removeObject(forKey: provider.accountIdentityUnresolvedKey)
            defaults.removeObject(forKey: provider.pendingAccountIdentityKey)
            defaults.removeObject(forKey: provider.accountBoundaryPendingKey)
            connectionStateVersion += 1
            withdrawAccountBoundaryWarning(for: provider)
            setStatus("Confirmed the same \(provider.displayName) account. Sync resumed.", for: provider)
            Logger.shared.log(
                "Experimental cloud sync confirmed \(provider.displayName) account continuity without user intervention",
                type: "CloudSync"
            )
            scheduleAutomaticSync()
        }
    }

    private func withdrawAccountBoundaryWarning(for provider: CloudSyncProvider) {
        queuedOverwriteWarnings.removeAll {
            $0.provider == provider && $0.direction == .accountChanged
        }
        if let displayed = overwriteWarning,
           displayed.provider == provider,
           displayed.direction == .accountChanged {
            advanceOverwriteWarning()
        }
    }

    private func resumeAuthorizedKeepLocalRecoveryIfNeeded() {
        guard !manualRestoreInterlockActive,
              !isSyncing,
              let replay = BackupManager.shared
                .authorizedExperimentalCloudKeepLocalReplay(),
              let provider = CloudSyncProvider(
                rawValue: replay.context.providerRawValue
              ) else {
            return
        }

        let currentGeneration = UserDefaults.standard.integer(
            forKey: provider.accountGenerationKey
        )
        guard currentGeneration == replay.context.generation else {

            let message = "Your keep-device recovery is safely paused. Reconnect the same \(provider.displayName) account you originally chose to finish it."
            setStatus(message, for: provider)
            lastStatusMessage = message
            return
        }

        let resolution = PendingAccountResolution(
            generation: replay.context.generation,
            pendingIdentity: replay.context.pendingIdentity
        )
        isSyncing = true
        activeProvider = provider
        setStatus("Finishing your keep-device decision...", for: provider)
        Task {
            do {
                let date = try await Self.finishAuthorizedKeepLocalReplacement(
                    replay: replay,
                    provider: provider,
                    resolution: resolution
                )
                completeProviderTask(
                    provider: provider,
                    statusPrefix: "Kept this device's copy",
                    date: date
                )
            } catch {
                let message = "Your keep-device decision is safely journaled. Eclipse will retry when \(provider.displayName) is available."
                setStatus(message, for: provider)
                lastStatusMessage = message
                activeProvider = nil
                isSyncing = false
                Logger.shared.log(
                    "Keep-local provider replay remains pending provider=\(provider.rawValue) errorCase=\(Self.diagnosticCaseToken(for: error)) errorType=\(String(reflecting: type(of: error)))",
                    type: "CloudSync"
                )
            }
        }
    }

    func syncOnActivationIfNeeded(reason: String) {

        guard MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
            isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
        ) else { return }
        BackupManager.shared.recoverInterruptedExperimentalCloudRestoreIfNeeded()
        resumeAuthorizedKeepLocalRecoveryIfNeeded()
        rehydratePendingAccountBoundaryWarnings()
        guard !manualRestoreInterlockActive else { return }
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync else { return }
        guard ExperimentalFeatureState.isEnabledAtLaunch else { return }
        let providers = enabledProvidersForAutomaticSync()
        guard !providers.isEmpty else { return }

        let now = Date()
        let nextAllowedByProvider = Dictionary(uniqueKeysWithValues: providers.map { provider -> (CloudSyncProvider, Date) in
            let defaults = UserDefaults.standard
            let attemptDate = Self.persistedScheduleDate(
                defaults: defaults,
                key: provider.lastAutomaticAttemptKey,
                adding: 300,
                now: now
            ) ?? .distantPast
            let retryDate = Self.persistedScheduleDate(
                defaults: defaults,
                key: provider.retryNotBeforeKey,
                now: now
            ) ?? .distantPast
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
        guard cloudSyncActionsAreAdministrable else { return }
        guard !manualRestoreInterlockActive else {
            lastStatusMessage = "Finish the current backup restore before syncing cloud data."
            return
        }
        guard !isSyncing else {
            lastStatusMessage = "Cloud sync is already in progress. Try again when it finishes."
            return
        }
        syncProviders(enabledProvidersForManualSync(), reason: reason)
    }

    func syncSnapshot(provider: CloudSyncProvider, reason: String = "manual") {
        guard cloudSyncActionsAreAdministrable else { return }
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
        guard cloudSyncActionsAreAdministrable else { return }
        runProviderTask(provider: provider, statusPrefix: "Restored") {
            try await Self.restoreRemoteSnapshotSafely(provider: provider)
        }
    }

    func cancelOverwriteWarning() {
        guard cloudSyncActionsAreAdministrable,
              !manualRestoreInterlockActive else { return }

        if let warning = overwriteWarning,
           warning.direction == .accountChanged,
           UserDefaults.standard.bool(forKey: warning.provider.accountBoundaryPendingKey) {

            setProviderEnabled(warning.provider, enabled: false)
            let message = "\(warning.provider.displayName) sync is off until you choose which copy to keep."
            setStatus(message, for: warning.provider)
            lastStatusMessage = message
        }
        advanceOverwriteWarning()
    }

    func restoreCloudAfterOverwriteWarning() {
        guard cloudSyncActionsAreAdministrable,
              !manualRestoreInterlockActive else { return }
        guard let warning = overwriteWarning else { return }
        if warning.direction == .accountChanged,
           !UserDefaults.standard.bool(forKey: warning.provider.accountBoundaryPendingKey) {
            advanceOverwriteWarning()
            return
        }
        guard !isSyncing else {
            setStatus(
                "Finishing the current sync. Choose again in a moment.",
                for: warning.provider
            )
            return
        }
        let provider = warning.provider
        let crossedAccountBoundary = warning.direction == .accountChanged
        let boundaryResolution = crossedAccountBoundary
            ? Self.pendingAccountResolution(provider: provider)
            : nil
        if crossedAccountBoundary {

            setProviderEnabled(provider, enabled: true)
        }
        advanceOverwriteWarning()
        runProviderTask(provider: provider, statusPrefix: "Restored", bypassesAccountBoundary: true) {
            if let boundaryResolution {
                guard !MediaStatePlaybackLease.isActive else {
                    throw SyncError.snapshotRestoreFailed
                }
                let canonical = try await Self.readMediaStateForPendingAccountBoundary(
                    provider: provider,
                    matching: boundaryResolution
                )
                let date: Date
                do {
                    date = try await Self.restoreRemoteSnapshot(
                        provider: provider,
                        expectedAccountGeneration: boundaryResolution.generation,
                        canonicalAccountBoundaryRecords: canonical.records,
                        pendingAccountResolution: boundaryResolution
                    )
                } catch SyncError.noSnapshot(let missingProvider)
                    where missingProvider == provider
                        && Self.canonicalMediaStateTransportIsAvailable {

                    guard #available(iOS 17.0, *) else {
                        throw SyncError.noSnapshot(missingProvider)
                    }
                    guard let canonicalRecords = canonical.records else {
                        throw SyncError.noSnapshot(missingProvider)
                    }
                    let rollbackSnapshot = try Self.requireRecoverySnapshot(
                        BackupManager.shared.prepareAccountBoundaryRecoverySnapshot()
                    )
                    let recoveryContext = ExperimentalCloudRestoreBoundaryContext(
                        providerRawValue: provider.rawValue,
                        generation: boundaryResolution.generation,
                        pendingIdentity: boundaryResolution.pendingIdentity,
                        outgoingProfileIDs: ProfileManager.shared.profiles
                            .map(\.id)
                            .sorted { $0.uuidString < $1.uuidString }
                    )
                    guard BackupManager.shared.prepareExperimentalCloudRestoreRecovery(
                        using: rollbackSnapshot,
                        accountBoundaryContext: recoveryContext
                    ) else {
                        throw SyncError.restoreRecoveryPreparationFailed
                    }
                    do {
                        try Self.requirePendingAccountResolution(
                            provider: provider,
                            matching: boundaryResolution
                        )
                    } catch {
                        BackupManager.shared.completeExperimentalCloudRestoreRecovery()
                        throw error
                    }
                    let installed = await MediaStateSyncManager.shared
                        .performConfirmedRemoteAccountBoundaryWithoutLegacySnapshot(
                            with: canonicalRecords,
                            commit: { outgoingProfileIDs in
                                Self.commitPendingAccountResolution(
                                    provider: provider,
                                    matching: boundaryResolution,
                                    outgoingProfileIDs: outgoingProfileIDs
                                )
                            }
                        )
                    guard installed else {
                        _ = await BackupManager.shared
                            .rollbackPreparedExperimentalCloudRestoreRecovery()
                        throw SyncError.snapshotRestoreFailed
                    }
                    guard BackupManager.shared.completeExperimentalCloudRestoreRecovery() else {

                        throw SyncError.restoreRecoveryPending
                    }
                    date = Date()
                }
                return date
            }
            return try await Self.restoreRemoteSnapshot(provider: provider)
        }
    }

    func replaceCloudAfterOverwriteWarning() {
        guard cloudSyncActionsAreAdministrable,
              !manualRestoreInterlockActive else { return }
        guard let warning = overwriteWarning else { return }
        if warning.direction == .accountChanged,
           !UserDefaults.standard.bool(forKey: warning.provider.accountBoundaryPendingKey) {
            advanceOverwriteWarning()
            return
        }
        guard !isSyncing else {
            setStatus(
                "Finishing the current sync. Choose again in a moment.",
                for: warning.provider
            )
            return
        }
        let provider = warning.provider
        let crossedAccountBoundary = warning.direction == .accountChanged
        let boundaryResolution = crossedAccountBoundary
            ? Self.pendingAccountResolution(provider: provider)
            : nil
        if crossedAccountBoundary {
            setProviderEnabled(provider, enabled: true)
        }
        advanceOverwriteWarning()
        runProviderTask(
            provider: provider,
            statusPrefix: "Replaced cloud backup",
            bypassesAccountBoundary: true
        ) {
            if let boundaryResolution {
                guard !MediaStatePlaybackLease.isActive else {
                    throw SyncError.snapshotRestoreFailed
                }
                try Self.requirePendingAccountResolution(
                    provider: provider,
                    matching: boundaryResolution
                )
                let rollbackSnapshot = try Self.requireRecoverySnapshot(
                    BackupManager.shared.prepareAccountBoundaryRecoverySnapshot()
                )

                try Self.requirePendingAccountResolution(
                    provider: provider,
                    matching: boundaryResolution
                )
                let recoveryContext = ExperimentalCloudRestoreBoundaryContext(
                    providerRawValue: provider.rawValue,
                    generation: boundaryResolution.generation,
                    pendingIdentity: boundaryResolution.pendingIdentity,
                    outgoingProfileIDs: []
                )
                guard BackupManager.shared.prepareExperimentalCloudRestoreRecovery(
                    using: rollbackSnapshot,
                    accountBoundaryContext: recoveryContext,
                    keepLocalTransportSnapshot: rollbackSnapshot
                ) else {
                    throw SyncError.restoreRecoveryPreparationFailed
                }
                var keepLocalWriteIsAuthorized = false
                do {
                    try Self.requirePendingAccountResolution(
                        provider: provider,
                        matching: boundaryResolution
                    )
                    guard BackupManager.shared.authorizeExperimentalCloudKeepLocalWrite(
                        context: recoveryContext
                    ) else {
                        throw SyncError.restoreRecoveryPreparationFailed
                    }
                    keepLocalWriteIsAuthorized = true
                    guard let replay = BackupManager.shared
                        .authorizedExperimentalCloudKeepLocalReplay(),
                          replay.context == recoveryContext else {
                        throw SyncError.restoreRecoveryPending
                    }
                    return try await Self.finishAuthorizedKeepLocalReplacement(
                        replay: replay,
                        provider: provider,
                        resolution: boundaryResolution
                    )
                } catch {
                    if !keepLocalWriteIsAuthorized {
                        _ = await BackupManager.shared
                            .rollbackPreparedExperimentalCloudRestoreRecovery()
                        throw error
                    }

                    throw SyncError.restoreRecoveryPending
                }
            }
            return try await Self.writeLocalSnapshot(
                provider: provider,
                reason: "confirmed-destructive-replacement"
            )
        }
    }

    func connectProvider(_ provider: CloudSyncProvider) {
        guard cloudSyncActionsAreAdministrable,
              !manualRestoreInterlockActive,
              provider.requiresAccountConnection else { return }
        guard !isSyncing else { return }

        let connectAttemptGeneration = UserDefaults.standard.integer(
            forKey: provider.accountGenerationKey
        )
        isSyncing = true
        activeProvider = provider
        setStatus("Connecting to \(provider.displayName)...", for: provider)

        Task {
            var expectedGeneration = connectAttemptGeneration
            do {
                let token = try await authorize(provider: provider)

                try Self.requireAccountGeneration(
                    provider,
                    expected: connectAttemptGeneration
                )
                let connectedGeneration = ExperimentalCloudAccountGenerationPolicy.next(
                    after: connectAttemptGeneration
                )
                expectedGeneration = connectedGeneration

                UserDefaults.standard.set(true, forKey: provider.accountBoundaryPendingKey)

                UserDefaults.standard.removeObject(
                    forKey: provider.pendingAccountIdentityKey
                )
                UserDefaults.standard.set(
                    connectedGeneration,
                    forKey: provider.accountGenerationKey
                )
                try CloudSyncTokenStore.save(token, for: provider)

                UserDefaults.standard.removeObject(forKey: provider.lastSeenRemoteModificationKey)
                UserDefaults.standard.removeObject(forKey: provider.lastSyncedFootprintKey)
                UserDefaults.standard.removeObject(forKey: provider.lastSeenRemoteRevisionKey)
                UserDefaults.standard.removeObject(forKey: provider.accountEmailKey)
                connectionStateVersion += 1

                let identityResult = await Self.prepareOAuthReconciliationIdentity(
                    provider: provider,
                    expectedGeneration: connectedGeneration
                )
                try Self.requireAccountGeneration(provider, expected: connectedGeneration)
                let continuity = identityResult.continuity
                if continuity == .confirmed {
                    withdrawAccountBoundaryWarning(for: provider)
                }

                if let authorizedReplay = BackupManager.shared
                    .authorizedExperimentalCloudKeepLocalReplay(),
                   authorizedReplay.context.providerRawValue == provider.rawValue {

                    let reboundReplay = identityResult.freshlyVerifiedIdentity
                        .flatMap { verifiedIdentity in
                            BackupManager.shared
                                .rebindAuthorizedExperimentalCloudKeepLocalReplay(
                                    providerRawValue: provider.rawValue,
                                    generation: connectedGeneration,
                                    verifiedPendingIdentity: verifiedIdentity
                                )
                        }
                    setProviderEnabled(provider, enabled: true)
                    guard let reboundReplay else {
                        isSyncing = false
                        activeProvider = nil
                        let message = "Your keep-device recovery is safely paused. Reconnect the same \(provider.displayName) account you originally chose to finish it."
                        setStatus(message, for: provider)
                        lastStatusMessage = message
                        return
                    }
                    let reboundResolution = PendingAccountResolution(
                        generation: connectedGeneration,
                        pendingIdentity: reboundReplay.context.pendingIdentity
                    )
                    let date = try await Self.finishAuthorizedKeepLocalReplacement(
                        replay: reboundReplay,
                        provider: provider,
                        resolution: reboundResolution
                    )
                    completeProviderTask(
                        provider: provider,
                        statusPrefix: "Reconnected and kept this device's copy",
                        date: date
                    )
                    return
                }

                guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync else {
                    setProviderEnabled(provider, enabled: true)
                    isSyncing = false
                    activeProvider = nil
                    let message = "Finish the interrupted cloud recovery before syncing \(provider.displayName)."
                    setStatus(message, for: provider)
                    lastStatusMessage = message
                    return
                }
                guard continuity != .deferredVerification else {
                    setProviderEnabled(provider, enabled: true)
                    isSyncing = false
                    activeProvider = nil
                    let message = "Connected. Eclipse will confirm the \(provider.displayName) account and resume sync automatically."
                    setStatus(message, for: provider)
                    lastStatusMessage = message
                    return
                }
                guard !continuity.requiresUserDecision else {

                    setProviderEnabled(provider, enabled: true)
                    isSyncing = false
                    activeProvider = nil
                    let message = continuity == .changed
                        ? "Connected to a different \(provider.displayName) account. Choose which copy to keep before syncing."
                        : "Could not confirm which \(provider.displayName) account this is. Choose which copy to keep before syncing."
                    setStatus(message, for: provider)
                    lastStatusMessage = message
                    enqueueOverwriteWarning(
                        CloudSyncOverwriteWarning(
                            provider: provider,
                            localRecordCount: 0,
                            remoteRecordCount: 0,
                            direction: .accountChanged
                        )
                    )
                    return
                }

                setProviderEnabled(provider, enabled: true)
                let date = try await Self.reconcileSnapshot(provider: provider, reason: "connected")
                try Self.requireAccountGeneration(provider, expected: connectedGeneration)
                completeProviderTask(provider: provider, statusPrefix: "Connected and synced", date: date)
            } catch {
                guard UserDefaults.standard.integer(forKey: provider.accountGenerationKey) == expectedGeneration else {

                    activeProvider = nil
                    isSyncing = false
                    return
                }
                failProviderTask(provider: provider, error: error)
            }
        }
    }

    func remoteUsage(for provider: CloudSyncProvider) -> CloudSyncRemoteUsage? {
        providerRemoteUsage[provider]
    }

    func isMeasuringRemoteUsage(for provider: CloudSyncProvider) -> Bool {
        measuringUsageProviders.contains(provider)
    }

    func refreshRemoteUsage(for provider: CloudSyncProvider, force: Bool = false) {
        guard !measuringUsageProviders.contains(provider) else { return }
        guard !provider.requiresAccountConnection || isProviderConnected(provider) else {
            providerRemoteUsage.removeValue(forKey: provider)
            return
        }
        guard force || providerRemoteUsage[provider] == nil else { return }

        measuringUsageProviders.insert(provider)
        Task {
            let measured: CloudSyncRemoteUsage?
            do {
                switch provider {
                case .googleDrive:
                    measured = try await Self.googleDriveUsage()
                case .oneDrive:
                    measured = try await Self.oneDriveUsage()
                case .iCloud:
                    measured = try await Task.detached(priority: .utility) {
                        try Self.iCloudUsage()
                    }.value
                }
            } catch {
                measured = nil
            }
            measuringUsageProviders.remove(provider)
            if let measured {
                providerRemoteUsage[provider] = measured
            } else {
                providerRemoteUsage.removeValue(forKey: provider)
            }
        }
    }

    func refreshRemoteUsageForVisibleProviders() {
        for provider in CloudSyncProvider.allCases where UserDefaults.standard.bool(forKey: provider.syncEnabledKey) || isProviderConnected(provider) {
            refreshRemoteUsage(for: provider)
        }
    }

    var canDeleteAppleAccountMediaState: Bool {
        guard MediaStateSyncBootstrap.hasCloudKitEntitlement else { return false }
        if #available(iOS 17.0, *) { return true }
        return false
    }

    var isAppleAccountMediaStateSuspended: Bool {
        _ = connectionStateVersion
        return MediaStateCloudKitSuspension.needsUserVisibleResume
    }

    func resumeAppleAccountMediaStateSync() {
        guard cloudSyncActionsAreAdministrable,
              !manualRestoreInterlockActive,
              MediaStateCloudKitSuspension.isSuspended else { return }
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync else {
            setStatus("Finish the interrupted cloud restore before resuming library sync.", for: .iCloud)
            return
        }
        MediaStateCloudKitSuspension.resume()
        MediaStateSyncBootstrap.setCloudKitSyncEnabled(true)
        connectionStateVersion += 1
        let message = "Library and watch progress are syncing through your Apple account again."
        setStatus(message, for: .iCloud)
        lastStatusMessage = message
    }

    func deleteRemoteData(for provider: CloudSyncProvider) {
        guard cloudSyncActionsAreAdministrable,
              !manualRestoreInterlockActive else { return }
        guard !isSyncing else {
            let message = "A sync started while the confirmation was open. Wait for it to finish, then confirm Delete Cloud Data again."
            setStatus(message, for: provider)
            lastStatusMessage = message
            return
        }
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync else {
            setStatus("Finish the interrupted cloud restore before deleting cloud data.", for: provider)
            return
        }
        guard !provider.requiresAccountConnection || isProviderConnected(provider) else {
            setStatus("Connect \(provider.displayName) first.", for: provider)
            return
        }
        if BackupManager.shared.authorizedExperimentalCloudKeepLocalReplay() != nil {
            setStatus("A pending cloud restore still needs to finish. Try again after it completes.", for: provider)
            return
        }
        if provider == .iCloud, canDeleteAppleAccountMediaState {
            if #available(iOS 17.0, *), MediaStateSyncManager.shared.isAccountWorkInProgress {
                setStatus("Eclipse is still finishing an iCloud account change. Try again in a moment.", for: provider)
                return
            }
        }

        let startingMessage = "Deleting Eclipse cloud data from \(provider.displayName)..."
        setStatus(startingMessage, for: provider)
        lastStatusMessage = startingMessage

        setProviderEnabled(provider, enabled: false)
        pendingAutomaticSyncTask?.cancel()
        pendingAutomaticSyncTask = nil
        if #available(iOS 17.0, *) {
            MediaStateRemoteTransportCoordinator.shared.invalidateActiveSyncPasses()
        }
        if provider.requiresAccountConnection {
            UserDefaults.standard.set(
                ExperimentalCloudAccountGenerationPolicy.next(
                    after: UserDefaults.standard.integer(
                        forKey: provider.accountGenerationKey
                    )
                ),
                forKey: provider.accountGenerationKey
            )
        }

        isSyncing = true
        activeProvider = provider

        Task {
            let outcome: (removed: Int, failed: Int)
            do {
                switch provider {
                case .googleDrive:
                    outcome = try await Self.deleteAllGoogleDriveData()
                case .oneDrive:
                    outcome = try await Self.deleteAllOneDriveData()
                case .iCloud:
                    var fileOutcome = try await Task.detached(priority: .utility) {
                        try Self.deleteAllICloudData()
                    }.value
                    if #available(iOS 17.0, *), canDeleteAppleAccountMediaState {
                        do {
                            fileOutcome.removed += try await MediaStateSyncManager.shared
                                .deleteAllRemoteMediaState()
                        } catch {
                            fileOutcome.failed += 1
                            Logger.shared.log(
                                "CloudSync: could not delete the iCloud record zone: \(error.localizedDescription)",
                                type: "Error"
                            )
                        }
                    }
                    outcome = fileOutcome
                }
            } catch {
                isSyncing = false
                activeProvider = nil
                failProviderTask(provider: provider, error: error)
                return
            }

            if outcome.failed == 0 {
                Self.forgetRemoteSnapshotMarkers(for: provider)
            }
            providerLastSyncDates.removeValue(forKey: provider)
            providerRemoteUsage.removeValue(forKey: provider)
            refreshRemoteUsage(for: provider, force: true)
            if activeProvider == provider { activeProvider = nil }
            isSyncing = false
            connectionStateVersion += 1

            let message: String
            if outcome.failed == 0, isAppleAccountMediaStateSuspended {
                message = "Deleted Eclipse backup files from \(provider.displayName). Uploads are now off for this device, and library and watch progress stay on this device until you tap Resume Library Sync."
            } else if outcome.failed == 0 {
                message = "Deleted Eclipse backup files from \(provider.displayName). Uploads are now off for this device."
            } else {
                message = "Removed \(outcome.removed) item\(outcome.removed == 1 ? "" : "s") from \(provider.displayName); \(outcome.failed) could not be removed."
            }
            setStatus(message, for: provider)
            lastStatusMessage = message
            Logger.shared.log(
                "CloudSync: deleted remote data provider=\(provider.rawValue) removed=\(outcome.removed) failed=\(outcome.failed)",
                type: "CloudSync"
            )
        }
    }

    private static func forgetRemoteSnapshotMarkers(for provider: CloudSyncProvider) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: provider.lastSeenRemoteModificationKey)
        defaults.removeObject(forKey: provider.lastSeenRemoteRevisionKey)
        defaults.removeObject(forKey: provider.lastSyncedFootprintKey)
        defaults.removeObject(forKey: provider.lastSuccessfulSyncKey)
        defaults.removeObject(forKey: provider.lastAutomaticAttemptKey)
        defaults.removeObject(forKey: provider.retryNotBeforeKey)
    }

    func disconnectProvider(_ provider: CloudSyncProvider) {
        guard cloudSyncActionsAreAdministrable,
              !manualRestoreInterlockActive,
              provider.requiresAccountConnection else { return }

        UserDefaults.standard.removeObject(forKey: provider.accountBoundaryPendingKey)
        UserDefaults.standard.removeObject(forKey: provider.pendingAccountIdentityKey)
        UserDefaults.standard.set(
            ExperimentalCloudAccountGenerationPolicy.next(
                after: UserDefaults.standard.integer(
                    forKey: provider.accountGenerationKey
                )
            ),
            forKey: provider.accountGenerationKey
        )
        CloudSyncTokenStore.deleteToken(for: provider)
        UserDefaults.standard.removeObject(forKey: provider.accountEmailKey)
        setProviderEnabled(provider, enabled: false)
        providerRemoteUsage.removeValue(forKey: provider)
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

    func connectedAccountEmail(for provider: CloudSyncProvider) -> String? {
        guard provider.requiresAccountConnection,
              isProviderConnected(provider) else { return nil }
        _ = connectionStateVersion
        return Self.normalizedAccountEmail(
            UserDefaults.standard.string(forKey: provider.accountEmailKey)
        )
    }

    func refreshConnectedAccountEmails() {
        for provider in CloudSyncProvider.allCases
        where provider.requiresAccountConnection
            && isProviderConnected(provider)
            && connectedAccountEmail(for: provider) == nil
            && !refreshingAccountEmailProviders.contains(provider) {
            refreshingAccountEmailProviders.insert(provider)
            let generation = UserDefaults.standard.integer(
                forKey: provider.accountGenerationKey
            )
            Task {
                defer { refreshingAccountEmailProviders.remove(provider) }
                guard let identity = try? await Self.fetchAccountIdentity(
                    provider: provider
                ) else { return }
                let defaults = UserDefaults.standard
                guard defaults.integer(forKey: provider.accountGenerationKey) == generation,
                      CloudSyncTokenStore.token(for: provider) != nil else { return }
                let acceptedIdentities = Set([
                    defaults.string(forKey: provider.accountIdentityKey),
                    defaults.string(forKey: provider.pendingAccountIdentityKey)
                ].compactMap { $0 })
                guard acceptedIdentities.contains(identity.stableIdentifier) else { return }
                Self.storeAccountEmail(identity.email, for: provider)
                connectionStateVersion += 1
            }
        }
    }

    func statusMessage(for provider: CloudSyncProvider) -> String {
        let visibleMediaStateFailure: String?
        if UserDefaults.standard.bool(forKey: provider.syncEnabledKey),
           canUseProvider(provider) {
            visibleMediaStateFailure = provider == .iCloud
                ? cloudKitMediaStateFailure
                : mediaStateTransportFailures[provider]
        } else {
            visibleMediaStateFailure = nil
        }
        if let visible = ExperimentalCloudProviderStatusPolicy.visibleStatus(
            mediaStateFailure: visibleMediaStateFailure,
            snapshotStatus: providerStatusMessages[provider]
        ) {
            return visible
        }
        if MediaStateAccountBoundaryRecoveryGate.isBlockingSync {
            return "Paused while Eclipse finishes an interrupted cloud restore. Reopen Eclipse if this does not clear."
        }
        if provider == .iCloud, isAppleAccountMediaStateSuspended {
            return "Library and watch progress stopped syncing through your Apple account when you deleted the iCloud copy. Use Resume Library Sync to start again."
        }
        return ""
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
                && !UserDefaults.standard.bool(forKey: provider.accountBoundaryPendingKey)
        }
    }

    func setProviderEnabled(_ provider: CloudSyncProvider, enabled: Bool) {
        guard cloudSyncActionsAreAdministrable,
              !manualRestoreInterlockActive else { return }
        updateProviderEnabledPreference(provider, enabled: enabled)
    }

    private func updateProviderEnabledPreference(
        _ provider: CloudSyncProvider,
        enabled: Bool
    ) {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: provider.syncEnabledKey)
        if provider == .iCloud {
            MediaStateSyncBootstrap.setCloudKitSyncEnabled(enabled)
        }
        if !enabled {
            mediaStateTransportFailures.removeValue(forKey: provider)
        }
        if enabled {
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
        guard cloudSyncActionsAreAdministrable,
              !manualRestoreInterlockActive else { return }
        guard UserDefaults.standard.bool(forKey: provider.syncEnabledKey) else { return }
        primaryProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.primaryProviderKey)
        connectionStateVersion += 1
    }

    private func orderedEnabledProviders() -> [CloudSyncProvider] {
        let enabled = CloudSyncProvider.allCases.filter { provider in
            UserDefaults.standard.bool(forKey: provider.syncEnabledKey) && canUseProvider(provider)
        }
        guard !enabled.isEmpty else { return [] }

        let first = primaryProvider.flatMap { enabled.contains($0) ? $0 : nil } ?? enabled[0]
        return [first] + enabled.filter { $0 != first }
    }

    private var pendingOverwriteDecisionProviders: Set<CloudSyncProvider> {
        var providers = Set(queuedOverwriteWarnings.map(\.provider))
        if let overwriteWarning {
            providers.insert(overwriteWarning.provider)
        }
        return providers
    }

    private func enabledProvidersForAutomaticSync() -> [CloudSyncProvider] {
        ExperimentalCloudAutomaticSyncPolicy.eligibleProviders(
            from: orderedEnabledProviders(),
            pendingOverwriteDecisionProviders: pendingOverwriteDecisionProviders
        )
    }

    private func scheduleAutomaticSync() {
        guard !manualRestoreInterlockActive,
              ExperimentalFeatureState.isEnabledAtLaunch,
              !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
              !enabledProvidersForAutomaticSync().isEmpty else {
            return
        }
        guard MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
            isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
        ) else {
            pendingAutomaticSyncTask?.cancel()
            pendingAutomaticSyncTask = nil
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
            let boundedDelay = delay.isFinite ? max(0, min(delay, 86_400)) : 0
            let nanoseconds = UInt64(boundedDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.pendingAutomaticSyncTask = nil
            guard MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
                isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
            ) else { return }
            self.syncOnActivationIfNeeded(reason: reason)
        }
    }

    private func enabledProvidersForManualSync() -> [CloudSyncProvider] {
        let providers = orderedEnabledProviders()
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
        guard !manualRestoreInterlockActive,
              !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
              !providers.isEmpty,
              !isSyncing,
              !automatic || MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
                isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
              ) else { return }
        var attemptsBeforeSync: [CloudSyncProvider: Double] = [:]
        if automatic {
            let timestamp = Date().timeIntervalSince1970
            providers.forEach {
                attemptsBeforeSync[$0] = UserDefaults.standard.double(forKey: $0.lastAutomaticAttemptKey)
                UserDefaults.standard.set(timestamp, forKey: $0.lastAutomaticAttemptKey)
            }
        }
        let previousAutomaticAttempts = attemptsBeforeSync
        isSyncing = true
        activeProvider = nil

        Task {
            var syncedCount = 0
            var lastDate: Date?
            var failedProviders: [CloudSyncProvider] = []
            var retryableFailedProviders: [CloudSyncProvider] = []
            var deferredProviders: [CloudSyncProvider] = []

            for provider in providers {
                activeProvider = provider
                do {
                    let date = try await Self.reconcileSnapshot(provider: provider, reason: reason)
                    syncedCount += 1
                    lastDate = date
                    setStatus("Synced \(Self.relativeSyncTime(for: date))", for: provider)
                    recordSuccessfulSync(date, for: provider)
                } catch let error as SyncError where error.isSourceLoadingDeferral {
                    guard case let .retry(startedAt) = CloudSyncSourceLoadingDeferral.action(
                        streakStartedAt: sourceLoadingDeferralStartedAt,
                        now: Date(),
                        grace: Self.sourceLoadingDeferralGrace
                    ) else {
                        failedProviders.append(provider)
                        retryableFailedProviders.append(provider)
                        handleProviderFailure(provider: provider, error: SyncError.snapshotPreparationStalled)
                        continue
                    }
                    sourceLoadingDeferralStartedAt = startedAt
                    deferredProviders.append(provider)
                    if let previousAttempt = previousAutomaticAttempts[provider] {
                        UserDefaults.standard.set(previousAttempt, forKey: provider.lastAutomaticAttemptKey)
                    }
                    setStatus(error.localizedDescription, for: provider)
                    Logger.shared.log(
                        "Cloud sync deferred provider=\(provider.rawValue) reason=sources-loading",
                        type: "CloudSync"
                    )
                } catch {
                    failedProviders.append(provider)
                    if Self.automaticFailureAction(for: error) == .retry {
                        retryableFailedProviders.append(provider)
                    }
                    handleProviderFailure(provider: provider, error: error)
                }
            }

            activeProvider = nil
            isSyncing = false
            if syncedCount > 0 || BackupManager.shared.backupDomainReadiness == .ready {
                sourceLoadingDeferralStartedAt = nil
            }
            if let lastDate, syncedCount > 0 {
                lastSyncDate = lastDate
                lastStatusMessage = syncedCount == 1
                    ? "Synced 1 provider \(Self.relativeSyncTime(for: lastDate))"
                    : "Synced \(syncedCount) providers \(Self.relativeSyncTime(for: lastDate))"
            } else if !deferredProviders.isEmpty, failedProviders.isEmpty {
                lastStatusMessage = "Cloud sync is waiting for sources to finish loading."
            } else {
                lastStatusMessage = "Cloud sync could not complete."
            }
            if !deferredProviders.isEmpty {
                pendingChangeDuringSync = false
                scheduleAutomaticSync(
                    after: Self.sourceLoadingRetryDelay,
                    reason: "sources-loading-retry"
                )
            } else if automatic, !retryableFailedProviders.isEmpty {
                scheduleAutomaticRetry(for: retryableFailedProviders)
            }
            scheduleFollowUpIfNeeded(afterSyncing: providers)
        }
    }

    private func runProviderTask(
        provider: CloudSyncProvider,
        statusPrefix: String,
        bypassesAccountBoundary: Bool = false,
        operation: @escaping () async throws -> Date
    ) {
        guard !manualRestoreInterlockActive else {
            let message = "Finish the current backup restore before using \(provider.displayName) sync."
            setStatus(message, for: provider)
            lastStatusMessage = message
            return
        }
        guard !isSyncing else {
            let message = "Cloud sync is already in progress. Try \(provider.displayName) again when it finishes."
            setStatus(message, for: provider)
            lastStatusMessage = message
            return
        }
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync else {
            setStatus("Finish the interrupted cloud restore before syncing.", for: provider)
            return
        }
        guard UserDefaults.standard.bool(forKey: provider.syncEnabledKey) else {
            setStatus("Enable \(provider.displayName) sync first.", for: provider)
            return
        }
        if !bypassesAccountBoundary {
            let now = Date()
            if let retryDate = Self.persistedScheduleDate(
                defaults: UserDefaults.standard,
                key: provider.retryNotBeforeKey,
                now: now
            ), retryDate > now {
                setStatus(
                    "\(provider.displayName) is temporarily limiting sync requests. Eclipse will retry \(Self.relativeSyncTime(for: retryDate)).",
                    for: provider
                )
                scheduleAutomaticSync(
                    after: max(1, retryDate.timeIntervalSince(now)),
                    reason: "provider-cooldown-ended"
                )
                return
            }
        }
        let isQuarantined = UserDefaults.standard.bool(forKey: provider.accountBoundaryPendingKey)
        guard canUseProvider(provider) || (bypassesAccountBoundary && isQuarantined && isProviderConnected(provider)) else {
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
                if bypassesAccountBoundary,
                   !Self.requiresFreshAuthorization(error),
                   !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
                   UserDefaults.standard.bool(forKey: provider.accountBoundaryPendingKey),
                   isProviderConnected(provider) {

                    enqueueOverwriteWarning(
                        CloudSyncOverwriteWarning(
                            provider: provider,
                            localRecordCount: 0,
                            remoteRecordCount: 0,
                            direction: .accountChanged
                        )
                    )
                }
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
        providerRemoteUsage.removeValue(forKey: provider)
        scheduleFollowUpIfNeeded(afterSyncing: [provider])
    }

    private func failProviderTask(provider: CloudSyncProvider, error: Error) {
        handleProviderFailure(provider: provider, error: error)
        lastStatusMessage = "\(provider.displayName): \(statusMessage(for: provider))"
        activeProvider = nil
        isSyncing = false
        if let syncError = error as? SyncError, syncError.isSourceLoadingDeferral {
            pendingChangeDuringSync = false
            scheduleAutomaticSync(
                after: Self.sourceLoadingRetryDelay,
                reason: "sources-loading-retry"
            )
        }
        scheduleFollowUpIfNeeded(afterSyncing: [provider])
    }

    private func handleProviderFailure(provider: CloudSyncProvider, error: Error) {
        presentOverwriteWarningIfNeeded(provider: provider, error: error)

        if provider.requiresAccountConnection, Self.requiresFreshAuthorization(error) {
            CloudSyncTokenStore.deleteToken(for: provider)
            updateProviderEnabledPreference(provider, enabled: false)
            setStatus("Your \(provider.displayName) connection expired. Connect it again to resume sync.", for: provider)
        } else {
            setStatus(error.localizedDescription, for: provider)
        }

        Logger.shared.log(
            "Cloud sync failed provider=\(provider.rawValue) errorCase=\(Self.diagnosticCaseToken(for: error)) errorType=\(String(reflecting: type(of: error)))",
            type: "CloudSync"
        )
    }

    private static func automaticFailureAction(
        for error: Error
    ) -> ExperimentalCloudAutomaticFailureAction {
        (error as? SyncError)?.automaticFailureAction ?? .retry
    }

    private static func diagnosticCaseToken(for error: Error) -> String {
        (error as? SyncError)?.diagnosticCaseToken ?? "non-sync-error"
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
        guard let displayed = overwriteWarning else {
            overwriteWarning = warning
            return
        }
        if displayed.provider != warning.provider {
            queuedOverwriteWarnings.append(warning)
        } else if warning.direction == .accountChanged, displayed.direction != .accountChanged {

            overwriteWarning = warning
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
            guard MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
                isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
            ) else { return }
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
            return max(
                Self.persistedScheduleDate(
                    defaults: defaults,
                    key: provider.lastAutomaticAttemptKey,
                    adding: 300,
                    now: now
                ) ?? now,
                Self.persistedScheduleDate(
                    defaults: defaults,
                    key: provider.retryNotBeforeKey,
                    now: now
                ) ?? now
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

    private func updateCloudKitMediaStateFailure(_ detail: String?) {
        guard let detail,
              !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cloudKitMediaStateFailure = nil
            return
        }
        let status = ExperimentalCloudProviderStatusPolicy.mediaStateFailure(
            providerDisplayName: CloudSyncProvider.iCloud.displayName,
            detail: detail
        )
        cloudKitMediaStateFailure = status
        if UserDefaults.standard.bool(forKey: CloudSyncProvider.iCloud.syncEnabledKey) {
            lastStatusMessage = status
        }
    }

    private func recordSuccessfulSync(_ date: Date, for provider: CloudSyncProvider) {
        providerLastSyncDates[provider] = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: provider.lastSuccessfulSyncKey)
    }

    func recordMediaStateTransportSuccess(for provider: CloudSyncProvider) {
        mediaStateTransportFailures.removeValue(forKey: provider)
    }

    func recordMediaStateTransportFailure(
        for provider: CloudSyncProvider,
        message: String
    ) {
        guard provider != .iCloud,
              UserDefaults.standard.bool(forKey: provider.syncEnabledKey),
              canUseProvider(provider) else { return }
        let status = ExperimentalCloudProviderStatusPolicy.mediaStateFailure(
            providerDisplayName: provider.displayName,
            detail: message
        )
        mediaStateTransportFailures[provider] = status
        lastStatusMessage = status
    }

    private func unavailableMessage(for provider: CloudSyncProvider) -> String {
        switch provider {
        case .iCloud:
            return ExperimentalCloudSyncAvailability.current.statusMessage
        case .googleDrive, .oneDrive:
            let defaults = UserDefaults.standard
            if isProviderConnected(provider),
               defaults.bool(forKey: provider.accountBoundaryPendingKey) {
                if defaults.string(forKey: provider.pendingAccountIdentityKey) != nil ||
                    defaults.bool(forKey: provider.accountIdentityUnresolvedKey) {
                    return "Choose which copy to keep before syncing this account."
                }
                return "Connected. Eclipse is confirming the \(provider.displayName) account before syncing."
            }
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

    private static func requireReconciliationRecoveryGateOpen() throws {
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync else {
            throw SyncError.restoreRecoveryPending
        }
    }

    private static func requirePreparedSnapshot(
        _ preparation: ExperimentalCloudSnapshotPreparation
    ) throws -> ExperimentalCloudSnapshot {
        switch preparation {
        case .ready(let snapshot):
            return snapshot
        case .deferredWhileSourcesLoad:
            throw SyncError.snapshotPreparationDeferred
        case .sourcesUnavailable:
            throw SyncError.snapshotSourcesUnavailable
        case .failed:
            throw SyncError.snapshotEncodingFailed
        }
    }

    private static func requireRecoverySnapshot(
        _ preparation: ExperimentalCloudSnapshotPreparation
    ) throws -> ExperimentalCloudSnapshot {
        switch preparation {
        case .ready(let snapshot):
            return snapshot
        case .deferredWhileSourcesLoad:
            throw SyncError.snapshotPreparationDeferred
        case .sourcesUnavailable:
            throw SyncError.snapshotSourcesUnavailable
        case .failed:
            throw SyncError.restoreRecoveryPreparationFailed
        }
    }

    private static func reconcileSnapshot(provider: CloudSyncProvider, reason: String) async throws -> Date {

        try requireReconciliationRecoveryGateOpen()
        switch BackupManager.shared.backupDomainReadiness {
        case .ready:
            break
        case .loading:
            throw SyncError.snapshotPreparationDeferred
        case .unavailable:
            throw SyncError.snapshotSourcesUnavailable
        }
        prepareReconciliationIdentity(provider: provider)

        guard let metadata = try await remoteMetadata(provider: provider) else {
            try requireReconciliationRecoveryGateOpen()
            return try await writeLocalSnapshot(
                provider: provider,
                reason: reason,
                writePrecondition: .remoteMissing
            )
        }

        adoptLegacySnapshotBaselineIfThisDeviceWroteIt(metadata: metadata, provider: provider, reason: reason)

        let localSnapshot = try await requirePreparedSnapshot(
            BackupManager.shared.prepareExperimentalCloudSnapshot()
        )

        let localFootprint = protectedFootprint(localSnapshot.footprint, provider: provider)

        if hasUnseenRemoteSnapshot(metadata: metadata, provider: provider) {
            let remoteSnapshot = try await readRemoteSnapshot(provider: provider, knownMetadata: metadata)
            guard let decodedRemoteFootprint = BackupManager.shared.experimentalCloudSnapshotFootprint(from: remoteSnapshot.data) else {
                throw SyncError.snapshotInspectionFailed
            }
            let remoteFootprint = protectedFootprint(decodedRemoteFootprint, provider: provider)

            let refreshedSnapshot = try await requirePreparedSnapshot(
                BackupManager.shared.prepareExperimentalCloudSnapshot()
            )
            let refreshedLocalFootprint = protectedFootprint(refreshedSnapshot.footprint, provider: provider)

            switch ExperimentalCloudReconciliationPolicy.actionForUnseenRemote(
                local: refreshedLocalFootprint,
                remote: remoteFootprint,
                previous: lastSyncedFootprint(provider: provider)
            ) {
            case .concurrentConflict:
                throw SyncError.concurrentSnapshotConflict(
                    provider,
                    refreshedLocalFootprint.meaningfulRecordCount,
                    remoteFootprint.meaningfulRecordCount
                )
            case .remoteWouldReduceLocalData:

                throw SyncError.suspiciousRemoteReduction(
                    provider,
                    refreshedLocalFootprint.meaningfulRecordCount,
                    remoteFootprint.meaningfulRecordCount
                )
            case .restoreRemote:
                break
            }

            Logger.shared.log("Experimental cloud snapshot restoring verified newer remote provider=\(provider.rawValue) reason=\(reason)", type: "CloudSync")
            if !remoteFootprint.hasAnyMoreData(than: refreshedLocalFootprint),
               remoteFootprint.hasDifferentContent(than: refreshedLocalFootprint) {
                Logger.shared.log(
                    "Experimental cloud snapshot restore replaces this device's app settings provider=\(provider.rawValue) reason=\(reason)",
                    type: "CloudSync"
                )
            }
            try requireReconciliationRecoveryGateOpen()
            return try await restoreRemoteSnapshot(
                provider: provider,
                knownMetadata: metadata,
                preparedSnapshot: remoteSnapshot
            )
        }

        let reconcileBaseline = lastSyncedFootprint(provider: provider)
        Logger.shared.log(
            "CloudSync reconcile provider=\(provider.rawValue) reason=\(reason)"
                + " legacy=\(metadata.isLegacy)"
                + " baseline=\((reconcileBaseline?.contentDigest).map { String($0.prefix(8)) } ?? "nil")"
                + " local=\((localFootprint.contentDigest).map { String($0.prefix(8)) } ?? "nil")",
            type: "Plugin"
        )
        if !metadata.isLegacy,
           let previousFootprint = lastSyncedFootprint(provider: provider),
           !localFootprint.hasDifferentContent(than: previousFootprint) {
            try requireReconciliationRecoveryGateOpen()
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

        try requireReconciliationRecoveryGateOpen()
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
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync
                || scopedAccountGeneration(for: provider) != nil else {
            throw SyncError.restoreRecoveryPending
        }
        if #available(iOS 17.0, *),
           scopedAccountGeneration(for: provider) == nil,
           await MediaStateSyncManager.shared.isCanonicalStateUnavailableForSnapshotWrites {
            throw SyncError.canonicalStateUnavailable(provider)
        }
        let snapshot: ExperimentalCloudSnapshot
        if let preparedSnapshot {
            snapshot = preparedSnapshot
        } else {
            snapshot = try await requirePreparedSnapshot(
                BackupManager.shared.prepareExperimentalCloudSnapshot()
            )
        }
        let data = snapshot.data
        guard data.count <= maximumCloudSnapshotBytes else {
            throw BoundedURLSessionError.responseTooLarge(
                maximumBytes: maximumCloudSnapshotBytes
            )
        }
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync
                || scopedAccountGeneration(for: provider) != nil else {
            throw SyncError.restoreRecoveryPending
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
        let expectedAccountGeneration = provider.requiresAccountConnection
            ? UserDefaults.standard.integer(forKey: provider.accountGenerationKey)
            : nil
        prepareReconciliationIdentity(provider: provider)
        guard let metadata = try await remoteMetadata(provider: provider) else {
            throw SyncError.noSnapshot(provider)
        }
        let localSnapshot = try await requirePreparedSnapshot(
            BackupManager.shared.prepareExperimentalCloudSnapshot()
        )

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
            preparedSnapshot: remoteSnapshot,
            expectedAccountGeneration: expectedAccountGeneration
        )
    }

    private static func restoreRemoteSnapshot(
        provider: CloudSyncProvider,
        knownMetadata: RemoteSnapshotMetadata? = nil,
        preparedSnapshot: RemoteSnapshot? = nil,
        expectedAccountGeneration suppliedGeneration: Int? = nil,
        canonicalAccountBoundaryRecords: [String: MediaStateEnvelope]? = nil,
        pendingAccountResolution: PendingAccountResolution? = nil
    ) async throws -> Date {
        if pendingAccountResolution != nil {
            guard #available(iOS 17.0, *) else {

                throw SyncError.accountBoundaryRestoreRequiresIOS17(provider)
            }
        }
        let expectedAccountGeneration = suppliedGeneration ?? (
            provider.requiresAccountConnection
                ? UserDefaults.standard.integer(forKey: provider.accountGenerationKey)
                : nil
        )
        if let expectedAccountGeneration {
            try requireAccountGeneration(provider, expected: expectedAccountGeneration)
        }
        if let pendingAccountResolution {
            try requirePendingAccountResolution(
                provider: provider,
                matching: pendingAccountResolution
            )
        }
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

        if let expectedAccountGeneration {
            try requireAccountGeneration(provider, expected: expectedAccountGeneration)
        }
        if let pendingAccountResolution {
            try requirePendingAccountResolution(
                provider: provider,
                matching: pendingAccountResolution
            )
        }

        let accountBoundaryRecoveryContext = pendingAccountResolution.map {
            ExperimentalCloudRestoreBoundaryContext(
                providerRawValue: provider.rawValue,
                generation: $0.generation,
                pendingIdentity: $0.pendingIdentity,
                outgoingProfileIDs: ProfileManager.shared.profiles
                    .map(\.id)
                    .sorted { $0.uuidString < $1.uuidString }
            )
        }

        let rollbackSnapshot = try requireRecoverySnapshot(
            BackupManager.shared.prepareAccountBoundaryRecoverySnapshot()
        )
        guard BackupManager.shared.prepareExperimentalCloudRestoreRecovery(
            using: rollbackSnapshot,
            accountBoundaryContext: accountBoundaryRecoveryContext
        ) else {
            throw SyncError.restoreRecoveryPreparationFailed
        }

        let preservesCanonicalMediaState = ExperimentalCanonicalRestorePolicy
            .preservesCanonicalMediaState(
                transportIsAvailable: canonicalMediaStateTransportIsAvailable,
                crossesAccountBoundary: pendingAccountResolution != nil,
                canonicalBundleIsPresent: canonicalAccountBoundaryRecords != nil
            )

        func rollbackPreparedRestore() async -> Bool {
            await BackupManager.shared.rollbackPreparedExperimentalCloudRestoreRecovery()
        }

        do {
            if let expectedAccountGeneration {
                try requireAccountGeneration(provider, expected: expectedAccountGeneration)
            }
            if let pendingAccountResolution {
                try requirePendingAccountResolution(
                    provider: provider,
                    matching: pendingAccountResolution
                )
            }
        } catch {
            BackupManager.shared.completeExperimentalCloudRestoreRecovery()
            throw error
        }

        let usesCanonicalAccountBoundaryTransaction = canonicalAccountBoundaryRecords != nil
            && pendingAccountResolution != nil
            && canonicalMediaStateTransportIsAvailable
        if !usesCanonicalAccountBoundaryTransaction,
           let accountBoundaryRecoveryContext {
            TrackerManager.shared.beginTentativeAccountBoundaryCredentialPreservation(
                profileIDs: Set(accountBoundaryRecoveryContext.outgoingProfileIDs)
            )
        }
        let didRestore: Bool
        var restoredTrackerProfileIDs = Set<UUID>()
        if let canonicalAccountBoundaryRecords,
           let pendingAccountResolution,
           usesCanonicalAccountBoundaryTransaction,
           #available(iOS 17.0, *) {
            didRestore = await MediaStateSyncManager.shared
                .performConfirmedRemoteAccountBoundaryRestore(
                    with: canonicalAccountBoundaryRecords,
                    restore: {
                        guard let restoreResult = await BackupManager.shared.restoreExperimentalCloudSnapshot(
                            from: data,
                            preserveMediaStateForCloudKit: true
                        ) else { return nil }
                        do {
                            if let expectedAccountGeneration {
                                try requireAccountGeneration(
                                    provider,
                                    expected: expectedAccountGeneration
                                )
                            }
                            try requirePendingAccountResolution(
                                provider: provider,
                                matching: pendingAccountResolution
                            )
                            return restoreResult.authoritativeTrackerProfileIDs
                        } catch {
                            return nil
                        }
                    },
                    commit: { outgoingProfileIDs, restoredTrackerProfileIDs in
                        commitPendingAccountResolution(
                            provider: provider,
                            matching: pendingAccountResolution,
                            outgoingProfileIDs: outgoingProfileIDs,
                            restoredTrackerProfileIDs: restoredTrackerProfileIDs
                        )
                    }
                )
        } else if preservesCanonicalMediaState, #available(iOS 17.0, *) {
            var restoreResult: ExperimentalCloudRestoreResult?
            didRestore = await MediaStateSyncManager.shared.performLegacySnapshotRestorePreservingMediaState {
                restoreResult = await BackupManager.shared.restoreExperimentalCloudSnapshot(
                    from: data,
                    preserveMediaStateForCloudKit: true
                )
                return restoreResult != nil
            }
            restoredTrackerProfileIDs = restoreResult?.authoritativeTrackerProfileIDs ?? []
        } else if #available(iOS 17.0, *) {
            var restoreResult: ExperimentalCloudRestoreResult?
            didRestore = await MediaStateSyncManager.shared.performAuthoritativeSnapshotRestore {
                restoreResult = await BackupManager.shared.restoreExperimentalCloudSnapshot(
                    from: data,
                    preserveMediaStateForCloudKit: preservesCanonicalMediaState
                )
                return restoreResult != nil
            }
            restoredTrackerProfileIDs = restoreResult?.authoritativeTrackerProfileIDs ?? []
        } else {
            let restoreResult = await BackupManager.shared.restoreExperimentalCloudSnapshot(
                from: data,
                preserveMediaStateForCloudKit: preservesCanonicalMediaState
            )
            restoredTrackerProfileIDs = restoreResult?.authoritativeTrackerProfileIDs ?? []
            didRestore = restoreResult != nil
        }

        var committedAccountBoundary = usesCanonicalAccountBoundaryTransaction && didRestore
        if didRestore,
           !usesCanonicalAccountBoundaryTransaction,
           let pendingAccountResolution,
           let accountBoundaryRecoveryContext {
            do {
                try requirePendingAccountResolution(
                    provider: provider,
                    matching: pendingAccountResolution
                )
                let committingContext = ExperimentalCloudRestoreBoundaryContext(
                    providerRawValue: accountBoundaryRecoveryContext.providerRawValue,
                    generation: accountBoundaryRecoveryContext.generation,
                    pendingIdentity: accountBoundaryRecoveryContext.pendingIdentity,
                    outgoingProfileIDs: accountBoundaryRecoveryContext.outgoingProfileIDs,
                    restoredTrackerProfileIDs: restoredTrackerProfileIDs
                        .sorted { $0.uuidString < $1.uuidString }
                )
                guard BackupManager.shared.authorizeExperimentalCloudRestoreCommit(
                    context: committingContext
                ) else {
                    throw SyncError.restoreRecoveryPreparationFailed
                }
                committedAccountBoundary = true
            } catch {
                if await rollbackPreparedRestore() {
                    Logger.shared.log(
                        "Experimental cloud restore rolled local state back before legacy boundary authorization",
                        type: "CloudSync"
                    )
                }
                throw error
            }
        }
        let accountStillMatches: Bool
        if committedAccountBoundary {
            accountStillMatches = true
        } else {
            do {
                if let expectedAccountGeneration {
                    try requireAccountGeneration(provider, expected: expectedAccountGeneration)
                }
                accountStillMatches = true
            } catch {
                accountStillMatches = false
            }
        }
        guard didRestore, accountStillMatches else {
            if await rollbackPreparedRestore() {
                Logger.shared.log("Experimental cloud restore rolled local state back after an apply failure", type: "CloudSync")
            }
            if !accountStillMatches {
                throw SyncError.authenticationRequired(provider)
            }
            throw SyncError.snapshotRestoreFailed
        }

        let postRestoreSnapshot: ExperimentalCloudSnapshot?
        if canonicalAccountBoundaryRecords != nil {
            postRestoreSnapshot = nil
        } else {
            postRestoreSnapshot = await BackupManager.shared.createExperimentalCloudSnapshot()
        }
        do {
            if !committedAccountBoundary, let expectedAccountGeneration {
                try requireAccountGeneration(provider, expected: expectedAccountGeneration)
            }
        } catch {
            _ = await rollbackPreparedRestore()
            throw error
        }

        guard BackupManager.shared.completeExperimentalCloudRestoreRecovery() else {
            if !committedAccountBoundary {

                _ = await rollbackPreparedRestore()
            }

            throw SyncError.restoreRecoveryPending
        }
        markRemoteSnapshotSeen(
            provider: provider,
            fallbackDate: modifiedAt ?? Date(),
            revision: snapshot.revision
        )
        if let localSnapshot = postRestoreSnapshot {
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
            if let knownMetadata {
                return try await readICloudSnapshot(
                    fileName: knownMetadata.id ?? snapshotFileName
                )
            }
            let fetchedMetadata = try await iCloudMetadata()
            return try await readICloudSnapshot(
                fileName: fetchedMetadata?.id ?? snapshotFileName
            )
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
        let listing = try await googleDriveSnapshotFiles(fileName: fileName)
        guard listing.isComplete else {
            Logger.shared.log(
                "CloudSync: refused to treat a malformed Google Drive snapshot listing as absent authority",
                type: "Error"
            )
            throw SyncError.invalidResponse(.googleDrive)
        }
        let files = listing.files
        guard let file = files.first else { return nil }
        return RemoteSnapshotMetadata(
            id: file.id,
            modifiedAt: parseRemoteDate(file.modifiedTime),
            revision: file.md5Checksum,
            historicalIDs: isLegacy ? [] : files.map(\.id),
            isLegacy: isLegacy
        )
    }

    private struct GoogleDriveSnapshotFileListing {
        var files: [GoogleDriveFile]
        var isComplete: Bool
    }

    private static func googleDriveSnapshotFiles(
        fileName: String
    ) async throws -> GoogleDriveSnapshotFileListing {
        let accessToken = try await accessToken(for: .googleDrive)
        var files: [GoogleDriveFile] = []
        var seenFileIDs = Set<String>()
        var listingIsComplete = true
        var pageToken: String?
        var pagination = ExperimentalCloudPaginationGuard()
        repeat {
            guard pagination.beginPage(cursor: pageToken) else {
                throw SyncError.invalidResponse(.googleDrive)
            }
            guard var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files") else {
                throw SyncError.unavailable(.googleDrive)
            }
            var queryItems = [
                URLQueryItem(name: "spaces", value: "appDataFolder"),
                URLQueryItem(name: "pageSize", value: "100"),
                URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,modifiedTime,md5Checksum)"),
                URLQueryItem(name: "q", value: "name = '\(fileName)' and 'appDataFolder' in parents and trashed = false")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems
            guard let requestURL = components.url else {
                throw SyncError.unavailable(.googleDrive)
            }
            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let data = try await validatedData(for: request, provider: .googleDrive)
            let response = try JSONDecoder().decode(GoogleDriveListResponse.self, from: data)
            guard pagination.recordObjects(response.listedObjectCount, maximum: 1_000) else {
                throw SyncError.invalidResponse(.googleDrive)
            }
            if !ExperimentalGoogleDriveListingCompletenessPolicy.isComplete(
                listedObjectCount: response.listedObjectCount,
                recognizedCandidateCount: response.files.count
            ) {
                listingIsComplete = false
            }
            for file in response.files {
                guard seenFileIDs.insert(file.id).inserted else {
                    listingIsComplete = false
                    continue
                }
                files.append(file)
            }
            guard files.count <= 1_000 else {
                throw SyncError.invalidResponse(.googleDrive)
            }
            pageToken = response.nextPageToken
        } while pageToken != nil
        return GoogleDriveSnapshotFileListing(
            files: files,
            isComplete: listingIsComplete
        )
    }

    private static func writeGoogleDriveSnapshot(
        data: Data,
        precondition: RemoteWritePrecondition
    ) async throws -> RemoteSnapshotMetadata {
        let accessToken = try await accessToken(for: .googleDrive)
        let existing = try await googleDriveMetadata(
            fileName: snapshotFileName,
            isLegacy: false
        )
        guard remoteWritePrecondition(precondition, accepts: existing) else {
            throw SyncError.remoteChangedDuringSync(.googleDrive)
        }
        if case .remoteMatches(let expected) = precondition,
           !ExperimentalGoogleDriveSnapshotWritePolicy.matchesExpectedCandidates(
                existing?.historicalIDs ?? [],
                expected: expected.historicalIDs
           ) {
            throw SyncError.remoteChangedDuringSync(.googleDrive)
        }
        let expectedCandidateIDs = existing?.historicalIDs ?? []

        let boundary = "EclipseCloudSync-\(UUID().uuidString)"
        let metadata: [String: Any] = [
            "name": snapshotFileName,
            "parents": ["appDataFolder"]
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        let body = multipartBody(metadata: metadataData, fileData: data, boundary: boundary)

        guard var components = URLComponents(
            string: "https://www.googleapis.com/upload/drive/v3/files"
        ) else {
            throw SyncError.unavailable(.googleDrive)
        }
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id,modifiedTime,md5Checksum")
        ]
        guard let requestURL = components.url else {
            throw SyncError.unavailable(.googleDrive)
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let responseData = try await validatedData(for: request, provider: .googleDrive)
        let file = try JSONDecoder().decode(GoogleDriveFile.self, from: responseData)

        let postWriteMetadata = try await googleDriveMetadata(
            fileName: snapshotFileName,
            isLegacy: false
        )
        guard ExperimentalGoogleDriveSnapshotWritePolicy.confirmsUploadedCandidate(
            expected: expectedCandidateIDs,
            uploadedID: file.id,
            observed: postWriteMetadata?.historicalIDs ?? [],
            headID: postWriteMetadata?.id
        ) else {
            _ = await deleteGoogleDriveSnapshotFile(id: file.id, accessToken: accessToken)
            throw SyncError.remoteChangedDuringSync(.googleDrive)
        }

        let retainedCopies = CloudSyncTotalBudget.current.retainedSnapshotCopies(forSnapshotBytes: data.count)
        if let existing, existing.historicalIDs.count >= retainedCopies {
            var removed = 0
            var failed = 0
            for obsoleteID in existing.historicalIDs.dropFirst(max(0, retainedCopies - 1)) {
                guard let obsoleteURL = googleDriveFileURL(id: obsoleteID) else {
                    Logger.shared.log(
                        "CloudSync: skipped an obsolete Google Drive snapshot whose id is not a usable path segment",
                        type: "Error"
                    )
                    failed += 1
                    continue
                }
                var deleteRequest = URLRequest(url: obsoleteURL)
                deleteRequest.httpMethod = "DELETE"
                deleteRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                do {
                    _ = try await validatedData(
                        for: deleteRequest,
                        provider: .googleDrive,
                        allowNotFound: true,
                        maximumResponseBytes: maximumCloudControlResponseBytes
                    )
                    removed += 1
                } catch {
                    failed += 1
                }
            }
            Logger.shared.log(
                "CloudSync: pruned Google Drive snapshot copies retained=\(retainedCopies) removed=\(removed) failed=\(failed)",
                type: "CloudSync"
            )
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
        guard let requestURL = remoteIdentifierPathURL(
            prefix: "https://www.googleapis.com/drive/v3/files/",
            identifier: fileID,
            suffix: "?alt=media"
        ) else {
            throw SyncError.invalidResponse(.googleDrive)
        }

        var request = URLRequest(url: requestURL)
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

    private static func deleteGoogleDriveSnapshotFile(
        id: String,
        accessToken: String
    ) async -> Bool {
        guard let fileURL = googleDriveFileURL(id: id) else { return false }
        var request = URLRequest(url: fileURL)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            _ = try await validatedData(
                for: request,
                provider: .googleDrive,
                allowNotFound: true,
                maximumResponseBytes: maximumCloudControlResponseBytes
            )
            return true
        } catch {
            return false
        }
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
        guard let metadataURL = oneDriveSnapshotMetadataURL(fileName: fileName) else {
            throw SyncError.unavailable(.oneDrive)
        }
        var request = URLRequest(url: metadataURL)
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
        let revision = ExperimentalOneDriveWritePolicy.usableETag(item.eTag)
        return RemoteSnapshotMetadata(
            id: item.id,
            modifiedAt: parseRemoteDate(item.lastModifiedDateTime),
            revision: revision,
            isLegacy: isLegacy
        )
    }

    private static func writeOneDriveSnapshot(
        data: Data,
        precondition: RemoteWritePrecondition
    ) async throws -> RemoteSnapshotMetadata {
        let accessToken = try await accessToken(for: .oneDrive)
        guard let contentURL = oneDriveSnapshotContentURL() else {
            throw SyncError.unavailable(.oneDrive)
        }
        var request = URLRequest(url: contentURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch precondition {
        case .remoteMissing:
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .remoteMatches(let metadata):
            guard let revision = ExperimentalOneDriveWritePolicy.usableETag(
                metadata.revision
            ) else {
                throw SyncError.remoteChangedDuringSync(.oneDrive)
            }
            request.setValue(revision, forHTTPHeaderField: "If-Match")
        case .unconditional:
            break
        }
        request.httpBody = data

        let responseData: Data
        do {
            responseData = try await validatedData(for: request, provider: .oneDrive)
        } catch let SyncError.remoteRequestFailed(_, statusCode, _)
        where ExperimentalOneDriveWritePolicy.isConflictStatus(statusCode) {
            throw SyncError.remoteChangedDuringSync(.oneDrive)
        }
        let item = try JSONDecoder().decode(OneDriveItem.self, from: responseData)
        guard let revision = ExperimentalOneDriveWritePolicy.usableETag(item.eTag) else {
            throw SyncError.invalidResponse(.oneDrive)
        }
        return RemoteSnapshotMetadata(
            id: item.id,
            modifiedAt: parseRemoteDate(item.lastModifiedDateTime),
            revision: revision
        )
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
        if let itemID = metadata.id, let itemURL = oneDriveItemContentURL(itemID: itemID) {
            contentURL = itemURL
        } else if let snapshotURL = oneDriveSnapshotContentURL() {
            contentURL = snapshotURL
        } else {
            throw SyncError.unavailable(.oneDrive)
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

    private static func remoteIdentifierPathURL(
        prefix: String,
        identifier: String,
        suffix: String
    ) -> URL? {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@"
        )
        guard !identifier.isEmpty,
              let encoded = identifier.addingPercentEncoding(withAllowedCharacters: allowed),
              encoded == identifier else {
            return nil
        }
        return URL(string: prefix + encoded + suffix)
    }

    private static func googleDriveFileURL(id: String) -> URL? {
        remoteIdentifierPathURL(
            prefix: "https://www.googleapis.com/drive/v3/files/",
            identifier: id,
            suffix: ""
        )
    }

    private static func oneDriveItemContentURL(itemID: String) -> URL? {
        remoteIdentifierPathURL(
            prefix: "https://graph.microsoft.com/v1.0/me/drive/items/",
            identifier: itemID,
            suffix: "/content"
        )
    }

    private static func oneDriveSnapshotMetadataURL(fileName: String) -> URL? {
        URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(fileName)")
    }

    private static func oneDriveSnapshotContentURL() -> URL? {
        URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(snapshotFileName):/content")
    }

    static let mediaStateEnvelopeFileName = "EclipseMediaStateEnvelopes-v1.json"
    private static let googleDriveMediaStateGenerationPrefix = "EclipseMediaStateEnvelopes-v1-generation-"

    nonisolated static let maximumMediaStateEnvelopeBytes = 50_000_000

    private static let maximumGoogleDriveMediaStateCandidates = 256

    static func readMediaStateEnvelopeBundle(
        provider: CloudSyncProvider,
        accountContinuityToken: String?
    ) async throws -> (data: Data?, revision: MediaStateRemoteRevision?) {
        switch provider {
        case .iCloud:

            throw SyncError.unavailable(provider)
        case .googleDrive:
            return try await readGoogleDriveMediaStateCandidates(
                accountContinuityToken: accountContinuityToken
            )
        case .oneDrive:
            return try await readOneDriveAppRootFile(
                named: mediaStateEnvelopeFileName,
                accountContinuityToken: accountContinuityToken
            )
        }
    }

    static func writeMediaStateEnvelopeBundle(
        _ data: Data,
        provider: CloudSyncProvider,
        expecting revision: MediaStateRemoteRevision?,
        accountContinuityToken: String?,
        replacingRemoteAuthority: Bool = false
    ) async throws {
        guard data.count <= maximumMediaStateEnvelopeBytes else {
            throw SyncError.snapshotTooLarge(provider)
        }
        guard let bundle = try? MediaStateEnvelopeBundle.decoder().decode(
            MediaStateEnvelopeBundle.self,
            from: data
        ),
        bundle.schemaVersion >= 1,
        bundle.schemaVersion <= MediaStateEnvelope.schemaVersion,
        MediaStateEnvelopeValidator.rejectionReason(
            for: bundle.records,
            allowsSystemFields: false
        ) == nil else {
            Logger.shared.log(
                "MediaStateSync: refused to upload an invalid outgoing \(provider.rawValue) envelope bundle",
                type: "Error"
            )
            throw SyncError.invalidResponse(provider)
        }
        Logger.shared.log(
            "MediaStateSync: envelope bundle upload provider=\(provider.rawValue) bytes=\(data.count)",
            type: "CloudSync"
        )

        try requireAccountContinuity(provider, expected: accountContinuityToken)
        switch provider {
        case .iCloud:
            throw SyncError.unavailable(provider)
        case .googleDrive:
            try await writeGoogleDriveMediaStateCandidate(
                data,
                expecting: revision,
                accountContinuityToken: accountContinuityToken,
                replacingRemoteAuthority: replacingRemoteAuthority
            )
        case .oneDrive:
            try await writeOneDriveAppRootFile(
                data,
                named: mediaStateEnvelopeFileName,
                expecting: revision,
                accountContinuityToken: accountContinuityToken
            )
        }
    }

    private struct GoogleDriveMediaStateFileListing {
        var files: [GoogleDriveFile]
        var isComplete: Bool
    }

    private static func googleDriveMediaStateFiles(
        accountContinuityToken: String?
    ) async throws -> GoogleDriveMediaStateFileListing {
        let accessToken = try await accessToken(
            for: .googleDrive,
            accountContinuityToken: accountContinuityToken
        )
        var files: [GoogleDriveFile] = []
        var seenCandidateIDs = Set<String>()
        var listingIsComplete = true
        var pageToken: String?
        var pagination = ExperimentalCloudPaginationGuard()
        repeat {
            guard pagination.beginPage(cursor: pageToken) else {
                throw SyncError.invalidResponse(.googleDrive)
            }
            guard var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files") else {
                throw SyncError.unavailable(.googleDrive)
            }
            var queryItems = [
                URLQueryItem(name: "spaces", value: "appDataFolder"),
                URLQueryItem(name: "pageSize", value: "100"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,modifiedTime,md5Checksum)"),
                URLQueryItem(
                    name: "q",
                    value: "(name = '\(mediaStateEnvelopeFileName)' or name contains '\(googleDriveMediaStateGenerationPrefix)') and 'appDataFolder' in parents and trashed = false"
                )
            ]
            if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = queryItems
            guard let requestURL = components.url else {
                throw SyncError.unavailable(.googleDrive)
            }
            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let responseData = try await validatedData(
                for: request,
                provider: .googleDrive,
                maximumResponseBytes: maximumCloudControlResponseBytes,
                accountContinuityToken: accountContinuityToken
            )
            let response = try JSONDecoder().decode(GoogleDriveListResponse.self, from: responseData)
            guard pagination.recordObjects(response.listedObjectCount) else {
                throw SyncError.invalidResponse(.googleDrive)
            }
            let recognizedCandidates = response.files.filter { file in
                file.name == mediaStateEnvelopeFileName ||
                    file.name?.hasPrefix(googleDriveMediaStateGenerationPrefix) == true
            }
            if !ExperimentalGoogleDriveListingCompletenessPolicy.isComplete(
                listedObjectCount: response.listedObjectCount,
                recognizedCandidateCount: recognizedCandidates.count
            ) {
                listingIsComplete = false
            }
            for candidate in recognizedCandidates {
                guard seenCandidateIDs.insert(candidate.id).inserted else {
                    listingIsComplete = false
                    continue
                }
                files.append(candidate)
            }
            pageToken = response.nextPageToken
        } while pageToken != nil
        let sortedFiles = files.sorted { $0.id < $1.id }
        if sortedFiles.count > maximumGoogleDriveMediaStateCandidates {
            guard ExperimentalGoogleDriveListingCompletenessPolicy.permitsMutation(
                isComplete: listingIsComplete
            ) else {
                Logger.shared.log(
                    "MediaStateSync: refused Google Drive compaction because the candidate listing contained malformed or unknown entries",
                    type: "Error"
                )
                throw SyncError.invalidResponse(.googleDrive)
            }
            try await compactGoogleDriveMediaStateBatch(
                from: sortedFiles,
                accessToken: accessToken,
                accountContinuityToken: accountContinuityToken
            )
            throw MediaStateRemoteRevisionConflict()
        }
        return GoogleDriveMediaStateFileListing(
            files: sortedFiles,
            isComplete: listingIsComplete
        )
    }

    private static func compactGoogleDriveMediaStateBatch(
        from files: [GoogleDriveFile],
        accessToken: String,
        accountContinuityToken: String?
    ) async throws {
        let generations = files
            .filter { $0.name?.hasPrefix(googleDriveMediaStateGenerationPrefix) == true }
            .sorted { $0.id < $1.id }
        let legacyDuplicates = files
            .filter { $0.name == mediaStateEnvelopeFileName }
            .sorted { $0.id < $1.id }
            .dropFirst()
        var selected = Array(generations.prefix(128))
        if selected.count < 128 {
            selected.append(contentsOf: legacyDuplicates.prefix(128 - selected.count))
        }
        guard !selected.isEmpty else {
            throw SyncError.snapshotTooLarge(.googleDrive)
        }

        var merged: [String: MediaStateEnvelope] = [:]
        var retirable: [GoogleDriveFile] = []
        for file in selected {
            guard let requestURL = remoteIdentifierPathURL(
                prefix: "https://www.googleapis.com/drive/v3/files/",
                identifier: file.id,
                suffix: "?alt=media"
            ) else {
                Logger.shared.log(
                    "MediaStateSync: skipped compacting a Google Drive candidate whose id is not a usable path segment",
                    type: "Error"
                )
                continue
            }
            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let data: Data
            do {
                guard let downloaded = try await validatedData(
                    for: request,
                    provider: .googleDrive,
                    allowNotFound: true,
                    maximumResponseBytes: maximumMediaStateEnvelopeBytes,
                    accountContinuityToken: accountContinuityToken
                ) else {
                    throw MediaStateRemoteRevisionConflict()
                }
                data = downloaded
            } catch is BoundedURLSessionError {
                Logger.shared.log(
                    "MediaStateSync: retained oversized Google Drive candidate id=\(file.id) without compacting it",
                    type: "Error"
                )
                continue
            }

            guard !mediaStateBundleUsesUnsupportedFutureSchema(data) else {
                throw SyncError.invalidResponse(.googleDrive)
            }
            guard let bundle = try? MediaStateEnvelopeBundle.decoder().decode(
                MediaStateEnvelopeBundle.self,
                from: data
            ),
            bundle.schemaVersion >= 1,
            bundle.schemaVersion <= MediaStateEnvelope.schemaVersion else {
                Logger.shared.log(
                    "MediaStateSync: retained invalid Google Drive candidate id=\(file.id) without compacting it",
                    type: "Error"
                )
                continue
            }
            let usable = MediaStateEnvelopeValidator.structurallyValidRemoteRecords(
                bundle.records
            )
            let candidateIsComplete = usable.droppedRecordNames.isEmpty
                && usable.repairedRecordNames.isEmpty
            if !usable.droppedRecordNames.isEmpty {
                Logger.shared.log(
                    "MediaStateSync: dropped \(usable.droppedRecordNames.count) invalid records while compacting Google Drive candidate id=\(file.id)",
                    type: "Error"
                )
            }
            if !usable.repairedRecordNames.isEmpty {
                Logger.shared.log(
                    "MediaStateSync: retained Google Drive candidate id=\(file.id) after stripping invalid nested context from \(usable.repairedRecordNames.count) progress record(s)",
                    type: "Error"
                )
            }
            if let reason = MediaStateEnvelopeValidator.aggregateRejectionReason(
                for: usable.records,
                allowsSystemFields: false
            ) {
                Logger.shared.log(
                    "MediaStateSync: retained an unsummarizable Google Drive candidate id=\(file.id) (\(reason))",
                    type: "Error"
                )
                continue
            }
            if candidateIsComplete {
                for (name, envelope) in usable.records {
                    merged[name] = merged[name]?.merged(with: envelope) ?? envelope
                }
                retirable.append(file)
            }
        }

        // One replacement plus one deletion does not reduce the candidate
        // count. More importantly, an all-incomplete batch must be read-only:
        // repeatedly uploading summaries of salvage would grow the very set
        // this compactor is trying to bound.
        guard ExperimentalGoogleDriveMediaStateCompactionPolicy
            .canReplaceAndReduceCandidateSet(
                completeCandidateCount: retirable.count
            ) else {
            Logger.shared.log(
                "MediaStateSync: refused Google Drive compaction because fewer than two complete candidates could be retired; incomplete source files remain untouched",
                type: "Error"
            )
            throw SyncError.invalidResponse(.googleDrive)
        }
        let data = try MediaStateEnvelopeBundle.encoder().encode(
            MediaStateEnvelopeBundle(records: merged)
        )
        guard data.count <= maximumMediaStateEnvelopeBytes else {
            throw SyncError.snapshotTooLarge(.googleDrive)
        }
        try await uploadGoogleDriveMediaStateGeneration(
            data,
            accessToken: accessToken,
            accountContinuityToken: accountContinuityToken
        )

        for file in retirable {
            _ = await deleteGoogleDriveMediaStateFile(
                id: file.id,
                accessToken: accessToken,
                accountContinuityToken: accountContinuityToken
            )
        }
    }

    private static func uploadGoogleDriveMediaStateGeneration(
        _ data: Data,
        accessToken: String,
        accountContinuityToken: String?
    ) async throws {
        let boundary = "EclipseMediaState-\(UUID().uuidString)"
        let generationName = "\(googleDriveMediaStateGenerationPrefix)\(UUID().uuidString.lowercased()).json"
        let metadataData = try JSONSerialization.data(withJSONObject: [
            "name": generationName,
            "parents": ["appDataFolder"]
        ] as [String: Any])
        guard var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files") else {
            throw SyncError.unavailable(.googleDrive)
        }
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id")
        ]
        guard let requestURL = components.url else {
            throw SyncError.unavailable(.googleDrive)
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(metadata: metadataData, fileData: data, boundary: boundary)
        _ = try await validatedData(
            for: request,
            provider: .googleDrive,
            accountContinuityToken: accountContinuityToken
        )
    }

    private static func readGoogleDriveMediaStateCandidates(
        accountContinuityToken: String?
    ) async throws -> (data: Data?, revision: MediaStateRemoteRevision?) {
        let listing = try await googleDriveMediaStateFiles(
            accountContinuityToken: accountContinuityToken
        )
        let files = listing.files
        if files.isEmpty, listing.isComplete {
            return (nil, nil)
        }

        let accessToken = try await accessToken(
            for: .googleDrive,
            accountContinuityToken: accountContinuityToken
        )
        var merged: [String: MediaStateEnvelope] = [:]
        var observed: [MediaStateRemoteFileVersion] = []
        var isComplete = listing.isComplete
        for file in files {
            guard let requestURL = remoteIdentifierPathURL(
                prefix: "https://www.googleapis.com/drive/v3/files/",
                identifier: file.id,
                suffix: "?alt=media"
            ) else {
                observed.append(MediaStateRemoteFileVersion(fileID: file.id, token: file.md5Checksum))
                isComplete = false
                Logger.shared.log(
                    "MediaStateSync: skipped a Google Drive candidate whose id is not a usable path segment",
                    type: "Error"
                )
                continue
            }
            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let data: Data
            do {
                guard let downloaded = try await validatedData(
                    for: request,
                    provider: .googleDrive,
                    allowNotFound: true,
                    maximumResponseBytes: maximumMediaStateEnvelopeBytes,
                    accountContinuityToken: accountContinuityToken
                ) else {

                    throw MediaStateRemoteRevisionConflict()
                }
                data = downloaded
            } catch is MediaStateRemoteRevisionConflict {
                throw MediaStateRemoteRevisionConflict()
            } catch is BoundedURLSessionError {
                observed.append(MediaStateRemoteFileVersion(fileID: file.id, token: file.md5Checksum))
                isComplete = false
                Logger.shared.log(
                    "MediaStateSync: skipped an oversized Google Drive candidate id=\(file.id)",
                    type: "Error"
                )
                continue
            }
            if mediaStateBundleUsesUnsupportedFutureSchema(data) {
                throw SyncError.invalidResponse(.googleDrive)
            }
            let bundle: MediaStateEnvelopeBundle
            do {
                bundle = try MediaStateEnvelopeBundle.decoder().decode(
                    MediaStateEnvelopeBundle.self,
                    from: data
                )
                guard bundle.schemaVersion >= 1,
                      bundle.schemaVersion <= MediaStateEnvelope.schemaVersion else {
                    throw SyncError.invalidResponse(.googleDrive)
                }
            } catch {
                observed.append(MediaStateRemoteFileVersion(fileID: file.id, token: file.md5Checksum))
                isComplete = false
                Logger.shared.log(
                    "MediaStateSync: skipped an invalid Google Drive candidate id=\(file.id)",
                    type: "Error"
                )
                continue
            }
            let usable = MediaStateEnvelopeValidator.structurallyValidRemoteRecords(
                bundle.records
            )
            if !usable.droppedRecordNames.isEmpty {
                isComplete = false
                Logger.shared.log(
                    "MediaStateSync: dropped \(usable.droppedRecordNames.count) invalid records from Google Drive candidate id=\(file.id)",
                    type: "Error"
                )
            }
            if !usable.repairedRecordNames.isEmpty {
                isComplete = false
                Logger.shared.log(
                    "MediaStateSync: stripped invalid nested playback context from \(usable.repairedRecordNames.count) Google Drive progress record(s) while preserving their progress",
                    type: "Error"
                )
            }
            if let reason = MediaStateEnvelopeValidator.aggregateRejectionReason(
                for: usable.records,
                allowsSystemFields: false
            ) {
                observed.append(
                    MediaStateRemoteFileVersion(fileID: file.id, token: file.md5Checksum)
                )
                Logger.shared.log(
                    "MediaStateSync: skipped an unreadable Google Drive candidate id=\(file.id) (\(reason))",
                    type: "Error"
                )
                isComplete = false
                continue
            }
            for (name, envelope) in usable.records {
                merged[name] = merged[name]?.merged(with: envelope) ?? envelope
            }
            observed.append(MediaStateRemoteFileVersion(fileID: file.id, token: file.md5Checksum))
        }

        let bundleData = try MediaStateEnvelopeBundle.encoder().encode(
            MediaStateEnvelopeBundle(records: merged)
        )
        guard bundleData.count <= maximumMediaStateEnvelopeBytes else {
            throw SyncError.snapshotTooLarge(.googleDrive)
        }
        return (
            bundleData,
            MediaStateRemoteRevision(
                fileID: nil,
                token: googleDriveMediaStateRevisionToken(observed: observed),
                observedFiles: observed,
                isComplete: isComplete
            )
        )
    }

    private static func googleDriveMediaStateRevisionToken(
        observed: [MediaStateRemoteFileVersion]
    ) -> String {
        observed
            .map { "\($0.fileID):\($0.token ?? "")" }
            .joined(separator: "|")
    }

    private static func mediaStateBundleUsesUnsupportedFutureSchema(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["schemaVersion"] as? NSNumber else {
            return false
        }
        return number.intValue > MediaStateEnvelope.schemaVersion
    }

    private struct GoogleDriveAppDataListing {
        var files: [GoogleDriveFile]
        var listedObjectCount: Int
        var isComplete: Bool
    }

    private static func googleDriveAppDataFiles() async throws -> GoogleDriveAppDataListing {
        let accessToken = try await accessToken(for: .googleDrive)
        var files: [GoogleDriveFile] = []
        var seenFileIDs = Set<String>()
        var listingIsComplete = true
        var pageToken: String?
        var pagination = ExperimentalCloudPaginationGuard()
        repeat {
            guard pagination.beginPage(cursor: pageToken) else {
                throw SyncError.invalidResponse(.googleDrive)
            }
            guard var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files") else {
                throw SyncError.unavailable(.googleDrive)
            }
            var queryItems = [
                URLQueryItem(name: "spaces", value: "appDataFolder"),
                URLQueryItem(name: "pageSize", value: "100"),
                URLQueryItem(
                    name: "fields",
                    value: "nextPageToken,files(id,name,modifiedTime,size,quotaBytesUsed)"
                )
            ]
            if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = queryItems
            guard let requestURL = components.url else {
                throw SyncError.unavailable(.googleDrive)
            }
            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            guard let responseData = try await validatedData(
                for: request,
                provider: .googleDrive,
                allowNotFound: false,
                maximumResponseBytes: maximumCloudControlResponseBytes,
                affectsProviderCooldown: false
            ) else {
                throw SyncError.invalidResponse(.googleDrive)
            }
            let response = try JSONDecoder().decode(GoogleDriveListResponse.self, from: responseData)
            guard pagination.recordObjects(response.listedObjectCount) else {
                throw SyncError.invalidResponse(.googleDrive)
            }
            if !ExperimentalGoogleDriveListingCompletenessPolicy.isComplete(
                listedObjectCount: response.listedObjectCount,
                recognizedCandidateCount: response.files.count
            ) {
                listingIsComplete = false
            }
            for file in response.files {
                guard seenFileIDs.insert(file.id).inserted else {
                    listingIsComplete = false
                    continue
                }
                files.append(file)
            }
            pageToken = response.nextPageToken
        } while pageToken != nil
        return GoogleDriveAppDataListing(
            files: files,
            listedObjectCount: pagination.objectCount,
            isComplete: listingIsComplete
        )
    }

    private static func googleDriveUsage() async throws -> CloudSyncRemoteUsage {
        let listing = try await googleDriveAppDataFiles()
        var total: Int64 = 0
        var complete = listing.isComplete
        for file in listing.files {
            guard let byteCount = file.byteCount,
                  let next = ExperimentalCloudPaginationGuard.addingNonnegativeUsage(
                    byteCount,
                    to: total
                  ) else {
                complete = false
                continue
            }
            total = next
        }
        return CloudSyncRemoteUsage(
            byteCount: total,
            objectCount: listing.listedObjectCount,
            isComplete: complete
        )
    }

    private static func oneDriveUsage() async throws -> CloudSyncRemoteUsage {
        var total: Int64 = 0
        var objects = 0
        var complete = true
        var nextURL = URL(
            string: "https://graph.microsoft.com/v1.0/me/drive/special/approot/children?$select=id,name,size,lastModifiedDateTime"
        )
        var pagination = ExperimentalCloudPaginationGuard()
        while let requestURL = nextURL {
            guard pagination.beginPage(cursor: requestURL.absoluteString) else {
                throw SyncError.invalidResponse(.oneDrive)
            }
            let accessToken = try await accessToken(for: .oneDrive)
            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            guard let responseData = try await validatedData(
                for: request,
                provider: .oneDrive,
                allowNotFound: false,
                maximumResponseBytes: maximumCloudControlResponseBytes,
                affectsProviderCooldown: false
            ) else {
                throw SyncError.invalidResponse(.oneDrive)
            }
            let response = try JSONDecoder().decode(OneDriveChildrenResponse.self, from: responseData)
            guard pagination.recordObjects(response.value.count) else {
                throw SyncError.invalidResponse(.oneDrive)
            }
            for item in response.value {
                guard let size = item.size,
                      let next = ExperimentalCloudPaginationGuard.addingNonnegativeUsage(
                        size,
                        to: total
                      ) else {
                    complete = false
                    continue
                }
                total = next
            }
            objects = pagination.objectCount
            if response.nextLink == nil {
                nextURL = nil
            } else {
                guard let validatedNextURL = ExperimentalCloudPaginationGuard
                    .exactOneDriveNextURL(response.nextLink) else {
                    throw SyncError.invalidResponse(.oneDrive)
                }
                nextURL = validatedNextURL
            }
        }
        return CloudSyncRemoteUsage(byteCount: total, objectCount: objects, isComplete: complete)
    }

    private nonisolated static func iCloudUsage() throws -> CloudSyncRemoteUsage {
        var total: Int64 = 0
        var objects = 0
        var complete = true
        for fileName in [eclipseCloudSnapshotFileName, eclipseLegacyCloudSnapshotFileName] {
            let url = try iCloudSnapshotURL(fileName: fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            objects += 1
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize,
               let next = ExperimentalCloudPaginationGuard.addingNonnegativeUsage(
                   Int64(size),
                   to: total
               ) {
                total = next
            } else {
                complete = false
            }
        }
        return CloudSyncRemoteUsage(byteCount: total, objectCount: objects, isComplete: complete)
    }

    private static func deleteAllGoogleDriveData() async throws -> (removed: Int, failed: Int) {
        var removed = 0
        var failed = 0
        for _ in 0..<3 {
            let listing = try await googleDriveAppDataFiles()
            let identifiers = listing.files.map(\.id)
            let unknownObjects = max(0, listing.listedObjectCount - identifiers.count)
            guard !identifiers.isEmpty else {
                failed = unknownObjects
                break
            }
            let accessToken = try await accessToken(for: .googleDrive)
            var failedThisPass = unknownObjects
            for identifier in identifiers {
                if await deleteGoogleDriveMediaStateFile(
                    id: identifier,
                    accessToken: accessToken,
                    accountContinuityToken: nil
                ) {
                    removed += 1
                } else {
                    failedThisPass += 1
                }
            }
            failed = failedThisPass
            if failedThisPass == identifiers.count + unknownObjects { break }
        }
        return (removed, failed)
    }

    private static func deleteAllOneDriveData() async throws -> (removed: Int, failed: Int) {
        var removed = 0
        var failed = 0
        for fileName in [snapshotFileName, legacySnapshotFileName, mediaStateEnvelopeFileName] {
            guard let url = oneDriveSnapshotMetadataURL(fileName: fileName) else {
                failed += 1
                continue
            }
            let accessToken = try await accessToken(for: .oneDrive)
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            do {
                _ = try await validatedData(
                    for: request,
                    provider: .oneDrive,
                    allowNotFound: true,
                    maximumResponseBytes: maximumCloudControlResponseBytes
                )
                removed += 1
            } catch {
                failed += 1
            }
        }
        return (removed, failed)
    }

    private nonisolated static func deleteAllICloudData() throws -> (removed: Int, failed: Int) {
        var removed = 0
        var failed = 0
        for fileName in [eclipseCloudSnapshotFileName, eclipseLegacyCloudSnapshotFileName] {
            do {
                let url = try iCloudSnapshotURL(fileName: fileName)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try coordinatedICloudWrite(at: url) { coordinatedURL in
                    try FileManager.default.removeItem(at: coordinatedURL)
                }
                removed += 1
            } catch {
                failed += 1
            }
        }
        return (removed, failed)
    }

    private static func deleteGoogleDriveMediaStateFile(
        id: String,
        accessToken: String,
        accountContinuityToken: String?
    ) async -> Bool {
        guard let fileURL = googleDriveFileURL(id: id) else {
            Logger.shared.log(
                "MediaStateSync: could not retire a Google Drive candidate whose id is not a usable path segment",
                type: "Error"
            )
            return false
        }
        var request = URLRequest(url: fileURL)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            _ = try await validatedData(
                for: request,
                provider: .googleDrive,
                allowNotFound: true,
                maximumResponseBytes: maximumCloudControlResponseBytes,
                accountContinuityToken: accountContinuityToken
            )
            return true
        } catch {
            Logger.shared.log(
                "MediaStateSync: could not retire invalid Google Drive candidate id=\(id)",
                type: "Error"
            )
            return false
        }
    }

    private static func writeGoogleDriveMediaStateCandidate(
        _ data: Data,
        expecting revision: MediaStateRemoteRevision?,
        accountContinuityToken: String?,
        replacingRemoteAuthority: Bool
    ) async throws {
        guard revision?.isComplete != false else {
            Logger.shared.log(
                "MediaStateSync: refused to replace incomplete Google Drive authority",
                type: "Error"
            )
            throw MediaStateRemoteRevisionConflict()
        }
        let currentListing = try await googleDriveMediaStateFiles(
            accountContinuityToken: accountContinuityToken
        )
        guard ExperimentalGoogleDriveListingCompletenessPolicy.permitsMutation(
            isComplete: currentListing.isComplete
        ) else {
            Logger.shared.log(
                "MediaStateSync: refused to mutate a Google Drive candidate listing containing malformed or unknown entries",
                type: "Error"
            )
            throw MediaStateRemoteRevisionConflict()
        }
        let currentFiles = currentListing.files
        let currentVersions = currentFiles.map {
            MediaStateRemoteFileVersion(fileID: $0.id, token: $0.md5Checksum)
        }
        let expectedVersions = revision?.observedFiles ?? []
        guard currentVersions == expectedVersions,
              (revision != nil || currentVersions.isEmpty) else {
            throw MediaStateRemoteRevisionConflict()
        }

        let accessToken = try await accessToken(
            for: .googleDrive,
            accountContinuityToken: accountContinuityToken
        )
        let boundary = "EclipseMediaState-\(UUID().uuidString)"
        let generationName = "\(googleDriveMediaStateGenerationPrefix)\(UUID().uuidString.lowercased()).json"
        let metadataData = try JSONSerialization.data(withJSONObject: [
            "name": generationName,
            "parents": ["appDataFolder"]
        ] as [String: Any])
        guard var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files") else {
            throw SyncError.unavailable(.googleDrive)
        }
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id")
        ]
        guard let requestURL = components.url else {
            throw SyncError.unavailable(.googleDrive)
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(metadata: metadataData, fileData: data, boundary: boundary)
        let uploadResponse = try await validatedData(
            for: request,
            provider: .googleDrive,
            accountContinuityToken: accountContinuityToken
        )
        let uploadedFile = try JSONDecoder().decode(GoogleDriveFile.self, from: uploadResponse)

        let retirementIDs: Set<String>
        if replacingRemoteAuthority {

            retirementIDs = Set(currentFiles.map(\.id))
        } else {
            retirementIDs = Set(currentFiles.compactMap { file in
                file.name?.hasPrefix(googleDriveMediaStateGenerationPrefix) == true
                    ? file.id
                    : nil
            })
        }
        var cleanupFailed = false
        for version in expectedVersions where retirementIDs.contains(version.fileID) {
            if !(await deleteGoogleDriveMediaStateFile(
                id: version.fileID,
                accessToken: accessToken,
                accountContinuityToken: accountContinuityToken
            )) {
                cleanupFailed = true
            }
        }
        if replacingRemoteAuthority {
            let remainingListing = try await googleDriveMediaStateFiles(
                accountContinuityToken: accountContinuityToken
            )
            guard !cleanupFailed,
                  remainingListing.isComplete,
                  remainingListing.files.allSatisfy({ $0.id == uploadedFile.id }) else {

                throw MediaStateRemoteRevisionConflict()
            }
        }
    }

    private static func oneDriveAppRootContentURL(fileName: String) -> URL? {
        URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(fileName):/content")
    }

    private static func oneDriveAppRootFileRevision(
        named fileName: String,
        accountContinuityToken: String?
    ) async throws -> MediaStateRemoteRevision? {
        let accessToken = try await accessToken(
            for: .oneDrive,
            accountContinuityToken: accountContinuityToken
        )
        guard let metadataURL = URL(
            string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(fileName)"
        ) else {
            throw SyncError.unavailable(.oneDrive)
        }
        var request = URLRequest(url: metadataURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let data = try await validatedData(
            for: request,
            provider: .oneDrive,
            allowNotFound: true,
            maximumResponseBytes: maximumCloudControlResponseBytes,
            accountContinuityToken: accountContinuityToken
        ) else {
            return nil
        }
        let item = try JSONDecoder().decode(OneDriveItem.self, from: data)
        let revisionToken = ExperimentalOneDriveWritePolicy.usableETag(item.eTag)
        let fileID = item.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaStateRemoteRevision(
            fileID: fileID?.isEmpty == false ? fileID : nil,
            token: revisionToken,
            isComplete: fileID?.isEmpty == false && revisionToken?.isEmpty == false
        )
    }

    private static func readOneDriveAppRootFile(
        named fileName: String,
        accountContinuityToken: String?
    ) async throws -> (data: Data?, revision: MediaStateRemoteRevision?) {
        guard var revision = try await oneDriveAppRootFileRevision(
            named: fileName,
            accountContinuityToken: accountContinuityToken
        ) else {
            return (nil, nil)
        }
        let accessToken = try await accessToken(
            for: .oneDrive,
            accountContinuityToken: accountContinuityToken
        )
        let contentURL: URL
        if let itemID = revision.fileID, let itemURL = oneDriveItemContentURL(itemID: itemID) {
            contentURL = itemURL
        } else if let appRootURL = oneDriveAppRootContentURL(fileName: fileName) {
            contentURL = appRootURL
        } else {
            throw SyncError.unavailable(.oneDrive)
        }
        var request = URLRequest(url: contentURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data = try await validatedData(
            for: request,
            provider: .oneDrive,
            allowNotFound: true,
            maximumResponseBytes: maximumMediaStateEnvelopeBytes,
            accountContinuityToken: accountContinuityToken
        )
        revision.isComplete = ExperimentalOneDriveBundleCompletenessPolicy.isComplete(
            metadataIsComplete: revision.isComplete,
            contentByteCount: data?.count
        )
        return (data, revision)
    }

    private static func writeOneDriveAppRootFile(
        _ data: Data,
        named fileName: String,
        expecting revision: MediaStateRemoteRevision?,
        accountContinuityToken: String?
    ) async throws {
        guard revision?.isComplete != false else {
            throw MediaStateRemoteRevisionConflict()
        }
        let accessToken = try await accessToken(
            for: .oneDrive,
            accountContinuityToken: accountContinuityToken
        )
        guard let contentURL = oneDriveAppRootContentURL(fileName: fileName) else {
            throw SyncError.unavailable(.oneDrive)
        }
        var request = URLRequest(url: contentURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = revision?.token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "if-match")
        } else if revision == nil {
            request.setValue("*", forHTTPHeaderField: "if-none-match")
        } else {

            Logger.shared.log(
                "MediaStateSync: OneDrive returned no eTag for \(fileName); refused to upload without a precondition",
                type: "Error"
            )
            throw MediaStateRemoteRevisionConflict()
        }
        request.httpBody = data
        do {
            _ = try await validatedData(
                for: request,
                provider: .oneDrive,
                accountContinuityToken: accountContinuityToken
            )
        } catch SyncError.remoteRequestFailed(_, 412, _),
                SyncError.remoteRequestFailed(_, 409, _),
                SyncError.remoteRequestFailed(_, 428, _) {
            throw MediaStateRemoteRevisionConflict()
        }
    }

    private static func hasUnseenRemoteSnapshot(metadata: RemoteSnapshotMetadata, provider: CloudSyncProvider) -> Bool {
        if let revision = metadata.revision, !revision.isEmpty {
            let lastRevision = UserDefaults.standard.string(forKey: provider.lastSeenRemoteRevisionKey)
            if lastRevision != revision { return true }
        }
        guard let modificationDate = metadata.modifiedAt else {
            // Missing revision and date is not evidence that this remote copy
            // was seen. Treat it as unseen and refuse a blind overwrite.
            return true
        }
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
            if expected.revision != nil || actualMetadata.revision != nil {
                guard let expectedRevision = expected.revision,
                      !expectedRevision.isEmpty,
                      let actualRevision = actualMetadata.revision,
                      !actualRevision.isEmpty else { return false }
                return expectedRevision == actualRevision
            }
            guard let expectedDate = expected.modifiedAt,
                  let actualDate = actualMetadata.modifiedAt else {
                return false
            }
            return abs(expectedDate.timeIntervalSince(actualDate)) < 0.001
        }
    }

    private static func adoptLegacySnapshotBaselineIfThisDeviceWroteIt(
        metadata: RemoteSnapshotMetadata,
        provider: CloudSyncProvider,
        reason: String
    ) {
        guard metadata.isLegacy else { return }
        let defaults = UserDefaults.standard
        guard defaults.data(forKey: provider.lastSyncedFootprintKey) == nil,
              defaults.string(forKey: provider.lastSeenRemoteRevisionKey) == nil else {
            return
        }
        let lastSeen = defaults.double(forKey: provider.lastSeenRemoteModificationKey)
        guard lastSeen > 0,
              let remoteModifiedAt = metadata.modifiedAt,
              remoteModifiedAt.timeIntervalSince1970 <= lastSeen + 1 else {
            return
        }
        markRemoteSnapshotSeen(
            provider: provider,
            fallbackDate: metadata.modifiedAt ?? Date(),
            revision: metadata.revision
        )
        Logger.shared.log(
            "Experimental cloud sync adopted this device's pre-upgrade snapshot as the baseline provider=\(provider.rawValue) reason=\(reason)",
            type: "CloudSync"
        )
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

        if canonicalMediaStateTransportIsAvailable {
            return footprint.excludingCloudKitMediaState()
        }

        return footprint
    }

    static var canonicalMediaStateTransportIsAvailable: Bool {
        guard #available(iOS 17.0, *) else { return false }
        if MediaStateSyncBootstrap.hasCloudKitEntitlement,
           UserDefaults.standard.bool(forKey: ExperimentalFeatureState.iCloudSyncEnabledKey),
           !MediaStateCloudKitSuspension.isSuspended {
            return true
        }
        guard ExperimentalFeatureState.isEnabledAtLaunch else { return false }
        return CloudSyncProvider.allCases.contains { provider in
            provider != .iCloud
                && UserDefaults.standard.bool(forKey: provider.syncEnabledKey)
        }
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

    enum CloudAccountContinuity {

        case confirmed

        case changed

        case unknown

        case deferredVerification

        var requiresUserDecision: Bool { self == .changed || self == .unknown }
    }

    private struct OAuthReconciliationIdentityResult {
        let continuity: CloudAccountContinuity

        let freshlyVerifiedIdentity: String?
    }

    private static func prepareOAuthReconciliationIdentity(
        provider: CloudSyncProvider,
        expectedGeneration: Int
    ) async -> OAuthReconciliationIdentityResult {
        guard provider.requiresAccountConnection else {
            return OAuthReconciliationIdentityResult(
                continuity: .confirmed,
                freshlyVerifiedIdentity: nil
            )
        }

        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: provider.accountGenerationKey) == expectedGeneration else {
            return OAuthReconciliationIdentityResult(
                continuity: .unknown,
                freshlyVerifiedIdentity: nil
            )
        }
        let previousIdentity = defaults.string(forKey: provider.accountIdentityKey)
        let previousIdentityWasUnresolved = defaults.bool(
            forKey: provider.accountIdentityUnresolvedKey
        )

        func quarantine(_ reason: String) {
            defaults.removeObject(forKey: provider.lastSeenRemoteModificationKey)
            defaults.removeObject(forKey: provider.lastSyncedFootprintKey)
            defaults.removeObject(forKey: provider.lastSeenRemoteRevisionKey)
            defaults.set(true, forKey: provider.accountBoundaryPendingKey)
            Logger.shared.log(
                "Experimental cloud sync paused for \(provider.displayName): \(reason)",
                type: "CloudSync"
            )
        }

        let canDeferIdentityVerification = !previousIdentityWasUnresolved

        let currentAccount: CloudAccountIdentity?
        do {
            currentAccount = try await fetchAccountIdentity(provider: provider)
        } catch {

            guard defaults.integer(forKey: provider.accountGenerationKey) == expectedGeneration else {
                return OAuthReconciliationIdentityResult(
                    continuity: .unknown,
                    freshlyVerifiedIdentity: nil
                )
            }

            if canDeferIdentityVerification {
                Logger.shared.log(
                    "Experimental cloud sync deferred \(provider.displayName) identity verification (\(error.localizedDescription))",
                    type: "CloudSync"
                )
                return OAuthReconciliationIdentityResult(
                    continuity: .deferredVerification,
                    freshlyVerifiedIdentity: nil
                )
            }

            defaults.removeObject(forKey: provider.pendingAccountIdentityKey)
            quarantine("the account could not be identified (\(error.localizedDescription))")
            return OAuthReconciliationIdentityResult(
                continuity: .unknown,
                freshlyVerifiedIdentity: nil
            )
        }

        guard defaults.integer(forKey: provider.accountGenerationKey) == expectedGeneration else {
            return OAuthReconciliationIdentityResult(
                continuity: .unknown,
                freshlyVerifiedIdentity: nil
            )
        }

        let currentIdentity = currentAccount?.stableIdentifier
        storeAccountEmail(currentAccount?.email, for: provider)

        guard let currentIdentity, !currentIdentity.isEmpty else {
            if canDeferIdentityVerification {
                Logger.shared.log(
                    "Experimental cloud sync deferred \(provider.displayName) identity verification (no account identifier returned)",
                    type: "CloudSync"
                )
                return OAuthReconciliationIdentityResult(
                    continuity: .deferredVerification,
                    freshlyVerifiedIdentity: nil
                )
            }
            defaults.removeObject(forKey: provider.pendingAccountIdentityKey)
            quarantine("the provider returned no account identifier")
            return OAuthReconciliationIdentityResult(
                continuity: .unknown,
                freshlyVerifiedIdentity: nil
            )
        }

        if previousIdentityWasUnresolved {
            guard previousIdentity == nil || previousIdentity != currentIdentity else {
                defaults.set(currentIdentity, forKey: provider.accountIdentityKey)
                defaults.removeObject(forKey: provider.accountIdentityUnresolvedKey)
                defaults.removeObject(forKey: provider.pendingAccountIdentityKey)
                defaults.removeObject(forKey: provider.accountBoundaryPendingKey)
                return OAuthReconciliationIdentityResult(
                    continuity: .confirmed,
                    freshlyVerifiedIdentity: currentIdentity
                )
            }
            defaults.set(currentIdentity, forKey: provider.pendingAccountIdentityKey)
            quarantine("the previously accepted account could not be identified, so continuity cannot be proven")
            return OAuthReconciliationIdentityResult(
                continuity: .unknown,
                freshlyVerifiedIdentity: currentIdentity
            )
        }

        guard let previousIdentity else {
            defaults.set(currentIdentity, forKey: provider.accountIdentityKey)
            defaults.removeObject(forKey: provider.accountIdentityUnresolvedKey)
            defaults.removeObject(forKey: provider.pendingAccountIdentityKey)
            defaults.removeObject(forKey: provider.accountBoundaryPendingKey)
            return OAuthReconciliationIdentityResult(
                continuity: .confirmed,
                freshlyVerifiedIdentity: currentIdentity
            )
        }
        guard previousIdentity != currentIdentity else {
            defaults.set(currentIdentity, forKey: provider.accountIdentityKey)
            defaults.removeObject(forKey: provider.accountIdentityUnresolvedKey)
            defaults.removeObject(forKey: provider.pendingAccountIdentityKey)
            defaults.removeObject(forKey: provider.accountBoundaryPendingKey)
            return OAuthReconciliationIdentityResult(
                continuity: .confirmed,
                freshlyVerifiedIdentity: currentIdentity
            )
        }

        defaults.set(currentIdentity, forKey: provider.pendingAccountIdentityKey)
        quarantine("it is a different account than the one this device last synced with")
        return OAuthReconciliationIdentityResult(
            continuity: .changed,
            freshlyVerifiedIdentity: currentIdentity
        )
    }

    private struct PendingAccountResolution {
        let generation: Int
        let pendingIdentity: String?
    }

    private struct AccountBoundaryResolverRequestScope: Sendable {
        let providerRawValue: String
        let generation: Int
    }

    @TaskLocal
    private static var accountBoundaryResolverRequestScope:
        AccountBoundaryResolverRequestScope?

    private static func scopedAccountGeneration(
        for provider: CloudSyncProvider
    ) -> Int? {
        guard let scope = accountBoundaryResolverRequestScope,
              scope.providerRawValue == provider.rawValue else {
            return nil
        }
        return scope.generation
    }

    private static func pendingAccountResolution(
        provider: CloudSyncProvider
    ) -> PendingAccountResolution {
        let defaults = UserDefaults.standard
        return PendingAccountResolution(
            generation: defaults.integer(forKey: provider.accountGenerationKey),
            pendingIdentity: defaults.string(forKey: provider.pendingAccountIdentityKey)
        )
    }

    private static func requirePendingAccountResolution(
        provider: CloudSyncProvider,
        matching resolution: PendingAccountResolution
    ) throws {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: provider.accountBoundaryPendingKey),
              defaults.integer(forKey: provider.accountGenerationKey) == resolution.generation,
              defaults.string(forKey: provider.pendingAccountIdentityKey) == resolution.pendingIdentity else {
            throw SyncError.authenticationRequired(provider)
        }
    }

    private static func readMediaStateForPendingAccountBoundary(
        provider: CloudSyncProvider,
        matching resolution: PendingAccountResolution
    ) async throws -> (records: [String: MediaStateEnvelope]?, revision: MediaStateRemoteRevision?) {
        try requirePendingAccountResolution(provider: provider, matching: resolution)
        guard canonicalMediaStateTransportIsAvailable, #available(iOS 17.0, *) else {
            return (nil, nil)
        }
        let fetched = try await readMediaStateEnvelopeBundle(
            provider: provider,

            accountContinuityToken: nil
        )
        try requirePendingAccountResolution(provider: provider, matching: resolution)
        guard ExperimentalCanonicalRemoteAuthorityPolicy
            .permitsAccountBoundaryUse(fetched.revision) else {
            Logger.shared.log(
                "MediaStateSync: refused to use incomplete remote salvage as account-boundary authority for \(provider.rawValue)",
                type: "Error"
            )
            throw SyncError.restoreRecoveryPending
        }
        let data: Data
        switch ExperimentalCanonicalMediaStateBundlePresence.classify(fetched.data) {
        case .absent:
            return (nil, fetched.revision)
        case .invalidEmpty:
            throw SyncError.invalidResponse(provider)
        case .present(let presentData):
            data = presentData
        }
        let bundle = try MediaStateEnvelopeBundle.decoder().decode(
            MediaStateEnvelopeBundle.self,
            from: data
        )
        guard bundle.schemaVersion >= 1,
              bundle.schemaVersion <= MediaStateEnvelope.schemaVersion,
              MediaStateEnvelopeValidator.rejectionReason(
                for: bundle.records,
                allowsSystemFields: false
              ) == nil else {
            throw SyncError.invalidResponse(provider)
        }
        return (bundle.records, fetched.revision)
    }

    private static func finishAuthorizedKeepLocalReplacement(
        replay: ExperimentalCloudKeepLocalReplay,
        provider: CloudSyncProvider,
        resolution: PendingAccountResolution
    ) async throws -> Date {
        let context = replay.context
        guard context.providerRawValue == provider.rawValue,
              context.generation == resolution.generation,
              context.pendingIdentity == resolution.pendingIdentity,
              context.outgoingProfileIDs.isEmpty else {
            throw SyncError.restoreRecoveryPending
        }
        let requestScope = AccountBoundaryResolverRequestScope(
            providerRawValue: provider.rawValue,
            generation: resolution.generation
        )
        let date = try await $accountBoundaryResolverRequestScope.withValue(
            requestScope
        ) {
            try requirePendingAccountResolution(
                provider: provider,
                matching: resolution
            )
            let remote = try await readMediaStateForPendingAccountBoundary(
                provider: provider,
                matching: resolution
            )
            try requirePendingAccountResolution(
                provider: provider,
                matching: resolution
            )

            let date = try await writeLocalSnapshot(
                provider: provider,
                reason: "confirmed-destructive-replacement-replay",
                snapshot: replay.snapshot
            )
            try requirePendingAccountResolution(
                provider: provider,
                matching: resolution
            )

            if #available(iOS 17.0, *) {
                let local = MediaStateEnvelopeReconciler.strippedForRemote(
                    MediaStateSyncManager.shared.envelopesForRemoteTransport(
                        allowsPreparedRecoveryTransaction: true
                    )
                )
                guard MediaStateSyncManager.shared.replaceMediaStateForRemoteAccountBoundary(
                    with: local,
                    rejecting: remote.records ?? [:],
                    queuesRemoteChanges: false
                ) else {
                    throw SyncError.snapshotRestoreFailed
                }
                let authoritative = MediaStateEnvelopeReconciler.strippedForRemote(
                    MediaStateSyncManager.shared.envelopesForRemoteTransport(
                        allowsPreparedRecoveryTransaction: true
                    )
                )
                let bundle = MediaStateEnvelopeBundle(records: authoritative)
                let data = try MediaStateEnvelopeBundle.encoder().encode(bundle)
                try requirePendingAccountResolution(
                    provider: provider,
                    matching: resolution
                )
                try await writeMediaStateEnvelopeBundle(
                    data,
                    provider: provider,
                    expecting: remote.revision,
                    accountContinuityToken: nil,
                    replacingRemoteAuthority: true
                )
            }
            return date
        }
        try requirePendingAccountResolution(
            provider: provider,
            matching: resolution
        )
        guard BackupManager.shared.authorizeExperimentalCloudRestoreCommit(
            context: context
        ) else {
            throw SyncError.restoreRecoveryPending
        }
        guard BackupManager.shared.completeExperimentalCloudRestoreRecovery() else {
            throw SyncError.restoreRecoveryPending
        }
        return date
    }

    private static func commitPendingAccountResolution(
        provider: CloudSyncProvider,
        matching resolution: PendingAccountResolution,
        outgoingProfileIDs: Set<UUID>,
        restoredTrackerProfileIDs: Set<UUID> = []
    ) -> Bool {
        do {
            try requirePendingAccountResolution(
                provider: provider,
                matching: resolution
            )
            let recoveryContext = ExperimentalCloudRestoreBoundaryContext(
                providerRawValue: provider.rawValue,
                generation: resolution.generation,
                pendingIdentity: resolution.pendingIdentity,
                outgoingProfileIDs: outgoingProfileIDs
                    .sorted { $0.uuidString < $1.uuidString },
                restoredTrackerProfileIDs: restoredTrackerProfileIDs
                    .sorted { $0.uuidString < $1.uuidString }
            )
            guard BackupManager.shared.authorizeExperimentalCloudRestoreCommit(
                context: recoveryContext
            ) else {
                return false
            }

            return true
        } catch {
            return false
        }
    }

    private struct CloudAccountIdentity: Sendable {
        let stableIdentifier: String
        let email: String?
    }

    nonisolated static func normalizedAccountEmail(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let email = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty,
              email.utf8.count <= 320,
              !email.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        let pieces = email.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else {
            return nil
        }
        return email
    }

    private static func storeAccountEmail(
        _ email: String?,
        for provider: CloudSyncProvider
    ) {
        let defaults = UserDefaults.standard
        if let email = normalizedAccountEmail(email) {
            defaults.set(email, forKey: provider.accountEmailKey)
        } else {
            defaults.removeObject(forKey: provider.accountEmailKey)
        }
    }

    private static func fetchAccountIdentity(provider: CloudSyncProvider) async throws -> CloudAccountIdentity? {
        switch provider {
        case .iCloud:
            return nil
        case .googleDrive:
            let accessToken = try await accessToken(for: .googleDrive)
            guard var components = URLComponents(string: "https://www.googleapis.com/drive/v3/about") else {
                throw SyncError.unavailable(.googleDrive)
            }
            components.queryItems = [
                URLQueryItem(
                    name: "fields",
                    value: "user(permissionId,emailAddress)"
                )
            ]
            guard let requestURL = components.url else {
                throw SyncError.unavailable(.googleDrive)
            }
            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let data = try await validatedData(for: request, provider: .googleDrive)
            guard let user = try JSONDecoder()
                .decode(GoogleDriveAboutResponse.self, from: data)
                .user,
                  let permissionID = user.permissionId,
                  !permissionID.isEmpty else { return nil }
            return CloudAccountIdentity(
                stableIdentifier: permissionID,
                email: normalizedAccountEmail(user.emailAddress)
            )
        case .oneDrive:
            let accessToken = try await accessToken(for: .oneDrive)
            guard let identityURL = URL(
                string: "https://graph.microsoft.com/v1.0/me?$select=id,mail,userPrincipalName"
            ) else {
                throw SyncError.unavailable(.oneDrive)
            }
            var request = URLRequest(url: identityURL)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let data = try await validatedData(for: request, provider: .oneDrive)
            let identity = try JSONDecoder().decode(MicrosoftGraphIdentity.self, from: data)
            guard let id = identity.id, !id.isEmpty else { return nil }
            return CloudAccountIdentity(
                stableIdentifier: id,
                email: normalizedAccountEmail(identity.mail)
                    ?? normalizedAccountEmail(identity.userPrincipalName)
            )
        }
    }

    private struct GoogleDriveAboutResponse: Decodable {
        struct User: Decodable {
            let permissionId: String?
            let emailAddress: String?
        }
        let user: User?
    }

    private struct MicrosoftGraphIdentity: Decodable {
        let id: String?
        let mail: String?
        let userPrincipalName: String?
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

    private static func requireAccountContinuity(
        _ provider: CloudSyncProvider,
        expected: String?
    ) throws {
        guard let expected else { return }
        let defaults = UserDefaults.standard
        let generation = defaults.integer(forKey: provider.accountGenerationKey)
        let identity = defaults.string(forKey: provider.accountIdentityKey) ?? ""
        guard !defaults.bool(forKey: provider.accountBoundaryPendingKey),
              "\(generation)|\(identity)" == expected else {
            throw SyncError.authenticationRequired(provider)
        }
    }

    private static func requireAccountGeneration(
        _ provider: CloudSyncProvider,
        expected: Int
    ) throws {
        guard !provider.requiresAccountConnection ||
                UserDefaults.standard.integer(forKey: provider.accountGenerationKey) == expected else {
            throw SyncError.authenticationRequired(provider)
        }
    }

    private static func accessToken(
        for provider: CloudSyncProvider,
        accountContinuityToken: String? = nil
    ) async throws -> String {
        guard provider.requiresAccountConnection else {
            throw SyncError.unavailable(provider)
        }
        if let expectedGeneration = scopedAccountGeneration(for: provider) {
            try requireAccountGeneration(provider, expected: expectedGeneration)
        }
        try requireAccountContinuity(provider, expected: accountContinuityToken)
        guard var token = CloudSyncTokenStore.token(for: provider) else {
            throw SyncError.authenticationRequired(provider)
        }

        if token.expiresAt.timeIntervalSinceNow > 90 {
            if let expectedGeneration = scopedAccountGeneration(for: provider) {
                try requireAccountGeneration(provider, expected: expectedGeneration)
            }
            try requireAccountContinuity(provider, expected: accountContinuityToken)
            return token.accessToken
        }

        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw SyncError.authenticationRequired(provider)
        }

        let generation = UserDefaults.standard.integer(forKey: provider.accountGenerationKey)
        let configuration = try oauthConfiguration(for: provider)
        let refreshed = try await refreshAccessToken(
            refreshToken,
            currentToken: token,
            configuration: configuration,
            provider: provider,
            accountContinuityToken: accountContinuityToken
        )

        guard UserDefaults.standard.integer(forKey: provider.accountGenerationKey) == generation else {
            throw SyncError.authenticationRequired(provider)
        }
        if let expectedGeneration = scopedAccountGeneration(for: provider) {
            try requireAccountGeneration(provider, expected: expectedGeneration)
        }
        try requireAccountContinuity(provider, expected: accountContinuityToken)
        token = refreshed
        try CloudSyncTokenStore.save(token, for: provider)
        return token.accessToken
    }

    private static func forceRefreshAccessToken(
        for provider: CloudSyncProvider,
        accountContinuityToken: String? = nil
    ) async throws -> String {
        if let expectedGeneration = scopedAccountGeneration(for: provider) {
            try requireAccountGeneration(provider, expected: expectedGeneration)
        }
        try requireAccountContinuity(provider, expected: accountContinuityToken)
        guard provider.requiresAccountConnection,
              let token = CloudSyncTokenStore.token(for: provider),
              let refreshToken = token.refreshToken,
              !refreshToken.isEmpty else {
            throw SyncError.authenticationRequired(provider)
        }
        let generation = UserDefaults.standard.integer(forKey: provider.accountGenerationKey)
        let configuration = try oauthConfiguration(for: provider)
        let refreshed = try await refreshAccessToken(
            refreshToken,
            currentToken: token,
            configuration: configuration,
            provider: provider,
            accountContinuityToken: accountContinuityToken
        )
        guard UserDefaults.standard.integer(forKey: provider.accountGenerationKey) == generation else {
            throw SyncError.authenticationRequired(provider)
        }
        if let expectedGeneration = scopedAccountGeneration(for: provider) {
            try requireAccountGeneration(provider, expected: expectedGeneration)
        }
        try requireAccountContinuity(provider, expected: accountContinuityToken)
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

                scopes: ["offline_access", "Files.ReadWrite.AppFolder", "User.Read"],
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
            expiresAt: Date().addingTimeInterval(
                ExperimentalOAuthExpiryPolicy.normalized(response.expiresIn)
            )
        )
    }

    private static func refreshAccessToken(
        _ refreshToken: String,
        currentToken: CloudSyncToken,
        configuration: OAuthConfiguration,
        provider: CloudSyncProvider,
        accountContinuityToken: String? = nil
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

        let data = try await validatedData(
            for: request,
            provider: provider,
            accountContinuityToken: accountContinuityToken
        )
        let response = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        return CloudSyncToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? currentToken.refreshToken,
            expiresAt: Date().addingTimeInterval(
                ExperimentalOAuthExpiryPolicy.normalized(response.expiresIn)
            )
        )
    }

    private static func validatedData(
        for request: URLRequest,
        provider: CloudSyncProvider,
        allowNotFound: Bool,
        maximumResponseBytes: Int,
        accountContinuityToken: String? = nil,
        affectsProviderCooldown: Bool = true
    ) async throws -> Data? {
        var currentRequest = request
        var refreshedAuthorization = false
        var accumulatedRetryDelay: TimeInterval = 0
        let maximumAttempts = 4

        let accountGeneration = scopedAccountGeneration(for: provider)
            ?? UserDefaults.standard.integer(forKey: provider.accountGenerationKey)

        for attempt in 0..<maximumAttempts {
            do {
                try requireAccountGeneration(provider, expected: accountGeneration)
                try requireAccountContinuity(provider, expected: accountContinuityToken)
                let (data, response) = try await URLSession.custom.boundedData(
                    for: currentRequest,
                    maximumResponseBytes: maximumResponseBytes
                )

                try requireAccountGeneration(provider, expected: accountGeneration)
                try requireAccountContinuity(provider, expected: accountContinuityToken)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SyncError.invalidResponse(provider)
                }

                if allowNotFound, httpResponse.statusCode == 404 {
                    if affectsProviderCooldown { clearProviderCooldown(provider) }
                    return nil
                }
                if (200..<300).contains(httpResponse.statusCode) {
                    if affectsProviderCooldown { clearProviderCooldown(provider) }
                    return data
                }

                if httpResponse.statusCode == 401,
                   !refreshedAuthorization,
                   currentRequest.value(forHTTPHeaderField: "Authorization") != nil,
                   provider.requiresAccountConnection {
                    let accessToken = try await forceRefreshAccessToken(
                        for: provider,
                        accountContinuityToken: accountContinuityToken
                    )
                    try requireAccountGeneration(provider, expected: accountGeneration)
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
                    if affectsProviderCooldown { persistProviderCooldown(provider, delay: delay) }
                    guard ExperimentalCloudRetryBudget.shouldRetry(
                        delay: delay,
                        after: accumulatedRetryDelay,
                        isCancelled: Task.isCancelled
                    ) else {
                        throw SyncError.remoteRequestFailed(
                            provider,
                            httpResponse.statusCode,
                            body
                        )
                    }
                    accumulatedRetryDelay += delay
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                if retryable {
                    let delay = retryDelay(response: httpResponse, attempt: attempt, provider: provider)
                    if affectsProviderCooldown { persistProviderCooldown(provider, delay: delay) }
                }
                throw SyncError.remoteRequestFailed(provider, httpResponse.statusCode, body)
            } catch let error as SyncError {
                throw error
            } catch {

                try requireAccountGeneration(provider, expected: accountGeneration)
                try requireAccountContinuity(provider, expected: accountContinuityToken)
                if attempt + 1 < maximumAttempts,
                   !(error is CancellationError),
                   !(error is BoundedURLSessionError) {
                    let delay = retryDelay(response: nil, attempt: attempt, provider: provider)
                    if affectsProviderCooldown { persistProviderCooldown(provider, delay: delay) }
                    guard ExperimentalCloudRetryBudget.shouldRetry(
                        delay: delay,
                        after: accumulatedRetryDelay,
                        isCancelled: Task.isCancelled
                    ) else {
                        throw error
                    }
                    accumulatedRetryDelay += delay
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                if !(error is CancellationError), !(error is BoundedURLSessionError) {
                    if affectsProviderCooldown { persistProviderCooldown(provider, delay: 60) }
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
            if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)),
               seconds.isFinite {
                return min(max(seconds, 1), 300)
            }
            if let date = parseHTTPDate(value) {
                let delay = date.timeIntervalSinceNow
                if delay.isFinite {
                    return min(max(delay, 1), 300)
                }
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
        guard delay.isFinite, delay >= 0 else {
            UserDefaults.standard.removeObject(forKey: provider.retryNotBeforeKey)
            return
        }
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
        provider: CloudSyncProvider,
        accountContinuityToken: String? = nil
    ) async throws -> Data {
        try await validatedData(
            for: request,
            provider: provider,
            maximumResponseBytes: maximumCloudControlResponseBytes,
            accountContinuityToken: accountContinuityToken
        )
    }

    private static func validatedData(
        for request: URLRequest,
        provider: CloudSyncProvider,
        maximumResponseBytes: Int,
        accountContinuityToken: String? = nil
    ) async throws -> Data {
        guard let data = try await validatedData(
            for: request,
            provider: provider,
            allowNotFound: false,
            maximumResponseBytes: maximumResponseBytes,
            accountContinuityToken: accountContinuityToken
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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decode(String.self, forKey: .accessToken)
            refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
            if let numeric = try? container.decodeIfPresent(
                TimeInterval.self,
                forKey: .expiresIn
            ) {
                expiresIn = numeric
            } else if let quoted = try? container.decodeIfPresent(
                String.self,
                forKey: .expiresIn
            ) {
                expiresIn = TimeInterval(quoted)
            } else {
                expiresIn = nil
            }
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

            case accountChanged
        }

        let provider: CloudSyncProvider
        let localRecordCount: Int
        let remoteRecordCount: Int
        let direction: Direction

        var id: CloudSyncProvider { provider }

        var alertMessage: String {
            switch direction {
            case .cloudIsFuller:
                return "This device has about \(localRecordCount) saved items, while \(provider.displayName) has about \(remoteRecordCount). Eclipse paused before overwriting the fuller cloud backup. \"Restore Cloud Data\" replaces this device's data and settings with the cloud copy. \"Replace Cloud Backup\" overwrites the cloud copy, and every other synced device will adopt it."
            case .deviceIsFuller:
                return "This device has about \(localRecordCount) saved items, while the newer \(provider.displayName) backup has about \(remoteRecordCount). Eclipse paused before replacing the fuller device data. \"Restore Cloud Data\" replaces this device's data and settings with the cloud copy. \"Replace Cloud Backup\" overwrites the cloud copy, and every other synced device will adopt it."
            case .bothChanged:
                return "Both this device and the newer \(provider.displayName) backup changed since the last sync. Eclipse paused without replacing either copy. Choose which version to keep; the copy you replace is also updated on every other synced device."
            case .accountChanged:
                return "This is a different \(provider.displayName) account than the one this device last synced with. Eclipse paused before mixing the two. \"Replace Cloud Backup\" keeps this device's data and overwrites the cloud copy for every device on this account. \"Restore Cloud Data\" resets this device's profiles, settings, and library, then adopts what is already in this account."
            }
        }
    }

    private struct GoogleDriveListResponse: Decodable {
        let files: [GoogleDriveFile]
        let nextPageToken: String?
        let listedObjectCount: Int

        private enum CodingKeys: String, CodingKey {
            case files
            case nextPageToken
        }

        private struct GoogleDriveListedFile: Decodable {
            let id: String?
            let name: String?
            let modifiedTime: String?
            let md5Checksum: String?
            let size: String?
            let quotaBytesUsed: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let listedFiles = try container.decodeIfPresent(
                [GoogleDriveListedFile].self,
                forKey: .files
            ) ?? []
            listedObjectCount = listedFiles.count
            files = listedFiles.compactMap { listed in
                guard let id = listed.id, !id.isEmpty else { return nil }
                return GoogleDriveFile(
                    id: id,
                    name: listed.name,
                    modifiedTime: listed.modifiedTime,
                    md5Checksum: listed.md5Checksum,
                    byteCount: listed.quotaBytesUsed.flatMap(Int64.init)
                        ?? listed.size.flatMap(Int64.init)
                )
            }
            let token = try container.decodeIfPresent(String.self, forKey: .nextPageToken)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            nextPageToken = token?.isEmpty == false ? token : nil
        }
    }

    private struct GoogleDriveFile: Decodable {
        let id: String
        let name: String?
        let modifiedTime: String?
        let md5Checksum: String?
        var byteCount: Int64?
    }

    private struct OneDriveItem: Decodable {
        let id: String?
        let lastModifiedDateTime: String?
        let eTag: String?
        var size: Int64?
    }

    private struct OneDriveChildrenResponse: Decodable {
        let value: [OneDriveItem]
        let nextLink: String?

        private enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    enum SyncError: LocalizedError, Sendable {
        case unavailable(CloudSyncProvider)
        case authenticationRequired(CloudSyncProvider)
        case noSnapshot(CloudSyncProvider)
        case snapshotEncodingFailed
        case snapshotPreparationDeferred
        case snapshotPreparationStalled
        case snapshotSourcesUnavailable
        case snapshotInspectionFailed
        case snapshotRestoreFailed
        case restoreRecoveryPreparationFailed
        case restoreRecoveryPending
        case accountBoundaryRestoreRequiresIOS17(CloudSyncProvider)
        case iCloudDownloadFailed
        case iCloudDownloadTimedOut
        case suspiciousLocalReduction(CloudSyncProvider, Int, Int)
        case suspiciousRemoteReduction(CloudSyncProvider, Int, Int)
        case concurrentSnapshotConflict(CloudSyncProvider, Int, Int)
        case remoteChangedDuringSync(CloudSyncProvider)
        case canonicalStateUnavailable(CloudSyncProvider)
        case authorizationFailed(String)
        case invalidResponse(CloudSyncProvider)
        case remoteRequestFailed(CloudSyncProvider, Int, String)
        case snapshotTooLarge(CloudSyncProvider)

        var errorDescription: String? {
            switch self {
            case .snapshotTooLarge(let provider):
                return "This device's media state is too large to send to \(provider.displayName)."
            case .unavailable(let provider):
                return "\(provider.displayName) is unavailable for this build or account."
            case .authenticationRequired(let provider):
                return "Connect \(provider.displayName) first."
            case .noSnapshot(let provider):
                return "No \(provider.displayName) snapshot was found."
            case .snapshotEncodingFailed:
                return "Could not prepare a safe cloud snapshot."
            case .snapshotPreparationDeferred:
                return "Sources are still loading. Eclipse left both copies unchanged and will sync as soon as they finish."
            case .snapshotPreparationStalled:
                return "Sources are taking unusually long to load, so Eclipse paused sync instead of uploading an incomplete backup."
            case .snapshotSourcesUnavailable:
                return "Your sources could not be loaded, so Eclipse paused cloud sync rather than act on an incomplete copy of your data. Open Services to check them."
            case .snapshotInspectionFailed:
                return "The cloud snapshot could not be safely inspected, so Eclipse left both copies unchanged."
            case .snapshotRestoreFailed:
                return "Could not restore the cloud snapshot."
            case .restoreRecoveryPreparationFailed:
                return "Could not create a local recovery point, so Eclipse did not start the cloud restore."
            case .restoreRecoveryPending:
                return "The cloud restore is safely paused while Eclipse finishes its local recovery transaction."
            case .accountBoundaryRestoreRequiresIOS17(let provider):
                return "Restoring a different \(provider.displayName) account requires iOS 17 or later so Eclipse can isolate both accounts safely. You can still keep this device's copy."
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
            case .canonicalStateUnavailable(let provider):
                return "Uploads to \(provider.displayName) are paused while this device's media state needs recovery, so the cloud copy stays protected."
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

        var isSourceLoadingDeferral: Bool {
            if case .snapshotPreparationDeferred = self { return true }
            return false
        }

        var automaticFailureAction: ExperimentalCloudAutomaticFailureAction {
            switch self {
            case .suspiciousLocalReduction,
                 .suspiciousRemoteReduction,
                 .concurrentSnapshotConflict:
                return .awaitOverwriteDecision
            default:
                return .retry
            }
        }

        var diagnosticCaseToken: String {
            switch self {
            case .unavailable:
                return "unavailable"
            case .authenticationRequired:
                return "authentication-required"
            case .noSnapshot:
                return "no-snapshot"
            case .snapshotEncodingFailed:
                return "snapshot-encoding-failed"
            case .snapshotPreparationDeferred:
                return "snapshot-preparation-deferred"
            case .snapshotPreparationStalled:
                return "snapshot-preparation-stalled"
            case .snapshotSourcesUnavailable:
                return "snapshot-sources-unavailable"
            case .snapshotInspectionFailed:
                return "snapshot-inspection-failed"
            case .snapshotRestoreFailed:
                return "snapshot-restore-failed"
            case .restoreRecoveryPreparationFailed:
                return "restore-recovery-preparation-failed"
            case .restoreRecoveryPending:
                return "restore-recovery-pending"
            case .accountBoundaryRestoreRequiresIOS17:
                return "account-boundary-restore-requires-ios17"
            case .iCloudDownloadFailed:
                return "icloud-download-failed"
            case .iCloudDownloadTimedOut:
                return "icloud-download-timed-out"
            case .suspiciousLocalReduction:
                return "suspicious-local-reduction"
            case .suspiciousRemoteReduction:
                return "suspicious-remote-reduction"
            case .concurrentSnapshotConflict:
                return "concurrent-snapshot-conflict"
            case .remoteChangedDuringSync:
                return "remote-changed-during-sync"
            case .canonicalStateUnavailable:
                return "canonical-state-unavailable"
            case .authorizationFailed:
                return "authorization-failed"
            case .invalidResponse:
                return "invalid-response"
            case .remoteRequestFailed:
                return "remote-request-failed"
            case .snapshotTooLarge:
                return "snapshot-too-large"
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

enum CloudSyncTokenStore {
    private static let service = "app.Eclipse.Soupy.cloud-sync"

    static func hasToken(for provider: CloudSyncProvider) -> Bool {
        token(for: provider) != nil
    }

    fileprivate static func token(for provider: CloudSyncProvider) -> ExperimentalCloudSyncManager.CloudSyncToken? {
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

    fileprivate static func save(_ token: ExperimentalCloudSyncManager.CloudSyncToken, for provider: CloudSyncProvider) throws {
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
    let strongEntityTag: String?
}

final class ExperimentalMPVPreloadManager {
    static let shared = ExperimentalMPVPreloadManager()

    private let fileManager = FileManager.default
    private let maxStarterBytes = 8 * 1024 * 1024
    private let maxPlaylistBytes = 1 * 1024 * 1024
    private let maxStarterMetadataBytes = 16 * 1024
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
            guard let self else { return }
            self.lock.lock()
            self.currentPath = path
            self.lock.unlock()
        }
        pathMonitor.start(queue: pathQueue)
#endif
        migrateLegacyCacheFileNamesIfNeeded()

        if Self.autoClearEnabled {
            pruneCacheIfNeeded(limitBytes: currentCacheLimitBytes())
        }
    }

    static var autoClearEnabled: Bool {
        (ProfileSettingsStore.active.object(forKey: ExperimentalFeatureState.mpvPreloadAutoClearKey) as? Bool) ?? true
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
        guard ProfileSettingsStore.active.bool(forKey: ExperimentalFeatureState.mpvPreloadEnabledKey) else {
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
        guard ProfileSettingsStore.active.bool(forKey: ExperimentalFeatureState.mpvSmoothTransitionEnabledKey) else {
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
            guard let proxyURL = MPVHeaderProxy.shared.makeProxyURL(
                for: url,
                headers: headers ?? [:],
                logType: "MPV",
                traceID: "preload-\(String(key.prefix(8)))"
            ) else {
                Logger.shared.log(
                    "MPV warmup skipped for \(safeLabel): pinned-proxy-unavailable target=\(logURLSummary(url))",
                    type: "MPV"
                )
                return
            }
            defer {
                MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
            }
            guard !Task.isCancelled else { return }
            await writeStarterCache(
                originalURL: url,
                transportURL: proxyURL,
                headers: headers,
                key: key,
                label: label
            )
        }
    }

    func cachedStarter(for url: URL, headers: [String: String]?) -> ExperimentalMPVPreloadCachedStarter? {
        let key = cacheKey(for: url, headers: headers)
        let dataURL = starterURL(forKey: key)
        let metadataURL = starterMetadataURL(forKey: key)

        guard reserveActiveKey(key) else { return nil }
        defer { releaseActiveKey(key) }

        guard let metadataData = boundedRegularFileData(
                  at: metadataURL,
                  maximumBytes: maxStarterMetadataBytes
              ),
              let metadata = try? JSONDecoder().decode(StarterMetadata.self, from: metadataData),
              metadata.storedAt.isFinite,
              metadata.storedAt <= Date().timeIntervalSince1970 + 300,
              metadata.dataLength > 0,
              metadata.dataLength <= maxStarterBytes,
              (200..<300).contains(metadata.statusCode),
              metadata.totalLength.map({ $0 >= 0 }) ?? true,
              Date().timeIntervalSince1970 - metadata.storedAt <= maxStarterAge,
              let data = boundedRegularFileData(at: dataURL, maximumBytes: maxStarterBytes),
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
            isPlaylist: metadata.isPlaylist,
            strongEntityTag: metadata.strongEntityTag
        )
    }

    func cachedStarter(
        for url: URL,
        headers: [String: String]?,
        waitForActiveWarmupUpTo timeout: TimeInterval
    ) async -> ExperimentalMPVPreloadCachedStarter? {
        let key = cacheKey(for: url, headers: headers)
        guard isActiveKey(key), timeout > 0 else {

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
        guard ProfileSettingsStore.active.bool(forKey: ExperimentalFeatureState.mpvPreloadEnabledKey) else { return "warmup-disabled" }
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
        guard let currentPath = currentNetworkPath() else { return "network-path-pending" }
        guard currentPath.status == .satisfied else { return "network-unsatisfied" }
        if currentPath.usesInterfaceType(.cellular),
           !ProfileSettingsStore.active.bool(forKey: ExperimentalFeatureState.mpvPreloadCellularEnabledKey) {
            return "cellular-disabled"
        }
#endif
        return nil
    }

    private func currentCacheLimitBytes() -> Int64 {
#if canImport(Network)
        if currentNetworkPath()?.usesInterfaceType(.cellular) == true {
            let mb = ProfileSettingsStore.active.integer(forKey: ExperimentalFeatureState.mpvPreloadCellularLimitMBKey)
            return Int64(ExperimentalFeatureState.resolvedMPVPreloadCellularLimitMB(mb)) * 1024 * 1024
        }
#endif
        let mb = ProfileSettingsStore.active.integer(forKey: ExperimentalFeatureState.mpvPreloadWifiLimitMBKey)
        return Int64(ExperimentalFeatureState.resolvedMPVPreloadWifiLimitMB(mb)) * 1024 * 1024
    }

    private func writeStarterCache(
        originalURL: URL,
        transportURL: URL,
        headers: [String: String]?,
        key: String,
        label: String
    ) async {
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            var request = URLRequest(url: transportURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
            let isPlaylistExtension = ["m3u8", "m3u"].contains(
                originalURL.pathExtension.lowercased()
            )
            if !isPlaylistExtension {
                request.setValue("bytes=0-\(maxStarterBytes - 1)", forHTTPHeaderField: "Range")
            }

            let responseLimit = isPlaylistExtension
                ? maxPlaylistBytes
                : maxStarterBytes
            let (data, response) = try await URLSession.shared.boundedData(
                for: request,
                maximumResponseBytes: responseLimit
            )
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                Logger.shared.log("MPV warmup skipped for \(label): empty-or-invalid-response target=\(logURLSummary(originalURL))", type: "MPV")
                return
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type")
            let rangeInfo = parseContentRange(http.value(forHTTPHeaderField: "Content-Range"))
            let isPlaylist = isLikelyPlaylist(url: originalURL, contentType: contentType)
            if isPlaylist {
                await writeHLSMediaStarterCache(
                    originalPlaylistURL: originalURL,
                    transportPlaylistURL: transportURL,
                    data: data,
                    headers: headers,
                    label: label,
                    depth: 0
                )
                return
            }

            let totalLength = rangeInfo?.totalLength
                ?? (http.expectedContentLength >= 0 ? http.expectedContentLength : nil)
            let isUsableRangeStarter = http.statusCode == 206 && rangeInfo?.start == 0
            guard isUsableRangeStarter else {
                Logger.shared.log("MPV warmup skipped for \(label): upstream-did-not-provide-usable-starter status=\(http.statusCode) range=\(http.value(forHTTPHeaderField: "Content-Range") ?? "nil") target=\(logURLSummary(originalURL))", type: "MPV")
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
                storedAt: Date().timeIntervalSince1970,
                strongEntityTag: sanitizedStrongEntityTag(
                    http.value(forHTTPHeaderField: "ETag")
                )
            )
            try starterData.write(to: target, options: .atomic)
            try JSONEncoder().encode(metadata).write(to: starterMetadataURL(forKey: key), options: .atomic)
            pruneCacheIfNeeded(limitBytes: currentCacheLimitBytes())
            Logger.shared.log("MPV warmup cached bytes=\(starterData.count) status=\(http.statusCode) playlist=false totalLength=\(totalLength.map(String.init) ?? "unknown") target=\(logURLSummary(originalURL)) label=\(label)", type: "MPV")
        } catch {
            Logger.shared.log("MPV warmup skipped for \(label): error=\(logErrorSummary(error)) target=\(logURLSummary(originalURL))", type: "MPV")
        }
    }

    private func writeHLSMediaStarterCache(
        originalPlaylistURL: URL,
        transportPlaylistURL: URL,
        data: Data,
        headers: [String: String]?,
        label: String,
        depth: Int
    ) async {
        guard depth < 2 else {
            Logger.shared.log("MPV warmup skipped for \(label): hls-playlist-depth-limit target=\(logURLSummary(originalPlaylistURL))", type: "MPV")
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            Logger.shared.log("MPV warmup skipped for \(label): hls-playlist-not-utf8 target=\(logURLSummary(originalPlaylistURL))", type: "MPV")
            return
        }

        let plan = hlsWarmupPlan(from: text, playlistURL: transportPlaylistURL)
        if let variantTransportURL = plan.variantURL {
            guard let variantOriginalURL = managedOriginalTargetURL(for: variantTransportURL) else {
                Logger.shared.log(
                    "MPV warmup skipped for \(label): hls-variant-left-pinned-session target=\(logURLSummary(originalPlaylistURL))",
                    type: "MPV"
                )
                return
            }
            do {
                let (variantData, response) = try await fetchHLSPlaylistData(transportURL: variantTransportURL)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      !variantData.isEmpty else {
                    Logger.shared.log("MPV warmup skipped for \(label): hls-variant-invalid target=\(logURLSummary(variantOriginalURL))", type: "MPV")
                    return
                }
                Logger.shared.log("MPV warmup HLS master selected variant target=\(logURLSummary(variantOriginalURL)) playlist=\(logURLSummary(originalPlaylistURL))", type: "MPV")
                await writeHLSMediaStarterCache(
                    originalPlaylistURL: variantOriginalURL,
                    transportPlaylistURL: variantTransportURL,
                    data: variantData,
                    headers: headers,
                    label: "\(label) HLS variant",
                    depth: depth + 1
                )
            } catch {
                Logger.shared.log("MPV warmup skipped for \(label): hls-variant-fetch-failed error=\(logErrorSummary(error)) target=\(logURLSummary(variantOriginalURL))", type: "MPV")
            }
            return
        }

        let targets = hlsMediaWarmupTargets(mapURL: plan.mapURL, segmentURL: plan.segmentURL).compactMap {
            transportURL -> (originalURL: URL, transportURL: URL)? in
            guard let originalURL = managedOriginalTargetURL(for: transportURL) else { return nil }
            return (originalURL, transportURL)
        }
        guard !targets.isEmpty else {
            Logger.shared.log("MPV warmup skipped for \(label): hls-no-pinned-media-target playlist=\(logURLSummary(originalPlaylistURL))", type: "MPV")
            return
        }

        Logger.shared.log("MPV warmup HLS media targets count=\(targets.count) playlist=\(logURLSummary(originalPlaylistURL)) targets=[\(targets.map { logURLSummary($0.originalURL) }.joined(separator: ","))]", type: "MPV")
        var reservedTargets: [(originalURL: URL, transportURL: URL, key: String)] = []
        for target in targets {
            let key = cacheKey(for: target.originalURL, headers: headers)
            if reserveActiveKey(key) {
                reservedTargets.append((target.originalURL, target.transportURL, key))
            } else {
                Logger.shared.log("MPV warmup coalesced for \(label) HLS media target=\(logURLSummary(target.originalURL))", type: "MPV")
            }
        }

        var pendingKeys = Set(reservedTargets.map { $0.key })
        defer {
            for key in pendingKeys {
                releaseActiveKey(key)
            }
        }

        for target in reservedTargets {
            guard !Task.isCancelled else { return }
            await writeStarterCache(
                originalURL: target.originalURL,
                transportURL: target.transportURL,
                headers: headers,
                key: target.key,
                label: "\(label) HLS media"
            )
            pendingKeys.remove(target.key)
            releaseActiveKey(target.key)
        }
    }

    private func fetchHLSPlaylistData(transportURL: URL) async throws -> (Data, URLResponse) {
        let request = URLRequest(url: transportURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        return try await URLSession.shared.boundedData(
            for: request,
            maximumResponseBytes: maxPlaylistBytes
        )
    }

    private func boundedRegularFileData(at url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes > 0,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumBytes,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              !data.isEmpty,
              data.count <= maximumBytes,
              data.count == fileSize else {
            return nil
        }
        return data
    }

#if canImport(Network)
    private func currentNetworkPath() -> NWPath? {
        lock.lock()
        let path = currentPath
        lock.unlock()
        return path
    }
#endif

    private func managedOriginalTargetURL(for transportURL: URL) -> URL? {
        guard let originalURL = MPVHeaderProxy.shared.originalTargetURL(for: transportURL),
              let scheme = originalURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return originalURL
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
        guard !url.isFileURL,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return url.isFileURL ? "local-file" : "invalid-url"
        }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        let portText = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portText)"
    }

    private func logErrorSummary(_ error: Error) -> String {
        "\(String(reflecting: type(of: error)))#\((error as NSError).code)"
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

    private func sanitizedStrongEntityTag(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count >= 2,
              trimmed.utf8.count <= 512,
              !trimmed.lowercased().hasPrefix("w/"),
              trimmed.first == "\"",
              trimmed.last == "\"",
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value != 0x7F
              }) else {
            return nil
        }
        return trimmed
    }

    private func migrateLegacyCacheFileNamesIfNeeded() {
        guard !ProfileSettingsStore.active.bool(forKey: cacheKeyMigrationDefaultsKey) else { return }
        try? fileManager.removeItem(at: cacheDirectory)
        ProfileSettingsStore.active.set(true, forKey: cacheKeyMigrationDefaultsKey)
    }

    private struct StarterMetadata: Codable {
        let statusCode: Int
        let contentType: String?
        let totalLength: Int64?
        let isPlaylist: Bool
        let dataLength: Int
        let storedAt: TimeInterval
        let strongEntityTag: String?
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

    private(set) static weak var current: Settings?

    private var isReloadingForProfileSwitch = false

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
            guard !isReloadingForProfileSwitch else { return }
            ProfileSettingsStore.active.set(selectedAppearance.rawValue, forKey: "selectedAppearance")
            updateAppearance()
        }
    }
#if !os(tvOS)
    @Published var readerSelectedAppearance: Appearance {
        didSet {
            guard !isReloadingForProfileSwitch else { return }
            ProfileSettingsStore.active.set(readerSelectedAppearance.rawValue, forKey: "readerSelectedAppearance")
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

    private func migratedBool(genericKey: String, legacyKey: String, defaultValue: Bool) -> Bool {
        if ProfileSettingsStore.active.object(forKey: genericKey) == nil {
            let value = ProfileSettingsStore.active.object(forKey: legacyKey) as? Bool ?? defaultValue
            ProfileSettingsStore.active.set(value, forKey: genericKey)
            return value
        }
        return ProfileSettingsStore.active.bool(forKey: genericKey)
    }

    private func migratedDouble(genericKey: String, legacyKey: String, defaultValue: Double) -> Double {
        if ProfileSettingsStore.active.object(forKey: genericKey) == nil {
            let value = ProfileSettingsStore.active.double(forKey: legacyKey)
            let resolved = value > 0 ? value : defaultValue
            ProfileSettingsStore.active.set(resolved, forKey: genericKey)
            return resolved
        }
        let value = ProfileSettingsStore.active.double(forKey: genericKey)
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
        get { ProfileSettingsStore.active.bool(forKey: "enableSubtitlesByDefault") }
        set { ProfileSettingsStore.active.set(newValue, forKey: "enableSubtitlesByDefault") }
    }

    var defaultSubtitleLanguage: String {
        get { ProfileSettingsStore.active.string(forKey: "defaultSubtitleLanguage") ?? "eng" }
        set { ProfileSettingsStore.active.set(newValue, forKey: "defaultSubtitleLanguage") }
    }

    var preferredAnimeAudioLanguage: String {
        get { ProfileSettingsStore.active.string(forKey: "preferredAnimeAudioLanguage") ?? "jpn" }
        set { ProfileSettingsStore.active.set(newValue, forKey: "preferredAnimeAudioLanguage") }
    }

    var preferredAutoAudioLanguage: String {
        get { ProfileSettingsStore.active.string(forKey: "preferredAutoAudioLanguage") ?? "eng" }
        set { ProfileSettingsStore.active.set(newValue, forKey: "preferredAutoAudioLanguage") }
    }

    var playerBrightnessGestureEnabled: Bool {
        get { migratedBool(genericKey: "playerBrightnessGestureEnabled", legacyKey: "vlcBrightnessGestureEnabled", defaultValue: false) }
        set { ProfileSettingsStore.active.set(newValue, forKey: "playerBrightnessGestureEnabled") }
    }

    var playerVolumeGestureEnabled: Bool {
        get { migratedBool(genericKey: "playerVolumeGestureEnabled", legacyKey: "vlcVolumeGestureEnabled", defaultValue: false) }
        set { ProfileSettingsStore.active.set(newValue, forKey: "playerVolumeGestureEnabled") }
    }

    var playerTwoFingerTapPlayPauseEnabled: Bool {
        get {
            if ProfileSettingsStore.active.object(forKey: "playerTwoFingerTapPlayPauseEnabled") == nil {
                if let legacyValue = ProfileSettingsStore.active.object(forKey: "mpvTwoFingerTapEnabled") as? Bool {
                    ProfileSettingsStore.active.set(legacyValue, forKey: "playerTwoFingerTapPlayPauseEnabled")
                    return legacyValue
                }
                ProfileSettingsStore.active.set(true, forKey: "playerTwoFingerTapPlayPauseEnabled")
            }
            return ProfileSettingsStore.active.bool(forKey: "playerTwoFingerTapPlayPauseEnabled")
        }
        set { ProfileSettingsStore.active.set(newValue, forKey: "playerTwoFingerTapPlayPauseEnabled") }
    }

    var defaultPlaybackSpeed: Double {
        get {
            let savedSpeed = ProfileSettingsStore.active.double(forKey: "defaultPlaybackSpeed")
            return savedSpeed > 0 ? savedSpeed : 1.0
        }
        set { ProfileSettingsStore.active.set(newValue, forKey: "defaultPlaybackSpeed") }
    }

    var playerDoubleTapSeekEnabled: Bool {
        get { migratedBool(genericKey: "playerDoubleTapSeekEnabled", legacyKey: "vlcDoubleTapSeekEnabled", defaultValue: true) }
        set { ProfileSettingsStore.active.set(newValue, forKey: "playerDoubleTapSeekEnabled") }
    }

    var playerDoubleTapSeekSeconds: Double {
        get { migratedDouble(genericKey: "playerDoubleTapSeekSeconds", legacyKey: "vlcDoubleTapSeekSeconds", defaultValue: 10.0) }
        set { ProfileSettingsStore.active.set(newValue, forKey: "playerDoubleTapSeekSeconds") }
    }

    var playerOpenSubtitlesEnabled: Bool {
        get { migratedBool(genericKey: "playerOpenSubtitlesEnabled", legacyKey: "vlcOpenSubtitlesEnabled", defaultValue: false) }
        set { ProfileSettingsStore.active.set(newValue, forKey: "playerOpenSubtitlesEnabled") }
    }

    var playerOpenSubtitlesAutoFallbackEnabled: Bool {
        get { migratedBool(genericKey: "playerOpenSubtitlesAutoFallbackEnabled", legacyKey: "vlcOpenSubtitlesAutoFallbackEnabled", defaultValue: true) }
        set { ProfileSettingsStore.active.set(newValue, forKey: "playerOpenSubtitlesAutoFallbackEnabled") }
    }

    var playerPerformanceOverlayEnabled: Bool {
        get { false }
        set { ProfileSettingsStore.active.set(false, forKey: "playerPerformanceOverlayEnabled") }
    }

    var mpvForegroundFPS: Int {
        get {
            ProfileSettingsStore.active.integer(forKey: "mpvForegroundFPS") == 60 ? 60 : 30
        }
        set {
            ProfileSettingsStore.active.set(newValue == 60 ? 60 : 30, forKey: "mpvForegroundFPS")
        }
    }

    var mpvRenderBackend: MPVRenderBackend {
        get {
            ProfileSettingsStore.active.set(MPVRenderBackend.defaultBackend.rawValue, forKey: "mpvRenderBackend")
            return .defaultBackend
        }
        set {
            ProfileSettingsStore.active.set(MPVRenderBackend.defaultBackend.rawValue, forKey: "mpvRenderBackend")
        }
    }

    var mpvMetalQualityProfile: MPVMetalQualityProfile {
        get {
            let raw = ProfileSettingsStore.active.string(forKey: "mpvMetalQualityProfile")
                ?? MPVMetalQualityProfile.defaultProfile.rawValue
            return MPVMetalQualityProfile(rawValue: raw) ?? .defaultProfile
        }
        set {
            ProfileSettingsStore.active.set(newValue.rawValue, forKey: "mpvMetalQualityProfile")
        }
    }

    var mpvUpscalingMode: MPVUpscalingMode {
        get {
            let raw = ProfileSettingsStore.active.string(forKey: "mpvUpscalingMode")
                ?? MPVUpscalingMode.defaultMode.rawValue
            return MPVUpscalingMode(rawValue: raw) ?? .defaultMode
        }
        set {
            ProfileSettingsStore.active.set(newValue.rawValue, forKey: "mpvUpscalingMode")
        }
    }

    var mpvNeuralUpscaler: MPVNeuralUpscaler {
        get {
            let raw = ProfileSettingsStore.active.string(forKey: "mpvNeuralUpscaler")
                ?? MPVNeuralUpscaler.defaultUpscaler.rawValue
            return MPVNeuralUpscaler(rawValue: raw) ?? .defaultUpscaler
        }
        set {
            ProfileSettingsStore.active.set(newValue.rawValue, forKey: "mpvNeuralUpscaler")
        }
    }

    var mpvNeuralUpscalerTV: MPVNeuralUpscaler {
        get {
            let raw = ProfileSettingsStore.active.string(forKey: "mpvNeuralUpscalerTV")
                ?? MPVNeuralUpscaler.defaultUpscaler.rawValue
            return MPVNeuralUpscaler(rawValue: raw) ?? .defaultUpscaler
        }
        set {
            ProfileSettingsStore.active.set(newValue.rawValue, forKey: "mpvNeuralUpscalerTV")
        }
    }

    var mpvPerformanceOverlayEnabled: Bool {
        get { ProfileSettingsStore.active.bool(forKey: "mpvPerformanceOverlayEnabled") }
        set { ProfileSettingsStore.active.set(newValue, forKey: "mpvPerformanceOverlayEnabled") }
    }

    var mpvUseLegacyCPURenderer: Bool {
        get { ProfileSettingsStore.active.bool(forKey: "mpvUseLegacyCPURenderer") }
        set { ProfileSettingsStore.active.set(newValue, forKey: "mpvUseLegacyCPURenderer") }
    }

    var mpvAppExitPictureInPictureEnabled: Bool {
        get { ProfileSettingsStore.active.bool(forKey: "mpvAppExitPictureInPictureEnabled") }
        set { ProfileSettingsStore.active.set(newValue, forKey: "mpvAppExitPictureInPictureEnabled") }
    }

    var mpvPictureInPictureEnabled: Bool {
        get { ProfileSettingsStore.active.object(forKey: "mpvPictureInPictureEnabled") as? Bool ?? true }
        set { ProfileSettingsStore.active.set(newValue, forKey: "mpvPictureInPictureEnabled") }
    }

    var mpvHDRMode: MPVHDRMode {
        get {
            let raw = ProfileSettingsStore.active.string(forKey: "mpvHDRMode")
                ?? MPVHDRMode.defaultMode.rawValue
            return MPVHDRMode(rawValue: raw) ?? .defaultMode
        }
        set {
            ProfileSettingsStore.active.set(newValue.rawValue, forKey: "mpvHDRMode")
        }
    }

    var audioComfortMode: AudioComfortMode {
        get {
            let raw = ProfileSettingsStore.active.string(forKey: "audioComfortMode")
                ?? AudioComfortMode.defaultMode.rawValue
            return AudioComfortMode(rawValue: raw) ?? .defaultMode
        }
        set {
            ProfileSettingsStore.active.set(newValue.rawValue, forKey: "audioComfortMode")
        }
    }

    var audioComfortScopeCategories: Set<AudioComfortContentCategory> {
        get {
            guard let raw = ProfileSettingsStore.active.array(forKey: "audioComfortScopeCategories") as? [String] else {
                return AudioComfortContentCategory.defaultScope
            }
            return Set(raw.compactMap { AudioComfortContentCategory(rawValue: $0) })
        }
        set {
            ProfileSettingsStore.active.set(newValue.map { $0.rawValue }, forKey: "audioComfortScopeCategories")
        }
    }

    var mpvSurroundSoundEnabled: Bool {
        get {
            if ProfileSettingsStore.active.object(forKey: "mpvSurroundSoundEnabled") == nil {
                return true
            }
            return ProfileSettingsStore.active.bool(forKey: "mpvSurroundSoundEnabled")
        }
        set {
            ProfileSettingsStore.active.set(newValue, forKey: "mpvSurroundSoundEnabled")
        }
    }

    var watchTogetherEnabled: Bool {
        get { WatchTogetherSettings.isEnabled() }
        set { ProfileSettingsStore.active.set(newValue, forKey: WatchTogetherSettings.enabledKey) }
    }

    var smartInAppPlayerChoosingEnabled: Bool {
        get { false }
        set { ProfileSettingsStore.active.set(false, forKey: "smartInAppPlayerChoosingEnabled") }
    }

    var playerSubtitleAppearanceEnabled: Bool {
        get {
            if ProfileSettingsStore.active.object(forKey: "playerSubtitleAppearanceEnabled") == nil {
                let legacy = ProfileSettingsStore.active.object(forKey: "enableVLCSubtitleEditMenu") as? Bool ?? true
                ProfileSettingsStore.active.set(legacy, forKey: "playerSubtitleAppearanceEnabled")
                return legacy
            }
            return ProfileSettingsStore.active.bool(forKey: "playerSubtitleAppearanceEnabled")
        }
        set { ProfileSettingsStore.active.set(newValue, forKey: "playerSubtitleAppearanceEnabled") }
    }

    enum PlayerChoice: String {
        case mpv
    }

    var playerChoice: PlayerChoice {
        get {
            let normalized = Self.normalizedInAppPlayer(ProfileSettingsStore.active.string(forKey: "inAppPlayer"))
            if normalized != ProfileSettingsStore.active.string(forKey: "inAppPlayer") {
                ProfileSettingsStore.active.set(normalized, forKey: "inAppPlayer")
            }
            return .mpv
        }
        set {
            ProfileSettingsStore.active.set("mpv", forKey: "inAppPlayer")
        }
    }

    private init() {
        let resolvedAccentColor: Color
        if let colorData = ProfileSettingsStore.active.data(forKey: "accentColor"),
           let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData) {
            resolvedAccentColor = Color(uiColor)
        } else {
            resolvedAccentColor = .accentColor
        }
        self.accentColor = resolvedAccentColor
#if !os(tvOS)
        if let colorData = ProfileSettingsStore.active.data(forKey: "readerAccentColor"),
           let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData) {
            self.readerAccentColor = Color(uiColor)
        } else {
            self.readerAccentColor = resolvedAccentColor
        }
#endif
        let resolvedAppearance: Appearance
        if let appearanceRawValue = ProfileSettingsStore.active.string(forKey: "selectedAppearance"),
           let appearance = Appearance(rawValue: appearanceRawValue) {
            resolvedAppearance = appearance
        } else {
            resolvedAppearance = .system
        }
        self.selectedAppearance = resolvedAppearance
#if !os(tvOS)
        if let appearanceRawValue = ProfileSettingsStore.active.string(forKey: "readerSelectedAppearance"),
           let appearance = Appearance(rawValue: appearanceRawValue) {
            self.readerSelectedAppearance = appearance
        } else {
            self.readerSelectedAppearance = resolvedAppearance
        }
#endif
        updateAppearance()
        Self.current = self
    }

    func reloadForActiveProfile() {
        isReloadingForProfileSwitch = true
        defer {
            isReloadingForProfileSwitch = false
            updateAppearance()
        }
        let resolvedAccentColor: Color
        if let colorData = ProfileSettingsStore.active.data(forKey: "accentColor"),
           let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData) {
            resolvedAccentColor = Color(uiColor)
        } else {
            resolvedAccentColor = .accentColor
        }
        accentColor = resolvedAccentColor
#if !os(tvOS)
        if let colorData = ProfileSettingsStore.active.data(forKey: "readerAccentColor"),
           let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData) {
            readerAccentColor = Color(uiColor)
        } else {
            readerAccentColor = resolvedAccentColor
        }
#endif
        let resolvedAppearance = ProfileSettingsStore.active.string(forKey: "selectedAppearance")
            .flatMap(Appearance.init(rawValue:)) ?? .system
        selectedAppearance = resolvedAppearance
#if !os(tvOS)
        readerSelectedAppearance = ProfileSettingsStore.active.string(forKey: "readerSelectedAppearance")
            .flatMap(Appearance.init(rawValue:)) ?? resolvedAppearance
#endif
    }

    private func saveAccentColor(_ color: Color) {
        guard !isReloadingForProfileSwitch else { return }

        let uiColor = UIColor(color)
        do {
            let colorData = try NSKeyedArchiver.archivedData(withRootObject: uiColor, requiringSecureCoding: false)
            ProfileSettingsStore.active.set(colorData, forKey: "accentColor")
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
        guard !isReloadingForProfileSwitch else { return }
        let uiColor = UIColor(color)
        do {
            let colorData = try NSKeyedArchiver.archivedData(withRootObject: uiColor, requiringSecureCoding: false)
            ProfileSettingsStore.active.set(colorData, forKey: "readerAccentColor")
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
