//
//  PlayerSettingsView.swift
//  Sora
//
//  Created by Francesco on 19/09/25.
//

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

enum InAppPlayer: String, CaseIterable, Identifiable {
    case normal = "Normal"
    case mpv = "mpv"
    case vlc = "VLC"
    
    var id: String { rawValue }
}

final class PlayerSettingsStore: ObservableObject {
    @Published var holdSpeed: Double {
        didSet { UserDefaults.standard.set(holdSpeed, forKey: "holdSpeedPlayer") }
    }
    
    @Published var externalPlayer: ExternalPlayer {
        didSet { UserDefaults.standard.set(externalPlayer.rawValue, forKey: "externalPlayer") }
    }
    
    @Published var landscapeOnly: Bool {
        didSet { UserDefaults.standard.set(landscapeOnly, forKey: "alwaysLandscape") }
    }
    
    @Published var inAppPlayer: InAppPlayer {
        didSet { UserDefaults.standard.set(inAppPlayer.rawValue, forKey: "inAppPlayer") }
    }

    @Published var aniSkipAutoSkip: Bool {
        didSet { UserDefaults.standard.set(aniSkipAutoSkip, forKey: "aniSkipAutoSkip") }
    }

    @Published var aniSkipEnabled: Bool {
        didSet { UserDefaults.standard.set(aniSkipEnabled, forKey: "aniSkipEnabled") }
    }

    @Published var introDBEnabled: Bool {
        didSet { UserDefaults.standard.set(introDBEnabled, forKey: "introDBEnabled") }
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

    @Published var nextEpisodeThreshold: Double {
        didSet { UserDefaults.standard.set(nextEpisodeThreshold, forKey: "nextEpisodeThreshold") }
    }

    init() {
        let savedSpeed = UserDefaults.standard.double(forKey: "holdSpeedPlayer")
        self.holdSpeed = savedSpeed > 0 ? savedSpeed : 2.0
        
        let raw = UserDefaults.standard.string(forKey: "externalPlayer") ?? ExternalPlayer.none.rawValue
        self.externalPlayer = ExternalPlayer(rawValue: raw) ?? .none
        
        self.landscapeOnly = UserDefaults.standard.bool(forKey: "alwaysLandscape")
        
        let inAppRaw = UserDefaults.standard.string(forKey: "inAppPlayer") ?? InAppPlayer.vlc.rawValue
        self.inAppPlayer = InAppPlayer(rawValue: inAppRaw) ?? .vlc

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

        self.skip85sEnabled = UserDefaults.standard.bool(forKey: "skip85sEnabled")
        self.skip85sAlwaysVisible = UserDefaults.standard.bool(forKey: "skip85sAlwaysVisible")

        // Default to true if key has never been set
        if UserDefaults.standard.object(forKey: "showNextEpisodeButton") == nil {
            self.showNextEpisodeButton = true
        } else {
            self.showNextEpisodeButton = UserDefaults.standard.bool(forKey: "showNextEpisodeButton")
        }

        let savedThreshold = UserDefaults.standard.double(forKey: "nextEpisodeThreshold")
        self.nextEpisodeThreshold = savedThreshold > 0 ? savedThreshold : 0.90
    }
}

struct PlayerSettingsView: View {
    @StateObject private var accentColorManager = AccentColorManager.shared
    @StateObject private var store = PlayerSettingsStore()
    @Environment(\.dismiss) private var dismiss
    @State private var subtitleTextColorName: String = "White"
    @State private var subtitleStrokeColorName: String = "Black"
    @State private var subtitleStrokeWidth: Double = 1.0
    @State private var subtitleFontSizePresetName: String = "Medium"
    @State private var subtitleVerticalOffset: Double = -6.0
    
    var body: some View {
        List {
            Section(header: Text("Default Player"), footer: Text("This settings work exclusively with the Default media player.")) {
#if !os(tvOS)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Hold Speed: %.1fx", store.holdSpeed))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("Value of long-press speed playback in the player.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    
                    Spacer()
                    
                    Stepper(value: $store.holdSpeed, in: 0.1...3, step: 0.1) {}
                }
#endif
                
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Force Landscape")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("Force landscape orientation in the video player.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $store.landscapeOnly)
                        .tint(accentColorManager.currentAccentColor)
                }
            }
            .disabled(store.externalPlayer != .none)
            .background(LunaScrollTracker())
            
