import Foundation
import XCTest
#if os(macOS)
@testable import EclipseMac
#else
@testable import Eclipse
#endif

final class TrackerLibraryTests: XCTestCase {
    func testImportFeedbackRejectsReplacedRunsAndRevokedScopes() throws {
        let scope = TrackerImportScope(owner: UUID(), accountGeneration: 1, serviceGeneration: 1, userID: "first")
        let run = TrackerImportState(id: UUID(), scope: scope, phase: .running("Fetching"))
        let phase = TrackerImportState.Phase.finished(TrackerImportSummary(entriesChecked: 12, collectionAdditions: 3, progressEntries: 8, hasSkippedItems: false))
        XCTAssertNil(run.updating(phase, runID: UUID(), scope: scope))
        for revoked in [
            TrackerImportScope(owner: UUID(), accountGeneration: 1, serviceGeneration: 1, userID: "first"),
            TrackerImportScope(owner: scope.owner, accountGeneration: 2, serviceGeneration: 1, userID: "first"),
            TrackerImportScope(owner: scope.owner, accountGeneration: 1, serviceGeneration: 2, userID: "first"),
            TrackerImportScope(owner: scope.owner, accountGeneration: 1, serviceGeneration: 1, userID: "second"),
            TrackerImportScope(owner: scope.owner, accountGeneration: 1, serviceGeneration: 1, userID: nil)
        ] {
            XCTAssertNil(run.updating(phase, runID: run.id, scope: revoked))
        }
        let finished = try XCTUnwrap(run.updating(phase, runID: run.id, scope: scope))
        XCTAssertFalse(finished.isImporting)
        XCTAssertEqual(finished.title, "Import Complete")
        XCTAssertNil(finished.updating(.running("Late phase"), runID: run.id, scope: scope))
        XCTAssertNil(finished.updating(.failed("Late error"), runID: run.id, scope: scope))
    }

    func testImportFeedbackDistinguishesEmptyRepeatedPartialAndFailedResults() throws {
        let scope = TrackerImportScope(owner: UUID(), accountGeneration: 1, serviceGeneration: 1, userID: "first")
        let run = TrackerImportState(id: UUID(), scope: scope, phase: .running("Matching titles"))
        XCTAssertTrue(run.isImporting)
        XCTAssertEqual(run.message, "Matching titles")
        let empty = TrackerImportSummary(entriesChecked: 0, collectionAdditions: 0, progressEntries: 0, hasSkippedItems: false)
        XCTAssertEqual(empty.message, "No entries were found in the imported lists.")
        let repeated = TrackerImportSummary(entriesChecked: 12, collectionAdditions: 0, progressEntries: 12, hasSkippedItems: false)
        XCTAssertTrue(repeated.message.contains("0 collection additions"))
        XCTAssertTrue(repeated.message.contains("12 progress entries processed"))
        let partial = try XCTUnwrap(run.updating(.finished(TrackerImportSummary(entriesChecked: 12, collectionAdditions: 3, progressEntries: 8, hasSkippedItems: true)), runID: run.id, scope: scope))
        XCTAssertTrue(partial.needsAttention)
        XCTAssertFalse(partial.isImporting)
        XCTAssertEqual(partial.title, "Import Finished with Skipped Items")
        let failed = try XCTUnwrap(run.updating(.failed("Earlier saved items remain in your library."), runID: run.id, scope: scope))
        XCTAssertTrue(failed.needsAttention)
        XCTAssertFalse(failed.isImporting)
        XCTAssertEqual(failed.title, "Import Could Not Finish")
        XCTAssertEqual(failed.message, "Earlier saved items remain in your library.")
    }


    func testMovieAndNovelMetadataSurviveProviderNormalization() throws {
        let movie = try TrackerAniListLibraryPage.decode(aniListData(mediaChanges: ["format": "MOVIE", "startDate": ["year": 2024]]), kind: .anime).entries.first
        XCTAssertEqual(movie?.format, "MOVIE")
        XCTAssertEqual(movie?.year, 2024)
        let novel = try TrackerMALLibraryPage.decode(malData(kind: .manga, nodeChanges: ["media_type": "light_novel", "start_date": "2020-05-12"]), kind: .manga).entries.first
        XCTAssertEqual(novel?.format, "LIGHT_NOVEL")
        XCTAssertEqual(novel?.year, 2020)
        let unknown = try TrackerMALLibraryPage.decode(malData(nodeChanges: ["media_type": "unrecognized", "start_date": "not-a-date"]), kind: .anime).entries.first
        XCTAssertNil(unknown?.format)
        XCTAssertNil(unknown?.year)
    }

    func testCollectionTargetsUseProviderIdentitiesWithoutTreatingLocalIDsAsTrackerIDs() {
        let source = TrackerCollectionTarget(title: "Novel", kind: .manga, aniListID: -55, malID: 99)
        XCTAssertNil(source.aniListID)
        XCTAssertEqual(source.malID, 99)
        XCTAssertTrue(source.hasExactIdentity(for: .anilist))
        XCTAssertFalse(source.supports(.trakt))
        let film = TrackerCollectionTarget(title: "Film", kind: .movie, aniListID: 100, malID: 200, tmdbID: 300)
        XCTAssertEqual(film.kind(for: .anilist), .anime)
        XCTAssertEqual(film.kind(for: .myAnimeList), .anime)
        XCTAssertEqual(film.kind(for: .trakt), .movie)
        XCTAssertEqual(film.aniListID, 100)
        XCTAssertEqual(film.malID, 200)
    }

    func testCollectionCandidateRejectsContradictoryMALMediaKind() throws {
        let object = try JSONSerialization.jsonObject(with: malData(kind: .anime, nodeChanges: ["media_type": "manga"])) as? [String: Any]
        let rows = try XCTUnwrap(object?["data"] as? [[String: Any]])
        let bytes = try JSONSerialization.data(withJSONObject: XCTUnwrap(rows.first?["node"]))
        let node = try JSONDecoder().decode(TrackerMALLibraryPage.Node.self, from: bytes)
        XCTAssertThrowsError(try node.collectionCandidate(kind: .anime))
        XCTAssertNoThrow(try node.collectionCandidate(kind: .manga))
    }

    func testCollectionAniListAbsenceRequiresExplicitMembershipField() throws {
        let page = try JSONSerialization.jsonObject(with: aniListData()) as? [String: Any]
        let data = page?["data"] as? [String: Any]
        let collection = data?["MediaListCollection"] as? [String: Any]
        let lists = collection?["lists"] as? [[String: Any]]
        let entries = lists?.first?["entries"] as? [[String: Any]]
        var media = try XCTUnwrap(entries?.first?["media"] as? [String: Any])
        func decode(_ value: [String: Any]) throws -> TrackerCollectionAniListResponse.Item {
            let bytes = try JSONSerialization.data(withJSONObject: ["data": ["Media": value]])
            return try XCTUnwrap(JSONDecoder().decode(TrackerCollectionAniListResponse.self, from: bytes).validatedItems().first)
        }
        XCTAssertFalse(try decode(media).membershipWasReturned)
        media["mediaListEntry"] = NSNull()
        let absent = try decode(media)
        XCTAssertTrue(absent.membershipWasReturned)
        XCTAssertNil(absent.mediaListEntry)
        media["mediaListEntry"] = entries?.first
        XCTAssertNotNil(try decode(media).mediaListEntry)
    }

