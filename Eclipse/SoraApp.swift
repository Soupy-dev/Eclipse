//
//  SoraApp.swift
//  Sora
//
//  Created by Francesco on 12/08/25.
//

import SwiftUI
import Combine
#if canImport(Kingfisher)
import Kingfisher
#endif
#if !os(tvOS)
import Nuke
#endif

class AppDelegate: NSObject, UIApplicationDelegate {

#if !os(tvOS)
    private static var orientationLocksByScene: [String: UIInterfaceOrientationMask] = [:]

    static func setOrientationLock(_ mask: UIInterfaceOrientationMask, for scene: UIWindowScene) {
        let identifier = scene.session.persistentIdentifier
        if mask == .all {
            orientationLocksByScene.removeValue(forKey: identifier)
        } else {
            orientationLocksByScene[identifier] = mask
        }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(
                .iOS(interfaceOrientations: mask)
            ) { error in
                Logger.shared.log(
                    "Player orientation geometry update failed: \(error.localizedDescription)",
                    type: "Player"
                )
            }
        }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if let identifier = window?.windowScene?.session.persistentIdentifier {
            return AppDelegate.orientationLocksByScene[identifier] ?? .all
        }

        let activeMasks = Array(AppDelegate.orientationLocksByScene.values)
        return activeMasks.count == 1 ? activeMasks[0] : .all
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        for session in sceneSessions {
            AppDelegate.orientationLocksByScene.removeValue(forKey: session.persistentIdentifier)
        }
    }
#endif

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == "app.eclipse.soupy.downloads" {
            DownloadManager.shared.backgroundCompletionHandler = completionHandler
        }
    }
}

@main
struct SoraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = Settings.shared
    @StateObject private var theme = EclipseTheme.shared
    @StateObject private var localization = LocalizationManager.shared
    @StateObject private var trackerManager = TrackerManager.shared
    @StateObject private var profileManager = ProfileManager.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var startupReady = false
    @State private var startupFallbackScheduled = false
    @State private var schedulePrefetchScheduled = false
    @State private var scheduleWarmupComplete = false
    @State private var homeHydrationComplete = false
    @State private var showSplash = true
    @State private var showProfilePicker: Bool
    @State private var didEvaluateLaunchPicker = false
    @State private var launchUnlockProfile: Profile?
    @State private var showOnboarding: Bool
    @State private var cloudKitUpgradeNoticePending = false
    @State private var showCloudKitUpgradeNotice = false

    @AppStorage("hideSplashScreen", store: .standard) private var hideSplashScreen = false

    @AppStorage(OnboardingState.completedKey, store: .standard)
    private var onboardingCompleted = false
#if !os(tvOS)
    @State private var showAppHubNotice = false

    @AppStorage(OnboardingState.appHubNoticeSeenKey, store: .standard)
    private var appHubNoticeSeen = false
#endif
    private let startupFallbackDelay: TimeInterval = 20
#if os(iOS)
    @State private var lastNotificationMaintenanceDay = Calendar.current.startOfDay(for: Date())
    private let notificationMaintenanceTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    private let cloudSyncMaintenanceTimer = Timer.publish(every: 900, on: .main, in: .common).autoconnect()
#endif

#if !os(tvOS)
    @AppStorage("showKanzen", store: .standard) private var showKanzen: Bool = false
    private var modeSwitchAnimationEnabled: Bool { ModeSwitchAnimationSettings.isEnabled() }
    @StateObject private var modeSwitchTransitionCoordinator = ModeSwitchTransitionCoordinator()
