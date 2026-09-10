import XCTest
@testable import Eclipse

#if os(iOS)

final class SettingsScopeTests: XCTestCase {

    func testExplicitKeySetsAreDisjoint() {
        let device = EclipseSettingsRegistry.deviceKeys
        let services = EclipseSettingsRegistry.servicesKeys
        let profile = EclipseSettingsRegistry.profileKeys

        XCTAssertTrue(
            device.isDisjoint(with: services),
            "claimed by both device and services: \(device.intersection(services).sorted())"
        )
        XCTAssertTrue(
            device.isDisjoint(with: profile),
            "claimed by both device and profile: \(device.intersection(profile).sorted())"
        )
        XCTAssertTrue(
            services.isDisjoint(with: profile),
            "claimed by both services and profile: \(services.intersection(profile).sorted())"
        )
    }

    func testEverySyncedSettingIsExplicitlyScoped() {
        let unclassified = MediaStateSettingRegistry.allKeys
            .filter { EclipseSettingsRegistry.explicitScope(for: $0) == nil }
            .sorted()

        XCTAssertTrue(
            unclassified.isEmpty,
            "MediaStateSettingRegistry keys with no explicit scope: \(unclassified)"
        )
    }

    func testExperimentalFamilyIsSplitByExactKeyNotPrefix() {
        XCTAssertEqual(EclipseSettingsRegistry.scope(for: "experimentalFeaturesEnabled"), .device)
        XCTAssertEqual(EclipseSettingsRegistry.scope(for: "experimentalICloudSyncEnabled"), .device)
        XCTAssertEqual(EclipseSettingsRegistry.scope(for: "experimentalMediaDesignPreset"), .profile)
        XCTAssertEqual(EclipseSettingsRegistry.scope(for: "experimentalHeroHeightScale"), .profile)
    }

    func testEveryProviderSyncBookkeepingKeyStaysDeviceLocal() {
        for provider in CloudSyncProvider.allCases {
            XCTAssertEqual(
                EclipseSettingsRegistry.scope(for: provider.lastSeenRemoteModificationKey),
                .device,
                "A captured last-seen marker re-triggers a snapshot push after every sync and ships one device's sync state to every other device"
            )
            XCTAssertEqual(EclipseSettingsRegistry.scope(for: provider.lastSyncedFootprintKey), .device)
            XCTAssertEqual(EclipseSettingsRegistry.scope(for: provider.lastAutomaticAttemptKey), .device)
            XCTAssertEqual(EclipseSettingsRegistry.scope(for: provider.retryNotBeforeKey), .device)
            XCTAssertEqual(EclipseSettingsRegistry.scope(for: provider.lastSeenRemoteRevisionKey), .device)
            XCTAssertEqual(EclipseSettingsRegistry.scope(for: provider.lastSuccessfulSyncKey), .device)
        }
    }

    func testServicesPrefixesCoverThePluginFamilies() {
        for key in [
            "servicesAutoModeSourceIds",
            "servicesAutoModeSourceOrderIds",
            "servicesAutoModeErrorIntelligenceEnabled",
            "servicesExtraRulesSourceIds",
            "skyStreamUntestedWarningSeen.v2.example",
            "nuvioPluginsState.v2",
            "stremioAddons",
            "tvServicesActiveSourceIds",
            "tvOSServiceSourceActivationOverrides",
            "kanzenAidokuInstalledSources",
            "kanzenAutoUpdateModules"
        ] {
            XCTAssertEqual(
                EclipseSettingsRegistry.scope(for: key), .services,
                "\(key) should resolve to the services store"
            )
        }
    }

    func testProfileRosterAndUpdaterStayOnTheDevice() {
        for key in [
            "eclipseProfilesV1",
            "eclipseActiveProfileIDV1",
            "eclipseSharesServicesAcrossProfilesV1",
            "githubReleaseAutoCheckEnabled",
            "autoClearCacheEnabled",
            "showKanzen",
            "eclipseOnboardingCompletedV1"
        ] {
            XCTAssertEqual(
                EclipseSettingsRegistry.scope(for: key), .device,
                "\(key) should resolve to the device store"
            )
        }
    }