    @MainActor
    func testCollectionAddPreservesExistingStatusProgressAndRating() async throws {
        var current = entry(kind: .manga, status: .repeating, total: 120)
        current.progress = 42
        current.score = 90
        var writes = 0
        let result = try await TrackerCollectionAddition.perform(isAuthorized: { true }, read: { current }, write: {
            writes += 1
            return self.entry(kind: .manga, status: .planning)
        })
        XCTAssertEqual(result, current)
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testCollectionAddReconcilesAmbiguousReplyWithoutResending() async throws {
        let saved = entry(status: .planning)
        var reads = 0
        var writes = 0
        let result = try await TrackerCollectionAddition.perform(isAuthorized: { true }, read: {
            reads += 1
            return reads == 1 ? nil : saved
        }, write: {
            writes += 1
            throw URLError(.networkConnectionLost)
        })
        XCTAssertEqual(result, saved)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testRepeatedCollectionAddsShareProgressSerializationAndSendOnce() async throws {
        let coordinator = TrackerProgressWriteCoordinator()
        let key = TrackerProgressWriteCoordinator.Key(owner: UUID(), service: .anilist, userID: "fixture", mediaID: 42, isManga: false)
        var remote: TrackerLibraryEntry?
        var writes = 0
        let saved = entry(status: .planning)
        func add() async throws -> TrackerLibraryEntry {
            try await coordinator.acquire(key)
            defer { Task { await coordinator.release(key) } }
            return try await TrackerCollectionAddition.perform(isAuthorized: { true }, read: { remote }, write: {
                writes += 1
                await Task.yield()
                remote = saved
                return saved
            })
        }
        let first = Task { @MainActor in try await add() }
        let second = Task { @MainActor in try await add() }
        let values = try await [first.value, second.value]
        XCTAssertEqual(values, [saved, saved])
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testCollectionAddRevokedDuringPreflightCannotWrite() async {
        var authorized = true
        var writes = 0
        do {
            _ = try await TrackerCollectionAddition.perform(isAuthorized: { authorized }, read: {
                authorized = false
                return nil
            }, write: {
                writes += 1
                return self.entry(status: .planning)
            })
            XCTFail("Revoked selection must not write")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(writes, 0)
    }

    func testIntegrationDefaultsOffAndUsesExplicitStore() throws {
        let name = "TrackerLibraryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(TrackerLibrarySettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: TrackerLibrarySettings.enabledKey)
        XCTAssertTrue(TrackerLibrarySettings.isEnabled(defaults: defaults))
        XCTAssertEqual(EclipseSettingsRegistry.scope(for: TrackerLibrarySettings.enabledKey), .profile)
    }

    func testSameProfileAfterABARemainsUnauthorized() {
        let initial = session()
        let returned = session(owner: initial.owner, operation: 3)
        XCTAssertFalse(initial.authorizes(returned, enabled: true, isKids: false))
        XCTAssertTrue(initial.authorizes(initial, enabled: true, isKids: false))
    }

    func testAccountReconnectAndCloudBoundaryRevokeSession() {
        let initial = session()
        XCTAssertFalse(initial.authorizes(session(owner: initial.owner, account: 2), enabled: true, isKids: false))
        XCTAssertFalse(initial.authorizes(session(owner: initial.owner, service: 2), enabled: true, isKids: false))
        XCTAssertFalse(initial.authorizes(session(owner: initial.owner, user: "replacement"), enabled: true, isKids: false))
        XCTAssertFalse(initial.authorizes(initial, enabled: false, isKids: false))
        XCTAssertFalse(initial.authorizes(initial, enabled: true, isKids: true))
    }

    func testAniListPagePreservesCanonicalScoreAndMangaProgress() throws {
        let result = try TrackerAniListLibraryPage.decode(aniListData(kind: .manga), kind: .manga)
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.kind, .manga)
        XCTAssertEqual(entry.progress, 8)
        XCTAssertEqual(entry.total, 120)
        XCTAssertEqual(entry.score, 85)
        XCTAssertEqual(entry.title, "Example")
        XCTAssertFalse(result.hasNext)
    }

    func testAniListRejectsPartialGraphQLErrorAndWrongMediaType() throws {
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(errors: true), kind: .anime))
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(kind: .manga), kind: .anime))
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(progress: -1), kind: .anime))
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(status: "NEW_UNKNOWN_STATUS"), kind: .anime))
    }

    func testMALUsesRepeatingFlagAndCorrectProgressUnits() throws {
        let anime = try XCTUnwrap(TrackerMALLibraryPage.decode(malData(kind: .anime, repeating: true), kind: .anime).entries.first)
        let manga = try XCTUnwrap(TrackerMALLibraryPage.decode(malData(kind: .manga, repeating: true), kind: .manga).entries.first)
        XCTAssertEqual(anime.status, .repeating)
        XCTAssertEqual(manga.status, .repeating)
        XCTAssertEqual(anime.progress, 8)
        XCTAssertEqual(manga.progress, 21)
        XCTAssertEqual(manga.score, 90)
        XCTAssertEqual(manga.averageScore, 82)
        XCTAssertEqual(TrackerLibraryStatus.repeating.title(for: .manga), "Rereading")
    }

    func testMALContinuationCannotSendCredentialsToAnotherEndpoint() throws {
        for next in [
            "https://attacker.example/v2/users/@me/animelist",
            "http://api.myanimelist.net/v2/users/@me/animelist",
            "https://api.myanimelist.net/v2/users/@me/mangalist",
            "https://user:secret@api.myanimelist.net/v2/users/@me/animelist",
            "https://api.myanimelist.net/v2/anime/1"
        ] {
            XCTAssertThrowsError(try TrackerMALLibraryPage.decode(malData(next: next), kind: .anime))
        }
        let next = "https://api.myanimelist.net/v2/users/@me/animelist?offset=100&limit=100"
        let result = try TrackerMALLibraryPage.decode(malData(next: next), kind: .anime)
        var sequence = TrackerRemoteProgressBoundary.PageSequence()
        let url = try XCTUnwrap(result.next)
        XCTAssertTrue(sequence.beginMALPage(url, listKind: .anime))
        XCTAssertFalse(sequence.beginMALPage(url, listKind: .anime))
    }

    func testUnchangedFieldsAreNeverWrittenBack() throws {
        let original = entry()
        var edit = TrackerLibraryEdit(entry: original)
        edit.score = 95
        let values = edit.aniListValues(original: original)
        XCTAssertEqual(Set(values.keys), ["scoreRaw"])
        XCTAssertEqual(values["scoreRaw"] as? Int, 95)
        XCTAssertTrue(TrackerLibraryEdit(entry: original).aniListValues(original: original).isEmpty)
    }

    func testMALRepeatingTransitionClearsFlagWithoutOverwritingProgressOrRating() {
        let original = entry(service: .myAnimeList, kind: .manga, status: .repeating)
        var edit = TrackerLibraryEdit(entry: original)
        edit.status = .paused
        XCTAssertEqual(edit.malValues(original: original), ["status": "on_hold", "is_rereading": "false"])
        edit.status = .repeating
        edit.progress = 9
        XCTAssertEqual(edit.malValues(original: original), ["num_chapters_read": "9"])
        let anime = entry(service: .myAnimeList)
        edit = TrackerLibraryEdit(entry: anime)
        edit.progress = 9
        XCTAssertEqual(edit.malValues(original: anime), ["num_watched_episodes": "9"])
    }

    func testConcurrentChangesConflictOnlyForFieldsTheUserEdited() {
        let original = entry()
        var remote = original
        remote.progress = 9
        var edit = TrackerLibraryEdit(entry: original)
        edit.score = 90
        XCTAssertFalse(edit.conflicts(original: original, current: remote))
        edit.progress = 10
        XCTAssertTrue(edit.conflicts(original: original, current: remote))
        edit.progress = 9
        XCTAssertFalse(edit.conflicts(original: original, current: remote))
    }

    func testProgressAndScoreEditsRejectInvalidOrOverflowingNumbers() throws {
        let original = entry(service: .myAnimeList)
        var edit = TrackerLibraryEdit(entry: original)
        edit.progress = Int.max
        XCTAssertThrowsError(try edit.validate(against: original))
        edit.progress = 13
        XCTAssertThrowsError(try edit.validate(against: original))
        edit.progress = 0
        edit.score = .nan
        XCTAssertThrowsError(try edit.validate(against: original))
        edit.score = 85
        XCTAssertThrowsError(try edit.validate(against: original))
        edit.score = 80
        XCTAssertNoThrow(try edit.validate(against: original))
    }

    func testDuplicateCustomListsDoNotDuplicateRowsOrMergeDifferentServices() throws {
        let first = entry()
        let second = entry(service: .myAnimeList)
        var entries: [TrackerLibraryEntry] = []
        try TrackerLibraryPolicy.append([first, first], to: &entries)
        try TrackerLibraryPolicy.append([first, second], to: &entries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testSearchUsesAlternateTitlesAndCombinesGenreFilter() {
        let item = entry()
        XCTAssertEqual(TrackerLibraryPolicy.filtered([item], search: " Japanese ", genre: "Comedy").count, 1)
        XCTAssertTrue(TrackerLibraryPolicy.filtered([item], search: "Japanese", genre: "Drama").isEmpty)
        XCTAssertTrue(TrackerLibraryPolicy.filtered([item], search: "missing", genre: nil).isEmpty)
    }

    func testImageURLsRejectCredentialsAndNonHTTPS() {
        XCTAssertNil(TrackerLibraryPolicy.imageURL("file:///tmp/image.png"))
        XCTAssertNil(TrackerLibraryPolicy.imageURL("http://images.example/cover.jpg"))
        XCTAssertNil(TrackerLibraryPolicy.imageURL("https://user:secret@images.example/cover.jpg"))
        XCTAssertNotNil(TrackerLibraryPolicy.imageURL("https://images.example/cover.jpg"))
    }

    func testSessionsCannotCrossProfilesOrTrackerServices() {
        let initial = session()
        XCTAssertFalse(initial.authorizes(session(), enabled: true, isKids: false))
        let otherService = TrackerLibrarySession(owner: initial.owner,
            operationGeneration: initial.operationGeneration, accountGeneration: initial.accountGeneration,
            serviceGeneration: initial.serviceGeneration, service: .myAnimeList, userID: initial.userID)
        XCTAssertFalse(initial.authorizes(otherService, enabled: true, isKids: false))
    }

    func testAniListEmptyCompletedPageDiffersFromMissingOrPartialData() throws {
        let empty = try TrackerAniListLibraryPage.decode(aniListData(entryCount: 0), kind: .anime)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertFalse(empty.hasNext)
        let continued = try TrackerAniListLibraryPage.decode(aniListData(entryCount: 0, hasNext: true), kind: .anime)
        XCTAssertTrue(continued.hasNext)
        for payload in [#"{}"#, #"{"data":null}"#, #"{"data":{"MediaListCollection":null}}"#] {
            XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(Data(payload.utf8), kind: .anime))
        }
    }

    func testAniListRejectsContradictoryIdentityAndUnboundedMetadata() throws {
        for changes: [String: Any] in [["mediaId": 43], ["id": 0], ["progress": NSNull()],
                                      ["progress": TrackerLibraryPolicy.maximumProgress + 1], ["score": 101]] {
            XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(entryChanges: changes), kind: .anime))
        }
        for changes: [String: Any] in [["id": 0], ["episodes": -1], ["averageScore": 101],
                                      ["genres": Array(repeating: "Genre", count: 65)],
                                      ["title": ["english": String(repeating: "x", count: 4_097)]]] {
            XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(mediaChanges: changes), kind: .anime))
        }
    }

    func testAniListBoundsGroupsCombinedRowsAndResponseBytes() throws {
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(groupCount: 101), kind: .anime))
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(entryCount: 1_001), kind: .anime))
        let repeated = try TrackerAniListLibraryPage.decode(aniListData(entryCount: 501, groupCount: 2), kind: .anime)
        XCTAssertEqual(repeated.entries.map(\.mediaID), [42])
        let maximum = try TrackerAniListLibraryPage.decode(aniListData(entryCount: 500, groupCount: 2, distinctIDs: true), kind: .anime)
        XCTAssertEqual(maximum.entries.map(\.mediaID), Array(1...1_000))
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(entryCount: 501, groupCount: 2, distinctIDs: true), kind: .anime)) { error in
            guard case TrackerLibraryError.tooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let bytes = Data(repeating: 0x20, count: TrackerLibraryPolicy.maximumResponseBytes + 1)
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(bytes, kind: .anime)) { error in
            guard case TrackerLibraryError.tooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMALRejectsMissingProgressFractionalRatingAndInvalidMetadata() throws {
        for kind in TrackerLibraryKind.supportedKinds(for: .myAnimeList) {
            let key = kind == .anime ? "num_episodes_watched" : "num_chapters_read"
            for changes: [String: Any] in [[key: NSNull()], [key: -1], ["score": 8.5],
                                          ["score": 11], ["status": "unknown"]] {
                XCTAssertThrowsError(try TrackerMALLibraryPage.decode(malData(kind: kind, statusChanges: changes), kind: kind))
            }
            let valid = try TrackerMALLibraryPage.decode(malData(kind: kind, statusChanges: ["score": 0]), kind: kind)
            XCTAssertEqual(valid.entries.first?.score, 0)
        }
        for changes: [String: Any] in [["id": 0], ["mean": -1], ["num_episodes": -1]] {
            XCTAssertThrowsError(try TrackerMALLibraryPage.decode(malData(nodeChanges: changes), kind: .anime))
        }
    }

    func testMALBoundsPagesAndRejectsFragmentsPortsAndRelativeContinuations() throws {
        XCTAssertThrowsError(try TrackerMALLibraryPage.decode(malData(entryCount: TrackerLibraryPolicy.pageSize + 1), kind: .anime))
        XCTAssertTrue(try TrackerMALLibraryPage.decode(malData(entryCount: 0), kind: .anime).entries.isEmpty)
        for next in ["/v2/users/@me/animelist?offset=100",
                     "https://api.myanimelist.net:443/v2/users/@me/animelist",
                     "https://api.myanimelist.net/v2/users/@me/animelist#fragment",
                     "https://api.myanimelist.net.attacker.example/v2/users/@me/animelist"] {
            XCTAssertThrowsError(try TrackerMALLibraryPage.decode(malData(next: next), kind: .anime))
        }
        let next = "https://api.myanimelist.net/v2/users/@me/mangalist?offset=100&limit=100"
        XCTAssertEqual(try TrackerMALLibraryPage.decode(malData(kind: .manga, next: next), kind: .manga).next?.absoluteString, next)
    }

    func testRatingOnlyEditPreservesProgressAboveOutdatedTotal() throws {
        let original = entry(progress: 20, total: 12)
        var edit = TrackerLibraryEdit(entry: original)
        edit.score = 90
        XCTAssertNoThrow(try edit.validate(against: original))
        XCTAssertEqual(Set(edit.aniListValues(original: original).keys), ["scoreRaw"])
        edit.progress = 21
        XCTAssertThrowsError(try edit.validate(against: original))
        edit.progress = 12
        XCTAssertNoThrow(try edit.validate(against: original))
        for total: Int? in [nil, 0] {
            let unknownTotal = entry(total: total)
            var unknownEdit = TrackerLibraryEdit(entry: unknownTotal)
            unknownEdit.progress = TrackerLibraryPolicy.maximumProgress
            XCTAssertNoThrow(try unknownEdit.validate(against: unknownTotal))
        }
    }

    func testConflictsCoverStatusRatingAndIdentityWithoutClobberingConvergedEdits() {
        let original = entry()
        var edit = TrackerLibraryEdit(entry: original)
        edit.status = .completed
        var remote = original
        remote.status = .dropped
        XCTAssertTrue(edit.conflicts(original: original, current: remote))
        remote.status = .completed
        XCTAssertFalse(edit.conflicts(original: original, current: remote))
        edit.score = 95
        remote.score = 90
        XCTAssertTrue(edit.conflicts(original: original, current: remote))
        remote.score = 95
        XCTAssertFalse(edit.conflicts(original: original, current: remote))
        for other in [entry(mediaID: 43), entry(kind: .manga), entry(service: .myAnimeList)] {
            XCTAssertTrue(TrackerLibraryEdit(entry: original).conflicts(original: original, current: other))
        }
    }

    func testAppendLimitsDoNotEvictAlreadyLoadedEntries() throws {
        var entries = [entry()]
        XCTAssertThrowsError(try TrackerLibraryPolicy.append(Array(repeating: entry(), count: 1_001), to: &entries))
        XCTAssertEqual(entries, [entry()])
        entries = (1...TrackerLibraryPolicy.maximumEntries).map { entry(mediaID: $0) }
        XCTAssertNoThrow(try TrackerLibraryPolicy.append([entry(mediaID: 1)], to: &entries))
        XCTAssertThrowsError(try TrackerLibraryPolicy.append([entry(mediaID: TrackerLibraryPolicy.maximumEntries + 1)], to: &entries))
        XCTAssertEqual(entries.count, TrackerLibraryPolicy.maximumEntries)
        XCTAssertEqual(entries.first?.mediaID, 1)
        XCTAssertEqual(entries.last?.mediaID, TrackerLibraryPolicy.maximumEntries)
    }

    func testMALStatusRoundTripsAndRatingClearRemainKindSpecific() {
        for kind in TrackerLibraryKind.supportedKinds(for: .myAnimeList) {
            for status in TrackerLibraryStatus.allCases {
                XCTAssertEqual(TrackerLibraryStatus.fromMAL(status.malValue(for: kind), repeating: status == .repeating), status)
            }
            let original = entry(service: .myAnimeList, kind: kind)
            var edit = TrackerLibraryEdit(entry: original)
            edit.score = 0
            XCTAssertEqual(edit.malValues(original: original), ["score": "0"])
            edit.status = .repeating
            XCTAssertEqual(edit.malValues(original: original)[kind == .anime ? "is_rewatching" : "is_rereading"], "true")
            XCTAssertNil(edit.malValues(original: original)[kind == .anime ? "is_rereading" : "is_rewatching"])
        }
    }

    private func session(owner: UUID = UUID(), operation: UInt64 = 1, account: UInt64 = 1, service: UInt64 = 1, user: String = "42") -> TrackerLibrarySession {
        TrackerLibrarySession(owner: owner, operationGeneration: operation, accountGeneration: account, serviceGeneration: service, service: .anilist, userID: user)
    }

    private func entry(service: TrackerService = .anilist, kind: TrackerLibraryKind = .anime, status: TrackerLibraryStatus = .current, mediaID: Int = 42, progress: Int = 8, total: Int? = 12) -> TrackerLibraryEntry {
        TrackerLibraryEntry(service: service, kind: kind, mediaID: mediaID, entryID: 24, aniListID: mediaID, malID: 13, title: "Example", alternateTitles: ["Japanese Title"], coverLarge: nil, coverMedium: nil, total: total, genres: ["Comedy"], averageScore: 80, status: status, progress: progress, score: 80, updatedAt: nil)
    }

    private func aniListData(kind: TrackerLibraryKind = .anime, errors: Bool = false, progress: Int = 8, status: String = "CURRENT", entryCount: Int = 1, groupCount: Int = 1, distinctIDs: Bool = false, hasNext: Bool = false, entryChanges: [String: Any] = [:], mediaChanges: [String: Any] = [:]) throws -> Data {
        var media: [String: Any] = ["id": 42, "idMal": 13, "type": kind.rawValue, "title": ["english": "Example"], "episodes": 12, "chapters": 120, "genres": ["Comedy"], "averageScore": 82]
        media.merge(mediaChanges) { _, updated in updated }
        var entry: [String: Any] = ["id": 24, "mediaId": 42, "status": status, "progress": progress, "score": 85, "media": media]
        entry.merge(entryChanges) { _, updated in updated }
        let groups = (0..<groupCount).map { group in
            ["entries": (0..<entryCount).map { index in
                guard distinctIDs else { return entry }
                let id = group * entryCount + index + 1
                var distinct = entry
                var distinctMedia = media
                distinct["id"] = id
                distinct["mediaId"] = id
                distinctMedia["id"] = id
                distinct["media"] = distinctMedia
                return distinct
            }]
        }
        var payload: [String: Any] = ["data": ["MediaListCollection": ["hasNextChunk": hasNext, "lists": groups]]]
        if errors { payload["errors"] = [["message": "Partial data"]] }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func malData(kind: TrackerLibraryKind = .anime, repeating: Bool = false, next: String? = nil, entryCount: Int = 1, nodeChanges: [String: Any] = [:], statusChanges: [String: Any] = [:]) throws -> Data {
        var node: [String: Any] = ["id": 13, "title": "Example", "num_episodes": 12, "num_chapters": 120, "genres": [["name": "Comedy"]], "mean": 8.2]
        node.merge(nodeChanges) { _, updated in updated }
        var status: [String: Any] = ["status": kind == .anime ? "watching" : "reading", "score": 9, "num_episodes_watched": 8, "num_chapters_read": 21, "is_rewatching": repeating, "is_rereading": repeating]
        status.merge(statusChanges) { _, updated in updated }
        var payload: [String: Any] = ["data": Array(repeating: ["node": node, "list_status": status], count: entryCount)]
        if let next { payload["paging"] = ["next": next] }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}


final class TrackerCollectionImportTests: XCTestCase {
    @MainActor
    func testMediaPreparedImportRebasesAfterAnAdditiveEdit() async throws {
        let owner = UUID()
        let key = LibraryManager.collectionsKey(for: owner)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = LibraryManager(profileID: owner)
        XCTAssertTrue(manager.createCollection(name: "Planning"))
        let collection = try XCTUnwrap(manager.collections.first { $0.name == "Planning" })
        let imported = LibraryItem(searchResult: mediaResult(id: 7, isMovie: false))
        let local = LibraryItem(searchResult: mediaResult(id: 8, isMovie: true))
        let additions = [LibraryManager.ImportedItem(collectionName: "Planning", item: imported)]
        let snapshot = try manager.captureImport(owner: owner, invalidation: nil)
        let prepared = try LibraryManager.prepareImport(additions, sourceName: "AniList", snapshot: snapshot)
        manager.addItem(to: collection.id, item: local)
        XCTAssertFalse(try manager.commitImport(prepared, snapshot: snapshot))
        let updated = try manager.captureImport(owner: owner, invalidation: snapshot.invalidation)
        let rebuilt = try LibraryManager.prepareImport(additions, sourceName: "AniList", snapshot: updated)
        XCTAssertTrue(try manager.commitImport(rebuilt, snapshot: updated))
        XCTAssertTrue(manager.collections.contains { $0 === collection })
        XCTAssertEqual(collection.items.map(\.id), [local.id, imported.id])
        XCTAssertTrue(snapshot.collections.first { $0.id == collection.id }?.items.isEmpty == true)
        await drainCollectionWrites()
    }

    @MainActor
    func testMediaPreparedImportRejectsRemovalRenameRestoreAndProfileABA() async throws {
        for mutation in ["remove-readd", "rename", "restore", "profile"] {
            let owner = UUID()
            let otherOwner = UUID()
            defer {
                UserDefaults.standard.removeObject(forKey: LibraryManager.collectionsKey(for: owner))
                UserDefaults.standard.removeObject(forKey: LibraryManager.collectionsKey(for: otherOwner))
            }
            let manager = LibraryManager(profileID: owner)
            XCTAssertTrue(manager.createCollection(name: "Planning"))
            let collection = try XCTUnwrap(manager.collections.first { $0.name == "Planning" })
            let local = LibraryItem(searchResult: mediaResult(id: 8, isMovie: false))
            manager.addItem(to: collection.id, item: local)
            let snapshot = try manager.captureImport(owner: owner, invalidation: nil)
            let prepared = try LibraryManager.prepareImport([
                .init(collectionName: "Planning", item: LibraryItem(searchResult: mediaResult(id: 7, isMovie: false)))
            ], sourceName: "AniList", snapshot: snapshot)
            switch mutation {
            case "remove-readd":
                manager.removeItem(from: collection.id, item: local)
                manager.addItem(to: collection.id, item: local)
            case "rename":
                manager.renameCollection(collection, name: "Renamed")
                manager.renameCollection(collection, name: "Planning")
            case "restore":
                manager.replaceCollectionsForMediaState(manager.collections)
            default:
                manager.switchProfile(to: otherOwner)
                manager.switchProfile(to: owner)
            }
            XCTAssertThrowsError(try manager.commitImport(prepared, snapshot: snapshot), mutation) { error in
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertThrowsError(try manager.captureImport(owner: owner, invalidation: snapshot.invalidation), mutation)
            XCTAssertFalse(manager.collections.flatMap(\.items).contains { $0.searchResult.id == 7 })
            await drainCollectionWrites()
        }
    }

    @MainActor
    func testMediaImportPreservesUnsupportedStorageBeforeCaptureAndCommit() throws {
        let owner = UUID()
        let key = LibraryManager.collectionsKey(for: owner)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = LibraryManager(profileID: owner)
        UserDefaults.standard.set("Unreadable before capture", forKey: key)
        XCTAssertThrowsError(try manager.captureImport(owner: owner, invalidation: nil))
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "Unreadable before capture")
        UserDefaults.standard.removeObject(forKey: key)
        let snapshot = try manager.captureImport(owner: owner, invalidation: nil)
        let prepared = try LibraryManager.prepareImport([
            .init(collectionName: "Planning", item: LibraryItem(searchResult: mediaResult(id: 7, isMovie: false)))
        ], sourceName: "AniList", snapshot: snapshot)
        UserDefaults.standard.set("Unreadable before commit", forKey: key)
        XCTAssertThrowsError(try manager.commitImport(prepared, snapshot: snapshot))
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "Unreadable before commit")
    }

    func testCombinedAnimeImportReusesCoveredCoursAndFetchesOnlyTheMissingSeed() async throws {
        let recorder = SeedRecorder()
        let entries = [
            TrackerCombinedAnimeImport.Entry(index: 0, aniListID: 101, malID: 201, watched: 2),
            TrackerCombinedAnimeImport.Entry(index: 1, aniListID: 102, malID: 202, watched: 2),
            TrackerCombinedAnimeImport.Entry(index: 2, aniListID: 103, malID: 203, watched: 2)
        ]
        let combined = [
            animeSeason(id: 101, canonicalID: 101, malID: 201, tmdbSeason: 1, firstEpisode: 1),
            animeSeason(id: 102, canonicalID: 102, malID: 202, tmdbSeason: 1, firstEpisode: 3)
        ]
        let missing = animeSeason(id: 103, canonicalID: 103, malID: 203, tmdbSeason: 2, firstEpisode: 1)
        let resolved = try await TrackerCombinedAnimeImport.resolve(entries, loadModel: { entry in
            await recorder.record(entry.aniListID)
            return entry.aniListID == 101 ? combined : [missing]
        }, validateAuthority: {})
        let requested = await recorder.values()
        XCTAssertEqual(requested, [101, 103])
        XCTAssertEqual(resolved[0], [1: [1...2]])
        XCTAssertEqual(resolved[1], [1: [3...4]])
        XCTAssertEqual(resolved[2], [2: [1...2]])
    }

    func testCombinedAnimeImportDoesNotGuessWithheldOrAmbiguousCoordinates() async throws {
        let recorder = SeedRecorder()
        let entries = [
            TrackerCombinedAnimeImport.Entry(index: 0, aniListID: 101, malID: 201, watched: 2),
            TrackerCombinedAnimeImport.Entry(index: 1, aniListID: 102, malID: 202, watched: 2),
            TrackerCombinedAnimeImport.Entry(index: 2, aniListID: 103, malID: 203, watched: 2),
            TrackerCombinedAnimeImport.Entry(index: 3, aniListID: 104, malID: 204, watched: 2)
        ]
        let ambiguous = animeSeason(id: 102, canonicalID: 102, malID: 202, tmdbSeason: 1, firstEpisode: 3)
        let graph = [
            animeSeason(id: 101, canonicalID: 101, malID: 201, tmdbSeason: nil, firstEpisode: nil),
            ambiguous, ambiguous,
            animeSeason(id: -203, canonicalID: nil, malID: 203, tmdbSeason: 2, firstEpisode: 1),
            animeSeason(id: -204, canonicalID: 999, malID: 204, tmdbSeason: 2, firstEpisode: 3)
        ]
        let resolved = try await TrackerCombinedAnimeImport.resolve(entries, loadModel: { entry in
            await recorder.record(entry.aniListID)
            return graph
        }, validateAuthority: {})
        let requested = await recorder.values()
        XCTAssertEqual(requested, [101, 102, 104])
        XCTAssertNil(resolved[0])
        XCTAssertNil(resolved[1])
        XCTAssertEqual(resolved[2], [2: [1...2]])
        XCTAssertNil(resolved[3])
    }

    @MainActor
    func testMediaImportPublishesOnceAndUpdatesAnOpenCollectionReference() async throws {
        let owner = UUID()
        let key = LibraryManager.collectionsKey(for: owner)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = LibraryManager(profileID: owner)
        XCTAssertTrue(manager.createCollection(name: "Planning"))
        let openCollection = try XCTUnwrap(manager.collections.first { $0.name == "Planning" })
        let startingRevision = manager.mediaStateRevision
        var notifications = 0
        let observation = NotificationCenter.default.addObserver(forName: .libraryDataDidChange, object: manager, queue: nil) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        let incoming = (1...1_000).map { index in
            LibraryManager.ImportedItem(collectionName: "Planning", item: LibraryItem(searchResult: mediaResult(id: index, isMovie: false)))
        }
        let added = try await manager.mergeImportedItems(incoming, sourceName: "AniList", owner: owner) {}
        XCTAssertEqual(added, 1_000)
        XCTAssertTrue(manager.collections.contains { $0 === openCollection })
        XCTAssertEqual(openCollection.items.count, 1_000)
        XCTAssertEqual(manager.mediaStateRevision, startingRevision + 1)
        let saved = try JSONDecoder().decode([LibraryCollection].self, from: XCTUnwrap(UserDefaults.standard.data(forKey: key)))
        XCTAssertEqual(saved.first { $0.id == openCollection.id }?.items.count, 1_000)
        await Task.yield()
        XCTAssertEqual(notifications, 1)
        let repeated = try await manager.mergeImportedItems(incoming, sourceName: "AniList", owner: owner) {}
        XCTAssertEqual(repeated, 0)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(manager.mediaStateRevision, startingRevision + 1)
    }

    func testMediaImportPreservesExistingMembersAndSeparatesMovieFromShowIdentity() throws {
        var original = LibraryItem(searchResult: mediaResult(id: 1, isMovie: false))
        original.dateAdded = Date(timeIntervalSince1970: 100)
        let planning = LibraryCollection(name: "Planning", items: [original], description: "Keep my description")
        let unrelated = LibraryCollection(name: "Private", items: [LibraryItem(searchResult: mediaResult(id: 99, isMovie: true))])
        let incoming = [
            LibraryManager.ImportedItem(collectionName: "Planning", item: LibraryItem(searchResult: mediaResult(id: 1, isMovie: false))),
            LibraryManager.ImportedItem(collectionName: "Planning", item: LibraryItem(searchResult: mediaResult(id: 2, isMovie: false))),
            LibraryManager.ImportedItem(collectionName: "Planning", item: LibraryItem(searchResult: mediaResult(id: 2, isMovie: false))),
            LibraryManager.ImportedItem(collectionName: "Planning", item: LibraryItem(searchResult: mediaResult(id: 2, isMovie: true))),
            LibraryManager.ImportedItem(collectionName: "Completed", item: LibraryItem(searchResult: mediaResult(id: 2, isMovie: true)))
        ]
        let merged = LibraryManager.mergingImportedItems(incoming, into: [planning, unrelated], sourceName: "AniList")
        XCTAssertEqual(merged.added, 3)
        XCTAssertEqual(planning.items.count, 1)
        XCTAssertEqual(merged.collections.map(\.name), ["Planning", "Private", "Completed"])
        XCTAssertEqual(merged.collections[0].id, planning.id)
        XCTAssertEqual(merged.collections[0].description, "Keep my description")
        XCTAssertEqual(merged.collections[0].items.first?.dateAdded, original.dateAdded)
        XCTAssertEqual(merged.collections[0].items.map(\.id), [original.id, incoming[1].item.id, incoming[3].item.id])
        XCTAssertTrue(merged.collections[1] === unrelated)
        let repeated = LibraryManager.mergingImportedItems(incoming, into: merged.collections, sourceName: "AniList")
        XCTAssertEqual(repeated.added, 0)
        XCTAssertTrue(repeated.collections[0] === merged.collections[0])
        XCTAssertEqual(try JSONEncoder().encode(repeated.collections).count, try JSONEncoder().encode(merged.collections).count)
    }

#if !os(tvOS)
    @MainActor
    func testMangaPreparedImportRebasesWithoutLosingAnAttachedSource() async throws {
        let owner = UUID()
        let key = MangaLibraryManager.storageKey(for: owner)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = MangaLibraryManager(profileID: owner)
        manager.createCollection(name: "Planning")
        let planning = try XCTUnwrap(manager.collections.first { $0.name == "Planning" })
        let bookmarks = try XCTUnwrap(manager.collections.first { $0.name == "Bookmarks" })
        let imported = MangaLibraryItem(aniListId: 7, title: "Tracker Title", coverURL: nil, format: nil, totalChapters: nil)
        let additions = [MangaLibraryManager.ImportedItem(collectionName: "Planning", item: imported)]
        let snapshot = try manager.captureImport(owner: owner, invalidation: nil)
        let prepared = try MangaLibraryManager.prepareImport(additions, sourceName: "AniList", snapshot: snapshot)
        var linked = imported
        linked.route = .legacyModule(moduleUUID: "fixture-module", contentParams: "fixture-title", isNovel: true)
        linked.format = "NOVEL"
        linked.title = "Saved Source Title"
        manager.addItem(to: bookmarks.id, item: linked)
        XCTAssertFalse(try manager.commitImport(prepared, snapshot: snapshot))
        let updated = try manager.captureImport(owner: owner, invalidation: snapshot.invalidation)
        let rebuilt = try MangaLibraryManager.prepareImport(additions, sourceName: "AniList", snapshot: updated)
        XCTAssertTrue(try manager.commitImport(rebuilt, snapshot: updated))
        XCTAssertTrue(manager.collections.contains { $0 === planning })
        XCTAssertTrue(manager.collections.contains { $0 === bookmarks })
        XCTAssertEqual(planning.items.first?.route, linked.route)
        XCTAssertEqual(planning.items.first?.title, linked.title)
        XCTAssertEqual(planning.items.first?.format, linked.format)
        let repeated = try await manager.mergeImportedItems(additions, sourceName: "AniList", owner: owner) {}
        XCTAssertEqual(repeated, 0)
        await drainCollectionWrites()
    }

    @MainActor
    func testMangaPreparedImportRejectsRemovalRenameRestoreAndProfileABA() async throws {
        for mutation in ["remove-readd", "rename", "restore", "profile"] {
            let owner = UUID()
            let otherOwner = UUID()
            defer {
                UserDefaults.standard.removeObject(forKey: MangaLibraryManager.storageKey(for: owner))
                UserDefaults.standard.removeObject(forKey: MangaLibraryManager.storageKey(for: otherOwner))
            }
            let manager = MangaLibraryManager(profileID: owner)
            manager.createCollection(name: "Planning")
            let collection = try XCTUnwrap(manager.collections.first { $0.name == "Planning" })
            let local = MangaLibraryItem(aniListId: 8, title: "Saved Title", coverURL: nil, format: nil, totalChapters: nil)
            manager.addItem(to: collection.id, item: local)
            let snapshot = try manager.captureImport(owner: owner, invalidation: nil)
            let prepared = try MangaLibraryManager.prepareImport([
                .init(collectionName: "Planning", item: MangaLibraryItem(aniListId: 7, title: "Imported", coverURL: nil, format: nil, totalChapters: nil))
            ], sourceName: "AniList", snapshot: snapshot)
            switch mutation {
            case "remove-readd":
                manager.removeItem(from: collection.id, item: local)
                manager.addItem(to: collection.id, item: local)
            case "rename":
                manager.renameCollection(collection, name: "Renamed")
                manager.renameCollection(collection, name: "Planning")
            case "restore":
                manager.applyRestoredCollections(manager.collections, forProfile: owner)
            default:
                manager.switchProfile(to: otherOwner)
                manager.switchProfile(to: owner)
            }
            XCTAssertThrowsError(try manager.commitImport(prepared, snapshot: snapshot), mutation) { error in
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertThrowsError(try manager.captureImport(owner: owner, invalidation: snapshot.invalidation), mutation)
            XCTAssertFalse(manager.collections.flatMap(\.items).contains { $0.id == 7 })
            await drainCollectionWrites()
        }
    }

    @MainActor
    func testMangaImportPreservesUnsupportedStorageBeforeCaptureAndCommit() throws {
        let owner = UUID()
        let key = MangaLibraryManager.storageKey(for: owner)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = MangaLibraryManager(profileID: owner)
        UserDefaults.standard.set("Unreadable before capture", forKey: key)
        XCTAssertThrowsError(try manager.captureImport(owner: owner, invalidation: nil))
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "Unreadable before capture")
        UserDefaults.standard.removeObject(forKey: key)
        let snapshot = try manager.captureImport(owner: owner, invalidation: nil)
        let prepared = try MangaLibraryManager.prepareImport([
            .init(collectionName: "Planning", item: MangaLibraryItem(aniListId: 7, title: "Imported", coverURL: nil, format: nil, totalChapters: nil))
        ], sourceName: "AniList", snapshot: snapshot)
        UserDefaults.standard.set("Unreadable before commit", forKey: key)
        XCTAssertThrowsError(try manager.commitImport(prepared, snapshot: snapshot))
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "Unreadable before commit")
    }

    func testMangaProgressImportAddsNovelMetadataAndKeepsAttachedSourceMetadata() throws {
        var linked = MangaProgress()
        linked.route = .legacyModule(moduleUUID: "fixture-module", contentParams: "fixture-title", isNovel: false)
        linked.coverURL = "https://example.com/source-cover.jpg"
        linked.format = "MANGA"
        let records = [
            MangaReadingProgressManager.ImportRecord(mangaID: 7, throughChapter: 2, title: "Novel", coverURL: "https://example.com/novel.jpg", totalChapters: 10, format: "NOVEL"),
            MangaReadingProgressManager.ImportRecord(mangaID: 8, throughChapter: 2, title: "Linked", coverURL: "https://example.com/tracker.jpg", totalChapters: 10, format: "NOVEL")
        ]
        let result = try MangaReadingProgressManager.prepareImport(records, progress: [8: linked])
        XCTAssertEqual(result.progress[7]?.format, "NOVEL")
        XCTAssertEqual(result.progress[7]?.coverURL, "https://example.com/novel.jpg")
        XCTAssertEqual(result.progress[8]?.format, "MANGA")
        XCTAssertEqual(result.progress[8]?.coverURL, linked.coverURL)
        XCTAssertEqual(result.progress[8]?.route, linked.route)
        XCTAssertEqual(result.progress[7]?.readChapterNumbers, ["1", "2"])
        XCTAssertEqual(result.progress[8]?.readChapterNumbers, ["1", "2"])
    }

    func testMangaImportKeepsAnAttachedSourceWhenCreatingUnreadPlanningMembership() throws {
        let route = MangaContentRoute.legacyModule(moduleUUID: UUID().uuidString, contentParams: "stored-title", isNovel: true)
        var linked = MangaLibraryItem(aniListId: 137, title: "Saved Source Title", coverURL: "https://example.com/cover.jpg", format: "NOVEL", totalChapters: 2)
        linked.route = route
        linked.moduleUUID = "saved-module"
        linked.contentParams = "stored-title"
        linked.isNovel = true
        linked.sourceName = "Installed Source"
        linked.latestChapterNumbers = ["1", "2"]
        linked.contentRating = ReaderContentRating.nsfw.rawValue
        linked.trackerMALId = 64
        let bookmarks = MangaLibraryCollection(name: "Bookmarks", items: [linked])
        let unlinked = MangaLibraryCollection(name: "Old List", items: [MangaLibraryItem(aniListId: 137, title: "Unlinked", coverURL: nil, format: nil, totalChapters: nil)])
        let incoming = [
            MangaLibraryManager.ImportedItem(collectionName: "Planning", item: MangaLibraryItem(aniListId: 137, title: "Tracker Title", coverURL: nil, format: nil, totalChapters: 44, trackerAniListId: 137)),
            MangaLibraryManager.ImportedItem(collectionName: "Planning", item: MangaLibraryItem(aniListId: 88, title: "Unread Title", coverURL: nil, format: nil, totalChapters: nil)),
            MangaLibraryManager.ImportedItem(collectionName: "Planning", item: MangaLibraryItem(aniListId: 88, title: "Duplicate", coverURL: nil, format: nil, totalChapters: nil))
        ]
        let merged = MangaLibraryManager.mergingImportedItems(incoming, into: [unlinked, bookmarks], sourceName: "AniList")
        let planning = try XCTUnwrap(merged.collections.first { $0.name == "Planning" })
        let retained = try XCTUnwrap(planning.items.first { $0.id == linked.id })
        XCTAssertEqual(merged.added, 2)
        XCTAssertEqual(planning.items.map(\.id), [137, 88])
        XCTAssertEqual(retained.route, route)
        XCTAssertEqual(retained.moduleUUID, linked.moduleUUID)
        XCTAssertEqual(retained.contentParams, linked.contentParams)
        XCTAssertEqual(retained.title, linked.title)
        XCTAssertEqual(retained.coverURL, linked.coverURL)
        XCTAssertEqual(retained.format, linked.format)
        XCTAssertEqual(retained.totalChapters, 2)
        XCTAssertEqual(retained.latestChapterNumbers, linked.latestChapterNumbers)
        XCTAssertEqual(retained.trackerAniListId, 137)
        XCTAssertEqual(retained.trackerMALId, 64)
        XCTAssertEqual(retained.contentRating, ReaderContentRating.nsfw.rawValue)
        XCTAssertEqual(bookmarks.items.count, 1)
        XCTAssertNil(unlinked.items.first?.route)
        let repeated = MangaLibraryManager.mergingImportedItems(incoming, into: merged.collections, sourceName: "AniList")
        XCTAssertEqual(repeated.added, 0)
        XCTAssertTrue(repeated.collections[2] === planning)
    }
#endif

    @MainActor
    func testMediaImportMergeMatchesLegacyMembershipAtRepresentativeLibrarySizes() async throws {
        for count in [100, 1_000, 10_000] {
            let incoming = (1...count).map { index in
                LibraryManager.ImportedItem(collectionName: "Planning", item: LibraryItem(searchResult: mediaResult(id: index, isMovie: false)))
            }
            let baselineStart = ProcessInfo.processInfo.systemUptime
            var baseline = incoming.prefix(0).map(\.item)
            for entry in incoming where !baseline.contains(where: { $0.id == entry.item.id }) {
                baseline.append(entry.item)
            }
            let baselineDuration = ProcessInfo.processInfo.systemUptime - baselineStart
            let batchStart = ProcessInfo.processInfo.systemUptime
            let merged = LibraryManager.mergingImportedItems(incoming, into: [], sourceName: "AniList")
            let batchDuration = ProcessInfo.processInfo.systemUptime - batchStart
            XCTAssertEqual(merged.added, count)
            XCTAssertEqual(merged.collections.first?.items.map(\.id), baseline.map(\.id))
            let owner = UUID()
            let key = LibraryManager.collectionsKey(for: owner)
            defer { UserDefaults.standard.removeObject(forKey: key) }
            let manager = LibraryManager(profileID: owner)
            let captureStart = ProcessInfo.processInfo.systemUptime
            let snapshot = try manager.captureImport(owner: owner, invalidation: nil)
            let captureDuration = ProcessInfo.processInfo.systemUptime - captureStart
            let workerResult = try await Task.detached(priority: .utility) {
                XCTAssertFalse(Thread.isMainThread)
                let preparationStart = ProcessInfo.processInfo.systemUptime
                let prepared = try LibraryManager.prepareImport(incoming, sourceName: "AniList", snapshot: snapshot)
                return (prepared, ProcessInfo.processInfo.systemUptime - preparationStart)
            }.value
            let commitStart = ProcessInfo.processInfo.systemUptime
            XCTAssertTrue(try manager.commitImport(workerResult.0, snapshot: snapshot))
            let commitDuration = ProcessInfo.processInfo.systemUptime - commitStart
            XCTAssertEqual(manager.collections.first { $0.name == "Planning" }?.items.count, count)
            let timing = "TrackerCollectionImportTiming rows=\(count) baselineMergeSeconds=\(baselineDuration) batchedMergeSeconds=\(batchDuration) mainCaptureSeconds=\(captureDuration) workerPrepareEncodeSeconds=\(workerResult.1) mainCommitSeconds=\(commitDuration)"
            print(timing)
            let attachment = XCTAttachment(string: timing)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private actor SeedRecorder {
        private var seeds: [Int] = []

        func record(_ seed: Int) { seeds.append(seed) }
        func values() -> [Int] { seeds }
    }

    @MainActor
    private func drainCollectionWrites() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func animeSeason(id: Int, canonicalID: Int?, malID: Int?, tmdbSeason: Int?, firstEpisode: Int?) -> AniListSeasonWithPoster {
        AniListSeasonWithPoster(
            seasonNumber: 1, anilistId: id, canonicalAniListId: canonicalID, malId: malID, kitsuId: nil,
            title: "Season \(id)", englishTitle: nil, romajiTitle: nil, nativeTitle: nil,
            episodes: (1...2).map { number in
                AniListEpisode(number: number, title: "Episode \(number)", description: nil, seasonNumber: 1,
                               stillPath: nil, airDate: nil, runtime: nil, tmdbSeasonNumber: tmdbSeason,
                               tmdbEpisodeNumber: firstEpisode.map { $0 + number - 1 })
            }, posterUrl: nil
        )
    }

    private func mediaResult(id: Int, isMovie: Bool) -> TMDBSearchResult {
        TMDBSearchResult(
            id: id, mediaType: isMovie ? "movie" : "tv", title: isMovie ? "Title \(id)" : nil,
            name: isMovie ? nil : "Title \(id)", overview: nil, posterPath: nil, backdropPath: nil,
            releaseDate: nil, firstAirDate: nil, voteAverage: 0, popularity: 0, adult: false, genreIds: []
        )
    }
}

final class TrackerProgressWriteCoordinatorTests: XCTestCase {
    func testCollectionIntentOrdersAutomaticAndDirectAddsWithoutBlockingScrobbles() async throws {
        let coordinator = TrackerProgressWriteCoordinator()
        let owner = UUID()
        let automatic = try XCTUnwrap(TrackerProgressWriteCoordinator.Key.traktCollectionIntent(
            owner: owner, userID: "fixture-account", tmdbID: 42))
        let direct = try XCTUnwrap(TrackerProgressWriteCoordinator.Key.traktCollectionIntent(
            owner: owner, userID: "fixture-account", tmdbID: 42, traktID: 900))
        let mutation = key(owner: owner, mediaID: 0)
        let identity = key(owner: owner, mediaID: 900)
        XCTAssertEqual(automatic, direct)
        XCTAssertNotEqual(automatic, mutation)
        XCTAssertNotEqual(automatic, identity)
        XCTAssertNil(TrackerProgressWriteCoordinator.Key.traktCollectionIntent(
            owner: owner, userID: "fixture-account", tmdbID: -42))
        try await coordinator.acquire(automatic)
        let directAdd = Task { try await coordinator.acquire(direct) }
        await waitForPending(1, coordinator: coordinator)
        try await coordinator.acquire(mutation)
        await coordinator.release(mutation)
        let waitingDuringLookup = await coordinator.pendingCount
        XCTAssertEqual(waitingDuringLookup, 1)
        await coordinator.release(automatic)
        try await directAdd.value
        await coordinator.release(direct)
    }

    func testCancelledQueuedWriteLeavesItsNeighborsInOrder() async throws {
        let coordinator = TrackerProgressWriteCoordinator()
        let key = key(mediaID: 1)
        try await coordinator.acquire(key)
        let first = Task { try await coordinator.acquire(key) }
        await waitForPending(1, coordinator: coordinator)
        let cancelled = Task { try await coordinator.acquire(key) }
        await waitForPending(2, coordinator: coordinator)
        let last = Task { try await coordinator.acquire(key) }
        await waitForPending(3, coordinator: coordinator)
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("A cancelled queued write must finish without acquiring the key")
        } catch is CancellationError {}
        let afterCancellation = await coordinator.pendingCount
        XCTAssertEqual(afterCancellation, 2)
        await coordinator.release(key)
        try await first.value
        let afterFirst = await coordinator.pendingCount
        XCTAssertEqual(afterFirst, 1)
        await coordinator.release(key)
        try await last.value
        let afterLast = await coordinator.pendingCount
        XCTAssertEqual(afterLast, 0)
        await coordinator.release(key)
        try await coordinator.acquire(key)
        await coordinator.release(key)
    }

    func testCancellationAfterAdmissionStillLetsCallerReleaseItsPermit() async throws {
        let coordinator = TrackerProgressWriteCoordinator()
        let key = key(mediaID: 1)
        let admitted = expectation(description: "The write holds its permit")
        let finished = expectation(description: "Cancellation releases the admitted permit")
        let write = Task {
            try await coordinator.acquire(key)
            admitted.fulfill()
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch {}
            await coordinator.release(key)
            finished.fulfill()
        }
        await fulfillment(of: [admitted], timeout: 2)
        write.cancel()
        await fulfillment(of: [finished], timeout: 2)
        try await write.value
        try await coordinator.acquire(key)
        await coordinator.release(key)
    }

    func testWriteQueueBoundDoesNotReserveTheRejectedKey() async throws {
        let coordinator = TrackerProgressWriteCoordinator()
        let owner = UUID()
        for mediaID in 1...TrackerProgressWriteCoordinator.maximumPendingWrites {
            try await coordinator.acquire(key(owner: owner, mediaID: mediaID))
        }
        let rejected = key(owner: owner, mediaID: TrackerProgressWriteCoordinator.maximumPendingWrites + 1)
        do {
            try await coordinator.acquire(rejected)
            XCTFail("Active writes must remain bounded")
        } catch TrackerRequestSchedulingError.queueFull {}
        await coordinator.release(key(owner: owner, mediaID: 1))
        try await coordinator.acquire(rejected)
        await coordinator.release(rejected)
        for mediaID in 2...TrackerProgressWriteCoordinator.maximumPendingWrites {
            await coordinator.release(key(owner: owner, mediaID: mediaID))
        }
    }

    private func waitForPending(_ count: Int, coordinator: TrackerProgressWriteCoordinator) async {
        let until = Date().addingTimeInterval(2)
        while await coordinator.pendingCount != count, Date() < until { await Task.yield() }
        let pending = await coordinator.pendingCount
        XCTAssertEqual(pending, count)
    }

    private func key(owner: UUID = UUID(), mediaID: Int) -> TrackerProgressWriteCoordinator.Key {
        .init(owner: owner, service: .trakt, userID: "fixture-account", mediaID: mediaID, isManga: false)
    }
}


final class TrackerDeepLibraryListPolicyTests: XCTestCase {
    func testAllSixStatusesAndHiddenCustomMembershipRemainVisible() throws {
        let names = ["Weekend Shows", "Planning to Watch", "お気に入り"]
        let entries = try TrackerLibraryStatus.allCases.enumerated().map { index, status in
            try row(id: index + 1, status: status, customLists: [names[index % names.count]: true, "Disabled": false])
        }
        let data = try JSONSerialization.data(withJSONObject: ["data": ["MediaListCollection": [
            "hasNextChunk": false, "lists": [["entries": entries], ["name": "Hidden custom group", "isCustomList": true, "entries": entries]]
        ]]])
        let result = try TrackerAniListLibraryPage.decode(data, kind: .anime)
        XCTAssertEqual(result.entries.count, 6)
        XCTAssertEqual(Set(result.entries.map(\.status)), Set(TrackerLibraryStatus.allCases))
        XCTAssertTrue(result.entries.allSatisfy(\.customListMembershipIsKnown))
        XCTAssertEqual(try TrackerLibraryPolicy.visibleEntries(result.entries, status: nil, section: .list).count, 6)
        for name in names {
            let selected = try TrackerLibraryPolicy.visibleEntries(result.entries, status: nil, section: .aniListCustomList(name: name))
            XCTAssertEqual(selected.count, 2)
            XCTAssertTrue(selected.allSatisfy { $0.customLists == [name] })
        }
        let planning = try TrackerLibraryPolicy.visibleEntries(result.entries, status: .planning, section: .list)
        XCTAssertEqual(planning.map(\.status), [.planning])
        XCTAssertEqual(TrackerLibraryStatus.planning.title(for: .anime), "Planning to Watch")
        XCTAssertEqual(TrackerLibraryStatus.planning.title(for: .manga), "Planning to Read")
    }

    func testCustomListNamesRespectKindOwnerEmptyAndMalformedAuthority() throws {
        func payload(_ options: [String: Any], userID: Int = 42) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["data": ["User": ["id": userID, "mediaListOptions": options]]])
        }
        let valid = try payload(["animeList": ["customLists": ["Planning to Watch", "Weekend", "Weekend"]], "mangaList": ["customLists": ["Manga Only"]]])
        XCTAssertEqual(try TrackerAniListLibraryListsResponse.decode(valid, kind: .anime, userID: 42), ["Planning to Watch", "Weekend"])
        XCTAssertEqual(try TrackerAniListLibraryListsResponse.decode(valid, kind: .manga, userID: 42), ["Manga Only"])
        XCTAssertThrowsError(try TrackerAniListLibraryListsResponse.decode(valid, kind: .anime, userID: 43))
        XCTAssertThrowsError(try TrackerAniListLibraryListsResponse.decode(valid, kind: .movie, userID: 42))
        XCTAssertEqual(try TrackerAniListLibraryListsResponse.decode(payload(["animeList": ["customLists": []]]), kind: .anime, userID: 42), [])
        let invalidOptions: [Any] = [NSNull(), ["customLists": NSNull()], ["customLists": 3], ["customLists": [""]], ["customLists": ["A\nB"]], ["customLists": [String(repeating: "x", count: 257)]]]
        for invalid in invalidOptions {
            XCTAssertThrowsError(try TrackerAniListLibraryListsResponse.decode(payload(["animeList": invalid]), kind: .anime, userID: 42))
        }
        XCTAssertThrowsError(try TrackerLibraryPolicy.customListNames((1...101).map { "List \($0)" }))
    }

    func testUnknownOrMalformedCustomMembershipCannotBecomeVerifiedAbsence() throws {
        let unknownData = try JSONSerialization.data(withJSONObject: row(id: 1, status: .planning, customLists: nil))
        let unknown = try JSONDecoder().decode(TrackerAniListLibraryPage.Entry.self, from: unknownData).normalized(kind: .anime)
        XCTAssertFalse(unknown.customListMembershipIsKnown)
        XCTAssertThrowsError(try TrackerLibraryPolicy.visibleEntries([unknown], status: nil, section: .aniListCustomList(name: "Weekend")))
        XCTAssertEqual(try TrackerLibraryPolicy.visibleEntries([unknown], status: .planning, section: .list).count, 1)
        let knownData = try JSONSerialization.data(withJSONObject: row(id: 2, status: .planning, customLists: ["Weekend": false]))
        let known = try JSONDecoder().decode(TrackerAniListLibraryPage.Entry.self, from: knownData).normalized(kind: .anime)
        XCTAssertTrue(known.customListMembershipIsKnown)
        XCTAssertEqual(try TrackerLibraryPolicy.visibleEntries([known], status: nil, section: .aniListCustomList(name: "Weekend")), [])
        var malformed = try row(id: 3, status: .planning, customLists: nil)
        malformed["customLists"] = ["Weekend": 1]
        XCTAssertThrowsError(try JSONDecoder().decode(TrackerAniListLibraryPage.Entry.self, from: JSONSerialization.data(withJSONObject: malformed)))
    }

    private func row(id: Int, status: TrackerLibraryStatus, customLists: [String: Bool]?) throws -> [String: Any] {
        var value: [String: Any] = [
            "id": id + 100, "mediaId": id, "status": status.rawValue, "progress": 0, "score": 0,
            "media": ["id": id, "type": "ANIME", "title": ["romaji": "Title \(id)"], "episodes": 12]
        ]
        if let customLists { value["customLists"] = customLists }
        return value
    }
}

