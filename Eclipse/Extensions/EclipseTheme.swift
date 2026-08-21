import SwiftUI

enum AtmosphereStyle: String, CaseIterable, Identifiable {
    case gradient
    case multiGradient
    case aurora
    case ember
    case solid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gradient: return "Gradient"
        case .multiGradient: return "Multi Gradient"
        case .aurora: return "Aurora"
        case .ember: return "Ember"
        case .solid: return "Solid Color"
        }
    }

    var isMultiGradient: Bool {
        switch self {
        case .multiGradient, .aurora, .ember:
            return true
        case .gradient, .solid:
            return false
        }
    }
}

enum AtmosphereSolidColorSource: String, CaseIterable, Identifiable {
    case dominant
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dominant: return "Poster Dominant"
        case .custom: return "Custom Color"
        }
    }
}

enum HeroBannerBehavior: String, CaseIterable, Identifiable {
    case `static`
    case carousel
    case launch

    var id: String { rawValue }

    static let defaultValue: HeroBannerBehavior = .carousel

    static let selectableCases: [HeroBannerBehavior] = [.static, .carousel]

    var displayName: String {
        switch self {
        case .static: return "Static"
        case .carousel: return "Carousel"
        case .launch: return "Change on App Launch"
        }
    }
}

class EclipseTheme: ObservableObject {
    static let shared = EclipseTheme()

    private var isReloadingForProfileSwitch = false

#if !os(tvOS)
    @Published var globalAppearanceEnabled: Bool {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(globalAppearanceEnabled, forKey: "readerGlobalAppearanceEnabled") }
    }
#endif

    @Published var settingsGradientColor: Color {
        didSet { guard !isReloadingForProfileSwitch else { return }; saveColor(settingsGradientColor, key: "eclipseThemeGradientColor") }
    }

#if !os(tvOS)
    @Published var readerSettingsGradientColor: Color {
        didSet { guard !isReloadingForProfileSwitch else { return }; saveColor(readerSettingsGradientColor, key: "readerThemeGradientColor") }
    }
#endif

    @Published var atmosphereStyle: AtmosphereStyle {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(atmosphereStyle.rawValue, forKey: "atmosphereStyle") }
    }

#if !os(tvOS)
    @Published var readerAtmosphereStyle: AtmosphereStyle {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(readerAtmosphereStyle.rawValue, forKey: "readerAtmosphereStyle") }
    }
#endif

    @Published var atmosphereSolidColorSource: AtmosphereSolidColorSource {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(atmosphereSolidColorSource.rawValue, forKey: "atmosphereSolidColorSource") }
    }

#if !os(tvOS)
    @Published var readerAtmosphereSolidColorSource: AtmosphereSolidColorSource {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(readerAtmosphereSolidColorSource.rawValue, forKey: "readerAtmosphereSolidColorSource") }
    }
#endif

    @Published var atmosphereSolidColor: Color {
        didSet { guard !isReloadingForProfileSwitch else { return }; saveColor(atmosphereSolidColor, key: "atmosphereSolidColor") }
    }

#if !os(tvOS)
    @Published var readerAtmosphereSolidColor: Color {
        didSet { guard !isReloadingForProfileSwitch else { return }; saveColor(readerAtmosphereSolidColor, key: "readerAtmosphereSolidColor") }
    }
#endif

    @Published var appearancePaletteRaw: String {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(appearancePaletteRaw, forKey: AppearanceConfig.paletteKey) }
    }

#if !os(tvOS)
    @Published var readerAppearancePaletteRaw: String {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(readerAppearancePaletteRaw, forKey: AppearanceConfig.readerPaletteKey) }
    }
#endif

    @Published var bleedStrength: Double {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(bleedStrength, forKey: AppearanceConfig.bleedStrengthKey) }
    }

#if !os(tvOS)
    @Published var readerBleedStrength: Double {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(readerBleedStrength, forKey: AppearanceConfig.readerBleedStrengthKey) }
    }
