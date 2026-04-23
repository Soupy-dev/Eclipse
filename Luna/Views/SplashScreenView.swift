//
//  SplashScreenView.swift
//  Luna
//
//  Animated moon splash screen that hides the cold boot loading.
//

import SwiftUI

struct SplashScreenView: View {
    // External signal: set true when the app content is ready
    @Binding var isFinished: Bool

    // MARK: - Animation state
    @State private var moonScale: CGFloat = 0.3
    @State private var moonOpacity: Double = 0
    @State private var glowRadius: CGFloat = 0
    @State private var glowOpacity: Double = 0
    @State private var crescentOffset: CGFloat = 40
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 12
    @State private var minimumTimeElapsed = false
    @State private var dismissing = false

    // Minimum display time so the animation doesn't flash
    private let minimumDuration: Double = 1.6

    var body: some View {
        ZStack {
            // Background
            Color(red: 0.06, green: 0.06, blue: 0.06)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Moon icon
                ZStack {
                    // Outer glow ring
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.35, green: 0.20, blue: 0.65).opacity(glowOpacity),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 30,
                                endRadius: 100
                            )
                        )
                        .frame(width: 180, height: 180)

                    // Moon body (bright crescent shape via overlay mask)
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.75, green: 0.70, blue: 0.90),
                                        Color(red: 0.50, green: 0.38, blue: 0.78)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)

                        // Crescent shadow overlay — slides in to form the moon shape
                        Circle()
                            .fill(Color(red: 0.06, green: 0.06, blue: 0.06))
                            .frame(width: 64, height: 64)
                            .offset(x: crescentOffset)
                    }
                    .shadow(color: Color(red: 0.45, green: 0.30, blue: 0.75).opacity(0.6), radius: glowRadius, x: 0, y: 0)
                }
                .scaleEffect(moonScale)
                .opacity(moonOpacity)

                // App title
                Text("Eclipse")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.75, green: 0.70, blue: 0.90),
                                Color(red: 0.55, green: 0.45, blue: 0.80)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .opacity(titleOpacity)
                    .offset(y: titleOffset)
            }
        }
        .onAppear { runEntrance() }
        .onChange(of: isFinished) { finished in
            if finished { tryDismiss() }
        }
        .onChange(of: minimumTimeElapsed) { elapsed in
            if elapsed { tryDismiss() }
        }
        .opacity(dismissing ? 0 : 1)
        .scaleEffect(dismissing ? 1.08 : 1)
    }

    // MARK: - Animate in

    private func runEntrance() {
        // Phase 1: Moon fades in and scales up
        withAnimation(.easeOut(duration: 0.6)) {
            moonScale = 1.0
            moonOpacity = 1.0
        }

        // Phase 2: Crescent forms & glow appears
        withAnimation(.easeInOut(duration: 0.8).delay(0.3)) {
            crescentOffset = 18
            glowRadius = 20
            glowOpacity = 0.7
        }

        // Phase 3: Title slides in
        withAnimation(.easeOut(duration: 0.5).delay(0.7)) {
            titleOpacity = 1.0
            titleOffset = 0
        }

        // Minimum timer
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumDuration) {
            minimumTimeElapsed = true
        }
    }

    // MARK: - Dismiss (fires as soon as BOTH conditions met)

    private func tryDismiss() {
        guard minimumTimeElapsed, isFinished, !dismissing else { return }
        withAnimation(.easeIn(duration: 0.35)) {
            dismissing = true
        }
    }
}