final class TrackerSeriesCollectionTests: XCTestCase {
    @MainActor
    func testFourExactSeasonsDeduplicateAfterResolutionAndKeepUnknownTotal() async throws {
        let targets = [target(1, title: "Season 1"), target(2, title: "Season 2 Part 1"),
                       target(2, title: "Season 2 Part 2"), target(3, title: "Bridon Arc"), target(4, title: "Season 3")]
        for service in [TrackerService.anilist, .myAnimeList] {
            var reads: [Int] = []
            var updates: [Int] = []
            let rows = try await TrackerSeriesCollection.load(targets: targets, isAuthorized: { true },
                resolve: { try self.resolve($0, service: service, unknownTotalID: service == .anilist ? 4 : 104) },
                read: { candidate in reads.append(candidate.mediaID); return nil },
                onUpdate: { _, completed, total in updates.append(completed); XCTAssertEqual(total, 5) })
            let expectedIDs = service == .anilist ? [1, 2, 3, 4] : [101, 102, 103, 104]
            XCTAssertEqual(reads, expectedIDs)
            XCTAssertEqual(updates, [1, 2, 3, 4, 5])
            XCTAssertEqual(rows.compactMap { $0.candidate?.mediaID }, expectedIDs)
            XCTAssertEqual(rows.map(\.target.title), ["Season 1", "Season 2 Part 1", "Bridon Arc", "Season 3"])
            XCTAssertNil(rows.last?.candidate?.total)
            var remote: [String: TrackerLibraryEntry] = [:]
            var writes: [Int] = []
            let saved = try await TrackerSeriesCollection.addAll(rows: rows, isAuthorized: { true },
                resolve: { try self.resolve($0, service: service) },
                add: { candidate in
                    try await TrackerCollectionAddition.perform(isAuthorized: { true }, read: { remote[candidate.id] }, write: {
                        writes.append(candidate.mediaID)
                        remote[candidate.id] = candidate
                        return candidate
                    })
                }, onUpdate: { _, _, _ in })
            XCTAssertEqual(writes, expectedIDs)
            XCTAssertEqual(remote.count, 4)
            XCTAssertTrue(saved.allSatisfy(\.confirmedByAction))
            XCTAssertNil(saved.last?.existing?.total)
        }
    }

