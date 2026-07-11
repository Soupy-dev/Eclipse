// Sora-JS

import Foundation

enum BoundedURLSessionError: LocalizedError, Equatable {
    case responseTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .responseTooLarge(let maximumBytes):
            return "Response exceeds the maximum size of \(maximumBytes) bytes."
        }
    }
}

/// Accumulates a response without ever accepting a byte beyond the configured
/// limit. Keeping this small type separate makes the boundary independently
/// testable without issuing a real network request.
struct BoundedResponseBuffer {
    let maximumBytes: Int
    private(set) var data = Data()

    init(maximumBytes: Int, expectedContentLength: Int64 = NSURLSessionTransferSizeUnknown) throws {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes

        if expectedContentLength > Int64(maximumBytes) {
            throw BoundedURLSessionError.responseTooLarge(maximumBytes: maximumBytes)
        }

        if expectedContentLength > 0 {
            data.reserveCapacity(min(Int(expectedContentLength), maximumBytes))
        }
    }

    mutating func append(_ byte: UInt8) throws {
        guard data.count < maximumBytes else {
            throw BoundedURLSessionError.responseTooLarge(maximumBytes: maximumBytes)
        }
        data.append(byte)
    }

    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= maximumBytes - data.count else {
            throw BoundedURLSessionError.responseTooLarge(maximumBytes: maximumBytes)
        }
        data.append(chunk)
    }
}

final class FetchDelegate: NSObject, URLSessionDataDelegate {
    private let allowRedirects: Bool

    private final class PendingBoundedResponse {
        let task: URLSessionDataTask
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        var buffer: BoundedResponseBuffer
        var response: URLResponse?

        init(
            task: URLSessionDataTask,
            maximumResponseBytes: Int,
            continuation: CheckedContinuation<(Data, URLResponse), Error>
        ) {
            self.task = task
            self.continuation = continuation
            self.buffer = try! BoundedResponseBuffer(maximumBytes: maximumResponseBytes)
        }
    }

    private enum BoundedRequestRegistration {
        case waiting
        case cancelledBeforeStart
        case active(PendingBoundedResponse)
    }

    private let boundedRequestLock = NSLock()
    private var boundedRequestRegistrations: [UUID: BoundedRequestRegistration] = [:]
    private var boundedRequestTokensByTask: [ObjectIdentifier: UUID] = [:]
    
    init(allowRedirects: Bool) {
        self.allowRedirects = allowRedirects
    }

