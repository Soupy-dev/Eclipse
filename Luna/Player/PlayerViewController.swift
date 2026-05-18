//
//  PlayerViewController.swift
//  test
//
//  Created by Francesco on 28/09/25.
//

import UIKit
import SwiftUI
import AVFoundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Kingfisher)
import Kingfisher
#endif
#if canImport(AVKit)
import AVKit
#endif
#if canImport(MediaPlayer)
import MediaPlayer
#endif

enum PlaybackSourceKind: String {
    case service
    case stremio
}

struct PlaybackLaunchContext {
    let sourceId: String
    let sourceName: String
    let sourceKind: PlaybackSourceKind
    let autoMode: Bool
    let streamURL: String
    let streamName: String?
    let headers: [String: String]
    let subtitles: [String]
    let subtitleNames: [String]?
    let retryCount: Int

    init(
        sourceId: String,
        sourceName: String,
        sourceKind: PlaybackSourceKind,
        autoMode: Bool,
        streamURL: String,
        streamName: String? = nil,
        headers: [String: String],
        subtitles: [String],
        subtitleNames: [String]?,
        retryCount: Int
    ) {
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.autoMode = autoMode
        self.streamURL = streamURL
        self.streamName = streamName
        self.headers = headers
        self.subtitles = subtitles
        self.subtitleNames = subtitleNames
        self.retryCount = retryCount
    }
}

struct PlaybackFailureReport {
    let context: PlaybackLaunchContext
    let message: String
    let isSourceFailure: Bool
}

final class PlayerViewController: UIViewController, UIGestureRecognizerDelegate {
    private struct PlayerOverlayMenuAction {
        let title: String
        let imageName: String?
        let isSelected: Bool
        let isEnabled: Bool
        let handler: () -> Void
    }

    private struct PlayerOverlayMenuSection {
        let title: String?
        let actions: [PlayerOverlayMenuAction]
    }

    private let playerLogId = UUID().uuidString.prefix(8)
    private let trackerManager = TrackerManager.shared
    private var overlayMenuHandlers: [Int: () -> Void] = [:]
    private var nextOverlayMenuHandlerID = 1
    private var overlayMenuKind: String?

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
    private weak var vlcRenderingView: UIView?
    private weak var mpvRenderingView: UIView?
    
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

    private let performanceOverlayLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        label.textColor = UIColor.systemGreen
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.alpha = 0.0
        label.isHidden = true
        label.isUserInteractionEnabled = false
        return label
    }()

    private lazy var overlayMenuDismissView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.alpha = 0.0
        view.isHidden = true
        view.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(overlayMenuDismissTapped))
        view.addGestureRecognizer(tap)
        return view
    }()

    private let overlayMenuPanelView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.black.withAlphaComponent(0.88)
        view.layer.cornerRadius = 8
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        view.clipsToBounds = true
        view.alpha = 0.0
        view.isHidden = true
        view.isUserInteractionEnabled = true
        return view
    }()

    private let overlayMenuTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.numberOfLines = 1
        return label
    }()

    private let overlayMenuScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.backgroundColor = .clear
        return scrollView
    }()

    private let overlayMenuStackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 4
        return stack
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

    private let playerTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.alpha = 0.0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
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

    private let episodeBrowserButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let img = UIImage(systemName: "list.bullet.rectangle", withConfiguration: cfg)
        b.setImage(img, for: .normal)
        b.tintColor = .white
        b.alpha = 0.0
        b.isHidden = true
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
        let v = UIVisualEffectView(effect: nil)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        v.contentView.backgroundColor = .clear
        v.clipsToBounds = false
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

    private let volumeContainer: UIVisualEffectView = {
        let v = UIVisualEffectView(effect: nil)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        v.contentView.backgroundColor = .clear
        v.clipsToBounds = false
        v.alpha = 0.0
        v.isHidden = true
        return v
    }()

    private let volumeSlider: UISlider = {
        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumValue = 0.0
        slider.maximumValue = 1.0
        slider.value = 0.5
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.thumbTintColor = .white
        return slider
    }()

    private let volumeIcon: UIImageView = {
        let icon = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.alpha = 0.8
        return icon
    }()

#if canImport(MediaPlayer)
    private let systemVolumeView: MPVolumeView = {
        let view = MPVolumeView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alpha = 0.01
        view.isHidden = false
        return view
    }()
#endif
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
        @Published var durationIsKnown: Bool = false
        @Published var skipSegments: [(start: Double, end: Double)] = []
    }
    private var progressModel = ProgressModel()

    private var containerTapGesture: UITapGestureRecognizer?
    private var leftDoubleTapGesture: UITapGestureRecognizer?
    private var rightDoubleTapGesture: UITapGestureRecognizer?
#if !os(tvOS)
    private var brightnessPanGesture: UIPanGestureRecognizer?
    private var volumePanGesture: UIPanGestureRecognizer?
    private var brightnessPanStartLevel: Float = 1.0
    private var volumePanStartLevel: Float = 0.5
    private var isBrightnessControlActive = false
    private var isVolumeControlActive = false
    private var outputVolumeObservation: NSKeyValueObservation?
#if canImport(MediaPlayer)
    private weak var systemVolumeSlider: UISlider?
#endif
#endif

    private var brightnessLevel: Float = 1.0
    private let twoFingerSettingKey = "playerTwoFingerTapPlayPauseEnabled"
    private let legacyTwoFingerSettingKey = "mpvTwoFingerTapEnabled"
    private let doubleTapSeekEnabledKey = "vlcDoubleTapSeekEnabled"
    private let playerSeekSecondsKey = "vlcDoubleTapSeekSeconds"
    private let playerPerformanceOverlayKey = "playerPerformanceOverlayEnabled"
    private let brightnessLevelKey = "mpvBrightnessLevel"
    
    private lazy var renderer: PlayerRenderer = {
        let requestedPlayerChoice = Settings.shared.playerChoice
        let smartChoice = smartInAppPlayerChoice(requested: requestedPlayerChoice)
        let playerChoice = smartChoice.choice
        
        if playerChoice == .vlc {
            if let reason = smartChoice.reason {
                Logger.shared.log("[PlayerVC.SmartPlayer] using \(playerChoiceName(playerChoice)) instead of \(playerChoiceName(requestedPlayerChoice)) reason=\(reason)", type: "Player")
            }
            let r = VLCRenderer(displayLayer: displayLayer)
            r.delegate = self
            return r
        } else {
            if let reason = smartChoice.reason {
                Logger.shared.log("[PlayerVC.SmartPlayer] using \(playerChoiceName(playerChoice)) instead of \(playerChoiceName(requestedPlayerChoice)) reason=\(reason)", type: "Player")
            }
            let r = MPVNativeRenderer(displayLayer: displayLayer)
            r.delegate = self
            return r
        }
    }()
    
    // Helper properties to access renderer methods regardless of type
    private var mpvRenderer: MPVNativeRenderer? {
        return renderer as? MPVNativeRenderer
    }
    
    private var vlcRenderer: VLCRenderer? {
        return renderer as? VLCRenderer
    }

    private func smartInAppPlayerChoice(requested: Settings.PlayerChoice) -> (choice: Settings.PlayerChoice, reason: String?) {
        guard Settings.shared.smartInAppPlayerChoosingEnabled else {
            return (requested, nil)
        }

        let classification = smartPlayerMediaClassification()
        switch requested {
        case .mpv:
            if let riskReason = classification.riskReason {
                return (.vlc, riskReason)
            }
        case .vlc:
            if classification.riskReason == nil, let safeReason = classification.safeReason {
                return (.mpv, safeReason)
            }
        }

        return (requested, nil)
    }

    private func playerChoiceName(_ choice: Settings.PlayerChoice) -> String {
        switch choice {
        case .mpv:
            return "MPV"
        case .vlc:
            return "VLC"
        }
    }

    private func smartPlayerMediaClassification() -> (riskReason: String?, safeReason: String?) {
        let candidates = [
            initialURL?.absoluteString,
            initialURL?.lastPathComponent,
            playbackLaunchContext?.streamURL,
            playbackLaunchContext?.streamName,
            playbackLaunchContext?.sourceName,
            playbackLaunchContext?.subtitleNames?.joined(separator: " "),
            initialSubtitleNames?.joined(separator: " "),
            smartPlayerMediaInfoText(),
            playerTitleOverride
        ]
        let mediaText = candidates
            .compactMap { $0 }
            .map { ($0.removingPercentEncoding ?? $0).lowercased() }
            .joined(separator: " ")

        guard !mediaText.isEmpty else { return (nil, nil) }
        let normalizedMediaText = mediaText.replacingOccurrences(
            of: #"[^a-z0-9\.\+\-]+"#,
            with: " ",
            options: .regularExpression
        )
        let paddedMediaText = " \(normalizedMediaText) "

        let riskyTokens: [(token: String, reason: String)] = [
            ("10bit", "10-bit video"),
            ("10-bit", "10-bit video"),
            ("10 bit", "10-bit video"),
            ("main10", "10-bit video"),
            ("hi10", "10-bit video"),
            ("hi10p", "10-bit video"),
            ("yuv420p10", "10-bit video"),
            ("yuv422p10", "10-bit video"),
            ("yuv444p10", "10-bit video"),
            ("p010", "10-bit/P010 video"),
            ("p016", "10-bit/P016 video"),
            ("2160p", "4K stream"),
            ("4k", "4K stream"),
            ("uhd", "UHD stream"),
            ("remux", "remux stream"),
            ("bdremux", "remux stream"),
            ("dolbyvision", "Dolby Vision stream"),
            ("dolby vision", "Dolby Vision stream"),
            ("dovi", "Dolby Vision stream"),
            ("dvhe", "Dolby Vision stream"),
            ("hdr10+", "HDR stream"),
            ("hdr10", "HDR stream"),
            ("hdr", "HDR stream"),
            ("av1", "AV1 stream"),
            ("pgs", "bitmap subtitle stream"),
            ("hdmv", "bitmap subtitle stream"),
            ("vobsub", "bitmap subtitle stream"),
            ("dvbsub", "bitmap subtitle stream"),
            ("xsub", "bitmap subtitle stream")
        ]

        if let matched = riskyTokens.first(where: { smartPlayerText(normalizedMediaText, paddedMediaText: paddedMediaText, contains: $0.token) }) {
            if initialURL?.isFileURL == true {
                return ("downloaded/local \(matched.reason)", nil)
            }
            return (matched.reason, nil)
        }

        let explicitlyModernCodecTokens = ["hevc", "h265", "h.265", "x265", "av1", "vp9"]
        let safeCodecTokens = ["h264", "h.264", "x264", "avc"]
        if safeCodecTokens.contains(where: { normalizedMediaText.contains($0) }),
           !explicitlyModernCodecTokens.contains(where: { normalizedMediaText.contains($0) }) {
            return (nil, "H.264/AVC video")
        }

        let conservativeWebSources = ["web-dl", "webdl", "webrip", "web rip", "hdtv"]
        let moderateResolutionTokens = ["1080p", "720p", "480p", "360p"]
        if conservativeWebSources.contains(where: { normalizedMediaText.contains($0) }),
           moderateResolutionTokens.contains(where: { normalizedMediaText.contains($0) }),
           !explicitlyModernCodecTokens.contains(where: { normalizedMediaText.contains($0) }) {
            return (nil, "SDR web stream")
        }

        if isAnimeContent() || isAnimeHint == true {
            return (nil, "anime playback without risky stream markers")
        }

        return (nil, nil)
    }

    private func smartPlayerText(_ normalizedText: String, paddedMediaText: String, contains token: String) -> Bool {
        switch token {
        case "4k", "uhd", "hdr", "av1", "pgs", "xsub":
            return paddedMediaText.contains(" \(token) ")
        default:
            return normalizedText.contains(token)
        }
    }

    private func smartPlayerMediaInfoText() -> String? {
        guard let mediaInfo else { return nil }
        switch mediaInfo {
        case .movie(_, let title, _, let isAnime):
            return "\(title) \(isAnime ? "anime" : "")"
        case .episode(_, let seasonNumber, let episodeNumber, let showTitle, _, let isAnime):
            let title = showTitle ?? ""
            return "\(title) s\(seasonNumber)e\(episodeNumber) \(isAnime ? "anime" : "")"
        }
    }

    private var isVLCPlayer: Bool {
        return vlcRenderer != nil
    }

    private var supportsSharedPlayerControls: Bool {
        isVLCPlayer || mpvRenderer != nil
    }
    
    var mediaInfo: MediaInfo?
    var imdbId: String?
    var playerTitleOverride: String?
    // Optional override: when true, treat content as anime regardless of tracker mapping
    var isAnimeHint: Bool?
    /// Original TMDB season/episode numbers for anime (before AniList restructuring).
    /// Used by TheIntroDB which requires TMDB numbering, not AniList-restructured S/E.
    var originalTMDBSeasonNumber: Int?
    var originalTMDBEpisodeNumber: Int?
    var episodePlaybackContext: EpisodePlaybackContext?

    // MARK: - Skip Segments & Next Episode
    /// Called when the user taps "Next Episode" — passes (seasonNumber, nextEpisodeNumber).
    var onRequestNextEpisode: ((_ seasonNumber: Int, _ nextEpisodeNumber: Int) -> Void)?

    private var skipSegments: [SkipSegment] = []
    private var skipDataFetched = false
    private var autoSkippedSegments: Set<String> = []
    private var currentActiveSkipSegment: SkipSegment?
    private var pendingNextEpisodeRequest: (seasonNumber: Int, episodeNumber: Int)?
    private var didDispatchNextEpisodeRequest = false
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
        btn.titleLabel?.lineBreakMode = .byTruncatingTail
        btn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        btn.titleLabel?.lineBreakMode = .byTruncatingTail
        btn.titleLabel?.numberOfLines = 1
        btn.setContentHuggingPriority(.required, for: .horizontal)
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
    private var lastVLCUIProgressLogBucket = -1
    private var lastVLCUIProgressAnomalyKey: String?
    private var lastVLCUIProgressAnomalyLogTime: CFTimeInterval = 0
    private var lastPiPButtonVisibilityLogKey: String?

    private var isRendererLoading: Bool = false
    private var isClosing = false
    private var isRunning = false  // Track if renderer has been started
    private var isVLCPlaybackStartupInProgress = false
    private var canMutateVLCSubtitleTracks = false
    private var pipController: PiPController?
    private var mpvPiPStartAttemptID = 0
    private var mpvAppExitPiPStartRequested = false
    private var initialURL: URL?
    private var initialPreset: PlayerPreset?
    private var initialHeaders: [String: String]?
    private var initialSubtitles: [String]?
    private var initialSubtitleNames: [String]?
    var playbackLaunchContext: PlaybackLaunchContext?
    var onPlaybackStartupFailure: ((PlaybackFailureReport) -> Void)?
    private var playbackStartupWorkItem: DispatchWorkItem?
    private var playbackDidStart = false
    private var playbackFailureHandled = false
    private var playbackSlowProbeCount = 0
    private var mpvSilentStartupRetryKey: String?
    private var userSelectedAudioTrack = false
    private var userSelectedSubtitleTrack = false
    private var pendingInitialResumeTarget: Double?
    private var pendingInitialResumeDeadline: Date?
    private var vlcProxyFallbackTried = false
    private var mpvTransportBridgeFallbackTried = false
    private var isMPVTransportBridgePlaybackActive = false
    private var lastIgnoredMPVBridgeDurationLogValue: Double = -1
    
    // Debounce timers for menu updates to avoid excessive rebuilds
    private var audioMenuDebounceTimer: Timer?
    private var subtitleMenuDebounceTimer: Timer?
    private var vlcSubtitleOverlayBottomConstraint: NSLayoutConstraint?
    private var subtitleTrailingToProgressConstraint: NSLayoutConstraint?
    private var subtitleTrailingToEpisodeBrowserConstraint: NSLayoutConstraint?
    private var episodeBrowserHostingController: UIHostingController<AnyView>?
    private var isEpisodeBrowserVisible = false
    private var nextEpisodePreview: PlayerEpisodeBrowserItem?
    private var nextEpisodePreviewKey: String?
    private var nextEpisodePreviewTask: Task<Void, Never>?
    private var nextEpisodePreviewUnavailableKeys: Set<String> = []
    private var nextEpisodeArtworkTask: URLSessionDataTask?
    private var nextEpisodeArtworkKey: String?
    private var nextEpisodeArtworkImage: UIImage?
#if !os(tvOS)
    private var volumeTopConstraint: NSLayoutConstraint?
    private var volumeWidthConstraint: NSLayoutConstraint?
    private var volumeHeightConstraint: NSLayoutConstraint?
    private var nextEpisodeButtonMaxWidthConstraint: NSLayoutConstraint?