    @MainActor
    func testWebsiteCreatedEntriesPreserveEveryExistingStatusAndValue() async throws {
        for service in [TrackerService.anilist, .myAnimeList] {
            let targets = (1...4).map { target($0) }
            let rows = try await TrackerSeriesCollection.load(targets: targets, isAuthorized: { true },
                resolve: { try self.resolve($0, service: service) }, read: { _ in nil }, onUpdate: { _, _, _ in })
            let statuses: [TrackerLibraryStatus] = [.current, .completed, .repeating, .paused]
            let expected = try targets.enumerated().map { index, target in
                var value = try resolve(target, service: service)
                value.status = statuses[index]
                value.progress = index == 1 ? 12 : index + 2
                value.score = Double(60 + index * 10)
                value.updatedAt = Date(timeIntervalSince1970: Double(1_700_000_000 + index))
                value.customLists = ["Website List \(index)"]
                value.customListMembershipIsKnown = true
                return value
            }
            let remote = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
            var reads: [String] = []
            var writes = 0
            let result = try await TrackerSeriesCollection.addAll(rows: rows, isAuthorized: { true },
                resolve: { try self.resolve($0, service: service) },
                add: { candidate in
                    try await TrackerCollectionAddition.perform(isAuthorized: { true }, read: {
                        reads.append(candidate.id)
                        return remote[candidate.id]
                    }, write: { writes += 1; return candidate })
                }, onUpdate: { _, _, _ in })
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(reads, expected.map(\.id))
            XCTAssertEqual(result.compactMap(\.existing), expected)
            XCTAssertTrue(result.allSatisfy(\.confirmedByAction))
        }
    }

