#if os(tvOS)
import AVFoundation
import AVKit
import CoreMedia
import MediaPlayer
import UIKit
import MPVKitSampleBufferGPL

@MainActor
final class TVMPVPlayerViewController: UIViewController {
    var onFirstFrame: (() -> Void)?
    var onProgress: ((_ position: Double, _ duration: Double, _ isPlaying: Bool) -> Void)?
    var onStartupFailure: ((String) -> Void)?
    var onRetryWithAVPlayer: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private let request: PlaybackRequest
    private let renderer = MPVTVRenderer()
    private var didStart = false
    private var didStop = false
    private var didReportStartupFailure = false
    private var controlsVisible = true
    private var controlsContainFocus = false
    private var autoHideWorkItem: DispatchWorkItem?
    private var pictureInPictureController: AVPictureInPictureController?
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var lastDisplayFrameRate: Double = 0
    private var lastVideoDiagnostics: MPVGPUPlayerRendererDiagnostics?
    private weak var activeDisplayManager: AVDisplayManager?
    private var displayCriteriaReapplyWorkItem: DispatchWorkItem?
    private var latestPosition: Double = 0
    private var latestDuration: Double = 0
    private var latestErrorMessage = "Playback failed."

    private let controlsGradient = TVPlayerGradientView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let progressView = UIProgressView()
    private let timelineFocusButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let rewindButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let pictureInPictureButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let transportStack = UIStackView()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()

