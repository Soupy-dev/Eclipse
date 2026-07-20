import SwiftUI
import JavaScriptCore

/// Exactly-once callback delivery with an optional deadline and explicit
/// cancellation. The timeout task and completion are cleared by the first
/// winner, so a settled request cannot retain either indefinitely.
final class JSCallbackDeadline<Value>: @unchecked Sendable {
    let id = UUID()

    private enum State: Equatable {
        case pending
        case completed
        case cancelled
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var completion: ((Value) -> Void)?
    private var cancellationHandler: (() -> Void)?
    private var timeoutTask: Task<Void, Never>?

    init(completion: @escaping (Value) -> Void) {
        self.completion = completion
    }

    func setCancellationHandler(_ handler: @escaping () -> Void) {
        var runImmediately = false
        lock.lock()
        switch state {
        case .pending:
            cancellationHandler = handler
        case .cancelled:
            runImmediately = true
        case .completed:
            break
        }
        lock.unlock()

        if runImmediately {
            handler()
        }
    }

    func armTimeout(
        nanoseconds: UInt64,
        value: Value,
        beforeDelivery: @escaping () -> Void
    ) {
        guard nanoseconds > 0 else {
            _ = finish(with: value, beforeDelivery: beforeDelivery)
            return
        }

        let task = Task { [self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            _ = finish(with: value, beforeDelivery: beforeDelivery)
        }

        lock.lock()
        guard state == .pending else {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    @discardableResult
    func finish(with value: Value, beforeDelivery: (() -> Void)? = nil) -> Bool {
        let completionToRun: ((Value) -> Void)?
        let timeoutToCancel: Task<Void, Never>?

        lock.lock()
        guard state == .pending else {
            lock.unlock()
            return false
        }
        state = .completed
        completionToRun = completion
        completion = nil
        cancellationHandler = nil
        timeoutToCancel = timeoutTask
        timeoutTask = nil
        lock.unlock()

        timeoutToCancel?.cancel()
        beforeDelivery?()
        completionToRun?(value)
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        let cancellationToRun: (() -> Void)?
        let timeoutToCancel: Task<Void, Never>?

        lock.lock()
        guard state == .pending else {
            lock.unlock()
            return false
        }
        state = .cancelled
        completion = nil
        cancellationToRun = cancellationHandler
        cancellationHandler = nil
        timeoutToCancel = timeoutTask
        timeoutTask = nil
        lock.unlock()

        timeoutToCancel?.cancel()
        cancellationToRun?()
        return true
    }

    var isPending: Bool {
        lock.lock()
        let pending = state == .pending
        lock.unlock()
        return pending
    }
}

struct ServiceSandboxOperation {
    let id: UUID
    let serviceName: String
    let operation: String
    let primaryURL: String?
}

final class ServiceSandboxState {
    private let lock = NSLock()
    private var currentOperation: ServiceSandboxOperation?
    private var loadingServiceName: String?

    func beginLoading(serviceName: String?) {
        lock.lock()
        loadingServiceName = serviceName
        lock.unlock()
    }

    func endLoading() {
        lock.lock()
        loadingServiceName = nil
        lock.unlock()
    }

    func beginOperation(serviceName: String, operation: String, primaryURL: String? = nil) -> ServiceSandboxOperation {
        let op = ServiceSandboxOperation(
            id: UUID(),
            serviceName: serviceName,
            operation: operation,
            primaryURL: primaryURL
        )
        lock.lock()
        currentOperation = op
        lock.unlock()
        Logger.shared.log("Service operation started service=\(serviceName) operation=\(operation) target=\(Self.redactedURL(primaryURL))", type: "Service")
        return op
    }

    @discardableResult
    func endOperation(_ operation: ServiceSandboxOperation, reason: String) -> Bool {
        lock.lock()
        let shouldEnd = currentOperation?.id == operation.id
        if shouldEnd {
            currentOperation = nil
        }
        lock.unlock()
        if shouldEnd {
            Logger.shared.log("Service operation ended service=\(operation.serviceName) operation=\(operation.operation) reason=\(reason)", type: "Service")
        }
        return shouldEnd
    }

    @discardableResult
    func cancelCurrentOperation(reason: String) -> Bool {
        lock.lock()
        let operation = currentOperation
        currentOperation = nil
        loadingServiceName = nil
        lock.unlock()

        if let operation {
            Logger.shared.log(
                "Service operation ended service=\(operation.serviceName) operation=\(operation.operation) reason=\(reason)",
                type: "Service"
            )
        }
        return operation != nil
    }

    func contextLabel() -> String {
        lock.lock()
        let operation = currentOperation
        let loadingName = loadingServiceName
        lock.unlock()

        if let operation {
            return "service=\(operation.serviceName) operation=\(operation.operation)"
        }
        if let loadingName {
            return "service=\(loadingName) operation=loadScript"
        }
        return "service=unknown operation=none"
    }

    func allowServiceNetworkRequest(api: String, urlString: String) -> ServiceSandboxOperation? {
        lock.lock()
        let operation = currentOperation
        let loadingName = loadingServiceName
        lock.unlock()

        guard Self.validatedHTTPURL(urlString) != nil else {
            let serviceName = operation?.serviceName ?? loadingName ?? "unknown"
            Logger.shared.log(
                "Service sandbox blocked non-HTTP network request service=\(serviceName) api=\(api) target=unsupported-url",
                type: "ServiceSandbox"
            )
            return nil
        }

        guard let operation else {
            let serviceName = loadingName ?? "unknown"
            Logger.shared.log("Service sandbox blocked network request outside user operation service=\(serviceName) api=\(api) target=\(Self.redactedURL(urlString))", type: "ServiceSandbox")
            return nil
        }

        if Self.isBlockedTrackingURL(urlString) {
            Logger.shared.log("Service sandbox blocked tracking request service=\(operation.serviceName) operation=\(operation.operation) api=\(api) target=\(Self.redactedURL(urlString))", type: "ServiceSandbox")
            return nil
        }

        Logger.shared.log("Service network request service=\(operation.serviceName) operation=\(operation.operation) api=\(api) target=\(Self.redactedURL(urlString))", type: "Service")
        return operation
    }

    static func redactedURL(_ value: String?) -> String {
        guard let value, let url = validatedHTTPURL(value) else {
            return value?.isEmpty == false ? "invalid-url" : "nil"
        }

        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "unknown")"
    }

    static func validatedHTTPURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              let url = components.url else {
            return nil
        }
        return url
    }

    static func hostDescription(_ value: String?) -> String {
        guard let value, let host = URL(string: value)?.host else { return "nil" }
        return host
    }

    static func isBlockedTrackingURL(_ value: String?) -> Bool {
        guard let value,
              let url = URL(string: value),
              let host = url.host?.lowercased() else {
            return false
        }

        let blockedSuffixes = [
            "google-analytics.com",
            "googletagmanager.com",
            "doubleclick.net",
            "googlesyndication.com",
            "facebook.net",
            "facebook.com",
            "mixpanel.com",
            "segment.io",
            "segment.com",
            "amplitude.com",
            "appsflyer.com",
            "branch.io",
            "hotjar.com",
            "clarity.ms",
            "scorecardresearch.com",
            "quantserve.com",
            "newrelic.com",
            "sentry.io",
            "datadoghq-browser-agent.com"
        ]

        if blockedSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return true
        }

        let blockedHostTokens = ["analytics", "telemetry", "metrics", "tracking", "tracker", "beacon"]
        return blockedHostTokens.contains(where: host.contains)
    }
}

class JSController: NSObject, ObservableObject {
    static let shared = JSController()
    var context: JSContext
    private let sandbox = ServiceSandboxState()
    private let contextLifecycleLock = NSRecursiveLock()
    private var serviceScriptReloadNeeded = false
    