    @MainActor
    func testPartialRetryAfterForegroundReloadDoesNotRecreateWebsiteDeletedSuccess() async throws {
        let targets = (1...3).map { target($0) }
        let rows = try await TrackerSeriesCollection.load(targets: targets, isAuthorized: { true },
            resolve: { try self.resolve($0) }, read: { _ in nil }, onUpdate: { _, _, _ in })
        var remote: [String: TrackerLibraryEntry] = [:]
        var writes: [Int: Int] = [:]
        var reads: [Int: Int] = [:]
        var failThird = true
        func add(_ candidate: TrackerLibraryEntry) async throws -> TrackerLibraryEntry {
            try await TrackerCollectionAddition.perform(isAuthorized: { true }, read: {
                reads[candidate.mediaID, default: 0] += 1
                return remote[candidate.id]
            }, write: {
                writes[candidate.mediaID, default: 0] += 1
                if candidate.mediaID == 3 && failThird { throw URLError(.notConnectedToInternet) }
                remote[candidate.id] = candidate
                if candidate.mediaID == 2 { throw URLError(.networkConnectionLost) }
                return candidate
            })
        }
        var confirmedIDs = Set<String>()
        let partial = try await TrackerSeriesCollection.addAll(rows: rows, isAuthorized: { true },
            resolve: { try self.resolve($0) }, add: add,
            onUpdate: { values, _, _ in
                confirmedIDs.formUnion(values.filter(\.confirmedByAction).compactMap { $0.candidate?.id })
            })
        XCTAssertEqual(partial.map(\.confirmedByAction), [true, true, false])
        XCTAssertNotNil(partial[2].errorMessage)
        XCTAssertEqual(writes, [1: 1, 2: 1, 3: 1])
        XCTAssertEqual(reads, [1: 1, 2: 2, 3: 2])
        let firstID = try XCTUnwrap(partial[0].candidate?.id)
        remote.removeValue(forKey: firstID)
        let refreshed = try await TrackerSeriesCollection.load(targets: targets, confirmedEntryIDs: confirmedIDs,
            isAuthorized: { true }, resolve: { try self.resolve($0) },
            read: { remote[$0.id] }, onUpdate: { _, _, _ in })
        XCTAssertTrue(refreshed[0].confirmedByAction)
        XCTAssertTrue(refreshed[0].membershipLoaded)
        XCTAssertNil(refreshed[0].existing)
        failThird = false
        let retried = try await TrackerSeriesCollection.addAll(rows: refreshed, retryIncompleteOnly: true,
            confirmedEntryIDs: confirmedIDs, isAuthorized: { true }, resolve: { try self.resolve($0) },
            add: add, onUpdate: { _, _, _ in })
        XCTAssertTrue(retried.allSatisfy(\.confirmedByAction))
        XCTAssertNil(retried[0].existing)
        XCTAssertNil(remote[firstID])
        XCTAssertEqual(writes, [1: 1, 2: 1, 3: 2])
    }