#endif
    
    private struct SubtitleTrackDescriptor {
        let id: Int
        let name: String
        let codec: String
        let isExternalNativeTrack: Bool
    }

    // MARK: - Renderer Wrapper Methods
    // These methods keep PlayerViewController on the shared PlayerRenderer surface.
    
    private func rendererLoad(url: URL, preset: PlayerPreset, headers: [String: String]?) {
        if vlcRenderer != nil {
            logVLCUI("rendererLoad url=\(url.absoluteString) preset=\(preset.id.rawValue) headers=\(headers?.count ?? 0) pendingSeek=\(secondsText(pendingSeekTime)) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))", type: "Stream")
        } else {
            logMPV("rendererLoad url=\(url.absoluteString) preset=\(preset.id.rawValue) headers=\(headers?.count ?? 0) pendingSeek=\(secondsText(pendingSeekTime)) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))")
        }
        renderer.load(url: url, with: preset, headers: headers)
    }
    
    private func rendererReloadCurrentItem() {
        if let vlc = vlcRenderer {
            logVLCUI("rendererReloadCurrentItem cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))", type: "Stream")
        }
        renderer.reloadCurrentItem()
    }
    
    private func rendererApplyPreset(_ preset: PlayerPreset) {
        renderer.applyPreset(preset)
    }
    
    private func rendererStart() throws {
        if vlcRenderer != nil {
            logVLCUI("rendererStart requested isRunning=\(isRunning)", type: "Stream")
        } else {
            logMPV("rendererStart requested isRunning=\(isRunning)")
        }
        try renderer.start()
        if vlcRenderer != nil {
            logVLCUI("rendererStart completed", type: "Stream")
        } else {
            logMPV("rendererStart completed")
        }
        isRunning = true
    }
    
    private func rendererStop() {
        if let vlc = vlcRenderer {
            logVLCUI("rendererStop requested cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) pipActive=\(vlc.isPictureInPictureActive)", type: "Stream")
        } else {
            logMPV("rendererStop requested cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) pipActive=\(pipController?.isPictureInPictureActive == true)")
        }
        renderer.stop()
        isRunning = false
        isVLCPlaybackStartupInProgress = false
        canMutateVLCSubtitleTracks = false
    }
    
    private func rendererPlay() {
        if vlcRenderer != nil {
            logVLCUI("rendererPlay requested cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)", type: "Stream")
        } else {
            logMPV("rendererPlay requested cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)")
        }
        renderer.play()
    }
    
    private func rendererPausePlayback() {
        if vlcRenderer != nil {
            logVLCUI("rendererPause requested cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)", type: "Stream")
        } else {
            logMPV("rendererPause requested cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)")
        }
        renderer.pausePlayback()
    }
    
    private func rendererTogglePause() {
        renderer.togglePause()
    }

    private func rendererSeek(to seconds: Double) {
        guard seconds.isFinite else {
            Logger.shared.log("PlayerViewController: ignored absolute seek with invalid target=\(secondsText(seconds))", type: "Player")
            return
        }
        if vlcRenderer != nil {
            logVLCUI("rendererSeek(to:) target=\(secondsText(seconds)) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)", type: "Progress")
        } else {
            logMPV("rendererSeek(to:) target=\(secondsText(seconds)) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)")
        }
        renderer.seek(to: seconds)
    }
    
    private func rendererSeek(by seconds: Double) {
        guard seconds.isFinite else {
            Logger.shared.log("PlayerViewController: ignored relative seek with invalid delta=\(secondsText(seconds))", type: "Player")
            return
        }
        if vlcRenderer != nil {
            logVLCUI("rendererSeek(by:) delta=\(secondsText(seconds)) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)", type: "Progress")
        } else {
            logMPV("rendererSeek(by:) delta=\(secondsText(seconds)) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)")
        }
        renderer.seek(by: seconds)
    }
    
    private func rendererSetSpeed(_ speed: Double) {
        if vlcRenderer != nil {
            logVLCUI("rendererSetSpeed \(String(format: "%.2f", speed))", type: "Player")
        } else {
            logMPV("rendererSetSpeed \(String(format: "%.2f", speed))")
        }
        renderer.setSpeed(speed)
    }
    
    private func rendererGetSpeed() -> Double {
        renderer.getSpeed()
    }
    
    private func rendererGetAudioTracksDetailed() -> [(Int, String, String)] {
        renderer.getAudioTracksDetailed()
    }
    
    private func rendererGetAudioTracks() -> [(Int, String)] {
        renderer.getAudioTracks()
    }
    
    private func rendererSetAudioTrack(id: Int) {
        if vlcRenderer != nil {
            logVLCUI("rendererSetAudioTrack id=\(id) userSelected=\(userSelectedAudioTrack)", type: "Player")
        } else {
            logMPV("rendererSetAudioTrack id=\(id) userSelected=\(userSelectedAudioTrack)")
        }
        renderer.setAudioTrack(id: id)
    }
    
    private func rendererGetCurrentAudioTrackId() -> Int {
        renderer.getCurrentAudioTrackId()
    }
    
    private func rendererGetSubtitleTracks() -> [(Int, String)] {
        renderer.getSubtitleTracks()
    }

    private func rendererGetSubtitleTrackDescriptors() -> [SubtitleTrackDescriptor] {
        if let mpvRenderer {
            return mpvRenderer.getSubtitleTracksDetailed().map {
                SubtitleTrackDescriptor(id: $0.0, name: $0.1, codec: $0.2, isExternalNativeTrack: $0.3)
            }
        }

        return rendererGetSubtitleTracks().map {
            SubtitleTrackDescriptor(id: $0.0, name: $0.1, codec: "", isExternalNativeTrack: false)
        }
    }
    
    private func rendererSetSubtitleTrack(id: Int) {
        if vlcRenderer != nil {
            logVLCUI("rendererSetSubtitleTrack id=\(id) userSelected=\(userSelectedSubtitleTrack) selection=\(vlcSubtitleSelection)", type: "Player")
        } else {
            logMPV("rendererSetSubtitleTrack id=\(id) userSelected=\(userSelectedSubtitleTrack) selection=\(vlcSubtitleSelection)")
        }
        lastRequestedEmbeddedSubtitleTrackId = id
        renderer.setSubtitleTrack(id: id)
    }
    
    private func rendererGetCurrentSubtitleTrackId() -> Int {
        renderer.getCurrentSubtitleTrackId()
    }
    
    private func rendererDisableSubtitles() {
        if vlcRenderer != nil {
            logVLCUI("rendererDisableSubtitles currentSelection=\(vlcSubtitleSelection)", type: "Player")
        } else {
            logMPV("rendererDisableSubtitles currentSelection=\(vlcSubtitleSelection)")
        }
        lastRequestedEmbeddedSubtitleTrackId = nil
        renderer.disableSubtitles()
    }
    
    private func rendererRefreshSubtitleOverlay() {
        renderer.refreshSubtitleOverlay()
    }
    
    private func rendererLoadExternalSubtitles(urls: [String], names: [String]? = nil, enforce: Bool = false) {
        if vlcRenderer != nil {
            logVLCUI("rendererLoadExternalSubtitles count=\(urls.count) names=\(names?.count ?? 0) enforce=\(enforce) urls=\(urls.joined(separator: " | "))", type: "Player")
        } else {
            logMPV("rendererLoadExternalSubtitles count=\(urls.count) names=\(names?.count ?? 0) enforce=\(enforce) urls=\(urls.joined(separator: " | "))")
        }
        renderer.loadExternalSubtitles(urls: urls, names: names, enforce: enforce)
    }

    private func rendererDisableSubtitlesIfReady(reason: String) {
        if isVLCPlayer && !canMutateVLCSubtitleTracks {
            logVLCUI("rendererDisableSubtitles skipped reason=\(reason): VLC subtitle tracks not ready", type: "Player")
            return
        }
        rendererDisableSubtitles()
    }

    private func rendererPrepareInitialSeek(to seconds: Double?) {
        if vlcRenderer != nil {
            logVLCUI("rendererPrepareInitialSeek \(secondsText(seconds))", type: "Progress")
        } else {
            logMPV("rendererPrepareInitialSeek \(secondsText(seconds))")
        }
        renderer.prepareInitialSeek(to: seconds)
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
        if vlcRenderer != nil {
            logVLCUI("rendererApplySubtitleStyle visible=\(style.isVisible) font=\(String(format: "%.1f", style.fontSize)) stroke=\(String(format: "%.1f", style.strokeWidth))", type: "Player")
        } else {
            logMPV("rendererApplySubtitleStyle visible=\(style.isVisible) font=\(String(format: "%.1f", style.fontSize)) stroke=\(String(format: "%.1f", style.strokeWidth))")
        }
        renderer.applySubtitleStyle(style)
    }

    private func currentSubtitleStyle(visible: Bool? = nil) -> SubtitleStyle {
        SubtitleStyle(
            foregroundColor: subtitleModel.foregroundColor,
            strokeColor: subtitleModel.strokeColor,
            strokeWidth: subtitleModel.strokeWidth,
            fontSize: subtitleModel.fontSize,
            isVisible: visible ?? subtitleModel.isVisible
        )
    }
    
    private func rendererIsPausedState() -> Bool {
        renderer.isPausedState
    }

    private func rendererIsPictureInPictureAvailable() -> Bool {
        if let vlc = vlcRenderer {
            guard Settings.shared.vlcPiPEnabled else { return false }
            return vlc.isPictureInPictureAvailable
        }
        if let mpv = mpvRenderer, !mpv.canStartSampleBufferPictureInPicture() {
            return false
        }
        return PiPController.isPictureInPictureSupported
    }

    private func rendererIsPictureInPictureActive() -> Bool {
        if let vlc = vlcRenderer {
            return vlc.isPictureInPictureActive
        }
        return pipController?.isPictureInPictureActive == true
    }

    private func rendererUpdatePictureInPicturePlaybackState() {
        if let vlc = vlcRenderer {
            vlc.updatePictureInPicturePlaybackState()
        } else {
            pipController?.updatePlaybackState()
        }
    }

    private func rendererPreparePictureInPictureStart() {
        logPictureInPicture("renderer prepare call hasMPVRenderer=\(mpvRenderer != nil)")
        mpvRenderer?.prepareForPictureInPictureStart()
    }

    private func rendererFinishPictureInPicture() {
        mpvRenderer?.finishPictureInPicture()
    }

    private func rendererPrimePictureInPictureFrames(reason: String) {
        logPictureInPicture("renderer prime call reason=\(reason) hasMPVRenderer=\(mpvRenderer != nil)")
        mpvRenderer?.primePictureInPictureFrames(reason: reason)
    }

    private func rendererActivatePictureInPictureLayer() {
        logPictureInPicture("renderer activate layer call hasMPVRenderer=\(mpvRenderer != nil)")
        mpvRenderer?.activatePictureInPictureLayer()
    }

    private func rendererIsPictureInPicturePrimed() -> Bool {
        mpvRenderer?.isPictureInPicturePrimed() ?? false
    }

    @discardableResult
    private func prepareMPVPictureInPictureRenderer(source: String, activateLayer: Bool) -> Bool {
        let active = pipController?.isPictureInPictureActive ?? false
        let possible = pipController?.isPictureInPicturePossible ?? false
        logPictureInPicture("renderer prepare begin source=\(source) active=\(active) possible=\(possible) activateLayer=\(activateLayer)")
        prepareMPVRenderedSubtitlesForPictureInPicture(source: source)
        rendererPreparePictureInPictureStart()
        rendererPrimePictureInPictureFrames(reason: source)
        if activateLayer {
            rendererActivatePictureInPictureLayer()
        }
        pipController?.updatePlaybackState()
        let primed = rendererIsPictureInPicturePrimed()
        logPictureInPicture("renderer prepare end source=\(source) primed=\(primed) renderer={\(rendererPictureInPictureDebugSnapshot())}")
        return primed
    }

    private func scheduleMPVPictureInPictureRendererWatchdog(source: String, attemptID: Int? = nil, delay: TimeInterval = 0.35) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  let pip = self.pipController,
                  pip.isPictureInPictureActive else { return }
            if let attemptID, attemptID != self.mpvPiPStartAttemptID { return }
            let primed = self.rendererIsPictureInPicturePrimed()
            self.logPictureInPicture("renderer watchdog source=\(source) delay=\(String(format: "%.2f", delay)) primed=\(primed) active=\(pip.isPictureInPictureActive) renderer={\(self.rendererPictureInPictureDebugSnapshot())}")
            if primed {
                self.rendererActivatePictureInPictureLayer()
            } else {
                _ = self.prepareMPVPictureInPictureRenderer(source: "\(source)-watchdog", activateLayer: true)
            }
        }
    }

    private func rendererResumeForegroundRendering(reason: String) {
        mpvRenderer?.resumeForegroundRendering(reason: reason)
    }

    private func rendererPictureInPictureDebugSnapshot() -> String {
        mpvRenderer?.pictureInPictureDebugSnapshot() ?? "mpvRenderer=nil"
    }

    private func subtitlePictureInPictureDebugSnapshot() -> String {
        let rendererTracks = rendererGetSubtitleTracks()
        let selectedTrack = rendererGetCurrentSubtitleTrackId()
        let currentURLState: String
        if currentSubtitleIndex < subtitleURLs.count {
            currentURLState = "currentURL=yes"
        } else {
            currentURLState = "currentURL=no"
        }
        return "visible=\(subtitleModel.isVisible) entries=\(subtitleEntries.count) urls=\(subtitleURLs.count) index=\(currentSubtitleIndex) \(currentURLState) selection=\(vlcSubtitleSelection) rendererTracks=\(rendererTracks.count) rendererSelected=\(selectedTrack)"
    }

    private func prepareMPVRenderedSubtitlesForPictureInPicture(source: String) {
        guard !isVLCPlayer else { return }
        Logger.shared.log("[PlayerVC.PiP] subtitle prepare begin source=\(source) subs={\(subtitlePictureInPictureDebugSnapshot())}", type: "Player")
        if subtitleModel.isVisible {
            let rendererSelectedTrack = rendererGetCurrentSubtitleTrackId()
            if (!subtitleEntries.isEmpty || rendererSelectedTrack < 0), currentSubtitleIndex < subtitleURLs.count {
                fallbackCurrentSubtitleToRenderer(reason: "pip-\(source)")
            } else {
                rendererApplySubtitleStyle(currentSubtitleStyle(visible: true))
            }
        } else {
            rendererApplySubtitleStyle(currentSubtitleStyle(visible: false))
        }
        Logger.shared.log("[PlayerVC.PiP] subtitle prepare end source=\(source) subs={\(subtitlePictureInPictureDebugSnapshot())}", type: "Player")
    }
    
    private var subtitleURLs: [String] = []
    private var subtitleNames: [String] = []
    private var currentSubtitleIndex: Int = 0
    private var subtitleEntries: [SubtitleEntry] = []
    private var vlcExternalSubtitlesLoadedNatively = false
    private var vlcExternalSubtitlePriorityDeadline: Date?
    private var lastKnownVLCCustomSubtitleOverlayEnabled: Bool?
    private var lastSkippedMPVBitmapSubtitleSummary = ""

    private enum VLCSubtitleSelection {
        case none
        case embedded(trackId: Int)
        case external(index: Int)
    }

    private var vlcSubtitleSelection: VLCSubtitleSelection = .none
    private var lastRequestedEmbeddedSubtitleTrackId: Int?
    private var openSubtitlesResults: [StremioSubtitle] = []
    private var openSubtitlesFetchTask: Task<Void, Never>?
    private var openSubtitlesFetchInProgress = false
    private var openSubtitlesSearchAttempted = false
    private var openSubtitlesFallbackAttempted = false
    private var openSubtitlesLoadedURLs: Set<String> = []

    private var isVLCCustomSubtitleOverlayEnabled: Bool {
        return isVLCPlayer && Settings.shared.enableVLCSubtitleEditMenu
    }

    private var isVLCOpenSubtitlesEnabled: Bool {
        return (isVLCPlayer || mpvRenderer != nil) && Settings.shared.vlcOpenSubtitlesEnabled
    }

    private func updatePiPButtonVisibility() {
        let imageName = rendererIsPictureInPictureActive() ? "pip.exit" : "pip.enter"
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        pipButton.setImage(UIImage(systemName: imageName, withConfiguration: cfg), for: .normal)

        let isAvailable = rendererIsPictureInPictureAvailable()
        let shouldShow = isAvailable && (!isVLCPlayer || Settings.shared.vlcPiPEnabled)
        pipButton.isHidden = !shouldShow
        pipButton.isEnabled = shouldShow
        if isVLCPlayer {
            let key = "available=\(isAvailable) show=\(shouldShow) hidden=\(pipButton.isHidden) active=\(rendererIsPictureInPictureActive()) enabled=\(Settings.shared.vlcPiPEnabled) image=\(imageName)"
            if key != lastPiPButtonVisibilityLogKey {
                lastPiPButtonVisibilityLogKey = key
                logVLCUI("updatePiPButtonVisibility \(key)", type: "Player")
            }
        } else {
            let key = "available=\(isAvailable) show=\(shouldShow) hidden=\(pipButton.isHidden) active=\(rendererIsPictureInPictureActive()) image=\(imageName)"
            if key != lastPiPButtonVisibilityLogKey {
                lastPiPButtonVisibilityLogKey = key
                logMPV("updatePiPButtonVisibility \(key)")
            }
        }
    }

    private func updatePlayerTitle() {
        let title = playerDisplayTitle()
        playerTitleLabel.text = title
        playerTitleLabel.isHidden = title.isEmpty
    }

    private func playerDisplayTitle() -> String {
        if let override = trimmedTitle(playerTitleOverride) {
            return override
        }

        guard let info = mediaInfo else { return "" }
        switch info {
        case .movie(_, let title, _, _):
            return title
        case .episode(_, let seasonNumber, let episodeNumber, let showTitle, _, let isAnime):
            let prefix = trimmedTitle(showTitle)
            if isAnime {
                let episodeCode = "E\(episodeNumber)"
                if let prefix, !prefix.isEmpty {
                    return "\(prefix) \(episodeCode)"
                }
                return episodeCode
            }
            let episodeCode = String(format: "S%02dE%02d", seasonNumber, episodeNumber)
            if let prefix, !prefix.isEmpty {
                return "\(prefix) - \(episodeCode)"
            }
            return episodeCode
        }
    }

    private func trimmedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private var shouldShowTopErrorBanner: Bool {
        return !supportsSharedPlayerControls
    }

    private func logMPV(_ message: String) {
        Logger.shared.log("[MPV \(playerLogId)] " + message, type: "MPV")
    }

    private func logVLCUI(_ message: String, type: String = "Player") {
        guard isVLCPlayer else { return }
        Logger.shared.log("[PlayerVC.VLC \(playerLogId)] \(message)", type: type)
    }

    private func logSharedPlayerControl(_ message: String) {
        if isVLCPlayer {
            logVLCUI(message, type: "Player")
        } else {
            logMPV(message)
        }
    }

    private func logPictureInPicture(_ message: String) {
        if isVLCPlayer {
            Logger.shared.log("[PlayerVC.PiP] \(message)", type: "Player")
        } else {
            logMPV("[PlayerVC.PiP] \(message)")
        }
    }

    private func logVLCUIViewSnapshot(_ event: String) {
        guard isVLCPlayer else { return }
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        let viewBounds = view.bounds
        let videoBounds = videoContainer.bounds
        let windowBounds = view.window?.bounds ?? .zero
        let pipActive = vlcRenderer?.isPictureInPictureActive ?? false
        let pipAvailable = vlcRenderer?.isPictureInPictureAvailable ?? false
        let displayFrame = displayLayer.frame
        let displayBackground = displayLayer.backgroundColor.map { UIColor(cgColor: $0).description } ?? "nil"
        let vlcView = vlcRenderingView
        let vlcIndex = vlcView.flatMap { target in videoContainer.subviews.firstIndex { $0 === target } } ?? -1
        let subviewStack = videoContainer.subviews.enumerated().map { index, subview -> String in
            if let vlcView = vlcView, subview === vlcView { return "\(index):vlc" }
            if subview === controlsOverlayView { return "\(index):controls" }
            if subview === dimmingView { return "\(index):dimming" }
            if subview === tapOverlayView { return "\(index):tap" }
            if subview === loadingIndicator { return "\(index):loading" }
            return "\(index):\(type(of: subview))"
        }.joined(separator: "|")
        logVLCUI("\(event) ui app=\(appState) window=\(view.window != nil) presenting=\(presentingViewController != nil) closing=\(isClosing) running=\(isRunning) loading=\(isRendererLoading) controls=\(controlsVisible) paused=\(rendererIsPausedState()) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) pipEnabled=\(Settings.shared.vlcPiPEnabled) pipAvailable=\(pipAvailable) pipActive=\(pipActive) view=\(String(format: "%.0fx%.0f", viewBounds.width, viewBounds.height)) video=\(String(format: "%.0fx%.0f", videoBounds.width, videoBounds.height)) windowBounds=\(String(format: "%.0fx%.0f", windowBounds.width, windowBounds.height)) vlcIndex=\(vlcIndex) vlcHidden=\(vlcView?.isHidden ?? true) vlcAlpha=\(String(format: "%.2f", vlcView?.alpha ?? 0)) displayAttached=\(displayLayer.superlayer != nil) displayHidden=\(displayLayer.isHidden) displayOpacity=\(String(format: "%.2f", displayLayer.opacity)) displayFrame=\(String(format: "%.0fx%.0f", displayFrame.width, displayFrame.height)) displayBg=\(displayBackground) stack=\(subviewStack)", type: "Player")
    }

    private func scheduleVLCUIViewSnapshots(_ event: String, delays: [TimeInterval] = [0.25, 1.0]) {
        guard isVLCPlayer else { return }
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.logVLCUIViewSnapshot("\(event) +\(String(format: "%.2f", delay))s")
            }
        }
    }

    private func secondsText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "nil" }
        return String(format: "%.2f", value)
    }
    
    class SubtitleModel: ObservableObject {
        @Published var currentAttributedText: NSAttributedString = NSAttributedString()
        
        private var isLoading: Bool = true
        private var shouldPersistChanges: Bool = true
        
        @Published var isVisible: Bool = false {
            didSet {
                if !isLoading && shouldPersistChanges { saveSubtitleSettings() }
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

        func setVisible(_ visible: Bool, persist: Bool = true) {
            let oldShouldPersistChanges = shouldPersistChanges
            shouldPersistChanges = persist
            isVisible = visible
            shouldPersistChanges = oldShouldPersistChanges
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
            if let legacyValue = UserDefaults.standard.object(forKey: legacyTwoFingerSettingKey) as? Bool {
                UserDefaults.standard.set(legacyValue, forKey: twoFingerSettingKey)
                return legacyValue
            }
            UserDefaults.standard.set(true, forKey: twoFingerSettingKey)
            return true
        }
        return UserDefaults.standard.bool(forKey: twoFingerSettingKey)
    }
    private var isDoubleTapSeekEnabled: Bool {
        if UserDefaults.standard.object(forKey: doubleTapSeekEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: doubleTapSeekEnabledKey)
    }
    private var playerSeekSeconds: Double {
        let savedSeconds = UserDefaults.standard.double(forKey: playerSeekSecondsKey)
        let seconds = savedSeconds > 0 ? savedSeconds : 10.0
        return min(max(seconds, 5.0), 60.0)
    }
    private var defaultPlaybackSpeed: Double {
        let savedSpeed = UserDefaults.standard.double(forKey: "defaultPlaybackSpeed")
        let speed = savedSpeed > 0 ? savedSpeed : 1.0
        return min(max(speed, 0.25), 3.0)
    }
    private var isBrightnessControlEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "vlcBrightnessGestureEnabled")
    }
    private var isVolumeControlEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "vlcVolumeGestureEnabled")
    }
    private var isPerformanceOverlayEnabled: Bool {
        return false
    }
    
    private var originalSpeed: Double = 1.0
    private var holdGesture: UILongPressGestureRecognizer?
    
    private var controlsHideWorkItem: DispatchWorkItem?
    private var controlsVisible: Bool = true
    private var pendingSeekTime: Double?
    private var defaultPlaybackSpeedApplied = false
    private var performanceOverlayTimer: Timer?
    private var lastCPUProcessTime: TimeInterval?
    private var lastCPUWallTime: CFTimeInterval?
    private var lastCPUUsagePercent: Double?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        logMPV("viewDidLoad initialURL=\(initialURL?.absoluteString ?? "nil") preset=\(initialPreset?.id.rawValue ?? "nil") mediaInfo=\(String(describing: mediaInfo))")
        logVLCUI("viewDidLoad initialURL=\(initialURL?.absoluteString ?? "nil") preset=\(initialPreset?.id.rawValue ?? "nil") mediaInfo=\(String(describing: mediaInfo))", type: "Stream")
        
#if !os(tvOS)
        modalPresentationCapturesStatusBarAppearance = true
#endif
        setupLayout()
        updatePlayerTitle()
        
        setupActions()
        setupHoldGesture()
        setupDoubleTapSkipGestures()
    #if !os(tvOS)
        setupBrightnessControls()
        setupVolumeControls()
    #endif
        configureSeekButtons()

        if usesOverlayPlayerMenus {
            subtitleButton.showsMenuAsPrimaryAction = false
            speedButton.showsMenuAsPrimaryAction = false
            audioButton.showsMenuAsPrimaryAction = false
            updateSubtitleTracksMenu()
        } else {
            // Ensure subtitle control appears with other buttons immediately on VLC,
            // even before track discovery finishes.
            subtitleButton.showsMenuAsPrimaryAction = true
            speedButton.showsMenuAsPrimaryAction = true
            audioButton.showsMenuAsPrimaryAction = true
            updateSubtitleTracksMenu()
            updateEpisodeBrowserButtonVisibility()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(handleLoggerNotification(_:)), name: NSNotification.Name("LoggerNotification"), object: nil)
        if isVLCPlayer || mpvRenderer != nil {
            lastKnownVLCCustomSubtitleOverlayEnabled = isVLCCustomSubtitleOverlayEnabled
            NotificationCenter.default.addObserver(self, selector: #selector(handleUserDefaultsDidChange), name: UserDefaults.didChangeNotification, object: nil)
        }
        
        do {
            try rendererStart()
            logSharedPlayerControl("renderer.start succeeded")
        } catch {
            let rendererName = vlcRenderer != nil ? "VLC" : "MPV"
            Logger.shared.log("Failed to start \(rendererName) renderer: \(error)", type: "Error")
        }

        pipController = PiPController(sampleBufferDisplayLayer: displayLayer)
        pipController?.delegate = self
        updatePiPButtonVisibility()
        
        showControlsTemporarily()
        
        if let url = initialURL, let preset = initialPreset {
            logSharedPlayerControl("loading initial url=\(url.absoluteString) preset=\(preset.id.rawValue)")
            load(url: url, preset: preset, headers: initialHeaders)
        }
        
        updateProgressHostingController()
        updateSpeedMenu()
        updatePerformanceOverlayVisibility()
        
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate), name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidEnterBackground), name: UIScene.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneWillEnterForeground), name: UIScene.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidActivate), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appScenePhaseDidChange(_:)), name: .lunaScenePhaseDidChange, object: nil)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.bringSubviewToFront(errorBanner)
        logVLCUIViewSnapshot("viewDidAppear")
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
        if supportsSharedPlayerControls {
            refreshGestureControlLevels(animated: false)
        }
        if isVLCPlayer {
            logVLCUIViewSnapshot("viewWillAppear")
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setNeedsStatusBarAppearanceUpdate()
        logVLCUIViewSnapshot("viewWillDisappear")
    }
#endif
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
#if !os(tvOS)
        updateGestureControlLayoutForCurrentSize()
#endif
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        if isVLCPlayer {
            if displayLayer.superlayer != nil || !displayLayer.isHidden || displayLayer.opacity != 0 {
                displayLayer.removeFromSuperlayer()
                displayLayer.isHidden = true
                displayLayer.opacity = 0.0
                logVLCUI("viewDidLayout removed sample-buffer displayLayer from VLC stack", type: "Player")
            }
        } else {
            displayLayer.frame = videoContainer.bounds
        }
        
        if let gradientLayer = controlsOverlayView.layer.sublayers?.first(where: { $0.name == "gradientLayer" }) {
            gradientLayer.frame = controlsOverlayView.bounds
        }
        
        CATransaction.commit()
    }

#if !os(tvOS)
    private func updateGestureControlLayoutForCurrentSize() {
        let isPortrait = view.bounds.height > view.bounds.width
        volumeWidthConstraint?.constant = isPortrait ? 154 : 220
        volumeHeightConstraint?.constant = isPortrait ? 32 : 36
        volumeTopConstraint?.constant = isPortrait ? 62 : 12

        let availableWidth = max(videoContainer.bounds.width, view.bounds.width)
        let compactLimit = max(240, availableWidth - 32)
        let landscapeLimit = min(480, max(300, availableWidth * 0.52))
        nextEpisodeButtonMaxWidthConstraint?.constant = isPortrait ? min(360, compactLimit) : landscapeLimit
    }
#endif
    
    deinit {
        isClosing = true
        audioMenuDebounceTimer?.invalidate()
        subtitleMenuDebounceTimer?.invalidate()
        performanceOverlayTimer?.invalidate()
        playbackStartupWorkItem?.cancel()
#if !os(tvOS)
        outputVolumeObservation?.invalidate()
        outputVolumeObservation = nil
#endif
        if let mpv = mpvRenderer {
            mpv.delegate = nil
        } else if let vlc = vlcRenderer {
            vlc.delegate = nil
        }
        logSharedPlayerControl("deinit; stopping renderer and restoring state")
        pipController?.delegate = nil
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        if vlcRenderer?.isPictureInPictureActive == true {
            vlcRenderer?.stopPictureInPicture()
        }
        openSubtitlesFetchTask?.cancel()
        nextEpisodePreviewTask?.cancel()
        nextEpisodeArtworkTask?.cancel()
        dismissEpisodeBrowser(animated: false)
        pipController?.invalidate()
        rendererStop()
        
        displayLayer.removeFromSuperlayer()
        
        NotificationCenter.default.removeObserver(self)
    }
    
    convenience init(url: URL, preset: PlayerPreset, headers: [String: String]? = nil, subtitles: [String]? = nil, subtitleNames: [String]? = nil, mediaInfo: MediaInfo? = nil, imdbId: String? = nil) {
        self.init(nibName: nil, bundle: nil)
        self.initialURL = url
        self.initialPreset = preset
        self.initialHeaders = headers
        self.initialSubtitles = subtitles
        self.initialSubtitleNames = subtitleNames
        self.mediaInfo = mediaInfo
        self.imdbId = imdbId
        Logger.shared.log("[PlayerViewController.init] URL=\(url.absoluteString) preset=\(preset.id.rawValue) headers=\(headers?.count ?? 0) subtitles=\(subtitles?.count ?? 0) mediaInfo=\(mediaInfo != nil)", type: "Stream")
    }
    
    func load(url: URL, preset: PlayerPreset, headers: [String: String]? = nil) {
        logMPV("load url=\(url.absoluteString) preset=\(preset.id.rawValue) headers=\(headers?.count ?? 0)")
        initialURL = url
        initialHeaders = headers
        openSubtitlesResults.removeAll()
        openSubtitlesFetchTask?.cancel()
        openSubtitlesFetchTask = nil
        openSubtitlesFetchInProgress = false
        openSubtitlesSearchAttempted = false
        openSubtitlesFallbackAttempted = false
        openSubtitlesLoadedURLs.removeAll()
        lastSkippedMPVBitmapSubtitleSummary = ""
        vlcExternalSubtitlePriorityDeadline = nil
        defaultPlaybackSpeedApplied = false
        cachedPosition = 0
        cachedDuration = 0
        progressModel.position = 0
        progressModel.duration = 1
        progressModel.durationIsKnown = false
        if isVLCPlayer {
            isVLCPlaybackStartupInProgress = true
            canMutateVLCSubtitleTracks = false
        }
        updatePiPButtonVisibility()
        updatePlayerTitle()
        updateEpisodeBrowserButtonVisibility()
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
        logVLCUI("load prepared mediaInfo=\(mediaInfoLabel) pendingSeek=\(secondsText(pendingSeekTime)) subtitles=\(subtitleURLs.count) openSubsEnabled=\(Settings.shared.vlcOpenSubtitlesEnabled) fallback=\(Settings.shared.vlcOpenSubtitlesAutoFallbackEnabled)", type: "Stream")
        
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
        lastRequestedEmbeddedSubtitleTrackId = nil
        if !isLocalProxyURL(url) {
            vlcProxyFallbackTried = false
            mpvTransportBridgeFallbackTried = false
            isMPVTransportBridgePlaybackActive = false
        }
        lastIgnoredMPVBridgeDurationLogValue = -1
        pendingSeekTime = nil
        pendingInitialResumeTarget = nil
        pendingInitialResumeDeadline = nil
        if let info = mediaInfo {
            prepareSeekToLastPosition(for: info)
        }
        logVLCUI("load resume prepared pendingSeek=\(secondsText(pendingSeekTime)) progressCached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) launchContext=\(String(describing: playbackLaunchContext))", type: "Progress")
        rendererPrepareInitialSeek(to: pendingSeekTime)
        let playbackRequest = preparePlayerHeaderProxyIfNeeded(originalURL: url, headers: headers)
        if !isVLCPlayer {
            preparePlaybackStartupMonitoring(for: playbackRequest.url, headers: playbackRequest.headers ?? headers ?? [:])
        }
        rendererLoad(url: playbackRequest.url, preset: preset, headers: playbackRequest.headers)
        applyDefaultPlaybackSpeed()
        
        if let subs = initialSubtitles, !subs.isEmpty {
            loadSubtitles(subs, names: initialSubtitleNames)
        }
        prefetchOpenSubtitlesIfEnabled(reason: "load")
    }

    private func preparePlaybackStartupMonitoring(for url: URL, headers: [String: String]) {
        playbackStartupWorkItem?.cancel()
        playbackDidStart = false
        playbackFailureHandled = false
        playbackSlowProbeCount = 0
        guard !url.isFileURL else {
            Logger.shared.log("[PlayerVC.PlaybackStart] startup monitor skipped for local file", type: "Stream")
            return
        }
        Logger.shared.log("[PlayerVC.PlaybackStart] startup monitor armed renderer=\(isVLCPlayer ? "VLC" : "MPV") url=\(url.absoluteString) headerKeys=[\(headers.keys.sorted().joined(separator: ","))]", type: isVLCPlayer ? "Stream" : "MPV")
        schedulePlaybackStartupCheck(url: url, headers: headers, delay: 18)
    }

    private func schedulePlaybackStartupCheck(url: URL, headers: [String: String], delay: TimeInterval) {
        playbackStartupWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.playbackDidStart,
                  !self.playbackFailureHandled,
                  !self.isClosing else {
                return
            }
            self.runPlaybackStartupProbe(url: url, headers: headers)
        }
        playbackStartupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func markPlaybackStarted(reason: String) {
        guard playbackStartupWorkItem != nil else { return }
        guard !playbackDidStart else { return }
        playbackDidStart = true
        playbackStartupWorkItem?.cancel()
        if let context = playbackLaunchContext {
            SourceHealthStore.shared.recordPlaybackSuccess(sourceId: context.sourceId, sourceName: context.sourceName)
            Logger.shared.log("[PlayerVC.PlaybackStart] \(context.sourceName) started via \(reason)", type: "Stream")
        }
    }

    private func runPlaybackStartupProbe(url: URL, headers: [String: String]) {
        Task { [weak self] in
            let result = await SourceHealthMonitor.shared.probeStream(url: url, headers: headers)
            await MainActor.run {
                guard let self,
                      !self.playbackDidStart,
                      !self.playbackFailureHandled,
                      !self.isClosing else {
                    return
                }

                switch result {
                case .reachable:
                    self.playbackSlowProbeCount += 1
                    self.showErrorBanner("Stream is reachable but still starting. Waiting a little longer...")
                    self.schedulePlaybackStartupCheck(url: url, headers: headers, delay: 20)
                case .slowOrIndeterminate(let reason):
                    self.playbackSlowProbeCount += 1
                    if self.playbackSlowProbeCount >= 3 {
                        self.handlePlaybackStartupFailure("Playback is taking too long: \(reason)", isSourceFailure: false)
                    } else {
                        self.showErrorBanner("Connection looks slow. Still waiting for playback...")
                        self.schedulePlaybackStartupCheck(url: url, headers: headers, delay: 20)
                    }
                case .networkUnavailable:
                    self.handlePlaybackStartupFailure("No internet connection is available.", isSourceFailure: false)
                case .sourceFailed(let reason):
                    self.handlePlaybackStartupFailure(reason, isSourceFailure: true)
                }
            }
        }
    }

    private func handlePlaybackStartupFailure(_ message: String, isSourceFailure: Bool) {
        guard !playbackDidStart, !playbackFailureHandled else { return }
        if !isVLCPlayer, attemptMPVTransportBridgeFallbackIfNeeded(after: message) {
            return
        }
        if !isVLCPlayer,
           playbackLaunchContext?.autoMode != true,
           shouldSilentlyRetryMPVStartup(after: message) {
            let retryKey = playbackLaunchContext?.streamURL ?? initialURL?.absoluteString ?? message
            if mpvSilentStartupRetryKey != retryKey {
                mpvSilentStartupRetryKey = retryKey
                playbackStartupWorkItem?.cancel()
                Logger.shared.log("[PlayerVC.PlaybackStart] MPV silently retrying startup after first failure: \(message)", type: "MPV")
                retryPlaybackAfterFailure()
                return
            }
        }
        playbackFailureHandled = true
        playbackStartupWorkItem?.cancel()

        guard let context = playbackLaunchContext else {
            Logger.shared.log("[PlayerVC.PlaybackStart] startup failed without launch context: \(message)", type: "MPV")
            if isVLCPlayer {
                showErrorBanner(message)
            }
            return
        }

        SourceHealthStore.shared.recordPlaybackFailure(
            sourceId: context.sourceId,
            sourceName: context.sourceName,
            reason: message,
            isSourceFailure: isSourceFailure
        )

        let report = PlaybackFailureReport(context: context, message: message, isSourceFailure: isSourceFailure)
        if context.autoMode {
            if isVLCPlayer {
                showErrorBanner("\(context.sourceName) failed. Retrying another stream...")
            } else {
                Logger.shared.log("[PlayerVC.PlaybackStart] MPV auto mode handing failure back without top banner", type: "MPV")
            }
            dismissAfterPlaybackFailure(report)
        } else {
            showManualPlaybackFailureAlert(report)
        }
    }

    private func shouldSilentlyRetryMPVStartup(after message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("stayed idle")
            || lower.contains("taking too long")
            || lower.contains("failed to open")
            || lower.contains("unexpected tls packet")
            || lower.contains("tls")
    }

    private func showManualPlaybackFailureAlert(_ report: PlaybackFailureReport) {
        let alert = UIAlertController(
            title: "Playback Failed",
            message: "\(report.context.sourceName) could not start playback. \(report.message)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.retryPlaybackAfterFailure()
        })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in
            self?.closeTapped()
        })
        present(alert, animated: true)
    }

    private func retryPlaybackAfterFailure() {
        guard let context = playbackLaunchContext,
              let preset = initialPreset,
              let url = URL(string: context.streamURL) else {
            rendererReloadCurrentItem()
            return
        }

        playbackDidStart = false
        playbackFailureHandled = false
        playbackSlowProbeCount = 0
        vlcProxyFallbackTried = false
        initialSubtitles = context.subtitles.isEmpty ? nil : context.subtitles
        initialSubtitleNames = context.subtitleNames
        load(url: url, preset: preset, headers: context.headers)
    }

    private func dismissAfterPlaybackFailure(_ report: PlaybackFailureReport) {
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.rendererStop()
            self.onPlaybackStartupFailure?(report)
        }

        if presentingViewController != nil {
            dismiss(animated: true, completion: finish)
        } else {
            finish()
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
                pendingInitialResumeTarget = lastPlayedTime
                pendingInitialResumeDeadline = Date().addingTimeInterval(20)
                Logger.shared.log("Prepared resume seek to \(Int(lastPlayedTime))s", type: "Progress")
            }
        }
    }
    
    private func setupLayout() {
        view.addSubview(videoContainer)
        
        // Keep the sample-buffer layer attached for MPV playback; VLC renders through its own drawable.
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
        if isVLCPlayer {
            displayLayer.removeFromSuperlayer()
            displayLayer.isHidden = true
            displayLayer.opacity = 0.0
            logVLCUI("setupLayout skipped sample-buffer displayLayer for VLC renderer", type: "Player")
        } else {
            displayLayer.isHidden = true
            displayLayer.opacity = 0.0
            displayLayer.zPosition = -1
            videoContainer.layer.addSublayer(displayLayer)
        }
        
        // Add native rendering view FIRST (before all UI elements) so it renders behind controls.
        if let mpv = mpvRenderer {
            let mpvView = mpv.getRenderingView()
            mpvRenderingView = mpvView
            videoContainer.addSubview(mpvView)
            mpvView.translatesAutoresizingMaskIntoConstraints = false
            mpvView.layer.zPosition = 0
            mpvView.isUserInteractionEnabled = false
            videoContainer.isUserInteractionEnabled = true
            NSLayoutConstraint.activate([
                mpvView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
                mpvView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),
                mpvView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
                mpvView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor)
            ])
        }

        // Add VLC rendering view FIRST (before all UI elements) so it renders behind controls
        if let vlc = vlcRenderer {
            let vlcView = vlc.getRenderingView()
            vlcRenderingView = vlcView
            videoContainer.addSubview(vlcView)
            vlcView.translatesAutoresizingMaskIntoConstraints = false
            vlcView.layer.zPosition = 0
            // Ensure container remains interactive for gesture recognition
            videoContainer.isUserInteractionEnabled = true
            NSLayoutConstraint.activate([
                vlcView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
                vlcView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),
                vlcView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
                vlcView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor)
            ])
        }

        videoContainer.addSubview(tapOverlayView)
        NSLayoutConstraint.activate([
            tapOverlayView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
            tapOverlayView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
            tapOverlayView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
            tapOverlayView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor)
        ])
        
        videoContainer.addSubview(dimmingView)
        videoContainer.addSubview(controlsOverlayView)
        videoContainer.addSubview(loadingIndicator)
        view.addSubview(errorBanner)
        videoContainer.addSubview(centerPlayPauseButton)
        videoContainer.addSubview(progressContainer)
        videoContainer.addSubview(overlayMenuDismissView)
        videoContainer.addSubview(overlayMenuPanelView)
        overlayMenuPanelView.addSubview(overlayMenuTitleLabel)
        overlayMenuPanelView.addSubview(overlayMenuScrollView)
        overlayMenuScrollView.addSubview(overlayMenuStackView)
        videoContainer.addSubview(closeButton)
        videoContainer.addSubview(pipButton)
        videoContainer.addSubview(playerTitleLabel)
        videoContainer.addSubview(skipBackwardButton)
        videoContainer.addSubview(skipForwardButton)
        videoContainer.addSubview(speedIndicatorLabel)
        videoContainer.addSubview(performanceOverlayLabel)
        videoContainer.addSubview(vlcSubtitleOverlayLabel)
        videoContainer.addSubview(subtitleButton)
        if supportsSharedPlayerControls {
            videoContainer.addSubview(episodeBrowserButton)
            videoContainer.addSubview(speedButton)
            videoContainer.addSubview(audioButton)
        }
    #if !os(tvOS)
        videoContainer.addSubview(brightnessContainer)
        brightnessContainer.contentView.addSubview(brightnessSlider)
        brightnessContainer.contentView.addSubview(brightnessIcon)
        videoContainer.addSubview(volumeContainer)
        volumeContainer.contentView.addSubview(volumeSlider)
        volumeContainer.contentView.addSubview(volumeIcon)
