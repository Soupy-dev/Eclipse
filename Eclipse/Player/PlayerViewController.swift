//
//  PlayerViewController.swift
//  test
//
//  Created by Francesco on 28/09/25.
//

import UIKit
import SwiftUI
import AVFoundation
import Combine
#if os(iOS)
import GroupActivities
#endif
#if canImport(Darwin)
import Darwin
#endif
#if canImport(ImageIO)
import ImageIO
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

/// Shared progress persistence for local playback. ProgressManager remains
/// authoritative for completion/removal rules, while Trakt receives the same
/// normalized position and episode identity.
@MainActor
private enum PlaybackProgressPersistence {
    static func persist(
        mediaInfo: MediaInfo,
        position: Double,
        duration: Double,
        playbackContext: EpisodePlaybackContext?,
        owner: UUID,
        progressAuthority: ProgressManager.ProfileMutationAuthority?,
        traktAction: TraktScrobbleAction? = nil
    ) {
        guard position.isFinite,
              duration.isFinite,
              duration >= 5,
              position >= 0,
              position <= duration + 2 else { return }
        let safePosition = min(position, duration)

        switch mediaInfo {
        case .movie(let id, let title, let posterURL, _):
            ProgressManager.shared.updateMovieProgress(
                movieId: id,
                title: title,
                currentTime: safePosition,
                totalDuration: duration,
                posterURL: posterURL,
                owner: owner
            )
        case .episode(let showID, let season, let episode, let showTitle, let posterURL, let isAnime):
            ProgressManager.shared.updateEpisodeProgress(
                showId: showID,
                seasonNumber: season,
                episodeNumber: episode,
                currentTime: safePosition,
                totalDuration: duration,
                showTitle: showTitle,
                showPosterURL: posterURL,
                playbackContext: playbackContext,
                isAnime: isAnime || playbackContext?.hasAnimeMediaId == true,
                owner: owner
            )
        }

        if let traktAction, safePosition > 0.5 {
            TrackerManager.shared.scrobbleTraktPlayback(
                traktAction,
                for: mediaInfo,
                progress: min(max(safePosition / duration, 0), 1),
                playbackContext: playbackContext,
                requiredOwner: owner,
                progressAuthority: progressAuthority
            )
        }
    }
}

final class PlayerPerformanceOverlayLabel: UILabel {
    var textInsets = UIEdgeInsets(top: 6, left: 9, bottom: 6, right: 9)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitted = super.sizeThatFits(size)
        return CGSize(
            width: fitted.width + textInsets.left + textInsets.right,
            height: fitted.height + textInsets.top + textInsets.bottom
        )
    }
}


#if !os(tvOS)
private final class NextEpisodePreviewButton: UIButton {
    private let posterImageView = UIImageView()
    private let upNextLabel = UILabel()
    private let episodeTitleLabel = UILabel()
    private var isPosterMode = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configurePosterSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePosterSubviews()
    }

    override var intrinsicContentSize: CGSize {
        isPosterMode ? CGSize(width: 420, height: 106) : super.intrinsicContentSize
    }

    func applyTextMode() {
        isPosterMode = false
        posterImageView.isHidden = true
        upNextLabel.isHidden = true
        episodeTitleLabel.isHidden = true
        backgroundColor = nil
        layer.borderWidth = 0
        layer.cornerRadius = 0
        layer.cornerCurve = .continuous

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.2)
        config.baseForegroundColor = UIColor.white
        config.image = UIImage(systemName: "forward.end.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.imagePlacement = .leading
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 18)
        config.title = "Next Episode"
        config.titleLineBreakMode = .byTruncatingTail
        configuration = config
        contentHorizontalAlignment = .center
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func applyPosterMode(image: UIImage, episodeText: String) {
        isPosterMode = true
        configuration = nil
        setTitle(nil, for: .normal)
        setImage(nil, for: .normal)
        backgroundColor = UIColor.black.withAlphaComponent(0.82)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor

        posterImageView.isHidden = false
        upNextLabel.isHidden = false
        episodeTitleLabel.isHidden = false
        posterImageView.image = image
        upNextLabel.text = "Up Next"
        episodeTitleLabel.text = episodeText
        contentHorizontalAlignment = .leading
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func updatePosterArtwork(_ image: UIImage) {
        guard isPosterMode else { return }
        posterImageView.image = image
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isPosterMode else { return }

        let inset: CGFloat = 8
        let spacing: CGFloat = 12
        let availableHeight = max(0, bounds.height - inset * 2)
        let artworkWidth = min(160, max(108, bounds.width * 0.42))
        let artworkHeight = min(availableHeight, artworkWidth * 9 / 16)
        let artworkSize = CGSize(width: artworkHeight * 16 / 9, height: artworkHeight)
        let artworkY = (bounds.height - artworkSize.height) / 2
        posterImageView.frame = CGRect(x: inset, y: artworkY, width: artworkSize.width, height: artworkSize.height)

        let textX = posterImageView.frame.maxX + spacing
        let textWidth = max(0, bounds.width - textX - 16)
        let labelHeight: CGFloat = 16
        let titleHeight = min(42, max(22, bounds.height - 48))
        let totalTextHeight = labelHeight + 4 + titleHeight
        let textY = max(inset, (bounds.height - totalTextHeight) / 2)
        upNextLabel.frame = CGRect(x: textX, y: textY, width: textWidth, height: labelHeight)
        episodeTitleLabel.frame = CGRect(x: textX, y: upNextLabel.frame.maxY + 4, width: textWidth, height: titleHeight)
    }

    private func configurePosterSubviews() {
        posterImageView.contentMode = .scaleAspectFill
        posterImageView.clipsToBounds = true
        posterImageView.layer.cornerRadius = 8
        posterImageView.layer.cornerCurve = .continuous
        posterImageView.isUserInteractionEnabled = false
        posterImageView.isHidden = true

        upNextLabel.font = UIFont.systemFont(ofSize: 11, weight: .bold)
        upNextLabel.textColor = UIColor.white.withAlphaComponent(0.68)
        upNextLabel.isUserInteractionEnabled = false
        upNextLabel.isHidden = true

        episodeTitleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        episodeTitleLabel.textColor = .white
        episodeTitleLabel.numberOfLines = 2
        episodeTitleLabel.lineBreakMode = .byTruncatingTail
        episodeTitleLabel.isUserInteractionEnabled = false
        episodeTitleLabel.isHidden = true

        addSubview(posterImageView)
        addSubview(upNextLabel)
        addSubview(episodeTitleLabel)
    }
}
#endif

final class PlayerViewController: UIViewController, UIGestureRecognizerDelegate {
    private struct PlayerSkinAppearance {
        let primary: UIColor
        let secondary: UIColor
        let overlayBackground: UIColor
        let centerButtonBackground: UIColor
        let menuBackground: UIColor
        let inactive: UIColor

        static let defaultAppearance = PlayerSkinAppearance(
            primary: .white,
            secondary: .white,
            overlayBackground: UIColor(white: 0.0, alpha: 0.4),
            centerButtonBackground: UIColor(white: 0.2, alpha: 0.5),
            menuBackground: UIColor.black.withAlphaComponent(0.88),
            inactive: UIColor.white.withAlphaComponent(0.3)
        )
    }

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
    private lazy var usesOverlayPlayerMenusForSession = false
    private var nativePlayerMenuRebuildSuppressionUntil: CFTimeInterval = 0
    private var nativePlayerMenuRefreshWorkItem: DispatchWorkItem?
    private var pendingNativePlayerMenuRefreshKinds = Set<String>()
    private let nativePlayerMenuRebuildSuppressionInterval: TimeInterval = 1.0
    private let moltenVKNativePlayerMenuRebuildSuppressionInterval: TimeInterval = 2.5
    private var nativeSpeedMenuContentSignature: String?
    private var nativeAudioMenuContentSignature: String?
    private var nativeSubtitleMenuContentSignature: String?

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

    private let loadingIndicator: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0.0
        v.isUserInteractionEnabled = false
        return v
    }()
    private var loadingIndicatorHostingController: UIHostingController<AnyView>?
    private var loadingIndicatorShouldBeVisible = false

    private let playerSkinDecorationLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.name = "playerSkinDecorationLayer"
        layer.opacity = 0
        return layer
    }()
    private var activePlayerSkin: MPVPlayerSkin = .defaultSkin
    private var activePlayerSkinAppearance = PlayerSkinAppearance.defaultAppearance
    private var activePlayerSkinSignature = ""
    private var activePlayerSkinTintControlsOnly = false
    private var activePlayerSkinAnimationsEnabled = MPVPlayerSkinSettings.defaultAnimationsEnabled
    private var activePlayerSkinAnimationStyle: MPVPlayerSkinAnimationStyle = .glow

    private let controlsOverlayView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = UIColor(white: 0.0, alpha: 0.4)
        v.alpha = 0.0
        v.isUserInteractionEnabled = false
        v.isHidden = true
        return v
    }()

    private let metalPerformanceOverlayLabel: PlayerPerformanceOverlayLabel = {
        let label = PlayerPerformanceOverlayLabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.numberOfLines = 0
        label.textAlignment = .left
        label.lineBreakMode = .byClipping
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

    private let playerNoticeBanner: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        container.layer.cornerRadius = 8
        container.clipsToBounds = true
        container.alpha = 0.0
        container.isHidden = true

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.numberOfLines = 2
        label.textAlignment = .center
        label.tag = 117

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
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

#if os(iOS)
    private let playbackLockButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        button.setImage(UIImage(systemName: "lock.open", withConfiguration: configuration), for: .normal)
        button.tintColor = .white
        button.alpha = 0.0
        button.isHidden = true
        button.accessibilityLabel = "Lock player"
        button.accessibilityHint = "Locks the current orientation and prevents closing the video"
        return button
    }()

    private let watchTogetherButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        button.setImage(UIImage(systemName: "person.2.fill", withConfiguration: configuration), for: .normal)
        button.tintColor = .white
        button.alpha = 0.0
        button.isHidden = true
        button.accessibilityLabel = "Watch Together"
        button.accessibilityHint = "Starts or manages secure synchronized playback with SharePlay"
        return button
    }()
#endif

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

    private let servicesButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let configuration = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        button.setImage(UIImage(systemName: "rectangle.stack.fill", withConfiguration: configuration), for: .normal)
        button.tintColor = .white
        button.alpha = 0.0
        button.isHidden = true
        button.accessibilityLabel = "Choose another source"
        button.accessibilityHint = "Opens Services for the current media"
        button.accessibilityIdentifier = "Player.Services"
        return button
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
    private var pendingContainerTapWorkItem: DispatchWorkItem?
    private let containerTapDoubleTapGraceInterval: TimeInterval = 0.22
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
    private let centerTapPlayPauseSettingKey = "playerCenterTapPlayPauseEnabled"
    private let doubleTapSeekEnabledKey = "playerDoubleTapSeekEnabled"
    private let legacyDoubleTapSeekEnabledKey = "vlcDoubleTapSeekEnabled"
    private let playerSeekSecondsKey = "playerDoubleTapSeekSeconds"
    private let legacyPlayerSeekSecondsKey = "vlcDoubleTapSeekSeconds"

    private lazy var renderer: PlayerRenderer = {
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE

        if !Settings.shared.mpvUseLegacyCPURenderer, MPVGPUPlayerBridge.isAvailable {
            let gpuQualityProfile = metalSampleBufferQualityProfile()
            Logger.shared.log("[PlayerVC.MPV] using GPU inline renderer (mpv gpu-next/MoltenVK inline, sample-buffer PiP) \(gpuQualityProfile.logDescription) \(MPVRenderBackendSupport.diagnosticsSummary)", type: "MPV")
            let r = MPVGPUPlayerBridge(pictureInPictureDisplayLayer: displayLayer, qualityProfile: gpuQualityProfile)
            r.delegate = self
            r.contentIsAnimation = isAnimationContent()
            return r
        }
        let qualityProfile = metalSampleBufferQualityProfile()
        let legacyReason = Settings.shared.mpvUseLegacyCPURenderer
            ? "user opt-out"
            : (MPVGPUPlayerBridge.unavailableReason ?? "gpu-next unavailable")
        Logger.shared.log("[PlayerVC.MPV] using single-instance MoltenVK sample-buffer renderer (inline + PiP, one mpv handle) reason=\(legacyReason) \(qualityProfile.logDescription) \(MPVRenderBackendSupport.diagnosticsSummary)", type: "MPV")
        let r = MPVSampleBufferPiPBridge(displayLayer: displayLayer, qualityProfile: qualityProfile)
        r.delegate = self
        return r
#else
        let r = MPVNativeRenderer(displayLayer: displayLayer)
        r.delegate = self
        return r
#endif
    }()

    private var mpvRenderer: MPVNativeRenderer? {
        return renderer as? MPVNativeRenderer
    }

#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
    private var metalMPVRenderer: MPVSampleBufferPiPBridge? {
        return renderer as? MPVSampleBufferPiPBridge
    }

    private var gpuMPVRenderer: MPVGPUPlayerBridge? {
        return renderer as? MPVGPUPlayerBridge
    }
#endif

    private var isMPVRenderer: Bool {
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        return metalMPVRenderer != nil || gpuMPVRenderer != nil
#else
        return mpvRenderer != nil
#endif
    }

    private var isMetalMPVRenderer: Bool {
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        return metalMPVRenderer != nil || gpuMPVRenderer != nil
#else
        return false
#endif
    }

    private var isSampleBufferMetalRenderer: Bool {
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        return metalMPVRenderer != nil
#else
        return false
#endif
    }

    private var mpvRendererName: String {
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        if gpuMPVRenderer != nil { return "moltenvk-gpu-next" }
        if metalMPVRenderer != nil { return "moltenvk-sample-buffer" }
#endif
        if mpvRenderer != nil { return "unavailable" }
        return "none"
    }

    private var vlcRenderer: MPVNativeRenderer? {
        return nil
    }

#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
    private func metalSampleBufferQualityProfile() -> MPVMetalSampleBufferQualityProfile {
        let requestedProfile = Settings.shared.mpvMetalQualityProfile
        let classification = smartPlayerMediaClassification()
        let device = metalDeviceCapabilitySummary()

        switch requestedProfile {
        case .sharp:
            return .sharp(reason: "manual sharp; \(device.reason)")
        case .balanced:
            return .balanced(reason: "manual balanced; \(device.reason)")
        case .lowHeat:
            return .lowHeat(reason: "manual low heat; \(device.reason)")
        case .auto:
            switch ProcessInfo.processInfo.thermalState {
            case .critical:
                return .lowHeat(reason: "auto thermal=critical; \(device.reason)", isAutomatic: true)
            case .serious:
                return .lowHeat(reason: "auto thermal=serious; \(device.reason)", isAutomatic: true)
            case .fair:

                return .balanced(reason: "auto thermal=fair; \(device.reason)", isAutomatic: true)
            default:
                let safeText = classification.safeReason ?? "no risky stream markers"
                if let riskReason = classification.riskReason {
                    return .sharp(reason: "auto starts sharp despite \(riskReason); \(device.reason)", isAutomatic: true)
                }
                return .sharp(reason: "auto starts sharp \(safeText); \(device.reason)", isAutomatic: true)
            }
        }
    }

    private func metalDeviceCapabilitySummary() -> (isConstrained: Bool, isThermallyConstrained: Bool, reason: String, thermalState: String) {
        let processInfo = ProcessInfo.processInfo
        let screen = currentPlaybackScreen()
        let memoryGB = Double(processInfo.physicalMemory) / 1_073_741_824.0
        let processorCount = processInfo.processorCount
        let maximumFPS = screen.maximumFramesPerSecond
        let longestPixelSide = max(screen.nativeBounds.width, screen.nativeBounds.height)
        let thermalState = metalThermalStateName(processInfo.thermalState)
        let isThermallyConstrained = processInfo.thermalState == .serious || processInfo.thermalState == .critical
        let lowMemory = processInfo.physicalMemory > 0 && memoryGB <= 3.25
        let lowCPU = processorCount > 0 && processorCount <= 4
        let smallStandardDisplay = UIDevice.current.userInterfaceIdiom == .phone && maximumFPS <= 60 && longestPixelSide <= 1800
        let isConstrained = isThermallyConstrained || lowMemory || lowCPU || smallStandardDisplay
        let reason = String(
            format: "device=%@ memory=%.1fGB cores=%d screenMaxFPS=%d longestPixels=%.0f thermal=%@",
            UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            memoryGB,
            processorCount,
            maximumFPS,
            longestPixelSide,
            thermalState
        )
        return (
            isConstrained: isConstrained,
            isThermallyConstrained: isThermallyConstrained,
            reason: reason,
            thermalState: thermalState
        )
    }

    private func currentPlaybackScreen() -> UIScreen {
        if let screen = view.window?.windowScene?.screen {
            return screen
        }
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first ?? UIScreen.main
    }

    private func metalThermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

#if os(iOS) && ECLIPSE_MPVKIT_METAL_LIVE_QUALITY_RECONFIGURE
    private func startMetalThermalQualityMonitoringIfNeeded() {
        guard Settings.shared.mpvMetalQualityProfile == .auto,
              metalMPVRenderer != nil || gpuMPVRenderer != nil else { return }
        evaluateMetalThermalQuality(reason: "startup")
        metalThermalQualityTimer?.invalidate()
        let timer = Timer(timeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.evaluateMetalThermalQuality(reason: "timer")
        }
        metalThermalQualityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func metalThermalStateDidChange() {
        evaluateMetalThermalQuality(reason: "thermal-notification")
    }

    private func evaluateMetalThermalQuality(reason: String) {
        guard Settings.shared.mpvMetalQualityProfile == .auto else { return }

        let resolvedProfile = metalSampleBufferQualityProfile()
        let changed: Bool
        if let metalMPVRenderer {
            changed = metalMPVRenderer.updateSampleBufferQualityProfile(resolvedProfile)
        } else if let gpuMPVRenderer {
            changed = gpuMPVRenderer.updateQualityProfile(resolvedProfile)
        } else {
            return
        }
        if changed {
            Logger.shared.log("[PlayerVC.MPV] Auto MoltenVK quality changed reason=\(reason) renderer=\(mpvRendererName) \(resolvedProfile.logDescription)", type: "MPV")
        }

        let thermalState = ProcessInfo.processInfo.thermalState
        let isBadThermalState = thermalState == .serious || thermalState == .critical
        if isBadThermalState {
            if !hasShownThermalQualityNotice {
                hasShownThermalQualityNotice = true
                showPlayerNotice("Eclipse detected bad thermal state, protecting device")
            }
        } else {
            hasShownThermalQualityNotice = false
        }
    }
#endif
#endif

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
            ("av1", "AV1 stream")
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
        return false
    }

    private var supportsSharedPlayerControls: Bool {
        isMPVRenderer
    }

    var mediaInfo: MediaInfo?
    var imdbId: String?
    var playerTitleOverride: String?

    var isAnimeHint: Bool?

    var isAnimationContentHint: Bool?

    var originalTMDBSeasonNumber: Int?
    var originalTMDBEpisodeNumber: Int?
    var episodePlaybackContext: EpisodePlaybackContext?
    var servicesSelectionContext: PlayerServicesSelectionContext?

    var servicesOriginalAudioLanguage: String? {
        Self.normalizedNonemptyString(servicesSelectionContext?.originalAudioLanguage)
            ?? Self.normalizedNonemptyString(activePlaybackRequest?.servicesOriginalAudioLanguage)
    }

    var onRequestNextEpisode: ((_ seasonNumber: Int, _ nextEpisodeNumber: Int) -> Void)?
    var onRequestResolvedNextEpisode: ((ResolvedNextEpisodeTarget) -> Void)?
    var localNextEpisodeFallback: PlaybackEpisodeCoordinate?

    private var skipSegments: [SkipSegment] = []
    private var skipDataFetched = false
    private var autoSkippedSegments: Set<String> = []
    private var currentActiveSkipSegment: SkipSegment?
    private var pendingNextEpisodeRequest: (seasonNumber: Int, episodeNumber: Int)?
    private var pendingResolvedNextEpisodeRequest: ResolvedNextEpisodeTarget?
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

    private lazy var nextEpisodeButton: NextEpisodePreviewButton = {
        let btn = NextEpisodePreviewButton()
        btn.applyTextMode()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.alpha = 0
        btn.isHidden = true
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = 0.3
        btn.layer.shadowOffset = CGSize(width: 0, height: 2)
        btn.layer.shadowRadius = 4
        btn.layer.cornerCurve = .continuous
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
    private var lastVLCUISteadyHeartbeatLogTime: CFTimeInterval = 0
    private var lastVLCUIMemoryWarningLogTime: CFTimeInterval = 0
    private var lastPiPButtonVisibilityLogKey: String?
    private var lastSkippedCloseTraktSyncReason: String?
    private var lastRendererPauseScrobbleAction: TraktScrobbleAction?
    private var lastRendererPauseScrobbleAt: CFTimeInterval = 0
    private let traktPlaybackSpeedChangeTolerance: Double = 0.01
    private var didSendFinalTraktScrobble = false

    private var isRendererLoading: Bool = false
    private var isClosing = false

    private let playbackProfileAuthority: (
        owner: UUID,
        progress: ProgressManager.ProfileMutationAuthority?
    ) = {
        let owner = ProfileManager.shared.activeProfileID
        return (
            owner,
            ProgressManager.shared.profileMutationAuthority(requiredOwner: owner)
        )
    }()
    private var playbackOwnerProfileID: UUID { playbackProfileAuthority.owner }

    private var activeProfileWillChangeCancellable: AnyCancellable?
    private var reportedAbandonedProfileWrites: Set<String> = []
    private var hasBegunMediaStatePlaybackLease = false
    private var hasEndedMediaStatePlaybackLease = false
    private var hasFinalizedMediaStatePlayback = false
    private var isRunning = false
    private var isIdleTimerDisabledForPlayback = false
    private var isVLCPlaybackStartupInProgress = false
    private var canMutateVLCSubtitleTracks = false
    private var didHandleVLCReadyToSeekForCurrentLoad = false
    private var didLogDuplicateVLCReadyToSeekForCurrentLoad = false
    private var vlcSubtitleStyleReloadProgressGate: VLCSubtitleStyleReloadProgressGate?
    private var vlcSubtitleStyleReloadProgressGateID = 0
    private var playbackReplacementGeneration = 0
    private var isReplacingVLCPlaybackInPlace = false
    private var pipController: PiPController?

    private static weak var mostRecentlyActivatedPlaybackController: PlayerViewController?
    private static weak var appExitPictureInPictureOwner: PlayerViewController?

    private weak var playbackWindowScene: UIWindowScene?
    private let playerInterfaceCoverageIdentifier = UUID().uuidString
    private var mpvPiPStartAttemptID = 0
    private var mpvExpectedPiPCallbackAttemptID: Int?
    private var mpvActivePiPCallbackAttemptID: Int?
    private struct MPVPictureInPictureRestoreKey: Equatable {
        let controllerIdentifier: ObjectIdentifier
        let playbackLoadGeneration: Int
        let transitionAttemptID: Int
    }
    private struct MPVPictureInPictureStopAuthorization {
        let id: Int
        let key: MPVPictureInPictureRestoreKey
        let lifecycleGeneration: Int
    }
    private struct MPVBackgroundAudioFallbackKey: Equatable {
        let lifecycleGeneration: Int
        let loadGeneration: Int
        let controllerIdentifier: ObjectIdentifier?
        let transitionAttemptID: Int?
    }

    private struct MPVAutomaticPictureInPictureAuthorization {
        let controllerIdentifier: ObjectIdentifier
        let loadGeneration: Int
        let transitionAttemptID: Int
        let playbackIntentGeneration: Int
    }
    private var mpvPictureInPictureRestoreOperationID = 0
    private var mpvPictureInPictureRestoreOperation: (
        id: Int,
        key: MPVPictureInPictureRestoreKey,
        task: Task<Bool, Never>
    )?
    private var mpvCompletedPictureInPictureRestore: (
        id: Int,
        key: MPVPictureInPictureRestoreKey,
        restored: Bool
    )?
    private var mpvPictureInPictureStopAuthorizationID = 0
    private var mpvPictureInPictureStopAuthorization: MPVPictureInPictureStopAuthorization?
    private var mpvPiPPlaybackStateUpdateGeneration = 0
    private var mpvAppExitPiPStartRequested = false
    private var mpvPendingAppExitPiPWorkItem: DispatchWorkItem?
    private var mpvAppExitPiPSuppressedUntilForeground = false

    private var mpvBackgroundLifecycleGeneration = 0
    private var mpvBackgroundLifecycleIsArmed = false
    private var mpvBackgroundLifecycleIsInForegroundPhase = false
    private var mpvForegroundRecoveryRetryCount = 0
    private var mpvForegroundRecoveryTask: Task<Void, Never>?
    private var rendererPlaybackIntentGeneration = 0
    private var mpvAutomaticPictureInPictureAuthorization: MPVAutomaticPictureInPictureAuthorization?
    private var mpvBackgroundFallbackAutoPaused = false
    private var mpvBackgroundFallbackPauseIntentGeneration: Int?
    private var mpvBackgroundFallbackPauseLifecycleGeneration: Int?
    private var mpvBackgroundAudioFallbackKey: MPVBackgroundAudioFallbackKey?
    private var mpvBackgroundAudioFallbackDeadline: CFTimeInterval = 0
    private var mpvBackgroundAudioFallbackWorkItem: DispatchWorkItem?
    private var mpvPictureInPictureRendererHandoffGeneration = 0
    private var mpvPictureInPictureRendererHandoffIsActive = false
    private enum MPVForegroundRecoveryOutcome {
        case completed
        case retryInlineRestore
        case failed
    }
    private var initialURL: URL?
    private var initialPreset: PlayerPreset?
    private var initialHeaders: [String: String]?
    private var initialSubtitles: [String]?
    private var initialSubtitleNames: [String]?
    private var initialSubtitleHeadersByURL: [String: [String: String]]?
#if os(iOS)
    var activePlaybackRequest: PlaybackRequest?
#endif

    private var playbackMediaSelectionIntent: PlaybackMediaSelectionIntent?
    var playbackLaunchContext: PlaybackLaunchContext?
    private var ephemeralProxySessionLease: PlaybackProxySessionOwnership.Lease?
    var onPlaybackStartupFailure: ((PlaybackFailureReport) -> Void)?
    var onAutomaticPlaybackFallback: ((PlaybackFailureReport) -> Void)?
    var isCoordinatorEngineFallback = false
    var forceHeaderProxyForStartup = false
    private(set) var playbackHandoffHasAppeared = false
    private var playbackStartupWorkItem: DispatchWorkItem?
    private var playbackDidStart = false
    private var playbackFailureHandled = false
    private var cloudflareStartupRecoveryInProgress = false

    private var mediaSourceRefreshAttemptCount = 0
    private var lastMediaSourceRefreshAttemptAt: Date?

    private var pendingSourceRefreshResumePosition: Double?
    private var playbackSlowProbeCount = 0
    private var playbackLoadGeneration = 0
    private struct DeferredIPadGPUPlaybackLoad {
        let url: URL
        let preset: PlayerPreset
        let headers: [String: String]?
        let playbackShouldResumeAfterLoad: Bool?
        let generation: Int
        let queuedAt: CFTimeInterval
    }
    private var deferredIPadGPUPlaybackLoad: DeferredIPadGPUPlaybackLoad?
    private var ipadGPUPlaybackLoadGateGeneration = 0
    private var ipadGPUPlaybackLoadGateRetryGeneration: Int?
    private var playbackTraceLoadStartedAt = Date()
    private var playbackTraceLastStageAt = Date()
    private var playbackTraceLastProgressPosition: Double?
    private var playbackTraceProgressAdvanceCount = 0
    private var playbackTraceLastLoadingValue: Bool?
    private var playbackTraceLastPauseValue: Bool?
    private var mpvSilentStartupRetryKey: String?
    private var pendingRendererRestartRetryGeneration: Int?
    private var pendingPlaybackFailureAlert: UIAlertController?
    private var userSelectedAudioTrack = false
    private var userSelectedSubtitleTrack = false
    private var attemptedAudioAutoSelectSignature: String?
    private var lastAudioTracksMenuLogSignature: String?
    private var lastSubtitleTracksMenuLogSignature: String?
    private var lastDefaultSubtitleChoiceLogSignature: String?
    private var lastVLCPauseLogSignature: String?
    private var lastVLCPauseLogTime: CFTimeInterval = 0
    private var pendingInitialResumeTarget: Double?
    private var pendingInitialResumeDeadline: Date?
    private var pendingInitialResumeRetryCount = 0
    private var pendingInitialResumeLastRetryAt: Date?
    private var vlcProxyFallbackTried = false
    private var mpvTransportBridgeFallbackTried = false
    private var isMPVTransportBridgePlaybackActive = false
#if !os(tvOS)
    private var activeMPVHeaderProxyURLs = Set<URL>()
    private var midPlaybackStallTimer: Timer?
    private var midPlaybackStallReferenceDate: Date?
    private var midPlaybackStallLastPosition: Double?
#endif
    private var lastIgnoredMPVBridgeDurationLogValue: Double = -1
    private struct BackgroundRecoveryProgressGate {
        let id: Int
        let mediaKey: String
        let source: String
        let rendererName: String
        let armedAt: Date
        let baselinePosition: Double
        let baselineDuration: Double
        var foregroundedAt: Date?
        var lastSuppressionLogBucket: Int = -1
    }
    private var backgroundRecoveryProgressGate: BackgroundRecoveryProgressGate?
    private var backgroundRecoveryProgressGateID = 0
    private let backgroundRecoveryProgressSuppressionWindow: TimeInterval = 12.0
    private let backgroundRecoveryProgressMaxGuardWindow: TimeInterval = 60.0
    private let backgroundRecoveryProgressJumpTolerance: Double = 12.0
    private struct VLCSubtitleStyleReloadProgressGate {
        let id: Int
        let armedAt: Date
        var expiresAt: Date
        let baselinePosition: Double
        let baselineDuration: Double
        var lastSuppressionLogBucket: Int = -1
    }

    private var audioMenuDebounceTimer: Timer?
    private var subtitleMenuDebounceTimer: Timer?
    private var vlcSubtitleOverlayBottomConstraint: NSLayoutConstraint?
    private var subtitleTrailingToProgressConstraint: NSLayoutConstraint?
    private var subtitleTrailingToEpisodeBrowserConstraint: NSLayoutConstraint?
    private var subtitleTrailingToServicesConstraint: NSLayoutConstraint?
    private var episodeBrowserTrailingToProgressConstraint: NSLayoutConstraint?
    private var episodeBrowserTrailingToServicesConstraint: NSLayoutConstraint?
    private var episodeBrowserHostingController: UIHostingController<AnyView>?
    private var isEpisodeBrowserVisible = false
    private var nextEpisodePreview: PlayerEpisodeBrowserItem?
    private var nextEpisodePreviewKey: String?
    private var experimentalStagedNextEpisodeKey: String?
    private var nextEpisodeStagingRetryAfterByKey: [String: Date] = [:]
    private let nextEpisodeStagingRetryDelay: TimeInterval = 8
    private var nextEpisodeStagingTask: Task<Void, Never>?

    private var stagedNextEpisodeRequest: PlayerResolvedPlaybackRequest?
    private var stagedNextEpisodeRequestKey: String?
    private var nextEpisodePreviewTask: Task<Void, Never>?
    private var nextEpisodePreviewGeneration: UUID?
    private var nextEpisodePreviewUnavailableKeys: Set<String> = []
    private var pendingWatchTogetherNextEpisodeTarget: NextEpisodePlaybackTarget?
    private var pendingWatchTogetherNextEpisodeTransitionID: UUID?
    private var nextEpisodeArtworkTask: URLSessionDataTask?
    private var nextEpisodeArtworkKey: String?
    private var nextEpisodeArtworkImage: UIImage?
    private var nextEpisodeButtonAppearanceKey: String?
#if !os(tvOS)
    private var volumeTopConstraint: NSLayoutConstraint?
    private var volumeWidthConstraint: NSLayoutConstraint?
    private var volumeHeightConstraint: NSLayoutConstraint?
    private var playerTitleCenterConstraint: NSLayoutConstraint?
    private var nextEpisodeButtonMaxWidthConstraint: NSLayoutConstraint?
    private var nextEpisodeButtonBottomConstraint: NSLayoutConstraint?
#endif

    private struct SubtitleTrackDescriptor {
        let id: Int
        let name: String
        let codec: String
        let isExternalNativeTrack: Bool
    }

    private func rendererLoad(url: URL, preset: PlayerPreset, headers: [String: String]?) {
        if vlcRenderer != nil {
            logVLCUI("rendererLoad target={\(playbackURLSummary(url))} preset=\(preset.id.rawValue) headers=\(headers?.count ?? 0) pendingSeek=\(secondsText(pendingSeekTime)) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))", type: "Stream")
        } else {
            logMPV("rendererLoad target={\(playbackURLSummary(url))} preset=\(preset.id.rawValue) headers=\(headers?.count ?? 0) pendingSeek=\(secondsText(pendingSeekTime)) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))")
        }
        renderer.load(url: url, with: preset, headers: headers)
#if !os(tvOS)
        if isMPVRenderer {
            releaseMPVHeaderProxySessions(retaining: isLocalProxyURL(url) ? url : nil)
        }
#endif
        invalidateRendererTrackCaches()
    }

    private func rendererReloadCurrentItem() {
        if vlcRenderer != nil {
            logVLCUI("rendererReloadCurrentItem cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))", type: "Stream")
        }
        renderer.reloadCurrentItem()
        invalidateRendererTrackCaches()
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

    private func rendererStop(retainingMPVHeaderProxyURL retainedProxyURL: URL? = nil) {
        if vlcRenderer != nil {
            logVLCUI("rendererStop requested cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))", type: "Stream")
        } else {
            logMPV("rendererStop requested cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) pipActive=\(pipController?.isPictureInPictureActive == true)")
        }
        mpvPiPPlaybackStateUpdateGeneration &+= 1
        mpvForegroundRecoveryTask?.cancel()
        mpvForegroundRecoveryTask = nil
        mpvBackgroundLifecycleIsArmed = false
        mpvBackgroundLifecycleIsInForegroundPhase = false
        mpvBackgroundFallbackAutoPaused = false
        mpvBackgroundFallbackPauseIntentGeneration = nil
        mpvBackgroundFallbackPauseLifecycleGeneration = nil
        cancelMPVBackgroundAudioFallback(reason: "renderer-stop")
        mpvPictureInPictureRendererHandoffGeneration &+= 1
        mpvPictureInPictureRendererHandoffIsActive = false
        invalidateMPVPictureInPictureRestoreOperation(reason: "renderer-stop")
        invalidateMPVPictureInPictureStopAuthorization(reason: "renderer-stop")
        let pipState = mpvPictureInPictureControllerState()
        cancelMPVPictureInPictureStartRequests(reason: "renderer-stop")
        pipController?.setCanStartPictureInPictureAutomaticallyFromInline(false)
        if pipState.active || pipState.pending {
            pipController?.stopPictureInPicture(source: "renderer-stop")
            rendererFinishPictureInPicture()
        }
        releaseMPVAppExitPictureInPictureOwnership(reason: "renderer-stop")
        cancelScheduledMPVPictureInPictureWarmups(reason: "renderer-stop")
        renderer.stop()
#if !os(tvOS)
        releaseMPVHeaderProxySessions(retaining: retainedProxyURL)
#endif
        isRunning = false
        mpvExpectedPiPCallbackAttemptID = nil
        mpvActivePiPCallbackAttemptID = nil
        refreshIdleTimerForPlayback(reason: "renderer-stop")
        isVLCPlaybackStartupInProgress = false
        canMutateVLCSubtitleTracks = false
        didHandleVLCReadyToSeekForCurrentLoad = false
        didLogDuplicateVLCReadyToSeekForCurrentLoad = false
    }

    private func rendererStopAndWait(retainingMPVHeaderProxyURL retainedProxyURL: URL? = nil) async {
        rendererStop(retainingMPVHeaderProxyURL: retainedProxyURL)
        await renderer.waitUntilStopped()
    }

    private func rendererPlay(recordingPlaybackIntent: Bool = true) {
        if recordingPlaybackIntent {

            rendererPlaybackIntentGeneration &+= 1
            mpvBackgroundFallbackAutoPaused = false
            mpvBackgroundFallbackPauseIntentGeneration = nil
            mpvBackgroundFallbackPauseLifecycleGeneration = nil
        }
        if vlcRenderer != nil {
            logVLCUI("rendererPlay requested cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)", type: "Stream")
        } else {
            logMPV("rendererPlay requested cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)")
        }
        renderer.play()
        rendererSchedulePictureInPicturePlaybackStateUpdate()
    }

    private func rendererPausePlayback(
        preservingBackgroundFallbackOwnership: Bool = false
    ) {
        if !preservingBackgroundFallbackOwnership {
            rendererPlaybackIntentGeneration &+= 1
            mpvBackgroundFallbackAutoPaused = false
            mpvBackgroundFallbackPauseIntentGeneration = nil
            mpvBackgroundFallbackPauseLifecycleGeneration = nil
        }
        if vlcRenderer != nil {
            logVLCUI("rendererPause requested cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)", type: "Stream")
        } else {
            logMPV("rendererPause requested cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)")
        }
        renderer.pausePlayback()
        rendererSchedulePictureInPicturePlaybackStateUpdate()
    }

    private func rendererTogglePause() {
        rendererPlaybackIntentGeneration &+= 1
        mpvBackgroundFallbackAutoPaused = false
        mpvBackgroundFallbackPauseIntentGeneration = nil
        mpvBackgroundFallbackPauseLifecycleGeneration = nil
        if vlcRenderer != nil {
            logVLCUI("rendererTogglePause requested paused=\(rendererIsPausedState()) loading=\(isRendererLoading) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))", type: "VLCPlayback")
        } else {
            logMPV("rendererTogglePause requested paused=\(rendererIsPausedState()) loading=\(isRendererLoading) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))")
        }
        renderer.togglePause()
        rendererSchedulePictureInPicturePlaybackStateUpdate()
    }

    private func refreshIdleTimerForPlayback(reason: String) {
        let shouldDisable = isRunning
            && !isClosing
            && playbackDidStart
            && !rendererIsPausedState()
        setIdleTimerDisabledForPlayback(shouldDisable, reason: reason)
    }

    private func setIdleTimerDisabledForPlayback(_ disabled: Bool, reason: String) {
        guard isIdleTimerDisabledForPlayback != disabled else { return }
        isIdleTimerDisabledForPlayback = disabled
        let apply = {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
        logSharedPlayerControl("idle timer disabled=\(disabled) reason=\(reason)")
    }

    private func currentTraktProgressFraction() -> Double? {
        guard let mediaInfo,
              isRunning,
              !isClosing,
              playbackDidStart,
              !isRendererLoading,
              cachedPosition.isFinite,
              cachedDuration.isFinite,
              cachedDuration >= 5,
              cachedPosition > 0.5,
              cachedPosition <= cachedDuration + 2 else {
            return nil
        }
        switch mediaInfo {
        case .movie, .episode:
            return min(max(cachedPosition / cachedDuration, 0), 1)
        }
    }

    private func playbackContextForTraktScrobble(_ info: MediaInfo) -> EpisodePlaybackContext? {
        guard case .episode(_, let seasonNumber, let episodeNumber, _, _, _) = info else {
            return nil
        }
        return playbackContextForCurrentEpisode(
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        )
    }

    private func playbackContextForCurrentEpisode(
        seasonNumber: Int,
        episodeNumber: Int
    ) -> EpisodePlaybackContext? {
        guard let context = episodePlaybackContext else { return nil }
        if context.hasAnimeMediaId {
            return context
        }
        guard context.localSeasonNumber == seasonNumber else { return nil }
        if context.localEpisodeNumber == episodeNumber {
            return context
        }
        return context.forEpisodeNumber(episodeNumber)
    }

    private func playbackProfileIsStillActive(_ reason: String) -> Bool {
        if ProfileManager.shared.isStillActive(playbackOwnerProfileID),
           playbackProfileAuthority.progress.map(
               ProgressManager.shared.profileMutationAuthorityIsCurrent
           ) == true {
            return true
        }
        if reportedAbandonedProfileWrites.insert(reason).inserted {
            Logger.shared.log(
                "PlayerViewController: abandoned \(reason) because the session's profile is no longer active",
                type: "Progress"
            )
        }
        return false
    }

    private func sendTraktScrobble(_ action: TraktScrobbleAction, reason: String, force: Bool = false) {
        guard playbackProfileIsStillActive("a Trakt scrobble") else { return }
        guard let info = mediaInfo,
              let progress = currentTraktProgressFraction() else { return }
        Logger.shared.log("PlayerViewController: Trakt scrobble \(action.rawValue) queued reason=\(reason) progress=\(Int((progress * 100).rounded()))%", type: "Tracker")
        TrackerManager.shared.scrobbleTraktPlayback(
            action,
            for: info,
            progress: progress,
            playbackContext: playbackContextForTraktScrobble(info),
            force: force,
            requiredOwner: playbackOwnerProfileID,
            progressAuthority: playbackProfileAuthority.progress
        )
    }

    private func syncTraktProgressOnPlaybackCloseIfNeeded(for mediaInfo: MediaInfo, reason: String) {
        let didPlay = playbackDidStart || cachedPosition > 0.5
        guard didPlay else {
            let signature = "\(reason)|\(String(describing: mediaInfo))"
            if signature != lastSkippedCloseTraktSyncReason {
                lastSkippedCloseTraktSyncReason = signature
                Logger.shared.log("PlayerViewController: skipping Trakt close sync reason=\(reason) playbackDidStart=\(playbackDidStart) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))", type: "Tracker")
            }
            return
        }
        if TrackerManager.shared.trackerState.liveTraktScrobbling {
            if sendFinalTraktStopScrobbleIfNeeded(for: mediaInfo, reason: reason) {
                return
            }
        }
        ProgressManager.shared.syncTraktProgressOnPlaybackClose(
            for: mediaInfo,
            playbackContext: episodePlaybackContext,
            played: true,
            owner: playbackOwnerProfileID,
            progressAuthority: playbackProfileAuthority.progress
        )
    }

    private func finalTraktProgressFraction() -> Double? {
        guard playbackDidStart || cachedPosition > 0.5,
              cachedPosition.isFinite,
              cachedDuration.isFinite,
              cachedDuration >= 5,
              cachedPosition > 0.5,
              cachedPosition <= cachedDuration + 2 else {
            return nil
        }
        return min(max(cachedPosition / cachedDuration, 0), 1)
    }

    @discardableResult
    private func sendFinalTraktStopScrobbleIfNeeded(for mediaInfo: MediaInfo, reason: String) -> Bool {
        guard playbackProfileIsStillActive("the final Trakt stop scrobble") else { return false }
        guard !didSendFinalTraktScrobble,
              let progress = finalTraktProgressFraction() else {
            return false
        }
        didSendFinalTraktScrobble = true
        Logger.shared.log("PlayerViewController: Trakt final stop queued reason=\(reason) progress=\(Int((progress * 100).rounded()))%", type: "Tracker")
        TrackerManager.shared.scrobbleTraktPlayback(
            .stop,
            for: mediaInfo,
            progress: progress,
            playbackContext: playbackContextForTraktScrobble(mediaInfo),
            force: true,
            requiredOwner: playbackOwnerProfileID,
            progressAuthority: playbackProfileAuthority.progress
        )
        return true
    }

    private func sendRendererPauseTraktScrobble(_ action: TraktScrobbleAction, reason: String) {
        guard currentTraktProgressFraction() != nil else { return }
        let now = CACurrentMediaTime()
        if lastRendererPauseScrobbleAction == action,
           now - lastRendererPauseScrobbleAt < 3 {
            return
        }
        lastRendererPauseScrobbleAction = action
        lastRendererPauseScrobbleAt = now
        sendTraktScrobble(action, reason: reason)
    }

    private func sendPlaybackSpeedTraktScrobbleIfNeeded(previousSpeed: Double, newSpeed: Double) {
        guard !rendererIsPausedState(),
              previousSpeed.isFinite,
              newSpeed.isFinite,
              abs(previousSpeed - newSpeed) > traktPlaybackSpeedChangeTolerance else {
            return
        }
        sendTraktScrobble(.start, reason: "playback-speed-\(String(format: "%.2f", newSpeed))x", force: true)
    }

    private func updateTraktScrobbleFromProgress(position: Double, duration: Double) {
        guard playbackProfileIsStillActive("a periodic Trakt scrobble") else { return }
        guard !rendererIsPausedState(),
              playbackDidStart,
              position.isFinite,
              duration.isFinite,
              duration >= 5,
              position > 0.5,
              position <= duration + 2,
              let info = mediaInfo else {
            return
        }
        TrackerManager.shared.scrobbleTraktPlayback(
            .start,
            for: info,
            progress: min(max(position / duration, 0), 1),
            playbackContext: playbackContextForTraktScrobble(info),
            requiredOwner: playbackOwnerProfileID,
            progressAuthority: playbackProfileAuthority.progress
        )
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
        releaseBackgroundRecoveryProgressGate(reason: "explicit-seek")
        renderer.seek(to: seconds)
        rendererSchedulePictureInPicturePlaybackStateUpdate()
    }

    private func clampedPlaybackPosition(_ position: Double) -> Double {
        let safePosition = max(0, position)
        guard cachedDuration.isFinite, cachedDuration > 5 else { return safePosition }
        return min(safePosition, cachedDuration)
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
        releaseBackgroundRecoveryProgressGate(reason: "explicit-relative-seek")
        renderer.seek(by: seconds)
        rendererSchedulePictureInPicturePlaybackStateUpdate()
    }

    private func rendererSetSpeed(_ speed: Double, notifyWatchTogether: Bool = true) {
        let previousSpeed = rendererGetSpeed()
        if vlcRenderer != nil {
            logVLCUI("rendererSetSpeed \(String(format: "%.2f", speed))", type: "Player")
        } else {
            logMPV("rendererSetSpeed \(String(format: "%.2f", speed))")
        }
        renderer.setSpeed(speed)
        rendererSchedulePictureInPicturePlaybackStateUpdate()
        sendPlaybackSpeedTraktScrobbleIfNeeded(previousSpeed: previousSpeed, newSpeed: rendererGetSpeed())
#if os(iOS)
        if notifyWatchTogether {
            WatchTogetherCoordinator.shared.sendUserPlaybackRate(speed, from: self)
        }
#endif
    }

    private func rendererGetSpeed() -> Double {
        return renderer.getSpeed()
    }

    private func currentMediaProgressKey(for info: MediaInfo? = nil) -> String? {
        guard let target = info ?? mediaInfo else {
            return nil
        }
        switch target {
        case .movie(let id, _, _, _):
            return "movie:\(id)"
        case .episode(let showId, let seasonNumber, let episodeNumber, _, _, _):
            return "episode:\(showId):\(seasonNumber):\(episodeNumber)"
        }
    }

    private func armBackgroundRecoveryProgressGateIfNeeded(source: String) {
        guard !isClosing,
              let mediaKey = currentMediaProgressKey(),
              mediaInfo != nil else {
            return
        }

        let wasPlaying = !rendererIsPausedState() && (playbackDidStart || cachedPosition > 0.1)
        guard wasPlaying else {
            if backgroundRecoveryProgressGate?.mediaKey == mediaKey {
                return
            }
            return
        }

        let now = Date()
        if let existing = backgroundRecoveryProgressGate,
           existing.mediaKey == mediaKey,
           now.timeIntervalSince(existing.armedAt) < 3.0 {
            return
        }

        backgroundRecoveryProgressGateID += 1
        let rendererName = isVLCPlayer ? "VLC" : "MPV"
        backgroundRecoveryProgressGate = BackgroundRecoveryProgressGate(
            id: backgroundRecoveryProgressGateID,
            mediaKey: mediaKey,
            source: source,
            rendererName: rendererName,
            armedAt: now,
            baselinePosition: max(0, cachedPosition),
            baselineDuration: max(0, cachedDuration)
        )
        Logger.shared.log("[PlayerVC.Recovery] armed progress gate id=\(backgroundRecoveryProgressGateID) source=\(source) renderer=\(rendererName) media=\(mediaKey) baseline=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))", type: "Progress")
    }

    private func markBackgroundRecoveryForegrounded(source: String) {
        guard var gate = backgroundRecoveryProgressGate else { return }
        if gate.foregroundedAt == nil {
            gate.foregroundedAt = Date()
            backgroundRecoveryProgressGate = gate
            Logger.shared.log("[PlayerVC.Recovery] foregrounded progress gate id=\(gate.id) source=\(source) renderer=\(gate.rendererName) baseline=\(secondsText(gate.baselinePosition))/\(secondsText(gate.baselineDuration))", type: "Progress")
        }

        let gateID = gate.id
        DispatchQueue.main.asyncAfter(deadline: .now() + backgroundRecoveryProgressMaxGuardWindow) { [weak self] in
            guard let self,
                  self.backgroundRecoveryProgressGate?.id == gateID else {
                return
            }
            self.releaseBackgroundRecoveryProgressGate(reason: "max-guard-window")
        }
    }

    private func releaseBackgroundRecoveryProgressGate(reason: String) {
        guard let gate = backgroundRecoveryProgressGate else { return }
        backgroundRecoveryProgressGate = nil
        Logger.shared.log("[PlayerVC.Recovery] released progress gate id=\(gate.id) reason=\(reason) renderer=\(gate.rendererName) media=\(gate.mediaKey) armedSource=\(gate.source)", type: "Progress")
    }

    private func setVLCSubtitleStyleReloadProgressGate(active: Bool, reason: String) {
        if active {
            guard isVLCPlayer else { return }
            vlcSubtitleStyleReloadProgressGateID += 1
            let now = Date()
            vlcSubtitleStyleReloadProgressGate = VLCSubtitleStyleReloadProgressGate(
                id: vlcSubtitleStyleReloadProgressGateID,
                armedAt: now,
                expiresAt: now.addingTimeInterval(6.0),
                baselinePosition: max(0, cachedPosition),
                baselineDuration: max(0, cachedDuration)
            )
            Logger.shared.log("[PlayerVC.Subtitles] armed VLC subtitle style progress gate id=\(vlcSubtitleStyleReloadProgressGateID) reason=\(reason) baseline=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))", type: "Progress")
        } else if var gate = vlcSubtitleStyleReloadProgressGate {
            if reason.hasPrefix("subtitle-style") {
                let settleExpiry = Date().addingTimeInterval(1.0)
                if settleExpiry < gate.expiresAt {
                    gate.expiresAt = settleExpiry
                }
                vlcSubtitleStyleReloadProgressGate = gate
                Logger.shared.log("[PlayerVC.Subtitles] VLC subtitle style progress gate id=\(gate.id) entering settle window reason=\(reason)", type: "Progress")
                return
            }
            vlcSubtitleStyleReloadProgressGate = nil
            Logger.shared.log("[PlayerVC.Subtitles] released VLC subtitle style progress gate id=\(gate.id) reason=\(reason)", type: "Progress")
        }
    }

    private func shouldPersistProgressDuringVLCSubtitleStyleReload(
        safePosition: Double,
        effectiveDuration: Double,
        durationIsReliable: Bool
    ) -> Bool {
        guard var gate = vlcSubtitleStyleReloadProgressGate else { return true }
        guard isVLCPlayer else {
            vlcSubtitleStyleReloadProgressGate = nil
            return true
        }

        let now = Date()
        let advancedPastReloadPoint = durationIsReliable
            && effectiveDuration > 0
            && safePosition >= gate.baselinePosition + 1.0

        if advancedPastReloadPoint {
            vlcSubtitleStyleReloadProgressGate = nil
            Logger.shared.log("[PlayerVC.Subtitles] released VLC subtitle style progress gate id=\(gate.id) reason=playback-advanced position=\(secondsText(safePosition))/\(secondsText(effectiveDuration)) baseline=\(secondsText(gate.baselinePosition))/\(secondsText(gate.baselineDuration))", type: "Progress")
            return true
        }

        if now >= gate.expiresAt {
            vlcSubtitleStyleReloadProgressGate = nil
            Logger.shared.log("[PlayerVC.Subtitles] released VLC subtitle style progress gate id=\(gate.id) reason=expired position=\(secondsText(safePosition))/\(secondsText(effectiveDuration))", type: "Progress")
            return true
        }

        let elapsed = max(0, now.timeIntervalSince(gate.armedAt))
        let bucket = Int(elapsed / 2.0)
        if gate.lastSuppressionLogBucket != bucket {
            gate.lastSuppressionLogBucket = bucket
            vlcSubtitleStyleReloadProgressGate = gate
            Logger.shared.log("[PlayerVC.Subtitles] suppressing progress persistence during VLC subtitle style reload id=\(gate.id) elapsed=\(String(format: "%.1f", elapsed))s position=\(secondsText(safePosition))/\(secondsText(effectiveDuration)) baseline=\(secondsText(gate.baselinePosition))/\(secondsText(gate.baselineDuration))", type: "Progress")
        }
        return false
    }

    private func shouldPersistProgressAfterBackgroundRecovery(
        safePosition: Double,
        effectiveDuration: Double,
        durationIsReliable: Bool
    ) -> Bool {
        guard var gate = backgroundRecoveryProgressGate else { return true }

        guard currentMediaProgressKey() == gate.mediaKey else {
            releaseBackgroundRecoveryProgressGate(reason: "media-changed")
            return true
        }

        guard durationIsReliable, effectiveDuration > 0 else {
            return false
        }

        let now = Date()
        let recoveryStart = gate.foregroundedAt ?? gate.armedAt
        let elapsed = max(0, now.timeIntervalSince(recoveryStart))
        let baselinePosition = max(0, gate.baselinePosition)
        let baselineDuration = max(0, gate.baselineDuration)
        let advanceThreshold = baselinePosition < 5.0 ? 1.0 : 2.0
        let advancedEnough = safePosition >= baselinePosition + advanceThreshold
        let baselineProgress = baselineDuration > 0 ? min(max(baselinePosition / baselineDuration, 0), 1) : 0
        let candidateProgress = min(max(safePosition / effectiveDuration, 0), 1)
        let crossedWatchedThreshold = baselineProgress < 0.85 && candidateProgress >= 0.85
        let allowedPlaybackAdvance = max(backgroundRecoveryProgressJumpTolerance, elapsed * max(1.0, rendererGetSpeed()) + 5.0)
        let suspiciousJump = safePosition > baselinePosition + allowedPlaybackAdvance
        let shouldSuppress = elapsed < backgroundRecoveryProgressSuppressionWindow
            || (crossedWatchedThreshold && suspiciousJump && elapsed < backgroundRecoveryProgressMaxGuardWindow)

        if advancedEnough && !suspiciousJump {
            releaseBackgroundRecoveryProgressGate(reason: "playback-advanced")
            return true
        }

        if shouldSuppress {
            let bucket = Int(elapsed / 5.0)
            if gate.lastSuppressionLogBucket != bucket {
                gate.lastSuppressionLogBucket = bucket
                backgroundRecoveryProgressGate = gate
                Logger.shared.log("[PlayerVC.Recovery] suppressing progress persistence id=\(gate.id) elapsed=\(String(format: "%.1f", elapsed))s position=\(secondsText(safePosition))/\(secondsText(effectiveDuration)) baseline=\(secondsText(baselinePosition))/\(secondsText(baselineDuration)) advanced=\(advancedEnough) suspiciousJump=\(suspiciousJump) crossedWatched=\(crossedWatchedThreshold)", type: "Progress")
            }
            return false
        }

        releaseBackgroundRecoveryProgressGate(reason: "guard-window-expired")
        return true
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
        audioTrackCacheValid = false
    }

    private func rendererGetCurrentAudioTrackId() -> Int {
        renderer.getCurrentAudioTrackId()
    }

    private func rendererGetSubtitleTracks() -> [(Int, String)] {
        renderer.getSubtitleTracks()
    }

    private func rendererGetSubtitleTrackDescriptors() -> [SubtitleTrackDescriptor] {
        let detailedTracks = renderer.getSubtitleTracksDetailed()
        if !detailedTracks.isEmpty {
            return detailedTracks.map {
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
        subtitleTrackCacheValid = false
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
        subtitleTrackCacheValid = false
    }

    private func rendererRefreshSubtitleOverlay() {
        renderer.refreshSubtitleOverlay()
    }

    private var cachedMenuSubtitleTrackDescriptors: [SubtitleTrackDescriptor] = []
    private var subtitleTrackCacheValid = false
    private var cachedMenuAudioDetailedTracks: [(Int, String, String)] = []
    private var cachedMenuCurrentAudioTrackId: Int = -1
    private var audioTrackCacheValid = false

    private func invalidateRendererTrackCaches() {
        subtitleTrackCacheValid = false
        audioTrackCacheValid = false
    }

    private func menuSubtitleTrackDescriptors() -> [SubtitleTrackDescriptor] {
        if !subtitleTrackCacheValid {
            cachedMenuSubtitleTrackDescriptors = rendererGetSubtitleTrackDescriptors()
            subtitleTrackCacheValid = true
        }
        return cachedMenuSubtitleTrackDescriptors
    }

    private func menuAudioDetailedTracks() -> [(Int, String, String)] {
        if !audioTrackCacheValid {
            cachedMenuAudioDetailedTracks = rendererGetAudioTracksDetailed()
            cachedMenuCurrentAudioTrackId = rendererGetCurrentAudioTrackId()
            audioTrackCacheValid = true
        }
        return cachedMenuAudioDetailedTracks
    }

    private func menuCurrentAudioTrackId() -> Int {
        _ = menuAudioDetailedTracks()
        return cachedMenuCurrentAudioTrackId
    }

    private func rendererLoadExternalSubtitles(urls: [String], names: [String]? = nil, enforce: Bool = false) {
        if vlcRenderer != nil {
            logVLCUI("rendererLoadExternalSubtitles count=\(urls.count) names=\(names?.count ?? 0) enforce=\(enforce) urls=\(urls.joined(separator: " | "))", type: "Player")
        } else {
            logMPV("rendererLoadExternalSubtitles count=\(urls.count) names=\(names?.count ?? 0) enforce=\(enforce) urls=\(urls.joined(separator: " | "))")
        }
        renderer.loadExternalSubtitles(urls: urls, names: names, enforce: enforce)
        subtitleTrackCacheValid = false
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
        if let value = ProfileSettingsStore.active.object(forKey: "playerSubtitleOverlayBottomConstant") as? Double {
            return CGFloat(value)
        }
        if let legacy = ProfileSettingsStore.active.object(forKey: "vlcSubtitleOverlayBottomConstant") as? Double {
            ProfileSettingsStore.active.set(legacy, forKey: "playerSubtitleOverlayBottomConstant")
            return CGFloat(legacy)
        }
        return -6.0
    }

    private func applyVLCSubtitleOverlayPositionSetting() {
        guard isVLCPlayer else { return }
        let constant = vlcSubtitleOverlayBottomConstant
        vlcSubtitleOverlayBottomConstraint?.constant = constant
        Logger.shared.log("[PlayerVC.Subtitles] applied VLC overlay bottom constant=\(String(format: "%.1f", constant))", type: "Player")
    }

    private var lastAppliedSubtitleStyleSnapshot: SubtitleStyle?

    private func rendererApplySubtitleStyle(_ style: SubtitleStyle) {
        lastAppliedSubtitleStyleSnapshot = style
        if vlcRenderer != nil {
            logVLCUI("rendererApplySubtitleStyle visible=\(style.isVisible) font=\(String(format: "%.1f", style.fontSize)) stroke=\(String(format: "%.1f", style.strokeWidth)) offset=\(String(format: "%.1f", style.verticalOffset))", type: "Player")
        } else {
            logMPV("rendererApplySubtitleStyle visible=\(style.isVisible) font=\(String(format: "%.1f", style.fontSize)) stroke=\(String(format: "%.1f", style.strokeWidth)) offset=\(String(format: "%.1f", style.verticalOffset)) ccBackground=\(style.closedCaptionBackground)")
        }
        renderer.applySubtitleStyle(style)
    }

    private func currentSubtitleStyle(visible: Bool? = nil) -> SubtitleStyle {
        SubtitleStyle(
            foregroundColor: subtitleModel.foregroundColor,
            strokeColor: subtitleModel.strokeColor,
            strokeWidth: subtitleModel.strokeWidth,
            fontSize: subtitleModel.fontSize,
            verticalOffset: subtitleModel.verticalOffset,
            isVisible: visible ?? subtitleModel.isVisible,
            closedCaptionBackground: subtitleModel.closedCaptionBackground
        )
    }

    private func rendererIsPausedState() -> Bool {
        return renderer.isPausedState
    }

    private func rendererIsPictureInPictureAvailable() -> Bool {
        if vlcRenderer != nil {
            return false
        }
        guard isMPVRenderer else {
            return false
        }
        if !canStartMPVSampleBufferPictureInPicture() {
            return false
        }
        return PiPController.isPictureInPictureSupported
    }

    private func canStartMPVSampleBufferPictureInPicture() -> Bool {
        renderer.canStartSampleBufferPictureInPicture()
    }

    private func rendererIsPictureInPictureActive() -> Bool {
        if vlcRenderer != nil {
            return false
        }
        return pipController?.isPictureInPictureActive == true
    }

    private func mpvPictureInPictureControllerState() -> (active: Bool, pending: Bool) {
        guard vlcRenderer == nil, let pip = pipController else {
            return (false, false)
        }
        return (pip.isPictureInPictureActive, pip.isPictureInPictureStartPending)
    }

    private func rendererUpdatePictureInPicturePlaybackState() {
        guard vlcRenderer == nil else { return }
        pipController?.updatePlaybackState()
    }

    private func rendererSchedulePictureInPicturePlaybackStateUpdate() {
        guard vlcRenderer == nil, let controller = pipController else { return }
        controller.updatePlaybackState()
        mpvPiPPlaybackStateUpdateGeneration &+= 1
        let updateGeneration = mpvPiPPlaybackStateUpdateGeneration
        let loadGeneration = playbackLoadGeneration
        let updatingRenderer = renderer
        Task { @MainActor [weak self, weak controller] in
            await updatingRenderer.waitForPictureInPictureTimelineUpdate()
            guard let self,
                  let controller,
                  updateGeneration == self.mpvPiPPlaybackStateUpdateGeneration,
                  loadGeneration == self.playbackLoadGeneration,
                  self.pipController === controller,
                  controller.playbackLoadGeneration == loadGeneration,
                  self.isRunning,
                  !self.isClosing else { return }
            controller.updatePlaybackState()
        }
    }

    private func armMPVPictureInPictureController(_ controller: PiPController, reason: String) {
        guard pipController === controller,
              controller.playbackLoadGeneration == playbackLoadGeneration else { return }
        invalidateMPVPictureInPictureStopAuthorization(reason: "new-transition-\(reason)")
        if let restoreKey = mpvPictureInPictureRestoreOperation?.key,
           restoreKey.transitionAttemptID != mpvPiPStartAttemptID {
            invalidateMPVPictureInPictureRestoreOperation(reason: "new-transition-\(reason)")
        }
        controller.armTransition(attemptID: mpvPiPStartAttemptID)
        mpvExpectedPiPCallbackAttemptID = mpvPiPStartAttemptID
        logPictureInPicture(
            "armed PiP controller reason=\(reason) loadGeneration=\(playbackLoadGeneration) attemptID=\(mpvPiPStartAttemptID)"
        )
    }

    private func authorizeMPVAutomaticPictureInPicture(
        for controller: PiPController,
        source: String
    ) {
        guard pipController === controller,
              controller.playbackLoadGeneration == playbackLoadGeneration else { return }
        mpvAutomaticPictureInPictureAuthorization = MPVAutomaticPictureInPictureAuthorization(
            controllerIdentifier: ObjectIdentifier(controller),
            loadGeneration: playbackLoadGeneration,
            transitionAttemptID: controller.transitionAttemptID,
            playbackIntentGeneration: rendererPlaybackIntentGeneration
        )
        logPictureInPicture(
            "authorized automatic PiP source=\(source) loadGeneration=\(playbackLoadGeneration) attemptID=\(controller.transitionAttemptID) intent=\(rendererPlaybackIntentGeneration)"
        )
    }

    private func clearMPVAutomaticPictureInPictureAuthorization(reason: String) {
        guard let authorization = mpvAutomaticPictureInPictureAuthorization else { return }
        mpvAutomaticPictureInPictureAuthorization = nil
        logPictureInPicture(
            "cleared automatic PiP authorization reason=\(reason) loadGeneration=\(authorization.loadGeneration) attemptID=\(authorization.transitionAttemptID) intent=\(authorization.playbackIntentGeneration)"
        )
    }

    private func validateMPVAutomaticPictureInPicturePlaybackIntent(
        for controller: PiPController,
        attemptID: Int,
        source: String
    ) -> Bool {
        guard let authorization = mpvAutomaticPictureInPictureAuthorization else {
            return true
        }
        let identityMatches = authorization.controllerIdentifier == ObjectIdentifier(controller)
            && authorization.loadGeneration == playbackLoadGeneration
            && authorization.loadGeneration == controller.playbackLoadGeneration
            && authorization.transitionAttemptID == attemptID
            && controller.transitionAttemptID == attemptID
        let intentMatches = authorization.playbackIntentGeneration == rendererPlaybackIntentGeneration
        let paused = rendererIsPausedState()
        guard identityMatches, intentMatches else {
            logPictureInPicture(
                "automatic PiP authorization rejected source=\(source) identityMatches=\(identityMatches) intentMatches=\(intentMatches) paused=\(paused) expectedIntent=\(authorization.playbackIntentGeneration) currentIntent=\(rendererPlaybackIntentGeneration) expectedAttempt=\(authorization.transitionAttemptID) callbackAttempt=\(attemptID)"
            )
            abortMPVAppExitPictureInPictureForPlaybackIntentChange(
                controller: controller,
                source: source,
                expectedLoadGeneration: authorization.loadGeneration,
                expectedIntentGeneration: authorization.playbackIntentGeneration
            )
            return false
        }
        return true
    }

    private func installMPVPictureInPictureController(reason: String) {
        guard isMPVRenderer, !isVLCPlayer else { return }
        clearMPVAutomaticPictureInPictureAuthorization(
            reason: "install-controller-\(reason)"
        )
        invalidateMPVPictureInPictureRestoreOperation(reason: "install-controller-\(reason)")
        invalidateMPVPictureInPictureStopAuthorization(reason: "install-controller-\(reason)")
        rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
        let previous = pipController
        previous?.delegate = nil
        previous?.invalidateForReplacement()

        let controller = PiPController(
            sampleBufferDisplayLayer: displayLayer,
            playbackLoadGeneration: playbackLoadGeneration
        )
        controller.delegate = self
        pipController = controller
        mpvExpectedPiPCallbackAttemptID = nil
        mpvActivePiPCallbackAttemptID = nil
        configureRendererPictureInPictureStopRequestHandling(for: controller)
        logPictureInPicture(
            "installed PiP controller reason=\(reason) loadGeneration=\(playbackLoadGeneration) replaced=\(previous != nil)"
        )
    }

    private func shouldHandleMPVPictureInPictureCallback(
        from controller: PiPController,
        source: String,
        attemptID: Int? = nil,
        requiresRunning: Bool = true
    ) -> Bool {
        let expectedAttempt = mpvExpectedPiPCallbackAttemptID
        let callbackAttempt = attemptID ?? controller.transitionAttemptID
        let attemptIsCurrentOrActive = callbackAttempt == mpvPiPStartAttemptID
            || callbackAttempt == mpvActivePiPCallbackAttemptID
        let valid = pipController === controller
            && controller.playbackLoadGeneration == playbackLoadGeneration
            && expectedAttempt == callbackAttempt
            && attemptIsCurrentOrActive
            && (!requiresRunning || isRunning)
            && !isClosing
        guard valid else {
            logPictureInPicture(
                "ignored stale PiP callback source=\(source) controllerMatch=\(pipController === controller) callbackLoad=\(controller.playbackLoadGeneration) currentLoad=\(playbackLoadGeneration) callbackAttempt=\(callbackAttempt) expectedAttempt=\(expectedAttempt.map { String($0) } ?? "nil") currentAttempt=\(mpvPiPStartAttemptID) activeAttempt=\(mpvActivePiPCallbackAttemptID.map { String($0) } ?? "nil") running=\(isRunning) closing=\(isClosing)"
            )
            return false
        }
        return true
    }

    private func configureRendererPictureInPictureStopRequestHandling(for controller: PiPController) {
        renderer.setPictureInPictureStopRequestHandler { [weak self, weak controller] reason in
            guard let self,
                  let controller,
                  self.pipController === controller,
                  controller.playbackLoadGeneration == self.playbackLoadGeneration,
                  self.isRunning,
                  !self.isClosing else { return }

            let loadGeneration = self.playbackLoadGeneration
            let transitionAttemptID = controller.transitionAttemptID

            let active = controller.isPictureInPictureActive
            let pending = controller.isPictureInPictureStartPending
            self.logPictureInPicture(
                "renderer requested PiP stop reason=\(reason) active=\(active) pending=\(pending) renderer={\(self.rendererPictureInPictureDebugSnapshot())}"
            )
            self.cancelMPVPictureInPictureStartRequests(reason: "renderer-failure")
            self.releaseMPVAppExitPictureInPictureOwnership(reason: "renderer-failure")
            controller.setCanStartPictureInPictureAutomaticallyFromInline(false)

            if reason.hasPrefix("native-activation-not-active") {

                controller.stopPictureInPicture(source: "renderer-activation-rejected")
                self.rendererFinishPictureInPicture()
                DispatchQueue.main.async { [weak self, weak controller] in
                    guard let self,
                          let controller,
                          self.pipController === controller,
                          controller.playbackLoadGeneration == self.playbackLoadGeneration,
                          self.isRunning,
                          !self.isClosing else { return }
                    controller.setCanStartPictureInPictureAutomaticallyFromInline(false)
                    controller.stopPictureInPicture(source: "renderer-activation-rejected-retire")
                    self.installMPVPictureInPictureController(
                        reason: "renderer-activation-rejected"
                    )
                    self.rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
                    if self.mpvBackgroundLifecycleIsArmed {
                        self.scheduleMPVBackgroundAudioFallback(
                            source: "renderer-activation-rejected",
                            delay: 0.25
                        )
                    }
                    self.updatePiPButtonVisibility()
                }
                return
            }

            if self.mpvBackgroundLifecycleIsArmed {
                self.scheduleMPVBackgroundAudioFallback(
                    source: "renderer-failure-\(reason)",
                    delay: 0.25
                )
            }

            guard active || pending else {
                self.rendererFinishPictureInPicture()
                self.updatePiPButtonVisibility()
                return
            }

            controller.stopPictureInPicture(source: "renderer-failure")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak controller] in
                guard let self,
                      let controller,
                      self.pipController === controller,
                      loadGeneration == self.playbackLoadGeneration,
                      controller.playbackLoadGeneration == loadGeneration,
                      controller.transitionAttemptID == transitionAttemptID,
                      self.isRunning,
                      !self.isClosing,
                      !controller.isPictureInPictureActive,
                      !controller.isPictureInPictureStartPending else { return }
                self.rendererFinishPictureInPicture()
                self.updatePiPButtonVisibility()
            }
        }
    }

    private func rendererPreparePictureInPictureStart() async throws {
        logPictureInPicture("renderer prepare call renderer=\(mpvRendererName) hasMPVRenderer=\(isMPVRenderer)")
        try await renderer.preparePictureInPicture()
    }

    private func rendererRenderingLayoutDidChange() {
        guard isMPVRenderer else { return }
        renderer.renderingLayoutDidChange(containerSize: videoContainer.bounds.size)
    }

    private func rendererFinishPictureInPicture() {
        mpvPictureInPictureRendererHandoffGeneration &+= 1
        mpvPictureInPictureRendererHandoffIsActive = false
        renderer.finishPictureInPicture()
    }

    private func rendererFinishPictureInPictureAndWait(
        restoringInlinePlayback: Bool
    ) async -> Bool {
        mpvPictureInPictureRendererHandoffGeneration &+= 1
        let finishGeneration = mpvPictureInPictureRendererHandoffGeneration
        mpvPictureInPictureRendererHandoffIsActive = false
        let restored = await renderer.finishPictureInPictureAndWait(
            restoringInlinePlayback: restoringInlinePlayback
        )

        if finishGeneration == mpvPictureInPictureRendererHandoffGeneration {
            mpvPictureInPictureRendererHandoffIsActive = false
        }
        return restored
    }

    private func mpvPictureInPictureRestoreKey(
        for controller: PiPController
    ) -> MPVPictureInPictureRestoreKey {
        MPVPictureInPictureRestoreKey(
            controllerIdentifier: ObjectIdentifier(controller),
            playbackLoadGeneration: controller.playbackLoadGeneration,
            transitionAttemptID: controller.transitionAttemptID
        )
    }

    private func authorizeMPVPictureInPictureStop(
        for controller: PiPController,
        source: String
    ) {
        mpvPictureInPictureStopAuthorizationID &+= 1
        let authorization = MPVPictureInPictureStopAuthorization(
            id: mpvPictureInPictureStopAuthorizationID,
            key: mpvPictureInPictureRestoreKey(for: controller),
            lifecycleGeneration: mpvBackgroundLifecycleGeneration
        )
        mpvPictureInPictureStopAuthorization = authorization
        logPictureInPicture(
            "authorized PiP stop restore source=\(source) authorization=\(authorization.id) lifecycleGeneration=\(authorization.lifecycleGeneration) attemptID=\(authorization.key.transitionAttemptID)"
        )
    }

    private func currentMPVPictureInPictureStopAuthorization(
        _ capturedAuthorization: MPVPictureInPictureStopAuthorization? = nil,
        for controller: PiPController
    ) -> MPVPictureInPictureStopAuthorization? {
        guard let currentAuthorization = mpvPictureInPictureStopAuthorization else {
            return nil
        }
        if let capturedAuthorization,
           capturedAuthorization.id != currentAuthorization.id {
            return nil
        }
        let key = mpvPictureInPictureRestoreKey(for: controller)
        guard currentAuthorization.key == key,
              currentAuthorization.lifecycleGeneration == mpvBackgroundLifecycleGeneration,
              isCurrentMPVPictureInPictureRestore(key, controller: controller) else {
            return nil
        }
        return currentAuthorization
    }

    private func invalidateMPVPictureInPictureStopAuthorization(reason: String) {
        guard let authorization = mpvPictureInPictureStopAuthorization else { return }
        mpvPictureInPictureStopAuthorization = nil
        logPictureInPicture(
            "invalidated PiP stop restore authorization=\(authorization.id) reason=\(reason)"
        )
    }

    private func waitForForegroundMPVPictureInPictureRestoreAuthorization(
        _ authorization: MPVPictureInPictureStopAuthorization,
        controller: PiPController
    ) async -> Bool {
        for _ in 0..<80 {
            guard !Task.isCancelled,
                  currentMPVPictureInPictureStopAuthorization(
                    authorization,
                    for: controller
                  ) != nil else {
                return false
            }
            if owningPlaybackSceneIsForegroundActive() {
                return true
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    private func isCurrentMPVPictureInPictureRestore(
        _ key: MPVPictureInPictureRestoreKey,
        controller: PiPController
    ) -> Bool {
        guard ObjectIdentifier(controller) == key.controllerIdentifier,
              pipController === controller,
              key.playbackLoadGeneration == playbackLoadGeneration,
              controller.playbackLoadGeneration == key.playbackLoadGeneration,
              controller.transitionAttemptID == key.transitionAttemptID,
              isRunning,
              !isClosing else {
            return false
        }

        if mpvPictureInPictureRestoreOperation?.key == key
            || mpvCompletedPictureInPictureRestore?.key == key {
            return true
        }
        return mpvExpectedPiPCallbackAttemptID == key.transitionAttemptID
            || mpvActivePiPCallbackAttemptID == key.transitionAttemptID
    }

    private func beginMPVPictureInPictureRestore(
        for controller: PiPController,
        lifecycleGeneration: Int? = nil
    ) -> (id: Int, key: MPVPictureInPictureRestoreKey, task: Task<Bool, Never>) {
        let key = mpvPictureInPictureRestoreKey(for: controller)
        if let operation = mpvPictureInPictureRestoreOperation,
           operation.key == key {
            return operation
        }

        mpvPictureInPictureRestoreOperationID &+= 1
        let operationID = mpvPictureInPictureRestoreOperationID
        let task = Task { @MainActor [weak self, weak controller] () -> Bool in
            guard let self,
                  let controller else {
                return false
            }
            let callbackAuthorized = self.isCurrentMPVPictureInPictureRestore(
                key,
                controller: controller
            ) && self.owningPlaybackSceneIsForegroundActive()
            let lifecycleAuthorized = lifecycleGeneration.map { generation in
                self.mpvBackgroundLifecycleIsArmed
                    && self.mpvBackgroundLifecycleGeneration == generation
                    && self.owningPlaybackSceneIsForegroundActive()
                    && self.pipController === controller
                    && controller.playbackLoadGeneration == self.playbackLoadGeneration
                    && key.playbackLoadGeneration == self.playbackLoadGeneration
                    && controller.transitionAttemptID == key.transitionAttemptID
                    && self.isRunning
                    && !self.isClosing
            } ?? false
            let restoreAuthorized = lifecycleGeneration == nil
                ? callbackAuthorized
                : lifecycleAuthorized
            guard restoreAuthorized else { return false }
            let restored = await self.rendererFinishPictureInPictureAndWait(
                restoringInlinePlayback: true
            )
            guard !Task.isCancelled,
                  restored,
                  self.mpvPictureInPictureRestoreOperation?.id == operationID,
                  self.isCurrentMPVPictureInPictureRestore(key, controller: controller) else {
                return false
            }
            if let lifecycleGeneration {
                guard self.mpvBackgroundLifecycleIsArmed,
                      self.mpvBackgroundLifecycleGeneration == lifecycleGeneration,
                      self.owningPlaybackSceneIsForegroundActive() else {
                    return false
                }
            }
            return true
        }
        let operation = (id: operationID, key: key, task: task)
        mpvPictureInPictureRestoreOperation = operation
        mpvCompletedPictureInPictureRestore = nil
        return operation
    }

    @discardableResult
    private func completeMPVPictureInPictureRestore(
        _ operation: (id: Int, key: MPVPictureInPictureRestoreKey, task: Task<Bool, Never>),
        controller: PiPController,
        rendererRestored: Bool,
        source: String
    ) -> Bool {
        if let completed = mpvCompletedPictureInPictureRestore,
           completed.id == operation.id,
           completed.key == operation.key {
            guard isCurrentMPVPictureInPictureRestore(
                operation.key,
                controller: controller
            ) else {
                return false
            }
            return completed.restored
        }
        guard mpvPictureInPictureRestoreOperation?.id == operation.id,
              isCurrentMPVPictureInPictureRestore(operation.key, controller: controller) else {
            return false
        }

        mpvCompletedPictureInPictureRestore = (
            id: operation.id,
            key: operation.key,
            restored: rendererRestored
        )
        if mpvExpectedPiPCallbackAttemptID == operation.key.transitionAttemptID {
            mpvExpectedPiPCallbackAttemptID = nil
        }
        if mpvActivePiPCallbackAttemptID == operation.key.transitionAttemptID {
            mpvActivePiPCallbackAttemptID = nil
        }
        if mpvPictureInPictureStopAuthorization?.key == operation.key {
            invalidateMPVPictureInPictureStopAuthorization(reason: "restore-completed-\(source)")
        }
        updatePiPButtonVisibility()

        guard rendererRestored else {
            logPictureInPicture(
                "PiP restore did not prove a current inline frame source=\(source) renderer={\(rendererPictureInPictureDebugSnapshot())}"
            )
            return false
        }
        if UIApplication.shared.applicationState == .active {
            clearMPVAppExitPictureInPictureSuppression(reason: "\(source)-active")
        }
        if mpvBackgroundLifecycleIsArmed {

            logPictureInPicture("PiP restore deferring rewarm to serialized foreground recovery source=\(source)")
        } else {
            scheduleMPVPictureInPictureForegroundWarmup(
                source: "\(source)-rewarm",
                delays: [0.25, 1.10],
                forceFirst: true
            )
        }
        logPictureInPicture(
            "PiP restore completed source=\(source) renderer={\(rendererPictureInPictureDebugSnapshot())}"
        )
        return true
    }

    private func invalidateMPVPictureInPictureRestoreOperation(reason: String) {
        guard mpvPictureInPictureRestoreOperation != nil
                || mpvCompletedPictureInPictureRestore != nil else {
            return
        }
        mpvPictureInPictureRestoreOperation?.task.cancel()
        mpvPictureInPictureRestoreOperation = nil
        mpvCompletedPictureInPictureRestore = nil
        logPictureInPicture("invalidated PiP restore operation reason=\(reason)")
    }

    @discardableResult
    private func rendererActivatePictureInPictureLayer() -> Bool {
        mpvPictureInPictureRendererHandoffGeneration &+= 1
        let activationGeneration = mpvPictureInPictureRendererHandoffGeneration
        mpvPictureInPictureRendererHandoffIsActive = false
        logPictureInPicture("renderer activate layer call renderer=\(mpvRendererName) hasMPVRenderer=\(isMPVRenderer)")
        let activated = renderer.activatePictureInPictureLayer()
        guard activationGeneration == mpvPictureInPictureRendererHandoffGeneration else {

            logPictureInPicture("renderer activation superseded during callback renderer=\(mpvRendererName)")
            return false
        }
        mpvPictureInPictureRendererHandoffIsActive = activated
        if !activated {
            logPictureInPicture("renderer activation rejected renderer=\(mpvRendererName) renderer={\(rendererPictureInPictureDebugSnapshot())}")
        }
        return activated
    }

    private func rendererSetPictureInPictureSourcePreparedForAutomaticStart(_ prepared: Bool) {
        if !prepared {
            let state = mpvPictureInPictureControllerState()

            guard !state.active, !state.pending else { return }
        }
        renderer.setPictureInPictureSourcePreparedForAutomaticStart(prepared)
    }

    private func rendererIsPictureInPicturePrimed() -> Bool {
        renderer.isPictureInPicturePrimed()
    }

    @discardableResult
    private func prepareMPVPictureInPictureRenderer(source: String, activateLayer: Bool) async -> Bool {
        let active = pipController?.isPictureInPictureActive ?? false
        let possible = pipController?.isPictureInPicturePossible ?? false
        logPictureInPicture("renderer prepare begin source=\(source) active=\(active) possible=\(possible) activateLayer=\(activateLayer)")
        prepareMPVRenderedSubtitlesForPictureInPicture(source: source)
        do {
            try await rendererPreparePictureInPictureStart()
        } catch {
            logPictureInPicture("renderer prepare failed source=\(source) error=\(error) renderer={\(rendererPictureInPictureDebugSnapshot())}")
            return false
        }
        let activated = !activateLayer || rendererActivatePictureInPictureLayer()
        pipController?.updatePlaybackState()
        let primed = rendererIsPictureInPicturePrimed()
        logPictureInPicture("renderer prepare end source=\(source) primed=\(primed) activated=\(activated) renderer={\(rendererPictureInPictureDebugSnapshot())}")
        return primed && activated
    }

    private func rendererResumeForegroundRendering(reason: String) {
        let pipState = mpvPictureInPictureControllerState()
        if pipState.active || pipState.pending {
            logPictureInPicture("foreground render recovery deferred reason=\(reason) active=\(pipState.active) pending=\(pipState.pending) renderer={\(rendererPictureInPictureDebugSnapshot())}")
            return
        }
        renderer.resumeForegroundRendering(reason: reason)
    }

    private func rendererRecoverForegroundRendering(reason: String) async -> Bool {
        let pipState = mpvPictureInPictureControllerState()
        guard !pipState.active, !pipState.pending else {
            logPictureInPicture(
                "serialized foreground recovery still waiting for AVKit reason=\(reason) active=\(pipState.active) pending=\(pipState.pending)"
            )
            return false
        }
        return await withCheckedContinuation { continuation in
            renderer.recoverForegroundRendering(reason: reason) { success in
                continuation.resume(returning: success)
            }
        }
    }

    private func rendererPictureInPictureDebugSnapshot() -> String {
        renderer.pictureInPictureDebugSnapshot()
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
    private var stremioSubtitleResults: [StremioAddonManager.AddonSubtitleResult] = []
    private var stremioSubtitleFetchTask: Task<Void, Never>?
    private var stremioSubtitleFetchInProgress = false
    private var stremioSubtitleSearchAttempted = false
    private var stremioSubtitleFallbackAttempted = false
    private var stremioSubtitleLoadedURLs: Set<String> = []
    private var onlineSubtitleLoadedURLs: Set<String> = []
    private var onlineSubtitleLoadedTrackNames: Set<String> = []
    private var onlineSubtitleLoadedRendererTrackIds: Set<Int> = []

    private var isVLCCustomSubtitleOverlayEnabled: Bool {
        return false
    }

    private var isVLCOpenSubtitlesEnabled: Bool {
        return isMPVRenderer && Settings.shared.playerOpenSubtitlesEnabled
    }

    private var hasStremioSubtitleAddons: Bool {
        return (isVLCPlayer || isMPVRenderer) && !StremioAddonManager.shared.activeSubtitleAddons.isEmpty
    }

    private func updatePiPButtonVisibility() {
        let imageName = rendererIsPictureInPictureActive() ? "pip.exit" : "pip.enter"
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        pipButton.setImage(UIImage(systemName: imageName, withConfiguration: cfg), for: .normal)

        let isAvailable = rendererIsPictureInPictureAvailable()
        var shouldShow = isAvailable && !isVLCPlayer && Settings.shared.mpvPictureInPictureEnabled
        pipButton.isHidden = !shouldShow
        pipButton.isEnabled = shouldShow
        if isVLCPlayer {
            let key = "available=false show=false hidden=\(pipButton.isHidden) active=false image=\(imageName)"
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

    private var mpvAppExitPictureInPictureSceneIdentifier: String {
        if let scene = playbackWindowScene ?? viewIfLoaded?.window?.windowScene {
            return scene.session.persistentIdentifier
        }
        return "unattached-\(playerInterfaceCoverageIdentifier.prefix(8))"
    }

    @discardableResult
    private func claimMPVAppExitPictureInPictureOwnership(
        reason: String,
        recordingActivation: Bool = false
    ) -> Bool {
        let previousCandidate = Self.mostRecentlyActivatedPlaybackController
        if recordingActivation {
            Self.mostRecentlyActivatedPlaybackController = self
        } else if Self.mostRecentlyActivatedPlaybackController == nil {

            Self.mostRecentlyActivatedPlaybackController = self
            logPictureInPicture(
                "MPV app-exit PiP arbiter claimed vacant candidate reason=\(reason) scene=\(mpvAppExitPictureInPictureSceneIdentifier)"
            )
        }

        guard Self.mostRecentlyActivatedPlaybackController === self else {
            let controllerState = mpvPictureInPictureControllerState()
            if Self.appExitPictureInPictureOwner === self {
                Self.appExitPictureInPictureOwner = nil
            }
            pipController?.setCanStartPictureInPictureAutomaticallyFromInline(false)
            cancelPendingMPVAppExitPictureInPictureStart(reason: "\(reason)-ownership-denied")
            if mpvAppExitPiPStartRequested,
               !controllerState.active,
               !controllerState.pending {
                cancelMPVPictureInPictureStartRequests(reason: "\(reason)-ownership-denied")
            }
            logPictureInPicture(
                "MPV app-exit PiP arbiter denied reason=\(reason) scene=\(mpvAppExitPictureInPictureSceneIdentifier) candidateScene=\(Self.mostRecentlyActivatedPlaybackController?.mpvAppExitPictureInPictureSceneIdentifier ?? "nil") ownerScene=\(Self.appExitPictureInPictureOwner?.mpvAppExitPictureInPictureSceneIdentifier ?? "nil")"
            )
            return false
        }

        guard isMPVRenderer, !isVLCPlayer, !isClosing else {
            if let previousOwner = Self.appExitPictureInPictureOwner {
                let previousState = previousOwner.mpvPictureInPictureControllerState()
                Self.appExitPictureInPictureOwner = nil
                previousOwner.pipController?.setCanStartPictureInPictureAutomaticallyFromInline(false)
                previousOwner.cancelPendingMPVAppExitPictureInPictureStart(
                    reason: "\(reason)-ineligible-candidate"
                )
                if previousOwner.mpvAppExitPiPStartRequested,
                   !previousState.active,
                   !previousState.pending {
                    previousOwner.cancelMPVPictureInPictureStartRequests(
                        reason: "\(reason)-ineligible-candidate"
                    )
                }
                previousOwner.logPictureInPicture(
                    "MPV app-exit PiP arbiter ownership transferred to ineligible scene reason=\(reason) scene=\(previousOwner.mpvAppExitPictureInPictureSceneIdentifier) newScene=\(mpvAppExitPictureInPictureSceneIdentifier)"
                )
            }
            logPictureInPicture(
                "MPV app-exit PiP arbiter candidate ineligible reason=\(reason) scene=\(mpvAppExitPictureInPictureSceneIdentifier) mpv=\(isMPVRenderer) vlc=\(isVLCPlayer) closing=\(isClosing)"
            )
            return false
        }

        if Self.appExitPictureInPictureOwner === self {
            if recordingActivation {
                logPictureInPicture(
                    "MPV app-exit PiP arbiter retained reason=\(reason) scene=\(mpvAppExitPictureInPictureSceneIdentifier)"
                )
            }
            return true
        }

        let previousOwner = Self.appExitPictureInPictureOwner
        Self.appExitPictureInPictureOwner = self
        if let previousOwner, previousOwner !== self {
            let previousState = previousOwner.mpvPictureInPictureControllerState()
            previousOwner.pipController?.setCanStartPictureInPictureAutomaticallyFromInline(false)
            previousOwner.cancelPendingMPVAppExitPictureInPictureStart(
                reason: "\(reason)-ownership-transferred"
            )

            if previousOwner.mpvAppExitPiPStartRequested,
               !previousState.active,
               !previousState.pending {
                previousOwner.cancelMPVPictureInPictureStartRequests(
                    reason: "\(reason)-ownership-transferred"
                )
            }
            previousOwner.logPictureInPicture(
                "MPV app-exit PiP arbiter ownership transferred away reason=\(reason) scene=\(previousOwner.mpvAppExitPictureInPictureSceneIdentifier) newScene=\(mpvAppExitPictureInPictureSceneIdentifier)"
            )
        }

        logPictureInPicture(
            "MPV app-exit PiP arbiter claimed reason=\(reason) scene=\(mpvAppExitPictureInPictureSceneIdentifier) previousCandidateScene=\(previousCandidate?.mpvAppExitPictureInPictureSceneIdentifier ?? "nil") previousOwnerScene=\(previousOwner?.mpvAppExitPictureInPictureSceneIdentifier ?? "nil")"
        )
        return true
    }

    private func releaseMPVAppExitPictureInPictureOwnership(
        reason: String,
        clearActivationCandidate: Bool = false
    ) {
        let releasedOwner = Self.appExitPictureInPictureOwner === self
        let clearedCandidate = clearActivationCandidate
            && Self.mostRecentlyActivatedPlaybackController === self
        if releasedOwner {
            Self.appExitPictureInPictureOwner = nil
        }
        if clearedCandidate {
            Self.mostRecentlyActivatedPlaybackController = nil
        }
        guard releasedOwner || clearedCandidate else { return }

        pipController?.setCanStartPictureInPictureAutomaticallyFromInline(false)
        rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
        cancelPendingMPVAppExitPictureInPictureStart(reason: "\(reason)-ownership-released")
        logPictureInPicture(
            "MPV app-exit PiP arbiter released reason=\(reason) scene=\(mpvAppExitPictureInPictureSceneIdentifier) owner=\(releasedOwner) candidate=\(clearedCandidate)"
        )
    }

    private func configureMPVAppExitPictureInPictureAutomation(reason: String) {
        guard isMPVRenderer, !isVLCPlayer else {
            pipController?.setCanStartPictureInPictureAutomaticallyFromInline(false)
            rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
            return
        }

        guard Self.appExitPictureInPictureOwner === self,
              Self.mostRecentlyActivatedPlaybackController === self else {
            pipController?.setCanStartPictureInPictureAutomaticallyFromInline(false)
            rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
            cancelPendingMPVAppExitPictureInPictureStart(reason: "\(reason)-not-arbiter-owner")
            logPictureInPicture(
                "MPV app-exit PiP automation denied by arbiter reason=\(reason) scene=\(mpvAppExitPictureInPictureSceneIdentifier) candidateScene=\(Self.mostRecentlyActivatedPlaybackController?.mpvAppExitPictureInPictureSceneIdentifier ?? "nil") ownerScene=\(Self.appExitPictureInPictureOwner?.mpvAppExitPictureInPictureSceneIdentifier ?? "nil")"
            )
            return
        }

        if isClosing {
            pipController?.setCanStartPictureInPictureAutomaticallyFromInline(false)
            rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
            cancelPendingMPVAppExitPictureInPictureStart(reason: "\(reason)-closing")
            mpvAppExitPiPStartRequested = false
            logPictureInPicture("MPV app-exit auto PiP automation disabled while closing reason=\(reason)")
            return
        }

        if mpvAppExitPiPSuppressedUntilForeground {
            if UIApplication.shared.applicationState == .active {
                clearMPVAppExitPictureInPictureSuppression(reason: "\(reason)-active")
            } else {
                pipController?.setCanStartPictureInPictureAutomaticallyFromInline(false)
                rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
                cancelPendingMPVAppExitPictureInPictureStart(reason: "\(reason)-suppressed")
                mpvAppExitPiPStartRequested = false
                logPictureInPicture("MPV app-exit auto PiP automation suppressed until foreground reason=\(reason)")
                return
            }
        }

        let requested = Settings.shared.mpvAppExitPictureInPictureEnabled && Settings.shared.mpvPictureInPictureEnabled
        let playing = !rendererIsPausedState()
        let enabled = requested && rendererIsPictureInPicturePrimed() && playing
        if enabled, let controller = pipController {
            armMPVPictureInPictureController(controller, reason: "\(reason)-automatic")
            authorizeMPVAutomaticPictureInPicture(for: controller, source: reason)
            rendererSetPictureInPictureSourcePreparedForAutomaticStart(true)
            controller.updatePlaybackState()
        } else {
            rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
        }
        pipController?.setCanStartPictureInPictureAutomaticallyFromInline(enabled)
        if !requested {
            cancelPendingMPVAppExitPictureInPictureStart(reason: "\(reason)-disabled")
            mpvAppExitPiPStartRequested = false
        }
        logPictureInPicture("MPV app-exit auto PiP automation configured reason=\(reason) requested=\(requested) ready=\(rendererIsPictureInPicturePrimed()) playing=\(playing) enabled=\(enabled)")
    }

    private func cancelMPVPictureInPictureStartRequests(reason: String) {
        mpvPiPStartAttemptID += 1
        mpvAppExitPiPStartRequested = false
        clearMPVAutomaticPictureInPictureAuthorization(reason: reason)
        cancelPendingMPVAppExitPictureInPictureStart(reason: reason)
        logPictureInPicture("MPV PiP start requests canceled reason=\(reason) attemptID=\(mpvPiPStartAttemptID)")
    }

    private func suppressMPVAppExitPictureInPictureUntilForeground(reason: String) {
        guard isMPVRenderer, !isVLCPlayer else { return }
        cancelMPVPictureInPictureStartRequests(reason: reason)
        pipController?.setCanStartPictureInPictureAutomaticallyFromInline(false)
        rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
        guard !mpvAppExitPiPSuppressedUntilForeground else {
            logPictureInPicture("MPV app-exit auto PiP already suppressed until foreground reason=\(reason)")
            return
        }
        mpvAppExitPiPSuppressedUntilForeground = true
        logPictureInPicture("MPV app-exit auto PiP suppressed until foreground reason=\(reason)")
    }

    private func clearMPVAppExitPictureInPictureSuppression(reason: String) {
        guard mpvAppExitPiPSuppressedUntilForeground else { return }
        mpvAppExitPiPSuppressedUntilForeground = false
        logPictureInPicture("MPV app-exit auto PiP suppression cleared reason=\(reason)")
    }

    private func disarmMPVPictureInPictureRestartAfterStop(reason: String) {
        let appState = UIApplication.shared.applicationState
        if appState == .active {
            cancelMPVPictureInPictureStartRequests(reason: reason)
            pipController?.setCanStartPictureInPictureAutomaticallyFromInline(false)
            clearMPVAppExitPictureInPictureSuppression(reason: "\(reason)-active-stop")
            logPictureInPicture("MPV PiP restart disarmed after stop reason=\(reason) appState=active -> app-exit-ready")
            return
        }

        logPictureInPicture("MPV PiP restart disarmed after stop reason=\(reason) appState=\(applicationStateDescription(appState)) -> suppress-until-foreground")
        suppressMPVAppExitPictureInPictureUntilForeground(reason: "\(reason)-\(applicationStateDescription(appState))")
    }

    @discardableResult
    private func primeMPVPictureInPictureForForegroundPlaybackIfNeeded(source: String, requiresAppExitEnabled: Bool) -> Bool {
        guard isMPVRenderer, !isVLCPlayer else { return false }
        if requiresAppExitEnabled {
            guard claimMPVAppExitPictureInPictureOwnership(reason: source) else { return false }
        }
        guard Settings.shared.mpvPictureInPictureEnabled else {
            logPictureInPicture("MPV foreground PiP warm skipped source=\(source): PiP disabled")
            return false
        }
        guard isMetalMPVRenderer else { return false }
        if requiresAppExitEnabled {
            guard Settings.shared.mpvAppExitPictureInPictureEnabled else {
                logPictureInPicture("MPV app-exit auto PiP prime skipped source=\(source): disabled")
                return false
            }
            guard !mpvAppExitPiPSuppressedUntilForeground else {
                logPictureInPicture("MPV app-exit auto PiP prime skipped source=\(source): suppressed-until-foreground")
                return false
            }
        }
        guard let pip = pipController else {
            logPictureInPicture("MPV foreground PiP warm skipped source=\(source): controller missing")
            return false
        }
        let active = pip.isPictureInPictureActive
        let pending = pip.isPictureInPictureStartPending
        let supported = pip.isPictureInPictureSupported
        let paused = rendererIsPausedState()
        let playbackReady = playbackDidStart || cachedPosition > 0.1
        guard isRunning, !isClosing, !active, !pending, !paused, playbackReady, supported else {
            logPictureInPicture("MPV foreground PiP warm skipped source=\(source) running=\(isRunning) closing=\(isClosing) active=\(active) pending=\(pending) paused=\(paused) ready=\(playbackReady) supported=\(supported)")
            return false
        }
        if requiresAppExitEnabled,
           UIApplication.shared.applicationState != .background {

            renderer.prioritizeAppExitPictureInPictureOverDecoderRecovery()
        }

        let warmSource = requiresAppExitEnabled ? "\(source)-app-exit-prime" : "\(source)-foreground-prewarm"
        let mode = requiresAppExitEnabled ? "app-exit" : "foreground"
        let preparationGeneration = mpvPictureInPictureWarmupGeneration
        let loadGeneration = playbackLoadGeneration
        if rendererIsPictureInPicturePrimed() {
            pip.updatePlaybackState()
            if requiresAppExitEnabled
                || (Settings.shared.mpvAppExitPictureInPictureEnabled
                    && Settings.shared.mpvPictureInPictureEnabled) {
                configureMPVAppExitPictureInPictureAutomation(reason: "\(source)-already-ready")
            }
            logPictureInPicture("MPV \(mode) PiP reused current ready state source=\(source) possible=\(pip.isPictureInPicturePossible) renderer={\(rendererPictureInPictureDebugSnapshot())}")
            return true
        }
        if requiresAppExitEnabled, UIApplication.shared.applicationState == .background {

            logPictureInPicture("MPV app-exit PiP prime skipped source=\(source): renderer was not ready before background")
            return false
        }
        Task { @MainActor [weak self, weak pip] in
            guard let self, let pip else { return }
            let primed = await self.prepareMPVPictureInPictureRenderer(
                source: warmSource,
                activateLayer: false
            )
            guard preparationGeneration == self.mpvPictureInPictureWarmupGeneration,
                  self.pipController === pip,
                  loadGeneration == self.playbackLoadGeneration,
                  pip.playbackLoadGeneration == loadGeneration,
                  self.isRunning,
                  !self.isClosing else { return }
            pip.updatePlaybackState()
            if primed,
               Settings.shared.mpvAppExitPictureInPictureEnabled,
               Settings.shared.mpvPictureInPictureEnabled,
               self.claimMPVAppExitPictureInPictureOwnership(reason: "\(source)-ready") {

                self.configureMPVAppExitPictureInPictureAutomation(reason: "\(source)-ready")
            } else if !primed {

                self.rendererFinishPictureInPicture()
                if requiresAppExitEnabled {
                    self.releaseMPVAppExitPictureInPictureOwnership(reason: "\(source)-prepare-failed")
                }
            }
            self.logPictureInPicture("MPV \(mode) PiP warmed source=\(source) primed=\(primed) possible=\(pip.isPictureInPicturePossible) renderer={\(self.rendererPictureInPictureDebugSnapshot())}")
        }
        return true
    }

    private func primeMPVAppExitPictureInPictureIfNeeded(source: String) {
        _ = primeMPVPictureInPictureForForegroundPlaybackIfNeeded(source: source, requiresAppExitEnabled: true)
    }

    private var lastMPVPictureInPictureWarmAt: CFTimeInterval = 0
    private var mpvPictureInPictureWarmupGeneration = 0

    private func cancelScheduledMPVPictureInPictureWarmups(reason: String) {
        mpvPictureInPictureWarmupGeneration += 1
        lastMPVPictureInPictureWarmAt = 0
        logPictureInPicture("MPV foreground PiP warmups canceled reason=\(reason) generation=\(mpvPictureInPictureWarmupGeneration)")
    }

    @discardableResult
    private func warmMPVPictureInPictureForForegroundPlaybackIfNeeded(source: String, minInterval: CFTimeInterval = 3.0, force: Bool = false) -> Bool {
        guard isMPVRenderer, !isVLCPlayer else { return false }
        guard !mpvBackgroundLifecycleIsArmed else {
            logPictureInPicture("MPV foreground PiP warm blocked during serialized lifecycle source=\(source)")
            return false
        }
        guard Settings.shared.mpvPictureInPictureEnabled else { return false }
        guard isMetalMPVRenderer else { return false }
        guard UIApplication.shared.applicationState == .active else { return false }
        let now = CACurrentMediaTime()
        guard force || now - lastMPVPictureInPictureWarmAt >= minInterval else { return false }
        lastMPVPictureInPictureWarmAt = now
        return primeMPVPictureInPictureForForegroundPlaybackIfNeeded(source: source, requiresAppExitEnabled: false)
    }

    private func scheduleMPVPictureInPictureForegroundWarmup(source: String, delays: [TimeInterval], forceFirst: Bool = false) {
        guard isMPVRenderer, !isVLCPlayer else { return }
        guard !mpvBackgroundLifecycleIsArmed else {
            logPictureInPicture("MPV foreground PiP warmup deferred to serialized lifecycle source=\(source)")
            return
        }
        guard Settings.shared.mpvPictureInPictureEnabled else { return }
        guard isMetalMPVRenderer else {
            logPictureInPicture("MPV app-exit PiP readiness skipped source=\(source): renderer=\(mpvRendererName) has no explicit preparation path")
            return
        }
        mpvPictureInPictureWarmupGeneration += 1
        let generation = mpvPictureInPictureWarmupGeneration
        let normalizedDelays = Array(Set(delays.map { max(0, $0) })).sorted()
        let scheduledDelays = normalizedDelays.isEmpty ? [0] : normalizedDelays
        let delaySummary = scheduledDelays
            .map { String(format: "%.2f", $0) }
            .joined(separator: ",")
        logPictureInPicture("MPV foreground PiP warmups scheduled source=\(source) delays=[\(delaySummary)] generation=\(generation)")

        for (index, delay) in scheduledDelays.enumerated() {
            let attempt = index + 1
            let warm: () -> Void = { [weak self] in
                guard let self,
                      generation == self.mpvPictureInPictureWarmupGeneration else {
                    return
                }
                _ = self.warmMPVPictureInPictureForForegroundPlaybackIfNeeded(
                    source: "\(source)-warm-\(attempt)",
                    minInterval: 0,
                    force: forceFirst && index == 0
                )
            }
            if delay <= 0 {
                DispatchQueue.main.async(execute: warm)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: warm)
            }
        }
    }

    private func updatePlayerTitle() {
        let title = playerDisplayTitle()
        playerTitleLabel.text = title
        playerTitleLabel.isHidden = title.isEmpty
    }

    private func playerDisplayTitle() -> String {
        guard let info = mediaInfo else { return trimmedTitle(playerTitleOverride) ?? "" }
        switch info {
        case .movie(_, let title, _, _):
            return trimmedTitle(playerTitleOverride) ?? title
        case .episode(_, let seasonNumber, let episodeNumber, let showTitle, _, _):

            let prefix = trimmedTitle(playerTitleOverride) ?? trimmedTitle(showTitle)
            if isAnimeContent() {
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

    private var playbackTraceID: String {
        playbackLaunchContext?.traceID ?? "\(playerLogId)-local"
    }

    private func playbackURLSummary(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "unknown"
        let host = url.host?.lowercased() ?? (url.isFileURL ? "local-file" : "unknown")
        let ext = url.pathExtension.isEmpty ? "none" : url.pathExtension.lowercased()
        return "\(scheme)://\(host) ext=\(ext)"
    }

    private func logPlaybackStage(_ stage: String, _ details: String = "") {
        let now = Date()
        let traceOrigin = playbackLaunchContext?.traceCreatedAt ?? playbackTraceLoadStartedAt
        let total = max(0, now.timeIntervalSince(traceOrigin))
        let load = max(0, now.timeIntervalSince(playbackTraceLoadStartedAt))
        let delta = max(0, now.timeIntervalSince(playbackTraceLastStageAt))
        playbackTraceLastStageAt = now
        let suffix = details.isEmpty ? "" : " \(details)"
        Logger.shared.log(
            "[PlaybackTrace \(playbackTraceID)] owner=appPlayer load=\(playbackLoadGeneration) stage=\(stage) total=\(String(format: "%.2f", total))s loadTime=\(String(format: "%.2f", load))s delta=\(String(format: "%.2f", delta))s\(suffix)",
            type: "PlaybackTrace"
        )
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
        let displayFrame = displayLayer.frame
        let displayBackground = displayLayer.backgroundColor.map { UIColor(cgColor: $0).description } ?? "nil"
        let vlcView: UIView? = nil
        let vlcIndex = vlcView.flatMap { target in videoContainer.subviews.firstIndex { $0 === target } } ?? -1
        let subviewStack = videoContainer.subviews.enumerated().map { index, subview -> String in
            if let vlcView = vlcView, subview === vlcView { return "\(index):vlc" }
            if subview === controlsOverlayView { return "\(index):controls" }
            if subview === dimmingView { return "\(index):dimming" }
            if subview === tapOverlayView { return "\(index):tap" }
            if subview === loadingIndicator { return "\(index):loading" }
            return "\(index):\(type(of: subview))"
        }.joined(separator: "|")
        logVLCUI("\(event) ui app=\(appState) window=\(view.window != nil) presenting=\(presentingViewController != nil) closing=\(isClosing) running=\(isRunning) loading=\(isRendererLoading) controls=\(controlsVisible) paused=\(rendererIsPausedState()) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) view=\(String(format: "%.0fx%.0f", viewBounds.width, viewBounds.height)) video=\(String(format: "%.0fx%.0f", videoBounds.width, videoBounds.height)) windowBounds=\(String(format: "%.0fx%.0f", windowBounds.width, windowBounds.height)) vlcIndex=\(vlcIndex) vlcHidden=\(vlcView?.isHidden ?? true) vlcAlpha=\(String(format: "%.2f", vlcView?.alpha ?? 0)) displayAttached=\(displayLayer.superlayer != nil) displayHidden=\(displayLayer.isHidden) displayOpacity=\(String(format: "%.2f", displayLayer.opacity)) displayFrame=\(String(format: "%.0fx%.0f", displayFrame.width, displayFrame.height)) displayBg=\(displayBackground) browser={\(episodeBrowserStateSummary())} stack=\(subviewStack)", type: "Player")
    }

    private func logVLCForegroundSnapshot(_ event: String, note: String? = nil) {
        guard isVLCPlayer else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.logVLCForegroundSnapshot(event, note: note)
            }
            return
        }

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
        let vlcView: UIView? = nil
        let vlcIndex = vlcView.flatMap { target in videoContainer.subviews.firstIndex { $0 === target } } ?? -1
        let displayFrame = displayLayer.frame
        let processInfo = ProcessInfo.processInfo
        let thermal = metalThermalStateName(processInfo.thermalState)
        let noteText = note.map { " note=\($0)" } ?? ""
        logVLCUI(
            "\(event) foreground app=\(appState) window=\(view.window != nil) presenting=\(presentingViewController != nil) closing=\(isClosing) running=\(isRunning) loading=\(isRendererLoading) controls=\(controlsVisible) paused=\(rendererIsPausedState()) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) view=\(String(format: "%.0fx%.0f", viewBounds.width, viewBounds.height)) video=\(String(format: "%.0fx%.0f", videoBounds.width, videoBounds.height)) windowBounds=\(String(format: "%.0fx%.0f", windowBounds.width, windowBounds.height)) vlcIndex=\(vlcIndex) displayAttached=\(displayLayer.superlayer != nil) displayHidden=\(displayLayer.isHidden) displayOpacity=\(String(format: "%.2f", displayLayer.opacity)) displayFrame=\(String(format: "%.0fx%.0f", displayFrame.width, displayFrame.height)) thermal=\(thermal) lowPower=\(processInfo.isLowPowerModeEnabled) browser={\(episodeBrowserStateSummary())}\(noteText)",
            type: "Player"
        )
    }

    private func episodeBrowserStateSummary(host explicitHost: UIHostingController<AnyView>? = nil) -> String {
        let host = explicitHost ?? episodeBrowserHostingController
        let hostView = host?.view
        let browserIndex = hostView.flatMap { view in videoContainer.subviews.firstIndex { $0 === view } } ?? -1
        let attached = hostView?.superview === videoContainer
        let parentAttached = host?.parent === self
        let frame = hostView?.frame ?? .zero
        let viewCount = videoContainer.subviews.count
        return "visible=\(isEpisodeBrowserVisible) host=\(host != nil) attached=\(attached) parent=\(parentAttached) index=\(browserIndex) alpha=\(String(format: "%.2f", hostView?.alpha ?? 0)) hidden=\(hostView?.isHidden ?? true) frame=\(String(format: "%.0fx%.0f", frame.width, frame.height)) subviews=\(viewCount)"
    }

    private func vlcMediaInfoLogLabel() -> String {
        vlcMediaInfoLogLabel(for: mediaInfo)
    }

    private func vlcMediaInfoLogLabel(for mediaInfo: MediaInfo?) -> String {
        guard let mediaInfo else { return "nil" }
        switch mediaInfo {
        case .movie(let id, let title, _, let isAnime):
            return "movie id=\(id) title=\(title) isAnime=\(isAnime)"
        case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, _, let isAnime):
            return "episode showId=\(showId) s=\(seasonNumber) e=\(episodeNumber) title=\(showTitle ?? "nil") isAnime=\(isAnime)"
        }
    }

    private func vlcAudioRouteSummary() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return "none" }
        return outputs.map { output in
            "\(output.portType.rawValue):\(output.portName)"
        }
        .joined(separator: "|")
    }

    private func vlcProxyDiagnosticsSummary() -> String {
        return "unavailable"
    }

    private func vlcSteadyEnvironmentSnapshot(safePosition: Double, effectiveDuration: Double, durationIsReliable: Bool) -> String {
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        let processInfo = ProcessInfo.processInfo
        let thermal = metalThermalStateName(processInfo.thermalState)
        let viewBounds = view.bounds
        let videoBounds = videoContainer.bounds
        let vlcView: UIView? = nil
        let route = vlcAudioRouteSummary()
        let proxy = vlcProxyDiagnosticsSummary()
        return "app=\(appState) media={\(vlcMediaInfoLogLabel())} position=\(secondsText(safePosition))/\(secondsText(effectiveDuration)) reliable=\(durationIsReliable) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) running=\(isRunning) closing=\(isClosing) loading=\(isRendererLoading) playbackStarted=\(playbackDidStart) controls=\(controlsVisible) paused=\(rendererIsPausedState()) speed=\(String(format: "%.2f", rendererGetSpeed())) thermal=\(thermal) lowPower=\(processInfo.isLowPowerModeEnabled) route={\(route)} view=\(String(format: "%.0fx%.0f", viewBounds.width, viewBounds.height)) video=\(String(format: "%.0fx%.0f", videoBounds.width, videoBounds.height)) window=\(view.window != nil) vlcHidden=\(vlcView?.isHidden ?? true) vlcAlpha=\(String(format: "%.2f", vlcView?.alpha ?? 0)) spinnerVisible=\(loadingIndicator.alpha > 0.01) spinnerAlpha=\(String(format: "%.2f", loadingIndicator.alpha)) browser={\(episodeBrowserStateSummary())} proxy={\(proxy)}"
    }

    private func logVLCUISteadyHeartbeatIfNeeded(safePosition: Double, effectiveDuration: Double, durationIsReliable: Bool) {
        guard isVLCPlayer else { return }
        let now = CACurrentMediaTime()
        guard now - lastVLCUISteadyHeartbeatLogTime >= 30 else { return }
        lastVLCUISteadyHeartbeatLogTime = now
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

    private func scheduleVLCForegroundSnapshots(_ event: String, delays: [TimeInterval] = [0.10, 0.50, 1.50]) {
        guard isVLCPlayer else { return }
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.logVLCForegroundSnapshot("\(event) +\(String(format: "%.2f", delay))s")
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
                guard isVisible != oldValue else { return }
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
        @Published var verticalOffset: CGFloat = -6.0 {
            didSet {
                if !isLoading { saveSubtitleSettings() }
            }
        }
        @Published var closedCaptionBackground: Bool = false {
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

        func reloadStyleSettingsFromDefaults(preservingVisibility: Bool = true) {
            let currentVisibility = isVisible
            isLoading = true
            loadSubtitleSettings()
            if preservingVisibility {
                isVisible = currentVisibility
            }
            isLoading = false
        }

        private func saveSubtitleSettings() {
            let defaults = ProfileSettingsStore.active
            defaults.set(isVisible, forKey: "subtitles_isVisible")
            defaults.set(strokeWidth, forKey: "subtitles_strokeWidth")
            defaults.set(fontSize, forKey: "subtitles_fontSize")
            defaults.set(verticalOffset, forKey: "playerSubtitleOverlayBottomConstant")

            if let foregroundData = try? NSKeyedArchiver.archivedData(withRootObject: foregroundColor, requiringSecureCoding: false) {
                defaults.set(foregroundData, forKey: "subtitles_foregroundColor")
            }
            if let strokeData = try? NSKeyedArchiver.archivedData(withRootObject: strokeColor, requiringSecureCoding: false) {
                defaults.set(strokeData, forKey: "subtitles_strokeColor")
            }
            defaults.set(closedCaptionBackground, forKey: "subtitles_closedCaptionBackground")
        }

        private func loadSubtitleSettings() {
            let defaults = ProfileSettingsStore.active

            if defaults.object(forKey: "subtitles_isVisible") != nil {
                isVisible = defaults.bool(forKey: "subtitles_isVisible")
            }

            if defaults.object(forKey: "subtitles_strokeWidth") != nil {
                let width = CGFloat(defaults.double(forKey: "subtitles_strokeWidth"))
                strokeWidth = max(0, min(width, 2.0))
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

            if defaults.object(forKey: "playerSubtitleOverlayBottomConstant") == nil,
               defaults.object(forKey: "vlcSubtitleOverlayBottomConstant") != nil {
                defaults.set(defaults.double(forKey: "vlcSubtitleOverlayBottomConstant"), forKey: "playerSubtitleOverlayBottomConstant")
            }
            if defaults.object(forKey: "playerSubtitleOverlayBottomConstant") != nil {
                let offset = CGFloat(defaults.double(forKey: "playerSubtitleOverlayBottomConstant"))
                verticalOffset = max(-24, min(offset, 24))
            } else {
                verticalOffset = -6.0
            }

            if defaults.object(forKey: "subtitles_closedCaptionBackground") != nil {
                closedCaptionBackground = defaults.bool(forKey: "subtitles_closedCaptionBackground")
            }
        }
    }
    private var subtitleModel = SubtitleModel()

    private var isTwoFingerTapEnabled: Bool {
        if ProfileSettingsStore.active.object(forKey: twoFingerSettingKey) == nil {
            if let legacyValue = ProfileSettingsStore.active.object(forKey: legacyTwoFingerSettingKey) as? Bool {
                ProfileSettingsStore.active.set(legacyValue, forKey: twoFingerSettingKey)
                return legacyValue
            }
            ProfileSettingsStore.active.set(true, forKey: twoFingerSettingKey)
            return true
        }
        return ProfileSettingsStore.active.bool(forKey: twoFingerSettingKey)
    }
    private var isDoubleTapSeekEnabled: Bool {
        if ProfileSettingsStore.active.object(forKey: doubleTapSeekEnabledKey) == nil {
            let legacy = ProfileSettingsStore.active.object(forKey: legacyDoubleTapSeekEnabledKey) as? Bool ?? true
            ProfileSettingsStore.active.set(legacy, forKey: doubleTapSeekEnabledKey)
            return legacy
        }
        return ProfileSettingsStore.active.bool(forKey: doubleTapSeekEnabledKey)
    }
    private var isCenterTapPlayPauseEnabled: Bool {
        if ProfileSettingsStore.active.object(forKey: centerTapPlayPauseSettingKey) == nil {
            ProfileSettingsStore.active.set(true, forKey: centerTapPlayPauseSettingKey)
            return true
        }
        return ProfileSettingsStore.active.bool(forKey: centerTapPlayPauseSettingKey)
    }
    private var playerSeekSeconds: Double {
        if ProfileSettingsStore.active.object(forKey: playerSeekSecondsKey) == nil,
           ProfileSettingsStore.active.object(forKey: legacyPlayerSeekSecondsKey) != nil {
            ProfileSettingsStore.active.set(ProfileSettingsStore.active.double(forKey: legacyPlayerSeekSecondsKey), forKey: playerSeekSecondsKey)
        }
        let savedSeconds = ProfileSettingsStore.active.double(forKey: playerSeekSecondsKey)
        let seconds = savedSeconds > 0 ? savedSeconds : 10.0
        return min(max(seconds, 5.0), 60.0)
    }
    private var defaultPlaybackSpeed: Double {
        let savedSpeed = ProfileSettingsStore.active.double(forKey: "defaultPlaybackSpeed")
        let speed = savedSpeed > 0 ? savedSpeed : 1.0
        return min(max(speed, 0.25), 3.0)
    }
    private var isBrightnessControlEnabled: Bool {
        if ProfileSettingsStore.active.object(forKey: "playerBrightnessGestureEnabled") == nil,
           let legacy = ProfileSettingsStore.active.object(forKey: "vlcBrightnessGestureEnabled") as? Bool {
            ProfileSettingsStore.active.set(legacy, forKey: "playerBrightnessGestureEnabled")
            return legacy
        }
        return ProfileSettingsStore.active.bool(forKey: "playerBrightnessGestureEnabled")
    }
    private var isVolumeControlEnabled: Bool {
        let enabled: Bool
        if ProfileSettingsStore.active.object(forKey: "playerVolumeGestureEnabled") == nil,
           let legacy = ProfileSettingsStore.active.object(forKey: "vlcVolumeGestureEnabled") as? Bool {
            ProfileSettingsStore.active.set(legacy, forKey: "playerVolumeGestureEnabled")
            enabled = legacy
        } else {
            enabled = ProfileSettingsStore.active.bool(forKey: "playerVolumeGestureEnabled")
        }
        return enabled
    }
    private var isMetalPerformanceOverlayActive: Bool {
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        return (metalMPVRenderer != nil || gpuMPVRenderer != nil) && Settings.shared.mpvPerformanceOverlayEnabled
#else
        return false
#endif
    }

    private var originalSpeed: Double = 1.0
    private var holdGesture: UILongPressGestureRecognizer?

    private var controlsHideWorkItem: DispatchWorkItem?

    private var controlsVisibilityGeneration = 0
    private var controlsVisible: Bool = true {
        didSet {
            guard controlsVisible != oldValue else { return }
            applyInteractiveRenderThrottle()
        }
    }
    private var suppressNextPlayPauseControlReveal = false
    private var playPauseRevealSuppressionToken = 0
    private var pendingSeekTime: Double?
    private var defaultPlaybackSpeedApplied = false
    private var metalPerformanceOverlayTimer: Timer?
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE && ECLIPSE_MPVKIT_METAL_LIVE_QUALITY_RECONFIGURE
    private var metalThermalQualityTimer: Timer?

    private var hasShownThermalQualityNotice = false
#endif
    private var playerNoticeDismissWorkItem: DispatchWorkItem?
#if os(iOS)
    private var watchTogetherConnectionState: WatchTogetherConnectionState = .ready
    private var watchTogetherMediaIdentifier: String?
    private var pendingWatchTogetherPlaybackState: (state: WatchTogetherSharedState, shouldSeek: Bool)?
    private var lastWatchTogetherSharedState: WatchTogetherSharedState?
    private var watchTogetherRendererReady = false
    private var watchTogetherRateNudgeActive = false
    private weak var episodeSourceSheetController: UIViewController?
    private var episodeSourceSheetTransitionID: UUID?
#endif
    private var lastCPUProcessTime: TimeInterval?
    private var lastCPUWallTime: CFTimeInterval?
    private var lastCPUUsagePercent: Double?

    private lazy var gpuUsageSampler: GPUUsageSampler? = GPUUsageSampler()

    override func viewDidLoad() {
        super.viewDidLoad()
        bindPlaybackWindowSceneIfAvailable(source: "view-did-load")
        beginMediaStatePlaybackLeaseIfNeeded()
        view.backgroundColor = .black
        let initialURLSummary = initialURL.map(playbackURLSummary) ?? "nil"
        logMPV("viewDidLoad initialURL={\(initialURLSummary)} preset=\(initialPreset?.id.rawValue ?? "nil") mediaInfo=\(String(describing: mediaInfo))")
        logVLCUI("viewDidLoad initialURL={\(initialURLSummary)} preset=\(initialPreset?.id.rawValue ?? "nil") mediaInfo=\(String(describing: mediaInfo))", type: "Stream")

#if !os(tvOS)
        modalPresentationCapturesStatusBarAppearance = true
#endif
        setupLayout()
        applyPlayerSkinIfNeeded(force: true)
        updatePlayerTitle()

        setupActions()
#if os(iOS)
        applyPlaybackLockState(capturingOrientationIfNeeded: false)
#endif
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

            subtitleButton.showsMenuAsPrimaryAction = true
            speedButton.showsMenuAsPrimaryAction = true
            audioButton.showsMenuAsPrimaryAction = true
            updateSubtitleTracksMenu()
        }
        updateEpisodeBrowserButtonVisibility()

        NotificationCenter.default.addObserver(self, selector: #selector(handleLoggerNotification(_:)), name: NSNotification.Name("LoggerNotification"), object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaStateAccountBoundary),
            name: .mediaStateWillChangeCurrentUser,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActiveProfileDidChange),
            name: .activeProfileDidChange,
            object: nil
        )
        activeProfileWillChangeCancellable = ProfileManager.shared.$activeProfileID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] incomingProfileID in
                self?.handleActiveProfileWillChange(to: incomingProfileID)
            }
        if isVLCPlayer || isMPVRenderer {
            lastKnownVLCCustomSubtitleOverlayEnabled = isVLCCustomSubtitleOverlayEnabled
            NotificationCenter.default.addObserver(self, selector: #selector(handleUserDefaultsDidChange), name: UserDefaults.didChangeNotification, object: nil)
        }

        view.setNeedsLayout()
        view.layoutIfNeeded()

        do {
            try rendererStart()
            logSharedPlayerControl("renderer.start succeeded")
        } catch {
            let rendererName = vlcRenderer != nil ? "VLC" : "MPV"
            Logger.shared.log("Failed to start \(rendererName) renderer: \(error)", type: "Error")
        }

        if isMPVRenderer {
            installMPVPictureInPictureController(reason: "view-did-load")
            configureMPVAppExitPictureInPictureAutomation(reason: "viewDidLoad")
        } else {
            renderer.setPictureInPictureStopRequestHandler(nil)
            pipController = nil
            logPictureInPicture("skipping MPV sample-buffer PiPController renderer=\(mpvRendererName)")
        }
        updatePiPButtonVisibility()

        showControlsTemporarily()

        if let url = initialURL, let preset = initialPreset {
            logSharedPlayerControl("loading initial target={\(playbackURLSummary(url))} preset=\(preset.id.rawValue)")
            load(url: url, preset: preset, headers: initialHeaders)
        }

        updateProgressHostingController()
        updateSpeedMenu()
        updateMetalPerformanceOverlayVisibility()
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE && ECLIPSE_MPVKIT_METAL_LIVE_QUALITY_RECONFIGURE
        startMetalThermalQualityMonitoringIfNeeded()
#endif

        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate), name: UIApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidReceiveMemoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE && ECLIPSE_MPVKIT_METAL_LIVE_QUALITY_RECONFIGURE
        NotificationCenter.default.addObserver(self, selector: #selector(metalThermalStateDidChange), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
#endif
        NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidEnterBackground(_:)), name: UIScene.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneWillEnterForeground(_:)), name: UIScene.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appScenePhaseDidChange(_:)), name: .eclipseScenePhaseDidChange, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        bindPlaybackWindowSceneIfAvailable(source: "view-did-appear")
        if claimMPVAppExitPictureInPictureOwnership(
            reason: "view-did-appear",
            recordingActivation: true
        ) {
            configureMPVAppExitPictureInPictureAutomation(reason: "view-did-appear")
        }
#if os(iOS)
        presentationController?.delegate = self
        applyPlaybackLockState(capturingOrientationIfNeeded: true)
#endif
        submitDeferredIPadGPUPlaybackLoadIfReady(source: "view-did-appear")
        playbackHandoffHasAppeared = true
        postPlayerInterfaceCoverage(covered: true)
        view.bringSubviewToFront(errorBanner)
        view.bringSubviewToFront(playerNoticeBanner)
        refreshPlayerSkinDecorationAnimations()
        logVLCUIViewSnapshot("viewDidAppear")
        if let pendingPlaybackFailureAlert {
            self.pendingPlaybackFailureAlert = nil
            presentPlaybackFailureAlert(pendingPlaybackFailureAlert)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        postPlayerInterfaceCoverage(covered: false)
#if os(iOS)
        if let scene = view.window?.windowScene ?? playbackWindowScene {
            AppDelegate.setOrientationLock(.all, for: scene)
        }
#endif
    }

    private func postPlayerInterfaceCoverage(covered: Bool) {
        let sceneSessionIdentifier = (viewIfLoaded?.window?.windowScene ?? playbackWindowScene)?
            .session.persistentIdentifier
        NotificationCenter.default.post(
            name: .playerInterfaceCoverageDidChange,
            object: self,
            userInfo: PlayerInterfaceCoverageNotification.userInfo(
                covered: covered,
                playerIdentifier: playerInterfaceCoverageIdentifier,
                sceneSessionIdentifier: sceneSessionIdentifier
            )
        )
    }

    private func bindPlaybackWindowSceneIfAvailable(source: String) {
        let resolvedScene = viewIfLoaded?.window?.windowScene
            ?? presentingViewController?.viewIfLoaded?.window?.windowScene
            ?? navigationController?.viewIfLoaded?.window?.windowScene
            ?? parent?.viewIfLoaded?.window?.windowScene
        guard let resolvedScene,
              playbackWindowScene !== resolvedScene else {
            return
        }
        playbackWindowScene = resolvedScene
        logPictureInPicture(
            "bound playback window scene source=\(source) scene=\(resolvedScene.session.persistentIdentifier)"
        )
    }

#if !os(tvOS)
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if let lockedMask = PlayerPlaybackLockSettings.lockedOrientationMask() {
            return lockedMask
        }
        if ProfileSettingsStore.active.bool(forKey: "alwaysLandscape") {
            return .landscape
        } else {
            return .all
        }
    }

    override var shouldAutorotate: Bool {
        !PlayerPlaybackLockSettings.isLocked()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        bindPlaybackWindowSceneIfAvailable(source: "view-will-appear")
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

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        updatePlayerTitleLayout(forWidth: size.width)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            self.view.layoutIfNeeded()
            self.rendererRenderingLayoutDidChange()
        }, completion: { [weak self] _ in
            guard let self else { return }
            self.view.layoutIfNeeded()
            self.rendererRenderingLayoutDidChange()
            self.refreshPlayerSkinDecorationAnimations()
        })
    }
#endif

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
#if !os(tvOS)
        updatePlayerTitleLayout(forWidth: view.bounds.width)
#endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
#if !os(tvOS)
        updateGestureControlLayoutForCurrentSize()
#endif

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if isVLCPlayer {
            displayLayer.removeFromSuperlayer()
            displayLayer.isHidden = true
            displayLayer.opacity = 0.0
            displayLayer.zPosition = -1
        } else {
            displayLayer.frame = videoContainer.bounds
            rendererRenderingLayoutDidChange()
        }

        playerSkinDecorationLayer.frame = controlsOverlayView.bounds

        CATransaction.commit()

        if deferredIPadGPUPlaybackLoad != nil {
            DispatchQueue.main.async { [weak self] in
                self?.submitDeferredIPadGPUPlaybackLoadIfReady(source: "layout")
            }
        }
    }

#if !os(tvOS)
    private func updateGestureControlLayoutForCurrentSize() {
        let isPortrait = view.bounds.height > view.bounds.width
        volumeWidthConstraint?.constant = isPortrait ? 154 : 220
        volumeHeightConstraint?.constant = isPortrait ? 32 : 36
        volumeTopConstraint?.constant = isPortrait ? 62 : 12

        let availableWidth = max(videoContainer.bounds.width, view.bounds.width)
        let compactLimit = max(240, availableWidth - 32)
        let landscapeLimit = min(520, max(360, availableWidth * 0.48))
        nextEpisodeButtonMaxWidthConstraint?.constant = isPortrait ? min(420, compactLimit) : landscapeLimit
    }

    private func updatePlayerTitleLayout(forWidth width: CGFloat) {
        guard let playerTitleCenterConstraint else { return }

        let usesCompactPlayerWidth = width > 0 && width < 524
        let priority: UILayoutPriority = usesCompactPlayerWidth ? .defaultHigh : .required
        guard playerTitleCenterConstraint.priority != priority else { return }
        playerTitleCenterConstraint.priority = priority
    }
#endif

    deinit {
        isClosing = true
        releaseEphemeralProxyOwnership()
        releaseMPVAppExitPictureInPictureOwnership(
            reason: "deinit",
            clearActivationCandidate: true
        )
        invalidateIPadGPUPlaybackLoadGate()
        setIdleTimerDisabledForPlayback(false, reason: "deinit")
        audioMenuDebounceTimer?.invalidate()
        subtitleMenuDebounceTimer?.invalidate()
        nativePlayerMenuRefreshWorkItem?.cancel()
        metalPerformanceOverlayTimer?.invalidate()
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE && ECLIPSE_MPVKIT_METAL_LIVE_QUALITY_RECONFIGURE
        metalThermalQualityTimer?.invalidate()
#endif
        playerNoticeDismissWorkItem?.cancel()
        playbackStartupWorkItem?.cancel()
        cancelScheduledMPVPictureInPictureWarmups(reason: "deinit")
#if !os(tvOS)
        midPlaybackStallTimer?.invalidate()
        outputVolumeObservation?.invalidate()
        outputVolumeObservation = nil
#endif
        MainActor.assumeIsolated {
            renderer.setPictureInPictureStopRequestHandler(nil)
            if let mpv = mpvRenderer {
                mpv.delegate = nil
            }
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
            if let metal = metalMPVRenderer {
                metal.delegate = nil
            }
            if let gpu = gpuMPVRenderer {
                gpu.delegate = nil
            }
#endif
            if let vlc = vlcRenderer {
                vlc.delegate = nil
            }
        }
        logSharedPlayerControl("deinit; stopping renderer and restoring state")
        if let mediaInfo, !hasFinalizedMediaStatePlayback {
            syncTraktProgressOnPlaybackCloseIfNeeded(for: mediaInfo, reason: "deinit")
        }
        if pipController?.isPictureInPictureActive == true
            || pipController?.isPictureInPictureStartPending == true {
            cancelMPVPictureInPictureStartRequests(reason: "player-deinit")
            pipController?.stopPictureInPicture(source: "player-deinit")
        }
        pipController?.delegate = nil
        openSubtitlesFetchTask?.cancel()
        stremioSubtitleFetchTask?.cancel()
        nextEpisodeStagingTask?.cancel()
        nextEpisodePreviewTask?.cancel()
        nextEpisodeArtworkTask?.cancel()
        dismissEpisodeBrowser(animated: false, reason: "deinit")
        pipController?.invalidate()
        rendererStop()

        displayLayer.removeFromSuperlayer()

        pendingUserDefaultsChangeWorkItem?.cancel()
        subtitleMenuRefreshWorkItem?.cancel()
        finishMediaStatePlaybackLeaseIfNeeded()
        NotificationCenter.default.removeObserver(self)
    }

    convenience init(url: URL, preset: PlayerPreset, headers: [String: String]? = nil, subtitles: [String]? = nil, subtitleNames: [String]? = nil, subtitleHeadersByURL: [String: [String: String]]? = nil, mediaSelectionIntent: PlaybackMediaSelectionIntent? = nil, mediaInfo: MediaInfo? = nil, imdbId: String? = nil) {
        self.init(nibName: nil, bundle: nil)
        self.initialURL = url
        self.initialPreset = preset
        self.initialHeaders = headers
        self.initialSubtitles = subtitles
        self.initialSubtitleNames = subtitleNames
        self.initialSubtitleHeadersByURL = subtitleHeadersByURL
        self.playbackMediaSelectionIntent = mediaSelectionIntent
        if let mediaSelectionIntent {
            self.subtitleModel.setVisible(mediaSelectionIntent.subtitlesEnabled, persist: false)
        }
        self.mediaInfo = mediaInfo
        self.imdbId = imdbId
        Logger.shared.log("[PlayerViewController.init] target={\(playbackURLSummary(url))} preset=\(preset.id.rawValue) headers=\(headers?.count ?? 0) subtitles=\(subtitles?.count ?? 0) mediaInfo=\(mediaInfo != nil)", type: "Stream")
    }

    private var automaticAudioSelectionLanguage: String {
        if let playbackMediaSelectionIntent {
            return playbackMediaSelectionIntent.preferredAudioLanguage ?? ""
        }
        return (isAnimeContent()
            ? Settings.shared.preferredAnimeAudioLanguage
            : Settings.shared.preferredAutoAudioLanguage).lowercased()
    }

    private var automaticSubtitleSelectionLanguage: String {
        if let playbackMediaSelectionIntent {
            return playbackMediaSelectionIntent.preferredSubtitleLanguage ?? ""
        }
        return Settings.shared.defaultSubtitleLanguage
    }

    private var automaticSubtitlesEnabled: Bool {
        playbackMediaSelectionIntent?.subtitlesEnabled
            ?? Settings.shared.enableSubtitlesByDefault
    }

    private func recordUserMediaSelection(
        audioLanguage: String? = nil,
        subtitleLanguage: String? = nil,
        subtitlesEnabled: Bool? = nil
    ) {

        guard let current = playbackMediaSelectionIntent else { return }
        playbackMediaSelectionIntent = current.overridingRendererSelection(
            audioLanguage: audioLanguage,
            subtitleLanguage: subtitleLanguage,
            hasSelectedSubtitle: subtitlesEnabled
        )
    }

    private func rendererNeutralLanguage(
        languageTag: String? = nil,
        displayName: String? = nil
    ) -> String? {
        if let normalizedTag = PlaybackMediaSelectionIntent.normalizedLanguage(languageTag) {
            return canonicalKnownLanguage(in: normalizedTag) ?? normalizedTag
        }
        guard let displayName else { return nil }
        return canonicalKnownLanguage(in: displayName)
    }

    private func canonicalKnownLanguage(in rawValue: String) -> String? {
        let normalized = rawValue
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let tokens = Set(
            normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        let knownLanguages: [(code: String, aliases: Set<String>)] = [
            ("eng", ["eng", "en", "english", "us", "uk"]),
            ("jpn", ["jpn", "ja", "jp", "japanese"]),
            ("zho", ["zho", "chi", "zh", "chinese", "mandarin", "cantonese"]),
            ("kor", ["kor", "ko", "korean"]),
            ("spa", ["spa", "es", "esp", "spanish", "lat", "latino"]),
            ("fra", ["fra", "fre", "fr", "french"]),
            ("deu", ["deu", "ger", "de", "german"]),
            ("ita", ["ita", "it", "italian"]),
            ("por", ["por", "pt", "br", "portuguese"]),
            ("rus", ["rus", "ru", "russian"])
        ]
        return knownLanguages.first(where: { !$0.aliases.isDisjoint(with: tokens) })?.code
    }

    private func recordUserAudioSelection(name: String, languageTag: String?) {
        recordUserMediaSelection(
            audioLanguage: rendererNeutralLanguage(languageTag: languageTag, displayName: name)
        )
    }

    private func recordUserSubtitleSelection(
        enabled: Bool,
        languageTag: String? = nil,
        displayName: String? = nil
    ) {
        recordUserMediaSelection(
            subtitleLanguage: rendererNeutralLanguage(
                languageTag: languageTag,
                displayName: displayName
            ),
            subtitlesEnabled: enabled
        )
    }

    private func setSessionAwareSubtitleVisible(_ visible: Bool) {
        setSubtitleVisible(visible, persist: playbackMediaSelectionIntent == nil)
    }

    private var shouldUseIPadGPUPlaybackLoadGate: Bool {
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        UIDevice.current.userInterfaceIdiom == .pad && gpuMPVRenderer != nil
#else
        false
#endif
    }

    private func isIPadGPUPlaybackViewportReady(_ request: DeferredIPadGPUPlaybackLoad) -> Bool {
        guard isViewLoaded,
              view.window != nil,
              let renderingView = mpvRenderingView,
              renderingView.window != nil,
              view.bounds.width > 1,
              view.bounds.height > 1,
              videoContainer.bounds.width > 1,
              videoContainer.bounds.height > 1,
              renderingView.bounds.width > 1,
              renderingView.bounds.height > 1 else {
            return false
        }

        let isLandscape = videoContainer.bounds.width > videoContainer.bounds.height
        return isLandscape || CACurrentMediaTime() - request.queuedAt >= 0.9
    }

    private func deferIPadGPUPlaybackLoadIfNeeded(
        url: URL,
        preset: PlayerPreset,
        headers: [String: String]?,
        playbackShouldResumeAfterLoad: Bool? = nil
    ) -> Bool {
        guard shouldUseIPadGPUPlaybackLoadGate else { return false }

        ipadGPUPlaybackLoadGateGeneration += 1
        let generation = ipadGPUPlaybackLoadGateGeneration
        let request = DeferredIPadGPUPlaybackLoad(
            url: url,
            preset: preset,
            headers: headers,
            playbackShouldResumeAfterLoad: playbackShouldResumeAfterLoad,
            generation: generation,
            queuedAt: CACurrentMediaTime()
        )
        deferredIPadGPUPlaybackLoad = request

        view.layoutIfNeeded()
        rendererRenderingLayoutDidChange()
        if isIPadGPUPlaybackViewportReady(request) {
            deferredIPadGPUPlaybackLoad = nil
            return false
        }

        logMPV("iPad gpu-next load deferred until attached viewport generation=\(generation) view=\(view.bounds.size) video=\(videoContainer.bounds.size) render=\(mpvRenderingView?.bounds.size ?? .zero) attached=\(view.window != nil && mpvRenderingView?.window != nil)")
        scheduleIPadGPUPlaybackLoadGateRetry(generation: generation)
        return true
    }

    private func scheduleIPadGPUPlaybackLoadGateRetry(generation: Int) {
        guard ipadGPUPlaybackLoadGateRetryGeneration != generation else { return }
        ipadGPUPlaybackLoadGateRetryGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if self.ipadGPUPlaybackLoadGateRetryGeneration == generation {
                self.ipadGPUPlaybackLoadGateRetryGeneration = nil
            }
            guard generation == self.ipadGPUPlaybackLoadGateGeneration else { return }
            self.submitDeferredIPadGPUPlaybackLoadIfReady(source: "retry")
        }
    }

    private func submitDeferredIPadGPUPlaybackLoadIfReady(source: String) {
        guard !isClosing,
              let request = deferredIPadGPUPlaybackLoad,
              request.generation == ipadGPUPlaybackLoadGateGeneration else {
            return
        }

        view.layoutIfNeeded()
        rendererRenderingLayoutDidChange()
        guard isIPadGPUPlaybackViewportReady(request) else {
            scheduleIPadGPUPlaybackLoadGateRetry(generation: request.generation)
            return
        }

        deferredIPadGPUPlaybackLoad = nil
        ipadGPUPlaybackLoadGateRetryGeneration = nil
        let age = CACurrentMediaTime() - request.queuedAt
        logMPV("iPad gpu-next load submitted source=\(source) generation=\(request.generation) age=\(String(format: "%.2f", age))s video=\(videoContainer.bounds.size) render=\(mpvRenderingView?.bounds.size ?? .zero)")
        performLoad(url: request.url, preset: request.preset, headers: request.headers)
        if let shouldResume = request.playbackShouldResumeAfterLoad {
            applyPlaybackIntentAfterLoad(shouldResume: shouldResume, source: "\(source)-deferred")
        }
    }

    private func invalidateIPadGPUPlaybackLoadGate() {
        ipadGPUPlaybackLoadGateGeneration += 1
        deferredIPadGPUPlaybackLoad = nil
        ipadGPUPlaybackLoadGateRetryGeneration = nil
    }

    func load(url: URL, preset: PlayerPreset, headers: [String: String]? = nil) {
        load(
            url: url,
            preset: preset,
            headers: headers,
            playbackShouldResumeAfterLoad: nil
        )
    }

    private func load(
        url: URL,
        preset: PlayerPreset,
        headers: [String: String]?,
        playbackShouldResumeAfterLoad: Bool?
    ) {
        if deferIPadGPUPlaybackLoadIfNeeded(
            url: url,
            preset: preset,
            headers: headers,
            playbackShouldResumeAfterLoad: playbackShouldResumeAfterLoad
        ) {
            return
        }
        performLoad(url: url, preset: preset, headers: headers)
        if let shouldResume = playbackShouldResumeAfterLoad {
            applyPlaybackIntentAfterLoad(shouldResume: shouldResume, source: "immediate")
        }
    }

    private func applyPlaybackIntentAfterLoad(shouldResume: Bool, source: String) {
        logMPV("applying post-load playback intent source=\(source) shouldResume=\(shouldResume)")
        rendererPlaybackIntentGeneration &+= 1
        mpvBackgroundFallbackAutoPaused = false
        mpvBackgroundFallbackPauseIntentGeneration = nil
        mpvBackgroundFallbackPauseLifecycleGeneration = nil
        if shouldResume {
            renderer.play()
        } else {
            renderer.pausePlayback()
        }
        rendererSchedulePictureInPicturePlaybackStateUpdate()
        updatePlayPauseButton(isPaused: !shouldResume, shouldShowControls: false)
    }

    private func performLoad(url: URL, preset: PlayerPreset, headers: [String: String]?) {
#if os(iOS) && !targetEnvironment(macCatalyst)
        if isMPVRenderer,
           MPVHeaderProxy.shared.isManagedSkyStreamSessionURL(url) {

            registerMPVHeaderProxyURL(url)
        }
#endif
        pendingRendererRestartRetryGeneration = nil
        playbackLoadGeneration += 1
        cancelMPVBackgroundAudioFallback(reason: "new-load")
        mpvBackgroundFallbackAutoPaused = false
        mpvBackgroundFallbackPauseIntentGeneration = nil
        mpvBackgroundFallbackPauseLifecycleGeneration = nil
        releaseMPVAppExitPictureInPictureOwnership(reason: "new-load")

        cancelMPVPictureInPictureStartRequests(reason: "new-load")
        let previousPiPState = mpvPictureInPictureControllerState()
        if previousPiPState.active || previousPiPState.pending {
            rendererFinishPictureInPicture()
        }
        installMPVPictureInPictureController(reason: "new-load")
        playbackTraceLoadStartedAt = Date()
        playbackTraceLastStageAt = playbackTraceLoadStartedAt
        playbackTraceLastProgressPosition = nil
        playbackTraceProgressAdvanceCount = 0
        playbackTraceLastLoadingValue = nil
        playbackTraceLastPauseValue = nil
        logPlaybackStage(
            "load-begin",
            "renderer=\(mpvRendererName) target={\(playbackURLSummary(url))} upscaling=\(Settings.shared.mpvUpscalingMode.rawValue) resumeCandidate=\(mediaInfo != nil) autoMode=\(playbackLaunchContext?.autoMode ?? false)"
        )
        logMPV("load target={\(playbackURLSummary(url))} preset=\(preset.id.rawValue) headers=\(headers?.count ?? 0)")
        initialURL = url
        initialHeaders = headers
#if os(iOS) && !targetEnvironment(macCatalyst)
        configureSkyStreamRouteRejectionRecovery(
            for: url,
            expectedLoadGeneration: playbackLoadGeneration
        )
#endif
        openSubtitlesResults.removeAll()
        openSubtitlesFetchTask?.cancel()
        openSubtitlesFetchTask = nil
        openSubtitlesFetchInProgress = false
        openSubtitlesSearchAttempted = false
        openSubtitlesFallbackAttempted = false
        openSubtitlesLoadedURLs.removeAll()
        stremioSubtitleResults.removeAll()
        stremioSubtitleFetchTask?.cancel()
        stremioSubtitleFetchTask = nil
        stremioSubtitleFetchInProgress = false
        stremioSubtitleSearchAttempted = false
        stremioSubtitleFallbackAttempted = false
        stremioSubtitleLoadedURLs.removeAll()
        onlineSubtitleLoadedURLs.removeAll()
        onlineSubtitleLoadedTrackNames.removeAll()
        onlineSubtitleLoadedRendererTrackIds.removeAll()
        lastSkippedMPVBitmapSubtitleSummary = ""
        vlcExternalSubtitlePriorityDeadline = nil
        nativePlayerMenuRebuildSuppressionUntil = 0
        pendingNativePlayerMenuRefreshKinds.removeAll()
        nativePlayerMenuRefreshWorkItem?.cancel()
        nativePlayerMenuRefreshWorkItem = nil
        resetNativePlayerMenuContentSignatures()
        lastRendererPauseScrobbleAction = nil
        lastRendererPauseScrobbleAt = 0
        didSendFinalTraktScrobble = false
        defaultPlaybackSpeedApplied = false
        cachedPosition = 0
        cachedDuration = 0
        progressModel.position = 0
        progressModel.duration = 1
        progressModel.durationIsKnown = false
        if isVLCPlayer {
            isVLCPlaybackStartupInProgress = true
            canMutateVLCSubtitleTracks = false
            didHandleVLCReadyToSeekForCurrentLoad = false
            didLogDuplicateVLCReadyToSeekForCurrentLoad = false
            lastVLCUISteadyHeartbeatLogTime = 0
            lastVLCUIMemoryWarningLogTime = 0
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
                return "episode showId=\(showId) s=\(seasonNumber) e=\(episodeNumber) title=\(showTitle ?? "nil") isAnime=\(isAnime)"
            }
        }()
        Logger.shared.log("PlayerViewController.load: isAnimeHint=\(isAnimeHint ?? false) mediaInfo=\(mediaInfoLabel)", type: "Stream")
        logVLCUI("load prepared mediaInfo=\(mediaInfoLabel) pendingSeek=\(secondsText(pendingSeekTime)) subtitles=\(subtitleURLs.count) openSubsEnabled=\(Settings.shared.playerOpenSubtitlesEnabled) fallback=\(Settings.shared.playerOpenSubtitlesAutoFallbackEnabled)", type: "Stream")

        if !isRunning {
            do {
                try rendererStart()
            } catch {
                let message = "The MPV renderer failed to start: \(error.localizedDescription)"
                logPlaybackStage("renderer-start-failed", "error=\(error.localizedDescription)")
                handlePlaybackStartupFailure(message, isSourceFailure: false)
                return
            }
        }
        logPlaybackStage("renderer-started", "running=\(isRunning)")

        userSelectedAudioTrack = false
        userSelectedSubtitleTrack = false
        attemptedAudioAutoSelectSignature = nil
        lastAudioTracksMenuLogSignature = nil
        lastSubtitleTracksMenuLogSignature = nil
        lastDefaultSubtitleChoiceLogSignature = nil
        lastVLCPauseLogSignature = nil
        lastVLCPauseLogTime = 0
        cancelScheduledMPVPictureInPictureWarmups(reason: "new-load")
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
        pendingInitialResumeRetryCount = 0
        pendingInitialResumeLastRetryAt = nil
#if os(iOS)
        watchTogetherRendererReady = false
        pendingWatchTogetherPlaybackState = nil
#endif
        releaseBackgroundRecoveryProgressGate(reason: "new-load")
        setVLCSubtitleStyleReloadProgressGate(active: false, reason: "new-load")
        if let info = mediaInfo {
            prepareSeekToLastPosition(for: info)
        }
        if let refreshPosition = pendingSourceRefreshResumePosition,
           refreshPosition.isFinite,
           refreshPosition >= 0 {
            pendingSeekTime = refreshPosition
            pendingInitialResumeTarget = refreshPosition
            pendingInitialResumeDeadline = Date().addingTimeInterval(20)
            pendingInitialResumeRetryCount = 0
            pendingInitialResumeLastRetryAt = nil
            pendingSourceRefreshResumePosition = nil
            Logger.shared.log(
                "Prepared source-refresh resume seek to \(Int(refreshPosition))s",
                type: "Progress"
            )
        }
        logPlaybackStage("resume-prepared", "target=\(secondsText(pendingSeekTime))")
        let launchContextSummary = playbackLaunchContext.map {
            "source=\($0.sourceName) kind=\($0.sourceKind.rawValue) autoMode=\($0.autoMode) headers=\($0.headers.count) subtitles=\($0.subtitles.count)"
        } ?? "nil"
        logVLCUI("load resume prepared pendingSeek=\(secondsText(pendingSeekTime)) progressCached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) launchContext={\(launchContextSummary)}", type: "Progress")
        rendererPrepareInitialSeek(to: pendingSeekTime)
        if isMPVRenderer {
            if isMetalMPVRenderer && ExperimentalFeatureState.canUseExperimentalMPVPlayback {
                Logger.shared.log("[PlayerVC.PlaybackStart] MPV warmup candidate source=resolved-playback-url autoMode=\(AutoModeSettings.isEnabled()) renderer=\(mpvRendererName) target={\(playbackURLSummary(url))}", type: "MPV")
                ExperimentalMPVPreloadManager.shared.prewarm(
                    url: url,
                    headers: headers,
                    label: mediaInfoLabel
                )
            } else if ProfileSettingsStore.active.bool(forKey: ExperimentalFeatureState.mpvPreloadEnabledKey) {
                let reason = isMetalMPVRenderer ? (ExperimentalFeatureState.mpvAdvancedPlaybackUnavailableReason ?? "advanced-unavailable") : "renderer-not-moltenvk-active"
                Logger.shared.log("[PlayerVC.PlaybackStart] MPV warmup not started reason=\(reason) renderer=\(mpvRendererName) target={\(playbackURLSummary(url))}", type: "MPV")
            }
        }
        let playbackRequest = preparePlayerHeaderProxyIfNeeded(originalURL: url, headers: headers)
        logPlaybackStage(
            "transport-ready",
            "original={\(playbackURLSummary(url))} submitted={\(playbackURLSummary(playbackRequest.url))} proxied=\(isLocalProxyURL(playbackRequest.url)) headerCount=\(playbackRequest.headers?.count ?? 0)"
        )
        if !isVLCPlayer {
            preparePlaybackStartupMonitoring(for: playbackRequest.url, headers: playbackRequest.headers ?? headers ?? [:])
        } else {
            rendererApplySubtitleStyle(currentSubtitleStyle())
        }
        rendererLoad(url: playbackRequest.url, preset: preset, headers: playbackRequest.headers)
        logPlaybackStage("renderer-submitted", "pendingSeek=\(secondsText(pendingSeekTime))")
        applyDefaultPlaybackSpeed()
#if os(iOS)
        configureWatchTogetherForCurrentMedia()
#endif

        if let subs = initialSubtitles, !subs.isEmpty {
            loadSubtitles(subs, names: initialSubtitleNames)
        }
        prefetchOpenSubtitlesIfEnabled(reason: "load")
        prefetchStremioSubtitlesIfAvailable(reason: "load")
    }

    private func preparePlaybackStartupMonitoring(for url: URL, headers: [String: String]) {
        playbackStartupWorkItem?.cancel()
#if !os(tvOS)
        stopMidPlaybackStallWatchdog()
#endif
        playbackDidStart = false
        refreshIdleTimerForPlayback(reason: "startup-monitor-reset")
        playbackFailureHandled = false
        playbackSlowProbeCount = 0
        playbackTraceLastProgressPosition = nil
        playbackTraceProgressAdvanceCount = 0
        guard !url.isFileURL else {
            Logger.shared.log("[PlayerVC.PlaybackStart] startup monitor skipped for local file", type: "Stream")
            logPlaybackStage("monitor-skipped", "reason=local-file")
            return
        }
        Logger.shared.log("[PlayerVC.PlaybackStart] startup monitor armed renderer=\(isVLCPlayer ? "VLC" : "MPV") target={\(playbackURLSummary(url))} headerKeys=[\(headers.keys.sorted().joined(separator: ","))]", type: isVLCPlayer ? "Stream" : "MPV")
        logPlaybackStage("monitor-armed", "deadline=18.00s target={\(playbackURLSummary(url))}")
        schedulePlaybackStartupCheck(
            url: url,
            headers: headers,
            generation: playbackLoadGeneration,
            delay: 18
        )
    }

    private func schedulePlaybackStartupCheck(
        url: URL,
        headers: [String: String],
        generation: Int,
        delay: TimeInterval
    ) {
        playbackStartupWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.playbackLoadGeneration == generation,
                  !self.playbackDidStart,
                  !self.playbackFailureHandled,
                  !self.isClosing else {
                return
            }
            self.logPlaybackStage(
                "watchdog-fired",
                "probe=\(self.playbackSlowProbeCount + 1) loading=\(self.isRendererLoading) paused=\(self.rendererIsPausedState()) cached=\(self.secondsText(self.cachedPosition))/\(self.secondsText(self.cachedDuration)) renderer={\(self.rendererPictureInPictureDebugSnapshot())}"
            )
            self.runPlaybackStartupProbe(url: url, headers: headers, generation: generation)
        }
        playbackStartupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func markPlaybackStarted(reason: String) {
        guard !playbackDidStart else {
            refreshIdleTimerForPlayback(reason: "playback-continued-\(reason)")
            return
        }
        playbackDidStart = true
        refreshIdleTimerForPlayback(reason: "playback-started-\(reason)")
        playbackStartupWorkItem?.cancel()
#if !os(tvOS)
        armMidPlaybackStallWatchdog()
#endif
        logPlaybackStage(
            "playback-confirmed",
            "reason=\(reason) progressSamples=\(playbackTraceProgressAdvanceCount) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading)"
        )
        Logger.shared.log("[PlayerVC.PlaybackStart] renderer=\(isVLCPlayer ? "VLC" : "MPV") started reason=\(reason) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) loading=\(isRendererLoading) context=\(playbackLaunchContext?.sourceName ?? "nil")", type: isVLCPlayer ? "VLCPlayback" : "MPV")
        if let context = playbackLaunchContext {
            SourceHealthStore.shared.recordPlaybackSuccess(sourceId: context.sourceId, sourceName: context.sourceName)
            Logger.shared.log("[PlayerVC.PlaybackStart] \(context.sourceName) started via \(reason)", type: "Stream")
        }

        scheduleMPVPictureInPictureForegroundWarmup(
            source: "playback-started-\(reason)",
            delays: [0.35, 1.50],
            forceFirst: true
        )
    }

#if !os(tvOS)
    private func armMidPlaybackStallWatchdog() {
        stopMidPlaybackStallWatchdog()
        guard isMPVRenderer, !activeMPVHeaderProxyURLs.isEmpty else { return }
        midPlaybackStallReferenceDate = Date()
        midPlaybackStallLastPosition = cachedPosition
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.evaluateMidPlaybackStallWatchdog()
        }
        midPlaybackStallTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMidPlaybackStallWatchdog() {
        midPlaybackStallTimer?.invalidate()
        midPlaybackStallTimer = nil
        midPlaybackStallReferenceDate = nil
        midPlaybackStallLastPosition = nil
    }

    private func evaluateMidPlaybackStallWatchdog() {
        guard playbackDidStart, !playbackFailureHandled, !isClosing, isMPVRenderer else {
            stopMidPlaybackStallWatchdog()
            return
        }
        let now = Date()
        let position = cachedPosition
        guard !rendererIsPausedState(), !isSeeking, pendingInitialResumeTarget == nil else {
            midPlaybackStallReferenceDate = now
            midPlaybackStallLastPosition = position
            return
        }
        guard let lastPosition = midPlaybackStallLastPosition,
              abs(position - lastPosition) <= 0.05,
              var referenceDate = midPlaybackStallReferenceDate else {
            midPlaybackStallLastPosition = position
            midPlaybackStallReferenceDate = now
            return
        }
        let healthSnapshots = activeMPVHeaderProxyURLs.compactMap {
            MPVHeaderProxy.shared.upstreamHealth(for: $0)
        }
        guard !healthSnapshots.isEmpty else {
            midPlaybackStallReferenceDate = now
            return
        }
        if let lastSuccessAt = healthSnapshots.compactMap(\.lastSuccessAt).max(),
           lastSuccessAt > referenceDate {
            midPlaybackStallReferenceDate = lastSuccessAt
            referenceDate = lastSuccessAt
        }
        let elapsed = now.timeIntervalSince(referenceDate)
        guard elapsed >= 45 else { return }
        guard let lastFailureAt = healthSnapshots.compactMap(\.lastFailureAt).max(),
              lastFailureAt >= referenceDate else { return }
        let failureCount = healthSnapshots.reduce(0) { $0 + $1.failureCount }
        stopMidPlaybackStallWatchdog()
        Logger.shared.log(
            "[PlayerVC.StallWatchdog] triggered elapsed=\(Int(elapsed))s upstreamFailures=\(failureCount) position=\(secondsText(position)) loading=\(isRendererLoading)",
            type: "Plugin"
        )
        handleUnrecoverableMediaSourceRejection(
            "Playback stalled for \(Int(elapsed)) seconds and the stream host stopped responding.",
            reason: "stalled-upstream"
        )
    }
#endif

    private func runPlaybackStartupProbe(url: URL, headers: [String: String], generation: Int) {
        logPlaybackStage("probe-begin", "attempt=\(playbackSlowProbeCount + 1)")
        Task { [weak self] in
            let result = await SourceHealthMonitor.shared.probeStream(url: url, headers: headers)
            await MainActor.run {
                guard let self,
                      self.playbackLoadGeneration == generation,
                      !self.playbackDidStart,
                      !self.playbackFailureHandled,
                      !self.isClosing else {
                    return
                }

                switch result {
                case .reachable:
                    self.playbackSlowProbeCount += 1
                    self.logPlaybackStage("probe-result", "result=reachable attempt=\(self.playbackSlowProbeCount)")
                    if self.playbackSlowProbeCount >= 3 {
                        self.handlePlaybackStartupFailure(
                            "The stream is reachable, but the renderer remained idle.",
                            isSourceFailure: false
                        )
                    } else {
                        self.showErrorBanner("Stream is reachable but still starting. Waiting a little longer...")
                        self.schedulePlaybackStartupCheck(
                            url: url,
                            headers: headers,
                            generation: generation,
                            delay: 20
                        )
                    }
                case .slowOrIndeterminate(let reason):
                    self.playbackSlowProbeCount += 1
                    self.logPlaybackStage("probe-result", "result=slow attempt=\(self.playbackSlowProbeCount) reason=\(reason)")
                    if self.playbackSlowProbeCount >= 3 {
                        self.handlePlaybackStartupFailure("Playback is taking too long: \(reason)", isSourceFailure: false)
                    } else {
                        self.showErrorBanner("Connection looks slow. Still waiting for playback...")
                        self.schedulePlaybackStartupCheck(
                            url: url,
                            headers: headers,
                            generation: generation,
                            delay: 20
                        )
                    }
                case .networkUnavailable:
                    self.logPlaybackStage("probe-result", "result=network-unavailable")
                    self.handlePlaybackStartupFailure("No internet connection is available.", isSourceFailure: false)
                case .sourceFailed(let reason):
                    self.logPlaybackStage("probe-result", "result=source-failed reason=\(reason)")
                    self.handlePlaybackStartupFailure(reason, isSourceFailure: true)
                }
            }
        }
    }

    private func handlePlaybackStartupFailure(_ message: String, isSourceFailure: Bool) {
        guard !playbackDidStart, !playbackFailureHandled else { return }
        releaseMPVAppExitPictureInPictureOwnership(reason: "playback-startup-failure")
        logPlaybackStage(
            "startup-failure",
            "sourceFailure=\(isSourceFailure) message=\(message) loading=\(isRendererLoading) paused=\(rendererIsPausedState()) renderer={\(rendererPictureInPictureDebugSnapshot())}"
        )
        if !isVLCPlayer, attemptMPVTransportBridgeFallbackIfNeeded(after: message) {
            return
        }
        if !isVLCPlayer,
           (playbackLaunchContext?.autoMode != true || isCoordinatorEngineFallback),
           shouldSilentlyRetryMPVStartup(after: message) {
            let retryKey = playbackLaunchContext?.streamURL ?? initialURL?.absoluteString ?? message
            if mpvSilentStartupRetryKey != retryKey {
                mpvSilentStartupRetryKey = retryKey
                playbackFailureHandled = true
                playbackStartupWorkItem?.cancel()
                Logger.shared.log("[PlayerVC.PlaybackStart] MPV silently retrying startup after first failure: \(message)", type: "MPV")
                restartRendererAndRetryPlayback(afterLoadGeneration: playbackLoadGeneration)
                return
            }
        }
        playbackFailureHandled = true
        playbackStartupWorkItem?.cancel()
        logPlaybackAttribution(reason: "startup-failure", message: message)

        guard let context = playbackLaunchContext else {
            Logger.shared.log("[PlayerVC.PlaybackStart] startup failed without launch context: \(message)", type: "MPV")
            if isVLCPlayer {
                showErrorBanner(message)
            }
            return
        }

        let report = PlaybackFailureReport(context: context, message: message, isSourceFailure: isSourceFailure)
        if let onAutomaticPlaybackFallback,
           PlaybackEngineRetryPolicy.shouldTryAlternateEngine(message: message) {
            self.onAutomaticPlaybackFallback = nil
            onAutomaticPlaybackFallback(report)
            return
        }

        SourceHealthStore.shared.recordPlaybackFailure(
            sourceId: context.sourceId,
            sourceName: context.sourceName,
            reason: message,
            isSourceFailure: isSourceFailure
        )

        if context.autoMode, isCoordinatorEngineFallback {
            showCoordinatorFallbackFailureAlert(report)
        } else if context.autoMode, onPlaybackStartupFailure != nil {
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
            || lower.contains("loading failed")
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
        presentPlaybackFailureAlert(alert)
    }

    private func showCoordinatorFallbackFailureAlert(_ report: PlaybackFailureReport) {
        let alert = UIAlertController(
            title: "Playback Failed in Both Players",
            message: "Molten could not start this stream after AVPlayer failed. \(report.message)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Retry Molten", style: .default) { [weak self] _ in
            self?.retryPlaybackAfterFailure()
        })
        if onPlaybackStartupFailure != nil {
            alert.addAction(UIAlertAction(title: "Try Another Source", style: .default) { [weak self] _ in
                self?.dismissAfterPlaybackFailure(report)
            })
        }
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in
            self?.closeTapped()
        })
        presentPlaybackFailureAlert(alert)
    }

    private func presentPlaybackFailureAlert(_ alert: UIAlertController) {
        guard !isClosing,
              !isBeingDismissed else { return }
        guard viewIfLoaded?.window != nil else {

            pendingPlaybackFailureAlert = alert
            return
        }
        if isBeingPresented, let transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.presentPlaybackFailureAlert(alert)
            }
            return
        }
        if let presentedViewController {
            presentedViewController.dismiss(animated: true) { [weak self] in
                self?.presentPlaybackFailureAlert(alert)
            }
            return
        }
        present(alert, animated: true)
    }

    private func restartRendererAndRetryPlayback(afterLoadGeneration failedGeneration: Int) {
        pendingRendererRestartRetryGeneration = failedGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let retainedProxyURL = self.initialURL.flatMap {
                self.isLocalProxyURL($0) ? $0 : nil
            }
            await self.rendererStopAndWait(retainingMPVHeaderProxyURL: retainedProxyURL)
            guard !self.isClosing,
                  !self.isBeingDismissed,
                  self.viewIfLoaded?.window != nil,
                  self.pendingRendererRestartRetryGeneration == failedGeneration,
                  self.playbackLoadGeneration == failedGeneration else { return }
            self.pendingRendererRestartRetryGeneration = nil
            self.retryPlaybackAfterFailure()
        }
    }

    private func retryPlaybackAfterFailure() {
        guard let context = playbackLaunchContext,
              let preset = initialPreset,
              let url = URL(string: context.streamURL) else {
            rendererReloadCurrentItem()
            return
        }

        playbackDidStart = false
        refreshIdleTimerForPlayback(reason: "retry-reset")
        playbackFailureHandled = false
        playbackSlowProbeCount = 0
        vlcProxyFallbackTried = false
        initialSubtitles = context.subtitles.isEmpty ? nil : context.subtitles
        initialSubtitleNames = context.subtitleNames
        initialSubtitleHeadersByURL = context.subtitleHeadersByURL
        load(url: url, preset: preset, headers: context.headers)
    }

    func playbackEngineHandoffDidFail(_ report: PlaybackFailureReport) {
        guard !isClosing, !isBeingDismissed, viewIfLoaded?.window != nil else { return }
        onAutomaticPlaybackFallback = nil
        playbackFailureHandled = true
        if report.context.autoMode, onPlaybackStartupFailure != nil {
            dismissAfterPlaybackFailure(report)
        } else {
            showManualPlaybackFailureAlert(report)
        }
    }

    private func dismissAfterPlaybackFailure(_ report: PlaybackFailureReport) {
        releaseEphemeralProxyOwnership()
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
                pendingInitialResumeRetryCount = 0
                pendingInitialResumeLastRetryAt = nil
                Logger.shared.log("Prepared resume seek to \(Int(lastPlayedTime))s", type: "Progress")
            }
        }
    }

    private func setupPlayerLoadingIndicator() {
        guard loadingIndicatorHostingController == nil else { return }
        let host = UIHostingController(rootView: AnyView(
            EclipseLoadingIndicator(tint: .white, diameter: 40)
                .accessibilityLabel("Loading video")
                .profileScopedAppStorage()
        ))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        host.view.isUserInteractionEnabled = false
        loadingIndicator.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: loadingIndicator.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: loadingIndicator.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: loadingIndicator.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: loadingIndicator.bottomAnchor)
        ])
        host.didMove(toParent: self)
        loadingIndicatorHostingController = host
    }

    private func teardownPlayerLoadingIndicator() {
        guard let host = loadingIndicatorHostingController else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        loadingIndicatorHostingController = nil
    }

    private func setPlayerLoadingIndicatorVisible(_ visible: Bool, animated: Bool = true) {
        loadingIndicatorShouldBeVisible = visible
        let targetAlpha: CGFloat = visible ? 1.0 : 0.0

        if visible {
            setupPlayerLoadingIndicator()
            videoContainer.bringSubviewToFront(loadingIndicator)
        }

        guard loadingIndicator.alpha != targetAlpha else {
            if !visible {
                teardownPlayerLoadingIndicator()
            }
            return
        }

        let changes = { self.loadingIndicator.alpha = targetAlpha }
        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self,
                  !self.loadingIndicatorShouldBeVisible,
                  self.loadingIndicator.alpha == 0 else { return }
            self.teardownPlayerLoadingIndicator()
        }
        if animated {
            UIView.animate(
                withDuration: visible ? 0.18 : 0.12,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut],
                animations: changes,
                completion: completion
            )
        } else {
            changes()
            completion(true)
        }
    }

    private func archivedSkinColor(forKey key: String, fallback: UIColor) -> UIColor {
        guard let data = ProfileSettingsStore.active.data(forKey: key),
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) else {
            return fallback
        }
        return color
    }

    private func resolvedPlayerSkinAppearance(for skin: MPVPlayerSkin) -> PlayerSkinAppearance {
        switch skin {
        case .defaultSkin:
            return .defaultAppearance
        case .blackAndGold:
            let gold = UIColor(red: 0.92, green: 0.73, blue: 0.27, alpha: 1.0)
            return PlayerSkinAppearance(
                primary: gold,
                secondary: UIColor(red: 1.0, green: 0.91, blue: 0.61, alpha: 1.0),
                overlayBackground: UIColor(red: 0.025, green: 0.018, blue: 0.006, alpha: 0.58),
                centerButtonBackground: gold.withAlphaComponent(0.20),
                menuBackground: UIColor(red: 0.035, green: 0.025, blue: 0.008, alpha: 0.94),
                inactive: gold.withAlphaComponent(0.27)
            )
        case .prismatic:
            let cyan = UIColor(red: 0.48, green: 0.94, blue: 1.0, alpha: 1.0)
            return PlayerSkinAppearance(
                primary: cyan,
                secondary: UIColor(red: 0.98, green: 0.39, blue: 0.84, alpha: 1.0),
                overlayBackground: UIColor(red: 0.045, green: 0.02, blue: 0.11, alpha: 0.55),
                centerButtonBackground: UIColor(red: 0.38, green: 0.18, blue: 0.58, alpha: 0.48),
                menuBackground: UIColor(red: 0.055, green: 0.025, blue: 0.12, alpha: 0.94),
                inactive: UIColor.white.withAlphaComponent(0.26)
            )
        case .cyberpunk:
            let cyan = UIColor(red: 0.10, green: 0.95, blue: 1.0, alpha: 1.0)
            return PlayerSkinAppearance(
                primary: cyan,
                secondary: UIColor(red: 1.0, green: 0.18, blue: 0.72, alpha: 1.0),
                overlayBackground: UIColor(red: 0.005, green: 0.018, blue: 0.07, alpha: 0.58),
                centerButtonBackground: UIColor(red: 0.05, green: 0.42, blue: 0.52, alpha: 0.42),
                menuBackground: UIColor(red: 0.01, green: 0.025, blue: 0.09, alpha: 0.95),
                inactive: cyan.withAlphaComponent(0.25)
            )
        case .custom:
            let primary = archivedSkinColor(
                forKey: MPVPlayerSkinSettings.customPrimaryColorKey,
                fallback: UIColor(red: 0.20, green: 0.86, blue: 1.0, alpha: 1.0)
            )
            let secondary = archivedSkinColor(
                forKey: MPVPlayerSkinSettings.customSecondaryColorKey,
                fallback: UIColor(red: 0.72, green: 0.31, blue: 1.0, alpha: 1.0)
            )
            return PlayerSkinAppearance(
                primary: primary,
                secondary: secondary,
                overlayBackground: secondary.withAlphaComponent(0.20),
                centerButtonBackground: primary.withAlphaComponent(0.30),
                menuBackground: UIColor.black.withAlphaComponent(0.90),
                inactive: primary.withAlphaComponent(0.25)
            )
        }
    }

    private func applyPlayerSkinIfNeeded(force: Bool = false) {
        let defaults = ProfileSettingsStore.active
        let selectedSkin = isMPVRenderer ? MPVPlayerSkinSettings.selected(defaults: defaults) : .defaultSkin
        let primaryDataHash = defaults.data(forKey: MPVPlayerSkinSettings.customPrimaryColorKey)?.hashValue ?? 0
        let secondaryDataHash = defaults.data(forKey: MPVPlayerSkinSettings.customSecondaryColorKey)?.hashValue ?? 0
        let animationsEnabled = MPVPlayerSkinSettings.animationsEnabled(defaults: defaults)
        let tintControlsOnly = selectedSkin != .defaultSkin && MPVPlayerSkinSettings.tintControlsOnly(defaults: defaults)
        let animationStyle = MPVPlayerSkinSettings.animationStyle(for: selectedSkin, defaults: defaults)
        let signature = "\(selectedSkin.rawValue)|\(primaryDataHash)|\(secondaryDataHash)|\(animationsEnabled)|\(tintControlsOnly)|\(animationStyle.rawValue)"
        guard force || signature != activePlayerSkinSignature else { return }

        activePlayerSkinSignature = signature
        activePlayerSkin = selectedSkin
        activePlayerSkinTintControlsOnly = tintControlsOnly
        activePlayerSkinAnimationsEnabled = animationsEnabled
        activePlayerSkinAnimationStyle = animationStyle
        activePlayerSkinAppearance = resolvedPlayerSkinAppearance(for: selectedSkin)
        let appearance = activePlayerSkinAppearance

        controlsOverlayView.backgroundColor = tintControlsOnly
            ? PlayerSkinAppearance.defaultAppearance.overlayBackground
            : appearance.overlayBackground
        centerPlayPauseButton.tintColor = appearance.primary
        centerPlayPauseButton.backgroundColor = appearance.centerButtonBackground
        centerPlayPauseButton.layer.shadowColor = appearance.primary.cgColor
        centerPlayPauseButton.layer.shadowOpacity = selectedSkin == .defaultSkin ? 0 : 0.38
        centerPlayPauseButton.layer.shadowRadius = selectedSkin == .defaultSkin ? 0 : 10
        centerPlayPauseButton.layer.shadowOffset = .zero

        var themedButtons = [
            closeButton, pipButton, skipBackwardButton, skipForwardButton,
            subtitleButton, servicesButton, episodeBrowserButton, speedButton, audioButton
        ]
#if os(iOS)
        themedButtons.append(playbackLockButton)
#endif
        for button in themedButtons {
            button.tintColor = appearance.primary
            if var configuration = button.configuration {
                configuration.baseForegroundColor = appearance.primary
                button.configuration = configuration
            }
        }
#if os(iOS)
        watchTogetherButton.tintColor = appearance.primary
#endif
#if !os(tvOS)
        if var configuration = skipButton.configuration {
            configuration.baseBackgroundColor = selectedSkin == .defaultSkin ? .systemYellow : appearance.secondary
            configuration.baseForegroundColor = .black
            skipButton.configuration = configuration
        }
        if var configuration = nextEpisodeButton.configuration {
            configuration.baseBackgroundColor = selectedSkin == .defaultSkin
                ? UIColor.white.withAlphaComponent(0.2)
                : appearance.primary.withAlphaComponent(0.22)
            configuration.baseForegroundColor = selectedSkin == .defaultSkin ? .white : appearance.primary
            nextEpisodeButton.configuration = configuration
        }
        if var configuration = skip85sButton.configuration {
            configuration.baseBackgroundColor = selectedSkin == .defaultSkin
                ? UIColor.white.withAlphaComponent(0.2)
                : appearance.secondary.withAlphaComponent(0.22)
            configuration.baseForegroundColor = selectedSkin == .defaultSkin ? .white : appearance.primary
            skip85sButton.configuration = configuration
        }
        brightnessSlider.minimumTrackTintColor = appearance.primary
        brightnessSlider.maximumTrackTintColor = appearance.inactive
        brightnessSlider.thumbTintColor = appearance.secondary
        brightnessIcon.tintColor = appearance.primary
        volumeSlider.minimumTrackTintColor = appearance.primary
        volumeSlider.maximumTrackTintColor = appearance.inactive
        volumeSlider.thumbTintColor = appearance.secondary
        volumeIcon.tintColor = appearance.primary
#endif
        playerTitleLabel.textColor = appearance.primary
        speedIndicatorLabel.textColor = appearance.primary
        speedIndicatorLabel.backgroundColor = selectedSkin == .defaultSkin
            ? UIColor(white: 0.2, alpha: 0.8)
            : appearance.secondary.withAlphaComponent(0.24)
        overlayMenuPanelView.backgroundColor = appearance.menuBackground
        overlayMenuPanelView.layer.borderColor = appearance.primary.withAlphaComponent(selectedSkin == .defaultSkin ? 0.12 : 0.22).cgColor
        overlayMenuTitleLabel.textColor = appearance.primary
        metalPerformanceOverlayLabel.textColor = appearance.primary

        configurePlayerSkinDecoration(animationsEnabled: animationsEnabled)
        if progressHostingController != nil {
            progressHostingController?.willMove(toParent: nil)
            progressHostingController?.view.removeFromSuperview()
            progressHostingController?.removeFromParent()
            progressHostingController = nil
            updateProgressHostingController()
        }
    }

    private func configurePlayerSkinDecoration(animationsEnabled: Bool) {
        let layer = playerSkinDecorationLayer
        layer.removeAllAnimations()
        layer.frame = controlsOverlayView.bounds
        layer.type = .axial
        layer.startPoint = CGPoint(x: 0, y: 0)
        layer.endPoint = CGPoint(x: 1, y: 1)
        layer.locations = [0, 0.5, 1]
        layer.isHidden = activePlayerSkin == .defaultSkin || activePlayerSkinTintControlsOnly

        if activePlayerSkin == .defaultSkin || activePlayerSkinTintControlsOnly {
            layer.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor]
            layer.opacity = 0
            return
        }

        let primary = activePlayerSkinAppearance.primary
        let secondary = activePlayerSkinAppearance.secondary
        let animate = animationsEnabled && !UIAccessibility.isReduceMotionEnabled
        switch activePlayerSkinAnimationStyle {
        case .glow:
            layer.colors = [UIColor.clear.cgColor, primary.withAlphaComponent(0.10).cgColor, UIColor.clear.cgColor]
            layer.opacity = 0.85
            if animate {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0.42
                pulse.toValue = 0.9
                pulse.duration = 2.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                layer.add(pulse, forKey: "skin.glow")
            }
        case .spectrum:
            let a = primary.withAlphaComponent(0.14).cgColor
            let b = UIColor(red: 0.50, green: 0.22, blue: 1.0, alpha: 0.13).cgColor
            let c = secondary.withAlphaComponent(0.15).cgColor
            layer.colors = [a, b, c]
            layer.opacity = 1
            if animate {
                let colors = CAKeyframeAnimation(keyPath: "colors")
                colors.values = [[a, b, c], [c, a, b], [b, c, a], [a, b, c]]
                colors.duration = 5.5
                colors.repeatCount = .infinity
                layer.add(colors, forKey: "skin.spectrum")
            }
        case .sweep:
            layer.startPoint = CGPoint(x: 0.5, y: 0)
            layer.endPoint = CGPoint(x: 0.5, y: 1)
            layer.colors = [
                UIColor.clear.cgColor,
                primary.withAlphaComponent(0.05).cgColor,
                primary.withAlphaComponent(0.22).cgColor,
                secondary.withAlphaComponent(0.16).cgColor,
                UIColor.clear.cgColor
            ]
            layer.locations = [-0.35, -0.18, 0, 0.18, 0.35]
            layer.opacity = 1
            if animate {
                let sweep = CABasicAnimation(keyPath: "locations")
                sweep.fromValue = [-0.35, -0.18, 0, 0.18, 0.35]
                sweep.toValue = [0.65, 0.82, 1.0, 1.18, 1.35]
                sweep.duration = 3.8
                sweep.repeatCount = .infinity
                sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(sweep, forKey: "skin.sweep")
            }
        case .aurora:
            layer.colors = [primary.withAlphaComponent(0.16).cgColor, UIColor.clear.cgColor, secondary.withAlphaComponent(0.16).cgColor]
            layer.opacity = 1
            if animate {
                let start = CAKeyframeAnimation(keyPath: "startPoint")
                start.values = [
                    NSValue(cgPoint: CGPoint(x: 0, y: 0)),
                    NSValue(cgPoint: CGPoint(x: 0.35, y: 0.2)),
                    NSValue(cgPoint: CGPoint(x: 0.1, y: 0.45)),
                    NSValue(cgPoint: CGPoint(x: 0, y: 0))
                ]
                start.duration = 7
                start.repeatCount = .infinity
                start.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(start, forKey: "skin.auroraStart")

                let end = CAKeyframeAnimation(keyPath: "endPoint")
                end.values = [
                    NSValue(cgPoint: CGPoint(x: 1, y: 1)),
                    NSValue(cgPoint: CGPoint(x: 0.65, y: 0.8)),
                    NSValue(cgPoint: CGPoint(x: 0.9, y: 0.55)),
                    NSValue(cgPoint: CGPoint(x: 1, y: 1))
                ]
                end.duration = 7
                end.repeatCount = .infinity
                end.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(end, forKey: "skin.auroraEnd")
            }
        }
    }

    private func refreshPlayerSkinDecorationAnimations() {
        guard isMPVRenderer,
              activePlayerSkin != .defaultSkin,
              !activePlayerSkinTintControlsOnly else { return }
        configurePlayerSkinDecoration(animationsEnabled: activePlayerSkinAnimationsEnabled)
    }

    private func setupLayout() {
        view.addSubview(videoContainer)

        displayLayer.frame = videoContainer.bounds

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
        } else if isSampleBufferMetalRenderer {

            displayLayer.isHidden = false
            displayLayer.opacity = 1.0
        } else {

            displayLayer.isHidden = true
            displayLayer.opacity = 0.0
            displayLayer.zPosition = -1
            videoContainer.layer.addSublayer(displayLayer)
        }

        if isMPVRenderer {
            let mpvView = renderer.getRenderingView()
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

        if let vlc = vlcRenderer {
            let vlcView = vlc.getRenderingView()
            videoContainer.addSubview(vlcView)
            vlcView.translatesAutoresizingMaskIntoConstraints = false
            vlcView.layer.zPosition = 0

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
        controlsOverlayView.layer.insertSublayer(playerSkinDecorationLayer, at: 0)
        videoContainer.addSubview(loadingIndicator)
        view.addSubview(errorBanner)
        view.addSubview(playerNoticeBanner)
        videoContainer.addSubview(centerPlayPauseButton)
        videoContainer.addSubview(progressContainer)
        videoContainer.addSubview(overlayMenuDismissView)
        videoContainer.addSubview(overlayMenuPanelView)
        overlayMenuPanelView.addSubview(overlayMenuTitleLabel)
        overlayMenuPanelView.addSubview(overlayMenuScrollView)
        overlayMenuScrollView.addSubview(overlayMenuStackView)
        videoContainer.addSubview(closeButton)
#if os(iOS)
        videoContainer.addSubview(playbackLockButton)
#endif
        videoContainer.addSubview(pipButton)
#if os(iOS)
        videoContainer.addSubview(watchTogetherButton)
#endif
        videoContainer.addSubview(playerTitleLabel)
        videoContainer.addSubview(skipBackwardButton)
        videoContainer.addSubview(skipForwardButton)
        videoContainer.addSubview(speedIndicatorLabel)
        videoContainer.addSubview(metalPerformanceOverlayLabel)
        videoContainer.addSubview(vlcSubtitleOverlayLabel)
        videoContainer.addSubview(subtitleButton)
        if supportsSharedPlayerControls {
            videoContainer.addSubview(servicesButton)
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

        let playerTitleCenterConstraint = playerTitleLabel.centerXAnchor.constraint(
            equalTo: videoContainer.centerXAnchor
        )
#if os(tvOS)
        playerTitleCenterConstraint.priority = .required
#else

        playerTitleCenterConstraint.priority = .defaultHigh
        self.playerTitleCenterConstraint = playerTitleCenterConstraint
#endif

#if os(iOS)
        NSLayoutConstraint.activate([
            playbackLockButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            playbackLockButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 16),
            playbackLockButton.widthAnchor.constraint(
                equalToConstant: PlayerPlaybackLockSettings.isEnabled() ? 36 : 0
            ),
            playbackLockButton.heightAnchor.constraint(equalToConstant: 36)
        ])
        let pipLeadingConstraint = pipButton.leadingAnchor.constraint(
            equalTo: playbackLockButton.trailingAnchor,
            constant: PlayerPlaybackLockSettings.isEnabled() ? 16 : 0
        )
#else
        let pipLeadingConstraint = pipButton.leadingAnchor.constraint(
            equalTo: closeButton.trailingAnchor,
            constant: 16
        )
#endif

        NSLayoutConstraint.activate([
            errorBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            errorBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorBanner.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.92),
            errorBanner.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),

            playerNoticeBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            playerNoticeBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playerNoticeBanner.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.78),
            playerNoticeBanner.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),

            centerPlayPauseButton.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            centerPlayPauseButton.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor),
            centerPlayPauseButton.widthAnchor.constraint(equalToConstant: 70),
            centerPlayPauseButton.heightAnchor.constraint(equalToConstant: 70),

            loadingIndicator.centerXAnchor.constraint(equalTo: centerPlayPauseButton.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerPlayPauseButton.centerYAnchor),
            loadingIndicator.widthAnchor.constraint(equalToConstant: 76),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 76),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor, constant: 4),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            pipButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            pipLeadingConstraint,
            pipButton.widthAnchor.constraint(equalToConstant: 36),
            pipButton.heightAnchor.constraint(equalToConstant: 36),

            playerTitleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            playerTitleCenterConstraint,
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

            metalPerformanceOverlayLabel.topAnchor.constraint(equalTo: videoContainer.safeAreaLayoutGuide.topAnchor, constant: 64),
            metalPerformanceOverlayLabel.trailingAnchor.constraint(equalTo: videoContainer.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            metalPerformanceOverlayLabel.widthAnchor.constraint(lessThanOrEqualTo: videoContainer.safeAreaLayoutGuide.widthAnchor, multiplier: 0.72),
            speedIndicatorLabel.widthAnchor.constraint(equalToConstant: 100),
            speedIndicatorLabel.heightAnchor.constraint(equalToConstant: 40),

            vlcSubtitleOverlayLabel.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor, constant: 12),
            vlcSubtitleOverlayLabel.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor, constant: -12),

            subtitleButton.bottomAnchor.constraint(equalTo: progressContainer.topAnchor, constant: -8),
            subtitleButton.widthAnchor.constraint(equalToConstant: 32),
            subtitleButton.heightAnchor.constraint(equalToConstant: 32)
        ])

        playerTitleLabel.leadingAnchor.constraint(
            greaterThanOrEqualTo: pipButton.trailingAnchor,
            constant: 12
        ).isActive = true

#if os(iOS)
        NSLayoutConstraint.activate([
            watchTogetherButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            watchTogetherButton.leadingAnchor.constraint(equalTo: pipButton.trailingAnchor, constant: 12),
            watchTogetherButton.widthAnchor.constraint(equalToConstant: 36),
            watchTogetherButton.heightAnchor.constraint(equalToConstant: 36),
            playerTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: watchTogetherButton.trailingAnchor, constant: 10)
        ])
#endif

        subtitleTrailingToProgressConstraint = subtitleButton.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor, constant: 0)
        subtitleTrailingToProgressConstraint?.isActive = true

        vlcSubtitleOverlayBottomConstraint = vlcSubtitleOverlayLabel.bottomAnchor.constraint(equalTo: progressContainer.topAnchor, constant: vlcSubtitleOverlayBottomConstant)
        vlcSubtitleOverlayBottomConstraint?.isActive = true
        if supportsSharedPlayerControls {
            subtitleTrailingToEpisodeBrowserConstraint = subtitleButton.trailingAnchor.constraint(equalTo: episodeBrowserButton.leadingAnchor, constant: -8)
            subtitleTrailingToServicesConstraint = subtitleButton.trailingAnchor.constraint(equalTo: servicesButton.leadingAnchor, constant: -8)
            episodeBrowserTrailingToProgressConstraint = episodeBrowserButton.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor)
            episodeBrowserTrailingToServicesConstraint = episodeBrowserButton.trailingAnchor.constraint(equalTo: servicesButton.leadingAnchor, constant: -8)
            NSLayoutConstraint.activate([
                servicesButton.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor, constant: 0),
                servicesButton.centerYAnchor.constraint(equalTo: subtitleButton.centerYAnchor),
                servicesButton.widthAnchor.constraint(equalToConstant: 32),
                servicesButton.heightAnchor.constraint(equalToConstant: 32),

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
            let nextEpisodeButtonMaxWidth = nextEpisodeButton.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
            nextEpisodeButtonMaxWidth.priority = .required
            nextEpisodeButtonMaxWidthConstraint = nextEpisodeButtonMaxWidth
            let nextEpisodeButtonBottom = nextEpisodeButton.bottomAnchor.constraint(equalTo: skipButton.topAnchor, constant: -10)
            nextEpisodeButtonBottomConstraint = nextEpisodeButtonBottom

            NSLayoutConstraint.activate([
                skipButton.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),
                skipButton.bottomAnchor.constraint(equalTo: subtitleButton.topAnchor, constant: -12),

                nextEpisodeButton.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),
                nextEpisodeButton.leadingAnchor.constraint(greaterThanOrEqualTo: videoContainer.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                nextEpisodeButtonBottom,
                nextEpisodeButtonMaxWidth,

                skip85sButton.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor),
                skip85sButton.bottomAnchor.constraint(equalTo: progressContainer.topAnchor, constant: -12),
            ])
        }
#endif

        if let vlc = vlcRenderer {
            let vlcView = vlc.getRenderingView()
            videoContainer.sendSubviewToBack(vlcView)

            vlcView.isUserInteractionEnabled = false
            #if !os(tvOS)
            vlcView.isExclusiveTouch = false
            #endif

            videoContainer.bringSubviewToFront(tapOverlayView)
        }
    }

    private var playerGestureSurfaceView: UIView {

        tapOverlayView
    }

    private func restorePlayerInteractionHierarchy() {
        mpvRenderingView?.isUserInteractionEnabled = false
        tapOverlayView.isHidden = false
        tapOverlayView.alpha = 1
        tapOverlayView.isUserInteractionEnabled = true
        videoContainer.bringSubviewToFront(tapOverlayView)
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

    private func updateMetalPerformanceOverlayVisibility() {
        let active = isMetalPerformanceOverlayActive
        metalPerformanceOverlayLabel.isHidden = !active
        metalPerformanceOverlayLabel.alpha = active ? 1.0 : 0.0
        if active {
            videoContainer.bringSubviewToFront(metalPerformanceOverlayLabel)
            refreshMetalPerformanceOverlay()
            startMetalPerformanceOverlayTimerIfNeeded()
        } else {
            stopMetalPerformanceOverlayTimer()
        }
    }

    private func startMetalPerformanceOverlayTimerIfNeeded() {
        guard metalPerformanceOverlayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshMetalPerformanceOverlay()
        }
        metalPerformanceOverlayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMetalPerformanceOverlayTimer() {
        metalPerformanceOverlayTimer?.invalidate()
        metalPerformanceOverlayTimer = nil
    }

    private func refreshMetalPerformanceOverlay() {
        guard isMetalPerformanceOverlayActive else {
            stopMetalPerformanceOverlayTimer()
            return
        }
        metalPerformanceOverlayLabel.attributedText = metalPerformanceOverlayText()
        videoContainer.bringSubviewToFront(metalPerformanceOverlayLabel)
    }

    private func metalPerformanceOverlayText() -> NSAttributedString {
        let cpuText = processCPUUsagePercent().map { String(format: "%.0f%%", $0) } ?? "n/a"
        let ramText = processMemoryFootprintBytes().map { String(format: "%.0f MB", Double($0) / 1_048_576.0) } ?? "n/a"
        let thermalState = ProcessInfo.processInfo.thermalState
        let text = NSMutableAttributedString()
        text.append(metalPerformanceOverlayRow(label: "CPU", value: cpuText, valueColor: .white))
        text.append(NSAttributedString(string: "\n"))
        text.append(metalPerformanceOverlayRow(label: "RAM", value: ramText, valueColor: .white))
        text.append(NSAttributedString(string: "\n"))
        text.append(metalPerformanceOverlayRow(
            label: "Thermal",
            value: metalPerformanceThermalName(thermalState),
            valueColor: metalPerformanceThermalColor(thermalState)
        ))
        text.append(NSAttributedString(string: "\n"))
        text.append(metalPerformanceOverlayRow(
            label: "Quality",
            value: metalPerformanceQualityText(),
            valueColor: metalPerformanceQualityColor()
        ))

        if let upscaling = metalPerformanceUpscalingStatus() {
            let upscalingColor: UIColor
            if upscaling.isThermallyLimited {
                upscalingColor = .systemOrange
            } else if upscaling.isActive {
                upscalingColor = .systemGreen
            } else {
                upscalingColor = .white
            }
            text.append(NSAttributedString(string: "\n"))
            text.append(metalPerformanceOverlayRow(label: "Upscale", value: upscaling.summary, valueColor: upscalingColor))
        }

        if let neural = metalPerformanceNeuralUpscalerStatus() {
            text.append(NSAttributedString(string: "\n"))
            text.append(metalPerformanceOverlayRow(
                label: "Upscale FX",
                value: neural.summary,
                valueColor: neural.isEngaged ? .systemGreen : .systemOrange
            ))
        }

        if let streamName = playbackLaunchContext?.streamName?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines), !streamName.isEmpty {
            let clipped = streamName.count > 52 ? String(streamName.prefix(51)) + "…" : streamName
            text.append(NSAttributedString(string: "\n"))
            text.append(metalPerformanceOverlayRow(label: "Stream", value: clipped, valueColor: .white))
        }

        #if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        if let diag = metalPerformanceDiagnostics() {
            text.append(NSAttributedString(string: "\n"))
            text.append(metalPerformanceOverlayRow(
                label: "PiP",
                value: diag.pictureInPictureBackingText,
                valueColor: diag.pictureInPictureBackingText.hasPrefix("GPU-backed") ? .systemGreen : .white
            ))

            var videoValue = "\(Int(diag.renderSize.width))x\(Int(diag.renderSize.height))  \(diag.dynamicRangeText)"
            if diag.highBitDepthActive { videoValue += "  16-bit" }
            text.append(NSAttributedString(string: "\n"))
            text.append(metalPerformanceOverlayRow(label: "Video", value: videoValue, valueColor: diag.isHDR ? .systemOrange : .white))

            if let rawDecoder = diag.hardwareDecoder {
                let decoder = rawDecoder.trimmingCharacters(in: .whitespacesAndNewlines)
                let decoderValue: String
                let decoderColor: UIColor
                if decoder.isEmpty {
                    decoderValue = "Reconfiguring"
                    decoderColor = .systemYellow
                } else if decoder.caseInsensitiveCompare("no") == .orderedSame {
                    decoderValue = "Software"
                    decoderColor = .systemOrange
                } else if decoder.lowercased().contains("videotoolbox") {
                    decoderValue = "VideoToolbox"
                    decoderColor = .systemGreen
                } else {
                    decoderValue = decoder
                    decoderColor = .systemGreen
                }
                text.append(NSAttributedString(string: "\n"))
                text.append(metalPerformanceOverlayRow(label: "Decode", value: decoderValue, valueColor: decoderColor))
            }

            let subValue = diag.subtitleCodec ?? "off"
            text.append(NSAttributedString(string: "\n"))
            text.append(metalPerformanceOverlayRow(label: "Subs", value: subValue, valueColor: diag.subtitleCodec == "ass" ? .systemYellow : .white))
        }
        #endif

        return text
    }

    private func metalPerformanceOverlayRow(label: String, value: String, valueColor: UIColor) -> NSAttributedString {
        let row = NSMutableAttributedString(
            string: label + "  ",
            attributes: [
                .foregroundColor: UIColor.white.withAlphaComponent(0.55),
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
            ]
        )
        row.append(NSAttributedString(
            string: value,
            attributes: [
                .foregroundColor: valueColor,
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            ]
        ))
        return row
    }

    private func metalPerformanceThermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func metalPerformanceThermalColor(_ state: ProcessInfo.ThermalState) -> UIColor {
        switch state {
        case .nominal: return .systemGreen
        case .fair: return .systemYellow
        case .serious: return .systemOrange
        case .critical: return .systemRed
        @unknown default: return .white
        }
    }

    private func metalPerformanceQualityText() -> String {
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        let active = metalMPVRenderer?.activeQualityProfileName ?? gpuMPVRenderer?.activeQualityProfileName ?? "-"

        return Settings.shared.mpvMetalQualityProfile == .auto ? "\(active) · Auto" : active
#else
        return "-"
#endif
    }

    private func metalPerformanceUpscalingStatus() -> MPVUpscalingStatus? {
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        if let gpuMPVRenderer {
            return gpuMPVRenderer.activeUpscalingStatus
        }
        if metalMPVRenderer != nil {
            return MPVUpscalingStatus(isActive: false, isThermallyLimited: false, summary: "Off · legacy renderer")
        }
        return nil
#else
        return nil
#endif
    }

    private func metalPerformanceNeuralUpscalerStatus() -> MPVNeuralUpscalerStatus? {
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        return gpuMPVRenderer?.activeNeuralUpscalerStatus
#else
        return nil
#endif
    }

    private func metalPerformanceQualityColor() -> UIColor {
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        switch metalMPVRenderer?.activeQualityProfileName ?? gpuMPVRenderer?.activeQualityProfileName {
        case "Sharp": return .systemGreen
        case "Balanced": return .systemYellow
        case "Low Heat": return .systemOrange
        default: return .white
        }
#else
        return .white
#endif
    }

    #if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
    private func metalPerformanceDiagnostics() -> MetalPlaybackDiagnostics? {
        return metalMPVRenderer?.currentPlaybackDiagnostics() ?? gpuMPVRenderer?.currentPlaybackDiagnostics()
    }
    #endif

    private func applyInteractiveRenderThrottle() {
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        metalMPVRenderer?.setInteractiveRenderThrottle(controlsVisible)
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

    private func processMemoryFootprintBytes() -> UInt64? {
#if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), integerPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
#else
        return nil
#endif
    }

    private func gpuUsagePercent() -> Double? {
        gpuUsageSampler?.sample()
    }

    final class GPUUsageSampler {
        private typealias CopyChannelsInGroup = @convention(c)
            (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
        private typealias CreateSubscription = @convention(c)
            (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
        private typealias CreateSamples = @convention(c)
            (AnyObject?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
        private typealias CreateSamplesDelta = @convention(c)
            (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
        private typealias StateGetCount = @convention(c) (CFDictionary) -> Int32
        private typealias StateGetNameForIndex = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
        private typealias StateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64
        private typealias IterateBlock = @convention(block) (CFDictionary) -> Int32
        private typealias Iterate = @convention(c) (CFDictionary, IterateBlock) -> Void

        private let createSamples: CreateSamples
        private let createSamplesDelta: CreateSamplesDelta
        private let stateGetCount: StateGetCount
        private let stateGetNameForIndex: StateGetNameForIndex
        private let stateGetResidency: StateGetResidency
        private let iterate: Iterate
        private let subscription: AnyObject
        private let subscribedChannels: CFMutableDictionary
        private var previousSample: CFDictionary?
        private var lastValue: Double?

        init?() {
            guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
            func sym<T>(_ name: String, _ type: T.Type) -> T? {
                guard let ptr = dlsym(lib, name) else { return nil }
                return unsafeBitCast(ptr, to: T.self)
            }
            guard
                let copyChannels = sym("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
                let createSub = sym("IOReportCreateSubscription", CreateSubscription.self),
                let samples = sym("IOReportCreateSamples", CreateSamples.self),
                let delta = sym("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
                let getCount = sym("IOReportStateGetCount", StateGetCount.self),
                let getName = sym("IOReportStateGetNameForIndex", StateGetNameForIndex.self),
                let getResidency = sym("IOReportStateGetResidency", StateGetResidency.self),
                let iter = sym("IOReportIterate", Iterate.self)
            else { return nil }

            guard let channels = copyChannels("GPU Stats" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return nil }
            var subbed: Unmanaged<CFMutableDictionary>?

            guard let sub = createSub(nil, channels, &subbed, 0, nil)?.takeRetainedValue(),
                  let subbedChannels = subbed?.takeUnretainedValue() else { return nil }

            self.createSamples = samples
            self.createSamplesDelta = delta
            self.stateGetCount = getCount
            self.stateGetNameForIndex = getName
            self.stateGetResidency = getResidency
            self.iterate = iter
            self.subscription = sub
            self.subscribedChannels = subbedChannels
        }

        func sample() -> Double? {
            guard let now = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue() else {
                return lastValue
            }
            defer { previousSample = now }
            guard let previous = previousSample,
                  let delta = createSamplesDelta(previous, now, nil)?.takeRetainedValue() else {
                return nil
            }

            var busy: Double = 0
            var idle: Double = 0
            iterate(delta) { [weak self] channel in
                guard let self else { return 0 }
                let count = self.stateGetCount(channel)
                guard count > 0 else { return 0 }
                var busyLocal: Double = 0
                var idleLocal: Double = 0
                var sawIdle = false
                for index in 0..<count {
                    let residency = Double(self.stateGetResidency(channel, index))
                    if residency < 0 { continue }
                    let nameCF = self.stateGetNameForIndex(channel, index)?.takeUnretainedValue()
                    let name = (nameCF.map { $0 as String } ?? "").uppercased()
                    if name.contains("IDLE") || name.contains("OFF") || name.contains("DOWN") {
                        idleLocal += residency
                        sawIdle = true
                    } else {
                        busyLocal += residency
                    }
                }

                if sawIdle {
                    busy += busyLocal
                    idle += idleLocal
                }
                return 0
            }

            let total = busy + idle
            guard total > 0 else { return lastValue }
            let percent = min(max(busy / total * 100.0, 0), 100)
            lastValue = percent
            return percent
        }
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
#if os(iOS)
        playbackLockButton.addTarget(self, action: #selector(playbackLockTapped), for: .touchUpInside)
#endif
        pipButton.addTarget(self, action: #selector(pipTouchDown), for: .touchDown)
        pipButton.addTarget(self, action: #selector(pipTapped), for: .touchUpInside)
#if os(iOS)
        watchTogetherButton.addTarget(self, action: #selector(watchTogetherTapped), for: .touchUpInside)
#endif
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
            subtitleButton.addTarget(self, action: #selector(playerMenuButtonTouchDown(_:)), for: .touchDown)
            servicesButton.addTarget(self, action: #selector(servicesButtonTapped), for: .touchUpInside)
            episodeBrowserButton.addTarget(self, action: #selector(episodeBrowserButtonTapped), for: .touchUpInside)
            speedButton.addTarget(self, action: #selector(speedButtonTapped), for: .touchUpInside)
            speedButton.addTarget(self, action: #selector(playerMenuButtonTouchDown(_:)), for: .touchDown)
            audioButton.addTarget(self, action: #selector(audioButtonTapped), for: .touchUpInside)
            audioButton.addTarget(self, action: #selector(playerMenuButtonTouchDown(_:)), for: .touchDown)
            if #available(iOS 14.0, tvOS 14.0, *) {
                subtitleButton.addTarget(self, action: #selector(playerMenuButtonTouchDown(_:)), for: .menuActionTriggered)
                speedButton.addTarget(self, action: #selector(playerMenuButtonTouchDown(_:)), for: .menuActionTriggered)
                audioButton.addTarget(self, action: #selector(playerMenuButtonTouchDown(_:)), for: .menuActionTriggered)
            }
        }

        if supportsSharedPlayerControls {
            [centerPlayPauseButton, closeButton, pipButton, skipBackwardButton,
             skipForwardButton, subtitleButton, servicesButton, episodeBrowserButton, speedButton, audioButton].forEach {
                $0.isUserInteractionEnabled = true
            }
#if os(iOS)
            playbackLockButton.isUserInteractionEnabled = true
            watchTogetherButton.isUserInteractionEnabled = true
#endif
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(containerTapped(_:)))
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

        #if !os(tvOS)
        if isTwoFingerTapEnabled {
            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped))
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.delegate = self
            playerGestureSurfaceView.addGestureRecognizer(twoFingerTap)

            containerTapGesture?.require(toFail: twoFingerTap)
        }
        #endif
    }

    @objc private func leftSideDoubleTapped(_ gesture: UITapGestureRecognizer) {
        guard isDoubleTapSeekEnabled else { return }
        let location = gesture.location(in: videoContainer)
        let isLeftSide = location.x < videoContainer.bounds.width / 2
        guard isLeftSide else { return }
        pendingContainerTapWorkItem?.cancel()
        logSharedPlayerControl("left double-tap seek by -\(String(format: "%.1f", playerSeekSeconds))")
        rendererSeek(by: -playerSeekSeconds)
#if os(iOS)
        WatchTogetherCoordinator.shared.sendUserSeek(to: max(0, cachedPosition - playerSeekSeconds), from: self)
#endif
        animateButtonTap(skipBackwardButton)
    }

    @objc private func rightSideDoubleTapped(_ gesture: UITapGestureRecognizer) {
        guard isDoubleTapSeekEnabled else { return }
        let location = gesture.location(in: videoContainer)
        let isRightSide = location.x >= videoContainer.bounds.width / 2
        guard isRightSide else { return }
        pendingContainerTapWorkItem?.cancel()
        logSharedPlayerControl("right double-tap seek by \(String(format: "%.1f", playerSeekSeconds))")
        rendererSeek(by: playerSeekSeconds)
#if os(iOS)
        WatchTogetherCoordinator.shared.sendUserSeek(to: watchTogetherClampedPosition(cachedPosition + playerSeekSeconds), from: self)
#endif
        animateButtonTap(skipForwardButton)
    }

    @objc private func twoFingerTapped(_ gesture: UITapGestureRecognizer) {

        togglePlaybackFromVideoGesture(source: "two-finger-tap")
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
        let current = Float(UIScreen.main.brightness)
        brightnessLevel = max(0.0, min(current, 1.0))
        brightnessSlider.value = brightnessLevel
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
        let store = ProfileSettingsStore.active
        let savedSpeed = store.double(forKey: "holdSpeedPlayer")
        let targetSpeed = PlayerSettingsStore.sanitizedNumericSetting(
            savedSpeed,
            default: 2,
            range: 0.1...3
        )
        if savedSpeed != targetSpeed {
            store.set(targetSpeed, forKey: "holdSpeedPlayer")
        }
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
        rendererSetSpeed(speed, notifyWatchTogether: false)
        defaultPlaybackSpeedApplied = true
        updateSpeedMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.updateSpeedMenu()
        }
    }

    @objc private func playPauseTapped() {
        if rendererIsPausedState() {
            markBackgroundRecoveryForegrounded(source: "play-button")
            rendererPlay()
            updatePlayPauseButton(isPaused: false)
#if os(iOS)
            WatchTogetherCoordinator.shared.sendUserPlay(from: self)
#endif
        } else {
            rendererPausePlayback()
            updatePlayPauseButton(isPaused: true)
#if os(iOS)
            WatchTogetherCoordinator.shared.sendUserPause(from: self)
#endif
        }
    }

    @objc private func centerPlayPauseTapped() {
        logSharedPlayerControl("center play/pause tapped paused=\(rendererIsPausedState()) loading=\(isRendererLoading) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))")
        playPauseTapped()
    }

    @objc private func skipBackwardTapped() {
        let seconds = playerSeekSeconds
        logSharedPlayerControl("skip backward button tapped seek=\(String(format: "%.1f", seconds))")
        rendererSeek(by: -seconds)
#if os(iOS)
        WatchTogetherCoordinator.shared.sendUserSeek(to: max(0, cachedPosition - seconds), from: self)
#endif
        animateButtonTap(skipBackwardButton)
        showControlsTemporarily()
    }

    @objc private func skipForwardTapped() {
        let seconds = playerSeekSeconds
        logSharedPlayerControl("skip forward button tapped seek=\(String(format: "%.1f", seconds))")
        rendererSeek(by: seconds)
#if os(iOS)
        WatchTogetherCoordinator.shared.sendUserSeek(to: watchTogetherClampedPosition(cachedPosition + seconds), from: self)
#endif
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
            guard let self else { return }
            self.setSessionAwareSubtitleVisible(false)
            self.userSelectedSubtitleTrack = true
            self.recordUserSubtitleSelection(enabled: false)
            self.rendererDisableSubtitles()
            self.subtitleEntries.removeAll()
            self.vlcSubtitleSelection = .none
            self.updateSubtitleButtonAppearance()
            self.updateSubtitleMenu()
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
                guard let self else { return }
                self.currentSubtitleIndex = index
                self.setSessionAwareSubtitleVisible(true)
                self.userSelectedSubtitleTrack = true
                self.recordUserSubtitleSelection(enabled: true, displayName: title)
                self.vlcSubtitleSelection = .external(index: index)
                self.loadCurrentSubtitle()
                self.rendererApplySubtitleStyle(self.currentSubtitleStyle(visible: true))
                self.updateSubtitleButtonAppearance()
                self.updateSubtitleMenu()
            }
            trackActions.append(action)
        }

        let trackMenu = UIMenu(title: "Select Track", image: UIImage(systemName: "list.bullet"), children: trackActions)

        let appearanceMenu = createAppearanceMenu()

        let mainMenu = UIMenu(title: "Subtitles", children: [trackMenu, appearanceMenu])
        nativeSubtitleMenuContentSignature = nil
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
                self?.scheduleSubtitleMenuRefresh()
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
                self?.scheduleSubtitleMenuRefresh()
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
                self?.scheduleSubtitleMenuRefresh()
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
                self?.scheduleSubtitleMenuRefresh()
            }
        }

        let fontSizeMenu = UIMenu(title: "Font Size", image: UIImage(systemName: "textformat.size"), children: fontSizeActions)

        let verticalOffsets: [(String, CGFloat)] = [
            ("Highest", -24.0),
            ("Higher", -16.0),
            ("Default", -6.0),
            ("Lower", 6.0),
            ("Lowest", 18.0)
        ]

        let verticalOffsetActions = verticalOffsets.map { (name, offset) in
            UIAction(
                title: name,
                state: abs(subtitleModel.verticalOffset - offset) < 0.01 ? .on : .off
            ) { [weak self] _ in
                self?.subtitleModel.verticalOffset = offset
                self?.updateCurrentSubtitleAppearance()
                self?.scheduleSubtitleMenuRefresh()
            }
        }

        let verticalOffsetMenu = UIMenu(title: "Vertical Position", image: UIImage(systemName: "arrow.up.and.down"), children: verticalOffsetActions)

        let closedCaptionBackgroundAction = UIAction(
            title: "Caption Background",
            image: UIImage(systemName: "rectangle.fill"),
            state: subtitleModel.closedCaptionBackground ? .on : .off
        ) { [weak self] _ in
            self?.subtitleModel.closedCaptionBackground.toggle()
            self?.updateCurrentSubtitleAppearance()
            self?.scheduleSubtitleMenuRefresh()
        }
        let closedCaptionBackgroundMenu = UIMenu(title: "", options: .displayInline, children: [closedCaptionBackgroundAction])

        return UIMenu(title: "Appearance", image: UIImage(systemName: "paintbrush"), children: [
            foregroundColorMenu,
            strokeColorMenu,
            strokeWidthMenu,
            fontSizeMenu,
            verticalOffsetMenu,
            closedCaptionBackgroundMenu
        ])
    }

    private func updateCurrentSubtitleAppearance() {

        rendererApplySubtitleStyle(currentSubtitleStyle())

        guard isVLCCustomSubtitleOverlayEnabled else { return }
        applyVLCSubtitleOverlayPositionSetting()
        updateVLCSubtitleOverlay(for: cachedPosition)
        if subtitleModel.isVisible && currentSubtitleIndex < subtitleURLs.count {
            loadCurrentSubtitle()
        }
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

    private var subtitleMenuRefreshWorkItem: DispatchWorkItem?

    private func scheduleSubtitleMenuRefresh() {
        subtitleMenuRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.subtitleMenuRefreshWorkItem = nil
            self?.refreshActiveSubtitleMenu()
        }
        subtitleMenuRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
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
        if ProfileSettingsStore.active.object(forKey: "showEpisodeBrowserButton") == nil {
            let legacy = ProfileSettingsStore.active.object(forKey: "showVLCEpisodeBrowserButton") as? Bool ?? true
            ProfileSettingsStore.active.set(legacy, forKey: "showEpisodeBrowserButton")
            return legacy
        }
        return ProfileSettingsStore.active.bool(forKey: "showEpisodeBrowserButton")
    }

    private func updateEpisodeBrowserButtonVisibility() {
        let shouldShowEpisodeBrowser: Bool
        if supportsSharedPlayerControls,
           isVLCEpisodeBrowserButtonSettingEnabled,
           case .episode = mediaInfo {
            shouldShowEpisodeBrowser = true
        } else {
            shouldShowEpisodeBrowser = false
        }

        let shouldShowServices = supportsSharedPlayerControls
            && PlayerServicesButtonSettings.isEnabled()
            && servicesSelectionContext != nil

        episodeBrowserButton.isHidden = !shouldShowEpisodeBrowser
        servicesButton.isHidden = !shouldShowServices
        if !shouldShowEpisodeBrowser {
            episodeBrowserButton.alpha = 0.0
            if isEpisodeBrowserVisible {
                dismissEpisodeBrowser(animated: true, reason: "button-visibility-hidden")
            }
        } else if controlsVisible {
            episodeBrowserButton.alpha = 1.0
        }
        servicesButton.alpha = shouldShowServices && controlsVisible ? 1.0 : 0.0

        subtitleTrailingToProgressConstraint?.isActive = false
        subtitleTrailingToEpisodeBrowserConstraint?.isActive = false
        subtitleTrailingToServicesConstraint?.isActive = false
        episodeBrowserTrailingToProgressConstraint?.isActive = false
        episodeBrowserTrailingToServicesConstraint?.isActive = false
        if shouldShowEpisodeBrowser {
            if shouldShowServices {
                episodeBrowserTrailingToServicesConstraint?.isActive = true
            } else {
                episodeBrowserTrailingToProgressConstraint?.isActive = true
            }
            subtitleTrailingToEpisodeBrowserConstraint?.isActive = true
        } else if shouldShowServices {
            subtitleTrailingToServicesConstraint?.isActive = true
        } else {
            subtitleTrailingToProgressConstraint?.isActive = true
        }
    }

    @objc private func servicesButtonTapped() {
        guard PlayerServicesButtonSettings.isEnabled(),
              let context = servicesSelectionContext,
              presentedViewController == nil,
              !isClosing else {
            showControlsTemporarily()
            return
        }

        controlsHideWorkItem?.cancel()
        let sheet = ModulesSearchResultsSheet(
            mediaTitle: context.mediaTitle,
            seasonTitleOverride: context.seasonTitleOverride,
            originalTitle: context.originalTitle,
            isMovie: context.isMovie,
            isAnimeContent: context.isAnime,
            selectedEpisode: context.selectedEpisode,
            tmdbId: context.tmdbID,
            mediaYear: context.mediaYear,
            animeSeasonTitle: context.animeSeasonTitle,
            posterPath: context.posterPath,
            originalAudioLanguage: context.originalAudioLanguage,
            imdbId: context.imdbID,
            originalTMDBSeasonNumber: context.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: context.originalTMDBEpisodeNumber,
            specialTitleOnlySearch: context.specialTitleOnlySearch,
            episodePlaybackContext: context.episodePlaybackContext,

            autoModeOnly: false,
            ignoresAutoMode: true,
            onResolvedPlaybackRequest: { [weak self] request in
                guard let self else {
                    Self.invalidateAbandonedProxyOwnership(request)
                    return
                }
                self.replacePlayback(with: request, reason: "player-services")
            },
            isAnimationGenre16: context.isAnimation
        )
        let host = UIHostingController(rootView: sheet.profileScopedAppStorage())
        episodeSourceSheetController = host
        episodeSourceSheetTransitionID = nil
        present(host, animated: true) { [weak self, weak host] in
            guard let self, let host else { return }
            host.presentationController?.delegate = self
        }
    }

    @objc private func episodeBrowserButtonTapped() {
        guard let seed = makeEpisodeBrowserSeed() else {
            logVLCUIViewSnapshot("episodeBrowser tap seed unavailable")
            return
        }
        if isEpisodeBrowserVisible {
            dismissEpisodeBrowser(animated: true, reason: "button-toggle")
            return
        }
        showEpisodeBrowser(seed: seed, reason: "button-tap")
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
            currentPlaybackContext: episodePlaybackContext,
            mediaYear: servicesSelectionContext?.mediaYear
        )
    }

    private func showEpisodeBrowser(seed: PlayerEpisodeBrowserSeed, reason: String = "unspecified") {
        logVLCUIViewSnapshot("episodeBrowser show requested")
        controlsHideWorkItem?.cancel()
        isEpisodeBrowserVisible = true
        let drawer = PlayerEpisodeBrowserDrawer(
            seed: seed,
            onClose: { [weak self] in
                guard let self else { return }
                self.dismissEpisodeBrowser(animated: true, reason: "drawer-close")
            },
            onEpisodeSelected: { [weak self] item in
                self?.beginEpisodeBrowserSelection(item)
            }
        )
        let host = UIHostingController(rootView: AnyView(drawer.profileScopedAppStorage()))
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
        logVLCUIViewSnapshot("episodeBrowser shown")
        scheduleVLCUIViewSnapshots("episodeBrowser shown followup", delays: [0.10, 0.50, 1.00])
    }

    private func dismissEpisodeBrowser(animated: Bool, reason: String = "unspecified") {
        guard let host = episodeBrowserHostingController else {
            isEpisodeBrowserVisible = false
            logVLCUIViewSnapshot("episodeBrowser dismiss no host")
            return
        }
        logVLCUIViewSnapshot("episodeBrowser dismiss requested")
        isEpisodeBrowserVisible = false
        let removeHost = {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            self.logVLCUIViewSnapshot("episodeBrowser dismiss removed")
            self.scheduleVLCUIViewSnapshots("episodeBrowser dismiss followup", delays: [0.10, 0.50])
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

    private func beginEpisodeBrowserSelection(_ item: PlayerEpisodeBrowserItem) {
        guard !item.isCurrent else { return }
#if os(iOS)
        if case .active = watchTogetherConnectionState {
            guard pendingWatchTogetherNextEpisodeTarget == nil else { return }
            if item.isAnime, item.playbackContext?.hasAnimeMediaId != true {
                showPlayerNotice("Watch Together needs this episode's exact anime identity. Open it from the show page so everyone can move together.")
                return
            }
            let transitionID = UUID()
            pendingWatchTogetherNextEpisodeTransitionID = transitionID
            pendingWatchTogetherNextEpisodeTarget = NextEpisodePlaybackTarget(
                seasonNumber: item.episode.seasonNumber,
                episodeNumber: item.episode.episodeNumber,
                playbackContext: item.playbackContext,
                title: item.seasonTitleOverride ?? item.mediaTitle
            )
            handleEpisodeBrowserSelection(
                item,
                reason: "episode-browser-watch-together",
                watchTogetherTransitionID: transitionID
            )
            return
        }
#endif
        handleEpisodeBrowserSelection(item)
    }

    private func handleEpisodeBrowserSelection(
        _ item: PlayerEpisodeBrowserItem,
        reason: String = "episode-browser",
        watchTogetherTransitionID: UUID? = nil
    ) {
        guard !item.isCurrent else {
            return
        }

        #if !os(tvOS)

        if ProfileSettingsStore.active.bool(forKey: "preferDownloadedMedia")
            || initialURL?.isFileURL == true,
           let request = downloadedPlaybackRequest(for: item) {
            guard commitPendingWatchTogetherNextEpisodeIfNeeded(
                transitionID: watchTogetherTransitionID
            ) else { return }
            dismissEpisodeBrowser(animated: true, reason: "\(reason)-downloaded-selection")
            replacePlayback(with: request, reason: "\(reason)-downloaded")
            return
        }
        #endif

        presentEpisodeSourceSheet(
            for: item,
            reason: reason,
            watchTogetherTransitionID: watchTogetherTransitionID
        )
    }

    #if !os(tvOS)
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
            mediaInfo: .episode(
                showId: item.showId,
                seasonNumber: item.episode.seasonNumber,
                episodeNumber: item.episode.episodeNumber,
                showTitle: item.showTitle,
                showPosterURL: item.showPosterURL,
                isAnime: item.isAnime
            ),
            imdbId: item.imdbId,
            isAnimeHint: downloadItem.isAnime || item.isAnime,
            isAnimationContentHint: nil,
            originalTMDBSeasonNumber: item.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: item.originalTMDBEpisodeNumber,
            episodePlaybackContext: item.playbackContext ?? downloadItem.episodePlaybackContext,
            launchContext: nil,
            mediaYear: item.mediaYear
        )
    }
    #endif

    private func presentEpisodeSourceSheet(
        for item: PlayerEpisodeBrowserItem,
        reason: String = "episode-browser",
        watchTogetherTransitionID: UUID? = nil
    ) {
        guard presentedViewController == nil else {
            clearPendingWatchTogetherNextEpisodeTarget(
                transitionID: watchTogetherTransitionID
            )
            return
        }
        let sheet = ModulesSearchResultsSheet(
            mediaTitle: item.mediaTitle,
            seasonTitleOverride: item.seasonTitleOverride,
            originalTitle: item.originalTitle,
            isMovie: false,
            isAnimeContent: item.isAnime,
            selectedEpisode: item.episode,
            tmdbId: item.showId,
            mediaYear: item.mediaYear,
            animeSeasonTitle: item.animeSeasonTitle,
            posterPath: item.posterURL ?? item.showPosterURL,
            originalAudioLanguage: item.originalAudioLanguage,
            imdbId: item.imdbId,
            originalTMDBSeasonNumber: item.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: item.originalTMDBEpisodeNumber,
            specialTitleOnlySearch: item.playbackContext?.titleOnlySearch ?? false,
            episodePlaybackContext: item.playbackContext,
            autoModeOnly: watchTogetherTransitionID != nil
                || AutoModeSettings.isEnabled(),
            watchTogetherExactHandoff: watchTogetherTransitionID != nil,
            onResolvedPlaybackRequest: { [weak self] request in
                guard let self,
                      self.commitPendingWatchTogetherNextEpisodeIfNeeded(
                        transitionID: watchTogetherTransitionID
                      ) else {
                    Self.invalidateAbandonedProxyOwnership(request)
                    return
                }
                self.replacePlayback(with: request, reason: "\(reason)-resolved-source")
            },

            isAnimationGenre16: isAnimationContentHint ?? false
        )
        let host = UIHostingController(rootView: sheet.onDisappear { [weak self] in
            self?.schedulePendingWatchTogetherNextEpisodeCleanup(
                transitionID: watchTogetherTransitionID
            )
        }.profileScopedAppStorage())
#if os(iOS)
        episodeSourceSheetController = host
        episodeSourceSheetTransitionID = watchTogetherTransitionID
        host.presentationController?.delegate = self
#endif
        present(host, animated: true) { [weak self, weak host] in
#if os(iOS)
            guard let self, let host else { return }
            host.presentationController?.delegate = self
#endif
        }
    }

    private static func hasSameMediaIdentity(_ lhs: MediaInfo?, _ rhs: MediaInfo?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.movie(leftID, _, _, _), .movie(rightID, _, _, _)):
            return leftID == rightID
        case let (
            .episode(leftShowID, leftSeason, leftEpisode, _, _, _),
            .episode(rightShowID, rightSeason, rightEpisode, _, _, _)
        ):
            return leftShowID == rightShowID
                && leftSeason == rightSeason
                && leftEpisode == rightEpisode
        default:
            return false
        }
    }

    private func replacePlayback(
        with request: PlayerResolvedPlaybackRequest,
        reason: String = "episode-browser",
        castReplacementAlreadyLoaded: Bool = false,
        castReplacementTransactionID: UUID? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosing else {
                Self.invalidateAbandonedProxyOwnership(request)
                return
            }

            self.retainEphemeralProxyOwnership(
                request.launchContext?.ephemeralProxyOwnership
            )

            self.onAutomaticPlaybackFallback = nil
            self.isCoordinatorEngineFallback = false
            self.pendingRendererRestartRetryGeneration = nil
            self.playbackReplacementGeneration += 1
            let replacementGeneration = self.playbackReplacementGeneration
            let wasVLC = self.isVLCPlayer
            if let mediaInfo = self.mediaInfo {
                self.syncTraktProgressOnPlaybackCloseIfNeeded(for: mediaInfo, reason: "replace-playback")
            }
            self.dismissEpisodeBrowser(animated: true, reason: "\(reason)-replace-playback")
            self.controlsHideWorkItem?.cancel()
            self.playbackStartupWorkItem?.cancel()
            self.playbackDidStart = false
            self.refreshIdleTimerForPlayback(reason: "replace-playback-reset")
            self.playbackFailureHandled = false
            self.playbackSlowProbeCount = 0
            self.vlcProxyFallbackTried = false
            self.didDispatchNextEpisodeRequest = false
            self.pendingNextEpisodeRequest = nil
            self.pendingResolvedNextEpisodeRequest = nil
            self.localNextEpisodeFallback = nil
            self.pendingWatchTogetherNextEpisodeTarget = nil
            self.pendingWatchTogetherNextEpisodeTransitionID = nil
#if os(iOS)
            self.episodeSourceSheetController = nil
            self.episodeSourceSheetTransitionID = nil
#endif
#if !os(tvOS)
            self.nextEpisodeButton.isEnabled = true
#endif
            self.resetTimedEpisodeStateForNewPlayback()

            self.initialPreset = request.preset
            self.initialHeaders = request.headers
            self.initialSubtitles = request.subtitles
            self.initialSubtitleNames = request.subtitleNames
            self.initialSubtitleHeadersByURL = request.subtitleHeadersByURL
            self.mediaInfo = request.mediaInfo
            self.imdbId = request.imdbId
            self.isAnimeHint = request.isAnimeHint
            self.isAnimationContentHint = request.isAnimationContentHint ?? self.isAnimationContentHint
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE

            self.gpuMPVRenderer?.contentIsAnimation = self.isAnimationContent()
#endif
            self.originalTMDBSeasonNumber = request.originalTMDBSeasonNumber
            self.originalTMDBEpisodeNumber = request.originalTMDBEpisodeNumber
            self.episodePlaybackContext = request.episodePlaybackContext
            self.playbackLaunchContext = request.launchContext
            let replacementTitle: String = {
                switch request.mediaInfo {
                case .movie(_, let title, _, _): return title
                case .episode(_, _, _, let showTitle, _, _): return showTitle ?? self.playerTitleOverride ?? "Show"
                case .none: return self.playerTitleOverride ?? ""
                }
            }()
            let selectionRequest = PlaybackRequest(
                url: request.url,
                preset: request.preset,
                headers: request.headers ?? [:],
                subtitles: request.subtitles ?? [],
                subtitleNames: request.subtitleNames,
                subtitleHeadersByURL: request.subtitleHeadersByURL,
                mediaSelectionIntent: self.playbackMediaSelectionIntent,
                mediaInfo: request.mediaInfo,
                mediaYear: request.mediaYear
                    ?? self.activePlaybackRequest?.mediaYear
                    ?? self.servicesSelectionContext?.mediaYear,
                imdbID: request.imdbId,
                episodePlaybackContext: request.episodePlaybackContext,
                launchContext: request.launchContext,
                resumePosition: nil,
                title: replacementTitle,
                subtitle: self.activePlaybackRequest?.subtitle,
                artworkURL: self.activePlaybackRequest?.artworkURL,
                isAnime: request.isAnimeHint,
                isAnimation: request.isAnimationContentHint ?? self.isAnimationContentHint ?? false,
                originalTMDBSeasonNumber: request.originalTMDBSeasonNumber,
                originalTMDBEpisodeNumber: request.originalTMDBEpisodeNumber,
                servicesOriginalTitle: self.activePlaybackRequest?.servicesOriginalTitle,
                servicesOriginalAudioLanguage: self.activePlaybackRequest?.servicesOriginalAudioLanguage,
                onRequestNextEpisode: self.activePlaybackRequest?.onRequestNextEpisode,
                onRequestResolvedNextEpisode: self.activePlaybackRequest?.onRequestResolvedNextEpisode,
                // The launch-site recovery callback is bound to the episode the host launched.
                // Forwarding it across an episode change lets a failed replacement reopen the
                // previous episode, so only a same-media source switch may inherit it.
                onPlaybackStartupFailure: Self.hasSameMediaIdentity(
                    self.activePlaybackRequest?.mediaInfo,
                    request.mediaInfo
                ) ? self.activePlaybackRequest?.onPlaybackStartupFailure : nil,
                localNextEpisodeFallback: self.activePlaybackRequest?.localNextEpisodeFallback
            )
            let existingSelectionStillMatches: Bool = {
                guard let existing = self.servicesSelectionContext else { return false }
                switch request.mediaInfo {
                case .movie(let id, _, _, _):
                    return existing.isMovie && existing.tmdbID == id
                case .episode(let showID, let seasonNumber, let episodeNumber, _, _, _):
                    return !existing.isMovie
                        && existing.tmdbID == showID
                        && existing.selectedEpisode?.seasonNumber == seasonNumber
                        && existing.selectedEpisode?.episodeNumber == episodeNumber
                case .none:
                    return false
                }
            }()
            if !existingSelectionStillMatches
                || (self.servicesSelectionContext?.mediaYear == nil && selectionRequest.mediaYear != nil) {
                self.servicesSelectionContext = PlayerServicesSelectionContext(request: selectionRequest)
            }

            self.updatePlayerTitle()
            self.updateEpisodeBrowserButtonVisibility()
            let shouldSwitchVLCInPlace = wasVLC && self.isRunning

            let startReplacementLoad = { [weak self] in
                guard let self else { return }
                guard self.playbackReplacementGeneration == replacementGeneration else {
                    return
                }
                if shouldSwitchVLCInPlace {
                    self.isReplacingVLCPlaybackInPlace = true
                }
                self.load(url: request.url, preset: request.preset, headers: request.headers)
                if shouldSwitchVLCInPlace {
                    self.isReplacingVLCPlaybackInPlace = false
                }
                self.showControlsTemporarily()
            }

            if shouldSwitchVLCInPlace {
                startReplacementLoad()
            } else if wasVLC {
                self.rendererStop(
                    retainingMPVHeaderProxyURL: self.isLocalProxyURL(request.url)
                        ? request.url
                        : nil
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: startReplacementLoad)
            } else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.rendererStopAndWait(
                        retainingMPVHeaderProxyURL: self.isLocalProxyURL(request.url)
                            ? request.url
                            : nil
                    )
                    guard self.playbackReplacementGeneration == replacementGeneration else { return }
                    startReplacementLoad()
                }
            }
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
        experimentalStagedNextEpisodeKey = nil
        nextEpisodeStagingRetryAfterByKey.removeAll()
        nextEpisodeStagingTask?.cancel()
        nextEpisodeStagingTask = nil
        stagedNextEpisodeRequest = nil
        stagedNextEpisodeRequestKey = nil
        nextEpisodePreviewUnavailableKeys.removeAll()
        pendingWatchTogetherNextEpisodeTarget = nil
        pendingWatchTogetherNextEpisodeTransitionID = nil
        nextEpisodePreviewTask?.cancel()
        nextEpisodePreviewTask = nil
        nextEpisodePreviewGeneration = nil
        nextEpisodeArtworkTask?.cancel()
        nextEpisodeArtworkTask = nil
        nextEpisodeArtworkKey = nil
        nextEpisodeArtworkImage = nil
        nextEpisodeButtonAppearanceKey = nil
#if !os(tvOS)
        applyTextNextEpisodeButton()
#endif
    }

    private var usesOverlayPlayerMenus: Bool {
        usesOverlayPlayerMenusForSession
    }

    @objc private func playerMenuButtonTouchDown(_ sender: UIButton) {
        let reason: String
        if sender === speedButton {
            reason = "speed-menu"
        } else if sender === audioButton {
            reason = "audio-menu"
        } else if sender === subtitleButton {
            reason = "subtitle-menu"
        } else {
            reason = "player-menu"
        }
        if usesOverlayPlayerMenus {
            Logger.shared.log("[PlayerVC.Menu] opening lightweight overlay reason=\(reason) renderer=\(mpvRendererName)", type: "MPV")
        } else {
            beginNativePlayerMenuPresentationGuard()
        }
        renderer.beginForegroundUIStallRecovery(reason: reason)
        let openedAt = CACurrentMediaTime()
        let baselinePosition = cachedPosition
        let baselineDuration = cachedDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, !self.isClosing else { return }
            let elapsed = CACurrentMediaTime() - openedAt
            let positionDelta = self.cachedPosition - baselinePosition
            Logger.shared.log(
                "[PlayerVC.Menu] playback continuity reason=\(reason) renderer=\(self.mpvRendererName) elapsed=\(String(format: "%.2f", elapsed))s positionDelta=\(String(format: "%.2f", positionDelta)) duration=\(String(format: "%.2f", baselineDuration))->\(String(format: "%.2f", self.cachedDuration)) paused=\(self.rendererIsPausedState()) loading=\(self.isRendererLoading)",
                type: "MPV"
            )
        }
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

    private func beginNativePlayerMenuPresentationGuard() {
        let interval = isMetalMPVRenderer && !rendererIsPausedState()
            ? moltenVKNativePlayerMenuRebuildSuppressionInterval
            : nativePlayerMenuRebuildSuppressionInterval
        let deadline = CACurrentMediaTime() + interval
        nativePlayerMenuRebuildSuppressionUntil = max(nativePlayerMenuRebuildSuppressionUntil, deadline)
        scheduleNativePlayerMenuRefreshFlush()
    }

    private func resetNativePlayerMenuContentSignatures() {
        nativeSpeedMenuContentSignature = nil
        nativeAudioMenuContentSignature = nil
        nativeSubtitleMenuContentSignature = nil
    }

    private func colorMenuSignature(_ color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return String(format: "%.3f,%.3f,%.3f,%.3f", red, green, blue, alpha)
        }
        return color.description
    }

    private func subtitleStyleMenuSignature() -> String {
        [
            colorMenuSignature(subtitleModel.foregroundColor),
            colorMenuSignature(subtitleModel.strokeColor),
            String(format: "%.2f", subtitleModel.strokeWidth),
            String(format: "%.2f", subtitleModel.fontSize),
            String(format: "%.2f", subtitleModel.verticalOffset),
            subtitleModel.closedCaptionBackground ? "cc-bg" : "cc-clear"
        ].joined(separator: "|")
    }

    private func subtitleSelectionMenuSignature() -> String {
        switch vlcSubtitleSelection {
        case .none:
            return "none"
        case .embedded(let trackId):
            return "embedded:\(trackId)"
        case .external(let index):
            return "external:\(index)"
        }
    }

    private func shouldDeferNativePlayerMenuRefresh(kind: String) -> Bool {
        guard !usesOverlayPlayerMenus,
              CACurrentMediaTime() < nativePlayerMenuRebuildSuppressionUntil else {
            return false
        }
        pendingNativePlayerMenuRefreshKinds.insert(kind)
        scheduleNativePlayerMenuRefreshFlush()
        return true
    }

    private func scheduleNativePlayerMenuRefreshFlush() {
        nativePlayerMenuRefreshWorkItem?.cancel()
        let delay = max(0.05, nativePlayerMenuRebuildSuppressionUntil - CACurrentMediaTime())
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if CACurrentMediaTime() < self.nativePlayerMenuRebuildSuppressionUntil {
                self.scheduleNativePlayerMenuRefreshFlush()
                return
            }

            let pendingKinds = self.pendingNativePlayerMenuRefreshKinds
            self.pendingNativePlayerMenuRefreshKinds.removeAll()
            self.nativePlayerMenuRefreshWorkItem = nil
            if pendingKinds.contains("speed") {
                self.updateSpeedMenu()
            }
            if pendingKinds.contains("audio") {
                self.updateAudioTracksMenu()
            }
            if pendingKinds.contains("subtitles") {
                self.updateSubtitleTracksMenu()
            }
        }
        nativePlayerMenuRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
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
                let foregroundColor = action.isEnabled ? UIColor.white : UIColor.white.withAlphaComponent(0.38)
                if let imageName = action.imageName {
                    var configuration = UIButton.Configuration.plain()
                    configuration.title = prefix + action.title
                    configuration.image = UIImage(systemName: imageName)
                    configuration.imagePadding = 8
                    configuration.contentInsets = .zero
                    configuration.baseForegroundColor = foregroundColor
                    button.configuration = configuration
                } else {
                    button.setTitle(prefix + action.title, for: .normal)
                    button.setTitleColor(foregroundColor, for: .normal)
                }
                button.tintColor = foregroundColor
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

    private func refreshVisibleOverlayMenuIfNeeded(kind: String) {
        guard usesOverlayPlayerMenus,
              overlayMenuKind == kind,
              !overlayMenuPanelView.isHidden else {
            return
        }

        switch kind {
        case "audio":
            showMPVAudioMenu()
        case "subtitles":
            showMPVSubtitleMenu()
        default:
            break
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
        var speeds: [(String, Double)] = [
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
        let detailedTracks = menuAudioDetailedTracks()
        let currentAudioTrackId = menuCurrentAudioTrackId()
        let actions: [PlayerOverlayMenuAction]
        if detailedTracks.isEmpty {
            actions = [makeOverlayAction(title: "No audio tracks available", isEnabled: false) {}]
        } else {
            actions = detailedTracks.map { id, name, language in
                makeOverlayAction(title: name, imageName: "speaker.wave.2", isSelected: id == currentAudioTrackId) { [weak self] in
                    guard let self else { return }
                    self.userSelectedAudioTrack = true
                    self.recordUserAudioSelection(name: name, languageTag: language)
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
        if usesOverlayPlayerMenus {
            if nativeSpeedMenuContentSignature != "overlay" {
                speedButton.menu = nil
                nativeSpeedMenuContentSignature = "overlay"
            }
            return
        }

        let currentSpeed = rendererGetSpeed()
        var speeds: [(String, Double)] = [
            ("0.25x", 0.25),
            ("0.5x", 0.5),
            ("0.75x", 0.75),
            ("1.0x", 1.0),
            ("1.25x", 1.25),
            ("1.5x", 1.5),
            ("1.75x", 1.75),
            ("2.0x", 2.0)
        ]

        let menuSignature = "native|\(String(format: "%.2f", currentSpeed))|\(speeds.map { "\($0.0):\(String(format: "%.2f", $0.1))" }.joined(separator: "|"))"
        if menuSignature == nativeSpeedMenuContentSignature {
            return
        }
        if shouldDeferNativePlayerMenuRefresh(kind: "speed") {
            return
        }

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
        nativeSpeedMenuContentSignature = menuSignature
    }

    private func updateAudioTracksMenuWhenReady(attempt: Int = 0) {

        audioTrackCacheValid = false

        if userSelectedAudioTrack {
            updateAudioTracksMenu()
            return
        }

        let detailedTracks = rendererGetAudioTracksDetailed()

        if !detailedTracks.isEmpty {
            updateAudioTracksMenu()
            return
        }

        if attempt >= 20 {
            updateAudioTracksMenu()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.updateAudioTracksMenuWhenReady(attempt: attempt + 1)
        }
    }

    private func updateSubtitleTracksMenuWhenReady(attempt: Int = 0) {

        subtitleTrackCacheValid = false
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
        let detailedTracks = menuAudioDetailedTracks()
        let tracks = detailedTracks.map { ($0.0, $0.1) }
        let isAnime = isAnimeContent()
        let currentAudioTrackId = menuCurrentAudioTrackId()

        audioButton.isHidden = false

        let trackSignature = detailedTracks.map { "\($0.0):\($0.1):\($0.2)" }.joined(separator: "|")
        let audioLogSignature = "tracks=\(trackSignature)|anime=\(isAnime)|user=\(userSelectedAudioTrack)|current=\(currentAudioTrackId)|renderer=\(vlcRenderer != nil ? "VLC" : "MPV")"
        if audioLogSignature != lastAudioTracksMenuLogSignature {
            lastAudioTracksMenuLogSignature = audioLogSignature
            Logger.shared.log("PlayerViewController: audio tracks count=\(tracks.count) isAnime=\(isAnime) userSelected=\(userSelectedAudioTrack) renderer=\(vlcRenderer != nil ? "VLC" : "MPV")", type: "Player")
        }

        let shouldAutoSelectAudio = !tracks.isEmpty && !userSelectedAudioTrack
        if shouldAutoSelectAudio {
            let preferredLang = automaticAudioSelectionLanguage
            let autoSelectSignature = "\(preferredLang)|\(trackSignature)"
            let shouldAttemptAutoSelect = attemptedAudioAutoSelectSignature != autoSelectSignature

            if shouldAttemptAutoSelect {
                attemptedAudioAutoSelectSignature = autoSelectSignature
            } else {
                if usesOverlayPlayerMenus {
                    if nativeAudioMenuContentSignature != "overlay" {
                        audioButton.menu = nil
                        nativeAudioMenuContentSignature = "overlay"
                    }
                    return
                }
            }

            if shouldAttemptAutoSelect, !preferredLang.isEmpty {
                Logger.shared.log("PlayerViewController: Auto audio - preferredLang=\(preferredLang), detailedTracks=\(detailedTracks.count), isAnime=\(isAnime)", type: "Player")

                let languageOptions = detailedTracks.map {
                    PlaybackLanguageSelectionPolicy.Option(
                        languageTag: $0.2,
                        displayName: $0.1
                    )
                }
                if let matchingIndex = PlaybackLanguageSelectionPolicy.preferredIndex(
                    in: languageOptions,
                    preferredLanguage: preferredLang
                ) {
                    let matching = detailedTracks[matchingIndex]
                    Logger.shared.log("PlayerViewController: Auto-selected audio track: \(matching.1) (ID: \(matching.0))", type: "Player")
                    userSelectedAudioTrack = true
                    rendererSetAudioTrack(id: matching.0)
                } else {
                    Logger.shared.log("PlayerViewController: No matching audio track found for lang=\(preferredLang)", type: "Player")
                }
            } else if shouldAttemptAutoSelect {
                Logger.shared.log("PlayerViewController: Auto audio skipped (preferred language empty)", type: "Player")
            }
        }

        if usesOverlayPlayerMenus {
            if nativeAudioMenuContentSignature != "overlay" {
                audioButton.menu = nil
                nativeAudioMenuContentSignature = "overlay"
            }
            return
        }
        let menuSignature = "native|current=\(currentAudioTrackId)|tracks=\(trackSignature)"
        if menuSignature == nativeAudioMenuContentSignature {
            return
        }
        if shouldDeferNativePlayerMenuRefresh(kind: "audio") {
            return
        }

        if tracks.isEmpty {
            let noTracksAction = UIAction(title: "No audio tracks available", state: .off) { _ in }
            let audioMenu = UIMenu(title: "Audio Tracks", image: UIImage(systemName: "speaker.wave.2"), children: [noTracksAction])
            audioButton.menu = audioMenu
            nativeAudioMenuContentSignature = menuSignature
            return
        }

        let trackActions = detailedTracks.map { (id, name, language) in
            UIAction(
                title: name,
                state: id == currentAudioTrackId ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.userSelectedAudioTrack = true
                self.recordUserAudioSelection(name: name, languageTag: language)
                self.rendererSetAudioTrack(id: id)

                self.audioMenuDebounceTimer?.invalidate()
                self.audioMenuDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                    DispatchQueue.main.async { [weak self] in
                        self?.updateAudioTracksMenu()
                    }
                }
            }
        }

        let audioMenu = UIMenu(title: "Audio Tracks", image: UIImage(systemName: "speaker.wave.2"), children: trackActions)
        audioButton.menu = audioMenu
        nativeAudioMenuContentSignature = menuSignature
    }

    private func isAnimeContent() -> Bool {
        if let hint = isAnimeHint, hint == true { return true }
        if episodePlaybackContext?.hasAnimeMediaId == true { return true }
        guard let info = mediaInfo else { return false }
        switch info {
        case .movie(_, _, _, let isAnime):
            return isAnime
        case .episode(_, _, _, _, _, let isAnime):
            return isAnime
        }
    }

    private func isAnimationContent() -> Bool {
        isAnimeContent() || isAnimationContentHint == true
    }

    private func audioComfortCategory() -> AudioComfortContentCategory {
        if isAnimeContent() { return .anime }
        if isAnimationContentHint == true { return .westernAnimation }
        return .liveAction
    }

    private func resolvedAudioComfortFilterChain() -> String {
        let mode = Settings.shared.audioComfortMode
        guard mode != .original else { return "" }
        let applies = Settings.shared.audioComfortScopeCategories.contains(audioComfortCategory())
        return applies ? mode.mpvAudioFilterChain : ""
    }

    private func applyAudioComfortFilterIfNeeded(reason: String) {

        guard isMPVRenderer else { return }
        let mode = Settings.shared.audioComfortMode
        let scope = Settings.shared.audioComfortScopeCategories.map { $0.rawValue }.sorted().joined(separator: "+")
        let chain = resolvedAudioComfortFilterChain()
        Logger.shared.log("[PlayerVC.Audio] comfort mode=\(mode.rawValue) scope=[\(scope)] category=\(audioComfortCategory().rawValue) reason=\(reason) -> \(chain.isEmpty ? "(passthrough)" : chain)", type: "MPV")
        renderer.applyAudioFilterChain(chain)
    }

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

        let tmdbId: Int
        let seasonNumber: Int?
        let episodeNumber: Int?
        let showTitle: String?
        let isAnime: Bool
        let mediaType: String

        switch info {
        case .movie(let id, _, _, let anime):
            tmdbId = id
            seasonNumber = nil
            episodeNumber = nil
            showTitle = nil
            isAnime = anime || isAnimeContent()
            mediaType = "movie"
        case .episode(let showId, let s, let e, let title, _, let anime):
            tmdbId = showId
            seasonNumber = s
            episodeNumber = e
            showTitle = title
            isAnime = anime || isAnimeContent()
            mediaType = "series"
        }

        Logger.shared.log("SkipData: fetchSkipData called - tmdbId=\(tmdbId) s=\(seasonNumber ?? -1) ep=\(episodeNumber ?? -1) isAnime=\(isAnime)", type: "Skip")

        skipDataFetched = true

        Task { [weak self] in
            guard let self else { return }

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
            let skip85sEnabled = ProfileSettingsStore.active.bool(forKey: "skip85sEnabled")
            let skip85sAlwaysVisible = ProfileSettingsStore.active.bool(forKey: "skip85sAlwaysVisible")

            let aniSkipEnabled = ProfileSettingsStore.active.object(forKey: "aniSkipEnabled") as? Bool ?? true
            let introDBEnabled = ProfileSettingsStore.active.object(forKey: "introDBEnabled") as? Bool ?? true
            let introDBAppEnabled = ProfileSettingsStore.active.object(forKey: "introDBAppEnabled") as? Bool ?? true
            var selectedSkipProvider: String?

            Logger.shared.log(
                "SkipData: provider flow=\(isAnime ? "AniSkip -> TheIntroDB -> IntroDB" : "TheIntroDB -> IntroDB") settings AniSkip=\(aniSkipEnabled) TheIntroDB=\(introDBEnabled) IntroDB=\(introDBAppEnabled) duration=\(self.secondsText(durationAtFetch))",
                type: "Skip"
            )

            if !aniSkipEnabled {
                Logger.shared.log("SkipData: AniSkip skipped: disabled in Settings", type: "Skip")
            } else if !isAnime {
                Logger.shared.log("SkipData: AniSkip skipped: non-anime content", type: "Skip")
            } else if episodeNumber == nil {
                Logger.shared.log("SkipData: AniSkip skipped: missing episode number", type: "Skip")
            } else if let ep = episodeNumber {
                Logger.shared.log(
                    "SkipData: AniSkip attempt tmdbId=\(tmdbId) s=\(seasonNumber ?? -1) ep=\(ep) duration=\(self.secondsText(durationAtFetch))",
                    type: "Skip"
                )
                segments = await self.fetchAniSkipSegments(
                    tmdbId: tmdbId,
                    seasonNumber: seasonNumber ?? 1,
                    episodeNumber: ep,
                    showTitle: showTitle,
                    duration: durationAtFetch
                )

                Logger.shared.log("SkipData: AniSkip returned \(segments.count) segments", type: "Skip")
                if !segments.isEmpty {
                    selectedSkipProvider = "AniSkip"
                }
            }

            let introDBSeason = self.originalTMDBSeasonNumber ?? seasonNumber
            let introDBEpisode = self.originalTMDBEpisodeNumber ?? episodeNumber

            let introDBAppSeason = self.episodePlaybackContext?.isSpecial == true ? introDBSeason : seasonNumber
            let introDBAppEpisode = self.episodePlaybackContext?.isSpecial == true ? introDBEpisode : episodeNumber
            if !introDBEnabled {
                Logger.shared.log("SkipData: TheIntroDB skipped: disabled in Settings", type: "Skip")
            } else if !segments.isEmpty {
                Logger.shared.log("SkipData: TheIntroDB skipped: \(selectedSkipProvider ?? "earlier provider") already returned \(segments.count) segments", type: "Skip")
            } else {
                Logger.shared.log(
                    "SkipData: TheIntroDB attempt tmdbId=\(tmdbId) s=\(introDBSeason ?? -1) ep=\(introDBEpisode ?? -1) duration=\(self.secondsText(durationAtFetch))",
                    type: "Skip"
                )
                do {
                    let introDBSegments = try await IntroDBService.shared.fetchSkipTimes(
                        tmdbId: tmdbId,
                        seasonNumber: introDBSeason,
                        episodeNumber: introDBEpisode,
                        episodeDuration: durationAtFetch
                    )
                    Logger.shared.log("SkipData: TheIntroDB returned \(introDBSegments.count) segments", type: "Skip")
                    if !introDBSegments.isEmpty {
                        segments = introDBSegments
                        selectedSkipProvider = "TheIntroDB"
                    }
                } catch {
                    Logger.shared.log("SkipData: TheIntroDB fetch failed: \(error.localizedDescription)", type: "Error")
                }
            }

            if !introDBAppEnabled {
                Logger.shared.log("SkipData: IntroDB skipped: disabled in Settings", type: "Skip")
            } else if !segments.isEmpty {
                Logger.shared.log("SkipData: IntroDB skipped: \(selectedSkipProvider ?? "earlier provider") already returned \(segments.count) segments", type: "Skip")
            } else {
                let introDBIMDbId = await self.resolveSkipDataIMDbId(tmdbId: tmdbId, type: mediaType, currentIMDbId: self.imdbId)
                if let introDBIMDbId {
                    Logger.shared.log(
                        "SkipData: IntroDB attempt imdbId=\(introDBIMDbId) s=\(introDBAppSeason ?? -1) ep=\(introDBAppEpisode ?? -1) duration=\(self.secondsText(durationAtFetch))",
                        type: "Skip"
                    )
                    do {
                        let introDBAppSegments = try await IntroDBAppService.shared.fetchSkipTimes(
                            imdbId: introDBIMDbId,
                            seasonNumber: introDBAppSeason,
                            episodeNumber: introDBAppEpisode,
                            episodeDuration: durationAtFetch
                        )
                        Logger.shared.log("SkipData: IntroDB returned \(introDBAppSegments.count) segments", type: "Skip")
                        if !introDBAppSegments.isEmpty {
                            segments = introDBAppSegments
                            selectedSkipProvider = "IntroDB"
                        }
                    } catch {
                        Logger.shared.log("SkipData: IntroDB fetch failed: \(error.localizedDescription)", type: "Error")
                    }
                } else {
                    Logger.shared.log("SkipData: IntroDB skipped missing IMDb ID for tmdbId=\(tmdbId)", type: "Skip")
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

            await MainActor.run {
                Logger.shared.log("SkipData: using \(selectedSkipProvider ?? "unknown provider") with \(segments.count) segments", type: "Skip")
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

    private func resolveSkipDataIMDbId(tmdbId: Int, type: String, currentIMDbId: String?) async -> String? {
        if let currentIMDbId = currentIMDbId?.trimmingCharacters(in: .whitespacesAndNewlines), !currentIMDbId.isEmpty {
            return currentIMDbId
        }

        do {
            if type == "movie" {
                return try await TMDBService.shared.getMovieDetails(id: tmdbId).imdbId
            }
            return try await TMDBService.shared.getTVShowDetails(id: tmdbId).externalIds?.imdbId
        } catch {
            Logger.shared.log("SkipData: IMDb resolve failed tmdbId=\(tmdbId) type=\(type): \(error.localizedDescription)", type: "Skip")
            return nil
        }
    }

    private func fetchAniSkipSegments(tmdbId: Int, seasonNumber: Int, episodeNumber: Int, showTitle: String?, duration: Double) async -> [SkipSegment] {
        let skipAniListTraversal = PerformanceModeSettings.skipsAniListTraversalForAnimeDetails

        var animeProviderId = episodePlaybackContext?.anilistMediaId
        if let id = animeProviderId {
            Logger.shared.log("SkipData: AniSkip step 0 - playback context media ID \(id)", type: "Skip")
        }

        if animeProviderId == nil {
            animeProviderId = trackerManager.cachedAniListSeasonId(tmdbId: tmdbId, seasonNumber: seasonNumber)
            if let id = animeProviderId {
                Logger.shared.log("SkipData: AniSkip step 1 - cached season ID \(id)", type: "Skip")
            }
        }

        if animeProviderId == nil {
            animeProviderId = trackerManager.cachedAniListId(for: tmdbId)
            if let id = animeProviderId {
                Logger.shared.log("SkipData: AniSkip step 2 - cached show ID \(id)", type: "Skip")
            }
        }

        if animeProviderId == nil, !skipAniListTraversal, let title = showTitle {
            Logger.shared.log("SkipData: AniSkip step 3 - resolving via AniListService for '\(title)'", type: "Skip")
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
                animeProviderId = animeData.seasons.first(where: { $0.seasonNumber == seasonNumber })?.anilistId
            } catch {
                Logger.shared.log("SkipData: AniSkip step 3 failed: \(error.localizedDescription)", type: "Skip")
            }
        }

        if animeProviderId == nil, !skipAniListTraversal {
            animeProviderId = await trackerManager.getAniListMediaId(tmdbId: tmdbId)
        }

        guard let finalId = animeProviderId else {
            Logger.shared.log("SkipData: No anime provider ID found for tmdbId=\(tmdbId) - skipping AniSkip", type: "Skip")
            return []
        }

        let malId: Int
        if finalId < 0 {
            guard let exactMALID = RemoteMediaNumericBoundary.positiveMagnitude(finalId) else {
                return []
            }
            malId = exactMALID
            Logger.shared.log("SkipData: AniSkip using MAL fallback mediaId=\(malId)", type: "Skip")
        } else {
            let resolvedMALId: Int?
            if skipAniListTraversal {
                resolvedMALId = trackerManager.cachedMyAnimeListAnimeId(fromAniListId: finalId)
            } else {
                resolvedMALId = await trackerManager.resolveMyAnimeListAnimeId(fromAniListId: finalId)
            }
            guard let resolvedMALId else {
                Logger.shared.log("SkipData: AniSkip could not resolve MAL ID for AniList \(finalId)", type: "Skip")
                return []
            }
            malId = resolvedMALId
            Logger.shared.log("SkipData: AniSkip resolved AniList \(finalId) to MAL \(malId)", type: "Skip")
        }

        Logger.shared.log("SkipData: AniSkip using malId=\(malId) for ep=\(episodeNumber)", type: "Skip")

        do {
            return try await AniSkipService.shared.fetchSkipTimes(
                malId: malId,
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
        if ProfileSettingsStore.active.bool(forKey: "skip85sEnabled") {
            showSkip85sButton()
            return true
        }
        hideSkip85sButton()
        return false
    }

    private func updateSkipState(position: Double, duration: Double) {
        guard !skipSegments.isEmpty, duration > 0 else { return }

        if progressModel.skipSegments.isEmpty {
            progressModel.skipSegments = skipSegments.map { seg in
                (start: seg.startTime / duration, end: seg.endTime / duration)
            }
            Logger.shared.log("SkipData: Deferred normalization applied with duration=\(String(format: "%.1f", duration))", type: "Skip")
        }

        let activeSegment = skipSegments.first { seg in
            guard seg.startTime.isFinite, seg.endTime.isFinite else { return false }
            return position >= seg.startTime && position <= seg.endTime
        }

        if let seg = activeSegment {

            let autoSkipEnabled = ProfileSettingsStore.active.bool(forKey: "aniSkipAutoSkip")
#if os(iOS)
            let autoSkipSuppressedByWatchTogether =
                WatchTogetherCoordinator.shared.sessionRole(for: self) == .follower
#else
            let autoSkipSuppressedByWatchTogether = false
#endif
            if autoSkipEnabled,
               !autoSkipSuppressedByWatchTogether,
               !autoSkippedSegments.contains(seg.uniqueKey) {
                autoSkippedSegments.insert(seg.uniqueKey)
                Logger.shared.log("SkipData: Auto-skipping \(seg.type.rawValue) from \(secondsText(seg.startTime))s to \(secondsText(seg.endTime))s", type: "Skip")
                let target = clampedPlaybackPosition(seg.endTime + 1.0)
                rendererSeek(to: target)
#if os(iOS)
                WatchTogetherCoordinator.shared.sendUserSeek(to: target, from: self)
#endif
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

    private func hasStagedNextEpisodeRequest(for key: String) -> Bool {
        stagedNextEpisodeRequestKey == key && stagedNextEpisodeRequest != nil
    }

    private func markNextEpisodeStagingAttemptSkipped(key: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.hasStagedNextEpisodeRequest(for: key) else { return }
            if self.experimentalStagedNextEpisodeKey == key {
                self.experimentalStagedNextEpisodeKey = nil
            }
            self.nextEpisodeStagingRetryAfterByKey[key] = Date().addingTimeInterval(self.nextEpisodeStagingRetryDelay)
        }
    }

    private var shouldUsePosterNextEpisodeButton: Bool {
        ProfileSettingsStore.active.bool(forKey: "showNextEpisodePosterButton")
    }

    private var shouldSkipFillerForNextEpisode: Bool {
        #if os(iOS)
        guard NextEpisodeFillerSettings.isEnabled(),
              case .episode(_, let seasonNumber, _, _, _, let isAnime) = mediaInfo,
              seasonNumber != 0,
              (isAnime || isAnimeContent()),
              episodePlaybackContext?.isSpecial != true else {
            return false
        }
        return true
        #else
        return false
        #endif
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

        let skippingKnownFillers = shouldSkipFillerForNextEpisode
        let generation = UUID()
        nextEpisodePreviewGeneration = generation
        nextEpisodePreviewTask = Task { @MainActor [weak self] in
            let model = PlayerEpisodeBrowserViewModel(seed: seed)
            let item = await model.itemAfterCurrent(skippingKnownFillers: skippingKnownFillers)
            guard !Task.isCancelled,
                  let self,
                  self.nextEpisodePreviewGeneration == generation else { return }
            self.nextEpisodePreviewTask = nil
            self.nextEpisodePreviewGeneration = nil
            guard case .episode(_, let activeSeason, let activeEpisode, _, _, _) = self.mediaInfo,
                  activeSeason == seasonNumber,
                  activeEpisode == episodeNumber,
                  self.nextEpisodeKey(seasonNumber: activeSeason, episodeNumber: activeEpisode) == key else {
                return
            }
            if let item {
                self.nextEpisodePreview = item
                self.nextEpisodePreviewKey = key
                self.applyNextEpisodeButtonAppearance()
            } else {
                self.nextEpisodePreview = nil
                self.nextEpisodePreviewKey = nil
                self.nextEpisodePreviewUnavailableKeys.insert(key)
                if self.hasStagedNextEpisodeRequest(for: key) {
                    self.applyTextNextEpisodeButton()
                } else {
                    self.hideNextEpisodeButton()
                }
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
        updateNextEpisodeButtonVerticalSpacing(isPosterMode: false)

        let signature = "text"
        guard nextEpisodeButtonAppearanceKey != signature else { return }
        nextEpisodeButton.applyTextMode()
        nextEpisodeButton.layer.shadowOpacity = 0.3
        nextEpisodeButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        nextEpisodeButton.layer.shadowRadius = 4
        nextEpisodeButtonAppearanceKey = signature
    }

    private func applyPosterNextEpisodeButton(_ item: PlayerEpisodeBrowserItem) {
        updateNextEpisodeButtonVerticalSpacing(isPosterMode: true)
        let imageURLs = item.artworkURLs
        let imageKey = imageURLs.joined(separator: "|")
        let isSameArtwork = nextEpisodeArtworkKey == imageKey
        let placeholderImage = makeNextEpisodeArtworkPlaceholderImage()
        let imageReady = isSameArtwork && nextEpisodeArtworkImage != nil
        let signature = "poster|\(imageKey)|\(item.displayCode)|\(item.displayTitle)|ready=\(imageReady)"

        if nextEpisodeButtonAppearanceKey != signature {
            nextEpisodeButton.applyPosterMode(
                image: isSameArtwork ? (nextEpisodeArtworkImage ?? placeholderImage) : placeholderImage,
                episodeText: "\(item.displayCode)  \(item.displayTitle)"
            )
            nextEpisodeButton.layer.shadowOpacity = 0.42
            nextEpisodeButton.layer.shadowOffset = CGSize(width: 0, height: 8)
            nextEpisodeButton.layer.shadowRadius = 14
            nextEpisodeButtonAppearanceKey = signature
        }

        guard !isSameArtwork else {
            return
        }

        nextEpisodeArtworkTask?.cancel()
        nextEpisodeArtworkTask = nil
        nextEpisodeArtworkKey = imageKey
        nextEpisodeArtworkImage = nil
        nextEpisodeButtonAppearanceKey = nil
        loadNextEpisodeArtwork(from: imageURLs, key: imageKey)
    }

    private func updateNextEpisodeButtonVerticalSpacing(isPosterMode: Bool) {
        let isIPadPoster = UIDevice.current.userInterfaceIdiom == .pad && isPosterMode
        let gapAboveSkipButton: CGFloat = isIPadPoster ? 82 : 10
        nextEpisodeButtonBottomConstraint?.constant = -gapAboveSkipButton
    }

    private func loadNextEpisodeArtwork(from imageURLs: [String], key: String, index: Int = 0) {
        guard index < imageURLs.count else { return }
        guard let url = URL(string: imageURLs[index]) else {
            loadNextEpisodeArtwork(from: imageURLs, key: key, index: index + 1)
            return
        }

#if canImport(Kingfisher)
        let processor = DownsamplingImageProcessor(size: nextEpisodeArtworkDecodeSize)
        KingfisherManager.shared.retrieveImage(
            with: url,
            options: [
                .processor(processor),
                .scaleFactor(UIScreen.main.scale),
                .backgroundDecode
            ]
        ) { [weak self] result in
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
            let rawImage = data.flatMap { self?.makeNextEpisodeArtworkSourceImage(from: $0) }
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

    private var nextEpisodeArtworkDecodeSize: CGSize {
        CGSize(width: 360, height: 204)
    }

    private var nextEpisodeArtworkTargetSize: CGSize {
        CGSize(width: 160, height: 90)
    }

    private func makeNextEpisodeArtworkPlaceholderImage() -> UIImage {
        let targetSize = nextEpisodeArtworkTargetSize
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: targetSize)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 8)
            UIColor(white: 1.0, alpha: 0.08).setFill()
            path.fill()

            let iconConfig = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
            let icon = UIImage(systemName: "play.rectangle.fill", withConfiguration: iconConfig)?
                .withTintColor(UIColor.white.withAlphaComponent(0.48), renderingMode: .alwaysOriginal)
            let iconSize = CGSize(width: 34, height: 26)
            let iconRect = CGRect(
                x: (targetSize.width - iconSize.width) / 2,
                y: (targetSize.height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            icon?.draw(in: iconRect)
        }.withRenderingMode(.alwaysOriginal)
    }

    private func makeNextEpisodeArtworkSourceImage(from data: Data) -> UIImage? {
#if canImport(ImageIO)
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 480
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
#else
        return UIImage(data: data)
#endif
    }

    private func applyNextEpisodeArtworkImage(_ rawImage: UIImage, key: String) {
        guard nextEpisodeArtworkKey == key else { return }
        let image = makeNextEpisodeArtworkImage(from: rawImage)
        nextEpisodeArtworkImage = image

        nextEpisodeButton.updatePosterArtwork(image)
        nextEpisodeButtonAppearanceKey = nil
    }

    private func makeNextEpisodeArtworkImage(from rawImage: UIImage) -> UIImage {
        guard rawImage.size.width > 0, rawImage.size.height > 0 else {
            return rawImage.withRenderingMode(.alwaysOriginal)
        }

        let targetSize = nextEpisodeArtworkTargetSize

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

    private struct NextEpisodePlaybackTarget {
        let seasonNumber: Int
        let episodeNumber: Int
        let playbackContext: EpisodePlaybackContext?
        let title: String?
    }

    private func nextEpisodePlaybackTarget(
        currentSeasonNumber: Int,
        currentEpisodeNumber: Int
    ) -> NextEpisodePlaybackTarget? {
        let key = nextEpisodeKey(
            seasonNumber: currentSeasonNumber,
            episodeNumber: currentEpisodeNumber
        )

        if initialURL?.isFileURL == true,
           let localNextEpisodeFallback {
            let currentTitle: String?
            if case .episode(_, _, _, let showTitle, _, _) = mediaInfo {
                currentTitle = showTitle
            } else {
                currentTitle = nil
            }
            return NextEpisodePlaybackTarget(
                seasonNumber: localNextEpisodeFallback.seasonNumber,
                episodeNumber: localNextEpisodeFallback.episodeNumber,
                playbackContext: localNextEpisodeFallback.seasonNumber == currentSeasonNumber
                    ? episodePlaybackContext?.forEpisodeNumber(localNextEpisodeFallback.episodeNumber)
                    : nil,
                title: currentTitle
            )
        }

        if nextEpisodePreviewKey == key,
           let preview = nextEpisodePreview {
            return NextEpisodePlaybackTarget(
                seasonNumber: preview.episode.seasonNumber,
                episodeNumber: preview.episode.episodeNumber,
                playbackContext: preview.playbackContext,
                title: preview.seasonTitleOverride ?? preview.mediaTitle
            )
        }

        guard onRequestResolvedNextEpisode == nil else { return nil }

        let requiresVerifiedAnimeTarget = isAnimeContent()
        guard !shouldSkipFillerForNextEpisode, !requiresVerifiedAnimeTarget else {
            return nil
        }

        guard let episodeNumber = RemoteMediaNumericBoundary.adding(
            currentEpisodeNumber,
            1
        ) else { return nil }
        let currentTitle: String?
        if case .episode(_, _, _, let showTitle, _, _) = mediaInfo {
            currentTitle = showTitle
        } else {
            currentTitle = nil
        }
        return NextEpisodePlaybackTarget(
            seasonNumber: currentSeasonNumber,
            episodeNumber: episodeNumber,
            playbackContext: episodePlaybackContext?.forEpisodeNumber(episodeNumber),
            title: currentTitle
        )
    }

    private func commitWatchTogetherNextEpisode(
        seasonNumber: Int,
        episodeNumber: Int,
        playbackContext: EpisodePlaybackContext?,
        title: String?
    ) -> (proceed: Bool, didBroadcast: Bool) {
#if os(iOS)
        let result = WatchTogetherCoordinator.shared.sendNextEpisode(
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            title: title,
            playbackContext: playbackContext,
            from: self
        )
        if result == .rejected {
            nextEpisodeButton.isEnabled = true
        } else if result == .notActive {
            switch watchTogetherConnectionState {
            case .ready:
                break
            case .activating, .active:
                nextEpisodeButton.isEnabled = true
                showPlayerNotice("Watch Together changed before the next episode was ready. Sync the session and try again.")
                return (false, false)
            }
        }
        return (result != .rejected, result == .sent)
#else
        return (true, false)
#endif
    }

    private func commitPendingWatchTogetherNextEpisodeIfNeeded(
        transitionID: UUID?
    ) -> Bool {
        guard let transitionID else { return pendingWatchTogetherNextEpisodeTarget == nil }
        guard pendingWatchTogetherNextEpisodeTransitionID == transitionID,
              let target = pendingWatchTogetherNextEpisodeTarget else {

            return false
        }
        pendingWatchTogetherNextEpisodeTarget = nil
        pendingWatchTogetherNextEpisodeTransitionID = nil
        return commitWatchTogetherNextEpisode(
            seasonNumber: target.seasonNumber,
            episodeNumber: target.episodeNumber,
            playbackContext: target.playbackContext,
            title: target.title
        ).proceed
    }

    private func clearPendingWatchTogetherNextEpisodeTarget(
        transitionID: UUID? = nil
    ) {
        if let transitionID,
           pendingWatchTogetherNextEpisodeTransitionID != transitionID {
            return
        }
        guard pendingWatchTogetherNextEpisodeTarget != nil
                || pendingWatchTogetherNextEpisodeTransitionID != nil else { return }
        pendingWatchTogetherNextEpisodeTarget = nil
        pendingWatchTogetherNextEpisodeTransitionID = nil
#if !os(tvOS)
        nextEpisodeButton.isEnabled = true
#endif
    }

    private func schedulePendingWatchTogetherNextEpisodeCleanup(
        transitionID: UUID?
    ) {
        guard let transitionID else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.clearPendingWatchTogetherNextEpisodeTarget(transitionID: transitionID)
        }
    }

    private func updateNextEpisodeState(position: Double, duration: Double) {
        guard duration > 0 else { return }
        guard case .episode(let showId, let seasonNumber, let episodeNumber, _, _, _) = mediaInfo else { return }

        let enabled: Bool
        if ProfileSettingsStore.active.object(forKey: "showNextEpisodeButton") == nil {
            enabled = true
        } else {
            enabled = ProfileSettingsStore.active.bool(forKey: "showNextEpisodeButton")
        }
        guard enabled else {
            if nextEpisodeButtonShown { hideNextEpisodeButton() }
            return
        }

        let threshold: Double
        let savedThreshold = ProfileSettingsStore.active.double(forKey: "nextEpisodeThreshold")
        threshold = savedThreshold > 0 ? savedThreshold : 0.90

        let progress = position / duration
        let previewKey = nextEpisodeKey(seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        let hasVerifiedLocalNextEpisode = initialURL?.isFileURL == true
            && localNextEpisodeFallback != nil
        if hasVerifiedLocalNextEpisode {
            if progress >= threshold {
                applyTextNextEpisodeButton()
                showNextEpisodeButton()
            } else if nextEpisodeButtonShown {
                hideNextEpisodeButton()
            }
            return
        }
        stageExperimentalNextEpisodeIfNeeded(
            showId: showId,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            progress: progress,
            threshold: threshold
        )

        if initialURL?.isFileURL == true,
           onRequestNextEpisode != nil,
           localNextEpisodeFallback == nil {
            if nextEpisodeButtonShown { hideNextEpisodeButton() }
            return
        }

        if progress >= threshold, !nextEpisodeButtonShown {
            resolveNextEpisodePreviewIfNeeded(seasonNumber: seasonNumber, episodeNumber: episodeNumber)
            if onRequestResolvedNextEpisode != nil,
               nextEpisodePreviewKey != previewKey {
                hideNextEpisodeButton()
                return
            }
            if shouldSkipFillerForNextEpisode,
               nextEpisodePreviewKey != previewKey {
                hideNextEpisodeButton()
                return
            }
            if !hasVerifiedLocalNextEpisode,
               nextEpisodePreviewUnavailableKeys.contains(previewKey),
               !hasStagedNextEpisodeRequest(for: previewKey) {
                hideNextEpisodeButton()
                return
            }
            applyNextEpisodeButtonAppearance()
            showNextEpisodeButton()
        } else if progress < threshold, nextEpisodeButtonShown {
            hideNextEpisodeButton()
        } else if progress >= threshold, nextEpisodeButtonShown {
            resolveNextEpisodePreviewIfNeeded(seasonNumber: seasonNumber, episodeNumber: episodeNumber)
            if onRequestResolvedNextEpisode != nil,
               nextEpisodePreviewKey != previewKey {
                hideNextEpisodeButton()
                return
            }
            if shouldSkipFillerForNextEpisode,
               nextEpisodePreviewKey != previewKey {
                hideNextEpisodeButton()
                return
            }
            if !hasVerifiedLocalNextEpisode,
               nextEpisodePreviewUnavailableKeys.contains(previewKey),
               !hasStagedNextEpisodeRequest(for: previewKey) {
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
        let target = clampedPlaybackPosition(seg.endTime + 1.0)
        rendererSeek(to: target)
#if os(iOS)
        WatchTogetherCoordinator.shared.sendUserSeek(to: target, from: self)
#endif
        currentActiveSkipSegment = nil
        hideSkipButton()
    }

    @objc private func nextEpisodeButtonTapped() {
        guard case .episode(let showID, let seasonNumber, let episodeNumber, _, _, _) = mediaInfo else { return }
        guard pendingNextEpisodeRequest == nil,
              pendingWatchTogetherNextEpisodeTarget == nil else { return }

        let target = nextEpisodePlaybackTarget(
            currentSeasonNumber: seasonNumber,
            currentEpisodeNumber: episodeNumber
        )
        let currentNextEpisodeKey = nextEpisodeKey(
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        )
        let matchingPreview = nextEpisodePreviewKey == currentNextEpisodeKey
            ? nextEpisodePreview
            : nil
        let currentEpisodeIsAnime = isAnimeContent()
        let requiresExactTarget = onRequestResolvedNextEpisode != nil || initialURL?.isFileURL == true
        if (shouldSkipFillerForNextEpisode || currentEpisodeIsAnime || requiresExactTarget), target == nil {
            Logger.shared.log(
                "NextEpisode: exact target was not ready; refusing to guess from S\(seasonNumber)E\(episodeNumber)",
                type: "Player"
            )
            hideNextEpisodeButton()
            return
        }
        let nextSeasonNumber = target?.seasonNumber ?? seasonNumber
        let nextEpisodeNumber: Int
        if let targetEpisodeNumber = target?.episodeNumber {
            nextEpisodeNumber = targetEpisodeNumber
        } else {
            guard let incrementedEpisodeNumber = RemoteMediaNumericBoundary.adding(
                episodeNumber,
                1
            ) else {
                hideNextEpisodeButton()
                return
            }
            nextEpisodeNumber = incrementedEpisodeNumber
        }
        let nextPlaybackContext = target?.playbackContext
            ?? (!currentEpisodeIsAnime && nextSeasonNumber == seasonNumber
                ? episodePlaybackContext?.forEpisodeNumber(nextEpisodeNumber)
                : nil)
        let nextTitle = target?.title
        Logger.shared.log("NextEpisode: User requested S\(nextSeasonNumber)E\(nextEpisodeNumber)", type: "Player")

        if initialURL?.isFileURL != true,
           nextEpisodePreviewUnavailableKeys.contains(currentNextEpisodeKey) {
            hideNextEpisodeButton()
            return
        }

#if os(iOS)
        let requiresResolvedWatchTogetherTarget: Bool
        switch watchTogetherConnectionState {
        case .ready:
            requiresResolvedWatchTogetherTarget = false
        case .activating, .active:
            requiresResolvedWatchTogetherTarget = true
        }
        if requiresResolvedWatchTogetherTarget,
           !(stagedNextEpisodeRequest != nil
                && stagedNextEpisodeRequestKey == currentNextEpisodeKey),
           matchingPreview == nil {

            nextEpisodeButton.isEnabled = true
            resolveNextEpisodePreviewIfNeeded(
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber
            )
            showPlayerNotice("The next episode is still resolving. Try again in a moment so everyone moves together.")
            return
        }
#endif

        nextEpisodeButton.isEnabled = false

        if let staged = stagedNextEpisodeRequest,
           stagedNextEpisodeRequestKey == currentNextEpisodeKey {
            guard commitWatchTogetherNextEpisode(
                seasonNumber: nextSeasonNumber,
                episodeNumber: nextEpisodeNumber,
                playbackContext: nextPlaybackContext,
                title: nextTitle
            ).proceed else { return }
            Logger.shared.log("[PlayerVC.MPV] next-episode using staged request (skipping source re-resolve)", type: "MPV")
            hideNextEpisodeButton()
            stagedNextEpisodeRequest = nil
            stagedNextEpisodeRequestKey = nil
            replacePlayback(with: staged, reason: "next-episode-staged-request")
            return
        }
        if let preview = matchingPreview {

            let transitionID = UUID()
            pendingWatchTogetherNextEpisodeTransitionID = transitionID
            pendingWatchTogetherNextEpisodeTarget = target ?? NextEpisodePlaybackTarget(
                seasonNumber: nextSeasonNumber,
                episodeNumber: nextEpisodeNumber,
                playbackContext: nextPlaybackContext,
                title: preview.seasonTitleOverride ?? preview.mediaTitle
            )
            hideNextEpisodeButton()
            handleEpisodeBrowserSelection(
                preview,
                reason: "next-episode-button-preview",
                watchTogetherTransitionID: transitionID
            )
            return
        }

        let watchTogetherCommit = commitWatchTogetherNextEpisode(
            seasonNumber: nextSeasonNumber,
            episodeNumber: nextEpisodeNumber,
            playbackContext: nextPlaybackContext,
            title: nextTitle
        )
        guard watchTogetherCommit.proceed else { return }
        let didBroadcastWatchTogether = watchTogetherCommit.didBroadcast

        if didBroadcastWatchTogether {
            if onRequestResolvedNextEpisode != nil {
                pendingResolvedNextEpisodeRequest = resolvedNextEpisodeTarget(
                    showID: showID,
                    seasonNumber: nextSeasonNumber,
                    episodeNumber: nextEpisodeNumber,
                    playbackContext: nextPlaybackContext,
                    title: nextTitle
                )
            } else if onRequestNextEpisode != nil {
                pendingNextEpisodeRequest = (nextSeasonNumber, nextEpisodeNumber)
            } else {
                let isAnimeEpisode: Bool
                if case .episode(_, _, _, _, _, let isAnime) = mediaInfo {
                    isAnimeEpisode = isAnime || nextPlaybackContext?.hasAnimeMediaId == true
                } else {
                    isAnimeEpisode = nextPlaybackContext?.hasAnimeMediaId == true
                }
                didDispatchNextEpisodeRequest = true
                var userInfo: [String: Any] = [
                    "tmdbId": showID,
                    "seasonNumber": nextSeasonNumber,
                    "episodeNumber": nextEpisodeNumber,
                    "isAnime": isAnimeEpisode,
                    "watchTogether": true
                ]
                if let nextPlaybackContext {
                    userInfo["playbackContext"] = nextPlaybackContext
                }
                NotificationCenter.default.post(
                    name: .requestNextEpisode,
                    object: nil,
                    userInfo: userInfo
                )
            }
        } else {
            if onRequestResolvedNextEpisode != nil {
#if os(iOS)

                if initialURL?.isFileURL == true,
                   DownloadManager.shared.completedEpisodeDownloadItem(
                       tmdbId: showID,
                       seasonNumber: nextSeasonNumber,
                       episodeNumber: nextEpisodeNumber,
                       playbackContext: nextPlaybackContext
                   ) == nil {
                    nextEpisodeButton.isEnabled = true
                    showPlayerNotice("The next episode isn't downloaded yet.")
                    return
                }
#endif
                pendingResolvedNextEpisodeRequest = resolvedNextEpisodeTarget(
                    showID: showID,
                    seasonNumber: nextSeasonNumber,
                    episodeNumber: nextEpisodeNumber,
                    playbackContext: nextPlaybackContext,
                    title: nextTitle
                )
            } else {
                pendingNextEpisodeRequest = (nextSeasonNumber, nextEpisodeNumber)
            }
        }
        hideNextEpisodeButton()
        closePlayer(allowWhilePlaybackLocked: true)
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
        let targetPosition = clampedPlaybackPosition(currentPosition + 85.0)
        Logger.shared.log("Skip85s: User tapped skip 85s at \(secondsText(currentPosition))s -> seeking to \(secondsText(targetPosition))s", type: "Skip")
        rendererSeek(to: targetPosition)
#if os(iOS)
        WatchTogetherCoordinator.shared.sendUserSeek(to: targetPosition, from: self)
#endif
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
        nextEpisodeButton.isEnabled = true
        nextEpisodeButton.isHidden = false
        videoContainer.bringSubviewToFront(nextEpisodeButton)
        bringTimedActionButtonsToFront()
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut]) {
            self.nextEpisodeButton.alpha = 1.0
        }
    }

    private func stageExperimentalNextEpisodeIfNeeded(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        progress: Double,
        threshold: Double
    ) {
        guard isMPVRenderer,
              isMetalMPVRenderer,
              ExperimentalFeatureState.canUseExperimentalMPVPlayback,
              ProfileSettingsStore.active.bool(forKey: ExperimentalFeatureState.mpvSmoothTransitionEnabledKey) else {
            return
        }

        let stageLead = 0.05
        let stageThreshold = max(0.50, threshold - stageLead)
        guard progress >= stageThreshold else { return }

        let key = nextEpisodeKey(seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        if let retryAfter = nextEpisodeStagingRetryAfterByKey[key], retryAfter > Date() {
            return
        }
        nextEpisodeStagingRetryAfterByKey[key] = nil
        resolveNextEpisodePreviewIfNeeded(seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        guard let target = nextEpisodePlaybackTarget(
            currentSeasonNumber: seasonNumber,
            currentEpisodeNumber: episodeNumber
        ) else {

            return
        }
        guard experimentalStagedNextEpisodeKey != key else { return }
        experimentalStagedNextEpisodeKey = key

        ExperimentalMPVPreloadManager.shared.noteNextEpisodeCandidate(
            showId: showId,
            seasonNumber: target.seasonNumber,
            episodeNumber: target.episodeNumber
        )
        prewarmNextEpisodeStreamIfPossible(
            showId: showId,
            currentSeasonNumber: seasonNumber,
            currentEpisodeNumber: episodeNumber,
            nextSeasonNumber: target.seasonNumber,
            nextEpisodeNumber: target.episodeNumber,
            nextEpisodeContext: target.playbackContext,
            attemptKey: key
        )
    }

    private func prewarmNextEpisodeStreamIfPossible(
        showId: Int,
        currentSeasonNumber: Int,
        currentEpisodeNumber: Int,
        nextSeasonNumber: Int,
        nextEpisodeNumber: Int,
        nextEpisodeContext: EpisodePlaybackContext?,
        attemptKey: String
    ) {

        guard ExperimentalFeatureState.mpvAdvancedPlaybackUnavailableReason == nil,
              ProfileSettingsStore.active.bool(forKey: ExperimentalFeatureState.mpvPreloadEnabledKey),
              ProfileSettingsStore.active.bool(forKey: ExperimentalFeatureState.mpvSmoothTransitionEnabledKey) else {
            markNextEpisodeStagingAttemptSkipped(key: attemptKey)
            return
        }

        let processInfo = ProcessInfo.processInfo
        guard !processInfo.isLowPowerModeEnabled,
              processInfo.thermalState != .serious,
              processInfo.thermalState != .critical else {
            Logger.shared.log("[PlayerVC.MPV] next-episode prewarm skipped reason=power-or-thermal show=\(showId) S\(nextSeasonNumber)E\(nextEpisodeNumber)", type: "MPV")
            markNextEpisodeStagingAttemptSkipped(key: attemptKey)
            return
        }

        guard AutoModeSettings.isEnabled(),
              playbackLaunchContext?.autoMode == true else {
            Logger.shared.log("[PlayerVC.MPV] next-episode prewarm skipped reason=not-auto-mode-launch show=\(showId) S\(nextSeasonNumber)E\(nextEpisodeNumber)", type: "MPV")
            markNextEpisodeStagingAttemptSkipped(key: attemptKey)
            return
        }

        if case .episode(_, _, _, _, _, let isAnime)? = mediaInfo, isAnime,
           PerformanceModeSettings.skipsAniListTraversalForAnimeDetails {
            Logger.shared.log("[PlayerVC.MPV] next-episode prewarm skipped reason=anilist-traversal-disabled show=\(showId)", type: "MPV")
            markNextEpisodeStagingAttemptSkipped(key: attemptKey)
            return
        }

        prewarmNextEpisodeFromAutoModeCandidates(
            showId: showId,
            currentSeasonNumber: currentSeasonNumber,
            currentEpisodeNumber: currentEpisodeNumber,
            nextSeasonNumber: nextSeasonNumber,
            nextEpisodeNumber: nextEpisodeNumber,
            nextEpisodeContext: nextEpisodeContext,
            attemptKey: attemptKey
        )
    }

    private func nextEpisodeLookupNumbers(
        currentSeasonNumber: Int,
        nextSeasonNumber: Int,
        nextEpisodeNumber: Int,
        nextEpisodeContext: EpisodePlaybackContext?
    ) -> (season: Int?, episode: Int?, context: EpisodePlaybackContext?)? {
        let isAnime = isAnimeContent()

        let nextContext = nextEpisodeContext ?? (
            !isAnime && nextSeasonNumber == currentSeasonNumber
                ? episodePlaybackContext?.forEpisodeNumber(nextEpisodeNumber)
                : nil
        )

        if isAnime && nextContext == nil {
            return nil
        }

        if let context = nextContext, context.isSpecial {
            guard let season = context.resolvedTMDBSeasonNumber,
                  let episode = context.resolvedTMDBEpisodeNumber else {
                return nil
            }
            return (season, episode, nextContext)
        }

        let season = nextContext?.resolvedTMDBSeasonNumber ?? nextSeasonNumber
        let episode = nextContext?.resolvedTMDBEpisodeNumber ?? nextEpisodeNumber
        return (season, episode, nextContext)
    }

    private func nextEpisodeChangesAnimeIdentity(
        nextSeasonNumber: Int,
        nextContext: EpisodePlaybackContext?
    ) -> Bool {
        guard isAnimeContent() else { return false }
        guard let nextContext else { return true }
        guard let currentContext = episodePlaybackContext else {
            return nextContext.localSeasonNumber != nextSeasonNumber
                || nextContext.hasAnimeMediaId
        }
        let currentProviderID = currentContext.positiveAniListMediaId
            ?? currentContext.anilistMediaId
        let nextProviderID = nextContext.positiveAniListMediaId
            ?? nextContext.anilistMediaId
        return currentContext.localSeasonNumber != nextContext.localSeasonNumber
            || currentProviderID != nextProviderID
            || currentContext.kitsuMediaId != nextContext.kitsuMediaId
            || currentContext.isSpecial != nextContext.isSpecial
    }

    private func stashStagedNextEpisodeRequest(
        resolution: NextEpisodePrestageResolution,
        localSeasonNumber: Int,
        localEpisodeNumber: Int,
        tmdbSeason: Int?,
        tmdbEpisode: Int?,
        context: EpisodePlaybackContext?
    ) {
        guard case .episode(let showId, let currentSeason, let currentEpisode, let showTitle, let posterURL, let mediaInfoIsAnime) = mediaInfo else { return }
        let isAnime = mediaInfoIsAnime || isAnimeHint == true || context?.hasAnimeMediaId == true
        let key = nextEpisodeKey(seasonNumber: currentSeason, episodeNumber: currentEpisode)
        guard experimentalStagedNextEpisodeKey == key else { return }
        nextEpisodeStagingRetryAfterByKey[key] = nil
        let preset = initialPreset ?? PlayerPreset.presets.first ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: [])
        let nextShowTitle = nextEpisodePreview?.seasonTitleOverride
            ?? nextEpisodePreview?.mediaTitle
            ?? showTitle
        let nextMediaInfo = MediaInfo.episode(
            showId: showId,
            seasonNumber: localSeasonNumber,
            episodeNumber: localEpisodeNumber,
            showTitle: nextShowTitle,
            showPosterURL: posterURL,
            isAnime: isAnime
        )
        let launchContext = PlaybackLaunchContext(
            sourceId: resolution.sourceId,
            sourceName: resolution.sourceName,
            sourceKind: resolution.sourceKind,
            autoMode: true,
            streamURL: resolution.streamURL.absoluteString,
            streamName: resolution.streamName,
            headers: resolution.headers,
            subtitles: resolution.subtitles,
            subtitleNames: resolution.subtitleNames,
            subtitleHeadersByURL: resolution.subtitleHeadersByURL,
            retryCount: 0,
            titleCandidates: resolution.titleCandidates,
            serviceContentHref: resolution.serviceContentHref,
            providerContentReference: resolution.providerContentReference
        )
        stagedNextEpisodeRequest = PlayerResolvedPlaybackRequest(
            url: resolution.streamURL,
            preset: preset,
            headers: resolution.headers,
            subtitles: resolution.subtitles.isEmpty ? nil : resolution.subtitles,
            subtitleNames: resolution.subtitleNames,
            subtitleHeadersByURL: resolution.subtitleHeadersByURL,
            mediaInfo: nextMediaInfo,
            imdbId: imdbId,
            isAnimeHint: isAnime,

            isAnimationContentHint: isAnimationContentHint,
            originalTMDBSeasonNumber: tmdbSeason,
            originalTMDBEpisodeNumber: tmdbEpisode,
            episodePlaybackContext: context,
            launchContext: launchContext,
            mediaYear: nextEpisodePreview?.mediaYear
                ?? servicesSelectionContext?.mediaYear
                ?? activePlaybackRequest?.mediaYear
        )
        stagedNextEpisodeRequestKey = key
        Logger.shared.log(
            "[PlayerVC.MPV] next-episode staged request ready key=\(key) source=\(resolution.sourceName) target={\(playbackURLSummary(resolution.streamURL))}",
            type: "MPV"
        )
    }

    private enum NextEpisodePrestageCandidate {
        case service(Service, contentHref: String?)
        case stremio(StremioAddon)
#if os(iOS) && !targetEnvironment(macCatalyst)
        case skyStream(SkyStreamProviderDescriptor)
        case nuvio(NuvioPluginScraper)
#endif

        var sourceId: String {
            switch self {
            case .service(let service, _): SourceHealth.serviceId(service)
            case .stremio(let addon): SourceHealth.stremioId(addon)
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .skyStream(let provider): provider.id
            case .nuvio(let scraper): scraper.id
#endif
            }
        }

        var sourceName: String {
            switch self {
            case .service(let service, _): service.metadata.sourceName
            case .stremio(let addon): addon.manifest.name
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .skyStream(let provider): provider.displayName
            case .nuvio(let scraper): scraper.displayName
#endif
            }
        }

        var sortIndex: Int64 {
            switch self {
            case .service(let service, _): service.sortIndex
            case .stremio(let addon): addon.sortIndex
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .skyStream(let provider): Int64(provider.sortIndex)
            case .nuvio: Int64.max
#endif
            }
        }
    }

    private struct NextEpisodePrestageResolution {
        let streamURL: URL
        let headers: [String: String]
        let subtitles: [String]
        let subtitleNames: [String]?
        let subtitleHeadersByURL: [String: [String: String]]?
        let streamName: String?
        let sourceId: String
        let sourceName: String
        let sourceKind: PlaybackSourceKind
        let titleCandidates: [String]
        let serviceContentHref: String?
        let providerContentReference: ProviderContentReference?
    }

    private func orderedNextEpisodePrestageCandidates(
        showId: Int,
        currentSeasonNumber: Int,
        currentEpisodeNumber: Int
    ) -> [NextEpisodePrestageCandidate] {
        let launch = playbackLaunchContext
        let recorded = ProgressManager.shared.findEpisode(
            showId: showId,
            season: currentSeasonNumber,
            episode: currentEpisodeNumber
        )
        var candidates: [NextEpisodePrestageCandidate] = ServiceManager.shared.activeServices.map { service in
            let sourceId = SourceHealth.serviceId(service)
            let launchHref = launch?.sourceId == sourceId ? launch?.serviceContentHref : nil
            let recordedHref = recorded?.lastServiceId == service.id ? recorded?.lastHref : nil
            return .service(service, contentHref: launchHref ?? recordedHref)
        }
        candidates.append(contentsOf: StremioAddonManager.shared.activeStreamAddons.map {
            .stremio($0)
        })
#if os(iOS) && !targetEnvironment(macCatalyst)
        if PlatformCapabilities.current.supportsSkyStreamPlugins {
            candidates.append(contentsOf: SkyStreamPluginManager.shared.providers
                .filter(\.isEnabled)
                .map { .skyStream($0) })
        }
        if PlatformCapabilities.current.supportsNuvioPlugins {
            candidates.append(contentsOf: NuvioPluginManager.shared.activeScrapers
                .map { .nuvio($0) })
        }
#endif

        candidates.removeAll {
            SourceHealthStore.shared.shouldSkipForAutoMode(sourceId: $0.sourceId)
        }

        candidates.sort { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName) == .orderedAscending
        }
        let candidateById = candidates.reduce(into: [String: NextEpisodePrestageCandidate]()) { result, candidate in

            if result[candidate.sourceId] == nil {
                result[candidate.sourceId] = candidate
            }
        }
        let orderedIds = AutoModeSourceSelection.orderedSelectedSourceIds(
            availableSourceIds: candidates.map(\.sourceId)
        )
        candidates = orderedIds.compactMap { candidateById[$0] }

        if let currentSourceId = launch?.sourceId,
           let current = candidateById[currentSourceId] {
            candidates.removeAll { $0.sourceId == currentSourceId }
            candidates.insert(current, at: 0)
        }
        return candidates
    }

    private func prewarmNextEpisodeFromAutoModeCandidates(
        showId: Int,
        currentSeasonNumber: Int,
        currentEpisodeNumber: Int,
        nextSeasonNumber: Int,
        nextEpisodeNumber: Int,
        nextEpisodeContext: EpisodePlaybackContext?,
        attemptKey: String
    ) {
        let changesAnimeIdentity = nextEpisodeChangesAnimeIdentity(
            nextSeasonNumber: nextSeasonNumber,
            nextContext: nextEpisodeContext
        )
        var candidates = orderedNextEpisodePrestageCandidates(
            showId: showId,
            currentSeasonNumber: currentSeasonNumber,
            currentEpisodeNumber: currentEpisodeNumber
        )
        if changesAnimeIdentity {

            candidates.removeAll { candidate in
                if case .service = candidate { return true }
                return false
            }
            Logger.shared.log(
                "[PlayerVC.MPV] cross-cour prewarm excluded service href reuse target=S\(nextSeasonNumber)E\(nextEpisodeNumber)",
                type: "MPV"
            )
        }
        guard !candidates.isEmpty else {
            Logger.shared.log("[PlayerVC.MPV] next-episode prewarm skipped reason=no-selected-candidates show=\(showId)", type: "MPV")
            markNextEpisodeStagingAttemptSkipped(key: attemptKey)
            return
        }

        let lookup = nextEpisodeLookupNumbers(
            currentSeasonNumber: currentSeasonNumber,
            nextSeasonNumber: nextSeasonNumber,
            nextEpisodeNumber: nextEpisodeNumber,
            nextEpisodeContext: nextEpisodeContext
        )
        let nextContext = lookup?.context ?? nextEpisodeContext
        let lookupSeason = lookup?.season ?? nextContext?.resolvedTMDBSeasonNumber ?? nextSeasonNumber
        let lookupEpisode = lookup?.episode ?? nextContext?.resolvedTMDBEpisodeNumber ?? nextEpisodeNumber
        let titleCandidates = nextEpisodePrestageTitleCandidates(
            changesAnimeIdentity: changesAnimeIdentity
        )
        let isAnime = isAnimeContent()
        let originalAudioLanguage = servicesOriginalAudioLanguage
        let currentIMDbId = imdbId

        nextEpisodeStagingTask?.cancel()
        nextEpisodeStagingTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let outcome = await OrderedSourceResolutionRunner.run(
                inputs: candidates,
                isCurrent: {
                    self.experimentalStagedNextEpisodeKey == attemptKey
                },
                resolve: { candidate in
                    Logger.shared.log("[PlayerVC.MPV] next-episode candidate resolving source=\(candidate.sourceName) target=S\(nextSeasonNumber)E\(nextEpisodeNumber)", type: "MPV")

                    let resolution: NextEpisodePrestageResolution?
                    switch candidate {
                    case .service(let service, let contentHref):
                        resolution = await self.resolveServicePrestageCandidate(
                            service: service,
                            knownContentHref: contentHref,
                            nextSeasonNumber: nextSeasonNumber,
                            nextEpisodeNumber: nextEpisodeNumber,
                            nextContext: nextContext,
                            lookupSeason: lookupSeason,
                            lookupEpisode: lookupEpisode,
                            isAnime: isAnime,
                            originalAudioLanguage: originalAudioLanguage,
                            titleCandidates: titleCandidates
                        )
                    case .stremio(let addon):
                        guard lookup != nil else {
                            Logger.shared.log("[PlayerVC.MPV] next-episode candidate failed source=\(candidate.sourceName) reason=no-episode-mapping", type: "MPV")
                            return nil
                        }
                        resolution = await self.resolveStremioPrestageCandidate(
                            addon: addon,
                            showId: showId,
                            imdbId: currentIMDbId,
                            lookupSeason: lookupSeason,
                            lookupEpisode: lookupEpisode,
                            nextContext: nextContext,
                            isAnime: isAnime,
                            originalAudioLanguage: originalAudioLanguage,
                            titleCandidates: titleCandidates
                        )
#if os(iOS) && !targetEnvironment(macCatalyst)
                    case .skyStream(let provider):
                        resolution = await self.resolveSkyStreamPrestageCandidate(
                            provider: provider,
                            lookupSeason: lookupSeason,
                            lookupEpisode: lookupEpisode,
                            nextContext: nextContext,
                            isAnime: isAnime,
                            originalAudioLanguage: originalAudioLanguage,
                            titleCandidates: titleCandidates
                        )
                    case .nuvio(let scraper):
                        guard lookup != nil else {
                            Logger.shared.log("[PlayerVC.MPV] next-episode candidate failed source=\(candidate.sourceName) reason=no-episode-mapping", type: "MPV")
                            return nil
                        }
                        resolution = await self.resolveNuvioPrestageCandidate(
                            scraper: scraper,
                            showId: showId,
                            lookupSeason: lookupSeason,
                            lookupEpisode: lookupEpisode,
                            isAnime: isAnime,
                            originalAudioLanguage: originalAudioLanguage,
                            titleCandidates: titleCandidates
                        )
#endif
                    }
                    return resolution
                },
                onAccepted: { _, resolution in
                    Logger.shared.log(
                        "[PlayerVC.MPV] next-episode candidate selected source=\(resolution.sourceName) target={\(self.playbackURLSummary(resolution.streamURL))}",
                        type: "MPV"
                    )
                    ExperimentalMPVPreloadManager.shared.prewarm(
                        url: resolution.streamURL,
                        headers: resolution.headers,
                        label: "next-S\(nextSeasonNumber)E\(nextEpisodeNumber)"
                    )
                    self.stashStagedNextEpisodeRequest(
                        resolution: resolution,
                        localSeasonNumber: nextSeasonNumber,
                        localEpisodeNumber: nextEpisodeNumber,
                        tmdbSeason: lookupSeason,
                        tmdbEpisode: lookupEpisode,
                        context: nextContext
                    )
                },
                discardStale: { resolution in
                    self.discardResolvedProviderPlayback(resolution)
                },
                onMiss: { candidate in
                    Logger.shared.log("[PlayerVC.MPV] next-episode candidate failed source=\(candidate.sourceName); trying next", type: "MPV")
                }
            )

            switch outcome {
            case .accepted:
                self.nextEpisodeStagingTask = nil
                return
            case .exhausted:
                self.nextEpisodeStagingTask = nil
                Logger.shared.log("[PlayerVC.MPV] next-episode prewarm exhausted selected candidates show=\(showId) S\(nextSeasonNumber)E\(nextEpisodeNumber)", type: "MPV")
                self.markNextEpisodeStagingAttemptSkipped(key: attemptKey)
            case .invalidated:
                return
            }
        }
    }

    private func resolveServicePrestageCandidate(
        service: Service,
        knownContentHref: String?,
        nextSeasonNumber: Int,
        nextEpisodeNumber: Int,
        nextContext: EpisodePlaybackContext?,
        lookupSeason: Int,
        lookupEpisode: Int,
        isAnime: Bool,
        originalAudioLanguage: String?,
        titleCandidates: [String],
        preferredStreamName: String? = nil
    ) async -> NextEpisodePrestageResolution? {
        let knownContentHref = Self.normalizedNonemptyString(knownContentHref)
        if let knownContentHref,
           let resolved = await resolveServicePrestageCandidate(
                service: service,
                contentHref: knownContentHref,
                nextSeasonNumber: nextSeasonNumber,
                nextEpisodeNumber: nextEpisodeNumber,
                nextContext: nextContext,
                lookupSeason: lookupSeason,
                lookupEpisode: lookupEpisode,
                isAnime: isAnime,
                originalAudioLanguage: originalAudioLanguage,
                titleCandidates: titleCandidates,
                preferredStreamName: preferredStreamName
           ) {
            return resolved
        }

        guard let discovered = await discoverServiceContentHref(
            service: service,
            titleCandidates: titleCandidates,
            seasonNumber: nextSeasonNumber,
            episodeNumber: nextEpisodeNumber,
            isAnime: isAnime
        ), discovered != knownContentHref else { return nil }

        return await resolveServicePrestageCandidate(
            service: service,
            contentHref: discovered,
            nextSeasonNumber: nextSeasonNumber,
            nextEpisodeNumber: nextEpisodeNumber,
            nextContext: nextContext,
            lookupSeason: lookupSeason,
            lookupEpisode: lookupEpisode,
            isAnime: isAnime,
            originalAudioLanguage: originalAudioLanguage,
            titleCandidates: titleCandidates,
            preferredStreamName: preferredStreamName
        )
    }

    private func resolveServicePrestageCandidate(
        service: Service,
        contentHref: String,
        nextSeasonNumber: Int,
        nextEpisodeNumber: Int,
        nextContext: EpisodePlaybackContext?,
        lookupSeason: Int,
        lookupEpisode: Int,
        isAnime: Bool,
        originalAudioLanguage: String?,
        titleCandidates: [String],
        preferredStreamName: String? = nil
    ) async -> NextEpisodePrestageResolution? {
        let jsController = JSController()
        jsController.loadScript(service.jsScript, service: service)
        let episodes = await fetchServiceEpisodes(jsController: jsController, service: service, contentHref: contentHref)
        guard !Task.isCancelled,
              let nextHref = Self.nextEpisodeHref(
                episodes: episodes,
                seasonNumber: nextSeasonNumber,
                episodeNumber: nextEpisodeNumber,
                context: nextContext,
                resolvedSeasonNumber: lookupSeason,
                resolvedEpisodeNumber: lookupEpisode,
                isAnime: isAnime
              ) else {
            return nil
        }

        let result = await fetchServiceStreams(jsController: jsController, service: service, episodeHref: nextHref)
        guard !Task.isCancelled,
              let selected = Self.selectPrewarmStream(
                streams: result.streams,
                sources: result.sources,
                sourceId: SourceHealth.serviceId(service),
                isAnime: isAnime,
                originalAudioLanguage: originalAudioLanguage,
                preferredLabel: preferredStreamName
              ),
              let streamURL = Self.httpURL(selected.url) else {
            return nil
        }

        let subtitles = Self.serviceSubtitleSelection(
            entries: (selected.subtitleEntries ?? []) + (result.subtitles ?? [])
        )
        let subtitleHeaders = selected.subtitleHeadersByURL?.filter {
            subtitles.urls.contains($0.key)
        }
        return NextEpisodePrestageResolution(
            streamURL: streamURL,
            headers: Self.mergedPlaybackHeaders(baseURL: service.metadata.baseUrl, custom: selected.headers),
            subtitles: subtitles.urls,
            subtitleNames: subtitles.names,
            subtitleHeadersByURL: subtitleHeaders?.isEmpty == false ? subtitleHeaders : nil,
            streamName: selected.label,
            sourceId: SourceHealth.serviceId(service),
            sourceName: service.metadata.sourceName,
            sourceKind: .service,
            titleCandidates: titleCandidates,
            serviceContentHref: contentHref,
            providerContentReference: nil
        )
    }

    private func resolveStremioPrestageCandidate(
        addon: StremioAddon,
        showId: Int,
        imdbId: String?,
        lookupSeason: Int,
        lookupEpisode: Int,
        nextContext: EpisodePlaybackContext?,
        isAnime: Bool,
        originalAudioLanguage: String?,
        titleCandidates: [String]
    ) async -> NextEpisodePrestageResolution? {
        let sourceId = SourceHealth.stremioId(addon)
        let streams = await StremioAddonManager.shared.fetchStreamsFromAddon(
            addon,
            tmdbId: showId,
            imdbId: imdbId,
            type: "series",
            season: lookupSeason,
            episode: lookupEpisode,
            anilistId: nextContext?.positiveAniListMediaId
                ?? nextContext?.anilistMediaId,
            playbackContext: nextContext,
            titleCandidates: titleCandidates
        )
        guard !Task.isCancelled else { return nil }
        let direct = streams.filter {
            $0.isDirectHTTP && !StreamLanguageFilter.shouldHide(
                stremio: $0,
                sourceId: sourceId,
                originalAudioLanguage: originalAudioLanguage,
                isAnime: isAnime
            )
        }
        let rankedStream = AutoModeStreamSelection.bestStremioStream(
            from: direct,
            sourceId: sourceId,
            streamsAreFiltered: true,
            isAnime: isAnime,
            originalAudioLanguage: originalAudioLanguage
        ) ?? (direct.count == 1 ? direct.first : nil)
        guard let stream = rankedStream,
              let streamURL = Self.httpURL(stream.url) else {
            return nil
        }

        let embeddedSubtitles = stream.subtitles ?? []
        let subtitlePairs = embeddedSubtitles.compactMap { subtitle -> (String, String)? in
            guard let url = subtitle.url, Self.httpURL(url) != nil else { return nil }
            return (url, subtitle.displayName)
        }
        return NextEpisodePrestageResolution(
            streamURL: streamURL,
            headers: Self.mergedUserAgentHeaders(custom: stream.proxyHeaders),
            subtitles: subtitlePairs.map(\.0),
            subtitleNames: subtitlePairs.isEmpty ? nil : subtitlePairs.map(\.1),
            subtitleHeadersByURL: nil,
            streamName: AutoModeStreamSelection.stremioStreamLabel(for: stream),
            sourceId: sourceId,
            sourceName: addon.manifest.name,
            sourceKind: .stremio,
            titleCandidates: titleCandidates,
            serviceContentHref: nil,
            providerContentReference: nil
        )
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    private func resolveNuvioPrestageCandidate(
        scraper: NuvioPluginScraper,
        showId: Int,
        lookupSeason: Int,
        lookupEpisode: Int,
        isAnime: Bool,
        originalAudioLanguage: String?,
        titleCandidates: [String]
    ) async -> NextEpisodePrestageResolution? {
        guard PlatformCapabilities.current.supportsNuvioPlugins,
              scraper.isRunnable,
              showId > 0 else {
            return nil
        }

        let streams = await NuvioPluginManager.shared.resolveStreams(
            scraperID: scraper.id,
            tmdbId: String(showId),
            mediaType: "tv",
            season: lookupSeason,
            episode: lookupEpisode
        )
        guard !Task.isCancelled else { return nil }

        let allowed = streams.filter { stream in
            !StreamLanguageFilter.shouldHide(
                languageHints: stream.languageHints,
                metadata: [stream.displayName] + stream.metadataHints,
                sourceId: scraper.id,
                originalAudioLanguage: originalAudioLanguage,
                isAnime: isAnime
            )
        }
        guard let chosen = AutoModeStreamSelection.bestNuvioStream(from: allowed),
              let streamURL = URL(string: chosen.url) else {
            return nil
        }

        let reference = NuvioProviderContentReference(
            sourceID: scraper.id,
            scraperID: scraper.id,
            tmdbID: String(showId),
            mediaType: "tv",
            season: lookupSeason,
            episode: lookupEpisode
        )
        guard reference.isStructurallyValid else { return nil }

        var headers: [String: String] = ["User-Agent": URLSession.randomUserAgent]
        for (key, value) in chosen.sanitizedHeaders ?? [:] {
            headers[key] = value
        }

        return NextEpisodePrestageResolution(
            streamURL: streamURL,
            headers: headers,
            subtitles: chosen.subtitleURLs,
            subtitleNames: chosen.subtitleNames,
            subtitleHeadersByURL: chosen.subtitleHeadersByURL,
            streamName: chosen.displayName,
            sourceId: scraper.id,
            sourceName: scraper.displayName,
            sourceKind: .nuvio,
            titleCandidates: titleCandidates,
            serviceContentHref: nil,
            providerContentReference: .nuvio(reference)
        )
    }

    private func resolveSkyStreamPrestageCandidate(
        provider: SkyStreamProviderDescriptor,
        lookupSeason: Int,
        lookupEpisode: Int,
        nextContext: EpisodePlaybackContext?,
        isAnime: Bool,
        originalAudioLanguage: String?,
        titleCandidates: [String]
    ) async -> NextEpisodePrestageResolution? {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins,
              provider.isEnabled,
              let title = titleCandidates.first,
              !title.isEmpty else {
            return nil
        }
        let absoluteCandidates = [
            nextContext?.animeAbsoluteEpisodeNumber,
            nextContext?.resolvedTMDBEpisodeNumber
        ].compactMap { $0 }
        let target = SkyStreamResolutionTarget(
            kind: .episode,
            title: title,
            aliases: Array(titleCandidates.dropFirst()),
            year: nil,
            season: lookupSeason,
            episode: lookupEpisode,
            absoluteEpisodeCandidates: absoluteCandidates,
            isAnime: isAnime,
            isSpecial: nextContext?.isSpecial == true,
            wantsDubbed: nil,

            requiresExactIdentity: true
        )

        do {
            let values = try await SkyStreamResolver.shared.resolve(
                sourceID: provider.id,
                target: target,
                mode: .autoMode,
                originalAudioLanguage: originalAudioLanguage
            )
            guard !Task.isCancelled,
                  let resolved = values.first,
                  resolved.provider.id == provider.id,
                  resolved.contentReference.sourceID == provider.id,
                  !StreamLanguageFilter.shouldHide(
                    languageHints: [],
                    metadata: [resolved.displayName],
                    sourceId: provider.id,
                    originalAudioLanguage: originalAudioLanguage,
                    isAnime: isAnime
                  ) else {
                return nil
            }
            return makeSkyStreamPlaybackResolution(
                resolved,
                titleCandidates: titleCandidates,
                traceID: "next-\(playbackTraceID)"
            )
        } catch is CancellationError {
            return nil
        } catch {
            Logger.shared.log(
                "SkyStream: next-episode staging failed source=\(provider.id) errorType=\(String(reflecting: type(of: error)))",
                type: "MPV"
            )
            return nil
        }
    }

    private func makeSkyStreamPlaybackResolution(
        _ resolved: SkyStreamResolvedStream,
        titleCandidates: [String],
        traceID: String
    ) -> NextEpisodePrestageResolution? {
        guard let proxyURL = MPVHeaderProxy.shared.makeSkyStreamProxyURL(
            for: resolved.playback,
            traceID: traceID
        ) else {
            return nil
        }
        guard let subtitleProxyURLs = MPVHeaderProxy.shared.skyStreamSubtitleProxyURLs(
            for: resolved.playback,
            streamProxyURL: proxyURL
        ) else {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
            return nil
        }
        if Task.isCancelled {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
            return nil
        }

        let descriptor = resolved.playback
        let subtitles = descriptor.subtitles.compactMap { subtitle -> String? in
                var components = URLComponents(
                    url: subtitle.remoteURL.url.absoluteURL,
                    resolvingAgainstBaseURL: false
                )
                components?.fragment = nil
                let key = components?.url?.absoluteString
                    ?? subtitle.remoteURL.url.absoluteURL.absoluteString
                return subtitleProxyURLs[key]?.absoluteString
        }
        guard subtitles.count == descriptor.subtitles.count else {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
            return nil
        }
        registerMPVHeaderProxyURL(proxyURL)
        let subtitleNames = descriptor.subtitles.map {
            $0.label ?? $0.language ?? "Subtitle"
        }
        return NextEpisodePrestageResolution(
            streamURL: proxyURL,
            headers: [:],
            subtitles: subtitles,
            subtitleNames: subtitleNames.isEmpty ? nil : subtitleNames,
            subtitleHeadersByURL: nil,
            streamName: resolved.displayName,
            sourceId: resolved.provider.id,
            sourceName: resolved.provider.displayName,
            sourceKind: .skyStream,
            titleCandidates: titleCandidates,
            serviceContentHref: nil,
            providerContentReference: .skyStream(resolved.contentReference)
        )
    }
#endif

    private func discoverServiceContentHref(
        service: Service,
        titleCandidates: [String],
        seasonNumber: Int,
        episodeNumber: Int,
        isAnime: Bool
    ) async -> String? {
        let queries = servicePrestageSearchQueries(
            titleCandidates: titleCandidates,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            isAnime: isAnime
        )
        var results: [SearchItem] = []
        var seenHrefs = Set<String>()

        for query in queries.prefix(4) {
            guard !Task.isCancelled else { return nil }
            let found = await ServiceManager.shared.searchSingleActiveService(service: service, query: query)
            results.append(contentsOf: found.filter { seenHrefs.insert($0.href).inserted })
            if let exact = bestServicePrestageResult(results, titleCandidates: titleCandidates), exact.score >= 0.93 {
                return exact.result.href
            }
        }
        guard let best = bestServicePrestageResult(results, titleCandidates: titleCandidates), best.score >= 0.85 else {
            return nil
        }
        return best.result.href
    }

    private func fetchServiceEpisodes(
        jsController: JSController,
        service: Service,
        contentHref: String
    ) async -> [EpisodeLink] {
        await withCheckedContinuation { continuation in
            jsController.fetchEpisodesJS(url: contentHref, module: service) { [jsController] episodes in
                _ = jsController
                continuation.resume(returning: episodes)
            }
        }
    }

    private func fetchServiceStreams(
        jsController: JSController,
        service: Service,
        episodeHref: String
    ) async -> ServiceStreamExtractionResult {
        await withCheckedContinuation { continuation in
            jsController.fetchStreamUrlJS(
                episodeUrl: episodeHref,
                softsub: service.metadata.softsub ?? false,
                module: service
            ) { [jsController] result in
                _ = jsController
                continuation.resume(returning: result)
            }
        }
    }

    private func nextEpisodePrestageTitleCandidates(
        changesAnimeIdentity: Bool
    ) -> [String] {
        var values: [String] = []
        if let preview = nextEpisodePreview {
            values.append(contentsOf: [
                preview.seasonTitleOverride,
                preview.animeSeasonTitle,
                Optional(preview.mediaTitle),
                preview.originalTitle
            ].compactMap { $0 })
        }
        if !changesAnimeIdentity {
            values.append(contentsOf: playbackLaunchContext?.titleCandidates ?? [])
            if case .episode(_, _, _, let showTitle?, _, _) = mediaInfo {
                values.append(showTitle)
            }
            values.append(playerDisplayTitle())
        }

        var seen = Set<String>()
        return values.compactMap(Self.normalizedNonemptyString)
            .map(Self.strippingEpisodeSuffix)
            .filter { !$0.isEmpty }
            .filter { seen.insert(Self.normalizedTitleKey($0)).inserted }
    }

    private func servicePrestageSearchQueries(
        titleCandidates: [String],
        seasonNumber: Int,
        episodeNumber: Int,
        isAnime: Bool
    ) -> [String] {
        var queries: [String] = []
        for title in titleCandidates.prefix(2) {
            queries.append(isAnime ? "\(title) E\(episodeNumber)" : "\(title) S\(seasonNumber)E\(episodeNumber)")
            queries.append(title)
        }
        var seen = Set<String>()
        return queries.filter { seen.insert(Self.normalizedTitleKey($0)).inserted }
    }

    private func bestServicePrestageResult(
        _ results: [SearchItem],
        titleCandidates: [String]
    ) -> (result: SearchItem, score: Double)? {
        results.enumerated().compactMap { index, result -> (Int, SearchItem, Double)? in
            let score = titleCandidates.map {
                AlgorithmManager.shared.calculateSimilarity(original: $0, result: result.title)
            }.max() ?? 0
            return (index, result, score)
        }
        .max { lhs, rhs in
            if abs(lhs.2 - rhs.2) < 0.0001 { return lhs.0 > rhs.0 }
            return lhs.2 < rhs.2
        }
        .map { ($0.1, $0.2) }
    }

    private static func nextEpisodeHref(
        episodes: [EpisodeLink],
        seasonNumber: Int,
        episodeNumber: Int,
        context: EpisodePlaybackContext?,
        resolvedSeasonNumber: Int?,
        resolvedEpisodeNumber: Int?,
        isAnime: Bool
    ) -> String? {
        guard !episodes.isEmpty else { return nil }

        var seasons: [[EpisodeLink]] = []
        var current: [EpisodeLink] = []
        var last = 0
        for ep in episodes {
            if ep.number == 1 || ep.number <= last {
                if !current.isEmpty { seasons.append(current); current = [] }
            }
            current.append(ep)
            last = ep.number
        }
        if !current.isEmpty { seasons.append(current) }

        let index = seasonNumber - 1
        if index >= 0, index < seasons.count,
           let match = seasons[index].first(where: { $0.number == episodeNumber }) {
            return match.href
        }
        guard isAnime,
              let context,
              !context.isSpecial,
              let seasonEpisodeCount = context.animeSeasonEpisodeCount,
              seasonEpisodeCount > 0 else {

            if seasons.count <= 1, let match = episodes.first(where: { $0.number == episodeNumber }) {
                return match.href
            }
            return nil
        }

        let stats = sourceEpisodeListStats(episodes)
        if stats.maxNumber > seasonEpisodeCount {
            let candidates = nextEpisodeBundledNumberCandidates(
                context: context,
                resolvedSeasonNumber: resolvedSeasonNumber,
                resolvedEpisodeNumber: resolvedEpisodeNumber,
                localEpisodeNumber: episodeNumber
            )
            if let bundled = firstUniqueEpisodeHref(episodes: episodes, numbers: candidates) {
                return bundled
            }
        }

        if stats.count <= seasonEpisodeCount,
           stats.maxNumber <= seasonEpisodeCount,
           let singleSeason = uniqueEpisodeHref(episodes: episodes, number: episodeNumber) {
            return singleSeason
        }

        if seasonNumber <= 1,
           let match = episodes.first(where: { $0.number == episodeNumber }) {
            return match.href
        }
        return nil
    }

    private static func sourceEpisodeListStats(_ episodes: [EpisodeLink]) -> (count: Int, maxNumber: Int) {
        let numbers = episodes.map(\.number)
        return (numbers.count, numbers.max() ?? 0)
    }

    private static func nextEpisodeBundledNumberCandidates(
        context: EpisodePlaybackContext,
        resolvedSeasonNumber: Int?,
        resolvedEpisodeNumber: Int?,
        localEpisodeNumber: Int
    ) -> [Int] {
        var numbers: [Int] = []
        if let absoluteEpisode = context.animeAbsoluteEpisodeNumber {
            numbers.append(absoluteEpisode)
        }
        if resolvedSeasonNumber == 1, let resolvedEpisodeNumber {
            numbers.append(resolvedEpisodeNumber)
        }

        var seen = Set<Int>()
        return numbers
            .filter { $0 > 0 && $0 != localEpisodeNumber }
            .filter { seen.insert($0).inserted }
    }

    private static func firstUniqueEpisodeHref(episodes: [EpisodeLink], numbers: [Int]) -> String? {
        for number in numbers {
            if let href = uniqueEpisodeHref(episodes: episodes, number: number) {
                return href
            }
        }
        return nil
    }

    private static func uniqueEpisodeHref(episodes: [EpisodeLink], number: Int) -> String? {
        let matches = episodes.filter { $0.number == number }
        guard matches.count == 1 else { return nil }
        return matches.first?.href
    }

    private static func selectPrewarmStream(
        streams: [String]?,
        sources: [[String: Any]]?,
        sourceId: String,
        isAnime: Bool = false,
        originalAudioLanguage: String?,
        preferredLabel: String? = nil
    ) -> (url: String, headers: [String: String]?, label: String, subtitleEntries: [String]?, subtitleHeadersByURL: [String: [String: String]]?)? {
        var candidates: [(url: String, headers: [String: String]?, label: String, scoreLabel: String, subtitleEntries: [String]?, subtitleHeadersByURL: [String: [String: String]]?)] = []
        if let sources = sources, !sources.isEmpty {
            for (index, source) in sources.enumerated() {
                guard let raw = ["streamUrl", "url", "file", "src", "link", "stream"]
                    .lazy
                    .compactMap({ source[$0] as? String })
                    .first(where: { !$0.isEmpty }) else { continue }
                let displayLabel = stringValues(
                    in: source,
                    keys: ["title", "name", "label", "quality"]
                ).first ?? "Stream \(index + 1)"
                let metadata = stringValues(
                    in: source,
                    keys: ["title", "name", "label", "quality", "provider", "type", "filename", "file", "streamName", "server"]
                )
                let languageHints = stringValues(
                    in: source,
                    keys: ["lang", "language", "languages", "audioLanguage", "audioLanguages", "dubLanguage", "dubLanguages"]
                )
                guard !StreamLanguageFilter.shouldHide(
                    languageHints: languageHints,
                    metadata: metadata + [raw],
                    sourceId: sourceId,
                    originalAudioLanguage: originalAudioLanguage,
                    isAnime: isAnime
                ) else { continue }
                candidates.append((
                    raw,
                    headersFromAny(source["headers"]),
                    displayLabel,
                    (metadata + [raw]).joined(separator: " "),
                    serviceSubtitleEntries(in: source),
                    serviceSubtitleHeaders(in: source)
                ))
            }
        } else if let streams = streams {
            var index = 0
            var unnamedCount = 1
            while index < streams.count {
                let entry = streams[index]
                let raw: String
                let label: String
                if httpURL(entry) != nil {
                    raw = entry
                    label = "Stream \(unnamedCount)"
                    unnamedCount += 1
                    index += 1
                } else if index + 1 < streams.count,
                          httpURL(streams[index + 1]) != nil {
                    raw = streams[index + 1]
                    label = normalizedNonemptyString(entry) ?? "Stream"
                    index += 2
                } else {
                    index += 1
                    continue
                }
                guard !StreamLanguageFilter.shouldHide(
                    languageHints: [],
                    metadata: [label, raw],
                    sourceId: sourceId,
                    originalAudioLanguage: originalAudioLanguage,
                    isAnime: isAnime
                ) else { continue }
                candidates.append((raw, nil, label, "\(label) \(raw)", nil, nil))
            }
        }

        guard !candidates.isEmpty else { return nil }
        if let preferredLabel = normalizedNonemptyString(preferredLabel) {
            let preferredKey = normalizedTitleKey(preferredLabel)
            if let matched = candidates.first(where: {
                normalizedTitleKey($0.label) == preferredKey
            }) {
                return (
                    matched.url,
                    matched.headers,
                    matched.label,
                    matched.subtitleEntries,
                    matched.subtitleHeadersByURL
                )
            }
        }
        if candidates.count == 1 {
            let candidate = candidates[0]
            return (candidate.url, candidate.headers, candidate.label, candidate.subtitleEntries, candidate.subtitleHeadersByURL)
        }

        let preference = AutoModeQualityPreference.current
        guard preference.usesAutomaticSelection,
              candidates.contains(where: { AutoModeStreamSelection.streamLabelHasDetectedQuality($0.scoreLabel) }) else {
            return nil
        }

        let best = candidates.enumerated().max {
            AutoModeStreamSelection.streamPreferenceScore(label: $0.element.scoreLabel, preference: preference, index: $0.offset)
                < AutoModeStreamSelection.streamPreferenceScore(label: $1.element.scoreLabel, preference: preference, index: $1.offset)
        }?.element
        guard let best else { return nil }
        return (best.url, best.headers, best.label, best.subtitleEntries, best.subtitleHeadersByURL)
    }

    private static func serviceSubtitleEntries(in source: [String: Any]) -> [String]? {
        var entries: [String] = []
        if let subtitle = normalizedNonemptyString(source["subtitle"] as? String) {
            entries.append(subtitle)
        }
        if let subtitles = source["subtitles"] as? [String] {
            entries.append(contentsOf: subtitles.compactMap(normalizedNonemptyString))
        }
        if let subtitles = source["subtitles"] as? [[String: Any]] {
            for (index, subtitle) in subtitles.enumerated() {
                guard let url = firstStringValue(in: subtitle, keys: ["url", "file", "src"]),
                      httpURL(url) != nil else { continue }
                let name = firstStringValue(in: subtitle, keys: ["title", "name", "label", "lang", "language"])
                    ?? "Subtitle \(index + 1)"
                entries.append(contentsOf: [name, url])
            }
        }
        return entries.isEmpty ? nil : entries
    }

    private static func serviceSubtitleHeaders(in source: [String: Any]) -> [String: [String: String]]? {
        guard let subtitles = source["subtitles"] as? [[String: Any]] else { return nil }
        var result: [String: [String: String]] = [:]
        for subtitle in subtitles {
            guard let url = firstStringValue(in: subtitle, keys: ["url", "file", "src"]),
                  httpURL(url) != nil,
                  let headers = headersFromAny(subtitle["headers"]),
                  !headers.isEmpty else { continue }
            result[url] = headers
        }
        return result.isEmpty ? nil : result
    }

    private static func firstStringValue(in source: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { normalizedNonemptyString(source[$0] as? String) }.first
    }

    private static func serviceSubtitleSelection(entries: [String]) -> (urls: [String], names: [String]?) {
        var pairs: [(url: String, name: String)] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if httpURL(entry) != nil {
                pairs.append((entry, "Subtitle \(pairs.count + 1)"))
                index += 1
                continue
            }
            let nextIndex = index + 1
            if nextIndex < entries.count {
                let url = entries[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if httpURL(url) != nil {
                    pairs.append((url, entry.isEmpty ? "Subtitle \(pairs.count + 1)" : entry))
                    index += 2
                    continue
                }
            }
            index += 1
        }

        var seen = Set<String>()
        pairs = pairs.filter { seen.insert($0.url).inserted }
        return (pairs.map(\.url), pairs.isEmpty ? nil : pairs.map(\.name))
    }

    private static func httpURL(_ rawValue: String?) -> URL? {
        guard let value = normalizedNonemptyString(rawValue),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private static func normalizedNonemptyString(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func strippingEpisodeSuffix(_ title: String) -> String {
        let patterns = [
            #"(?i)\s*-?\s*S\d{1,3}E\d{1,4}$"#,
            #"(?i)\s*-?\s*E\d{1,4}$"#,
            #"(?i)\s*episode\s+\d{1,4}$"#
        ]
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in patterns {
            if let range = result.range(of: pattern, options: .regularExpression) {
                result.removeSubrange(range)
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedTitleKey(_ title: String) -> String {
        title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringValues(in source: [String: Any], keys: [String]) -> [String] {
        keys.flatMap { key -> [String] in
            guard let rawValue = source[key] else { return [] }
            if let value = streamMetadataString(from: rawValue) {
                return [value]
            }
            if let values = rawValue as? [Any] {
                return values.compactMap(streamMetadataString(from:))
            }
            return []
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    private static func streamMetadataString(from value: Any) -> String? {
        if value is Bool || value is NSNull { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func headersFromAny(_ value: Any?) -> [String: String]? {
        guard let value, !(value is NSNull) else { return nil }
        if let headers = value as? [String: String] { return headers }
        if let dict = value as? [String: Any] {
            var out: [String: String] = [:]
            for (key, val) in dict {
                if let s = val as? String { out[key] = s }
                else if let n = val as? NSNumber { out[key] = n.stringValue }
                else if !(val is NSNull) { out[key] = String(describing: val) }
            }
            return out.isEmpty ? nil : out
        }
        return nil
    }

    private static func mergedPlaybackHeaders(baseURL: String, custom: [String: String]?) -> [String: String] {
        var finalHeaders: [String: String] = [
            "Origin": baseURL,
            "Referer": baseURL,
            "User-Agent": URLSession.randomUserAgent
        ]
        if let custom {
            for (k, v) in custom { finalHeaders[k] = v }
            if finalHeaders["User-Agent"] == nil {
                finalHeaders["User-Agent"] = URLSession.randomUserAgent
            }
        }
        return finalHeaders
    }

    private static func mergedUserAgentHeaders(custom: [String: String]?) -> [String: String] {
        var finalHeaders: [String: String] = ["User-Agent": URLSession.randomUserAgent]
        if let custom {
            for (k, v) in custom { finalHeaders[k] = v }
        }
        return finalHeaders
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
        guard !didDispatchNextEpisodeRequest else { return }

        if let target = pendingResolvedNextEpisodeRequest,
           let onRequestResolvedNextEpisode {
            didDispatchNextEpisodeRequest = true
            pendingResolvedNextEpisodeRequest = nil
            pendingNextEpisodeRequest = nil
            onRequestResolvedNextEpisode(target)
            return
        }

        guard let request = pendingNextEpisodeRequest else { return }

        didDispatchNextEpisodeRequest = true
        pendingNextEpisodeRequest = nil
        onRequestNextEpisode?(request.seasonNumber, request.episodeNumber)
    }

    private func resolvedNextEpisodeTarget(
        showID: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        playbackContext: EpisodePlaybackContext?,
        title: String?
    ) -> ResolvedNextEpisodeTarget {
        let showTitle: String
        let showPosterURL: String?
        let mediaIsAnime: Bool
        if case .episode(_, _, _, let currentTitle, let posterURL, let isAnime) = mediaInfo {
            showTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? title!
                : (currentTitle ?? "")
            showPosterURL = posterURL
            mediaIsAnime = isAnime || isAnimeHint == true || playbackContext?.hasAnimeMediaId == true
        } else {
            showTitle = title ?? ""
            showPosterURL = nil
            mediaIsAnime = isAnimeHint == true || playbackContext?.hasAnimeMediaId == true
        }
        let episode = TMDBEpisode(
            id: Int("\(showID)\(seasonNumber)\(episodeNumber)") ?? showID,
            name: "",
            overview: nil,
            stillPath: nil,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            airDate: nil,
            runtime: nil,
            voteAverage: 0,
            voteCount: 0
        )
        return ResolvedNextEpisodeTarget(
            showID: showID,
            episode: episode,
            playbackContext: playbackContext,
            mediaTitle: showTitle,
            seasonTitleOverride: mediaIsAnime ? showTitle : nil,
            originalTitle: nil,
            posterURL: showPosterURL,
            imdbID: imdbId,
            isAnime: mediaIsAnime,
            isAnimation: isAnimationContentHint ?? false,
            mediaYear: servicesSelectionContext?.mediaYear
                ?? activePlaybackRequest?.mediaYear
        )
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

    func retainEphemeralProxyOwnership(_ ownership: PlaybackProxySessionOwnership?) {
        let replacementLease = ownership?.acquireLease()
        ephemeralProxySessionLease?.release()
        ephemeralProxySessionLease = replacementLease
    }

    private func releaseEphemeralProxyOwnership() {
        ephemeralProxySessionLease?.release()
        ephemeralProxySessionLease = nil
    }

    private static func invalidateAbandonedProxyOwnership(
        _ request: PlayerResolvedPlaybackRequest
    ) {
        request.launchContext?.ephemeralProxyOwnership?.invalidate()
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard request.launchContext?.sourceKind == .skyStream else { return }
        MPVHeaderProxy.shared.invalidateSession(for: request.url)
#endif
    }

#if !os(tvOS)
    private func registerMPVHeaderProxyURL(_ proxyURL: URL) {
        activeMPVHeaderProxyURLs.insert(proxyURL)
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    private func configureSkyStreamRouteRejectionRecovery(
        for streamProxyURL: URL,
        expectedLoadGeneration: Int
    ) {
        guard let context = playbackLaunchContext,
              context.sourceKind == .skyStream,
              context.streamURL == streamProxyURL.absoluteString,
              let providerReference = context.providerContentReference,
              providerReference.kind == .skyStream,
              providerReference.sourceID == context.sourceId,
              let reference = providerReference.skyStream,
              reference.sourceID == context.sourceId,
              reference.isStructurallyValid,
              skyStreamReferenceMatchesCurrentMedia(reference) else {
            return
        }

        let attached = MPVHeaderProxy.shared.setSkyStreamRouteRejectionHandler(
            for: streamProxyURL
        ) { [weak self] challengedURL, statusCode, isInteractiveChallenge in
            DispatchQueue.main.async { [weak self] in
                self?.handleMPVHeaderProxyCloudflareChallenge(
                    challengeURL: challengedURL,
                    rejectedCookieHeader: nil,
                    isInteractiveChallenge: isInteractiveChallenge,
                    statusCode: statusCode,
                    originalURL: streamProxyURL,
                    originalHeaders: [:],
                    expectedLoadGeneration: expectedLoadGeneration
                )
            }
        }
        guard attached else {
            Logger.shared.log(
                "SkyStream: typed playback recovery handler could not attach source=\(context.sourceId)",
                type: "MPV"
            )
            return
        }
        registerMPVHeaderProxyURL(streamProxyURL)
    }
#endif

    private func releaseMPVHeaderProxySessions(retaining retainedURL: URL? = nil) {
        let staleURLs = activeMPVHeaderProxyURLs.filter { $0 != retainedURL }
        let invalidatesStagedRequest = stagedNextEpisodeRequest.map { staged in
            staleURLs.contains(staged.url)
        } ?? false
        for proxyURL in staleURLs {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
            activeMPVHeaderProxyURLs.remove(proxyURL)
        }
        if invalidatesStagedRequest {
            stagedNextEpisodeRequest = nil
            stagedNextEpisodeRequestKey = nil
            experimentalStagedNextEpisodeKey = nil
            Logger.shared.log(
                "[PlayerVC.MPV] cleared staged next-episode request because its proxy session ended",
                type: "MPV"
            )
        }
    }

    private func preparePlayerHeaderProxyIfNeeded(originalURL: URL, headers: [String: String]?) -> (url: URL, headers: [String: String]?) {
        if isMPVRenderer {
            return prepareMPVHeaderProxyIfNeeded(originalURL: originalURL, headers: headers)
        }
        return (originalURL, headers)
    }

    private func buildProxyHeaders(for _: URL, baseHeaders: [String: String]) -> [String: String] {

        return baseHeaders
    }

    private func isRemoteHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func prepareMPVHeaderProxyIfNeeded(originalURL: URL, headers: [String: String]?) -> (url: URL, headers: [String: String]?) {
        guard isRemoteHTTPURL(originalURL), !isLocalProxyURL(originalURL) else { return (originalURL, headers) }

        let proxyHeaders = buildProxyHeaders(for: originalURL, baseHeaders: headers ?? [:])
        if forceHeaderProxyForStartup || (
            isMetalMPVRenderer
                && ExperimentalMPVPreloadManager.shared.shouldUsePlaybackProxy(for: originalURL)
        ) {
            guard let proxyURL = makeMPVHeaderProxyURL(
                for: originalURL,
                headers: proxyHeaders
            ) else {
                Logger.shared.log("[PlayerVC.PlaybackStart] MPV warmup proxy URL creation failed; using direct HTTP target={\(playbackURLSummary(originalURL))} headerKeys=[\(proxyHeaders.keys.sorted().joined(separator: ","))]", type: "MPV")
                return (originalURL, proxyHeaders.isEmpty ? headers : proxyHeaders)
            }

            registerMPVHeaderProxyURL(proxyURL)
            let reason = forceHeaderProxyForStartup ? "coordinator-engine-fallback" : "warmup"
            Logger.shared.log("[PlayerVC.PlaybackStart] MPV header proxy activated reason=\(reason) target={\(playbackURLSummary(originalURL))} headerKeys=[\(proxyHeaders.keys.sorted().joined(separator: ","))]", type: "MPV")
            return (proxyURL, nil)
        }

        let proxySkipReason = isMetalMPVRenderer
            ? (ExperimentalMPVPreloadManager.shared.playbackProxySkipReason(for: originalURL) ?? "not-requested")
            : "renderer-not-moltenvk-active"
        Logger.shared.log("[PlayerVC.PlaybackStart] MPV direct HTTP playback target={\(playbackURLSummary(originalURL))} warmupProxySkipped=\(proxySkipReason) renderer=\(mpvRendererName) headerKeys=[\(proxyHeaders.keys.sorted().joined(separator: ","))]", type: "MPV")
        return (originalURL, proxyHeaders.isEmpty ? headers : proxyHeaders)
    }

    private func makeMPVHeaderProxyURL(
        for originalURL: URL,
        headers: [String: String],
        expectedLoadGeneration: Int? = nil
    ) -> URL? {
        let recoveryLoadGeneration = expectedLoadGeneration ?? playbackLoadGeneration
        return MPVHeaderProxy.shared.makeProxyURL(
            for: originalURL,
            headers: headers,
            logType: "MPV",
            traceID: playbackTraceID,
            onConfirmedCloudflareChallenge: { [weak self] challengeURL, rejectedCookieHeader, isInteractiveChallenge, statusCode in
                DispatchQueue.main.async { [weak self] in
                    self?.handleMPVHeaderProxyCloudflareChallenge(
                        challengeURL: challengeURL,
                        rejectedCookieHeader: rejectedCookieHeader,
                        isInteractiveChallenge: isInteractiveChallenge,
                        statusCode: statusCode,
                        originalURL: originalURL,
                        originalHeaders: headers,
                        expectedLoadGeneration: recoveryLoadGeneration
                    )
                }
            }
        )
    }

    private func handleMPVHeaderProxyCloudflareChallenge(
        challengeURL: URL,
        rejectedCookieHeader: String?,
        isInteractiveChallenge: Bool,
        statusCode: Int,
        originalURL: URL,
        originalHeaders: [String: String],
        expectedLoadGeneration: Int
    ) {
        guard playbackLoadGeneration == expectedLoadGeneration,
              !playbackFailureHandled,
              !cloudflareStartupRecoveryInProgress,
              !isClosing,
              let preset = initialPreset else { return }

        let hasRefreshableProviderReference: Bool = {
            guard let context = playbackLaunchContext else { return false }
            switch context.sourceKind {
            case .service:
                return context.serviceContentHref?.isEmpty == false
            case .stremio:
                return false
            case .skyStream:
#if os(iOS) && !targetEnvironment(macCatalyst)
                guard let reference = context.providerContentReference else { return false }
                return reference.kind == .skyStream
                    && reference.sourceID == context.sourceId
                    && reference.skyStream?.isStructurallyValid == true
#else
                return false
#endif
            case .nuvio:
#if os(iOS) && !targetEnvironment(macCatalyst)
                guard let reference = context.providerContentReference else { return false }
                return reference.kind == .nuvio
                    && reference.sourceID == context.sourceId
                    && reference.nuvio?.isStructurallyValid == true
#else
                return false
#endif
            }
        }()
        if hasRefreshableProviderReference {
            guard beginMediaSourceRefreshAttempt() else {
                handleUnrecoverableMediaSourceRejection(
                    "The media source could not be refreshed after repeated HTTP \(statusCode) responses."
                )
                return
            }
            refreshCurrentProviderPlaybackSource(
                challengeURL: challengeURL,
                rejectedCookieHeader: rejectedCookieHeader,
                isInteractiveChallenge: isInteractiveChallenge,
                statusCode: statusCode,
                originalURL: originalURL,
                expectedLoadGeneration: expectedLoadGeneration,
                preset: preset
            )
            return
        }

        guard isInteractiveChallenge else {
            handleUnrecoverableMediaSourceRejection(
                "The media host rejected this URL (HTTP \(statusCode)) and the source could not be refreshed."
            )
            return
        }

        cloudflareStartupRecoveryInProgress = true
        playbackFailureHandled = true
        playbackStartupWorkItem?.cancel()
        releaseMPVHeaderProxySessions()
        rendererStop()
        showErrorBanner("Cloudflare verification is required. Retrying this source after verification...")
        Logger.shared.log(
            "[PlayerVC.PlaybackStart] explicit Cloudflare challenge; refreshing session before same-source retry host=\(challengeURL.host ?? "unknown")",
            type: "MPV"
        )

        Task { @MainActor [weak self] in
            let solved = await CloudflareBypassManager.shared.refreshSessionAfterChallenge(
                for: challengeURL,
                rejectedCookieHeader: rejectedCookieHeader
            )
            guard let self else { return }
            await self.renderer.waitUntilStopped()

            cloudflareStartupRecoveryInProgress = false
            guard playbackLoadGeneration == expectedLoadGeneration,
                  !isClosing,
                  !isBeingDismissed else { return }

            playbackFailureHandled = false
            if solved {
                let refreshedHeaders = CloudflareBypassManager.shared.headersByApplyingCachedBypass(
                    originalHeaders,
                    for: originalURL
                )
                Logger.shared.log(
                    "[PlayerVC.PlaybackStart] Cloudflare session refreshed; retrying identical source",
                    type: "MPV"
                )
                load(url: originalURL, preset: preset, headers: refreshedHeaders)
            } else {
                handlePlaybackStartupFailure(
                    "Cloudflare verification was not completed.",
                    isSourceFailure: false
                )
            }
        }
    }

    private func beginMediaSourceRefreshAttempt() -> Bool {
        let now = Date()
        if let lastAttempt = lastMediaSourceRefreshAttemptAt,
           now.timeIntervalSince(lastAttempt) > 30 {
            mediaSourceRefreshAttemptCount = 0
        }
        lastMediaSourceRefreshAttemptAt = now
        guard mediaSourceRefreshAttemptCount < 2 else { return false }
        mediaSourceRefreshAttemptCount += 1
        return true
    }

    private func refreshCurrentProviderPlaybackSource(
        challengeURL: URL,
        rejectedCookieHeader: String?,
        isInteractiveChallenge: Bool,
        statusCode: Int,
        originalURL: URL,
        expectedLoadGeneration: Int,
        preset: PlayerPreset
    ) {
        guard let context = playbackLaunchContext else { return }

        let resumePosition = playbackDidStart && cachedPosition.isFinite && cachedPosition > 0
            ? cachedPosition
            : nil
        cloudflareStartupRecoveryInProgress = true
        playbackFailureHandled = true
        playbackStartupWorkItem?.cancel()
        releaseMPVHeaderProxySessions()
        rendererStop()
        showErrorBanner("The media URL expired. Refreshing this source...")
        Logger.shared.log(
            "[PlayerVC.SourceRefresh] begin source=\(context.sourceName) status=\(statusCode) interactiveChallenge=\(isInteractiveChallenge) challengedHost=\(challengeURL.host ?? "unknown") started=\(playbackDidStart)",
            type: "MPV"
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.renderer.waitUntilStopped()
            var resolution = await resolveCurrentProviderPlaybackSource(context: context)
            var solvedMediaChallenge = false
            let permitsLegacyInteractiveSolve = context.sourceKind == .service

            if isInteractiveChallenge,
               permitsLegacyInteractiveSolve,
               resolution == nil || resolution?.streamURL == originalURL {
                solvedMediaChallenge = await CloudflareBypassManager.shared.refreshSessionAfterChallenge(
                    for: challengeURL,
                    rejectedCookieHeader: rejectedCookieHeader
                )
                if solvedMediaChallenge {
                    resolution = await resolveCurrentProviderPlaybackSource(context: context) ?? resolution
                }
            }

            cloudflareStartupRecoveryInProgress = false
            guard playbackLoadGeneration == expectedLoadGeneration,
                  playbackLaunchContext?.traceID == context.traceID,
                  playbackLaunchContext?.sourceId == context.sourceId,
                  playbackLaunchContext?.providerContentReference == context.providerContentReference,
                  !isClosing,
                  !isBeingDismissed else {
                discardResolvedProviderPlayback(resolution)
                return
            }

            guard let resolution else {
                playbackFailureHandled = false
                handleUnrecoverableMediaSourceRejection(
                    "\(context.sourceName) could not refresh the expired media URL (HTTP \(statusCode))."
                )
                return
            }

            let refreshedContext = PlaybackLaunchContext(
                traceID: context.traceID,
                traceCreatedAt: context.traceCreatedAt,
                sourceId: resolution.sourceId,
                sourceName: resolution.sourceName,
                sourceKind: resolution.sourceKind,
                autoMode: context.autoMode,
                streamURL: resolution.streamURL.absoluteString,
                streamName: resolution.streamName,
                headers: resolution.headers,
                subtitles: resolution.subtitles,
                subtitleNames: resolution.subtitleNames,
                subtitleHeadersByURL: resolution.subtitleHeadersByURL,
                retryCount: context.retryCount,
                titleCandidates: resolution.titleCandidates,
                serviceContentHref: resolution.serviceContentHref,
                providerContentReference: resolution.providerContentReference
            )
            playbackLaunchContext = refreshedContext
            initialSubtitles = resolution.subtitles
            initialSubtitleNames = resolution.subtitleNames
            initialSubtitleHeadersByURL = resolution.subtitleHeadersByURL
            pendingSourceRefreshResumePosition = resumePosition
            playbackFailureHandled = false

            Logger.shared.log(
                "[PlayerVC.SourceRefresh] resolved source=\(resolution.sourceName) oldHost=\(originalURL.host ?? "unknown") newHost=\(resolution.streamURL.host ?? "unknown") sameURL=\(resolution.streamURL == originalURL) resume=\(secondsText(resumePosition))",
                type: "MPV"
            )
            load(url: resolution.streamURL, preset: preset, headers: resolution.headers)
        }
    }

    private func discardResolvedProviderPlayback(_ resolution: NextEpisodePrestageResolution?) {
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard let resolution,
              resolution.sourceKind == .skyStream else { return }
        MPVHeaderProxy.shared.invalidateSession(for: resolution.streamURL)
        activeMPVHeaderProxyURLs.remove(resolution.streamURL)
#endif
    }

    private func resolveCurrentProviderPlaybackSource(
        context: PlaybackLaunchContext
    ) async -> NextEpisodePrestageResolution? {
#if os(iOS) && !targetEnvironment(macCatalyst)
        if context.sourceKind == .skyStream {
            return await resolveCurrentSkyStreamPlaybackSource(context: context)
        }
#endif
        guard context.sourceKind == .service,
              let service = ServiceManager.shared.activeServices.first(where: {
                  SourceHealth.serviceId($0) == context.sourceId
              }),
              let contentHref = Self.normalizedNonemptyString(context.serviceContentHref) else {
            return nil
        }

        let isAnime = isAnimeContent()
        let originalAudioLanguage = servicesOriginalAudioLanguage
        switch mediaInfo {
        case .episode(_, let seasonNumber, let episodeNumber, _, _, _):
            return await resolveServicePrestageCandidate(
                service: service,
                knownContentHref: contentHref,
                nextSeasonNumber: seasonNumber,
                nextEpisodeNumber: episodeNumber,
                nextContext: episodePlaybackContext,
                lookupSeason: episodePlaybackContext?.resolvedTMDBSeasonNumber ?? seasonNumber,
                lookupEpisode: episodePlaybackContext?.resolvedTMDBEpisodeNumber ?? episodeNumber,
                isAnime: isAnime,
                originalAudioLanguage: originalAudioLanguage,
                titleCandidates: context.titleCandidates,
                preferredStreamName: context.streamName
            )

        case .movie:
            let jsController = JSController()
            jsController.loadScript(service.jsScript, service: service)
            let episodes = await fetchServiceEpisodes(
                jsController: jsController,
                service: service,
                contentHref: contentHref
            )
            guard !Task.isCancelled else { return nil }
            let streamHref = episodes.first?.href ?? contentHref
            let result = await fetchServiceStreams(
                jsController: jsController,
                service: service,
                episodeHref: streamHref
            )
            guard !Task.isCancelled,
                  let selected = Self.selectPrewarmStream(
                      streams: result.streams,
                      sources: result.sources,
                      sourceId: context.sourceId,
                      isAnime: isAnime,
                      originalAudioLanguage: originalAudioLanguage,
                      preferredLabel: context.streamName
                  ),
                  let streamURL = Self.httpURL(selected.url) else {
                return nil
            }
            let subtitles = Self.serviceSubtitleSelection(
                entries: (selected.subtitleEntries ?? []) + (result.subtitles ?? [])
            )
            let subtitleHeaders = selected.subtitleHeadersByURL?.filter {
                subtitles.urls.contains($0.key)
            }
            return NextEpisodePrestageResolution(
                streamURL: streamURL,
                headers: Self.mergedPlaybackHeaders(
                    baseURL: service.metadata.baseUrl,
                    custom: selected.headers
                ),
                subtitles: subtitles.urls,
                subtitleNames: subtitles.names,
                subtitleHeadersByURL: subtitleHeaders?.isEmpty == false ? subtitleHeaders : nil,
                streamName: selected.label,
                sourceId: context.sourceId,
                sourceName: service.metadata.sourceName,
                sourceKind: .service,
                titleCandidates: context.titleCandidates,
                serviceContentHref: contentHref,
                providerContentReference: nil
            )

        case nil:
            return nil
        }
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    private func resolveCurrentSkyStreamPlaybackSource(
        context: PlaybackLaunchContext
    ) async -> NextEpisodePrestageResolution? {
        guard context.sourceKind == .skyStream,
              let providerReference = context.providerContentReference,
              providerReference.kind == .skyStream,
              providerReference.sourceID == context.sourceId,
              let reference = providerReference.skyStream,
              reference.sourceID == context.sourceId,
              reference.isStructurallyValid,
              skyStreamReferenceMatchesCurrentMedia(reference) else {
            return nil
        }

        do {
            let values = try await SkyStreamResolver.shared.refresh(
                reference,
                mode: .playbackRefresh,
                originalAudioLanguage: servicesOriginalAudioLanguage
            )
            guard !Task.isCancelled,
                  let resolved = values.first,
                  resolved.provider.id == context.sourceId,
                  resolved.contentReference.sourceID == context.sourceId,
                  resolved.contentReference.isStructurallyValid,
                  resolved.playback.identity.packageID == reference.packageName,
                  resolved.playback.identity.providerID == (reference.providerID ?? "root"),
                  reference.scriptSHA256.map({
                    resolved.playback.identity.payloadSHA256.caseInsensitiveCompare($0) == .orderedSame
                  }) ?? true else {
                return nil
            }
            return makeSkyStreamPlaybackResolution(
                resolved,
                titleCandidates: context.titleCandidates,
                traceID: "refresh-\(context.traceID)"
            )
        } catch is CancellationError {
            return nil
        } catch {
            Logger.shared.log(
                "SkyStream: playback refresh failed source=\(context.sourceId) errorType=\(String(reflecting: type(of: error)))",
                type: "MPV"
            )
            return nil
        }
    }

    private func skyStreamReferenceMatchesCurrentMedia(
        _ reference: SkyStreamProviderContentReference
    ) -> Bool {
        switch mediaInfo {
        case .movie:
            return reference.season == nil && reference.episode == nil
        case .episode(_, let localSeason, let localEpisode, _, _, _):
            guard let referenceSeason = reference.season,
                  let referenceEpisode = reference.episode,
                  referenceSeason >= 0,
                  referenceEpisode > 0 else {
                return false
            }
            var acceptedCoordinates = Set(["\(localSeason):\(localEpisode)"])
            if let context = episodePlaybackContext {
                if let season = context.resolvedTMDBSeasonNumber,
                   let episode = context.resolvedTMDBEpisodeNumber {
                    acceptedCoordinates.insert("\(season):\(episode)")
                }
                if let absolute = context.animeAbsoluteEpisodeNumber, absolute > 0 {
                    acceptedCoordinates.insert("1:\(absolute)")
                }
            }
            return acceptedCoordinates.contains("\(referenceSeason):\(referenceEpisode)")
        case nil:
            return false
        }
    }
#endif

    private func logPlaybackAttribution(reason: String, message: String) {
        guard let context = playbackLaunchContext else {
            Logger.shared.log(
                "[PlayerVC.Attribution] reason=\(reason) blame=eclipse detail=no-launch-context message=\(message)",
                type: "Error"
            )
            return
        }

        let deliveredURL = context.streamURL
        let dispatchedURL = initialURL?.absoluteString
        let defect = SkyStreamRemoteURLPolicy.deliveryDefect(in: deliveredURL)
        let dispatchedDiffers = dispatchedURL.map { $0 != deliveredURL } ?? false
        let providerHeaderNames = context.headers.keys.sorted().joined(separator: ",")
        let dispatchedHeaderNames = (initialHeaders ?? [:]).keys.sorted().joined(separator: ",")
        let headersDiffer = providerHeaderNames != dispatchedHeaderNames

        let blame: String
        let detail: String
        if defect != nil {
            blame = "provider"
            detail = "the source handed Eclipse a stream URL that is not a legal URI (\(defect ?? "")); "
                + "Eclipse dispatched it unchanged"
        } else if dispatchedDiffers || headersDiffer {
            blame = "eclipse-suspect"
            detail = "Eclipse did not dispatch what the source supplied; compare delivered and dispatched below"
        } else {
            blame = "provider"
            detail = "Eclipse dispatched the source's URL and headers verbatim, and the host rejected them"
        }

        Logger.shared.log(
            "[PlayerVC.Attribution] reason=\(reason) blame=\(blame) source=\(context.sourceName)"
                + " kind=\(context.sourceKind) trace=\(context.traceID)"
                + " deliveredURL=\(SkyStreamRemoteURLPolicy.defectEvidence(of: deliveredURL))"
                + " dispatchedURL=\(dispatchedURL.map { SkyStreamRemoteURLPolicy.defectEvidence(of: $0) } ?? "none")"
                + " urlUnchanged=\(!dispatchedDiffers)"
                + " providerHeaders=[\(providerHeaderNames)] dispatchedHeaders=[\(dispatchedHeaderNames)]"
                + " detail=\(detail) message=\(message)",
            type: "Error"
        )
    }

    private func handleUnrecoverableMediaSourceRejection(
        _ message: String,
        reason: String = "media-source-rejected"
    ) {
        logPlaybackAttribution(reason: reason, message: message)
        guard let context = playbackLaunchContext else {
            showErrorBanner(message)
            return
        }
        playbackFailureHandled = true
        let report = PlaybackFailureReport(
            context: context,
            message: message,
            isSourceFailure: true
        )
        SourceHealthStore.shared.recordPlaybackFailure(
            sourceId: context.sourceId,
            sourceName: context.sourceName,
            reason: message,
            isSourceFailure: true
        )
        if context.autoMode, onPlaybackStartupFailure != nil {
            dismissAfterPlaybackFailure(report)
        } else {
            showManualPlaybackFailureAlert(report)
        }
    }

    private func isMPVTransportBridgeCandidate(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("unexpected tls packet")
            || (lower.contains("tls") && lower.contains("failed to open"))
    }

    private func attemptMPVTransportBridgeFallbackIfNeeded(after message: String) -> Bool {
        guard isMPVRenderer else { return false }
        guard isMPVTransportBridgeCandidate(message) else { return false }
        guard !mpvTransportBridgeFallbackTried else { return false }
        guard let originalURL = initialURL,
              isRemoteHTTPURL(originalURL),
              !isLocalProxyURL(originalURL),
              let preset = initialPreset else {
            return false
        }

        let proxyHeaders = buildProxyHeaders(for: originalURL, baseHeaders: initialHeaders ?? [:])
        guard let proxyURL = makeMPVHeaderProxyURL(
            for: originalURL,
            headers: proxyHeaders,
            expectedLoadGeneration: playbackLoadGeneration + 1
        ) else {
            Logger.shared.log("[PlayerVC.PlaybackStart] MPV transport bridge URL creation failed; keeping direct failure", type: "MPV")
            return false
        }

        registerMPVHeaderProxyURL(proxyURL)
        mpvTransportBridgeFallbackTried = true
        isMPVTransportBridgePlaybackActive = true
        Logger.shared.log("[PlayerVC.PlaybackStart] MPV transport bridge activated after TLS failure target={\(playbackURLSummary(originalURL))} headerKeys=[\(proxyHeaders.keys.sorted().joined(separator: ","))]", type: "MPV")
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

    private func externalSubtitleTracksForMenu() -> [(Int, String)] {
        guard isVLCCustomSubtitleOverlayEnabled else { return [] }
        return subtitleURLs.enumerated().compactMap { index, url in
            guard !onlineSubtitleLoadedURLs.contains(normalizedSubtitleURLKey(url)) else {
                return nil
            }
            let name = index < subtitleNames.count ? subtitleNames[index] : "Subtitle \(index + 1)"
            return (index, name)
        }
    }

    private func nativeSubtitleTracksForMenu(canReadNativeTracks: Bool = true) -> [SubtitleTrackDescriptor] {
        guard canReadNativeTracks else { return [] }
        return menuSubtitleTrackDescriptors()
            .filter {
                $0.id >= 0 &&
                !isDisabledTrackName($0.name) &&
                !onlineSubtitleLoadedRendererTrackIds.contains($0.id) &&
                !isOnlineSubtitleRendererTrack($0.name)
            }
    }

    private func isOnlineSubtitleRendererTrack(_ name: String) -> Bool {
        let normalized = normalizedOnlineSubtitleTrackName(name)
        guard !normalized.isEmpty else { return false }
        return onlineSubtitleLoadedTrackNames.contains(normalized) ||
            onlineSubtitleLoadedTrackNames.contains { loaded in
                guard loaded.count >= 4, normalized.count >= 4 else { return false }
                return normalized.contains(loaded) || loaded.contains(normalized)
            }
    }

    private func onlineSubtitleTrackNameCandidates(urlString: String, displayName: String) -> [String] {
        var candidates = [displayName]
        if let url = URL(string: urlString), !url.lastPathComponent.isEmpty {
            candidates.append(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        } else {
            let withoutQuery = urlString.split(separator: "?", maxSplits: 1).first ?? Substring(urlString)
            let withoutFragment = withoutQuery.split(separator: "#", maxSplits: 1).first ?? withoutQuery
            if let lastPathComponent = withoutFragment.split(separator: "/").last {
                candidates.append(String(lastPathComponent))
            }
        }

        var seen = Set<String>()
        return candidates.flatMap { candidate -> [String] in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let withoutExtension = (trimmed as NSString).deletingPathExtension
            return withoutExtension.isEmpty || withoutExtension == trimmed ? [trimmed] : [trimmed, withoutExtension]
        }
        .map { normalizedOnlineSubtitleTrackName($0) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func normalizedOnlineSubtitleTrackName(_ name: String) -> String {
        name
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedSubtitleURLKey(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func captureOnlineSubtitleRendererTrackIds(knownBeforeLoad: Set<Int>) {
        let currentTracks = rendererGetSubtitleTrackDescriptors()
            .filter { $0.id >= 0 && !isDisabledTrackName($0.name) }
        let currentIds = Set(currentTracks.map(\.id))
        onlineSubtitleLoadedRendererTrackIds.formUnion(currentIds.subtracting(knownBeforeLoad))
        onlineSubtitleLoadedRendererTrackIds.formUnion(
            currentTracks
                .filter { isOnlineSubtitleRendererTrack($0.name) }
                .map(\.id)
        )
    }

    private func showMPVSubtitleMenu() {
        updateSubtitleTracksMenu()

        let externalTracks = externalSubtitleTracksForMenu()
        let nativeSubtitleTracks = nativeSubtitleTracksForMenu()
        let embeddedTracks = nativeSubtitleTracks.map { ($0.id, $0.name) }

        var sections: [PlayerOverlayMenuSection] = []
        var trackActions: [PlayerOverlayMenuAction] = [
            makeOverlayAction(title: "Disable Subtitles", imageName: "xmark", isSelected: !subtitleModel.isVisible) { [weak self] in
                guard let self else { return }
                self.setSessionAwareSubtitleVisible(false)
                self.userSelectedSubtitleTrack = true
                self.recordUserSubtitleSelection(enabled: false)
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
                    self.setSessionAwareSubtitleVisible(true)
                    self.userSelectedSubtitleTrack = true
                    self.recordUserSubtitleSelection(enabled: true, displayName: name)
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
                    self.setSessionAwareSubtitleVisible(true)
                    self.userSelectedSubtitleTrack = true
                    self.recordUserSubtitleSelection(enabled: true, displayName: track.name)
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

        if hasStremioSubtitleAddons {
            sections.append(PlayerOverlayMenuSection(title: "Stremio Subtitles", actions: stremioSubtitleOverlayActions()))
        }

        if isVLCOpenSubtitlesEnabled {
            sections.append(PlayerOverlayMenuSection(title: "OpenSubtitles", actions: openSubtitlesOverlayActions()))
        }

        if !isVLCPlayer && Settings.shared.playerSubtitleAppearanceEnabled {
            sections.append(contentsOf: subtitleAppearanceOverlaySections())
        }

        showOverlayMenu(title: "Subtitles", kind: "subtitles", sections: sections)
    }

    private func stremioSubtitleOverlayActions() -> [PlayerOverlayMenuAction] {
        if stremioSubtitleFetchInProgress {
            return [makeOverlayAction(title: "Searching subtitle addons...", imageName: "hourglass", isEnabled: false) {}]
        }
        if stremioSubtitleResults.isEmpty {
            if stremioSubtitleSearchAttempted {
                return [
                    makeOverlayAction(title: "No subtitle addon results", imageName: "captions.bubble", isEnabled: false) {},
                    makeOverlayAction(title: "Refresh subtitle addons", imageName: "arrow.clockwise") { [weak self] in
                        self?.fetchStremioSubtitles(autoSelect: false, reason: "manual-refresh-empty", forceRefresh: true)
                        self?.hideOverlayMenu()
                    }
                ]
            }
            return [
                makeOverlayAction(title: "Search subtitle addons", imageName: "magnifyingglass") { [weak self] in
                    self?.fetchStremioSubtitles(autoSelect: false, reason: "manual-menu")
                    self?.hideOverlayMenu()
                }
            ]
        }

        var actions: [PlayerOverlayMenuAction] = [
            makeOverlayAction(title: "Refresh subtitle addons", imageName: "arrow.clockwise") { [weak self] in
                self?.fetchStremioSubtitles(autoSelect: false, reason: "manual-refresh", forceRefresh: true)
                self?.hideOverlayMenu()
            }
        ]
        actions.append(contentsOf: stremioSubtitleResults.prefix(20).map { result in
            let selected = isOnlineSubtitleSelected(result.subtitle.url)
            return makeOverlayAction(title: stremioSubtitleDisplayName(result), imageName: "captions.bubble", isSelected: selected) { [weak self] in
                self?.loadStremioSubtitle(result, userSelected: true)
                self?.hideOverlayMenu()
            }
        })
        return actions
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
        let verticalOffsets: [(String, CGFloat)] = [
            ("Highest", -24.0),
            ("Higher", -16.0),
            ("Default", -6.0),
            ("Lower", 6.0),
            ("Lowest", 18.0)
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
            }),
            PlayerOverlayMenuSection(title: "Vertical Position", actions: verticalOffsets.map { name, offset in
                makeOverlayAction(title: name, imageName: "arrow.up.and.down", isSelected: abs(subtitleModel.verticalOffset - offset) < 0.01) { [weak self] in
                    self?.subtitleModel.verticalOffset = offset
                    self?.updateCurrentSubtitleAppearance()
                    self?.showMPVSubtitleMenu()
                }
            })
        ]
    }

    private func updateSubtitleTracksMenu() {
        let useCustomExternalOverlay = isVLCCustomSubtitleOverlayEnabled
        let externalTracks = useCustomExternalOverlay ? externalSubtitleTracksForMenu() : []
        let canReadNativeTracks = !isVLCPlayer || canMutateVLCSubtitleTracks
        let nativeSubtitleTracks = nativeSubtitleTracksForMenu(canReadNativeTracks: canReadNativeTracks)
        let embeddedTracks = nativeSubtitleTracks.map { ($0.id, $0.name) }
        let autoSelectableNativeTracks = nativeSubtitleTracks.filter { canAutoSelectNativeSubtitleTrack($0) }
        let autoSelectableEmbeddedTracks = autoSelectableNativeTracks.map { ($0.id, $0.name) }
        logSkippedMPVBitmapSubtitleTracksIfNeeded(nativeSubtitleTracks.filter { !canAutoSelectNativeSubtitleTrack($0) })

        let subtitleTrackSignature = nativeSubtitleTracks.map { "\($0.id):\($0.name):\($0.codec)" }.joined(separator: "|")
        let subtitleLogSignature = "external=\(externalTracks.count)|embedded=\(subtitleTrackSignature)|auto=\(autoSelectableEmbeddedTracks.count)|user=\(userSelectedSubtitleTrack)|renderer=\(vlcRenderer != nil ? "VLC" : "MPV")"
        if subtitleLogSignature != lastSubtitleTracksMenuLogSignature {
            lastSubtitleTracksMenuLogSignature = subtitleLogSignature
            Logger.shared.log("PlayerViewController: subtitle tracks external=\(externalTracks.count) embedded=\(embeddedTracks.count) autoSelectableNative=\(autoSelectableEmbeddedTracks.count) userSelected=\(userSelectedSubtitleTrack) renderer=\(vlcRenderer != nil ? "VLC" : "MPV")", type: "Player")
        }

        subtitleButton.isHidden = false

        subtitleButton.showsMenuAsPrimaryAction = !usesOverlayPlayerMenus

        if restoreRequestedEmbeddedSubtitleTrackIfNeeded(from: embeddedTracks) {
            updateSubtitleButtonAppearance()
        }

        if !userSelectedSubtitleTrack {
            if automaticSubtitlesEnabled {
                let preferredLang = automaticSubtitleSelectionLanguage
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
                } else if maybeUseStremioSubtitleFallback(preferredLang: preferredLang) {
                    Logger.shared.log("[PlayerVC.Subtitles] Stremio subtitle fallback requested for preferredLang=\(preferredLang)", type: "Player")
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

        if usesOverlayPlayerMenus {
            if nativeSubtitleMenuContentSignature != "overlay" {
                subtitleButton.menu = nil
                nativeSubtitleMenuContentSignature = "overlay"
            }
            return
        }
        let externalTrackSignature = externalTracks.map { "\($0.0):\($0.1)" }.joined(separator: "|")
        let nativeTrackMenuSignature = nativeSubtitleTracks.map {
            "\($0.id):\($0.name):\($0.codec):\($0.isExternalNativeTrack):\(canAutoSelectNativeSubtitleTrack($0))"
        }.joined(separator: "|")
        let stremioMenuSignature = [
            "enabled=\(hasStremioSubtitleAddons)",
            "fetching=\(stremioSubtitleFetchInProgress)",
            "searched=\(stremioSubtitleSearchAttempted)",
            stremioSubtitleResults.prefix(20).map {
                "\($0.addon.id):\(stremioSubtitleDisplayName($0)):\($0.subtitle.id ?? ""):\($0.subtitle.url ?? ""):\(isOnlineSubtitleSelected($0.subtitle.url))"
            }.joined(separator: "|")
        ].joined(separator: ";")
        let openSubtitlesMenuSignature = [
            "enabled=\(isVLCOpenSubtitlesEnabled)",
            "fetching=\(openSubtitlesFetchInProgress)",
            "searched=\(openSubtitlesSearchAttempted)",
            openSubtitlesResults.prefix(20).map {
                "\($0.id ?? ""):\(openSubtitleDisplayName($0)):\($0.url ?? "")"
            }.joined(separator: "|")
        ].joined(separator: ";")
        let appearanceEnabled = !isVLCPlayer && Settings.shared.playerSubtitleAppearanceEnabled
        let menuSignature = [
            "native",
            "visible=\(subtitleModel.isVisible)",
            "selection=\(subtitleSelectionMenuSignature())",
            "external=\(externalTrackSignature)",
            "nativeTracks=\(nativeTrackMenuSignature)",
            "stremio=\(stremioMenuSignature)",
            "openSubtitles=\(openSubtitlesMenuSignature)",
            "appearance=\(appearanceEnabled)",
            appearanceEnabled ? subtitleStyleMenuSignature() : ""
        ].joined(separator: "||")
        if menuSignature == nativeSubtitleMenuContentSignature {
            return
        }
        if shouldDeferNativePlayerMenuRefresh(kind: "subtitles") {
            return
        }

        var trackActions: [UIAction] = []

        let disableAction = UIAction(
            title: "Disable Subtitles",
            image: UIImage(systemName: "xmark"),
            state: subtitleModel.isVisible ? .off : .on
        ) { [weak self] _ in
            guard let self else { return }
            self.setSessionAwareSubtitleVisible(false)
            self.userSelectedSubtitleTrack = true
            self.recordUserSubtitleSelection(enabled: false)
            self.rendererDisableSubtitles()
            self.subtitleEntries.removeAll()
            self.vlcSubtitleSelection = .none
            self.updateVLCSubtitleOverlay(for: self.cachedPosition)
            self.updateSubtitleButtonAppearance()
            self.updateSubtitleTracksMenu()
            Logger.shared.log("[PlayerVC.Subtitles] user disabled subtitles from menu", type: "Player")
        }
        trackActions.append(disableAction)

        if externalTracks.isEmpty && embeddedTracks.isEmpty {

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
                    self.setSessionAwareSubtitleVisible(true)
                    self.userSelectedSubtitleTrack = true
                    self.recordUserSubtitleSelection(enabled: true, displayName: name)
                    self.currentSubtitleIndex = id
                    self.vlcSubtitleSelection = .external(index: id)
                    Logger.shared.log("[PlayerVC.Subtitles] user selected external subtitle index=\(id) name=\(name)", type: "Player")
                    self.loadCurrentSubtitle()
                    self.rendererDisableSubtitles()
                    self.updateVLCSubtitleOverlay(for: self.cachedPosition)
                    self.updateSubtitleButtonAppearance()

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
                    self.setSessionAwareSubtitleVisible(true)
                    self.userSelectedSubtitleTrack = true
                    self.recordUserSubtitleSelection(enabled: true, displayName: name)
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
        if let stremioMenu = stremioSubtitleMenu() {
            menuChildren.append(stremioMenu)
        }
        if let openSubtitlesMenu = openSubtitlesMenu() {
            menuChildren.append(openSubtitlesMenu)
        }
        if !isVLCPlayer && Settings.shared.playerSubtitleAppearanceEnabled {
            let appearanceMenu = createAppearanceMenu()
            menuChildren.append(appearanceMenu)
        }
        let subtitleMenu = UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: menuChildren)
        subtitleButton.menu = subtitleMenu
        nativeSubtitleMenuContentSignature = menuSignature
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
        _ = track
        return true
    }

    private func shouldLogSkippedMPVBitmapSubtitleTracks() -> Bool {
        return false
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
        guard shouldLogSkippedMPVBitmapSubtitleTracks() else { return }
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
        let choiceLogSignature = "\(preferredLang)|\(tracks.map { "\($0.0):\($0.1)" }.joined(separator: "|"))|\(best?.0 ?? -1)|\(bestScore)"
        if choiceLogSignature != lastDefaultSubtitleChoiceLogSignature {
            lastDefaultSubtitleChoiceLogSignature = choiceLogSignature
            Logger.shared.log("PlayerViewController: default subtitles preferredLang=\(preferredLang) best=\(best?.1 ?? "nil") score=\(bestScore)", type: "Player")
        }
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

    private func preferredStremioSubtitle(from results: [StremioAddonManager.AddonSubtitleResult], preferredLang: String) -> StremioAddonManager.AddonSubtitleResult? {
        let valid = results.filter { $0.subtitle.url?.isEmpty == false }
        if let exact = valid.first(where: { openSubtitleMatchesPreferredLanguage($0.subtitle, preferredLang: preferredLang) }) {
            return exact
        }
        return nil
    }

    private func stremioSubtitleMenu() -> UIMenu? {
        guard hasStremioSubtitleAddons else { return nil }

        var actions: [UIMenuElement] = []

        if stremioSubtitleFetchInProgress {
            actions.append(UIAction(title: "Searching subtitle addons...", image: UIImage(systemName: "hourglass"), attributes: .disabled) { _ in })
        } else if stremioSubtitleResults.isEmpty {
            if stremioSubtitleSearchAttempted {
                actions.append(UIAction(title: "No subtitle addon results", image: UIImage(systemName: "captions.bubble"), attributes: .disabled) { _ in })
                actions.append(UIAction(title: "Refresh subtitle addons", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.fetchStremioSubtitles(autoSelect: false, reason: "manual-refresh-empty", forceRefresh: true)
                })
            } else {
                actions.append(UIAction(title: "Search subtitle addons", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                    self?.fetchStremioSubtitles(autoSelect: false, reason: "manual-menu")
                })
            }
        } else {
            actions.append(UIAction(title: "Refresh subtitle addons", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.fetchStremioSubtitles(autoSelect: false, reason: "manual-refresh", forceRefresh: true)
            })

            let subtitleActions: [UIMenuElement] = stremioSubtitleResults.prefix(20).map { result in
                UIAction(
                    title: stremioSubtitleDisplayName(result),
                    image: UIImage(systemName: "captions.bubble"),
                    state: isOnlineSubtitleSelected(result.subtitle.url) ? .on : .off
                ) { [weak self] _ in
                    self?.loadStremioSubtitle(result, userSelected: true)
                }
            }
            actions.append(contentsOf: subtitleActions)
        }

        return UIMenu(title: "Stremio Subtitles", image: UIImage(systemName: "puzzlepiece.extension"), children: actions)
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

    private func stremioSubtitleDisplayName(_ result: StremioAddonManager.AddonSubtitleResult) -> String {
        let addonName = result.addon.manifest.name
        let subtitleName = openSubtitleDisplayName(result.subtitle)
        if subtitleName.lowercased().contains(addonName.lowercased()) {
            return subtitleName
        }
        return "\(addonName) - \(subtitleName)"
    }

    private func maybeUseStremioSubtitleFallback(preferredLang: String) -> Bool {
        guard canAutoApplyStremioSubtitleFallback() else { return false }

        if let result = preferredStremioSubtitle(from: stremioSubtitleResults, preferredLang: preferredLang) {
            stremioSubtitleFallbackAttempted = true
            loadStremioSubtitle(result, userSelected: false)
            return true
        }

        guard !stremioSubtitleFallbackAttempted,
              !stremioSubtitleFetchInProgress else { return false }
        stremioSubtitleFallbackAttempted = true
        fetchStremioSubtitles(autoSelect: true, reason: "auto-fallback")
        return true
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
            && Settings.shared.playerOpenSubtitlesAutoFallbackEnabled
            && automaticSubtitlesEnabled
            && !userSelectedSubtitleTrack
    }

    private func canAutoApplyStremioSubtitleFallback() -> Bool {
        if let deadline = vlcExternalSubtitlePriorityDeadline, Date() < deadline {
            return false
        }
        return hasStremioSubtitleAddons
            && Settings.shared.playerOpenSubtitlesAutoFallbackEnabled
            && automaticSubtitlesEnabled
            && !userSelectedSubtitleTrack
    }

    private func fetchStremioSubtitles(autoSelect: Bool, reason: String, forceRefresh: Bool = false) {
        guard hasStremioSubtitleAddons else { return }
        if stremioSubtitleFetchInProgress { return }
        if !forceRefresh, !stremioSubtitleResults.isEmpty {
            if autoSelect,
               canAutoApplyStremioSubtitleFallback(),
               let result = preferredStremioSubtitle(from: stremioSubtitleResults, preferredLang: automaticSubtitleSelectionLanguage) {
                stremioSubtitleFallbackAttempted = true
                loadStremioSubtitle(result, userSelected: false)
            }
            return
        }

        stremioSubtitleFetchTask?.cancel()
        stremioSubtitleFetchInProgress = true
        stremioSubtitleSearchAttempted = true
        updateSubtitleTracksMenu()

        stremioSubtitleFetchTask = Task { [weak self] in
            guard let self else { return }
            let results = await self.fetchStremioSubtitleResults(reason: reason)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.stremioSubtitleFetchInProgress = false
                self.stremioSubtitleResults = self.sortedStremioSubtitleResults(results)
                Logger.shared.log("[PlayerVC.StremioSubtitles] fetch complete reason=\(reason) count=\(results.count)", type: "Player")
                if autoSelect,
                   self.canAutoApplyStremioSubtitleFallback(),
                   let result = self.preferredStremioSubtitle(from: self.stremioSubtitleResults, preferredLang: self.automaticSubtitleSelectionLanguage) {
                    self.stremioSubtitleFallbackAttempted = true
                    self.loadStremioSubtitle(result, userSelected: false)
                } else {
                    self.updateSubtitleTracksMenu()
                    self.refreshVisibleOverlayMenuIfNeeded(kind: "subtitles")
                }
            }
        }
    }

    private func fetchOpenSubtitles(autoSelect: Bool, reason: String, forceRefresh: Bool = false) {
        guard isVLCOpenSubtitlesEnabled else { return }
        if openSubtitlesFetchInProgress { return }
        if !forceRefresh, !openSubtitlesResults.isEmpty {
            if autoSelect,
               canAutoApplyOpenSubtitlesFallback(),
               let subtitle = preferredOpenSubtitle(from: openSubtitlesResults, preferredLang: automaticSubtitleSelectionLanguage) {
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
                   let subtitle = self.preferredOpenSubtitle(from: results, preferredLang: self.automaticSubtitleSelectionLanguage) {
                    self.openSubtitlesFallbackAttempted = true
                    self.loadOpenSubtitle(subtitle, userSelected: false)
                } else {
                    self.updateSubtitleTracksMenu()
                    self.refreshVisibleOverlayMenuIfNeeded(kind: "subtitles")
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

    private func prefetchStremioSubtitlesIfAvailable(reason: String) {
        guard hasStremioSubtitleAddons else { return }
        guard !stremioSubtitleFetchInProgress,
              stremioSubtitleResults.isEmpty,
              !stremioSubtitleSearchAttempted else {
            return
        }
        guard openSubtitlesLookupMetadata() != nil else { return }
        fetchStremioSubtitles(autoSelect: false, reason: "auto-prefetch-\(reason)")
    }

    private func fetchStremioSubtitleResults(reason: String) async -> [StremioAddonManager.AddonSubtitleResult] {
        let lookup = await MainActor.run {
            (
                metadata: openSubtitlesLookupMetadata(),
                playbackContext: episodePlaybackContext,
                titleCandidates: stremioSubtitleTitleCandidates()
            )
        }
        let metadata = lookup.metadata
        guard let metadata else {
            Logger.shared.log("[PlayerVC.StremioSubtitles] skipped \(reason): missing metadata", type: "Player")
            return []
        }

        let resolvedImdbId: String?
        if let imdbId = metadata.imdbId, !imdbId.isEmpty {
            resolvedImdbId = imdbId
        } else {
            resolvedImdbId = await resolveOpenSubtitlesIMDbId(tmdbId: metadata.tmdbId, type: metadata.type)
        }

        return await StremioAddonManager.shared.fetchSubtitlesFromAddons(
            tmdbId: metadata.tmdbId,
            imdbId: resolvedImdbId,
            type: metadata.type,
            season: metadata.season,
            episode: metadata.episode,
            anilistId: lookup.playbackContext?.positiveAniListMediaId
                ?? lookup.playbackContext?.anilistMediaId,
            playbackContext: lookup.playbackContext,
            titleCandidates: lookup.titleCandidates
        )
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
        let preferredLang = automaticSubtitleSelectionLanguage
        return result.sorted { lhs, rhs in
            let lhsMatch = openSubtitleMatchesPreferredLanguage(lhs, preferredLang: preferredLang)
            let rhsMatch = openSubtitleMatchesPreferredLanguage(rhs, preferredLang: preferredLang)
            if lhsMatch != rhsMatch { return lhsMatch && !rhsMatch }
            return openSubtitleDisplayName(lhs) < openSubtitleDisplayName(rhs)
        }
    }

    private func sortedStremioSubtitleResults(_ results: [StremioAddonManager.AddonSubtitleResult]) -> [StremioAddonManager.AddonSubtitleResult] {
        let preferredLang = automaticSubtitleSelectionLanguage
        return results.sorted { lhs, rhs in
            let lhsMatch = openSubtitleMatchesPreferredLanguage(lhs.subtitle, preferredLang: preferredLang)
            let rhsMatch = openSubtitleMatchesPreferredLanguage(rhs.subtitle, preferredLang: preferredLang)
            if lhsMatch != rhsMatch { return lhsMatch && !rhsMatch }
            if lhs.addon.sortIndex != rhs.addon.sortIndex {
                return lhs.addon.sortIndex < rhs.addon.sortIndex
            }
            return stremioSubtitleDisplayName(lhs) < stremioSubtitleDisplayName(rhs)
        }
    }

    private func stremioSubtitleTitleCandidates() -> [String] {
        var candidates: [String] = []
        if let override = trimmedTitle(playerTitleOverride) {
            candidates.append(override)
        }
        switch mediaInfo {
        case .movie(_, let title, _, _):
            candidates.append(title)
        case .episode(_, _, _, let showTitle, _, _):
            if let showTitle {
                candidates.append(showTitle)
            }
            candidates.append(playerDisplayTitle())
        case .none:
            break
        }
        var seen = Set<String>()
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private func isOnlineSubtitleSelected(_ url: String?) -> Bool {
        guard let url else { return false }
        let key = normalizedSubtitleURLKey(url)
        guard onlineSubtitleLoadedURLs.contains(key),
              subtitleModel.isVisible,
              currentSubtitleIndex < subtitleURLs.count else {
            return false
        }
        return normalizedSubtitleURLKey(subtitleURLs[currentSubtitleIndex]) == key
    }

    private func loadOpenSubtitle(_ subtitle: StremioSubtitle, userSelected: Bool) {
        guard let urlString = subtitle.url, !urlString.isEmpty else { return }
        let urlKey = normalizedSubtitleURLKey(urlString)
        guard openSubtitlesLoadedURLs.insert(urlKey).inserted || userSelected else { return }

        let displayName = "OpenSubtitles - \(openSubtitleDisplayName(subtitle))"
        if userSelected {
            recordUserSubtitleSelection(
                enabled: true,
                languageTag: subtitle.lang,
                displayName: displayName
            )
        }
        loadOnlineSubtitle(
            urlString: urlString,
            displayName: displayName,
            sourceLogLabel: "OpenSubtitles",
            userSelected: userSelected
        )
    }

    private func loadStremioSubtitle(_ result: StremioAddonManager.AddonSubtitleResult, userSelected: Bool) {
        guard let urlString = result.subtitle.url, !urlString.isEmpty else { return }
        let urlKey = normalizedSubtitleURLKey(urlString)
        guard stremioSubtitleLoadedURLs.insert(urlKey).inserted || userSelected else { return }

        let displayName = stremioSubtitleDisplayName(result)
        if userSelected {
            recordUserSubtitleSelection(
                enabled: true,
                languageTag: result.subtitle.lang,
                displayName: displayName
            )
        }
        loadOnlineSubtitle(
            urlString: urlString,
            displayName: displayName,
            sourceLogLabel: "StremioSubtitles",
            userSelected: userSelected
        )
    }

    private func loadOnlineSubtitle(urlString: String, displayName: String, sourceLogLabel: String, userSelected: Bool) {
        let subtitleIndex: Int
        if let existingIndex = subtitleURLs.firstIndex(of: urlString) {
            subtitleIndex = existingIndex
            if existingIndex < subtitleNames.count {
                subtitleNames[existingIndex] = displayName
            }
        } else {
            subtitleURLs.append(urlString)
            subtitleNames.append(displayName)
            subtitleIndex = subtitleURLs.count - 1
        }
        onlineSubtitleLoadedURLs.insert(normalizedSubtitleURLKey(urlString))
        onlineSubtitleTrackNameCandidates(urlString: urlString, displayName: displayName).forEach {
            onlineSubtitleLoadedTrackNames.insert($0)
        }

        if userSelected {
            setSessionAwareSubtitleVisible(true)
            userSelectedSubtitleTrack = true
        } else {
            setSubtitleVisible(true, persist: false)
        }

        currentSubtitleIndex = subtitleIndex
        if isVLCCustomSubtitleOverlayEnabled {
            vlcSubtitleSelection = .external(index: subtitleIndex)
            rendererDisableSubtitlesIfReady(reason: "\(sourceLogLabel) custom overlay")
            loadCurrentSubtitle()
            updateVLCSubtitleOverlay(for: cachedPosition)
        } else {
            let knownRendererSubtitleTrackIds = Set(
                rendererGetSubtitleTrackDescriptors()
                    .filter { $0.id >= 0 && !isDisabledTrackName($0.name) }
                    .map(\.id)
            )
            rendererLoadExternalSubtitles(urls: [urlString], names: [displayName], enforce: true)
            vlcExternalSubtitlesLoadedNatively = true
            vlcExternalSubtitlePriorityDeadline = nil
            vlcSubtitleSelection = .none
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.captureOnlineSubtitleRendererTrackIds(knownBeforeLoad: knownRendererSubtitleTrackIds)
                self?.updateSubtitleTracksMenuWhenReady()
            }
        }

        Logger.shared.log("[PlayerVC.\(sourceLogLabel)] loaded subtitle name=\(displayName) userSelected=\(userSelected)", type: "Player")
        updateSubtitleButtonAppearance()
        updateSubtitleTracksMenu()
    }

    private var pendingUserDefaultsChangeWorkItem: DispatchWorkItem?

    @objc private func handleUserDefaultsDidChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleUserDefaultsDidChange()
            }
            return
        }

        pendingUserDefaultsChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingUserDefaultsChangeWorkItem = nil
            self.applyUserDefaultsChange()
        }
        pendingUserDefaultsChangeWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func applyUserDefaultsChange() {
        guard isVLCPlayer || isMPVRenderer else { return }
        if isVLCPlaybackStartupInProgress {
            Logger.shared.log("[PlayerVC.Settings] UserDefaults changed during VLC startup; deferring subtitle/settings rebuild", type: "Player")
#if !os(tvOS)
            updateBrightnessControlVisibility()
            updateVolumeControlVisibility()
#endif
            updateEpisodeBrowserButtonVisibility()
            updateMetalPerformanceOverlayVisibility()
            return
        }
        Logger.shared.log("[PlayerVC.Settings] UserDefaults changed; evaluating in-app player subtitle mode", type: "Player")
        applyPlayerSkinIfNeeded()
        configureSeekButtons()
        subtitleModel.reloadStyleSettingsFromDefaults(preservingVisibility: true)
        if isVLCPlayer {
            applyVLCSubtitleModeSettingIfNeeded()
            applyVLCSubtitleOverlayPositionSetting()
        } else {

            let style = currentSubtitleStyle()
            if style != lastAppliedSubtitleStyleSnapshot {
                rendererApplySubtitleStyle(style)
            }
        }
        configureMPVAppExitPictureInPictureAutomation(reason: "settings")

        applyAudioComfortFilterIfNeeded(reason: "settings")
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE

        gpuMPVRenderer?.applyHDRConfiguration(reason: "settings")
#endif
        updatePiPButtonVisibility()
        updateEpisodeBrowserButtonVisibility()
        updateMetalPerformanceOverlayVisibility()
        scheduleSubtitleMenuRefresh()
        prefetchOpenSubtitlesIfEnabled(reason: "settings")
        prefetchStremioSubtitlesIfAvailable(reason: "settings")
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
            let enableByDefault = automaticSubtitlesEnabled
            setSubtitleVisible(enableByDefault, persist: false)

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

        guard let url = URL(string: urlString) else {
            Logger.shared.log("Rejected malformed remote subtitle URL", type: "Error")
            return
        }

        Logger.shared.log(
            "Loading remote subtitle target={\(playbackURLSummary(url))}",
            type: "Info"
        )

        var request = URLRequest(url: url)
        if isLocalProxyURL(url) {
            Logger.shared.log("Subtitle download using local proxy URL; preserving proxy headers", type: "Stream")
        } else {
            let subtitleSpecificHeaders = initialSubtitleHeadersByURL?[urlString]
            let requestHeaders = subtitleSpecificHeaders?.isEmpty == false ? subtitleSpecificHeaders : initialHeaders
            if let headers = requestHeaders, !headers.isEmpty {
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let session = URLSession.fetchData(allowRedirects: true)
            session.dataTask(with: request) { [weak self] data, response, error in
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

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    self.parseAndDisplaySubtitles(subtitleContent)
                }
            }.resume()

            session.finishTasksAndInvalidate()
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

        if subtitleButton.showsMenuAsPrimaryAction {
            return
        }

        if vlcRenderer != nil {
            return
        }

        if !subtitleURLs.isEmpty {
            if subtitleURLs.count == 1 {
                let shouldShow = !subtitleModel.isVisible
                setSessionAwareSubtitleVisible(shouldShow)
                userSelectedSubtitleTrack = true
                if shouldShow {
                    let displayName = currentSubtitleIndex < subtitleNames.count
                        ? subtitleNames[currentSubtitleIndex]
                        : nil
                    recordUserSubtitleSelection(enabled: true, displayName: displayName)
                    vlcSubtitleSelection = .external(index: currentSubtitleIndex)
                    loadCurrentSubtitle()
                    rendererApplySubtitleStyle(currentSubtitleStyle(visible: true))
                } else {
                    recordUserSubtitleSelection(enabled: false)
                    rendererDisableSubtitles()
                    subtitleEntries.removeAll()
                    vlcSubtitleSelection = .none
                }
                updateSubtitleButtonAppearance()
                updateSubtitleTracksMenu()
            } else {
                showSubtitleSelectionMenu()
            }
            showControlsTemporarily()
            Logger.shared.log("subtitleButtonTapped: handled external subtitle flow", type: "Info")
            return
        }

        let embeddedTracks = rendererGetSubtitleTracks()
        Logger.shared.log("subtitleButtonTapped: embedded flow, tracks=\(embeddedTracks.count)", type: "Info")

        let alert = UIAlertController(title: "Select Subtitle", message: nil, preferredStyle: .actionSheet)

        let disable = UIAlertAction(title: "Disable Subtitles", style: .destructive) { [weak self] _ in
            Logger.shared.log("Embedded subtitles disabled via action sheet", type: "Info")
            guard let self else { return }
            self.userSelectedSubtitleTrack = true
            self.setSessionAwareSubtitleVisible(false)
            self.recordUserSubtitleSelection(enabled: false)
            self.rendererDisableSubtitles()
            self.subtitleEntries.removeAll()
            self.vlcSubtitleSelection = .none
            self.updateSubtitleButtonAppearance()
            self.updateSubtitleTracksMenu()
        }
        alert.addAction(disable)

        if embeddedTracks.isEmpty {
            alert.addAction(UIAlertAction(title: "No subtitles in stream", style: .cancel, handler: nil))
        } else {
            for (id, name) in embeddedTracks {
                alert.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                    guard let self else { return }
                    Logger.shared.log("Embedded subtitle selected via action sheet: id=\(id) name=\(name)", type: "Info")
                    self.userSelectedSubtitleTrack = true
                    self.setSessionAwareSubtitleVisible(true)
                    self.recordUserSubtitleSelection(enabled: true, displayName: name)
                    self.vlcSubtitleSelection = .embedded(trackId: id)
                    self.rendererSetSubtitleTrack(id: id)
                    self.rendererApplySubtitleStyle(self.currentSubtitleStyle(visible: true))
                    self.updateSubtitleButtonAppearance()
                    self.updateSubtitleTracksMenu()
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
            guard let self else { return }
            self.setSessionAwareSubtitleVisible(false)
            self.userSelectedSubtitleTrack = true
            self.recordUserSubtitleSelection(enabled: false)
            self.rendererDisableSubtitles()
            self.subtitleEntries.removeAll()
            self.vlcSubtitleSelection = .none
            self.updateSubtitleButtonAppearance()
            self.updateSubtitleTracksMenu()
        }
        alert.addAction(disableAction)

        for (index, _) in subtitleURLs.enumerated() {
            let title = index < subtitleNames.count ? subtitleNames[index] : "Subtitle \(index + 1)"
            let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                self.currentSubtitleIndex = index
                self.setSessionAwareSubtitleVisible(true)
                self.userSelectedSubtitleTrack = true
                self.recordUserSubtitleSelection(enabled: true, displayName: title)
                self.vlcSubtitleSelection = .external(index: index)
                self.loadCurrentSubtitle()
                self.rendererApplySubtitleStyle(self.currentSubtitleStyle(visible: true))
                self.updateSubtitleButtonAppearance()
                self.updateSubtitleTracksMenu()
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
            let showRemainingTime: Bool
            let preciseAdjustment: Bool
            let primaryColor: Color
            let secondaryColor: Color
            let inactiveColor: Color
            let defaultSkin: Bool
            var onEditingChanged: (Bool) -> Void
            var body: some View {
                MusicProgressSlider(
                    value: Binding(get: { model.position }, set: { model.position = $0 }),
                    inRange: 0...max(model.duration, 1.0),
                    activeFillColor: primaryColor,
                    fillColor: secondaryColor,
                    textColor: primaryColor.opacity(defaultSkin ? 0.7 : 0.78),
                    emptyColor: inactiveColor,
                    height: 33,
                    durationKnown: model.durationIsKnown,
                    showRemainingTime: showRemainingTime,
                    preciseAdjustment: preciseAdjustment,
                    segments: model.skipSegments,
                    onEditingChanged: onEditingChanged
                )
            }
        }

        if progressHostingController != nil {
            return
        }

        let mpvAdvancedControlsActive = isMPVRenderer && isMetalMPVRenderer && ExperimentalFeatureState.canUseExperimentalMPVPlayback
        let showRemainingTime = !isMPVRenderer
            || !mpvAdvancedControlsActive
            || (mpvAdvancedControlsActive && ProfileSettingsStore.active.bool(forKey: ExperimentalFeatureState.mpvShowRemainingTimeKey))
        let preciseAdjustment = mpvAdvancedControlsActive
            && ProfileSettingsStore.active.bool(forKey: ExperimentalFeatureState.mpvPreciseProgressKey)

        let host = UIHostingController(rootView: AnyView(ProgressHostView(
            model: progressModel,
            showRemainingTime: showRemainingTime,
            preciseAdjustment: preciseAdjustment,
            primaryColor: Color(activePlayerSkinAppearance.primary),
            secondaryColor: Color(activePlayerSkinAppearance.secondary),
            inactiveColor: Color(activePlayerSkinAppearance.inactive),
            defaultSkin: activePlayerSkin == .defaultSkin,
            onEditingChanged: { [weak self] editing in
                guard let self = self else { return }
                self.isSeeking = editing
                self.controlsHideWorkItem?.cancel()
                if !editing {
                    let target = max(0, self.progressModel.position)
                    self.rendererSeek(to: target)
#if os(iOS)
                    WatchTogetherCoordinator.shared.sendUserSeek(to: target, from: self)
#endif
                    self.showControlsTemporarily()
                }
            }
        ).profileScopedAppStorage()))

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

    private func showPlayerNotice(_ message: String, duration: TimeInterval = 3.8) {
        DispatchQueue.main.async {
            guard let label = self.playerNoticeBanner.viewWithTag(117) as? UILabel else { return }
            self.playerNoticeDismissWorkItem?.cancel()
            label.text = message
            self.playerNoticeBanner.isHidden = false
            self.view.bringSubviewToFront(self.playerNoticeBanner)
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
                self.playerNoticeBanner.alpha = 1.0
                self.playerNoticeBanner.transform = .identity
            }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseIn]) {
                    self.playerNoticeBanner.alpha = 0.0
                } completion: { _ in
                    self.playerNoticeBanner.isHidden = true
                }
            }
            self.playerNoticeDismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
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

    @objc private func containerTapped(_ gesture: UITapGestureRecognizer) {
        pendingContainerTapWorkItem?.cancel()
        if isCenterTapPlayPauseEnabled, isCentralPlaybackTap(gesture) {
            togglePlaybackFromVideoTap()
            return
        }

        guard !isMPVRenderer, isDoubleTapSeekEnabled else {
            performContainerTapToggle()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.performContainerTapToggle()
        }
        pendingContainerTapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + containerTapDoubleTapGraceInterval, execute: work)
    }

    private func performContainerTapToggle() {
        logSharedPlayerControl("container tapped controlsVisible=\(controlsVisible)")
        if controlsVisible {
            hideControls()
        } else {
            showControlsTemporarily()
        }
    }

    private func isCentralPlaybackTap(_ gesture: UITapGestureRecognizer) -> Bool {
        guard gesture.state == .ended else { return false }
        let bounds = videoContainer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let location = gesture.location(in: videoContainer)
        let buttonFrame = centerPlayPauseButton.convert(centerPlayPauseButton.bounds, to: videoContainer)
        if !buttonFrame.isEmpty {
            return buttonFrame.insetBy(dx: -24, dy: -24).contains(location)
        }

        let side = min(max(min(bounds.width, bounds.height) * 0.22, 88), 132)
        let centralRect = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        return centralRect.contains(location)
    }

    private func togglePlaybackFromVideoTap() {
        togglePlaybackFromVideoGesture(source: "central-video-tap")
    }

    private func togglePlaybackFromVideoGesture(source: String) {
        pendingContainerTapWorkItem?.cancel()
        suppressNextPlayPauseControlReveal = true
        playPauseRevealSuppressionToken += 1
        let suppressionToken = playPauseRevealSuppressionToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self,
                  self.playPauseRevealSuppressionToken == suppressionToken else { return }
            self.suppressNextPlayPauseControlReveal = false
        }
        logSharedPlayerControl("\(source) toggled playback paused=\(rendererIsPausedState())")
        if rendererIsPausedState() {
            markBackgroundRecoveryForegrounded(source: source)
            rendererPlay()
            updatePlayPauseButton(isPaused: false, shouldShowControls: false)
#if os(iOS)
            WatchTogetherCoordinator.shared.sendUserPlay(from: self)
#endif
        } else {
            rendererPausePlayback()
            updatePlayPauseButton(isPaused: true, shouldShowControls: false)
#if os(iOS)
            WatchTogetherCoordinator.shared.sendUserPause(from: self)
#endif
        }
    }

    private func showControlsTemporarily() {
        controlsHideWorkItem?.cancel()
        controlsVisibilityGeneration += 1
        let visibilityGeneration = controlsVisibilityGeneration
        controlsVisible = true

        warmMPVPictureInPictureForForegroundPlaybackIfNeeded(source: "controls-shown-track", minInterval: 10.0)
        updateBrightnessControlVisibility()
        updateVolumeControlVisibility()

        restorePlayerInteractionHierarchy()
        videoContainer.bringSubviewToFront(controlsOverlayView)
        videoContainer.bringSubviewToFront(overlayMenuDismissView)
        videoContainer.bringSubviewToFront(overlayMenuPanelView)
        videoContainer.bringSubviewToFront(centerPlayPauseButton)
        videoContainer.bringSubviewToFront(progressContainer)
        videoContainer.bringSubviewToFront(closeButton)
#if os(iOS)
        videoContainer.bringSubviewToFront(playbackLockButton)
#endif
        videoContainer.bringSubviewToFront(pipButton)
#if os(iOS)
        videoContainer.bringSubviewToFront(watchTogetherButton)
#endif
        videoContainer.bringSubviewToFront(playerTitleLabel)
        videoContainer.bringSubviewToFront(skipBackwardButton)
        videoContainer.bringSubviewToFront(skipForwardButton)
        videoContainer.bringSubviewToFront(speedIndicatorLabel)
        videoContainer.bringSubviewToFront(metalPerformanceOverlayLabel)
        videoContainer.bringSubviewToFront(subtitleButton)
        if supportsSharedPlayerControls {
            videoContainer.bringSubviewToFront(servicesButton)
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
            guard self.controlsVisibilityGeneration == visibilityGeneration,
                  self.controlsVisible else { return }
            self.controlsOverlayView.isHidden = false
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.centerPlayPauseButton.alpha = 1.0
                self.controlsOverlayView.alpha = 1.0
                self.progressContainer.alpha = 1.0
#if os(iOS)
                self.closeButton.alpha = PlayerPlaybackLockSettings.isLocked() ? 0.35 : 1.0
                self.playbackLockButton.alpha = self.playbackLockButton.isHidden ? 0.0 : 1.0
#else
                self.closeButton.alpha = 1.0
#endif
                self.pipButton.alpha = self.pipButton.isHidden ? 0.0 : 1.0
#if os(iOS)
                self.watchTogetherButton.alpha = self.watchTogetherButton.isHidden ? 0.0 : 1.0
#endif
                self.playerTitleLabel.alpha = self.playerTitleLabel.text?.isEmpty == false ? 1.0 : 0.0
                self.skipBackwardButton.alpha = 1.0
                self.skipForwardButton.alpha = 1.0
                if !self.subtitleButton.isHidden {
                    self.subtitleButton.alpha = 1.0
                }
                if self.supportsSharedPlayerControls {
                    if !self.servicesButton.isHidden {
                        self.servicesButton.alpha = 1.0
                    }
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
            guard let self,
                  self.controlsVisibilityGeneration == visibilityGeneration,
                  self.controlsVisible else { return }
            self.hideControls()
        }
        controlsHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func hideControls() {
        controlsHideWorkItem?.cancel()
        controlsVisibilityGeneration += 1
        let visibilityGeneration = controlsVisibilityGeneration
        controlsVisible = false
        hideOverlayMenu(animated: false)
#if !os(tvOS)
        isBrightnessControlActive = false
        isVolumeControlActive = false
#endif

        DispatchQueue.main.async {
            guard self.controlsVisibilityGeneration == visibilityGeneration,
                  !self.controlsVisible else { return }
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
                self.centerPlayPauseButton.alpha = 0.0
                self.controlsOverlayView.alpha = 0.0
                self.progressContainer.alpha = 0.0
                self.closeButton.alpha = 0.0
#if os(iOS)
                self.playbackLockButton.alpha = 0.0
#endif
                self.pipButton.alpha = 0.0
#if os(iOS)
                self.watchTogetherButton.alpha = 0.0
#endif
                self.playerTitleLabel.alpha = 0.0
                self.skipBackwardButton.alpha = 0.0
                self.skipForwardButton.alpha = 0.0
                self.subtitleButton.alpha = 0.0
                if self.supportsSharedPlayerControls {
                    self.servicesButton.alpha = 0.0
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
                guard self.controlsVisibilityGeneration == visibilityGeneration,
                      !self.controlsVisible else { return }
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
#if os(iOS)
        if case .active = watchTogetherConnectionState,
           !PlayerPlaybackLockSettings.isLocked(),
           presentedViewController == nil {
            presentWatchTogetherCloseConfirmation()
            return
        }
#endif
        closePlayer(allowWhilePlaybackLocked: false)
    }

#if os(iOS)
    private func presentWatchTogetherCloseConfirmation() {
        let alert = UIAlertController(
            title: "Watch Together is Active",
            message: "Closing the player affects the SharePlay session.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Leave Session & Close", style: .destructive) { [weak self] _ in
            WatchTogetherCoordinator.shared.leaveSession()
            self?.closePlayer(allowWhilePlaybackLocked: false)
        })
        alert.addAction(UIAlertAction(title: "End for Everyone & Close", style: .destructive) { [weak self] _ in
            WatchTogetherCoordinator.shared.endSessionForEveryone()
            self?.closePlayer(allowWhilePlaybackLocked: false)
        })
        alert.addAction(UIAlertAction(title: "Keep Watching", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = closeButton
            popover.sourceRect = closeButton.bounds
        }
        present(alert, animated: true)
    }
#endif

    private func closePlayer(allowWhilePlaybackLocked: Bool) {
#if os(iOS)
        guard allowWhilePlaybackLocked || !PlayerPlaybackLockSettings.isLocked() else {
            showControlsTemporarily()
            showPlayerNotice("Unlock the player before closing.")
            return
        }
#endif
        if isClosing { return }
        isClosing = true
        releaseEphemeralProxyOwnership()
        releaseMPVAppExitPictureInPictureOwnership(
            reason: "close-tapped",
            clearActivationCandidate: true
        )
        invalidateIPadGPUPlaybackLoadGate()
        pendingRendererRestartRetryGeneration = nil
        pendingPlaybackFailureAlert = nil
#if os(iOS)
        WatchTogetherCoordinator.shared.detach(self)
#endif
        suppressMPVAppExitPictureInPictureUntilForeground(reason: "close-tapped")
        cancelScheduledMPVPictureInPictureWarmups(reason: "close-tapped")
        refreshIdleTimerForPlayback(reason: "player-close")
        let isAnyPiPActive = rendererIsPictureInPictureActive()
        logSharedPlayerControl("closeTapped; pipActive=\(isAnyPiPActive); mediaInfo=\(String(describing: mediaInfo))")
        dismissEpisodeBrowser(animated: false, reason: "player-close")
        closeButton.isEnabled = false
        view.isUserInteractionEnabled = false

        var teardownPerformed = false
        let teardownAndStop: () -> Void = { [weak self] in
            guard let self else { return }
            if teardownPerformed { return }
            teardownPerformed = true
            self.renderer.setPictureInPictureStopRequestHandler(nil)

            if let mpv = self.mpvRenderer {
                mpv.delegate = nil
            }
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
            if let metal = self.metalMPVRenderer {
                metal.delegate = nil
            }
            if let gpu = self.gpuMPVRenderer {
                gpu.delegate = nil
            }
#endif
            if let vlc = self.vlcRenderer {
                vlc.delegate = nil
            }

            if self.pipController?.isPictureInPictureActive == true
                || self.pipController?.isPictureInPictureStartPending == true {
                self.cancelMPVPictureInPictureStartRequests(reason: "close-tapped")
                self.pipController?.stopPictureInPicture(source: "close-tapped")
            }
            self.pipController?.delegate = nil

            self.rendererStop()
            self.logSharedPlayerControl("renderer.stop called from closeTapped")
            ProgressManager.shared.flushPendingSave()
            self.postPlayerDidCloseNotification()
            self.finishMediaStatePlaybackLeaseIfNeeded()
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

#if os(iOS)
    @objc private func playbackLockTapped() {
        let shouldLock = !PlayerPlaybackLockSettings.isLocked()
        PlayerPlaybackLockSettings.setLocked(
            shouldLock,
            interfaceOrientation: PlayerPlaybackLockSettings.capturedInterfaceOrientation(
                scene: view.window?.windowScene,
                viewBounds: view.bounds
            )
        )
        applyPlaybackLockState(capturingOrientationIfNeeded: true)
        showControlsTemporarily()
        showPlayerNotice(shouldLock ? "Playback locked. Next Episode stays available." : "Playback unlocked.")
    }

    private func applyPlaybackLockState(capturingOrientationIfNeeded: Bool) {
        if capturingOrientationIfNeeded,
           PlayerPlaybackLockSettings.isLocked(),
           PlayerPlaybackLockSettings.lockedOrientationMask() == nil {
            PlayerPlaybackLockSettings.setLocked(
                true,
                interfaceOrientation: view.window?.windowScene?.interfaceOrientation
            )
        }

        let available = PlayerPlaybackLockSettings.isEnabled()
        let locked = PlayerPlaybackLockSettings.isLocked()
        playbackLockButton.isHidden = !available
        playbackLockButton.isEnabled = available
        let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        playbackLockButton.setImage(
            UIImage(systemName: locked ? "lock.fill" : "lock.open", withConfiguration: configuration),
            for: .normal
        )
        playbackLockButton.accessibilityLabel = locked ? "Unlock player" : "Lock player"
        playbackLockButton.accessibilityHint = locked
            ? "Allows orientation changes and closing the video"
            : "Locks the current orientation and prevents closing the video"
        playbackLockButton.accessibilityValue = locked ? "Locked" : "Unlocked"
        playbackLockButton.alpha = available && controlsVisible ? 1.0 : 0.0
        closeButton.isEnabled = !locked
        closeButton.alpha = controlsVisible ? (locked ? 0.35 : 1.0) : 0.0
        closeButton.accessibilityHint = locked ? "Unlock the player before closing" : nil
        isModalInPresentation = locked
        if let scene = view.window?.windowScene ?? playbackWindowScene {
            AppDelegate.setOrientationLock(
                locked ? (PlayerPlaybackLockSettings.lockedOrientationMask() ?? supportedInterfaceOrientations) : .all,
                for: scene
            )
        }

        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
#endif

    private func postPlayerDidCloseNotification() {
        guard !hasFinalizedMediaStatePlayback else { return }
        hasFinalizedMediaStatePlayback = true
        var userInfo: [String: Any] = [:]
        if let mediaInfo {
            syncTraktProgressOnPlaybackCloseIfNeeded(for: mediaInfo, reason: "close")
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

    private func beginMediaStatePlaybackLeaseIfNeeded() {
        guard mediaInfo != nil, !hasBegunMediaStatePlaybackLease else { return }
        hasBegunMediaStatePlaybackLease = true
        MediaStatePlaybackLease.begin()
    }

    private func finishMediaStatePlaybackLeaseIfNeeded() {
        guard hasBegunMediaStatePlaybackLease, !hasEndedMediaStatePlaybackLease else { return }
        hasEndedMediaStatePlaybackLease = true
        MediaStatePlaybackLease.end()
    }

    private func persistCurrentProgressForAccountBoundary() {
        guard playbackProfileIsStillActive("the final position write") else { return }
        guard cachedPosition.isFinite,
              cachedDuration.isFinite,
              cachedPosition >= 0,
              cachedDuration >= 5,
              cachedPosition <= cachedDuration + 2,
              let mediaInfo else { return }
        let position = min(cachedPosition, cachedDuration)

        switch mediaInfo {
        case .movie(let id, let title, let posterURL, _):
            ProgressManager.shared.updateMovieProgress(
                movieId: id,
                title: title,
                currentTime: position,
                totalDuration: cachedDuration,
                posterURL: posterURL,
                owner: playbackOwnerProfileID
            )
        case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, let showPosterURL, let isAnime):
            ProgressManager.shared.updateEpisodeProgress(
                showId: showId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                currentTime: position,
                totalDuration: cachedDuration,
                showTitle: showTitle,
                showPosterURL: showPosterURL,
                playbackContext: playbackContextForCurrentEpisode(
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber
                ),
                isAnime: isAnime || episodePlaybackContext?.hasAnimeMediaId == true,
                owner: playbackOwnerProfileID
            )
        }
    }

    @objc private func handleMediaStateAccountBoundary() {
        guard hasBegunMediaStatePlaybackLease,
              !hasEndedMediaStatePlaybackLease else { return }

        isClosing = true
        releaseEphemeralProxyOwnership()
        releaseMPVAppExitPictureInPictureOwnership(
            reason: "icloud-account-boundary",
            clearActivationCandidate: true
        )
        renderer.setPictureInPictureStopRequestHandler(nil)
        suppressMPVAppExitPictureInPictureUntilForeground(reason: "icloud-account-boundary")
        cancelScheduledMPVPictureInPictureWarmups(reason: "icloud-account-boundary")
        if pipController?.isPictureInPictureActive == true
            || pipController?.isPictureInPictureStartPending == true {
            cancelMPVPictureInPictureStartRequests(reason: "icloud-account-boundary")
            pipController?.stopPictureInPicture(source: "icloud-account-boundary")
        }
        pipController?.delegate = nil
        persistCurrentProgressForAccountBoundary()
        rendererStop()
        ProgressManager.shared.flushPendingSave()
        postPlayerDidCloseNotification()
        finishMediaStatePlaybackLeaseIfNeeded()
        dismiss(animated: false)
    }

    private func handleActiveProfileWillChange(to incomingProfileID: UUID) {
        guard incomingProfileID != playbackOwnerProfileID, !isClosing else { return }
        Logger.shared.log(
            "PlayerViewController: closing playback before its owning profile changes",
            type: "Player"
        )
        if hasBegunMediaStatePlaybackLease, !hasEndedMediaStatePlaybackLease {
            handleMediaStateAccountBoundary()
            return
        }

        isClosing = true
        releaseEphemeralProxyOwnership()
        rendererPausePlayback()
        rendererStop()
        postPlayerDidCloseNotification()
        dismiss(animated: false)
    }

    @objc private func handleActiveProfileDidChange() {

        guard !isClosing, shouldStopPlaybackForActiveProfile() else { return }
        Logger.shared.log(
            "PlayerViewController: stopping playback because the newly active profile may not see this title",
            type: "Player"
        )

        rendererPausePlayback()
        closePlayer(allowWhilePlaybackLocked: true)
    }

    private func shouldStopPlaybackForActiveProfile() -> Bool {
        guard ProfileManager.shared.isKidsModeActive else { return false }
        guard let request = kidsGateRequestForCurrentPlayback() else { return true }
        return KidsPlaybackGate.decision(for: request) != .allow
    }

    private func kidsGateRequestForCurrentPlayback() -> PlaybackRequest? {
        guard let mediaInfo else { return nil }
        return PlaybackRequest(
            url: initialURL ?? URL(fileURLWithPath: "/"),
            mediaInfo: mediaInfo,
            episodePlaybackContext: episodePlaybackContext,
            title: playerTitleOverride ?? "",
            isAnime: isAnimeHint ?? false
        )
    }

    @objc private func pipTapped() {
        if vlcRenderer != nil {
            Logger.shared.log("[PlayerVC.PiP] button ignored for VLC renderer: unavailable", type: "Player")
            updatePiPButtonVisibility()
            return
        }
        guard let pip = pipController else { return }
        logPictureInPicture("button tap state active=\(pip.isPictureInPictureActive) possible=\(pip.isPictureInPicturePossible) supported=\(pip.isPictureInPictureSupported) isVLC=\(isVLCPlayer)")
        if pip.isPictureInPictureActive {
            logPictureInPicture("stopping PiP from button")
            let loadGeneration = playbackLoadGeneration
            let transitionAttemptID = pip.transitionAttemptID
            disarmMPVPictureInPictureRestartAfterStop(reason: "button-stop")
            pip.stopPictureInPicture(source: "button")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak pip] in
                guard let self,
                      let pip,
                      self.pipController === pip,
                      loadGeneration == self.playbackLoadGeneration,
                      pip.playbackLoadGeneration == loadGeneration,
                      pip.transitionAttemptID == transitionAttemptID,
                      self.isRunning,
                      !self.isClosing,
                      !pip.isPictureInPictureActive else { return }
                self.logPictureInPicture("MPV PiP stop timeout reached inactive state; restoring foreground")
                self.rendererFinishPictureInPicture()
                self.updatePiPButtonVisibility()
                self.scheduleMPVPictureInPictureForegroundWarmup(
                    source: "button-stop-timeout-rewarm",
                    delays: [0.25, 1.10],
                    forceFirst: true
                )
            }
        } else {
            startMPVPictureInPictureWhenPossible(source: "button")
        }
    }

    private func abortMPVAppExitPictureInPictureForPlaybackIntentChange(
        controller: PiPController,
        source: String,
        expectedLoadGeneration: Int,
        expectedIntentGeneration: Int
    ) {
        guard pipController === controller,
              playbackLoadGeneration == expectedLoadGeneration,
              controller.playbackLoadGeneration == expectedLoadGeneration else { return }
        logPictureInPicture(
            "MPV app-exit PiP canceled after playback intent changed source=\(source) expectedIntent=\(expectedIntentGeneration) currentIntent=\(rendererPlaybackIntentGeneration) paused=\(rendererIsPausedState())"
        )
        controller.setCanStartPictureInPictureAutomaticallyFromInline(false)
        cancelMPVPictureInPictureStartRequests(reason: "\(source)-playback-intent-changed")
        releaseMPVAppExitPictureInPictureOwnership(
            reason: "\(source)-playback-intent-changed"
        )
        if controller.isPictureInPictureActive || controller.isPictureInPictureStartPending {
            controller.stopPictureInPicture(source: "playback-intent-changed")
        }
        rendererFinishPictureInPicture()

        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self,
                  let controller,
                  self.pipController === controller,
                  self.playbackLoadGeneration == expectedLoadGeneration,
                  controller.playbackLoadGeneration == expectedLoadGeneration,
                  self.isRunning,
                  !self.isClosing else { return }
            self.installMPVPictureInPictureController(
                reason: "playback-intent-changed"
            )
            self.rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
            if self.mpvBackgroundLifecycleIsArmed {
                self.scheduleMPVBackgroundAudioFallback(
                    source: "\(source)-playback-intent-changed",
                    delay: 0.25
                )
            }
            self.updatePiPButtonVisibility()
        }
    }

    private func retireMPVPictureInPictureAfterRendererActivationFailure(
        controller: PiPController,
        source: String,
        attemptID: Int
    ) {

        guard pipController === controller,
              controller.playbackLoadGeneration == playbackLoadGeneration,
              controller.transitionAttemptID == attemptID,
              mpvPiPStartAttemptID == attemptID,
              mpvExpectedPiPCallbackAttemptID == attemptID else { return }
        let loadGeneration = playbackLoadGeneration
        logPictureInPicture(
            "retiring PiP after renderer activation failure source=\(source) attemptID=\(attemptID) renderer={\(rendererPictureInPictureDebugSnapshot())}"
        )
        controller.setCanStartPictureInPictureAutomaticallyFromInline(false)
        cancelMPVPictureInPictureStartRequests(
            reason: "\(source)-renderer-activation-failed"
        )
        releaseMPVAppExitPictureInPictureOwnership(
            reason: "\(source)-renderer-activation-failed"
        )
        if controller.isPictureInPictureActive || controller.isPictureInPictureStartPending {
            controller.stopPictureInPicture(source: "renderer-activation-failed")
        }
        rendererFinishPictureInPicture()
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self,
                  let controller,
                  self.pipController === controller,
                  self.playbackLoadGeneration == loadGeneration,
                  controller.playbackLoadGeneration == loadGeneration,
                  self.isRunning,
                  !self.isClosing else { return }
            self.installMPVPictureInPictureController(
                reason: "\(source)-renderer-activation-failed"
            )
            self.rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
            if self.mpvBackgroundLifecycleIsArmed {
                self.scheduleMPVBackgroundAudioFallback(
                    source: "\(source)-renderer-activation-failed",
                    delay: 0.25
                )
            }
            self.updatePiPButtonVisibility()
        }
    }

    private func startMPVPictureInPictureWhenPossible(source: String) {
        guard isMPVRenderer, !isVLCPlayer else {
            logPictureInPicture("MPV PiP start ignored source=\(source): active renderer is not MPV")
            return
        }
        guard let pip = pipController else { return }
        if source == "button" {
            clearMPVAppExitPictureInPictureSuppression(reason: "manual-button-start")
        }
        guard !pip.isPictureInPictureActive else {
            logPictureInPicture("start ignored source=\(source): PiP already active")
            return
        }
        guard !pip.isPictureInPictureStartPending else {
            logPictureInPicture("start ignored source=\(source): PiP transition already pending")
            return
        }
        mpvPiPStartAttemptID += 1
        let attemptID = mpvPiPStartAttemptID
        let requiresStablePlayingIntent = source != "button"
        let playbackIntentGeneration = rendererPlaybackIntentGeneration
        armMPVPictureInPictureController(pip, reason: "\(source)-explicit")
        if requiresStablePlayingIntent {
            authorizeMPVAutomaticPictureInPicture(for: pip, source: source)
        } else {
            clearMPVAutomaticPictureInPictureAuthorization(reason: "manual-button-start")
        }
        let loadGeneration = playbackLoadGeneration
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        logPictureInPicture("prepare MPV PiP begin source=\(source) attemptID=\(attemptID) appState=\(appState) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration)) ready=\(playbackDidStart)")
        Task { @MainActor [weak self, weak pip] in
            guard let self, let pip else { return }
            let primed = await self.prepareMPVPictureInPictureRenderer(
                source: source,
                activateLayer: false
            )
            guard attemptID == self.mpvPiPStartAttemptID,
                  loadGeneration == self.playbackLoadGeneration,
                  self.pipController === pip,
                  pip.playbackLoadGeneration == loadGeneration,
                  pip.transitionAttemptID == attemptID,
                  self.mpvExpectedPiPCallbackAttemptID == attemptID,
                  self.isRunning,
                  self.isMPVRenderer,
                  !self.isVLCPlayer,
                  !self.isClosing else { return }
            guard !requiresStablePlayingIntent
                    || (playbackIntentGeneration == self.rendererPlaybackIntentGeneration
                        && !self.rendererIsPausedState()) else {
                self.abortMPVAppExitPictureInPictureForPlaybackIntentChange(
                    controller: pip,
                    source: source,
                    expectedLoadGeneration: loadGeneration,
                    expectedIntentGeneration: playbackIntentGeneration
                )
                return
            }

            self.logPictureInPicture("prepare MPV PiP end source=\(source) attemptID=\(attemptID) primed=\(primed) subs={\(self.subtitlePictureInPictureDebugSnapshot())}")
            if pip.isPictureInPictureActive {

                self.mpvAppExitPiPStartRequested = false
                self.mpvActivePiPCallbackAttemptID = attemptID
                if primed {
                    guard self.rendererActivatePictureInPictureLayer() else {
                        self.logPictureInPicture(
                            "MPV PiP active automatic join rejected renderer activation source=\(source) attemptID=\(attemptID)"
                        )
                        self.retireMPVPictureInPictureAfterRendererActivationFailure(
                            controller: pip,
                            source: "\(source)-active-join",
                            attemptID: attemptID
                        )
                        return
                    }
                }
                pip.updatePlaybackState()
                self.updatePiPButtonVisibility()
                self.logPictureInPicture(
                    "MPV PiP explicit prepare joined active automatic transition source=\(source) attemptID=\(attemptID) loadGeneration=\(loadGeneration) primed=\(primed)"
                )
                return
            }
            guard primed else {
                self.mpvAppExitPiPStartRequested = false
                self.releaseMPVAppExitPictureInPictureOwnership(
                    reason: "\(source)-prepare-failed"
                )
                self.rendererFinishPictureInPicture()
                self.updatePiPButtonVisibility()
                return
            }

            pip.updatePlaybackState()

            let possibleDeadline = CACurrentMediaTime() + 1
            while !pip.isPictureInPicturePossible,
                  !pip.isPictureInPictureActive,
                  (!requiresStablePlayingIntent
                    || (playbackIntentGeneration == self.rendererPlaybackIntentGeneration
                        && !self.rendererIsPausedState())),
                  CACurrentMediaTime() < possibleDeadline {
                guard attemptID == self.mpvPiPStartAttemptID,
                      loadGeneration == self.playbackLoadGeneration,
                      self.pipController === pip,
                      pip.playbackLoadGeneration == loadGeneration,
                      pip.transitionAttemptID == attemptID,
                      self.mpvExpectedPiPCallbackAttemptID == attemptID,
                      self.isRunning else { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }

            guard attemptID == self.mpvPiPStartAttemptID,
                  loadGeneration == self.playbackLoadGeneration,
                  self.pipController === pip,
                  pip.playbackLoadGeneration == loadGeneration,
                  pip.transitionAttemptID == attemptID,
                  self.mpvExpectedPiPCallbackAttemptID == attemptID,
                  self.isRunning else { return }
            guard !requiresStablePlayingIntent
                    || (playbackIntentGeneration == self.rendererPlaybackIntentGeneration
                        && !self.rendererIsPausedState()) else {
                self.abortMPVAppExitPictureInPictureForPlaybackIntentChange(
                    controller: pip,
                    source: source,
                    expectedLoadGeneration: loadGeneration,
                    expectedIntentGeneration: playbackIntentGeneration
                )
                return
            }
            if pip.isPictureInPictureActive {
                self.mpvAppExitPiPStartRequested = false
                self.mpvActivePiPCallbackAttemptID = attemptID
                guard self.rendererActivatePictureInPictureLayer() else {
                    self.logPictureInPicture(
                        "MPV PiP readiness join rejected renderer activation source=\(source) attemptID=\(attemptID)"
                    )
                    self.retireMPVPictureInPictureAfterRendererActivationFailure(
                        controller: pip,
                        source: "\(source)-readiness-join",
                        attemptID: attemptID
                    )
                    return
                }
                pip.updatePlaybackState()
                self.updatePiPButtonVisibility()
                self.logPictureInPicture(
                    "MPV PiP explicit readiness wait joined active automatic transition source=\(source) attemptID=\(attemptID) loadGeneration=\(loadGeneration)"
                )
                return
            }
            guard pip.isPictureInPicturePossible else {
                self.logPictureInPicture("MPV PiP controller did not become possible source=\(source) primed=\(primed) renderer={\(self.rendererPictureInPictureDebugSnapshot())}")
                self.mpvAppExitPiPStartRequested = false
                self.releaseMPVAppExitPictureInPictureOwnership(
                    reason: "\(source)-controller-not-possible"
                )
                self.rendererFinishPictureInPicture()
                self.updatePiPButtonVisibility()
                return
            }

            self.logPictureInPicture("starting MPV PiP source=\(source) state=ready")
            if self.renderer.prefersPictureInPictureLayerActivationBeforeStart {
                guard self.rendererActivatePictureInPictureLayer() else {
                    self.logPictureInPicture(
                        "MPV PiP start canceled after renderer activation rejection source=\(source) attemptID=\(attemptID)"
                    )
                    self.retireMPVPictureInPictureAfterRendererActivationFailure(
                        controller: pip,
                        source: "\(source)-pre-start",
                        attemptID: attemptID
                    )
                    return
                }
                pip.updatePlaybackState()
            }
            pip.startPictureInPicture()

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak pip] in
                guard let self,
                      attemptID == self.mpvPiPStartAttemptID,
                      loadGeneration == self.playbackLoadGeneration,
                      let pip,
                      self.pipController === pip,
                      pip.playbackLoadGeneration == loadGeneration,
                      pip.transitionAttemptID == attemptID,
                      self.mpvExpectedPiPCallbackAttemptID == attemptID,
                      self.isRunning,
                      !pip.isPictureInPictureActive else { return }
                self.logPictureInPicture("MPV PiP start timed out without active state source=\(source); restoring foreground")
                self.cancelMPVPictureInPictureStartRequests(reason: "\(source)-start-timeout")
                self.releaseMPVAppExitPictureInPictureOwnership(
                    reason: "\(source)-start-timeout"
                )
                pip.stopPictureInPicture(source: "\(source)-start-timeout")
                self.mpvAppExitPiPStartRequested = false
                self.rendererFinishPictureInPicture()
                self.installMPVPictureInPictureController(
                    reason: "\(source)-start-timeout-retire"
                )
                self.rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
                if self.mpvBackgroundLifecycleIsArmed {
                    self.scheduleMPVBackgroundAudioFallback(
                        source: "\(source)-start-timeout",
                        delay: 0.25
                    )
                }
                self.updatePiPButtonVisibility()
            }
        }
    }

    private func updatePosition(_ position: Double, duration: Double) {
        guard !isClosing else { return }

        let safePosition: Double
        if position.isFinite, position >= 0 {
            safePosition = position
        } else {
            safePosition = max(0, cachedPosition)
        }

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
                pendingInitialResumeRetryCount = 0
                pendingInitialResumeLastRetryAt = nil
            }
        } else {
            waitingForInitialResume = false
        }

        if isVLCPlayer {
            if playbackAdvanced || safePosition > 0.1 {
                markPlaybackStarted(reason: "position")
            }
        } else if let lastTracePosition = playbackTraceLastProgressPosition {
            if safePosition > lastTracePosition + 0.05 {
                playbackTraceProgressAdvanceCount += 1
                playbackTraceLastProgressPosition = safePosition
                if playbackTraceProgressAdvanceCount == 1 {
                    logPlaybackStage(
                        "first-progress",
                        "position=\(secondsText(safePosition)) duration=\(secondsText(effectiveDuration)) waitingResume=\(waitingForInitialResume)"
                    )
                }
                if playbackTraceProgressAdvanceCount >= 2 {
                    markPlaybackStarted(reason: "progressing-position")
                }
            } else if safePosition + 2.0 < lastTracePosition {
                playbackTraceLastProgressPosition = safePosition
                playbackTraceProgressAdvanceCount = 0
                logPlaybackStage("position-discontinuity", "from=\(secondsText(lastTracePosition)) to=\(secondsText(safePosition))")
            }
        } else {
            playbackTraceLastProgressPosition = safePosition
            if playbackAdvanced {
                playbackTraceProgressAdvanceCount = 1
                logPlaybackStage(
                    "first-progress",
                    "position=\(secondsText(safePosition)) duration=\(secondsText(effectiveDuration)) waitingResume=\(waitingForInitialResume)"
                )
            }
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
                self.retryPendingInitialResumeIfNeeded(currentPosition: safePosition)
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
                    if self.isVLCPlayer {
                        self.logVLCUI("loading cleared by position advance safe=\(self.secondsText(safePosition)) effectiveDuration=\(self.secondsText(effectiveDuration)) waitingResume=\(waitingForInitialResume)", type: "VLCPlayback")
                    }
                    self.isRendererLoading = false
                    self.setPlayerLoadingIndicatorVisible(false)
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

            if self.isRendererLoading && playbackAdvanced {
                if self.isVLCPlayer {
                    self.logVLCUI("loading cleared by position advance safe=\(self.secondsText(safePosition)) effectiveDuration=\(self.secondsText(effectiveDuration)) waitingResume=\(waitingForInitialResume)", type: "VLCPlayback")
                }
                self.isRendererLoading = false
                self.setPlayerLoadingIndicatorVisible(false)
                self.centerPlayPauseButton.isHidden = false
                self.updatePlayPauseButton(isPaused: self.rendererIsPausedState(), shouldShowControls: false)
            } else if !self.isRendererLoading && self.loadingIndicator.alpha > 0.0 {
                self.setPlayerLoadingIndicatorVisible(false)
                self.centerPlayPauseButton.isHidden = false
            }
        }

        guard !waitingForInitialResume else { return }

        guard durationIsReliable, effectiveDuration.isFinite, effectiveDuration > 0, safePosition >= 0, let info = mediaInfo else { return }
        let persistPosition = min(safePosition, effectiveDuration)
        guard shouldPersistProgressAfterBackgroundRecovery(
            safePosition: persistPosition,
            effectiveDuration: effectiveDuration,
            durationIsReliable: durationIsReliable
        ) else {
            return
        }
        guard shouldPersistProgressDuringVLCSubtitleStyleReload(
            safePosition: persistPosition,
            effectiveDuration: effectiveDuration,
            durationIsReliable: durationIsReliable
        ) else {
            return
        }

        guard playbackProfileIsStillActive("a periodic position write") else { return }

        let progressPlaybackContext: EpisodePlaybackContext?
        if case .episode(_, let seasonNumber, let episodeNumber, _, _, _) = info {
            progressPlaybackContext = playbackContextForCurrentEpisode(
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber
            )
        } else {
            progressPlaybackContext = nil
        }
        PlaybackProgressPersistence.persist(
            mediaInfo: info,
            position: persistPosition,
            duration: effectiveDuration,
            playbackContext: progressPlaybackContext,
            owner: playbackOwnerProfileID,
            progressAuthority: playbackProfileAuthority.progress,
            traktAction: !rendererIsPausedState() && playbackDidStart ? .start : nil
        )
    }

    private func retryPendingInitialResumeIfNeeded(currentPosition: Double) {
        guard !isClosing,
              isMetalMPVRenderer,
              !isVLCPlayer,
              !isSeeking,
              let target = pendingInitialResumeTarget,
              let deadline = pendingInitialResumeDeadline else {
            return
        }
        let now = Date()
        guard now < deadline, currentPosition + 2.0 < target else { return }
        guard pendingInitialResumeRetryCount < 3 else { return }
        if let lastRetry = pendingInitialResumeLastRetryAt, now.timeIntervalSince(lastRetry) < 0.9 {
            return
        }

        pendingInitialResumeRetryCount += 1
        pendingInitialResumeLastRetryAt = now
        Logger.shared.log(
            "[PlayerVC.progress] retrying MoltenVK initial resume target=\(secondsText(target)) position=\(secondsText(currentPosition)) attempt=\(pendingInitialResumeRetryCount)",
            type: "MPV"
        )
        rendererSeek(to: target)
    }

    private func logVLCUIProgressIfNeeded(rawPosition: Double, rawDuration: Double, safePosition: Double, effectiveDuration: Double, durationIsReliable: Bool, waitingForInitialResume: Bool) {
        guard isVLCPlayer else { return }
        logVLCUISteadyHeartbeatIfNeeded(
            safePosition: safePosition,
            effectiveDuration: effectiveDuration,
            durationIsReliable: durationIsReliable
        )

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
    var mediaYear: Int? = nil
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
    let originalAudioLanguage: String?
    let imdbId: String?
    let episode: TMDBEpisode
    let isAnime: Bool
    let isSpecial: Bool
    let playbackContext: EpisodePlaybackContext?
    let originalTMDBSeasonNumber: Int?
    let originalTMDBEpisodeNumber: Int?
    let progress: Double
    let isDownloaded: Bool
    #if !os(tvOS)
    let downloadItem: DownloadItem?
    #endif
    let isCurrent: Bool
    var mediaYear: Int? = nil

    var imageURL: String? {
        PlayerEpisodeBrowserViewModel.fullImageURL(from: episode.stillPath)
            ?? posterURL
            ?? showPosterURL
    }

    var artworkURLs: [String] {
        var urls: [String] = []
        var candidates = [
            PlayerEpisodeBrowserViewModel.fullImageURL(from: episode.stillPath),
            posterURL,
            showPosterURL
        ]
        #if !os(tvOS)
        candidates.append(downloadItem?.posterURL)
        #endif
        for candidate in candidates {
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
    private struct CachedEpisodeBrowserLoad {
        let seasons: [PlayerEpisodeBrowserSeason]
        let currentItemID: String?
        let storedAt: Date
    }

    private static var loadCache: [String: CachedEpisodeBrowserLoad] = [:]
    private static let loadCacheTTL: TimeInterval = 10 * 60

    @Published var seasons: [PlayerEpisodeBrowserSeason] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentItemID: String?

    let seed: PlayerEpisodeBrowserSeed
    private var didLoad = false
    private var resolvedMediaYear: Int?
    private var canonicalCurrentPlaybackContext: EpisodePlaybackContext?

    init(seed: PlayerEpisodeBrowserSeed) {
        self.seed = seed
        self.resolvedMediaYear = seed.mediaYear
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await load()
    }

    func itemAfterCurrent(skippingKnownFillers: Bool = false) async -> PlayerEpisodeBrowserItem? {
        if !didLoad {
            await load()
        }
        if seed.isAnime,
           seed.currentPlaybackContext?.hasAnimeMediaId == true,
           canonicalCurrentPlaybackContext == nil {
            return nil
        }
        let currentContext = canonicalCurrentPlaybackContext ?? seed.currentPlaybackContext
        let currentIsSpecial = canonicalCurrentPlaybackContext?.isSpecial
            ?? (seed.currentPlaybackContext?.isSpecial == true || seed.currentSeasonNumber == 0)
        let eligibleItems = seasons.flatMap(\.episodes).filter { item in
            guard currentIsSpecial else { return !item.isSpecial }
            guard item.isSpecial,
                  let currentContext,
                  let itemContext = item.playbackContext else {
                return false
            }
            if let currentAniListId = currentContext.positiveAniListMediaId {
                return itemContext.positiveAniListMediaId == currentAniListId
            }
            if let currentProviderID = currentContext.anilistMediaId {
                return itemContext.anilistMediaId == currentProviderID
            }
            if let currentKitsuId = currentContext.kitsuMediaId {
                return itemContext.kitsuMediaId == currentKitsuId
            }
            return itemContext.localSeasonNumber == currentContext.localSeasonNumber
        }
        let allItems = eligibleItems.sorted { lhs, rhs in
            if lhs.episode.seasonNumber == rhs.episode.seasonNumber {
                return lhs.episode.episodeNumber < rhs.episode.episodeNumber
            }
            return lhs.episode.seasonNumber < rhs.episode.seasonNumber
        }
        guard let index = allItems.firstIndex(where: { item in
            isCanonicalCurrentItem(item, currentContext: currentContext)
        }) else { return nil }
        let nextIndex = allItems.index(after: index)
        guard nextIndex < allItems.endIndex else { return nil }

        let immediateNext = allItems[nextIndex]
        guard skippingKnownFillers,
              seed.isAnime,
              !currentIsSpecial else {
            return immediateNext
        }

        var fillerEpisodeNumbersByProviderId: [Int: Set<Int>] = [:]
        for item in allItems[nextIndex...] {
            guard !Task.isCancelled else { return nil }

            guard item.isAnime,
                  !item.isSpecial,
                  let providerId = item.playbackContext?.anilistMediaId else {
                return immediateNext
            }

            let fillerEpisodeNumbers: Set<Int>
            if let cached = fillerEpisodeNumbersByProviderId[providerId] {
                fillerEpisodeNumbers = cached
            } else {
                let malId: Int?
                if providerId < 0 {
                    malId = RemoteMediaNumericBoundary.positiveMagnitude(providerId)
                } else if let cached = TrackerManager.shared.cachedMyAnimeListAnimeId(fromAniListId: providerId) {
                    malId = cached
                } else {
                    malId = await TrackerManager.shared.resolveMyAnimeListAnimeId(fromAniListId: providerId)
                }

                guard let malId, malId > 0 else {
                    Logger.shared.log(
                        "NextEpisode: filler metadata unavailable for providerId=\(providerId); using immediate next episode",
                        type: "Player"
                    )
                    return immediateNext
                }

                do {
                    fillerEpisodeNumbers = try await AnimeFillerService.shared.fillerEpisodeNumbers(malId: malId)
                    fillerEpisodeNumbersByProviderId[providerId] = fillerEpisodeNumbers
                } catch is CancellationError {
                    return nil
                } catch {
                    Logger.shared.log(
                        "NextEpisode: filler lookup failed providerId=\(providerId) error=\(error.localizedDescription); using immediate next episode",
                        type: "Error"
                    )
                    return immediateNext
                }
            }

            if fillerEpisodeNumbers.contains(item.episode.episodeNumber) {
                Logger.shared.log(
                    "NextEpisode: skipping known filler S\(item.episode.seasonNumber)E\(item.episode.episodeNumber)",
                    type: "Player"
                )
                continue
            }
            return item
        }
        return nil
    }

    private func load() async {
        didLoad = true
        let cacheKey = Self.cacheKey(for: seed)
        if let cached = Self.cachedLoad(for: cacheKey) {
            seasons = cached.seasons
            currentItemID = cached.currentItemID
            canonicalCurrentPlaybackContext = cached.seasons
                .flatMap(\.episodes)
                .first(where: { $0.id == cached.currentItemID })?
                .playbackContext
            isLoading = false
            errorMessage = nil
            Logger.shared.log("Player episode browser cache hit key=\(cacheKey) seasons=\(cached.seasons.count)", type: "Player")
            return
        }

        isLoading = true
        errorMessage = nil
        seasons = []
        currentItemID = nil
        canonicalCurrentPlaybackContext = nil

        do {
            let tmdbService = TMDBService.shared
            let tvShow = try await tmdbService.getTVShowWithSeasons(id: seed.showId)
            let showTitle = tvShow.name.isEmpty ? seed.showTitle : tvShow.name
            let showPosterURL = seed.showPosterURL ?? tvShow.fullPosterURL
            let resolvedImdbId = seed.imdbId ?? tvShow.externalIds?.imdbId
            let fetchedMediaYear = tvShow.firstAirDate.flatMap { Int($0.prefix(4)) }
            resolvedMediaYear = seed.mediaYear
                ?? fetchedMediaYear.flatMap { (1800...3000).contains($0) ? $0 : nil }
            var animeData: AniListAnimeWithSeasons?
            var specialContexts: [SpecialEpisodeListContext] = []

            if seed.isAnime && !PerformanceModeSettings.skipsAniListTraversalForAnimeDetails {
                let providerSeed = seed.currentPlaybackContext?.anilistMediaId
                    ?? seed.currentPlaybackContext?.positiveAniListMediaId
                animeData = try? await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                    title: seed.showTitle,
                    tmdbShowId: seed.showId,
                    tmdbService: tmdbService,
                    tmdbShowPoster: showPosterURL,
                    token: nil,
                    seedAniListId: providerSeed,
                    seedMALId: providerSeed.flatMap { value in
                        value < 0 ? RemoteMediaNumericBoundary.positiveMagnitude(value) : nil
                    }
                )
                if let animeData {
                    let mappings = animeData.seasons.map {
                        (
                            seasonNumber: $0.seasonNumber,
                            anilistId: $0.canonicalAniListId ?? $0.anilistId
                        )
                    }
                    TrackerManager.shared.registerAniListAnimeData(tmdbId: seed.showId, seasons: mappings)
                }

                let specialEntries: [AniListSpecialSearchEntry]
                if let providerSeed, providerSeed < 0 {
                    if let rootMALID = RemoteMediaNumericBoundary.positiveMagnitude(providerSeed) {
                        specialEntries = (try? await AniListService.shared.fetchRequiredMALSpecialSearchEntries(
                            tmdbShowId: seed.showId,
                            rootMalId: rootMALID,
                            fallbackPosterURL: showPosterURL
                        )) ?? []
                    } else {
                        specialEntries = []
                    }
                } else {
                    specialEntries = await AniListService.shared.fetchSpecialSearchEntries(
                        tmdbShowId: seed.showId,
                        fallbackPosterURL: showPosterURL,
                        baseAniListIds: animeData?.seasons.map(\.anilistId) ?? [],
                        tmdbService: tmdbService
                    )
                }
                specialContexts = specialEntries.compactMap {
                    SpecialEpisodeListContext(entry: $0, tmdbShowId: seed.showId)
                }
            } else if seed.isAnime {
                Logger.shared.log("EpisodeBrowser: skipped AniList traversal because detail traversal performance mode is enabled", type: "AniList")
            }

            var loaded: [PlayerEpisodeBrowserSeason] = []
            let animeAbsoluteEpisodeOffsets = animeData.map {
                absoluteEpisodeOffsetsBySeason(for: $0.seasons)
            } ?? [:]
            canonicalCurrentPlaybackContext = canonicalPlaybackContext(
                animeData: animeData,
                specialContexts: specialContexts,
                absoluteEpisodeOffsets: animeAbsoluteEpisodeOffsets
            )

            if canonicalCurrentPlaybackContext?.isSpecial == true,
               let currentSpecial = currentSpecialContext(from: specialContexts) {
                loaded.append(buildSpecialSeason(
                    context: currentSpecial,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    fallbackImdbId: resolvedImdbId,
                    originalAudioLanguage: tvShow.originalLanguage
                ))
                seasons = loaded
            } else if seed.isAnime,
                      let animeSeason = currentRegularSeason(in: animeData) {
                loaded.append(buildAnimeSeason(
                    animeSeason,
                    absoluteEpisodeOffset: animeAbsoluteEpisodeOffsets[animeSeason.seasonNumber] ?? 0,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    imdbId: resolvedImdbId,
                    originalAudioLanguage: tvShow.originalLanguage
                ))
                seasons = loaded

            } else if !seed.isAnime || animeData == nil,
                      let currentTMDBSeason = tvShow.seasons.first(where: { $0.seasonNumber == seed.currentSeasonNumber }),
                      let detail = try? await tmdbService.getSeasonDetails(tvShowId: seed.showId, seasonNumber: currentTMDBSeason.seasonNumber) {
                loaded.append(buildTMDBSeason(
                    summary: currentTMDBSeason,
                    detail: detail,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    imdbId: resolvedImdbId,
                    isSpecial: currentTMDBSeason.seasonNumber == 0,
                    originalAudioLanguage: tvShow.originalLanguage
                ))
                seasons = loaded
            }

            if seed.isAnime, let animeData {
                let currentProviderID = canonicalCurrentPlaybackContext?.positiveAniListMediaId
                    ?? canonicalCurrentPlaybackContext?.anilistMediaId
                let currentKitsuID = canonicalCurrentPlaybackContext?.kitsuMediaId
                for season in animeData.seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }) where
                    (season.canonicalAniListId ?? season.anilistId) != currentProviderID
                        && (currentKitsuID == nil || season.kitsuId != currentKitsuID) {
                    loaded.append(buildAnimeSeason(
                        season,
                        absoluteEpisodeOffset: animeAbsoluteEpisodeOffsets[season.seasonNumber] ?? 0,
                        showTitle: showTitle,
                        showPosterURL: showPosterURL,
                        imdbId: resolvedImdbId,
                        originalAudioLanguage: tvShow.originalLanguage
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
                        isSpecial: season.seasonNumber == 0,
                        originalAudioLanguage: tvShow.originalLanguage
                    ))
                    seasons = loaded
                }
            }

            for context in specialContexts where !loaded.contains(where: { $0.id == "special-\(context.id)" }) {
                loaded.append(buildSpecialSeason(
                    context: context,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    fallbackImdbId: resolvedImdbId,
                    originalAudioLanguage: tvShow.originalLanguage
                ))
                seasons = loaded
            }

            if let current = loaded.flatMap(\.episodes).first(where: { $0.isCurrent }) {
                currentItemID = current.id
            }
            seasons = loaded
            Self.storeLoad(seasons: loaded, currentItemID: currentItemID, for: cacheKey)
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private static func cacheKey(for seed: PlayerEpisodeBrowserSeed) -> String {
        let rawProvider = seed.currentPlaybackContext?.anilistMediaId
            .map { String($0) } ?? "nil"
        let canonicalProvider = seed.currentPlaybackContext?.positiveAniListMediaId
            .map { String($0) } ?? "nil"
        let kitsuProvider = seed.currentPlaybackContext?.kitsuMediaId
            .map { String($0) } ?? "nil"
        let role = seed.currentPlaybackContext?.isSpecial == true ? "special" : "regular"
        let contextKey = "\(rawProvider):\(canonicalProvider):\(kitsuProvider):\(role)"
        let modeKey: String
        if PerformanceModeSettings.isEnabled && PerformanceModeSettings.skipsAniListTraversalForAnimeDetails {
            modeKey = "performance+skipTraversal"
        } else if PerformanceModeSettings.isEnabled {
            modeKey = "performance"
        } else if PerformanceModeSettings.skipsAniListTraversalForAnimeDetails {
            modeKey = "skipTraversal"
        } else {
            modeKey = "standard"
        }
        return "\(seed.showId)|S\(seed.currentSeasonNumber)|E\(seed.currentEpisodeNumber)|anime=\(seed.isAnime)|mode=\(modeKey)|\(contextKey)"
    }

    private static func cachedLoad(for key: String) -> CachedEpisodeBrowserLoad? {
        let now = Date()
        loadCache = loadCache.filter { now.timeIntervalSince($0.value.storedAt) < loadCacheTTL }
        return loadCache[key]
    }

    private static func storeLoad(seasons: [PlayerEpisodeBrowserSeason], currentItemID: String?, for key: String) {
        loadCache[key] = CachedEpisodeBrowserLoad(seasons: seasons, currentItemID: currentItemID, storedAt: Date())
        if loadCache.count > 12 {
            let sortedKeys = loadCache.sorted { $0.value.storedAt < $1.value.storedAt }.map(\.key)
            for key in sortedKeys.prefix(loadCache.count - 12) {
                loadCache[key] = nil
            }
        }
    }

    private func currentSpecialContext(from contexts: [SpecialEpisodeListContext]) -> SpecialEpisodeListContext? {

        guard let current = canonicalCurrentPlaybackContext ?? seed.currentPlaybackContext else { return nil }
        for context in contexts {
            let candidates: [TMDBEpisode]
            if let tmdbSeason = current.resolvedTMDBSeasonNumber,
               let tmdbEpisode = current.resolvedTMDBEpisodeNumber {
                candidates = context.episodes.filter {
                    let candidate = context.playbackContext(for: $0)
                    return candidate.resolvedTMDBSeasonNumber == tmdbSeason
                        && candidate.resolvedTMDBEpisodeNumber == tmdbEpisode
                }
            } else {
                candidates = context.episodes.filter {
                    $0.episodeNumber == current.localEpisodeNumber
                }
            }
            if candidates.contains(where: {
                AnimeEpisodeIdentityPolicy.isSameEpisode(
                    current,
                    context.playbackContext(for: $0)
                )
            }) {
                return context
            }
        }
        return nil
    }

    private func currentRegularSeason(
        in animeData: AniListAnimeWithSeasons?
    ) -> AniListSeasonWithPoster? {
        guard let animeData else { return nil }
        if let context = canonicalCurrentPlaybackContext {
            if let providerID = context.positiveAniListMediaId,
               let season = animeData.seasons.first(where: {
                   ($0.canonicalAniListId ?? ($0.anilistId > 0 ? $0.anilistId : nil)) == providerID
               }) {
                return season
            }
            if let providerID = context.anilistMediaId,
               let season = animeData.seasons.first(where: { $0.anilistId == providerID }) {
                return season
            }
            if let kitsuID = context.kitsuMediaId,
               let season = animeData.seasons.first(where: { $0.kitsuId == kitsuID }) {
                return season
            }
            return nil
        }
        guard seed.currentPlaybackContext?.hasAnimeMediaId != true else { return nil }
        return animeData.seasons.first(where: { $0.seasonNumber == seed.currentSeasonNumber })
    }

    private func canonicalPlaybackContext(
        animeData: AniListAnimeWithSeasons?,
        specialContexts: [SpecialEpisodeListContext],
        absoluteEpisodeOffsets: [Int: Int]
    ) -> EpisodePlaybackContext? {
        guard seed.isAnime else { return nil }
        let persisted = seed.currentPlaybackContext
        let episodeNumber = max(1, persisted?.localEpisodeNumber ?? seed.currentEpisodeNumber)

        var aliases: [Int: Int] = [:]
        if let animeData {
            for season in animeData.seasons {
                if let canonicalID = season.canonicalAniListId
                        ?? (season.anilistId > 0 ? season.anilistId : nil),
                   canonicalID > 0 {
                    aliases[season.anilistId] = canonicalID
                    if let providerID = RemoteMediaNumericBoundary.negativeProviderIdentifier(
                        season.malId
                    ) {
                        aliases[providerID] = canonicalID
                    }
                }
            }
        }
        for special in specialContexts {
            if let canonicalID = special.canonicalAniListId, canonicalID > 0 {
                aliases[special.anilistId] = canonicalID
            }
        }

        if let animeData {
            for season in animeData.seasons {
                let candidates: [AniListEpisode]
                if let tmdbSeason = persisted?.resolvedTMDBSeasonNumber,
                   let tmdbEpisode = persisted?.resolvedTMDBEpisodeNumber {
                    candidates = season.episodes.filter {
                        $0.tmdbSeasonNumber == tmdbSeason
                            && $0.tmdbEpisodeNumber == tmdbEpisode
                    }
                } else {
                    candidates = season.episodes.filter {
                        $0.number == episodeNumber
                            && (persisted?.hasAnimeMediaId == true
                                || season.seasonNumber == seed.currentSeasonNumber)
                    }
                }
                for episode in candidates {
                    let candidate = EpisodePlaybackContext(
                        localSeasonNumber: season.seasonNumber,
                        localEpisodeNumber: episode.number,
                        anilistMediaId: season.anilistId,
                        canonicalAniListMediaId: season.canonicalAniListId
                            ?? (season.anilistId > 0 ? season.anilistId : nil),
                        malMediaId: season.malId,
                        kitsuMediaId: season.kitsuId,
                        tmdbSeasonNumber: episode.tmdbSeasonNumber,
                        tmdbEpisodeNumber: episode.tmdbEpisodeNumber,
                        tmdbEpisodeOffset: nil,
                        animeAbsoluteEpisodeNumber: RemoteMediaNumericBoundary.adding(
                            absoluteEpisodeOffsets[season.seasonNumber] ?? 0,
                            episode.number
                        ),
                        animeSeasonEpisodeCount: season.episodes.count,
                        isSpecial: false,
                        titleOnlySearch: false
                    )
                    if let persisted {
                        if AnimeEpisodeIdentityPolicy.isSameEpisode(
                            persisted,
                            candidate,
                            providerAliases: aliases
                        ) {
                            return candidate
                        }
                    } else if season.seasonNumber == seed.currentSeasonNumber,
                              episode.number == seed.currentEpisodeNumber {
                        return candidate
                    }
                }
            }
        }

        for special in specialContexts {
            let candidates: [TMDBEpisode]
            if let tmdbSeason = persisted?.resolvedTMDBSeasonNumber,
               let tmdbEpisode = persisted?.resolvedTMDBEpisodeNumber {
                candidates = special.episodes.filter {
                    let candidate = special.playbackContext(for: $0)
                    return candidate.resolvedTMDBSeasonNumber == tmdbSeason
                        && candidate.resolvedTMDBEpisodeNumber == tmdbEpisode
                }
            } else {
                candidates = special.episodes.filter {
                    $0.episodeNumber == episodeNumber
                        && (persisted?.hasAnimeMediaId == true
                            || special.localSeasonNumber == seed.currentSeasonNumber)
                }
            }
            for episode in candidates {
                let candidate = special.playbackContext(for: episode)
                if let persisted {
                    if AnimeEpisodeIdentityPolicy.isSameEpisode(
                        persisted,
                        candidate,
                        providerAliases: aliases
                    ) {
                        return candidate
                    }
                } else if special.localSeasonNumber == seed.currentSeasonNumber,
                          episode.episodeNumber == seed.currentEpisodeNumber {
                    return candidate
                }
            }
        }

        return persisted?.hasAnimeMediaId == true ? nil : persisted
    }

    private func isCanonicalCurrentItem(
        _ item: PlayerEpisodeBrowserItem,
        currentContext: EpisodePlaybackContext?
    ) -> Bool {
        isCanonicalCurrentEpisode(
            item.episode,
            isSpecial: item.isSpecial,
            playbackContext: item.playbackContext,
            currentContext: currentContext
        )
    }

    private func isCanonicalCurrentEpisode(
        _ episode: TMDBEpisode,
        isSpecial: Bool,
        playbackContext: EpisodePlaybackContext?,
        currentContext: EpisodePlaybackContext?
    ) -> Bool {
        if seed.isAnime,
           seed.currentPlaybackContext?.hasAnimeMediaId == true,
           canonicalCurrentPlaybackContext == nil {
            return false
        }
        guard let currentContext else {
            return episode.seasonNumber == seed.currentSeasonNumber
                && episode.episodeNumber == seed.currentEpisodeNumber
        }
        if let playbackContext {
            return isSpecial == currentContext.isSpecial
                && AnimeEpisodeIdentityPolicy.isSameEpisode(
                    currentContext,
                    playbackContext
                )
        }
        return episode.seasonNumber == currentContext.localSeasonNumber
            && episode.episodeNumber == currentContext.localEpisodeNumber
    }

    private func absoluteEpisodeOffsetsBySeason(for seasons: [AniListSeasonWithPoster]) -> [Int: Int] {
        var offsets: [Int: Int] = [:]
        var absoluteOffset = 0

        for season in seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }) {
            offsets[season.seasonNumber] = absoluteOffset
            absoluteOffset = RemoteMediaNumericBoundary.adding(
                absoluteOffset,
                season.episodes.count
            ) ?? RemoteMediaNumericBoundary.maximumTotalEpisodeCount
        }

        return offsets
    }

    private func buildAnimeSeason(_ season: AniListSeasonWithPoster, absoluteEpisodeOffset: Int, showTitle: String, showPosterURL: String?, imdbId: String?, originalAudioLanguage: String?) -> PlayerEpisodeBrowserSeason {
        let title = season.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Season \(season.seasonNumber)" : season.title
        let items = season.episodes
            .sorted { $0.number < $1.number }
            .map { aniEpisode -> PlayerEpisodeBrowserItem in
                let episode = TMDBEpisode(
                    id: RemoteMediaNumericBoundary.syntheticIdentifier([
                        (seed.showId, 1_000),
                        (season.seasonNumber, 100),
                        (aniEpisode.number, 1)
                    ]),
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
                    canonicalAniListMediaId: season.canonicalAniListId
                        ?? (season.anilistId > 0 ? season.anilistId : nil),
                    malMediaId: season.malId,
                    kitsuMediaId: season.kitsuId,
                    tmdbSeasonNumber: aniEpisode.tmdbSeasonNumber,
                    tmdbEpisodeNumber: aniEpisode.tmdbEpisodeNumber,
                    tmdbEpisodeOffset: nil,
                    animeAbsoluteEpisodeNumber: RemoteMediaNumericBoundary.adding(
                        absoluteEpisodeOffset,
                        aniEpisode.number
                    ),
                    animeSeasonEpisodeCount: season.episodes.count,
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
                    originalAudioLanguage: originalAudioLanguage,
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

    private func buildTMDBSeason(summary: TMDBSeason, detail: TMDBSeasonDetail, showTitle: String, showPosterURL: String?, imdbId: String?, isSpecial: Bool, originalAudioLanguage: String?) -> PlayerEpisodeBrowserSeason {
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
                    originalAudioLanguage: originalAudioLanguage,
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

    private func buildSpecialSeason(context: SpecialEpisodeListContext, showTitle: String, showPosterURL: String?, fallbackImdbId: String?, originalAudioLanguage: String?) -> PlayerEpisodeBrowserSeason {
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
                originalAudioLanguage: originalAudioLanguage,
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
        originalAudioLanguage: String?,
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
        #if !os(tvOS)
        let download: DownloadItem?
        #if os(iOS)
        download = DownloadManager.shared.completedEpisodeDownloadItem(
            tmdbId: seed.showId,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            playbackContext: playbackContext
        )
        #else
        download = DownloadManager.shared.completedDownloadItem(
            tmdbId: seed.showId,
            isMovie: false,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
        #endif
        #endif
        let isCurrent = isCanonicalCurrentEpisode(
            episode,
            isSpecial: isSpecial,
            playbackContext: playbackContext,
            currentContext: canonicalCurrentPlaybackContext ?? seed.currentPlaybackContext
        )
        let id = "\(episode.seasonNumber)-\(episode.episodeNumber)-\(episode.id)-\(isSpecial ? "special" : "main")"
        #if os(tvOS)
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
            originalAudioLanguage: originalAudioLanguage,
            imdbId: imdbId,
            episode: episode,
            isAnime: isAnime,
            isSpecial: isSpecial,
            playbackContext: playbackContext,
            originalTMDBSeasonNumber: originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: originalTMDBEpisodeNumber,
            progress: progress,
            isDownloaded: false,
            isCurrent: isCurrent,
            mediaYear: resolvedMediaYear
        )
        #else
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
            originalAudioLanguage: originalAudioLanguage,
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
            isCurrent: isCurrent,
            mediaYear: resolvedMediaYear
        )
        #endif
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
                .frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 38 : nil)
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

#if os(iOS)
private extension PlayerViewController {
    var isWatchTogetherAvailable: Bool {
        WatchTogetherSettings.isEnabled() && isMetalMPVRenderer
    }

    func configureWatchTogetherForCurrentMedia() {
        guard isWatchTogetherAvailable else {
            watchTogetherMediaIdentifier = nil
            watchTogetherButton.alpha = 0.0
            watchTogetherButton.isHidden = true
            WatchTogetherCoordinator.shared.detach(self)
            return
        }
        guard let context = watchTogetherMediaContext() else {
            watchTogetherMediaIdentifier = nil
            watchTogetherButton.isHidden = true
            WatchTogetherCoordinator.shared.detach(self)
            return
        }

        let identifier = WatchTogetherCoordinator.mediaIdentifier(forStableKey: context.stableKey)
        watchTogetherMediaIdentifier = identifier
        watchTogetherButton.isHidden = false
        watchTogetherButton.alpha = controlsVisible ? 1.0 : 0.0
        WatchTogetherCoordinator.shared.attach(self, mediaIdentifier: identifier, title: context.title)
    }

    func watchTogetherMediaContext() -> (stableKey: String, title: String)? {
        guard let descriptor = watchTogetherMediaDescriptor,
              let stableKey = descriptor.stableKey else { return nil }
        let baseTitle = descriptor.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = baseTitle?.isEmpty == false ? baseTitle! : playerDisplayTitle()
        guard descriptor.mediaType == "tv" else {
            return (stableKey, resolvedTitle)
        }
        let season = descriptor.localSeasonNumber ?? descriptor.seasonNumber ?? 1
        let episode = descriptor.localEpisodeNumber ?? descriptor.episodeNumber ?? 1
        return (stableKey, "\(resolvedTitle) S\(season)E\(episode)")
    }

    func watchTogetherClampedPosition(_ position: Double) -> Double {
        clampedPlaybackPosition(position)
    }

    @objc func watchTogetherTapped() {
        guard isWatchTogetherAvailable else {
            watchTogetherButton.alpha = 0.0
            watchTogetherButton.isHidden = true
            WatchTogetherCoordinator.shared.detach(self)
            return
        }
        switch watchTogetherConnectionState {
        case .ready:
            beginWatchTogetherActivity()
        case .activating:
            showPlayerNotice("SharePlay is starting...")
        case .active(let participantCount, let mediaMatches, let sharedTitle):
            if mediaMatches {
                presentWatchTogetherSessionMenu(participantCount: participantCount)
            } else {
                presentWatchTogetherMismatchMenu(sharedTitle: sharedTitle)
            }
        }
    }

    func beginWatchTogetherActivity() {
        guard isWatchTogetherAvailable else {
            showPlayerNotice("Watch Together requires MPV with the MoltenVK renderer and must be enabled in Settings.")
            return
        }
        guard watchTogetherMediaIdentifier != nil else {
            showPlayerNotice("Watch Together is unavailable because this video has no media identity.")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await WatchTogetherCoordinator.shared.beginActivity()
            switch result {
            case .started:
                self.showPlayerNotice("Starting secure Watch Together with SharePlay...")
            case .needsGroupSession:
                self.presentWatchTogetherSharingSheetIfAvailable()
            case .cancelled:
                break
            case .unavailable(let message):
                self.presentWatchTogetherAlert(title: "Watch Together Unavailable", message: message)
            }
        }
    }

    func presentWatchTogetherSharingSheetIfAvailable() {
        guard #available(iOS 15.4, *),
              let activity = WatchTogetherCoordinator.shared.activityForSharing() else {
            presentWatchTogetherAlert(
                title: "SharePlay Needs a Group",
                message: "Start or join a FaceTime or Messages group session, then tap Watch Together again."
            )
            return
        }
        guard presentedViewController == nil else {
            showPlayerNotice("Close the current menu, then tap Watch Together again.")
            return
        }

        let itemProvider = NSItemProvider()
        itemProvider.registerGroupActivity(activity)

        let controller = UIActivityViewController(
            activityItems: [itemProvider],
            applicationActivities: nil
        )
        controller.allowsProminentActivity = true
        controller.completionWithItemsHandler = { [weak self] _, completed, _, error in
            guard let self else { return }
            if let error {
                self.showPlayerNotice("Watch Together invitation failed: \(error.localizedDescription)")
            } else if completed {
                self.showPlayerNotice("Watch Together invitation shared.")
            }
        }
        controller.popoverPresentationController?.sourceView = watchTogetherButton
        controller.popoverPresentationController?.sourceRect = watchTogetherButton.bounds
        present(controller, animated: true)
    }

    func presentWatchTogetherSessionMenu(participantCount: Int) {
        guard presentedViewController == nil else { return }
        let sessionPeople = participantCount == 1 ? "1 person" : "\(participantCount) people"
        let alert = UIAlertController(
            title: "Watch Together",
            message: "SharePlay is active with \(sessionPeople) in the session.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Sync Everyone Now", style: .default) { [weak self] _ in
            guard let self else { return }
            WatchTogetherCoordinator.shared.sendCurrentState(reason: "player-menu", from: self)
            self.showPlayerNotice("Sent the current playback position to the group.")
        })
        alert.addAction(UIAlertAction(title: "Leave Session", style: .destructive) { _ in
            WatchTogetherCoordinator.shared.leaveSession()
        })
        alert.addAction(UIAlertAction(title: "End for Everyone", style: .destructive) { _ in
            WatchTogetherCoordinator.shared.endSessionForEveryone()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = watchTogetherButton
            popover.sourceRect = watchTogetherButton.bounds
        }
        present(alert, animated: true)
    }

    func presentWatchTogetherMismatchMenu(sharedTitle: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Different Watch Together Title",
            message: "The current SharePlay session is for \(sharedTitle). Leave it before starting this title.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Leave & Start This Title", style: .default) { [weak self] _ in
            WatchTogetherCoordinator.shared.leaveSession()
            self?.beginWatchTogetherActivity()
        })
        alert.addAction(UIAlertAction(title: "Leave Current Session", style: .destructive) { _ in
            WatchTogetherCoordinator.shared.leaveSession()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = watchTogetherButton
            popover.sourceRect = watchTogetherButton.bounds
        }
        present(alert, animated: true)
    }

    func presentWatchTogetherAlert(title: String, message: String) {
        guard presentedViewController == nil else {
            showPlayerNotice(message)
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func updateWatchTogetherButton(for state: WatchTogetherConnectionState) {
        watchTogetherConnectionState = state
        let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let symbolName: String
        switch state {
        case .ready:
            symbolName = "person.2.fill"
            watchTogetherButton.tintColor = .white
            watchTogetherButton.isEnabled = true
            watchTogetherButton.accessibilityValue = "Not active"
        case .activating:
            symbolName = "person.2.fill"
            watchTogetherButton.tintColor = .systemYellow
            watchTogetherButton.isEnabled = false
            watchTogetherButton.accessibilityValue = "Starting SharePlay"
        case .active(let participantCount, let mediaMatches, _):
            symbolName = mediaMatches ? "person.2.fill" : "exclamationmark.triangle.fill"
            watchTogetherButton.tintColor = mediaMatches ? .systemGreen : .systemOrange
            watchTogetherButton.isEnabled = true
            let sessionPeople = participantCount == 1 ? "1 person" : "\(participantCount) people"
            watchTogetherButton.accessibilityValue = mediaMatches
                ? "Session includes \(sessionPeople)"
                : "Active for a different title"
        }
        watchTogetherButton.setImage(UIImage(systemName: symbolName, withConfiguration: configuration), for: .normal)
    }
}

extension PlayerViewController: WatchTogetherPlaybackDelegate {
    var watchTogetherMediaDescriptor: WatchTogetherMediaDescriptor? {
        guard let mediaInfo else { return nil }
        switch mediaInfo {
        case .movie(let id, let title, _, let isAnime):
            return WatchTogetherMediaDescriptor(
                tmdbID: id,
                mediaType: "movie",
                seasonNumber: nil,
                episodeNumber: nil,
                isAnime: isAnime,
                title: title
            )
        case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, _, let mediaIsAnime):

            let playbackContext = episodePlaybackContext
            return WatchTogetherMediaDescriptor(
                tmdbID: showId,
                mediaType: "tv",
                seasonNumber: playbackContext?.resolvedTMDBSeasonNumber ?? originalTMDBSeasonNumber ?? seasonNumber,
                episodeNumber: playbackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBEpisodeNumber ?? episodeNumber,
                playbackContext: playbackContext,
                isAnime: mediaIsAnime || isAnimeHint == true || playbackContext?.hasAnimeMediaId == true,
                title: showTitle
            )
        }
    }

    var watchTogetherPosition: Double {
        if !watchTogetherRendererReady {
            let preparedPosition = pendingInitialResumeTarget ?? pendingSeekTime
            if let preparedPosition,
               preparedPosition.isFinite,
               preparedPosition >= 0 {
                return watchTogetherClampedPosition(preparedPosition)
            }
        }
        return watchTogetherClampedPosition(cachedPosition)
    }

    var watchTogetherDuration: Double {
        cachedDuration.isFinite && cachedDuration > 0 ? cachedDuration : 0
    }

    var watchTogetherIsReady: Bool {
        watchTogetherRendererReady && !isClosing
    }

    var watchTogetherIsStalled: Bool {
        if isRendererLoading { return true }
        return false
    }

    var watchTogetherIsPlaying: Bool {
        !rendererIsPausedState()
    }

    var watchTogetherPlaybackRate: Double {
        if watchTogetherRateNudgeActive,
           let baseRate = lastWatchTogetherSharedState?.playbackRate,
           baseRate.isFinite,
           (0.25...3.0).contains(baseRate) {
            return baseRate
        }
        let playbackRate = rendererGetSpeed()
        return playbackRate.isFinite && (0.25...3.0).contains(playbackRate) ? playbackRate : 1.0
    }

    func watchTogetherAdopt(media: WatchTogetherMediaDescriptor) {
        guard let mediaInfo else { return }
        if media.mediaType == "tv",
           let localDescriptor = watchTogetherMediaDescriptor,
           localDescriptor.isSameLogicalMedia(as: media),
           localDescriptor.playbackContext?.hasAnimeMediaId == true {

            return
        }
        switch mediaInfo {
        case .movie(let id, _, _, _):
            guard media.mediaType == "movie", media.tmdbID == id else { return }
        case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, let showPosterURL, let mediaIsAnime):
            guard media.mediaType == "tv", media.tmdbID == showId else { return }
            episodePlaybackContext = media.playbackContext
            originalTMDBSeasonNumber = media.playbackContext?.resolvedTMDBSeasonNumber ?? media.seasonNumber
            originalTMDBEpisodeNumber = media.playbackContext?.resolvedTMDBEpisodeNumber ?? media.episodeNumber
            if let context = media.playbackContext {
                self.mediaInfo = .episode(
                    showId: showId,
                    seasonNumber: context.localSeasonNumber,
                    episodeNumber: context.localEpisodeNumber,
                    showTitle: showTitle ?? media.title,
                    showPosterURL: showPosterURL,
                    isAnime: mediaIsAnime || media.isAnime || context.hasAnimeMediaId
                )
            } else if seasonNumber != media.seasonNumber || episodeNumber != media.episodeNumber {

                return
            }
        }
    }

    func watchTogetherApply(state: WatchTogetherSharedState, shouldSeek: Bool) {
        guard !isClosing, isWatchTogetherAvailable else { return }
        watchTogetherAdopt(media: state.media)
        lastWatchTogetherSharedState = state
        let synchronizedPosition = watchTogetherTargetPosition(for: state)
        let requiresAuthoritativeSeek = shouldSeek
            || !watchTogetherRendererReady
            || isRendererLoading
            || pendingSeekTime != nil
            || pendingInitialResumeTarget != nil
            || abs(watchTogetherPosition - synchronizedPosition) >= WatchTogetherCoordinator.driftSeekThreshold

        if !watchTogetherRendererReady || isRendererLoading {
            let retainedSeek = pendingWatchTogetherPlaybackState?.shouldSeek == true
                || requiresAuthoritativeSeek
            pendingWatchTogetherPlaybackState = (state, retainedSeek)
            persistWatchTogetherProgress(at: synchronizedPosition)
            return
        }

        applyWatchTogetherStateNow(state, shouldSeek: requiresAuthoritativeSeek)
    }

    private func applyWatchTogetherStateNow(
        _ state: WatchTogetherSharedState,
        shouldSeek: Bool
    ) {
        guard !isClosing, isWatchTogetherAvailable else { return }
        let synchronizedPosition = watchTogetherTargetPosition(for: state)
        pendingSeekTime = nil
        pendingInitialResumeTarget = nil
        pendingInitialResumeDeadline = nil
        pendingInitialResumeRetryCount = 0
        pendingInitialResumeLastRetryAt = nil

        if shouldSeek {
            cachedPosition = synchronizedPosition
            progressModel.position = synchronizedPosition
            rendererSeek(to: synchronizedPosition)
        }
        applyWatchTogetherPlaybackRate(for: state, didSeek: shouldSeek)
        persistWatchTogetherProgress(at: synchronizedPosition)

        if state.isPlaying {
            if rendererIsPausedState() {
                markBackgroundRecoveryForegrounded(source: "watch-together")
                rendererPlay()
                updatePlayPauseButton(isPaused: false, shouldShowControls: false)
            }
        } else {
            if rendererIsPausedState() {

                rendererPlaybackIntentGeneration &+= 1
                mpvBackgroundFallbackAutoPaused = false
                mpvBackgroundFallbackPauseIntentGeneration = nil
                mpvBackgroundFallbackPauseLifecycleGeneration = nil
            } else {
                rendererPausePlayback()
                updatePlayPauseButton(isPaused: true, shouldShowControls: false)
            }
        }
    }

    private func watchTogetherTargetPosition(for state: WatchTogetherSharedState) -> Double {
        let localDuration = cachedDuration.isFinite && cachedDuration > 0 ? cachedDuration : nil
        return watchTogetherClampedPosition(
            WatchTogetherCoordinator.shared.synchronizedPosition(of: state, localDuration: localDuration)
        )
    }

    private func restoreWatchTogetherNudgedRateIfNeeded() {
        guard watchTogetherRateNudgeActive else { return }
        watchTogetherRateNudgeActive = false
        let restoredRate = lastWatchTogetherSharedState?.playbackRate ?? 1.0
        rendererSetSpeed(restoredRate, notifyWatchTogether: false)
        updateSpeedMenu()
    }

    private func applyWatchTogetherPlaybackRate(
        for state: WatchTogetherSharedState,
        didSeek: Bool
    ) {
        let baseRate = state.playbackRate
        var desiredRate = baseRate
        if !didSeek,
           state.isPlaying,
           !rendererIsPausedState() {
            let drift = watchTogetherPosition - watchTogetherTargetPosition(for: state)
            if abs(drift) >= WatchTogetherCoordinator.driftNudgeThreshold {
                desiredRate = drift > 0 ? baseRate * 0.95 : baseRate * 1.05
            }
        }
        desiredRate = min(max(desiredRate, 0.25), 3.0)
        watchTogetherRateNudgeActive = abs(desiredRate - baseRate) > 0.001
        if abs(rendererGetSpeed() - desiredRate) >= 0.01 {
            rendererSetSpeed(desiredRate, notifyWatchTogether: false)
            if !watchTogetherRateNudgeActive {
                updateSpeedMenu()
            }
        }
    }

    private func drainPendingWatchTogetherStateIfReady() {
        guard watchTogetherRendererReady,
              !isRendererLoading else { return }
        if let pending = pendingWatchTogetherPlaybackState {
            pendingWatchTogetherPlaybackState = nil
            let freshState = WatchTogetherCoordinator.shared.currentAcceptedState(for: self)
            applyWatchTogetherStateNow(freshState ?? pending.state, shouldSeek: pending.shouldSeek)
        }
        notifyWatchTogetherPlaybackReadyIfNeeded()
    }

    private func notifyWatchTogetherPlaybackReadyIfNeeded() {
        guard watchTogetherIsReady,
              WatchTogetherCoordinator.shared.playbackDidBecomeReady(self) else { return }
        markBackgroundRecoveryForegrounded(source: "watch-together-transition-ready")
        rendererPlay()
        updatePlayPauseButton(isPaused: false, shouldShowControls: false)
    }

    private func persistWatchTogetherProgress(at position: Double) {
        guard playbackProfileIsStillActive("a Watch Together position write") else { return }
        guard cachedDuration.isFinite, cachedDuration > 0 else { return }
        let resolvedDuration = cachedDuration
        guard position.isFinite,
              let mediaInfo else {
            return
        }

        let safePosition = min(max(0, position), resolvedDuration)
        switch mediaInfo {
        case .movie(let id, let title, let posterURL, _):
            ProgressManager.shared.updateMovieProgress(
                movieId: id,
                title: title,
                currentTime: safePosition,
                totalDuration: resolvedDuration,
                posterURL: posterURL,
                owner: playbackOwnerProfileID
            )
        case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, let showPosterURL, let isAnime):
            ProgressManager.shared.updateEpisodeProgress(
                showId: showId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                currentTime: safePosition,
                totalDuration: resolvedDuration,
                showTitle: showTitle,
                showPosterURL: showPosterURL,
                playbackContext: episodePlaybackContext,
                isAnime: isAnime || episodePlaybackContext?.hasAnimeMediaId == true,
                owner: playbackOwnerProfileID
            )
        }
    }

    func watchTogetherPrepareForMediaTransition(to media: WatchTogetherMediaDescriptor) {
        guard !isClosing else { return }
        persistWatchTogetherProgress(at: watchTogetherClampedPosition(cachedPosition))
        pendingWatchTogetherPlaybackState = nil
        let season = media.localSeasonNumber.map(String.init) ?? "?"
        let episode = media.localEpisodeNumber.map(String.init) ?? "?"
        showPlayerNotice("Watch Together is moving everyone to S\(season)E\(episode)...")
        closePlayer(allowWhilePlaybackLocked: true)
    }

    func watchTogetherConnectionDidChange(_ state: WatchTogetherConnectionState) {
        guard isWatchTogetherAvailable else {
            watchTogetherButton.alpha = 0.0
            watchTogetherButton.isHidden = true
            WatchTogetherCoordinator.shared.detach(self)
            pendingWatchTogetherPlaybackState = nil
            restoreWatchTogetherNudgedRateIfNeeded()
            return
        }
        let wasActive: Bool
        if case .active = watchTogetherConnectionState {
            wasActive = true
        } else {
            wasActive = false
        }
        updateWatchTogetherButton(for: state)
        if case .ready = state {
            pendingWatchTogetherPlaybackState = nil
            restoreWatchTogetherNudgedRateIfNeeded()
        }
        if !wasActive, case .active(let count, let matches, _) = state, matches {
            let sessionPeople = count == 1 ? "1 person" : "\(count) people"
            showPlayerNotice("Watch Together connected — \(sessionPeople) in the session.")
        }
    }

    func watchTogetherShowNotice(_ message: String) {
        showPlayerNotice(message)
    }
}
#endif


#if os(iOS)
extension PlayerViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        guard isPlayerPresentation(presentationController) else { return true }
        return !PlayerPlaybackLockSettings.isLocked()
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        guard isPlayerPresentation(presentationController),
              PlayerPlaybackLockSettings.isLocked() else { return }
        showControlsTemporarily()
        showPlayerNotice("Unlock the player before closing.")
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if isPlayerPresentation(presentationController) {
            return
        }
        guard episodeSourceSheetController === presentationController.presentedViewController else { return }
        let transitionID = episodeSourceSheetTransitionID
        episodeSourceSheetController = nil
        episodeSourceSheetTransitionID = nil
        schedulePendingWatchTogetherNextEpisodeCleanup(transitionID: transitionID)
    }

    private func isPlayerPresentation(_ presentationController: UIPresentationController) -> Bool {
        let presented = presentationController.presentedViewController
        return presented === self || presented.children.contains(where: { $0 === self })
    }
}
#endif

extension PlayerViewController: MPVNativeRendererDelegate {
    func renderer(_ renderer: PlayerRenderer, didUpdatePosition position: Double, duration: Double) {
        if isClosing { return }
        updatePosition(position, duration: duration)
    }

    func renderer(_ renderer: PlayerRenderer, didChangePause isPaused: Bool) {
        if isClosing { return }
        if playbackTraceLastPauseValue != isPaused {
            playbackTraceLastPauseValue = isPaused
            logPlaybackStage(
                isPaused ? "renderer-paused" : "renderer-playing-signal",
                "loading=\(isRendererLoading) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))"
            )
        }
        if !isPaused {
            rendererResumeForegroundRendering(reason: "mpv-unpause")
            sendRendererPauseTraktScrobble(.start, reason: "mpv-unpause")
        } else {
            sendRendererPauseTraktScrobble(.pause, reason: "mpv-pause")
        }
        refreshIdleTimerForPlayback(reason: "mpv-pause-changed")
        if isRendererLoading {
            pipController?.updatePlaybackState()
            return
        }
        let shouldShowControls = !suppressNextPlayPauseControlReveal
        updatePlayPauseButton(isPaused: isPaused, shouldShowControls: shouldShowControls)
        pipController?.updatePlaybackState()
    }

    func renderer(_ renderer: PlayerRenderer, didChangeLoading isLoading: Bool) {
        if isClosing { return }
        if playbackTraceLastLoadingValue != isLoading {
            playbackTraceLastLoadingValue = isLoading
            logPlaybackStage(
                isLoading ? "renderer-loading" : "renderer-loading-ended",
                "paused=\(rendererIsPausedState()) cached=\(secondsText(cachedPosition))/\(secondsText(cachedDuration))"
            )
        }
        isRendererLoading = isLoading

        pipController?.updatePlaybackState()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isLoading {
                self.centerPlayPauseButton.isHidden = true
                self.setPlayerLoadingIndicatorVisible(true)
            } else {
                self.setPlayerLoadingIndicatorVisible(false)
                self.centerPlayPauseButton.isHidden = false

                self.updatePlayPauseButton(
                    isPaused: self.rendererIsPausedState(),
                    shouldShowControls: !self.suppressNextPlayPauseControlReveal
                )
#if os(iOS)
                self.drainPendingWatchTogetherStateIfReady()
#endif
            }
        }
    }

    func renderer(_ renderer: PlayerRenderer, didBecomeReadyToSeek: Bool) {
        if isClosing { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logPlaybackStage(
                "renderer-ready",
                "pendingSeek=\(self.secondsText(self.pendingSeekTime)) loading=\(self.isRendererLoading) renderer={\(self.rendererPictureInPictureDebugSnapshot())}"
            )
            self.updateAudioTracksMenuWhenReady()
            self.updateSubtitleTracksMenuWhenReady()
            self.prefetchOpenSubtitlesIfEnabled(reason: "ready")
            self.prefetchStremioSubtitlesIfAvailable(reason: "ready")
            self.updatePiPButtonVisibility()

            if let seekTime = self.pendingSeekTime {
                self.pendingInitialResumeTarget = seekTime
                self.pendingInitialResumeDeadline = Date().addingTimeInterval(20)

                self.logPlaybackStage("initial-seek-owned-by-renderer", "target=\(self.secondsText(seekTime))")
                Logger.shared.log("MPV renderer applied prepared resume seek to \(Int(seekTime))s", type: "Progress")
                self.pendingSeekTime = nil
            }
            self.applyDefaultPlaybackSpeed()
#if os(iOS)
            self.watchTogetherRendererReady = true
            self.drainPendingWatchTogetherStateIfReady()
#endif
            self.applyAudioComfortFilterIfNeeded(reason: "ready")

            self.fetchSkipData()
        }
    }

    func renderer(_ renderer: PlayerRenderer, didFailWithError message: String) {
        if isClosing { return }
        logPlaybackStage("renderer-failed", "message=\(message)")
        setIdleTimerDisabledForPlayback(false, reason: "mpv-failure")
        logMPV("delegate didFailWithError message=\(message)")
        Logger.shared.log("PlayerViewController: MPV playback issue: \(message)", type: "MPV")
        if attemptMPVTransportBridgeFallbackIfNeeded(after: message) {
            return
        }
        if !playbackDidStart {
            handlePlaybackStartupFailure(message, isSourceFailure: true)
        } else if message.hasPrefix("Hardware decoder unavailable") {
            showTransientErrorBanner(message, duration: 8)
        }
    }

    func rendererDidChangeTracks(_ renderer: PlayerRenderer) {
        if isClosing { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidateRendererTrackCaches()
            self.updateAudioTracksMenu()
            self.updateSubtitleTracksMenu()
            self.refreshVisibleOverlayMenuIfNeeded(kind: "audio")
            self.refreshVisibleOverlayMenuIfNeeded(kind: "subtitles")
        }
    }

    func renderer(_ renderer: PlayerRenderer, subtitleTrackDidChange trackId: Int) {
        if isClosing { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shouldShowSubtitles = trackId >= 0
            if self.subtitleModel.isVisible != shouldShowSubtitles {
                self.setSessionAwareSubtitleVisible(shouldShowSubtitles)
            }
            if trackId >= 0 {
                self.vlcSubtitleSelection = .embedded(trackId: trackId)
            } else {
                self.vlcSubtitleSelection = .none
            }
            self.updateSubtitleButtonAppearance()
        }
    }

}

extension PlayerViewController: PiPControllerDelegate {
    func pipController(_ controller: PiPController, willStartPictureInPicture: Bool) {
        guard shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "will-start"
        ) else { return }
        guard !isVLCPlayer else {
            Logger.shared.log("[PlayerVC.PiP] ignoring sample-buffer willStart while VLC renderer is active", type: "Player")
            return
        }
        logPictureInPicture("delegate willStart possible=\(controller.isPictureInPicturePossible) active=\(controller.isPictureInPictureActive)")
        let primed = rendererIsPictureInPicturePrimed()
        let resumedFallbackPause = primed
            && resumeMPVBackgroundFallbackPauseForPictureInPictureIfNeeded(
                source: "delegate-willStart"
            )
        logPictureInPicture("delegate willStart state primed=\(primed) resumedFallbackPause=\(resumedFallbackPause) subs={\(subtitlePictureInPictureDebugSnapshot())}")
        guard validateMPVAutomaticPictureInPicturePlaybackIntent(
            for: controller,
            attemptID: controller.transitionAttemptID,
            source: "delegate-willStart"
        ) else { return }
        if primed, renderer.prefersPictureInPictureLayerActivationBeforeStart {

            guard rendererActivatePictureInPictureLayer() else {
                logPictureInPicture("delegate willStart renderer activation rejected")
                retireMPVPictureInPictureAfterRendererActivationFailure(
                    controller: controller,
                    source: "delegate-willStart",
                    attemptID: controller.transitionAttemptID
                )
                return
            }
        }
        if resumedFallbackPause || primed {
            controller.updatePlaybackState()
        }
    }
    func pipController(
        _ controller: PiPController,
        didStartPictureInPicture: Bool,
        attemptID: Int
    ) {
        guard shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "did-start",
            attemptID: attemptID
        ) else { return }
        guard !isVLCPlayer else {
            Logger.shared.log("[PlayerVC.PiP] ignoring sample-buffer didStart while VLC renderer is active", type: "Player")
            updatePiPButtonVisibility()
            return
        }
        let primed = rendererIsPictureInPicturePrimed()
        let resumedFallbackPause = didStartPictureInPicture
            && primed
            && resumeMPVBackgroundFallbackPauseForPictureInPictureIfNeeded(
                source: "delegate-didStart"
            )
        logPictureInPicture("delegate didStart success=\(didStartPictureInPicture) possible=\(controller.isPictureInPicturePossible) active=\(controller.isPictureInPictureActive) primed=\(primed) resumedFallbackPause=\(resumedFallbackPause) renderer={\(rendererPictureInPictureDebugSnapshot())}")
        if didStartPictureInPicture,
           !validateMPVAutomaticPictureInPicturePlaybackIntent(
                for: controller,
                attemptID: attemptID,
                source: "delegate-didStart"
           ) {
            updatePiPButtonVisibility()
            return
        }
        if didStartPictureInPicture {
            mpvAppExitPiPStartRequested = false
            cancelPendingMPVAppExitPictureInPictureStart(reason: "delegate-didStart")
            mpvActivePiPCallbackAttemptID = attemptID
            if primed {
                guard rendererActivatePictureInPictureLayer() else {
                    logPictureInPicture("delegate didStart renderer activation rejected")
                    retireMPVPictureInPictureAfterRendererActivationFailure(
                        controller: controller,
                        source: "delegate-didStart",
                        attemptID: attemptID
                    )
                    updatePiPButtonVisibility()
                    return
                }
                clearMPVAutomaticPictureInPictureAuthorization(
                    reason: "delegate-didStart-ready"
                )
                cancelMPVBackgroundAudioFallback(reason: "delegate-didStart-ready")
            } else {
                logPictureInPicture("delegate didStart found unready renderer; ending PiP cleanly")
                clearMPVAutomaticPictureInPictureAuthorization(
                    reason: "delegate-didStart-renderer-not-ready"
                )
                releaseMPVAppExitPictureInPictureOwnership(reason: "renderer-not-ready")
                controller.stopPictureInPicture(source: "renderer-not-ready")
                rendererFinishPictureInPicture()
                if mpvBackgroundLifecycleIsArmed {
                    scheduleMPVBackgroundAudioFallback(
                        source: "delegate-didStart-renderer-not-ready",
                        delay: 0.25
                    )
                }
            }
        } else {

            if controller.isPictureInPictureActive
                || controller.isPictureInPictureStartPending {
                logPictureInPicture(
                    "delegate didStart failure superseded by live transition active=\(controller.isPictureInPictureActive) pending=\(controller.isPictureInPictureStartPending) attemptID=\(attemptID)"
                )
                controller.updatePlaybackState()
                updatePiPButtonVisibility()
                return
            }
            mpvPiPStartAttemptID += 1
            mpvAppExitPiPStartRequested = false
            clearMPVAutomaticPictureInPictureAuthorization(
                reason: "delegate-didStart-failed"
            )
            releaseMPVAppExitPictureInPictureOwnership(reason: "delegate-didStart-failed")
            rendererFinishPictureInPicture()
            mpvExpectedPiPCallbackAttemptID = nil
            mpvActivePiPCallbackAttemptID = nil
            if mpvBackgroundLifecycleIsArmed {
                requestMPVSerializedForegroundRecovery(source: "delegate-didStart-failed")
            } else {
                scheduleMPVPictureInPictureForegroundWarmup(
                    source: "delegate-didStart-failed-rewarm",
                    delays: [0.35, 1.20],
                    forceFirst: true
                )
            }
        }
        pipController?.updatePlaybackState()
        updatePiPButtonVisibility()
        if mpvBackgroundLifecycleIsArmed, owningPlaybackSceneIsForegroundActive() {
            requestMPVSerializedForegroundRecovery(source: "delegate-didStart-settled")
        }
    }
    func pipController(_ controller: PiPController, willStopPictureInPicture: Bool) {
        guard shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "will-stop"
        ) else { return }
        guard !isVLCPlayer else {
            Logger.shared.log("[PlayerVC.PiP] ignoring sample-buffer willStop while VLC renderer is active", type: "Player")
            return
        }
        logPictureInPicture("delegate willStop renderer={\(rendererPictureInPictureDebugSnapshot())}")
        authorizeMPVPictureInPictureStop(for: controller, source: "delegate-willStop")
        disarmMPVPictureInPictureRestartAfterStop(reason: "delegate-willStop")
    }
    func pipController(_ controller: PiPController, didStopPictureInPicture: Bool) {
        let restoreKey = mpvPictureInPictureRestoreKey(for: controller)
        let isKnownRestore = mpvPictureInPictureRestoreOperation?.key == restoreKey
            || mpvCompletedPictureInPictureRestore?.key == restoreKey
        guard isKnownRestore || shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "did-stop"
        ) else { return }
        guard !isVLCPlayer else {
            Logger.shared.log("[PlayerVC.PiP] ignoring sample-buffer didStop while VLC renderer is active", type: "Player")
            updatePiPButtonVisibility()
            return
        }
        logPictureInPicture("delegate didStop renderer={\(rendererPictureInPictureDebugSnapshot())}")
        let existingOperation = mpvPictureInPictureRestoreOperation?.key == restoreKey
            ? mpvPictureInPictureRestoreOperation
            : nil
        if existingOperation == nil,
           currentMPVPictureInPictureStopAuthorization(for: controller) == nil,
           owningPlaybackSceneIsForegroundActive() {

            authorizeMPVPictureInPictureStop(
                for: controller,
                source: "did-stop-foreground-fallback"
            )
        }
        guard existingOperation != nil
                || currentMPVPictureInPictureStopAuthorization(for: controller) != nil else {
            logPictureInPicture(
                "delegate didStop ignored: stop authorization expired before this lifecycle"
            )
            updatePiPButtonVisibility()
            return
        }
        disarmMPVPictureInPictureRestartAfterStop(reason: "delegate-didStop")
        let operation: (
            id: Int,
            key: MPVPictureInPictureRestoreKey,
            task: Task<Bool, Never>
        )
        if let existingOperation {
            operation = existingOperation
        } else {
            guard let authorization = currentMPVPictureInPictureStopAuthorization(
                for: controller
            ), owningPlaybackSceneIsForegroundActive() else {

                logPictureInPicture(
                    "delegate didStop deferred inline restore: owning scene is not foreground or stop authorization is stale"
                )
                updatePiPButtonVisibility()
                return
            }
            operation = beginMPVPictureInPictureRestore(
                for: controller,
                lifecycleGeneration: mpvBackgroundLifecycleIsArmed
                    ? authorization.lifecycleGeneration
                    : nil
            )
        }
        Task { @MainActor [weak self, weak controller] in
            let rendererRestored = await operation.task.value
            guard let self, let controller else { return }
            _ = self.completeMPVPictureInPictureRestore(
                operation,
                controller: controller,
                rendererRestored: rendererRestored,
                source: "delegate-didStop"
            )
            self.requestMPVSerializedForegroundRecovery(source: "delegate-didStop-restored")
        }
    }
    func pipController(_ controller: PiPController, restoreUserInterfaceForPictureInPictureStop completionHandler: @escaping (Bool) -> Void) {
        let restoreKey = mpvPictureInPictureRestoreKey(for: controller)
        let existingOperation = mpvPictureInPictureRestoreOperation?.key == restoreKey
            ? mpvPictureInPictureRestoreOperation
            : nil
        let isKnownRestore = existingOperation != nil
            || mpvCompletedPictureInPictureRestore?.key == restoreKey
        guard isKnownRestore || shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "restore-ui"
        ) else {
            completionHandler(false)
            return
        }
        guard !isVLCPlayer else {
            Logger.shared.log("[PlayerVC.PiP] ignoring sample-buffer restoreUI while VLC renderer is active", type: "Player")
            completionHandler(false)
            return
        }
        logPictureInPicture("delegate restoreUI begin renderer={\(rendererPictureInPictureDebugSnapshot())}")
        if existingOperation == nil,
           currentMPVPictureInPictureStopAuthorization(for: controller) == nil,
           owningPlaybackSceneIsForegroundActive() {

            authorizeMPVPictureInPictureStop(
                for: controller,
                source: "restore-ui-foreground-fallback"
            )
        }
        let stopAuthorization = currentMPVPictureInPictureStopAuthorization(for: controller)
        guard existingOperation != nil || stopAuthorization != nil else {
            logPictureInPicture(
                "delegate restoreUI rejected: no current stop authorization for owning lifecycle"
            )
            completionHandler(false)
            return
        }
        let completeRestore: () -> Void = { [weak self, weak controller] in
            Task { @MainActor in
                guard let self, let controller else {
                    completionHandler(false)
                    return
                }
                let operation: (
                    id: Int,
                    key: MPVPictureInPictureRestoreKey,
                    task: Task<Bool, Never>
                )
                if let existingOperation {
                    guard self.mpvPictureInPictureRestoreOperation?.id == existingOperation.id else {
                        completionHandler(false)
                        return
                    }
                    operation = existingOperation
                } else {
                    guard let stopAuthorization,
                          await self.waitForForegroundMPVPictureInPictureRestoreAuthorization(
                            stopAuthorization,
                            controller: controller
                          ),
                          self.currentMPVPictureInPictureStopAuthorization(
                            stopAuthorization,
                            for: controller
                          ) != nil else {
                        self.logPictureInPicture(
                            "delegate restoreUI rejected after waiting: lifecycle authorization expired"
                        )
                        completionHandler(false)
                        return
                    }
                    operation = self.beginMPVPictureInPictureRestore(
                        for: controller,
                        lifecycleGeneration: self.mpvBackgroundLifecycleIsArmed
                            ? stopAuthorization.lifecycleGeneration
                            : nil
                    )
                }
                let rendererRestored = await operation.task.value
                let restored = self.completeMPVPictureInPictureRestore(
                    operation,
                    controller: controller,
                    rendererRestored: rendererRestored,
                    source: "restore-ui"
                )
                self.requestMPVSerializedForegroundRecovery(source: "restore-ui-restored")
                completionHandler(restored)
            }
        }
        if presentedViewController != nil {
            dismiss(animated: true) { completeRestore() }
        } else {
            completeRestore()
        }
    }
    func pipControllerPlay(_ controller: PiPController) {
        guard shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "play"
        ) else { return }
        rendererPlay()
#if os(iOS)
        WatchTogetherCoordinator.shared.sendUserPlay(from: self)
#endif
    }
    func pipControllerPause(_ controller: PiPController) {
        guard shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "pause"
        ) else { return }
        rendererPausePlayback()
#if os(iOS)
        WatchTogetherCoordinator.shared.sendUserPause(from: self)
#endif
    }
    func pipController(_ controller: PiPController, setPlaying playing: Bool, completion: @escaping () -> Void) {
        guard shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "set-playing"
        ) else {
            completion()
            return
        }
        if playing {
            pipControllerPlay(controller)
        } else {
            pipControllerPause(controller)
        }
        let callbackLoadGeneration = controller.playbackLoadGeneration
        let callbackAttemptID = controller.transitionAttemptID
        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller else {
                completion()
                return
            }
            await self.renderer.waitForPictureInPictureTimelineUpdate()
            guard callbackLoadGeneration == self.playbackLoadGeneration,
                  controller.playbackLoadGeneration == callbackLoadGeneration,
                  controller.transitionAttemptID == callbackAttemptID else {
                completion()
                return
            }
            guard self.shouldHandleMPVPictureInPictureCallback(
                from: controller,
                source: "set-playing-completion"
            ) else {
                completion()
                return
            }
            self.rendererUpdatePictureInPicturePlaybackState()
            completion()
        }
    }
    func pipController(_ controller: PiPController, didTransitionToRenderSize size: CGSize) {
        guard shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "render-size"
        ) else { return }
        renderer.updatePictureInPictureRenderSize(size)
    }
    func pipController(_ controller: PiPController, skipByInterval interval: CMTime, completion: @escaping () -> Void) {
        guard shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "skip"
        ) else {
            completion()
            return
        }
        guard !isVLCPlayer else {
            completion()
            return
        }
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
#if os(iOS)
        WatchTogetherCoordinator.shared.sendUserSeek(to: target, from: self)
#endif
        let callbackLoadGeneration = controller.playbackLoadGeneration
        let callbackAttemptID = controller.transitionAttemptID
        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller else {
                completion()
                return
            }
            await self.renderer.waitForPictureInPictureTimelineUpdate()
            guard callbackLoadGeneration == self.playbackLoadGeneration,
                  controller.playbackLoadGeneration == callbackLoadGeneration,
                  controller.transitionAttemptID == callbackAttemptID else {
                completion()
                return
            }
            guard self.shouldHandleMPVPictureInPictureCallback(
                from: controller,
                source: "skip-completion"
            ) else {
                completion()
                return
            }
            self.rendererUpdatePictureInPicturePlaybackState()
            completion()
        }
    }
    func pipControllerIsPlaying(_ controller: PiPController) -> Bool {
        guard shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "is-playing"
        ) else { return false }
        return !rendererIsPausedState() && !isRendererLoading
    }
    func pipControllerDuration(_ controller: PiPController) -> Double {
        guard shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "duration"
        ) else { return 0 }
        return cachedDuration
    }
    func pipControllerCurrentTime(_ controller: PiPController) -> Double {
        guard shouldHandleMPVPictureInPictureCallback(
            from: controller,
            source: "current-time"
        ) else { return 0 }
        return cachedPosition
    }

    @objc private func appDidReceiveMemoryWarning() {
        guard isVLCPlayer else { return }
        let now = CACurrentMediaTime()
        guard now - lastVLCUIMemoryWarningLogTime >= 2 else { return }
        lastVLCUIMemoryWarningLogTime = now
        logVLCUIViewSnapshot("memoryWarning")
    }

    @discardableResult
    private func resumeMPVBackgroundFallbackPauseForPictureInPictureIfNeeded(
        source: String
    ) -> Bool {
        guard mpvBackgroundFallbackAutoPaused else { return false }
        let pauseLifecycleGeneration = mpvBackgroundFallbackPauseLifecycleGeneration
        let pauseIntentGeneration = mpvBackgroundFallbackPauseIntentGeneration
        let lifecycleMatches = pauseLifecycleGeneration == mpvBackgroundLifecycleGeneration
        let intentMatches = pauseIntentGeneration == rendererPlaybackIntentGeneration
        let rendererWasPaused = rendererIsPausedState()

        mpvBackgroundFallbackAutoPaused = false
        mpvBackgroundFallbackPauseIntentGeneration = nil
        mpvBackgroundFallbackPauseLifecycleGeneration = nil

        guard lifecycleMatches, intentMatches else {
            let pauseLifecycleText = pauseLifecycleGeneration.map { String($0) } ?? "nil"
            let pauseIntentText = pauseIntentGeneration.map { String($0) } ?? "nil"
            logPictureInPicture(
                "background fallback resume rejected source=\(source) pauseLifecycle=\(pauseLifecycleText) currentLifecycle=\(mpvBackgroundLifecycleGeneration) pauseIntent=\(pauseIntentText) currentIntent=\(rendererPlaybackIntentGeneration) paused=\(rendererWasPaused)"
            )
            return false
        }

        rendererPlay(recordingPlaybackIntent: false)
        logPictureInPicture(
            "background fallback pause resumed for PiP source=\(source) lifecycle=\(mpvBackgroundLifecycleGeneration) intent=\(rendererPlaybackIntentGeneration)"
        )
        return true
    }

    private func noteMPVBackgroundLifecycleIfNeeded(source: String) {
        guard isMPVRenderer, !isVLCPlayer, isRunning, !isClosing else { return }
        let wasAlreadyArmed = mpvBackgroundLifecycleIsArmed
        guard !wasAlreadyArmed || mpvBackgroundLifecycleIsInForegroundPhase else {
            logPictureInPicture(
                "coalesced duplicate background lifecycle source=\(source) generation=\(mpvBackgroundLifecycleGeneration)"
            )
            return
        }

        if wasAlreadyArmed {
            _ = resumeMPVBackgroundFallbackPauseForPictureInPictureIfNeeded(
                source: "new-background-\(source)"
            )
        }
        cancelMPVBackgroundAudioFallback(reason: "new-background-\(source)")
        mpvBackgroundLifecycleGeneration &+= 1
        invalidateMPVPictureInPictureStopAuthorization(
            reason: "serialized-background-\(source)-generation-\(mpvBackgroundLifecycleGeneration)"
        )
        mpvBackgroundLifecycleIsArmed = true
        mpvBackgroundLifecycleIsInForegroundPhase = false
        mpvForegroundRecoveryRetryCount = 0
        mpvForegroundRecoveryTask?.cancel()
        mpvForegroundRecoveryTask = nil
        invalidateMPVPictureInPictureRestoreOperation(
            reason: "serialized-background-\(source)-generation-\(mpvBackgroundLifecycleGeneration)"
        )
        cancelScheduledMPVPictureInPictureWarmups(reason: "serialized-background-\(source)")
        mpvBackgroundFallbackAutoPaused = false
        mpvBackgroundFallbackPauseIntentGeneration = nil
        mpvBackgroundFallbackPauseLifecycleGeneration = nil
        renderer.noteApplicationDidEnterBackground()
        logPictureInPicture(
            "armed serialized foreground recovery source=\(source) generation=\(mpvBackgroundLifecycleGeneration)"
        )
    }

    private func owningPlaybackSceneIsForegroundActive() -> Bool {
        bindPlaybackWindowSceneIfAvailable(source: "foreground-state-check")
        if let scene = playbackWindowScene ?? viewIfLoaded?.window?.windowScene {
            return scene.activationState == .foregroundActive
        }
#if os(iOS)

        if UIDevice.current.userInterfaceIdiom == .pad
            || UIDevice.current.userInterfaceIdiom == .mac {
            return false
        }
#endif
        return UIApplication.shared.applicationState == .active
    }

    private func requestMPVSerializedForegroundRecovery(source: String) {
        guard isMPVRenderer,
              !isVLCPlayer,
              isRunning,
              !isClosing,
              mpvBackgroundLifecycleIsArmed,
              owningPlaybackSceneIsForegroundActive() else {
            return
        }
        cancelMPVBackgroundAudioFallback(reason: "foreground-recovery-\(source)")
        renderer.noteApplicationDidBecomeActive()
        mpvBackgroundLifecycleIsInForegroundPhase = true
        guard mpvForegroundRecoveryTask == nil else {
            logPictureInPicture(
                "coalesced duplicate foreground lifecycle source=\(source) generation=\(mpvBackgroundLifecycleGeneration)"
            )
            return
        }

        let generation = mpvBackgroundLifecycleGeneration
        logPictureInPicture(
            "serialized foreground recovery begin source=\(source) generation=\(generation)"
        )
        mpvForegroundRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.performMPVSerializedForegroundRecovery(
                source: source,
                generation: generation
            )

            guard generation == self.mpvBackgroundLifecycleGeneration else { return }
            self.mpvForegroundRecoveryTask = nil
            guard self.mpvBackgroundLifecycleIsArmed,
                  self.owningPlaybackSceneIsForegroundActive() else { return }
            switch outcome {
            case .completed:
                self.mpvBackgroundLifecycleIsArmed = false
                self.mpvForegroundRecoveryRetryCount = 0
                _ = self.claimMPVAppExitPictureInPictureOwnership(
                    reason: "\(source)-serialized-complete",
                    recordingActivation: true
                )
                self.scheduleMPVPictureInPictureForegroundWarmup(
                    source: "\(source)-serialized-rewarm",
                    delays: [0.25, 1.10],
                    forceFirst: true
                )
                self.logPictureInPicture(
                    "serialized foreground recovery completed source=\(source) generation=\(generation) renderer={\(self.rendererPictureInPictureDebugSnapshot())}"
                )
            case .retryInlineRestore:
                guard self.mpvForegroundRecoveryRetryCount < 3,
                      self.owningPlaybackSceneIsForegroundActive() else {
                    self.mpvBackgroundLifecycleIsArmed = false
                    self.logPictureInPicture(
                        "serialized foreground recovery abandoned after bounded inline retries source=\(source) generation=\(generation)"
                    )
                    return
                }
                self.mpvForegroundRecoveryRetryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                    guard let self,
                          generation == self.mpvBackgroundLifecycleGeneration else { return }
                    self.requestMPVSerializedForegroundRecovery(
                        source: "\(source)-inline-retry-\(self.mpvForegroundRecoveryRetryCount)"
                    )
                }
            case .failed:
                self.mpvBackgroundLifecycleIsArmed = false
                self.mpvBackgroundFallbackAutoPaused = false
                self.mpvBackgroundFallbackPauseIntentGeneration = nil
                self.mpvBackgroundFallbackPauseLifecycleGeneration = nil
                self.logPictureInPicture(
                    "serialized foreground recovery failed source=\(source) generation=\(generation)"
                )
            }
        }
    }

    private func performMPVSerializedForegroundRecovery(
        source: String,
        generation: Int
    ) async -> MPVForegroundRecoveryOutcome {
        guard generation == mpvBackgroundLifecycleGeneration,
              mpvBackgroundLifecycleIsArmed,
              owningPlaybackSceneIsForegroundActive(),
              let controller = pipController else {
            return .failed
        }

        var requestedStop = false
        var settledInline = false
        for _ in 0..<60 {
            guard !Task.isCancelled,
                  generation == mpvBackgroundLifecycleGeneration,
                  mpvBackgroundLifecycleIsArmed,
                  owningPlaybackSceneIsForegroundActive() else {
                return .failed
            }
            let active = controller.isPictureInPictureActive
            let pending = controller.isPictureInPictureStartPending
            if active, !requestedStop {
                requestedStop = true
                cancelMPVPictureInPictureStartRequests(reason: "\(source)-active-pip-return")
                logPictureInPicture(
                    "serialized foreground recovery stopping active PiP source=\(source) generation=\(generation)"
                )
                controller.stopPictureInPicture(source: "\(source)-serialized-return")
            }
            if !active, !pending {
                settledInline = true
                break
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return .failed
            }
        }
        guard settledInline else {
            logPictureInPicture(
                "serialized foreground recovery timed out waiting for AVKit ownership source=\(source) generation=\(generation)"
            )
            cancelMPVPictureInPictureStartRequests(reason: "\(source)-avkit-timeout")
            controller.stopPictureInPicture(source: "\(source)-avkit-timeout")
            rendererFinishPictureInPicture()
            installMPVPictureInPictureController(reason: "\(source)-avkit-timeout-retire")
            return .retryInlineRestore
        }

        cancelMPVPictureInPictureStartRequests(reason: "\(source)-inline-settled")
        let operation = beginMPVPictureInPictureRestore(
            for: controller,
            lifecycleGeneration: generation
        )
        let rendererRestored = await operation.task.value
        guard generation == mpvBackgroundLifecycleGeneration,
              mpvBackgroundLifecycleIsArmed,
              owningPlaybackSceneIsForegroundActive(),
              !Task.isCancelled else {
            return .failed
        }
        let inlineRestored = completeMPVPictureInPictureRestore(
            operation,
            controller: controller,
            rendererRestored: rendererRestored,
            source: "\(source)-serialized-inline"
        )
        if !inlineRestored {

            logPictureInPicture(
                "serialized foreground recovery continuing after absent PiP restore token source=\(source) generation=\(generation)"
            )
        }

        if resumeMPVBackgroundFallbackPauseForPictureInPictureIfNeeded(
            source: "\(source)-serialized-foreground"
        ) {

            await Task.yield()
        }

        let recovered = await rendererRecoverForegroundRendering(
            reason: "\(source)-serialized-decoder-validation"
        )
        guard generation == mpvBackgroundLifecycleGeneration,
              mpvBackgroundLifecycleIsArmed,
              owningPlaybackSceneIsForegroundActive(),
              !Task.isCancelled else {
            return .failed
        }
        return recovered ? .completed : .failed
    }

    @objc private func appWillResignActive() {
        logPictureInPicture("lifecycle notification received source=will-resign-active")
        armBackgroundRecoveryProgressGateIfNeeded(source: "will-resign-active")
        if isVLCPlayer {
            logPictureInPicture("VLC app-exit PiP skipped source=will-resign-active: disabled")
            return
        }
        if Thread.isMainThread {
            primeMPVAppExitPictureInPictureIfNeeded(source: "will-resign-active")
            scheduleMPVAppExitPictureInPictureAfterBackgroundConfirmation(source: "will-resign-active")
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.primeMPVAppExitPictureInPictureIfNeeded(source: "will-resign-active")
                self?.scheduleMPVAppExitPictureInPictureAfterBackgroundConfirmation(source: "will-resign-active")
            }
        }
    }

    @objc private func appScenePhaseDidChange(_ notification: Notification) {
        let phase = notification.userInfo?["phase"] as? String ?? "unknown"
        logPictureInPicture("scenePhase notification received phase=\(phase)")
#if os(iOS)

        let idiom = UIDevice.current.userInterfaceIdiom
        if idiom == .pad || idiom == .mac {
            bindPlaybackWindowSceneIfAvailable(source: "scene-phase-\(phase)")
            logPictureInPicture("scenePhase notification ignored for multiwindow idiom=\(idiom.rawValue) phase=\(phase) ownerAttached=\(playbackWindowScene != nil)")
            return
        }
#endif
        if phase == "inactive" || phase == "background" {
            armBackgroundRecoveryProgressGateIfNeeded(source: "scene-phase-\(phase)")
        } else if phase == "active" {
            releaseMPVAppExitPictureInPictureOwnership(reason: "scene-phase-active")
            markBackgroundRecoveryForegrounded(source: "scene-phase-active")
            cancelPendingMPVAppExitPictureInPictureStart(reason: "scene-phase-active")
            clearMPVAppExitPictureInPictureSuppression(reason: "scene-phase-active")
        }
        if isVLCPlayer {
            if phase == "active" {
                logVLCForegroundSnapshot("scene-phase-active notification")
                scheduleVLCForegroundSnapshots("scene-phase-active followup", delays: [0.10, 0.75])
            }
            if phase == "inactive" || phase == "background" {
                logPictureInPicture("VLC app-exit PiP skipped source=scene-phase-\(phase): disabled")
            }
            return
        }
        switch phase {
        case "inactive":
            if Thread.isMainThread {
                primeMPVAppExitPictureInPictureIfNeeded(source: "scene-phase-inactive")
                scheduleMPVAppExitPictureInPictureAfterBackgroundConfirmation(source: "scene-phase-inactive")
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.primeMPVAppExitPictureInPictureIfNeeded(source: "scene-phase-inactive")
                    self?.scheduleMPVAppExitPictureInPictureAfterBackgroundConfirmation(source: "scene-phase-inactive")
                }
            }
        case "background":
            noteMPVBackgroundLifecycleIfNeeded(source: "scene-phase-background")
            if Thread.isMainThread {
                cancelPendingMPVAppExitPictureInPictureStart(reason: "scene-phase-background")
                attemptMPVAppExitPictureInPictureStart(source: "scene-phase-background")
                scheduleMPVBackgroundAudioFallback(source: "scene-phase-background")
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.cancelPendingMPVAppExitPictureInPictureStart(reason: "scene-phase-background")
                    self?.attemptMPVAppExitPictureInPictureStart(source: "scene-phase-background")
                    self?.scheduleMPVBackgroundAudioFallback(source: "scene-phase-background")
                }
            }
        case "active":
            requestMPVSerializedForegroundRecovery(source: "scene-phase-active")
        default:
            break
        }
    }

    private func scheduleMPVAppExitPictureInPictureAfterBackgroundConfirmation(source: String, delay: TimeInterval = 0.35) {
        guard !isVLCPlayer, isMPVRenderer else { return }
        guard claimMPVAppExitPictureInPictureOwnership(reason: source) else { return }
        guard !isClosing else {
            logPictureInPicture("MPV app-exit auto PiP pending skipped source=\(source): closing")
            return
        }
        guard !mpvAppExitPiPSuppressedUntilForeground else {
            logPictureInPicture("MPV app-exit auto PiP pending skipped source=\(source): suppressed-until-foreground")
            return
        }
        configureMPVAppExitPictureInPictureAutomation(reason: source)
        guard Settings.shared.mpvAppExitPictureInPictureEnabled else {
            logPictureInPicture("MPV app-exit auto PiP skipped source=\(source): disabled")
            return
        }
        mpvPendingAppExitPiPWorkItem?.cancel()
        #if os(tvOS)
        if UIApplication.shared.applicationState != .background {
            attemptMPVAppExitPictureInPictureStart(source: "\(source)-pre-background")
        }
        #else
        if UIApplication.shared.applicationState != .background {

            logPictureInPicture(
                "MPV app-exit explicit pre-background start deferred to automatic-from-inline source=\(source)"
            )
        }
        #endif

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.mpvPendingAppExitPiPWorkItem = nil
            let appState = UIApplication.shared.applicationState
            guard appState == .background else {
                self.logPictureInPicture("MPV app-exit auto PiP canceled source=\(source): appState=\(self.applicationStateDescription(appState))")
                return
            }
            self.attemptMPVAppExitPictureInPictureStart(source: "\(source)-confirmed-background")
        }
        mpvPendingAppExitPiPWorkItem = workItem
        logPictureInPicture("MPV app-exit auto PiP pending source=\(source) delay=\(String(format: "%.2f", delay))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelPendingMPVAppExitPictureInPictureStart(reason: String) {
        guard mpvPendingAppExitPiPWorkItem != nil else { return }
        mpvPendingAppExitPiPWorkItem?.cancel()
        mpvPendingAppExitPiPWorkItem = nil
        logPictureInPicture("MPV app-exit auto PiP pending canceled reason=\(reason)")
    }

    private func applicationStateDescription(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func attemptMPVAppExitPictureInPictureStart(source: String) {
        guard !isVLCPlayer else {
            logPictureInPicture("app-exit auto PiP skipped source=\(source): VLC renderer unavailable")
            return
        }
        guard isMPVRenderer else {
            logPictureInPicture("app-exit auto PiP skipped source=\(source): MPV renderer missing")
            return
        }
        guard claimMPVAppExitPictureInPictureOwnership(reason: source) else { return }
        guard Settings.shared.mpvPictureInPictureEnabled else {
            logPictureInPicture("MPV app-exit auto PiP skipped source=\(source): PiP disabled")
            return
        }
        guard Settings.shared.mpvAppExitPictureInPictureEnabled else {
            logPictureInPicture("MPV app-exit auto PiP skipped source=\(source): disabled")
            return
        }
        if mpvAppExitPiPSuppressedUntilForeground {
            let appState = applicationStateDescription(UIApplication.shared.applicationState)
            logPictureInPicture("MPV app-exit auto PiP skipped source=\(source): suppressed-until-foreground appState=\(appState)")
            if source.contains("background") || UIApplication.shared.applicationState == .background {
                scheduleMPVBackgroundAudioFallback(source: "\(source)-suppressed")
            }
            return
        }
        configureMPVAppExitPictureInPictureAutomation(reason: source)
        guard let pip = pipController else {
            logPictureInPicture("app-exit auto PiP skipped source=\(source): controller missing")
            return
        }

        let paused = rendererIsPausedState()
        let playbackReady = playbackDidStart || cachedPosition > 0.1
        let active = pip.isPictureInPictureActive
        let pending = pip.isPictureInPictureStartPending
        let supported = pip.isPictureInPictureSupported
        let possible = pip.isPictureInPicturePossible
        let appState = applicationStateDescription(UIApplication.shared.applicationState)
        let shouldScheduleBackgroundFallback = source.contains("background")
            || appState == "background"
        defer {

            if shouldScheduleBackgroundFallback {
                scheduleMPVBackgroundAudioFallback(source: source)
            }
        }

        if UIApplication.shared.applicationState == .background,
           !active,
           !pending,
           !rendererIsPictureInPicturePrimed() {

            logPictureInPicture("MPV app-exit auto PiP skipped source=\(source): renderer was not primed before background")
            return
        }

        let shouldStart = isRunning
            && !isClosing
            && !active
            && !pending
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
        } else if pending {
            skipReason = "transition-pending"
        } else if paused {
            skipReason = "paused"
        } else if !playbackReady {
            skipReason = "playback-not-started"
        } else if !supported {
            skipReason = "unsupported"
        } else {
            skipReason = "unknown"
        }

        logPictureInPicture("MPV app-exit auto PiP check source=\(source) shouldStart=\(shouldStart) skipReason=\(skipReason) appState=\(appState) active=\(active) pending=\(pending) possible=\(possible) supported=\(supported) paused=\(paused) ready=\(playbackReady) loading=\(isRendererLoading) requested=\(mpvAppExitPiPStartRequested) subs={\(subtitlePictureInPictureDebugSnapshot())} renderer={\(rendererPictureInPictureDebugSnapshot())}")

        if pending {
            mpvAppExitPiPStartRequested = true
            return
        }
        guard shouldStart else { return }
        #if !os(tvOS)
        if pip.isAutomaticFromInlineEnabled {
            if !mpvAppExitPiPStartRequested {
                mpvAppExitPiPStartRequested = true
                pip.updatePlaybackState()
                logPictureInPicture(
                    "MPV app-exit start owned by automatic-from-inline source=\(source) attemptID=\(pip.transitionAttemptID)"
                )
            } else {
                logPictureInPicture(
                    "MPV app-exit automatic-from-inline already armed; ignoring explicit duplicate source=\(source)"
                )
            }
            return
        }
        #endif
        guard !mpvAppExitPiPStartRequested else {
            logPictureInPicture("MPV app-exit auto PiP already requested; ignoring duplicate source=\(source)")
            return
        }

        mpvAppExitPiPStartRequested = true
        startMPVPictureInPictureWhenPossible(source: source)
    }

    private func shouldHandleSceneLifecycleNotification(
        _ notification: Notification,
        source: String
    ) -> Bool {
        guard let notificationScene = notification.object as? UIWindowScene else {
            logPictureInPicture("ignored \(source) without a window scene")
            return false
        }
        bindPlaybackWindowSceneIfAvailable(source: source)
        guard let owningScene = playbackWindowScene ?? viewIfLoaded?.window?.windowScene else {
#if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad
                || UIDevice.current.userInterfaceIdiom == .mac {

                logPictureInPicture("ignored \(source) while multiwindow playback scene is unattached")
                return false
            }
#endif

            return true
        }
        guard notificationScene === owningScene else {
            logPictureInPicture("ignored \(source) for another window scene")
            return false
        }
        return true
    }

    private func shouldHandleIPadSceneDeactivationForAppExitPiP(source: String) -> Bool {
#if os(iOS)
        if (UIDevice.current.userInterfaceIdiom == .pad
                || UIDevice.current.userInterfaceIdiom == .mac),
           UIApplication.shared.applicationState == .active {
            let owningScene = playbackWindowScene ?? viewIfLoaded?.window?.windowScene
            let anotherEclipseSceneIsActive = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .contains { scene in
                    scene.activationState == .foregroundActive
                        && (owningScene == nil || scene !== owningScene)
                }
            guard anotherEclipseSceneIsActive else { return true }

            logPictureInPicture("ignored \(source) app-exit PiP while another multiwindow scene keeps the app active")
            return false
        }
#endif
        return true
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard shouldHandleSceneLifecycleNotification(notification, source: "scene-will-deactivate") else { return }
        logPictureInPicture("lifecycle notification received source=scene-will-deactivate")
        armBackgroundRecoveryProgressGateIfNeeded(source: "scene-will-deactivate")
        guard shouldHandleIPadSceneDeactivationForAppExitPiP(source: "scene-will-deactivate") else { return }
        if isVLCPlayer {
            logPictureInPicture("VLC app-exit PiP skipped source=scene-will-deactivate: disabled")
            return
        }
#if os(iOS) && ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
        if metalMPVRenderer != nil {
            logPictureInPicture("scene-will-deactivate pending MoltenVK GPU sample-buffer PiP handoff until background confirmation")
            primeMPVAppExitPictureInPictureIfNeeded(source: "scene-will-deactivate-moltenvk")
            scheduleMPVAppExitPictureInPictureAfterBackgroundConfirmation(source: "scene-will-deactivate-moltenvk", delay: 0.35)
            return
        }
#endif
        if Thread.isMainThread {
            primeMPVAppExitPictureInPictureIfNeeded(source: "scene-will-deactivate")
            scheduleMPVAppExitPictureInPictureAfterBackgroundConfirmation(source: "scene-will-deactivate")
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.primeMPVAppExitPictureInPictureIfNeeded(source: "scene-will-deactivate")
                self?.scheduleMPVAppExitPictureInPictureAfterBackgroundConfirmation(source: "scene-will-deactivate")
            }
        }
    }

    @objc private func sceneDidEnterBackground(_ notification: Notification) {
        guard shouldHandleSceneLifecycleNotification(notification, source: "scene-did-enter-background") else { return }
        logPictureInPicture("lifecycle notification received source=scene-did-enter-background")
        armBackgroundRecoveryProgressGateIfNeeded(source: "scene-did-enter-background")

        noteMPVBackgroundLifecycleIfNeeded(source: "scene-did-enter-background")
        guard shouldHandleIPadSceneDeactivationForAppExitPiP(
            source: "scene-did-enter-background"
        ) else {
            scheduleMPVBackgroundAudioFallback(source: "scene-did-enter-background-other-scene-active")
            return
        }
        if isVLCPlayer {
            logPictureInPicture("VLC app-exit PiP skipped source=scene-did-enter-background: disabled")
            return
        }
        if Thread.isMainThread {
            primeMPVAppExitPictureInPictureIfNeeded(source: "scene-did-enter-background")
            cancelPendingMPVAppExitPictureInPictureStart(reason: "scene-did-enter-background")
            attemptMPVAppExitPictureInPictureStart(source: "scene-did-enter-background")
            scheduleMPVBackgroundAudioFallback(source: "scene-did-enter-background")
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.primeMPVAppExitPictureInPictureIfNeeded(source: "scene-did-enter-background")
                self?.cancelPendingMPVAppExitPictureInPictureStart(reason: "scene-did-enter-background")
                self?.attemptMPVAppExitPictureInPictureStart(source: "scene-did-enter-background")
                self?.scheduleMPVBackgroundAudioFallback(source: "scene-did-enter-background")
            }
        }
    }

    private func currentMPVBackgroundAudioFallbackKey() -> MPVBackgroundAudioFallbackKey {
        MPVBackgroundAudioFallbackKey(
            lifecycleGeneration: mpvBackgroundLifecycleGeneration,
            loadGeneration: playbackLoadGeneration,
            controllerIdentifier: pipController.map { ObjectIdentifier($0) },
            transitionAttemptID: pipController?.transitionAttemptID
        )
    }

    private func cancelMPVBackgroundAudioFallback(reason: String) {
        let hadScheduledFallback = mpvBackgroundAudioFallbackWorkItem != nil
            || mpvBackgroundAudioFallbackKey != nil
        mpvBackgroundAudioFallbackWorkItem?.cancel()
        mpvBackgroundAudioFallbackWorkItem = nil
        mpvBackgroundAudioFallbackKey = nil
        mpvBackgroundAudioFallbackDeadline = 0
        if hadScheduledFallback {
            logPictureInPicture("MPV background fallback canceled reason=\(reason)")
        }
    }

    private func scheduleMPVBackgroundAudioFallback(
        source: String,
        delay: TimeInterval = 0.75
    ) {
        guard isMPVRenderer, !isVLCPlayer, isRunning, !isClosing else { return }
        let key = currentMPVBackgroundAudioFallbackKey()
        let now = CACurrentMediaTime()

        if mpvBackgroundAudioFallbackKey != key {
            cancelMPVBackgroundAudioFallback(reason: "superseded-\(source)")
            mpvBackgroundAudioFallbackKey = key

            mpvBackgroundAudioFallbackDeadline = now + 10
        } else if mpvBackgroundAudioFallbackWorkItem != nil {
            let attemptText = key.transitionAttemptID.map { String($0) } ?? "nil"
            logPictureInPicture(
                "MPV background fallback coalesced source=\(source) lifecycle=\(key.lifecycleGeneration) load=\(key.loadGeneration) attempt=\(attemptText)"
            )
            return
        } else if mpvBackgroundAudioFallbackDeadline <= 0 {
            mpvBackgroundAudioFallbackDeadline = now + 10
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.mpvBackgroundAudioFallbackKey == key else { return }
            self.mpvBackgroundAudioFallbackWorkItem = nil
            self.performMPVBackgroundAudioFallback(source: source, key: key)
        }
        mpvBackgroundAudioFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func performMPVBackgroundAudioFallback(
        source: String,
        key: MPVBackgroundAudioFallbackKey
    ) {
        guard mpvBackgroundAudioFallbackKey == key else { return }
        let currentKey = currentMPVBackgroundAudioFallbackKey()
        let owningScene = playbackWindowScene ?? viewIfLoaded?.window?.windowScene
        let owningPlaybackIsBackgrounded = UIApplication.shared.applicationState == .background
            || owningScene?.activationState == .background

        guard key == currentKey,
              key.lifecycleGeneration == mpvBackgroundLifecycleGeneration,
              key.loadGeneration == playbackLoadGeneration,
              mpvBackgroundLifecycleIsArmed,
              !mpvBackgroundLifecycleIsInForegroundPhase,
              isMPVRenderer,
              !isVLCPlayer,
              isRunning,
              !isClosing,
              owningPlaybackIsBackgrounded else {
            cancelMPVBackgroundAudioFallback(reason: "stale-\(source)")
            return
        }

        let controller = pipController
        let active = controller?.isPictureInPictureActive ?? false
        let pending = controller?.isPictureInPictureStartPending ?? false
        let requested = mpvAppExitPiPStartRequested
        let rendererHandoff = mpvPictureInPictureRendererHandoffIsActive

        let primed = rendererIsPictureInPicturePrimed()
        if active, primed {
            let resumed = resumeMPVBackgroundFallbackPauseForPictureInPictureIfNeeded(
                source: "\(source)-active-backstop"
            )
            if resumed {
                controller?.updatePlaybackState()
            }
            cancelMPVBackgroundAudioFallback(reason: "PiP-active-\(source)")
            return
        }

        let transitionOwned = active || pending || requested || rendererHandoff
        if transitionOwned, CACurrentMediaTime() < mpvBackgroundAudioFallbackDeadline {
            let attemptText = key.transitionAttemptID.map { String($0) } ?? "nil"
            logPictureInPicture(
                "MPV background fallback waiting for PiP source=\(source) active=\(active) pending=\(pending) requested=\(requested) rendererHandoff=\(rendererHandoff) primed=\(primed) lifecycle=\(key.lifecycleGeneration) attempt=\(attemptText)"
            )
            scheduleMPVBackgroundAudioFallback(source: source, delay: 0.50)
            return
        }

        if transitionOwned {

            logPictureInPicture(
                "MPV background PiP handoff timed out source=\(source) active=\(active) pending=\(pending) requested=\(requested) rendererHandoff=\(rendererHandoff) primed=\(primed) renderer={\(rendererPictureInPictureDebugSnapshot())}"
            )
            controller?.setCanStartPictureInPictureAutomaticallyFromInline(false)
            cancelMPVPictureInPictureStartRequests(reason: "background-fallback-timeout-\(source)")
            releaseMPVAppExitPictureInPictureOwnership(
                reason: "background-fallback-timeout-\(source)"
            )
            if active || pending {
                controller?.stopPictureInPicture(source: "background-fallback-timeout")
            }

            rendererFinishPictureInPicture()
            installMPVPictureInPictureController(reason: "background-fallback-timeout")
            rendererSetPictureInPictureSourcePreparedForAutomaticStart(false)
        }

        if rendererIsPausedState() {

            cancelMPVBackgroundAudioFallback(reason: "renderer-paused-\(source)")
            return
        }

        cancelMPVBackgroundAudioFallback(reason: "executing-\(source)")
        mpvAppExitPiPStartRequested = false
        mpvBackgroundFallbackAutoPaused = true
        mpvBackgroundFallbackPauseIntentGeneration = rendererPlaybackIntentGeneration
        mpvBackgroundFallbackPauseLifecycleGeneration = mpvBackgroundLifecycleGeneration
        logPictureInPicture(
            "MPV background fallback pause source=\(source) lifecycle=\(mpvBackgroundLifecycleGeneration) load=\(playbackLoadGeneration) renderer={\(rendererPictureInPictureDebugSnapshot())}"
        )
        rendererPausePlayback(preservingBackgroundFallbackOwnership: true)
#if os(iOS)
        WatchTogetherCoordinator.shared.sendLifecyclePause(from: self)
#endif
    }

    @objc private func appDidEnterBackground() {
        logPictureInPicture("lifecycle notification received source=did-enter-background")
        armBackgroundRecoveryProgressGateIfNeeded(source: "did-enter-background")
        noteMPVBackgroundLifecycleIfNeeded(source: "did-enter-background")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logVLCUIViewSnapshot("appDidEnterBackground async start")
            if self.vlcRenderer != nil {
                Logger.shared.log("[PlayerVC.PiP] VLC background auto-start skipped: disabled", type: "Player")
                self.logVLCUIViewSnapshot("appDidEnterBackground async end")
                self.scheduleVLCUIViewSnapshots("appDidEnterBackground followup", delays: [0.5, 1.5])
                return
            }

            self.cancelPendingMPVAppExitPictureInPictureStart(reason: "did-enter-background")
            self.primeMPVAppExitPictureInPictureIfNeeded(source: "did-enter-background")
            self.attemptMPVAppExitPictureInPictureStart(source: "did-enter-background")
            self.scheduleMPVBackgroundAudioFallback(source: "did-enter-background")
        }
    }

    @objc private func appWillTerminate() {
        logSharedPlayerControl("lifecycle notification received source=will-terminate")
        if let mediaInfo {
            syncTraktProgressOnPlaybackCloseIfNeeded(for: mediaInfo, reason: "will-terminate")
        }
    }

    @objc private func appWillEnterForeground() {
        logVLCForegroundSnapshot("will-enter-foreground notification")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPlayerSkinDecorationAnimations()
            self.logVLCForegroundSnapshot("will-enter-foreground async start")
#if !os(tvOS)
            if self.supportsSharedPlayerControls {
                self.refreshGestureControlLevels(animated: false)
            }
#endif
            if self.vlcRenderer != nil {
                Logger.shared.log("[PlayerVC.PiP] VLC foreground PiP check skipped: disabled", type: "Player")
                self.logVLCForegroundSnapshot("will-enter-foreground async end")
                self.scheduleVLCForegroundSnapshots("will-enter-foreground followup", delays: [0.10, 0.50, 1.50, 3.00])
                return
            }

        }
    }

    @objc private func sceneWillEnterForeground(_ notification: Notification) {
        guard shouldHandleSceneLifecycleNotification(notification, source: "scene-will-enter-foreground") else { return }
        releaseMPVAppExitPictureInPictureOwnership(reason: "scene-will-enter-foreground")
        markBackgroundRecoveryForegrounded(source: "scene-will-enter-foreground")
        cancelPendingMPVAppExitPictureInPictureStart(reason: "scene-will-enter-foreground")
        clearMPVAppExitPictureInPictureSuppression(reason: "scene-will-enter-foreground")
        if isVLCPlayer {
            logVLCForegroundSnapshot("scene-will-enter-foreground notification")
            scheduleVLCForegroundSnapshots("scene-will-enter-foreground followup", delays: [0.10, 0.75])
            return
        }

    }

    @objc private func appDidBecomeActive() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let owningScene = self.viewIfLoaded?.window?.windowScene ?? self.playbackWindowScene,
               owningScene.activationState != .foregroundActive {
                self.logPictureInPicture(
                    "appDidBecomeActive ignored for background owning scene state=\(owningScene.activationState.rawValue)"
                )
                return
            }
            self.markBackgroundRecoveryForegrounded(source: "did-become-active")
            self.cancelPendingMPVAppExitPictureInPictureStart(reason: "did-become-active")
            self.clearMPVAppExitPictureInPictureSuppression(reason: "did-become-active")
            self.refreshPlayerSkinDecorationAnimations()
            if self.isVLCPlayer {
                self.logVLCForegroundSnapshot("did-become-active")
                self.scheduleVLCForegroundSnapshots("did-become-active followup", delays: [0.10, 0.75, 2.00])
                return
            }
            guard self.vlcRenderer == nil else { return }
            self.requestMPVSerializedForegroundRecovery(source: "app-did-become-active")
        }
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard shouldHandleSceneLifecycleNotification(notification, source: "scene-did-activate") else { return }
        let claimedPiPOwnership = claimMPVAppExitPictureInPictureOwnership(
            reason: "scene-did-activate",
            recordingActivation: true
        )
        if claimedPiPOwnership, !mpvBackgroundLifecycleIsArmed {
            configureMPVAppExitPictureInPictureAutomation(reason: "scene-did-activate")
        }
        markBackgroundRecoveryForegrounded(source: "scene-did-activate")
        cancelPendingMPVAppExitPictureInPictureStart(reason: "scene-did-activate")
        clearMPVAppExitPictureInPictureSuppression(reason: "scene-did-activate")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isVLCPlayer {
                self.logVLCForegroundSnapshot("scene-did-activate")
                self.scheduleVLCForegroundSnapshots("scene-did-activate followup", delays: [0.10, 0.75])
                return
            }
            guard self.vlcRenderer == nil else { return }
            self.requestMPVSerializedForegroundRecovery(source: "scene-did-activate")
        }
    }
}
