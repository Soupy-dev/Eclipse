import SwiftUI
import Kingfisher
import AVKit
#if canImport(Darwin)
import Darwin
#endif

func homeImageDecodeSize(width: CGFloat, height: CGFloat) -> CGSize {
#if os(iOS) || os(tvOS)
    let scale = UIScreen.main.scale
#else
    let scale: CGFloat = 2
#endif
    return CGSize(width: max(width * scale, 1), height: max(height * scale, 1))
}

private func homeTMDBRatingText(_ voteAverage: Double?) -> String? {
    guard let voteAverage, voteAverage > 0 else { return nil }
    return String(format: "%.1f", voteAverage)
}

private struct HomeCardSubtitle: View {
    let result: TMDBSearchResult

    private var year: String? {
        result.displayDate.isEmpty ? nil : String(result.displayDate.prefix(4))
    }

    private var rating: String? {
        homeTMDBRatingText(result.voteAverage)
    }

    var body: some View {
        HStack(spacing: 4) {
            if let year {
                Text(year)
            }

            if year != nil && rating != nil {
                Text("·")
            }

            if let rating {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text(rating)
            }
        }
    }
}

private enum HeroCarouselDirection {
    case forward
    case backward
}

struct AppPerformanceSnapshot {
    var cpuPercent: Double? = nil
    var memoryFootprintBytes: UInt64? = nil
    var cpuText = "Measuring…"
    var ramText = "Measuring…"
    var thermalState = ProcessInfo.processInfo.thermalState
    var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
}

struct AppPerformanceLogContext: Equatable {
    let surface: String
    let appMode: String
    let startupPhase: String
    let homeHydrationComplete: Bool
    let splashVisible: Bool
    let motion: String
    let reduceMotion: Bool
    let modeSwitchActive: Bool

    var fields: String {
        "surface=\(surface) mode=\(appMode) startup=\(startupPhase) hydration=\(homeHydrationComplete ? "complete" : "running") splash=\(splashVisible ? 1 : 0) motion=\(motion) reduceMotion=\(reduceMotion ? 1 : 0) modeSwitch=\(modeSwitchActive ? 1 : 0)"
    }
}

@MainActor
final class AppPerformanceRuntimeContext {
    static let shared = AppPerformanceRuntimeContext()

    let launchUptime = ProcessInfo.processInfo.systemUptime
    private(set) var surface = "startup"

    var launchElapsedMilliseconds: Int {
        max(Int((ProcessInfo.processInfo.systemUptime - launchUptime) * 1_000), 0)
    }

    func setSurface(_ surface: String) {
        let normalized = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        self.surface = normalized.isEmpty ? "unknown" : normalized
    }
}

@MainActor
final class AppPerformanceMonitor: ObservableObject {
    @Published private(set) var snapshot = AppPerformanceSnapshot()

    private var lastCPUProcessTime: TimeInterval?
    private var lastCPUWallTime: TimeInterval?
    private var diagnosticSessionID = ""
    private var diagnosticSequence = 0
    private var diagnosticSessionActive = false
    private var recentCPUValues: [Double] = []
    private var consecutiveRecoverySamples = 0
    private var spikeActive = false
    private var lastSpikeLogUptime: TimeInterval = 0
    private var lastLogContext: AppPerformanceLogContext?

    @discardableResult
    func beginSampling(context: AppPerformanceLogContext) -> String {
        if diagnosticSessionActive {
            stop(context: lastLogContext, reason: "context-restart")
        }
        resetBaselines()
        diagnosticSessionID = String(UUID().uuidString.prefix(8))
        diagnosticSequence = 0
        diagnosticSessionActive = true
        recentCPUValues.removeAll(keepingCapacity: true)
        consecutiveRecoverySamples = 0
        spikeActive = false
        lastSpikeLogUptime = 0
        lastLogContext = context
        Logger.shared.log(
            "perf event=begin sid=\(diagnosticSessionID) launchMs=\(launchElapsedMilliseconds) overlay=visible \(context.fields)",
            type: "Performance"
        )
        _ = sample()
        return diagnosticSessionID
    }

    func stop(
        sessionID: String? = nil,
        context: AppPerformanceLogContext? = nil,
        reason: String = "stopped"
    ) {
        if let sessionID, sessionID != diagnosticSessionID { return }
        if diagnosticSessionActive {
            let fields = (context ?? lastLogContext)?.fields ?? "surface=unknown"
            Logger.shared.log(
                "perf event=end sid=\(diagnosticSessionID) seq=\(diagnosticSequence) launchMs=\(launchElapsedMilliseconds) reason=\(reason) \(fields)",
                type: "Performance"
            )
        }
        diagnosticSessionActive = false
        resetBaselines()
    }

    func sampleNow(context: AppPerformanceLogContext, sessionID: String) {
        guard diagnosticSessionActive, sessionID == diagnosticSessionID else { return }
        let sampled = sample()
        diagnosticSequence += 1

        if lastLogContext != context {
            Logger.shared.log(
                "perf event=context sid=\(diagnosticSessionID) seq=\(diagnosticSequence) launchMs=\(launchElapsedMilliseconds) \(context.fields)",
                type: "Performance"
            )
            lastLogContext = context
            recentCPUValues.removeAll(keepingCapacity: true)
            spikeActive = false
            consecutiveRecoverySamples = 0
        }

        guard let cpu = sampled.cpuPercent else { return }
        let baseline = median(recentCPUValues)
        let relativeSpike = baseline.map { cpu >= 20 && cpu - $0 >= 15 } ?? false
        let thresholdSpike = cpu >= 30 || relativeSpike
        let now = ProcessInfo.processInfo.systemUptime

        if thresholdSpike, !spikeActive || now - lastSpikeLogUptime >= 10 {
            Logger.shared.log(
                "perf event=spike sid=\(diagnosticSessionID) seq=\(diagnosticSequence) launchMs=\(launchElapsedMilliseconds) \(metricFields(sampled, baseline: baseline)) \(context.fields)",
                type: "Performance"
            )
            spikeActive = true
            consecutiveRecoverySamples = 0
            lastSpikeLogUptime = now
        } else if spikeActive {
            let recoveryCeiling = (baseline ?? 10) + 5
            consecutiveRecoverySamples = cpu <= recoveryCeiling ? consecutiveRecoverySamples + 1 : 0
            if consecutiveRecoverySamples >= 3 {
                Logger.shared.log(
                    "perf event=recovery sid=\(diagnosticSessionID) seq=\(diagnosticSequence) launchMs=\(launchElapsedMilliseconds) \(metricFields(sampled, baseline: baseline)) \(context.fields)",
                    type: "Performance"
                )
                spikeActive = false
                consecutiveRecoverySamples = 0
            }
        }

        if diagnosticSequence.isMultiple(of: 5) {
            Logger.shared.log(
                "perf event=sample sid=\(diagnosticSessionID) seq=\(diagnosticSequence) launchMs=\(launchElapsedMilliseconds) \(metricFields(sampled, baseline: baseline)) \(context.fields)",
                type: "Performance"
            )
        }

        recentCPUValues.append(cpu)
        if recentCPUValues.count > 10 {
            recentCPUValues.removeFirst(recentCPUValues.count - 10)
        }
    }

    private func resetBaselines() {
        lastCPUProcessTime = nil
        lastCPUWallTime = nil
        snapshot = AppPerformanceSnapshot()
    }

    @discardableResult
    private func sample() -> AppPerformanceSnapshot {
        let cpuPercent = processCPUUsagePercent()
        let cpuText = cpuPercent.map { String(format: "%.0f%%", $0) } ?? "Measuring…"
        let memoryFootprintBytes = processMemoryFootprintBytes()
        let ramText = memoryFootprintBytes.map(formatMemory) ?? "n/a"
        let sampled = AppPerformanceSnapshot(
            cpuPercent: cpuPercent,
            memoryFootprintBytes: memoryFootprintBytes,
            cpuText: cpuText,
            ramText: ramText,
            thermalState: ProcessInfo.processInfo.thermalState,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        snapshot = sampled
        return sampled
    }

    private var launchElapsedMilliseconds: Int {
        AppPerformanceRuntimeContext.shared.launchElapsedMilliseconds
    }

    private func metricFields(_ snapshot: AppPerformanceSnapshot, baseline: Double?) -> String {
        let cpu = snapshot.cpuPercent.map { String(format: "%.1f", $0) } ?? "na"
        let ramMB = snapshot.memoryFootprintBytes.map { String(format: "%.1f", Double($0) / 1_048_576.0) } ?? "na"
        let median = baseline.map { String(format: "%.1f", $0) } ?? "na"
        return "cpuCore=\(cpu) cpuMedian=\(median) ramMB=\(ramMB) thermal=\(thermalName(snapshot.thermalState)) power=\(snapshot.lowPowerModeEnabled ? "low" : "normal")"
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func processCPUUsagePercent() -> Double? {
#if canImport(Darwin)
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }

        let userTime = TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000.0
        let systemTime = TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000.0
        let processTime = userTime + systemTime
        let wallTime = ProcessInfo.processInfo.systemUptime

        guard let previousProcessTime = lastCPUProcessTime,
              let previousWallTime = lastCPUWallTime else {
            lastCPUProcessTime = processTime
            lastCPUWallTime = wallTime
            return nil
        }

        let wallDelta = wallTime - previousWallTime
        let processDelta = processTime - previousProcessTime
        lastCPUProcessTime = processTime
        lastCPUWallTime = wallTime
        guard wallDelta > 0.05, processDelta >= 0 else { return nil }
        return min(max((processDelta / wallDelta) * 100.0, 0), 999)
#else
        return nil
#endif
    }

    private func processMemoryFootprintBytes() -> UInt64? {
#if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), integerPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
#else
        return nil
#endif
    }

    private func formatMemory(_ bytes: UInt64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
    }
}

struct AppPerformanceOverlay: View {
    let snapshot: AppPerformanceSnapshot
    let backgroundQuality: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("CPU", snapshot.cpuText)
            row("RAM", snapshot.ramText)
            row("Thermal", thermalName)
            row("Power", snapshot.lowPowerModeEnabled ? "Low Power" : "Normal")
            row("Motion", backgroundQuality)
        }
        .frame(width: 150, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(valueColor(label: label, value: value))
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .lineLimit(1)
    }

    private var thermalName: String {
        switch snapshot.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func valueColor(label: String, value: String) -> Color {
        if label == "Thermal" {
            switch snapshot.thermalState {
            case .nominal: return .green
            case .fair: return .yellow
            case .serious: return .orange
            case .critical: return .red
            @unknown default: return .white
            }
        }
        if label == "Power", snapshot.lowPowerModeEnabled { return .yellow }
        if value == "n/a" || value == "Measuring…" { return .white.opacity(0.7) }
        return .white
    }
}

#if os(tvOS)
private enum TVHeroFocusTarget: Hashable {
    case hero
    case watchNow
    case watchlist
}

private struct TVHeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
#endif

private struct EclipseStartupOverlayVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var eclipseStartupOverlayVisible: Bool {
        get { self[EclipseStartupOverlayVisibleKey.self] }
        set { self[EclipseStartupOverlayVisibleKey.self] = newValue }
    }
}

struct HomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.eclipseStartupOverlayVisible) private var startupOverlayVisible

    private let isActive: Bool
    private let onStartupReady: () -> Void
    @State private var showingSettings = false
    @State private var isViewVisible = false
    @State private var isHoveringWatchNow = false
    @State private var isHoveringWatchlist = false
    @State private var continueWatchingItems: [ContinueWatchingItem] = []
    @State private var upNextItems: [ContinueWatchingItem] = []
    @State private var traktContinueWatchingItems: [ContinueWatchingItem] = []
    @State private var continueWatchingRefreshID = UUID()
    @State private var traktContinueWatchingRefreshTask: Task<Void, Never>?
    @State private var upNextResolvedSignature = ""
    @State private var upNextResolvedOwner: UUID?
    @State private var upNextResolvedKidsMode = false
    @State private var upNextInFlightSignature = ""
    @State private var upNextResolveTask: Task<Void, Never>?

    @State private var continueWatchingProfileFilterTask: Task<Void, Never>?

    @State private var continueWatchingVettedOwner: UUID?

    @State private var maturityRevisionReloadTask: Task<Void, Never>?
    @State private var pendingContinueWatchingProgressRefreshTask: Task<Void, Never>?
    @State private var didReportStartupReady = false
    @State private var didReportInitialHydration = false
    @State private var observedPerformanceMode = PerformanceModeSettings.isEnabled
    @State private var observedHomeCatalogSignature = ""
    @State private var pendingHomeCatalogReloadTask: Task<Void, Never>?
    @State private var heroCarouselTimerResetID = UUID()
    @State private var lastManualHeroAdvanceUptime: TimeInterval = 0
    @State private var selectedHeroForDetail: TMDBSearchResult?
    @State private var showingHeroDetail = false
    @State private var heroLogoURL: String?
    @State private var heroAlternatePosterURL: String?
    @State private var heroArtworkIdentity: String?
    @State private var prefetchedHeroAlternatePosterURLs: [String: String] = [:]
#if os(tvOS)
    @FocusState private var tvHeroFocus: TVHeroFocusTarget?
    @State private var focusedHeroSnapshot: TMDBSearchResult?
#endif
    @ObservedObject private var libraryManager = LibraryManager.shared
    @ObservedObject private var trackerManager = TrackerManager.shared
    @State private var scrollOffset: CGFloat = 0

    @AppStorage("tmdbLanguage") private var selectedLanguage = "en-US"

    @StateObject private var homeViewModel = HomeViewModel()
    @StateObject private var catalogManager = CatalogManager.shared
    @StateObject private var tmdbService = TMDBService.shared
    @StateObject private var contentFilter = TMDBContentFilter.shared
    @ObservedObject private var theme = EclipseTheme.shared
    @AppStorage(MediaDetailAlternatePosterSettings.enabledKey) private var mediaDetailAlternatePosterEnabled = MediaDetailAlternatePosterSettings.defaultEnabled
    @AppStorage("heroBannerCatalogId") private var heroBannerCatalogId = "trending"
    @AppStorage("heroBannerBehavior") private var heroBannerBehavior = HeroBannerBehavior.defaultValue.rawValue
    @AppStorage(HomeAnimatedBackgroundSettings.enabledKey) private var homeAnimatedBackgroundEnabled = HomeAnimatedBackgroundSettings.defaultEnabled
    @AppStorage(ExperimentalMediaDesignPreset.storageKey) private var experimentalDesignPreset = ExperimentalMediaDesignPreset.defaultValue.rawValue
    @AppStorage(ExperimentalHeroBleedLevel.storageKey) private var experimentalHeroBleedLevel = ExperimentalHeroBleedLevel.defaultValue.rawValue
    @AppStorage(ExperimentalHomeCardShape.storageKey) private var experimentalHomeCardShape = ExperimentalHomeCardShape.defaultValue.rawValue
    @AppStorage(ExperimentalVisualTuning.mediaCardScaleKey) private var experimentalMediaCardScale = ExperimentalVisualTuning.defaultMediaCardScale
#if os(tvOS)

    @AppStorage("tvCardDensity") private var tvCardDensity = "standard"
