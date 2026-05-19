//
//  Settings.swift
//  Luna
//
//  Created by Dawud Osman on 17/11/2025.
//
import SwiftUI
// helper Class & Enums
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    
    var id: String { self.rawValue }
}

enum MediaDetailElement: String, CaseIterable, Identifiable {
    case actions
    case overview
    case details
    case cast
    case ratingNotes
    case episodes

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
        .episodes
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
        case .ratingNotes:
            return "Rating & Notes"
        case .episodes:
            return "Episodes"
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
        case .ratingNotes:
            return "Your star rating, notes, and tracker sync shortcuts."
        case .episodes:
            return "Seasons, specials, and episode list for series."
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

enum MPVRenderBackend: String, CaseIterable, Identifiable {
    case openGL = "opengl"
    case metal = "metal"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openGL:
            return "OpenGL"
        case .metal:
            return "Metal"
        }
    }

    static let defaultBackend: MPVRenderBackend = .openGL
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
            return "Starts Metal sample-buffer playback at 1080p and only lowers quality if iOS reports serious thermal pressure."
        case .balanced:
            return "Renders up to 720p sample buffers, then lets iOS scale to the screen."
        case .lowHeat:
            return "Renders up to 576p sample buffers to reduce heat on risky files or warm devices."
        case .sharp:
            return "Renders up to 1080p sample buffers for a cleaner image at higher power cost."
        }
    }

    static let defaultProfile: MPVMetalQualityProfile = .auto
}

struct MPVRenderBackendSupport {
    static let bundledMPVKitVersion = "0.41.0"
    static let bundledMPVKitRevision = "3257830892c6b8cf44e0007aca2a4cef8064bc90"
    static let bundledMPVKitSupportsMoltenVKInlineRendering = true

    #if LUNA_MPVKIT_FORK_EXPOSES_METAL_SAMPLE_BUFFER_PIP
    static let forkExposesMetalSampleBufferPictureInPicture = true
    #else
    static let forkExposesMetalSampleBufferPictureInPicture = false
    #endif

    #if LUNA_MPVKIT_METAL_SAMPLE_BUFFER_PIP_IMPLEMENTED
    static let lunaImplementsMetalSampleBufferPictureInPicture = true
    #else
    static let lunaImplementsMetalSampleBufferPictureInPicture = false
    #endif

    #if LUNA_MPVKIT_METAL_BITMAP_SUBTITLES_VALIDATED
    static let metalBitmapSubtitlesValidated = true
    #else
    static let metalBitmapSubtitlesValidated = false
    #endif
    static let metalBitmapSubtitlesAllowed = true

    #if LUNA_MPVKIT_METAL_LIVE_QUALITY_RECONFIGURE
    static let metalLiveQualityReconfigurationAvailable = true
    #else
    static let metalLiveQualityReconfigurationAvailable = false
    #endif

    static var metalSampleBufferPictureInPictureAvailable: Bool {
        bundledMPVKitSupportsMoltenVKInlineRendering
            && forkExposesMetalSampleBufferPictureInPicture
            && lunaImplementsMetalSampleBufferPictureInPicture
    }

    static var metalIsFullySupported: Bool {
        metalSampleBufferPictureInPictureAvailable
    }

    static var diagnosticsSummary: String {
        [
            "mpvKit=\(bundledMPVKitVersion)",
            "revision=\(bundledMPVKitRevision)",
            "moltenVKInline=\(bundledMPVKitSupportsMoltenVKInlineRendering)",
            "forkMetalSampleBufferPiP=\(forkExposesMetalSampleBufferPictureInPicture)",
            "lunaMetalPiP=\(lunaImplementsMetalSampleBufferPictureInPicture)",
            "bitmapSubsAllowed=\(metalBitmapSubtitlesAllowed)",
            "bitmapSubsValidated=\(metalBitmapSubtitlesValidated)",
            "liveQuality=\(metalLiveQualityReconfigurationAvailable)"
        ].joined(separator: " ")
    }

    static var settingsDescription: String {
        if metalIsFullySupported {
            return "Applies to the next player session. Metal sample-buffer playback is experimental in this build; switch back to OpenGL if a stream misbehaves."
        }
        return "Applies to the next player session. OpenGL is active in this build; Metal is remembered but falls back until the MPVKit fork exposes full sample-buffer PiP."
    }

    static var settingsStatusLine: String {
        if metalIsFullySupported {
            return "Metal backend: experimental sample-buffer PiP available"
        }
        return "Metal backend: waiting for MPVKit fork sample-buffer PiP"
    }

    static func effectiveBackend(requested: MPVRenderBackend, hasMetalDevice: Bool) -> MPVRenderBackend {
        guard requested == .metal else { return .openGL }
        guard hasMetalDevice, metalIsFullySupported else { return .openGL }
        return .metal
    }

    static func fallbackReason(requested: MPVRenderBackend, hasMetalDevice: Bool) -> String? {
        guard requested == .metal else { return nil }
        guard hasMetalDevice else { return "Metal device unavailable" }
        guard forkExposesMetalSampleBufferPictureInPicture else {
            return "MPVKit \(bundledMPVKitVersion) bundled in this build does not expose Metal sample-buffer PiP frames"
        }
        guard lunaImplementsMetalSampleBufferPictureInPicture else {
            return "Luna Metal sample-buffer PiP adapter is not enabled in this build"
        }
        return nil
    }
}

