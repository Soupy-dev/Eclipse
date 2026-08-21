//
//  KanzenAidokuMigration.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

#if !os(tvOS)
import Foundation
import Combine

struct KanzenAidokuLegacyEntry: Equatable, Hashable, Sendable, Identifiable {
    let legacySourceID: String
    let legacyItemKey: String
    var libraryItemID: Int?
    var title: String?
    var coverURL: String?
    var hasReadingProgress: Bool

    var legacyStableKey: String {
        ReaderExtensionAidokuMigration.legacyStableKey(
            sourceID: legacySourceID,
            itemKey: legacyItemKey
        )
    }

    var id: String { legacyStableKey }
}

struct KanzenAidokuMigrationSummary: Equatable, Sendable {
    var legacySourceIDs: [String] = []
    var referencedSourceIDs: [String] = []
    var libraryEntryCount = 0
    var libraryEntriesWithProgress = 0
    var progressOnlyEntryCount = 0
    var libraryStoreUnreadable = false
    var progressStoreUnreadable = false
    var truncated = false

    static let empty = KanzenAidokuMigrationSummary()

    var legacySourceCount: Int { legacySourceIDs.count }

    var affectedEntryCount: Int { libraryEntryCount + progressOnlyEntryCount }

    var isBlocked: Bool { libraryStoreUnreadable || progressStoreUnreadable }

    /// Leftover *source metadata* alone is not something to migrate. A restored
    /// backup can carry `readerExtensions.legacyAidokuSources.v1` while no
    /// saved item references it, and offering to reconnect nothing reads as a
    /// bug. Only saved content the user can actually lose counts.
    var hasLeftoverData: Bool {
        guard !isBlocked else { return false }
        return !referencedSourceIDs.isEmpty
    }
}

struct KanzenAidokuLeftoverScan: Equatable, Sendable {
    var summary: KanzenAidokuMigrationSummary = .empty
    var entries: [KanzenAidokuLegacyEntry] = []
    var legacySources: [BackupLegacyAidokuSourceMetadata] = []

    static let empty = KanzenAidokuLeftoverScan()

    func entries(forSourceID sourceID: String) -> [KanzenAidokuLegacyEntry] {
        entries.filter { $0.legacySourceID == sourceID }
    }
}

enum KanzenAidokuLeftoverScanner {
    static let maximumCollectedEntries = 20_000

    private static let routeMarker = Data("aidoku".utf8)

    static func mayContainLegacyRoutes(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty else { return false }
        return data.range(of: routeMarker) != nil
    }

    static func scan(
        legacySources: [BackupLegacyAidokuSourceMetadata],
        libraryData: Data?,
        progressData: Data?
    ) -> KanzenAidokuLeftoverScan {
        var summary = KanzenAidokuMigrationSummary()
        summary.legacySourceIDs = legacySources.map(\.id).sorted()

        guard mayContainLegacyRoutes(libraryData) || mayContainLegacyRoutes(progressData) else {
            return KanzenAidokuLeftoverScan(
                summary: summary,
                entries: [],
                legacySources: legacySources
            )
        }

        let library = MangaLibraryManager.persistedCollections(from: libraryData)
        summary.libraryStoreUnreadable = library.unreadable
        let progress = decodedProgress(progressData)
        summary.progressStoreUnreadable = progress.unreadable

        guard !summary.isBlocked else {
            return KanzenAidokuLeftoverScan(
                summary: summary,
                entries: [],
                legacySources: legacySources
            )
        }

        var entries: [KanzenAidokuLegacyEntry] = []
        var seenStableKeys = Set<String>()
        var seenLibraryIDs = Set<Int>()
        var referenced = Set<String>()

        for collection in library.collections {
            for item in collection.items {
                guard let route = item.route,
                      case .aidoku(let sourceID, let mangaKey) = route else { continue }
                guard seenLibraryIDs.insert(item.id).inserted else { continue }
                referenced.insert(sourceID)
                summary.libraryEntryCount += 1
                let itemProgress = progress.progress[item.id]
                let hasProgress = hasMeaningfulProgress(itemProgress)
                if hasProgress { summary.libraryEntriesWithProgress += 1 }
                let stableKey = ReaderExtensionAidokuMigration.legacyStableKey(
                    sourceID: sourceID,
                    itemKey: mangaKey
                )
                guard seenStableKeys.insert(stableKey).inserted else { continue }
                guard entries.count < maximumCollectedEntries else {
                    summary.truncated = true
                    continue
                }
                entries.append(
                    KanzenAidokuLegacyEntry(
                        legacySourceID: sourceID,
                        legacyItemKey: mangaKey,
                        libraryItemID: item.id,
                        title: item.title,
                        coverURL: item.coverURL,
                        hasReadingProgress: hasProgress
                    )
                )
            }
        }

        for (mangaID, record) in progress.progress {
            guard let route = record.route,
                  case .aidoku(let sourceID, let mangaKey) = route else { continue }
            guard !seenLibraryIDs.contains(mangaID) else { continue }
            referenced.insert(sourceID)
            summary.progressOnlyEntryCount += 1
            let stableKey = ReaderExtensionAidokuMigration.legacyStableKey(
                sourceID: sourceID,
                itemKey: mangaKey
            )
            guard seenStableKeys.insert(stableKey).inserted else { continue }
            guard entries.count < maximumCollectedEntries else {
                summary.truncated = true
                continue
            }
            entries.append(
                KanzenAidokuLegacyEntry(
                    legacySourceID: sourceID,
                    legacyItemKey: mangaKey,
                    libraryItemID: mangaID,
                    title: record.title,
                    coverURL: record.coverURL,
                    hasReadingProgress: hasMeaningfulProgress(record)
                )
            )
        }

        summary.referencedSourceIDs = referenced.sorted()
        return KanzenAidokuLeftoverScan(
            summary: summary,
            entries: entries.sorted { $0.legacyStableKey < $1.legacyStableKey },
            legacySources: legacySources
        )
    }

    private static func decodedProgress(
        _ data: Data?
    ) -> (progress: [Int: MangaProgress], unreadable: Bool) {
        guard let data, !data.isEmpty else { return ([:], false) }
        guard let decoded = try? JSONDecoder().decode([Int: MangaProgress].self, from: data) else {
            return ([:], true)
        }
        return (decoded, false)
    }

