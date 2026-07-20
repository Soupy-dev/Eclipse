// test

import AVKit
import AVFoundation
import Foundation

private final class PiPRestoreCompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Bool) -> Void)?

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func callAsFunction(_ restored: Bool) {
        let callback: ((Bool) -> Void)?
        lock.lock()
        callback = completion
        completion = nil
        lock.unlock()
        callback?(restored)
    }
}

protocol PiPControllerDelegate: AnyObject {
    func pipController(_ controller: PiPController, willStartPictureInPicture: Bool)
    func pipController(
        _ controller: PiPController,
        didStartPictureInPicture: Bool,
        attemptID: Int
    )
    func pipController(_ controller: PiPController, willStopPictureInPicture: Bool)
    func pipController(_ controller: PiPController, didStopPictureInPicture: Bool)
    func pipController(_ controller: PiPController, restoreUserInterfaceForPictureInPictureStop completionHandler: @escaping (Bool) -> Void)
    func pipControllerPlay(_ controller: PiPController)
    func pipControllerPause(_ controller: PiPController)
    func pipController(_ controller: PiPController, setPlaying playing: Bool, completion: @escaping () -> Void)
    func pipController(_ controller: PiPController, didTransitionToRenderSize size: CGSize)
    func pipController(_ controller: PiPController, skipByInterval interval: CMTime, completion: @escaping () -> Void)
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
    private var automaticFromInlineEnabled = false
    /// AVKit can reject an explicit start while concurrently accepting automatic-from-inline on
    /// the same controller. Track `willStart` independently from Eclipse's attempt IDs so a
    /// deferred failure from the rejected request cannot tear down the succeeding transition.
    private var pictureInPictureWillStartSequence: UInt = 0
    let playbackLoadGeneration: Int
    private var armedTransitionAttemptID: Int = 0
    private var callbackTransitionAttemptID: Int?
    var transitionAttemptID: Int {
        callbackTransitionAttemptID ?? armedTransitionAttemptID
    }
    
    weak var delegate: PiPControllerDelegate?
    
