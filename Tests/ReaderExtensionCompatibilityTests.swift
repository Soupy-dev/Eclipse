import CryptoKit
import XCTest
@testable import Eclipse

#if os(iOS)
@MainActor
final class ReaderExtensionCompatibilityTests: XCTestCase {
    func testUnknownSourceCanPassRuntimeButCannotSelfCertify() async throws {
        let source = makeSource(name: "Fixture", version: "1.0.0")
        let provider = CompatibilityFixtureProvider(source: source, filters: genericFilters())

        let report = await ReaderExtensionCompatibilityRunner.run(
            provider: provider,
            profileID: UUID(),
            approvedDomains: ["reader.example"],
            pageImageProbe: { _ in "Decoded fixture image" }
        )

        XCTAssertEqual(report.classification, .runtimeCompatible)
        XCTAssertEqual(report.siteParity, .notAudited)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertTrue(report.checks.contains { $0.kind == .firstPageImage && $0.state == .passed })
    }

    func testContentProbeFallsBackFromChapterlessFirstCandidateAndStopsAtSuccess() async throws {
        let source = makeSource(name: "Fixture", version: "1.0.0")
        let chapterless = ReaderExtensionItem(key: "private-first-key", title: "Private First Title")
        let working = ReaderExtensionItem(key: "private-working-key", title: "Private Working Title")
        let unused = ReaderExtensionItem(key: "private-unused-key", title: "Private Unused Title")
        let provider = CompatibilityFixtureProvider(
            source: source,
            filters: genericFilters(),
            listItemsByOperation: [
                .popular: [chapterless, unused],
                .latest: [working],
                .search: [chapterless]
            ],
            emptyChapterItemKeys: [chapterless.key]
        )

        let report = await ReaderExtensionCompatibilityRunner.run(
            provider: provider,
            profileID: UUID(),
            approvedDomains: ["reader.example"],
            pageImageProbe: { _ in "Decoded fixture image" }
        )

        XCTAssertEqual(report.classification, .runtimeCompatible)
        XCTAssertEqual(provider.detailRequestKeys, [chapterless.key, working.key])
        XCTAssertEqual(provider.chapterRequestKeys, [chapterless.key, working.key])
        XCTAssertFalse(provider.detailRequestKeys.contains(unused.key))
        XCTAssertEqual(report.checks.first { $0.kind == .detail }?.state, .passed)
        XCTAssertEqual(report.checks.first { $0.kind == .chapters }?.state, .passed)
        XCTAssertTrue(report.checks.first { $0.kind == .chapters }?.summary.contains("after 2 bounded candidates") == true)
        let summaries = report.checks.map(\.summary).joined(separator: " ")
        XCTAssertFalse(summaries.contains(chapterless.key))
        XCTAssertFalse(summaries.contains(chapterless.title))
    }

    func testContentProbeBoundsExhaustedChapterlessCandidatesAndReportsDependencySkips() async throws {
        let source = makeSource(name: "Fixture", version: "1.0.0")
        let items = (1...8).map {
            ReaderExtensionItem(key: "sensitive-key-\($0)", title: "Sensitive Title \($0)")
        }
        let provider = CompatibilityFixtureProvider(
            source: source,
            filters: genericFilters(),
            listItemsByOperation: [
                .popular: items,
                .latest: items,
                .search: items
            ],
            emptyChapterItemKeys: Set(items.map(\.key))
        )

        let report = await ReaderExtensionCompatibilityRunner.run(
            provider: provider,
            profileID: UUID(),
            approvedDomains: ["reader.example"],
            pageImageProbe: { _ in
                XCTFail("Page image probe must not run without a usable chapter")
                return "unreachable"
            }
        )

        XCTAssertEqual(report.classification, .failed)
        XCTAssertEqual(provider.detailRequestKeys.count, 3)
        XCTAssertEqual(provider.chapterRequestKeys.count, 3)
        XCTAssertEqual(Set(provider.detailRequestKeys).count, 3)
        XCTAssertEqual(report.checks.first { $0.kind == .detail }?.state, .passed)
        XCTAssertEqual(report.checks.first { $0.kind == .chapters }?.state, .failed)
        XCTAssertEqual(
            report.checks.first { $0.kind == .chapters }?.summary,
            "Failed: empty-result after 3 bounded candidates"
        )
        XCTAssertEqual(report.checks.first { $0.kind == .pages }?.state, .skipped)
        XCTAssertTrue(report.checks.first { $0.kind == .pages }?.summary.contains("dependency") == true)
        let summaries = report.checks.map(\.summary).joined(separator: " ")
        for item in items {
            XCTAssertFalse(summaries.contains(item.key))
            XCTAssertFalse(summaries.contains(item.title))
        }
    }