    private static func hasMeaningfulProgress(_ record: MangaProgress?) -> Bool {
        guard let record else { return false }
        return !record.readChapterNumbers.isEmpty
            || record.lastReadChapter != nil
            || record.lastReadDate != nil
            || !record.pagePositions.isEmpty
    }
}

enum KanzenAidokuMatchEvidence: String, Hashable, Sendable, CaseIterable {
    case upstreamSourceIdentifier
    case providerHost
    case identifierHost
    case identifierAffinity
    case sourceName
    case language

    /// Authoritative evidence has to be independent of the source's display
    /// name. An Aidoku id is derived from that name (`en.manhwaclan` for
    /// "ManhwaClan"), so `identifierAffinity` — id tokens against the
    /// installed source's *name* — restates name equality and cannot promote a
    /// pairing on its own. Two unrelated clones of the same Madara site share a
    /// name, and a wrong promotion silently repoints an entire library.
    /// `identifierHost` is kept authoritative because it tests those tokens
    /// against the provider's real host, which no display name supplies.
    var isAuthoritative: Bool {
        switch self {
        case .upstreamSourceIdentifier, .providerHost, .identifierHost:
            return true
        case .identifierAffinity, .sourceName, .language:
            return false
        }
    }

    var weight: Int {
        switch self {
        case .upstreamSourceIdentifier: return 1_000
        case .providerHost: return 900
        case .identifierHost: return 850
        case .identifierAffinity: return 120
        case .sourceName: return 40
        case .language: return 25
        }
    }

    var displayName: String {
        switch self {
        case .upstreamSourceIdentifier: return "source identifier"
        case .providerHost: return "provider host"
        case .identifierHost: return "identifier host"
        case .identifierAffinity: return "identifier name"
        case .sourceName: return "source name"
        case .language: return "language"
        }
    }
}

struct KanzenAidokuScoredCandidate: Equatable, Hashable, Sendable, Identifiable {
    let candidate: ReaderExtensionLegacyReconnectCandidate
    let evidence: [KanzenAidokuMatchEvidence]

    var id: String { candidate.id }

    var installedSource: ReaderExtensionInstalledSource { candidate.installedSource }

    var score: Int { evidence.reduce(0) { $0 + $1.weight } }

    var hasAuthoritativeEvidence: Bool { evidence.contains(where: \.isAuthoritative) }

    var evidenceSummary: String {
        evidence.isEmpty
            ? "manual review"
            : evidence.map(\.displayName).joined(separator: " + ")
    }
}

enum KanzenAidokuSourceMatch: Equatable, Sendable {
    case confident(KanzenAidokuScoredCandidate)
    case ambiguous([KanzenAidokuScoredCandidate])
    case unmatched

    var confidentCandidate: KanzenAidokuScoredCandidate? {
        guard case .confident(let scored) = self else { return nil }
        return scored
    }

    var reviewCandidates: [KanzenAidokuScoredCandidate] {
        switch self {
        case .confident(let scored): return [scored]
        case .ambiguous(let scored): return scored
        case .unmatched: return []
        }
    }

    var hasCandidate: Bool { !reviewCandidates.isEmpty }
}

struct KanzenAidokuSourcePlan: Equatable, Sendable, Identifiable {
    let legacySource: BackupLegacyAidokuSourceMetadata
    let match: KanzenAidokuSourceMatch
    let entryCount: Int
    let entriesWithProgress: Int

    var id: String { legacySource.id }
}

struct KanzenAidokuMigrationPlan: Equatable, Sendable {
    var sources: [KanzenAidokuSourcePlan] = []
    var orphanSourceIDs: [String] = []

    static let empty = KanzenAidokuMigrationPlan()

    var confidentSources: [KanzenAidokuSourcePlan] {
        sources.filter { $0.match.confidentCandidate != nil }
    }

    var ambiguousSources: [KanzenAidokuSourcePlan] {
        sources.filter {
            if case .ambiguous = $0.match { return true }
            return false
        }
    }

    var unmatchedSources: [KanzenAidokuSourcePlan] {
        sources.filter { $0.match == .unmatched }
    }

    var isEmpty: Bool { sources.isEmpty && orphanSourceIDs.isEmpty }
}

enum KanzenAidokuSourceMatcher {
    private static let codeHostingHosts: Set<String> = [
        "github.com",
        "githubusercontent.com",
        "github.io",
        "gitlab.com",
        "gitlab.io",
        "codeberg.org",
        "bitbucket.org",
        "gitee.com",
        "sourceforge.net",
        "jsdelivr.net",
        "statically.io",
        "pages.dev",
        "workers.dev",
        "r2.dev",
        "netlify.app",
        "vercel.app",
        "herokuapp.com",
        "amazonaws.com",
        "googleapis.com",
        "firebaseapp.com"
    ]

    private static let publicSuffixLabels: Set<String> = [
        "com", "org", "net", "io", "co", "uk", "us", "to", "me", "tv", "xyz", "app", "dev",
        "info", "biz", "site", "online", "fun", "cc", "ws", "la", "in", "id", "ru", "jp",
        "fr", "es", "it", "de", "br", "mx", "cn", "tw", "kr", "vip", "live", "moe", "one",
        "top", "pro", "club", "sh", "gg", "is", "im", "art", "blog", "world", "su", "st"
    ]

    private static let genericHostLabels: Set<String> = [
        "www", "api", "cdn", "static", "assets", "img", "images", "media", "gateway", "m",
        "mobile", "web", "app", "read", "content", "data"
    ]

    private static let genericIdentifierTokens: Set<String> = [
        "aidoku", "source", "sources", "manga", "mangas", "manhwa", "manhua", "comic",
        "comics", "novel", "novels", "multi", "all", "other", "misc", "reader", "scan",
        "scans", "official", "mirror"
    ]