    static func isAllowedRedirectURL(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard allowRedirects, Self.isAllowedRedirectURL(request.url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func boundedData(
        in session: URLSession,
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        precondition(maximumResponseBytes > 0)

        let token = UUID()
        prepareBoundedRegistration(for: token)

        defer { removeBoundedRegistrationIfPresent(for: token) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let pending = PendingBoundedResponse(
                    task: task,
                    maximumResponseBytes: maximumResponseBytes,
                    continuation: continuation
                )

                let shouldStart: Bool
                boundedRequestLock.lock()
                switch boundedRequestRegistrations[token] {
                case .waiting:
                    boundedRequestRegistrations[token] = .active(pending)
                    boundedRequestTokensByTask[ObjectIdentifier(task)] = token
                    shouldStart = true
                case .cancelledBeforeStart, .none:
                    boundedRequestRegistrations.removeValue(forKey: token)
                    shouldStart = false
                case .active:
                    assertionFailure("A bounded response task was registered more than once.")
                    shouldStart = false
                }
                boundedRequestLock.unlock()

                if shouldStart {
                    task.resume()
                } else {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancelBoundedRequest(token: token)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        var oversizedPending: PendingBoundedResponse?

        boundedRequestLock.lock()
        if let (token, pending) = activeBoundedRequest(for: dataTask) {
            do {
                if pending.buffer.data.isEmpty {
                    pending.buffer = try BoundedResponseBuffer(
                        maximumBytes: pending.buffer.maximumBytes,
                        expectedContentLength: response.expectedContentLength
                    )
                } else if response.expectedContentLength > Int64(pending.buffer.maximumBytes) {
                    throw BoundedURLSessionError.responseTooLarge(
                        maximumBytes: pending.buffer.maximumBytes
                    )
                }
                pending.response = response
            } catch {
                removeActiveBoundedRequest(token: token, task: dataTask)
                oversizedPending = pending
            }
        }
        boundedRequestLock.unlock()

        guard let oversizedPending else {
            completionHandler(.allow)
            return
        }

        completionHandler(.cancel)
        oversizedPending.task.cancel()
        oversizedPending.continuation.resume(
            throwing: BoundedURLSessionError.responseTooLarge(
                maximumBytes: oversizedPending.buffer.maximumBytes
            )
        )
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var oversizedPending: PendingBoundedResponse?

        boundedRequestLock.lock()
        if let (token, pending) = activeBoundedRequest(for: dataTask) {
            do {
                try pending.buffer.append(data)
            } catch {
                removeActiveBoundedRequest(token: token, task: dataTask)
                oversizedPending = pending
            }
        }
        boundedRequestLock.unlock()

        guard let oversizedPending else { return }
        oversizedPending.task.cancel()
        oversizedPending.continuation.resume(
            throwing: BoundedURLSessionError.responseTooLarge(
                maximumBytes: oversizedPending.buffer.maximumBytes
            )
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var completedPending: PendingBoundedResponse?

        boundedRequestLock.lock()
        let taskIdentifier = ObjectIdentifier(task)
        if let token = boundedRequestTokensByTask[taskIdentifier],
           case .active(let pending) = boundedRequestRegistrations[token] {
            boundedRequestRegistrations.removeValue(forKey: token)
            boundedRequestTokensByTask.removeValue(forKey: taskIdentifier)
            completedPending = pending
        }
        boundedRequestLock.unlock()

        guard let completedPending else { return }
        if let error {
            completedPending.continuation.resume(throwing: error)
            return
        }
        guard let response = completedPending.response else {
            completedPending.continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        completedPending.continuation.resume(returning: (completedPending.buffer.data, response))
    }

    private func activeBoundedRequest(
        for task: URLSessionTask
    ) -> (token: UUID, pending: PendingBoundedResponse)? {
        let taskIdentifier = ObjectIdentifier(task)
        guard let token = boundedRequestTokensByTask[taskIdentifier],
              case .active(let pending) = boundedRequestRegistrations[token] else {
            return nil
        }
        return (token, pending)
    }

    private func removeActiveBoundedRequest(token: UUID, task: URLSessionTask) {
        boundedRequestRegistrations.removeValue(forKey: token)
        boundedRequestTokensByTask.removeValue(forKey: ObjectIdentifier(task))
    }

    private func cancelBoundedRequest(token: UUID) {
        var pendingToCancel: PendingBoundedResponse?

        boundedRequestLock.lock()
        switch boundedRequestRegistrations[token] {
        case .waiting:
            boundedRequestRegistrations[token] = .cancelledBeforeStart
        case .cancelledBeforeStart:
            break
        case .active(let pending):
            removeActiveBoundedRequest(token: token, task: pending.task)
            pendingToCancel = pending
        case .none:
            break
        }
        boundedRequestLock.unlock()

        guard let pendingToCancel else { return }
        pendingToCancel.task.cancel()
        pendingToCancel.continuation.resume(throwing: CancellationError())
    }

    private func removeBoundedRegistrationIfPresent(for token: UUID) {
        boundedRequestLock.lock()
        if case .active(let pending) = boundedRequestRegistrations[token] {
            boundedRequestTokensByTask.removeValue(forKey: ObjectIdentifier(pending.task))
        }
        boundedRequestRegistrations.removeValue(forKey: token)
        boundedRequestLock.unlock()
    }

    private func prepareBoundedRegistration(for token: UUID) {
        boundedRequestLock.lock()
        boundedRequestRegistrations[token] = .waiting
        boundedRequestLock.unlock()
    }
}

extension URLSession {
    static let userAgents = [
        // Chrome
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.6998.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
        
        // FireFox
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:136.0) Gecko/20100101 Firefox/136.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.7; rv:136.0) Gecko/20100101 Firefox/136.0",
        "Mozilla/5.0 (X11; Linux x86_64; rv:136.0) Gecko/20100101 Firefox/136.0",
        "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:136.0) Gecko/20100101 Firefox/136.0",
        
        // Edge
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.3124.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.3124.0",
        
        // Safari
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
        
        // Mobile Chrome
        "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 15; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.6998.0 Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 14; SM-G998B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36",
        
        // Mobile Safari
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_7_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPad; CPU OS 17_7_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1",
        
        // Mobile Firefox
        "Mozilla/5.0 (Mobile; rv:136.0) Gecko/136.0 Firefox/136.0",
        "Mozilla/5.0 (Android 15; Mobile; rv:136.0) Gecko/136.0 Firefox/136.0",
        
        // Mobile Edge
        "Mozilla/5.0 (Linux; Android 14; SM-G973F) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36 EdgA/134.0.3124.0",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_7_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 EdgiOS/134.3124.77 Mobile/15E148 Safari/605.1.15"
    ]
    
    /// Intentionally stable for the process lifetime (evaluated once on first access, not
    /// per-call): PlayerViewController's next-episode prewarm and the actual play-time
    /// request both build their header dictionaries from this property independently, and
    /// ExperimentalMPVPreloadManager's cache key is a hash that includes the User-Agent — the
    /// two reads have to land on the same value or the prewarm is silently wasted. Call sites
    /// that need a fresh, internally-consistent identity per webview/request (e.g. Cloudflare
    /// bypass scraping) should capture this into a local `let` once and reuse it, not rely on
    /// repeated reads agreeing with each other by chance.
    static var randomUserAgent: String = {
        userAgents.randomElement() ?? userAgents[0]
    }()

    /// A desktop-class identity, for webviews whose frame is a fixed desktop size — keeping
    /// the UA/viewport pairing internally consistent (a mobile UA on a desktop-sized canvas,
    /// or vice versa, is a bot-detection tell). Re-picked per call: callers that need one
    /// stable value for a whole request/webview flow should capture it into a local `let`.
    static var randomDesktopUserAgent: String {
        let desktopAgents = userAgents.filter {
            !$0.contains("Mobile") && !$0.contains("iPhone") && !$0.contains("iPad")
        }
        return desktopAgents.randomElement() ?? userAgents[0]
    }
    
    static let custom: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": randomUserAgent]
        return URLSession(
            configuration: configuration,
            delegate: FetchDelegate(allowRedirects: true),
            delegateQueue: nil
        )
    }()
    
    static func fetchData(allowRedirects:Bool) -> URLSession {
        let delegate = FetchDelegate(allowRedirects:allowRedirects)
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": randomUserAgent]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Reads a response incrementally and cancels its data task as soon as the
    /// byte limit is crossed. This avoids the unbounded buffering performed by
    /// `data(for:)` and the full temporary-file write performed by
    /// `download(for:)`, while preserving this session's redirect, cookie,
    /// timeout, cache, and delegate behavior.
    func boundedData(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        if let fetchDelegate = delegate as? FetchDelegate {
            return try await fetchDelegate.boundedData(
                in: self,
                for: request,
                maximumResponseBytes: maximumResponseBytes
            )
        }

        let (bytes, response) = try await bytes(for: request)
        let dataTask = bytes.task

        do {
            var buffer = try BoundedResponseBuffer(
                maximumBytes: maximumResponseBytes,
                expectedContentLength: response.expectedContentLength
            )
            for try await byte in bytes {
                try Task.checkCancellation()
                try buffer.append(byte)
            }
            return (buffer.data, response)
        } catch {
            dataTask.cancel()
            throw error
        }
    }

    func boundedData(
        from url: URL,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        try await boundedData(
            for: URLRequest(url: url),
            maximumResponseBytes: maximumResponseBytes
        )
    }
}