    func testContentProbeSkipsChaptersWhenAllBoundedDetailsFail() async throws {
        let source = makeSource(name: "Fixture", version: "1.0.0")
        let items = (1...5).map {
            ReaderExtensionItem(key: "private-detail-key-\($0)", title: "Private Detail Title \($0)")
        }
        let provider = CompatibilityFixtureProvider(
            source: source,
            filters: genericFilters(),
            failingOperation: .detail,
            listItemsByOperation: [.popular: items, .latest: items, .search: items]
        )

        let report = await ReaderExtensionCompatibilityRunner.run(
            provider: provider,
            profileID: UUID(),
            approvedDomains: ["reader.example"],
            pageImageProbe: { _ in
                XCTFail("Page image probe must not run after detail failure")
                return "unreachable"
            }
        )

        XCTAssertEqual(report.classification, .failed)
        XCTAssertEqual(provider.detailRequestKeys.count, 3)
        XCTAssertTrue(provider.chapterRequestKeys.isEmpty)
        XCTAssertEqual(report.checks.first { $0.kind == .detail }?.state, .failed)
        XCTAssertTrue(report.checks.first { $0.kind == .detail }?.summary.contains("runtime-failed") == true)
        XCTAssertEqual(report.checks.first { $0.kind == .chapters }?.state, .skipped)
        XCTAssertTrue(report.checks.first { $0.kind == .chapters }?.summary.contains("no detail candidate") == true)
        let summaries = report.checks.map(\.summary).joined(separator: " ")
        XCTAssertFalse(summaries.contains("credential"))
        for item in items {
            XCTAssertFalse(summaries.contains(item.key))
            XCTAssertFalse(summaries.contains(item.title))
        }
    }

    func testRequiredOperationFailureMakesReportFailedWithoutLeakingProviderError() async throws {
        let source = makeSource(name: "Fixture", version: "1.0.0")
        let provider = CompatibilityFixtureProvider(
            source: source,
            filters: genericFilters(),
            failingOperation: .search
        )

        let report = await ReaderExtensionCompatibilityRunner.run(
            provider: provider,
            profileID: UUID(),
            approvedDomains: ["reader.example"],
            pageImageProbe: { _ in "Decoded fixture image" }
        )

        XCTAssertEqual(report.classification, .failed)
        let search = try XCTUnwrap(report.checks.first { $0.kind == .search })
        XCTAssertEqual(search.state, .failed)
        XCTAssertEqual(search.summary, "Failed: runtime-failed")
        XCTAssertFalse(search.summary.contains("credential"))
    }

    func testEmptyPopularFailsWhileEmptySearchIsAllowedAndDependenciesDoNotRun() async throws {
        let source = makeSource(name: "Fixture", version: "1.0.0")
        let provider = CompatibilityFixtureProvider(
            source: source,
            filters: genericFilters(),
            emptyListOperations: [.popular, .latest, .search]
        )

        let report = await ReaderExtensionCompatibilityRunner.run(
            provider: provider,
            profileID: UUID(),
            approvedDomains: ["reader.example"],
            pageImageProbe: { _ in
                XCTFail("Page image probe must not run without a list-item dependency")
                return "unreachable"
            }
        )

        XCTAssertEqual(report.classification, .failed)
        XCTAssertEqual(report.checks.first { $0.kind == .popular }?.state, .failed)
        XCTAssertEqual(report.checks.first { $0.kind == .popular }?.summary, "Failed: empty-result")
        XCTAssertEqual(report.checks.first { $0.kind == .search }?.state, .passed)
        XCTAssertEqual(report.checks.first { $0.kind == .search }?.summary, "0 items")
        XCTAssertEqual(report.checks.first { $0.kind == .detail }?.state, .skipped)
        XCTAssertTrue(report.checks.first { $0.kind == .detail }?.summary.contains("Not run") == true)
        XCTAssertEqual(report.checks.first { $0.kind == .pages }?.state, .skipped)
    }

