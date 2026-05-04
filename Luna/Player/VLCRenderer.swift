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
        return self
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
        renderer?.seek(by: Double(offset) / 1000.0)
    }

    @objc(seekBy:completion:)
    func seekBy(_ offset: Int64, completion: NativeVLCPiPSeekCompletion?) {
        renderer?.seek(by: Double(offset) / 1000.0)
        completion?()
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
    private var wasPausedBeforeBackground = true
    private var backgroundedPosition: Double?
    
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
    }

    private func reattachRenderingView() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mediaPlayer?.drawable = self.vlcView
            self.vlcView.setNeedsLayout()
            self.vlcView.layoutIfNeeded()
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
        return vlcView
    }
    
    // MARK: - Lifecycle
    
    func start() throws {
        guard !isRunning else { return }
        
        do {
            Logger.shared.log("[VLCRenderer.start] Initializing VLCMediaPlayer", type: "Stream")
            
            // Initialize VLC with proper options for video rendering
            mediaPlayer = VLCMediaPlayer()
            guard let mediaPlayer = mediaPlayer else {
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
            
            isRunning = true

        } catch {
            throw RendererError.vlcInitializationFailed
        }
    }
    
    func stop() {
        if isStopping { return }
        if !isRunning { return }


        
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

            // Mark stop completion only after cleanup finishes to prevent reentrancy races
            self.isStopping = false

        }
    }
    
    // MARK: - Playback Control

    func prepareInitialSeek(to seconds: Double?) {
        let clamped = seconds.map { max(0, $0) }
        preparedInitialSeek = clamped
        pendingAbsoluteSeek = clamped
    }
    
    func load(url: URL, with preset: PlayerPreset, headers: [String: String]? = nil) {
        Logger.shared.log("[VLCRenderer.load] URL=\(url.absoluteString) headers=\(headers?.count ?? 0) isLocal=\(url.isFileURL)", type: "Stream")
        
        currentURL = url
        currentPreset = preset
        let initialSeek = preparedInitialSeek
        preparedInitialSeek = nil
        cachedPosition = 0
        cachedDuration = 0
        pendingAbsoluteSeek = initialSeek
        lastProgressHostTime = nil

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
                media.addOption(":start-time=\(String(format: "%.3f", initialSeek))")
                Logger.shared.log("[VLCRenderer.load] prepared initial seek \(Int(initialSeek))s", type: "Progress")
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
            player.play()
            self.startProgressPolling()
            self.scheduleLoadingSanityChecks()
            self.updatePictureInPicturePlaybackState()
        }
    }
    
    func reloadCurrentItem() {
        guard let url = currentURL, let preset = currentPreset else { return }
        load(url: url, with: preset, headers: currentHeaders)
    }
    
    func applyPreset(_ preset: PlayerPreset) {
        currentPreset = preset
        // VLC doesn't require preset application like mpv does
        // Presets are mainly for video output configuration which VLC handles automatically
    }
    
    func play() {
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
    }

    /// Reload the current media and seek back to the last known position.
    /// Used to recover from stopped/ended state after background network drops.
    private func reloadAndSeekToLastPosition() {
        guard let url = currentURL, let preset = currentPreset else { return }
        let savedPosition = cachedPosition
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
    }
    
    func togglePause() {
        if isPaused { play() } else { pausePlayback() }
    }
    
    func seek(to seconds: Double) {
        eventQueue.async { [weak self] in
            guard let self, let player = self.mediaPlayer else { return }
            let clamped = max(0, seconds)

            // If VLC already knows the duration, seek accurately using normalized position.
            let durationMs = player.media?.length.value?.doubleValue ?? 0
            let durationSec = durationMs / 1000.0
            if durationSec >= self.minimumReliableDuration {
                let normalized = min(max(clamped / durationSec, 0), 1)
                self.setNormalizedPosition(normalized, on: player)
                self.cachedDuration = durationSec
                self.pendingAbsoluteSeek = nil
                self.updatePictureInPicturePlaybackState()
                return
            }

            // If we have a cached duration, fall back to it.
            if self.cachedDuration >= self.minimumReliableDuration {
                let normalized = min(max(clamped / self.cachedDuration, 0), 1)
                self.setNormalizedPosition(normalized, on: player)
                self.pendingAbsoluteSeek = clamped
                self.updatePictureInPicturePlaybackState()
                return
            }

            // Duration unknown: stash the seek request to apply once duration arrives.
            self.pendingAbsoluteSeek = clamped
            self.updatePictureInPicturePlaybackState()
        }
    }
    
    func seek(by seconds: Double) {
        eventQueue.async { [weak self] in
            guard let self, let player = self.mediaPlayer else { return }
            let newTime = self.cachedPosition + seconds
            self.seek(to: newTime)
        }
    }
    
    func setSpeed(_ speed: Double) {
        eventQueue.async { [weak self] in
            guard let self, let player = self.mediaPlayer else { return }
            
            self.currentPlaybackSpeed = max(0.1, speed)
            
            player.rate = Float(self.currentPlaybackSpeed)
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
        Logger.shared.log("VLCRenderer: Setting audio track to ID \(id)", type: "Player")
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
        
        return result
    }
    
    func setSubtitleTrack(id: Int) {
        guard let player = mediaPlayer else { return }
        
        // Set track immediately - VLC property setters are thread-safe
        Logger.shared.log("VLCRenderer: Setting subtitle track to ID \(id)", type: "Player")
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
            Logger.shared.log("VLCRenderer: Adding external subtitles count=\(urls.count)", type: "Info")
            for urlString in urls {
                if let url = URL(string: urlString) {
                    // enforce: true for local files so VLC auto-selects the subtitle track
                    let shouldEnforce = enforce || url.isFileURL
                    let subtitleSlaveType = VLCMediaPlaybackSlaveType(rawValue: 0)!
                    player.addPlaybackSlave(url, type: subtitleSlaveType, enforce: shouldEnforce)
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
            cachedDuration = duration
        }

        if isPlaybackActive(player), isPaused {
            isPaused = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didChangePause: false)
            }
        }

        // If we were waiting for duration to apply a pending seek, do it once duration is known.
        if duration > 0, let pending = pendingAbsoluteSeek {
            let normalized = min(max(pending / duration, 0), 1)
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
    
    @objc private func mediaPlayerStateChanged() {
        guard let player = mediaPlayer else { return }
        
        let state = player.state
        
        if isErrorState(state) {
            let urlString = currentURL?.absoluteString ?? "nil"
            let headerCount = currentHeaders?.count ?? 0
            Logger.shared.log("VLCRenderer: ERROR url=\(urlString) headers=\(headerCount) preset=\(currentPreset?.id.rawValue ?? "nil")", type: "Error")
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didChangeLoading: false)
        }
    }

    private func scheduleLoadingSanityChecks() {
        for delay in [0.75, 1.5, 3.0] {
            eventQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isLoading, let player = self.mediaPlayer else { return }

                let positionMs = player.time.value?.doubleValue ?? 0
                if positionMs > 0 || self.isPlaybackActive(player) {
                    self.clearLoadingState()
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
    }

    private func stopProgressPolling() {
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
        let duration = reportedDurationIsReliable ? rawDuration : (cachedDurationIsReliable ? cachedDuration : 0)
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
        if isPictureInPictureActive {
            Logger.shared.log("[VLCRenderer.PiP] returning to foreground; stopping native VLC PiP", type: "Player")
            stopPictureInPicture()
        }
        // Re-activate the audio session that iOS may have deactivated during background.
        ensureAudioSessionActive()
        reattachRenderingView()
        if wasPausedBeforeBackground {
            restorePausedVideoAfterForeground()
        }
    }

    private func restorePausedVideoAfterForeground() {
        let restorePosition = backgroundedPosition ?? cachedPosition
        eventQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let player = self.mediaPlayer else { return }

            if restorePosition > 0 {
                let durationMs = player.media?.length.value?.doubleValue ?? 0
                let durationSec = durationMs / 1000.0
                if durationSec >= self.minimumReliableDuration {
                    let normalized = min(max(restorePosition / durationSec, 0), 1)
                    self.setNormalizedPosition(normalized, on: player)
                    self.cachedDuration = durationSec
                } else if self.cachedDuration >= self.minimumReliableDuration {
                    let normalized = min(max(restorePosition / self.cachedDuration, 0), 1)
                    self.setNormalizedPosition(normalized, on: player)
                } else {
                    self.pendingAbsoluteSeek = restorePosition
                }
                self.cachedPosition = restorePosition
            }

            if self.isPlayerActivelyPlaying(player) || self.isPlayingState(player.state) {
                player.pause()
            }

            self.isPaused = true
            self.stopProgressPolling()
            self.updatePictureInPicturePlaybackState()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mediaPlayer?.drawable = self.vlcView
                self.vlcView.setNeedsLayout()
                self.vlcView.layoutIfNeeded()
                self.delegate?.renderer(self, didChangePause: true)
                if restorePosition > 0 {
                    self.delegate?.renderer(self, didUpdatePosition: restorePosition, duration: self.cachedDuration)
                }
            }
        }
    }
    
    // MARK: - Native VLC Picture in Picture

    var isPictureInPictureAvailable: Bool {
        return nativePiPAvailable
    }

    var isPictureInPictureActive: Bool {
        return nativePiPActive || nativePiPStartRequested
    }

    fileprivate var nativePictureInPictureMediaTime: Int64 {
        return Int64(max(0, cachedPosition) * 1000.0)
    }

    fileprivate var nativePictureInPictureMediaLength: Int64 {
        return Int64(max(0, cachedDuration) * 1000.0)
    }

    fileprivate var nativePictureInPictureMediaSeekable: Bool {
        return currentURL != nil
    }

    fileprivate var nativePictureInPictureMediaPlaying: Bool {
        return !isPaused
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
            return
        }

        let selector = NSSelectorFromString("invalidatePlaybackState")
        if controller.responds(to: selector) {
            _ = controller.perform(selector)
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
        Logger.shared.log("[VLCRenderer.PiP] native VLC PiP controller ready type=\(String(describing: type(of: controller)))", type: "Player")
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
        delegate?.renderer(self, didChangePictureInPictureActive: isEffectivelyActive)
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

