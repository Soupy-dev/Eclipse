import Foundation
import SwiftUI

enum SplashMotion {
    static let markSettle = Animation.spring(response: 0.72, dampingFraction: 0.78)
    static let titleReveal = Animation.easeOut(duration: 0.5)
    static let titleRevealDelay: Double = 0.66
    static let titleRise: CGFloat = 14
    static let staggerStep: Double = 0.10

    static let accentRuleWidth: CGFloat = 92
    static let accentRuleHeight: CGFloat = 2

    static let shimmerDuration: Double = 2.0
    static let shimmerDelay: Double = 0.18

    static let wordmarkColors: [Color] = [
        Color(red: 0.98, green: 0.93, blue: 1.0),
        Color(red: 0.62, green: 0.55, blue: 0.90),
        Color(red: 0.46, green: 0.70, blue: 0.92)
    ]

    static let accentRuleColors: [Color] = [
        Color(red: 0.92, green: 0.80, blue: 1.0).opacity(0.9),
        Color(red: 0.34, green: 0.74, blue: 0.88).opacity(0.42)
    ]

    static let accentRuleGlow = Color(red: 0.60, green: 0.42, blue: 0.95).opacity(0.55)

    static func stagger(_ index: Int) -> Animation {
        titleReveal.delay(Double(index) * staggerStep)
    }
}

struct SplashWordmark: View {
    let text: String
    var size: CGFloat = 32
    var shimmer: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmerPhase: CGFloat = -1

    private var travel: CGFloat { size * 3.4 }

    private var label: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .minimumScaleFactor(0.7)
            .lineLimit(1)
    }

    var body: some View {
        label
            .foregroundStyle(
                LinearGradient(
                    colors: SplashMotion.wordmarkColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay { shimmerLayer }
            .onAppear(perform: startShimmer)
    }

    @ViewBuilder
    private var shimmerLayer: some View {
        if shimmer && !reduceMotion {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.3),
                            Color.white.opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size * 0.5, height: size * 3)
                .rotationEffect(.degrees(24))
                .offset(x: shimmerPhase * travel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask { label }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func startShimmer() {
        guard shimmer, !reduceMotion, shimmerPhase < 1 else { return }
        withAnimation(
            .linear(duration: SplashMotion.shimmerDuration).delay(SplashMotion.shimmerDelay)
        ) {
            shimmerPhase = 1
        }
    }
}

struct SplashAccentRule: View {
    var trackWidth: CGFloat = SplashMotion.accentRuleWidth
    var height: CGFloat = SplashMotion.accentRuleHeight
    let fillWidth: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: trackWidth, height: height)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: SplashMotion.accentRuleColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: min(max(fillWidth, 0), trackWidth), height: height)
                .shadow(color: SplashMotion.accentRuleGlow, radius: 8, x: 0, y: 0)
        }
        .frame(width: trackWidth, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SplashReveal<Content: View>: View {
    private let index: Int
    private let enabled: Bool
    private let content: Content

    @State private var revealed = false

    init(
        index: Int,
        enabled: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.index = index
        self.enabled = enabled
        self.content = content()
    }

    var body: some View {
        if enabled {
            content
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : SplashMotion.titleRise)
                .onAppear {
                    guard !revealed else { return }
                    withAnimation(SplashMotion.stagger(index)) { revealed = true }
                }
        } else {
            content
        }
    }
}