    func testOnboardingCompletionFlagStaysOnTheDevice() {
        XCTAssertTrue(
            EclipseSettingsRegistry.deviceKeys.contains(OnboardingState.completedKey),
            "\(OnboardingState.completedKey) is not listed in deviceKeys"
        )
        XCTAssertEqual(EclipseSettingsRegistry.scope(for: OnboardingState.completedKey), .device)
    }

    static let extraSourceSettingsKeys: [String] = [
        ServicesSheetPresentationSettings.stremioStyleEnabledKey,
        ServicesResultRankingSettings.minimumSimilarityKey,
        ServicesResultRankingSettings.dropMismatchedResultsKey,
        StreamLanguageFilter.includedLanguagesKey,
        StreamLanguageFilter.storageKey,
        StreamLanguageFilter.hideUnknownLanguageStreamsKey,
        StreamLanguageFilter.assumeOriginalAudioKey,
        StreamLanguageFilter.treatDubbedAnimeAsEnglishKey,
        StreamLanguageFilter.hiddenStreamQualitiesKey,
        StreamLanguageFilter.hideUnknownQualityStreamsKey,
        StreamLanguageFilter.extraRulesSourceIdsKey
    ]

    func testEveryExtraSourceSettingIsClassifiedInBothRegistries() {
        for key in Self.extraSourceSettingsKeys {
            XCTAssertEqual(
                EclipseSettingsRegistry.scope(for: key), .services,
                "\(key) should resolve to the services store"
            )
        }

        let unsynced = Self.extraSourceSettingsKeys
            .filter { !MediaStateSettingRegistry.allKeys.contains($0) }
            .sorted()
        XCTAssertTrue(
            unsynced.isEmpty,
            "Extra Source Settings keys missing from MediaStateSettingRegistry: \(unsynced)"
        )
    }

    func testAddonSubtitleBlockingCombinesGlobalAndPerSourceSettings() throws {
        let suiteName = "SettingsScopeTests.SubtitleBlocking.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstSource = "stremio:first"
        let secondSource = "stremio:second"
        XCTAssertTrue(StremioAddonComponentSettings.allowsSubtitles(sourceID: firstSource, defaults: defaults))
        for globallyBlocked in [false, true] {
            ContentBlockingSettings.setBlocksAddonSubtitles(globallyBlocked, defaults: defaults)
            for componentEnabled in [false, true] {
                StremioAddonComponentSettings.setEnabled(
                    componentEnabled, sourceID: firstSource, component: .subtitles, defaults: defaults
                )
                XCTAssertEqual(
                    StremioAddonComponentSettings.allowsSubtitles(sourceID: firstSource, defaults: defaults),
                    !globallyBlocked && componentEnabled
                )
                XCTAssertEqual(
                    StremioAddonComponentSettings.allowsSubtitles(sourceID: secondSource, defaults: defaults),
                    !globallyBlocked
                )
            }
        }
        ContentBlockingSettings.setBlocksAddonSubtitles(false, defaults: defaults)
        ContentBlockingSettings.setBlocksAddonCatalogs(true, defaults: defaults)
        StremioAddonComponentSettings.setEnabled(false, sourceID: firstSource, component: .catalogs, defaults: defaults)
        XCTAssertTrue(StremioAddonComponentSettings.allowsSubtitles(sourceID: firstSource, defaults: defaults))
        XCTAssertTrue(ContentBlockingSettings.blocksAddonCatalogs(defaults: defaults))
        for key in [ContentBlockingSettings.blockAddonSubtitlesKey, ContentBlockingSettings.blockAddonCatalogsKey] {
            XCTAssertEqual(EclipseSettingsRegistry.scope(for: key), .services)
        }
    }

