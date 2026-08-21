// Copyright 2026 Eclipse contributors
// SPDX-License-Identifier: Apache-2.0

#if !os(tvOS)
import CryptoKit
import Foundation

enum ReaderExtensionCompatibilityClassification: String, Codable, Hashable, Sendable {
    case certified
    case runtimeCompatible
    case limited
    case failed

    var displayName: String {
        switch self {
        case .certified: return "Certified"
        case .runtimeCompatible: return "Runtime Passed"
        case .limited: return "Limited"
        case .failed: return "Failed"
        }
    }
}

enum ReaderExtensionCompatibilityCheckState: String, Codable, Hashable, Sendable {
    case passed
    case warning
    case failed
    case skipped
}

enum ReaderExtensionCompatibilityCheckKind: String, Codable, CaseIterable, Hashable, Sendable {
    case admission
    case filters
    case filterStateShape
    case preferences
    case resourceHeaders
    case popular
    case latest
    case search
    case pagination
    case detail
    case chapters
    case pages
    case firstPageImage

    var displayName: String {
        switch self {
        case .admission: return "Runtime admission"
        case .filters: return "Advanced filters"
        case .filterStateShape: return "Filter state shape"
        case .preferences: return "Source preferences"
        case .resourceHeaders: return "Image headers"
        case .popular: return "Popular"
        case .latest: return "Latest updates"
        case .search: return "Search"
        case .pagination: return "Pagination"
        case .detail: return "Manga details"
        case .chapters: return "Chapters"
        case .pages: return "Page resolution"
        case .firstPageImage: return "Page image"
        }
    }
}

struct ReaderExtensionCompatibilityCheck: Codable, Hashable, Identifiable, Sendable {
    var id: String { kind.rawValue }
    let kind: ReaderExtensionCompatibilityCheckKind
    let state: ReaderExtensionCompatibilityCheckState
    let required: Bool
    let summary: String

    init(
        kind: ReaderExtensionCompatibilityCheckKind,
        state: ReaderExtensionCompatibilityCheckState,
        required: Bool,
        summary: String
    ) {
        self.kind = kind
        self.state = state
        self.required = required
        self.summary = String(summary.prefix(160))
    }
}

enum ReaderExtensionSiteParity: String, Codable, Hashable, Sendable {
    case verified
    case knownLimitations
    case notAudited

    var displayName: String {
        switch self {
        case .verified: return "Verified against the live catalog"
        case .knownLimitations: return "Known upstream catalog limitations"
        case .notAudited: return "Live-site parity not audited"
        }
    }
}

struct ReaderExtensionFilterSchemaSummary: Codable, Hashable, Sendable {
    static let maximumRows = 10_000

    let topLevelCount: Int
    let flattenedCount: Int
    let countsByKind: [String: Int]
    let normalizedTitles: Set<String>