    func testKnownMangaDexSchemaStillReportsUpstreamLimitations() async throws {
        let source = makeSource(
            name: "MangaDex",
            version: "0.1.4",
            sourceCodeURL: URL(string: "https://raw.githubusercontent.com/m2k3a/mangayomi-extensions/main/javascript/manga/src/all/mangadex.js")!
        )
        let provider = CompatibilityFixtureProvider(source: source, filters: mangaDexFilters())

        let report = await ReaderExtensionCompatibilityRunner.run(
            provider: provider,
            profileID: UUID(),
            approvedDomains: ["mangadex.org", "api.mangadex.org"],
            pageImageProbe: { _ in "Decoded fixture image" }
        )

        XCTAssertEqual(report.filterSchema?.topLevelCount, 11)
        XCTAssertEqual(report.filterSchema?.flattenedCount, 102)
        XCTAssertEqual(report.classification, .limited)
        XCTAssertEqual(report.siteParity, .knownLimitations)
        XCTAssertTrue(report.siteParityNotes.contains { $0.contains("Incest") && $0.contains("Mahjong") })
        XCTAssertTrue(report.siteParityNotes.contains { $0.contains("Self-Published") })
        XCTAssertTrue(report.siteParityNotes.contains { $0.contains("ContentsFilter") && $0.contains("ignores") })
        XCTAssertEqual(report.checks.first { $0.kind == .filters }?.state, .passed)
        XCTAssertEqual(report.checks.first { $0.kind == .filterStateShape }?.state, .passed)
    }

    func testKnownWeebCentralSchemaClassifiesAuthorAndExclusionGapAsLimited() async throws {
        let source = makeSource(
            name: "Weeb Central",
            version: "0.1.0",
            sourceCodeURL: URL(string: "https://raw.githubusercontent.com/m2k3a/mangayomi-extensions/main/javascript/manga/src/en/weebcentral.js")!
        )
        let report = await ReaderExtensionCompatibilityRunner.run(
            provider: CompatibilityFixtureProvider(source: source, filters: weebCentralFilters()),
            profileID: UUID(),
            approvedDomains: ["weebcentral.com"],
            pageImageProbe: { _ in "Decoded fixture image" }
        )

        XCTAssertEqual(report.filterSchema?.topLevelCount, 6)
        XCTAssertEqual(report.filterSchema?.flattenedCount, 51)
        XCTAssertEqual(report.classification, .limited)
        XCTAssertEqual(report.siteParity, .knownLimitations)
        XCTAssertEqual(report.checks.first { $0.kind == .filters }?.state, .passed)
        XCTAssertEqual(report.checks.first { $0.kind == .filterStateShape }?.state, .passed)
        XCTAssertTrue(report.siteParityNotes.contains { $0.contains("38 tags") })
        XCTAssertTrue(report.siteParityNotes.contains { $0.contains("author") && $0.contains("exclusion") })
    }

    func testKnownAsuraSchemaClassifiesGenreCreatorAndMinimumChapterGapsAsLimited() async throws {
        let source = makeSource(
            name: "Asura Scans",
            version: "0.2.14",
            sourceCodeURL: URL(string: "https://raw.githubusercontent.com/m2k3a/mangayomi-extensions/main/javascript/manga/src/en/asurascans.js")!
        )
        let report = await ReaderExtensionCompatibilityRunner.run(
            provider: CompatibilityFixtureProvider(source: source, filters: asuraFilters()),
            profileID: UUID(),
            approvedDomains: ["asuracomic.net"],
            pageImageProbe: { _ in "Decoded fixture image" }
        )

        XCTAssertEqual(report.filterSchema?.topLevelCount, 5)
        XCTAssertEqual(report.filterSchema?.flattenedCount, 35)
        XCTAssertEqual(report.classification, .limited)
        XCTAssertEqual(report.siteParity, .knownLimitations)
        XCTAssertEqual(report.checks.first { $0.kind == .filters }?.state, .passed)
        XCTAssertEqual(report.checks.first { $0.kind == .filterStateShape }?.state, .passed)
        XCTAssertTrue(report.siteParityNotes.contains { $0.contains("33 genres") })
        XCTAssertTrue(report.siteParityNotes.contains { $0.contains("Creator") && $0.contains("minimum-chapter") })
    }

