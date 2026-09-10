import Foundation

enum PlaybackAudioTrackLabel {
    static func title(
        id: Int,
        title: String,
        language: String,
        codec: String = "",
        channelLayout: String = "",
        channelCount: Int = 0
    ) -> String {
        let suppliedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = suppliedTitle.isEmpty
            || ["unknown", "unknown language", "und", "audio", "track"].contains(suppliedTitle.lowercased())
            || suppliedTitle.range(
                of: #"^(?:audio\s*)?(?:track\s*)?[#(]?\s*\d+\s*\)?$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        var parts = placeholder ? [] : [suppliedTitle]
        if let languageName = languageName(language),
           !containsTerm(languageName, in: suppliedTitle),
           !containsTerm(language.replacingOccurrences(of: "_", with: "-"), in: suppliedTitle) {
            parts.append(languageName)
        }
        if parts.isEmpty { parts.append("Audio \(id)") }

        let codecName = codecName(codec)
        if !codecName.isEmpty,
           !containsTerm(codecName, in: suppliedTitle),
           !containsTerm(codec, in: suppliedTitle) {
            parts.append(codecName)
        }
        let channels = channelName(layout: channelLayout, count: channelCount)
        if !channels.isEmpty, !containsTerm(channels, in: suppliedTitle) {
            parts.append(channels)
        }
        return parts.joined(separator: " · ")
    }

    private static func languageName(_ language: String) -> String? {
        let tag = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let base = tag.split(separator: "-").first.map(String.init) ?? tag
        guard !tag.isEmpty, !["und", "unknown", "unk"].contains(base) else { return nil }
        let normalized: String
        switch tag {
        case "jp": normalized = "ja"
        default: normalized = tag
        }
        let locale = Locale(identifier: "en")
        return locale.localizedString(forIdentifier: normalized)
            ?? locale.localizedString(forLanguageCode: normalized)
            ?? normalized.uppercased()
    }

    private static func codecName(_ codec: String) -> String {
        let normalized = codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "", "unknown", "und": return ""
        case "aac", "mp4a": return "AAC"
        case ".mp3": return "MP3"
        case "lpcm": return "PCM"
        case "ac3", "ac-3": return "AC-3"
        case "eac3", "e-ac3", "ec-3": return "E-AC-3"
        case "truehd": return "TrueHD"
        case "dts", "dca": return "DTS"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        default: return normalized.hasPrefix("pcm_") ? "PCM" : normalized.uppercased()
        }
    }

    private static func channelName(layout: String, count: Int) -> String {
        let normalized = layout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "mono": return "Mono"
        case "stereo": return "Stereo"
        case "", "unknown", "und": break
        default:
            if !normalized.hasPrefix("unknown") { return normalized }
        }
        return count > 0 ? "\(count) \(count == 1 ? "channel" : "channels")" : ""
    }

    private static func containsTerm(_ term: String, in title: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: trimmed)
            + "(?![\\p{L}\\p{N}])"
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

enum PlaybackAttachedSubtitleAdmission {
    static func allows(
        sourceKind: PlaybackSourceKind?,
        sourceID: String?,
        defaults: UserDefaults = ProfileSettingsStore.services
    ) -> Bool {
        guard sourceKind == .stremio else { return true }
        guard let sourceID else { return false }
        return StremioAddonComponentSettings.allowsSubtitles(sourceID: sourceID, defaults: defaults)
    }
}

enum PlaybackSubtitlePrefetchPolicy {
    enum Source: Hashable {
        case addon
        case openSubtitles
    }

    struct Candidate {
        let url: String
        let source: Source
        let matchesPreferredLanguage: Bool
    }

    static func urls(
        candidates: [Candidate],
        enabledSources: Set<Source>,
        subtitlesEnabled: Bool,
        automaticFallbackEnabled: Bool,
        warmupEnabled: Bool,
        menuIsOpen: Bool,
        resourceConstrained: Bool
    ) -> [String] {
        guard !resourceConstrained,
              menuIsOpen || (subtitlesEnabled && automaticFallbackEnabled && warmupEnabled) else {
            return []
        }
        var seen = Set<String>()
        var sourceCounts: [Source: Int] = [:]
        var result: [String] = []
        for candidate in candidates {
            guard enabledSources.contains(candidate.source),
                  menuIsOpen || candidate.matchesPreferredLanguage,
                  sourceCounts[candidate.source, default: 0] < 2,
                  let url = URL(string: candidate.url),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false,
                  seen.insert(candidate.url).inserted else { continue }
            result.append(candidate.url)
            sourceCounts[candidate.source, default: 0] += 1
            if result.count == 4 { break }
        }
        return result
    }
}