    static func plan(
        legacySources: [BackupLegacyAidokuSourceMetadata],
        installedSources: [ReaderExtensionInstalledSource],
        scan: KanzenAidokuLeftoverScan
    ) -> KanzenAidokuMigrationPlan {
        let allCandidates = ReaderExtensionLegacyReconnectManager.candidates(
            legacySources: legacySources,
            installedSources: installedSources
        )
        let grouped = Dictionary(grouping: allCandidates, by: { $0.legacySource.id })

        let sources = legacySources.map { legacySource -> KanzenAidokuSourcePlan in
            let entries = scan.entries(forSourceID: legacySource.id)
            return KanzenAidokuSourcePlan(
                legacySource: legacySource,
                match: classify(candidates: grouped[legacySource.id] ?? []),
                entryCount: entries.count,
                entriesWithProgress: entries.filter(\.hasReadingProgress).count
            )
        }.sorted { lhs, rhs in
            if lhs.legacySource.order != rhs.legacySource.order {
                return lhs.legacySource.order < rhs.legacySource.order
            }
            return lhs.legacySource.id < rhs.legacySource.id
        }

        let knownIDs = Set(legacySources.map(\.id))
        let orphans = scan.summary.referencedSourceIDs.filter { !knownIDs.contains($0) }
        return KanzenAidokuMigrationPlan(sources: sources, orphanSourceIDs: orphans.sorted())
    }