    func testFilterStateShapeValidationSeparatesLocalRoundTripFromSiteParity() {
        let valid = ReaderExtensionFilterStateShapeValidator.validate(genericFilters())
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.flattenedCount, 1)
        XCTAssertEqual(valid.statefulCount, 1)
        XCTAssertTrue(valid.check(required: true).summary.contains("live-site parity is not asserted"))

        let malformed = [
            ReaderExtensionFilter(
                key: "toggle",
                title: "Toggle",
                kind: .toggle,
                options: [],
                value: .string("not-a-boolean")
            ),
            ReaderExtensionFilter(
                key: "sort",
                title: "Sort",
                kind: .sort,
                options: [ReaderExtensionFilterOption(label: "Popular", value: "popular")],
                value: .string("missing"),
                sortAscending: nil
            )
        ]
        let invalid = ReaderExtensionFilterStateShapeValidator.validate(malformed)
        XCTAssertFalse(invalid.isValid)
        XCTAssertTrue(invalid.issues.contains(.invalidValueKind))
        XCTAssertTrue(invalid.issues.contains(.invalidSelection))
        XCTAssertTrue(invalid.issues.contains(.missingSortDirection))
        XCTAssertEqual(invalid.check(required: true).state, .failed)
        XCTAssertEqual(invalid.check(required: false).state, .warning)

