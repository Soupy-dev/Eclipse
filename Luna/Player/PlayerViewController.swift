//
//  PlayerViewController.swift
//  test
//
//  Created by Francesco on 28/09/25.
//

import UIKit
import SwiftUI
import AVFoundation
#if canImport(AVKit)
import AVKit
#endif

final class PlayerViewController: UIViewController, UIGestureRecognizerDelegate {
    private let playerLogId = UUID().uuidString.prefix(8)
    private let trackerManager = TrackerManager.shared

    private let videoContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .black
        v.clipsToBounds = true
        return v
    }()
    
    private let tapOverlayView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        return v
    }()
    
    private let displayLayer = AVSampleBufferDisplayLayer()
    
    private func createSymbolButton(symbolName: String, pointSize: CGFloat = 18, weight: UIImage.SymbolWeight = .semibold, backgroundColor: UIColor? = nil) -> UIButton {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let img = UIImage(systemName: symbolName, withConfiguration: cfg)
        b.setImage(img, for: .normal)
        b.tintColor = .white
        if let bg = backgroundColor {
            b.backgroundColor = bg
            b.layer.cornerRadius = pointSize + 10
            b.clipsToBounds = true
        } else {
            b.alpha = 0.0
        }
        return b
    }
    
    private let centerPlayPauseButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        let configuration = UIImage.SymbolConfiguration(pointSize: 32, weight: .semibold)
        let image = UIImage(systemName: "play.fill", withConfiguration: configuration)
        b.setImage(image, for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor(white: 0.2, alpha: 0.5)
        b.layer.cornerRadius = 35
        b.clipsToBounds = true
        return b
    }()
    
    private let loadingIndicator: UIActivityIndicatorView = {
        let v: UIActivityIndicatorView
        v = UIActivityIndicatorView(style: .large)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.hidesWhenStopped = true
        v.color = .white
        v.alpha = 0.0
        return v
    }()
    
    private let controlsOverlayView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = UIColor(white: 0.0, alpha: 0.4)
        v.alpha = 0.0
        v.isUserInteractionEnabled = false
        v.isHidden = true
        return v
    }()
    
    private lazy var errorBanner: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor { trait -> UIColor in
            return trait.userInterfaceStyle == .dark ? UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 0.95) : UIColor(red: 0.9, green: 0.17, blue: 0.17, alpha: 0.98)
        }
        container.layer.cornerRadius = 10
        container.clipsToBounds = true
        container.alpha = 0.0
        
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
        icon.tintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.numberOfLines = 2
        label.tag = 101
        
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("View Logs", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        btn.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
        btn.layer.cornerRadius = 6
        
        if #unavailable(tvOS 15) {
            btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        }
        btn.addTarget(self, action: #selector(viewLogsTapped), for: .touchUpInside)
        
        container.addSubview(icon)
        container.addSubview(label)
        container.addSubview(btn)
        
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            
            btn.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            btn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            btn.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        
        return container
    }()
    
    private let closeButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let img = UIImage(systemName: "xmark", withConfiguration: cfg)
        b.setImage(img, for: .normal)
        b.tintColor = .white
        b.alpha = 0.0
        return b
    }()
    
    private let pipButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let img = UIImage(systemName: "pip.enter", withConfiguration: cfg)
        b.setImage(img, for: .normal)
        b.tintColor = .white
        b.alpha = 0.0
        return b
    }()
    
    private let skipBackwardButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        let img = UIImage(systemName: "gobackward.10", withConfiguration: cfg)
        b.setImage(img, for: .normal)
        b.tintColor = .white
        b.alpha = 0.0
        return b
    }()
    
    private let skipForwardButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        let img = UIImage(systemName: "goforward.10", withConfiguration: cfg)
        b.setImage(img, for: .normal)
        b.tintColor = .white
        b.alpha = 0.0
        return b
    }()
    
    private let speedIndicatorLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .bold)
        label.textAlignment = .center
        label.backgroundColor = UIColor(white: 0.2, alpha: 0.8)
        label.layer.cornerRadius = 20
        label.clipsToBounds = true
        label.alpha = 0.0
        return label
    }()
    
    private let subtitleButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let img = UIImage(systemName: "captions.bubble", withConfiguration: cfg)
        b.setImage(img, for: .normal)
        b.tintColor = .white
        b.alpha = 0.0
        b.isHidden = true
        // Will be set dynamically based on renderer type
        b.showsMenuAsPrimaryAction = false
        return b
    }()

    private let vlcSubtitleOverlayLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = .clear
        label.isHidden = true
        label.alpha = 0.0
        return label
    }()
    
    private let speedButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let img = UIImage(systemName: "hare.fill", withConfiguration: cfg)
        b.setImage(img, for: .normal)
        b.tintColor = .white
        b.alpha = 0.0
        b.showsMenuAsPrimaryAction = true
        return b
    }()
    
    private let audioButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let img = UIImage(systemName: "speaker.wave.2", withConfiguration: cfg)
        b.setImage(img, for: .normal)
        b.tintColor = .white
        b.alpha = 0.0
        b.showsMenuAsPrimaryAction = true
        return b
    }()

    private let dimmingView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .black
        v.alpha = 0.0
        v.isUserInteractionEnabled = false
        return v
    }()

#if !os(tvOS)
    private let brightnessContainer: UIVisualEffectView = {
        let effect: UIBlurEffect
        if #available(iOS 15.0, *) {
            effect = UIBlurEffect(style: .systemThinMaterialDark)
        } else {
            effect = UIBlurEffect(style: .dark)
        }
        let v = UIVisualEffectView(effect: effect)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layer.cornerRadius = 12
        v.clipsToBounds = true
        v.alpha = 0.0
        v.isHidden = true
        return v
    }()

    private let brightnessSlider: UISlider = {
        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumValue = 0.0
        slider.maximumValue = 1.0
        slider.value = 1.0
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.thumbTintColor = .white
        slider.transform = CGAffineTransform(rotationAngle: -.pi / 2)
        return slider
    }()

    private let brightnessIcon: UIImageView = {
        let icon = UIImageView(image: UIImage(systemName: "sun.max.fill"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.alpha = 0.8
        return icon
    }()
#endif
    
    private let progressContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        return v
    }()
    private var progressHostingController: UIHostingController<AnyView>?
    private var lastHostedDuration: Double = 0
    
    class ProgressModel: ObservableObject {
        @Published var position: Double = 0
        @Published var duration: Double = 1
        @Published var skipSegments: [(start: Double, end: Double)] = []
    }
    private var progressModel = ProgressModel()

    private var containerTapGesture: UITapGestureRecognizer?
    private var leftDoubleTapGesture: UITapGestureRecognizer?
    private var rightDoubleTapGesture: UITapGestureRecognizer?

    private var brightnessLevel: Float = 1.0
    private let twoFingerSettingKey = "mpvTwoFingerTapEnabled"
    private let brightnessLevelKey = "mpvBrightnessLevel"
    
    private lazy var renderer: Any = {
        // Select renderer based on Settings
        let playerChoice = Settings.shared.playerChoice
        
        if playerChoice == .vlc {
            let r = VLCRenderer(displayLayer: displayLayer)
            r.delegate = self
            return r
        } else {
            let r = MPVSoftwareRenderer(displayLayer: displayLayer)
            r.delegate = self
            return r
        }
    }()
    
    // Helper properties to access renderer methods regardless of type
    private var mpvRenderer: MPVSoftwareRenderer? {
        return renderer as? MPVSoftwareRenderer
    }
    
    private var vlcRenderer: VLCRenderer? {
        return renderer as? VLCRenderer
    }

    private var isVLCPlayer: Bool {
        return vlcRenderer != nil
    }
    
    var mediaInfo: MediaInfo?
    // Optional override: when true, treat content as anime regardless of tracker mapping
    var isAnimeHint: Bool?
    /// Original TMDB season/episode numbers for anime (before AniList restructuring).
    /// Used by TheIntroDB which requires TMDB numbering, not AniList-restructured S/E.
    var originalTMDBSeasonNumber: Int?
    var originalTMDBEpisodeNumber: Int?

    // MARK: - Skip Segments & Next Episode
    /// Called when the user taps "Next Episode" — passes (seasonNumber, nextEpisodeNumber).
    var onRequestNextEpisode: ((_ seasonNumber: Int, _ nextEpisodeNumber: Int) -> Void)?

    private var skipSegments: [SkipSegment] = []
    private var skipDataFetched = false
    private var autoSkippedSegments: Set<String> = []
    private var currentActiveSkipSegment: SkipSegment?
    private var nextEpisodeButtonShown = false
#if !os(tvOS)
    private var skip85sButtonShown = false
#endif

#if !os(tvOS)
    private lazy var skipButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.systemYellow
        config.baseForegroundColor = UIColor.black
        config.image = UIImage(systemName: "forward.end.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 18)
        config.title = "Skip Intro"
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.alpha = 0
        btn.isHidden = true
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = 0.3
        btn.layer.shadowOffset = CGSize(width: 0, height: 2)
        btn.layer.shadowRadius = 4
        return btn
    }()

    private lazy var nextEpisodeButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.2)
        config.baseForegroundColor = UIColor.white
        config.image = UIImage(systemName: "forward.end.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 18)
        config.title = "Next Episode"
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.alpha = 0
        btn.isHidden = true
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = 0.3
        btn.layer.shadowOffset = CGSize(width: 0, height: 2)
        btn.layer.shadowRadius = 4
        return btn
    }()

    private lazy var skip85sButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.2)
        config.baseForegroundColor = UIColor.white
        config.image = UIImage(systemName: "forward.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 18)
        config.title = "Skip 85s"
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.alpha = 0
        btn.isHidden = true
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = 0.3
        btn.layer.shadowOffset = CGSize(width: 0, height: 2)
        btn.layer.shadowRadius = 4
        return btn
    }()
