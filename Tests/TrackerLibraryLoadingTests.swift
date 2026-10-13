import Foundation
import XCTest
#if os(macOS)
@testable import EclipseMac
#else
@testable import Eclipse
#endif

final class TrackerLibraryLoadingTests: XCTestCase {
    @MainActor
    func testReaderFormatFilteredPagesContinueBeforePublishingCompleteResults() async throws {
        for service in [TrackerService.anilist, .myAnimeList] {
            for kind in [TrackerLibraryKind.manga, .lightNovel] {
                let cache = TrackerLibraryCache()
                let owner = TrackerLibrarySession(owner: UUID(), operationGeneration: 1, accountGeneration: 1,
                    serviceGeneration: 1, service: service, userID: "42")
                let key = TrackerLibraryCacheKey(session: owner, kind: kind, status: nil, section: .list)
                let value = TrackerLibraryEntry(service: service, kind: kind, mediaID: 17, entryID: 24,
                    aniListID: 17, malID: 13, title: "Reading", alternateTitles: [], coverLarge: nil, coverMedium: nil,
                    total: 100, genres: [], averageScore: nil, status: .current, progress: 7, score: 80, updatedAt: nil,
                    format: kind == .lightNovel ? "NOVEL" : "MANGA")
                var calls = 0
                var completeUpdates: [Bool] = []
                let result = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
                    calls += 1
                    if calls < 3 {
                        let next: TrackerLibraryCursor
                        if service == .myAnimeList {
                            next = .mal(try XCTUnwrap(URL(string: "https://api.myanimelist.net/v2/users/@me/mangalist?offset=\(calls * 100)&limit=100")))
                        } else { next = .page(calls + 1) }
                        return TrackerLibraryPage(entries: [], next: next, rawEntryCount: 100)
                    }
                    XCTAssertEqual(cursor, service == .anilist ? .page(3) : .mal(try XCTUnwrap(URL(string: "https://api.myanimelist.net/v2/users/@me/mangalist?offset=200&limit=100"))))
                    return TrackerLibraryPage(entries: [value], next: nil)
                }, onUpdate: { completeUpdates.append($0.isComplete) })
                XCTAssertEqual(calls, 3)
                XCTAssertEqual(result, [value])
                XCTAssertEqual(completeUpdates, [false, false, true])
                XCTAssertEqual(cache.snapshot(for: key)?.isComplete, true)
            }
        }
    }

    @MainActor
    func testReaderTrulyEmptyNonterminalPagesRemainInvalid() async throws {
        for service in [TrackerService.anilist, .myAnimeList] {
            let owner = TrackerLibrarySession(owner: UUID(), operationGeneration: 1, accountGeneration: 1,
                serviceGeneration: 1, service: service, userID: "42")
            let key = TrackerLibraryCacheKey(session: owner, kind: .lightNovel, status: nil, section: .list)
            let cache = TrackerLibraryCache()
            do {
                _ = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { _ in
                    TrackerLibraryPage(entries: [], next: .page(2))
                }, onUpdate: nil)
                XCTFail("An empty provider page cannot prove more filtered rows")
            } catch {
                guard case TrackerLibraryError.invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertNil(cache.snapshot(for: key))
        }
    }

    @MainActor
    func testReaderFullyFilteredPaginationCompletesEmptyWithoutExceedingProviderBounds() async throws {
        let owner = TrackerLibrarySession(owner: UUID(), operationGeneration: 1, accountGeneration: 1,
            serviceGeneration: 1, service: .anilist, userID: "42")
        let key = TrackerLibraryCacheKey(session: owner, kind: .lightNovel, status: nil, section: .list)
        let cache = TrackerLibraryCache()
        var calls = 0
        let entries = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
            guard case .page(let page) = cursor else { throw TrackerLibraryError.invalidResponse }
            calls += 1
            return TrackerLibraryPage(entries: [], next: page < 200 ? .page(page + 1) : nil,
                rawEntryCount: 200, providerEntryCount: 100)
        }, onUpdate: nil)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(calls, 200)
        XCTAssertEqual(cache.snapshot(for: key)?.isComplete, true)
        let overflowing = TrackerLibraryCache()
        do {
            _ = try await overflowing.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { _ in
                TrackerLibraryPage(entries: [], next: nil, rawEntryCount: Int.max)
            }, onUpdate: nil)
            XCTFail("Unbounded raw page counts must be rejected")
        } catch {
            guard case TrackerLibraryError.tooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertNil(overflowing.snapshot(for: key))
    }

    func testRefreshGateCoalescesLifecycleEventsWithoutReauthorizingAccountABA() {
        var gate = TrackerLibraryRefreshGate()
        let original = session()
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(gate.begin(session: original, now: now))
        XCTAssertFalse(gate.begin(session: original, now: now.addingTimeInterval(0.5)))
        XCTAssertTrue(gate.begin(session: original, now: now.addingTimeInterval(1)))
        let replaced = session(owner: original.owner, generation: 2)
        XCTAssertTrue(gate.begin(session: replaced, now: now.addingTimeInterval(1)))
        XCTAssertTrue(gate.begin(session: original, now: now.addingTimeInterval(-1)))
    }

    @MainActor
    func testWebsiteStatusMoveExpiresEverySiblingCacheAndOnlyCompleteResultsRemoveRows() async throws {
        let cache = TrackerLibraryCache()
        let owner = TrackerLibrarySession(owner: UUID(), operationGeneration: 1, accountGeneration: 1,
            serviceGeneration: 1, service: .anilist, userID: "42")
        let planning = TrackerLibraryCacheKey(session: owner, kind: .anime, status: .planning, section: .list)
        let completed = TrackerLibraryCacheKey(session: owner, kind: .anime, status: .completed, section: .list)
        let other = key()
        let now = Date(timeIntervalSince1970: 10_000)
        for target in [planning, completed, other] {
            let token = cache.begin(target)
            cache.store(TrackerLibrarySnapshot(entries: target == planning ? [animeEntry(progress: 0, total: 12, status: .planning)] : [],
                isComplete: true, isStale: false, fetchedAt: now), key: target, token: token)
            cache.finish(token, key: target)
        }
        cache.markStale(session: owner)
        XCTAssertEqual(cache.snapshot(for: planning, now: now)?.isStale, true)
        XCTAssertEqual(cache.snapshot(for: completed, now: now)?.isStale, true)
        XCTAssertEqual(cache.snapshot(for: other, now: now)?.isStale, false)
        var requests = 0
        let removed = try await cache.load(key: planning, forceRefresh: false, now: { now }, isAuthorized: { true }, fetchPage: { _ in
            requests += 1
            return TrackerLibraryPage(entries: [], next: nil)
        }, onUpdate: nil)
        XCTAssertTrue(removed.isEmpty)
        let moved = try await cache.load(key: completed, forceRefresh: false, now: { now }, isAuthorized: { true }, fetchPage: { _ in
            requests += 1
            return TrackerLibraryPage(entries: [self.animeEntry(progress: 12, total: 12, status: .completed)], next: nil)
        }, onUpdate: nil)
        XCTAssertEqual(moved.map(\.status), [.completed])
        XCTAssertEqual(requests, 2)
        _ = try await cache.load(key: completed, forceRefresh: false, now: { now }, isAuthorized: { true }, fetchPage: { _ in
            XCTFail("The completed refresh must be reusable")
            throw TrackerLibraryError.unavailable
        }, onUpdate: nil)
        cache.markStale(session: owner)
        do {
            _ = try await cache.load(key: completed, forceRefresh: false, now: { now }, isAuthorized: { true }, fetchPage: { _ in
                throw TrackerLibraryError.invalidResponse
            }, onUpdate: nil)
            XCTFail("Failed refresh must remain visible")
        } catch { XCTAssertTrue(error is TrackerLibraryError) }
        XCTAssertEqual(cache.snapshot(for: completed, now: now)?.entries, moved)
        XCTAssertEqual(cache.snapshot(for: completed, now: now)?.isStale, true)
    }

    @MainActor
    func testLifecycleRevalidationRejectsLateOldGETAndPreservesItsCompleteFallback() async throws {
        let cache = TrackerLibraryCache()
        let key = key()
        let token = cache.begin(key)
        cache.store(TrackerLibrarySnapshot(entries: [entry(1)], isComplete: true, isStale: false, fetchedAt: Date()), key: key, token: token)
        cache.finish(token, key: key)
        let gate = TrackerLibraryTestPageGate(ignoresCancellation: true)
        let old = Task { @MainActor in
            try await cache.load(key: key, forceRefresh: true, isAuthorized: { true }, fetchPage: { _ in try await gate.fetch() }, onUpdate: nil)
        }
        await gate.started.wait()
        cache.markStale(session: key.session)
        do { _ = try await old.value; XCTFail("Superseded read cannot complete") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cache.snapshot(for: key)?.entries.map(\.mediaID), [1])
        XCTAssertEqual(cache.snapshot(for: key)?.isStale, true)
        let fresh = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { _ in
            TrackerLibraryPage(entries: [self.entry(2)], next: nil)
        }, onUpdate: nil)
        gate.release(TrackerLibraryPage(entries: [entry(99)], next: nil))
        await Task.yield()
        XCTAssertEqual(cache.snapshot(for: key)?.entries, fresh)
        XCTAssertEqual(fresh.map(\.mediaID), [2])
    }

    func testTraktCustomListRenamePreservesCacheIdentityButDifferentProvidersDoNotCollide() {
        let owner = session()
        let original = key(session: owner, section: .customList(id: 42, name: "Old name"))
        let renamed = key(session: owner, section: .customList(id: 42, name: "New name"))
        XCTAssertEqual(original, renamed)
        XCTAssertEqual(Set([original, renamed]).count, 1)
        XCTAssertNotEqual(original, key(session: owner, section: .customList(id: 43, name: "Old name")))
        XCTAssertNotEqual(original, key(session: owner, section: .aniListCustomList(name: "42")))
    }

    @MainActor
    func testLargeLibrariesPublishFirstPageBeforeFetchingRemainingPages() async throws {
        for count in [100, 1_000, 10_000] {
            let cache = TrackerLibraryCache()
            let key = key()
            var delivered: [Int] = []
            var requests = 0
            let started = Date()
            var firstPageElapsed: TimeInterval?
            let entries = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
                guard case .page(let page) = cursor else { throw TrackerLibraryError.invalidResponse }
                XCTAssertEqual(delivered.last ?? 0, (page - 1) * 100)
                requests += 1
                let first = (page - 1) * 100 + 1
                return TrackerLibraryPage(entries: (first..<(first + 100)).map { self.entry($0) }, next: page * 100 < count ? .page(page + 1) : nil)
            }, onUpdate: {
                delivered.append($0.entries.count)
                if firstPageElapsed == nil { firstPageElapsed = Date().timeIntervalSince(started) }
            })
            let elapsed = Date().timeIntervalSince(started)
            let beforeReuse = requests
            let reused = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { _ in
                requests += 1
                throw TrackerLibraryError.unavailable
            }, onUpdate: nil)
            XCTAssertEqual(reused.count, count)
            XCTAssertEqual(requests, beforeReuse)
            print("Tracker cache fixture rows=\(count) firstPageMs=\((firstPageElapsed ?? 0) * 1_000) completeMs=\(elapsed * 1_000) requests=\(requests) freshCacheRequests=\(requests - beforeReuse)")
            XCTAssertEqual(entries.count, count)
            XCTAssertEqual(requests, count / 100)
            XCTAssertEqual(delivered.first, 100)
            XCTAssertEqual(delivered.last, count)
            XCTAssertEqual(cache.snapshot(for: key)?.isComplete, true)
        }
    }

    @MainActor
    func testConcurrentSubscribersShareEveryPageWithoutSupersedingEachOther() async throws {
        let cache = TrackerLibraryCache()
        let key = key()
        let gate = TrackerLibraryTestPageGate()
        let joined = TrackerLibraryTestSignal()
        var authorizations = 0
        var requests: [TrackerLibraryCursor] = []
        var firstUpdates: [Int] = []
        var secondUpdates: [Int] = []
        let first = Task { @MainActor in
            try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
                requests.append(cursor)
                if cursor == .page(1) { return try await gate.fetch() }
                return TrackerLibraryPage(entries: [self.entry(2)], next: nil)
            }, onUpdate: { firstUpdates.append($0.entries.count) })
        }
        await gate.started.wait()
        let second = Task { @MainActor in
            try await cache.load(key: key, forceRefresh: true, isAuthorized: {
                authorizations += 1
                if authorizations == 2 { joined.fire() }
                return true
            }, fetchPage: { _ in
                XCTFail("A second consumer must share the in-flight page stream")
                throw TrackerLibraryError.unavailable
            }, onUpdate: { secondUpdates.append($0.entries.count) })
        }
        await joined.wait()
        gate.release(TrackerLibraryPage(entries: [entry(1)], next: .page(2)))
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult.map(\.mediaID), [1, 2])
        XCTAssertEqual(secondResult, firstResult)
        XCTAssertEqual(firstUpdates, [1, 2])
        XCTAssertEqual(secondUpdates, [1, 2])
        XCTAssertEqual(requests, [.page(1), .page(2)])
    }

    @MainActor
    func testCancellingOneSubscriberDoesNotCancelAnotherSubscriberFetch() async throws {
        let cache = TrackerLibraryCache()
        let key = key()
        let gate = TrackerLibraryTestPageGate()
        let joined = TrackerLibraryTestSignal()
        var authorizations = 0
        var firstUpdates = 0
        let first = Task { @MainActor in
            try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { _ in
                try await gate.fetch()
            }, onUpdate: { _ in firstUpdates += 1 })
        }
        await gate.started.wait()
        let second = Task { @MainActor in
            try await cache.load(key: key, forceRefresh: false, isAuthorized: {
                authorizations += 1
                if authorizations == 2 { joined.fire() }
                return true
            }, fetchPage: { _ in throw TrackerLibraryError.unavailable }, onUpdate: nil)
        }
        await joined.wait()
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled subscriber must return promptly") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(gate.cancelled)
        XCTAssertEqual(firstUpdates, 0)
        gate.release(TrackerLibraryPage(entries: [entry(1)], next: nil))
        let rows = try await second.value
        XCTAssertEqual(rows.map(\.mediaID), [1])
        XCTAssertEqual(firstUpdates, 0)
        XCTAssertEqual(cache.snapshot(for: key)?.entries, rows)
    }

    @MainActor
    func testLastSubscriberCancelsFetchAndLateOldResponseCannotReplaceNewRead() async throws {
        let cache = TrackerLibraryCache()
        let key = key()
        let gate = TrackerLibraryTestPageGate(ignoresCancellation: true)
        let abandoned = Task { @MainActor in
            try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { _ in
                try await gate.fetch()
            }, onUpdate: { _ in XCTFail("An abandoned response cannot publish") })
        }
        await gate.started.wait()
        abandoned.cancel()
        do { _ = try await abandoned.value; XCTFail("The final subscriber must detach promptly") }
        catch { XCTAssertTrue(error is CancellationError) }
        await gate.cancellation.wait()
        XCTAssertTrue(gate.cancelled)
        let fresh = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { _ in
            TrackerLibraryPage(entries: [self.entry(2)], next: nil)
        }, onUpdate: nil)
        gate.release(TrackerLibraryPage(entries: [entry(1)], next: nil))
        await Task.yield()
        XCTAssertEqual(fresh.map(\.mediaID), [2])
        XCTAssertEqual(cache.snapshot(for: key)?.entries.map(\.mediaID), [2])
    }

    @MainActor
    func testSubscriberAuthorityExpiresIndependentlyDuringSharedRead() async throws {
        let cache = TrackerLibraryCache()
        let key = key()
        let gate = TrackerLibraryTestPageGate()
        let joined = TrackerLibraryTestSignal()
        var firstAuthorized = true
        var secondAuthorizations = 0
        let first = Task { @MainActor in
            try await cache.load(key: key, forceRefresh: false, isAuthorized: { firstAuthorized }, fetchPage: { _ in
                try await gate.fetch()
            }, onUpdate: { _ in XCTFail("Expired screen cannot receive private rows") })
        }
        await gate.started.wait()
        let second = Task { @MainActor in
            try await cache.load(key: key, forceRefresh: false, isAuthorized: {
                secondAuthorizations += 1
                if secondAuthorizations == 2 { joined.fire() }
                return true
            }, fetchPage: { _ in throw TrackerLibraryError.unavailable }, onUpdate: nil)
        }
        await joined.wait()
        firstAuthorized = false
        gate.release(TrackerLibraryPage(entries: [entry(1)], next: nil))
        do { _ = try await first.value; XCTFail("Expired subscriber cannot receive the result") }
        catch { XCTAssertTrue(error is CancellationError) }
        let rows = try await second.value
        XCTAssertEqual(rows.map(\.mediaID), [1])
    }

    @MainActor
    func testMembershipStopsAtVerifiedMatchButAbsenceRequiresCompletePagination() async throws {
        for expected in [true, false] {
            let cache = TrackerLibraryCache()
            let key = key()
            var requests = 0
            let found = try await cache.contains(entry(expected ? 1 : 99).id, key: key, forceRefresh: false,
                isAuthorized: { true }, fetchPage: { cursor in
                    requests += 1
                    return TrackerLibraryPage(entries: [self.entry(requests)], next: cursor == .page(1) ? .page(2) : nil)
                })
            XCTAssertEqual(found, expected)
            XCTAssertEqual(requests, expected ? 1 : 2)
            XCTAssertEqual(cache.snapshot(for: key)?.isComplete, !expected)
        }
    }

    @MainActor
    func testMembershipDoesNotTreatStaleFallbackAsPresenceEvidence() async throws {
        for soughtID in [1, 2] {
            let cache = TrackerLibraryCache()
            let key = key()
            let old = Date(timeIntervalSince1970: 100_000)
            let token = cache.begin(key)
            cache.store(TrackerLibrarySnapshot(entries: [entry(1)], isComplete: true, isStale: false, fetchedAt: old), key: key, token: token)
            cache.finish(token, key: key)
            var requests = 0
            let found = try await cache.contains(entry(soughtID).id, key: key, forceRefresh: false,
                now: { old.addingTimeInterval(121) }, isAuthorized: { true }, fetchPage: { cursor in
                    requests += 1
                    if cursor == .page(1) { return TrackerLibraryPage(entries: [self.entry(2)], next: .page(2)) }
                    return TrackerLibraryPage(entries: [], next: nil)
                })
            XCTAssertEqual(found, soughtID == 2)
            XCTAssertEqual(requests, soughtID == 2 ? 1 : 2)
        }
    }

    @MainActor
    func testEarlyMembershipCompletionLeavesFullLibrarySubscriberRunning() async throws {
        let cache = TrackerLibraryCache()
        let key = key()
        let firstPage = TrackerLibraryTestPageGate()
        let secondPage = TrackerLibraryTestPageGate()
        let joined = TrackerLibraryTestSignal()
        var authorizations = 0
        let library = Task { @MainActor in
            try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
                if cursor == .page(1) { return try await firstPage.fetch() }
                return try await secondPage.fetch()
            }, onUpdate: nil)
        }
        await firstPage.started.wait()
        let membership = Task { @MainActor in
            try await cache.contains(self.entry(1).id, key: key, forceRefresh: false, isAuthorized: {
                authorizations += 1
                if authorizations == 2 { joined.fire() }
                return true
            }, fetchPage: { _ in throw TrackerLibraryError.unavailable })
        }
        await joined.wait()
        firstPage.release(TrackerLibraryPage(entries: [entry(1)], next: .page(2)))
        let included = try await membership.value
        XCTAssertTrue(included)
        await secondPage.started.wait()
        XCTAssertFalse(secondPage.cancelled)
        secondPage.release(TrackerLibraryPage(entries: [entry(2)], next: nil))
        let rows = try await library.value
        XCTAssertEqual(rows.map(\.mediaID), [1, 2])
        XCTAssertEqual(cache.snapshot(for: key)?.isComplete, true)
    }

    @MainActor
    func testMembershipReceiptsRequireCurrentEpochOwnerSectionAndFreshClock() {
        var receipts = TrackerLibraryMembershipReceipts()
        let owner = session()
        let generation = UUID()
        let now = Date(timeIntervalSince1970: 100_000)
        let movie = entry(1)
        receipts.record(true, entry: movie, section: .customList(id: 9, name: "Original"), session: owner, generation: generation, now: now)
        XCTAssertEqual(receipts.value(entry: movie, section: .customList(id: 9, name: "Renamed"), session: owner, generation: generation, now: now), true)
        XCTAssertNil(receipts.value(entry: movie, section: .watchlist, session: owner, generation: generation, now: now))
        XCTAssertNil(receipts.value(entry: movie, section: .customList(id: 9, name: "Original"), session: session(owner: owner.owner, generation: 3), generation: generation, now: now))
        XCTAssertNil(receipts.value(entry: movie, section: .customList(id: 9, name: "Original"), session: owner, generation: UUID(), now: now))
        for age in [-1.0, 120.0] {
            receipts.record(false, entry: movie, section: .watchlist, session: owner, generation: generation, now: now)
            XCTAssertNil(receipts.value(entry: movie, section: .watchlist, session: owner, generation: generation, now: now.addingTimeInterval(age)))
        }
        receipts.record(false, entry: movie, section: .watchlist, session: owner, generation: generation, now: now)
        XCTAssertEqual(receipts.value(entry: movie, section: .watchlist, session: owner, generation: generation, now: now), false)
        receipts.invalidate(session: owner)
        XCTAssertNil(receipts.value(entry: movie, section: .watchlist, session: owner, generation: generation, now: now))
        for index in 1...(TrackerLibraryMembershipReceipts.maximumEntries + 1) {
            receipts.record(true, entry: entry(index), section: .watchlist, session: owner, generation: generation,
                now: now.addingTimeInterval(Double(index) / 1_000))
        }
        XCTAssertNil(receipts.value(entry: movie, section: .watchlist, session: owner, generation: generation, now: now.addingTimeInterval(1)))
        XCTAssertEqual(receipts.value(entry: entry(TrackerLibraryMembershipReceipts.maximumEntries + 1), section: .watchlist,
            session: owner, generation: generation, now: now.addingTimeInterval(1)), true)
    }

    func testResolutionQueueOnlyAdmitsVisibleRowsAndPrioritizesSelection() {
        let rows = (1...10_000).map(entry)
        var queue = TrackerLibraryResolutionQueue()
        XCTAssertTrue(queue.entries.isEmpty)
        for row in rows.prefix(8) { queue.appear(row) }
        XCTAssertEqual(queue.entries.count, 8)
        queue.select(rows[500])
        queue.disappear(rows[0])
        queue.disappear(rows[500])
        let selected = queue.next()
        XCTAssertEqual(selected?.entry.mediaID, 501)
        XCTAssertEqual(selected?.priority, .interactive)
        XCTAssertEqual(queue.next()?.entry.mediaID, 2)
        queue.appear(rows[0])
        XCTAssertEqual(queue.entries.last?.mediaID, 1)
        queue.appear(rows[1])
        XCTAssertFalse(queue.entries.contains { $0.mediaID == 2 })
        queue.retry(rows[1])
        XCTAssertEqual(queue.next()?.entry.mediaID, 2)
    }

    func testResolutionQueueRefreshReplacesVisibleAndReadmitsInvisibleMetadata() {
        let original = entry(1)
        var updated = original
        updated.tmdbID = 100
        var queue = TrackerLibraryResolutionQueue()
        queue.appear(original)
        XCTAssertEqual(queue.next()?.entry.tmdbID, 1)
        queue.refreshMetadata(updated)
        let visible = queue.next()
        XCTAssertEqual(visible?.entry.tmdbID, 100)
        XCTAssertEqual(visible?.priority, .visible)
        queue.disappear(updated)
        updated.tmdbID = 200
        queue.refreshMetadata(updated)
        XCTAssertTrue(queue.entries.isEmpty)
        queue.appear(updated)
        XCTAssertEqual(queue.next()?.entry.tmdbID, 200)
        XCTAssertNil(queue.next())
        queue.select(original)
        queue.refreshMetadata(updated)
        let selected = queue.next()
        XCTAssertEqual(selected?.entry.tmdbID, 200)
        XCTAssertEqual(selected?.priority, .interactive)
    }

    @MainActor
    func testFreshCacheAvoidsNetworkAndForceRefreshReplacesRemovedEntriesOnlyWhenComplete() async throws {
        let cache = TrackerLibraryCache()
        let key = key()
        let now = Date(timeIntervalSince1970: 100_000)
        _ = try await cache.load(key: key, forceRefresh: false, now: { now }, isAuthorized: { true }, fetchPage: { _ in
            TrackerLibraryPage(entries: [self.entry(1), self.entry(2)], next: nil)
        }, onUpdate: nil)
        var requested = false
        let reused = try await cache.load(key: key, forceRefresh: false, now: { now }, isAuthorized: { true }, fetchPage: { _ in
            requested = true
            throw TrackerLibraryError.unavailable
        }, onUpdate: nil)
        XCTAssertFalse(requested)
        XCTAssertEqual(reused.map(\.mediaID), [1, 2])
        var updates: [TrackerLibrarySnapshot] = []
        _ = try await cache.load(key: key, forceRefresh: true, now: { now }, isAuthorized: { true }, fetchPage: { cursor in
            if cursor == .page(1) { return TrackerLibraryPage(entries: [self.entry(1)], next: .page(2)) }
            return TrackerLibraryPage(entries: [], next: nil)
        }, onUpdate: { updates.append($0) })
        XCTAssertEqual(updates[1].entries.map(\.mediaID), [1, 2])
        XCTAssertTrue(updates[1].isStale)
        XCTAssertEqual(updates.last?.entries.map(\.mediaID), [1])
        XCTAssertEqual(updates.last?.isComplete, true)
    }

    @MainActor
    func testRefreshFailurePreservesCompleteReadableCache() async throws {
        let cache = TrackerLibraryCache()
        let key = key()
        let old = Date(timeIntervalSince1970: 100_000)
        let token = cache.begin(key)
        cache.store(TrackerLibrarySnapshot(entries: [entry(1), entry(2)], isComplete: true, isStale: false, fetchedAt: old), key: key, token: token)
        cache.finish(token, key: key)
        var updates: [TrackerLibrarySnapshot] = []
        do {
            _ = try await cache.load(key: key, forceRefresh: false, now: { old.addingTimeInterval(121) }, isAuthorized: { true }, fetchPage: { cursor in
                if cursor == .page(1) { return TrackerLibraryPage(entries: [self.entry(3)], next: .page(2)) }
                throw TrackerLibraryError.requestFailed(429)
            }, onUpdate: { updates.append($0) })
            XCTFail("The rate-limit failure must remain visible")
        } catch {
            guard case TrackerLibraryError.requestFailed(429) = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(updates.last?.entries.map(\.mediaID), [3, 1, 2])
        XCTAssertEqual(cache.snapshot(for: key, now: old.addingTimeInterval(121))?.entries.map(\.mediaID), [1, 2])
    }

    @MainActor
    func testFirstLoadFailureRetainsPartialRowsAndRetriesFromFirstPage() async throws {
        let cache = TrackerLibraryCache()
        let key = key()
        do {
            _ = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
                if cursor == .page(1) { return TrackerLibraryPage(entries: [self.entry(1)], next: .page(2)) }
                throw TrackerLibraryError.invalidResponse
            }, onUpdate: nil)
            XCTFail("Malformed second page must fail")
        } catch {}
        XCTAssertEqual(cache.snapshot(for: key)?.isComplete, false)
        var cursors: [TrackerLibraryCursor] = []
        _ = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
            cursors.append(cursor)
            return TrackerLibraryPage(entries: [self.entry(2)], next: nil)
        }, onUpdate: nil)
        XCTAssertEqual(cursors, [.page(1)])
        XCTAssertEqual(cache.snapshot(for: key)?.entries.map(\.mediaID), [2])
    }

    @MainActor
    func testStaleOwnerCompletionCannotPublishOrCache() async throws {
        let cache = TrackerLibraryCache()
        let original = key()
        var active = original.session
        var deliveries = 0
        do {
            _ = try await cache.load(key: original, forceRefresh: false, isAuthorized: { active == original.session }, fetchPage: { _ in
                active = self.session(owner: original.session.owner, generation: 3)
                return TrackerLibraryPage(entries: [self.entry(1)], next: nil)
            }, onUpdate: { _ in deliveries += 1 })
            XCTFail("A to B to A must expire the first owner generation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(deliveries, 0)
        XCTAssertNil(cache.snapshot(for: original))
    }

    @MainActor
    func testCacheSeparatesAccountsKindsSectionsAndGenerations() {
        let cache = TrackerLibraryCache()
        let original = key()
        let token = cache.begin(original)
        cache.store(TrackerLibrarySnapshot(entries: [entry(1)], isComplete: true, isStale: false, fetchedAt: Date()), key: original, token: token)
        let variants = [
            key(session: session(owner: UUID())),
            key(session: session(owner: original.session.owner, generation: 2)),
            key(session: session(owner: original.session.owner, account: 2)),
            key(session: session(owner: original.session.owner, serviceGeneration: 2)),
            key(session: session(owner: original.session.owner, user: "other")),
            key(session: original.session, kind: .show),
            key(session: original.session, section: .history)
        ]
        for variant in variants { XCTAssertNil(cache.snapshot(for: variant)) }
        cache.invalidate(session: original.session)
        XCTAssertFalse(cache.isCurrent(token, key: original))
        XCTAssertNil(cache.snapshot(for: original))
    }

    @MainActor
    func testCancellationAndMutationInvalidatePendingLoad() async throws {
        let cache = TrackerLibraryCache()
        let key = key()
        var deliveries = 0
        do {
            _ = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { _ in
                cache.invalidate(session: key.session)
                return TrackerLibraryPage(entries: [self.entry(1)], next: nil)
            }, onUpdate: { _ in deliveries += 1 })
            XCTFail("An earlier read cannot replace a later edit")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(deliveries, 0)
    }

    @MainActor
    func testPaginationCycleAndRepeatedContentAreBounded() async throws {
        for sameCursor in [true, false] {
            let cache = TrackerLibraryCache()
            var requests = 0
            do {
                _ = try await cache.load(key: key(), forceRefresh: false, isAuthorized: { true }, fetchPage: { _ in
                    requests += 1
                    return TrackerLibraryPage(entries: [self.entry(1)], next: .page(sameCursor ? 1 : requests + 1))
                }, onUpdate: nil)
                XCTFail("Cyclic pagination must fail")
            } catch {}
            XCTAssertLessThanOrEqual(requests, 2)
        }
    }

    @MainActor
    func testExpiredFutureDatedAndExcessCacheEntriesAreEvicted() {
        let cache = TrackerLibraryCache()
        let now = Date(timeIntervalSince1970: 100_000)
        var keys: [TrackerLibraryCacheKey] = []
        for index in 0..<20 {
            let key = key(session: session(user: "\(index)"))
            keys.append(key)
            let token = cache.begin(key)
            cache.store(TrackerLibrarySnapshot(entries: [entry(index + 1)], isComplete: true, isStale: false,
                fetchedAt: now.addingTimeInterval(Double(index))), key: key, token: token)
            cache.finish(token, key: key)
        }
        XCTAssertNil(cache.snapshot(for: keys[0], now: now.addingTimeInterval(20)))
        XCTAssertNotNil(cache.snapshot(for: keys[19], now: now.addingTimeInterval(20)))
        XCTAssertNil(cache.snapshot(for: keys[19], now: now))
        XCTAssertNil(cache.snapshot(for: keys[18], now: now.addingTimeInterval(TrackerLibraryCache.staleInterval + 100)))
    }

    func testTraktPaginationUsesEffectiveHeadersAndContinuesShortPagesWithoutHeaders() throws {
        let response = try response(["X-Pagination-Page": "1", "X-Pagination-Limit": "50", "X-Pagination-Page-Count": "20", "X-Pagination-Item-Count": "1000"])
        XCTAssertEqual(try TrackerLibraryPolicy.traktNextPage(response: response, requested: 1, count: 50), .page(2))
        XCTAssertEqual(try TrackerLibraryPolicy.traktNextPage(response: self.response([:]), requested: 1, count: 12), .page(2))
        XCTAssertNil(try TrackerLibraryPolicy.traktNextPage(response: self.response([:]), requested: 2, count: 0))
        XCTAssertThrowsError(try TrackerLibraryPolicy.traktNextPage(response: self.response(["X-Pagination-Page": "1"]), requested: 2, count: 20))
        XCTAssertThrowsError(try TrackerLibraryPolicy.traktNextPage(response: self.response(["X-Pagination-Page-Count": "999999999"]), requested: 1, count: 20))
        XCTAssertThrowsError(try TrackerLibraryPolicy.traktNextPage(response: self.response(["X-Pagination-Limit": "garbage"]), requested: 1, count: 20))
    }

    func testAniListEmptyCustomListScalarArrayIsKnownEmptyAndMalformedMembershipStaysUnreadable() throws {
        let media: [String: Any] = ["id": 42, "type": "ANIME", "title": ["romaji": "Example"], "episodes": 12]
        func page(_ membership: Any?) throws -> Data {
            var row: [String: Any] = ["id": 24, "mediaId": 42, "status": "CURRENT", "progress": 3, "score": 85, "media": media]
            if let membership { row["customLists"] = membership }
            return try JSONSerialization.data(withJSONObject: ["data": ["MediaListCollection": ["hasNextChunk": false, "lists": [["entries": [row]]]]]])
        }
        for value: Any in [[Any](), [String: Bool]()] {
            let entry = try XCTUnwrap(TrackerAniListLibraryPage.decode(page(value), kind: .anime).entries.first)
            XCTAssertTrue(entry.customListMembershipIsKnown)
            XCTAssertTrue(entry.customLists.isEmpty)
            XCTAssertEqual(entry.progress, 3)
        }
        let enabled = try XCTUnwrap(TrackerAniListLibraryPage.decode(page(["Weekend": true, "Hidden": false]), kind: .anime).entries.first)
        XCTAssertEqual(enabled.customLists, ["Weekend"])
        for value in [nil, NSNull()] {
            let entry = try XCTUnwrap(TrackerAniListLibraryPage.decode(page(value), kind: .anime).entries.first)
            XCTAssertFalse(entry.customListMembershipIsKnown)
        }
        for value: Any in [[true], [["name": "Weekend", "enabled": true]], ["Weekend": 1], "[]"] {
            XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(page(value), kind: .anime))
        }
    }

    func testAniListLogicalDuplicatesWithDifferentEntryIDsMergeDeterministicallyWithoutHidingOtherConflicts() throws {
        let media: [String: Any] = ["id": 42, "type": "ANIME", "title": ["romaji": "Example"], "episodes": 12]
        let row: [String: Any] = ["id": 24, "mediaId": 42, "status": "CURRENT", "progress": 3, "score": 85, "media": media]
        func page(_ rows: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["data": ["MediaListCollection": ["hasNextChunk": false,
                "lists": rows.map { ["entries": [$0]] }]]])
        }
        var duplicate = row
        duplicate["id"] = 12
        for rows in [[row, duplicate], [duplicate, row], [row, duplicate, row]] {
            let result = try TrackerAniListLibraryPage.decode(page(rows), kind: .anime)
            XCTAssertEqual(result.entries.count, 1)
            XCTAssertEqual(result.entries.first?.entryID, 12)
            XCTAssertEqual(result.entries.first?.mediaID, 42)
        }
        for changes: [String: Any] in [["progress": 4], ["score": 90], ["status": "COMPLETED"],
            ["customLists": ["Weekend": true]], ["updatedAt": 1], ["media": ["id": 42, "type": "ANIME", "title": ["romaji": "Changed"], "episodes": 12]]] {
            var conflict = duplicate
            conflict.merge(changes) { _, incoming in incoming }
            XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(page([row, conflict]), kind: .anime))
        }
        let original = try XCTUnwrap(TrackerAniListLibraryPage.decode(page([row, duplicate]), kind: .anime).entries.first)
        var authoritative = original
        authoritative.entryID = 999
        var edit = TrackerLibraryEdit(entry: original)
        edit.progress = 4
        XCTAssertFalse(edit.conflicts(original: original, current: authoritative))
        XCTAssertEqual(edit.aniListValues(original: original)["progress"] as? Int, 4)
        XCTAssertNil(edit.aniListValues(original: original)["id"])
    }

    func testAniListDifferentEntryVersionsChooseOnlyStrictlyNewerValidUserState() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        var earlier = animeEntry(progress: 3, total: 12)
        earlier.entryID = 12
        earlier.updatedAt = Date(timeIntervalSince1970: 8_000)
        var latest = earlier
        latest.entryID = 24
        latest.progress = 4
        latest.score = 90
        latest.status = .paused
        latest.updatedAt = Date(timeIntervalSince1970: 9_000)
        for pair in [(earlier, latest), (latest, earlier)] {
            XCTAssertEqual(try TrackerLibraryPolicy.mergedAniListDuplicate(pair.0, pair.1, now: now), latest)
        }
        for date in [nil, earlier.updatedAt, Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: -1),
            now.addingTimeInterval(301)] {
            var unknown = latest
            unknown.updatedAt = date
            XCTAssertThrowsError(try TrackerLibraryPolicy.mergedAniListDuplicate(earlier, unknown, now: now))
        }
        var sameID = latest
        sameID.entryID = earlier.entryID
        XCTAssertEqual(try TrackerLibraryPolicy.mergedAniListDuplicate(earlier, sameID, now: now), sameID)
        XCTAssertEqual(try TrackerLibraryPolicy.mergedAniListDuplicate(sameID, earlier, now: now), sameID)
        var differentMembership = latest
        differentMembership.customLists = ["Weekend"]
        XCTAssertThrowsError(try TrackerLibraryPolicy.mergedAniListDuplicate(earlier, differentMembership, now: now))
        var differentMetadata = latest
        differentMetadata.year = 2020
        XCTAssertThrowsError(try TrackerLibraryPolicy.mergedAniListDuplicate(earlier, differentMetadata, now: now))
        var final = latest
        final.entryID = earlier.entryID
        final.progress = 5
        final.updatedAt = now
        for rows in [[earlier, latest, final], [earlier, final, latest], [latest, earlier, final],
            [latest, final, earlier], [final, earlier, latest], [final, latest, earlier]] {
            let merged = try rows.dropFirst().reduce(rows[0]) { try TrackerLibraryPolicy.mergedAniListDuplicate($0, $1, now: now) }
            XCTAssertEqual(merged, final)
        }
    }

    @MainActor
    func testAniListVersionsAcrossChunksUpdateInEitherOrderAndChangedVersionsAllowAnotherPage() async throws {
        var earlier = animeEntry(progress: 3, total: 12)
        earlier.entryID = 12
        earlier.updatedAt = Date(timeIntervalSince1970: 8_000)
        var latest = earlier
        latest.entryID = 24
        latest.progress = 4
        latest.updatedAt = Date(timeIntervalSince1970: 9_000)
        let owner = TrackerLibrarySession(owner: UUID(), operationGeneration: 1, accountGeneration: 1,
            serviceGeneration: 1, service: .anilist, userID: "42")
        let target = key(session: owner, kind: .anime, section: .list)
        for pair in [(earlier, latest), (latest, earlier)] {
            let cache = TrackerLibraryCache()
            let rows = try await cache.load(key: target, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
                TrackerLibraryPage(entries: [cursor == .page(1) ? pair.0 : pair.1], next: cursor == .page(1) ? .page(2) : nil)
            }, onUpdate: nil)
            XCTAssertEqual(rows, [latest])
            var appended = [pair.0]
            try TrackerLibraryPolicy.append([pair.1], to: &appended)
            XCTAssertEqual(appended, [latest])
        }
        let cache = TrackerLibraryCache()
        let rows = try await cache.load(key: target, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
            guard case .page(let page) = cursor else { throw TrackerLibraryError.invalidResponse }
            return TrackerLibraryPage(entries: page == 1 ? [earlier] : page == 2 ? [latest] : [],
                next: page < 3 ? .page(page + 1) : nil)
        }, onUpdate: nil)
        XCTAssertEqual(rows, [latest])
        var final = latest
        final.entryID = 36
        final.progress = 5
        final.updatedAt = Date(timeIntervalSince1970: 10_000)
        let unchangedMiddle = TrackerLibraryCache()
        let afterMiddle = try await unchangedMiddle.load(key: target, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
            guard case .page(let page) = cursor else { throw TrackerLibraryError.invalidResponse }
            return TrackerLibraryPage(entries: [page == 1 ? latest : page == 2 ? earlier : final],
                next: page < 3 ? .page(page + 1) : nil)
        }, onUpdate: nil)
        XCTAssertEqual(afterMiddle, [final])
    }

    func testPersonalListMetadataCompletesWithoutPaginationHeadersAndFollowsExplicitHeaders() throws {
        XCTAssertNil(try TrackerLibraryPolicy.traktListsNextPage(response: response([:]), requested: 1, count: 2))
        XCTAssertNil(try TrackerLibraryPolicy.traktListsNextPage(response: response([:]), requested: 1, count: 0))
        XCTAssertNil(try TrackerLibraryPolicy.traktListsNextPage(response: response([:]), requested: 1, count: 1_000))
        XCTAssertThrowsError(try TrackerLibraryPolicy.traktListsNextPage(response: response([:]), requested: 1, count: 1_001))
        let headers = try response(["X-Pagination-Page": "1", "X-Pagination-Limit": "10", "X-Pagination-Page-Count": "2", "X-Pagination-Item-Count": "12"])
        XCTAssertEqual(try TrackerLibraryPolicy.traktListsNextPage(response: headers, requested: 1, count: 10), .page(2))
        let data = try JSONSerialization.data(withJSONObject: (1...150).map { ["name": "List", "ids": ["trakt": $0]] })
        XCTAssertEqual(try TrackerTraktLibraryList.decode(data).count, 150)
    }

    @MainActor
    func testFilteredCustomListEmptyPageContinuesWhileContradictoryHistoryEmptyPageFails() async throws {
        let headers = try response(["X-Pagination-Page": "1", "X-Pagination-Limit": "10", "X-Pagination-Page-Count": "2", "X-Pagination-Item-Count": "12"])
        XCTAssertThrowsError(try TrackerLibraryPolicy.traktNextPage(response: headers, requested: 1, count: 0))
        let section = TrackerLibrarySection.customList(id: 9, name: "Owned")
        let first = try TrackerLibraryPolicy.traktLibraryPage(response: headers, requested: 1, entries: [], kind: .movie, section: section)
        XCTAssertEqual(first.next, .page(2))
        let cache = TrackerLibraryCache()
        let key = key(section: section)
        var requested: [TrackerLibraryCursor] = []
        let rows = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
            requested.append(cursor)
            return cursor == .page(1) ? first : TrackerLibraryPage(entries: [self.entry(42)], next: nil)
        }, onUpdate: nil)
        XCTAssertEqual(rows.map(\.mediaID), [42])
        XCTAssertEqual(requested, [.page(1), .page(2)])
        XCTAssertNil(try TrackerLibraryPolicy.traktNextPage(response: response(["X-Pagination-Page-Count": "0", "X-Pagination-Item-Count": "0"]), requested: 1, count: 0))
        XCTAssertThrowsError(try TrackerLibraryPolicy.traktNextPage(response: response(["X-Pagination-Page-Count": "0", "X-Pagination-Item-Count": "12"]), requested: 1, count: 0))
    }

    func testOwnedShowsFollowPaginationHeadersWhenTheEndpointBeginsPaging() throws {
        let headers = try response(["X-Pagination-Page": "1", "X-Pagination-Limit": "10", "X-Pagination-Page-Count": "2", "X-Pagination-Item-Count": "12"])
        let page = try TrackerLibraryPolicy.traktLibraryPage(response: headers, requested: 1,
            entries: (1...10).map { entry($0) }, kind: .show, section: .collection)
        XCTAssertEqual(page.next, .page(2))
        XCTAssertThrowsError(try TrackerLibraryPolicy.traktLibraryPage(response: headers, requested: 1,
            entries: (1...101).map { entry($0) }, kind: .show, section: .collection))
    }

    func testTrackerLibraryDecodeDiagnosticsHideDynamicKeysAndGraphQLMessages() throws {
        let path = TrackerLibraryDiagnosticsTestKey(stringValue: "private-list-name")
        let error = DecodingError.typeMismatch(Bool.self,
            .init(codingPath: [try XCTUnwrap(path)], debugDescription: "private-account-token"))
        XCTAssertEqual(TrackerLibraryDiagnostics.failure(error), "decode:type-mismatch path=*")
        let data = try JSONSerialization.data(withJSONObject: ["errors": [["message": "private-account-token", "status": 401]]])
        XCTAssertEqual(TrackerLibraryDiagnostics.graphQL(data), "graphql-errors=1 graphql-status=401")
        XCTAssertFalse(TrackerLibraryDiagnostics.section(.customList(id: 9, name: "private-list-name")).contains("private"))
    }

    func testTrackerLibrarySemanticRefusalsAndAuthenticationFailuresHaveSafeSpecificReasons() {
        XCTAssertNil(TrackerLibraryPolicy.validationFailure(animeEntry(progress: 3, total: 12)))
        XCTAssertEqual(TrackerLibraryPolicy.validationFailure(animeEntry(progress: -1, total: 12)), "progress-range")
        XCTAssertEqual(TrackerLibraryPolicy.validationFailure(animeEntry(progress: 3, total: -1)), "total-range")
        var score = animeEntry(progress: 3, total: 12)
        score.score = .infinity
        XCTAssertEqual(TrackerLibraryPolicy.validationFailure(score), "score-range")
        XCTAssertEqual(TrackerLibraryDiagnostics.failure(TraktAuthenticationRequiredError()), "authentication-required")
        let terminal = TraktOAuthRefreshFailure(statusCode: 400, responseData: Data("{\"error\":\"invalid_grant\"}".utf8))
        XCTAssertEqual(TrackerLibraryDiagnostics.failure(terminal), "token-refresh:http:400 disposition=authentication-required")
        let retryable = TraktOAuthRefreshFailure(statusCode: 503, responseData: Data("private-account-token".utf8))
        XCTAssertEqual(TrackerLibraryDiagnostics.failure(retryable), "token-refresh:http:503 disposition=retryable")
        XCTAssertFalse(TrackerLibraryDiagnostics.failure(retryable).contains("private-account-token"))
    }

    @MainActor
    func testTotalsOnlyPaginationUsesCumulativeRawRowsAndRejectsTruncatedCompletion() async throws {
        for firstCount in [0, 2, 3] {
            let cache = TrackerLibraryCache()
            let key = key(section: .history)
            let headers = try response(["X-Pagination-Item-Count": "3"])
            var requests = 0
            do {
                let rows = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
                    requests += 1
                    let values = cursor == .page(1) ? (0..<firstCount).map { self.entry($0 + 1) } : []
                    return try TrackerLibraryPolicy.traktLibraryPage(response: headers, requested: requests,
                        entries: values, kind: .movie, section: .history)
                }, onUpdate: nil)
                XCTAssertEqual(firstCount, 3)
                XCTAssertEqual(rows.count, 3)
                XCTAssertEqual(cache.snapshot(for: key)?.isComplete, true)
            } catch {
                XCTAssertLessThan(firstCount, 3)
                XCTAssertTrue(error is TrackerLibraryError)
                XCTAssertNotEqual(cache.snapshot(for: key)?.isComplete, true)
            }
        }
    }

    @MainActor
    func testAdvertisedTotalSurvivesHeaderDisappearanceAndFinishesAtMaximumWithoutExtraRequest() async throws {
        let truncated = TrackerLibraryCache()
        let target = key(section: .history)
        do {
            _ = try await truncated.load(key: target, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
                TrackerLibraryPage(entries: cursor == .page(1) ? [self.entry(1)] : [],
                    next: cursor == .page(1) ? .page(2) : nil, expectedTotal: cursor == .page(1) ? 2 : nil)
            }, onUpdate: nil)
            XCTFail("A terminal response cannot discard the earlier advertised total")
        } catch { XCTAssertTrue(error is TrackerLibraryError) }
        XCTAssertNotEqual(truncated.snapshot(for: target)?.isComplete, true)

        let complete = TrackerLibraryCache()
        var requests = 0
        let rows = try await complete.load(key: target, forceRefresh: false, isAuthorized: { true }, fetchPage: { cursor in
            guard case .page(let page) = cursor else { throw TrackerLibraryError.invalidResponse }
            requests += 1
            let first = (page - 1) * TrackerLibraryPolicy.pageSize + 1
            return TrackerLibraryPage(entries: (first..<(first + TrackerLibraryPolicy.pageSize)).map { self.entry($0) },
                next: .page(page + 1), expectedTotal: TrackerLibraryPolicy.maximumEntries)
        }, onUpdate: nil)
        XCTAssertEqual(rows.count, TrackerLibraryPolicy.maximumEntries)
        XCTAssertEqual(requests, TrackerLibraryPolicy.maximumPageCount)
        XCTAssertEqual(complete.snapshot(for: target)?.isComplete, true)
        XCTAssertThrowsError(try TrackerLibraryPolicy.traktCompletionCursor(next: nil, receivedCount: 0, expectedTotal: 2))
        XCTAssertNil(try TrackerLibraryPolicy.traktCompletionCursor(next: .page(2), receivedCount: 2, expectedTotal: 2))
    }

    @MainActor
    func testOwnedShowsUseOneBoundedUnpaginatedResponse() async throws {
        let data = try JSONSerialization.data(withJSONObject: (1...1_500).map { id in
            ["show": ["title": "Show \(id)", "ids": ["trakt": id]]]
        })
        let entries = try TrackerTraktLibraryItem.decode(data, kind: .show, section: .collection)
        XCTAssertEqual(entries.count, 1_500)
        let page = try TrackerLibraryPolicy.traktLibraryPage(response: response([:]), requested: 1,
            entries: entries, kind: .show, section: .collection)
        XCTAssertNil(page.next)
        let cache = TrackerLibraryCache()
        let key = key(kind: .show, section: .collection)
        var requests = 0
        let rows = try await cache.load(key: key, forceRefresh: false, isAuthorized: { true }, fetchPage: { _ in
            requests += 1
            return page
        }, onUpdate: nil)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(rows.count, 1_500)
        XCTAssertEqual(cache.snapshot(for: key)?.isComplete, true)
        XCTAssertThrowsError(try TrackerTraktLibraryItem.decode(data, kind: .show, section: .watchlist))
        XCTAssertThrowsError(try TrackerTraktLibraryItem.decode(data, kind: .show, section: .history))
        XCTAssertThrowsError(try TrackerLibraryPolicy.traktLibraryPage(response: response([:]), requested: 2,
            entries: entries, kind: .show, section: .collection))
        XCTAssertThrowsError(try TrackerLibraryPolicy.traktLibraryPage(response: response(["X-Pagination-Page-Count": "2"]), requested: 1,
            entries: entries, kind: .show, section: .collection))
        XCTAssertThrowsError(try TrackerLibraryPolicy.traktLibraryPage(response: response(["X-Pagination-Item-Count": "1600"]), requested: 1,
            entries: entries, kind: .show, section: .collection))
    }

    func testUnpaginatedOwnedShowBoundsDoNotBecomeUnboundedImportAuthority() throws {
        let data = try JSONSerialization.data(withJSONObject: (1...(TrackerLibraryPolicy.maximumEntries + 1)).map { id in
            ["show": ["title": "Show", "ids": ["trakt": id]]]
        })
        XCTAssertLessThan(data.count, TrackerLibraryPolicy.maximumResponseBytes)
        XCTAssertThrowsError(try TrackerTraktLibraryItem.decode(data, kind: .show, section: .collection))
        XCTAssertThrowsError(try TrackerTraktLibraryItem.decode(Data(repeating: 0, count: TrackerLibraryPolicy.maximumResponseBytes + 1), kind: .show, section: .collection))
        XCTAssertTrue(TrackerLibraryPolicy.traktCollectionIsUnpaginated(kind: .show, section: .collection))
        XCTAssertFalse(TrackerLibraryPolicy.traktCollectionIsUnpaginated(kind: .movie, section: .collection))
        XCTAssertFalse(TrackerLibraryPolicy.traktCollectionIsUnpaginated(kind: .show, section: .customList(id: 9, name: "Owned")))
    }

    func testTraktMovieShowMetadataAndInvalidKinds() throws {
        let data = try traktData(kind: .movie)
        let movie = try XCTUnwrap(TrackerTraktLibraryItem.decode(data, kind: .movie, section: .watchlist).first)
        XCTAssertEqual(movie.tmdbID, 123)
        XCTAssertEqual(movie.imdbID, "tt1234567")
        XCTAssertEqual(movie.year, 2024)
        XCTAssertEqual(movie.format, "MOVIE")
        XCTAssertEqual(movie.averageScore, 82)
        XCTAssertTrue(movie.websiteURL?.absoluteString.contains("/movies/42") == true)
        let show = try XCTUnwrap(TrackerTraktLibraryItem.decode(traktData(kind: .show), kind: .show, section: .history).first)
        XCTAssertEqual(show.total, 24)
        XCTAssertEqual(show.format, "TV")
        XCTAssertThrowsError(try TrackerTraktLibraryItem.decode(data, kind: .show, section: .watchlist))
        XCTAssertThrowsError(try TrackerTraktLibraryItem.decode(data, kind: .anime, section: .watchlist))
        XCTAssertThrowsError(try TrackerTraktLibraryItem.decode(traktData(kind: .movie, mediaChanges: ["rating": 12]), kind: .movie, section: .watchlist))
    }

    func testTraktActionsUseExplicitIDsTypesAndSingleActionBodies() throws {
        let movie = entry(42)
        let rating = try TraktLibraryAction.rating(8).request(entry: movie)
        XCTAssertEqual(rating.url?.path, "/sync/ratings")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(rating.httpBody)) as? [String: [[String: Any]]])
        XCTAssertEqual(body["movies"]?.first?["rating"] as? Int, 8)
        XCTAssertEqual((body["movies"]?.first?["ids"] as? [String: Int])?["trakt"], 42)
        XCTAssertNil(body["shows"])
        XCTAssertEqual(try TraktLibraryAction.rating(nil).request(entry: movie).url?.path, "/sync/ratings/remove")
        XCTAssertEqual(try TraktLibraryAction.watchlist(false).request(entry: movie).url?.path, "/sync/watchlist/remove")
        XCTAssertEqual(try TraktLibraryAction.customList(id: 9, included: true).request(entry: movie).url?.path, "/users/me/lists/9/items")
        XCTAssertThrowsError(try TraktLibraryAction.rating(11).request(entry: movie))
        XCTAssertThrowsError(try TraktLibraryAction.customList(id: -1, included: true).request(entry: movie))
    }

    func testTraktMutationResponseCannotClaimSuccessForMissingMedia() throws {
        let success = try JSONSerialization.data(withJSONObject: ["added": ["movies": 1], "not_found": ["movies": []]])
        XCTAssertNoThrow(try TraktLibraryAction.validateResponse(success))
        let missing = try JSONSerialization.data(withJSONObject: ["added": ["movies": 0], "not_found": ["movies": [["ids": ["trakt": 42]]]]])
        XCTAssertThrowsError(try TraktLibraryAction.validateResponse(missing))
        XCTAssertThrowsError(try TraktLibraryAction.validateResponse(Data("{}".utf8)))
        XCTAssertThrowsError(try TraktLibraryAction.validateResponse(JSONSerialization.data(withJSONObject: ["added": ["movies": true]])))
        XCTAssertThrowsError(try TraktLibraryAction.validateResponse(JSONSerialization.data(withJSONObject: ["added": ["movies": 1], "not_found": ["movies": "unreadable"]])))
    }

    func testPersonalRatingDecoderRejectsFractionalMissingAndConflictingIDs() throws {
        let item: [String: Any] = ["rating": 8, "movie": ["ids": ["trakt": 42]]]
        XCTAssertEqual(try TrackerTraktLibraryRating.decode(JSONSerialization.data(withJSONObject: [item]), kind: .movie), [42: 8])
        XCTAssertEqual(try TrackerTraktLibraryRating.decode(Data("[]".utf8), kind: .movie), [:])
        XCTAssertThrowsError(try TrackerTraktLibraryRating.decode(JSONSerialization.data(withJSONObject: [item, item]), kind: .movie))
        XCTAssertThrowsError(try TrackerTraktLibraryRating.decode(JSONSerialization.data(withJSONObject: [["rating": 8.5, "movie": ["ids": ["trakt": 42]]]]), kind: .movie))
        XCTAssertThrowsError(try TrackerTraktLibraryRating.decode(JSONSerialization.data(withJSONObject: [item]), kind: .show))
        XCTAssertThrowsError(try TrackerTraktLibraryRating.decode(JSONSerialization.data(withJSONObject: [["movie": ["ids": ["trakt": 42]]]]), kind: .movie))
    }

    func testCustomListDecodingAndEndpointIdentityAreBounded() throws {
        let data = try JSONSerialization.data(withJSONObject: [["name": "Personal List", "ids": ["trakt": 9], "item_count": 1000]])
        XCTAssertEqual(try TrackerTraktLibraryList.decode(data).first, TrackerLibraryList(id: 9, name: "Personal List", itemCount: 1000))
        XCTAssertEqual(try TrackerLibraryPolicy.traktPath(kind: .show, section: .customList(id: 9, name: "ignored/path")), "users/me/lists/9/items/show")
        XCTAssertThrowsError(try TrackerLibraryPolicy.traktPath(kind: .manga, section: .watchlist))
        XCTAssertThrowsError(try TrackerTraktLibraryList.decode(JSONSerialization.data(withJSONObject: [["name": "Bad", "ids": ["trakt": -1]]])))
    }

    @MainActor
    func testRateLimitCooldownHonorsLongHeaderAndCancellation() async throws {
        let cooldown = TrackerLibraryCooldown()
        let now = Date()
        let rateLimit = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(URL(string: "https://api.trakt.tv/sync/watchlist/movies")),
            statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "300"]))
        XCTAssertEqual(cooldown.record(rateLimit, service: .trakt, now: now), 300)
        XCTAssertEqual(cooldown.remaining(service: .trakt, now: now.addingTimeInterval(120)), 180, accuracy: 0.001)
        XCTAssertThrowsError(try cooldown.requireReady(service: .trakt))
        let waiter = Task { @MainActor in try await cooldown.waitUntilReady(service: .trakt, isAuthorized: { true }) }
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("Cancelling must end the cooldown wait")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cooldown.remaining(service: .myAnimeList, now: now), 0)
    }

    @MainActor
    func testUnauthorizedCacheHitCannotExposeRows() async throws {
        let cache = TrackerLibraryCache()
        let key = key()
        let token = cache.begin(key)
        cache.store(TrackerLibrarySnapshot(entries: [entry(1)], isComplete: true, isStale: false, fetchedAt: Date()), key: key, token: token)
        var delivered = false
        do {
            _ = try await cache.load(key: key, forceRefresh: false, isAuthorized: { false }, fetchPage: { _ in
                XCTFail("An unauthorized profile must not fetch")
                return TrackerLibraryPage(entries: [], next: nil)
            }, onUpdate: { _ in delivered = true })
            XCTFail("Kids, unreadable roster or disconnected accounts must fail closed")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(delivered)
    }

    func testPreparedPlaybackRejectsEditsEvenWhenEpisodeAndSessionAreUnchanged() {
        let intent = playbackIntent()
        let generation = UUID()
        let snapshot = TrackerLibraryPlaybackSnapshot(target: .traktEpisode(season: 1, number: 12, tmdbID: 123), intent: intent, metadataGeneration: generation)
        XCTAssertTrue(snapshot.isCurrent(for: intent, metadataGeneration: generation))
        XCTAssertFalse(snapshot.isCurrent(for: intent, metadataGeneration: UUID()))
        XCTAssertFalse(snapshot.isCurrent(for: intent, metadataGeneration: nil))
        let reread = TrackerLibraryPlaybackSnapshot(target: snapshot.target, intent: intent, metadataGeneration: UUID())
        XCTAssertFalse(snapshot.isCurrent(for: reread.intent, metadataGeneration: reread.metadataGeneration))
        XCTAssertTrue(reread.isCurrent(for: intent, metadataGeneration: reread.metadataGeneration))
    }

    func testPreparedPlaybackRejectsRetainedViewsAfterOwnerOrAccountABASwitch() {
        let owner = UUID()
        let original = session(owner: owner)
        let intent = playbackIntent(session: original)
        let generation = UUID()
        let snapshot = TrackerLibraryPlaybackSnapshot(target: .traktEpisode(season: 1, number: 12, tmdbID: 123), intent: intent, metadataGeneration: generation)
        for changed in [session(), session(owner: owner, generation: 3), session(owner: owner, account: 3),
                        session(owner: owner, serviceGeneration: 3), session(owner: owner, user: "43")] {
            XCTAssertFalse(snapshot.isCurrent(for: playbackIntent(session: changed), metadataGeneration: generation))
        }
        let anotherTitle = TrackerLibraryPlaybackIntent(entry: entry(99), session: original)
        XCTAssertFalse(snapshot.isCurrent(for: anotherTitle, metadataGeneration: generation))
    }

    func testAnimeContinuationUsesNextEpisodeWithinTrackerTitle() throws {
        let value = animeEntry(progress: 11, total: 12)
        XCTAssertEqual(try TrackerLibraryPlaybackPolicy.animeTarget(value), .animeEpisode(12))
        XCTAssertEqual(try TrackerLibraryPlaybackPolicy.animeTarget(animeEntry(progress: 0, total: 12)), .animeEpisode(1))
        XCTAssertEqual(try TrackerLibraryPlaybackPolicy.animeTarget(animeEntry(progress: 11, total: nil)), .animeEpisode(12))
    }

    func testCompletedOrExhaustedTrackerTitleNeverWrapsOrCrossesSeasons() throws {
        XCTAssertEqual(try TrackerLibraryPlaybackPolicy.animeTarget(animeEntry(progress: 12, total: 12)), .caughtUp)
        XCTAssertEqual(try TrackerLibraryPlaybackPolicy.animeTarget(animeEntry(progress: 0, total: nil, status: .completed)), .caughtUp)
        XCTAssertEqual(try TrackerLibraryPlaybackPolicy.animeTarget(animeEntry(progress: 12, total: 12, status: .repeating)), .caughtUp)
        XCTAssertEqual(try TrackerLibraryPlaybackPolicy.animeTarget(animeEntry(progress: 3, total: 12, status: .repeating)), .animeEpisode(4))
    }

    func testPausedDroppedAndMALProgressRemainTrackerAuthoritative() throws {
        XCTAssertEqual(try TrackerLibraryPlaybackPolicy.animeTarget(animeEntry(progress: 8, total: 12, status: .paused)), .animeEpisode(9))
        XCTAssertEqual(try TrackerLibraryPlaybackPolicy.animeTarget(animeEntry(progress: 8, total: 12, status: .dropped, service: .myAnimeList)), .animeEpisode(9))
        XCTAssertThrowsError(try TrackerLibraryPlaybackPolicy.animeTarget(entry(1)))
        XCTAssertThrowsError(try TrackerLibraryPlaybackPolicy.animeTarget(animeEntry(progress: -1, total: 12)))
    }

    func testProviderSeasonMappingRejectsFlattenedAmbiguityAndUnrelatedIDs() {
        XCTAssertEqual(TrackerLibraryPlaybackPolicy.uniqueSeason(providerIDs: [1: 10, 2: 20], acceptedIDs: [20]), 2)
        XCTAssertEqual(TrackerLibraryPlaybackPolicy.uniqueSeason(providerIDs: [1: -10, 2: -20], acceptedIDs: [-20]), 2)
        XCTAssertNil(TrackerLibraryPlaybackPolicy.uniqueSeason(providerIDs: [1: 10, 2: 10], acceptedIDs: [10]))
        XCTAssertNil(TrackerLibraryPlaybackPolicy.uniqueSeason(providerIDs: [1: 10, 2: 20], acceptedIDs: [30]))
    }

    func testTraktContinuationUsesExactNextEpisodeInsteadOfCompletedCount() throws {
        let data = Data(#"{"aired":100,"completed":11,"next_episode":{"season":3,"number":4,"ids":{"tmdb":678}}}"#.utf8)
        XCTAssertEqual(try TrackerTraktPlaybackProgress.decode(data), .traktEpisode(season: 3, number: 4, tmdbID: 678))
        let empty = Data(#"{"aired":0,"completed":0,"next_episode":null}"#.utf8)
        XCTAssertEqual(try TrackerTraktPlaybackProgress.decode(empty), .caughtUp)
        let reset = Data(#"{"aired":100,"completed":100,"reset_at":"2026-09-15T12:00:00Z","next_episode":{"season":1,"number":2}}"#.utf8)
        XCTAssertEqual(try TrackerTraktPlaybackProgress.decode(reset), .traktEpisode(season: 1, number: 2, tmdbID: nil))
    }

    func testTraktContinuationRejectsMissingMalformedOrSpecialCoordinates() {
        for value in [
            #"{"aired":100,"completed":11}"#,
            #"{"aired":100,"completed":11,"next_episode":{"season":0,"number":1}}"#,
            #"{"aired":100,"completed":11,"next_episode":{"season":1,"number":0}}"#,
            #"{"aired":100,"completed":11,"next_episode":{"season":1,"number":1.5}}"#,
            #"{"aired":100,"completed":true,"next_episode":null}"#,
            #"{"aired":100,"completed":11,"next_episode":{"season":1,"number":2,"ids":{"tmdb":-1}}}"#
        ] { XCTAssertThrowsError(try TrackerTraktPlaybackProgress.decode(Data(value.utf8))) }
    }

    func testFutureEpisodeDatesDoNotLaunchBeforeAiring() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z"))
        XCTAssertTrue(TrackerLibraryPlaybackPolicy.isKnownFutureDate("2026-09-16", now: now))
        XCTAssertFalse(TrackerLibraryPlaybackPolicy.isKnownFutureDate("2026-09-15", now: now))
        XCTAssertFalse(TrackerLibraryPlaybackPolicy.isKnownFutureDate("2026-09-14T12:00:00Z", now: now))
        XCTAssertFalse(TrackerLibraryPlaybackPolicy.isKnownFutureDate("2026-02-30", now: now))
        XCTAssertFalse(TrackerLibraryPlaybackPolicy.isKnownFutureDate(nil, now: now))
    }

    private func playbackIntent(session: TrackerLibrarySession? = nil) -> TrackerLibraryPlaybackIntent {
        let entry = TrackerLibraryEntry(service: .trakt, kind: .show, mediaID: 42, entryID: nil, aniListID: nil, malID: nil,
            title: "Show", alternateTitles: [], coverLarge: nil, coverMedium: nil, total: 24, genres: [],
            averageScore: nil, status: .current, progress: 11, score: 0, updatedAt: nil, tmdbID: 42)
        return TrackerLibraryPlaybackIntent(entry: entry, session: session ?? self.session())
    }

    private func animeEntry(progress: Int, total: Int?, status: TrackerLibraryStatus = .current, service: TrackerService = .anilist) -> TrackerLibraryEntry {
        TrackerLibraryEntry(service: service, kind: .anime, mediaID: 42, entryID: nil, aniListID: service == .anilist ? 42 : nil, malID: 24,
            title: "Anime", alternateTitles: [], coverLarge: nil, coverMedium: nil, total: total, genres: [],
            averageScore: nil, status: status, progress: progress, score: 0, updatedAt: nil)
    }

    private func session(owner: UUID = UUID(), generation: UInt64 = 1, account: UInt64 = 1, serviceGeneration: UInt64 = 1, user: String = "42") -> TrackerLibrarySession {
        TrackerLibrarySession(owner: owner, operationGeneration: generation, accountGeneration: account,
            serviceGeneration: serviceGeneration, service: .trakt, userID: user)
    }
    private func key(session: TrackerLibrarySession? = nil, kind: TrackerLibraryKind = .movie, section: TrackerLibrarySection = .watchlist) -> TrackerLibraryCacheKey {
        TrackerLibraryCacheKey(session: session ?? self.session(), kind: kind, status: nil, section: section)
    }
    private func entry(_ id: Int) -> TrackerLibraryEntry {
        TrackerLibraryEntry(service: .trakt, kind: .movie, mediaID: id, entryID: nil, aniListID: nil, malID: nil,
            title: "Movie \(id)", alternateTitles: [], coverLarge: nil, coverMedium: nil, total: nil, genres: [],
            averageScore: nil, status: .planning, progress: 0, score: 0, updatedAt: nil, tmdbID: id)
    }
    private func response(_ headers: [String: String]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(URL(string: "https://api.trakt.tv/sync/watchlist/movies")), statusCode: 200, httpVersion: nil, headerFields: headers))
    }
    private func traktData(kind: TrackerLibraryKind, mediaChanges: [String: Any] = [:]) throws -> Data {
        var media: [String: Any] = ["title": "Example", "year": 2024, "ids": ["trakt": 42, "tmdb": 123, "imdb": "tt1234567"], "rating": 8.2, "aired_episodes": 24]
        media.merge(mediaChanges) { _, updated in updated }
        return try JSONSerialization.data(withJSONObject: [["type": kind == .movie ? "movie" : "show", kind == .movie ? "movie" : "show": media, "listed_at": "2026-09-15T12:00:00.000Z"]])
    }
}

