//
//  JSController.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI
import JavaScriptCore

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
    let serviceID: UUID?
    let scriptFingerprint: String?
    let serviceName: String
    let operation: String
    let primaryURL: String?
}

final class ServiceSandboxNativeOperationLease: @unchecked Sendable {
    let id: UUID
    private let lock = NSLock()
    private weak var sandbox: ServiceSandboxState?

    fileprivate init(id: UUID, sandbox: ServiceSandboxState) {
        self.id = id
        self.sandbox = sandbox
    }

    func installCancellationHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        let owningSandbox = sandbox
        lock.unlock()
        guard let owningSandbox else {
            handler()
            return
        }
        owningSandbox.installNativeOperationCancellationHandler(handler, for: id)
    }

    func finish() {
        lock.lock()
        let owningSandbox = sandbox
        sandbox = nil
        lock.unlock()
        owningSandbox?.finishNativeOperation(id)
    }

    var isActive: Bool {
        lock.lock()
        let owningSandbox = sandbox
        lock.unlock()
        return owningSandbox?.isNativeOperationActive(id) == true
    }

    deinit {
        finish()
    }
}

final class ServiceSandboxState {
    static let maximumConcurrentNativeOperations = 64
    let isolationScopeID = UUID()

    private struct NativeOperationRegistration {
        var cancellationHandler: (() -> Void)?
    }

    private let lock = NSLock()
    private var currentOperation: ServiceSandboxOperation?
    private var loadingOperation: ServiceSandboxOperation?
    private var browserProfileID: UUID?
    private var browserServiceID: UUID?
    private var serviceNetworkSession: URLSession?
    private var javaScriptScheduler: (((@escaping () -> Void) -> Void))?
    private var invalidationHandlers: [UUID: () -> Void] = [:]
    private var nativeOperations: [UUID: NativeOperationRegistration] = [:]
#if os(iOS)
    private var rateLimitedOperationIDs: Set<UUID> = []
#endif
    private var isInvalidated = false

    deinit {
        invalidate()
    }

    func installJavaScriptScheduler(
        _ scheduler: @escaping (@escaping () -> Void) -> Void
    ) {
        lock.lock()
        if !isInvalidated {
            javaScriptScheduler = scheduler
        }
        lock.unlock()
    }

    func configureBrowserIsolation(profileID: UUID, serviceID: UUID?) {
        lock.lock()
        browserProfileID = profileID
        browserServiceID = serviceID
        lock.unlock()
    }

    func browserIsolationKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let browserProfileID, let browserServiceID else { return nil }
        return "\(browserProfileID.uuidString.lowercased()):\(browserServiceID.uuidString.lowercased())"
    }

    func configureNetworkSession(_ session: URLSession) {
        lock.lock()
        serviceNetworkSession = session
        lock.unlock()
    }

    func networkSession() -> URLSession? {
        lock.lock()
        defer { lock.unlock() }
        return serviceNetworkSession
    }

    func registerInvalidationHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        if isInvalidated {
            lock.unlock()
            handler()
            return
        }
        invalidationHandlers[UUID()] = handler
        lock.unlock()
    }

    func reserveNativeOperation() -> ServiceSandboxNativeOperationLease? {
        lock.lock()
        guard !isInvalidated,
              nativeOperations.count < Self.maximumConcurrentNativeOperations else {
            lock.unlock()
            return nil
        }
        let id = UUID()
        nativeOperations[id] = NativeOperationRegistration(cancellationHandler: nil)
        lock.unlock()
        return ServiceSandboxNativeOperationLease(id: id, sandbox: self)
    }

    fileprivate func installNativeOperationCancellationHandler(
        _ handler: @escaping () -> Void,
        for id: UUID
    ) {
        lock.lock()
        guard !isInvalidated, nativeOperations[id] != nil else {
            lock.unlock()
            handler()
            return
        }
        nativeOperations[id]?.cancellationHandler = handler
        lock.unlock()
    }

    fileprivate func finishNativeOperation(_ id: UUID) {
        lock.lock()
        nativeOperations.removeValue(forKey: id)
        lock.unlock()
    }

    fileprivate func isNativeOperationActive(_ id: UUID) -> Bool {
        lock.lock()
        let active = !isInvalidated && nativeOperations[id] != nil
        lock.unlock()
        return active
    }

    var liveNativeOperationCount: Int {
        lock.lock()
        let count = nativeOperations.count
        lock.unlock()
        return count
    }

    func invalidate() {
        let handlers: [() -> Void]
        let nativeCancellations: [() -> Void]
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }
        isInvalidated = true
        javaScriptScheduler = nil
        currentOperation = nil
        loadingOperation = nil
#if os(iOS)
        rateLimitedOperationIDs.removeAll(keepingCapacity: false)
