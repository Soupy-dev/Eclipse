import AppKit
import SwiftUI
import UserNotifications

final class EclipseMacApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.userInfo["route"] as? String == "schedule" {
            UserDefaults.standard.set(true, forKey: MacNotificationRouting.pendingScheduleKey)
            DispatchQueue.main.async {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .macOpenScheduleNotification, object: nil)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let isScheduleReminder = notification.request.content.userInfo["route"] as? String == "schedule"
        completionHandler(isScheduleReminder ? [.banner, .sound] : [])
    }
}

enum MacNotificationRouting {
    static let pendingScheduleKey = "macPendingScheduleNotificationRoute"
}

@main
struct EclipseMacApp: App {
    @NSApplicationDelegateAdaptor(EclipseMacApplicationDelegate.self) private var applicationDelegate
    @StateObject private var appState = MacAppState()
    @StateObject private var playback = MacPlaybackController.shared
    @StateObject private var reader = MacReaderController.shared
    @StateObject private var catalog = MacCatalogStore.shared
    @StateObject private var downloads = MacDownloadStore.shared
    @StateObject private var services = MacStremioStore.shared
    @StateObject private var legacyServices = MacLegacyServiceStore.shared
    @StateObject private var cloudLibrary = MacCloudLibrarySync.shared
    @StateObject private var trackers = MacTrackerStore.shared
    @StateObject private var aidoku = MacAidokuStore.shared
    @StateObject private var mediaState = MacMediaStateStore.shared

    var body: some Scene {
        WindowGroup("Eclipse", id: MacWindowID.main) {
            MacRootView()
                .environmentObject(appState)
                .environmentObject(playback)
                .environmentObject(reader)
                .environmentObject(catalog)
                .environmentObject(downloads)
                .environmentObject(services)
                .environmentObject(legacyServices)
                .environmentObject(cloudLibrary)
                .environmentObject(trackers)
                .environmentObject(aidoku)
                .environmentObject(mediaState)
                .frame(minWidth: 900, minHeight: 620)
                .preferredColorScheme(.dark)
                .task {
                    await MacStorageMaintenance.runIfNeeded()
                    await catalog.refreshScheduleNotificationsFromStoredPreferences()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            MacAppCommands()
        }

        Window("Player", id: MacWindowID.player) {
            MacPlayerView()
                .environmentObject(playback)
                .environmentObject(downloads)
                .environmentObject(services)
                .environmentObject(legacyServices)
                .environmentObject(cloudLibrary)
                .environmentObject(trackers)
                .environmentObject(aidoku)
                .environmentObject(mediaState)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 700)
        .windowResizability(.contentMinSize)

        Window("Reader", id: MacWindowID.reader) {
            MacReaderView()
                .environmentObject(reader)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 980, height: 760)
        .windowResizability(.contentMinSize)

    }
}

enum MacWindowID {
    static let main = "eclipse-main"
    static let player = "eclipse-player"
    static let reader = "eclipse-reader"
}

private struct MacAppCommands: Commands {
    @FocusedValue(\.macNavigationAction) private var navigationAction

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Media…") {
                NotificationCenter.default.post(name: .macOpenMedia, object: nil)
            }
            .keyboardShortcut("o")
        }

        CommandMenu("Navigate") {
            Button("Search") { navigationAction?(.search) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Home") { navigationAction?(.home) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Library") { navigationAction?(.library) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Downloads") { navigationAction?(.downloads) }
                .keyboardShortcut("3", modifiers: .command)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { navigationAction?(.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }

    }
}

private struct MacNavigationActionKey: FocusedValueKey {
    typealias Value = (MacDestination) -> Void
}

extension FocusedValues {
    var macNavigationAction: ((MacDestination) -> Void)? {
        get { self[MacNavigationActionKey.self] }
        set { self[MacNavigationActionKey.self] = newValue }
    }
}

extension Notification.Name {
    static let macOpenMedia = Notification.Name("EclipseMacOpenMedia")
    static let macOpenScheduleNotification = Notification.Name("EclipseMacOpenScheduleNotification")
}