#endif

    @Published var backgroundIntensity: Double {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(backgroundIntensity, forKey: AppearanceConfig.backgroundIntensityKey) }
    }

#if !os(tvOS)
    @Published var readerBackgroundIntensity: Double {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(readerBackgroundIntensity, forKey: AppearanceConfig.readerBackgroundIntensityKey) }
    }
#endif

    @Published var atmosphereMotion: Double {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(atmosphereMotion, forKey: AppearanceConfig.motionKey) }
    }

#if !os(tvOS)
    @Published var readerAtmosphereMotion: Double {
        didSet { guard !isReloadingForProfileSwitch else { return }; ProfileSettingsStore.active.set(readerAtmosphereMotion, forKey: AppearanceConfig.readerMotionKey) }
    }
#endif

    @Published var customPaletteColors: [Color] {
        didSet {
            guard !isReloadingForProfileSwitch else { return }
            if let data = AppearanceConfig.encodeColors(customPaletteColors) {
                ProfileSettingsStore.active.set(data, forKey: AppearanceConfig.customColorsKey)
            }
        }
    }

#if !os(tvOS)
    @Published var readerCustomPaletteColors: [Color] {
        didSet {
            guard !isReloadingForProfileSwitch else { return }
            if let data = AppearanceConfig.encodeColors(readerCustomPaletteColors) {
                ProfileSettingsStore.active.set(data, forKey: AppearanceConfig.readerCustomColorsKey)
            }
        }
    }
