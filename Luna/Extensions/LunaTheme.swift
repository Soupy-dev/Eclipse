//
//  LunaTheme.swift
//  Luna
//
//  Theme system with customizable gradient colors
//

import SwiftUI

class LunaTheme: ObservableObject {
    static let shared = LunaTheme()
    
    // MARK: - Persisted Settings
    
    @Published var settingsGradientColor: Color {
        didSet { saveGradientColor(settingsGradientColor) }
    }
    
    // MARK: - Constants
    
    let cardCornerRadius: CGFloat = 16
    let backgroundBase = Color(red: 0.08, green: 0.08, blue: 0.08)
    let cardBackground = Color.white.opacity(0.08)
    let separatorColor = Color.white.opacity(0.12)
    let sectionHeaderColor = Color.white.opacity(0.5)
    
    // MARK: - Presets
    
    static let gradientPresets: [(name: String, color: Color)] = [
        ("Purple", Color(red: 0.25, green: 0.12, blue: 0.45)),
        ("Blue", Color(red: 0.10, green: 0.15, blue: 0.40)),
        ("Teal", Color(red: 0.08, green: 0.28, blue: 0.30)),
        ("Red", Color(red: 0.38, green: 0.10, blue: 0.12)),
        ("Green", Color(red: 0.10, green: 0.28, blue: 0.14))
    ]
    
    // MARK: - Init
    
    private init() {
        self.settingsGradientColor = Self.gradientPresets[0].color
        self.settingsGradientColor = loadGradientColor() ?? Self.gradientPresets[0].color
    }
    
    // MARK: - Persistence
    
    private func saveGradientColor(_ color: Color) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: UIColor(color), requiringSecureCoding: true)
            UserDefaults.standard.set(data, forKey: "lunaThemeGradientColor")
        } catch {
            // Silently fail — default will be used next launch
        }
    }
    
    private func loadGradientColor() -> Color? {
        guard let data = UserDefaults.standard.data(forKey: "lunaThemeGradientColor"),
              !data.isEmpty else { return nil }
        do {
            if let uiColor = try NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) {
                return Color(uiColor)
            }
        } catch { }
        return nil
    }
}

// MARK: - View Modifiers

extension View {
    /// Apply the standard dark base background used across all screens
    func lunaBackground() -> some View {
        self.background(LunaTheme.shared.backgroundBase.ignoresSafeArea())
    }
    
    /// Apply the gradient background used in Settings screens
    func lunaGradientBackground() -> some View {
        self.background(
            SettingsGradientBackground()
                .ignoresSafeArea()
        )
    }
    
    /// Apply Luna styling to any List-based settings sub-view:
    /// gradient background, transparent list style, dark toolbar
    func lunaSettingsStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .lunaGradientBackground()
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
