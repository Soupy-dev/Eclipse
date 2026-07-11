// Created on 27/02/26.

import SwiftUI

struct FloatingSettingsButton: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                isPresented = true
            }
        }) {
            Image(systemName: "gear")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .applyLiquidGlassBackground(cornerRadius: 22)
        }
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}

#if !os(tvOS)
struct ModeSwitchButtonPulse: View {
    let isActive: Bool
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(isActive ? 0.24 : 0))
                .scaleEffect(isActive ? 1.22 : 0.45)

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [tint.opacity(0.7), tint.opacity(0.3), Color.clear],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    ),
                    lineWidth: 2
                )
                .scaleEffect(isActive ? 1.58 : 0.72)
                .opacity(isActive ? 0 : 0.7)
        }
        .opacity(isActive ? 1 : 0)
        .animation(.easeOut(duration: 0.42), value: isActive)
    }
}

struct FloatingModeSwitchButton: View {
    @AppStorage("showKanzen") private var showKanzen: Bool = false
    @AppStorage(ModeSwitchAnimationSettings.enabledKey) private var modeSwitchAnimationEnabled = ModeSwitchAnimationSettings.defaultEnabled
    @EnvironmentObject private var modeSwitchTransitionCoordinator: ModeSwitchTransitionCoordinator
    @State private var isLaunching = false
    @State private var buttonFrame: CGRect = .zero

    var body: some View {
        Button {
            switchToReaderMode()
        } label: {
            ZStack {
                ModeSwitchButtonPulse(isActive: isLaunching, tint: .orange)

                Image(systemName: "book.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(isLaunching ? -12 : 0))
                    .scaleEffect(isLaunching ? 1.16 : 1)
            }
            .frame(width: 44, height: 44)
            .applyLiquidGlassBackground(cornerRadius: 22)
            .scaleEffect(isLaunching ? 0.94 : 1)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ModeSwitchButtonOriginPreferenceKey.self,
                    value: proxy.frame(in: .named(ModeSwitchTransitionCoordinator.coordinateSpaceName))
                )
            }
        }
        .onPreferenceChange(ModeSwitchButtonOriginPreferenceKey.self) { frame in
            buttonFrame = frame
        }
        .accessibilityLabel("Switch to Reader Mode")
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
    }

    private func switchToReaderMode() {
        guard !showKanzen, !isLaunching else { return }

        guard modeSwitchAnimationEnabled else {
            showKanzen = true
            return
        }

        recordSwitchOrigin()
        modeSwitchTransitionCoordinator.beginBurst(toReaderMode: true)

#if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif

        withAnimation(.spring(response: 0.28, dampingFraction: 0.58)) {
            isLaunching = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            withAnimation(.easeInOut(duration: 0.84)) {
                showKanzen = true
            }
        }
    }

    private func recordSwitchOrigin() {
        guard buttonFrame != .zero else { return }
        modeSwitchTransitionCoordinator.record(
            origin: CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        )
    }
}
#endif

struct FloatingSettingsOverlay: View {
    @Binding var showingSettings: Bool
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .allowsHitTesting(false)
            
            HStack(spacing: 10) {
#if !os(tvOS)
                FloatingModeSwitchButton()
#endif
                FloatingSettingsButton(isPresented: $showingSettings)
            }
                .padding(.trailing, 16)
                .padding(.top, 8)
        }
    }
}
