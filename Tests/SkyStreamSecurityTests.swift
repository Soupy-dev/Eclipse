import Foundation
import CryptoKit
import UIKit
import WebKit
import XCTest
@testable import Eclipse
#if os(iOS) && !targetEnvironment(macCatalyst)
import ZIPFoundation

private final class SkyStreamRedirectResponseURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "redirect-source.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let source = request.url,
              let destination = URL(string: "https://redirect-destination.example/final"),
              let response = HTTPURLResponse(
                url: source,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Location": destination.absoluteString,
                    "Content-Length": "1048576"
                ]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(
            self,
            wasRedirectedTo: URLRequest(url: destination),
            redirectResponse: response
        )
    }

    override func stopLoading() {}
}

final class NuvioBoundaryHardeningTests: XCTestCase {
    func testSubtitleHeadersAreInheritedOnlyWithinExactHTTPOrigin() throws {
        let stream = try XCTUnwrap(URL(string: "https://Media.Example.test/video.m3u8"))

        XCTAssertTrue(DownloadManager.shouldInheritDownloadHeadersForSubtitle(
            streamURL: stream,
            subtitleURL: try XCTUnwrap(URL(string: "https://media.example.test:443/subtitles/en.vtt"))
        ))
        XCTAssertFalse(DownloadManager.shouldInheritDownloadHeadersForSubtitle(
            streamURL: stream,
            subtitleURL: try XCTUnwrap(URL(string: "http://media.example.test/subtitles/en.vtt"))
        ))
        XCTAssertFalse(DownloadManager.shouldInheritDownloadHeadersForSubtitle(
            streamURL: stream,
            subtitleURL: try XCTUnwrap(URL(string: "https://media.example.test:8443/subtitles/en.vtt"))
        ))
        XCTAssertFalse(DownloadManager.shouldInheritDownloadHeadersForSubtitle(
            streamURL: stream,
            subtitleURL: try XCTUnwrap(URL(string: "https://subtitles.example.test/subtitles/en.vtt"))
        ))
    }

