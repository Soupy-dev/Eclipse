import Foundation
#if os(iOS)
import UIKit
#endif

enum PlaybackEngine: String, CaseIterable, Codable, Identifiable {
    case automatic
    case mpv
    case avPlayer

    static let defaultsKey = "playbackEngine"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .mpv: return "MPV"
        case .avPlayer: return "AVPlayer"
        }
    }

    var settingsDescription: String {
        switch self {
        case .automatic:
#if os(tvOS)
            return "Use MPV first and retry with AVPlayer if MPV cannot produce the first frame."
#else
            return "Use AVPlayer first on iPad and retry the same stream with MoltenVK if AVPlayer cannot start playback."
#endif
        case .mpv:
            return "Always use the MoltenVK MPV renderer."
        case .avPlayer:
            return "Always use Apple's system player."
        }
    }

    static var selected: PlaybackEngine {
        get { selected() }
        set { setSelected(newValue) }
    }

    static func selected(defaults: UserDefaults = ProfileSettingsStore.active) -> PlaybackEngine {
#if os(tvOS)
        if let raw = defaults.string(forKey: defaultsKey),
           let value = PlaybackEngine(rawValue: raw) {
            return value
        }
        return .automatic
#else
        let persistedEngine = defaults.string(forKey: defaultsKey)
        let resolved = selected(
            persistedEngine: persistedEngine,
            legacyInAppPlayer: defaults.object(forKey: "inAppPlayer") as? String,
            deviceFamily: .current
        )

        if persistedEngine != nil, persistedEngine != resolved.rawValue {
            defaults.set(resolved.rawValue, forKey: defaultsKey)
        }
        return resolved
#endif
    }

    static func setSelected(
        _ engine: PlaybackEngine,
        defaults: UserDefaults = ProfileSettingsStore.active
    ) {
        let resolved = supportedSelection(engine, deviceFamily: .current)
        defaults.set(resolved.rawValue, forKey: defaultsKey)
    }

    static func availableSelections(
        deviceFamily: PlaybackDeviceFamily
    ) -> [PlaybackEngine] {
        deviceFamily == .phone ? [.mpv, .avPlayer] : allCases
    }

    static func supportedSelection(
        _ selection: PlaybackEngine,
        deviceFamily: PlaybackDeviceFamily
    ) -> PlaybackEngine {
        if deviceFamily == .phone, selection == .automatic {
            return .mpv
        }
        return selection
    }

    static func defaultSelection(
        deviceFamily: PlaybackDeviceFamily
    ) -> PlaybackEngine {
        switch deviceFamily {
        case .phone, .pad, .other:
            return .mpv
        case .television:
            return .automatic
        }
    }

    static func selected(
        persistedEngine: String?,
        legacyInAppPlayer: String?,
        deviceFamily: PlaybackDeviceFamily
    ) -> PlaybackEngine {
        if let persistedEngine,
           let engine = PlaybackEngine(rawValue: persistedEngine) {
            return supportedSelection(engine, deviceFamily: deviceFamily)
        }
        guard let legacy = legacyInAppPlayer?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !legacy.isEmpty else {
            return defaultSelection(deviceFamily: deviceFamily)
        }
        let selection: PlaybackEngine
        switch legacy {
        case "mpv", "vlc":
            selection = .mpv
        case "normal", "avplayer", "av player":
            selection = .avPlayer
        case "automatic", "auto":
            selection = .automatic
        default:
            selection = defaultSelection(deviceFamily: deviceFamily)
        }
        return supportedSelection(selection, deviceFamily: deviceFamily)
    }
}

enum TypedPluginPlaybackEnginePolicy {
    static func effectiveEngine(
        requested: PlaybackEngine,
        sourceKind: PlaybackSourceKind?
    ) -> PlaybackEngine {
        switch sourceKind {
        case .skyStream:
            return .mpv
        default:
            return requested
        }
    }
}

enum PlaybackDeviceFamily: Equatable {
    case phone
    case pad
    case television
    case other

    static var current: PlaybackDeviceFamily {
#if os(tvOS)
        return .television
#elseif os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: return .phone
        case .pad: return .pad

        default: return .phone
        }
#else
        return .other
#endif
    }
}

struct PlaybackLaunchPlan: Equatable {
    let primary: PlaybackEngine
    let preStartFallback: PlaybackEngine?

    static func make(
        selection: PlaybackEngine,
        deviceFamily: PlaybackDeviceFamily
    ) -> PlaybackLaunchPlan {
        switch PlaybackEngine.supportedSelection(selection, deviceFamily: deviceFamily) {
        case .mpv:
            return PlaybackLaunchPlan(primary: .mpv, preStartFallback: nil)
        case .avPlayer:
            return PlaybackLaunchPlan(primary: .avPlayer, preStartFallback: nil)
        case .automatic:
            if deviceFamily == .pad || deviceFamily == .other {
                return PlaybackLaunchPlan(primary: .avPlayer, preStartFallback: .mpv)
            }
            return PlaybackLaunchPlan(primary: .mpv, preStartFallback: .avPlayer)
        }
    }
}

enum PlaybackEngineRetryPolicy {

