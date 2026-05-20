//
//  VLCRenderer.swift
//  Luna
//
//  VLC player renderer using VLCKitSPM for GPU-accelerated playback
//  Provides the same PlayerRenderer surface as MPVNativeRenderer
//
//  DEPENDENCY: VLCKitSPM via Swift Package Manager.

import UIKit
import AVFoundation

// MARK: - Compatibility: VLC renderer is iOS-only (tvOS uses MPV)
#if canImport(VLCKitSPM) && os(iOS)
import VLCKitSPM

protocol VLCRendererDelegate: AnyObject {
    func renderer(_ renderer: VLCRenderer, didUpdatePosition position: Double, duration: Double)
    func renderer(_ renderer: VLCRenderer, didChangePause isPaused: Bool)
    func renderer(_ renderer: VLCRenderer, didChangeLoading isLoading: Bool)
    func renderer(_ renderer: VLCRenderer, didBecomeReadyToSeek: Bool)
    func renderer(_ renderer: VLCRenderer, didFailWithError message: String)
    func renderer(_ renderer: VLCRenderer, getSubtitleForTime time: Double) -> NSAttributedString?
    func renderer(_ renderer: VLCRenderer, getSubtitleStyle: Void) -> SubtitleStyle
    func renderer(_ renderer: VLCRenderer, subtitleTrackDidChange trackId: Int)
    func rendererDidChangeTracks(_ renderer: VLCRenderer)
}

private extension Notification.Name {
    static let lunaVLCMediaPlayerTimeChanged = Notification.Name("VLCMediaPlayerTimeChanged")
    static let lunaVLCMediaPlayerStateChanged = Notification.Name("VLCMediaPlayerStateChanged")
}

final class VLCRenderer: NSObject, PlayerRenderer {
    enum RendererError: Error {
        case vlcInitializationFailed
        case mediaCreationFailed
    }
    
    private let displayLayer: AVSampleBufferDisplayLayer
    private let eventQueue = DispatchQueue(label: "vlc.renderer.events", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "vlc.renderer.state", attributes: .concurrent)
    
    // VLC renders into this child view. The parent stays stable in the UI while
    // the drawable remains the older VLCKitSPM plain UIView path.
    private let renderingContainerView: UIView
    private let plainVLCView: UIView
    private var activeVLCView: UIView
    
    private var vlcInstance: VLCMediaList?
    private var mediaPlayer: VLCMediaPlayer?
    private var currentMedia: VLCMedia?
    
    private var isPaused: Bool = true
    private var isLoading: Bool = false
    private var isReadyToSeek: Bool = false
    private var cachedDuration: Double = 0
    private var cachedPosition: Double = 0
    private var lastProgressHostTime: CFTimeInterval?
    private var progressTimer: DispatchSourceTimer?
    private var pendingAbsoluteSeek: Double?
    private var preparedInitialSeek: Double?
    private var loadGeneration = 0
    private let minimumReliableDuration: Double = 5.0
    private var currentURL: URL?
    private var currentHeaders: [String: String]?
    private var currentPreset: PlayerPreset?
    private var isRunning = false
    private var isStopping = false
    private var currentPlaybackSpeed: Double = 1.0

    private var currentSubtitleStyle: SubtitleStyle = .default
    private var lastLoggedStateCode: Int?
    private var lastProgressLogBucket = -1
    private var lastProgressAnomalyKey: String?
    private var lastProgressAnomalyLogTime: CFTimeInterval = 0
    private var lastAudioTracksDetailedLogSignature: String?
    private var lastPlaybackClockSampleHostTime: CFTimeInterval?
    private var lastPlaybackClockSamplePosition: Double?
    private var lastSlowPlaybackClockLogTime: CFTimeInterval = 0
    private var lastBufferingWhileAdvancingLogTime: CFTimeInterval = 0
    private var lastPositionRegressionLogTime: CFTimeInterval = 0
    private var lastSteadyPlaybackHeartbeatLogTime: CFTimeInterval = 0
    private var lastSteadyDrawableHeartbeatLogTime: CFTimeInterval = 0
    private var pendingSeekRequiresPlaybackClock = false
    private var pendingSeekDelayLogged = false
    private var needsProxyReloadAfterBackground = false
    private var proxyResumeAttemptID = 0
    private var lifecycleObserversInstalled = false
    
