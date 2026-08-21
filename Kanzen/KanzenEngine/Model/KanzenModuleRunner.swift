//
//  KanzenModuleRunner.swift
//  Kanzen
//
//  Created by Dawud Osman on 12/05/2025.
//

import Foundation
import JavaScriptCore

struct KanzenLegacyJavaScriptIdentity: Equatable {
    let moduleID: UUID
    let scriptFingerprint: String
    let moduleName: String

    init(moduleID: UUID, script: String, moduleName: String) {
        self.moduleID = moduleID
        scriptFingerprint = script.sha256
        self.moduleName = moduleName
    }
}

enum KanzenLegacyJavaScriptError: LocalizedError {
    case quarantined
    case workerBudgetExhausted
    case executionTimedOut
    case promiseTimedOut
    case scriptLoadFailed
    case contextUnavailable
    case functionUnavailable(String)
    case invalidResult
    case superseded

    var errorDescription: String? {
        switch self {
        case .quarantined:
            return "This legacy Reader module was disabled after non-yielding JavaScript. Re-enable it explicitly to retry."
        case .workerBudgetExhausted:
            return "Legacy Reader JavaScript is unavailable until Eclipse restarts because both worker lanes stopped yielding."
        case .executionTimedOut:
            return "The legacy Reader module stopped yielding and was disabled."
        case .promiseTimedOut:
            return "The legacy Reader module did not finish in time."
        case .scriptLoadFailed:
            return "The legacy Reader module could not be loaded."
        case .contextUnavailable:
            return "The legacy Reader JavaScript context is unavailable."
        case .functionUnavailable(let name):
            return "The legacy Reader module does not provide \(name)."
        case .invalidResult:
            return "The legacy Reader module returned invalid or oversized data."
        case .superseded:
            return "The legacy Reader module load was superseded."
        }
    }
}

/// Device-local health for the old Kanzen module ABI. This deliberately has a
/// different key and domain from Service JavaScript quarantine. A quarantine
/// follows the stable installed-module UUID across script updates and is only
/// relaxed for one UUID at a time by explicit re-enable/removal.
final class KanzenLegacyJavaScriptQuarantineStore: @unchecked Sendable {
    static let shared = KanzenLegacyJavaScriptQuarantineStore()
    static let storageKey = "kanzenLegacyJavaScriptExecutionHealthV1"
    private static let maximumModuleDomainCount = 256
    private static let maximumStorageBytes = 256 * 1_024

    private struct Entry: Codable {
        var fingerprint: String
        var strikeCount: Int
        var quarantined: Bool
        var updatedAt: TimeInterval
    }

    private struct State: Codable {
        var entries: [String: Entry]
        var failClosedOverflow: Bool
        var explicitlyClearedModuleIDs: Set<String>

        static let empty = State(
            entries: [:],
            failClosedOverflow: false,
            explicitlyClearedModuleIDs: []
        )

        func isQuarantined(moduleID: String) -> Bool {
            if entries[moduleID]?.quarantined == true { return true }
            return failClosedOverflow && !explicitlyClearedModuleIDs.contains(moduleID)
        }
    }

    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isQuarantined(_ identity: KanzenLegacyJavaScriptIdentity) -> Bool {
        isQuarantined(moduleID: identity.moduleID)
    }

    func isQuarantined(moduleID: UUID) -> Bool {
        lock.lock()
        let result = loadStateLocked().isQuarantined(moduleID: moduleID.uuidString)
        lock.unlock()
        return result
    }

    @discardableResult
    func recordNonYieldingBoundary(
        identity: KanzenLegacyJavaScriptIdentity,
        operation: String
    ) -> Bool {
        lock.lock()
        var state = loadStateLocked()
        let key = identity.moduleID.uuidString
        let wasQuarantined = state.isQuarantined(moduleID: key)
        var entry = state.entries[key] ?? Entry(
            fingerprint: identity.scriptFingerprint,
            strikeCount: 0,
            quarantined: false,
            updatedAt: 0
        )
        entry.fingerprint = identity.scriptFingerprint
        entry.strikeCount = max(entry.strikeCount, 1)
        entry.quarantined = true
        entry.updatedAt = Date().timeIntervalSince1970
        state.explicitlyClearedModuleIDs.remove(key)
        if state.entries[key] != nil || state.entries.count < Self.maximumModuleDomainCount {
            state.entries[key] = entry
        } else {
            // Never evict an older quarantine to make room for a new one.
            state.failClosedOverflow = true
        }
        saveStateLocked(state)
        let becameQuarantined = !wasQuarantined && state.isQuarantined(moduleID: key)
        lock.unlock()

        ReaderLogger.shared.log(
            "Legacy module JavaScript failed to yield module=\(identity.moduleName) operation=\(operation); module quarantined",
            type: "Error"
        )
        return becameQuarantined
    }