#endif
        handlers = Array(invalidationHandlers.values)
        invalidationHandlers.removeAll(keepingCapacity: false)
        nativeCancellations = nativeOperations.values.compactMap(\.cancellationHandler)
        nativeOperations.removeAll(keepingCapacity: false)
        lock.unlock()
        handlers.forEach { $0() }
        nativeCancellations.forEach { $0() }
    }

    /// Schedules access to a JSValue back onto the serial lane that owns its
    /// JSContext. This must be used by every asynchronous native bridge.
    func performJavaScriptCallback(_ callback: @escaping () -> Void) {
        lock.lock()
        let scheduler = isInvalidated ? nil : javaScriptScheduler
        lock.unlock()
        scheduler?(callback)
    }

    func beginLoading(identity: ServiceJavaScriptIdentity?) {
        lock.lock()
        loadingOperation = identity.map {
            ServiceSandboxOperation(
                id: UUID(),
                serviceID: $0.serviceID,
                scriptFingerprint: $0.scriptFingerprint,
                serviceName: $0.serviceName,
                operation: "loadScript",
                primaryURL: nil
            )
        }
        lock.unlock()
    }

    func endLoading() {
        lock.lock()
#if os(iOS)
        if let operationID = loadingOperation?.id {
            rateLimitedOperationIDs.remove(operationID)
        }
#endif
        loadingOperation = nil
        lock.unlock()
    }

    func beginOperation(_ op: ServiceSandboxOperation) {
        lock.lock()
        currentOperation = op
#if os(iOS)
        rateLimitedOperationIDs.remove(op.id)
#endif
        lock.unlock()
        Logger.shared.log(
            "Service operation started service=\(op.serviceName) operation=\(op.operation) target=\(Self.redactedURL(op.primaryURL))",
            type: "Service"
        )
    }

    @discardableResult
    func endOperation(_ operation: ServiceSandboxOperation, reason: String) -> Bool {
        lock.lock()
        let shouldEnd = currentOperation?.id == operation.id
#if os(iOS)
        rateLimitedOperationIDs.remove(operation.id)
#endif
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
#if os(iOS)
        if let operationID = operation?.id {
            rateLimitedOperationIDs.remove(operationID)
        }
        if let operationID = loadingOperation?.id {
            rateLimitedOperationIDs.remove(operationID)
        }
#endif
        currentOperation = nil
        loadingOperation = nil
        lock.unlock()

        if let operation {
            Logger.shared.log(
                "Service operation ended service=\(operation.serviceName) operation=\(operation.operation) reason=\(reason)",
                type: "Service"
            )
        }
        return operation != nil
    }

#if os(iOS)
    func recordRateLimit(for operation: ServiceSandboxOperation) {
        lock.lock()
        let isCurrent = currentOperation?.id == operation.id || loadingOperation?.id == operation.id
        if !isInvalidated, isCurrent {
            rateLimitedOperationIDs.insert(operation.id)
        }
        lock.unlock()
    }

    func clearRateLimit(for operation: ServiceSandboxOperation) {
        lock.lock()
        rateLimitedOperationIDs.remove(operation.id)
        lock.unlock()
    }

    func consumeRateLimit(for operation: ServiceSandboxOperation) -> Bool {
        lock.lock()
        let consumed = rateLimitedOperationIDs.remove(operation.id) != nil
        lock.unlock()
        return consumed
    }
#else
    func recordRateLimit(for operation: ServiceSandboxOperation) {}

    func clearRateLimit(for operation: ServiceSandboxOperation) {}
#endif

    func contextLabel() -> String {
        lock.lock()
        let operation = currentOperation
        let loadingOperation = loadingOperation
        lock.unlock()

        if let operation {
            return "service=\(operation.serviceName) operation=\(operation.operation)"
        }
        if let loadingOperation {
            return "service=\(loadingOperation.serviceName) operation=loadScript"
        }
        return "service=unknown operation=none"
    }

    func allowServiceNetworkRequest(api: String, urlString: String) -> ServiceSandboxOperation? {
        lock.lock()
        let operation = currentOperation ?? loadingOperation
        lock.unlock()

        guard Self.validatedHTTPURL(urlString) != nil else {
            let serviceName = operation?.serviceName ?? "unknown"
            Logger.shared.log(
                "Service sandbox blocked non-HTTP network request service=\(serviceName) api=\(api) target=unsupported-url",
                type: "ServiceSandbox"
            )
            return nil
        }

        guard let operation else {
            Logger.shared.log("Service sandbox blocked network request outside user operation service=unknown api=\(api) target=\(Self.redactedURL(urlString))", type: "ServiceSandbox")
            return nil
        }

        if Self.isBlockedTrackingURL(urlString) {
            Logger.shared.log("Service sandbox blocked tracking request service=\(operation.serviceName) operation=\(operation.operation) api=\(api) target=\(Self.redactedURL(urlString))", type: "ServiceSandbox")
            return nil
        }

        Logger.shared.log("Service network request service=\(operation.serviceName) operation=\(operation.operation) api=\(api) target=\(Self.redactedURL(urlString))", type: "Service")
        return operation
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

        return false
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
              let repaired = ServiceModuleURLParser.repaired(trimmed),
              let components = URLComponents(string: repaired),
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

}

extension Notification.Name {
    static let serviceJavaScriptQuarantineDidChange = Notification.Name(
        "ServiceJavaScriptQuarantineDidChange"
    )
}

enum ServiceModuleURLParser {
    private static let allowedCharacters: CharacterSet = {
        var characters = CharacterSet.urlQueryAllowed
        characters.formUnion(.urlPathAllowed)
        characters.formUnion(.urlHostAllowed)
        characters.formUnion(.urlFragmentAllowed)
        characters.formUnion(.urlUserAllowed)
        characters.formUnion(.urlPasswordAllowed)
        characters.insert(charactersIn: "%#/?:@[]!$&'()*+,;=-._~")
        return characters
    }()

    static func repaired(_ rawValue: String) -> String? {
        rawValue.addingPercentEncoding(withAllowedCharacters: allowedCharacters)
    }

    static func url(_ rawValue: String, relativeTo baseURL: URL? = nil) -> URL? {
        guard let repaired = repaired(rawValue) else { return nil }
        return URL(string: repaired, relativeTo: baseURL)?.absoluteURL
    }
}

struct ServiceJavaScriptIdentity: Equatable {
    let serviceID: UUID
    let scriptFingerprint: String
    let serviceName: String

    init(service: Service) {
        serviceID = service.id
        scriptFingerprint = service.jsScript.sha256
        serviceName = service.metadata.sourceName
    }

    init(serviceID: UUID, scriptFingerprint: String, serviceName: String) {
        self.serviceID = serviceID
        self.scriptFingerprint = scriptFingerprint
        self.serviceName = serviceName
    }
}

final class ServiceJavaScriptQuarantineStore: @unchecked Sendable {
    static let shared = ServiceJavaScriptQuarantineStore()
    static let storageKey = "serviceJavaScriptExecutionHealthV1"
    private static let maximumServiceDomainCount = 256
    private static let maximumStorageBytes = 256 * 1_024

