// Reworked for the modern Eclipse appearance system.

import SwiftUI

enum AppearanceSettingsSearchTarget: String, Hashable {
    case palette
    case backgroundStyle
    case solidColorSource
    case customBackgroundColor
    case colorBleed
    case backgroundIntensity
    case interface
    case globalAppearance
    case accentColor
    case switchModeAnimation
    case animatedBackground
    case animationQuality
    case animationFrameRate
    case appPerformanceOverlay
    case hideSplashScreen
    case alternativeSeasonMenu
    case horizontalEpisodeList
    case tmdbTitleArt
    case similarTitles

    var anchorID: String {
        "appearance-settings-search-\(rawValue)"
    }

    var sectionKey: String {
        switch self {
        case .palette, .backgroundStyle, .solidColorSource, .customBackgroundColor, .colorBleed, .backgroundIntensity:
            return "theme"
        case .interface, .globalAppearance, .accentColor:
            return "interface"
        case .switchModeAnimation, .animatedBackground, .animationQuality, .animationFrameRate, .appPerformanceOverlay, .hideSplashScreen:
            return "motion"
        case .alternativeSeasonMenu, .horizontalEpisodeList, .tmdbTitleArt, .similarTitles:
            return "details"
        }
    }
}

struct AlternativeUIView: View {
    let initialSearchTarget: AppearanceSettingsSearchTarget?

    // Retained display options
    @AppStorage(MediaDetailPlatformDefaults.seasonMenuKey) private var useSeasonMenu = MediaDetailPlatformDefaults.prefersCompactSeasonMenu
    @AppStorage(MediaDetailPlatformDefaults.horizontalEpisodeListKey) private var horizontalEpisodeList = MediaDetailPlatformDefaults.prefersHorizontalEpisodes
    @AppStorage(MediaDetailTitleArtworkSettings.enabledKey) private var mediaDetailTitleArtworkEnabled = MediaDetailTitleArtworkSettings.defaultEnabled
    @AppStorage(MediaDetailSimilarTitlesSettings.enabledKey) private var mediaDetailSimilarTitlesEnabled = MediaDetailSimilarTitlesSettings.defaultEnabled

    // Layout knobs retained for Reset Appearance; their controls now live in Home Layout.
    @AppStorage(ExperimentalMediaDesignPreset.storageKey) private var experimentalDesignPreset = ExperimentalMediaDesignPreset.defaultValue.rawValue
    @AppStorage(ExperimentalHomeCardShape.storageKey) private var experimentalHomeCardShape = ExperimentalHomeCardShape.defaultValue.rawValue
    @AppStorage(ExperimentalVisualTuning.sectionSpacingScaleKey) private var experimentalSectionSpacingScale = ExperimentalVisualTuning.defaultSectionSpacingScale
    @AppStorage(ExperimentalVisualTuning.cardRadiusScaleKey) private var experimentalCardRadiusScale = ExperimentalVisualTuning.defaultCardRadiusScale
    @AppStorage(ExperimentalVisualTuning.mediaCardScaleKey) private var experimentalMediaCardScale = ExperimentalVisualTuning.defaultMediaCardScale
    @AppStorage(ExperimentalVisualTuning.glassStrengthKey) private var experimentalGlassStrength = ExperimentalVisualTuning.defaultGlassStrength
    @AppStorage(ExperimentalVisualTuning.heroHeightScaleKey) private var experimentalHeroHeightScale = ExperimentalVisualTuning.defaultHeroHeightScale
    @AppStorage(HomeAnimatedBackgroundSettings.enabledKey) private var homeAnimatedBackgroundEnabled = HomeAnimatedBackgroundSettings.defaultEnabled
    @AppStorage(HomeAnimatedBackgroundQuality.storageKey) private var homeAnimatedBackgroundQuality = HomeAnimatedBackgroundQuality.defaultValue.rawValue
    @AppStorage(HomeAnimatedBackgroundFrameRate.storageKey) private var homeAnimatedBackgroundFrameRate = HomeAnimatedBackgroundFrameRate.defaultValue.rawValue
    @AppStorage(AppPerformanceOverlaySettings.enabledKey) private var appPerformanceOverlayEnabled = AppPerformanceOverlaySettings.defaultEnabled
#if !os(tvOS)
    @AppStorage(ModeSwitchAnimationSettings.enabledKey) private var modeSwitchAnimationEnabled = ModeSwitchAnimationSettings.defaultEnabled
    @AppStorage("hideSplashScreen") private var hideSplashScreen = false
#endif

    // Interface (modern vs classic) - restart applied gate
    @AppStorage(ExperimentalFeatureState.enabledKey) private var modernInterfaceEnabled = true
    @State private var showRestartAlert = false