    init(filters: [ReaderExtensionFilter]) {
        var count = 0
        var kindCounts: [String: Int] = [:]
        var titles = Set<String>()

        func visit(_ rows: [ReaderExtensionFilter], depth: Int) {
            guard depth < 8, count < Self.maximumRows else { return }
            for row in rows.prefix(200) {
                guard count < Self.maximumRows else { break }
                count += 1
                kindCounts[row.kind.rawValue, default: 0] += 1
                let title = Self.normalize(row.title)
                if !title.isEmpty { titles.insert(title) }
                visit(row.children, depth: depth + 1)
            }
        }

        visit(filters, depth: 0)
        topLevelCount = min(filters.count, 200)
        flattenedCount = count
        countsByKind = kindCounts
        normalizedTitles = titles
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
            .reduce(into: "") { partialResult, character in
                if character == " ", partialResult.last == " " { return }
                partialResult.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ReaderExtensionFilterStateShapeIssue: String, Hashable, Sendable {
    case rowLimitExceeded
    case depthLimitExceeded
    case siblingLimitExceeded
    case optionLimitExceeded
    case invalidKey
    case duplicateSiblingKey
    case duplicateOptionValue
    case invalidValueKind
    case invalidSelection
    case missingSortDirection
    case unexpectedSortDirection

    var summary: String {
        switch self {
        case .rowLimitExceeded: return "too many controls"
        case .depthLimitExceeded: return "nesting is too deep"
        case .siblingLimitExceeded: return "too many sibling controls"
        case .optionLimitExceeded: return "too many options"
        case .invalidKey: return "invalid control key"
        case .duplicateSiblingKey: return "duplicate sibling keys"
        case .duplicateOptionValue: return "duplicate option values"
        case .invalidValueKind: return "state type does not match control kind"
        case .invalidSelection: return "selected option is unavailable"
        case .missingSortDirection: return "sort direction is missing"
        case .unexpectedSortDirection: return "non-sort control carries sort direction"
        }
    }
}

struct ReaderExtensionFilterStateShapeValidation: Hashable, Sendable {
    let flattenedCount: Int
    let statefulCount: Int
    let issues: Set<ReaderExtensionFilterStateShapeIssue>

    var isValid: Bool { issues.isEmpty }

    func check(required: Bool) -> ReaderExtensionCompatibilityCheck {
        if isValid {
            return ReaderExtensionCompatibilityCheck(
                kind: .filterStateShape,
                state: .passed,
                required: required,
                summary: "\(statefulCount) stateful controls have bounded local round-trip shapes; live-site parity is not asserted"
            )
        }
        let details = issues
            .sorted { $0.rawValue < $1.rawValue }
            .prefix(3)
            .map(\.summary)
            .joined(separator: ", ")
        return ReaderExtensionCompatibilityCheck(
            kind: .filterStateShape,
            state: required ? .failed : .warning,
            required: required,
            summary: "Local state shape is not round-trippable: \(details)"
        )
    }
}

/// Pure, bounded validation of Eclipse's parsed filter model. This proves only
/// that the controls can be rendered and their local state can be represented
/// without losing shape. It never compares the extension with a live site and
/// therefore cannot establish catalog parity or certification.
enum ReaderExtensionFilterStateShapeValidator {
    static let maximumRows = ReaderExtensionFilterSchemaSummary.maximumRows
    static let maximumDepth = 8
    static let maximumSiblings = 200
    static let maximumOptions = 200
    private static let maximumKeyBytes = 1_024

    static func validate(_ filters: [ReaderExtensionFilter]) -> ReaderExtensionFilterStateShapeValidation {
        var flattenedCount = 0
        var statefulCount = 0
        var issues = Set<ReaderExtensionFilterStateShapeIssue>()

        func selectedOptionIsValid(_ filter: ReaderExtensionFilter) -> Bool {
            guard !filter.options.isEmpty else { return false }
            switch filter.value {
            case .string(let value):
                return filter.options.contains { $0.value == value }
            case .number(let value):
                guard value.isFinite,
                      value.rounded(.towardZero) == value,
                      value >= 0,
                      value < Double(filter.options.count) else { return false }
                return filter.options.indices.contains(Int(value))
            default:
                return false
            }
        }

        func valueKindIsValid(_ filter: ReaderExtensionFilter) -> Bool {
            switch (filter.kind, filter.value) {
            case (.text, .string), (.text, .bool), (.text, .stringList):
                return true
            case (.text, .number(let value)):
                return value.isFinite
            case (.toggle, .bool):
                return true
            case (.triState, .number(let value)):
                return value.isFinite
                    && value.rounded(.towardZero) == value
                    && (value == 0 || value == 1 || value == 2)
            case (.select, _), (.sort, _):
                return selectedOptionIsValid(filter)
            case (.group, _), (.header, _), (.separator, _):
                return true
            default:
                return false
            }
        }

        func visit(_ rows: [ReaderExtensionFilter], depth: Int) {
            guard depth < maximumDepth else {
                if !rows.isEmpty { issues.insert(.depthLimitExceeded) }
                return
            }
            if rows.count > maximumSiblings { issues.insert(.siblingLimitExceeded) }
            let boundedRows = rows.prefix(maximumSiblings)
            let keys = boundedRows.map(\.key)
            if Set(keys).count != keys.count { issues.insert(.duplicateSiblingKey) }

            for filter in boundedRows {
                guard flattenedCount < maximumRows else {
                    issues.insert(.rowLimitExceeded)
                    break
                }
                flattenedCount += 1
                if filter.kind != .group && filter.kind != .header && filter.kind != .separator {
                    statefulCount += 1
                }
                if filter.key.isEmpty || filter.key.utf8.count > maximumKeyBytes {
                    issues.insert(.invalidKey)
                }
                if filter.options.count > maximumOptions { issues.insert(.optionLimitExceeded) }
                let optionValues = filter.options.prefix(maximumOptions).map(\.value)
                if Set(optionValues).count != optionValues.count {
                    issues.insert(.duplicateOptionValue)
                }
                if !valueKindIsValid(filter) { issues.insert(.invalidValueKind) }
                if (filter.kind == .select || filter.kind == .sort), !selectedOptionIsValid(filter) {
                    issues.insert(.invalidSelection)
                }
                if filter.kind == .sort, filter.sortAscending == nil {
                    issues.insert(.missingSortDirection)
                } else if filter.kind != .sort, filter.sortAscending != nil {
                    issues.insert(.unexpectedSortDirection)
                }
                visit(filter.children, depth: depth + 1)
                if flattenedCount >= maximumRows { break }
            }
            if rows.count > maximumSiblings {
                // Rows after the bounded prefix were deliberately not visited.
                issues.insert(.rowLimitExceeded)
            }
        }

        visit(filters, depth: 0)
        return ReaderExtensionFilterStateShapeValidation(
            flattenedCount: flattenedCount,
            statefulCount: statefulCount,
            issues: issues
        )
    }
}

struct ReaderExtensionCompatibilityReport: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(profileID.uuidString):\(sourceID.rawValue)" }

    let sourceID: ReaderExtensionSourceID
    let profileID: UUID
    let sourceName: String
    let sourceVersion: String
    let sourceRevision: String
    let checkedAt: Date
    let classification: ReaderExtensionCompatibilityClassification
    let checks: [ReaderExtensionCompatibilityCheck]
    let filterSchema: ReaderExtensionFilterSchemaSummary?
    let siteParity: ReaderExtensionSiteParity
    let siteParityNotes: [String]

    var passedCount: Int { checks.filter { $0.state == .passed }.count }
    var failedCount: Int { checks.filter { $0.state == .failed }.count }
}

struct ReaderExtensionCompatibilitySpecification: Hashable, Sendable {
    let minimumTopLevelFilters: Int
    let minimumFlattenedFilters: Int
    let requiredFilterKinds: Set<ReaderExtensionFilterKind>
    let requiredFilterTitles: Set<String>
    let siteParity: ReaderExtensionSiteParity
    let notes: [String]

    func check(schema: ReaderExtensionFilterSchemaSummary) -> ReaderExtensionCompatibilityCheck {
        let missingKinds = requiredFilterKinds.filter {
            schema.countsByKind[$0.rawValue, default: 0] == 0
        }
        let missingTitles = requiredFilterTitles.subtracting(schema.normalizedTitles)
        let countMatches = schema.topLevelCount >= minimumTopLevelFilters
            && schema.flattenedCount >= minimumFlattenedFilters

        guard countMatches, missingKinds.isEmpty, missingTitles.isEmpty else {
            var reasons: [String] = []
            if !countMatches {
                reasons.append("expected at least \(minimumTopLevelFilters)/\(minimumFlattenedFilters), received \(schema.topLevelCount)/\(schema.flattenedCount)")
            }
            if !missingKinds.isEmpty { reasons.append("missing filter kinds") }
            if !missingTitles.isEmpty { reasons.append("missing expected controls") }
            return ReaderExtensionCompatibilityCheck(
                kind: .filters,
                state: .failed,
                required: true,
                summary: reasons.joined(separator: "; ")
            )
        }

        return ReaderExtensionCompatibilityCheck(
            kind: .filters,
            state: .passed,
            required: true,
            summary: "\(schema.topLevelCount) groups · \(schema.flattenedCount) controls"
        )
    }
}

enum ReaderExtensionCompatibilitySpecifications {
    static func specification(for source: ReaderExtensionInstalledSource) -> ReaderExtensionCompatibilitySpecification? {
        guard source.implementation == .javascript,
              let codeURL = source.sourceCodeURL,
              codeURL.host?.lowercased() == "raw.githubusercontent.com" else {
            return nil
        }

        let path = codeURL.path.lowercased()
        let name = ReaderExtensionFilterSchemaSummary.normalize(source.name)

        if name == "mangadex", source.version == "0.1.4", path.hasSuffix("/javascript/manga/src/all/mangadex.js") {
            return ReaderExtensionCompatibilitySpecification(
                minimumTopLevelFilters: 11,
                minimumFlattenedFilters: 102,
                requiredFilterKinds: [.toggle, .select, .triState, .sort, .group],
                requiredFilterTitles: normalized([
                    "Has available chapters", "Original language", "Content rating", "Publication demographic",
                    "Status", "Sort", "Tags mode", "Content", "Format", "Genre", "Theme"
                ]),
                siteParity: .knownLimitations,
                notes: [
                    "The parsed v0.1.4 schema has 11 groups and 102 controls with the exact MangaDex extension labels.",
                    "Its tag catalog is missing Incest and Mahjong and labels Self-Published with the stale name User Created.",
                    "Its ContentsFilter renders Gore and Sexual Violence, but the extension's search implementation ignores that group."
                ]
            )
        }

        if name == "weeb central", source.version == "0.1.0", path.hasSuffix("/javascript/manga/src/en/weebcentral.js") {
            return ReaderExtensionCompatibilitySpecification(
                minimumTopLevelFilters: 6,
                minimumFlattenedFilters: 51,
                requiredFilterKinds: [.select, .toggle, .group],
                requiredFilterTitles: normalized([
                    "Sort", "Order", "Official Translation", "Series Status", "Series Type", "Tags"
                ]),
                siteParity: .knownLimitations,
                notes: [
                    "The v0.1.0 extension exposes 6 filter groups and 37 tags; the current site exposes 9 groups and 38 tags.",
                    "The extension hard-codes an empty author and supports inclusion only, so author and exclusion filters cannot round-trip."
                ]
            )
        }

        if name == "asura scans", source.version == "0.2.14", path.hasSuffix("/javascript/manga/src/en/asurascans.js") {
            return ReaderExtensionCompatibilitySpecification(
                minimumTopLevelFilters: 5,
                minimumFlattenedFilters: 35,
                requiredFilterKinds: [.select, .toggle, .group],
                requiredFilterTitles: normalized(["Sort By", "Sort Order", "Status", "Type", "Genres"]),
                siteParity: .knownLimitations,
                notes: [
                    "The v0.2.14 extension exposes 5 filter groups and 30 genres; the current catalog exposes 33 genres.",
                    "Creator and minimum-chapter controls are absent, so those catalog filters cannot round-trip through Eclipse."
                ]
            )
        }

        return nil
    }

    private static func normalized(_ values: [String]) -> Set<String> {
        Set(values.map(ReaderExtensionFilterSchemaSummary.normalize))
    }
}

struct ReaderExtensionCompatibilityRevision {
    // Increment whenever the checker changes which operations or dependencies
    // establish a result. This invalidates derived reports produced by an older
    // host contract without mutating the installed source.
    private static let hostContractRevision = "reader-extension-compatibility-v2"
    private static let nativeAdapterRevision = "native-adapters-v1"

    static func value(
        source: ReaderExtensionInstalledSource,
        profileID: UUID,
        approvedDomains: Set<String>
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let preferences = (try? encoder.encode(source.preferences)) ?? Data()
        let runtimeIdentity = ReaderExtensionLanguageCompatibilityPolicy.runtimeIdentity(for: source)
        let fields = [
            hostContractRevision,
            profileID.uuidString.lowercased(),
            source.id.rawValue,
            runtimeIdentity.upstreamID,
            runtimeIdentity.language,
            runtimeIdentity.isCompatibilityRepair ? "compatibility-repair" : "declared-identity",
            source.languageSelectionVersion.map(String.init) ?? "legacy-language-selection",
            source.version,
            source.activeContentDigest ?? "native",
            source.activeContentDigest == nil ? nativeAdapterRevision : "javascript",
            source.codeProvenanceFingerprint,
            source.implementation.rawValue,
            source.preferenceSchemaFingerprint ?? "",
            source.runtimeCapabilities.map(\ReaderExtensionCapability.rawValue).sorted().joined(separator: ","),
            ReaderExtensionSecurityPolicy.canonicalHosts(approvedDomains).sorted().joined(separator: ","),
            source.enabled ? "enabled" : "disabled",
            source.isRunnable ? "runnable" : "unavailable"
        ].joined(separator: "\u{1e}")
        var material = Data(fields.utf8)
        material.append(preferences)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class ReaderExtensionCompatibilityStore: ObservableObject {
    static let shared = ReaderExtensionCompatibilityStore()

    private static let maximumReports = 512
    private static let maximumStoredBytes = 2 * 1_024 * 1_024
    private static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    @Published private(set) var reports: [String: ReaderExtensionCompatibilityReport]
    private let fileURL: URL
    private var observers: [NSObjectProtocol] = []

    init(fileURL: URL? = nil, observesRuntimeChanges: Bool = true) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        reports = Self.load(from: self.fileURL)
        if observesRuntimeChanges {
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: .readerExtensionAuthenticationDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let sourceID = notification.object as? ReaderExtensionSourceID else { return }
                Task { @MainActor in self?.invalidate(sourceID: sourceID) }
            })
            observers.append(center.addObserver(
                forName: .readerExtensionResourceHeadersDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    if let sourceID = notification.object as? ReaderExtensionSourceID {
                        self?.invalidate(sourceID: sourceID)
                    } else {
                        self?.removeAll()
                    }
                }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func currentReport(
        for source: ReaderExtensionInstalledSource,
        profileID: UUID,
        approvedDomains: Set<String>
    ) -> ReaderExtensionCompatibilityReport? {
        guard let report = reports[key(profileID: profileID, sourceID: source.id)],
              Date().timeIntervalSince(report.checkedAt) <= Self.maximumAge,
              report.sourceRevision == ReaderExtensionCompatibilityRevision.value(
                source: source,
                profileID: profileID,
                approvedDomains: approvedDomains
              ) else {
            return nil
        }
        return report
    }

    func latestReport(
        sourceID: ReaderExtensionSourceID,
        profileID: UUID
    ) -> ReaderExtensionCompatibilityReport? {
        reports[key(profileID: profileID, sourceID: sourceID)]
    }

    func save(_ report: ReaderExtensionCompatibilityReport) {
        reports[report.id] = report
        pruneAndPersist()
    }

    func invalidate(sourceID: ReaderExtensionSourceID) {
        reports = reports.filter { $0.value.sourceID != sourceID }
        persist()
    }

    func removeAll() {
        reports.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func pruneAndPersist() {
        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
        let retained = reports.values
            .filter { $0.checkedAt >= cutoff }
            .sorted { $0.checkedAt > $1.checkedAt }
            .prefix(Self.maximumReports)
        reports = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(reports), data.count <= Self.maximumStoredBytes else {
            reports.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var directoryCopy = directory
            try directoryCopy.setResourceValues(directoryValues)
            var fileValues = URLResourceValues()
            fileValues.isExcludedFromBackup = true
            var fileCopy = fileURL
            try fileCopy.setResourceValues(fileValues)
        } catch {
            // Compatibility evidence is derived and fail-open. A storage
            // failure must never disable or mutate the installed source.
        }
    }

    private static func load(from fileURL: URL) -> [String: ReaderExtensionCompatibilityReport] {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              data.count <= maximumStoredBytes,
              let decoded = try? JSONDecoder().decode(
                [String: ReaderExtensionCompatibilityReport].self,
                from: data
              ),
              decoded.count <= maximumReports else {
            return [:]
        }
        return decoded.filter { key, report in key == report.id }
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return support
            .appendingPathComponent("ReaderExtensions", isDirectory: true)
            .appendingPathComponent("Compatibility", isDirectory: true)
            .appendingPathComponent("reports-v1.json", isDirectory: false)
    }

    private func key(profileID: UUID, sourceID: ReaderExtensionSourceID) -> String {
        "\(profileID.uuidString):\(sourceID.rawValue)"
    }
}

struct ReaderExtensionCompatibilityRunner {
    typealias PageImageProbe = ([ReaderExtensionPage]) async throws -> String

    static func run(
        provider: any ReaderSourceProvider,
        profileID: UUID,
        approvedDomains: Set<String>,
        pageImageProbe: PageImageProbe
    ) async -> ReaderExtensionCompatibilityReport {
        let source = provider.source
        let revision = ReaderExtensionCompatibilityRevision.value(
            source: source,
            profileID: profileID,
            approvedDomains: approvedDomains
        )
        let specification = ReaderExtensionCompatibilitySpecifications.specification(for: source)
        var checks: [ReaderExtensionCompatibilityCheck] = [
            .init(kind: .admission, state: .passed, required: true, summary: "Validated executable admitted")
        ]
        var schema: ReaderExtensionFilterSchemaSummary?
        var candidateFeeds: [[ReaderExtensionItem]] = []

        let filterResult = await attempt(kind: .filters, required: false) {
            try await provider.filters()
        }
        if let filters = filterResult.value {
            let summary = ReaderExtensionFilterSchemaSummary(filters: filters)
            schema = summary
            if let specification {
                checks.append(specification.check(schema: summary))
            } else {
                checks.append(.init(
                    kind: .filters,
                    state: filters.isEmpty ? .warning : .passed,
                    required: false,
                    summary: filters.isEmpty
                        ? "Source exposes no advanced filters"
                        : "\(summary.topLevelCount) groups · \(summary.flattenedCount) controls"
                ))
            }
            if filters.isEmpty {
                checks.append(.init(
                    kind: .filterStateShape,
                    state: .skipped,
                    required: specification != nil,
                    summary: "No filter state was available to validate"
                ))
            } else {
                checks.append(
                    ReaderExtensionFilterStateShapeValidator
                        .validate(filters)
                        .check(required: specification != nil)
                )
            }
        } else {
            checks.append(.init(
                kind: .filters,
                state: specification == nil ? .warning : .failed,
                required: specification != nil,
                summary: filterResult.check.summary
            ))
            checks.append(.init(
                kind: .filterStateShape,
                state: .skipped,
                required: specification != nil,
                summary: "Filter schema was unavailable"
            ))
        }

        if source.runtimeCapabilities.contains(.preferences) {
            checks.append(await attempt(kind: .preferences, required: false) {
                try await provider.preferences()
            }.map { "\($0.count) preference controls" }.check)
        } else {
            checks.append(.init(
                kind: .preferences,
                state: .skipped,
                required: false,
                summary: "Source exposes no preference schema"
            ))
        }

        checks.append(await attempt(kind: .resourceHeaders, required: false) {
            try await provider.resourceHeaders()
        }.map { "\($0.count) sanitized headers" }.check)

        let popular = requiringNonemptyItems(await attempt(kind: .popular, required: true) {
            try await provider.popular(page: 1)
        }.map { "\($0.items.count) items" })
        checks.append(popular.check)
        if let result = popular.value { candidateFeeds.append(result.items) }

        if source.runtimeCapabilities.contains(.latest) {
            let latest = await attempt(kind: .latest, required: false) {
                try await provider.latest(page: 1)
            }.map { "\($0.items.count) items" }
            checks.append(latest.check)
            if let result = latest.value { candidateFeeds.append(result.items) }
        } else {
            checks.append(.init(
                kind: .latest,
                state: .warning,
                required: false,
                summary: "Source falls back to its Popular feed"
            ))
        }

        let defaultFilters = filterResult.value ?? []
        let search = await attempt(kind: .search, required: true) {
            try await provider.search(query: "", page: 1, filters: defaultFilters)
        }.map { "\($0.items.count) items" }
        checks.append(search.check)
        if let result = search.value { candidateFeeds.append(result.items) }

        if let result = search.value, result.hasNextPage {
            checks.append(await attempt(kind: .pagination, required: false) {
                try await provider.search(query: "", page: 2, filters: defaultFilters)
            }.map { "Page 2 returned \($0.items.count) items" }.check)
        } else {
            checks.append(.init(
                kind: .pagination,
                state: .skipped,
                required: false,
                summary: "Source did not advertise another search page"
            ))
        }

        let seedCandidates = boundedUniqueCandidates(from: candidateFeeds)
        guard !seedCandidates.isEmpty else {
            checks.append(.init(kind: .detail, state: .skipped, required: true, summary: "Not run: no list-item dependency"))
            checks.append(.init(kind: .chapters, state: .skipped, required: true, summary: "Not run: no detail-item dependency"))
            checks.append(.init(kind: .pages, state: .skipped, required: true, summary: "Not run: no chapter dependency"))
            checks.append(.init(kind: .firstPageImage, state: .skipped, required: true, summary: "Not run: no page dependency"))
            return makeReport(
                source: source,
                profileID: profileID,
                revision: revision,
                checks: checks,
                schema: schema,
                specification: specification
            )
        }

        let contentProbe = await firstCandidateWithChapters(
            provider: provider,
            candidates: seedCandidates
        )
        checks.append(contentProbe.detailCheck)
        checks.append(contentProbe.chaptersCheck)

        guard let chapters = contentProbe.chapters, !chapters.isEmpty else {
            checks.append(.init(kind: .pages, state: .skipped, required: true, summary: "Not run: no usable chapter dependency"))
            checks.append(.init(kind: .firstPageImage, state: .skipped, required: true, summary: "Not run: no resolved page dependency"))
            return makeReport(
                source: source,
                profileID: profileID,
                revision: revision,
                checks: checks,
                schema: schema,
                specification: specification
            )
        }

        if source.mediaType == .manga {
            let pageResult = await firstWorkingPages(provider: provider, chapters: chapters)
            checks.append(pageResult.check)
            if let pages = pageResult.value, !pages.isEmpty {
                checks.append(await attempt(kind: .firstPageImage, required: true) {
                    try await pageImageProbe(pages)
                }.map { $0 }.check)
            } else {
                checks.append(.init(kind: .firstPageImage, state: .skipped, required: true, summary: "No resolved page image"))
            }
        } else {
            let chapter = chapters[0]
            checks.append(await attempt(kind: .pages, required: true) {
                try await provider.chapterHTML(chapterKey: chapter.key, chapterTitle: chapter.title)
            }.map { "\($0.utf8.count) bytes of sanitized chapter HTML" }.check)
            checks.append(.init(kind: .firstPageImage, state: .skipped, required: false, summary: "Novel source"))
        }

        return makeReport(
            source: source,
            profileID: profileID,
            revision: revision,
            checks: checks,
            schema: schema,
            specification: specification
        )
    }

    static func failedAdmissionReport(
        source: ReaderExtensionInstalledSource,
        profileID: UUID,
        approvedDomains: Set<String>,
        error: Error
    ) -> ReaderExtensionCompatibilityReport {
        makeReport(
            source: source,
            profileID: profileID,
            revision: ReaderExtensionCompatibilityRevision.value(
                source: source,
                profileID: profileID,
                approvedDomains: approvedDomains
            ),
            checks: [.init(
                kind: .admission,
                state: .failed,
                required: true,
                summary: "Admission failed: \(ReaderExtensionDiagnostics.errorCode(error))"
            )],
            schema: nil,
            specification: ReaderExtensionCompatibilitySpecifications.specification(for: source)
        )
    }

    private struct Attempt<Value> {
        let value: Value?
        let check: ReaderExtensionCompatibilityCheck

        func map(_ summary: (Value) -> String) -> Attempt<Value> {
            guard let value else { return self }
            return Attempt(
                value: value,
                check: .init(kind: check.kind, state: .passed, required: check.required, summary: summary(value))
            )
        }
    }

    private struct ContentProbe {
        let chapters: [ReaderExtensionChapter]?
        let detailCheck: ReaderExtensionCompatibilityCheck
        let chaptersCheck: ReaderExtensionCompatibilityCheck
    }

    /// A catalog's first row is not necessarily readable: it may be deleted,
    /// premium-only, or have no chapters in the selected language. Sample a
    /// small number of unique rows across the feeds already fetched above and
    /// stop as soon as one candidate supports both detail and chapters.
    private static let maximumContentCandidates = 3
    private static let maximumScannedRowsPerFeed = 12

    private static func firstCandidateWithChapters(
        provider: any ReaderSourceProvider,
        candidates: [ReaderExtensionItem]
    ) async -> ContentProbe {
        let boundedCandidates = Array(candidates.prefix(maximumContentCandidates))
        var detailSuccessCount = 0
        var chapterAttemptCount = 0
        var emptyChapterCount = 0
        var lastDetailError: Error?
        var lastChapterError: Error?

        for (offset, candidate) in boundedCandidates.enumerated() {
            do {
                _ = try await provider.detail(itemKey: candidate.key)
                detailSuccessCount += 1
            } catch {
                lastDetailError = error
                continue
            }

            chapterAttemptCount += 1
            do {
                let chapters = try await provider.chapters(itemKey: candidate.key)
                guard !chapters.isEmpty else {
                    emptyChapterCount += 1
                    continue
                }
                let probeCount = offset + 1
                return ContentProbe(
                    chapters: chapters,
                    detailCheck: .init(
                        kind: .detail,
                        state: .passed,
                        required: true,
                        summary: probeCount == 1
                            ? "Detail metadata loaded"
                            : "Detail metadata loaded after \(probeCount) bounded candidates"
                    ),
                    chaptersCheck: .init(
                        kind: .chapters,
                        state: .passed,
                        required: true,
                        summary: "\(chapters.count) chapters after \(probeCount) bounded candidate\(probeCount == 1 ? "" : "s")"
                    )
                )
            } catch {
                lastChapterError = error
            }
        }

        let probedCount = boundedCandidates.count
        guard detailSuccessCount > 0 else {
            let code = ReaderExtensionDiagnostics.errorCode(
                lastDetailError ?? ReaderExtensionError.unsupportedSource
            )
            return ContentProbe(
                chapters: nil,
                detailCheck: .init(
                    kind: .detail,
                    state: .failed,
                    required: true,
                    summary: "Failed after \(probedCount) bounded candidates: \(code)"
                ),
                chaptersCheck: .init(
                    kind: .chapters,
                    state: .skipped,
                    required: true,
                    summary: "Not run: no detail candidate succeeded"
                )
            )
        }

        let chapterSummary: String
        if chapterAttemptCount == emptyChapterCount {
            chapterSummary = "Failed: empty-result after \(chapterAttemptCount) bounded candidates"
        } else if let lastChapterError {
            chapterSummary = "Failed after \(chapterAttemptCount) bounded candidates: \(ReaderExtensionDiagnostics.errorCode(lastChapterError))"
        } else {
            chapterSummary = "Failed: no usable chapters after \(chapterAttemptCount) bounded candidates"
        }
        return ContentProbe(
            chapters: nil,
            detailCheck: .init(
                kind: .detail,
                state: .passed,
                required: true,
                summary: "Detail metadata loaded for \(detailSuccessCount) of \(probedCount) bounded candidates"
            ),
            chaptersCheck: .init(
                kind: .chapters,
                state: .failed,
                required: true,
                summary: chapterSummary
            )
        )
    }

    private static func attempt<Value>(
        kind: ReaderExtensionCompatibilityCheckKind,
        required: Bool,
        operation: () async throws -> Value
    ) async -> Attempt<Value> {
        do {
            let value = try await operation()
            return Attempt(
                value: value,
                check: .init(kind: kind, state: .passed, required: required, summary: "Passed")
            )
        } catch {
            return Attempt(
                value: nil,
                check: .init(
                    kind: kind,
                    state: required ? .failed : .warning,
                    required: required,
                    summary: "Failed: \(ReaderExtensionDiagnostics.errorCode(error))"
                )
            )
        }
    }

    private static func requiringNonemptyItems(
        _ attempt: Attempt<ReaderExtensionPagedResult>
    ) -> Attempt<ReaderExtensionPagedResult> {
        guard let value = attempt.value else { return attempt }
        guard !value.items.isEmpty else {
            return Attempt(
                value: nil,
                check: .init(
                    kind: .popular,
                    state: .failed,
                    required: true,
                    summary: "Failed: empty-result"
                )
            )
        }
        return attempt
    }

    private static func firstWorkingPages(
        provider: any ReaderSourceProvider,
        chapters: [ReaderExtensionChapter]
    ) async -> Attempt<[ReaderExtensionPage]> {
        var candidates: [ReaderExtensionChapter] = []
        for index in [0, chapters.count - 1, chapters.count / 2] where chapters.indices.contains(index) {
            let chapter = chapters[index]
            if !candidates.contains(where: { $0.key == chapter.key }) { candidates.append(chapter) }
        }

        var lastError: Error?
        for chapter in candidates {
            do {
                let pages = try await provider.pages(chapterKey: chapter.key)
                if !pages.isEmpty {
                    return Attempt(
                        value: pages,
                        check: .init(kind: .pages, state: .passed, required: true, summary: "\(pages.count) pages")
                    )
                }
                lastError = ReaderExtensionError.resultInvalid("empty page list")
            } catch {
                lastError = error
            }
        }
        return Attempt(
            value: nil,
            check: .init(
                kind: .pages,
                state: .failed,
                required: true,
                summary: "Failed: \(ReaderExtensionDiagnostics.errorCode(lastError ?? ReaderExtensionError.unsupportedSource))"
            )
        )
    }

    private static func boundedUniqueCandidates(
        from feeds: [[ReaderExtensionItem]]
    ) -> [ReaderExtensionItem] {
        let boundedFeeds = feeds.map { Array($0.prefix(maximumScannedRowsPerFeed)) }
        var seen = Set<String>()
        var candidates: [ReaderExtensionItem] = []

        // Round-robin sampling avoids letting one feed consume the entire
        // request budget while remaining agnostic about source-specific data.
        for row in 0..<maximumScannedRowsPerFeed {
            for feed in boundedFeeds where feed.indices.contains(row) {
                let item = feed[row]
                guard !item.key.isEmpty, seen.insert(item.key).inserted else { continue }
                candidates.append(item)
                if candidates.count == maximumContentCandidates { return candidates }
            }
        }
        return candidates
    }

    private static func makeReport(
        source: ReaderExtensionInstalledSource,
        profileID: UUID,
        revision: String,
        checks: [ReaderExtensionCompatibilityCheck],
        schema: ReaderExtensionFilterSchemaSummary?,
        specification: ReaderExtensionCompatibilitySpecification?
    ) -> ReaderExtensionCompatibilityReport {
        let hasRequiredFailure = checks.contains { $0.required && $0.state == .failed }
            || checks.contains { $0.required && $0.state == .skipped }
        let hasWarning = checks.contains { $0.state == .warning }
        let parity = specification?.siteParity ?? .notAudited
        let classification: ReaderExtensionCompatibilityClassification
        if hasRequiredFailure {
            classification = .failed
        } else if hasWarning || parity == .knownLimitations {
            classification = .limited
        } else if parity == .verified {
            classification = .certified
        } else {
            classification = .runtimeCompatible
        }

        return ReaderExtensionCompatibilityReport(
            sourceID: source.id,
            profileID: profileID,
            sourceName: ReaderExtensionDiagnostics.safeLabel(source.name),
            sourceVersion: String(source.version.prefix(64)),
            sourceRevision: revision,
            checkedAt: Date(),
            classification: classification,
            checks: Array(checks.prefix(ReaderExtensionCompatibilityCheckKind.allCases.count)),
            filterSchema: schema,
            siteParity: parity,
            siteParityNotes: Array((specification?.notes ?? [
                "Eclipse verified the runtime path only; the extension's catalog has not been compared with the live site."
            ]).prefix(4)).map { String($0.prefix(240)) }
        )
    }
}

@MainActor
final class ReaderExtensionCompatibilityCoordinator: ObservableObject {
    static let shared = ReaderExtensionCompatibilityCoordinator()

    @Published private(set) var runningSourceIDs = Set<ReaderExtensionSourceID>()

    @discardableResult
    func run(sourceID: ReaderExtensionSourceID) async -> ReaderExtensionCompatibilityReport? {
        guard !runningSourceIDs.contains(sourceID),
              let source = ReaderExtensionManager.shared.source(for: sourceID) else {
            return nil
        }
        runningSourceIDs.insert(sourceID)
        defer { runningSourceIDs.remove(sourceID) }

        let manager = ReaderExtensionManager.shared
        let profileID = ProfileManager.shared.activeProfileID
        let approvedDomains = manager.approvedDomains(for: sourceID)
        let report: ReaderExtensionCompatibilityReport
        do {
            let provider = try manager.provider(for: sourceID)
            report = await ReaderExtensionCompatibilityRunner.run(
                provider: provider,
                profileID: profileID,
                approvedDomains: approvedDomains,
                pageImageProbe: { pages in
                    guard let resource = try manager.pageResources(for: pages, sourceID: sourceID).first else {
                        throw ReaderExtensionError.resultInvalid("no page resource")
                    }
                    let response = try await manager.fetchPage(resource)
                    let metadata = try ReaderExtensionImageSafety.validate(response.body)
                    return "Decoded \(metadata.pixelWidth)×\(metadata.pixelHeight) image"
                }
            )
        } catch {
            report = ReaderExtensionCompatibilityRunner.failedAdmissionReport(
                source: source,
                profileID: profileID,
                approvedDomains: approvedDomains,
                error: error
            )
        }

        ReaderExtensionCompatibilityStore.shared.save(report)
        ReaderExtensionDiagnostics.record(
            context: ReaderExtensionDiagnosticContext(source: source),
            operation: "compatibility-check",
            event: report.classification.rawValue,
            type: "ReaderExtensionCompatibility",
            count: report.passedCount
        )
        return report
    }
}
#endif
