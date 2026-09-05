import XCTest
@testable import Eclipse

final class PlatformCapabilitiesTests: XCTestCase {
    func testTVRuntimeConfigurationUsesBuildOverrides() {
        let requiredKeys = [
            "TMDBAPIKey",
            "AniListClientID",
            "AniListClientSecret",
            "AniListRedirectUri",
            "TraktClientID",
            "TraktClientSecret",
            "TraktRedirectUri",
            "MALClientID",
            "MALClientSecret",
            "MALRedirectUri"
        ]

        for key in requiredKeys {
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
            XCTAssertNotNil(value, "Missing tvOS runtime configuration key: \(key)")
            XCTAssertFalse(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            XCTAssertFalse(value?.contains("$(") ?? true, "Unexpanded tvOS build setting: \(key)")
        }
    }

    func testCurrentTVCapabilitiesExcludeReaderDownloadsAndTouchFeatures() {
        let capabilities = PlatformCapabilities.current

        XCTAssertEqual(capabilities.platform, .tvOS)
        XCTAssertFalse(capabilities.supportsReader)
        XCTAssertFalse(capabilities.supportsDownloads)
        XCTAssertFalse(capabilities.supportsBrowserAutomation)
        XCTAssertFalse(capabilities.supportsFileSharing)
        XCTAssertFalse(capabilities.supportsTouchInput)
        XCTAssertFalse(capabilities.supportsCellularSettings)
        XCTAssertFalse(capabilities.supportsExternalPlayers)
        XCTAssertFalse(capabilities.supportsGitHubUpdates)
        XCTAssertFalse(capabilities.supportsSkyStreamPlugins)
        XCTAssertFalse(capabilities.supportsNuvioPlugins)
        XCTAssertTrue(capabilities.supportsMPV)
        XCTAssertTrue(capabilities.supportsCloudKit)
    }

    func testReaderAndIOSSettingsAreHiddenOnTV() {
        let reader = SettingDescriptor(id: "reader", title: "Reader", scope: .reader)
        let cellular = SettingDescriptor(id: "cellular", title: "Cellular", scope: .iOS)
        let tvDensity = SettingDescriptor(id: "density", title: "Card Density", scope: .tvOS)

        XCTAssertFalse(reader.availability().isAvailable)
        XCTAssertFalse(cellular.availability().isAvailable)
        XCTAssertTrue(tvDensity.availability().isAvailable)
    }

    func testRequiredCapabilityDrivesVisibilityFromSameSourceOfTruth() {
        let downloads = SettingDescriptor(
            id: "downloads",
            title: "Downloads",
            requiredCapability: \.supportsDownloads
        )
        let cloudSync = SettingDescriptor(
            id: "cloud-sync",
            title: "Cloud Sync",
            requiredCapability: \.supportsCloudKit
        )

        XCTAssertFalse(downloads.availability().isAvailable)
        XCTAssertTrue(cloudSync.availability().isAvailable)
    }

    func testTVMediaStateRegistryUsesTheRuntimePlaybackKeys() {
        XCTAssertNotNil(MediaStateSettingRegistry.scope(for: PlaybackEngine.defaultsKey))
        XCTAssertNotNil(MediaStateSettingRegistry.scope(for: "playerDoubleTapSeekSeconds"))
        XCTAssertNotNil(MediaStateSettingRegistry.scope(for: "tmdbLanguage"))
        XCTAssertNil(MediaStateSettingRegistry.scope(for: "preferredTMDBLanguage"))
    }

    func testTVTraktDismissalAndLateCodeKeepReplacementSignIn() throws {
        let first = UUID()
        let second = UUID()
        let url = try XCTUnwrap(URL(string: "https://trakt.tv/activate"))
        let firstCode = TVTraktSignInPresentation(id: first, userCode: "AAAA1111", verificationURL: url)
        let secondCode = TVTraktSignInPresentation(id: second, userCode: "BBBB2222", verificationURL: url)
        var state = TVTraktSignInState()

        state.begin(authenticationID: first)
        XCTAssertTrue(state.present(firstCode))
        state.begin(authenticationID: second)
        XCTAssertNil(state.presentation)
        XCTAssertFalse(state.finish(authenticationID: first))
        XCTAssertFalse(state.present(firstCode))
        XCTAssertEqual(state.authenticationID, second)
        XCTAssertTrue(state.present(secondCode))
        XCTAssertFalse(state.finish(authenticationID: first))
        XCTAssertEqual(state.presentation, secondCode)
        XCTAssertTrue(state.finish(authenticationID: second))
        XCTAssertNil(state.authenticationID)
        XCTAssertNil(state.presentation)
        XCTAssertFalse(state.present(secondCode))
    }

    func testTVTraktProfileRoundTripCannotRevivePriorSignIn() throws {
        let originalRequest = UUID()
        let returnedProfileRequest = UUID()
        let url = try XCTUnwrap(URL(string: "https://auth.trakt.tv/activate"))
        var state = TVTraktSignInState()
        state.begin(authenticationID: originalRequest)
        state.invalidateForProfileChange()
        state.invalidateForProfileChange()

        XCTAssertNil(state.authenticationID)
        XCTAssertFalse(state.present(TVTraktSignInPresentation(
            id: originalRequest,
            userCode: "AAAA1111",
            verificationURL: url
        )))
        state.begin(authenticationID: returnedProfileRequest)
        XCTAssertFalse(state.finish(authenticationID: originalRequest))
        XCTAssertEqual(state.authenticationID, returnedProfileRequest)
        XCTAssertTrue(state.present(TVTraktSignInPresentation(
            id: returnedProfileRequest,
            userCode: "BBBB2222",
            verificationURL: url
        )))
    }

    func testTVTraktDeviceResponseRejectsUnsafeURLsAndUnboundedTiming() throws {
        let valid: [String: Any] = [
            "device_code": "device-code",
            "user_code": "ABCD1234",
            "verification_url": "https://trakt.tv/activate",
            "expires_in": 600,
            "interval": 5
        ]
        func decode(_ response: [String: Any]) throws -> TrackerManager.TraktDeviceCodeResponse {
            try JSONDecoder().decode(
                TrackerManager.TraktDeviceCodeResponse.self,
                from: JSONSerialization.data(withJSONObject: response)
            )
        }
        var currentHost = valid
        currentHost["verification_url"] = "https://auth.trakt.tv/activate"
        XCTAssertNoThrow(try decode(currentHost))
        let accepted = try decode(valid)
        XCTAssertEqual(accepted.expiresIn, 600)
        XCTAssertEqual(accepted.interval, 5)
        for (key, value) in [
            ("expires_in", 0 as Any),
            ("expires_in", 3601 as Any),
            ("expires_in", Int.max as Any),
            ("interval", 0 as Any),
            ("interval", 61 as Any),
            ("device_code", String(repeating: "a", count: 4097) as Any),
            ("user_code", String(repeating: "A", count: 33) as Any),
            ("user_code", "ABCD\n1234" as Any),
            ("verification_url", "http://trakt.tv/activate" as Any),
            ("verification_url", "https://trakt.tv.example/activate" as Any),
            ("verification_url", "https://auth.trakt.tv.example/activate" as Any),
            ("verification_url", "https://user:password@trakt.tv/activate" as Any),
            ("verification_url", "https://trakt.tv/activate?redirect=https://example.com" as Any)
        ] {
            var response = valid
            response[key] = value
            XCTAssertThrowsError(try decode(response), "Accepted invalid \(key)")
        }
        var expiresBeforeFirstPoll = valid
        expiresBeforeFirstPoll["expires_in"] = 4
        XCTAssertThrowsError(try decode(expiresBeforeFirstPoll))
    }

    func testTVTraktHTTPFailuresStayActionableWithoutReadingErrorBodies() {
        XCTAssertEqual(TVTraktDeviceAuthBoundary.serverError(status: 403).code, 403)
        XCTAssertTrue(TVTraktDeviceAuthBoundary.serverError(status: 403).localizedDescription.contains("another network"))
        XCTAssertTrue(TVTraktDeviceAuthBoundary.serverError(status: 429).localizedDescription.contains("Wait"))
        XCTAssertTrue(TVTraktDeviceAuthBoundary.serverError(status: 503).localizedDescription.contains("unavailable"))
    }

    func testTVTraktTokenBoundaryRejectsHeaderControlsAndOversizedCredentials() {
        func token(accessToken: String = "access", refreshToken: String = "refresh", expiresIn: Int = 7776000) -> TraktAuthResponse {
            TraktAuthResponse(accessToken: accessToken, tokenType: "bearer", expiresIn: expiresIn, refreshToken: refreshToken)
        }
        XCTAssertTrue(TVTraktDeviceAuthBoundary.validToken(token()))
        XCTAssertFalse(TVTraktDeviceAuthBoundary.validToken(token(accessToken: "")))
        XCTAssertFalse(TVTraktDeviceAuthBoundary.validToken(token(accessToken: "access\r\nheader")))
        XCTAssertFalse(TVTraktDeviceAuthBoundary.validToken(token(refreshToken: String(repeating: "x", count: 8193))))
        XCTAssertFalse(TVTraktDeviceAuthBoundary.validToken(token(expiresIn: 0)))
        XCTAssertFalse(TVTraktDeviceAuthBoundary.validToken(token(expiresIn: Int.max)))
    }

    func testTVEngineDefaultsAndLegacyAutomaticResolveToMPV() throws {
        let suiteName = "tv-engine-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(PlaybackEngine.availableSelections(deviceFamily: .television), [.mpv, .avPlayer])
        XCTAssertEqual(PlaybackEngine.selected(defaults: defaults), .mpv)
        defaults.set("automatic", forKey: PlaybackEngine.defaultsKey)
        XCTAssertEqual(PlaybackEngine.selected(defaults: defaults), .mpv)
        XCTAssertEqual(defaults.string(forKey: PlaybackEngine.defaultsKey), "mpv")
        XCTAssertEqual(
            PlaybackLaunchPlan.make(selection: .automatic, deviceFamily: .television),
            PlaybackLaunchPlan(primary: .mpv, preStartFallback: nil)
        )
        defaults.removeObject(forKey: PlaybackEngine.defaultsKey)
        defaults.set("auto", forKey: "inAppPlayer")
        XCTAssertEqual(PlaybackEngine.selected(defaults: defaults), .mpv)
        PlaybackEngine.setSelected(.avPlayer, defaults: defaults)
        XCTAssertEqual(PlaybackEngine.selected(defaults: defaults), .avPlayer)
        XCTAssertEqual(
            PlaybackLaunchPlan.make(selection: .automatic, deviceFamily: .pad),
            PlaybackLaunchPlan(primary: .avPlayer, preStartFallback: .mpv)
        )
    }

    func testTVUpscalingTargetDefaultsAndInvalidValuesStayBounded() throws {
        let suiteName = "tv-upscaling-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(MPVTVUpscalingTarget.selected(defaults: defaults), .display)
        defaults.set("8k", forKey: MPVTVUpscalingTarget.defaultsKey)
        XCTAssertEqual(MPVTVUpscalingTarget.selected(defaults: defaults), .display)
        defaults.set(-1, forKey: MPVTVUpscalingTarget.defaultsKey)
        XCTAssertEqual(MPVTVUpscalingTarget.selected(defaults: defaults), .display)
        defaults.set(MPVTVUpscalingTarget.hd1080.rawValue, forKey: MPVTVUpscalingTarget.defaultsKey)
        XCTAssertEqual(MPVTVUpscalingTarget.selected(defaults: defaults), .hd1080)
        XCTAssertEqual(MPVTVUpscalingTarget.hd1080.maximumDrawablePixelCount, 2_073_600)
        XCTAssertEqual(MPVTVUpscalingTarget.qhd1440.maximumDrawablePixelCount, 3_686_400)
        XCTAssertEqual(MPVTVUpscalingTarget.uhd4K.maximumDrawablePixelCount, 8_294_400)
        XCTAssertEqual(MPVTVUpscalingTarget.display.maximumDrawablePixelCount, 0)
        XCTAssertEqual(EclipseSettingsRegistry.scope(for: MPVTVUpscalingTarget.defaultsKey), .profile)
    }

    func testTVComfortAudioCategoryKeepsAnimePrecedence() {
        XCTAssertEqual(AudioComfortContentCategory.resolved(isAnime: true, isAnimation: true), .anime)
        XCTAssertEqual(AudioComfortContentCategory.resolved(isAnime: true, isAnimation: false), .anime)
        XCTAssertEqual(AudioComfortContentCategory.resolved(isAnime: false, isAnimation: true), .westernAnimation)
        XCTAssertEqual(AudioComfortContentCategory.resolved(isAnime: false, isAnimation: false), .liveAction)
    }

    func testAutomaticPlaybackFallsBackOnlyBeforeFirstFrameAndOnlyOnce() {
        XCTAssertEqual(
            PlaybackFallbackPolicy.decision(
                requestedEngine: .automatic,
                playbackDidStart: false,
                hasAttemptedAutomaticFallback: false
            ),
            .retryAutomaticallyWithAVPlayer
        )
        XCTAssertEqual(
            PlaybackFallbackPolicy.decision(
                requestedEngine: .automatic,
                playbackDidStart: false,
                hasAttemptedAutomaticFallback: true
            ),
            .terminalError
        )
        XCTAssertEqual(
            PlaybackFallbackPolicy.decision(
                requestedEngine: .automatic,
                playbackDidStart: true,
                hasAttemptedAutomaticFallback: false
            ),
            .offerManualAVPlayerRetry
        )
    }

    func testExplicitMPVFailureOffersManualAVPlayerRetry() {
        XCTAssertEqual(
            PlaybackFallbackPolicy.decision(
                requestedEngine: .mpv,
                playbackDidStart: false,
                hasAttemptedAutomaticFallback: false
            ),
            .offerManualAVPlayerRetry
        )
    }

    func testTVNextEpisodeRequiresExplicitPlayNextSelection() {
        let threshold = TVNextEpisodePolicy.transition(
            from: .watching,
            event: .thresholdReached,
            hasNextEpisode: true
        )
        XCTAssertEqual(threshold.state, .promptingNearEnd)
        XCTAssertEqual(threshold.action, .showPrompt(atNaturalEnd: false))

        let keepWatching = TVNextEpisodePolicy.transition(
            from: threshold.state,
            event: .keepWatching,
            hasNextEpisode: true
        )
        XCTAssertEqual(keepWatching.state, .declinedNearEnd)
        XCTAssertEqual(keepWatching.action, .hidePrompt(resumePlayback: true))

        let ended = TVNextEpisodePolicy.transition(
            from: keepWatching.state,
            event: .naturalEnd,
            hasNextEpisode: true
        )
        XCTAssertEqual(ended.state, .promptingAtEnd)
        XCTAssertEqual(ended.action, .showPrompt(atNaturalEnd: true))

        let playNext = TVNextEpisodePolicy.transition(
            from: ended.state,
            event: .playNext,
            hasNextEpisode: true
        )
        XCTAssertEqual(playNext.state, .playNextSelected)
        XCTAssertEqual(playNext.action, .playNext)
    }

    func testTVNextEpisodeBackNeverLaunchesAndNaturalEndWaitsForChoice() {
        let ended = TVNextEpisodePolicy.transition(
            from: .watching,
            event: .naturalEnd,
            hasNextEpisode: true
        )
        XCTAssertEqual(ended.action, .showPrompt(atNaturalEnd: true))

        let back = TVNextEpisodePolicy.transition(
            from: ended.state,
            event: .back,
            hasNextEpisode: true
        )
        XCTAssertEqual(back.state, .declinedAtEnd)
        XCTAssertEqual(back.action, .hidePrompt(resumePlayback: false))
        XCTAssertNotEqual(back.action, .playNext)

        let automaticProgress = TVNextEpisodePolicy.transition(
            from: .declinedAtEnd,
            event: .thresholdReached,
            hasNextEpisode: true
        )
        XCTAssertEqual(automaticProgress.action, .none)
    }

    func testPlaybackSpeedPolicyUsesMPVAndAVPlayerClamp() {
        XCTAssertEqual(PlaybackSpeedPolicy.normalized(0), 1)
        XCTAssertEqual(PlaybackSpeedPolicy.normalized(.nan), 1)
        XCTAssertEqual(PlaybackSpeedPolicy.normalized(0.1), 0.25)
        XCTAssertEqual(PlaybackSpeedPolicy.normalized(1.5), 1.5)
        XCTAssertEqual(PlaybackSpeedPolicy.normalized(8), 3)
    }

    func testPlaybackRequestCarriesMediaSelectionIntentAcrossEngineFallback() throws {
        let intent = PlaybackMediaSelectionIntent(
            preferredAudioLanguage: "ja-JP",
            preferredSubtitleLanguage: "en-US",
            subtitlesEnabled: true
        )
        let request = PlaybackRequest(
            url: try XCTUnwrap(URL(string: "https://media.example/master.m3u8")),
            subtitles: ["https://subtitles.example/episode.vtt"],
            subtitleNames: ["English"],
            mediaSelectionIntent: intent,
            isAnime: true
        )

        XCTAssertEqual(request.mediaSelectionIntent, intent)
        XCTAssertEqual(request.subtitles, ["https://subtitles.example/episode.vtt"])
        XCTAssertEqual(request.subtitleNames, ["English"])
    }

    func testPlaybackLanguageSelectionPrefersExactThenBaseThenDisplayName() {
        let options = [
            PlaybackLanguageSelectionPolicy.Option(languageTag: "en-GB", displayName: "British English"),
            PlaybackLanguageSelectionPolicy.Option(languageTag: "ja-JP", displayName: "Japanese"),
            PlaybackLanguageSelectionPolicy.Option(languageTag: nil, displayName: "Spanish (Latin America)")
        ]

        XCTAssertEqual(
            PlaybackLanguageSelectionPolicy.preferredIndex(in: options, preferredLanguage: "ja_JP"),
            1
        )
        XCTAssertEqual(
            PlaybackLanguageSelectionPolicy.preferredIndex(in: options, preferredLanguage: "en-US"),
            0
        )
        XCTAssertEqual(
            PlaybackLanguageSelectionPolicy.preferredIndex(in: options, preferredLanguage: "es"),
            2
        )
    }

    func testExternalSubtitleParserAcceptsSRTAndWebVTTAndStripsMarkup() {
        let srt = Data("""
        1
        00:00:01,250 --> 00:00:03,500
        <i>Hello</i> &amp; welcome

        2
        00:04.000 --> 00:05.500 align:middle
        Next line
        """.utf8)

        XCTAssertEqual(
            TVExternalSubtitleParser.parse(srt),
            [
                TVExternalSubtitleCue(start: 1.25, end: 3.5, text: "Hello & welcome"),
                TVExternalSubtitleCue(start: 4, end: 5.5, text: "Next line")
            ]
        )
    }

    func testAccountBoundaryNotificationIsSynchronousBeforeIncomingStateWork() {
        let center = NotificationCenter()
        var order: [String] = []
        let token = center.addObserver(
            forName: .mediaStateWillChangeCurrentUser,
            object: nil,
            queue: nil
        ) { _ in
            order.append("playback-finalized")
        }
        defer { center.removeObserver(token) }

        MediaStateAccountPlaybackBoundary.notifyWillChangeUser(notificationCenter: center)
        order.append("incoming-state-applied")

        XCTAssertEqual(order, ["playback-finalized", "incoming-state-applied"])
    }

    @MainActor
    func testTVCustomPaletteUsesSafePresetWithoutRewritingSharedPreference() {
        let defaults = UserDefaults.standard
        let key = AppearanceConfig.paletteKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            EclipseTheme.shared.reloadMediaAppearanceFromDefaults()
        }

        defaults.set(AtmospherePaletteID.custom.rawValue, forKey: key)
        EclipseTheme.shared.reloadMediaAppearanceFromDefaults()

        XCTAssertEqual(EclipseTheme.shared.appearancePaletteRaw, AtmospherePaletteID.custom.rawValue)
        XCTAssertEqual(EclipseTheme.shared.scopedPaletteID(), AtmospherePaletteID.defaultValue)
        XCTAssertEqual(defaults.string(forKey: key), AtmospherePaletteID.custom.rawValue)
    }