        let oversized = (0...ReaderExtensionFilterStateShapeValidator.maximumSiblings).map { index in
            ReaderExtensionFilter(
                key: "toggle-\(index)",
                title: "Toggle \(index)",
                kind: .toggle,
                options: [],
                value: .bool(false)
            )
        }
        let bounded = ReaderExtensionFilterStateShapeValidator.validate(oversized)
        XCTAssertEqual(bounded.flattenedCount, ReaderExtensionFilterStateShapeValidator.maximumSiblings)
        XCTAssertTrue(bounded.issues.contains(.siblingLimitExceeded))
        XCTAssertTrue(bounded.issues.contains(.rowLimitExceeded))
    }

    func testReaderHostDefaultsPreserveCaseInsensitiveSourceHeaders() {
        let sourceHeaders = [
            "uSeR-aGeNt": "SourceAgent/1",
            "aCcEpT": "application/json",
            "Accept-LANGUAGE": "ja",
            "Referer": "https://reader.example/"
        ]
        let preserved = ReaderExtensionSecurityPolicy.headersByApplyingHostDefaults(sourceHeaders)
        XCTAssertEqual(preserved, sourceHeaders)

        let injected = ReaderExtensionSecurityPolicy.headersByApplyingHostDefaults([
            "Referer": "https://reader.example/"
        ])
        XCTAssertEqual(injected["User-Agent"], ReaderExtensionSecurityPolicy.defaultReaderUserAgent)
        XCTAssertEqual(injected["Accept"], ReaderExtensionSecurityPolicy.defaultReaderAcceptHeader)
        XCTAssertEqual(injected["Accept-Language"], ReaderExtensionSecurityPolicy.defaultReaderAcceptLanguageHeader)
        XCTAssertEqual(injected["Referer"], "https://reader.example/")
    }

    func testReaderAssetResponseCeilingSitsBetweenOrdinaryAndPageBudgets() {
        XCTAssertGreaterThan(
            ReaderExtensionSecurityPolicy.maximumAssetResponseBytes,
            ReaderExtensionSecurityPolicy.maximumResponseBytes
        )
        XCTAssertLessThan(
            ReaderExtensionSecurityPolicy.maximumAssetResponseBytes,
            ReaderExtensionSecurityPolicy.maximumPageResponseBytes
        )
    }

    func testExtensionVisibleRequestHeadersExposeOnlyCaseInsensitiveCookie() {
        let visible = ReaderExtensionSecureHTTPClient.extensionVisibleRequestHeaders(from: [
            "cOoKiE": "session=owned",
            "Authorization": "Bearer must-not-leak",
            "X-Token": "must-not-leak",
            "User-Agent": "SourceAgent/1"
        ])

        XCTAssertEqual(visible, ["Cookie": "session=owned"])
    }

    func testMangayomiGetHeadersReceivesExactEffectiveBaseURL() async throws {
        var source = makeSource(name: "Header Fixture", version: "1.0.0")
        let script = Data("""
        class DefaultExtension extends MProvider {
          getHeaders(url) { return { Referer: url }; }
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: "Fixture", chapters: []}; }
          async getPageList(url) { return []; }
        }
        """.utf8)
        source.activeContentDigest = SHA256.hash(data: script)
            .map { String(format: "%02x", $0) }
            .joined()
        let provider = try JavaScriptReaderProvider(
            source: source,
            scriptData: script,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            consentScopeID: "compatibility-get-headers-base-url",
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )

        let headers = try await provider.resourceHeaders()
        XCTAssertEqual(headers["Referer"], source.baseURL.absoluteString)
    }

    func testRevisionUsesEffectiveMangaDexRuntimeIdentityAndInvalidatesExplicitArabic() {
        let profileID = UUID()
        var legacy = makeSource(
            name: "MangaDex",
            version: "0.1.4",
            sourceCodeURL: URL(string: "https://raw.githubusercontent.com/m2k3a/mangayomi-extensions/main/javascript/manga/src/all/mangadex.js")!,
            language: "ar",
            upstreamID: "202373705"
        )
        legacy.languageSelectionVersion = nil
        var explicitArabic = legacy
        explicitArabic.languageSelectionVersion = ReaderExtensionLanguageCompatibilityPolicy.explicitSelectionVersion

        let legacyRevision = ReaderExtensionCompatibilityRevision.value(
            source: legacy,
            profileID: profileID,
            approvedDomains: ["mangadex.org"]
        )
        let explicitRevision = ReaderExtensionCompatibilityRevision.value(
            source: explicitArabic,
            profileID: profileID,
            approvedDomains: ["mangadex.org"]
        )

        XCTAssertNotEqual(legacyRevision, explicitRevision)
        XCTAssertEqual(
            ReaderExtensionLanguageCompatibilityPolicy.runtimeIdentity(
                for: legacy,
                preferredLanguages: ["en-US"]
            ).language,
            "en"
        )
        XCTAssertEqual(
            ReaderExtensionLanguageCompatibilityPolicy.runtimeIdentity(
                for: explicitArabic,
                preferredLanguages: ["en-US"]
            ).language,
            "ar"
        )
    }

    func testDiskStoreIsBoundedDerivedStateAndCorruptionFailsOpen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderExtensionCompatibilityTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("reports.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = makeSource(name: "Fixture", version: "1.0.0")
        let profileID = UUID()
        let report = await ReaderExtensionCompatibilityRunner.run(
            provider: CompatibilityFixtureProvider(source: source, filters: genericFilters()),
            profileID: profileID,
            approvedDomains: ["reader.example"],
            pageImageProbe: { _ in "Decoded fixture image" }
        )

        let writer = ReaderExtensionCompatibilityStore(fileURL: fileURL, observesRuntimeChanges: false)
        writer.save(report)
        let reader = ReaderExtensionCompatibilityStore(fileURL: fileURL, observesRuntimeChanges: false)
        XCTAssertNotNil(reader.currentReport(
            for: source,
            profileID: profileID,
            approvedDomains: ["reader.example"]
        ))

        var changed = source
        changed.version = "1.0.1"
        XCTAssertNil(reader.currentReport(
            for: changed,
            profileID: profileID,
            approvedDomains: ["reader.example"]
        ))

        try Data("not-json".utf8).write(to: fileURL, options: .atomic)
        let corruptReader = ReaderExtensionCompatibilityStore(fileURL: fileURL, observesRuntimeChanges: false)
        XCTAssertTrue(corruptReader.reports.isEmpty)
    }

    private func makeSource(
        name: String,
        version: String,
        sourceCodeURL: URL = URL(string: "https://raw.githubusercontent.com/example/extensions/main/source.js")!,
        language: String = "en",
        upstreamID: String = "fixture"
    ) -> ReaderExtensionInstalledSource {
        let repositoryURL = URL(string: name == "MangaDex"
            ? "https://m2k3a.github.io/mangayomi-extensions/index.json"
            : "https://repo.example/index.json")!
        let catalog = ReaderExtensionCatalogSource(
            id: ReaderExtensionSourceID(
                repositoryURL: repositoryURL,
                upstreamID: upstreamID,
                language: language,
                mediaType: .manga
            ),
            upstreamID: upstreamID,
            repositoryID: ReaderExtensionRepositoryRecord(indexURL: repositoryURL).id,
            repositoryURL: repositoryURL,
            name: name,
            baseURL: URL(string: name == "MangaDex" ? "https://mangadex.org" : "https://reader.example")!,
            apiURL: name == "MangaDex" ? URL(string: "https://api.mangadex.org")! : nil,
            language: language,
            mediaType: .manga,
            implementation: .javascript,
            sourceCodeURL: sourceCodeURL,
            version: version,
            maturity: .safe,
            hasCloudflare: false,
            dateFormat: nil,
            dateFormatLocale: nil,
            additionalParameters: nil,
            notes: nil,
            license: .unknown
        )
        var source = ReaderExtensionInstalledSource(catalog: catalog, sortIndex: 0)
        source.activeContentDigest = String(repeating: "a", count: 64)
        source.runtimeCapabilities = Set(ReaderExtensionCapability.allCasesForCompatibilityTests)
        return source
    }

    private func genericFilters() -> [ReaderExtensionFilter] {
        [
            ReaderExtensionFilter(
                key: "sort",
                title: "Sort",
                kind: .select,
                options: [ReaderExtensionFilterOption(label: "Popular", value: "popular")],
                value: .string("popular")
            )
        ]
    }

    private func mangaDexFilters() -> [ReaderExtensionFilter] {
        func toggles(_ prefix: String, count: Int) -> [ReaderExtensionFilter] {
            (0..<count).map { index in
                ReaderExtensionFilter(
                    key: "\(prefix)-\(index)",
                    title: "\(prefix) \(index)",
                    kind: .toggle,
                    options: [],
                    value: .bool(false)
                )
            }
        }
        func triStates(_ prefix: String, count: Int) -> [ReaderExtensionFilter] {
            (0..<count).map { index in
                ReaderExtensionFilter(
                    key: "\(prefix)-\(index)",
                    title: "\(prefix) \(index)",
                    kind: .triState,
                    options: [],
                    value: .number(0)
                )
            }
        }
        func mode(_ key: String, title: String, selected: String) -> ReaderExtensionFilter {
            ReaderExtensionFilter(
                key: key,
                title: title,
                kind: .select,
                options: [
                    ReaderExtensionFilterOption(label: "AND", value: "AND"),
                    ReaderExtensionFilterOption(label: "OR", value: "OR")
                ],
                value: .string(selected)
            )
        }
        return [
            ReaderExtensionFilter(key: "available", title: "Has available chapters", kind: .toggle, options: [], value: .bool(false)),
            ReaderExtensionFilter(key: "language", title: "Original language", kind: .group, options: [], value: .string(""), children: toggles("Language", count: 3)),
            ReaderExtensionFilter(key: "rating", title: "Content rating", kind: .group, options: [], value: .string(""), children: toggles("Rating", count: 2)),
            ReaderExtensionFilter(key: "demographic", title: "Publication demographic", kind: .group, options: [], value: .string(""), children: toggles("Demographic", count: 5)),
            ReaderExtensionFilter(key: "status", title: "Status", kind: .group, options: [], value: .string(""), children: toggles("Status", count: 4)),
            ReaderExtensionFilter(
                key: "sort",
                title: "Sort",
                kind: .sort,
                options: [ReaderExtensionFilterOption(label: "Relevance", value: "relevance")],
                value: .string("relevance"),
                sortAscending: false
            ),
            ReaderExtensionFilter(
                key: "tags-mode",
                title: "Tags mode",
                kind: .group,
                options: [],
                value: .string(""),
                children: [
                    mode("included-mode", title: "Included tags mode", selected: "AND"),
                    mode("excluded-mode", title: "Excluded tags mode", selected: "OR")
                ]
            ),
            ReaderExtensionFilter(key: "content", title: "Content", kind: .group, options: [], value: .string(""), children: triStates("Content", count: 2)),
            ReaderExtensionFilter(key: "format", title: "Format", kind: .group, options: [], value: .string(""), children: triStates("Format", count: 12)),
            ReaderExtensionFilter(key: "genre", title: "Genre", kind: .group, options: [], value: .string(""), children: triStates("Genre", count: 25)),
            ReaderExtensionFilter(key: "theme", title: "Theme", kind: .group, options: [], value: .string(""), children: triStates("Theme", count: 36))
        ]
    }

    private func weebCentralFilters() -> [ReaderExtensionFilter] {
        let selectionOptions = [
            ReaderExtensionFilterOption(label: "Any", value: "Any"),
            ReaderExtensionFilterOption(label: "Other", value: "Other")
        ]
        func toggles(_ prefix: String, count: Int) -> [ReaderExtensionFilter] {
            (0..<count).map { index in
                ReaderExtensionFilter(
                    key: "\(prefix)-\(index)",
                    title: "\(prefix) \(index)",
                    kind: .toggle,
                    options: [],
                    value: .bool(false)
                )
            }
        }
        return [
            ReaderExtensionFilter(key: "sort", title: "Sort", kind: .select, options: selectionOptions, value: .string("Any")),
            ReaderExtensionFilter(key: "order", title: "Order", kind: .select, options: selectionOptions, value: .string("Any")),
            ReaderExtensionFilter(key: "official", title: "Official Translation", kind: .select, options: selectionOptions, value: .string("Any")),
            ReaderExtensionFilter(key: "status", title: "Series Status", kind: .group, options: [], value: .string(""), children: toggles("Status", count: 4)),
            ReaderExtensionFilter(key: "type", title: "Series Type", kind: .group, options: [], value: .string(""), children: toggles("Type", count: 4)),
            ReaderExtensionFilter(key: "tags", title: "Tags", kind: .group, options: [], value: .string(""), children: toggles("Tag", count: 37))
        ]
    }

    private func asuraFilters() -> [ReaderExtensionFilter] {
        let selectionOptions = [
            ReaderExtensionFilterOption(label: "All", value: ""),
            ReaderExtensionFilterOption(label: "Other", value: "other")
        ]
        let genres = (0..<30).map { index in
            ReaderExtensionFilter(
                key: "genre-\(index)",
                title: "Genre \(index)",
                kind: .toggle,
                options: [],
                value: .bool(false)
            )
        }
        return [
            ReaderExtensionFilter(key: "sort-by", title: "Sort By", kind: .select, options: selectionOptions, value: .string("")),
            ReaderExtensionFilter(key: "sort-order", title: "Sort Order", kind: .select, options: selectionOptions, value: .string("")),
            ReaderExtensionFilter(key: "status", title: "Status", kind: .select, options: selectionOptions, value: .string("")),
            ReaderExtensionFilter(key: "type", title: "Type", kind: .select, options: selectionOptions, value: .string("")),
            ReaderExtensionFilter(key: "genres", title: "Genres", kind: .group, options: [], value: .string(""), children: genres)
        ]
    }
}