#endif

    let cardCornerRadius: CGFloat = 16

    var backgroundBase: Color {
        #if !os(tvOS)
        if ExperimentalFeatureState.isEnabledAtLaunch {
            return Color(red: 0.070, green: 0.060, blue: 0.095)
        }
        #endif
        return Color(red: 0.08, green: 0.08, blue: 0.08)
    }

    var cardBackground: Color {
        #if !os(tvOS)
        if ExperimentalFeatureState.isEnabledAtLaunch {
            return Color(red: 0.12, green: 0.105, blue: 0.17).opacity(0.72)
        }
        #endif
        return Color.white.opacity(0.08)
    }

    var separatorColor: Color {
        #if !os(tvOS)
        if ExperimentalFeatureState.isEnabledAtLaunch {
            return Color.white.opacity(0.10)
        }
        #endif
        return Color.white.opacity(0.12)
    }

    var sectionHeaderColor: Color {
        #if !os(tvOS)
        if ExperimentalFeatureState.isEnabledAtLaunch {
            return Color.white.opacity(0.58)
        }
        #endif
        return Color.white.opacity(0.5)
    }

    static let gradientPresets: [(name: String, color: Color)] = [
        ("Purple", Color(red: 0.25, green: 0.12, blue: 0.45)),
        ("Blue", Color(red: 0.10, green: 0.15, blue: 0.40)),
        ("Teal", Color(red: 0.08, green: 0.28, blue: 0.30)),
        ("Red", Color(red: 0.38, green: 0.10, blue: 0.12)),
        ("Green", Color(red: 0.10, green: 0.28, blue: 0.14))
    ]

    private init() {
        AppearanceConfig.migrateIfNeeded()
        let styleRaw = ProfileSettingsStore.active.string(forKey: "atmosphereStyle") ?? Self.defaultAtmosphereStyle.rawValue
        let sourceRaw = ProfileSettingsStore.active.string(forKey: "atmosphereSolidColorSource") ?? AtmosphereSolidColorSource.dominant.rawValue
#if !os(tvOS)
        let readerStyleRaw = ProfileSettingsStore.active.string(forKey: "readerAtmosphereStyle") ?? styleRaw
        let readerSourceRaw = ProfileSettingsStore.active.string(forKey: "readerAtmosphereSolidColorSource") ?? sourceRaw

        self.globalAppearanceEnabled = ProfileSettingsStore.active.object(forKey: "readerGlobalAppearanceEnabled") == nil
            ? true
            : ProfileSettingsStore.active.bool(forKey: "readerGlobalAppearanceEnabled")
#endif
        self.settingsGradientColor = Self.loadColor(key: "eclipseThemeGradientColor") ?? Self.gradientPresets[0].color
#if !os(tvOS)
        self.readerSettingsGradientColor = Self.loadColor(key: "readerThemeGradientColor") ?? Self.loadColor(key: "eclipseThemeGradientColor") ?? Self.gradientPresets[0].color
#endif
        self.atmosphereStyle = AtmosphereStyle(rawValue: styleRaw) ?? .gradient
#if !os(tvOS)
        self.readerAtmosphereStyle = AtmosphereStyle(rawValue: readerStyleRaw) ?? .gradient
#endif
        self.atmosphereSolidColorSource = AtmosphereSolidColorSource(rawValue: sourceRaw) ?? .dominant
#if !os(tvOS)
        self.readerAtmosphereSolidColorSource = AtmosphereSolidColorSource(rawValue: readerSourceRaw) ?? .dominant
#endif
        self.atmosphereSolidColor = Self.loadColor(key: "atmosphereSolidColor") ?? Self.gradientPresets[0].color
#if !os(tvOS)
        self.readerAtmosphereSolidColor = Self.loadColor(key: "readerAtmosphereSolidColor") ?? Self.loadColor(key: "atmosphereSolidColor") ?? Self.gradientPresets[0].color
#endif

        let defaults = ProfileSettingsStore.active
        self.appearancePaletteRaw = defaults.string(forKey: AppearanceConfig.paletteKey) ?? AtmospherePaletteID.defaultValue.rawValue
#if !os(tvOS)
        self.readerAppearancePaletteRaw = defaults.string(forKey: AppearanceConfig.readerPaletteKey)
            ?? defaults.string(forKey: AppearanceConfig.paletteKey)
            ?? AtmospherePaletteID.defaultValue.rawValue
#endif
        self.bleedStrength = defaults.object(forKey: AppearanceConfig.bleedStrengthKey) != nil
            ? AppearanceConfig.clampBleed(defaults.double(forKey: AppearanceConfig.bleedStrengthKey))
            : AppearanceConfig.defaultBleedStrength
#if !os(tvOS)
        self.readerBleedStrength = defaults.object(forKey: AppearanceConfig.readerBleedStrengthKey) != nil
            ? AppearanceConfig.clampBleed(defaults.double(forKey: AppearanceConfig.readerBleedStrengthKey))
            : (defaults.object(forKey: AppearanceConfig.bleedStrengthKey) != nil
                ? AppearanceConfig.clampBleed(defaults.double(forKey: AppearanceConfig.bleedStrengthKey))
                : AppearanceConfig.defaultBleedStrength)
#endif
        self.backgroundIntensity = defaults.object(forKey: AppearanceConfig.backgroundIntensityKey) != nil
            ? AppearanceConfig.clampIntensity(defaults.double(forKey: AppearanceConfig.backgroundIntensityKey))
            : AppearanceConfig.defaultBackgroundIntensity
#if !os(tvOS)
        self.readerBackgroundIntensity = defaults.object(forKey: AppearanceConfig.readerBackgroundIntensityKey) != nil
            ? AppearanceConfig.clampIntensity(defaults.double(forKey: AppearanceConfig.readerBackgroundIntensityKey))
            : (defaults.object(forKey: AppearanceConfig.backgroundIntensityKey) != nil
                ? AppearanceConfig.clampIntensity(defaults.double(forKey: AppearanceConfig.backgroundIntensityKey))
                : AppearanceConfig.defaultBackgroundIntensity)
#endif
        self.atmosphereMotion = defaults.object(forKey: AppearanceConfig.motionKey) != nil
            ? AppearanceConfig.clampMotion(defaults.double(forKey: AppearanceConfig.motionKey))
            : AppearanceConfig.defaultMotion
#if !os(tvOS)
        self.readerAtmosphereMotion = defaults.object(forKey: AppearanceConfig.readerMotionKey) != nil
            ? AppearanceConfig.clampMotion(defaults.double(forKey: AppearanceConfig.readerMotionKey))
            : (defaults.object(forKey: AppearanceConfig.motionKey) != nil
                ? AppearanceConfig.clampMotion(defaults.double(forKey: AppearanceConfig.motionKey))
                : AppearanceConfig.defaultMotion)
#endif
        self.customPaletteColors = AppearanceConfig.decodeColors(defaults.data(forKey: AppearanceConfig.customColorsKey))
            ?? AppearanceConfig.defaultCustomColors
#if !os(tvOS)
        self.readerCustomPaletteColors = AppearanceConfig.decodeColors(defaults.data(forKey: AppearanceConfig.readerCustomColorsKey))
            ?? AppearanceConfig.decodeColors(defaults.data(forKey: AppearanceConfig.customColorsKey))
            ?? AppearanceConfig.defaultCustomColors
#endif
    }

    func reloadForActiveProfile() {
        isReloadingForProfileSwitch = true
        defer { isReloadingForProfileSwitch = false }
        let defaults = ProfileSettingsStore.active
        let styleRaw = defaults.string(forKey: "atmosphereStyle") ?? Self.defaultAtmosphereStyle.rawValue
        let sourceRaw = defaults.string(forKey: "atmosphereSolidColorSource") ?? AtmosphereSolidColorSource.dominant.rawValue
#if !os(tvOS)
        let readerStyleRaw = defaults.string(forKey: "readerAtmosphereStyle") ?? styleRaw
        let readerSourceRaw = defaults.string(forKey: "readerAtmosphereSolidColorSource") ?? sourceRaw

        globalAppearanceEnabled = defaults.object(forKey: "readerGlobalAppearanceEnabled") == nil
            ? true
            : defaults.bool(forKey: "readerGlobalAppearanceEnabled")
#endif
        settingsGradientColor = Self.loadColor(key: "eclipseThemeGradientColor") ?? Self.gradientPresets[0].color
#if !os(tvOS)
        readerSettingsGradientColor = Self.loadColor(key: "readerThemeGradientColor")
            ?? Self.loadColor(key: "eclipseThemeGradientColor")
            ?? Self.gradientPresets[0].color
#endif
        atmosphereStyle = AtmosphereStyle(rawValue: styleRaw) ?? .gradient
#if !os(tvOS)
        readerAtmosphereStyle = AtmosphereStyle(rawValue: readerStyleRaw) ?? .gradient
#endif
        atmosphereSolidColorSource = AtmosphereSolidColorSource(rawValue: sourceRaw) ?? .dominant
#if !os(tvOS)
        readerAtmosphereSolidColorSource = AtmosphereSolidColorSource(rawValue: readerSourceRaw) ?? .dominant
#endif
        atmosphereSolidColor = Self.loadColor(key: "atmosphereSolidColor") ?? Self.gradientPresets[0].color
#if !os(tvOS)
        readerAtmosphereSolidColor = Self.loadColor(key: "readerAtmosphereSolidColor")
            ?? Self.loadColor(key: "atmosphereSolidColor")
            ?? Self.gradientPresets[0].color
#endif
        appearancePaletteRaw = defaults.string(forKey: AppearanceConfig.paletteKey)
            ?? AtmospherePaletteID.defaultValue.rawValue
#if !os(tvOS)
        readerAppearancePaletteRaw = defaults.string(forKey: AppearanceConfig.readerPaletteKey)
            ?? defaults.string(forKey: AppearanceConfig.paletteKey)
            ?? AtmospherePaletteID.defaultValue.rawValue
#endif
        bleedStrength = defaults.object(forKey: AppearanceConfig.bleedStrengthKey) != nil
            ? AppearanceConfig.clampBleed(defaults.double(forKey: AppearanceConfig.bleedStrengthKey))
            : AppearanceConfig.defaultBleedStrength
#if !os(tvOS)
        readerBleedStrength = defaults.object(forKey: AppearanceConfig.readerBleedStrengthKey) != nil
            ? AppearanceConfig.clampBleed(defaults.double(forKey: AppearanceConfig.readerBleedStrengthKey))
            : bleedStrength
#endif
        backgroundIntensity = defaults.object(forKey: AppearanceConfig.backgroundIntensityKey) != nil
            ? AppearanceConfig.clampIntensity(defaults.double(forKey: AppearanceConfig.backgroundIntensityKey))
            : AppearanceConfig.defaultBackgroundIntensity
#if !os(tvOS)
        readerBackgroundIntensity = defaults.object(forKey: AppearanceConfig.readerBackgroundIntensityKey) != nil
            ? AppearanceConfig.clampIntensity(defaults.double(forKey: AppearanceConfig.readerBackgroundIntensityKey))
            : backgroundIntensity
#endif
        atmosphereMotion = defaults.object(forKey: AppearanceConfig.motionKey) != nil
            ? AppearanceConfig.clampMotion(defaults.double(forKey: AppearanceConfig.motionKey))
            : AppearanceConfig.defaultMotion
#if !os(tvOS)
        readerAtmosphereMotion = defaults.object(forKey: AppearanceConfig.readerMotionKey) != nil
            ? AppearanceConfig.clampMotion(defaults.double(forKey: AppearanceConfig.readerMotionKey))
            : atmosphereMotion
#endif
        customPaletteColors = AppearanceConfig.decodeColors(defaults.data(forKey: AppearanceConfig.customColorsKey))
            ?? AppearanceConfig.defaultCustomColors
#if !os(tvOS)
        readerCustomPaletteColors = AppearanceConfig.decodeColors(defaults.data(forKey: AppearanceConfig.readerCustomColorsKey))
            ?? AppearanceConfig.decodeColors(defaults.data(forKey: AppearanceConfig.customColorsKey))
            ?? AppearanceConfig.defaultCustomColors
#endif
    }

    @MainActor
    func reloadMediaAppearanceFromDefaults() {
        let defaults = ProfileSettingsStore.active
        let styleRaw = defaults.string(forKey: "atmosphereStyle") ?? Self.defaultAtmosphereStyle.rawValue
        atmosphereStyle = AtmosphereStyle(rawValue: styleRaw) ?? Self.defaultAtmosphereStyle

        let paletteRaw = defaults.string(forKey: AppearanceConfig.paletteKey) ?? AtmospherePaletteID.defaultValue.rawValue
        appearancePaletteRaw = paletteRaw
        bleedStrength = defaults.object(forKey: AppearanceConfig.bleedStrengthKey) != nil
            ? AppearanceConfig.clampBleed(defaults.double(forKey: AppearanceConfig.bleedStrengthKey))
            : AppearanceConfig.defaultBleedStrength
        backgroundIntensity = defaults.object(forKey: AppearanceConfig.backgroundIntensityKey) != nil
            ? AppearanceConfig.clampIntensity(defaults.double(forKey: AppearanceConfig.backgroundIntensityKey))
            : AppearanceConfig.defaultBackgroundIntensity
        atmosphereMotion = defaults.object(forKey: AppearanceConfig.motionKey) != nil
            ? AppearanceConfig.clampMotion(defaults.double(forKey: AppearanceConfig.motionKey))
            : AppearanceConfig.defaultMotion
    }

    private static var defaultAtmosphereStyle: AtmosphereStyle {
        #if !os(tvOS)
        return ExperimentalFeatureState.isEnabledAtLaunch ? .multiGradient : .gradient
        #else
        return .gradient
        #endif
    }

    func atmosphereColor(dominant: Color) -> Color {
        atmosphereSolidColorSource == .custom ? atmosphereSolidColor : dominant
    }