    func testTVCardDensityDoesNotOverwriteSharedIOSCardScale() {
        let defaults = UserDefaults.standard
        let densityKey = "tvCardDensity"
        let sharedKey = ExperimentalVisualTuning.mediaCardScaleKey
        let previousDensity = defaults.object(forKey: densityKey)
        let previousShared = defaults.object(forKey: sharedKey)
        defer {
            if let previousDensity { defaults.set(previousDensity, forKey: densityKey) }
            else { defaults.removeObject(forKey: densityKey) }
            if let previousShared { defaults.set(previousShared, forKey: sharedKey) }
            else { defaults.removeObject(forKey: sharedKey) }
        }

        defaults.set("compact", forKey: densityKey)
        defaults.set(1.27, forKey: sharedKey)

        XCTAssertEqual(ExperimentalVisualTuning.current.mediaCardScale, 0.86, accuracy: 0.001)
        XCTAssertEqual(defaults.double(forKey: sharedKey), 1.27, accuracy: 0.001)
    }

    func testAVPlayerResourceLoaderSanitizesManagedAndUnsafeHeaders() {
        let headers = AVPlayerResourceLoader.sanitizedHTTPHeaders([
            "Referer": " https://example.com/watch ",
            "Cookie": "session=local-only",
            "Range": "bytes=0-99",
            "Host": "attacker.invalid",
            "Bad Header": "value",
            "Injected": "one\r\ntwo"
        ])

        XCTAssertEqual(headers["Referer"], "https://example.com/watch")
        XCTAssertEqual(headers["Cookie"], "session=local-only")
        XCTAssertNil(headers["Range"])
        XCTAssertNil(headers["Host"])
        XCTAssertNil(headers["Bad Header"])
        XCTAssertNil(headers["Injected"])
    }

