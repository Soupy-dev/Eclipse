//
//  VLCRenderer.swift
//  Luna
//
//  VLC player renderer using VLCKitSPM for GPU-accelerated playback
//  Provides same interface as MPVSoftwareRenderer for thermal optimization
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
    func renderer(_ renderer: VLCRenderer, didChangePictureInPictureAvailability isAvailable: Bool)
    func renderer(_ renderer: VLCRenderer, didChangePictureInPictureActive isActive: Bool)
    func rendererDidChangeTracks(_ renderer: VLCRenderer)
}

private extension Notification.Name {
    static let lunaVLCMediaPlayerTimeChanged = Notification.Name("VLCMediaPlayerTimeChanged")
    static let lunaVLCMediaPlayerStateChanged = Notification.Name("VLCMediaPlayerStateChanged")
}

final class VLCRenderer: NSObject {
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
    
    weak var delegate: VLCRendererDelegate?
    
    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        let containerView = UIView()
        let plainView = UIView()
        self.renderingContainerView = containerView
        self.plainVLCView = plainView
        self.activeVLCView = plainView
        super.init()
        _ = VLCRenderer.isPictureInPictureEnabledInDefaults()
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

    private static func isPictureInPictureEnabledInDefaults() -> Bool {
        if UserDefaults.standard.object(forKey: "vlcPiPEnabled") as? Bool != false {
            UserDefaults.standard.set(false, forKey: "vlcPiPEnabled")
        }
        return false
    }

    private func desiredRenderingViewForCurrentSetting() -> UIView {
        plainVLCView
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

    private func syncRenderingViewWithPictureInPictureSetting(reason: String, reassignPlayerDrawable: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.syncRenderingViewWithPictureInPictureSetting(reason: reason, reassignPlayerDrawable: reassignPlayerDrawable)
            }
            return
        }

        let desiredView = desiredRenderingViewForCurrentSetting()
        let oldMode = renderingModeDescription()
        if activeVLCView !== desiredView {
            activeVLCView = desiredView
            attachActiveRenderingViewToContainer(reason: reason)
            logVLC("switched VLC rendering view \(oldMode) -> \(renderingModeDescription()) reason=\(reason) setting=\(isPictureInPictureSettingEnabled)")
        } else {
            attachActiveRenderingViewToContainer(reason: reason)
            logVLC("kept VLC rendering view mode=\(renderingModeDescription()) reason=\(reason) setting=\(isPictureInPictureSettingEnabled)")
        }

