import SwiftUI

@main
struct EclipseTVApp: App {
    @StateObject private var theme = EclipseTheme.shared
    @StateObject private var localization = LocalizationManager.shared
    @StateObject private var profileManager = ProfileManager.shared
    @StateObject private var trackerManager = TrackerManager.shared

    @State private var showOnboarding: Bool
    @State private var showProfilePicker = false
    @State private var didEvaluateLaunchPicker = false
    @State private var launchUnlockProfile: Profile?
    @State private var cloudKitUpgradeNoticePending = false
    @State private var showCloudKitUpgradeNotice = false

    private static let isUITestHarness = ProcessInfo.processInfo.arguments
        .contains("-UITestingPlayerHarness")

    private static let isUITestRun = ProcessInfo.processInfo.arguments
        .contains("-UITesting")

    init() {
        OnboardingState.bootstrapIfNeeded()
        _ = LocalizationManager.shared
        CrashReportManager.shared.start()
        ExperimentalFeatureState.configureLaunchState()

        DispatchQueue.global(qos: .utility).async {
            CacheManager.shared.checkAndAutoClearIfNeeded()
        }

        MediaStateSyncBootstrap.startIfAvailable()

        let completed = UserDefaults.standard.bool(forKey: OnboardingState.completedKey)
        _showOnboarding = State(initialValue: !completed && !Self.isUITestHarness && !Self.isUITestRun)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showOnboarding {
                    OnboardingView {
                        showOnboarding = false
                        presentCloudKitUpgradeNoticeIfReady()
                        trackerManager.checkForExpiredTrackerSessions()
                    }
                } else if Self.isUITestHarness {
                    TVPlayerUITestHarness()
                } else if showProfilePicker {
                    ProfilePickerView(autoUnlockProfile: launchUnlockProfile) {
                        showProfilePicker = false
                        presentCloudKitUpgradeNoticeIfReady()
                        trackerManager.checkForExpiredTrackerSessions()
                    }
                    .ignoresSafeArea()
                } else {
                    TVRootView()
                }
            }
                .onAppear {
                    guard !didEvaluateLaunchPicker else { return }
                    didEvaluateLaunchPicker = true
                    showProfilePicker = !showOnboarding
                        && !Self.isUITestHarness
                        && !Self.isUITestRun
                        && ProfileManager.shared.shouldPresentLaunchPicker
                    launchUnlockProfile = ProfileManager.shared.launchProfileRequiringUnlock
                    cloudKitUpgradeNoticePending =
                        MediaStateSyncBootstrap.prepareCloudKitUpgradeNoticeIfNeeded()
                    presentCloudKitUpgradeNoticeIfReady()
                    if !showOnboarding,
                       !showProfilePicker,
                       !Self.isUITestHarness,
                       !Self.isUITestRun {
                        trackerManager.checkForExpiredTrackerSessions()
                    }
                }
                .defaultAppStorage(ProfileSettingsStore.shared.store(for: profileManager.activeProfileID))
                .environmentObject(theme)
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
                .environment(\.layoutDirection, localization.layoutDirection)
                .preferredColorScheme(.dark)
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
                    Text("Earlier versions of Eclipse automatically synced your library and watch progress through iCloud on this Apple TV. That sync is now off, and no data was deleted. You can keep it off or explicitly resume syncing.")
                }
        }
    }

    private func presentCloudKitUpgradeNoticeIfReady() {
        guard cloudKitUpgradeNoticePending,
              !showOnboarding,
              !showProfilePicker,
              !Self.isUITestHarness,
              !Self.isUITestRun else { return }
        cloudKitUpgradeNoticePending = false
        showCloudKitUpgradeNotice = true
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
