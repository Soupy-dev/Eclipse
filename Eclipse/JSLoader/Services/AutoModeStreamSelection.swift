// Shared, pure stream-quality scoring used by Auto Mode selection.

import Foundation

enum AutoModeStreamSelection {
    private static let resolutionMatchers: [(height: Int, regex: NSRegularExpression)] = [
        (2160, try! NSRegularExpression(
            pattern: #"(?<![a-wyz0-9])(?:2160(?:p|i)?|4k|uhd)(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#,
            options: [.caseInsensitive]
        )),
        (1440, try! NSRegularExpression(
            pattern: #"(?<![a-wyz0-9])1440(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#,
            options: [.caseInsensitive]
        )),
        (1080, try! NSRegularExpression(
            pattern: #"(?<![a-wyz0-9])1080(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#,
            options: [.caseInsensitive]
        )),
        (720, try! NSRegularExpression(
            pattern: #"(?<![a-wyz0-9])720(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#,
            options: [.caseInsensitive]
        )),
        (480, try! NSRegularExpression(
            pattern: #"(?<![a-wyz0-9])480(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#,
            options: [.caseInsensitive]
        )),
        (360, try! NSRegularExpression(
            pattern: #"(?<![a-wyz0-9])360(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#,
            options: [.caseInsensitive]
        ))
    ]
    private static let fileSizeMatcher = try! NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*(gb|gib|mb|mib)"#,
        options: [.caseInsensitive]
    )

    struct StreamQualityInfo {
        let resolutionHeight: Int?
        let sizeMB: Double?
        let sourceScore: Double
        let featureScore: Double
    }

    static func streamQualityInfo(from label: String) -> StreamQualityInfo {
        let lower = label.lowercased()
        let resolutionHeight = detectedResolutionHeight(in: label)

        let sizeMB = largestFileSizeMB(in: label)

        let sourceScore: Double
        if lower.contains("remux") {
            sourceScore = 9
        } else if lower.contains("bluray") || lower.contains("blu-ray") || lower.contains("bdrip") || lower.contains("brrip") {
            sourceScore = 8
        } else if lower.contains("web-dl") || lower.contains("webdl") {
            sourceScore = 7
        } else if lower.contains("webrip") || lower.contains(" web ") || lower.contains(".web.") {
            sourceScore = 6
        } else if lower.contains("hdtv") || lower.contains("hdrip") {
            sourceScore = 5
        } else if lower.contains("dvdrip") || lower.contains("dvd") {
            sourceScore = 4
        } else if lower.contains("cam") || lower.contains("hdcam") || lower.contains(" telesync") || lower.contains(" ts ") {
            sourceScore = 1
        } else {
            sourceScore = 3
        }

        var featureScore = 0.0
        if lower.contains("cached") || lower.contains("cache") { featureScore += 0.4 }
        if lower.contains("hdr") || lower.contains("dolby vision") || lower.contains(" dv ") { featureScore += 0.2 }
        if lower.contains("hevc") || lower.contains("x265") || lower.contains("h265") || lower.contains("h.265") { featureScore += 0.1 }

        return StreamQualityInfo(
            resolutionHeight: resolutionHeight,
            sizeMB: sizeMB,
            sourceScore: sourceScore,
            featureScore: featureScore
        )
    }

    private static func detectedResolutionHeight(in label: String) -> Int? {
        let range = NSRange(label.startIndex..<label.endIndex, in: label)
        return resolutionMatchers.first { matcher in
            matcher.regex.firstMatch(in: label, range: range) != nil
        }?.height
    }

    static func largestFileSizeMB(in label: String) -> Double? {
        let nsRange = NSRange(label.startIndex..<label.endIndex, in: label)
        let matches = fileSizeMatcher.matches(in: label, range: nsRange)
        let sizes = matches.compactMap { match -> Double? in
            guard let valueRange = Range(match.range(at: 1), in: label),
                  let unitRange = Range(match.range(at: 2), in: label),
                  let value = Double(String(label[valueRange])) else {
                return nil
            }
            let unit = label[unitRange].lowercased()
            return unit.hasPrefix("g") ? value * 1024 : value
        }
        return sizes.max()
    }

    static func streamPreferenceScore(label: String, preference: AutoModeQualityPreference, index: Int) -> Double {
        streamPreferenceScore(
            info: streamQualityInfo(from: label),
            preference: preference,
            index: index
        )
    }

    static func streamPreferenceScore(info: StreamQualityInfo, preference: AutoModeQualityPreference, index: Int) -> Double {
        let earlierTieBreak = -Double(index) * 0.001
        let sizeScore = min(info.sizeMB ?? 0, 80_000) / 10_000
        let qualityBonus = info.sourceScore + info.featureScore + sizeScore + earlierTieBreak

        switch preference {
        case .manual:
            return qualityBonus
        case .auto, .highest:
            return Double(info.resolutionHeight ?? 0) * 10 + qualityBonus
        case .lowest:
            let resolution = info.resolutionHeight ?? 10_000
            return -Double(resolution) + (qualityBonus * 0.1)
        case .quality2160, .quality1080, .quality720, .quality480:
            guard let target = preference.targetResolutionHeight else {
                return qualityBonus
            }
            guard let resolution = info.resolutionHeight else {
                return -10_000 + qualityBonus
            }
            if resolution == target {
                return 20_000 + qualityBonus
            }
            if resolution < target {
                return 10_000 - Double(target - resolution) + qualityBonus
            }
            return 8_000 - Double(resolution - target) + qualityBonus
        }
    }

    static func streamLabelHasDetectedQuality(_ label: String) -> Bool {
        streamQualityInfo(from: label).resolutionHeight != nil
    }

    // MARK: - Stremio

    /// Mirrors `ServicesResultsSheet.bestStremioStream`.
    static func bestStremioStream(
        from streams: [StremioStream],
        sourceId: String? = nil,
        streamsAreFiltered: Bool = false
    ) -> StremioStream? {
        let preference = AutoModeQualityPreference.current
        guard preference.usesAutomaticSelection else {
            return nil
        }

        let visibleStreams: [StremioStream]
        if streamsAreFiltered {
            visibleStreams = streams
        } else if let configuration = StreamLanguageFilter.configuration(sourceId: sourceId) {
            visibleStreams = streams.filter {
                !StreamLanguageFilter.shouldHide(stremio: $0, configuration: configuration)
            }
        } else {
            visibleStreams = streams
        }

        let rankedStreams = visibleStreams.enumerated().map { index, stream in
            let label = smartPlayerMetadata(for: stream)
            let info = streamQualityInfo(from: label)
            return (
                index: index,
                stream: stream,
                hasDetectedQuality: info.resolutionHeight != nil,
                score: streamPreferenceScore(info: info, preference: preference, index: index)
                    + legacyStremioStreamScore(stream)
            )
        }
        guard rankedStreams.contains(where: { $0.hasDetectedQuality }) else {
            return nil
        }
        return rankedStreams.max(by: { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.index > rhs.index
            }
            return lhs.score < rhs.score
        })?.stream
    }

    static func legacyStremioStreamScore(_ stream: StremioStream) -> Double {
        let shortDescription = stream.description.map { String($0.prefix(120)) }
        let label = [stream.displayName, shortDescription, stream.behaviorHints?.filename]
            .compactMap { $0 }
            .joined(separator: " ")
        let lower = label.lowercased()

        // Stremio addon lookups are already ID-based, so Auto Mode should rank
        // streams by quality/usefulness instead of title similarity.
        var score = 1.0

        if lower.contains("cached") || lower.contains("cache") {
            score += 0.12
        }

        if lower.contains("2160") || lower.contains("4k") {
            score += 0.08
        } else if lower.contains("1080") {
            score += 0.06
        } else if lower.contains("720") {
            score += 0.04
        }

        if lower.contains("hdr") {
            score += 0.02
        }

        if lower.contains("remux") {
            score += 0.02
        }

        if stream.isDirectHTTP {
            score += 0.01
        }

        return score
    }

    static func smartPlayerMetadata(for stream: StremioStream) -> String {
        [
            stream.name,
            stream.title,
            stream.description,
            stream.behaviorHints?.filename,
            stream.formattedVideoSize,
            stremioStreamLabel(for: stream)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    static func stremioStreamLabel(for stream: StremioStream) -> String {
        var parts: [String] = []
        if let name = stream.name, !name.isEmpty { parts.append(name) }

        // Parse quality info from title lines (Torrentio/Comet format)
        if let title = stream.title, !title.isEmpty {
            let lines = title.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let qualityTags = extractQualityTags(from: lines)
            if !qualityTags.isEmpty {
                parts.append(qualityTags)
            } else if let firstLine = lines.first, firstLine != stream.name {
                parts.append(firstLine)
            }
        }
        if let languageLabel = stremioLanguageLabel(for: stream),
           !stremioLanguageLabel(languageLabel, isAlreadyIncludedIn: parts) {
            parts.append(languageLabel)
        }
        let hasDisplayedSize = parts.joined(separator: " ").range(
            of: #"\d+(?:\.\d+)?\s*(?:KB|MB|GB|TB)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if !hasDisplayedSize, let size = stream.formattedVideoSize {
            parts.append(size)
        }

        return parts.isEmpty ? "Stream" : parts.joined(separator: " · ")
    }

    static func stremioLanguageLabel(for stream: StremioStream) -> String? {
        let metadata = [
            stream.name,
            stream.title,
            stream.description,
            stream.behaviorHints?.filename
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        var languages = stream.languageHints
            .flatMap(splitStremioLanguageHint)
            .compactMap(normalizedStremioLanguageName)
        languages.append(contentsOf: detectedStremioLanguageNames(in: metadata.joined(separator: " ")))

        var seen = Set<String>()
        let uniqueLanguages = languages.filter { seen.insert($0).inserted }
        if uniqueLanguages.contains("Multi Audio") || uniqueLanguages.count > 3 {
            return "Multi Audio"
        }

        let namedLanguages = uniqueLanguages.filter { $0 != "Dual Audio" }
        if !namedLanguages.isEmpty {
            return namedLanguages.joined(separator: "/")
        }

        let metadataText = metadata.joined(separator: " ")
        if containsStremioLanguageMarker("multi audio", in: metadataText)
            || containsStremioLanguageMarker("multi-language", in: metadataText)
            || containsStremioLanguageMarker("multilang", in: metadataText) {
            return "Multi Audio"
        }
        if uniqueLanguages.contains("Dual Audio")
            || containsStremioLanguageMarker("dual audio", in: metadataText) {
            return "Dual Audio"
        }
        return nil
    }

    static func splitStremioLanguageHint(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",/|;+"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func normalizedStremioLanguageName(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dual", "dual audio", "dual-audio": return "Dual Audio"
        case "multi", "multi audio", "multi-audio", "multilang", "multi-language": return "Multi Audio"
        case "eng", "en", "english": return "English"
        case "jpn", "ja", "jp", "japanese": return "Japanese"
        case "hin", "hi", "hindi": return "Hindi"
        case "kor", "ko", "korean": return "Korean"
        case "chi", "zho", "zh", "chinese", "mandarin", "cantonese": return "Chinese"
        case "spa", "es", "esp", "spanish": return "Spanish"
        case "lat", "latin", "latino": return "Latino"
        case "fre", "fra", "fr", "french": return "French"
        case "ger", "deu", "de", "german": return "German"
        case "ita", "it", "italian": return "Italian"
        case "por", "pt", "portuguese": return "Portuguese"
        case "rus", "ru", "russian": return "Russian"
        case "ara", "ar", "arabic": return "Arabic"
        case "tam", "ta", "tamil": return "Tamil"
        case "tel", "te", "telugu": return "Telugu"
        case "ben", "bn", "bengali": return "Bengali"
        case "mal", "ml", "malayalam": return "Malayalam"
        case "kan", "kn", "kannada": return "Kannada"
        case "mar", "mr", "marathi": return "Marathi"
        case "tur", "tr", "turkish": return "Turkish"
        case "pol", "pl", "polish": return "Polish"
        case "dut", "nld", "nl", "dutch": return "Dutch"
        case "ind", "id", "indonesian": return "Indonesian"
        case "tha", "th", "thai": return "Thai"
        case "vie", "vi", "vietnamese": return "Vietnamese"
        case "ukr", "uk", "ukrainian": return "Ukrainian"
        default: return nil
        }
    }

    static func detectedStremioLanguageNames(in value: String) -> [String] {
        let languages: [(name: String, markers: [String])] = [
            ("English", ["english", "eng"]),
            ("Japanese", ["japanese", "jpn"]),
            ("Hindi", ["hindi", "hin"]),
            ("Korean", ["korean", "kor"]),
            ("Chinese", ["chinese", "mandarin", "cantonese", "zho", "chi"]),
            ("Spanish", ["spanish", "spa"]),
            ("Latino", ["latino", "latin", "lat"]),
            ("French", ["french", "fra", "fre"]),
            ("German", ["german", "deu", "ger"]),
            ("Italian", ["italian", "ita"]),
            ("Portuguese", ["portuguese", "por"]),
            ("Russian", ["russian", "rus"]),
            ("Arabic", ["arabic", "ara"]),
            ("Tamil", ["tamil", "tam"]),
            ("Telugu", ["telugu", "tel"]),
            ("Bengali", ["bengali", "ben"]),
            ("Malayalam", ["malayalam", "mal"]),
            ("Kannada", ["kannada", "kan"]),
            ("Marathi", ["marathi", "mar"]),
            ("Turkish", ["turkish", "tur"]),
            ("Polish", ["polish", "pol"]),
            ("Dutch", ["dutch", "nld", "dut"]),
            ("Indonesian", ["indonesian", "ind"]),
            ("Thai", ["thai", "tha"]),
            ("Vietnamese", ["vietnamese", "vie"]),
            ("Ukrainian", ["ukrainian", "ukr"])
        ]

        return languages.compactMap { language in
            language.markers.contains { containsStremioLanguageMarker($0, in: value) }
                ? language.name
                : nil
        }
    }

    static func containsStremioLanguageMarker(_ marker: String, in value: String) -> Bool {
        let escapedMarker = NSRegularExpression.escapedPattern(for: marker)
        return value.range(
            of: "(?i)(^|[^a-z])\(escapedMarker)([^a-z]|$)",
            options: .regularExpression
        ) != nil
    }

    static func stremioLanguageLabel(_ languageLabel: String, isAlreadyIncludedIn parts: [String]) -> Bool {
        let displayedText = parts.joined(separator: " ")
        if displayedText.range(of: languageLabel, options: .caseInsensitive) != nil {
            return true
        }

        let displayedLanguages = Set(detectedStremioLanguageNames(in: displayedText))
        let expectedLanguages = languageLabel.components(separatedBy: "/")
        return !expectedLanguages.isEmpty && expectedLanguages.allSatisfy(displayedLanguages.contains)
    }

    static func extractQualityTags(from lines: [String]) -> String {
        let resolutionPatterns = ["4k", "2160p", "1080p", "720p", "480p", "360p"]
        let qualityPatterns = ["bluray", "blu-ray", "bdrip", "brrip", "dvdrip", "dvd", "webrip", "web-dl", "webdl", "web", "hdtv", "hdrip", "cam", "ts", "hdcam", "remux"]
        let codecPatterns = ["hevc", "h265", "h.265", "x265", "h264", "h.264", "x264", "av1", "vp9", "xvid"]
        let hdrPatterns = ["hdr10+", "hdr10", "hdr", "dolby vision", "dv", "sdr"]
        let audioPatterns = ["atmos", "truehd", "dts-hd", "dts", "dd5.1", "dd+", "aac", "5.1", "7.1"]

        var tags: [String] = []
        let allText = lines.joined(separator: " ").lowercased()

        // Resolution
        for pattern in resolutionPatterns {
            if allText.contains(pattern) {
                tags.append(pattern == "4k" ? "4K" : pattern.uppercased())
                break
            }
        }

        // Source quality
        for pattern in qualityPatterns {
            if allText.contains(pattern) {
                let display: String
                switch pattern {
                case "bluray", "blu-ray": display = "BluRay"
                case "bdrip": display = "BDRip"
                case "brrip": display = "BRRip"
                case "dvdrip": display = "DVDRip"
                case "dvd": display = "DVD"
                case "webrip": display = "WEBRip"
                case "web-dl", "webdl": display = "WEB-DL"
                case "web": display = "WEB"
                case "hdtv": display = "HDTV"
                case "hdrip": display = "HDRip"
                case "cam": display = "CAM"
                case "ts": display = "TS"
                case "hdcam": display = "HDCAM"
                case "remux": display = "Remux"
                default: display = pattern.uppercased()
                }
                tags.append(display)
                break
            }
        }

        // Codec
        for pattern in codecPatterns {
            if allText.contains(pattern) {
                let display: String
                switch pattern {
                case "hevc", "h265", "h.265", "x265": display = "HEVC"
                case "h264", "h.264", "x264": display = "H.264"
                case "av1": display = "AV1"
                default: display = pattern.uppercased()
                }
                tags.append(display)
                break
            }
        }

        // HDR
        for pattern in hdrPatterns {
            if allText.contains(pattern) {
                let display: String
                switch pattern {
                case "hdr10+": display = "HDR10+"
                case "hdr10": display = "HDR10"
                case "hdr": display = "HDR"
                case "dolby vision", "dv": display = "DV"
                default: display = pattern.uppercased()
                }
                tags.append(display)
                break
            }
        }

        // Audio
        for pattern in audioPatterns {
            if allText.contains(pattern) {
                let display: String
                switch pattern {
                case "atmos": display = "Atmos"
                case "truehd": display = "TrueHD"
                case "dts-hd": display = "DTS-HD"
                case "dts": display = "DTS"
                case "dd5.1": display = "DD5.1"
                case "dd+": display = "DD+"
                default: display = pattern
                }
                tags.append(display)
                break
            }
        }

        // File size (look for patterns like "2.5 GB", "800 MB")
        let sizeRegex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?\s*(?:GB|MB|gb|mb))"#)
        if let match = sizeRegex?.firstMatch(in: lines.joined(separator: " "), range: NSRange(location: 0, length: lines.joined(separator: " ").utf16.count)) {
            if let range = Range(match.range(at: 1), in: lines.joined(separator: " ")) {
                tags.append(String(lines.joined(separator: " ")[range]))
            }
        }

        return tags.joined(separator: " · ")
    }
}

enum StreamLanguageFilter {
    static let storageKey = "servicesHiddenStreamLanguages"
    static let includedLanguagesKey = "servicesIncludedStreamLanguages"
    static let hideUnknownLanguageStreamsKey = "servicesHideStreamsWithoutLanguageData"
    static let hiddenStreamQualitiesKey = "servicesHiddenStreamQualities"
    static let hideUnknownQualityStreamsKey = "servicesHideStreamsWithoutDetectedQuality"
    static let extraRulesSourceIdsKey = "servicesExtraRulesSourceIds"
    static let supportedQualityHeights = [2160, 1440, 1080, 720, 480, 360]

    struct Matcher {
        let keys: Set<String>
        let markers: [String]
    }

    struct Configuration {
        let hidesStreamsWithoutLanguageData: Bool
        let includedLanguageMatchers: [Matcher]
        let hiddenLanguageMatchers: [Matcher]
        let hiddenQualityHeights: Set<Int>
        let hidesStreamsWithoutDetectedQuality: Bool

        var hasLanguageRules: Bool {
            hidesStreamsWithoutLanguageData
                || !includedLanguageMatchers.isEmpty
                || !hiddenLanguageMatchers.isEmpty
        }

        var hasQualityRules: Bool {
            hidesStreamsWithoutDetectedQuality || !hiddenQualityHeights.isEmpty
        }
    }

    static func hiddenLanguages(defaults: UserDefaults = .standard) -> [String] {
        sanitizedLanguageList(defaults.stringArray(forKey: storageKey) ?? [])
    }

    static func includedLanguages(defaults: UserDefaults = .standard) -> [String] {
        sanitizedLanguageList(defaults.stringArray(forKey: includedLanguagesKey) ?? [])
    }

    static func hidesStreamsWithoutLanguageData(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hideUnknownLanguageStreamsKey)
    }

    static func hiddenQualityHeights(defaults: UserDefaults = .standard) -> [Int] {
        sanitizedQualityHeights(defaults.array(forKey: hiddenStreamQualitiesKey)?.compactMap { value in
            if let intValue = value as? Int { return intValue }
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String { return Int(string) }
            return nil
        } ?? [])
    }

    static func hidesStreamsWithoutDetectedQuality(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hideUnknownQualityStreamsKey)
    }

    /// A missing value means rules apply to every Service and Stremio addon. An explicit empty
    /// array means the user disabled the rules for every connected source.
    static func extraRulesSourceIds(defaults: UserDefaults = .standard) -> [String]? {
        guard defaults.object(forKey: extraRulesSourceIdsKey) != nil else { return nil }
        return sanitizedExtraRulesSourceIds(defaults.stringArray(forKey: extraRulesSourceIdsKey) ?? [])
    }

    static func extraRulesApply(to sourceId: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let sourceId else { return true }
        guard let selectedSourceIds = extraRulesSourceIds(defaults: defaults) else { return true }
        return selectedSourceIds.contains(sourceId)
    }

    /// Returns `nil` when this source has no active rules. Callers processing a
    /// stream list can snapshot this once and avoid UserDefaults, metadata, and
    /// regex work for every element in the common default configuration.
    static func configuration(
        sourceId: String? = nil,
        defaults: UserDefaults = .standard
    ) -> Configuration? {
        guard extraRulesApply(to: sourceId, defaults: defaults) else { return nil }

        let included = includedLanguages(defaults: defaults)
        let hidden = hiddenLanguages(defaults: defaults)
        let hiddenQualities = Set(hiddenQualityHeights(defaults: defaults))
        let hideUnknownLanguage = hidesStreamsWithoutLanguageData(defaults: defaults)
        let hideUnknownQuality = hidesStreamsWithoutDetectedQuality(defaults: defaults)

        guard hideUnknownLanguage
                || hideUnknownQuality
                || !included.isEmpty
                || !hidden.isEmpty
                || !hiddenQualities.isEmpty else {
            return nil
        }

        return Configuration(
            hidesStreamsWithoutLanguageData: hideUnknownLanguage,
            includedLanguageMatchers: included.map(matcher(for:)),
            hiddenLanguageMatchers: hidden.map(matcher(for:)),
            hiddenQualityHeights: hiddenQualities,
            hidesStreamsWithoutDetectedQuality: hideUnknownQuality
        )
    }

    static func setHiddenLanguages(_ values: [String], defaults: UserDefaults = .standard) {
        let sanitized = sanitizedLanguageList(values)
        if sanitized.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(sanitized, forKey: storageKey)
        }
    }

    static func setIncludedLanguages(_ values: [String], defaults: UserDefaults = .standard) {
        let sanitized = sanitizedLanguageList(values)
        if sanitized.isEmpty {
            defaults.removeObject(forKey: includedLanguagesKey)
        } else {
            defaults.set(sanitized, forKey: includedLanguagesKey)
        }
    }

    static func setHidesStreamsWithoutLanguageData(_ enabled: Bool, defaults: UserDefaults = .standard) {
        if enabled {
            defaults.set(true, forKey: hideUnknownLanguageStreamsKey)
        } else {
            defaults.removeObject(forKey: hideUnknownLanguageStreamsKey)
        }
    }

    static func setHiddenQualityHeights(_ values: [Int], defaults: UserDefaults = .standard) {
        let sanitized = sanitizedQualityHeights(values)
        if sanitized.isEmpty {
            defaults.removeObject(forKey: hiddenStreamQualitiesKey)
        } else {
            defaults.set(sanitized, forKey: hiddenStreamQualitiesKey)
        }
    }

    static func setHidesStreamsWithoutDetectedQuality(_ enabled: Bool, defaults: UserDefaults = .standard) {
        if enabled {
            defaults.set(true, forKey: hideUnknownQualityStreamsKey)
        } else {
            defaults.removeObject(forKey: hideUnknownQualityStreamsKey)
        }
    }

    static func setExtraRulesSourceIds(_ values: [String]?, defaults: UserDefaults = .standard) {
        guard let values else {
            defaults.removeObject(forKey: extraRulesSourceIdsKey)
            return
        }
        defaults.set(sanitizedExtraRulesSourceIds(values), forKey: extraRulesSourceIdsKey)
    }

    static func languages(from editorText: String) -> [String] {
        sanitizedLanguageList(editorText.components(separatedBy: CharacterSet(charactersIn: ",;\n")))
    }

    static func editorText(from values: [String]) -> String {
        sanitizedLanguageList(values).joined(separator: ", ")
    }

    static func sanitizedLanguageList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        let sanitized = values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let language = String(trimmed.prefix(40))
            let dedupeKey = languageKeys(in: language).first ?? normalizedKey(language)
            guard seen.insert(dedupeKey).inserted else { return nil }
            return language
        }
        return Array(sanitized.prefix(40))
    }

    static func sanitizedQualityHeights(_ values: [Int]) -> [Int] {
        let supported = Set(supportedQualityHeights)
        return Array(Set(values.filter { supported.contains($0) })).sorted(by: >)
    }

    static func sanitizedExtraRulesSourceIds(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("service:") || trimmed.hasPrefix("stremio:") else { return nil }
            let sourceId = String(trimmed.prefix(160))
            guard seen.insert(sourceId).inserted else { return nil }
            return sourceId
        }
        .prefix(200)
        .map { $0 }
    }

    static func qualityLabel(for height: Int) -> String {
        height == 2160 ? "4K / 2160p" : "\(height)p"
    }

    static func shouldHide(
        languageHints: [String],
        metadata: [String],
        sourceId: String? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let configuration = configuration(sourceId: sourceId, defaults: defaults) else {
            return false
        }
        return shouldHide(
            languageHints: languageHints,
            metadata: metadata,
            configuration: configuration
        )
    }

    static func shouldHide(
        languageHints: [String],
        metadata: [String],
        configuration: Configuration
    ) -> Bool {
        if configuration.hasQualityRules {
            let metadataText = metadataText(from: metadata)
            let detectedQuality = AutoModeStreamSelection.streamQualityInfo(from: metadataText).resolutionHeight
            if configuration.hidesStreamsWithoutDetectedQuality, detectedQuality == nil {
                return true
            }
            if let detectedQuality,
               configuration.hiddenQualityHeights.contains(detectedQuality) {
                return true
            }
        }

        guard configuration.hasLanguageRules else { return false }
        return shouldHideForLanguage(
            languageHints: languageHints,
            metadata: metadata,
            configuration: configuration
        )
    }

    private static func shouldHideForLanguage(
        languageHints: [String],
        metadata: [String],
        configuration: Configuration
    ) -> Bool {
        if configuration.hidesStreamsWithoutLanguageData,
           !hasLanguageData(languageHints: languageHints, metadata: metadata) {
            return true
        }

        guard !configuration.includedLanguageMatchers.isEmpty
                || !configuration.hiddenLanguageMatchers.isEmpty else {
            return false
        }

        let hintKeys = Set(languageHints.flatMap { languageKeys(in: $0) })
        let metadataText = metadataText(from: metadata)
        let detectedMetadataKeys = Set(AutoModeStreamSelection.detectedStremioLanguageNames(in: metadataText).flatMap { languageKeys(in: $0) })

        if !configuration.includedLanguageMatchers.isEmpty {
            guard matchesAnyLanguage(
                configuration.includedLanguageMatchers,
                hintKeys: hintKeys,
                detectedMetadataKeys: detectedMetadataKeys,
                metadataText: metadataText
            ) else {
                return true
            }
        }

        if matchesAnyLanguage(
            configuration.hiddenLanguageMatchers,
            hintKeys: hintKeys,
            detectedMetadataKeys: detectedMetadataKeys,
            metadataText: metadataText
        ) {
            return true
        }

        return false
    }

    private static func matchesAnyLanguage(
        _ matchers: [Matcher],
        hintKeys: Set<String>,
        detectedMetadataKeys: Set<String>,
        metadataText: String
    ) -> Bool {
        guard !matchers.isEmpty else { return false }

        if !hintKeys.isEmpty,
           matchers.contains(where: { !$0.keys.isDisjoint(with: hintKeys) }) {
            return true
        }
        if !detectedMetadataKeys.isEmpty,
           matchers.contains(where: { !$0.keys.isDisjoint(with: detectedMetadataKeys) }) {
            return true
        }
        guard !metadataText.isEmpty else { return false }

        return matchers.contains { matcher in
            matcher.markers.contains { marker in
                AutoModeStreamSelection.containsStremioLanguageMarker(marker, in: metadataText)
            }
        }
    }

    static func hasLanguageData(languageHints: [String], metadata: [String]) -> Bool {
        let hintValues = languageHints
            .flatMap(AutoModeStreamSelection.splitStremioLanguageHint)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if hintValues.contains(where: isMeaningfulLanguageHint) {
            return true
        }

        let metadataText = metadataText(from: metadata)
        guard !metadataText.isEmpty else { return false }
        if !AutoModeStreamSelection.detectedStremioLanguageNames(in: metadataText).isEmpty {
            return true
        }

        return AutoModeStreamSelection.containsStremioLanguageMarker("multi audio", in: metadataText)
            || AutoModeStreamSelection.containsStremioLanguageMarker("multi-language", in: metadataText)
            || AutoModeStreamSelection.containsStremioLanguageMarker("multilang", in: metadataText)
            || AutoModeStreamSelection.containsStremioLanguageMarker("dual audio", in: metadataText)
    }

    static func shouldHide(
        stremio stream: StremioStream,
        sourceId: String? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        shouldHide(
            languageHints: stream.languageHints,
            metadata: [
                stream.name,
                stream.title,
                stream.description,
                stream.behaviorHints?.filename,
                AutoModeStreamSelection.stremioLanguageLabel(for: stream),
                AutoModeStreamSelection.smartPlayerMetadata(for: stream)
            ].compactMap { $0 },
            sourceId: sourceId,
            defaults: defaults
        )
    }

    static func shouldHide(
        stremio stream: StremioStream,
        configuration: Configuration
    ) -> Bool {
        shouldHide(
            languageHints: stream.languageHints,
            metadata: [
                stream.name,
                stream.title,
                stream.description,
                stream.behaviorHints?.filename,
                AutoModeStreamSelection.stremioLanguageLabel(for: stream),
                AutoModeStreamSelection.smartPlayerMetadata(for: stream)
            ].compactMap { $0 },
            configuration: configuration
        )
    }

    private static func matcher(for value: String) -> Matcher {
        let keys = Set(languageKeys(in: value))
        let markers = markerCandidates(for: value, keys: keys)
        return Matcher(keys: keys, markers: markers)
    }

    private static func languageKeys(in value: String) -> [String] {
        var keys: [String] = []
        let candidates = [value] + AutoModeStreamSelection.splitStremioLanguageHint(value)
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let normalized = AutoModeStreamSelection.normalizedStremioLanguageName(trimmed) {
                keys.append(normalizedKey(normalized))
            }
            if let prefix = trimmed.split(separator: "-").first,
               prefix.count < trimmed.count,
               let normalized = AutoModeStreamSelection.normalizedStremioLanguageName(String(prefix)) {
                keys.append(normalizedKey(normalized))
            }
            keys.append(normalizedKey(trimmed))
        }
        var seen = Set<String>()
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func isMeaningfulLanguageHint(_ value: String) -> Bool {
        let key = normalizedKey(value)
        guard !key.isEmpty else { return false }
        let placeholders: Set<String> = [
            "unknown",
            "unknown language",
            "unk",
            "und",
            "undefined",
            "undetermined",
            "none",
            "null",
            "n a",
            "na",
            "not available",
            "no language"
        ]
        return !placeholders.contains(key)
    }

    private static func metadataText(from metadata: [String]) -> String {
        metadata
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func markerCandidates(for value: String, keys: Set<String>) -> [String] {
        var markers = AutoModeStreamSelection.splitStremioLanguageHint(value)
        markers.append(value)
        if keys.contains("multi audio") {
            markers.append(contentsOf: ["multi audio", "multi-audio", "multilang", "multi-language"])
        }
        if keys.contains("dual audio") {
            markers.append(contentsOf: ["dual audio", "dual-audio"])
        }
        var seen = Set<String>()
        return markers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert(normalizedKey($0)).inserted }
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
