import SwiftUI

struct AppHubSuppressionPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {

    func hidesAppHub(_ hidden: Bool = true) -> some View {
        preference(key: AppHubSuppressionPreferenceKey.self, value: hidden)
    }
}

struct AppHubPresentation: ViewModifier {
    @Binding var showingSettings: Bool
    let isSuppressed: Bool

    let tvPlacementActive: Bool

    @State private var suppressedByScreen = false

    func body(content: Content) -> some View {
#if os(tvOS)
        content
            .overlay(alignment: .topTrailing) {
                if tvPlacementActive && !isSuppressed {
                    FloatingSettingsOverlay(showingSettings: $showingSettings)
                }
            }
#else
        content
            .onPreferenceChange(AppHubSuppressionPreferenceKey.self) { hidden in
                suppressedByScreen = hidden
            }
            .overlay {
                if !isSuppressed && !suppressedByScreen {
                    AppHubOverlay(showingSettings: $showingSettings)
                        .transition(.opacity)
                }
            }
#endif
    }
}

extension View {
    func appHub(
        showingSettings: Binding<Bool>,
        isSuppressed: Bool,
        tvPlacementActive: Bool
    ) -> some View {
        modifier(AppHubPresentation(
            showingSettings: showingSettings,
            isSuppressed: isSuppressed,
            tvPlacementActive: tvPlacementActive
        ))
    }
}

#if !os(tvOS)

struct AppHubAction: Identifiable {
    let id: String
    let systemImage: String
    let label: String

    var pulseTint: Color?

    let activate: (CGPoint) -> Void
}

enum AppHubMetrics {

    static let positionKey = "appHubHandlePosition"
    static let defaultPosition: Double = 0.45

    static var handleWidth: CGFloat { isIPad ? 10 : 7 }
    static var handleHeight: CGFloat { isIPad ? 64 : 44 }

    static let handleOverhang: CGFloat = 2
    static var hitWidth: CGFloat { isIPad ? 44 : 32 }
    static var hitHeight: CGFloat { isIPad ? 84 : 56 }

    static var buttonDiameter: CGFloat { isIPad ? 56 : 44 }
    static var buttonIconSize: CGFloat { isIPad ? 23 : 18 }
    static var buttonHitDiameter: CGFloat { buttonDiameter + 12 }
    static var fanRadius: CGFloat { isIPad ? 112 : 88 }

    static let fanStep: Double = 38

    static let trackTopInset: CGFloat = 56

    static let trackBottomInset: CGFloat = 120

    static let fanTopGuard: CGFloat = 120
    static let fanBottomGuard: CGFloat = 140

    static let restingOpacity: Double = 0.6
    static let idleOpacity: Double = 0.28
    static let idleDelay: UInt64 = 4_000_000_000
    static let expandedIdleDelay: UInt64 = 24_000_000_000
}

private struct AppHubActionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private enum AppHubDragIntent {
    case undecided
    case reposition
    case pull
}

struct AppHubOverlay: View {
    @Binding var showingSettings: Bool

    @AppStorage("showKanzen", store: .standard) private var showKanzen: Bool = false
    @AppStorage(ModeSwitchAnimationSettings.enabledKey) private var modeSwitchAnimationEnabled = ModeSwitchAnimationSettings.defaultEnabled
    @AppStorage(AppHubMetrics.positionKey, store: .standard) private var storedPosition: Double = AppHubMetrics.defaultPosition

    @EnvironmentObject private var modeSwitchTransitionCoordinator: ModeSwitchTransitionCoordinator
    @Environment(\.layoutDirection) private var layoutDirection

    @State private var isExpanded = false
    @State private var isIdle = false
    @State private var activatingActionID: String?
    @State private var actionFrames: [String: CGRect] = [:]
    @State private var dragTranslation: CGFloat = 0
    @State private var dragIntent: AppHubDragIntent = .undecided
    @State private var interactionToken = 0

    private var inwardSign: CGFloat {
        layoutDirection == .rightToLeft ? 1 : -1
    }