@MainActor
private final class TrackerLibraryTestSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func fire() {
        fired = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class TrackerLibraryTestPageGate {
    let started = TrackerLibraryTestSignal()
    let cancellation = TrackerLibraryTestSignal()
    private(set) var cancelled = false
    private let ignoresCancellation: Bool
    private var pending: CheckedContinuation<TrackerLibraryPage, Error>?

    init(ignoresCancellation: Bool = false) { self.ignoresCancellation = ignoresCancellation }

    func fetch() async throws -> TrackerLibraryPage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                pending = $0
                started.fire()
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelled = true
                self.cancellation.fire()
                if !self.ignoresCancellation {
                    let pending = self.pending
                    self.pending = nil
                    pending?.resume(throwing: CancellationError())
                }
            }
        }
    }

    func release(_ page: TrackerLibraryPage) {
        let pending = self.pending
        self.pending = nil
        pending?.resume(returning: page)
    }
}

private struct TrackerLibraryDiagnosticsTestKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        self.intValue = intValue
        stringValue = String(intValue)
    }
}

final class TrackerLibraryCanonicalPlaybackTests: XCTestCase {
    func testEveryCanonicalSaikiShortResolvesToItsPhysicalCompilationForBothTrackers() {
        let rows = compilations()
        for service in [TrackerService.anilist, .myAnimeList] {
            var selectedCounts: [Int: Int] = [:]
            for number in 1...120 {
                let physical = (number + 4) / 5
                XCTAssertEqual(resolve(number, service: service, rows: rows), .episode(physical), "\(service) short \(number)")
                XCTAssertEqual(resolve(number, service: service, rows: Array(rows.reversed())), .episode(physical))
                selectedCounts[physical, default: 0] += 1
            }
            XCTAssertEqual(selectedCounts.count, 24)
            XCTAssertTrue(selectedCounts.values.allSatisfy { $0 == 5 })
            XCTAssertEqual(resolve(119, service: service, rows: rows), .episode(24))
            XCTAssertEqual(resolve(120, service: service, rows: rows), .episode(24))
            XCTAssertEqual(resolve(121, service: service, rows: rows), .caughtUp)
            for invalid in [0, -1, Int.min, Int.max, 122] {
                XCTAssertEqual(resolve(invalid, service: service, rows: rows), .unavailable)
            }
            for next in [1, 119, 120, 121] {
                XCTAssertEqual(resolve(next, service: service, rows: Array(rows.dropLast())), .unavailable)
            }
        }
    }

