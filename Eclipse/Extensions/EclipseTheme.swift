// Theme system with customizable gradient colors

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

    /// Behaviors offered in the UI. `.launch` is retained for backward compatibility
    /// with existing saved values and backups but is no longer user-selectable.
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
    
    // MARK: - Persisted Settings

#if !os(tvOS)
    @Published var globalAppearanceEnabled: Bool {
        didSet { UserDefaults.standard.set(globalAppearanceEnabled, forKey: "readerGlobalAppearanceEnabled") }
    }
#endif

    @Published var settingsGradientColor: Color {
        didSet { saveColor(settingsGradientColor, key: "eclipseThemeGradientColor") }
    }

#if !os(tvOS)
    @Published var readerSettingsGradientColor: Color {
        didSet { saveColor(readerSettingsGradientColor, key: "readerThemeGradientColor") }
    }
#endif

    @Published var atmosphereStyle: AtmosphereStyle {
        didSet { UserDefaults.standard.set(atmosphereStyle.rawValue, forKey: "atmosphereStyle") }
    }

#if !os(tvOS)
    @Published var readerAtmosphereStyle: AtmosphereStyle {
        didSet { UserDefaults.standard.set(readerAtmosphereStyle.rawValue, forKey: "readerAtmosphereStyle") }
    }
#endif

    @Published var atmosphereSolidColorSource: AtmosphereSolidColorSource {
        didSet { UserDefaults.standard.set(atmosphereSolidColorSource.rawValue, forKey: "atmosphereSolidColorSource") }
    }

#if !os(tvOS)
    @Published var readerAtmosphereSolidColorSource: AtmosphereSolidColorSource {
        didSet { UserDefaults.standard.set(readerAtmosphereSolidColorSource.rawValue, forKey: "readerAtmosphereSolidColorSource") }
    }
#endif

    @Published var atmosphereSolidColor: Color {
        didSet { saveColor(atmosphereSolidColor, key: "atmosphereSolidColor") }
    }

#if !os(tvOS)
    @Published var readerAtmosphereSolidColor: Color {
        didSet { saveColor(readerAtmosphereSolidColor, key: "readerAtmosphereSolidColor") }
    }
#endif

    // MARK: - Appearance (modern atmosphere)

    @Published var appearancePaletteRaw: String {
        didSet { UserDefaults.standard.set(appearancePaletteRaw, forKey: AppearanceConfig.paletteKey) }
    }

#if !os(tvOS)
    @Published var readerAppearancePaletteRaw: String {
        didSet { UserDefaults.standard.set(readerAppearancePaletteRaw, forKey: AppearanceConfig.readerPaletteKey) }
    }
#endif

    @Published var bleedStrength: Double {
        didSet { UserDefaults.standard.set(bleedStrength, forKey: AppearanceConfig.bleedStrengthKey) }
    }

#if !os(tvOS)
    @Published var readerBleedStrength: Double {
        didSet { UserDefaults.standard.set(readerBleedStrength, forKey: AppearanceConfig.readerBleedStrengthKey) }
    }
#endif

    @Published var backgroundIntensity: Double {
        didSet { UserDefaults.standard.set(backgroundIntensity, forKey: AppearanceConfig.backgroundIntensityKey) }
    }

#if !os(tvOS)
    @Published var readerBackgroundIntensity: Double {
        didSet { UserDefaults.standard.set(readerBackgroundIntensity, forKey: AppearanceConfig.readerBackgroundIntensityKey) }
    }
#endif

    @Published var atmosphereMotion: Double {
        didSet { UserDefaults.standard.set(atmosphereMotion, forKey: AppearanceConfig.motionKey) }
    }

#if !os(tvOS)
    @Published var readerAtmosphereMotion: Double {
        didSet { UserDefaults.standard.set(readerAtmosphereMotion, forKey: AppearanceConfig.readerMotionKey) }
    }
#endif

    @Published var customPaletteColors: [Color] {
        didSet {
            if let data = AppearanceConfig.encodeColors(customPaletteColors) {
                UserDefaults.standard.set(data, forKey: AppearanceConfig.customColorsKey)
            }
        }
    }

#if !os(tvOS)
    @Published var readerCustomPaletteColors: [Color] {
        didSet {
            if let data = AppearanceConfig.encodeColors(readerCustomPaletteColors) {
                UserDefaults.standard.set(data, forKey: AppearanceConfig.readerCustomColorsKey)
            }
        }
    }
