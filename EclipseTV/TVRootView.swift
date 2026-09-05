import SwiftUI

struct TVRootView: View {
    enum Tab: Hashable {
        case home
        case schedule
        case library
        case search
        case settings
    }

    @State private var selectedTab: Tab = .home
    @State private var homePath = NavigationPath()
    @State private var schedulePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var showingAniListFallbackAlert = false
    @State private var playerInterfaceCoverage = PlayerInterfaceCoverageState()
    @State private var homeHydrationComplete = false
    @StateObject private var nextEpisodeRouter = TVNextEpisodeRoutingCenter.shared
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var heroNamespace

    private var playerCoversInterface: Bool {

        playerInterfaceCoverage.isCovered(in: nil)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                HomeView(isActive: selectedTab == .home && !playerCoversInterface)
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(Tab.home)

            NavigationStack(path: $schedulePath) {

                ScheduleView(isActive: selectedTab == .schedule)
            }
            .tabItem { Label("Schedule", systemImage: "calendar") }
            .tag(Tab.schedule)

            NavigationStack(path: $libraryPath) {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            .tag(Tab.library)

            NavigationStack(path: $searchPath) {
                SearchView()
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(Tab.search)

            NavigationStack(path: $settingsPath) {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(Tab.settings)
        }
        .heroNamespace(heroNamespace)
        .modifier(AppPerformanceOverlayPresentation(
            startupReady: true,
            homeHydrationComplete: homeHydrationComplete,
            splashVisible: false,
            appMode: "media",
            modeSwitchActive: false
        ))
        .onReceive(NotificationCenter.default.publisher(for: .homeInitialHydrationDidComplete)) { _ in
            homeHydrationComplete = true
        }
        .task { await refreshBackgroundServices() }
        .task(priority: .utility) { await warmSchedulesAfterStartup() }
        .onChange(of: scenePhase) { _, newPhase in
            publishScenePhase(newPhase)
            if newPhase == .active {
                MediaStateSyncBootstrap.syncOnActivation()
                Task { await refreshBackgroundServices() }
            }
        }
        .onAppear { publishScenePhase(scenePhase) }
        .onReceive(NotificationCenter.default.publisher(for: .playerInterfaceCoverageDidChange)) { notification in
            playerInterfaceCoverage.consume(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .animeMetadataDidSwitchToMALFallback)) { _ in
            showingAniListFallbackAlert = true
        }
        .sheet(item: $nextEpisodeRouter.target) { route in
            let target = route.target
            ModulesSearchResultsSheet(
                mediaTitle: target.mediaTitle,
                seasonTitleOverride: target.seasonTitleOverride,
                originalTitle: target.originalTitle,
                isMovie: false,
                isAnimeContent: target.isAnime,
                selectedEpisode: target.episode,
                tmdbId: target.showID,
                animeSeasonTitle: target.isAnime ? "anime" : nil,
                posterPath: target.posterURL,
                imdbId: target.imdbID,
                originalTMDBSeasonNumber: target.originalTMDBSeasonNumber,
                originalTMDBEpisodeNumber: target.originalTMDBEpisodeNumber,
                specialTitleOnlySearch: target.playbackContext?.titleOnlySearch == true,
                episodePlaybackContext: target.playbackContext,
                autoModeOnly: AutoModeSettings.isEnabled(),
                onResolvedPlaybackRequest: { request in
                    nextEpisodeRouter.present(request, for: route)
                },
                isAnimationGenre16: target.isAnimation
            )
        }
        .alert("AniList Unavailable", isPresented: $showingAniListFallbackAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Eclipse is temporarily using MyAnimeList metadata. Season and special mapping may be less accurate until AniList recovers.")
        }
        .alert(
            "Next Episode Failed",
            isPresented: Binding(
                get: { nextEpisodeRouter.presentationError != nil },
                set: { if !$0 { nextEpisodeRouter.presentationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                nextEpisodeRouter.presentationError = nil
            }
        } message: {
            Text(nextEpisodeRouter.presentationError ?? "The next episode could not be opened.")
        }
    }

    private func refreshBackgroundServices() async {
        await ServiceManager.shared.autoUpdateServicesIfNeeded()
        await SourceHealthMonitor.shared.runDailyEnabledSourceChecksIfNeeded()
    }

    private func warmSchedulesAfterStartup() async {

        try? await Task.sleep(nanoseconds: 750_000_000)
        guard !Task.isCancelled else { return }
        let requestedDayCount = ScheduleWindow.current.rawValue
        _ = await ScheduleViewModel.shared.notificationScheduleSnapshot(
            dayCount: requestedDayCount
        )
    }

    private func publishScenePhase(_ phase: ScenePhase) {
        let name: String
        switch phase {
        case .active: name = "active"
        case .inactive: name = "inactive"
        case .background: name = "background"
        @unknown default: name = "unknown"
        }
        NotificationCenter.default.post(
            name: .eclipseScenePhaseDidChange,
            object: nil,
            userInfo: ["phase": name]
        )
    }
}

@MainActor
final class TVNextEpisodeRoutingCenter: NSObject, ObservableObject {
    struct RouteAuthority: Equatable {
        let scope: ProviderPlaybackScopeAuthority
        let boundaryGeneration: UUID
    }

    struct Route: Identifiable {
        let id = UUID()
        let target: ResolvedNextEpisodeTarget
        let authority: RouteAuthority
    }

    static let shared = TVNextEpisodeRoutingCenter()

    @Published var target: Route?
    @Published var presentationError: String?

    private let notificationCenter: NotificationCenter
    private var boundaryGeneration = UUID()
    private var pendingRouteID: UUID?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        super.init()
        for name in [Notification.Name.mediaStateWillChangeCurrentUser, .activeProfileDidChange] {
            notificationCenter.addObserver(
                self,
                selector: #selector(invalidateRouting),
                name: name,
                object: nil
            )
        }
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    func captureAuthority() -> RouteAuthority {
        RouteAuthority(
            scope: .capture(),
            boundaryGeneration: boundaryGeneration
        )
    }

    func isCurrent(_ authority: RouteAuthority) -> Bool {
        authority.boundaryGeneration == boundaryGeneration && authority.scope.isCurrent
    }

    func isCurrent(_ route: Route) -> Bool {
        pendingRouteID == route.id && isCurrent(route.authority)
    }

    @objc private func invalidateRouting() {
        boundaryGeneration = UUID()
        pendingRouteID = nil
        target = nil
        presentationError = nil
    }

    func route(
        _ target: ResolvedNextEpisodeTarget,
        authority: RouteAuthority
    ) async {
        guard isCurrent(authority) else { return }
        let route = Route(target: target, authority: authority)
        pendingRouteID = route.id
        presentationError = nil
        self.target = nil
        await Task.yield()
        guard !Task.isCancelled, isCurrent(route) else { return }
        self.target = route
    }

    func present(
        _ resolved: PlayerResolvedPlaybackRequest,
        for route: Route
    ) {
        guard isCurrent(route) else {
            resolved.launchContext?.ephemeralProxyOwnership?.invalidate()
            return
        }
        self.target = nil
        let target = route.target

        let request = PlaybackRequest(
            url: resolved.url,
            preset: resolved.preset,
            headers: resolved.headers ?? [:],
            subtitles: resolved.subtitles ?? [],
            subtitleNames: resolved.subtitleNames,
            subtitleHeadersByURL: resolved.subtitleHeadersByURL,
            mediaInfo: resolved.mediaInfo ?? .episode(
                showId: target.showID,
                seasonNumber: target.episode.seasonNumber,
                episodeNumber: target.episode.episodeNumber,
                showTitle: target.mediaTitle,
                showPosterURL: target.posterURL,
                isAnime: target.isAnime
            ),
            imdbID: resolved.imdbId ?? target.imdbID,
            episodePlaybackContext: resolved.episodePlaybackContext ?? target.playbackContext,
            launchContext: resolved.launchContext,
            title: target.mediaTitle,
            subtitle: target.isAnime
                ? "Episode \(target.episode.episodeNumber)"
                : "Season \(target.episode.seasonNumber), Episode \(target.episode.episodeNumber)",
            artworkURL: target.posterURL.flatMap(URL.init(string:)),
            isAnime: resolved.isAnimeHint || target.isAnime,
            isAnimation: resolved.isAnimationContentHint ?? target.isAnimation,
            originalTMDBSeasonNumber: resolved.originalTMDBSeasonNumber
                ?? target.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: resolved.originalTMDBEpisodeNumber
                ?? target.originalTMDBEpisodeNumber
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isCurrent(route) else {
                request.launchContext?.ephemeralProxyOwnership?.invalidate()
                return
            }
            self.pendingRouteID = nil
            guard let presenter = Self.presentationController() else {
                request.launchContext?.ephemeralProxyOwnership?.invalidate()
                self.presentationError = "The next episode could not be opened. Please try again."
                return
            }
            PlaybackCoordinator.shared.present(request, from: presenter)
        }
    }

    private static func presentationController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        return topmost(from: window?.rootViewController)
    }

    private static func topmost(from controller: UIViewController?) -> UIViewController? {
        guard let controller else { return nil }
        if let presented = controller.presentedViewController, !presented.isBeingDismissed {
            return topmost(from: presented)
        }
        if let navigation = controller as? UINavigationController {
            return topmost(from: navigation.visibleViewController ?? navigation)
        }
        if let tabs = controller as? UITabBarController {
            return topmost(from: tabs.selectedViewController ?? tabs)
        }
        return controller
    }
}