    func testProviderEpisodeUnitsDistinguishFourPartsFromOneWholeFeature() {
        let parts = featureParts()
        XCTAssertEqual(resolve(1, service: .anilist, show: 93_816, aniListID: 170_935, malID: 57_184, rows: parts), .episode(1))
        XCTAssertEqual(resolve(1, service: .anilist, show: 93_816, aniListID: 170_935, malID: 57_184,
            rows: Array(parts.reversed())), .episode(1))
        XCTAssertEqual(resolve(2, service: .anilist, show: 93_816, aniListID: 170_935, malID: 57_184, rows: parts), .caughtUp)
        XCTAssertEqual(resolve(3, service: .anilist, show: 93_816, aniListID: 170_935, malID: 57_184, rows: parts), .unavailable)
        for number in 1...4 {
            XCTAssertEqual(resolve(number, service: .myAnimeList, show: 93_816, aniListID: nil,
                malID: 57_184, rows: parts), .episode(number))
            XCTAssertEqual(resolve(number, service: .myAnimeList, show: 93_816, aniListID: 170_935,
                malID: 57_184, rows: [feature()]), .episode(1))
        }
        XCTAssertEqual(resolve(5, service: .myAnimeList, show: 93_816, aniListID: nil,
            malID: 57_184, rows: parts), .caughtUp)
        XCTAssertEqual(resolve(6, service: .myAnimeList, show: 93_816, aniListID: nil,
            malID: 57_184, rows: parts), .unavailable)
        XCTAssertEqual(resolve(1, service: .anilist, show: 93_816, aniListID: 170_935,
            malID: 57_184, rows: [feature()]), .episode(1))
        XCTAssertEqual(resolve(2, service: .anilist, show: 93_816, aniListID: 170_935,
            malID: 57_184, rows: [feature()]), .caughtUp)
        XCTAssertEqual(resolve(5, service: .myAnimeList, show: 93_816, aniListID: 170_935,
            malID: 57_184, rows: [feature()]), .caughtUp)
    }