#if os(tvOS)

    func scopedGradientColor() -> Color {
        settingsGradientColor
    }

    func scopedAtmosphereStyle() -> AtmosphereStyle {
        atmosphereStyle
    }

    func scopedAtmosphereColor(dominant: Color) -> Color {
        atmosphereColor(dominant: dominant)
    }

    func scopedPaletteID() -> AtmospherePaletteID {
        let palette = AtmospherePaletteID.from(appearancePaletteRaw)
#if os(tvOS)

        return palette == .custom ? .defaultValue : palette
#else
        return palette
#endif
    }

    func scopedCustomColors() -> [Color] {
        customPaletteColors
    }

    func scopedPalette() -> AtmospherePalette {
        AppearancePalettes.resolved(
            id: scopedPaletteID(),
            customColors: scopedCustomColors()
        )
    }

    func scopedBleedStrength() -> Double {
        AppearanceConfig.clampBleed(bleedStrength)
    }

    func scopedBackgroundIntensity() -> Double {
        AppearanceConfig.clampIntensity(backgroundIntensity)
    }

    func scopedMotion() -> Double {
        AppearanceConfig.clampMotion(atmosphereMotion)
    }

    func atmosphereBackgroundMode() -> AtmosphereBackgroundMode {
        switch scopedAtmosphereStyle() {
        case .solid: return .solid
        case .gradient: return .classicGradient
        case .multiGradient, .aurora, .ember: return .multiGradient
        }
    }

    func atmosphereInput(
        dominant: Color?,
        hasHeroBleed: Bool,
        heroHeight: CGFloat,
        fadeDistance: CGFloat
    ) -> AtmosphereInput {
        let usableDominant = Self.usableDominant(dominant)
        let mode = atmosphereBackgroundMode()
        let accent = scopedGradientColor()
        let classicColor: Color
        switch mode {
        case .solid:
            classicColor = scopedAtmosphereColor(dominant: usableDominant ?? accent)
        case .classicGradient, .multiGradient:
            classicColor = accent
        }
        return AtmosphereInput(
            mode: mode,
            palette: scopedPalette(),
            classicColor: classicColor,
            baseColor: backgroundBase,
            dominant: hasHeroBleed ? usableDominant : nil,
            hasHeroBleed: hasHeroBleed,
            heroHeight: heroHeight,
            fadeDistance: fadeDistance,
            bleedStrength: scopedBleedStrength(),
            backgroundIntensity: scopedBackgroundIntensity(),
            motion: scopedMotion()
        )
    }

    func atmosphereBackdropColor() -> Color {
        let intensity = scopedBackgroundIntensity()
        switch atmosphereBackgroundMode() {
        case .solid:
            return scopedAtmosphereColor(dominant: scopedGradientColor())
        case .classicGradient:
            return scopedGradientColor().atmosphereScaled(intensity)
        case .multiGradient:
            let palette = scopedPalette()
            let base = palette.mesh.indices.contains(4) ? palette.mesh[4] : backgroundBase
            return base.atmosphereScaled(intensity)
        }
    }

    func heroBlendColor(dominant: Color?) -> Color {
        Self.usableDominant(dominant) ?? atmosphereBackdropColor()
    }