#endif
    @StateObject private var layoutStore = HomeCatalogLayoutStore.shared

    init(isActive: Bool = true, onStartupReady: @escaping () -> Void = {}) {
        self.isActive = isActive
        self.onStartupReady = onStartupReady
    }

    private var effectiveIsActive: Bool {
        isActive && isViewVisible && scenePhase == .active && !startupOverlayVisible
    }

    private var ambientMotionIsActive: Bool {
        !reduceMotion &&
            effectiveIsActive &&
            !showingSettings &&
            !showingHeroDetail
    }

    private var enabledCatalogs: [Catalog] {
        return catalogManager.getEnabledCatalogs()
    }

    private var heroHeight: CGFloat {
#if os(tvOS)
        UIScreen.main.bounds.height * 0.8
#else
        if ExperimentalFeatureState.isEnabledAtLaunch {
            return designMetrics.homeHeroHeight(screenHeight: UIScreen.main.bounds.height, isIPad: isIPad)
        }
        return isIPad ? 720 : 580
#endif
    }

    private var ambientColor: Color { homeViewModel.ambientColor }
    private var atmosphereColor: Color { theme.atmosphereColor(dominant: ambientColor) }
    private var currentHeroImageURL: String? {
        guard let hero = homeViewModel.heroContent else { return nil }
        return heroImageURL(for: hero)
    }
    private var heroLogoLoadKey: String {
        "\(selectedLanguage)|\(homeViewModel.heroContent?.stableIdentity ?? "empty")"
    }

    private var heroLogoMaxWidth: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch
            ? (isTvOS ? 720 : (isIPad ? 520 : 334))
            : (isIPad ? 400 : 280)
    }
    private var heroLogoMaxHeight: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch
            ? (isTvOS ? 250 : (isIPad ? 178 : 132))
            : (isIPad ? 140 : 100)
    }
    private var heroLogoDecodeSize: CGSize {
        homeImageDecodeSize(width: heroLogoMaxWidth, height: heroLogoMaxHeight)
    }
    private var heroImageDecodeSize: CGSize {
        homeImageDecodeSize(width: UIScreen.main.bounds.width, height: heroHeight)
    }
    private var designMetrics: ExperimentalMediaDesignMetrics {

#if os(tvOS)

        _ = tvCardDensity
        let tuning = ExperimentalVisualTuning.current
#else
        var tuning = ExperimentalVisualTuning.current
        tuning.mediaCardScale = ExperimentalVisualTuning.sanitizedMediaCardScale(experimentalMediaCardScale)
#endif
        return ExperimentalMediaDesignMetrics(
            preset: ExperimentalMediaDesignPreset(rawValue: experimentalDesignPreset) ?? ExperimentalMediaDesignPreset.defaultValue,
            heroBleedLevel: ExperimentalHeroBleedLevel(rawValue: experimentalHeroBleedLevel) ?? ExperimentalHeroBleedLevel.defaultValue,
            cardShape: ExperimentalHomeCardShape(rawValue: experimentalHomeCardShape) ?? ExperimentalHomeCardShape.defaultValue,
            tuning: tuning
        )
    }

    private func metrics(for catalog: Catalog) -> ExperimentalMediaDesignMetrics {
        let base = designMetrics
        let override = layoutStore.override(for: catalog.id)
        guard !override.isEmpty else { return base }
        var tuning = base.tuning
        if let sizeScale = override.sizeScale {
            tuning.mediaCardScale = ExperimentalVisualTuning.sanitizedMediaCardScale(sizeScale)
        }
        let cardShape = override.orientation.cardShape ?? base.cardShape
        return ExperimentalMediaDesignMetrics(
            preset: base.preset,
            heroBleedLevel: base.heroBleedLevel,
            cardShape: cardShape,
            tuning: tuning
        )
    }

    private var tracksBackgroundScroll: Bool {
#if os(iOS)
        !isIPad
#else
        true
#endif
    }

    private var backgroundScrollOffset: CGFloat {
        tracksBackgroundScroll ? scrollOffset : 0
    }

    private var animatedBackgroundTopClearance: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch ? 88 : 56
    }

    private var scrollOffsetUpdateThreshold: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch ? designMetrics.scrollOffsetThreshold : 8
    }

    var body: some View {
#if os(tvOS)
        homeContent
#else
        if #available(iOS 16.0, *) {
            NavigationStack {
                homeContent
            }
        } else {
            NavigationView {
                homeContent
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
#endif
    }

    private var homeContent: some View {
        ZStack {
            if ExperimentalFeatureState.isEnabledAtLaunch {
                AtmosphereBackdrop(
                    input: theme.atmosphereInput(
                        dominant: ambientColor,
                        hasHeroBleed: false,
                        heroHeight: heroHeight,
                        fadeDistance: heroHeight * 0.6
                    ),
                    scrollOffset: backgroundScrollOffset
                )
                .ignoresSafeArea(.all)
            } else {
                GlobalGradientBackground(scrollOffset: backgroundScrollOffset, allowsAnimatedBackground: false)
                    .ignoresSafeArea(.all)

                Group {
                    theme.atmosphereStyle == .solid ? atmosphereColor : homeViewModel.ambientColor
                }
                .ignoresSafeArea(.all)
            }

            if homeAnimatedBackgroundEnabled {
                EclipseIsolatedAmbientMotionBackground(
                    topClearance: animatedBackgroundTopClearance,
                    ambientColor: nil,
                    accentColor: theme.scopedGradientColor(),
                    motionEnabled: ambientMotionIsActive
                )
                .ignoresSafeArea(.all)
            }

            if homeViewModel.isLoading && !homeViewModel.hasRenderableStartupContent {
                loadingView
            } else if enabledCatalogs.isEmpty {
                noEnabledCatalogsView
            } else if let errorMessage = homeViewModel.errorMessage {
                errorView(errorMessage)
            } else {
                mainScrollView
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            isViewVisible = true
            refreshContinueWatchingItems()
            let catalogSignature = currentHomeCatalogSignature()
            if observedHomeCatalogSignature.isEmpty ||
                (!homeViewModel.hasLoadedContent &&
                 !homeViewModel.hasCompletedInitialLoad) {
                observedHomeCatalogSignature = catalogSignature
            } else if observedHomeCatalogSignature != catalogSignature {
                scheduleHomeCatalogReloadIfNeeded()
            }
            if homeViewModel.hasRenderableStartupContent || homeViewModel.hasCompletedInitialLoad {
                reportStartupReadyIfNeeded()
            }
            if homeViewModel.hasCompletedInitialLoad {
                reportInitialHydrationIfNeeded()
            }
            if !homeViewModel.hasLoadedContent {
                homeViewModel.loadContent(tmdbService: tmdbService, catalogManager: catalogManager, contentFilter: contentFilter)
            }
        }
        .task(id: "\(heroLogoLoadKey)|\(effectiveIsActive)") {
            guard effectiveIsActive else { return }
            await loadHeroArtwork(for: homeViewModel.heroContent, language: selectedLanguage)
        }
        .task(id: "hero-prefetch|\(heroLogoLoadKey)|\(effectiveIsActive)") {
            guard effectiveIsActive,
                  heroBannerBehavior == HeroBannerBehavior.carousel.rawValue else { return }
            await prefetchUpcomingHeroImages()
        }
        .onDisappear {
            isViewVisible = false
            pendingHomeCatalogReloadTask?.cancel()
            pendingHomeCatalogReloadTask = nil
            pendingContinueWatchingProgressRefreshTask?.cancel()
            pendingContinueWatchingProgressRefreshTask = nil
            cancelTraktContinueWatchingRefresh(clearItems: false)
        }
        .onChangeComp(of: homeViewModel.hasCompletedInitialLoad) { _, hasCompletedInitialLoad in
            if hasCompletedInitialLoad {
                reportStartupReadyIfNeeded()
                reportInitialHydrationIfNeeded()
            }
        }
        .onChangeComp(of: homeViewModel.hasRenderableStartupContent) { _, hasRenderableContent in
            if hasRenderableContent {
                reportStartupReadyIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard effectiveIsActive else { return }
            refreshContinueWatchingItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerDidClose)) { _ in
            guard isActive else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard effectiveIsActive else { return }
                refreshContinueWatchingItems()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .progressDataDidChange)) { _ in
            guard effectiveIsActive else { return }
            scheduleContinueWatchingProgressRefresh()
        }
        .onChangeComp(of: trackerManager.trackerState.mergeTraktContinueWatching) { _, _ in
            guard effectiveIsActive else { return }
            refreshContinueWatchingItems()
        }
        .onReceive(trackerManager.$trackerState) { _ in
            guard effectiveIsActive else { return }
            refreshContinueWatchingItems()
            scheduleHomeCatalogReloadIfNeeded()
        }
        .onChangeComp(of: contentFilter.filterHorror) { _, _ in
            reloadHomeContentAfterFilterChange()
        }

        .onChangeComp(of: contentFilter.maturityRatingRevision) { _, _ in
            maturityRevisionReloadTask?.cancel()
            maturityRevisionReloadTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                reloadHomeContentAfterFilterChange()
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in

            cancelTraktContinueWatchingRefresh(clearItems: true)
            refreshContinueWatchingItems()
            reloadHomeContentForProfileChange()
        }
        .onChangeComp(of: heroBannerCatalogId) { _, _ in
            homeViewModel.refreshHeroContentForSettingsChange()
        }
        .onChangeComp(of: heroBannerBehavior) { _, _ in
            homeViewModel.refreshHeroContentForSettingsChange()
        }
        .onChangeComp(of: showingHeroDetail) { _, isPresented in
            if !isPresented {
                selectedHeroForDetail = nil
            }
        }
        .onReceive(catalogManager.$catalogs) { _ in
            guard effectiveIsActive else { return }
            refreshContinueWatchingItems()
            scheduleHomeCatalogReloadIfNeeded()
        }
        .onReceive(catalogManager.$performanceModeEnabled) { enabled in
            guard observedPerformanceMode != enabled else { return }
            observedPerformanceMode = enabled
            scheduleHomeCatalogReloadIfNeeded()
        }
        .onChangeComp(of: effectiveIsActive) { _, active in
            guard active else {
                pendingContinueWatchingProgressRefreshTask?.cancel()
                pendingContinueWatchingProgressRefreshTask = nil
                cancelTraktContinueWatchingRefresh(clearItems: false)
                return
            }
            refreshContinueWatchingItems()
            if observedHomeCatalogSignature != currentHomeCatalogSignature() {
                scheduleHomeCatalogReloadIfNeeded()
            }
        }
        .task(id: "\(effectiveIsActive)|\(heroCarouselTimerResetID.uuidString)") {
            guard effectiveIsActive else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 7_000_000_000)
                } catch {
                    return
                }
                guard effectiveIsActive, !showingHeroDetail else { continue }
#if os(tvOS)
                guard tvHeroFocus == nil else { continue }
#endif

                guard ProcessInfo.processInfo.systemUptime - lastManualHeroAdvanceUptime >= 7.0 else {
                    continue
                }
                advanceHeroCarousel(.forward)
            }
        }
        .background(heroDetailNavigationHost)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 16) {
            if effectiveIsActive {
                EclipseLoadingIndicator()
                    .scaleEffect(1.5)
            }
            Text("Loading amazing content...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 50))
                .foregroundColor(.orange)

            Text("Connection Error")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Retry") {
                loadContent()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var noEnabledCatalogsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 50))
                .foregroundColor(.accentColor)

            Text("No Catalogs Enabled")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enable at least one catalog in Settings to populate your home screen.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Open Settings") {
                showingSettings = true
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .foregroundColor(.white)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var mainScrollView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                heroSection
                postHeroSections
            }
            .background(
                Group {
                    if tracksBackgroundScroll {
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: -geo.frame(in: .named("homeScroll")).origin.y
                            )
                        }
                    }
                }
            )
            .heroBannerBleed(
                color: ExperimentalFeatureState.isEnabledAtLaunch ? heroBleedColor : nil,
                heroHeight: heroHeight,
                tail: heroHeight * 0.62,
                strength: theme.scopedBleedStrength()
            )
        }
        .coordinateSpace(name: "homeScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { newOffset in
            guard tracksBackgroundScroll else { return }
            guard abs(scrollOffset - newOffset) >= scrollOffsetUpdateThreshold else { return }
            scrollOffset = newOffset
        }
        .ignoresSafeArea(edges: [.top, .leading, .trailing])
    }

    private var postHeroSections: some View {
        VStack(spacing: 0) {
            continueWatchingSection
            contentSections
        }
    }

    @ViewBuilder
    private var continueWatchingSection: some View {
        if !continueWatchingItems.isEmpty {
            ContinueWatchingSection(
                items: continueWatchingItems,
                tmdbService: tmdbService,
                onDataChanged: refreshContinueWatchingItems,
                onSectionBecameEmpty: requestTVHomeFallbackFocus
            )
        }
    }

    @ViewBuilder
    private var heroSection: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch, homeViewModel.heroContent != nil {
#if os(tvOS)
            heroSectionBody
                .overlay(tvHeroPagingHints)
                .scaleEffect(tvHeroFocus == .hero ? 1.02 : 1.0)
                .brightness(tvHeroFocus == .hero ? 0.05 : 0)
                .animation(.easeOut(duration: 0.22), value: tvHeroFocus == .hero)
                .overlay(alignment: .bottom) {
                    Button {
                        guard let hero = focusedHeroSnapshot ?? homeViewModel.heroContent else { return }
                        openHeroDetail(hero)
                    } label: {
                        Color.clear
                            .frame(height: heroHeight * 0.55)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TVHeroButtonStyle())
                    .disabled(showingHeroDetail)
                    .focused($tvHeroFocus, equals: .hero)
                    .onMoveCommand { direction in
                        switch direction {
                        case .left:
                            advanceHeroCarouselManually(.backward)
                            focusedHeroSnapshot = homeViewModel.heroContent
                        case .right:
                            advanceHeroCarouselManually(.forward)
                            focusedHeroSnapshot = homeViewModel.heroContent
                        default:
                            break
                        }
                    }
                    .onChangeComp(of: tvHeroFocus) { _, focus in
                        if focus == .hero {
                            focusedHeroSnapshot = homeViewModel.heroContent
                        }
                    }
                    .accessibilityLabel(homeViewModel.heroContent?.displayTitle ?? "Featured title")
                    .accessibilityHint("Open details")
                }
#else
            heroSectionBody
                .onTapGesture {
                    openCurrentHeroDetail()
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    openCurrentHeroDetail()
                }
#endif
        } else {
            heroSectionBody
        }
    }

    @ViewBuilder
    private var heroDetailNavigationHost: some View {
        if #available(iOS 16.0, *) {
            Color.clear
                .navigationDestination(isPresented: $showingHeroDetail) {
                    if let selectedHeroForDetail {
                        MediaDetailView(searchResult: selectedHeroForDetail)
                    }
                }
        } else {
            NavigationLink(
                isActive: $showingHeroDetail,
                destination: {
                    if let selectedHeroForDetail {
                        MediaDetailView(searchResult: selectedHeroForDetail)
                    }
                },
                label: { EmptyView() }
            )
            .hidden()
        }
    }

    private func openCurrentHeroDetail() {
        guard let hero = homeViewModel.heroContent else { return }
        openHeroDetail(hero)
    }

    private func openHeroDetail(_ hero: TMDBSearchResult) {
        selectedHeroForDetail = hero
        showingHeroDetail = true
    }

    @ViewBuilder
    private var heroSectionBody: some View {
        let heroIdentity = homeViewModel.heroContent?.stableIdentity ?? "empty"

        ZStack(alignment: .bottom) {
            StretchyHeaderView(
                backdropURL: currentHeroImageURL,
                isMovie: homeViewModel.heroContent?.mediaType == "movie",
                headerHeight: heroHeight,
                minHeaderHeight: ExperimentalFeatureState.isEnabledAtLaunch ? max(380, heroHeight * 0.58) : 300,
                onAmbientColorExtracted: { color in
                    guard homeViewModel.heroContent?.stableIdentity == heroIdentity else { return }
                    homeViewModel.ambientColor = color
                },
                imageDecodeSize: heroImageDecodeSize
            )
            .id("hero-image-\(heroIdentity)")

            .transition(.opacity)

            heroGradientOverlay
                .allowsHitTesting(false)

            heroContentInfo
                .id("hero-content-\(heroIdentity)")
                .transition(.opacity)
        }
        .contentShape(Rectangle())
#if !os(tvOS)
        .simultaneousGesture(heroCarouselSwipeGesture)
#endif
        .animation(heroCarouselAnimation, value: heroIdentity)
    }

    private var heroCarouselAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.12) : .easeInOut(duration: 0.32)
    }

#if !os(tvOS)
    private var heroCarouselSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 28, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > 54, abs(horizontal) > abs(vertical) * 1.2 else {
                    return
                }

                advanceHeroCarouselManually(horizontal < 0 ? .forward : .backward)
            }
    }
#endif

    private func advanceHeroCarouselManually(_ direction: HeroCarouselDirection) {
        guard heroBannerBehavior == HeroBannerBehavior.carousel.rawValue,
              homeViewModel.heroCarouselCount > 1 else {
            return
        }

        lastManualHeroAdvanceUptime = ProcessInfo.processInfo.systemUptime
        heroCarouselTimerResetID = UUID()
        advanceHeroCarousel(direction)
    }

    private func advanceHeroCarousel(_ direction: HeroCarouselDirection) {

        homeViewModel.advanceHeroCarouselIfNeeded(by: direction == .forward ? 1 : -1)
    }

    private var heroBlendColor: Color {
        theme.heroBlendColor(dominant: ambientColor)
    }

    private var heroBleedColor: Color? {
        EclipseTheme.usableDominant(ambientColor)
    }

    @ViewBuilder
    private var heroGradientOverlay: some View {

        LinearGradient(
            gradient: Gradient(stops: ExperimentalFeatureState.isEnabledAtLaunch ? [
                .init(color: heroBlendColor.opacity(0.0), location: 0.0),
                .init(color: heroBlendColor.opacity(0.32), location: 0.34),
                .init(color: heroBlendColor.opacity(0.66), location: 0.62),
                .init(color: heroBlendColor.opacity(0.90), location: 0.84),
                .init(color: heroBlendColor.opacity(1.0), location: 1.0)
            ] : [
                .init(color: ambientColor.opacity(0.0), location: 0.0),
                .init(color: Color.black.opacity(0.26), location: 0.18),
                .init(color: atmosphereColor.opacity(0.72), location: 0.58),
                .init(color: atmosphereColor.opacity(1), location: 1.0)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: ExperimentalFeatureState.isEnabledAtLaunch ? designMetrics.heroBottomFadeHeight : 150)
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }

    @ViewBuilder
    private var heroContentInfo: some View {
        if let hero = homeViewModel.heroContent {
            if ExperimentalFeatureState.isEnabledAtLaunch {
                experimentalHeroContent(hero)
            } else {
                legacyHeroContent(hero)
            }
        }
    }

    @ViewBuilder
    private func experimentalHeroContent(_ hero: TMDBSearchResult) -> some View {
        VStack(alignment: .center, spacing: isTvOS ? 20 : (isIPad ? 13 : 10)) {
            if experimentalHeroShouldShowTitle(hero) {
                heroTitleArtwork(hero)
                    .padding(.horizontal, isTvOS ? 60 : (isIPad ? 90 : 24))
            }

            Text(experimentalMetadataLine(hero))
                .font(.system(size: isTvOS ? 29 : (isIPad ? 20 : 17), weight: .medium))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .padding(.horizontal, isTvOS ? 60 : (isIPad ? 90 : 22))
                .shadow(color: .black.opacity(0.7), radius: 8, x: 0, y: 3)

            if let overview = heroOverview(hero) {
                Text(overview)
                    .font(.system(size: isTvOS ? 29 : (isIPad ? 20 : 17), weight: .regular))
                    .shadow(color: .black.opacity(0.7), radius: 8, x: 0, y: 4)
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                    .padding(.horizontal, isTvOS ? 400 : (isIPad ? 110 : 30))
            }

            heroRatingsRow(hero)

            heroPagerDots
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, isTvOS ? 60 : (isIPad ? 58 : 48))
    }

    @ViewBuilder
    private var heroPagerDots: some View {
        let count = homeViewModel.heroCarouselCount
        if heroBannerBehavior == HeroBannerBehavior.carousel.rawValue && count > 1 {
            let current = homeViewModel.heroCarouselCurrentIndex
            HStack(spacing: isTvOS ? 22 : (isIPad ? 15 : 12)) {
                ForEach(Array(0..<count), id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity(index == current ? 0.95 : 0.38))
                        .frame(
                            width: isTvOS ? 16 : (isIPad ? 11 : 9),
                            height: isTvOS ? 16 : (isIPad ? 11 : 9)
                        )
                }
            }
            .padding(.top, isTvOS ? 8 : 2)
        }
    }

    @ViewBuilder
    private func legacyHeroContent(_ hero: TMDBSearchResult) -> some View {
        VStack(alignment: .center, spacing: isTvOS ? 30 : 12) {
            HStack {
                Text(hero.isMovie ? "Movie" : "TV Series")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, isTvOS ? 16 : 8)
                    .padding(.vertical, isTvOS ? 10 : 4)
                    .applyLiquidGlassBackground(cornerRadius: 12)

                if (hero.voteAverage ?? 0.0) > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)

                        Text(String(format: "%.1f", hero.voteAverage ?? 0.0))
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                    }
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, isTvOS ? 16 : 8)
                    .padding(.vertical, isTvOS ? 10 : 4)
                    .applyLiquidGlassBackground(cornerRadius: 12)
                }
            }

            heroTitleArtwork(hero)

            if let overview = hero.overview, !overview.isEmpty {
                Text(String(overview.prefix(100)) + (overview.count > 100 ? "..." : ""))
                    .font(.system(size: isTvOS ? 30 : 15))
                    .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 4)
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            HStack(spacing: 16) {
                Button(action: {
                    openHeroDetail(hero)
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.subheadline)
                        Text("Watch Now")
                            .fontWeight(.semibold)
                            .fixedSize()
                            .lineLimit(1)
                    }
                    .foregroundColor(isHoveringWatchNow ? .black : .white)
                    .tvos({ view in
                        view.frame(width: 200, height: 60)
                            .buttonStyle(PlainButtonStyle())
#if os(tvOS)
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(_): isHoveringWatchNow = true
                                case .ended: isHoveringWatchNow = false
                                }
                            }
#endif
                    }, else: { view in
                        view
                            .frame(width: 140, height: 42)
                            .buttonStyle(PlainButtonStyle())
                            .applyLiquidGlassBackground(cornerRadius: 12)
                    })
                }
                .buttonStyle(.plain)
