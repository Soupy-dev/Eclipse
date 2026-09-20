import Foundation

enum MangayomiEpisodeSelectionPolicy {
    static func matchingEpisodes(
        _ episodes: [EpisodeLink],
        sourceID: UUID,
        isMovie: Bool,
        seasonNumber: Int?,
        episodeNumber: Int?,
        context: EpisodePlaybackContext?
    ) -> [EpisodeLink] {
        let valid = episodes.filter {
            (try? MangayomiMediaKey.decode($0.href, source: sourceID, kind: "episode")) != nil
        }
        if isMovie { return valid.count == 1 ? valid : [] }
        guard let seasonNumber, seasonNumber > 0,
              let episodeNumber, episodeNumber > 0,
              context?.isSpecial != true else { return [] }
        let numbered = valid.filter { episode in
            guard episode.number > 0,
                  let key = try? MangayomiMediaKey.decode(episode.href, source: sourceID, kind: "episode"),
                  let raw = key.number,
                  let number = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { return false }
            return number == Decimal(episode.number)
        }
        let numbers = Set(numbered.map(\.number))
        let targetNumber: Int
        if let context, context.hasAnimeMediaId,
           context.localSeasonNumber == seasonNumber,
           context.localEpisodeNumber == episodeNumber,
           let count = context.animeSeasonEpisodeCount, count > 0,
           (numbers.max() ?? 0) > count,
           let absolute = context.animeAbsoluteEpisodeNumber, absolute > 0,
           absolute != episodeNumber {
            targetNumber = absolute
        } else if seasonNumber == 1 {
            targetNumber = episodeNumber
        } else {
            guard let context, context.hasAnimeMediaId,
                  context.localSeasonNumber == seasonNumber,
                  context.localEpisodeNumber == episodeNumber,
                  let count = context.animeSeasonEpisodeCount, count > 0,
                  (numbers.max() ?? 0) <= count,
                  numbers.count <= count, episodeNumber <= count else { return [] }
            targetNumber = episodeNumber
        }
        var seen = Set<String>()
        let matches = numbered.filter { $0.number == targetNumber && seen.insert($0.href).inserted }
        if matches.count > 1 {
            let lanes = matches.compactMap {
                (try? MangayomiMediaKey.decode($0.href, source: sourceID, kind: "episode"))?.audio?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
            guard lanes.count == matches.count, Set(lanes).count == matches.count else { return [] }
        }
        return matches
    }
}

extension PlaybackExternalAudioTrack {
    static func serviceTracks(in source: [String: Any]) -> [Self] {
        guard let rows = source["externalAudioTracks"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return rows.prefix(32).compactMap { row in
            guard let raw = (row["url"] ?? row["file"]) as? String,
                  let url = ServiceSandboxState.validatedHTTPURL(raw),
                  seen.insert(url.absoluteString).inserted else { return nil }
            return Self(url: url, label: String((row["label"] as? String ?? "Audio").prefix(256)), headers: row["headers"] as? [String: String] ?? [:])
        }
    }
}

enum LegacyServiceChallengePolicy {
    static func permitsRecovery(sourceKind: PlaybackSourceKind?, contentHref: String?, isInstalledNativeService: Bool) -> Bool {
        sourceKind == .service && isInstalledNativeService
            && contentHref?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("mangayomi:") != true
    }

    @MainActor
    static func permitsRecovery(for context: PlaybackLaunchContext?) -> Bool {
        guard let context else { return false }
        return permitsRecovery(sourceKind: context.sourceKind, contentHref: context.serviceContentHref,
            isInstalledNativeService: ServiceManager.shared.services.contains {
                SourceHealth.serviceId($0) == context.sourceId && $0.mangayomiSource == nil
            })
    }
}

