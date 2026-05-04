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
            if UserDefaults.standard.object(forKey: "vlcPiPEnabled") == nil {
                UserDefaults.standard.set(false, forKey: "vlcPiPEnabled")
            }
            return false
        }
        set { UserDefaults.standard.set(false, forKey: "vlcPiPEnabled") }
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

    var enableVLCSubtitleEditMenu: Bool {
        get {
            if UserDefaults.standard.object(forKey: "enableVLCSubtitleEditMenu") as? Bool != true {
                UserDefaults.standard.set(true, forKey: "enableVLCSubtitleEditMenu")
            }
            return true
        }
        set { UserDefaults.standard.set(true, forKey: "enableVLCSubtitleEditMenu") }
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
