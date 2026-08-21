import XCTest
@testable import Eclipse

#if os(iOS)

final class WatchTogetherProtocolTests: XCTestCase {

    private let authorityA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000") ?? UUID()
    private let authorityB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000") ?? UUID()

    private func movieDescriptor() -> WatchTogetherMediaDescriptor {
        WatchTogetherMediaDescriptor(
            tmdbID: 603,
            mediaType: "movie",
            seasonNumber: nil,
            episodeNumber: nil,
            title: "The Matrix"
        )
    }

    private func state(
        mediaRevision: UInt64 = 1,
        stateRevision: UInt64 = 1,
        position: Double = 100,
        duration: Double? = 1440,
        isPlaying: Bool = true,
        playbackRate: Double = 1.0,
        awaitsReadiness: Bool? = nil,
        sentAt: TimeInterval = 1_000_000,
        authority: UUID? = nil,
        isStalled: Bool? = nil,
        pausedByLifecycle: Bool? = nil
    ) -> WatchTogetherSharedState {
        WatchTogetherSharedState(
            mediaIdentifier: "movie-identifier",
            media: movieDescriptor(),
            mediaRevision: mediaRevision,
            stateRevision: stateRevision,
            position: position,
            duration: duration,
            normalizedProgress: duration.map { position / $0 },
            isPlaying: isPlaying,
            playbackRate: playbackRate,
            awaitsReadiness: awaitsReadiness,
            sentAt: sentAt,
            authorityInstanceID: authority ?? authorityA,
            isStalled: isStalled,
            pausedByLifecycle: pausedByLifecycle
        )
    }

    func testProjectionAdvancesPausedStateNever() {
        let paused = state(isPlaying: false)
        XCTAssertEqual(paused.projectedPosition(at: 1_000_004), 100)
    }

    func testProjectionAdvancesWithElapsedTime() {
        let playing = state()
        XCTAssertEqual(playing.projectedPosition(at: 1_000_002), 102, accuracy: 0.0001)
    }

    func testProjectionAppliesPlaybackRate() {
        let fast = state(playbackRate: 2.0)
        XCTAssertEqual(fast.projectedPosition(at: 1_000_002), 104, accuracy: 0.0001)
    }

    func testProjectionCorrectsSenderClockAhead() {
        let playing = state()
        XCTAssertEqual(playing.projectedPosition(at: 999_999), 100)
        XCTAssertEqual(
            playing.projectedPosition(at: 999_999, senderClockOffset: 3),
            102,
            accuracy: 0.0001
        )
    }

    func testProjectionCorrectsSenderClockBehind() {
        let playing = state()
        XCTAssertEqual(
            playing.projectedPosition(at: 1_000_005, senderClockOffset: -3),
            102,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            playing.projectedPosition(at: 1_000_000, senderClockOffset: -3),
            100
        )
    }

    func testProjectionRejectsElapsedOutsideGuard() {
        let playing = state()
        XCTAssertEqual(playing.projectedPosition(at: 1_000_006), 100)
        XCTAssertEqual(playing.projectedPosition(at: 999_998), 100)
    }

    func testProjectionToleratesSlightNegativeElapsed() {
        let playing = state()
        XCTAssertEqual(playing.projectedPosition(at: 999_999.5), 100)
    }

    func testProjectionClampsToDuration() {
        let nearEnd = state(position: 1438)
        XCTAssertEqual(nearEnd.projectedPosition(at: 1_000_004), 1440)
    }

    @MainActor
    func testAcceptancePrefersHigherMediaRevision() {
        let current = state(mediaRevision: 2, stateRevision: 9)
        let incoming = state(mediaRevision: 3, stateRevision: 1, authority: authorityB)
        XCTAssertTrue(WatchTogetherCoordinator.prefersIncomingState(incoming, over: current))
        XCTAssertFalse(WatchTogetherCoordinator.prefersIncomingState(current, over: incoming))
    }

    @MainActor
    func testAcceptancePrefersHigherStateRevision() {
        let current = state(stateRevision: 5)
        let incoming = state(stateRevision: 6, authority: authorityB)
        XCTAssertTrue(WatchTogetherCoordinator.prefersIncomingState(incoming, over: current))
        XCTAssertFalse(WatchTogetherCoordinator.prefersIncomingState(current, over: incoming))
    }

    @MainActor
    func testAcceptanceSameAuthoritySnapshotIsAcceptedRegardlessOfSentAt() {
        let current = state(sentAt: 2_000_000)
        let incoming = state(position: 130, sentAt: 1_999_990)
        XCTAssertTrue(WatchTogetherCoordinator.prefersIncomingState(incoming, over: current))
    }

    @MainActor
    func testAcceptanceTieBreakLetsPauseWinAcrossAuthoritiesInBothArrivalOrders() {
        let pause = state(stateRevision: 4, isPlaying: false, authority: authorityA)
        let seek = state(stateRevision: 4, position: 300, isPlaying: true, authority: authorityB)
        XCTAssertTrue(WatchTogetherCoordinator.prefersIncomingState(pause, over: seek))
        XCTAssertFalse(WatchTogetherCoordinator.prefersIncomingState(seek, over: pause))
    }

