import XCTest
import Foundation
import Network
import CryptoKit
import zlib

#if os(macOS)
@testable import EclipseMac
#else
@testable import Eclipse
#endif

private enum ProxyFlowFixtureBody {
    case media
    case probe
    case oversizedPlaylist
    case tinyChunks
    case gzip

    private static let compressionPattern: [UInt8] = {
        var state: UInt32 = 0xEC11
        return (0..<16_384).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
    }()

    var path: String {
        switch self {
        case .media, .tinyChunks, .gzip: return "/video.ts"
        case .probe: return "/stream"
        case .oversizedPlaylist: return "/playlist.m3u8"
        }
    }

    var contentType: String {
        switch self {
        case .media, .tinyChunks, .gzip: return "video/mp2t"
        case .probe: return "application/x-eclipse-unknown"
        case .oversizedPlaylist: return "application/vnd.apple.mpegurl"
        }
    }

    func data(offset: Int, count: Int) -> Data {
        if case .gzip = self {
            return Data((0..<count).map { Self.compressionPattern[(offset + $0) % Self.compressionPattern.count] })
        }
        var result = Data(repeating: UInt8((offset / 65_536) % 251), count: count)
        let prefix: [UInt8]
        switch self {
        case .probe: prefix = Array("#EX".utf8)
        case .oversizedPlaylist: prefix = Array("#EXTM3U\n".utf8)
        default: prefix = []
        }
        for index in 0..<min(count, max(0, prefix.count - offset)) {
            result[index] = prefix[offset + index]
        }
        return result
    }

    func digest(start: Int = 0, count: Int) -> Data {
        var hasher = SHA256()
        var offset = start
        let end = start + count
        while offset < end {
            let length = min(end - offset, 65_536 - offset % 65_536)
            hasher.update(data: data(offset: offset, count: length))
            offset += length
        }
        return Data(hasher.finalize())
    }
}

