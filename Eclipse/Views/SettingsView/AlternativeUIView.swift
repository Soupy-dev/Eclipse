// Reworked for the modern Eclipse appearance system.

import SwiftUI

struct AlternativeUIView: View {
    // Retained display options
    @AppStorage("seasonMenu") private var useSeasonMenu = false
    @AppStorage("horizontalEpisodeList") private var horizontalEpisodeList = false

    // Layout knobs retained for Reset Appearance; their controls now live in Home Layout.
    @AppStorage(ExperimentalMediaDesignPreset.storageKey) private var experimentalDesignPreset = ExperimentalMediaDesignPreset.defaultValue.rawValue
    @AppStorage(ExperimentalHomeCardShape.storageKey) private var experimentalHomeCardShape = ExperimentalHomeCardShape.defaultValue.rawValue
    @AppStorage(ExperimentalVisualTuning.sectionSpacingScaleKey) private var experimentalSectionSpacingScale = ExperimentalVisualTuning.defaultSectionSpacingScale
    @AppStorage(ExperimentalVisualTuning.cardRadiusScaleKey) private var experimentalCardRadiusScale = ExperimentalVisualTuning.defaultCardRadiusScale
    @AppStorage(ExperimentalVisualTuning.mediaCardScaleKey) private var experimentalMediaCardScale = ExperimentalVisualTuning.defaultMediaCardScale
    @AppStorage(ExperimentalVisualTuning.glassStrengthKey) private var experimentalGlassStrength = ExperimentalVisualTuning.defaultGlassStrength
    @AppStorage(ExperimentalVisualTuning.heroHeightScaleKey) private var experimentalHeroHeightScale = ExperimentalVisualTuning.defaultHeroHeightScale
    @AppStorage(HomeAnimatedBackgroundSettings.enabledKey) private var homeAnimatedBackgroundEnabled = HomeAnimatedBackgroundSettings.defaultEnabled
    @AppStorage(ModeSwitchAnimationSettings.enabledKey) private var modeSwitchAnimationEnabled = ModeSwitchAnimationSettings.defaultEnabled
    @AppStorage("hideSplashScreen") private var hideSplashScreen = false

    // Interface (modern vs classic) - restart applied gate
    @AppStorage(ExperimentalFeatureState.enabledKey) private var modernInterfaceEnabled = true
    @State private var showRestartAlert = false

    @StateObject private var accentColorManager = AccentColorManager.shared
    @ObservedObject private var theme = EclipseTheme.shared
    @State private var mediaDetailElements = MediaDetailElement.orderedElements()
    @State private var hiddenMediaDetailElements = MediaDetailElement.hiddenElements()

    private var accent: Color { accentColorManager.currentAccentColor }

