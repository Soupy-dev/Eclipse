import SwiftUI

struct SplashScreenView: View {
    @Binding var isFinished: Bool
    var onDismissed: () -> Void = {}

    @State private var moonScale: CGFloat = 0.28
    @State private var moonOpacity: Double = 0
    @State private var glowRadius: CGFloat = 0
    @State private var glowOpacity: Double = 0
    @State private var crescentOffset: CGFloat = 42
    @State private var coronaScale: CGFloat = 0.78
    @State private var coronaOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 14
    @State private var accentLineWidth: CGFloat = 0
    @State private var minimumTimeElapsed = false
    @State private var dismissing = false

    @State private var ambientStarted = false
    @State private var haloScale: CGFloat = 0.9
    @State private var haloBreath: Double = 0.45
    @State private var ringRotation: Double = -34
    @State private var counterRingRotation: Double = 26
    @State private var particleDrift = false
    @State private var shimmerOffset: CGFloat = -120
    @State private var backgroundShift: CGFloat = -36
    @State private var loadingPulse = false

    private let minimumDuration: Double = 1.6

    var body: some View {
        ZStack {
            splashBackground

            VStack(spacing: 22) {
                logoStage
                    .frame(width: 206, height: 206)
                    .scaleEffect(moonScale)
                    .opacity(moonOpacity)

                titleStage
                    .opacity(titleOpacity)
                    .offset(y: titleOffset)

                SplashLoadingIndicator(active: loadingPulse)
                    .opacity(minimumTimeElapsed && !isFinished ? 1 : 0)
                    .frame(height: 20)
                    .animation(.easeInOut(duration: 0.2), value: minimumTimeElapsed && !isFinished)
            }
            .padding(.bottom, 18)
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
        .blur(radius: dismissing ? 12 : 0)
    }

    private var splashBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.024, blue: 0.034),
                    Color(red: 0.055, green: 0.045, blue: 0.078),
                    Color(red: 0.035, green: 0.035, blue: 0.047)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Color(red: 0.47, green: 0.27, blue: 0.78).opacity(0.42),
                    Color(red: 0.12, green: 0.18, blue: 0.34).opacity(0.18),
                    Color.clear
                ],
                center: .top,
                startRadius: 12,
                endRadius: 390
            )
            .offset(x: backgroundShift, y: -18)
            .blendMode(.screen)

            RadialGradient(
                colors: [
                    Color(red: 0.12, green: 0.64, blue: 0.78).opacity(0.16),
                    Color(red: 0.58, green: 0.30, blue: 0.72).opacity(0.08),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 380
            )
            .offset(x: -backgroundShift * 0.6, y: 28)
            .blendMode(.screen)

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color(red: 0.62, green: 0.50, blue: 0.95).opacity(0.14),
                            Color(red: 0.25, green: 0.78, blue: 0.86).opacity(0.08),
                            Color.white.opacity(0)
                        ],
                        center: .center
                    ),
                    lineWidth: 1
                )
                .frame(width: 560, height: 560)
                .rotationEffect(.degrees(ringRotation * 0.18))
                .opacity(0.8)

            SplashParticleField(active: particleDrift)
                .opacity(0.85)
        }
        .ignoresSafeArea()
    }

    private var logoStage: some View {
        ZStack {
            eclipseHalo

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color(red: 0.90, green: 0.82, blue: 1.0).opacity(0.55),
                            Color(red: 0.35, green: 0.76, blue: 0.90).opacity(0.24),
                            Color.white.opacity(0.04),
                            Color.white.opacity(0)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(width: 164, height: 164)
                .rotationEffect(.degrees(ringRotation))
                .opacity(coronaOpacity)

            Circle()
                .trim(from: 0.12, to: 0.74)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.88, blue: 1.0).opacity(0.72),
                            Color(red: 0.36, green: 0.72, blue: 0.92).opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(width: 138, height: 138)
                .rotationEffect(.degrees(counterRingRotation))
                .opacity(coronaOpacity)
                .scaleEffect(coronaScale)

            ForEach(0..<7, id: \.self) { index in
                SplashOrbitSpark(index: index, rotation: ringRotation)
                    .opacity(coronaOpacity)
            }

            moonMark
        }
    }

    private var eclipseHalo: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.58, green: 0.42, blue: 0.92).opacity(glowOpacity * 0.58),
                            Color(red: 0.19, green: 0.48, blue: 0.85).opacity(glowOpacity * 0.18),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 16,
                        endRadius: 112
                    )
                )
                .frame(width: 206, height: 206)
                .scaleEffect(haloScale)
                .opacity(haloBreath)

            Circle()
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                .frame(width: 126, height: 126)
                .scaleEffect(haloScale)
        }
    }

    private var moonMark: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.95, blue: 1.0),
                            Color(red: 0.68, green: 0.57, blue: 0.92),
                            Color(red: 0.28, green: 0.58, blue: 0.82)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 88, height: 88)

            Circle()
                .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
                .frame(width: 88, height: 88)

            Circle()
                .fill(Color(red: 0.035, green: 0.032, blue: 0.044))
                .frame(width: 69, height: 69)
                .offset(x: crescentOffset)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.55),
                            Color.white.opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 16, height: 96)
                .rotationEffect(.degrees(24))
                .offset(x: shimmerOffset)
                .mask(Circle().frame(width: 88, height: 88))
                .opacity(coronaOpacity * 0.65)
        }
        .shadow(color: Color(red: 0.50, green: 0.36, blue: 0.86).opacity(0.64), radius: glowRadius, x: 0, y: 0)
    }

    private var titleStage: some View {
        VStack(spacing: 10) {
            Text("Eclipse")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.93, blue: 1.0),
                            Color(red: 0.62, green: 0.55, blue: 0.90),
                            Color(red: 0.46, green: 0.70, blue: 0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 92, height: 2)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.92, green: 0.80, blue: 1.0).opacity(0.9),
                                Color(red: 0.34, green: 0.74, blue: 0.88).opacity(0.42)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: accentLineWidth, height: 2)
                    .shadow(color: Color(red: 0.60, green: 0.42, blue: 0.95).opacity(0.55), radius: 8, x: 0, y: 0)
            }
        }
    }

    private func runEntrance() {
        withAnimation(.spring(response: 0.72, dampingFraction: 0.78)) {
            moonScale = 1.0
            moonOpacity = 1.0
        }

        withAnimation(.easeInOut(duration: 0.82).delay(0.24)) {
            crescentOffset = 18
            glowRadius = 22
            glowOpacity = 0.78
            coronaScale = 1.0
            coronaOpacity = 1.0
        }

        withAnimation(.easeOut(duration: 0.5).delay(0.66)) {
            titleOpacity = 1.0
            titleOffset = 0
            accentLineWidth = 92
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.78) {
            startAmbientMotion()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + minimumDuration) {
            minimumTimeElapsed = true
        }
    }

    private func startAmbientMotion() {
        guard !ambientStarted else { return }
        ambientStarted = true

        withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
            ringRotation = 326
        }
        withAnimation(.linear(duration: 12.0).repeatForever(autoreverses: false)) {
            counterRingRotation = -334
        }
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
            haloScale = 1.08
            haloBreath = 0.9
            backgroundShift = 34
        }
        withAnimation(.linear(duration: 2.0).delay(0.18).repeatForever(autoreverses: false)) {
            shimmerOffset = 120
        }
        withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
            particleDrift = true
        }
        withAnimation(.easeInOut(duration: 0.64).delay(0.3).repeatForever(autoreverses: true)) {
            loadingPulse = true
        }
    }

    private func tryDismiss() {
        guard minimumTimeElapsed, isFinished, !dismissing else { return }
        withAnimation(.easeIn(duration: 0.35)) {
            dismissing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            onDismissed()
        }
    }
}