#if os(tvOS)
                .focused($tvHeroFocus, equals: .watchNow)
                .onChangeComp(of: tvHeroFocus) { _, focus in
                    if focus == .watchNow {
                        focusedHeroSnapshot = hero
                    }
                }
#endif

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        libraryManager.toggleBookmark(for: hero)
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: libraryManager.isBookmarked(hero) ? "checkmark" : "plus")
                            .font(.subheadline)
                        Text(libraryManager.isBookmarked(hero) ? "In Watchlist" : "Watchlist")
                            .fontWeight(.semibold)
                            .fixedSize()
                            .lineLimit(1)
                    }
                    .foregroundColor(isHoveringWatchlist ? .black : .white)
                    .tvos({ view in
                        view.frame(width: 200, height: 60)
                            .buttonStyle(PlainButtonStyle())
#if os(tvOS)
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(_): isHoveringWatchlist = true
                                case .ended: isHoveringWatchlist = false
                                }
                            }
#endif
                    }, else: { view in
                        view.frame(width: 140, height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.black.opacity(0.3))
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(.white.opacity(0.3), lineWidth: 1)
                                    )
                            )
                    })
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
#if os(tvOS)
                .focused($tvHeroFocus, equals: .watchlist)
                .onChangeComp(of: tvHeroFocus) { _, focus in
                    if focus == .watchlist {
                        focusedHeroSnapshot = hero
                    }
                }
#endif
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }

    private func heroMetadataLine(_ hero: TMDBSearchResult) -> String {
        let date = hero.displayDate.isEmpty ? nil : String(hero.displayDate.prefix(10))
        let kind = hero.isMovie ? "Movie" : "TV Series"
        return [date, kind].compactMap { $0 }.joined(separator: " · ")
    }

    private func experimentalMetadataLine(_ hero: TMDBSearchResult) -> String {
        let date = hero.displayDate.isEmpty ? nil : String(hero.displayDate.prefix(10))
        let genres = genreNames(for: hero).prefix(3).joined(separator: ", ")
        let kind = genres.isEmpty ? (hero.isMovie ? "Movie" : "TV Series") : genres
        return [date, kind].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private func heroImageURL(for hero: TMDBSearchResult) -> String? {
        if ExperimentalFeatureState.isEnabledAtLaunch {
#if os(tvOS)
            return hero.fullBackdropURL ?? hero.fullPosterURL
#else
            if isIPad {
                return hero.fullBackdropURL ?? hero.fullPosterURL
            }
            return currentHeroAlternatePosterURL(for: hero)
                ?? hero.fullPosterURL
                ?? hero.fullBackdropURL
#endif
        }
        return hero.fullBackdropURL ?? hero.fullPosterURL
    }

    private func currentHeroAlternatePosterURL(for hero: TMDBSearchResult) -> String? {
        guard !isIPad,
              mediaDetailAlternatePosterEnabled else { return nil }
        if let prefetchedURL = prefetchedHeroAlternatePosterURLs[hero.stableIdentity] {
            return prefetchedURL
        }
        guard heroArtworkIdentity == hero.stableIdentity else { return nil }
        return heroAlternatePosterURL
    }

    private func isAnimeHero(_ hero: TMDBSearchResult) -> Bool {
        guard hero.genreIds?.contains(16) == true else { return false }

        let animeOriginCountries: Set<String> = ["JP", "CN", "KR", "TW"]
        if hero.originCountry?.contains(where: { animeOriginCountries.contains($0) }) == true {
            return true
        }

        guard let originalLanguage = hero.originalLanguage?.lowercased() else { return false }
        return ["ja", "zh", "ko"].contains(originalLanguage)
    }

    private func experimentalHeroShouldShowTitle(_ hero: TMDBSearchResult) -> Bool {
        currentHeroLogoURL(for: hero) != nil || hero.fullPosterURL == nil
    }

    private func heroOverview(_ hero: TMDBSearchResult) -> String? {
        guard let rawOverview = hero.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawOverview.isEmpty else {
            return nil
        }
        let limit = isIPad ? 180 : 125
        return rawOverview.count > limit ? "\(rawOverview.prefix(limit))..." : rawOverview
    }

    @ViewBuilder
    private func heroRatingsRow(_ hero: TMDBSearchResult) -> some View {
        let chips = heroRatingChips(for: hero)
        if !chips.isEmpty {
            HStack(spacing: isTvOS ? 24 : (isIPad ? 14 : 10)) {
                ForEach(chips) { chip in
                    HeroScoreChipView(chip: chip)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, isTvOS ? 60 : (isIPad ? 80 : 18))
        }
    }

    private func heroRatingChips(for hero: TMDBSearchResult) -> [HeroScoreChip] {
        var chips: [HeroScoreChip] = []

        if let voteAverage = hero.voteAverage, voteAverage > 0 {
            chips.append(HeroScoreChip(
                id: "tmdb",
                label: "TMDB",
                value: String(format: "%.1f", voteAverage),
                systemImage: nil,
                tint: Color(red: 0.19, green: 0.78, blue: 0.76)
            ))
        }

        if let userRating = UserRatingManager.shared.rating(for: hero.id), userRating > 0 {
            chips.append(HeroScoreChip(
                id: "you",
                label: "You",
                value: String(format: "%.1f", userRating),
                systemImage: "checkmark.seal.fill",
                tint: Color(red: 0.90, green: 0.24, blue: 0.78)
            ))
        }

        if let voteCount = hero.voteCount, voteCount > 0, chips.count < 3 {
            chips.append(HeroScoreChip(
                id: "votes",
                label: "Votes",
                value: compactCount(voteCount),
                systemImage: "person.2.fill",
                tint: Color(red: 1.00, green: 0.68, blue: 0.22)
            ))
        }

        return chips
    }

    private func compactCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func genreNames(for hero: TMDBSearchResult) -> [String] {
        guard let genreIds = hero.genreIds else { return [] }
        return genreIds.compactMap { Self.tmdbGenreNames[$0] }
    }

    private static let tmdbGenreNames: [Int: String] = [
        12: "Adventure",
        14: "Fantasy",
        16: "Animation",
        18: "Drama",
        27: "Horror",
        28: "Action",
        35: "Comedy",
        36: "History",
        37: "Western",
        53: "Thriller",
        80: "Crime",
        99: "Documentary",
        878: "Sci-Fi",
        9648: "Mystery",
        10402: "Music",
        10749: "Romance",
        10751: "Family",
        10752: "War",
        10759: "Action Adventure",
        10762: "Kids",
        10763: "News",
        10764: "Reality",
        10765: "Sci-Fi Fantasy",
        10766: "Soap",
        10767: "Talk",
        10768: "War Politics",
        10770: "TV Movie"
    ]

    @ViewBuilder
    private func heroTitleArtwork(_ hero: TMDBSearchResult) -> some View {
        if let logoURL = currentHeroLogoURL(for: hero) {
            KFImage(URL(string: logoURL))
                .setProcessor(DownsamplingImageProcessor(size: heroLogoDecodeSize))
                .placeholder {
                    heroTitleText(hero)
                }
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: heroLogoMaxWidth, maxHeight: heroLogoMaxHeight)
                .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 4)
                .accessibilityLabel(Text(hero.displayTitle))
        } else {
            heroTitleText(hero)
        }
    }

    private func currentHeroLogoURL(for hero: TMDBSearchResult) -> String? {
        guard heroArtworkIdentity == hero.stableIdentity else { return nil }
        return heroLogoURL
    }

    @ViewBuilder
    private func heroTitleText(_ hero: TMDBSearchResult) -> some View {
        Text(hero.displayTitle)
            .font(
                ExperimentalFeatureState.isEnabledAtLaunch
                    ? .system(size: isTvOS ? 76 : (isIPad ? 52 : 40), weight: .heavy)
                    : .system(size: isTvOS ? 40 : 25)
            )
            .fontWeight(.bold)
            .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 4)
            .foregroundColor(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var contentSections: some View {
        LazyVStack(spacing: 0) {
            let catalogs = enabledCatalogs.filter { catalog in
                switch catalog.displayStyle {
                case .standard:
                    if let items = homeViewModel.catalogResults[catalog.id], !items.isEmpty {
                        return true
                    }
                    return false
                case .network:
                    return WidgetNetwork.active.contains { !( homeViewModel.widgetData["network_\($0.id)"] ?? []).isEmpty }
                case .genre:
                    return WidgetGenre.active.contains { !(homeViewModel.widgetData["genre_\($0.id)"] ?? []).isEmpty }
                case .company:
                    return WidgetCompany.active.contains { !(homeViewModel.widgetData["company_\($0.id)"] ?? []).isEmpty }
                case .ranked:
                    if let items = homeViewModel.widgetData[catalog.id], !items.isEmpty { return true }
                    if let items = homeViewModel.catalogResults[catalog.id], !items.isEmpty { return true }
                    return false
                case .featured:
                    return !(homeViewModel.widgetData["featured"] ?? []).isEmpty
                case .continueWatching:
                    return !playbackItems(for: catalog).isEmpty
                }
            }

            ForEach(Array(catalogs.enumerated()), id: \.element.id) { index, catalog in
                let catalogMetrics = metrics(for: catalog)
                switch catalog.displayStyle {
                case .standard:
                    if let items = homeViewModel.catalogResults[catalog.id], !items.isEmpty {
                        let detailItems = catalog.id == "trending"
                            ? items.filter { $0.stableIdentity != homeViewModel.heroContent?.stableIdentity }
                            : items
                        let displayItems = Array(detailItems.prefix(15))

                        let displayTitle: String = {
                            if catalog.id == "becauseYouWatched" && !homeViewModel.becauseYouWatchedTitle.isEmpty {
                                return "Because You Watched \(homeViewModel.becauseYouWatchedTitle)"
                            }
                            return catalog.name
                        }()

                        MediaSection(
                            title: displayTitle,
                            items: displayItems,
                            destination: sectionDetailView(
                                for: catalog,
                                title: displayTitle,
                                initialItems: detailItems
                            ),
                            metrics: catalogMetrics
                        )
                    }

                case .network:
                    NetworkSectionWidget(
                        widgetData: homeViewModel.widgetData,
                        tmdbService: tmdbService,
                        metrics: catalogMetrics
                    )

                case .genre:
                    GenreSectionWidget(
                        widgetData: homeViewModel.widgetData,
                        tmdbService: tmdbService,
                        metrics: catalogMetrics
                    )

                case .company:
                    CompanySectionWidget(
                        widgetData: homeViewModel.widgetData,
                        tmdbService: tmdbService,
                        metrics: catalogMetrics
                    )

                case .ranked:
                    let items = homeViewModel.widgetData[catalog.id]
                        ?? homeViewModel.catalogResults[catalog.id]
                        ?? []
                    RankedListWidget(
                        catalogId: catalog.id,
                        title: catalog.name,
                        items: Array(items.prefix(10)),
                        tmdbService: tmdbService,
                        metrics: catalogMetrics
                    )

                case .featured:
                    FeaturedSpotlightWidget(
                        widgetData: homeViewModel.widgetData,
                        genreName: homeViewModel.featuredGenreName,
                        tmdbService: tmdbService,
                        metrics: catalogMetrics
                    )

                case .continueWatching:
                    let items = playbackItems(for: catalog)
                    if !items.isEmpty {
                        ContinueWatchingSection(
                            title: catalog.name,
                            items: items,
                            tmdbService: tmdbService,
                            onDataChanged: refreshContinueWatchingItems,
                            onSectionBecameEmpty: requestTVHomeFallbackFocus
                        )
                    }
                }

                if index < catalogs.count - 1 && !ExperimentalFeatureState.isEnabledAtLaunch {
                    SectionDivider()
                }
            }

            Spacer(minLength: 50)
        }
        .background(
            Group {
                if ExperimentalFeatureState.isEnabledAtLaunch {
                    Color.clear
                } else if theme.atmosphereStyle == .solid {
                    atmosphereColor
                } else {
                    LinearGradient(
                        colors: [ambientColor, Color.clear, EclipseTheme.shared.backgroundBase],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.3)
                    )
                }
            }
        )
    }

    private func requestTVHomeFallbackFocus() {
#if os(tvOS)
        DispatchQueue.main.async {
            if homeViewModel.heroContent != nil {
                tvHeroFocus = .hero
            }
        }
#endif
    }

#if os(tvOS)
    @ViewBuilder
    private var tvHeroPagingHints: some View {
        if tvHeroFocus == .hero,
           heroBannerBehavior == HeroBannerBehavior.carousel.rawValue,
           homeViewModel.heroCarouselCount > 1 {
            HStack {
                tvHeroPagingChevron("chevron.left")
                Spacer()
                tvHeroPagingChevron("chevron.right")
            }
            .padding(.horizontal, 48)
            .transition(.opacity)
        }
    }

    private func tvHeroPagingChevron(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 38, weight: .bold))
            .foregroundColor(.white.opacity(0.9))
            .frame(width: 88, height: 88)
            .background(Circle().fill(Color.black.opacity(0.35)))
            .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
    }