    static func classify(
        candidates: [ReaderExtensionLegacyReconnectCandidate]
    ) -> KanzenAidokuSourceMatch {
        guard !candidates.isEmpty else { return .unmatched }
        let scored = candidates.map { score($0) }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.installedSource.sortIndex < rhs.installedSource.sortIndex
        }
        let eligible = scored.filter { isEligibleForAutomaticReconnect($0) }
        guard let best = eligible.first else { return .ambiguous(scored) }
        let tied = eligible.filter { $0.score == best.score }
        guard tied.count == 1 else { return .ambiguous(scored) }
        return .confident(best)
    }

    static func isEligibleForAutomaticReconnect(_ scored: KanzenAidokuScoredCandidate) -> Bool {
        scored.hasAuthoritativeEvidence
            && scored.candidate.matchesLanguage
            && scored.installedSource.mediaType == .manga
            && scored.installedSource.enabled
            && scored.installedSource.isRunnable
    }

    static func score(
        _ candidate: ReaderExtensionLegacyReconnectCandidate
    ) -> KanzenAidokuScoredCandidate {
        var evidence: [KanzenAidokuMatchEvidence] = []
        if candidate.matchesUpstreamSourceID {
            evidence.append(.upstreamSourceIdentifier)
        }
        if candidate.matchesOriginHost,
           let host = candidate.legacySource.originHost,
           !isCodeHostingHost(host) {
            evidence.append(.providerHost)
        }
        let tokens = identifierTokens(
            sourceID: candidate.legacySource.id,
            languages: candidate.legacySource.languages
        )
        if !tokens.isDisjoint(with: hostTokens(for: candidate.installedSource)) {
            evidence.append(.identifierHost)
        }
        if !tokens.isDisjoint(with: nameTokens(candidate.installedSource.name)) {
            evidence.append(.identifierAffinity)
        }
        if candidate.matchesSourceName {
            evidence.append(.sourceName)
        }
        if candidate.matchesLanguage {
            evidence.append(.language)
        }
        return KanzenAidokuScoredCandidate(
            candidate: candidate,
            evidence: evidence.sorted { $0.weight > $1.weight }
        )
    }

    static func isCodeHostingHost(_ rawValue: String) -> Bool {
        let host = canonicalHost(rawValue)
        guard !host.isEmpty else { return false }
        return codeHostingHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    }

    static func identifierTokens(sourceID: String, languages: [String]) -> Set<String> {
        let languageTokens = Set(languages.map { normalizedToken($0) })
        let separators = CharacterSet(charactersIn: ".-_ /")
        let raw = sourceID.lowercased()
            .components(separatedBy: separators)
            .map { normalizedToken($0) }
        var tokens = Set(raw.filter { isDiscriminatingToken($0) })
        tokens.subtract(languageTokens)
        let collapsed = normalizedToken(sourceID)
        if isDiscriminatingToken(collapsed), !languageTokens.contains(collapsed) {
            tokens.insert(collapsed)
        }
        return tokens
    }

    static func hostTokens(for source: ReaderExtensionInstalledSource) -> Set<String> {
        let hosts = [
            source.baseURL.host,
            source.apiURL?.host,
            source.sourceCodeURL?.host,
            source.repositoryURL.host
        ].compactMap { $0 }
        var tokens = Set<String>()
        for host in hosts where !isCodeHostingHost(host) {
            let labels = canonicalHost(host).split(separator: ".").map { normalizedToken(String($0)) }
            let meaningful = labels.filter {
                !publicSuffixLabels.contains($0) && !genericHostLabels.contains($0)
            }
            for label in meaningful where isDiscriminatingToken(label) {
                tokens.insert(label)
            }
            let joined = meaningful.joined()
            if isDiscriminatingToken(joined) { tokens.insert(joined) }
        }
        return tokens
    }

    static func nameTokens(_ name: String) -> Set<String> {
        let collapsed = normalizedToken(name)
        var tokens = Set<String>()
        if isDiscriminatingToken(collapsed) { tokens.insert(collapsed) }
        for part in name.lowercased().components(separatedBy: CharacterSet(charactersIn: " -_.")) {
            let token = normalizedToken(part)
            if isDiscriminatingToken(token) { tokens.insert(token) }
        }
        return tokens
    }

    private static func isDiscriminatingToken(_ token: String) -> Bool {
        token.count >= 4 && !genericIdentifierTokens.contains(token)
    }

    private static func normalizedToken(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func canonicalHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

struct KanzenAidokuUnavailableMark: Codable, Equatable, Hashable, Sendable, Identifiable {
    let legacyStableKey: String
    let legacySourceID: String
    var legacySourceName: String?
    var title: String?
    var libraryItemID: Int?
    var markedAt: Date
    var hasReconnectCandidate: Bool
    var lastEvaluatedAt: Date?
    /// The replacement source was asked about this title and answered that it
    /// does not have it. Offering "Reconnect" for one of these is offering an
    /// action that cannot succeed.
    var confirmedAbsentOnReplacement: Bool

    var id: String { legacyStableKey }

    private enum CodingKeys: String, CodingKey {
        case legacyStableKey
        case legacySourceID
        case legacySourceName
        case title
        case libraryItemID
        case markedAt
        case hasReconnectCandidate
        case lastEvaluatedAt
        case confirmedAbsentOnReplacement
    }

    /// Mirrors what this type's own decoder will accept, so a caller can screen
    /// a key before it is written rather than discovering the rejection on the
    /// next load.
    static func isPersistableKey(_ value: String) -> Bool {
        value.hasPrefix("aidoku:")
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 32 * 1_024
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    init(
        legacyStableKey: String,
        legacySourceID: String,
        legacySourceName: String? = nil,
        title: String? = nil,
        libraryItemID: Int? = nil,
        markedAt: Date = Date(),
        hasReconnectCandidate: Bool = false,
        lastEvaluatedAt: Date? = nil,
        confirmedAbsentOnReplacement: Bool = false
    ) {
        self.legacyStableKey = legacyStableKey
        self.legacySourceID = legacySourceID
        self.legacySourceName = Self.boundedText(legacySourceName)
        self.title = Self.boundedText(title)
        self.libraryItemID = libraryItemID
        self.markedAt = markedAt
        self.hasReconnectCandidate = hasReconnectCandidate
        self.lastEvaluatedAt = lastEvaluatedAt
        self.confirmedAbsentOnReplacement = confirmedAbsentOnReplacement
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKey = try container.decode(String.self, forKey: .legacyStableKey)
        guard Self.isValidLegacyStableKey(decodedKey) else {
            throw DecodingError.dataCorruptedError(
                forKey: .legacyStableKey,
                in: container,
                debugDescription: "Legacy Reader unavailability marks require a bounded Aidoku stable key."
            )
        }
        legacyStableKey = decodedKey
        let decodedSourceID = try container.decodeIfPresent(String.self, forKey: .legacySourceID)
            ?? Self.sourceID(inStableKey: decodedKey)
            ?? ""
        guard !decodedSourceID.isEmpty, decodedSourceID.utf8.count <= 192 else {
            throw DecodingError.dataCorruptedError(
                forKey: .legacySourceID,
                in: container,
                debugDescription: "Legacy Reader unavailability marks require a bounded source identity."
            )
        }
        legacySourceID = decodedSourceID
        legacySourceName = Self.boundedText(
            try container.decodeIfPresent(String.self, forKey: .legacySourceName)
        )
        title = Self.boundedText(try container.decodeIfPresent(String.self, forKey: .title))
        libraryItemID = try container.decodeIfPresent(Int.self, forKey: .libraryItemID)
        markedAt = try container.decodeIfPresent(Date.self, forKey: .markedAt) ?? Date()
        hasReconnectCandidate = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasReconnectCandidate
        ) ?? false
        lastEvaluatedAt = try container.decodeIfPresent(Date.self, forKey: .lastEvaluatedAt)
        confirmedAbsentOnReplacement = try container.decodeIfPresent(
            Bool.self,
            forKey: .confirmedAbsentOnReplacement
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(legacyStableKey, forKey: .legacyStableKey)
        try container.encode(legacySourceID, forKey: .legacySourceID)
        try container.encodeIfPresent(legacySourceName, forKey: .legacySourceName)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(libraryItemID, forKey: .libraryItemID)
        try container.encode(markedAt, forKey: .markedAt)
        try container.encode(hasReconnectCandidate, forKey: .hasReconnectCandidate)
        try container.encodeIfPresent(lastEvaluatedAt, forKey: .lastEvaluatedAt)
        try container.encode(confirmedAbsentOnReplacement, forKey: .confirmedAbsentOnReplacement)
    }

    static func isValidLegacyStableKey(_ value: String) -> Bool {
        value.hasPrefix("aidoku:")
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 32 * 1_024
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func sourceID(inStableKey value: String) -> String? {
        let components = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        let candidate = String(components[1])
        return candidate.isEmpty ? nil : candidate
    }

    private static func boundedText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return String(value.prefix(512))
    }
}

enum KanzenAidokuUnavailableMarkStore {
    static let storageBase = "kanzenReaderLegacyUnavailableV1"
    static let maximumMarks = 20_000

    static func storageKey(for profileID: UUID) -> String {
        ProfileScopedStorage.defaultsKey(base: storageBase, profileID: profileID)
    }

    static func load(
        from store: UserDefaults,
        profileID: UUID
    ) -> [String: KanzenAidokuUnavailableMark] {
        guard let data = store.data(forKey: storageKey(for: profileID)), !data.isEmpty else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode(
            [String: KanzenAidokuUnavailableMark].self,
            from: data
        ) else {
            ReaderLogger.shared.log(
                "KanzenAidokuMigration: unreadable unavailability marks for profile \(profileID); recomputing from saved routes",
                type: "Reader"
            )
            return [:]
        }
        return decoded
    }

    @discardableResult
    static func save(
        _ marks: [String: KanzenAidokuUnavailableMark],
        to store: UserDefaults,
        profileID: UUID
    ) -> Bool {
        let key = storageKey(for: profileID)
        guard !marks.isEmpty else {
            store.removeObject(forKey: key)
            return true
        }
        let bounded = marks.count <= maximumMarks
            ? marks
            : Dictionary(
                uniqueKeysWithValues: marks.sorted { $0.key < $1.key }.prefix(maximumMarks)
                    .map { ($0.key, $0.value) }
            )
        guard let data = try? JSONEncoder().encode(bounded) else { return false }
        store.set(data, forKey: key)
        return true
    }

    static func persistedSchemaIsValid(_ data: Data) -> Bool {
        (try? JSONDecoder().decode([String: KanzenAidokuUnavailableMark].self, from: data)) != nil
    }
}

enum KanzenAidokuItemIdentity {
    static let maximumCandidateKeys = 8

    static func canonicalKey(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: normalized), url.scheme != nil {
            return ReaderExtensionURLCanonicalizer.canonicalString(url)
        }
        return normalized
    }

    static func candidateKeys(
        for legacyKey: String,
        installedSource: ReaderExtensionInstalledSource
    ) -> [String] {
        var candidates = [legacyKey]
        if let identifier = embeddedIdentifier(in: legacyKey) {
            candidates.append(identifier)
            if canonicalSourceName(installedSource.name) == "mangadex" {
                candidates.append("/manga/\(identifier)")
            }
        }
        if let path = relativePath(in: legacyKey) {
            candidates.append(path)
            if let absolute = URL(string: path, relativeTo: installedSource.baseURL)?.absoluteString {
                candidates.append(absolute)
            }
            if let apiURL = installedSource.apiURL,
               let absolute = URL(string: path, relativeTo: apiURL)?.absoluteString {
                candidates.append(absolute)
            }
        }
        var seen = Set<String>()
        return candidates.filter { candidate in
            let canonical = canonicalKey(candidate)
            guard !canonical.isEmpty,
                  ReaderExtensionSecurityPolicy.persistableProviderContentKey(candidate) != nil else {
                return false
            }
            return seen.insert(canonical).inserted
        }.prefix(maximumCandidateKeys).map { $0 }
    }

    static func refersToSameIdentity(
        _ legacyKey: String,
        _ replacementKey: String,
        installedSource: ReaderExtensionInstalledSource
    ) -> Bool {
        let legacy = canonicalKey(legacyKey)
        let replacement = canonicalKey(replacementKey)
        if !legacy.isEmpty, legacy == replacement { return true }
        if let legacyPath = relativePath(in: legacyKey),
           let replacementPath = relativePath(in: replacementKey),
           !legacyPath.isEmpty,
           legacyPath == replacementPath {
            return true
        }
        guard let legacyIdentifier = embeddedIdentifier(in: legacyKey),
              let replacementIdentifier = embeddedIdentifier(in: replacementKey) else {
            return false
        }
        return legacyIdentifier == replacementIdentifier
    }

    static func embeddedIdentifier(in rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = URL(string: trimmed).flatMap { $0.scheme == nil ? nil : $0.path } ?? trimmed
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        if let uuid = components.first(where: { UUID(uuidString: $0) != nil }) {
            return uuid.lowercased()
        }
        if let ulid = components.first(where: isULID) {
            return ulid.uppercased()
        }
        if let numeric = components.last(where: isDurableNumericIdentifier) {
            return numeric
        }
        return nil
    }

    static func relativePath(in rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? nil : path
    }

    private static func isULID(_ value: String) -> Bool {
        guard value.count == 26 else { return false }
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return value.uppercased().allSatisfy(alphabet.contains)
    }

    private static func isDurableNumericIdentifier(_ value: String) -> Bool {
        value.count >= 4 && value.count <= 20 && value.allSatisfy(\.isNumber)
    }

    private static func canonicalSourceName(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

@MainActor
enum KanzenAidokuItemVerification {
    static func verify(
        _ legacyItem: ReaderExtensionLegacyItemReference,
        against installedSource: ReaderExtensionInstalledSource
    ) async throws -> ReaderExtensionLegacyItemVerification {
        guard installedSource.enabled, installedSource.isRunnable else {
            throw ReaderExtensionError.sourceNotFound
        }
        let provider = try ReaderExtensionManager.shared.provider(for: installedSource.id)
        var sourceStoppedAnswering = false
        for candidateKey in KanzenAidokuItemIdentity.candidateKeys(
            for: legacyItem.legacyItemKey,
            installedSource: installedSource
        ) {
            do {
                let detail = try await provider.detail(itemKey: candidateKey)
                guard carriesARealTitle(detail.title, for: candidateKey),
                      KanzenAidokuItemIdentity.refersToSameIdentity(
                        legacyItem.legacyItemKey,
                        detail.key,
                        installedSource: installedSource
                      ) else { continue }
                return .resolved(detail.key)
            } catch {
                if sourceCannotAnswer(error) { sourceStoppedAnswering = true }
                continue
            }
        }
        return sourceStoppedAnswering ? .interrupted : .absent
    }

    /// A JavaScript source that returns no link for a title makes `detail.key`
    /// fall back to the key that was asked for, which makes the identity check
    /// agree with itself. A non-empty title is then the only real evidence, so
    /// a page that echoes the key back as its title is not evidence at all. No
    /// real title is its own URL slug, so rejecting that shape cannot lose a
    /// title that exists.
    nonisolated static func carriesARealTitle(_ title: String, for candidateKey: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalizedTitle = KanzenAidokuItemIdentity.canonicalKey(trimmed)
        guard !normalizedTitle.isEmpty else { return false }
        if normalizedTitle == KanzenAidokuItemIdentity.canonicalKey(candidateKey) { return false }
        let lastComponent = candidateKey
            .split(separator: "/")
            .last
            .map(String.init) ?? candidateKey
        return normalizedTitle != KanzenAidokuItemIdentity.canonicalKey(lastComponent)
    }

    /// Separates "this source is not answering right now" from "this source
    /// answered and does not have the title". Only the first may stop a sweep;
    /// treating both alike is what let one rate limit discard every title that
    /// had already matched. An unrecognised failure counts as a real answer,
    /// because the realistic unknown is an extension throwing on a key it does
    /// not know — and a wrong guess there costs one title marked unavailable
    /// and rechecked in a week, not a migration that can never finish.
    nonisolated static func sourceCannotAnswer(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError {
            return urlError.code != .unsupportedURL && urlError.code != .badURL
        }
        guard let readerError = error as? ReaderExtensionError else { return false }
        switch readerError {
        case .runtimeTimedOut,
             .runtimeUnavailable,
             .sourceQuarantined,
             .runtimeIntegrityFailed,
             .browserVerificationRequired,
             .domainConsentRequired,
             .persistenceFailed:
            return true
        case .runtimeFailed(let message):
            return messageDescribesAnUnreachableSource(message)
        case .invalidRepositoryURL,
             .invalidManifest,
             .sourceNotFound,
             .unsupportedSource,
             .restrictiveLicense,
             .unknownLicenseNeedsConsent,
             .updateConsentRequired,
             .insecureURL,
             .privateNetworkDestination,
             .contentTooLarge,
             .unsupportedArchive,
             .invalidScriptEncoding,
             .prohibitedScriptConstruct,
             .resultInvalid:
            return false
        }
    }

    nonisolated private static let unreachableSourceMarkers = [
        "429",
        "too many requests",
        "rate limit",
        "503",
        "502",
        "504",
        "timed out",
        "timeout",
        "offline",
        "network connection",
        "could not connect",
        "connection lost",
        "cloudflare"
    ]

    nonisolated private static func messageDescribesAnUnreachableSource(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return unreachableSourceMarkers.contains { lowercased.contains($0) }
    }
}

struct KanzenAidokuMigrationProgress: Equatable, Sendable {
    let legacySourceID: String
    let legacySourceName: String
    let checked: Int
    let total: Int
    let resolved: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(checked) / Double(total)))
    }
}

