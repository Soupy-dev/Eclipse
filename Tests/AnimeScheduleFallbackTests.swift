import Foundation
import XCTest
@testable import Eclipse

private final class AnimeScheduleURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) -> (Int, Data, [String: String]))?
    static var paths: [String] = []

    static func configure(_ handler: @escaping (URLRequest) -> (Int, Data, [String: String])) {
        lock.lock()
        self.handler = handler
        paths = []
        lock.unlock()
    }

    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.paths.append(request.url?.path ?? "")
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data, headers) = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AnimeScheduleFallbackTests: XCTestCase {
    private var now: Date { Date(timeIntervalSince1970: 1_788_998_400) }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnimeScheduleURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func row(_ changes: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = [
            "title": "Example Season 2", "route": "example-2", "english": "Example Second Season",
            "romaji": "Example 2", "native": "例", "episodeDate": ISO8601DateFormatter().string(from: now.addingTimeInterval(3600)),
            "episodeNumber": 5, "airType": "raw", "airingStatus": "unaired",
            "delayedFrom": "0001-01-01T00:00:00Z", "delayedUntil": "0001-01-01T00:00:00Z",
            "mediaTypes": [["route": "tv", "name": "TV"]], "imageVersionRoute": "anime/jpg/example.jpg"
        ]
        for (key, value) in changes { result[key] = value }
        return result
    }

    private func anime(_ changes: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = [
            "route": "example-2", "websites": ["aniList": "anilist.co/anime/101/Example", "mal": "myanimelist.net/anime/202/Example"],
            "genres": [["route": "action", "name": "Action"]]
        ]
        for (key, value) in changes { result[key] = value }
        return result
    }

    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    private func mapped(_ changes: [String: Any] = [:], animeChanges: [String: Any] = [:], stale: Bool = false) throws -> [AniListAiringScheduleEntry] {
        let row = try JSONDecoder().decode(AnimeScheduleTimetableEntry.self, from: data(row(changes)))
        let anime = try JSONDecoder().decode(AnimeScheduleAnime.self, from: data(anime(animeChanges)))
        return AnimeScheduleEntryMapper.entries(from: row, anime: anime, window: ScheduleDateWindow.envelope(dayCount: 7, now: now), preferredLanguageCode: "en", stale: stale)
    }

    private func stub(rows: [[String: Any]]? = nil, missingWeek: Bool = false) throws {
        let timetable = try data(rows ?? [row()])
        let catalog = try data(["page": 1, "totalAmount": 1, "anime": [anime()]])
        let firstWeek = AnimeScheduleWeek.covering(ScheduleDateWindow.envelope(dayCount: 7, now: now)).first?.week
        AnimeScheduleURLProtocol.configure { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" else { return (401, Data(), [:]) }
            if request.url?.path.contains("timetables") == true {
                let week = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "week" }?.value
                if missingWeek, week != firstWeek.map(String.init) { return (404, Data(), [:]) }
                return (200, timetable, [:])
            }
            return (200, catalog, [:])
        }
    }

    func testFallbackUsesAnimeScheduleBeforeMAL() async throws {
        var usedMAL = false
        let entries = try mapped()
        let result = try await AnimeScheduleFallback.load(
            aniList: { throw AnimeScheduleError.http(503) },
            animeSchedule: { AnimeAiringScheduleResult(entries: entries, isAuthoritativeForNotifications: false) },
            mal: { usedMAL = true; throw AnimeScheduleError.unavailable },
            permitsFallback: { _ in true }
        )
        XCTAssertFalse(usedMAL)
        XCTAssertEqual(result.entries.first?.mediaId, 101)
        XCTAssertTrue(result.entries.first?.hasKnownAiringTime == true)
    }

    func testHealthyAniListDoesNotContactFallback() async throws {
        var usedFallback = false
        let result = try await AnimeScheduleFallback.load(
            aniList: { AnimeAiringScheduleResult(entries: [], isAuthoritativeForNotifications: true) },
            animeSchedule: { usedFallback = true; throw AnimeScheduleError.unavailable },
            mal: { usedFallback = true; throw AnimeScheduleError.unavailable },
            permitsFallback: { _ in true }
        )
        XCTAssertTrue(result.isAuthoritativeForNotifications)
        XCTAssertFalse(usedFallback)
    }

    func testBothProvidersFailThenMALIsUsed() async throws {
        var usedMAL = false
        let result = try await AnimeScheduleFallback.load(
            aniList: { throw AnimeScheduleError.http(503) },
            animeSchedule: { throw AnimeScheduleError.http(429) },
            mal: { usedMAL = true; return AnimeAiringScheduleResult(entries: [], isAuthoritativeForNotifications: false) },
            permitsFallback: { _ in true }
        )
        XCTAssertTrue(usedMAL)
        XCTAssertFalse(result.isAuthoritativeForNotifications)
    }

    func testCancellationNeverFallsThroughToAnotherProvider() async {
        for cancellationAtPrimary in [true, false] {
            var usedMAL = false
            do {
                _ = try await AnimeScheduleFallback.load(
                    aniList: {
                        if cancellationAtPrimary { throw CancellationError() }
                        throw AnimeScheduleError.http(503)
                    },
                    animeSchedule: { throw URLError(.cancelled) },
                    mal: { usedMAL = true; throw AnimeScheduleError.unavailable },
                    permitsFallback: { _ in true }
                )
                XCTFail("Cancellation must propagate")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(usedMAL)
        }
    }

    func testOrdinaryForbiddenResponseDoesNotAuthorizeFallback() async {
        var usedFallback = false
        do {
            _ = try await AnimeScheduleFallback.load(
                aniList: { throw NSError(domain: "AniList", code: 403) },
                animeSchedule: { usedFallback = true; throw AnimeScheduleError.unavailable },
                mal: { usedFallback = true; throw AnimeScheduleError.unavailable },
                permitsFallback: { error in
                    let health = AnimeProviderHealthCenter.shared
                    return health.shouldUseMALFallback(for: health.classifyAniListFailure(error))
                }
            )
            XCTFail("Forbidden must remain a failure")
        } catch { XCTAssertEqual((error as NSError).code, 403) }
        XCTAssertFalse(usedFallback)
    }

    func testWeekWindowsCoverThirtyDaysAndISOYearBoundary() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-31T23:00:00Z"))
        let weeks = AnimeScheduleWeek.covering(ScheduleDateWindow.envelope(dayCount: 30, now: date))
        XCTAssertEqual(weeks.first, AnimeScheduleWeek(year: 2026, week: 53))
        XCTAssertTrue(weeks.contains(AnimeScheduleWeek(year: 2027, week: 1)))
        XCTAssertEqual(Set(weeks).count, weeks.count)
        XCTAssertGreaterThanOrEqual(weeks.count, 5)
    }

    func testBatchReleasesHaveDistinctEpisodeIdentities() throws {
        let entries = try mapped(["subtractedEpisodeNumber": 3]).map(ScheduleEntry.init(animeEntry:))
        XCTAssertEqual(entries.map(\.episode), [3, 4, 5])
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
        XCTAssertEqual(entries.first?.animeMediaIDs, [101, -202])
        XCTAssertEqual(entries.first?.format, "TV")
        XCTAssertTrue(entries.allSatisfy(\.hasKnownAiringTime))
    }

    func testRejectsInvalidEpisodesWrongAirTypeAndAdultRows() throws {
        for change: [String: Any] in [
            ["episodeNumber": 0], ["episodeNumber": 100_001], ["subtractedEpisodeNumber": 0],
            ["subtractedEpisodeNumber": 6], ["episodeNumber": 500, "subtractedEpisodeNumber": 1],
            ["episodeDate": "0001-01-01T00:00:00Z"], ["airType": "dub"], ["route": "../example-2"]
        ] { XCTAssertTrue(try mapped(change).isEmpty) }
        XCTAssertTrue(try mapped(animeChanges: ["genres": [["route": "hentai"]]]).isEmpty)
        XCTAssertTrue(try mapped(animeChanges: ["websites": [:]]).isEmpty)
    }

    func testCrossReferencesRequireExactHostAndAnimePath() {
        XCTAssertEqual(AnimeScheduleAnime.identifier("anilist.co/anime/101/title", host: "anilist.co"), 101)
        for text in ["https://anilist.co.evil.test/anime/101", "https://evil.test/anilist.co/anime/101", "https://anilist.co/manga/101", "https://anilist.co/anime/-101", "https://user@anilist.co/anime/101", "https://anilist.co/anime/99999999999999999"] {
            XCTAssertNil(AnimeScheduleAnime.identifier(text, host: "anilist.co"))
        }
    }

    func testMALOnlyMappingUsesExistingNegativeNamespace() throws {
        let entry = try XCTUnwrap(mapped(animeChanges: ["websites": ["mal": "myanimelist.net/anime/202/title"]]).first)
        XCTAssertEqual(entry.mediaId, -202)
    }

    func testDelayWithdrawsAirtimeButNormalSentinelDoesNot() throws {
        XCTAssertTrue(try XCTUnwrap(mapped().first).hasKnownAiringTime)
        let delayed = try XCTUnwrap(mapped(["airingStatus": "delayed-air"]).first)
        XCTAssertFalse(delayed.hasKnownAiringTime)
        XCTAssertTrue(delayed.airingTimeWithdrawn == true)
        let stale = try XCTUnwrap(mapped(stale: true).first)
        XCTAssertFalse(stale.hasKnownAiringTime)
        XCTAssertFalse(stale.airingTimeWithdrawn == true)
    }

    func testMovieAndONAFormatsRemainDistinctForSpecialFiltering() throws {
        XCTAssertEqual(try mapped(["mediaTypes": [["route": "movie-chinese"]]]).first?.format, "MOVIE")
        XCTAssertEqual(try mapped(["mediaTypes": [["route": "ona-chinese"]]]).first?.format, "ONA")
    }

    func testFetchPaginatesWeeksAndCachesWithoutDuplicateEpisodes() async throws {
        try stub()
        let session = session()
        defer { session.invalidateAndCancel() }
        let service = AnimeScheduleService(session: session, token: "fixture-token", requestSpacing: 0)
        let first = try await service.fetchSchedule(daysAhead: 7, now: now)
        let count = AnimeScheduleURLProtocol.count
        let second = try await service.fetchSchedule(daysAhead: 7, now: now)
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertGreaterThan(count, 1)
        XCTAssertEqual(AnimeScheduleURLProtocol.count, count)
        XCTAssertFalse(first.isAuthoritativeForNotifications)
    }

    func testMissingWeekRetainsConfirmedEntriesWithoutDeletionAuthority() async throws {
        try stub(missingWeek: true)
        let session = session()
        defer { session.invalidateAndCancel() }
        let service = AnimeScheduleService(session: session, token: "fixture-token", requestSpacing: 0)
        let result = try await service.fetchSchedule(daysAhead: 7, now: now)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertTrue(result.entries.first?.hasKnownAiringTime == true)
        XCTAssertFalse(result.isAuthoritativeForNotifications)
        XCTAssertTrue(result.notice?.contains("unavailable") == true)
    }

    func testDiskCacheSurvivesRelaunchWithoutInventingFreshNotificationAuthority() async throws {
        try stub()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let session = session()
        defer { session.invalidateAndCancel() }
        let initial = AnimeScheduleService(session: session, token: "fixture-token", cacheURL: cache, requestSpacing: 0)
        _ = try await initial.fetchSchedule(daysAhead: 7, now: now)
        AnimeScheduleURLProtocol.configure { _ in (503, Data(), [:]) }
        let restored = AnimeScheduleService(session: session, token: "fixture-token", cacheURL: cache, requestSpacing: 0)
        let result = try await restored.fetchSchedule(daysAhead: 7, now: now.addingTimeInterval(3600))
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertFalse(result.entries.first?.hasKnownAiringTime == true)
        XCTAssertFalse(result.entries.first?.airingTimeWithdrawn == true)
        XCTAssertTrue(result.notice?.contains("Saved") == true)
        XCTAssertFalse(String(decoding: try Data(contentsOf: cache), as: UTF8.self).contains("fixture-token"))
    }

    func testUnconfiguredBuildDoesNotSendRequests() async {
        AnimeScheduleURLProtocol.configure { _ in (200, Data(), [:]) }
        do {
            _ = try await AnimeScheduleService(token: "$(ANIMESCHEDULE_API_TOKEN)").fetchSchedule(daysAhead: 7, now: now)
            XCTFail("Missing token must fail")
        } catch {}
        XCTAssertEqual(AnimeScheduleURLProtocol.count, 0)
    }

    func testRecoveryKeepsCanonicalEpisodeIdentityDespiteProviderTitleChange() throws {
        let fallback = try XCTUnwrap(mapped().first)
        var primary = try XCTUnwrap(mapped(["english": "Different provider spelling"]).first)
        primary.scheduleProvider = .aniList
        let a = ScheduleEntry(animeEntry: primary)
        let b = ScheduleEntry(animeEntry: fallback)
        XCTAssertEqual(a.id, b.id)
        XCTAssertTrue(a.isSameEpisode(as: b))
        XCTAssertNotEqual(a.title, b.title)
        XCTAssertNotEqual(a.provider, b.provider)
#if os(iOS)
        XCTAssertTrue(AnimeScheduleNotificationPolicy.matches(b, knownIDs: [101], aliases: []))
        XCTAssertTrue(AnimeScheduleNotificationPolicy.matches(b, knownIDs: [-202], aliases: []))
        XCTAssertFalse(AnimeScheduleNotificationPolicy.matches(b, knownIDs: [102], aliases: ["example second season"]))
#endif
    }