#endif

    private func loadContent(showLoading: Bool = true) {
        homeViewModel.loadContent(
            tmdbService: tmdbService,
            catalogManager: catalogManager,
            contentFilter: contentFilter,
            showLoading: showLoading
        )
    }

    private func loadHeroArtwork(for hero: TMDBSearchResult?, language: String) async {
        guard let hero else {
            await MainActor.run {
                heroArtworkIdentity = nil
                heroLogoURL = nil
                heroAlternatePosterURL = nil
            }
            return
        }

        let identity = hero.stableIdentity
        await MainActor.run {
            heroArtworkIdentity = identity
            heroLogoURL = nil
            heroAlternatePosterURL = nil
        }

        do {
            let images = hero.isMovie
                ? try await tmdbService.getMovieImages(id: hero.id, preferredLanguage: language)
                : try await tmdbService.getTVShowImages(id: hero.id, preferredLanguage: language)
            guard !Task.isCancelled else { return }
            let logoURL = tmdbService.getBestLogo(from: images, preferredLanguage: language)?.fullURL
            let alternatePosterURL = await tmdbService.bestAlternatePoster(
                from: images,
                excluding: [hero.posterPath],
                matching: hero.posterPath
            )?.fullURL
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard homeViewModel.heroContent?.stableIdentity == identity,
                      selectedLanguage == language else {
                    return
                }
                heroArtworkIdentity = identity
                heroLogoURL = logoURL
                heroAlternatePosterURL = alternatePosterURL
                if let alternatePosterURL {
                    prefetchedHeroAlternatePosterURLs[identity] = alternatePosterURL
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard homeViewModel.heroContent?.stableIdentity == identity,
                      selectedLanguage == language else {
                    return
                }
                heroArtworkIdentity = identity
                heroLogoURL = nil
                heroAlternatePosterURL = nil
            }
        }
    }

    private func prefetchUpcomingHeroImages() async {
        let processor = DownsamplingImageProcessor(size: heroImageDecodeSize)
        let upcomingHeroes = homeViewModel.upcomingHeroCarouselItems(limit: 2)
        for hero in upcomingHeroes {
            guard let imageURL = heroImageURL(for: hero),
                  let url = URL(string: imageURL) else { continue }
            KingfisherManager.shared.retrieveImage(
                with: url,
                options: [
                    .processor(processor),
                    .scaleFactor(UIScreen.main.scale),
                    .backgroundDecode
                ]
            ) { _ in }
        }

#if os(iOS)
        guard ExperimentalFeatureState.isEnabledAtLaunch,
              !isIPad,
              mediaDetailAlternatePosterEnabled else { return }

        for hero in upcomingHeroes {
            guard !Task.isCancelled,
                  prefetchedHeroAlternatePosterURLs[hero.stableIdentity] == nil else { continue }
            do {
                let images = hero.isMovie
                    ? try await tmdbService.getMovieImages(id: hero.id, preferredLanguage: selectedLanguage)
                    : try await tmdbService.getTVShowImages(id: hero.id, preferredLanguage: selectedLanguage)
                guard !Task.isCancelled else { return }
                guard let alternatePosterURL = await tmdbService.bestAlternatePoster(
                    from: images,
                    excluding: [hero.posterPath],
                    matching: hero.posterPath
                )?.fullURL,
                      await prefetchHeroImage(alternatePosterURL, processor: processor),
                      !Task.isCancelled else { continue }
                prefetchedHeroAlternatePosterURLs[hero.stableIdentity] = alternatePosterURL
            } catch {
                continue
            }
        }
#endif
    }

    private func prefetchHeroImage(
        _ imageURL: String,
        processor: DownsamplingImageProcessor
    ) async -> Bool {
        guard let url = URL(string: imageURL) else { return false }
        return await withCheckedContinuation { continuation in
            KingfisherManager.shared.retrieveImage(
                with: url,
                options: [
                    .processor(processor),
                    .scaleFactor(UIScreen.main.scale),
                    .backgroundDecode
                ]
            ) { result in
                continuation.resume(returning: (try? result.get()) != nil)
            }
        }
    }

    private func scheduleHomeCatalogReloadIfNeeded() {
        guard homeViewModel.hasLoadedContent ||
                homeViewModel.hasCompletedInitialLoad else {
            observedHomeCatalogSignature = currentHomeCatalogSignature()
            return
        }

        let newSignature = currentHomeCatalogSignature()
        guard observedHomeCatalogSignature != newSignature else { return }
        observedHomeCatalogSignature = newSignature
        pendingHomeCatalogReloadTask?.cancel()
        pendingHomeCatalogReloadTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            homeViewModel.resetContent(preserveVisibleContent: true, invalidateRecommendations: false)
            loadContent(showLoading: false)
        }
    }

    private func currentHomeCatalogSignature() -> String {
        let enabled = catalogManager.getEnabledCatalogs()
        let catalogPart = enabled
            .map { "\($0.id):\($0.source.rawValue):\($0.displayStyle.rawValue):\($0.order)" }
            .joined(separator: "|")
        let hasAnimeCatalog = enabled.contains { PerformanceModeSettings.isAnimeCatalog($0) }
        let modePart = hasAnimeCatalog
            ? (PerformanceModeSettings.isEnabled ? "animeFast" : "animeFull")
            : "noAnime"
        let overrides = PerformanceModeSettings.fastAnimeCatalogOverrides
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return "\(catalogPart)#\(modePart)#\(overrides)"
    }

    private func sectionDetailView(
        for catalog: Catalog,
        title: String,
        initialItems: [TMDBSearchResult]
    ) -> DiscoverDetailView {
        DiscoverDetailView(
            title: title,
            initialItems: initialItems,
            loadMore: sectionLoadMoreHandler(for: catalog)
        )
    }

    private func sectionLoadMoreHandler(for catalog: Catalog) -> ((Int) async -> [TMDBSearchResult])? {
        switch catalog.id {
        case "trending":
            return { page in
                await loadFilteredSectionPage(catalogId: catalog.id, page: page) {
                    try await tmdbService.getTrending(page: page)
                }
            }
        case "popularMovies":
            return { page in
                await loadFilteredSectionPage(catalogId: catalog.id, page: page) {
                    try await tmdbService.getPopularMovies(page: page).map(\.asSearchResult)
                }
            }
        case "nowPlayingMovies":
            return { page in
                await loadFilteredSectionPage(catalogId: catalog.id, page: page) {
                    try await tmdbService.getNowPlayingMovies(page: page).map(\.asSearchResult)
                }
            }
        case "upcomingMovies":
            return { page in
                await loadFilteredSectionPage(catalogId: catalog.id, page: page) {
                    try await tmdbService.getUpcomingMovies(page: page).map(\.asSearchResult)
                }
            }
        case "upcomingTV":
            return { page in
                await loadFilteredSectionPage(catalogId: catalog.id, page: page) {
                    try await tmdbService.getUpcomingTVShows(page: page).map(\.asSearchResult)
                }
            }
        case "popularTVShows":
            return { page in
                await loadFilteredSectionPage(catalogId: catalog.id, page: page) {
                    try await tmdbService.getPopularTVShows(page: page).map(\.asSearchResult)
                }
            }
        case "onTheAirTV":
            return { page in
                await loadFilteredSectionPage(catalogId: catalog.id, page: page) {
                    try await tmdbService.getOnTheAirTVShows(page: page).map(\.asSearchResult)
                }
            }
        case "airingTodayTV":
            return { page in
                await loadFilteredSectionPage(catalogId: catalog.id, page: page) {
                    try await tmdbService.getAiringTodayTVShows(page: page).map(\.asSearchResult)
                }
            }
        case "topRatedTVShows":
            return { page in
                await loadFilteredSectionPage(catalogId: catalog.id, page: page) {
                    try await tmdbService.getTopRatedTVShows(page: page).map(\.asSearchResult)
                }
            }
        case "topRatedMovies":
            return { page in
                await loadFilteredSectionPage(catalogId: catalog.id, page: page) {
                    try await tmdbService.getTopRatedMovies(page: page).map(\.asSearchResult)
                }
            }
        case "trendingAnime":
            return animeSectionLoadMoreHandler(for: .trending, catalogId: catalog.id)
        case "popularAnime":
            return animeSectionLoadMoreHandler(for: .popular, catalogId: catalog.id)
        case "topRatedAnime":
            return animeSectionLoadMoreHandler(for: .topRated, catalogId: catalog.id)
        case "airingAnime":
            return animeSectionLoadMoreHandler(for: .airing, catalogId: catalog.id)
        case "upcomingAnime":
            return animeSectionLoadMoreHandler(for: .upcoming, catalogId: catalog.id)
        default:
            return expandingSourceLoadMoreHandler(for: catalog)
        }
    }

    private func loadFilteredSectionPage(
        catalogId: String,
        page: Int,
        fetch: () async throws -> [TMDBSearchResult]
    ) async -> [TMDBSearchResult] {
        do {
            return await contentFilter.filterSearchResultsResolvingRatings(try await fetch())
        } catch {
            Logger.shared.log("HomeView: section \(catalogId) page \(page) failed: \(error.localizedDescription)", type: "TMDB")
            return []
        }
    }

    private func animeSectionLoadMoreHandler(
        for kind: AniListService.AniListCatalogKind,
        catalogId: String
    ) -> ((Int) async -> [TMDBSearchResult]) {
        { page in
            await loadAnimeSectionPage(kind: kind, catalogId: catalogId, page: page)
        }
    }

    private func loadAnimeSectionPage(
        kind: AniListService.AniListCatalogKind,
        catalogId: String,
        page: Int
    ) async -> [TMDBSearchResult] {
        let pageSize = 20
        let boundedPage = max(page, 1)

        do {
            if catalogManager.performanceModeEnabled, let fastKind = fastAnimeCatalogKind(for: kind) {
                let limit = boundedPage * pageSize
                let offset = (boundedPage - 1) * pageSize
                let results = await contentFilter.filterFastAnimeSearchResultsResolvingRatings(
                    try await tmdbService.getFastAnimeCatalog(kind: fastKind, limit: limit)
                )
                return Array(results.dropFirst(offset))
            }

            return await contentFilter.filterSearchResultsResolvingRatings(
                try await AniListService.shared.fetchAnimeCatalog(
                    kind,
                    page: boundedPage,
                    limit: pageSize,
                    tmdbService: tmdbService
                )
            )
        } catch {
            Logger.shared.log("HomeView: anime section \(catalogId) page \(page) failed: \(error.localizedDescription)", type: "AniList")
            return []
        }
    }

    private func fastAnimeCatalogKind(for kind: AniListService.AniListCatalogKind) -> TMDBService.FastAnimeCatalogKind? {
        switch kind {
        case .trending:
            return .trending
        case .popular:
            return .popular
        case .topRated:
            return .topRated
        case .airing:
            return .airing
        case .upcoming:
            return .upcoming
        }
    }

    private func expandingSourceLoadMoreHandler(for catalog: Catalog) -> ((Int) async -> [TMDBSearchResult])? {
        switch catalog.source {
        case .stremio:
            return { page in
                let pageSize = 15
                let limit = max(page, 1) * pageSize
                let offset = max(page - 1, 0) * pageSize
                let items = await StremioAddonManager.shared.fetchCatalogItems(
                    for: catalog,
                    tmdbService: tmdbService,
                    limit: limit
                )
                return await Array(contentFilter.filterSearchResultsResolvingRatings(items).dropFirst(offset))
            }
        case .trakt:
            return { page in
                let pageSize = 15
                let limit = max(page, 1) * pageSize
                let offset = max(page - 1, 0) * pageSize
                let items = await trackerManager.fetchTraktPublicListCatalogItems(
                    for: catalog,
                    tmdbService: tmdbService,
                    limit: limit
                )
                return await Array(contentFilter.filterSearchResultsResolvingRatings(items).dropFirst(offset))
            }
        case .tmdb, .anilist, .local:
            return nil
        }
    }

    private func reloadHomeContentForProfileChange() {

        homeViewModel.resetContent(preserveVisibleContent: false, invalidateRecommendations: false)
        homeViewModel.loadContent(
            tmdbService: tmdbService,
            catalogManager: catalogManager,
            contentFilter: contentFilter,
            showLoading: true
        )
    }

    private func reloadHomeContentAfterFilterChange() {
        guard homeViewModel.hasLoadedContent else { return }

        homeViewModel.resetContent(preserveVisibleContent: true, invalidateRecommendations: false)
        homeViewModel.loadContent(
            tmdbService: tmdbService,
            catalogManager: catalogManager,
            contentFilter: contentFilter,
            showLoading: false
        )
    }

    private func refreshContinueWatchingItems() {
        refreshLocalContinueWatchingItems()
        refreshRemotePlaybackCatalogItems()
    }

    private func refreshLocalContinueWatchingItems() {
        let items = ProgressManager.shared.getContinueWatchingItems()

        continueWatchingProfileFilterTask?.cancel()
        continueWatchingProfileFilterTask = nil
        guard ProfileManager.shared.isKidsModeActive else {
            continueWatchingVettedOwner = nil
            continueWatchingItems = items
            return
        }

        let owner = ProfileManager.shared.activeProfileID

        if continueWatchingVettedOwner == owner {
            let vetted = Set(continueWatchingItems.map(\.id))
            continueWatchingItems = items.filter { vetted.contains($0.id) }
        } else {
            continueWatchingVettedOwner = nil
            continueWatchingItems = []
        }
        continueWatchingProfileFilterTask = Task { @MainActor in
            let allowed = await TMDBContentFilter.shared
                .filterContinueWatchingResolvingRatings(items)

            guard !Task.isCancelled, ProfileManager.shared.isStillActive(owner) else { return }
            continueWatchingItems = allowed
            continueWatchingVettedOwner = owner
        }
    }

    private func scheduleContinueWatchingProgressRefresh() {
        pendingContinueWatchingProgressRefreshTask?.cancel()
        pendingContinueWatchingProgressRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            refreshLocalContinueWatchingItems()
        }
    }

    private func refreshRemotePlaybackCatalogItems() {
        let enabledIds = Set(enabledCatalogs.map(\.id))
        let shouldLoadUpNext = enabledIds.contains(Catalog.upNextCatalogId)
        let shouldLoadTraktContinueWatching = enabledIds.contains(Catalog.traktContinueWatchingCatalogId)

        if shouldLoadUpNext {
            refreshUpNextItemsIfNeeded()
        } else {
            cancelUpNextResolution()
            upNextItems = []
        }

        if shouldLoadTraktContinueWatching {

            cancelTraktContinueWatchingRefresh(clearItems: false)
            let refreshID = UUID()
            continueWatchingRefreshID = refreshID
            let isKids = ProfileManager.shared.isKidsModeActive
            let owner = ProfileManager.shared.activeProfileID
            traktContinueWatchingRefreshTask = Task { @MainActor in
                let items = await trackerManager.fetchTraktContinueWatchingItems(
                    requiredOwner: owner
                )
                guard !Task.isCancelled,
                      continueWatchingRefreshID == refreshID,
                      ProfileManager.shared.isStillActive(owner) else { return }
                guard isKids else {
                    traktContinueWatchingItems = items
                    traktContinueWatchingRefreshTask = nil
                    return
                }

                let allowed = await TMDBContentFilter.shared
                    .filterContinueWatchingResolvingRatings(items)
                guard !Task.isCancelled,
                      continueWatchingRefreshID == refreshID,
                      ProfileManager.shared.isStillActive(owner) else { return }
                traktContinueWatchingItems = allowed
                traktContinueWatchingRefreshTask = nil
            }
        } else {
            cancelTraktContinueWatchingRefresh(clearItems: true)
        }
    }

    private func cancelTraktContinueWatchingRefresh(clearItems: Bool) {

        continueWatchingRefreshID = UUID()
        traktContinueWatchingRefreshTask?.cancel()
        traktContinueWatchingRefreshTask = nil
        if clearItems {
            traktContinueWatchingItems = []
        }
    }

    private func cancelUpNextResolution() {
        upNextResolveTask?.cancel()
        upNextResolveTask = nil
        upNextInFlightSignature = ""
        upNextResolvedSignature = ""
        upNextResolvedOwner = nil
    }

    private func watchNextCandidateSignature(_ candidates: [WatchNextCandidate]) -> String {
        let owner = ProfileManager.shared.activeProfileID.uuidString
        let isKids = ProfileManager.shared.isKidsModeActive
        let coordinates = candidates
            .map { "\($0.tmdbId):\($0.seasonNumber):\($0.episodeNumber)" }
            .joined(separator: "|")
        return "\(owner)#\(isKids)#\(coordinates)"
    }

    private func refreshUpNextItemsIfNeeded() {
        let candidates = ProgressManager.shared.getWatchNextCandidates(limit: 20)

        let owner = ProfileManager.shared.activeProfileID
        let isKidsMode = ProfileManager.shared.isKidsModeActive
        let signature = watchNextCandidateSignature(candidates)

        guard !candidates.isEmpty else {
            cancelUpNextResolution()
            upNextItems = []
            return
        }

        if signature == upNextResolvedSignature, !upNextItems.isEmpty { return }

        if signature == upNextInFlightSignature, upNextResolveTask != nil { return }

        if upNextResolvedOwner != owner || upNextResolvedKidsMode != isKidsMode, !upNextItems.isEmpty {
            upNextItems = []
            upNextResolvedSignature = ""
            upNextResolvedOwner = nil
        }

        let cached = cachedWatchNextItems(candidates, owner: owner)
        if cached.isComplete {
            upNextResolveTask?.cancel()
            upNextInFlightSignature = signature

            upNextResolveTask = Task { @MainActor in
                let allowed = await TMDBContentFilter.shared
                    .filterContinueWatchingResolvingRatings(cached.items)
                guard !Task.isCancelled, ProfileManager.shared.isStillActive(owner) else { return }
                upNextItems = allowed
                upNextResolvedSignature = signature
                upNextResolvedOwner = owner
                upNextResolvedKidsMode = isKidsMode
                upNextInFlightSignature = ""
                upNextResolveTask = nil
            }
            return
        }

        upNextResolveTask?.cancel()
        upNextInFlightSignature = signature
        upNextResolveTask = Task { @MainActor in
            let items = await resolveWatchNextItems(candidates, owner: owner)
            guard !Task.isCancelled else { return }
            let allowed = await TMDBContentFilter.shared
                .filterContinueWatchingResolvingRatings(items)
            guard !Task.isCancelled, ProfileManager.shared.isStillActive(owner) else { return }
            upNextItems = allowed
            upNextResolvedSignature = signature
            upNextResolvedOwner = owner
            upNextResolvedKidsMode = isKidsMode
            upNextInFlightSignature = ""
            upNextResolveTask = nil
        }
    }

    private func playbackItems(for catalog: Catalog) -> [ContinueWatchingItem] {
        switch catalog.id {
        case Catalog.upNextCatalogId:
            return upNextItems
        case Catalog.traktContinueWatchingCatalogId:
            return traktContinueWatchingItems
        default:
            return []
        }
    }

    private func resolveWatchNextItems(_ candidates: [WatchNextCandidate], owner: UUID) async -> [ContinueWatchingItem] {
        guard !candidates.isEmpty else { return [] }

        let maxConcurrent = 4
        var resolved: [Int: ContinueWatchingItem] = [:]

        await withTaskGroup(of: (Int, ContinueWatchingItem?).self) { group in
            var nextIndex = 0
            for _ in 0..<min(maxConcurrent, candidates.count) {
                let index = nextIndex
                group.addTask { (index, await resolveWatchNextItem(candidates[index], owner: owner)) }
                nextIndex += 1
            }

            while let (index, item) = await group.next() {
                if let item {
                    resolved[index] = item
                }

                if !Task.isCancelled, nextIndex < candidates.count, resolved.count < 10 {
                    let index = nextIndex
                    group.addTask { (index, await resolveWatchNextItem(candidates[index], owner: owner)) }
                    nextIndex += 1
                }
            }
        }

        return Array(candidates.indices.compactMap { resolved[$0] }.prefix(10))
    }

    private func watchNextCacheKey(_ candidate: WatchNextCandidate) -> String {
        UpNextResolutionCache.key(
            showId: candidate.tmdbId,
            seasonNumber: candidate.seasonNumber,
            episodeNumber: candidate.episodeNumber
        )
    }

    private func cachedWatchNextItems(_ candidates: [WatchNextCandidate], owner: UUID) -> (items: [ContinueWatchingItem], isComplete: Bool) {
        var items: [ContinueWatchingItem] = []
        var isComplete = true

        for candidate in candidates {
            if items.count >= 10 { break }
            guard let resolution = UpNextResolutionCache.shared.resolution(
                forKey: watchNextCacheKey(candidate),
                profile: owner
            ) else {
                isComplete = false
                continue
            }
            guard let seasonNumber = resolution.seasonNumber,
                  let episodeNumber = resolution.episodeNumber else {

                continue
            }
            guard isWatchNextTargetAvailable(
                showId: candidate.tmdbId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber
            ) else {
                isComplete = false
                continue
            }
            items.append(
                makeWatchNextItem(
                    candidate: candidate,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber,
                    playbackContext: resolution.playbackContext
                )
            )
        }

        return (items, isComplete)
    }

    private func storeWatchNextResolution(
        for candidate: WatchNextCandidate,
        seasonNumber: Int?,
        episodeNumber: Int?,
        playbackContext: EpisodePlaybackContext?,
        owner: UUID
    ) {
        guard ProfileManager.shared.isStillActive(owner) else { return }
        UpNextResolutionCache.shared.store(
            UpNextResolutionCache.Resolution(
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                playbackContext: playbackContext,
                resolvedAt: Date()
            ),
            forKey: watchNextCacheKey(candidate),
            profile: owner
        )
    }

    private func resolveWatchNextItem(_ candidate: WatchNextCandidate, owner: UUID) async -> ContinueWatchingItem? {
        let cacheKey = watchNextCacheKey(candidate)
        if let resolution = UpNextResolutionCache.shared.resolution(forKey: cacheKey, profile: owner) {
            guard let seasonNumber = resolution.seasonNumber,
                  let episodeNumber = resolution.episodeNumber else {
                return nil
            }
            if isWatchNextTargetAvailable(
                showId: candidate.tmdbId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber
            ) {
                return makeWatchNextItem(
                    candidate: candidate,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber,
                    playbackContext: resolution.playbackContext
                )
            }

        }

        if candidate.isAnime || candidate.playbackContext?.hasAnimeMediaId == true {
            guard candidate.playbackContext?.isSpecial != true else { return nil }
            let seed = NextEpisodeSeed(
                showID: candidate.tmdbId,
                currentSeasonNumber: candidate.seasonNumber,
                currentEpisodeNumber: candidate.episodeNumber,
                showTitle: candidate.title,
                showPosterURL: candidate.posterURL,
                isAnime: true,
                isAnimation: true,
                playbackContext: candidate.playbackContext
            )
            let resolution = await NextEpisodeResolver().resolve(seed: seed)
            guard case .available(let target) = resolution else {

                if case .noAvailableEpisode = resolution {
                    storeWatchNextResolution(
                        for: candidate,
                        seasonNumber: nil,
                        episodeNumber: nil,
                        playbackContext: nil,
                        owner: owner
                    )
                }
                return nil
            }
            guard isWatchNextTargetAvailable(
                showId: candidate.tmdbId,
                seasonNumber: target.episode.seasonNumber,
                episodeNumber: target.episode.episodeNumber
            ) else {
                return nil
            }
            storeWatchNextResolution(
                for: candidate,
                seasonNumber: target.episode.seasonNumber,
                episodeNumber: target.episode.episodeNumber,
                playbackContext: target.playbackContext,
                owner: owner
            )
            return makeWatchNextItem(
                candidate: candidate,
                seasonNumber: target.episode.seasonNumber,
                episodeNumber: target.episode.episodeNumber,
                playbackContext: target.playbackContext
            )
        }

        do {
            let season = try await tmdbService.getSeasonDetails(
                tvShowId: candidate.tmdbId,
                seasonNumber: candidate.seasonNumber
            )
            if let nextEpisode = season.episodes
                .filter({
                    $0.episodeNumber > candidate.episodeNumber &&
                    episodeHasAired($0) &&
                    isWatchNextTargetAvailable(
                        showId: candidate.tmdbId,
                        seasonNumber: $0.seasonNumber,
                        episodeNumber: $0.episodeNumber
                    )
                })
                .min(by: { $0.episodeNumber < $1.episodeNumber }) {
                let playbackContext = candidate.playbackContext?.forEpisodeNumber(nextEpisode.episodeNumber)
                storeWatchNextResolution(
                    for: candidate,
                    seasonNumber: nextEpisode.seasonNumber,
                    episodeNumber: nextEpisode.episodeNumber,
                    playbackContext: playbackContext,
                    owner: owner
                )
                return makeWatchNextItem(
                    candidate: candidate,
                    seasonNumber: nextEpisode.seasonNumber,
                    episodeNumber: nextEpisode.episodeNumber,
                    playbackContext: playbackContext
                )
            }

            let show = try await tmdbService.getTVShowWithSeasons(id: candidate.tmdbId)
            for nextSeason in show.seasons
                .filter({ $0.seasonNumber > candidate.seasonNumber && $0.seasonNumber > 0 && $0.episodeCount > 0 })
                .sorted(by: { $0.seasonNumber < $1.seasonNumber }) {
                let season = try await tmdbService.getSeasonDetails(
                    tvShowId: candidate.tmdbId,
                    seasonNumber: nextSeason.seasonNumber
                )
                if let firstEpisode = season.episodes
                    .filter({
                        episodeHasAired($0) &&
                        isWatchNextTargetAvailable(
                            showId: candidate.tmdbId,
                            seasonNumber: $0.seasonNumber,
                            episodeNumber: $0.episodeNumber
                        )
                    })
                    .min(by: { $0.episodeNumber < $1.episodeNumber }) {
                    storeWatchNextResolution(
                        for: candidate,
                        seasonNumber: firstEpisode.seasonNumber,
                        episodeNumber: firstEpisode.episodeNumber,
                        playbackContext: nil,
                        owner: owner
                    )
                    return makeWatchNextItem(
                        candidate: candidate,
                        seasonNumber: firstEpisode.seasonNumber,
                        episodeNumber: firstEpisode.episodeNumber,
                        playbackContext: nil
                    )
                }
            }

            storeWatchNextResolution(
                for: candidate,
                seasonNumber: nil,
                episodeNumber: nil,
                playbackContext: nil,
                owner: owner
            )
        } catch {

            Logger.shared.log("HomeView: Watch Next lookup failed for TMDB \(candidate.tmdbId): \(error.localizedDescription)", type: "TMDB")
        }

        return nil
    }

    private func isWatchNextTargetAvailable(showId: Int, seasonNumber: Int, episodeNumber: Int) -> Bool {
        seasonNumber > 0 &&
        episodeNumber > 0 &&
        !ProgressManager.shared.hasStartedOrCompletedEpisode(
            showId: showId,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        )
    }

    private func makeWatchNextItem(
        candidate: WatchNextCandidate,
        seasonNumber: Int,
        episodeNumber: Int,
        playbackContext: EpisodePlaybackContext?
    ) -> ContinueWatchingItem {
        ContinueWatchingItem(
            id: "watch_next_\(candidate.tmdbId)_s\(seasonNumber)_e\(episodeNumber)",
            tmdbId: candidate.tmdbId,
            isMovie: false,
            title: candidate.title,
            posterURL: candidate.posterURL,
            progress: 0,
            lastUpdated: candidate.lastUpdated,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            currentTime: 0,
            totalDuration: 1,
            playbackContext: playbackContext,
            isAnime: candidate.isAnime,
            statusText: "Watch next",
            isWatchNext: true,
            traktPlaybackId: nil,
            removalTarget: .localUpNextShow
        )
    }

    private func episodeHasAired(_ episode: TMDBEpisode) -> Bool {
        guard let airDate = episode.airDate,
              let parsedDate = Self.tmdbDateFormatter.date(from: airDate) else {
            return true
        }
        return parsedDate <= Date()
    }

    private static let tmdbDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func reportStartupReadyIfNeeded() {
        guard !didReportStartupReady else { return }
        didReportStartupReady = true
        onStartupReady()
    }

    private func reportInitialHydrationIfNeeded() {
        guard !didReportInitialHydration else { return }
        didReportInitialHydration = true
        NotificationCenter.default.post(name: .homeInitialHydrationDidComplete, object: nil)
    }

}