struct KanzenAidokuMigrationOutcome: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case idle
        case completed
        case blockedByKidsMode
        case blockedByUnreadableStore
        case alreadyRunning
    }

    struct Failure: Equatable, Sendable {
        let legacySourceID: String
        let message: String
        /// Verified titles were saved, so the same run repeated makes progress
        /// instead of starting over. The prompt says "Try Again" rather than
        /// reporting the source as permanently unmigratable.
        let isResumable: Bool

        init(legacySourceID: String, message: String, isResumable: Bool = false) {
            self.legacySourceID = legacySourceID
            self.message = message
            self.isResumable = isResumable
        }
    }

    var status: Status = .idle
    var reconnectedSourceIDs: [String] = []
    var reconnectedItemCount = 0
    var retainedItemCount = 0
    var failures: [Failure] = []
    var markedEntryCount = 0
    var clearedMarkCount = 0

    static let idle = KanzenAidokuMigrationOutcome()

    var didChangeAnything: Bool {
        !reconnectedSourceIDs.isEmpty || markedEntryCount > 0 || clearedMarkCount > 0
    }

    var hasResumableFailure: Bool { failures.contains { $0.isResumable } }
}

struct KanzenAidokuMigrationEnvironment {
    var servicesStore: () -> UserDefaults = { ProfileSettingsStore.services }
    var markStore: () -> UserDefaults = { .standard }
    var activeProfileID: () -> UUID = { ProfileManager.shared.activeProfileID }
    var isProfileStillActive: (UUID) -> Bool = { ProfileManager.shared.isStillActive($0) }
    var isKidsModeActive: () -> Bool = { ProfileManager.shared.isKidsModeActive }
    var libraryData: (UUID) -> Data? = {
        UserDefaults.standard.data(forKey: MangaLibraryManager.storageKey(for: $0))
    }
    var progressData: (UUID) -> Data? = {
        UserDefaults.standard.data(forKey: MangaReadingProgressManager.storageKey(for: $0))
    }
    var installedSources: @MainActor () -> [ReaderExtensionInstalledSource] = {
        ReaderExtensionManager.shared.installedSources
    }
    var verifyItemKey: ReaderExtensionLegacyReconnectManager.ItemKeyVerifier = { item, source in
        try await KanzenAidokuItemVerification.verify(item, against: source)
    }
    /// Applying is always an explicit, confirmed action here, so it may commit
    /// the titles that matched and leave the rest as legacy routes. The
    /// unattended strong-match path in Reader Sources deliberately keeps the
    /// all-or-nothing default instead.
    var reconnect: @MainActor (
        String,
        ReaderExtensionInstalledSource,
        UserDefaults,
        ReaderExtensionReconnectLedgerStore.Handle,
        ReaderExtensionLegacyReconnectManager.ReconnectProgressObserver?,
        ReaderExtensionLegacyReconnectManager.ItemKeyVerifier
    ) async throws -> ReaderExtensionLegacyReconnectReport = {
        legacySourceID, installedSource, store, ledger, progress, verify in
        try await ReaderExtensionLegacyReconnectManager.reconnect(
            legacySourceID: legacySourceID,
            to: installedSource,
            servicesStore: store,
            unresolvedItems: .retain,
            ledger: ledger,
            progress: progress,
            verifyItemKey: verify
        )
    }