    func testAVPlayerResourceLoaderProxyURLRoundTripsWithoutChangingTokens() throws {
        let original = try XCTUnwrap(URL(string: "https://media.example/video/master.m3u8?token=secret#fragment"))
        let proxied = try XCTUnwrap(AVPlayerResourceLoader.proxiedURL(for: original))

        XCTAssertEqual(proxied.scheme, "eclipse-av-https")
        XCTAssertEqual(AVPlayerResourceLoader.originalURL(for: proxied), original)
        XCTAssertNil(AVPlayerResourceLoader.proxiedURL(for: URL(fileURLWithPath: "/tmp/movie.mp4")))
    }

    func testAVPlayerResourceLoaderDoesNotLeakCredentialsAcrossOrigins() throws {
        let origin = try XCTUnwrap(URL(string: "https://media.example/master.m3u8"))
        let sameOrigin = try XCTUnwrap(URL(string: "https://media.example:443/segment.ts"))
        let otherOrigin = try XCTUnwrap(URL(string: "https://cdn.example/segment.ts"))
        let headers = [
            "Authorization": "Bearer device-local-token",
            "Cookie": "session=device-local",
            "Proxy-Authorization": "Basic blocked",
            "X-Api-Key": "device-local-api-key",
            "X-Auth-Token": "device-local-auth-token",
            "Api-Key": "device-local-generic-key",
            "Referer": "https://media.example/watch",
            "User-Agent": "Eclipse-tvOS",
            "Accept": "application/vnd.apple.mpegurl"
        ]

        let sameOriginHeaders = AVPlayerResourceLoader.httpHeaders(
            headers,
            for: sameOrigin,
            credentialOriginURL: origin
        )
        XCTAssertEqual(sameOriginHeaders["Authorization"], "Bearer device-local-token")
        XCTAssertEqual(sameOriginHeaders["Cookie"], "session=device-local")
        XCTAssertNil(sameOriginHeaders["Proxy-Authorization"])

        let crossOriginHeaders = AVPlayerResourceLoader.httpHeaders(
            headers,
            for: otherOrigin,
            credentialOriginURL: origin
        )
        XCTAssertNil(crossOriginHeaders["Authorization"])
        XCTAssertNil(crossOriginHeaders["Cookie"])
        XCTAssertNil(crossOriginHeaders["Proxy-Authorization"])
        XCTAssertNil(crossOriginHeaders["X-Api-Key"])
        XCTAssertNil(crossOriginHeaders["X-Auth-Token"])
        XCTAssertNil(crossOriginHeaders["Api-Key"])
        XCTAssertEqual(crossOriginHeaders["Referer"], "https://media.example/watch")
        XCTAssertEqual(crossOriginHeaders["User-Agent"], "Eclipse-tvOS")
        XCTAssertEqual(crossOriginHeaders["Accept"], "application/vnd.apple.mpegurl")
    }