private struct HeroScoreChip: Identifiable {
    let id: String
    let label: String
    let value: String
    let systemImage: String?
    let tint: Color
}

private struct HeroScoreChipView: View {
    let chip: HeroScoreChip

    var body: some View {
        HStack(alignment: .center, spacing: isTvOS ? 9 : 5) {
            HStack(spacing: isTvOS ? 5 : 3) {
                if let systemImage = chip.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: isTvOS ? 17 : 10, weight: .bold))
                }
                Text(chip.label)
                    .font(.system(size: isTvOS ? 16 : 9, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(.black.opacity(0.86))
            .padding(.horizontal, isTvOS ? 9 : 5)
            .padding(.vertical, isTvOS ? 5 : 3)
            .background(
                RoundedRectangle(cornerRadius: isTvOS ? 5 : 3, style: .continuous)
                    .fill(chip.tint)
            )

            Text(chip.value)
                .font(.system(size: isTvOS ? 30 : (isIPad ? 21 : 18), weight: .semibold))
                .foregroundColor(.white.opacity(0.96))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 3)
        .accessibilityElement(children: .combine)
    }
}

struct MediaSection: View {
    let title: String
    let items: [TMDBSearchResult]
    var destination: DiscoverDetailView?
    var metrics: ExperimentalMediaDesignMetrics = .current

    var gap: Double { isTvOS ? 50.0 : (isIPad ? 28.0 : 20.0) }

    var body: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch && !isTvOS {
            ExperimentalMediaShelf(
                title: title,
                items: items,
                destination: destination,
                preferredStyle: title.localizedCaseInsensitiveContains("anime") ? .poster : .automatic,
                metrics: metrics
            )
        } else {
            legacySection
        }
    }

    private var legacySection: some View {
        VStack(alignment: .leading, spacing: ExperimentalFeatureState.isEnabledAtLaunch ? 18 : 16) {
            HStack {
                Text(title)
                    .font(sectionTitleFont)
                    .foregroundColor(.white)
                Spacer()

#if !os(tvOS)
                if let destination = destination {
                    NavigationLink(destination: destination) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: isTvOS ? 26 : 20, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                            .frame(width: isTvOS ? 54 : 44, height: isTvOS ? 54 : 44, alignment: .trailing)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("See all \(title)")
                }
#endif
            }
            .padding(.horizontal, isTvOS ? 60 : 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: gap) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        MediaCard(
                            result: item,
                            heroID: "home-\(title)-\(index)-\(item.stableIdentity)",
                            metrics: metrics
                        )
                    }
#if os(tvOS)
                    if let destination = destination {
                        TVSeeAllCard(title: title, destination: destination, metrics: metrics)
                    }
#endif
                }
                .padding(.horizontal, isTvOS ? 60 : 16)
            }
            .modifier(ScrollClipModifier())
            .buttonStyle(.borderless)
        }
        .padding(.top, isTvOS ? 40 : 24)
        .opacity(items.isEmpty ? 0 : 1)
    }

    private var sectionTitleFont: Font {
        if isTvOS {
            return .headline
        }
        return ExperimentalFeatureState.isEnabledAtLaunch
            ? .system(size: isIPad ? 30 : 28, weight: .bold)
            : .title2.weight(.bold)
    }
}

#if os(tvOS)
struct TVSeeAllCard: View {
    let title: String
    let destination: DiscoverDetailView
    var metrics: ExperimentalMediaDesignMetrics = .current

    private var cardWidth: CGFloat { 200 * metrics.mediaCardScale }
    private var cardHeight: CGFloat { 380 * metrics.mediaCardScale }

    var body: some View {
        NavigationLink(destination: destination) {
            VStack(spacing: 20) {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                Text("See All")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.card)
        .padding(.vertical, 30)
        .accessibilityLabel("See all \(title)")
    }
}
#endif

enum ExperimentalMediaShelfStyle {
    case automatic
    case landscape
    case poster
}

struct ExperimentalMediaShelf: View {
    let title: String
    let items: [TMDBSearchResult]
    var destination: DiscoverDetailView?
    let preferredStyle: ExperimentalMediaShelfStyle
    let metrics: ExperimentalMediaDesignMetrics

    private var gap: CGFloat { isIPad ? 22 : 20 }
    private var resolvedStyle: ExperimentalMediaShelfStyle {
        switch metrics.cardShape {
        case .landscape:
            return .landscape
        case .poster:
            return .poster
        case .automatic:
            if preferredStyle == .poster || automaticShelfPrefersPoster {
                return .poster
            }
            return shelfHasCompleteBackdropArtwork ? .landscape : .poster
        }
    }

    private var shelfHasCompleteBackdropArtwork: Bool {
        !items.isEmpty && items.allSatisfy { $0.fullBackdropURL != nil }
    }

    private var automaticShelfPrefersPoster: Bool {
        !items.isEmpty && items.allSatisfy(Self.prefersPosterArtworkInAutomatic)
    }

    private static func prefersPosterArtworkInAutomatic(_ result: TMDBSearchResult) -> Bool {
        guard result.genreIds?.contains(16) == true else {
            return false
        }

        let animeOriginCountries: Set<String> = ["JP", "CN", "KR", "TW"]
        if result.originCountry?.contains(where: { animeOriginCountries.contains($0) }) == true {
            return true
        }

        guard let originalLanguage = result.originalLanguage?.lowercased() else {
            return false
        }
        return ["ja", "zh", "ko"].contains(originalLanguage)
    }

    var body: some View {
        let shelfStyle = resolvedStyle

        VStack(alignment: .leading, spacing: isIPad ? 18 : 16) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: isIPad ? 34 : 29, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if let destination = destination {
                    NavigationLink(destination: destination) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: isIPad ? 26 : 22, weight: .semibold))
                            .foregroundColor(.white.opacity(0.46))
                            .frame(width: isIPad ? 52 : 44, height: isIPad ? 52 : 44, alignment: .trailing)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("See all \(title)")
                }
            }
            .padding(.horizontal, isIPad ? 24 : 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: gap) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        ExperimentalMediaCard(
                            result: item,
                            heroID: "experimental-home-\(title)-\(index)-\(item.stableIdentity)",
                            preferredStyle: shelfStyle,
                            metrics: metrics
                        )
                    }
                }
                .padding(.horizontal, isIPad ? 24 : 16)
            }
            .modifier(ScrollClipModifier())
            .buttonStyle(.borderless)
        }
        .padding(.top, metrics.sectionSpacing)
        .opacity(items.isEmpty ? 0 : 1)
    }
}

struct ExperimentalMediaCard: View {
    let result: TMDBSearchResult
    let heroID: String
    let preferredStyle: ExperimentalMediaShelfStyle
    let metrics: ExperimentalMediaDesignMetrics

    @Environment(\.heroNamespace) private var heroNamespace

    private var resolvedStyle: ExperimentalMediaShelfStyle {
        switch preferredStyle {
        case .landscape:
            return .landscape
        case .poster:
            return .poster
        case .automatic:
            return .landscape
        }
    }

    private var cardSize: CGSize {
        switch resolvedStyle {
        case .landscape, .automatic:
            return metrics.landscapeCardSize(isIPad: isIPad)
        case .poster:
            return metrics.posterCardSize(isIPad: isIPad)
        }
    }

    private var imageAspectRatio: CGFloat {
        switch resolvedStyle {
        case .landscape, .automatic:
            return 16 / 9
        case .poster:
            return 2 / 3
        }
    }

    private var imageURL: String {
        switch resolvedStyle {
        case .landscape, .automatic:
            return result.fullBackdropURL ?? result.fullPosterURL ?? ""
        case .poster:
            return result.fullPosterURL ?? result.fullBackdropURL ?? ""
        }
    }

    var body: some View {
        NavigationLink(destination: MediaDetailView(searchResult: result)
            .heroDestination(id: heroID, namespace: heroNamespace)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                mediaImage

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.displayTitle)
                        .font(.system(size: resolvedStyle == .poster ? (isIPad ? 19 : 17) : (isIPad ? 21 : 20), weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    HomeCardSubtitle(result: result)
                        .font(.system(size: isIPad ? 16 : 15, weight: .regular))
                        .foregroundColor(.white.opacity(0.56))
                        .lineLimit(1)
                }
                .frame(width: cardSize.width, alignment: .leading)
            }
            .frame(width: cardSize.width, alignment: .leading)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var mediaImage: some View {
        KFImage(URL(string: imageURL))
            .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: cardSize.width, height: cardSize.height)))
            .placeholder {
                FallbackImageView(
                    isMovie: result.isMovie,
                    size: cardSize
                )
            }
            .resizable()
            .aspectRatio(imageAspectRatio, contentMode: .fill)
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
            .heroSource(id: heroID, namespace: heroNamespace)
    }
}

struct ScrollClipModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollClipDisabled()
        } else {
            content
        }
    }
}

struct SectionDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            line
            Image(systemName: "sparkle")
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.2))
            line
        }
        .padding(.horizontal, 60)
        .padding(.top, 28)
        .padding(.bottom, 4)
    }

    private var line: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.12), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 0.5)
    }
}

struct MediaCard: View {
    let result: TMDBSearchResult
    let heroID: String
    var metrics: ExperimentalMediaDesignMetrics = .current
    @State private var isHovering: Bool = false
    @Environment(\.heroNamespace) private var heroNamespace