    func testHostileRetryAfterNumbersAreTotalAndBounded() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example.test/playlist.m3u8"))
        for rawValue in ["nan", "inf", "-inf"] {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": rawValue]
            ))
            XCTAssertNil(HLSDownloader.retryAfterSeconds(from: response), rawValue)
        }

        let huge = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "1e300"]
        ))
        let bounded = try XCTUnwrap(HLSDownloader.retryAfterSeconds(from: huge))
        XCTAssertTrue(bounded.isFinite)
        XCTAssertEqual(bounded, 30)

        XCTAssertEqual(HLSDownloader.nanoseconds(for: .nan), 0)
        XCTAssertEqual(HLSDownloader.nanoseconds(for: .infinity), 0)
        XCTAssertEqual(HLSDownloader.nanoseconds(for: -1), 0)
        XCTAssertEqual(HLSDownloader.nanoseconds(for: 1e300), UInt64.max)
        for value in [Double.nan, Double.infinity, 1e300] {
            XCTAssertFalse(
                HLSError.rateLimited(retryAfterSeconds: value)
                    .localizedDescription.isEmpty
            )
        }
    }

    func testSubtitleBoundaryStableDedupesHostileAliasArraysAndKeepsFirstHeaders() {
        func subtitle(_ index: Int, token: String) -> NuvioPluginSubtitle {
            NuvioPluginSubtitle(
                url: "https://subs.example/\(index).vtt",
                language: "Language \(index)",
                name: "Track \(index)",
                headers: ["Authorization": "Bearer \(token)"]
            )
        }

        var accumulator = NuvioSubtitleTrackAccumulator()
        accumulator.append(contentsOf: [
            subtitle(0, token: "first"),
            subtitle(0, token: "duplicate-must-not-replace"),
            subtitle(1, token: "one")
        ])
        accumulator.append(contentsOf: (2..<200).map {
            subtitle($0, token: "token-\($0)")
        })

        XCTAssertEqual(accumulator.tracks.count, NuvioSubtitleBoundary.maximumTracksPerStream)
        XCTAssertEqual(Array(accumulator.tracks.map(\.url).prefix(3)), [
            "https://subs.example/0.vtt",
            "https://subs.example/1.vtt",
            "https://subs.example/2.vtt"
        ])
        XCTAssertEqual(accumulator.tracks.first?.headers?["Authorization"], "Bearer first")
        XCTAssertFalse(
            accumulator.tracks.contains {
                $0.headers?["Authorization"] == "Bearer duplicate-must-not-replace"
            }
        )
    }

    func testProviderDuplicateSubtitleURLsAreNotReportedAsAnEclipseBudgetLoss() {
        let repeated = (0..<10).map { index in
            NuvioPluginSubtitle(
                url: index < 4
                    ? "https://subs.example/shared.vtt"
                    : "https://subs.example/\(index).vtt",
                language: "en",
                name: "Track \(index)",
                headers: nil
            )
        }
        let stream = NuvioPluginStream(
            id: "stream-0",
            scraperId: "scraper",
            scraperName: "Fixture",
            sourceId: "nuvio:fixture",
            sourceName: "Fixture",
            title: "Stream 0",
            name: nil,
            url: "https://media.example/video.mp4",
            quality: nil,
            size: nil,
            language: nil,
            provider: nil,
            type: nil,
            headers: nil,
            subtitles: repeated
        )

        let batch = NuvioSubtitleBoundary.boundedForNetworkValidation([stream])
        XCTAssertEqual(
            batch.streams.first?.subtitles?.count,
            7,
            "the three duplicate URLs collapse; every distinct track survives"
        )
        XCTAssertEqual(
            batch.droppedByBatchBudget,
            0,
            "no Eclipse cap engaged, so nothing may be attributed to one"
        )
    }

    func testSubtitleNetworkValidationBatchIsAggregateBoundedInStreamOrder() {
        func stream(_ index: Int) -> NuvioPluginStream {
            let subtitles = (0..<NuvioSubtitleBoundary.maximumTracksPerStream).map { track in
                NuvioPluginSubtitle(
                    url: "https://subs-\(index).example/\(track).vtt",
                    language: "Language \(track)",
                    name: "Stream \(index) Track \(track)",
                    headers: ["X-Stream": "\(index)", "X-Track": "\(track)"]
                )
            }
            return NuvioPluginStream(
                id: "stream-\(index)",
                scraperId: "scraper",
                scraperName: "Fixture",
                sourceId: "nuvio:fixture",
                sourceName: "Fixture",
                title: "Stream \(index)",
                name: nil,
                url: "https://media-\(index).example/video.mp4",
                quality: nil,
                size: nil,
                language: nil,
                provider: nil,
                type: nil,
                headers: nil,
                subtitles: subtitles
            )
        }

        let batch = NuvioSubtitleBoundary.boundedForNetworkValidation(
            (0..<40).map(stream)
        )
        let tracks = batch.streams.flatMap { $0.subtitles ?? [] }

        XCTAssertLessThanOrEqual(
            tracks.count,
            NuvioSubtitleBoundary.maximumTracksPerValidationBatch,
            "the batch budget must remain a hard aggregate bound"
        )
        XCTAssertTrue(
            batch.streams.allSatisfy { ($0.subtitles?.isEmpty == false) },
            "no stream may lose every subtitle while an earlier stream keeps a full share"
        )
        let shares = batch.streams.map { $0.subtitles?.count ?? 0 }
        let smallest = shares.min() ?? 0
        let largest = shares.max() ?? 0
        XCTAssertLessThanOrEqual(
            largest - smallest,
            1,
            "no stream may be given a materially larger share than another"
        )
        let baseShare = max(
            1,
            NuvioSubtitleBoundary.maximumTracksPerValidationBatch / batch.streams.count
        )
        XCTAssertGreaterThanOrEqual(
            smallest,
            baseShare,
            "no stream may receive less than an even division of the budget"
        )
        XCTAssertEqual(
            tracks.count,
            NuvioSubtitleBoundary.maximumTracksPerValidationBatch,
            "the batch must spend its whole budget rather than leaving a remainder unused"
        )
        XCTAssertEqual(tracks.first?.name, "Stream 0 Track 0")
        XCTAssertEqual(tracks.first?.headers?["X-Track"], "0")
        XCTAssertGreaterThan(
            batch.droppedByBatchBudget,
            0,
            "tracks cut by Eclipse's own budget must be counted so they can be attributed to Eclipse"
        )
    }

    func testPlaybackScopeAuthorityRejectsProfileChangesAndABAStoreReopens() {
        let profileA = UUID()
        let profileB = UUID()
        let captured = NuvioPlaybackScopeAuthority(
            profileID: profileA,
            serviceStoreGeneration: 41
        )

        XCTAssertTrue(captured.matches(profileID: profileA, serviceStoreGeneration: 41))
        XCTAssertFalse(captured.matches(profileID: profileB, serviceStoreGeneration: 41))
        XCTAssertFalse(
            captured.matches(profileID: profileA, serviceStoreGeneration: 43),
            "Returning to the same profile must not revive work captured before its Services store reopened"
        )

        XCTAssertTrue(ProviderPlaybackTransportPolicy.hasSameHTTPOrigin(
            URL(string: "https://media.example/video")!,
            URL(string: "https://MEDIA.example:443/subtitle")!
        ))
        XCTAssertFalse(ProviderPlaybackTransportPolicy.hasSameHTTPOrigin(
            URL(string: "https://media.example/video")!,
            URL(string: "http://media.example/subtitle")!
        ))
        XCTAssertFalse(ProviderPlaybackTransportPolicy.hasSameHTTPOrigin(
            URL(string: "https://media.example/video")!,
            URL(string: "https://media.example:444/subtitle")!
        ))
        XCTAssertTrue(ProviderPlaybackTransportPolicy.mayAttemptExternalHandoff(
            autoModeLaunch: false,
            forceAutomaticPlayback: false,
            hasResolvedRequestConsumer: false
        ))
        XCTAssertTrue(ProviderPlaybackTransportPolicy.mayAttemptExternalHandoff(
            autoModeLaunch: false,
            forceAutomaticPlayback: false,
            hasResolvedRequestConsumer: true
        ), "A manual source selection must hand off the validated original URL before it becomes a loopback proxy request")
        XCTAssertFalse(ProviderPlaybackTransportPolicy.mayAttemptExternalHandoff(
            autoModeLaunch: true,
            forceAutomaticPlayback: false,
            hasResolvedRequestConsumer: false
        ))
        XCTAssertFalse(ProviderPlaybackTransportPolicy.mayAttemptExternalHandoff(
            autoModeLaunch: false,
            forceAutomaticPlayback: true,
            hasResolvedRequestConsumer: false
        ))
        XCTAssertEqual(ServicesHighQualityThresholdPolicy.sanitized(.nan), 0.9)
        XCTAssertEqual(ServicesHighQualityThresholdPolicy.sanitized(.infinity), 0.9)
        XCTAssertEqual(ServicesHighQualityThresholdPolicy.sanitized(-100), 0)
        XCTAssertEqual(ServicesHighQualityThresholdPolicy.sanitized(1e300), 1)
        XCTAssertEqual(ServicesHighQualityThresholdPolicy.percentage(.nan), 90)
        XCTAssertEqual(ServicesHighQualityThresholdPolicy.percentage(1e300), 100)
        XCTAssertEqual(
            ServicesHighQualityThresholdPolicy.percentage(
                -.infinity,
                usesRankingRange: true
            ),
            85
        )
    }

    func testSkyServiceScopeAuthorityRejectsProfileChangesAndABAStoreReopens() {
        let profileA = UUID()
        let profileB = UUID()
        let captured = SkyStreamServiceScopeAuthority(
            profileID: profileA,
            serviceStoreGeneration: 71
        )

        XCTAssertTrue(captured.matches(profileID: profileA, serviceStoreGeneration: 71))
        XCTAssertFalse(captured.matches(profileID: profileB, serviceStoreGeneration: 71))
        XCTAssertFalse(captured.matches(profileID: profileA, serviceStoreGeneration: 73))
    }

    func testServicePluginAdministrationFailsClosedForKidsProfiles() {
        XCTAssertTrue(
            ServicePluginAdministrativeAdmissionPolicy.permits(
                isKidsProfile: false
            )
        )
        XCTAssertFalse(
            ServicePluginAdministrativeAdmissionPolicy.permits(
                isKidsProfile: true
            )
        )
    }

    func testPlaybackHeaderSanitizerKeepsValidCredentialsAndDropsUnsafeNeighbors() {
        let sanitized = NuvioPluginSupport.sanitizedHeaders([
            "Authorization": "Bearer valid-token",
            "Cookie": "session=valid",
            "Referer": "https://watch.example/title",
            "Origin": "https://watch.example",
            "User-Agent": "Fixture/1.0",
            "X-Trace": "valid",
            "Host": "127.0.0.1",
            "Range": "bytes=0-9",
            "Connection": "keep-alive",
            "Injected": "safe\r\nX-Evil: yes",
            "Bad Header": "value"
        ])

        XCTAssertEqual(sanitized?["authorization"], "Bearer valid-token")
        XCTAssertEqual(sanitized?["cookie"], "session=valid")
        XCTAssertEqual(sanitized?["referer"], "https://watch.example/title")
        XCTAssertEqual(sanitized?["origin"], "https://watch.example")
        XCTAssertEqual(sanitized?["user-agent"], "Fixture/1.0")
        XCTAssertEqual(sanitized?["x-trace"], "valid")
        for forbidden in ["host", "range", "connection", "injected", "bad header"] {
            XCTAssertNil(sanitized?[forbidden], forbidden)
        }
    }

    func testPlaybackHeaderSanitizerBoundsCountAndAggregateBytesWithoutDroppingValidPrefix() {
        var headers: [String: String] = [
            "Cookie": "session=still-valid",
            "Authorization": "Bearer still-valid"
        ]
        for index in 0..<100 {
            headers[String(format: "Z-%03d", index)] = String(repeating: "v", count: 700)
        }

        let sanitized = NuvioPluginSupport.sanitizedHeaders(headers)
        XCTAssertEqual(sanitized?["cookie"], "session=still-valid")
        XCTAssertEqual(sanitized?["authorization"], "Bearer still-valid")
        XCTAssertLessThanOrEqual(sanitized?.count ?? 0, 64)
        let byteCount = sanitized?.reduce(0) {
            $0 + $1.key.utf8.count + $1.value.utf8.count + 4
        } ?? 0
        XCTAssertLessThanOrEqual(byteCount, 32 * 1024)
    }

    func testHugeAndNonFiniteNumericSettingsCannotTrapOrPersist() {
        let huge = NuvioSettingsValue.number(1e300)
        XCTAssertFalse(huge.stringValue.isEmpty)
        XCTAssertEqual(huge.sanitizedForPersistence, huge)
        XCTAssertFalse(
            NuvioSettingsValue.number(Double(Int.max)).stringValue.isEmpty,
            "Double(Int.max) rounds to 2^63 and must not enter a trapping Int conversion"
        )

        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            let value = NuvioSettingsValue.number(invalid)
            XCTAssertEqual(value.stringValue, "")
            XCTAssertFalse(value.boolValue)
            XCTAssertNil(value.sanitizedForPersistence)
        }
    }

    func testPinnedRedirectMethodRulesMatchBrowserFetchCompatibility() {
        XCTAssertTrue(SkyStreamPinnedHTTPClient.redirectChangesToGET(status: 301, method: "POST"))
        XCTAssertTrue(SkyStreamPinnedHTTPClient.redirectChangesToGET(status: 302, method: "POST"))
        XCTAssertTrue(SkyStreamPinnedHTTPClient.redirectChangesToGET(status: 303, method: "PATCH"))
        XCTAssertFalse(SkyStreamPinnedHTTPClient.redirectChangesToGET(status: 303, method: "HEAD"))
        XCTAssertFalse(SkyStreamPinnedHTTPClient.redirectChangesToGET(status: 307, method: "POST"))
        XCTAssertFalse(SkyStreamPinnedHTTPClient.redirectChangesToGET(status: 308, method: "PUT"))
    }

    func testProtectedDownloadPlanDispatchesOnlyThroughFreshProxy() throws {
        let remote = try XCTUnwrap(URL(string: "https://media.example/movie.mp4?token=secret"))
        let proxy = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/session-token"))
        let plan = NuvioDownloadTransportPlan.protectedAttempt(
            authoritativeURL: remote,
            authoritativeHeaders: ["Authorization": "Bearer secret"],
            proxyURL: proxy
        )

        XCTAssertEqual(plan.authoritativeURL, remote)
        XCTAssertEqual(plan.authoritativeHeaders["Authorization"], "Bearer secret")
        XCTAssertEqual(plan.dispatchURL, proxy)
        XCTAssertTrue(plan.dispatchHeaders.isEmpty)
        XCTAssertFalse(plan.mayUseResumeData)
        XCTAssertTrue(plan.mustRegenerateHLSCheckpoint)
    }

    func testNuvioPersistenceScrubsEveryTransportSecretAndForcesRefresh() throws {
        let sourceID = "nuvio:fixture"
        let owner = UUID()
        let reference = ProviderContentReference.nuvio(
            NuvioProviderContentReference(
                sourceID: sourceID,
                scraperID: "fixture-scraper",
                tmdbID: "42",
                mediaType: "movie"
            )
        )
        var item = DownloadItem(
            id: "dl_movie_42",
            tmdbId: 42,
            isMovie: true,
            title: "Fixture",
            displayTitle: "Fixture",
            posterURL: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            episodeName: nil,
            streamURL: "https://media.example/master.m3u8?token=stream-secret",
            headers: ["Authorization": "Bearer main-secret", "Cookie": "sid=main-secret"],
            subtitleURL: "https://subs.example/subtitle.vtt?token=subtitle-secret",
            subtitleHeaders: ["Authorization": "Bearer subtitle-secret"],
            serviceBaseURL: "https://legacy.example?token=legacy-base-secret",
            sourceId: "service:legacy",
            serviceContentHref: "https://legacy.example/title?token=legacy-href-secret",
            lastSourceId: sourceID,
            lastContentReference: reference,
            nuvioTransportKind: .hls,
            nuvioOwnerProfileID: owner,
            status: .queued,
            progress: 0.5,
            totalBytes: 1_000,
            downloadedBytes: 500,
            localFileName: nil,
            subtitleFileName: nil,
            error: nil,
            dateAdded: Date(timeIntervalSince1970: 1),
            dateCompleted: nil,
            isAnime: false,
            hlsResumeSegmentIndex: 12,
            hlsResumeByteCount: 500,
            hlsVariantURL: "http://127.0.0.1:49152/proxy-token/variant.m3u8",
            hlsTotalSegments: 30
        )
        item = DownloadManager.persistedDownloadItem(item)

        XCTAssertEqual(item.streamURL, "")
        XCTAssertTrue(item.headers.isEmpty)
        XCTAssertNil(item.subtitleURL)
        XCTAssertNil(item.subtitleHeaders)
        XCTAssertNil(item.hlsVariantURL)
        XCTAssertNil(item.hlsResumeSegmentIndex)
        XCTAssertNil(item.hlsResumeByteCount)
        XCTAssertNil(item.hlsTotalSegments)
        XCTAssertEqual(item.nuvioTransportKind, .hls)
        XCTAssertEqual(item.nuvioOwnerProfileID, owner)
        XCTAssertTrue(item.isHLS)
        XCTAssertTrue(
            NuvioDownloadPersistencePolicy.requiresFreshResolution(
                claimsNuvio: true,
                streamURL: item.streamURL
            )
        )
        XCTAssertFalse(
            NuvioDownloadPersistencePolicy.mayAdoptRestoredBackgroundTask(claimsNuvio: true)
        )
        XCTAssertFalse(
            NuvioDownloadPersistencePolicy.mayClaimDirectTaskCallback(
                claimsNuvio: true,
                registeredProtectedTaskIdentifier: nil,
                callbackTaskIdentifier: 41
            )
        )
        XCTAssertFalse(
            NuvioDownloadPersistencePolicy.mayClaimDirectTaskCallback(
                claimsNuvio: true,
                registeredProtectedTaskIdentifier: 40,
                callbackTaskIdentifier: 41
            )
        )
        XCTAssertTrue(
            NuvioDownloadPersistencePolicy.mayClaimDirectTaskCallback(
                claimsNuvio: true,
                registeredProtectedTaskIdentifier: 41,
                callbackTaskIdentifier: 41
            )
        )

        let encoded = try JSONEncoder().encode(item)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in [
            "https://media.example",
            "https://subs.example",
            "127.0.0.1",
            "legacy.example",
            "legacy-base-secret",
            "legacy-href-secret",
            "stream-secret",
            "subtitle-secret",
            "main-secret",
            "Authorization",
            "Cookie"
        ] {
            XCTAssertFalse(encodedText.contains(forbidden), forbidden)
        }
    }

    func testNuvioProfileOwnerBlocksCrossProfileRestoreAndValidationRace() {
        let ownerA = UUID()
        let profileB = UUID()

        XCTAssertEqual(
            NuvioDownloadPersistencePolicy.profileAuthority(
                ownerProfileID: ownerA,
                activeProfileID: ownerA
            ),
            .authorized
        )
        XCTAssertEqual(
            NuvioDownloadPersistencePolicy.profileAuthority(
                ownerProfileID: ownerA,
                activeProfileID: profileB
            ),
            .waitingForOwner
        )
        XCTAssertEqual(
            NuvioDownloadPersistencePolicy.profileAuthority(
                ownerProfileID: ownerA,
                activeProfileID: ownerA
            ),
            .authorized
        )

        XCTAssertTrue(
            NuvioDownloadPersistencePolicy.validatedEnqueueAuthorityIsCurrent(
                ownerProfileID: ownerA,
                capturedScopeGeneration: 7,
                activeProfileID: ownerA,
                currentScopeGeneration: 7
            )
        )
        XCTAssertFalse(
            NuvioDownloadPersistencePolicy.validatedEnqueueAuthorityIsCurrent(
                ownerProfileID: ownerA,
                capturedScopeGeneration: 7,
                activeProfileID: profileB,
                currentScopeGeneration: 8
            )
        )
    }

    func testProtectedDownloadAttemptWaitsForSubtitleConsumerBeforeRelease() {
        XCTAssertFalse(
            NuvioDownloadAttemptLifecycle.mayReleaseAttempt(
                mainFinished: true,
                subtitleSessionCount: 1
            )
        )
        XCTAssertFalse(
            NuvioDownloadAttemptLifecycle.mayReleaseAttempt(
                mainFinished: false,
                subtitleSessionCount: 0
            )
        )
        XCTAssertTrue(
            NuvioDownloadAttemptLifecycle.mayReleaseAttempt(
                mainFinished: true,
                subtitleSessionCount: 0
            )
        )
    }

    func testNuvioAuthorityClaimsFailClosedWhenReferenceAndSourceDisagree() {
        let sourceID = "nuvio:fixture"
        let reference = ProviderContentReference.nuvio(
            NuvioProviderContentReference(
                sourceID: sourceID,
                scraperID: "fixture-scraper",
                tmdbID: "42",
                mediaType: "movie"
            )
        )
        XCTAssertEqual(
            NuvioDownloadAuthorityState.classify(sourceID: sourceID, reference: reference),
            .authorized
        )
        XCTAssertEqual(
            NuvioDownloadAuthorityState.classify(sourceID: "nuvio:other", reference: reference),
            .invalid
        )
        XCTAssertEqual(
            NuvioDownloadAuthorityState.classify(sourceID: nil, reference: reference),
            .invalid
        )
    }

    func testServicePersistenceKeepsOnlyBoundedAuthorityAndNonsecretMarkers() throws {
        let sourceID = "service:fixture"
        let owner = UUID()
        let reference = ProviderContentReference.service(
            sourceID: sourceID,
            href: "https://catalog.example/title/42"
        )
        let item = DownloadItem(
            id: "dl_movie_42",
            tmdbId: 42,
            isMovie: true,
            title: "Fixture",
            displayTitle: "Fixture",
            posterURL: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            episodeName: nil,
            streamURL: "https://media.example/master.m3u8?token=stream-secret",
            headers: ["Authorization": "Bearer main-secret", "Cookie": "sid=secret"],
            subtitleURL: "https://subs.example/sub.vtt?token=subtitle-secret",
            subtitleHeaders: ["Referer": "https://secret.example/", "Authorization": "secret"],
            serviceBaseURL: "https://service.example/?token=base-secret",
            sourceId: sourceID,
            serviceContentHref: "https://catalog.example/title/42",
            lastSourceId: sourceID,
            lastContentReference: reference,
            protectedProviderKind: .service,
            protectedTransportKind: .hls,
            protectedOwnerProfileID: owner,
            status: .queued,
            progress: 0.6,
            totalBytes: 1_000,
            downloadedBytes: 600,
            localFileName: nil,
            subtitleFileName: nil,
            error: nil,
            dateAdded: Date(timeIntervalSince1970: 1),
            dateCompleted: nil,
            isAnime: false,
            hlsResumeSegmentIndex: 12,
            hlsResumeByteCount: 600,
            hlsVariantURL: "http://127.0.0.1:49152/expired/variant.m3u8",
            hlsTotalSegments: 20
        )

        let persisted = DownloadManager.persistedDownloadItem(item)
        XCTAssertEqual(persisted.protectedProviderKind, .service)
        XCTAssertEqual(persisted.protectedTransportKind, .hls)
        XCTAssertEqual(persisted.protectedOwnerProfileID, owner)
        XCTAssertEqual(persisted.lastSourceId, sourceID)
        XCTAssertEqual(persisted.lastContentReference, reference)
        XCTAssertTrue(persisted.isHLS)
        XCTAssertEqual(persisted.streamURL, "")
        XCTAssertTrue(persisted.headers.isEmpty)
        XCTAssertNil(persisted.subtitleURL)
        XCTAssertNil(persisted.subtitleHeaders)
        XCTAssertNil(persisted.hlsVariantURL)
        XCTAssertNil(persisted.hlsResumeSegmentIndex)
        XCTAssertNil(persisted.hlsResumeByteCount)
        XCTAssertNil(persisted.hlsTotalSegments)
        XCTAssertFalse(
            ProtectedDownloadPersistencePolicy.mayAdoptRestoredBackgroundTask(
                claimsProtectedProvider: true
            )
        )

        let encodedText = try XCTUnwrap(String(
            data: JSONEncoder().encode(persisted),
            encoding: .utf8
        ))
        for forbidden in [
            "media.example", "subs.example", "secret.example", "127.0.0.1",
            "stream-secret", "subtitle-secret", "main-secret", "base-secret",
            "Authorization", "Cookie"
        ] {
            XCTAssertFalse(encodedText.contains(forbidden), forbidden)
        }
    }

    func testServiceProtectedAuthorityDistinguishesRefreshableAndLegacyRows() {
        let sourceID = "service:fixture"
        let reference = ProviderContentReference.service(
            sourceID: sourceID,
            href: "https://catalog.example/title/42"
        )
        XCTAssertEqual(
            ProtectedDownloadAuthorityState.classify(
                explicitKind: .service,
                hasLegacyNuvioMarker: false,
                sourceID: sourceID,
                reference: reference
            ),
            .authorized(.service)
        )
        XCTAssertEqual(
            ProtectedDownloadAuthorityState.classify(
                explicitKind: .service,
                hasLegacyNuvioMarker: false,
                sourceID: sourceID,
                reference: nil
            ),
            .legacyService
        )
        XCTAssertEqual(
            ProtectedDownloadAuthorityState.classify(
                explicitKind: .service,
                hasLegacyNuvioMarker: false,
                sourceID: "service:other",
                reference: reference
            ),
            .invalid
        )
        XCTAssertTrue(
            ProtectedDownloadPersistencePolicy.requiresReselectionAfterRelaunch(
                providerKind: .service,
                hasAuthoritativeReference: false,
                streamURL: ""
            )
        )
        XCTAssertFalse(
            ProtectedDownloadPersistencePolicy.mayClaimDirectTaskCallback(
                claimsProtectedProvider: true,
                registeredProtectedTaskIdentifier: nil,
                callbackTaskIdentifier: 7
            )
        )
    }

    func testStremioProtectedAuthorityAndPersistenceRequireFreshResolution() throws {
        let addonID = UUID()
        let sourceID = "stremio:\(addonID.uuidString)"
        let owner = UUID()
        let reference = ProviderContentReference(
            kind: .stremio,
            sourceID: sourceID,
            stremioContentID: "tt1234567",
            stremioContentType: "movie",
            stremioStreamOrdinal: 0,
            stremioSubtitleOrdinal: 0
        )
        XCTAssertTrue(reference.hasValidStremioSelection)
        XCTAssertEqual(
            ProtectedDownloadAuthorityState.classify(
                explicitKind: .stremio,
                hasLegacyNuvioMarker: false,
                sourceID: sourceID,
                reference: reference
            ),
            .authorized(.stremio)
        )
        XCTAssertEqual(
            ProtectedDownloadAuthorityState.classify(
                explicitKind: .stremio,
                hasLegacyNuvioMarker: false,
                sourceID: sourceID,
                reference: nil
            ),
            .legacyStremio
        )
        XCTAssertEqual(
            ProtectedDownloadAuthorityState.classify(
                explicitKind: .stremio,
                hasLegacyNuvioMarker: false,
                sourceID: "stremio:\(UUID().uuidString)",
                reference: reference
            ),
            .invalid
        )

        let item = DownloadItem(
            id: "dl_movie_91",
            tmdbId: 91,
            isMovie: true,
            title: "Fixture",
            displayTitle: "Fixture",
            posterURL: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            episodeName: nil,
            streamURL: "https://media.example/master.m3u8?token=stream-secret",
            headers: ["Authorization": "Bearer main-secret", "Cookie": "sid=secret"],
            subtitleURL: "https://subs.example/sub.vtt?token=subtitle-secret",
            subtitleHeaders: ["Authorization": "Bearer subtitle-secret"],
            serviceBaseURL: "http://192.168.1.10/addon?token=config-secret",
            lastSourceId: sourceID,
            lastContentReference: reference,
            protectedProviderKind: .stremio,
            protectedTransportKind: .hls,
            protectedOwnerProfileID: owner,
            status: .queued,
            progress: 0.75,
            totalBytes: 1_000,
            downloadedBytes: 750,
            localFileName: nil,
            subtitleFileName: nil,
            error: nil,
            dateAdded: Date(timeIntervalSince1970: 1),
            dateCompleted: nil,
            isAnime: false,
            hlsResumeSegmentIndex: 9,
            hlsResumeByteCount: 750,
            hlsVariantURL: "http://127.0.0.1:49152/expired/variant.m3u8",
            hlsTotalSegments: 12
        )

        let persisted = DownloadManager.persistedDownloadItem(item)
        XCTAssertEqual(persisted.protectedProviderKind, .stremio)
        XCTAssertEqual(persisted.protectedTransportKind, .hls)
        XCTAssertEqual(persisted.protectedOwnerProfileID, owner)
        XCTAssertEqual(persisted.lastContentReference, reference)
        XCTAssertTrue(persisted.isHLS)
        XCTAssertEqual(persisted.streamURL, "")
        XCTAssertTrue(persisted.headers.isEmpty)
        XCTAssertNil(persisted.subtitleURL)
        XCTAssertNil(persisted.subtitleHeaders)
        XCTAssertNil(persisted.hlsVariantURL)
        XCTAssertNil(persisted.hlsResumeSegmentIndex)
        XCTAssertFalse(
            ProtectedDownloadPersistencePolicy.mayAdoptRestoredBackgroundTask(
                claimsProtectedProvider: true
            )
        )
        XCTAssertTrue(
            ProtectedDownloadPersistencePolicy.requiresReselectionAfterRelaunch(
                providerKind: .stremio,
                hasAuthoritativeReference: false,
                streamURL: ""
            )
        )

        let encoded = try XCTUnwrap(String(
            data: JSONEncoder().encode(persisted),
            encoding: .utf8
        ))
        for forbidden in [
            "media.example", "subs.example", "192.168.1.10", "127.0.0.1",
            "stream-secret", "subtitle-secret", "config-secret", "main-secret",
            "Authorization", "Cookie"
        ] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }

    func testLegacyStremioMigrationRequiresOneExactUnambiguousAddonMatch() {
        let addonID = UUID()
        let configured = "http://192.168.1.20:11470/private-addon"
        XCTAssertEqual(
            ProtectedDownloadPersistencePolicy.legacyStremioSourceID(
                serviceBaseURL: configured + "/",
                configuredAddons: [addonID: configured]
            ),
            "stremio:\(addonID.uuidString)"
        )
        XCTAssertNil(
            ProtectedDownloadPersistencePolicy.legacyStremioSourceID(
                serviceBaseURL: "http://192.168.1.20:11470/other-addon",
                configuredAddons: [addonID: configured]
            )
        )
        XCTAssertNil(
            ProtectedDownloadPersistencePolicy.legacyStremioSourceID(
                serviceBaseURL: configured,
                configuredAddons: [addonID: configured, UUID(): configured]
            ),
            "Ambiguous legacy identity must fail closed instead of selecting an addon."
        )
    }

    func testPinnedProxyPrivateAddressesRequireExplicitConfiguredAuthorityFlag() {
        XCTAssertNil(
            MPVHeaderProxyPinnedAddressPolicy.normalizeApprovedAddress(
                "192.168.1.10",
                permitsPrivateApprovedAddresses: false
            )
        )
        XCTAssertEqual(
            MPVHeaderProxyPinnedAddressPolicy.normalizeApprovedAddress(
                "192.168.1.10",
                permitsPrivateApprovedAddresses: true
            ),
            "192.168.1.10"
        )
        XCTAssertEqual(
            MPVHeaderProxyPinnedAddressPolicy.normalizeApprovedAddress(
                "8.8.8.8",
                permitsPrivateApprovedAddresses: false
            ),
            "8.8.8.8"
        )
    }

    func testSkyStreamDirectPersistenceRequiresFreshPinnedAttempt() throws {
        let skyReference = SkyStreamProviderContentReference(
            packageName: "fixture.plugin",
            providerID: "primary",
            scriptSHA256: String(repeating: "a", count: 64),
            pluginVersion: 1,
            loadedItemURL: "https://catalog.example/title/42",
            contentType: .movie,
            title: "Fixture",
            year: 2026
        )
        let reference = ProviderContentReference.skyStream(skyReference)
        let owner = UUID()
        let item = DownloadItem(
            id: "dl_movie_42",
            tmdbId: 42,
            isMovie: true,
            title: "Fixture",
            displayTitle: "Fixture",
            posterURL: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            episodeName: nil,
            streamURL: "https://media.example/movie.mp4?token=stream-secret",
            headers: ["Authorization": "Bearer secret", "Cookie": "sid=secret"],
            subtitleURL: "https://subs.example/sub.vtt?token=subtitle-secret",
            subtitleHeaders: ["Authorization": "Bearer subtitle-secret"],
            serviceBaseURL: "https://media.example",
            lastSourceId: skyReference.sourceID,
            lastContentReference: reference,
            providerTransportKind: .skyStreamDirect,
            protectedProviderKind: .skyStream,
            protectedTransportKind: .direct,
            protectedOwnerProfileID: owner,
            status: .queued,
            progress: 0.5,
            totalBytes: 1_000,
            downloadedBytes: 500,
            localFileName: nil,
            subtitleFileName: nil,
            error: nil,
            dateAdded: Date(timeIntervalSince1970: 1),
            dateCompleted: nil,
            isAnime: false,
            hlsResumeSegmentIndex: 4,
            hlsResumeByteCount: 500,
            hlsVariantURL: "http://127.0.0.1:49152/expired/variant.m3u8",
            hlsTotalSegments: 10
        )

        XCTAssertEqual(
            ProtectedDownloadAuthorityState.classify(
                explicitKind: item.protectedProviderKind,
                hasLegacyNuvioMarker: false,
                sourceID: item.lastSourceId,
                reference: item.lastContentReference
            ),
            .authorized(.skyStream)
        )

        let persisted = DownloadManager.persistedDownloadItem(item)
        XCTAssertEqual(persisted.protectedProviderKind, .skyStream)
        XCTAssertEqual(persisted.protectedTransportKind, .direct)
        XCTAssertEqual(persisted.protectedOwnerProfileID, owner)
        XCTAssertEqual(persisted.lastContentReference, reference)
        XCTAssertEqual(persisted.streamURL, "")
        XCTAssertTrue(persisted.headers.isEmpty)
        XCTAssertNil(persisted.subtitleURL)
        XCTAssertNil(persisted.subtitleHeaders)
        XCTAssertNil(persisted.hlsVariantURL)
        XCTAssertNil(persisted.hlsResumeSegmentIndex)
        XCTAssertFalse(
            ProtectedDownloadPersistencePolicy.mayAdoptRestoredBackgroundTask(
                claimsProtectedProvider: true
            )
        )

        let encoded = try XCTUnwrap(String(
            data: JSONEncoder().encode(persisted),
            encoding: .utf8
        ))
        for forbidden in [
            "media.example", "subs.example", "127.0.0.1", "stream-secret",
            "subtitle-secret", "Authorization", "Cookie", "Bearer secret"
        ] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }

    func testOversizedNuvioStoredStateIsRejectedBeforeDecode() {
        XCTAssertTrue(
            NuvioPluginStore.persistedStateDataIsWithinLimit(
                Data(count: NuvioPluginStore.Bounds.persistedStateBytes)
            )
        )
        XCTAssertFalse(
            NuvioPluginStore.persistedStateDataIsWithinLimit(
                Data(count: NuvioPluginStore.Bounds.persistedStateBytes + 1)
            )
        )

        let suiteName = "NuvioOversizedStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(count: NuvioPluginStore.Bounds.persistedStateBytes + 1),
            forKey: "nuvioPluginsState.v2"
        )
        let loaded = NuvioPluginStore(defaults: defaults).load()
        XCTAssertTrue(loaded.repositories.isEmpty)
        XCTAssertTrue(loaded.scrapers.isEmpty)
        XCTAssertTrue(loaded.scraperSettings.isEmpty)
    }

    func testNuvioStoredCodeMetadataRejectsOversizedAndNonRegularFiles() {
        XCTAssertTrue(
            NuvioPluginStore.codeFileMetadataIsWithinLimit(
                size: UInt64(NuvioPluginStore.Bounds.codeBytes),
                isRegularFile: true
            )
        )
        XCTAssertFalse(
            NuvioPluginStore.codeFileMetadataIsWithinLimit(
                size: UInt64(NuvioPluginStore.Bounds.codeBytes) + 1,
                isRegularFile: true
            )
        )
        XCTAssertFalse(
            NuvioPluginStore.codeFileMetadataIsWithinLimit(size: 1, isRegularFile: false)
        )
    }

    func testDownloadMetadataPreflightBoundsBytesShapeAndTopLevelItemCount() {
        XCTAssertTrue(
            DownloadMetadataPersistencePolicy.fileMetadataIsWithinLimit(
                size: UInt64(DownloadMetadataPersistencePolicy.Bounds.fileBytes),
                isRegularFile: true
            )
        )
        XCTAssertFalse(
            DownloadMetadataPersistencePolicy.fileMetadataIsWithinLimit(
                size: UInt64(DownloadMetadataPersistencePolicy.Bounds.fileBytes) + 1,
                isRegularFile: true
            )
        )
        XCTAssertFalse(
            DownloadMetadataPersistencePolicy.fileMetadataIsWithinLimit(
                size: 1,
                isRegularFile: false
            )
        )

        XCTAssertTrue(
            DownloadMetadataPersistencePolicy.metadataJSONPassesPreflight(
                Data(#"[{"id":"one","nested":{"values":[1,2]}},{"id":"two"}]"#.utf8),
                maximumItems: 2
            )
        )
        XCTAssertFalse(
            DownloadMetadataPersistencePolicy.metadataJSONPassesPreflight(
                Data(#"[{"id":"one"},{"id":"two"},{"id":"three"}]"#.utf8),
                maximumItems: 2
            )
        )
        XCTAssertFalse(
            DownloadMetadataPersistencePolicy.metadataJSONPassesPreflight(
                Data(#"["not-an-item"]"#.utf8),
                maximumItems: 2
            )
        )
    }

    func testDownloadMetadataNormalizationDropsUnsafeFieldsAndRedactsLegacyProviderError() throws {
        let sourceID = "service:fixture"
        var item = DownloadItem(
            id: "dl_movie_42",
            tmdbId: 42,
            isMovie: true,
            title: "Fixture",
            displayTitle: "Fixture",
            posterURL: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            episodeName: nil,
            streamURL: "https://media.example/movie.mp4\r\nX-Evil: yes",
            headers: [
                "Authorization": "Bearer valid",
                "Injected": "safe\r\nX-Evil: yes"
            ],
            subtitleURL: nil,
            subtitleHeaders: nil,
            serviceBaseURL: "https://service.example",
            lastSourceId: sourceID,
            lastContentReference: .service(
                sourceID: sourceID,
                href: "https://catalog.example/title/42"
            ),
            protectedProviderKind: .service,
            protectedTransportKind: .direct,
            protectedOwnerProfileID: UUID(),
            status: .failed,
            progress: 4,
            totalBytes: 10,
            downloadedBytes: 40,
            localFileName: "/outside/movie.mp4",
            subtitleFileName: nil,
            error: "Failed https://media.example/movie.mp4?token=legacy-secret",
            dateAdded: Date(timeIntervalSince1970: 1),
            dateCompleted: nil,
            isAnime: false
        )
        item.hlsResumeSegmentIndex = -1

        let normalized = DownloadMetadataPersistencePolicy.normalizedLoadedItems([item])
        let loaded = try XCTUnwrap(normalized.items.first)
        XCTAssertTrue(normalized.wasChanged)
        XCTAssertEqual(loaded.streamURL, "")
        XCTAssertEqual(loaded.headers, ["Authorization": "Bearer valid"])
        XCTAssertEqual(loaded.progress, 1)
        XCTAssertEqual(loaded.downloadedBytes, 10)
        XCTAssertNil(loaded.localFileName)
        XCTAssertNil(loaded.hlsResumeSegmentIndex)
        XCTAssertEqual(loaded.error, "The provider download must be retried.")

        let persisted = DownloadManager.persistedDownloadItem(loaded)
        let encoded = try XCTUnwrap(String(
            data: JSONEncoder().encode(persisted),
            encoding: .utf8
        ))
        XCTAssertFalse(encoded.contains("legacy-secret"))
        XCTAssertFalse(encoded.contains("Bearer valid"))
        XCTAssertFalse(encoded.contains("media.example"))

        var rawRows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode([item, item]))
                as? [[String: Any]]
        )
        rawRows[0]["tmdbId"] = "not-an-integer"
        let mixedData = try JSONSerialization.data(withJSONObject: rawRows)
        let lossy = try DownloadMetadataPersistencePolicy.decodeAndNormalizeLoadedItems(
            from: mixedData
        )
        XCTAssertTrue(lossy.wasChanged)
        XCTAssertEqual(lossy.items.count, 1, "A corrupt row must not discard a valid completed/library row.")
    }
}
#endif