#if canImport(MediaPlayer)
        view.addSubview(systemVolumeView)
#endif
        if supportsSharedPlayerControls {
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

            overlayMenuDismissView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
            overlayMenuDismissView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
            overlayMenuDismissView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
            overlayMenuDismissView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),

            overlayMenuPanelView.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),
            overlayMenuPanelView.bottomAnchor.constraint(equalTo: progressContainer.topAnchor, constant: -48),
            overlayMenuPanelView.widthAnchor.constraint(equalToConstant: 280),
            overlayMenuPanelView.heightAnchor.constraint(equalToConstant: 240),

            overlayMenuTitleLabel.topAnchor.constraint(equalTo: overlayMenuPanelView.topAnchor, constant: 10),
            overlayMenuTitleLabel.leadingAnchor.constraint(equalTo: overlayMenuPanelView.leadingAnchor, constant: 12),
            overlayMenuTitleLabel.trailingAnchor.constraint(equalTo: overlayMenuPanelView.trailingAnchor, constant: -12),

            overlayMenuScrollView.topAnchor.constraint(equalTo: overlayMenuTitleLabel.bottomAnchor, constant: 8),
            overlayMenuScrollView.leadingAnchor.constraint(equalTo: overlayMenuPanelView.leadingAnchor, constant: 8),
            overlayMenuScrollView.trailingAnchor.constraint(equalTo: overlayMenuPanelView.trailingAnchor, constant: -8),
            overlayMenuScrollView.bottomAnchor.constraint(equalTo: overlayMenuPanelView.bottomAnchor, constant: -8),

            overlayMenuStackView.topAnchor.constraint(equalTo: overlayMenuScrollView.contentLayoutGuide.topAnchor),
            overlayMenuStackView.leadingAnchor.constraint(equalTo: overlayMenuScrollView.contentLayoutGuide.leadingAnchor),
            overlayMenuStackView.trailingAnchor.constraint(equalTo: overlayMenuScrollView.contentLayoutGuide.trailingAnchor),
            overlayMenuStackView.bottomAnchor.constraint(equalTo: overlayMenuScrollView.contentLayoutGuide.bottomAnchor),
            overlayMenuStackView.widthAnchor.constraint(equalTo: overlayMenuScrollView.frameLayoutGuide.widthAnchor)
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

            playerTitleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            playerTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pipButton.trailingAnchor, constant: 12),
            playerTitleLabel.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            playerTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            
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

            performanceOverlayLabel.topAnchor.constraint(equalTo: videoContainer.safeAreaLayoutGuide.topAnchor, constant: 64),
            performanceOverlayLabel.trailingAnchor.constraint(equalTo: videoContainer.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            performanceOverlayLabel.widthAnchor.constraint(lessThanOrEqualTo: videoContainer.safeAreaLayoutGuide.widthAnchor, multiplier: 0.72),
            speedIndicatorLabel.widthAnchor.constraint(equalToConstant: 100),
            speedIndicatorLabel.heightAnchor.constraint(equalToConstant: 40),

            vlcSubtitleOverlayLabel.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor, constant: 12),
            vlcSubtitleOverlayLabel.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor, constant: -12),
            
            subtitleButton.bottomAnchor.constraint(equalTo: progressContainer.topAnchor, constant: -8),
            subtitleButton.widthAnchor.constraint(equalToConstant: 32),
            subtitleButton.heightAnchor.constraint(equalToConstant: 32)
        ])

        subtitleTrailingToProgressConstraint = subtitleButton.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor, constant: 0)
        subtitleTrailingToProgressConstraint?.isActive = true

        vlcSubtitleOverlayBottomConstraint = vlcSubtitleOverlayLabel.bottomAnchor.constraint(equalTo: progressContainer.topAnchor, constant: vlcSubtitleOverlayBottomConstant)
        vlcSubtitleOverlayBottomConstraint?.isActive = true
        if supportsSharedPlayerControls {
            subtitleTrailingToEpisodeBrowserConstraint = subtitleButton.trailingAnchor.constraint(equalTo: episodeBrowserButton.leadingAnchor, constant: -8)
            NSLayoutConstraint.activate([
                episodeBrowserButton.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor, constant: 0),
                episodeBrowserButton.centerYAnchor.constraint(equalTo: subtitleButton.centerYAnchor),
                episodeBrowserButton.widthAnchor.constraint(equalToConstant: 32),
                episodeBrowserButton.heightAnchor.constraint(equalToConstant: 32),

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
        volumeTopConstraint = volumeContainer.topAnchor.constraint(equalTo: videoContainer.safeAreaLayoutGuide.topAnchor, constant: 12)
        volumeWidthConstraint = volumeContainer.widthAnchor.constraint(equalToConstant: 220)
        volumeHeightConstraint = volumeContainer.heightAnchor.constraint(equalToConstant: 36)
        NSLayoutConstraint.activate([
            brightnessContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            brightnessContainer.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor, constant: -12),
            brightnessContainer.widthAnchor.constraint(equalToConstant: 44),
            brightnessContainer.heightAnchor.constraint(equalToConstant: 154),

            brightnessSlider.centerXAnchor.constraint(equalTo: brightnessContainer.contentView.centerXAnchor),
            brightnessSlider.centerYAnchor.constraint(equalTo: brightnessContainer.contentView.centerYAnchor),
            brightnessSlider.widthAnchor.constraint(equalTo: brightnessContainer.contentView.heightAnchor, multiplier: 0.72),
            brightnessSlider.heightAnchor.constraint(equalToConstant: 28),

            brightnessIcon.centerXAnchor.constraint(equalTo: brightnessContainer.contentView.centerXAnchor),
            brightnessIcon.topAnchor.constraint(equalTo: brightnessContainer.contentView.topAnchor, constant: 6),
            brightnessIcon.heightAnchor.constraint(equalToConstant: 18),
            brightnessIcon.widthAnchor.constraint(equalToConstant: 18),

            volumeContainer.leadingAnchor.constraint(greaterThanOrEqualTo: videoContainer.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            volumeContainer.trailingAnchor.constraint(equalTo: videoContainer.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            volumeTopConstraint!,
            volumeWidthConstraint!,
            volumeHeightConstraint!,

            volumeIcon.leadingAnchor.constraint(equalTo: volumeContainer.contentView.leadingAnchor, constant: 12),
            volumeIcon.centerYAnchor.constraint(equalTo: volumeContainer.contentView.centerYAnchor),
            volumeIcon.heightAnchor.constraint(equalToConstant: 20),
            volumeIcon.widthAnchor.constraint(equalToConstant: 22),

            volumeSlider.leadingAnchor.constraint(equalTo: volumeIcon.trailingAnchor, constant: 8),
            volumeSlider.trailingAnchor.constraint(equalTo: volumeContainer.contentView.trailingAnchor, constant: -12),
            volumeSlider.centerYAnchor.constraint(equalTo: volumeContainer.contentView.centerYAnchor)
        ])
#if canImport(MediaPlayer)
        NSLayoutConstraint.activate([
            systemVolumeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            systemVolumeView.topAnchor.constraint(equalTo: view.topAnchor),
            systemVolumeView.widthAnchor.constraint(equalToConstant: 1),
            systemVolumeView.heightAnchor.constraint(equalToConstant: 1)
        ])
#endif
        if supportsSharedPlayerControls {
            let nextEpisodeButtonMaxWidth = nextEpisodeButton.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
            nextEpisodeButtonMaxWidth.priority = .required
            nextEpisodeButtonMaxWidthConstraint = nextEpisodeButtonMaxWidth

            NSLayoutConstraint.activate([
                skipButton.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),
                skipButton.bottomAnchor.constraint(equalTo: subtitleButton.topAnchor, constant: -12),

                nextEpisodeButton.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),
                nextEpisodeButton.leadingAnchor.constraint(greaterThanOrEqualTo: videoContainer.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                nextEpisodeButton.bottomAnchor.constraint(equalTo: skipButton.topAnchor, constant: -10),
                nextEpisodeButtonMaxWidth,

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
            
            videoContainer.bringSubviewToFront(tapOverlayView)
        }
    }
    
    private var playerGestureSurfaceView: UIView {
        // MPV's GL view can be aggressive about touch delivery on iOS. Attaching
        // background gestures to the container lets them see touches through the
        // overlay while the delegate still filters real controls.
        return mpvRenderer != nil ? videoContainer : tapOverlayView
    }

    private func configureSeekButtons() {
        let seconds = Int(playerSeekSeconds.rounded())
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        let backwardImage = UIImage(systemName: "gobackward.\(seconds)", withConfiguration: cfg)
            ?? UIImage(systemName: "gobackward", withConfiguration: cfg)
            ?? UIImage(systemName: "backward.fill", withConfiguration: cfg)
        let forwardImage = UIImage(systemName: "goforward.\(seconds)", withConfiguration: cfg)
            ?? UIImage(systemName: "goforward", withConfiguration: cfg)
            ?? UIImage(systemName: "forward.fill", withConfiguration: cfg)
        skipBackwardButton.setImage(backwardImage, for: .normal)
        skipForwardButton.setImage(forwardImage, for: .normal)
        skipBackwardButton.accessibilityLabel = "Seek Back \(seconds) Seconds"
        skipForwardButton.accessibilityLabel = "Seek Forward \(seconds) Seconds"
    }

    private func updatePerformanceOverlayVisibility() {
        let enabled = supportsSharedPlayerControls && isPerformanceOverlayEnabled
        performanceOverlayLabel.isHidden = !enabled
        performanceOverlayLabel.alpha = enabled ? 1.0 : 0.0
        if enabled {
            videoContainer.bringSubviewToFront(performanceOverlayLabel)
            updatePerformanceOverlayText()
            startPerformanceOverlayTimerIfNeeded()
        } else {
            stopPerformanceOverlayTimer()
        }
    }

    private func startPerformanceOverlayTimerIfNeeded() {
        guard performanceOverlayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updatePerformanceOverlayText()
        }
        performanceOverlayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPerformanceOverlayTimer() {
        performanceOverlayTimer?.invalidate()
        performanceOverlayTimer = nil
    }

    private func updatePerformanceOverlayText() {
        guard supportsSharedPlayerControls, isPerformanceOverlayEnabled else { return }
        let pipState = rendererIsPictureInPictureActive() ? "PiP" : "Inline"
        let playState = rendererIsPausedState() ? "Paused" : "Playing"
        let header = "\(isVLCPlayer ? "VLC" : "MPV") \(pipState) \(playState)"
        let progress = "pos \(secondsText(cachedPosition))/\(secondsText(cachedDuration))"
        performanceOverlayLabel.text = "\(header)\n\(systemPerformanceOverlayLine())\n\(progress)\n\(renderer.performanceOverlaySnapshot())"
        videoContainer.bringSubviewToFront(performanceOverlayLabel)
    }

    private func systemPerformanceOverlayLine() -> String {
        let cpuText = processCPUUsagePercent().map { String(format: "%.0f%%", $0) } ?? "n/a"
        let memoryText = processMemoryFootprintBytes().map(formatByteCount) ?? "n/a"
        return "CPU \(cpuText) mem \(memoryText) thermal \(thermalStateText())"
    }

    private func thermalStateText() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func formatByteCount(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576.0
        if megabytes >= 1024 {
            return String(format: "%.2fGB", megabytes / 1024.0)
        }
        return String(format: "%.0fMB", megabytes)
    }

    private func processMemoryFootprintBytes() -> UInt64? {
#if canImport(Darwin)
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else { return nil }
        return UInt64(usage.ru_maxrss)
#else
        return nil
#endif
    }

    private func processCPUUsagePercent() -> Double? {
#if canImport(Darwin)
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }

        let userTime = TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000.0
        let systemTime = TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000.0
        let processTime = userTime + systemTime
        let wallTime = CACurrentMediaTime()

        guard let previousProcessTime = lastCPUProcessTime,
              let previousWallTime = lastCPUWallTime else {
            lastCPUProcessTime = processTime
            lastCPUWallTime = wallTime
            lastCPUUsagePercent = 0
            return 0
        }

        let wallDelta = wallTime - previousWallTime
        let processDelta = processTime - previousProcessTime
        lastCPUProcessTime = processTime
        lastCPUWallTime = wallTime
        guard wallDelta > 0.05, processDelta >= 0 else {
            return lastCPUUsagePercent
        }

        let percent = min(max((processDelta / wallDelta) * 100.0, 0), 999)
        lastCPUUsagePercent = percent
        return percent
#else
        return nil
#endif
    }

    private func setupActions() {
        videoContainer.isMultipleTouchEnabled = true
        tapOverlayView.isMultipleTouchEnabled = true
#if !os(tvOS)
        videoContainer.isExclusiveTouch = false
        tapOverlayView.isExclusiveTouch = false
#endif

        centerPlayPauseButton.addTarget(self, action: #selector(centerPlayPauseTapped), for: .touchUpInside)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        pipButton.addTarget(self, action: #selector(pipTouchDown), for: .touchDown)
        pipButton.addTarget(self, action: #selector(pipTapped), for: .touchUpInside)
        skipBackwardButton.addTarget(self, action: #selector(skipBackwardTapped), for: .touchUpInside)
        skipForwardButton.addTarget(self, action: #selector(skipForwardTapped), for: .touchUpInside)
#if !os(tvOS)
        if supportsSharedPlayerControls {
            skipButton.addTarget(self, action: #selector(skipButtonTapped), for: .touchUpInside)
            nextEpisodeButton.addTarget(self, action: #selector(nextEpisodeButtonTapped), for: .touchUpInside)
            skip85sButton.addTarget(self, action: #selector(skip85sButtonTapped), for: .touchUpInside)
        }
#endif
        if supportsSharedPlayerControls {
            subtitleButton.addTarget(self, action: #selector(subtitleButtonTapped), for: .touchUpInside)
            episodeBrowserButton.addTarget(self, action: #selector(episodeBrowserButtonTapped), for: .touchUpInside)
            speedButton.addTarget(self, action: #selector(speedButtonTapped), for: .touchUpInside)
            audioButton.addTarget(self, action: #selector(audioButtonTapped), for: .touchUpInside)
        }
        
        // Ensure shared player buttons stay interactive above renderer views.
        if supportsSharedPlayerControls {
            [centerPlayPauseButton, closeButton, pipButton, skipBackwardButton,
             skipForwardButton, subtitleButton, episodeBrowserButton, speedButton, audioButton].forEach {
                $0.isUserInteractionEnabled = true
            }
        }
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(containerTapped))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        playerGestureSurfaceView.addGestureRecognizer(tap)
        containerTapGesture = tap
    }

    @objc private func pipTouchDown() {

    }
    
    private func setupHoldGesture() {
        holdGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldGesture(_:)))
        holdGesture?.minimumPressDuration = 0.5
        if let holdGesture = holdGesture {
            playerGestureSurfaceView.addGestureRecognizer(holdGesture)
        }
    }
    
    private func setupDoubleTapSkipGestures() {
        let leftDoubleTap = UITapGestureRecognizer(target: self, action: #selector(leftSideDoubleTapped))
        leftDoubleTap.numberOfTapsRequired = 2
        leftDoubleTap.delegate = self
        leftDoubleTapGesture = leftDoubleTap
        playerGestureSurfaceView.addGestureRecognizer(leftDoubleTap)
        
        let rightDoubleTap = UITapGestureRecognizer(target: self, action: #selector(rightSideDoubleTapped))
        rightDoubleTap.numberOfTapsRequired = 2
        rightDoubleTap.delegate = self
        rightDoubleTapGesture = rightDoubleTap
        playerGestureSurfaceView.addGestureRecognizer(rightDoubleTap)
        
        if mpvRenderer == nil, let tap = containerTapGesture {
            tap.require(toFail: leftDoubleTap)
            tap.require(toFail: rightDoubleTap)
        }
        
        #if !os(tvOS)
        if isTwoFingerTapEnabled {
            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped))
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.delegate = self
            playerGestureSurfaceView.addGestureRecognizer(twoFingerTap)
        }
        #endif
    }

    @objc private func leftSideDoubleTapped(_ gesture: UITapGestureRecognizer) {
        guard isDoubleTapSeekEnabled else { return }
        let location = gesture.location(in: videoContainer)
        let isLeftSide = location.x < videoContainer.bounds.width / 2
        guard isLeftSide else { return }
        logSharedPlayerControl("left double-tap seek by -\(String(format: "%.1f", playerSeekSeconds))")
        rendererSeek(by: -playerSeekSeconds)
        animateButtonTap(skipBackwardButton)
    }

    @objc private func rightSideDoubleTapped(_ gesture: UITapGestureRecognizer) {
        guard isDoubleTapSeekEnabled else { return }
        let location = gesture.location(in: videoContainer)
        let isRightSide = location.x >= videoContainer.bounds.width / 2
        guard isRightSide else { return }
        logSharedPlayerControl("right double-tap seek by \(String(format: "%.1f", playerSeekSeconds))")
        rendererSeek(by: playerSeekSeconds)
        animateButtonTap(skipForwardButton)
    }

    @objc private func twoFingerTapped(_ gesture: UITapGestureRecognizer) {
        // Two-finger tap: toggle play/pause without showing UI
        logSharedPlayerControl("two-finger tap toggle pause currentPaused=\(rendererIsPausedState())")
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
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleBrightnessPan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        brightnessPanGesture = pan
        videoContainer.addGestureRecognizer(pan)
        loadBrightnessLevel()
        setupBrightnessObservation()
        updateBrightnessControlVisibility()
#endif
    }

    private func setupVolumeControls() {
#if !os(tvOS)
        volumeSlider.addTarget(self, action: #selector(volumeSliderChanged(_:)), for: .valueChanged)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleVolumePan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        volumePanGesture = pan
        videoContainer.addGestureRecognizer(pan)
        loadVolumeLevel()
        setupVolumeObservation()
        updateVolumeControlVisibility()
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

    private func setupBrightnessObservation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenBrightnessChanged(_:)),
            name: UIScreen.brightnessDidChangeNotification,
            object: UIScreen.main
        )
    }

    @objc private func screenBrightnessChanged(_ notification: Notification) {
        refreshGestureControlLevels(animated: true)
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
            UIScreen.main.brightness = CGFloat(clamped)
            self.dimmingView.alpha = 0.0
        }
    }

    private func updateBrightnessControlVisibility() {
        if isClosing { return }
        if !isBrightnessControlEnabled || (!controlsVisible && !isBrightnessControlActive) {
            brightnessContainer.isHidden = true
            brightnessContainer.alpha = 0.0
            return
        }
        brightnessContainer.isHidden = false
        brightnessContainer.alpha = 1.0
        videoContainer.bringSubviewToFront(brightnessContainer)
        bringTimedActionButtonsToFront()
    }

    private func showBrightnessControl() {
        isBrightnessControlActive = true
        brightnessContainer.isHidden = false
        brightnessContainer.alpha = 1.0
        videoContainer.bringSubviewToFront(brightnessContainer)
        bringTimedActionButtonsToFront()
    }

    private func hideBrightnessControlSoon() {
        isBrightnessControlActive = false
        guard !isBrightnessControlEnabled else {
            updateBrightnessControlVisibility()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.isBrightnessControlActive else { return }
            UIView.animate(withDuration: 0.2) {
                self.brightnessContainer.alpha = 0.0
            } completion: { _ in
                if !self.isBrightnessControlActive {
                    self.brightnessContainer.isHidden = true
                }
            }
        }
    }

    @objc private func handleBrightnessPan(_ gesture: UIPanGestureRecognizer) {
        guard isBrightnessControlEnabled else { return }

        switch gesture.state {
        case .began:
            brightnessPanStartLevel = Float(UIScreen.main.brightness)
            showBrightnessControl()
            controlsHideWorkItem?.cancel()
        case .changed:
            let translation = gesture.translation(in: videoContainer)
            let delta = Float(-translation.y / max(videoContainer.bounds.height, 1))
            let target = brightnessPanStartLevel + delta * 1.25
            brightnessSlider.value = max(0.0, min(target, 1.0))
            applyBrightnessLevel(brightnessSlider.value)
        case .ended, .cancelled, .failed:
            showControlsTemporarily()
            hideBrightnessControlSoon()
        default:
            break
        }
    }

    private func loadVolumeLevel() {
#if canImport(MediaPlayer)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.systemVolumeSlider = self.systemVolumeView.subviews.compactMap { $0 as? UISlider }.first
            let level = self.systemVolumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume
            self.volumeSlider.value = level
        }
#else
        volumeSlider.value = AVAudioSession.sharedInstance().outputVolume
#endif
    }

    private func setupVolumeObservation() {
        outputVolumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.initial, .new]) { [weak self] session, _ in
            let level = max(0.0, min(session.outputVolume, 1.0))
            DispatchQueue.main.async {
                guard let self, !self.isClosing else { return }
                self.volumeSlider.setValue(level, animated: true)
            }
        }
    }

    private func refreshGestureControlLevels(animated: Bool) {
        if isClosing { return }

        let brightness = max(0.0, min(Float(UIScreen.main.brightness), 1.0))
        brightnessLevel = brightness
        UserDefaults.standard.set(brightness, forKey: brightnessLevelKey)
        brightnessSlider.setValue(brightness, animated: animated)

        var volume = AVAudioSession.sharedInstance().outputVolume
#if canImport(MediaPlayer)
        if systemVolumeSlider == nil {
            systemVolumeSlider = systemVolumeView.subviews.compactMap { $0 as? UISlider }.first
        }
        volume = systemVolumeSlider?.value ?? volume
#endif
        volumeSlider.setValue(max(0.0, min(volume, 1.0)), animated: animated)
    }

    @objc private func volumeSliderChanged(_ sender: UISlider) {
        applyVolumeLevel(sender.value)
        showControlsTemporarily()
    }

    private func applyVolumeLevel(_ value: Float) {
        if isClosing { return }
        let clamped = max(0.0, min(value, 1.0))
        volumeSlider.value = clamped
#if canImport(MediaPlayer)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.systemVolumeSlider == nil {
                self.systemVolumeSlider = self.systemVolumeView.subviews.compactMap { $0 as? UISlider }.first
            }
            self.systemVolumeSlider?.setValue(clamped, animated: false)
            self.systemVolumeSlider?.sendActions(for: .touchUpInside)
        }
#endif
    }

    private func updateVolumeControlVisibility() {
        if isClosing { return }
        if !isVolumeControlEnabled || (!controlsVisible && !isVolumeControlActive) {
            volumeContainer.isHidden = true
            volumeContainer.alpha = 0.0
            return
        }
        volumeContainer.isHidden = false
        volumeContainer.alpha = 1.0
        videoContainer.bringSubviewToFront(volumeContainer)
        bringTimedActionButtonsToFront()
    }

    private func showVolumeControl() {
        isVolumeControlActive = true
        volumeContainer.isHidden = false
        volumeContainer.alpha = 1.0
        videoContainer.bringSubviewToFront(volumeContainer)
        bringTimedActionButtonsToFront()
    }

    private func hideVolumeControlSoon() {
        isVolumeControlActive = false
        guard !isVolumeControlEnabled else {
            updateVolumeControlVisibility()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.isVolumeControlActive else { return }
            UIView.animate(withDuration: 0.2) {
                self.volumeContainer.alpha = 0.0
            } completion: { _ in
                if !self.isVolumeControlActive {
                    self.volumeContainer.isHidden = true
                }
            }
        }
    }

    @objc private func handleVolumePan(_ gesture: UIPanGestureRecognizer) {
        guard isVolumeControlEnabled else { return }

        switch gesture.state {
        case .began:
            volumePanStartLevel = volumeSlider.value
            showVolumeControl()
            controlsHideWorkItem?.cancel()
        case .changed:
            let translation = gesture.translation(in: videoContainer)
            let delta = Float(-translation.y / max(videoContainer.bounds.height, 1))
            let target = volumePanStartLevel + delta * 1.25
            applyVolumeLevel(target)
        case .ended, .cancelled, .failed:
            showControlsTemporarily()
            hideVolumeControlSoon()
        default:
            break
        }
    }

#else
    // tvOS stub to satisfy shared call sites when brightness UI is unavailable
    private func updateBrightnessControlVisibility() { }
    private func updateVolumeControlVisibility() { }
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

    private func applyDefaultPlaybackSpeed() {
        guard !defaultPlaybackSpeedApplied else { return }
        let speed = defaultPlaybackSpeed
        rendererSetSpeed(speed)
        defaultPlaybackSpeedApplied = true
        updateSpeedMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.updateSpeedMenu()
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
        let seconds = playerSeekSeconds
        logSharedPlayerControl("skip backward button tapped seek=\(String(format: "%.1f", seconds))")
        rendererSeek(by: -seconds)
        animateButtonTap(skipBackwardButton)
        showControlsTemporarily()
    }
    
    @objc private func skipForwardTapped() {
        let seconds = playerSeekSeconds
        logSharedPlayerControl("skip forward button tapped seek=\(String(format: "%.1f", seconds))")
        rendererSeek(by: seconds)
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
        rendererApplySubtitleStyle(currentSubtitleStyle())

        if isVLCCustomSubtitleOverlayEnabled {
            updateVLCSubtitleOverlay(for: cachedPosition)
            if subtitleModel.isVisible && currentSubtitleIndex < subtitleURLs.count {
                loadCurrentSubtitle()
                return
            }
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
        updateSubtitleTracksMenu()
        if overlayMenuKind == "subtitles" {
            showMPVSubtitleMenu()
        }
    }
    
    private func updateSubtitleButtonAppearance() {
        let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let imageName = subtitleModel.isVisible ? "captions.bubble.fill" : "captions.bubble"
        let img = UIImage(systemName: imageName, withConfiguration: cfg)
        subtitleButton.setImage(img, for: .normal)
    }

    private func setSubtitleVisible(_ visible: Bool, persist: Bool = true) {
        subtitleModel.setVisible(visible, persist: persist)
    }

    private var isVLCEpisodeBrowserButtonSettingEnabled: Bool {
        if UserDefaults.standard.object(forKey: "showVLCEpisodeBrowserButton") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "showVLCEpisodeBrowserButton")
    }

    private func updateEpisodeBrowserButtonVisibility() {
        let shouldShow: Bool
        if supportsSharedPlayerControls,
           isVLCEpisodeBrowserButtonSettingEnabled,
           case .episode = mediaInfo {
            shouldShow = true
        } else {
            shouldShow = false
        }

        episodeBrowserButton.isHidden = !shouldShow
        if !shouldShow {
            episodeBrowserButton.alpha = 0.0
            if isEpisodeBrowserVisible {
                dismissEpisodeBrowser(animated: true)
            }
        } else if controlsVisible {
            episodeBrowserButton.alpha = 1.0
        }

        if shouldShow {
            subtitleTrailingToProgressConstraint?.isActive = false
            subtitleTrailingToEpisodeBrowserConstraint?.isActive = true
        } else {
            subtitleTrailingToEpisodeBrowserConstraint?.isActive = false
            subtitleTrailingToProgressConstraint?.isActive = true
        }
    }

    @objc private func episodeBrowserButtonTapped() {
        guard let seed = makeEpisodeBrowserSeed() else { return }
        if isEpisodeBrowserVisible {
            dismissEpisodeBrowser(animated: true)
            return
        }
        showEpisodeBrowser(seed: seed)
    }

    private func makeEpisodeBrowserSeed() -> PlayerEpisodeBrowserSeed? {
        guard case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, let showPosterURL, let isAnime) = mediaInfo else {
            return nil
        }

        let fallbackTitle = playerTitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = showTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = [resolvedTitle, fallbackTitle]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? "Show"

        return PlayerEpisodeBrowserSeed(
            showId: showId,
            showTitle: title,
            showPosterURL: showPosterURL,
            currentSeasonNumber: seasonNumber,
            currentEpisodeNumber: episodeNumber,
            isAnime: isAnime || isAnimeContent(),
            imdbId: imdbId,
            currentPlaybackContext: episodePlaybackContext
        )
    }

    private func showEpisodeBrowser(seed: PlayerEpisodeBrowserSeed) {
        controlsHideWorkItem?.cancel()
        isEpisodeBrowserVisible = true
        let drawer = PlayerEpisodeBrowserDrawer(
            seed: seed,
            onClose: { [weak self] in
                self?.dismissEpisodeBrowser(animated: true)
            },
            onEpisodeSelected: { [weak self] item in
                self?.handleEpisodeBrowserSelection(item)
            }
        )
        let host = UIHostingController(rootView: AnyView(drawer))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        videoContainer.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: videoContainer.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor)
        ])
        host.didMove(toParent: self)
        episodeBrowserHostingController = host
        videoContainer.bringSubviewToFront(host.view)
    }

    private func dismissEpisodeBrowser(animated: Bool) {
        guard let host = episodeBrowserHostingController else {
            isEpisodeBrowserVisible = false
            return
        }
        isEpisodeBrowserVisible = false
        let removeHost = {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        if animated {
            UIView.animate(withDuration: 0.2) {
                host.view.alpha = 0.0
            } completion: { _ in
                removeHost()
            }
        } else {
            removeHost()
        }
        episodeBrowserHostingController = nil
    }

    private func handleEpisodeBrowserSelection(_ item: PlayerEpisodeBrowserItem) {
        guard !item.isCurrent else { return }

        if UserDefaults.standard.bool(forKey: "preferDownloadedMedia"),
           let request = downloadedPlaybackRequest(for: item) {
            dismissEpisodeBrowser(animated: true)
            replacePlayback(with: request)
            return
        }

        presentEpisodeSourceSheet(for: item)
    }

    private func downloadedPlaybackRequest(for item: PlayerEpisodeBrowserItem) -> PlayerResolvedPlaybackRequest? {
        guard let downloadItem = item.downloadItem,
              let fileURL = DownloadManager.shared.localFileURL(for: downloadItem) else {
            return nil
        }
        let subtitleArray = DownloadManager.shared.localSubtitleURL(for: downloadItem).map { [$0.absoluteString] }
        let preset = PlayerPreset.presets.first ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: [])
        return PlayerResolvedPlaybackRequest(
            url: fileURL,
            preset: preset,
            headers: [:],
            subtitles: subtitleArray,
            subtitleNames: nil,
            mediaInfo: downloadItem.mediaInfo,
            imdbId: item.imdbId,
            isAnimeHint: downloadItem.isAnime,
            originalTMDBSeasonNumber: item.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: item.originalTMDBEpisodeNumber,
            episodePlaybackContext: downloadItem.episodePlaybackContext ?? item.playbackContext,
            launchContext: nil
        )
    }

    private func presentEpisodeSourceSheet(for item: PlayerEpisodeBrowserItem) {
        guard presentedViewController == nil else { return }
        let sheet = ModulesSearchResultsSheet(
            mediaTitle: item.mediaTitle,
            seasonTitleOverride: item.seasonTitleOverride,
            originalTitle: item.originalTitle,
            isMovie: false,
            isAnimeContent: item.isAnime,
            selectedEpisode: item.episode,
            tmdbId: item.showId,
            animeSeasonTitle: item.animeSeasonTitle,
            posterPath: item.posterURL ?? item.showPosterURL,
            imdbId: item.imdbId,
            originalTMDBSeasonNumber: item.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: item.originalTMDBEpisodeNumber,
            specialTitleOnlySearch: item.playbackContext?.titleOnlySearch ?? false,
            episodePlaybackContext: item.playbackContext,
            autoModeOnly: UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"),
            onResolvedPlaybackRequest: { [weak self] request in
                self?.replacePlayback(with: request)
            }
        )
        let host = UIHostingController(rootView: sheet)
        present(host, animated: true, completion: nil)
    }

    private func replacePlayback(with request: PlayerResolvedPlaybackRequest) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dismissEpisodeBrowser(animated: true)
            self.controlsHideWorkItem?.cancel()
            self.playbackStartupWorkItem?.cancel()
            self.playbackDidStart = false
            self.playbackFailureHandled = false
            self.playbackSlowProbeCount = 0
            self.vlcProxyFallbackTried = false
            self.didDispatchNextEpisodeRequest = false
            self.pendingNextEpisodeRequest = nil