    @MainActor
    func testConfirmedIdentitySurvivesResolverFailureDuringReload() async throws {
        let target = target(1)
        let candidate = try resolve(target)
        let confirmedIDs: Set<String> = [candidate.id]
        let refreshed = try await TrackerSeriesCollection.load(targets: [target], confirmedEntryIDs: confirmedIDs,
            isAuthorized: { true }, resolve: { _ in throw URLError(.timedOut) },
            read: { _ in XCTFail("A failed resolution cannot authorize a membership read"); return nil },
            onUpdate: { _, _, _ in })
        XCTAssertNil(refreshed[0].candidate)
        XCTAssertNotNil(refreshed[0].errorMessage)
        var adds = 0
        let retried = try await TrackerSeriesCollection.addAll(rows: refreshed, retryIncompleteOnly: true,
            confirmedEntryIDs: confirmedIDs, isAuthorized: { true }, resolve: { _ in candidate },
            add: { entry in adds += 1; return entry }, onUpdate: { _, _, _ in })
        XCTAssertEqual(adds, 0)
        XCTAssertTrue(retried[0].confirmedByAction)
        XCTAssertFalse(retried[0].membershipLoaded)
        XCTAssertNil(retried[0].existing)
        XCTAssertNil(retried[0].errorMessage)
    }