    func clear(moduleID: UUID) {
        lock.lock()
        var state = loadStateLocked()
        let key = moduleID.uuidString
        let removed = state.entries.removeValue(forKey: key) != nil
        var explicitlyCleared = false
        if state.failClosedOverflow,
           state.explicitlyClearedModuleIDs.count < Self.maximumModuleDomainCount
                || state.explicitlyClearedModuleIDs.contains(key) {
            explicitlyCleared = state.explicitlyClearedModuleIDs.insert(key).inserted
        }
        if removed || explicitlyCleared {
            saveStateLocked(state)
        }
        lock.unlock()
    }

    @discardableResult
    func clearAfterDurableModuleRemoval(
        moduleID: UUID,
        metadataRemovalPersisted: Bool
    ) -> Bool {
        guard metadataRemovalPersisted else { return false }
        clear(moduleID: moduleID)
        return !isQuarantined(moduleID: moduleID)
    }

    func strikeCount(for identity: KanzenLegacyJavaScriptIdentity) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let state = loadStateLocked()
        if let entry = state.entries[identity.moduleID.uuidString] {
            return entry.strikeCount
        }
        return state.isQuarantined(moduleID: identity.moduleID.uuidString) ? 1 : 0
    }

    private func loadStateLocked() -> State {
        guard let data = defaults.data(forKey: Self.storageKey) else { return .empty }
        guard data.count <= Self.maximumStorageBytes,
              let state = try? JSONDecoder().decode(State.self, from: data),
              isValid(state) else {
            return failClosedState()
        }
        return state
    }

    private func saveStateLocked(_ state: State) {
        if let data = try? JSONEncoder().encode(state),
           data.count <= Self.maximumStorageBytes {
            defaults.set(data, forKey: Self.storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(failClosedState()) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func failClosedState() -> State {
        State(entries: [:], failClosedOverflow: true, explicitlyClearedModuleIDs: [])
    }

    private func isValid(_ state: State) -> Bool {
        guard state.entries.count <= Self.maximumModuleDomainCount,
              state.explicitlyClearedModuleIDs.count <= Self.maximumModuleDomainCount,
              state.entries.keys.allSatisfy({ UUID(uuidString: $0) != nil }),
              state.explicitlyClearedModuleIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            return false
        }
        return state.entries.values.allSatisfy {
            $0.fingerprint.utf8.count <= 1_024
                && (0...1_000_000).contains($0.strikeCount)
                && $0.updatedAt.isFinite
        }
    }
}

private final class KanzenLegacyCompletionGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Result<Value, Error>) -> Void)?
    private var timeout: DispatchWorkItem?

    init(_ completion: @escaping (Result<Value, Error>) -> Void) {
        self.completion = completion
    }

    var isFinished: Bool {
        lock.lock()
        let finished = completion == nil
        lock.unlock()
        return finished
    }

    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        let completion: ((Result<Value, Error>) -> Void)?
        let timeout: DispatchWorkItem?
        lock.lock()
        completion = self.completion
        self.completion = nil
        timeout = self.timeout
        self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        completion?(result)
        return completion != nil
    }

    func armTimeout(
        after nanoseconds: UInt64,
        on queue: DispatchQueue,
        error: @autoclosure @escaping () -> Error
    ) {
        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure(error()))
        }
        lock.lock()
        guard completion != nil else {
            lock.unlock()
            work.cancel()
            return
        }
        timeout?.cancel()
        timeout = work
        lock.unlock()
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(min(nanoseconds, UInt64(Int.max)))),
            execute: work
        )
    }
}

final class KanzenLegacyJavaScriptBoundary: @unchecked Sendable {
    private enum Phase {
        case queued
        case running
        case finished
        case timedOut
    }

    private let lock = NSLock()
    private var phase: Phase = .queued
    private var timeout: DispatchWorkItem?