#endif

    init() {

        OnboardingState.bootstrapIfNeeded()
        _ = AppPerformanceRuntimeContext.shared
        _ = LocalizationManager.shared
#if canImport(Kingfisher)
        KingfisherImageCacheConfigurator.configureIfNeeded()
#endif
        CrashReportManager.shared.start()
        GitHubReleaseChecker.registerDefaults()
        ExperimentalFeatureState.configureLaunchState()
        MediaStateSyncBootstrap.startIfAvailable()
#if !os(tvOS)
        LocalNotificationManager.shared.configure()
        ReaderImagePipelineConfigurator.configureIfNeeded()
#endif
#if os(iOS)
        Task { @MainActor in
            WatchTogetherCoordinator.shared.start()
        }
#endif

        DispatchQueue.global(qos: .background).async {
            CacheManager.shared.checkAndAutoClearIfNeeded()
        }
        _ = DownloadManager.shared
#if !os(tvOS)
        // ReaderDownloadManager runs migration recovery synchronously before it
        // loads the mutable queue. If another Reader store is quarantined, the
        // manager still exposes independently verified completed chapters
        // read-only while keeping every provider and mutation path inert.
        Task { @MainActor in
            _ = ReaderDownloadManager.shared
        }
#endif

        let onboardingCompletedAtLaunch = UserDefaults.standard.bool(forKey: OnboardingState.completedKey)
#if (DEBUG || ECLIPSE_PERF_HARNESS) && os(iOS)
        let debugAutoplayRequested = EclipseDebugAutoplay.isRequested
#else
        let debugAutoplayRequested = false
#endif
        _showOnboarding = State(initialValue: !onboardingCompletedAtLaunch && !debugAutoplayRequested)
        _showProfilePicker = State(initialValue: onboardingCompletedAtLaunch && !debugAutoplayRequested && ProfileManager.shared.shouldPresentLaunchPicker)
        _launchUnlockProfile = State(initialValue: ProfileManager.shared.launchProfileRequiringUnlock)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
#if os(tvOS)
                ContentView(onStartupReady: markStartupReady)
                    .onAppear { scheduleStartupFallback() }
#else
                if showKanzen {
                    KanzenAppRoot(
                        onStartupReady: markStartupReady,
                        settings: settings,
                        theme: theme,
                        modeSwitchTransitionCoordinator: modeSwitchTransitionCoordinator
                    )
                        .onAppear { scheduleStartupFallback() }
                        .transition(modeSwitchTransition(isReaderMode: true))
                        .zIndex(1)
                } else {
                    Group {
                        if ExperimentalFeatureState.isEnabledAtLaunch {
                            ExperimentalContentView(onStartupReady: markStartupReady)
                                .environmentObject(theme)
                                .onAppear { scheduleStartupFallback() }
                        } else {
                            ContentView(onStartupReady: markStartupReady)
                                .environmentObject(theme)
                                .onAppear { scheduleStartupFallback() }
                        }
                    }
                    .environmentObject(modeSwitchTransitionCoordinator)
                    .transition(modeSwitchTransition(isReaderMode: false))
                    .zIndex(0)
                }

                if modeSwitchAnimationEnabled, let modeSwitchBurst = modeSwitchTransitionCoordinator.activeBurst {
                    AppModeSwitchBurstOverlay(burst: modeSwitchBurst)
                        .id(modeSwitchBurst.id)
                        .allowsHitTesting(false)
                        .zIndex(2)
                }
#endif

                if showProfilePicker {
                    ProfilePickerView(
                        isReaderMode: profilePickerIsReaderMode,
                        autoUnlockProfile: launchUnlockProfile
                    ) {
                        showProfilePicker = false
                        presentCloudKitUpgradeNoticeIfReady()
                    }
                    .ignoresSafeArea()
                    .zIndex(4)
                }

                if showSplash && !hideSplashScreen {
                    SplashScreenView(isFinished: $startupReady) {
                        withAnimation(.easeInOut(duration: 0.34)) {
                            showSplash = false
                        }
                        presentCloudKitUpgradeNoticeIfReady()
                    }
                        .ignoresSafeArea()
                        .zIndex(6)
                }

                if showOnboarding, !(showSplash && !hideSplashScreen) {

                    OnboardingView {
                        showOnboarding = false
                        presentCloudKitUpgradeNoticeIfReady()
                    }
                        .transition(.opacity)
                        .zIndex(5)
                }

#if !os(tvOS)
                if showAppHubNotice, !showOnboarding, !(showSplash && !hideSplashScreen) {

                    AppHubUpdateNoticeView {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            showAppHubNotice = false
                        }
                        presentCloudKitUpgradeNoticeIfReady()
                    }
                    .transition(.opacity)
                    .zIndex(5)
                }