#endif
    private var isSeeking = false
    private var cachedDuration: Double = 0
    private var cachedPosition: Double = 0

    private var isRendererLoading: Bool = false
    private var isClosing = false
    private var isRunning = false  // Track if renderer has been started
    private var pipController: PiPController?
    private var initialURL: URL?
    private var initialPreset: PlayerPreset?
    private var initialHeaders: [String: String]?
    private var initialSubtitles: [String]?
    private var initialSubtitleNames: [String]?
    private var userSelectedAudioTrack = false
    private var userSelectedSubtitleTrack = false
    private var vlcProxyFallbackTried = false
    
    // Debounce timers for menu updates to avoid excessive rebuilds
    private var audioMenuDebounceTimer: Timer?
    private var subtitleMenuDebounceTimer: Timer?
    private var vlcSubtitleOverlayBottomConstraint: NSLayoutConstraint?
    
    // MARK: - Renderer Wrapper Methods
    // These methods abstract away differences between MPVSoftwareRenderer and VLCRenderer
    
    private func rendererLoad(url: URL, preset: PlayerPreset, headers: [String: String]?) {
        if let vlc = vlcRenderer {
            vlc.load(url: url, with: preset, headers: headers)
        } else if let mpv = mpvRenderer {
            mpv.load(url: url, with: preset, headers: headers)
        }
    }
    
    private func rendererReloadCurrentItem() {
        if let vlc = vlcRenderer {
            vlc.reloadCurrentItem()
        } else if let mpv = mpvRenderer {
            mpv.reloadCurrentItem()
        }
    }
    
    private func rendererApplyPreset(_ preset: PlayerPreset) {
        if let vlc = vlcRenderer {
            vlc.applyPreset(preset)
        } else if let mpv = mpvRenderer {
            mpv.applyPreset(preset)
        }
    }
    
    private func rendererStart() throws {
        if let vlc = vlcRenderer {
            try vlc.start()
        } else if let mpv = mpvRenderer {
            try mpv.start()
        }
        isRunning = true
    }
    
    private func rendererStop() {
        if let vlc = vlcRenderer {
            vlc.stop()
        } else if let mpv = mpvRenderer {
            mpv.stop()
        }
        isRunning = false
    }
    
    private func rendererPlay() {
        if let vlc = vlcRenderer {
            vlc.play()
        } else if let mpv = mpvRenderer {
            mpv.play()
        }
    }
    
    private func rendererPausePlayback() {
        if let vlc = vlcRenderer {
            vlc.pausePlayback()
        } else if let mpv = mpvRenderer {
            mpv.pausePlayback()
        }
    }
    
    private func rendererTogglePause() {
        if let vlc = vlcRenderer {
            vlc.togglePause()
        } else if let mpv = mpvRenderer {
            mpv.togglePause()
        }
    }

    private func rendererSeek(to seconds: Double) {
        if let vlc = vlcRenderer {
            vlc.seek(to: seconds)
        } else if let mpv = mpvRenderer {
            mpv.seek(to: seconds)
        }
    }
    
    private func rendererSeek(by seconds: Double) {
        if let vlc = vlcRenderer {
            vlc.seek(by: seconds)
        } else if let mpv = mpvRenderer {
            mpv.seek(by: seconds)
        }
    }
    
    private func rendererSetSpeed(_ speed: Double) {
        if let vlc = vlcRenderer {
            vlc.setSpeed(speed)
        } else if let mpv = mpvRenderer {
            mpv.setSpeed(speed)
        }
    }
    
    private func rendererGetSpeed() -> Double {
        if let vlc = vlcRenderer {
            return vlc.getSpeed()
        } else if let mpv = mpvRenderer {
            return mpv.getSpeed()
        }
        return 1.0
    }
    
    private func rendererGetAudioTracksDetailed() -> [(Int, String, String)] {
        if let vlc = vlcRenderer {
            return vlc.getAudioTracksDetailed()
        } else if let mpv = mpvRenderer {
            return mpv.getAudioTracksDetailed()
        }
        return []
    }
    
    private func rendererGetAudioTracks() -> [(Int, String)] {
        if let vlc = vlcRenderer {
            return vlc.getAudioTracks()
        } else if let mpv = mpvRenderer {
            return mpv.getAudioTracks()
        }
        return []
    }
    
    private func rendererSetAudioTrack(id: Int) {
        if let vlc = vlcRenderer {
            vlc.setAudioTrack(id: id)
        } else if let mpv = mpvRenderer {
            mpv.setAudioTrack(id: id)
        }
    }
    
    private func rendererGetCurrentAudioTrackId() -> Int {
        if let vlc = vlcRenderer {
            return vlc.getCurrentAudioTrackId()
        } else if let mpv = mpvRenderer {
            return mpv.getCurrentAudioTrackId()
        }
        return -1
    }
    
    private func rendererGetSubtitleTracks() -> [(Int, String)] {
        if let vlc = vlcRenderer {
            return vlc.getSubtitleTracks()
        } else if let mpv = mpvRenderer {
            return mpv.getSubtitleTracks()
        }
        return []
    }
    
    private func rendererSetSubtitleTrack(id: Int) {
        if let vlc = vlcRenderer {
            vlc.setSubtitleTrack(id: id)
        } else if let mpv = mpvRenderer {
            mpv.setSubtitleTrack(id: id)
        }
    }
    
    private func rendererGetCurrentSubtitleTrackId() -> Int {
        if let vlc = vlcRenderer {
            return vlc.getCurrentSubtitleTrackId()
        } else if let mpv = mpvRenderer {
            return mpv.getCurrentSubtitleTrackId()
        }
        return -1
    }
    
    private func rendererDisableSubtitles() {
        if let vlc = vlcRenderer {
            vlc.disableSubtitles()
        } else if let mpv = mpvRenderer {
            mpv.disableSubtitles()
        }
    }
    
    private func rendererRefreshSubtitleOverlay() {
        if let vlc = vlcRenderer {
            vlc.refreshSubtitleOverlay()
        }
    }
    
    private func rendererLoadExternalSubtitles(urls: [String]) {
        if let vlc = vlcRenderer {
            vlc.loadExternalSubtitles(urls: urls)
        }
    }

    private var vlcSubtitleOverlayBottomConstant: CGFloat {
        if let value = UserDefaults.standard.object(forKey: "vlcSubtitleOverlayBottomConstant") as? Double {
            return CGFloat(value)
        }
        return -6.0
    }

    private func applyVLCSubtitleOverlayPositionSetting() {
        guard isVLCPlayer else { return }
        let constant = vlcSubtitleOverlayBottomConstant
        vlcSubtitleOverlayBottomConstraint?.constant = constant
        Logger.shared.log("[PlayerVC.Subtitles] applied VLC overlay bottom constant=\(String(format: "%.1f", constant))", type: "Player")
    }

    private func rendererApplySubtitleStyle(_ style: SubtitleStyle) {
        if let vlc = vlcRenderer {
            vlc.applySubtitleStyle(style)
        }
    }
    
    private func rendererIsPausedState() -> Bool {
        if let vlc = vlcRenderer {
            return vlc.isPausedState
        } else if let mpv = mpvRenderer {
            return mpv.isPausedState
        }
        return true
    }
    
    private var subtitleURLs: [String] = []
    private var subtitleNames: [String] = []
    private var currentSubtitleIndex: Int = 0
    private var subtitleEntries: [SubtitleEntry] = []
    private var vlcExternalSubtitlesLoadedNatively = false
    private var lastKnownVLCCustomSubtitleOverlayEnabled: Bool?

    private enum VLCSubtitleSelection {
        case none
        case embedded(trackId: Int)
        case external(index: Int)
    }

    private var vlcSubtitleSelection: VLCSubtitleSelection = .none

    private var isVLCCustomSubtitleOverlayEnabled: Bool {
        return isVLCPlayer && Settings.shared.enableVLCSubtitleEditMenu
    }

    private func updatePiPButtonVisibility() {
        let pipSupported = PiPController.isPictureInPictureSupported
        // VLC PiP is disabled until VideoLAN adds native support
        pipButton.isHidden = !pipSupported || isVLCPlayer
    }

    private var shouldShowTopErrorBanner: Bool {
        return !isVLCPlayer
    }

    private func logMPV(_ message: String) {
        Logger.shared.log("[MPV \(playerLogId)] " + message, type: "MPV")
    }
    
    class SubtitleModel: ObservableObject {
        @Published var currentAttributedText: NSAttributedString = NSAttributedString()
        
        private var isLoading: Bool = true
        
        @Published var isVisible: Bool = false {
            didSet {
                if !isLoading { saveSubtitleSettings() }
            }
        }
        @Published var foregroundColor: UIColor = .white {
            didSet {
                if !isLoading { saveSubtitleSettings() }
            }
        }
        @Published var strokeColor: UIColor = .black {
            didSet {
                if !isLoading { saveSubtitleSettings() }
            }
        }
        @Published var strokeWidth: CGFloat = 1.0 {
            didSet {
                if !isLoading { saveSubtitleSettings() }
            }
        }
        @Published var fontSize: CGFloat = 30.0 {
            didSet {
                if !isLoading { saveSubtitleSettings() }
            }
        }
        
        init() {
            loadSubtitleSettings()
            isLoading = false
        }
        
        private func saveSubtitleSettings() {
            let defaults = UserDefaults.standard
            defaults.set(isVisible, forKey: "subtitles_isVisible")
            defaults.set(strokeWidth, forKey: "subtitles_strokeWidth")
            defaults.set(fontSize, forKey: "subtitles_fontSize")
            
            if let foregroundData = try? NSKeyedArchiver.archivedData(withRootObject: foregroundColor, requiringSecureCoding: false) {
                defaults.set(foregroundData, forKey: "subtitles_foregroundColor")
            }
            if let strokeData = try? NSKeyedArchiver.archivedData(withRootObject: strokeColor, requiringSecureCoding: false) {
                defaults.set(strokeData, forKey: "subtitles_strokeColor")
            }
        }
        
        private func loadSubtitleSettings() {
            let defaults = UserDefaults.standard
            
            if defaults.object(forKey: "subtitles_isVisible") != nil {
                isVisible = defaults.bool(forKey: "subtitles_isVisible")
            }
            
            if defaults.object(forKey: "subtitles_strokeWidth") != nil {
                let width = CGFloat(defaults.double(forKey: "subtitles_strokeWidth"))
                strokeWidth = width > 0 ? width : 1.0
            }
            
            if defaults.object(forKey: "subtitles_fontSize") != nil {
                let size = CGFloat(defaults.double(forKey: "subtitles_fontSize"))
                fontSize = size > 0 ? size : 30.0
            }
            
            if let foregroundData = defaults.data(forKey: "subtitles_foregroundColor"),
               let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: foregroundData) {
                foregroundColor = color
            }
            if let strokeData = defaults.data(forKey: "subtitles_strokeColor"),
               let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: strokeData) {
                strokeColor = color
            }
        }
    }
    private var subtitleModel = SubtitleModel()

    private var isTwoFingerTapEnabled: Bool {
        if UserDefaults.standard.object(forKey: twoFingerSettingKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: twoFingerSettingKey)
    }
    private var isBrightnessControlEnabled: Bool {
        return false
    }
    
    private var originalSpeed: Double = 1.0
    private var holdGesture: UILongPressGestureRecognizer?
    
    private var controlsHideWorkItem: DispatchWorkItem?
    private var controlsVisible: Bool = true
    private var pendingSeekTime: Double?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        logMPV("viewDidLoad, initialURL=")
        
#if !os(tvOS)
        modalPresentationCapturesStatusBarAppearance = true
#endif
        setupLayout()
        
        setupActions()
        setupHoldGesture()
        if isVLCPlayer {
            setupDoubleTapSkipGestures()
        }
    #if !os(tvOS)
        if isVLCPlayer {
            setupBrightnessControls()
        }
    #endif

        if !isVLCPlayer {
            let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
            skipBackwardButton.setImage(UIImage(systemName: "gobackward.15", withConfiguration: cfg), for: .normal)
            skipForwardButton.setImage(UIImage(systemName: "goforward.15", withConfiguration: cfg), for: .normal)
            subtitleButton.showsMenuAsPrimaryAction = true
        } else {
            // Ensure subtitle control appears with other buttons immediately on VLC,
            // even before track discovery finishes.
            subtitleButton.showsMenuAsPrimaryAction = true
            updateSubtitleTracksMenu()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(handleLoggerNotification(_:)), name: NSNotification.Name("LoggerNotification"), object: nil)
        if isVLCPlayer {
            lastKnownVLCCustomSubtitleOverlayEnabled = isVLCCustomSubtitleOverlayEnabled
            NotificationCenter.default.addObserver(self, selector: #selector(handleUserDefaultsDidChange), name: UserDefaults.didChangeNotification, object: nil)
        }
        
        do {
            try rendererStart()
            logMPV("renderer.start succeeded")
        } catch {
            let rendererName = vlcRenderer != nil ? "VLC" : "MPV"
            Logger.shared.log("Failed to start \(rendererName) renderer: \(error)", type: "Error")
        }

        pipController = PiPController(sampleBufferDisplayLayer: displayLayer)
        pipController?.delegate = self
        updatePiPButtonVisibility()
        
        showControlsTemporarily()
        
        if let url = initialURL, let preset = initialPreset {
            logMPV("loading initial url=\(url.absoluteString) preset=\(preset.id.rawValue)")
            load(url: url, preset: preset, headers: initialHeaders)
        }
        
        updateProgressHostingController()
        if isVLCPlayer {
            updateSpeedMenu()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.bringSubviewToFront(errorBanner)
    }
    
#if !os(tvOS)
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if UserDefaults.standard.bool(forKey: "alwaysLandscape") {
            return .landscape
        } else {
            return .all
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setNeedsStatusBarAppearanceUpdate()
    }
#endif
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        displayLayer.frame = videoContainer.bounds
        
        if let gradientLayer = controlsOverlayView.layer.sublayers?.first(where: { $0.name == "gradientLayer" }) {
            gradientLayer.frame = controlsOverlayView.bounds
        }
        
        CATransaction.commit()
    }
    
    deinit {
        isClosing = true
        audioMenuDebounceTimer?.invalidate()
        subtitleMenuDebounceTimer?.invalidate()
        if let mpv = mpvRenderer {
            mpv.delegate = nil
        } else if let vlc = vlcRenderer {
            vlc.delegate = nil
        }
        logMPV("deinit; stopping renderer and restoring state")
        pipController?.delegate = nil
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        pipController?.invalidate()
        rendererStop()
        
        displayLayer.removeFromSuperlayer()
        
        NotificationCenter.default.removeObserver(self)
    }
    
    convenience init(url: URL, preset: PlayerPreset, headers: [String: String]? = nil, subtitles: [String]? = nil, subtitleNames: [String]? = nil, mediaInfo: MediaInfo? = nil) {
        self.init(nibName: nil, bundle: nil)
        self.initialURL = url
        self.initialPreset = preset
        self.initialHeaders = headers
        self.initialSubtitles = subtitles
        self.initialSubtitleNames = subtitleNames
        self.mediaInfo = mediaInfo
        Logger.shared.log("[PlayerViewController.init] URL=\(url.absoluteString) preset=\(preset.id.rawValue) headers=\(headers?.count ?? 0) subtitles=\(subtitles?.count ?? 0) mediaInfo=\(mediaInfo != nil)", type: "Stream")
    }
    
    func load(url: URL, preset: PlayerPreset, headers: [String: String]? = nil) {
        logMPV("load url=\(url.absoluteString) preset=\(preset.id.rawValue) headers=\(headers?.count ?? 0)")
        initialURL = url
        initialHeaders = headers
        updatePiPButtonVisibility()
        let mediaInfoLabel: String = {
            guard let info = mediaInfo else { return "nil" }
            switch info {
            case .movie(let id, let title, _, let isAnime):
                return "movie id=\(id) title=\(title) isAnime=\(isAnime)"
            case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, _, let isAnime):
                return "episode showId=\(showId) s=\(seasonNumber) e=\(episodeNumber) title=\(showTitle) isAnime=\(isAnime)"
            }
        }()
        Logger.shared.log("PlayerViewController.load: isAnimeHint=\(isAnimeHint ?? false) mediaInfo=\(mediaInfoLabel)", type: "Stream")
        
        // Ensure renderer is started before loading media
        if !isRunning {
            do {
                try rendererStart()
            } catch {
                return
            }
        }
        
        userSelectedAudioTrack = false
        userSelectedSubtitleTrack = false
        rendererLoad(url: url, preset: preset, headers: headers)
        if let info = mediaInfo {
            prepareSeekToLastPosition(for: info)
        }
        
        if let subs = initialSubtitles, !subs.isEmpty {
            loadSubtitles(subs, names: initialSubtitleNames)
        }
    }
    
    private func prepareSeekToLastPosition(for mediaInfo: MediaInfo) {
        let lastPlayedTime: Double
        
        switch mediaInfo {
        case .movie(let id, let title, _, _):
            lastPlayedTime = ProgressManager.shared.getMovieCurrentTime(movieId: id, title: title)
            
        case .episode(let showId, let seasonNumber, let episodeNumber, _, _, _):
            lastPlayedTime = ProgressManager.shared.getEpisodeCurrentTime(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        }
        
        if lastPlayedTime != 0 {
            let progress: Double
            switch mediaInfo {
            case .movie(let id, let title, _, _):
                progress = ProgressManager.shared.getMovieProgress(movieId: id, title: title)
            case .episode(let showId, let seasonNumber, let episodeNumber, _, _, _):
                progress = ProgressManager.shared.getEpisodeProgress(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
            }
            
            if progress < 0.95 {
                pendingSeekTime = lastPlayedTime
            }
        }
    }
    
    private func setupLayout() {
        view.addSubview(videoContainer)
        
        // Keep the sample-buffer layer attached for MPV playback and VLC PiP handoff
        displayLayer.frame = videoContainer.bounds
        // Keep full video visible; avoid cropping for downloaded media
        displayLayer.videoGravity = .resizeAspect
        displayLayer.isOpaque = (vlcRenderer == nil)
#if compiler(>=6.0)
        if #available(iOS 26.0, tvOS 26.0, *) {
            displayLayer.preferredDynamicRange = .automatic
        } else {
#if !os(tvOS)
            if #available(iOS 17.0, *) {
                displayLayer.wantsExtendedDynamicRangeContent = true
            }
#endif
        }
#elseif !os(tvOS)
        if #available(iOS 17.0, *) {
            displayLayer.wantsExtendedDynamicRangeContent = true
        }
