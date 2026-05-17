//
//  PiPController.swift
//  test
//
//  Created by Francesco on 30/09/25.
//

import AVKit
import AVFoundation

protocol PiPControllerDelegate: AnyObject {
    func pipController(_ controller: PiPController, willStartPictureInPicture: Bool)
    func pipController(_ controller: PiPController, didStartPictureInPicture: Bool)
    func pipController(_ controller: PiPController, willStopPictureInPicture: Bool)
    func pipController(_ controller: PiPController, didStopPictureInPicture: Bool)
    func pipController(_ controller: PiPController, restoreUserInterfaceForPictureInPictureStop completionHandler: @escaping (Bool) -> Void)
    func pipControllerPlay(_ controller: PiPController)
    func pipControllerPause(_ controller: PiPController)
    func pipController(_ controller: PiPController, skipByInterval interval: CMTime)
    func pipControllerIsPlaying(_ controller: PiPController) -> Bool
    func pipControllerDuration(_ controller: PiPController) -> Double
    func pipControllerCurrentTime(_ controller: PiPController) -> Double
}

final class PiPController: NSObject {
    private var pipController: AVPictureInPictureController?
    private weak var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    private var isStartRequestPending = false
    private var timeRangeRequestCount = 0
    private var currentTimeRequestCount = 0
    
    weak var delegate: PiPControllerDelegate?
    
    var isPictureInPictureSupported: Bool {
        return AVPictureInPictureController.isPictureInPictureSupported()
    }
    
    var isPictureInPictureActive: Bool {
        return pipController?.isPictureInPictureActive ?? false
    }
    
    var isPictureInPicturePossible: Bool {
        return pipController?.isPictureInPicturePossible ?? false
    }

    static var isPictureInPictureSupported: Bool {
        return AVPictureInPictureController.isPictureInPictureSupported()
    }
    
    init(sampleBufferDisplayLayer: AVSampleBufferDisplayLayer) {
        self.sampleBufferDisplayLayer = sampleBufferDisplayLayer
        super.init()
        setupSampleBufferPictureInPicture()
    }
    
    private func setupSampleBufferPictureInPicture() {
        guard isPictureInPictureSupported,
              let displayLayer = sampleBufferDisplayLayer else {
                        Logger.shared.log("[PiPController] setup skipped: supported=\(isPictureInPictureSupported) hasDisplayLayer=\(sampleBufferDisplayLayer != nil)", type: "MPV")
            return
        }
        
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        
        pipController = AVPictureInPictureController(contentSource: contentSource)
        pipController?.delegate = self
        pipController?.requiresLinearPlayback = false
        #if !os(tvOS)
        pipController?.canStartPictureInPictureAutomaticallyFromInline = false
        #endif
        Logger.shared.log("[PiPController] initialized supported=\(isPictureInPictureSupported) possible=\(pipController?.isPictureInPicturePossible ?? false) autoInline=false layer={\(layerSnapshot())}", type: "MPV")
    }