private struct SplashOrbitSpark: View {
    let index: Int
    let rotation: Double

    private var size: CGFloat {
        [5, 3, 4, 2, 6, 3, 4][index % 7]
    }

    private var radius: CGFloat {
        [82, 72, 88, 64, 78, 92, 70][index % 7]
    }

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.95),
                        Color(red: 0.58, green: 0.78, blue: 1.0).opacity(0.5)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size, height: size)
            .shadow(color: Color(red: 0.62, green: 0.48, blue: 1.0).opacity(0.65), radius: 5, x: 0, y: 0)
            .offset(y: -radius)
            .rotationEffect(.degrees(rotation + Double(index) * 51.4))
    }
}

private struct SplashParticleField: View {
    let active: Bool

    private let particles: [(x: CGFloat, y: CGFloat, size: CGFloat, drift: CGFloat, opacity: Double)] = [
        (-136, -260, 2, 12, 0.36),
        (118, -214, 3, -10, 0.32),
        (-92, -112, 2, 8, 0.24),
        (146, -48, 2, -14, 0.28),
        (-154, 82, 3, 10, 0.22),
        (94, 154, 2, -8, 0.26),
        (-38, 234, 2, 12, 0.20),
        (168, 246, 3, -10, 0.18)
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(particles.indices, id: \.self) { index in
                    let particle = particles[index]
                    Circle()
                        .fill(Color.white.opacity(particle.opacity))
                        .frame(width: particle.size, height: particle.size)
                        .position(x: proxy.size.width / 2 + particle.x, y: proxy.size.height / 2 + particle.y)
                        .offset(x: active ? particle.drift : -particle.drift * 0.4, y: active ? -10 : 8)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SplashLoadingIndicator: View {
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.90, green: 0.82, blue: 1.0),
                                Color(red: 0.42, green: 0.68, blue: 0.92)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: active ? 17 : 7, height: 4)
                    .opacity(active ? 0.95 : 0.36)
                    .animation(
                        .easeInOut(duration: 0.58)
                            .delay(Double(index) * 0.12)
                            .repeatForever(autoreverses: true),
                        value: active
                    )
            }
        }
    }
}
