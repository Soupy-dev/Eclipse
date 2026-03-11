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