    private struct Entry: Codable {
        var fingerprint: String
        var strikeCount: Int
        var quarantined: Bool
        var updatedAt: TimeInterval
        var operation: String?
    }

    private struct State: Codable {
        var entries: [String: Entry]
        var failClosedOverflow: Bool
        var explicitlyClearedServiceIDs: Set<String>

        static let empty = State(
            entries: [:],
            failClosedOverflow: false,
            explicitlyClearedServiceIDs: []
        )

        func isQuarantined(serviceID: String) -> Bool {
            entries[serviceID]?.quarantined == true
        }
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let strikeLimit: Int
    private var sessionQuarantinedFingerprints: Set<String> = []

    init(defaults: UserDefaults = .standard, strikeLimit: Int = 3) {
        self.defaults = defaults
        self.strikeLimit = max(strikeLimit, 1)
    }

    func isQuarantined(_ service: Service) -> Bool {
        isQuarantined(ServiceJavaScriptIdentity(service: service))
    }

    func isQuarantined(_ identity: ServiceJavaScriptIdentity) -> Bool {
        lock.lock()
        let state = loadStateLocked()
        let key = identity.serviceID.uuidString
        let sessionKey = sessionKey(for: identity)
        let persistentlyQuarantined = state.entries[key].map {
            $0.fingerprint == identity.scriptFingerprint && $0.quarantined
        } ?? false
        let quarantined = sessionQuarantinedFingerprints.contains(sessionKey)
            || persistentlyQuarantined
        lock.unlock()
        return quarantined
    }

    @discardableResult
    func recordNonYieldingBoundary(
        identity: ServiceJavaScriptIdentity,
        operation: String
    ) -> Bool {
        let becameQuarantined: Bool
        let strikeCount: Int

        lock.lock()
        var state = loadStateLocked()
        let key = identity.serviceID.uuidString
        let entry = state.entries[key]
        var updated = entry ?? Entry(
            fingerprint: identity.scriptFingerprint,
            strikeCount: 0,
            quarantined: false,
            updatedAt: 0,
            operation: operation
        )
        if updated.fingerprint != identity.scriptFingerprint || updated.operation != operation {
            updated.strikeCount = 0
            updated.quarantined = false
        }
        let wasQuarantined = updated.quarantined
        updated.fingerprint = identity.scriptFingerprint
        updated.operation = operation
        updated.strikeCount = min(updated.strikeCount + 1, strikeLimit)
        updated.quarantined = updated.strikeCount >= strikeLimit
        updated.updatedAt = Date().timeIntervalSince1970
        let becameSessionQuarantined: Bool
        if updated.strikeCount >= strikeLimit {
            becameSessionQuarantined = sessionQuarantinedFingerprints.insert(
                sessionKey(for: identity)
            ).inserted
        } else {
            becameSessionQuarantined = false
        }
        if entry != nil || state.entries.count < Self.maximumServiceDomainCount {
            state.entries[key] = updated
        }
        saveStateLocked(state)
        becameQuarantined = !wasQuarantined && updated.quarantined
        strikeCount = updated.strikeCount
        lock.unlock()

        Logger.shared.log(
            "Service JavaScript failed to yield service=\(identity.serviceName) operation=\(operation) strike=\(strikeCount)/\(strikeLimit)",
            type: "ServiceSandbox"
        )
        if becameQuarantined {
            Logger.shared.log(
                "Service JavaScript quarantined service=\(identity.serviceName) reason=repeated-non-yielding-script",
                type: "ServiceSandbox"
            )
            NotificationCenter.default.post(name: .serviceJavaScriptQuarantineDidChange, object: nil)
        } else if becameSessionQuarantined {
            NotificationCenter.default.post(name: .serviceJavaScriptQuarantineDidChange, object: nil)
        }
        return becameQuarantined
    }

    func recordYieldingBoundary(
        identity: ServiceJavaScriptIdentity,
        operation: String
    ) {
        lock.lock()
        var state = loadStateLocked()
        let key = identity.serviceID.uuidString
        let canClear = !sessionQuarantinedFingerprints.contains(sessionKey(for: identity))
            && state.entries[key].map {
                $0.fingerprint == identity.scriptFingerprint && $0.operation == operation
            } == true
        let removed = canClear
            ? state.entries.removeValue(forKey: key) != nil
            : false
        if removed {
            saveStateLocked(state)
        }
        lock.unlock()
        if removed {
            NotificationCenter.default.post(name: .serviceJavaScriptQuarantineDidChange, object: nil)
        }
    }

    func clear(serviceID: UUID) {
        lock.lock()
        var state = loadStateLocked()
        let key = serviceID.uuidString
        let removed = state.entries.removeValue(forKey: key) != nil
        let explicitlyCleared = state.explicitlyClearedServiceIDs.remove(key) != nil
        let sessionCount = sessionQuarantinedFingerprints.count
        sessionQuarantinedFingerprints = sessionQuarantinedFingerprints.filter {
            !$0.hasPrefix("\(key):")
        }
        let changed = removed
            || explicitlyCleared
            || sessionQuarantinedFingerprints.count != sessionCount
        if changed {
            saveStateLocked(state)
        }
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: .serviceJavaScriptQuarantineDidChange, object: nil)
        }
    }

    func strikeCount(for identity: ServiceJavaScriptIdentity) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let state = loadStateLocked()
        let key = identity.serviceID.uuidString
        if let entry = state.entries[key], entry.fingerprint == identity.scriptFingerprint {
            return entry.strikeCount
        }
        return 0
    }

    private func sessionKey(for identity: ServiceJavaScriptIdentity) -> String {
        "\(identity.serviceID.uuidString):\(identity.scriptFingerprint)"
    }

    private func loadStateLocked() -> State {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return .empty
        }
        guard data.count <= Self.maximumStorageBytes else {
            return .empty
        }
        if let state = try? JSONDecoder().decode(State.self, from: data),
           isValid(state) {
            return state
        }
        if let entries = try? JSONDecoder().decode([String: Entry].self, from: data) {
            let state = State(
                entries: entries,
                failClosedOverflow: false,
                explicitlyClearedServiceIDs: []
            )
            if isValid(state) {
                return state
            }
        }
        return .empty
    }

    private func saveStateLocked(_ state: State) {
        if let data = try? JSONEncoder().encode(state),
           data.count <= Self.maximumStorageBytes {
            defaults.set(data, forKey: Self.storageKey)
            return
        }
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func isValid(_ state: State) -> Bool {
        guard state.entries.count <= Self.maximumServiceDomainCount,
              state.explicitlyClearedServiceIDs.count <= Self.maximumServiceDomainCount else {
            return false
        }
        guard state.entries.keys.allSatisfy({ UUID(uuidString: $0) != nil }),
              state.explicitlyClearedServiceIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            return false
        }
        return state.entries.values.allSatisfy { entry in
            entry.fingerprint.utf8.count <= 1_024
                && (0...1_000_000).contains(entry.strikeCount)
                && entry.updatedAt.isFinite
        }
    }
}