struct PlaybackMediaSelectionIntent: Equatable {
    let preferredAudioLanguage: String?
    let preferredSubtitleLanguage: String?
    let subtitlesEnabled: Bool

    static func currentDefaults(isAnime: Bool, defaults: UserDefaults = ProfileSettingsStore.active) -> Self {
        Self(
            preferredAudioLanguage: isAnime
                ? normalizedLanguage(defaults.string(forKey: "preferredAnimeAudioLanguage") ?? "jpn")
                : normalizedLanguage(defaults.string(forKey: "preferredAutoAudioLanguage") ?? "eng"),
            preferredSubtitleLanguage: normalizedLanguage(
                defaults.string(forKey: "defaultSubtitleLanguage")
            ),
            subtitlesEnabled: defaults.bool(forKey: "enableSubtitlesByDefault")
        )
    }

    func overridingRendererSelection(
        audioLanguage: String?,
        subtitleLanguage: String?,
        hasSelectedSubtitle: Bool?
    ) -> Self {
        Self(
            preferredAudioLanguage: Self.normalizedLanguage(audioLanguage)
                ?? preferredAudioLanguage,
            preferredSubtitleLanguage: Self.normalizedLanguage(subtitleLanguage)
                ?? preferredSubtitleLanguage,
            subtitlesEnabled: hasSelectedSubtitle ?? subtitlesEnabled
        )
    }

    static func normalizedLanguage(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        return normalized.isEmpty || normalized == "und" ? nil : normalized
    }
}

enum PlaybackLanguageSelectionPolicy {
    struct Option: Equatable {
        let languageTag: String?
        let displayName: String
    }

    static func preferredIndex(
        in options: [Option],
        preferredLanguage: String?
    ) -> Int? {
        guard !options.isEmpty else { return nil }
        guard let preferred = PlaybackMediaSelectionIntent.normalizedLanguage(preferredLanguage) else {
            return nil
        }
        let preferredBase = preferred.split(separator: "-").first.map(String.init) ?? preferred

        if let exact = options.firstIndex(where: {
            PlaybackMediaSelectionIntent.normalizedLanguage($0.languageTag) == preferred
        }) {
            return exact
        }
        if let baseMatch = options.firstIndex(where: {
            guard let language = PlaybackMediaSelectionIntent.normalizedLanguage($0.languageTag) else {
                return false
            }
            return language.split(separator: "-").first.map(String.init) == preferredBase
        }) {
            return baseMatch
        }

        let preferredNames = languageSearchTerms(for: preferred)
        return options.firstIndex { option in
            let name = option.displayName
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            let nameTokens = Set(
                name.components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
            )
            return preferredNames.contains { term in

                term.count <= 3 ? nameTokens.contains(term) : name.contains(term)
            }
        }
    }

    private static func languageSearchTerms(for normalizedLanguage: String) -> [String] {
        let base = normalizedLanguage.split(separator: "-").first.map(String.init) ?? normalizedLanguage
        var terms = [normalizedLanguage, base]
        let locale = Locale(identifier: "en")
        if let localizedName = locale.localizedString(forLanguageCode: base)?.lowercased() {
            terms.append(localizedName)
        }
        return Array(Set(terms.filter { !$0.isEmpty }))
    }
}

struct PlaybackEpisodeCoordinate: Equatable {
    let seasonNumber: Int
    let episodeNumber: Int

    init?(seasonNumber: Int?, episodeNumber: Int?) {
        guard let seasonNumber,
              let episodeNumber,
              seasonNumber >= 0 || AnimeSyntheticSeasonKey.isSynthetic(seasonNumber),
              episodeNumber > 0 else { return nil }
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
    }
}

enum PlayerServicesButtonSettings {
    static let key = "showPlayerServicesButton"

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        defaults.object(forKey: key) == nil ? false : defaults.bool(forKey: key)
    }
}

struct PlayerServicesSelectionContext {
    let mediaTitle: String
    let seasonTitleOverride: String?
    let originalTitle: String?
    let isMovie: Bool
    let isAnime: Bool
    let selectedEpisode: TMDBEpisode?
    let tmdbID: Int
    let mediaYear: Int?
    let animeSeasonTitle: String?
    let posterPath: String?
    let originalAudioLanguage: String?
    let imdbID: String?
    let originalTMDBSeasonNumber: Int?
    let originalTMDBEpisodeNumber: Int?
    let specialTitleOnlySearch: Bool
    let episodePlaybackContext: EpisodePlaybackContext?
    let isAnimation: Bool

