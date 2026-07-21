import SwiftUI

@MainActor
private enum SkyStreamAutoUpdateState {
    static var isRunning = false
}

@MainActor
private func autoUpdateSkyStreamSourcesIfNeeded() async {
#if os(iOS) && !targetEnvironment(macCatalyst)
    guard PlatformCapabilities.current.supportsSkyStreamPlugins,
          UserDefaults.standard.object(forKey: "autoUpdateServicesEnabled") == nil
            || UserDefaults.standard.bool(forKey: "autoUpdateServicesEnabled") else {
        return
    }

    let timestampKey = "lastSkyStreamAutoUpdateTimestamp"
    let lastTimestamp = UserDefaults.standard.double(forKey: timestampKey)
    if lastTimestamp > 0,
       Date().timeIntervalSince1970 - lastTimestamp < 3_600 {
        return
    }
    guard !SkyStreamAutoUpdateState.isRunning else { return }
    SkyStreamAutoUpdateState.isRunning = true
    defer { SkyStreamAutoUpdateState.isRunning = false }

    // The manager loads Core Data lazily. Bound the wait so source maintenance never delays
    // the rest of ContentView's background checks indefinitely on a damaged store.
    let manager = SkyStreamPluginManager.shared
    for _ in 0..<40 where !manager.isLoaded {
        do {
            try await Task.sleep(nanoseconds: 50_000_000)
        } catch {
            return
        }
    }
    guard !Task.isCancelled,
          manager.isLoaded,
          !manager.installedPlugins.isEmpty || !manager.repositories.isEmpty else {
        return
    }
    await manager.refreshRepositoriesAndInstalledPlugins(autoUpdate: true)
    guard !Task.isCancelled else { return }
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timestampKey)
#endif
}

struct ContentView: View {
    private enum AppTab: Hashable {
        case home, schedule, downloads, library, search
    }
    
    @ObservedObject private var downloadManager = DownloadManager.shared
    @AppStorage("githubReleaseShowAlertPending") private var githubReleaseShowAlertPending = false
    @AppStorage("githubReleaseLatestVersion") private var githubReleaseLatestVersion = ""
    @AppStorage("githubReleaseURL") private var githubReleaseURL = ""

    @State private var selectedTab: AppTab = .home
    @State private var showingSettings = false
    @State private var showingReleaseAlert = false
    @State private var showingAniListFallbackAlert = false
    @State private var playerInterfaceCoverage = PlayerInterfaceCoverageState()

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.eclipseWindowSceneSessionIdentifier) private var windowSceneSessionIdentifier
    @Namespace private var heroNamespace
    private let onStartupReady: () -> Void
    
    init(onStartupReady: @escaping () -> Void = {}) {
        self.onStartupReady = onStartupReady
        configureTabBarAppearance()
    }

    private var playerCoversInterface: Bool {
        playerInterfaceCoverage.isCovered(in: windowSceneSessionIdentifier)
    }
    
    private func configureTabBarAppearance() {
        #if !os(tvOS)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 0.92)
        appearance.shadowColor = .clear
        
        let itemAppearance = UITabBarItemAppearance()
        itemAppearance.normal.iconColor = UIColor.gray
        itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.gray]
        
        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance
        
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        #endif
    }
    
    var body: some View {
        Group {
#if compiler(>=6.0)
            if #available(iOS 26.0, tvOS 26.0, *) {
                ZStack {
                    modernTabView
                        .heroNamespace(heroNamespace)
                        .overlay(alignment: .topTrailing) {
                            if (selectedTab == .home || selectedTab == .schedule) && !showingSettings {
                                FloatingSettingsOverlay(showingSettings: $showingSettings)
                            }
                        }
                    
                    if showingSettings {
                        settingsFullScreen
                            .zIndex(1)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .trailing))
                            ))
                    }
                }
            } else {
                ZStack {
                    olderTabView
                        .heroNamespace(heroNamespace)
                        .overlay {
                            if (selectedTab == .home || selectedTab == .schedule) && !showingSettings {
                                FloatingSettingsOverlay(showingSettings: $showingSettings)
                            }
                        }
                    
                    if showingSettings {
                        settingsFullScreen
                            .zIndex(1)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .trailing))
                            ))
                    }
                }
            }
