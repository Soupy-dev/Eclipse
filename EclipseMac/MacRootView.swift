import AppKit
import AidokuRunner
import SwiftUI

enum MacMode: String, CaseIterable, Identifiable {
    case media = "Media"
    case reader = "Kanzen"

    var id: String { rawValue }
    var icon: String { self == .media ? "play.rectangle.fill" : "books.vertical.fill" }
}

enum MacHomeCatalogID: String, CaseIterable, Identifiable {
    case trending
    case trendingAnime
    case popularMovies
    case popularAnime
    case popularShows
    case airingAnime
    case upcomingAnime
    case topRated
    case topRatedAnime

    var id: String { rawValue }
    var title: String {
        switch self {
        case .trending: "Trending This Week"
        case .trendingAnime: "Trending Anime"
        case .popularMovies: "Popular Movies"
        case .popularAnime: "Popular Anime"
        case .popularShows: "Popular Shows"
        case .airingAnime: "Airing Now"
        case .upcomingAnime: "Upcoming Anime"
        case .topRated: "Top Rated Movies"
        case .topRatedAnime: "Top Rated Anime"
        }
    }
}

enum MacDestination: String, CaseIterable, Identifiable {
    case home = "Home"
    case schedule = "Schedule"
    case browse = "Browse"
    case library = "Library"
    case downloads = "Downloads"
    case search = "Search"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house.fill"
        case .schedule: "calendar"
        case .browse: "safari.fill"
        case .library: "books.vertical.fill"
        case .downloads: "arrow.down.circle.fill"
        case .search: "magnifyingglass"
        case .settings: "gearshape.fill"
        }
    }
}

@MainActor
final class MacAppState: ObservableObject {
    @AppStorage("macSelectedMode") var mode: MacMode = .media
    @Published var mediaDestination: MacDestination = .home
    @Published var readerDestination: MacDestination = .home
    @Published var searchText = ""
    @Published var homeBackgroundAnimationSuspended = false

    var destination: MacDestination {
        get { mode == .media ? mediaDestination : readerDestination }
        set {
            if mode == .media { mediaDestination = newValue }
            else { readerDestination = newValue }
        }
    }

    var destinations: [MacDestination] {
        mode == .media
            ? [.home, .schedule, .downloads, .library, .search]
            : [.home, .browse, .library, .downloads, .search]
    }
}