    init?(request: PlaybackRequest) {
        guard let mediaInfo = request.mediaInfo else { return nil }
        let fallbackPoster = request.artworkURL?.absoluteString
        switch mediaInfo {
        case .movie(let id, let title, let posterURL, let mediaIsAnime):
            mediaTitle = title
            seasonTitleOverride = nil
            originalTitle = request.servicesOriginalTitle
            isMovie = true
            isAnime = request.isAnime || mediaIsAnime
            selectedEpisode = nil
            tmdbID = id
            animeSeasonTitle = nil
            posterPath = posterURL ?? fallbackPoster
        case .episode(let showID, let seasonNumber, let episodeNumber, let showTitle, let showPosterURL, let mediaIsAnime):
            let resolvedTitle = showTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestTitle = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = resolvedTitle?.isEmpty == false ? resolvedTitle! : (requestTitle.isEmpty ? "Show" : requestTitle)
            let resolvedIsAnime = request.isAnime || mediaIsAnime || request.episodePlaybackContext?.hasAnimeMediaId == true
            mediaTitle = title
            isMovie = false
            isAnime = resolvedIsAnime
            seasonTitleOverride = resolvedIsAnime ? requestTitle.nilIfEmpty : nil
            originalTitle = request.servicesOriginalTitle
            selectedEpisode = TMDBEpisode(
                id: RemoteMediaNumericBoundary.syntheticIdentifier([
                    (showID, 1_000_000),
                    (max(0, seasonNumber), 10_000),
                    (max(1, episodeNumber), 1)
                ]),
                name: request.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                overview: nil,
                stillPath: nil,
                episodeNumber: episodeNumber,
                seasonNumber: seasonNumber,
                airDate: nil,
                runtime: nil,
                voteAverage: 0,
                voteCount: 0
            )
            tmdbID = showID
            animeSeasonTitle = resolvedIsAnime ? (requestTitle.nilIfEmpty ?? title) : nil
            posterPath = showPosterURL ?? fallbackPoster
        }
        originalAudioLanguage = request.servicesOriginalAudioLanguage
        mediaYear = request.mediaYear
        imdbID = request.imdbID
        originalTMDBSeasonNumber = request.episodePlaybackContext?.resolvedTMDBSeasonNumber
            ?? request.originalTMDBSeasonNumber
        originalTMDBEpisodeNumber = request.episodePlaybackContext?.resolvedTMDBEpisodeNumber
            ?? request.originalTMDBEpisodeNumber
        specialTitleOnlySearch = request.episodePlaybackContext?.titleOnlySearch ?? false
        episodePlaybackContext = request.episodePlaybackContext
        isAnimation = request.isAnimation
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct PlaybackRequest {
    let url: URL
    let preset: PlayerPreset
    let headers: [String: String]
    let subtitles: [String]
    let subtitleNames: [String]?
    let subtitleHeadersByURL: [String: [String: String]]?
    let mediaSelectionIntent: PlaybackMediaSelectionIntent
    let mediaInfo: MediaInfo?

    let kidsPolicyDetails: KidsPolicyDetails?
    let mediaYear: Int?
    let imdbID: String?
    let episodePlaybackContext: EpisodePlaybackContext?
    let launchContext: PlaybackLaunchContext?
    let resumePosition: Double?
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let isAnime: Bool
    let isAnimation: Bool
    let originalTMDBSeasonNumber: Int?
    let originalTMDBEpisodeNumber: Int?
    let servicesOriginalTitle: String?
    let servicesOriginalAudioLanguage: String?
    let onRequestNextEpisode: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)?
    let onRequestResolvedNextEpisode: ((ResolvedNextEpisodeTarget) -> Void)?
    let onPlaybackStartupFailure: ((PlaybackFailureReport) -> Void)?
    let localNextEpisodeFallback: PlaybackEpisodeCoordinate?

    init(
        url: URL,
        preset: PlayerPreset? = nil,
        headers: [String: String] = [:],
        subtitles: [String] = [],
        subtitleNames: [String]? = nil,
        subtitleHeadersByURL: [String: [String: String]]? = nil,
        mediaSelectionIntent: PlaybackMediaSelectionIntent? = nil,
        mediaInfo: MediaInfo? = nil,
        kidsPolicyDetails: KidsPolicyDetails? = nil,
        mediaYear: Int? = nil,
        imdbID: String? = nil,
        episodePlaybackContext: EpisodePlaybackContext? = nil,
        launchContext: PlaybackLaunchContext? = nil,
        resumePosition: Double? = nil,
        title: String = "",
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        isAnime: Bool = false,
        isAnimation: Bool = false,
        originalTMDBSeasonNumber: Int? = nil,
        originalTMDBEpisodeNumber: Int? = nil,
        servicesOriginalTitle: String? = nil,
        servicesOriginalAudioLanguage: String? = nil,
        onRequestNextEpisode: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)? = nil,
        onRequestResolvedNextEpisode: ((ResolvedNextEpisodeTarget) -> Void)? = nil,
        onPlaybackStartupFailure: ((PlaybackFailureReport) -> Void)? = nil,
        localNextEpisodeFallback: PlaybackEpisodeCoordinate? = nil
    ) {
        self.url = url
        self.preset = preset
            ?? PlayerPreset.presets.first
            ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: [])
        self.headers = Self.sanitizedHeaders(headers)
        self.subtitles = subtitles
        self.subtitleNames = subtitleNames
        self.subtitleHeadersByURL = subtitleHeadersByURL
        self.mediaSelectionIntent = mediaSelectionIntent
            ?? PlaybackMediaSelectionIntent.currentDefaults(isAnime: isAnime)
        self.mediaInfo = mediaInfo
        self.kidsPolicyDetails = kidsPolicyDetails
        self.mediaYear = mediaYear.flatMap { (1800...3000).contains($0) ? $0 : nil }
        self.imdbID = imdbID
        self.episodePlaybackContext = episodePlaybackContext
        self.launchContext = launchContext
        if let resumePosition, resumePosition.isFinite, resumePosition > 0 {
            self.resumePosition = resumePosition
        } else {
            self.resumePosition = nil
        }
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.isAnime = isAnime
        self.isAnimation = isAnimation
        self.originalTMDBSeasonNumber = originalTMDBSeasonNumber
        self.originalTMDBEpisodeNumber = originalTMDBEpisodeNumber
        self.servicesOriginalTitle = servicesOriginalTitle
        self.servicesOriginalAudioLanguage = servicesOriginalAudioLanguage
        self.onRequestNextEpisode = onRequestNextEpisode
        self.onRequestResolvedNextEpisode = onRequestResolvedNextEpisode
        self.onPlaybackStartupFailure = onPlaybackStartupFailure
        self.localNextEpisodeFallback = localNextEpisodeFallback
    }

    private static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty,
                  key.rangeOfCharacter(from: .newlines) == nil,
                  value.rangeOfCharacter(from: .newlines) == nil else { return }
            result[key] = value
        }
    }

    func replacingMediaSelectionIntent(_ mediaSelectionIntent: PlaybackMediaSelectionIntent) -> PlaybackRequest {
        PlaybackRequest(
            url: url,
            preset: preset,
            headers: headers,
            subtitles: subtitles,
            subtitleNames: subtitleNames,
            subtitleHeadersByURL: subtitleHeadersByURL,
            mediaSelectionIntent: mediaSelectionIntent,
            mediaInfo: mediaInfo,
            kidsPolicyDetails: kidsPolicyDetails,
            mediaYear: mediaYear,
            imdbID: imdbID,
            episodePlaybackContext: episodePlaybackContext,
            launchContext: launchContext,
            resumePosition: resumePosition,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            isAnime: isAnime,
            isAnimation: isAnimation,
            originalTMDBSeasonNumber: originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: originalTMDBEpisodeNumber,
            servicesOriginalTitle: servicesOriginalTitle,
            servicesOriginalAudioLanguage: servicesOriginalAudioLanguage,
            onRequestNextEpisode: onRequestNextEpisode,
            onRequestResolvedNextEpisode: onRequestResolvedNextEpisode,
            onPlaybackStartupFailure: onPlaybackStartupFailure,
            localNextEpisodeFallback: localNextEpisodeFallback
        )
    }

    func replacingResolvedTransport(
        url: URL,
        headers: [String: String],
        subtitles: [String],
        subtitleNames: [String]?,
        subtitleHeadersByURL: [String: [String: String]]?,
        launchContext: PlaybackLaunchContext,
        resumePosition: Double?
    ) -> PlaybackRequest {
        PlaybackRequest(
            url: url,
            preset: preset,
            headers: headers,
            subtitles: subtitles,
            subtitleNames: subtitleNames,
            subtitleHeadersByURL: subtitleHeadersByURL,
            mediaSelectionIntent: mediaSelectionIntent,
            mediaInfo: mediaInfo,
            kidsPolicyDetails: kidsPolicyDetails,
            mediaYear: mediaYear,
            imdbID: imdbID,
            episodePlaybackContext: episodePlaybackContext,
            launchContext: launchContext,
            resumePosition: resumePosition,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            isAnime: isAnime,
            isAnimation: isAnimation,
            originalTMDBSeasonNumber: originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: originalTMDBEpisodeNumber,
            servicesOriginalTitle: servicesOriginalTitle,
            servicesOriginalAudioLanguage: servicesOriginalAudioLanguage,
            onRequestNextEpisode: onRequestNextEpisode,
            onRequestResolvedNextEpisode: onRequestResolvedNextEpisode,
            onPlaybackStartupFailure: onPlaybackStartupFailure,
            localNextEpisodeFallback: localNextEpisodeFallback
        )
    }
}