#else
    func scopedGradientColor(isReaderMode: Bool? = nil) -> Color {
        let readerMode = isReaderMode ?? UserDefaults.standard.bool(forKey: "showKanzen")
        return readerMode && !globalAppearanceEnabled ? readerSettingsGradientColor : settingsGradientColor
    }

    func scopedAtmosphereStyle(isReaderMode: Bool? = nil) -> AtmosphereStyle {
        let readerMode = isReaderMode ?? UserDefaults.standard.bool(forKey: "showKanzen")
        return readerMode && !globalAppearanceEnabled ? readerAtmosphereStyle : atmosphereStyle
    }

    func scopedAtmosphereColor(dominant: Color, isReaderMode: Bool? = nil) -> Color {
        let readerMode = isReaderMode ?? UserDefaults.standard.bool(forKey: "showKanzen")
        if readerMode && !globalAppearanceEnabled {
            return readerAtmosphereSolidColorSource == .custom ? readerAtmosphereSolidColor : dominant
        }
        return atmosphereColor(dominant: dominant)
    }

    private func usesReaderScope(_ isReaderMode: Bool?) -> Bool {
        let readerMode = isReaderMode ?? UserDefaults.standard.bool(forKey: "showKanzen")
        return readerMode && !globalAppearanceEnabled
    }

    func scopedPaletteID(isReaderMode: Bool? = nil) -> AtmospherePaletteID {
        AtmospherePaletteID.from(usesReaderScope(isReaderMode) ? readerAppearancePaletteRaw : appearancePaletteRaw)
    }

    func scopedCustomColors(isReaderMode: Bool? = nil) -> [Color] {
        usesReaderScope(isReaderMode) ? readerCustomPaletteColors : customPaletteColors
    }

    func scopedPalette(isReaderMode: Bool? = nil) -> AtmospherePalette {
        AppearancePalettes.resolved(
            id: scopedPaletteID(isReaderMode: isReaderMode),
            customColors: scopedCustomColors(isReaderMode: isReaderMode)
        )
    }

    func scopedBleedStrength(isReaderMode: Bool? = nil) -> Double {
        AppearanceConfig.clampBleed(usesReaderScope(isReaderMode) ? readerBleedStrength : bleedStrength)
    }

    func scopedBackgroundIntensity(isReaderMode: Bool? = nil) -> Double {
        AppearanceConfig.clampIntensity(usesReaderScope(isReaderMode) ? readerBackgroundIntensity : backgroundIntensity)
    }

    func scopedMotion(isReaderMode: Bool? = nil) -> Double {
        AppearanceConfig.clampMotion(usesReaderScope(isReaderMode) ? readerAtmosphereMotion : atmosphereMotion)
    }

    func atmosphereBackgroundMode(isReaderMode: Bool? = nil) -> AtmosphereBackgroundMode {
        switch scopedAtmosphereStyle(isReaderMode: isReaderMode) {
        case .solid: return .solid
        case .gradient: return .classicGradient
        case .multiGradient, .aurora, .ember: return .multiGradient
        }
    }

    func atmosphereInput(
        dominant: Color?,
        hasHeroBleed: Bool,
        heroHeight: CGFloat,
        fadeDistance: CGFloat,
        isReaderMode: Bool? = nil
    ) -> AtmosphereInput {
        let usableDominant = Self.usableDominant(dominant)
        let mode = atmosphereBackgroundMode(isReaderMode: isReaderMode)
        let accent = scopedGradientColor(isReaderMode: isReaderMode)
        let classicColor: Color
        switch mode {
        case .solid:
            classicColor = scopedAtmosphereColor(dominant: usableDominant ?? accent, isReaderMode: isReaderMode)
        case .classicGradient, .multiGradient:
            classicColor = accent
        }
        return AtmosphereInput(
            mode: mode,
            palette: scopedPalette(isReaderMode: isReaderMode),
            classicColor: classicColor,
            baseColor: backgroundBase,
            dominant: hasHeroBleed ? usableDominant : nil,
            hasHeroBleed: hasHeroBleed,
            heroHeight: heroHeight,
            fadeDistance: fadeDistance,
            bleedStrength: scopedBleedStrength(isReaderMode: isReaderMode),
            backgroundIntensity: scopedBackgroundIntensity(isReaderMode: isReaderMode),
            motion: scopedMotion(isReaderMode: isReaderMode)
        )
    }

    func atmosphereBackdropColor(isReaderMode: Bool? = nil) -> Color {
        let intensity = scopedBackgroundIntensity(isReaderMode: isReaderMode)
        switch atmosphereBackgroundMode(isReaderMode: isReaderMode) {
        case .solid:
            return scopedAtmosphereColor(dominant: scopedGradientColor(isReaderMode: isReaderMode), isReaderMode: isReaderMode)
        case .classicGradient:
            return scopedGradientColor(isReaderMode: isReaderMode).atmosphereScaled(intensity)
        case .multiGradient:
            let palette = scopedPalette(isReaderMode: isReaderMode)
            let base = palette.mesh.indices.contains(4) ? palette.mesh[4] : backgroundBase
            return base.atmosphereScaled(intensity)
        }
    }

    func heroBlendColor(dominant: Color?, isReaderMode: Bool? = nil) -> Color {
        Self.usableDominant(dominant) ?? atmosphereBackdropColor(isReaderMode: isReaderMode)
    }