#endif
            }
            .onAppear {

                guard !didEvaluateLaunchPicker else { return }
                didEvaluateLaunchPicker = true
                showOnboarding = !onboardingCompleted
#if (DEBUG || ECLIPSE_PERF_HARNESS) && os(iOS)
                if EclipseDebugAutoplay.isRequested {
                    showOnboarding = false
                    showProfilePicker = false
                    EclipseDebugAutoplay.scheduleLaunch()
                    return
                }
#endif
#if !os(tvOS)
                showAppHubNotice = onboardingCompleted && !appHubNoticeSeen
#endif

                showProfilePicker = !showOnboarding && ProfileManager.shared.shouldPresentLaunchPicker
                launchUnlockProfile = ProfileManager.shared.launchProfileRequiringUnlock
                cloudKitUpgradeNoticePending =
                    MediaStateSyncBootstrap.prepareCloudKitUpgradeNoticeIfNeeded()
                presentCloudKitUpgradeNoticeIfReady()
            }
#if os(iOS)
            .modifier(WatchTogetherJoinPresentation())
#endif
            .modifier(AppPerformanceOverlayPresentation(
                startupReady: startupReady,
                homeHydrationComplete: homeHydrationComplete,
                splashVisible: showSplash && !hideSplashScreen,
                appMode: performanceAppMode,
                modeSwitchActive: performanceModeSwitchActive
            ))
#if os(iOS)
            .modifier(EclipseWindowSceneScopeModifier())
#endif
            .environment(\.eclipseStartupOverlayVisible, showSplash && !hideSplashScreen)
#if !os(tvOS)
            .coordinateSpace(name: ModeSwitchTransitionCoordinator.coordinateSpaceName)
#endif

            .defaultAppStorage(ProfileSettingsStore.shared.store(for: profileManager.activeProfileID))
            .environment(\.locale, localization.locale)
            .environment(\.layoutDirection, localization.layoutDirection)
            .environmentObject(localization)
            .alert(item: $trackerManager.authenticationNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    primaryButton: .default(Text("Log In")) {
                        trackerManager.reconnectTracker(notice.service)
                    },
                    secondaryButton: .cancel()
                )
            }
            .alert(
                "Cloud Sync Changed",
                isPresented: $showCloudKitUpgradeNotice
            ) {
                Button("Resume Sync") {
                    MediaStateSyncBootstrap.markCloudKitUpgradeNoticeHandled()
                    MediaStateSyncBootstrap.setCloudKitSyncEnabled(true)
                }
                Button("Keep Off", role: .cancel) {
                    MediaStateSyncBootstrap.markCloudKitUpgradeNoticeHandled()
                }
            } message: {
                Text("Earlier versions of Eclipse automatically synced your library and watch progress through iCloud on this device. That sync is now off, and no data was deleted. You can keep it off or explicitly resume syncing.")
            }
            .onAppear {
                trackerManager.checkForExpiredTrackerSessions()
            }
#if !os(tvOS)
            .animation(modeSwitchAnimationEnabled ? .timingCurve(0.2, 0.75, 0.25, 1, duration: 0.82) : nil, value: showKanzen)
            .onChange(of: showKanzen) { newValue in
                if modeSwitchTransitionCoordinator.activeBurst == nil {
                    modeSwitchTransitionCoordinator.beginBurst(toReaderMode: newValue)
                }
                if !newValue {
                    warmSchedulesAfterStartup()
                }
            }
            .onChange(of: modeSwitchAnimationEnabled) { isEnabled in
                if !isEnabled {
                    modeSwitchTransitionCoordinator.cancelBurst()
                }
            }