    func testExtraSourceSettingValuesAreAdmittedWithTheirRealTypes() {
        for key in [
            ServicesSheetPresentationSettings.stremioStyleEnabledKey,
            ServicesResultRankingSettings.dropMismatchedResultsKey,
            StreamLanguageFilter.hideUnknownLanguageStreamsKey,
            StreamLanguageFilter.assumeOriginalAudioKey,
            StreamLanguageFilter.treatDubbedAnimeAsEnglishKey,
            StreamLanguageFilter.hideUnknownQualityStreamsKey
        ] {
            XCTAssertNotNil(admittedValue(true, forKey: key), "\(key) should admit a Bool")
            XCTAssertNil(admittedValue("true", forKey: key), "\(key) should reject a String")
        }

        let similarityKey = ServicesResultRankingSettings.minimumSimilarityKey
        let range = ServicesResultRankingSettings.minimumSimilarityRange
        XCTAssertNotNil(admittedValue(range.lowerBound, forKey: similarityKey))
        XCTAssertNotNil(admittedValue(range.upperBound, forKey: similarityKey))
        XCTAssertNotNil(
            admittedValue(ServicesResultRankingSettings.defaultMinimumSimilarity, forKey: similarityKey)
        )
        XCTAssertNil(admittedValue(range.lowerBound - 0.01, forKey: similarityKey))
        XCTAssertNil(admittedValue(range.upperBound + 0.01, forKey: similarityKey))
        XCTAssertNil(admittedValue("0.85", forKey: similarityKey))
    }

    private func admittedValue(_ value: Any, forKey key: String) -> Any? {
        guard PropertyListSerialization.propertyList(value, isValidFor: .binary),
              let data = try? PropertyListSerialization.data(
                fromPropertyList: value,
                format: .binary,
                options: 0
              ) else {
            XCTFail("could not encode a property list value for \(key)")
            return nil
        }
        return MediaStateSettingValueValidator.validatedValue(from: data, forKey: key)
    }

    func testUnknownKeysDefaultToProfile() {
        XCTAssertNil(EclipseSettingsRegistry.explicitScope(for: "someKeyNobodyClassifiedYet"))
        XCTAssertEqual(EclipseSettingsRegistry.scope(for: "someKeyNobodyClassifiedYet"), .profile)
    }

    func testPlayerNumericSettingsRejectNonFiniteAndBoundLegacyValues() {
        let range = 5.0...60.0
        XCTAssertEqual(
            PlayerSettingsStore.sanitizedNumericSetting(.nan, default: 10, range: range),
            10
        )
        XCTAssertEqual(
            PlayerSettingsStore.sanitizedNumericSetting(.infinity, default: 10, range: range),
            10
        )
        XCTAssertEqual(
            PlayerSettingsStore.sanitizedNumericSetting(-.infinity, default: 10, range: range),
            10
        )
        XCTAssertEqual(
            PlayerSettingsStore.sanitizedNumericSetting(1, default: 10, range: range),
            5
        )
        XCTAssertEqual(
            PlayerSettingsStore.sanitizedNumericSetting(500, default: 10, range: range),
            60
        )
        XCTAssertEqual(
            PlayerSettingsStore.sanitizedNumericSetting(25, default: 10, range: range),
            25
        )
    }

    func testServiceSimilarityAndCacheThresholdRejectNonFiniteLegacyValues() {
        XCTAssertEqual(
            ServicesResultRankingSettings.clampedMinimumSimilarity(.nan),
            ServicesResultRankingSettings.defaultMinimumSimilarity
        )
        XCTAssertEqual(
            ServicesResultRankingSettings.clampedMinimumSimilarity(.infinity),
            ServicesResultRankingSettings.defaultMinimumSimilarity
        )

        XCTAssertEqual(
            CacheManager.sanitizedAutoClearThresholdMB(.nan),
            CacheManager.defaultAutoClearThresholdMB
        )
        XCTAssertEqual(
            CacheManager.sanitizedAutoClearThresholdMB(.infinity),
            CacheManager.defaultAutoClearThresholdMB
        )
        XCTAssertEqual(CacheManager.sanitizedAutoClearThresholdMB(1), 100)
        XCTAssertEqual(CacheManager.sanitizedAutoClearThresholdMB(50_000), 5_000)
        XCTAssertEqual(CacheManager.autoClearThresholdBytes(for: .nan), 500_000_000)
    }