    func testMalformedCompilationInventoryCannotSelectOrDeclareCaughtUp() {
        let complete = compilations()
        let expected = complete[1].unitProjection
        var duplicated = complete
        duplicated[1] = row(1, physicalSeason: 1, physicalEpisode: 1, projection: complete[0].unitProjection)
        var gap = complete
        gap[1] = row(25, physicalSeason: 1, physicalEpisode: 2, projection: expected)
        var missingProjection = complete
        missingProjection[1] = row(2, physicalSeason: 1, physicalEpisode: 2)
        var unknownProjection = complete
        unknownProjection[1] = row(2, physicalSeason: 1, physicalEpisode: 2,
            projection: .init(edition: .unverified, canonicalAniListEpisodeRange: nil, canonicalMALEpisodeRange: nil))
        var wrongRange = complete
        wrongRange[1] = row(2, physicalSeason: 1, physicalEpisode: 2, projection: complete[0].unitProjection)
        var wrongCoordinates = complete
        wrongCoordinates[1] = row(2, physicalSeason: 2, physicalEpisode: 2, projection: expected)
        var duplicateCoordinates = complete
        duplicateCoordinates[1] = row(2, physicalSeason: 1, physicalEpisode: 1, projection: expected)
        var mixedSeasons = complete
        mixedSeasons[1] = row(2, season: 2, physicalSeason: 1, physicalEpisode: 2, projection: expected)
        for rows in [duplicated, gap, missingProjection, unknownProjection, wrongRange,
            wrongCoordinates, duplicateCoordinates, mixedSeasons] {
            for service in [TrackerService.anilist, .myAnimeList] {
                for next in [1, 6, 120, 121] {
                    XCTAssertEqual(resolve(next, service: service, rows: rows), .unavailable)
                }
            }
        }
    }