#endif
        displayLayer.backgroundColor = (vlcRenderer == nil) ? UIColor.black.cgColor : UIColor.clear.cgColor
        videoContainer.layer.addSublayer(displayLayer)
        
        // Add VLC rendering view FIRST (before all UI elements) so it renders behind controls
        if let vlc = vlcRenderer {
            let vlcView = vlc.getRenderingView()
            videoContainer.addSubview(vlcView)
            vlcView.translatesAutoresizingMaskIntoConstraints = false
            // Ensure container remains interactive for gesture recognition
            videoContainer.isUserInteractionEnabled = true
            NSLayoutConstraint.activate([
                vlcView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
                vlcView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),
                vlcView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
                vlcView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor)
            ])
        }
        
        videoContainer.addSubview(dimmingView)
        videoContainer.addSubview(controlsOverlayView)
        videoContainer.addSubview(loadingIndicator)
        view.addSubview(errorBanner)
        videoContainer.addSubview(centerPlayPauseButton)
        videoContainer.addSubview(progressContainer)
        videoContainer.addSubview(closeButton)
        videoContainer.addSubview(pipButton)
        videoContainer.addSubview(skipBackwardButton)
        videoContainer.addSubview(skipForwardButton)
        videoContainer.addSubview(speedIndicatorLabel)
        videoContainer.addSubview(vlcSubtitleOverlayLabel)
        videoContainer.addSubview(subtitleButton)
        if isVLCPlayer {
            videoContainer.addSubview(speedButton)
            videoContainer.addSubview(audioButton)
        }
    #if !os(tvOS)
        videoContainer.addSubview(brightnessContainer)
        brightnessContainer.contentView.addSubview(brightnessSlider)
        brightnessContainer.contentView.addSubview(brightnessIcon)
        if isVLCPlayer {
            videoContainer.addSubview(skipButton)
            videoContainer.addSubview(nextEpisodeButton)
            videoContainer.addSubview(skip85sButton)
        }
    #endif

        NSLayoutConstraint.activate([
            videoContainer.topAnchor.constraint(equalTo: view.topAnchor),
            videoContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            progressContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            progressContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            progressContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            progressContainer.heightAnchor.constraint(equalToConstant: 44),

            dimmingView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),
            
            controlsOverlayView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
            controlsOverlayView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
            controlsOverlayView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
            controlsOverlayView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),
        ])
        
        NSLayoutConstraint.activate([
            errorBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            errorBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorBanner.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.92),
            errorBanner.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            
            centerPlayPauseButton.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            centerPlayPauseButton.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor),
            centerPlayPauseButton.widthAnchor.constraint(equalToConstant: 70),
            centerPlayPauseButton.heightAnchor.constraint(equalToConstant: 70),
            
            loadingIndicator.centerXAnchor.constraint(equalTo: centerPlayPauseButton.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerPlayPauseButton.centerYAnchor),
            
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor, constant: 4),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
            
            pipButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            pipButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 16),
            pipButton.widthAnchor.constraint(equalToConstant: 36),
            pipButton.heightAnchor.constraint(equalToConstant: 36),
            
            skipBackwardButton.centerYAnchor.constraint(equalTo: centerPlayPauseButton.centerYAnchor),
            skipBackwardButton.trailingAnchor.constraint(equalTo: centerPlayPauseButton.leadingAnchor, constant: -48),
            skipBackwardButton.widthAnchor.constraint(equalToConstant: 50),
            skipBackwardButton.heightAnchor.constraint(equalToConstant: 50),
            
            skipForwardButton.centerYAnchor.constraint(equalTo: centerPlayPauseButton.centerYAnchor),
            skipForwardButton.leadingAnchor.constraint(equalTo: centerPlayPauseButton.trailingAnchor, constant: 48),
            skipForwardButton.widthAnchor.constraint(equalToConstant: 50),
            skipForwardButton.heightAnchor.constraint(equalToConstant: 50),
            
            speedIndicatorLabel.topAnchor.constraint(equalTo: videoContainer.safeAreaLayoutGuide.topAnchor, constant: 20),
            speedIndicatorLabel.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            speedIndicatorLabel.widthAnchor.constraint(equalToConstant: 100),
            speedIndicatorLabel.heightAnchor.constraint(equalToConstant: 40),

            vlcSubtitleOverlayLabel.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor, constant: 12),
            vlcSubtitleOverlayLabel.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor, constant: -12),
            
            subtitleButton.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor, constant: 0),
            subtitleButton.bottomAnchor.constraint(equalTo: progressContainer.topAnchor, constant: -8),
            subtitleButton.widthAnchor.constraint(equalToConstant: 32),
            subtitleButton.heightAnchor.constraint(equalToConstant: 32)
        ])

        vlcSubtitleOverlayBottomConstraint = vlcSubtitleOverlayLabel.bottomAnchor.constraint(equalTo: progressContainer.topAnchor, constant: vlcSubtitleOverlayBottomConstant)
        vlcSubtitleOverlayBottomConstraint?.isActive = true
        if isVLCPlayer {
            NSLayoutConstraint.activate([
                speedButton.trailingAnchor.constraint(equalTo: subtitleButton.leadingAnchor, constant: -8),
                speedButton.centerYAnchor.constraint(equalTo: subtitleButton.centerYAnchor),
                speedButton.widthAnchor.constraint(equalToConstant: 32),
                speedButton.heightAnchor.constraint(equalToConstant: 32),

                audioButton.trailingAnchor.constraint(equalTo: speedButton.leadingAnchor, constant: -8),
                audioButton.centerYAnchor.constraint(equalTo: subtitleButton.centerYAnchor),
                audioButton.widthAnchor.constraint(equalToConstant: 32),
                audioButton.heightAnchor.constraint(equalToConstant: 32)
            ])
        }
#if !os(tvOS)
        NSLayoutConstraint.activate([
            brightnessContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            brightnessContainer.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor),
            brightnessContainer.widthAnchor.constraint(equalToConstant: 52),
            brightnessContainer.heightAnchor.constraint(equalToConstant: 220),

            brightnessSlider.centerXAnchor.constraint(equalTo: brightnessContainer.contentView.centerXAnchor),
            brightnessSlider.centerYAnchor.constraint(equalTo: brightnessContainer.contentView.centerYAnchor),
            brightnessSlider.widthAnchor.constraint(equalTo: brightnessContainer.contentView.heightAnchor, multiplier: 0.82),
            brightnessSlider.heightAnchor.constraint(equalToConstant: 34),

            brightnessIcon.centerXAnchor.constraint(equalTo: brightnessContainer.contentView.centerXAnchor),
            brightnessIcon.topAnchor.constraint(equalTo: brightnessContainer.contentView.topAnchor, constant: 8),
            brightnessIcon.heightAnchor.constraint(equalToConstant: 20),
            brightnessIcon.widthAnchor.constraint(equalToConstant: 20)
        ])
        if isVLCPlayer {
            NSLayoutConstraint.activate([
                skipButton.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),
                skipButton.bottomAnchor.constraint(equalTo: subtitleButton.topAnchor, constant: -12),

                nextEpisodeButton.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),
                nextEpisodeButton.bottomAnchor.constraint(equalTo: skipButton.topAnchor, constant: -10),

                skip85sButton.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor),
                skip85sButton.bottomAnchor.constraint(equalTo: progressContainer.topAnchor, constant: -12),
            ])
        }
