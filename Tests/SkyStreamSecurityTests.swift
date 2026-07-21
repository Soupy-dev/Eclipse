import Foundation
import CryptoKit
import XCTest
@testable import Eclipse
#if os(iOS) && !targetEnvironment(macCatalyst)
import ZIPFoundation
#endif

#if os(iOS)
final class ExperimentalCloudSyncPolicyTests: XCTestCase {
    func testUnchangedLocalRestoresNewerFullerRemote() {
        let baseline = footprint(libraryItems: 2, digest: "baseline")
        let remote = footprint(libraryItems: 3, digest: "remote")

        XCTAssertEqual(
            ExperimentalCloudReconciliationPolicy.actionForUnseenRemote(
                local: baseline,
                remote: remote,
                previous: baseline
            ),
            .restoreRemote
        )
    }

    func testChangedLocalAndChangedRemoteRequiresConflictChoice() {
        let baseline = footprint(libraryItems: 1, digest: "baseline")
        let local = footprint(libraryItems: 2, digest: "local")
        let remote = footprint(libraryItems: 3, digest: "remote")

        XCTAssertEqual(
            ExperimentalCloudReconciliationPolicy.actionForUnseenRemote(
                local: local,
                remote: remote,
                previous: baseline
            ),
            .concurrentConflict
        )
    }

    func testRemoteReductionNeverSilentlyErasesLocalDomain() {
        let local = footprint(libraryItems: 3, digest: "same")
        let remote = footprint(libraryItems: 1, digest: "same")

        XCTAssertEqual(
            ExperimentalCloudReconciliationPolicy.actionForUnseenRemote(
                local: local,
                remote: remote,
                previous: local
            ),
            .remoteWouldReduceLocalData
        )
    }

    func testRateLimitAndStorageQuotaHaveDifferentUserMessages() {
        let rateLimited = ExperimentalCloudSyncErrorPolicy.message(
            provider: .googleDrive,
            statusCode: 403,
            body: #"{"reason":"userRateLimitExceeded"}"#
        )
        let storageFull = ExperimentalCloudSyncErrorPolicy.message(
            provider: .googleDrive,
            statusCode: 403,
            body: #"{"reason":"storageQuotaExceeded"}"#
        )

        XCTAssertTrue(rateLimited.contains("temporarily limiting"))
        XCTAssertTrue(storageFull.contains("enough available storage"))
        XCTAssertFalse(rateLimited.contains("storage"))
    }

    func testInvalidGrantRequiresReconnectWithoutExposingProviderBody() {
        let body = #"{"error":"invalid_grant","error_description":"provider detail"}"#
        let message = ExperimentalCloudSyncErrorPolicy.message(
            provider: .oneDrive,
            statusCode: 400,
            body: body
        )

        XCTAssertTrue(ExperimentalCloudSyncErrorPolicy.requiresFreshAuthorization(
            statusCode: 400,
            body: body
        ))
        XCTAssertTrue(message.contains("Connect it again"))
        XCTAssertFalse(message.contains("provider detail"))
    }

    private func footprint(
        libraryItems: Int,
        digest: String
    ) -> ExperimentalCloudSnapshotFootprint {
        ExperimentalCloudSnapshotFootprint(
            libraryItems: libraryItems,
            movieProgress: 0,
            episodeProgress: 0,
            mangaLibraryItems: 0,
            mangaReadingProgress: 0,
            userRatings: 0,
            services: 0,
            stremioAddons: 0,
            skyStreamSources: 0,
            kanzenModules: 0,
            aidokuSources: 0,
            contentDigest: digest,
            contentDigestExcludingCloudKitMediaState: digest
        )
    }
}
#endif
private final class SkyStreamFixtureAnchor {}

private final class SkyStreamLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        storage += 1
        let value = storage
        lock.unlock()
        return value
    }
}

private enum SkyStreamTestFixture {
    static func data(named name: String) throws -> Data {
        let bundle = Bundle(for: SkyStreamFixtureAnchor.self)
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        return try Data(contentsOf: XCTUnwrap(url, "Missing test fixture \(name).json"))
    }
}

final class SkyStreamUntestedWarningAcknowledgementTests: XCTestCase {
    func testAcknowledgementIsBoundToCompleteNormalizedArchiveHash() throws {
        let suiteName = "SkyStreamUntestedWarningAcknowledgementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let originalHash = String(repeating: "aB", count: 32)
        let updatedHash = String(repeating: "cD", count: 32)

        XCTAssertFalse(SkyStreamUntestedWarningAcknowledgement.wasSeen(
            forArchiveSHA256: originalHash,
            defaults: defaults
        ))
        SkyStreamUntestedWarningAcknowledgement.markSeen(
            forArchiveSHA256: originalHash,
            defaults: defaults
        )
        XCTAssertTrue(SkyStreamUntestedWarningAcknowledgement.wasSeen(
            forArchiveSHA256: originalHash.lowercased(),
            defaults: defaults
        ))
        XCTAssertFalse(SkyStreamUntestedWarningAcknowledgement.wasSeen(
            forArchiveSHA256: updatedHash,
            defaults: defaults
        ))
    }

    func testInvalidOrMissingCatalogHashNeverSuppressesWarning() throws {
        let suiteName = "SkyStreamUntestedWarningAcknowledgementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for invalidHash in [nil, "", "abc", String(repeating: "g", count: 64)] as [String?] {
            SkyStreamUntestedWarningAcknowledgement.markSeen(
                forArchiveSHA256: invalidHash,
                defaults: defaults
            )
            XCTAssertFalse(SkyStreamUntestedWarningAcknowledgement.wasSeen(
                forArchiveSHA256: invalidHash,
                defaults: defaults
            ))
        }
    }

    func testDirectArchiveFingerprintChangesWithArchiveBytes() {
        let first = SkyStreamUntestedWarningAcknowledgement.archiveSHA256(
            for: Data("first archive".utf8)
        )
        let second = SkyStreamUntestedWarningAcknowledgement.archiveSHA256(
            for: Data("second archive".utf8)
        )

        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(
            SkyStreamUntestedWarningAcknowledgement.warningKey(forArchiveSHA256: first),
            SkyStreamUntestedWarningAcknowledgement.warningKey(forArchiveSHA256: second)
        )
    }
}

final class SkyStreamStableIdentityTests: XCTestCase {
    func testSubtitleIdentityIncludesHeadersButDoesNotExposeCredentialValues() {
        let first = SkyStreamSubtitleRecord(
            url: "https://subtitle.example.com/episode.vtt",
            label: "English",
            language: "en",
            headers: ["Authorization": "Bearer first-secret", "X-Mode": "one"]
        )
        let reordered = SkyStreamSubtitleRecord(
            url: first.url,
            label: first.label,
            language: first.language,
            headers: ["x-mode": "one", "authorization": "Bearer first-secret"]
        )
        let refreshedCredential = SkyStreamSubtitleRecord(
            url: first.url,
            label: first.label,
            language: first.language,
            headers: ["authorization": "Bearer second-secret", "x-mode": "one"]
        )

        XCTAssertEqual(first.id, reordered.id)
        XCTAssertNotEqual(first.id, refreshedCredential.id)
        XCTAssertEqual(first.id.count, 64)
        for sensitiveValue in ["first-secret", "Bearer", first.url] {
            XCTAssertFalse(first.id.contains(sensitiveValue))
        }
    }

    func testStableIDsPreserveLegacyComponentsAndEncodeOpaqueProviderIDs() throws {
        XCTAssertEqual(
            try SkyStreamStableID.validatedRootProvider(packageName: "fixture.plugin"),
            "skystream:fixture.plugin"
        )
        XCTAssertEqual(
            try SkyStreamStableID.validatedProvider(
                packageName: "fixture.plugin",
                providerID: "primary-hd"
            ),
            "skystream:fixture.plugin::primary-hd"
        )
        XCTAssertTrue(SkyStreamStableID.isValidProviderID("PRIME VIDEO"))
        XCTAssertTrue(SkyStreamStableID.isValidProviderID("provider/path::variant"))

        let opaqueID = try SkyStreamStableID.validatedProvider(
            packageName: "fixture.plugin",
            providerID: "PRIME VIDEO"
        )
        XCTAssertTrue(opaqueID.hasPrefix("skystream:fixture.plugin::encoded-"))
        XCTAssertEqual(
            opaqueID,
            try SkyStreamStableID.validatedProvider(
                packageName: "fixture.plugin",
                providerID: "PRIME VIDEO"
            )
        )
        XCTAssertFalse(opaqueID.contains("PRIME VIDEO"))

        let reservedPrefixID = try SkyStreamStableID.validatedProvider(
            packageName: "fixture.plugin",
            providerID: "encoded-provider"
        )
        XCTAssertNotEqual(reservedPrefixID, "skystream:fixture.plugin::encoded-provider")

        for packageName in [
            "PlugIn", "tiny", ".plugin", "plugin.", "plugin..child", "plugin/path", "plugin name"
        ] {
            XCTAssertFalse(
                SkyStreamStableID.isValidPackageName(packageName),
                "Unexpected valid package name: \(packageName)"
            )
        }
        for providerID in ["", "   ", "provider\nchild", "provider\u{202E}child"] {
            XCTAssertFalse(
                SkyStreamStableID.isValidProviderID(providerID),
                "Unexpected valid provider ID: \(providerID)"
            )
        }
        XCTAssertTrue(SkyStreamStableID.isValidProviderID(String(repeating: "a", count: 256)))
        XCTAssertFalse(SkyStreamStableID.isValidProviderID(String(repeating: "a", count: 257)))
    }

    func testSchemaV1ReferenceMigratesWithoutPersistingOpaqueProviderState() throws {
        let fixture = try SkyStreamTestFixture.data(named: "SkyStreamContentReferenceV1")
        let reference = try JSONDecoder().decode(SkyStreamProviderContentReference.self, from: fixture)

        XCTAssertEqual(reference.schemaVersion, 2)
        XCTAssertEqual(reference.packageName, "fixture.plugin")
        XCTAssertEqual(reference.providerID, "primary")
        XCTAssertEqual(reference.season, 1)
        XCTAssertEqual(reference.episode, 2)
        XCTAssertEqual(reference.title, "Fixture Show")
        XCTAssertEqual(reference.contentType, .series)
        XCTAssertTrue(reference.loadedItemURL.isEmpty)
        XCTAssertNil(reference.selectedEpisodeURL)
        XCTAssertTrue(reference.syncData.isEmpty)
        XCTAssertTrue(reference.additionalFields.isEmpty)
        XCTAssertTrue(reference.isStructurallyValid)

        let migrated = try JSONEncoder().encode(reference)
        let migratedText = try XCTUnwrap(String(data: migrated, encoding: .utf8))
        for forbiddenMarker in [
            "legacy-loaded-secret", "legacy-episode-secret", "legacy-sync-secret",
            "legacy-additional-secret", "loadedItemURL", "selectedEpisodeURL", "syncData",
            "additionalFields"
        ] {
            XCTAssertFalse(migratedText.contains(forbiddenMarker), forbiddenMarker)
        }
    }

    func testNewReferenceEncodingRetainsOnlyBoundedDeviceLocalRefreshIdentity() throws {
        let reference = SkyStreamProviderContentReference(
            packageName: "fixture.plugin",
            providerID: "primary",
            scriptSHA256: String(repeating: "B", count: 64),
            pluginVersion: 3,
            loadedItemURL: "  https://fixture.example/show/42  ",
            selectedEpisodeURL: "  episode://fixture/1  ",
            season: 0,
            episode: 1,
            preferredStreamLabel: "  Original  ",
            contentType: .anime,
            title: "  Fixture Anime  ",
            year: 2026
        )

        XCTAssertEqual(reference.scriptSHA256, String(repeating: "b", count: 64))
        XCTAssertEqual(reference.preferredStreamLabel, "Original")
        XCTAssertEqual(reference.title, "Fixture Anime")
        XCTAssertEqual(reference.loadedItemURL, "https://fixture.example/show/42")
        XCTAssertEqual(reference.selectedEpisodeURL, "episode://fixture/1")
        XCTAssertTrue(reference.isStructurallyValid)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(object["loadedItemURL"] as? String, reference.loadedItemURL)
        XCTAssertEqual(object["selectedEpisodeURL"] as? String, reference.selectedEpisodeURL)
        XCTAssertNil(object["syncData"])
        XCTAssertNil(object["additionalFields"])

        let decoded = try JSONDecoder().decode(
            SkyStreamProviderContentReference.self,
            from: JSONEncoder().encode(reference)
        )
        XCTAssertEqual(decoded, reference)
    }
}