#if !os(tvOS)
            self.nextEpisodeButton.isEnabled = true
#endif
            self.resetTimedEpisodeStateForNewPlayback()

            self.initialPreset = request.preset
            self.initialHeaders = request.headers
            self.initialSubtitles = request.subtitles
            self.initialSubtitleNames = request.subtitleNames
            self.mediaInfo = request.mediaInfo
            self.imdbId = request.imdbId
            self.isAnimeHint = request.isAnimeHint
            self.originalTMDBSeasonNumber = request.originalTMDBSeasonNumber
            self.originalTMDBEpisodeNumber = request.originalTMDBEpisodeNumber
            self.episodePlaybackContext = request.episodePlaybackContext
            self.playbackLaunchContext = request.launchContext

            self.rendererStop()
            self.updatePlayerTitle()
            self.updateEpisodeBrowserButtonVisibility()
            self.load(url: request.url, preset: request.preset, headers: request.headers)
            self.showControlsTemporarily()
        }
    }

    private func resetTimedEpisodeStateForNewPlayback() {
#if !os(tvOS)
        skipSegments.removeAll()
        skipDataFetched = false
        autoSkippedSegments.removeAll()
        currentActiveSkipSegment = nil
        skipButton.alpha = 0.0
        skipButton.isHidden = true
        nextEpisodeButton.alpha = 0.0
        nextEpisodeButton.isHidden = true
        nextEpisodeButtonShown = false
        skip85sButton.alpha = 0.0
        skip85sButton.isHidden = true
        skip85sButtonShown = false
#endif
        progressModel.skipSegments = []
        nextEpisodePreview = nil
        nextEpisodePreviewKey = nil
        nextEpisodePreviewUnavailableKeys.removeAll()
        nextEpisodePreviewTask?.cancel()
        nextEpisodePreviewTask = nil
        nextEpisodeArtworkTask?.cancel()
        nextEpisodeArtworkTask = nil
        nextEpisodeArtworkKey = nil
        nextEpisodeArtworkImage = nil
#if !os(tvOS)
        nextEpisodeButton.configuration?.title = "Next Episode"
        nextEpisodeButton.configuration?.subtitle = nil
        nextEpisodeButton.configuration?.image = UIImage(systemName: "forward.end.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
#endif
    }

    private var usesOverlayPlayerMenus: Bool {
        false
    }

    private func makeOverlayAction(
        title: String,
        imageName: String? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) -> PlayerOverlayMenuAction {
        PlayerOverlayMenuAction(title: title, imageName: imageName, isSelected: isSelected, isEnabled: isEnabled, handler: handler)
    }

    private func showOverlayMenu(title: String, kind: String, sections: [PlayerOverlayMenuSection]) {
        guard usesOverlayPlayerMenus else { return }
        overlayMenuKind = kind
        overlayMenuHandlers.removeAll()
        overlayMenuStackView.arrangedSubviews.forEach { view in
            overlayMenuStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        overlayMenuTitleLabel.text = title

        for section in sections {
            if let title = section.title, !title.isEmpty {
                let label = UILabel()
                label.text = title
                label.textColor = UIColor.white.withAlphaComponent(0.65)
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.numberOfLines = 1
                overlayMenuStackView.addArrangedSubview(label)
            }
            for action in section.actions {
                let button = UIButton(type: .system)
                button.contentHorizontalAlignment = .leading
                button.titleLabel?.font = .systemFont(ofSize: 13, weight: action.isSelected ? .bold : .medium)
                let prefix = action.isSelected ? "✓ " : "  "
                button.setTitle(prefix + action.title, for: .normal)
                button.setTitleColor(action.isEnabled ? .white : UIColor.white.withAlphaComponent(0.38), for: .normal)
                if let imageName = action.imageName {
                    button.setImage(UIImage(systemName: imageName), for: .normal)
                    button.tintColor = action.isEnabled ? .white : UIColor.white.withAlphaComponent(0.38)
                    button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
                }
                button.backgroundColor = action.isSelected ? UIColor.white.withAlphaComponent(0.18) : UIColor.white.withAlphaComponent(0.07)
                button.layer.cornerRadius = 6
                button.clipsToBounds = true
                button.isEnabled = action.isEnabled
                let handlerID = nextOverlayMenuHandlerID
                nextOverlayMenuHandlerID += 1
                overlayMenuHandlers[handlerID] = action.handler
                button.tag = handlerID
                button.heightAnchor.constraint(equalToConstant: 34).isActive = true
                button.addTarget(self, action: #selector(overlayMenuActionTapped(_:)), for: .touchUpInside)
                overlayMenuStackView.addArrangedSubview(button)
            }
        }

        overlayMenuDismissView.isHidden = false
        overlayMenuPanelView.isHidden = false
        videoContainer.bringSubviewToFront(overlayMenuDismissView)
        videoContainer.bringSubviewToFront(overlayMenuPanelView)
        overlayMenuScrollView.setContentOffset(.zero, animated: false)
        controlsHideWorkItem?.cancel()
        UIView.animate(withDuration: 0.14) {
            self.overlayMenuDismissView.alpha = 1.0
            self.overlayMenuPanelView.alpha = 1.0
        }
    }

    private func hideOverlayMenu(animated: Bool = true) {
        guard !overlayMenuPanelView.isHidden else { return }
        overlayMenuKind = nil
        let finish = {
            self.overlayMenuDismissView.isHidden = true
            self.overlayMenuPanelView.isHidden = true
            self.overlayMenuHandlers.removeAll()
        }
        if animated {
            UIView.animate(withDuration: 0.12) {
                self.overlayMenuDismissView.alpha = 0.0
                self.overlayMenuPanelView.alpha = 0.0
            } completion: { _ in finish() }
        } else {
            overlayMenuDismissView.alpha = 0.0
            overlayMenuPanelView.alpha = 0.0
            finish()
        }
    }

    @objc private func overlayMenuDismissTapped() {
        hideOverlayMenu()
        showControlsTemporarily()
    }

    @objc private func overlayMenuActionTapped(_ sender: UIButton) {
        overlayMenuHandlers[sender.tag]?()
    }

    @objc private func speedButtonTapped() {
        guard usesOverlayPlayerMenus else { return }
        showMPVSpeedMenu()
    }

    private func showMPVSpeedMenu() {
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
        let actions = speeds.map { name, speed in
            makeOverlayAction(title: name, imageName: "hare.fill", isSelected: abs(currentSpeed - speed) < 0.01) { [weak self] in
                guard let self else { return }
                self.rendererSetSpeed(speed)
                self.speedIndicatorLabel.text = String(format: "%.2fx", speed)
                UIView.animate(withDuration: 0.16) {
                    self.speedIndicatorLabel.alpha = 1.0
                } completion: { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        UIView.animate(withDuration: 0.16) {
                            self?.speedIndicatorLabel.alpha = 0.0
                        }
                    }
                }
                self.hideOverlayMenu()
                self.updateSpeedMenu()
                self.showControlsTemporarily()
            }
        }
        showOverlayMenu(title: "Playback Speed", kind: "speed", sections: [PlayerOverlayMenuSection(title: nil, actions: actions)])
    }

    @objc private func audioButtonTapped() {
        guard usesOverlayPlayerMenus else { return }
        showMPVAudioMenu()
    }

    private func showMPVAudioMenu() {
        let detailedTracks = rendererGetAudioTracksDetailed()
        let currentAudioTrackId = rendererGetCurrentAudioTrackId()
        let actions: [PlayerOverlayMenuAction]
        if detailedTracks.isEmpty {
            actions = [makeOverlayAction(title: "No audio tracks available", isEnabled: false) {}]
        } else {
            actions = detailedTracks.map { id, name, _ in
                makeOverlayAction(title: name, imageName: "speaker.wave.2", isSelected: id == currentAudioTrackId) { [weak self] in
                    guard let self else { return }
                    self.userSelectedAudioTrack = true
                    self.rendererSetAudioTrack(id: id)
                    self.updateAudioTracksMenu()
                    self.hideOverlayMenu()
                    self.showControlsTemporarily()
                }
            }
        }
        showOverlayMenu(title: "Audio Tracks", kind: "audio", sections: [PlayerOverlayMenuSection(title: nil, actions: actions)])
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
    
    private func updateAudioTracksMenuWhenReady(attempt: Int = 0) {
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

        if attempt >= 20 {
            updateAudioTracksMenu()
            return
        }
        
        // Tracks not ready yet - retry shortly (works for both VLC and MPV)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.updateAudioTracksMenuWhenReady(attempt: attempt + 1)
        }
    }

    private func updateSubtitleTracksMenuWhenReady(attempt: Int = 0) {
        if userSelectedSubtitleTrack {
            updateSubtitleTracksMenu()
            return
        }

        if isVLCPlayer && !canMutateVLCSubtitleTracks {
            if attempt >= 20 {
                updateSubtitleTracksMenu()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.updateSubtitleTracksMenuWhenReady(attempt: attempt + 1)
            }
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
        if episodePlaybackContext?.anilistMediaId != nil { return true }
        guard let info = mediaInfo else { return false }
        switch info {
        case .movie(_, _, _, let isAnime):
            return isAnime
        case .episode(_, _, _, _, _, let isAnime):
            return isAnime
        }
    }

    // MARK: - Skip Data Integration (AniSkip + TheIntroDB)

    private func fetchSkipData() {
        guard !skipDataFetched else { return }
        guard let info = mediaInfo else {
            skipDataFetched = true
#if !os(tvOS)
            applySkip85sFallbackVisibility()
#endif
            Logger.shared.log("SkipData: no mediaInfo; using Skip 85s fallback if enabled", type: "Skip")
            return
        }

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
    private func bringTimedActionButtonsToFront() {
        if !skipButton.isHidden || skipButton.alpha > 0 {
            videoContainer.bringSubviewToFront(skipButton)
        }
        if nextEpisodeButtonShown || !nextEpisodeButton.isHidden || nextEpisodeButton.alpha > 0 {
            videoContainer.bringSubviewToFront(nextEpisodeButton)
        }
        if skip85sButtonShown || !skip85sButton.isHidden || skip85sButton.alpha > 0 {
            videoContainer.bringSubviewToFront(skip85sButton)
        }
    }

    @discardableResult
    private func applySkip85sFallbackVisibility() -> Bool {
        if UserDefaults.standard.bool(forKey: "skip85sEnabled") {
            showSkip85sButton()
            return true
        }
        hideSkip85sButton()
        return false
    }

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
            guard seg.startTime.isFinite, seg.endTime.isFinite else { return false }
            return position >= seg.startTime && position <= seg.endTime
        }

        if let seg = activeSegment {
            // Auto-skip if enabled and not yet skipped for this segment
            let autoSkipEnabled = UserDefaults.standard.bool(forKey: "aniSkipAutoSkip")
            if autoSkipEnabled, !autoSkippedSegments.contains(seg.uniqueKey) {
                autoSkippedSegments.insert(seg.uniqueKey)
                Logger.shared.log("SkipData: Auto-skipping \(seg.type.rawValue) from \(secondsText(seg.startTime))s to \(secondsText(seg.endTime))s", type: "Skip")
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

    private func nextEpisodeKey(seasonNumber: Int, episodeNumber: Int) -> String {
        guard case .episode(let showId, _, _, _, _, _) = mediaInfo else {
            return "none"
        }
        return "\(showId):\(seasonNumber):\(episodeNumber)"
    }

    private var shouldUsePosterNextEpisodeButton: Bool {
        UserDefaults.standard.bool(forKey: "showNextEpisodePosterButton")
    }

    private func resolveNextEpisodePreviewIfNeeded(seasonNumber: Int, episodeNumber: Int) {
        let key = nextEpisodeKey(seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        guard nextEpisodePreviewKey != key,
              !nextEpisodePreviewUnavailableKeys.contains(key),
              nextEpisodePreviewTask == nil else {
            return
        }
        guard let seed = makeEpisodeBrowserSeed() else {
            nextEpisodePreviewUnavailableKeys.insert(key)
            return
        }

        nextEpisodePreviewTask = Task { @MainActor [weak self] in
            let model = PlayerEpisodeBrowserViewModel(seed: seed)
            let item = await model.itemAfterCurrent()
            guard let self else { return }
            self.nextEpisodePreviewTask = nil
            guard self.nextEpisodeKey(seasonNumber: seasonNumber, episodeNumber: episodeNumber) == key else { return }
            if let item {
                self.nextEpisodePreview = item
                self.nextEpisodePreviewKey = key
                self.applyNextEpisodeButtonAppearance()
            } else {
                self.nextEpisodePreview = nil
                self.nextEpisodePreviewKey = nil
                self.nextEpisodePreviewUnavailableKeys.insert(key)
                self.hideNextEpisodeButton()
            }
        }
    }

    private func applyNextEpisodeButtonAppearance() {
        if shouldUsePosterNextEpisodeButton, let preview = nextEpisodePreview, !preview.artworkURLs.isEmpty {
            applyPosterNextEpisodeButton(preview)
        } else {
            applyTextNextEpisodeButton()
        }
    }

    private func applyTextNextEpisodeButton() {
        nextEpisodeArtworkTask?.cancel()
        nextEpisodeArtworkTask = nil
        nextEpisodeArtworkKey = nil
        nextEpisodeArtworkImage = nil

        var config = nextEpisodeButton.configuration ?? UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.2)
        config.baseForegroundColor = UIColor.white
        config.image = UIImage(systemName: "forward.end.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.imagePlacement = .leading
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 18)
        config.title = "Next Episode"
        config.subtitle = nil
        config.titleLineBreakMode = .byTruncatingTail
        nextEpisodeButton.configuration = config
    }

    private func applyPosterNextEpisodeButton(_ item: PlayerEpisodeBrowserItem) {
        let imageURLs = item.artworkURLs
        let imageKey = imageURLs.joined(separator: "|")
        let isSameArtwork = nextEpisodeArtworkKey == imageKey
        let placeholderImage = UIImage(systemName: "photo")

        var config = nextEpisodeButton.configuration ?? UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.58)
        config.baseForegroundColor = UIColor.white
        config.imagePlacement = .leading
        config.imagePadding = 10
        config.image = isSameArtwork ? (nextEpisodeArtworkImage ?? placeholderImage) : placeholderImage
        config.title = "\(item.displayCode)  \(item.displayTitle)"
        config.subtitle = "Next Episode"
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 14)
        config.titleLineBreakMode = .byTruncatingTail
        config.subtitleLineBreakMode = .byTruncatingTail
        nextEpisodeButton.configuration = config

        guard !isSameArtwork else {
            return
        }

        nextEpisodeArtworkTask?.cancel()
        nextEpisodeArtworkTask = nil
        nextEpisodeArtworkKey = imageKey
        nextEpisodeArtworkImage = nil
        loadNextEpisodeArtwork(from: imageURLs, key: imageKey)
    }

    private func loadNextEpisodeArtwork(from imageURLs: [String], key: String, index: Int = 0) {
        guard index < imageURLs.count else { return }
        guard let url = URL(string: imageURLs[index]) else {
            loadNextEpisodeArtwork(from: imageURLs, key: key, index: index + 1)
            return
        }

#if canImport(Kingfisher)
        KingfisherManager.shared.retrieveImage(with: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.nextEpisodeArtworkKey == key,
                      self.shouldUsePosterNextEpisodeButton else { return }

                switch result {
                case .success(let value):
                    self.applyNextEpisodeArtworkImage(value.image, key: key)
                case .failure:
                    self.loadNextEpisodeArtwork(from: imageURLs, key: key, index: index + 1)
                }
            }
        }
#else
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let rawImage = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                guard let self,
                      self.nextEpisodeArtworkKey == key,
                      self.shouldUsePosterNextEpisodeButton else { return }

                if let rawImage {
                    self.applyNextEpisodeArtworkImage(rawImage, key: key)
                } else {
                    self.loadNextEpisodeArtwork(from: imageURLs, key: key, index: index + 1)
                }
            }
        }
        nextEpisodeArtworkTask = task
        task.resume()
#endif
    }

    private func applyNextEpisodeArtworkImage(_ rawImage: UIImage, key: String) {
        guard nextEpisodeArtworkKey == key else { return }
        let image = makeNextEpisodeArtworkImage(from: rawImage)
        nextEpisodeArtworkImage = image

        var current = nextEpisodeButton.configuration ?? UIButton.Configuration.filled()
        current.image = image
        nextEpisodeButton.configuration = current
    }

    private func makeNextEpisodeArtworkImage(from rawImage: UIImage) -> UIImage {
        guard rawImage.size.width > 0, rawImage.size.height > 0 else {
            return rawImage.withRenderingMode(.alwaysOriginal)
        }

        let aspectRatio = rawImage.size.width / rawImage.size.height
        let targetSize = aspectRatio < 0.85
            ? CGSize(width: 48, height: 68)
            : CGSize(width: 84, height: 48)

        let scale = max(targetSize.width / rawImage.size.width, targetSize.height / rawImage.size.height)
        let drawSize = CGSize(width: rawImage.size.width * scale, height: rawImage.size.height * scale)
        let drawRect = CGRect(
            x: (targetSize.width - drawSize.width) / 2,
            y: (targetSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: targetSize), cornerRadius: 7).addClip()
            rawImage.draw(in: drawRect)
        }.withRenderingMode(.alwaysOriginal)
    }

    private func updateNextEpisodeState(position: Double, duration: Double) {
        guard duration > 0 else { return }
        guard case .episode(_, let seasonNumber, let episodeNumber, _, _, _) = mediaInfo else { return }

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
        let previewKey = nextEpisodeKey(seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        if progress >= threshold, !nextEpisodeButtonShown {
            resolveNextEpisodePreviewIfNeeded(seasonNumber: seasonNumber, episodeNumber: episodeNumber)
            if nextEpisodePreviewUnavailableKeys.contains(previewKey) {
                hideNextEpisodeButton()
                return
            }
            applyNextEpisodeButtonAppearance()
            showNextEpisodeButton()
        } else if progress < threshold, nextEpisodeButtonShown {
            hideNextEpisodeButton()
        } else if progress >= threshold, nextEpisodeButtonShown {
            resolveNextEpisodePreviewIfNeeded(seasonNumber: seasonNumber, episodeNumber: episodeNumber)
            if nextEpisodePreviewUnavailableKeys.contains(previewKey) {
                hideNextEpisodeButton()
            } else {
                applyNextEpisodeButtonAppearance()
            }
        }
    }

    @objc private func skipButtonTapped() {
        guard let seg = currentActiveSkipSegment else { return }
        guard seg.endTime.isFinite else {
            Logger.shared.log("SkipData: Ignored skip tap for \(seg.type.rawValue); invalid end=\(secondsText(seg.endTime))", type: "Skip")
            currentActiveSkipSegment = nil
            hideSkipButton()
            return
        }
        Logger.shared.log("SkipData: User tapped skip for \(seg.type.rawValue) -> seeking to \(secondsText(seg.endTime + 1))s", type: "Skip")
        autoSkippedSegments.insert(seg.uniqueKey)
        rendererSeek(to: seg.endTime + 1.0)
        currentActiveSkipSegment = nil
        hideSkipButton()
    }

    @objc private func nextEpisodeButtonTapped() {
        guard case .episode(_, let seasonNumber, let episodeNumber, _, _, _) = mediaInfo else { return }
        guard pendingNextEpisodeRequest == nil else { return }

        let nextEpisodeNumber = episodeNumber + 1
        Logger.shared.log("NextEpisode: User requested S\(seasonNumber)E\(nextEpisodeNumber)", type: "Player")
        if let preview = nextEpisodePreview {
            hideNextEpisodeButton()
            handleEpisodeBrowserSelection(preview)
            return
        }

        if nextEpisodePreviewTask != nil {
            return
        }

        if nextEpisodePreviewUnavailableKeys.contains(nextEpisodeKey(seasonNumber: seasonNumber, episodeNumber: episodeNumber)) {
            hideNextEpisodeButton()
            return
        }

        pendingNextEpisodeRequest = (seasonNumber, nextEpisodeNumber)
        nextEpisodeButton.isEnabled = false
        hideNextEpisodeButton()
        closeTapped()
    }

    private func showSkipButton() {
        guard skipButton.isHidden || skipButton.alpha < 1 else { return }
        skipButton.isHidden = false
        videoContainer.bringSubviewToFront(skipButton)
        bringTimedActionButtonsToFront()
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
        Logger.shared.log("Skip85s: User tapped skip 85s at \(secondsText(currentPosition))s -> seeking to \(secondsText(targetPosition))s", type: "Skip")
        rendererSeek(to: targetPosition)
    }

    private func showSkip85sButton() {
        skip85sButtonShown = true
        guard controlsVisible else { return }
        skip85sButton.isHidden = false
        videoContainer.bringSubviewToFront(skip85sButton)
        bringTimedActionButtonsToFront()
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
        bringTimedActionButtonsToFront()
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

    private func dispatchPendingNextEpisodeRequestIfNeeded() {
        guard !didDispatchNextEpisodeRequest,
              let request = pendingNextEpisodeRequest else { return }

        didDispatchNextEpisodeRequest = true
        pendingNextEpisodeRequest = nil
        onRequestNextEpisode?(request.seasonNumber, request.episodeNumber)
    }

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
    private func preparePlayerHeaderProxyIfNeeded(originalURL: URL, headers: [String: String]?) -> (url: URL, headers: [String: String]?) {
        if isVLCPlayer {
            return prepareVLCHeaderProxyIfNeeded(originalURL: originalURL, headers: headers)
        }
        if mpvRenderer != nil {
            return prepareMPVHeaderProxyIfNeeded(originalURL: originalURL, headers: headers)
        }
        return (originalURL, headers)
    }

    private func buildProxyHeaders(for _: URL, baseHeaders: [String: String]) -> [String: String] {
        // Services often require exact Origin/Referer/Cookie/User-Agent values.
        // The proxy must preserve the caller-provided header set without filling
        // anything from the media URL.
        return baseHeaders
    }

    private var isVLCHeaderProxyEnabled: Bool {
        UserDefaults.standard.object(forKey: "vlcHeaderProxyEnabled") as? Bool ?? true
    }

    private func isRemoteHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func prepareVLCHeaderProxyIfNeeded(originalURL: URL, headers: [String: String]?) -> (url: URL, headers: [String: String]?) {
        guard isVLCPlayer else { return (originalURL, headers) }
        guard isVLCHeaderProxyEnabled else { return (originalURL, headers) }
        guard isRemoteHTTPURL(originalURL), !isLocalProxyURL(originalURL) else { return (originalURL, headers) }
        guard let headers, !headers.isEmpty else { return (originalURL, headers) }

        let proxyHeaders = buildProxyHeaders(for: originalURL, baseHeaders: headers)
        guard let proxyURL = VLCHeaderProxy.shared.makeProxyURL(for: originalURL, headers: proxyHeaders) else {
            Logger.shared.log("PlayerViewController: proactive VLC proxy URL creation failed; using direct VLC headers", type: "Stream")
            return (originalURL, headers)
        }

        vlcProxyFallbackTried = true

        if let subs = initialSubtitles, !subs.isEmpty {
            Logger.shared.log("PlayerViewController: proactive VLC proxy subtitle count=\(subs.count)", type: "Stream")
            let proxiedSubs = proxySubtitleURLs(subs, headers: headers)
            if proxiedSubs.count == subs.count {
                initialSubtitles = proxiedSubs
                Logger.shared.log("PlayerViewController: proactive VLC proxy subtitles ready", type: "Stream")
            } else {
                Logger.shared.log("PlayerViewController: proactive VLC proxy subtitles incomplete; using direct URLs", type: "Stream")
            }
        }

        Logger.shared.log("PlayerViewController: proactive VLC proxy activated headerKeys=[\(headers.keys.sorted().joined(separator: ","))]", type: "Stream")
        return (proxyURL, nil)
    }

    private func prepareMPVHeaderProxyIfNeeded(originalURL: URL, headers: [String: String]?) -> (url: URL, headers: [String: String]?) {
        guard isRemoteHTTPURL(originalURL), !isLocalProxyURL(originalURL) else { return (originalURL, headers) }

        let proxyHeaders = buildProxyHeaders(for: originalURL, baseHeaders: headers ?? [:])
        let shouldBridge = !proxyHeaders.isEmpty || playbackLaunchContext?.sourceKind == .stremio
        guard shouldBridge else { return (originalURL, headers) }

        guard let proxyURL = MPVHeaderProxy.shared.makeProxyURL(for: originalURL, headers: proxyHeaders, logType: "MPV") else {
            Logger.shared.log("[PlayerVC.PlaybackStart] proactive MPV bridge URL creation failed; using direct MPV headers", type: "MPV")
            return (originalURL, headers)
        }

        mpvTransportBridgeFallbackTried = true
        isMPVTransportBridgePlaybackActive = true
        Logger.shared.log("[PlayerVC.PlaybackStart] proactive MPV bridge activated target=\(originalURL.absoluteString) headerKeys=[\(proxyHeaders.keys.sorted().joined(separator: ","))]", type: "MPV")
        return (proxyURL, nil)
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
        guard let originalURL = initialURL, !isLocalProxyURL(originalURL) else { return false }
        guard let headers = initialHeaders, !headers.isEmpty else { return false }

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

    private func isMPVTransportBridgeCandidate(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("unexpected tls packet")
            || (lower.contains("tls") && lower.contains("failed to open"))
    }

    private func attemptMPVTransportBridgeFallbackIfNeeded(after message: String) -> Bool {
        guard mpvRenderer != nil else { return false }
        guard isMPVTransportBridgeCandidate(message) else { return false }
        guard !mpvTransportBridgeFallbackTried else { return false }
        guard let originalURL = initialURL,
              isRemoteHTTPURL(originalURL),
              !isLocalProxyURL(originalURL),
              let preset = initialPreset else {
            return false
        }

        let proxyHeaders = buildProxyHeaders(for: originalURL, baseHeaders: initialHeaders ?? [:])
        guard let proxyURL = MPVHeaderProxy.shared.makeProxyURL(for: originalURL, headers: proxyHeaders, logType: "MPV") else {
            Logger.shared.log("[PlayerVC.PlaybackStart] MPV transport bridge URL creation failed; keeping direct failure", type: "MPV")
            return false
        }

        mpvTransportBridgeFallbackTried = true
        isMPVTransportBridgePlaybackActive = true
        Logger.shared.log("[PlayerVC.PlaybackStart] MPV transport bridge activated after TLS failure target=\(originalURL.absoluteString) headerKeys=[\(proxyHeaders.keys.sorted().joined(separator: ","))]", type: "MPV")
        load(url: proxyURL, preset: preset, headers: nil)
        return true
    }

    #else
    private func preparePlayerHeaderProxyIfNeeded(originalURL: URL, headers: [String: String]?) -> (url: URL, headers: [String: String]?) {
        return (originalURL, headers)
    }

    private func attemptVlcProxyFallbackIfNeeded() -> Bool {
        return false
    }

    private func attemptMPVTransportBridgeFallbackIfNeeded(after _: String) -> Bool {
        return false
    }

    #endif

    private func showMPVSubtitleMenu() {
        updateSubtitleTracksMenu()

        let externalTracks: [(Int, String)] = isVLCCustomSubtitleOverlayEnabled
            ? subtitleURLs.enumerated().map { index, _ in
                let name = index < subtitleNames.count ? subtitleNames[index] : "Subtitle \(index + 1)"
                return (index, name)
            }
            : []
        let nativeSubtitleTracks = rendererGetSubtitleTrackDescriptors()
            .filter { $0.id >= 0 && !isDisabledTrackName($0.name) }
        let embeddedTracks = nativeSubtitleTracks.map { ($0.id, $0.name) }

        var sections: [PlayerOverlayMenuSection] = []
        var trackActions: [PlayerOverlayMenuAction] = [
            makeOverlayAction(title: "Disable Subtitles", imageName: "xmark", isSelected: !subtitleModel.isVisible) { [weak self] in
                guard let self else { return }
                self.subtitleModel.isVisible = false
                self.userSelectedSubtitleTrack = true
                self.rendererDisableSubtitles()
                self.subtitleEntries.removeAll()
                self.vlcSubtitleSelection = .none
                self.updateVLCSubtitleOverlay(for: self.cachedPosition)
                self.updateSubtitleButtonAppearance()
                self.updateSubtitleTracksMenu()
                self.showMPVSubtitleMenu()
                Logger.shared.log("[PlayerVC.Subtitles] user disabled subtitles from overlay menu", type: "Player")
            }
        ]

        if externalTracks.isEmpty && embeddedTracks.isEmpty {
            trackActions.append(makeOverlayAction(title: "No subtitles in stream", isEnabled: false) {})
        } else {
            trackActions.append(contentsOf: externalTracks.map { id, name in
                let selected: Bool = {
                    guard subtitleModel.isVisible, case .external(let selectedIndex) = vlcSubtitleSelection else { return false }
                    return selectedIndex == id
                }()
                return makeOverlayAction(title: name, imageName: "captions.bubble", isSelected: selected) { [weak self] in
                    guard let self else { return }
                    self.subtitleModel.isVisible = true
                    self.userSelectedSubtitleTrack = true
                    self.currentSubtitleIndex = id
                    self.vlcSubtitleSelection = .external(index: id)
                    self.loadCurrentSubtitle()
                    self.rendererDisableSubtitles()
                    self.updateVLCSubtitleOverlay(for: self.cachedPosition)
                    self.updateSubtitleButtonAppearance()
                    self.updateSubtitleTracksMenu()
                    self.showMPVSubtitleMenu()
                    Logger.shared.log("[PlayerVC.Subtitles] user selected external subtitle index=\(id) name=\(name)", type: "Player")
                }
            })

            trackActions.append(contentsOf: nativeSubtitleTracks.map { track in
                let blocksMPVDefault = !canAutoSelectNativeSubtitleTrack(track)
                let selected: Bool = {
                    guard subtitleModel.isVisible, case .embedded(let selectedTrackId) = vlcSubtitleSelection else { return false }
                    return selectedTrackId == track.id
                }()
                let title = blocksMPVDefault ? "\(track.name) [\(subtitleBitmapCodecLabel(track.codec))]" : track.name
                return makeOverlayAction(
                    title: title,
                    imageName: blocksMPVDefault ? "exclamationmark.triangle" : "captions.bubble",
                    isSelected: selected,
                    isEnabled: !blocksMPVDefault
                ) { [weak self] in
                    guard let self else { return }
                    self.subtitleModel.isVisible = true
                    self.userSelectedSubtitleTrack = true
                    self.vlcSubtitleSelection = .embedded(trackId: track.id)
                    self.subtitleEntries.removeAll()
                    self.updateVLCSubtitleOverlay(for: self.cachedPosition)
                    self.rendererSetSubtitleTrack(id: track.id)
                    self.rendererApplySubtitleStyle(self.currentSubtitleStyle())
                    self.updateSubtitleButtonAppearance()
                    self.updateSubtitleTracksMenu()
                    self.showMPVSubtitleMenu()
                    Logger.shared.log("[PlayerVC.Subtitles] user selected embedded subtitle id=\(track.id) name=\(track.name)", type: "Player")
                }
            })
        }
        sections.append(PlayerOverlayMenuSection(title: "Select Track", actions: trackActions))

        if isVLCOpenSubtitlesEnabled {
            sections.append(PlayerOverlayMenuSection(title: "OpenSubtitles", actions: openSubtitlesOverlayActions()))
        }

        if Settings.shared.enableVLCSubtitleEditMenu {
            sections.append(contentsOf: subtitleAppearanceOverlaySections())
        }

        showOverlayMenu(title: "Subtitles", kind: "subtitles", sections: sections)
    }

    private func openSubtitlesOverlayActions() -> [PlayerOverlayMenuAction] {
        if openSubtitlesFetchInProgress {
            return [makeOverlayAction(title: "Searching OpenSubtitles...", imageName: "hourglass", isEnabled: false) {}]
        }
        if openSubtitlesResults.isEmpty {
            if openSubtitlesSearchAttempted {
                return [
                    makeOverlayAction(title: "No OpenSubtitles results", imageName: "captions.bubble", isEnabled: false) {},
                    makeOverlayAction(title: "Refresh OpenSubtitles", imageName: "arrow.clockwise") { [weak self] in
                        self?.fetchOpenSubtitles(autoSelect: false, reason: "manual-refresh-empty", forceRefresh: true)
                        self?.hideOverlayMenu()
                    }
                ]
            }
            return [
                makeOverlayAction(title: "Search OpenSubtitles", imageName: "magnifyingglass") { [weak self] in
                    self?.fetchOpenSubtitles(autoSelect: false, reason: "manual-menu")
                    self?.hideOverlayMenu()
                }
            ]
        }

        var actions: [PlayerOverlayMenuAction] = [
            makeOverlayAction(title: "Refresh OpenSubtitles", imageName: "arrow.clockwise") { [weak self] in
                self?.fetchOpenSubtitles(autoSelect: false, reason: "manual-refresh", forceRefresh: true)
                self?.hideOverlayMenu()
            }
        ]
        actions.append(contentsOf: openSubtitlesResults.prefix(20).map { subtitle in
            makeOverlayAction(title: openSubtitleDisplayName(subtitle), imageName: "captions.bubble") { [weak self] in
                self?.loadOpenSubtitle(subtitle, userSelected: true)
                self?.hideOverlayMenu()
            }
        })
        return actions
    }

    private func subtitleAppearanceOverlaySections() -> [PlayerOverlayMenuSection] {
        let foregroundColors: [(String, UIColor)] = [
            ("White", .white),
            ("Yellow", .yellow),
            ("Cyan", .cyan),
            ("Green", .green),
            ("Magenta", .magenta)
        ]
        let strokeColors: [(String, UIColor)] = [
            ("Black", .black),
            ("Dark Gray", .darkGray),
            ("White", .white),
            ("None", .clear)
        ]
        let strokeWidths: [(String, CGFloat)] = [
            ("None", 0.0),
            ("Thin", 0.5),
            ("Normal", 1.0),
            ("Medium", 1.5),
            ("Thick", 2.0)
        ]
        let fontSizes: [(String, CGFloat)] = [
            ("Very Small", 20.0),
            ("Small", 24.0),
            ("Medium", 30.0),
            ("Large", 34.0),
            ("Extra Large", 38.0),
            ("Huge", 42.0),
            ("Extra Huge", 46.0)
        ]

        return [
            PlayerOverlayMenuSection(title: "Text Color", actions: foregroundColors.map { name, color in
                makeOverlayAction(title: name, imageName: "paintpalette", isSelected: subtitleModel.foregroundColor == color) { [weak self] in
                    self?.subtitleModel.foregroundColor = color
                    self?.updateCurrentSubtitleAppearance()
                    self?.showMPVSubtitleMenu()
                }
            }),
            PlayerOverlayMenuSection(title: "Stroke Color", actions: strokeColors.map { name, color in
                makeOverlayAction(title: name, imageName: "pencil.tip", isSelected: subtitleModel.strokeColor == color) { [weak self] in
                    self?.subtitleModel.strokeColor = color
                    self?.updateCurrentSubtitleAppearance()
                    self?.showMPVSubtitleMenu()
                }
            }),
            PlayerOverlayMenuSection(title: "Stroke Width", actions: strokeWidths.map { name, width in
                makeOverlayAction(title: name, imageName: "lineweight", isSelected: subtitleModel.strokeWidth == width) { [weak self] in
                    self?.subtitleModel.strokeWidth = width
                    self?.updateCurrentSubtitleAppearance()
                    self?.showMPVSubtitleMenu()
                }
            }),
            PlayerOverlayMenuSection(title: "Font Size", actions: fontSizes.map { name, size in
                makeOverlayAction(title: name, imageName: "textformat.size", isSelected: subtitleModel.fontSize == size) { [weak self] in
                    self?.subtitleModel.fontSize = size
                    self?.updateCurrentSubtitleAppearance()
                    self?.showMPVSubtitleMenu()
                }
            })
        ]
    }
    
    private func updateSubtitleTracksMenu() {
        let useCustomExternalOverlay = isVLCCustomSubtitleOverlayEnabled
        let externalTracks: [(Int, String)] = useCustomExternalOverlay
            ? subtitleURLs.enumerated().map { (index, _) in
                let name = index < subtitleNames.count ? subtitleNames[index] : "Subtitle \(index + 1)"
                return (index, name)
            }
            : []
        let canReadNativeTracks = !isVLCPlayer || canMutateVLCSubtitleTracks
        let nativeSubtitleTracks = canReadNativeTracks
            ? rendererGetSubtitleTrackDescriptors().filter { $0.id >= 0 && !isDisabledTrackName($0.name) }
            : []
        let embeddedTracks = nativeSubtitleTracks.map { ($0.id, $0.name) }
        let autoSelectableNativeTracks = nativeSubtitleTracks.filter { canAutoSelectNativeSubtitleTrack($0) }
        let autoSelectableEmbeddedTracks = autoSelectableNativeTracks.map { ($0.id, $0.name) }
        logSkippedMPVBitmapSubtitleTracksIfNeeded(nativeSubtitleTracks.filter { !canAutoSelectNativeSubtitleTrack($0) })

        Logger.shared.log("PlayerViewController: subtitle tracks external=\(externalTracks.count) embedded=\(embeddedTracks.count) autoSelectableNative=\(autoSelectableEmbeddedTracks.count) userSelected=\(userSelectedSubtitleTrack) renderer=\(vlcRenderer != nil ? "VLC" : "MPV")", type: "Player")

        // Always show the subtitle button so the user can view the menu even when empty
        subtitleButton.isHidden = false

        subtitleButton.showsMenuAsPrimaryAction = !usesOverlayPlayerMenus

        if restoreRequestedEmbeddedSubtitleTrackIfNeeded(from: embeddedTracks) {
            updateSubtitleButtonAppearance()
        }

        // Apply subtitle defaults while the user has not manually selected a track.
        if !userSelectedSubtitleTrack {
            let settings = Settings.shared
            if settings.enableSubtitlesByDefault {
                let preferredLang = settings.defaultSubtitleLanguage
                if let selectedEmbeddedTrack = preferredDefaultSubtitleTrack(from: autoSelectableEmbeddedTracks, preferredLang: preferredLang) {
                    if rendererGetCurrentSubtitleTrackId() != selectedEmbeddedTrack.0 {
                        rendererSetSubtitleTrack(id: selectedEmbeddedTrack.0)
                    }
                    userSelectedSubtitleTrack = true
                    setSubtitleVisible(true, persist: false)
                    rendererApplySubtitleStyle(currentSubtitleStyle(visible: true))
                    vlcSubtitleSelection = .embedded(trackId: selectedEmbeddedTrack.0)
                    Logger.shared.log("[PlayerVC.Subtitles] default selected embedded track id=\(selectedEmbeddedTrack.0) name=\(selectedEmbeddedTrack.1)", type: "Player")
                } else if let selectedExternalTrack = preferredDefaultSubtitleTrack(from: externalTracks, preferredLang: preferredLang) {
                    currentSubtitleIndex = selectedExternalTrack.0
                    loadCurrentSubtitle()
                    rendererDisableSubtitlesIfReady(reason: "default external subtitle")
                    updateVLCSubtitleOverlay(for: cachedPosition)
                    userSelectedSubtitleTrack = true
                    setSubtitleVisible(true, persist: false)
                    vlcSubtitleSelection = .external(index: selectedExternalTrack.0)
                    Logger.shared.log("[PlayerVC.Subtitles] default selected external track index=\(selectedExternalTrack.0)", type: "Player")
                } else if maybeUseOpenSubtitlesFallback(preferredLang: preferredLang) {
                    Logger.shared.log("[PlayerVC.Subtitles] OpenSubtitles fallback requested for preferredLang=\(preferredLang)", type: "Player")
                } else if !isVLCPlayer, let fallbackEmbeddedTrack = fallbackDefaultSubtitleTrack(from: autoSelectableEmbeddedTracks) {
                    if rendererGetCurrentSubtitleTrackId() != fallbackEmbeddedTrack.0 {
                        rendererSetSubtitleTrack(id: fallbackEmbeddedTrack.0)
                    }
                    userSelectedSubtitleTrack = true
                    setSubtitleVisible(true, persist: false)
                    rendererApplySubtitleStyle(currentSubtitleStyle(visible: true))
                    vlcSubtitleSelection = .embedded(trackId: fallbackEmbeddedTrack.0)
                    Logger.shared.log("[PlayerVC.Subtitles] default selected fallback MPV/native track id=\(fallbackEmbeddedTrack.0) name=\(fallbackEmbeddedTrack.1)", type: "Player")
                } else if let fallbackExternalTrack = fallbackDefaultSubtitleTrack(from: externalTracks) {
                    currentSubtitleIndex = fallbackExternalTrack.0
                    loadCurrentSubtitle()
                    rendererDisableSubtitlesIfReady(reason: "fallback external subtitle")
                    updateVLCSubtitleOverlay(for: cachedPosition)
                    userSelectedSubtitleTrack = true
                    setSubtitleVisible(true, persist: false)
                    vlcSubtitleSelection = .external(index: fallbackExternalTrack.0)
                    Logger.shared.log("[PlayerVC.Subtitles] default selected fallback external track index=\(fallbackExternalTrack.0)", type: "Player")
                }
            } else {
                rendererDisableSubtitlesIfReady(reason: "default subtitles off")
                subtitleEntries.removeAll()
                updateVLCSubtitleOverlay(for: cachedPosition)
                setSubtitleVisible(false, persist: false)
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

            let embeddedSubtitleActions: [UIAction] = nativeSubtitleTracks.map { track -> UIAction in
                let id = track.id
                let name = track.name
                let blocksMPVDefault = !canAutoSelectNativeSubtitleTrack(track)
                return UIAction(
                    title: blocksMPVDefault ? "\(name) [\(subtitleBitmapCodecLabel(track.codec))]" : name,
                    image: UIImage(systemName: blocksMPVDefault ? "exclamationmark.triangle" : "captions.bubble"),
                    attributes: blocksMPVDefault ? .disabled : [],
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
                    self.rendererApplySubtitleStyle(self.currentSubtitleStyle())
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
        var menuChildren: [UIMenuElement] = [trackMenu]
        if let openSubtitlesMenu = openSubtitlesMenu() {
            menuChildren.append(openSubtitlesMenu)
        }
        if Settings.shared.enableVLCSubtitleEditMenu {
            let appearanceMenu = createAppearanceMenu()
            menuChildren.append(appearanceMenu)
        }
        let subtitleMenu = UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: menuChildren)
        subtitleButton.menu = subtitleMenu
    }

    private func restoreRequestedEmbeddedSubtitleTrackIfNeeded(from embeddedTracks: [(Int, String)]) -> Bool {
        guard !isVLCPlayer,
              userSelectedSubtitleTrack,
              let requestedTrackId = lastRequestedEmbeddedSubtitleTrackId,
              let track = embeddedTracks.first(where: { $0.0 == requestedTrackId }),
              rendererGetCurrentSubtitleTrackId() != requestedTrackId else {
            return false
        }

        subtitleEntries.removeAll()
        vlcSubtitleSelection = .embedded(trackId: requestedTrackId)
        setSubtitleVisible(true, persist: false)
        rendererSetSubtitleTrack(id: requestedTrackId)
        rendererApplySubtitleStyle(currentSubtitleStyle(visible: true))
        Logger.shared.log("[PlayerVC.Subtitles] restored embedded track id=\(requestedTrackId) name=\(track.1) after MPV track refresh", type: "Player")
        return true
    }

    private func isDisabledTrackName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.contains("disable") || lower.contains("off") || lower.contains("none")
    }

    private func canAutoSelectNativeSubtitleTrack(_ track: SubtitleTrackDescriptor) -> Bool {
        guard let mpvRenderer else { return true }
        if mpvRenderer.supportsBitmapSubtitleTracks { return true }
        return !isMPVBitmapSubtitleTrack(track)
    }

    private func isMPVBitmapSubtitleTrack(_ track: SubtitleTrackDescriptor) -> Bool {
        isBitmapSubtitleCodec(track.codec)
    }

    private func isBitmapSubtitleCodec(_ codec: String) -> Bool {
        let lower = codec.lowercased()
        return lower.contains("pgs")
            || lower.contains("hdmv")
            || lower.contains("dvd")
            || lower.contains("vobsub")
            || lower.contains("dvb")
            || lower.contains("xsub")
    }

    private func subtitleBitmapCodecLabel(_ codec: String) -> String {
        let lower = codec.lowercased()
        if lower.contains("pgs") || lower.contains("hdmv") { return "PGS" }
        if lower.contains("dvd") || lower.contains("vobsub") { return "VobSub" }
        if lower.contains("dvb") { return "DVB" }
        if lower.contains("xsub") { return "XSUB" }
        return "Bitmap"
    }

    private func logSkippedMPVBitmapSubtitleTracksIfNeeded(_ tracks: [SubtitleTrackDescriptor]) {
        guard mpvRenderer != nil else { return }
        let summary = tracks
            .map { "#\($0.id):\($0.codec.isEmpty ? "unknown" : $0.codec):\($0.name)" }
            .joined(separator: "|")
        guard summary != lastSkippedMPVBitmapSubtitleSummary else { return }
        lastSkippedMPVBitmapSubtitleSummary = summary
        guard !summary.isEmpty else { return }
        Logger.shared.log("[PlayerVC.Subtitles] skipping MPV bitmap subtitle tracks for default/manual selection reason=unsupported renderer path: \(summary)", type: "Player")
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

        let bestScore = sorted.first?.1 ?? -999
        let best = bestScore > 0 ? sorted.first?.0 : nil
        Logger.shared.log("PlayerViewController: default subtitles preferredLang=\(preferredLang) best=\(best?.1 ?? "nil") score=\(bestScore)", type: "Player")
        return best
    }

    private func fallbackDefaultSubtitleTrack(from tracks: [(Int, String)]) -> (Int, String)? {
        return tracks.first { !isDisabledTrackName($0.1) }
    }

    private func openSubtitleMatchesPreferredLanguage(_ subtitle: StremioSubtitle, preferredLang: String) -> Bool {
        let tokens = languageTokens(for: preferredLang)
        guard !tokens.isEmpty else { return true }
        let fields = [
            subtitle.lang,
            subtitle.name,
            subtitle.title,
            subtitle.id
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        return tokens.contains { fields.contains($0) }
    }

    private func preferredOpenSubtitle(from subtitles: [StremioSubtitle], preferredLang: String) -> StremioSubtitle? {
        let valid = subtitles.filter { $0.url?.isEmpty == false }
        if let exact = valid.first(where: { openSubtitleMatchesPreferredLanguage($0, preferredLang: preferredLang) }) {
            return exact
        }
        return nil
    }

    private func openSubtitlesMenu() -> UIMenu? {
        guard isVLCOpenSubtitlesEnabled else { return nil }

        var actions: [UIMenuElement] = []

        if openSubtitlesFetchInProgress {
            actions.append(UIAction(title: "Searching OpenSubtitles...", image: UIImage(systemName: "hourglass"), attributes: .disabled) { _ in })
        } else if openSubtitlesResults.isEmpty {
            if openSubtitlesSearchAttempted {
                actions.append(UIAction(title: "No OpenSubtitles results", image: UIImage(systemName: "captions.bubble"), attributes: .disabled) { _ in })
                actions.append(UIAction(title: "Refresh OpenSubtitles", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.fetchOpenSubtitles(autoSelect: false, reason: "manual-refresh-empty", forceRefresh: true)
                })
            } else {
                actions.append(UIAction(title: "Search OpenSubtitles", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                    self?.fetchOpenSubtitles(autoSelect: false, reason: "manual-menu")
                })
            }
        } else {
            actions.append(UIAction(title: "Refresh OpenSubtitles", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.fetchOpenSubtitles(autoSelect: false, reason: "manual-refresh", forceRefresh: true)
            })

            let subtitleActions: [UIMenuElement] = openSubtitlesResults.prefix(20).map { subtitle in
                UIAction(
                    title: openSubtitleDisplayName(subtitle),
                    image: UIImage(systemName: "captions.bubble")
                ) { [weak self] _ in
                    self?.loadOpenSubtitle(subtitle, userSelected: true)
                }
            }
            actions.append(contentsOf: subtitleActions)
        }

        return UIMenu(title: "OpenSubtitles", image: UIImage(systemName: "globe"), children: actions)
    }

    private func openSubtitleDisplayName(_ subtitle: StremioSubtitle) -> String {
        let language = subtitle.lang?.uppercased()
        let base = subtitle.displayName
        if let language, !language.isEmpty, !base.lowercased().contains(language.lowercased()) {
            return "\(language) - \(base)"
        }
        return base
    }

    private func maybeUseOpenSubtitlesFallback(preferredLang: String) -> Bool {
        guard canAutoApplyOpenSubtitlesFallback() else { return false }

        if let subtitle = preferredOpenSubtitle(from: openSubtitlesResults, preferredLang: preferredLang) {
            openSubtitlesFallbackAttempted = true
            loadOpenSubtitle(subtitle, userSelected: false)
            return true
        }

        guard !openSubtitlesFallbackAttempted,
              !openSubtitlesFetchInProgress else { return false }
        openSubtitlesFallbackAttempted = true
        fetchOpenSubtitles(autoSelect: true, reason: "auto-fallback")
        return true
    }

    private func canAutoApplyOpenSubtitlesFallback() -> Bool {
        if let deadline = vlcExternalSubtitlePriorityDeadline, Date() < deadline {
            return false
        }
        return isVLCOpenSubtitlesEnabled
            && Settings.shared.vlcOpenSubtitlesAutoFallbackEnabled
            && Settings.shared.enableSubtitlesByDefault
            && !userSelectedSubtitleTrack
    }

    private func fetchOpenSubtitles(autoSelect: Bool, reason: String, forceRefresh: Bool = false) {
        guard isVLCOpenSubtitlesEnabled else { return }
        if openSubtitlesFetchInProgress { return }
        if !forceRefresh, !openSubtitlesResults.isEmpty {
            if autoSelect,
               canAutoApplyOpenSubtitlesFallback(),
               let subtitle = preferredOpenSubtitle(from: openSubtitlesResults, preferredLang: Settings.shared.defaultSubtitleLanguage) {
                openSubtitlesFallbackAttempted = true
                loadOpenSubtitle(subtitle, userSelected: false)
            }
            return
        }

        openSubtitlesFetchTask?.cancel()
        openSubtitlesFetchInProgress = true
        openSubtitlesSearchAttempted = true
        updateSubtitleTracksMenu()

        openSubtitlesFetchTask = Task { [weak self] in
            guard let self else { return }
            let results = await self.fetchOpenSubtitlesResults(reason: reason)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.openSubtitlesFetchInProgress = false
                self.openSubtitlesResults = results
                Logger.shared.log("[PlayerVC.OpenSubtitles] fetch complete reason=\(reason) count=\(results.count)", type: "Player")
                if autoSelect,
                   self.canAutoApplyOpenSubtitlesFallback(),
                   let subtitle = self.preferredOpenSubtitle(from: results, preferredLang: Settings.shared.defaultSubtitleLanguage) {
                    self.openSubtitlesFallbackAttempted = true
                    self.loadOpenSubtitle(subtitle, userSelected: false)
                } else {
                    self.updateSubtitleTracksMenu()
                }
            }
        }
    }

    private func prefetchOpenSubtitlesIfEnabled(reason: String) {
        guard isVLCOpenSubtitlesEnabled else { return }
        guard !openSubtitlesFetchInProgress,
              openSubtitlesResults.isEmpty,
              !openSubtitlesSearchAttempted else {
            return
        }
        guard openSubtitlesLookupMetadata() != nil else { return }
        fetchOpenSubtitles(autoSelect: false, reason: "auto-prefetch-\(reason)")
    }

    private func fetchOpenSubtitlesResults(reason: String) async -> [StremioSubtitle] {
        let metadata = await MainActor.run { openSubtitlesLookupMetadata() }
        guard let metadata else {
            Logger.shared.log("[PlayerVC.OpenSubtitles] skipped \(reason): missing metadata", type: "Player")
            return []
        }

        let resolvedImdbId: String?
        if let imdbId = metadata.imdbId, !imdbId.isEmpty {
            resolvedImdbId = imdbId
        } else {
            resolvedImdbId = await resolveOpenSubtitlesIMDbId(tmdbId: metadata.tmdbId, type: metadata.type)
        }

        guard let resolvedImdbId, !resolvedImdbId.isEmpty else {
            Logger.shared.log("[PlayerVC.OpenSubtitles] skipped \(reason): missing IMDb ID for tmdbId=\(metadata.tmdbId)", type: "Player")
            return []
        }

        do {
            let subtitles = try await StremioClient.shared.fetchOpenSubtitlesV3(
                tmdbId: metadata.tmdbId,
                imdbId: resolvedImdbId,
                type: metadata.type,
                season: metadata.season,
                episode: metadata.episode
            )
            return dedupeOpenSubtitles(subtitles)
        } catch {
            Logger.shared.log("[PlayerVC.OpenSubtitles] fetch failed \(reason): \(error.localizedDescription)", type: "Error")
            return []
        }
    }

    private func openSubtitlesLookupMetadata() -> (tmdbId: Int, imdbId: String?, type: String, season: Int?, episode: Int?)? {
        guard let info = mediaInfo else { return nil }
        switch info {
        case .movie(let id, _, _, _):
            return (id, imdbId, "movie", nil, nil)
        case .episode(let showId, let seasonNumber, let episodeNumber, _, _, _):
            return (
                showId,
                imdbId,
                "series",
                originalTMDBSeasonNumber ?? seasonNumber,
                originalTMDBEpisodeNumber ?? episodeNumber
            )
        }
    }

    private func resolveOpenSubtitlesIMDbId(tmdbId: Int, type: String) async -> String? {
        do {
            if type == "movie" {
                return try await TMDBService.shared.getMovieDetails(id: tmdbId).imdbId
            }
            return try await TMDBService.shared.getTVShowDetails(id: tmdbId).externalIds?.imdbId
        } catch {
            Logger.shared.log("[PlayerVC.OpenSubtitles] IMDb resolve failed tmdbId=\(tmdbId) type=\(type): \(error.localizedDescription)", type: "Player")
            return nil
        }
    }

    private func dedupeOpenSubtitles(_ subtitles: [StremioSubtitle]) -> [StremioSubtitle] {
        var seen = Set<String>()
        var result: [StremioSubtitle] = []
        for subtitle in subtitles {
            guard let url = subtitle.url, !url.isEmpty else { continue }
            if seen.insert(url).inserted {
                result.append(subtitle)
            }
        }
        let preferredLang = Settings.shared.defaultSubtitleLanguage
        return result.sorted { lhs, rhs in
            let lhsMatch = openSubtitleMatchesPreferredLanguage(lhs, preferredLang: preferredLang)
            let rhsMatch = openSubtitleMatchesPreferredLanguage(rhs, preferredLang: preferredLang)
            if lhsMatch != rhsMatch { return lhsMatch && !rhsMatch }
            return openSubtitleDisplayName(lhs) < openSubtitleDisplayName(rhs)
        }
    }

    private func loadOpenSubtitle(_ subtitle: StremioSubtitle, userSelected: Bool) {
        guard let urlString = subtitle.url, !urlString.isEmpty else { return }
        guard openSubtitlesLoadedURLs.insert(urlString).inserted || userSelected else { return }

        let displayName = "OpenSubtitles - \(openSubtitleDisplayName(subtitle))"
        let subtitleIndex: Int
        if let existingIndex = subtitleURLs.firstIndex(of: urlString) {
            subtitleIndex = existingIndex
        } else {
            subtitleURLs.append(urlString)
            subtitleNames.append(displayName)
            subtitleIndex = subtitleURLs.count - 1
        }

        setSubtitleVisible(true, persist: userSelected)
        if userSelected {
            userSelectedSubtitleTrack = true
        }

        if isVLCCustomSubtitleOverlayEnabled {
            currentSubtitleIndex = subtitleIndex
            vlcSubtitleSelection = .external(index: subtitleIndex)
            rendererDisableSubtitlesIfReady(reason: "OpenSubtitles custom overlay")
            loadCurrentSubtitle()
            updateVLCSubtitleOverlay(for: cachedPosition)
        } else {
            rendererLoadExternalSubtitles(urls: [urlString], names: [displayName], enforce: true)
            vlcExternalSubtitlesLoadedNatively = true
            vlcExternalSubtitlePriorityDeadline = nil
            vlcSubtitleSelection = .none
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.updateSubtitleTracksMenuWhenReady()
            }
        }

        Logger.shared.log("[PlayerVC.OpenSubtitles] loaded subtitle name=\(displayName) userSelected=\(userSelected)", type: "Player")
        updateSubtitleButtonAppearance()
        updateSubtitleTracksMenu()
    }

    @objc private func handleUserDefaultsDidChange() {
        guard isVLCPlayer || mpvRenderer != nil else { return }
        if isVLCPlaybackStartupInProgress {
            Logger.shared.log("[PlayerVC.Settings] UserDefaults changed during VLC startup; deferring subtitle/settings rebuild", type: "Player")
#if !os(tvOS)
            updateBrightnessControlVisibility()
            updateVolumeControlVisibility()
#endif
            updateEpisodeBrowserButtonVisibility()
            updatePerformanceOverlayVisibility()
            return
        }
        Logger.shared.log("[PlayerVC.Settings] UserDefaults changed; evaluating in-app player subtitle mode", type: "Player")
        configureSeekButtons()
        if isVLCPlayer {
            applyVLCSubtitleModeSettingIfNeeded()
            applyVLCSubtitleOverlayPositionSetting()
        } else {
            rendererApplySubtitleStyle(currentSubtitleStyle())
        }
        vlcRenderer?.handlePictureInPictureSettingChanged()
        updatePiPButtonVisibility()
        updateEpisodeBrowserButtonVisibility()
        updatePerformanceOverlayVisibility()
        updateSubtitleTracksMenu()
        prefetchOpenSubtitlesIfEnabled(reason: "settings")
#if !os(tvOS)
        updateBrightnessControlVisibility()
        updateVolumeControlVisibility()
#endif
    }

    private func applyVLCSubtitleModeSettingIfNeeded() {
        let customOverlayEnabled = isVLCCustomSubtitleOverlayEnabled
        if lastKnownVLCCustomSubtitleOverlayEnabled == customOverlayEnabled {
            return
        }
        Logger.shared.log("[PlayerVC.Subtitles] mode toggle detected customOverlayEnabled=\(customOverlayEnabled) subtitleURLs=\(subtitleURLs.count) isVisible=\(subtitleModel.isVisible)", type: "Player")
        lastKnownVLCCustomSubtitleOverlayEnabled = customOverlayEnabled

        if customOverlayEnabled {
            rendererDisableSubtitlesIfReady(reason: "custom overlay mode enabled")
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
                    rendererLoadExternalSubtitles(urls: subtitleURLs, names: subtitleNames)
                    vlcExternalSubtitlesLoadedNatively = true
                    vlcExternalSubtitlePriorityDeadline = Date().addingTimeInterval(1.2)
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
        vlcExternalSubtitlePriorityDeadline = nil
        
        if !urls.isEmpty {
            Logger.shared.log("PlayerViewController: loadSubtitles count=\(urls.count) renderer=\(vlcRenderer != nil ? "VLC" : "MPV")", type: "Stream")
            subtitleButton.isHidden = false
            currentSubtitleIndex = 0
            let enableByDefault = Settings.shared.enableSubtitlesByDefault
            setSubtitleVisible(enableByDefault, persist: false)
            
            // VLC and native MPV both hand external subtitles to the renderer.
            if vlcRenderer != nil {
                if isVLCCustomSubtitleOverlayEnabled {
                    Logger.shared.log("[PlayerVC.Subtitles] loadSubtitles path=VLC customOverlay", type: "Stream")
                    rendererDisableSubtitlesIfReady(reason: "load subtitles custom overlay")
                    updateSubtitleTracksMenu()
                    updateVLCSubtitleOverlay(for: cachedPosition)
                } else {
                    Logger.shared.log("[PlayerVC.Subtitles] loadSubtitles path=VLC native", type: "Stream")
                    rendererLoadExternalSubtitles(urls: urls, names: names)
                    vlcExternalSubtitlesLoadedNatively = true
                    vlcExternalSubtitlePriorityDeadline = Date().addingTimeInterval(1.2)
                    // Update subtitle menu after VLC loads the external subs
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.updateSubtitleTracksMenu()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self else { return }
                        guard self.canMutateVLCSubtitleTracks else {
                            self.updateSubtitleTracksMenuWhenReady()
                            return
                        }
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
                rendererLoadExternalSubtitles(urls: urls, names: names)
                rendererApplySubtitleStyle(currentSubtitleStyle(visible: enableByDefault))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.updateSubtitleTracksMenuWhenReady()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.updateSubtitleTracksMenuWhenReady()
                }
            }
            
            updateSubtitleButtonAppearance()
            updateSubtitleTracksMenu()
        } else {
            Logger.shared.log("No subtitle URLs to load", type: "Info")
        }
    }

    private func currentExternalSubtitleName() -> String? {
        guard currentSubtitleIndex < subtitleURLs.count else { return nil }
        if currentSubtitleIndex < subtitleNames.count {
            return subtitleNames[currentSubtitleIndex]
        }
        return "Subtitle \(currentSubtitleIndex + 1)"
    }

    private func fallbackCurrentSubtitleToRenderer(reason: String) {
        guard currentSubtitleIndex < subtitleURLs.count else { return }
        let urlString = subtitleURLs[currentSubtitleIndex]
        let subtitleName = currentExternalSubtitleName()
        Logger.shared.log("[PlayerVC.Subtitles] falling back to renderer subtitle path reason=\(reason) index=\(currentSubtitleIndex) renderer=\(isVLCPlayer ? "VLC" : "MPV")", type: "Player")

        subtitleEntries.removeAll()
        updateVLCSubtitleOverlay(for: cachedPosition)
        rendererLoadExternalSubtitles(urls: [urlString], names: subtitleName.map { [$0] }, enforce: true)
        rendererApplySubtitleStyle(currentSubtitleStyle(visible: true))

        if isVLCPlayer {
            vlcExternalSubtitlesLoadedNatively = true
            vlcExternalSubtitlePriorityDeadline = Date().addingTimeInterval(1.2)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateSubtitleTracksMenuWhenReady()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.updateSubtitleTracksMenuWhenReady()
        }
    }
    
    private func loadCurrentSubtitle() {
        guard currentSubtitleIndex < subtitleURLs.count else { return }
        let urlString = subtitleURLs[currentSubtitleIndex]
        Logger.shared.log("[PlayerVC.Subtitles] loadCurrentSubtitle index=\(currentSubtitleIndex) renderer=\(isVLCPlayer ? "VLC" : "MPV")", type: "Stream")

        if !isVLCPlayer {
            let subtitleName = currentSubtitleIndex < subtitleNames.count ? subtitleNames[currentSubtitleIndex] : nil
            rendererLoadExternalSubtitles(urls: [urlString], names: subtitleName.map { [$0] }, enforce: true)
            rendererApplySubtitleStyle(currentSubtitleStyle(visible: true))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.updateSubtitleTracksMenuWhenReady()
            }
            return
        }

        // Handle local file:// URLs directly (e.g. downloaded media subtitles)
        if let url = URL(string: urlString), url.isFileURL {
            Logger.shared.log("[PlayerVC.Subtitles] Loading local subtitle file: \(url.path)", type: "Stream")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    let data = try Data(contentsOf: url)
                    guard let subtitleContent = String(data: data, encoding: .utf8) else {
                        Logger.shared.log("Failed to decode local subtitle data as UTF-8", type: "Error")
                        DispatchQueue.main.async { [weak self] in
                            self?.fallbackCurrentSubtitleToRenderer(reason: "local-decode-failed")
                        }
                        return
                    }
                    self.parseAndDisplaySubtitles(subtitleContent)
                } catch {
                    Logger.shared.log("Failed to read local subtitle file: \(error.localizedDescription)", type: "Error")
                    DispatchQueue.main.async { [weak self] in
                        self?.fallbackCurrentSubtitleToRenderer(reason: "local-read-failed")
                    }
                }
            }
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
                    DispatchQueue.main.async { [weak self] in
                        self?.fallbackCurrentSubtitleToRenderer(reason: "download-error")
                    }
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    Logger.shared.log("Subtitle download response: \(httpResponse.statusCode)", type: "Info")
                    if httpResponse.statusCode != 200 {
                        Logger.shared.log("Subtitle download failed with status \(httpResponse.statusCode)", type: "Error")
                        DispatchQueue.main.async { [weak self] in
                            self?.fallbackCurrentSubtitleToRenderer(reason: "http-\(httpResponse.statusCode)")
                        }
                        return
                    }
                }
                
                guard let data = data, let subtitleContent = String(data: data, encoding: .utf8) else {
                    Logger.shared.log("Failed to parse subtitle data (size: \(data?.count ?? 0) bytes)", type: "Error")
                    DispatchQueue.main.async { [weak self] in
                        self?.fallbackCurrentSubtitleToRenderer(reason: "download-decode-failed")
                    }
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
        let entries = SubtitleLoader.parseSubtitles(from: content, fontSize: subtitleModel.fontSize, foregroundColor: subtitleModel.foregroundColor)

        if !isVLCPlayer {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.subtitleEntries = entries
                Logger.shared.log("Loaded \(entries.count) MPV subtitle overlay entries", type: "Info")
                if entries.isEmpty {
                    self.fallbackCurrentSubtitleToRenderer(reason: "mpv-overlay-parse-empty")
                }
            }
            return
        }

        guard isVLCCustomSubtitleOverlayEnabled else {
            Logger.shared.log("[PlayerVC.Subtitles] ignoring manual subtitle parse because VLC native subtitles are active", type: "Player")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.subtitleEntries = entries
            Logger.shared.log("Loaded \(self.subtitleEntries.count) subtitle entries", type: "Info")
            if entries.isEmpty {
                self.fallbackCurrentSubtitleToRenderer(reason: "custom-overlay-parse-empty")
                return
            }
            self.updateVLCSubtitleOverlay(for: self.cachedPosition)
        }
    }
    
    @objc private func subtitleButtonTapped() {
        if usesOverlayPlayerMenus {
            showMPVSubtitleMenu()
            return
        }

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
                    durationKnown: model.durationIsKnown,
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
        if lower == "mpv" || message.hasPrefix("[MPV ") || message.hasPrefix("[MPVNativeRenderer]") || message.hasPrefix("[MPVPiPBridge]") {
            return
        }
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
        logSharedPlayerControl("container tapped controlsVisible=\(controlsVisible)")
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
        updateVolumeControlVisibility()

        // Ensure controls sit above the video layer/view
        videoContainer.bringSubviewToFront(controlsOverlayView)
        videoContainer.bringSubviewToFront(overlayMenuDismissView)
        videoContainer.bringSubviewToFront(overlayMenuPanelView)
        videoContainer.bringSubviewToFront(centerPlayPauseButton)
        videoContainer.bringSubviewToFront(progressContainer)
        videoContainer.bringSubviewToFront(closeButton)
        videoContainer.bringSubviewToFront(pipButton)
        videoContainer.bringSubviewToFront(playerTitleLabel)
        videoContainer.bringSubviewToFront(skipBackwardButton)
        videoContainer.bringSubviewToFront(skipForwardButton)
        videoContainer.bringSubviewToFront(speedIndicatorLabel)
        videoContainer.bringSubviewToFront(performanceOverlayLabel)
        videoContainer.bringSubviewToFront(subtitleButton)
        if supportsSharedPlayerControls {
            videoContainer.bringSubviewToFront(episodeBrowserButton)
            videoContainer.bringSubviewToFront(speedButton)
            videoContainer.bringSubviewToFront(audioButton)
        }
#if !os(tvOS)
        videoContainer.bringSubviewToFront(brightnessContainer)
        videoContainer.bringSubviewToFront(volumeContainer)
        bringTimedActionButtonsToFront()
#endif
        if let browserView = episodeBrowserHostingController?.view {
            videoContainer.bringSubviewToFront(browserView)
        }
        
        DispatchQueue.main.async {
            self.controlsOverlayView.isHidden = false
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                self.centerPlayPauseButton.alpha = 1.0
                self.controlsOverlayView.alpha = 1.0
                self.progressContainer.alpha = 1.0
                self.closeButton.alpha = 1.0
                self.pipButton.alpha = self.pipButton.isHidden ? 0.0 : 1.0
                self.playerTitleLabel.alpha = self.playerTitleLabel.text?.isEmpty == false ? 1.0 : 0.0
                self.skipBackwardButton.alpha = 1.0
                self.skipForwardButton.alpha = 1.0
                if !self.subtitleButton.isHidden {
                    self.subtitleButton.alpha = 1.0
                }
                if self.supportsSharedPlayerControls {
                    if !self.episodeBrowserButton.isHidden {
                        self.episodeBrowserButton.alpha = 1.0
                    }
                    self.speedButton.alpha = 1.0
                    if !self.audioButton.isHidden {
                        self.audioButton.alpha = 1.0
                    }
                }
#if !os(tvOS)
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
        hideOverlayMenu(animated: false)
#if !os(tvOS)
        isBrightnessControlActive = false
        isVolumeControlActive = false
#endif
        
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn]) {
                self.centerPlayPauseButton.alpha = 0.0
                self.controlsOverlayView.alpha = 0.0
                self.progressContainer.alpha = 0.0
                self.closeButton.alpha = 0.0
                self.pipButton.alpha = 0.0
                self.playerTitleLabel.alpha = 0.0
                self.skipBackwardButton.alpha = 0.0
                self.skipForwardButton.alpha = 0.0
                self.subtitleButton.alpha = 0.0
                if self.supportsSharedPlayerControls {
                    self.episodeBrowserButton.alpha = 0.0
                    self.speedButton.alpha = 0.0
                    self.audioButton.alpha = 0.0
                }
#if !os(tvOS)
                self.brightnessContainer.alpha = 0.0
                self.volumeContainer.alpha = 0.0
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
                self.updateBrightnessControlVisibility()
                self.updateVolumeControlVisibility()
#endif
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateBrightnessControlVisibility()
            self?.updateVolumeControlVisibility()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if isEpisodeBrowserVisible {
            return false
        }

        if let touchedView = touch.view,
           isInteractivePlayerControl(touchedView) {
            return false
        }

        #if !os(tvOS)
        if isBrightnessControlEnabled && !brightnessContainer.isHidden && brightnessContainer.alpha > 0.01 {
            let location = touch.location(in: brightnessContainer)
            if brightnessContainer.bounds.contains(location) {
                return false
            }
        }
        if isVolumeControlEnabled && !volumeContainer.isHidden && volumeContainer.alpha > 0.01 {
            let location = touch.location(in: volumeContainer)
            if volumeContainer.bounds.contains(location) {
                return false
            }
        }
        #endif
        
        // Filter double-tap gestures by screen side
        let location = touch.location(in: videoContainer)
        let isLeftSide = location.x < videoContainer.bounds.width / 2
        
        if gestureRecognizer === leftDoubleTapGesture {
            return isDoubleTapSeekEnabled && isLeftSide
        } else if gestureRecognizer === rightDoubleTapGesture {
            return isDoubleTapSeekEnabled && !isLeftSide
        }
        
        return true
    }

    private func isInteractivePlayerControl(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate is UIControl {
                return true
            }
            if candidate === progressContainer
                || candidate === brightnessContainer
                || candidate === volumeContainer
                || candidate === overlayMenuDismissView
                || candidate === overlayMenuPanelView
                || candidate === errorBanner {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if isEpisodeBrowserVisible {
            return false
        }

#if !os(tvOS)
        if gestureRecognizer === brightnessPanGesture {
            guard isBrightnessControlEnabled else { return false }
            let location = gestureRecognizer.location(in: videoContainer)
            let velocity = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: videoContainer) ?? .zero
            return location.x <= videoContainer.bounds.width * 0.28 && abs(velocity.y) >= abs(velocity.x)
        }

        if gestureRecognizer === volumePanGesture {
            guard isVolumeControlEnabled else { return false }
            let location = gestureRecognizer.location(in: videoContainer)
            let velocity = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: videoContainer) ?? .zero
            return location.x >= videoContainer.bounds.width * 0.72 && abs(velocity.y) >= abs(velocity.x)
        }
#endif
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
#if !os(tvOS)
        if gestureRecognizer === brightnessPanGesture || otherGestureRecognizer === brightnessPanGesture {
            return true
        }
        if gestureRecognizer === volumePanGesture || otherGestureRecognizer === volumePanGesture {
            return true
        }
#endif
        return false
    }
    
    @objc private func closeTapped() {
        if isClosing { return }
        isClosing = true
        let isAnyPiPActive = rendererIsPictureInPictureActive()
        logSharedPlayerControl("closeTapped; pipActive=\(isAnyPiPActive); mediaInfo=\(String(describing: mediaInfo))")
        dismissEpisodeBrowser(animated: false)
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
            if self.vlcRenderer?.isPictureInPictureActive == true {
                self.vlcRenderer?.stopPictureInPicture()
            }

            self.rendererStop()
            self.logSharedPlayerControl("renderer.stop called from closeTapped")
            self.postPlayerDidCloseNotification()
        }

        if let presenter = presentingViewController {
            presenter.dismiss(animated: true) {
                teardownAndStop()
                self.dispatchPendingNextEpisodeRequestIfNeeded()
            }
        } else {
            dismiss(animated: true) {
                teardownAndStop()
                self.dispatchPendingNextEpisodeRequestIfNeeded()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            teardownAndStop()
            self.dispatchPendingNextEpisodeRequestIfNeeded()
        }
    }

    private func postPlayerDidCloseNotification() {
        var userInfo: [String: Any] = [:]
        if let mediaInfo {
            switch mediaInfo {
            case .movie(let id, _, _, _):
                userInfo["tmdbId"] = id
                userInfo["isMovie"] = true
            case .episode(let showId, _, _, _, _, _):
                userInfo["tmdbId"] = showId
                userInfo["isMovie"] = false
            }
        }
        NotificationCenter.default.post(name: .playerDidClose, object: self, userInfo: userInfo)
    }
    
    @objc private func pipTapped() {
        if let vlc = vlcRenderer {
            guard Settings.shared.vlcPiPEnabled else {
                Logger.shared.log("[PlayerVC.PiP] VLC button ignored because PiP setting is off", type: "Player")
                updatePiPButtonVisibility()
                return
            }
            Logger.shared.log("[PlayerVC.PiP] VLC button tap active=\(vlc.isPictureInPictureActive) available=\(vlc.isPictureInPictureAvailable)", type: "Player")
            if vlc.isPictureInPictureActive {
                vlc.stopPictureInPicture()
            } else if vlc.isPictureInPictureAvailable {
                _ = vlc.startPictureInPicture()
            } else {
                Logger.shared.log("[PlayerVC.PiP] VLC start blocked: native PiP controller not ready", type: "Player")
            }
            updatePiPButtonVisibility()
            return
        }
        guard let pip = pipController else { return }
        logPictureInPicture("button tap state active=\(pip.isPictureInPictureActive) possible=\(pip.isPictureInPicturePossible) supported=\(pip.isPictureInPictureSupported) isVLC=\(isVLCPlayer)")
        if pip.isPictureInPictureActive {
            logPictureInPicture("stopping PiP from button")
            pip.stopPictureInPicture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak pip] in
                guard let self, let pip, !pip.isPictureInPictureActive else { return }
                self.logPictureInPicture("MPV PiP stop timeout reached inactive state; restoring foreground")
                self.rendererFinishPictureInPicture()
                self.updatePiPButtonVisibility()
            }
        } else {
            startMPVPictureInPictureWhenPossible(source: "button")
        }
    }

    private func startMPVPictureInPictureWhenPossible(source: String) {
        guard let pip = pipController else { return }
        guard !pip.isPictureInPictureActive else {
            logPictureInPicture("start ignored source=\(source): PiP already active")
            return
        }
        mpvPiPStartAttemptID += 1
        let attemptID = mpvPiPStartAttemptID
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        logPictureInPicture("prepare MPV PiP begin source=\(source) attemptID=\(attemptID) appState=\(appState) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) ready=\(playbackDidStart)")
        let primed = prepareMPVPictureInPictureRenderer(source: source, activateLayer: false)
        logPictureInPicture("prepare MPV PiP end source=\(source) attemptID=\(attemptID) primed=\(primed) subs={\(subtitlePictureInPictureDebugSnapshot())}")
        attemptMPVPictureInPictureStart(source: source, attemptID: attemptID, attempt: 0)
    }

    private func attemptMPVPictureInPictureStart(source: String, attemptID: Int, attempt: Int) {
        guard attemptID == mpvPiPStartAttemptID else { return }
        guard let pip = pipController else { return }
        rendererPrimePictureInPictureFrames(reason: "\(source)-attempt-\(attempt)")
        pip.updatePlaybackState()
        let primed = rendererIsPictureInPicturePrimed()
        let snapshot = (attempt <= 2 || attempt % 5 == 0) ? " renderer={\(rendererPictureInPictureDebugSnapshot())}" : ""
        logPictureInPicture("MPV PiP attempt source=\(source) attempt=\(attempt) active=\(pip.isPictureInPictureActive) possible=\(pip.isPictureInPicturePossible) supported=\(pip.isPictureInPictureSupported) primed=\(primed)\(snapshot)")

        if pip.isPictureInPicturePossible && primed && !pip.isPictureInPictureActive {
            logPictureInPicture("starting MPV PiP source=\(source) attempt=\(attempt)")
            rendererActivatePictureInPictureLayer()
            pip.startPictureInPicture()
            scheduleMPVPictureInPictureRendererWatchdog(source: source, attemptID: attemptID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak pip] in
                guard let self,
                      attemptID == self.mpvPiPStartAttemptID,
                      let pip,
                      !pip.isPictureInPictureActive else { return }
                self.logPictureInPicture("MPV PiP start timed out without active state source=\(source) attempt=\(attempt); restoring foreground")
                self.mpvAppExitPiPStartRequested = false
                self.rendererFinishPictureInPicture()
                self.updatePiPButtonVisibility()
            }
            return
        }

        if pip.isPictureInPictureActive {
            logPictureInPicture("MPV PiP already active source=\(source) attempt=\(attempt)")
            return
        }

        guard attempt < 18 else {
            logPictureInPicture("MPV start blocked after retries source=\(source) possible=\(pip.isPictureInPicturePossible) supported=\(pip.isPictureInPictureSupported) primed=\(primed) renderer={\(rendererPictureInPictureDebugSnapshot())}")
            rendererFinishPictureInPicture()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.attemptMPVPictureInPictureStart(source: source, attemptID: attemptID, attempt: attempt + 1)
        }
    }

    private func updatePosition(_ position: Double, duration: Double) {

        let safePosition: Double
        if position.isFinite, position >= 0 {
            safePosition = position
        } else {
            safePosition = max(0, cachedPosition)
        }

        // Newer VLCKit builds can temporarily report a tiny/unknown duration while
        // valid playback time is already advancing. Treat that as unknown instead
        // of letting the slider collapse to the end of a 1-second range.
        let minimumReliableDuration = 5.0
        let mpvBridgeDurationLooksLikeWindow = isMPVTransportBridgePlaybackActive
            && !isVLCPlayer
            && mediaInfo != nil
            && duration.isFinite
            && duration > 0
            && duration < 60
        let reportedDurationIsReliable = duration.isFinite
            && duration >= minimumReliableDuration
            && safePosition <= duration + 2.0
            && !mpvBridgeDurationLooksLikeWindow
        let cachedDurationIsReliable = cachedDuration.isFinite
            && cachedDuration >= minimumReliableDuration
            && safePosition <= cachedDuration + 2.0
            && !mpvBridgeDurationLooksLikeWindow
        let effectiveDuration: Double
        if reportedDurationIsReliable, cachedDurationIsReliable {
            effectiveDuration = max(duration, cachedDuration)
        } else if reportedDurationIsReliable {
            effectiveDuration = duration
        } else if cachedDurationIsReliable {
            effectiveDuration = cachedDuration
        } else {
            effectiveDuration = 0
        }
        let durationIsReliable = effectiveDuration > 0
        let safeDuration: Double
        if durationIsReliable {
            safeDuration = max(effectiveDuration, safePosition + 0.5)
        } else if playbackDidStart || safePosition > 0.1 {
            safeDuration = max(60.0, safePosition + 300.0)
        } else {
            safeDuration = 1.0
        }

        if !position.isFinite || !duration.isFinite {
            Logger.shared.log("[PlayerVC.progress] non-finite input from renderer. rawPos=\(position) rawDur=\(duration) cachedPos=\(cachedPosition) cachedDur=\(cachedDuration)", type: "Error")
        }
        if mpvBridgeDurationLooksLikeWindow && abs(duration - lastIgnoredMPVBridgeDurationLogValue) > 0.5 {
            lastIgnoredMPVBridgeDurationLogValue = duration
            Logger.shared.log("[PlayerVC.progress] ignoring tiny MPV bridge duration raw=\(secondsText(duration)) position=\(secondsText(safePosition)); treating HLS window as unknown duration", type: "MPV")
        }

        let previousPosition = cachedPosition
        let playbackAdvanced = safePosition > max(0, previousPosition) + 0.05
        let waitingForInitialResume: Bool
        if let resumeTarget = pendingInitialResumeTarget {
            let deadline = pendingInitialResumeDeadline ?? .distantPast
            if safePosition + 2.0 < resumeTarget && Date() < deadline {
                waitingForInitialResume = true
            } else {
                waitingForInitialResume = false
                pendingInitialResumeTarget = nil
                pendingInitialResumeDeadline = nil
            }
        } else {
            waitingForInitialResume = false
        }

        if playbackAdvanced || safePosition > 0.1 {
            markPlaybackStarted(reason: "position")
        }

        logVLCUIProgressIfNeeded(
            rawPosition: position,
            rawDuration: duration,
            safePosition: safePosition,
            effectiveDuration: effectiveDuration,
            durationIsReliable: durationIsReliable,
            waitingForInitialResume: waitingForInitialResume
        )

        DispatchQueue.main.async {
            if reportedDurationIsReliable {
                self.cachedDuration = max(self.cachedDuration, duration)
            }

            if waitingForInitialResume {
                self.cachedPosition = safePosition
                if safeDuration > 0 {
                    self.updateProgressHostingController()
                }
                self.progressModel.position = safePosition
                self.progressModel.duration = max(safeDuration, 1.0)
                self.progressModel.durationIsKnown = durationIsReliable
                if self.rendererIsPictureInPictureActive() {
                    self.rendererUpdatePictureInPicturePlaybackState()
                }
                if self.isVLCPlayer {
                    self.updateVLCSubtitleOverlay(for: safePosition)
                }
#if !os(tvOS)
                if self.supportsSharedPlayerControls, durationIsReliable {
                    if !self.skipDataFetched {
                        self.fetchSkipData()
                    }
                    self.updateSkipState(position: safePosition, duration: effectiveDuration)
                    self.updateNextEpisodeState(position: safePosition, duration: effectiveDuration)
                }
#endif
                if self.isRendererLoading && playbackAdvanced {
                    self.isRendererLoading = false
                    self.loadingIndicator.stopAnimating()
                    self.loadingIndicator.alpha = 0.0
                    self.centerPlayPauseButton.isHidden = false
                    self.updatePlayPauseButton(isPaused: self.rendererIsPausedState(), shouldShowControls: false)
                }
                return
            }

            self.cachedPosition = safePosition
            if safeDuration > 0 {
                self.updateProgressHostingController()
            }
            self.progressModel.position = safePosition
            self.progressModel.duration = max(safeDuration, 1.0)
            self.progressModel.durationIsKnown = durationIsReliable
            
            if self.rendererIsPictureInPictureActive() {
                self.rendererUpdatePictureInPicturePlaybackState()
            }

            if self.isVLCPlayer {
                self.updateVLCSubtitleOverlay(for: safePosition)
            }

#if !os(tvOS)
            if self.supportsSharedPlayerControls, durationIsReliable {
                if !self.skipDataFetched {
                    self.fetchSkipData()
                }
                self.updateSkipState(position: safePosition, duration: effectiveDuration)
                self.updateNextEpisodeState(position: safePosition, duration: effectiveDuration)
            }
#endif

            // If playback is progressing, force-hide any lingering loading spinner.
            if self.isRendererLoading && playbackAdvanced {
                self.isRendererLoading = false
                self.loadingIndicator.stopAnimating()
                self.loadingIndicator.alpha = 0.0
                self.centerPlayPauseButton.isHidden = false
                self.updatePlayPauseButton(isPaused: self.rendererIsPausedState(), shouldShowControls: false)
            } else if !self.isRendererLoading && (self.loadingIndicator.alpha > 0.0 || self.loadingIndicator.isAnimating) {
                self.loadingIndicator.stopAnimating()
                self.loadingIndicator.alpha = 0.0
                self.centerPlayPauseButton.isHidden = false
            }
        }

        guard !waitingForInitialResume else { return }
        
        guard durationIsReliable, effectiveDuration.isFinite, effectiveDuration > 0, safePosition >= 0, let info = mediaInfo else { return }
        let persistPosition = min(safePosition, effectiveDuration)
        
        switch info {
        case .movie(let id, let title, _, _):
            ProgressManager.shared.updateMovieProgress(movieId: id, title: title, currentTime: persistPosition, totalDuration: effectiveDuration)
        case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, let showPosterURL, let isAnime):
            ProgressManager.shared.updateEpisodeProgress(
                showId: showId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                currentTime: persistPosition,
                totalDuration: effectiveDuration,
                showTitle: showTitle,
                showPosterURL: showPosterURL,
                playbackContext: episodePlaybackContext?.forEpisodeNumber(episodeNumber),
                isAnime: isAnime || episodePlaybackContext?.anilistMediaId != nil
            )
        }
    }

    private func logVLCUIProgressIfNeeded(rawPosition: Double, rawDuration: Double, safePosition: Double, effectiveDuration: Double, durationIsReliable: Bool, waitingForInitialResume: Bool) {
        guard isVLCPlayer else { return }
        let bucket = Int(max(0, safePosition) / 10.0)
        if bucket != lastVLCUIProgressLogBucket {
            lastVLCUIProgressLogBucket = bucket
            logVLCUI("progress raw=\(secondsText(rawPosition))/\(secondsText(rawDuration)) safe=\(secondsText(safePosition))/\(secondsText(effectiveDuration)) reliable=\(durationIsReliable) waitingResume=\(waitingForInitialResume) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)", type: "Progress")
        }

        let anomaly: String?
        if safePosition > 1.0 && !durationIsReliable {
            anomaly = "position-advancing-duration-unreliable rawDuration=\(secondsText(rawDuration)) cachedDuration=\(secondsText(cachedDuration))"
        } else if durationIsReliable && cachedDuration > 0 && effectiveDuration + 30.0 < cachedDuration {
            anomaly = "effective-duration-shrank effective=\(secondsText(effectiveDuration)) cached=\(secondsText(cachedDuration))"
        } else if waitingForInitialResume {
            anomaly = "waiting-for-initial-resume target=\(secondsText(pendingInitialResumeTarget)) position=\(secondsText(safePosition))"
        } else {
            anomaly = nil
        }

        guard let anomaly else { return }
        let now = CACurrentMediaTime()
        if anomaly != lastVLCUIProgressAnomalyKey || now - lastVLCUIProgressAnomalyLogTime > 8.0 {
            lastVLCUIProgressAnomalyKey = anomaly
            lastVLCUIProgressAnomalyLogTime = now
            logVLCUI("progress anomaly \(anomaly)", type: "Error")
        }
    }
}