    @MainActor
    func testFailedDuplicateCannotConfirmStaleMembership() async throws {
        let firstTarget = target(1, title: "First Cour")
        let duplicateTarget = target(1, title: "Second Cour")
        let candidate = try resolve(firstTarget)
        var stale = TrackerSeriesCollectionRow(index: 0, target: firstTarget)
        stale.candidate = candidate
        stale.existing = candidate
        stale.membershipLoaded = true
        let unresolved = TrackerSeriesCollectionRow(index: 1, target: duplicateTarget)
        var adds = 0
        let failed = try await TrackerSeriesCollection.addAll(rows: [stale, unresolved], isAuthorized: { true },
            resolve: { _ in candidate }, add: { _ in adds += 1; throw URLError(.timedOut) }, onUpdate: { _, _, _ in })
        XCTAssertEqual(adds, 1)
        XCTAssertTrue(failed.allSatisfy { !$0.confirmedByAction && !$0.membershipLoaded && $0.existing == nil })
        XCTAssertTrue(failed.allSatisfy { $0.errorMessage != nil })
        let retried = try await TrackerSeriesCollection.addAll(rows: failed, retryIncompleteOnly: true,
            isAuthorized: { true }, resolve: { _ in candidate },
            add: { entry in adds += 1; return entry }, onUpdate: { _, _, _ in })
        XCTAssertEqual(adds, 2)
        XCTAssertTrue(retried.allSatisfy(\.confirmedByAction))
        XCTAssertEqual(retried.compactMap(\.existing), [candidate, candidate])
    }

