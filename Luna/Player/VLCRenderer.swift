//
//  VLCRenderer.swift
//  Luna
//
//  VLC player renderer using VLCKit for GPU-accelerated playback
//  Provides same interface as MPVSoftwareRenderer for thermal optimization
//
//  DEPENDENCY: VLCKit 4.0.0a19+ via CocoaPods for native VideoLAN PiP.

import UIKit
import AVFoundation

// MARK: - Compatibility: VLC renderer is iOS-only (tvOS uses MPV)
#if (canImport(VLCKit) || canImport(VLCKitSPM)) && os(iOS)
import ObjectiveC
#if canImport(VLCKit)
import VLCKit
#else
import VLCKitSPM
#endif

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

private typealias NativeVLCPiPReadyBlock = @convention(block) (AnyObject) -> Void
private typealias NativeVLCPiPSeekCompletion = @convention(block) () -> Void
private typealias NativeVLCPiPStateChangeBlock = @convention(block) (Bool) -> Void

private extension Notification.Name {
    static let lunaVLCMediaPlayerTimeChanged = Notification.Name("VLCMediaPlayerTimeChanged")
    static let lunaVLCMediaPlayerStateChanged = Notification.Name("VLCMediaPlayerStateChanged")
}

private final class VLCPictureInPictureDrawableView: UIView {
    weak var renderer: VLCRenderer?

    override func conforms(to aProtocol: Protocol) -> Bool {
        let protocolName = String(cString: protocol_getName(aProtocol))
        if protocolName == "VLCDrawable" ||
            protocolName == "VLCPictureInPictureDrawable" ||
            protocolName == "VLCPictureInPictureMediaControlling" {
            return true
        }
        return super.conforms(to: aProtocol)
    }

    @objc(mediaController)
    func mediaController() -> AnyObject {
        return renderer?.nativePictureInPictureMediaController() ?? self
    }

    @objc(pictureInPictureReady)
    func pictureInPictureReady() -> NativeVLCPiPReadyBlock {
        return { [weak self] controller in
            self?.renderer?.handleNativePictureInPictureControllerReady(controller)
        }
    }

    @objc(canStartPictureInPictureAutomaticallyFromInline)
    func canStartPictureInPictureAutomaticallyFromInline() -> Bool {
        return true
    }

    @objc(play)
    func playFromPictureInPicture() {
        renderer?.play()
    }

    @objc(pause)
    func pauseFromPictureInPicture() {
        renderer?.pausePlayback()
    }

    @objc(seekBy:)
    func seekBy(_ offset: Int64) {
        renderer?.seekFromPictureInPicture(byMilliseconds: offset, completion: nil)
    }

    @objc(seekBy:completion:)
    func seekBy(_ offset: Int64, completion: NativeVLCPiPSeekCompletion?) {
        renderer?.seekFromPictureInPicture(byMilliseconds: offset, completion: completion)
    }

    @objc(seekBy:completionHandler:)
    func seekBy(_ offset: Int64, completionHandler: NativeVLCPiPSeekCompletion?) {
        renderer?.seekFromPictureInPicture(byMilliseconds: offset, completion: completionHandler)
    }

    @objc(mediaTime)
    func mediaTime() -> Int64 {
        return renderer?.nativePictureInPictureMediaTime ?? 0
    }

    @objc(mediaLength)
    func mediaLength() -> Int64 {
        return renderer?.nativePictureInPictureMediaLength ?? 0
    }

    @objc(isMediaSeekable)
    func isMediaSeekable() -> Bool {
        return renderer?.nativePictureInPictureMediaSeekable ?? false
    }

    @objc(isMediaPlaying)
    func isMediaPlaying() -> Bool {
        return renderer?.nativePictureInPictureMediaPlaying ?? false
    }
}

final class VLCRenderer: NSObject {
    enum RendererError: Error {
        case vlcInitializationFailed
        case mediaCreationFailed
    }
    
    private let displayLayer: AVSampleBufferDisplayLayer
    private let eventQueue = DispatchQueue(label: "vlc.renderer.events", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "vlc.renderer.state", attributes: .concurrent)
    
    // VLC rendering container - uses OpenGL rendering
    private let vlcView: VLCPictureInPictureDrawableView
    
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
    private let minimumReliableDuration: Double = 5.0
    private var currentURL: URL?
    private var currentHeaders: [String: String]?
    private var currentPreset: PlayerPreset?
    private var isRunning = false
    private var isStopping = false
    private var currentPlaybackSpeed: Double = 1.0

    private var currentSubtitleStyle: SubtitleStyle = .default
    private var nativePiPController: AnyObject?
    private var nativePiPStateChangeHandler: NativeVLCPiPStateChangeBlock?
    private var nativePiPStartRequested = false
    private var nativePiPActive = false
    private var nativePiPAvailable = false
    private var nativePiPBlockedSeekDeadline: Date?
    private var nativePiPMediaControllerMode: String?
    private var wasPausedBeforeBackground = true
    private var backgroundedPosition: Double?
    private var foregroundRestoreGeneration = 0
    private var lastLoggedStateCode: Int?
    private var lastProgressLogBucket = -1
    private var lastProgressAnomalyKey: String?
    private var lastProgressAnomalyLogTime: CFTimeInterval = 0
    private var lastPiPPlaybackStateLogKey: String?
    private var lastPiPMediaQueryLogTimes: [String: CFTimeInterval] = [:]
    private var lastNativePiPControlCapabilityLogKey: String?
    