#if !os(tvOS)
final class MPVPreloadPinnedTransportTests: XCTestCase {
    func testProxyLogSummaryOmitsEveryCredentialBearingURLComponent() throws {
        let sensitiveURL = try XCTUnwrap(
            URL(string: "https://signed-user:signed-password@media.example:8443/private/path-token/master.m3u8?auth=query-token#fragment-token")
        )
        let summary = MPVHeaderProxyLogSanitizer.summary(for: sensitiveURL)

        XCTAssertEqual(summary, "https://media.example:8443")
        for secret in [
            "signed-user", "signed-password", "private", "path-token",
            "master.m3u8", "query-token", "fragment-token", "@"
        ] {
            XCTAssertFalse(summary.contains(secret), secret)
        }

        XCTAssertEqual(
            MPVHeaderProxyLogSanitizer.summary(
                for: try XCTUnwrap(URL(string: "https://media.example:443/another-secret"))
            ),
            "https://media.example"
        )
    }

    func testCrossOriginRedirectRevokesOnlyTheDestinationOrigin() throws {
        let credentialOrigin = try XCTUnwrap(URL(string: "https://origin.example/show/master.m3u8"))
        let burnedDestination = try XCTUnwrap(URL(string: "https://tracker.example/beacon"))

        XCTAssertTrue(
            MPVHeaderProxyRevokedOriginSet.requiresRevocation(
                from: credentialOrigin,
                to: burnedDestination,
                credentialOriginURL: credentialOrigin
            )
        )

        var revoked = MPVHeaderProxyRevokedOriginSet()
        revoked.revoke(destinationURL: burnedDestination)

        XCTAssertTrue(
            revoked.revokesCredentials(
                for: try XCTUnwrap(URL(string: "https://tracker.example/other/path?q=1")),
                credentialOriginURL: credentialOrigin
            ),
            "A burned destination origin must stay burned for every later request"
        )
        XCTAssertFalse(
            revoked.revokesCredentials(
                for: try XCTUnwrap(URL(string: "https://origin.example/show/variant/720.m3u8")),
                credentialOriginURL: credentialOrigin
            ),
            "The session's own credential origin must keep full credentials after an unrelated origin is burned"
        )
        XCTAssertFalse(
            revoked.revokesCredentials(
                for: try XCTUnwrap(URL(string: "https://cdn.example/segment-0001.ts")),
                credentialOriginURL: credentialOrigin
            ),
            "A never-burned third origin keeps the ordinary cross-origin credential scoping"
        )
        XCTAssertFalse(
            MPVHeaderProxyRevokedOriginSet.requiresRevocation(
                from: burnedDestination,
                to: try XCTUnwrap(URL(string: "https://origin.example/show/master.m3u8?retry=1")),
                credentialOriginURL: credentialOrigin
            ),
            "A redirect back to the credential origin must never burn the credential origin itself"
        )
    }

    func testSameHostSchemeUpgradeRedirectDoesNotRevoke() throws {
        let credentialOrigin = try XCTUnwrap(URL(string: "http://origin.example/show/master.m3u8"))

        XCTAssertFalse(
            MPVHeaderProxyRevokedOriginSet.requiresRevocation(
                from: credentialOrigin,
                to: try XCTUnwrap(URL(string: "https://origin.example/show/master.m3u8")),
                credentialOriginURL: credentialOrigin
            )
        )
        XCTAssertFalse(
            MPVHeaderProxyRevokedOriginSet.requiresRevocation(
                from: try XCTUnwrap(URL(string: "http://origin.example:80/show/master.m3u8")),
                to: try XCTUnwrap(URL(string: "https://origin.example:443/show/master.m3u8")),
                credentialOriginURL: credentialOrigin
            )
        )
        XCTAssertTrue(
            MPVHeaderProxyRevokedOriginSet.requiresRevocation(
                from: credentialOrigin,
                to: try XCTUnwrap(URL(string: "https://upgraded.example/show/master.m3u8")),
                credentialOriginURL: credentialOrigin
            ),
            "An https redirect to a different host is not a scheme upgrade"
        )
        XCTAssertTrue(
            MPVHeaderProxyRevokedOriginSet.requiresRevocation(
                from: try XCTUnwrap(URL(string: "http://other.example:8080/path")),
                to: try XCTUnwrap(URL(string: "https://other.example:8443/path")),
                credentialOriginURL: credentialOrigin
            ),
            "A cross-port https hop is not a default-port scheme upgrade"
        )
    }

    func testRevokedOriginSetStaysBoundedAndOverflowFailsClosed() throws {
        let credentialOrigin = try XCTUnwrap(URL(string: "https://origin.example/show/master.m3u8"))
        var revoked = MPVHeaderProxyRevokedOriginSet()

        for index in 0...MPVHeaderProxyRevokedOriginSet.maximumTrackedOrigins {
            revoked.revoke(
                destinationURL: try XCTUnwrap(URL(string: "https://burned-\(index).example/path"))
            )
        }

        XCTAssertTrue(revoked.revokesAllCrossOriginDestinations)
        XCTAssertLessThanOrEqual(
            revoked.originKeys.count,
            MPVHeaderProxyRevokedOriginSet.maximumTrackedOrigins,
            "Overflow must collapse to revoke-everything-cross-origin, never unbounded growth"
        )
        XCTAssertTrue(
            revoked.revokesCredentials(
                for: try XCTUnwrap(URL(string: "https://never-seen.example/path")),
                credentialOriginURL: credentialOrigin
            ),
            "After overflow every cross-origin destination is revoked"
        )
        XCTAssertFalse(
            revoked.revokesCredentials(
                for: try XCTUnwrap(URL(string: "https://origin.example/still/works.ts")),
                credentialOriginURL: credentialOrigin
            ),
            "The credential origin keeps working even after overflow"
        )
    }

    func testRedirectedMasterAndMediaPlaylistsResolveRelativeChildrenAgainstFinalURL() throws {
        let requestedMaster = try XCTUnwrap(URL(string: "https://origin.example/show/master.m3u8"))
        let redirectedMaster = try XCTUnwrap(URL(string: "https://cdn.example/signed/root/master.m3u8?token=one"))
        let masterBase = MPVHeaderProxyPlaylistRouting.effectiveResponseURL(
            originalRequestURL: requestedMaster,
            responseURL: redirectedMaster
        )
        XCTAssertEqual(
            MPVHeaderProxyPlaylistRouting.resolve("variants/720/index.m3u8", againstPlaylistURL: masterBase),
            URL(string: "https://cdn.example/signed/root/variants/720/index.m3u8")
        )

        let requestedMedia = try XCTUnwrap(URL(string: "https://cdn.example/signed/root/variants/720/index.m3u8"))
        let redirectedMedia = try XCTUnwrap(URL(string: "https://edge.example/delivery/episode/720/index.m3u8?token=two"))
        let mediaBase = MPVHeaderProxyPlaylistRouting.effectiveResponseURL(
            originalRequestURL: requestedMedia,
            responseURL: redirectedMedia
        )
        XCTAssertEqual(
            MPVHeaderProxyPlaylistRouting.resolve("segment-0001.ts", againstPlaylistURL: mediaBase),
            URL(string: "https://edge.example/delivery/episode/720/segment-0001.ts")
        )
        XCTAssertEqual(
            MPVHeaderProxyPlaylistRouting.resolve("../keys/init.key", againstPlaylistURL: mediaBase),
            URL(string: "https://edge.example/delivery/episode/keys/init.key")
        )
    }

    func testOversizedIdentifiedPlaylistMustRejectInsteadOfRawPassthrough() {
        let limit = 5 * 1_024 * 1_024
        XCTAssertEqual(
            MPVHeaderProxyPlaylistFramingPolicy.action(
                bufferedByteCount: limit,
                maximumRewriteBytes: limit
            ),
            .continueBuffering
        )
        XCTAssertEqual(
            MPVHeaderProxyPlaylistFramingPolicy.action(
                bufferedByteCount: limit + 1,
                maximumRewriteBytes: limit
            ),
            .reject,
            "An identified playlist that cannot be fully rewritten must never expose raw child URLs"
        )
        XCTAssertTrue(
            MPVHeaderProxyPlaylistFramingPolicy.mustRejectIdentifiedPlaylist(
                isUTF8Decodable: false
            ),
            "An identified playlist with invalid text encoding must not pass through raw child URLs"
        )
    }