struct MacRootView: View {
    @EnvironmentObject private var state: MacAppState
    @EnvironmentObject private var playback: MacPlaybackController
    @EnvironmentObject private var reader: MacReaderController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            EclipseMacBackground(
                allowsAnimation: state.destination == .home
                    && state.mode == .media
                    && !state.homeBackgroundAnimationSuspended
            )
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(.white.opacity(0.07))
                    .frame(width: 1)
                destinationContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .focusedValue(\.macNavigationAction) { destination in
            state.destination = destination
        }
        .onReceive(NotificationCenter.default.publisher(for: .macOpenMedia)) { _ in
            openMediaPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macOpenScheduleNotification)) { _ in
            consumePendingScheduleRoute()
        }
        .onAppear {
            consumePendingScheduleRoute()
        }
        .onChange(of: playback.pendingWindowPresentation) { _, shouldOpen in
            guard shouldOpen else { return }
            openWindow(id: MacWindowID.player)
            playback.pendingWindowPresentation = false
        }
        .onChange(of: reader.pendingWindowPresentation) { _, shouldOpen in
            guard shouldOpen else { return }
            openWindow(id: MacWindowID.reader)
            reader.pendingWindowPresentation = false
        }
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            VStack(spacing: 7) {
                ForEach(state.destinations) { destination in
                    sidebarButton(destination)
                }
            }
            .padding(.top, 10)

            Spacer(minLength: 12)

            if playback.hasMedia {
                Button {
                    playback.pendingWindowPresentation = true
                } label: {
                    Image(systemName: playback.isPaused ? "pause.circle.fill" : "waveform.circle.fill")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 44, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.78))
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .help("Now Playing: \(playback.title)")
            }

            sidebarButton(.settings)

            Menu {
                ForEach(MacMode.allCases) { mode in
                    Button {
                        state.mode = mode
                    } label: {
                        Label(mode.rawValue, systemImage: mode == state.mode ? "checkmark" : mode.icon)
                    }
                }
            } label: {
                Image(systemName: state.mode.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 40)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.white.opacity(0.76))
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .help("Mode: \(state.mode.rawValue)")
            .padding(.bottom, 12)
        }
        .frame(width: 72)
        .background(.black.opacity(0.20))
    }

    private func sidebarButton(_ destination: MacDestination) -> some View {
        let selected = state.destination == destination
        return Button {
            state.destination = destination
        } label: {
            Image(systemName: destination.icon)
                .font(.system(size: 18, weight: selected ? .semibold : .medium))
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .white : .white.opacity(0.58))
        .background(
            selected ? Color.white.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            }
        }
        .help(destination.rawValue)
        .accessibilityLabel(destination.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch state.destination {
        case .home:
            MacHomeView(mode: state.mode)
        case .schedule:
            MacScheduleView()
        case .browse:
            MacReaderBrowseView()
        case .library:
            MacLibraryView(mode: state.mode)
        case .downloads:
            MacDownloadsView(mode: state.mode)
        case .search:
            MacSearchView(mode: state.mode, text: $state.searchText)
        case .settings:
            MacSettingsView()
        }
    }

    private func openMediaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Media"
        panel.prompt = "Play"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        playback.requestPlayback(url: url, title: url.deletingPathExtension().lastPathComponent)
    }

    private func consumePendingScheduleRoute() {
        guard UserDefaults.standard.bool(forKey: MacNotificationRouting.pendingScheduleKey) else { return }
        UserDefaults.standard.removeObject(forKey: MacNotificationRouting.pendingScheduleKey)
        state.mode = .media
        state.mediaDestination = .schedule
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct EclipseMacBackground: View {
    @AppStorage("appearancePalette") private var paletteID = "midnightPurple"
    @AppStorage("atmosphereStyle") private var atmosphereStyleRaw = "multiGradient"
    @AppStorage("appearanceBleedStrength") private var bleedStrength = 1.0
    @AppStorage("appearanceBackgroundIntensity") private var backgroundIntensity = 1.0
    @AppStorage("homeAnimatedBackgroundEnabled") private var animatedBackgroundEnabled = true
    @AppStorage("homeAnimatedBackgroundQuality") private var animatedBackgroundQuality = "low"
    @AppStorage("homeAnimatedBackgroundFrameRate") private var animatedBackgroundFrameRate = "fps20"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let allowsAnimation: Bool

    /// Secondary surfaces such as Settings and media detail are static by default. The
    /// root Home surface opts into animation explicitly so hidden sheets and tabs do not
    /// keep independent TimelineView render loops alive.
    init(allowsAnimation: Bool = false) {
        self.allowsAnimation = allowsAnimation
    }

    var body: some View {
        GeometryReader { proxy in
            if shouldAnimate {
                TimelineView(.animation(minimumInterval: resolvedFrameInterval)) { timeline in
                    animatedAtmosphere(
                        size: proxy.size,
                        phase: timeline.date.timeIntervalSinceReferenceDate / 14
                    )
                }
            } else {
                atmosphere(size: proxy.size, phase: 0)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var shouldAnimate: Bool {
        allowsAnimation
            && animatedBackgroundEnabled
            && !reduceMotion
            && scenePhase == .active
            && resolvedAtmosphereStyle != .solid
    }

    private func animatedAtmosphere(size: CGSize, phase: Double) -> some View {
        Canvas(opaque: true, colorMode: .linear, rendersAsynchronously: true) { context, canvasSize in
            var drawingContext = context
            drawAnimatedAtmosphere(context: &drawingContext, size: canvasSize, phase: phase)
        }
        .frame(width: size.width, height: size.height)
    }

    private func drawAnimatedAtmosphere(
        context: inout GraphicsContext,
        size: CGSize,
        phase: Double
    ) {
        let palette = resolvedPalette
        let intensity = min(max(backgroundIntensity, 0.6), 1.3)
        let bleed = min(max(bleedStrength, 0), 1.2)
        let horizontalDrift = sin(phase) * min(size.width * 0.06, 72)
        let verticalDrift = cos(phase * 0.74) * min(size.height * 0.035, 34)
        let bounds = CGRect(origin: .zero, size: size)
        let baseGradientColors: [Color] = resolvedAtmosphereStyle == .gradient
            ? [
                palette.top.opacity(0.38 * intensity * bleed),
                palette.base.opacity(0.94)
            ]
            : [
                palette.top.opacity(0.28 * intensity * bleed),
                palette.middle.opacity(0.20 * intensity * bleed),
                palette.base.opacity(0.94)
            ]

        context.fill(Path(bounds), with: .color(palette.base))
        context.fill(
            Path(bounds),
            with: .linearGradient(
                Gradient(colors: baseGradientColors),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: size.height)
            )
        )

        let primaryCenter = CGPoint(
            x: size.width * 0.45 + horizontalDrift,
            y: size.height * 0.08 + verticalDrift
        )
        context.fill(
            Path(bounds),
            with: .radialGradient(
                Gradient(colors: [
                    palette.top.opacity(0.50 * intensity * bleed),
                    palette.top.opacity(0.10 * intensity * bleed),
                    .clear
                ]),
                center: primaryCenter,
                startRadius: 0,
                endRadius: max(size.width, 720) * 0.64
            )
        )

        if resolvedAtmosphereStyle == .multiGradient && animatedBackgroundQuality != "low" {
            let secondaryCenter = CGPoint(
                x: size.width * 0.83 - horizontalDrift * 0.68,
                y: size.height * 0.43 - verticalDrift * 0.54
            )
            context.fill(
                Path(bounds),
                with: .radialGradient(
                    Gradient(colors: [
                        palette.secondary.opacity(0.30 * intensity * bleed),
                        .clear
                    ]),
                    center: secondaryCenter,
                    startRadius: 0,
                    endRadius: max(size.width, 660) * 0.52
                )
            )
        }

        if resolvedAtmosphereStyle == .multiGradient && animatedBackgroundQuality == "high" {
            let tertiaryCenter = CGPoint(
                x: size.width * 0.16 + horizontalDrift * 0.42,
                y: size.height * 0.72 - verticalDrift * 0.38
            )
            context.fill(
                Path(bounds),
                with: .radialGradient(
                    Gradient(colors: [
                        palette.middle.opacity(0.20 * intensity * bleed),
                        .clear
                    ]),
                    center: tertiaryCenter,
                    startRadius: 0,
                    endRadius: max(size.width, 620) * 0.42
                )
            )
        }

        context.fill(
            Path(bounds),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.46),
                    .init(color: .black.opacity(0.42), location: 1)
                ]),
                startPoint: CGPoint(x: size.width * 0.5, y: 0),
                endPoint: CGPoint(x: size.width * 0.5, y: size.height)
            )
        )
    }

    @ViewBuilder
    private func atmosphere(size: CGSize, phase: Double) -> some View {
        let palette = resolvedPalette
        let intensity = min(max(backgroundIntensity, 0.6), 1.3)
        let bleed = min(max(bleedStrength, 0), 1.2)
        let horizontalDrift = sin(phase) * min(size.width * 0.06, 72)
        let verticalDrift = cos(phase * 0.74) * min(size.height * 0.035, 34)

        switch resolvedAtmosphereStyle {
        case .solid:
            palette.base

        case .gradient:
            ZStack {
                palette.base

                LinearGradient(
                    colors: [
                        palette.top.opacity(0.38 * intensity * bleed),
                        palette.base.opacity(0.94)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [palette.top.opacity(0.30 * intensity * bleed), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: max(size.width, 720) * 0.64
                )
                .frame(width: max(size.width * 1.12, 800), height: max(size.height * 0.88, 600))
                .position(
                    x: size.width * 0.45 + horizontalDrift,
                    y: size.height * 0.10 + verticalDrift
                )

                bottomShade
            }

        case .multiGradient:
            ZStack {
                palette.base

                LinearGradient(
                    colors: [
                        palette.top.opacity(0.28 * intensity * bleed),
                        palette.middle.opacity(0.20 * intensity * bleed),
                        palette.base.opacity(0.94)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [
                        palette.top.opacity(0.50 * intensity * bleed),
                        palette.top.opacity(0.10 * intensity * bleed),
                        .clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: max(size.width, 720) * 0.64
                )
                .frame(width: max(size.width * 1.18, 820), height: max(size.height * 0.92, 620))
                .position(
                    x: size.width * 0.45 + horizontalDrift,
                    y: size.height * 0.08 + verticalDrift
                )

                RadialGradient(
                    colors: [palette.secondary.opacity(0.30 * intensity * bleed), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: max(size.width, 660) * 0.52
                )
                .frame(width: max(size.width * 0.94, 680), height: max(size.height * 0.78, 520))
                .position(
                    x: size.width * 0.83 - horizontalDrift * 0.68,
                    y: size.height * 0.43 - verticalDrift * 0.54
                )

                bottomShade
            }
        }
    }

    private var bottomShade: some View {
        LinearGradient(
            colors: [.clear, Color.black.opacity(0.42)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var resolvedAtmosphereStyle: MacAtmosphereStyle {
        MacAtmosphereStyle(rawValue: atmosphereStyleRaw) ?? .multiGradient
    }

    private var resolvedFrameInterval: TimeInterval {
        animatedBackgroundFrameRate == "fps30" ? 1.0 / 30.0 : 1.0 / 20.0
    }

    private var resolvedPalette: MacAtmospherePalette {
        switch paletteID {
        case "nocturne":
            MacAtmospherePalette(
                base: Color(red: 0.044, green: 0.058, blue: 0.110),
                top: Color(red: 0.20, green: 0.42, blue: 0.62),
                middle: Color(red: 0.095, green: 0.155, blue: 0.305),
                secondary: Color(red: 0.12, green: 0.54, blue: 0.58)
            )
        case "velvet":
            MacAtmospherePalette(
                base: Color(red: 0.072, green: 0.050, blue: 0.100),
                top: Color(red: 0.55, green: 0.20, blue: 0.46),
                middle: Color(red: 0.235, green: 0.100, blue: 0.250),
                secondary: Color(red: 0.32, green: 0.16, blue: 0.55)
            )
        case "mutedAurora":
            MacAtmospherePalette(
                base: Color(red: 0.052, green: 0.072, blue: 0.120),
                top: Color(red: 0.16, green: 0.52, blue: 0.54),
                middle: Color(red: 0.100, green: 0.185, blue: 0.245),
                secondary: Color(red: 0.30, green: 0.22, blue: 0.62)
            )
        default:
            MacAtmospherePalette(
                base: Color(red: 0.055, green: 0.047, blue: 0.075),
                top: Color(red: 0.42, green: 0.22, blue: 0.58),
                middle: Color(red: 0.180, green: 0.110, blue: 0.300),
                secondary: Color(red: 0.12, green: 0.20, blue: 0.56)
            )
        }
    }
}

private enum MacAtmosphereStyle: String {
    case multiGradient
    case gradient
    case solid
}

private struct MacAtmospherePalette {
    let base: Color
    let top: Color
    let middle: Color
    let secondary: Color
}

struct MacGlassPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.105, green: 0.083, blue: 0.135).opacity(0.90),
                        Color(red: 0.052, green: 0.047, blue: 0.075).opacity(0.86)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
    }
}

struct MacHomeView: View {
    let mode: MacMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var reader: MacReaderController
    @EnvironmentObject private var catalog: MacCatalogStore
    @EnvironmentObject private var mediaState: MacMediaStateStore
    @EnvironmentObject private var aidoku: MacAidokuStore
    @EnvironmentObject private var appState: MacAppState
    @AppStorage("macHomeShowTrending") private var showTrending = true
    @AppStorage("macHomeShowTrendingAnime") private var showTrendingAnime = true
    @AppStorage("macHomeShowPopularMovies") private var showPopularMovies = true
    @AppStorage("macHomeShowPopularAnime") private var showPopularAnime = true
    @AppStorage("macHomeShowPopularShows") private var showPopularShows = true
    @AppStorage("macHomeShowAiringAnime") private var showAiringAnime = false
    @AppStorage("macHomeShowUpcomingAnime") private var showUpcomingAnime = false
    @AppStorage("macHomeShowTopRated") private var showTopRated = true
    @AppStorage("macHomeShowTopRatedAnime") private var showTopRatedAnime = true
    @AppStorage("macHomeCatalogOrder") private var catalogOrderRaw = MacHomeCatalogID.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("heroBannerCatalogId") private var heroBannerCatalogID = "trending"
    @AppStorage("heroBannerBehavior") private var heroBannerBehavior = "carousel"
    @AppStorage("experimentalMediaDesignPreset") private var designPreset = "cinematic"
    @AppStorage("experimentalHeroHeightScale") private var heroHeightScale = 1.0
    @AppStorage("experimentalSectionSpacingScale") private var sectionSpacingScale = 1.0
    @State private var selectedItem: MacMediaItem?
    @State private var heroIndex = 0
    @State private var isHeroAutoAdvancePaused = false
    @State private var isHomeScrolling = false

    private var heroItems: [MacMediaItem] {
        let selected = heroCatalogItems(heroBannerCatalogID)
        let candidates = selected.isEmpty ? catalog.trending : selected
        return Array(candidates.filter { $0.backdropURL != nil }.prefix(12))
    }

    var body: some View {
        Group {
            if mode == .media {
                mediaHome
            } else {
                readerHome
            }
        }
        .task {
            if mode == .media { await catalog.loadHomeIfNeeded() }
        }
        .task(id: heroAutoAdvanceTaskID) {
            guard heroBannerBehavior == "carousel",
                  !reduceMotion,
                  !isHeroAutoAdvancePaused,
                  selectedItem == nil,
                  heroItems.count > 1 else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(7))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      !reduceMotion,
                      !isHeroAutoAdvancePaused,
                      selectedItem == nil,
                      heroItems.count > 1 else { return }
                advanceHero(by: 1)
            }
        }
        .task(id: heroPreheatTaskID) {
            guard mode == .media, heroItems.count > 1 else { return }
            let currentIndex = min(max(heroIndex, 0), heroItems.count - 1)
            let upcomingURLs = (1...min(2, heroItems.count - 1)).compactMap { offset in
                heroItems[(currentIndex + offset) % heroItems.count].backdropURL
            }
            await MacCachedImage.preheat(
                urls: upcomingURLs,
                targetSize: MacHomeHero.artworkTargetSize
            )
        }
        .onChange(of: heroBannerCatalogID) { _, _ in heroIndex = 0 }
        .onChange(of: heroBannerBehavior) { _, value in
            if value != "carousel" { heroIndex = 0 }
        }
        .onChange(of: isHomeScrolling) { _, _ in
            syncBackgroundAnimationSuspension()
        }
        .onChange(of: selectedItem != nil) { _, _ in
            syncBackgroundAnimationSuspension()
        }
        .onChange(of: mode) { _, _ in
            syncBackgroundAnimationSuspension()
        }
        .onAppear {
            syncBackgroundAnimationSuspension()
        }
        .onDisappear {
            appState.homeBackgroundAnimationSuspended = false
        }
        .sheet(item: $selectedItem) { item in
            MacMediaDetail(item: item)
        }
    }

    private var mediaHome: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: resolvedSectionSpacing) {
                if let hero = heroItems.indices.contains(heroIndex) ? heroItems[heroIndex] : heroItems.first {
                    MacHomeHero(
                        item: hero,
                        currentIndex: min(heroIndex, max(0, heroItems.count - 1)),
                        count: heroBannerBehavior == "carousel" ? heroItems.count : 1,
                        open: { selectedItem = hero },
                        toggleLibrary: { catalog.toggleLibrary(hero) },
                        isInLibrary: catalog.isInLibrary(hero),
                        isAutoAdvancePaused: reduceMotion || isHeroAutoAdvancePaused,
                        autoAdvanceUnavailable: reduceMotion,
                        previous: { advanceHero(by: -1) },
                        next: { advanceHero(by: 1) },
                        toggleAutoAdvance: { isHeroAutoAdvancePaused.toggle() }
                    )
                    .frame(height: resolvedHeroHeight)
                    .id(hero.stableID)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: hero.stableID)
                } else if catalog.isLoading {
                    ProgressView("Loading Eclipse…")
                        .frame(maxWidth: .infinity, minHeight: 360)
                }

                if !mediaState.continueWatching.isEmpty {
                    MacContinueWatchingRail(values: Array(mediaState.continueWatching.prefix(12))) {
                        selectedItem = $0.identity.item
                    }
                }

                ForEach(orderedCatalogs) { catalogID in
                    catalogRail(for: catalogID)
                }

                if let error = catalog.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 34)
                }
            }
            .padding(.bottom, 42)
        }
        .scrollIndicators(.hidden)
        .onScrollPhaseChange { _, newPhase in
            isHomeScrolling = newPhase != .idle
        }
    }

    private var orderedCatalogs: [MacHomeCatalogID] {
        var seen = Set<MacHomeCatalogID>()
        let saved = catalogOrderRaw.split(separator: ",").compactMap { MacHomeCatalogID(rawValue: String($0)) }.filter { seen.insert($0).inserted }
        return saved + MacHomeCatalogID.allCases.filter { seen.insert($0).inserted }
    }

    private var resolvedHeroHeight: CGFloat {
        let base: CGFloat
        switch designPreset {
        case "balanced": base = 400
        case "compact": base = 350
        default: base = 440
        }
        return base * CGFloat(min(max(heroHeightScale, 0.75), 1.15))
    }

    private var resolvedSectionSpacing: CGFloat {
        let base: CGFloat
        switch designPreset {
        case "balanced": base = 24
        case "compact": base = 18
        default: base = 30
        }
        return base * CGFloat(min(max(sectionSpacingScale, 0.75), 1.35))
    }

    private var heroAutoAdvanceTaskID: String {
        "\(heroBannerCatalogID)-\(heroBannerBehavior)-\(heroItems.count)-\(reduceMotion)-\(isHeroAutoAdvancePaused)-\(selectedItem != nil)"
    }

    private var heroPreheatTaskID: String {
        "\(heroBannerCatalogID)-\(heroIndex)-\(heroItems.map(\.stableID).joined(separator: ","))"
    }

    private func syncBackgroundAnimationSuspension() {
        appState.homeBackgroundAnimationSuspended = mode == .media
            && (isHomeScrolling || selectedItem != nil)
    }

    private func advanceHero(by offset: Int) {
        guard heroItems.count > 1 else { return }
        let normalizedIndex = min(max(heroIndex, 0), heroItems.count - 1)
        let nextIndex = (normalizedIndex + offset + heroItems.count) % heroItems.count
        heroIndex = nextIndex
    }

    private func heroCatalogItems(_ catalogID: String) -> [MacMediaItem] {
        switch catalogID {
        case "trending": catalog.trending
        case "popularMovies": catalog.popularMovies
        case "popularTVShows", "popularShows": catalog.popularShows
        case "topRatedMovies", "topRated": catalog.topRatedMovies
        case "trendingAnime": catalog.trendingAnime
        case "popularAnime": catalog.popularAnime
        case "topRatedAnime": catalog.topRatedAnime
        case "airingAnime": catalog.airingAnime
        case "upcomingAnime": catalog.upcomingAnime
        default: []
        }
    }

    @ViewBuilder
    private func catalogRail(for catalogID: MacHomeCatalogID) -> some View {
        switch catalogID {
        case .trending:
            if showTrending, !catalog.trending.isEmpty { MacCatalogRail(title: catalogID.title, items: catalog.trending, selectedItem: $selectedItem) }
        case .trendingAnime:
            if showTrendingAnime, !catalog.trendingAnime.isEmpty { MacCatalogRail(title: catalogID.title, items: catalog.trendingAnime, selectedItem: $selectedItem) }
        case .popularMovies:
            if showPopularMovies, !catalog.popularMovies.isEmpty { MacCatalogRail(title: catalogID.title, items: catalog.popularMovies, selectedItem: $selectedItem) }
        case .popularAnime:
            if showPopularAnime, !catalog.popularAnime.isEmpty { MacCatalogRail(title: catalogID.title, items: catalog.popularAnime, selectedItem: $selectedItem) }
        case .popularShows:
            if showPopularShows, !catalog.popularShows.isEmpty { MacCatalogRail(title: catalogID.title, items: catalog.popularShows, selectedItem: $selectedItem) }
        case .airingAnime:
            if showAiringAnime, !catalog.airingAnime.isEmpty { MacCatalogRail(title: catalogID.title, items: catalog.airingAnime, selectedItem: $selectedItem) }
        case .upcomingAnime:
            if showUpcomingAnime, !catalog.upcomingAnime.isEmpty { MacCatalogRail(title: catalogID.title, items: catalog.upcomingAnime, selectedItem: $selectedItem) }
        case .topRated:
            if showTopRated, !catalog.topRatedMovies.isEmpty { MacCatalogRail(title: catalogID.title, items: catalog.topRatedMovies, selectedItem: $selectedItem) }
        case .topRatedAnime:
            if showTopRatedAnime, !catalog.topRatedAnime.isEmpty { MacCatalogRail(title: catalogID.title, items: catalog.topRatedAnime, selectedItem: $selectedItem) }
        }
    }

    private var readerHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [Color.purple.opacity(0.58), Color.indigo.opacity(0.22), .black.opacity(0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 190, weight: .light))
                        .foregroundStyle(.white.opacity(0.08))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 70)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Kanzen")
                            .font(.system(size: 48, weight: .black, design: .rounded))
                        Text("Your Eclipse reader library, sources, and offline chapters.")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.78))
                        HStack {
                            Button("Open Book") { reader.openImportPanel() }
                                .buttonStyle(.borderedProminent)
                            Button("Browse Sources") { appState.readerDestination = .browse }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(38)
                }
                .frame(height: 330)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.10)))

                if aidoku.library.isEmpty {
                    MacGlassPanel {
                        ContentUnavailableView(
                            "Your Kanzen Library",
                            systemImage: "books.vertical",
                            description: Text("Install a reader source, then add manga to your library.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 210)
                    }
                } else {
                    Text("Continue Reading").font(.title2.bold())
                    Text("Open Library from the sidebar to continue from your saved chapter.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(34)
        }
    }
}

private struct MacHomeHero: View {
    static let artworkTargetSize = CGSize(width: 1_280, height: 720)

    let item: MacMediaItem
    let currentIndex: Int
    let count: Int
    let open: () -> Void
    let toggleLibrary: () -> Void
    let isInLibrary: Bool
    let isAutoAdvancePaused: Bool
    let autoAdvanceUnavailable: Bool
    let previous: () -> Void
    let next: () -> Void
    let toggleAutoAdvance: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            MacCachedImage(
                url: item.backdropURL,
                targetSize: Self.artworkTargetSize,
                placeholderSystemImage: "film"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.08),
                    .init(color: .black.opacity(0.18), location: 0.38),
                    .init(color: Color(red: 0.08, green: 0.035, blue: 0.105).opacity(0.80), location: 0.72),
                    .init(color: Color(red: 0.055, green: 0.047, blue: 0.075), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack {
                LinearGradient(colors: [.black.opacity(0.56), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 280)
                Spacer()
            }

            VStack(spacing: 11) {
                Text(item.title)
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.8), radius: 12, y: 4)
                Text(metadata)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.90))
                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 720)
                }
                HStack(spacing: 10) {
                    Label(String(format: "%.1f", item.rating), systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                }
                HStack(spacing: 12) {
                    Button(action: open) {
                        Label("Watch Now", systemImage: "play.fill")
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)

                    Button(action: toggleLibrary) {
                        Label(isInLibrary ? "In Library" : "Add to Library", systemImage: isInLibrary ? "checkmark" : "plus")
                    }
                    .buttonStyle(.bordered)
                }

                if count > 1 {
                    HStack(spacing: 12) {
                        Button(action: previous) {
                            Label("Previous Feature", systemImage: "chevron.left")
                        }
                        .help("Show the previous featured title")

                        HStack(spacing: 9) {
                            ForEach(0..<count, id: \.self) { index in
                                Circle()
                                    .fill(.white.opacity(index == currentIndex ? 0.95 : 0.34))
                                    .frame(width: 7, height: 7)
                            }
                        }

                        Button(action: toggleAutoAdvance) {
                            Label(
                                autoAdvanceUnavailable ? "Auto-Advance Off" : (isAutoAdvancePaused ? "Resume" : "Pause"),
                                systemImage: isAutoAdvancePaused ? "play.fill" : "pause.fill"
                            )
                        }
                        .disabled(autoAdvanceUnavailable)
                        .help(autoAdvanceUnavailable ? "Auto-advance is disabled while Reduce Motion is on" : (isAutoAdvancePaused ? "Resume featured-title auto-advance" : "Pause featured-title auto-advance"))
                        .accessibilityLabel(autoAdvanceUnavailable ? "Featured title auto-advance unavailable" : (isAutoAdvancePaused ? "Resume featured title auto-advance" : "Pause featured title auto-advance"))
                        .accessibilityValue(autoAdvanceUnavailable ? "Reduce Motion is on" : (isAutoAdvancePaused ? "Paused" : "Playing"))

                        Button(action: next) {
                            Label("Next Feature", systemImage: "chevron.right")
                        }
                        .help("Show the next featured title")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 38)
            .padding(.bottom, 28)
        }
    }

    private var metadata: String {
        let type = item.mediaType == "movie" ? "Movie" : "TV Series"
        let year = item.date.map { String($0.prefix(4)) } ?? ""
        return [year, type].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct MacContinueWatchingRail: View {
    let values: [MacPlaybackProgress]
    let selected: (MacPlaybackProgress) -> Void
    @AppStorage("experimentalCardRadiusScale") private var cardRadiusScale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Continue Watching").font(.title2.bold())
                .padding(.horizontal, 34)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 15) {
                    ForEach(values.prefix(12)) { value in
                        Button { selected(value) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                MacCachedImage(
                                    url: value.identity.item.backdropURL ?? value.identity.item.posterURL,
                                    targetSize: CGSize(width: 238, height: 134),
                                    placeholderSystemImage: "play.rectangle"
                                )
                                .frame(width: 238, height: 134)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 14 * resolvedRadiusScale, style: .continuous))
                                Text(value.identity.displayTitle).font(.headline).lineLimit(1)
                                ProgressView(value: value.fraction).tint(.purple)
                            }
                            .frame(width: 238, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 34)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var resolvedRadiusScale: CGFloat {
        CGFloat(min(max(cardRadiusScale, 0.7), 1.4))
    }
}

