import Foundation
import XCTest
@testable import EclipseMac

final class MacPlaybackPolicyTests: XCTestCase {
    #if arch(x86_64)
    @MainActor
    func testIntelDeviceFailureDoesNotPenalizeOrRotateAutoModeSource() async throws {
        let suite = "IntelDeviceFailureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = ProfileManager.shared.activeProfileID
        let authority = try XCTUnwrap(ProgressManager.shared.profileMutationAuthority(requiredOwner: owner))
        for message in ["GPU device lost. Retry playback to continue.", "audio output initialization failed"] {
            let sourceID = "stremio:intel-test-\(UUID().uuidString)"
            let url = try XCTUnwrap(URL(string: "https://example.invalid/fixture.mp4"))
            let context = PlaybackLaunchContext(sourceId: sourceID, sourceName: "Isolated test", sourceKind: .stremio,
                autoMode: true, streamURL: url.absoluteString, headers: [:], subtitles: [], subtitleNames: nil, retryCount: 0)
            var rotationCount = 0
            let request = PlaybackRequest(url: url, launchContext: context,
                onPlaybackStartupFailure: { _ in rotationCount += 1 })
            let session = MacPlaybackSession(request: request, engine: .mpv, owner: owner, authority: authority,
                defaults: defaults)
            session.failed(message)
            XCTAssertEqual(session.errorMessage, message)
            XCTAssertFalse(session.isPlaying)
            XCTAssertFalse(session.isReady)
            XCTAssertNil(SourceHealthStore.shared.record(for: sourceID))
            XCTAssertEqual(rotationCount, 0)
            session.stop()
            await session.waitUntilStopped()
        }
    }
    #endif

    func testIntelRestrictionsDoNotApplyToOtherPlatformsOrAppleSilicon() {
        for platform in [EclipsePlatform.iOS, .tvOS, .visionOS, .macOS] {
            for x86 in [false, true] {
                let policy = IntelMacCompatibilityPolicy(platform: platform, isX86_64: x86)
                let expected = platform == .macOS && x86
                XCTAssertEqual(policy.isEnabled, expected)
                XCTAssertEqual(policy.supportsEnhancedMPVRendering, !expected)
                XCTAssertEqual(policy.supportsMPVPictureInPicture, !expected)
                XCTAssertEqual(policy.supportsAtmosPassthrough, !expected)
                XCTAssertEqual(policy.supportsReaderImageUpscaling, !expected)
            }
        }
    }

