import SwiftUI
#if !os(tvOS)
import Nuke
#endif

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
        if identifier == "app.eclipse.soupy.downloads" {
            DownloadManager.shared.backgroundCompletionHandler = completionHandler
        }
    }
}

@main
struct SoraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = Settings()
    @StateObject private var theme = EclipseTheme.shared
    @StateObject private var moduleManager = ModuleManager.shared
    @StateObject private var favouriteManager = FavouriteManager.shared
    @StateObject private var localization = LocalizationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var startupReady = false
    @State private var startupFallbackScheduled = false
    @State private var showSplash = true
    @AppStorage("hideSplashScreen") private var hideSplashScreen = false
    private let startupFallbackDelay: TimeInterval = 20

#if !os(tvOS)
    @AppStorage("showKanzen") private var showKanzen: Bool = false
    @AppStorage(ModeSwitchAnimationSettings.enabledKey) private var modeSwitchAnimationEnabled = ModeSwitchAnimationSettings.defaultEnabled
    @State private var modeSwitchBurst: AppModeSwitchBurst?
#endif

    init() {
        _ = LocalizationManager.shared
        CrashReportManager.shared.start()
        GitHubReleaseChecker.registerDefaults()
        ExperimentalFeatureState.configureLaunchState()
#if !os(tvOS)
        ReaderImagePipelineConfigurator.configureIfNeeded()
#endif

        DispatchQueue.global(qos: .background).async {
            CacheManager.shared.checkAndAutoClearIfNeeded()
        }
        _ = DownloadManager.shared
#if !os(tvOS)
        Task { @MainActor in
            _ = ReaderDownloadManager.shared
        }
#endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
#if os(tvOS)
                ContentView(onStartupReady: markStartupReady)
                    .onAppear { scheduleStartupFallback() }
#else
                if showKanzen {
                    KanzenMenu(onStartupReady: markStartupReady)
                        .environmentObject(settings)
                        .environmentObject(theme)
                        .environmentObject(moduleManager)
                        .environmentObject(favouriteManager)
                        .environment(\.managedObjectContext, favouriteManager.container.viewContext)
                        .accentColor(settings.effectiveAccentColor)
                        .onAppear { scheduleStartupFallback() }
                        .transition(modeSwitchTransition(isReaderMode: true))
                } else {
                    Group {
                        if ExperimentalFeatureState.isEnabledAtLaunch {
                            ExperimentalContentView(onStartupReady: markStartupReady)
                                .environmentObject(theme)
                                .onAppear { scheduleStartupFallback() }
                        } else {
                            ContentView(onStartupReady: markStartupReady)
                                .environmentObject(theme)
                                .onAppear { scheduleStartupFallback() }
                        }
                    }
                    .transition(modeSwitchTransition(isReaderMode: false))
                }

                if modeSwitchAnimationEnabled, let modeSwitchBurst {
                    AppModeSwitchBurstOverlay(burst: modeSwitchBurst)
                        .id(modeSwitchBurst.id)
                        .allowsHitTesting(false)
                        .zIndex(2)
                }
#endif

                if showSplash && !hideSplashScreen {
                    SplashScreenView(isFinished: $startupReady) {
                        showSplash = false
                    }
                        .ignoresSafeArea()
                        .zIndex(3)
                }
            }
            .environment(\.locale, localization.locale)
            .environment(\.layoutDirection, localization.layoutDirection)
            .environmentObject(localization)
#if !os(tvOS)
            .animation(modeSwitchAnimationEnabled ? .spring(response: 0.72, dampingFraction: 0.82, blendDuration: 0.08) : nil, value: showKanzen)
            .onChange(of: showKanzen) { newValue in
                beginModeSwitchBurst(toReaderMode: newValue)
            }
            .onChange(of: modeSwitchAnimationEnabled) { isEnabled in
                if !isEnabled {
                    modeSwitchBurst = nil
                }
            }
#endif
#if os(iOS)
            .onAppear {
                ExperimentalCloudSyncManager.shared.syncOnActivationIfNeeded(reason: "launch")
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    ExperimentalCloudSyncManager.shared.syncOnActivationIfNeeded(reason: "active")
                }
            }
#endif
        }
    }

#if !os(tvOS)
    private func modeSwitchTransition(isReaderMode: Bool) -> AnyTransition {
        modeSwitchAnimationEnabled ? .eclipseModeScene(isReaderMode: isReaderMode) : .identity
    }

    private func beginModeSwitchBurst(toReaderMode: Bool) {
        guard modeSwitchAnimationEnabled else {
            modeSwitchBurst = nil
            return
        }

        let burst = AppModeSwitchBurst(toReaderMode: toReaderMode)
        modeSwitchBurst = burst

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
            if modeSwitchBurst?.id == burst.id {
                modeSwitchBurst = nil
            }
        }
    }
#endif

    private func markStartupReady() {
        guard !startupReady else { return }
        startupReady = true
    }

    private func scheduleStartupFallback() {
        guard !startupFallbackScheduled else { return }
        startupFallbackScheduled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + startupFallbackDelay) {
            markStartupReady()
        }
    }
}

#if !os(tvOS)
private struct AppModeSwitchBurst: Identifiable, Equatable {
    let id = UUID()
    let toReaderMode: Bool
}

private struct AppModeSwitchBurstOverlay: View {
    let burst: AppModeSwitchBurst

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bloomScale: CGFloat = 0.04
    @State private var bloomOpacity: Double = 0
    @State private var ringScale: CGFloat = 0.25
    @State private var ringOpacity: Double = 0
    @State private var iconScale: CGFloat = 0.55
    @State private var iconOpacity: Double = 0
    @State private var sparkProgress: CGFloat = 0

    private var primaryColor: Color {
        burst.toReaderMode ? Color.orange : Color.cyan
    }