    static func shouldTryAlternateEngine(message: String) -> Bool {
        let lower = message.lowercased()
        let terminalSourceMarkers = [
            "no internet", "network connection was lost", "not connected to the internet",
            "internet connection appears to be offline",
            "http 401", "http 403", "http 404", "http 410", "http 429",
            "status 401", "status 403", "status 404", "status 410", "status 429",
            "unauthorized", "forbidden", "signed url expired"
        ]
        if terminalSourceMarkers.contains(where: { lower.contains($0) }) {
            return false
        }

        if let expression = try? NSRegularExpression(
            pattern: #"\b(?:http|status(?:\s+code)?)\s*[:=]?\s*[45]\d{2}\b"#
        ), expression.firstMatch(
            in: lower,
            range: NSRange(lower.startIndex..<lower.endIndex, in: lower)
        ) != nil {
            return false
        }
        return true
    }
}

enum PlaybackFallbackDecision: Equatable {
    case retryAutomaticallyWithAVPlayer
    case offerManualAVPlayerRetry
    case terminalError
}

enum PlaybackFallbackPolicy {
    static func decision(
        requestedEngine: PlaybackEngine,
        playbackDidStart: Bool,
        hasAttemptedAutomaticFallback: Bool
    ) -> PlaybackFallbackDecision {
        guard requestedEngine != .avPlayer else { return .terminalError }
        if playbackDidStart || requestedEngine == .mpv {
            return .offerManualAVPlayerRetry
        }
        return hasAttemptedAutomaticFallback
            ? .terminalError
            : .retryAutomaticallyWithAVPlayer
    }
}

enum PlaybackSpeedPolicy {
    static func normalized(_ savedValue: Double) -> Double {
        guard savedValue.isFinite, savedValue > 0 else { return 1 }
        return max(0.25, min(savedValue, 3))
    }
}

#if os(tvOS)
enum TVSkipSegmentPolicy {
    static func normalized(_ segments: [SkipSegment], duration: Double) -> [SkipSegment] {
        guard duration.isFinite, duration > 0 else { return [] }

        var seen = Set<String>()
        return segments
            .compactMap { segment -> SkipSegment? in
                guard segment.startTime.isFinite,
                      segment.endTime.isFinite else { return nil }
                let start = max(0, segment.startTime)
                let end = min(duration, segment.endTime)
                guard start < duration, end > start else { return nil }
                let normalized = SkipSegment(startTime: start, endTime: end, type: segment.type)
                guard seen.insert(normalized.uniqueKey).inserted else { return nil }
                return normalized
            }
            .sorted {
                if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
                return $0.startTime < $1.startTime
            }
    }

    static func activeSegment(
        in segments: [SkipSegment],
        position: Double
    ) -> SkipSegment? {
        guard position.isFinite, position >= 0 else { return nil }
        return segments.first { position >= $0.startTime && position < $0.endTime }
    }
}

enum TVNextEpisodeState: Equatable {
    case watching
    case promptingNearEnd
    case declinedNearEnd
    case promptingAtEnd
    case declinedAtEnd
    case playNextSelected
}

enum TVNextEpisodeEvent: Equatable {
    case thresholdReached
    case naturalEnd
    case keepWatching
    case back
    case playNext
}

enum TVNextEpisodeAction: Equatable {
    case none
    case showPrompt(atNaturalEnd: Bool)
    case hidePrompt(resumePlayback: Bool)
    case playNext
}

struct TVNextEpisodeTransition: Equatable {
    let state: TVNextEpisodeState
    let action: TVNextEpisodeAction
}

enum TVNextEpisodePolicy {
    static func transition(
        from state: TVNextEpisodeState,
        event: TVNextEpisodeEvent,
        hasNextEpisode: Bool
    ) -> TVNextEpisodeTransition {
        guard hasNextEpisode else {
            return TVNextEpisodeTransition(state: state, action: .none)
        }

        switch (state, event) {
        case (.watching, .thresholdReached):
            return TVNextEpisodeTransition(
                state: .promptingNearEnd,
                action: .showPrompt(atNaturalEnd: false)
            )
        case (.watching, .naturalEnd),
             (.declinedNearEnd, .naturalEnd),
             (.promptingNearEnd, .naturalEnd):
            return TVNextEpisodeTransition(
                state: .promptingAtEnd,
                action: .showPrompt(atNaturalEnd: true)
            )
        case (.promptingNearEnd, .keepWatching),
             (.promptingNearEnd, .back):
            return TVNextEpisodeTransition(
                state: .declinedNearEnd,
                action: .hidePrompt(resumePlayback: true)
            )
        case (.promptingAtEnd, .keepWatching),
             (.promptingAtEnd, .back):
            return TVNextEpisodeTransition(
                state: .declinedAtEnd,
                action: .hidePrompt(resumePlayback: false)
            )
        case (.promptingNearEnd, .playNext),
             (.promptingAtEnd, .playNext):
            return TVNextEpisodeTransition(state: .playNextSelected, action: .playNext)
        default:
            return TVNextEpisodeTransition(state: state, action: .none)
        }
    }
}
#endif