    func testMangaRetryDelayRejectsNonFiniteAndNegativeHeaders() {
        XCTAssertEqual(AniListMangaService.boundedRetryDelay("nan", fallback: 2), 2)
        XCTAssertEqual(AniListMangaService.boundedRetryDelay("inf", fallback: 2), 2)
        XCTAssertEqual(AniListMangaService.boundedRetryDelay("-1", fallback: 2), 2)
        XCTAssertEqual(AniListMangaService.boundedRetryDelay("1e300", fallback: 2), 10)
        XCTAssertEqual(AniListMangaService.boundedRetryDelay("3", fallback: 2), 3)
    }

    func testLevenshteinRollingRowsPreserveDistanceForLongProviderTitles() {
        XCTAssertEqual(LevenshteinDistance.levenshteinDistance("kitten", "sitting"), 3)
        XCTAssertEqual(LevenshteinDistance.levenshteinDistance("", "title"), 5)
        XCTAssertEqual(LevenshteinDistance.levenshteinDistance("same", "same"), 0)

        let longTitle = String(repeating: "a", count: 2_048)
        let oneCharacterDifferent = String(repeating: "a", count: 2_047) + "b"
        XCTAssertEqual(
            LevenshteinDistance.levenshteinDistance(longTitle, oneCharacterDifferent),
            1
        )
        XCTAssertEqual(
            LevenshteinDistance.levenshteinDistance(oneCharacterDifferent, longTitle),
            1
        )
    }

    func testServicesSearchTargetsRouteToTheirDedicatedSettingsPages() {
        let autoModeTargets: [ServicesSettingsSearchTarget] = [
            .autoMode,
            .autoSelectEpisodes,
            .autoQuality,
            .autoQualityPreference,
            .autoModeErrorIntelligence
        ]
        for target in autoModeTargets {
            XCTAssertTrue(target.opensAutoModeSettings, "\(target) should open Auto Mode settings")
            XCTAssertFalse(target.opensExtraServiceSettings)
        }

        let extraSettingsTargets: [ServicesSettingsSearchTarget] = [
            .blockAddonSubtitles,
            .blockAddonCatalogs,
            .stremioStyleSheet,
            .rankingSimilarity,
            .languagesToInclude,
            .qualitiesToHide,
            .applyExtraRulesTo
        ]
        for target in extraSettingsTargets {
            XCTAssertTrue(target.opensExtraServiceSettings, "\(target) should open Extra Source Settings")
            XCTAssertFalse(target.opensAutoModeSettings)
        }

        XCTAssertFalse(ServicesSettingsSearchTarget.autoUpdateServices.opensAutoModeSettings)
        XCTAssertFalse(ServicesSettingsSearchTarget.autoUpdateServices.opensExtraServiceSettings)
        XCTAssertFalse(ServicesSettingsSearchTarget.installedSource("test").opensAutoModeSettings)
        XCTAssertFalse(ServicesSettingsSearchTarget.installedSource("test").opensExtraServiceSettings)
    }
}
#endif

#if os(iOS)
final class CoreAuditRegressionTests: XCTestCase {
    func testAppHubOnboardingFlagsRemainDeviceScopedAcrossProfileChoices() {
        for key in ["eclipseOnboardingCompletedV1", "eclipseAppHubNoticeSeenV1", "eclipseAppHubHintPendingV1"] {
            XCTAssertEqual(EclipseSettingsRegistry.explicitScope(for: key), .device)
            XCTAssertFalse(MediaStateSettingRegistry.allKeys.contains(key))
        }
        for key in ["experimentalMediaDesignPreset", "experimentalHeroHeightScale", "defaultPlaybackSpeed"] {
            XCTAssertEqual(EclipseSettingsRegistry.scope(for: key), .profile)
        }
    }

