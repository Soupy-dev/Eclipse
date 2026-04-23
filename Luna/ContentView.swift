//
//  ContentView.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI

struct ContentView: View {
    private enum AppTab: Hashable {
        case home, schedule, downloads, library, search
    }
    
    @StateObject private var accentColorManager = AccentColorManager.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @AppStorage("githubReleaseShowAlertPending") private var githubReleaseShowAlertPending = false
    @AppStorage("githubReleaseLatestVersion") private var githubReleaseLatestVersion = ""
    @AppStorage("githubReleaseURL") private var githubReleaseURL = ""

    @State private var selectedTab: AppTab = .home
    @State private var showingSettings = false
    @State private var showingReleaseAlert = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Namespace private var heroNamespace
    
    init() {
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
                        .accentColor(accentColorManager.currentAccentColor)
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
            if newPhase == .active {
                Task { await runBackgroundAutoChecks() }
            }
        }
        .onAppear {
            presentUpdateAlertIfNeeded()
        }
        .onChange(of: githubReleaseShowAlertPending) { pending in
            if pending {
                presentUpdateAlertIfNeeded()
            }
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
    }

    private func runBackgroundAutoChecks() async {
        await ServiceManager.shared.autoUpdateServicesIfNeeded()
        await GitHubReleaseChecker.checkForUpdatesIfNeeded()

        await MainActor.run {
            presentUpdateAlertIfNeeded()
        }
    }

    private func presentUpdateAlertIfNeeded() {
        guard githubReleaseShowAlertPending else { return }
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
                HomeView()
            }
            
            Tab("Schedule", systemImage: "calendar", value: AppTab.schedule) {
                ScheduleView()
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
            LunaTheme.shared.backgroundBase
                .ignoresSafeArea()
            
            if #available(iOS 16.0, *) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button(action: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                        showingSettings = false
                                    }
                                }) {
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
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button(action: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                        showingSettings = false
                                    }
                                }) {
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
    
    private var olderTabView: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Home")
                }
                .tag(AppTab.home)
            
            ScheduleView()
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
        .accentColor(accentColorManager.currentAccentColor)
    }
}

#Preview {
    ContentView()
}
