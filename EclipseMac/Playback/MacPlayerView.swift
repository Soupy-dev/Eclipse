#if os(macOS)
import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MacPlaybackSurfaceView: NSView {
    let gpuView = NSView()
    let playerLayer = AVPlayerLayer()
    private let avView = NSView()
    private let pictureInPictureView = NSView()
    private var pictureInPictureLayer: AVSampleBufferDisplayLayer?
    private var pictureInPictureOwnsLayerGeometry = false
    var videoPresentationSize = CGSize(width: 16, height: 9) {
        didSet { if oldValue != videoPresentationSize { needsLayout = true } }
    }
    var onGeometryChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        gpuView.wantsLayer = true
        avView.wantsLayer = true
        avView.layer = playerLayer
        pictureInPictureView.wantsLayer = true
        addSubview(pictureInPictureView)
        addSubview(gpuView)
        addSubview(avView)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { nil }

    func showMPV() {
        gpuView.isHidden = false
        avView.isHidden = true
    }

    func showAVPlayer(_ player: AVPlayer) {
        playerLayer.player = player
        gpuView.isHidden = true
        avView.isHidden = false
    }

    func installPictureInPictureLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        pictureInPictureLayer?.removeFromSuperlayer()
        pictureInPictureLayer = displayLayer
        pictureInPictureView.layer?.addSublayer(displayLayer)
        displayLayer.videoGravity = .resizeAspect
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func setPictureInPictureOwnsLayerGeometry(_ ownsGeometry: Bool) {
        guard pictureInPictureOwnsLayerGeometry != ownsGeometry else { return }
        if ownsGeometry { pictureInPictureLayer?.contentsScale = window?.backingScaleFactor ?? 1 }
        pictureInPictureOwnsLayerGeometry = ownsGeometry
        if !ownsGeometry {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        gpuView.frame = bounds
        avView.frame = bounds
        pictureInPictureView.frame = AVMakeRect(aspectRatio: videoPresentationSize, insideRect: bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !pictureInPictureOwnsLayerGeometry {
            pictureInPictureLayer?.contentsScale = window?.backingScaleFactor ?? 1
            pictureInPictureLayer?.frame = pictureInPictureView.bounds
        }
        CATransaction.commit()
        onGeometryChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
        layoutSubtreeIfNeeded()
        onGeometryChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        layoutSubtreeIfNeeded()
        onGeometryChange?()
    }
}

private struct MacPlaybackSurface: NSViewRepresentable {
    let session: MacPlaybackSession
    func makeNSView(context: Context) -> MacPlaybackSurfaceView { session.surface }
    func updateNSView(_ nsView: MacPlaybackSurfaceView, context: Context) {}
}

private struct MacAirPlayPicker: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        return view
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) { nsView.player = player }
}

struct MacPlayerView: View {
    @ObservedObject var session: MacPlaybackSession
    @ObservedObject private var accent = AccentColorManager.shared
    @State private var controlsVisible = true
    @State private var skinSettingsRevision: UInt64 = 0
    @State private var controlsTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var subtitlePicker = false
    @State private var showsSubtitleTiming = false
    @AppStorage("mpvPerformanceOverlayEnabled", store: ProfileSettingsStore.active) private var showsPerformance = false
    @AppStorage(ExperimentalFeatureState.mpvShowRemainingTimeKey, store: ProfileSettingsStore.active) private var showsRemainingTime = true
    @AppStorage(ExperimentalFeatureState.mpvPreciseProgressKey, store: ProfileSettingsStore.active) private var preciseProgress = true
    @AppStorage("mpvPictureInPictureEnabled", store: ProfileSettingsStore.active) private var pictureInPictureEnabled = true
    @AppStorage("showEpisodeBrowserButton", store: ProfileSettingsStore.active) private var episodeBrowserEnabled = true
    @AppStorage("showNextEpisodePosterButton", store: ProfileSettingsStore.active) private var nextEpisodePosterEnabled = false
    @State private var showsPlayerSettings = false
    @State private var showsEpisodes = false
    @State private var showsSources = false
    @State private var sourceEpisode: PlayerEpisodeBrowserItem?
    private enum FocusedSlider: Hashable { case position, volume }
    @FocusState private var focusedSlider: FocusedSlider?
    @State private var keyboardFocusRequest: UInt64 = 0
    @State private var hoveringControls = false
    @State private var availableWidth: CGFloat = 0

