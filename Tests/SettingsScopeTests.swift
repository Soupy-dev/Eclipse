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