#endif
            .onReceive(NotificationCenter.default.publisher(for: .homeInitialHydrationDidComplete)) { _ in
                homeHydrationComplete = true
                warmSchedulesAfterStartup()
            }
#if DEBUG
            .onOpenURL { url in
                guard url.scheme?.lowercased() == "luna",
                      url.host?.lowercased() == "open" else { return }
                let components = url.pathComponents.dropFirst()
                switch components.first?.lowercased() {
#if !os(tvOS)
                case "reader":
                    showKanzen = true
                case "video":
                    showKanzen = false
#endif
                case "settings":
                    NotificationCenter.default.post(name: .eclipseDebugOpenSettings, object: nil)
                case "tab":
                    guard let tab = components.dropFirst().first?.lowercased() else { return }
                    NotificationCenter.default.post(
                        name: .eclipseDebugOpenTab,
                        object: nil,
                        userInfo: ["tab": tab]
                    )
                default:
                    break
                }
            }
#endif
#if os(iOS)
            .onAppear {
                MediaStateSyncBootstrap.syncOnActivation()
                ExperimentalCloudSyncManager.shared.syncOnActivationIfNeeded(reason: "launch")
                if LocalNotificationManager.shared.hasPendingScheduleNavigation {
                    showKanzen = false
                }
                if showKanzen, LocalNotificationManager.shared.hasNotificationSelections {
                    warmSchedulesAfterStartup()
                }
                Task {
                    await LocalNotificationManager.shared.refreshAuthorizationStatus()
                }
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    trackerManager.checkForExpiredTrackerSessions()
                    MediaStateSyncBootstrap.syncOnActivation()
                    ExperimentalCloudSyncManager.shared.syncOnActivationIfNeeded(reason: "active")
                    Task {
                        await LocalNotificationManager.shared.refreshAuthorizationStatus()
                        await LocalNotificationManager.shared.syncDeliveredNotificationHistory()
                        guard scheduleWarmupComplete else { return }
                        await LocalNotificationManager.shared.refreshSchedulesIfNeeded()
                    }
                }
            }
            .onReceive(notificationMaintenanceTimer) { _ in
                guard scenePhase == .active, scheduleWarmupComplete else { return }
                let today = Calendar.current.startOfDay(for: Date())
                guard today != lastNotificationMaintenanceDay else { return }
                lastNotificationMaintenanceDay = today
                guard LocalNotificationManager.shared.hasNotificationSelections else { return }
                Task {

                    await LocalNotificationManager.shared.refreshSchedulesIfNeeded()
                }
            }
            .onReceive(cloudSyncMaintenanceTimer) { _ in
                guard scenePhase == .active else { return }
                ExperimentalCloudSyncManager.shared.syncOnActivationIfNeeded(
                    reason: "foreground-periodic"
                )

                MediaStateSyncBootstrap.syncOnActivation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openScheduleFromLocalNotification)) { _ in
                showKanzen = false
            }
#endif
        }
    }

    private var profilePickerIsReaderMode: Bool {
#if os(tvOS)
        false
#else
        showKanzen
#endif
    }

    private func presentCloudKitUpgradeNoticeIfReady() {
        guard cloudKitUpgradeNoticePending,
              !showOnboarding,
              !showProfilePicker,
              !(showSplash && !hideSplashScreen) else { return }
#if !os(tvOS)
        guard !showAppHubNotice else { return }
#endif
        cloudKitUpgradeNoticePending = false
        showCloudKitUpgradeNotice = true
    }

#if !os(tvOS)
    private func modeSwitchTransition(isReaderMode: Bool) -> AnyTransition {
        guard modeSwitchAnimationEnabled else { return .identity }
        return isReaderMode
            ? .eclipseModeWave(origin: modeSwitchTransitionCoordinator.origin)
            : .eclipseMediaModeReturn
    }