    func begin(
        timeoutNanoseconds: UInt64,
        timeoutQueue: DispatchQueue,
        onTimeout: @escaping () -> Void
    ) -> Bool {
        let work = DispatchWorkItem { [weak self] in
            guard self?.timeOutRunningBoundary() == true else { return }
            onTimeout()
        }
        lock.lock()
        guard phase == .queued else {
            lock.unlock()
            return false
        }
        phase = .running
        timeout = work
        lock.unlock()
        timeoutQueue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(min(timeoutNanoseconds, UInt64(Int.max)))),
            execute: work
        )
        return true
    }

    @discardableResult
    func finish() -> Bool {
        let timeout: DispatchWorkItem?
        lock.lock()
        guard phase == .running else {
            lock.unlock()
            return false
        }
        phase = .finished
        timeout = self.timeout
        self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        return true
    }

    private func timeOutRunningBoundary() -> Bool {
        lock.lock()
        guard phase == .running else {
            lock.unlock()
            return false
        }
        phase = .timedOut
        timeout = nil
        lock.unlock()
        return true
    }
}

final class KanzenLegacyJavaScriptWorkerLane: @unchecked Sendable {
    fileprivate struct Job {
        let work: () -> Void
        let unavailable: () -> Void
        let rerouted: (KanzenLegacyJavaScriptWorkerLane) -> Void
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private weak var pool: KanzenLegacyJavaScriptWorkerPool?
    private var permanentlyUnavailable = false
    private var isRunning = false
    private var pendingJobs: [(Job, Bool)] = []
    private let maximumPendingJobs = 64

    fileprivate init(index: Int) {
        queue = DispatchQueue(
            label: "app.eclipse.kanzen-legacy-javascript.worker.\(index)",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        )
    }

    fileprivate func installPool(_ pool: KanzenLegacyJavaScriptWorkerPool) {
        lock.lock()
        self.pool = pool
        lock.unlock()
    }

    @discardableResult
    func async(
        _ work: @escaping () -> Void,
        ifUnavailable: @escaping () -> Void,
        ifRerouted: @escaping (KanzenLegacyJavaScriptWorkerLane) -> Void
    ) -> Bool {
        accept(
            Job(work: work, unavailable: ifUnavailable, rerouted: ifRerouted),
            wasRerouted: false,
            mayReroute: true,
            rejectOnFailure: true
        )
    }

    @discardableResult
    private func accept(
        _ job: Job,
        wasRerouted: Bool,
        mayReroute: Bool,
        rejectOnFailure: Bool
    ) -> Bool {
        let shouldStart: Bool
        let reroutePool: KanzenLegacyJavaScriptWorkerPool?
        lock.lock()
        if permanentlyUnavailable {
            reroutePool = pool
            lock.unlock()
            if mayReroute, reroutePool?.reroute(job, from: self) == true { return true }
            if rejectOnFailure { job.unavailable() }
            return false
        }
        guard pendingJobs.count < maximumPendingJobs else {
            lock.unlock()
            if rejectOnFailure { job.unavailable() }
            return false
        }
        if isRunning {
            pendingJobs.append((job, wasRerouted))
            shouldStart = false
        } else {
            isRunning = true
            shouldStart = true
        }
        lock.unlock()
        if shouldStart { dispatch(job, wasRerouted: wasRerouted) }
        return true
    }

    func markPermanentlyUnavailable() {
        let pending: [Job]
        let reroutePool: KanzenLegacyJavaScriptWorkerPool?
        lock.lock()
        guard !permanentlyUnavailable else {
            lock.unlock()
            return
        }
        permanentlyUnavailable = true
        pending = pendingJobs.map(\.0)
        pendingJobs.removeAll(keepingCapacity: false)
        reroutePool = pool
        lock.unlock()

        for job in pending where reroutePool?.reroute(job, from: self) != true {
            job.unavailable()
        }
    }

    var isAvailable: Bool {
        lock.lock()
        let result = !permanentlyUnavailable
        lock.unlock()
        return result
    }

    private func dispatch(_ job: Job, wasRerouted: Bool) {
        queue.async { [weak self] in
            guard let self else {
                job.unavailable()
                return
            }
            guard isAvailable else {
                lock.lock()
                let reroutePool = pool
                lock.unlock()
                if reroutePool?.reroute(job, from: self) != true {
                    job.unavailable()
                }
                finishCurrentJob()
                return
            }
            if wasRerouted { job.rerouted(self) }
            job.work()
            finishCurrentJob()
        }
    }

    private func finishCurrentJob() {
        let next: (Job, Bool)?
        lock.lock()
        if permanentlyUnavailable || pendingJobs.isEmpty {
            isRunning = false
            next = nil
        } else {
            next = pendingJobs.removeFirst()
        }
        lock.unlock()
        if let next { dispatch(next.0, wasRerouted: next.1) }
    }

    fileprivate func acceptRerouted(_ job: Job) -> Bool {
        accept(job, wasRerouted: true, mayReroute: false, rejectOnFailure: false)
    }
}

final class KanzenLegacyJavaScriptWorkerPool: @unchecked Sendable {
    static let shared = KanzenLegacyJavaScriptWorkerPool(maximumConcurrentWorkers: 2)