#endif

    // MARK: - Constants
    
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
    
    // MARK: - Presets
    
    static let gradientPresets: [(name: String, color: Color)] = [
        ("Purple", Color(red: 0.25, green: 0.12, blue: 0.45)),
        ("Blue", Color(red: 0.10, green: 0.15, blue: 0.40)),
        ("Teal", Color(red: 0.08, green: 0.28, blue: 0.30)),
        ("Red", Color(red: 0.38, green: 0.10, blue: 0.12)),
        ("Green", Color(red: 0.10, green: 0.28, blue: 0.14))
    ]
    
    // MARK: - Init
    
    private init() {
        AppearanceConfig.migrateIfNeeded()
        let styleRaw = UserDefaults.standard.string(forKey: "atmosphereStyle") ?? Self.defaultAtmosphereStyle.rawValue
        let sourceRaw = UserDefaults.standard.string(forKey: "atmosphereSolidColorSource") ?? AtmosphereSolidColorSource.dominant.rawValue
#if !os(tvOS)
        let readerStyleRaw = UserDefaults.standard.string(forKey: "readerAtmosphereStyle") ?? styleRaw
        let readerSourceRaw = UserDefaults.standard.string(forKey: "readerAtmosphereSolidColorSource") ?? sourceRaw

        self.globalAppearanceEnabled = UserDefaults.standard.object(forKey: "readerGlobalAppearanceEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "readerGlobalAppearanceEnabled")
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

        let defaults = UserDefaults.standard
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

    /// Refresh the media-only theme fields after CloudKit applies shared settings.
    /// Reader-scoped values deliberately remain untouched.
    @MainActor
    func reloadMediaAppearanceFromDefaults() {
        let defaults = UserDefaults.standard
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
    // tvOS has one media-only appearance scope. Keep no reader-labelled API or
    // persisted reader state in the television binary.
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
        // A custom iPhone palette is a shared preference, but custom color
        // editing/data is intentionally unavailable on Apple TV. Render a safe
        // preset without rewriting the shared value back to CloudKit.
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

    // MARK: - Appearance scoping

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

    /// Build the compositor input for any screen. `dominant` is the extracted
    /// banner/poster color (nil or near-black is treated as "no bleed").
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

    /// A single representative color of the current background, used to fade a
    /// hero image's bottom into the backdrop (so dark posters don't leave a
    /// black box over the multi-gradient).
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

    /// The hero-bottom blend color: the poster's color when it is usable,
    /// otherwise the backdrop color so the image dissolves into the background.
    func heroBlendColor(dominant: Color?, isReaderMode: Bool? = nil) -> Color {
        Self.usableDominant(dominant) ?? atmosphereBackdropColor(isReaderMode: isReaderMode)
    }
#endif

    /// Treat near-black extracted colors as "no bleed" so the app gradient is
    /// not muddied before a real poster color is available.
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

    // MARK: - Persistence
    
    private func saveColor(_ color: Color, key: String) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: UIColor(color), requiringSecureCoding: true)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // Silently fail - default will be used next launch
        }
    }
    
    private static func loadColor(key: String) -> Color? {
        guard let data = UserDefaults.standard.data(forKey: key),
              !data.isEmpty else { return nil }
        do {
            if let uiColor = try NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) {
                return Color(uiColor)
            }
        } catch { }
        return nil
    }
}

// MARK: - View Modifiers

extension View {
    /// Apply the standard dark base background used across all screens
    @ViewBuilder
    func eclipseBackground(allowsAnimatedBackground: Bool = true) -> some View {
        self.background(
            GlobalGradientBackground(allowsAnimatedBackground: allowsAnimatedBackground)
                .ignoresSafeArea()
        )
    }
    
    /// Apply the gradient background used in Settings screens
    func eclipseGradientBackground(allowsAnimatedBackground: Bool = true) -> some View {
        self.modifier(EclipseAutoGradientModifier(allowsAnimatedBackground: allowsAnimatedBackground))
    }

#if !os(tvOS)
    /// Apply the app-wide gradient used by Reader Mode/Kanzen shell screens.
    func kanzenGradientBackground(scrollOffset: CGFloat = 0, allowsAnimatedBackground: Bool = true) -> some View {
        self.background(
            GlobalGradientBackground(scrollOffset: scrollOffset, allowsAnimatedBackground: allowsAnimatedBackground)
                .ignoresSafeArea()
        )
    }
#endif
    
    /// Hide list/scroll-view chrome (iOS 16+, unavailable on tvOS)
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

    /// Dark toolbar color scheme (iOS 16+, unavailable on tvOS)
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

    /// Apply Eclipse styling to any List-based settings sub-view:
    /// gradient background, transparent list style, dark toolbar
    func eclipseSettingsStyle(allowsAnimatedBackground: Bool = true) -> some View {
        self
            .eclipseHideScrollBackground()
            .eclipseGradientBackground(allowsAnimatedBackground: allowsAnimatedBackground)
            .eclipseDarkToolbar()
    }

    /// Give native List/Form settings rows the experimental glass treatment without
    /// rewriting each settings screen into custom containers.
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

    /// Hide list row separators where supported (no-op on tvOS).
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

// MARK: - Auto-tracking gradient modifier

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
