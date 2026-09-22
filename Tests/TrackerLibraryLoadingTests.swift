import Foundation
import XCTest
#if os(macOS)
@testable import EclipseMac
#else
@testable import Eclipse
#endif

final class TrackerLibraryLoadingTests: XCTestCase {
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
