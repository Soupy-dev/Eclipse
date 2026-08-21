import Foundation

enum BoundedProgressiveFanout {
    private struct Completion<Input: Sendable, Output: Sendable>: Sendable {
        let input: Input
        let output: Output
    }

    private enum BatchedEvent<Input: Sendable, Output: Sendable>: Sendable {
        case completion(Completion<Input, Output>)
        case flush
    }

    @MainActor
    static func run<Input: Sendable, Output: Sendable>(
        inputs: [Input],
        maxConcurrent: Int,
        operation: @escaping @Sendable (Input) async -> Output,
        isCurrent: () -> Bool,
        onResult: (Input, Output) -> Void
    ) async {
        guard !inputs.isEmpty else { return }
        guard !Task.isCancelled, isCurrent() else { return }
        let limit = min(max(maxConcurrent, 1), inputs.count)
        await withTaskGroup(of: Completion<Input, Output>.self) { group in
            var nextIndex = 0

            func admit(_ input: Input) {
                group.addTask {
                    Completion(input: input, output: await operation(input))
                }
            }

            for input in inputs.prefix(limit) {
                nextIndex += 1
                admit(input)
            }

            for await completion in group {
                guard !Task.isCancelled, isCurrent() else {
                    group.cancelAll()
                    return
                }
                onResult(completion.input, completion.output)
                guard !Task.isCancelled, isCurrent() else {
                    group.cancelAll()
                    return
                }
                if nextIndex < inputs.count {
                    let next = inputs[nextIndex]
                    nextIndex += 1
                    admit(next)
                }
            }
        }
    }

    @MainActor
    static func runBatched<Input: Sendable, Output: Sendable>(
        inputs: [Input],
        maxConcurrent: Int,
        publicationIntervalNanoseconds: UInt64,
        operation: @escaping @Sendable (Input) async -> Output,
        isCurrent: () -> Bool,
        onBatch: ([(input: Input, output: Output)]) -> Void
    ) async {
        guard !inputs.isEmpty else { return }
        guard !Task.isCancelled, isCurrent() else { return }
        let limit = min(max(maxConcurrent, 1), inputs.count)
        let publicationInterval = max(publicationIntervalNanoseconds, 1)

        await withTaskGroup(of: BatchedEvent<Input, Output>.self) { group in
            var nextIndex = 0
            var pending: [(input: Input, output: Output)] = []
            var flushScheduled = false

            func admit(_ input: Input) {
                group.addTask {
                    .completion(Completion(input: input, output: await operation(input)))
                }
            }

            func scheduleFlush() {
                guard !flushScheduled else { return }
                flushScheduled = true
                group.addTask {
                    try? await Task.sleep(nanoseconds: publicationInterval)
                    return .flush
                }
            }

            func publishPending() {
                guard !pending.isEmpty else { return }
                let batch = pending
                pending.removeAll(keepingCapacity: true)
                onBatch(batch)
            }

            for input in inputs.prefix(limit) {
                nextIndex += 1
                admit(input)
            }

            for await event in group {
                guard !Task.isCancelled, isCurrent() else {
                    group.cancelAll()
                    return
                }

                switch event {
                case .completion(let completion):
                    pending.append((completion.input, completion.output))
                    scheduleFlush()
                    if nextIndex < inputs.count {
                        let next = inputs[nextIndex]
                        nextIndex += 1
                        admit(next)
                    }

                case .flush:
                    flushScheduled = false
                    publishPending()
                    guard !Task.isCancelled, isCurrent() else {
                        group.cancelAll()
                        return
                    }
                }
            }

            publishPending()
        }
    }
}

enum OrderedSourceAttemptRunner {
    enum Outcome: Equatable {
        case accepted
        case exhausted
        case invalidated
    }

    @MainActor
    static func run<Input>(
        inputs: [Input],
        isCurrent: () -> Bool,
        attempt: (Input) async -> Bool
    ) async -> Outcome {
        for input in inputs {
            guard !Task.isCancelled, isCurrent() else { return .invalidated }
            let accepted = await attempt(input)
            guard !Task.isCancelled, isCurrent() else { return .invalidated }
            if accepted { return .accepted }
        }
        guard !Task.isCancelled, isCurrent() else { return .invalidated }
        return .exhausted
    }
}

@MainActor
enum OrderedSourceResolutionRunner {
    enum Outcome: Equatable {
        case accepted
        case exhausted
        case invalidated
    }

    static func run<Input, Output>(
        inputs: [Input],
        isCurrent: () -> Bool,
        resolve: (Input) async -> Output?,
        onAccepted: (Input, Output) -> Void,
        discardStale: (Output) -> Void,
        onMiss: (Input) -> Void = { _ in }
    ) async -> Outcome {
        for input in inputs {
            guard !Task.isCancelled, isCurrent() else { return .invalidated }
            let output = await resolve(input)
            guard !Task.isCancelled, isCurrent() else {
                if let output {
                    discardStale(output)
                }
                return .invalidated
            }
            guard let output else {
                onMiss(input)
                continue
            }
            onAccepted(input, output)
            return .accepted
        }
        guard !Task.isCancelled, isCurrent() else { return .invalidated }
        return .exhausted
    }
}

enum AutoModeStreamSelection {
    private static let maxLanguageHintCharacters = 512
    private static let maxLanguageSearchCharacters = 8_192

    fileprivate struct LanguageSearchText {
        let value: String
        let shortCodeTokens: Set<String>
    }

    private static let stremioLanguageMarkers: [(name: String, markers: Set<String>)] = [
        ("English", ["english", "eng", "en"]),
        ("Japanese", ["japanese", "jpn", "ja", "jp"]),
        ("Hindi", ["hindi", "hin", "hi"]),
        ("Korean", ["korean", "kor", "ko"]),
        ("Chinese", ["chinese", "mandarin", "cantonese", "zho", "chi", "zh"]),
        ("Spanish", ["spanish", "spa", "es"]),
        ("Bulgarian", ["bulgarian", "bul", "bg"]),
        ("Latino", ["latino", "latin", "lat", "latam", "latinoamericano"]),
        ("French", ["french", "fra", "fre", "fr"]),
        ("German", ["german", "deu", "ger", "de"]),
        ("Italian", ["italian", "ita", "it"]),
        ("Portuguese", ["portuguese", "por", "pt"]),
        ("Russian", ["russian", "rus", "ru"]),
        ("Arabic", ["arabic", "ara", "ar"]),
        ("Tamil", ["tamil", "tam", "ta"]),
        ("Telugu", ["telugu", "tel", "te"]),
        ("Bengali", ["bengali", "ben", "bn"]),
        ("Malayalam", ["malayalam", "mal", "ml"]),
        ("Kannada", ["kannada", "kan", "kn"]),
        ("Marathi", ["marathi", "mar", "mr"]),
        ("Turkish", ["turkish", "tur", "tr"]),
        ("Polish", ["polish", "pol", "pl"]),
        ("Dutch", ["dutch", "nld", "dut", "nl"]),
        ("Indonesian", ["indonesian", "ind", "id"]),
        ("Thai", ["thai", "tha", "th"]),
        ("Vietnamese", ["vietnamese", "vie", "vi"]),
        ("Ukrainian", ["ukrainian", "ukr", "uk"])
    ]