    override init() {
        self.context = JSContext()
        super.init()
        setupContext()
    }
    
    func setupContext() {
        context.setupJavaScriptEnvironment(sandbox: sandbox)
    }
    
    func loadScript(_ script: String, service: Service? = nil) {
        contextLifecycleLock.lock()
        defer { contextLifecycleLock.unlock() }
        serviceScriptReloadNeeded = false

        // Clean up old context
        context.exception = nil
        
        // Create fresh context
        context = JSContext()
        context.setupJavaScriptEnvironment(sandbox: sandbox)
        sandbox.beginLoading(serviceName: service?.metadata.sourceName)
        let runtimeScript: String
#if os(tvOS)
        if let service {
            runtimeScript = TVServiceSettingVault.hydrating(script, serviceID: service.id)
        } else {
            runtimeScript = script
        }
#else
        runtimeScript = script
#endif
        context.evaluateScript(runtimeScript)
        if context.exception != nil {
            Logger.shared.log("Service load JavaScript exception; untrusted body suppressed", type: "Error")
        }
        sandbox.endLoading()
    }

    func beginServiceOperation(service: Service, operation: String, primaryURL: String? = nil) -> ServiceSandboxOperation {
        contextLifecycleLock.lock()
        defer { contextLifecycleLock.unlock() }
        return sandbox.beginOperation(
            serviceName: service.metadata.sourceName,
            operation: operation,
            primaryURL: primaryURL
        )
    }

