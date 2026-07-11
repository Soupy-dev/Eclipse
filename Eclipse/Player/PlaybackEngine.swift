import Foundation

/// The playback implementation selected for a launch. `automatic` is deliberately a real
/// persisted choice rather than an alias: on tvOS it permits a single pre-first-frame retry from
/// MPV to AVPlayer without changing the user's future launches.
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
            return "Use MPV first and retry with AVPlayer if MPV cannot produce the first frame."
        case .mpv:
            return "Always use the MoltenVK MPV renderer."
        case .avPlayer:
            return "Always use Apple's system player."
        }
    }

    static var selected: PlaybackEngine {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let value = PlaybackEngine(rawValue: raw) {
                return value
            }
#if os(tvOS)
            return .automatic
#else
            // Preserve the existing iOS player choice until the user explicitly adopts the new
            // engine setting. This keeps the shared coordinator behavior-neutral on iPhone/iPad.
            return Settings.normalizedInAppPlayer(UserDefaults.standard.string(forKey: "inAppPlayer")) == "mpv"
                ? .mpv
                : .avPlayer
#endif
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
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

/// Pure state used by the television player so progress and end-of-item events can reveal a
/// choice, but can never launch the next episode themselves.
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