private extension ReaderExtensionCapability {
    static var allCasesForCompatibilityTests: [ReaderExtensionCapability] {
        [.popular, .latest, .search, .detail, .pages, .filters, .preferences]
    }
}

private final class CompatibilityFixtureProvider: ReaderSourceProvider {
    let source: ReaderExtensionInstalledSource
    private let suppliedFilters: [ReaderExtensionFilter]
    private let failingOperation: ReaderExtensionCompatibilityCheckKind?
    private let emptyListOperations: Set<ReaderExtensionCompatibilityCheckKind>
    private let listItemsByOperation: [ReaderExtensionCompatibilityCheckKind: [ReaderExtensionItem]]
    private let emptyChapterItemKeys: Set<String>
    private(set) var detailRequestKeys: [String] = []
    private(set) var chapterRequestKeys: [String] = []

    init(
        source: ReaderExtensionInstalledSource,
        filters: [ReaderExtensionFilter],
        failingOperation: ReaderExtensionCompatibilityCheckKind? = nil,
        emptyListOperations: Set<ReaderExtensionCompatibilityCheckKind> = [],
        listItemsByOperation: [ReaderExtensionCompatibilityCheckKind: [ReaderExtensionItem]] = [:],
        emptyChapterItemKeys: Set<String> = []
    ) {
        self.source = source
        suppliedFilters = filters
        self.failingOperation = failingOperation
        self.emptyListOperations = emptyListOperations
        self.listItemsByOperation = listItemsByOperation
        self.emptyChapterItemKeys = emptyChapterItemKeys
    }