#endif

    static func usableDominant(_ color: Color?) -> Color? {
        guard let color else { return nil }
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
        if max(r, max(g, b)) < 0.06 { return nil }
        return color
        #else
        return color
        #endif
    }

    private func saveColor(_ color: Color, key: String) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: UIColor(color), requiringSecureCoding: true)
            ProfileSettingsStore.active.set(data, forKey: key)
        } catch {

        }
    }

    private static func loadColor(key: String) -> Color? {
        guard let data = ProfileSettingsStore.active.data(forKey: key),
              !data.isEmpty else { return nil }
        do {
            if let uiColor = try NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) {
                return Color(uiColor)
            }
        } catch { }
        return nil
    }
}

extension View {

    @ViewBuilder
    func eclipseBackground(allowsAnimatedBackground: Bool = true) -> some View {
        self.background(
            GlobalGradientBackground(allowsAnimatedBackground: allowsAnimatedBackground)
                .ignoresSafeArea()
        )
    }

    func eclipseGradientBackground(allowsAnimatedBackground: Bool = true) -> some View {
        self.modifier(EclipseAutoGradientModifier(allowsAnimatedBackground: allowsAnimatedBackground))
    }

#if !os(tvOS)

    func kanzenGradientBackground(scrollOffset: CGFloat = 0, allowsAnimatedBackground: Bool = true) -> some View {
        self.background(
            GlobalGradientBackground(scrollOffset: scrollOffset, allowsAnimatedBackground: allowsAnimatedBackground)
                .ignoresSafeArea()
        )
    }
#endif

