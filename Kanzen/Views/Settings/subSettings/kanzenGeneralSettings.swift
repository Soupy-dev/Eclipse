//
//  GeneralView.swift
//  Kanzen
//
//  Created by Dawud Osman on 22/05/2025.
//
import SwiftUI
import UIKit

#if !os(tvOS)
struct KanzenGeneralSettingsView: View {
    @EnvironmentObject var settings: Settings
    @StateObject private var theme = EclipseTheme.shared
    @StateObject private var accentColorManager = AccentColorManager.shared
    @AppStorage("readerFontSize") private var readerFontSize: Double = 16
    @AppStorage("readerFontFamily") private var readerFontFamily = "-apple-system"
    @AppStorage("readerFontWeight") private var readerFontWeight = "normal"
    @AppStorage("readerColorPreset") private var readerColorPreset = 0
    @AppStorage("readerTextAlignment") private var readerTextAlignment = "left"
    @AppStorage("readerLineSpacing") private var readerLineSpacing: Double = 1.6
    @AppStorage("readerMargin") private var readerMargin: Double = 4
    @AppStorage("readerReadThresholdPercent") private var readerReadThresholdPercent: Double = 80
    @State private var readerDetailElements = ReaderDetailElement.orderedElements()
    @State private var hiddenReaderDetailElements = ReaderDetailElement.hiddenElements()

    private var sanitizedReaderFontSize: Double {
        Self.sanitizedSetting(readerFontSize, default: 16, range: 12...32)
    }

    private var sanitizedReaderLineSpacing: Double {
        Self.sanitizedSetting(readerLineSpacing, default: 1.6, range: 1...3)
    }

    private var sanitizedReaderMargin: Double {
        Self.sanitizedSetting(readerMargin, default: 4, range: 0...30)
    }

    private var sanitizedReaderReadThresholdPercent: Double {
        Self.sanitizedSetting(readerReadThresholdPercent, default: 80, range: 50...100)
    }