#endif

    private var performanceAppMode: String {
#if os(tvOS)
        "media"
#else
        showKanzen ? "reader" : "media"
#endif
    }

    private var performanceModeSwitchActive: Bool {
#if os(tvOS)
        false
#else
        modeSwitchTransitionCoordinator.activeBurst != nil
#endif
    }

    private func markStartupReady() {
        guard !startupReady else { return }
        startupReady = true
        warmSchedulesAfterStartup()
    }

    private func warmSchedulesAfterStartup() {
#if !os(tvOS)

        guard !showKanzen || LocalNotificationManager.shared.hasNotificationSelections else { return }
#endif
        guard !schedulePrefetchScheduled else { return }
        schedulePrefetchScheduled = true

        Task(priority: .utility) {

            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
#if os(tvOS)
            let requestedDayCount = ScheduleWindow.current.rawValue
            _ = await ScheduleViewModel.shared.notificationScheduleSnapshot(
                dayCount: requestedDayCount
            )
#else

            let requestedDayCount = ScheduleWindow.current.rawValue
            let snapshot = await ScheduleViewModel.shared.notificationScheduleSnapshot(
                dayCount: requestedDayCount
            )
#if os(iOS)
            await LocalNotificationManager.shared.consumeStartupScheduleSnapshot(snapshot)
#endif
            await MainActor.run { scheduleWarmupComplete = true }
#endif
        }
    }

    private func scheduleStartupFallback() {
        guard !startupFallbackScheduled else { return }
        startupFallbackScheduled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + startupFallbackDelay) {
            markStartupReady()
        }
    }
}

#if (DEBUG || ECLIPSE_PERF_HARNESS) && os(iOS)
enum EclipseDebugAutoplay {

    static var isRequested: Bool {
        requestedURL != nil
    }

    private static var requestedURL: URL? {
        guard let urlString = ProcessInfo.processInfo.environment["ECLIPSE_DEBUG_AUTOPLAY_URL"],
              !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

    static func scheduleLaunch() {
        let environment = ProcessInfo.processInfo.environment
        guard let url = requestedURL else { return }

        if let modeRaw = environment["ECLIPSE_DEBUG_UPSCALING_MODE"],
           let mode = MPVUpscalingMode(rawValue: modeRaw) {
            Settings.shared.mpvUpscalingMode = mode
        }
        if let upscalerRaw = environment["ECLIPSE_DEBUG_NEURAL_UPSCALER"],
           let upscaler = MPVNeuralUpscaler(rawValue: upscalerRaw) {
            Settings.shared.mpvNeuralUpscaler = upscaler
        }
        let animationHint = environment["ECLIPSE_DEBUG_ANIMATION_HINT"] == "1"

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            present(url: url, animationHint: animationHint)
        }
    }

    private static func present(url: URL, animationHint: Bool) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController else {
            Logger.shared.log("[EclipseDebugAutoplay] no root view controller", type: "Plugin")
            return
        }
        var host = root
        while let presented = host.presentedViewController {
            host = presented
        }
        let preset = PlayerPreset.presets.first
            ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: [])
        let controller = PlayerViewController(url: url, preset: preset)
        controller.isAnimationContentHint = animationHint
        controller.playerTitleOverride = "Debug Autoplay"
        controller.modalPresentationStyle = .fullScreen
        Logger.shared.log(
            "[EclipseDebugAutoplay] presenting url=\(url.absoluteString) animationHint=\(animationHint) mode=\(Settings.shared.mpvUpscalingMode.rawValue) neural=\(Settings.shared.mpvNeuralUpscaler.rawValue)",
            type: "Plugin"
        )
        host.present(controller, animated: false)
    }
}
#endif

#if !os(tvOS)