#else
            ZStack {
                olderTabView
                    .heroNamespace(heroNamespace)
                    .overlay {
                        if (selectedTab == .home || selectedTab == .schedule) && !showingSettings {
                            FloatingSettingsOverlay(showingSettings: $showingSettings)
                        }
                    }
                
                if showingSettings {
                    settingsFullScreen
                        .zIndex(1)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .trailing))
                        ))
                }
            }
#endif
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showingSettings)
        .task { await runBackgroundAutoChecks() }
        .onChange(of: scenePhase) { newPhase in
            publishScenePhase(newPhase)
            if newPhase == .active {
#if !os(tvOS)
                openPendingNotificationRouteIfNeeded()
#endif
                Task { await runBackgroundAutoChecks() }
            }
        }
        .onAppear {
            updatePerformanceSurface()
            publishScenePhase(scenePhase)
            presentUpdateAlertIfNeeded()
#if !os(tvOS)
            openPendingNotificationRouteIfNeeded()
#endif
        }
#if !os(tvOS)
        .onChange(of: windowSceneSessionIdentifier) { _ in
            openPendingNotificationRouteIfNeeded()
        }
#endif
        .onChange(of: githubReleaseShowAlertPending) { pending in
            if pending {
                presentUpdateAlertIfNeeded()
            }
        }
        .onChange(of: selectedTab) { _ in
            updatePerformanceSurface()
        }
        .onChange(of: showingSettings) { _ in
            updatePerformanceSurface()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerInterfaceCoverageDidChange)) { notification in
            playerInterfaceCoverage.consume(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .animeMetadataDidSwitchToMALFallback)) { _ in
            showingAniListFallbackAlert = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openScheduleFromLocalNotification)) { _ in
#if !os(tvOS)
            openPendingNotificationRouteIfNeeded()
#endif
        }
        .alert("Update Available", isPresented: $showingReleaseAlert) {
            Button("Later", role: .cancel) {
                consumeUpdateAlert()
            }

            Button("Open Release") {
                consumeUpdateAlert()
                if let url = URL(string: githubReleaseURL), !githubReleaseURL.isEmpty {
                    openURL(url)
                }
            }
        } message: {
            if githubReleaseLatestVersion.isEmpty {
                Text("A new Eclipse release is available on GitHub.")
            } else {
                Text("A new Eclipse release (\(githubReleaseLatestVersion)) is available on GitHub.")
            }
        }
        .alert("AniList Unavailable", isPresented: $showingAniListFallbackAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("AniList appears to be down. Eclipse is switching to MyAnimeList fallback for anime metadata. Season and special mapping should still work, but may be less accurate until AniList recovers.")
        }
    }

    private func runBackgroundAutoChecks() async {
        // Let first render and the splash transition settle before hourly service
        // maintenance and daily source probes compete for CPU/network slots.
        do {
            try await Task.sleep(nanoseconds: 6_000_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        await ServiceManager.shared.autoUpdateServicesIfNeeded()
        await autoUpdateSkyStreamSourcesIfNeeded()
        await SourceHealthMonitor.shared.runDailyEnabledSourceChecksIfNeeded()
        await GitHubReleaseChecker.checkForUpdatesIfNeeded()

        await MainActor.run {
            presentUpdateAlertIfNeeded()
        }
    }

    private func presentUpdateAlertIfNeeded() {
        guard GitHubReleaseChecker.shouldShowPendingUpdatePrompt else {
            githubReleaseShowAlertPending = false
            return
        }
        showingReleaseAlert = true
    }

    private func consumeUpdateAlert() {
        GitHubReleaseChecker.consumePendingUpdatePrompt()
        githubReleaseShowAlertPending = false
        showingReleaseAlert = false
    }

#if compiler(>=6.0)
    @available(iOS 26.0, tvOS 26.0, *)
    private var modernTabView: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView(
                    isActive: selectedTab == .home && !showingSettings && !playerCoversInterface,
                    onStartupReady: onStartupReady
                )
            }
            
            Tab("Schedule", systemImage: "calendar", value: AppTab.schedule) {
                ScheduleView(isActive: selectedTab == .schedule)
            }
            
            Tab("Downloads", systemImage: "arrow.down.circle.fill", value: AppTab.downloads) {
                DownloadsView()
            }
#if !os(tvOS)
            .badge(downloadManager.activeDownloadCount > 0 ? downloadManager.activeDownloadCount : 0)
#endif
            
            Tab("Library", systemImage: "books.vertical.fill", value: AppTab.library) {
                LibraryView()
            }
            
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView()
            }
        }