    func testProjectedPlaybackRejectsForeignIdentityAndUnverifiedLegacyRows() {
        let rows = compilations()
        for identity in [(show: 67_677, aniList: 21_804, mal: 33_255),
            (show: 67_676, aniList: 21_805, mal: 33_255), (show: 67_676, aniList: 21_804, mal: 33_256)] {
            for service in [TrackerService.anilist, .myAnimeList] {
                XCTAssertEqual(resolve(6, service: service, show: identity.show,
                    aniListID: identity.aniList, malID: identity.mal, rows: rows), .unavailable)
            }
        }
        XCTAssertEqual(resolve(6, service: .myAnimeList, aniListID: nil, rows: rows), .episode(2))
        XCTAssertEqual(resolve(6, service: .trakt, rows: rows), .unavailable)
        XCTAssertEqual(resolve(6, service: .simkl, rows: rows), .unavailable)
        let legacy = (1...120).map { row($0, physicalSeason: 1, physicalEpisode: $0) }
        for service in [TrackerService.anilist, .myAnimeList] {
            XCTAssertEqual(resolve(6, service: service, rows: legacy), .unavailable)
            XCTAssertEqual(resolve(1, service: service, show: 93_816, aniListID: 170_935,
                malID: 57_184, rows: [row(1)]), .unavailable)
        }
    }