private struct KanzenAppRoot: View {
    let onStartupReady: () -> Void
    let settings: Settings
    let theme: EclipseTheme
    let modeSwitchTransitionCoordinator: ModeSwitchTransitionCoordinator

    @StateObject private var moduleManager = ModuleManager.shared
    @StateObject private var favouriteManager = FavouriteManager.shared

    var body: some View {
        KanzenMenu(onStartupReady: onStartupReady)
            .environmentObject(settings)
            .environmentObject(theme)
            .environmentObject(moduleManager)
            .environmentObject(favouriteManager)
            .environmentObject(modeSwitchTransitionCoordinator)
            .environment(\.managedObjectContext, favouriteManager.container.viewContext)
            .accentColor(settings.effectiveAccentColor)
    }
}

final class ModeSwitchTransitionCoordinator: ObservableObject {
    static let coordinateSpaceName = "AppModeSwitchTransitionRoot"

    @Published private(set) var origin: CGPoint?
    @Published private(set) var activeBurst: AppModeSwitchBurst?

    func record(origin: CGPoint) {
        guard origin.x.isFinite, origin.y.isFinite else { return }
        self.origin = origin
    }

    func beginBurst(toReaderMode: Bool) {
        let burst = AppModeSwitchBurst(toReaderMode: toReaderMode, origin: origin)
        activeBurst = burst

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.96) { [weak self] in
            if self?.activeBurst?.id == burst.id {
                self?.activeBurst = nil
            }
        }
    }

    func cancelBurst() {
        activeBurst = nil
    }
}

struct ModeSwitchButtonOriginPreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

struct AppModeSwitchBurst: Identifiable, Equatable {
    let id = UUID()
    let toReaderMode: Bool
    let origin: CGPoint?
}

private struct AppModeSwitchBurstOverlay: View {
    let burst: AppModeSwitchBurst

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var waveScale: CGFloat = 0.025
    @State private var waveOpacity = 0.82
    @State private var leadingRingOpacity = 0.72
    @State private var trailingRingScale: CGFloat = 0.025
    @State private var trailingRingOpacity = 0.44
    @State private var waveletProgress: CGFloat = 0

    private var primaryColor: Color {
        burst.toReaderMode
            ? Color(red: 0.64, green: 0.38, blue: 0.31)
            : Color(red: 0.24, green: 0.46, blue: 0.53)
    }

    private var secondaryColor: Color {
        burst.toReaderMode
            ? Color(red: 0.43, green: 0.32, blue: 0.52)
            : Color(red: 0.20, green: 0.34, blue: 0.46)
    }

    private var shadowColor: Color {
        burst.toReaderMode
            ? Color(red: 0.15, green: 0.09, blue: 0.14)
            : Color(red: 0.06, green: 0.13, blue: 0.18)
    }