    func testIntelOptionsOverrideAdvancedSettingsWithoutWritingPreferences() throws {
        let suite = "IntelPlaybackPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved: [String: Any] = ["mpvDolbyVisionEnabled": true, "mpvDolbyAtmosEnabled": true,
            "mpvSurroundSoundEnabled": true, "mpvHDRMode": "hdr", "mpvUpscalingMode": "upscaleTo4K",
            "mpvNeuralUpscaler": "anime", "mpvPictureInPictureEnabled": true,
            "Reader.upscaleImages": true, "Reader.upscaleModelName": "Existing model"]
        defaults.setPersistentDomain(saved, forName: suite)
        let before = try XCTUnwrap(defaults.persistentDomain(forName: suite)) as NSDictionary
        let dolby = MPVDolbyPlaybackSettings(defaults: defaults)
        var requested = dolby.options
        requested["glsl-shaders"] = "existing-shader"
        requested["target-colorspace-hint"] = "yes"
        requested["sub-delay"] = "1.25"
        let effective = MacIntelPlaybackPolicy.options(requested,
            compatibility: .init(platform: .macOS, isX86_64: true))
        XCTAssertEqual(effective["apple-compressed-audio"], "no")
        XCTAssertEqual(effective["audio-spdif"], "")
        XCTAssertEqual(effective["audio-channels"], "auto")
        XCTAssertEqual(effective["hwdec-software-fallback"], "3")
        XCTAssertEqual(effective["glsl-shaders"], "")
        XCTAssertEqual(effective["target-colorspace-hint"], "no")
        XCTAssertEqual(effective["sub-delay"], "1.25")
        XCTAssertEqual(dolby.videoFilterChain, "")
        XCTAssertEqual(try XCTUnwrap(defaults.persistentDomain(forName: suite)) as NSDictionary, before)
        for platform in [EclipsePlatform.iOS, .tvOS, .visionOS, .macOS] {
            let unchanged = MacIntelPlaybackPolicy.options(requested,
                compatibility: .init(platform: platform, isX86_64: platform != .macOS))
            XCTAssertEqual(unchanged, requested)
        }
    }

    func testIntelRendererFailureClassificationDoesNotCaptureSourceFailures() {
        for message in ["VK_ERROR_DEVICE_LOST", "Metal is unavailable on this device.",
                        "mpv_initialize failed status=-3", "Video output initialization failed",
                        "playback ended with error: audio output initialization failed"] {
            XCTAssertTrue(MacIntelPlaybackPolicy.isLocalRendererFailure(message))
        }
        for message in ["HTTP 403", "No internet connection", "gpu-next loadfile failed status=-13",
                        "The signed URL expired", "Subtitle download failed"] {
            XCTAssertFalse(MacIntelPlaybackPolicy.isLocalRendererFailure(message))
        }
    }

    func testAutoplayCompletionRejectsTruncationUnknownDurationAndUnsafePresentation() {
        var gate = MacAutoplayCompletionGate()
        for value in [Double.nan, .infinity, 0, 4] {
            XCTAssertFalse(gate.claim(completedGeneration: 1, currentGeneration: 1,
                position: value, duration: value, isEligible: true))
        }
        XCTAssertFalse(gate.claim(completedGeneration: 1, currentGeneration: 1,
            position: 590, duration: 600, isEligible: true))
        XCTAssertFalse(gate.claim(completedGeneration: 1, currentGeneration: 1,
            position: 600, duration: 600, isEligible: false))
        XCTAssertTrue(gate.claim(completedGeneration: 1, currentGeneration: 1,
            position: 599.8, duration: 600, isEligible: true))
    }

    func testAutoplayCompletionClaimsOnlyOnceForTheCurrentLoad() {
        var gate = MacAutoplayCompletionGate()
        XCTAssertFalse(gate.claim(completedGeneration: 1, currentGeneration: 2,
            position: 600, duration: 600, isEligible: true))
        XCTAssertTrue(gate.claim(completedGeneration: 2, currentGeneration: 2,
            position: 600, duration: 600, isEligible: true))
        XCTAssertFalse(gate.claim(completedGeneration: 2, currentGeneration: 2,
            position: 600, duration: 600, isEligible: true))
        XCTAssertFalse(gate.claim(completedGeneration: 2, currentGeneration: 3,
            position: 600, duration: 600, isEligible: true))
        XCTAssertTrue(gate.claim(completedGeneration: 3, currentGeneration: 3,
            position: 600, duration: 600, isEligible: true))
    }

    func testAutomaticQualityAdaptsAndManualQualityStaysSelected() {
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.effectiveProfile(.auto, thermal: .nominal), .sharp)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.effectiveProfile(.auto, thermal: .fair), .balanced)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.effectiveProfile(.auto, thermal: .serious), .lowHeat)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.effectiveProfile(.sharp, thermal: .critical), .sharp)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.effectiveProfile(.lowHeat, thermal: .nominal), .lowHeat)
    }

    func testUpscalingTargetsRespectDisplayAndQualityScale() {
        let source = CGSize(width: 1920, height: 1080)
        let bounds = CGSize(width: 2560, height: 1440)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.contentsScale(profile: .sharp, mode: .upscaleTo4K,
            source: source, bounds: bounds, backingScale: 2), 1.5, accuracy: 0.001)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.contentsScale(profile: .sharp, mode: .oneLevelAlways,
            source: source, bounds: bounds, backingScale: 2), 1, accuracy: 0.001)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.contentsScale(profile: .lowHeat, mode: .auto,
            source: source, bounds: bounds, backingScale: 2), 1.24, accuracy: 0.001)
    }

    func testBrowserFlowCannotPublishAfterCloseReopenCancelOrOwnerChange() {
        func accepted(window: UInt64 = 1, flow: UInt64 = 1, owner: Bool = true,
                      services: Bool = true, visible: Bool = true, cancelled: Bool = false) -> Bool {
            MacProviderBrowserAuthorityPolicy.accepts(profileIsCurrent: owner, servicesAreCurrent: services,
                capturedWindow: 1, currentWindow: window, capturedFlow: 1, currentFlow: flow,
                allowsPresentation: visible, isCancelled: cancelled)
        }
        XCTAssertTrue(accepted())
        XCTAssertFalse(accepted(window: 3))
        XCTAssertFalse(accepted(flow: 3))
        XCTAssertFalse(accepted(owner: false))
        XCTAssertFalse(accepted(services: false))
        XCTAssertFalse(accepted(visible: false))
        XCTAssertFalse(accepted(cancelled: true))
    }

    func testMacDefaultsAndAutomaticFallback() {
        XCTAssertEqual(PlaybackEngine.defaultSelection(deviceFamily: .mac), .mpv)
        let automatic = PlaybackLaunchPlan.make(selection: .automatic, deviceFamily: .mac)
        XCTAssertEqual(automatic.primary, .avPlayer)
        XCTAssertEqual(automatic.preStartFallback, .mpv)
        XCTAssertNil(PlaybackLaunchPlan.make(selection: .mpv, deviceFamily: .mac).preStartFallback)
        XCTAssertEqual(TypedPluginPlaybackEnginePolicy.effectiveEngine(requested: .automatic, sourceKind: .skyStream), .mpv)
    }

    func testMainWindowAndModeChangesOnlyPreserveExplicitPictureInPicture() {
        for reason in [MacPlaybackLifecyclePolicy.CloseReason.mainWindow, .modeSwitch] {
            XCTAssertTrue(MacPlaybackLifecyclePolicy.shouldStop(for: reason, hasExplicitPictureInPicture: false))
            XCTAssertFalse(MacPlaybackLifecyclePolicy.shouldStop(for: reason, hasExplicitPictureInPicture: true))
            XCTAssertTrue(MacPlaybackLifecyclePolicy.shouldStop(for: reason, hasExplicitPictureInPicture: true,
                isRestoringPictureInPicture: true))
        }
        for reason in [MacPlaybackLifecyclePolicy.CloseReason.player, .pictureInPicture, .accountOrProfile] {
            XCTAssertTrue(MacPlaybackLifecyclePolicy.shouldStop(for: reason, hasExplicitPictureInPicture: true))
        }
    }

    func testClosedWindowOrWatchTogetherRoundTripCannotReadmitPendingPlayback() {
        let initial = WatchTogetherPlaybackHandoffIdentity(sessionID: nil, sessionGeneration: 1, mediaRevision: nil, mediaIdentifier: nil)
        let afterLeave = WatchTogetherPlaybackHandoffIdentity(sessionID: nil, sessionGeneration: 3, mediaRevision: nil, mediaIdentifier: nil)
        XCTAssertFalse(MacPlaybackLifecyclePolicy.acceptsAdmission(capturedGeneration: 1, currentGeneration: 3,
            capturedWatchTogether: initial, currentWatchTogether: initial, ownerIsCurrent: true))
        XCTAssertFalse(MacPlaybackLifecyclePolicy.acceptsAdmission(capturedGeneration: 1, currentGeneration: 1,
            capturedWatchTogether: initial, currentWatchTogether: afterLeave, ownerIsCurrent: true))
        XCTAssertFalse(MacPlaybackLifecyclePolicy.acceptsAdmission(capturedGeneration: 1, currentGeneration: 1,
            capturedWatchTogether: initial, currentWatchTogether: initial, ownerIsCurrent: false))
    }

    func testRetiredPictureInPictureCannotRestoreOrStopNewPlayback() {
        XCTAssertFalse(MacPlaybackLifecyclePolicy.acceptsPictureInPictureCallback(controllerIsCurrent: false, ownerIsCurrent: true))
        XCTAssertFalse(MacPlaybackLifecyclePolicy.acceptsPictureInPictureCallback(controllerIsCurrent: true, ownerIsCurrent: false))
        XCTAssertTrue(MacPlaybackLifecyclePolicy.acceptsPictureInPictureCallback(controllerIsCurrent: true, ownerIsCurrent: true))
    }

    @MainActor
    func testDelayedPictureInPictureRestoreRejectsCloseReopenAndModeReplacement() async {
        let restoration = MacPlaybackRestorationAuthority(playbackGeneration: 4, windowGeneration: 7)
        XCTAssertTrue(restoration.isCurrent(playbackGeneration: 4, windowGeneration: 7, ownerIsCurrent: true,
            applicationIsTerminating: false, requiresUnlock: false))
        for replacement in [(playback: UInt64(4), window: UInt64(9)), (playback: UInt64(5), window: UInt64(7))] {
            let delayedCompletion = Task { @MainActor in
                await Task.yield()
                return restoration.isCurrent(playbackGeneration: replacement.playback,
                    windowGeneration: replacement.window, ownerIsCurrent: true,
                    applicationIsTerminating: false, requiresUnlock: false)
            }
            let accepted = await delayedCompletion.value
            XCTAssertFalse(accepted)
        }
        XCTAssertFalse(restoration.isCurrent(playbackGeneration: 4, windowGeneration: 7, ownerIsCurrent: false,
            applicationIsTerminating: false, requiresUnlock: false))
        XCTAssertFalse(restoration.isCurrent(playbackGeneration: 4, windowGeneration: 7, ownerIsCurrent: true,
            applicationIsTerminating: true, requiresUnlock: false))
        XCTAssertFalse(restoration.isCurrent(playbackGeneration: 4, windowGeneration: 7, ownerIsCurrent: true,
            applicationIsTerminating: false, requiresUnlock: true))
    }

    @MainActor
    func testRetirementTimeoutCannotReopenAdmissionBeforeGlobalQuitCancellation() async {
        var gate = MacPlaybackTerminationGate()
        gate.begin()
        let retirement = Task<Void, Never> { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        defer { retirement.cancel() }
        let finished = await MacPlaybackShutdownBarrier.wait(for: [retirement], timeout: 0.01)
        XCTAssertFalse(finished)
        XCTAssertFalse(gate.allowsAdmission(applicationIsTerminating: true))
        XCTAssertFalse(gate.allowsAdmission(applicationIsTerminating: false))
        gate.cancel()
        XCTAssertFalse(gate.allowsAdmission(applicationIsTerminating: true))
        XCTAssertTrue(gate.allowsAdmission(applicationIsTerminating: false))
    }

    @MainActor
    func testShutdownWaitsForRetirementAndBoundsUnresponsiveWork() async {
        let finished = Task<Void, Never> {}
        let successful = await MacPlaybackShutdownBarrier.wait(for: [finished], timeout: 1)
        XCTAssertTrue(successful)
        let slow = Task<Void, Never> { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        let bounded = await MacPlaybackShutdownBarrier.wait(for: [slow], timeout: 0.01)
        XCTAssertFalse(bounded)
        slow.cancel()
        await slow.value
    }

    func testExternalHandoffRejectsPrivateTransportAndPreservesOrdinaryHTTP() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example/video.mp4"))
        XCTAssertTrue(MacExternalPlaybackPolicy.allows(url: url, hasHeaders: false, hasProxyOwnership: false,
            sourceKind: .stremio, autoMode: false, watchTogether: false))
        XCTAssertFalse(MacExternalPlaybackPolicy.allows(url: url, hasHeaders: false, hasProxyOwnership: false,
            sourceKind: .nuvio, autoMode: false, watchTogether: false))
        for headers in [false, true] {
            XCTAssertFalse(MacExternalPlaybackPolicy.allows(url: url, hasHeaders: headers, hasProxyOwnership: true,
                sourceKind: .skyStream, autoMode: false, watchTogether: false))
        }
        XCTAssertFalse(MacExternalPlaybackPolicy.allows(url: url, hasHeaders: true, hasProxyOwnership: false,
            sourceKind: .service, autoMode: false, watchTogether: false))
        XCTAssertFalse(MacExternalPlaybackPolicy.allows(url: try XCTUnwrap(URL(string: "http://127.0.0.1:9000/video")),
            hasHeaders: false, hasProxyOwnership: false, sourceKind: .stremio, autoMode: false, watchTogether: false))
        XCTAssertFalse(MacExternalPlaybackPolicy.allows(url: url, hasHeaders: false, hasProxyOwnership: false,
            sourceKind: .service, autoMode: true, watchTogether: false))
    }
}