#if os(iOS)
    func testExplicitLegacyReminderAndMutesSurviveProviderSwitch() throws {
        let entry = ScheduleEntry(animeEntry: try XCTUnwrap(mapped().first))
        let reminder = LocalEpisodeNotificationReminder(id: "anime:title:old spelling:e5", source: .anime, sourceMediaID: 101, tmdbID: 77, tmdbMediaType: .tv, title: "Old spelling", season: nil, episode: 5, airingAt: now, hasKnownAiringTime: true, isStreamingRelease: false, isAnimeSpecial: false)
        XCTAssertEqual(AnimeScheduleNotificationPolicy.explicitKey(entry, reminders: [reminder]), reminder.id)
        let legacyMute = "subscription:title:example 2:s0:e5"
        XCTAssertEqual(AnimeScheduleNotificationPolicy.subscriptionKey(entry, subscriptionID: "subscription", existingKeys: [legacyMute]), legacyMute)
        let canonical = "subscription:media:101:e5"
        XCTAssertEqual(AnimeScheduleNotificationPolicy.subscriptionKey(entry, subscriptionID: "subscription", existingKeys: [canonical]), canonical)
    }

    func testChangedOrWithdrawnAirtimeReplacesOnlyMatchingPendingRequests() throws {
        let fresh = ScheduleEntry(animeEntry: try XCTUnwrap(mapped().first))
        let delayed = ScheduleEntry(animeEntry: try XCTUnwrap(mapped(["airingStatus": "delayed-air"]).first))
        let stale = ScheduleEntry(animeEntry: try XCTUnwrap(mapped(stale: true).first))
        let info: [AnyHashable: Any] = ["source": "anime", "sourceMediaID": 101, "episodeNumber": 5]
        XCTAssertTrue(AnimeScheduleNotificationPolicy.supersedes(info, entries: [fresh]))
        XCTAssertTrue(AnimeScheduleNotificationPolicy.supersedes(info, entries: [delayed]))
        XCTAssertFalse(AnimeScheduleNotificationPolicy.supersedes(info, entries: [stale]))
        XCTAssertFalse(AnimeScheduleNotificationPolicy.supersedes(["source": "anime", "sourceMediaID": 999, "episodeNumber": 5], entries: [fresh]))
        XCTAssertFalse(AnimeScheduleNotificationPolicy.supersedes(["source": "western", "sourceMediaID": 101, "episodeNumber": 5], entries: [fresh]))
        let batch: [AnyHashable: Any] = ["source": "anime", "sourceMediaID": 101, "episodeNumbers": [3, 4, 5]]
        XCTAssertFalse(AnimeScheduleNotificationPolicy.supersedes(batch, entries: [fresh]))
        XCTAssertTrue(AnimeScheduleNotificationPolicy.supersedes(batch, entries: try mapped(["subtractedEpisodeNumber": 3]).map(ScheduleEntry.init(animeEntry:))))
    }

    func testDelayedReminderSurvivesOriginalAirtimeAndRelaunchUntilRescheduled() throws {
        var reminder = LocalEpisodeNotificationReminder(id: "anime:media:101:e5", source: .anime, sourceMediaID: 101, tmdbID: 77, tmdbMediaType: .tv, title: "Example", season: nil, episode: 5, airingAt: now.addingTimeInterval(-3600), hasKnownAiringTime: false, isStreamingRelease: false, isAnimeSpecial: false)
        let restored = try JSONDecoder().decode(LocalEpisodeNotificationReminder.self, from: JSONEncoder().encode(reminder))
        XCTAssertFalse(restored.hasExpired(at: now))
        reminder.airingAt = now.addingTimeInterval(86400)
        reminder.hasKnownAiringTime = true
        XCTAssertFalse(reminder.hasExpired(at: now))
        XCTAssertTrue(reminder.hasExpired(at: now.addingTimeInterval(86401)))
    }