    var body: some View {
        GeometryReader { proxy in
            let origin = resolvedOrigin(in: proxy)
            let diameter = coverageDiameter(from: origin, in: proxy.size)

            ZStack {

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                primaryColor.opacity(0.76),
                                secondaryColor.opacity(0.66),
                                shadowColor.opacity(0.56)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: diameter * 0.5
                        )
                    )
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(waveScale)
                    .opacity(waveOpacity)
                    .position(origin)

                waveRing(
                    scale: waveScale,
                    opacity: leadingRingOpacity,
                    diameter: diameter,
                    lineWidth: 14
                )
                .position(origin)

                waveRing(
                    scale: trailingRingScale,
                    opacity: trailingRingOpacity,
                    diameter: diameter,
                    lineWidth: 5
                )
                .position(origin)

                ForEach(0..<10, id: \.self) { index in
                    AppModeSwitchWavelet(
                        index: index,
                        progress: waveletProgress,
                        coverage: diameter * 0.5,
                        primaryColor: primaryColor,
                        secondaryColor: secondaryColor
                    )
                    .position(origin)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .onAppear(perform: animate)
    }

    private func waveRing(scale: CGFloat, opacity: Double, diameter: CGFloat, lineWidth: CGFloat) -> some View {
        Circle()
            .stroke(
                LinearGradient(
                    colors: [primaryColor.opacity(0.82), secondaryColor.opacity(0.6), shadowColor.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: lineWidth
            )
            .frame(width: diameter, height: diameter)
            .scaleEffect(scale)
            .opacity(opacity)
    }

    private func resolvedOrigin(in proxy: GeometryProxy) -> CGPoint {
        let fallback = CGPoint(x: proxy.size.width - 38, y: 58)
        let rootFrame = proxy.frame(in: .named(ModeSwitchTransitionCoordinator.coordinateSpaceName))
        guard let origin = burst.origin,
              origin.x >= rootFrame.minX, origin.x <= rootFrame.maxX,
              origin.y >= rootFrame.minY, origin.y <= rootFrame.maxY else {
            return fallback
        }
        return CGPoint(x: origin.x - rootFrame.minX, y: origin.y - rootFrame.minY)
    }

    private func coverageDiameter(from origin: CGPoint, in size: CGSize) -> CGFloat {
        let farthestCorner = max(
            hypot(origin.x, origin.y),
            hypot(size.width - origin.x, origin.y),
            hypot(origin.x, size.height - origin.y),
            hypot(size.width - origin.x, size.height - origin.y)
        )

        return (farthestCorner + 44) * 2
    }

    private func animate() {
        if reduceMotion {

            withAnimation(.easeOut(duration: 0.24)) {
                waveScale = 1
                waveOpacity = 0.2
            }
            withAnimation(.easeIn(duration: 0.32).delay(0.24)) {
                waveOpacity = 0
            }
            return
        }

        let waveTiming = Animation.timingCurve(0.2, 0.75, 0.25, 1, duration: 0.82)
        withAnimation(waveTiming) {
            waveScale = 1
            trailingRingScale = 0.96
            waveletProgress = 1
        }
        withAnimation(.easeOut(duration: 0.4).delay(0.35)) {
            leadingRingOpacity = 0
            trailingRingOpacity = 0
        }
        withAnimation(.easeIn(duration: 0.24).delay(0.62)) {
            waveOpacity = 0
        }
    }
}

private struct AppModeSwitchWavelet: View {
    let index: Int
    let progress: CGFloat
    let coverage: CGFloat
    let primaryColor: Color
    let secondaryColor: Color

    private var angle: Double {
        Double(index) * 36 - 90
    }

    var body: some View {
        let radians = angle * .pi / 180
        let distance = 16 + progress * coverage * (0.2 + CGFloat(index % 3) * 0.09)
        let x = CGFloat(cos(radians)) * distance
        let y = CGFloat(sin(radians)) * distance

        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        (index.isMultiple(of: 2) ? primaryColor : secondaryColor).opacity(0.7),
                        secondaryColor.opacity(0.38),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: 26 + progress * 92, height: 7)
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: y)
            .scaleEffect(1 - progress * 0.3)
            .opacity(Double(max(0, 0.62 - progress * progress * 0.62)))
    }
}

private struct AppModeWaveRevealModifier: AnimatableModifier {
    var progress: CGFloat
    let origin: CGPoint?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(Double(progress))
        } else {
            content.mask {
                GeometryReader { proxy in
                    let rootFrame = proxy.frame(in: .named(ModeSwitchTransitionCoordinator.coordinateSpaceName))
                    let resolvedOrigin = origin.map {
                        CGPoint(x: $0.x - rootFrame.minX, y: $0.y - rootFrame.minY)
                    } ?? CGPoint(x: proxy.size.width - 38, y: 58)
                    let radius = max(
                        hypot(resolvedOrigin.x, resolvedOrigin.y),
                        hypot(proxy.size.width - resolvedOrigin.x, resolvedOrigin.y),
                        hypot(resolvedOrigin.x, proxy.size.height - resolvedOrigin.y),
                        hypot(proxy.size.width - resolvedOrigin.x, proxy.size.height - resolvedOrigin.y)
                    ) + 44
                    let diameter = max(4, radius * 2 * min(max(progress, 0), 1))

                    Circle()
                        .frame(width: diameter, height: diameter)
                        .position(resolvedOrigin)
                }
            }
        }
    }
}