#endif
        
        // CRITICAL: After all UI elements are added, ensure VLC view is at the very back
        if let vlc = vlcRenderer {
            let vlcView = vlc.getRenderingView()
            videoContainer.sendSubviewToBack(vlcView)
            // Double-ensure VLC view doesn't steal touches
            vlcView.isUserInteractionEnabled = false
            #if !os(tvOS)
            vlcView.isExclusiveTouch = false
            #endif
            
            // Add transparent tap overlay on top to guarantee tap detection
            videoContainer.addSubview(tapOverlayView)
            NSLayoutConstraint.activate([
                tapOverlayView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
                tapOverlayView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
                tapOverlayView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
                tapOverlayView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor)
            ])
        }
    }
    
    private func setupActions() {
        centerPlayPauseButton.addTarget(self, action: #selector(centerPlayPauseTapped), for: .touchUpInside)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        pipButton.addTarget(self, action: #selector(pipTouchDown), for: .touchDown)
        pipButton.addTarget(self, action: #selector(pipTapped), for: .touchUpInside)
        skipBackwardButton.addTarget(self, action: #selector(skipBackwardTapped), for: .touchUpInside)
        skipForwardButton.addTarget(self, action: #selector(skipForwardTapped), for: .touchUpInside)
#if !os(tvOS)
        if isVLCPlayer {
            skipButton.addTarget(self, action: #selector(skipButtonTapped), for: .touchUpInside)
            nextEpisodeButton.addTarget(self, action: #selector(nextEpisodeButtonTapped), for: .touchUpInside)
            skip85sButton.addTarget(self, action: #selector(skip85sButtonTapped), for: .touchUpInside)
        }
#endif
        if isVLCPlayer {
            subtitleButton.addTarget(self, action: #selector(subtitleButtonTapped), for: .touchUpInside)
        }
        
        // Ensure buttons work with VLC
        if vlcRenderer != nil {
            [centerPlayPauseButton, closeButton, pipButton, skipBackwardButton,
             skipForwardButton, subtitleButton, speedButton, audioButton].forEach {
                $0.isUserInteractionEnabled = true
            }
        }
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(containerTapped))
        if vlcRenderer != nil {
            tap.delegate = self
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tapOverlayView.addGestureRecognizer(tap)
        } else {
            videoContainer.addGestureRecognizer(tap)
        }
        containerTapGesture = tap
    }

    @objc private func pipTouchDown() {

    }
    
    private func setupHoldGesture() {
        holdGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldGesture(_:)))
        holdGesture?.minimumPressDuration = 0.5
        if let holdGesture = holdGesture {
            videoContainer.addGestureRecognizer(holdGesture)
        }
    }
    
    private func setupDoubleTapSkipGestures() {
        let leftDoubleTap = UITapGestureRecognizer(target: self, action: #selector(leftSideDoubleTapped))
        leftDoubleTap.numberOfTapsRequired = 2
        leftDoubleTap.delegate = self
        leftDoubleTapGesture = leftDoubleTap
        videoContainer.addGestureRecognizer(leftDoubleTap)
        
        let rightDoubleTap = UITapGestureRecognizer(target: self, action: #selector(rightSideDoubleTapped))
        rightDoubleTap.numberOfTapsRequired = 2
        rightDoubleTap.delegate = self
        rightDoubleTapGesture = rightDoubleTap
        videoContainer.addGestureRecognizer(rightDoubleTap)
        
        if let tap = containerTapGesture {
            tap.require(toFail: leftDoubleTap)
            tap.require(toFail: rightDoubleTap)
        }
        
        #if !os(tvOS)
        if isTwoFingerTapEnabled {
            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped))
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.delegate = self
            videoContainer.addGestureRecognizer(twoFingerTap)
        }
        #endif
    }

    @objc private func leftSideDoubleTapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: videoContainer)
        let isLeftSide = location.x < videoContainer.bounds.width / 2
        guard isLeftSide else { return }
        rendererSeek(by: -10)
        animateButtonTap(skipBackwardButton)
    }

    @objc private func rightSideDoubleTapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: videoContainer)
        let isRightSide = location.x >= videoContainer.bounds.width / 2
        guard isRightSide else { return }
        rendererSeek(by: 10)
        animateButtonTap(skipForwardButton)
    }

    @objc private func twoFingerTapped(_ gesture: UITapGestureRecognizer) {
        // Two-finger tap: toggle play/pause without showing UI
        if rendererIsPausedState() {
            rendererPlay()
            updatePlayPauseButton(isPaused: false, shouldShowControls: false)
        } else {
            rendererPausePlayback()
            updatePlayPauseButton(isPaused: true, shouldShowControls: false)
        }
    }

    private func setupBrightnessControls() {
#if !os(tvOS)
        brightnessSlider.addTarget(self, action: #selector(brightnessSliderChanged(_:)), for: .valueChanged)
        loadBrightnessLevel()
        updateBrightnessControlVisibility()
#endif
    }

#if !os(tvOS)
    private func loadBrightnessLevel() {
        if UserDefaults.standard.object(forKey: brightnessLevelKey) == nil {
            UserDefaults.standard.set(Float(UIScreen.main.brightness), forKey: brightnessLevelKey)
        }
        let stored = UserDefaults.standard.float(forKey: brightnessLevelKey)
        brightnessLevel = max(0.0, min(stored, 1.0))
        brightnessSlider.value = brightnessLevel
        applyBrightnessLevel(brightnessLevel)
    }

    @objc private func brightnessSliderChanged(_ sender: UISlider) {
        applyBrightnessLevel(sender.value)
        showControlsTemporarily()
    }

    private func applyBrightnessLevel(_ value: Float) {
        if isClosing { return }
        let clamped = max(0.0, min(value, 1.0))
        brightnessLevel = clamped
        UserDefaults.standard.set(clamped, forKey: brightnessLevelKey)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isClosing { return }
            self.dimmingView.alpha = 0.0
        }
    }

    private func updateBrightnessControlVisibility() {
        if isClosing { return }
        brightnessContainer.isHidden = true
        brightnessContainer.alpha = 0.0
    }

#else
    // tvOS stub to satisfy shared call sites when brightness UI is unavailable
    private func updateBrightnessControlVisibility() { }
#endif

    @objc private func handleHoldGesture(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginHoldSpeed()
        case .ended, .cancelled:
            endHoldSpeed()
        default:
            break
        }
    }
    
    private func beginHoldSpeed() {
        originalSpeed = rendererGetSpeed()
        let holdSpeed = UserDefaults.standard.float(forKey: "holdSpeedPlayer")
        let targetSpeed = holdSpeed > 0 ? Double(holdSpeed) : 2.0
        rendererSetSpeed(targetSpeed)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.speedIndicatorLabel.text = String(format: "%.1fx", targetSpeed)
            UIView.animate(withDuration: 0.2) {
                self.speedIndicatorLabel.alpha = 1.0
            }
        }
    }
    
    private func endHoldSpeed() {
        rendererSetSpeed(originalSpeed)
        
        DispatchQueue.main.async { [weak self] in
            UIView.animate(withDuration: 0.2) {
                self?.speedIndicatorLabel.alpha = 0.0
            }
        }
    }
    
    @objc private func playPauseTapped() {
        if rendererIsPausedState() {
            rendererPlay()
            updatePlayPauseButton(isPaused: false)
        } else {
            rendererPausePlayback()
            updatePlayPauseButton(isPaused: true)
        }
    }
    
    @objc private func centerPlayPauseTapped() {
        playPauseTapped()
    }
    
    @objc private func skipBackwardTapped() {
        rendererSeek(by: isVLCPlayer ? -10 : -15)
        animateButtonTap(skipBackwardButton)
        showControlsTemporarily()
    }
    
    @objc private func skipForwardTapped() {
        rendererSeek(by: isVLCPlayer ? 10 : 15)
        animateButtonTap(skipForwardButton)
        showControlsTemporarily()
    }
    private func updateSubtitleMenu() {
        var trackActions: [UIAction] = []
        
        let disableAction = UIAction(
            title: "Disable Subtitles",
            image: UIImage(systemName: "xmark"),
            state: subtitleModel.isVisible ? .off : .on
        ) { [weak self] _ in
            self?.subtitleModel.isVisible = false
            self?.updateSubtitleButtonAppearance()
            self?.updateSubtitleMenu()
        }
        trackActions.append(disableAction)
        
        for (index, _) in subtitleURLs.enumerated() {
            let isSelected = subtitleModel.isVisible && currentSubtitleIndex == index
            let title = index < subtitleNames.count ? subtitleNames[index] : "Subtitle \(index + 1)"
            let action = UIAction(
                title: title,
                image: UIImage(systemName: "captions.bubble"),
                state: isSelected ? .on : .off
            ) { [weak self] _ in
                self?.currentSubtitleIndex = index
                self?.subtitleModel.isVisible = true
                self?.loadCurrentSubtitle()
                self?.updateSubtitleButtonAppearance()
                self?.updateSubtitleMenu()
            }
            trackActions.append(action)
        }
        
        let trackMenu = UIMenu(title: "Select Track", image: UIImage(systemName: "list.bullet"), children: trackActions)
        
        let appearanceMenu = createAppearanceMenu()
        
        let mainMenu = UIMenu(title: "Subtitles", children: [trackMenu, appearanceMenu])
        subtitleButton.menu = mainMenu
    }
    
    private func createAppearanceMenu() -> UIMenu {
        let foregroundColors: [(String, UIColor)] = [
            ("White", .white),
            ("Yellow", .yellow),
            ("Cyan", .cyan),
            ("Green", .green),
            ("Magenta", .magenta)
        ]
        
        let foregroundColorActions = foregroundColors.map { (name, color) in
            UIAction(
                title: name,
                state: subtitleModel.foregroundColor == color ? .on : .off
            ) { [weak self] _ in
                self?.subtitleModel.foregroundColor = color
                self?.updateCurrentSubtitleAppearance()
                self?.refreshActiveSubtitleMenu()
            }
        }
        
        let foregroundColorMenu = UIMenu(title: "Text Color", image: UIImage(systemName: "paintpalette"), children: foregroundColorActions)
        
        let strokeColors: [(String, UIColor)] = [
            ("Black", .black),
            ("Dark Gray", .darkGray),
            ("White", .white),
            ("None", .clear)
        ]
        
        let strokeColorActions = strokeColors.map { (name, color) in
            UIAction(
                title: name,
                state: subtitleModel.strokeColor == color ? .on : .off
            ) { [weak self] _ in
                self?.subtitleModel.strokeColor = color
                self?.updateCurrentSubtitleAppearance()
                self?.refreshActiveSubtitleMenu()
            }
        }
        
        let strokeColorMenu = UIMenu(title: "Stroke Color", image: UIImage(systemName: "pencil.tip"), children: strokeColorActions)
        
        let strokeWidths: [(String, CGFloat)] = [
            ("None", 0.0),
            ("Thin", 0.5),
            ("Normal", 1.0),
            ("Medium", 1.5),
            ("Thick", 2.0)
        ]
        
        let strokeWidthActions = strokeWidths.map { (name, width) in
            UIAction(
                title: name,
                state: subtitleModel.strokeWidth == width ? .on : .off
            ) { [weak self] _ in
                self?.subtitleModel.strokeWidth = width
                self?.updateCurrentSubtitleAppearance()
                self?.refreshActiveSubtitleMenu()
            }
        }
        
        let strokeWidthMenu = UIMenu(title: "Stroke Width", image: UIImage(systemName: "lineweight"), children: strokeWidthActions)
        
        let fontSizes: [(String, CGFloat)] = [
            ("Very Small", 20.0),
            ("Small", 24.0),
            ("Medium", 30.0),
            ("Large", 34.0),
            ("Extra Large", 38.0),
            ("Huge", 42.0),
            ("Extra Huge", 46.0)
        ]
        
        let fontSizeActions = fontSizes.map { (name, size) in
            UIAction(
                title: name,
                state: subtitleModel.fontSize == size ? .on : .off
            ) { [weak self] _ in
                self?.subtitleModel.fontSize = size
                self?.updateCurrentSubtitleAppearance()
                self?.refreshActiveSubtitleMenu()
            }
        }
        
        let fontSizeMenu = UIMenu(title: "Font Size", image: UIImage(systemName: "textformat.size"), children: fontSizeActions)
        
        return UIMenu(title: "Appearance", image: UIImage(systemName: "paintbrush"), children: [
            foregroundColorMenu,
            strokeColorMenu,
            strokeWidthMenu,
            fontSizeMenu
        ])
    }
    
    private func updateCurrentSubtitleAppearance() {
        rendererApplySubtitleStyle(SubtitleStyle(
            foregroundColor: subtitleModel.foregroundColor,
            strokeColor: subtitleModel.strokeColor,
            strokeWidth: subtitleModel.strokeWidth,
            fontSize: subtitleModel.fontSize,
            isVisible: subtitleModel.isVisible
        ))

        if isVLCCustomSubtitleOverlayEnabled {
            updateVLCSubtitleOverlay(for: cachedPosition)
        }

        if subtitleModel.isVisible && currentSubtitleIndex < subtitleURLs.count {
            loadCurrentSubtitle()
            return
        }
        rendererRefreshSubtitleOverlay()
    }

    private func updateVLCSubtitleOverlay(for time: Double) {
        guard isVLCCustomSubtitleOverlayEnabled,
              subtitleModel.isVisible,
              !subtitleEntries.isEmpty,
              time.isFinite,
              let entry = subtitleEntries.first(where: { $0.startTime <= time && time <= $0.endTime }) else {
            vlcSubtitleOverlayLabel.attributedText = nil
            vlcSubtitleOverlayLabel.alpha = 0.0
            vlcSubtitleOverlayLabel.isHidden = true
            return
        }

        let styled = NSMutableAttributedString(attributedString: entry.attributedText)
        let fullRange = NSRange(location: 0, length: styled.length)

        styled.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let baseFont = (value as? UIFont) ?? UIFont.boldSystemFont(ofSize: subtitleModel.fontSize)
            let descriptor = baseFont.fontDescriptor
            let resized = UIFont(descriptor: descriptor, size: subtitleModel.fontSize)
            styled.addAttribute(.font, value: resized, range: range)
            styled.addAttribute(.foregroundColor, value: subtitleModel.foregroundColor, range: range)
            styled.addAttribute(.strokeColor, value: subtitleModel.strokeColor, range: range)
            styled.addAttribute(.strokeWidth, value: -abs(subtitleModel.strokeWidth * 2.0), range: range)
        }

        vlcSubtitleOverlayLabel.attributedText = styled
        vlcSubtitleOverlayLabel.isHidden = false
        vlcSubtitleOverlayLabel.alpha = 1.0
    }

    private func refreshActiveSubtitleMenu() {
        if isVLCPlayer {
            updateSubtitleTracksMenu()
        } else {
            updateSubtitleMenu()
        }
    }
    
    private func updateSubtitleButtonAppearance() {
        let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let imageName = subtitleModel.isVisible ? "captions.bubble.fill" : "captions.bubble"
        let img = UIImage(systemName: imageName, withConfiguration: cfg)
        subtitleButton.setImage(img, for: .normal)
    }
    
    private func updateSpeedMenu() {
        let currentSpeed = rendererGetSpeed()
        let speeds: [(String, Double)] = [
            ("0.25x", 0.25),
            ("0.5x", 0.5),
            ("0.75x", 0.75),
            ("1.0x", 1.0),
            ("1.25x", 1.25),
            ("1.5x", 1.5),
            ("1.75x", 1.75),
            ("2.0x", 2.0)
        ]
        
        let speedActions = speeds.map { (name, speed) in
            UIAction(
                title: name,
                state: abs(currentSpeed - speed) < 0.01 ? .on : .off
            ) { [weak self] _ in
                self?.rendererSetSpeed(speed)
                self?.speedIndicatorLabel.text = String(format: "%.2fx", speed)
                DispatchQueue.main.async {
                    UIView.animate(withDuration: 0.2) {
                        self?.speedIndicatorLabel.alpha = 1.0
                    } completion: { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            UIView.animate(withDuration: 0.2) {
                                self?.speedIndicatorLabel.alpha = 0.0
                            }
                        }
                    }
                }
                self?.updateSpeedMenu()
            }
        }
        
        let speedMenu = UIMenu(title: "Playback Speed", image: UIImage(systemName: "hare.fill"), children: speedActions)
        speedButton.menu = speedMenu
    }
    
    private func updateAudioTracksMenuWhenReady() {
        guard isVLCPlayer else { return }
        // Stop retrying if user manually selected a track
        if userSelectedAudioTrack {
            updateAudioTracksMenu()
            return
        }
        
        let detailedTracks = rendererGetAudioTracksDetailed()
        
        // If tracks are populated, proceed with auto-selection
        if !detailedTracks.isEmpty {
            updateAudioTracksMenu()
            return
        }
        
        // Tracks not ready yet - retry shortly (works for both VLC and MPV)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.updateAudioTracksMenuWhenReady()
        }
    }

    private func updateSubtitleTracksMenuWhenReady(attempt: Int = 0) {
        guard isVLCPlayer else { return }
        if userSelectedSubtitleTrack {
            updateSubtitleTracksMenu()
            return
        }

        if !subtitleURLs.isEmpty && vlcRenderer == nil {
            updateSubtitleTracksMenu()
            return
        }

        let tracks = rendererGetSubtitleTracks()
        if !tracks.isEmpty || attempt >= 20 {
            updateSubtitleTracksMenu()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.updateSubtitleTracksMenuWhenReady(attempt: attempt + 1)
        }
    }
    
    private func updateAudioTracksMenu() {
        guard isVLCPlayer else {
            audioButton.isHidden = true
            return
        }
        let detailedTracks = rendererGetAudioTracksDetailed()
        let tracks = detailedTracks.map { ($0.0, $0.1) }
        var trackActions: [UIAction] = []
        
        // Always show the audio button so the user can view the menu even when empty
        audioButton.isHidden = false

        Logger.shared.log("PlayerViewController: audio tracks count=\(tracks.count) isAnime=\(isAnimeContent()) userSelected=\(userSelectedAudioTrack) renderer=\(vlcRenderer != nil ? "VLC" : "MPV")", type: "Player")
        
        if tracks.isEmpty {
            let noTracksAction = UIAction(title: "No audio tracks available", state: .off) { _ in }
            let audioMenu = UIMenu(title: "Audio Tracks", image: UIImage(systemName: "speaker.wave.2"), children: [noTracksAction])
            audioButton.menu = audioMenu
            return
        }

        let currentAudioTrackId = rendererGetCurrentAudioTrackId()
        trackActions = tracks.map { (id, name) in
            UIAction(
                title: name,
                state: id == currentAudioTrackId ? .on : .off
            ) { [weak self] _ in
                self?.userSelectedAudioTrack = true
                self?.rendererSetAudioTrack(id: id)
                // Debounce menu update to avoid lag - only update after 0.3s of no selection changes
                self?.audioMenuDebounceTimer?.invalidate()
                self?.audioMenuDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                    DispatchQueue.main.async { [weak self] in
                        self?.updateAudioTracksMenu()
                    }
                }
            }
        }

        // Auto-select preferred anime audio language when applicable and user hasn't picked a track yet
        if isAnimeContent() && !userSelectedAudioTrack {
            let preferredLang = Settings.shared.preferredAnimeAudioLanguage.lowercased()
            let tokens = languageTokens(for: preferredLang)

            if !preferredLang.isEmpty {
                Logger.shared.log("PlayerViewController: Auto anime audio - preferredLang=\(preferredLang), tokens=\(tokens.joined(separator: ",")), detailedTracks=\(detailedTracks.count)", type: "Player")

                if let matching = detailedTracks.first(where: {
                    let langCode = $0.2.lowercased()
                    let title = $0.1.lowercased()
                    return tokens.contains(where: { token in
                        langCode.contains(token) || title.contains(token)
                    })
                }) {
                    Logger.shared.log("PlayerViewController: Auto-selected anime audio track: \(matching.1) (ID: \(matching.0))", type: "Player")
                    userSelectedAudioTrack = true
                    rendererSetAudioTrack(id: matching.0)
                } else {
                    Logger.shared.log("PlayerViewController: No matching anime audio track found for lang=\(preferredLang)", type: "Player")
                }
            } else {
                Logger.shared.log("PlayerViewController: Auto anime audio skipped (preferred language empty)", type: "Player")
            }
        } else if !isAnimeContent() {
            Logger.shared.log("PlayerViewController: Auto anime audio skipped (isAnime=false)", type: "Player")
        } else if userSelectedAudioTrack {
            Logger.shared.log("PlayerViewController: Auto anime audio skipped (user already selected)", type: "Player")
        }
        
        let audioMenu = UIMenu(title: "Audio Tracks", image: UIImage(systemName: "speaker.wave.2"), children: trackActions)
        audioButton.menu = audioMenu
    }

    private func isAnimeContent() -> Bool {
        if let hint = isAnimeHint, hint == true { return true }
        guard let info = mediaInfo else { return false }
        switch info {
        case .movie(_, _, _, let isAnime):
            return isAnime
        case .episode(let showId, _, _, _, _, let isAnime):
            if isAnime { return true }
            return trackerManager.cachedAniListId(for: showId) != nil
        }
    }

    // MARK: - Skip Data Integration (AniSkip + TheIntroDB)

    private func fetchSkipData() {
        guard !skipDataFetched else { return }
        guard let info = mediaInfo else { return }

        // Extract TMDB ID, season, episode from mediaInfo
        let tmdbId: Int
        let seasonNumber: Int?
        let episodeNumber: Int?
        let showTitle: String?
        let isAnime: Bool

        switch info {
        case .movie(let id, _, _, let anime):
            tmdbId = id
            seasonNumber = nil
            episodeNumber = nil
            showTitle = nil
            isAnime = anime || isAnimeContent()
        case .episode(let showId, let s, let e, let title, _, let anime):
            tmdbId = showId
            seasonNumber = s
            episodeNumber = e
            showTitle = title
            isAnime = anime || isAnimeContent()
        }

        Logger.shared.log("SkipData: fetchSkipData called — tmdbId=\(tmdbId) s=\(seasonNumber ?? -1) ep=\(episodeNumber ?? -1) isAnime=\(isAnime)", type: "Skip")

        skipDataFetched = true

        Task { [weak self] in
            guard let self else { return }

            // Wait for renderer to report a valid duration
            var durationAtFetch: Double = 0
            for attempt in 1...20 {
                durationAtFetch = await MainActor.run { self.cachedDuration }
                if durationAtFetch > 0 { break }
                if attempt <= 2 {
                    Logger.shared.log("SkipData: Waiting for duration (attempt \(attempt)/20)…", type: "Skip")
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            var segments: [SkipSegment] = []
            let skip85sEnabled = UserDefaults.standard.bool(forKey: "skip85sEnabled")
            let skip85sAlwaysVisible = UserDefaults.standard.bool(forKey: "skip85sAlwaysVisible")

            let aniSkipEnabled = UserDefaults.standard.object(forKey: "aniSkipEnabled") as? Bool ?? true
            let introDBEnabled = UserDefaults.standard.object(forKey: "introDBEnabled") as? Bool ?? true

            // ── Anime content: try AniSkip first (better anime coverage) ──
            if aniSkipEnabled, isAnime, let ep = episodeNumber {
                segments = await self.fetchAniSkipSegments(
                    tmdbId: tmdbId,
                    seasonNumber: seasonNumber ?? 1,
                    episodeNumber: ep,
                    showTitle: showTitle,
                    duration: durationAtFetch
                )

                if !segments.isEmpty {
                    Logger.shared.log("SkipData: AniSkip returned \(segments.count) segments", type: "Skip")
                }
            }

            // ── Fallback to TheIntroDB (or primary for non-anime) ──
            // For anime, use original TMDB S/E (pre-AniList restructuring) since TheIntroDB uses TMDB numbering
            let introDBSeason = self.originalTMDBSeasonNumber ?? seasonNumber
            let introDBEpisode = self.originalTMDBEpisodeNumber ?? episodeNumber
            if introDBEnabled, segments.isEmpty {
                do {
                    let introDBSegments = try await IntroDBService.shared.fetchSkipTimes(
                        tmdbId: tmdbId,
                        seasonNumber: introDBSeason,
                        episodeNumber: introDBEpisode,
                        episodeDuration: durationAtFetch
                    )
                    if !introDBSegments.isEmpty {
                        segments = introDBSegments
                        Logger.shared.log("SkipData: TheIntroDB returned \(segments.count) segments", type: "Skip")
                    }
                } catch {
                    Logger.shared.log("SkipData: TheIntroDB fetch failed: \(error.localizedDescription)", type: "Error")
                }
            }

            if segments.isEmpty {
                Logger.shared.log("SkipData: No skip data found from any source for tmdbId=\(tmdbId)", type: "Skip")
#if !os(tvOS)
                await MainActor.run {
                    if skip85sEnabled {
                        self.showSkip85sButton()
                    } else {
                        self.hideSkip85sButton()
                    }
                }
#endif
                return
            }

            // Store segments and normalize for progress bar
            await MainActor.run {
                self.skipSegments = segments
                let liveDuration = self.cachedDuration
                guard liveDuration > 0 else { return }
                self.progressModel.skipSegments = segments.map { seg in
                    (start: seg.startTime / liveDuration, end: seg.endTime / liveDuration)
                }
#if !os(tvOS)
                if skip85sEnabled && skip85sAlwaysVisible {
                    self.showSkip85sButton()
                } else {
                    self.hideSkip85sButton()
                }
#endif
            }
        }
    }

    /// AniSkip fetch with 4-step AniList ID resolution (anime-only path).
    private func fetchAniSkipSegments(tmdbId: Int, seasonNumber: Int, episodeNumber: Int, showTitle: String?, duration: Double) async -> [SkipSegment] {
        // Step 1: Check season-specific cache
        var anilistId = trackerManager.cachedAniListSeasonId(tmdbId: tmdbId, seasonNumber: seasonNumber)
        if let id = anilistId {
            Logger.shared.log("SkipData: AniSkip step 1 – cached season ID \(id)", type: "Skip")
        }

        // Step 2: Fall back to show-level cache
        if anilistId == nil {
            anilistId = trackerManager.cachedAniListId(for: tmdbId)
            if let id = anilistId {
                Logger.shared.log("SkipData: AniSkip step 2 – cached show ID \(id)", type: "Skip")
            }
        }

        // Step 3: Full AniList resolution via sequel chain
        if anilistId == nil, let title = showTitle {
            Logger.shared.log("SkipData: AniSkip step 3 – resolving via AniListService for '\(title)'", type: "Skip")
            do {
                let animeData = try await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                    title: title,
                    tmdbShowId: tmdbId,
                    tmdbService: TMDBService.shared,
                    tmdbShowPoster: nil,
                    token: nil
                )
                let seasonMappings = animeData.seasons.map { (seasonNumber: $0.seasonNumber, anilistId: $0.anilistId) }
                trackerManager.registerAniListAnimeData(tmdbId: tmdbId, seasons: seasonMappings)
                anilistId = animeData.seasons.first(where: { $0.seasonNumber == seasonNumber })?.anilistId
            } catch {
                Logger.shared.log("SkipData: AniSkip step 3 failed: \(error.localizedDescription)", type: "Skip")
            }
        }

        // Step 4: Last resort – simple title search
        if anilistId == nil {
            anilistId = await trackerManager.getAniListMediaId(tmdbId: tmdbId)
        }

        guard let finalId = anilistId else {
            Logger.shared.log("SkipData: No AniList ID found for tmdbId=\(tmdbId) — skipping AniSkip", type: "Skip")
            return []
        }

        Logger.shared.log("SkipData: AniSkip using anilistId=\(finalId) for ep=\(episodeNumber)", type: "Skip")

        do {
            return try await AniSkipService.shared.fetchSkipTimes(
                anilistId: finalId,
                episodeNumber: episodeNumber,
                episodeDuration: duration
            )
        } catch {
            Logger.shared.log("SkipData: AniSkip fetch failed: \(error.localizedDescription)", type: "Error")
            return []
        }
    }

#if !os(tvOS)
    private func updateSkipState(position: Double, duration: Double) {
        guard !skipSegments.isEmpty, duration > 0 else { return }

        // Deferred normalization: if fetchSkipData completed before duration was available,
        // progressModel.skipSegments will still be empty. Populate it now.
        if progressModel.skipSegments.isEmpty {
            progressModel.skipSegments = skipSegments.map { seg in
                (start: seg.startTime / duration, end: seg.endTime / duration)
            }
            Logger.shared.log("SkipData: Deferred normalization applied with duration=\(String(format: "%.1f", duration))", type: "Skip")
        }

        // Find if current position is inside any skip segment
        let activeSegment = skipSegments.first { seg in
            position >= seg.startTime && position <= seg.endTime
        }

        if let seg = activeSegment {
            // Auto-skip if enabled and not yet skipped for this segment
            let autoSkipEnabled = UserDefaults.standard.bool(forKey: "aniSkipAutoSkip")
            if autoSkipEnabled, !autoSkippedSegments.contains(seg.uniqueKey) {
                autoSkippedSegments.insert(seg.uniqueKey)
                Logger.shared.log("SkipData: Auto-skipping \(seg.type.rawValue) from \(Int(seg.startTime))s to \(Int(seg.endTime))s", type: "Skip")
                rendererSeek(to: seg.endTime + 1.0)
                return
            }

            if currentActiveSkipSegment?.uniqueKey != seg.uniqueKey {
                currentActiveSkipSegment = seg
                skipButton.configuration?.title = seg.type.displayLabel
                showSkipButton()
            }
        } else {
            if currentActiveSkipSegment != nil {
                currentActiveSkipSegment = nil
                hideSkipButton()
            }
        }
    }

    private func updateNextEpisodeState(position: Double, duration: Double) {
        guard isVLCPlayer, duration > 0 else { return }
        guard case .episode(_, _, _, _, _, _) = mediaInfo else { return }

        let enabled: Bool
        if UserDefaults.standard.object(forKey: "showNextEpisodeButton") == nil {
            enabled = true // default
        } else {
            enabled = UserDefaults.standard.bool(forKey: "showNextEpisodeButton")
        }
        guard enabled else {
            if nextEpisodeButtonShown { hideNextEpisodeButton() }
            return
        }

        let threshold: Double
        let savedThreshold = UserDefaults.standard.double(forKey: "nextEpisodeThreshold")
        threshold = savedThreshold > 0 ? savedThreshold : 0.90

        let progress = position / duration
        if progress >= threshold, !nextEpisodeButtonShown {
            showNextEpisodeButton()
        } else if progress < threshold, nextEpisodeButtonShown {
            hideNextEpisodeButton()
        }
    }

    @objc private func skipButtonTapped() {
        guard let seg = currentActiveSkipSegment else { return }
        Logger.shared.log("SkipData: User tapped skip for \(seg.type.rawValue) → seeking to \(Int(seg.endTime + 1))s", type: "Skip")
        autoSkippedSegments.insert(seg.uniqueKey)
        rendererSeek(to: seg.endTime + 1.0)
        currentActiveSkipSegment = nil
        hideSkipButton()
    }

    @objc private func nextEpisodeButtonTapped() {
        guard case .episode(_, let seasonNumber, let episodeNumber, _, _, _) = mediaInfo else { return }
        Logger.shared.log("NextEpisode: User requested S\(seasonNumber)E\(episodeNumber + 1)", type: "Player")
        onRequestNextEpisode?(seasonNumber, episodeNumber + 1)
        closeTapped()
    }

    private func showSkipButton() {
        guard skipButton.isHidden || skipButton.alpha < 1 else { return }
        skipButton.isHidden = false
        videoContainer.bringSubviewToFront(skipButton)
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut]) {
            self.skipButton.alpha = 1.0
        }
    }

    private func hideSkipButton() {
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn]) {
            self.skipButton.alpha = 0
        } completion: { _ in
            self.skipButton.isHidden = true
        }
    }

    @objc private func skip85sButtonTapped() {
        let currentPosition = cachedPosition
        let targetPosition = currentPosition + 85.0
        Logger.shared.log("Skip85s: User tapped skip 85s at \(Int(currentPosition))s → seeking to \(Int(targetPosition))s", type: "Skip")
        rendererSeek(to: targetPosition)
    }

    private func showSkip85sButton() {
        skip85sButtonShown = true
        guard controlsVisible else { return }
        skip85sButton.isHidden = false
        videoContainer.bringSubviewToFront(skip85sButton)
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut]) {
            self.skip85sButton.alpha = 1.0
        }
    }

    private func hideSkip85sButton() {
        guard skip85sButtonShown else { return }
        skip85sButtonShown = false
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn]) {
            self.skip85sButton.alpha = 0
        } completion: { _ in
            self.skip85sButton.isHidden = true
        }
    }

    private func showNextEpisodeButton() {
        guard !nextEpisodeButtonShown else { return }
        nextEpisodeButtonShown = true
        nextEpisodeButton.isHidden = false
        videoContainer.bringSubviewToFront(nextEpisodeButton)
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut]) {
            self.nextEpisodeButton.alpha = 1.0
        }
    }

    private func hideNextEpisodeButton() {
        guard nextEpisodeButtonShown else { return }
        nextEpisodeButtonShown = false
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn]) {
            self.nextEpisodeButton.alpha = 0
        } completion: { _ in
            self.nextEpisodeButton.isHidden = true
        }
    }