    private var skin: MacPlayerSkinAppearance {
        _ = skinSettingsRevision
        return MacPlayerSkinAppearance(engine: session.engine)
    }

    var body: some View {
        playerContent(availableWidth: availableWidth)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { availableWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in availableWidth = width }
                }
            }
            .clipped()
    }

    private func playerContent(availableWidth: CGFloat) -> some View {
        ZStack {
            Color.black
            MacPlaybackSurface(session: session)
            if session.isPictureInPicture {
                VStack(spacing: 16) {
                    Image(systemName: "pip.fill").font(.system(size: 36))
                    Text("Playing in Picture in Picture").font(.title3)
                    Button("Return to Eclipse") { session.togglePictureInPicture() }
                }
                .foregroundStyle(.white)
            }
            if !session.subtitleText.isEmpty, !session.isPictureInPicture {
                VStack {
                    Spacer()
                    MacSubtitleOverlay(text: session.subtitleText, appearance: PlayerSubtitleAppearance())
                        .padding(.horizontal, 12)
                        .padding(.vertical, PlayerSubtitleAppearance().captionBackground ? 6 : 0)
                        .background(PlayerSubtitleAppearance().captionBackground ? Color.black.opacity(0.75) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 32)
                        .padding(.bottom, max(4, (controlsVisible ? 110 : 36)
                            - (PlayerSubtitleAppearance().verticalOffset + 6) * 2.5))
                }
                .allowsHitTesting(false)
            }
            if controlsVisible || !session.isPlaying || session.errorMessage != nil {
                VStack {
                    topBar
                    Spacer()
                    if let error = session.errorMessage {
                        VStack(spacing: 14) {
                            Text("Playback stopped").font(.title2.bold())
                            Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                            if session.request.launchContext?.sourceKind != .skyStream {
                                Button("Try \(session.engine == .mpv ? "AVPlayer" : "MPV")") {
                                    session.retryWithAlternateEngine()
                                }
                            }
                        }
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                        .frame(maxWidth: 560)
                    }
                    Spacer()
                    if let notice = session.notice {
                        HStack {
                            Text(notice).font(.callout)
                            if session.pendingMPVSubtitle != nil {
                                Button("Play With MPV") { session.retryWithAlternateEngine() }
                            }
                            Button { session.notice = nil } label: { Image(systemName: "xmark") }
                        }
                        .padding(12).background(.ultraThinMaterial, in: Capsule())
                    }
                    HStack {
                        Spacer()
                        if let segment = session.activeSkipSegment {
                            Button(segment.type.displayLabel) { session.skipCurrentSegment() }
                                .buttonStyle(.borderedProminent)
                        } else if session.skip85SecondsAvailable {
                            Button("Skip 85 Seconds") { session.seek(by: 85) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    bottomBar(isCompact: availableWidth < 820)
                }
                .padding(20)
                .foregroundStyle(.white)
                .background(LinearGradient(colors: [.black.opacity(0.7), .clear, .black.opacity(0.7)],
                                           startPoint: .top, endPoint: .bottom))
            }
            if !session.isReady || session.isBuffering, session.errorMessage == nil { ProgressView().controlSize(.large) }
            if showsPerformance {
                VStack {
                    HStack {
                        Text(session.performanceText).font(.system(.caption, design: .monospaced))
                            .padding(12).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                        Spacer()
                    }
                    Spacer()
                }.padding(.top, 78).padding(.leading, 20).allowsHitTesting(false)
            }
        }
        .overlay {
            if showsEpisodes, let seed = session.episodeBrowserSeed {
                PlayerEpisodeBrowserDrawer(seed: seed, onClose: { showsEpisodes = false }, onEpisodeSelected: { episode in
                    showsEpisodes = false
                    if !session.selectEpisode(episode) {
                        sourceEpisode = episode
                        showsSources = true
                    }
                })
            }
        }
        .sheet(isPresented: $showsSources) { MacPlayerSourceSheet(session: session, episode: sourceEpisode) }
        .sheet(isPresented: $showsPlayerSettings) {
            NavigationStack {
                PlayerSettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsPlayerSettings = false } } }
            }.frame(minWidth: 660, minHeight: 560).profileScopedAppStorage()
        }
        .environment(\.colorScheme, .dark)
        .tint(skin.skin == .defaultSkin ? accent.currentAccentColor : skin.primary)
        .contentShape(Rectangle())
        .overlay(MacPlayerKeyboardCapture(isEnabled: {
            session.isCurrentOwner && MacPlaybackCoordinator.shared.session === session
                && !session.isPictureInPicture && !showsSources && !showsPlayerSettings && !showsEpisodes && !subtitlePicker && !showsSubtitleTiming
        }, focusRequest: keyboardFocusRequest,
            sliderIsFocused: { focusedSlider != nil }, onAction: handleKeyboardAction))
        .onAppear { keyboardFocusRequest &+= 1; revealControls() }
        .onChange(of: session.isPictureInPicture) { _, isPiP in
            focusedSlider = nil
            keyboardFocusRequest &+= 1
            if isPiP {
                showsSubtitleTiming = false
                controlsTask?.cancel()
            } else { revealControls() }
        }
        .onChange(of: showsSources || showsPlayerSettings || showsEpisodes || subtitlePicker || showsSubtitleTiming) { _, isPresenting in
            focusedSlider = nil
            keyboardFocusRequest &+= 1
        }
        .onChange(of: showsSubtitleTiming) { _, presented in
            session.setSubtitleTimingControlsPresented(presented)
            revealControls()
        }
        .onChange(of: session.engine) { _, engine in
            if engine != .mpv { showsSubtitleTiming = false }
        }
        .onDisappear {
            controlsTask?.cancel()
            focusedSlider = nil
            showsSubtitleTiming = false
            session.setSubtitleTimingControlsPresented(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            skinSettingsRevision &+= 1
        }
        .onChange(of: session.requestedSourceEpisode?.id) { _, _ in
            guard let episode = session.requestedSourceEpisode else { return }
            sourceEpisode = episode
            showsSources = true
        }
        .onContinuousHover { phase in if case .active = phase { revealControls() } }
        .onTapGesture(count: 2) { session.surface.window?.toggleFullScreen(nil) }
        .onTapGesture { focusedSlider = nil; keyboardFocusRequest &+= 1; revealControls() }
        .fileImporter(isPresented: $subtitlePicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { session.addSubtitle(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let subtitles = urls.filter { MacPlaybackFileTypes.subtitleExtensions.contains($0.pathExtension.lowercased()) }
            subtitles.forEach(session.addSubtitle)
            return !subtitles.isEmpty
        }
    }

    private func handleKeyboardAction(_ action: MacPlayerKeyAction) {
        switch action {
        case .togglePlayback: session.togglePlayback()
        case .seekBackward: session.seek(by: -session.seekStep)
        case .seekForward: session.seek(by: session.seekStep)
        case .volumeUp: session.setVolume(session.volume + 0.05)
        case .volumeDown: session.setVolume(session.volume - 0.05)
        case .escape:
            if session.surface.window?.styleMask.contains(.fullScreen) == true {
                session.surface.window?.toggleFullScreen(nil)
            } else { session.stop() }
        }
        revealControls()
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            control("Close player", symbol: "xmark") { session.stop() }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.request.title.isEmpty ? session.request.url.deletingPathExtension().lastPathComponent : session.request.title)
                    .font(.headline).lineLimit(1)
                if let subtitle = session.request.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
            Spacer(minLength: 0)
            if session.request.mediaInfo != nil {
                control("Watch Together", symbol: "person.2.fill") {
                    Task {
                        let result = await WatchTogetherCoordinator.shared.beginActivity()
                        if case .needsGroupSession = result { session.notice = "Start a FaceTime call to watch together." }
                        if case .unavailable(let message) = result { session.notice = message }
                    }
                }
            }
            if (pictureInPictureEnabled && session.supportsPictureInPicture) || session.isPictureInPicture {
                control("Picture in Picture", symbol: "pip") { session.togglePictureInPicture() }
            }
            control("Toggle full screen", symbol: "arrow.up.left.and.arrow.down.right") {
                session.surface.window?.toggleFullScreen(nil)
            }
        }
        .foregroundStyle(.white)
        .onHover(perform: controlsHoverChanged)
    }

    private func bottomBar(isCompact: Bool) -> some View {
        VStack(spacing: 12) {
            Slider(value: Binding(get: { isScrubbing ? scrubPosition : session.position },
                set: { scrubPosition = $0 }), in: 0...max(session.duration, 1),
                step: session.engine == .mpv && preciseProgress ? 0.1 : 1, onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { session.seek(to: scrubPosition) }
                })
                .accessibilityLabel("Playback position")
                .focused($focusedSlider, equals: .position)
            if isCompact {
                HStack(spacing: 16) { transportControls; Spacer(minLength: 0) }
                HStack(spacing: 16) { playbackMenus; Spacer(minLength: 0) }
                if session.showsNextEpisodeButton { HStack { Spacer(); nextEpisodeControl } }
            } else {
                HStack(spacing: 16) {
                    transportControls
                    Spacer(minLength: 0)
                    nextEpisodeControl
                    playbackMenus
                }
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        .onHover(perform: controlsHoverChanged)
        .background(MacPlayerSkinBackground(appearance: skin, isActive: controlsVisible && !session.isPictureInPicture))
    }

    @ViewBuilder
    private var transportControls: some View {
        control("Back \(session.seekStep.formatted()) seconds", symbol: seekSymbol(forward: false)) { session.seek(by: -session.seekStep) }
        control(session.isPlaying ? "Pause" : "Play", symbol: session.isPlaying ? "pause.fill" : "play.fill") {
            session.togglePlayback()
        }
        control("Forward \(session.seekStep.formatted()) seconds", symbol: seekSymbol(forward: true)) { session.seek(by: session.seekStep) }
        Text("\(time(isScrubbing ? scrubPosition : session.position)) / \(trailingTime)")
            .font(.system(.caption, design: .monospaced)).monospacedDigit().foregroundStyle(.white)
    }

    @ViewBuilder
    private var nextEpisodeControl: some View {
        if session.showsNextEpisodeButton, let next = session.nextEpisode {
            Button { session.playNextEpisode() } label: {
                HStack(spacing: 8) {
                    if nextEpisodePosterEnabled, let poster = next.posterURL.flatMap(URL.init(string:)) {
                        AsyncImage(url: poster) { image in image.resizable().scaledToFill() }
                            placeholder: { Color.white.opacity(0.1) }
                            .frame(width: 64, height: 36).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Label("S\(next.episode.seasonNumber) E\(next.episode.episodeNumber)", systemImage: "forward.end.fill")
                        if nextEpisodePosterEnabled { Text(next.episode.name).font(.caption).lineLimit(1) }
                    }
                }
            }.help("Play next episode").foregroundStyle(.white).frame(maxWidth: nextEpisodePosterEnabled ? 220 : nil)
        }
    }

    @ViewBuilder
    private var playbackMenus: some View {
        Menu {
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3], id: \.self) { value in
                Button("\(value.formatted())×") { session.setSpeed(value) }
            }
        } label: { Text("\(session.speed.formatted())×") }
            .menuStyle(.borderlessButton).foregroundStyle(.white).tint(.white).fixedSize().help("Playback speed")
        Menu {
            ForEach(session.audioTracks) { track in
                Button { session.selectAudio(track.id) } label: {
                    Label(track.title, systemImage: session.selectedAudioID == track.id ? "checkmark" : "speaker.wave.2")
                }
            }
        } label: { Image(systemName: "waveform") }
            .menuStyle(.borderlessButton).foregroundStyle(.white).tint(.white).fixedSize().help("Audio tracks")
        Menu {
            Button("Off") { session.selectSubtitle(-1) }
            ForEach(session.subtitleTracks) { track in
                Button { session.selectSubtitle(track.id) } label: {
                    Label(track.title, systemImage: session.selectedSubtitleID == track.id ? "checkmark" : "captions.bubble")
                }
            }
            Divider()
            if session.engine == .mpv {
                Button("Subtitle Delay · \(PlayerSubtitleTiming.label(session.subtitleDelaySeconds))…") {
                    session.setSubtitleTimingControlsPresented(true)
                    showsSubtitleTiming = true
                    revealControls()
                }
            }
            Button("Open Subtitle…") { subtitlePicker = true }
            Button(session.searchingOnlineSubtitles ? "Searching Online Subtitles…" : "Search Online Subtitles") {
                session.searchOnlineSubtitles()
            }.disabled(session.searchingOnlineSubtitles || session.request.mediaInfo == nil)
            if !session.onlineSubtitles.isEmpty {
                Menu("Online Subtitles") {
                    ForEach(session.onlineSubtitles) { subtitle in
                        Button(subtitle.title) { session.selectOnlineSubtitle(subtitle) }
                    }
                }
            }
        } label: { Image(systemName: "captions.bubble") }
            .menuStyle(.borderlessButton).foregroundStyle(.white).tint(.white).fixedSize().help("Subtitles")
            .popover(isPresented: $showsSubtitleTiming, arrowEdge: .bottom) {
                subtitleTimingControls
            }
        Image(systemName: session.volume == 0 ? "speaker.slash" : "speaker.wave.2")
        Slider(value: Binding(get: { session.volume }, set: session.setVolume), in: 0...1)
            .frame(width: 75).accessibilityLabel("Volume")
            .focused($focusedSlider, equals: .volume)
        if session.engine == .avPlayer {
            MacAirPlayPicker(player: session.player).frame(width: 26, height: 26).help("AirPlay")
        } else if session.request.launchContext?.sourceKind != .skyStream {
            Menu {
                Button("Use AVPlayer for AirPlay") { session.retryWithAlternateEngine() }
            } label: { Image(systemName: "airplay.video") }
                .menuStyle(.borderlessButton).foregroundStyle(.white).tint(.white).fixedSize().help("Use AVPlayer for AirPlay")
        }
        Menu {
            if episodeBrowserEnabled, session.episodeBrowserSeed != nil { Button("Browse Episodes") { showsEpisodes = true } }
            if PlayerServicesButtonSettings.isEnabled(), session.request.mediaInfo != nil {
                Button("Choose Another Source") { sourceEpisode = nil; showsSources = true }
            }
            if session.request.launchContext != nil {
                Button(session.isRefreshingSource ? "Refreshing Source…" : "Refresh Current Source") { session.refreshSource() }
                    .disabled(session.isRefreshingSource)
            }
            Button("Player Settings…") { showsPlayerSettings = true }
            Toggle("Playback Statistics", isOn: $showsPerformance)
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).foregroundStyle(.white).tint(.white).fixedSize().help("Player options")
    }

    private func seekSymbol(forward: Bool) -> String {
        let prefix = forward ? "goforward" : "gobackward"
        let seconds = Int(session.seekStep)
        return [5, 10, 15, 30, 45, 60].contains(seconds) ? "\(prefix).\(seconds)" : prefix
    }

    private func control(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 32, height: 32).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.white).help(title).accessibilityLabel(title)
    }

    private var subtitleTimingControls: some View {
        VStack(spacing: 16) {
            Text("Subtitle Delay").font(.headline)
            HStack(spacing: 20) {
                Button {
                    session.adjustSubtitleDelay(by: -PlayerSubtitleTiming.step)
                } label: {
                    Image(systemName: "minus").frame(width: 32, height: 24)
                }
                .accessibilityLabel("Decrease subtitle delay by 0.25 seconds")
                .disabled(session.subtitleDelaySeconds <= PlayerSubtitleTiming.range.lowerBound)
                Text(PlayerSubtitleTiming.label(session.subtitleDelaySeconds))
                    .font(.system(.title2, design: .monospaced)).monospacedDigit()
                    .frame(minWidth: 112)
                    .accessibilityLabel("Subtitle delay")
                    .accessibilityValue(PlayerSubtitleTiming.label(session.subtitleDelaySeconds))
                Button {
                    session.adjustSubtitleDelay(by: PlayerSubtitleTiming.step)
                } label: {
                    Image(systemName: "plus").frame(width: 32, height: 24)
                }
                .accessibilityLabel("Increase subtitle delay by 0.25 seconds")
                .disabled(session.subtitleDelaySeconds >= PlayerSubtitleTiming.range.upperBound)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!session.isCurrentOwner || session.engine != .mpv)
            Text("Positive values show subtitles later; negative values show them earlier.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Reset") { session.adjustSubtitleDelay(by: nil) }
                    .disabled(!session.isCurrentOwner || session.engine != .mpv || session.subtitleDelaySeconds == 0)
                Spacer()
                Button("Done") { showsSubtitleTiming = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func controlsHoverChanged(_ hovering: Bool) {
        hoveringControls = hovering
        revealControls()
    }

    private func revealControls() {
        controlsVisible = true
        controlsTask?.cancel()
        guard !hoveringControls, !showsSubtitleTiming else { return }
        controlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private var trailingTime: String {
        let position = isScrubbing ? scrubPosition : session.position
        if session.engine != .mpv || showsRemainingTime {
            return "−" + time(max(0, session.duration - position))
        }
        return time(session.duration)
    }

    private func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return "0:00" }
        let seconds = Int(value)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
#endif
