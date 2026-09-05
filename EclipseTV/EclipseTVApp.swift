import SwiftUI
import UIKit

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

    private static var isUITestHarness: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-UITestingPlayerHarness")
#else
        false
#endif
    }

    private static var isUITestRun: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-UITesting")
#else
        false
#endif
    }

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
                        .ignoresSafeArea()
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
                .toggleStyle(TVOnOffToggleStyle())
                .overlay(alignment: .bottom) {
                    if trackerManager.traktDeviceSignIn.authenticationID != nil,
                       trackerManager.traktDeviceSignIn.presentation == nil {
                        HStack(spacing: 14) {
                            ProgressView()
                            Text("Requesting Trakt sign-in code…")
                                .font(.system(size: 24, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.bottom, 36)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("tv.trakt.requestingCode")
                    }
                }
                .sheet(item: Binding(
                    get: { trackerManager.traktDeviceSignIn.presentation },
                    set: { _ in }
                )) { presentation in
                    TVTraktSignInView(presentation: presentation, trackerManager: trackerManager)
                        .onDisappear {
                            trackerManager.cancelTVTrackerSignIn(authenticationID: presentation.id)
                        }
                }
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
    func makeUIViewController(context: Context) -> TVPlayerUITestHostController {
        let request = PlaybackRequest(
            url: playbackURL,
            title: "Player Remote Test",
            subtitle: "Control overlay",
            isAnimation: isAnimationFixture
        )
        return TVPlayerUITestHostController(
            request: request,
            startsPlaybackAutomatically: playbackURL.path != "/dev/null"
        )
    }

    private var isAnimationFixture: Bool {
#if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["ECLIPSE_TEST_ANIMATION"] == "1"
#else
        false
#endif
    }

    private var playbackURL: URL {
#if DEBUG && targetEnvironment(simulator)
        if let name = ProcessInfo.processInfo.environment["ECLIPSE_TEST_VIDEO_NAME"],
           !name.isEmpty,
           name == (name as NSString).lastPathComponent,
           let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let url = caches.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
#endif
        return URL(fileURLWithPath: "/dev/null")
    }

    func updateUIViewController(
        _ uiViewController: TVPlayerUITestHostController,
        context: Context
    ) {}
}

private final class TVPlayerUITestHostController: UIViewController {
    private let request: PlaybackRequest
    private let startsPlaybackAutomatically: Bool
    private var didPresentPlayer = false

    init(request: PlaybackRequest, startsPlaybackAutomatically: Bool) {
        self.request = request
        self.startsPlaybackAutomatically = startsPlaybackAutomatically
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let closedLabel = UILabel()
        closedLabel.text = "Player closed"
        closedLabel.textColor = .white
        closedLabel.font = .systemFont(ofSize: 32)
        closedLabel.accessibilityIdentifier = "tv.playerHarness.closed"
        closedLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closedLabel)
        NSLayoutConstraint.activate([
            closedLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            closedLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPresentPlayer else { return }
        didPresentPlayer = true
        let player = TVPlaybackViewController(request: request, requestedEngine: .mpv)
#if DEBUG
        player.startsPlaybackAutomatically = startsPlaybackAutomatically
#endif
        present(player, animated: false)
    }
}