private struct MacCatalogRail: View {
    let title: String
    let items: [MacMediaItem]
    @Binding var selectedItem: MacMediaItem?
    @EnvironmentObject private var catalog: MacCatalogStore
    @AppStorage("experimentalHomeCardShape") private var cardShape = "automatic"
    @AppStorage("experimentalMediaCardScale") private var cardScale = 1.0
    @AppStorage("experimentalMediaDesignPreset") private var designPreset = "cinematic"
    @AppStorage("experimentalCardRadiusScale") private var cardRadiusScale = 1.0

    private var resolvedArtworkStyle: MacMediaCardArtworkStyle {
        switch cardShape {
        case "landscape":
            return .landscape
        case "poster":
            return .poster
        default:
            let visibleItems = Array(items.prefix(15))
            return !visibleItems.isEmpty && visibleItems.allSatisfy { $0.backdropURL != nil }
                ? .landscape
                : .poster
        }
    }

    private var resolvedCardScale: CGFloat {
        let densityScale: Double
        switch designPreset {
        case "balanced": densityScale = 0.94
        case "compact": densityScale = 0.86
        default: densityScale = 1.0
        }
        return CGFloat(min(max(cardScale * densityScale, 0.68), 1.35))
    }

    private var resolvedCardRadius: CGFloat {
        let base: Double
        switch designPreset {
        case "balanced": base = 15
        case "compact": base = 13
        default: base = 16
        }
        return CGFloat(base * min(max(cardRadiusScale, 0.7), 1.4))
    }