    /// Restoring a context and claiming its next operation must be atomic with
    /// respect to stale cancellation. Otherwise an old deadline could detach
    /// the freshly restored context in the gap before `beginOperation`.
    func beginStreamExtractionOperation(service: Service, primaryURL: String) -> ServiceSandboxOperation {
        contextLifecycleLock.lock()
        defer { contextLifecycleLock.unlock() }
        restoreServiceScriptAfterCancellationIfNeeded(service)
        return sandbox.beginOperation(
            serviceName: service.metadata.sourceName,
            operation: "extractStreamUrl",
            primaryURL: primaryURL
        )
    }

    func endServiceOperation(_ operation: ServiceSandboxOperation, reason: String) {
        sandbox.endOperation(operation, reason: reason)
    }

    /// Cancellation deliberately replaces the JSContext so callbacks retained
    /// by an abandoned Promise cannot fire into a later request. If the caller
    /// reuses this controller, restore its service script before beginning the
    /// next extraction.
    func restoreServiceScriptAfterCancellationIfNeeded(_ service: Service) {
        contextLifecycleLock.lock()
        let shouldReload = serviceScriptReloadNeeded
        serviceScriptReloadNeeded = false
        contextLifecycleLock.unlock()

        guard shouldReload else { return }
        Logger.shared.log(
            "Reloading service JavaScript after cancelled operation service=\(service.metadata.sourceName)",
            type: "Service"
        )
        loadScript(service.jsScript, service: service)
    }

    /// Detaches callbacks from an abandoned JavaScript promise. Native network
    /// requests still observe their own URLSession deadlines, while the search
    /// task and its continuation can be reclaimed immediately.
    func cancelPendingServiceOperation(reason: String) {
        contextLifecycleLock.lock()
        defer { contextLifecycleLock.unlock() }
        guard sandbox.cancelCurrentOperation(reason: reason) else { return }
        detachPendingServiceContext()
    }

    /// Ends only the operation owned by the cancelled request. This prevents a
    /// late timeout from clearing the sandbox bookkeeping for a newer request.
    func cancelPendingServiceOperation(_ operation: ServiceSandboxOperation, reason: String) {
        contextLifecycleLock.lock()
        defer { contextLifecycleLock.unlock() }
        guard sandbox.endOperation(operation, reason: reason) else { return }
        detachPendingServiceContext()
    }

    private func detachPendingServiceContext() {
        context.exception = nil
        context = JSContext()
        serviceScriptReloadNeeded = true
    }
}
