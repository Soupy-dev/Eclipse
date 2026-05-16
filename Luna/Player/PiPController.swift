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
        Logger.shared.log("[PiPController] initialized supported=\(isPictureInPictureSupported) possible=\(pipController?.isPictureInPicturePossible ?? false) autoInline=false", type: "MPV")
    }

    func startPictureInPicture() {
        guard let pipController = pipController,
              pipController.isPictureInPicturePossible else {
            Logger.shared.log("[PiPController] start blocked: controllerNil=\(pipController == nil) possible=\(self.pipController?.isPictureInPicturePossible ?? false)", type: "MPV")
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
        Logger.shared.log("[PiPController] start requested active=\(pipController.isPictureInPictureActive) possible=\(pipController.isPictureInPicturePossible) supported=\(isPictureInPictureSupported) pending=\(isStartRequestPending)", type: "MPV")
        pipController.startPictureInPicture()
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
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Logger.shared.log("[PiPController] delegate willStart active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) pending=\(isStartRequestPending)", type: "MPV")
        delegate?.pipController(self, willStartPictureInPicture: true)
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStartRequestPending = false
        Logger.shared.log("[PiPController] delegate didStart active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) pending=\(isStartRequestPending)", type: "MPV")
        delegate?.pipController(self, didStartPictureInPicture: true)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        isStartRequestPending = false
        let nsError = error as NSError
        Logger.shared.log("[PiPController] failedToStart error=\(nsError.domain)#\(nsError.code) desc=\(nsError.localizedDescription) active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) pending=\(isStartRequestPending) hasDelegate=\(delegate != nil)", type: "MPV")
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
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        delegate?.pipController(self, skipByInterval: skipInterval)
        DispatchQueue.main.async { [weak self] in
            self?.pipController?.invalidatePlaybackState()
        }
        completionHandler()
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let duration = delegate?.pipControllerDuration(self) ?? 0
        if duration > 0 {
            let cmDuration = CMTime(seconds: duration, preferredTimescale: 1000)
            return CMTimeRange(start: .zero, duration: cmDuration)
        }
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
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
        let duration = delegate?.pipControllerDuration(self) ?? 0
        if duration > 0 {
            let cmDuration = CMTime(seconds: duration, preferredTimescale: 1000)
            return CMTimeRange(start: .zero, duration: cmDuration)
        }
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, currentTimeFor sampleBufferDisplayLayer: AVSampleBufferDisplayLayer) -> CMTime {
        let currentTime = delegate?.pipControllerCurrentTime(self) ?? 0
        return CMTime(seconds: currentTime, preferredTimescale: 1000)
    }
}