    private var cardWidth: CGFloat {
        (resolvedArtworkStyle == .landscape ? 250 : 158) * resolvedCardScale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.title2.bold())
                .padding(.horizontal, 34)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items.prefix(15)) { item in
                        Button { selectedItem = item } label: {
                            MacHomeMediaCard(
                                item: item,
                                artworkStyle: resolvedArtworkStyle,
                                cornerRadius: resolvedCardRadius
                            )
                                .frame(width: cardWidth)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(catalog.isInLibrary(item) ? "Remove from Library" : "Add to Library") {
                                catalog.toggleLibrary(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
        }
        .animation(.easeInOut(duration: 0.22), value: cardShape)
        .animation(.easeInOut(duration: 0.22), value: resolvedCardScale)
    }
}

private struct MacHomeMediaCard: View {
    let item: MacMediaItem
    let artworkStyle: MacMediaCardArtworkStyle
    let cornerRadius: CGFloat
    @State private var isHovering = false

    private var artworkURL: URL? {
        switch artworkStyle {
        case .poster: item.posterURL ?? item.backdropURL
        case .landscape: item.backdropURL ?? item.posterURL
        }
    }

    private var artworkAspectRatio: CGFloat {
        artworkStyle == .landscape ? 16 / 9 : 2 / 3
    }

    private var targetSize: CGSize {
        artworkStyle == .landscape
            ? CGSize(width: 300, height: 169)
            : CGSize(width: 190, height: 285)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MacCachedImage(
                url: artworkURL,
                targetSize: targetSize,
                placeholderSystemImage: "film"
            )
            .aspectRatio(artworkAspectRatio, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(.white.opacity(isHovering ? 0.20 : 0.08))
            )
            .shadow(color: .black.opacity(isHovering ? 0.38 : 0.22), radius: isHovering ? 12 : 7, y: 5)

            Text(item.title)
                .font(.headline)
                .lineLimit(1)
            HStack {
                Text(item.date?.prefix(4) ?? "")
                Spacer()
                Label(String(format: "%.1f", item.rating), systemImage: "star.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .scaleEffect(isHovering ? 1.018 : 1)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

struct MacScheduleView: View {
    @EnvironmentObject private var catalog: MacCatalogStore
    @AppStorage("defaultScheduleMode") private var scheduleMode = "anime"
    @AppStorage("scheduleWindowDays") private var scheduleWindowDays = 7
    @AppStorage("showLocalScheduleTime") private var showLocalScheduleTime = true
    @AppStorage(MacSchedulePreferences.notificationsEnabledKey) private var notificationsEnabled = false
    @AppStorage("localNotificationEpisodeLeadTime") private var episodeLeadTime = 0
    @AppStorage("localNotificationSeasonLeadTime") private var seasonLeadTime = 86_400
    @AppStorage("localNotificationIncludeAnimeSpecials") private var includeAnimeSpecials = false
    @State private var selected: MacMediaItem?
    @State private var openingScheduleEntryID: String?
    @State private var scheduleOpenError: String?

    private var resolvedMode: String {
        ["anime", "western", "combined"].contains(scheduleMode) ? scheduleMode : "anime"
    }

    private var resolvedWindowDays: Int {
        [7, 14, 21, 30].contains(scheduleWindowDays) ? scheduleWindowDays : 7
    }

    private var loadIdentity: String {
        let libraryIDs = catalog.library
            .filter { $0.mediaType == "tv" }
            .map(\.stableID)
            .sorted()
            .joined(separator: ",")
        return "\(resolvedMode)-\(resolvedWindowDays)-\(libraryIDs)"
    }

    private var scheduleCalendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = showLocalScheduleTime
            ? .current
            : (TimeZone(secondsFromGMT: 0) ?? .current)
        return calendar
    }

    private var groupedEntries: [MacScheduleDayGroup] {
        let calendar = scheduleCalendar
        let groups = Dictionary(grouping: catalog.scheduleEntries) {
            calendar.startOfDay(for: $0.airDate)
        }

        let start = calendar.startOfDay(for: Date())
        return (0..<resolvedWindowDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else {
                return nil
            }
            return MacScheduleDayGroup(
                day: day,
                entries: groups[day, default: []].sorted { $0.airDate < $1.airDate }
            )
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                scheduleControls

                if let message = catalog.scheduleNotificationMessage {
                    Label(message, systemImage: notificationsEnabled ? "bell.badge.fill" : "bell.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }

                if let scheduleOpenError {
                    Label(scheduleOpenError, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                }

                if let error = catalog.scheduleErrorMessage, !catalog.scheduleEntries.isEmpty {
                    MacGlassPanel {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                }

                scheduleContent
            }
            .padding(28)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await load(forceReload: true)
        }
        .task(id: loadIdentity) {
            await load(forceReload: false)
        }
        .onChange(of: notificationsEnabled) { _, _ in
            Task { await catalog.syncScheduleNotifications() }
        }
        .onChange(of: episodeLeadTime) { _, _ in
            Task { await catalog.syncScheduleNotifications() }
        }
        .onChange(of: seasonLeadTime) { _, _ in
            Task { await catalog.syncScheduleNotifications() }
        }
        .onChange(of: includeAnimeSpecials) { _, _ in
            Task { await catalog.syncScheduleNotifications() }
        }
        .sheet(item: $selected) { item in
            MacMediaDetail(item: item)
        }
    }

    private var scheduleControls: some View {
        MacGlassPanel {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Upcoming Episodes", systemImage: "calendar.badge.clock")
                            .font(.title2.bold())
                        Text("Anime uses AniList with MyAnimeList fallback. Western TV uses Trakt with TVMaze fallback. TMDB is used only to open details and hydrate artwork.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 18)
                    if catalog.isLoadingSchedule {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await load(forceReload: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(catalog.isLoadingSchedule)
                }

                Divider().overlay(.white.opacity(0.08))

                HStack(spacing: 18) {
                    Picker("Schedule", selection: $scheduleMode) {
                        Text("Anime").tag("anime")
                        Text("Western").tag("western")
                        Text("Combined").tag("combined")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)

                    Picker("Range", selection: $scheduleWindowDays) {
                        ForEach([7, 14, 21, 30], id: \.self) { days in
                            Text("\(days) days").tag(days)
                        }
                    }
                    .frame(width: 145)

                    Picker("Timezone", selection: $showLocalScheduleTime) {
                        Text("Local").tag(true)
                        Text("UTC").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 205)
                    .help("Display schedule dates and times in \(showLocalScheduleTime ? "your Mac’s local time zone" : "UTC")")

                    Spacer()

                    Toggle(isOn: $notificationsEnabled) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Airing Reminders")
                            Text("Off by default")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .help("Does not request notification permission. Exact-time provider entries use their supplied airtime; date-only fallbacks use 9:00 AM local.")
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var scheduleContent: some View {
        if catalog.isLoadingSchedule && catalog.scheduleEntries.isEmpty {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Loading \(modeDisplayName.lowercased()) schedule…")
                    .font(.headline)
                Text(resolvedMode == "western" ? "Loading Trakt’s calendar, with TVMaze ready as fallback." : "Loading AniList’s airing calendar, with MyAnimeList ready as fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else if let error = catalog.scheduleErrorMessage, catalog.scheduleEntries.isEmpty {
            VStack(spacing: 15) {
                ContentUnavailableView(
                    "Couldn’t Load Schedule",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text(error)
                )
                Button("Try Again") { Task { await load(forceReload: true) } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else if catalog.scheduleEntries.isEmpty {
            ContentUnavailableView(
                "No Upcoming \(modeDisplayName) Episodes",
                systemImage: "calendar",
                description: Text(resolvedMode == "anime" ? "AniList and MyAnimeList have no upcoming anime airings in the next \(resolvedWindowDays) days." : "Trakt and TVMaze found no upcoming episodes in the next \(resolvedWindowDays) days. Try Combined or a longer range.")
            )
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            ForEach(groupedEntries) { group in
                MacScheduleDaySection(
                    group: group,
                    openingEntryID: openingScheduleEntryID,
                    timeZone: scheduleCalendar.timeZone
                ) { entry in
                    openScheduleEntry(entry)
                }
            }
        }
    }

    private var modeDisplayName: String {
        switch resolvedMode {
        case "western": "Western"
        case "combined": "Combined"
        default: "Anime"
        }
    }

    private func load(forceReload: Bool) async {
        await catalog.loadSchedule(
            windowDays: resolvedWindowDays,
            mode: resolvedMode,
            forceReload: forceReload
        )
    }

    private func openScheduleEntry(_ entry: MacScheduleEntry) {
        guard openingScheduleEntryID == nil else { return }
        scheduleOpenError = nil
        openingScheduleEntryID = entry.id
        Task {
            let item = await catalog.resolveScheduleEntry(entry)
            openingScheduleEntryID = nil
            if let item {
                selected = item
            } else {
                scheduleOpenError = "\(entry.source.displayName) supplied this airing, but Eclipse could not map the title to a playable TMDB detail page."
            }
        }
    }
}

private struct MacScheduleDayGroup: Identifiable {
    let day: Date
    let entries: [MacScheduleEntry]
    var id: Date { day }
}

private struct MacScheduleDaySection: View {
    let group: MacScheduleDayGroup
    let openingEntryID: String?
    let timeZone: TimeZone
    let open: (MacScheduleEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(formattedDay)
                    .font(.title3.bold())
                Text(relativeDay)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
                Spacer()
                Text("\(group.entries.count) episode\(group.entries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)

            MacGlassPanel {
                if group.entries.isEmpty {
                    Label("No episodes scheduled", systemImage: "calendar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Divider().overlay(.white.opacity(0.08)).padding(.leading, 112)
                            }
                            MacScheduleRow(
                                entry: entry,
                                isOpening: openingEntryID == entry.id,
                                timeZone: timeZone
                            ) { open(entry) }
                        }
                    }
                }
            }
        }
    }

    private var formattedDay: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        formatter.timeZone = timeZone
        return formatter.string(from: group.day)
    }

    private var relativeDay: String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        if calendar.isDateInToday(group.day) { return "Today" }
        if calendar.isDateInTomorrow(group.day) { return "Tomorrow" }
        let today = calendar.startOfDay(for: Date())
        let days = calendar.dateComponents([.day], from: today, to: group.day).day ?? 0
        return days > 1 ? "In \(days) days" : "Upcoming"
    }
}

private struct MacScheduleRow: View {
    let entry: MacScheduleEntry
    let isOpening: Bool
    let timeZone: TimeZone
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 16) {
                MacCachedImage(
                    url: entry.show.posterURL,
                    targetSize: CGSize(width: 76, height: 104),
                    placeholderSystemImage: "tv"
                )
                .frame(width: 76, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.09)))

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(entry.show.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(entry.classification == .anime ? "ANIME" : "TV")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(entry.classification == .anime ? .pink : .purple)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.07), in: Capsule())
                        Text(entry.source.displayName.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.055), in: Capsule())
                    }

                    Text(episodeDescription)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)

                    HStack(spacing: 12) {
                        Label(entry.hasKnownAiringTime ? formattedTime : "Time TBD", systemImage: "clock")
                        Label(entry.seriesStatus, systemImage: "dot.radiowaves.left.and.right")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 9) {
                    if isOpening {
                        ProgressView().controlSize(.small)
                    }
                    Text(entry.isSeasonPremiere ? "Season Premiere" : "Upcoming")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entry.isSeasonPremiere ? .pink : .purple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.08), in: Capsule())
                    Label("Open Details", systemImage: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var episodeDescription: String {
        entry.episodeTitle.isEmpty
            ? entry.episodeLabel
            : "\(entry.episodeLabel) · \(entry.episodeTitle)"
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        return formatter.string(from: entry.airDate)
    }
}

struct MacEmptyState: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(detail))
    }
}

struct MacLibraryView: View {
    let mode: MacMode
    @EnvironmentObject private var catalog: MacCatalogStore
    @EnvironmentObject private var aidoku: MacAidokuStore
    @State private var selectedManga: MacAidokuSearchItem?
    var body: some View {
        Group {
            if mode == .media, !catalog.library.isEmpty {
                ScrollView { MacMediaGrid(items: catalog.library).padding(28) }
            } else if mode == .reader, !aidoku.library.isEmpty {
                List(aidoku.library) { entry in
                    Button { selectedManga = entry.item } label: {
                        HStack(spacing: 14) {
                            AsyncImage(url: entry.item.manga.cover.flatMap(URL.init(string:))) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() }
                                else { Color.white.opacity(0.06).overlay(Image(systemName: "book.closed")) }
                            }.frame(width: 62, height: 88).clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.item.manga.title).font(.headline)
                                Text(entry.item.sourceName).font(.caption).foregroundStyle(.secondary)
                                if let chapter = entry.lastChapterTitle { Text("Last read: \(chapter)").font(.caption).foregroundStyle(.purple) }
                            }
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.contentShape(Rectangle()).padding(.vertical, 4)
                    }.buttonStyle(.plain)
                    .contextMenu { Button("Remove from Library", role: .destructive) { aidoku.toggleLibrary(entry.item) } }
                }
                .scrollContentBackground(.hidden)
            } else {
                MacEmptyState(title: mode == .media ? "Media Library" : "Kanzen Library", detail: "Synced and locally saved items will appear here.", icon: mode == .media ? "rectangle.stack" : "books.vertical")
            }
        }
        .sheet(item: $selectedManga) { MacAidokuDetailView(item: $0) }
    }
}