    weak var delegate: VLCRendererDelegate?
    
    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        let containerView = UIView()
        let plainView = UIView()
        self.renderingContainerView = containerView
        self.plainVLCView = plainView
        self.activeVLCView = plainView
        super.init()
        setupVLCView()
    }
    
    deinit {
        stop()
    }
    
    // MARK: - View Setup
    
    private func setupVLCView() {
        renderingContainerView.backgroundColor = .black
        renderingContainerView.clipsToBounds = true
        renderingContainerView.isUserInteractionEnabled = false
        renderingContainerView.layer.isOpaque = true

        configureVLCView(plainVLCView)
        attachActiveRenderingViewToContainer(reason: "setup")

        logVLC("setup view mode=\(renderingModeDescription()) contentMode=\(activeVLCView.contentMode.rawValue) gravity=\(activeVLCView.layer.contentsGravity.rawValue)")
    }

    private func configureVLCView(_ view: UIView) {
        view.backgroundColor = .black
        // Prefer aspect-fit semantics to keep full frame visible; rely on black bars.
        view.contentMode = .scaleAspectFit
        view.layer.contentsGravity = .resizeAspect
        view.layer.isOpaque = true
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
    }

    private func renderingModeDescription(for view: UIView? = nil) -> String {
        let target = view ?? activeVLCView
        if target === plainVLCView { return "plain-view" }
        return String(describing: type(of: target))
    }

    private func attachActiveRenderingViewToContainer(reason: String) {
        if activeVLCView.superview === renderingContainerView {
            return
        }

        plainVLCView.removeFromSuperview()
        renderingContainerView.addSubview(activeVLCView)
        activeVLCView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            activeVLCView.topAnchor.constraint(equalTo: renderingContainerView.topAnchor),
            activeVLCView.bottomAnchor.constraint(equalTo: renderingContainerView.bottomAnchor),
            activeVLCView.leadingAnchor.constraint(equalTo: renderingContainerView.leadingAnchor),
            activeVLCView.trailingAnchor.constraint(equalTo: renderingContainerView.trailingAnchor)
        ])
        logVLC("attached VLC rendering view mode=\(renderingModeDescription()) reason=\(reason)")
    }

    private func logVLC(_ message: String, type: String = "Player") {
        Logger.shared.log("[VLCRenderer] \(message)", type: type)
    }

    private func secondsText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "nil" }
        return String(format: "%.2f", value)
    }

    private func appStateText() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func playerSnapshot(_ player: VLCMediaPlayer? = nil) -> String {
        guard let player = player ?? mediaPlayer else {
            return "player=nil pausedFlag=\(isPaused) loading=\(isLoading) ready=\(isReadyToSeek) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) pending=\(secondsText(pendingAbsoluteSeek)) app=\(appStateText())"
        }

        let rawPosition = (player.time.value?.doubleValue ?? 0) / 1000.0
        let rawDuration = (player.media?.length.value?.doubleValue ?? 0) / 1000.0
        return "state=\(describeState(player.state))(\(stateCode(player.state))) playing=\(isPlayerActivelyPlaying(player)) pausedFlag=\(isPaused) loading=\(isLoading) ready=\(isReadyToSeek) raw=\(secondsText(rawPosition))/\(secondsText(rawDuration)) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) pending=\(secondsText(pendingAbsoluteSeek)) speed=\(String(format: "%.2f", currentPlaybackSpeed)) app=\(appStateText())"
    }

    private func foregroundSafeSnapshot() -> String {
        let urlHost = currentURL?.host ?? "nil"
        let urlPort = currentURL?.port.map(String.init) ?? "nil"
        let urlExt = currentURL?.pathExtension ?? "nil"
        return "running=\(isRunning) stopping=\(isStopping) playerPresent=\(mediaPlayer != nil) mediaPresent=\(currentMedia != nil) pausedFlag=\(isPaused) loading=\(isLoading) ready=\(isReadyToSeek) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) pending=\(secondsText(pendingAbsoluteSeek)) speed=\(String(format: "%.2f", currentPlaybackSpeed)) gen=\(loadGeneration) resumeAttempt=\(proxyResumeAttemptID) needsProxyReloadAfterBackground=\(needsProxyReloadAfterBackground) currentIsProxy=\(isVLCHeaderProxyURL(currentURL)) urlHost=\(urlHost) urlPort=\(urlPort) urlExt=\(urlExt) app=\(appStateText())"
    }

    func performanceOverlaySnapshot() -> String {
        "VLC \(isPaused ? "paused" : "playing")\(isLoading ? " loading" : "") ready=\(isReadyToSeek)\npos=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) speed=\(String(format: "%.2f", currentPlaybackSpeed)) pending=\(secondsText(pendingAbsoluteSeek)) app=\(appStateText())"
    }

    private func logDrawableSnapshot(_ event: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let drawableView = self.activeVLCView
            let bounds = drawableView.bounds
            let containerBounds = self.renderingContainerView.bounds
            let superBounds = self.renderingContainerView.superview?.bounds ?? .zero
            let currentDrawable = self.mediaPlayer?.drawable
            let drawableMatches = (currentDrawable as? UIView) === drawableView
            let drawableType = currentDrawable.map { String(describing: type(of: $0)) } ?? "nil"
            self.logVLC("\(event) drawableMode=\(self.renderingModeDescription()) drawableHidden=\(drawableView.isHidden) drawableAlpha=\(String(format: "%.2f", drawableView.alpha)) drawableBounds=\(String(format: "%.0fx%.0f", bounds.width, bounds.height)) containerBounds=\(String(format: "%.0fx%.0f", containerBounds.width, containerBounds.height)) super=\(String(format: "%.0fx%.0f", superBounds.width, superBounds.height)) window=\(self.renderingContainerView.window != nil) attachedToPlayer=\(drawableMatches) drawableType=\(drawableType) snapshot={\(self.playerSnapshot())}")
        }
    }

    private func logForegroundSafeDrawableSnapshot(_ event: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let drawableView = self.activeVLCView
            let bounds = drawableView.bounds
            let containerBounds = self.renderingContainerView.bounds
            let superBounds = self.renderingContainerView.superview?.bounds ?? .zero
            let attachedToContainer = drawableView.superview === self.renderingContainerView
            self.logVLC("\(event) foregroundSafe drawableMode=\(self.renderingModeDescription()) drawableHidden=\(drawableView.isHidden) drawableAlpha=\(String(format: "%.2f", drawableView.alpha)) drawableBounds=\(String(format: "%.0fx%.0f", bounds.width, bounds.height)) containerBounds=\(String(format: "%.0fx%.0f", containerBounds.width, containerBounds.height)) super=\(String(format: "%.0fx%.0f", superBounds.width, superBounds.height)) window=\(self.renderingContainerView.window != nil) attachedToContainer=\(attachedToContainer) subviews=\(self.renderingContainerView.subviews.count) safe={\(self.foregroundSafeSnapshot())}", type: "VLCCrashProbe")
        }
    }

    private func scheduleDrawableSnapshots(_ event: String, delays: [TimeInterval] = [0.25, 1.0]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.logDrawableSnapshot("\(event) +\(String(format: "%.2f", delay))s")
            }
        }
    }

    private func scheduleForegroundSafeDrawableSnapshots(_ event: String, delays: [TimeInterval] = [0.10, 0.50, 1.50]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.logForegroundSafeDrawableSnapshot("\(event) +\(String(format: "%.2f", delay))s")
            }
        }
    }

    private func reattachRenderingView() {
        logVLC("foreground reattach drawable requested safe={\(foregroundSafeSnapshot())}", type: "VLCCrashProbe")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attachActiveRenderingViewToContainer(reason: "reattach")
            self.mediaPlayer?.drawable = self.activeVLCView
            self.activeVLCView.setNeedsLayout()
            self.activeVLCView.layoutIfNeeded()
            self.logForegroundSafeDrawableSnapshot("foreground reattach drawable applied")
            self.scheduleForegroundSafeDrawableSnapshots("foreground reattach drawable followup")
        }
    }

    private func ensureAudioSessionActive() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            Logger.shared.log("VLCRenderer: Failed to activate AVAudioSession: \(error)", type: "Error")
        }
    }

    private func installMediaPlayerEventObservers(for player: VLCMediaPlayer) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mediaPlayerTimeChanged),
            name: .lunaVLCMediaPlayerTimeChanged,
            object: player
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mediaPlayerStateChanged),
            name: .lunaVLCMediaPlayerStateChanged,
            object: player
        )
    }

    private func removeMediaPlayerEventObservers(for player: VLCMediaPlayer) {
        NotificationCenter.default.removeObserver(self, name: .lunaVLCMediaPlayerTimeChanged, object: player)
        NotificationCenter.default.removeObserver(self, name: .lunaVLCMediaPlayerStateChanged, object: player)
    }

    /// Return the VLC view to be added to the view hierarchy
    func getRenderingView() -> UIView {
        logVLC("getRenderingView mode=\(renderingModeDescription()) snapshot={\(playerSnapshot())}")
        return renderingContainerView
    }
    
    // MARK: - Lifecycle
    
    func start() throws {
        guard !isRunning else {
            logVLC("start ignored: already running snapshot={\(playerSnapshot())}", type: "Stream")
            return
        }

        if isStopping {
            logVLC("start requested while stop cleanup is pending snapshot={\(playerSnapshot())}", type: "VLCCrashProbe")
        }
        
        do {
            logVLC("start initializing VLCMediaPlayer", type: "Stream")
            
            // Initialize VLC with proper options for video rendering
            mediaPlayer = VLCMediaPlayer()
            guard let mediaPlayer = mediaPlayer else {
                logVLC("start failed: VLCMediaPlayer returned nil", type: "Error")
                throw RendererError.vlcInitializationFailed
            }
            
            if Thread.isMainThread {
                attachActiveRenderingViewToContainer(reason: "start")
            }

            // Render directly into the currently selected VLC drawable.
            mediaPlayer.drawable = activeVLCView
            
            // Set up event handling
            installMediaPlayerEventObservers(for: mediaPlayer)
            
            if !lifecycleObserversInstalled {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleAppDidEnterBackground),
                    name: UIApplication.didEnterBackgroundNotification,
                    object: nil
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleAppWillResignActive),
                    name: UIApplication.willResignActiveNotification,
                    object: nil
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleAppWillEnterForeground),
                    name: UIApplication.willEnterForegroundNotification,
                    object: nil
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleAppDidBecomeActive),
                    name: UIApplication.didBecomeActiveNotification,
                    object: nil
                )
                lifecycleObserversInstalled = true
            }
            
            isRunning = true
            logVLC("start completed snapshot={\(playerSnapshot(mediaPlayer))}", type: "Stream")

        } catch {
            logVLC("start threw \(error)", type: "Error")
            throw RendererError.vlcInitializationFailed
        }
    }
    
    func stop() {
        if isStopping {
            logVLC("stop ignored: already stopping snapshot={\(playerSnapshot())}", type: "Stream")
            return
        }
        if !isRunning {
            logVLC("stop ignored: not running snapshot={\(playerSnapshot())}", type: "Stream")
            return
        }


        
        logVLC("stop begin snapshot={\(playerSnapshot())}", type: "Stream")
        let playerToStop = mediaPlayer
        let stopGeneration = loadGeneration + 1
        isRunning = false
        isStopping = true
        loadGeneration += 1
        proxyResumeAttemptID += 1
        stopProgressPolling()

        eventQueue.async { [weak self] in
            guard let self else { return }
            if let playerToStop {
                self.removeMediaPlayerEventObservers(for: playerToStop)
            }

            if let playerToStop {
                playerToStop.stop()
            }

            if let playerToStop, self.mediaPlayer !== playerToStop {
                self.logVLC("stop cleanup did not clear current player because playback already advanced generation=\(stopGeneration) currentGeneration=\(self.loadGeneration) snapshot={\(self.playerSnapshot())}", type: "VLCCrashProbe")
            } else {
                self.mediaPlayer = nil

                self.currentMedia = nil
                self.isReadyToSeek = false
                self.isPaused = true
                self.isLoading = false
                self.lastLoggedStateCode = nil
                self.lastProgressLogBucket = -1
                self.lastProgressAnomalyKey = nil
            }

            // Mark stop completion only after cleanup finishes to prevent reentrancy races
            self.isStopping = false
            self.logVLC("stop completed", type: "Stream")

        }
    }
    
    // MARK: - Playback Control

    func prepareInitialSeek(to seconds: Double?) {
        let clamped = seconds.map { max(0, $0) }
        preparedInitialSeek = clamped
        pendingAbsoluteSeek = clamped
        logVLC("prepareInitialSeek requested=\(secondsText(seconds)) clamped=\(secondsText(clamped)) snapshot={\(playerSnapshot())}", type: "Progress")
    }
    
    func load(url: URL, with preset: PlayerPreset, headers: [String: String]? = nil) {
        loadMedia(url: url, with: preset, headers: headers)
    }

    private func loadMedia(
        url: URL,
        with preset: PlayerPreset,
        headers: [String: String]? = nil
    ) {
        let headerKeys = (headers ?? [:]).keys.sorted().joined(separator: ",")
        let replacingActiveMedia = currentMedia != nil && isRunning && !isStopping
        logVLC("load begin url=\(url.absoluteString) preset=\(preset.id.rawValue) headers=\(headers?.count ?? 0)[\(headerKeys)] isLocal=\(url.isFileURL) preparedInitialSeek=\(secondsText(preparedInitialSeek)) replacingActiveMedia=\(replacingActiveMedia)", type: "Stream")
        
        currentURL = url
        currentPreset = preset
        loadGeneration += 1
        proxyResumeAttemptID += 1
        needsProxyReloadAfterBackground = false
        let initialSeek = preparedInitialSeek
        preparedInitialSeek = nil
        cachedPosition = 0
        cachedDuration = 0
        pendingAbsoluteSeek = initialSeek
        pendingSeekRequiresPlaybackClock = initialSeek != nil && shouldDelayPreparedSeekUntilPlaybackClock(for: url)
        pendingSeekDelayLogged = false
        lastProgressHostTime = nil
        lastLoggedStateCode = nil
        lastProgressLogBucket = -1
        lastProgressAnomalyKey = nil
        lastPlaybackClockSampleHostTime = nil
        lastPlaybackClockSamplePosition = nil
        lastSlowPlaybackClockLogTime = 0
        lastBufferingWhileAdvancingLogTime = 0
        lastPositionRegressionLogTime = 0
        lastSteadyPlaybackHeartbeatLogTime = 0
        lastSteadyDrawableHeartbeatLogTime = 0

        // Use provided headers as-is; they're already built correctly by the caller
        // (StreamURL domain should NOT be used for headers—service baseUrl should be)
        currentHeaders = headers ?? [:]
        
        isLoading = true
        isReadyToSeek = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didChangeLoading: true)
        }
        
        eventQueue.async { [weak self] in
            guard let self, let player = self.mediaPlayer else {
                Logger.shared.log("[VLCRenderer.load] ERROR: mediaPlayer is nil", type: "Error")
                return 
            }
            
            let mediaURL = url

            let media = VLCMedia(url: mediaURL)
            if let headers = self.currentHeaders, !headers.isEmpty {
                if let ua = headers["User-Agent"], !ua.isEmpty {
                    media.addOption(":http-user-agent=\(ua)")
                }
                if let referer = headers["Referer"], !referer.isEmpty {
                    media.addOption(":http-referrer=\(referer)")
                    media.addOption(":http-header=Referer: \(referer)")
                }
                if let cookie = headers["Cookie"], !cookie.isEmpty {
                    media.addOption(":http-cookie=\(cookie)")
                }

                media.addOption(":http-reconnect=true")

                let skippedKeys: Set<String> = ["User-Agent", "Referer", "Cookie"]
                for (key, value) in headers where !skippedKeys.contains(key) {
                    guard !value.isEmpty else { continue }
                    media.addOption(":http-header=\(key): \(value)")
                }
            }

            // Keep reconnect enabled for flaky hosts
            media.addOption(":http-reconnect=true")

            // Apply subtitle styling options (best effort; depends on libvlc text renderer support)
            self.applySubtitleStyleOptions(to: media)

            if let initialSeek, initialSeek > 0 {
                Logger.shared.log("[VLCRenderer.load] queued initial seek \(Int(initialSeek))s", type: "Progress")
                if self.pendingSeekRequiresPlaybackClock {
                    Logger.shared.log("[VLCRenderer.load] delaying initial seek until playback clock advances for proxied stream", type: "Progress")
                }
            }

            // Tune caching and demuxer for local vs. remote playback
            if mediaURL.isFileURL {
                media.addOption(":file-caching=300")
                // Force MPEG-TS demuxer for .ts files (concatenated HLS segments)
                let ext = mediaURL.pathExtension.lowercased()
                if ext == "ts" || ext == "mts" || ext == "m2ts" {
                    media.addOption(":demux=ts")
                }
            } else {
                // Reduce buffering while keeping resume/start reasonably responsive
                media.addOption(":network-caching=12000")  // ~12s
            }

            self.currentMedia = media
            
            player.media = media
            player.drawable = self.activeVLCView
            self.ensureAudioSessionActive()
            self.logVLC("load configured media; calling play snapshot={\(self.playerSnapshot(player))}", type: "Stream")
            player.play()
            self.startProgressPolling()
            self.scheduleLoadingSanityChecks()
            self.logVLC("load submitted play snapshot={\(self.playerSnapshot(player))}", type: "Stream")
        }
    }
    
    func reloadCurrentItem() {
        guard let player = mediaPlayer else { return }
        logVLC("reloadCurrentItem snapshot={\(playerSnapshot())}", type: "Stream")
        recoverPlaybackWithoutReloading(player, savedPosition: cachedPosition, reason: "reload-current-item")
    }

    private func isVLCHeaderProxyURL(_ url: URL?) -> Bool {
        guard let url,
              let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            return false
        }
        return url.path.localizedCaseInsensitiveContains("/proxy/")
    }

    private func shouldDelayPreparedSeekUntilPlaybackClock(for url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" else {
            return false
        }

        return url.path.localizedCaseInsensitiveContains("/proxy/")
    }
    
    func applyPreset(_ preset: PlayerPreset) {
        currentPreset = preset
        logVLC("applyPreset \(preset.id.rawValue) snapshot={\(playerSnapshot())}")
        // VLC doesn't require preset application like mpv does
        // Presets are mainly for video output configuration which VLC handles automatically
    }
    
    func play() {
        logVLC("play requested snapshot={\(playerSnapshot())}", type: "Stream")
        logDrawableSnapshot("play requested")
        isPaused = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didChangePause: false)
        }

        guard let player = mediaPlayer else { return }
        ensureAudioSessionActive()

        // After a background pause, give VLC fresh local proxy media in-place.
        // Reusing the old backgrounded proxy connection can leave libVLC in a
        // fragile post-foreground state even after the clock starts moving.
        let state = player.state
        if needsProxyReloadAfterBackground, isVLCHeaderProxyURL(currentURL) {
            if isTerminalState(state), !isPlaybackActive(player) {
                Logger.shared.log("[VLCRenderer.play] Background proxy resume found terminal state \(describeState(state)); doing terminal-only media reload from position \(cachedPosition)s", type: "Stream")
                reloadStoppedPlayerMediaPreservingPosition(cachedPosition, reason: "background-terminal")
            } else if reloadForegroundProxiedMediaPreservingPosition(cachedPosition, player: player, reason: "background-resume") {
                Logger.shared.log("[VLCRenderer.play] Background proxy resume refreshed media in-place from position \(cachedPosition)s", type: "Stream")
            } else {
                softResumeProxiedStreamAfterBackground(player)
            }
            return
        }

        if isTerminalState(state), !isPlaybackActive(player) {
            Logger.shared.log("[VLCRenderer.play] Player in \(describeState(state)) state; doing terminal-only media reload from position \(cachedPosition)s", type: "Stream")
            reloadStoppedPlayerMediaPreservingPosition(cachedPosition, reason: "terminal-play")
            return
        }

        player.play()
        startProgressPolling()
        if currentPlaybackSpeed != 1.0 {
            player.rate = Float(currentPlaybackSpeed)
        }
        logVLC("play submitted snapshot={\(playerSnapshot(player))}", type: "Stream")
        logDrawableSnapshot("play submitted")
    }

    private func softResumeProxiedStreamAfterBackground(_ player: VLCMediaPlayer) {
        proxyResumeAttemptID += 1
        let attemptID = proxyResumeAttemptID
        let savedPosition = max(0, cachedPosition)
        let baselineRawPosition = rawPlaybackPosition(from: player)

        resetPlaybackClockDiagnostics(reason: "background-proxy-soft-resume", logIfEmpty: true)
        logVLC("background proxy soft resume begin attempt=\(attemptID) saved=\(secondsText(savedPosition)) raw=\(secondsText(baselineRawPosition)) snapshot={\(playerSnapshot(player))}", type: "Stream")
        player.drawable = activeVLCView
        player.play()
        startProgressPolling()
        if currentPlaybackSpeed != 1.0 {
            player.rate = Float(currentPlaybackSpeed)
        }
        logDrawableSnapshot("background proxy soft resume submitted")

        scheduleProxySoftResumeCheck(
            attemptID: attemptID,
            player: player,
            savedPosition: savedPosition,
            baselineRawPosition: baselineRawPosition,
            delay: 1.25,
            isFinalCheck: false
        )
        scheduleProxySoftResumeCheck(
            attemptID: attemptID,
            player: player,
            savedPosition: savedPosition,
            baselineRawPosition: baselineRawPosition,
            delay: 3.5,
            isFinalCheck: true
        )
    }

    private func scheduleProxySoftResumeCheck(
        attemptID: Int,
        player: VLCMediaPlayer,
        savedPosition: Double,
        baselineRawPosition: Double,
        delay: TimeInterval,
        isFinalCheck: Bool
    ) {
        eventQueue.asyncAfter(deadline: .now() + delay) { [weak self, weak player] in
            guard let self,
                  let player,
                  self.proxyResumeAttemptID == attemptID,
                  self.needsProxyReloadAfterBackground,
                  self.mediaPlayer === player,
                  self.isRunning,
                  !self.isStopping else {
                return
            }

            let rawPosition = self.rawPlaybackPosition(from: player)
            let baselineMatchesResumePoint = savedPosition < 5 || baselineRawPosition >= savedPosition - 5
            let rawAdvanced = rawPosition >= savedPosition + 0.75 || (baselineMatchesResumePoint && rawPosition >= baselineRawPosition + 0.75)
            let terminal = self.isTerminalState(player.state) && !self.isPlaybackActive(player)
            self.logVLC("background proxy soft resume check attempt=\(attemptID) delay=\(String(format: "%.2f", delay)) final=\(isFinalCheck) raw=\(self.secondsText(rawPosition)) baseline=\(self.secondsText(baselineRawPosition)) saved=\(self.secondsText(savedPosition)) advanced=\(rawAdvanced) terminal=\(terminal) snapshot={\(self.playerSnapshot(player))}", type: "VLCCrashProbe")

            if rawAdvanced {
                self.needsProxyReloadAfterBackground = false
                self.logVLC("background proxy soft resume confirmed attempt=\(attemptID) raw=\(self.secondsText(rawPosition)) saved=\(self.secondsText(savedPosition))", type: "Stream")
                return
            }

            if !isFinalCheck && !terminal {
                return
            }

            self.needsProxyReloadAfterBackground = false
            self.logVLC("background proxy soft resume fallback attempt=\(attemptID) reason=\(terminal ? "terminal-state" : "clock-stalled") saved=\(self.secondsText(savedPosition)) snapshot={\(self.playerSnapshot(player))}", type: "VLCCrashProbe")
            if terminal {
                self.reloadStoppedPlayerMediaPreservingPosition(savedPosition, reason: "soft-resume-terminal")
            } else {
                self.recoverPlaybackWithoutReloading(player, savedPosition: savedPosition, reason: "soft-resume-clock-stalled")
            }
        }
    }

    private func reloadForegroundProxiedMediaPreservingPosition(_ position: Double, player: VLCMediaPlayer, reason: String) -> Bool {
        guard let url = currentURL,
              isVLCHeaderProxyURL(url),
              let preset = currentPreset,
              let refreshedURL = VLCHeaderProxy.shared.refreshedProxyURL(
                from: url,
                restartListener: false,
                reason: "foreground-media-reload-\(reason)"
              ) else {
            return false
        }

        let resumePosition = max(0, position)
        let preservedDuration = cachedDuration
        proxyResumeAttemptID += 1
        let attemptID = proxyResumeAttemptID
        resetPlaybackClockDiagnostics(reason: "foreground-proxy-media-reload-\(reason)", logIfEmpty: true)
        needsProxyReloadAfterBackground = false
        isPaused = false

        logVLC("foreground proxy media reload begin reason=\(reason) attempt=\(attemptID) oldPort=\(url.port?.description ?? "nil") newPort=\(refreshedURL.port?.description ?? "nil") resume=\(secondsText(resumePosition)) preservedDuration=\(secondsText(preservedDuration)) safe={\(foregroundSafeSnapshot())} snapshot={\(playerSnapshot(player))}", type: "VLCCrashProbe")
        preparedInitialSeek = resumePosition
        pendingAbsoluteSeek = resumePosition
        loadMedia(url: refreshedURL, with: preset, headers: currentHeaders)
        cachedPosition = resumePosition
        if preservedDuration >= minimumReliableDuration {
            cachedDuration = preservedDuration
        }
        logVLC("foreground proxy media reload submitted reason=\(reason) attempt=\(attemptID) safe={\(foregroundSafeSnapshot())}", type: "VLCCrashProbe")
        return true
    }

    private func reloadStoppedPlayerMediaPreservingPosition(_ position: Double, reason: String) {
        guard let player = mediaPlayer,
              isTerminalState(player.state),
              !isPlaybackActive(player),
              let url = currentURL,
              let preset = currentPreset else {
            if let player = mediaPlayer {
                recoverPlaybackWithoutReloading(player, savedPosition: position, reason: "\(reason)-not-terminal")
            }
            return
        }

        let resumePosition = max(0, position)
        let preservedDuration = cachedDuration
        let mediaURL: URL
        if isVLCHeaderProxyURL(url),
           let refreshedURL = VLCHeaderProxy.shared.refreshedProxyURL(
                from: url,
                restartListener: true,
                reason: "terminal-media-reload-\(reason)"
           ) {
            mediaURL = refreshedURL
            logVLC("terminal-only media reload refreshed proxy reason=\(reason) oldPort=\(url.port?.description ?? "nil") newPort=\(refreshedURL.port?.description ?? "nil")", type: "VLCCrashProbe")
        } else {
            mediaURL = url
        }

        logVLC("terminal-only media reload begin reason=\(reason) resume=\(secondsText(resumePosition)) preservedDuration=\(secondsText(preservedDuration)) snapshot={\(playerSnapshot(player))}", type: "VLCCrashProbe")
        preparedInitialSeek = resumePosition
        pendingAbsoluteSeek = resumePosition
        loadMedia(url: mediaURL, with: preset, headers: currentHeaders)
        cachedPosition = resumePosition
        if preservedDuration >= minimumReliableDuration {
            cachedDuration = preservedDuration
        }
    }

    private func recoverPlaybackWithoutReloading(_ player: VLCMediaPlayer, savedPosition: Double, reason: String) {
        proxyResumeAttemptID += 1
        let attemptID = proxyResumeAttemptID
        let resumePosition = max(0, savedPosition)
        let baselineRawPosition = rawPlaybackPosition(from: player)

        isLoading = true
        isPaused = false
        needsProxyReloadAfterBackground = false
        resetPlaybackClockDiagnostics(reason: "no-reload-recovery-\(reason)", logIfEmpty: true)

        let proxyRestarted: Bool
        if let currentURL, isVLCHeaderProxyURL(currentURL) {
            proxyRestarted = VLCHeaderProxy.shared.restartListenerForExistingProxyURL(currentURL, reason: reason)
        } else {
            proxyRestarted = false
        }

        logVLC("no-reload recovery begin reason=\(reason) attempt=\(attemptID) proxyRestarted=\(proxyRestarted) saved=\(secondsText(resumePosition)) raw=\(secondsText(baselineRawPosition)) snapshot={\(playerSnapshot(player))}", type: "VLCCrashProbe")
        ensureAudioSessionActive()
        player.drawable = activeVLCView
        queueSeekWithoutReloading(to: resumePosition, on: player, reason: reason)
        player.play()
        startProgressPolling()
        if currentPlaybackSpeed != 1.0 {
            player.rate = Float(currentPlaybackSpeed)
        }
        logDrawableSnapshot("no-reload recovery submitted")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didChangeLoading: true)
            self.delegate?.renderer(self, didChangePause: false)
        }

        scheduleNoReloadRecoveryCheck(
            attemptID: attemptID,
            player: player,
            savedPosition: resumePosition,
            baselineRawPosition: baselineRawPosition,
            delay: 2.0,
            isFinalCheck: false
        )
        scheduleNoReloadRecoveryCheck(
            attemptID: attemptID,
            player: player,
            savedPosition: resumePosition,
            baselineRawPosition: baselineRawPosition,
            delay: 5.0,
            isFinalCheck: true
        )
    }

    private func queueSeekWithoutReloading(to seconds: Double, on player: VLCMediaPlayer, reason: String) {
        let target = max(0, seconds)
        let duration = reliableDuration(from: player)
        let effectiveDuration = max(duration, cachedDuration)
        cachedPosition = effectiveDuration >= minimumReliableDuration ? min(target, effectiveDuration) : target

        if duration >= minimumReliableDuration {
            let normalized = min(max(cachedPosition / duration, 0), 1)
            setNormalizedPosition(normalized, on: player)
            pendingAbsoluteSeek = nil
            pendingSeekRequiresPlaybackClock = false
            pendingSeekDelayLogged = false
            logVLC("no-reload recovery seek used live duration reason=\(reason) target=\(secondsText(cachedPosition)) duration=\(secondsText(duration)) normalized=\(String(format: "%.5f", normalized))", type: "Progress")
        } else if cachedDuration >= minimumReliableDuration {
            let normalized = min(max(cachedPosition / cachedDuration, 0), 1)
            setNormalizedPosition(normalized, on: player)
            pendingAbsoluteSeek = cachedPosition
            pendingSeekRequiresPlaybackClock = false
            pendingSeekDelayLogged = false
            logVLC("no-reload recovery seek used cached duration reason=\(reason) target=\(secondsText(cachedPosition)) cachedDuration=\(secondsText(cachedDuration)) normalized=\(String(format: "%.5f", normalized))", type: "Progress")
        } else {
            pendingAbsoluteSeek = cachedPosition
            pendingSeekRequiresPlaybackClock = currentURL.map { shouldDelayPreparedSeekUntilPlaybackClock(for: $0) } ?? false
            pendingSeekDelayLogged = false
            logVLC("no-reload recovery queued seek reason=\(reason) target=\(secondsText(cachedPosition)) duration unavailable", type: "Progress")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didUpdatePosition: self.cachedPosition, duration: max(0, effectiveDuration))
        }
    }

    private func scheduleNoReloadRecoveryCheck(
        attemptID: Int,
        player: VLCMediaPlayer,
        savedPosition: Double,
        baselineRawPosition: Double,
        delay: TimeInterval,
        isFinalCheck: Bool
    ) {
        eventQueue.asyncAfter(deadline: .now() + delay) { [weak self, weak player] in
            guard let self,
                  let player,
                  self.proxyResumeAttemptID == attemptID,
                  self.mediaPlayer === player,
                  self.isRunning,
                  !self.isStopping else {
                return
            }

            let rawPosition = self.rawPlaybackPosition(from: player)
            let baselineMatchesResumePoint = savedPosition < 5 || baselineRawPosition >= savedPosition - 5
            let rawAdvanced = rawPosition >= savedPosition + 0.75 || (baselineMatchesResumePoint && rawPosition >= baselineRawPosition + 0.75)
            let terminal = self.isTerminalState(player.state) && !self.isPlaybackActive(player)
            self.logVLC("no-reload recovery check attempt=\(attemptID) delay=\(String(format: "%.2f", delay)) final=\(isFinalCheck) raw=\(self.secondsText(rawPosition)) baseline=\(self.secondsText(baselineRawPosition)) saved=\(self.secondsText(savedPosition)) advanced=\(rawAdvanced) terminal=\(terminal) snapshot={\(self.playerSnapshot(player))}", type: "VLCCrashProbe")

            if rawAdvanced, !terminal {
                self.clearLoadingState()
                self.logVLC("no-reload recovery confirmed attempt=\(attemptID) raw=\(self.secondsText(rawPosition)) saved=\(self.secondsText(savedPosition))", type: "Stream")
                return
            }

            if !isFinalCheck && !terminal {
                return
            }

            self.isLoading = false
            self.isPaused = true
            self.proxyResumeAttemptID += 1
            self.stopProgressPolling()
            let message = "VLC could not resume this stream after backgrounding without restarting playback."
            self.logVLC("no-reload recovery failed attempt=\(attemptID) message=\(message) snapshot={\(self.playerSnapshot(player))}", type: "Error")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didChangeLoading: false)
                self.delegate?.renderer(self, didChangePause: true)
                self.delegate?.renderer(self, didFailWithError: message)
            }
        }
    }

    func pausePlayback() {
        pausePlayback(forceSendToPlayer: false)
    }

    private func pausePlayback(forceSendToPlayer: Bool) {
        let player = mediaPlayer
        let shouldSendPause = player.map {
            forceSendToPlayer || isPlayerActivelyPlaying($0) || isPlayingState($0.state) || (!isPaused && !isVLCPlayerPausedState($0.state) && !isTerminalState($0.state))
        } ?? !isPaused
        logVLC("pause requested forceSend=\(forceSendToPlayer) shouldSendPause=\(shouldSendPause) snapshot={\(playerSnapshot(player))}", type: "Stream")
        logDrawableSnapshot("pause requested")
        isPaused = true
        proxyResumeAttemptID += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didChangePause: true)
        }

        if shouldSendPause {
            player?.pause()
        }
        stopProgressPolling()
        resetPlaybackClockDiagnostics(reason: forceSendToPlayer ? "forced-pause" : "pause")
        logVLC("pause completed snapshot={\(playerSnapshot(player))}", type: "Stream")
        logDrawableSnapshot("pause completed")
    }
    
    func togglePause() {
        logVLC("togglePause currentPaused=\(isPaused) snapshot={\(playerSnapshot())}", type: "Stream")
        if isPaused { play() } else { pausePlayback() }
    }
    
    func seek(to seconds: Double) {
        logVLC("seek(to:) requested target=\(secondsText(seconds)) snapshot={\(playerSnapshot())}", type: "Progress")
        eventQueue.async { [weak self] in
            guard let self, let player = self.mediaPlayer else {
                Logger.shared.log("[VLCRenderer] seek(to:) dropped: mediaPlayer missing target=\(seconds)", type: "Error")
                return
            }
            self.applySeek(to: seconds, on: player)
        }
    }

    func seek(by seconds: Double) {
        logVLC("seek(by:) requested delta=\(secondsText(seconds)) snapshot={\(playerSnapshot())}", type: "Progress")
        eventQueue.async { [weak self] in
            guard let self, let player = self.mediaPlayer else {
                Logger.shared.log("[VLCRenderer] seek(by:) dropped: mediaPlayer missing delta=\(seconds)", type: "Error")
                return
            }
            let currentPosition = self.resolvedPlaybackProgress(from: player).position
            self.logVLC("seek(by:) resolved current=\(self.secondsText(currentPosition)) target=\(self.secondsText(currentPosition + seconds))", type: "Progress")
            self.applySeek(to: currentPosition + seconds, on: player)
        }
    }

    private func applySeek(to seconds: Double, on player: VLCMediaPlayer, refreshVideoOutput: Bool = true) {
        let duration = reliableDuration(from: player)
        let upperBound = duration >= minimumReliableDuration ? max(0, duration - 0.1) : Double.greatestFiniteMagnitude
        let clamped = min(max(0, seconds), upperBound)
        let before = resolvedPlaybackProgress(from: player).position
        logVLC("applySeek begin requested=\(secondsText(seconds)) current=\(secondsText(before)) clamped=\(secondsText(clamped)) reliableDuration=\(secondsText(duration)) cachedDuration=\(secondsText(cachedDuration)) paused=\(isPaused) refreshVideoOutput=\(refreshVideoOutput)", type: "Progress")

        if isTerminalState(player.state), !isPlaybackActive(player), !isLoading {
            cachedPosition = clamped
            pendingAbsoluteSeek = clamped
            logVLC("applySeek terminal player; doing terminal-only media reload target=\(secondsText(clamped)) snapshot={\(playerSnapshot(player))}", type: "Progress")
            reloadStoppedPlayerMediaPreservingPosition(clamped, reason: "terminal-seek")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didUpdatePosition: clamped, duration: max(duration, self.cachedDuration))
            }
            return
        }

        if duration >= minimumReliableDuration {
            let normalized = min(max(clamped / duration, 0), 1)
            setNormalizedPosition(normalized, on: player)
            cachedDuration = duration
            pendingAbsoluteSeek = nil
            pendingSeekRequiresPlaybackClock = false
            pendingSeekDelayLogged = false
            logVLC("applySeek used live duration normalized=\(String(format: "%.5f", normalized))", type: "Progress")
        } else if cachedDuration >= minimumReliableDuration {
            let normalized = min(max(clamped / cachedDuration, 0), 1)
            setNormalizedPosition(normalized, on: player)
            pendingAbsoluteSeek = clamped
            pendingSeekRequiresPlaybackClock = false
            pendingSeekDelayLogged = false
            logVLC("applySeek used cached duration normalized=\(String(format: "%.5f", normalized)) pending=\(secondsText(clamped))", type: "Progress")
        } else {
            pendingAbsoluteSeek = clamped
            logVLC("applySeek queued pending absolute seek=\(secondsText(clamped)) because duration unavailable", type: "Progress")
        }

        cachedPosition = clamped
        if isPlaybackActive(player) || !isPaused {
            lastProgressHostTime = CACurrentMediaTime()
            startProgressPolling()
        }
        if refreshVideoOutput {
            refreshVideoOutputAfterSeek(player, shouldResumePlayback: !isPaused)
        } else {
            eventQueue.asyncAfter(deadline: .now() + 0.08) { [weak self, weak player] in
                guard let self, self.isRunning, !self.isStopping, let player else { return }
                self.clearLoadingState()
                self.publishPlaybackProgress(from: player)
                self.logVLC("applySeek follow-up snapshot={\(self.playerSnapshot(player))}", type: "Progress")
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didUpdatePosition: clamped, duration: max(duration, self.cachedDuration))
        }
        logVLC("applySeek end snapshot={\(playerSnapshot(player))}", type: "Progress")
    }

    private func refreshVideoOutputAfterSeek(_ player: VLCMediaPlayer, shouldResumePlayback: Bool) {
        logVLC("refreshVideoOutputAfterSeek shouldResume=\(shouldResumePlayback) snapshot={\(playerSnapshot(player))}", type: "Progress")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, !self.isStopping else { return }
            self.attachActiveRenderingViewToContainer(reason: "seek refresh")
            self.mediaPlayer?.drawable = self.activeVLCView
            self.activeVLCView.isHidden = false
            self.activeVLCView.alpha = 1
            self.renderingContainerView.setNeedsLayout()
            self.renderingContainerView.layoutIfNeeded()
            self.activeVLCView.setNeedsLayout()
            self.activeVLCView.layoutIfNeeded()
            self.logDrawableSnapshot("refreshVideoOutputAfterSeek layout")
        }

        eventQueue.asyncAfter(deadline: .now() + 0.08) { [weak self, weak player] in
            guard let self, self.isRunning, !self.isStopping, let player else { return }
            if shouldResumePlayback {
                self.ensureAudioSessionActive()
                player.play()
                if self.currentPlaybackSpeed != 1.0 {
                    player.rate = Float(self.currentPlaybackSpeed)
                }
                self.startProgressPolling()
            } else if self.isTerminalState(player.state), !self.isPlaybackActive(player) {
                self.logVLC("refreshVideoOutputAfterSeek skipped paused frame refresh because player is terminal snapshot={\(self.playerSnapshot(player))}", type: "Progress")
            } else {
                self.logVLC("refreshVideoOutputAfterSeek paused seek on stable VLCKitSPM path; drawable already refreshed snapshot={\(self.playerSnapshot(player))}", type: "Progress")
            }
            self.clearLoadingState()
            self.publishPlaybackProgress(from: player)
            self.logVLC("refreshVideoOutputAfterSeek follow-up snapshot={\(self.playerSnapshot(player))}", type: "Progress")
        }
    }

    private func reliableDuration(from player: VLCMediaPlayer) -> Double {
        let mediaDurationMs = player.media?.length.value?.doubleValue ?? 0
        let mediaDuration = mediaDurationMs / 1000.0
        let cached = cachedDuration.isFinite && cachedDuration >= minimumReliableDuration ? cachedDuration : 0
        if mediaDuration.isFinite, mediaDuration >= minimumReliableDuration {
            return max(mediaDuration, cached)
        }
        return cached
    }

    func setSpeed(_ speed: Double) {
        logVLC("setSpeed requested=\(String(format: "%.2f", speed)) snapshot={\(playerSnapshot())}")
        eventQueue.async { [weak self] in
            guard let self, let player = self.mediaPlayer else { return }
            
            self.currentPlaybackSpeed = max(0.1, speed)
            
            player.rate = Float(self.currentPlaybackSpeed)
            self.logVLC("setSpeed applied=\(String(format: "%.2f", self.currentPlaybackSpeed)) snapshot={\(self.playerSnapshot(player))}")
        }
    }
    
    func getSpeed() -> Double {
        guard let player = mediaPlayer else { return 1.0 }
        return Double(player.rate)
    }
    
    // MARK: - Audio Track Controls
    
    func getAudioTracksDetailed() -> [(Int, String, String)] {
        guard let player = mediaPlayer else { return [] }
        
        var result: [(Int, String, String)] = []
        
        // VLC provides audio track info through the media player.
        if let audioTrackIndexes = player.audioTrackIndexes as? [Int],
           let audioTrackNames = player.audioTrackNames as? [String] {
            // VLCKitSPM doesn't expose language codes publicly; rely on name parsing.
            for (index, name) in zip(audioTrackIndexes, audioTrackNames) {
                let code = guessLanguageCode(from: name)
                result.append((index, name, code))
            }
        }
        let currentTrackId = getCurrentAudioTrackId()
        let trackSignature = result.map { "\($0.0):\($0.1):\($0.2)" }.joined(separator: "|")
        let logSignature = "\(currentTrackId)|\(trackSignature)"
        if logSignature != lastAudioTracksDetailedLogSignature {
            lastAudioTracksDetailedLogSignature = logSignature
            logVLC("getAudioTracksDetailed count=\(result.count) current=\(currentTrackId) names=\(result.map { "\($0.0):\($0.1)" }.joined(separator: " | "))")
        }
        
        return result
    }

    // Heuristic language guess when VLC doesn't expose codes
    private func guessLanguageCode(from name: String) -> String {
        let lower = name.lowercased()
        let map: [(String, [String])] = [
            ("jpn", ["japanese", "jpn", "ja", "jp"]),
            ("eng", ["english", "eng", "en", "us", "uk"]),
            ("spa", ["spanish", "spa", "es", "esp", "lat" ]),
            ("fre", ["french", "fra", "fre", "fr"]),
            ("ger", ["german", "deu", "ger", "de"]),
            ("ita", ["italian", "ita", "it"]),
            ("por", ["portuguese", "por", "pt", "br"]),
            ("rus", ["russian", "rus", "ru"]),
            ("chi", ["chinese", "chi", "zho", "zh", "mandarin", "cantonese"]),
            ("kor", ["korean", "kor", "ko"])
        ]
        for (code, tokens) in map {
            if tokens.contains(where: { lower.contains($0) }) {
                return code
            }
        }
        return ""
    }
    
    func getAudioTracks() -> [(Int, String)] {
        return getAudioTracksDetailed().map { ($0.0, $0.1) }
    }
    
    func setAudioTrack(id: Int) {
        guard let player = mediaPlayer else { return }
        
        // Set track immediately - VLC property setters are thread-safe
        logVLC("setAudioTrack id=\(id) beforeCurrent=\(getCurrentAudioTrackId()) snapshot={\(playerSnapshot(player))}")
        player.currentAudioTrackIndex = Int32(id)
        
        // Notify delegates on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.rendererDidChangeTracks(self)
        }
    }
    
    func getCurrentAudioTrackId() -> Int {
        guard let player = mediaPlayer else { return -1 }
        return Int(player.currentAudioTrackIndex)
    }

    
    // MARK: - Subtitle Track Controls
    
    func getSubtitleTracks() -> [(Int, String)] {
        guard let player = mediaPlayer else { return [] }
        
        var result: [(Int, String)] = []
        
        // VLC provides subtitle track info through the media player
        if let subtitleIndexes = player.videoSubTitlesIndexes as? [Int],
           let subtitleNames = player.videoSubTitlesNames as? [String] {
            for (index, name) in zip(subtitleIndexes, subtitleNames) {
                result.append((index, name))
            }
        }

        return result
    }

    func getCurrentSubtitleTrackId() -> Int {
        guard let player = mediaPlayer else { return -1 }
        return Int(player.currentVideoSubTitleIndex)
    }

    func setSubtitleTrack(id: Int) {
        guard let player = mediaPlayer else { return }

        // Set track immediately - VLC property setters are thread-safe
        Logger.shared.log("VLCRenderer: Setting subtitle track to ID \(id)", type: "Player")
        player.currentVideoSubTitleIndex = Int32(id)

        // Notify delegates on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, subtitleTrackDidChange: id)
            self.delegate?.rendererDidChangeTracks(self)
        }
    }
    
    func disableSubtitles() {
        guard let player = mediaPlayer else { return }
        // Disable subtitles immediately by setting track index to -1
        player.currentVideoSubTitleIndex = -1
    }
    
    func refreshSubtitleOverlay() {
        // VLC handles subtitle rendering automatically through native libass
        // No manual refresh needed
    }
    
    // MARK: - External Subtitles
    
    func loadExternalSubtitles(urls: [String], names: [String]? = nil, enforce: Bool = false) {
        guard let player = mediaPlayer, currentMedia != nil else { return }
        
        eventQueue.async { [weak self] in
            Logger.shared.log("VLCRenderer: Adding external subtitles count=\(urls.count)", type: "Info")
            for urlString in urls {
                if let url = URL(string: urlString) {
                    // enforce: true for local files so VLC auto-selects the subtitle track
                    let shouldEnforce = enforce || url.isFileURL
                    player.addPlaybackSlave(url, type: VLCMediaPlaybackSlaveType.subtitle, enforce: shouldEnforce)
                    Logger.shared.log("VLCRenderer: added playback slave subtitle=\(url.absoluteString) enforce=\(shouldEnforce)", type: "Info")
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.rendererDidChangeTracks(self)
            }
        }
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        currentSubtitleStyle = style
        logVLC("applySubtitleStyle visible=\(style.isVisible) font=\(String(format: "%.1f", style.fontSize)) stroke=\(String(format: "%.1f", style.strokeWidth))")
        eventQueue.async { [weak self] in
            guard let self else { return }

            if let media = self.currentMedia {
                self.applySubtitleStyleOptions(to: media)
            }

            // Best-effort live re-apply: toggle current subtitle track to force renderer refresh.
            if let player = self.mediaPlayer {
                let currentTrack = player.currentVideoSubTitleIndex
                if currentTrack >= 0 {
                    player.currentVideoSubTitleIndex = -1
                    player.currentVideoSubTitleIndex = currentTrack
                }
            }
        }
    }

    private func applySubtitleStyleOptions(to media: VLCMedia) {
        let foregroundHex = vlcHexRGB(currentSubtitleStyle.foregroundColor)
        let strokeHex = vlcHexRGB(currentSubtitleStyle.strokeColor)
        let fontSize = max(12, Int(round(currentSubtitleStyle.fontSize)))
        let outline = max(0, Int(round(currentSubtitleStyle.strokeWidth * 2.0)))

        media.addOption(":freetype-color=0x\(foregroundHex)")
        media.addOption(":freetype-outline-color=0x\(strokeHex)")
        media.addOption(":freetype-outline-thickness=\(outline)")
        media.addOption(":freetype-fontsize=\(fontSize)")
    }

    private func vlcHexRGB(_ color: UIColor) -> String {
        var r: CGFloat = 1
        var g: CGFloat = 1
        var b: CGFloat = 1
        var a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = max(0, min(255, Int(round(r * 255))))
        let gi = max(0, min(255, Int(round(g * 255))))
        let bi = max(0, min(255, Int(round(b * 255))))
        return String(format: "%02X%02X%02X", ri, gi, bi)
    }
    
    // MARK: - Event Handlers
    
    @objc private func mediaPlayerTimeChanged() {
        guard let player = mediaPlayer else { return }
        publishPlaybackProgress(from: player)
    }

    private func publishPlaybackProgress(from player: VLCMediaPlayer) {
        let progress = resolvedPlaybackProgress(from: player)
        let position = progress.position
        let duration = progress.duration
        let rawPosition = max(0, (player.time.value?.doubleValue ?? 0) / 1000.0)
        if duration.isFinite, duration > 0 {
            cachedDuration = max(cachedDuration, duration)
        }
        logProgressSnapshotIfNeeded(player: player, position: position, duration: duration)
        logPlaybackClockDiagnosticsIfNeeded(player: player, position: position)
        logSteadyPlaybackHeartbeatIfNeeded(player: player, position: position, duration: duration)
        let hasStartupSignal = hasUsablePlaybackSignal(player, position: position, duration: duration)

        if isPlaybackActive(player), hasStartupSignal, isPaused {
            isPaused = false
            logVLC("progress observed active playback while paused flag was true; clearing pause flag snapshot={\(playerSnapshot(player))}", type: "Progress")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didChangePause: false)
            }
        }

        // If we were waiting for duration to apply a pending seek, do it once duration is known.
        if duration > 0, let pending = pendingAbsoluteSeek {
            if pendingSeekRequiresPlaybackClock && rawPosition <= 0.05 {
                if !pendingSeekDelayLogged {
                    pendingSeekDelayLogged = true
                    logVLC("delaying pending seek until raw playback clock advances pending=\(secondsText(pending)) duration=\(secondsText(duration)) snapshot={\(playerSnapshot(player))}", type: "Progress")
                }
                cachedPosition = position
                clearLoadingState()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.renderer(self, didUpdatePosition: position, duration: duration)
                }
                return
            }
            let normalized = min(max(pending / duration, 0), 1)
            logVLC("applying pending seek from progress pending=\(secondsText(pending)) duration=\(secondsText(duration)) normalized=\(String(format: "%.5f", normalized))", type: "Progress")
            setNormalizedPosition(normalized, on: player)
            pendingAbsoluteSeek = nil
            pendingSeekRequiresPlaybackClock = false
            pendingSeekDelayLogged = false
            let seekPosition = min(max(0, pending), duration)
            cachedPosition = seekPosition
            if isLoading && hasStartupSignal {
                clearLoadingState()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didUpdatePosition: seekPosition, duration: duration)
            }
            return
        }

        cachedPosition = position

        // If we were marked loading but playback is progressing, clear loading state.
        if isLoading && hasStartupSignal {
            clearLoadingState()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didUpdatePosition: position, duration: duration)
        }
    }

    private func logProgressSnapshotIfNeeded(player: VLCMediaPlayer, position: Double, duration: Double) {
        let bucket = Int(max(0, position) / 10.0)
        if bucket != lastProgressLogBucket {
            lastProgressLogBucket = bucket
            logVLC("progress snapshot position=\(secondsText(position)) duration=\(secondsText(duration)) snapshot={\(playerSnapshot(player))}", type: "Progress")
        }

        let rawDuration = max(0, (player.media?.length.value?.doubleValue ?? 0) / 1000.0)
        let normalized = normalizedPosition(from: player)
        let anomaly: String?
        if position > 1.0 && duration <= 0 {
            anomaly = "position-advanced-duration-unknown"
        } else if rawDuration > 0 && cachedDuration > rawDuration + 30.0 {
            anomaly = "raw-duration-shrank raw=\(secondsText(rawDuration)) cached=\(secondsText(cachedDuration))"
        } else if normalized > 0.98 && duration > 0 && position < duration * 0.5 {
            anomaly = "normalized-near-end-but-position-low normalized=\(String(format: "%.4f", normalized))"
        } else {
            anomaly = nil
        }

        guard let anomaly else { return }
        let now = CACurrentMediaTime()
        if anomaly != lastProgressAnomalyKey || now - lastProgressAnomalyLogTime > 8.0 {
            lastProgressAnomalyKey = anomaly
            lastProgressAnomalyLogTime = now
            logVLC("progress anomaly \(anomaly) position=\(secondsText(position)) duration=\(secondsText(duration)) snapshot={\(playerSnapshot(player))}", type: "Error")
        }
    }

    private func resetPlaybackClockDiagnostics(reason: String, logIfEmpty: Bool = false) {
        let hadSamples = lastPlaybackClockSampleHostTime != nil
            || lastPlaybackClockSamplePosition != nil
            || lastProgressHostTime != nil
        lastPlaybackClockSampleHostTime = nil
        lastPlaybackClockSamplePosition = nil
        lastProgressHostTime = nil
        lastSlowPlaybackClockLogTime = 0
        lastBufferingWhileAdvancingLogTime = 0
        lastPositionRegressionLogTime = 0

        if hadSamples || logIfEmpty {
            logVLC("reset playback clock diagnostics reason=\(reason) hadSamples=\(hadSamples) safe={\(foregroundSafeSnapshot())}", type: "VLCCrashProbe")
        }
    }

    private func logPlaybackClockDiagnosticsIfNeeded(player: VLCMediaPlayer, position: Double) {
        guard isPlaybackActive(player) else {
            resetPlaybackClockDiagnostics(reason: "playback-inactive")
            return
        }

        let now = CACurrentMediaTime()
        guard let previousHostTime = lastPlaybackClockSampleHostTime,
              let previousPosition = lastPlaybackClockSamplePosition else {
            lastPlaybackClockSampleHostTime = now
            lastPlaybackClockSamplePosition = position
            return
        }

        let wallDelta = max(0, now - previousHostTime)
        guard wallDelta >= 1.0 else { return }

        let mediaDelta = position - previousPosition
        if mediaDelta < -1.0, now - lastPositionRegressionLogTime > 4.0 {
            lastPositionRegressionLogTime = now
            logVLC("playback clock regression previous=\(secondsText(previousPosition)) current=\(secondsText(position)) wallDelta=\(String(format: "%.2f", wallDelta)) snapshot={\(playerSnapshot(player))}", type: "VLCPlayback")
        }

        let expectedDelta = wallDelta * max(currentPlaybackSpeed, 0.1)
        if expectedDelta > 0.5 {
            let ratio = mediaDelta / expectedDelta
            if ratio < 0.55, now - lastSlowPlaybackClockLogTime > 4.0 {
                lastSlowPlaybackClockLogTime = now
                logVLC("playback clock slow mediaDelta=\(secondsText(mediaDelta)) expected=\(secondsText(expectedDelta)) ratio=\(String(format: "%.2f", ratio)) wallDelta=\(String(format: "%.2f", wallDelta)) snapshot={\(playerSnapshot(player))}", type: "VLCPlayback")
            }
        }

        if stateCode(player.state) == 2, mediaDelta > 0.1, now - lastBufferingWhileAdvancingLogTime > 8.0 {
            lastBufferingWhileAdvancingLogTime = now
            logVLC("state buffering while clock advances mediaDelta=\(secondsText(mediaDelta)) wallDelta=\(String(format: "%.2f", wallDelta)) snapshot={\(playerSnapshot(player))}", type: "VLCPlayback")
        }

        lastPlaybackClockSampleHostTime = now
        lastPlaybackClockSamplePosition = position
    }

    private func logSteadyPlaybackHeartbeatIfNeeded(player: VLCMediaPlayer, position: Double, duration: Double) {
        guard isPlaybackActive(player),
              hasUsablePlaybackSignal(player, position: position, duration: duration) else {
            return
        }

        let now = CACurrentMediaTime()
        guard now - lastSteadyPlaybackHeartbeatLogTime >= 20 else { return }
        lastSteadyPlaybackHeartbeatLogTime = now

        let normalized = normalizedPosition(from: player)
        let audioTrackId = Int(player.currentAudioTrackIndex)
        let subtitleTrackId = Int(player.currentVideoSubTitleIndex)
        let audioTrackCount = (player.audioTrackIndexes as? [Int])?.count ?? -1
        let subtitleTrackCount = (player.videoSubTitlesIndexes as? [Int])?.count ?? -1
        let mediaLength = max(0, (player.media?.length.value?.doubleValue ?? 0) / 1000.0)
        let proxyDiagnostics = VLCHeaderProxy.shared.diagnosticsSnapshot()

        logVLC("steady heartbeat gen=\(loadGeneration) running=\(isRunning) stopping=\(isStopping) position=\(secondsText(position))/\(secondsText(duration)) mediaLength=\(secondsText(mediaLength)) normalized=\(String(format: "%.5f", normalized)) audioTrack=\(audioTrackId)/\(audioTrackCount) subtitleTrack=\(subtitleTrackId)/\(subtitleTrackCount) proxy={\(proxyDiagnostics)} snapshot={\(playerSnapshot(player))}", type: "VLCCrashProbe")

        if now - lastSteadyDrawableHeartbeatLogTime >= 60 {
            lastSteadyDrawableHeartbeatLogTime = now
            logDrawableSnapshot("steady heartbeat")
        }
    }
    
    @objc private func mediaPlayerStateChanged() {
        guard let player = mediaPlayer else { return }
        
        let state = player.state
        let code = stateCode(state)
        if lastLoggedStateCode != code {
            lastLoggedStateCode = code
            logVLC("stateChanged \(describeState(state))(\(code)) snapshot={\(playerSnapshot(player))}", type: "Stream")
        }
        
        if isErrorState(state) {
            let urlString = currentURL?.absoluteString ?? "nil"
            let headerCount = currentHeaders?.count ?? 0
            logVLC("state error url=\(urlString) headers=\(headerCount) preset=\(currentPreset?.id.rawValue ?? "nil") snapshot={\(playerSnapshot(player))}", type: "Error")
        }
        
        if isPlaybackActive(player) {
            guard hasUsablePlaybackSignal(player) else {
                logVLC("state active without usable startup signal; keeping loading state snapshot={\(playerSnapshot(player))}", type: "Stream")
                return
            }
            let didChangePause = isPaused
            let didBecomeReadyToSeek = !isReadyToSeek
            isPaused = false
            isReadyToSeek = true
            clearLoadingState()
            
            if didChangePause || didBecomeReadyToSeek {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if didChangePause {
                        self.delegate?.renderer(self, didChangePause: false)
                    }
                    if didBecomeReadyToSeek {
                        self.delegate?.renderer(self, didBecomeReadyToSeek: true)
                    }
                }
            }
            
        } else if isVLCPlayerPausedState(state) {
            isPaused = true
            stopProgressPolling()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didChangePause: true)
            }
            
        } else if isLoadingState(state) {
            guard !isPlaybackActive(player) else {
                if hasUsablePlaybackSignal(player) {
                    clearLoadingState()
                } else {
                    logVLC("loading state ignored active playback without usable signal snapshot={\(playerSnapshot(player))}", type: "Stream")
                }
                return
            }
            isLoading = true
            scheduleLoadingSanityChecks()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didChangeLoading: true)
            }

        } else if isTerminalState(state) {
            isPaused = true
            isLoading = false
            stopProgressPolling()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didChangePause: true)
                self.delegate?.renderer(self, didChangeLoading: false)
            }
            if isErrorState(state) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.renderer(self, didFailWithError: "VLC playback error")
                }
            }
        }
    }

    private func clearLoadingState() {
        guard isLoading else { return }
        isLoading = false
        logVLC("clearLoadingState snapshot={\(playerSnapshot())}", type: "Stream")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didChangeLoading: false)
        }
    }

    private func scheduleLoadingSanityChecks() {
        let generation = loadGeneration
        let isProxyLoad = currentURL?.host == "127.0.0.1" || currentURL?.host == "localhost"
        let failureDelay = isProxyLoad ? 10.0 : 1.5
        let delays: [Double] = isProxyLoad ? [2.0, 5.0, 10.0] : [0.75, 1.5, 3.0]
        logVLC("scheduleLoadingSanityChecks generation=\(generation) proxy=\(isProxyLoad) snapshot={\(playerSnapshot())}", type: "Stream")
        for delay in delays {
            eventQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isLoading, let player = self.mediaPlayer else { return }
                guard self.loadGeneration == generation else {
                    self.logVLC("loading sanity skipped stale generation check=\(generation) current=\(self.loadGeneration)", type: "Stream")
                    return
                }

                let positionMs = player.time.value?.doubleValue ?? 0
                self.logVLC("loading sanity delay=\(String(format: "%.2f", delay)) generation=\(generation) proxy=\(isProxyLoad) positionMs=\(String(format: "%.0f", positionMs)) snapshot={\(self.playerSnapshot(player))}", type: "Stream")
                if self.hasUsablePlaybackSignal(player) {
                    self.clearLoadingState()
                } else if delay >= failureDelay, self.isTerminalState(player.state) {
                    self.isLoading = false
                    self.stopProgressPolling()
                    let message = "VLC could not start playback (state \(self.describeState(player.state)) at 0s)"
                    self.logVLC("startup failed: \(message) snapshot={\(self.playerSnapshot(player))}", type: "Error")
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.renderer(self, didChangeLoading: false)
                        self.delegate?.renderer(self, didFailWithError: message)
                    }
                }
            }
        }
    }

    private func startProgressPolling() {
        progressTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: eventQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning, let player = self.mediaPlayer else { return }
            self.publishPlaybackProgress(from: player)
        }
        progressTimer = timer
        timer.resume()
        logVLC("startProgressPolling snapshot={\(playerSnapshot())}", type: "Progress")
    }

    private func stopProgressPolling() {
        if progressTimer != nil {
            logVLC("stopProgressPolling snapshot={\(playerSnapshot())}", type: "Progress")
        }
        progressTimer?.cancel()
        progressTimer = nil
        lastProgressHostTime = nil
    }

    private func hasUsablePlaybackSignal(_ player: VLCMediaPlayer, position: Double? = nil, duration: Double? = nil) -> Bool {
        let rawPosition = max(0, (player.time.value?.doubleValue ?? 0) / 1000.0)
        let rawDuration = max(0, (player.media?.length.value?.doubleValue ?? 0) / 1000.0)
        if rawPosition > 0.05 { return true }
        if let position, position > 0.05 { return true }
        if rawDuration.isFinite, rawDuration >= minimumReliableDuration { return true }
        if let duration, duration.isFinite, duration >= minimumReliableDuration { return true }
        if cachedDuration.isFinite, cachedDuration >= minimumReliableDuration { return true }
        return false
    }

    private func resolvedPlaybackProgress(from player: VLCMediaPlayer) -> (position: Double, duration: Double) {
        let now = CACurrentMediaTime()
        let rawPosition = max(0, (player.time.value?.doubleValue ?? 0) / 1000.0)
        let rawDuration = max(0, (player.media?.length.value?.doubleValue ?? 0) / 1000.0)
        let normalized = normalizedPosition(from: player)
        let reportedDurationFitsPosition = rawPosition <= 0 || rawPosition <= rawDuration + 2.0
        let cachedDurationFitsPosition = rawPosition <= 0 || rawPosition <= cachedDuration + 2.0
        let reportedDurationIsReliable = rawDuration.isFinite && rawDuration >= minimumReliableDuration && reportedDurationFitsPosition
        let cachedDurationIsReliable = cachedDuration.isFinite && cachedDuration >= minimumReliableDuration && cachedDurationFitsPosition
        let duration: Double
        if reportedDurationIsReliable, cachedDurationIsReliable {
            duration = max(rawDuration, cachedDuration)
        } else if reportedDurationIsReliable {
            duration = rawDuration
        } else if cachedDurationIsReliable {
            duration = cachedDuration
        } else {
            duration = 0
        }
        let isPlaying = isPlaybackActive(player)

        let waitingForPendingSeekClock = pendingSeekRequiresPlaybackClock
            && pendingAbsoluteSeek != nil
            && rawPosition <= 0.05

        let position: Double
        if rawPosition > 0 {
            position = rawPosition
        } else if waitingForPendingSeekClock, let pending = pendingAbsoluteSeek {
            position = duration > 0 ? min(max(0, pending), duration) : max(0, pending)
        } else if normalized > 0, duration > 0 {
            position = normalized * duration
        } else if isPlaying, let lastProgressHostTime {
            let elapsed = max(0, now - lastProgressHostTime) * max(0.1, currentPlaybackSpeed)
            let advanced = cachedPosition + elapsed
            position = duration > 0 ? min(advanced, duration) : advanced
        } else {
            position = cachedPosition
        }

        if isPlaying {
            lastProgressHostTime = now
        } else {
            lastProgressHostTime = nil
        }

        return (max(0, position), duration)
    }
    
    @objc private func handleAppDidEnterBackground() {
        resetPlaybackClockDiagnostics(reason: "app-did-enter-background")
        logVLC("appDidEnterBackground snapshot={\(playerSnapshot())}", type: "Player")
        logDrawableSnapshot("appDidEnterBackground")
        scheduleDrawableSnapshots("appDidEnterBackground followup", delays: [0.5, 1.5])
        if isVLCHeaderProxyURL(currentURL) {
            needsProxyReloadAfterBackground = true
            logVLC("marked proxied stream for reload after background snapshot={\(playerSnapshot())}", type: "Stream")
        }

        Logger.shared.log("[VLCRenderer] entering background on stable VLCKitSPM path; pausing playback and keeping drawable attached", type: "Player")
        pausePlayback(forceSendToPlayer: true)
        logDrawableSnapshot("appDidEnterBackground stable SPM no detach")
    }

    @objc private func handleAppWillResignActive() {
        logVLC("appWillResignActive stable VLCKitSPM path snapshot={\(playerSnapshot())}", type: "Player")
    }
    
    @objc private func handleAppWillEnterForeground() {
        resetPlaybackClockDiagnostics(reason: "app-will-enter-foreground")
        logVLC("foreground will-enter begin safe={\(foregroundSafeSnapshot())}", type: "VLCCrashProbe")
        logForegroundSafeDrawableSnapshot("foreground will-enter begin")
        scheduleForegroundSafeDrawableSnapshots("foreground will-enter followup", delays: [0.10, 0.50, 1.50, 3.00])
        ensureAudioSessionActive()
        reattachRenderingView()
        logVLC("foreground will-enter submitted audio-session+reattach safe={\(foregroundSafeSnapshot())}", type: "VLCCrashProbe")
    }

    @objc private func handleAppDidBecomeActive() {
        resetPlaybackClockDiagnostics(reason: "app-did-become-active")
        logVLC("foreground did-become-active safe={\(foregroundSafeSnapshot())}", type: "VLCCrashProbe")
        logForegroundSafeDrawableSnapshot("foreground did-become-active")
        scheduleForegroundSafeDrawableSnapshots("foreground did-become-active followup", delays: [0.10, 0.75, 2.00])
    }

    // MARK: - State Properties
    
    var isPausedState: Bool {
        return isPaused
    }

    private func stateCode(_ state: VLCMediaPlayerState) -> Int {
        return Int(state.rawValue)
    }

    private func isPlayingState(_ state: VLCMediaPlayerState) -> Bool {
        return stateCode(state) == 5
    }

    private func isVLCPlayerPausedState(_ state: VLCMediaPlayerState) -> Bool {
        return stateCode(state) == 6
    }

    private func isLoadingState(_ state: VLCMediaPlayerState) -> Bool {
        let code = stateCode(state)
        return code == 1 || code == 2
    }

    private func isErrorState(_ state: VLCMediaPlayerState) -> Bool {
        return stateCode(state) == 4
    }

    private func isTerminalState(_ state: VLCMediaPlayerState) -> Bool {
        let code = stateCode(state)
        return code == 0 || code == 3 || code == 4
    }

    private func isPlayerActivelyPlaying(_ player: VLCMediaPlayer) -> Bool {
        return player.isPlaying
    }

    private func isPlaybackActive(_ player: VLCMediaPlayer) -> Bool {
        return isPlayerActivelyPlaying(player) || isPlayingState(player.state)
    }

    private func describeState(_ state: VLCMediaPlayerState) -> String {
        switch stateCode(state) {
        case 0: return "stopped"
        case 1: return "opening"
        case 2: return "buffering"
        case 3: return "ended"
        case 4: return "error"
        case 5: return "playing"
        case 6: return "paused"
        case 7: return "esAdded"
        default: return "unknown(\(stateCode(state)))"
        }
    }

    private func normalizedPosition(from player: VLCMediaPlayer) -> Double {
        return min(max(Double(player.position), 0), 1)
    }

    private func rawPlaybackPosition(from player: VLCMediaPlayer) -> Double {
        return max(0, (player.time.value?.doubleValue ?? 0) / 1000.0)
    }

    private func setNormalizedPosition(_ normalized: Double, on player: VLCMediaPlayer) {
        player.position = Float(min(max(normalized, 0), 1))
    }
}