#endif

    private func isLocalFile() -> Bool {
        return initialURL?.isFileURL == true
    }

    private func isLocalProxyURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func languageName(for code: String) -> String {
        switch code.lowercased() {
        case "jpn", "ja", "jp": return "japanese"
        case "eng", "en", "us", "uk": return "english"
        case "spa", "es", "esp": return "spanish"
        case "fre", "fra", "fr": return "french"
        case "ger", "deu", "de": return "german"
        case "ita", "it": return "italian"
        case "por", "pt": return "portuguese"
        case "rus", "ru": return "russian"
        case "chi", "zho", "zh": return "chinese"
        case "kor", "ko": return "korean"
        default: return ""
        }
    }

    private func languageTokens(for preferred: String) -> [String] {
        let lower = preferred.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return [] }

        let map: [String: [String]] = [
            "jpn": ["jpn", "ja", "jp", "japanese"],
            "eng": ["eng", "en", "us", "uk", "english"],
            "spa": ["spa", "es", "esp", "spanish", "lat"],
            "fre": ["fre", "fra", "fr", "french"],
            "ger": ["ger", "deu", "de", "german"],
            "ita": ["ita", "it", "italian"],
            "por": ["por", "pt", "br", "portuguese"],
            "rus": ["rus", "ru", "russian"],
            "chi": ["chi", "zho", "zh", "chinese", "mandarin", "cantonese"],
            "kor": ["kor", "ko", "korean"]
        ]

        if let tokens = map[lower] {
            return tokens
        }

        let name = languageName(for: lower)
        if name.isEmpty {
            return [lower]
        }
        return [lower, name]
    }

    #if !os(tvOS)
    private func buildProxyHeaders(for url: URL, baseHeaders: [String: String]) -> [String: String] {
        var headers = baseHeaders
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = URLSession.randomUserAgent
        }
        if headers["Origin"] == nil, let host = url.host, let scheme = url.scheme {
            headers["Origin"] = "\(scheme)://\(host)"
        }
        if headers["Referer"] == nil {
            headers["Referer"] = url.absoluteString
        }
        return headers
    }

    private func proxySubtitleURLs(_ urls: [String], headers: [String: String]) -> [String] {
        let proxied = urls.compactMap { urlString -> String? in
            guard let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                Logger.shared.log("PlayerViewController: subtitle proxy skipped (invalid URL or scheme)", type: "Stream")
                return nil
            }

            let proxyHeaders = buildProxyHeaders(for: url, baseHeaders: headers)
            guard let proxiedURL = VLCHeaderProxy.shared.makeProxyURL(for: url, headers: proxyHeaders) else {
                Logger.shared.log("PlayerViewController: subtitle proxy URL creation failed", type: "Stream")
                return nil
            }
            return proxiedURL.absoluteString
        }
        Logger.shared.log("PlayerViewController: subtitle proxy result count=\(proxied.count) of \(urls.count)", type: "Stream")
        return proxied
    }

    private func attemptVlcProxyFallbackIfNeeded() -> Bool {
        guard vlcRenderer != nil else { return false }
        guard !vlcProxyFallbackTried else { return false }
        guard let originalURL = initialURL, originalURL.host != "127.0.0.1" else { return false }
        guard let headers = initialHeaders, !headers.isEmpty else { return false }

        let proxyEnabled = UserDefaults.standard.object(forKey: "vlcHeaderProxyEnabled") as? Bool ?? true
        guard proxyEnabled else { return false }
        guard let preset = initialPreset else { return false }

        let proxyHeaders = buildProxyHeaders(for: originalURL, baseHeaders: headers)
        guard let proxyURL = VLCHeaderProxy.shared.makeProxyURL(for: originalURL, headers: proxyHeaders) else {
            return false
        }

        let fallbackSubtitles: [String]?
        if let subs = initialSubtitles, !subs.isEmpty {
            Logger.shared.log("PlayerViewController: proxy fallback subtitle count=\(subs.count)", type: "Stream")
            let proxiedSubs = proxySubtitleURLs(subs, headers: headers)
            if proxiedSubs.count == subs.count {
                Logger.shared.log("PlayerViewController: proxy fallback subtitles ready", type: "Stream")
                fallbackSubtitles = proxiedSubs
            } else {
                Logger.shared.log("PlayerViewController: proxy fallback subtitles incomplete; using direct URLs", type: "Stream")
                fallbackSubtitles = subs
            }
        } else {
            fallbackSubtitles = nil
        }

        vlcProxyFallbackTried = true
        initialSubtitles = fallbackSubtitles

        Logger.shared.log("PlayerViewController: VLC proxy fallback activated", type: "Stream")
        load(url: proxyURL, preset: preset, headers: nil)
        return true
    }
    #else
    private func attemptVlcProxyFallbackIfNeeded() -> Bool {
        return false
    }
    #endif
    
    private func updateSubtitleTracksMenu() {
        guard isVLCPlayer else {
            return
        }
        let useCustomExternalOverlay = isVLCCustomSubtitleOverlayEnabled
        let externalTracks: [(Int, String)] = useCustomExternalOverlay
            ? subtitleURLs.enumerated().map { (index, _) in
                let name = index < subtitleNames.count ? subtitleNames[index] : "Subtitle \(index + 1)"
                return (index, name)
            }
            : []
        let embeddedTracks = rendererGetSubtitleTracks().filter { $0.0 >= 0 && !isDisabledTrackName($0.1) }

        Logger.shared.log("PlayerViewController: subtitle tracks external=\(externalTracks.count) embedded=\(embeddedTracks.count) userSelected=\(userSelectedSubtitleTrack) renderer=\(vlcRenderer != nil ? "VLC" : "MPV")", type: "Player")

        // Always show the subtitle button so the user can view the menu even when empty
        subtitleButton.isHidden = false

        // Use menu-only behavior for both VLC and MPV so the UI looks consistent
        subtitleButton.showsMenuAsPrimaryAction = true

        // Apply subtitle defaults while the user has not manually selected a track.
        if !userSelectedSubtitleTrack {
            let settings = Settings.shared
            if settings.enableSubtitlesByDefault {
                let preferredLang = settings.defaultSubtitleLanguage
                if let selectedEmbeddedTrack = preferredDefaultSubtitleTrack(from: embeddedTracks, preferredLang: preferredLang) {
                    if rendererGetCurrentSubtitleTrackId() != selectedEmbeddedTrack.0 {
                        rendererSetSubtitleTrack(id: selectedEmbeddedTrack.0)
                    }
                    userSelectedSubtitleTrack = true
                    subtitleModel.isVisible = true
                    vlcSubtitleSelection = .embedded(trackId: selectedEmbeddedTrack.0)
                    Logger.shared.log("[PlayerVC.Subtitles] default selected embedded track id=\(selectedEmbeddedTrack.0) name=\(selectedEmbeddedTrack.1)", type: "Player")
                } else if let firstExternalTrack = externalTracks.first {
                    currentSubtitleIndex = firstExternalTrack.0
                    loadCurrentSubtitle()
                    rendererDisableSubtitles()
                    updateVLCSubtitleOverlay(for: cachedPosition)
                    userSelectedSubtitleTrack = true
                    subtitleModel.isVisible = true
                    vlcSubtitleSelection = .external(index: firstExternalTrack.0)
                    Logger.shared.log("[PlayerVC.Subtitles] default selected external track index=\(firstExternalTrack.0)", type: "Player")
                }
            } else {
                rendererDisableSubtitles()
                subtitleEntries.removeAll()
                updateVLCSubtitleOverlay(for: cachedPosition)
                subtitleModel.isVisible = false
                vlcSubtitleSelection = .none
                Logger.shared.log("[PlayerVC.Subtitles] defaults disabled; subtitles forced off", type: "Player")
            }
            updateSubtitleButtonAppearance()
        }
        
        var trackActions: [UIAction] = []

        let disableAction = UIAction(
            title: "Disable Subtitles",
            image: UIImage(systemName: "xmark"),
            state: subtitleModel.isVisible ? .off : .on
        ) { [weak self] _ in
            self?.subtitleModel.isVisible = false
            self?.userSelectedSubtitleTrack = true
            self?.rendererDisableSubtitles()
            self?.subtitleEntries.removeAll()
            self?.vlcSubtitleSelection = .none
            self?.updateVLCSubtitleOverlay(for: self?.cachedPosition ?? 0)
            self?.updateSubtitleButtonAppearance()
            self?.updateSubtitleTracksMenu()
            Logger.shared.log("[PlayerVC.Subtitles] user disabled subtitles from menu", type: "Player")
        }
        trackActions.append(disableAction)
        
        if externalTracks.isEmpty && embeddedTracks.isEmpty {
            // Inform the user; keep menu available
            let noTracksAction = UIAction(title: "No subtitles in stream", state: .off) { _ in }
            trackActions.append(noTracksAction)
        } else {
            let externalSubtitleActions = externalTracks.map { (id, name) in
                UIAction(
                    title: name,
                    image: UIImage(systemName: "captions.bubble"),
                    state: subtitleModel.isVisible && {
                        if case .external(let selectedIndex) = self.vlcSubtitleSelection {
                            return selectedIndex == id
                        }
                        return false
                    }() ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    self.subtitleModel.isVisible = true
                    self.userSelectedSubtitleTrack = true
                    self.currentSubtitleIndex = id
                    self.vlcSubtitleSelection = .external(index: id)
                    Logger.shared.log("[PlayerVC.Subtitles] user selected external subtitle index=\(id) name=\(name)", type: "Player")
                    self.loadCurrentSubtitle()
                    self.rendererDisableSubtitles()
                    self.updateVLCSubtitleOverlay(for: self.cachedPosition)
                    self.updateSubtitleButtonAppearance()
                    // Debounce menu update to avoid lag - only update after 0.3s of no selection changes
                    self.subtitleMenuDebounceTimer?.invalidate()
                    self.subtitleMenuDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                        DispatchQueue.main.async { [weak self] in
                            self?.updateSubtitleTracksMenu()
                        }
                    }
                }
            }

            let embeddedSubtitleActions = embeddedTracks.map { (id, name) in
                UIAction(
                    title: name,
                    image: UIImage(systemName: "captions.bubble"),
                    state: subtitleModel.isVisible && {
                        if case .embedded(let selectedTrackId) = self.vlcSubtitleSelection {
                            return selectedTrackId == id
                        }
                        return false
                    }() ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    self.subtitleModel.isVisible = true
                    self.userSelectedSubtitleTrack = true
                    self.vlcSubtitleSelection = .embedded(trackId: id)
                    Logger.shared.log("[PlayerVC.Subtitles] user selected embedded subtitle id=\(id) name=\(name)", type: "Player")
                    self.subtitleEntries.removeAll()
                    self.updateVLCSubtitleOverlay(for: self.cachedPosition)
                    self.rendererSetSubtitleTrack(id: id)
                    self.rendererApplySubtitleStyle(SubtitleStyle(
                        foregroundColor: self.subtitleModel.foregroundColor,
                        strokeColor: self.subtitleModel.strokeColor,
                        strokeWidth: self.subtitleModel.strokeWidth,
                        fontSize: self.subtitleModel.fontSize,
                        isVisible: self.subtitleModel.isVisible
                    ))
                    self.updateSubtitleButtonAppearance()
                    self.subtitleMenuDebounceTimer?.invalidate()
                    self.subtitleMenuDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                        DispatchQueue.main.async { [weak self] in
                            self?.updateSubtitleTracksMenu()
                        }
                    }
                }
            }

            if !externalSubtitleActions.isEmpty {
                trackActions.append(contentsOf: externalSubtitleActions)
            }
            if !embeddedSubtitleActions.isEmpty {
                trackActions.append(contentsOf: embeddedSubtitleActions)
            }
        }
        
        let trackMenu = UIMenu(title: "Select Track", image: UIImage(systemName: "list.bullet"), children: trackActions)
        let menuChildren: [UIMenuElement]
        if Settings.shared.enableVLCSubtitleEditMenu {
            let appearanceMenu = createAppearanceMenu()
            menuChildren = [trackMenu, appearanceMenu]
        } else {
            menuChildren = [trackMenu]
        }
        let subtitleMenu = UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: menuChildren)
        subtitleButton.menu = subtitleMenu
    }

    private func isDisabledTrackName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.contains("disable") || lower.contains("off") || lower.contains("none")
    }

    private func preferredDefaultSubtitleTrack(from tracks: [(Int, String)], preferredLang: String) -> (Int, String)? {
        let languageMatches = languageTokens(for: preferredLang)
        let dialogueTokens = ["dialogue", "dialog", "full", "complete", "cc"]
        let lessPreferredTokens = ["sign", "songs", "song", "karaoke", "forced"]

        let ranked = tracks.map { track -> ((Int, String), Int) in
            let nameLower = track.1.lowercased()

            var score = 0

            if !languageMatches.isEmpty {
                if languageMatches.contains(where: { nameLower.contains($0) }) {
                    score += 100
                }
            }

            if dialogueTokens.contains(where: { nameLower.contains($0) }) {
                score += 10
            }

            if lessPreferredTokens.contains(where: { nameLower.contains($0) }) {
                score -= 8
            }

            return (track, score)
        }

        let sorted = ranked.sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.0 < rhs.0.0
            }
            return lhs.1 > rhs.1
        }

        let best = sorted.first?.0
        Logger.shared.log("PlayerViewController: default subtitles preferredLang=\(preferredLang) best=\(best?.1 ?? "nil") score=\(sorted.first?.1 ?? -999)", type: "Player")
        return best
    }

    @objc private func handleUserDefaultsDidChange() {
        guard isVLCPlayer else { return }
        Logger.shared.log("[PlayerVC.Settings] UserDefaults changed; evaluating VLC subtitle mode", type: "Player")
        applyVLCSubtitleModeSettingIfNeeded()
        applyVLCSubtitleOverlayPositionSetting()
    }

    private func applyVLCSubtitleModeSettingIfNeeded() {
        let customOverlayEnabled = isVLCCustomSubtitleOverlayEnabled
        if lastKnownVLCCustomSubtitleOverlayEnabled == customOverlayEnabled {
            return
        }
        Logger.shared.log("[PlayerVC.Subtitles] mode toggle detected customOverlayEnabled=\(customOverlayEnabled) subtitleURLs=\(subtitleURLs.count) isVisible=\(subtitleModel.isVisible)", type: "Player")
        lastKnownVLCCustomSubtitleOverlayEnabled = customOverlayEnabled

        if customOverlayEnabled {
            rendererDisableSubtitles()
            if subtitleModel.isVisible && !subtitleURLs.isEmpty {
                if currentSubtitleIndex >= subtitleURLs.count {
                    currentSubtitleIndex = 0
                }
                Logger.shared.log("[PlayerVC.Subtitles] switching to custom overlay mode; loading external subtitle index=\(currentSubtitleIndex)", type: "Player")
                loadCurrentSubtitle()
            } else {
                subtitleEntries.removeAll()
                updateVLCSubtitleOverlay(for: cachedPosition)
                Logger.shared.log("[PlayerVC.Subtitles] switching to custom overlay mode; no subtitle content to load", type: "Player")
            }
        } else {
            subtitleEntries.removeAll()
            updateVLCSubtitleOverlay(for: cachedPosition)
            if !subtitleURLs.isEmpty {
                if !vlcExternalSubtitlesLoadedNatively {
                    Logger.shared.log("[PlayerVC.Subtitles] switching to native VLC subtitle mode; loading external tracks into VLC", type: "Player")
                    rendererLoadExternalSubtitles(urls: subtitleURLs)
                    vlcExternalSubtitlesLoadedNatively = true
                }
                userSelectedSubtitleTrack = false
                updateSubtitleTracksMenuWhenReady()
            }
        }

        updateSubtitleTracksMenu()
        updateSubtitleButtonAppearance()
    }

    private func loadSubtitles(_ urls: [String], names: [String]? = nil) {
        subtitleURLs = urls
        subtitleNames = names ?? []
        userSelectedSubtitleTrack = false
        vlcSubtitleSelection = .none
        vlcExternalSubtitlesLoadedNatively = false
        
        if !urls.isEmpty {
            Logger.shared.log("PlayerViewController: loadSubtitles count=\(urls.count) renderer=\(vlcRenderer != nil ? "VLC" : "MPV")", type: "Stream")
            subtitleButton.isHidden = false
            currentSubtitleIndex = 0
            let enableByDefault = isVLCPlayer ? Settings.shared.enableSubtitlesByDefault : true
            subtitleModel.isVisible = enableByDefault
            
            // VLC can load external subtitles natively; MPV uses manual parsing
            if vlcRenderer != nil {
                if isVLCCustomSubtitleOverlayEnabled {
                    Logger.shared.log("[PlayerVC.Subtitles] loadSubtitles path=VLC customOverlay", type: "Stream")
                    rendererDisableSubtitles()
                    updateSubtitleTracksMenu()
                    updateVLCSubtitleOverlay(for: cachedPosition)
                } else {
                    Logger.shared.log("[PlayerVC.Subtitles] loadSubtitles path=VLC native", type: "Stream")
                    rendererLoadExternalSubtitles(urls: urls)
                    vlcExternalSubtitlesLoadedNatively = true
                    // Update subtitle menu after VLC loads the external subs
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.updateSubtitleTracksMenu()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self else { return }
                        let tracks = self.rendererGetSubtitleTracks()
                        if tracks.isEmpty {
                            Logger.shared.log("PlayerViewController: VLC external subtitles not detected after load", type: "Stream")
                        } else {
                            Logger.shared.log("PlayerViewController: VLC subtitle tracks available count=\(tracks.count)", type: "Stream")
                            self.updateSubtitleTracksMenuWhenReady()
                        }
                    }
                }
            } else {
                loadCurrentSubtitle()
            }
            
            updateSubtitleButtonAppearance()
            if isVLCPlayer {
                updateSubtitleTracksMenu()
            } else {
                updateSubtitleMenu()
            }
        } else {
            Logger.shared.log("No subtitle URLs to load", type: "Info")
        }
    }
    
    private func loadCurrentSubtitle() {
        guard currentSubtitleIndex < subtitleURLs.count else { return }
        let urlString = subtitleURLs[currentSubtitleIndex]
        Logger.shared.log("[PlayerVC.Subtitles] loadCurrentSubtitle index=\(currentSubtitleIndex) renderer=\(isVLCPlayer ? "VLC" : "MPV")", type: "Stream")

        // Handle local file:// URLs directly (e.g. downloaded media subtitles)
        if let url = URL(string: urlString), url.isFileURL {
            Logger.shared.log("[PlayerVC.Subtitles] Loading local subtitle file: \(url.path)", type: "Stream")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    let data = try Data(contentsOf: url)
                    guard let subtitleContent = String(data: data, encoding: .utf8) else {
                        Logger.shared.log("Failed to decode local subtitle data as UTF-8", type: "Error")
                        return
                    }
                    self.parseAndDisplaySubtitles(subtitleContent)
                } catch {
                    Logger.shared.log("Failed to read local subtitle file: \(error.localizedDescription)", type: "Error")
                }
            }
            return
        }

        if !isVLCPlayer {
            guard let url = URL(string: urlString) else {
                Logger.shared.log("Invalid subtitle URL: \(urlString)", type: "Error")
                return
            }

            URLSession.custom.dataTask(with: url) { [weak self] data, _, error in
                guard let self else { return }

                if let error = error {
                    Logger.shared.log("Failed to download subtitles: \(error.localizedDescription)", type: "Error")
                    return
                }

                guard let data = data, let subtitleContent = String(data: data, encoding: .utf8) else {
                    Logger.shared.log("Failed to parse subtitle data", type: "Error")
                    return
                }

                self.parseAndDisplaySubtitles(subtitleContent)
            }.resume()
            return
        }
        
        Logger.shared.log("Loading subtitle from: \(urlString)", type: "Info")
        
        guard let url = URL(string: urlString) else {
            Logger.shared.log("Invalid subtitle URL: \(urlString)", type: "Error")
            return
        }
        
        var request = URLRequest(url: url)
        if isLocalProxyURL(url) {
            Logger.shared.log("Subtitle download using local proxy URL; preserving proxy headers", type: "Stream")
        } else {
            if let headers = initialHeaders, !headers.isEmpty {
                for (key, value) in headers where !value.isEmpty {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue(URLSession.randomUserAgent, forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Origin") == nil,
               let scheme = url.scheme,
               let host = url.host {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
            }
        }
        request.timeoutInterval = 30
        
        // Download on background queue to avoid blocking main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            URLSession.custom.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }
                
                if let error = error {
                    Logger.shared.log("Failed to download subtitles: \(error.localizedDescription)", type: "Error")
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    Logger.shared.log("Subtitle download response: \(httpResponse.statusCode)", type: "Info")
                    if httpResponse.statusCode != 200 {
                        Logger.shared.log("Subtitle download failed with status \(httpResponse.statusCode)", type: "Error")
                        return
                    }
                }
                
                guard let data = data, let subtitleContent = String(data: data, encoding: .utf8) else {
                    Logger.shared.log("Failed to parse subtitle data (size: \(data?.count ?? 0) bytes)", type: "Error")
                    return
                }
                
                Logger.shared.log("Subtitle content loaded: \(subtitleContent.prefix(100))...", type: "Info")
                
                // Parse subtitles on background queue (heavy text processing)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    self.parseAndDisplaySubtitles(subtitleContent)
                }
            }.resume()
        }
    }
    
    private func parseAndDisplaySubtitles(_ content: String) {
        if !isVLCPlayer {
            subtitleEntries = SubtitleLoader.parseSubtitles(from: content, fontSize: subtitleModel.fontSize, foregroundColor: subtitleModel.foregroundColor)
            Logger.shared.log("Loaded \(subtitleEntries.count) subtitle entries", type: "Info")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.subtitleEntries = SubtitleLoader.parseSubtitles(from: content, fontSize: self.subtitleModel.fontSize, foregroundColor: self.subtitleModel.foregroundColor)
            Logger.shared.log("Loaded \(self.subtitleEntries.count) subtitle entries", type: "Info")
            self.updateVLCSubtitleOverlay(for: self.cachedPosition)
        }
    }
    
    @objc private func subtitleButtonTapped() {
        // Menu-first UI (VLC + MPV). When menu is primary, do not show action sheets.
        if subtitleButton.showsMenuAsPrimaryAction {
            return
        }

        // VLC uses menu system directly; this handler is for MPV only
        if vlcRenderer != nil {
            return
        }
        
        // External subtitles present (MPV)
        if !subtitleURLs.isEmpty {
            if subtitleURLs.count == 1 {
                subtitleModel.isVisible.toggle()
                rendererRefreshSubtitleOverlay()
                updateSubtitleButtonAppearance()
            } else {
                showSubtitleSelectionMenu()
            }
            showControlsTemporarily()
            Logger.shared.log("subtitleButtonTapped: handled external subtitle flow", type: "Info")
            return
        }

        // Embedded subtitles flow (MPV only at this point)
        let embeddedTracks = rendererGetSubtitleTracks()
        Logger.shared.log("subtitleButtonTapped: embedded flow, tracks=\(embeddedTracks.count)", type: "Info")

        let alert = UIAlertController(title: "Select Subtitle", message: nil, preferredStyle: .actionSheet)

        let disable = UIAlertAction(title: "Disable Subtitles", style: .destructive) { [weak self] _ in
            Logger.shared.log("Embedded subtitles disabled via action sheet", type: "Info")
            self?.userSelectedSubtitleTrack = true
            self?.rendererDisableSubtitles()
            self?.updateSubtitleTracksMenu()
        }
        alert.addAction(disable)

        if embeddedTracks.isEmpty {
            alert.addAction(UIAlertAction(title: "No subtitles in stream", style: .cancel, handler: nil))
        } else {
            for (id, name) in embeddedTracks {
                alert.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                    Logger.shared.log("Embedded subtitle selected via action sheet: id=\(id) name=\(name)", type: "Info")
                    self?.userSelectedSubtitleTrack = true
                    self?.rendererSetSubtitleTrack(id: id)
                    self?.updateSubtitleTracksMenu()
                })
            }
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