    func testNotificationLaneDrainsCanceledCallbackBurstWithoutOverlappingWrites() async {
        actor Probe {
            var active = 0
            var maximum = 0
            var completed = Set<Int>()
            func enter() { active += 1; maximum = max(maximum, active) }
            func leave(_ id: Int) { active -= 1; completed.insert(id) }
            func snapshot() -> (Int, Int, Set<Int>) { (active, maximum, completed) }
        }
        let lane = LocalNotificationWriteCoordinator()
        let probe = Probe()
        await lane.acquire()
        let tasks = (0..<256).map { id in
            Task {
                await lane.acquire()
                if !Task.isCancelled {
                    await probe.enter()
                    await Task.yield()
                    await probe.leave(id)
                }
                await lane.release()
            }
        }
        for id in stride(from: 0, to: tasks.count, by: 2) { tasks[id].cancel() }
        await lane.release()
        for task in tasks { await task.value }
        await lane.acquire()
        await probe.enter()
        await probe.leave(256)
        await lane.release()
        let result = await probe.snapshot()
        XCTAssertEqual(result.0, 0)
        XCTAssertEqual(result.1, 1)
        XCTAssertEqual(result.2, Set(stride(from: 1, to: 256, by: 2)).union([256]))
    }

    func testScheduleWindowsCoverEveryTimeZoneAtSeasonAndYearBoundaries() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let dates = [
            DateComponents(year: 2026, month: 1, day: 1, hour: 0),
            DateComponents(year: 2026, month: 3, day: 8, hour: 7),
            DateComponents(year: 2026, month: 4, day: 5, hour: 15),
            DateComponents(year: 2026, month: 10, day: 25, hour: 1),
            DateComponents(year: 2026, month: 11, day: 1, hour: 6),
            DateComponents(year: 2026, month: 12, day: 31, hour: 23)
        ].map { utc.date(from: $0) }
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
            for candidate in dates {
                let now = try XCTUnwrap(candidate)
                for days in [1, 7, 30, 366] {
                    let window = ScheduleDateWindow.envelope(dayCount: days, now: now, localCalendar: local)
                    for calendar in [utc, local] {
                        let start = calendar.startOfDay(for: now)
                        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: days, to: start))
                        XCTAssertLessThanOrEqual(window.start, start, identifier)
                        XCTAssertGreaterThanOrEqual(window.end, end, identifier)
                    }
                    XCTAssertGreaterThan(window.duration, 0)
                    XCTAssertLessThan(window.duration, Double(days + 2) * 86_400)
                }
                XCTAssertEqual(ScheduleDateWindow.envelope(dayCount: 0, now: now, localCalendar: local), ScheduleDateWindow.envelope(dayCount: 1, now: now, localCalendar: local))
                XCTAssertEqual(ScheduleDateWindow.envelope(dayCount: 400, now: now, localCalendar: local), ScheduleDateWindow.envelope(dayCount: 366, now: now, localCalendar: local))
            }
        }
    }

    func testNotificationSelectionEpochRejectsRoundTripProfileSwitch() {
        let epoch = LocalNotificationSelectionEpoch()
        let original = epoch.capture()
        epoch.advance()
        epoch.advance()
        XCTAssertFalse(epoch.isCurrent(original))
        XCTAssertTrue(epoch.isCurrent(epoch.capture()))
    }

    func testNotificationWriteLanePreservesNewerRequestAfterStaleCleanup() async {
        let lane = LocalNotificationWriteCoordinator()
        actor Requests {
            var pending: String?
            func write(_ value: String) { pending = value }
            func remove() { pending = nil }
            func current() -> String? { pending }
        }
        let requests = Requests()
        await lane.acquire()
        let newer = Task {
            await lane.acquire()
            await requests.write("newer revision")
            await lane.release()
        }
        await requests.write("stale revision")
        await requests.remove()
        await lane.release()
        await newer.value
        let retained = await requests.current()
        XCTAssertEqual(retained, "newer revision")
    }

    func testNotificationDecisionWaitsForVisibleStaleRequestCleanup() async {
        let lane = LocalNotificationWriteCoordinator()
        actor Requests {
            var pending: String?
            var decisions = 0
            func makeStaleVisible() { pending = "stale" }
            func cleanup() { pending = nil }
            func decide() { decisions += 1; if pending == nil { pending = "newer" } }
            func result() -> (String?, Int) { (pending, decisions) }
        }
        let requests = Requests()
        await lane.acquire()
        await requests.makeStaleVisible()
        let newer = Task {
            await lane.acquire()
            await requests.decide()
            await lane.release()
        }
        await requests.cleanup()
        await lane.release()
        await newer.value
        let result = await requests.result()
        XCTAssertEqual(result.0, "newer")
        XCTAssertEqual(result.1, 1)
    }

    func testClearAllCleanupRemovesOldRequestsAndPreservesLaterReenable() {
        let generation = UUID()
        XCTAssertTrue(LocalNotificationRequestRevision.canRemove(storedGeneration: nil, storedRevision: nil, generation: generation, revision: 3))
        XCTAssertTrue(LocalNotificationRequestRevision.canRemove(storedGeneration: UUID().uuidString, storedRevision: 100, generation: generation, revision: 3))
        XCTAssertTrue(LocalNotificationRequestRevision.canRemove(storedGeneration: generation.uuidString, storedRevision: 2, generation: generation, revision: 3))
        XCTAssertFalse(LocalNotificationRequestRevision.canRemove(storedGeneration: generation.uuidString, storedRevision: 4, generation: generation, revision: 3))
    }

    func testUnreadableNotificationSelectionsDifferFromMissingAndEmpty() throws {
        let suite = "core-audit-notifications-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let decoder = JSONDecoder()
        let key = LocalNotificationManager.subscriptionsStorageKey
        XCTAssertTrue(LocalNotificationSelectionStorage.read([Int].self, key: key, store: store, decoder: decoder).isReadable)
        store.set("[", forKey: key)
        XCTAssertFalse(LocalNotificationSelectionStorage.read([Int].self, key: key, store: store, decoder: decoder).isReadable)
        XCTAssertEqual(store.string(forKey: key), "[")
        store.set(42, forKey: key)
        XCTAssertFalse(LocalNotificationSelectionStorage.read([Int].self, key: key, store: store, decoder: decoder).isReadable)
        store.set("[]", forKey: key)
        let empty = LocalNotificationSelectionStorage.read([Int].self, key: key, store: store, decoder: decoder)
        XCTAssertTrue(empty.isReadable)
        XCTAssertEqual(empty.value, [])
    }

    func testDeliveredLeadReminderSurvivesRelaunchWithoutAirtimeDuplicate() throws {
        let event = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = LocalNotificationScheduledOccurrence(fireDate: event.addingTimeInterval(-3600), eventDate: event)
        let restored = try JSONDecoder().decode(LocalNotificationScheduledOccurrence.self, from: JSONEncoder().encode(occurrence))
        XCTAssertFalse(restored.suppresses(eventDate: event, now: event.addingTimeInterval(-3601)))
        XCTAssertTrue(restored.suppresses(eventDate: event, now: event.addingTimeInterval(-1800)))
        XCTAssertFalse(restored.suppresses(eventDate: event.addingTimeInterval(86400), now: event.addingTimeInterval(-1800)))
    }

    func testScheduleProviderIdentitiesDoNotCollide() {
        let trakt = ScheduleProvider.trakt.metadataCacheKey(mediaID: 42, tmdbID: nil, entryID: "episode")
        let tvMaze = ScheduleProvider.tvMaze.metadataCacheKey(mediaID: 42, tmdbID: nil, entryID: "episode")
        XCTAssertNotEqual(trakt, tvMaze)
        XCTAssertNotEqual(trakt, ScheduleProvider.aniList.metadataCacheKey(mediaID: 42, tmdbID: nil, entryID: "episode"))
        XCTAssertEqual(ScheduleProvider.trakt.metadataCacheKey(mediaID: 42, tmdbID: 100, entryID: "episode"), "tmdb-tv-100")
        XCTAssertNotEqual(ScheduleProvider.trakt.metadataCacheKey(mediaID: 0, tmdbID: nil, entryID: "a"), ScheduleProvider.trakt.metadataCacheKey(mediaID: 0, tmdbID: nil, entryID: "b"))
    }

    func testScheduleEnvelopeIncludesLocalAndUTCBucketEdgesAcrossDST() throws {
        for zone in ["Pacific/Kiritimati", "Pacific/Honolulu", "America/New_York", "Europe/London"] {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            for timestamp: TimeInterval in [1_773_000_000, 1_793_520_000, 2_000_000_000] {
                let now = Date(timeIntervalSince1970: timestamp)
                let envelope = ScheduleDateWindow.envelope(dayCount: 7, now: now, localCalendar: local)
                for calendar in [local, utc] {
                    let start = calendar.startOfDay(for: now)
                    let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: start))
                    XCTAssertLessThanOrEqual(envelope.start, start)
                    XCTAssertGreaterThanOrEqual(envelope.end, end)
                }
                XCTAssertLessThan(envelope.duration, 9 * 86400)
            }
        }
    }

    func testFeaturedGenresUseTVIdentifiersAndKeepMovieCategories() {
        let supportedTV = Set([10759, 16, 35, 80, 99, 18, 10751, 10762, 9648, 10763, 10764, 10765, 10766, 10767, 10768, 37])
        XCTAssertTrue(Set(WidgetGenre.tvCurated.map(\.id)).isSubset(of: supportedTV))
        XCTAssertTrue(Set(WidgetGenre.kidsTVCurated.map(\.id)).isSubset(of: supportedTV))
        XCTAssertTrue(WidgetGenre.curated.contains { $0.id == 28 })
        XCTAssertTrue(WidgetGenre.curated.contains { $0.id == 878 })
        XCTAssertTrue(WidgetGenre.tvCurated.contains { $0.id == 10759 })
        XCTAssertTrue(WidgetGenre.tvCurated.contains { $0.id == 10765 })
    }

    @MainActor
    func testHomeResetClearsCarouselBackingItems() {
        let model = HomeViewModel()
        model.catalogResults["trending"] = [homeItem(1), homeItem(2)]
        model.refreshHeroContentForSettingsChange()
        XCTAssertEqual(model.heroCarouselCount, 2)
        model.resetContent(invalidateRecommendations: false)
        model.advanceHeroCarouselIfNeeded()
        XCTAssertEqual(model.heroCarouselCount, 0)
        XCTAssertTrue(model.upcomingHeroCarouselItems(limit: 2).isEmpty)
        XCTAssertNil(model.heroContent)
    }

    @MainActor
    func testHomeVisibleRefreshRetainsCarouselUntilReplacement() {
        let model = HomeViewModel()
        model.catalogResults["trending"] = [homeItem(1), homeItem(2)]
        model.refreshHeroContentForSettingsChange()
        model.resetContent(preserveVisibleContent: true, invalidateRecommendations: false)
        XCTAssertEqual(model.heroCarouselCount, 2)
        XCTAssertNotNil(model.heroContent)
        model.catalogResults = [:]
        model.refreshHeroContentForSettingsChange()
        XCTAssertEqual(model.heroCarouselCount, 0)
        XCTAssertNil(model.heroContent)
    }

    private func homeItem(_ id: Int) -> TMDBSearchResult {
        TMDBSearchResult(id: id, mediaType: "tv", title: nil, name: "Fixture \(id)", overview: "", posterPath: nil, backdropPath: nil, releaseDate: nil, firstAirDate: nil, voteAverage: 8, popularity: 1, adult: false, genreIds: [35])
    }
}
#endif