    private var posterWidth: CGFloat { isTvOS ? 280 * metrics.mediaCardScale : 120 * iPadScale }
    private var posterHeight: CGFloat { isTvOS ? 380 * metrics.mediaCardScale : 180 * iPadScale }
    private var posterShadowRadius: CGFloat { isIPad ? 4 : 8 }
    private var usesBackdropCard: Bool {
        ExperimentalFeatureState.isEnabledAtLaunch && !isTvOS && result.fullBackdropURL != nil
    }
    private var backdropWidth: CGFloat { isIPad ? 300 : 220 }
    private var backdropHeight: CGFloat { isIPad ? 170 : 124 }

    var body: some View {
        NavigationLink(destination: MediaDetailView(searchResult: result)
            .heroDestination(id: heroID, namespace: heroNamespace)
        ) {
            if usesBackdropCard {
                backdropCard
            } else {
                posterCard
            }
        }
#if os(tvOS)
        .buttonStyle(.card)
#else
        .buttonStyle(PlainButtonStyle())
#endif
    }

    private var posterCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            KFImage(URL(string: result.fullPosterURL ?? ""))
                .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: posterWidth, height: posterHeight)))
                .placeholder {
                    FallbackImageView(
                        isMovie: result.isMovie,
                        size: CGSize(width: posterWidth, height: posterHeight)
                    )
                }
                .resizable()
                .aspectRatio(2/3, contentMode: .fill)
                .tvos({ view in
                    view
                        .frame(width: posterWidth, height: posterHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .hoverEffect(.highlight)
                        .modifier(ContinuousHoverModifier(isHovering: $isHovering))
                        .padding(.vertical, 30)
                }, else: { view in
                    view
                        .frame(width: posterWidth, height: posterHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.25), radius: posterShadowRadius, x: 0, y: 4)
                })
                .heroSource(id: heroID, namespace: heroNamespace)

            VStack(alignment: .leading, spacing: isTvOS ? 10 : 3) {
                Text(result.displayTitle)
                    .tvos({ view in
                        view
                            .foregroundColor(isHovering ? .white : .white.opacity(0.78))
                            .font(.system(size: 27, weight: .semibold))
                    }, else: { view in
                        view
                            .foregroundColor(.white)
                            .fontWeight(.medium)
                            .font(.caption)
                    })
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(alignment: .center, spacing: isTvOS ? 18 : 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)

                        Text(String(format: "%.1f", result.voteAverage ?? 0.0))
                            .font(.caption2)
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, isTvOS ? 16 : 8)
                    .padding(.vertical, isTvOS ? 10 : 4)
                    .applyLiquidGlassBackground(cornerRadius: 12)

                    Spacer()

                    Text(result.isMovie ? "Movie" : "TV")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, isTvOS ? 16 : 8)
                        .padding(.vertical, isTvOS ? 10 : 4)
                        .applyLiquidGlassBackground(cornerRadius: 12)
                }
            }
            .frame(width: posterWidth, alignment: .leading)
        }
    }

    private var backdropCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            KFImage(URL(string: result.fullBackdropURL ?? result.fullPosterURL ?? ""))
                .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: backdropWidth, height: backdropHeight)))
                .placeholder {
                    FallbackImageView(
                        isMovie: result.isMovie,
                        size: CGSize(width: backdropWidth, height: backdropHeight)
                    )
                }
                .resizable()
                .aspectRatio(16/9, contentMode: .fill)
                .frame(width: backdropWidth, height: backdropHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 5)
                .heroSource(id: heroID, namespace: heroNamespace)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayTitle)
                    .font(.system(size: isIPad ? 19 : 18, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(width: backdropWidth, alignment: .leading)

                HomeCardSubtitle(result: result)
                    .font(.system(size: isIPad ? 15 : 14, weight: .regular))
                    .foregroundColor(.white.opacity(0.58))
                    .lineLimit(1)
                    .frame(width: backdropWidth, alignment: .leading)
            }
        }
        .frame(width: backdropWidth, alignment: .leading)
    }
}

struct ContinueWatchingSection: View {
    var title: String = "Continue Watching"
    let items: [ContinueWatchingItem]
    let tmdbService: TMDBService
    let onDataChanged: () -> Void
    var onSectionBecameEmpty: () -> Void = {}

    @State private var requestedTVFocusItemID: String?

    private var gap: Double { isTvOS ? 50.0 : (isIPad ? 24.0 : 16.0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(isTvOS ? .headline : .title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Spacer()
            }
            .padding(.horizontal, isTvOS ? 60 : 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: gap) {
                    ForEach(items) { item in
                        ContinueWatchingCard(
                            item: item,
                            tmdbService: tmdbService,
                            onDataChanged: onDataChanged,
                            requestedTVFocusItemID: $requestedTVFocusItemID,
                            onItemDisappeared: {
                                requestFocusAfterRemoving(itemID: item.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, isTvOS ? 60 : 16)
            }
            .modifier(ScrollClipModifier())
            .buttonStyle(.borderless)
        }
        .padding(.top, isTvOS ? 40 : 24)
    }

    private func requestFocusAfterRemoving(itemID: String) {
        guard let removedIndex = items.firstIndex(where: { $0.id == itemID }) else { return }
        let survivingItems = items.filter { $0.id != itemID }
        guard !survivingItems.isEmpty else {
            onSectionBecameEmpty()
            return
        }

        let nearestIndex = min(removedIndex, survivingItems.count - 1)
        let nearestItemID = survivingItems[nearestIndex].id
        DispatchQueue.main.async {
            requestedTVFocusItemID = nearestItemID
        }
    }
}

enum ContinueWatchingAnimePlaybackContextPolicy {
    static func resolve(
        existingContext: EpisodePlaybackContext?,
        localSeasonNumber: Int,
        localEpisodeNumber: Int,
        localCoordinatesAreKnownTMDB: Bool
    ) -> EpisodePlaybackContext? {
        guard localSeasonNumber >= 0, localEpisodeNumber > 0 else { return nil }

        if let existingContext {
            if existingContext.localSeasonNumber == localSeasonNumber,
               existingContext.localEpisodeNumber == localEpisodeNumber,
               hasExactTMDBCoordinates(existingContext) {

                return existingContext
            }

            guard !existingContext.isSpecial,
                  existingContext.localSeasonNumber == localSeasonNumber else {
                return nil
            }
            let projected = existingContext.forEpisodeNumber(localEpisodeNumber)
            guard projected.localSeasonNumber == localSeasonNumber,
                  projected.localEpisodeNumber == localEpisodeNumber,
                  hasExactTMDBCoordinates(projected) else {
                return nil
            }
            return projected
        }

        guard localCoordinatesAreKnownTMDB else { return nil }
        return EpisodePlaybackContext(
            localSeasonNumber: localSeasonNumber,
            localEpisodeNumber: localEpisodeNumber,
            anilistMediaId: nil,
            kitsuMediaId: nil,
            tmdbSeasonNumber: localSeasonNumber,
            tmdbEpisodeNumber: localEpisodeNumber,
            tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: nil,
            animeSeasonEpisodeCount: nil,
            isSpecial: false,
            titleOnlySearch: false
        )
    }

    private static func hasExactTMDBCoordinates(_ context: EpisodePlaybackContext) -> Bool {
        context.resolvedTMDBSeasonNumber.map { $0 >= 0 } == true
            && context.resolvedTMDBEpisodeNumber.map { $0 > 0 } == true
    }
}

struct ContinueWatchingCard: View {
    let item: ContinueWatchingItem
    let tmdbService: TMDBService
    let onDataChanged: () -> Void
    @Binding var requestedTVFocusItemID: String?
    let onItemDisappeared: () -> Void

    @AppStorage("tmdbLanguage") private var selectedLanguage = "en-US"

    @State private var backdropURL: String?
    @State private var logoURL: String?
    @State private var title: String = ""
    @State private var isHovering = false
    @State private var isLoaded = false
    @State private var showingSearchResults = false
    @State private var showingDetails = false
    @State private var nextEpisodeSearchTarget: ResolvedNextEpisodeTarget?
    @StateObject private var autoModeRetrySession = AutoModeRetrySession()
#if os(iOS)
    @State private var presentationSceneIdentifier: String?
#endif

    @State private var isAnimeContent = false
    @State private var animeSeasonTitle: String? = nil
    @State private var animeSeasonRomajiTitle: String? = nil
    @State private var originalTitle: String? = nil
    @State private var originalAudioLanguage: String? = nil
    @State private var isMetadataReady = false
    @State private var pendingOpenSheet = false
    @State private var imdbId: String? = nil
    @State private var enrichedPlaybackContext: EpisodePlaybackContext? = nil
    @State private var detailGenres: [TMDBGenre] = []
    @State private var mediaYear: Int? = nil

    private enum TVActionFocus: Hashable {
        case play
        case details
        case watched
        case remove
    }

    @FocusState private var tvActionFocus: TVActionFocus?

    private struct PlayButtonModifier: ViewModifier {
        let focus: FocusState<TVActionFocus?>.Binding

        @ViewBuilder
        func body(content: Content) -> some View {
#if os(tvOS)
            content
                .buttonStyle(.card)
                .focused(focus, equals: .play)
#else
            content.buttonStyle(PlainButtonStyle())
#endif
        }
    }

    private var globalCardSizeScale: CGFloat {
        guard ExperimentalFeatureState.isEnabledAtLaunch, !isTvOS else { return 1 }
        return CGFloat(ExperimentalVisualTuning.current.mediaCardScale)
    }
    private var cardWidth: CGFloat { (isTvOS ? 380 : (isIPad ? 360 : 260)) * globalCardSizeScale }
    private var cardHeight: CGFloat { (isTvOS ? 220 : (isIPad ? 200 : 146)) * globalCardSizeScale }
    private var logoMaxWidth: CGFloat { isTvOS ? 200 : (isIPad ? 180 : 140) }
    private var logoMaxHeight: CGFloat { isTvOS ? 60 : (isIPad ? 52 : 40) }
    private var backdropDecodeSize: CGSize { homeImageDecodeSize(width: cardWidth, height: cardHeight) }
    private var logoDecodeSize: CGSize { homeImageDecodeSize(width: logoMaxWidth, height: logoMaxHeight) }
    private var cardShadowRadius: CGFloat { isIPad ? (isHovering ? 8 : 5) : (isHovering ? 12 : 8) }
    private var cardShadowYOffset: CGFloat { isIPad ? (isHovering ? 5 : 3) : (isHovering ? 8 : 4) }

    private var displayTitle: String {
        title.isEmpty ? item.title : title
    }

    private var searchSheetIsAnime: Bool {
        if let nextEpisodeSearchTarget {
            return nextEpisodeSearchTarget.isAnime
        }
        let playbackContext = enrichedPlaybackContext ?? item.playbackContext
        return isAnimeContent ||
            item.isAnime ||
            playbackContext?.hasAnimeMediaId == true
    }

    private var searchSheetTitle: String {
        if let nextEpisodeSearchTarget {
            return nextEpisodeSearchTarget.mediaTitle
        }
        if searchSheetIsAnime, !item.isMovie,
           let seasonTitle = animeSeasonTitle {
            return seasonTitle
        }
        return displayTitle
    }

    private var selectedEpisodeForSearch: TMDBEpisode? {
        if let nextEpisodeSearchTarget {
            return nextEpisodeSearchTarget.episode
        }
        guard !item.isMovie,
              let seasonNumber = item.seasonNumber,
              let episodeNumber = item.episodeNumber else {
            return nil
        }

        return TMDBEpisode(
            id: Int("\(item.tmdbId)\(seasonNumber)\(episodeNumber)") ?? item.tmdbId,
            name: "",
            overview: nil,
            stillPath: nil,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            airDate: nil,
            runtime: nil,
            voteAverage: 0,
            voteCount: 0
        )
    }

    private var selectedEpisodePlaybackContext: EpisodePlaybackContext? {
        if let nextEpisodeSearchTarget {
            return nextEpisodeSearchTarget.playbackContext
        }
        let baseContext = enrichedPlaybackContext ?? item.playbackContext
        guard let episode = selectedEpisodeForSearch else { return baseContext }
        if PerformanceModeSettings.skipsAniListTraversalForAnimeDetails, searchSheetIsAnime {
            let localCoordinatesAreKnownTMDB: Bool
            switch item.removalTarget {
            case .localUpNextShow:

                localCoordinatesAreKnownTMDB = !item.isAnime && item.playbackContext == nil
            case .localProgress, .traktPlayback, .traktUpNextShow, .none:
                localCoordinatesAreKnownTMDB = false
            }
            return ContinueWatchingAnimePlaybackContextPolicy.resolve(
                existingContext: baseContext,
                localSeasonNumber: episode.seasonNumber,
                localEpisodeNumber: episode.episodeNumber,
                localCoordinatesAreKnownTMDB: localCoordinatesAreKnownTMDB
            )
        }
        return baseContext?.forEpisodeNumber(episode.episodeNumber)
    }

    private var autoModeTargetToken: String {
        AutoModeMediaTargetToken.make(
            tmdbID: item.tmdbId,
            isMovie: item.isMovie,
            episode: selectedEpisodeForSearch,
            playbackContext: selectedEpisodePlaybackContext
        )
    }

    @MainActor
    private func openSearchResultsForNewSession() {
        autoModeRetrySession.reset(targetToken: autoModeTargetToken)
        showingSearchResults = true
    }

    private var detailSearchResult: TMDBSearchResult {
        TMDBSearchResult(
            id: item.tmdbId,
            mediaType: item.isMovie ? "movie" : "tv",
            title: item.isMovie ? displayTitle : nil,
            name: item.isMovie ? nil : displayTitle,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            firstAirDate: nil,
            voteAverage: nil,
            popularity: 0,
            adult: nil,
            genreIds: nil
        )
    }

    var body: some View {
        Group {
            VStack(spacing: isTvOS ? 12 : 0) {
        Button {
#if os(iOS)
            if playPreferredDownloadedMediaIfAvailable() {
                return
            }
#endif
            nextEpisodeSearchTarget = nil
            if isMetadataReady {
                openSearchResultsForNewSession()
            } else {
                pendingOpenSheet = true
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                ZStack {
                    if let backdropURL {
                        KFImage(URL(string: backdropURL))
                            .setProcessor(DownsamplingImageProcessor(size: backdropDecodeSize))
                            .placeholder { backdropPlaceholder }
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        backdropPlaceholder
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipped()

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.3), location: 0.4),
                        .init(color: .black.opacity(0.85), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: isTvOS ? 10 : 6) {
                    Spacer()

                    HStack(alignment: .bottom, spacing: isTvOS ? 12 : 8) {
                        if let logoURL {
                            KFImage(URL(string: logoURL))
                                .setProcessor(DownsamplingImageProcessor(size: logoDecodeSize))
                                .placeholder { titleText }
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: logoMaxWidth, maxHeight: logoMaxHeight, alignment: .leading)
                        } else {
                            titleText
                        }

                        Spacer()

                        if !item.isMovie, let season = item.seasonNumber, let episode = item.episodeNumber {
                            Text("S\(season) E\(episode)")
                                .font(isTvOS ? .subheadline : .caption)
                                .fontWeight(.medium)
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }

                    HStack(spacing: isTvOS ? 12 : 8) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.white.opacity(0.3))
                                    .frame(height: isTvOS ? 6 : 4)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.white)
                                    .frame(width: geometry.size.width * item.progress, height: isTvOS ? 6 : 4)
                            }
                        }
                        .frame(height: isTvOS ? 6 : 4)

                        Text(item.displayStatus)
                            .font(isTvOS ? .subheadline : .caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.8))
                            .fixedSize()
                    }
                }
                .padding(isTvOS ? 16 : 12)
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(isHovering ? 0.5 : 0.15), lineWidth: isHovering ? 2 : 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: cardShadowRadius, x: 0, y: cardShadowYOffset)
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isHovering)
            .modifier(ContinuousHoverModifier(isHovering: $isHovering))
        }
        .modifier(PlayButtonModifier(focus: $tvActionFocus))
#if os(tvOS)
                tvActionBar
#endif
            }
        }
#if os(iOS)
        .background(
            ContinueWatchingWindowSceneReader { scene in
                let identifier = scene.session.persistentIdentifier
                if presentationSceneIdentifier != identifier {
                    presentationSceneIdentifier = identifier
                }
            }
            .frame(width: 0, height: 0)
        )
#endif
        .task {
            await loadMediaDetails()
        }
        .sheet(isPresented: $showingSearchResults) {
            ModulesSearchResultsSheet(
                mediaTitle: searchSheetTitle,
                seasonTitleOverride: nextEpisodeSearchTarget?.seasonTitleOverride
                    ?? (searchSheetIsAnime ? animeSeasonTitle : nil),
                originalTitle: nextEpisodeSearchTarget?.originalTitle
                    ?? (searchSheetIsAnime ? (animeSeasonRomajiTitle ?? originalTitle) : originalTitle),
                isMovie: item.isMovie,
                isAnimeContent: searchSheetIsAnime,
                selectedEpisode: selectedEpisodeForSearch,
                tmdbId: item.tmdbId,
                mediaYear: nextEpisodeSearchTarget?.mediaYear ?? mediaYear,
                animeSeasonTitle: searchSheetIsAnime ? "anime" : nil,
                posterPath: nextEpisodeSearchTarget?.posterURL ?? item.posterURL,
                originalAudioLanguage: originalAudioLanguage,
                imdbId: nextEpisodeSearchTarget?.imdbID ?? imdbId,
                originalTMDBSeasonNumber: selectedEpisodePlaybackContext?.resolvedTMDBSeasonNumber,
                originalTMDBEpisodeNumber: selectedEpisodePlaybackContext?.resolvedTMDBEpisodeNumber,
                specialTitleOnlySearch: selectedEpisodePlaybackContext?.titleOnlySearch ?? false,
                episodePlaybackContext: selectedEpisodePlaybackContext,
                autoModeOnly: AutoModeSettings.isEnabled(),
                autoModeRetrySession: autoModeRetrySession,
                autoModeRecoveryIdentity: autoModeRetrySession.recoveryIdentity(for: autoModeTargetToken),
                onResolvedPlaybackRequest: { request in
                    Task { @MainActor in
                        self.presentResolvedPlayback(request)
                    }
                },
                isAnimationGenre16: nextEpisodeSearchTarget?.isAnimation
                    ?? detailGenres.contains { $0.id == 16 }
            )
        }