private final class ProxyFlowFixtureServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mpv.proxy.flow.fixture.server")
    private let lock = NSLock()
    private let ready: XCTestExpectation
    private let body: ProxyFlowFixtureBody
    private let totalBytes: Int
    private let compressedBody: Data?
    private var redirectResponsesRemaining: Int
    private var rateLimitResponsesRemaining: Int
    private var connections: [UUID: NWConnection] = [:]
    private var activeCount = 0
    private var listenerPort: UInt16?

    init(body: ProxyFlowFixtureBody, totalBytes: Int, ready: XCTestExpectation,
         redirects: Int = 0, rateLimits: Int = 0) throws {
        self.body = body
        self.totalBytes = totalBytes
        self.ready = ready
        redirectResponsesRemaining = redirects
        rateLimitResponsesRemaining = rateLimits
        if case .gzip = body {
            compressedBody = try Self.compress(body: body, bytes: totalBytes)
        } else {
            compressedBody = nil
        }
        listener = try NWListener(using: .tcp, on: .any)
    }

    private static func compress(body: ProxyFlowFixtureBody, bytes: Int) throws -> Data {
        var stream = z_stream()
        let initialized = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8,
            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw NSError(domain: "ProxyFlowGzipFixture", code: Int(initialized)) }
        defer { deflateEnd(&stream) }
        var result = Data()
        var scratch = [UInt8](repeating: 0, count: 65_536)
        var offset = 0
        while offset < bytes {
            let count = min(65_536, bytes - offset)
            let input = body.data(offset: offset, count: count)
            let succeeded = input.withUnsafeBytes { source -> Bool in
                guard let base = source.bindMemory(to: Bytef.self).baseAddress else { return false }
                stream.next_in = UnsafeMutablePointer(mutating: base)
                stream.avail_in = uInt(count)
                while stream.avail_in > 0 {
                    let status = scratch.withUnsafeMutableBufferPointer { buffer -> Int32 in
                        stream.next_out = buffer.baseAddress
                        stream.avail_out = uInt(buffer.count)
                        return deflate(&stream, Z_NO_FLUSH)
                    }
                    guard status == Z_OK else { return false }
                    result.append(contentsOf: scratch.prefix(scratch.count - Int(stream.avail_out)))
                }
                return true
            }
            guard succeeded else { throw NSError(domain: "ProxyFlowGzipFixture", code: 1) }
            offset += count
        }
        while true {
            let status = scratch.withUnsafeMutableBufferPointer { buffer -> Int32 in
                stream.next_in = nil
                stream.avail_in = 0
                stream.next_out = buffer.baseAddress
                stream.avail_out = uInt(buffer.count)
                return deflate(&stream, Z_FINISH)
            }
            result.append(contentsOf: scratch.prefix(scratch.count - Int(stream.avail_out)))
            if status == Z_STREAM_END { return result }
            guard status == Z_OK else { throw NSError(domain: "ProxyFlowGzipFixture", code: Int(status)) }
        }
    }

    var port: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return listenerPort
    }

    var activeConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeCount
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.lock.lock()
                self.listenerPort = self.listener.port?.rawValue
                self.lock.unlock()
                self.ready.fulfill()
            } else if case .failed = state {
                self.ready.fulfill()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            self.connections[id] = connection
            self.updateActiveCount()
            connection.start(queue: self.queue)
            self.readRequest(connection, id: id, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            let connections = Array(self.connections.values)
            self.connections.removeAll()
            self.updateActiveCount()
            connections.forEach { $0.cancel() }
        }
    }

    private func updateActiveCount() {
        lock.lock()
        activeCount = connections.count
        lock.unlock()
    }

    private func close(_ connection: NWConnection, id: UUID) {
        connections.removeValue(forKey: id)
        updateActiveCount()
        connection.cancel()
    }

    private func readRequest(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, id: id, request: request)
            } else if complete || error != nil || request.count > 65_536 {
                self.close(connection, id: id)
            } else {
                self.readRequest(connection, id: id, accumulated: request)
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, request: Data) {
        let text = String(data: request, encoding: .utf8) ?? ""
        if redirectResponsesRemaining > 0 {
            redirectResponsesRemaining -= 1
            sendTerminalResponse(connection, id: id,
                response: "HTTP/1.1 302 Found\r\nLocation: /delivered.ts\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        if rateLimitResponsesRemaining > 0 {
            rateLimitResponsesRemaining -= 1
            let body = "{\"error\":\"busy\"}"
            sendTerminalResponse(connection, id: id,
                response: "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nRetry-After: 0\r\nConnection: close\r\n\r\n\(body)")
            return
        }
        let head = text.hasPrefix("HEAD ")
        let rangeLine = text.components(separatedBy: "\r\n").first {
            $0.lowercased().hasPrefix("range: bytes=")
        }
        let bounds = rangeLine?.split(separator: "=", maxSplits: 1).last?
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let start = bounds?.first.flatMap { Int($0) } ?? 0
        let requestedEnd = bounds?.last.flatMap { Int($0) } ?? totalBytes - 1
        let end = min(totalBytes - 1, requestedEnd)
        guard start >= 0, end >= start else { close(connection, id: id); return }
        var headers = "HTTP/1.1 \(rangeLine == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: \(body.contentType)\r\nConnection: close\r\n"
        if case .tinyChunks = body {
            headers += "Transfer-Encoding: chunked\r\n"
        } else if let compressedBody {
            headers += "Content-Encoding: gzip\r\nContent-Length: \(compressedBody.count)\r\n"
        } else {
            headers += "Content-Length: \(end - start + 1)\r\n"
        }
        if rangeLine != nil {
            headers += "Content-Range: bytes \(start)-\(end)/\(totalBytes)\r\n"
        }
        headers += "\r\n"
        connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.close(connection, id: id)
                return
            }
            if head {
                self.sendTerminalResponse(connection, id: id, response: "")
                return
            }
            self.monitorClosure(connection, id: id)
            if let compressedBody = self.compressedBody {
                self.sendCompressedBody(connection, id: id, data: compressedBody, offset: 0)
            } else {
                self.sendBody(connection, id: id, offset: start, end: end + 1)
            }
        })
    }

    private func sendTerminalResponse(_ connection: NWConnection, id: UUID, response: String) {
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] _ in self?.close(connection, id: id) })
    }

    private func sendCompressedBody(_ connection: NWConnection, id: UUID, data: Data, offset: Int) {
        guard connections[id] != nil else { return }
        let end = min(data.count, offset + 65_536)
        connection.send(content: Data(data[offset..<end]), isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.close(connection, id: id)
                } else if end == data.count {
                    self.sendTerminalResponse(connection, id: id, response: "")
                } else {
                    self.sendCompressedBody(connection, id: id, data: data, offset: end)
                }
            })
    }

    private func monitorClosure(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            if complete || error != nil {
                self.close(connection, id: id)
            } else {
                self.monitorClosure(connection, id: id)
            }
        }
    }

    private func sendBody(_ connection: NWConnection, id: UUID, offset: Int, end: Int) {
        guard connections[id] != nil else { return }
        guard offset < end else {
            let terminator: Data?
            if case .tinyChunks = body { terminator = Data("0\r\n\r\n".utf8) }
            else { terminator = nil }
            connection.send(content: terminator, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    self?.close(connection, id: id)
                })
            return
        }
        let count: Int
        let data: Data
        if case .tinyChunks = body {
            count = min(1_024, end - offset, 65_536 - offset % 65_536)
            var framed = Data()
            for byte in body.data(offset: offset, count: count) {
                framed.append(Data("1\r\n".utf8))
                framed.append(byte)
                framed.append(Data("\r\n".utf8))
            }
            data = framed
        } else {
            count = min(end - offset, 65_536 - offset % 65_536)
            data = body.data(offset: offset, count: count)
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.close(connection, id: id)
            } else {
                self.sendBody(connection, id: id, offset: offset + count, end: end)
            }
        })
    }
}