    func testGenericMediaDeclarationsCannotBypassHLSProbe() {
        let attackerControlledMediaDeclarations: [(String, String, Int64)] = [
            ("mp4", "video/mp4", 64 * 1_024 * 1_024),
            ("bin", "application/octet-stream", -1),
            ("", "application/octet-stream", Int64.max)
        ]

        for (pathExtension, contentType, expectedLength) in attackerControlledMediaDeclarations {
            XCTAssertEqual(
                MPVHeaderProxyGenericBodyPolicy.initialAction(
                    isPlaylistMetadata: false,
                    declaredContentType: contentType,
                    pathExtension: pathExtension,
                    expectedContentLength: expectedLength,
                    isValidatedResource: false,
                    hasVerifiedCachedMediaContinuation: false
                ),
                .probeGenericResponse,
                "Untrusted \(pathExtension)/\(contentType) metadata and length \(expectedLength) must not select raw streaming"
            )
        }

        XCTAssertEqual(
            MPVHeaderProxyGenericBodyPolicy.initialAction(
                isPlaylistMetadata: false,
                declaredContentType: "application/octet-stream",
                pathExtension: "mp4",
                expectedContentLength: Int64.max,
                isValidatedResource: true,
                hasVerifiedCachedMediaContinuation: false
            ),
            .probeValidatedResource,
            "Validated Sky child bodies must still be signature-probed so a typed segment cannot become a nested playlist"
        )
        XCTAssertEqual(
            MPVHeaderProxyGenericBodyPolicy.initialAction(
                isPlaylistMetadata: false,
                declaredContentType: "application/octet-stream",
                pathExtension: "mp4",
                expectedContentLength: Int64.max,
                isValidatedResource: false,
                hasVerifiedCachedMediaContinuation: true
            ),
            .streamVerifiedCachedMediaContinuation
        )
    }

    func testValidatedBinaryChildIsNotRejectedForAnM3U8Suffix() throws {
        let binaryChild = try XCTUnwrap(
            URL(string: "https://media.example.test/segments/0001.m3u8")
        )
        XCTAssertFalse(
            MPVHeaderProxyValidatedRouteResponsePolicy.rejectsManifest(
                role: "mediaSegment",
                contentType: "video/mp2t",
                responseURL: binaryChild
            )
        )
        XCTAssertTrue(
            MPVHeaderProxyValidatedRouteResponsePolicy.rejectsManifest(
                role: "mediaSegment",
                contentType: "application/vnd.apple.mpegurl",
                responseURL: binaryChild
            )
        )
    }

    func testGenericProbeRecognizesDisguisedAndOversizedHLSAndFailsClosedWhenAmbiguous() {
        let maliciousPlaylist = Data(
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"http://127.0.0.1/private\"\n".utf8
        )
        XCTAssertEqual(
            MPVHeaderProxyGenericBodyPolicy.probeAction(
                bufferedData: maliciousPlaylist,
                maximumProbeBytes: 4 * 1_024
            ),
            .identifiedPlaylist
        )

        var oversizedPlaylist = maliciousPlaylist
        oversizedPlaylist.append(
            Data(repeating: 0x78, count: 5 * 1_024 * 1_024)
        )
        XCTAssertEqual(
            MPVHeaderProxyGenericBodyPolicy.probeAction(
                bufferedData: oversizedPlaylist,
                maximumProbeBytes: 4 * 1_024
            ),
            .identifiedPlaylist
        )
        XCTAssertEqual(
            MPVHeaderProxyPlaylistFramingPolicy.action(
                bufferedByteCount: oversizedPlaylist.count,
                maximumRewriteBytes: 5 * 1_024 * 1_024
            ),
            .reject
        )

        XCTAssertEqual(
            MPVHeaderProxyGenericBodyPolicy.probeAction(
                bufferedData: Data(repeating: 0x20, count: 4 * 1_024),
                maximumProbeBytes: 4 * 1_024
            ),
            .rejectAmbiguousPrefix
        )
        XCTAssertEqual(
            MPVHeaderProxyGenericBodyPolicy.probeAction(
                bufferedData: Data([0x00, 0x01, 0x02, 0x03]),
                maximumProbeBytes: 4 * 1_024
            ),
            .streamNonPlaylist
        )
        XCTAssertEqual(
            MPVHeaderProxyGenericBodyPolicy.probeAction(
                bufferedData: Data("#EXTM".utf8),
                maximumProbeBytes: 4 * 1_024
            ),
            .continueBuffering,
            "A partial HLS signature must remain classified as ambiguous and be rejected if EOF arrives"
        )
    }

    func testCachedMediaContinuationRequiresExactStrongIdentityAndRange() {
        let bodyByteCount = MPVHeaderProxyCachedContinuationPolicy.validatedBodyByteCount(
            statusCode: 206,
            contentRange: "bytes 8192-16383/32768",
            contentLength: "8192",
            transferEncoding: nil,
            responseEntityTag: "\"entity-v1\"",
            contentEncoding: nil,
            expectedEntityTag: "\"entity-v1\"",
            expectedStart: 8192,
            expectedEnd: 16383,
            expectedTotal: 32768
        )
        XCTAssertEqual(bodyByteCount, 8192)

        XCTAssertNil(
            MPVHeaderProxyCachedContinuationPolicy.validatedBodyByteCount(
                statusCode: 206,
                contentRange: "bytes 8192-16383/32768",
                contentLength: "8192",
                transferEncoding: nil,
                responseEntityTag: "\"entity-v2\"",
                contentEncoding: nil,
                expectedEntityTag: "\"entity-v1\"",
                expectedStart: 8192,
                expectedEnd: 16383,
                expectedTotal: 32768
            ),
            "A changed entity must not be concatenated with a cached prefix"
        )
        XCTAssertNil(
            MPVHeaderProxyCachedContinuationPolicy.validatedBodyByteCount(
                statusCode: 206,
                contentRange: "bytes 0-8191/32768",
                contentLength: "8192",
                transferEncoding: nil,
                responseEntityTag: "\"entity-v1\"",
                contentEncoding: nil,
                expectedEntityTag: "\"entity-v1\"",
                expectedStart: 8192,
                expectedEnd: 16383,
                expectedTotal: 32768
            ),
            "A server that ignores or changes the requested continuation range must fail closed"
        )
        XCTAssertNil(
            MPVHeaderProxyCachedContinuationPolicy.validatedBodyByteCount(
                statusCode: 206,
                contentRange: "bytes 8192-16383/32768",
                contentLength: "8192",
                transferEncoding: "chunked",
                responseEntityTag: "\"entity-v1\"",
                contentEncoding: nil,
                expectedEntityTag: "\"entity-v1\"",
                expectedStart: 8192,
                expectedEnd: 16383,
                expectedTotal: 32768
            )
        )
        XCTAssertNil(
            MPVHeaderProxyCachedContinuationPolicy.validatedBodyByteCount(
                statusCode: 206,
                contentRange: "bytes 8192-16383/32768",
                contentLength: "8192",
                transferEncoding: nil,
                responseEntityTag: "\"entity-v1\"",
                contentEncoding: "gzip",
                expectedEntityTag: "\"entity-v1\"",
                expectedStart: 8192,
                expectedEnd: 16383,
                expectedTotal: 32768
            )
        )
    }

    func testManagedProxyPreservesOriginalCacheIdentityOnlyForLiveSession() throws {
        let originalURL = try XCTUnwrap(
            URL(string: "https://media.example.test/master.m3u8?token=cache-identity")
        )
        let proxyURL = try XCTUnwrap(
            MPVHeaderProxy.shared.makeProxyURL(
                for: originalURL,
                headers: ["Authorization": "Bearer fixture"],
                logType: "MPV",
                traceID: "preload-test"
            )
        )
        defer { MPVHeaderProxy.shared.invalidateSession(for: proxyURL) }

        XCTAssertEqual(MPVHeaderProxy.shared.originalTargetURL(for: proxyURL), originalURL)

        MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
        XCTAssertNil(
            MPVHeaderProxy.shared.originalTargetURL(for: proxyURL),
            "A completed warmup must not keep a reusable proxy session alive"
        )
    }
}

final class PlaybackProxySessionOwnershipTests: XCTestCase {
    func testLastPlaybackLeaseInvalidatesEveryDeduplicatedProxyExactlyOnce() throws {
        let root = try XCTUnwrap(URL(string: "http://127.0.0.1:9001/root"))
        let subtitle = try XCTUnwrap(URL(string: "http://127.0.0.1:9002/subtitle"))
        var invalidationCounts: [URL: Int] = [:]
        let ownership = PlaybackProxySessionOwnership(
            proxyURLs: [root, subtitle, root]
        ) { proxyURL in
            invalidationCounts[proxyURL, default: 0] += 1
        }

        var firstLease = try XCTUnwrap(ownership.acquireLease())
        var handoffLease = try XCTUnwrap(ownership.acquireLease())
        firstLease.release()
        XCTAssertTrue(invalidationCounts.isEmpty)

        handoffLease.release()
        XCTAssertEqual(invalidationCounts[root], 1)
        XCTAssertEqual(invalidationCounts[subtitle], 1)
        XCTAssertTrue(ownership.isInvalidated)

        firstLease.release()
        handoffLease.release()
        ownership.invalidate()
        XCTAssertEqual(invalidationCounts[root], 1)
        XCTAssertEqual(invalidationCounts[subtitle], 1)
    }

    func testAbandonInvalidatesImmediatelyAndRejectsFuturePlaybackLeases() throws {
        let root = try XCTUnwrap(URL(string: "http://127.0.0.1:9011/root"))
        let subtitle = try XCTUnwrap(URL(string: "http://127.0.0.1:9012/subtitle"))
        var invalidated: [URL] = []
        let ownership = PlaybackProxySessionOwnership(
            proxyURLs: [root, subtitle]
        ) { invalidated.append($0) }
        let outstandingLease = try XCTUnwrap(ownership.acquireLease())

        ownership.invalidate()
        XCTAssertEqual(Set(invalidated), Set([root, subtitle]))
        XCTAssertNil(ownership.acquireLease())

        outstandingLease.release()
        XCTAssertEqual(invalidated.count, 2)
    }
}
#endif

final class FetchDelegateRedirectHeaderScopingTests: XCTestCase {
    func testLanguageFilterConfigurationReflectsSettingChangesImmediately() throws {
        let suiteName = "eclipse.tests.streamfilter.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            StreamLanguageFilter.invalidateConfigurationCache()
        }
        StreamLanguageFilter.invalidateConfigurationCache()

        XCTAssertNil(
            StreamLanguageFilter.configuration(sourceId: "nuvio:probe", defaults: defaults),
            "With no rules configured there is nothing to filter"
        )

        defaults.set(["ja"], forKey: "servicesHiddenStreamLanguages")
        let afterHiding = StreamLanguageFilter.configuration(sourceId: "nuvio:probe", defaults: defaults)
        XCTAssertNotNil(
            afterHiding,
            "A cached configuration must not survive the setting that produced it changing"
        )

