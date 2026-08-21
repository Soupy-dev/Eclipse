import Foundation
#if canImport(AVKit)
import AVKit
#endif
#if canImport(UIKit)
import UIKit
#endif

enum EclipsePlatform: String, Sendable {
    case iOS
    case tvOS
    case visionOS
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
    let supportsSkyStreamPlugins: Bool
    let supportsNuvioPlugins: Bool

    static var current: PlatformCapabilities { resolved }

    private static let resolved: PlatformCapabilities = {
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
            supportsGitHubUpdates: false,
            supportsSkyStreamPlugins: false,
            supportsNuvioPlugins: false
        )
#elseif os(visionOS)
        return PlatformCapabilities(
            platform: .visionOS,
            supportsReader: false,
            supportsDownloads: false,
            supportsBrowserAutomation: false,
            supportsFileSharing: false,
            supportsTouchInput: false,
            supportsCellularSettings: false,
            supportsExternalPlayers: false,
            supportsPictureInPicture: false,
            supportsMPV: false,
            supportsStoreKit: true,
            supportsCloudKit: true,
            supportsGitHubUpdates: false,
            supportsSkyStreamPlugins: false,
            supportsNuvioPlugins: false
        )
#else
#if canImport(UIKit)

        if #available(iOS 17.0, *),
           UIDevice.current.userInterfaceIdiom == .vision {
            return PlatformCapabilities(
                platform: .visionOS,
                supportsReader: false,
                supportsDownloads: false,
                supportsBrowserAutomation: false,
                supportsFileSharing: false,
                supportsTouchInput: false,
                supportsCellularSettings: false,
                supportsExternalPlayers: false,
                supportsPictureInPicture: false,
                supportsMPV: false,
                supportsStoreKit: true,
                supportsCloudKit: true,
                supportsGitHubUpdates: false,
                supportsSkyStreamPlugins: false,
                supportsNuvioPlugins: false
            )
        }
#endif
#if targetEnvironment(macCatalyst)
        let supportsSkyStreamPlugins = false
        let supportsNuvioPlugins = false
#else
        let supportsSkyStreamPlugins = Bundle.main.allowsSkyStreamPlugins
        let supportsNuvioPlugins = Bundle.main.allowsNuvioPlugins
#endif
        return PlatformCapabilities(
            platform: .iOS,
            supportsReader: true,
            supportsDownloads: true,
            supportsBrowserAutomation: true,
            supportsFileSharing: true,
            supportsTouchInput: true,
            supportsCellularSettings: true,
            supportsExternalPlayers: true,

            supportsPictureInPicture: true,
            supportsMPV: true,
            supportsStoreKit: true,
            supportsCloudKit: true,
            supportsGitHubUpdates: GitHubReleaseChecker.isGitHubReleaseUpdatesAvailable,
            supportsSkyStreamPlugins: supportsSkyStreamPlugins,
            supportsNuvioPlugins: supportsNuvioPlugins
        )
#endif
    }()
}