final class ServiceJavaScriptBoundary: @unchecked Sendable {
    enum Phase: Equatable {
        case queued
        case running
        case finished
        case timedOut
    }

    private let lock = NSLock()
    private var phase: Phase = .queued
    private var timeoutTask: Task<Void, Never>?

    func begin() -> Bool {
        lock.lock()
        guard phase == .queued else {
            lock.unlock()
            return false
        }
        phase = .running
        lock.unlock()
        return true
    }

    func finish() {
        let task: Task<Void, Never>?
        lock.lock()
        if phase != .timedOut {
            phase = .finished
        }
        task = timeoutTask
        timeoutTask = nil
        lock.unlock()
        task?.cancel()
    }

    @discardableResult
    func timeOut() -> Phase? {
        lock.lock()
        guard phase != .finished, phase != .timedOut else {
            lock.unlock()
            return nil
        }
        let prior = phase
        phase = .timedOut
        timeoutTask = nil
        lock.unlock()
        return prior
    }

    func armTimeout(
        nanoseconds: UInt64,
        handler: @escaping (Phase) -> Void
    ) {
        let task = Task { [self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            if let prior = timeOut() {
                handler(prior)
            }
        }
        lock.lock()
        guard phase != .finished, phase != .timedOut else {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }
}

private final class ServiceJavaScriptGenerationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var generationID: UUID?

    func install(_ generationID: UUID) {
        lock.lock()
        self.generationID = generationID
        lock.unlock()
    }

    var value: UUID? {
        lock.lock()
        let value = generationID
        lock.unlock()
        return value
    }
}

final class ServiceJavaScriptWorkerLane: @unchecked Sendable {
    fileprivate struct Job {
        let work: () -> Void
        let unavailable: (() -> Void)?
        let rerouted: ((ServiceJavaScriptWorkerLane) -> Void)?
    }

    fileprivate let queue: DispatchQueue
    private let lock = NSLock()
    private weak var pool: ServiceJavaScriptWorkerPool?
    private var permanentlyUnavailable = false
    private var isRunning = false
    private var pendingJobs: [(job: Job, wasRerouted: Bool)] = []
    private let maximumPendingJobs = 64

    fileprivate init(index: Int) {
        queue = DispatchQueue(
            label: "app.eclipse.service-javascript.worker.\(index)",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        )
    }

    fileprivate func installPool(_ pool: ServiceJavaScriptWorkerPool) {
        lock.lock()
        self.pool = pool
        lock.unlock()
    }

    @discardableResult
    func async(
        _ work: @escaping () -> Void,
        ifUnavailable: (() -> Void)? = nil,
        ifRerouted: ((ServiceJavaScriptWorkerLane) -> Void)? = nil
    ) -> Bool {
        let job = Job(work: work, unavailable: ifUnavailable, rerouted: ifRerouted)
        return accept(
            job,
            wasRerouted: false,
            mayReroute: true,
            rejectOnFailure: true
        )
    }

    @discardableResult
    fileprivate func accept(
        _ job: Job,
        wasRerouted: Bool,
        mayReroute: Bool,
        rejectOnFailure: Bool
    ) -> Bool {
        let shouldStart: Bool
        let reroutePool: ServiceJavaScriptWorkerPool?
        lock.lock()
        if permanentlyUnavailable {
            reroutePool = pool
            lock.unlock()
            if mayReroute, reroutePool?.reroute(job, from: self) == true {
                return true
            }
            return rejectOnFailure ? reject(job) : false
        }
        guard pendingJobs.count < maximumPendingJobs else {
            lock.unlock()
            return rejectOnFailure ? reject(job) : false
        }
        if isRunning {
            pendingJobs.append((job, wasRerouted))
            shouldStart = false
        } else {
            isRunning = true
            shouldStart = true
        }
        lock.unlock()
        if shouldStart {
            dispatch(job, wasRerouted: wasRerouted)
        }
        return true
    }

    func markPermanentlyUnavailable() {
        let pending: [Job]
        let reroutePool: ServiceJavaScriptWorkerPool?
        lock.lock()
        guard !permanentlyUnavailable else {
            lock.unlock()
            return
        }
        permanentlyUnavailable = true
        pending = pendingJobs.map(\.job)
        pendingJobs.removeAll(keepingCapacity: false)
        reroutePool = pool
        lock.unlock()
        pending.forEach { job in
            if reroutePool?.reroute(job, from: self) != true {
                _ = reject(job)
            }
        }
    }

    var isAvailable: Bool {
        lock.lock()
        let available = !permanentlyUnavailable
        lock.unlock()
        return available
    }