    private func sanitizedBinding(
        _ value: Binding<Double>,
        default defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Binding<Double> {
        Binding(
            get: { Self.sanitizedSetting(value.wrappedValue, default: defaultValue, range: range) },
            set: { value.wrappedValue = Self.sanitizedSetting($0, default: defaultValue, range: range) }
        )
    }

    private static func sanitizedSetting(
        _ value: Double,
        default defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    var body: some View {
        Form {
            Section(header: Text("Interface")) {
                Toggle("Global Appearance", isOn: $theme.globalAppearanceEnabled)
                    .onChange(of: theme.globalAppearanceEnabled) { _ in
                        settings.updateAppearance()
                    }

                ColorPicker("Accent Color", selection: accentColorBinding)

                HStack {
                    Text("Appearance")
                    Spacer()
                    Picker("Appearance", selection: appearanceBinding) {
                        Text("System").tag(Appearance.system)
                        Text("Light").tag(Appearance.light)
                        Text("Dark").tag(Appearance.dark)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(maxWidth: 300)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Theme Color")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack(spacing: 12) {
                        ForEach(EclipseTheme.gradientPresets, id: \.name) { preset in
                            Button {
                                gradientColorBinding.wrappedValue = preset.color
                            } label: {
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.white, lineWidth: colorsMatch(preset.color, gradientColorBinding.wrappedValue) ? 2.5 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        ColorPicker("", selection: gradientColorBinding)
                            .labelsHidden()
                    }
                }

                Picker("Atmosphere", selection: atmosphereStyleBinding) {
                    ForEach(AtmosphereStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                if atmosphereStyleBinding.wrappedValue == .solid {
                    Picker("Solid Color Source", selection: atmosphereSolidSourceBinding) {
                        ForEach(AtmosphereSolidColorSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }

                    if atmosphereSolidSourceBinding.wrappedValue == .custom {
                        ColorPicker("Custom Atmosphere Color", selection: atmosphereSolidColorBinding)
                    }
                }
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())

            Section(header: Text("Reader Text")) {
                HStack {
                    Text("Font Size")
                    Slider(
                        value: sanitizedBinding($readerFontSize, default: 16, range: 12...32),
                        in: 12...32,
                        step: 1
                    )
                    Text("\(Int(sanitizedReaderFontSize))")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Picker("Font", selection: $readerFontFamily) {
                    Text("System").tag("-apple-system")
                    Text("Serif").tag("Georgia")
                    Text("Monospace").tag("Menlo")
                    Text("Rounded").tag("ui-rounded")
                }

                Picker("Weight", selection: $readerFontWeight) {
                    Text("Regular").tag("normal")
                    Text("Medium").tag("500")
                    Text("Bold").tag("700")
                }

                Picker("Color Preset", selection: $readerColorPreset) {
                    Text("Black").tag(0)
                    Text("Sepia").tag(1)
                    Text("White").tag(2)
                }

                Picker("Text Alignment", selection: $readerTextAlignment) {
                    Text("Left").tag("left")
                    Text("Center").tag("center")
                    Text("Justified").tag("justify")
                }

                HStack {
                    Text("Line Spacing")
                    Slider(
                        value: sanitizedBinding($readerLineSpacing, default: 1.6, range: 1...3),
                        in: 1...3,
                        step: 0.1
                    )
                    Text(String(format: "%.1f", sanitizedReaderLineSpacing))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                HStack {
                    Text("Margin")
                    Slider(
                        value: sanitizedBinding($readerMargin, default: 4, range: 0...30),
                        in: 0...30,
                        step: 1
                    )
                    Text("\(Int(sanitizedReaderMargin))")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Button(action: resetReaderTextSettings) {
                    HStack {
                        Text("Reset Reader Text Defaults")
                        Spacer()
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())

            Section(
                header: Text("Reader Progress"),
                footer: Text("A chapter is marked read once you reach this percentage. This also controls when tracker progress can sync.")
            ) {
                HStack {
                    Text("Mark as Read")
                    Slider(
                        value: sanitizedBinding($readerReadThresholdPercent, default: 80, range: 50...100),
                        in: 50...100,
                        step: 5
                    )
                    Text("\(Int(sanitizedReaderReadThresholdPercent))%")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())

            Section(
                header: Text("Reader Detail Page"),
                footer: Text("Drag rows to change their order. Hidden rows will not appear on manga, manhwa, or light novel detail pages.")
            ) {
                ForEach(readerDetailElements) { element in
                    readerDetailElementRow(element)
                }
                .onMove(perform: moveReaderDetailElements)

                Button(action: resetReaderDetailElements) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset Reader Detail Layout")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Text("Restore the default order and visibility.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()

                        Image(systemName: "arrow.counterclockwise")
                            .foregroundColor(accentColorManager.currentAccentColor)
                    }
                }
            }
            .eclipseExperimentalSettingsRows()
            .environment(\.editMode, .constant(.active))
            .background(EclipseScrollTracker())
        }
        .navigationTitle(Text("Appearance"))
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
        .preferredColorScheme(.dark)
        .onAppear {
            readerFontSize = sanitizedReaderFontSize
            readerLineSpacing = sanitizedReaderLineSpacing
            readerMargin = sanitizedReaderMargin
            readerReadThresholdPercent = sanitizedReaderReadThresholdPercent
            reloadReaderDetailElements()
        }
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: {
                theme.globalAppearanceEnabled ? settings.accentColor : settings.readerAccentColor
            },
            set: { color in
                if theme.globalAppearanceEnabled {
                    settings.accentColor = color
                    accentColorManager.saveAccentColor(color)
                } else {
                    settings.readerAccentColor = color
                }
            }
        )
    }

    private var appearanceBinding: Binding<Appearance> {
        Binding(
            get: {
                theme.globalAppearanceEnabled ? settings.selectedAppearance : settings.readerSelectedAppearance
            },
            set: { appearance in
                if theme.globalAppearanceEnabled {
                    settings.selectedAppearance = appearance
                } else {
                    settings.readerSelectedAppearance = appearance
                }
            }
        )
    }

    private var gradientColorBinding: Binding<Color> {
        Binding(
            get: {
                theme.globalAppearanceEnabled ? theme.settingsGradientColor : theme.readerSettingsGradientColor
            },
            set: { color in
                if theme.globalAppearanceEnabled {
                    theme.settingsGradientColor = color
                } else {
                    theme.readerSettingsGradientColor = color
                }
            }
        )
    }

    private var atmosphereStyleBinding: Binding<AtmosphereStyle> {
        Binding(
            get: {
                theme.globalAppearanceEnabled ? theme.atmosphereStyle : theme.readerAtmosphereStyle
            },
            set: { style in
                if theme.globalAppearanceEnabled {
                    theme.atmosphereStyle = style
                } else {
                    theme.readerAtmosphereStyle = style
                }
            }
        )
    }

    private var atmosphereSolidSourceBinding: Binding<AtmosphereSolidColorSource> {
        Binding(
            get: {
                theme.globalAppearanceEnabled ? theme.atmosphereSolidColorSource : theme.readerAtmosphereSolidColorSource
            },
            set: { source in
                if theme.globalAppearanceEnabled {
                    theme.atmosphereSolidColorSource = source
                } else {
                    theme.readerAtmosphereSolidColorSource = source
                }
            }
        )
    }

    private var atmosphereSolidColorBinding: Binding<Color> {
        Binding(
            get: {
                theme.globalAppearanceEnabled ? theme.atmosphereSolidColor : theme.readerAtmosphereSolidColor
            },
            set: { color in
                if theme.globalAppearanceEnabled {
                    theme.atmosphereSolidColor = color
                } else {
                    theme.readerAtmosphereSolidColor = color
                }
            }
        )
    }

    private func colorsMatch(_ a: Color, _ b: Color) -> Bool {
        let uiA = UIColor(a)
        let uiB = UIColor(b)
        var rA: CGFloat = 0, gA: CGFloat = 0, bA: CGFloat = 0, aA: CGFloat = 0
        var rB: CGFloat = 0, gB: CGFloat = 0, bB: CGFloat = 0, aB: CGFloat = 0
        uiA.getRed(&rA, green: &gA, blue: &bA, alpha: &aA)
        uiB.getRed(&rB, green: &gB, blue: &bB, alpha: &aB)
        return abs(rA - rB) < 0.02 && abs(gA - gB) < 0.02 && abs(bA - bB) < 0.02
    }

    private func resetReaderTextSettings() {
        readerFontSize = 16
        readerFontFamily = "-apple-system"
        readerFontWeight = "normal"
        readerColorPreset = 0
        readerTextAlignment = "left"
        readerLineSpacing = 1.6
        readerMargin = 4
    }

    private func readerDetailElementRow(_ element: ReaderDetailElement) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(element.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(element.settingsDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)

                Text(hiddenReaderDetailElements.contains(element) ? "Hidden" : "Visible")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { !hiddenReaderDetailElements.contains(element) },
                set: { setReaderDetailElement(element, visible: $0) }
            ))
            .labelsHidden()
            .tint(accentColorManager.currentAccentColor)
        }
        .padding(.vertical, 4)
    }

    private func reloadReaderDetailElements() {
        readerDetailElements = ReaderDetailElement.orderedElements()
        hiddenReaderDetailElements = ReaderDetailElement.hiddenElements()
    }

    private func moveReaderDetailElements(from source: IndexSet, to destination: Int) {
        readerDetailElements.move(fromOffsets: source, toOffset: destination)
        ReaderDetailElement.saveOrder(readerDetailElements)
    }

    private func setReaderDetailElement(_ element: ReaderDetailElement, visible: Bool) {
        if visible {
            hiddenReaderDetailElements.remove(element)
        } else {
            hiddenReaderDetailElements.insert(element)
        }
        ReaderDetailElement.saveHiddenElements(hiddenReaderDetailElements)
    }

    private func resetReaderDetailElements() {
        readerDetailElements = ReaderDetailElement.defaultOrder
        hiddenReaderDetailElements = []
        ReaderDetailElement.saveOrder(readerDetailElements)
        ReaderDetailElement.saveHiddenElements(hiddenReaderDetailElements)
    }
}
#endif