    var isPictureInPictureSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }
    
    var isPictureInPictureActive: Bool {
        return pipController?.isPictureInPictureActive ?? false
    }

    var isPictureInPictureSuspended: Bool {
        return pipController?.isPictureInPictureSuspended ?? false
    }

    var isPictureInPictureStartPending: Bool {
        return isStartRequestPending
    }

    var isAutomaticFromInlineEnabled: Bool {
        automaticFromInlineEnabled
    }
    
    var isPictureInPicturePossible: Bool {
        return pipController?.isPictureInPicturePossible ?? false
    }

    static var isPictureInPictureSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }
    
    init(sampleBufferDisplayLayer: AVSampleBufferDisplayLayer, playbackLoadGeneration: Int = 0) {
        self.sampleBufferDisplayLayer = sampleBufferDisplayLayer
        self.playbackLoadGeneration = playbackLoadGeneration
        super.init()
        setupSampleBufferPictureInPicture()
    }

    func armTransition(attemptID: Int) {
        armedTransitionAttemptID = attemptID
        if isStartRequestPending {
            // An explicit request can join an automatic-from-inline transition after willStart.
            callbackTransitionAttemptID = attemptID
        }
    }
    
    private func setupSampleBufferPictureInPicture() {
        guard isPictureInPictureSupported,
              let displayLayer = sampleBufferDisplayLayer else {
            Logger.shared.log(
                "[PiPController] setup skipped: supported=\(isPictureInPictureSupported) hasDisplayLayer=\(sampleBufferDisplayLayer != nil)",
                type: "MPV"
            )
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
        Logger.shared.log(
            "[PiPController] initialized supported=\(isPictureInPictureSupported) possible=\(pipController?.isPictureInPicturePossible ?? false) autoInline=false layer={\(layerSnapshot())}",
            type: "MPV"
        )
    }

    func setCanStartPictureInPictureAutomaticallyFromInline(_ enabled: Bool) {
        #if !os(tvOS)
        guard automaticFromInlineEnabled != enabled else { return }
        automaticFromInlineEnabled = enabled
        pipController?.canStartPictureInPictureAutomaticallyFromInline = enabled
        Logger.shared.log("[PiPController] autoInline set to \(enabled) possible=\(pipController?.isPictureInPicturePossible ?? false) layer={\(layerSnapshot())}", type: "MPV")
        #endif
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
        stopPictureInPicture(source: "unspecified")
    }

    func stopPictureInPicture(source: String) {
        let wasPending = isStartRequestPending
        let wasActive = pipController?.isPictureInPictureActive ?? false
        let wasPossible = pipController?.isPictureInPicturePossible ?? false
        isStartRequestPending = false
        Logger.shared.log("[PiPController] stop requested source=\(source) active=\(wasActive) possible=\(wasPossible) pending=\(wasPending) layer={\(layerSnapshot())}", type: "MPV")
        pipController?.stopPictureInPicture()
    }
    
    func invalidate() {
        pipController?.invalidatePlaybackState()
    }

    /// Permanently detaches this AVKit controller before the player installs a controller for a
    /// newer media load. Late callbacks stay on this object and cannot reach the new load.
    func invalidateForReplacement() {
        let wasPending = isStartRequestPending
        let wasActive = pipController?.isPictureInPictureActive ?? false
        Logger.shared.log(
            "[PiPController] invalidating replacement loadGeneration=\(playbackLoadGeneration) attemptID=\(transitionAttemptID) active=\(wasActive) possible=\(pipController?.isPictureInPicturePossible ?? false) pending=\(wasPending) layer={\(layerSnapshot())}",
            type: "PiPTrace"
        )
        isStartRequestPending = false
        pictureInPictureWillStartSequence &+= 1
        callbackTransitionAttemptID = nil
        automaticFromInlineEnabled = false
        #if !os(tvOS)
        pipController?.canStartPictureInPictureAutomaticallyFromInline = false
        #endif
        pipController?.delegate = nil
        // On tvOS, stopPictureInPicture can stop the system's currently active PiP session even
        // when it belongs to another app. Only stop a transition this wrapper actually owned.
        // iOS/iPadOS must stop unconditionally because AVKit can have a queued automatic start
        // before it publishes willStart and flips this wrapper's pending bit.
#if os(tvOS)
        if wasPending || wasActive {
            pipController?.stopPictureInPicture()
        }
#else
        pipController?.stopPictureInPicture()
#endif
        pipController?.invalidatePlaybackState()
        pipController = nil
        delegate = nil
    }
    
    func updatePlaybackState() {
        pipController?.invalidatePlaybackState()
    }

    private func layerSnapshot() -> String {
        guard let layer = sampleBufferDisplayLayer else { return "nil" }
        let nsError = layer.error.map { $0 as NSError }
        let errorText = nsError.map { "\($0.domain)#\($0.code)" } ?? "nil"
        let readyForDisplay: String
        if #available(iOS 17.4, tvOS 17.4, *) {
            readyForDisplay = String(layer.isReadyForDisplay)
        } else {
            readyForDisplay = "unavailable"
        }
        let timebase: String
        if let controlTimebase = layer.controlTimebase {
            let time = CMTimeGetSeconds(CMTimebaseGetTime(controlTimebase))
            timebase = "\(String(format: "%.2f", time))@\(String(format: "%.2f", CMTimebaseGetRate(controlTimebase)))"
        } else {
            timebase = "nil"
        }
        return "readyForDisplay=\(readyForDisplay) readyForMore=\(layer.isReadyForMoreMediaData) status=\(layerStatusName(layer.status)) error=\(errorText) hidden=\(layer.isHidden) opacity=\(String(format: "%.2f", layer.opacity)) frame=\(String(format: "%.0fx%.0f", layer.bounds.width, layer.bounds.height)) timebase=\(timebase)"
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
        // A finite duration remains valid through the end of playback. Requiring it to be more
        // than one second *ahead* of the current time made an ordinary VOD look indefinite during
        // its final second, so the PiP timeline suddenly gained a synthesized ten minutes. Allow a
        // small amount of clock skew past the reported end while still rejecting a stale duration
        // that is materially behind the renderer position.
        let durationIsUsable = rawDuration.isFinite
            && rawDuration > 0
            && currentTime <= rawDuration + 1.0
        let duration = durationIsUsable ? rawDuration : max(600, currentTime + 600)
        return (min(currentTime, max(0, duration - 0.5)), duration, rawDuration, !durationIsUsable)
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        // Automatic-from-inline entry does not pass through startPictureInPicture(), so establish
        // the same pending latch here. Teardown can then cancel the AVKit handoff before stopping
        // the renderer instead of allowing an automatic start to complete against a dead layer.
        pictureInPictureWillStartSequence &+= 1
        isStartRequestPending = true
        callbackTransitionAttemptID = armedTransitionAttemptID
        Logger.shared.log("[PiPController] stage=will-start active=\(pictureInPictureController.isPictureInPictureActive) suspended=\(pictureInPictureController.isPictureInPictureSuspended) possible=\(pictureInPictureController.isPictureInPicturePossible) pending=\(isStartRequestPending) layer={\(layerSnapshot())}", type: "PiPTrace")
        delegate?.pipController(self, willStartPictureInPicture: true)
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStartRequestPending = false
        let startedAttemptID = transitionAttemptID
        Logger.shared.log("[PiPController] stage=did-start active=\(pictureInPictureController.isPictureInPictureActive) suspended=\(pictureInPictureController.isPictureInPictureSuspended) possible=\(pictureInPictureController.isPictureInPicturePossible) pending=\(isStartRequestPending) layer={\(layerSnapshot())}", type: "PiPTrace")
        delegate?.pipController(
            self,
            didStartPictureInPicture: true,
            attemptID: startedAttemptID
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak pictureInPictureController] in
            guard let self, let pictureInPictureController else { return }
            let times = self.sanitizedPlaybackTimes()
            let currentText = String(format: "%.2f", times.currentTime)
            let durationText = String(format: "%.2f", times.duration)
            Logger.shared.log("[PiPController] stage=post-start-health active=\(pictureInPictureController.isPictureInPictureActive) suspended=\(pictureInPictureController.isPictureInPictureSuspended) possible=\(pictureInPictureController.isPictureInPicturePossible) playing=\(self.delegate?.pipControllerIsPlaying(self) ?? false) current=\(currentText) duration=\(durationText) layer={\(self.layerSnapshot())}", type: "PiPTrace")
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        isStartRequestPending = false
        let failedAttemptID = transitionAttemptID
        let willStartSequenceAtFailure = pictureInPictureWillStartSequence
        let nsError = error as NSError
        Logger.shared.log("[PiPController] stage=failed-to-start error=\(nsError.domain)#\(nsError.code) desc=\(nsError.localizedDescription) active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) pending=\(isStartRequestPending) hasDelegate=\(delegate != nil) layer={\(layerSnapshot())}", type: "PiPTrace")
        DispatchQueue.main.async { [weak self, weak pictureInPictureController] in
            guard let self, let pictureInPictureController else { return }
            let newerWillStart = self.pictureInPictureWillStartSequence != willStartSequenceAtFailure
            let active = pictureInPictureController.isPictureInPictureActive
            if newerWillStart || active {
                Logger.shared.log(
                    "[PiPController] stage=failed-to-start-superseded attemptID=\(failedAttemptID) newerWillStart=\(newerWillStart) active=\(active) pending=\(self.isStartRequestPending) layer={\(self.layerSnapshot())}",
                    type: "PiPTrace"
                )
                return
            }
            self.delegate?.pipController(
                self,
                didStartPictureInPicture: false,
                attemptID: failedAttemptID
            )
            if self.callbackTransitionAttemptID == failedAttemptID {
                self.callbackTransitionAttemptID = nil
            }
        }
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStartRequestPending = false
        Logger.shared.log("[PiPController] stage=will-stop active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) pending=\(isStartRequestPending) layer={\(layerSnapshot())}", type: "PiPTrace")
        delegate?.pipController(self, willStopPictureInPicture: true)
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Logger.shared.log("[PiPController] stage=did-stop active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) pending=\(isStartRequestPending) layer={\(layerSnapshot())}", type: "PiPTrace")
        delegate?.pipController(self, didStopPictureInPicture: true)
        callbackTransitionAttemptID = nil
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        let completion = PiPRestoreCompletionOnce(completionHandler)
        let attemptID = transitionAttemptID
        Logger.shared.log(
            "[PiPController] stage=restore-ui-request loadGeneration=\(playbackLoadGeneration) attemptID=\(attemptID) active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) hasDelegate=\(delegate != nil) layer={\(layerSnapshot())}",
            type: "PiPTrace"
        )
        guard let delegate else {
            Logger.shared.log(
                "[PiPController] stage=restore-ui-complete restored=false reason=no-delegate loadGeneration=\(playbackLoadGeneration) attemptID=\(attemptID) layer={\(layerSnapshot())}",
                type: "PiPTrace"
            )
            completion(false)
            return
        }
        delegate.pipController(self, restoreUserInterfaceForPictureInPictureStop: { restored in
            Logger.shared.log(
                "[PiPController] stage=restore-ui-complete restored=\(restored) loadGeneration=\(self.playbackLoadGeneration) attemptID=\(attemptID) layer={\(self.layerSnapshot())}",
                type: "PiPTrace"
            )
            completion(restored)
        })
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Logger.shared.log(
            "[PiPController] stage=set-playing playing=\(playing) active=\(pictureInPictureController.isPictureInPictureActive) suspended=\(pictureInPictureController.isPictureInPictureSuspended) pending=\(isStartRequestPending) attemptID=\(transitionAttemptID) layer={\(layerSnapshot())}",
            type: "PiPTrace"
        )
        guard let delegate else { return }
        let callbackAttemptID = transitionAttemptID
        delegate.pipController(self, setPlaying: playing) { [weak self, weak pictureInPictureController] in
            guard let self,
                  let pictureInPictureController,
                  self.pipController === pictureInPictureController,
                  self.callbackTransitionAttemptID == callbackAttemptID else { return }
            pictureInPictureController.invalidatePlaybackState()
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        Logger.shared.log("[PiPController] stage=render-size size=\(newRenderSize.width)x\(newRenderSize.height) layer={\(layerSnapshot())}", type: "PiPTrace")
        delegate?.pipController(
            self,
            didTransitionToRenderSize: CGSize(
                width: CGFloat(newRenderSize.width),
                height: CGFloat(newRenderSize.height)
            )
        )
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        let seconds = CMTimeGetSeconds(skipInterval)
        let times = sanitizedPlaybackTimes()
        Logger.shared.log("[PiPController] skip callback interval=\(String(format: "%.2f", seconds)) current=\(String(format: "%.2f", times.currentTime)) duration=\(String(format: "%.2f", times.duration)) rawDuration=\(String(format: "%.2f", times.rawDuration)) synthesized=\(times.synthesizedDuration) active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) layer={\(layerSnapshot())}", type: "MPV")
        guard let delegate else {
            completionHandler()
            return
        }
        let callbackAttemptID = transitionAttemptID
        delegate.pipController(self, skipByInterval: skipInterval) { [weak self, weak pictureInPictureController] in
            guard let self,
                  let pictureInPictureController,
                  self.pipController === pictureInPictureController,
                  self.callbackTransitionAttemptID == callbackAttemptID else {
                completionHandler()
                return
            }
            pictureInPictureController.invalidatePlaybackState()
            completionHandler()
        }
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let times = sanitizedPlaybackTimes()
        return CMTimeRange(start: .zero, duration: CMTime(seconds: times.duration, preferredTimescale: 1000))
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return !(delegate?.pipControllerIsPlaying(self) ?? false)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool, completion: @escaping () -> Void) {
        Logger.shared.log(
            "[PiPController] stage=set-playing-completion playing=\(playing) active=\(pictureInPictureController.isPictureInPictureActive) suspended=\(pictureInPictureController.isPictureInPictureSuspended) pending=\(isStartRequestPending) attemptID=\(transitionAttemptID) layer={\(layerSnapshot())}",
            type: "PiPTrace"
        )
        guard let delegate else {
            completion()
            return
        }
        let callbackAttemptID = transitionAttemptID
        delegate.pipController(self, setPlaying: playing) { [weak self, weak pictureInPictureController] in
            guard let self,
                  let pictureInPictureController,
                  self.pipController === pictureInPictureController,
                  self.callbackTransitionAttemptID == callbackAttemptID else {
                completion()
                return
            }
            pictureInPictureController.invalidatePlaybackState()
            completion()
        }
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
