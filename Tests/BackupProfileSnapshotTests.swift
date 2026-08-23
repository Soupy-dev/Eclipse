import XCTest
@testable import Eclipse

final class BackupProfileSnapshotTests: XCTestCase {

    private func profileSnapshot(id: UUID, name: String) -> BackupProfileSnapshot {
        BackupProfileSnapshot(
            id: id,
            name: name,
            avatarSymbol: ProfileAvatar.defaultSymbol,
            avatarColorHex: ProfileAvatar.defaultColorHex,
            avatarPhotoData: nil,
            isKidsProfile: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func nuvioState(
        manifestURL: String,
        providerKeys: [String],
        enabledProviderKeys: Set<String>? = nil,
        pluginsEnabled: Bool = true,
        sortIndex: Int64 = 0,
        codeFileNameForProvider: ((String, String) -> String)? = nil
    ) -> NuvioStoredPluginsState {
        let repositoryID = NuvioPluginSupport.repositoryID(forManifestURL: manifestURL)
        let enabledKeys = enabledProviderKeys ?? Set(providerKeys)
        let scrapers = providerKeys.map { providerKey in
            let scraperID = NuvioPluginSupport.scraperSourceID(
                manifestURL: manifestURL,
                providerKey: providerKey
            )
            return NuvioPluginScraper(
                id: scraperID,
                providerKey: providerKey,
                repositoryId: repositoryID,
                repositoryUrl: manifestURL,
                name: providerKey,
                description: "Fixture provider",
                author: nil,
                version: "1.0.0",
                filename: "\(providerKey).js",
                codeFileName: codeFileNameForProvider?(providerKey, scraperID)
                    ?? "\(providerKey)-fixture.js",
                supportedTypes: ["movie", "tv"],
                enabled: enabledKeys.contains(providerKey),
                manifestEnabled: true,
                declaresSettings: true,
                logo: nil,
                contentLanguage: ["en"],
                formats: ["hls"]
            )
        }
        return NuvioStoredPluginsState(
            pluginsEnabled: pluginsEnabled,
            repositories: [
                NuvioPluginRepository(
                    id: repositoryID,
                    manifestUrl: manifestURL,
                    name: "Fixture repository",
                    description: nil,
                    version: "1.0.0",
                    scraperCount: scrapers.count,
                    lastUpdated: 1,
                    sortIndex: sortIndex
                )
            ],
            scrapers: scrapers
        )
    }

    private func legacyAidokuInstalledSourceObject(id: String) -> [String: Any] {
        [
            "id": id,
            "name": "Source \(id)",
            "version": 1,
            "languages": ["en"],
            "contentRatingRawValue": 0,
            "isEnabled": true,
            "order": 0
        ]
    }

    private func minimalBackupObject() -> [String: Any] {
        [
            "version": "2.0",
            "createdDate": 0,
            "tmdbLanguage": "en-US",
            "selectedAppearance": "system",
            "readerSelectedAppearance": "system",
            "readerGlobalAppearanceEnabled": true,
            "enableSubtitlesByDefault": false,
            "defaultSubtitleLanguage": "eng",
            "playerSubtitleAppearanceEnabled": true,
            "preferredAutoAudioLanguage": "eng",
            "preferredAnimeAudioLanguage": "jpn",
            "inAppPlayer": "none",
            "showScheduleTab": true,
            "showLocalScheduleTime": true
        ]
    }

    private func decodeBackupObject(_ object: [String: Any]) throws -> BackupData {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(
            BackupData.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func completePrivateCloudReaderState() throws -> BackupReaderExtensionState {
        try BackupReaderExtensionState(snapshot: ReaderExtensionBackupSnapshot(
            repositories: [],
            installedSources: [],
            showMatureSources: false,
            autoUpdateSources: true,
            lastAutoUpdate: nil
        ))
    }

    private func completePrivateCloudSkyState() -> SkyStreamBackupSnapshot {
        SkyStreamBackupSnapshot(
            repositories: [],
            plugins: [],
            createdAt: Date(timeIntervalSince1970: 0),
            isSafeCloudSnapshot: true,
            privateCloudConfigurationIsComplete: true
        )
    }

    private func completePrivateCloudBackup() throws -> BackupData {
        let profileID = UUID()
        let readerState = try completePrivateCloudReaderState()
        let readerConfiguration = try JSONEncoder().encode(
            ReaderExtensionPrivateCloudConfiguration(
                profileID: profileID,
                sources: []
            )
        )
        var profile = profileSnapshot(id: profileID, name: "Cloud")
        profile.trackerCredentialsAndRosterWereCaptured = true
        profile.services = []
        profile.stremioAddons = []
        profile.skyStream = completePrivateCloudSkyState()
        profile.nuvioPlugins = NuvioStoredPluginsState()
        profile.readerExtensionsState = readerState
        profile.readerPrivateCloudConfigurationData = readerConfiguration
        profile.servicesSettings = [:]
        profile.servicesSettingsWereCaptured = true

        var backup = BackupData(
            createdDate: Date(timeIntervalSince1970: 1),
            tmdbLanguage: "en-US",
            selectedAppearance: "system",
            enableSubtitlesByDefault: false,
            defaultSubtitleLanguage: "eng",
            playerSubtitleAppearanceEnabled: true,
            preferredAutoAudioLanguage: "eng",
            preferredAnimeAudioLanguage: "jpn",
            inAppPlayer: "none",
            showScheduleTab: true,
            showLocalScheduleTime: true,
            services: [],
            stremioAddons: [],
            skyStream: completePrivateCloudSkyState(),
            nuvioPlugins: NuvioStoredPluginsState(),
            readerExtensionsState: readerState,
            servicesPresent: true
        )
        backup.servicesSettings = [:]
        backup.servicesSettingsWereCaptured = true
        backup.sharesServices = false
        backup.profiles = [profile]
        backup.activeProfileID = profileID
        return backup
    }

    private func changingFirstProfile(
        in backup: BackupData,
        _ change: (inout BackupProfileSnapshot) -> Void
    ) -> BackupData {
        var changed = backup
        guard var profiles = changed.profiles, !profiles.isEmpty else { return changed }
        change(&profiles[0])
        changed.profiles = profiles
        return changed
    }

    func testLegacyBackupWithoutProfilesDecodesWithNilRoster() throws {
        let legacy = """
        {"version":"1.0","createdDate":0,"tmdbLanguage":"en-US","selectedAppearance":"system",
         "readerSelectedAppearance":"system","readerGlobalAppearanceEnabled":true,
         "enableSubtitlesByDefault":false,"defaultSubtitleLanguage":"eng",
         "playerSubtitleAppearanceEnabled":true,"preferredAutoAudioLanguage":"eng",
         "preferredAnimeAudioLanguage":"jpn","inAppPlayer":"none","showScheduleTab":true,
         "showLocalScheduleTime":true}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(BackupData.self, from: Data(legacy.utf8))

        XCTAssertNil(
            decoded.profiles,
            "A pre-profiles backup must decode with a nil roster so restore keeps applying the top-level fields to the active profile"
        )
        XCTAssertNil(decoded.activeProfileID)
        XCTAssertFalse(
            decoded.hasCustomCatalogs,
            "A backup written before custom catalogs existed carries no key, and restore must leave the destination's catalogs alone rather than apply an empty list"
        )
    }

    func testBackupWithoutExperimentalFeatureGateClaimsNoAuthorityOverIt() throws {
        let legacy = """
        {"version":"1.0","createdDate":0,"tmdbLanguage":"en-US","selectedAppearance":"system",
         "readerSelectedAppearance":"system","readerGlobalAppearanceEnabled":true,
         "enableSubtitlesByDefault":false,"defaultSubtitleLanguage":"eng",
         "playerSubtitleAppearanceEnabled":true,"preferredAutoAudioLanguage":"eng",
         "preferredAnimeAudioLanguage":"jpn","inAppPlayer":"none","showScheduleTab":true,
         "showLocalScheduleTime":true}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(BackupData.self, from: Data(legacy.utf8))

        XCTAssertNil(
            decoded.experimentalFeaturesEnabled,
            "A payload that never captured the experimental master gate must claim no authority over it; a false fallback would hide the launch-latched Cloud Sync entry on every device that restores the payload"
        )
        XCTAssertNil(decoded.experimentalFeaturesLastChangedAt)

        let encoded = try JSONEncoder().encode(decoded)
        let reencoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNil(
            reencoded["experimentalFeaturesEnabled"],
            "Re-encoding a gate-less payload must not invent a value for the master gate"
        )

        var captured = decoded
        captured.experimentalFeaturesEnabled = true
        let capturedData = try JSONEncoder().encode(captured)
        let capturedRoundTrip = try decoder.decode(BackupData.self, from: capturedData)
        XCTAssertEqual(
            capturedRoundTrip.experimentalFeaturesEnabled,
            true,
            "A payload that did capture the gate must round-trip it"
        )
    }

    func testProfileSnapshotRoundTripsEveryPerProfileDomain() throws {
        let id = UUID()
        var snapshot = BackupProfileSnapshot(
            id: id,
            name: "Kid",
            avatarSymbol: "star",
            avatarColorHex: "#FF0000",
            avatarPhotoData: nil,
            isKidsProfile: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        snapshot.userRatings = ["603": 9.5]
        snapshot.userRatingNotes = ["603": "private"]
        snapshot.settings = [
            "tmdbLanguage": try PropertyListSerialization.data(
                fromPropertyList: "fr-FR",
                format: .binary,
                options: 0
            )
        ]

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(BackupProfileSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.id, id)
        XCTAssertTrue(decoded.isKidsProfile, "The kids flag has to survive a backup round trip")
        XCTAssertEqual(decoded.userRatings["603"], 9.5)
        XCTAssertEqual(decoded.userRatingNotes["603"], "private")

        let restoredLanguage = try PropertyListSerialization.propertyList(
            from: XCTUnwrap(decoded.settings["tmdbLanguage"]),
            options: [],
            format: nil
        ) as? String
        XCTAssertEqual(
            restoredLanguage,
            "fr-FR",
            "Profile-scoped settings are property-list encoded so new preferences need no model change"
        )
    }

    func testManualMediaStateSettingsUseTypedWireValidation() throws {
        let suiteName = "BackupProfileSnapshotTests.media-state.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let wrongType = try PropertyListSerialization.data(
            fromPropertyList: "true",
            format: .binary,
            options: 0
        )
        BackupData.restoreMediaStateSettings(
            ["enableSubtitlesByDefault": wrongType],
            to: defaults
        )
        XCTAssertNil(defaults.object(forKey: "enableSubtitlesByDefault"))

        let valid = try PropertyListSerialization.data(
            fromPropertyList: true,
            format: .binary,
            options: 0
        )
        BackupData.restoreMediaStateSettings(
            ["enableSubtitlesByDefault": valid],
            to: defaults
        )
        XCTAssertEqual(defaults.object(forKey: "enableSubtitlesByDefault") as? Bool, true)
    }

    func testGenericBackupSettingsValidateRegisteredTypesAndSize() throws {
        let wrongType = try PropertyListSerialization.data(
            fromPropertyList: "true",
            format: .binary,
            options: 0
        )
        XCTAssertNil(BackupManager.validatedBackupSettingValue(
            from: wrongType,
            forKey: "servicesAutoModeEnabled"
        ))

        let valid = try PropertyListSerialization.data(
            fromPropertyList: true,
            format: .binary,
            options: 0
        )
        XCTAssertNotNil(BackupManager.validatedBackupSettingValue(
            from: valid,
            forKey: "servicesAutoModeEnabled"
        ))
        XCTAssertNil(BackupManager.validatedBackupSettingValue(
            from: Data(repeating: 0, count: 512 * 1_024 + 1),
            forKey: "nuvio.provider.setting"
        ))
    }

    func testJSONDataBackedMediaSettingsKeepTheirWireType() throws {
        let layout = [
            "popular": CatalogLayoutOverride(
                orientation: .poster,
                sizeScale: 1.1
            )
        ]
        let layoutJSON = try JSONEncoder().encode(layout)
        let layoutPlist = try PropertyListSerialization.data(
            fromPropertyList: layoutJSON,
            format: .binary,
            options: 0
        )
        XCTAssertNotNil(MediaStateSettingValueValidator.validatedValue(
            from: layoutPlist,
            forKey: HomeCatalogLayoutStore.storageKey
        ))

        let invalidLayoutJSON = try JSONEncoder().encode([
            "popular": CatalogLayoutOverride(
                orientation: .poster,
                sizeScale: 99
            )
        ])
        let invalidLayoutPlist = try PropertyListSerialization.data(
            fromPropertyList: invalidLayoutJSON,
            format: .binary,
            options: 0
        )
        XCTAssertNil(MediaStateSettingValueValidator.validatedValue(
            from: invalidLayoutPlist,
            forKey: HomeCatalogLayoutStore.storageKey
        ))

        let performanceJSON = try JSONEncoder().encode(["popularAnime": true])
        let performancePlist = try PropertyListSerialization.data(
            fromPropertyList: performanceJSON,
            format: .binary,
            options: 0
        )
        XCTAssertNotNil(MediaStateSettingValueValidator.validatedValue(
            from: performancePlist,
            forKey: PerformanceModeSettings.fastAnimeCatalogOverridesKey
        ))

        let unknownPerformanceJSON = try JSONEncoder().encode(["unknown": true])
        let unknownPerformancePlist = try PropertyListSerialization.data(
            fromPropertyList: unknownPerformanceJSON,
            format: .binary,
            options: 0
        )
        XCTAssertNil(MediaStateSettingValueValidator.validatedValue(
            from: unknownPerformancePlist,
            forKey: PerformanceModeSettings.fastAnimeCatalogOverridesKey
        ))
    }

    func testProfileRestoreSanitizesMetadataAndImplausibleClocks() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = profileSnapshot(
            id: UUID(),
            name: "  \u{0000}\(String(repeating: "é", count: 300))\n  "
        )
        snapshot.avatarSymbol = "not a symbol 🚫"
        snapshot.avatarColorHex = "not-a-color"
        snapshot.avatarPhotoData = Data(repeating: 1, count: ProfileAvatar.maximumPhotoBytes + 1)
        snapshot.pinHash = "invalid"
        snapshot.createdAt = Date(
            timeIntervalSince1970: now.timeIntervalSince1970
                + TimeInterval(10 * 365 * 24 * 60 * 60)
        )
        snapshot.pinChangedAt = snapshot.createdAt
        snapshot.kidsFlagChangedAt = Date(timeIntervalSince1970: -1)

        let sanitized = try XCTUnwrap(
            BackupManager.sanitizedProfileSnapshotForRestore(snapshot, now: now)
        )
        XCTAssertLessThanOrEqual(
            sanitized.name.utf8.count,
            BackupManager.maximumProfileNameUTF8Bytes
        )
        XCTAssertFalse(sanitized.name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }))
        XCTAssertEqual(sanitized.avatarSymbol, ProfileAvatar.defaultSymbol)
        XCTAssertEqual(sanitized.avatarColorHex, ProfileAvatar.defaultColorHex)
        XCTAssertNil(sanitized.avatarPhotoData)
        XCTAssertNil(sanitized.pinHash)
        XCTAssertEqual(sanitized.createdAt, now)
        XCTAssertNil(sanitized.pinChangedAt, "An invalid PIN cannot carry a winning restriction clock")
        XCTAssertNil(sanitized.kidsFlagChangedAt)
    }

    func testBackupRatingsRejectNoncanonicalTMDBKeysAndNormalizeValues() {
        let ratings = BackupData.sanitizedUserRatings([
            "42": 9.74,
            "43": .infinity,
            "0": 8,
            "-42": 8,
            "042": 8,
            "+44": 8,
            " 45": 8
        ])
        let notes = BackupData.sanitizedUserRatingNotes([
            "42": "  private note \n",
            "43": "   ",
            "0": "invalid",
            "042": "alias",
            "+44": "alias"
        ])

        XCTAssertEqual(ratings, ["42": 9.5, "43": 0.5])
        XCTAssertEqual(notes, ["42": "private note"])
        XCTAssertEqual(BackupData.canonicalPositiveTMDBIdentifier("42"), "42")
        XCTAssertNil(BackupData.canonicalPositiveTMDBIdentifier("042"))
    }

    func testBackupProgressSanitizerProducesValidatorCompatibleCanonicalEntries() throws {
        var olderMovie = MovieProgressEntry(id: 603, title: "Older")
        olderMovie.currentTime = 95
        olderMovie.totalDuration = 100
        olderMovie.lastUpdated = Date(timeIntervalSinceReferenceDate: 10)

        var newerMovie = MovieProgressEntry(id: 603, title: "Newer")
        newerMovie.currentTime = 105
        newerMovie.totalDuration = 100
        newerMovie.lastUpdated = Date(timeIntervalSinceReferenceDate: 20)
        newerMovie.lastHref = "https://example.invalid/signed"
        newerMovie.lastContentReference = .service(
            sourceID: "service:test",
            href: "https://example.invalid/item"
        )

        var resetMovie = MovieProgressEntry(id: 604, title: "Reset")
        resetMovie.currentTime = 0
        resetMovie.totalDuration = 100
        resetMovie.isWatched = false
        resetMovie.lastUpdated = Date(timeIntervalSinceReferenceDate: 30)

        var invalidIDMovie = MovieProgressEntry(id: 0, title: "Invalid")
        invalidIDMovie.totalDuration = 100
        var impossibleZeroDuration = MovieProgressEntry(id: 605, title: "Impossible")
        impossibleZeroDuration.currentTime = 1
        impossibleZeroDuration.totalDuration = 0
        var implausiblyFutureMovie = MovieProgressEntry(id: 606, title: "Future")
        implausiblyFutureMovie.totalDuration = 100
        implausiblyFutureMovie.lastUpdated = Date(
            timeIntervalSinceNow: MediaStateEnvelopeValidator.maximumFutureClockSkew + 60
        )

        var episode = EpisodeProgressEntry(showId: 1399, seasonNumber: 1, episodeNumber: 2)
        episode.currentTime = 101
        episode.totalDuration = 100
        episode.lastUpdated = Date(timeIntervalSinceReferenceDate: 40)
        episode.lastHref = "https://example.invalid/episode"
        var syntheticSpecialEpisode = EpisodeProgressEntry(showId: 1399, seasonNumber: -1, episodeNumber: 2)
        syntheticSpecialEpisode.totalDuration = 100
        syntheticSpecialEpisode.lastUpdated = Date(timeIntervalSinceReferenceDate: 50)
        var intMinSeasonEpisode = EpisodeProgressEntry(showId: 1399, seasonNumber: Int.min, episodeNumber: 2)
        intMinSeasonEpisode.totalDuration = 100
        intMinSeasonEpisode.lastUpdated = Date(timeIntervalSinceReferenceDate: 50)
        var overflowingSeasonEpisode = EpisodeProgressEntry(
            showId: 1399,
            seasonNumber: -(ProgressPersistencePolicy.maximumIdentifier + 1),
            episodeNumber: 2
        )
        overflowingSeasonEpisode.totalDuration = 100
        overflowingSeasonEpisode.lastUpdated = Date(timeIntervalSinceReferenceDate: 50)
        var implausiblyFutureEpisode = EpisodeProgressEntry(showId: 1399, seasonNumber: 1, episodeNumber: 3)
        implausiblyFutureEpisode.totalDuration = 100
        implausiblyFutureEpisode.lastUpdated = Date(
            timeIntervalSinceNow: MediaStateEnvelopeValidator.maximumFutureClockSkew + 60
        )

        var source = ProgressData()
        source.movieProgress = [
            olderMovie,
            invalidIDMovie,
            newerMovie,
            impossibleZeroDuration,
            implausiblyFutureMovie,
            resetMovie
        ]
        source.episodeProgress = [
            syntheticSpecialEpisode,
            intMinSeasonEpisode,
            overflowingSeasonEpisode,
            episode,
            implausiblyFutureEpisode
        ]
        source.showMetadata = [
            1399: ShowMetadata(showId: 1399, title: "Show", posterURL: nil),
            7: ShowMetadata(showId: 8, title: "Mismatched", posterURL: nil),
            -1: ShowMetadata(showId: -1, title: "Negative", posterURL: nil)
        ]
        source.hiddenUpNextShowIds = [-1, 0, 1399]

        let sanitized = BackupData.sanitizedProgressData(source)

        XCTAssertEqual(sanitized.movieProgress.map(\.id), [603, 604])
        let movie = try XCTUnwrap(sanitized.movieProgress.first { $0.id == 603 })
        XCTAssertEqual(movie.title, "Newer", "The newest duplicate wins deterministically")
        XCTAssertEqual(movie.currentTime, 105)
        XCTAssertEqual(movie.totalDuration, 105, "Positive duration drift expands rather than losing progress")
        XCTAssertNil(movie.lastHref)
        XCTAssertNil(movie.lastContentReference)
        let preservingLocalReferences = BackupData.sanitizedProgressData(
            source,
            preservingDeviceLocalReferences: true
        )
        let locallyMergedMovie = try XCTUnwrap(
            preservingLocalReferences.movieProgress.first { $0.id == 603 }
        )
        XCTAssertEqual(locallyMergedMovie.lastHref, newerMovie.lastHref)
        XCTAssertEqual(locallyMergedMovie.lastContentReference, newerMovie.lastContentReference)
        XCTAssertEqual(
            sanitized.episodeProgress.map(\.id),
            ["ep_1399_s-1_e2", "ep_1399_s1_e2"]
        )
        let canonicalEpisode = try XCTUnwrap(
            sanitized.episodeProgress.first { $0.id == "ep_1399_s1_e2" }
        )
        XCTAssertEqual(canonicalEpisode.totalDuration, 101)
        XCTAssertNil(canonicalEpisode.lastHref)
        let retainedSpecial = try XCTUnwrap(
            sanitized.episodeProgress.first { $0.id == "ep_1399_s-1_e2" }
        )
        XCTAssertEqual(retainedSpecial.seasonNumber, -1)
        XCTAssertEqual(retainedSpecial.totalDuration, 100)
        XCTAssertEqual(Set(sanitized.showMetadata.keys), [1399])
        XCTAssertEqual(sanitized.hiddenUpNextShowIds, [1399])

        let profileID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-A000-000000000001")
        )
        for movie in sanitized.movieProgress {
            let recordName = MediaStateRecordName.make(
                kind: .movieProgress,
                identifier: String(movie.id),
                profileID: profileID
            )
            let envelope = MediaStateEnvelope(
                recordName: recordName,
                kind: .movieProgress,
                payload: try JSONEncoder().encode(movie),
                modifiedAt: movie.lastUpdated,
                isCompleted: movie.isWatched || movie.progress >= 0.85
            )
            XCTAssertNil(
                MediaStateEnvelopeValidator.rejectionReason(
                    for: envelope,
                    dictionaryKey: recordName,
                    allowsSystemFields: false
                )
            )
        }
        for episode in sanitized.episodeProgress {
            let recordName = MediaStateRecordName.make(
                kind: .episodeProgress,
                identifier: episode.id,
                profileID: profileID
            )
            let envelope = MediaStateEnvelope(
                recordName: recordName,
                kind: .episodeProgress,
                payload: try JSONEncoder().encode(episode),
                modifiedAt: episode.lastUpdated,
                isCompleted: episode.isWatched || episode.progress >= 0.85
            )
            XCTAssertNil(
                MediaStateEnvelopeValidator.rejectionReason(
                    for: envelope,
                    dictionaryKey: recordName,
                    allowsSystemFields: false
                )
            )
        }
        for rejected in [intMinSeasonEpisode, overflowingSeasonEpisode] {
            let recordName = MediaStateRecordName.make(
                kind: .episodeProgress,
                identifier: rejected.id,
                profileID: profileID
            )
            let envelope = MediaStateEnvelope(
                recordName: recordName,
                kind: .episodeProgress,
                payload: try JSONEncoder().encode(rejected),
                modifiedAt: rejected.lastUpdated,
                isCompleted: rejected.isWatched || rejected.progress >= 0.85
            )
            XCTAssertNotNil(
                MediaStateEnvelopeValidator.rejectionReason(
                    for: envelope,
                    dictionaryKey: recordName,
                    allowsSystemFields: false
                )
            )
        }
    }