struct PlayerEpisodeBrowserSeed {
    let showId: Int
    let showTitle: String
    let showPosterURL: String?
    let currentSeasonNumber: Int
    let currentEpisodeNumber: Int
    let isAnime: Bool
    let imdbId: String?
    let currentPlaybackContext: EpisodePlaybackContext?
}

struct PlayerEpisodeBrowserSeason: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let posterURL: String?
    let episodes: [PlayerEpisodeBrowserItem]
}

struct PlayerEpisodeBrowserItem: Identifiable {
    let id: String
    let showId: Int
    let showTitle: String
    let showPosterURL: String?
    let mediaTitle: String
    let seasonTitleOverride: String?
    let animeSeasonTitle: String?
    let originalTitle: String?
    let posterURL: String?
    let imdbId: String?
    let episode: TMDBEpisode
    let isAnime: Bool
    let isSpecial: Bool
    let playbackContext: EpisodePlaybackContext?
    let originalTMDBSeasonNumber: Int?
    let originalTMDBEpisodeNumber: Int?
    let progress: Double
    let isDownloaded: Bool
    let downloadItem: DownloadItem?
    let isCurrent: Bool

    var imageURL: String? {
        PlayerEpisodeBrowserViewModel.fullImageURL(from: episode.stillPath)
            ?? posterURL
            ?? showPosterURL
    }