private struct AppModeWaveCutoutModifier: AnimatableModifier {
    var progress: CGFloat
    let origin: CGPoint?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(Double(1 - progress))
        } else {
            content.mask {
                GeometryReader { proxy in
                    let rootFrame = proxy.frame(in: .named(ModeSwitchTransitionCoordinator.coordinateSpaceName))
                    let resolvedOrigin = origin.map {
                        CGPoint(x: $0.x - rootFrame.minX, y: $0.y - rootFrame.minY)
                    } ?? CGPoint(x: proxy.size.width - 38, y: 58)
                    let radius = max(
                        hypot(resolvedOrigin.x, resolvedOrigin.y),
                        hypot(proxy.size.width - resolvedOrigin.x, resolvedOrigin.y),
                        hypot(resolvedOrigin.x, proxy.size.height - resolvedOrigin.y),
                        hypot(proxy.size.width - resolvedOrigin.x, proxy.size.height - resolvedOrigin.y)
                    ) + 44
                    let diameter = radius * 2 * min(max(progress, 0), 1)

                    ZStack {
                        Rectangle()
                        Circle()
                            .frame(width: diameter, height: diameter)
                            .position(resolvedOrigin)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
            }
        }
    }
}

private struct AppModeKeepAliveModifier: AnimatableModifier {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(1)
    }
}

#if canImport(Kingfisher)
private enum KingfisherImageCacheConfigurator {
    private static var didConfigure = false
    private static let memoryCostLimit = 96 * 1024 * 1024
    private static let memoryCountLimit = 192

    static func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        var memoryConfig = ImageCache.default.memoryStorage.config
        memoryConfig.totalCostLimit = memoryCostLimit
        memoryConfig.countLimit = memoryCountLimit
        ImageCache.default.memoryStorage.config = memoryConfig
    }
}
#endif

private extension AnyTransition {

    static var eclipseMediaModeReturn: AnyTransition {
        .asymmetric(
            insertion: .identity,
            removal: .modifier(
                active: AppModeKeepAliveModifier(progress: 1),
                identity: AppModeKeepAliveModifier(progress: 0)
            )
        )
    }

    static func eclipseModeWave(origin: CGPoint?) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: AppModeWaveRevealModifier(progress: 0, origin: origin),
                identity: AppModeWaveRevealModifier(progress: 1, origin: origin)
            ),
            removal: .modifier(
                active: AppModeWaveCutoutModifier(progress: 1, origin: origin),
                identity: AppModeWaveCutoutModifier(progress: 0, origin: origin)
            )
        )
    }
}

private enum ReaderImagePipelineConfigurator {
    private static var didConfigure = false

    static func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        DataLoader.sharedUrlCache.diskCapacity = 0
        DataLoader.sharedUrlCache.memoryCapacity = 0

        let pipeline = ImagePipeline {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil

            let dataCache = try? DataCache(name: "app.eclipse.soupy.reader.datacache")
            dataCache?.sizeLimit = 500 * 1024 * 1024

            let imageCache = Nuke.ImageCache()
            imageCache.costLimit = 100 * 1024 * 1024

            $0.dataCache = dataCache
            $0.imageCache = imageCache
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.dataCachePolicy = .storeOriginalData
            $0.isStoringPreviewsInMemoryCache = false
        }

        ImagePipeline.shared = pipeline
        ReaderLogger.shared.log("Configured reader image pipeline cache data=500MB image=100MB", type: "ReaderPerf")
    }
}
#endif
