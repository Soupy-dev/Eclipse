import SwiftUI

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

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Namespace private var heroNamespace
    private let onStartupReady: () -> Void
    
    init(onStartupReady: @escaping () -> Void = {}) {
        self.onStartupReady = onStartupReady
        configureTabBarAppearance()
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
                Task { await runBackgroundAutoChecks() }
            }
        }
        .onAppear {
            publishScenePhase(scenePhase)
            presentUpdateAlertIfNeeded()
        }
        .onChange(of: githubReleaseShowAlertPending) { pending in
            if pending {
                presentUpdateAlertIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .animeMetadataDidSwitchToMALFallback)) { _ in
            showingAniListFallbackAlert = true
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
        // Give Home's first user-visible catalog request priority over hourly
        // service maintenance and daily source probes. These checks retain
        // their existing eligibility intervals and still run on foreground.
        do {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        await ServiceManager.shared.autoUpdateServicesIfNeeded()
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
                HomeView(onStartupReady: onStartupReady)
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
        }
        .preferredColorScheme(.dark)
    }

    private func dismissSettings() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            showingSettings = false
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

    private var olderTabView: some View {
        TabView(selection: $selectedTab) {
            HomeView(onStartupReady: onStartupReady)
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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Namespace private var heroNamespace

    private let onStartupReady: () -> Void

    init(onStartupReady: @escaping () -> Void = {}) {
        self.onStartupReady = onStartupReady
        configureTabBarAppearance()
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
                Task { await runBackgroundAutoChecks() }
            }
        }
        .onAppear {
            publishScenePhase(scenePhase)
            presentUpdateAlertIfNeeded()
        }
        .onChange(of: githubReleaseShowAlertPending) { pending in
            if pending {
                presentUpdateAlertIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .animeMetadataDidSwitchToMALFallback)) { _ in
            showingAniListFallbackAlert = true
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
            HomeView(onStartupReady: onStartupReady)
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

            if #available(iOS 16.0, *) {
                NavigationStack {
                    SettingsView(onRootDismiss: dismissSettings)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                closeSettingsButton
                            }
                        }
                }
            } else {
                NavigationView {
                    SettingsView(onRootDismiss: dismissSettings)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                closeSettingsButton
                            }
                        }
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        }
    }

    private var closeSettingsButton: some View {
        Button(action: dismissSettings) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("Back")
            }
        }
    }

    private func dismissSettings() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            showingSettings = false
        }
    }

    private func runBackgroundAutoChecks() async {
        // Keep launch maintenance from contending with Home's first paint.
        do {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        await ServiceManager.shared.autoUpdateServicesIfNeeded()
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

#Preview {
    ContentView()
}