    func testProgressPolicyRejectsExtremeDurationButRetainsProgressAfterStrippingInvalidContext() throws {
        var extreme = MovieProgressEntry(id: 700, title: "Extreme")
        extreme.currentTime = 1
        extreme.totalDuration = .greatestFiniteMagnitude
        extreme.lastUpdated = Date(timeIntervalSince1970: 100)

        var episode = EpisodeProgressEntry(showId: 701, seasonNumber: 1, episodeNumber: 2)
        episode.currentTime = 30
        episode.totalDuration = 100
        episode.lastUpdated = Date(timeIntervalSince1970: 101)
        episode.playbackContext = EpisodePlaybackContext(
            localSeasonNumber: 1,
            localEpisodeNumber: 2,
            anilistMediaId: Int.min,
            tmdbSeasonNumber: nil,
            tmdbEpisodeNumber: nil,
            tmdbEpisodeOffset: Int.max,
            animeAbsoluteEpisodeNumber: nil,
            animeSeasonEpisodeCount: nil,
            isSpecial: false,
            titleOnlySearch: false
        )

        var source = ProgressData()
        source.movieProgress = [extreme]
        source.episodeProgress = [episode]
        let sanitized = BackupData.sanitizedProgressData(source)

        XCTAssertTrue(sanitized.movieProgress.isEmpty)
        let retained = try XCTUnwrap(sanitized.episodeProgress.first)
        XCTAssertEqual(retained.currentTime, 30)
        XCTAssertEqual(retained.totalDuration, 100)
        XCTAssertNil(retained.playbackContext)
    }

    func testProgressNumericAccessorsAndRemainingTimeCannotTrapOnHostileFiniteValues() {
        let context = EpisodePlaybackContext(
            localSeasonNumber: 1,
            localEpisodeNumber: Int.max,
            anilistMediaId: Int.min,
            tmdbSeasonNumber: 1,
            tmdbEpisodeNumber: nil,
            tmdbEpisodeOffset: Int.max,
            animeAbsoluteEpisodeNumber: Int.max,
            animeSeasonEpisodeCount: nil,
            isSpecial: false,
            titleOnlySearch: false
        )
        XCTAssertNil(context.exactMALMediaId)
        XCTAssertNil(context.resolvedTMDBEpisodeNumber)
        _ = context.forEpisodeNumber(Int.max)

        let item = ContinueWatchingItem(
            id: "hostile",
            tmdbId: 1,
            isMovie: true,
            title: "Hostile",
            posterURL: nil,
            progress: 0,
            lastUpdated: Date(),
            seasonNumber: nil,
            episodeNumber: nil,
            currentTime: 0,
            totalDuration: .greatestFiniteMagnitude,
            playbackContext: nil,
            isAnime: false,
            statusText: nil,
            isWatchNext: false,
            traktPlaybackId: nil
        )
        XCTAssertEqual(item.remainingTime, "720h left")
    }

    func testPersistedAnimeIdentitySeedDropsIntMinMALWithoutDroppingSearchResult() throws {
        let json = Data(
            """
            {
              "id": 42,
              "media_type": "tv",
              "popularity": 1,
              "anime_identity_seed": {
                "anilistId": 123,
                "malId": -9223372036854775808,
                "kitsuId": 456,
                "format": "TV"
              }
            }
            """.utf8
        )
        let result = try JSONDecoder().decode(TMDBSearchResult.self, from: json)
        XCTAssertEqual(result.id, 42)
        XCTAssertEqual(result.animeIdentitySeed?.anilistId, 123)
        XCTAssertNil(result.animeIdentitySeed?.malId)
        XCTAssertEqual(result.animeIdentitySeed?.kitsuId, 456)
    }

