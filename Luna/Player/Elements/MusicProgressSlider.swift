//
//  MusicProgressSlider.swift
//  Custom Seekbar
//
//  Created by Pratik on 08/01/23.
//
//  Thanks to pratikg29 for this code inside his open source project "https://github.com/pratikg29/Custom-Slider-Control?ref=iosexample.com"
//  I did edit some of the code for my liking (added a buffer indicator, etc.)

import SwiftUI

struct MusicProgressSlider<T: BinaryFloatingPoint>: View {
    @Binding var value: T
    let inRange: ClosedRange<T>
    let activeFillColor: Color
    let fillColor: Color
    let textColor: Color
    let emptyColor: Color
    let height: CGFloat
    let durationKnown: Bool
    /// Normalized 0-1 skip segment ranges to render as yellow overlays.
    let segments: [(start: Double, end: Double)]
    let onEditingChanged: (Bool) -> Void
    
    @State private var localRealProgress: T = 0
    @State private var localTempProgress: T = 0
    @GestureState private var isActive: Bool = false
    @State private var progressDuration: T = 0

    
    init(
        value: Binding<T>,
        inRange: ClosedRange<T>,
        activeFillColor: Color,
        fillColor: Color,
        textColor: Color,
        emptyColor: Color,
        height: CGFloat,
        durationKnown: Bool = true,
        segments: [(start: Double, end: Double)] = [],
        onEditingChanged: @escaping (Bool) -> Void
    ) {
        self._value = value
        self.inRange = inRange
        self.activeFillColor = activeFillColor
        self.fillColor = fillColor
        self.textColor = textColor
        self.emptyColor = emptyColor
        self.height = height
        self.durationKnown = durationKnown
        self.segments = segments
        self.onEditingChanged = onEditingChanged
    }
    
    var body: some View {
        GeometryReader { bounds in
            ZStack {
                Color.clear
                    .allowsHitTesting(false)
                VStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        // Background capsule
                        Capsule()
                            .fill(.ultraThinMaterial)

                        // Yellow skip-segment overlays
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                            let segStart = CGFloat(max(0, min(seg.start, 1)))
                            let segEnd = CGFloat(max(0, min(seg.end, 1)))
                            let segWidth = max((segEnd - segStart) * bounds.size.width, 2)
                            Rectangle()
                                .fill(Color.yellow.opacity(0.55))
                                .frame(width: segWidth)
                                .offset(x: segStart * bounds.size.width)
                        }

                        // Progress fill
                        Capsule()
                            .fill(isActive ? activeFillColor : fillColor)
                            .mask({
                                HStack {
                                    Rectangle()
                                        .frame(
                                            width: max(
                                                bounds.size.width * CGFloat(localRealProgress + localTempProgress),
                                                0
                                            ),
                                            alignment: .leading
                                        )
                                    Spacer(minLength: 0)
                                }
                            })
                    }
                    .clipShape(Capsule())
                    
                    HStack {
                        Text(timeString(from: progressDuration))
                        Spacer(minLength: 0)
                        Text(displayDurationIsKnown ? "-" + timeString(from: (inRange.upperBound - progressDuration)) : "--:--")
                    }
                    .font(.system(size: 12.5))
                    .foregroundColor(textColor)
                }
                .frame(width: isActive ? bounds.size.width * 1.04 : bounds.size.width, alignment: .center)
                .animation(animation, value: isActive)
            }
            .frame(width: bounds.size.width, height: bounds.size.height, alignment: .center)
            .contentShape(Rectangle())
            #if !os(tvOS)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($isActive) { _, state, _ in
                        state = true
                    }
                    .onChanged { gesture in
                        localTempProgress = T(gesture.translation.width / bounds.size.width)
                        let prg = max(min((localRealProgress + localTempProgress), 1), 0)
                        progressDuration = inRange.upperBound * prg
                        value = max(min(getPrgValue(), inRange.upperBound), inRange.lowerBound)
                    }
                    .onEnded { _ in
                        localRealProgress = max(min(localRealProgress + localTempProgress, 1), 0)
                        localTempProgress = 0
                    }
            )
            #endif
            .onChangeComp(of: isActive) { _, newValue in
                value = max(min(getPrgValue(), inRange.upperBound), inRange.lowerBound)
                onEditingChanged(newValue)
            }
            .onAppear {
                localRealProgress = getPrgPercentage(value)
                progressDuration = inRange.upperBound * localRealProgress
            }
            .onChangeComp(of: value) { _, newValue in
                if !isActive {
                    localRealProgress = getPrgPercentage(newValue)
                    progressDuration = inRange.upperBound * localRealProgress
                }
            }
        }
        .frame(height: isActive ? height * 1.25 : height, alignment: .center)
    }
        
    private var animation: Animation {
        if isActive {
            return .spring()
        } else {
            return .spring(response: 0.5, dampingFraction: 0.5, blendDuration: 0.6)
        }
    }

    private var displayDurationIsKnown: Bool {
        let upper = Double(inRange.upperBound)
        return durationKnown && upper.isFinite && upper > 1.5
    }
    
    private func getPrgPercentage(_ value: T) -> T {
        let range = inRange.upperBound - inRange.lowerBound
        let rangeDouble = Double(range)
        if !rangeDouble.isFinite || abs(rangeDouble) <= .ulpOfOne {
            Logger.shared.log("[MusicProgressSlider.math] invalid range in getPrgPercentage range=\(rangeDouble)", type: "Error")
            return 0
        }

        let correctedStartValue = value - inRange.lowerBound
        let percentage = correctedStartValue / range
        let clamped = max(min(percentage, 1), 0)
        let clampedDouble = Double(clamped)
        if !clampedDouble.isFinite {
            Logger.shared.log("[MusicProgressSlider.math] non-finite clamped percentage value=\(Double(value)) range=\(rangeDouble)", type: "Error")
            return 0
        }
        return clamped
    }
    
    private func getPrgValue() -> T {
        let candidate = ((localRealProgress + localTempProgress) * (inRange.upperBound - inRange.lowerBound)) + inRange.lowerBound
        let candidateDouble = Double(candidate)
        if !candidateDouble.isFinite {
            Logger.shared.log("[MusicProgressSlider.math] non-finite candidate localReal=\(Double(localRealProgress)) localTemp=\(Double(localTempProgress)) rangeEnd=\(Double(inRange.upperBound))", type: "Error")
            return inRange.lowerBound
        }
        return candidate
    }
    
    private func timeString(from value: T) -> String {
        let seconds = Double(value)
        guard seconds.isFinite && seconds > 0 else { return "00:00" }
        let total = Int(round(seconds))
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}
