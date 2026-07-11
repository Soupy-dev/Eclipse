import Foundation
#if canImport(AVKit)
import AVKit
#endif

enum EclipsePlatform: String, Sendable {
    case iOS
    case tvOS
}

enum SettingScope: Sendable {
    case shared
    case iOS
    case tvOS
    case reader
}

enum SettingAvailability: Equatable, Sendable {
    case available
    case hidden(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

struct SettingDescriptor<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let scope: SettingScope
    let requiredCapability: KeyPath<PlatformCapabilities, Bool>?

    init(
        id: ID,
        title: String,
        scope: SettingScope = .shared,
        requiredCapability: KeyPath<PlatformCapabilities, Bool>? = nil
    ) {
        self.id = id
        self.title = title
        self.scope = scope
        self.requiredCapability = requiredCapability
    }

    func availability(on capabilities: PlatformCapabilities = .current) -> SettingAvailability {
        switch scope {
        case .shared:
            break
        case .iOS where capabilities.platform != .iOS:
            return .hidden(reason: "This setting applies only to iPhone and iPad.")
        case .tvOS where capabilities.platform != .tvOS:
            return .hidden(reason: "This setting applies only to Apple TV.")
        case .reader where !capabilities.supportsReader:
            return .hidden(reason: "Reader mode is not part of the Apple TV app.")
        default:
            break
        }

        if let requiredCapability, !capabilities[keyPath: requiredCapability] {
            return .hidden(reason: "This feature is unavailable on the current platform.")
        }
        return .available
    }
}

/// The single source of truth for product capabilities that differ between
/// the iPhone/iPad and Apple TV targets. UI visibility and runtime entry points
/// should consult the same value so a hidden setting can never remain active.
struct PlatformCapabilities: Equatable, Sendable {
    let platform: EclipsePlatform
    let supportsReader: Bool
    let supportsDownloads: Bool
    let supportsBrowserAutomation: Bool
    let supportsFileSharing: Bool
    let supportsTouchInput: Bool
    let supportsCellularSettings: Bool
    let supportsExternalPlayers: Bool
    let supportsPictureInPicture: Bool
    let supportsMPV: Bool
    let supportsStoreKit: Bool
    let supportsCloudKit: Bool
    let supportsGitHubUpdates: Bool

    static var current: PlatformCapabilities {
#if os(tvOS)
        return PlatformCapabilities(
            platform: .tvOS,
            supportsReader: false,
            supportsDownloads: false,
            supportsBrowserAutomation: false,
            supportsFileSharing: false,
            supportsTouchInput: false,
            supportsCellularSettings: false,
            supportsExternalPlayers: false,
            supportsPictureInPicture: AVPictureInPictureController.isPictureInPictureSupported(),
            supportsMPV: true,
            supportsStoreKit: true,
            supportsCloudKit: true,
            supportsGitHubUpdates: false
        )
#else
        return PlatformCapabilities(
            platform: .iOS,
            supportsReader: true,
            supportsDownloads: true,
            supportsBrowserAutomation: true,
            supportsFileSharing: true,
            supportsTouchInput: true,
            supportsCellularSettings: true,
            supportsExternalPlayers: true,
            // PiP is an iOS/iPadOS product capability, so keep its master setting visible.
            // CoreSimulator deliberately marks iPhone device profiles as lacking its system
            // PiP overlay while iPad profiles expose it. The player still checks AVKit's live
            // support result before creating the controller or exposing runtime PiP controls.
            supportsPictureInPicture: true,
            supportsMPV: true,
            supportsStoreKit: true,
            supportsCloudKit: true,
            supportsGitHubUpdates: GitHubReleaseChecker.isGitHubReleaseUpdatesAvailable
        )
#endif
    }
}