struct MacDownloadsView: View {
    let mode: MacMode
    @EnvironmentObject private var downloads: MacDownloadStore
    @EnvironmentObject private var playback: MacPlaybackController
    @EnvironmentObject private var aidoku: MacAidokuStore
    @EnvironmentObject private var reader: MacReaderController
    var body: some View {
        if mode == .media, !downloads.items.isEmpty {
            List(downloads.items) { item in
                HStack(spacing: 14) {
                    Image(systemName: item.state == .completed ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(item.state == .completed ? .green : .purple)
                    VStack(alignment: .leading) {
                        Text(item.title).font(.headline)
                        Text(item.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                        if item.state == .downloading {
                            ProgressView(value: item.progress).frame(maxWidth: 260).tint(.purple)
                            Text("\(Int(item.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let error = item.error { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                    Spacer()
                    if item.state == .completed {
                        Button("Play") { if let url = downloads.localURL(for: item) { playback.requestPlayback(url: url, title: item.title) } }
                        Button { downloads.reveal(item) } label: { Image(systemName: "folder") }.help("Reveal in Finder")
                        Button { downloads.export(item) } label: { Image(systemName: "square.and.arrow.up") }.help("Export")
                    } else if item.state == .failed || item.state == .queued {
                        Button("Retry") { downloads.begin(id: item.id) }
                    }
                    Button(role: .destructive) { downloads.delete(item) } label: { Image(systemName: "trash") }
                }
                .padding(.vertical, 5)
            }
            .scrollContentBackground(.hidden)
        } else if mode == .reader, !aidoku.offlineChapters.isEmpty {
            List(aidoku.offlineChapters) { chapter in
                HStack(spacing: 14) {
                    AsyncImage(url: chapter.item.manga.cover.flatMap(URL.init(string:))) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { Color.white.opacity(0.06).overlay(Image(systemName: "book.closed")) }
                    }.frame(width: 52, height: 74).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chapter.item.manga.title).font(.headline)
                        Text(chapter.chapterTitle).font(.caption).foregroundStyle(.secondary)
                        Text("\(chapter.pages.count) pages · \(chapter.downloadedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Read") {
                        reader.open(
                            title: "\(chapter.item.manga.title) · \(chapter.chapterTitle)",
                            pages: aidoku.offlinePages(for: chapter),
                            trackingContext: chapter.trackingContext
                        )
                    }
                    Button { aidoku.revealOffline(chapter) } label: { Image(systemName: "folder") }
                    Button(role: .destructive) { aidoku.deleteOffline(chapter) } label: { Image(systemName: "trash") }
                }.padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
        } else {
            MacEmptyState(title: "Downloads", detail: "Downloads are managed inside Eclipse's sandbox and can be revealed or exported.", icon: "arrow.down.circle")
        }
    }
}

struct MacSearchView: View {
    let mode: MacMode
    @Binding var text: String
    @EnvironmentObject private var catalog: MacCatalogStore
    @EnvironmentObject private var aidoku: MacAidokuStore
    @State private var selectedManga: MacAidokuSearchItem?
    @State private var selectedMedia: MacMediaItem?
    @State private var mediaFilter = "all"
    @State private var recentSearches: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(mode == .media ? "Search movies and shows" : "Search manga and novels", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { commitSearch() }
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
                if mode == .media {
                    Picker("Type", selection: $mediaFilter) {
                        Text("All").tag("all")
                        Text("Movies").tag("movie")
                        Text("Shows").tag("tv")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.10)))
            .padding(28)
            if text.isEmpty {
                emptySearchContent
            } else if mode == .media, !filteredMediaResults.isEmpty {
                ScrollView { MacMediaGrid(items: filteredMediaResults).padding(.horizontal, 28).padding(.bottom, 28) }
            } else if mode == .reader, !aidoku.searchResults.isEmpty {
                readerResults
            } else {
                MacEmptyState(
                    title: (mode == .media ? catalog.isLoading : aidoku.isWorking) ? "Searching" : "No Results",
                    detail: (mode == .media ? catalog.errorMessage : aidoku.errorMessage) ?? (mode == .reader && aidoku.installedSources.filter(\.isEnabled).isEmpty ? "Install an Aidoku source in Settings first." : "Try another title."),
                    icon: "magnifyingglass"
                )
                .frame(maxHeight: .infinity)
            }
        }
        .onChange(of: text) { _, value in
            if mode == .media { catalog.search(value) } else { aidoku.search(value) }
        }
        .task(id: mode) {
            recentSearches = UserDefaults.standard.stringArray(forKey: recentSearchKey) ?? []
            if mode == .media { await catalog.loadHomeIfNeeded() }
        }
        .sheet(item: $selectedManga) { MacAidokuDetailView(item: $0) }
        .sheet(item: $selectedMedia) { MacMediaDetail(item: $0) }
    }

    private var filteredMediaResults: [MacMediaItem] {
        guard mediaFilter != "all" else { return catalog.searchResults }
        return catalog.searchResults.filter { $0.mediaType == mediaFilter }
    }

    private var recentSearchKey: String { mode == .media ? "macRecentMediaSearches" : "macRecentReaderSearches" }

    @ViewBuilder
    private var emptySearchContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Search Eclipse").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(mode == .media ? "Find TMDB movies and shows, then open Eclipse Services from a title." : "Search every enabled Aidoku reader source.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if mode == .media, !catalog.trending.isEmpty {
                        Button { selectedMedia = catalog.trending.randomElement() } label: { Label("Surprise Me", systemImage: "shuffle") }
                            .buttonStyle(.borderedProminent)
                    }
                }

                if !recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("Recent Searches").font(.title3.bold()); Spacer(); Button("Clear") { clearRecentSearches() }.buttonStyle(.plain).foregroundStyle(.secondary) }
                        ScrollView(.horizontal) {
                            HStack(spacing: 9) {
                                ForEach(recentSearches, id: \.self) { query in
                                    Button(query) { text = query }
                                        .buttonStyle(.bordered)
                                        .buttonBorderShape(.capsule)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }

                if mode == .media, !catalog.trending.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Browse Trending").font(.title2.bold())
                        MacMediaGrid(items: Array(catalog.trending.prefix(12)))
                    }
                } else if mode == .reader, aidoku.installedSources.filter(\.isEnabled).isEmpty {
                    MacEmptyState(title: "No Reader Sources", detail: "Install and enable an Aidoku source in Settings before searching.", icon: "books.vertical")
                        .frame(minHeight: 230)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private var readerResults: some View {
        List(aidoku.searchResults) { item in
            Button { selectedManga = item } label: {
                HStack(spacing: 14) {
                    AsyncImage(url: item.manga.cover.flatMap(URL.init(string:))) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { Color.white.opacity(0.06).overlay(Image(systemName: "book.closed")) }
                    }
                    .frame(width: 56, height: 78).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.manga.title).font(.headline)
                        Text(item.sourceName).font(.caption).foregroundStyle(.secondary)
                        if let description = item.manga.description { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.vertical, 4)
        }
        .scrollContentBackground(.hidden)
    }

    private func commitSearch() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        recentSearches.insert(query, at: 0)
        recentSearches = Array(recentSearches.prefix(10))
        UserDefaults.standard.set(recentSearches, forKey: recentSearchKey)
        if mode == .media { catalog.search(query) } else { aidoku.search(query) }
    }