            Section(header: Text("Media Player")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Media Player")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("The app must be installed and accept the provided scheme.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    
                    Picker("", selection: $store.externalPlayer) {
                        ForEach(ExternalPlayer.allCases) { player in
                            Text(player.rawValue).tag(player)
                        }
                    }
                    .pickerStyle(.menu)
                }
                
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In-App Player")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("Select the internal player software.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    
                    Picker("", selection: $store.inAppPlayer) {
                        ForEach(InAppPlayer.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            
            if store.inAppPlayer == .vlc {
                Section(header: Text("VLC Player"), footer: Text("Configure default subtitle and audio settings.")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Subtitles by Default")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            Text("Automatically load and display subtitles when available.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "enableSubtitlesByDefault") },
                            set: { UserDefaults.standard.set($0, forKey: "enableSubtitlesByDefault") }
                        ))
                        .tint(accentColorManager.currentAccentColor)
                    }

                    NavigationLink(destination: VLCLanguageSelectionView(
                        title: "Default Subtitle Language",
                        selectedLanguage: Binding(
                            get: { UserDefaults.standard.string(forKey: "defaultSubtitleLanguage") ?? "eng" },
                            set: { UserDefaults.standard.set($0, forKey: "defaultSubtitleLanguage") }
                        )
                    )) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Default Subtitle Language")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Text("Language preference for subtitles.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Text(getLanguageName(UserDefaults.standard.string(forKey: "defaultSubtitleLanguage") ?? "eng"))
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    
                    NavigationLink(destination: VLCLanguageSelectionView(
                        title: "Preferred Anime Audio",
                        selectedLanguage: Binding(
                            get: { UserDefaults.standard.string(forKey: "preferredAnimeAudioLanguage") ?? "jpn" },
                            set: { UserDefaults.standard.set($0, forKey: "preferredAnimeAudioLanguage") }
                        )
                    )) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Preferred Anime Audio")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Text("Audio language for anime content.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Text(getLanguageName(UserDefaults.standard.string(forKey: "preferredAnimeAudioLanguage") ?? "jpn"))
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }

                    HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Subtitle Text Color")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Text("Default color for custom subtitle rendering.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Picker("", selection: subtitleTextColorBinding) {
                                ForEach(subtitleTextColorOptions.map(\.name), id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Subtitle Stroke Color")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Text("Outline color for custom subtitle rendering.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Picker("", selection: subtitleStrokeColorBinding) {
                                ForEach(subtitleStrokeColorOptions.map(\.name), id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: "Subtitle Stroke Width: %.1f", subtitleStrokeWidthBinding.wrappedValue))
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Text("Outline thickness for custom subtitle rendering.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

#if os(tvOS)
                            Picker("", selection: subtitleStrokeWidthBinding) {
                                Text("0.0").tag(0.0)
                                Text("0.5").tag(0.5)
                                Text("1.0").tag(1.0)
                                Text("1.5").tag(1.5)
                                Text("2.0").tag(2.0)
                            }
                            .pickerStyle(.menu)
#else
                            Stepper("", value: subtitleStrokeWidthBinding, in: 0.0...2.0, step: 0.5)
#endif
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Subtitle Font Size")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Text("Named size presets for custom subtitle rendering.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Picker("", selection: subtitleFontSizePresetBinding) {
                                ForEach(subtitleFontSizeOptions.map(\.name), id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: "Subtitle Vertical Offset: %.0f", subtitleVerticalOffsetBinding.wrappedValue))
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Text("Numeric offset for subtitle height. Higher values place subtitles lower on screen.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

#if os(tvOS)
                            Picker("", selection: subtitleVerticalOffsetBinding) {
                                ForEach(Array(stride(from: -24, through: 24, by: 2)), id: \.self) { value in
                                    Text("\(value)").tag(Double(value))
                                }
                            }
                            .pickerStyle(.menu)
#else
                            Stepper("", value: subtitleVerticalOffsetBinding, in: -24...24, step: 1)
#endif
                        }

                        Button(action: resetVLCSubtitleStyleDefaults) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Reset Subtitle Style")
                                        .font(.subheadline)
                                        .fontWeight(.medium)

                                    Text("Restore default subtitle text color, stroke, width, and font size.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                }

                                Spacer()

                                Image(systemName: "arrow.counterclockwise")
                                    .foregroundColor(accentColorManager.currentAccentColor)
                            }
                        }
                }

                Section(header: Text("Skip Segments")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AniSkip")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Text("Fetch skip segments from AniSkip for anime content.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()

                        Toggle("", isOn: $store.aniSkipEnabled)
                            .tint(accentColorManager.currentAccentColor)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TheIntroDB")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Text("Fetch skip segments from TheIntroDB for all content.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()

                        Toggle("", isOn: $store.introDBEnabled)
                            .tint(accentColorManager.currentAccentColor)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto Skip")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Text("Automatically skip intros, outros, recaps, and previews when detected. A skip button is always shown regardless of this setting.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()

                        Toggle("", isOn: $store.aniSkipAutoSkip)
                            .tint(accentColorManager.currentAccentColor)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Skip 85s Fallback")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Text("Show a skip 85 seconds button when no skip data is returned for the current episode.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()

                        Toggle("", isOn: $store.skip85sEnabled)
                            .tint(accentColorManager.currentAccentColor)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Always Show Skip 85s")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Text("Keep the Skip 85s button visible even when skip segments are available.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()

                        Toggle("", isOn: $store.skip85sAlwaysVisible)
                            .tint(accentColorManager.currentAccentColor)
                    }
                }

                Section(header: Text("Next Episode")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Next Episode Button")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Text("Display a button near the end of an episode to quickly open stream search for the next episode.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()

                        Toggle("", isOn: $store.showNextEpisodeButton)
                            .tint(accentColorManager.currentAccentColor)
                    }

                    if store.showNextEpisodeButton {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Appearance Threshold")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Text("How far into the episode (%) before the button appears. Default is 90%.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.leading)
                            }

                            Spacer()

                            Text("\(Int(store.nextEpisodeThreshold * 100))%")
                                .foregroundColor(.secondary)
                                .font(.subheadline)