    var body: some View {
        List {
            previewSection
            themeSection
                .eclipseExperimentalSettingsRows()
            interfaceSection
                .eclipseExperimentalSettingsRows()
            appExperienceSection
                .eclipseExperimentalSettingsRows()
            homeLayoutSection
                .eclipseExperimentalSettingsRows()
            detailPagesSection
                .eclipseExperimentalSettingsRows()
            mediaDetailSection
                .eclipseExperimentalSettingsRows()
            resetSection
                .eclipseExperimentalSettingsRows()
        }
        .navigationTitle("Appearance")
        .eclipseSettingsStyle()
        .onAppear(perform: reloadMediaDetailElements)
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The interface style is applied when Eclipse launches. Restart the app to switch between the Modern and Classic layouts.")
        }
    }

    // MARK: - Live preview

    private var previewSection: some View {
        Section {
            AppearancePreviewCard()
                .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    // MARK: - Theme

    private var themeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Palette")
                    .font(.subheadline)
                    .fontWeight(.medium)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(AtmospherePaletteID.allCases) { id in
                            paletteSwatch(id)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 4)

#if !os(tvOS)
            if theme.appearancePaletteRaw == AtmospherePaletteID.custom.rawValue {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom palette colors blend into a multi-gradient. Pick three.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ColorPicker("Color 1", selection: customColorBinding(0))
                    ColorPicker("Color 2", selection: customColorBinding(1))
                    ColorPicker("Color 3", selection: customColorBinding(2))
                }
                .padding(.vertical, 2)
            }
#endif

            settingRow(
                title: "Background Style",
                description: "Multi-gradient blends smoothly; Classic uses a single-color gradient; Solid is flat."
            ) {
                Picker("", selection: backgroundStyleBinding) {
                    Text("Multi Gradient").tag(AtmosphereStyle.multiGradient)
                    Text("Classic Gradient").tag(AtmosphereStyle.gradient)
                    Text("Solid Color").tag(AtmosphereStyle.solid)
                }
                .pickerStyle(.menu)
            }

            if theme.atmosphereStyle == .solid {
                settingRow(
                    title: "Solid Color Source",
                    description: "Use the poster's color where available, or a custom color everywhere."
                ) {
                    Picker("", selection: $theme.atmosphereSolidColorSource) {
                        ForEach(AtmosphereSolidColorSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .pickerStyle(.menu)
                }

#if !os(tvOS)
                if theme.atmosphereSolidColorSource == .custom {
                    ColorPicker("Custom Background Color", selection: $theme.atmosphereSolidColor)
                }
#endif
            }

            if theme.atmosphereStyle != .solid {
                sliderRow(
                    title: "Color Bleed",
                    description: "How strongly the banner color washes down the page.",
                    value: $theme.bleedStrength,
                    range: AppearanceConfig.bleedRange,
                    step: 0.05
                )

                sliderRow(
                    title: "Background Intensity",
                    description: "Lighten or deepen the overall background.",
                    value: $theme.backgroundIntensity,
                    range: AppearanceConfig.intensityRange,
                    step: 0.05
                )
            }
        } header: {
            Text("Theme")
        }
    }

    // MARK: - Interface & scope

    private var interfaceSection: some View {
        Section {
            settingRow(
                title: "Interface",
                description: "Modern is the redesigned look. Classic restores the original layout (requires restart)."
            ) {
                Picker("", selection: interfaceBinding) {
                    Text("Modern").tag(true)
                    Text("Classic").tag(false)
                }
                .pickerStyle(.menu)
            }

            if modernInterfaceEnabled != ExperimentalFeatureState.isEnabledAtLaunch {
                Label("Restart required to apply the interface change", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            toggleRow(
                title: "Global Appearance",
                description: "Share appearance changes between media and reader mode.",
                isOn: $theme.globalAppearanceEnabled
            )

#if !os(tvOS)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accent Color")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Affects buttons, links and other interactive elements.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                ColorPicker("", selection: $accentColorManager.currentAccentColor)
                    .labelsHidden()
                    .onChangeComp(of: accentColorManager.currentAccentColor) { _, newColor in
                        accentColorManager.saveAccentColor(newColor)
                    }
            }
#endif
        } header: {
            Text("Interface & Scope")
        }
    }

    // MARK: - App experience

    private var appExperienceSection: some View {
        Section {
            toggleRow(
                title: "Switch Mode Animation",
                description: "Animate the top-right Media and Reader mode switch.",
                isOn: $modeSwitchAnimationEnabled
            )

            toggleRow(
                title: "Animated Background",
                description: "Show ambient motion behind the home screen.",
                isOn: $homeAnimatedBackgroundEnabled
            )

            toggleRow(
                title: "Hide Splash Screen",
                description: "Skip the launch splash once Eclipse opens.",
                isOn: $hideSplashScreen
            )
        } header: {
            Text("App Experience")
        }
    }

    // MARK: - Home layout

    private var homeLayoutSection: some View {
        Section {
            NavigationLink {
                HomeLayoutView()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Home Layout")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Size and orientation of home rows - globally or per catalog.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
        } header: {
            Text("Home")
        }
    }

    // MARK: - Detail pages

    private var detailPagesSection: some View {
        Section {
            toggleRow(
                title: "Alternative Season Menu",
                description: "Dropdown menus instead of horizontal scrolls for seasons, specials and OVAs.",
                isOn: $useSeasonMenu
            )
            toggleRow(
                title: "Horizontal Episode List",
                description: "Use a horizontal instead of vertical episode list.",
                isOn: $horizontalEpisodeList
            )
        } header: {
            Text("Detail Pages")
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button(action: resetAppearance) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset Appearance")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Restore the default theme, layout, animation, and startup display values.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundColor(accent)
                }
            }
        } footer: {
            Text("Resets theme, layout, app experience, and per-catalog overrides to their defaults.")
        }
    }

    // MARK: - Media detail layout

    private var mediaDetailSection: some View {
        Section {
            ForEach(mediaDetailElements) { element in
                mediaDetailElementRow(element)
            }
            .onMove(perform: moveMediaDetailElements)

            Button(action: resetMediaDetailElements) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset Media Detail Layout")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Restore the default order and visibility.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundColor(accent)
                }
            }
        } header: {
            Text("Media Detail Page")
        } footer: {
            Text("Drag rows to change their order. Hidden rows will not appear on media detail pages. Episodes only appear for series. Stills and Trailers appear in the Modern interface.")
        }
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - Bindings

    private var backgroundStyleBinding: Binding<AtmosphereStyle> {
        Binding(
            get: {
                switch theme.atmosphereStyle {
                case .gradient: return .gradient
                case .solid: return .solid
                default: return .multiGradient
                }
            },
            set: { theme.atmosphereStyle = $0 }
        )
    }

    private var interfaceBinding: Binding<Bool> {
        Binding(
            get: { modernInterfaceEnabled },
            set: { newValue in
                ExperimentalFeatureState.setStoredValue(newValue)
                modernInterfaceEnabled = newValue
                showRestartAlert = true
            }
        )
    }