    private func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: recentSearchKey)
    }
}

private struct MacAidokuDetailView: View {
    let item: MacAidokuSearchItem
    @EnvironmentObject private var aidoku: MacAidokuStore
    @EnvironmentObject private var reader: MacReaderController
    @Environment(\.dismiss) private var dismiss
    @State private var manga: AidokuRunner.Manga?
    @State private var isLoading = true
    @State private var openingChapter: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                AsyncImage(url: (manga?.cover ?? item.manga.cover).flatMap(URL.init(string:))) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { Color.white.opacity(0.06).overlay(Image(systemName: "book.closed")) }
                }
                .frame(width: 120, height: 175).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 8) {
                    Text(manga?.title ?? item.manga.title).font(.largeTitle.bold())
                    Text(item.sourceName).foregroundStyle(.secondary)
                    if let description = manga?.description ?? item.manga.description {
                        Text(description).lineLimit(6).foregroundStyle(.secondary)
                    }
                    if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                    Button(aidoku.isInLibrary(item) ? "Remove from Library" : "Add to Library") {
                        aidoku.toggleLibrary(item)
                    }
                }
            }
            Divider()
            if isLoading {
                HStack { ProgressView(); Text("Loading chapters…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let chapters = manga?.chapters, !chapters.isEmpty {
                List(chapters.reversed(), id: \.key) { chapter in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(chapter.title?.isEmpty == false ? chapter.title! : "Chapter \(chapter.chapterNumber.map { String(format: "%g", $0) } ?? "")")
                            HStack {
                                if let language = chapter.language { Text(language.uppercased()) }
                                if let group = chapter.scanlators?.joined(separator: ", ") { Text(group) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if openingChapter == chapter.key { ProgressView().controlSize(.small) }
                        Button("Read") { Task { await open(chapter) } }.disabled(openingChapter != nil || chapter.locked)
                        Button(aidoku.isDownloaded(item: item, chapter: chapter) ? "Downloaded" : "Download") {
                            if let manga { Task { await aidoku.downloadChapter(item: item, manga: manga, chapter: chapter) } }
                        }
                        .disabled(aidoku.isDownloaded(item: item, chapter: chapter) || aidoku.isWorking || manga == nil || chapter.locked)
                    }.padding(.vertical, 3)
                }
            } else {
                ContentUnavailableView("No Chapters", systemImage: "books.vertical")
            }
            HStack { Spacer(); Button("Close", role: .cancel) { dismiss() } }
        }
        .padding(22).frame(width: 760, height: 640)
        .task {
            do { manga = try await aidoku.details(for: item) }
            catch { errorMessage = error.localizedDescription }
            isLoading = false
        }
    }

    private func open(_ chapter: AidokuRunner.Chapter) async {
        guard let manga else { return }
        openingChapter = chapter.key; errorMessage = nil
        do {
            let pages = try await aidoku.pages(sourceID: item.sourceID, manga: manga, chapter: chapter)
            reader.open(
                title: "\(manga.title) · \(chapter.title ?? "Chapter")",
                pages: pages,
                trackingContext: aidoku.trackingContext(for: manga, chapter: chapter)
            )
            aidoku.recordRead(item: item, chapter: chapter)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
        openingChapter = nil
    }
}
