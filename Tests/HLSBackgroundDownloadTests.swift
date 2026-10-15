#if os(iOS) && !targetEnvironment(macCatalyst) && DEBUG
import Foundation
import XCTest
@testable import Eclipse

@MainActor
final class HLSBackgroundDownloadTests: XCTestCase {
    func testBackgroundSettingDefaultsOffInIsolatedDefaults() throws {
        let name = "HLSBackgroundDownloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(HLSBackgroundDownloadSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: HLSBackgroundDownloadSettings.enabledKey)
        XCTAssertTrue(HLSBackgroundDownloadSettings.isEnabled(defaults: defaults))
        defaults.set(false, forKey: HLSBackgroundDownloadSettings.enabledKey)
        XCTAssertFalse(HLSBackgroundDownloadSettings.isEnabled(defaults: defaults))
    }

    func testDisabledSettingKeepsForegroundDownloaderAndSubmitsNoBackgroundRequest() async throws {
        let fixture = try HLSBackgroundFixture(enabled: false)
        do {
            try fixture.start()
            try await eventually { fixture.heldCount == 1 }
            XCTAssertTrue(fixture.scheduler.requests.isEmpty)
            XCTAssertEqual(fixture.item.status, .downloading)
            fixture.release()
            try await eventually { fixture.item.status == .completed }
            XCTAssertEqual(try fixture.completedData(), Data("AABBCC".utf8))
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testRejectedBackgroundRequestLeavesForegroundDownloadWorking() async throws {
        let fixture = try HLSBackgroundFixture(mode: .reject)
        do {
            try fixture.start()
            try await eventually { fixture.heldCount == 1 && fixture.scheduler.requests.count == 1 }
            XCTAssertEqual(fixture.item.status, .downloading)
            XCTAssertEqual(fixture.scheduler.grantResults, [])
            fixture.release()
            try await eventually { fixture.item.status == .completed }
            XCTAssertEqual(try fixture.completedData(), Data("AABBCC".utf8))
            XCTAssertTrue(fixture.scheduler.finishes.isEmpty)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testForegroundExpirationPausesOnceWithoutAutomaticRestart() async throws {
        let fixture = try HLSBackgroundFixture(mode: .grant)
        do {
            try fixture.start()
            try await eventually { fixture.heldCount == 1 && fixture.scheduler.grantResults == [true] }
            fixture.scheduler.expire(0)
            fixture.scheduler.expire(0)
            try await eventually { fixture.scheduler.finishes.count == 1 && fixture.heldCount == 0 }
            await fixture.manager.drainIsolatedHLSWorkers()
            XCTAssertEqual(fixture.item.status, .paused)
            XCTAssertEqual(fixture.item.hlsResumeSegmentIndex, 2)
            XCTAssertEqual(fixture.item.hlsResumeByteCount, 4)
            XCTAssertTrue(fixture.item.hasVerifiedHLSCheckpoint)
            XCTAssertEqual(fixture.scheduler.finishes.map(\.success), [false])
            let requests = fixture.requestedPaths
            fixture.manager.applicationDidBecomeActive()
            fixture.manager.applyQueueSettingsChanged()
            await fixture.manager.drainIsolatedPersistence()
            XCTAssertEqual(fixture.item.status, .paused)
            XCTAssertEqual(fixture.requestedPaths, requests)
            XCTAssertEqual(fixture.scheduler.requests.count, 1)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testGrantedWorkerCompletesAfterBackgrounding() async throws {
        let fixture = try HLSBackgroundFixture(mode: .grant)
        do {
            try fixture.start()
            try await eventually { fixture.heldCount == 1 && fixture.scheduler.grantResults == [true] }
            fixture.foreground = false
            fixture.manager.applicationDidEnterBackground()
            XCTAssertEqual(fixture.item.status, .downloading)
            XCTAssertEqual(fixture.heldCount, 1)
            fixture.release()
            try await eventually { fixture.item.status == .completed && fixture.scheduler.finishes.count == 1 }
            XCTAssertEqual(fixture.scheduler.finishes.map(\.success), [true])
            XCTAssertEqual(try fixture.completedData(), Data("AABBCC".utf8))
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testToggleOffRejectsLateGrantAndPreservesForegroundWork() async throws {
        let fixture = try HLSBackgroundFixture(mode: .hold)
        do {
            try fixture.start()
            try await eventually { fixture.heldCount == 1 && fixture.scheduler.requests.count == 1 }
            fixture.enabled = false
            fixture.manager.applyHLSBackgroundDownloadsSettingChanged()
            XCTAssertFalse(fixture.scheduler.grant(0))
            try await eventually { fixture.scheduler.finishes.count == 1 }
            XCTAssertEqual(fixture.item.status, .downloading)
            fixture.release()
            try await eventually { fixture.item.status == .completed }
            XCTAssertEqual(try fixture.completedData(), Data("AABBCC".utf8))
            XCTAssertEqual(fixture.scheduler.requests.count, 1)
            XCTAssertEqual(fixture.scheduler.finishes.map(\.success), [false])
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testLateGrantAfterRemovalCannotResurrectDownload() async throws {
        let fixture = try HLSBackgroundFixture(mode: .hold)
        do {
            try fixture.start()
            try await eventually { fixture.heldCount == 1 && fixture.scheduler.requests.count == 1 }
            fixture.manager.cancelDownload(id: fixture.itemID)
            await fixture.manager.drainIsolatedHLSWorkers()
            try await eventually { fixture.scheduler.finishes.count == 1 && fixture.heldCount == 0 }
            let paths = fixture.requestedPaths
            XCTAssertFalse(fixture.scheduler.grant(0))
            fixture.manager.applicationDidBecomeActive()
            await fixture.manager.drainIsolatedPersistence()
            XCTAssertTrue(fixture.manager.downloads.isEmpty)
            XCTAssertEqual(fixture.requestedPaths, paths)
            XCTAssertEqual(fixture.heldCount, 0)
            XCTAssertEqual(fixture.scheduler.finishes.map(\.success), [false])
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testLateGrantAfterPauseCannotRestartDownload() async throws {
        let fixture = try HLSBackgroundFixture(mode: .hold)
        do {
            try fixture.start()
            try await eventually { fixture.heldCount == 1 && fixture.scheduler.requests.count == 1 }
            fixture.manager.pauseDownload(id: fixture.itemID)
            await fixture.manager.drainIsolatedHLSWorkers()
            try await eventually { fixture.scheduler.finishes.count == 1 && fixture.heldCount == 0 }
            let paths = fixture.requestedPaths
            XCTAssertFalse(fixture.scheduler.grant(0))
            fixture.manager.applicationDidBecomeActive()
            fixture.manager.applyQueueSettingsChanged()
            await fixture.manager.drainIsolatedPersistence()
            XCTAssertEqual(fixture.item.status, .paused)
            XCTAssertEqual(fixture.requestedPaths, paths)
            XCTAssertEqual(fixture.heldCount, 0)
            XCTAssertEqual(fixture.scheduler.requests.count, 1)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testToggleOffAfterGrantKeepsForegroundWorkerWithoutGrantAuthority() async throws {
        let fixture = try HLSBackgroundFixture(mode: .grant)
        do {
            try fixture.start()
            try await eventually { fixture.heldCount == 1 && fixture.scheduler.grantResults == [true] }
            fixture.enabled = false
            fixture.manager.applyHLSBackgroundDownloadsSettingChanged()
            try await eventually { fixture.scheduler.finishes.count == 1 }
            XCTAssertEqual(fixture.item.status, .downloading)
            XCTAssertEqual(fixture.heldCount, 1)
            XCTAssertFalse(fixture.scheduler.grant(0))
            XCTAssertEqual(fixture.scheduler.grantResults, [true, false])
            fixture.release()
            try await eventually { fixture.item.status == .completed }
            XCTAssertEqual(try fixture.completedData(), Data("AABBCC".utf8))
            XCTAssertEqual(fixture.scheduler.requests.count, 1)
            XCTAssertEqual(fixture.scheduler.finishes.map(\.success), [false])
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testExpirationAfterBackgroundingPausesAndDoesNotRestartOnForegroundReturn() async throws {
        let fixture = try HLSBackgroundFixture(mode: .grant)
        do {
            try fixture.start()
            try await eventually { fixture.heldCount == 1 && fixture.scheduler.grantResults == [true] }
            fixture.foreground = false
            fixture.manager.applicationDidEnterBackground()
            fixture.scheduler.expire(0)
            try await eventually { fixture.scheduler.finishes.count == 1 && fixture.heldCount == 0 }
            await fixture.manager.drainIsolatedHLSWorkers()
            XCTAssertEqual(fixture.item.status, .paused)
            XCTAssertTrue(fixture.item.hasVerifiedHLSCheckpoint)
            XCTAssertEqual(fixture.scheduler.finishes.map(\.success), [false])
            let paths = fixture.requestedPaths
            fixture.foreground = true
            fixture.manager.applicationDidBecomeActive()
            await fixture.manager.drainIsolatedPersistence()
            XCTAssertEqual(fixture.item.status, .paused)
            XCTAssertEqual(fixture.requestedPaths, paths)
            XCTAssertEqual(fixture.scheduler.requests.count, 1)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testStartupQueueDoesNotMintForegroundBackgroundIntent() async throws {
        let fixture = try HLSBackgroundFixture(mode: .grant, initialStatus: .queued)
        do {
            fixture.manager.applicationDidBecomeActive()
            try fixture.checkEnvironmentalDelay()
            try await eventually { fixture.heldCount == 1 }
            XCTAssertTrue(fixture.scheduler.requests.isEmpty)
            fixture.release()
            try await eventually { fixture.item.status == .completed }
            XCTAssertTrue(fixture.scheduler.requests.isEmpty)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testUnverifiedLivePlaylistNeverSubmitsBackgroundRequest() async throws {
        let fixture = try HLSBackgroundFixture(mode: .grant, finitePlaylist: false)
        do {
            try fixture.start()
            try await eventually { fixture.heldCount == 1 }
            XCTAssertNil(fixture.item.hlsResumeManifestSHA256)
            XCTAssertTrue(fixture.scheduler.requests.isEmpty)
            fixture.release()
            try await eventually { fixture.item.status == .completed }
            XCTAssertEqual(try fixture.completedData(), Data("AABBCC".utf8))
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testImmediatePauseResumeWithFourSlotsNeverOverlapsSegmentWriters() async throws {
        let fixture = try HLSBackgroundFixture(mode: .grant, hlsLimit: 4)
        do {
            try fixture.start()
            try await eventually { fixture.heldCount == 1 && fixture.item.hlsResumeSegmentIndex == 2 }
            fixture.manager.pauseDownload(id: fixture.itemID)
            fixture.manager.resumeDownload(id: fixture.itemID)
            try await eventually {
                fixture.playlistRequestCount == 2 && fixture.heldCount == 1
                    && fixture.scheduler.requests.count == 2 && fixture.scheduler.grantResults == [true, true]
            }
            XCTAssertEqual(fixture.maximumHeldCount, 1)
            XCTAssertEqual(fixture.requestedPaths.filter { $0 == "/first.ts" }.count, 1)
            XCTAssertEqual(fixture.requestedPaths.filter { $0 == "/second.ts" }.count, 1)
            fixture.release()
            try await eventually { fixture.item.status == .completed }
            XCTAssertEqual(try fixture.completedData(), Data("AABBCC".utf8))
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testCompletedDurableReceiptRecoversOnRelaunchWithSettingOffBeforeNetwork() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("recovered.ts")
        try Data("AABBCC".utf8).write(to: output)
        var item = recoveryItem(id: "recovered", reservation: "recovered.ts")
        item.status = .queued
        let bytes = try JSONEncoder().encode([item])
        try bytes.write(to: root.appendingPathComponent(".downloads_metadata.json"))
        let scheduler = HLSBackgroundSchedulerMock(mode: .grant)
        var started = 0
        let manager = DownloadManager(downloadsDirectory: root, initialDownloads: [], transportMayStart: { false },
            refreshSource: { _ in XCTFail("Recovery must precede provider refresh"); return nil },
            transferStarter: { _ in started += 1 }, loadPersistedMetadata: true)
        manager.configureHLSBackgroundForTesting(scheduler: scheduler, enabled: { false }, applicationIsActive: { false },
            sessionConfiguration: .ephemeral)
        manager.applicationDidBecomeActive()
        await manager.drainIsolatedPersistence()
        let recovered = try XCTUnwrap(manager.downloads.first)
        XCTAssertEqual(recovered.status, .completed)
        XCTAssertEqual(recovered.localFileName, "recovered.ts")
        XCTAssertEqual(recovered.progress, 1)
        XCTAssertEqual(recovered.downloadedBytes, 6)
        XCTAssertNil(recovered.hlsDurableCheckpoint)
        XCTAssertEqual(started, 0)
        XCTAssertTrue(scheduler.requests.isEmpty)
        XCTAssertEqual(manager.localFileURL(for: recovered), output)
        manager.finishIsolatedSession()
        await manager.drainIsolatedHLSWorkers()
        try? FileManager.default.removeItem(at: root)
    }

    func testDurableReceiptRecoveryRefusesWrongSizeIncompleteCheckpointAndCollision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var wrongSize = recoveryItem(id: "wrong-size", reservation: "wrong-size.ts")
        wrongSize.hlsResumeByteCount = 8
        var incomplete = recoveryItem(id: "incomplete", reservation: "incomplete.ts")
        incomplete.hlsResumeSegmentIndex = 2
        let firstCollision = recoveryItem(id: "collision-one", reservation: "collision.ts")
        let secondCollision = recoveryItem(id: "collision-two", reservation: "collision.ts")
        for name in ["wrong-size.ts", "incomplete.ts", "collision.ts"] {
            try Data("AABBCC".utf8).write(to: root.appendingPathComponent(name))
        }
        let manager = DownloadManager(downloadsDirectory: root,
            initialDownloads: [wrongSize, incomplete, firstCollision, secondCollision], transportMayStart: { false },
            refreshSource: { _ in nil }, transferStarter: { _ in XCTFail("Paused recovery candidates must not start") })
        manager.applicationDidBecomeActive()
        XCTAssertTrue(manager.downloads.allSatisfy { $0.status == .paused && $0.localFileName == nil })
        for name in ["wrong-size.ts", "incomplete.ts", "collision.ts"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data("AABBCC".utf8))
        }
        manager.finishIsolatedSession()
        await manager.drainIsolatedHLSWorkers()
        try? FileManager.default.removeItem(at: root)
    }

    func testBackgroundingProtectedItemWithoutGrantKeepsExistingSuspensionBoundary() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var item = recoveryItem(id: "protected-pending", reservation: "protected.ts")
        item.status = .downloading
        item.protectedProviderKind = .service
        item.protectedTransportKind = .hls
        item.protectedOwnerProfileID = ProfileManager.shared.activeProfileID
        item.lastSourceId = "service:hls-background-fixture"
        item.lastContentReference = .service(sourceID: "service:hls-background-fixture", href: "https://provider.example/episode")
        let manager = DownloadManager(downloadsDirectory: root, initialDownloads: [item], transportMayStart: { false },
            refreshSource: { _ in nil }, transferStarter: nil)
        let scheduler = HLSBackgroundSchedulerMock(mode: .hold)
        manager.configureHLSBackgroundForTesting(scheduler: scheduler, enabled: { true }, applicationIsActive: { false },
            sessionConfiguration: .ephemeral)
        manager.applicationDidEnterBackground()
        let suspended = try XCTUnwrap(manager.downloads.first)
        XCTAssertNotEqual(suspended.status, .downloading)
        XCTAssertEqual(suspended.streamURL, "")
        XCTAssertTrue(scheduler.requests.isEmpty)
        manager.finishIsolatedSession()
        await manager.drainIsolatedHLSWorkers()
        try? FileManager.default.removeItem(at: root)
    }

    private func eventually(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard condition() else {
            XCTFail("Expected download lifecycle state was not reached", file: file, line: line)
            throw HLSBackgroundFixtureError.timedOut
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func recoveryItem(id: String, reservation: String) -> DownloadItem {
        var item = HLSBackgroundFixture.makeItem(id: id, streamURL: "https://recovery.invalid/playlist.m3u8", status: .paused)
        item.reservedVideoFileName = reservation
        item.hlsDurableCheckpoint = true
        item.hlsResumeManifestSHA256 = String(repeating: "a", count: 64)
        item.hlsTotalSegments = 3
        item.hlsResumeSegmentIndex = 3
        item.hlsResumeByteCount = 6
        item.hlsVariantURL = item.streamURL
        return item
    }
}

private enum HLSBackgroundFixtureError: Error {
    case timedOut
}

private final class HLSBackgroundSchedulerMock: HLSBackgroundDownloadScheduling {
    enum Mode {
        case hold
        case grant
        case reject
    }

    struct Request {
        let attemptID: UUID
        let onGranted: () -> Bool
        let onExpiration: () -> Void
        let onRejected: () -> Void
    }

    struct Finish {
        let attemptID: UUID
        let success: Bool
    }

    let mode: Mode
    private(set) var requests: [Request] = []
    private(set) var grantResults: [Bool] = []
    private(set) var finishes: [Finish] = []

    init(mode: Mode) { self.mode = mode }

    func request(attemptID: UUID, title: String, onGranted: @escaping () -> Bool, onExpiration: @escaping () -> Void,
                 onRejected: @escaping () -> Void) {
        requests.append(Request(attemptID: attemptID, onGranted: onGranted, onExpiration: onExpiration, onRejected: onRejected))
        switch mode {
        case .hold: break
        case .grant: _ = grant(requests.count - 1)
        case .reject: onRejected()
        }
    }

    @discardableResult
    func grant(_ index: Int) -> Bool {
        guard requests.indices.contains(index) else { return false }
        let granted = requests[index].onGranted()
        grantResults.append(granted)
        return granted
    }

    func expire(_ index: Int) {
        guard requests.indices.contains(index) else { return }
        requests[index].onExpiration()
    }

    func updateProgress(attemptID: UUID, completed: Int64, total: Int64, subtitle: String) { }

    func finish(attemptID: UUID, success: Bool) {
        finishes.append(Finish(attemptID: attemptID, success: success))
    }
}

@MainActor
private final class HLSBackgroundFixture {
    let root: URL
    let host: String
    let itemID = UUID().uuidString
    let scheduler: HLSBackgroundSchedulerMock
    let initialStatus: DownloadStatus
    let hlsLimit: Int
    var enabled: Bool
    var foreground = true
    private let configuration: URLSessionConfiguration
    private(set) lazy var manager: DownloadManager = {
        let value = DownloadManager(downloadsDirectory: root,
            initialDownloads: [Self.makeItem(id: itemID, streamURL: "https://\(host)/playlist.m3u8", status: initialStatus)],
            transportMayStart: { [weak self] in self?.foreground == true }, refreshSource: { _ in nil },
            transferStarter: nil, concurrencyLimit: { 4 }, hlsConcurrencyLimit: { [weak self] in self?.hlsLimit ?? 1 })
        value.configureHLSBackgroundForTesting(scheduler: scheduler, enabled: { [weak self] in self?.enabled == true },
            applicationIsActive: { [weak self] in self?.foreground == true }, sessionConfiguration: configuration)
        return value
    }()

    var item: DownloadItem { manager.downloads.first ?? Self.makeItem(id: itemID, streamURL: "", status: .failed) }
    var heldCount: Int { HLSBackgroundURLProtocol.statistics(host: host).held }
    var maximumHeldCount: Int { HLSBackgroundURLProtocol.statistics(host: host).maximumHeld }
    var requestedPaths: [String] { HLSBackgroundURLProtocol.statistics(host: host).paths }
    var playlistRequestCount: Int { requestedPaths.filter { $0 == "/playlist.m3u8" }.count }

    init(enabled: Bool = true, mode: HLSBackgroundSchedulerMock.Mode = .hold, initialStatus: DownloadStatus = .paused,
         finitePlaylist: Bool = true, hlsLimit: Int = 1) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        host = "hls-background-\(UUID().uuidString.lowercased()).example"
        self.enabled = enabled
        self.initialStatus = initialStatus
        self.hlsLimit = hlsLimit
        scheduler = HLSBackgroundSchedulerMock(mode: mode)
        configuration = .ephemeral
        configuration.protocolClasses = [HLSBackgroundURLProtocol.self]
        HLSBackgroundURLProtocol.register(host: host, playlist: "#EXTM3U\nfirst.ts\nsecond.ts\nthird.ts\n" + (finitePlaylist ? "#EXT-X-ENDLIST" : ""))
    }

    func start() throws {
        manager.resumeDownload(id: itemID)
        try checkEnvironmentalDelay()
    }

    func checkEnvironmentalDelay() throws {
        let reason = item.error ?? ""
        try XCTSkipIf(["Waiting for app to reopen", "Paused for low battery", "Paused for thermal state", "Paused for low disk space"].contains(reason), reason)
    }

    func release() { HLSBackgroundURLProtocol.release(host: host) }

    func completedData() throws -> Data {
        try Data(contentsOf: XCTUnwrap(manager.localFileURL(for: item)))
    }

    func cleanUp() async {
        manager.finishIsolatedSession()
        await manager.drainIsolatedHLSWorkers()
        await manager.drainIsolatedPersistence()
        HLSBackgroundURLProtocol.unregister(host: host)
        try? FileManager.default.removeItem(at: root)
    }

    static func makeItem(id: String, streamURL: String, status: DownloadStatus) -> DownloadItem {
        DownloadItem(id: id, tmdbId: 1_801_400_001, isMovie: true, title: "HLS background fixture", displayTitle: "Fixture",
            posterURL: nil, seasonNumber: nil, episodeNumber: nil, episodeName: nil, streamURL: streamURL,
            headers: [:], subtitleURL: nil, serviceBaseURL: "", status: status, progress: 0, totalBytes: 0,
            downloadedBytes: 0, localFileName: nil, subtitleFileName: nil, error: nil, dateAdded: Date(),
            dateCompleted: nil, isAnime: false)
    }
}

private final class HLSBackgroundURLProtocol: URLProtocol {
    private struct Route {
        let playlist: String
        var holdsLast = true
        var paths: [String] = []
        var held: [UUID: HLSBackgroundURLProtocol] = [:]
        var maximumHeld = 0
    }

    private static let lock = NSLock()
    private static var routes: [String: Route] = [:]
    private let identity = UUID()
    private let deliveryLock = NSLock()
    private var stopped = false

    static func register(host: String, playlist: String) {
        lock.lock()
        routes[host] = Route(playlist: playlist)
        lock.unlock()
    }

    static func unregister(host: String) {
        lock.lock()
        routes.removeValue(forKey: host)
        lock.unlock()
    }

    static func statistics(host: String) -> (held: Int, maximumHeld: Int, paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard let route = routes[host] else { return (0, 0, []) }
        return (route.held.count, route.maximumHeld, route.paths)
    }

    static func release(host: String) {
        lock.lock()
        guard var route = routes[host] else { lock.unlock(); return }
        route.holdsLast = false
        let pending = Array(route.held.values)
        route.held.removeAll()
        routes[host] = route
        lock.unlock()
        for request in pending { request.deliver(Data("CC".utf8)) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        lock.lock()
        defer { lock.unlock() }
        return routes[host] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        Self.lock.lock()
        guard var route = Self.routes[host] else { Self.lock.unlock(); return }
        route.paths.append(url.path)
        let held = route.holdsLast && url.lastPathComponent == "third.ts"
        if held {
            route.held[identity] = self
            route.maximumHeld = max(route.maximumHeld, route.held.count)
        }
        let bytes: Data
        switch url.lastPathComponent {
        case "playlist.m3u8": bytes = Data(route.playlist.utf8)
        case "first.ts": bytes = Data("AA".utf8)
        case "second.ts": bytes = Data("BB".utf8)
        default: bytes = Data("CC".utf8)
        }
        Self.routes[host] = route
        Self.lock.unlock()
        if !held { deliver(bytes) }
    }

    private func deliver(_ bytes: Data) {
        deliveryLock.lock()
        let mayDeliver = !stopped
        deliveryLock.unlock()
        guard mayDeliver, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        deliveryLock.lock()
        stopped = true
        deliveryLock.unlock()
        guard let host = request.url?.host else { return }
        Self.lock.lock()
        Self.routes[host]?.held.removeValue(forKey: identity)
        Self.lock.unlock()
    }
}
#endif