    weak var delegate: VLCRendererDelegate?
    
    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        // Create a UIView container that VLC will render into and newer VLCKit can use for PiP.
        self.vlcView = VLCPictureInPictureDrawableView()
        super.init()
        self.vlcView.renderer = self
        setupVLCView()
    }
    
    deinit {
        stop()
    }
    
    // MARK: - View Setup
    
    private func setupVLCView() {
        vlcView.backgroundColor = .black
        // Prefer aspect-fit semantics to keep full frame visible; rely on black bars
        vlcView.contentMode = .scaleAspectFit
        vlcView.layer.contentsGravity = .resizeAspect
        vlcView.layer.isOpaque = true
        vlcView.clipsToBounds = true
        vlcView.isUserInteractionEnabled = false  // Allow touches to pass through to controls
        logVLC("setup view contentMode=\(vlcView.contentMode.rawValue) gravity=\(vlcView.layer.contentsGravity.rawValue)")
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
            return "player=nil pausedFlag=\(isPaused) loading=\(isLoading) ready=\(isReadyToSeek) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) pending=\(secondsText(pendingAbsoluteSeek)) pipAvailable=\(nativePiPAvailable) pipActive=\(nativePiPActive) pipRequested=\(nativePiPStartRequested) app=\(appStateText())"
        }

        let rawPosition = (player.time.value?.doubleValue ?? 0) / 1000.0
        let rawDuration = (player.media?.length.value?.doubleValue ?? 0) / 1000.0
        return "state=\(describeState(player.state))(\(stateCode(player.state))) playing=\(isPlayerActivelyPlaying(player)) pausedFlag=\(isPaused) loading=\(isLoading) ready=\(isReadyToSeek) raw=\(secondsText(rawPosition))/\(secondsText(rawDuration)) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) pending=\(secondsText(pendingAbsoluteSeek)) speed=\(String(format: "%.2f", currentPlaybackSpeed)) pipAvailable=\(nativePiPAvailable) pipActive=\(nativePiPActive) pipRequested=\(nativePiPStartRequested) pipMode=\(nativePiPMediaControllerMode ?? "nil") app=\(appStateText())"
    }

    private func logDrawableSnapshot(_ event: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let bounds = self.vlcView.bounds
            let superBounds = self.vlcView.superview?.bounds ?? .zero
            self.logVLC("\(event) drawable hidden=\(self.vlcView.isHidden) alpha=\(String(format: "%.2f", self.vlcView.alpha)) bounds=\(String(format: "%.0fx%.0f", bounds.width, bounds.height)) super=\(String(format: "%.0fx%.0f", superBounds.width, superBounds.height)) snapshot={\(self.playerSnapshot())}")
        }
    }

    private func reattachRenderingView() {
        logVLC("reattach drawable requested snapshot={\(playerSnapshot())}")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mediaPlayer?.drawable = self.vlcView
            self.vlcView.setNeedsLayout()
            self.vlcView.layoutIfNeeded()
            self.logDrawableSnapshot("reattach drawable applied")
        }
    }

    private func recoverRenderingViewAfterPictureInPictureStop(reloadMedia: Bool = false) {
        guard isRunning, !isStopping else { return }
        let restorePosition = cachedPosition
        logVLC("recover rendering view reloadMedia=\(reloadMedia) restore=\(secondsText(restorePosition)) snapshot={\(playerSnapshot())}")

        ensureAudioSessionActive()
        reattachRenderingView()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.isRunning, !self.isStopping else { return }
            self.mediaPlayer?.drawable = self.vlcView
            self.vlcView.isHidden = false
            self.vlcView.alpha = 1
            self.vlcView.superview?.setNeedsLayout()
            self.vlcView.superview?.layoutIfNeeded()
            self.vlcView.setNeedsLayout()
            self.vlcView.layoutIfNeeded()
            self.logDrawableSnapshot("recover rendering view layout pass")
        }

        eventQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isRunning, !self.isStopping, let player = self.mediaPlayer else { return }
            self.logVLC("recover rendering view playback check snapshot={\(self.playerSnapshot(player))}")
            if self.isPlaybackActive(player) || (!self.isPaused && !self.isTerminalState(player.state)) {
                self.startProgressPolling()
                self.clearLoadingState()
            }
            self.publishPlaybackProgress(from: player)
        }

        if reloadMedia {
            eventQueue.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.isRunning, !self.isStopping else { return }
                guard UIApplication.shared.applicationState != .background else { return }
                Logger.shared.log("[VLCRenderer.PiP] reloading VLC output after blocked native PiP seek", type: "Player")
                self.reloadCurrentItemPreservingPosition(restorePosition)
            }
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
        logVLC("getRenderingView snapshot={\(playerSnapshot())}")
        return vlcView
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
            
            // Render directly into the VLC view (stable video output)
            mediaPlayer.drawable = vlcView
            
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
        stopProgressPolling()
        teardownNativePictureInPicture()

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
            
            guard let media = VLCMedia(url: url) else {
                Logger.shared.log("[VLCRenderer.load] ERROR: VLCMedia could not be created for \(url.absoluteString)", type: "Error")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.renderer(self, didChangeLoading: false)
                    self.delegate?.renderer(self, didFailWithError: "VLC could not load this media")
                }
                return
            }
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
            player.drawable = self.vlcView
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
        logVLC("reloadCurrentItemPreservingPosition requested=\(secondsText(position)) resume=\(secondsText(resumePosition)) snapshot={\(playerSnapshot())}", type: "Stream")
        preparedInitialSeek = resumePosition
        pendingAbsoluteSeek = resumePosition
        load(url: url, with: preset, headers: currentHeaders)
    }
    
    func applyPreset(_ preset: PlayerPreset) {
        currentPreset = preset
        logVLC("applyPreset \(preset.id.rawValue) snapshot={\(playerSnapshot())}")
        // VLC doesn't require preset application like mpv does
        // Presets are mainly for video output configuration which VLC handles automatically
    }
    
    func play() {
        logVLC("play requested snapshot={\(playerSnapshot())}", type: "Stream")
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
        if isTerminalState(state) {
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
    }

    /// Reload the current media and seek back to the last known position.
    /// Used to recover from stopped/ended state after background network drops.
    private func reloadAndSeekToLastPosition() {
        guard let url = currentURL, let preset = currentPreset else { return }
        let savedPosition = cachedPosition
        logVLC("reloadAndSeekToLastPosition saved=\(secondsText(savedPosition)) snapshot={\(playerSnapshot())}", type: "Stream")
        load(url: url, with: preset, headers: currentHeaders)
        if savedPosition > 0 {
            pendingAbsoluteSeek = savedPosition
        }
    }
    
    func pausePlayback() {
        let player = mediaPlayer
        let shouldSendPause = player.map {
            isPlayerActivelyPlaying($0) || isPlayingState($0.state) || (!isPaused && !isVLCPlayerPausedState($0.state) && !isTerminalState($0.state))
        } ?? !isPaused
        logVLC("pause requested shouldSendPause=\(shouldSendPause) snapshot={\(playerSnapshot(player))}", type: "Stream")
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

    fileprivate func seekFromPictureInPicture(byMilliseconds offset: Int64, completion: NativeVLCPiPSeekCompletion?) {
        eventQueue.async { [weak self] in
            guard let self, let player = self.mediaPlayer else {
                DispatchQueue.main.async {
                    completion?()
                }
                return
            }

            let duration = self.reliableDuration(from: player)
            guard duration >= self.minimumReliableDuration else {
                Logger.shared.log("[VLCRenderer.PiP] seek ignored: duration unavailable offsetMs=\(offset) snapshot={\(self.playerSnapshot(player))}", type: "Player")
                self.updatePictureInPicturePlaybackState()
                DispatchQueue.main.async {
                    completion?()
                }
                return
            }

            let currentPosition = self.resolvedPlaybackProgress(from: player).position
            let target = currentPosition + (Double(offset) / 1000.0)
            let clampedTarget = min(max(0, target), max(0, duration - 0.1))
            Logger.shared.log("[VLCRenderer.PiP] seek requested offsetMs=\(offset) current=\(self.secondsText(currentPosition)) target=\(self.secondsText(target)) clamped=\(self.secondsText(clampedTarget))", type: "Player")
            self.applySeek(to: clampedTarget, on: player, refreshVideoOutput: false)
            self.finishPictureInPictureSeek(target: clampedTarget, completion: completion)
        }
    }

    private func applySeek(to seconds: Double, on player: VLCMediaPlayer, refreshVideoOutput: Bool = true) {
        let duration = reliableDuration(from: player)
        let upperBound = duration >= minimumReliableDuration ? max(0, duration - 0.1) : Double.greatestFiniteMagnitude
        let clamped = min(max(0, seconds), upperBound)
        let before = resolvedPlaybackProgress(from: player).position
        logVLC("applySeek begin requested=\(secondsText(seconds)) current=\(secondsText(before)) clamped=\(secondsText(clamped)) reliableDuration=\(secondsText(duration)) cachedDuration=\(secondsText(cachedDuration)) paused=\(isPaused) refreshVideoOutput=\(refreshVideoOutput)", type: "Progress")

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
                self.logVLC("applySeek PiP follow-up snapshot={\(self.playerSnapshot(player))}", type: "Progress")
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didUpdatePosition: clamped, duration: max(duration, self.cachedDuration))
        }
        logVLC("applySeek end snapshot={\(playerSnapshot(player))}", type: "Progress")
    }

    private func finishPictureInPictureSeek(target: Double, completion: NativeVLCPiPSeekCompletion?, attempt: Int = 0) {
        guard let completion else { return }

        eventQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion()
                }
                return
            }

            let observedPosition = self.mediaPlayer.flatMap { self.observedSeekCompletionPosition(from: $0) }
            let position = observedPosition ?? self.cachedPosition
            let isCloseEnough = observedPosition != nil && abs(position - target) <= 1.5
            let shouldFinish = isCloseEnough || attempt >= 8

            if shouldFinish {
                self.logVLC("PiP seek completion target=\(self.secondsText(target)) position=\(self.secondsText(position)) attempt=\(attempt) closeEnough=\(isCloseEnough)", type: "Player")
                self.updatePictureInPicturePlaybackState()
                DispatchQueue.main.async {
                    completion()
                }
            } else {
                self.finishPictureInPictureSeek(target: target, completion: completion, attempt: attempt + 1)
            }
        }
    }

    private func observedSeekCompletionPosition(from player: VLCMediaPlayer) -> Double? {
        let rawPosition = max(0, (player.time.value?.doubleValue ?? 0) / 1000.0)
        if rawPosition > 0 {
            return rawPosition
        }

        let duration = reliableDuration(from: player)
        let normalized = normalizedPosition(from: player)
        if duration >= minimumReliableDuration, normalized > 0 {
            return normalized * duration
        }

        return nil
    }

    private func refreshVideoOutputAfterSeek(_ player: VLCMediaPlayer, shouldResumePlayback: Bool) {
        logVLC("refreshVideoOutputAfterSeek shouldResume=\(shouldResumePlayback) snapshot={\(playerSnapshot(player))}", type: "Progress")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, !self.isStopping else { return }
            self.mediaPlayer?.drawable = self.vlcView
            self.vlcView.isHidden = false
            self.vlcView.alpha = 1
            self.vlcView.superview?.setNeedsLayout()
            self.vlcView.superview?.layoutIfNeeded()
            self.vlcView.setNeedsLayout()
            self.vlcView.layoutIfNeeded()
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
            } else {
                self.refreshPausedVideoFrameIfPossible(player)
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
        
        let audioTrackIndexes = vlcIntArray(from: player, key: "audioTrackIndexes")
        let audioTrackNames = vlcStringArray(from: player, key: "audioTrackNames")
        // VLCKit doesn't expose language codes publicly here; rely on name parsing.
        for (index, name) in zip(audioTrackIndexes, audioTrackNames) {
            let code = guessLanguageCode(from: name)
            result.append((index, name, code))
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
        setVLCInt(id, on: player, key: "currentAudioTrackIndex")
        
        // Notify delegates on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.rendererDidChangeTracks(self)
        }
    }
    
    func getCurrentAudioTrackId() -> Int {
        guard let player = mediaPlayer else { return -1 }
        return vlcInt(from: player, key: "currentAudioTrackIndex", fallback: -1)
    }

    
    // MARK: - Subtitle Track Controls
    
    func getSubtitleTracks() -> [(Int, String)] {
        guard let player = mediaPlayer else { return [] }
        
        var result: [(Int, String)] = []
        
        let subtitleIndexes = vlcIntArray(from: player, key: "videoSubTitlesIndexes")
        let subtitleNames = vlcStringArray(from: player, key: "videoSubTitlesNames")
        for (index, name) in zip(subtitleIndexes, subtitleNames) {
            result.append((index, name))
        }
        logVLC("getSubtitleTracks count=\(result.count) current=\(getCurrentSubtitleTrackId()) names=\(result.map { "\($0.0):\($0.1)" }.joined(separator: " | "))")
        
        return result
    }
    
    func setSubtitleTrack(id: Int) {
        guard let player = mediaPlayer else { return }
        
        // Set track immediately - VLC property setters are thread-safe
        logVLC("setSubtitleTrack id=\(id) beforeCurrent=\(getCurrentSubtitleTrackId()) snapshot={\(playerSnapshot(player))}")
        setVLCInt(id, on: player, key: "currentVideoSubTitleIndex")
        
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
        setVLCInt(-1, on: player, key: "currentVideoSubTitleIndex")
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
                    let subtitleSlaveType = VLCMediaPlaybackSlaveType(rawValue: 0)!
                    player.addPlaybackSlave(url, type: subtitleSlaveType, enforce: shouldEnforce)
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
                let currentTrack = self.vlcInt(from: player, key: "currentVideoSubTitleIndex", fallback: -1)
                if currentTrack >= 0 {
                    self.setVLCInt(-1, on: player, key: "currentVideoSubTitleIndex")
                    self.setVLCInt(currentTrack, on: player, key: "currentVideoSubTitleIndex")
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
        return vlcInt(from: player, key: "currentVideoSubTitleIndex", fallback: -1)
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

        if isPlaybackActive(player), isPaused {
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

        if nativePiPActive || nativePiPStartRequested {
            updatePictureInPicturePlaybackState()
        }

        // If we were marked loading but playback is progressing, clear loading state.
        if isLoading && (position > 0 || isPlaybackActive(player)) {
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
                clearLoadingState()
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
        logVLC("scheduleLoadingSanityChecks snapshot={\(playerSnapshot())}", type: "Stream")
        for delay in [0.75, 1.5, 3.0] {
            eventQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isLoading, let player = self.mediaPlayer else { return }

                let positionMs = player.time.value?.doubleValue ?? 0
                self.logVLC("loading sanity delay=\(String(format: "%.2f", delay)) positionMs=\(String(format: "%.0f", positionMs)) snapshot={\(self.playerSnapshot(player))}", type: "Stream")
                if positionMs > 0 || self.isPlaybackActive(player) {
                    self.clearLoadingState()
                } else if delay >= 1.5, self.isTerminalState(player.state) {
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
        let isPlaying = isPlaybackActive(player) || (!isPaused && !isLoading)

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
        let player = mediaPlayer
        let pausedForBackground = player.map { player in
            (isPaused || isVLCPlayerPausedState(player.state)) && !isPlayerActivelyPlaying(player)
        } ?? isPaused
        wasPausedBeforeBackground = pausedForBackground
        backgroundedPosition = cachedPosition
        logVLC("appDidEnterBackground pausedForBackground=\(pausedForBackground) backgroundedPosition=\(secondsText(backgroundedPosition)) snapshot={\(playerSnapshot(player))}", type: "Player")

        if pausedForBackground {
            Logger.shared.log("[VLCRenderer.PiP] entering background while paused; preserving paused video output", type: "Player")
            isPaused = true
            stopProgressPolling()
            updatePictureInPicturePlaybackState()
            return
        }

        let pipEnabled = UserDefaults.standard.object(forKey: "vlcPiPEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "vlcPiPEnabled")

        guard pipEnabled else {
            Logger.shared.log("[VLCRenderer.PiP] entering background with native VLC PiP disabled", type: "Player")
            if !isPaused {
                pausePlayback()
            }
            return
        }

        if !isPaused, isPictureInPictureAvailable {
            Logger.shared.log("[VLCRenderer.PiP] entering background; starting native VLC PiP", type: "Player")
            if startPictureInPicture() {
                return
            }
        }

        Logger.shared.log("[VLCRenderer.PiP] entering background without native VLC PiP", type: "Player")
        if !isPaused {
            pausePlayback()
        }
    }
    
    @objc private func handleAppWillEnterForeground() {
        logVLC("appWillEnterForeground snapshot={\(playerSnapshot())}", type: "Player")
        if isPictureInPictureActive {
            Logger.shared.log("[VLCRenderer.PiP] returning to foreground; stopping native VLC PiP", type: "Player")
            stopPictureInPicture()
        }
        restoreVideoAfterForeground()
        scheduleForegroundVideoRestoreFollowUp()
    }

    @objc private func handleAppDidBecomeActive() {
        guard !isPictureInPictureActive else { return }
        logVLC("appDidBecomeActive snapshot={\(playerSnapshot())}", type: "Player")
        restoreVideoAfterForeground()
    }

    private func scheduleForegroundVideoRestoreFollowUp() {
        foregroundRestoreGeneration += 1
        let generation = foregroundRestoreGeneration
        logVLC("scheduleForegroundVideoRestoreFollowUp generation=\(generation)", type: "Player")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.foregroundRestoreGeneration == generation else { return }
            self.restoreVideoAfterForeground()
        }
    }

    private func restoreVideoAfterForeground() {
        guard isRunning, !isStopping else { return }
        guard UIApplication.shared.applicationState != .background else { return }
        logVLC("restoreVideoAfterForeground wasPausedBeforeBackground=\(wasPausedBeforeBackground) isPaused=\(isPaused) snapshot={\(playerSnapshot())}", type: "Player")
        // Re-activate the audio session that iOS may have deactivated during background.
        ensureAudioSessionActive()
        reattachRenderingView()
        if wasPausedBeforeBackground || isPaused {
            restorePausedVideoAfterForeground()
        } else {
            recoverActiveVideoAfterForeground()
        }
    }

    private func recoverActiveVideoAfterForeground() {
        logVLC("recoverActiveVideoAfterForeground snapshot={\(playerSnapshot())}", type: "Player")
        recoverRenderingViewAfterPictureInPictureStop(reloadMedia: false)
        eventQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.isRunning, !self.isStopping, let player = self.mediaPlayer, !self.isPaused else { return }
            self.ensureAudioSessionActive()
            player.play()
            if self.currentPlaybackSpeed != 1.0 {
                player.rate = Float(self.currentPlaybackSpeed)
            }
            self.startProgressPolling()
            self.clearLoadingState()
            self.updatePictureInPicturePlaybackState()
            self.publishPlaybackProgress(from: player)
            self.logVLC("recoverActiveVideoAfterForeground follow-up snapshot={\(self.playerSnapshot(player))}", type: "Player")
        }
    }

    private func restorePausedVideoAfterForeground() {
        let restorePosition = backgroundedPosition ?? cachedPosition
        logVLC("restorePausedVideoAfterForeground restorePosition=\(secondsText(restorePosition)) snapshot={\(playerSnapshot())}", type: "Player")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mediaPlayer?.drawable = self.vlcView
            self.vlcView.isHidden = false
            self.vlcView.alpha = 1
            self.vlcView.superview?.setNeedsLayout()
            self.vlcView.superview?.layoutIfNeeded()
            self.vlcView.setNeedsLayout()
            self.vlcView.layoutIfNeeded()
            self.delegate?.renderer(self, didChangePause: true)
            if restorePosition > 0 {
                self.delegate?.renderer(self, didUpdatePosition: restorePosition, duration: self.cachedDuration)
            }
        }

        eventQueue.async { [weak self] in
            guard let self, let player = self.mediaPlayer else { return }

            if restorePosition > 0 {
                let currentPosition = self.resolvedPlaybackProgress(from: player).position
                if abs(currentPosition - restorePosition) > 0.75 {
                    let durationSec = self.reliableDuration(from: player)
                    if durationSec >= self.minimumReliableDuration {
                        let normalized = min(max(restorePosition / durationSec, 0), 1)
                        self.setNormalizedPosition(normalized, on: player)
                        self.cachedDuration = max(self.cachedDuration, durationSec)
                    } else if self.cachedDuration >= self.minimumReliableDuration {
                        let normalized = min(max(restorePosition / self.cachedDuration, 0), 1)
                        self.setNormalizedPosition(normalized, on: player)
                    } else {
                        self.pendingAbsoluteSeek = restorePosition
                    }
                }
                self.cachedPosition = restorePosition
            }

            if self.isPlayerActivelyPlaying(player) || self.isPlayingState(player.state) {
                player.pause()
            }

            self.isPaused = true
            self.stopProgressPolling()
            self.updatePictureInPicturePlaybackState()
            self.refreshPausedVideoFrameIfPossible(player)
            self.logVLC("restorePausedVideoAfterForeground follow-up snapshot={\(self.playerSnapshot(player))}", type: "Player")
        }
    }

    private func refreshPausedVideoFrameIfPossible(_ player: VLCMediaPlayer) {
        let object = player as NSObject
        for selectorName in ["gotoNextFrame", "nextFrame"] {
            let selector = NSSelectorFromString(selectorName)
            if object.responds(to: selector) {
                _ = object.perform(selector)
                Logger.shared.log("[VLCRenderer.PiP] refreshed paused video frame using \(selectorName)", type: "Player")
                return
            }
        }
        logVLC("refreshPausedVideoFrameIfPossible no supported selector snapshot={\(playerSnapshot(player))}", type: "Player")
    }
    
    // MARK: - Native VLC Picture in Picture

    var isPictureInPictureAvailable: Bool {
        return nativePiPAvailable
    }

    var isPictureInPictureActive: Bool {
        return nativePiPActive || nativePiPStartRequested
    }

    fileprivate var nativePictureInPictureMediaTime: Int64 {
        let position = mediaPlayer.map { resolvedPlaybackProgress(from: $0).position } ?? cachedPosition
        let value = Int64(max(0, position) * 1000.0)
        logPiPMediaQueryIfNeeded(key: "mediaTime", message: "mediaTime queried valueMs=\(value) position=\(secondsText(position)) cachedPosition=\(secondsText(cachedPosition))")
        return value
    }

    fileprivate var nativePictureInPictureMediaLength: Int64 {
        let value: Int64
        if let player = mediaPlayer {
            value = Int64(max(0, reliableDuration(from: player)) * 1000.0)
        } else {
            value = Int64(max(0, cachedDuration) * 1000.0)
        }
        logPiPMediaQueryIfNeeded(key: "mediaLength", message: "mediaLength queried valueMs=\(value) cachedDuration=\(secondsText(cachedDuration)) snapshot={\(playerSnapshot())}")
        return value
    }

    fileprivate var nativePictureInPictureMediaSeekable: Bool {
        let duration: Double
        if let player = mediaPlayer {
            duration = reliableDuration(from: player)
        } else {
            duration = cachedDuration
        }
        let seekable = isRunning && !isStopping && duration >= minimumReliableDuration
        logPiPMediaQueryIfNeeded(key: "isMediaSeekable", message: "isMediaSeekable queried -> \(seekable) duration=\(secondsText(duration)) mode=\(nativePiPMediaControllerMode ?? "nil")")
        return seekable
    }

    fileprivate var nativePictureInPictureMediaPlaying: Bool {
        let playing = !isPaused
        logPiPMediaQueryIfNeeded(key: "isMediaPlaying", message: "isMediaPlaying queried -> \(playing) snapshot={\(playerSnapshot())}")
        return playing
    }

    fileprivate func nativePictureInPictureMediaController() -> AnyObject {
        guard let player = mediaPlayer else {
            recordNativePictureInPictureMediaControllerMode("drawable-shim")
            return vlcView
        }

        if canUseVLCMediaPlayerForNativePictureInPictureControl(player) {
            recordNativePictureInPictureMediaControllerMode("vlc-media-player")
            return player
        }

        recordNativePictureInPictureMediaControllerMode("drawable-shim")
        return vlcView
    }

    private func canUseVLCMediaPlayerForNativePictureInPictureControl(_ player: VLCMediaPlayer) -> Bool {
        let object = player as NSObject
        let requiredSelectors = [
            "mediaTime",
            "mediaLength",
            "isMediaSeekable",
            "isMediaPlaying",
            "play",
            "pause"
        ]
        let hasBaseControl = requiredSelectors.allSatisfy {
            object.responds(to: NSSelectorFromString($0))
        }
        let hasSeekCompletion =
            object.responds(to: NSSelectorFromString("seekBy:completion:")) ||
            object.responds(to: NSSelectorFromString("seekBy:completionHandler:"))
        let missing = requiredSelectors.filter { !object.responds(to: NSSelectorFromString($0)) }
        let key = "missing=\(missing.joined(separator: ",")) seekCompletion=\(hasSeekCompletion)"
        if key != lastNativePiPControlCapabilityLogKey {
            lastNativePiPControlCapabilityLogKey = key
            logVLC("PiP native media-player control capability \(key)", type: "Player")
        }
        return hasBaseControl && hasSeekCompletion
    }

    private func recordNativePictureInPictureMediaControllerMode(_ mode: String) {
        guard nativePiPMediaControllerMode != mode else { return }
        nativePiPMediaControllerMode = mode
        Logger.shared.log("[VLCRenderer.PiP] mediaController mode=\(mode)", type: "Player")
    }

    @discardableResult
    func startPictureInPicture() -> Bool {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                _ = self?.startPictureInPicture()
            }
            return nativePiPAvailable
        }

        guard nativePiPAvailable else {
            Logger.shared.log("[VLCRenderer.PiP] start blocked: native controller not ready", type: "Player")
            return false
        }

        guard let controller = nativePiPController as? NSObject else {
            Logger.shared.log("[VLCRenderer.PiP] start blocked: native controller missing", type: "Player")
            setNativePictureInPictureAvailable(false)
            return false
        }

        if nativePiPActive || nativePiPStartRequested {
            Logger.shared.log("[VLCRenderer.PiP] start ignored: already active or pending", type: "Player")
            return true
        }

        let selector = NSSelectorFromString("startPictureInPicture")
        guard controller.responds(to: selector) else {
            Logger.shared.log("[VLCRenderer.PiP] start blocked: native controller has no startPictureInPicture selector", type: "Player")
            setNativePictureInPictureAvailable(false)
            return false
        }

        ensureAudioSessionActive()
        nativePiPStartRequested = true
        Logger.shared.log("[VLCRenderer.PiP] start requested via native VLC controller", type: "Player")
        _ = controller.perform(selector)
        if nativePiPStateChangeHandler == nil {
            setNativePictureInPictureActive(true)
        }
        scheduleNativePictureInPictureStartFallbackCheck()
        updatePictureInPicturePlaybackState()
        return true
    }

    func stopPictureInPicture() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.stopPictureInPicture()
            }
            return
        }

        guard let controller = nativePiPController as? NSObject else {
            setNativePictureInPictureActive(false)
            return
        }

        let selector = NSSelectorFromString("stopPictureInPicture")
        if controller.responds(to: selector) {
            Logger.shared.log("[VLCRenderer.PiP] stop requested via native VLC controller", type: "Player")
            _ = controller.perform(selector)
        }

        setNativePictureInPictureActive(false)
        updatePictureInPicturePlaybackState()
    }

    func updatePictureInPicturePlaybackState() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.updatePictureInPicturePlaybackState()
            }
            return
        }

        guard nativePiPAvailable,
              let controller = nativePiPController as? NSObject else {
            let key = "unavailable available=\(nativePiPAvailable) controller=\(nativePiPController != nil)"
            if key != lastPiPPlaybackStateLogKey {
                lastPiPPlaybackStateLogKey = key
                logVLC("PiP playback state invalidate skipped \(key) snapshot={\(playerSnapshot())}", type: "Player")
            }
            return
        }

        let seekableText = nativePiPMediaControllerMode == "vlc-media-player" ? "vlc-managed" : "\(nativePictureInPictureMediaSeekable)"
        let stateKey = "time=\(nativePictureInPictureMediaTime) length=\(nativePictureInPictureMediaLength) playing=\(nativePictureInPictureMediaPlaying) seekable=\(seekableText) mode=\(nativePiPMediaControllerMode ?? "nil") active=\(nativePiPActive) requested=\(nativePiPStartRequested)"
        if stateKey != lastPiPPlaybackStateLogKey {
            lastPiPPlaybackStateLogKey = stateKey
            logVLC("PiP playback state invalidate \(stateKey)", type: "Player")
        }

        let selector = NSSelectorFromString("invalidatePlaybackState")
        if controller.responds(to: selector) {
            _ = controller.perform(selector)
        } else {
            logVLC("PiP controller missing invalidatePlaybackState selector type=\(String(describing: type(of: controller)))", type: "Player")
        }
    }

    private func logPiPMediaQueryIfNeeded(key: String, message: String) {
        let now = CACurrentMediaTime()
        if now - (lastPiPMediaQueryLogTimes[key] ?? 0) >= 5.0 {
            lastPiPMediaQueryLogTimes[key] = now
            logVLC("PiP media query \(message)", type: "Player")
        }
    }

    fileprivate func handleNativePictureInPictureControllerReady(_ controller: AnyObject) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.handleNativePictureInPictureControllerReady(controller)
            }
            return
        }

        nativePiPController = controller
        nativePiPStartRequested = false
        installNativePictureInPictureStateHandler(on: controller)
        setNativePictureInPictureAvailable(true)
        updatePictureInPicturePlaybackState()
        logVLC("native VLC PiP controller ready type=\(String(describing: type(of: controller))) snapshot={\(playerSnapshot())}", type: "Player")
    }

    private func installNativePictureInPictureStateHandler(on controller: AnyObject) {
        guard let object = controller as? NSObject else { return }
        let selector = NSSelectorFromString("setStateChangeEventHandler:")
        guard object.responds(to: selector) else {
            Logger.shared.log("[VLCRenderer.PiP] native controller has no stateChangeEventHandler; using local active state", type: "Player")
            return
        }

        let handler: NativeVLCPiPStateChangeBlock = { [weak self] isStarted in
            DispatchQueue.main.async {
                self?.logVLC("native PiP state handler isStarted=\(isStarted)", type: "Player")
                self?.setNativePictureInPictureActive(isStarted)
                self?.updatePictureInPicturePlaybackState()
            }
        }
        nativePiPStateChangeHandler = handler
        object.setValue(handler, forKey: "stateChangeEventHandler")
    }

    private func scheduleNativePictureInPictureStartFallbackCheck() {
        guard nativePiPStateChangeHandler != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard self.nativePiPStartRequested, !self.nativePiPActive else { return }

            Logger.shared.log("[VLCRenderer.PiP] native start did not report active; cancelling pending request", type: "Player")
            self.setNativePictureInPictureActive(false)
            if UIApplication.shared.applicationState == .background {
                self.pausePlayback()
            }
            self.updatePictureInPicturePlaybackState()
        }
    }

    private func teardownNativePictureInPicture() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.teardownNativePictureInPicture()
            }
            return
        }

        if nativePiPActive || nativePiPStartRequested {
            stopPictureInPicture()
        }
        logVLC("teardownNativePictureInPicture snapshot={\(playerSnapshot())}", type: "Player")
        nativePiPController = nil
        nativePiPStateChangeHandler = nil
        nativePiPStartRequested = false
        setNativePictureInPictureActive(false)
        setNativePictureInPictureAvailable(false)
    }

    private func setNativePictureInPictureAvailable(_ available: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setNativePictureInPictureAvailable(available)
            }
            return
        }

        if !available {
            nativePiPStartRequested = false
        }

        guard nativePiPAvailable != available else { return }
        nativePiPAvailable = available
        logVLC("setNativePictureInPictureAvailable=\(available) snapshot={\(playerSnapshot())}", type: "Player")
        delegate?.renderer(self, didChangePictureInPictureAvailability: available)
    }

    private func setNativePictureInPictureActive(_ active: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setNativePictureInPictureActive(active)
            }
            return
        }

        let wasEffectivelyActive = nativePiPActive || nativePiPStartRequested
        let storedActiveChanged = nativePiPActive != active
        nativePiPStartRequested = false
        nativePiPActive = active
        let isEffectivelyActive = nativePiPActive || nativePiPStartRequested
        guard storedActiveChanged || wasEffectivelyActive != isEffectivelyActive else { return }
        logVLC("setNativePictureInPictureActive stored=\(active) effective=\(isEffectivelyActive) wasEffective=\(wasEffectivelyActive) snapshot={\(playerSnapshot())}", type: "Player")
        delegate?.renderer(self, didChangePictureInPictureActive: isEffectivelyActive)
        if wasEffectivelyActive && !isEffectivelyActive {
            let shouldReloadAfterBlockedSeek = nativePiPBlockedSeekDeadline.map { Date() <= $0 } ?? false
            nativePiPBlockedSeekDeadline = nil
            Logger.shared.log("[VLCRenderer.PiP] native PiP stopped; reattaching VLC drawable", type: "Player")
            recoverRenderingViewAfterPictureInPictureStop(reloadMedia: shouldReloadAfterBlockedSeek)
        } else if isEffectivelyActive {
            nativePiPBlockedSeekDeadline = nil
        }
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
        return vlcBool(from: player, key: "playing", selectors: ["isPlaying", "playing"], fallback: false)
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
        return min(max(vlcDouble(from: player, key: "position", fallback: 0), 0), 1)
    }

    private func setNormalizedPosition(_ normalized: Double, on player: VLCMediaPlayer) {
        setVLCDouble(min(max(normalized, 0), 1), on: player, key: "position")
    }

    private func vlcIntArray(from player: VLCMediaPlayer, key: String) -> [Int] {
        guard let value = vlcValue(from: player, key: key) else { return [] }
        if let ints = value as? [Int] {
            return ints
        }
        if let numbers = value as? [NSNumber] {
            return numbers.map { $0.intValue }
        }
        if let array = value as? NSArray {
            return array.compactMap { item in
                if let number = item as? NSNumber { return number.intValue }
                if let int = item as? Int { return int }
                if let string = item as? String { return Int(string) }
                return nil
            }
        }
        return []
    }

    private func vlcStringArray(from player: VLCMediaPlayer, key: String) -> [String] {
        guard let value = vlcValue(from: player, key: key) else { return [] }
        if let strings = value as? [String] {
            return strings
        }
        if let array = value as? NSArray {
            return array.compactMap { item in
                if let string = item as? String { return string }
                if item is NSNull { return nil }
                return String(describing: item)
            }
        }
        return []
    }

    private func vlcInt(from player: VLCMediaPlayer, key: String, fallback: Int) -> Int {
        guard let value = vlcValue(from: player, key: key) else { return fallback }
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let int32 = value as? Int32 {
            return Int(int32)
        }
        if let string = value as? String, let int = Int(string) {
            return int
        }
        return fallback
    }

    private func vlcBool(from player: VLCMediaPlayer, key: String, selectors: [String], fallback: Bool) -> Bool {
        guard let value = vlcValue(from: player, key: key, selectors: selectors) else { return fallback }
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return (string as NSString).boolValue
        }
        return fallback
    }

    private func vlcDouble(from player: VLCMediaPlayer, key: String, fallback: Double) -> Double {
        guard let value = vlcValue(from: player, key: key) else { return fallback }
        if let double = value as? Double {
            return double
        }
        if let float = value as? Float {
            return Double(float)
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String, let double = Double(string) {
            return double
        }
        return fallback
    }

    private func setVLCInt(_ value: Int, on player: VLCMediaPlayer, key: String) {
        setVLCValue(NSNumber(value: value), on: player, key: key)
    }

    private func setVLCDouble(_ value: Double, on player: VLCMediaPlayer, key: String) {
        setVLCValue(NSNumber(value: value), on: player, key: key)
    }

    private func vlcValue(from player: VLCMediaPlayer, key: String) -> Any? {
        return vlcValue(from: player, key: key, selectors: [key])
    }

    private func vlcValue(from player: VLCMediaPlayer, key: String, selectors: [String]) -> Any? {
        let object = player as NSObject
        guard selectors.contains(where: { object.responds(to: NSSelectorFromString($0)) }) else { return nil }
        return object.value(forKey: key)
    }

    private func setVLCValue(_ value: Any, on player: VLCMediaPlayer, key: String) {
        let object = player as NSObject
        guard object.responds(to: NSSelectorFromString(setterSelectorName(for: key))) else { return }
        object.setValue(value, forKey: key)
    }

    private func setterSelectorName(for key: String) -> String {
        guard let first = key.first else { return "set:" }
        return "set\(String(first).uppercased())\(key.dropFirst()):"
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

#endif  // canImport(VLCKit) || canImport(VLCKitSPM)