    var artworkURLs: [String] {
        var urls: [String] = []
        for candidate in [
            PlayerEpisodeBrowserViewModel.fullImageURL(from: episode.stillPath),
            posterURL,
            showPosterURL,
            downloadItem?.posterURL
        ] {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  !urls.contains(value) else {
                continue
            }
            urls.append(value)
        }
        return urls
    }

    var displayCode: String {
        if isSpecial {
            return episode.episodeNumber > 1 ? "Special \(episode.episodeNumber)" : "Special"
        }
        if isAnime {
            return "E\(episode.episodeNumber)"
        }
        return "S\(episode.seasonNumber)E\(episode.episodeNumber)"
    }

    var displayTitle: String {
        let name = episode.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Episode \(episode.episodeNumber)" : name
    }
}

@MainActor
final class PlayerEpisodeBrowserViewModel: ObservableObject {
    @Published var seasons: [PlayerEpisodeBrowserSeason] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentItemID: String?

    let seed: PlayerEpisodeBrowserSeed
    private var didLoad = false

    init(seed: PlayerEpisodeBrowserSeed) {
        self.seed = seed
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await load()
    }

    func itemAfterCurrent() async -> PlayerEpisodeBrowserItem? {
        if !didLoad {
            await load()
        }
        let allItems = seasons.flatMap(\.episodes).sorted { lhs, rhs in
            if lhs.episode.seasonNumber == rhs.episode.seasonNumber {
                return lhs.episode.episodeNumber < rhs.episode.episodeNumber
            }
            return lhs.episode.seasonNumber < rhs.episode.seasonNumber
        }
        guard let index = allItems.firstIndex(where: { $0.isCurrent }) else { return nil }
        let nextIndex = allItems.index(after: index)
        guard nextIndex < allItems.endIndex else { return nil }
        return allItems[nextIndex]
    }