    static let live = KanzenAidokuMigrationEnvironment()
}

@MainActor
final class KanzenAidokuMigrationCoordinator: ObservableObject {
    static let shared = KanzenAidokuMigrationCoordinator()

    enum Phase: Equatable {
        case idle
        case detecting
        case applying
    }

    static let promptDismissedKey = "kanzenAidokuMigrationPromptDismissedV1"

    @Published private(set) var summary: KanzenAidokuMigrationSummary = .empty
    @Published private(set) var plan: KanzenAidokuMigrationPlan = .empty
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var unavailableMarks: [String: KanzenAidokuUnavailableMark] = [:]
    @Published private(set) var unavailableLibraryItemIDs: Set<Int> = []
    @Published private(set) var lastOutcome: KanzenAidokuMigrationOutcome = .idle
    @Published private(set) var applyProgress: KanzenAidokuMigrationProgress?

    private let environment: KanzenAidokuMigrationEnvironment
    private var scan: KanzenAidokuLeftoverScan = .empty
    private var scanOwner: UUID?
    private var isApplying = false

    init(environment: KanzenAidokuMigrationEnvironment = .live) {
        self.environment = environment
    }

    var isKidsModeActive: Bool { environment.isKidsModeActive() }

    var promptWasDismissed: Bool {
        environment.servicesStore().bool(forKey: Self.promptDismissedKey)
    }

    var shouldOfferMigrationPrompt: Bool {
        !isKidsModeActive && summary.hasLeftoverData && !promptWasDismissed
    }

    var canOpenMigrationFromSettings: Bool {
        !isKidsModeActive && (summary.hasLeftoverData || !unavailableMarks.isEmpty)
    }

    func dismissMigrationPrompt() {
        environment.servicesStore().set(true, forKey: Self.promptDismissedKey)
        objectWillChange.send()
    }

    func restoreMigrationPrompt() {
        environment.servicesStore().removeObject(forKey: Self.promptDismissedKey)
        objectWillChange.send()
    }

    func mark(forLegacyStableKey key: String) -> KanzenAidokuUnavailableMark? {
        unavailableMarks[key]
    }

    func mark(for route: MangaContentRoute?) -> KanzenAidokuUnavailableMark? {
        guard let route, case .aidoku = route else { return nil }
        return unavailableMarks[route.stableKey]
    }

    func mark(for item: MangaLibraryItem) -> KanzenAidokuUnavailableMark? {
        if let route = item.route, let found = mark(for: route) { return found }
        return unavailableLibraryItemIDs.contains(item.id)
            ? unavailableMarks.values.first { $0.libraryItemID == item.id }
            : nil
    }

    func isLegacySourceUnavailable(_ item: MangaLibraryItem) -> Bool {
        mark(for: item) != nil
    }

    func reconnectCandidates(forLegacySourceID sourceID: String) -> [KanzenAidokuScoredCandidate] {
        plan.sources.first { $0.id == sourceID }?.match.reviewCandidates ?? []
    }

    var legacyEntries: [KanzenAidokuLegacyEntry] { scan.entries }

    func legacyEntries(forLegacySourceID sourceID: String) -> [KanzenAidokuLegacyEntry] {
        scan.entries(forSourceID: sourceID)
    }