    private var secondaryColor: Color {
        burst.toReaderMode ? Color.pink : Color.blue
    }

    private var iconName: String {
        burst.toReaderMode ? "book.fill" : "play.rectangle.fill"
    }

    var body: some View {
        GeometryReader { proxy in
            let buttonCenter = CGPoint(x: proxy.size.width - 38, y: 58)
            let diameter = sqrt(proxy.size.width * proxy.size.width + proxy.size.height * proxy.size.height) * 2.2

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                primaryColor.opacity(0.46),
                                secondaryColor.opacity(0.24),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: diameter * 0.5
                        )
                    )
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(bloomScale)
                    .opacity(bloomOpacity)
                    .position(buttonCenter)
                    .blendMode(.screen)

                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.92), primaryColor.opacity(0.45), Color.clear],
                            startPoint: .topTrailing,
                            endPoint: .bottomLeading
                        ),
                        lineWidth: 2
                    )
                    .frame(width: 86, height: 86)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
                    .position(buttonCenter)
                    .blur(radius: ringOpacity > 0 ? CGFloat(0) : CGFloat(4))

                ForEach(0..<12, id: \.self) { index in
                    AppModeSwitchSpark(
                        index: index,
                        progress: sparkProgress,
                        primaryColor: primaryColor,
                        secondaryColor: secondaryColor
                    )
                    .position(buttonCenter)
                }

                Image(systemName: iconName)
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                            )
                    )
                    .shadow(color: primaryColor.opacity(0.48), radius: 18, x: 0, y: 8)
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)
                    .rotationEffect(.degrees(burst.toReaderMode ? -10 : 10))
                    .position(buttonCenter)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .onAppear(perform: animate)
    }

    private func animate() {
        if reduceMotion {
            bloomScale = 1
            bloomOpacity = 0.16
            ringScale = 1
            ringOpacity = 0
            iconScale = 1
            iconOpacity = 0
            sparkProgress = 1
            return
        }

        withAnimation(.easeOut(duration: 0.42)) {
            bloomScale = 1
            bloomOpacity = 0.72
        }

        withAnimation(.easeOut(duration: 0.58).delay(0.08)) {
            bloomOpacity = 0
        }

        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
            ringScale = 1.85
            ringOpacity = 0.9
            iconScale = 1.08
            iconOpacity = 1
        }

        withAnimation(.easeOut(duration: 0.52).delay(0.12)) {
            ringOpacity = 0
            iconScale = 1.55
            iconOpacity = 0
            sparkProgress = 1
        }
    }
}

private struct AppModeSwitchSpark: View {
    let index: Int
    let progress: CGFloat
    let primaryColor: Color
    let secondaryColor: Color

    private var angle: Double {
        Double(index) * 30 - 158
    }

    var body: some View {
        let radians = angle * .pi / 180
        let distance = 34 + progress * CGFloat(132 + (index % 4) * 18)
        let x = CGFloat(cos(radians)) * distance
        let y = CGFloat(sin(radians)) * distance

        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.95),
                        (index.isMultiple(of: 2) ? primaryColor : secondaryColor).opacity(0.82),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: 14 + progress * 42, height: 3)
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: y)
            .scaleEffect(1 - progress * 0.25)
            .opacity(Double(max(0, 1 - progress)))
            .blendMode(.screen)
    }
}

private struct AppModeSceneTransitionModifier: ViewModifier {
    let progress: CGFloat
    let direction: CGFloat
    let entering: Bool

    func body(content: Content) -> some View {
        content
            .opacity(Double(entering ? 1 - progress * 0.22 : 1 - progress * 0.55))
            .scaleEffect(entering ? 1 + progress * 0.035 : 1 - progress * 0.045, anchor: .topTrailing)
            .rotation3DEffect(
                .degrees(Double(direction * progress * (entering ? 9 : -7))),
                axis: (x: 0.12, y: 1, z: 0.04),
                anchor: .topTrailing,
                perspective: 0.72
            )
            .offset(
                x: direction * progress * (entering ? 58 : -34),
                y: progress * (entering ? -10 : 16)
            )
            .blur(radius: progress * (entering ? 7 : 12))
    }
}

private extension AnyTransition {
    static func eclipseModeScene(isReaderMode: Bool) -> AnyTransition {
        let direction: CGFloat = isReaderMode ? 1 : -1

        return .asymmetric(
            insertion: .modifier(
                active: AppModeSceneTransitionModifier(progress: 1, direction: direction, entering: true),
                identity: AppModeSceneTransitionModifier(progress: 0, direction: direction, entering: true)
            ),
            removal: .modifier(
                active: AppModeSceneTransitionModifier(progress: 1, direction: -direction, entering: false),
                identity: AppModeSceneTransitionModifier(progress: 0, direction: -direction, entering: false)
            )
        )
    }
}

private enum ReaderImagePipelineConfigurator {
    private static var didConfigure = false

    static func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        DataLoader.sharedUrlCache.diskCapacity = 0
        DataLoader.sharedUrlCache.memoryCapacity = 0

        let pipeline = ImagePipeline {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil

            let dataCache = try? DataCache(name: "app.eclipse.soupy.reader.datacache")
            dataCache?.sizeLimit = 500 * 1024 * 1024

            let imageCache = Nuke.ImageCache()
            imageCache.costLimit = 100 * 1024 * 1024

            $0.dataCache = dataCache
            $0.imageCache = imageCache
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.dataCachePolicy = .storeOriginalData
            $0.isStoringPreviewsInMemoryCache = false
        }

        ImagePipeline.shared = pipeline
        ReaderLogger.shared.log("Configured reader image pipeline cache data=500MB image=100MB", type: "ReaderPerf")
    }
}
#endif