    func testBackupDropsUnboundedCatalogIdentitiesButRetainsValidNeighbors() throws {
        var object = minimalBackupObject()
        let validResult: [String: Any] = [
            "id": 42,
            "media_type": "movie",
            "title": "Valid",
            "popularity": 1
        ]
        let invalidResult: [String: Any] = [
            "id": Int.max,
            "media_type": "tv",
            "name": "Hostile",
            "popularity": 1
        ]
        object["collections"] = [[
            "id": UUID().uuidString,
            "name": "Bookmarks",
            "items": [
                ["searchResult": validResult, "dateAdded": 0],
                ["searchResult": invalidResult, "dateAdded": 0]
            ]
        ]]
        object["recommendationCache"] = [invalidResult, validResult]

        let decoded = try decodeBackupObject(object)
        XCTAssertEqual(decoded.collections.count, 1)
        XCTAssertEqual(decoded.collections[0].items.map(\.searchResult.id), [42])
        XCTAssertEqual(decoded.recommendationCache.map(\.id), [42])

        let encoded = try JSONEncoder().encode(decoded)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(String(Int.max)))
    }

    func testProfileSnapshotRoundTripsUnreadableDomainAuthority() throws {
        var snapshot = BackupProfileSnapshot(
            id: UUID(),
            name: "Partial",
            avatarSymbol: "person",
            avatarColorHex: "#123456",
            avatarPhotoData: nil,
            isKidsProfile: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        snapshot.progressWasCaptured = false
        snapshot.ratingsWereCaptured = false
        snapshot.collectionsWereCaptured = false
        snapshot.catalogsWereCaptured = false
        snapshot.mangaCollectionsWereCaptured = false
        snapshot.mangaReadingProgressWasCaptured = false
        snapshot.mangaCatalogsWereCaptured = false
        snapshot.customCatalogsWereCaptured = false

        let decoded = try JSONDecoder().decode(
            BackupProfileSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertFalse(decoded.progressWasCaptured)
        XCTAssertFalse(decoded.ratingsWereCaptured)
        XCTAssertFalse(decoded.collectionsWereCaptured)
        XCTAssertFalse(decoded.catalogsWereCaptured)
        XCTAssertFalse(decoded.mangaCollectionsWereCaptured)
        XCTAssertFalse(decoded.mangaReadingProgressWasCaptured)
        XCTAssertFalse(decoded.mangaCatalogsWereCaptured)
        XCTAssertFalse(decoded.customCatalogsWereCaptured)
    }

    func testLegacyProfileSnapshotDefaultsMissingAuthorityFlagsToCaptured() throws {
        let snapshot = BackupProfileSnapshot(
            id: UUID(),
            name: "Legacy",
            avatarSymbol: "person",
            avatarColorHex: "#123456",
            avatarPhotoData: nil,
            isKidsProfile: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in [
            "progressWasCaptured", "ratingsWereCaptured", "collectionsWereCaptured",
            "catalogsWereCaptured", "trackerStateWasCaptured", "mangaCollectionsWereCaptured",
            "mangaReadingProgressWasCaptured", "mangaCatalogsWereCaptured",
            "customCatalogsWereCaptured"
        ] {
            object.removeValue(forKey: key)
        }

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(BackupProfileSnapshot.self, from: legacy)

        XCTAssertTrue(decoded.progressWasCaptured)
        XCTAssertTrue(decoded.ratingsWereCaptured)
        XCTAssertTrue(decoded.collectionsWereCaptured)
        XCTAssertTrue(decoded.catalogsWereCaptured)
        XCTAssertTrue(decoded.trackerStateWasCaptured)
        XCTAssertTrue(decoded.mangaCollectionsWereCaptured)
        XCTAssertTrue(decoded.mangaReadingProgressWasCaptured)
        XCTAssertTrue(decoded.mangaCatalogsWereCaptured)
        XCTAssertTrue(decoded.customCatalogsWereCaptured)
    }

    func testProfileSnapshotCannotClaimAuthorityOverOmittedPayloads() throws {
        let snapshot = BackupProfileSnapshot(
            id: UUID(),
            name: "Partial transfer",
            avatarSymbol: "person",
            avatarColorHex: "#123456",
            avatarPhotoData: nil,
            isKidsProfile: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        for key in [
            "collections", "progressData", "trackerState", "catalogs",
            "userRatings", "userRatingNotes", "mangaCollections",
            "mangaReadingProgress", "mangaCatalogs", "customCatalogs"
        ] {
            object.removeValue(forKey: key)
        }

        let decoded = try JSONDecoder().decode(
            BackupProfileSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertFalse(decoded.progressWasCaptured)
        XCTAssertFalse(decoded.ratingsWereCaptured)
        XCTAssertFalse(decoded.collectionsWereCaptured)
        XCTAssertFalse(decoded.catalogsWereCaptured)
        XCTAssertFalse(decoded.trackerStateWasCaptured)
        XCTAssertFalse(decoded.mangaCollectionsWereCaptured)
        XCTAssertFalse(decoded.mangaReadingProgressWasCaptured)
        XCTAssertFalse(decoded.mangaCatalogsWereCaptured)
        XCTAssertFalse(decoded.customCatalogsWereCaptured)
        XCTAssertTrue(decoded.progressData.movieProgress.isEmpty)
        XCTAssertTrue(decoded.userRatings.isEmpty)
        XCTAssertTrue(decoded.userRatingNotes.isEmpty)
    }

    func testProfileSnapshotTreatsNullPayloadAsAbsentEvenWhenCaptureFlagIsTrue() throws {
        let snapshot = BackupProfileSnapshot(
            id: UUID(),
            name: "Interrupted transfer",
            avatarSymbol: "person",
            avatarColorHex: "#123456",
            avatarPhotoData: nil,
            isKidsProfile: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        object["progressData"] = NSNull()
        object["progressWasCaptured"] = true

        let decoded = try JSONDecoder().decode(
            BackupProfileSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertFalse(decoded.progressWasCaptured)
        XCTAssertTrue(decoded.progressData.movieProgress.isEmpty)
        XCTAssertTrue(decoded.progressData.episodeProgress.isEmpty)

        var nullFlagObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        nullFlagObject["progressWasCaptured"] = NSNull()
        let nullFlagDecoded = try JSONDecoder().decode(
            BackupProfileSnapshot.self,
            from: JSONSerialization.data(withJSONObject: nullFlagObject)
        )
        XCTAssertFalse(
            nullFlagDecoded.progressWasCaptured,
            "An explicit null flag is an interrupted field, not a flagless legacy payload"
        )
    }

    func testProfileSnapshotRatingsAuthorityRequiresRatingsAndNotesPair() throws {
        let snapshot = BackupProfileSnapshot(
            id: UUID(),
            name: "Ratings pair",
            avatarSymbol: "person",
            avatarColorHex: "#123456",
            avatarPhotoData: nil,
            isKidsProfile: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let original = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        for missingKey in ["userRatings", "userRatingNotes"] {
            var partial = original
            partial.removeValue(forKey: missingKey)
            partial["ratingsWereCaptured"] = true
            let decoded = try JSONDecoder().decode(
                BackupProfileSnapshot.self,
                from: JSONSerialization.data(withJSONObject: partial)
            )
            XCTAssertFalse(
                decoded.ratingsWereCaptured,
                "A missing \(missingKey) half must preserve both destination ratings and notes"
            )
        }

        var legacy = original
        legacy.removeValue(forKey: "ratingsWereCaptured")
        let legacyDecoded = try JSONDecoder().decode(
            BackupProfileSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertTrue(
            legacyDecoded.ratingsWereCaptured,
            "Flagless legacy snapshots remain authoritative when both payload halves are present"
        )
    }

    func testTopLevelDestructiveDomainsRequireDecodedNonNullPayloads() throws {
        let omitted = try decodeBackupObject(minimalBackupObject())
        XCTAssertFalse(omitted.hasCollections)
        XCTAssertFalse(omitted.hasProgressData)
        XCTAssertFalse(omitted.hasTrackerState)
        XCTAssertFalse(omitted.hasCatalogs)
        XCTAssertFalse(omitted.hasServices)

        let omittedRoundTrip = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(omitted))
                as? [String: Any]
        )
        for key in ["collections", "progressData", "trackerState", "catalogs", "services"] {
            XCTAssertNil(
                omittedRoundTrip[key],
                "Re-encoding must not promote an omitted \(key) payload into authoritative empty state"
            )
        }

        var explicitEmpty = minimalBackupObject()
        explicitEmpty["collections"] = []
        explicitEmpty["progressData"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ProgressData())
        )
        explicitEmpty["trackerState"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TrackerState())
        )
        explicitEmpty["catalogs"] = []
        explicitEmpty["services"] = []
        let capturedEmpty = try decodeBackupObject(explicitEmpty)
        XCTAssertTrue(capturedEmpty.hasCollections)
        XCTAssertTrue(capturedEmpty.hasProgressData)
        XCTAssertTrue(capturedEmpty.hasTrackerState)
        XCTAssertTrue(capturedEmpty.hasCatalogs)
        XCTAssertTrue(capturedEmpty.hasServices)

        var explicitNull = minimalBackupObject()
        for key in ["collections", "progressData", "trackerState", "catalogs", "services"] {
            explicitNull[key] = NSNull()
        }
        let interrupted = try decodeBackupObject(explicitNull)
        XCTAssertFalse(interrupted.hasCollections)
        XCTAssertFalse(interrupted.hasProgressData)
        XCTAssertFalse(interrupted.hasTrackerState)
        XCTAssertFalse(interrupted.hasCatalogs)
        XCTAssertFalse(interrupted.hasServices)
    }

    func testPartialTopLevelSettingsApplyOnlySuccessfullyDecodedKeys() throws {
        var partial = minimalBackupObject()
        partial["showScheduleTab"] = false
        partial["servicesAutoModeEnabled"] = false
        partial["defaultPlaybackSpeed"] = NSNull()
        let decoded = try decodeBackupObject(partial)

        XCTAssertTrue(decoded.topLevelSettingIsAuthoritative(storageKey: "showScheduleTab"))
        XCTAssertTrue(decoded.topLevelSettingIsAuthoritative(storageKey: "servicesAutoModeEnabled"))
        XCTAssertFalse(
            decoded.topLevelSettingIsAuthoritative(storageKey: "defaultPlaybackSpeed"),
            "A null setting must preserve the destination rather than applying the decoder default"
        )
        XCTAssertFalse(
            decoded.topLevelSettingIsAuthoritative(storageKey: "holdSpeedPlayer"),
            "An omitted setting must preserve the destination"
        )
        let roundTripped = try JSONDecoder().decode(
            BackupData.self,
            from: JSONEncoder().encode(decoded)
        )
        XCTAssertTrue(roundTripped.topLevelSettingIsAuthoritative(storageKey: "showScheduleTab"))
        XCTAssertFalse(
            roundTripped.topLevelSettingIsAuthoritative(storageKey: "holdSpeedPlayer"),
            "Decode/re-encode must not promote an omitted setting's serialized default into restore authority"
        )

        let lenientKeys = BackupData.decodedTopLevelSettingKeys(fromJSONObject: [
            "showScheduleTab": false,
            "defaultPlaybackSpeed": 1.25,
            "holdSpeedPlayer": "not-a-number",
            "playerChoice": "mpv",
            "servicesAutoModeEnabled": NSNull()
        ])
        XCTAssertTrue(lenientKeys.contains("showScheduleTab"))
        XCTAssertTrue(lenientKeys.contains("defaultPlaybackSpeed"))
        XCTAssertFalse(lenientKeys.contains("holdSpeedPlayer"))
        XCTAssertFalse(lenientKeys.contains("servicesAutoModeEnabled"))
        XCTAssertTrue(
            BackupData.topLevelSettingIsAuthoritative(
                storageKey: PlaybackEngine.defaultsKey,
                decodedWireKeys: lenientKeys
            ),
            "The legacy playerChoice key must still authorize the modern playbackEngine setting"
        )
        XCTAssertFalse(BackupData.topLevelSettingIsAuthoritative(
            storageKey: "servicesAutoModeEnabled",
            decodedWireKeys: lenientKeys
        ))
    }

    func testTopLevelRatingsAuthorityRequiresRatingsAndNotesPair() throws {
        var ratingsOnly = minimalBackupObject()
        ratingsOnly["userRatings"] = ["603": 9.5]
        XCTAssertFalse(try decodeBackupObject(ratingsOnly).hasUserRatings)

        var notesOnly = minimalBackupObject()
        notesOnly["userRatingNotes"] = ["603": "private"]
        XCTAssertFalse(try decodeBackupObject(notesOnly).hasUserRatings)

        var pairedEmpty = minimalBackupObject()
        pairedEmpty["userRatings"] = [String: Double]()
        pairedEmpty["userRatingNotes"] = [String: String]()
        XCTAssertTrue(
            try decodeBackupObject(pairedEmpty).hasUserRatings,
            "An explicitly captured empty pair remains authoritative"
        )

        var interruptedPair = pairedEmpty
        interruptedPair["userRatingNotes"] = NSNull()
        XCTAssertFalse(try decodeBackupObject(interruptedPair).hasUserRatings)
    }

    func testTopLevelTrackerHonorsProfileCaptureFlag() {
        XCTAssertTrue(BackupManager.topLevelDomainIsAuthoritative(
            payloadWasDecoded: true,
            profileCaptureFlag: nil
        ), "A present flagless legacy payload remains authoritative")
        XCTAssertTrue(BackupManager.topLevelDomainIsAuthoritative(
            payloadWasDecoded: true,
            profileCaptureFlag: true
        ))
        XCTAssertFalse(BackupManager.topLevelDomainIsAuthoritative(
            payloadWasDecoded: true,
            profileCaptureFlag: false
        ), "An unreadable profile tracker snapshot must veto its top-level compatibility copy")
        XCTAssertFalse(BackupManager.topLevelDomainIsAuthoritative(
            payloadWasDecoded: false,
            profileCaptureFlag: true
        ), "A capture flag cannot authorize an omitted/null payload")
    }

    func testSearchHistoryCaptureRequiresDecodedQueries() throws {
        for object: [String: Any] in [
            ["wasCaptured": true],
            ["queries": NSNull(), "wasCaptured": true],
            ["queries": "not-an-array", "wasCaptured": true]
        ] {
            let decoded = try JSONDecoder().decode(
                BackupSearchHistory.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            XCTAssertFalse(decoded.wasCaptured)
            XCTAssertTrue(decoded.queries.isEmpty)
        }

        let explicitEmpty = try JSONDecoder().decode(
            BackupSearchHistory.self,
            from: Data(#"{"queries":[],"wasCaptured":true}"#.utf8)
        )
        XCTAssertTrue(explicitEmpty.wasCaptured)
        XCTAssertTrue(explicitEmpty.queries.isEmpty)

        let legacyEmptyArray = try JSONDecoder().decode(
            BackupSearchHistory.self,
            from: Data("[]".utf8)
        )
        XCTAssertTrue(
            legacyEmptyArray.wasCaptured,
            "A directly decoded legacy array exists even when it is empty"
        )

        let lenientEmptyArray = BackupSearchHistory(jsonValue: [String]())
        XCTAssertTrue(
            lenientEmptyArray.wasCaptured,
            "Lenient decoding must preserve explicit-empty array authority"
        )
    }

    func testSearchHistoryRejectsOversizedStorageAndBoundsQueriesUTF8Safely() throws {
        let longASCII = String(repeating: "a", count: 4_096)
        let longUnicode = String(repeating: "👨‍👩‍👧‍👦", count: 100)
        let sanitized = BackupSearchHistory.sanitizedQueries(
            [longASCII, longUnicode] + (0..<20).map { "query-\($0)" }
        )

        XCTAssertEqual(sanitized.count, BackupSearchHistory.maximumQueryCount)
        XCTAssertEqual(sanitized[0].utf8.count, BackupSearchHistory.maximumQueryUTF8Bytes)
        XCTAssertLessThanOrEqual(
            sanitized[1].utf8.count,
            BackupSearchHistory.maximumQueryUTF8Bytes
        )
        XCTAssertTrue(
            String(data: Data(sanitized[1].utf8), encoding: .utf8) != nil,
            "Bounding must stop on a Character boundary rather than split UTF-8"
        )

        let validData = try JSONEncoder().encode(["  First query  ", "SECOND"])
        XCTAssertEqual(
            BackupSearchHistory.decodedQueries(from: validData),
            ["First query", "SECOND"]
        )
        XCTAssertNil(BackupSearchHistory.decodedQueries(from: Data("not json".utf8)))
        XCTAssertNil(BackupSearchHistory.decodedQueries(
            from: Data(repeating: 0x20, count: BackupSearchHistory.maximumEncodedBytes + 1)
        ))
    }

    func testUntrustedDoubleToIntConversionRequiresFiniteExactValue() {
        XCTAssertEqual(BackupData.optionalInt(from: 30.0, defaultValue: 7), 30)
        XCTAssertEqual(BackupData.optionalInt(from: 30.5, defaultValue: 7), 7)
        XCTAssertEqual(BackupData.optionalInt(from: Double.infinity, defaultValue: 7), 7)
        XCTAssertEqual(BackupData.optionalInt(from: Double.nan, defaultValue: 7), 7)
        XCTAssertEqual(BackupData.optionalInt(from: Double.greatestFiniteMagnitude, defaultValue: 7), 7)
    }

    func testBackupNumericSettingsStayFiniteAndBoundedAcrossConstructionAndEncoding() throws {
        var untrustedWire = minimalBackupObject()
        untrustedWire["defaultPlaybackSpeed"] = 999.0
        untrustedWire["holdSpeedPlayer"] = 999.0
        untrustedWire["nextEpisodeThreshold"] = 0.01
        untrustedWire["playerDoubleTapSeekSeconds"] = 999.0
        untrustedWire["subtitleFontSize"] = 999.0
        untrustedWire["subtitleVerticalOffset"] = -999.0
        untrustedWire["readerFontSize"] = 999.0
        untrustedWire["readerLineSpacing"] = 999.0
        untrustedWire["readerMargin"] = -999.0
        untrustedWire["autoClearCacheThresholdMB"] = Double.greatestFiniteMagnitude
        untrustedWire["highQualityThreshold"] = -100.0
        let boundedWire = try decodeBackupObject(untrustedWire)
        XCTAssertEqual(boundedWire.defaultPlaybackSpeed, 3)
        XCTAssertEqual(boundedWire.holdSpeedPlayer, 3)
        XCTAssertEqual(boundedWire.nextEpisodeThreshold, 0.5)
        XCTAssertEqual(boundedWire.playerDoubleTapSeekSeconds, 60)
        XCTAssertEqual(boundedWire.subtitleFontSize, 96)
        XCTAssertEqual(boundedWire.subtitleVerticalOffset, -24)
        XCTAssertEqual(boundedWire.readerFontSize, 32)
        XCTAssertEqual(boundedWire.readerLineSpacing, 3)
        XCTAssertEqual(boundedWire.readerMargin, 0)
        XCTAssertEqual(boundedWire.autoClearCacheThresholdMB, 5_000)
        XCTAssertEqual(boundedWire.highQualityThreshold, 0)

        var backup = BackupData(
            createdDate: Date(timeIntervalSince1970: 1),
            tmdbLanguage: "en",
            selectedAppearance: "system",
            enableSubtitlesByDefault: false,
            defaultSubtitleLanguage: "eng",
            playerSubtitleAppearanceEnabled: true,
            preferredAutoAudioLanguage: "eng",
            preferredAnimeAudioLanguage: "jpn",
            inAppPlayer: "mpv",
            showScheduleTab: true,
            showLocalScheduleTime: true,
            defaultPlaybackSpeed: .infinity,
            holdSpeedPlayer: .nan,
            nextEpisodeThreshold: -.infinity,
            playerDoubleTapSeekSeconds: Double.greatestFiniteMagnitude,
            experimentalFeaturesLastChangedAt: .infinity,
            subtitleStrokeWidth: .nan,
            subtitleFontSize: .infinity,
            subtitleVerticalOffset: -.infinity,
            readerFontSize: .infinity,
            readerLineSpacing: .nan,
            readerMargin: -.infinity,
            autoClearCacheThresholdMB: .infinity,
            highQualityThreshold: .nan
        )

        XCTAssertEqual(backup.defaultPlaybackSpeed, 1)
        XCTAssertEqual(backup.holdSpeedPlayer, 2)
        XCTAssertEqual(backup.nextEpisodeThreshold, 0.9)
        XCTAssertEqual(backup.playerDoubleTapSeekSeconds, 60)
        XCTAssertNil(backup.experimentalFeaturesLastChangedAt)
        XCTAssertEqual(backup.subtitleStrokeWidth, 1)
        XCTAssertEqual(backup.subtitleFontSize, 30)
        XCTAssertEqual(backup.subtitleVerticalOffset, -6)
        XCTAssertEqual(backup.readerFontSize, 16)
        XCTAssertEqual(backup.readerLineSpacing, 1.6)
        XCTAssertEqual(backup.readerMargin, 4)
        XCTAssertEqual(backup.autoClearCacheThresholdMB, 500)
        XCTAssertEqual(backup.highQualityThreshold, 0.9)

        // Public mutable fields can still be polluted after construction.
        // Encoding is the final safety boundary and must not let one setting
        // make the entire backup fail.
        backup.defaultPlaybackSpeed = .infinity
        backup.holdSpeedPlayer = .nan
        backup.nextEpisodeThreshold = -.infinity
        backup.playerDoubleTapSeekSeconds = .infinity
        backup.experimentalFeaturesLastChangedAt = .nan
        backup.subtitleStrokeWidth = .infinity
        backup.subtitleFontSize = .nan
        backup.subtitleVerticalOffset = .infinity
        backup.experimentalHeroHeightScale = .infinity
        backup.experimentalGradientScrollMotion = .nan
        backup.readerPillarboxAmount = .infinity
        backup.readerReadThresholdPercent = .nan
        backup.readerFontSize = .infinity
        backup.readerLineSpacing = .nan
        backup.readerMargin = -.infinity
        backup.autoClearCacheThresholdMB = .infinity
        backup.highQualityThreshold = .nan
        backup.servicesResultMinimumSimilarity = .infinity

        let data = try JSONEncoder().encode(backup)
        let decoded = try JSONDecoder().decode(BackupData.self, from: data)
        let finiteValues = [
            decoded.defaultPlaybackSpeed,
            decoded.holdSpeedPlayer,
            decoded.nextEpisodeThreshold,
            decoded.playerDoubleTapSeekSeconds,
            decoded.subtitleStrokeWidth,
            decoded.subtitleFontSize,
            decoded.subtitleVerticalOffset,
            decoded.experimentalHeroHeightScale,
            decoded.experimentalGradientScrollMotion,
            decoded.readerPillarboxAmount,
            decoded.readerReadThresholdPercent,
            decoded.readerFontSize,
            decoded.readerLineSpacing,
            decoded.readerMargin,
            decoded.autoClearCacheThresholdMB,
            decoded.highQualityThreshold,
            decoded.servicesResultMinimumSimilarity
        ]
        XCTAssertTrue(finiteValues.allSatisfy(\.isFinite))
        XCTAssertNil(decoded.experimentalFeaturesLastChangedAt)
        XCTAssertEqual(decoded.defaultPlaybackSpeed, 1)
        XCTAssertEqual(decoded.autoClearCacheThresholdMB, 500)
        XCTAssertEqual(decoded.servicesResultMinimumSimilarity, 0.85)
    }

    func testLocalNotificationBackupPayloadsAreBoundedBeforeRestore() throws {
        let now = Date()
        let validReminder = LocalEpisodeNotificationReminder(
            id: "anime-1-episode-1",
            source: .anime,
            sourceMediaID: 1,
            tmdbID: 2,
            tmdbMediaType: .tv,
            title: "Episode",
            season: 1,
            episode: 1,
            airingAt: now.addingTimeInterval(86_400),
            hasKnownAiringTime: true,
            isStreamingRelease: false,
            isAnimeSpecial: false
        )
        let hostileReminder = LocalEpisodeNotificationReminder(
            id: "hostile",
            source: .anime,
            sourceMediaID: 2,
            tmdbID: nil,
            tmdbMediaType: nil,
            title: "Far future",
            season: nil,
            episode: 2,
            airingAt: Date(timeIntervalSince1970: Double.greatestFiniteMagnitude),
            hasKnownAiringTime: true,
            isStreamingRelease: false,
            isAnimeSpecial: false
        )
        let remindersData = try JSONEncoder().encode([validReminder, hostileReminder])
        let remindersJSON = try XCTUnwrap(String(data: remindersData, encoding: .utf8))

        let mutedKeys = Set((0..<600).map { "episode-\($0)" })
        let subscription = LocalMediaNotificationSubscription(
            id: "anime-2",
            source: .anime,
            tmdbID: 2,
            title: String(repeating: "T", count: 2_000),
            titleAliases: (0..<40).map {
                "Alias \($0) " + String(repeating: "A", count: 2_000)
            },
            animeMediaIDs: Set(1...600),
            animeSpecialMediaIDs: Set(601...1_200),
            knownWesternSeasonIDs: Set(1...600),
            episodeNotifications: true,
            futureSeasonNotifications: true,
            mutedEpisodeKeys: mutedKeys,
            mutedEpisodeExpirations: Dictionary(
                uniqueKeysWithValues: mutedKeys.map { ($0, now.addingTimeInterval(86_400)) }
            ),
            seasonPremieres: [
                LocalSeasonPremiere(
                    id: "future-season",
                    title: "Future",
                    seasonLabel: "Season 2",
                    premiereDate: Date(timeIntervalSince1970: Double.greatestFiniteMagnitude),
                    hasExactTime: false,
                    seasonNumber: 2,
                    sourceMediaID: 3
                )
            ],
            dateAdded: Date(timeIntervalSince1970: Double.greatestFiniteMagnitude)
        )
        let subscriptionsData = try JSONEncoder().encode([subscription])
        let subscriptionsJSON = try XCTUnwrap(String(data: subscriptionsData, encoding: .utf8))

        var object = minimalBackupObject()
        object["localNotificationEpisodeReminders"] = remindersJSON
        object["localNotificationSubscriptions"] = subscriptionsJSON
        object["localNotificationEpisodeLeadTime"] = Int.max
        object["localNotificationSeasonLeadTime"] = -1
        let decoded = try decodeBackupObject(object)

        let sanitizedRemindersJSON = try XCTUnwrap(decoded.localNotificationEpisodeReminders)
        let sanitizedReminders = try JSONDecoder().decode(
            [LocalEpisodeNotificationReminder].self,
            from: Data(sanitizedRemindersJSON.utf8)
        )
        XCTAssertEqual(sanitizedReminders.map(\.id), [validReminder.id])
        XCTAssertNil(decoded.localNotificationEpisodeLeadTime)
        XCTAssertNil(decoded.localNotificationSeasonLeadTime)

        let sanitizedSubscriptionsJSON = try XCTUnwrap(decoded.localNotificationSubscriptions)
        let sanitizedSubscriptions = try JSONDecoder().decode(
            [LocalMediaNotificationSubscription].self,
            from: Data(sanitizedSubscriptionsJSON.utf8)
        )
        let sanitizedSubscription = try XCTUnwrap(sanitizedSubscriptions.first)
        XCTAssertEqual(sanitizedSubscriptions.count, 1)
        XCTAssertLessThanOrEqual(sanitizedSubscription.title.count, 1_024)
        XCTAssertLessThanOrEqual(sanitizedSubscription.titleAliases.count, 32)
        XCTAssertLessThanOrEqual(sanitizedSubscription.animeMediaIDs.count, 512)
        XCTAssertLessThanOrEqual(sanitizedSubscription.animeSpecialMediaIDs.count, 512)
        XCTAssertLessThanOrEqual(sanitizedSubscription.knownWesternSeasonIDs.count, 512)
        XCTAssertLessThanOrEqual(sanitizedSubscription.mutedEpisodeKeys.count, 512)
        XCTAssertLessThanOrEqual(sanitizedSubscription.mutedEpisodeExpirations.count, 512)
        XCTAssertNil(sanitizedSubscription.seasonPremieres.first?.premiereDate)
        XCTAssertEqual(sanitizedSubscription.dateAdded, Date(timeIntervalSince1970: 0))

        XCTAssertEqual(BackupData.sanitizedLocalNotificationEpisodeReminders("[]"), "[]")
        XCTAssertNil(BackupData.sanitizedLocalNotificationEpisodeReminders("not-json"))
        XCTAssertNil(
            BackupData.sanitizedLocalNotificationEpisodeReminders(
                String(repeating: "x", count: 262_145)
            )
        )
        XCTAssertNil(
            BackupData.sanitizedLocalNotificationEpisodeReminders(
                try XCTUnwrap(
                    String(
                        data: JSONEncoder().encode([hostileReminder]),
                        encoding: .utf8
                    )
                )
            ),
            "A nonempty but wholly malformed reminder domain must preserve the destination, not clear it"
        )
    }

    func testNotificationTimeBucketsRejectNonFiniteAndImplausibleDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let valid = now.addingTimeInterval(300)
        XCTAssertEqual(
            LocalNotificationManager.notificationTimeBucket(for: valid, now: now),
            Int(valid.timeIntervalSince1970 / 300)
        )
        XCTAssertNil(
            LocalNotificationManager.notificationTimeBucket(
                for: Date(timeIntervalSince1970: .infinity),
                now: now
            )
        )
        XCTAssertNil(
            LocalNotificationManager.notificationTimeBucket(
                for: Date(timeIntervalSince1970: Double.greatestFiniteMagnitude),
                now: now
            )
        )
        XCTAssertNil(
            LocalNotificationManager.notificationTimeBucket(
                for: now.addingTimeInterval(11 * 366 * 24 * 60 * 60),
                now: now
            )
        )
    }

    func testSnapshotPredatingCustomCatalogsClaimsNoAuthorityOverThem() throws {
        let snapshot = BackupProfileSnapshot(
            id: UUID(),
            name: "Before the feature",
            avatarSymbol: "person",
            avatarColorHex: "#123456",
            avatarPhotoData: nil,
            isKidsProfile: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "customCatalogs")
        object.removeValue(forKey: "customCatalogsWereCaptured")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(BackupProfileSnapshot.self, from: legacy)

        XCTAssertTrue(decoded.customCatalogs.isEmpty)
        XCTAssertFalse(
            decoded.customCatalogsWereCaptured,
            "every backup written before custom catalogs existed lacks the key entirely; defaulting it to captured restores an empty list over the destination's real catalogs on the per-profile path, which has no other presence gate"
        )
        XCTAssertTrue(
            decoded.mangaCatalogsWereCaptured,
            "the older domain remains authoritative because its payload is present"
        )
    }

    func testCustomCatalogStoreIsNotSweptIntoTheProfileSettingsDictionary() {
        let profileKey = ProfileScopedStorage.defaultsKey(
            base: "kanzenCustomCatalogs",
            profileID: ProfileManager.defaultProfileID
        )
        XCTAssertFalse(
            BackupManager.carriesProfileScopedSetting(profileKey),
            "the raw catalog blob must travel only as a first-class captured domain; swept into settings it is restored with no customCatalogsWereCaptured gate"
        )
        XCTAssertFalse(
            BackupManager.carriesProfileScopedSetting(
                ProfileScopedStorage.defaultsKey(
                    base: "kanzenMangaCatalogs",
                    profileID: ProfileManager.defaultProfileID
                )
            )
        )
    }

    func testDeviceLocalTrackerAndRuntimeKeysAreNotSweptIntoCloudSettings() {
        for key in [
            "trackerPendingCredentialDeletions.v1",
            "trackerPendingDiscardedProfileCleanup.v1",
            "traktHistoryWriteReceipts.v1",
            "localNotificationFutureMetadataRefreshDates",
            "Reader.upscaleModelName"
        ] {
            XCTAssertFalse(
                BackupManager.carriesProfileScopedSetting(key),
                "\(key) describes state that only exists on the originating device"
            )
        }
    }

    func testExperimentalCloudSnapshotDoesNotAdvertiseADeviceLocalReaderModel() {
        var backup = BackupData(
            createdDate: Date(timeIntervalSince1970: 1),
            tmdbLanguage: "en",
            selectedAppearance: "system",
            enableSubtitlesByDefault: false,
            defaultSubtitleLanguage: "en",
            playerSubtitleAppearanceEnabled: true,
            preferredAutoAudioLanguage: "en",
            preferredAnimeAudioLanguage: "ja",
            inAppPlayer: "mpv",
            showScheduleTab: true,
            showLocalScheduleTime: true
        )
        backup.readerUpscaleModelName = "DeviceOnly.mlmodel"
        backup.experimentalICloudSyncEnabled = true
        let redacted = backup.redactedForExperimentalCloudSync()

        XCTAssertEqual(
            redacted.readerUpscaleModelName,
            "None"
        )
        XCTAssertFalse(redacted.experimentalICloudSyncEnabled)
        XCTAssertNil(
            BackupReaderUpscaleModelRestorePolicy.modelNameToApply(
                incoming: redacted.readerUpscaleModelName,
                preservesDeviceLocalSelection: true
            )
        )
        XCTAssertEqual(
            BackupReaderUpscaleModelRestorePolicy.modelNameToApply(
                incoming: "ManualBackup.mlmodel",
                preservesDeviceLocalSelection: false
            ),
            "ManualBackup.mlmodel"
        )
    }

    func testExperimentalCloudNuvioMergeUsesIncomingSettingsForSurvivingProviders() throws {
        let manifestURL = "https://plugins.example/public/manifest.json"
        var current = nuvioState(
            manifestURL: manifestURL,
            providerKeys: ["survives", "removed"]
        )
        let survivingID = NuvioPluginSupport.scraperSourceID(
            manifestURL: manifestURL,
            providerKey: "survives"
        )
        let removedID = NuvioPluginSupport.scraperSourceID(
            manifestURL: manifestURL,
            providerKey: "removed"
        )
        current.scraperSettings = [
            survivingID: ["apiOption": .string("receiver-only")],
            removedID: ["removedOption": .bool(true)]
        ]

        var incoming = nuvioState(
            manifestURL: manifestURL,
            providerKeys: ["survives", "new-provider"],
            enabledProviderKeys: ["new-provider"],
            pluginsEnabled: false
        )
        incoming.scraperSettings = [
            survivingID: ["mustNotTravel": .string("cloud-value")]
        ]

        let plan = BackupData.nuvioRestorePlanForExperimentalCloudSync(
            incoming: incoming,
            current: current
        )

        XCTAssertFalse(plan.state.pluginsEnabled, "Cloud-safe enablement remains authoritative")
        XCTAssertFalse(try XCTUnwrap(plan.state.scrapers.first { $0.id == survivingID }).enabled)
        XCTAssertNil(plan.state.scrapers.first { $0.id == removedID })
        XCTAssertEqual(
            plan.state.scraperSettings,
            [survivingID: ["mustNotTravel": .string("cloud-value")]],
            "Bounded private-cloud settings are authoritative, and a removed provider must lose its orphaned receiver settings"
        )
        XCTAssertTrue(plan.deviceLocalSourceIDs.isEmpty)
    }

    func testExperimentalCloudNuvioMergeRoundTripsCredentialURLAndHonorsDeletion() throws {
        let concurrentlyAddedSafeURL = "https://plugins.example/concurrent/manifest.json"
        let privateURL = "https://plugins.example/private/manifest.json?token=device-secret"
        let incomingURL = "https://plugins.example/incoming/manifest.json"
        let safeLocal = nuvioState(
            manifestURL: concurrentlyAddedSafeURL,
            providerKeys: ["safe-local"]
        )
        let privateLocal = nuvioState(
            manifestURL: privateURL,
            providerKeys: ["private-local"]
        )
        var current = NuvioStoredPluginsState(
            repositories: safeLocal.repositories + privateLocal.repositories,
            scrapers: safeLocal.scrapers + privateLocal.scrapers
        )
        let safeLocalScraperID = try XCTUnwrap(safeLocal.scrapers.first?.id)
        let privateScraperID = try XCTUnwrap(privateLocal.scrapers.first?.id)
        current.scraperSettings = [
            safeLocalScraperID: ["safeConcurrent": .bool(true)],
            privateScraperID: ["token": .string("kept-only-on-this-device")]
        ]
        let incoming = nuvioState(
            manifestURL: incomingURL,
            providerKeys: ["incoming"]
        )

        let plan = BackupData.nuvioRestorePlanForExperimentalCloudSync(
            incoming: incoming,
            current: current
        )
        let resultingRepositoryIDs = Set(plan.state.repositories.map(\.id))

        XCTAssertEqual(
            resultingRepositoryIDs,
            Set([try XCTUnwrap(incoming.repositories.first?.id)])
        )
        XCTAssertNil(plan.state.scraperSettings[safeLocalScraperID])
        XCTAssertNil(plan.state.scraperSettings[privateScraperID])
        XCTAssertTrue(
            plan.deviceLocalSourceIDs.isEmpty,
            "A bounded credential-bearing repository is representable in private cloud, so an authoritative omission deletes it"
        )
    }

    func testExperimentalCloudNuvioMergeTreatsExplicitEmptyLocalStateAsEmpty() {
        var incoming = nuvioState(
            manifestURL: "https://plugins.example/new/manifest.json",
            providerKeys: ["new-provider"]
        )
        let incomingID = incoming.scrapers[0].id
        incoming.scraperSettings = [incomingID: ["secret": .string("must-redact")]]

        let plan = BackupData.nuvioRestorePlanForExperimentalCloudSync(
            incoming: incoming,
            current: NuvioStoredPluginsState()
        )

        XCTAssertEqual(
            plan.state,
            BackupData.nuvioStateForExperimentalCloudSync(incoming)
        )
        XCTAssertEqual(
            plan.state.scraperSettings,
            [incomingID: ["secret": .string("must-redact")]]
        )
        XCTAssertTrue(plan.deviceLocalSourceIDs.isEmpty)
    }

    func testExperimentalCloudLocalSourceSelectionKeepsReceiverOnlySlots() {
        let localRepositoryID = "nuvio:local-repository"
        let localProviderID = "nuvio:local-provider"
        let preserved = Set([localRepositoryID, localProviderID])

        XCTAssertEqual(
            ExperimentalCloudLocalSourceSelectionPolicy.membership(
                current: ["nuvio:old-shared", localProviderID],
                incoming: ["nuvio:new-shared"],
                preserving: preserved
            ),
            ["nuvio:new-shared", localProviderID]
        )
        XCTAssertEqual(
            ExperimentalCloudLocalSourceSelectionPolicy.order(
                current: ["nuvio:old-a", localRepositoryID, "nuvio:old-b", localProviderID],
                incoming: ["nuvio:new-a", "nuvio:new-b", "nuvio:new-c"],
                preserving: preserved
            ),
            ["nuvio:new-a", localRepositoryID, "nuvio:new-b", localProviderID, "nuvio:new-c"]
        )
    }

    func testPrivateCloudServiceAndStremioConfigurationRoundTripsExactly() throws {
        let service = BackupService(
            id: UUID(),
            url: "https://services.example/anime.json?install_token=fixture-token",
            jsonMetadata: #"{"sourceName":"Fixture","authorization":"metadata-value"}"#,
            jsScript: "const session = 'fixture-session'; const api_key = 'fixture-key';",
            isActive: true,
            sortIndex: 4
        )
        XCTAssertEqual(
            BackupData.serviceForExperimentalCloudSync(service),
            service,
            "Executable Service settings belong in the bounded private-cloud payload"
        )

        let configuredURL = "https://torrentio.example/realdebrid=fixture-token,qualityfilter=all"
        let addon = BackupStremioAddon(
            id: UUID(),
            configuredURL: configuredURL,
            manifestJSON: #"{"id":"fixture","name":"Fixture","authorization":"fixture"}"#,
            isActive: true,
            sortIndex: 7
        )
        XCTAssertEqual(
            BackupData.stremioAddonForExperimentalCloudSync(addon),
            addon,
            "The configured capability path must not be projected to a public origin"
        )

        let opaqueAIOConfiguration = String(repeating: "a", count: 122)
        let aio = BackupStremioAddon(
            id: UUID(),
            configuredURL: "https://aio.example/stremio/fixture1/00000000-0000-4000-a000-000000000001/\(opaqueAIOConfiguration)",
            manifestJSON: #"{"id":"aio","name":"AIO"}"#,
            isActive: false,
            sortIndex: 8
        )
        XCTAssertEqual(BackupData.stremioAddonForExperimentalCloudSync(aio), aio)
    }

    func testPrivateCloudSourceMergePreservesOnlyUnrepresentableLocalRows() {
        let deletedByCloud = BackupService(
            id: UUID(),
            url: "https://services.example/old.json",
            jsonMetadata: "{}",
            jsScript: "old",
            isActive: true,
            sortIndex: 0
        )
        let deviceLocal = BackupService(
            id: UUID(),
            url: "file:///private/provider.json",
            jsonMetadata: "{}",
            jsScript: "local",
            isActive: true,
            sortIndex: 1
        )
        let incoming = BackupService(
            id: UUID(),
            url: "https://services.example/new.json",
            jsonMetadata: "{}",
            jsScript: "new",
            isActive: false,
            sortIndex: 2
        )

        let services = ExperimentalCloudSourceRestorePolicy.services(
            current: [deletedByCloud, deviceLocal],
            incoming: [incoming]
        )
        XCTAssertEqual(Set(services.map(\.id)), Set([deviceLocal.id, incoming.id]))

        let deletedConfiguredAddon = BackupStremioAddon(
            id: UUID(),
            configuredURL: "https://stremio.example/config=private-fixture",
            manifestJSON: "{}",
            isActive: true,
            sortIndex: 0
        )
        let localInvalidAddon = BackupStremioAddon(
            id: UUID(),
            configuredURL: "stremio-local://unrepresentable",
            manifestJSON: "{}",
            isActive: true,
            sortIndex: 1
        )
        let addons = ExperimentalCloudSourceRestorePolicy.stremioAddons(
            current: [deletedConfiguredAddon, localInvalidAddon],
            incoming: []
        )
        XCTAssertEqual(addons, [localInvalidAddon])
    }

    func testPrivateCloudSourceProjectionRejectsUnboundedPayloads() {
        let valid = BackupService(
            id: UUID(),
            url: "https://services.example/valid.json",
            jsonMetadata: "{}",
            jsScript: "valid",
            isActive: true,
            sortIndex: 0
        )
        let oversized = BackupService(
            id: UUID(),
            url: "https://services.example/large.json",
            jsonMetadata: "{}",
            jsScript: String(repeating: "x", count: 512 * 1_024 + 1),
            isActive: true,
            sortIndex: 0
        )
        XCTAssertNil(BackupData.serviceForExperimentalCloudSync(oversized))
        XCTAssertNil(
            BackupData.servicesForExperimentalCloudSync([valid, oversized]),
            "One rejected present row must omit the complete source family"
        )

        let validAddon = BackupStremioAddon(
            id: UUID(),
            configuredURL: "https://addons.example/configured/valid",
            manifestJSON: "{}",
            isActive: true,
            sortIndex: 0
        )
        let rejectedAddon = BackupStremioAddon(
            id: UUID(),
            configuredURL: "device-local://unrepresentable",
            manifestJSON: "{}",
            isActive: true,
            sortIndex: 1
        )
        XCTAssertNil(
            BackupData.stremioAddonsForExperimentalCloudSync([
                validAddon,
                rejectedAddon
            ])
        )
    }

    func testNuvioMediaStateCaptureDistinguishesAbsentFromUnreadable() throws {
        let absent = try XCTUnwrap(
            BackupData.nuvioMetadataForMediaState(persistedValue: nil)
        )
        let empty = try JSONDecoder().decode(NuvioStoredPluginsState.self, from: absent)
        XCTAssertTrue(empty.repositories.isEmpty)
        XCTAssertTrue(empty.scrapers.isEmpty)
        XCTAssertNil(
            BackupData.nuvioMetadataForMediaState(
                persistedValue: Data("not-json".utf8)
            )
        )
        XCTAssertNil(
            BackupData.nuvioMetadataForMediaState(
                persistedValue: Data(
                    repeating: 0,
                    count: NuvioPluginStore.Bounds.persistedStateBytes + 1
                )
            )
        )
        XCTAssertNil(
            BackupData.nuvioMetadataForMediaState(persistedValue: "wrong-type")
        )
    }

    func testServicesSettingsCompletenessCreatesOnlyEligibleTombstones() {
        let current: Set<String> = [
            "autoUpdateServicesEnabled",
            "nuvioPluginsState.v2",
            "readerExtensions.preferenceOverlay.v1",
            "tmdbLanguage"
        ]
        XCTAssertEqual(
            BackupManager.missingAuthoritativeServicesSettingKeys(
                current: current,
                incoming: [],
                capturedCompletely: true
            ),
            ["autoUpdateServicesEnabled"]
        )
        XCTAssertTrue(
            BackupManager.missingAuthoritativeServicesSettingKeys(
                current: current,
                incoming: [],
                capturedCompletely: false
            ).isEmpty
        )
    }

    func testNuvioRestoreAutoModeCandidatesAreRunnableProvidersNeverRepositoryIDs() throws {
        let manifestURL = "https://plugins.example/auto-mode/manifest.json"
        let state = nuvioState(
            manifestURL: manifestURL,
            providerKeys: ["enabled", "disabled"],
            enabledProviderKeys: ["enabled"]
        )
        let enabledID = NuvioPluginSupport.scraperSourceID(
            manifestURL: manifestURL,
            providerKey: "enabled"
        )

        XCTAssertEqual(state.runnableScraperSourceIDs, [enabledID])
        XCTAssertFalse(
            state.runnableScraperSourceIDs.contains(try XCTUnwrap(state.repositories.first?.id))
        )
    }

    func testNuvioCodeReadinessReportsPartialAndEmptyRepositoryRepairs() throws {
        let first = nuvioState(
            manifestURL: "https://plugins.example/partial/manifest.json",
            providerKeys: ["ready", "pending"]
        )
        let empty = nuvioState(
            manifestURL: "https://plugins.example/empty/manifest.json",
            providerKeys: []
        )
        let state = NuvioStoredPluginsState(
            repositories: first.repositories + empty.repositories,
            scrapers: first.scrapers
        )
        let readyID = try XCTUnwrap(first.scrapers.first { $0.providerKey == "ready" }?.id)
        let pendingID = try XCTUnwrap(first.scrapers.first { $0.providerKey == "pending" }?.id)
        let firstRepositoryID = try XCTUnwrap(first.repositories.first?.id)
        let emptyRepositoryID = try XCTUnwrap(empty.repositories.first?.id)

        let readiness = state.codeReadiness { _, codeFileName in
            codeFileName == "ready-fixture.js"
        }

        XCTAssertEqual(readiness.readyProviderCount, 1)
        XCTAssertEqual(readiness.pendingProviderIDs, [pendingID])
        XCTAssertEqual(readiness.pendingProviderCountByRepository, [firstRepositoryID: 1])
        XCTAssertEqual(
            readiness.pendingRepositoryIDs,
            [firstRepositoryID, emptyRepositoryID]
        )
        XCTAssertTrue(readiness.retryPending)
        XCTAssertFalse(readiness.isComplete)
        XCTAssertNotEqual(readyID, pendingID)
    }

    func testLegacyNuvioSharedPayloadMigratesMetadataToContentAddressedCodeBeforeRestore() throws {
        let manifestURL = "https://plugins.example/legacy/manifest.json"
        let code = "function getStreams() { return []; }"
        let state = nuvioState(
            manifestURL: manifestURL,
            providerKeys: ["legacy"],
            codeFileNameForProvider: { _, scraperID in
                NuvioPluginSupport.codeFileName(forScraperID: scraperID)
            }
        )
        let repositoryID = try XCTUnwrap(state.repositories.first?.id)
        let scraperID = try XCTUnwrap(state.scrapers.first?.id)
        let legacyFileName = try XCTUnwrap(state.scrapers.first?.codeFileName)
        let contentAddressedFileName = NuvioPluginStore.codeFileName(
            forScraperID: scraperID,
            code: code
        )
        var backup = try decodeBackupObject(minimalBackupObject())
        backup.nuvioPlugins = state
        var profile = profileSnapshot(id: UUID(), name: "Legacy Nuvio")
        profile.nuvioPlugins = state
        backup.profiles = [profile]
        backup.nuvioSharedPayloads = [
            BackupNuvioSharedPayload(
                repositoryID: repositoryID,
                scraperID: scraperID,
                codeFileName: legacyFileName,
                code: code
            )
        ]
        var writes: [(String, String, String)] = []

        let migration = BackupManager.migratingNuvioSharedPayloadsForRestore(backup) {
            writtenCode, writtenRepositoryID, writtenScraperID in
            writes.append((writtenCode, writtenRepositoryID, writtenScraperID))
            return contentAddressedFileName
        }

        XCTAssertNotEqual(legacyFileName, contentAddressedFileName)
        XCTAssertEqual(migration.migratedPayloadCount, 1)
        XCTAssertEqual(migration.refusedPayloadCount, 0)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, code)
        XCTAssertEqual(writes.first?.1, repositoryID)
        XCTAssertEqual(writes.first?.2, scraperID)
        XCTAssertEqual(
            migration.backup.nuvioPlugins?.scrapers.first?.codeFileName,
            contentAddressedFileName
        )
        XCTAssertEqual(
            migration.backup.profiles?.first?.nuvioPlugins?.scrapers.first?.codeFileName,
            contentAddressedFileName
        )
        XCTAssertEqual(
            migration.backup.nuvioSharedPayloads?.first?.codeFileName,
            contentAddressedFileName
        )
        let topLevelReadiness = try XCTUnwrap(migration.backup.nuvioPlugins).codeReadiness {
            restoredRepositoryID, restoredCodeFileName in
            restoredRepositoryID == repositoryID
                && restoredCodeFileName == contentAddressedFileName
        }
        XCTAssertEqual(topLevelReadiness.readyProviderCount, 1)
        XCTAssertTrue(topLevelReadiness.pendingProviderIDs.isEmpty)
    }

    private func comixCustomCatalog() -> KanzenCustomCatalog {
        let sort = ReaderExtensionFilter(
            key: "sort",
            title: "Sort",
            kind: .sort,
            options: [
                ReaderExtensionFilterOption(
                    label: "Best Match",
                    value: "desc",
                    abiExtras: ["param": .string("relevance")]
                ),
                ReaderExtensionFilterOption(
                    label: "Most Popular",
                    value: "desc",
                    abiExtras: ["param": .string("rating")]
                ),
                ReaderExtensionFilterOption(
                    label: "Least Popular",
                    value: "asc",
                    abiExtras: ["param": .string("rating")]
                ),
                ReaderExtensionFilterOption(
                    label: "Newest",
                    value: "desc",
                    abiExtras: ["param": .string("created_at")]
                )
            ],
            value: .string("desc"),
            abiType: "SortFilter",
            abiState: .object(["index": .number(0), "ascending": .bool(false)]),
            sortAscending: false,
            selectedOptionIndex: 3
        )
        let genres = ReaderExtensionFilter(
            key: "genres",
            title: "Genres",
            kind: .group,
            options: [],
            value: .stringList([]),
            children: [
                ReaderExtensionFilter(
                    key: "genre-action",
                    title: "Action",
                    kind: .triState,
                    options: [],
                    value: .number(1)
                ),
                ReaderExtensionFilter(
                    key: "genre-ecchi",
                    title: "Ecchi",
                    kind: .triState,
                    options: [],
                    value: .number(2)
                )
            ]
        )
        return KanzenCustomCatalog(
            title: "Newest Weekly",
            sourceID: ReaderExtensionSourceID(rawValue: String(repeating: "c", count: 64)),
            query: "pirates",
            filters: [sort, genres],
            order: 3
        )
    }

    func testBackupRoundTripPreservesACustomCatalogsWholeFilterTree() throws {
        let catalog = comixCustomCatalog()
        var snapshot = profileSnapshot(id: UUID(), name: "Reader")
        snapshot.customCatalogs = [catalog]

        let decoded = try JSONDecoder().decode(
            BackupProfileSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        let restored = try XCTUnwrap(decoded.customCatalogs.first)

        XCTAssertEqual(
            restored,
            catalog,
            "a restored catalog that differs anywhere in its filter tree searches differently than the search that created it"
        )

        let sort = try XCTUnwrap(restored.filters.first)
        XCTAssertEqual(
            sort.options.map(\.value),
            ["desc", "desc", "asc", "desc"],
            "option value strings repeat within a source, so a value match cannot identify the chosen sort"
        )
        XCTAssertEqual(
            sort.selectedOptionIndex,
            3,
            "the positional selection is the only thing distinguishing options that share a value string"
        )
        XCTAssertEqual(
            sort.options[3].abiExtras?["param"],
            .string("created_at"),
            "Comix carries its query parameter key in an option's custom param field, so option-level ABI extras must survive a backup"
        )
        XCTAssertEqual(sort.sortAscending, false)
        XCTAssertEqual(restored.filters.last?.children.map(\.value), [.number(1), .number(2)])
    }

    func testTopLevelBackupPayloadRoundTripsCustomCatalogsAndRecordsTheirPresence() throws {
        let seed = """
        {"version":"2.0","createdDate":0,"tmdbLanguage":"en-US","selectedAppearance":"system",
         "readerSelectedAppearance":"system","readerGlobalAppearanceEnabled":true,
         "enableSubtitlesByDefault":false,"defaultSubtitleLanguage":"eng",
         "playerSubtitleAppearanceEnabled":true,"preferredAutoAudioLanguage":"eng",
         "preferredAnimeAudioLanguage":"jpn","inAppPlayer":"none","showScheduleTab":true,
         "showLocalScheduleTime":true}
        """
        let seedDecoder = JSONDecoder()
        seedDecoder.dateDecodingStrategy = .secondsSince1970
        var backup = try seedDecoder.decode(BackupData.self, from: Data(seed.utf8))
        XCTAssertFalse(
            backup.hasCustomCatalogs,
            "a payload with no custom-catalog key must not claim to carry the domain"
        )

        let catalog = comixCustomCatalog()
        backup.customCatalogs = [catalog]

        let decoded = try JSONDecoder().decode(
            BackupData.self,
            from: JSONEncoder().encode(backup)
        )

        XCTAssertTrue(decoded.hasCustomCatalogs)
        let restored = try XCTUnwrap(decoded.customCatalogs.first)
        XCTAssertEqual(restored, catalog)
        XCTAssertEqual(restored.filters.first?.selectedOptionIndex, 3)
        XCTAssertEqual(
            restored.filters.first?.options[3].abiExtras?["param"],
            .string("created_at")
        )
    }

    func testUnreadableCustomCatalogStoreIsOmittedAndRestoreKeepsTheDestinationCopy() throws {
        let sourceSuite = "BackupProfileSnapshotTests.custom-catalogs-source.\(UUID().uuidString)"
        let sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }

        let profileID = UUID()
        let storageKey = KanzenCustomCatalogManager.storageKey(for: profileID)
        let corrupt = Data("not a catalog list".utf8)
        sourceDefaults.set(corrupt, forKey: storageKey)

        let reader = KanzenCustomCatalogManager(defaults: sourceDefaults, profileID: UUID())
        let captured = reader.catalogsSnapshot(forProfile: profileID)

        XCTAssertNil(
            captured,
            "bytes that exist but do not decode must report as uncaptured, never as an empty catalog set"
        )
        XCTAssertEqual(
            sourceDefaults.data(forKey: storageKey),
            corrupt,
            "a backup read must preserve the bytes it could not decode rather than quarantine them"
        )

        var snapshot = profileSnapshot(id: profileID, name: "Unreadable")
        if let captured {
            snapshot.customCatalogs = captured
        } else {
            snapshot.customCatalogsWereCaptured = false
        }

        let decoded = try JSONDecoder().decode(
            BackupProfileSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        XCTAssertFalse(decoded.customCatalogsWereCaptured)
        XCTAssertTrue(decoded.customCatalogs.isEmpty)

        let destinationSuite = "BackupProfileSnapshotTests.custom-catalogs-destination.\(UUID().uuidString)"
        let destinationDefaults = try XCTUnwrap(UserDefaults(suiteName: destinationSuite))
        defer { destinationDefaults.removePersistentDomain(forName: destinationSuite) }
        let destination = KanzenCustomCatalogManager(
            defaults: destinationDefaults,
            profileID: profileID
        )
        try destination.save(comixCustomCatalog())

        if decoded.customCatalogsWereCaptured {
            destination.applyRestoredCatalogs(decoded.customCatalogs, forProfile: profileID)
        }

        XCTAssertEqual(
            destination.catalogs.map(\.title),
            ["Newest Weekly"],
            "a domain the source could not read must never overwrite the destination's own catalogs"
        )
    }

    func testAidokuBackupPackageDigestIsBackwardCompatibleAndRoundTrips() throws {
        let digest = String(repeating: "a", count: 64)
        let source = BackupAidokuInstalledSource(
            id: "source.one",
            name: "Source",
            version: 2,
            languages: ["en"],
            iconPath: nil,
            externalIconURL: nil,
            contentRatingRawValue: 0,
            sourceListURL: "https://example.com/list.json",
            packageURL: "https://example.com/source.zip",
            isEnabled: true,
            order: 0,
            lastUpdated: nil,
            lastError: nil,
            packageDigest: digest,
            payloadArchiveData: nil
        )
        let encoded = try JSONEncoder().encode(source)
        XCTAssertEqual(
            try JSONDecoder().decode(BackupAidokuInstalledSource.self, from: encoded).packageDigest,
            digest
        )

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "packageDigest")
        let legacy = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertNil(
            try JSONDecoder().decode(BackupAidokuInstalledSource.self, from: legacy).packageDigest
        )
    }

    func testLegacyAidokuBackupRejectsMoreThan512InstalledRows() throws {
        let rows = (0...512).map {
            legacyAidokuInstalledSourceObject(id: "source.\($0)")
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "sourceLists": [],
            "installedSources": rows,
            "showMatureSources": false,
            "autoUpdateSources": true
        ])

        XCTAssertThrowsError(try JSONDecoder().decode(BackupAidokuState.self, from: data))
    }

    func testLegacyAidokuBackupIgnoresExecutableArchiveFieldsWithoutDecodingThem() throws {
        let largeArchive = String(repeating: "A", count: 1024 * 1024)
        var source = legacyAidokuInstalledSourceObject(id: "source.one")
        source["payloadArchiveData"] = largeArchive
        let data = try JSONSerialization.data(withJSONObject: [
            "sourceLists": [],
            "installedSources": [source],
            "showMatureSources": false,
            "autoUpdateSources": true,
            "sharedPayloads": ["source.one": largeArchive]
        ])

        let decoded = try JSONDecoder().decode(BackupAidokuState.self, from: data)
        XCTAssertNil(decoded.installedSources.first?.payloadArchiveData)
        XCTAssertNil(decoded.sharedPayloads)

        let reencoded = try JSONEncoder().encode(decoded)
        let reencodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        XCTAssertNil(reencodedObject["sharedPayloads"])
        let installedRows = try XCTUnwrap(reencodedObject["installedSources"] as? [[String: Any]])
        XCTAssertNil(installedRows.first?["payloadArchiveData"])
        XCTAssertFalse(String(decoding: reencoded, as: UTF8.self).contains(largeArchive))
    }

    func testLegacyAidokuBackupDecodesAsMetadataOnlyReaderExtensionsState() throws {
        var snapshot = profileSnapshot(id: UUID(), name: "Legacy Reader")
        let executableSentinel = Data("must-not-survive".utf8)
        snapshot.aidokuState = BackupAidokuState(
            sourceLists: [
                BackupAidokuSourceListRecord(
                    url: "https://legacy.example/list.json",
                    name: "Legacy list",
                    sourceCount: 1,
                    lastRefresh: nil,
                    lastError: nil
                )
            ],
            installedSources: [
                BackupAidokuInstalledSource(
                    id: "source.one",
                    name: "Source",
                    version: 3,
                    languages: ["EN"],
                    iconPath: "/private/icon.png",
                    externalIconURL: "https://legacy.example/icon.png",
                    contentRatingRawValue: 1,
                    sourceListURL: "https://legacy.example/list.json",
                    packageURL: "https://provider.example/source.aix",
                    isEnabled: true,
                    order: 2,
                    lastUpdated: nil,
                    lastError: "private failure",
                    packageDigest: String(repeating: "a", count: 64),
                    payloadArchiveData: executableSentinel
                )
            ],
            showMatureSources: true,
            autoUpdateSources: false,
            lastAutoUpdate: nil,
            sharedPayloads: ["source.one": executableSentinel]
        )

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        legacyObject["aidokuState"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(snapshot.aidokuState)
        )
        let decoded = try JSONDecoder().decode(
            BackupProfileSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )

        XCTAssertNil(decoded.aidokuState?.sharedPayloads)
        XCTAssertNil(decoded.aidokuState?.installedSources.first?.payloadArchiveData)
        XCTAssertEqual(decoded.readerExtensionsState?.legacyAidokuSources.first?.id, "source.one")
        XCTAssertEqual(decoded.readerExtensionsState?.legacyAidokuSources.first?.originHost, "provider.example")
        XCTAssertEqual(decoded.readerExtensionsState?.sourceCountForCompatibility, 1)
        XCTAssertEqual(decoded.readerExtensionsState?.showMatureSources, true)
        XCTAssertEqual(decoded.readerExtensionsState?.autoUpdateSources, false)

        let reencoded = try JSONEncoder().encode(decoded)
        let text = String(decoding: reencoded, as: UTF8.self)
        XCTAssertFalse(text.contains("aidokuState"))
        XCTAssertFalse(text.contains("source.aix"))
        XCTAssertFalse(text.contains(executableSentinel.base64EncodedString()))
        XCTAssertTrue(text.contains("readerExtensionsState"))
    }

    func testReaderSourceRawSettingsAreNeverReencoded() throws {
        var snapshot = profileSnapshot(id: UUID(), name: "Reader")
        let value = try PropertyListSerialization.data(
            fromPropertyList: true,
            format: .binary,
            options: 0
        )
        snapshot.servicesSettings = [
            "kanzenAidokuInstalledSources": value,
            "kanzenAidokuUnknownFutureKey": value,
            "readerExtensions.installedSources.v1": value,
            "readerExtensions.approvedDomains.v1": value,
            "servicesAutoModeEnabled": value
        ]

        let decoded = try JSONDecoder().decode(
            BackupProfileSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(Set(decoded.servicesSettings.keys), ["servicesAutoModeEnabled"])
    }

    func testDeviceLocalSchedulingKeysAreDroppedFromCloudServicesSettings() throws {
        var snapshot = profileSnapshot(id: UUID(), name: "Scheduling")
        let value = try PropertyListSerialization.data(
            fromPropertyList: true,
            format: .binary,
            options: 0
        )
        snapshot.servicesSettings = [
            "lastServiceAutoUpdateTimestamp": value,
            "kanzenLastModuleAutoUpdate": value,
            "nuvioMissingCodeRepairCursor.v1": value,
            "skyStreamPendingSafeCloudSnapshot.v1": value,
            "servicesAutoModeEnabled": value
        ]

        let decoded = try JSONDecoder().decode(
            BackupProfileSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(Set(decoded.servicesSettings.keys), ["servicesAutoModeEnabled"])
    }

    func testConflictDigestIgnoresBackgroundMaintenanceStamps() throws {
        func readerState(stamp: Int, version: String, capabilities: [String]) -> BackupReaderExtensionState {
            let encodedCapabilities = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
            let blob = """
            {"autoUpdateSources":true,\
            "installedSources":[{"id":"s1","license":{"detectedAt":\(stamp),"kind":"mit"},\
            "name":"Fixture","runtimeCapabilities":[\(encodedCapabilities)],\
            "updatedAt":\(stamp),"version":"\(version)"}],\
            "lastAutoUpdate":\(stamp),\
            "repositories":[{"id":"r1","lastRefreshedAt":\(stamp),"name":"Repo"}],\
            "showMatureSources":false}
            """
            let state = BackupReaderExtensionState(
                metadataJSON: Data(blob.utf8),
                installedSourceCount: 1,
                showMatureSources: false,
                autoUpdateSources: true,
                lastAutoUpdate: Date(timeIntervalSince1970: TimeInterval(stamp))
            )
            XCTAssertNotNil(state.metadataJSON, "Fixture blob must survive metadata sanitization")
            return state
        }

        let seed = """
        {"version":"2.0","createdDate":0,"tmdbLanguage":"en-US","selectedAppearance":"system",
         "readerSelectedAppearance":"system","readerGlobalAppearanceEnabled":true,
         "enableSubtitlesByDefault":false,"defaultSubtitleLanguage":"eng",
         "playerSubtitleAppearanceEnabled":true,"preferredAutoAudioLanguage":"eng",
         "preferredAnimeAudioLanguage":"jpn","inAppPlayer":"none","showScheduleTab":true,
         "showLocalScheduleTime":true}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var backupA = try decoder.decode(BackupData.self, from: Data(seed.utf8))
        var backupB = try decoder.decode(BackupData.self, from: Data(seed.utf8))
        var backupC = try decoder.decode(BackupData.self, from: Data(seed.utf8))
        backupA.readerExtensionsState = readerState(
            stamp: 1_000,
            version: "1.0.0",
            capabilities: ["detail", "search", "filters", "pages", "latest"]
        )
        backupB.readerExtensionsState = readerState(
            stamp: 2_000,
            version: "1.0.0",
            capabilities: ["search", "latest", "detail", "filters", "pages"]
        )
        backupC.readerExtensionsState = readerState(
            stamp: 1_000,
            version: "1.0.1",
            capabilities: ["detail", "search", "filters", "pages", "latest"]
        )

        let encoder = JSONEncoder()
        let footprintA = ExperimentalCloudSnapshotFootprint(
            snapshot: backupA,
            encodedData: try encoder.encode(backupA)
        )
        let footprintB = ExperimentalCloudSnapshotFootprint(
            snapshot: backupB,
            encodedData: try encoder.encode(backupB)
        )
        let footprintC = ExperimentalCloudSnapshotFootprint(
            snapshot: backupC,
            encodedData: try encoder.encode(backupC)
        )

        XCTAssertNotNil(footprintA.contentDigest)
        XCTAssertEqual(footprintA.contentDigest, footprintB.contentDigest)
        XCTAssertEqual(
            footprintA.contentDigestExcludingCloudKitMediaState,
            footprintB.contentDigestExcludingCloudKitMediaState
        )
        XCTAssertFalse(footprintA.hasDifferentContent(than: footprintB))
        XCTAssertNotEqual(footprintA.contentDigest, footprintC.contentDigest)
        XCTAssertTrue(footprintA.hasDifferentContent(than: footprintC))
    }

    func testReaderPrivateCloudConfigurationRoundTripsAsBoundedOpaqueProfileData() throws {
        var snapshot = profileSnapshot(id: UUID(), name: "Reader Cloud")
        let payload = Data(#"{"credential":"private-cloud-value"}"#.utf8)
        snapshot.readerPrivateCloudConfigurationData = payload

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(BackupProfileSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.readerPrivateCloudConfigurationData, payload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(
            object["readerPrivateCloudConfigurationData"] as? String,
            payload.base64EncodedString()
        )
    }

    func testManualProfileSnapshotDoesNotInventReaderPrivateCloudConfiguration() throws {
        let snapshot = profileSnapshot(id: UUID(), name: "Manual Reader")
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertNil(snapshot.readerPrivateCloudConfigurationData)
        XCTAssertNil(object["readerPrivateCloudConfigurationData"])
    }

    func testReaderPrivateCloudConfigurationRejectsEmptyAndOversizedOpaqueData() throws {
        XCTAssertNil(
            BackupProfileSnapshot.boundedReaderPrivateCloudConfigurationData(Data())
        )
        var snapshot = profileSnapshot(id: UUID(), name: "Oversized Reader Cloud")
        snapshot.readerPrivateCloudConfigurationData = Data(
            repeating: 0x41,
            count: BackupProfileSnapshot.maximumReaderPrivateCloudConfigurationBytes + 1
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(BackupProfileSnapshot.self, from: encoded)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertNil(decoded.readerPrivateCloudConfigurationData)
        XCTAssertNil(object["readerPrivateCloudConfigurationData"])
        XCTAssertNil(
            BackupManager.sanitizedProfileSnapshotForRestore(snapshot)?
                .readerPrivateCloudConfigurationData
        )
    }

    func testMalformedReaderPrivateCloudConfigurationClaimsNoConfigurationAuthority() throws {
        let snapshot = profileSnapshot(id: UUID(), name: "Malformed Reader Cloud")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
                as? [String: Any]
        )
        object["readerPrivateCloudConfigurationData"] = ["unexpected": "object"]

        let decoded = try JSONDecoder().decode(
            BackupProfileSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.readerPrivateCloudConfigurationData)
        XCTAssertEqual(decoded.id, snapshot.id)
    }

    func testSnapshotPredatingReaderExtensionSyncClaimsNoAuthorityOverIt() throws {
        var snapshot = profileSnapshot(id: UUID(), name: "Before Reader Sync")
        snapshot.readerExtensionsState = try completePrivateCloudReaderState()
        snapshot.readerPrivateCloudConfigurationData = try JSONEncoder().encode(
            ReaderExtensionPrivateCloudConfiguration(profileID: snapshot.id, sources: [])
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
                as? [String: Any]
        )
        object.removeValue(forKey: "readerExtensionsState")
        object.removeValue(forKey: "readerPrivateCloudConfigurationData")
        object.removeValue(forKey: "aidokuState")

        let decoded = try JSONDecoder().decode(
            BackupProfileSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(
            decoded.readerExtensionsState,
            "every backup written before Reader Extension sync existed lacks the key entirely; inventing a state here would restore an empty roster over the destination's installed sources"
        )
        XCTAssertNil(decoded.readerPrivateCloudConfigurationData)
        XCTAssertNil(decoded.aidokuState)

        let sanitized = try XCTUnwrap(
            BackupManager.sanitizedProfileSnapshotForRestore(decoded)
        )
        XCTAssertNil(sanitized.readerExtensionsState)
        XCTAssertNil(sanitized.readerPrivateCloudConfigurationData)

        let legacyBackup = try decodeBackupObject(minimalBackupObject())
        XCTAssertNil(
            legacyBackup.readerExtensionsState,
            "a top-level backup predating the domain must decode without Reader authority so the restore site skips it and preserves local state"
        )
    }

    func testReaderExtensionMetadataEnvelopeRejectsExecutableFields() throws {
        let unsafe = try JSONSerialization.data(withJSONObject: [
            "repositories": [],
            "installedSources": [["id": "unsafe", "script": "alert(1)"]],
            "showMatureSources": false,
            "autoUpdateSources": true
        ])
        let state = BackupReaderExtensionState(
            metadataJSON: unsafe,
            installedSourceCount: 1,
            showMatureSources: false,
            autoUpdateSources: true,
            lastAutoUpdate: nil
        )
        XCTAssertNil(state.metadataJSON)
    }

    func testReaderExtensionMetadataEnvelopePreflightsDenseStructureBeforeFoundation() throws {
        let capPlusOne = Data(
            ("{\"installedSources\":[" + Array(repeating: "{}", count: 1_001)
                .joined(separator: ",") + "]}").utf8
        )
        XCTAssertLessThan(capPlusOne.count, BackupReaderExtensionState.maximumMetadataBytes)
        XCTAssertNil(BackupReaderExtensionState(
            metadataJSON: capPlusOne,
            installedSourceCount: 0,
            showMatureSources: false,
            autoUpdateSources: true,
            lastAutoUpdate: nil
        ).metadataJSON)

        let denseRow = "[" + Array(repeating: "0", count: 1_000).joined(separator: ",") + "]"
        let dense = Data(
            ("{\"repositories\":[" + Array(repeating: denseRow, count: 257)
                .joined(separator: ",") + "]}").utf8
        )
        XCTAssertLessThan(dense.count, BackupReaderExtensionState.maximumMetadataBytes)
        XCTAssertThrowsError(try ReaderExtensionJSONPreflight.validate(dense, limits: .init(
            maximumBytes: BackupReaderExtensionState.maximumMetadataBytes,
            maximumDepth: 18,
            maximumContainerEntries: BackupReaderExtensionState.maximumInstalledSources,
            maximumTopLevelEntries: 5,
            maximumTotalTokens: 256_000,
            maximumStringBytes: 64 * 1_024
        ))) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }
        XCTAssertNil(BackupReaderExtensionState(
            metadataJSON: dense,
            installedSourceCount: 0,
            showMatureSources: false,
            autoUpdateSources: true,
            lastAutoUpdate: nil
        ).metadataJSON)
    }

    func testReaderExtensionRestoreRollsBackGlobalControlsAfterVerificationFailure() throws {
        let suiteName = "BackupProfileSnapshotTests.reader-restore-rollback.\(UUID().uuidString)"
        let metadataStore = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { metadataStore.removePersistentDomain(forName: suiteName) }

        let global = UserDefaults.standard
        let keys = [
            ReaderExtensionPersistence.showMatureSourcesKey,
            ReaderExtensionPersistence.autoUpdateSourcesKey,
            ReaderExtensionPersistence.lastAutoUpdateKey
        ]
        let previousGlobal = keys.map { ($0, global.object(forKey: $0)) }
        defer {
            for (key, value) in previousGlobal {
                if let value { global.set(value, forKey: key) }
                else { global.removeObject(forKey: key) }
            }
        }

        let originalDate = Date(timeIntervalSince1970: 123)
        global.set(false, forKey: ReaderExtensionPersistence.showMatureSourcesKey)
        global.set(true, forKey: ReaderExtensionPersistence.autoUpdateSourcesKey)
        global.set(originalDate, forKey: ReaderExtensionPersistence.lastAutoUpdateKey)
        let originalRepositories = Data("original-repositories".utf8)
        metadataStore.set(originalRepositories, forKey: ReaderExtensionPersistence.repositoriesKey)

        let incoming = BackupReaderExtensionState(
            metadataJSON: nil,
            installedSourceCount: 0,
            showMatureSources: true,
            autoUpdateSources: false,
            lastAutoUpdate: Date(timeIntervalSince1970: 999)
        )
        XCTAssertThrowsError(
            try incoming.restore(
                to: metadataStore,
                preferenceStore: metadataStore,
                postRestoreVerification: {
                    throw NSError(domain: "ReaderExtensionRestoreTest", code: 1)
                }
            )
        )

        XCTAssertFalse(global.bool(forKey: ReaderExtensionPersistence.showMatureSourcesKey))
        XCTAssertTrue(global.bool(forKey: ReaderExtensionPersistence.autoUpdateSourcesKey))
        XCTAssertEqual(
            global.object(forKey: ReaderExtensionPersistence.lastAutoUpdateKey) as? Date,
            originalDate
        )
        XCTAssertEqual(
            metadataStore.data(forKey: ReaderExtensionPersistence.repositoriesKey),
            originalRepositories
        )
    }

    func testRejectedReaderBackupDoesNotPoisonVerifiedLocalStartupState() throws {
        let suiteName = "BackupProfileSnapshotTests.reader-rejected-import.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }

        let repositories = try JSONEncoder().encode([ReaderExtensionRepositoryRecord]())
        let sources = try JSONEncoder().encode([ReaderExtensionInstalledSource]())
        store.set(repositories, forKey: ReaderExtensionPersistence.repositoriesKey)
        store.set(sources, forKey: ReaderExtensionPersistence.installedSourcesKey)
        store.set(true, forKey: ReaderExtensionAidokuMigration.completionKey)
        store.removeObject(forKey: ReaderExtensionAidokuMigration.quarantineKey)

        // A nonzero declared count without a safe metadata envelope is an
        // untrusted/incomplete incoming backup and must be rejected.
        let rejected = BackupReaderExtensionState(
            metadataJSON: nil,
            installedSourceCount: 1,
            showMatureSources: false,
            autoUpdateSources: true,
            lastAutoUpdate: nil
        )
        XCTAssertFalse(BackupManager.restoreReaderExtensionStatePreservingLocalOnFailure(
            rejected,
            metadataStore: store,
            preferenceStore: store,
            context: "owned fixture"
        ))

        XCTAssertEqual(store.data(forKey: ReaderExtensionPersistence.repositoriesKey), repositories)
        XCTAssertEqual(store.data(forKey: ReaderExtensionPersistence.installedSourcesKey), sources)
        XCTAssertTrue(store.bool(forKey: ReaderExtensionAidokuMigration.completionKey))
        XCTAssertNil(store.object(forKey: ReaderExtensionAidokuMigration.quarantineKey))
        XCTAssertNoThrow(try ReaderExtensionAidokuMigration.validateRuntimeState(in: store))
        XCTAssertNoThrow(try ReaderExtensionAidokuMigration.migrateStoreIfNeeded(store))
        XCTAssertNil(store.object(forKey: ReaderExtensionAidokuMigration.quarantineKey))
    }

    func testCloudFootprintKeepsAidokuWireSlotForReaderExtensionCount() throws {
        let seed = """
        {"version":"2.0","createdDate":0,"tmdbLanguage":"en-US","selectedAppearance":"system",
         "readerSelectedAppearance":"system","readerGlobalAppearanceEnabled":true,
         "enableSubtitlesByDefault":false,"defaultSubtitleLanguage":"eng",
         "playerSubtitleAppearanceEnabled":true,"preferredAutoAudioLanguage":"eng",
         "preferredAnimeAudioLanguage":"jpn","inAppPlayer":"none","showScheduleTab":true,
         "showLocalScheduleTime":true}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var backup = try decoder.decode(BackupData.self, from: Data(seed.utf8))
        backup.readerExtensionsState = BackupReaderExtensionState.migratingLegacyAidoku(
            BackupAidokuState(
                sourceLists: [],
                installedSources: [
                    BackupAidokuInstalledSource(
                        id: "source.one",
                        name: "Source",
                        version: 1,
                        languages: ["en"],
                        iconPath: nil,
                        externalIconURL: nil,
                        contentRatingRawValue: 1,
                        sourceListURL: nil,
                        packageURL: nil,
                        isEnabled: true,
                        order: 0,
                        lastUpdated: nil,
                        lastError: nil,
                        packageDigest: nil,
                        payloadArchiveData: nil
                    )
                ],
                showMatureSources: false,
                autoUpdateSources: true,
                lastAutoUpdate: nil,
                sharedPayloads: nil
            )
        )
        let encoded = try JSONEncoder().encode(backup)
        let footprint = ExperimentalCloudSnapshotFootprint(snapshot: backup, encodedData: encoded)

        XCTAssertEqual(footprint.aidokuSources, 1)
    }

#if !os(tvOS)
    func testLocalAidokuMigrationIsProfileScopedMetadataOnlyAndIdempotent() throws {
        let suiteName = "BackupProfileSnapshotTests.reader-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = BackupAidokuInstalledSource(
            id: "source.one",
            name: "Source",
            version: 3,
            languages: ["en"],
            iconPath: "/private/icon.png",
            externalIconURL: nil,
            contentRatingRawValue: 1,
            sourceListURL: "https://legacy.example/list.json",
            packageURL: "https://provider.example/source.aix",
            isEnabled: false,
            order: 4,
            lastUpdated: nil,
            lastError: nil,
            packageDigest: String(repeating: "b", count: 64),
            payloadArchiveData: nil
        )
        defaults.set(
            try JSONEncoder().encode([source]),
            forKey: "kanzenAidokuInstalledSources"
        )
        defaults.set(true, forKey: "kanzenAidokuShowMatureSources")
        defaults.set(false, forKey: "kanzenAidokuAutoUpdateSources")

        try ReaderExtensionAidokuMigration.migrateStoreIfNeeded(defaults)
        try ReaderExtensionAidokuMigration.migrateStoreIfNeeded(defaults)

        XCTAssertTrue(defaults.bool(forKey: ReaderExtensionAidokuMigration.completionKey))
        XCTAssertNil(defaults.object(forKey: "kanzenAidokuInstalledSources"))
        XCTAssertEqual(ReaderExtensionAidokuMigration.legacySources(in: defaults).map(\.id), ["source.one"])
        let persisted = try ReaderExtensionPersistence.backupSnapshot(from: defaults)
        XCTAssertTrue(persisted.repositories.isEmpty)
        XCTAssertTrue(persisted.installedSources.isEmpty)
        XCTAssertTrue(persisted.showMatureSources)
        XCTAssertFalse(persisted.autoUpdateSources)

        let encodedLegacy = try XCTUnwrap(
            defaults.data(forKey: BackupReaderExtensionState.legacyAidokuSourcesStorageKey)
        )
        let text = String(decoding: encodedLegacy, as: UTF8.self)
        XCTAssertFalse(text.contains("source.aix"))
        XCTAssertFalse(text.contains("list.json"))
        XCTAssertFalse(text.contains("packageDigest"))
    }

    func testLocalAidokuMigrationAcceptsFiftyFourUniqueLanguages() throws {
        let suiteName = "BackupProfileSnapshotTests.reader-language-count.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let global = UserDefaults.standard
        let globalKeys = [
            ReaderExtensionPersistence.showMatureSourcesKey,
            ReaderExtensionPersistence.autoUpdateSourcesKey,
            ReaderExtensionPersistence.lastAutoUpdateKey
        ]
        let previousGlobal = globalKeys.map { ($0, global.object(forKey: $0)) }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            for (key, value) in previousGlobal {
                if let value { global.set(value, forKey: key) }
                else { global.removeObject(forKey: key) }
            }
        }

        let languages = (0..<54).map { String(format: "l%02d", $0) }
        var source = legacyAidokuInstalledSourceObject(id: "source.multilingual")
        source["languages"] = languages
        defaults.set(
            try JSONSerialization.data(withJSONObject: [source]),
            forKey: "kanzenAidokuInstalledSources"
        )
        defaults.set(
            ["detail": "previous quarantine"],
            forKey: ReaderExtensionAidokuMigration.quarantineKey
        )

        try ReaderExtensionAidokuMigration.migrateStoreIfNeeded(defaults)

        XCTAssertTrue(defaults.bool(forKey: ReaderExtensionAidokuMigration.completionKey))
        XCTAssertNil(defaults.object(forKey: ReaderExtensionAidokuMigration.quarantineKey))
        XCTAssertNil(defaults.object(forKey: "kanzenAidokuInstalledSources"))
        let legacy = try ReaderExtensionAidokuMigration.validatedLegacySources(in: defaults)
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy.first?.languages, languages.sorted())
        let runtime = try ReaderExtensionPersistence.backupSnapshot(from: defaults)
        XCTAssertTrue(runtime.repositories.isEmpty)
        XCTAssertTrue(runtime.installedSources.isEmpty)
    }

    func testUnreadableLocalAidokuMetadataRollsBackWithoutCleanup() throws {
        let suiteName = "BackupProfileSnapshotTests.reader-quarantine.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: "kanzenAidokuInstalledSources")

        XCTAssertThrowsError(try ReaderExtensionAidokuMigration.migrateStoreIfNeeded(defaults))
        XCTAssertEqual(defaults.data(forKey: "kanzenAidokuInstalledSources"), corrupt)
        XCTAssertFalse(defaults.bool(forKey: ReaderExtensionAidokuMigration.completionKey))
        XCTAssertNil(defaults.object(forKey: ReaderExtensionPersistence.installedSourcesKey))
    }

    func testLocalAidokuMigrationRejects513InstalledRowsWithoutCleanup() throws {
        let suiteName = "BackupProfileSnapshotTests.reader-row-limit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rows = (0...512).map {
            legacyAidokuInstalledSourceObject(id: "source.\($0)")
        }
        let original = try JSONSerialization.data(withJSONObject: rows)
        defaults.set(original, forKey: "kanzenAidokuInstalledSources")

        XCTAssertThrowsError(try ReaderExtensionAidokuMigration.migrateStoreIfNeeded(defaults))
        XCTAssertEqual(defaults.data(forKey: "kanzenAidokuInstalledSources"), original)
        XCTAssertFalse(defaults.bool(forKey: ReaderExtensionAidokuMigration.completionKey))
        XCTAssertNil(defaults.object(forKey: ReaderExtensionPersistence.installedSourcesKey))
    }

    func testLocalAidokuMigrationRejectsDuplicateInstalledSourceIdentities() throws {
        let suiteName = "BackupProfileSnapshotTests.reader-duplicate-source.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rows = [
            legacyAidokuInstalledSourceObject(id: "source.one"),
            legacyAidokuInstalledSourceObject(id: "source.one")
        ]
        let original = try JSONSerialization.data(withJSONObject: rows)
        defaults.set(original, forKey: "kanzenAidokuInstalledSources")

        XCTAssertThrowsError(try ReaderExtensionAidokuMigration.migrateStoreIfNeeded(defaults))
        XCTAssertEqual(defaults.data(forKey: "kanzenAidokuInstalledSources"), original)
        XCTAssertFalse(defaults.bool(forKey: ReaderExtensionAidokuMigration.completionKey))
    }

    func testLocalAidokuMigrationPreservesLegacyMissingFieldDefaults() throws {
        let suiteName = "BackupProfileSnapshotTests.reader-source-defaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONSerialization.data(withJSONObject: [["id": "source.defaults"]]),
            forKey: "kanzenAidokuInstalledSources"
        )

        try ReaderExtensionAidokuMigration.migrateStoreIfNeeded(defaults)

        let source = try XCTUnwrap(ReaderExtensionAidokuMigration.legacySources(in: defaults).first)
        XCTAssertEqual(source.id, "source.defaults")
        XCTAssertEqual(source.name, "source.defaults")
        XCTAssertEqual(source.version, 0)
        XCTAssertEqual(source.languages, [])
        XCTAssertEqual(source.contentRatingRawValue, 0)
        XCTAssertTrue(source.isEnabled)
        XCTAssertEqual(source.order, 0)
    }

    func testRuntimeSafetyGateRejectsCorruptCurrentReaderMetadataAndPreferenceOverlay() throws {
        let suiteName = "BackupProfileSnapshotTests.reader-current-state.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not-json".utf8), forKey: ReaderExtensionPersistence.installedSourcesKey)
        XCTAssertThrowsError(try ReaderExtensionAidokuMigration.validateRuntimeState(in: defaults))

        defaults.set(
            try JSONEncoder().encode([ReaderExtensionInstalledSource]()),
            forKey: ReaderExtensionPersistence.installedSourcesKey
        )
        defaults.set(
            try JSONEncoder().encode([ReaderExtensionRepositoryRecord]()),
            forKey: ReaderExtensionPersistence.repositoriesKey
        )
        defaults.set(Data("not-json".utf8), forKey: ReaderExtensionPersistence.preferenceOverlayKey)
        XCTAssertThrowsError(try ReaderExtensionAidokuMigration.validateRuntimeState(in: defaults))
    }

    func testSharedReaderMetadataCaptureStillReadsProfilePreferenceOverlay() throws {
        let metadataSuite = "BackupProfileSnapshotTests.reader-shared-metadata.\(UUID().uuidString)"
        let profileSuite = "BackupProfileSnapshotTests.reader-profile-overlay.\(UUID().uuidString)"
        let metadataStore = try XCTUnwrap(UserDefaults(suiteName: metadataSuite))
        let profileStore = try XCTUnwrap(UserDefaults(suiteName: profileSuite))
        defer {
            metadataStore.removePersistentDomain(forName: metadataSuite)
            profileStore.removePersistentDomain(forName: profileSuite)
        }
        metadataStore.set(
            try JSONEncoder().encode([ReaderExtensionRepositoryRecord]()),
            forKey: ReaderExtensionPersistence.repositoriesKey
        )
        metadataStore.set(
            try JSONEncoder().encode([ReaderExtensionInstalledSource]()),
            forKey: ReaderExtensionPersistence.installedSourcesKey
        )
        profileStore.set(
            Data("invalid-overlay".utf8),
            forKey: ReaderExtensionPersistence.preferenceOverlayKey
        )

        XCTAssertThrowsError(
            try BackupManager.captureReaderExtensionState(
                metadataStore: metadataStore,
                preferenceStore: profileStore
            )
        )
    }

    func testRuntimeRoutePreflightRejectsCorruptDownloadIndexShape() throws {
        XCTAssertThrowsError(
            try ReaderExtensionLegacyRouteRewriter.validate(
                Data("not-json".utf8),
                label: "Reader download index"
            )
        )
    }

    func testRuntimeRoutePreflightRejectsDenseStructuralFlood() throws {
        let denseRow = "[" + String(repeating: "0,", count: 20_255) + "0]"
        let document = "[" + Array(repeating: denseRow, count: 50).joined(separator: ",") + "]"
        let data = Data(document.utf8)
        XCTAssertLessThan(data.count, 32 * 1_024 * 1_024)

        XCTAssertThrowsError(
            try ReaderExtensionLegacyRouteRewriter.validate(
                data,
                label: "dense Reader metadata"
            )
        )
    }

    func testLegacyRouteRewriterPreservesStableIdentityAndDownloadMetadata() throws {
        let legacyStableKey = "aidoku:source.one:/series/42"
        let input = try JSONSerialization.data(withJSONObject: [[
            "title": "Synthetic title",
            "routeKey": legacyStableKey,
            "route": [
                "kind": "aidoku",
                "sourceId": "source.one",
                "mangaKey": "/series/42"
            ],
            "provider": [
                "kind": "aidoku",
                "sourceId": "source.one",
                "mangaKey": "/series/42",
                "isNovel": false,
                "chapterParams": NSNull()
            ]
        ]])
        let sourceID = ReaderExtensionSourceID(rawValue: String(repeating: "a", count: 64))
        let result = try ReaderExtensionLegacyRouteRewriter.rewrite(
            input,
            mapping: .init(
                legacySourceID: "source.one",
                installedSourceID: sourceID,
                itemKeys: ["/series/42": "canonical-42"],
                mediaType: .manga
            )
        )

        XCTAssertEqual(result.routeCount, 1)
        XCTAssertEqual(result.providerCount, 1)
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.data) as? [[String: Any]]
        )
        let row = try XCTUnwrap(rows.first)
        let route = try XCTUnwrap(row["route"] as? [String: Any])
        XCTAssertEqual(route["kind"] as? String, "readerExtension")
        XCTAssertEqual(route["source"] as? String, sourceID.rawValue)
        XCTAssertEqual(route["itemKey"] as? String, "canonical-42")
        XCTAssertEqual(route["legacyStableKey"] as? String, legacyStableKey)
        XCTAssertEqual(row["routeKey"] as? String, legacyStableKey)
        let provider = try XCTUnwrap(row["provider"] as? [String: Any])
        XCTAssertEqual(provider["kind"] as? String, "readerExtension")
        XCTAssertEqual(provider["sourceId"] as? String, sourceID.rawValue)
        XCTAssertEqual(provider["mangaKey"] as? String, "canonical-42")

        XCTAssertTrue(
            try ReaderExtensionLegacyRouteRewriter.references(
                in: result.data,
                legacySourceID: "source.one"
            ).isEmpty
        )
    }

    func testLegacyRouteRewriterRequiresEveryCanonicalItemMapping() throws {
        let input = try JSONSerialization.data(withJSONObject: [
            "route": [
                "kind": "aidoku",
                "sourceId": "source.one",
                "mangaKey": "missing"
            ]
        ])
        XCTAssertThrowsError(
            try ReaderExtensionLegacyRouteRewriter.rewrite(
                input,
                mapping: .init(
                    legacySourceID: "source.one",
                    installedSourceID: ReaderExtensionSourceID(
                        rawValue: String(repeating: "b", count: 64)
                    ),
                    itemKeys: ["different": "canonical"],
                    mediaType: .manga
                )
            )
        )
    }

    func testLegacyRouteRewriterRetainsUnmappedRoutesByteForByteWhenAskedTo() throws {
        let input = try JSONSerialization.data(withJSONObject: [
            [
                "title": "Still on the new source",
                "route": [
                    "kind": "aidoku",
                    "sourceId": "source.one",
                    "mangaKey": "/series/42"
                ]
            ],
            [
                "title": "Gone from the new source",
                "route": [
                    "kind": "aidoku",
                    "sourceId": "source.one",
                    "mangaKey": "/series/99"
                ],
                "provider": [
                    "kind": "aidoku",
                    "sourceId": "source.one",
                    "mangaKey": "/series/99",
                    "isNovel": false
                ]
            ]
        ])
        let sourceID = ReaderExtensionSourceID(rawValue: String(repeating: "d", count: 64))
        let result = try ReaderExtensionLegacyRouteRewriter.rewrite(
            input,
            mapping: .init(
                legacySourceID: "source.one",
                installedSourceID: sourceID,
                itemKeys: ["/series/42": "canonical-42"],
                mediaType: .manga,
                unresolvedItems: .retain
            )
        )

        XCTAssertEqual(result.routeCount, 1)
        XCTAssertEqual(result.providerCount, 0)
        XCTAssertEqual(result.retainedCount, 2, "one route position and one provider position")

        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.data) as? [[String: Any]]
        )
        let migrated = try XCTUnwrap(rows.first { $0["title"] as? String == "Still on the new source" })
        let migratedRoute = try XCTUnwrap(migrated["route"] as? [String: Any])
        XCTAssertEqual(migratedRoute["kind"] as? String, "readerExtension")
        XCTAssertEqual(migratedRoute["itemKey"] as? String, "canonical-42")

        let kept = try XCTUnwrap(rows.first { $0["title"] as? String == "Gone from the new source" })
        let keptRoute = try XCTUnwrap(kept["route"] as? [String: Any])
        XCTAssertEqual(keptRoute["kind"] as? String, "aidoku")
        XCTAssertEqual(keptRoute["sourceId"] as? String, "source.one")
        XCTAssertEqual(keptRoute["mangaKey"] as? String, "/series/99")
        let keptProvider = try XCTUnwrap(kept["provider"] as? [String: Any])
        XCTAssertEqual(keptProvider["kind"] as? String, "aidoku")
        XCTAssertEqual(keptProvider["mangaKey"] as? String, "/series/99")

        let survivors = try ReaderExtensionLegacyRouteRewriter.references(
            in: result.data,
            legacySourceID: "source.one"
        ).map(\.legacyItemKey)
        XCTAssertEqual(
            Set(survivors),
            ["/series/99"],
            "only the title with no verified replacement may survive as a legacy route"
        )
    }

    func testRetainingUnresolvedRoutesStillRefusesACredentialBearingReplacementKey() throws {
        let input = try JSONSerialization.data(withJSONObject: [
            "route": [
                "kind": "aidoku",
                "sourceId": "source.one",
                "mangaKey": "/legacy/42"
            ]
        ])
        let result = try ReaderExtensionLegacyRouteRewriter.rewrite(
            input,
            mapping: .init(
                legacySourceID: "source.one",
                installedSourceID: ReaderExtensionSourceID(rawValue: String(repeating: "e", count: 64)),
                itemKeys: ["/legacy/42": "/title/42?access_token=owned-secret"],
                mediaType: .manga,
                unresolvedItems: .retain
            )
        )

        XCTAssertEqual(result.routeCount, 0)
        XCTAssertEqual(result.retainedCount, 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        )
        let route = try XCTUnwrap(object["route"] as? [String: Any])
        XCTAssertEqual(
            route["kind"] as? String,
            "aidoku",
            "a rejected replacement key must leave the original route alone, never write the credential"
        )
        XCTAssertNil(route["itemKey"])
    }

    func testRequiringEveryMappingIsStillTheDefaultForTheRewriter() throws {
        let input = try JSONSerialization.data(withJSONObject: [
            "route": [
                "kind": "aidoku",
                "sourceId": "source.one",
                "mangaKey": "unmapped"
            ]
        ])
        let mapping = ReaderExtensionLegacyRouteRewriter.Mapping(
            legacySourceID: "source.one",
            installedSourceID: ReaderExtensionSourceID(rawValue: String(repeating: "f", count: 64)),
            itemKeys: ["other": "canonical"],
            mediaType: .manga
        )
        XCTAssertEqual(mapping.unresolvedItems, .require)
        XCTAssertThrowsError(try ReaderExtensionLegacyRouteRewriter.rewrite(input, mapping: mapping))
    }

    func testLegacyRouteRewriterRejectsCredentialBearingReplacementItemKeys() throws {
        let input = try JSONSerialization.data(withJSONObject: [
            "route": [
                "kind": "aidoku",
                "sourceId": "source.one",
                "mangaKey": "/legacy/42"
            ]
        ])
        let sourceID = ReaderExtensionSourceID(rawValue: String(repeating: "c", count: 64))

        for unsafeKey in [
            "/title/42?access_token=owned-secret",
            "/title/42?x-api-key=owned-secret",
            "https://user:password@example.invalid/title/42"
        ] {
            XCTAssertThrowsError(
                try ReaderExtensionLegacyRouteRewriter.rewrite(
                    input,
                    mapping: .init(
                        legacySourceID: "source.one",
                        installedSourceID: sourceID,
                        itemKeys: ["/legacy/42": unsafeKey],
                        mediaType: .manga
                    )
                ),
                "Reconnect must never persist provider credentials in a replacement item key"
            )
        }

        let safeKey = "/title/42?number=42&volume=7"
        let rewritten = try ReaderExtensionLegacyRouteRewriter.rewrite(
            input,
            mapping: .init(
                legacySourceID: "source.one",
                installedSourceID: sourceID,
                itemKeys: ["/legacy/42": safeKey],
                mediaType: .manga
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rewritten.data) as? [String: Any]
        )
        let route = try XCTUnwrap(object["route"] as? [String: Any])
        XCTAssertEqual(route["itemKey"] as? String, safeKey)
        XCTAssertEqual(route["legacyStableKey"] as? String, "aidoku:source.one:/legacy/42")
    }

    func testReconnectJournalRecoversMixedPartialWritesAndIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reader-reconnect-journal-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.plist")
        let firstLocation = ReaderExtensionReconnectTransactionJournal.Location
            .standardDefaults(key: "synthetic.first")
        let secondLocation = ReaderExtensionReconnectTransactionJournal.Location
            .metadataDefaults(scope: "primary", key: "synthetic.second")
        let firstOriginal = ReaderExtensionReconnectTransactionJournal.Value.data(
            Data("first-original".utf8)
        )
        let firstReplacement = ReaderExtensionReconnectTransactionJournal.Value.data(
            Data("first-replacement".utf8)
        )
        let secondOriginal = ReaderExtensionReconnectTransactionJournal.Value.string(
            "second-original"
        )
        let secondReplacement = ReaderExtensionReconnectTransactionJournal.Value.string(
            "second-replacement"
        )
        let entries = [
            ReaderExtensionReconnectTransactionJournal.Entry(
                location: firstLocation,
                original: firstOriginal,
                replacement: firstReplacement
            ),
            ReaderExtensionReconnectTransactionJournal.Entry(
                location: secondLocation,
                original: secondOriginal,
                replacement: secondReplacement
            )
        ]
        try ReaderExtensionReconnectTransactionJournal.prepare(
            entries: entries,
            at: journalURL
        )

        // Simulate a crash after the first store changed but before the second did.
        var state: [ReaderExtensionReconnectTransactionJournal.Location:
            ReaderExtensionReconnectTransactionJournal.Value] = [
                firstLocation: firstReplacement,
                secondLocation: secondOriginal
            ]
        XCTAssertTrue(try ReaderExtensionReconnectTransactionJournal.recoverIfPresent(
            at: journalURL,
            read: { try XCTUnwrap(state[$0]) },
            apply: { value, location in state[location] = value }
        ))
        XCTAssertEqual(state[firstLocation], firstOriginal)
        XCTAssertEqual(state[secondLocation], secondOriginal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertFalse(try ReaderExtensionReconnectTransactionJournal.recoverIfPresent(
            at: journalURL,
            read: { try XCTUnwrap(state[$0]) },
            apply: { value, location in state[location] = value }
        ))
    }

    func testReconnectJournalRollsCommittedTransactionForwardAfterTargetWriteLoss() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reader-reconnect-committed-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.plist")
        let firstLocation = ReaderExtensionReconnectTransactionJournal.Location
            .standardDefaults(key: "synthetic.committed.first")
        let secondLocation = ReaderExtensionReconnectTransactionJournal.Location
            .file(path: directory.appendingPathComponent("second.json").path)
        let firstOriginal = ReaderExtensionReconnectTransactionJournal.Value.string("first-old")
        let firstReplacement = ReaderExtensionReconnectTransactionJournal.Value.string("first-new")
        let secondOriginal = ReaderExtensionReconnectTransactionJournal.Value.data(
            Data("second-old".utf8)
        )
        let secondReplacement = ReaderExtensionReconnectTransactionJournal.Value.data(
            Data("second-new".utf8)
        )
        let entries = [
            ReaderExtensionReconnectTransactionJournal.Entry(
                location: firstLocation,
                original: firstOriginal,
                replacement: firstReplacement
            ),
            ReaderExtensionReconnectTransactionJournal.Entry(
                location: secondLocation,
                original: secondOriginal,
                replacement: secondReplacement
            )
        ]
        try ReaderExtensionReconnectTransactionJournal.prepare(entries: entries, at: journalURL)
        try ReaderExtensionReconnectTransactionJournal.markCommitted(at: journalURL)

        // Simulate a power loss after the commit marker reached disk while one target's
        // buffered replacement did not. A committed journal must finish, never roll back.
        var state: [ReaderExtensionReconnectTransactionJournal.Location:
            ReaderExtensionReconnectTransactionJournal.Value] = [
                firstLocation: firstReplacement,
                secondLocation: secondOriginal
            ]
        XCTAssertTrue(try ReaderExtensionReconnectTransactionJournal.recoverIfPresent(
            at: journalURL,
            read: { try XCTUnwrap(state[$0]) },
            apply: { value, location in state[location] = value }
        ))
        XCTAssertEqual(state[firstLocation], firstReplacement)
        XCTAssertEqual(state[secondLocation], secondReplacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testCommittedReconnectRecoveryRemainsRetryableAfterSecondCrash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reader-reconnect-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.plist")
        let firstLocation = ReaderExtensionReconnectTransactionJournal.Location
            .standardDefaults(key: "synthetic.retry.first")
        let secondLocation = ReaderExtensionReconnectTransactionJournal.Location
            .standardDefaults(key: "synthetic.retry.second")
        let entries = [firstLocation, secondLocation].enumerated().map { index, location in
            ReaderExtensionReconnectTransactionJournal.Entry(
                location: location,
                original: .string("old-\(index)"),
                replacement: .string("new-\(index)")
            )
        }
        try ReaderExtensionReconnectTransactionJournal.prepare(entries: entries, at: journalURL)
        try ReaderExtensionReconnectTransactionJournal.markCommitted(at: journalURL)
        var state = Dictionary(uniqueKeysWithValues: entries.map { ($0.location, $0.original) })
        var appliedCount = 0

        XCTAssertThrowsError(try ReaderExtensionReconnectTransactionJournal.recoverIfPresent(
            at: journalURL,
            read: { try XCTUnwrap(state[$0]) },
            apply: { value, location in
                appliedCount += 1
                if appliedCount == 2 {
                    throw NSError(domain: "SyntheticReconnectCrash", code: 1)
                }
                state[location] = value
            }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        XCTAssertTrue(try ReaderExtensionReconnectTransactionJournal.recoverIfPresent(
            at: journalURL,
            read: { try XCTUnwrap(state[$0]) },
            apply: { value, location in state[location] = value }
        ))
        XCTAssertEqual(state[firstLocation], entries[0].replacement)
        XCTAssertEqual(state[secondLocation], entries[1].replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testReconnectJournalRefusesToOverwriteAnUnrelatedThirdState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reader-reconnect-conflict-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.plist")
        let location = ReaderExtensionReconnectTransactionJournal.Location
            .standardDefaults(key: "synthetic.conflict")
        let original = ReaderExtensionReconnectTransactionJournal.Value.string("original")
        let replacement = ReaderExtensionReconnectTransactionJournal.Value.string("replacement")
        try ReaderExtensionReconnectTransactionJournal.prepare(
            entries: [.init(location: location, original: original, replacement: replacement)],
            at: journalURL
        )
        var current = ReaderExtensionReconnectTransactionJournal.Value.string("third-state")
        XCTAssertThrowsError(try ReaderExtensionReconnectTransactionJournal.recoverIfPresent(
            at: journalURL,
            read: { _ in current },
            apply: { value, _ in current = value }
        ))
        XCTAssertEqual(current, .string("third-state"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testReconnectJournalRefusesThirdStateIntroducedAfterPreflight() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reader-reconnect-race-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.plist")
        let location = ReaderExtensionReconnectTransactionJournal.Location
            .standardDefaults(key: "synthetic.concurrent")
        let original = ReaderExtensionReconnectTransactionJournal.Value.string("original")
        let replacement = ReaderExtensionReconnectTransactionJournal.Value.string("replacement")
        let thirdState = ReaderExtensionReconnectTransactionJournal.Value.string("concurrent")
        try ReaderExtensionReconnectTransactionJournal.prepare(
            entries: [.init(location: location, original: original, replacement: replacement)],
            at: journalURL
        )
        var current = replacement
        var readCount = 0
        var applyWasCalled = false
        XCTAssertThrowsError(try ReaderExtensionReconnectTransactionJournal.recoverIfPresent(
            at: journalURL,
            read: { _ in
                readCount += 1
                if readCount == 2 { current = thirdState }
                return current
            },
            apply: { value, _ in
                applyWasCalled = true
                current = value
            }
        ))
        XCTAssertFalse(applyWasCalled)
        XCTAssertEqual(current, thirdState)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testReplacementChapterKeyRequiresOneExactIdentityAndMatchingLegacyTitle() throws {
        let sourceID = ReaderExtensionSourceID(rawValue: String(repeating: "d", count: 64))
        let route = MangaContentRoute.readerExtension(
            source: sourceID,
            itemKey: "canonical-item",
            legacyStableKey: "aidoku:source.one:/series/42"
        )
        let item = ReaderDownloadItem(
            id: "download",
            route: route,
            routeKey: route.stableKey,
            mangaId: -42,
            mangaTitle: "Synthetic title",
            coverURL: nil,
            sourceName: "Synthetic source",
            format: "Manga",
            chapterNumber: "Chapter 12",
            chapterTitle: "Chapter 12",
            chapterKey: "c12",
            contentRating: 1,
            provider: ReaderDownloadProvider(
                kind: .readerExtension,
                sourceId: sourceID.rawValue,
                mangaKey: "canonical-item",
                moduleUUID: nil,
                contentParams: nil,
                isNovel: false,
                chapterParams: nil
            ),
            status: .paused,
            progress: 0.5,
            completedPages: 2,
            totalPages: 4,
            downloadedBytes: 1_024,
            error: nil,
            dateAdded: Date(timeIntervalSince1970: 1),
            dateCompleted: nil,
            legacyResumeStatus: .paused
        )
        func chapter(key: String, title: String) -> ReaderExtensionChapter {
            ReaderExtensionChapter(
                key: key,
                title: title,
                url: nil,
                uploadedAt: nil,
                scanlator: nil,
                isFiller: false,
                thumbnailURL: nil,
                summary: nil
            )
        }

        XCTAssertEqual(
            ReaderDownloadManager.verifiedReplacementChapterKey(
                for: item,
                candidates: [
                    chapter(key: "replacement-12", title: "  CHAPTER   12 "),
                    chapter(key: "replacement-13", title: "Chapter 13")
                ]
            ),
            "replacement-12"
        )
        let splitTitle = ReaderDownloadItem(
            id: item.id,
            route: item.route,
            routeKey: item.routeKey,
            mangaId: item.mangaId,
            mangaTitle: item.mangaTitle,
            coverURL: item.coverURL,
            sourceName: item.sourceName,
            format: item.format,
            chapterNumber: "12",
            chapterTitle: "The Beginning",
            chapterKey: ChapterIdentityNormalizer.key(for: "12"),
            contentRating: item.contentRating,
            provider: item.provider,
            status: item.status,
            progress: item.progress,
            completedPages: item.completedPages,
            totalPages: item.totalPages,
            downloadedBytes: item.downloadedBytes,
            error: item.error,
            dateAdded: item.dateAdded,
            dateCompleted: item.dateCompleted,
            legacyResumeStatus: item.legacyResumeStatus
        )
        XCTAssertEqual(
            ReaderDownloadManager.verifiedReplacementChapterKey(
                for: splitTitle,
                candidates: [
                    chapter(
                        key: "replacement-split-12",
                        title: "Chapter 12 — The Beginning"
                    ),
                    chapter(key: "replacement-13", title: "Chapter 13 — Later")
                ]
            ),
            "replacement-split-12",
            "split legacy number/title metadata must match the same combined replacement title"
        )
        var queued = item
        queued.status = .failed
        queued.legacyResumeStatus = .queued
        XCTAssertTrue(ReaderDownloadManager.applyVerifiedReplacementChapterKey(
            "replacement-12",
            to: &queued
        ))
        XCTAssertEqual(queued.provider.chapterParams, "replacement-12")
        XCTAssertEqual(queued.status, .queued)
        XCTAssertNil(queued.legacyResumeStatus)

        var paused = item
        paused.status = .failed
        paused.legacyResumeStatus = .paused
        XCTAssertTrue(ReaderDownloadManager.applyVerifiedReplacementChapterKey(
            "replacement-12",
            to: &paused
        ))
        XCTAssertEqual(paused.status, .paused)

        var failed = item
        failed.status = .failed
        failed.legacyResumeStatus = .failed
        XCTAssertTrue(ReaderDownloadManager.applyVerifiedReplacementChapterKey(
            "replacement-12",
            to: &failed
        ))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertNotNil(failed.provider.chapterParams, "failed rows must become retryable")
        XCTAssertNil(ReaderDownloadManager.verifiedReplacementChapterKey(
            for: item,
            candidates: [
                chapter(key: "duplicate-a", title: "Chapter 12"),
                chapter(key: "duplicate-b", title: "12")
            ]
        ), "duplicate normalized identities must never pick the first chapter")
        XCTAssertNil(ReaderDownloadManager.verifiedReplacementChapterKey(
            for: item,
            candidates: [chapter(key: "wrong-title", title: "12")]
        ), "a nonempty persisted title must agree after normalization")
        XCTAssertNil(ReaderDownloadManager.verifiedReplacementChapterKey(
            for: splitTitle,
            candidates: [
                chapter(key: "wrong-split-title", title: "Chapter 12 — The Ending")
            ]
        ), "a different descriptive title must not hydrate the legacy download")
        XCTAssertNil(ReaderDownloadManager.verifiedReplacementChapterKey(
            for: item,
            candidates: [
                chapter(
                    key: "/chapter/12?access_token=owned-secret",
                    title: "Chapter 12"
                )
            ]
        ), "reconnect hydration must not persist provider authorization data")
        var credentialBearing = item
        credentialBearing.status = .failed
        credentialBearing.legacyResumeStatus = .queued
        XCTAssertFalse(ReaderDownloadManager.applyVerifiedReplacementChapterKey(
            "https://user:password@provider.example/chapter/12",
            to: &credentialBearing
        ))
        XCTAssertNil(credentialBearing.provider.chapterParams)
        XCTAssertEqual(
            ReaderDownloadManager.verifiedReplacementChapterKey(
                for: item,
                candidates: [
                    chapter(
                        key: "/chapter/12?number=12&volume=2",
                        title: "Chapter 12"
                    )
                ]
            ),
            "/chapter/12?number=12&volume=2"
        )
        XCTAssertNil(ReaderDownloadManager.verifiedReplacementChapterKey(
            for: splitTitle,
            candidates: [
                chapter(key: "duplicate-split-a", title: "Chapter 12 — The Beginning"),
                chapter(key: "duplicate-split-b", title: "12 — The Beginning")
            ]
        ), "title agreement must never disambiguate duplicate chapter identities")
        var completed = item
        completed.status = .completed
        XCTAssertNil(ReaderDownloadManager.verifiedReplacementChapterKey(
            for: completed,
            candidates: [chapter(key: "replacement-12", title: "Chapter 12")]
        ), "completed offline downloads must never be rewritten for resumability")
        XCTAssertFalse(ReaderDownloadManager.applyVerifiedReplacementChapterKey(
            "replacement-12",
            to: &completed
        ))
        XCTAssertNil(completed.provider.chapterParams)
    }

    func testAutomaticReconnectCandidateRequiresIDHostAndLanguageNotTitle() throws {
        let legacyJSON = try JSONSerialization.data(withJSONObject: [
            "id": "source.one",
            "name": "A shared display name",
            "version": 1,
            "languages": ["en-US"],
            "originHost": "provider.example",
            "contentRatingRawValue": 0,
            "isEnabled": true,
            "order": 0
        ])
        let legacy = try JSONDecoder().decode(
            BackupLegacyAidokuSourceMetadata.self,
            from: legacyJSON
        )
        let repositoryURL = try XCTUnwrap(URL(string: "https://repo.example/index.json"))
        let license = ReaderExtensionLicense(
            kind: .apache2,
            name: "Apache-2.0",
            url: nil,
            textSHA256: nil,
            detectedAt: Date(timeIntervalSince1970: 1)
        )
        func installed(upstreamID: String, baseHost: String, language: String) throws
            -> ReaderExtensionInstalledSource {
            let catalog = ReaderExtensionCatalogSource(
                id: ReaderExtensionSourceID(
                    repositoryURL: repositoryURL,
                    upstreamID: upstreamID,
                    language: language,
                    mediaType: .manga
                ),
                upstreamID: upstreamID,
                repositoryID: "repo",
                repositoryURL: repositoryURL,
                name: "A shared display name",
                baseURL: try XCTUnwrap(URL(string: "https://\(baseHost)")),
                apiURL: nil,
                language: language,
                mediaType: .manga,
                implementation: .madara,
                sourceCodeURL: nil,
                version: "1",
                maturity: .safe,
                hasCloudflare: false,
                dateFormat: nil,
                dateFormatLocale: nil,
                additionalParameters: nil,
                notes: nil,
                license: license
            )
            return ReaderExtensionInstalledSource(catalog: catalog, sortIndex: 0)
        }
        let exact = try installed(
            upstreamID: "source.one",
            baseHost: "provider.example",
            language: "en"
        )
        let titleOnly = try installed(
            upstreamID: "different",
            baseHost: "different.example",
            language: "en"
        )

        let unique = ReaderExtensionLegacyReconnectManager.uniqueStrongCandidates(
            legacySources: [legacy],
            installedSources: [exact, titleOnly]
        )
        XCTAssertEqual(unique.map(\.installedSource.id), [exact.id])
    }

    func testLegacyAidokuMetadataDecodeIsBoundedAndStoredPreflightFailsClosed() throws {
        func record(
            id: String = "source.one",
            name: String = "Owned legacy source",
            version: Int = 1,
            languages: [String] = ["EN-us"],
            originHost: Any = "Provider.Example.",
            rating: Int = 1,
            order: Int = 2
        ) -> [String: Any] {
            [
                "id": id,
                "name": name,
                "version": version,
                "languages": languages,
                "originHost": originHost,
                "contentRatingRawValue": rating,
                "isEnabled": true,
                "order": order
            ]
        }

        let validData = try JSONSerialization.data(withJSONObject: record())
        let valid = try JSONDecoder().decode(
            BackupLegacyAidokuSourceMetadata.self,
            from: validData
        )
        XCTAssertEqual(valid.originHost, "provider.example")
        XCTAssertEqual(valid.languages, ["en-us"])

        let invalidRecords: [[String: Any]] = [
            record(id: "../source"),
            record(name: String(repeating: "n", count: 513)),
            record(name: "bad\u{0000}name"),
            record(version: -1),
            record(languages: Array(repeating: "en", count: 129)),
            record(languages: ["../../en"]),
            record(originHost: "provider.example/path"),
            record(originHost: "user@provider.example"),
            record(rating: 4),
            record(order: 10_001)
        ]
        for invalid in invalidRecords {
            let data = try JSONSerialization.data(withJSONObject: invalid)
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    BackupLegacyAidokuSourceMetadata.self,
                    from: data
                )
            )
        }

        let tooManyRows = (0...BackupReaderExtensionState.maximumLegacySources).map {
            record(id: "source.\($0)", order: min($0, 10_000))
        }
        let oversizedEnvelope = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": BackupReaderExtensionState.currentSchemaVersion,
            "installedSourceCount": 0,
            "legacyAidokuSources": tooManyRows,
            "showMatureSources": false,
            "autoUpdateSources": true
        ])
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BackupReaderExtensionState.self,
                from: oversizedEnvelope
            )
        )
        XCTAssertThrowsError(
            try ReaderExtensionAidokuMigration.validatedLegacySources(
                data: try JSONSerialization.data(withJSONObject: tooManyRows)
            )
        )

        let duplicateStoreData = try JSONSerialization.data(
            withJSONObject: [record(), record()]
        )
        XCTAssertThrowsError(
            try ReaderExtensionAidokuMigration.validatedLegacySources(
                data: duplicateStoreData
            )
        )

        let suiteName = "BackupProfileSnapshotTests.invalid-legacy.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        store.set(
            try JSONSerialization.data(withJSONObject: [record(id: "bad:id")]),
            forKey: BackupReaderExtensionState.legacyAidokuSourcesStorageKey
        )
        XCTAssertThrowsError(
            try ReaderExtensionAidokuMigration.validatedLegacySources(in: store)
        )
        XCTAssertTrue(
            store.data(forKey: BackupReaderExtensionState.legacyAidokuSourcesStorageKey) != nil,
            "invalid reconnect metadata must remain intact for repair instead of being normalized away"
        )
    }

    func testPortableReaderRestoreRetainsOnlyMatchingLocalVerifiedRuntime() throws {
        let localSuite = "BackupProfileSnapshotTests.reader-local-runtime.\(UUID().uuidString)"
        let newDeviceSuite = "BackupProfileSnapshotTests.reader-new-device.\(UUID().uuidString)"
        let changedSuite = "BackupProfileSnapshotTests.reader-changed-runtime.\(UUID().uuidString)"
        let localStore = try XCTUnwrap(UserDefaults(suiteName: localSuite))
        let newDeviceStore = try XCTUnwrap(UserDefaults(suiteName: newDeviceSuite))
        let changedStore = try XCTUnwrap(UserDefaults(suiteName: changedSuite))
        defer {
            localStore.removePersistentDomain(forName: localSuite)
            newDeviceStore.removePersistentDomain(forName: newDeviceSuite)
            changedStore.removePersistentDomain(forName: changedSuite)
        }

        let global = UserDefaults.standard
        let globalKeys = [
            ReaderExtensionPersistence.showMatureSourcesKey,
            ReaderExtensionPersistence.autoUpdateSourcesKey,
            ReaderExtensionPersistence.lastAutoUpdateKey
        ]
        let priorGlobal = globalKeys.map { ($0, global.object(forKey: $0)) }
        defer {
            for (key, value) in priorGlobal {
                if let value { global.set(value, forKey: key) }
                else { global.removeObject(forKey: key) }
            }
        }

        let repositoryURL = try XCTUnwrap(URL(string: "https://repo.example/index.json"))
        let license = ReaderExtensionLicense(
            kind: .apache2,
            name: "Apache-2.0",
            url: nil,
            textSHA256: String(repeating: "a", count: 64),
            detectedAt: Date(timeIntervalSince1970: 1)
        )
        let repository = ReaderExtensionRepositoryRecord(
            indexURL: repositoryURL,
            name: "Owned fixture",
            license: license
        )
        let catalog = ReaderExtensionCatalogSource(
            id: ReaderExtensionSourceID(
                repositoryURL: repositoryURL,
                upstreamID: "owned-native",
                language: "en",
                mediaType: .manga
            ),
            upstreamID: "owned-native",
            repositoryID: repository.id,
            repositoryURL: repositoryURL,
            name: "Owned native fixture",
            baseURL: try XCTUnwrap(URL(string: "https://provider.example")),
            apiURL: nil,
            language: "en",
            mediaType: .manga,
            implementation: .madara,
            sourceCodeURL: nil,
            version: "1.0.0",
            maturity: .safe,
            hasCloudflare: false,
            dateFormat: nil,
            dateFormatLocale: nil,
            additionalParameters: "owned-parser-config",
            notes: nil,
            license: license
        )
        var local = ReaderExtensionInstalledSource(catalog: catalog, sortIndex: 0)
        local.runtimeCapabilities = [.popular, .search, .detail, .pages]
        local.preferenceSchemaFingerprint = String(repeating: "b", count: 64)
        local.declaredDomains = ["provider.example"]

        try ReaderExtensionPersistence.persist(
            repositories: [repository],
            installedSources: [local],
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: localStore,
            preferenceStore: localStore
        )
        let state = try BackupReaderExtensionState(snapshot: ReaderExtensionBackupSnapshot(
            repositories: [repository],
            installedSources: [local],
            showMatureSources: false,
            autoUpdateSources: true,
            lastAutoUpdate: nil
        ))
        XCTAssertTrue(try XCTUnwrap(state.runtimeSnapshot().installedSources.first).requiresReinstall)

        try state.restore(to: localStore, preferenceStore: localStore)
        let retained = try XCTUnwrap(
            ReaderExtensionPersistence.loadInstalledSources(from: localStore).first
        )
        XCTAssertFalse(retained.requiresReinstall)
        XCTAssertTrue(retained.isRunnable)
        XCTAssertEqual(retained.declaredDomains, Set(["provider.example"]))

        try state.restore(to: newDeviceStore, preferenceStore: newDeviceStore)
        let newDevice = try XCTUnwrap(
            ReaderExtensionPersistence.loadInstalledSources(from: newDeviceStore).first
        )
        XCTAssertTrue(newDevice.requiresReinstall)
        XCTAssertFalse(newDevice.isRunnable)

        try ReaderExtensionPersistence.persist(
            repositories: [repository],
            installedSources: [local],
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: changedStore,
            preferenceStore: changedStore
        )
        var changed = local
        changed.version = "2.0.0"
        let changedState = try BackupReaderExtensionState(snapshot: ReaderExtensionBackupSnapshot(
            repositories: [repository],
            installedSources: [changed],
            showMatureSources: false,
            autoUpdateSources: true,
            lastAutoUpdate: nil
        ))
        try changedState.restore(to: changedStore, preferenceStore: changedStore)
        let changedResult = try XCTUnwrap(
            ReaderExtensionPersistence.loadInstalledSources(from: changedStore).first
        )
        XCTAssertTrue(changedResult.requiresReinstall)
        XCTAssertFalse(changedResult.isRunnable)
    }