    func testFeatureInventoryRequiresActualEditionAndPhysicalPointers() {
        let film = feature()
        let invalidFilm = row(1, physicalSeason: 2, physicalEpisode: 1, projection: film.unitProjection)
        let wrongMovie = row(1, projection: .init(edition: .feature,
            canonicalAniListEpisodeRange: .init(lowerBound: 1, upperBound: 1),
            canonicalMALEpisodeRange: .init(lowerBound: 1, upperBound: 4), tmdbMovieID: 1_220_442))
        let parts = featureParts()
        var mixed = parts
        mixed[0] = film
        var wrongPart = parts
        wrongPart[3] = row(4, season: 2, physicalSeason: 2, physicalEpisode: 3,
            projection: parts[3].unitProjection)
        for inventory in [[invalidFilm], [wrongMovie], [film, film], Array(parts.dropLast()), mixed, wrongPart] {
            for service in [TrackerService.anilist, .myAnimeList] {
                XCTAssertEqual(resolve(1, service: service, show: 93_816, aniListID: 170_935,
                    malID: 57_184, rows: inventory), .unavailable)
                XCTAssertEqual(resolve(service == .anilist ? 2 : 5, service: service, show: 93_816,
                    aniListID: 170_935, malID: 57_184, rows: inventory), .unavailable)
            }
        }
        XCTAssertEqual(resolve(1, service: .anilist, show: 93_817, aniListID: 170_935,
            malID: 57_184, rows: [film]), .unavailable)
        XCTAssertEqual(resolve(1, service: .anilist, show: 93_816, aniListID: 170_936,
            malID: 57_184, rows: [film]), .unavailable)
    }