#if os(tvOS)
                            Picker("", selection: $store.nextEpisodeThreshold) {
                                ForEach(Array(stride(from: 0.50, through: 0.99, by: 0.05)), id: \.self) { value in
                                    Text("\(Int(value * 100))%").tag(value)
                                }
                            }
                            .pickerStyle(.menu)
#else
                            Stepper("", value: $store.nextEpisodeThreshold, in: 0.50...0.99, step: 0.05)
                                .frame(width: 100)
#endif
                        }
                    }
                }
            }
        }
        .navigationTitle("Media Player")
        .lunaSettingsStyle()
        .onAppear {
            let subtitleEditMenuKey = "enableVLCSubtitleEditMenu"
            let headerProxyKey = "vlcHeaderProxyEnabled"
            // Enforce these VLC flags on launch, including for previously disabled states.
            if UserDefaults.standard.object(forKey: subtitleEditMenuKey) as? Bool != true {
                UserDefaults.standard.set(true, forKey: subtitleEditMenuKey)
            }
            if UserDefaults.standard.object(forKey: headerProxyKey) as? Bool != true {
                UserDefaults.standard.set(true, forKey: headerProxyKey)
            }
            refreshVLCSubtitleStyleStateFromDefaults()
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
                subtitleStrokeWidth = $0
                UserDefaults.standard.set($0, forKey: "subtitles_strokeWidth")
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
                subtitleVerticalOffset = selectedValue
                UserDefaults.standard.set(selectedValue, forKey: "vlcSubtitleOverlayBottomConstant")
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

    private func resetVLCSubtitleStyleDefaults() {
        saveSubtitleColor(.white, forKey: "subtitles_foregroundColor")
        saveSubtitleColor(.black, forKey: "subtitles_strokeColor")
        UserDefaults.standard.set(1.0, forKey: "subtitles_strokeWidth")
        UserDefaults.standard.set(30.0, forKey: "subtitles_fontSize")
        UserDefaults.standard.set(-6.0, forKey: "vlcSubtitleOverlayBottomConstant")
        refreshVLCSubtitleStyleStateFromDefaults()
    }

    private func refreshVLCSubtitleStyleStateFromDefaults() {
        let textColor = loadSubtitleColor(forKey: "subtitles_foregroundColor", defaultColor: .white)
        subtitleTextColorName = subtitleTextColorOptions.first(where: { $0.color.isEqual(textColor) })?.name ?? "White"

        let strokeColor = loadSubtitleColor(forKey: "subtitles_strokeColor", defaultColor: .black)
        subtitleStrokeColorName = subtitleStrokeColorOptions.first(where: { $0.color.isEqual(strokeColor) })?.name ?? "Black"

        let savedStrokeWidth = UserDefaults.standard.double(forKey: "subtitles_strokeWidth")
        subtitleStrokeWidth = savedStrokeWidth >= 0 ? savedStrokeWidth : 1.0

        let savedFontSize = UserDefaults.standard.double(forKey: "subtitles_fontSize")
        let resolvedFontSize = savedFontSize > 0 ? savedFontSize : 30.0
        if let exact = subtitleFontSizeOptions.first(where: { abs($0.size - resolvedFontSize) < 0.01 }) {
            subtitleFontSizePresetName = exact.name
        } else {
            let nearest = subtitleFontSizeOptions.min(by: { abs($0.size - resolvedFontSize) < abs($1.size - resolvedFontSize) })
            subtitleFontSizePresetName = nearest?.name ?? "Medium"
        }

        let savedBottomConstant = UserDefaults.standard.double(forKey: "vlcSubtitleOverlayBottomConstant")
        subtitleVerticalOffset = UserDefaults.standard.object(forKey: "vlcSubtitleOverlayBottomConstant") != nil
            ? savedBottomConstant
            : -6.0
    }
}