#if !os(tvOS)
    private func customColorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                let colors = theme.customPaletteColors
                if colors.indices.contains(index) { return colors[index] }
                if AppearanceConfig.defaultCustomColors.indices.contains(index) { return AppearanceConfig.defaultCustomColors[index] }
                return .purple
            },
            set: { newColor in
                var colors = theme.customPaletteColors
                while colors.count <= index { colors.append(.purple) }
                colors[index] = newColor
                theme.customPaletteColors = colors
            }
        )
    }
#endif

    // MARK: - Swatch

    private func paletteSwatch(_ id: AtmospherePaletteID) -> some View {
        let palette = AppearancePalettes.resolved(id: id, customColors: theme.customPaletteColors)
        let selected = theme.appearancePaletteRaw == id.rawValue
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                theme.appearancePaletteRaw = id.rawValue
            }
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(stops: palette.verticalStops, startPoint: .top, endPoint: .bottom))
                    .frame(width: 56, height: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(selected ? accent : Color.white.opacity(0.14), lineWidth: selected ? 2.5 : 1)
                    )
                    .scaleEffect(selected ? 1.05 : 1.0)

                Text(id.displayName)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .white : .white.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 62)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Row helpers

    private func settingRow<Trailing: View>(
        title: String,
        description: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            trailing()
        }
    }

    private func toggleRow(title: String, description: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(accent)
        }
    }

    private func sliderRow(
        title: String,
        description: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
                .tint(accent)
        }
        .padding(.vertical, 2)
    }

    private func mediaDetailElementRow(_ element: MediaDetailElement) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(element.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(element.settingsDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                Text(hiddenMediaDetailElements.contains(element) ? "Hidden" : "Visible")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { !hiddenMediaDetailElements.contains(element) },
                set: { setMediaDetailElement(element, visible: $0) }
            ))
            .labelsHidden()
            .tint(accent)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func reloadMediaDetailElements() {
        mediaDetailElements = MediaDetailElement.orderedElements()
        hiddenMediaDetailElements = MediaDetailElement.hiddenElements()
    }

    private func moveMediaDetailElements(from source: IndexSet, to destination: Int) {
        mediaDetailElements.move(fromOffsets: source, toOffset: destination)
        MediaDetailElement.saveOrder(mediaDetailElements)
    }

    private func setMediaDetailElement(_ element: MediaDetailElement, visible: Bool) {
        if visible {
            hiddenMediaDetailElements.remove(element)
        } else {
            hiddenMediaDetailElements.insert(element)
        }
        MediaDetailElement.saveHiddenElements(hiddenMediaDetailElements)
    }

    private func resetMediaDetailElements() {
        mediaDetailElements = MediaDetailElement.defaultOrder
        hiddenMediaDetailElements = []
        MediaDetailElement.saveOrder(mediaDetailElements)
        MediaDetailElement.saveHiddenElements(hiddenMediaDetailElements)
    }

    private func resetAppearance() {
        withAnimation(.easeInOut(duration: 0.25)) {
            theme.appearancePaletteRaw = AtmospherePaletteID.defaultValue.rawValue
            theme.bleedStrength = AppearanceConfig.defaultBleedStrength
            theme.backgroundIntensity = AppearanceConfig.defaultBackgroundIntensity
            theme.atmosphereMotion = AppearanceConfig.defaultMotion
            theme.customPaletteColors = AppearanceConfig.defaultCustomColors
        }
        experimentalDesignPreset = ExperimentalMediaDesignPreset.defaultValue.rawValue
        experimentalHomeCardShape = ExperimentalHomeCardShape.defaultValue.rawValue
        experimentalHeroHeightScale = ExperimentalVisualTuning.defaultHeroHeightScale
        experimentalSectionSpacingScale = ExperimentalVisualTuning.defaultSectionSpacingScale
        experimentalCardRadiusScale = ExperimentalVisualTuning.defaultCardRadiusScale
        experimentalMediaCardScale = ExperimentalVisualTuning.defaultMediaCardScale
        experimentalGlassStrength = ExperimentalVisualTuning.defaultGlassStrength
        homeAnimatedBackgroundEnabled = HomeAnimatedBackgroundSettings.defaultEnabled
        modeSwitchAnimationEnabled = ModeSwitchAnimationSettings.defaultEnabled
        hideSplashScreen = false
        HomeCatalogLayoutStore.shared.resetAll()
    }
}

// MARK: - Live preview card

private struct AppearancePreviewCard: View {
    @ObservedObject private var theme = EclipseTheme.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AtmosphereBackdrop(
                input: theme.atmosphereInput(
                    dominant: Color(red: 0.52, green: 0.24, blue: 0.66),
                    hasHeroBleed: true,
                    heroHeight: 92,
                    fadeDistance: 150
                ),
                scrollOffset: 0
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Preview")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                Text("Banner color bleeds, then the background takes over")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
            }
            .padding(14)
        }
        .frame(height: 188)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
