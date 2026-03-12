//
//  GradientBackground.swift
//  Luna
//
//  Gradient background for Settings screens
//

import SwiftUI

// MARK: - Scroll Offset Tracking

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct SettingsGradientBackground: View {
    @ObservedObject private var theme = LunaTheme.shared
    var scrollOffset: CGFloat = 0
    
    // The gradient is taller than the screen and physically offset upward
    // as the user scrolls, so the color band visibly moves with the content.
    private var gradientOffset: CGFloat {
        -scrollOffset * 0.35
    }
    
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height * 2.5
            LinearGradient(
                stops: [
                    .init(color: theme.backgroundBase, location: 0.0),
                    .init(color: theme.settingsGradientColor.opacity(0.6), location: 0.15),
                    .init(color: theme.settingsGradientColor.opacity(0.3), location: 0.35),
                    .init(color: theme.backgroundBase, location: 0.6)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: h)
            .offset(y: gradientOffset)
        }
        .clipped()
    }
}

/// Drop inside any scrollable container (ScrollView/List content)
/// to emit scroll offset for gradient tracking.
struct LunaScrollTracker: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ScrollOffsetPreferenceKey.self,
                value: -geo.frame(in: .named("lunaGradientScroll")).origin.y
            )
        }
        .frame(height: 0)
    }
}

struct GlobalGradientBackground: View {
    @ObservedObject private var theme = LunaTheme.shared
    var overrideColor: Color? = nil
    var scrollOffset: CGFloat = 0
    
    private var gradientColor: Color {
        overrideColor ?? theme.settingsGradientColor
    }
    
    private var gradientOffset: CGFloat {
        -scrollOffset * 0.15
    }
    
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height * 5.0
            LinearGradient(
                stops: [
                    .init(color: theme.backgroundBase, location: 0.0),
                    .init(color: gradientColor.opacity(0.7), location: 0.06),
                    .init(color: gradientColor.opacity(0.4), location: 0.15),
                    .init(color: gradientColor.opacity(0.15), location: 0.3),
                    .init(color: gradientColor.opacity(0.05), location: 0.5),
                    .init(color: theme.backgroundBase, location: 0.7)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: h)
            .offset(y: gradientOffset)
        }
        .clipped()
    }
}
