//
//  AlternativeUIView.swift
//  Sora
//
//  Created by Francesco on 20/08/25.
//

import SwiftUI

struct AlternativeUIView: View {
    @AppStorage("seasonMenu") private var useSeasonMenu = false
    @AppStorage("horizontalEpisodeList") private var horizontalEpisodeList = false
    @AppStorage("useClassicScheduleUI") private var useClassicScheduleUI = false
    
    @StateObject private var accentColorManager = AccentColorManager.shared
    @ObservedObject private var theme = LunaTheme.shared
    
    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accent Color")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("This affects buttons, links, and other interactive elements.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
#if !os(tvOS)
                    ColorPicker("", selection: $accentColorManager.currentAccentColor)
                        .onChangeComp(of: accentColorManager.currentAccentColor) { _, newColor in
                            accentColorManager.saveAccentColor(newColor)
                        }
#endif
                }
            } header: {
                Text("Interface")
            }
            .background(LunaScrollTracker())
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings Theme Color")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("Changes the gradient background color in Settings screens.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    
                    HStack(spacing: 12) {
                        ForEach(LunaTheme.gradientPresets, id: \.name) { preset in
                            Button {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    theme.settingsGradientColor = preset.color
                                }
                            } label: {
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.white, lineWidth: colorsMatch(preset.color, theme.settingsGradientColor) ? 2.5 : 0)
                                    )
                                    .scaleEffect(colorsMatch(preset.color, theme.settingsGradientColor) ? 1.15 : 1.0)
                                    .animation(.easeInOut(duration: 0.2), value: theme.settingsGradientColor)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        Spacer()
                        
#if !os(tvOS)
                        ColorPicker("", selection: $theme.settingsGradientColor)
                            .labelsHidden()
#endif
                    }
                }
            } header: {
                Text("Settings Theme")
            }
            
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alternative Season Menu")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("Use dropdown menu instead of horizontal scroll for seasons")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $useSeasonMenu)
                        .tint(accentColorManager.currentAccentColor)
                }
                
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Horizontal Episode list ")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("Use Horizontal list instead of vertical episode list")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $horizontalEpisodeList)
                        .tint(accentColorManager.currentAccentColor)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Classic Schedule Layout")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text("Use the original full schedule list instead of the compact day picker.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer()

                    Toggle("", isOn: $useClassicScheduleUI)
                        .tint(accentColorManager.currentAccentColor)
                }
            } header: {
                Text("DISPLAY OPTIONS")
            } footer: {
                Text("Classic schedule keeps the old all-days list. The alternative season menu uses a dropdown instead of a horizontal scroll for selecting seasons.")
            }
        }
        .navigationTitle("Appearance")
        .lunaSettingsStyle()
    }
    
    private func colorsMatch(_ a: Color, _ b: Color) -> Bool {
        let uiA = UIColor(a)
        let uiB = UIColor(b)
        var rA: CGFloat = 0, gA: CGFloat = 0, bA: CGFloat = 0, aA: CGFloat = 0
        var rB: CGFloat = 0, gB: CGFloat = 0, bB: CGFloat = 0, aB: CGFloat = 0
        uiA.getRed(&rA, green: &gA, blue: &bA, alpha: &aA)
        uiB.getRed(&rB, green: &gB, blue: &bB, alpha: &aB)
        return abs(rA - rB) < 0.02 && abs(gA - gB) < 0.02 && abs(bA - bB) < 0.02
    }
}