        if reassignPlayerDrawable, isRunning, !isStopping {
            mediaPlayer?.drawable = activeVLCView
            logDrawableSnapshot("sync rendering view drawable reassigned")
        }
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
            return "player=nil pausedFlag=\(isPaused) loading=\(isLoading) ready=\(isReadyToSeek) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) pending=\(secondsText(pendingAbsoluteSeek)) pipAvailable=false pipActive=false app=\(appStateText())"
        }

        let rawPosition = (player.time.value?.doubleValue ?? 0) / 1000.0
        let rawDuration = (player.media?.length.value?.doubleValue ?? 0) / 1000.0
        return "state=\(describeState(player.state))(\(stateCode(player.state))) playing=\(isPlayerActivelyPlaying(player)) pausedFlag=\(isPaused) loading=\(isLoading) ready=\(isReadyToSeek) raw=\(secondsText(rawPosition))/\(secondsText(rawDuration)) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) pending=\(secondsText(pendingAbsoluteSeek)) speed=\(String(format: "%.2f", currentPlaybackSpeed)) pipAvailable=false pipActive=false app=\(appStateText())"
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

    private func scheduleDrawableSnapshots(_ event: String, delays: [TimeInterval] = [0.25, 1.0]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.logDrawableSnapshot("\(event) +\(String(format: "%.2f", delay))s")
            }
        }
    }

    fileprivate var isPictureInPictureSettingEnabled: Bool {
        Self.isPictureInPictureEnabledInDefaults()
    }

    private func reattachRenderingView() {
        logVLC("reattach drawable requested snapshot={\(playerSnapshot())}")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncRenderingViewWithPictureInPictureSetting(reason: "reattach", reassignPlayerDrawable: false)
            self.mediaPlayer?.drawable = self.activeVLCView
            self.activeVLCView.setNeedsLayout()
            self.activeVLCView.layoutIfNeeded()
            self.logDrawableSnapshot("reattach drawable applied")
            self.scheduleDrawableSnapshots("reattach drawable followup")
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
        
        do {
            logVLC("start initializing VLCMediaPlayer", type: "Stream")
            
            // Initialize VLC with proper options for video rendering
            mediaPlayer = VLCMediaPlayer()
            guard let mediaPlayer = mediaPlayer else {
                logVLC("start failed: VLCMediaPlayer returned nil", type: "Error")
                throw RendererError.vlcInitializationFailed
            }
            
            if Thread.isMainThread {
                syncRenderingViewWithPictureInPictureSetting(reason: "start", reassignPlayerDrawable: false)
            }

            // Render directly into the currently selected VLC drawable.
            mediaPlayer.drawable = activeVLCView
            
            // Set up event handling
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(mediaPlayerTimeChanged),
                name: .lunaVLCMediaPlayerTimeChanged,
                object: mediaPlayer
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(mediaPlayerStateChanged),
                name: .lunaVLCMediaPlayerStateChanged,
                object: mediaPlayer
            )
            
            // Observe app lifecycle
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
        isRunning = false
        isStopping = true
        loadGeneration += 1
        stopProgressPolling()
        delegate?.renderer(self, didChangePictureInPictureAvailability: false)
        delegate?.renderer(self, didChangePictureInPictureActive: false)

        eventQueue.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.removeObserver(self)

            if let player = self.mediaPlayer {
                player.stop()
                self.mediaPlayer = nil
            }

            self.currentMedia = nil
            self.isReadyToSeek = false
            self.isPaused = true
            self.isLoading = false
            self.lastLoggedStateCode = nil
            self.lastProgressLogBucket = -1
            self.lastProgressAnomalyKey = nil

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
        let headerKeys = (headers ?? [:]).keys.sorted().joined(separator: ",")
        logVLC("load begin url=\(url.absoluteString) preset=\(preset.id.rawValue) headers=\(headers?.count ?? 0)[\(headerKeys)] isLocal=\(url.isFileURL) preparedInitialSeek=\(secondsText(preparedInitialSeek))", type: "Stream")
        
        currentURL = url
        currentPreset = preset
        loadGeneration += 1
        let initialSeek = preparedInitialSeek
        preparedInitialSeek = nil
        cachedPosition = 0
        cachedDuration = 0
        pendingAbsoluteSeek = initialSeek
        lastProgressHostTime = nil
        lastLoggedStateCode = nil
        lastProgressLogBucket = -1
        lastProgressAnomalyKey = nil

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
            
            let media = VLCMedia(url: url)
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
            }

            // Tune caching and demuxer for local vs. remote playback
            if url.isFileURL {
                media.addOption(":file-caching=300")
                // Force MPEG-TS demuxer for .ts files (concatenated HLS segments)
                let ext = url.pathExtension.lowercased()
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
            self.updatePictureInPicturePlaybackState()
            self.logVLC("load submitted play snapshot={\(self.playerSnapshot(player))}", type: "Stream")
        }
    }
    
    func reloadCurrentItem() {
        guard let url = currentURL, let preset = currentPreset else { return }
        logVLC("reloadCurrentItem snapshot={\(playerSnapshot())}", type: "Stream")
        load(url: url, with: preset, headers: currentHeaders)
    }

    private func reloadCurrentItemPreservingPosition(_ position: Double) {
        guard let url = currentURL, let preset = currentPreset else { return }
        let resumePosition = max(0, position)
        let preservedDuration = cachedDuration
        logVLC("reloadCurrentItemPreservingPosition requested=\(secondsText(position)) resume=\(secondsText(resumePosition)) preservedDuration=\(secondsText(preservedDuration)) snapshot={\(playerSnapshot())}", type: "Stream")
        preparedInitialSeek = resumePosition
        pendingAbsoluteSeek = resumePosition
        load(url: url, with: preset, headers: currentHeaders)
        cachedPosition = resumePosition
        if preservedDuration >= minimumReliableDuration {
            cachedDuration = preservedDuration
        }
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

        // If VLC's media has stopped or ended (e.g. network timeout while backgrounded),
        // calling play() alone won't work — reload the stream and seek back.
        let state = player.state
        if isTerminalState(state), !isPlaybackActive(player) {
            Logger.shared.log("[VLCRenderer.play] Player in \(describeState(state)) state — reloading from position \(cachedPosition)s", type: "Stream")
            reloadAndSeekToLastPosition()
            return
        }

        player.play()
        startProgressPolling()
        if currentPlaybackSpeed != 1.0 {
            player.rate = Float(currentPlaybackSpeed)
        }
        updatePictureInPicturePlaybackState()
        logVLC("play submitted snapshot={\(playerSnapshot(player))}", type: "Stream")
        logDrawableSnapshot("play submitted")
    }

    /// Reload the current media and seek back to the last known position.
    /// Used to recover from stopped/ended state after background network drops.
    private func reloadAndSeekToLastPosition() {
        guard currentURL != nil, currentPreset != nil else { return }
        let savedPosition = cachedPosition
        logVLC("reloadAndSeekToLastPosition saved=\(secondsText(savedPosition)) snapshot={\(playerSnapshot())}", type: "Stream")
        reloadCurrentItemPreservingPosition(savedPosition)
    }
    
    func pausePlayback(forceSendToPlayer: Bool = false) {
        let player = mediaPlayer
        let shouldSendPause = player.map {
            forceSendToPlayer || isPlayerActivelyPlaying($0) || isPlayingState($0.state) || (!isPaused && !isVLCPlayerPausedState($0.state) && !isTerminalState($0.state))
        } ?? !isPaused
        logVLC("pause requested forceSend=\(forceSendToPlayer) shouldSendPause=\(shouldSendPause) snapshot={\(playerSnapshot(player))}", type: "Stream")
        logDrawableSnapshot("pause requested")
        isPaused = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didChangePause: true)
        }

        if shouldSendPause {
            player?.pause()
        }
        stopProgressPolling()
        updatePictureInPicturePlaybackState()
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
            logVLC("applySeek reloading terminal player instead of seeking stopped output target=\(secondsText(clamped)) snapshot={\(playerSnapshot(player))}", type: "Progress")
            reloadCurrentItemPreservingPosition(clamped)
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
            logVLC("applySeek used live duration normalized=\(String(format: "%.5f", normalized))", type: "Progress")
        } else if cachedDuration >= minimumReliableDuration {
            let normalized = min(max(clamped / cachedDuration, 0), 1)
            setNormalizedPosition(normalized, on: player)
            pendingAbsoluteSeek = clamped
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
        updatePictureInPicturePlaybackState()
        if refreshVideoOutput {
            refreshVideoOutputAfterSeek(player, shouldResumePlayback: !isPaused)
        } else {
            eventQueue.asyncAfter(deadline: .now() + 0.08) { [weak self, weak player] in
                guard let self, self.isRunning, !self.isStopping, let player else { return }
                self.clearLoadingState()
                self.publishPlaybackProgress(from: player)
                self.updatePictureInPicturePlaybackState()
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
            self.syncRenderingViewWithPictureInPictureSetting(reason: "seek refresh", reassignPlayerDrawable: false)
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
        logVLC("getAudioTracksDetailed count=\(result.count) current=\(getCurrentAudioTrackId()) names=\(result.map { "\($0.0):\($0.1)" }.joined(separator: " | "))")
        
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
        
        // VLC provides subtitle track info through the media player.
        if let subtitleIndexes = player.videoSubTitlesIndexes as? [Int],
           let subtitleNames = player.videoSubTitlesNames as? [String] {
            for (index, name) in zip(subtitleIndexes, subtitleNames) {
                result.append((index, name))
            }
        }
        logVLC("getSubtitleTracks count=\(result.count) current=\(getCurrentSubtitleTrackId()) names=\(result.map { "\($0.0):\($0.1)" }.joined(separator: " | "))")
        
        return result
    }
    
    func setSubtitleTrack(id: Int) {
        guard let player = mediaPlayer else { return }
        
        // Set track immediately - VLC property setters are thread-safe
        logVLC("setSubtitleTrack id=\(id) beforeCurrent=\(getCurrentSubtitleTrackId()) snapshot={\(playerSnapshot(player))}")
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
        logVLC("disableSubtitles beforeCurrent=\(getCurrentSubtitleTrackId()) snapshot={\(playerSnapshot(player))}")
        player.currentVideoSubTitleIndex = -1
    }
    
    func refreshSubtitleOverlay() {
        // VLC handles subtitle rendering automatically through native libass
        // No manual refresh needed
    }
    
    // MARK: - External Subtitles
    
    func loadExternalSubtitles(urls: [String], enforce: Bool = false) {
        guard let player = mediaPlayer else { return }
        
        eventQueue.async { [weak self] in
            self?.logVLC("loadExternalSubtitles count=\(urls.count) enforce=\(enforce) urls=\(urls.joined(separator: " | "))", type: "Info")
            for urlString in urls {
                if let url = URL(string: urlString) {
                    // enforce: true for local files so VLC auto-selects the subtitle track
                    let shouldEnforce = enforce || url.isFileURL
                    player.addPlaybackSlave(url, type: .subtitle, enforce: shouldEnforce)
                    self?.logVLC("added playback slave subtitle=\(url.absoluteString) enforce=\(shouldEnforce)", type: "Info")
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
    
    func getCurrentSubtitleTrackId() -> Int {
        guard let player = mediaPlayer else { return -1 }
        return Int(player.currentVideoSubTitleIndex)
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
        cachedPosition = position
        if duration.isFinite, duration > 0 {
            cachedDuration = max(cachedDuration, duration)
        }
        logProgressSnapshotIfNeeded(player: player, position: position, duration: duration)
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
            let normalized = min(max(pending / duration, 0), 1)
            logVLC("applying pending seek from progress pending=\(secondsText(pending)) duration=\(secondsText(duration)) normalized=\(String(format: "%.5f", normalized))", type: "Progress")
            setNormalizedPosition(normalized, on: player)
            pendingAbsoluteSeek = nil
        }

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
                updatePictureInPicturePlaybackState()
                return
            }
            isPaused = false
            isReadyToSeek = true
            clearLoadingState()
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didChangePause: false)
                self.delegate?.renderer(self, didBecomeReadyToSeek: true)
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
                updatePictureInPicturePlaybackState()
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
        updatePictureInPicturePlaybackState()
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

        let position: Double
        if rawPosition > 0 {
            position = rawPosition
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
        logVLC("appDidEnterBackground snapshot={\(playerSnapshot())}", type: "Player")
        logDrawableSnapshot("appDidEnterBackground")
        scheduleDrawableSnapshots("appDidEnterBackground followup", delays: [0.5, 1.5])

        Logger.shared.log("[VLCRenderer] entering background on stable VLCKitSPM path; pausing playback and keeping drawable attached", type: "Player")
        pausePlayback(forceSendToPlayer: true)
        logDrawableSnapshot("appDidEnterBackground stable SPM no detach")
    }

    @objc private func handleAppWillResignActive() {
        logVLC("appWillResignActive stable VLCKitSPM path snapshot={\(playerSnapshot())}", type: "Player")
    }
    
    @objc private func handleAppWillEnterForeground() {
        logVLC("appWillEnterForeground snapshot={\(playerSnapshot())}", type: "Player")
        logDrawableSnapshot("appWillEnterForeground")
        scheduleDrawableSnapshots("appWillEnterForeground followup")
        ensureAudioSessionActive()
        reattachRenderingView()
    }

    @objc private func handleAppDidBecomeActive() {
        logVLC("appDidBecomeActive snapshot={\(playerSnapshot())}", type: "Player")
    }

    // MARK: - Picture in Picture

    var isPictureInPictureAvailable: Bool {
        false
    }

    var isPictureInPictureActive: Bool {
        false
    }

    @discardableResult
    func startPictureInPicture() -> Bool {
        Logger.shared.log("[VLCRenderer] PiP start ignored: stable VLCKitSPM path does not expose VLC PiP", type: "Player")
        return false
    }

    func stopPictureInPicture() {
        // No-op: VLC PiP is unavailable on the stable VLCKitSPM path.
    }

    func updatePictureInPicturePlaybackState() {
        // No-op: VLC PiP is unavailable on the stable VLCKitSPM path.
    }

    func handlePictureInPictureSettingChanged() {
        logVLC("handlePictureInPictureSettingChanged ignored; VLC PiP is disabled on stable VLCKitSPM path", type: "Player")
        if UserDefaults.standard.object(forKey: "vlcPiPEnabled") as? Bool != false {
            UserDefaults.standard.set(false, forKey: "vlcPiPEnabled")
        }
        delegate?.renderer(self, didChangePictureInPictureAvailability: false)
        delegate?.renderer(self, didChangePictureInPictureActive: false)
        syncRenderingViewWithPictureInPictureSetting(reason: "PiP disabled stable SPM", reassignPlayerDrawable: true)
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
    func renderer(_ renderer: VLCRenderer, didChangePictureInPictureAvailability isAvailable: Bool)
    func renderer(_ renderer: VLCRenderer, didChangePictureInPictureActive isActive: Bool)
    func rendererDidChangeTracks(_ renderer: VLCRenderer)
}

final class VLCRenderer {
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
    func loadExternalSubtitles(urls: [String], enforce: Bool = false) { }
    func applySubtitleStyle(_ style: SubtitleStyle) { }
    var isPictureInPictureAvailable: Bool { false }
    var isPictureInPictureActive: Bool { false }
    @discardableResult
    func startPictureInPicture() -> Bool { false }
    func stopPictureInPicture() { }
    func updatePictureInPicturePlaybackState() { }
    var isPausedState: Bool { true }
    weak var delegate: VLCRendererDelegate?
}

#endif  // canImport(VLCKitSPM)

