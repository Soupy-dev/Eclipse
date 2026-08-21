//
//  MainMenu.swift
//  Eclipse
//
//  Created by Dawud Osman on 17/11/2025.
//

import SwiftUI

#if !os(tvOS)
enum KanzenRootTab: Hashable {
    case home
    case library
    case search
    case history
    case settings
}

struct KanzenModeSwitchButton: View {
    @AppStorage("showKanzen", store: .standard) private var showKanzen: Bool = false
    @AppStorage(ModeSwitchAnimationSettings.enabledKey) private var modeSwitchAnimationEnabled = ModeSwitchAnimationSettings.defaultEnabled
    @EnvironmentObject private var modeSwitchTransitionCoordinator: ModeSwitchTransitionCoordinator
    @State private var isLaunching = false
    @State private var buttonFrame: CGRect = .zero

    var body: some View {
        Button {
            switchToMediaMode()
        } label: {
            if ExperimentalFeatureState.isEnabledAtLaunch {
                ZStack {
                    ModeSwitchButtonPulse(isActive: isLaunching, tint: .cyan)

                    Image(systemName: "play.rectangle.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.white)
                        .rotationEffect(.degrees(isLaunching ? 10 : 0))
                        .scaleEffect(isLaunching ? 1.14 : 1)
                }
                .frame(width: 42, height: 42)
                .applyLiquidGlassBackground(
                    cornerRadius: 21,
                    glassTint: Color.white.opacity(0.04)
                )
                .scaleEffect(isLaunching ? 0.94 : 1)
            } else {
                ZStack {
                    ModeSwitchButtonPulse(isActive: isLaunching, tint: .cyan)

                    Image(systemName: "play.rectangle.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.white)
                        .rotationEffect(.degrees(isLaunching ? 10 : 0))
                        .scaleEffect(isLaunching ? 1.14 : 1)
                }
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .scaleEffect(isLaunching ? 0.94 : 1)
            }
        }
        .buttonStyle(.plain)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ModeSwitchButtonOriginPreferenceKey.self,
                    value: proxy.frame(in: .named(ModeSwitchTransitionCoordinator.coordinateSpaceName))
                )
            }
        }
        .onPreferenceChange(ModeSwitchButtonOriginPreferenceKey.self) { frame in
            buttonFrame = frame
        }
        .accessibilityLabel("Switch to Media Mode")
    }

    private func switchToMediaMode() {
        guard showKanzen, !isLaunching else { return }

        guard modeSwitchAnimationEnabled else {
            showKanzen = false
            return
        }

        recordSwitchOrigin()
        modeSwitchTransitionCoordinator.beginBurst(toReaderMode: false)

#if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif

        withAnimation(.spring(response: 0.28, dampingFraction: 0.58)) {
            isLaunching = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation(.timingCurve(0.2, 0.75, 0.25, 1, duration: 0.82)) {
                showKanzen = false
            }
        }
    }

    private func recordSwitchOrigin() {
        guard buttonFrame != .zero else { return }
        modeSwitchTransitionCoordinator.record(
            origin: CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        )
    }
}

struct KanzenRootHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(ExperimentalFeatureState.isEnabledAtLaunch ? .system(size: isIPad ? 42 : 34, weight: .heavy) : .largeTitle)
                .fontWeight(ExperimentalFeatureState.isEnabledAtLaunch ? .heavy : .bold)
                .foregroundColor(ExperimentalFeatureState.isEnabledAtLaunch ? .white : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer()

            trailing()

            KanzenModeSwitchButton()
        }
        .padding(.horizontal, 20)
        .padding(.top, ExperimentalFeatureState.isEnabledAtLaunch ? 16 : 10)
        .padding(.bottom, ExperimentalFeatureState.isEnabledAtLaunch ? 8 : 2)
    }
}

extension KanzenRootHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = { EmptyView() }
    }
}

struct KanzenMenu: View {
    @StateObject private var kanzen = KanzenEngine()
    private let onStartupReady: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var moduleManager: ModuleManager
    @StateObject private var readerExtensionManager = ReaderExtensionManager.shared
    @StateObject private var readerDownloadManager = ReaderDownloadManager.shared
    @State private var selectedTab: KanzenRootTab = .home

    init(onStartupReady: @escaping () -> Void = {}) {
        self.onStartupReady = onStartupReady
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
        TabView(selection: $selectedTab) {
            KanzenHomeView(onStartupReady: onStartupReady)
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(KanzenRootTab.home)

            KanzenLibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
                .tag(KanzenRootTab.library)

            KanzenGlobalSearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(KanzenRootTab.search)

            KanzenHistoryView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }
                .tag(KanzenRootTab.history)

            KanzenSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(KanzenRootTab.settings)
        }
        .environmentObject(kanzen)
        .kanzenAidokuMigrationPrompt()
        .task {
            await moduleManager.autoUpdateModulesIfNeeded()
            await readerExtensionManager.autoUpdateInstalledSourcesIfNeeded(reason: "reader-open")
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                Task {
                    await moduleManager.autoUpdateModulesIfNeeded()
                    await readerExtensionManager.autoUpdateInstalledSourcesIfNeeded(reason: "reader-active")
                }
            }
        }
        .alert("Reader Download Not Added", isPresented: Binding(
            get: { readerDownloadManager.enqueueErrorMessage != nil },
            set: { isPresented in
                if !isPresented { readerDownloadManager.clearEnqueueError() }
            }
        )) {
            Button("OK") {
                readerDownloadManager.clearEnqueueError()
            }
        } message: {
            Text(readerDownloadManager.enqueueErrorMessage ?? "The download could not be added safely.")
        }
    }
}

#endif