#endif

    func testUnmappedTimetableDoesNotBlockLastResortFallback() async throws {
        let timetable = try data([row()])
        let catalog = try data(["page": 1, "totalAmount": 1, "anime": [anime(["websites": [:]])]])
        AnimeScheduleURLProtocol.configure { request in
            (200, request.url?.path.contains("timetables") == true ? timetable : catalog, [:])
        }
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AnimeScheduleService(session: session, token: "fixture-token", requestSpacing: 0).fetchSchedule(daysAhead: 7, now: now)
            XCTFail("An unusable timetable must allow the next provider")
        } catch { XCTAssertTrue(error is AnimeScheduleError) }
    }

    func testProviderOutageStopsFurtherRequestsAndInvalidRateLimitHeadersAreBounded() async {
        for status in [401, 429, 503] {
            AnimeScheduleURLProtocol.configure { _ in (status, Data(), ["Retry-After": "nan", "X-RateLimit-Reset": "inf"]) }
            let session = session()
            let service = AnimeScheduleService(session: session, token: "fixture-token", requestSpacing: 0)
            do {
                _ = try await service.fetchSchedule(daysAhead: 30, now: now)
                XCTFail("An unavailable provider must fail")
            } catch {}
            XCTAssertEqual(AnimeScheduleURLProtocol.count, 1)
            if status == 429 {
                do { _ = try await service.fetchSchedule(daysAhead: 30, now: now) } catch {}
                XCTAssertEqual(AnimeScheduleURLProtocol.count, 1)
            }
            session.invalidateAndCancel()
        }
    }

    @MainActor
    func testLiveScheduleThroughProductionClientAndOutageFallback() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_RUN_LIVE_SCHEDULE_TESTS"] == "1" else {
            throw XCTSkip("Live API validation is opt-in")
        }
        let service = AnimeScheduleService()
        for days in [7, 30] {
            let started = Date()
            let result = try await AnimeScheduleFallback.load(
                aniList: { throw NSError(domain: "AniList", code: 503) },
                animeSchedule: { try await service.fetchSchedule(daysAhead: days) },
                mal: { XCTFail("Live AnimeSchedule should serve the fallback"); throw AnimeScheduleError.unavailable },
                permitsFallback: { error in
                    let health = AnimeProviderHealthCenter.shared
                    return health.shouldUseMALFallback(for: health.classifyAniListFailure(error))
                }
            )
            XCTAssertFalse(result.entries.isEmpty)
            XCTAssertTrue(result.entries.allSatisfy { $0.scheduleProvider == .animeSchedule && $0.mediaId != 0 })
            XCTAssertEqual(Set(result.entries.map(\.id)).count, result.entries.count)
            let entries = result.entries.map(ScheduleEntry.init(animeEntry:))
            XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
            XCTAssertTrue(entries.contains( where: \.hasKnownAiringTime))
#if os(iOS)
            let entry = try XCTUnwrap(entries.first)
            XCTAssertTrue(AnimeScheduleNotificationPolicy.matches(entry, knownIDs: entry.animeMediaIDs, aliases: []))
#endif
            print("AnimeSchedule live: days=\(days) entries=\(entries.count) confirmed=\(entries.filter(\.hasKnownAiringTime).count) elapsed=\(Int(Date().timeIntervalSince(started)))s notice=\(result.notice ?? "")")
        }
        let result = try await AniListService.shared.fetchAiringScheduleResult(daysAhead: 7)
        XCTAssertFalse(result.entries.isEmpty)
        XCTAssertTrue(result.entries.contains( where: \.hasKnownAiringTime))
        print("AnimeSchedule live: shared schedule facade entries=\(result.entries.count) provider=\(result.entries.first?.scheduleProvider?.rawValue ?? "aniList")")
        let model = ScheduleViewModel()
        await model.loadSchedule(mode: .anime, localTimeZone: true)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.scheduleEntries.isEmpty)
        XCTAssertTrue(model.dayBuckets.contains { !$0.items.isEmpty })
        let snapshot = await model.notificationScheduleSnapshot(dayCount: 7, requiredSources: [.anime])
        XCTAssertTrue(snapshot.successfulSources.contains(.anime))
        XCTAssertFalse(snapshot.entries.isEmpty)
        if snapshot.entries.contains(where: { $0.provider == .animeSchedule }) {
            XCTAssertFalse(snapshot.authoritativeSources.contains(.anime))
            XCTAssertNotNil(model.scheduleNotice)
        }
        let entry = try XCTUnwrap(model.scheduleEntries.first { $0.title.lowercased().contains("one piece") } ?? model.scheduleEntries.first)
        let detail = await model.lookupTMDBResult(for: entry)
        XCTAssertNotNil(detail)
        print("AnimeSchedule live: calendar buckets=\(model.dayBuckets.count) notification entries=\(snapshot.entries.count) title navigation=\(detail != nil)")
    }
}