#if os(iOS)
        if let pop = alert.popoverPresentationController {
            pop.sourceView = subtitleButton
            pop.sourceRect = subtitleButton.bounds
        }
#endif

        present(alert, animated: true)
        showControlsTemporarily()
    }
    
    private func showSubtitleSelectionMenu() {
        let alert = UIAlertController(title: "Select Subtitle", message: nil, preferredStyle: .actionSheet)
        
        let disableAction = UIAlertAction(title: "Disable Subtitles", style: .default) { [weak self] _ in
            self?.subtitleModel.isVisible = false
            self?.userSelectedSubtitleTrack = true
            self?.rendererRefreshSubtitleOverlay()
            self?.updateSubtitleButtonAppearance()
        }
        alert.addAction(disableAction)
        
        for (index, _) in subtitleURLs.enumerated() {
            let title = index < subtitleNames.count ? subtitleNames[index] : "Subtitle \(index + 1)"
            let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.currentSubtitleIndex = index
                self?.subtitleModel.isVisible = true
                self?.userSelectedSubtitleTrack = true
                self?.loadCurrentSubtitle()
                self?.updateSubtitleButtonAppearance()
            }
            alert.addAction(action)
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alert.addAction(cancelAction)
        
#if os(iOS)
        if let popover = alert.popoverPresentationController {
            popover.sourceView = subtitleButton
            popover.sourceRect = subtitleButton.bounds
        }
#endif
        
        present(alert, animated: true, completion: nil)
    }
    
    private func animateButtonTap(_ button: UIButton) {
        UIView.animate(withDuration: 0.1, delay: 0, options: [.curveEaseOut]) {
            button.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        } completion: { _ in
            UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseIn]) {
                button.transform = .identity
            }
        }
    }
    
    private func updateProgressHostingController() {
        struct ProgressHostView: View {
            @ObservedObject var model: ProgressModel
            var onEditingChanged: (Bool) -> Void
            var body: some View {
                MusicProgressSlider(
                    value: Binding(get: { model.position }, set: { model.position = $0 }),
                    inRange: 0...max(model.duration, 1.0),
                    activeFillColor: .white,
                    fillColor: .white,
                    textColor: .white.opacity(0.7),
                    emptyColor: .white.opacity(0.3),
                    height: 33,
                    segments: model.skipSegments,
                    onEditingChanged: onEditingChanged
                )
            }
        }
        
        if progressHostingController != nil {
            return
        }
        
        let host = UIHostingController(rootView: AnyView(ProgressHostView(model: progressModel, onEditingChanged: { [weak self] editing in
            guard let self = self else { return }
            self.isSeeking = editing
            if !editing {
                self.rendererSeek(to: max(0, self.progressModel.position))
            }
        })))

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        progressContainer.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: progressContainer.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: progressContainer.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor)
        ])
        host.didMove(toParent: self)
        progressHostingController = host

    }
    
    private func updatePlayPauseButton(isPaused: Bool, shouldShowControls: Bool = true) {
        DispatchQueue.main.async {
            if self.isRendererLoading {
                self.centerPlayPauseButton.isHidden = true
                return
            }
            let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .semibold)
            let name = isPaused ? "play.fill" : "pause.fill"
            let img = UIImage(systemName: name, withConfiguration: config)
            self.centerPlayPauseButton.setImage(img, for: .normal)
            self.centerPlayPauseButton.isHidden = false
            
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut]) {
                self.centerPlayPauseButton.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
            } completion: { _ in
                UIView.animate(withDuration: 0.15) {
                    self.centerPlayPauseButton.transform = .identity
                }
            }
            
            if shouldShowControls {
                self.showControlsTemporarily()
            }
        }
    }
    
    // MARK: - Error display helpers
    private func presentErrorAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            ac.addAction(UIAlertAction(title: "View Logs", style: .default, handler: { _ in
                self.viewLogsTapped()
            }))
            self.showErrorBanner(message)
            if self.presentedViewController == nil {
                self.present(ac, animated: true, completion: nil)
            }
        }
    }
    
    private func showTransientErrorBanner(_ message: String, duration: TimeInterval = 4.0) {
        guard shouldShowTopErrorBanner else { return }
        DispatchQueue.main.async {
            self.showErrorBanner(message)
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.hideErrorBanner), object: nil)
            self.perform(#selector(self.hideErrorBanner), with: nil, afterDelay: duration)
        }
    }
    
    @objc private func hideErrorBanner() {
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.25) {
                self.errorBanner.alpha = 0.0
            }
        }
    }
    
    @objc private func handleLoggerNotification(_ note: Notification) {
        guard shouldShowTopErrorBanner else { return }
        guard let info = note.userInfo,
              let message = info["message"] as? String,
              let type = info["type"] as? String else { return }

        let lower = type.lowercased()
        if lower == "error" || lower == "warn" || message.lowercased().contains("error") || message.lowercased().contains("warn") {
            showTransientErrorBanner(message)
        }
    }
    
    private func showErrorBanner(_ message: String) {
        guard shouldShowTopErrorBanner else { return }
        DispatchQueue.main.async {
            guard let label = self.errorBanner.viewWithTag(101) as? UILabel else { return }
            label.text = message
            self.view.bringSubviewToFront(self.errorBanner)
            UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.6, options: [.curveEaseOut], animations: {
                self.errorBanner.alpha = 1.0
                self.errorBanner.transform = CGAffineTransform(translationX: 0, y: 4)
            }, completion: nil)
        }
    }
    
    @objc private func viewLogsTapped() {
        Task { @MainActor in
            let logs = await Logger.shared.getLogsAsync()
            let vc = UIViewController()
            vc.view.backgroundColor = UIColor(named: "background")
            let tv = UITextView()
            tv.translatesAutoresizingMaskIntoConstraints = false
            
#if !os(tvOS)
            tv.isEditable = false
#endif
            tv.text = logs
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            vc.view.addSubview(tv)
            NSLayoutConstraint.activate([
                tv.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 12),
                tv.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 12),
                tv.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -12),
                tv.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor, constant: -12),
            ])
            vc.navigationItem.title = "Logs"
            let nav = UINavigationController(rootViewController: vc)
            