#if !os(tvOS)
        .tabBarMinimizeBehavior(.never)
#endif
    }
#endif
    
    private var settingsFullScreen: some View {
        ZStack {
            EclipseTheme.shared.backgroundBase
                .ignoresSafeArea()

#if os(tvOS)
            if #available(iOS 16.0, *) {
                NavigationStack {
                    SettingsView(onRootDismiss: dismissSettings)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button(action: dismissSettings) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "chevron.left")
                                        Text("Back")
                                    }
                                }
                            }
                        }
                }
            } else {
                NavigationView {
                    SettingsView(onRootDismiss: dismissSettings)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button(action: dismissSettings) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "chevron.left")
                                        Text("Back")
                                    }
                                }
                            }
                        }
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
#else
            SettingsView(onRootDismiss: dismissSettings)
#endif
        }
        .preferredColorScheme(.dark)
    }

    private func dismissSettings() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            showingSettings = false
        }
    }

#if !os(tvOS)
    private func openPendingNotificationRouteIfNeeded() {
        guard scenePhase == .active,
              LocalNotificationManager.shared.shouldHandlePendingNavigation(
                inSceneSessionIdentifier: windowSceneSessionIdentifier
              ) else { return }
        showingSettings = false
        selectedTab = .schedule
    }
#endif

    private func publishScenePhase(_ phase: ScenePhase) {
        let phaseName: String
        switch phase {
        case .active:
            phaseName = "active"
        case .inactive:
            phaseName = "inactive"
        case .background:
            phaseName = "background"
        @unknown default:
            phaseName = "unknown"
        }
        NotificationCenter.default.post(
            name: .eclipseScenePhaseDidChange,
            object: nil,
            userInfo: ["phase": phaseName]
        )
    }

    private func updatePerformanceSurface() {
        if showingSettings {
            AppPerformanceRuntimeContext.shared.setSurface("settings")
            return
        }
        switch selectedTab {
        case .home: AppPerformanceRuntimeContext.shared.setSurface("home")
        case .schedule: AppPerformanceRuntimeContext.shared.setSurface("schedule")
        case .downloads: AppPerformanceRuntimeContext.shared.setSurface("downloads")
        case .library: AppPerformanceRuntimeContext.shared.setSurface("library")
        case .search: AppPerformanceRuntimeContext.shared.setSurface("search")
        }
    }

    private var olderTabView: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                isActive: selectedTab == .home && !showingSettings && !playerCoversInterface,
                onStartupReady: onStartupReady
            )
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Home")
                }
                .tag(AppTab.home)
            
            ScheduleView(isActive: selectedTab == .schedule)
                .tabItem {
                    Image(systemName: "calendar")
                    Text("Schedule")
                }
                .tag(AppTab.schedule)
            
            DownloadsView()
                .tabItem {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Downloads")
                }
                .tag(AppTab.downloads)
#if !os(tvOS)
                .badge(downloadManager.activeDownloadCount > 0 ? downloadManager.activeDownloadCount : 0)
#endif
            
            LibraryView()
                .tabItem {
                    Image(systemName: "books.vertical.fill")
                    Text("Library")
                }
                .tag(AppTab.library)
            
            SearchView()
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                }
                .tag(AppTab.search)
        }
    }
}