    @ViewBuilder
    func eclipseHideScrollBackground() -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func eclipseDarkToolbar() -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self.toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            self
        }
        #else
        self
        #endif
    }

    func eclipseSettingsStyle(allowsAnimatedBackground: Bool = true) -> some View {
        self
            .eclipseHideScrollBackground()
            .eclipseGradientBackground(allowsAnimatedBackground: allowsAnimatedBackground)
            .eclipseDarkToolbar()
    }

    @ViewBuilder
    func eclipseExperimentalSettingsRows() -> some View {
        #if os(iOS)
        if ExperimentalFeatureState.isEnabledAtLaunch {
            self
                .listRowSeparator(.hidden)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.16, green: 0.13, blue: 0.22).opacity(0.78),
                                    Color(red: 0.08, green: 0.08, blue: 0.13).opacity(0.70)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
                        )
                        .padding(.vertical, 3)
                )
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func eclipseHideListRowSeparator() -> some View {
        #if os(iOS)
        if #available(iOS 15.0, *) {
            self.listRowSeparator(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

private struct EclipseAutoGradientModifier: ViewModifier {
    var allowsAnimatedBackground: Bool

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: "eclipseGradientScroll")
            .background(
                SettingsGradientBackground(allowsAnimatedBackground: allowsAnimatedBackground)
                    .ignoresSafeArea()
            )
    }
}