#else  // Stub when VLCKit is not available

// Minimal stub to allow compilation when VLCKit is not installed
protocol VLCRendererDelegate: AnyObject {
    func renderer(_ renderer: VLCRenderer, didUpdatePosition position: Double, duration: Double)
    func renderer(_ renderer: VLCRenderer, didChangePause isPaused: Bool)
    func renderer(_ renderer: VLCRenderer, didChangeLoading isLoading: Bool)
    func renderer(_ renderer: VLCRenderer, didBecomeReadyToSeek: Bool)
    func renderer(_ renderer: VLCRenderer, didFailWithError message: String)
    func renderer(_ renderer: VLCRenderer, getSubtitleForTime time: Double) -> NSAttributedString?
    func renderer(_ renderer: VLCRenderer, getSubtitleStyle: Void) -> SubtitleStyle
    func renderer(_ renderer: VLCRenderer, subtitleTrackDidChange trackId: Int)
    func rendererDidChangeTracks(_ renderer: VLCRenderer)
}

final class VLCRenderer: PlayerRenderer {
    enum RendererError: Error {
        case vlcInitializationFailed
    }
    
    init(displayLayer: AVSampleBufferDisplayLayer) { }
    func getRenderingView() -> UIView { UIView() }
    func start() throws { throw RendererError.vlcInitializationFailed }
    func stop() { }
    func prepareInitialSeek(to seconds: Double?) { }
    func load(url: URL, with preset: PlayerPreset, headers: [String: String]?) { }
    func reloadCurrentItem() { }
    func applyPreset(_ preset: PlayerPreset) { }
    func play() { }
    func performanceOverlaySnapshot() -> String { "VLC unavailable" }
    func pausePlayback() { }
    func togglePause() { }
    func seek(to seconds: Double) { }
    func seek(by seconds: Double) { }
    func setSpeed(_ speed: Double) { }
    func getSpeed() -> Double { 1.0 }
    func getAudioTracksDetailed() -> [(Int, String, String)] { [] }
    func getAudioTracks() -> [(Int, String)] { [] }
    func getCurrentAudioTrackId() -> Int { -1 }
    func setAudioTrack(id: Int) { }
    func getSubtitleTracks() -> [(Int, String)] { [] }
    func getCurrentSubtitleTrackId() -> Int { -1 }
    func setSubtitleTrack(id: Int) { }
    func disableSubtitles() { }
    func refreshSubtitleOverlay() { }
    func loadExternalSubtitles(urls: [String], names: [String]? = nil, enforce: Bool = false) { }
    func applySubtitleStyle(_ style: SubtitleStyle) { }
    var isPausedState: Bool { true }
    weak var delegate: VLCRendererDelegate?
}

#endif  // canImport(VLCKitSPM)

