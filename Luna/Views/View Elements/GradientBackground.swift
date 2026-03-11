//
//  GradientBackground.swift
//  Luna
//
//  Gradient background for Settings screens
//

import SwiftUI

struct SettingsGradientBackground: View {
    @ObservedObject private var theme = LunaTheme.shared
    
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: theme.settingsGradientColor.opacity(0.6), location: 0.0),
                .init(color: theme.settingsGradientColor.opacity(0.3), location: 0.3),
                .init(color: theme.backgroundBase, location: 0.7)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct GlobalGradientBackground: View {
    @ObservedObject private var theme = LunaTheme.shared
    var overrideColor: Color? = nil
    
    private var gradientColor: Color {
        overrideColor ?? theme.globalGradientColor
    }
    
    var body: some View {
        if theme.globalGradientEnabled || overrideColor != nil {
            LinearGradient(
                stops: [
                    .init(color: gradientColor.opacity(0.45), location: 0.0),
                    .init(color: gradientColor.opacity(0.2), location: 0.25),
                    .init(color: theme.backgroundBase, location: 0.55)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            theme.backgroundBase
        }
    }
}