    func popular(page: Int) async throws -> ReaderExtensionPagedResult {
        try failIfNeeded(.popular)
        if emptyListOperations.contains(.popular) { return .init(items: [], hasNextPage: false) }
        return .init(items: listItems(for: .popular), hasNextPage: false)
    }

    func latest(page: Int) async throws -> ReaderExtensionPagedResult {
        try failIfNeeded(.latest)
        if emptyListOperations.contains(.latest) { return .init(items: [], hasNextPage: false) }
        return .init(items: listItems(for: .latest), hasNextPage: false)
    }

    func search(query: String, page: Int, filters: [ReaderExtensionFilter]) async throws -> ReaderExtensionPagedResult {
        try failIfNeeded(.search)
        if emptyListOperations.contains(.search) { return .init(items: [], hasNextPage: false) }
        return .init(items: listItems(for: .search), hasNextPage: false)
    }

    func detail(itemKey: String) async throws -> ReaderExtensionItem {
        detailRequestKeys.append(itemKey)
        try failIfNeeded(.detail)
        return ReaderExtensionItem(key: itemKey, title: "Fixture Manga")
    }

    func chapters(itemKey: String) async throws -> [ReaderExtensionChapter] {
        chapterRequestKeys.append(itemKey)
        try failIfNeeded(.chapters)
        if emptyChapterItemKeys.contains(itemKey) { return [] }
        return [ReaderExtensionChapter(
            key: "chapter-1",
            title: "Chapter 1",
            url: nil,
            uploadedAt: nil,
            scanlator: nil,
            isFiller: false,
            thumbnailURL: nil,
            summary: nil
        )]
    }

    func pages(chapterKey: String) async throws -> [ReaderExtensionPage] {
        try failIfNeeded(.pages)
        return [ReaderExtensionPage(key: "page-1", url: URL(string: "https://images.example/page.webp")!, headers: [:])]
    }

    func chapterHTML(chapterKey: String, chapterTitle: String) async throws -> String { "chapter" }
    func resourceHeaders() async throws -> [String: String] { ["Referer": "https://reader.example/"] }
    func filters() async throws -> [ReaderExtensionFilter] { suppliedFilters }
    func preferences() async throws -> [ReaderExtensionPreference] { [] }

    private var item: ReaderExtensionItem {
        ReaderExtensionItem(key: "manga-1", title: "Fixture Manga")
    }

    private func listItems(for operation: ReaderExtensionCompatibilityCheckKind) -> [ReaderExtensionItem] {
        listItemsByOperation[operation] ?? [item]
    }

    private func failIfNeeded(_ operation: ReaderExtensionCompatibilityCheckKind) throws {
        guard failingOperation == operation else { return }
        throw ReaderExtensionError.runtimeFailed("credential=must-not-appear")
    }
}
#endif