struct AppPerformanceOverlayPresentation: ViewModifier {
    let startupReady: Bool
    let homeHydrationComplete: Bool
    let splashVisible: Bool
    let appMode: String
    let modeSwitchActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.eclipseWindowSceneSessionIdentifier) private var windowSceneSessionIdentifier
    @AppStorage(AppPerformanceOverlaySettings.enabledKey) private var overlayEnabled = AppPerformanceOverlaySettings.defaultEnabled
    @AppStorage(HomeAnimatedBackgroundSettings.enabledKey) private var animatedBackgroundEnabled = HomeAnimatedBackgroundSettings.defaultEnabled
    @AppStorage(HomeAnimatedBackgroundQuality.storageKey) private var animatedBackgroundQuality = HomeAnimatedBackgroundQuality.defaultValue.rawValue
    @AppStorage(HomeAnimatedBackgroundFrameRate.storageKey) private var animatedBackgroundFrameRate = HomeAnimatedBackgroundFrameRate.defaultValue.rawValue
    @StateObject private var monitor = AppPerformanceMonitor()
    @State private var playerInterfaceCoverage = PlayerInterfaceCoverageState()

    private var playerCoversInterface: Bool {
        playerInterfaceCoverage.isCovered(in: windowSceneSessionIdentifier)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if overlayEnabled && !playerCoversInterface {
                    AppPerformanceOverlay(
                        snapshot: monitor.snapshot,
                        backgroundQuality: motionText
                    )
                    .padding(.top, 56)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
                    .zIndex(10_000)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playerInterfaceCoverageDidChange)) { notification in
                playerInterfaceCoverage.consume(notification)
            }
            .task(id: monitoringStateID) {
                guard shouldSample else {
                    monitor.stop(context: performanceLogContext, reason: stopReason)
                    return
                }
                let sessionID = monitor.beginSampling(context: performanceLogContext)
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        break
                    }
                    guard !Task.isCancelled else { break }
                    monitor.sampleNow(context: performanceLogContext, sessionID: sessionID)
                }
                monitor.stop(
                    sessionID: sessionID,
                    context: performanceLogContext,
                    reason: "task-cancelled"
                )
            }
    }

    private var motionText: String {
        guard animatedBackgroundEnabled else { return "Off" }
        guard !reduceMotion else { return "Reduced" }
        let quality = HomeAnimatedBackgroundQuality.resolved(animatedBackgroundQuality).displayName
        let frameRate = HomeAnimatedBackgroundFrameRate.resolved(animatedBackgroundFrameRate).displayName
        return "\(quality) · \(frameRate)"
    }

    private var shouldSample: Bool {
        overlayEnabled && scenePhase == .active && !playerCoversInterface
    }

    private var performanceLogContext: AppPerformanceLogContext {
        AppPerformanceLogContext(
            surface: AppPerformanceRuntimeContext.shared.surface,
            appMode: appMode,
            startupPhase: startupReady ? "ready" : "hydrating",
            homeHydrationComplete: homeHydrationComplete,
            splashVisible: splashVisible,
            motion: motionText.lowercased(),
            reduceMotion: reduceMotion,
            modeSwitchActive: modeSwitchActive
        )
    }

    private var stopReason: String {
        if !overlayEnabled { return "disabled" }
        if scenePhase != .active { return "scene-inactive" }
        if playerCoversInterface { return "player-covered" }
        return "stopped"
    }

    private var monitoringStateID: String {
        [
            String(overlayEnabled),
            String(scenePhase == .active),
            String(playerCoversInterface),
            String(startupReady),
            String(homeHydrationComplete),
            String(splashVisible),
            appMode,
            String(modeSwitchActive),
            motionText,
            String(reduceMotion)
        ].joined(separator: "-")
    }
}

#if os(iOS)
struct WatchTogetherJoinPresentation: ViewModifier {
    @State private var request: WatchTogetherJoinRequest?
    @State private var playerInterfaceCoverage = PlayerInterfaceCoverageState()
    @State private var dismissAfterPlayerCloses = false
    @Environment(\.eclipseWindowSceneSessionIdentifier) private var windowSceneSessionIdentifier

    private var playerCoversInterface: Bool {
        playerInterfaceCoverage.isCovered(in: windowSceneSessionIdentifier)
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                consumePendingRequestIfNeeded()
            }
            .onChange(of: windowSceneSessionIdentifier) { _ in
                consumePendingRequestIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchTogetherJoinRequested)) { _ in
                consumePendingRequestIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchTogetherSessionCleared)) { _ in
                guard request != nil else { return }
                if playerCoversInterface {
                    // Keep an already-playing video alive when SharePlay ends, then discard the
                    // session-owned detail route once the user closes the player.
                    dismissAfterPlayerCloses = true
                } else {
                    request = nil
                    dismissAfterPlayerCloses = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playerInterfaceCoverageDidChange)) { notification in
                playerInterfaceCoverage.consume(notification)
                if !playerCoversInterface, dismissAfterPlayerCloses {
                    request = nil
                    dismissAfterPlayerCloses = false
                }
            }
            .fullScreenCover(item: $request) { request in
                MediaDetailView(
                    searchResult: request.searchResult,
                    watchTogetherAutoPlay: request.media
                )
                .id(request.id)
            }
    }

    private func consumePendingRequestIfNeeded() {
        guard request == nil else { return }
        if let pendingRequest = WatchTogetherCoordinator.shared.takePendingJoinRequest(
            forSceneSessionIdentifier: windowSceneSessionIdentifier
        ) {
            dismissAfterPlayerCloses = false
            request = pendingRequest
        }
    }
}
#endif