    private let lock = NSLock()
    private let lanes: [KanzenLegacyJavaScriptWorkerLane]
    private var nextLane = 0

    init(maximumConcurrentWorkers: Int = 2) {
        // Production and tests both use the same fixed physical-lane budget.
        precondition(maximumConcurrentWorkers == 2)
        lanes = (0..<maximumConcurrentWorkers).map(KanzenLegacyJavaScriptWorkerLane.init)
        lanes.forEach { $0.installPool(self) }
    }

    func leaseLane() -> KanzenLegacyJavaScriptWorkerLane? {
        lock.lock()
        let start = nextLane
        var result: KanzenLegacyJavaScriptWorkerLane?
        repeat {
            let candidate = lanes[nextLane]
            nextLane = (nextLane + 1) % lanes.count
            if candidate.isAvailable {
                result = candidate
                break
            }
        } while nextLane != start
        lock.unlock()
        return result
    }

    var physicalLaneCount: Int { lanes.count }

    var availableLaneCount: Int {
        lanes.reduce(into: 0) { count, lane in
            if lane.isAvailable { count += 1 }
        }
    }

    fileprivate func reroute(
        _ job: KanzenLegacyJavaScriptWorkerLane.Job,
        from unavailableLane: KanzenLegacyJavaScriptWorkerLane
    ) -> Bool {
        lock.lock()
        let start = nextLane
        var candidates: [KanzenLegacyJavaScriptWorkerLane] = []
        repeat {
            let candidate = lanes[nextLane]
            nextLane = (nextLane + 1) % lanes.count
            if candidate !== unavailableLane, candidate.isAvailable {
                candidates.append(candidate)
            }
        } while nextLane != start
        lock.unlock()

        return candidates.contains { $0.acceptRerouted(job) }
    }
}

/// Owns the bounded timers and native network tasks created by one JSC
/// generation. Invalidation cancels every registered operation and suppresses
/// late JSValue callbacks.
final class KanzenLegacyJavaScriptRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var timers: [UUID: DispatchWorkItem] = [:]
    private var nativeReservations: Set<UUID> = []
    private var nativeTasks: [UUID: Task<Void, Never>] = [:]
    private let scheduler: (@escaping () -> Void) -> Void
    private let maximumTimers = 64
    private let maximumNativeOperations = 16

    init(scheduler: @escaping (@escaping () -> Void) -> Void) {
        self.scheduler = scheduler
    }

    func scheduleJavaScript(_ work: @escaping () -> Void) {
        lock.lock()
        let shouldSchedule = active
        lock.unlock()
        if shouldSchedule { scheduler(work) }
    }

    @discardableResult
    func scheduleTimer(delayMilliseconds: Double, work: @escaping () -> Void) -> Bool {
        let id = UUID()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lock.lock()
            timers.removeValue(forKey: id)
            let shouldRun = active
            lock.unlock()
            if shouldRun { scheduleJavaScript(work) }
        }
        lock.lock()
        guard active, timers.count < maximumTimers else {
            lock.unlock()
            return false
        }
        timers[id] = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + delayMilliseconds / 1_000,
            execute: item
        )
        return true
    }

    func reserveNativeOperation() -> KanzenLegacyNativeOperationLease? {
        lock.lock()
        guard active, nativeReservations.count < maximumNativeOperations else {
            lock.unlock()
            return nil
        }
        let id = UUID()
        nativeReservations.insert(id)
        lock.unlock()
        return KanzenLegacyNativeOperationLease(id: id, state: self)
    }

    fileprivate func installNativeTask(_ task: Task<Void, Never>, id: UUID) -> Bool {
        lock.lock()
        guard active, nativeReservations.contains(id) else {
            lock.unlock()
            task.cancel()
            return false
        }
        nativeTasks[id] = task
        lock.unlock()
        return true
    }

    fileprivate func finishNativeOperation(id: UUID) {
        lock.lock()
        nativeReservations.remove(id)
        nativeTasks.removeValue(forKey: id)
        lock.unlock()
    }

    func invalidate() {
        let timers: [DispatchWorkItem]
        let tasks: [Task<Void, Never>]
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        timers = Array(self.timers.values)
        tasks = Array(nativeTasks.values)
        self.timers.removeAll(keepingCapacity: false)
        nativeReservations.removeAll(keepingCapacity: false)
        nativeTasks.removeAll(keepingCapacity: false)
        lock.unlock()
        timers.forEach { $0.cancel() }
        tasks.forEach { $0.cancel() }
    }
}