    @discardableResult
    func detect() async -> KanzenAidokuMigrationSummary {
        guard !environment.isKidsModeActive() else {
            resetForKidsMode()
            return .empty
        }
        let owner = environment.activeProfileID()
        phase = .detecting
        let refreshed = await refreshScanAndPlan(owner: owner)
        phase = .idle
        return refreshed.scan.summary
    }

    @discardableResult
    func detectAtLaunchIfNeeded() async -> KanzenAidokuMigrationSummary {
        guard scanOwner != environment.activeProfileID() else { return summary }
        return await detect()
    }

    @discardableResult
    func applyAutomaticMatches() async -> KanzenAidokuMigrationOutcome {
        await apply(choices: [:], includeAutomaticMatches: true)
    }

    @discardableResult
    func reconnect(
        legacySourceID: String,
        to installedSourceID: ReaderExtensionSourceID
    ) async -> KanzenAidokuMigrationOutcome {
        await apply(
            choices: [legacySourceID: installedSourceID],
            includeAutomaticMatches: false
        )
    }

    @discardableResult
    func apply(
        choices: [String: ReaderExtensionSourceID],
        includeAutomaticMatches: Bool = true
    ) async -> KanzenAidokuMigrationOutcome {
        guard !environment.isKidsModeActive() else {
            resetForKidsMode()
            return finished(.blockedByKidsMode)
        }
        guard !isApplying else {
            var outcome = KanzenAidokuMigrationOutcome.idle
            outcome.status = .alreadyRunning
            return outcome
        }
        isApplying = true
        phase = .applying
        defer {
            isApplying = false
            phase = .idle
            applyProgress = nil
        }

        let owner = environment.activeProfileID()
        let prepared = await refreshScanAndPlan(owner: owner)
        guard !prepared.scan.summary.isBlocked else {
            ReaderLogger.shared.log(
                "KanzenAidokuMigration: refused to migrate because a saved Reader store is unreadable",
                type: "Reader"
            )
            return finished(.blockedByUnreadableStore)
        }

        var outcome = KanzenAidokuMigrationOutcome.idle
        outcome.status = .completed
        var confirmedAbsent: Set<String> = []
        let servicesStore = environment.servicesStore()
        let installed = environment.installedSources()

        for sourcePlan in prepared.plan.sources {
            let target = resolvedTarget(
                for: sourcePlan,
                choices: choices,
                includeAutomaticMatches: includeAutomaticMatches,
                installedSources: installed
            )
            guard let target else { continue }
            let sourceName = sourcePlan.legacySource.name
            do {
                let report = try await environment.reconnect(
                    sourcePlan.id,
                    target,
                    servicesStore,
                    // The owner captured when this run started, never a late
                    // read of the active profile: a switch mid-sweep must not
                    // file one profile's verification cache under another.
                    ReaderExtensionReconnectLedgerStore.Handle(
                        defaults: .standard,
                        profileID: owner
                    ),
                    { [weak self] progress in
                        self?.applyProgress = KanzenAidokuMigrationProgress(
                            legacySourceID: sourcePlan.id,
                            legacySourceName: sourceName,
                            checked: progress.checked,
                            total: progress.total,
                            resolved: progress.resolved
                        )
                    },
                    environment.verifyItemKey
                )
                outcome.reconnectedSourceIDs.append(sourcePlan.id)
                outcome.reconnectedItemCount += report.itemCount
                outcome.retainedItemCount += report.retainedItemCount
                for itemKey in report.retainedItemKeys {
                    confirmedAbsent.insert(
                        ReaderExtensionAidokuMigration.legacyStableKey(
                            sourceID: sourcePlan.id,
                            itemKey: itemKey
                        )
                    )
                }
                if report.retainedItemCount > 0 {
                    ReaderLogger.shared.log(
                        "KanzenAidokuMigration: \(sourceName) reconnected \(report.itemCount) title(s); \(report.retainedItemCount) stayed unavailable on the replacement source",
                        type: "Reader"
                    )
                }
            } catch {
                let resumable = (error as? ReaderExtensionLegacyReconnectError)?.isResumable ?? false
                outcome.failures.append(
                    KanzenAidokuMigrationOutcome.Failure(
                        legacySourceID: sourcePlan.id,
                        message: error.localizedDescription,
                        isResumable: resumable
                    )
                )
                ReaderLogger.shared.log(
                    "KanzenAidokuMigration: \(sourceName) stayed unavailable: \(error.localizedDescription)",
                    type: "Reader"
                )
            }
            applyProgress = nil
        }

        let rescan = await performScan(owner: owner)
        let rescanPlan = KanzenAidokuSourceMatcher.plan(
            legacySources: rescan.legacySources,
            installedSources: installed,
            scan: rescan
        )
        let marking = writeMarks(
            owner: owner,
            scan: rescan,
            plan: rescanPlan,
            confirmedAbsent: confirmedAbsent
        )
        outcome.markedEntryCount = marking.marked
        outcome.clearedMarkCount = marking.cleared
        publish(scan: rescan, plan: rescanPlan, owner: owner, marks: marking.marks)
        lastOutcome = outcome
        return outcome
    }

    @discardableResult
    func reevaluateAfterInstalledSourcesChanged(
        automaticallyReconnect: Bool = true
    ) async -> KanzenAidokuMigrationOutcome {
        guard !environment.isKidsModeActive() else {
            resetForKidsMode()
            return finished(.blockedByKidsMode)
        }
        let owner = environment.activeProfileID()
        let prepared = await refreshScanAndPlan(owner: owner)
        guard automaticallyReconnect, !prepared.plan.confidentSources.isEmpty else {
            return await markUnavailableEntries()
        }
        return await apply(choices: [:], includeAutomaticMatches: true)
    }

    @discardableResult
    func markUnavailableEntries() async -> KanzenAidokuMigrationOutcome {
        guard !environment.isKidsModeActive() else {
            resetForKidsMode()
            return finished(.blockedByKidsMode)
        }
        let owner = environment.activeProfileID()
        let prepared = await refreshScanAndPlan(owner: owner)
        guard !prepared.scan.summary.isBlocked else {
            return finished(.blockedByUnreadableStore)
        }
        var outcome = KanzenAidokuMigrationOutcome.idle
        outcome.status = .completed
        let marking = writeMarks(
            owner: owner,
            scan: prepared.scan,
            plan: prepared.plan
        )
        outcome.markedEntryCount = marking.marked
        outcome.clearedMarkCount = marking.cleared
        publish(
            scan: prepared.scan,
            plan: prepared.plan,
            owner: owner,
            marks: marking.marks
        )
        lastOutcome = outcome
        return outcome
    }