final class SkyStreamRepositoryEnvelopeSecurityTests: XCTestCase {
    func testRepositoryMetadataWinsWhenRepositoryEmbedsPlugins() throws {
        let embedded = Data(#"""
        {
          "name": "Ambiguous Fixture",
          "packageName": "fixture.ambiguous",
          "manifestVersion": 1,
          "pluginLists": ["https://repo.example/plugins.json"],
          "plugins": []
        }
        """#.utf8)
        guard case .repository(let embeddedManifest) = try JSONDecoder().decode(
            SkyStreamRepositoryDocument.self,
            from: embedded
        ) else {
            return XCTFail("A repository with embedded plugins was misclassified as a plugin list.")
        }
        XCTAssertEqual(embeddedManifest.packageName, "fixture.ambiguous")

        let repository = Data(#"""
        {
          "name": "Repository Fixture",
          "packageName": "fixture.repository",
          "manifestVersion": 1,
          "pluginLists": ["https://repo.example/plugins.json"]
        }
        """#.utf8)
        guard case .repository(let manifest) = try JSONDecoder().decode(
            SkyStreamRepositoryDocument.self,
            from: repository
        ) else {
            return XCTFail("A repository-only envelope was misclassified.")
        }
        XCTAssertEqual(manifest.packageName, "fixture.repository")

        let pluginList = Data(#"{"plugins":[]}"#.utf8)
        guard case .pluginList(let document) = try JSONDecoder().decode(
            SkyStreamRepositoryDocument.self,
            from: pluginList
        ) else {
            return XCTFail("A plugin-list-only envelope was misclassified.")
        }
        XCTAssertTrue(document.plugins.isEmpty)

    }

    func testPluginManifestAcceptsSkyStreamDefaultsAndHistoricalAliases() throws {
        let minimal = try JSONDecoder().decode(
            SkyStreamPluginManifest.self,
            from: Data(#"{"packageName":"fixture.minimal"}"#.utf8)
        )
        XCTAssertEqual(minimal.name, "Unknown Plugin")
        XCTAssertEqual(minimal.version, 1)
        XCTAssertEqual(minimal.authors, [])
        XCTAssertEqual(minimal.baseURL, "")
        XCTAssertEqual(minimal.languages, [])
        XCTAssertEqual(minimal.categories, [])

        let aliases = try JSONDecoder().decode(
            SkyStreamPluginManifest.self,
            from: Data(#"""
            {
              "packageName": "fixture.aliases",
              "language": "ja",
              "tvTypes": ["anime", "movie"]
            }
            """#.utf8)
        )
        XCTAssertEqual(aliases.languages, ["ja"])
        XCTAssertEqual(aliases.categories, ["anime", "movie"])
        XCTAssertNil(aliases.additionalFields["language"])
        XCTAssertNil(aliases.additionalFields["tvTypes"])
    }

    func testPluginManifestIgnoresNonObjectDomainAndProviderEntriesLikeSkyStream() throws {
        let manifest = try JSONDecoder().decode(
            SkyStreamPluginManifest.self,
            from: Data(#"""
            {
              "packageName": "fixture.lossy-object-lists",
              "domains": [
                "https://legacy.example",
                {"name":"Working Domain","url":"https://working.example"},
                {"name":"Missing URL"},
                42
              ],
              "providers": [
                "legacy-provider",
                {"id":"working","name":"Working Provider"},
                {"name":"Missing ID"},
                false
              ]
            }
            """#.utf8)
        )

        XCTAssertEqual(manifest.domains?.map(\.url), ["https://working.example"])
        XCTAssertEqual(manifest.providers?.map(\.id), ["working"])
    }

    func testCNCVerseProviderIDsRemainOpaqueWhileSourceIDsStaySafe() throws {
        let manifest = try JSONDecoder().decode(
            SkyStreamPluginManifest.self,
            from: Data(#"""
            {
              "packageName": "dev.nivincnc.cncverse.cncverse",
              "name": "CNCVerse",
              "version": 9,
              "baseUrl": "https://net52.cc",
              "providers": [
                {"id":"NETFLIX","name":"Netflix"},
                {"id":"PRIME VIDEO","name":"Prime Video"},
                {"id":"HOTSTAR","name":"Hotstar"},
                {"id":"DISNEY PLUS","name":"Disney Plus"}
              ]
            }
            """#.utf8)
        )

        XCTAssertEqual(manifest.providers?[1].id, "PRIME VIDEO")
        XCTAssertEqual(manifest.providers?[3].id, "DISNEY PLUS")
        XCTAssertEqual(manifest.sourceIDs.count, 4)
        XCTAssertTrue(manifest.sourceIDs[1].contains("::encoded-"))
        XCTAssertFalse(manifest.sourceIDs[1].contains("PRIME VIDEO"))
        XCTAssertEqual(Set(manifest.sourceIDs).count, 4)
        XCTAssertTrue(SkyStreamRepositoryManager.isBoundedCatalogManifest(manifest))
    }

    func testRepositoryManifestDecodesIncludedReposAndEmbeddedPlugins() throws {
        let data = Data(#"""
        {
          "name": "Megarepo Fixture",
          "id": "fixture.megarepo",
          "repos": ["child", "https://repo.example/second.json"],
          "plugins": [
            {
              "packageName": "fixture.embedded",
              "language": "en",
              "types": "movie",
              "url": "https://repo.example/fixture.sky"
            }
          ]
        }
        """#.utf8)
        guard case .repository(let manifest) = try JSONDecoder().decode(
            SkyStreamRepositoryDocument.self,
            from: data
        ) else {
            return XCTFail("A megarepo manifest was not decoded as a repository.")
        }
        XCTAssertEqual(manifest.packageName, "fixture.megarepo")
        XCTAssertEqual(
            manifest.includedRepositories,
            ["child", "https://repo.example/second.json"]
        )
        XCTAssertEqual(manifest.plugins.count, 1)
        XCTAssertEqual(manifest.plugins.first?.manifest.version, 1)
        XCTAssertEqual(manifest.plugins.first?.manifest.languages, ["en"])
        XCTAssertEqual(manifest.plugins.first?.manifest.categories, ["movie"])
    }

    func testRepositoryEnvelopeVersionsRemainForwardCompatible() throws {
        let data = Data(#"""
        {
          "name": "ZORO",
          "packageName": "com.igris.repo",
          "manifestVersion": 3,
          "pluginLists": ["https://repo.example/plugins.json"]
        }
        """#.utf8)
        guard case .repository(let manifest) = try JSONDecoder().decode(
            SkyStreamRepositoryDocument.self,
            from: data
        ) else {
            return XCTFail("A forward-versioned repository was not decoded.")
        }

        XCTAssertEqual(manifest.manifestVersion, 3)
        XCTAssertTrue(
            SkyStreamRepositoryManager.isSupportedRepositoryManifestVersion(
                manifest.manifestVersion
            )
        )
        XCTAssertFalse(SkyStreamRepositoryManager.isSupportedRepositoryManifestVersion(0))
        XCTAssertFalse(SkyStreamRepositoryManager.isSupportedRepositoryManifestVersion(-1))

        let snapshot = SkyStreamRepositoryBackupSnapshot(
            sourceURL: "https://repo.example/repo.json",
            kind: .repository,
            manifest: manifest,
            pluginListURLs: manifest.pluginLists
        )
        XCTAssertTrue(SkyStreamBackupMetadataPolicy.isBounded(repository: snapshot))

        let cloudSnapshot = BackupData.skyStreamSnapshotForExperimentalCloudSync(
            SkyStreamBackupSnapshot(
                repositories: [snapshot],
                isSafeCloudSnapshot: true
            )
        )
        XCTAssertEqual(
            cloudSnapshot?.repositories.first?.manifest?.manifestVersion,
            3
        )
    }

    func testPluginListDocumentRejectsEveryMultipleEnvelopeKeyCombination() throws {
        let combinations = [
            ["plugins", "items"],
            ["plugins", "data"],
            ["items", "data"],
            ["plugins", "items", "data"]
        ]

        for keys in combinations {
            var object: [String: Any] = [:]
            for key in keys {
                object[key] = [Any]()
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            XCTAssertThrowsError(
                try JSONDecoder().decode(SkyStreamPluginListDocument.self, from: data),
                "Expected multiple envelope keys to be rejected: \(keys.joined(separator: ", "))"
            )
        }
    }

    func testSpreadPluginListCatalogKeysDoNotConsumeAdditionalFieldBudget() throws {
        let data = try JSONSerialization.data(
            withJSONObject: spreadPluginListEntry(additionalFieldCount: 32),
            options: [.sortedKeys]
        )
        let entry = try JSONDecoder().decode(SkyStreamPluginListEntry.self, from: data)
        let expectedKeys = Set((0..<32).map { String(format: "futureField%02d", $0) })
        let catalogKeys = ["url", "sha256", "checksum", "archiveSha256", "scriptSha256"]

        XCTAssertEqual(Set(entry.additionalFields.keys), expectedKeys)
        XCTAssertEqual(Set(entry.manifest.additionalFields.keys), expectedKeys)
        for key in catalogKeys {
            XCTAssertNil(entry.additionalFields[key], "Catalog key leaked into entry additional fields: \(key)")
            XCTAssertNil(
                entry.manifest.additionalFields[key],
                "Catalog key leaked into manifest additional fields: \(key)"
            )
        }
    }

    func testSpreadPluginListRejectsGenuinelyExcessiveAdditionalFields() throws {
        let data = try JSONSerialization.data(
            withJSONObject: spreadPluginListEntry(additionalFieldCount: 33),
            options: [.sortedKeys]
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(SkyStreamPluginListEntry.self, from: data)
        ) {
            XCTAssertEqual($0 as? SkyStreamJSONEnvelopeError, .excessiveContainerValues)
        }
    }

    private func spreadPluginListEntry(additionalFieldCount: Int) -> [String: Any] {
        var entry: [String: Any] = [
            "packageName": "fixture.catalog-budget",
            "name": "Catalog Budget Fixture",
            "version": 1,
            "authors": ["Eclipse Tests"],
            "baseUrl": "https://fixture.example",
            "languages": ["en"],
            "categories": ["movie"],
            "url": "https://fixture.example/plugin.sky",
            "sha256": String(repeating: "a", count: 64),
            "checksum": String(repeating: "b", count: 64),
            "archiveSha256": String(repeating: "c", count: 64),
            "scriptSha256": String(repeating: "d", count: 64)
        ]
        for index in 0..<additionalFieldCount {
            entry[String(format: "futureField%02d", index)] = index
        }
        return entry
    }
}

final class SkyStreamMediaStateDocumentTests: XCTestCase {
    func testManualAndMediaStateOpaqueFilesCannotAlias() {
        XCTAssertNotEqual(
            SkyStreamOpaqueStorageLayout.manualBackupFilename,
            SkyStreamOpaqueStorageLayout.mediaStateFilename
        )
        XCTAssertNotEqual(
            SkyStreamOpaqueStorageLayout.manualBackupFilename,
            SkyStreamOpaqueStorageLayout.experimentalCloudBackupFilename
        )
        XCTAssertNotEqual(
            SkyStreamOpaqueStorageLayout.experimentalCloudBackupFilename,
            SkyStreamOpaqueStorageLayout.mediaStateFilename
        )
        XCTAssertNotEqual(
            SkyStreamOpaqueStorageLayout.legacySharedFilename,
            SkyStreamOpaqueStorageLayout.mediaStateFilename
        )
        XCTAssertEqual(
            SkyStreamOpaqueStorageLayout.manualBackupFilename,
            "opaque-manual-backup-v1.json"
        )
        XCTAssertEqual(
            SkyStreamOpaqueStorageLayout.mediaStateFilename,
            "opaque-media-state-v1.json"
        )
        XCTAssertEqual(
            SkyStreamOpaqueStorageLayout.experimentalCloudBackupFilename,
            "opaque-cloud-backup-v1.json"
        )
        XCTAssertEqual(
            SkyStreamOpaqueStorageLayout.filenamesInvalidatedAfterWrite(
                isSafeCloudSnapshot: false
            ),
            [SkyStreamOpaqueStorageLayout.experimentalCloudBackupFilename]
        )
        XCTAssertTrue(
            SkyStreamOpaqueStorageLayout.filenamesInvalidatedAfterWrite(
                isSafeCloudSnapshot: true
            ).isEmpty
        )
    }

    func testMetadataDocumentStripsArchivesAndHasStableEncoding() throws {
        var snapshot = makeSnapshot(archive: Data(repeating: 0x41, count: 4_096))
        snapshot.repositories = [
            SkyStreamRepositoryBackupSnapshot(
                sourceURL: "https://repo.example/z-list.json",
                kind: .pluginList,
                name: "Z Fixture List",
                pluginListURLs: ["https://repo.example/z-list.json"],
                lastRefreshedAt: Date(),
                frozenAt: Date()
            ),
            SkyStreamRepositoryBackupSnapshot(
                sourceURL: "https://repo.example/a-list.json",
                kind: .pluginList,
                name: "A Fixture List",
                pluginListURLs: ["https://repo.example/a-list.json"],
                lastRefreshedAt: Date()
            )
        ]
        snapshot.plugins[0].state.preferences["layout"] = SkyStreamPreferenceValue(
            value: .string("compact"),
            updatedAt: Date()
        )
        snapshot.plugins[0].state.compatibility = SkyStreamCompatibilityResult(
            status: .compatible,
            evaluatedAt: Date()
        )
        snapshot.plugins[0].state.provenance.expectedArchiveSHA256 = String(repeating: "c", count: 64)
        snapshot.plugins[0].state.provenance.frozenAt = Date()
        snapshot.plugins[0].state.providers.append(contentsOf: [
            SkyStreamProviderState(
                packageName: "fixture.plugin",
                providerID: "z-provider",
                lastSeenPluginVersion: 1
            ),
            SkyStreamProviderState(
                packageName: "fixture.plugin",
                providerID: "removed-provider",
                lastSeenPluginVersion: 1,
                removedAt: Date()
            )
        ])

        var secondPlugin = snapshot.plugins[0]
        secondPlugin.state.manifest.packageName = "fixture.second"
        secondPlugin.state.manifest.name = "Second Fixture"
        secondPlugin.state.providers = secondPlugin.state.providers.map { provider in
            var provider = provider
            provider.packageName = "fixture.second"
            return provider
        }
        secondPlugin.state.provenance.sourceURL = "https://plugins.example/second.sky"
        snapshot.plugins.append(secondPlugin)

        let first = try SkyStreamMediaStateDocument.encodeMetadataOnly(snapshot)
        var recaptured = snapshot
        recaptured.createdAt = Date().addingTimeInterval(60)
        recaptured.repositories.reverse()
        recaptured.repositories[0].lastRefreshedAt = Date().addingTimeInterval(90)
        recaptured.repositories[0].frozenAt = Date().addingTimeInterval(100)
        recaptured.plugins.reverse()
        for index in recaptured.plugins.indices {
            recaptured.plugins[index].state.installedAt = Date().addingTimeInterval(120)
            recaptured.plugins[index].state.updatedAt = Date().addingTimeInterval(180)
            recaptured.plugins[index].state.provenance.pinnedAt = Date().addingTimeInterval(240)
            recaptured.plugins[index].state.provenance.frozenAt = Date().addingTimeInterval(300)
            recaptured.plugins[index].state.provenance.expectedArchiveSHA256 = nil
            recaptured.plugins[index].state.compatibility = SkyStreamCompatibilityResult(
                status: .incompatible,
                reasons: [.init(code: .invalidPackage, message: "device-local evaluation")],
                evaluatedAt: Date().addingTimeInterval(360)
            )
            recaptured.plugins[index].state.preferences["layout"]?.updatedAt = Date().addingTimeInterval(420)
            recaptured.plugins[index].preferencesWereRedacted.toggle()
            recaptured.plugins[index].state.providers.reverse()
            for providerIndex in recaptured.plugins[index].state.providers.indices
                where recaptured.plugins[index].state.providers[providerIndex].removedAt != nil {
                recaptured.plugins[index].state.providers[providerIndex].removedAt = Date().addingTimeInterval(480)
            }
        }
        let second = try SkyStreamMediaStateDocument.encodeMetadataOnly(recaptured)
        let decoded = try SkyStreamMediaStateDocument.decodeMetadataOnly(first)

        XCTAssertEqual(first, second)
        XCTAssertLessThan(first.count, SkyStreamMediaStateDocument.maximumPayloadBytes)
        XCTAssertNil(decoded.plugins.first?.archivePayload)
        XCTAssertEqual(decoded.plugins.first?.payloadWasRedacted, true)
        XCTAssertEqual(decoded.createdAt, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(decoded.repositories.map(\.sourceURL), decoded.repositories.map(\.sourceURL).sorted())
        XCTAssertEqual(decoded.plugins.map(\.id), decoded.plugins.map(\.id).sorted())
        XCTAssertTrue(decoded.plugins.allSatisfy { plugin in
            plugin.state.providers.allSatisfy { $0.removedAt == nil }
                && plugin.state.providers.map(\.id) == plugin.state.providers.map(\.id).sorted()
        })
    }

    func testMetadataDocumentRejectsManualOrCredentialedState() {
        var manual = makeSnapshot()
        manual.isSafeCloudSnapshot = false
        XCTAssertThrowsError(try SkyStreamMediaStateDocument.encodeMetadataOnly(manual))

        var credentialed = makeSnapshot()
        credentialed.plugins[0].state.provenance.sourceURL =
            "https://plugins.example/archive.sky?access_token=secret"
        XCTAssertThrowsError(try SkyStreamMediaStateDocument.encodeMetadataOnly(credentialed))

        var secretPreference = makeSnapshot()
        secretPreference.plugins[0].state.preferences["apiToken"] = SkyStreamPreferenceValue(
            value: .string("opaque"),
            isSecret: false
        )
        XCTAssertThrowsError(try SkyStreamMediaStateDocument.encodeMetadataOnly(secretPreference))
    }

    func testMetadataDocumentRejectsPayloadAboveCloudKitHeadroom() {
        var first = makeSnapshot().plugins[0]
        first.state.preferences = Dictionary(uniqueKeysWithValues: (0..<8).map {
            (
                "layout-\($0)",
                SkyStreamPreferenceValue(
                    value: .string(String(repeating: "x", count: 50 * 1_024))
                )
            )
        })
        XCTAssertTrue(SkyStreamBackupMetadataPolicy.isBounded(pluginState: first.state))

        var second = first
        second.state.manifest.packageName = "fixture.second"
        let secondPackageID = second.state.manifest.packageName
        second.state.providers = second.state.providers.map { provider in
            var provider = provider
            provider.packageName = secondPackageID
            return provider
        }
        second.state.provenance.sourceURL = "https://plugins.example/second.sky"
        XCTAssertTrue(SkyStreamBackupMetadataPolicy.isBounded(pluginState: second.state))

        let snapshot = SkyStreamBackupSnapshot(
            plugins: [first, second],
            isSafeCloudSnapshot: true
        )

        XCTAssertThrowsError(try SkyStreamMediaStateDocument.encodeMetadataOnly(snapshot)) {
            XCTAssertEqual(
                $0 as? SkyStreamMediaStateDocument.ValidationError,
                .payloadTooLarge
            )
        }
    }

    func testCloudSanitizerOmitsRowsOutsideNormalRuntimeQuotas() {
        var oversizedPreference = makeSnapshot()
        oversizedPreference.plugins[0].state.preferences["layout"] = SkyStreamPreferenceValue(
            value: .string(String(repeating: "x", count: 70 * 1_024))
        )
        let sanitized = BackupData.skyStreamSnapshotForExperimentalCloudSync(
            oversizedPreference
        )
        XCTAssertTrue(sanitized?.plugins.isEmpty == true)

        var oversizedProviders = makeSnapshot().plugins[0].state
        let packageID = oversizedProviders.id
        let pluginVersion = oversizedProviders.manifest.version
        oversizedProviders.providers = (0...SkyStreamBackupMetadataPolicy.maximumProviderStates).map {
            SkyStreamProviderState(
                packageName: packageID,
                providerID: "provider-\($0)",
                lastSeenPluginVersion: pluginVersion
            )
        }
        XCTAssertFalse(
            SkyStreamBackupMetadataPolicy.isBounded(pluginState: oversizedProviders)
        )

        let withArchive = makeSnapshot(archive: Data(repeating: 0x41, count: 4_096))
        let metadataOnly = BackupData.skyStreamSnapshotForExperimentalCloudSync(
            withArchive,
            stripArchives: true
        )
        XCTAssertNil(metadataOnly?.plugins.first?.archivePayload)
        XCTAssertEqual(metadataOnly?.plugins.first?.payloadWasRedacted, true)
    }

    @MainActor
    func testSafeCloudArchiveCannotReplaceExistingCodeByClaimingItsSource() {
        let existing = makeSnapshot().plugins[0].state

        XCTAssertTrue(SkyStreamPluginManager.safeCloudArchiveMayInstall(
            incoming: existing,
            over: existing
        ))
        XCTAssertTrue(SkyStreamPluginManager.safeCloudArchiveMayInstall(
            incoming: existing,
            over: nil
        ))

        var forgedUpgrade = existing
        forgedUpgrade.manifest.version += 1
        forgedUpgrade.archiveSHA256 = String(repeating: "c", count: 64)
        forgedUpgrade.scriptSHA256 = String(repeating: "d", count: 64)
        XCTAssertFalse(SkyStreamPluginManager.safeCloudArchiveMayInstall(
            incoming: forgedUpgrade,
            over: existing
        ))

        var forgedOwner = existing
        forgedOwner.provenance.sourceURL = "https://plugins.example/takeover.sky"
        XCTAssertFalse(SkyStreamPluginManager.safeCloudArchiveMayInstall(
            incoming: forgedOwner,
            over: existing
        ))
    }

    @MainActor
    func testSafeCloudMergePreservesExistingRepositoryAndSecretPreferences() {
        let sourceURL = "https://repo.example/repository.json"
        let current = SkyStreamSavedRepository(
            sourceURL: sourceURL,
            kind: .repository,
            name: "Locally verified",
            pluginListURLs: ["https://repo.example/verified-list.json"],
            plugins: []
        )
        let incoming = SkyStreamSavedRepository(
            sourceURL: sourceURL,
            kind: .repository,
            name: "Cloud replacement",
            pluginListURLs: ["https://attacker.example/replacement.json"],
            plugins: []
        )
        XCTAssertEqual(
            SkyStreamPluginManager.mergingSafeCloudRepositories(
                current: [current],
                incoming: [incoming]
            ),
            [current]
        )

        let localSecret = SkyStreamPreferenceValue(
            value: .string("device-secret"),
            isSecret: true
        )
        let merged = SkyStreamPluginManager.mergingSafeCloudPreferences(
            local: [
                "token": localSecret,
                "quality": SkyStreamPreferenceValue(value: .string("720p"))
            ],
            incoming: [
                "token": SkyStreamPreferenceValue(value: .string("forged-public")),
                "quality": SkyStreamPreferenceValue(value: .string("1080p")),
                "newSecret": SkyStreamPreferenceValue(
                    value: .string("must-not-arrive"),
                    isSecret: true
                )
            ]
        )
        XCTAssertEqual(merged["token"], localSecret)
        XCTAssertEqual(merged["quality"]?.value, .string("1080p"))
        XCTAssertNil(merged["newSecret"])
    }

    @MainActor
    func testSafeCloudPreferenceUnionCannotExceedRuntimeQuota() {
        let local = Dictionary(uniqueKeysWithValues: (0..<256).map {
            ("local-\($0)", SkyStreamPreferenceValue(value: .number(Double($0))))
        })
        let incoming = Dictionary(uniqueKeysWithValues: (0..<256).map {
            ("remote-\($0)", SkyStreamPreferenceValue(value: .number(Double($0))))
        })
        XCTAssertTrue(SkyStreamBackupMetadataPolicy.preferencesAreBounded(local))
        XCTAssertTrue(SkyStreamBackupMetadataPolicy.preferencesAreBounded(incoming))

        let merged = SkyStreamPluginManager.mergingSafeCloudPreferences(
            local: local,
            incoming: incoming
        )
        XCTAssertEqual(merged.count, 256)
        XCTAssertTrue(Set(local.keys).isSubset(of: Set(merged.keys)))
        XCTAssertTrue(SkyStreamBackupMetadataPolicy.preferencesAreBounded(merged))
    }

    @MainActor
    func testSafeCloudExplicitRuleMergePreservesDuplicateNonSkyValues() {
        let first = SkyStreamProviderState(
            packageName: "fixture.rules",
            providerID: "first",
            isExplicitlySelectedForExtraRules: false,
            lastSeenPluginVersion: 1
        )
        let second = SkyStreamProviderState(
            packageName: "fixture.rules",
            providerID: "second",
            isExplicitlySelectedForExtraRules: true,
            lastSeenPluginVersion: 1
        )
        let explicit = [
            "service.duplicate", first.id, "service.duplicate",
            "stremio.addon", second.id, "service.tail"
        ]
        let snapshot = SkyStreamPluginManager.SkySourceDefaultsSnapshot(
            selectedIDs: [],
            orderIDs: explicit,
            explicitIDs: explicit
        )

        let merged = SkyStreamPluginManager.mergedSafeCloudSourceDefaults(
            baseline: snapshot,
            current: snapshot,
            incomingBySourceID: [first.id: first, second.id: second],
            allCurrentSourceIDs: [first.id, second.id]
        )

        XCTAssertEqual(
            merged.explicitIDs,
            [
                "service.duplicate", "service.duplicate",
                "stremio.addon", "service.tail", second.id
            ]
        )
    }

    @MainActor
    func testSafeCloudExplicitRuleMergeHandlesAllModeAndUnspecifiedMembership() {
        let excluded = SkyStreamProviderState(
            packageName: "fixture.rules",
            providerID: "excluded",
            isExplicitlySelectedForExtraRules: false,
            lastSeenPluginVersion: 1
        )
        let siblingID = SkyStreamStableID.sourceID(
            packageName: "fixture.rules",
            providerID: "sibling"
        )
        let allMode = SkyStreamPluginManager.SkySourceDefaultsSnapshot(
            selectedIDs: [],
            orderIDs: ["service.one", excluded.id, siblingID],
            explicitIDs: nil
        )
        let excludedFromAll = SkyStreamPluginManager.mergedSafeCloudSourceDefaults(
            baseline: allMode,
            current: allMode,
            incomingBySourceID: [excluded.id: excluded],
            allCurrentSourceIDs: [excluded.id, siblingID]
        )
        XCTAssertEqual(excludedFromAll.explicitIDs, ["service.one", siblingID])

        var unspecified = excluded
        unspecified.isExplicitlySelectedForExtraRules = nil
        let unchangedAll = SkyStreamPluginManager.mergedSafeCloudSourceDefaults(
            baseline: allMode,
            current: allMode,
            incomingBySourceID: [unspecified.id: unspecified],
            allCurrentSourceIDs: [unspecified.id, siblingID]
        )
        XCTAssertNil(unchangedAll.explicitIDs)
    }

    @MainActor
    func testSafeCloudExplicitRuleMergeLetsConcurrentLocalMembershipWin() {
        let first = SkyStreamProviderState(
            packageName: "fixture.rules",
            providerID: "first",
            isExplicitlySelectedForExtraRules: true,
            lastSeenPluginVersion: 1
        )
        let second = SkyStreamProviderState(
            packageName: "fixture.rules",
            providerID: "second",
            isExplicitlySelectedForExtraRules: false,
            lastSeenPluginVersion: 1
        )
        let baseline = SkyStreamPluginManager.SkySourceDefaultsSnapshot(
            selectedIDs: [],
            orderIDs: [first.id, second.id],
            explicitIDs: ["service.local", first.id]
        )
        let current = SkyStreamPluginManager.SkySourceDefaultsSnapshot(
            selectedIDs: [],
            orderIDs: [first.id, second.id],
            explicitIDs: ["service.local", "service.local", second.id]
        )
        let merged = SkyStreamPluginManager.mergedSafeCloudSourceDefaults(
            baseline: baseline,
            current: current,
            incomingBySourceID: [first.id: first, second.id: second],
            allCurrentSourceIDs: [first.id, second.id]
        )
        XCTAssertEqual(merged.explicitIDs, current.explicitIDs)

        let baselineAll = SkyStreamPluginManager.SkySourceDefaultsSnapshot(
            selectedIDs: [],
            orderIDs: [first.id],
            explicitIDs: nil
        )
        let locallyChangedMode = SkyStreamPluginManager.SkySourceDefaultsSnapshot(
            selectedIDs: [],
            orderIDs: [first.id],
            explicitIDs: ["service.local", first.id]
        )
        var remoteExclusion = first
        remoteExclusion.isExplicitlySelectedForExtraRules = false
        let modeMerge = SkyStreamPluginManager.mergedSafeCloudSourceDefaults(
            baseline: baselineAll,
            current: locallyChangedMode,
            incomingBySourceID: [first.id: remoteExclusion],
            allCurrentSourceIDs: [first.id]
        )
        XCTAssertEqual(modeMerge.explicitIDs, locallyChangedMode.explicitIDs)
    }

    private func makeSnapshot(archive: Data? = nil) -> SkyStreamBackupSnapshot {
        let manifest = SkyStreamPluginManifest(
            packageName: "fixture.plugin",
            name: "Fixture",
            version: 1,
            authors: ["Fixture Author"],
            baseURL: "https://video.example",
            languages: ["en"],
            categories: ["movie"]
        )
        let provenance = SkyStreamInstallProvenance(
            kind: .directArchive,
            sourceURL: "https://plugins.example/fixture.sky"
        )
        let state = SkyStreamInstalledPluginState(
            manifest: manifest,
            archiveSHA256: String(repeating: "a", count: 64),
            scriptSHA256: String(repeating: "b", count: 64),
            payloadRelativePath: "",
            provenance: provenance,
            providers: [
                SkyStreamProviderState(
                    packageName: manifest.packageName,
                    lastSeenPluginVersion: manifest.version
                )
            ]
        )
        return SkyStreamBackupSnapshot(
            plugins: [
                SkyStreamPluginBackupSnapshot(
                    state: state,
                    archivePayload: archive,
                    payloadWasRedacted: archive == nil
                )
            ],
            isSafeCloudSnapshot: true
        )
    }
}

final class SkyStreamCloudProgressPrivacyTests: XCTestCase {
    func testExperimentalCloudRedactionRemovesDeviceLocalProviderURLs() throws {
        let reference = SkyStreamProviderContentReference(
            packageName: "fixture.plugin",
            providerID: "primary",
            scriptSHA256: String(repeating: "a", count: 64),
            pluginVersion: 1,
            loadedItemURL: "https://provider.example/title/42?signed=movie-secret",
            selectedEpisodeURL: "https://provider.example/episode/7?signed=episode-secret",
            season: 1,
            episode: 7,
            contentType: .series,
            title: "Fixture Show",
            year: 2026
        )
        var progress = ProgressData()
        var movie = MovieProgressEntry(id: 42, title: "Fixture Movie")
        movie.lastHref = "https://media.example/movie.mp4?token=movie-playback-secret"
        movie.lastSourceId = reference.sourceID
        movie.lastContentReference = .skyStream(reference)
        progress.movieProgress = [movie]

        var episode = EpisodeProgressEntry(showId: 42, seasonNumber: 1, episodeNumber: 7)
        episode.lastHref = "https://media.example/episode.m3u8?token=episode-playback-secret"
        episode.lastSourceId = reference.sourceID
        episode.lastContentReference = .skyStream(reference)
        progress.episodeProgress = [episode]

        let backup = BackupData(
            createdDate: Date(),
            tmdbLanguage: "en",
            selectedAppearance: "system",
            enableSubtitlesByDefault: false,
            defaultSubtitleLanguage: "en",
            playerSubtitleAppearanceEnabled: true,
            preferredAutoAudioLanguage: "en",
            preferredAnimeAudioLanguage: "ja",
            inAppPlayer: "mpv",
            showScheduleTab: true,
            showLocalScheduleTime: true,
            progressData: progress
        )

        let redacted = backup.redactedForExperimentalCloudSync()
        XCTAssertNil(redacted.progressData.movieProgress.first?.lastHref)
        XCTAssertNil(redacted.progressData.movieProgress.first?.lastContentReference)
        XCTAssertNil(redacted.progressData.episodeProgress.first?.lastHref)
        XCTAssertNil(redacted.progressData.episodeProgress.first?.lastContentReference)
        XCTAssertEqual(redacted.progressData.movieProgress.first?.lastSourceId, reference.sourceID)
        XCTAssertEqual(redacted.progressData.episodeProgress.first?.lastSourceId, reference.sourceID)

        let encoded = try JSONEncoder().encode(redacted)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for secret in [
            "movie-secret", "episode-secret", "movie-playback-secret", "episode-playback-secret"
        ] {
            XCTAssertFalse(json.contains(secret), secret)
        }
    }
}

final class SkyStreamRuntimeABIEdgeCaseTests: XCTestCase {
#if os(iOS) && !targetEnvironment(macCatalyst)
    func testResolverScoresPluginAlternateAnimeTitlesAgainstKnownAliases() {
        let target = SkyStreamResolutionTarget(
            kind: .episode,
            title: "Attack on Titan: The Final Season",
            aliases: ["Shingeki no Kyojin: The Final Season"],
            season: 4,
            episode: 1,
            isAnime: true
        )

        let score = SkyStreamResolver.titleMatchScore(
            candidateTitle: "L'Attaque des Titans Saison Finale",
            candidateAlternateTitles: ["Shingeki no Kyojin: The Final Season"],
            target: target
        )

        XCTAssertGreaterThanOrEqual(score, 0.85)
    }

    func testResolverUsesItsOwnFixedTitleIdentityBoundaries() {
        XCTAssertFalse(SkyStreamResolver.acceptsTitleMatch(
            score: 0.8499,
            requiresExactIdentity: false
        ))
        XCTAssertTrue(SkyStreamResolver.acceptsTitleMatch(
            score: 0.85,
            requiresExactIdentity: false
        ))
        XCTAssertFalse(SkyStreamResolver.acceptsTitleMatch(
            score: 0.8999,
            requiresExactIdentity: true
        ))
        XCTAssertTrue(SkyStreamResolver.acceptsTitleMatch(
            score: 0.90,
            requiresExactIdentity: true
        ))
    }

    func testResolverAcceptsOnlyExplicitUnambiguousOptionalEpisodeIdentity() {
        let target = SkyStreamResolutionTarget(
            kind: .episode,
            title: "Fixture Anime Part 2",
            aliases: ["Fixture Anime Second Cour"],
            season: 2,
            episode: 3,
            absoluteEpisodeCandidates: [15],
            isAnime: true
        )

        let sdkDefaultSeason = SkyStreamEpisodeRecord(
            name: "Episode 3",
            url: "https://provider.example/default-season",
            season: 0,
            episode: 3
        )
        XCTAssertEqual(
            SkyStreamResolver.selectExplicitEpisode(
                from: [sdkDefaultSeason],
                target: target
            )?.url,
            sdkDefaultSeason.url
        )

        for label in ["S02E03", "2x03", "Season 2 - Episode 3", "Episode 15"] {
            let labeled = SkyStreamEpisodeRecord(
                name: label,
                url: "https://provider.example/\(label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "episode")",
                season: 0,
                episode: 0
            )
            XCTAssertEqual(
                SkyStreamResolver.selectExplicitEpisode(from: [labeled], target: target)?.url,
                labeled.url,
                label
            )
        }
    }

    func testResolverRejectsAmbiguousOrContradictoryEpisodeLabels() {
        let target = SkyStreamResolutionTarget(
            kind: .episode,
            title: "Fixture Show",
            season: 2,
            episode: 3
        )
        let ambiguous = [
            SkyStreamEpisodeRecord(
                name: "Episode 3",
                url: "https://provider.example/first",
                season: 0,
                episode: 0
            ),
            SkyStreamEpisodeRecord(
                name: "Ep. 3",
                url: "https://provider.example/second",
                season: 0,
                episode: 0
            )
        ]
        XCTAssertNil(SkyStreamResolver.selectExplicitEpisode(from: ambiguous, target: target))

        for label in ["S01E03", "Season 2 Episode 4", "Special Episode 3", "Chapter 3"] {
            let candidate = SkyStreamEpisodeRecord(
                name: label,
                url: "https://provider.example/wrong",
                season: 0,
                episode: label == "S01E03" ? 3 : 0
            )
            XCTAssertNil(
                SkyStreamResolver.selectExplicitEpisode(from: [candidate], target: target),
                label
            )
        }
    }

    func testResolverDoesNotTreatItemPlaybackPolicyAsExternalPlayerRequirement() {
        let stream = SkyStreamStreamRecord(url: "https://media.example/video.mp4")
        let loaded = SkyStreamLoadedItemRecord(
            title: "Fixture",
            url: "https://provider.example/item",
            playbackPolicy: "Internal Player Only"
        )
        let episode = SkyStreamEpisodeRecord(
            name: "Episode 1",
            url: "https://provider.example/episode/1",
            season: 1,
            episode: 1,
            playbackPolicy: "External Player Only"
        )

        let candidate = SkyStreamResolver.rawCandidate(
            stream,
            loaded: loaded,
            episode: episode
        )

        XCTAssertNil(candidate.externalPlayerPolicy)
        XCTAssertFalse(candidate.isLive)
    }
#endif

    func testHTMLBridgeReusesBoundedContextLocalDocumentsAndInvalidatesHandles() throws {
        let bridge = SkyStreamHTMLBridge(
            maximumCachedDocuments: 2,
            maximumCachedHTMLBytes: 4_096
        )
        let firstHTML = "<html><body><a class='item' href='/one'>One</a><p>Text</p></body></html>"
        let firstHandle = try openHTML(firstHTML, using: bridge)

        let links = try queryHTML(handle: firstHandle, selector: "a.item", using: bridge)
        let paragraphs = try queryHTML(handle: firstHandle, selector: "p", using: bridge)
        XCTAssertEqual(links.first?["text"] as? String, "One")
        XCTAssertEqual(paragraphs.first?["text"] as? String, "Text")

        // A raw compatibility request for the same source must hit the same
        // parsed tree rather than creating a parallel cache entry.
        let legacy = try bridgeRequest([
            "html": firstHTML,
            "selector": "body",
            "attr": NSNull()
        ], using: bridge)
        XCTAssertEqual((legacy as? [[String: Any]])?.count, 1)
        XCTAssertEqual(bridge.diagnostics.parseCount, 1)
        XCTAssertEqual(bridge.diagnostics.cachedDocumentCount, 1)

        let secondHandle = try openHTML("<html><body><b>Two</b></body></html>", using: bridge)
        _ = try queryHTML(handle: firstHandle, selector: "body", using: bridge)
        _ = try openHTML("<html><body><i>Three</i></body></html>", using: bridge)

        let secondAfterEviction = try bridgeRequest([
            "action": "query",
            "handle": secondHandle,
            "selector": "body"
        ], using: bridge)
        XCTAssertEqual((secondAfterEviction as? [String: Any])?["cacheMiss"] as? Bool, true)
        XCTAssertEqual(bridge.diagnostics.cachedDocumentCount, 2)
        XCTAssertLessThanOrEqual(bridge.diagnostics.cachedHTMLBytes, 4_096)

        bridge.invalidate()
        XCTAssertTrue(bridge.diagnostics.isInvalidated)
        XCTAssertEqual(bridge.diagnostics.cachedDocumentCount, 0)
        XCTAssertEqual(bridge.diagnostics.cachedHTMLBytes, 0)
        let invalidated = try queryHTML(handle: firstHandle, selector: "body", using: bridge)
        XCTAssertTrue(invalidated.isEmpty)
    }

    func testSetCookieResponseHeadersRemainSeparateWithoutSplittingExpiresDates() {
        let projected = SkyStreamHTTPResponseHeaderProjection.project([
            "Set-Cookie": "token=one; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/, session=two; HttpOnly",
            "X-Fixture": "present"
        ])

        XCTAssertEqual(projected["x-fixture"] as? String, "present")
        XCTAssertEqual(projected["set-cookie"] as? [String], [
            "token=one; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/",
            "session=two; HttpOnly"
        ])
    }

    func testSkyStreamCompatibilityDropsOnlyTransportControlledHeaders() {
        let normalized = SkyStreamRuntimeHeaderCompatibility.droppingControlled([
            "Accept-Encoding": "gzip",
            "Connection": "keep-alive",
            "Host": "forged.example",
            "Proxy-Authorization": "secret",
            "Cookie": "session=allowed",
            "Referer": "https://allowed.example/page",
            "X-Requested-With": "XMLHttpRequest"
        ])

        XCTAssertNil(normalized["Accept-Encoding"])
        XCTAssertNil(normalized["Connection"])
        XCTAssertNil(normalized["Host"])
        XCTAssertNil(normalized["Proxy-Authorization"])
        XCTAssertEqual(normalized["Cookie"], "session=allowed")
        XCTAssertEqual(normalized["Referer"], "https://allowed.example/page")
        XCTAssertEqual(normalized["X-Requested-With"], "XMLHttpRequest")
    }

    func testRuntimePreservesLargeMagicValueInfersLanguageAndSupportsLongShows() async throws {
        let fixture = try makeRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scriptURL.deletingLastPathComponent()) }

        let pool = SkyStreamRuntimePool()
        let loaded = try await pool.load(using: fixture.configuration, url: "https://fixture.example/show")
        XCTAssertEqual(loaded.episodes.count, 512)
        XCTAssertEqual(loaded.episodes.last?.episode, 512)
        XCTAssertEqual(loaded.episodes[0].dubStatus, .dubbed)
        XCTAssertEqual(loaded.episodes[1].dubStatus, .subbed)
        XCTAssertEqual(loaded.episodes[2].dubStatus, .subbed, "An explicit value must win over the name")
        XCTAssertEqual(loaded.episodes[3].dubStatus, .dubbed, "Episode's default none should permit name inference")

        let large = try await pool.loadStreams(using: fixture.configuration, url: "large")
        XCTAssertEqual(large.count, 1)
        XCTAssertTrue(large[0].url.hasPrefix("magic_m3u8:"))
        XCTAssertEqual(large[0].url.count, "magic_m3u8:".count + 400_000)

        do {
            _ = try await pool.loadStreams(using: fixture.configuration, url: "oversized")
            XCTFail("Expected an oversized result to fail instead of being truncated")
        } catch let error as SkyStreamRuntimeError {
            XCTAssertEqual(error, .resultTooLarge)
        }
    }

    func testGetAndUnpackIsWhitespaceTolerantAndSupportsBase95() async throws {
        let fixture = try makeRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scriptURL.deletingLastPathComponent()) }

        let pool = SkyStreamRuntimePool()
        let base36 = try await pool.loadStreams(using: fixture.configuration, url: "packed36")
        XCTAssertEqual(base36.first?.url, "https://video.example.com/path")

        let base95 = try await pool.loadStreams(using: fixture.configuration, url: "packed95")
        XCTAssertEqual(base95.first?.url, "https://video.example.com/path")
    }

    func testParseHtmlAndJSDOMAliasesStillUseDocumentSemantics() async throws {
        let fixture = try makeRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scriptURL.deletingLastPathComponent()) }

        let pool = SkyStreamRuntimePool()
        let loaded = try await pool.load(using: fixture.configuration, url: "dom-aliases")
        XCTAssertEqual(loaded.title, "Heading|Link|/video")
    }

    func testDOMRelationsClassNameAndNativeHelpersMatchSkyStreamContracts() async throws {
        let fixture = try makeRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scriptURL.deletingLastPathComponent()) }

        let pool = SkyStreamRuntimePool()
        let relations = try await pool.load(using: fixture.configuration, url: "dom-relations")
        XCTAssertEqual(relations.title, "item chosen|wrapper|One|Three|3")

        let helpers = try await pool.load(using: fixture.configuration, url: "native-helpers")
        XCTAssertEqual(
            helpers.title,
            "Heading|One,Two|Heading|1,2|One,Two|5d41402abc4b2a76b9719d911017c592"
        )

        let headerOptions = try await pool.load(
            using: fixture.configuration,
            url: "header-options"
        )
        XCTAssertEqual(headerOptions.title, "cookie/direct|cookie/nested|nested|true")

        let streams = try await pool.loadStreams(
            using: fixture.configuration,
            url: "controlled-headers"
        )
        XCTAssertEqual(streams.first?.headers["cookie"], "session=allowed")
        XCTAssertEqual(streams.first?.headers["referer"], "https://allowed.example/page")
        XCTAssertNil(streams.first?.headers["host"])
        XCTAssertNil(streams.first?.headers["connection"])
        XCTAssertNil(streams.first?.headers["accept-encoding"])
    }

    func testLocalExtractorRegistryCoversAnichiOrdinaryVODHosts() async throws {
        let fixture = try makeRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scriptURL.deletingLastPathComponent()) }

        let streams = try await SkyStreamRuntimePool().loadStreams(
            using: fixture.configuration,
            url: "extractor-registry"
        )

        XCTAssertEqual(streams.count, 7)
        XCTAssertEqual(Set(streams.compactMap(\.source)), [
            "DoodStream", "Filemoon", "HubCloud 1080p", "MixDrop", "StreamTape", "Voe"
        ])
        XCTAssertTrue(streams.contains { $0.url.hasPrefix("https://cdn.example/dood/") })
        XCTAssertTrue(streams.contains { $0.url == "https://cdn.example/hubcloud.mp4" })
        XCTAssertTrue(streams.contains { $0.url == "https://cdn.example/mixdrop.mp4" })
        XCTAssertTrue(streams.contains { $0.url == "https://streamtape.test/get_video?id=abc" })
        XCTAssertTrue(streams.contains { $0.url == "https://cdn.example/voe.m3u8" })
        XCTAssertEqual(
            Set(streams.filter { $0.source == "Filemoon" }.compactMap(\.quality)),
            [720, 1080]
        )
        XCTAssertTrue(streams.allSatisfy { $0.url.hasPrefix("https://") })
    }

    func testLocalExtractorRegistrySupportsPromiseAndLegacyCallbackForms() async throws {
        let fixture = try makeRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scriptURL.deletingLastPathComponent()) }

        let loaded = try await SkyStreamRuntimePool().load(
            using: fixture.configuration,
            url: "extractor-callback-contracts"
        )

        XCTAssertEqual(loaded.title, "1|1|1|1|0|0")
    }

    func testEpisodeLimitRemainsExplicitlyBounded() {
        XCTAssertEqual(SkyStreamRuntimeLimits(maximumEpisodes: 0).maximumEpisodes, 1)
        XCTAssertEqual(SkyStreamRuntimeLimits(maximumEpisodes: 99_999).maximumEpisodes, 5_000)
    }

    private func openHTML(_ html: String, using bridge: SkyStreamHTMLBridge) throws -> String {
        let value = try bridgeRequest(["action": "open", "html": html], using: bridge)
        return try XCTUnwrap((value as? [String: Any])?["handle"] as? String)
    }

    private func queryHTML(
        handle: String,
        selector: String,
        using bridge: SkyStreamHTMLBridge
    ) throws -> [[String: Any]] {
        let value = try bridgeRequest([
            "action": "query",
            "handle": handle,
            "selector": selector
        ], using: bridge)
        return value as? [[String: Any]] ?? []
    }

    private func bridgeRequest(
        _ request: [String: Any],
        using bridge: SkyStreamHTMLBridge
    ) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: request)
        let requestJSON = try XCTUnwrap(String(data: data, encoding: .utf8))
        let response = bridge.handle(requestJSON)
        return try JSONSerialization.jsonObject(with: Data(response.utf8))
    }

    private func makeRuntimeFixture() throws -> (
        configuration: SkyStreamRuntimeConfiguration,
        scriptURL: URL
    ) {
        let script = #"""
        var fixtureRequests = [];
        var fixtureNativeHTTP = globalThis.__eclipseSkyNativeHTTP;
        globalThis.__eclipseSkyNativeHTTP = function(requestJSON, resolve, reject) {
            var request = JSON.parse(requestJSON);
            var extractorBodies = {
                "https://dood.test/e/fixture": "<script>var path='/pass_md5/fixture?token=token-value';</script>",
                "https://dood.test/pass_md5/fixture?token=token-value": "https://cdn.example/dood/",
                "https://filemoon.test/e/fixture": "<script>var player={file:'https://filemoon.test/master.m3u8'};</script>",
                "https://filemoon.test/master.m3u8": "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720\n/video-720.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080\nhttps://cdn.example/video-1080.m3u8\n",
                "https://hubcloud.test/drive/fixture": "<a id='download' href='/generated'>Generate Direct Download Link</a>",
                "https://hubcloud.test/generated": "<a class='btn' href='https://cdn.example/hubcloud.mp4'>Download [HubCloud 1080p]</a>",
                "https://mixdrop.test/e/fixture": "<script>MDCore.wurl=\"//cdn.example/mixdrop.mp4\";</script>",
                "https://streamtape.test/e/fixture": "<div id='norobotlink'></div><script>document.getElementById('norobotlink').innerHTML = '//streamtape.test/get_video?id=' + ('Xabc').substring(1);</script>",
                "https://voe.test/e/fixture": "<script>var sources={'hls':'https://cdn.example/voe.m3u8'};</script>"
            };
            if (Object.prototype.hasOwnProperty.call(extractorBodies, request.url)) {
                fixtureRequests.push(request);
                resolve(JSON.stringify({
                    body: extractorBodies[request.url], code: 200, status: 200,
                    statusCode: 200, ok: true, url: request.url,
                    finalUrl: request.url, headers: {}
                }));
                return;
            }
            if (String(request.url || "").indexOf("https://fixture-request.invalid/") === 0) {
                fixtureRequests.push(request);
                resolve(JSON.stringify({
                    body: "", code: 200, status: 200, statusCode: 200, ok: true,
                    url: request.url, finalUrl: request.url, headers: {}
                }));
                return;
            }
            return fixtureNativeHTTP(requestJSON, resolve, reject);
        };
        function search(query) { return []; }
        async function load(url) {
            if (url === "extractor-callback-contracts") {
                var twoArgumentCallbacks = [];
                var twoArgumentResult = await loadExtractor(
                    "https://hubcloud.test/drive/fixture",
                    function(stream) { twoArgumentCallbacks.push(stream); }
                );
                var threeArgumentCallbacks = [];
                var threeArgumentResult = await loadExtractor(
                    "https://mixdrop.test/e/fixture",
                    "https://anime.example/episode",
                    function(stream) { threeArgumentCallbacks.push(stream); }
                );
                var unsupportedCallbacks = [];
                var unsupportedResult = await loadExtractor(
                    "https://unsupported.test/e/fixture",
                    function(stream) { unsupportedCallbacks.push(stream); }
                );
                return {
                    title: [
                        twoArgumentResult.length, twoArgumentCallbacks.length,
                        threeArgumentResult.length, threeArgumentCallbacks.length,
                        unsupportedResult.length, unsupportedCallbacks.length
                    ].join("|"),
                    url: url,
                    episodes: []
                };
            }
            if (url === "dom-aliases") {
                var page = "<html><body><h1>Heading</h1><a class='item' href='/video'>Link</a></body></html>";
                var parsed = await parseHtml(page);
                var dom = new JSDOM(page);
                await dom.waitForInit();
                var raw = await parse_html(page, "a.item", "href");
                return {
                    title: parsed.querySelector("h1").textContent + "|" +
                        dom.window.document.querySelector("a.item").textContent + "|" + raw[0].attr,
                    url: url,
                    episodes: []
                };
            }
            if (url === "dom-relations") {
                var relationPage = "<html><body><div class='wrapper'><a>One</a><a id='middle' class='item chosen'>Two</a><a>Three</a></div></body></html>";
                var relationDocument = await parseHtml(relationPage);
                var middle = relationDocument.querySelector("#middle");
                return {
                    title: [
                        middle.className,
                        middle.parentElement.className,
                        middle.previousElementSibling.textContent,
                        middle.nextElementSibling.textContent,
                        middle.parentElement.children.length
                    ].join("|"),
                    url: url,
                    episodes: []
                };
            }
            if (url === "native-helpers") {
                var helperPage = "<html><body><h1>Heading</h1><a>One</a><a>Two</a></body></html>";
                var helperDocument = await parseHtml(helperPage);
                var batch = nativeDomBatch(helperDocument.nodeId, [
                    { query: "h1", attr: "textContent", first: true },
                    { query: "a", attr: "textContent" }
                ]);
                var extracted = await nativeExtract(helperPage, {
                    heading: { query: "h1", attr: "textContent", first: true }
                });
                var regex = nativeRegex("A1 a2", "a(\\d)", 1, false);
                var json = nativeJsonExtract('{"items":[{"name":"One"},{"name":"Two"}]}', ["items[*].name"]);
                return {
                    title: [
                        batch[0], batch[1].join(","), extracted.heading,
                        regex.join(","), json["items[*].name"].join(","), nativeMd5("hello")
                    ].join("|"),
                    url: url,
                    episodes: []
                };
            }
            if (url === "header-options") {
                fixtureRequests = [];
                await http_get("https://fixture-request.invalid/direct", {
                    Cookie: "cookie/direct", Host: "blocked", Connection: "blocked"
                });
                await http_get("https://fixture-request.invalid/nested", { headers: {
                    Cookie: "cookie/nested", Referer: "nested", "Accept-Encoding": "gzip"
                }});
                var directRequest = fixtureRequests[0];
                var nestedRequest = fixtureRequests[1];
                return {
                    title: [
                        directRequest.headers.Cookie,
                        nestedRequest.headers.Cookie,
                        nestedRequest.headers.Referer,
                        directRequest.headers.Host === undefined &&
                            directRequest.headers.Connection === undefined &&
                            nestedRequest.headers["Accept-Encoding"] === undefined
                    ].join("|"),
                    url: url,
                    episodes: []
                };
            }
            var episodes = [];
            for (var index = 0; index < 512; index++) {
                episodes.push({
                    name: "Episode " + (index + 1),
                    url: "https://fixture.example/episode/" + (index + 1),
                    season: 1,
                    episode: index + 1
                });
            }
            episodes[0].name = "Episode 1 (Dub)";
            episodes[1].name = "Episode 2 [Sub]";
            episodes[2].name = "Episode 3 Dub";
            episodes[2].dubStatus = "subbed";
            episodes[3] = new Episode({
                name: "Episode 4 - Dub",
                url: "https://fixture.example/episode/4",
                season: 1,
                episode: 4
            });
            return { title: "Fixture Show", url: url, episodes: episodes };
        }
        async function loadStreams(url) {
            if (url === "extractor-registry") {
                var targets = [
                    "https://dood.test/e/fixture",
                    "https://filemoon.test/e/fixture",
                    "https://hubcloud.test/drive/fixture",
                    "https://mixdrop.test/e/fixture",
                    "https://streamtape.test/e/fixture",
                    "https://voe.test/e/fixture"
                ];
                var output = [];
                for (var targetIndex = 0; targetIndex < targets.length; targetIndex++) {
                    output = output.concat(await loadExtractor(targets[targetIndex]));
                }
                return output;
            }
            if (url === "controlled-headers") {
                return [{
                    url: "https://video.example.com/fixture.mp4",
                    headers: {
                        "Cookie": "session=allowed",
                        "Referer": "https://allowed.example/page",
                        "Host": "forged.example",
                        "Connection": "keep-alive",
                        "Accept-Encoding": "gzip"
                    }
                }];
            }
            if (url === "large") {
                return [{ url: "magic_m3u8:" + new Array(400001).join("A") }];
            }
            if (url === "oversized") {
                return [{ url: "magic_m3u8:" + new Array(6000001).join("A") }];
            }
            if (url === "packed36") {
                var packed36 = "eval ( function ( p , a , c , k , e , r ) { return p; } " +
                    "( '0://1.2.3/4', 36, 5, 'https|video|example|com|path'.split ( '|' ) ) )";
                return [{ url: getAndUnpack(packed36) }];
            }
            if (url === "packed95") {
                var packed95 = "eval ( function ( p , a , c , k , e , d ) { return p; } " +
                    "( '0://1.2.3/4', 95, 21, '||||||||||||||||https|video|example|com|path'.split ( '|' ) ) )";
                return [{ url: getAndUnpack(packed95) }];
            }
            return [];
        }
        """#
        let data = Data(script.utf8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EclipseSkyStreamRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("plugin.js")
        try data.write(to: scriptURL, options: .atomic)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let manifest = SkyStreamPluginManifest(
            packageName: "fixture.runtime",
            name: "Runtime Fixture",
            version: 1,
            authors: ["Eclipse Tests"],
            baseURL: "https://fixture.example",
            languages: ["en"],
            categories: ["series"]
        )
        return (
            SkyStreamRuntimeConfiguration(
                manifest: manifest,
                scriptURL: scriptURL,
                expectedScriptSHA256: hash
            ),
            scriptURL
        )
    }
}

final class SkyStreamRuntimeWatchdogTests: XCTestCase {
    func testCancellationOfFiniteSpinReturnsPromptlyAndIsolatesLateCompletion() async throws {
        let fixture = try makeRuntimeFixture(
            script: #"""
            var contextMarker = "clean";
            function search(query) {
                if (query === "slow") {
                    contextMarker = "dirty";
                    var finiteDeadline = Date.now() + 900;
                    while (Date.now() < finiteDeadline) { Math.sqrt(144); }
                    return [{ title: "cancelled-result", url: "https://fixture.example/cancelled" }];
                }
                return [{ title: "fresh-" + contextMarker, url: "https://fixture.example/fresh" }];
            }
            function load(url) { return { title: "unused", url: url, episodes: [] }; }
            function loadStreams(url) { return []; }
            """#,
            limits: SkyStreamRuntimeLimits(searchTimeout: 1)
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let pool = SkyStreamRuntimePool()
        let slowTask = Task {
            try await pool.search(using: fixture.configuration, query: "slow")
        }
        // Failed invocations now use transactional storage, so a liveness marker written by this
        // call must not escape. Give the task a scheduling turn, then use the retained source
        // admission permit below to prove that cancellation happened during physical execution.
        try await Task.sleep(nanoseconds: 150_000_000)

        let cancelledAt = Date()
        slowTask.cancel()
        do {
            _ = try await slowTask.value
            XCTFail("A cancelled caller must not receive the abandoned JavaScript result.")
        } catch let error as SkyStreamRuntimeError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(cancelledAt),
            0.75,
            "Caller cancellation must not wait for synchronous JavaScriptCore work to unwind."
        )

        let freshStartedAt = Date()
        let fresh = try await pool.search(using: fixture.configuration, query: "fresh")
        XCTAssertEqual(fresh.map(\.title), ["fresh-clean"])
        XCTAssertGreaterThan(
            Date().timeIntervalSince(freshStartedAt),
            0.35,
            "Fresh work must wait for the cancelled synchronous frame to unwind physically."
        )
    }

    func testDeadlineReplacesContextAndLateCallbackCannotSettleNextInvocation() async throws {
        let fixture = try makeRuntimeFixture(
            script: #"""
            var contextMarker = "clean";
            function search(query, callback) {
                if (query === "late") {
                    contextMarker = "dirty";
                    setTimeout(function () {
                        localStorage.setItem("lateCallbackRan", "yes");
                        callback([{ title: "late", url: "https://fixture.example/late" }]);
                    }, 1300);
                    return;
                }
                setTimeout(function () {
                    callback([{
                        title: "fresh-" + contextMarker,
                        url: "https://fixture.example/fresh"
                    }]);
                }, 500);
            }
            function load(url) { return { title: "unused", url: url, episodes: [] }; }
            function loadStreams(url) { return []; }
            """#,
            limits: SkyStreamRuntimeLimits(searchTimeout: 1)
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let pool = SkyStreamRuntimePool()
        let startedAt = Date()
        do {
            _ = try await pool.search(using: fixture.configuration, query: "late")
            XCTFail("Expected the callback scheduled beyond the operation deadline to time out.")
        } catch let error as SkyStreamRuntimeError {
            XCTAssertEqual(error, .operationTimedOut(.search))
        }
        let timeoutDuration = Date().timeIntervalSince(startedAt)
        XCTAssertGreaterThan(timeoutDuration, 0.75)
        XCTAssertLessThan(timeoutDuration, 2.5)

        // The stale callback was due while this second invocation was active. It must neither
        // settle the new invocation nor carry mutable globals from the timed-out context into it.
        let fresh = try await pool.search(using: fixture.configuration, query: "fresh")
        XCTAssertEqual(fresh.map(\.title), ["fresh-clean"])
        XCTAssertNil(fixture.configuration.dataStore.snapshot().storage["lateCallbackRan"])
    }

    func testQueuedInvocationDoesNotSpendHardDeadlineBeforeActivation() async throws {
        let fixture = try makeRuntimeFixture(
            script: #"""
            function search(query) {
                return [{ title: "search-" + query, url: "https://fixture.example/" + query }];
            }
            function load(url) { return { title: "unused", url: url, episodes: [] }; }
            function loadStreams(url) {
                if (url === "slow-valid") {
                    var finiteDeadline = Date.now() + 3900;
                    while (Date.now() < finiteDeadline) { Math.sqrt(144); }
                }
                return [{ url: "https://fixture.example/video.mp4" }];
            }
            """#,
            limits: SkyStreamRuntimeLimits(searchTimeout: 1, streamTimeout: 5)
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let pool = SkyStreamRuntimePool()
        let queueLeader = Task {
            try await pool.loadStreams(using: fixture.configuration, url: "slow-valid")
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        // search's one-second operation timeout (and current three-second outer deadline) is
        // intentionally shorter than the remaining valid queue-leader work. Queue residence is
        // not execution and must not poison this otherwise healthy provider.
        let queuedSearch = Task {
            let startedAt = Date()
            let records = try await pool.search(using: fixture.configuration, query: "queued")
            return (records, Date().timeIntervalSince(startedAt))
        }
        let streams = try await queueLeader.value
        let (search, queuedDuration) = try await queuedSearch.value
        XCTAssertEqual(streams.map(\.url), ["https://fixture.example/video.mp4"])
        XCTAssertEqual(search.map(\.title), ["search-queued"])
        XCTAssertGreaterThan(
            queuedDuration,
            3,
            "The regression fixture must actually wait beyond search's hard execution budget."
        )

        let later = try await pool.search(using: fixture.configuration, query: "later")
        XCTAssertEqual(later.map(\.title), ["search-later"])
    }

    func testHardWatchdogQuarantinesFiniteUnresponsiveRuntime() async throws {
        let fixture = try makeRuntimeFixture(
            script: #"""
            function search(query) {
                if (query === "hard") {
                    var finiteDeadline = Date.now() + 3600;
                    while (Date.now() < finiteDeadline) { Math.sqrt(144); }
                    return [{ title: "too-late", url: "https://fixture.example/too-late" }];
                }
                return [{ title: "fresh", url: "https://fixture.example/fresh" }];
            }
            function load(url) { return { title: "unused", url: url, episodes: [] }; }
            function loadStreams(url) { return []; }
            """#,
            limits: SkyStreamRuntimeLimits(searchTimeout: 1)
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let pool = SkyStreamRuntimePool()
        let startedAt = Date()
        do {
            _ = try await pool.search(using: fixture.configuration, query: "hard")
            XCTFail("The hard watchdog must detach from finite but unresponsive JavaScript.")
        } catch let error as SkyStreamRuntimeError {
            XCTAssertEqual(error, .operationTimedOut(.search))
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            5,
            "The hard watchdog must return before a stuck JavaScriptCore queue can hang the runner."
        )

        do {
            _ = try await pool.search(using: fixture.configuration, query: "fresh")
            XCTFail("A runtime classified unresponsive must not be reused.")
        } catch let error as SkyStreamRuntimeError {
            XCTAssertEqual(error, .runtimeQuarantined)
        }

        // The wall-clock spin is finite. Allow its sub-second remainder to unwind after the
        // three-second hard deadline before deleting the fixture backing this runtime.
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    func testEarlySuccessCannotHideSynchronousWorkFromHardWatchdog() async throws {
        let fixture = try makeRuntimeFixture(
            script: #"""
            function search(query) { return []; }
            function load(url) { return { title: "unused", url: url, episodes: [] }; }
            function loadStreams(url, callback) {
                if (url === "early-success") {
                    callback([{ url: "https://fixture.example/callback.mp4" }]);
                    var finiteDeadline = Date.now() + 3600;
                    while (Date.now() < finiteDeadline) { Math.sqrt(144); }
                    return [{ url: "https://fixture.example/direct-return.mp4" }];
                }
                return [{ url: "https://fixture.example/fresh.mp4" }];
            }
            """#,
            limits: SkyStreamRuntimeLimits(streamTimeout: 1)
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let pool = SkyStreamRuntimePool()
        do {
            _ = try await pool.loadStreams(
                using: fixture.configuration,
                url: "early-success"
            )
            XCTFail("An early callback must not end physical liveness while JavaScript is still running.")
        } catch let error as SkyStreamRuntimeError {
            XCTAssertEqual(error, .operationTimedOut(.loadStreams))
        }

        do {
            _ = try await pool.loadStreams(using: fixture.configuration, url: "fresh")
            XCTFail("The early-settled but physically unresponsive runtime must be quarantined.")
        } catch let error as SkyStreamRuntimeError {
            XCTAssertEqual(error, .runtimeQuarantined)
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    func testSameSourceQueueCannotStarveHealthySourceAndIsCancelledAfterQuarantine() async throws {
        let blockedFixture = try makeRuntimeFixture(
            script: #"""
            function search(query) {
                if (query === "hung") {
                    var finiteDeadline = Date.now() + 3600;
                    while (Date.now() < finiteDeadline) { Math.sqrt(144); }
                }
                return [{ title: query, url: "https://blocked.example/" + query }];
            }
            function load(url) { return { title: "unused", url: url, episodes: [] }; }
            function loadStreams(url) { return []; }
            """#,
            limits: SkyStreamRuntimeLimits(searchTimeout: 1),
            packageName: "fixture.watchdog.blocked"
        )
        defer { try? FileManager.default.removeItem(at: blockedFixture.directoryURL) }
        let healthyFixture = try makeRuntimeFixture(
            script: #"""
            function search(query) {
                return [{ title: "healthy-" + query, url: "https://healthy.example/" + query }];
            }
            function load(url) { return { title: "unused", url: url, episodes: [] }; }
            function loadStreams(url) { return []; }
            """#,
            limits: SkyStreamRuntimeLimits(searchTimeout: 1),
            packageName: "fixture.watchdog.healthy"
        )
        defer { try? FileManager.default.removeItem(at: healthyFixture.directoryURL) }

        let pool = SkyStreamRuntimePool()
        let hung = Task {
            try await pool.search(using: blockedFixture.configuration, query: "hung")
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        let queuedOne = Task {
            try await pool.search(using: blockedFixture.configuration, query: "queued-one")
        }
        let queuedTwo = Task {
            try await pool.search(using: blockedFixture.configuration, query: "queued-two")
        }
        // Give both unstructured callers a scheduling turn so this exercises permit accounting,
        // rather than accidentally racing the healthy probe ahead of the queued requests.
        try await Task.sleep(nanoseconds: 150_000_000)

        // Three same-source callers must not reserve all three global ABI slots while only one
        // can execute. An unrelated provider should retain Services-like responsiveness.
        let healthyStartedAt = Date()
        let healthy = try await pool.search(
            using: healthyFixture.configuration,
            query: "probe"
        )
        XCTAssertEqual(healthy.map(\.title), ["healthy-probe"])
        XCTAssertLessThan(
            Date().timeIntervalSince(healthyStartedAt),
            1.5,
            "Queued work for one provider must not starve another healthy source."
        )

        do {
            _ = try await hung.value
            XCTFail("The active finite hang must be classified by the hard watchdog.")
        } catch let error as SkyStreamRuntimeError {
            XCTAssertEqual(error, .operationTimedOut(.search))
        }
        await assertCancelledAfterQuarantine(queuedOne, label: "first queued invocation")
        await assertCancelledAfterQuarantine(queuedTwo, label: "second queued invocation")

        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    func testFailedAndCancelledInvocationsRollbackTransactionalStorage() async throws {
        let initialSnapshot = SkyStreamRuntimeStorageSnapshot(
            storage: ["transaction-storage": "before"],
            preferences: ["transaction-preference": .string("before")]
        )
        let fixture = try makeRuntimeFixture(
            script: #"""
            function search(query, callback) {
                if (query === "throw") {
                    localStorage.setItem("transaction-storage", "failed-throw");
                    setPreference("transaction-preference", "failed-throw");
                    throw new Error("transaction fixture rejection");
                }
                if (query === "cancel") {
                    localStorage.setItem("transaction-storage", "failed-cancel");
                    setPreference("transaction-preference", "failed-cancel");
                    var finiteDeadline = Date.now() + 650;
                    while (Date.now() < finiteDeadline) { Math.sqrt(144); }
                    return [{
                        title: "cancelled-result",
                        url: "https://fixture.example/cancelled-result"
                    }];
                }
                return [{
                    title: localStorage.getItem("transaction-storage") + "|" +
                        getPreference("transaction-preference"),
                    url: "https://fixture.example/healthy"
                }];
            }
            function load(url) { return { title: "unused", url: url, episodes: [] }; }
            function loadStreams(url) { return []; }
            """#,
            limits: SkyStreamRuntimeLimits(searchTimeout: 2),
            packageName: "fixture.watchdog.transaction",
            initialSnapshot: initialSnapshot
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let pool = SkyStreamRuntimePool()
        do {
            _ = try await pool.search(using: fixture.configuration, query: "throw")
            XCTFail("A rejected ABI call must not commit its working storage.")
        } catch let error as SkyStreamRuntimeError {
            guard case .pluginRejected = error else {
                XCTFail("Unexpected rejection error: \(error)")
                return
            }
        }
        await assertTransactionSnapshot(
            in: pool,
            packageName: fixture.configuration.manifest.packageName,
            expected: "before",
            phase: "rejection"
        )

        let afterFailure = try await pool.search(using: fixture.configuration, query: "healthy")
        XCTAssertEqual(afterFailure.map(\.title), ["before|before"])

        let cancelled = Task {
            try await pool.search(using: fixture.configuration, query: "cancel")
        }
        // The operation synchronously stages both writes before entering its finite frame.
        try await Task.sleep(nanoseconds: 150_000_000)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled ABI call must not publish its staged storage.")
        } catch let error as SkyStreamRuntimeError {
            XCTAssertEqual(error, .cancelled)
        }
        await assertTransactionSnapshot(
            in: pool,
            packageName: fixture.configuration.manifest.packageName,
            expected: "before",
            phase: "cancellation"
        )

        let afterCancellationStartedAt = Date()
        let afterCancellation = try await pool.search(
            using: fixture.configuration,
            query: "healthy"
        )
        XCTAssertEqual(afterCancellation.map(\.title), ["before|before"])
        XCTAssertGreaterThan(
            Date().timeIntervalSince(afterCancellationStartedAt),
            0.2,
            "The healthy probe must wait for the cancelled transaction's physical frame."
        )
    }

    func testScalarPreferencesRoundTripThroughSuccessfulTransaction() async throws {
        let initialSnapshot = SkyStreamRuntimeStorageSnapshot(preferences: [
            "scalar-string": .string("before"),
            "scalar-bool": .boolean(true),
            "scalar-number": .number(2.5)
        ])
        let fixture = try makeRuntimeFixture(
            script: #"""
            function preferenceRecord(key) {
                var value = getPreference(key);
                return {
                    title: typeof value + ":" + String(value),
                    url: "https://fixture.example/" + key
                };
            }
            function search(query) {
                if (query === "write") {
                    if (!setPreference("scalar-string", "after") ||
                        !setPreference("scalar-bool", false) ||
                        !setPreference("scalar-number", 7.25)) {
                        throw new Error("scalar preference write failed");
                    }
                }
                return [
                    preferenceRecord("scalar-string"),
                    preferenceRecord("scalar-bool"),
                    preferenceRecord("scalar-number")
                ];
            }
            function load(url) { return { title: "unused", url: url, episodes: [] }; }
            function loadStreams(url) { return []; }
            """#,
            limits: SkyStreamRuntimeLimits(searchTimeout: 1),
            packageName: "fixture.watchdog.scalar-preferences",
            initialSnapshot: initialSnapshot
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let pool = SkyStreamRuntimePool()
        let before = try await pool.search(using: fixture.configuration, query: "read")
        XCTAssertEqual(
            before.map(\.title),
            ["string:before", "boolean:true", "number:2.5"]
        )

        let write = try await pool.search(using: fixture.configuration, query: "write")
        XCTAssertEqual(
            write.map(\.title),
            ["string:after", "boolean:false", "number:7.25"]
        )
        let committed = await pool.storageSnapshot(
            packageName: fixture.configuration.manifest.packageName
        )
        XCTAssertEqual(committed?.preferences["scalar-string"], .string("after"))
        XCTAssertEqual(committed?.preferences["scalar-bool"], .boolean(false))
        XCTAssertEqual(committed?.preferences["scalar-number"], .number(7.25))

        let fresh = try await pool.search(using: fixture.configuration, query: "read")
        XCTAssertEqual(
            fresh.map(\.title),
            ["string:after", "boolean:false", "number:7.25"]
        )
    }

    func testPreferenceJSONShapeGateRejectsHostileValuesWithoutPartialMutation() async throws {
        let initialSnapshot = SkyStreamRuntimeStorageSnapshot(preferences: [
            "protected": .string("before")
        ])
        let fixture = try makeRuntimeFixture(
            script: #"""
            function search(query) {
                if (query === "hostile") {
                    var deep = "leaf";
                    for (var depth = 0; depth < 16; depth += 1) deep = [deep];
                    var wide = [];
                    for (var index = 0; index < 1025; index += 1) wide.push(index);
                    var rejected = [
                        setPreference("protected", deep),
                        setPreference("protected", wide),
                        setPreference("protected", "x".repeat(65537)),
                        setPreference("protected", { "": "invalid-key" })
                    ];
                    return [{
                        title: rejected.join("|") + "|" + getPreference("protected"),
                        url: "https://fixture.example/preferences/hostile"
                    }];
                }
                var accepted = setPreference("accepted", { nested: [true, 3, "ok"] });
                return [{
                    title: accepted + "|" + JSON.stringify(getPreference("accepted")),
                    url: "https://fixture.example/preferences/benign"
                }];
            }
            function load(url) { return { title: "unused", url: url, episodes: [] }; }
            function loadStreams(url) { return []; }
            """#,
            limits: SkyStreamRuntimeLimits(searchTimeout: 1),
            packageName: "fixture.watchdog.preference-shape",
            initialSnapshot: initialSnapshot
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let pool = SkyStreamRuntimePool()
        let records = try await pool.search(using: fixture.configuration, query: "hostile")
        XCTAssertEqual(
            records.map(\.title),
            ["false|false|false|false|before"]
        )

        let afterRejection = await pool.storageSnapshot(
            packageName: fixture.configuration.manifest.packageName
        )
        XCTAssertEqual(afterRejection?.preferences["protected"], .string("before"))
        XCTAssertNil(afterRejection?.preferences["accepted"])

        let followUp = try await pool.search(using: fixture.configuration, query: "benign")
        XCTAssertEqual(
            followUp.map(\.title),
            [#"true|{"nested":[true,3,"ok"]}"#]
        )
        let committed = await pool.storageSnapshot(
            packageName: fixture.configuration.manifest.packageName
        )
        XCTAssertEqual(committed?.preferences["protected"], .string("before"))
        XCTAssertEqual(
            committed?.preferences["accepted"],
            .object(["nested": .array([.boolean(true), .integer(3), .string("ok")])])
        )
    }

    private func makeRuntimeFixture(
        script: String,
        limits: SkyStreamRuntimeLimits,
        packageName: String = "fixture.watchdog",
        initialSnapshot: SkyStreamRuntimeStorageSnapshot = .init()
    ) throws -> (
        configuration: SkyStreamRuntimeConfiguration,
        directoryURL: URL
    ) {
        let data = Data(script.utf8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EclipseSkyStreamWatchdogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("plugin.js")
        try data.write(to: scriptURL, options: .atomic)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let manifest = SkyStreamPluginManifest(
            packageName: packageName,
            name: "Watchdog Fixture",
            version: 1,
            authors: ["Eclipse Tests"],
            baseURL: "https://fixture.example",
            languages: ["en"],
            categories: ["series"]
        )
        return (
            SkyStreamRuntimeConfiguration(
                manifest: manifest,
                scriptURL: scriptURL,
                expectedScriptSHA256: hash,
                dataStore: SkyStreamRuntimeDataStore(snapshot: initialSnapshot),
                limits: limits
            ),
            directory
        )
    }

    private func assertCancelledAfterQuarantine(
        _ task: Task<[SkyStreamSearchRecord], Error>,
        label: String
    ) async {
        do {
            _ = try await task.value
            XCTFail("\(label) executed after its runtime was quarantined.")
        } catch let error as SkyStreamRuntimeError {
            XCTAssertTrue(
                error == .runtimeQuarantined || error == .cancelled,
                "\(label) ended with unexpected error: \(error)"
            )
        } catch {
            XCTFail("\(label) ended with unexpected error: \(error)")
        }
    }

    private func assertTransactionSnapshot(
        in pool: SkyStreamRuntimePool,
        packageName: String,
        expected: String,
        phase: String
    ) async {
        let snapshot = await pool.storageSnapshot(packageName: packageName)
        XCTAssertEqual(
            snapshot?.storage["transaction-storage"],
            expected,
            "Storage mutation escaped the \(phase) transaction."
        )
        XCTAssertEqual(
            snapshot?.preferences["transaction-preference"],
            .string(expected),
            "Preference mutation escaped the \(phase) transaction."
        )
    }

}

final class SkyStreamURLAndHeaderSecurityTests: XCTestCase {
    private let policy = SkyStreamRemoteURLPolicy()

    func testSyntacticPolicyAcceptsRemoteHTTPMediaAndStripsFragments() throws {
        let validated = try policy.validateSyntactic(
            "https://media.example.com:8443/video.mp4?token=secret#fragment-secret",
            purpose: .streamRoot
        )

        XCTAssertEqual(validated.origin.scheme, "https")
        XCTAssertEqual(validated.origin.host, "media.example.com")
        XCTAssertEqual(validated.origin.port, 8_443)
        XCTAssertNil(validated.url.fragment)
        XCTAssertEqual(
            SkyStreamRemoteURLPolicy.redactedDescription(of: validated.url),
            "https://media.example.com:8443"
        )
    }

    func testRedactedDescriptionNeverIncludesCredentialsPathQueryOrFragment() {
        let raw = "https://user:password@media.example.com/private/file.m3u8?token=query-secret#fragment-secret"
        let redacted = SkyStreamRemoteURLPolicy.redactedDescription(of: raw)
        XCTAssertEqual(redacted, "https://media.example.com")
        for marker in ["user", "password", "private", "token", "query-secret", "fragment-secret"] {
            XCTAssertFalse(redacted.contains(marker), marker)
        }
    }

    func testPolicyRejectsCustomSchemesCredentialsAndInsecurePackageTransport() {
        assertSyntacticError(.unsupportedScheme, "file:///private/video.mp4", purpose: .streamRoot)
        assertSyntacticError(.unsupportedScheme, "luna://play/video", purpose: .streamRoot)
        assertSyntacticError(.unsupportedScheme, "javascript:alert(1)", purpose: .streamRoot)
        assertSyntacticError(.unsupportedScheme, "magnet:?xt=urn:btih:abc", purpose: .streamRoot)
        assertSyntacticError(
            .credentialsInURL,
            "https://user:password@media.example.com/video.mp4",
            purpose: .streamRoot
        )
        assertSyntacticError(.insecureTransport, "http://repo.example.com/index.json", purpose: .repository)
        assertSyntacticError(.insecureTransport, "http://repo.example.com/plugin.zip", purpose: .package)
    }

    func testPolicyRejectsLocalPrivateAndAmbiguousAddressFormsWithoutNetworkIO() {
        let prohibited = [
            "http://localhost/video.mp4",
            "http://player.local/video.mp4",
            "http://127.0.0.1/video.mp4",
            "http://127.1/video.mp4",
            "http://2130706433/video.mp4",
            "http://0x7f000001/video.mp4",
            "http://10.0.0.1/video.mp4",
            "http://172.16.1.1/video.mp4",
            "http://192.168.1.1/video.mp4",
            "http://169.254.169.254/latest/meta-data",
            "http://[::1]/video.mp4",
            "http://[::ffff:127.0.0.1]/video.mp4"
        ]

        for rawURL in prohibited {
            XCTAssertThrowsError(
                try policy.validateSyntactic(rawURL, purpose: .streamRoot),
                "Unexpected accepted URL: \(rawURL)"
            ) { error in
                guard let securityError = error as? SkyStreamSecurityError else {
                    return XCTFail("Unexpected error type: \(type(of: error))")
                }
                switch securityError {
                case .prohibitedHost, .prohibitedAddress:
                    break
                default:
                    XCTFail("Unexpected error \(securityError) for \(rawURL)")
                }
            }
        }
    }

    func testHeaderSanitizerNormalizesAndRejectsManagedOrInjectedHeaders() throws {
        let sanitized = try SkyStreamHeaderSanitizer.sanitize(
            [
                "Authorization": "Bearer fixture-token",
                "Cookie": "session=fixture",
                "User-Agent": "FixtureAgent/1.0",
                "Referer": "https://video.example.com/watch/42"
            ],
            purpose: .stream
        )
        XCTAssertEqual(sanitized.values["authorization"], "Bearer fixture-token")
        XCTAssertEqual(sanitized.values["cookie"], "session=fixture")
        XCTAssertEqual(sanitized.values["user-agent"], "FixtureAgent/1.0")

        XCTAssertThrowsError(
            try SkyStreamHeaderSanitizer.sanitize(["Host": "attacker.example"], purpose: .stream)
        ) { XCTAssertEqual($0 as? SkyStreamSecurityError, .forbiddenHeader) }
        XCTAssertThrowsError(
            try SkyStreamHeaderSanitizer.sanitize(["Range": "bytes=0-10"], purpose: .stream)
        ) { XCTAssertEqual($0 as? SkyStreamSecurityError, .forbiddenHeader) }
        XCTAssertThrowsError(
            try SkyStreamHeaderSanitizer.sanitize(["X-Test": "value\r\nInjected: yes"], purpose: .stream)
        ) { XCTAssertEqual($0 as? SkyStreamSecurityError, .invalidHeaderValue) }
    }

    func testCrossOriginRedirectPermanentlyShedsCredentials() throws {
        let source = try policy.validateSyntactic(
            "https://video.example.com/start",
            purpose: .streamRoot
        ).origin
        let sameOrigin = try policy.validateSyntactic(
            "https://video.example.com/next",
            purpose: .streamRoot
        ).origin
        let otherOrigin = try policy.validateSyntactic(
            "https://cdn.example.com/next",
            purpose: .streamRoot
        ).origin
        let original = try SkyStreamHeaderSanitizer.sanitize(
            [
                "Authorization": "Bearer fixture-token",
                "Cookie": "session=fixture",
                "X-API-Key": "fixture-key",
                "Referer": "https://video.example.com/watch/42",
                "Origin": "https://video.example.com",
                "Accept": "video/*",
                "User-Agent": "FixtureAgent/1.0"
            ],
            purpose: .stream
        )

        XCTAssertEqual(original.scopedForRedirect(from: source, to: sameOrigin), original)

        let shed = original.scopedForRedirect(from: source, to: otherOrigin)
        XCTAssertEqual(shed.values, ["accept": "video/*", "user-agent": "FixtureAgent/1.0"])
        for name in ["authorization", "cookie", "x-api-key", "referer", "origin"] {
            XCTAssertNil(shed.values[name], name)
        }

        let bouncedBack = shed.scopedForRedirect(from: otherOrigin, to: source)
        XCTAssertEqual(bouncedBack, shed)
    }

    func testConcurrentColdValidationsCoalesceOneHostLookup() async throws {
        let count = SkyStreamLockedCounter()
        let policy = SkyStreamRemoteURLPolicy { _ in
            count.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return ["93.184.216.34"]
        }

        let values = try await withThrowingTaskGroup(
            of: SkyStreamValidatedRemoteURL.self,
            returning: [SkyStreamValidatedRemoteURL].self
        ) { group in
            for index in 0..<32 {
                group.addTask {
                    try await policy.validate(
                        "https://coalesce.example.com/segment-\(index).ts",
                        purpose: .mediaSegment
                    )
                }
            }
            var result: [SkyStreamValidatedRemoteURL] = []
            for try await value in group { result.append(value) }
            return result
        }

        XCTAssertEqual(values.count, 32)
        XCTAssertEqual(count.value, 1)
    }

    func testNetworkDispatchBypassesPositiveDNSCacheAndRejectsRebinding() async throws {
        let count = SkyStreamLockedCounter()
        let policy = SkyStreamRemoteURLPolicy { _ in
            count.increment() == 1
                ? ["93.184.216.34"]
                : ["127.0.0.1"]
        }
        let rawURL = "https://dns-rebinding.example.test/video.mp4"

        let cachedPreflight = try await policy.validate(rawURL, purpose: .streamRoot)
        let repeatedPreflight = try await policy.validate(rawURL, purpose: .streamRoot)
        XCTAssertEqual(cachedPreflight.checkedAddresses, ["93.184.216.34"])
        XCTAssertEqual(repeatedPreflight.checkedAddresses, cachedPreflight.checkedAddresses)
        XCTAssertEqual(count.value, 1, "Ordinary parsing validation should use its positive cache.")

        let client = SkyStreamHTTPClient(policy: policy)
        do {
            _ = try await client.fetch(
                SkyStreamHTTPRequest(url: cachedPreflight),
                packageID: "dns-rebinding-fixture",
                limits: .manifest
            )
            XCTFail("Dispatch must not trust the cached public answer after DNS rebinding.")
        } catch let error as SkyStreamSecurityError {
            guard case .prohibitedAddress = error else {
                return XCTFail("Unexpected dispatch rejection: \(error)")
            }
        }
        XCTAssertEqual(
            count.value,
            2,
            "The network dispatch boundary must perform exactly one fresh lookup."
        )
    }

    func testDNSCacheHasHardBoundAndEvictsLeastRecentlyUsedHost() async throws {
        let count = SkyStreamLockedCounter()
        let policy = SkyStreamRemoteURLPolicy { _ in
            count.increment()
            return ["93.184.216.34"]
        }

        for index in 0..<300 {
            _ = try await policy.validate(
                "https://host-\(index).example.com/segment.ts",
                purpose: .mediaSegment
            )
        }
        XCTAssertEqual(count.value, 300)

        _ = try await policy.validate(
            "https://host-0.example.com/another.ts",
            purpose: .mediaSegment
        )
        XCTAssertEqual(count.value, 301, "The oldest entry must have been evicted at the 256-host cap")
    }

    func testBatchValidationChecksEveryURLBeforeDNSAndPreservesOrigins() async throws {
        let count = SkyStreamLockedCounter()
        let policy = SkyStreamRemoteURLPolicy { _ in
            count.increment()
            return ["93.184.216.34"]
        }

        do {
            _ = try await policy.validate([
                SkyStreamRemoteURLValidationRequest(
                    rawValue: "https://media.example.com/segment.ts",
                    purpose: .mediaSegment
                ),
                SkyStreamRemoteURLValidationRequest(
                    rawValue: "http://127.0.0.1/private.ts",
                    purpose: .mediaSegment
                )
            ])
            XCTFail("Expected the private literal in the batch to be rejected")
        } catch let error as SkyStreamSecurityError {
            guard case .prohibitedAddress = error else {
                return XCTFail("Unexpected security error: \(error)")
            }
        }
        XCTAssertEqual(count.value, 0, "DNS must not start until every route passes syntax/literal checks")

        let accepted = try await policy.validate([
            SkyStreamRemoteURLValidationRequest(
                rawValue: "https://media.example.com/one.ts",
                purpose: .mediaSegment
            ),
            SkyStreamRemoteURLValidationRequest(
                rawValue: "https://cdn.example.com/two.ts",
                purpose: .mediaSegment
            )
        ])
        XCTAssertEqual(accepted.map(\.origin.host), ["media.example.com", "cdn.example.com"])
        XCTAssertEqual(count.value, 2)
    }

    private func assertSyntacticError(
        _ expected: SkyStreamSecurityError,
        _ rawURL: String,
        purpose: SkyStreamNetworkPurpose,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try policy.validateSyntactic(rawURL, purpose: purpose),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? SkyStreamSecurityError, expected, file: file, line: line)
        }
    }
}

final class SkyStreamHLSValidationScalingTests: XCTestCase {
    func testFinite4096RoutePlaylistResolvesOneSharedHostOnce() async throws {
        let count = SkyStreamLockedCounter()
        let policy = SkyStreamRemoteURLPolicy { _ in
            count.increment()
            return ["93.184.216.34"]
        }
        var lines = ["#EXTM3U", "#EXT-X-PLAYLIST-TYPE:VOD"]
        lines.reserveCapacity(8_195)
        for index in 0..<4_096 {
            lines.append("#EXTINF:1.0,")
            lines.append("https://segments.example.com/video/\(index).ts")
        }
        lines.append("#EXT-X-ENDLIST")
        let manifest = lines.joined(separator: "\n")
        let candidate = SkyStreamRawStreamCandidate(
            url: "magic_m3u8:\(Data(manifest.utf8).base64EncodedString())"
        )
        let identity = SkyStreamVODValidationIdentity(
            packageID: "fixture.scaling",
            providerID: "primary",
            payloadSHA256: String(repeating: "d", count: 64),
            generation: 1
        )

        let descriptor = try await SkyStreamVODValidator(
            policy: policy,
            client: SkyStreamHTTPClient(policy: policy)
        ).validate(candidate, identity: identity, bypassCache: true)

        XCTAssertEqual(descriptor.mediaKind, .hls)
        XCTAssertEqual(descriptor.routes.count, 4_096)
        XCTAssertEqual(count.value, 1)
    }

    func testGeneratedHLSDropsTransportControlledPluginHeaders() async throws {
        let policy = SkyStreamRemoteURLPolicy { _ in ["93.184.216.34"] }
        let manifest = [
            "#EXTM3U",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXTINF:1.0,",
            "https://segments.example.com/video/one.ts",
            "#EXT-X-ENDLIST"
        ].joined(separator: "\n")
        let candidate = SkyStreamRawStreamCandidate(
            url: "magic_m3u8:\(Data(manifest.utf8).base64EncodedString())",
            headers: [
                "Accept-Encoding": "gzip",
                "Connection": "keep-alive",
                "Host": "segments.example.com",
                "X-Playback-Token": "fixture",
                "Referer": "https://watch.example.com/title"
            ]
        )
        let identity = SkyStreamVODValidationIdentity(
            packageID: "fixture.controlled-headers",
            providerID: "primary",
            payloadSHA256: String(repeating: "e", count: 64),
            generation: 1
        )

        let descriptor = try await SkyStreamVODValidator(
            policy: policy,
            client: SkyStreamHTTPClient(policy: policy)
        ).validate(candidate, identity: identity, bypassCache: true)

        let mediaRoute = try XCTUnwrap(
            descriptor.routes.first(where: { $0.role == .mediaSegment })
        )
        XCTAssertEqual(mediaRoute.headers.values["x-playback-token"], "fixture")
        XCTAssertEqual(
            mediaRoute.headers.values["referer"],
            "https://watch.example.com/title"
        )
        XCTAssertNil(mediaRoute.headers.values["accept-encoding"])
        XCTAssertNil(mediaRoute.headers.values["connection"])
        XCTAssertNil(mediaRoute.headers.values["host"])
    }
}

final class SkyStreamMagicProxyDecoderTests: XCTestCase {
    func testV1DecodesRemoteURLAndUsesFallbackHeaders() throws {
        let remoteURL = "https://media.example.com/video.mp4?signature=fixture"
        let encoded = Data(remoteURL.utf8).base64EncodedString()
        let decoded = try SkyStreamMagicProxyDecoder.decode(
            "MAGIC_PROXY_v1\(encoded)",
            fallbackHeaders: ["User-Agent": "FixtureAgent/1.0"]
        )

        guard case .remote(let url, let headers, let options) = decoded else {
            return XCTFail("Expected a remote MAGIC_PROXY payload")
        }
        XCTAssertEqual(url, remoteURL)
        XCTAssertEqual(headers, ["User-Agent": "FixtureAgent/1.0"])
        XCTAssertEqual(options?.version, .v1)
        XCTAssertEqual(options?.mirrorHosts, [])
        XCTAssertEqual(options?.retainedCookieNames, [])
        XCTAssertNil(options?.referer)
    }

    func testV2DecodesBoundedHeadersAndOptionsFromFixture() throws {
        let fixture = try SkyStreamTestFixture.data(named: "SkyStreamMagicProxyV2")
        let decoded = try SkyStreamMagicProxyDecoder.decode(
            "MAGIC_PROXY_v2\(fixture.base64EncodedString())",
            fallbackHeaders: ["Ignored": "fallback"]
        )

        guard case .remote(let url, let headers, let options) = decoded else {
            return XCTFail("Expected a remote MAGIC_PROXY payload")
        }
        XCTAssertEqual(url, "https://video.example.com/master.m3u8?signature=fixture-secret")
        XCTAssertEqual(headers["Authorization"], "Bearer fixture-token")
        XCTAssertNil(headers["Ignored"])
        XCTAssertEqual(options?.version, .v2)
        XCTAssertEqual(options?.mirrorHosts, ["cdn.example.com", "edge.example.com"])
        XCTAssertEqual(options?.retainedCookieNames, ["session", "hd"])
        XCTAssertEqual(options?.referer, "https://video.example.com/watch/42")
    }

    func testGeneratedHLSDecodesLocallyWithoutOpeningNetwork() throws {
        let manifest = "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-ENDLIST\n"
        let decoded = try SkyStreamMagicProxyDecoder.decode(
            "magic_m3u8:\(Data(manifest.utf8).base64EncodedString())",
            fallbackHeaders: ["Authorization": "fixture"]
        )

        guard case .generatedHLS(let bytes, let headers, let options) = decoded else {
            return XCTFail("Expected generated HLS")
        }
        XCTAssertEqual(bytes, Data(manifest.utf8))
        XCTAssertEqual(headers, ["Authorization": "fixture"])
        XCTAssertEqual(options.version, .generatedM3U8)
    }

    func testDecoderRejectsOversizedDeepAndOverpopulatedDescriptors() throws {
        XCTAssertThrowsError(
            try SkyStreamMagicProxyDecoder.decode(
                "MAGIC_PROXY_v2" + String(repeating: "A", count: 512_001)
            )
        ) { XCTAssertEqual($0 as? SkyStreamVODValidationError, .oversizedMagicDescriptor) }

        let tooLargeV1URL = String(repeating: "a", count: 32_769)
        XCTAssertThrowsError(
            try SkyStreamMagicProxyDecoder.decode(
                "MAGIC_PROXY_v1\(Data(tooLargeV1URL.utf8).base64EncodedString())"
            )
        ) { XCTAssertEqual($0 as? SkyStreamVODValidationError, .malformedMagicDescriptor) }

        let deeplyNested = "{\"url\":\"https://video.example.com/v.mp4\",\"x\":"
            + String(repeating: "[", count: 17)
            + "0"
            + String(repeating: "]", count: 17)
            + "}"
        XCTAssertThrowsError(
            try SkyStreamMagicProxyDecoder.decode(
                "MAGIC_PROXY_v2\(Data(deeplyNested.utf8).base64EncodedString())"
            )
        ) { XCTAssertEqual($0 as? SkyStreamVODValidationError, .invalidMagicDescriptor) }

        let mirrors = (0..<17).map { "cdn\($0).example.com" }
        let overpopulated: [String: Any] = [
            "url": "https://video.example.com/v.mp4",
            "options": ["mirrorHosts": mirrors]
        ]
        let data = try JSONSerialization.data(withJSONObject: overpopulated, options: [.sortedKeys])
        XCTAssertThrowsError(
            try SkyStreamMagicProxyDecoder.decode("MAGIC_PROXY_v2\(data.base64EncodedString())")
        ) { XCTAssertEqual($0 as? SkyStreamVODValidationError, .invalidMagicDescriptor) }
    }
}

final class SkyStreamEarlyVODRejectionTests: XCTestCase {
    private let identity = SkyStreamVODValidationIdentity(
        packageID: "fixture.plugin",
        providerID: "primary",
        payloadSHA256: String(repeating: "a", count: 64),
        generation: 1
    )

    func testRejectsLiveCandidatesBeforeNetworkIO() async {
        await assertRejected(
            SkyStreamRawStreamCandidate(url: "https://video.example.com/live.m3u8", isLive: true),
            as: .liveContent
        )
        await assertRejected(
            SkyStreamRawStreamCandidate(
                url: "https://video.example.com/channel.m3u8",
                policyHints: ["isLive": "true"]
            ),
            as: .liveContent
        )
    }

    func testRejectsTorrentAndInfoHashCandidatesBeforeNetworkIO() async {
        await assertRejected(
            SkyStreamRawStreamCandidate(
                url: "https://video.example.com/v.mp4",
                infoHash: "0123456789abcdef"
            ),
            as: .torrentContent
        )
        await assertRejected(
            SkyStreamRawStreamCandidate(url: "magnet:?xt=urn:btih:0123456789abcdef"),
            as: .torrentContent
        )
        await assertRejected(
            SkyStreamRawStreamCandidate(
                url: "https://video.example.com/v.mp4",
                torrentURL: "https://tracker.example.com/file.torrent"
            ),
            as: .torrentContent
        )
    }

    func testRejectsDRMAndExternalPlayerPoliciesBeforeNetworkIO() async {
        await assertRejected(
            SkyStreamRawStreamCandidate(
                url: "https://video.example.com/manifest.mpd",
                licenseURL: "https://license.example.com/widevine"
            ),
            as: .drmContent
        )
        await assertRejected(
            SkyStreamRawStreamCandidate(
                url: "https://video.example.com/v.mp4",
                policyHints: ["widevine": "1"]
            ),
            as: .drmContent
        )
        await assertRejected(
            SkyStreamRawStreamCandidate(
                url: "https://video.example.com/v.mp4",
                externalPlayerPolicy: "required"
            ),
            as: .externalPlayerPolicy
        )
    }

    func testRejectsCustomAndLoopbackTransportsBeforeNetworkIO() async {
        for rawURL in [
            "file:///private/video.mp4", "data:video/mp4;base64,AAAA", "javascript:alert(1)",
            "blob:https://video.example.com/id", "rtmp://video.example.com/live"
        ] {
            await assertRejected(
                SkyStreamRawStreamCandidate(url: rawURL),
                as: .prohibitedTransport
            )
        }

        for rawURL in [
            "http://localhost/video.mp4", "http://127.0.0.1/video.mp4",
            "http://169.254.169.254/latest/meta-data", "http://[::1]/video.mp4"
        ] {
            await assertSecurityRejected(SkyStreamRawStreamCandidate(url: rawURL))
        }
    }

    private func assertRejected(
        _ candidate: SkyStreamRawStreamCandidate,
        as expected: SkyStreamVODValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await SkyStreamVODValidator().validate(candidate, identity: identity)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as SkyStreamVODValidationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type \(type(of: error))", file: file, line: line)
        }
    }

    private func assertSecurityRejected(
        _ candidate: SkyStreamRawStreamCandidate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await SkyStreamVODValidator().validate(candidate, identity: identity)
            XCTFail("Expected a local-address security rejection", file: file, line: line)
        } catch let error as SkyStreamVODValidationError {
            guard case .security(let reason) = error else {
                return XCTFail("Unexpected validation error \(error)", file: file, line: line)
            }
            XCTAssertFalse(reason.isEmpty, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type \(type(of: error))", file: file, line: line)
        }
    }
}

final class SkyStreamPlatformAndDistributionTests: XCTestCase {
    func testCurrentTargetExposesSkyStreamOnlyThroughIOSCapability() {
        XCTAssertEqual(PlatformCapabilities.current.platform, .iOS)
        XCTAssertTrue(PlatformCapabilities.current.supportsSkyStreamPlugins)
        XCTAssertEqual(
            PlatformCapabilities.current.supportsSkyStreamPlugins,
            Bundle.main.allowsSkyStreamPlugins
        )
    }

    func testIOSScopedSettingIsHiddenOnTVAndMacAndRequiresCapability() {
        let descriptor = SettingDescriptor(
            id: "skystream",
            title: "SkyStream",
            scope: .iOS,
            requiredCapability: \PlatformCapabilities.supportsSkyStreamPlugins
        )

        XCTAssertTrue(descriptor.availability(on: capabilities(.iOS, skyStream: true)).isAvailable)
        XCTAssertFalse(descriptor.availability(on: capabilities(.iOS, skyStream: false)).isAvailable)
        XCTAssertFalse(descriptor.availability(on: capabilities(.tvOS, skyStream: true)).isAvailable)
        XCTAssertFalse(descriptor.availability(on: capabilities(.macOS, skyStream: true)).isAvailable)
    }

    func testDistributionDefaultsEnabledButExplicitKillSwitchWins() throws {
        let testFlight = try makeFixtureBundle([
            "EclipseDistributionChannel": "TestFlight"
        ])
        XCTAssertTrue(testFlight.isAppleReviewedDistribution)
        XCTAssertTrue(testFlight.allowsSkyStreamPlugins)

        let appStoreDisabled = try makeFixtureBundle([
            "EclipseDistributionChannel": "App Store",
            "EclipseSkyStreamPluginsEnabled": false
        ])
        XCTAssertTrue(appStoreDisabled.isAppleReviewedDistribution)
        XCTAssertFalse(appStoreDisabled.allowsSkyStreamPlugins)

        let githubStringDisabled = try makeFixtureBundle([
            "EclipseDistributionChannel": "GitHub",
            "EclipseSkyStreamPluginsEnabled": "0"
        ])
        XCTAssertFalse(githubStringDisabled.isAppleReviewedDistribution)
        XCTAssertFalse(githubStringDisabled.allowsSkyStreamPlugins)
    }

    private func capabilities(
        _ platform: EclipsePlatform,
        skyStream: Bool
    ) -> PlatformCapabilities {
        PlatformCapabilities(
            platform: platform,
            supportsReader: true,
            supportsDownloads: platform == .iOS,
            supportsBrowserAutomation: platform == .iOS,
            supportsFileSharing: true,
            supportsTouchInput: platform == .iOS,
            supportsCellularSettings: platform == .iOS,
            supportsExternalPlayers: platform == .iOS,
            supportsPictureInPicture: true,
            supportsMPV: true,
            supportsStoreKit: true,
            supportsCloudKit: true,
            supportsGitHubUpdates: false,
            supportsSkyStreamPlugins: skyStream
        )
    }

    private func makeFixtureBundle(_ values: [String: Any]) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EclipseSkyStreamTests-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        var info: [String: Any] = [
            "CFBundleIdentifier": "app.eclipse.tests.\(UUID().uuidString)",
            "CFBundleName": "SkyStreamFixture",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1"
        ]
        values.forEach { info[$0.key] = $0.value }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: directory.appendingPathComponent("Info.plist"), options: .atomic)
        return try XCTUnwrap(Bundle(path: directory.path))
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
private struct SkyStreamPackageZIPEntry {
    let path: String
    let data: Data
    let type: Entry.EntryType
    let compressionMethod: CompressionMethod

    init(
        path: String,
        data: Data = Data(),
        type: Entry.EntryType = .file,
        compressionMethod: CompressionMethod = .deflate
    ) {
        self.path = path
        self.data = data
        self.type = type
        self.compressionMethod = compressionMethod
    }
}

final class SkyStreamPackageValidatorTests: XCTestCase {
    private static let fixturePackageName = "fixture.plugin"
    private static let archiveModificationDate = Date(timeIntervalSince1970: 946_684_800)
    private static let validScript = Data(
        """
        function search(query) { return []; }
        function load(url) { return { name: "Fixture", url: url }; }
        function loadStreams(url) { return []; }
        """.utf8
    )

    func testAcceptsValidRootPackageAndVerifiesBothChecksums() throws {
        let manifest = try manifestData()
        let entries = validEntries(manifest: manifest)

        try withArchive(entries: entries) { archiveURL, stagingURL in
            let archiveData = try Data(contentsOf: archiveURL)
            let archiveHash = Self.sha256Hex(archiveData)
            let scriptHash = Self.sha256Hex(Self.validScript)

            let result = try SkyStreamPackageValidator.validateAndExtract(
                archiveAt: archiveURL,
                to: stagingURL,
                expectedPackageName: Self.fixturePackageName,
                expectedArchiveSHA256: "sha256:\(archiveHash.uppercased())",
                expectedScriptSHA256: scriptHash.uppercased()
            )

            XCTAssertEqual(result.manifest.packageName, Self.fixturePackageName)
            XCTAssertEqual(result.manifest.version, 1)
            XCTAssertEqual(result.archiveSHA256, archiveHash)
            XCTAssertEqual(result.scriptSHA256, scriptHash)
            XCTAssertEqual(result.archiveByteCount, UInt64(archiveData.count))
            XCTAssertEqual(result.expandedByteCount, UInt64(manifest.count + Self.validScript.count))
            XCTAssertEqual(result.entryCount, 2)
            XCTAssertEqual(result.stagingDirectory, stagingURL.standardizedFileURL)
            XCTAssertEqual(
                Set(try FileManager.default.contentsOfDirectory(atPath: stagingURL.path)),
                Set(["plugin.json", "plugin.js"])
            )
            XCTAssertEqual(
                try Data(contentsOf: stagingURL.appendingPathComponent("plugin.json")),
                manifest
            )
            XCTAssertEqual(
                try Data(contentsOf: stagingURL.appendingPathComponent("plugin.js")),
                Self.validScript
            )
        }
    }

    func testAcceptsPackageWithCurrentSkyStreamManifestDefaults() throws {
        let manifest = Data(#"{"packageName":"fixture.plugin"}"#.utf8)
        try withArchive(entries: validEntries(manifest: manifest)) { archiveURL, stagingURL in
            let result = try SkyStreamPackageValidator.validateAndExtract(
                archiveAt: archiveURL,
                to: stagingURL,
                expectedPackageName: Self.fixturePackageName
            )
            XCTAssertEqual(result.manifest.name, "Unknown Plugin")
            XCTAssertEqual(result.manifest.version, 1)
            XCTAssertEqual(result.manifest.authors, [])
            XCTAssertEqual(result.manifest.baseURL, "")
            XCTAssertEqual(result.manifest.languages, [])
            XCTAssertEqual(result.manifest.categories, [])
        }
    }

    func testAcceptsOpaqueProvidersAlongsideDomainsAndSanitizesOptionalIcons() throws {
        let manifest = Data(#"""
        {
          "packageName": "fixture.plugin",
          "name": "Combined Fixture",
          "version": 1,
          "baseUrl": "https://fixture.example",
          "iconUrl": "http://insecure.example/root.png",
          "domains": [
            {"name":"Primary","url":"https://fixture.example"},
            {"name":"Mirror","url":"https://mirror.example"}
          ],
          "providers": [
            {
              "id":"PRIME VIDEO",
              "name":"Prime Video",
              "iconUrl":"not a URL"
            },
            {
              "id":"prime video",
              "name":"Prime Video Alternate",
              "iconUrl":"https://images.example/prime.png"
            }
          ]
        }
        """#.utf8)

        try withArchive(entries: validEntries(manifest: manifest)) { archiveURL, stagingURL in
            let result = try SkyStreamPackageValidator.validateAndExtract(
                archiveAt: archiveURL,
                to: stagingURL,
                expectedPackageName: Self.fixturePackageName
            )

            XCTAssertEqual(result.manifest.domains?.count, 2)
            XCTAssertEqual(result.manifest.providers?.map(\.id), ["PRIME VIDEO", "prime video"])
            XCTAssertNil(result.manifest.iconURL)
            XCTAssertNil(result.manifest.providers?.first?.iconURL)
            XCTAssertEqual(
                result.manifest.providers?.last?.iconURL,
                "https://images.example/prime.png"
            )
        }
    }

    func testRejectsOuterArchiveSymlinkToRegularZIP() throws {
        let entries = validEntries(manifest: try manifestData())

        try withArchive(entries: entries) { archiveURL, stagingURL in
            let symlinkURL = archiveURL
                .deletingLastPathComponent()
                .appendingPathComponent("symlink.sky", isDirectory: false)
            try FileManager.default.createSymbolicLink(
                at: symlinkURL,
                withDestinationURL: archiveURL
            )

            let resourceValues = try symlinkURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            XCTAssertEqual(resourceValues.isSymbolicLink, true)

            try assertRejected(
                archiveAt: symlinkURL,
                stagingURL: stagingURL,
                context: "outer archive symlink",
                matching: {
                    guard case .archiveMustBeARegularFile = $0 else { return false }
                    return true
                }
            )
        }
    }

    func testRejectsTraversalAbsoluteDriveAndBackslashPaths() throws {
        let safeEntries = validEntries(manifest: try manifestData())
        let unsafePaths = [
            "../escape.txt",
            "nested/../../escape.txt",
            "/absolute.txt",
            "C:/drive-root.txt",
            "nested\\backslash.txt"
        ]

        for unsafePath in unsafePaths {
            try assertRejected(
                entries: safeEntries + [SkyStreamPackageZIPEntry(
                    path: unsafePath,
                    data: Data("unsafe".utf8)
                )],
                context: unsafePath,
                matching: {
                    guard case .invalidEntryPath(let path) = $0 else { return false }
                    return path == unsafePath
                }
            )
        }
    }

    func testRejectsExactCaseUnicodeAndFileDirectoryCollisions() throws {
        let safeEntries = validEntries(manifest: try manifestData())

        try assertRejected(
            entries: safeEntries + [SkyStreamPackageZIPEntry(
                path: "plugin.js",
                data: Data("duplicate".utf8)
            )],
            context: "exact duplicate required file",
            matching: {
                guard case .duplicateEntryPath("plugin.js") = $0 else { return false }
                return true
            }
        )

        try assertRejected(
            entries: safeEntries + [SkyStreamPackageZIPEntry(
                path: "Plugin.json",
                data: Data("{}".utf8)
            )],
            context: "case-colliding required file",
            matching: {
                guard case .duplicateEntryPath("Plugin.json") = $0 else { return false }
                return true
            }
        )

        let decomposedPath = "assets/cafe\u{301}.txt"
        try assertRejected(
            entries: safeEntries + [
                SkyStreamPackageZIPEntry(path: "assets/café.txt", data: Data("one".utf8)),
                SkyStreamPackageZIPEntry(path: decomposedPath, data: Data("two".utf8))
            ],
            context: "Unicode-normalization collision",
            matching: {
                guard case .duplicateEntryPath(let path) = $0 else { return false }
                return path == decomposedPath
            }
        )

        try assertRejected(
            entries: safeEntries + [
                SkyStreamPackageZIPEntry(path: "assets", data: Data("file".utf8)),
                SkyStreamPackageZIPEntry(path: "assets/payload.txt", data: Data("nested".utf8))
            ],
            context: "file/directory collision",
            matching: {
                guard case .fileDirectoryCollision("assets/payload.txt") = $0 else { return false }
                return true
            }
        )
    }

    func testRejectsMissingNonRegularAndSymbolicRequiredFiles() throws {
        let manifest = try manifestData()

        try assertRejected(
            entries: [SkyStreamPackageZIPEntry(path: "plugin.js", data: Self.validScript)],
            context: "missing manifest",
            matching: {
                guard case .requiredFileMissing("plugin.json") = $0 else { return false }
                return true
            }
        )

        try assertRejected(
            entries: [SkyStreamPackageZIPEntry(path: "plugin.json", data: manifest)],
            context: "missing script",
            matching: {
                guard case .requiredFileMissing("plugin.js") = $0 else { return false }
                return true
            }
        )

        try assertRejected(
            entries: [
                SkyStreamPackageZIPEntry(
                    path: "plugin.json",
                    type: .directory,
                    compressionMethod: .none
                ),
                SkyStreamPackageZIPEntry(path: "plugin.js", data: Self.validScript)
            ],
            context: "directory in place of manifest",
            matching: {
                guard case .requiredFileMustBeRegular("plugin.json") = $0 else { return false }
                return true
            }
        )

        try assertRejected(
            entries: [
                SkyStreamPackageZIPEntry(path: "plugin.json", data: manifest),
                SkyStreamPackageZIPEntry(
                    path: "plugin.js",
                    data: Data("plugin.json".utf8),
                    type: .symlink,
                    compressionMethod: .none
                )
            ],
            context: "symlink in place of script",
            matching: {
                guard case .symbolicLinkNotAllowed("plugin.js") = $0 else { return false }
                return true
            }
        )
    }

    func testRejectsMalformedAndMismatchedChecksums() throws {
        let entries = validEntries(manifest: try manifestData())

        try assertRejected(
            entries: entries,
            expectedArchiveSHA256: "not-a-sha256",
            context: "malformed archive checksum",
            matching: {
                guard case .invalidExpectedChecksum("archive") = $0 else { return false }
                return true
            }
        )

        try assertRejected(
            entries: entries,
            expectedArchiveSHA256: String(repeating: "0", count: 64),
            context: "archive checksum mismatch",
            matching: {
                guard case .checksumMismatch(let kind, _, _) = $0 else { return false }
                return kind == "archive"
            }
        )

        try assertRejected(
            entries: entries,
            expectedScriptSHA256: String(repeating: "0", count: 64),
            context: "script checksum mismatch",
            matching: {
                guard case .checksumMismatch(let kind, _, _) = $0 else { return false }
                return kind == "script"
            }
        )
    }

    func testEnforcesArchiveEntryManifestScriptAndExpandedLimits() throws {
        let manifest = try manifestData()
        let entries = validEntries(manifest: manifest)

        try assertRejected(
            entries: entries,
            limits: SkyStreamPackageValidationLimits(maximumArchiveBytes: 1),
            context: "archive byte limit",
            matching: {
                guard case .archiveTooLarge(_, 1) = $0 else { return false }
                return true
            }
        )

        try assertRejected(
            entries: entries + [SkyStreamPackageZIPEntry(
                path: "extra.txt",
                data: Data("extra".utf8)
            )],
            limits: SkyStreamPackageValidationLimits(maximumEntryCount: 2),
            context: "entry count limit",
            matching: {
                guard case .tooManyEntries(3, 2) = $0 else { return false }
                return true
            }
        )

        let manifestLimit = UInt64(manifest.count - 1)
        try assertRejected(
            entries: entries,
            limits: SkyStreamPackageValidationLimits(maximumManifestBytes: manifestLimit),
            context: "manifest byte limit",
            matching: {
                guard case .requiredFileTooLarge(let path, _, let maximum) = $0 else { return false }
                return path == "plugin.json" && maximum == manifestLimit
            }
        )

        let scriptLimit = UInt64(Self.validScript.count - 1)
        try assertRejected(
            entries: entries,
            limits: SkyStreamPackageValidationLimits(maximumScriptBytes: scriptLimit),
            context: "script byte limit",
            matching: {
                guard case .requiredFileTooLarge(let path, _, let maximum) = $0 else { return false }
                return path == "plugin.js" && maximum == scriptLimit
            }
        )

        let expandedLimit = UInt64(manifest.count + Self.validScript.count - 1)
        try assertRejected(
            entries: entries,
            limits: SkyStreamPackageValidationLimits(maximumExpandedBytes: expandedLimit),
            context: "expanded byte limit",
            matching: {
                guard case .expandedDataTooLarge(_, let maximum) = $0 else { return false }
                return maximum == expandedLimit
            }
        )
    }

    func testHighlyCompressibleEntriesStillCountTowardAggregateExpandedLimit() throws {
        let manifest = try manifestData()
        let payloadSize = 32 * 1_024
        let payloadEntries = (0..<4).map { index in
            SkyStreamPackageZIPEntry(
                path: "payload/chunk-\(index).txt",
                data: Data(repeating: UInt8(65 + index), count: payloadSize)
            )
        }
        let entries = validEntries(manifest: manifest) + payloadEntries
        let expandedLimit = UInt64(manifest.count + Self.validScript.count + (2 * payloadSize))
        let limits = SkyStreamPackageValidationLimits(
            maximumArchiveBytes: expandedLimit,
            maximumExpandedBytes: expandedLimit
        )

        try withArchive(entries: entries) { archiveURL, stagingURL in
            let compressedByteCount = try Data(contentsOf: archiveURL).count
            XCTAssertLessThan(
                UInt64(compressedByteCount),
                expandedLimit,
                "Fixture must pass the compressed-byte cap before exercising expanded-byte accounting."
            )
            try assertRejected(
                archiveAt: archiveURL,
                stagingURL: stagingURL,
                limits: limits,
                context: "aggregate compressible payload",
                matching: {
                    guard case .expandedDataTooLarge(let actual, let maximum) = $0 else { return false }
                    return actual > maximum && maximum == expandedLimit
                }
            )
        }
    }

    func testRejectsMalformedUTF8JSONPackageIdentifierAndVersions() throws {
        try assertRejected(
            entries: validEntries(manifest: Data([0xFF, 0xFE, 0xFD])),
            context: "invalid manifest UTF-8",
            matching: {
                guard case .invalidRequiredFileUTF8("plugin.json") = $0 else { return false }
                return true
            }
        )

        try assertRejected(
            entries: [
                SkyStreamPackageZIPEntry(path: "plugin.json", data: try manifestData()),
                SkyStreamPackageZIPEntry(path: "plugin.js", data: Data([0xFF, 0xFE, 0xFD]))
            ],
            context: "invalid script UTF-8",
            matching: {
                guard case .invalidRequiredFileUTF8("plugin.js") = $0 else { return false }
                return true
            }
        )

        try assertRejected(
            entries: validEntries(manifest: Data("{".utf8)),
            context: "malformed manifest JSON",
            matching: {
                guard case .invalidManifestJSON = $0 else { return false }
                return true
            }
        )

        try assertRejected(
            entries: validEntries(manifest: try manifestData(packageName: "Bad.ID")),
            context: "invalid package identifier",
            matching: {
                guard case .invalidPackageIdentifier("Bad.ID") = $0 else { return false }
                return true
            }
        )

        try assertRejected(
            entries: validEntries(manifest: try manifestData(version: 0)),
            context: "invalid plugin version",
            matching: {
                guard case .invalidPluginVersion(0) = $0 else { return false }
                return true
            }
        )

        try assertRejected(
            entries: validEntries(manifest: try manifestData(manifestVersion: 2)),
            context: "unsupported manifest version",
            matching: {
                guard case .unsupportedManifestVersion(2) = $0 else { return false }
                return true
            }
        )

        try assertRejected(
            entries: validEntries(manifest: try manifestData()),
            expectedPackageName: "different.plugin",
            context: "package identifier mismatch",
            matching: {
                guard case .packageIdentifierMismatch(let expected, let actual) = $0 else { return false }
                return expected == "different.plugin" && actual == Self.fixturePackageName
            }
        )
    }

    private func manifestData(
        packageName: String = fixturePackageName,
        version: Int = 1,
        manifestVersion: Int? = 1
    ) throws -> Data {
        var manifest: [String: Any] = [
            "packageName": packageName,
            "name": "Fixture Plugin",
            "version": version,
            "authors": ["Eclipse Tests"],
            "baseUrl": "https://fixture.example",
            "languages": ["en"],
            "categories": ["movie"]
        ]
        manifest["manifestVersion"] = manifestVersion
        return try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    }

    private func validEntries(manifest: Data) -> [SkyStreamPackageZIPEntry] {
        [
            SkyStreamPackageZIPEntry(path: "plugin.json", data: manifest),
            SkyStreamPackageZIPEntry(path: "plugin.js", data: Self.validScript)
        ]
    }

    private func assertRejected(
        entries: [SkyStreamPackageZIPEntry],
        expectedPackageName: String? = nil,
        expectedArchiveSHA256: String? = nil,
        expectedScriptSHA256: String? = nil,
        limits: SkyStreamPackageValidationLimits = .default,
        context: String,
        matching: (SkyStreamPackageValidationError) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try withArchive(entries: entries) { archiveURL, stagingURL in
            try assertRejected(
                archiveAt: archiveURL,
                stagingURL: stagingURL,
                expectedPackageName: expectedPackageName,
                expectedArchiveSHA256: expectedArchiveSHA256,
                expectedScriptSHA256: expectedScriptSHA256,
                limits: limits,
                context: context,
                matching: matching,
                file: file,
                line: line
            )
        }
    }

    private func assertRejected(
        archiveAt archiveURL: URL,
        stagingURL: URL,
        expectedPackageName: String? = nil,
        expectedArchiveSHA256: String? = nil,
        expectedScriptSHA256: String? = nil,
        limits: SkyStreamPackageValidationLimits = .default,
        context: String,
        matching: (SkyStreamPackageValidationError) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        do {
            _ = try SkyStreamPackageValidator.validateAndExtract(
                archiveAt: archiveURL,
                to: stagingURL,
                expectedPackageName: expectedPackageName,
                expectedArchiveSHA256: expectedArchiveSHA256,
                expectedScriptSHA256: expectedScriptSHA256,
                limits: limits
            )
            XCTFail("\(context): unexpectedly accepted adversarial archive", file: file, line: line)
        } catch let error as SkyStreamPackageValidationError {
            XCTAssertTrue(
                matching(error),
                "\(context): unexpected validation error \(String(reflecting: error))",
                file: file,
                line: line
            )
        } catch {
            XCTFail(
                "\(context): unexpected non-validator error \(String(reflecting: error))",
                file: file,
                line: line
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagingURL.path),
            "\(context): rejected archive published a staging directory",
            file: file,
            line: line
        )
    }

    private func withArchive<T>(
        entries: [SkyStreamPackageZIPEntry],
        _ body: (URL, URL) throws -> T
    ) throws -> T {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SkyStreamPackageValidatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let archiveURL = rootURL.appendingPathComponent("fixture.sky", isDirectory: false)
        let stagingURL = rootURL.appendingPathComponent("staged", isDirectory: true)
        try writeArchive(entries, to: archiveURL)
        return try body(archiveURL, stagingURL)
    }

    private func writeArchive(
        _ entries: [SkyStreamPackageZIPEntry],
        to archiveURL: URL
    ) throws {
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for entry in entries {
            try archive.addEntry(
                with: entry.path,
                type: entry.type,
                uncompressedSize: Int64(entry.data.count),
                modificationDate: Self.archiveModificationDate,
                compressionMethod: entry.compressionMethod,
                bufferSize: 4 * 1_024
            ) { position, requestedSize in
                let start = Int(position)
                guard start >= 0, start < entry.data.count else { return Data() }
                let end = min(start + requestedSize, entry.data.count)
                return entry.data.subdata(in: start..<end)
            }
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