private final class ProxyFlowFixtureClient {
    struct Result {
        let status: Int?
        let bytes: Int
        let digest: Data
        let error: String?
    }

    private let queue = DispatchQueue(label: "mpv.proxy.flow.fixture.client")
    private let lock = NSLock()
    private let completed: XCTestExpectation
    private let headersReceived: XCTestExpectation?
    private var connection: NWConnection?
    private var paused: Bool
    private var receiving = false
    private var headerBuffer = Data()
    private var parsedHeaders = false
    private var status: Int?
    private var byteCount = 0
    private var hasher = SHA256()
    private var finished = false
    private var storedResult: Result?

    init(paused: Bool, headersReceived: XCTestExpectation? = nil, completed: XCTestExpectation) {
        self.paused = paused
        self.headersReceived = headersReceived
        self.completed = completed
    }

    var result: Result? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    func start(url: URL, range: String? = nil, method: String = "GET") throws {
        let portValue = try XCTUnwrap(url.port)
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(portValue)))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var path = components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?\(query)" }
        var request = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\nConnection: close\r\n"
        if let range { request += "Range: \(range)\r\n" }
        request += "\r\n"
        let requestBytes = Data(request.utf8)
        queue.async {
            let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.finish(error: String(describing: error)) }
            }
            connection.start(queue: self.queue)
            connection.send(content: requestBytes, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { self.finish(error: String(describing: error)) }
                else { self.receiveNext() }
            })
        }
    }

    func resume() {
        queue.async {
            self.paused = false
            self.receiveNext()
        }
    }

    func cancel() {
        queue.async { self.finish(error: "cancelled") }
    }

    private func receiveNext() {
        guard !finished, !receiving, !paused || !parsedHeaders, let connection else { return }
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            self.receiving = false
            if let data { self.consume(data) }
            if let error { self.finish(error: String(describing: error)) }
            else if complete { self.finish(error: nil) }
            else { self.receiveNext() }
        }
    }

    private func consume(_ data: Data) {
        if !parsedHeaders {
            headerBuffer.append(data)
            guard let range = headerBuffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let header = String(data: headerBuffer[..<range.lowerBound], encoding: .utf8) ?? ""
            status = header.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) }
            let body = Data(headerBuffer[range.upperBound...])
            headerBuffer = Data()
            parsedHeaders = true
            byteCount += body.count
            hasher.update(data: body)
            headersReceived?.fulfill()
        } else {
            byteCount += data.count
            hasher.update(data: data)
        }
    }

    private func finish(error: String?) {
        guard !finished else { return }
        finished = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let result = Result(status: status, bytes: byteCount, digest: Data(hasher.finalize()), error: error)
        lock.lock()
        storedResult = result
        lock.unlock()
        completed.fulfill()
    }
}

private final class ProxyFlowCapture {
    private let lock = NSLock()
    private var flows: [MPVHeaderProxyFlowControl] = []

    func append(_ flow: MPVHeaderProxyFlowControl) {
        lock.lock()
        flows.append(flow)
        lock.unlock()
    }

    var all: [MPVHeaderProxyFlowControl] {
        lock.lock()
        defer { lock.unlock() }
        return flows
    }
}

