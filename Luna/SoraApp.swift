//
//  SoraApp.swift
//  Sora
//
//  Created by Francesco on 12/08/25.
//

import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
#if !os(tvOS)
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
#endif

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == "com.luna.downloads" {
            DownloadManager.shared.backgroundCompletionHandler = completionHandler
        }
    }
}

@main
struct SoraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = Settings()
    @StateObject private var moduleManager = ModuleManager.shared
    @StateObject private var favouriteManager = FavouriteManager.shared

#if !os(tvOS)
    @AppStorage("showKanzen") private var showKanzen: Bool = false
    let kanzen = KanzenEngine();
#endif

    init() {
        // Check and auto-clear cache on app startup if threshold exceeded
        DispatchQueue.global(qos: .background).async {
            CacheManager.shared.checkAndAutoClearIfNeeded()
        }
        // Initialize download manager early to reconnect background session
        _ = DownloadManager.shared
    }

    var body: some Scene {
        WindowGroup {
#if os(tvOS)
            ContentView()
#else
            if showKanzen {
                    KanzenMenu().environmentObject(settings).environmentObject(moduleManager).environmentObject(favouriteManager)
                    .environment(\.managedObjectContext, favouriteManager.container.viewContext)
                    .accentColor(settings.accentColor)
            }
            else{
                ContentView()
            }
#endif
        }
    }
}