#if !os(tvOS)
            nav.modalPresentationStyle = .pageSheet
#endif
            
            let close: UIBarButtonItem
            
#if compiler(>=6.0)
            if #available(iOS 26.0, tvOS 26.0, *) {
                close = UIBarButtonItem(title: "Close", style: .prominent, target: self, action: #selector(dismissLogs))
            } else {
                close = UIBarButtonItem(title: "Close", style: .done, target: self, action: #selector(dismissLogs))
            }
#else
            close = UIBarButtonItem(title: "Close", style: .done, target: self, action: #selector(dismissLogs))
#endif
            vc.navigationItem.rightBarButtonItem = close
            self.present(nav, animated: true, completion: nil)
        }
    }
    
    @objc private func dismissLogs() {
        dismiss(animated: true, completion: nil)
    }
    
    @objc private func containerTapped() {
        if controlsVisible {
            hideControls()
        } else {
            showControlsTemporarily()
        }
    }
    
    private func showControlsTemporarily() {
        controlsHideWorkItem?.cancel()
        controlsVisible = true
        updateBrightnessControlVisibility()

        // Ensure controls sit above the video layer/view
        videoContainer.bringSubviewToFront(controlsOverlayView)
        videoContainer.bringSubviewToFront(centerPlayPauseButton)
        videoContainer.bringSubviewToFront(progressContainer)
        videoContainer.bringSubviewToFront(closeButton)
        videoContainer.bringSubviewToFront(pipButton)
        videoContainer.bringSubviewToFront(skipBackwardButton)
        videoContainer.bringSubviewToFront(skipForwardButton)
        videoContainer.bringSubviewToFront(speedIndicatorLabel)
        videoContainer.bringSubviewToFront(subtitleButton)
        if isVLCPlayer {
            videoContainer.bringSubviewToFront(speedButton)
            videoContainer.bringSubviewToFront(audioButton)
        }
#if !os(tvOS)
        videoContainer.bringSubviewToFront(brightnessContainer)
        if skip85sButtonShown {
            videoContainer.bringSubviewToFront(skip85sButton)
        }
#endif
        
        DispatchQueue.main.async {
            self.controlsOverlayView.isHidden = false
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                self.centerPlayPauseButton.alpha = 1.0
                self.controlsOverlayView.alpha = 1.0
                self.progressContainer.alpha = 1.0
                self.closeButton.alpha = 1.0
                self.pipButton.alpha = 1.0
                self.skipBackwardButton.alpha = 1.0
                self.skipForwardButton.alpha = 1.0
                if !self.subtitleButton.isHidden {
                    self.subtitleButton.alpha = 1.0
                }
                if self.isVLCPlayer {
                    self.speedButton.alpha = 1.0
                    if !self.audioButton.isHidden {
                        self.audioButton.alpha = 1.0
                    }
                }
#if !os(tvOS)
                if self.isBrightnessControlEnabled {
                    self.brightnessContainer.isHidden = false
                    self.brightnessContainer.alpha = 1.0
                }
                if self.skip85sButtonShown {
                    self.skip85sButton.isHidden = false
                    self.skip85sButton.alpha = 1.0
                }
#endif
            }
        }
        
        let work = DispatchWorkItem { [weak self] in
            self?.hideControls()
        }
        controlsHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }
    
    private func hideControls() {
        controlsHideWorkItem?.cancel()
        controlsVisible = false
        
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn]) {
                self.centerPlayPauseButton.alpha = 0.0
                self.controlsOverlayView.alpha = 0.0
                self.progressContainer.alpha = 0.0
                self.closeButton.alpha = 0.0
                self.pipButton.alpha = 0.0
                self.skipBackwardButton.alpha = 0.0
                self.skipForwardButton.alpha = 0.0
                self.subtitleButton.alpha = 0.0
                if self.isVLCPlayer {
                    self.speedButton.alpha = 0.0
                    self.audioButton.alpha = 0.0
                }
#if !os(tvOS)
                self.brightnessContainer.alpha = 0.0
                if self.skip85sButtonShown {
                    self.skip85sButton.alpha = 0.0
                }
#endif
            } completion: { _ in
                self.controlsOverlayView.isHidden = true
#if !os(tvOS)
                if self.skip85sButtonShown {
                    self.skip85sButton.isHidden = true
                }
#endif
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateBrightnessControlVisibility()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        #if !os(tvOS)
        if isBrightnessControlEnabled {
            let location = touch.location(in: brightnessContainer)
            if brightnessContainer.bounds.contains(location) {
                return false
            }
        }
        #endif
        
        // Filter double-tap gestures by screen side
        let location = touch.location(in: videoContainer)
        let isLeftSide = location.x < videoContainer.bounds.width / 2
        
        if gestureRecognizer === leftDoubleTapGesture {
            return isLeftSide
        } else if gestureRecognizer === rightDoubleTapGesture {
            return !isLeftSide
        }
        
        return true
    }
    
    @objc private func closeTapped() {
        if isClosing { return }
        isClosing = true
        let isAnyPiPActive = (pipController?.isPictureInPictureActive == true)
        logMPV("closeTapped; pipActive=\(isAnyPiPActive); mediaInfo=\(String(describing: mediaInfo))")
        closeButton.isEnabled = false
        view.isUserInteractionEnabled = false

        var teardownPerformed = false
        let teardownAndStop: () -> Void = { [weak self] in
            guard let self else { return }
            if teardownPerformed { return }
            teardownPerformed = true

            if let mpv = self.mpvRenderer {
                mpv.delegate = nil
            } else if let vlc = self.vlcRenderer {
                vlc.delegate = nil
            }

            self.pipController?.delegate = nil
            if self.pipController?.isPictureInPictureActive == true {
                self.pipController?.stopPictureInPicture()
            }

            self.rendererStop()
            self.logMPV("renderer.stop called from closeTapped")
        }

        if let presenter = presentingViewController {
            presenter.dismiss(animated: true) {
                teardownAndStop()
            }
        } else {
            dismiss(animated: true) {
                teardownAndStop()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            teardownAndStop()
        }
    }
    
    @objc private func pipTapped() {
        // VLC PiP is disabled — button should be hidden for VLC, but guard anyway.
        if isVLCPlayer { return }

        guard let pip = pipController else { return }
        Logger.shared.log("[PlayerVC.PiP] button tap state active=\(pip.isPictureInPictureActive) possible=\(pip.isPictureInPicturePossible) supported=\(pip.isPictureInPictureSupported) isVLC=\(isVLCPlayer)", type: "Player")
        if pip.isPictureInPictureActive {
            Logger.shared.log("[PlayerVC.PiP] stopping PiP from button", type: "Player")
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            Logger.shared.log("[PlayerVC.PiP] starting PiP from button", type: "Player")
            pip.startPictureInPicture()
        } else {
            Logger.shared.log("[PlayerVC.PiP] start blocked: PiP not possible active=\(pip.isPictureInPictureActive) possible=\(pip.isPictureInPicturePossible) supported=\(pip.isPictureInPictureSupported)", type: "Player")
        }
    }

    private func updatePosition(_ position: Double, duration: Double) {

        // Some VLC/HLS sources report 0 duration for a while; keep the last good duration so progress persists.
        let effectiveDuration: Double
        if duration.isFinite, duration > 0 {
            effectiveDuration = duration
        } else {
            effectiveDuration = cachedDuration
        }

        let safePosition: Double
        if position.isFinite, position >= 0 {
            safePosition = position
        } else {
            safePosition = max(0, cachedPosition)
        }

        let safeDuration: Double
        if effectiveDuration.isFinite, effectiveDuration > 0 {
            safeDuration = effectiveDuration
        } else {
            safeDuration = max(1.0, cachedDuration)
        }

        if !position.isFinite || !duration.isFinite {
            Logger.shared.log("[PlayerVC.progress] non-finite input from renderer. rawPos=\(position) rawDur=\(duration) cachedPos=\(cachedPosition) cachedDur=\(cachedDuration)", type: "Error")
        }



        DispatchQueue.main.async {
            if duration.isFinite, duration > 0 {
                self.cachedDuration = duration
            }
            self.cachedPosition = safePosition
            if safeDuration > 0 {
                self.updateProgressHostingController()
            }
            self.progressModel.position = safePosition
            self.progressModel.duration = max(safeDuration, 1.0)
            
            if self.pipController?.isPictureInPictureActive == true {
                self.pipController?.updatePlaybackState()
            }

            if self.isVLCPlayer {
                self.updateVLCSubtitleOverlay(for: safePosition)
            }

#if !os(tvOS)
            if self.isVLCPlayer {
                self.updateSkipState(position: safePosition, duration: safeDuration)
                self.updateNextEpisodeState(position: safePosition, duration: safeDuration)
            }
#endif

            // If playback is progressing, force-hide any lingering loading spinner
            if !self.isRendererLoading && (self.loadingIndicator.alpha > 0.0 || self.loadingIndicator.isAnimating) {
                self.loadingIndicator.stopAnimating()
                self.loadingIndicator.alpha = 0.0
                self.centerPlayPauseButton.isHidden = false
            }
        }
        
        guard safeDuration.isFinite, safeDuration > 0, safePosition >= 0, let info = mediaInfo else { return }
        
        switch info {
        case .movie(let id, let title, _, _):
            ProgressManager.shared.updateMovieProgress(movieId: id, title: title, currentTime: safePosition, totalDuration: safeDuration)
        case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, let showPosterURL, _):
            ProgressManager.shared.updateEpisodeProgress(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber, currentTime: safePosition, totalDuration: safeDuration, showTitle: showTitle, showPosterURL: showPosterURL)
        }
    }
}