    init(request: PlaybackRequest) {
        self.request = request
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureRendererCallbacks()
        configureDisplayChangeObservers()
        configureRemoteCommands()
        updateNowPlaying(position: 0, duration: 0, isPlaying: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        renderer.view.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        clearPreferredDisplayCriteria()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if controlsVisible { return [playPauseButton] }
        return [view]
    }

    func startPlayback() {
        guard !didStart else { return }
        didStart = true
        do {
            try renderer.start(request)
            loadingIndicator.startAnimating()
            showControls(animated: false, moveFocus: true)
        } catch {
            handleStartupFailure(error.localizedDescription)
        }
    }

    /// Captures the portable part of the current MPV track selection before switching engines.
    /// MPV numeric track IDs are not forwarded because AVFoundation uses unrelated
    /// `AVMediaSelectionOption` identities; language is the only reliable mapping.
    func avPlayerFallbackSelectionIntent() -> PlaybackMediaSelectionIntent {
        let audioTracks = renderer.audioTracks()
        let subtitleTracks = renderer.subtitleTracks()
        let selectedAudio = audioTracks.first(where: \.selected)
        let selectedSubtitle = subtitleTracks.first(where: \.selected)
        return request.mediaSelectionIntent.overridingRendererSelection(
            audioLanguage: selectedAudio?.language,
            subtitleLanguage: selectedSubtitle?.language,
            hasSelectedSubtitle: subtitleTracks.isEmpty ? nil : selectedSubtitle != nil
        )
    }

    var isPlaybackActive: Bool {
        !didStop && !renderer.isPaused
    }

    func stopPlayback() {
        guard !didStop else { return }
        didStop = true
        autoHideWorkItem?.cancel()
        displayCriteriaReapplyWorkItem?.cancel()
        if pictureInPictureController?.isPictureInPictureActive == true {
            pictureInPictureController?.stopPictureInPicture()
        }
        renderer.stop()
        clearPreferredDisplayCriteria()
        removeRemoteCommands()
        clearNowPlaying()
    }

    func seekToPlaybackPosition(_ position: Double) {
        guard position.isFinite, position >= 0, !didStop else { return }
        renderer.seek(to: position)
        showControls(animated: true, moveFocus: false)
    }

    func pauseForNextEpisodePrompt() -> Bool {
        guard !didStop else { return false }
        let wasPlaying = !renderer.isPaused
        renderer.pause()
        autoHideWorkItem?.cancel()
        return wasPlaying
    }

    func resumeAfterNextEpisodePrompt() {
        guard !didStop else { return }
        renderer.play()
        scheduleControlsAutoHide()
    }

    override func didUpdateFocus(
        in context: UIFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let focused = context.nextFocusedView {
            controlsContainFocus = focused === controlsGradient || focused.isDescendant(of: controlsGradient)
        } else {
            controlsContainFocus = false
        }
        if controlsContainFocus {
            autoHideWorkItem?.cancel()
        } else {
            scheduleControlsAutoHide()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first else {
            super.pressesBegan(presses, with: event)
            return
        }
        switch press.type {
        case .playPause:
            renderer.togglePlayback()
            showControls(animated: true, moveFocus: false)
        case .select where !controlsVisible:
            showControls(animated: true, moveFocus: true)
        case .leftArrow where timelineFocusButton.isFocused:
            seek(by: -seekInterval)
        case .rightArrow where timelineFocusButton.isFocused:
            seek(by: seekInterval)
        case .menu:
            if controlsVisible {
                hideControls(animated: true, forced: true)
            } else {
                onDismiss?()
            }
        default:
            super.pressesBegan(presses, with: event)
        }
    }

    private var seekInterval: Double {
        let stored = UserDefaults.standard.double(forKey: "playerDoubleTapSeekSeconds")
        return stored >= 5 ? min(stored, 60) : 10
    }

    private func configureHierarchy() {
        view.backgroundColor = .black
        renderer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(renderer.view)
        NSLayoutConstraint.activate([
            renderer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            renderer.view.topAnchor.constraint(equalTo: view.topAnchor),
            renderer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        controlsGradient.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsGradient)
        NSLayoutConstraint.activate([
            controlsGradient.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsGradient.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlsGradient.topAnchor.constraint(equalTo: view.topAnchor),
            controlsGradient.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        configureLabel(titleLabel, font: .systemFont(ofSize: 42, weight: .bold), color: .white)
        configureLabel(subtitleLabel, font: .systemFont(ofSize: 24, weight: .medium), color: .white.withAlphaComponent(0.72))
        configureLabel(elapsedLabel, font: .monospacedDigitSystemFont(ofSize: 20, weight: .medium), color: .white)
        configureLabel(remainingLabel, font: .monospacedDigitSystemFont(ofSize: 20, weight: .medium), color: .white)
        titleLabel.text = request.title.isEmpty ? fallbackTitle : request.title
        subtitleLabel.text = request.subtitle
        subtitleLabel.isHidden = request.subtitle?.isEmpty != false

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .white.withAlphaComponent(0.25)
        progressView.progressTintColor = .white
        progressView.layer.cornerRadius = 3
        progressView.clipsToBounds = true

        timelineFocusButton.translatesAutoresizingMaskIntoConstraints = false
        timelineFocusButton.setTitle("Timeline", for: .normal)
        timelineFocusButton.setTitleColor(.clear, for: .normal)
        timelineFocusButton.backgroundColor = .clear
        timelineFocusButton.accessibilityLabel = "Playback timeline"
        timelineFocusButton.accessibilityIdentifier = "tv.player.timeline"
        timelineFocusButton.accessibilityHint = "Press left or right to seek"
        timelineFocusButton.addAction(UIAction { [weak self] _ in
            self?.showControls(animated: true, moveFocus: false)
        }, for: .primaryActionTriggered)

        configureTransportButton(rewindButton, symbol: "gobackward.10", title: "Rewind") { [weak self] in
            self?.seek(by: -(self?.seekInterval ?? 10))
        }
        configureTransportButton(playPauseButton, symbol: "pause.fill", title: "Pause") { [weak self] in
            self?.renderer.togglePlayback()
        }
        configureTransportButton(forwardButton, symbol: "goforward.10", title: "Fast Forward") { [weak self] in
            self?.seek(by: self?.seekInterval ?? 10)
        }
        configureTransportButton(audioButton, symbol: "speaker.wave.3.fill", title: "Audio") { [weak self] in
            self?.showAudioMenu()
        }
        configureTransportButton(subtitleButton, symbol: "captions.bubble.fill", title: "Subtitles") { [weak self] in
            self?.showSubtitleMenu()
        }
        configureTransportButton(pictureInPictureButton, symbol: "pip.enter", title: "Picture in Picture") { [weak self] in
            self?.startPictureInPicture()
        }
        rewindButton.accessibilityIdentifier = "tv.player.rewind"
        playPauseButton.accessibilityIdentifier = "tv.player.playPause"
        forwardButton.accessibilityIdentifier = "tv.player.forward"
        audioButton.accessibilityIdentifier = "tv.player.audio"
        subtitleButton.accessibilityIdentifier = "tv.player.subtitles"
        pictureInPictureButton.accessibilityIdentifier = "tv.player.pictureInPicture"
        pictureInPictureButton.isHidden = !renderer.canStartPictureInPicture

        transportStack.translatesAutoresizingMaskIntoConstraints = false
        transportStack.axis = .horizontal
        transportStack.alignment = .center
        transportStack.distribution = .equalSpacing
        transportStack.spacing = 26
        [rewindButton, playPauseButton, forwardButton, audioButton, subtitleButton, pictureInPictureButton]
            .forEach(transportStack.addArrangedSubview)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.color = .white
        view.addSubview(loadingIndicator)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        errorLabel.textColor = .white
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 3
        errorLabel.isHidden = true
        view.addSubview(errorLabel)

        configureTransportButton(retryButton, symbol: "play.rectangle.fill", title: "Retry with AVPlayer") { [weak self] in
            guard let self else { return }
            self.onRetryWithAVPlayer?(self.latestErrorMessage)
        }
        retryButton.isHidden = true
        view.addSubview(retryButton)

        let timelineRow = UIView()
        timelineRow.translatesAutoresizingMaskIntoConstraints = false
        timelineRow.addSubview(elapsedLabel)
        timelineRow.addSubview(progressView)
        timelineRow.addSubview(timelineFocusButton)
        timelineRow.addSubview(remainingLabel)
        NSLayoutConstraint.activate([
            elapsedLabel.leadingAnchor.constraint(equalTo: timelineRow.leadingAnchor),
            elapsedLabel.centerYAnchor.constraint(equalTo: progressView.centerYAnchor),
            elapsedLabel.widthAnchor.constraint(equalToConstant: 110),
            progressView.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 20),
            progressView.trailingAnchor.constraint(equalTo: remainingLabel.leadingAnchor, constant: -20),
            progressView.centerYAnchor.constraint(equalTo: timelineRow.centerYAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 8),
            timelineFocusButton.leadingAnchor.constraint(equalTo: progressView.leadingAnchor, constant: -16),
            timelineFocusButton.trailingAnchor.constraint(equalTo: progressView.trailingAnchor, constant: 16),
            timelineFocusButton.topAnchor.constraint(equalTo: timelineRow.topAnchor),
            timelineFocusButton.bottomAnchor.constraint(equalTo: timelineRow.bottomAnchor),
            remainingLabel.trailingAnchor.constraint(equalTo: timelineRow.trailingAnchor),
            remainingLabel.centerYAnchor.constraint(equalTo: progressView.centerYAnchor),
            remainingLabel.widthAnchor.constraint(equalToConstant: 130),
            timelineRow.heightAnchor.constraint(equalToConstant: 76)
        ])

        let content = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, timelineRow, transportStack])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 14
        content.setCustomSpacing(26, after: subtitleLabel)
        content.setCustomSpacing(18, after: timelineRow)
        controlsGradient.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: controlsGradient.safeAreaLayoutGuide.leadingAnchor, constant: 70),
            content.trailingAnchor.constraint(equalTo: controlsGradient.safeAreaLayoutGuide.trailingAnchor, constant: -70),
            content.bottomAnchor.constraint(equalTo: controlsGradient.safeAreaLayoutGuide.bottomAnchor, constant: -48),
            transportStack.heightAnchor.constraint(equalToConstant: 96),
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -60),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.65),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 36),
            retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 330),
            retryButton.heightAnchor.constraint(equalToConstant: 72)
        ])
    }

    private func configureRendererCallbacks() {
        renderer.onFirstFrame = { [weak self] in
            guard let self else { return }
            self.loadingIndicator.stopAnimating()
            self.onFirstFrame?()
            self.scheduleControlsAutoHide()
        }
        renderer.onStartupFailure = { [weak self] message in self?.handleStartupFailure(message) }
        renderer.onPlaybackFailure = { [weak self] message in self?.handlePlaybackFailure(message) }
        renderer.onStateChange = { [weak self] state in self?.handleRendererState(state) }
        renderer.onPositionChange = { [weak self] position, duration in
            self?.updateProgress(position: position, duration: duration)
        }
        renderer.onVideoFormatChange = { [weak self] diagnostics in
            self?.lastVideoDiagnostics = diagnostics
            self?.applyPreferredDisplayCriteria(for: diagnostics)
        }
        renderer.onTracksChange = { [weak self] in self?.updateTrackButtonAvailability() }
    }

    private func handleRendererState(_ state: MPVTVRenderer.State) {
        switch state {
        case .loading:
            loadingIndicator.startAnimating()
        case .playing:
            loadingIndicator.stopAnimating()
            setButton(playPauseButton, symbol: "pause.fill", title: "Pause")
            scheduleControlsAutoHide()
        case .paused:
            loadingIndicator.stopAnimating()
            setButton(playPauseButton, symbol: "play.fill", title: "Play")
            showControls(animated: true, moveFocus: false)
            autoHideWorkItem?.cancel()
        case .failed(let message):
            latestErrorMessage = message
        default:
            break
        }
    }

    private func handleStartupFailure(_ message: String) {
        // `MPVTVRenderer.start` reports post-setup failures through its callback before it
        // rethrows to `startPlayback`. Keep this idempotent so the automatic AVPlayer fallback
        // cannot be followed immediately by a second, terminal-error path.
        guard !didReportStartupFailure else { return }
        didReportStartupFailure = true
        loadingIndicator.stopAnimating()
        latestErrorMessage = message
        onStartupFailure?(message)
    }

    private func handlePlaybackFailure(_ message: String) {
        loadingIndicator.stopAnimating()
        latestErrorMessage = message
        errorLabel.text = message
        errorLabel.isHidden = false
        retryButton.isHidden = false
        showControls(animated: true, moveFocus: false)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func updateProgress(position: Double, duration: Double) {
        latestPosition = position.isFinite ? max(0, position) : 0
        latestDuration = duration.isFinite ? max(0, duration) : 0
        progressView.progress = latestDuration > 0 ? Float(min(latestPosition / latestDuration, 1)) : 0
        elapsedLabel.text = formatTime(latestPosition)
        remainingLabel.text = latestDuration > 0 ? "−\(formatTime(max(0, latestDuration - latestPosition)))" : "−−:−−"
        updateNowPlaying(position: latestPosition, duration: latestDuration, isPlaying: !renderer.isPaused)
        onProgress?(latestPosition, latestDuration, !renderer.isPaused)
        pictureInPictureController?.invalidatePlaybackState()
    }

    private func seek(by delta: Double) {
        renderer.seek(by: delta)
        showControls(animated: true, moveFocus: false)
        UIAccessibility.post(notification: .announcement, argument: delta < 0 ? "Rewound \(Int(abs(delta))) seconds" : "Forward \(Int(delta)) seconds")
    }

    private func showControls(animated: Bool, moveFocus: Bool) {
        controlsVisible = true
        controlsGradient.isHidden = false
        controlsGradient.isUserInteractionEnabled = true
        let changes = { self.controlsGradient.alpha = 1 }
        animated ? UIView.animate(withDuration: 0.2, animations: changes) : changes()
        if moveFocus {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
        scheduleControlsAutoHide()
    }

    private func hideControls(animated: Bool, forced: Bool = false) {
        guard controlsVisible else { return }
        guard forced || (!renderer.isPaused && !controlsContainFocus && presentedViewController == nil) else { return }
        controlsVisible = false
        controlsGradient.isUserInteractionEnabled = false
        let changes = { self.controlsGradient.alpha = 0 }
        let completion: (Bool) -> Void = { _ in self.controlsGradient.isHidden = true }
        if animated {
            UIView.animate(withDuration: 0.25, animations: changes, completion: completion)
        } else {
            changes()
            completion(true)
        }
    }

    private func scheduleControlsAutoHide() {
        autoHideWorkItem?.cancel()
        guard !renderer.isPaused, !controlsContainFocus, presentedViewController == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.hideControls(animated: true) }
        autoHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
    }

    private func showAudioMenu() {
        let tracks = renderer.audioTracks()
        guard !tracks.isEmpty else { return }
        let alert = UIAlertController(title: "Audio", message: nil, preferredStyle: .alert)
        tracks.forEach { track in
            let marker = track.selected ? "✓ " : ""
            let language = track.language.isEmpty ? "" : " · \(track.language.uppercased())"
            alert.addAction(UIAlertAction(title: "\(marker)\(track.title)\(language)", style: .default) { [weak self] _ in
                self?.renderer.setAudioTrack(track.id)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showSubtitleMenu() {
        let tracks = renderer.subtitleTracks()
        let alert = UIAlertController(title: "Subtitles", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: renderer.subtitleTracks().contains(where: { $0.selected }) ? "Off" : "✓ Off", style: .default) { [weak self] _ in
            self?.renderer.disableSubtitles()
        })
        tracks.forEach { track in
            let marker = track.selected ? "✓ " : ""
            let language = track.language.isEmpty ? "" : " · \(track.language.uppercased())"
            alert.addAction(UIAlertAction(title: "\(marker)\(track.title)\(language)", style: .default) { [weak self] _ in
                self?.renderer.setSubtitleTrack(track.id)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func updateTrackButtonAvailability() {
        audioButton.isEnabled = !renderer.audioTracks().isEmpty
        subtitleButton.isEnabled = !renderer.subtitleTracks().isEmpty
    }

    private func startPictureInPicture() {
        guard renderer.canStartPictureInPicture else { return }
        if pictureInPictureController == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: renderer.pictureInPictureDisplayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.requiresLinearPlayback = false
            pictureInPictureController = controller
        }
        guard renderer.preparePictureInPicture() else {
            handlePlaybackFailure("Picture in Picture could not prepare this stream.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let controller = self.pictureInPictureController else { return }
            guard controller.isPictureInPicturePossible else {
                self.handlePlaybackFailure("Picture in Picture is not currently available.")
                return
            }
            controller.startPictureInPicture()
        }
    }

    private func applyPreferredDisplayCriteria(
        for diagnostics: MPVGPUPlayerRendererDiagnostics,
        force: Bool = false
    ) {
        let fps = diagnostics.estimatedFramesPerSecond
        guard fps.isFinite, (10...120).contains(fps) else { return }
        if !force, abs(fps - lastDisplayFrameRate) <= 0.05 { return }
        guard let manager = view.window?.avDisplayManager, manager.isDisplayCriteriaMatchingEnabled else { return }
        var formatDescription: CMVideoFormatDescription?
        let dimensions = CMVideoDimensions(
            width: Int32(max(1, diagnostics.videoWidth)),
            height: Int32(max(1, diagnostics.videoHeight))
        )
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: displayCodecType(for: diagnostics.videoCodec),
            width: dimensions.width,
            height: dimensions.height,
            extensions: displayFormatExtensions(for: diagnostics),
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { return }
        if activeDisplayManager !== manager {
            activeDisplayManager?.preferredDisplayCriteria = nil
            activeDisplayManager = manager
        }
        lastDisplayFrameRate = fps
        manager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(fps),
            formatDescription: formatDescription
        )
    }

    private func displayCodecType(for codec: String) -> CMVideoCodecType {
        let normalized = codec.lowercased()
        if normalized.contains("hevc") || normalized.contains("h265") {
            return kCMVideoCodecType_HEVC
        }
        if normalized.contains("av1") {
            return 0x61763031 // av01
        }
        if normalized.contains("vp9") {
            return 0x76703039 // vp09
        }
        return kCMVideoCodecType_H264
    }

    private func displayFormatExtensions(
        for diagnostics: MPVGPUPlayerRendererDiagnostics
    ) -> CFDictionary? {
        let primaries = diagnostics.videoColorPrimaries.lowercased()
        let transfer = diagnostics.videoTransferFunction.lowercased()
        var extensions: [CFString: Any] = [:]

        if primaries.contains("2020") {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        } else if primaries.contains("p3") {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_P3_D65
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        } else if !primaries.isEmpty {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        }

        if transfer.contains("pq") || transfer.contains("2084") {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        } else if transfer.contains("hlg") || transfer.contains("2100") {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        } else if !transfer.isEmpty {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        }

        return extensions.isEmpty ? nil : extensions as CFDictionary
    }

    private func clearPreferredDisplayCriteria() {
        displayCriteriaReapplyWorkItem?.cancel()
        displayCriteriaReapplyWorkItem = nil
        activeDisplayManager?.preferredDisplayCriteria = nil
        if view.window?.avDisplayManager !== activeDisplayManager {
            view.window?.avDisplayManager.preferredDisplayCriteria = nil
        }
        activeDisplayManager = nil
        lastDisplayFrameRate = 0
    }

    private func configureDisplayChangeObservers() {
        let center = NotificationCenter.default
        for name in [
            AVAudioSession.routeChangeNotification,
            UIScreen.didConnectNotification,
            UIScreen.didDisconnectNotification,
            .AVDisplayManagerModeSwitchSettingsChanged
        ] {
            center.addObserver(
                self,
                selector: #selector(handleDisplayOrRouteChange),
                name: name,
                object: nil
            )
        }
    }

    @objc private func handleDisplayOrRouteChange() {
        guard !didStop, let diagnostics = lastVideoDiagnostics else { return }

        // A receiver/HDMI/AirPlay route change can replace AVDisplayManager while retaining the
        // same source FPS. Resetting the FPS gate is essential; otherwise the ordinary diagnostics
        // callback suppresses the criteria as a duplicate and the new display stays unmatched.
        activeDisplayManager?.preferredDisplayCriteria = nil
        activeDisplayManager = nil
        lastDisplayFrameRate = 0
        displayCriteriaReapplyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.didStop else { return }
            self.applyPreferredDisplayCriteria(for: diagnostics, force: true)
        }
        displayCriteriaReapplyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        addRemoteTarget(commands.playCommand) { [weak self] _ in self?.renderer.play(); return .success }
        addRemoteTarget(commands.pauseCommand) { [weak self] _ in self?.renderer.pause(); return .success }
        addRemoteTarget(commands.togglePlayPauseCommand) { [weak self] _ in self?.renderer.togglePlayback(); return .success }
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: seekInterval)]
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: seekInterval)]
        addRemoteTarget(commands.skipForwardCommand) { [weak self] _ in self?.seek(by: self?.seekInterval ?? 10); return .success }
        addRemoteTarget(commands.skipBackwardCommand) { [weak self] _ in self?.seek(by: -(self?.seekInterval ?? 10)); return .success }
        addRemoteTarget(commands.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.renderer.seek(to: event.positionTime)
            return .success
        }
    }

    private func addRemoteTarget(_ command: MPRemoteCommand, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        let target = command.addTarget(handler: handler)
        remoteCommandTargets.append((command, target))
    }

    private func removeRemoteCommands() {
        remoteCommandTargets.forEach { $0.0.removeTarget($0.1) }
        remoteCommandTargets.removeAll()
    }

    private func updateNowPlaying(position: Double, duration: Double, isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: request.title.isEmpty ? fallbackTitle : request.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? renderer.diagnosticsSnapshot().isPaused ? 0 : 1 : 0
        ]
        if let subtitle = request.subtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = subtitle
        }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private var fallbackTitle: String {
        switch request.mediaInfo {
        case .movie(_, let title, _, _): return title
        case .episode(_, let season, let episode, let title, _, _):
            return [title, "S\(season) E\(episode)"].compactMap { $0 }.joined(separator: " · ")
        case nil: return request.url.lastPathComponent.isEmpty ? "Eclipse" : request.url.lastPathComponent
        }
    }

    private func configureLabel(_ label: UILabel, font: UIFont, color: UIColor) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = color
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.65
    }

    private func configureTransportButton(
        _ button: UIButton,
        symbol: String,
        title: String,
        action: @escaping () -> Void
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.title = title
        configuration.imagePlacement = .top
        configuration.imagePadding = 8
        configuration.baseForegroundColor = .white
        button.configuration = configuration
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        button.heightAnchor.constraint(equalToConstant: 86).isActive = true
    }

    private func setButton(_ button: UIButton, symbol: String, title: String) {
        var configuration = button.configuration
        configuration?.image = UIImage(systemName: symbol)
        configuration?.title = title
        button.configuration = configuration
        button.accessibilityLabel = title
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "−−:−−" }
        let value = max(0, Int(seconds.rounded(.down)))
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let remainder = value % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }
}

extension TVMPVPlayerViewController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        renderer.beginPictureInPicture()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        renderer.endPictureInPicture(restoringInlinePlayback: true)
        showControls(animated: true, moveFocus: true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        renderer.endPictureInPicture(restoringInlinePlayback: true)
        handlePlaybackFailure("Picture in Picture failed: \(error.localizedDescription)")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

extension TVMPVPlayerViewController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        playing ? renderer.play() : renderer.pause()
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        renderer.seek(by: skipInterval.seconds)
        pictureInPictureController.invalidatePlaybackState()
        completionHandler()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let duration = renderer.duration.isFinite && renderer.duration > 0 ? renderer.duration : 1
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        renderer.isPaused
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}
}

private final class TVPlayerGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let gradient = layer as? CAGradientLayer
        gradient?.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.88).cgColor]
        gradient?.locations = [0, 0.48, 1]
        gradient?.startPoint = CGPoint(x: 0.5, y: 0)
        gradient?.endPoint = CGPoint(x: 0.5, y: 1)
    }

    required init?(coder: NSCoder) { nil }
}
#endif