    private func dispatch(_ job: Job, wasRerouted: Bool) {
        queue.async { [weak self] in
            guard let self else {
                job.unavailable?()
                return
            }
            guard isAvailable else {
                lock.lock()
                let reroutePool = pool
                lock.unlock()
                if reroutePool?.reroute(job, from: self) != true {
                    _ = reject(job)
                }
                finishCurrentJob()
                return
            }
            if wasRerouted {
                job.rerouted?(self)
            }
            job.work()
            finishCurrentJob()
        }
    }

    private func finishCurrentJob() {
        let next: (job: Job, wasRerouted: Bool)?
        lock.lock()
        if permanentlyUnavailable || pendingJobs.isEmpty {
            isRunning = false
            next = nil
        } else {
            next = pendingJobs.removeFirst()
        }
        lock.unlock()
        if let next {
            dispatch(next.job, wasRerouted: next.wasRerouted)
        }
    }

    @discardableResult
    private func reject(_ job: Job) -> Bool {
        job.unavailable?()
        return false
    }
}

final class ServiceJavaScriptWorkerPool: @unchecked Sendable {
    static let shared = ServiceJavaScriptWorkerPool(maximumConcurrentWorkers: 4)

    private let lock = NSLock()
    private var lanes: [ServiceJavaScriptWorkerLane]
    private var nextLane = 0
    private var replacementLanesGranted = 0
    private let maximumReplacementLanes = 2
    private var replacementBudgetExhaustionLogged = false

    init(maximumConcurrentWorkers: Int) {
        precondition(maximumConcurrentWorkers > 0)
        lanes = (0..<maximumConcurrentWorkers).map(ServiceJavaScriptWorkerLane.init)
        lanes.forEach { $0.installPool(self) }
    }

    func leaseLane() -> ServiceJavaScriptWorkerLane? {
        lock.lock()
        defer { lock.unlock() }
        let start = nextLane
        repeat {
            let candidate = lanes[nextLane]
            nextLane = (nextLane + 1) % lanes.count
            if candidate.isAvailable {
                return candidate
            }
        } while nextLane != start

        guard replacementLanesGranted < maximumReplacementLanes else {
            if !replacementBudgetExhaustionLogged {
                replacementBudgetExhaustionLogged = true
                Logger.shared.log(
                    "Service JavaScript worker pool exhausted lanes=\(lanes.count) replacements=\(replacementLanesGranted)/\(maximumReplacementLanes); every lane is wedged and the replacement budget is spent, so further work is refused until relaunch",
                    type: "Plugin"
                )
            }
            return nil
        }
        replacementLanesGranted += 1
        let replacement = ServiceJavaScriptWorkerLane(index: lanes.count)
        replacement.installPool(self)
        lanes.append(replacement)
        nextLane = 0
        Logger.shared.log(
            "Service JavaScript worker lane replaced after a non-yielding boundary lanes=\(lanes.count) replacements=\(replacementLanesGranted)/\(maximumReplacementLanes); the wedged thread stays abandoned but service execution continues without a relaunch",
            type: "ServiceSandbox"
        )
        return replacement
    }

    fileprivate func reroute(
        _ job: ServiceJavaScriptWorkerLane.Job,
        from unavailableLane: ServiceJavaScriptWorkerLane
    ) -> Bool {
        lock.lock()
        let start = nextLane
        var candidates: [ServiceJavaScriptWorkerLane] = []
        repeat {
            let candidate = lanes[nextLane]
            nextLane = (nextLane + 1) % lanes.count
            if candidate !== unavailableLane, candidate.isAvailable {
                candidates.append(candidate)
            }
        } while nextLane != start
        lock.unlock()

        for candidate in candidates where candidate.accept(
            job,
            wasRerouted: true,
            mayReroute: false,
            rejectOnFailure: false
        ) {
            return true
        }
        return false
    }
}

class JSController: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = JSController()
    private static let loadTimeoutNanoseconds: UInt64 = 20_000_000_000
    private static let callbackTimeoutNanoseconds: UInt64 = 20_000_000_000

    private struct RuntimeDefinition {
        let script: String
        let service: Service?
        let identity: ServiceJavaScriptIdentity?
        let profileID: UUID
    }

    private struct LoadedRuntime {
        let generationID: UUID
        let definition: RuntimeDefinition
        let context: JSContext
        let sandbox: ServiceSandboxState
    }

    private struct OperationBinding {
        let generationID: UUID
        let sandbox: ServiceSandboxState
    }

    private let worker: ServiceJavaScriptWorkerLane?
    private let quarantineStore: ServiceJavaScriptQuarantineStore
    private let contextLifecycleLock = NSRecursiveLock()
    private var desiredDefinition: RuntimeDefinition?
    private var latestLoadToken: UUID?
    private var activeGenerationID: UUID?
    private var generationSandboxes: [UUID: ServiceSandboxState] = [:]
    private var operationBindings: [UUID: OperationBinding] = [:]
    private var currentOperationID: UUID?
    private var executionPoisoned = false
    private var executingWorkerLane: ServiceJavaScriptWorkerLane?

    /// JavaScriptCore state is only read or replaced on `worker`.
    private var loadedRuntime: LoadedRuntime?

    override init() {
        let worker = ServiceJavaScriptWorkerPool.shared.leaseLane()
        self.worker = worker
        executingWorkerLane = worker
        quarantineStore = .shared
        super.init()
    }

    init(
        worker: ServiceJavaScriptWorkerLane?,
        quarantineStore: ServiceJavaScriptQuarantineStore
    ) {
        self.worker = worker
        executingWorkerLane = worker
        self.quarantineStore = quarantineStore
        super.init()
    }

    deinit {
        contextLifecycleLock.lock()
        let sandboxes = Array(generationSandboxes.values)
        generationSandboxes.removeAll(keepingCapacity: false)
        activeGenerationID = nil
        contextLifecycleLock.unlock()
        sandboxes.forEach { $0.invalidate() }
    }