    private func finished(_ status: KanzenAidokuMigrationOutcome.Status) -> KanzenAidokuMigrationOutcome {
        var outcome = KanzenAidokuMigrationOutcome.idle
        outcome.status = status
        lastOutcome = outcome
        return outcome
    }

    private func resolvedTarget(
        for sourcePlan: KanzenAidokuSourcePlan,
        choices: [String: ReaderExtensionSourceID],
        includeAutomaticMatches: Bool,
        installedSources: [ReaderExtensionInstalledSource]
    ) -> ReaderExtensionInstalledSource? {
        let resolved: ReaderExtensionInstalledSource?
        if let chosen = choices[sourcePlan.id] {
            resolved = installedSources.first { $0.id == chosen }
        } else if includeAutomaticMatches,
                  let confident = sourcePlan.match.confidentCandidate {
            resolved = installedSources.first { $0.id == confident.installedSource.id }
                ?? confident.installedSource
        } else {
            resolved = nil
        }
        guard let resolved, resolved.enabled, resolved.isRunnable else { return nil }
        return resolved
    }

    private func refreshScanAndPlan(
        owner: UUID
    ) async -> (scan: KanzenAidokuLeftoverScan, plan: KanzenAidokuMigrationPlan) {
        let refreshed = await performScan(owner: owner)
        let refreshedPlan = KanzenAidokuSourceMatcher.plan(
            legacySources: refreshed.legacySources,
            installedSources: environment.installedSources(),
            scan: refreshed
        )
        let marks = KanzenAidokuUnavailableMarkStore.load(
            from: environment.markStore(),
            profileID: owner
        )
        publish(scan: refreshed, plan: refreshedPlan, owner: owner, marks: marks)
        return (refreshed, refreshedPlan)
    }

    private func publish(
        scan refreshed: KanzenAidokuLeftoverScan,
        plan refreshedPlan: KanzenAidokuMigrationPlan,
        owner: UUID,
        marks: [String: KanzenAidokuUnavailableMark]
    ) {
        guard environment.isProfileStillActive(owner) else {
            ReaderLogger.shared.log(
                "KanzenAidokuMigration: withheld a stale migration summary because the active profile changed",
                type: "Reader"
            )
            return
        }
        scan = refreshed
        scanOwner = owner
        summary = refreshed.summary
        plan = refreshedPlan
        unavailableMarks = marks
        unavailableLibraryItemIDs = Set(marks.values.compactMap(\.libraryItemID))
    }

    private func performScan(owner: UUID) async -> KanzenAidokuLeftoverScan {
        let legacySources = ReaderExtensionAidokuMigration.legacySources(
            in: environment.servicesStore()
        )
        let libraryData = environment.libraryData(owner)
        let progressData = environment.progressData(owner)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: KanzenAidokuLeftoverScanner.scan(
                        legacySources: legacySources,
                        libraryData: libraryData,
                        progressData: progressData
                    )
                )
            }
        }
    }

    private func writeMarks(
        owner: UUID,
        scan refreshed: KanzenAidokuLeftoverScan,
        plan refreshedPlan: KanzenAidokuMigrationPlan,
        confirmedAbsent: Set<String> = []
    ) -> (marks: [String: KanzenAidokuUnavailableMark], marked: Int, cleared: Int) {
        let store = environment.markStore()
        let existing = KanzenAidokuUnavailableMarkStore.load(from: store, profileID: owner)
        guard !refreshed.summary.isBlocked else { return (existing, 0, 0) }

        let sourceNames = Dictionary(
            refreshed.legacySources.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let candidateSourceIDs = Set(
            refreshedPlan.sources.filter { $0.match.hasCandidate }.map(\.id)
        )

        var updated: [String: KanzenAidokuUnavailableMark] = [:]
        var marked = 0
        for entry in refreshed.entries {
            // The old scraper's identifiers are unvalidated, so a stable key
            // built from them can carry whitespace or control characters that
            // this store's own decoder refuses. Persisting one writes a blob
            // that fails to load on the next launch, taking every other mark
            // with it. Skip what cannot round-trip rather than poison the file.
            guard KanzenAidokuUnavailableMark.isPersistableKey(entry.legacyStableKey) else {
                ReaderLogger.shared.log(
                    "KanzenAidokuMigration: skipped an unavailability mark whose legacy key cannot round-trip",
                    type: "ReaderExtensionHome"
                )
                continue
            }
            let previous = existing[entry.legacyStableKey]
            if previous == nil { marked += 1 }
            updated[entry.legacyStableKey] = KanzenAidokuUnavailableMark(
                legacyStableKey: entry.legacyStableKey,
                legacySourceID: entry.legacySourceID,
                legacySourceName: sourceNames[entry.legacySourceID],
                title: entry.title,
                libraryItemID: entry.libraryItemID,
                markedAt: previous?.markedAt ?? Date(),
                hasReconnectCandidate: candidateSourceIDs.contains(entry.legacySourceID),
                lastEvaluatedAt: previous?.lastEvaluatedAt,
                // Once a replacement source has said it does not carry a title,
                // that answer stands until the user reconnects the source to a
                // different one; a later pass must not quietly downgrade it back
                // to "not tried yet".
                confirmedAbsentOnReplacement: confirmedAbsent.contains(entry.legacyStableKey)
                    || previous?.confirmedAbsentOnReplacement == true
            )
        }

        guard updated != existing else { return (existing, 0, 0) }
        let cleared = existing.keys.filter { updated[$0] == nil }.count
        guard KanzenAidokuUnavailableMarkStore.save(updated, to: store, profileID: owner) else {
            ReaderLogger.shared.log(
                "KanzenAidokuMigration: could not persist unavailability marks for profile \(owner); saved titles are unchanged",
                type: "Error"
            )
            return (existing, 0, 0)
        }
        return (updated, marked, cleared)
    }

    private func resetForKidsMode() {
        scan = .empty
        scanOwner = nil
        summary = .empty
        plan = .empty
        unavailableMarks = [:]
        unavailableLibraryItemIDs = []
    }
}
#endif