    private var actions: [AppHubAction] {
        [
            AppHubAction(
                id: "reader",
                systemImage: "book.fill",
                label: "Switch to Reader Mode",
                pulseTint: .orange,
                activate: { origin in switchToReaderMode(origin: origin) }
            ),
            AppHubAction(
                id: "settings",
                systemImage: "gear",
                label: "Settings",
                activate: { _ in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        showingSettings = true
                    }
                }
            )
        ]
    }

    var body: some View {
        GeometryReader { proxy in
            let track = handleTrack(in: proxy)
            let handleY = resolvedHandleY(in: track)
            let anchor = fanAnchor(handleY: handleY, in: proxy)
            let items = actions

            ZStack(alignment: .topLeading) {
                Color.clear
                    .allowsHitTesting(false)

                scrim

                ForEach(Array(items.enumerated()), id: \.element.id) { index, action in
                    actionButton(action, index: index, count: items.count, anchor: anchor)
                }

                handle(centerY: handleY, in: proxy, track: track)
            }
        }
        .onPreferenceChange(AppHubActionFramePreferenceKey.self) { frames in
            actionFrames = frames
        }
        .task(id: interactionToken) {
            let delay = isExpanded ? AppHubMetrics.expandedIdleDelay : AppHubMetrics.idleDelay
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            guard dragIntent == .undecided, activatingActionID == nil else { return }
            withAnimation(.easeOut(duration: 0.5)) {
                isIdle = true
                isExpanded = false
            }
        }
    }

    private var scrim: some View {
        Color.black
            .opacity(isExpanded ? 0.28 : 0)
            .ignoresSafeArea()
            .allowsHitTesting(isExpanded)
            .onTapGesture { collapse() }
            .animation(.easeOut(duration: 0.22), value: isExpanded)
    }

    private func handle(centerY: CGFloat, in proxy: GeometryProxy, track: ClosedRange<CGFloat>) -> some View {
        let x = layoutDirection == .rightToLeft
            ? AppHubMetrics.hitWidth / 2
            : proxy.size.width - AppHubMetrics.hitWidth / 2

        return Capsule(style: .continuous)
            .fill(Color.white.opacity(0.92))
            .frame(width: AppHubMetrics.handleWidth, height: AppHubMetrics.handleHeight)
            .offset(x: -inwardSign * AppHubMetrics.handleOverhang)

            .shadow(color: .black.opacity(0.5), radius: 1.5, x: 0, y: 0)
            .shadow(color: .black.opacity(0.35), radius: 8, x: inwardSign * 3, y: 0)
            .opacity(handleOpacity)
            .scaleEffect(y: isExpanded ? 0.55 : 1)
            .frame(width: AppHubMetrics.hitWidth, height: AppHubMetrics.hitHeight, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture { toggleExpansion() }
            .simultaneousGesture(dragGesture(track: track))
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Quick Actions")
            .accessibilityHint("Opens mode and settings shortcuts. Drag to move.")
            .animation(.easeOut(duration: 0.28), value: isIdle)
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: isExpanded)
            .position(x: x, y: centerY)
    }

    private func actionButton(
        _ action: AppHubAction,
        index: Int,
        count: Int,
        anchor: CGPoint
    ) -> some View {
        let offset = fanOffset(index: index, count: count)
        let isActivating = activatingActionID == action.id

        return Button {
            activate(action)
        } label: {
            ZStack {
                if let tint = action.pulseTint {
                    ModeSwitchButtonPulse(isActive: isActivating, tint: tint)
                }

                Image(systemName: action.systemImage)
                    .font(.system(size: AppHubMetrics.buttonIconSize, weight: .semibold))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(isActivating ? -12 : 0))
                    .scaleEffect(isActivating ? 1.16 : 1)
            }
            .frame(width: AppHubMetrics.buttonDiameter, height: AppHubMetrics.buttonDiameter)
            .applyLiquidGlassBackground(cornerRadius: AppHubMetrics.buttonDiameter / 2)
            .scaleEffect(isActivating ? 0.94 : 1)
            .frame(width: AppHubMetrics.buttonHitDiameter, height: AppHubMetrics.buttonHitDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AppHubActionFramePreferenceKey.self,
                    value: [action.id: proxy.frame(in: .named(ModeSwitchTransitionCoordinator.coordinateSpaceName))]
                )
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        .accessibilityLabel(action.label)
        .scaleEffect(isExpanded ? 1 : 0.3)
        .opacity(isExpanded ? 1 : 0)
        .allowsHitTesting(isExpanded)
        .animation(
            .spring(response: 0.34, dampingFraction: 0.76).delay(Double(index) * 0.035),
            value: isExpanded
        )
        .position(
            x: anchor.x + (isExpanded ? offset.width : 0),
            y: anchor.y + (isExpanded ? offset.height : 0)
        )
    }

    private func handleTrack(in proxy: GeometryProxy) -> ClosedRange<CGFloat> {
        let midpoint = proxy.size.height / 2
        let lower = min(proxy.safeAreaInsets.top + AppHubMetrics.trackTopInset, midpoint)
        let upper = max(proxy.size.height - AppHubMetrics.trackBottomInset, midpoint)
        return lower...upper
    }

    private func resolvedHandleY(in track: ClosedRange<CGFloat>) -> CGFloat {
        let span = track.upperBound - track.lowerBound
        let base = track.lowerBound + CGFloat(storedPosition.clampedToUnitInterval) * span
        return min(max(base + dragTranslation, track.lowerBound), track.upperBound)
    }

    private func fanAnchor(handleY: CGFloat, in proxy: GeometryProxy) -> CGPoint {
        let midpoint = proxy.size.height / 2
        let lower = min(AppHubMetrics.fanTopGuard, midpoint)
        let upper = max(proxy.size.height - AppHubMetrics.fanBottomGuard, midpoint)
        let x = layoutDirection == .rightToLeft
            ? AppHubMetrics.hitWidth / 2
            : proxy.size.width - AppHubMetrics.hitWidth / 2
        return CGPoint(x: x, y: min(max(handleY, lower), upper))
    }

    private func fanOffset(index: Int, count: Int) -> CGSize {
        guard count > 0 else { return .zero }
        let middle = Double(count - 1) / 2
        let angle = (Double(index) - middle) * AppHubMetrics.fanStep * .pi / 180
        return CGSize(
            width: inwardSign * AppHubMetrics.fanRadius * CGFloat(cos(angle)),
            height: AppHubMetrics.fanRadius * CGFloat(sin(angle))
        )
    }

    private var handleOpacity: Double {
        if isExpanded { return 1 }
        return isIdle ? AppHubMetrics.idleOpacity : AppHubMetrics.restingOpacity
    }

    private func dragGesture(track: ClosedRange<CGFloat>) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                wake()

                if dragIntent == .undecided {
                    let horizontal = value.translation.width * inwardSign
                    if horizontal > 10, abs(value.translation.width) > abs(value.translation.height) {
                        dragIntent = .pull
                        interactionToken &+= 1
                        if !isExpanded { expand() }
                    } else if abs(value.translation.height) >= 6 {
                        dragIntent = .reposition
                        interactionToken &+= 1
                    }
                }

                if dragIntent == .reposition, !isExpanded {
                    dragTranslation = value.translation.height
                }
            }
            .onEnded { _ in
                if dragIntent == .reposition {
                    commitPosition(track: track)
                }
                dragIntent = .undecided
                dragTranslation = 0
                interactionToken &+= 1
            }
    }

    private func commitPosition(track: ClosedRange<CGFloat>) {
        let span = track.upperBound - track.lowerBound
        guard span > 0 else { return }
        let resolved = resolvedHandleY(in: track)
        storedPosition = Double((resolved - track.lowerBound) / span).clampedToUnitInterval
    }

    private func toggleExpansion() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    private func expand() {
        wake()
        interactionToken &+= 1
#if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
        withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
            isExpanded = true
        }
    }

    private func collapse() {
        interactionToken &+= 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            isExpanded = false
        }
    }

    private func wake() {
        guard isIdle else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            isIdle = false
        }
    }

    private func activate(_ action: AppHubAction) {
        guard activatingActionID == nil else { return }
        wake()
        interactionToken &+= 1

        let frame = actionFrames[action.id]
        let origin = frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero

        if action.pulseTint != nil {

            withAnimation(.spring(response: 0.28, dampingFraction: 0.58)) {
                activatingActionID = action.id
            }
        } else {
            collapse()
        }

        action.activate(origin)
    }

    private func switchToReaderMode(origin: CGPoint) {
        guard !showKanzen else { return }

        guard modeSwitchAnimationEnabled else {
            showKanzen = true
            return
        }

        if origin != .zero {
            modeSwitchTransitionCoordinator.record(origin: origin)
        }
        modeSwitchTransitionCoordinator.beginBurst(toReaderMode: true)

#if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation(.timingCurve(0.2, 0.75, 0.25, 1, duration: 0.82)) {
                showKanzen = true
            }
        }
    }
}

private extension Double {
    var clampedToUnitInterval: Double {
        guard isFinite else { return AppHubMetrics.defaultPosition }
        return Swift.min(Swift.max(self, 0), 1)
    }
}

#endif