    @MainActor
    func testUnresolvedSeasonRemainsVisibleAndCannotAuthorizeAWrite() async throws {
        let unknown = TrackerCollectionTarget(title: "Unresolved Season", kind: .show, aniListID: -55, tmdbID: 123542)
        let targets = [target(1), unknown]
        let rows = try await TrackerSeriesCollection.load(targets: targets, isAuthorized: { true },
            resolve: { try self.resolve($0) }, read: { _ in nil }, onUpdate: { _, _, _ in })
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].target, unknown)
        XCTAssertNil(rows[1].candidate)
        XCTAssertNotNil(rows[1].errorMessage)
        var writes: [Int] = []
        let saved = try await TrackerSeriesCollection.addAll(rows: rows, isAuthorized: { true },
            resolve: { try self.resolve($0) }, add: { candidate in writes.append(candidate.mediaID); return candidate },
            onUpdate: { _, _, _ in })
        XCTAssertEqual(writes, [1])
        XCTAssertTrue(saved[0].confirmedByAction)
        XCTAssertFalse(saved[1].confirmedByAction)
        XCTAssertNotNil(saved[1].errorMessage)
    }

    @MainActor
    func testProfileABABetweenSeasonsStopsRemainingWritesAndKeepsCommittedOwner() async throws {
        let original = session(owner: UUID(), operation: 1)
        var current = original
        let targets = (1...3).map { target($0) }
        let rows = try await TrackerSeriesCollection.load(targets: targets, isAuthorized: { true },
            resolve: { try self.resolve($0) }, read: { _ in nil }, onUpdate: { _, _, _ in })
        var committed: [TrackerLibrarySession: [Int]] = [:]
        var published: [Int] = []
        do {
            _ = try await TrackerSeriesCollection.addAll(rows: rows,
                isAuthorized: { original.authorizes(current, enabled: true, isKids: false) },
                resolve: { try self.resolve($0) },
                add: { candidate in
                    try await TrackerCollectionAddition.perform(
                        isAuthorized: { original.authorizes(current, enabled: true, isKids: false) },
                        read: { nil }, write: {
                            committed[original, default: []].append(candidate.mediaID)
                            return candidate
                        })
                }, onUpdate: { values, count, _ in
                    published.append(count)
                    XCTAssertTrue(values[0].confirmedByAction)
                    current = self.session(owner: UUID(), operation: 2)
                    current = self.session(owner: original.owner, operation: 3)
                })
            XCTFail("Returning to the original profile must not reauthorize the action")
        } catch is CancellationError {}
        XCTAssertEqual(committed[original], [1])
        XCTAssertEqual(committed.count, 1)
        XCTAssertNil(committed[current])
        XCTAssertEqual(published, [1])
    }

    @MainActor
    func testCancellationAfterRemoteCommitStopsRemainingAndDiscardsPendingUIResult() async throws {
        let rows = try await TrackerSeriesCollection.load(targets: (1...3).map { target($0) },
            isAuthorized: { true }, resolve: { try self.resolve($0) }, read: { _ in nil }, onUpdate: { _, _, _ in })
        var committed: [Int] = []
        var updates = 0
        let operation = Task { @MainActor in
            try await TrackerSeriesCollection.addAll(rows: rows, isAuthorized: { true },
                resolve: { try self.resolve($0) },
                add: { candidate in
                    try await TrackerCollectionAddition.perform(isAuthorized: { true }, read: { nil }, write: {
                        committed.append(candidate.mediaID)
                        withUnsafeCurrentTask { $0?.cancel() }
                        return candidate
                    })
                }, onUpdate: { _, _, _ in updates += 1 })
        }
        do {
            _ = try await operation.value
            XCTFail("Cancellation must stop the remaining seasons")
        } catch is CancellationError {}
        XCTAssertEqual(committed, [1])
        XCTAssertEqual(updates, 0)
    }

    private func target(_ id: Int, title: String? = nil) -> TrackerCollectionTarget {
        .init(title: title ?? "Season \(id)", kind: .show, aniListID: id, malID: id + 100, tmdbID: 123542)
    }

    private func resolve(_ target: TrackerCollectionTarget, service: TrackerService = .anilist,
                         unknownTotalID: Int? = nil) throws -> TrackerLibraryEntry {
        guard target.hasExactIdentity(for: service),
              let id = service == .anilist ? target.aniListID : target.malID else { throw TrackerLibraryError.noMatch }
        return TrackerLibraryEntry(service: service, kind: .anime, mediaID: id, entryID: nil,
            aniListID: target.aniListID, malID: target.malID, title: target.title, alternateTitles: [],
            coverLarge: nil, coverMedium: nil, total: id == unknownTotalID ? nil : 12, genres: [], averageScore: nil,
            status: .planning, progress: 0, score: 0, updatedAt: nil, tmdbID: target.tmdbID)
    }

    private func session(owner: UUID, operation: UInt64) -> TrackerLibrarySession {
        .init(owner: owner, operationGeneration: operation, accountGeneration: 1, serviceGeneration: 1,
              service: .anilist, userID: "fixture-account")
    }
}