    func loadScript(
        _ script: String,
        service: Service? = nil,
        timeoutNanoseconds: UInt64 = JSController.loadTimeoutNanoseconds
    ) {
        let definition = RuntimeDefinition(
            script: script,
            service: service,
            identity: service.map(ServiceJavaScriptIdentity.init(service:)),
            profileID: ProfileManager.shared.activeProfileID
        )
        let token = UUID()
        let boundary = ServiceJavaScriptBoundary()
        let lease = ServiceJavaScriptGenerationLease()

        contextLifecycleLock.lock()
        desiredDefinition = definition
        latestLoadToken = token
        contextLifecycleLock.unlock()

        if let identity = definition.identity, quarantineStore.isQuarantined(identity) {
            Logger.shared.log(
                "Service JavaScript load skipped because the current script is quarantined service=\(identity.serviceName)",
                type: "ServiceSandbox"
            )
            return
        }

        boundary.armTimeout(nanoseconds: timeoutNanoseconds) { [weak self] prior in
            guard let self, prior == .running else { return }
            if let identity = definition.identity {
                self.quarantineStore.recordNonYieldingBoundary(identity: identity, operation: "loadScript")
            }
            self.poisonControllerExecution()
            self.retireExecutingWorkerLane()
            if let generationID = lease.value {
                self.invalidateGeneration(generationID)
            }
        }

        guard let worker else {
            boundary.finish()
            logWorkerPoolUnavailable()
            return
        }
        worker.async({ [weak self, boundary] in
            guard let self else {
                boundary.finish()
                return
            }
            guard !self.isControllerExecutionPoisoned else {
                boundary.finish()
                return
            }
            guard self.isLatestLoadToken(token) else {
                boundary.finish()
                return
            }
            if let identity = definition.identity, self.quarantineStore.isQuarantined(identity) {
                boundary.finish()
                return
            }
            guard boundary.begin() else { return }
            _ = self.installRuntime(definition, generationLease: lease)
            boundary.finish()
        }, ifUnavailable: { [weak self, boundary] in
            boundary.finish()
            self?.logWorkerPoolUnavailable()
        }, ifRerouted: { [weak self] destinationLane in
            self?.prepareForWorkerMigration(
                identity: definition.identity,
                destinationLane: destinationLane
            )
        })
    }

    func beginServiceOperation(
        service: Service,
        operation: String,
        primaryURL: String? = nil
    ) -> ServiceSandboxOperation {
        let identity = ServiceJavaScriptIdentity(service: service)
        return ServiceSandboxOperation(
            id: UUID(),
            serviceID: identity.serviceID,
            scriptFingerprint: identity.scriptFingerprint,
            serviceName: identity.serviceName,
            operation: operation,
            primaryURL: primaryURL
        )
    }

    func beginStreamExtractionOperation(
        service: Service,
        primaryURL: String
    ) -> ServiceSandboxOperation {
        beginServiceOperation(
            service: service,
            operation: "extractStreamUrl",
            primaryURL: primaryURL
        )
    }

    func makeBoundary() -> ServiceJavaScriptBoundary {
        ServiceJavaScriptBoundary()
    }

    func enqueueJavaScriptOperation(
        _ operation: ServiceSandboxOperation,
        service: Service?,
        boundary: ServiceJavaScriptBoundary,
        shouldStart: @escaping () -> Bool,
        unavailable: @escaping () -> Void,
        body: @escaping (JSContext) -> Void
    ) {
        guard let worker else {
            logWorkerPoolUnavailable()
            unavailable()
            return
        }
        worker.async({ [weak self, boundary] in
            guard let self,
                  !self.isControllerExecutionPoisoned,
                  shouldStart(),
                  boundary.begin() else { return }
            guard let definition = self.runtimeDefinition(for: service),
                  definition.identity.map({ !self.quarantineStore.isQuarantined($0) }) != false,
                  let runtime = self.ensureRuntime(definition, generationLease: nil),
                  self.isGenerationActive(runtime.generationID),
                  shouldStart() else {
                boundary.finish()
                unavailable()
                return
            }

            runtime.sandbox.beginOperation(operation)
            self.bind(operation, to: runtime)
            body(runtime.context)
            boundary.finish()
        }, ifUnavailable: { [weak self] in
            self?.logWorkerPoolUnavailable()
            unavailable()
        }, ifRerouted: { [weak self] destinationLane in
            self?.prepareForWorkerMigration(
                identity: service.map(ServiceJavaScriptIdentity.init(service:)),
                destinationLane: destinationLane
            )
        })
    }

    func handleOperationTimeout(
        _ operation: ServiceSandboxOperation,
        boundary: ServiceJavaScriptBoundary,
        reason: String
    ) {
        let prior = boundary.timeOut()
        if prior == .running,
           let serviceID = operation.serviceID,
           let scriptFingerprint = operation.scriptFingerprint {
            poisonControllerExecution()
            retireExecutingWorkerLane()
            quarantineStore.recordNonYieldingBoundary(
                identity: ServiceJavaScriptIdentity(
                    serviceID: serviceID,
                    scriptFingerprint: scriptFingerprint,
                    serviceName: operation.serviceName
                ),
                operation: operation.operation
            )
        }
        cancelPendingServiceOperation(operation, reason: reason)
    }

#if os(iOS)
    func consumeRateLimit(for operation: ServiceSandboxOperation) -> Bool {
        let binding: OperationBinding?
        contextLifecycleLock.lock()
        binding = operationBindings[operation.id]
        contextLifecycleLock.unlock()
        return binding?.sandbox.consumeRateLimit(for: operation) == true
    }
#endif

