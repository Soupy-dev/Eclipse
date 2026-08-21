//
//  LiquidGlassBackground.swift
//  Eclipse
//
//  Created by Francesco on 02/11/25.
//

import SwiftUI

extension View {
    @ViewBuilder
    func applyLiquidGlassBackground(cornerRadius: CGFloat, fallbackFill: Color = Color.black.opacity(0.2), fallbackMaterial: Material = .ultraThinMaterial, glassTint: Color? = nil) -> some View {
#if compiler(>=6.0)
        if #available(iOS 26.0, tvOS 26.0, macOS 15.0, *) {
            self
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(alignment: .center) {
                    if let glassTint {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(glassTint)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            oldBackground(cornerRadius: cornerRadius, fallbackFill: fallbackFill, fallbackMaterial: fallbackMaterial)
        }
#else
        oldBackground(cornerRadius: cornerRadius, fallbackFill: fallbackFill, fallbackMaterial: fallbackMaterial)
#endif
    }

    @ViewBuilder
    private func oldBackground(cornerRadius: CGFloat, fallbackFill: Color, fallbackMaterial: Material) -> some View {
        #if !os(tvOS)
        if ExperimentalFeatureState.isEnabledAtLaunch {
            let glassStrength = ExperimentalVisualTuning.current.glassStrength
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.17, green: 0.14, blue: 0.24).opacity(0.50 + 0.28 * glassStrength),
                                    Color(red: 0.08, green: 0.08, blue: 0.13).opacity(0.46 + 0.24 * glassStrength)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Color.white.opacity(0.06 + 0.06 * glassStrength), lineWidth: 1)
                        )
                        .background(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(fallbackMaterial)
                        )
                )
        } else {
            legacyBackground(cornerRadius: cornerRadius, fallbackFill: fallbackFill, fallbackMaterial: fallbackMaterial)
        }
        #else
        legacyBackground(cornerRadius: cornerRadius, fallbackFill: fallbackFill, fallbackMaterial: fallbackMaterial)
        #endif
    }

    private func legacyBackground(cornerRadius: CGFloat, fallbackFill: Color, fallbackMaterial: Material) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fallbackFill)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fallbackMaterial)
                )
        )
    }
}