    func testAVPlayerResourceLoaderRedactsCrossOriginRefererQueryTokens() throws {
        let origin = try XCTUnwrap(URL(string: "https://media.example/master.m3u8"))
        let destination = try XCTUnwrap(URL(string: "https://cdn.example/segment.ts"))
        let headers = AVPlayerResourceLoader.httpHeaders(
            ["Referer": "https://media.example/watch?token=secret#private"],
            for: destination,
            credentialOriginURL: origin
        )

        XCTAssertEqual(headers["Referer"], "https://media.example/watch")
    }

    func testAVPlayerResourceLoaderRewritesEveryHLSNetworkResource() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://media.example/path/master.m3u8?token=private%2Bvalue%3D"))
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,URI="audio/playlist.m3u8"
        #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example/key.bin"
        //cdn.example/video/variant.m3u8
        segment.ts
        """

        let rewritten = AVPlayerResourceLoader.rewriteHLSManifest(manifest, relativeTo: baseURL)

        XCTAssertTrue(rewritten.contains("URI=\"eclipse-av-https://media.example/path/audio/playlist.m3u8?token=private%2Bvalue%3D\""))
        XCTAssertTrue(rewritten.contains("URI=\"eclipse-av-https://keys.example/key.bin\""))
        XCTAssertTrue(rewritten.contains("eclipse-av-https://cdn.example/video/variant.m3u8"))
        XCTAssertTrue(rewritten.contains("eclipse-av-https://media.example/path/segment.ts?token=private%2Bvalue%3D"))
        XCTAssertFalse(rewritten.contains("URI=\"https://"))
    }

    func testTVSkipSegmentPolicyNormalizesBoundsOrderingAndDuplicates() {
        let segments = [
            SkipSegment(startTime: 50, endTime: 80, type: .outro),
            SkipSegment(startTime: -5, endTime: 10, type: .recap),
            SkipSegment(startTime: 50, endTime: 90, type: .outro),
            SkipSegment(startTime: 110, endTime: 130, type: .preview),
            SkipSegment(startTime: 20, endTime: 20, type: .intro)
        ]

        let normalized = TVSkipSegmentPolicy.normalized(segments, duration: 120)

        XCTAssertEqual(normalized.count, 3)
        XCTAssertEqual(normalized.map(\.type), [.recap, .outro, .preview])
        XCTAssertEqual(normalized[0].startTime, 0)
        XCTAssertEqual(normalized[2].endTime, 120)
    }

    func testTVSkipSegmentPolicyUsesHalfOpenIntervals() {
        let segment = SkipSegment(startTime: 10, endTime: 20, type: .intro)

        XCTAssertNil(TVSkipSegmentPolicy.activeSegment(in: [segment], position: 9.99))
        XCTAssertEqual(
            TVSkipSegmentPolicy.activeSegment(in: [segment], position: 10)?.uniqueKey,
            segment.uniqueKey
        )
        XCTAssertNil(TVSkipSegmentPolicy.activeSegment(in: [segment], position: 20))
    }
}