private final class ProxyFlowTaskDouble: URLSessionDataTask, @unchecked Sendable {
    private var currentState: URLSessionTask.State = .running
    private(set) var suspensions = 0
    private(set) var resumptions = 0

    override var state: URLSessionTask.State { currentState }

    override func suspend() {
        suspensions += 1
        currentState = .suspended
    }

    override func resume() {
        resumptions += 1
        currentState = .running
    }
}

final class MPVHeaderProxyFlowControlTests: XCTestCase {
    func testBufferedResponseCanContinueAboveStreamingResumeWatermark() {
        let flow = MPVHeaderProxyFlowControl(pinned: false)
        let task = ProxyFlowTaskDouble()
        flow.attach(task)
        for _ in 0..<8 {
            XCTAssertEqual(flow.admit(640 * 1_024), .accepted)
        }
        XCTAssertEqual(task.suspensions, 1)
        for _ in 0..<8 {
            flow.release(0, allowingBufferedProgress: true)
        }
        XCTAssertEqual(flow.snapshot.bytes, 5 * 1_024 * 1_024)
        XCTAssertEqual(task.resumptions, 1)
        XCTAssertEqual(flow.admit(65_536), .accepted)
        flow.release(5 * 1_024 * 1_024 + 65_536)
        XCTAssertEqual(flow.snapshot.bytes, 0)
        XCTAssertEqual(flow.snapshot.chunks, 0)
    }

    func testNativeStalledReaderResumesWithoutBlockingParallelRange() throws {
        try exerciseStalledReader(pinned: false)
    }

    func testPinnedStalledReaderResumesWithoutBlockingParallelRange() throws {
        try exerciseStalledReader(pinned: true)
    }

    func testCancellationAndInvalidationClosePausedNativeAndPinnedUpstreams() throws {
        for pinned in [false, true] {
            for invalidating in [false, true] {
                try exercisePausedCancellation(pinned: pinned, invalidating: invalidating)
            }
        }
    }

    func testTinyChunkedBodiesAndProbeTransitionsPreserveAllBytes() throws {
        for pinned in [false, true] {
            try exerciseBody(pinned: pinned, body: .tinyChunks, bytes: 4_096)
            try exerciseBody(pinned: pinned, body: .probe, bytes: 2 * 1_024 * 1_024)
        }
    }

    func testOversizedOrdinaryPlaylistStillStreamsOriginalBody() throws {
        for pinned in [false, true] {
            try exerciseBody(pinned: pinned, body: .oversizedPlaylist, bytes: 6 * 1_024 * 1_024)
        }
    }

    func testGzipExpansionDrainsEveryBufferedSlice() throws {
        for pinned in [false, true] {
            try exerciseBody(pinned: pinned, body: .gzip, bytes: 6 * 1_024 * 1_024)
        }
    }

    func testRedirectKeepsFlowAndRateLimitRetryCreatesFreshFlow() throws {
        for pinned in [false, true] {
            for retrying in [false, true] {
                let bytes = 2 * 1_024 * 1_024
                let (server, proxy, url, capture) = try makeFixture(pinned: pinned, body: .media,
                    bytes: bytes, redirects: retrying ? 0 : 1, rateLimits: retrying ? 1 : 0)
                defer { proxy.invalidateSession(for: url); proxy.shutdownForTesting(); server.stop() }
                let completed = expectation(description: "Redirect or retry response completes")
                let client = ProxyFlowFixtureClient(paused: false, completed: completed)
                defer { client.cancel() }
                try client.start(url: url)
                wait(for: [completed], timeout: 20)
                let result = try XCTUnwrap(client.result)
                XCTAssertNil(result.error)
                XCTAssertEqual(result.status, 200)
                XCTAssertEqual(result.bytes, bytes)
                XCTAssertEqual(result.digest, ProxyFlowFixtureBody.media.digest(count: bytes))
                XCTAssertEqual(capture.all.count, retrying ? 2 : 1)
                XCTAssertTrue(capture.all.allSatisfy { $0.snapshot.closed })
                if retrying, capture.all.count == 2 {
                    XCTAssertFalse(capture.all[0] === capture.all[1])
                }
            }
        }
    }

