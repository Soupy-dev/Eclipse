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
    private var pendingAbsoluteSeek: Double?
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
                name: NSNotification.Name(rawValue: VLCMediaPlayerTimeChanged),
                object: mediaPlayer
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(mediaPlayerStateChanged),
                name: NSNotification.Name(rawValue: VLCMediaPlayerStateChanged),
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
    
    func load(url: URL, with preset: PlayerPreset, headers: [String: String]? = nil) {
        Logger.shared.log("[VLCRenderer.load] URL=\(url.absoluteString) headers=\(headers?.count ?? 0) isLocal=\(url.isFileURL)", type: "Stream")
        
        currentURL = url
        currentPreset = preset

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
            self.ensureAudioSessionActive()
            player.play()
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
        if state == .stopped || state == .ended || state == .error {
            Logger.shared.log("[VLCRenderer.play] Player in \(describeState(state)) state — reloading from position \(cachedPosition)s", type: "Stream")
            reloadAndSeekToLastPosition()
            return
        }

        player.play()
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
        isPaused = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didChangePause: true)
        }

        mediaPlayer?.pause()
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
            if durationSec > 0 {
                let normalized = min(max(clamped / durationSec, 0), 1)
                player.position = Float(normalized)
                self.cachedDuration = durationSec
                self.pendingAbsoluteSeek = nil
                self.updatePictureInPicturePlaybackState()
                return
            }

            // If we have a cached duration, fall back to it.
            if self.cachedDuration > 0 {
                let normalized = min(max(clamped / self.cachedDuration, 0), 1)
                player.position = Float(normalized)
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
        
        // VLC provides audio track info through the media player
        if let audioTrackIndexes = player.audioTrackIndexes as? [Int],
           let audioTrackNames = player.audioTrackNames as? [String] {
            // VLCKit doesn't expose language codes publicly here; rely on name parsing.
            for (index, name) in zip(audioTrackIndexes, audioTrackNames) {
                let code = guessLanguageCode(from: name)
                result.append((index, name, code))
            }
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
    
    func loadExternalSubtitles(urls: [String], enforce: Bool = false) {
        guard let player = mediaPlayer, let media = currentMedia else { return }
        
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
        let positionMs = player.time.value?.doubleValue ?? 0
        let durationMs = player.media?.length.value?.doubleValue ?? 0
        let position = positionMs / 1000.0
        let duration = durationMs / 1000.0
        let normalizedPosition = Double(player.position)

        let now = CACurrentMediaTime()

        cachedPosition = position
        cachedDuration = duration

        // If we were waiting for duration to apply a pending seek, do it once duration is known.
        if duration > 0, let pending = pendingAbsoluteSeek {
            let normalized = min(max(pending / duration, 0), 1)
            player.position = Float(normalized)
            pendingAbsoluteSeek = nil
        }

        if nativePiPActive || nativePiPStartRequested {
            updatePictureInPicturePlaybackState()
        }

        // If we were marked loading but playback is progressing, clear loading state
        if isLoading && position > 0 {
            isLoading = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didChangeLoading: false)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didUpdatePosition: position, duration: duration)
        }


    }
    
    @objc private func mediaPlayerStateChanged() {
        guard let player = mediaPlayer else { return }
        
        let state = player.state
        
        if state == .error {
            let urlString = currentURL?.absoluteString ?? "nil"
            let headerCount = currentHeaders?.count ?? 0
            Logger.shared.log("VLCRenderer: ERROR url=\(urlString) headers=\(headerCount) preset=\(currentPreset?.id.rawValue ?? "nil")", type: "Error")
        }
        
        switch state {
        case .playing:
            isPaused = false
            isLoading = false
            isReadyToSeek = true
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didChangePause: false)
                self.delegate?.renderer(self, didChangeLoading: false)
                self.delegate?.renderer(self, didBecomeReadyToSeek: true)
            }
            
        case .paused:
            isPaused = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didChangePause: true)
            }
            
        case .opening, .buffering:
            isLoading = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didChangeLoading: true)
            }

        case .stopped, .ended, .error:
            isPaused = true
            isLoading = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, didChangePause: true)
                self.delegate?.renderer(self, didChangeLoading: false)
            }
            if state == .error {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.renderer(self, didFailWithError: "VLC playback error")
                }
            }
            
        default:
            break
        }
        updatePictureInPicturePlaybackState()
    }
    
    @objc private func handleAppDidEnterBackground() {
        if !isPaused, isPictureInPictureAvailable {
            Logger.shared.log("[VLCRenderer.PiP] entering background; starting native VLC PiP", type: "Player")
            if startPictureInPicture() {
                return
            }
        }

        Logger.shared.log("[VLCRenderer.PiP] entering background without native VLC PiP; pausing playback", type: "Player")
        pausePlayback()
    }
    
    @objc private func handleAppWillEnterForeground() {
        if isPictureInPictureActive {
            Logger.shared.log("[VLCRenderer.PiP] returning to foreground; stopping native VLC PiP", type: "Player")
            stopPictureInPicture()
        }
        // Re-activate the audio session that iOS may have deactivated during background.
        ensureAudioSessionActive()
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
        return cachedDuration > 0
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

    private func describeState(_ state: VLCMediaPlayerState) -> String {
        switch state {
        case .opening: return "opening"
        case .buffering: return "buffering"
        case .ended: return "ended"
        case .error: return "error"
        case .paused: return "paused"
        case .playing: return "playing"
        case .stopped: return "stopped"
        case .esAdded: return "esAdded"
        @unknown default:
            // Older or newer SDKs may expose an idle/unknown state; fall back to rawValue for logging.
            return "unknown(\(state.rawValue))"
        }
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

