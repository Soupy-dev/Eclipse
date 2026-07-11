import Foundation

/// Renderer-neutral intent for the selection that should be active when playback begins.
///
/// MPV track identifiers and AVFoundation media-selection options are renderer-specific and
/// cannot be mapped reliably. Language plus the explicit subtitle-enabled state are the common
/// public contract, so a fallback can preserve the user's intent instead of re-reading settings
/// that may have changed after the request was created.
struct PlaybackMediaSelectionIntent: Equatable {
    let preferredAudioLanguage: String?
    let preferredSubtitleLanguage: String?
    let subtitlesEnabled: Bool

    static func currentDefaults(isAnime: Bool, defaults: UserDefaults = .standard) -> Self {
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

/// Pure language matching used by AVFoundation selection and external-subtitle menus.
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
                // Short language codes must match a complete token. Substring matching would,
                // for example, treat `es` as Spanish when it merely appears inside "Japanese".
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

/// A renderer-neutral launch description. Keeping headers, subtitles, resume position, and media
/// identity together prevents fallback from reconstructing a subtly different playback request.
struct PlaybackRequest {
    let url: URL
    let preset: PlayerPreset
    let headers: [String: String]
    let subtitles: [String]
    let subtitleNames: [String]?
    let subtitleHeadersByURL: [String: [String: String]]?
    let mediaSelectionIntent: PlaybackMediaSelectionIntent
    let mediaInfo: MediaInfo?
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
    let onRequestNextEpisode: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)?

    init(
        url: URL,
        preset: PlayerPreset? = nil,
        headers: [String: String] = [:],
        subtitles: [String] = [],
        subtitleNames: [String]? = nil,
        subtitleHeadersByURL: [String: [String: String]]? = nil,
        mediaSelectionIntent: PlaybackMediaSelectionIntent? = nil,
        mediaInfo: MediaInfo? = nil,
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
        onRequestNextEpisode: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)? = nil
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
        self.onRequestNextEpisode = onRequestNextEpisode
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
}