    func testHeadAndShortUnknownRootEOFKeepResponseFraming() throws {
        for pinned in [false, true] {
            try exerciseBody(pinned: pinned, body: .probe, bytes: 3)
            let (server, proxy, url, capture) = try makeFixture(pinned: pinned, body: .media, bytes: 1_024)
            defer { proxy.invalidateSession(for: url); proxy.shutdownForTesting(); server.stop() }
            let completed = expectation(description: "HEAD completes without receiving a body")
            let client = ProxyFlowFixtureClient(paused: false, completed: completed)
            defer { client.cancel() }
            try client.start(url: url, method: "HEAD")
            wait(for: [completed], timeout: 10)
            let result = try XCTUnwrap(client.result)
            XCTAssertNil(result.error)
            XCTAssertEqual(result.status, 200)
            XCTAssertEqual(result.bytes, 0)
            XCTAssertEqual(capture.all.first?.snapshot.peakBytes, 0)
        }
    }

    func testNativeTaskSuspensionStaysBalancedAcrossPressureCycles() {
        let task = ProxyFlowTaskDouble()
        let flow = MPVHeaderProxyFlowControl(pinned: false)
        flow.attach(task)
        let bytes = 1_024 * 1_024
        for _ in 0..<8 { XCTAssertEqual(flow.admit(bytes), .accepted) }
        XCTAssertEqual(task.suspensions, 1)
        XCTAssertEqual(task.resumptions, 0)
        for _ in 0..<3 { flow.release(bytes) }
        XCTAssertEqual(task.resumptions, 0)
        flow.release(bytes)
        XCTAssertEqual(task.resumptions, 1)
        for _ in 0..<4 { XCTAssertEqual(flow.admit(bytes), .accepted) }
        XCTAssertEqual(task.suspensions, 2)
        for _ in 0..<8 { flow.release(bytes) }
        XCTAssertEqual(task.resumptions, 2)
        XCTAssertEqual(flow.snapshot.bytes, 0)
        XCTAssertEqual(flow.snapshot.chunks, 0)
        flow.close()
        flow.release(0)
        XCTAssertEqual(task.resumptions, 2)
    }

    func testPinnedCreditsSurviveSplitDelegateDeliveryAndWakeAfterDrain() {
        let flow = MPVHeaderProxyFlowControl(pinned: true)
        XCTAssertTrue(flow.reserveProducerBytes(65_536, whenAvailable: {}))
        XCTAssertEqual(flow.admit(16_384), .accepted)
        var awakened = false
        XCTAssertFalse(flow.reserveProducerBytes(65_536, whenAvailable: { awakened = true }))
        flow.release(16_384)
        XCTAssertFalse(awakened)
        XCTAssertEqual(flow.admit(49_152), .accepted)
        XCTAssertTrue(awakened)
        flow.release(49_152)
        XCTAssertEqual(flow.snapshot.bytes, 0)
        XCTAssertEqual(flow.snapshot.chunks, 0)
    }

    func testNativeOverflowCannotAccumulateUnboundedQueuedData() {
        let flow = MPVHeaderProxyFlowControl(pinned: false)
        let chunk = 1_024 * 1_024
        for _ in 0..<32 { XCTAssertEqual(flow.admit(chunk), .accepted) }
        XCTAssertEqual(flow.admit(1), .overflow)
        XCTAssertEqual(flow.snapshot.bytes, MPVHeaderProxyFlowControl.maximumOverflowBytes)
        flow.close()
        XCTAssertEqual(flow.admit(chunk), .closed)
    }

    private func makeFixture(pinned: Bool, body: ProxyFlowFixtureBody, bytes: Int,
                             redirects: Int = 0, rateLimits: Int = 0) throws ->
        (ProxyFlowFixtureServer, MPVHeaderProxy, URL, ProxyFlowCapture) {
        let ready = expectation(description: "Upstream listener becomes ready")
        let server = try ProxyFlowFixtureServer(body: body, totalBytes: bytes, ready: ready,
            redirects: redirects, rateLimits: rateLimits)
        server.start()
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(server.port)
        let upstream = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(body.path)"))
        let proxy = MPVHeaderProxy.testingInstance(pinnedLoopbackTransport: pinned)
        let capture = ProxyFlowCapture()
        proxy.flowControlCreatedForTesting = { capture.append($0) }
        let url = try XCTUnwrap(proxy.makeProxyURL(for: upstream, headers: [:],
            logType: "MPVProxyTest", traceID: "flow-control-regression"))
        return (server, proxy, url, capture)
    }

