//
//  URLSession.swift
//  Sora-JS
//
//  Created by Francesco on 05/01/25.
//

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

    typealias RedirectAuthorization = @Sendable (_ source: URL, _ destination: URL) async throws -> Void

    private let allowRedirects: Bool
    private let redirectAuthorization: RedirectAuthorization?
    private let scopesCrossOriginHeaders: Bool

    private final class PendingBoundedResponse {
        let task: URLSessionDataTask
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        var buffer: BoundedResponseBuffer
        var response: URLResponse?
        let allowRedirects: Bool?
        let returnsRedirectResponseImmediately: Bool

        init(
            task: URLSessionDataTask,
            maximumResponseBytes: Int,
            allowRedirects: Bool?,
            returnsRedirectResponseImmediately: Bool,
            continuation: CheckedContinuation<(Data, URLResponse), Error>
        ) throws {
            self.task = task
            self.continuation = continuation
            self.buffer = try BoundedResponseBuffer(maximumBytes: maximumResponseBytes)
            self.allowRedirects = allowRedirects
            self.returnsRedirectResponseImmediately = returnsRedirectResponseImmediately
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

    // Header scoping is opt-in and separate from redirect authorization. A plugin's own Cookie
    // and Authorization must survive the 302 that hands off its session, or the documented
    // log-in -> redirect -> embed provider shape stops working; authorizing the destination
    // address is a different concern and must not silently drag header stripping in with it.
    init(
        allowRedirects: Bool,
        redirectAuthorization: RedirectAuthorization? = nil,
        scopesCrossOriginHeaders: Bool = false
    ) {
        self.allowRedirects = allowRedirects
        self.redirectAuthorization = redirectAuthorization
        self.scopesCrossOriginHeaders = scopesCrossOriginHeaders
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

    static func requestScopedForRedirect(
        _ request: URLRequest,
        from source: URL,
        to destination: URL
    ) -> URLRequest {
        guard !isSameOrigin(source, destination) else { return request }

        let crossOriginSafeHeaderNames: Set<String> = [
            "accept", "accept-language", "cache-control", "dnt", "pragma", "user-agent"
        ]
        var scoped = request

        for headerName in (request.allHTTPHeaderFields ?? [:]).keys where
            !crossOriginSafeHeaderNames.contains(headerName.lowercased()) {
            scoped.setValue(nil, forHTTPHeaderField: headerName)
        }
        return scoped
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased() else {
            return false
        }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(for: lhs, scheme: lhsScheme) == effectivePort(for: rhs, scheme: rhsScheme)
    }

    private static func effectivePort(for url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var immediateRedirect: PendingBoundedResponse?
        boundedRequestLock.lock()
        if let (token, pending) = activeBoundedRequest(for: task),
           pending.returnsRedirectResponseImmediately {
            removeActiveBoundedRequest(token: token, task: task)
            immediateRedirect = pending
        }
        boundedRequestLock.unlock()
        if let immediateRedirect {
            completionHandler(nil)
            immediateRedirect.task.cancel()
            immediateRedirect.continuation.resume(returning: (Data(), response))
            return
        }

        guard allowsRedirect(for: task), Self.isAllowedRedirectURL(request.url) else {
            completionHandler(nil)
            return
        }
        guard let destination = request.url else {
            completionHandler(nil)
            return
        }

        let source = response.url ?? task.originalRequest?.url ?? destination
        guard let redirectAuthorization else {
            completionHandler(request)
            return
        }
        Task {
            do {
                try await redirectAuthorization(source, destination)

                guard self.scopesCrossOriginHeaders else {
                    completionHandler(request)
                    return
                }
                completionHandler(Self.requestScopedForRedirect(
                    request,
                    from: source,
                    to: destination
                ))
            } catch {

                completionHandler(nil)
            }
        }
    }

    func boundedData(
        in session: URLSession,
        for request: URLRequest,
        maximumResponseBytes: Int,
        allowRedirects: Bool? = nil,
        returnsRedirectResponseImmediately: Bool = false
    ) async throws -> (Data, URLResponse) {
        precondition(maximumResponseBytes > 0)

        let token = UUID()
        prepareBoundedRegistration(for: token)

        defer { removeBoundedRegistrationIfPresent(for: token) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let pending: PendingBoundedResponse
                do {
                    pending = try PendingBoundedResponse(
                        task: task,
                        maximumResponseBytes: maximumResponseBytes,
                        allowRedirects: allowRedirects,
                        returnsRedirectResponseImmediately: returnsRedirectResponseImmediately,
                        continuation: continuation
                    )
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

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

    private func allowsRedirect(for task: URLSessionTask) -> Bool {
        boundedRequestLock.lock()
        defer { boundedRequestLock.unlock() }
        guard let token = boundedRequestTokensByTask[ObjectIdentifier(task)],
              case .active(let pending) = boundedRequestRegistrations[token] else {
            return allowRedirects
        }
        return pending.allowRedirects ?? allowRedirects
    }
}

extension URLSession {
    static let userAgents = [

        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.6998.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",

        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:136.0) Gecko/20100101 Firefox/136.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.7; rv:136.0) Gecko/20100101 Firefox/136.0",
        "Mozilla/5.0 (X11; Linux x86_64; rv:136.0) Gecko/20100101 Firefox/136.0",
        "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:136.0) Gecko/20100101 Firefox/136.0",

        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.3124.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.3124.0",

        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",

        "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 15; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.6998.0 Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 14; SM-G998B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36",

        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_7_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPad; CPU OS 17_7_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1",

        "Mozilla/5.0 (Mobile; rv:136.0) Gecko/136.0 Firefox/136.0",
        "Mozilla/5.0 (Android 15; Mobile; rv:136.0) Gecko/136.0 Firefox/136.0",

        "Mozilla/5.0 (Linux; Android 14; SM-G973F) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Mobile Safari/537.36 EdgA/134.0.3124.0",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_7_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 EdgiOS/134.3124.77 Mobile/15E148 Safari/605.1.15"
    ]

    static var randomUserAgent: String = {
        userAgents.randomElement() ?? userAgents[0]
    }()

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

    static func fetchData(
        allowRedirects: Bool,
        redirectAuthorization: FetchDelegate.RedirectAuthorization? = nil
    ) -> URLSession {
        let delegate = FetchDelegate(
            allowRedirects: allowRedirects,
            redirectAuthorization: redirectAuthorization
        )
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": randomUserAgent]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func boundedData(
        for request: URLRequest,
        maximumResponseBytes: Int,
        allowRedirects: Bool? = nil
    ) async throws -> (Data, URLResponse) {
        if let fetchDelegate = delegate as? FetchDelegate {
            return try await fetchDelegate.boundedData(
                in: self,
                for: request,
                maximumResponseBytes: maximumResponseBytes,
                allowRedirects: allowRedirects
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
