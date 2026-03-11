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
    @State private var selectedTab: AppTab = .home
    @State private var showingSettings = false
    @Environment(\.scenePhase) private var scenePhase
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
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showingSettings)
            .task { await ServiceManager.shared.autoUpdateServicesIfNeeded() }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    Task { await ServiceManager.shared.autoUpdateServicesIfNeeded() }
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
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showingSettings)
            .task { await ServiceManager.shared.autoUpdateServicesIfNeeded() }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    Task { await ServiceManager.shared.autoUpdateServicesIfNeeded() }
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
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showingSettings)
        .task { await ServiceManager.shared.autoUpdateServicesIfNeeded() }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                Task { await ServiceManager.shared.autoUpdateServicesIfNeeded() }
            }
        }
#endif
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
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button(action: { showingSettings = false }) {
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
                                Button(action: { showingSettings = false }) {
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
        .background(LunaTheme.shared.backgroundBase)
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
