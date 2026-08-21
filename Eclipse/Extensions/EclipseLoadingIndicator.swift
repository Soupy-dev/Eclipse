import SwiftUI

struct EclipseLoadingIndicator: View {
    var tint: Color
    var diameter: CGFloat
    var label: String?

    init(tint: Color = .accentColor, diameter: CGFloat = 26, label: String? = nil) {
        self.tint = tint
        self.diameter = diameter
        self.label = label
    }

    init(_ label: String, tint: Color = .accentColor, diameter: CGFloat = 26) {
        self.init(tint: tint, diameter: diameter, label: label)
    }

    var body: some View {
        if let label {
            VStack(spacing: 12) {
                EclipseLoadingSpinner(tint: tint, diameter: diameter)
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            EclipseLoadingSpinner(tint: tint, diameter: diameter)
        }
    }
}

private struct EclipseLoadingSpinner: View {
    let tint: Color
    let diameter: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0
    @State private var counterRotation: Double = 0
    @State private var pulse = false

    private var lineWidth: CGFloat { max(2.4, diameter * 0.12) }

    var body: some View {
        ZStack {

            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.32), tint.opacity(0.0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 0.9
                    )
                )
                .frame(width: diameter * 1.75, height: diameter * 1.75)
                .scaleEffect(pulse ? 1.12 : 0.78)
                .opacity(pulse ? 0.15 : 0.9)
                .blendMode(.plusLighter)

            Circle()
                .stroke(tint.opacity(0.15), lineWidth: lineWidth)
                .frame(width: diameter, height: diameter)

            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(
                    tint.opacity(0.45),
                    style: StrokeStyle(lineWidth: lineWidth * 0.7, lineCap: .round)
                )
                .frame(width: diameter * 0.66, height: diameter * 0.66)
                .rotationEffect(.degrees(counterRotation))

            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            tint.opacity(0.0),
                            tint.opacity(0.55),
                            tint,
                            Color.white
                        ]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(rotation))
                .shadow(color: tint.opacity(0.6), radius: lineWidth * 0.8)
        }
        .frame(width: diameter * 1.75, height: diameter * 1.75)
        .onAppear(perform: start)
    }

    private func start() {
        guard !reduceMotion else {

            pulse = true
            return
        }
        withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
            rotation = 360
        }
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
            counterRotation = -360
        }
        withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 40) {
            EclipseLoadingIndicator()
            EclipseLoadingIndicator(tint: .white, diameter: 40)
            EclipseLoadingIndicator("Loading source…", tint: .cyan)
        }
    }
}