    @MainActor
    func testAcceptanceTieBreakFallsBackToAuthorityIdentifier() {
        let first = state(stateRevision: 4, authority: authorityA)
        let second = state(stateRevision: 4, position: 300, authority: authorityB)
        XCTAssertTrue(WatchTogetherCoordinator.prefersIncomingState(second, over: first))
        XCTAssertFalse(WatchTogetherCoordinator.prefersIncomingState(first, over: second))
    }

    @MainActor
    func testSynchronizedPositionUsesAbsoluteMappingAcrossDifferentDurations() {
        let shared = state(position: 1200, isPlaying: false)
        let mapped = WatchTogetherCoordinator.shared.synchronizedPosition(
            of: shared,
            localDuration: 1425
        )
        XCTAssertEqual(mapped, 1200, accuracy: 0.0001)
    }

    @MainActor
    func testSynchronizedPositionClampsBeforeLocalEnd() {
        let shared = state(position: 1439, isPlaying: false)
        let mapped = WatchTogetherCoordinator.shared.synchronizedPosition(
            of: shared,
            localDuration: 1425
        )
        XCTAssertEqual(mapped, 1424, accuracy: 0.0001)
    }

    @MainActor
    func testDriftThresholdsKeepNudgeBandBelowSeekBand() {
        XCTAssertLessThan(
            WatchTogetherCoordinator.driftNudgeThreshold,
            WatchTogetherCoordinator.driftSeekThreshold
        )
    }

    func testSharedStateDecodesLegacyPayloadWithoutStallFields() throws {
        let modern = state()
        let data = try JSONEncoder().encode(modern)
        var payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        payload.removeValue(forKey: "isStalled")
        payload.removeValue(forKey: "pausedByLifecycle")
        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(WatchTogetherSharedState.self, from: legacyData)
        XCTAssertNil(decoded.isStalled)
        XCTAssertNil(decoded.pausedByLifecycle)
        XCTAssertEqual(decoded.position, modern.position)
        XCTAssertEqual(decoded.authorityInstanceID, modern.authorityInstanceID)
    }

    func testSharedStateRoundTripsStallAndLifecycleFields() throws {
        let stalled = state(isPlaying: false, isStalled: true, pausedByLifecycle: true)
        let decoded = try JSONDecoder().decode(
            WatchTogetherSharedState.self,
            from: JSONEncoder().encode(stalled)
        )
        XCTAssertEqual(decoded.isStalled, true)
        XCTAssertEqual(decoded.pausedByLifecycle, true)
    }

    func testAnimeDescriptorStableKeySurvivesCodableRoundTrip() throws {
        let context = EpisodePlaybackContext(
            localSeasonNumber: 2,
            localEpisodeNumber: 5,
            anilistMediaId: 145_064,
            canonicalAniListMediaId: 145_064,
            malMediaId: 51_009,
            kitsuMediaId: nil,
            tmdbSeasonNumber: 1,
            tmdbEpisodeNumber: 29,
            tmdbEpisodeOffset: 24,
            animeAbsoluteEpisodeNumber: 29,
            animeSeasonEpisodeCount: 23,
            isSpecial: false,
            titleOnlySearch: false
        )
        let descriptor = WatchTogetherMediaDescriptor(
            tmdbID: 95_479,
            mediaType: "tv",
            seasonNumber: 1,
            episodeNumber: 29,
            playbackContext: context,
            isAnime: true,
            title: "Jujutsu Kaisen"
        )
        let decoded = try JSONDecoder().decode(
            WatchTogetherMediaDescriptor.self,
            from: JSONEncoder().encode(descriptor)
        )
        XCTAssertNotNil(descriptor.stableKey)
        XCTAssertEqual(decoded.stableKey, descriptor.stableKey)
        XCTAssertNil(descriptor.animeContextFailureReason)
    }

    func testDescriptorDecodeRejectsUnboundedIdentityAndCoordinates() throws {
        let decoder = JSONDecoder()
        let hostilePayloads: [[String: Any]] = [
            [
                "tmdbID": Int.max,
                "mediaType": "movie",
                "isAnime": false
            ],
            [
                "tmdbID": 42,
                "mediaType": "tv",
                "seasonNumber": Int.min,
                "episodeNumber": 1,
                "isAnime": false
            ],
            [
                "tmdbID": 42,
                "mediaType": "tv",
                "seasonNumber": 1,
                "episodeNumber": 1,
                "isAnime": true,
                "playbackContext": [
                    "localSeasonNumber": 1,
                    "localEpisodeNumber": 1,
                    "anilistMediaId": Int.min,
                    "isSpecial": false,
                    "titleOnlySearch": false
                ]
            ]
        ]

        for payload in hostilePayloads {
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertThrowsError(
                try decoder.decode(WatchTogetherMediaDescriptor.self, from: data)
            )
        }

        let locallyConstructed = WatchTogetherMediaDescriptor(
            tmdbID: Int.max,
            mediaType: "movie",
            seasonNumber: nil,
            episodeNumber: nil
        )
        XCTAssertNil(locallyConstructed.sanitizedForTransport)
        XCTAssertNil(locallyConstructed.stableKey)
    }
}

#endif