    func startPictureInPicture() {
        guard let pipController = pipController,
              pipController.isPictureInPicturePossible else {
            Logger.shared.log("[PiPController] start blocked: controllerNil=\(pipController == nil) possible=\(self.pipController?.isPictureInPicturePossible ?? false) layer={\(layerSnapshot())}", type: "MPV")
            return
        }
        if pipController.isPictureInPictureActive {
            Logger.shared.log("[PiPController] start ignored: already active", type: "MPV")
            return
        }
        if isStartRequestPending {
            Logger.shared.log("[PiPController] start ignored: request already pending", type: "MPV")
            return
        }
        isStartRequestPending = true
        pipController.requiresLinearPlayback = false
        pipController.invalidatePlaybackState()
        Logger.shared.log("[PiPController] start requested active=\(pipController.isPictureInPictureActive) possible=\(pipController.isPictureInPicturePossible) supported=\(isPictureInPictureSupported) pending=\(isStartRequestPending) layer={\(layerSnapshot())}", type: "MPV")
        pipController.startPictureInPicture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pipController?.requiresLinearPlayback = false
            self?.pipController?.invalidatePlaybackState()
        }
    }
    
    func stopPictureInPicture() {
        isStartRequestPending = false
        Logger.shared.log("[PiPController] stop requested active=\(pipController?.isPictureInPictureActive ?? false)", type: "MPV")
        pipController?.stopPictureInPicture()
    }
    
    func invalidate() {
        pipController?.invalidatePlaybackState()
    }
    
    func updatePlaybackState() {
        pipController?.invalidatePlaybackState()
    }

    private func layerSnapshot() -> String {
        guard let layer = sampleBufferDisplayLayer else { return "nil" }
        let nsError = layer.error.map { $0 as NSError }
        let errorText = nsError.map { "\($0.domain)#\($0.code)" } ?? "nil"
        return "ready=\(layer.isReadyForMoreMediaData) status=\(layerStatusName(layer.status)) error=\(errorText) hidden=\(layer.isHidden) opacity=\(String(format: "%.2f", layer.opacity)) frame=\(String(format: "%.0fx%.0f", layer.bounds.width, layer.bounds.height)) timebase=\(layer.controlTimebase != nil)"
    }

    private func layerStatusName(_ status: AVQueuedSampleBufferRenderingStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .rendering: return "rendering"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }

    private func sanitizedPlaybackTimes() -> (currentTime: Double, duration: Double, rawDuration: Double, synthesizedDuration: Bool) {
        let rawCurrentTime = delegate?.pipControllerCurrentTime(self) ?? 0
        let rawDuration = delegate?.pipControllerDuration(self) ?? 0
        let currentTime = rawCurrentTime.isFinite ? max(0, rawCurrentTime) : 0
        let durationIsUsable = rawDuration.isFinite && rawDuration > max(5, currentTime + 1.0)
        let duration = durationIsUsable ? rawDuration : max(600, currentTime + 600)
        return (min(currentTime, max(0, duration - 0.5)), duration, rawDuration, !durationIsUsable)
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Logger.shared.log("[PiPController] delegate willStart active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) pending=\(isStartRequestPending) layer={\(layerSnapshot())}", type: "MPV")
        delegate?.pipController(self, willStartPictureInPicture: true)
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStartRequestPending = false
        Logger.shared.log("[PiPController] delegate didStart active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) pending=\(isStartRequestPending) layer={\(layerSnapshot())}", type: "MPV")
        delegate?.pipController(self, didStartPictureInPicture: true)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        isStartRequestPending = false
        let nsError = error as NSError
        Logger.shared.log("[PiPController] failedToStart error=\(nsError.domain)#\(nsError.code) desc=\(nsError.localizedDescription) active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) pending=\(isStartRequestPending) hasDelegate=\(delegate != nil) layer={\(layerSnapshot())}", type: "MPV")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.pipController(self, didStartPictureInPicture: false)
        }
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStartRequestPending = false
        Logger.shared.log("[PiPController] delegate willStop", type: "MPV")
        delegate?.pipController(self, willStopPictureInPicture: true)
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Logger.shared.log("[PiPController] delegate didStop active=\(pictureInPictureController.isPictureInPictureActive)", type: "MPV")
        delegate?.pipController(self, didStopPictureInPicture: true)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        delegate?.pipController(self, restoreUserInterfaceForPictureInPictureStop: completionHandler)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing {
            delegate?.pipControllerPlay(self)
        } else {
            delegate?.pipControllerPause(self)
        }
        DispatchQueue.main.async { [weak self] in
            self?.pipController?.invalidatePlaybackState()
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        Logger.shared.log("[PiPController] render size transition \(newRenderSize.width)x\(newRenderSize.height) layer={\(layerSnapshot())}", type: "MPV")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        let seconds = CMTimeGetSeconds(skipInterval)
        let times = sanitizedPlaybackTimes()
        Logger.shared.log("[PiPController] skip callback interval=\(String(format: "%.2f", seconds)) current=\(String(format: "%.2f", times.currentTime)) duration=\(String(format: "%.2f", times.duration)) rawDuration=\(String(format: "%.2f", times.rawDuration)) synthesized=\(times.synthesizedDuration) active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) layer={\(layerSnapshot())}", type: "MPV")
        delegate?.pipController(self, skipByInterval: skipInterval)
        DispatchQueue.main.async { [weak self] in
            self?.pipController?.invalidatePlaybackState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.pipController?.invalidatePlaybackState()
            }
        }
        completionHandler()
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let times = sanitizedPlaybackTimes()
        return CMTimeRange(start: .zero, duration: CMTime(seconds: times.duration, preferredTimescale: 1000))
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return !(delegate?.pipControllerIsPlaying(self) ?? false)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool, completion: @escaping () -> Void) {
        if playing {
            delegate?.pipControllerPlay(self)
        } else {
            delegate?.pipControllerPause(self)
        }
        DispatchQueue.main.async { [weak self] in
            self?.pipController?.invalidatePlaybackState()
        }
        completion()
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, timeRangeForPlayback sampleBufferDisplayLayer: AVSampleBufferDisplayLayer) -> CMTimeRange {
        let times = sanitizedPlaybackTimes()
        timeRangeRequestCount += 1
        if timeRangeRequestCount <= 3 || timeRangeRequestCount % 30 == 0 {
            Logger.shared.log("[PiPController] playback timeRange request count=\(timeRangeRequestCount) current=\(String(format: "%.2f", times.currentTime)) rawDuration=\(String(format: "%.2f", times.rawDuration)) duration=\(String(format: "%.2f", times.duration)) synthesized=\(times.synthesizedDuration) layer={\(layerSnapshot())}", type: "MPV")
        }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: times.duration, preferredTimescale: 1000))
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, currentTimeFor sampleBufferDisplayLayer: AVSampleBufferDisplayLayer) -> CMTime {
        let times = sanitizedPlaybackTimes()
        currentTimeRequestCount += 1
        if currentTimeRequestCount <= 3 || currentTimeRequestCount % 30 == 0 {
            Logger.shared.log("[PiPController] playback currentTime request count=\(currentTimeRequestCount) time=\(String(format: "%.2f", times.currentTime)) duration=\(String(format: "%.2f", times.duration)) synthesized=\(times.synthesizedDuration) layer={\(layerSnapshot())}", type: "MPV")
        }
        return CMTime(seconds: times.currentTime, preferredTimescale: 1000)
    }
}