final class KanzenLegacyNativeOperationLease: @unchecked Sendable {
    private let lock = NSLock()
    private let id: UUID
    private weak var state: KanzenLegacyJavaScriptRuntimeState?
    private var finished = false

    fileprivate init(id: UUID, state: KanzenLegacyJavaScriptRuntimeState) {
        self.id = id
        self.state = state
    }

    @discardableResult
    func install(_ task: Task<Void, Never>) -> Bool {
        lock.lock()
        let canInstall = !finished
        lock.unlock()
        guard canInstall, let state else {
            task.cancel()
            return false
        }
        return state.installNativeTask(task, id: id)
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let state = self.state
        self.state = nil
        lock.unlock()
        state?.finishNativeOperation(id: id)
    }
}

final class KanzenModuleRunner: @unchecked Sendable {
    struct Timeouts {
        var loadNanoseconds: UInt64 = 10_000_000_000
        var functionNanoseconds: UInt64 = 5_000_000_000
        var callbackNanoseconds: UInt64 = 5_000_000_000
        var promiseNanoseconds: UInt64 = 12_000_000_000
    }

    private struct RuntimeDefinition: Equatable {
        let script: String
        let isNovel: Bool
        let identity: KanzenLegacyJavaScriptIdentity
    }

    private final class LoadedRuntime {
        let generationID: UUID
        let definition: RuntimeDefinition
        let context: JSContext
        let resultConverter: JSValue
        let state: KanzenLegacyJavaScriptRuntimeState

        init(
            generationID: UUID,
            definition: RuntimeDefinition,
            context: JSContext,
            resultConverter: JSValue,
            state: KanzenLegacyJavaScriptRuntimeState
        ) {
            self.generationID = generationID
            self.definition = definition
            self.context = context
            self.resultConverter = resultConverter
            self.state = state
        }
    }