#if !os(tvOS)
        .contextMenu {
            Button {
                showingDetails = true
            } label: {
                Label("Details", systemImage: "info.circle")
            }

            Button {
                markAsWatched()
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }

            if item.removalTarget.isRemovable {
                Button(role: .destructive) {
                    removeFromContinueWatching()
                } label: {
                    Label(item.isWatchNext ? "Remove from Up Next" : "Remove", systemImage: "trash")
                }
            }
        }
#endif
        .background(
            NavigationLink(destination: MediaDetailView(searchResult: detailSearchResult), isActive: $showingDetails) {
                EmptyView()
            }
            .hidden()
        )
#if os(tvOS)
        .onChangeComp(of: requestedTVFocusItemID) { _, requestedItemID in
            guard requestedItemID == item.id else { return }
            tvActionFocus = .play
            requestedTVFocusItemID = nil
        }
#endif
    }

#if os(tvOS)
    private var tvActionBar: some View {
        HStack(spacing: 10) {
            Button {
                showingDetails = true
            } label: {
                Label("Details", systemImage: "info.circle")
            }
            .focused($tvActionFocus, equals: .details)

            Button {
                markAsWatched()
            } label: {
                Label("Watched", systemImage: "checkmark.circle")
            }
            .focused($tvActionFocus, equals: .watched)

            if item.removalTarget.isRemovable {
                Button(role: .destructive) {
                    removeFromContinueWatching()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .accessibilityLabel(item.isWatchNext ? "Remove from Up Next" : "Remove")
                .focused($tvActionFocus, equals: .remove)
            }
        }
        .font(.callout)
        .controlSize(.small)
        .buttonStyle(.bordered)
        .frame(width: cardWidth)
    }
#endif

    @ViewBuilder
    private var titleText: some View {
        Text(displayTitle)
            .font(isTvOS ? .title3 : .subheadline)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
    }

    @ViewBuilder
    private var backdropPlaceholder: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Image(systemName: item.isMovie ? "film" : "tv")
                    .font(isTvOS ? .largeTitle : .title)
                    .foregroundColor(.gray.opacity(0.5))
            )
    }

    private func loadMediaDetails() async {
        guard !isLoaded else { return }

        do {
            if item.isMovie {
                async let detailsTask = tmdbService.getMovieDetails(id: item.tmdbId)
                async let imagesTask = tmdbService.getMovieImages(id: item.tmdbId, preferredLanguage: selectedLanguage)
                async let romajiTask = tmdbService.getRomajiTitle(for: "movie", id: item.tmdbId)

                let (details, images, romaji) = try await (detailsTask, imagesTask, romajiTask)

                await MainActor.run {
                    self.title = details.title
                    self.backdropURL = details.fullBackdropURL ?? details.fullPosterURL ?? item.posterURL
                    if let logo = tmdbService.getBestLogo(from: images, preferredLanguage: selectedLanguage) {
                        self.logoURL = logo.fullURL
                    }
                    self.originalTitle = romaji
                    self.originalAudioLanguage = details.originalLanguage
                    self.mediaYear = releaseYear(from: details.releaseDate)
                    self.animeSeasonRomajiTitle = nil
                    self.enrichedPlaybackContext = nil
                    self.imdbId = details.imdbId
                    self.isAnimeContent = false
                    self.isLoaded = true
                    self.isMetadataReady = true
                    if self.pendingOpenSheet {
                        self.pendingOpenSheet = false
                        self.openSearchResultsForNewSession()
                    }
                }
            } else {

                async let detailsTask = tmdbService.getTVShowWithSeasons(id: item.tmdbId)
                async let imagesTask = tmdbService.getTVShowImages(id: item.tmdbId, preferredLanguage: selectedLanguage)
                async let romajiTask = tmdbService.getRomajiTitle(for: "tv", id: item.tmdbId)
                async let episodeArtworkTask = resolveEpisodeArtworkURL()

                let (details, images, romaji, episodeArtworkURL) = try await (detailsTask, imagesTask, romajiTask, episodeArtworkTask)
                let showArtworkURL = details.fullBackdropURL ?? details.fullPosterURL ?? item.posterURL

                let animeOriginCountries: Set<String> = ["JP", "CN", "KR", "TW"]
                let isAsianAnimation = details.originCountry?.contains(where: { animeOriginCountries.contains($0) }) ?? false
                let isAnimation = details.genres.contains { $0.id == 16 }
                let detectedAsAnime = item.isAnime ||
                    item.playbackContext?.hasAnimeMediaId == true ||
                    (isAsianAnimation && isAnimation)

                await MainActor.run {
                    self.title = details.name
                    self.backdropURL = episodeArtworkURL ?? showArtworkURL
                    if let logo = tmdbService.getBestLogo(from: images, preferredLanguage: selectedLanguage) {
                        self.logoURL = logo.fullURL
                    }
                    self.originalTitle = romaji
                    self.originalAudioLanguage = details.originalLanguage
                    self.mediaYear = releaseYear(from: details.firstAirDate)
                    self.imdbId = details.externalIds?.imdbId
                    self.detailGenres = details.genres
                    self.isLoaded = true
                }

                if detectedAsAnime && !PerformanceModeSettings.skipsAniListTraversalForAnimeDetails {

                    let exactAniListId = knownAniListSeasonId()
                    if let exactAniListId,
                       let identity = await AniListService.shared.fetchAnimeSeasonIdentity(
                           anilistId: exactAniListId,
                           tmdbShowId: details.id,
                           title: details.name
                       ) {
                        let context = playbackContext(enrichedWith: identity)
                        applyResolvedAnimeCardMetadata(
                            seasonTitle: identity.title,
                            seasonRomajiTitle: identity.romajiTitle,
                            playbackContext: context,
                            artworkURL: episodeArtworkURL ?? identity.posterURL ?? showArtworkURL
                        )
                        Logger.shared.log(
                            "ContinueWatchingCard: exact AniList season enrichment id=\(exactAniListId) title=\(identity.title)",
                            type: "AniList"
                        )
                    } else {

                        do {
                        let providerSeed = item.playbackContext?.anilistMediaId
                            ?? item.playbackContext?.positiveAniListMediaId
                        let animeData = try await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                            title: details.name,
                            tmdbShowId: details.id,
                            tmdbService: tmdbService,
                            tmdbShowPoster: details.fullPosterURL,
                            token: nil,
                            seedAniListId: providerSeed,
                            seedMALId: providerSeed.flatMap { value in
                                value < 0 ? RemoteMediaNumericBoundary.positiveMagnitude(value) : nil
                            }
                        )
                        let animeEpisodeArtworkURL = resolveAnimeEpisodeArtworkURL(from: animeData)

                        let seasonMappings = animeData.seasons.map {
                            (
                                seasonNumber: $0.seasonNumber,
                                anilistId: $0.canonicalAniListId ?? $0.anilistId
                            )
                        }
                        TrackerManager.shared.registerAniListAnimeData(tmdbId: details.id, seasons: seasonMappings)

                        let matchedSeason: AniListSeasonWithPoster? = {
                            if let anilistId = item.playbackContext?.positiveAniListMediaId {

                                return animeData.seasons.first(where: {
                                    ($0.canonicalAniListId
                                        ?? ($0.anilistId > 0 ? $0.anilistId : nil)) == anilistId
                                })
                            }
                            if let providerID = item.playbackContext?.anilistMediaId,
                               providerID != 0 {
                                return animeData.seasons.first(where: {
                                    $0.anilistId == providerID
                                })
                            }
                            if let kitsuId = item.playbackContext?.kitsuMediaId,
                               kitsuId > 0 {
                                return animeData.seasons.first(where: { $0.kitsuId == kitsuId })
                            }
                            guard let sn = item.seasonNumber else { return animeData.seasons.first }
                            return animeData.seasons.first(where: { $0.seasonNumber == sn })
                                ?? animeData.seasons.first
                        }()

                        let matchedSeasonTitle: String? = {
                            matchedSeason?.title
                        }()

                        let matchedSeasonRomajiTitle: String? = {
                            matchedSeason?.romajiTitle
                        }()

                        var updatedPlaybackContext: EpisodePlaybackContext?
                        if let matchedSeason {
                            updatedPlaybackContext = item.playbackContext?
                                .withCanonicalAniListMediaId(
                                    matchedSeason.canonicalAniListId
                                        ?? (matchedSeason.anilistId > 0 ? matchedSeason.anilistId : nil)
                                )
                                .withMALMediaId(matchedSeason.malId)
                                .withKitsuMediaId(matchedSeason.kitsuId)
                            if let context = updatedPlaybackContext,
                               context.resolvedTMDBEpisodeNumber == nil,
                               let mappedEpisode = matchedSeason.episodes.first(where: {
                                   $0.seasonNumber == context.localSeasonNumber
                                       && $0.number == context.localEpisodeNumber
                               }),
                               let mappedTMDBSeason = mappedEpisode.tmdbSeasonNumber,
                               let mappedTMDBEpisode = mappedEpisode.tmdbEpisodeNumber {
                                updatedPlaybackContext = EpisodePlaybackContext(
                                    localSeasonNumber: context.localSeasonNumber,
                                    localEpisodeNumber: context.localEpisodeNumber,
                                    anilistMediaId: context.anilistMediaId,
                                    canonicalAniListMediaId: context.canonicalAniListMediaId,
                                    malMediaId: context.malMediaId,
                                    kitsuMediaId: context.kitsuMediaId,
                                    tmdbSeasonNumber: mappedTMDBSeason,
                                    tmdbEpisodeNumber: mappedTMDBEpisode,
                                    tmdbEpisodeOffset: context.tmdbEpisodeOffset,
                                    animeAbsoluteEpisodeNumber: context.animeAbsoluteEpisodeNumber,
                                    animeSeasonEpisodeCount: context.animeSeasonEpisodeCount
                                        ?? matchedSeason.episodes.count,
                                    isSpecial: context.isSpecial,
                                    titleOnlySearch: context.titleOnlySearch
                                )
                            }
                        } else {
                            updatedPlaybackContext = item.playbackContext
                        }

                        await MainActor.run {
                            self.isAnimeContent = true
                            self.animeSeasonTitle = matchedSeasonTitle
                            self.animeSeasonRomajiTitle = matchedSeasonRomajiTitle
                            self.enrichedPlaybackContext = updatedPlaybackContext
                            self.backdropURL = animeEpisodeArtworkURL ?? episodeArtworkURL ?? showArtworkURL
                            self.isMetadataReady = true
                            if self.pendingOpenSheet {
                                self.pendingOpenSheet = false
                                self.openSearchResultsForNewSession()
                            }
                        }

                        Logger.shared.log("ContinueWatchingCard: Resolved anime metadata for \(details.name), seasonTitle=\(matchedSeasonTitle ?? "nil")", type: "AniList")
                        } catch {

                            Logger.shared.log("ContinueWatchingCard: AniList fetch failed for \(details.name): \(error.localizedDescription)", type: "AniList")
                            await MainActor.run {
                                self.isAnimeContent = true
                                self.animeSeasonRomajiTitle = nil
                                self.enrichedPlaybackContext = item.playbackContext
                                self.isMetadataReady = true
                                if self.pendingOpenSheet {
                                    self.pendingOpenSheet = false
                                    self.openSearchResultsForNewSession()
                                }
                            }
                        }
                    }
                } else if detectedAsAnime {
                    Logger.shared.log("ContinueWatchingCard skipped AniList metadata because detail traversal performance mode is enabled", type: "AniList")
                    await MainActor.run {
                        self.isAnimeContent = true
                        self.animeSeasonRomajiTitle = nil
                        self.enrichedPlaybackContext = item.playbackContext
                        self.isMetadataReady = true
                        if self.pendingOpenSheet {
                            self.pendingOpenSheet = false
                            self.openSearchResultsForNewSession()
                        }
                    }
                } else {

                    await MainActor.run {
                        self.isAnimeContent = false
                        self.animeSeasonRomajiTitle = nil
                        self.enrichedPlaybackContext = nil
                        self.isMetadataReady = true
                        if self.pendingOpenSheet {
                            self.pendingOpenSheet = false
                            self.openSearchResultsForNewSession()
                        }
                    }
                }
            }
        } catch {
            await MainActor.run {
                if self.title.isEmpty {
                    self.title = item.title
                }
                self.backdropURL = item.posterURL
                self.animeSeasonRomajiTitle = nil
                self.enrichedPlaybackContext = nil
                self.isLoaded = true
                self.isMetadataReady = true
                if self.pendingOpenSheet {
                    self.pendingOpenSheet = false
                    self.openSearchResultsForNewSession()
                }
            }
        }
    }

    private func knownAniListSeasonId() -> Int? {
        guard let context = item.playbackContext,
              let id = context.positiveAniListMediaId,
              context.resolvedTMDBSeasonNumber != nil,
              context.resolvedTMDBEpisodeNumber != nil else {
            return nil
        }
        return id
    }

    private func playbackContext(enrichedWith identity: AniListSeasonIdentity) -> EpisodePlaybackContext? {
        if let existing = item.playbackContext {

            if let itemSeasonNumber = item.seasonNumber,
               let itemEpisodeNumber = item.episodeNumber,
               existing.localSeasonNumber == itemSeasonNumber,
               existing.resolvedTMDBSeasonNumber != nil,
               existing.resolvedTMDBEpisodeNumber != nil,
               !existing.isSpecial {
                let rebased = existing.localEpisodeNumber == itemEpisodeNumber
                    ? existing
                    : existing.forEpisodeNumber(itemEpisodeNumber)
                if rebased.resolvedTMDBSeasonNumber != nil,
                   rebased.resolvedTMDBEpisodeNumber != nil {
                    return rebased
                        .withCanonicalAniListMediaId(identity.anilistId)
                        .withMALMediaId(identity.malId)
                        .withKitsuMediaId(identity.kitsuId)
                }
            }

            return EpisodePlaybackContext(
                localSeasonNumber: existing.localSeasonNumber,
                localEpisodeNumber: existing.localEpisodeNumber,
                anilistMediaId: identity.anilistId,
                canonicalAniListMediaId: identity.anilistId,
                malMediaId: identity.malId,
                kitsuMediaId: identity.kitsuId,
                tmdbSeasonNumber: nil,
                tmdbEpisodeNumber: nil,
                tmdbEpisodeOffset: nil,
                animeAbsoluteEpisodeNumber: nil,
                animeSeasonEpisodeCount: identity.episodeCount,
                isSpecial: false,
                titleOnlySearch: false
            )
        }
        guard let seasonNumber = item.seasonNumber,
              let episodeNumber = item.episodeNumber else {
            return nil
        }
        return EpisodePlaybackContext(
            localSeasonNumber: seasonNumber,
            localEpisodeNumber: episodeNumber,
            anilistMediaId: identity.anilistId,
            canonicalAniListMediaId: identity.anilistId,
            malMediaId: identity.malId,
            kitsuMediaId: identity.kitsuId,
            tmdbSeasonNumber: nil,
            tmdbEpisodeNumber: nil,
            tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: nil,
            animeSeasonEpisodeCount: identity.episodeCount,
            isSpecial: false,
            titleOnlySearch: false
        )
    }

    @MainActor
    private func applyResolvedAnimeCardMetadata(
        seasonTitle: String?,
        seasonRomajiTitle: String?,
        playbackContext: EpisodePlaybackContext?,
        artworkURL: String?
    ) {
        isAnimeContent = true
        animeSeasonTitle = seasonTitle
        animeSeasonRomajiTitle = seasonRomajiTitle
        enrichedPlaybackContext = playbackContext
        backdropURL = artworkURL
        isMetadataReady = true
        if pendingOpenSheet {
            pendingOpenSheet = false
            openSearchResultsForNewSession()
        }
    }

    private func resolveEpisodeArtworkURL() async -> String? {
        guard !item.isMovie else { return nil }
        let seasonNumber = item.playbackContext?.resolvedTMDBSeasonNumber ?? item.seasonNumber
        let episodeNumber = item.playbackContext?.resolvedTMDBEpisodeNumber ?? item.episodeNumber
        guard let seasonNumber, let episodeNumber else { return nil }

        do {
            let detail = try await tmdbService.getSeasonDetails(tvShowId: item.tmdbId, seasonNumber: seasonNumber)
            return detail.episodes.first(where: { $0.episodeNumber == episodeNumber })?.fullStillURL
                ?? detail.fullPosterURL
        } catch {
            Logger.shared.log("ContinueWatchingCard: Episode artwork fetch failed showId=\(item.tmdbId) season=\(seasonNumber) episode=\(episodeNumber): \(error.localizedDescription)", type: "TMDB")
            return nil
        }
    }

    private func resolveAnimeEpisodeArtworkURL(from animeData: AniListAnimeWithSeasons) -> String? {
        guard let localSeasonNumber = item.seasonNumber,
              let localEpisodeNumber = item.episodeNumber else {
            return nil
        }

        let exactSeason = item.playbackContext.flatMap { context in
            if let anilistId = context.positiveAniListMediaId,
               let season = animeData.seasons.first(where: {
                   ($0.canonicalAniListId
                       ?? ($0.anilistId > 0 ? $0.anilistId : nil)) == anilistId
               }) {
                return season
            }
            if let providerID = context.anilistMediaId,
               let season = animeData.seasons.first(where: { $0.anilistId == providerID }) {
                return season
            }
            if let kitsuId = context.kitsuMediaId,
               let season = animeData.seasons.first(where: { $0.kitsuId == kitsuId }) {
                return season
            }
            return nil
        }
        let hasExactProviderIdentity = item.playbackContext?.hasAnimeMediaId == true
            || item.playbackContext?.kitsuMediaId != nil
        let season = exactSeason
            ?? (hasExactProviderIdentity
                ? nil
                : animeData.seasons.first(where: { $0.seasonNumber == localSeasonNumber })
                    ?? animeData.seasons.first)
        let episode = season?.episodes.first(where: { $0.number == localEpisodeNumber })
        return fullImageURL(from: episode?.stillPath)
            ?? season?.posterUrl
    }

    private func fullImageURL(from path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return path }
        return "\(TMDBService.tmdbImageBaseURL)\(path)"
    }