    func testExtraneousProjectionFieldsCannotResumeOrCarryTrustedPlaybackContext() throws {
        let cases: [(episode: AniListEpisode, fields: [String: Int], show: Int, aniList: Int, mal: Int)] = [
            (compilations()[0], ["tmdbMovieID": 1_220_441], 67_676, 21_804, 33_255),
            (compilations()[0], ["physicalPartOrdinal": 1, "physicalPartCount": 4], 67_676, 21_804, 33_255),
            (feature(), ["physicalPartOrdinal": 1, "physicalPartCount": 4], 93_816, 170_935, 57_184),
            (featureParts()[0], ["tmdbMovieID": 1_220_441], 93_816, 170_935, 57_184)
        ]
        for value in cases {
            let projection = try XCTUnwrap(value.episode.unitProjection)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any])
            for (key, number) in value.fields { object[key] = number }
            let corrupted = try JSONDecoder().decode(AnimeEpisodeUnitProjection.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(corrupted.edition, .unverified)
            let episode = row(1, season: value.episode.seasonNumber,
                physicalSeason: value.episode.tmdbSeasonNumber, physicalEpisode: value.episode.tmdbEpisodeNumber,
                projection: corrupted)
            XCTAssertEqual(resolve(1, service: .anilist, show: value.show, aniListID: value.aniList,
                malID: value.mal, rows: [episode]), .unavailable)
            let context = EpisodePlaybackContext(localSeasonNumber: episode.seasonNumber, localEpisodeNumber: 1,
                anilistMediaId: value.aniList, canonicalAniListMediaId: value.aniList, malMediaId: value.mal,
                tmdbSeasonNumber: episode.tmdbSeasonNumber, tmdbEpisodeNumber: episode.tmdbEpisodeNumber,
                tmdbEpisodeOffset: nil, animeAbsoluteEpisodeNumber: nil, animeSeasonEpisodeCount: 1,
                isSpecial: false, titleOnlySearch: false, unitProjection: corrupted)
            XCTAssertFalse(context.hasTrustedUnitProjection(showID: value.show))
        }
    }

    func testOrdinaryEpisodeIdentityAndAiringRulesRemainUnchanged() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z"))
        for service in [TrackerService.anilist, .myAnimeList] {
            for date in ["2026-10-12", "2026-10-13", "2026-02-30", nil] {
                XCTAssertEqual(resolve(2, service: service, show: 42, aniListID: 43, malID: 44,
                    rows: [row(2, physicalSeason: 3, physicalEpisode: 12, date: date)], now: now), .episode(2))
            }
            XCTAssertEqual(resolve(2, service: service, show: 42, aniListID: 43, malID: 44,
                rows: [row(2, date: "2026-10-14")], now: now), .unaired)
            XCTAssertEqual(resolve(3, service: service, show: 42, aniListID: 43, malID: 44,
                rows: [row(2)], now: now), .unavailable)
            XCTAssertEqual(resolve(2, service: service, show: 42, aniListID: 43, malID: 44,
                rows: [row(2), row(2)], now: now), .unavailable)
        }
        var future = compilations()
        future[23] = row(24, physicalSeason: 1, physicalEpisode: 24,
            projection: future[23].unitProjection, date: "2026-10-14")
        XCTAssertEqual(resolve(119, service: .anilist, rows: future, now: now), .unaired)
        XCTAssertEqual(resolve(120, service: .myAnimeList, rows: future, now: now), .unaired)
        XCTAssertEqual(resolve(121, service: .anilist, rows: future, now: now), .caughtUp)
    }

    func testFreshTrackerSnapshotRetainsNewProgressWithoutLosingMetadataAuthority() throws {
        let original = entry(progress: 5, total: nil)
        var fresh = entry(progress: 119, total: 120)
        fresh.status = .paused
        fresh.score = 80
        fresh.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(fresh.hasSameResolutionMetadata(as: original))
        XCTAssertTrue(original.hasSameResolutionMetadata(as: fresh))
        XCTAssertEqual(try TrackerLibraryPlaybackPolicy.animeTarget(original), .animeEpisode(6))
        XCTAssertEqual(try TrackerLibraryPlaybackPolicy.animeTarget(fresh), .animeEpisode(120))
        let session = TrackerLibrarySession(owner: UUID(), operationGeneration: 1, accountGeneration: 1,
            serviceGeneration: 1, service: .anilist, userID: "isolated-test")
        let intent = TrackerLibraryPlaybackIntent(entry: original, session: session)
        let generation = UUID()
        let snapshot = TrackerLibraryPlaybackSnapshot(target: try TrackerLibraryPlaybackPolicy.animeTarget(fresh),
            intent: intent, metadataGeneration: generation, currentEntry: fresh)
        XCTAssertEqual(snapshot.currentEntry, fresh)
        XCTAssertNotEqual(snapshot.currentEntry, intent.entry)
        XCTAssertTrue(snapshot.isCurrent(for: intent, metadataGeneration: generation))
        XCTAssertFalse(snapshot.isCurrent(for: intent, metadataGeneration: UUID()))
        XCTAssertNil(TrackerLibraryPlaybackSnapshot(target: .animeEpisode(6), intent: intent,
            metadataGeneration: generation).currentEntry)
        fresh.status = .completed
        XCTAssertTrue(fresh.hasSameResolutionMetadata(as: original))
        XCTAssertEqual(try TrackerLibraryPlaybackPolicy.animeTarget(fresh), .caughtUp)
    }

    func testTrackerMetadataChangesInvalidatePreparedEpisodeAuthority() {
        let original = entry()
        for changed in [entry(aniListID: 21_805), entry(malID: 33_256), entry(title: "Different Anime"),
            entry(format: "ONA"), entry(year: 2017), entry(tmdbID: 67_677), entry(imdbID: "tt1234567")] {
            XCTAssertFalse(changed.hasSameResolutionMetadata(as: original))
            XCTAssertFalse(original.hasSameResolutionMetadata(as: changed))
        }
    }

    func testVerifiedTrackerFeatureUsesTheActualMovieBodyForBothProviders() throws {
        let movie = featureMovie()
        for service in [TrackerService.anilist, .myAnimeList] {
            let value = entry(service: service, aniListID: 170_935, malID: 57_184,
                title: "Great Pretender razbliuto", progress: service == .anilist ? 0 : 2,
                total: service == .anilist ? 1 : 4, format: "ONA", year: 2024, tmdbID: 93_816)
            let episode = try XCTUnwrap(TrackerLibraryPlaybackPolicy.verifiedAnimeFeatureEpisode(
                entry: value, movie: movie, displaySeasonNumber: 2))
            XCTAssertEqual(episode.title, movie.title)
            XCTAssertEqual(episode.description, movie.overview)
            XCTAssertEqual(episode.stillPath, movie.backdropPath)
            XCTAssertEqual(episode.runtime, 89)
            XCTAssertEqual(episode.airDate, "2024-01-09")
            XCTAssertEqual(episode.seasonNumber, 2)
            XCTAssertNil(episode.tmdbSeasonNumber)
            XCTAssertNil(episode.tmdbEpisodeNumber)
            XCTAssertEqual(episode.unitProjection?.tmdbMovieID, 1_220_441)
            XCTAssertEqual(episode.unitProjection?.canonicalMALEpisodeRange, .init(lowerBound: 1, upperBound: 4))
            XCTAssertEqual(resolve(service == .anilist ? 1 : 3, service: service, show: 93_816,
                aniListID: 170_935, malID: 57_184, rows: [episode]), .episode(1))
            for wrong in [featureMovie(id: 1_220_442), featureMovie(imdb: "tt30827041"),
                featureMovie(originalTitle: "Different Feature"), featureMovie(runtime: 22),
                featureMovie(releaseDate: "2024-02-23")] {
                XCTAssertNil(TrackerLibraryPlaybackPolicy.verifiedAnimeFeatureEpisode(entry: value, movie: wrong))
            }
            XCTAssertNotNil(TrackerLibraryPlaybackPolicy.verifiedAnimeFeatureEpisode(
                entry: entry(service: service, aniListID: 170_935, malID: 57_184, progress: 0,
                    total: nil, format: "ONA", year: 2024, tmdbID: 93_816), movie: movie))
        }
        let malOnly = entry(service: .myAnimeList, aniListID: nil, malID: 57_184,
            title: "Great Pretender razbliuto", progress: 2, total: 4, format: "ONA", year: 2024, tmdbID: 93_816)
        let malEpisode = try XCTUnwrap(TrackerLibraryPlaybackPolicy.verifiedAnimeFeatureEpisode(
            entry: malOnly, movie: movie, displaySeasonNumber: 2))
        XCTAssertEqual(malEpisode.unitProjection?.tmdbMovieID, 1_220_441)
        XCTAssertEqual(resolve(3, service: .myAnimeList, show: 93_816, aniListID: 170_935,
            malID: 57_184, rows: [malEpisode]), .episode(1))
        XCTAssertEqual(resolve(3, service: .myAnimeList, show: 93_816, aniListID: nil,
            malID: 57_184, rows: [malEpisode]), .unavailable)
        for invalid in [entry(service: .anilist, aniListID: nil, malID: 57_184, mediaID: 170_935,
                progress: 0, total: 1, format: "ONA"),
            entry(service: .myAnimeList, aniListID: 170_935, malID: nil, mediaID: 57_184,
                progress: 0, total: 4, format: "ONA"),
            entry(service: .myAnimeList, aniListID: 170_936, malID: 57_184, progress: 0, total: 4, format: "ONA"),
            entry(aniListID: 170_935, malID: 57_185, progress: 0, total: 1, format: "ONA"),
            entry(aniListID: 170_935, malID: 57_184, progress: 0, total: 4, format: "ONA"),
            entry(service: .myAnimeList, aniListID: nil, malID: 57_184, progress: 0, total: 1, format: "ONA")] {
            XCTAssertNil(TrackerLibraryPlaybackPolicy.verifiedAnimeFeatureEpisode(entry: invalid, movie: movie))
        }
        XCTAssertNil(TrackerLibraryPlaybackPolicy.verifiedAnimeFeatureEpisode(entry: entry(), movie: movie))
    }

    private func resolve(
        _ next: Int, service: TrackerService, show: Int = 67_676, aniListID: Int? = 21_804,
        malID: Int? = 33_255, rows: [AniListEpisode], now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> TrackerLibraryPlaybackPolicy.AnimeEpisodeResolution {
        TrackerLibraryPlaybackPolicy.resolveAnimeEpisode(nextCanonicalNumber: next, service: service,
            tmdbShowID: show, aniListID: aniListID, malID: malID, episodes: rows, now: now)
    }

    private func compilations() -> [AniListEpisode] {
        (1...24).map { number in
            let range = AnimeCanonicalEpisodeRange(lowerBound: (number - 1) * 5 + 1, upperBound: number * 5)
            return row(number, physicalSeason: 1, physicalEpisode: number,
                projection: .init(edition: .compilation, canonicalAniListEpisodeRange: range, canonicalMALEpisodeRange: range))
        }
    }

    private func feature() -> AniListEpisode {
        row(1, season: 2, projection: .init(edition: .feature,
            canonicalAniListEpisodeRange: .init(lowerBound: 1, upperBound: 1),
            canonicalMALEpisodeRange: .init(lowerBound: 1, upperBound: 4), tmdbMovieID: 1_220_441))
    }

    private func featureParts() -> [AniListEpisode] {
        (1...4).map { number in
            row(number, season: 2, physicalSeason: 2, physicalEpisode: number,
                projection: .init(edition: .featurePart,
                    canonicalAniListEpisodeRange: .init(lowerBound: 1, upperBound: 1),
                    canonicalMALEpisodeRange: .init(lowerBound: number, upperBound: number),
                    physicalPartOrdinal: number, physicalPartCount: 4))
        }
    }

    private func row(
        _ number: Int, season: Int = 1, physicalSeason: Int? = nil, physicalEpisode: Int? = nil,
        projection: AnimeEpisodeUnitProjection? = nil, date: String? = "2016-07-11"
    ) -> AniListEpisode {
        .init(number: number, title: "Physical episode \(number)", description: "Independent body \(number)",
            seasonNumber: season, stillPath: "/still-\(number).jpg", airDate: date, runtime: 23,
            tmdbSeasonNumber: physicalSeason, tmdbEpisodeNumber: physicalEpisode, unitProjection: projection)
    }

    private func entry(
        service: TrackerService = .anilist, aniListID: Int? = 21_804, malID: Int? = 33_255, mediaID: Int? = nil,
        title: String = "Saiki", progress: Int = 5, total: Int? = 120,
        format: String = "TV", year: Int = 2016, tmdbID: Int = 67_676, imdbID: String? = nil
    ) -> TrackerLibraryEntry {
        .init(service: service, kind: .anime, mediaID: mediaID ?? (service == .myAnimeList ? malID : aniListID) ?? 0,
            entryID: nil, aniListID: aniListID, malID: malID, title: title, alternateTitles: [],
            coverLarge: nil, coverMedium: nil, total: total, genres: [], averageScore: nil,
            status: .current, progress: progress, score: 0, updatedAt: nil, tmdbID: tmdbID,
            format: format, year: year, imdbID: imdbID)
    }

    private func featureMovie(
        id: Int = 1_220_441, imdb: String = "tt30827040", originalTitle: String = "GREAT PRETENDER razbliuto",
        runtime: Int = 89, releaseDate: String = "2024-01-09"
    ) -> TMDBMovieDetail {
        .init(id: id, title: "Localized verified feature", overview: "Actual movie overview", posterPath: "/poster.jpg",
            backdropPath: "/feature.jpg", releaseDate: releaseDate, voteAverage: 7, popularity: 1,
            runtime: runtime, genres: [.init(id: 16, name: "Animation")], tagline: nil, status: "Released",
            budget: nil, revenue: nil, imdbId: imdb, originalLanguage: "ja", originalTitle: originalTitle,
            adult: false, voteCount: 10, releaseDates: nil)
    }
}