class Settings: ObservableObject {
    static let shared = Settings()
    
    @Published var accentColor: Color {
        didSet {
            saveAccentColor(accentColor)
        }
    }
    @Published var selectedAppearance: Appearance {
        didSet {
            UserDefaults.standard.set(selectedAppearance.rawValue, forKey: "selectedAppearance")
            updateAppearance()
        }
    }
    
    // VLC Player Settings
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

    var vlcBrightnessGestureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "vlcBrightnessGestureEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "vlcBrightnessGestureEnabled") }
    }

    var vlcVolumeGestureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "vlcVolumeGestureEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "vlcVolumeGestureEnabled") }
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

    var vlcDoubleTapSeekEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "vlcDoubleTapSeekEnabled") == nil {
                UserDefaults.standard.set(true, forKey: "vlcDoubleTapSeekEnabled")
            }
            return UserDefaults.standard.bool(forKey: "vlcDoubleTapSeekEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "vlcDoubleTapSeekEnabled") }
    }

    var vlcDoubleTapSeekSeconds: Double {
        get {
            let savedSeconds = UserDefaults.standard.double(forKey: "vlcDoubleTapSeekSeconds")
            return savedSeconds > 0 ? savedSeconds : 10.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "vlcDoubleTapSeekSeconds") }
    }

    var vlcPiPEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "vlcPiPEnabled") as? Bool != false {
                UserDefaults.standard.set(false, forKey: "vlcPiPEnabled")
            }
            return false
        }
        set {
            if UserDefaults.standard.object(forKey: "vlcPiPEnabled") as? Bool != false {
                UserDefaults.standard.set(false, forKey: "vlcPiPEnabled")
            }
        }
    }

    var vlcOpenSubtitlesEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "vlcOpenSubtitlesEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "vlcOpenSubtitlesEnabled") }
    }

    var vlcOpenSubtitlesAutoFallbackEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "vlcOpenSubtitlesAutoFallbackEnabled") == nil {
                UserDefaults.standard.set(true, forKey: "vlcOpenSubtitlesAutoFallbackEnabled")
            }
            return UserDefaults.standard.bool(forKey: "vlcOpenSubtitlesAutoFallbackEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "vlcOpenSubtitlesAutoFallbackEnabled") }
    }

    var playerPerformanceOverlayEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "playerPerformanceOverlayEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "playerPerformanceOverlayEnabled") }
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
            let raw = UserDefaults.standard.string(forKey: "mpvRenderBackend")
                ?? MPVRenderBackend.defaultBackend.rawValue
            return MPVRenderBackend(rawValue: raw) ?? .defaultBackend
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "mpvRenderBackend")
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

    var smartInAppPlayerChoosingEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "smartInAppPlayerChoosingEnabled") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "smartInAppPlayerChoosingEnabled") }
    }

    var enableVLCSubtitleEditMenu: Bool {
        get {
            UserDefaults.standard.object(forKey: "enableVLCSubtitleEditMenu") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "enableVLCSubtitleEditMenu") }
    }
    
    enum PlayerChoice: String {
        case mpv, vlc
    }
    
    var playerChoice: PlayerChoice {
        get {
            // Read from inAppPlayer setting used in PlayerSettingsView
            let inAppRaw = UserDefaults.standard.string(forKey: "inAppPlayer") ?? "VLC"
            switch inAppRaw {
            case "VLC":
                return .vlc
            case "mpv":
                return .mpv
            default:
                // "Normal" uses native iOS player, not PlayerViewController
                // This should not be called when Normal is selected
                return .mpv  // Fallback
            }
        }
        set {
            // Sync back to inAppPlayer setting
            let inAppValue: String
            switch newValue {
            case .vlc:
                inAppValue = "VLC"
            case .mpv:
                inAppValue = "mpv"
            }
            UserDefaults.standard.set(inAppValue, forKey: "inAppPlayer")
        }
    }
    
    init() {
        if let colorData = UserDefaults.standard.data(forKey: "accentColor"),
           let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData) {
            self.accentColor = Color(uiColor)
        } else {
            self.accentColor = .accentColor
        }
        if let appearanceRawValue = UserDefaults.standard.string(forKey: "selectedAppearance"),
           let appearance = Appearance(rawValue: appearanceRawValue) {
            self.selectedAppearance = appearance
        } else {
            self.selectedAppearance = .system
        }
        updateAppearance()
    }
    
    private func saveAccentColor(_ color: Color) {
        
        let uiColor = UIColor(color)
        do {
            let colorData = try NSKeyedArchiver.archivedData(withRootObject: uiColor, requiringSecureCoding: false)
            UserDefaults.standard.set(colorData, forKey: "accentColor")
        } catch {
            Logger.shared.log("Failed to save accent color: \(error.localizedDescription)")
        }
    }
    
    func updateAppearance() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        switch selectedAppearance {
        case .system:
            windowScene.windows.first?.overrideUserInterfaceStyle = .unspecified
        case .light:
            windowScene.windows.first?.overrideUserInterfaceStyle = .light
        case .dark:
            windowScene.windows.first?.overrideUserInterfaceStyle = .dark
        }
    }
}