    private static let resolutionMatchers: [(height: Int, regex: NSRegularExpression)] = {
        let specifications: [(height: Int, pattern: String)] = [
            (2160, #"(?<![a-wyz0-9])(?:2160(?:p|i)?|4k|uhd)(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#),
            (1440, #"(?<![a-wyz0-9])1440(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#),
            (1080, #"(?<![a-wyz0-9])1080(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#),
            (720, #"(?<![a-wyz0-9])720(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#),
            (480, #"(?<![a-wyz0-9])480(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#),
            (360, #"(?<![a-wyz0-9])360(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#)
        ]
        return compiledResolutionMatchers(specifications)
    }()

    private static func compiledResolutionMatchers(
        _ specifications: [(height: Int, pattern: String)]
    ) -> [(height: Int, regex: NSRegularExpression)] {
        specifications.compactMap { specification in
            guard let regex = try? NSRegularExpression(
                pattern: specification.pattern,
                options: [.caseInsensitive]
            ) else {
                Logger.shared.log(
                    "StreamLanguageFilter: dropped an unusable \(specification.height)p matcher",
                    type: "Error"
                )
                return nil
            }
            return (specification.height, regex)
        }
    }

    private static let dimensionResolutionMatchers: [(height: Int, regex: NSRegularExpression)] = {
        let specifications: [(height: Int, pattern: String)] = [
            (2160, #"(?<![0-9])(?:3840|4096)\s*[x×]\s*2160(?![0-9])"#),
            (1440, #"(?<![0-9])2560\s*[x×]\s*1440(?![0-9])"#),
            (1080, #"(?<![0-9])1920\s*[x×]\s*1080(?![0-9])"#),
            (720, #"(?<![0-9])1280\s*[x×]\s*720(?![0-9])"#),
            (480, #"(?<![0-9])(?:854|720|640)\s*[x×]\s*480(?![0-9])"#)
        ]
        return compiledResolutionMatchers(specifications)
    }()

    private static let fileSizeMatcher: NSRegularExpression? = try? NSRegularExpression(
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
        let boundedLabel = String(label.prefix(maxLanguageSearchCharacters))
        let lower = boundedLabel.lowercased()
        let resolutionHeight = detectedResolutionHeight(in: boundedLabel)

        let sizeMB = largestFileSizeMB(in: boundedLabel)

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
        if let dimension = dimensionResolutionMatchers.first(where: { matcher in
            matcher.regex.firstMatch(in: label, range: range) != nil
        }) {
            return dimension.height
        }
        return resolutionMatchers.first { matcher in
            matcher.regex.firstMatch(in: label, range: range) != nil
        }?.height
    }

    static func largestFileSizeMB(in label: String) -> Double? {
        guard let fileSizeMatcher else { return nil }
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

    static func streamLabelMatchesExactTargetQuality(
        _ label: String,
        preference: AutoModeQualityPreference
    ) -> Bool {
        guard let target = preference.targetResolutionHeight else { return false }
        return streamQualityInfo(from: label).resolutionHeight == target
    }

#if os(iOS) && !targetEnvironment(macCatalyst)

    static func bestNuvioStream(
        from streams: [NuvioPluginStream],
        preference: AutoModeQualityPreference = .current
    ) -> NuvioPluginStream? {
        guard preference.usesAutomaticSelection, !streams.isEmpty else { return nil }
        if streams.count == 1 { return streams.first }

        let ranked: [(index: Int, stream: NuvioPluginStream, score: Double)] =
            streams.enumerated().map { index, stream in
                (
                    index: index,
                    stream: stream,
                    score: streamPreferenceScore(
                        label: stream.qualitySearchLabel,
                        preference: preference,
                        index: index
                    )
                )
            }
        return ranked.max(by: { lhs, rhs in
            lhs.score == rhs.score ? lhs.index > rhs.index : lhs.score < rhs.score
        })?.stream
    }
#endif

    static func bestStremioStream(
        from streams: [StremioStream],
        preference: AutoModeQualityPreference = .current,
        sourceId: String? = nil,
        streamsAreFiltered: Bool = false,
        isAnime: Bool = false,
        originalAudioLanguage: String? = nil
    ) -> StremioStream? {
        guard preference.usesAutomaticSelection else {
            return nil
        }

        let visibleStreams: [StremioStream]
        if streamsAreFiltered {
            visibleStreams = streams
        } else if let configuration = StreamLanguageFilter.configuration(sourceId: sourceId) {
            visibleStreams = streams.filter {
                !StreamLanguageFilter.shouldHide(
                    stremio: $0,
                    configuration: configuration,
                    originalAudioLanguage: originalAudioLanguage,
                    isAnime: isAnime
                )
            }
        } else {
            visibleStreams = streams
        }

        let rankedStreams: [(index: Int, stream: StremioStream, score: Double)] =
            visibleStreams.enumerated().compactMap {
                (index, stream) -> (index: Int, stream: StremioStream, score: Double)? in
                guard let score = stremioStreamPreferenceScore(
                    stream,
                    preference: preference,
                    index: index
                ) else {
                    return nil
                }
                return (index: index, stream: stream, score: score)
            }
        return rankedStreams.max(by: { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.index > rhs.index
            }
            return lhs.score < rhs.score
        })?.stream
    }

    static func stremioStreamPreferenceScore(
        _ stream: StremioStream,
        preference: AutoModeQualityPreference,
        index: Int
    ) -> Double? {
        guard preference.usesAutomaticSelection else { return nil }
        let info = streamQualityInfo(from: smartPlayerMetadata(for: stream))
        return streamPreferenceScore(info: info, preference: preference, index: index)
            + legacyStremioStreamScore(stream)
    }

    static func bestExactTargetStremioStream(
        from streams: [StremioStream],
        preference: AutoModeQualityPreference,
        sourceId: String? = nil,
        streamsAreFiltered: Bool = false,
        isAnime: Bool = false,
        originalAudioLanguage: String? = nil
    ) -> StremioStream? {
        guard preference.startsWhenExactTargetArrives else { return nil }
        let targetStreams = streams.filter {
            streamLabelMatchesExactTargetQuality(
                smartPlayerMetadata(for: $0),
                preference: preference
            )
        }
        return bestStremioStream(
            from: targetStreams,
            preference: preference,
            sourceId: sourceId,
            streamsAreFiltered: streamsAreFiltered,
            isAnime: isAnime,
            originalAudioLanguage: originalAudioLanguage
        )
    }

    static func legacyStremioStreamScore(_ stream: StremioStream) -> Double {
        let shortDescription = stream.description.map { String($0.prefix(120)) }
        let label = [stream.displayName, shortDescription, stream.behaviorHints?.filename]
            .compactMap { $0 }
            .joined(separator: " ")
        let lower = label.lowercased()

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
        let metadataSearchText = languageSearchText(from: metadata)
        languages.append(contentsOf: detectedStremioLanguageNames(in: metadataSearchText))

        var seen = Set<String>()
        let uniqueLanguages = languages.filter { seen.insert($0).inserted }
        if uniqueLanguages.contains("Multi Audio") || uniqueLanguages.count > 3 {
            return "Multi Audio"
        }

        let namedLanguages = uniqueLanguages.filter { $0 != "Dual Audio" }
        if !namedLanguages.isEmpty {
            return namedLanguages.joined(separator: "/")
        }

        if containsStremioLanguageMarker("multi audio", in: metadataSearchText)
            || containsStremioLanguageMarker("multi-language", in: metadataSearchText)
            || containsStremioLanguageMarker("multilang", in: metadataSearchText) {
            return "Multi Audio"
        }
        if uniqueLanguages.contains("Dual Audio")
            || containsStremioLanguageMarker("dual audio", in: metadataSearchText) {
            return "Dual Audio"
        }
        return nil
    }

    static func splitStremioLanguageHint(_ value: String) -> [String] {
        String(value.prefix(maxLanguageHintCharacters))
            .components(separatedBy: CharacterSet(charactersIn: ",/|;+"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func normalizedStremioLanguageName(_ value: String) -> String? {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[](){}"))
        if isLatinoSpanishIdentifier(normalizedValue) {
            return "Latino"
        }
        let languageCode = normalizedValue.split(separator: "-", maxSplits: 1).first.map(String.init)

        switch languageCode ?? normalizedValue {
        case "dual", "dual audio", "dual-audio": return "Dual Audio"
        case "multi", "multi audio", "multi-audio", "multilang", "multi-language": return "Multi Audio"
        case "eng", "en", "english": return "English"
        case "jpn", "ja", "jp", "japanese": return "Japanese"
        case "hin", "hi", "hindi": return "Hindi"
        case "kor", "ko", "korean": return "Korean"
        case "chi", "zho", "zh", "chinese", "mandarin", "cantonese": return "Chinese"
        case "spa", "es", "esp", "spanish": return "Spanish"
        case "bul", "bg", "bulgarian": return "Bulgarian"
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

    private static func isLatinoSpanishIdentifier(_ value: String) -> Bool {
        let tokens = Set(
            value.split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
        let latinoMarkers: Set<String> = [
            "lat", "latin", "latino", "latam", "419", "latinoamerican", "latinamerican"
        ]
        let spanishMarkers: Set<String> = ["es", "spa", "spanish"]

        if !tokens.isDisjoint(with: latinoMarkers),
           (!tokens.isDisjoint(with: spanishMarkers)
                || !tokens.isDisjoint(with: ["lat", "latin", "latino", "latam"])) {
            return true
        }

        let components = value.split(separator: "-").map(String.init)
        guard let primary = components.first,
              spanishMarkers.contains(primary),
              components.count > 1 else {
            return false
        }
        return !Set(components.dropFirst()).isDisjoint(with: latinoMarkers)
    }

    static func detectedStremioLanguageNames(in value: String) -> [String] {
        detectedStremioLanguageNames(in: languageSearchText(from: value))
    }

    static func containsStremioLanguageMarker(_ marker: String, in value: String) -> Bool {
        containsStremioLanguageMarker(marker, in: languageSearchText(from: value))
    }

    fileprivate static func languageSearchText(from value: String) -> LanguageSearchText {
        languageSearchText(from: [value])
    }

    fileprivate static func languageSearchText(from values: [String]) -> LanguageSearchText {
        freeTextLanguageSearchText(languageTaggableText(from: values))
    }

    fileprivate static func languageHintSearchText(from values: [String]) -> LanguageSearchText {
        let combined = combinedLanguageSource(from: values).lowercased()
        let shortCodeTokens: Set<String> = asciiLanguageTokens(in: combined)
            .filter(isShortLanguageCode)
        return LanguageSearchText(value: combined, shortCodeTokens: shortCodeTokens)
    }

    fileprivate static func languageTaggableText(from values: [String]) -> String {
        combinedLanguageSource(from: values.map(languageTaggableFragment(from:)))
    }

    private static func freeTextLanguageSearchText(_ source: String) -> LanguageSearchText {
        LanguageSearchText(
            value: source.lowercased(),
            shortCodeTokens: tagLikeShortLanguageCodes(in: source)
        )
    }

    private static func combinedLanguageSource(from values: [String]) -> String {
        var combined = ""
        combined.reserveCapacity(min(maxLanguageSearchCharacters, 1_024))
        var remaining = maxLanguageSearchCharacters

        for value in values where remaining > 0 {
            let fragment = String(value.prefix(remaining))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fragment.isEmpty else { continue }
            if !combined.isEmpty {
                combined.append(" ")
                remaining -= 1
                guard remaining > 0 else { break }
            }
            let boundedFragment = fragment.prefix(remaining)
            combined.append(contentsOf: boundedFragment)
            remaining -= boundedFragment.count
        }

        return combined
    }

    private static func languageTaggableFragment(from value: String) -> String {
        let bounded = String(value.prefix(maxLanguageSearchCharacters))
        guard bounded.range(of: "://") != nil else { return bounded }

        var result = ""
        result.reserveCapacity(bounded.count)
        var remainder = Substring(bounded)

        while let separator = remainder.range(of: "://") {
            let head = remainder[remainder.startIndex..<separator.lowerBound]
            let schemeStart = head.lastIndex(where: { !isURLSchemeCharacter($0) })
                .map { head.index(after: $0) } ?? head.startIndex
            result.append(contentsOf: head[head.startIndex..<schemeStart])
            let afterSeparator = remainder[separator.upperBound...]
            let authorityEnd = afterSeparator.firstIndex(where: {
                $0 == "/" || $0 == "?" || $0 == "#" || $0.isWhitespace
            }) ?? afterSeparator.endIndex
            result.append(" ")
            remainder = afterSeparator[authorityEnd...]
        }

        result.append(contentsOf: remainder)
        return result
    }

    private static func isURLSchemeCharacter(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter || character.isNumber || character == "+" || character == "-" || character == ".")
    }

    private static func isShortLanguageCode(_ value: String) -> Bool {
        value.count <= 2 && value.allSatisfy { $0.isASCII && $0.isLetter }
    }

    private static let ambiguousShortLanguageCodes: Set<String> = [
        "de", "es", "id", "it", "mr", "la", "is", "in", "no", "me", "so", "to"
    ]

    private static let deliberateLanguageTagContextWords: Set<String> = [
        "audio", "audios", "dub", "dubs", "dubbed", "dublado", "sub", "subs", "subbed",
        "subtitle", "subtitles", "subtitulos", "lang", "langs", "language", "languages",
        "dual", "multi", "multiaudio", "multilang", "multilanguage", "track", "tracks"
    ]

    private static let releaseStructureTokens: Set<String> = [
        "4k", "8k", "uhd", "fhd", "qhd", "hd", "sd", "hdr", "hdr10", "hdr10plus", "dv", "dovi",
        "hlg", "sdr", "10bit", "8bit", "hi10p",
        "bluray", "blu", "ray", "bdrip", "bdremux", "brrip", "bd", "remux", "web", "webrip",
        "webdl", "dl", "hdtv", "hdrip", "dvdrip", "dvd", "dvdscr", "cam", "hdcam", "ts", "hdts",
        "telesync", "telecine", "pdtv", "tvrip", "sdtv", "vodrip",
        "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "xvid", "divx", "vp9",
        "aac", "ac3", "eac3", "dd", "ddp", "dd5", "ddp5", "dts", "dtshd", "truehd", "atmos",
        "opus", "flac", "mp3",
        "amzn", "nf", "dsnp", "hmax", "atvp", "pcok", "hulu", "itunes", "hbo", "sho",
        "proper", "repack", "extended", "uncut", "unrated", "imax", "limited", "internal",
        "complete", "season", "seasons", "episode", "remastered", "theatrical", "directors",
        "mkv", "mp4", "avi", "m4v", "mov",
        "esub", "esubs", "msub", "msubs"
    ]

    private static let releaseResolutionHeights: Set<String> = [
        "240", "360", "480", "540", "576", "720", "1080", "1440", "2160", "4320"
    ]

    private static let unambiguousLanguageMarkerTokens: Set<String> =
        Set(stremioLanguageMarkers.flatMap { $0.markers })
            .subtracting(ambiguousShortLanguageCodes)

    private static let maximumReleaseTokenScalars = 24

    private struct ReleaseNameToken {
        let text: String
        let isShortLetterCode: Bool
        let isBracketWrapped: Bool
        let opensWhitespaceGroup: Bool
    }

    private static func tagLikeShortLanguageCodes(in source: String) -> Set<String> {
        let tokens = releaseNameTokens(in: source)
        var codes: Set<String> = []
        for index in tokens.indices where tokens[index].isShortLetterCode {
            let code = tokens[index].text
            guard !code.isEmpty,
                  shortLanguageCodeReadsAsATag(at: index, in: tokens) else {
                continue
            }
            codes.insert(code)
        }
        return codes
    }

    private static func shortLanguageCodeReadsAsATag(
        at index: Int,
        in tokens: [ReleaseNameToken]
    ) -> Bool {
        let token = tokens[index]
        guard !releaseStructureTokens.contains(token.text),
              !deliberateLanguageTagContextWords.contains(token.text) else {
            return false
        }
        if token.isBracketWrapped { return true }
        guard ambiguousShortLanguageCodes.contains(token.text) else { return true }

        let neighbours = [
            tokens.indices.contains(index - 1) ? tokens[index - 1] : nil,
            tokens.indices.contains(index + 1) ? tokens[index + 1] : nil
        ].compactMap { $0 }
        if token.opensWhitespaceGroup {
            return neighbours.contains { neighbourNamesALanguageContext($0.text) }
        }
        return neighbours.contains { neighbourAnchorsALanguageTag($0.text) }
    }

    private static func neighbourNamesALanguageContext(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return deliberateLanguageTagContextWords.contains(text)
            || unambiguousLanguageMarkerTokens.contains(text)
    }

    private static func neighbourAnchorsALanguageTag(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return neighbourNamesALanguageContext(text)
            || releaseStructureTokens.contains(text)
            || isReleaseResolutionToken(text)
            || isReleaseYearToken(text)
            || isSeasonEpisodeToken(text)
    }

    private static func isReleaseResolutionToken(_ text: String) -> Bool {
        if releaseResolutionHeights.contains(text) { return true }
        guard let suffix = text.last, suffix == "p" || suffix == "i" else { return false }
        return releaseResolutionHeights.contains(String(text.dropLast()))
    }

    private static func isReleaseYearToken(_ text: String) -> Bool {
        guard text.count == 4,
              text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let year = Int(text) else {
            return false
        }
        return (1900...2099).contains(year)
    }

    private static func isSeasonEpisodeToken(_ text: String) -> Bool {
        var remainder = Substring(text)
        var matchedMarker = false
        while let marker = remainder.first, marker == "s" || marker == "e" {
            remainder = remainder.dropFirst()
            let digits = remainder.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 4 else { return false }
            remainder = remainder.dropFirst(digits.count)
            matchedMarker = true
        }
        return matchedMarker && remainder.isEmpty
    }

    private static func releaseNameTokens(in source: String) -> [ReleaseNameToken] {
        var tokens: [ReleaseNameToken] = []
        var currentToken = ""
        var currentScalarCount = 0
        var currentIsASCIILetters = true
        var currentFollowsOpeningBracket = false
        var previousScalar: Unicode.Scalar?
        var awaitingGroupStart = true

        func appendToken(followedBy next: Unicode.Scalar?) {
            defer {
                currentToken = ""
                currentScalarCount = 0
                currentIsASCIILetters = true
                currentFollowsOpeningBracket = false
            }
            guard currentScalarCount > 0 else { return }
            let isBracketWrapped = currentFollowsOpeningBracket
                && (next.map(isLanguageTagClosingBracket) ?? false)
            tokens.append(
                ReleaseNameToken(
                    text: currentScalarCount <= maximumReleaseTokenScalars
                        ? currentToken.lowercased()
                        : "",
                    isShortLetterCode: currentIsASCIILetters && currentScalarCount <= 2,
                    isBracketWrapped: isBracketWrapped,
                    opensWhitespaceGroup: awaitingGroupStart
                )
            )
            awaitingGroupStart = false
        }

        for scalar in source.unicodeScalars {
            if isLanguageTokenScalar(scalar) {
                if currentScalarCount == 0 {
                    currentFollowsOpeningBracket = previousScalar
                        .map(isLanguageTagOpeningBracket) ?? false
                }
                if !isASCIIEnglishLetterScalar(scalar) { currentIsASCIILetters = false }
                if currentScalarCount < maximumReleaseTokenScalars {
                    currentToken.unicodeScalars.append(scalar)
                }
                currentScalarCount += 1
            } else {
                appendToken(followedBy: scalar)
                if Character(scalar).isWhitespace { awaitingGroupStart = true }
            }
            previousScalar = scalar
        }
        appendToken(followedBy: nil)
        return tokens
    }

    private static func isLanguageTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        let character = Character(scalar)
        return character.isLetter || character.isNumber
    }

    private static func isLanguageTagOpeningBracket(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "[" || scalar == "(" || scalar == "{"
    }

    private static func isLanguageTagClosingBracket(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "]" || scalar == ")" || scalar == "}"
    }

    private static func isASCIIEnglishLetterScalar(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    fileprivate static func detectedStremioLanguageNames(in searchText: LanguageSearchText) -> [String] {
        var tokens: Set<String> = asciiLanguageTokens(in: searchText.value)
            .filter { !isShortLanguageCode($0) }
        tokens.formUnion(searchText.shortCodeTokens)
        return stremioLanguageMarkers.compactMap { language in
            language.markers.isDisjoint(with: tokens) ? nil : language.name
        }
    }

    fileprivate static func containsStremioLanguageMarker(
        _ marker: String,
        in searchText: LanguageSearchText
    ) -> Bool {
        let normalizedMarker = String(marker.prefix(maxLanguageHintCharacters)).lowercased()
        guard !normalizedMarker.isEmpty, !searchText.value.isEmpty else { return false }
        if isShortLanguageCode(normalizedMarker) {
            return searchText.shortCodeTokens.contains(normalizedMarker)
        }

        var searchStart = searchText.value.startIndex
        while searchStart < searchText.value.endIndex,
              let range = searchText.value.range(
                  of: normalizedMarker,
                  range: searchStart..<searchText.value.endIndex
              ) {
            let hasLeadingBoundary = range.lowerBound == searchText.value.startIndex
                || !isASCIIEnglishLetter(searchText.value[searchText.value.index(before: range.lowerBound)])
            let hasTrailingBoundary = range.upperBound == searchText.value.endIndex
                || !isASCIIEnglishLetter(searchText.value[range.upperBound])
            if hasLeadingBoundary && hasTrailingBoundary {
                return true
            }
            searchStart = searchText.value.index(after: range.lowerBound)
        }
        return false
    }

    private static func asciiLanguageTokens(in value: String) -> Set<String> {
        var tokens = Set<String>()
        var currentToken: [UInt8] = []
        currentToken.reserveCapacity(16)

        func commitToken() {
            guard !currentToken.isEmpty else { return }
            tokens.insert(String(decoding: currentToken, as: UTF8.self))
            currentToken.removeAll(keepingCapacity: true)
        }

        for byte in value.utf8 {
            if byte >= 97 && byte <= 122 {
                currentToken.append(byte)
            } else {
                commitToken()
            }
        }
        commitToken()
        return tokens
    }

    private static func isASCIIEnglishLetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        return isASCIIEnglishLetterScalar(scalar)
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
        let qualityPatterns = ["bluray", "blu-ray", "bdrip", "brrip", "dvdrip", "dvd", "webrip", "web-dl", "webdl", "web", "hdtv", "hdrip", "cam", "ts", "hdcam", "remux"]
        let codecPatterns = ["hevc", "h265", "h.265", "x265", "h264", "h.264", "x264", "av1", "vp9", "xvid"]
        let hdrPatterns = ["hdr10+", "hdr10", "hdr", "dolby vision", "dv", "sdr"]
        let audioPatterns = ["atmos", "truehd", "dts-hd", "dts", "dd5.1", "dd+", "aac", "5.1", "7.1"]

        var tags: [String] = []
        let joinedText = lines.joined(separator: " ")
        let allText = joinedText.lowercased()

        if let height = detectedResolutionHeight(in: joinedText) {
            tags.append(height == 2160 ? "4K" : "\(height)P")
        }

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
    static let assumeOriginalAudioKey = "servicesAssumeOriginalAudio"
    static let treatDubbedAnimeAsEnglishKey = "servicesTreatDubbedAnimeAsEnglish"
    static let hiddenStreamQualitiesKey = "servicesHiddenStreamQualities"
    static let hideUnknownQualityStreamsKey = "servicesHideStreamsWithoutDetectedQuality"
    static let extraRulesSourceIdsKey = "servicesExtraRulesSourceIds"
    static let supportedQualityHeights = [2160, 1440, 1080, 720, 480, 360]

    static let maximumSkyStreamSourceIDComponentLength = 128
    private static let maximumExtraRulesSourceIDLength =
        "skystream:".count + maximumSkyStreamSourceIDComponentLength * 2 + "::".count
    private static let skyStreamSourceIDCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )
    private static let skyStreamSourceIDBoundaryCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    )

    struct Matcher {
        let keys: Set<String>
        let markers: [String]
    }

    struct Configuration {
        let hidesStreamsWithoutLanguageData: Bool
        let assumesOriginalAudio: Bool
        let treatsDubbedAnimeAsEnglish: Bool
        let includedLanguageMatchers: [Matcher]
        let hiddenLanguageMatchers: [Matcher]
        let hiddenQualityHeights: Set<Int>
        let hidesStreamsWithoutDetectedQuality: Bool

        var hasLanguageRules: Bool {
            hidesStreamsWithoutLanguageData
                || assumesOriginalAudio
                || treatsDubbedAnimeAsEnglish
                || !includedLanguageMatchers.isEmpty
                || !hiddenLanguageMatchers.isEmpty
        }

        var hasQualityRules: Bool {
            hidesStreamsWithoutDetectedQuality || !hiddenQualityHeights.isEmpty
        }

        var canHideStreams: Bool {
            hidesStreamsWithoutLanguageData
                || !includedLanguageMatchers.isEmpty
                || !hiddenLanguageMatchers.isEmpty
                || hasQualityRules
        }
    }

    static func hiddenLanguages(defaults: UserDefaults = ProfileSettingsStore.services) -> [String] {
        sanitizedLanguageList(defaults.stringArray(forKey: storageKey) ?? [])
    }

    static func includedLanguages(defaults: UserDefaults = ProfileSettingsStore.services) -> [String] {
        sanitizedLanguageList(defaults.stringArray(forKey: includedLanguagesKey) ?? [])
    }

    static func hidesStreamsWithoutLanguageData(defaults: UserDefaults = ProfileSettingsStore.services) -> Bool {
        defaults.bool(forKey: hideUnknownLanguageStreamsKey)
    }

    static func assumesOriginalAudio(defaults: UserDefaults = ProfileSettingsStore.services) -> Bool {
        defaults.bool(forKey: assumeOriginalAudioKey)
    }

    static func treatsDubbedAnimeAsEnglish(defaults: UserDefaults = ProfileSettingsStore.services) -> Bool {
        defaults.bool(forKey: treatDubbedAnimeAsEnglishKey)
    }

    static func hiddenQualityHeights(defaults: UserDefaults = ProfileSettingsStore.services) -> [Int] {
        sanitizedQualityHeights(defaults.array(forKey: hiddenStreamQualitiesKey)?.compactMap { value in
            if let intValue = value as? Int { return intValue }
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String { return Int(string) }
            return nil
        } ?? [])
    }

    static func hidesStreamsWithoutDetectedQuality(defaults: UserDefaults = ProfileSettingsStore.services) -> Bool {
        defaults.bool(forKey: hideUnknownQualityStreamsKey)
    }

    static func extraRulesSourceIds(defaults: UserDefaults = ProfileSettingsStore.services) -> [String]? {
        guard defaults.object(forKey: extraRulesSourceIdsKey) != nil else { return nil }
        return sanitizedExtraRulesSourceIds(defaults.stringArray(forKey: extraRulesSourceIdsKey) ?? [])
    }

    static func extraRulesApply(to sourceId: String?, defaults: UserDefaults = ProfileSettingsStore.services) -> Bool {
        guard let sourceId else { return true }
        guard let selectedSourceIds = extraRulesSourceIds(defaults: defaults) else { return true }
        return selectedSourceIds.contains(sourceId)
    }

    private static let configurationCacheLock = NSLock()
    private static var configurationCache: [ConfigurationCacheKey: Configuration?] = [:]

    private struct ConfigurationCacheKey: Hashable {
        let store: ObjectIdentifier
        let sourceId: String?
    }

    private static let configurationCacheInvalidator: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification,
        object: nil,
        queue: nil
    ) { _ in
        configurationCacheLock.lock()
        configurationCache.removeAll(keepingCapacity: true)
        configurationCacheLock.unlock()
    }

    static func invalidateConfigurationCache() {
        configurationCacheLock.lock()
        configurationCache.removeAll(keepingCapacity: true)
        configurationCacheLock.unlock()
    }

    static func configuration(
        sourceId: String? = nil,
        defaults: UserDefaults = ProfileSettingsStore.services
    ) -> Configuration? {
        _ = configurationCacheInvalidator
        let cacheKey = ConfigurationCacheKey(store: ObjectIdentifier(defaults), sourceId: sourceId)

        configurationCacheLock.lock()
        if let cached = configurationCache[cacheKey] {
            configurationCacheLock.unlock()
            return cached
        }
        configurationCacheLock.unlock()

        let resolved = computedConfiguration(sourceId: sourceId, defaults: defaults)

        configurationCacheLock.lock()
        configurationCache[cacheKey] = resolved
        configurationCacheLock.unlock()
        return resolved
    }

    private static func computedConfiguration(
        sourceId: String?,
        defaults: UserDefaults
    ) -> Configuration? {
        guard extraRulesApply(to: sourceId, defaults: defaults) else { return nil }

        let included = includedLanguages(defaults: defaults)
        let hidden = hiddenLanguages(defaults: defaults)
        let hiddenQualities = Set(hiddenQualityHeights(defaults: defaults))
        let hideUnknownLanguage = hidesStreamsWithoutLanguageData(defaults: defaults)
        let assumeOriginalAudio = assumesOriginalAudio(defaults: defaults)
        let treatDubbedAnimeAsEnglish = treatsDubbedAnimeAsEnglish(defaults: defaults)
        let hideUnknownQuality = hidesStreamsWithoutDetectedQuality(defaults: defaults)

        guard hideUnknownLanguage
                || assumeOriginalAudio
                || treatDubbedAnimeAsEnglish
                || hideUnknownQuality
                || !included.isEmpty
                || !hidden.isEmpty
                || !hiddenQualities.isEmpty else {
            return nil
        }

        return Configuration(
            hidesStreamsWithoutLanguageData: hideUnknownLanguage,
            assumesOriginalAudio: assumeOriginalAudio,
            treatsDubbedAnimeAsEnglish: treatDubbedAnimeAsEnglish,
            includedLanguageMatchers: included.map(matcher(for:)),
            hiddenLanguageMatchers: hidden.map(matcher(for:)),
            hiddenQualityHeights: hiddenQualities,
            hidesStreamsWithoutDetectedQuality: hideUnknownQuality
        )
    }

    static func setHiddenLanguages(_ values: [String], defaults: UserDefaults = ProfileSettingsStore.services) {
        let sanitized = sanitizedLanguageList(values)
        if sanitized.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(sanitized, forKey: storageKey)
        }
    }

    static func setIncludedLanguages(_ values: [String], defaults: UserDefaults = ProfileSettingsStore.services) {
        let sanitized = sanitizedLanguageList(values)
        if sanitized.isEmpty {
            defaults.removeObject(forKey: includedLanguagesKey)
        } else {
            defaults.set(sanitized, forKey: includedLanguagesKey)
        }
    }

    static func setHidesStreamsWithoutLanguageData(_ enabled: Bool, defaults: UserDefaults = ProfileSettingsStore.services) {
        if enabled {
            defaults.set(true, forKey: hideUnknownLanguageStreamsKey)
        } else {
            defaults.removeObject(forKey: hideUnknownLanguageStreamsKey)
        }
    }

    static func setAssumesOriginalAudio(_ enabled: Bool, defaults: UserDefaults = ProfileSettingsStore.services) {
        if enabled {
            defaults.set(true, forKey: assumeOriginalAudioKey)
        } else {
            defaults.removeObject(forKey: assumeOriginalAudioKey)
        }
    }

    static func setTreatsDubbedAnimeAsEnglish(_ enabled: Bool, defaults: UserDefaults = ProfileSettingsStore.services) {
        if enabled {
            defaults.set(true, forKey: treatDubbedAnimeAsEnglishKey)
        } else {
            defaults.removeObject(forKey: treatDubbedAnimeAsEnglishKey)
        }
    }

    static func setHiddenQualityHeights(_ values: [Int], defaults: UserDefaults = ProfileSettingsStore.services) {
        let sanitized = sanitizedQualityHeights(values)
        if sanitized.isEmpty {
            defaults.removeObject(forKey: hiddenStreamQualitiesKey)
        } else {
            defaults.set(sanitized, forKey: hiddenStreamQualitiesKey)
        }
    }

    static func setHidesStreamsWithoutDetectedQuality(_ enabled: Bool, defaults: UserDefaults = ProfileSettingsStore.services) {
        if enabled {
            defaults.set(true, forKey: hideUnknownQualityStreamsKey)
        } else {
            defaults.removeObject(forKey: hideUnknownQualityStreamsKey)
        }
    }

    static func setExtraRulesSourceIds(_ values: [String]?, defaults: UserDefaults = ProfileSettingsStore.services) {
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
            guard !trimmed.isEmpty,
                  trimmed.count <= maximumExtraRulesSourceIDLength,
                  trimmed.hasPrefix("service:")
                    || trimmed.hasPrefix("stremio:")
                    || isValidSkyStreamSourceID(trimmed)
                    || isValidNuvioSourceID(trimmed),
                  seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
        .prefix(200)
        .map { $0 }
    }

    static func isPlatformScopedProviderSourceID(_ sourceID: String) -> Bool {
        isValidSkyStreamSourceID(sourceID) || isValidNuvioSourceID(sourceID)
    }

    static func isValidNuvioSourceID(_ sourceID: String) -> Bool {
        let prefix = "nuvio:"
        guard sourceID.hasPrefix(prefix),
              sourceID.count <= maximumExtraRulesSourceIDLength else {
            return false
        }
        let components = String(sourceID.dropFirst(prefix.count)).components(separatedBy: "::")
        guard components.count == 1 || components.count == 2 else { return false }
        return components.allSatisfy(isValidSkyStreamSourceIDComponent)
    }

    static func isValidSkyStreamSourceID(_ sourceID: String) -> Bool {
        let prefix = "skystream:"
        guard sourceID.hasPrefix(prefix),
              sourceID.count <= maximumExtraRulesSourceIDLength else {
            return false
        }

        let payload = String(sourceID.dropFirst(prefix.count))
        let components = payload.components(separatedBy: "::")
        guard components.count == 1 || components.count == 2 else { return false }
        return components.allSatisfy(isValidSkyStreamSourceIDComponent)
    }

    private static func isValidSkyStreamSourceIDComponent(_ component: String) -> Bool {
        guard !component.isEmpty,
              component.count <= maximumSkyStreamSourceIDComponentLength,
              component != ".",
              component != "..",
              !component.contains(".."),
              component.unicodeScalars.allSatisfy({ skyStreamSourceIDCharacters.contains($0) }),
              let first = component.unicodeScalars.first,
              let last = component.unicodeScalars.last,
              skyStreamSourceIDBoundaryCharacters.contains(first),
              skyStreamSourceIDBoundaryCharacters.contains(last) else {
            return false
        }
        return true
    }

    static func qualityLabel(for height: Int) -> String {
        height == 2160 ? "4K / 2160p" : "\(height)p"
    }

    static func shouldHide(
        languageHints: [String],
        metadata: [String],
        sourceId: String? = nil,
        defaults: UserDefaults = ProfileSettingsStore.services,
        originalAudioLanguage: String? = nil,
        isAnime: Bool = false
    ) -> Bool {
        guard let configuration = configuration(sourceId: sourceId, defaults: defaults) else {
            return false
        }
        return shouldHide(
            languageHints: languageHints,
            metadata: metadata,
            configuration: configuration,
            originalAudioLanguage: originalAudioLanguage,
            isAnime: isAnime
        )
    }

    static func shouldHide(
        languageHints: [String],
        metadata: [String],
        configuration: Configuration,
        originalAudioLanguage: String? = nil,
        isAnime: Bool = false
    ) -> Bool {
        let boundedMetadataText = metadataText(from: metadata)
        if configuration.hasQualityRules {
            let detectedQuality = AutoModeStreamSelection.streamQualityInfo(from: boundedMetadataText).resolutionHeight
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
            metadataText: boundedMetadataText,
            configuration: configuration,
            originalAudioLanguage: originalAudioLanguage,
            isAnime: isAnime
        )
    }

    private static func shouldHideForLanguage(
        languageHints: [String],
        metadataText: String,
        configuration: Configuration,
        originalAudioLanguage: String?,
        isAnime: Bool
    ) -> Bool {
        let metadataSearchText = AutoModeStreamSelection.languageSearchText(from: metadataText)
        let detectedMetadataLanguages = AutoModeStreamSelection.detectedStremioLanguageNames(
            in: metadataSearchText
        )
        let metadataIsDubbed = metadataIndicatesDubbed(metadataSearchText)
        let languageDataPresent = hasLanguageData(
            languageHints: languageHints,
            metadataSearchText: metadataSearchText,
            detectedMetadataLanguages: detectedMetadataLanguages,
            metadataIsDubbed: metadataIsDubbed,
            treatsDubbedAnimeAsEnglish: configuration.treatsDubbedAnimeAsEnglish,
            isAnime: isAnime
        )
        let treatsDubbedAnimeAsEnglish = isAnime
            && configuration.treatsDubbedAnimeAsEnglish
            && metadataIsDubbed
        let detectedHintLanguages = AutoModeStreamSelection.detectedStremioLanguageNames(
            in: AutoModeStreamSelection.languageHintSearchText(from: languageHints)
        )
        let hintKeys = treatsDubbedAnimeAsEnglish
            ? Set(languageKeys(in: "English"))
            : Set(
                languageHints.flatMap { languageKeys(in: $0) }
                    + detectedHintLanguages.flatMap { languageKeys(in: $0) }
            )
        var detectedMetadataKeys = Set(
            detectedMetadataLanguages.flatMap { languageKeys(in: $0) }
        )

        let assumedOriginalLanguageKeys: Set<String> = {
            guard !languageDataPresent,
                  configuration.assumesOriginalAudio,
                  let originalAudioLanguage,
                  !originalAudioLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return []
            }
            return Set(languageKeys(in: originalAudioLanguage))
        }()

        if !assumedOriginalLanguageKeys.isEmpty {
            detectedMetadataKeys.formUnion(assumedOriginalLanguageKeys)
        }

        if configuration.hidesStreamsWithoutLanguageData,
           !languageDataPresent,
           assumedOriginalLanguageKeys.isEmpty {
            return true
        }

        guard !configuration.includedLanguageMatchers.isEmpty
                || !configuration.hiddenLanguageMatchers.isEmpty else {
            return false
        }

        if treatsDubbedAnimeAsEnglish {
            detectedMetadataKeys = Set(languageKeys(in: "English"))
        }

        if !configuration.includedLanguageMatchers.isEmpty {
            guard matchesAnyLanguage(
                configuration.includedLanguageMatchers,
                hintKeys: hintKeys,
                detectedMetadataKeys: detectedMetadataKeys,
                metadataSearchText: metadataSearchText
            ) else {
                return true
            }

            if containsExplicitLanguageOutside(
                configuration.includedLanguageMatchers,
                languageHints: languageHints,
                detectedHintLanguages: detectedHintLanguages,
                detectedMetadataLanguages: detectedMetadataLanguages
            ) {
                return true
            }
        }

        if matchesAnyLanguage(
            configuration.hiddenLanguageMatchers,
            hintKeys: hintKeys,
            detectedMetadataKeys: detectedMetadataKeys,
            metadataSearchText: metadataSearchText
        ) {
            return true
        }

        return false
    }

    private static func containsExplicitLanguageOutside(
        _ allowedMatchers: [Matcher],
        languageHints: [String],
        detectedHintLanguages: [String],
        detectedMetadataLanguages: [String]
    ) -> Bool {
        let hintLanguages = languageHints
            .flatMap(AutoModeStreamSelection.splitStremioLanguageHint)
            .compactMap(AutoModeStreamSelection.normalizedStremioLanguageName)
        let explicitLanguageKeys = Set(
            (hintLanguages + detectedHintLanguages + detectedMetadataLanguages).flatMap {
                languageKeys(in: $0)
            }
        )

        return explicitLanguageKeys.contains { languageKey in
            !allowedMatchers.contains { !$0.keys.isDisjoint(with: [languageKey]) }
        }
    }

    private static func matchesAnyLanguage(
        _ matchers: [Matcher],
        hintKeys: Set<String>,
        detectedMetadataKeys: Set<String>,
        metadataSearchText: AutoModeStreamSelection.LanguageSearchText
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
        guard !metadataSearchText.value.isEmpty else { return false }

        return matchers.contains { matcher in
            matcher.markers.contains { marker in
                AutoModeStreamSelection.containsStremioLanguageMarker(marker, in: metadataSearchText)
            }
        }
    }

    private static func hasLanguageData(
        languageHints: [String],
        metadataSearchText: AutoModeStreamSelection.LanguageSearchText,
        detectedMetadataLanguages: [String],
        metadataIsDubbed: Bool,
        treatsDubbedAnimeAsEnglish: Bool,
        isAnime: Bool
    ) -> Bool {
        let hintValues = languageHints
            .flatMap(AutoModeStreamSelection.splitStremioLanguageHint)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if hintValues.contains(where: isMeaningfulLanguageHint) {
            return true
        }

        guard !metadataSearchText.value.isEmpty else { return false }
        if !detectedMetadataLanguages.isEmpty {
            return true
        }

        if isAnime, treatsDubbedAnimeAsEnglish, metadataIsDubbed {
            return true
        }

        return AutoModeStreamSelection.containsStremioLanguageMarker("multi audio", in: metadataSearchText)
            || AutoModeStreamSelection.containsStremioLanguageMarker("multi-language", in: metadataSearchText)
            || AutoModeStreamSelection.containsStremioLanguageMarker("multilang", in: metadataSearchText)
            || AutoModeStreamSelection.containsStremioLanguageMarker("dual audio", in: metadataSearchText)
    }

    static func shouldHide(
        stremio stream: StremioStream,
        sourceId: String? = nil,
        defaults: UserDefaults = ProfileSettingsStore.services,
        originalAudioLanguage: String? = nil,
        isAnime: Bool = false
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
            defaults: defaults,
            originalAudioLanguage: originalAudioLanguage,
            isAnime: isAnime
        )
    }

    static func shouldHide(
        stremio stream: StremioStream,
        configuration: Configuration,
        originalAudioLanguage: String? = nil,
        isAnime: Bool = false
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
            configuration: configuration,
            originalAudioLanguage: originalAudioLanguage,
            isAnime: isAnime
        )
    }

    private static func metadataIndicatesDubbed(
        _ metadataSearchText: AutoModeStreamSelection.LanguageSearchText
    ) -> Bool {
        ["dub", "dubbed", "dubbed audio", "foreign dub"].contains {
            AutoModeStreamSelection.containsStremioLanguageMarker($0, in: metadataSearchText)
        }
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
        AutoModeStreamSelection.languageTaggableText(from: metadata)
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
        let folded = value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()

        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(folded.utf8.count, 256))
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            let value = scalar.value
            if (48...57).contains(value) || (97...122).contains(value) {
                if pendingSeparator, !bytes.isEmpty {
                    bytes.append(32)
                }
                bytes.append(UInt8(value))
                pendingSeparator = false
            } else if !bytes.isEmpty {
                pendingSeparator = true
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