#if !os(tvOS)
private enum ExperimentalMediaTab: Hashable {
    case home
    case schedule
    case downloads
    case library
    case search
}

struct ExperimentalContentView: View {
    @ObservedObject private var downloadManager = DownloadManager.shared
    @AppStorage("githubReleaseShowAlertPending") private var githubReleaseShowAlertPending = false
    @AppStorage("githubReleaseLatestVersion") private var githubReleaseLatestVersion = ""
    @AppStorage("githubReleaseURL") private var githubReleaseURL = ""

    @State private var selectedTab: ExperimentalMediaTab = .home
    @State private var showingSettings = false
    @State private var showingReleaseAlert = false
    @State private var showingAniListFallbackAlert = false
    @State private var playerInterfaceCoverage = PlayerInterfaceCoverageState()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.eclipseWindowSceneSessionIdentifier) private var windowSceneSessionIdentifier
    @Namespace private var heroNamespace

    private let onStartupReady: () -> Void

    init(onStartupReady: @escaping () -> Void = {}) {
        self.onStartupReady = onStartupReady
        configureTabBarAppearance()
    }

    private var playerCoversInterface: Bool {
        playerInterfaceCoverage.isCovered(in: windowSceneSessionIdentifier)
    }

    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 0.92)
        appearance.shadowColor = .clear

        let itemAppearance = UITabBarItemAppearance()
        itemAppearance.normal.iconColor = UIColor.gray
        itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.gray]
        itemAppearance.selected.iconColor = UIColor.white
        itemAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.white]

        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        ZStack {
            GlobalGradientBackground(allowsAnimatedBackground: false)
                .ignoresSafeArea()

            experimentalTabView
                .heroNamespace(heroNamespace)
                .overlay(alignment: .topTrailing) {
                    if (selectedTab == .home || selectedTab == .schedule) && !showingSettings {
                        FloatingSettingsOverlay(showingSettings: $showingSettings)
                    }
                }

            if showingSettings {
                experimentalSettingsFullScreen
                    .zIndex(2)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showingSettings)
        .task { await runBackgroundAutoChecks() }
        .onChange(of: scenePhase) { newPhase in
            publishScenePhase(newPhase)
            if newPhase == .active {
                openPendingNotificationRouteIfNeeded()
                Task { await runBackgroundAutoChecks() }
            }
        }
        .onAppear {
            updatePerformanceSurface()
            publishScenePhase(scenePhase)
            presentUpdateAlertIfNeeded()
            openPendingNotificationRouteIfNeeded()
        }
        .onChange(of: windowSceneSessionIdentifier) { _ in
            openPendingNotificationRouteIfNeeded()
        }
        .onChange(of: githubReleaseShowAlertPending) { pending in
            if pending {
                presentUpdateAlertIfNeeded()
            }
        }
        .onChange(of: selectedTab) { _ in
            updatePerformanceSurface()
        }
        .onChange(of: showingSettings) { _ in
            updatePerformanceSurface()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerInterfaceCoverageDidChange)) { notification in
            playerInterfaceCoverage.consume(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .animeMetadataDidSwitchToMALFallback)) { _ in
            showingAniListFallbackAlert = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openScheduleFromLocalNotification)) { _ in
            openPendingNotificationRouteIfNeeded()
        }
        .alert("Update Available", isPresented: $showingReleaseAlert) {
            Button("Later", role: .cancel) { consumeUpdateAlert() }
            Button("Open Release") {
                consumeUpdateAlert()
                if let url = URL(string: githubReleaseURL), !githubReleaseURL.isEmpty {
                    openURL(url)
                }
            }
        } message: {
            if githubReleaseLatestVersion.isEmpty {
                Text("A new Eclipse release is available on GitHub.")
            } else {
                Text("A new Eclipse release (\(githubReleaseLatestVersion)) is available on GitHub.")
            }
        }
        .alert("AniList Unavailable", isPresented: $showingAniListFallbackAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("AniList appears to be down. Eclipse is switching to MyAnimeList fallback for anime metadata. Season and special mapping should still work, but may be less accurate until AniList recovers.")
        }
    }

    private var experimentalTabView: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                isActive: selectedTab == .home && !showingSettings && !playerCoversInterface,
                onStartupReady: onStartupReady
            )
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Home")
                }
                .tag(ExperimentalMediaTab.home)

            ScheduleView(isActive: selectedTab == .schedule)
                .tabItem {
                    Image(systemName: "calendar")
                    Text("Schedule")
                }
                .tag(ExperimentalMediaTab.schedule)

            DownloadsView()
                .tabItem {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Downloads")
                }
                .tag(ExperimentalMediaTab.downloads)
                .badge(downloadManager.activeDownloadCount > 0 ? downloadManager.activeDownloadCount : 0)

            LibraryView()
                .tabItem {
                    Image(systemName: "books.vertical.fill")
                    Text("Library")
                }
                .tag(ExperimentalMediaTab.library)

            SearchView()
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                }
                .tag(ExperimentalMediaTab.search)
        }
    }

    private var experimentalSettingsFullScreen: some View {
        ZStack(alignment: .topLeading) {
            GlobalGradientBackground(allowsAnimatedBackground: false)
                .ignoresSafeArea()

            SettingsView(onRootDismiss: dismissSettings)
        }
    }

    private func dismissSettings() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            showingSettings = false
        }
    }

    private func openPendingNotificationRouteIfNeeded() {
        guard scenePhase == .active,
              LocalNotificationManager.shared.shouldHandlePendingNavigation(
                inSceneSessionIdentifier: windowSceneSessionIdentifier
              ) else { return }
        showingSettings = false
        selectedTab = .schedule
    }

    private func runBackgroundAutoChecks() async {
        // Keep launch maintenance outside first render and the splash transition.
        do {
            try await Task.sleep(nanoseconds: 6_000_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        await ServiceManager.shared.autoUpdateServicesIfNeeded()
        await autoUpdateSkyStreamSourcesIfNeeded()
        await SourceHealthMonitor.shared.runDailyEnabledSourceChecksIfNeeded()
        await GitHubReleaseChecker.checkForUpdatesIfNeeded()

        await MainActor.run {
            presentUpdateAlertIfNeeded()
        }
    }

    private func publishScenePhase(_ phase: ScenePhase) {
        let phaseName: String
        switch phase {
        case .active:
            phaseName = "active"
        case .inactive:
            phaseName = "inactive"
        case .background:
            phaseName = "background"
        @unknown default:
            phaseName = "unknown"
        }
        NotificationCenter.default.post(
            name: .eclipseScenePhaseDidChange,
            object: nil,
            userInfo: ["phase": phaseName]
        )
    }

    private func updatePerformanceSurface() {
        if showingSettings {
            AppPerformanceRuntimeContext.shared.setSurface("settings")
            return
        }
        switch selectedTab {
        case .home: AppPerformanceRuntimeContext.shared.setSurface("home")
        case .schedule: AppPerformanceRuntimeContext.shared.setSurface("schedule")
        case .downloads: AppPerformanceRuntimeContext.shared.setSurface("downloads")
        case .library: AppPerformanceRuntimeContext.shared.setSurface("library")
        case .search: AppPerformanceRuntimeContext.shared.setSurface("search")
        }
    }

    private func presentUpdateAlertIfNeeded() {
        guard GitHubReleaseChecker.shouldShowPendingUpdatePrompt else {
            githubReleaseShowAlertPending = false
            return
        }
        showingReleaseAlert = true
    }

    private func consumeUpdateAlert() {
        GitHubReleaseChecker.consumePendingUpdatePrompt()
        githubReleaseShowAlertPending = false
        showingReleaseAlert = false
    }
}

#endif

extension Notification.Name {
    static let openScheduleFromLocalNotification = Notification.Name("openScheduleFromLocalNotification")
}

#Preview {
    ContentView()
}
