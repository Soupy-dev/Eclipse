//
//  MainMenu.swift
//  Luna
//
//  Created by Dawud Osman on 17/11/2025.
//

import SwiftUI

#if !os(tvOS)
struct KanzenMenu: View {
    let kanzen = KanzenEngine()
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var moduleManager: ModuleManager
    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 0.92)
        appearance.shadowColor = .clear
        let normalAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.gray]
        let selectedAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.white]
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = normalAttrs
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = selectedAttrs
        appearance.stackedLayoutAppearance.normal.iconColor = .gray
        appearance.stackedLayoutAppearance.selected.iconColor = .white
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    var body: some View {
        TabView {
            KanzenHomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            KanzenLibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }

            KanzenGlobalSearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }

            KanzenHistoryView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }

            KanzenSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .environmentObject(kanzen)
        .task {
            await moduleManager.autoUpdateModulesIfNeeded()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                Task {
                    await moduleManager.autoUpdateModulesIfNeeded()
                }
            }
        }
    }
}
#endif