    private func load() async {
        didLoad = true
        isLoading = true
        errorMessage = nil
        seasons = []
        currentItemID = nil

        do {
            let tmdbService = TMDBService.shared
            let tvShow = try await tmdbService.getTVShowWithSeasons(id: seed.showId)
            let showTitle = tvShow.name.isEmpty ? seed.showTitle : tvShow.name
            let showPosterURL = seed.showPosterURL ?? tvShow.fullPosterURL
            let resolvedImdbId = seed.imdbId ?? tvShow.externalIds?.imdbId
            var animeData: AniListAnimeWithSeasons?
            var specialContexts: [SpecialEpisodeListContext] = []

            if seed.isAnime {
                animeData = try? await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                    title: seed.showTitle,
                    tmdbShowId: seed.showId,
                    tmdbService: tmdbService,
                    tmdbShowPoster: showPosterURL,
                    token: nil
                )
                if let animeData {
                    let mappings = animeData.seasons.map { (seasonNumber: $0.seasonNumber, anilistId: $0.anilistId) }
                    TrackerManager.shared.registerAniListAnimeData(tmdbId: seed.showId, seasons: mappings)
                }

                let specialEntries = await AniListService.shared.fetchSpecialSearchEntries(
                    tmdbShowId: seed.showId,
                    fallbackPosterURL: showPosterURL,
                    baseAniListIds: animeData?.seasons.map(\.anilistId) ?? [],
                    tmdbService: tmdbService
                )
                specialContexts = specialEntries.compactMap {
                    SpecialEpisodeListContext(entry: $0, tmdbShowId: seed.showId)
                }
            }

            var loaded: [PlayerEpisodeBrowserSeason] = []

            if let currentSpecial = currentSpecialContext(from: specialContexts) {
                loaded.append(buildSpecialSeason(
                    context: currentSpecial,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    fallbackImdbId: resolvedImdbId
                ))
                seasons = loaded
            } else if seed.isAnime,
                      let animeSeason = animeData?.seasons.first(where: { $0.seasonNumber == seed.currentSeasonNumber }) {
                loaded.append(buildAnimeSeason(
                    animeSeason,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    imdbId: resolvedImdbId
                ))
                seasons = loaded
            } else if let currentTMDBSeason = tvShow.seasons.first(where: { $0.seasonNumber == seed.currentSeasonNumber }),
                      let detail = try? await tmdbService.getSeasonDetails(tvShowId: seed.showId, seasonNumber: currentTMDBSeason.seasonNumber) {
                loaded.append(buildTMDBSeason(
                    summary: currentTMDBSeason,
                    detail: detail,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    imdbId: resolvedImdbId,
                    isSpecial: currentTMDBSeason.seasonNumber == 0
                ))
                seasons = loaded
            }

            if seed.isAnime, let animeData {
                for season in animeData.seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }) where season.seasonNumber != seed.currentSeasonNumber {
                    loaded.append(buildAnimeSeason(
                        season,
                        showTitle: showTitle,
                        showPosterURL: showPosterURL,
                        imdbId: resolvedImdbId
                    ))
                    seasons = loaded
                }
            } else {
                let orderedSeasons = tvShow.seasons
                    .filter { $0.episodeCount > 0 }
                    .sorted { lhs, rhs in
                        if lhs.seasonNumber == 0 { return false }
                        if rhs.seasonNumber == 0 { return true }
                        return lhs.seasonNumber < rhs.seasonNumber
                    }
                for season in orderedSeasons where season.seasonNumber != seed.currentSeasonNumber {
                    guard let detail = try? await tmdbService.getSeasonDetails(tvShowId: seed.showId, seasonNumber: season.seasonNumber) else {
                        continue
                    }
                    loaded.append(buildTMDBSeason(
                        summary: season,
                        detail: detail,
                        showTitle: showTitle,
                        showPosterURL: showPosterURL,
                        imdbId: resolvedImdbId,
                        isSpecial: season.seasonNumber == 0
                    ))
                    seasons = loaded
                }
            }

            for context in specialContexts where !loaded.contains(where: { $0.id == "special-\(context.id)" }) {
                loaded.append(buildSpecialSeason(
                    context: context,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    fallbackImdbId: resolvedImdbId
                ))
                seasons = loaded
            }

            if let current = loaded.flatMap(\.episodes).first(where: { $0.isCurrent }) {
                currentItemID = current.id
            }
            seasons = loaded
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func currentSpecialContext(from contexts: [SpecialEpisodeListContext]) -> SpecialEpisodeListContext? {
        guard let current = seed.currentPlaybackContext, current.isSpecial else { return nil }
        return contexts.first {
            $0.anilistId == current.anilistMediaId ||
            $0.localSeasonNumber == current.localSeasonNumber
        }
    }

    private func buildAnimeSeason(_ season: AniListSeasonWithPoster, showTitle: String, showPosterURL: String?, imdbId: String?) -> PlayerEpisodeBrowserSeason {
        let title = season.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Season \(season.seasonNumber)" : season.title
        let items = season.episodes
            .sorted { $0.number < $1.number }
            .map { aniEpisode -> PlayerEpisodeBrowserItem in
                let episode = TMDBEpisode(
                    id: seed.showId * 1000 + season.seasonNumber * 100 + aniEpisode.number,
                    name: aniEpisode.title,
                    overview: aniEpisode.description,
                    stillPath: aniEpisode.stillPath,
                    episodeNumber: aniEpisode.number,
                    seasonNumber: season.seasonNumber,
                    airDate: aniEpisode.airDate,
                    runtime: aniEpisode.runtime,
                    voteAverage: 0,
                    voteCount: 0
                )
                let context = EpisodePlaybackContext(
                    localSeasonNumber: season.seasonNumber,
                    localEpisodeNumber: aniEpisode.number,
                    anilistMediaId: season.anilistId,
                    tmdbSeasonNumber: aniEpisode.tmdbSeasonNumber,
                    tmdbEpisodeNumber: aniEpisode.tmdbEpisodeNumber,
                    tmdbEpisodeOffset: nil,
                    isSpecial: false,
                    titleOnlySearch: false
                )
                return buildItem(
                    episode: episode,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    mediaTitle: title,
                    seasonTitleOverride: title,
                    animeSeasonTitle: title,
                    originalTitle: nil,
                    posterURL: season.posterUrl ?? showPosterURL,
                    imdbId: imdbId,
                    isAnime: true,
                    isSpecial: false,
                    playbackContext: context,
                    originalTMDBSeasonNumber: context.resolvedTMDBSeasonNumber,
                    originalTMDBEpisodeNumber: context.resolvedTMDBEpisodeNumber
                )
            }
        return PlayerEpisodeBrowserSeason(
            id: "anime-\(season.seasonNumber)-\(season.anilistId)",
            title: title,
            subtitle: "Season \(season.seasonNumber)",
            posterURL: season.posterUrl ?? showPosterURL,
            episodes: items
        )
    }

    private func buildTMDBSeason(summary: TMDBSeason, detail: TMDBSeasonDetail, showTitle: String, showPosterURL: String?, imdbId: String?, isSpecial: Bool) -> PlayerEpisodeBrowserSeason {
        let title = isSpecial ? "Specials" : (summary.name.isEmpty ? "Season \(summary.seasonNumber)" : summary.name)
        let posterURL = detail.fullPosterURL ?? summary.fullPosterURL ?? showPosterURL
        let items = detail.episodes
            .sorted { $0.episodeNumber < $1.episodeNumber }
            .map { episode in
                buildItem(
                    episode: episode,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    mediaTitle: showTitle,
                    seasonTitleOverride: nil,
                    animeSeasonTitle: nil,
                    originalTitle: nil,
                    posterURL: posterURL,
                    imdbId: imdbId,
                    isAnime: false,
                    isSpecial: isSpecial,
                    playbackContext: nil,
                    originalTMDBSeasonNumber: nil,
                    originalTMDBEpisodeNumber: nil
                )
            }
        return PlayerEpisodeBrowserSeason(
            id: "tmdb-\(summary.seasonNumber)-\(summary.id)",
            title: title,
            subtitle: isSpecial ? nil : "Season \(summary.seasonNumber)",
            posterURL: posterURL,
            episodes: items
        )
    }

    private func buildSpecialSeason(context: SpecialEpisodeListContext, showTitle: String, showPosterURL: String?, fallbackImdbId: String?) -> PlayerEpisodeBrowserSeason {
        let posterURL = context.posterUrl ?? showPosterURL
        let items = context.episodes.map { episode -> PlayerEpisodeBrowserItem in
            let playbackContext = context.playbackContext(for: episode)
            return buildItem(
                episode: episode,
                showTitle: showTitle,
                showPosterURL: showPosterURL,
                mediaTitle: context.title,
                seasonTitleOverride: context.title,
                animeSeasonTitle: context.title,
                originalTitle: context.alternateTitle,
                posterURL: posterURL,
                imdbId: context.imdbId ?? fallbackImdbId,
                isAnime: true,
                isSpecial: true,
                playbackContext: playbackContext,
                originalTMDBSeasonNumber: playbackContext.resolvedTMDBSeasonNumber,
                originalTMDBEpisodeNumber: playbackContext.resolvedTMDBEpisodeNumber
            )
        }
        return PlayerEpisodeBrowserSeason(
            id: "special-\(context.id)",
            title: context.title,
            subtitle: context.formatLabel,
            posterURL: posterURL,
            episodes: items
        )
    }

    private func buildItem(
        episode: TMDBEpisode,
        showTitle: String,
        showPosterURL: String?,
        mediaTitle: String,
        seasonTitleOverride: String?,
        animeSeasonTitle: String?,
        originalTitle: String?,
        posterURL: String?,
        imdbId: String?,
        isAnime: Bool,
        isSpecial: Bool,
        playbackContext: EpisodePlaybackContext?,
        originalTMDBSeasonNumber: Int?,
        originalTMDBEpisodeNumber: Int?
    ) -> PlayerEpisodeBrowserItem {
        let progress = ProgressManager.shared.getEpisodeProgress(
            showId: seed.showId,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
        let download = DownloadManager.shared.completedDownloadItem(
            tmdbId: seed.showId,
            isMovie: false,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
        let isCurrent = episode.seasonNumber == seed.currentSeasonNumber
            && episode.episodeNumber == seed.currentEpisodeNumber
        let id = "\(episode.seasonNumber)-\(episode.episodeNumber)-\(episode.id)-\(isSpecial ? "special" : "main")"
        return PlayerEpisodeBrowserItem(
            id: id,
            showId: seed.showId,
            showTitle: showTitle,
            showPosterURL: showPosterURL,
            mediaTitle: mediaTitle,
            seasonTitleOverride: seasonTitleOverride,
            animeSeasonTitle: animeSeasonTitle,
            originalTitle: originalTitle,
            posterURL: posterURL,
            imdbId: imdbId,
            episode: episode,
            isAnime: isAnime,
            isSpecial: isSpecial,
            playbackContext: playbackContext,
            originalTMDBSeasonNumber: originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: originalTMDBEpisodeNumber,
            progress: progress,
            isDownloaded: download != nil,
            downloadItem: download,
            isCurrent: isCurrent
        )
    }

    nonisolated static func fullImageURL(from path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return path }
        return "\(TMDBService.tmdbImageBaseURL)\(path)"
    }
}