    @StateObject private var accentColorManager = AccentColorManager.shared
    @ObservedObject private var theme = EclipseTheme.shared
    @State private var mediaDetailElements = MediaDetailElement.orderedElements()
    @State private var hiddenMediaDetailElements = MediaDetailElement.hiddenElements()

    private var accent: Color { accentColorManager.currentAccentColor }

    init(initialSearchTarget: AppearanceSettingsSearchTarget? = nil) {
        self.initialSearchTarget = initialSearchTarget
    }

    var body: some View {
        List {
            previewSection
            customizationSection
                .eclipseExperimentalSettingsRows()
            behaviorSection
                .eclipseExperimentalSettingsRows()
            layoutAndDetailsSection
                .eclipseExperimentalSettingsRows()
            resetSection
                .eclipseExperimentalSettingsRows()
        }
        .navigationTitle("Appearance")
        .accessibilityIdentifier("tv.settings.appearance.screen")
        .eclipseSettingsStyle()
        .onAppear {
            AppPerformanceRuntimeContext.shared.setSurface("settings.appearance")
            reloadMediaDetailElements()
        }
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The interface style is applied when Eclipse launches. Restart the app to switch between the Modern and Classic layouts.")
        }
    }

    // MARK: - Appearance categories

    private var customizationSection: some View {
        Section {
            NavigationLink {
                AppearanceSettingsSubpage(title: "Theme", sectionKey: "theme", initialSearchTarget: initialSearchTarget) {
                    themeSection
                        .eclipseExperimentalSettingsRows()
                }
            } label: {
                appearanceCategoryLabel(
                    title: "Theme",
                    description: "Palette, background style, and color intensity.",
                    systemImage: "paintpalette"
                )
            }
        } header: {
            Text("Customize")
        }
    }

    private var behaviorSection: some View {
        Section {
#if !os(tvOS)
            NavigationLink {
                AppearanceSettingsSubpage(title: "Interface", sectionKey: "interface", initialSearchTarget: initialSearchTarget) {
                    interfaceSection
                        .eclipseExperimentalSettingsRows()
                }
            } label: {
                appearanceCategoryLabel(
                    title: "Interface",
                    description: "Layout style, global appearance, and accent color.",
                    systemImage: "rectangle.3.group"
                )
            }
#endif

            NavigationLink {
                AppearanceSettingsSubpage(title: "Motion & Startup", sectionKey: "motion", initialSearchTarget: initialSearchTarget) {
                    appExperienceSection
                        .eclipseExperimentalSettingsRows()
                }
            } label: {
                appearanceCategoryLabel(
                    title: "Motion & Startup",
                    description: "Mode switching, ambient background, and launch behavior.",
                    systemImage: "sparkles"
                )
            }
        } header: {
            Text("Behavior")
        }
    }

    private var layoutAndDetailsSection: some View {
        Section {
            NavigationLink {
                HomeLayoutView()
            } label: {
                appearanceCategoryLabel(
                    title: "Home Layout",
                    description: "Size and orientation of home rows, globally or per catalog.",
                    systemImage: "rectangle.grid.1x2"
                )
            }
            .accessibilityIdentifier("tv.appearance.homeLayout")

            NavigationLink {
                AppearanceSettingsSubpage(title: "Detail Pages", sectionKey: "details", initialSearchTarget: initialSearchTarget) {
                    detailPagesSection
                        .eclipseExperimentalSettingsRows()
                }
            } label: {
                appearanceCategoryLabel(
                    title: "Detail Pages",
                    description: "Season menus, episode lists, and title artwork.",
                    systemImage: "text.below.photo"
                )
            }

            NavigationLink {
                AppearanceSettingsSubpage(title: "Media Detail Layout", sectionKey: "mediaDetailLayout", initialSearchTarget: initialSearchTarget) {
                    mediaDetailSection
                        .eclipseExperimentalSettingsRows()
                }
            } label: {
                appearanceCategoryLabel(
                    title: "Media Detail Layout",
                    description: "Choose and order sections on media detail pages.",
                    systemImage: "rectangle.3.group"
                )
            }
        } header: {
            Text("Layout & Details")
        }
    }

    // MARK: - Live preview

    private var previewSection: some View {
        Section {
            AppearancePreviewCard()
                .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                .listRowBackground(Color.clear)
#if !os(tvOS)
                .listRowSeparator(.hidden)
#endif
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
                        ForEach(availablePaletteIDs) { id in
                            paletteSwatch(id)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 4)
            .id(AppearanceSettingsSearchTarget.palette.anchorID)

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
                .id(AppearanceSettingsSearchTarget.customBackgroundColor.anchorID)
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
                .id(AppearanceSettingsSearchTarget.backgroundStyle.anchorID)
            }

            if theme.atmosphereStyle == .solid {
#if !os(tvOS)
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
                    .id(AppearanceSettingsSearchTarget.solidColorSource.anchorID)
                }

                if theme.atmosphereSolidColorSource == .custom {
                    ColorPicker("Custom Background Color", selection: $theme.atmosphereSolidColor)
                        .id(AppearanceSettingsSearchTarget.customBackgroundColor.anchorID)
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
                .id(AppearanceSettingsSearchTarget.colorBleed.anchorID)

                sliderRow(
                    title: "Background Intensity",
                    description: "Lighten or deepen the overall background.",
                    value: $theme.backgroundIntensity,
                    range: AppearanceConfig.intensityRange,
                    step: 0.05
                )
                .id(AppearanceSettingsSearchTarget.backgroundIntensity.anchorID)
            }
        } header: {
            Text("Theme")
        }
    }

    // MARK: - Interface & scope