// MARK: - MPVSoftwareRendererDelegate
extension PlayerViewController: MPVSoftwareRendererDelegate {
    func renderer(_ renderer: MPVSoftwareRenderer, didUpdatePosition position: Double, duration: Double) {
        if isClosing { return }
        updatePosition(position, duration: duration)
    }
    
    func renderer(_ renderer: MPVSoftwareRenderer, didChangePause isPaused: Bool) {
        if isClosing { return }
        if isRendererLoading {
            pipController?.updatePlaybackState()
            return
        }
        updatePlayPauseButton(isPaused: isPaused)
        pipController?.updatePlaybackState()
    }
    
    func renderer(_ renderer: MPVSoftwareRenderer, didChangeLoading isLoading: Bool) {
        if isClosing { return }
        isRendererLoading = isLoading
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isLoading {
                self.centerPlayPauseButton.isHidden = true
                self.loadingIndicator.alpha = 1.0
                self.loadingIndicator.startAnimating()
            } else {
                self.loadingIndicator.stopAnimating()
                self.loadingIndicator.alpha = 0.0
                self.centerPlayPauseButton.isHidden = false
                self.updatePlayPauseButton(isPaused: self.rendererIsPausedState())
            }
        }
    }
    
    func renderer(_ renderer: MPVSoftwareRenderer, didBecomeReadyToSeek: Bool) {
        if isClosing { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            
            if let seekTime = self.pendingSeekTime {
                self.rendererSeek(to: seekTime)
                Logger.shared.log("Resumed MPV playback from \(Int(seekTime))s", type: "Progress")
                self.pendingSeekTime = nil
            }

            // Fetch skip data once MPV is ready
            self.fetchSkipData()
        }
    }

    func rendererDidChangeTracks(_ renderer: MPVSoftwareRenderer) {
        if isClosing { return }
    }
    
    func renderer(_ renderer: MPVSoftwareRenderer, getSubtitleForTime time: Double) -> NSAttributedString? {
        guard subtitleModel.isVisible, !subtitleEntries.isEmpty else {
            return nil
        }
        
        if let entry = subtitleEntries.first(where: { $0.startTime <= time && time <= $0.endTime }) {
            return entry.attributedText
        }
        
        return nil
    }
    
    func renderer(_ renderer: MPVSoftwareRenderer, getSubtitleStyle: Void) -> SubtitleStyle {
        let style = SubtitleStyle(
            foregroundColor: subtitleModel.foregroundColor,
            strokeColor: subtitleModel.strokeColor,
            strokeWidth: subtitleModel.strokeWidth,
            fontSize: subtitleModel.fontSize,
            isVisible: subtitleModel.isVisible
        )
        return style
    }
    
    func renderer(_ renderer: MPVSoftwareRenderer, subtitleTrackDidChange trackId: Int) {
        if isClosing { return }
        // When an embedded subtitle track is selected, enable subtitle display
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.subtitleModel.isVisible = true
            self.updateSubtitleButtonAppearance()
            // Embedded subtitles are extracted from mpv and rendered manually
        }
    }

}

// MARK: - VLCRendererDelegate
extension PlayerViewController: VLCRendererDelegate {
    func renderer(_ renderer: VLCRenderer, didUpdatePosition position: Double, duration: Double) {
        if isClosing { return }
        updatePosition(position, duration: duration)
    }
    
    func renderer(_ renderer: VLCRenderer, didChangePause isPaused: Bool) {
        if isClosing { return }

        if isRendererLoading {
            pipController?.updatePlaybackState()
            return
        }
        updatePlayPauseButton(isPaused: isPaused)
        pipController?.updatePlaybackState()
    }
    
    func renderer(_ renderer: VLCRenderer, didChangeLoading isLoading: Bool) {
        if isClosing { return }

        isRendererLoading = isLoading
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isLoading {
                self.centerPlayPauseButton.isHidden = true
                self.loadingIndicator.alpha = 1.0
                self.loadingIndicator.startAnimating()
            } else {
                self.loadingIndicator.stopAnimating()
                self.loadingIndicator.alpha = 0.0
                self.centerPlayPauseButton.isHidden = false
                self.updatePlayPauseButton(isPaused: self.rendererIsPausedState(), shouldShowControls: false)
            }
        }
    }
    
    func renderer(_ renderer: VLCRenderer, didBecomeReadyToSeek: Bool) {
        if isClosing { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            
            // Update audio and subtitle tracks now that the video is ready
            self.updateAudioTracksMenuWhenReady()
            self.updateSubtitleTracksMenuWhenReady()
            
            if let seekTime = self.pendingSeekTime {
                self.rendererSeek(to: seekTime)
                Logger.shared.log("Resumed VLC playback from \(Int(seekTime))s", type: "Progress")
                self.pendingSeekTime = nil
            }

            // Fetch skip data once VLC is ready
            self.fetchSkipData()
        }
    }

    func renderer(_ renderer: VLCRenderer, didFailWithError message: String) {
        if isClosing { return }
        Logger.shared.log("[PlayerVC.VLCDelegate] didFailWithError message=\(message)", type: "Error")
        if attemptVlcProxyFallbackIfNeeded() {
            return
        }
        Logger.shared.log("PlayerViewController: VLC error: \(message)", type: "Error")
    }

    func rendererDidChangeTracks(_ renderer: VLCRenderer) {
        if isClosing { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateAudioTracksMenu()
            self.updateSubtitleTracksMenu()
        }
    }
    
    func renderer(_ renderer: VLCRenderer, getSubtitleForTime time: Double) -> NSAttributedString? {
        guard subtitleModel.isVisible, !subtitleEntries.isEmpty else {
            return nil
        }
        
        if let entry = subtitleEntries.first(where: { $0.startTime <= time && time <= $0.endTime }) {
            return entry.attributedText
        }
        return nil
    }
    
    func renderer(_ renderer: VLCRenderer, getSubtitleStyle: Void) -> SubtitleStyle {
        return SubtitleStyle(
            foregroundColor: subtitleModel.foregroundColor,
            strokeColor: subtitleModel.strokeColor,
            strokeWidth: subtitleModel.strokeWidth,
            fontSize: subtitleModel.fontSize,
            isVisible: subtitleModel.isVisible
        )
    }
    
    func renderer(_ renderer: VLCRenderer, subtitleTrackDidChange trackId: Int) {
        if isClosing { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.subtitleModel.isVisible = true
            if trackId >= 0 {
                self.vlcSubtitleSelection = .embedded(trackId: trackId)
                self.rendererApplySubtitleStyle(SubtitleStyle(
                    foregroundColor: self.subtitleModel.foregroundColor,
                    strokeColor: self.subtitleModel.strokeColor,
                    strokeWidth: self.subtitleModel.strokeWidth,
                    fontSize: self.subtitleModel.fontSize,
                    isVisible: self.subtitleModel.isVisible
                ))
            }
            self.subtitleEntries.removeAll()
            self.updateVLCSubtitleOverlay(for: self.cachedPosition)
            self.updateSubtitleButtonAppearance()
            // VLC natively renders ASS subtitles
        }
    }
}

// MARK: - PiP Support
extension PlayerViewController: PiPControllerDelegate {
    func pipController(_ controller: PiPController, willStartPictureInPicture: Bool) {
        Logger.shared.log("[PlayerVC.PiP] delegate willStart possible=\(controller.isPictureInPicturePossible)", type: "Player")
        pipController?.updatePlaybackState()
    }
    func pipController(_ controller: PiPController, didStartPictureInPicture: Bool) {
        Logger.shared.log("[PlayerVC.PiP] delegate didStart success=\(didStartPictureInPicture)", type: "Player")
        pipController?.updatePlaybackState()
    }
    func pipController(_ controller: PiPController, willStopPictureInPicture: Bool) {
        Logger.shared.log("[PlayerVC.PiP] delegate willStop", type: "Player")
    }
    func pipController(_ controller: PiPController, didStopPictureInPicture: Bool) {
        Logger.shared.log("[PlayerVC.PiP] delegate didStop", type: "Player")
    }
    func pipController(_ controller: PiPController, restoreUserInterfaceForPictureInPictureStop completionHandler: @escaping (Bool) -> Void) {
        if presentedViewController != nil {
            dismiss(animated: true) { completionHandler(true) }
        } else {
            completionHandler(true)
        }
    }
    func pipControllerPlay(_ controller: PiPController) {
        rendererPlay()
    }
    func pipControllerPause(_ controller: PiPController) {
        rendererPausePlayback()
    }
    func pipController(_ controller: PiPController, skipByInterval interval: CMTime) {
        let seconds = CMTimeGetSeconds(interval)
        let target = max(0, cachedPosition + seconds)
        rendererSeek(to: target)
        pipController?.updatePlaybackState()
    }
    func pipControllerIsPlaying(_ controller: PiPController) -> Bool {
        return !rendererIsPausedState()
    }
    func pipControllerDuration(_ controller: PiPController) -> Double { return cachedDuration }
    func pipControllerCurrentTime(_ controller: PiPController) -> Double { return cachedPosition }
    
    @objc private func appDidEnterBackground() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // VLC pauses itself via VLCRenderer background handler; nothing to do here.
            if self.isVLCPlayer { return }

            guard let pip = self.pipController else { return }
            Logger.shared.log("[PlayerVC.PiP] background check active=\(pip.isPictureInPictureActive) possible=\(pip.isPictureInPicturePossible) supported=\(pip.isPictureInPictureSupported) isVLC=\(self.isVLCPlayer)", type: "Player")
            if pip.isPictureInPicturePossible && !pip.isPictureInPictureActive {
                self.logMPV("Entering background; starting PiP")
                pip.startPictureInPicture()
            } else {
                Logger.shared.log("[PlayerVC.PiP] background auto-start not triggered possible=\(pip.isPictureInPicturePossible) active=\(pip.isPictureInPictureActive)", type: "Player")
            }
        }
    }
    
    @objc private func appWillEnterForeground() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // VLC handles its own background pause via VLCRenderer; no PiP to stop.
            if self.isVLCPlayer { return }
            guard let pip = self.pipController else { return }
            if pip.isPictureInPictureActive {
                self.logMPV("Returning to foreground; stopping PiP")
                pip.stopPictureInPicture()
            }
        }
    }
}