#if os(iOS)
    @MainActor
    private func playPreferredDownloadedMediaIfAvailable() -> Bool {
        guard ProfileSettingsStore.active.bool(forKey: "preferDownloadedMedia") else {
            return false
        }

        let downloadManager = DownloadManager.shared
        let downloadedItem: DownloadItem?
        if item.isMovie {
            downloadedItem = downloadManager.completedDownloadItem(
                tmdbId: item.tmdbId,
                isMovie: true
            )
        } else if let seasonNumber = item.seasonNumber,
                  let episodeNumber = item.episodeNumber {
            downloadedItem = downloadManager.completedEpisodeDownloadItem(
                tmdbId: item.tmdbId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                playbackContext: enrichedPlaybackContext ?? item.playbackContext
            )
        } else {
            downloadedItem = nil
        }

        guard let downloadedItem,
              let presenter = rootPresentationController() else {
            return false
        }

        let resumePosition: Double? = {
            guard case .localProgress = item.removalTarget,
                  item.currentTime.isFinite,
                  item.currentTime > 0 else {
                return nil
            }
            return item.currentTime
        }()
        return presentPreferredDownloadedItem(
            downloadedItem,
            resumePosition: resumePosition,
            playbackContextOverride: enrichedPlaybackContext ?? item.playbackContext,
            from: presenter
        )
    }

    @MainActor
    private func presentPreferredDownloadedItem(
        _ downloadedItem: DownloadItem,
        resumePosition: Double?,
        playbackContextOverride: EpisodePlaybackContext? = nil,
        from presenter: UIViewController
    ) -> Bool {
        let downloadManager = DownloadManager.shared
        guard let fileURL = downloadManager.localFileURL(for: downloadedItem) else { return false }
        let subtitles = downloadManager.localSubtitleURL(for: downloadedItem).map { [$0.absoluteString] } ?? []
        let effectiveContext = playbackContextOverride ?? downloadedItem.episodePlaybackContext
        let effectiveMediaInfo: MediaInfo = {
            guard !downloadedItem.isMovie, let effectiveContext else {
                return downloadedItem.mediaInfo
            }
            return .episode(
                showId: downloadedItem.tmdbId,
                seasonNumber: effectiveContext.localSeasonNumber,
                episodeNumber: effectiveContext.localEpisodeNumber,
                showTitle: downloadedItem.playerTitleBase,
                showPosterURL: downloadedItem.posterURL,
                isAnime: downloadedItem.isAnime || effectiveContext.hasAnimeMediaId
            )
        }()
        let localNextEpisode = nextCompletedDownloadedEpisode(after: downloadedItem)
        let nextEpisodeRequest: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)? = downloadedItem.isMovie ? nil : { [weak presenter] seasonNumber, episodeNumber in
            guard let presenter,
                  let localNextEpisode,
                  localNextEpisode.seasonNumber == seasonNumber,
                  localNextEpisode.episodeNumber == episodeNumber else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                Task { @MainActor in
                    _ = self.presentPreferredDownloadedItem(
                        localNextEpisode,
                        resumePosition: nil,
                        playbackContextOverride: nil,
                        from: presenter
                    )
                }
            }
        }
        let playbackRequest = PlaybackRequest(
            url: fileURL,
            headers: [:],
            subtitles: subtitles,
            mediaInfo: effectiveMediaInfo,
            mediaYear: mediaYear,
            episodePlaybackContext: effectiveContext,
            resumePosition: resumePosition,
            title: downloadedItem.playerTitleBase,
            subtitle: downloadedItem.isMovie ? nil : downloadedItem.displayTitle,
            artworkURL: downloadedItem.posterURL.flatMap(URL.init(string:)),
            isAnime: downloadedItem.isAnime || effectiveContext?.hasAnimeMediaId == true,
            isAnimation: detailGenres.contains { $0.id == 16 },
            originalTMDBSeasonNumber: effectiveContext?.resolvedTMDBSeasonNumber,
            originalTMDBEpisodeNumber: effectiveContext?.resolvedTMDBEpisodeNumber,
            onRequestNextEpisode: nextEpisodeRequest,
            localNextEpisodeFallback: PlaybackEpisodeCoordinate(
                seasonNumber: localNextEpisode?.seasonNumber,
                episodeNumber: localNextEpisode?.episodeNumber
            )
        )

        Logger.shared.log(
            "ContinueWatchingCard: using preferred download id=\(downloadedItem.id) source=\(item.id)",
            type: "Download"
        )
        PlaybackCoordinator.shared.present(playbackRequest, from: presenter)
        return true
    }

    private func nextCompletedDownloadedEpisode(after currentItem: DownloadItem) -> DownloadItem? {
        let downloadManager = DownloadManager.shared

        guard !currentItem.isAnime,
              currentItem.episodePlaybackContext?.hasAnimeMediaId != true else {
            return nil
        }
        let episodes = downloadManager.completedDownloads
            .filter {
                !$0.isMovie
                    && $0.tmdbId == currentItem.tmdbId
                    && $0.seasonNumber != nil
                    && $0.episodeNumber != nil
                    && downloadManager.localFileURL(for: $0) != nil
            }
            .sorted {
                if $0.seasonNumber == $1.seasonNumber {
                    return ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0)
                }
                return ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0)
            }
        guard let currentIndex = episodes.firstIndex(where: { $0.id == currentItem.id }) else { return nil }
        let nextIndex = episodes.index(after: currentIndex)
        return nextIndex < episodes.endIndex ? episodes[nextIndex] : nil
    }
#endif

    @MainActor
    private func presentResolvedPlayback(_ request: PlayerResolvedPlaybackRequest) {
        guard recoveryIdentityIsCurrent(request.autoModeRecoveryIdentity) else {
            invalidateAbandonedSkyStreamPlayback(request)
            Logger.shared.log("ContinueWatchingCard: discarded stale resolved playback before sheet dismissal", type: "Player")
            return
        }
        showingSearchResults = false

        dismissContinueWatchingSheetAndPresent(
            request,
            recoveryIdentity: request.autoModeRecoveryIdentity
        )
    }

    @MainActor
    private func dismissContinueWatchingSheetAndPresent(
        _ request: PlayerResolvedPlaybackRequest,
        recoveryIdentity: AutoModePlaybackRecoveryIdentity?,
        attempt: Int = 0
    ) {
        guard recoveryIdentityIsCurrent(recoveryIdentity) else {
            invalidateAbandonedSkyStreamPlayback(request)
            Logger.shared.log("ContinueWatchingCard: stopped stale resolved playback during dismissal", type: "Player")
            return
        }
        guard let presenter = rootPresentationController() else {
            invalidateAbandonedSkyStreamPlayback(request)
            Logger.shared.log("ContinueWatchingCard: unable to present resolved playback; no presenter", type: "Player")
            return
        }

        if let presented = presenter.presentedViewController, attempt < 3 {
            Logger.shared.log("ContinueWatchingCard: dismissing services sheet before resolved playback attempt=\(attempt) presented=\(type(of: presented))", type: "Player")
            presenter.dismiss(animated: true) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    Task { @MainActor in
                        guard self.recoveryIdentityIsCurrent(recoveryIdentity) else {
                            self.invalidateAbandonedSkyStreamPlayback(request)
                            return
                        }
                        self.dismissContinueWatchingSheetAndPresent(
                            request,
                            recoveryIdentity: recoveryIdentity,
                            attempt: attempt + 1
                        )
                    }
                }
            }
            return
        }
        if presenter.presentedViewController != nil {
            invalidateAbandonedSkyStreamPlayback(request)
            Logger.shared.log("ContinueWatchingCard: unable to clear presentation stack for resolved playback", type: "Player")
            return
        }

        presentResolvedPlaybackAfterSheetDismissal(
            request,
            presenter: presenter,
            recoveryIdentity: recoveryIdentity
        )
    }

    @MainActor
    private func presentResolvedPlaybackAfterSheetDismissal(
        _ request: PlayerResolvedPlaybackRequest,
        presenter: UIViewController,
        recoveryIdentity: AutoModePlaybackRecoveryIdentity?
    ) {
        guard recoveryIdentityIsCurrent(recoveryIdentity) else {
            invalidateAbandonedSkyStreamPlayback(request)
            Logger.shared.log("ContinueWatchingCard: discarded stale resolved playback before presentation", type: "Player")
            return
        }
#if !os(tvOS)
        let externalRaw = ProfileSettingsStore.active.string(forKey: "externalPlayer") ?? ExternalPlayer.none.rawValue
        let external = ExternalPlayer(rawValue: externalRaw) ?? .none
        if request.launchContext?.sourceKind != .skyStream,
           request.launchContext?.sourceKind != .nuvio,
           request.launchContext?.ephemeralProxyOwnership == nil,
           let scheme = external.schemeURL(for: request.url.absoluteString),
           UIApplication.shared.canOpenURL(scheme) {
            UIApplication.shared.open(scheme, options: [:], completionHandler: nil)
            Logger.shared.log("ContinueWatchingCard: opening resolved playback in external player", type: "Player")
            return
        }
#endif
        let episodeSubtitle: String? = {
            guard case .episode(_, let season, let episode, _, _, _) = request.mediaInfo else { return nil }
            return "Season \(season), Episode \(episode)"
        }()
        let nextEpisodeRequest: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)? = item.isMovie ? nil : { seasonNumber, nextEpisodeNumber in
            Task { @MainActor in
                handleNumericNextEpisodeRequest(seasonNumber: seasonNumber, episodeNumber: nextEpisodeNumber)
            }
        }
        let resolvedNextEpisodeRequest: ((ResolvedNextEpisodeTarget) -> Void)? = item.isMovie ? nil : { target in
            Task { @MainActor in
                handleResolvedNextEpisodeRequest(target)
            }
        }
        let playbackRequest = PlaybackRequest(
            url: request.url,
            preset: request.preset,
            headers: request.headers ?? [:],
            subtitles: request.subtitles ?? [],
            subtitleNames: request.subtitleNames,
            subtitleHeadersByURL: request.subtitleHeadersByURL,
            mediaInfo: request.mediaInfo,
            mediaYear: nextEpisodeSearchTarget?.mediaYear ?? mediaYear,
            imdbID: request.imdbId,
            episodePlaybackContext: request.episodePlaybackContext,
            launchContext: request.launchContext,
            title: displayTitle,
            subtitle: episodeSubtitle,
            artworkURL: backdropURL.flatMap(URL.init(string:)),
            isAnime: request.isAnimeHint,
            isAnimation: request.isAnimationContentHint ?? false,
            originalTMDBSeasonNumber: request.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: request.originalTMDBEpisodeNumber,
            onRequestNextEpisode: nextEpisodeRequest,
            onRequestResolvedNextEpisode: resolvedNextEpisodeRequest,
            onPlaybackStartupFailure: { report in
                Task { @MainActor in
                    self.handleAutoModePlaybackFailure(
                        report,
                        recoveryIdentity: recoveryIdentity
                    )
                }
            }
        )
        Logger.shared.log("ContinueWatchingCard: presenting resolved playback through coordinator", type: "Player")
        PlaybackCoordinator.shared.present(playbackRequest, from: presenter)
    }

    @MainActor
    private func invalidateAbandonedSkyStreamPlayback(_ request: PlayerResolvedPlaybackRequest) {
        request.launchContext?.ephemeralProxyOwnership?.invalidate()
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard request.launchContext?.sourceKind == .skyStream else { return }
        MPVHeaderProxy.shared.invalidateSession(for: request.url)
#endif
    }

    @MainActor
    private func handleResolvedNextEpisodeRequest(_ target: ResolvedNextEpisodeTarget) {
        guard target.showID == item.tmdbId else { return }
        nextEpisodeSearchTarget = target
        autoModeRetrySession.reset(targetToken: autoModeTargetToken)
        showingSearchResults = true
    }

    @MainActor
    private func handleAutoModePlaybackFailure(
        _ report: PlaybackFailureReport,
        recoveryIdentity: AutoModePlaybackRecoveryIdentity?
    ) {
        guard report.context.autoMode,
              let recoveryIdentity,
              recoveryIdentityIsCurrent(recoveryIdentity) else { return }
        autoModeRetrySession.recordPlaybackFailure(report)
        Logger.shared.log(
            "ContinueWatchingCard: Auto Mode playback failed source=\(report.context.sourceName) retry=\(autoModeRetrySession.retryCount); reopening remaining sources",
            type: "Player"
        )
        showingSearchResults = true
    }

    @MainActor
    private func recoveryIdentityIsCurrent(_ identity: AutoModePlaybackRecoveryIdentity?) -> Bool {
        guard let identity else { return true }
        return identity.targetToken == autoModeTargetToken
            && autoModeRetrySession.matches(identity)
    }

    @MainActor
    private func handleNumericNextEpisodeRequest(seasonNumber: Int, episodeNumber: Int) {
        guard !item.isMovie, seasonNumber >= 0, episodeNumber > 0 else { return }
        let baseContext = enrichedPlaybackContext ?? item.playbackContext
        let nextContext = baseContext?.localSeasonNumber == seasonNumber
            ? baseContext?.forEpisodeNumber(episodeNumber)
            : nil
        let episode = TMDBEpisode(
            id: Int("\(item.tmdbId)\(seasonNumber)\(episodeNumber)") ?? item.tmdbId,
            name: "",
            overview: nil,
            stillPath: nil,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            airDate: nil,
            runtime: nil,
            voteAverage: 0,
            voteCount: 0
        )
        handleResolvedNextEpisodeRequest(ResolvedNextEpisodeTarget(
            showID: item.tmdbId,
            episode: episode,
            playbackContext: nextContext,
            mediaTitle: searchSheetTitle,
            seasonTitleOverride: searchSheetIsAnime ? animeSeasonTitle : nil,
            originalTitle: searchSheetIsAnime ? (animeSeasonRomajiTitle ?? originalTitle) : originalTitle,
            posterURL: item.posterURL,
            imdbID: imdbId,
            isAnime: searchSheetIsAnime,
            isAnimation: detailGenres.contains { $0.id == 16 },
            mediaYear: mediaYear
        ))
    }

    private func releaseYear(from rawDate: String?) -> Int? {
        guard let rawDate,
              let year = Int(rawDate.prefix(4)),
              (1800...3000).contains(year) else {
            return nil
        }
        return year
    }

    @MainActor
    private func rootPresentationController() -> UIViewController? {
        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
#if os(iOS)
        let windowScene: UIWindowScene?
        if let presentationSceneIdentifier {
            windowScene = activeScenes.first(where: {
                $0.session.persistentIdentifier == presentationSceneIdentifier
            })
        } else {
            windowScene = activeScenes.count == 1 ? activeScenes.first : nil
        }
#else
        let windowScene = activeScenes.first
#endif
        let window = windowScene?.windows.first(where: { $0.isKeyWindow && $0.rootViewController != nil })
            ?? windowScene?.windows.first(where: {
                !$0.isHidden && $0.alpha > 0 && $0.windowLevel == .normal && $0.rootViewController != nil
            })
        return window?.rootViewController
    }

    private func markAsWatched() {
        ProgressManager.shared.markContinueWatchingItemAsWatched(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDataChanged()
            onItemDisappeared()
        }
    }

    private func removeFromContinueWatching() {
        switch item.removalTarget {
        case .traktPlayback(let playbackId):
            TrackerManager.shared.removeTraktContinueWatchingItem(playbackId) {
                onDataChanged()
                onItemDisappeared()
            }
            return
        case .traktUpNextShow:
            TrackerManager.shared.removeTraktUpNextShow(tmdbId: item.tmdbId) {
                onDataChanged()
                onItemDisappeared()
            }
            return
        case .localUpNextShow:
            ProgressManager.shared.removeUpNextShow(item)
        case .localProgress:
            ProgressManager.shared.removeContinueWatchingItem(item)
        case .none:
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDataChanged()
            onItemDisappeared()
        }
    }
}

#if os(iOS)
private struct ContinueWatchingWindowSceneReader: UIViewRepresentable {
    let onResolve: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onResolve = onResolve
        uiView.resolveIfAttached()
    }

    final class ProbeView: UIView {
        var onResolve: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolveIfAttached()
        }

        func resolveIfAttached() {
            guard let scene = window?.windowScene else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onResolve?(scene)
            }
        }
    }
}
#endif

struct ContinuousHoverModifier: ViewModifier {
    @Binding var isHovering: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .onContinuousHover { phase in
                    switch phase {
                    case .active(_):
                        isHovering = true
                    case .ended:
                        isHovering = false
                    }
                }
        } else {
            content
        }
    }
}