#if !os(tvOS)
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
                .id(AppearanceSettingsSearchTarget.interface.anchorID)
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
            .id(AppearanceSettingsSearchTarget.globalAppearance.anchorID)

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
            .id(AppearanceSettingsSearchTarget.accentColor.anchorID)
#endif
        } header: {
            Text("Interface & Scope")
        }
    }
#endif

    // MARK: - App experience

    private var appExperienceSection: some View {
        Section {
#if !os(tvOS)
            toggleRow(
                title: "Switch Mode Animation",
                description: "Animate the top-right Media and Reader mode switch.",
                isOn: $modeSwitchAnimationEnabled
            )
            .id(AppearanceSettingsSearchTarget.switchModeAnimation.anchorID)
#endif

            toggleRow(
                title: "Animated Background",
                description: "Show ambient motion behind broad app surfaces.",
                isOn: $homeAnimatedBackgroundEnabled
            )
            .id(AppearanceSettingsSearchTarget.animatedBackground.anchorID)

            settingRow(
                title: "Animation Quality",
                description: "Low keeps the core eclipse rings and particles. Medium adds a plasma field, starfield, orbiting embers, energy wavefronts, and a corona. High adds denser motion, a kinetic mesh, more orbiting embers, and meteor bursts."
            ) {
                Picker("", selection: $homeAnimatedBackgroundQuality) {
                    ForEach(HomeAnimatedBackgroundQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .id(AppearanceSettingsSearchTarget.animationQuality.anchorID)
            }

            settingRow(
                title: "Animation Frame Rate",
                description: "Use the battery-friendly 20 FPS default, or choose smoother 30 FPS motion across Eclipse."
            ) {
                Picker("", selection: $homeAnimatedBackgroundFrameRate) {
                    ForEach(HomeAnimatedBackgroundFrameRate.allCases) { frameRate in
                        Text(frameRate.displayName).tag(frameRate.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .id(AppearanceSettingsSearchTarget.animationFrameRate.anchorID)
            }

            toggleRow(
                title: "App Performance Overlay",
                description: "Show live CPU, GPU, thermal state, and background quality diagnostics throughout Eclipse. While visible, sparse samples and CPU spikes are added to Performance logs. Sampling and logging pause when the app is inactive or playback covers the interface.",
                isOn: $appPerformanceOverlayEnabled
            )
            .id(AppearanceSettingsSearchTarget.appPerformanceOverlay.anchorID)

#if !os(tvOS)
            toggleRow(
                title: "Hide Splash Screen",
                description: "Skip the launch splash once Eclipse opens.",
                isOn: $hideSplashScreen
            )
            .id(AppearanceSettingsSearchTarget.hideSplashScreen.anchorID)
#endif
        } header: {
            Text("App Experience")
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
            .id(AppearanceSettingsSearchTarget.alternativeSeasonMenu.anchorID)
            toggleRow(
                title: "Horizontal Episode List",
                description: "Use a horizontal instead of vertical episode list.",
                isOn: $horizontalEpisodeList
            )
            .id(AppearanceSettingsSearchTarget.horizontalEpisodeList.anchorID)
            toggleRow(
                title: "TMDB Title Art",
                description: "Use TMDB logo artwork for media titles when available.",
                isOn: $mediaDetailTitleArtworkEnabled
            )
            .id(AppearanceSettingsSearchTarget.tmdbTitleArt.anchorID)
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
#if os(tvOS)
            ForEach(Array(mediaDetailElements.enumerated()), id: \.element.id) { index, element in
                HStack(spacing: 18) {
                    mediaDetailElementRow(element)
                    VStack(spacing: 8) {
                        Button {
                            moveMediaDetailElement(at: index, by: -1)
                        } label: {
                            Label("Move Up", systemImage: "chevron.up")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(index == 0)

                        Button {
                            moveMediaDetailElement(at: index, by: 1)
                        } label: {
                            Label("Move Down", systemImage: "chevron.down")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(index == mediaDetailElements.count - 1)
                    }
                }
            }
#else
            ForEach(mediaDetailElements) { element in
                mediaDetailElementRow(element)
            }
            .onMove(perform: moveMediaDetailElements)
#endif

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
#if os(tvOS)
            Text("Use the arrow buttons to change section order. Hidden rows will not appear on media detail pages.")
#else
            Text("Drag rows to change their order. Hidden rows will not appear on media detail pages. Episodes only appear for series. Stills and Trailers appear in the Modern interface.")
#endif
        }
#if !os(tvOS)
        .environment(\.editMode, .constant(.active))
#endif
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

    private var availablePaletteIDs: [AtmospherePaletteID] {
#if os(tvOS)
        AtmospherePaletteID.allCases.filter { $0 != .custom }
#else
        AtmospherePaletteID.allCases
#endif
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

    private func appearanceCategoryLabel(
        title: String,
        description: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundColor(accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 2)
    }

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
#if os(tvOS)
            HStack(spacing: 18) {
                Button {
                    value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                } label: {
                    Label("Decrease", systemImage: "minus")
                }
                .disabled(value.wrappedValue <= range.lowerBound)

                Button {
                    value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                } label: {
                    Label("Increase", systemImage: "plus")
                }
                .disabled(value.wrappedValue >= range.upperBound)
            }
#else
            Slider(value: value, in: range, step: step)
                .tint(accent)
#endif
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
                Text(isMediaDetailElementVisible(element) ? "Visible" : "Hidden")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isMediaDetailElementVisible(element) },
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

    private func moveMediaDetailElement(at index: Int, by offset: Int) {
        let destination = index + offset
        guard mediaDetailElements.indices.contains(index), mediaDetailElements.indices.contains(destination) else { return }
        mediaDetailElements.swapAt(index, destination)
        MediaDetailElement.saveOrder(mediaDetailElements)
    }

    private func setMediaDetailElement(_ element: MediaDetailElement, visible: Bool) {
        if element == .similarTitles {
            mediaDetailSimilarTitlesEnabled = visible
        }

        if visible {
            hiddenMediaDetailElements.remove(element)
        } else {
            hiddenMediaDetailElements.insert(element)
        }
        MediaDetailElement.saveHiddenElements(hiddenMediaDetailElements)
    }

    private func isMediaDetailElementVisible(_ element: MediaDetailElement) -> Bool {
        if element == .similarTitles {
            return mediaDetailSimilarTitlesEnabled && !hiddenMediaDetailElements.contains(element)
        }
        return !hiddenMediaDetailElements.contains(element)
    }

    private func resetMediaDetailElements() {
        mediaDetailElements = MediaDetailElement.defaultOrder
        hiddenMediaDetailElements = []
        mediaDetailSimilarTitlesEnabled = MediaDetailSimilarTitlesSettings.defaultEnabled
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
        homeAnimatedBackgroundQuality = HomeAnimatedBackgroundQuality.defaultValue.rawValue
        homeAnimatedBackgroundFrameRate = HomeAnimatedBackgroundFrameRate.defaultValue.rawValue
        appPerformanceOverlayEnabled = AppPerformanceOverlaySettings.defaultEnabled
#if !os(tvOS)
        modeSwitchAnimationEnabled = ModeSwitchAnimationSettings.defaultEnabled
        hideSplashScreen = false
#endif
        mediaDetailTitleArtworkEnabled = MediaDetailTitleArtworkSettings.defaultEnabled
        mediaDetailSimilarTitlesEnabled = MediaDetailSimilarTitlesSettings.defaultEnabled
        HomeCatalogLayoutStore.shared.resetAll()
    }
}

private struct AppearanceSettingsSubpage<Content: View>: View {
    let title: String
    let sectionKey: String
    let initialSearchTarget: AppearanceSettingsSearchTarget?
    private let content: Content

    init(
        title: String,
        sectionKey: String,
        initialSearchTarget: AppearanceSettingsSearchTarget?,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.sectionKey = sectionKey
        self.initialSearchTarget = initialSearchTarget
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                content
            }
            .onAppear {
                AppPerformanceRuntimeContext.shared.setSurface("settings.\(sectionKey)")
                guard let initialSearchTarget,
                      initialSearchTarget.sectionKey == sectionKey else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        scrollProxy.scrollTo(initialSearchTarget.anchorID, anchor: .center)
                    }
                }
            }
            .onDisappear {
                AppPerformanceRuntimeContext.shared.setSurface("settings.appearance")
            }
        }
        .navigationTitle(title)
        .eclipseSettingsStyle()
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