    func endServiceOperation(_ operation: ServiceSandboxOperation, reason: String) {
        let binding: OperationBinding?
        contextLifecycleLock.lock()
        binding = operationBindings.removeValue(forKey: operation.id)
        if currentOperationID == operation.id {
            currentOperationID = nil
        }
        contextLifecycleLock.unlock()
        binding?.sandbox.endOperation(operation, reason: reason)
        if let serviceID = operation.serviceID,
           let scriptFingerprint = operation.scriptFingerprint {
            quarantineStore.recordYieldingBoundary(
                identity: ServiceJavaScriptIdentity(
                    serviceID: serviceID,
                    scriptFingerprint: scriptFingerprint,
                    serviceName: operation.serviceName
                ),
                operation: operation.operation
            )
        }
    }

    func cancelPendingServiceOperation(reason: String) {
        let operationID: UUID?
        let binding: OperationBinding?
        contextLifecycleLock.lock()
        operationID = currentOperationID
        binding = operationID.flatMap { operationBindings[$0] }
        contextLifecycleLock.unlock()

        guard let operationID, let binding,
              binding.sandbox.cancelCurrentOperation(reason: reason) else { return }
        contextLifecycleLock.lock()
        operationBindings.removeValue(forKey: operationID)
        if currentOperationID == operationID {
            currentOperationID = nil
        }
        contextLifecycleLock.unlock()
        invalidateGeneration(binding.generationID)
    }

    func cancelPendingServiceOperation(_ operation: ServiceSandboxOperation, reason: String) {
        let binding: OperationBinding?
        contextLifecycleLock.lock()
        binding = operationBindings[operation.id]
        contextLifecycleLock.unlock()
        guard let binding,
              binding.sandbox.endOperation(operation, reason: reason) else { return }

        contextLifecycleLock.lock()
        operationBindings.removeValue(forKey: operation.id)
        if currentOperationID == operation.id {
            currentOperationID = nil
        }
        contextLifecycleLock.unlock()
        invalidateGeneration(binding.generationID)
    }

    func hasJavaScriptFunction(named name: String) async -> Bool {
        guard let worker else { return false }
        return await withCheckedContinuation { continuation in
            let response = JSCallbackDeadline<Bool> { value in
                continuation.resume(returning: value)
            }
            worker.async({ [weak self, response] in
                guard let self,
                      !self.isControllerExecutionPoisoned,
                      let runtime = self.loadedRuntime,
                      self.isGenerationActive(runtime.generationID),
                      let value = runtime.context.objectForKeyedSubscript(name) else {
                    response.finish(with: false)
                    return
                }
                response.finish(with: !value.isUndefined && !value.isNull)
            }, ifUnavailable: { [response] in
                response.finish(with: false)
            }, ifRerouted: { [weak self] destinationLane in
                guard let self else { return }
                self.prepareForWorkerMigration(
                    identity: self.desiredIdentity,
                    destinationLane: destinationLane
                )
            })
        }
    }

    /// Converts the string contract returned by a service Promise without
    /// first accepting an arbitrarily large JavaScript value. JavaScript's
    /// string length is measured in UTF-16 code units, which is never greater
    /// than the corresponding UTF-8 byte budget for the same scalar content;
    /// the byte check remains authoritative after conversion.
    static func boundedUTF8Data(from value: JSValue, maximumBytes: Int) -> Data? {
        guard maximumBytes > 0, value.isString else { return nil }
        if let lengthValue = value.forProperty("length"), lengthValue.isNumber {
            let length = lengthValue.toDouble()
            guard length.isFinite,
                  length >= 0,
                  length <= Double(maximumBytes) else {
                return nil
            }
        }
        guard let string = value.toString(),
              let data = string.data(using: .utf8),
              data.count <= maximumBytes else {
            return nil
        }
        return data
    }

    static func isThenable(_ value: JSValue) -> Bool {
        guard value.isObject,
              let then = value.objectForKeyedSubscript("then"),
              !then.isUndefined,
              !then.isNull else {
            return false
        }
        return true
    }

    private func runtimeDefinition(for service: Service?) -> RuntimeDefinition? {
        if let service {
            return RuntimeDefinition(
                script: service.jsScript,
                service: service,
                identity: ServiceJavaScriptIdentity(service: service),
                profileID: ProfileManager.shared.activeProfileID
            )
        }
        contextLifecycleLock.lock()
        let definition = desiredDefinition
        contextLifecycleLock.unlock()
        return definition
    }

    private func ensureRuntime(
        _ definition: RuntimeDefinition,
        generationLease: ServiceJavaScriptGenerationLease?
    ) -> LoadedRuntime? {
        if let loadedRuntime,
           loadedRuntime.definition.identity == definition.identity,
           loadedRuntime.definition.script == definition.script,
           isGenerationActive(loadedRuntime.generationID) {
            generationLease?.install(loadedRuntime.generationID)
            return loadedRuntime
        }
        return installRuntime(definition, generationLease: generationLease)
    }

    private func installRuntime(
        _ definition: RuntimeDefinition,
        generationLease: ServiceJavaScriptGenerationLease?
    ) -> LoadedRuntime? {
        if let identity = definition.identity, quarantineStore.isQuarantined(identity) {
            return nil
        }

        let generationID = UUID()
        generationLease?.install(generationID)
        let sandbox = ServiceSandboxState()
        sandbox.configureBrowserIsolation(
            profileID: definition.profileID,
            serviceID: definition.identity?.serviceID
        )
        sandbox.installJavaScriptScheduler { [weak self] work in
            self?.scheduleJavaScriptCallback(
                generationID: generationID,
                identity: definition.identity,
                work: work
            )
        }
        let previousSandbox: ServiceSandboxState?
        contextLifecycleLock.lock()
        if let previousGenerationID = activeGenerationID {
            previousSandbox = generationSandboxes.removeValue(forKey: previousGenerationID)
        } else {
            previousSandbox = nil
        }
        activeGenerationID = generationID
        generationSandboxes[generationID] = sandbox
        contextLifecycleLock.unlock()
        previousSandbox?.invalidate()

        guard let context = JSContext() else {
            invalidateGeneration(generationID)
            return nil
        }
        let serviceSession = ServiceJavaScriptSessionRegistry.shared.session(
            profileID: definition.profileID,
            serviceID: definition.identity?.serviceID
        )
        sandbox.configureNetworkSession(serviceSession)
        context.setupJavaScriptEnvironment(
            sandbox: sandbox,
            serviceSession: serviceSession
        )
        sandbox.beginLoading(identity: definition.identity)
        let runtimeScript: String
#if os(tvOS)
        if let service = definition.service {
            runtimeScript = TVServiceSettingVault.hydrating(
                definition.script,
                serviceID: service.id
            )
        } else {
            runtimeScript = definition.script
        }
#else
        runtimeScript = definition.script
#endif
        context.evaluateScript(runtimeScript)
        sandbox.endLoading()

        guard isGenerationActive(generationID) else { return nil }
        if context.exception != nil {
            Logger.shared.log(
                "Service load JavaScript exception; untrusted body suppressed",
                type: "Error"
            )
        }
        let runtime = LoadedRuntime(
            generationID: generationID,
            definition: definition,
            context: context,
            sandbox: sandbox
        )
        loadedRuntime = runtime
        return runtime
    }