    private static let timeoutQueue = DispatchQueue(
        label: "app.eclipse.kanzen-legacy-javascript.deadlines",
        qos: .utility
    )
    private static let boundedResultScript = #"""
    (function() {
        return function eclipseBoundedLegacyResult(value) {
            const seen = new WeakSet();
            let nodes = 0;
            function copy(input, depth) {
                nodes += 1;
                if (nodes > 4096 || depth > 8) throw new Error('result limit');
                if (input === null || input === undefined) return null;
                const kind = typeof input;
                if (kind === 'string') {
                    if (input.length > 1048576) throw new Error('string limit');
                    return input;
                }
                if (kind === 'boolean') return input;
                if (kind === 'number') return Number.isFinite(input) ? input : null;
                if (kind !== 'object') return null;
                if (seen.has(input)) throw new Error('cyclic result');
                seen.add(input);
                if (Array.isArray(input)) {
                    if (input.length > 512) throw new Error('array limit');
                    const output = [];
                    for (let index = 0; index < input.length; index += 1) {
                        output.push(copy(input[index], depth + 1));
                    }
                    return output;
                }
                const output = {};
                let count = 0;
                for (const key in input) {
                    if (!Object.prototype.hasOwnProperty.call(input, key)) continue;
                    count += 1;
                    if (count > 128 || key.length > 1024) throw new Error('object limit');
                    output[key] = copy(input[key], depth + 1);
                }
                return output;
            }
            try {
                const json = JSON.stringify(copy(value, 0));
                return typeof json === 'string' && json.length <= 2097152 ? json : null;
            } catch (_) {
                return null;
            }
        };
    })()
    """#

    private let initialWorker: KanzenLegacyJavaScriptWorkerLane?
    private let quarantineStore: KanzenLegacyJavaScriptQuarantineStore
    private let timeouts: Timeouts
    private let lifecycleLock = NSRecursiveLock()
    private var executingWorker: KanzenLegacyJavaScriptWorkerLane?
    private var desiredDefinition: RuntimeDefinition?
    private var latestLoadToken: UUID?
    private var loadedRuntime: LoadedRuntime?
    private var installingRuntimeState: KanzenLegacyJavaScriptRuntimeState?
    private var executionPoisoned = false

    init(
        workerPool: KanzenLegacyJavaScriptWorkerPool = .shared,
        quarantineStore: KanzenLegacyJavaScriptQuarantineStore = .shared,
        timeouts: Timeouts = Timeouts()
    ) {
        initialWorker = workerPool.leaseLane()
        executingWorker = initialWorker
        self.quarantineStore = quarantineStore
        self.timeouts = timeouts
    }

    deinit {
        lifecycleLock.lock()
        let states = [loadedRuntime?.state, installingRuntimeState].compactMap { $0 }
        lifecycleLock.unlock()
        states.forEach { $0.invalidate() }
    }

    func loadScript(
        _ script: String,
        moduleID: UUID,
        moduleName: String,
        isNovel: Bool = false
    ) async throws {
        let definition = RuntimeDefinition(
            script: script,
            isNovel: isNovel,
            identity: KanzenLegacyJavaScriptIdentity(
                moduleID: moduleID,
                script: script,
                moduleName: moduleName
            )
        )
        if quarantineStore.isQuarantined(definition.identity) {
            throw KanzenLegacyJavaScriptError.quarantined
        }
        let token = UUID()
        lifecycleLock.lock()
        desiredDefinition = definition
        latestLoadToken = token
        lifecycleLock.unlock()

        try await withCheckedThrowingContinuation { continuation in
            let gate = KanzenLegacyCompletionGate<Void> { result in
                continuation.resume(with: result)
            }
            submit(
                operation: "loadScript",
                identity: definition.identity,
                timeoutNanoseconds: timeouts.loadNanoseconds,
                gate: gate
            ) { [weak self] boundary in
                guard let self else {
                    gate.finish(.failure(KanzenLegacyJavaScriptError.contextUnavailable))
                    return
                }
                guard isLatestLoad(token) else {
                    boundary.finish()
                    gate.finish(.failure(KanzenLegacyJavaScriptError.superseded))
                    return
                }
                do {
                    _ = try installRuntime(definition)
                    if boundary.finish() {
                        gate.finish(.success(()))
                    }
                } catch {
                    if boundary.finish() {
                        gate.finish(.failure(error))
                    }
                }
            }
        }
    }

    func invoke(
        _ functionName: String,
        arguments: [Any],
        optional: Bool = false
    ) async throws -> Any? {
        guard let definition = currentDefinition() else {
            throw KanzenLegacyJavaScriptError.contextUnavailable
        }
        if quarantineStore.isQuarantined(definition.identity) {
            throw KanzenLegacyJavaScriptError.quarantined
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = KanzenLegacyCompletionGate<Any?> { result in
                continuation.resume(with: result)
            }
            submit(
                operation: functionName,
                identity: definition.identity,
                timeoutNanoseconds: timeouts.functionNanoseconds,
                gate: gate
            ) { [weak self] boundary in
                guard let self else {
                    gate.finish(.failure(KanzenLegacyJavaScriptError.contextUnavailable))
                    return
                }
                do {
                    let runtime = try ensureRuntime(definition)
                    guard let function = runtime.context.objectForKeyedSubscript(functionName),
                          !function.isUndefined, !function.isNull else {
                        if boundary.finish() {
                            if optional {
                                gate.finish(.success(nil))
                            } else {
                                gate.finish(.failure(KanzenLegacyJavaScriptError.functionUnavailable(functionName)))
                            }
                        }
                        return
                    }
                    runtime.context.exception = nil
                    guard let result = function.call(withArguments: arguments) else {
                        throw KanzenLegacyJavaScriptError.invalidResult
                    }
                    if runtime.context.exception != nil {
                        throw KanzenLegacyJavaScriptError.invalidResult
                    }
                    if result.hasProperty("then") {
                        attachPromise(
                            result,
                            runtime: runtime,
                            operation: functionName,
                            gate: gate
                        )
                        _ = boundary.finish()
                        gate.armTimeout(
                            after: timeouts.promiseNanoseconds,
                            on: Self.timeoutQueue,
                            error: KanzenLegacyJavaScriptError.promiseTimedOut
                        )
                    } else {
                        let value = try boundedFoundationValue(result, runtime: runtime)
                        if boundary.finish() {
                            gate.finish(.success(value))
                        }
                    }
                } catch {
                    if boundary.finish() {
                        gate.finish(.failure(error))
                    }
                }
            }
        }
    }

    private func submit<Value>(
        operation: String,
        identity: KanzenLegacyJavaScriptIdentity,
        timeoutNanoseconds: UInt64,
        gate: KanzenLegacyCompletionGate<Value>,
        body: @escaping (KanzenLegacyJavaScriptBoundary) -> Void
    ) {
        guard let initialWorker else {
            gate.finish(.failure(KanzenLegacyJavaScriptError.workerBudgetExhausted))
            return
        }
        let boundary = KanzenLegacyJavaScriptBoundary()
        initialWorker.async({ [weak self] in
            guard let self, !isExecutionPoisoned else {
                gate.finish(.failure(KanzenLegacyJavaScriptError.contextUnavailable))
                return
            }
            guard !quarantineStore.isQuarantined(identity) else {
                gate.finish(.failure(KanzenLegacyJavaScriptError.quarantined))
                return
            }
            guard boundary.begin(
                timeoutNanoseconds: timeoutNanoseconds,
                timeoutQueue: Self.timeoutQueue,
                onTimeout: { [weak self] in
                    guard let self else { return }
                    quarantineStore.recordNonYieldingBoundary(
                        identity: identity,
                        operation: operation
                    )
                    poisonExecution()
                    retireExecutingWorker()
                    gate.finish(.failure(KanzenLegacyJavaScriptError.executionTimedOut))
                }
            ) else { return }
            body(boundary)
        }, ifUnavailable: {
            gate.finish(.failure(KanzenLegacyJavaScriptError.workerBudgetExhausted))
        }, ifRerouted: { [weak self] destination in
            self?.prepareForWorkerMigration(destination)
        })
    }

    private func attachPromise(
        _ promise: JSValue,
        runtime: LoadedRuntime,
        operation: String,
        gate: KanzenLegacyCompletionGate<Any?>
    ) {
        let resolve: @convention(block) (JSValue) -> Void = { [weak self, weak runtime] value in
            guard let self, let runtime else {
                gate.finish(.failure(KanzenLegacyJavaScriptError.contextUnavailable))
                return
            }
            scheduleResultConversion(
                value,
                runtime: runtime,
                operation: "\(operation)-promise-result",
                gate: gate
            )
        }
        let reject: @convention(block) (JSValue) -> Void = { _ in
            gate.finish(.failure(KanzenLegacyJavaScriptError.invalidResult))
        }
        guard let resolveValue = JSValue(object: resolve, in: runtime.context),
              let rejectValue = JSValue(object: reject, in: runtime.context) else {
            gate.finish(.failure(KanzenLegacyJavaScriptError.contextUnavailable))
            return
        }
        promise.invokeMethod("then", withArguments: [resolveValue])
        promise.invokeMethod("catch", withArguments: [rejectValue])
    }

    private func scheduleResultConversion(
        _ value: JSValue,
        runtime: LoadedRuntime,
        operation: String,
        gate: KanzenLegacyCompletionGate<Any?>
    ) {
        if gate.isFinished { return }
        submit(
            operation: operation,
            identity: runtime.definition.identity,
            timeoutNanoseconds: timeouts.callbackNanoseconds,
            gate: gate
        ) { [weak self, weak runtime] boundary in
            guard let self, let runtime,
                  isActiveGeneration(runtime.generationID),
                  !gate.isFinished else {
                _ = boundary.finish()
                return
            }
            do {
                let result = try boundedFoundationValue(value, runtime: runtime)
                if boundary.finish() {
                    gate.finish(.success(result))
                }
            } catch {
                if boundary.finish() {
                    gate.finish(.failure(error))
                }
            }
        }
    }

    private func ensureRuntime(_ definition: RuntimeDefinition) throws -> LoadedRuntime {
        if let loadedRuntime,
           loadedRuntime.definition == definition,
           isActiveGeneration(loadedRuntime.generationID) {
            return loadedRuntime
        }
        return try installRuntime(definition)
    }

    private func installRuntime(_ definition: RuntimeDefinition) throws -> LoadedRuntime {
        guard !quarantineStore.isQuarantined(definition.identity) else {
            throw KanzenLegacyJavaScriptError.quarantined
        }
        guard let context = JSContext() else {
            throw KanzenLegacyJavaScriptError.contextUnavailable
        }
        let generationID = UUID()
        let runtimeState = KanzenLegacyJavaScriptRuntimeState { [weak self] work in
            self?.scheduleJavaScriptCallback(
                generationID: generationID,
                identity: definition.identity,
                work: work
            )
        }
        lifecycleLock.lock()
        installingRuntimeState = runtimeState
        lifecycleLock.unlock()
        defer {
            lifecycleLock.lock()
            if installingRuntimeState === runtimeState {
                installingRuntimeState = nil
            }
            lifecycleLock.unlock()
        }
        var sawException = false
        context.exceptionHandler = { _, _ in
            sawException = true
            ReaderLogger.shared.log(
                "Legacy module JavaScript exception; untrusted message omitted",
                type: "Error"
            )
        }
        if definition.isNovel {
            context.setUpNovelJSEnvironment(runtimeState: runtimeState)
        } else {
            context.setUpJSEnvirontment(runtimeState: runtimeState)
        }
        guard let converter = context.evaluateScript(Self.boundedResultScript),
              !converter.isUndefined, !converter.isNull else {
            runtimeState.invalidate()
            throw KanzenLegacyJavaScriptError.contextUnavailable
        }
        sawException = false
        context.exception = nil
        context.evaluateScript(definition.script)
        guard !sawException, context.exception == nil else {
            runtimeState.invalidate()
            throw KanzenLegacyJavaScriptError.scriptLoadFailed
        }
        let runtime = LoadedRuntime(
            generationID: generationID,
            definition: definition,
            context: context,
            resultConverter: converter,
            state: runtimeState
        )
        lifecycleLock.lock()
        let previousState = loadedRuntime?.state
        loadedRuntime = runtime
        installingRuntimeState = nil
        lifecycleLock.unlock()
        previousState?.invalidate()
        return runtime
    }

    private func boundedFoundationValue(
        _ value: JSValue,
        runtime: LoadedRuntime
    ) throws -> Any? {
        guard let boundedJSON = runtime.resultConverter.call(withArguments: [value]),
              boundedJSON.isString,
              let length = boundedJSON.forProperty("length"),
              length.isNumber,
              length.toDouble().isFinite,
              length.toDouble() <= 2_097_152,
              let string = boundedJSON.toString(),
              let data = string.data(using: .utf8),
              data.count <= 2_097_152 else {
            throw KanzenLegacyJavaScriptError.invalidResult
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func scheduleJavaScriptCallback(
        generationID: UUID,
        identity: KanzenLegacyJavaScriptIdentity,
        work: @escaping () -> Void
    ) {
        guard isActiveGeneration(generationID), let initialWorker else { return }
        let boundary = KanzenLegacyJavaScriptBoundary()
        initialWorker.async({ [weak self] in
            guard let self,
                  !isExecutionPoisoned,
                  isActiveGeneration(generationID),
                  boundary.begin(
                    timeoutNanoseconds: timeouts.callbackNanoseconds,
                    timeoutQueue: Self.timeoutQueue,
                    onTimeout: { [weak self] in
                        guard let self else { return }
                        quarantineStore.recordNonYieldingBoundary(
                            identity: identity,
                            operation: "native-callback"
                        )
                        poisonExecution()
                        retireExecutingWorker()
                    }
                  ) else { return }
            work()
            _ = boundary.finish()
        }, ifUnavailable: {}, ifRerouted: { [weak self] destination in
            self?.prepareForWorkerMigration(destination)
        })
    }

    private func prepareForWorkerMigration(
        _ destination: KanzenLegacyJavaScriptWorkerLane
    ) {
        lifecycleLock.lock()
        guard !executionPoisoned else {
            lifecycleLock.unlock()
            return
        }
        let prior = executingWorker
        executingWorker = destination
        guard prior.map({ $0 !== destination }) ?? true else {
            lifecycleLock.unlock()
            return
        }
        let previousStates = [loadedRuntime?.state, installingRuntimeState].compactMap { $0 }
        loadedRuntime = nil
        installingRuntimeState = nil
        lifecycleLock.unlock()
        previousStates.forEach { $0.invalidate() }
    }

    private func currentDefinition() -> RuntimeDefinition? {
        lifecycleLock.lock()
        let definition = desiredDefinition
        lifecycleLock.unlock()
        return definition
    }

    private func isLatestLoad(_ token: UUID) -> Bool {
        lifecycleLock.lock()
        let result = latestLoadToken == token
        lifecycleLock.unlock()
        return result
    }

    private func isActiveGeneration(_ generationID: UUID) -> Bool {
        lifecycleLock.lock()
        let result = loadedRuntime?.generationID == generationID
        lifecycleLock.unlock()
        return result
    }

    private var isExecutionPoisoned: Bool {
        lifecycleLock.lock()
        let result = executionPoisoned
        lifecycleLock.unlock()
        return result
    }

    private func poisonExecution() {
        lifecycleLock.lock()
        executionPoisoned = true
        let states = [loadedRuntime?.state, installingRuntimeState].compactMap { $0 }
        lifecycleLock.unlock()
        states.forEach { $0.invalidate() }
    }

    private func retireExecutingWorker() {
        lifecycleLock.lock()
        let worker = executingWorker
        lifecycleLock.unlock()
        worker?.markPermanentlyUnavailable()
    }
}