struct PlayerEpisodeBrowserDrawer: View {
    @StateObject private var viewModel: PlayerEpisodeBrowserViewModel
    @State private var selectedSeasonID: String?
    @State private var didManuallySelectSeason = false
    let onClose: () -> Void
    let onEpisodeSelected: (PlayerEpisodeBrowserItem) -> Void

    init(
        seed: PlayerEpisodeBrowserSeed,
        onClose: @escaping () -> Void,
        onEpisodeSelected: @escaping (PlayerEpisodeBrowserItem) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: PlayerEpisodeBrowserViewModel(seed: seed))
        self.onClose = onClose
        self.onEpisodeSelected = onEpisodeSelected
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                drawerContent
                    .frame(width: drawerWidth(for: proxy.size.width), height: proxy.size.height)
                    .background(Color.black.opacity(0.86))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 1)
                    }
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
    }

    private var drawerContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Episodes")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    Text(viewModel.seed.showTitle)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()
                .background(Color.white.opacity(0.12))

            if viewModel.isLoading && viewModel.seasons.isEmpty {
                Spacer()
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Spacer()
            } else if let error = viewModel.errorMessage, viewModel.seasons.isEmpty {
                Spacer()
                Text(error)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            } else {
                seasonSelector
                selectedSeasonEpisodes
            }
        }
        .onAppear {
            syncSelectedSeasonIfNeeded()
        }
        .onChange(of: viewModel.seasons.map(\.id)) { _ in
            syncSelectedSeasonIfNeeded()
        }
        .onChange(of: viewModel.currentItemID) { _ in
            syncSelectedSeasonIfNeeded()
        }
    }

    private var selectedSeason: PlayerEpisodeBrowserSeason? {
        if let selectedSeasonID,
           let season = viewModel.seasons.first(where: { $0.id == selectedSeasonID }) {
            return season
        }
        return currentSeason ?? viewModel.seasons.first
    }

    private var currentSeason: PlayerEpisodeBrowserSeason? {
        guard let currentID = viewModel.currentItemID else { return nil }
        return viewModel.seasons.first { season in
            season.episodes.contains(where: { $0.id == currentID })
        }
    }

    private var seasonSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedSeason?.title ?? "Season")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let subtitle = selectedSeasonSubtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.58))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if viewModel.seasons.count > 1 {
                    Menu {
                        ForEach(viewModel.seasons) { season in
                            Button {
                                selectSeason(season)
                            } label: {
                                Label(
                                    seasonMenuTitle(season),
                                    systemImage: season.id == selectedSeason?.id ? "checkmark" : "tv"
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Change")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }
            }

            if viewModel.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(viewModel.seasons) { season in
                            seasonChip(season)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.22))
    }

    private var selectedSeasonSubtitle: String? {
        guard let season = selectedSeason else { return nil }
        let episodeText = "\(season.episodes.count) episode\(season.episodes.count == 1 ? "" : "s")"
        if let subtitle = season.subtitle, !subtitle.isEmpty {
            return "\(subtitle) - \(episodeText)"
        }
        return episodeText
    }

    private var selectedSeasonEpisodes: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: []) {
                    Color.clear
                        .frame(height: 0)
                        .id("selected-season-top")

                    if let season = selectedSeason {
                        ForEach(season.episodes) { item in
                            episodeRow(item)
                                .id(item.id)
                        }
                    } else if viewModel.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    } else {
                        Text("No episodes found.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.68))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .onChange(of: selectedSeasonID) { _ in
                scrollToSelectedSeasonStart(proxy: proxy)
            }
            .onChange(of: viewModel.currentItemID) { _ in
                scrollToCurrentIfVisible(proxy: proxy)
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    scrollToCurrentIfVisible(proxy: proxy)
                }
            }
        }
    }

    private func seasonChip(_ season: PlayerEpisodeBrowserSeason) -> some View {
        let selected = season.id == selectedSeason?.id
        return Button {
            selectSeason(season)
        } label: {
            HStack(spacing: 6) {
                if season.episodes.contains(where: { $0.isCurrent }) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
                Text(seasonChipTitle(season))
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .medium)
                    .lineLimit(1)
            }
            .foregroundColor(.white.opacity(selected ? 1.0 : 0.72))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(selected ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func selectSeason(_ season: PlayerEpisodeBrowserSeason) {
        didManuallySelectSeason = true
        selectedSeasonID = season.id
    }

    private func syncSelectedSeasonIfNeeded() {
        guard !viewModel.seasons.isEmpty else {
            selectedSeasonID = nil
            didManuallySelectSeason = false
            return
        }

        if let selectedSeasonID,
           viewModel.seasons.contains(where: { $0.id == selectedSeasonID }) {
            return
        }

        if !didManuallySelectSeason, let currentSeason {
            selectedSeasonID = currentSeason.id
        } else {
            selectedSeasonID = viewModel.seasons.first?.id
        }
    }

    private func scrollToSelectedSeasonStart(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("selected-season-top", anchor: .top)
            }
        }
    }

    private func scrollToCurrentIfVisible(proxy: ScrollViewProxy) {
        guard let id = viewModel.currentItemID,
              selectedSeason?.episodes.contains(where: { $0.id == id }) == true else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func seasonChipTitle(_ season: PlayerEpisodeBrowserSeason) -> String {
        if season.episodes.first?.isSpecial == true {
            return season.title
        }
        if let subtitle = season.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        return season.title
    }

    private func seasonMenuTitle(_ season: PlayerEpisodeBrowserSeason) -> String {
        let title = seasonChipTitle(season)
        return "\(title) (\(season.episodes.count))"
    }

    private func episodeRow(_ item: PlayerEpisodeBrowserItem) -> some View {
        Button {
            onEpisodeSelected(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                episodeImage(item)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(item.displayCode)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white.opacity(0.72))

                        if item.isCurrent {
                            Text("Now Playing")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.25))
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        } else if item.isDownloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        }

                        Spacer(minLength: 0)
                    }

                    Text(item.displayTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let overview = item.episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.58))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: 8) {
                        if let runtime = item.episode.runtime, runtime > 0 {
                            Text("\(runtime)m")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.58))
                        }
                        if item.episode.voteAverage > 0 {
                            Label(String(format: "%.1f", item.episode.voteAverage), systemImage: "star.fill")
                                .font(.caption2)
                                .foregroundColor(.yellow.opacity(0.9))
                        }
                        Spacer(minLength: 0)
                    }

                    if item.progress > 0 && item.progress < 0.95 {
                        ProgressView(value: item.progress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                            .frame(height: 3)
                    }
                }
            }
            .padding(8)
            .background(item.isCurrent ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(item.isCurrent ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(item.isCurrent)
    }

    private func episodeImage(_ item: PlayerEpisodeBrowserItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.1))

            if let imageURL = item.imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Image(systemName: item.isSpecial ? "sparkles" : "tv")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
            } else {
                Image(systemName: item.isSpecial ? "sparkles" : "tv")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .frame(width: 92, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func drawerWidth(for totalWidth: CGFloat) -> CGFloat {
        if totalWidth < 700 {
            return min(totalWidth, max(300, totalWidth * 0.86))
        }
        return min(460, max(360, totalWidth * 0.42))
    }
}

// MARK: - MPVNativeRendererDelegate
extension PlayerViewController: MPVNativeRendererDelegate {
    func renderer(_ renderer: MPVNativeRenderer, didUpdatePosition position: Double, duration: Double) {
        if isClosing { return }
        updatePosition(position, duration: duration)
    }
    
    func renderer(_ renderer: MPVNativeRenderer, didChangePause isPaused: Bool) {
        if isClosing { return }
        if !isPaused {
            markPlaybackStarted(reason: "playing")
            rendererResumeForegroundRendering(reason: "mpv-unpause")
        }
        if isRendererLoading && !isPaused {
            isRendererLoading = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loadingIndicator.stopAnimating()
                self.loadingIndicator.alpha = 0.0
                self.centerPlayPauseButton.isHidden = false
            }
        }
        if isRendererLoading {
            pipController?.updatePlaybackState()
            return
        }
        updatePlayPauseButton(isPaused: isPaused)
        pipController?.updatePlaybackState()
    }
    
    func renderer(_ renderer: MPVNativeRenderer, didChangeLoading isLoading: Bool) {
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
    
    func renderer(_ renderer: MPVNativeRenderer, didBecomeReadyToSeek: Bool) {
        if isClosing { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.markPlaybackStarted(reason: "ready")
            self.updateAudioTracksMenuWhenReady()
            self.updateSubtitleTracksMenuWhenReady()
            self.prefetchOpenSubtitlesIfEnabled(reason: "ready")
            self.updatePiPButtonVisibility()
            
            if let seekTime = self.pendingSeekTime {
                self.pendingInitialResumeTarget = seekTime
                self.pendingInitialResumeDeadline = Date().addingTimeInterval(20)
                self.rendererSeek(to: seekTime)
                Logger.shared.log("Resumed MPV playback from \(Int(seekTime))s", type: "Progress")
                self.pendingSeekTime = nil
            }
            self.applyDefaultPlaybackSpeed()

            // Fetch skip data once MPV is ready
            self.fetchSkipData()
        }
    }

    func renderer(_ renderer: MPVNativeRenderer, didFailWithError message: String) {
        if isClosing { return }
        logMPV("delegate didFailWithError message=\(message)")
        Logger.shared.log("PlayerViewController: MPV playback issue: \(message)", type: "MPV")
        if attemptMPVTransportBridgeFallbackIfNeeded(after: message) {
            return
        }
        if !playbackDidStart {
            handlePlaybackStartupFailure(message, isSourceFailure: true)
        }
    }

    func rendererDidChangeTracks(_ renderer: MPVNativeRenderer) {
        if isClosing { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateAudioTracksMenu()
            self.updateSubtitleTracksMenu()
        }
    }
    
    func renderer(_ renderer: MPVNativeRenderer, subtitleTrackDidChange trackId: Int) {
        if isClosing { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.subtitleModel.isVisible = trackId >= 0
            if trackId >= 0 {
                self.vlcSubtitleSelection = .embedded(trackId: trackId)
            } else {
                self.vlcSubtitleSelection = .none
            }
            self.updateSubtitleButtonAppearance()
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
        logVLCUI("delegate didChangePause isPaused=\(isPaused) loading=\(isRendererLoading) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) pipActive=\(renderer.isPictureInPictureActive)", type: "Player")

        if !isPaused {
            markPlaybackStarted(reason: "playing")
        }
        if isRendererLoading && !isPaused {
            isRendererLoading = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loadingIndicator.stopAnimating()
                self.loadingIndicator.alpha = 0.0
                self.centerPlayPauseButton.isHidden = false
            }
        }
        if isRendererLoading {
            renderer.updatePictureInPicturePlaybackState()
            return
        }
        updatePlayPauseButton(isPaused: isPaused)
        renderer.updatePictureInPicturePlaybackState()
    }
    
    func renderer(_ renderer: VLCRenderer, didChangeLoading isLoading: Bool) {
        if isClosing { return }
        logVLCUI("delegate didChangeLoading isLoading=\(isLoading) currentLoading=\(isRendererLoading) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))", type: "Stream")

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
            self.isVLCPlaybackStartupInProgress = false
            self.canMutateVLCSubtitleTracks = true
            self.markPlaybackStarted(reason: "ready")
            
            // Update audio and subtitle tracks now that the video is ready
            self.updateAudioTracksMenuWhenReady()
            self.updateSubtitleTracksMenuWhenReady()
            self.prefetchOpenSubtitlesIfEnabled(reason: "ready")
            renderer.updatePictureInPicturePlaybackState()
            self.updatePiPButtonVisibility()
            
            if let seekTime = self.pendingSeekTime {
                self.pendingInitialResumeTarget = seekTime
                self.pendingInitialResumeDeadline = Date().addingTimeInterval(20)
                self.rendererSeek(to: seekTime)
                Logger.shared.log("Resumed VLC playback from \(Int(seekTime))s", type: "Progress")
                self.pendingSeekTime = nil
            }
            self.applyDefaultPlaybackSpeed()

            // Fetch skip data once VLC is ready
            self.fetchSkipData()
        }
    }

    func renderer(_ renderer: VLCRenderer, didFailWithError message: String) {
        if isClosing { return }
        isVLCPlaybackStartupInProgress = false
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
                self.rendererApplySubtitleStyle(self.currentSubtitleStyle())
            }
            self.subtitleEntries.removeAll()
            self.updateVLCSubtitleOverlay(for: self.cachedPosition)
            self.updateSubtitleButtonAppearance()
            // VLC natively renders ASS subtitles
        }
    }

    func renderer(_ renderer: VLCRenderer, didChangePictureInPictureAvailability isAvailable: Bool) {
        if isClosing { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Logger.shared.log("[PlayerVC.PiP] native VLC availability changed available=\(isAvailable) enabled=\(Settings.shared.vlcPiPEnabled) active=\(renderer.isPictureInPictureActive) paused=\(self.rendererIsPausedState())", type: "Player")
            self.logVLCUIViewSnapshot("delegate didChangePictureInPictureAvailability")
            self.updatePiPButtonVisibility()
        }
    }

    func renderer(_ renderer: VLCRenderer, didChangePictureInPictureActive isActive: Bool) {
        if isClosing { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Logger.shared.log("[PlayerVC.PiP] native VLC active changed active=\(isActive) enabled=\(Settings.shared.vlcPiPEnabled) available=\(renderer.isPictureInPictureAvailable) paused=\(self.rendererIsPausedState())", type: "Player")
            self.logVLCUIViewSnapshot("delegate didChangePictureInPictureActive")
            self.updatePiPButtonVisibility()
            renderer.updatePictureInPicturePlaybackState()
        }
    }
}

// MARK: - PiP Support
extension PlayerViewController: PiPControllerDelegate {
    func pipController(_ controller: PiPController, willStartPictureInPicture: Bool) {
        logPictureInPicture("delegate willStart possible=\(controller.isPictureInPicturePossible) active=\(controller.isPictureInPictureActive)")
        let primed = prepareMPVPictureInPictureRenderer(source: "delegate-willStart", activateLayer: true)
        logPictureInPicture("delegate willStart prepared primed=\(primed) subs={\(subtitlePictureInPictureDebugSnapshot())}")
    }
    func pipController(_ controller: PiPController, didStartPictureInPicture: Bool) {
        let primed = rendererIsPictureInPicturePrimed()
        logPictureInPicture("delegate didStart success=\(didStartPictureInPicture) possible=\(controller.isPictureInPicturePossible) active=\(controller.isPictureInPictureActive) primed=\(primed) renderer={\(rendererPictureInPictureDebugSnapshot())}")
        if didStartPictureInPicture {
            if primed {
                rendererActivatePictureInPictureLayer()
            } else {
                logPictureInPicture("delegate didStart found unprimed renderer; forcing PiP renderer prepare")
                _ = prepareMPVPictureInPictureRenderer(source: "delegate-didStart-unprimed", activateLayer: true)
            }
            scheduleMPVPictureInPictureRendererWatchdog(source: "delegate-didStart")
        } else {
            mpvPiPStartAttemptID += 1
            mpvAppExitPiPStartRequested = false
            rendererFinishPictureInPicture()
        }
        pipController?.updatePlaybackState()
        updatePiPButtonVisibility()
    }
    func pipController(_ controller: PiPController, willStopPictureInPicture: Bool) {
        logPictureInPicture("delegate willStop renderer={\(rendererPictureInPictureDebugSnapshot())}")
    }
    func pipController(_ controller: PiPController, didStopPictureInPicture: Bool) {
        logPictureInPicture("delegate didStop renderer={\(rendererPictureInPictureDebugSnapshot())}")
        mpvPiPStartAttemptID += 1
        mpvAppExitPiPStartRequested = false
        rendererFinishPictureInPicture()
        updatePiPButtonVisibility()
    }
    func pipController(_ controller: PiPController, restoreUserInterfaceForPictureInPictureStop completionHandler: @escaping (Bool) -> Void) {
        logPictureInPicture("delegate restoreUI begin renderer={\(rendererPictureInPictureDebugSnapshot())}")
        let completeRestore: () -> Void = { [weak self] in
            self?.rendererFinishPictureInPicture()
            self?.updatePiPButtonVisibility()
            self?.logPictureInPicture("delegate restoreUI complete renderer={\(self?.rendererPictureInPictureDebugSnapshot() ?? "nil")}")
            completionHandler(true)
        }
        if presentedViewController != nil {
            dismiss(animated: true) { completeRestore() }
        } else {
            completeRestore()
        }
    }
    func pipControllerPlay(_ controller: PiPController) {
        rendererPlay()
    }
    func pipControllerPause(_ controller: PiPController) {
        rendererPausePlayback()
    }
    func pipController(_ controller: PiPController, skipByInterval interval: CMTime) {
        let requestedSeconds = CMTimeGetSeconds(interval)
        let direction = requestedSeconds < 0 ? -1.0 : 1.0
        let seconds = direction * playerSeekSeconds
        let canClampToDuration = cachedDuration.isFinite && cachedDuration > 5 && cachedDuration > cachedPosition + 1
        let targetLimit = canClampToDuration ? cachedDuration : .greatestFiniteMagnitude
        let target = max(0, min(targetLimit, cachedPosition + seconds))
        logPictureInPicture("skip requested=\(String(format: "%.1f", requestedSeconds)) applying=\(String(format: "%.1f", seconds)) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) optimistic=\(secondsText(target))")
        cachedPosition = target
        progressModel.position = target
        rendererSeek(to: target)
        rendererPrimePictureInPictureFrames(reason: "pip-skip")
        pipController?.updatePlaybackState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.rendererPrimePictureInPictureFrames(reason: "pip-skip-followup")
            self.pipController?.updatePlaybackState()
        }
    }
    func pipControllerIsPlaying(_ controller: PiPController) -> Bool {
        return !rendererIsPausedState()
    }
    func pipControllerDuration(_ controller: PiPController) -> Double { return cachedDuration }
    func pipControllerCurrentTime(_ controller: PiPController) -> Double { return cachedPosition }

    @objc private func appWillResignActive() {
        logPictureInPicture("lifecycle notification received source=will-resign-active")
        if Thread.isMainThread {
            attemptMPVAppExitPictureInPictureStart(source: "will-resign-active")
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.attemptMPVAppExitPictureInPictureStart(source: "will-resign-active")
            }
        }
    }

    @objc private func appScenePhaseDidChange(_ notification: Notification) {
        let phase = notification.userInfo?["phase"] as? String ?? "unknown"
        logPictureInPicture("scenePhase notification received phase=\(phase)")
        switch phase {
        case "inactive":
            if Thread.isMainThread {
                attemptMPVAppExitPictureInPictureStart(source: "scene-phase-inactive")
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.attemptMPVAppExitPictureInPictureStart(source: "scene-phase-inactive")
                }
            }
        case "background":
            if Thread.isMainThread {
                attemptMPVAppExitPictureInPictureStart(source: "scene-phase-background")
                scheduleMPVBackgroundAudioFallback(source: "scene-phase-background")
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.attemptMPVAppExitPictureInPictureStart(source: "scene-phase-background")
                    self?.scheduleMPVBackgroundAudioFallback(source: "scene-phase-background")
                }
            }
        case "active":
            restoreMPVForegroundIfNeeded(source: "scene-phase-active")
        default:
            break
        }
    }

    private func attemptMPVAppExitPictureInPictureStart(source: String) {
        guard !isVLCPlayer else {
            logPictureInPicture("app-exit auto PiP skipped source=\(source): VLC renderer active")
            return
        }
        guard mpvRenderer != nil else {
            logPictureInPicture("app-exit auto PiP skipped source=\(source): MPV renderer missing")
            return
        }
        guard let pip = pipController else {
            logPictureInPicture("app-exit auto PiP skipped source=\(source): controller missing")
            return
        }

        let paused = rendererIsPausedState()
        let playbackReady = playbackDidStart || cachedPosition > 0.1
        let active = pip.isPictureInPictureActive
        let supported = pip.isPictureInPictureSupported
        let possible = pip.isPictureInPicturePossible
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }

        let shouldStart = isRunning
            && !isClosing
            && !active
            && !paused
            && playbackReady
            && supported

        let skipReason: String
        if shouldStart {
            skipReason = "none"
        } else if !isRunning {
            skipReason = "not-running"
        } else if isClosing {
            skipReason = "closing"
        } else if active {
            skipReason = "already-active"
        } else if paused {
            skipReason = "paused"
        } else if !playbackReady {
            skipReason = "playback-not-started"
        } else if !supported {
            skipReason = "unsupported"
        } else {
            skipReason = "unknown"
        }

        logPictureInPicture("MPV app-exit auto PiP check source=\(source) shouldStart=\(shouldStart) skipReason=\(skipReason) appState=\(appState) active=\(active) possible=\(possible) supported=\(supported) paused=\(paused) ready=\(playbackReady) loading=\(isRendererLoading) requested=\(mpvAppExitPiPStartRequested) subs={\(subtitlePictureInPictureDebugSnapshot())} renderer={\(rendererPictureInPictureDebugSnapshot())}")

        if source.contains("background") || appState == "background" {
            scheduleMPVBackgroundAudioFallback(source: source)
        }

        guard shouldStart else { return }
        guard !mpvAppExitPiPStartRequested else {
            logPictureInPicture("MPV app-exit auto PiP already requested; ignoring duplicate source=\(source)")
            return
        }

        mpvAppExitPiPStartRequested = true
        startMPVPictureInPictureWhenPossible(source: source)
    }

    @objc private func sceneWillDeactivate() {
        logPictureInPicture("lifecycle notification received source=scene-will-deactivate")
        if Thread.isMainThread {
            attemptMPVAppExitPictureInPictureStart(source: "scene-will-deactivate")
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.attemptMPVAppExitPictureInPictureStart(source: "scene-will-deactivate")
            }
        }
    }

    @objc private func sceneDidEnterBackground() {
        logPictureInPicture("lifecycle notification received source=scene-did-enter-background")
        if Thread.isMainThread {
            attemptMPVAppExitPictureInPictureStart(source: "scene-did-enter-background")
            scheduleMPVBackgroundAudioFallback(source: "scene-did-enter-background")
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.attemptMPVAppExitPictureInPictureStart(source: "scene-did-enter-background")
                self?.scheduleMPVBackgroundAudioFallback(source: "scene-did-enter-background")
            }
        }
    }

    private func scheduleMPVBackgroundAudioFallback(source: String, delay: TimeInterval = 0.75, force: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  !self.isVLCPlayer,
                  !self.isClosing,
                  UIApplication.shared.applicationState == .background else {
                return
            }
            let active = self.pipController?.isPictureInPictureActive ?? false
            guard !active, !self.rendererIsPausedState() else { return }
            if self.mpvAppExitPiPStartRequested && !force {
                self.logPictureInPicture("MPV background fallback waiting for pending PiP source=\(source)")
                self.scheduleMPVBackgroundAudioFallback(source: source, delay: 1.25, force: true)
                return
            }
            self.logPictureInPicture("MPV background fallback pause source=\(source) active=\(active) requested=\(self.mpvAppExitPiPStartRequested) renderer={\(self.rendererPictureInPictureDebugSnapshot())}")
            self.mpvAppExitPiPStartRequested = false
            self.rendererPausePlayback()
        }
    }
    
    @objc private func appDidEnterBackground() {
        logPictureInPicture("lifecycle notification received source=did-enter-background")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logVLCUIViewSnapshot("appDidEnterBackground async start")
            if let vlc = self.vlcRenderer {
                let pipEnabled = Settings.shared.vlcPiPEnabled
                let paused = self.rendererIsPausedState()
                let active = vlc.isPictureInPictureActive
                let available = vlc.isPictureInPictureAvailable
                let shouldStartPiP = pipEnabled && available && !active && !paused
                let skipReason: String
                if shouldStartPiP {
                    skipReason = "none"
                } else if !pipEnabled {
                    skipReason = "setting-off"
                } else if !available {
                    skipReason = "unavailable"
                } else if active {
                    skipReason = "already-active"
                } else if paused {
                    skipReason = "paused"
                } else {
                    skipReason = "unknown"
                }
                Logger.shared.log("[PlayerVC.PiP] VLC background check active=\(active) available=\(available) paused=\(paused) enabled=\(pipEnabled) shouldStart=\(shouldStartPiP) skipReason=\(skipReason)", type: "Player")
                if shouldStartPiP {
                    let started = vlc.startPictureInPicture()
                    Logger.shared.log("[PlayerVC.PiP] VLC background auto-start requested result=\(started)", type: "Player")
                }
                self.logVLCUIViewSnapshot("appDidEnterBackground async end")
                self.scheduleVLCUIViewSnapshots("appDidEnterBackground followup", delays: [0.5, 1.5])
                return
            }

            self.attemptMPVAppExitPictureInPictureStart(source: "did-enter-background")
            self.scheduleMPVBackgroundAudioFallback(source: "did-enter-background")
        }
    }
    
    @objc private func appWillEnterForeground() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logVLCUIViewSnapshot("appWillEnterForeground async start")
#if !os(tvOS)
            if self.supportsSharedPlayerControls {
                self.refreshGestureControlLevels(animated: false)
            }
#endif
            if let vlc = self.vlcRenderer {
                Logger.shared.log("[PlayerVC.PiP] VLC foreground check active=\(vlc.isPictureInPictureActive) available=\(vlc.isPictureInPictureAvailable) enabled=\(Settings.shared.vlcPiPEnabled) paused=\(self.rendererIsPausedState())", type: "Player")
                if vlc.isPictureInPictureActive {
                    Logger.shared.log("[PlayerVC.PiP] returning to foreground; stopping native VLC PiP", type: "Player")
                    vlc.stopPictureInPicture()
                } else {
                    Logger.shared.log("[PlayerVC.PiP] foreground did not stop PiP because native VLC PiP was inactive", type: "Player")
                }
                self.logVLCUIViewSnapshot("appWillEnterForeground async end")
                self.scheduleVLCUIViewSnapshots("appWillEnterForeground followup")
                return
            }
            guard let pip = self.pipController else { return }
            self.mpvPiPStartAttemptID += 1
            self.mpvAppExitPiPStartRequested = false
            if pip.isPictureInPictureActive {
                self.logMPV("Returning to foreground; stopping PiP renderer={\(self.rendererPictureInPictureDebugSnapshot())}")
                pip.stopPictureInPicture()
            } else {
                self.rendererFinishPictureInPicture()
            }
            self.logVLCUIViewSnapshot("appWillEnterForeground async end")
        }
    }

    private func restoreMPVForegroundIfNeeded(source: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.vlcRenderer == nil else { return }
            guard let pip = self.pipController else { return }
            self.mpvPiPStartAttemptID += 1
            self.mpvAppExitPiPStartRequested = false
            if pip.isPictureInPictureActive {
                self.logMPV("\(source): stopping MPV PiP for foreground return renderer={\(self.rendererPictureInPictureDebugSnapshot())}")
                pip.stopPictureInPicture()
            } else {
                self.logMPV("\(source): PiP inactive; restoring MPV foreground render path renderer={\(self.rendererPictureInPictureDebugSnapshot())}")
                self.rendererFinishPictureInPicture()
            }
        }
    }

    @objc private func sceneWillEnterForeground() {
        restoreMPVForegroundIfNeeded(source: "scene-will-enter-foreground")
    }

    @objc private func appDidBecomeActive() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.vlcRenderer == nil else { return }
            self.logMPV("appDidBecomeActive foreground render recovery renderer={\(self.rendererPictureInPictureDebugSnapshot())}")
            self.rendererResumeForegroundRendering(reason: "app-did-become-active")
        }
    }

    @objc private func sceneDidActivate() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.vlcRenderer == nil else { return }
            self.logMPV("sceneDidActivate foreground render recovery")
            self.rendererResumeForegroundRendering(reason: "scene-did-activate")
        }
    }
}