    private func scheduleJavaScriptCallback(
        generationID: UUID,
        identity: ServiceJavaScriptIdentity?,
        work: @escaping () -> Void
    ) {
        guard isGenerationActive(generationID) else { return }
        let boundary = ServiceJavaScriptBoundary()
        boundary.armTimeout(nanoseconds: Self.callbackTimeoutNanoseconds) { [weak self] prior in
            guard let self, prior == .running else { return }
            if let identity {
                self.quarantineStore.recordNonYieldingBoundary(
                    identity: identity,
                    operation: "promise-callback"
                )
            }
            self.poisonControllerExecution()
            self.retireExecutingWorkerLane()
            self.invalidateGeneration(generationID)
        }
        guard let worker else {
            boundary.finish()
            return
        }
        worker.async({ [weak self, boundary] in
            guard let self,
                  !self.isControllerExecutionPoisoned,
                  self.isGenerationActive(generationID) else {
                boundary.finish()
                return
            }
            guard boundary.begin() else { return }
            work()
            boundary.finish()
        }, ifUnavailable: { [boundary] in
            boundary.finish()
        }, ifRerouted: { [weak self] destinationLane in
            self?.prepareForWorkerMigration(
                identity: identity,
                destinationLane: destinationLane
            )
        })
    }

    private func bind(_ operation: ServiceSandboxOperation, to runtime: LoadedRuntime) {
        contextLifecycleLock.lock()
        operationBindings[operation.id] = OperationBinding(
            generationID: runtime.generationID,
            sandbox: runtime.sandbox
        )
        currentOperationID = operation.id
        contextLifecycleLock.unlock()
    }

    private func invalidateGeneration(_ generationID: UUID) {
        let sandbox: ServiceSandboxState?
        contextLifecycleLock.lock()
        if activeGenerationID == generationID {
            activeGenerationID = nil
        }
        sandbox = generationSandboxes.removeValue(forKey: generationID)
        contextLifecycleLock.unlock()
        sandbox?.invalidate()
    }

    private func isGenerationActive(_ generationID: UUID) -> Bool {
        contextLifecycleLock.lock()
        let active = activeGenerationID == generationID
        contextLifecycleLock.unlock()
        return active
    }

    private func isLatestLoadToken(_ token: UUID) -> Bool {
        contextLifecycleLock.lock()
        let isLatest = latestLoadToken == token
        contextLifecycleLock.unlock()
        return isLatest
    }

    private var desiredIdentity: ServiceJavaScriptIdentity? {
        contextLifecycleLock.lock()
        let identity = desiredDefinition?.identity
        contextLifecycleLock.unlock()
        return identity
    }

    private var isControllerExecutionPoisoned: Bool {
        contextLifecycleLock.lock()
        let poisoned = executionPoisoned
        contextLifecycleLock.unlock()
        return poisoned
    }

    private func poisonControllerExecution() {
        contextLifecycleLock.lock()
        executionPoisoned = true
        contextLifecycleLock.unlock()
    }

    private func retireExecutingWorkerLane() {
        contextLifecycleLock.lock()
        let lane = executingWorkerLane
        contextLifecycleLock.unlock()
        lane?.markPermanentlyUnavailable()
    }

    /// A physical worker queue can be lost to another controller's hostile
    /// synchronous script. Recreate this controller's JSC state whenever its
    /// physical destination changes; JavaScriptCore contexts themselves are
    /// never moved between threads. The controller that caused the timeout is
    /// poisoned before the lane is retired and therefore cannot race its stuck
    /// context on a replacement lane.
    private func prepareForWorkerMigration(
        identity: ServiceJavaScriptIdentity?,
        destinationLane: ServiceJavaScriptWorkerLane
    ) {
        guard let identity, !quarantineStore.isQuarantined(identity) else { return }

        let sandboxes: [ServiceSandboxState]
        contextLifecycleLock.lock()
        guard !executionPoisoned else {
            contextLifecycleLock.unlock()
            return
        }
        let previousLane = executingWorkerLane
        executingWorkerLane = destinationLane
        guard previousLane.map({ $0 !== destinationLane }) ?? true else {
            contextLifecycleLock.unlock()
            return
        }
        sandboxes = Array(generationSandboxes.values)
        generationSandboxes.removeAll(keepingCapacity: false)
        operationBindings.removeAll(keepingCapacity: false)
        activeGenerationID = nil
        currentOperationID = nil
        contextLifecycleLock.unlock()

        // This hook runs on the replacement serial worker immediately before
        // its first job for this controller.
        loadedRuntime = nil
        sandboxes.forEach { $0.invalidate() }
    }

    private func logWorkerPoolUnavailable() {
        Logger.shared.log(
            "Service JavaScript worker budget exhausted by non-yielding code; service execution is disabled until Eclipse restarts",
            type: "ServiceSandbox"
        )
    }
}