        defaults.set([String](), forKey: "servicesHiddenStreamLanguages")
        XCTAssertNil(
            StreamLanguageFilter.configuration(sourceId: "nuvio:probe", defaults: defaults),
            "Clearing every rule has to clear the cached configuration too"
        )
    }

    func testDNSFailureIsNotReportedAsAnEclipseBlock() {
        let unreachable: [SkyStreamSecurityError] = [.dnsResolutionFailed, .dnsReturnedNoAddresses]
        let eclipseEnforced: [SkyStreamSecurityError] = [
            .prohibitedHost,
            .credentialsInURL,
            .insecureTransport,
            .httpsDowngrade
        ]

        for error in unreachable {
            XCTAssertTrue(
                NuvioPluginSupport.isUnreachableHostError(error),
                "A host that will not resolve is the provider's dead endpoint, not an Eclipse policy block"
            )
        }
        for error in eclipseEnforced {
            XCTAssertFalse(
                NuvioPluginSupport.isUnreachableHostError(error),
                "\(error) is a rule Eclipse chose to enforce and must stay attributed to Eclipse"
            )
        }
    }

    func testSameOriginRedirectPreservesCallerHeaders() throws {
        let source = try XCTUnwrap(URL(string: "https://media.example/path"))
        let destination = try XCTUnwrap(URL(string: "https://MEDIA.example:443/next"))
        var request = URLRequest(url: destination)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("private", forHTTPHeaderField: "X-API-Key")

        let scoped = FetchDelegate.requestScopedForRedirect(
            request,
            from: source,
            to: destination
        )

        XCTAssertEqual(scoped.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(scoped.value(forHTTPHeaderField: "X-API-Key"), "private")
    }

    func testCrossOriginRedirectKeepsOnlyNonCredentialBrowserHeaders() throws {
        let source = try XCTUnwrap(URL(string: "https://media.example/path"))
        let destination = try XCTUnwrap(URL(string: "https://cdn.example/next"))
        var request = URLRequest(url: destination)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Eclipse", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("session=secret", forHTTPHeaderField: "Cookie")
        request.setValue("private", forHTTPHeaderField: "X-API-Key")

        let scoped = FetchDelegate.requestScopedForRedirect(
            request,
            from: source,
            to: destination
        )

        XCTAssertEqual(scoped.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(scoped.value(forHTTPHeaderField: "User-Agent"), "Eclipse")
        XCTAssertNil(scoped.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(scoped.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(scoped.value(forHTTPHeaderField: "X-API-Key"))
    }

    func testSchemeOrPortChangeIsCrossOrigin() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://media.example:444/next")))
        request.setValue("private", forHTTPHeaderField: "X-Token")

        let scoped = FetchDelegate.requestScopedForRedirect(
            request,
            from: try XCTUnwrap(URL(string: "https://media.example/path")),
            to: try XCTUnwrap(request.url)
        )

        XCTAssertNil(scoped.value(forHTTPHeaderField: "X-Token"))
    }
}

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
        let fixture = Data("""
        {
          "schemaVersion": 1,
          "packageName": "fixture.plugin",
          "providerID": "primary",
          "scriptSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "pluginVersion": 7,
          "loadedItemURL": "https://catalog.example.test/title/42?access_token=legacy-loaded-secret",
          "selectedEpisodeURL": "https://media.example.test/season/1/episode/2?signature=legacy-episode-secret",
          "season": 1,
          "episode": 2,
          "preferredStreamLabel": "1080p",
          "contentType": "series",
          "title": "Fixture Show",
          "year": 2025,
          "syncData": {
            "opaqueSession": "legacy-sync-secret"
          },
          "additionalFields": {
            "providerToken": "legacy-additional-secret"
          }
        }
        """.utf8)
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

    func testMetadataDocumentRejectsManualAndCarriesPrivateConfiguration() throws {
        var manual = makeSnapshot()
        manual.isSafeCloudSnapshot = false
        XCTAssertThrowsError(try SkyStreamMediaStateDocument.encodeMetadataOnly(manual))

        var credentialed = makeSnapshot()
        credentialed.plugins[0].state.provenance.sourceURL =
            "https://plugins.example/archive.sky?access_token=secret"
        credentialed.plugins[0].state.preferences["apiToken"] = SkyStreamPreferenceValue(
            value: .string("opaque"),
            isSecret: true
        )
        let data = try SkyStreamMediaStateDocument.encodeMetadataOnly(credentialed)
        let decoded = try SkyStreamMediaStateDocument.decodeMetadataOnly(data)
        XCTAssertEqual(
            decoded.plugins.first?.state.provenance.sourceURL,
            "https://plugins.example/archive.sky?access_token=secret"
        )
        XCTAssertEqual(decoded.plugins.first?.state.preferences["apiToken"]?.value, .string("opaque"))
        XCTAssertEqual(decoded.plugins.first?.state.preferences["apiToken"]?.isSecret, true)
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
            isSafeCloudSnapshot: true,
            privateCloudConfigurationIsComplete: true
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
        XCTAssertNil(sanitized)

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

    func testCompletePrivateCloudSanitizerPreservesCapabilityURLsAndSecretPreferences() throws {
        let incoming = makeCapabilitySnapshot()
        let sanitized = try XCTUnwrap(
            BackupData.skyStreamSnapshotForExperimentalCloudSync(incoming)
        )
        let incomingRepository = try XCTUnwrap(incoming.repositories.first)
        let repository = try XCTUnwrap(sanitized.repositories.first)
        let incomingRepositoryManifest = try XCTUnwrap(incomingRepository.manifest)
        let repositoryManifest = try XCTUnwrap(repository.manifest)
        let incomingEmbedded = try XCTUnwrap(incomingRepositoryManifest.plugins.first)
        let embedded = try XCTUnwrap(repositoryManifest.plugins.first)
        let incomingPlugin = try XCTUnwrap(incoming.plugins.first)
        let plugin = try XCTUnwrap(sanitized.plugins.first)

        XCTAssertEqual(repository.sourceURL, incomingRepository.sourceURL)
        XCTAssertEqual(repository.pluginListURLs, incomingRepository.pluginListURLs)
        XCTAssertEqual(repositoryManifest.pluginLists, incomingRepositoryManifest.pluginLists)
        XCTAssertEqual(
            repositoryManifest.includedRepositories,
            incomingRepositoryManifest.includedRepositories
        )
        XCTAssertEqual(repositoryManifest.iconURL, incomingRepositoryManifest.iconURL)
        XCTAssertEqual(repositoryManifest.websiteURL, incomingRepositoryManifest.websiteURL)
        XCTAssertEqual(embedded.url, incomingEmbedded.url)
        XCTAssertEqual(embedded.manifest.baseURL, incomingEmbedded.manifest.baseURL)
        XCTAssertEqual(embedded.manifest.iconURL, incomingEmbedded.manifest.iconURL)
        XCTAssertEqual(
            embedded.manifest.domains?.first?.url,
            incomingEmbedded.manifest.domains?.first?.url
        )
        XCTAssertEqual(
            embedded.manifest.providers?.first?.baseURL,
            incomingEmbedded.manifest.providers?.first?.baseURL
        )
        XCTAssertEqual(
            embedded.manifest.providers?.first?.iconURL,
            incomingEmbedded.manifest.providers?.first?.iconURL
        )
        XCTAssertEqual(
            plugin.state.provenance.sourceURL,
            incomingPlugin.state.provenance.sourceURL
        )
        XCTAssertEqual(
            plugin.state.provenance.repositoryURL,
            incomingPlugin.state.provenance.repositoryURL
        )
        XCTAssertEqual(
            plugin.state.provenance.pluginListURL,
            incomingPlugin.state.provenance.pluginListURL
        )
        XCTAssertEqual(plugin.state.selectedDomainURL, incomingPlugin.state.selectedDomainURL)
        XCTAssertEqual(plugin.state.manifest.baseURL, incomingPlugin.state.manifest.baseURL)
        XCTAssertEqual(
            plugin.state.manifest.domains?.first?.url,
            incomingPlugin.state.manifest.domains?.first?.url
        )
        XCTAssertEqual(
            plugin.state.manifest.providers?.first?.baseURL,
            incomingPlugin.state.manifest.providers?.first?.baseURL
        )
        XCTAssertEqual(
            plugin.state.preferences["apiToken"],
            incomingPlugin.state.preferences["apiToken"]
        )
        XCTAssertEqual(sanitized.privateCloudConfigurationIsComplete, true)
    }

    func testCompletePrivateCloudSanitizerRejectsAnyInvalidNestedConfiguredURL() {
        let invalid = "https://user:password@invalid.example/private"
        let mutations: [(String, (inout SkyStreamBackupSnapshot) -> Void)] = [
            ("repository source", { $0.repositories[0].sourceURL = invalid }),
            ("repository list", { $0.repositories[0].pluginListURLs[0] = invalid }),
            ("repository manifest list", {
                $0.repositories[0].manifest?.pluginLists[0] = invalid
            }),
            ("nested repository", {
                $0.repositories[0].manifest?.includedRepositories[0] = invalid
            }),
            ("embedded archive", { $0.repositories[0].manifest?.plugins[0].url = invalid }),
            ("repository icon", { $0.repositories[0].manifest?.iconURL = invalid }),
            ("repository website", { $0.repositories[0].manifest?.websiteURL = invalid }),
            ("embedded base", {
                $0.repositories[0].manifest?.plugins[0].manifest.baseURL = invalid
            }),
            ("embedded icon", {
                $0.repositories[0].manifest?.plugins[0].manifest.iconURL = invalid
            }),
            ("embedded domain", {
                $0.repositories[0].manifest?.plugins[0].manifest.domains?[0].url = invalid
            }),
            ("embedded provider base", {
                $0.repositories[0].manifest?.plugins[0].manifest.providers?[0].baseURL = invalid
            }),
            ("embedded provider icon", {
                $0.repositories[0].manifest?.plugins[0].manifest.providers?[0].iconURL = invalid
            }),
            ("provenance source", { $0.plugins[0].state.provenance.sourceURL = invalid }),
            ("provenance repository", {
                $0.plugins[0].state.provenance.repositoryURL = invalid
            }),
            ("provenance list", { $0.plugins[0].state.provenance.pluginListURL = invalid }),
            ("selected domain", { $0.plugins[0].state.selectedDomainURL = invalid }),
            ("manifest base", { $0.plugins[0].state.manifest.baseURL = invalid }),
            ("manifest icon", { $0.plugins[0].state.manifest.iconURL = invalid }),
            ("manifest domain", { $0.plugins[0].state.manifest.domains?[0].url = invalid }),
            ("provider base", {
                $0.plugins[0].state.manifest.providers?[0].baseURL = invalid
            }),
            ("provider icon", {
                $0.plugins[0].state.manifest.providers?[0].iconURL = invalid
            })
        ]

        for (name, mutation) in mutations {
            var incoming = makeCapabilitySnapshot()
            mutation(&incoming)
            XCTAssertNil(
                BackupData.skyStreamSnapshotForExperimentalCloudSync(incoming),
                name
            )
        }
    }

    func testClaimedCompletePrivateCloudConfigurationCannotDowngradeToPartialAuthority() {
        var incoming = makeCapabilitySnapshot()
        incoming.plugins[0].preferencesWereRedacted = true

        XCTAssertNil(BackupData.skyStreamSnapshotForExperimentalCloudSync(incoming))
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
    func testCompletePrivateCloudURLPolicyAcceptsCapabilityURLsOnlyForCompleteConfiguration() {
        let ordinary = "https://repo.example/repository.json"
        let capabilityURLs = [
            "https://repo.example/repository.json?token=private",
            "https://repo.example/repository.json#private-fragment",
            "https://repo.example/repository.json?token=private#private-fragment"
        ]

        XCTAssertTrue(SkyStreamPluginManager.acceptsSafeCloudConfigurationURL(
            ordinary,
            configurationIsComplete: true
        ))
        XCTAssertTrue(SkyStreamPluginManager.acceptsSafeCloudConfigurationURL(
            ordinary,
            configurationIsComplete: false
        ))
        for capabilityURL in capabilityURLs {
            XCTAssertTrue(SkyStreamPluginManager.acceptsSafeCloudConfigurationURL(
                capabilityURL,
                configurationIsComplete: true
            ))
            XCTAssertFalse(SkyStreamPluginManager.acceptsSafeCloudConfigurationURL(
                capabilityURL,
                configurationIsComplete: false
            ))
        }
    }

    @MainActor
    func testCompletePrivateCloudRepositoryUpdateWinsWhileLegacyMergePreservesLocal() {
        let sourceURL = "https://repo.example/repository.json?token=private#configured"
        let current = SkyStreamSavedRepository(
            sourceURL: sourceURL,
            kind: .pluginList,
            name: "Local configuration",
            pluginListURLs: ["https://repo.example/local.json"],
            plugins: []
        )
        let incoming = SkyStreamSavedRepository(
            sourceURL: sourceURL,
            kind: .pluginList,
            name: "Incoming configuration",
            pluginListURLs: ["https://repo.example/incoming.json?token=private#configured"],
            plugins: []
        )

        XCTAssertEqual(
            SkyStreamPluginManager.restoringCompletePrivateCloudRepositories(
                current: [current],
                incoming: [incoming],
                baseline: [sourceURL: current]
            ),
            [incoming]
        )
        XCTAssertEqual(
            SkyStreamPluginManager.mergingSafeCloudRepositories(
                current: [current],
                incoming: [incoming]
            ),
            [current]
        )
    }

    @MainActor
    func testCompletePrivateCloudConfigurationMakesEmptyAuthoritative() {
        let local = [
            "token": SkyStreamPreferenceValue(
                value: .string("local-secret"),
                isSecret: true
            )
        ]
        XCTAssertEqual(
            SkyStreamPrivateCloudConfigurationPolicy.restoredPreferences(
                local: local,
                incoming: [:],
                incomingIsComplete: true
            ),
            [:]
        )
        XCTAssertEqual(
            SkyStreamPrivateCloudConfigurationPolicy.restoredPreferences(
                local: local,
                incoming: [:],
                incomingIsComplete: false
            ),
            local
        )

        let removed = SkyStreamSavedRepository(
            sourceURL: "https://repo.example/removed.json",
            kind: .pluginList,
            name: "Removed",
            pluginListURLs: ["https://repo.example/removed.json"],
            plugins: []
        )
        let concurrent = SkyStreamSavedRepository(
            sourceURL: "https://repo.example/concurrent.json",
            kind: .pluginList,
            name: "Concurrent",
            pluginListURLs: ["https://repo.example/concurrent.json"],
            plugins: []
        )
        XCTAssertEqual(
            SkyStreamPluginManager.restoringCompletePrivateCloudRepositories(
                current: [removed, concurrent],
                incoming: [],
                baseline: [removed.sourceURL: removed]
            ),
            [concurrent]
        )
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
            isSafeCloudSnapshot: true,
            privateCloudConfigurationIsComplete: true
        )
    }

    private func makeCapabilitySnapshot() -> SkyStreamBackupSnapshot {
        let pluginDomainURL = "https://video.example/domain?session=secret#domain-fragment"
        let pluginManifest = SkyStreamPluginManifest(
            packageName: "fixture.plugin",
            name: "Fixture",
            version: 1,
            authors: ["Fixture Author"],
            baseURL: "https://video.example/base?api_key=secret#base-fragment",
            iconURL: "https://video.example/icon.png?token=secret#icon-fragment",
            languages: ["en"],
            categories: ["movie"],
            domains: [
                SkyStreamPluginDomain(name: "Primary", url: pluginDomainURL)
            ],
            providers: [
                SkyStreamPluginProvider(
                    id: "primary",
                    name: "Primary",
                    baseURL: "https://video.example/provider?auth=secret#provider-fragment",
                    iconURL: "https://video.example/provider.png?auth=secret#provider-icon"
                )
            ]
        )
        let provenance = SkyStreamInstallProvenance(
            kind: .repository,
            sourceURL: "https://plugins.example/fixture.sky?download=secret#archive-fragment",
            repositoryURL: "https://repo.example/root.json?repo=secret#repo-fragment",
            pluginListURL: "https://repo.example/list.json?list=secret#list-fragment",
            repositoryPackageName: "fixture.repository"
        )
        let state = SkyStreamInstalledPluginState(
            manifest: pluginManifest,
            archiveSHA256: String(repeating: "a", count: 64),
            scriptSHA256: String(repeating: "b", count: 64),
            payloadRelativePath: "",
            provenance: provenance,
            selectedDomainURL: pluginDomainURL,
            providers: [
                SkyStreamProviderState(
                    packageName: pluginManifest.packageName,
                    providerID: "primary",
                    lastSeenPluginVersion: pluginManifest.version
                )
            ],
            preferences: [
                "apiToken": SkyStreamPreferenceValue(
                    value: .string("private-cloud-secret"),
                    isSecret: true
                )
            ]
        )
        let embeddedManifest = SkyStreamPluginManifest(
            packageName: "fixture.embedded",
            name: "Embedded",
            version: 1,
            authors: ["Fixture Author"],
            baseURL: "https://embedded.example/base?key=secret#embedded-base",
            iconURL: "https://embedded.example/icon.png?key=secret#embedded-icon",
            languages: ["en"],
            categories: ["movie"],
            domains: [
                SkyStreamPluginDomain(
                    name: "Embedded",
                    url: "https://embedded.example/domain?key=secret#embedded-domain"
                )
            ],
            providers: [
                SkyStreamPluginProvider(
                    id: "embedded",
                    name: "Embedded",
                    baseURL: "https://embedded.example/provider?key=secret#embedded-provider",
                    iconURL: "https://embedded.example/provider.png?key=secret#embedded-provider-icon"
                )
            ]
        )
        let embedded = SkyStreamPluginListEntry(
            manifest: embeddedManifest,
            url: "https://repo.example/embedded.sky?key=secret#embedded-archive"
        )
        let listURL = "https://repo.example/list.json?list=secret#list-fragment"
        let repositoryManifest = SkyStreamRepositoryManifest(
            name: "Fixture Repository",
            packageName: "fixture.repository",
            pluginLists: [listURL],
            includedRepositories: [
                "https://repo.example/nested.json?nested=secret#nested-fragment"
            ],
            plugins: [embedded],
            iconURL: "https://repo.example/icon.png?icon=secret#repo-icon",
            websiteURL: "https://repo.example/site?site=secret#repo-site"
        )
        let repository = SkyStreamRepositoryBackupSnapshot(
            sourceURL: "https://repo.example/root.json?repo=secret#repo-fragment",
            kind: .repository,
            manifest: repositoryManifest,
            pluginListURLs: [listURL]
        )
        return SkyStreamBackupSnapshot(
            repositories: [repository],
            plugins: [
                SkyStreamPluginBackupSnapshot(
                    state: state,
                    payloadWasRedacted: true,
                    preferencesWereRedacted: false
                )
            ],
            isSafeCloudSnapshot: true,
            privateCloudConfigurationIsComplete: true
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

    func testResolverIdentityFloorFollowsTheDropUnmatchedResultsToggle() {
        let suiteName = "SkyStreamResolverIdentityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create an isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ServicesResultRankingSettings.setMinimumSimilarity(0.95, defaults: defaults)
        ServicesResultRankingSettings.setDropsMismatchedResults(true, defaults: defaults)
        XCTAssertFalse(SkyStreamResolver.acceptsTitleMatch(
            score: 0.9499,
            requiresExactIdentity: false,
            defaults: defaults
        ))
        XCTAssertTrue(SkyStreamResolver.acceptsTitleMatch(
            score: 0.95,
            requiresExactIdentity: false,
            defaults: defaults
        ))

        ServicesResultRankingSettings.setDropsMismatchedResults(false, defaults: defaults)
        XCTAssertFalse(SkyStreamResolver.acceptsTitleMatch(
            score: 0.8499,
            requiresExactIdentity: false,
            defaults: defaults
        ))
        XCTAssertTrue(SkyStreamResolver.acceptsTitleMatch(
            score: 0.85,
            requiresExactIdentity: false,
            defaults: defaults
        ))

        ServicesResultRankingSettings.setMinimumSimilarity(0.50, defaults: defaults)
        ServicesResultRankingSettings.setDropsMismatchedResults(true, defaults: defaults)
        XCTAssertFalse(SkyStreamResolver.acceptsTitleMatch(
            score: 0.8499,
            requiresExactIdentity: false,
            defaults: defaults
        ))

        for dropsMismatchedResults in [true, false] {
            ServicesResultRankingSettings.setDropsMismatchedResults(
                dropsMismatchedResults,
                defaults: defaults
            )
            XCTAssertFalse(SkyStreamResolver.acceptsTitleMatch(
                score: 0.8999,
                requiresExactIdentity: true,
                defaults: defaults
            ))
            XCTAssertTrue(SkyStreamResolver.acceptsTitleMatch(
                score: 0.90,
                requiresExactIdentity: true,
                defaults: defaults
            ))
        }
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

        try await Task.sleep(nanoseconds: 150_000_000)

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

    func testRedirectHeadersCanBypassAnIrrelevantOversizedBody() async throws {
        let delegate = FetchDelegate(allowRedirects: false)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SkyStreamRedirectResponseURLProtocol.self]
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let source = try XCTUnwrap(URL(string: "https://redirect-source.example/start"))
        let (data, response) = try await delegate.boundedData(
            in: session,
            for: URLRequest(url: source),
            maximumResponseBytes: 16,
            allowRedirects: false,
            returnsRedirectResponseImmediately: true
        )
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(http.statusCode, 302)
        XCTAssertEqual(
            http.value(forHTTPHeaderField: "Location"),
            "https://redirect-destination.example/final"
        )
    }

    func testPinnedProviderImageDecoderBoundsPayloadAndDimensions() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let validData = UIGraphicsImageRenderer(
            size: CGSize(width: 8, height: 8),
            format: format
        ).pngData { context in
            context.cgContext.setFillColor(UIColor.systemBlue.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        XCTAssertNotNil(PinnedProviderImageLoader.decodedImage(from: validData))
        XCTAssertNil(PinnedProviderImageLoader.decodedImage(from: Data("not-an-image".utf8)))

        let oversizedDimension = UIGraphicsImageRenderer(
            size: CGSize(width: 8_193, height: 1),
            format: format
        ).pngData { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 8_193, height: 1))
        }
        XCTAssertNil(PinnedProviderImageLoader.decodedImage(from: oversizedDimension))
        XCTAssertNil(
            PinnedProviderImageLoader.decodedImage(
                from: Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1)
            )
        )
    }

    func testStremioJSONEnvelopeAndModelCollectionsAreBoundedBeforeUse() throws {
        let excessiveDepth = Data((String(repeating: "[", count: 17)
            + "0"
            + String(repeating: "]", count: 17)).utf8)
        XCTAssertThrowsError(try StremioJSONBoundary.validate(excessiveDepth)) {
            XCTAssertEqual($0 as? SkyStreamJSONEnvelopeError, .excessiveDepth)
        }

        let previouslyRefusedString = try JSONSerialization.data(withJSONObject: [
            "metas": [],
            "padding": String(repeating: "x", count: 16 * 1_024 + 1)
        ])
        XCTAssertNoThrow(
            try StremioJSONBoundary.validate(previouslyRefusedString),
            "a 16 KiB string must no longer make Eclipse discard the whole addon response"
        )

        let excessiveString = try JSONSerialization.data(withJSONObject: [
            "metas": [],
            "padding": String(repeating: "x", count: 1_024 * 1_024 + 1)
        ])
        XCTAssertThrowsError(try StremioJSONBoundary.validate(excessiveString)) {
            XCTAssertEqual($0 as? SkyStreamJSONEnvelopeError, .excessiveTokenBytes)
        }

        var metas: [[String: Any]] = (0..<350).map { index in
            ["id": "meta-\(index)", "type": "movie", "name": "Meta \(index)"]
        }
        metas[0]["videos"] = (0..<160).map { index in
            ["id": "video-\(index)", "title": "Video \(index)"]
        }
        metas[1]["name"] = String(repeating: "n", count: 1_025)
        let catalogData = try JSONSerialization.data(withJSONObject: ["metas": metas])
        try StremioJSONBoundary.validate(catalogData)
        let catalog = try JSONDecoder().decode(StremioCatalogResponse.self, from: catalogData)
        XCTAssertEqual(catalog.metas.count, StremioDecodingLimits.catalogMetasPerResponse)
        XCTAssertEqual(catalog.metas.first?.id, "meta-0")
        XCTAssertEqual(catalog.metas.first?.videos?.count, StremioDecodingLimits.videosPerMeta)
        let truncatedNameMeta = catalog.metas.first { $0.id == "meta-1" }
        XCTAssertNotNil(
            truncatedNameMeta,
            "an over-long name must truncate the field rather than discard the whole row"
        )
        XCTAssertEqual(truncatedNameMeta?.name.utf8.count, 1_024)
        XCTAssertFalse(catalog.metas.contains { $0.id == "meta-300" })

        let manifestData = try JSONSerialization.data(withJSONObject: [
            "id": "fixture.addon",
            "name": "Fixture",
            "types": (0..<100).map { "type-\($0)" },
            "resources": (0..<100).map { "resource-\($0)" },
            "idPrefixes": (0..<200).map { "prefix-\($0)" },
            "catalogs": (0..<(StremioDecodingLimits.manifestCatalogs + 50)).map {
                ["type": "movie", "id": "catalog-\($0)"]
            }
        ])
        try StremioJSONBoundary.validate(manifestData)
        let manifest = try JSONDecoder().decode(StremioManifest.self, from: manifestData)
        XCTAssertEqual(manifest.types?.count, StremioDecodingLimits.manifestTypes)
        XCTAssertEqual(manifest.resources?.count, StremioDecodingLimits.manifestResources)
        XCTAssertEqual(manifest.idPrefixes?.count, StremioDecodingLimits.manifestIDPrefixes)
        XCTAssertEqual(manifest.catalogs?.count, StremioDecodingLimits.manifestCatalogs)
    }

    func testServiceSearchResultBoundaryCapsAndSanitizesProviderOutput() throws {
        var rows = (0..<350).map { index in
            [
                "title": "Result \(index)",
                "image": "https://images.example/\(index).jpg",
                "href": "/title/\(index)"
            ]
        }
        rows.insert(
            [
                "title": String(repeating: "x", count: 513),
                "image": "https://images.example/oversized.jpg",
                "href": "/oversized"
            ],
            at: 0
        )
        let data = try JSONSerialization.data(withJSONObject: rows)
        let parsed = try JSController.boundedSearchItems(from: data)
        XCTAssertEqual(parsed.rawCount, 351)
        XCTAssertEqual(parsed.items.count, 350)
        XCTAssertEqual(parsed.items.first?.title, "Result 0")

        let explicitLimit = try JSController.boundedSearchItems(from: data, maxResults: 5)
        XCTAssertEqual(explicitLimit.items.count, 5)
        XCTAssertThrowsError(
            try JSController.boundedSearchItems(
                from: Data(repeating: 0x20, count: 4 * 1_024 * 1_024 + 1)
            )
        )
    }

    #if !os(tvOS)
    func testServiceBrowserAutomationPolicyAllowsProviderWebNavigation() async throws {
        let publicHTTPS = try XCTUnwrap(URL(string: "https://media.example.test/path"))
        XCTAssertEqual(
            ServiceBrowserAutomationPolicy.staticDecision(
                for: publicHTTPS,
                allowsLocalDocument: false
            ),
            .web
        )
        let publicHTTP = try XCTUnwrap(URL(string: "http://media.example.test/path"))
        XCTAssertEqual(
            ServiceBrowserAutomationPolicy.staticDecision(
                for: publicHTTP,
                allowsLocalDocument: false
            ),
            .web
        )
        for rawURL in ["ftp://media.example.test/path"] {
            let url = try XCTUnwrap(URL(string: rawURL))
            XCTAssertEqual(
                ServiceBrowserAutomationPolicy.staticDecision(
                    for: url,
                    allowsLocalDocument: false
                ),
                .reject,
                rawURL
            )
        }
        let basicAuthURL = try XCTUnwrap(
            URL(string: "https://user:secret@media.example.test/path")
        )
        XCTAssertEqual(
            ServiceBrowserAutomationPolicy.staticDecision(
                for: basicAuthURL,
                allowsLocalDocument: false
            ),
            .web
        )

        let localDocument = try XCTUnwrap(URL(string: "about:blank"))
        XCTAssertEqual(
            ServiceBrowserAutomationPolicy.staticDecision(
                for: localDocument,
                allowsLocalDocument: true
            ),
            .localDocument
        )
        XCTAssertEqual(
            ServiceBrowserAutomationPolicy.staticDecision(
                for: localDocument,
                allowsLocalDocument: false
            ),
            .reject
        )
        let privateNavigationURL = try XCTUnwrap(
            URL(string: "https://127.0.0.1/private")
        )
        let permitsPrivateNavigation = await ServiceBrowserAutomationPolicy.permitsNavigation(
            to: privateNavigationURL,
            allowsLocalDocument: false
        )
        XCTAssertTrue(permitsPrivateNavigation)

        XCTAssertFalse(
            ServiceBrowserAutomationPolicy.requiresOriginLock(
                for: ["cookie": "session=fixture", "accept": "text/html"]
            ),
            "Cookies are moved into WebKit's exact-host cookie store before dispatch"
        )
        XCTAssertFalse(
            ServiceBrowserAutomationPolicy.requiresOriginLock(
                for: ["authorization": "Bearer fixture"]
            )
        )
        XCTAssertTrue(
            ServiceBrowserAutomationPolicy.isSameOrigin(
                publicHTTPS,
                try XCTUnwrap(URL(string: "https://MEDIA.example.test:443/redirect"))
            )
        )
        XCTAssertFalse(
            ServiceBrowserAutomationPolicy.isSameOrigin(
                publicHTTPS,
                try XCTUnwrap(URL(string: "https://media.example.test:444/redirect"))
            )
        )
        XCTAssertFalse(
            ServiceBrowserAutomationPolicy.isSameOrigin(
                publicHTTPS,
                try XCTUnwrap(URL(string: "https://other.example.test/redirect"))
            )
        )
    }

    @MainActor
    func testServiceBrowserAutomationUsesDistinctEphemeralCookieStores() async throws {
        let firstSandbox = ServiceSandboxState()
        let secondSandbox = ServiceSandboxState()
        let sharedProfileID = UUID()
        let sharedServiceID = UUID()
        let serviceSandboxA = ServiceSandboxState()
        let serviceSandboxB = ServiceSandboxState()
        let otherServiceSandbox = ServiceSandboxState()
        serviceSandboxA.configureBrowserIsolation(
            profileID: sharedProfileID,
            serviceID: sharedServiceID
        )
        serviceSandboxB.configureBrowserIsolation(
            profileID: sharedProfileID,
            serviceID: sharedServiceID
        )
        otherServiceSandbox.configureBrowserIsolation(
            profileID: sharedProfileID,
            serviceID: UUID()
        )
        let first = ServiceBrowserAutomationPolicy.isolatedConfiguration(for: firstSandbox)
        let sameService = ServiceBrowserAutomationPolicy.isolatedConfiguration(
            for: firstSandbox
        )
        let second = ServiceBrowserAutomationPolicy.isolatedConfiguration(for: secondSandbox)
        let serviceA = ServiceBrowserAutomationPolicy.isolatedConfiguration(for: serviceSandboxA)
        let serviceB = ServiceBrowserAutomationPolicy.isolatedConfiguration(for: serviceSandboxB)
        let otherService = ServiceBrowserAutomationPolicy.isolatedConfiguration(
            for: otherServiceSandbox
        )
        let installedContentRule = await ServiceBrowserAutomationPolicy.installHTTPSOnlyContentRule(
            in: first
        )
        XCTAssertTrue(installedContentRule)
        XCTAssertFalse(first.websiteDataStore.isPersistent)
        XCTAssertFalse(second.websiteDataStore.isPersistent)
        XCTAssertTrue(first.websiteDataStore === sameService.websiteDataStore)
        XCTAssertFalse(first.websiteDataStore === second.websiteDataStore)
        XCTAssertTrue(serviceA.websiteDataStore === serviceB.websiteDataStore)
        XCTAssertFalse(serviceA.websiteDataStore === otherService.websiteDataStore)

        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "service-a-session",
            .value: "private",
            .domain: "media.example.test",
            .path: "/",
            .secure: "TRUE"
        ]))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            first.websiteDataStore.httpCookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }
        let firstCookies = await withCheckedContinuation { continuation in
            first.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        let secondCookies = await withCheckedContinuation { continuation in
            second.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertEqual(firstCookies.map(\.name), ["service-a-session"])
        XCTAssertTrue(secondCookies.isEmpty)
    }

    func testServiceBrowserReturnedCookiesHonorHostPathSecureAndExpiryScope() throws {
        let now = Date()
        func cookie(
            name: String,
            domain: String,
            path: String,
            secure: Bool = false,
            expires: Date? = nil
        ) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: name,
                .domain: domain,
                .path: path
            ]
            if secure {
                properties[.secure] = "TRUE"
            }
            if let expires {
                properties[.expires] = expires
            }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }

        let cookies = try [
            cookie(name: "exact", domain: "media.example.test", path: "/watch"),
            cookie(name: "parent", domain: ".example.test", path: "/watch"),
            cookie(name: "secure", domain: "media.example.test", path: "/", secure: true),
            cookie(name: "wrong-host", domain: "other.example.test", path: "/"),
            cookie(name: "wrong-path", domain: "media.example.test", path: "/admin"),
            cookie(
                name: "expired",
                domain: "media.example.test",
                path: "/",
                expires: now.addingTimeInterval(-60)
            )
        ]
        let httpsURL = try XCTUnwrap(
            URL(string: "https://media.example.test/watch/episode")
        )
        let httpsCookies = ServiceBrowserCookiePolicy.returnedCookies(
            from: cookies,
            for: httpsURL,
            now: now
        )
        XCTAssertEqual(Set(httpsCookies.keys), ["exact", "parent", "secure"])

        let httpURL = try XCTUnwrap(
            URL(string: "http://media.example.test/watch/episode")
        )
        let httpCookies = ServiceBrowserCookiePolicy.returnedCookies(
            from: cookies,
            for: httpURL,
            now: now
        )
        XCTAssertEqual(Set(httpCookies.keys), ["exact", "parent"])

        let union = ServiceBrowserCookiePolicy.returnedCookies(
            from: cookies,
            preferring: [httpURL, httpsURL],
            now: now
        )
        XCTAssertEqual(
            Set(union.keys),
            ["exact", "parent", "secure", "wrong-host", "wrong-path"]
        )
    }

    func testCloudflareSolvedSessionRetainsSupportingCookies() {
        let serviceAHeader = [
            "cf_clearance=clearance-a",
            "service_session=service-a-secret",
            "authorization=service-a-token",
            "__ddg1=ddos-clearance"
        ].joined(separator: "; ")

        let headerVisibleToServiceB = CloudflareBypassManager
            .vettedSharedCookieHeader(from: serviceAHeader)

        XCTAssertEqual(
            headerVisibleToServiceB,
            "cf_clearance=clearance-a; service_session=service-a-secret; authorization=service-a-token; __ddg1=ddos-clearance"
        )
        XCTAssertEqual(
            CloudflareBypassManager.vettedSharedCookieHeader(
                from: "service_session=service-a-secret; auth=service-a-token"
            ),
            "service_session=service-a-secret; auth=service-a-token"
        )
    }

    func testCloudflareSolvedCookiesRemainScopedToTheirApplicableHost() throws {
        func cookie(name: String, value: String, domain: String) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: domain,
                .path: "/"
            ]))
        }
        let cookies = try [
            cookie(name: "cf_clearance", value: "dot-com", domain: "animepahe.com"),
            cookie(name: "cf_clearance", value: "dot-pw", domain: "animepahe.pw"),
            cookie(name: "session", value: "pw-session", domain: "animepahe.pw")
        ]

        XCTAssertEqual(
            CloudflareBypassManager.vettedSharedCookieHeader(
                from: cookies,
                for: "animepahe.com"
            ),
            "cf_clearance=dot-com"
        )
        let resolvedHeader = try XCTUnwrap(
            CloudflareBypassManager.vettedSharedCookieHeader(
                from: cookies,
                for: "animepahe.pw"
            )
        )
        XCTAssertTrue(resolvedHeader.contains("cf_clearance=dot-pw"))
        XCTAssertTrue(resolvedHeader.contains("session=pw-session"))
    }
    #endif

    func testPinnedConnectionIdentityUsesOnlyFreshlyApprovedNumericAddressAndOriginalTLSHost() async throws {
        let policy = SkyStreamRemoteURLPolicy { _ in ["93.184.216.34"] }
        let target = try await policy.validateForNetworkDispatch(
            "https://video.example.test/path",
            purpose: .streamRoot
        )

        XCTAssertEqual(
            SkyStreamPinnedTransportSemantics.connectionIdentity(
                target: target,
                rawAddress: "93.184.216.34"
            ),
            SkyStreamPinnedConnectionIdentity(
                numericAddress: "93.184.216.34",
                tlsServerName: "video.example.test"
            )
        )
        XCTAssertNil(
            SkyStreamPinnedTransportSemantics.connectionIdentity(
                target: target,
                rawAddress: "127.0.0.1"
            ),
            "A later DNS answer cannot replace the numeric endpoint approved for dispatch"
        )
    }

    func testStremioConfiguredOriginAuthorityCoversExactOrigin() async throws {
        let lookups = SkyStreamLockedCounter()
        let policy = SkyStreamRemoteURLPolicy { host in
            lookups.increment()
            switch host {
            case "addon.lan", "other.lan":
                return ["192.168.50.4"]
            default:
                return ["93.184.216.34"]
            }
        }
        let authority = try SkyStreamPinnedOriginAuthority.stremio(
            configuredBaseURL: "http://addon.lan/token/manifest.json?config=secret#fragment"
        )

        let relativeLogo = try authority.resolveResourceURL("images/logo.png")
        XCTAssertEqual(relativeLogo.absoluteString, "http://addon.lan/token/images/logo.png")
        XCTAssertFalse(authority.cacheNamespace.isEmpty)
        XCTAssertEqual(authority.cacheKey(for: relativeLogo), authority.cacheKey(for: relativeLogo))
        let otherAuthority = try SkyStreamPinnedOriginAuthority.stremio(
            configuredBaseURL: "http://addon.lan/other-token"
        )
        XCTAssertNotEqual(authority.cacheNamespace, otherAuthority.cacheNamespace)
        XCTAssertNotEqual(
            authority.cacheKey(for: relativeLogo),
            otherAuthority.cacheKey(for: relativeLogo)
        )

        let first = try await policy.validateForNetworkDispatch(
            "http://addon.lan/token/stream/movie/id.json",
            purpose: .pluginRequest,
            stremioAuthority: authority
        )
        let second = try await policy.validateForNetworkDispatch(
            "http://addon.lan/token/meta/movie/id.json",
            purpose: .pluginRequest,
            stremioAuthority: authority
        )
        XCTAssertEqual(first.checkedAddresses, ["192.168.50.4"])
        XCTAssertEqual(second.checkedAddresses, ["192.168.50.4"])
        XCTAssertEqual(
            SkyStreamPinnedTransportSemantics.connectionIdentity(
                target: first,
                rawAddress: "192.168.50.4"
            ),
            SkyStreamPinnedConnectionIdentity(
                numericAddress: "192.168.50.4",
                tlsServerName: "addon.lan"
            )
        )
        XCTAssertEqual(lookups.value, 2, "Each exact-origin dispatch must resolve freshly.")

        let sibling = try await policy.validateForNetworkDispatch(
            "http://addon.lan/token-evil/stream.json",
            purpose: .pluginRequest,
            stremioAuthority: authority
        )
        XCTAssertEqual(sibling.checkedAddresses, ["192.168.50.4"])
        _ = try await policy.validateForNetworkDispatch(
            "http://addon.lan/token/%2e%2e/admin",
            purpose: .pluginRequest,
            stremioAuthority: authority
        )
        for ambiguousPath in [
            "http://addon.lan/token/%252e%252e/admin",
            "http://addon.lan/token/%252fadmin",
            "http://addon.lan/token/%255cadmin"
        ] {
            _ = try await policy.validateForNetworkDispatch(
                ambiguousPath,
                purpose: .pluginRequest,
                stremioAuthority: authority
            )
        }
        do {
            _ = try await policy.validateForNetworkDispatch(
                "http://other.lan/token/stream.json",
                purpose: .pluginRequest,
                stremioAuthority: authority
            )
            XCTFail("A different private origin must remain prohibited.")
        } catch let error as SkyStreamSecurityError {
            switch error {
            case .prohibitedAddress, .prohibitedHost:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }

        let external = try await policy.validateForNetworkDispatch(
            "https://cdn.example.com/logo.png",
            purpose: .pluginRequest,
            stremioAuthority: authority
        )
        XCTAssertEqual(external.checkedAddresses, ["93.184.216.34"])
        XCTAssertEqual(
            try authority.resolveResourceURL("/token-evil/logo.png").absoluteString,
            "http://addon.lan/token-evil/logo.png"
        )
        XCTAssertTrue(try MPVHeaderProxyStremioTargetPolicy.permitsPrivateDispatch(
            to: try XCTUnwrap(URL(string: "http://addon.lan/public-sibling/segment.ts")),
            authority: authority
        ))
        XCTAssertTrue(try MPVHeaderProxyStremioTargetPolicy.permitsPrivateDispatch(
            to: try XCTUnwrap(URL(string: "http://addon.lan/token/hls/segment.ts")),
            authority: authority
        ))
        XCTAssertFalse(try MPVHeaderProxyStremioTargetPolicy.permitsPrivateDispatch(
            to: try XCTUnwrap(URL(string: "https://cdn.example.com/hls/segment.ts")),
            authority: authority
        ))
        XCTAssertEqual(
            try MPVHeaderProxyStremioTargetPolicy.scopedAuthority(
                for: try XCTUnwrap(URL(string: "http://addon.lan/token/root.m3u8")),
                authority: authority
            ),
            authority
        )
        XCTAssertNil(try MPVHeaderProxyStremioTargetPolicy.scopedAuthority(
            for: try XCTUnwrap(URL(string: "https://cdn.example.com/root.m3u8")),
            authority: authority
        ))
        XCTAssertEqual(try MPVHeaderProxyStremioTargetPolicy.scopedAuthority(
            for: try XCTUnwrap(URL(string: "http://addon.lan/public-sibling/root.m3u8")),
            authority: authority
        ), authority)
        XCTAssertThrowsError(
            try SkyStreamPinnedOriginAuthority.stremio(
                configuredBaseURL: "http://user:password@addon.lan/token"
            )
        ) { XCTAssertEqual($0 as? SkyStreamSecurityError, .credentialsInURL) }
    }

    func testStremioArtworkRequestResolvesRelativeResourceUnderExactAuthority() throws {
        let request = try XCTUnwrap(PinnedProviderImageRequest.stremioResource(
            "images/logo.png?signature=art-secret",
            configuredBaseURL: "http://addon.lan/user-token/manifest.json?config=base-secret"
        ))
        XCTAssertEqual(
            request.url.absoluteString,
            "http://addon.lan/user-token/images/logo.png?signature=art-secret"
        )
        XCTAssertNotNil(request.stremioAuthority)
        XCTAssertFalse(request.cacheKey.contains("art-secret"))
        XCTAssertFalse(request.cacheKey.contains("base-secret"))
        let otherConfiguration = try XCTUnwrap(PinnedProviderImageRequest.stremioResource(
            "images/logo.png?signature=art-secret",
            configuredBaseURL: "http://addon.lan/user-token/manifest.json?config=other-secret"
        ))
        XCTAssertNotEqual(
            request.cacheKey,
            otherConfiguration.cacheKey,
            "Artwork authenticated by different addon configuration must not share decoded cache entries."
        )
        XCTAssertEqual(
            PinnedProviderImageRequest.stremioResource(
                "/outside/logo.png",
                configuredBaseURL: "http://addon.lan/user-token/manifest.json"
            )?.url.absoluteString,
            "http://addon.lan/outside/logo.png"
        )
        let external = try XCTUnwrap(PinnedProviderImageRequest.stremioResource(
            "http://other.lan/logo.png",
            configuredBaseURL: "http://addon.lan/user-token/manifest.json"
        ))
        XCTAssertEqual(external.url.host, "other.lan")
        XCTAssertNotNil(
            external.stremioAuthority,
            "The pinned client retains the original authority so this external host still receives public-only validation"
        )
    }

    func testStremioDownloadReferencePersistsOnlyBoundedSelectionIntent() throws {
        func stream(url: String, title: String) throws -> StremioStream {
            let data = try JSONSerialization.data(withJSONObject: [
                "url": url,
                "name": "1080p",
                "title": title,
                "behaviorHints": [
                    "filename": "episode.mkv",
                    "proxyHeaders": ["request": ["Authorization": "Bearer header-secret"]]
                ],
                "subtitles": [[
                    "url": "https://subs.example.test/sub.vtt?token=subtitle-secret",
                    "lang": "eng"
                ]]
            ])
            return try JSONDecoder().decode(StremioStream.self, from: data)
        }

        let addonID = UUID()
        let selected = try stream(
            url: "https://media.example.test/video.m3u8?token=stream-secret",
            title: "Episode One"
        ).withResolutionProvenance(
            contentType: "series",
            contentID: "tt1234567:1:1",
            streamOrdinal: 4
        )
        let reference = try XCTUnwrap(ProviderContentReference.stremio(
            addonID: addonID,
            stream: selected,
            subtitleOrdinal: 0
        ))
        XCTAssertTrue(reference.hasValidStremioSelection)
        XCTAssertEqual(reference.stremioContentType, "series")
        XCTAssertEqual(reference.stremioContentID, "tt1234567:1:1")
        XCTAssertEqual(reference.stremioStreamOrdinal, 4)
        XCTAssertEqual(reference.stremioSubtitleOrdinal, 0)
        XCTAssertNotNil(reference.stremioSubtitleFingerprint)

        let encoded = try JSONEncoder().encode(reference)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for secret in ["stream-secret", "subtitle-secret", "header-secret", "media.example.test"] {
            XCTAssertFalse(encodedText.contains(secret))
        }
        let roundTrip = try JSONDecoder().decode(ProviderContentReference.self, from: encoded)
        XCTAssertEqual(roundTrip, reference)

        let reorderedEquivalent = try stream(
            url: "https://media.example.test/fresh.m3u8?token=fresh-token",
            title: "Episode One"
        )
        XCTAssertTrue(
            reference.selects(stremio: reorderedEquivalent, ordinal: 17),
            "The non-URL fingerprint should survive provider reordering and renewed signed URLs"
        )
        let different = try stream(
            url: "https://media.example.test/other.m3u8",
            title: "Different Episode"
        )
        XCTAssertFalse(reference.selects(stremio: different, ordinal: 4))
        XCTAssertEqual(
            reference.selectStremioStream(from: [different, reorderedEquivalent])?.url,
            reorderedEquivalent.url
        )
        XCTAssertNil(
            reference.selectStremioStream(from: [different]),
            "A vanished fingerprint must fail closed instead of silently downloading a different ordinal"
        )
        let duplicateEquivalent = try stream(
            url: "https://media.example.test/duplicate.m3u8?token=duplicate-token",
            title: "Episode One"
        )
        var duplicates = Array(repeating: different, count: 5)
        duplicates[0] = duplicateEquivalent
        duplicates[4] = reorderedEquivalent
        XCTAssertEqual(
            reference.selectStremioStream(from: duplicates)?.url,
            reorderedEquivalent.url,
            "When descriptors collide, retain the original ordinal deterministically"
        )

        let reorderedSubtitleData = try JSONSerialization.data(withJSONObject: [
            "url": "https://media.example.test/fresh.m3u8",
            "name": "1080p",
            "title": "Episode One",
            "subtitles": [
                ["url": "https://subs.example.test/es.vtt", "lang": "spa"],
                ["url": "https://subs.example.test/fresh-en.vtt?token=fresh", "lang": "eng"]
            ]
        ])
        let reorderedSubtitles = try JSONDecoder().decode(
            StremioStream.self,
            from: reorderedSubtitleData
        ).subtitles ?? []
        XCTAssertEqual(reference.selectStremioSubtitleIndex(from: reorderedSubtitles), 1)
        XCTAssertNil(
            reference.selectStremioSubtitleIndex(from: Array(reorderedSubtitles.prefix(1))),
            "A vanished subtitle descriptor must not silently select a different language at the old ordinal."
        )

        let malformed = Data("{\"schemaVersion\":1,\"kind\":\"stremio\",\"sourceID\":\"stremio:\(addonID.uuidString)\",\"stremioContentID\":\"id\",\"stremioStreamOrdinal\":0}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ProviderContentReference.self, from: malformed))
    }

    func testPinnedManagedHeadersMergeCookiesAndRangeButCookieOptOutSendsNone() throws {
        let base = try SkyStreamHeaderSanitizer.sanitize(
            [
                "Authorization": "Bearer fixture",
                "Cookie": "explicit=one; shared=explicit"
            ],
            purpose: .pluginRequest
        )
        let withCookies = try SkyStreamPinnedTransportSemantics.effectiveHeaders(
            base: base,
            jarCookie: "jar=two; shared=jar",
            byteRange: 10...99,
            allowsCookies: true,
            method: "GET"
        )
        XCTAssertEqual(
            withCookies.values["cookie"],
            "explicit=one; jar=two; shared=jar"
        )
        XCTAssertEqual(withCookies.values["range"], "bytes=10-99")
        XCTAssertEqual(withCookies.values["authorization"], "Bearer fixture")

        let withoutCookies = try SkyStreamPinnedTransportSemantics.effectiveHeaders(
            base: base,
            jarCookie: "jar=two",
            byteRange: nil,
            allowsCookies: false,
            method: "POST"
        )
        XCTAssertNil(withoutCookies.values["cookie"])
        XCTAssertEqual(withoutCookies.values["authorization"], "Bearer fixture")
    }

    func testServicePinnedHeadersExtractOnlyBoundedSingleGETRangeAndRejectInjection() throws {
        let prepared = try ServicePinnedRequestHeaders(
            [
                "Authorization": "Bearer fixture",
                "Range": "bytes=10-99",
                "X-Trace": "safe"
            ],
            method: "get"
        )
        XCTAssertEqual(prepared.byteRange, 10...99)
        XCTAssertEqual(prepared.headers.values["authorization"], "Bearer fixture")
        XCTAssertEqual(prepared.headers.values["x-trace"], "safe")
        XCTAssertNil(prepared.headers.values["range"])

        XCTAssertThrowsError(
            try ServicePinnedRequestHeaders(
                ["Range": "bytes=0-1", "range": "bytes=2-3"],
                method: "GET"
            )
        ) { XCTAssertEqual($0 as? SkyStreamSecurityError, .duplicateHeader) }
        XCTAssertThrowsError(
            try ServicePinnedRequestHeaders(["Range": "bytes=0-"], method: "GET")
        ) { XCTAssertEqual($0 as? SkyStreamSecurityError, .invalidByteRange) }
        XCTAssertThrowsError(
            try ServicePinnedRequestHeaders(
                ["Range": "bytes=0-\(Int64.max)"],
                method: "GET"
            )
        ) { XCTAssertEqual($0 as? SkyStreamSecurityError, .invalidByteRange) }
        XCTAssertThrowsError(
            try ServicePinnedRequestHeaders(["Range": "bytes=0-1"], method: "POST")
        ) { XCTAssertEqual($0 as? SkyStreamSecurityError, .invalidByteRange) }
        XCTAssertThrowsError(
            try ServicePinnedRequestHeaders(["X-Injected": "safe\r\nHost: local"], method: "GET")
        ) { XCTAssertEqual($0 as? SkyStreamSecurityError, .invalidHeaderValue) }
    }

    func testPinnedCookieJarNeverWidensDomainCookieBeyondExactResponseHost() throws {
        let jar = SkyStreamPinnedCookieJar()
        let responseURL = try XCTUnwrap(URL(string: "https://media.example.test/start"))
        jar.store(
            setCookieValues: ["session=fixture; Domain=example.test; Path=/; Secure"],
            responseURL: responseURL
        )

        XCTAssertEqual(
            jar.cookieHeader(for: try XCTUnwrap(URL(string: "https://media.example.test/next"))),
            "session=fixture"
        )
        XCTAssertNil(
            jar.cookieHeader(for: try XCTUnwrap(URL(string: "https://cdn.example.test/next")))
        )
    }

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

    func testActiveCustomNAT64PrefixesClassifyEmbeddedIPv4AtEveryRFC6052Length() {
        for length in SkyStreamNAT64Prefix.supportedLengths {
            let prefix = syntheticSkyStreamNAT64Prefix(length: length)
            let discovery = [
                skyStreamRFC6052Address(
                    prefix: prefix,
                    length: length,
                    ipv4: [192, 0, 0, 170]
                ),
                skyStreamRFC6052Address(
                    prefix: prefix,
                    length: length,
                    ipv4: [192, 0, 0, 171]
                )
            ]
            XCTAssertEqual(
                SkyStreamRemoteURLPolicy.discoveredNAT64Prefixes(
                    fromIPv6Bytes: discovery
                ),
                Set([SkyStreamNAT64Prefix(prefixBytes: prefix, length: length)!]),
                "custom /\(length) Pref64 discovery must be exact"
            )

            XCTAssertTrue(
                SkyStreamRemoteURLPolicy.isProhibitedIPv6Bytes(
                    skyStreamRFC6052Address(
                        prefix: prefix,
                        length: length,
                        ipv4: [10, 24, 0, 7]
                    ),
                    nat64DiscoveryAddresses: discovery
                ),
                "custom /\(length) must not hide a private IPv4 destination"
            )
            XCTAssertFalse(
                SkyStreamRemoteURLPolicy.isProhibitedIPv6Bytes(
                    skyStreamRFC6052Address(
                        prefix: prefix,
                        length: length,
                        ipv4: [8, 8, 8, 8]
                    ),
                    nat64DiscoveryAddresses: discovery
                ),
                "custom /\(length) must preserve a public IPv4 destination"
            )
        }
    }

    func testNAT64ClassifierDoesNotDecodeArbitraryIPv6Last32Bits() {
        var nativeIPv6: [UInt8] = [
            0x26, 0x07, 0xf8, 0xb0, 0x40, 0x05, 0x08, 0x0a,
            0, 0, 0, 0, 0, 0, 0, 0
        ]
        nativeIPv6.replaceSubrange(12..<16, with: [10, 0, 0, 1])
        XCTAssertFalse(
            SkyStreamRemoteURLPolicy.isProhibitedIPv6Bytes(
                nativeIPv6,
                nat64DiscoveryAddresses: []
            )
        )
    }

    func testFreshDispatchDoesNotReusePref64CacheAcrossNetworkChange() async throws {
        let prefixA = syntheticSkyStreamNAT64Prefix(length: 64)
        let prefixB: [UInt8] = [0x26, 0x06, 0x47, 0x00, 0x72, 0x00, 0x56, 0x78]
        let discoveryA = try [170, 171].map { suffix in
            try XCTUnwrap(SkyStreamRemoteURLPolicy.ipv6PresentationString(
                for: skyStreamRFC6052Address(
                    prefix: prefixA,
                    length: 64,
                    ipv4: [192, 0, 0, UInt8(suffix)]
                )
            ))
        }
        let discoveryB = try [170, 171].map { suffix in
            try XCTUnwrap(SkyStreamRemoteURLPolicy.ipv6PresentationString(
                for: skyStreamRFC6052Address(
                    prefix: prefixB,
                    length: 64,
                    ipv4: [192, 0, 0, UInt8(suffix)]
                )
            ))
        }
        let publicA = try XCTUnwrap(SkyStreamRemoteURLPolicy.ipv6PresentationString(
            for: skyStreamRFC6052Address(
                prefix: prefixA,
                length: 64,
                ipv4: [8, 8, 8, 8]
            )
        ))
        let privateB = try XCTUnwrap(SkyStreamRemoteURLPolicy.ipv6PresentationString(
            for: skyStreamRFC6052Address(
                prefix: prefixB,
                length: 64,
                ipv4: [10, 1, 2, 3]
            )
        ))

        let stateLock = NSLock()
        var currentAddress = publicA
        var currentDiscovery = discoveryA
        let policy = SkyStreamRemoteURLPolicy(
            addressResolver: { _ in
                stateLock.lock()
                defer { stateLock.unlock() }
                return [currentAddress]
            },
            nat64DiscoveryResolver: {
                stateLock.lock()
                defer { stateLock.unlock() }
                return currentDiscovery
            }
        )
        let rawURL = "https://pref64-switch.example.test/video.mp4"
        _ = try await policy.validate(rawURL, purpose: .streamRoot)

        stateLock.lock()
        currentAddress = privateB
        currentDiscovery = discoveryB
        stateLock.unlock()

        do {
            _ = try await policy.validateForNetworkDispatch(rawURL, purpose: .streamRoot)
            XCTFail("Dispatch must rediscover Pref64 instead of reusing the prior network's cache.")
        } catch let error as SkyStreamSecurityError {
            guard case .prohibitedAddress = error else {
                return XCTFail("Unexpected dispatch rejection: \(error)")
            }
        }
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

    private func syntheticSkyStreamNAT64Prefix(length: Int) -> [UInt8] {
        let base: [UInt8] = [
            0x26, 0x06, 0x47, 0x00, 0x71, 0x00, 0x12, 0x34,
            0x00, 0x00, 0x00, 0x00
        ]
        return Array(base.prefix(length / 8))
    }

    private func skyStreamRFC6052Address(
        prefix: [UInt8],
        length: Int,
        ipv4: [UInt8]
    ) -> [UInt8] {
        precondition(SkyStreamNAT64Prefix.supportedLengths.contains(length))
        precondition(prefix.count == length / 8)
        precondition(ipv4.count == 4)
        if length == 96 { return prefix + ipv4 }

        var withoutU = [UInt8](repeating: 0, count: 15)
        withoutU.replaceSubrange(0..<prefix.count, with: prefix)
        withoutU.replaceSubrange(prefix.count..<(prefix.count + 4), with: ipv4)
        return Array(withoutU[0..<8]) + [0] + Array(withoutU[8..<15])
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
        let fixture = Data("""
        {
          "url": "https://video.example.com/master.m3u8?signature=fixture-secret",
          "headers": {
            "Authorization": "Bearer fixture-token",
            "User-Agent": "FixtureAgent/1.0"
          },
          "options": {
            "mirrorHosts": [
              "cdn.example.com",
              "edge.example.com"
            ],
            "keepCookies": [
              "session",
              "hd"
            ],
            "referer": "https://video.example.com/watch/42"
          }
        }
        """.utf8)
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

    func testIOSScopedSettingIsHiddenOnOtherPlatformsAndRequiresCapability() {
        let descriptor = SettingDescriptor(
            id: "skystream",
            title: "SkyStream",
            scope: .iOS,
            requiredCapability: \PlatformCapabilities.supportsSkyStreamPlugins
        )

        XCTAssertTrue(descriptor.availability(on: capabilities(.iOS, skyStream: true)).isAvailable)
        XCTAssertFalse(descriptor.availability(on: capabilities(.iOS, skyStream: false)).isAvailable)
        XCTAssertFalse(descriptor.availability(on: capabilities(.tvOS, skyStream: true)).isAvailable)
        XCTAssertFalse(descriptor.availability(on: capabilities(.visionOS, skyStream: true)).isAvailable)
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
        skyStream: Bool,
        nuvio: Bool = false
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
            supportsSkyStreamPlugins: skyStream,
            supportsNuvioPlugins: nuvio
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

final class AutoModeQualitySelectionTests: XCTestCase {
    func testFixedQualityRecognizes4KAsAnExact2160Target() {
        XCTAssertTrue(AutoModeQualityPreference.quality2160.startsWhenExactTargetArrives)
        XCTAssertFalse(AutoModeQualityPreference.highest.startsWhenExactTargetArrives)
        XCTAssertTrue(
            AutoModeStreamSelection.streamLabelMatchesExactTargetQuality(
                "Cached 4K HDR",
                preference: .quality2160
            )
        )
        XCTAssertTrue(
            AutoModeStreamSelection.streamLabelMatchesExactTargetQuality(
                "3840x2160 WEB-DL",
                preference: .quality2160
            )
        )
        XCTAssertFalse(
            AutoModeStreamSelection.streamLabelMatchesExactTargetQuality(
                "Cached 1080p HDR",
                preference: .quality2160
            )
        )
    }

    func testHighestRanks4KAbove1080AcrossReturnedStreams() throws {
        let fullHD = try stream(url: "https://example.com/1080", label: "1080p WEB-DL")
        let ultraHD = try stream(url: "https://example.com/2160", label: "4K WEB-DL")

        let selected = AutoModeStreamSelection.bestStremioStream(
            from: [fullHD, ultraHD],
            preference: .highest,
            streamsAreFiltered: true
        )

        XCTAssertEqual(selected?.id, ultraHD.id)
        XCTAssertTrue(AutoModeQualityPreference.highest.waitsForAllProviderResults)
        XCTAssertFalse(AutoModeQualityPreference.quality2160.waitsForAllProviderResults)
    }

    func testExactTargetDoesNotUseLowerQualityAsProgressiveMatch() throws {
        let fullHD = try stream(url: "https://example.com/1080", label: "1080p WEB-DL")
        let ultraHD = try stream(url: "https://example.com/2160", label: "2160p WEB-DL")

        XCTAssertNil(
            AutoModeStreamSelection.bestExactTargetStremioStream(
                from: [fullHD],
                preference: .quality2160,
                streamsAreFiltered: true
            )
        )
        XCTAssertEqual(
            AutoModeStreamSelection.bestExactTargetStremioStream(
                from: [fullHD, ultraHD],
                preference: .quality2160,
                streamsAreFiltered: true
            )?.id,
            ultraHD.id
        )
    }

    func testProviderNameContaining4KDoesNotPoisonQualityDetectionOrHiding() throws {
        let suiteName = "AutoModeQualitySelectionTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fullHD = try pengu(
            quality: "1080p",
            filename: "Movie.tt14476236.1.2.1080p.WEB-DL.x264.mkv"
        )
        let ultraHD = try pengu(
            quality: "4K",
            filename: "Movie.tt14476236.1.2.2160p.HEVC.DV.mkv"
        )

        let fullHDLabel = AutoModeStreamSelection.stremioStreamLabel(for: fullHD)
        XCTAssertFalse(fullHDLabel.contains("4K"))
        XCTAssertTrue(fullHDLabel.contains("1080P"))
        XCTAssertEqual(
            AutoModeStreamSelection.streamQualityInfo(
                from: AutoModeStreamSelection.smartPlayerMetadata(for: fullHD)
            ).resolutionHeight,
            1080
        )

        StreamLanguageFilter.setHiddenQualityHeights([2160], defaults: defaults)
        let sourceID = "stremio:quality-poison-tests"
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertFalse(
            StreamLanguageFilter.shouldHide(stremio: fullHD, sourceId: sourceID, defaults: defaults)
        )
        XCTAssertTrue(
            StreamLanguageFilter.shouldHide(stremio: ultraHD, sourceId: sourceID, defaults: defaults)
        )
    }

    private func pengu(quality: String, filename: String) throws -> StremioStream {
        let json = """
        {
          "url": "http://192.168.0.10:8971/media/ok.mp4?src=4khdhub",
          "name": "PenguPlay\\n\(quality)",
          "title": "4KHDHub • \(filename)\\n💾 3.2 GB 🌐 🇬🇧 English"
        }
        """
        return try JSONDecoder().decode(StremioStream.self, from: Data(json.utf8))
    }

    private func stream(url: String, label: String) throws -> StremioStream {
        let json = """
        {
          "url": "\(url)",
          "name": "\(label)",
          "title": "\(label)"
        }
        """
        return try JSONDecoder().decode(StremioStream.self, from: Data(json.utf8))
    }
}

final class StreamLanguageFilterTests: XCTestCase {
    func testLatinoIsRejectedWhenOnlyEnglishSpanishAndBulgarianAreAllowed() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setIncludedLanguages(
            ["English", "Spanish", "Bulgarian"],
            defaults: defaults
        )
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertTrue(isHidden(languageHints: ["Latino"], defaults: defaults))
        XCTAssertTrue(isHidden(languageHints: ["English", "Spanish (Latino)"], defaults: defaults))
        XCTAssertTrue(isHidden(languageHints: ["es-419"], defaults: defaults))
        XCTAssertTrue(isHidden(languageHints: ["spa-LATAM"], defaults: defaults))
        XCTAssertTrue(isHidden(metadata: ["WEB-DL Latino audio"], defaults: defaults))

        XCTAssertFalse(isHidden(languageHints: ["English"], defaults: defaults))
        XCTAssertFalse(isHidden(languageHints: ["Spanish"], defaults: defaults))
        XCTAssertFalse(isHidden(languageHints: ["Bulgarian"], defaults: defaults))
    }

    func testExplicitLatinoTrackRejectsAnOtherwiseAllowedMultiAudioHint() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setIncludedLanguages(["English", "Spanish"], defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertTrue(
            isHidden(
                languageHints: ["English / Latino / Spanish"],
                defaults: defaults
            )
        )
    }

    func testSourceScopeAndExcludeRuleAreFailClosed() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setIncludedLanguages(["English"], defaults: defaults)
        StreamLanguageFilter.setHiddenLanguages(["English"], defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertTrue(isHidden(languageHints: ["English"], defaults: defaults))
        XCTAssertFalse(
            StreamLanguageFilter.shouldHide(
                languageHints: ["English"],
                metadata: [],
                sourceId: "stremio:outside-the-rule-scope",
                defaults: defaults
            )
        )
    }

    func testUntaggedOriginalAudioAndDubbedAnimeRules() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setIncludedLanguages(["English"], defaults: defaults)
        StreamLanguageFilter.setHidesStreamsWithoutLanguageData(true, defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertTrue(isHidden(defaults: defaults))

        StreamLanguageFilter.setAssumesOriginalAudio(true, defaults: defaults)
        XCTAssertFalse(isHidden(defaults: defaults, originalAudioLanguage: "en"))

        StreamLanguageFilter.setTreatsDubbedAnimeAsEnglish(true, defaults: defaults)
        XCTAssertFalse(isHidden(metadata: ["Dubbed audio"], defaults: defaults, isAnime: true))
        XCTAssertTrue(isHidden(metadata: ["Dubbed audio"], defaults: defaults, isAnime: false))
    }

    func testQualityRulesRejectConfiguredAndUnknownQualities() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setHiddenQualityHeights([1080], defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertTrue(isHidden(metadata: ["1080p WEB-DL"], defaults: defaults))
        XCTAssertFalse(isHidden(metadata: ["720p WEB-DL"], defaults: defaults))

        StreamLanguageFilter.setHiddenQualityHeights([], defaults: defaults)
        StreamLanguageFilter.setHidesStreamsWithoutDetectedQuality(true, defaults: defaults)
        XCTAssertTrue(isHidden(metadata: ["Untitled source"], defaults: defaults))
    }

    func testFreeTextMetadataNeverInventsALanguageFromShortTokensOrAHost() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setIncludedLanguages(["English"], defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertFalse(
            isHidden(
                languageHints: ["English"],
                metadata: ["It.Chapter.Two.2019.1080p"],
                defaults: defaults
            )
        )
        XCTAssertFalse(
            isHidden(
                languageHints: ["English"],
                metadata: ["https://cdn.example.de/videos/Movie.2019.1080p.mkv"],
                defaults: defaults
            )
        )

        StreamLanguageFilter.setIncludedLanguages(["Spanish"], defaults: defaults)
        XCTAssertFalse(
            isHidden(
                languageHints: ["Spanish"],
                metadata: ["La.Casa.de.Papel.S01E01.1080p"],
                defaults: defaults
            )
        )
    }

    func testDelimitedShortLanguageTagsInFreeTextStayVisibleUnderAnIncludeList() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setIncludedLanguages(["English"], defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertFalse(isHidden(metadata: ["[EN] Movie 1080p"], defaults: defaults))
        XCTAssertFalse(isHidden(metadata: ["(en) Movie 1080p"], defaults: defaults))
        XCTAssertFalse(isHidden(metadata: ["Movie.EN.1080p.WEB-DL"], defaults: defaults))

        StreamLanguageFilter.setIncludedLanguages(["German"], defaults: defaults)
        XCTAssertFalse(isHidden(metadata: ["Movie.DE.1080p"], defaults: defaults))
        XCTAssertFalse(isHidden(metadata: ["[de] Movie 1080p"], defaults: defaults))

        StreamLanguageFilter.setIncludedLanguages(["French"], defaults: defaults)
        XCTAssertFalse(isHidden(metadata: ["Movie.fr.1080p"], defaults: defaults))
    }

    func testAmbiguousShortCodesInTitleWordsDoNotSatisfyAnIncludeList() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setIncludedLanguages(["Italian"], defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)
        XCTAssertTrue(isHidden(metadata: ["It.Chapter.Two.2019.1080p"], defaults: defaults))

        StreamLanguageFilter.setIncludedLanguages(["German"], defaults: defaults)
        XCTAssertTrue(isHidden(metadata: ["La.Casa.de.Papel.S01E01.1080p"], defaults: defaults))
        XCTAssertTrue(
            isHidden(
                metadata: ["https://cdn.example.de/videos/Movie.2019.1080p.mkv"],
                defaults: defaults
            )
        )
    }

    func testDelimitedShortLanguageTagsCountAsLanguageData() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setHidesStreamsWithoutLanguageData(true, defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertFalse(isHidden(metadata: ["Movie.DE.1080p"], defaults: defaults))
        XCTAssertFalse(isHidden(metadata: ["[EN] Movie 1080p"], defaults: defaults))
        XCTAssertFalse(isHidden(metadata: ["Movie.fr.1080p"], defaults: defaults))

        XCTAssertTrue(isHidden(metadata: ["Movie.2019.1080p.WEB-DL"], defaults: defaults))
        XCTAssertTrue(isHidden(metadata: ["It.Chapter.Two.2019.1080p"], defaults: defaults))
        XCTAssertTrue(isHidden(metadata: ["La.Casa.de.Papel.S01E01.1080p"], defaults: defaults))
        XCTAssertTrue(
            isHidden(
                metadata: ["https://cdn.example.de/videos/Movie.2019.1080p.mkv"],
                defaults: defaults
            )
        )
    }

    func testShortCodeFragmentsInsideWordsAreNotLanguageTags() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setHidesStreamsWithoutLanguageData(true, defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertTrue(isHidden(metadata: ["Movie.2019.Hi10P.1080p"], defaults: defaults))
        XCTAssertTrue(isHidden(metadata: ["Mr. Robot S01E01 1080p"], defaults: defaults))
    }

    func testShortLanguageCodesStillApplyWhenASourceReportsThemAsLanguageData() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setIncludedLanguages(["English"], defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertFalse(isHidden(languageHints: ["en"], defaults: defaults))
        XCTAssertTrue(isHidden(languageHints: ["de"], defaults: defaults))
        XCTAssertTrue(isHidden(languageHints: ["en", "de"], defaults: defaults))
    }

    func testTitleWordsAndURLHostsAreNotReadAsLanguageTags() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        StreamLanguageFilter.setHiddenLanguages(["Italian"], defaults: defaults)
        XCTAssertFalse(
            isHidden(metadata: ["IT.Chapter.Two.2019.1080p.BluRay.x264-SPARKS"], defaults: defaults)
        )
        XCTAssertFalse(
            isHidden(metadata: ["IT.2017.1080p.BluRay.x264-SPARKS"], defaults: defaults)
        )

        StreamLanguageFilter.setHiddenLanguages(["Indonesian"], defaults: defaults)
        XCTAssertFalse(isHidden(metadata: ["ID.Invaded.S01E01.1080p"], defaults: defaults))

        StreamLanguageFilter.setHiddenLanguages(["German"], defaults: defaults)
        XCTAssertFalse(
            isHidden(metadata: ["LA.CASA.DE.PAPEL.S01E01.1080P.WEB-DL"], defaults: defaults)
        )
        XCTAssertFalse(
            isHidden(metadata: ["https://cdn.example.de/stream/file.mkv"], defaults: defaults)
        )

        StreamLanguageFilter.setHiddenLanguages(["Marathi"], defaults: defaults)
        XCTAssertFalse(isHidden(metadata: ["MR.ROBOT.S01E01.1080P.WEB-DL"], defaults: defaults))
    }

    func testDeliberateShortLanguageTagsAreStillDetected() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setIncludedLanguages(["English"], defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertFalse(isHidden(metadata: ["[EN] Movie 1080p"], defaults: defaults))
        XCTAssertTrue(isHidden(metadata: ["Movie.DE.1080p"], defaults: defaults))
    }

    func testDelimitedLanguageTagsSatisfyLanguageDataRequirement() {
        let suite = makeDefaults()
        let defaults = suite.defaults
        defer { defaults.removePersistentDomain(forName: suite.name) }

        StreamLanguageFilter.setHidesStreamsWithoutLanguageData(true, defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds([sourceID], defaults: defaults)

        XCTAssertFalse(isHidden(metadata: ["Movie.DE.1080p"], defaults: defaults))
        XCTAssertFalse(isHidden(metadata: ["[EN] Movie 1080p"], defaults: defaults))
    }

    private var sourceID: String { "stremio:stream-language-filter-tests" }

    private func makeDefaults() -> (name: String, defaults: UserDefaults) {
        let name = "StreamLanguageFilterTests.\(self.name).\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    private func isHidden(
        languageHints: [String] = [],
        metadata: [String] = [],
        defaults: UserDefaults,
        originalAudioLanguage: String? = nil,
        isAnime: Bool = false
    ) -> Bool {
        StreamLanguageFilter.shouldHide(
            languageHints: languageHints,
            metadata: metadata,
            sourceId: sourceID,
            defaults: defaults,
            originalAudioLanguage: originalAudioLanguage,
            isAnime: isAnime
        )
    }
}
#endif
