import SwiftUI

@main
struct EclipseTVApp: App {
    @StateObject private var theme = EclipseTheme.shared
    @StateObject private var localization = LocalizationManager.shared

    init() {
        _ = LocalizationManager.shared
        CrashReportManager.shared.start()
        ExperimentalFeatureState.configureLaunchState()

        // tvOS treats everything outside UserDefaults as purgeable. Keep the
        // bounded media cache tidy without instantiating the download stack.
        DispatchQueue.global(qos: .utility).async {
            CacheManager.shared.checkAndAutoClearIfNeeded()
        }

        MediaStateSyncBootstrap.startIfAvailable()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("-UITestingPlayerHarness") {
                    TVPlayerUITestHarness()
                } else {
                    TVRootView()
                }
            }
                .environmentObject(theme)
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
                .environment(\.layoutDirection, localization.layoutDirection)
                .preferredColorScheme(.dark)
        }
    }
}

private struct TVPlayerUITestHarness: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TVMPVPlayerViewController {
        let request = PlaybackRequest(
            url: URL(fileURLWithPath: "/dev/null"),
            title: "Player Remote Test",
            subtitle: "Control overlay"
        )
        return TVMPVPlayerViewController(request: request)
    }

    func updateUIViewController(
        _ uiViewController: TVMPVPlayerViewController,
        context: Context
    ) {}
}