    private func waitForPressure(_ capture: ProxyFlowCapture) {
        let pressure = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let flow = capture.all.first else { return false }
            let snapshot = flow.snapshot
            return snapshot.chunks >= MPVHeaderProxyFlowControl.maximumChunks
                || snapshot.bytes >= MPVHeaderProxyFlowControl.maximumBytes
        }, object: nil)
        wait(for: [pressure], timeout: 10)
    }

    private func exerciseStalledReader(pinned: Bool) throws {
        let size = 64 * 1_024 * 1_024
        let (server, proxy, url, capture) = try makeFixture(pinned: pinned, body: .media, bytes: size)
        defer { proxy.invalidateSession(for: url); proxy.shutdownForTesting(); server.stop() }
        let headers = expectation(description: "Paused reader receives headers")
        let completed = expectation(description: "Resumed reader drains full response")
        let client = ProxyFlowFixtureClient(paused: true, headersReceived: headers, completed: completed)
        defer { client.cancel() }
        try client.start(url: url)
        wait(for: [headers], timeout: 10)
        waitForPressure(capture)

        let parallelDone = expectation(description: "Parallel range completes while original reader is paused")
        let parallel = ProxyFlowFixtureClient(paused: false, completed: parallelDone)
        defer { parallel.cancel() }
        let rangeStart = 123_456
        let rangeEnd = 189_000
        try parallel.start(url: url, range: "bytes=\(rangeStart)-\(rangeEnd)")
        wait(for: [parallelDone], timeout: 10)
        let range = try XCTUnwrap(parallel.result)
        XCTAssertNil(range.error)
        XCTAssertEqual(range.status, 206)
        XCTAssertEqual(range.bytes, rangeEnd - rangeStart + 1)
        XCTAssertEqual(range.digest, ProxyFlowFixtureBody.media.digest(start: rangeStart, count: rangeEnd - rangeStart + 1))

        let stalled = expectation(description: "Reader remains stalled while upstream applies pressure")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { stalled.fulfill() }
        wait(for: [stalled], timeout: 3)
        let flow = try XCTUnwrap(capture.all.first)
        XCTAssertFalse(flow.snapshot.closed)
        XCTAssertLessThanOrEqual(flow.snapshot.peakBytes,
            pinned ? MPVHeaderProxyFlowControl.maximumBytes : MPVHeaderProxyFlowControl.maximumOverflowBytes)
        XCTAssertLessThanOrEqual(flow.snapshot.peakChunks, MPVHeaderProxyFlowControl.maximumOverflowChunks)

        client.resume()
        wait(for: [completed], timeout: 40)
        let result = try XCTUnwrap(client.result)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.bytes, size)
        XCTAssertEqual(result.digest, ProxyFlowFixtureBody.media.digest(count: size))
    }

    private func exercisePausedCancellation(pinned: Bool, invalidating: Bool) throws {
        let (server, proxy, url, capture) = try makeFixture(pinned: pinned, body: .media, bytes: 64 * 1_024 * 1_024)
        defer { proxy.invalidateSession(for: url); proxy.shutdownForTesting(); server.stop() }
        let headers = expectation(description: "Reader receives headers before cancellation")
        let completed = expectation(description: "Canceled reader finishes")
        let client = ProxyFlowFixtureClient(paused: true, headersReceived: headers, completed: completed)
        defer { client.cancel() }
        try client.start(url: url)
        wait(for: [headers], timeout: 10)
        waitForPressure(capture)
        if invalidating { proxy.invalidateSession(for: url) }
        else { client.cancel() }
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.activeConnections == 0 && capture.all.first?.snapshot.closed == true
        }, object: nil)
        wait(for: [closed], timeout: 10)
        client.cancel()
        wait(for: [completed], timeout: 3)
    }

    private func exerciseBody(pinned: Bool, body: ProxyFlowFixtureBody, bytes: Int) throws {
        let (server, proxy, url, _) = try makeFixture(pinned: pinned, body: body, bytes: bytes)
        defer { proxy.invalidateSession(for: url); proxy.shutdownForTesting(); server.stop() }
        let completed = expectation(description: "Body finishes with preserved framing")
        let client = ProxyFlowFixtureClient(paused: false, completed: completed)
        defer { client.cancel() }
        try client.start(url: url)
        wait(for: [completed], timeout: 30)
        let result = try XCTUnwrap(client.result)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.bytes, bytes)
        XCTAssertEqual(result.digest, body.digest(count: bytes))
    }
}