#endif

    func testBackupDataRoundTripsProfilesAndServicesSettings() throws {

        let seed = """
        {"version":"2.0","createdDate":0,"tmdbLanguage":"en-US","selectedAppearance":"system",
         "readerSelectedAppearance":"system","readerGlobalAppearanceEnabled":true,
         "enableSubtitlesByDefault":false,"defaultSubtitleLanguage":"eng",
         "playerSubtitleAppearanceEnabled":true,"preferredAutoAudioLanguage":"eng",
         "preferredAnimeAudioLanguage":"jpn","inAppPlayer":"none","showScheduleTab":true,
         "showLocalScheduleTime":true}
        """
        let seedDecoder = JSONDecoder()
        seedDecoder.dateDecodingStrategy = .secondsSince1970
        var backup = try seedDecoder.decode(BackupData.self, from: Data(seed.utf8))
        let profileID = UUID()
        var snapshot = BackupProfileSnapshot(
            id: profileID,
            name: "Second",
            avatarSymbol: "person",
            avatarColorHex: "#123456",
            avatarPhotoData: nil,
            isKidsProfile: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        snapshot.userRatings = ["550": 8.0]
        snapshot.searchHistory = BackupSearchHistory(queries: ["fight club"])
        snapshot.servicesSettings = [
            "servicesAutoModeEnabled": try PropertyListSerialization.data(
                fromPropertyList: true, format: .binary, options: 0
            )
        ]
        backup.profiles = [snapshot]
        backup.activeProfileID = profileID
        backup.servicesSettings = [
            "contentBlockingBlockAddonCatalogs": try PropertyListSerialization.data(
                fromPropertyList: true, format: .binary, options: 0
            )
        ]
        backup.sharesServices = false

        let encoded = try JSONEncoder().encode(backup)
        let decoded = try JSONDecoder().decode(BackupData.self, from: encoded)

        XCTAssertEqual(decoded.profiles?.count, 1, "The profile roster must survive encoding")
        XCTAssertEqual(decoded.activeProfileID, profileID)
        XCTAssertEqual(decoded.profiles?.first?.userRatings["550"], 8.0)
        XCTAssertEqual(
            decoded.profiles?.first?.searchHistory.queries,
            ["fight club"],
            "Search history is captured per profile; restoring an empty one would erase it"
        )
        XCTAssertNotNil(
            decoded.profiles?.first?.servicesSettings["servicesAutoModeEnabled"],
            "A profile's own services settings must survive when Share Services is off"
        )
        XCTAssertNotNil(
            decoded.servicesSettings?["contentBlockingBlockAddonCatalogs"],
            "Content Blocking is services-scoped and was previously in no backup field at all"
        )
        XCTAssertEqual(
            decoded.sharesServices,
            false,
            "The Share Services mode decides which store every source write resolves to, so it has to travel with the sources"
        )
    }

    func testBackupWithoutSharesServicesDecodesAsNilRatherThanFalse() throws {
        let legacy = """
        {"version":"1.0","createdDate":0,"tmdbLanguage":"en-US","selectedAppearance":"system",
         "readerSelectedAppearance":"system","readerGlobalAppearanceEnabled":true,
         "enableSubtitlesByDefault":false,"defaultSubtitleLanguage":"eng",
         "playerSubtitleAppearanceEnabled":true,"preferredAutoAudioLanguage":"eng",
         "preferredAnimeAudioLanguage":"jpn","inAppPlayer":"none","showScheduleTab":true,
         "showLocalScheduleTime":true}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(BackupData.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.sharesServices)
    }

    func testManualBackupTrackerStateCarriesNoCredentials() throws {
        var account = TrackerAccount(
            service: .anilist,
            username: "someone",
            accessToken: "SECRET-ACCESS-TOKEN",
            refreshToken: "SECRET-REFRESH-TOKEN",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            userId: "1"
        )
        account.isConnected = true
        var state = TrackerState()
        state.addOrUpdateAccount(account)

        let redacted = BackupManager.trackerStateWithoutCredentials(state)
        let encoded = try JSONEncoder().encode(redacted)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(text.contains("SECRET-ACCESS-TOKEN"), "A manual backup remains credential-free")
        XCTAssertFalse(text.contains("SECRET-REFRESH-TOKEN"), "A manual backup remains credential-free")
    }

    func testExperimentalPrivateCloudSnapshotCarriesTrackerCredentials() throws {
        var object = minimalBackupObject()
        object["trackerState"] = [
            "accounts": [[
                "service": "anilist",
                "username": "fixture-user",
                "accessToken": "PRIVATE-CLOUD-ACCESS-FIXTURE",
                "refreshToken": "PRIVATE-CLOUD-REFRESH-FIXTURE",
                "userId": "fixture-id",
                "isConnected": true
            ]],
            "syncEnabled": true
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(BackupData.self, from: data)
        let cloudData = try JSONEncoder().encode(decoded.redactedForExperimentalCloudSync())
        let text = String(decoding: cloudData, as: UTF8.self)

        XCTAssertTrue(text.contains("PRIVATE-CLOUD-ACCESS-FIXTURE"))
        XCTAssertTrue(text.contains("PRIVATE-CLOUD-REFRESH-FIXTURE"))
    }

    func testCompleteEmptyPrivateCloudConfigurationCarriesDeletionAuthority() throws {
        let snapshot = try completePrivateCloudBackup()
            .redactedForExperimentalCloudSync(stripSkyStreamArchives: true)

        XCTAssertTrue(snapshot.privateCloudConfigurationWasCapturedCompletely)
        XCTAssertEqual(snapshot.nuvioPlugins?.repositories, [])
        XCTAssertEqual(snapshot.skyStream?.repositories, [])
        XCTAssertEqual(snapshot.profiles?.first?.readerExtensionsState?.installedSourceCount, 0)
    }

    func testIncompletePrivateCloudDomainsCannotAuthorizeWholeSnapshotReplacement() throws {
        let complete = try completePrivateCloudBackup()
            .redactedForExperimentalCloudSync(stripSkyStreamArchives: true)
        XCTAssertTrue(complete.privateCloudConfigurationWasCapturedCompletely)

        var missingNuvio = complete
        missingNuvio.nuvioPlugins = nil
        XCTAssertFalse(missingNuvio.privateCloudConfigurationWasCapturedCompletely)

        let missingProfileNuvio = changingFirstProfile(in: complete) {
            $0.nuvioPlugins = nil
        }
        XCTAssertFalse(missingProfileNuvio.privateCloudConfigurationWasCapturedCompletely)

        var missingReader = complete
        missingReader.readerExtensionsState = nil
        XCTAssertFalse(missingReader.privateCloudConfigurationWasCapturedCompletely)

        let missingProfileReader = changingFirstProfile(in: complete) {
            $0.readerPrivateCloudConfigurationData = nil
        }
        XCTAssertFalse(missingProfileReader.privateCloudConfigurationWasCapturedCompletely)

        let unreadableProfileReader = changingFirstProfile(in: complete) {
            $0.readerExtensionsState = BackupReaderExtensionState(
                metadataJSON: nil,
                installedSourceCount: 1,
                showMatureSources: false,
                autoUpdateSources: true,
                lastAutoUpdate: nil
            )
        }
        XCTAssertFalse(unreadableProfileReader.privateCloudConfigurationWasCapturedCompletely)

        let incompleteTracker = changingFirstProfile(in: complete) {
            $0.trackerCredentialsAndRosterWereCaptured = false
        }
        XCTAssertFalse(incompleteTracker.privateCloudConfigurationWasCapturedCompletely)

        var missingSky = complete
        missingSky.skyStream = nil
        XCTAssertFalse(missingSky.privateCloudConfigurationWasCapturedCompletely)

        let missingProfileSky = changingFirstProfile(in: complete) {
            $0.skyStream = nil
        }
        XCTAssertFalse(missingProfileSky.privateCloudConfigurationWasCapturedCompletely)

        var missingStremio = complete
        missingStremio.stremioAddons = nil
        XCTAssertFalse(missingStremio.privateCloudConfigurationWasCapturedCompletely)

        let missingProfileServices = changingFirstProfile(in: complete) {
            $0.services = nil
        }
        XCTAssertFalse(missingProfileServices.privateCloudConfigurationWasCapturedCompletely)

        var incompleteSettings = complete
        incompleteSettings.servicesSettingsWereCaptured = false
        XCTAssertFalse(incompleteSettings.privateCloudConfigurationWasCapturedCompletely)

        let incompleteProfileSettings = changingFirstProfile(in: complete) {
            $0.servicesSettingsWereCaptured = false
        }
        XCTAssertFalse(incompleteProfileSettings.privateCloudConfigurationWasCapturedCompletely)
    }

    func testExperimentalCloudRestoreDropsReaderMetadataWithoutCompletePrivateAuthority() throws {
        let complete = try completePrivateCloudBackup()
            .redactedForExperimentalCloudSync(stripSkyStreamArchives: true)

        var missingConfiguration = changingFirstProfile(in: complete) {
            $0.readerPrivateCloudConfigurationData = nil
        }
        missingConfiguration.removeReaderDomainsWithoutCompletePrivateCloudAuthority()
        XCTAssertNil(missingConfiguration.readerExtensionsState)
        XCTAssertNil(missingConfiguration.profiles?.first?.readerExtensionsState)
        XCTAssertNil(missingConfiguration.profiles?.first?.readerPrivateCloudConfigurationData)

        var malformedConfiguration = changingFirstProfile(in: complete) {
            $0.readerPrivateCloudConfigurationData = Data("{}".utf8)
        }
        malformedConfiguration.removeReaderDomainsWithoutCompletePrivateCloudAuthority()
        XCTAssertNil(malformedConfiguration.readerExtensionsState)
        XCTAssertNil(malformedConfiguration.profiles?.first?.readerExtensionsState)
        XCTAssertNil(malformedConfiguration.profiles?.first?.readerPrivateCloudConfigurationData)

        var completeAuthority = complete
        completeAuthority.removeReaderDomainsWithoutCompletePrivateCloudAuthority()
        XCTAssertNotNil(completeAuthority.readerExtensionsState)
        XCTAssertNotNil(completeAuthority.profiles?.first?.readerExtensionsState)
        XCTAssertNotNil(completeAuthority.profiles?.first?.readerPrivateCloudConfigurationData)
    }

    func testPrivateCloudTrackerExportHydratesInactiveProfileAndFailsClosed() throws {
        var source = TrackerState()
        source.addOrUpdateAccount(TrackerAccount(
            service: .trakt,
            username: "inactive-user",
            accessToken: "",
            refreshToken: nil,
            expiresAt: nil,
            userId: "inactive-id"
        ))

        let hydrated = try XCTUnwrap(TrackerPrivateCloudExportPolicy.materializedState(
            from: source,
            hydrate: { account in
                .found(TrackerAccount(
                    service: account.service,
                    username: account.username,
                    accessToken: "HYDRATED-ACCESS-FIXTURE",
                    refreshToken: "HYDRATED-REFRESH-FIXTURE",
                    expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
                    userId: account.userId
                ))
            }
        ))
        XCTAssertEqual(hydrated.accounts.first?.accessToken, "HYDRATED-ACCESS-FIXTURE")
        XCTAssertEqual(hydrated.accounts.first?.refreshToken, "HYDRATED-REFRESH-FIXTURE")

        XCTAssertNil(TrackerPrivateCloudExportPolicy.materializedState(
            from: source,
            hydrate: { _ in .unavailable }
        ), "A missing or locked Keychain item must not become authoritative disconnected state")
    }

    func testPrivateCloudTrackerExportRejectsABAAndPendingDeletionAuthority() {
        let profileID = UUID()
        let before = TrackerPrivateCloudExportAuthority(
            profileID: profileID,
            rosterGeneration: 3,
            operationGeneration: 10,
            accountBoundaryGeneration: 2,
            serviceGenerations: [.anilist: 4, .myAnimeList: 1, .trakt: 8]
        )
        let afterABA = TrackerPrivateCloudExportAuthority(
            profileID: profileID,
            rosterGeneration: 3,
            operationGeneration: 12,
            accountBoundaryGeneration: 2,
            serviceGenerations: [.anilist: 4, .myAnimeList: 1, .trakt: 8]
        )
        XCTAssertFalse(TrackerPrivateCloudExportPolicy.authorityRemainedCurrent(
            before: before,
            after: afterABA,
            profileStillExists: true,
            cleanupIsPending: false
        ), "A→B→A still advances tracker operation authority and must invalidate capture")
        XCTAssertFalse(TrackerPrivateCloudExportPolicy.authorityRemainedCurrent(
            before: before,
            after: before,
            profileStillExists: true,
            cleanupIsPending: true
        ), "A pending credential-deletion journal must block export")
    }

    func testPrivateCloudTrackerRestorePrefersRotatedIncomingCredential() throws {
        let local = TrackerAccount(
            service: .myAnimeList,
            username: "old-user",
            accessToken: "OLD-LOCAL-ACCESS",
            refreshToken: "OLD-LOCAL-REFRESH",
            expiresAt: nil,
            userId: "old-id"
        )
        let incoming = TrackerAccount(
            service: .myAnimeList,
            username: "new-user",
            accessToken: "NEW-CLOUD-ACCESS",
            refreshToken: "NEW-CLOUD-REFRESH",
            expiresAt: nil,
            userId: "new-id"
        )
        let preferred = try XCTUnwrap(
            TrackerPrivateCloudExportPolicy.preferredCredentialBearingAccount(
                incoming: incoming,
                local: local,
                credentialsAndRosterAreAuthoritative: true
            )
        )
        XCTAssertEqual(preferred.userId, "new-id")
        XCTAssertEqual(preferred.accessToken, "NEW-CLOUD-ACCESS")

        let legacyPreferred = try XCTUnwrap(
            TrackerPrivateCloudExportPolicy.preferredCredentialBearingAccount(
                incoming: incoming,
                local: local,
                credentialsAndRosterAreAuthoritative: false
            )
        )
        XCTAssertEqual(legacyPreferred.userId, "old-id")
    }

    func testCompleteTrackerRosterDisconnectsOmittedAccountsButLegacyPreserves() {
        let local = TrackerAccount(
            service: .trakt,
            username: "local-user",
            accessToken: "local-fixture",
            refreshToken: "refresh-fixture",
            expiresAt: nil,
            userId: "local-id",
            isConnected: true
        )
        XCTAssertEqual(
            TrackerPrivateCloudExportPolicy.omittedConnectedAccounts(
                existing: [local],
                incoming: [],
                credentialsAndRosterAreAuthoritative: true
            ).map(\.service),
            [.trakt]
        )
        XCTAssertTrue(
            TrackerPrivateCloudExportPolicy.omittedConnectedAccounts(
                existing: [local],
                incoming: [],
                credentialsAndRosterAreAuthoritative: false
            ).isEmpty
        )
        let tombstone = TrackerPrivateCloudExportPolicy.disconnectedTombstone(local)
        XCTAssertFalse(tombstone.isConnected)
        XCTAssertTrue(tombstone.accessToken.isEmpty)
        XCTAssertNil(tombstone.refreshToken)
    }

    func testTrackerCredentialsAreDeviceOnlyOutsidePrivateCloudSnapshots() {
        XCTAssertFalse(TrackerCredentialStoragePolicy.primarySynchronizable)
        XCTAssertTrue(TrackerCredentialStoragePolicy.legacySynchronizable)
    }

    func testPrivateCloudTrackerTransactionRestoresPreStateAfterLateAuthorityFailure() {
        let previousAccount = TrackerAccount(
            service: .trakt,
            username: "local-user",
            accessToken: "LOCAL-ACCESS",
            refreshToken: "LOCAL-REFRESH",
            expiresAt: nil,
            userId: "local-id"
        )
        let incomingAccount = TrackerAccount(
            service: .trakt,
            username: "remote-user",
            accessToken: "REMOTE-ACCESS",
            refreshToken: "REMOTE-REFRESH",
            expiresAt: nil,
            userId: "remote-id"
        )
        var credentials: [TrackerService: TrackerAccount] = [.trakt: previousAccount]
        var persistedState = "local"
        var authorityCheckCount = 0

        let succeeded = TrackerPrivateCloudRestoreTransaction.apply(
            services: [.trakt],
            previous: [.trakt: previousAccount],
            incoming: [.trakt: incomingAccount],
            applyCredential: { service, account in
                credentials[service] = account
                return true
            },
            persistTargetState: {
                persistedState = "remote"
                return true
            },
            authorityIsCurrent: {
                authorityCheckCount += 1
                return authorityCheckCount < 3
            },
            restoreCredential: { service, account in
                credentials[service] = account
                return true
            },
            restorePreviousState: {
                persistedState = "local"
                return true
            }
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(credentials[.trakt]?.accessToken, previousAccount.accessToken)
        XCTAssertEqual(credentials[.trakt]?.userId, previousAccount.userId)
        XCTAssertEqual(persistedState, "local")
    }

    func testPrivateCloudTrackerTransactionFailsWhenCredentialOrStatePersistenceFails() {
        let localTrakt = TrackerAccount(
            service: .trakt,
            username: "local-trakt",
            accessToken: "LOCAL-TRAKT",
            refreshToken: nil,
            expiresAt: nil,
            userId: "local-trakt-id"
        )
        let remoteTrakt = TrackerAccount(
            service: .trakt,
            username: "remote-trakt",
            accessToken: "REMOTE-TRAKT",
            refreshToken: nil,
            expiresAt: nil,
            userId: "remote-trakt-id"
        )
        let remoteAniList = TrackerAccount(
            service: .anilist,
            username: "remote-anilist",
            accessToken: "REMOTE-ANILIST",
            refreshToken: nil,
            expiresAt: nil,
            userId: "remote-anilist-id"
        )
        var credentials: [TrackerService: TrackerAccount] = [.trakt: localTrakt]
        var persistedTargetState = false

        let credentialSucceeded = TrackerPrivateCloudRestoreTransaction.apply(
            services: [.trakt, .anilist],
            previous: [.trakt: localTrakt],
            incoming: [.trakt: remoteTrakt, .anilist: remoteAniList],
            applyCredential: { service, account in
                guard service != .anilist else { return false }
                credentials[service] = account
                return true
            },
            persistTargetState: {
                persistedTargetState = true
                return true
            },
            authorityIsCurrent: { true },
            restoreCredential: { service, account in
                credentials[service] = account
                return true
            },
            restorePreviousState: { true }
        )

        XCTAssertFalse(credentialSucceeded)
        XCTAssertFalse(persistedTargetState)
        XCTAssertEqual(credentials[.trakt]?.accessToken, localTrakt.accessToken)
        XCTAssertNil(credentials[.anilist])

        let persistenceSucceeded = TrackerPrivateCloudRestoreTransaction.apply(
            services: [.trakt],
            previous: [.trakt: localTrakt],
            incoming: [.trakt: remoteTrakt],
            applyCredential: { service, account in
                credentials[service] = account
                return true
            },
            persistTargetState: { false },
            authorityIsCurrent: { true },
            restoreCredential: { service, account in
                credentials[service] = account
                return true
            },
            restorePreviousState: { true }
        )

        XCTAssertFalse(persistenceSucceeded)
        XCTAssertEqual(credentials[.trakt]?.accessToken, localTrakt.accessToken)
    }

    func testAccountBoundaryTrackerCleanupPreservesAuthoritativelyRestoredOverlap() {
        let overlap = ProfileManager.defaultProfileID
        let outgoingOnly = UUID()
        let incomingOnly = UUID()

        let cleanup = ExperimentalCloudTrackerAccountBoundaryPolicy.profileIDsToClear(
            outgoingProfileIDs: [overlap, outgoingOnly],
            restoredTrackerProfileIDs: [overlap, incomingOnly]
        )

        XCTAssertEqual(cleanup, [outgoingOnly])
        XCTAssertFalse(cleanup.contains(overlap))
    }

    func testLegacyAccountBoundaryContextDefaultsRestoredTrackerProfilesToEmpty() throws {
        let outgoing = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "providerRawValue": "fixture",
            "generation": 3,
            "pendingIdentity": "incoming-account",
            "outgoingProfileIDs": [outgoing.uuidString]
        ])

        let decoded = try JSONDecoder().decode(
            ExperimentalCloudRestoreBoundaryContext.self,
            from: data
        )

        XCTAssertEqual(decoded.outgoingProfileIDs, [outgoing])
        XCTAssertTrue(decoded.restoredTrackerProfileIDs.isEmpty)

        let enriched = ExperimentalCloudRestoreBoundaryContext(
            providerRawValue: "fixture",
            generation: 4,
            pendingIdentity: "incoming-account",
            outgoingProfileIDs: [outgoing],
            restoredTrackerProfileIDs: [ProfileManager.defaultProfileID]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExperimentalCloudRestoreBoundaryContext.self,
                from: JSONEncoder().encode(enriched)
            ),
            enriched
        )
    }

    func testAuthoritativeRosterInvariantRejectsUnsafeDecodedRosters() {
        let adult = Profile(name: "Adult")
        XCTAssertTrue(ProfileManager.isValidAuthoritativeRoster([adult]))

        XCTAssertFalse(ProfileManager.isValidAuthoritativeRoster([]))
        XCTAssertFalse(ProfileManager.isValidAuthoritativeRoster([adult, adult]))
        XCTAssertFalse(ProfileManager.isValidAuthoritativeRoster([
            Profile(id: UUID(), name: "   ")
        ]))
        XCTAssertFalse(ProfileManager.isValidAuthoritativeRoster([
            Profile(id: UUID(), name: "Kid", isKidsProfile: true)
        ]))
        XCTAssertFalse(ProfileManager.isValidAuthoritativeRoster([
            Profile(
                id: UUID(),
                name: "Oversized Photo",
                avatarPhotoData: Data(repeating: 0, count: ProfileAvatar.maximumPhotoBytes + 1)
            )
        ]))
        XCTAssertFalse(ProfileManager.isValidAuthoritativeRoster([
            Profile(id: UUID(), name: "Invalid PIN", pinHash: "not-a-pin-hash")
        ]))
    }

    func testProfileRosterSanitizerKeepsLocalProfilesSyncable() throws {
        let raw = Profile(
            id: UUID(),
            name: " \u{0000} Alice\n ",
            avatarSymbol: "invalid 🚫",
            avatarColorHex: "#abcdef",
            avatarPhotoData: Data(repeating: 1, count: ProfileAvatar.maximumPhotoBytes + 1),
            isKidsProfile: false,
            createdAt: Date(
                timeIntervalSinceNow: MediaStateEnvelopeValidator.maximumFutureClockSkew + 60
            ),
            pinChangedAt: Date(timeIntervalSince1970: -1),
            kidsFlagChangedAt: Date(
                timeIntervalSinceNow: MediaStateEnvelopeValidator.maximumFutureClockSkew + 60
            )
        )

        let sanitized = try XCTUnwrap(ProfileManager.sanitizedProfileForRoster(raw))
        XCTAssertEqual(sanitized.name, "Alice")
        XCTAssertEqual(sanitized.avatarSymbol, ProfileAvatar.defaultSymbol)
        XCTAssertEqual(sanitized.avatarColorHex, "#ABCDEF")
        XCTAssertNil(sanitized.avatarPhotoData)
        XCTAssertGreaterThanOrEqual(sanitized.createdAt.timeIntervalSince1970, 0)
        XCTAssertNil(sanitized.pinChangedAt)
        XCTAssertNotNil(sanitized.kidsFlagChangedAt)
        XCTAssertTrue(ProfileManager.isValidAuthoritativeRoster([sanitized]))
    }

    func testRestoreAdmissionDoesNotChargeTheUnreadableFallbackAsAProfile() {
        let snapshots = (0..<ProfileManager.maximumProfiles).map { index in
            profileSnapshot(id: UUID(), name: "Restored \(index)")
        }
        let admitted = BackupManager.profileSnapshotsAdmittedForRestore(
            snapshots,
            existingProfileIDs: []
        )

        XCTAssertEqual(admitted.map(\.id), snapshots.map(\.id))
    }

    func testRestoreAdmissionPrioritizesExistingProfilesBeyondNewcomerCap() {
        let existingID = UUID()
        let newcomers = (0..<ProfileManager.maximumProfiles).map { index in
            profileSnapshot(id: UUID(), name: "New \(index)")
        }
        let admitted = BackupManager.profileSnapshotsAdmittedForRestore(
            newcomers + [profileSnapshot(id: existingID, name: "Existing")],
            existingProfileIDs: [existingID]
        )

        XCTAssertEqual(admitted.count, ProfileManager.maximumProfiles)
        XCTAssertTrue(
            admitted.contains { $0.id == existingID },
            "An existing profile must survive even when it appears after enough newcomers to fill the raw prefix"
        )
        XCTAssertEqual(
            admitted.filter { $0.id != existingID }.count,
            ProfileManager.maximumProfiles - 1
        )
    }

    func testPrivateConfigurationAdmissionAllowsCanonicalProfilesBeyondTheLocalRoster() {
        let localProfileIDs = Set(
            (0..<ProfileManager.maximumProfiles).map { _ in UUID() }
        )
        let canonicalSnapshots = (0..<(ProfileManager.maximumProfiles + 2)).map { index in
            profileSnapshot(id: UUID(), name: "Canonical \(index)")
        }

        let ordinaryAdmission = BackupManager.profileSnapshotsAdmittedForRestore(
            canonicalSnapshots,
            existingProfileIDs: localProfileIDs
        )
        let privateConfigurationAdmission = BackupManager.profileSnapshotsAdmittedForRestore(
            canonicalSnapshots,
            existingProfileIDs: localProfileIDs,
            admittingUnrosteredPrivateConfiguration: true
        )

        XCTAssertTrue(ordinaryAdmission.isEmpty)
        XCTAssertEqual(
            privateConfigurationAdmission.map(\.id),
            canonicalSnapshots.prefix(ProfileManager.maximumProfiles).map(\.id)
        )
    }

    func testRestoreAdmissionDeduplicatesAndRejectsBlankNames() {
        let duplicateID = UUID()
        let blankExistingID = UUID()
        let admitted = BackupManager.profileSnapshotsAdmittedForRestore(
            [
                profileSnapshot(id: duplicateID, name: "First"),
                profileSnapshot(id: duplicateID, name: "Second"),
                profileSnapshot(id: blankExistingID, name: "   ")
            ],
            existingProfileIDs: [blankExistingID]
        )

        XCTAssertEqual(admitted.map(\.id), [duplicateID])
        XCTAssertEqual(admitted.first?.name, "First")
    }

    func testMergeReturnsOnlyProfilesItActuallyAccepted() throws {
        let manager = ProfileManager.shared
        let existing = try XCTUnwrap(manager.profiles.first)
        let rejected = Profile(
            id: existing.id,
            name: "\n\t",
            avatarSymbol: existing.avatarSymbol,
            avatarColorHex: existing.avatarColorHex,
            avatarPhotoData: nil,
            isKidsProfile: existing.isKidsProfile,
            createdAt: existing.createdAt
        )

        let generation = manager.rosterGeneration
        let accepted = manager.mergeProfilesFromBackup([rejected])
        XCTAssertFalse(accepted.contains(existing.id))
        XCTAssertEqual(manager.rosterGeneration, generation)
    }

    func testMergeAddsMissingProfilesAndNeverDeletes() {
        let manager = ProfileManager.shared
        let before = Set(manager.profiles.map(\.id))
        let newcomer = Profile(
            id: UUID(),
            name: "Restored",
            avatarSymbol: "person",
            avatarColorHex: "#00FF00",
            avatarPhotoData: nil,
            isKidsProfile: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let accepted = manager.mergeProfilesFromBackup([newcomer])
        defer { _ = manager.deleteProfile(newcomer.id) }

        XCTAssertTrue(accepted.contains(newcomer.id))
        let after = Set(manager.profiles.map(\.id))
        XCTAssertTrue(after.contains(newcomer.id), "A profile present only in the backup must be restored")
        XCTAssertTrue(
            before.isSubset(of: after),
            "Restoring a backup must never remove a profile that exists on this device"
        )
    }

    func testMergeRefusesToResurrectALocallyDeletedProfile() {
        let manager = ProfileManager.shared
        let doomed = Profile(
            id: UUID(),
            name: "Deleted Elsewhere",
            avatarSymbol: "person",
            avatarColorHex: "#0000FF",
            avatarPhotoData: nil,
            isKidsProfile: false,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertTrue(manager.mergeProfilesFromBackup([doomed]).contains(doomed.id))
        _ = manager.deleteProfile(doomed.id)
        XCTAssertTrue(manager.wasDeletedLocally(doomed.id))

        let accepted = manager.mergeProfilesFromBackup([doomed])

        XCTAssertFalse(
            accepted.contains(doomed.id),
            "A profile deleted on this device must not be resurrected by a peer snapshot that still contains it"
        )
        XCTAssertFalse(
            manager.profiles.contains { $0.id == doomed.id },
            "Resurrecting a deleted profile also replays its progress, ratings and collections"
        )
        XCTAssertTrue(
            manager.wasDeletedLocally(doomed.id),
            "The deletion tombstone must survive the merge that tried to undo it"
        )
    }

    func testMergeNeverClearsALocalKidsFlag() {
        let manager = ProfileManager.shared
        let id = UUID()
        manager.mergeProfilesFromBackup([
            Profile(
                id: id,
                name: "Kid",
                avatarSymbol: "person",
                avatarColorHex: "#00FF00",
                avatarPhotoData: nil,
                isKidsProfile: true,
                createdAt: Date(timeIntervalSince1970: 2)
            )
        ])
        defer { _ = manager.deleteProfile(id) }
        XCTAssertEqual(manager.profile(with: id)?.isKidsProfile, true)

        manager.mergeProfilesFromBackup([
            Profile(
                id: id,
                name: "Kid",
                avatarSymbol: "person",
                avatarColorHex: "#00FF00",
                avatarPhotoData: nil,
                isKidsProfile: false,
                createdAt: Date(timeIntervalSince1970: 2)
            )
        ])
        XCTAssertEqual(
            manager.profile(with: id)?.isKidsProfile,
            true,
            "An older backup must not be able to lift a kids restriction set on this device"
        )
    }

    func testMergeCannotMakeEveryProfileAKidsProfile() {
        let manager = ProfileManager.shared
        let adults = manager.profiles.filter { !$0.isKidsProfile }
        XCTAssertFalse(adults.isEmpty, "The fixture roster must start with at least one grown-up profile")

        manager.mergeProfilesFromBackup(
            adults.map {
                Profile(
                    id: $0.id,
                    name: $0.name,
                    avatarSymbol: $0.avatarSymbol,
                    avatarColorHex: $0.avatarColorHex,
                    avatarPhotoData: nil,
                    isKidsProfile: true,
                    createdAt: $0.createdAt
                )
            }
        )

        XCTAssertTrue(
            manager.profiles.contains { !$0.isKidsProfile },
            "A backup must never be able to leave the roster with no profile able to administer it"
        )
    }

    func testMergeStopsAtTheProfileMaximum() {
        let manager = ProfileManager.shared
        let overflow = (0..<(ProfileManager.maximumProfiles + 3)).map { index in
            Profile(
                id: UUID(),
                name: "Imported \(index)",
                avatarSymbol: "person",
                avatarColorHex: "#00FF00",
                avatarPhotoData: nil,
                isKidsProfile: false,
                createdAt: Date(timeIntervalSince1970: TimeInterval(1000 + index))
            )
        }

        manager.mergeProfilesFromBackup(overflow)
        defer { overflow.forEach { _ = manager.deleteProfile($0.id) } }

        XCTAssertLessThanOrEqual(
            manager.profiles.count,
            ProfileManager.maximumProfiles,
            "Backup roster ingestion must respect the same cap every other creation path does"
        )
    }

    func testDefaultProfileCannotBeDeleted() {
        let manager = ProfileManager.shared
        let placeholder = Profile(
            id: UUID(),
            name: "Second",
            avatarSymbol: "person",
            avatarColorHex: "#00FF00",
            avatarPhotoData: nil,
            isKidsProfile: false,
            createdAt: Date(timeIntervalSince1970: 5)
        )
        manager.mergeProfilesFromBackup([placeholder])
        defer { _ = manager.deleteProfile(placeholder.id) }

        XCTAssertFalse(
            manager.deleteProfile(ProfileManager.defaultProfileID),
            "Deleting the default profile would strand its settings and its tvOS credentials with nothing able to address them"
        )
        XCTAssertNotNil(manager.profile(with: ProfileManager.defaultProfileID))
    }

}

final class TraktOAuthRefreshFailurePolicyTests: XCTestCase {
    func testOnlyExactInvalidGrantOnBadRequestRequiresAuthentication() {
        let exact = Data(#"{"error":"invalid_grant"}"#.utf8)
        let normalized = Data(#"{"error":"  INVALID_GRANT\n"}"#.utf8)

        XCTAssertEqual(
            TraktOAuthRefreshFailurePolicy.disposition(
                statusCode: 400,
                responseData: exact
            ),
            .authenticationRequired
        )
        XCTAssertEqual(
            TraktOAuthRefreshFailurePolicy.disposition(
                statusCode: 400,
                responseData: normalized
            ),
            .authenticationRequired
        )
    }

    func testDescriptionsSubstringsAndOtherOAuthCodesDoNotRequireAuthentication() {
        let bodies = [
            #"{"error_description":"invalid_grant"}"#,
            #"{"error":"invalid_grant_suffix"}"#,
            #"{"error":"prefix_invalid_grant"}"#,
            #"{"error":"invalid_request"}"#,
            #"{"error":"invalid_client"}"#,
            #"{"error":"temporarily_unavailable"}"#
        ]

        for body in bodies {
            XCTAssertEqual(
                TraktOAuthRefreshFailurePolicy.disposition(
                    statusCode: 400,
                    responseData: Data(body.utf8)
                ),
                .other,
                body
            )
        }
    }

    func testStatusMustBeTheDocumentedBadRequest() {
        let body = Data(#"{"error":"invalid_grant"}"#.utf8)

        for statusCode in [200, 401, 403, 429, 500, 503] {
            XCTAssertEqual(
                TraktOAuthRefreshFailurePolicy.disposition(
                    statusCode: statusCode,
                    responseData: body
                ),
                .other,
                "status=\(statusCode)"
            )
        }
    }

    func testMalformedNonObjectNonStringAndOversizedBodiesAreNonterminal() {
        let bodies = [
            Data("not-json".utf8),
            Data(#"["invalid_grant"]"#.utf8),
            Data(#"{"error":7}"#.utf8),
            Data(#"{"error":null}"#.utf8),
            Data(
                #"{"error":""#
                    .appending(String(repeating: "x", count: TraktOAuthRefreshFailurePolicy.maximumErrorCodeBytes + 1))
                    .appending(#""}"#)
                    .utf8
            ),
            Data(
                repeating: 0x78,
                count: TraktOAuthRefreshFailurePolicy.maximumResponseBytes + 1
            )
        ]

        for body in bodies {
            XCTAssertEqual(
                TraktOAuthRefreshFailurePolicy.disposition(
                    statusCode: 400,
                    responseData: body
                ),
                .other
            )
        }
    }

    func testStructuredFailureNeverExposesProviderDescription() {
        let body = Data(
            #"{"error":"invalid_grant","error_description":"SECRET PROVIDER DETAIL"}"#.utf8
        )
        let failure = TraktOAuthRefreshFailure(
            statusCode: 400,
            responseData: body
        )

        XCTAssertEqual(failure.disposition, .authenticationRequired)
        XCTAssertFalse((failure as Error).localizedDescription.contains("SECRET PROVIDER DETAIL"))
        XCTAssertTrue(
            (failure as Error).localizedDescription.hasPrefix(
                "Trakt token refresh failed with status 400: bytes=70 token="
            )
        )
    }
}

final class TraktAuthenticationRequiredLatchStoreTests: XCTestCase {
    private let owner = UUID()
    private let otherOwner = UUID()

    private func identity(
        owner: UUID? = nil,
        accountBoundaryGeneration: UInt64 = 7,
        accessToken: String = "access-a",
        refreshToken: String? = "refresh-a"
    ) -> TraktAuthenticationCredentialIdentity {
        TraktAuthenticationCredentialIdentity(
            owner: owner ?? self.owner,
            accountBoundaryGeneration: accountBoundaryGeneration,
            userId: "user-a",
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    func testLatchInstallsOnceAndBlocksOnlyTheExactCredential() {
        var store = TraktAuthenticationRequiredLatchStore()
        let credential = identity()

        XCTAssertTrue(store.install(failedIdentity: credential, currentIdentity: credential))
        XCTAssertFalse(store.install(failedIdentity: credential, currentIdentity: credential))
        XCTAssertTrue(store.blocks(credential))
        XCTAssertFalse(store.blocks(identity(owner: otherOwner)))
        XCTAssertTrue(store.blocks(credential))
    }

    func testStaleFailureCannotLatchReplacementCredential() {
        var store = TraktAuthenticationRequiredLatchStore()
        let failed = identity()
        let replacement = identity(accessToken: "access-b", refreshToken: "refresh-b")

        XCTAssertFalse(store.install(failedIdentity: failed, currentIdentity: replacement))
        XCTAssertFalse(store.blocks(failed))
        XCTAssertFalse(store.blocks(replacement))
    }

    func testReplacementCredentialAndAccountBoundaryClearTheOldLatch() {
        var credentialStore = TraktAuthenticationRequiredLatchStore()
        let credential = identity()
        XCTAssertTrue(
            credentialStore.install(failedIdentity: credential, currentIdentity: credential)
        )
        XCTAssertFalse(
            credentialStore.blocks(identity(accessToken: "access-b", refreshToken: "refresh-b"))
        )
        XCTAssertFalse(credentialStore.blocks(credential))

        var boundaryStore = TraktAuthenticationRequiredLatchStore()
        XCTAssertTrue(boundaryStore.install(failedIdentity: credential, currentIdentity: credential))
        XCTAssertFalse(boundaryStore.blocks(identity(accountBoundaryGeneration: 8)))
        XCTAssertFalse(boundaryStore.blocks(credential))
    }

    func testNoticePresentsOncePerProfileActivationAndDisconnectClearsLatch() {
        var store = TraktAuthenticationRequiredLatchStore()
        let credential = identity()
        XCTAssertTrue(store.install(failedIdentity: credential, currentIdentity: credential))

        XCTAssertTrue(store.shouldPresent(credential))
        XCTAssertFalse(store.shouldPresent(credential))
        store.deactivate(owner)
        XCTAssertTrue(store.shouldPresent(credential))
        XCTAssertFalse(store.shouldPresent(credential))

        store.clear(owner)
        XCTAssertFalse(store.blocks(credential))
        XCTAssertFalse(store.shouldPresent(credential))
    }

    func testRepeatedForcedPlaybackChecksStayBlockedWithoutRepeatedNotice() {
        var store = TraktAuthenticationRequiredLatchStore()
        let credential = identity()
        XCTAssertTrue(store.install(failedIdentity: credential, currentIdentity: credential))

        var presentationCount = 0
        for _ in 0..<49 {
            XCTAssertTrue(store.blocks(credential))
            if store.shouldPresent(credential) {
                presentationCount += 1
            }
        }

        XCTAssertEqual(presentationCount, 1)
    }

    func testSuccessfulSignInClearsLatchEvenWhenCredentialIsReused() {
        var store = TraktAuthenticationRequiredLatchStore()
        let credential = identity()
        XCTAssertTrue(store.install(failedIdentity: credential, currentIdentity: credential))
        XCTAssertTrue(store.blocks(credential))

        store.clear(owner)

        XCTAssertFalse(store.blocks(credential))
        XCTAssertFalse(store.shouldPresent(credential))
    }
}
