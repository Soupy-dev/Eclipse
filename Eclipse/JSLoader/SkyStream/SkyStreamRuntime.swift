import Foundation
@preconcurrency import JavaScriptCore
import CryptoKit
import Security

#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
#endif

#if canImport(CommonCrypto)
import CommonCrypto
#endif

#if canImport(SwiftSoup)
import SwiftSoup
#endif

// MARK: - Public runtime surface

/// The only plugin entry points Eclipse's SkyStream runtime can invoke.
/// `getHome` is intentionally absent: SkyStream catalog/home integration is
/// outside Eclipse's supported source contract.
public enum SkyStreamABIOperation: String, Sendable, Hashable, CaseIterable {
    case search
    case load
    case loadStreams
    case getProviders
}

public struct SkyStreamRuntimeLimits: Sendable, Hashable {
    public var maximumProviders: Int
    public var maximumSearchResults: Int
    public var maximumEpisodes: Int
    public var maximumRawStreams: Int
    public var maximumSerializedResultBytes: Int
    public var maximumScriptBytes: Int
    public var searchTimeout: TimeInterval
    public var loadTimeout: TimeInterval
    public var streamTimeout: TimeInterval
    public var providerTimeout: TimeInterval
    public var idleContextLifetime: TimeInterval
    public var maximumContextsPerPackage: Int
    public var maximumContextsGlobally: Int

    public init(
        maximumProviders: Int = 64,
        maximumSearchResults: Int = 300,
        maximumEpisodes: Int = 5_000,
        maximumRawStreams: Int = 1_200,
        maximumSerializedResultBytes: Int = 10 * 1_024 * 1_024,
        maximumScriptBytes: Int = 10 * 1_024 * 1_024,
        searchTimeout: TimeInterval = 8,
        loadTimeout: TimeInterval = 8,
        streamTimeout: TimeInterval = 12,
        providerTimeout: TimeInterval = 5,
        idleContextLifetime: TimeInterval = 5 * 60,
        maximumContextsPerPackage: Int = 4,
        maximumContextsGlobally: Int = 12
    ) {
        self.maximumProviders = max(1, min(maximumProviders, 64))
        self.maximumSearchResults = max(1, min(maximumSearchResults, 300))
        self.maximumEpisodes = max(1, min(maximumEpisodes, 5_000))
        self.maximumRawStreams = max(1, min(maximumRawStreams, 1_200))
        self.maximumSerializedResultBytes = max(64 * 1_024, min(maximumSerializedResultBytes, 10 * 1_024 * 1_024))
        self.maximumScriptBytes = max(64 * 1_024, min(maximumScriptBytes, 10 * 1_024 * 1_024))
        self.searchTimeout = max(1, min(searchTimeout, 30))
        self.loadTimeout = max(1, min(loadTimeout, 30))
        self.streamTimeout = max(1, min(streamTimeout, 45))
        self.providerTimeout = max(1, min(providerTimeout, 15))
        self.idleContextLifetime = max(30, min(idleContextLifetime, 30 * 60))
        self.maximumContextsPerPackage = max(1, min(maximumContextsPerPackage, 4))
        self.maximumContextsGlobally = max(1, min(maximumContextsGlobally, 12))
    }

    public static let `default` = SkyStreamRuntimeLimits()
}

public enum SkyStreamRuntimeError: Error, Sendable, Equatable {
    case unavailable
    case invalidConfiguration
    case invalidScriptHash
    case scriptMissing
    case scriptTooLarge
    case scriptIntegrityMismatch
    case invalidScriptEncoding
    case scriptEvaluationFailed
    case missingExport(SkyStreamABIOperation)
    case incompatibleCaptchaRequirement
    case operationTimedOut(SkyStreamABIOperation)
    case runtimePreparationTimedOut
    case cancelled
    case pluginRejected(String)
    case malformedResult
    case resultTooLarge
    case runtimePoolExhausted
    case runtimeQuarantined
    case storageQuotaExceeded
    case unsupportedCrypto
}

extension SkyStreamRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "SkyStream plugins can run only on iPhone and iPad."
        case .invalidConfiguration:
            return "The SkyStream runtime configuration is invalid."
        case .invalidScriptHash:
            return "The installed SkyStream script hash is malformed."
        case .scriptMissing:
            return "The installed SkyStream script is missing."
        case .scriptTooLarge:
            return "The installed SkyStream script exceeds the runtime limit."
        case .scriptIntegrityMismatch:
            return "The installed SkyStream script failed its integrity check."
        case .invalidScriptEncoding:
            return "The installed SkyStream script is not valid UTF-8."
        case .scriptEvaluationFailed:
            return "The SkyStream script could not be evaluated."
        case .missingExport(let operation):
            return "The SkyStream plugin does not export \(operation.rawValue)."
        case .incompatibleCaptchaRequirement:
            return "This plugin requires generic interactive CAPTCHA solving, which Eclipse does not support."
        case .operationTimedOut(let operation):
            return "The SkyStream \(operation.rawValue) call timed out."
        case .runtimePreparationTimedOut:
            return "The SkyStream package did not finish loading in time."
        case .cancelled:
            return "The SkyStream operation was cancelled."
        case .pluginRejected(let message):
            return message.isEmpty ? "The SkyStream plugin rejected the operation." : message
        case .malformedResult:
            return "The SkyStream plugin returned malformed data."
        case .resultTooLarge:
            return "The SkyStream plugin returned too much data."
        case .runtimePoolExhausted:
            return "All SkyStream runtime contexts are currently busy."
        case .runtimeQuarantined:
            return "This SkyStream package was stopped after its JavaScript became unresponsive. Restart Eclipse before trying it again."
        case .storageQuotaExceeded:
            return "The SkyStream plugin exceeded its storage quota."
        case .unsupportedCrypto:
            return "The requested cryptographic operation is not supported."
        }
    }
}

public struct SkyStreamRuntimeStorageSnapshot: Sendable, Hashable {
    public var storage: [String: String]
    public var preferences: [String: SkyStreamJSONValue]

    public init(
        storage: [String: String] = [:],
        preferences: [String: SkyStreamJSONValue] = [:]
    ) {
        self.storage = storage
        self.preferences = preferences
    }
}

/// A bounded, package-scoped store. Every sub-provider of one package shares
/// this object, matching SkyStream's namespace semantics. Callers may snapshot
/// it after an operation and persist through their existing state transaction.
public final class SkyStreamRuntimeDataStore: @unchecked Sendable {
    /// Per-ABI working copy. Untrusted code never mutates the shared package store directly:
    /// successful invocations merge only the keys they changed, while failures/cancellation
    /// simply discard this object. The key-level compare-and-swap in `commit` lets sibling
    /// providers run concurrently without one overwriting a newer accepted write.
    fileprivate final class Transaction {
        private let owner: SkyStreamRuntimeDataStore
        fileprivate let baseline: SkyStreamRuntimeStorageSnapshot
        private let working: SkyStreamRuntimeDataStore
        fileprivate var changedStorageKeys: Set<String> = []
        fileprivate var changedPreferenceKeys: Set<String> = []

        fileprivate init(
            owner: SkyStreamRuntimeDataStore,
            baseline: SkyStreamRuntimeStorageSnapshot
        ) {
            self.owner = owner
            self.baseline = baseline
            self.working = SkyStreamRuntimeDataStore(snapshot: baseline)
        }

        fileprivate func storageValue(for key: String) -> String? {
            working.storageValue(for: key)
        }

        fileprivate func setStorageValue(_ value: String?, for key: String) throws {
            try working.setStorageValue(value, for: key)
            changedStorageKeys.insert(key)
        }

        fileprivate func preferenceValue(for key: String) -> SkyStreamJSONValue? {
            working.preferenceValue(for: key)
        }

        fileprivate func setPreferenceValue(
            _ value: SkyStreamJSONValue?,
            for key: String
        ) throws {
            try working.setPreferenceValue(value, for: key)
            changedPreferenceKeys.insert(key)
        }

        fileprivate func commit() throws {
            try owner.commit(self)
        }

        fileprivate func snapshot() -> SkyStreamRuntimeStorageSnapshot {
            working.snapshot()
        }
    }

    private let lock = NSLock()
    private var storage: [String: String]
    private var preferences: [String: SkyStreamJSONValue]
    private let maximumKeys = 256
    private let maximumStorageBytes = 1 * 1_024 * 1_024
    private let maximumPreferenceBytes = 512 * 1_024
    private let maximumValueBytes = 64 * 1_024

    public init(snapshot: SkyStreamRuntimeStorageSnapshot = .init()) {
        storage = snapshot.storage
        preferences = snapshot.preferences
        enforceInitialBounds()
    }

    public func snapshot() -> SkyStreamRuntimeStorageSnapshot {
        lock.lock()
        let value = SkyStreamRuntimeStorageSnapshot(storage: storage, preferences: preferences)
        lock.unlock()
        return value
    }

    fileprivate func beginTransaction() -> Transaction {
        lock.lock()
        let baseline = SkyStreamRuntimeStorageSnapshot(
            storage: storage,
            preferences: preferences
        )
        lock.unlock()
        return Transaction(owner: self, baseline: baseline)
    }

    private func commit(_ transaction: Transaction) throws {
        let desired = transaction.snapshot()
        lock.lock()
        defer { lock.unlock() }

        var candidateStorage = storage
        for key in transaction.changedStorageKeys.sorted()
            where storage[key] == transaction.baseline.storage[key] {
            if let value = desired.storage[key] {
                candidateStorage[key] = value
            } else {
                candidateStorage.removeValue(forKey: key)
            }
        }

        var candidatePreferences = preferences
        for key in transaction.changedPreferenceKeys.sorted()
            where preferences[key] == transaction.baseline.preferences[key] {
            if let value = desired.preferences[key] {
                candidatePreferences[key] = value
            } else {
                candidatePreferences.removeValue(forKey: key)
            }
        }

        let preferenceBytes = (try? JSONEncoder().encode(candidatePreferences).count) ?? Int.max
        guard candidateStorage.count <= maximumKeys,
              Self.byteCount(candidateStorage) <= maximumStorageBytes,
              candidatePreferences.count <= maximumKeys,
              preferenceBytes <= maximumPreferenceBytes else {
            throw SkyStreamRuntimeError.storageQuotaExceeded
        }
        storage = candidateStorage
        preferences = candidatePreferences
    }

    fileprivate func storageValue(for key: String) -> String? {
        guard Self.validKey(key) else { return nil }
        lock.lock()
        let value = storage[key]
        lock.unlock()
        return value
    }

    fileprivate func setStorageValue(_ value: String?, for key: String) throws {
        guard Self.validKey(key), value?.utf8.count ?? 0 <= maximumValueBytes else {
            throw SkyStreamRuntimeError.storageQuotaExceeded
        }
        lock.lock()
        defer { lock.unlock() }
        var candidate = storage
        if let value {
            candidate[key] = value
        } else {
            candidate.removeValue(forKey: key)
        }
        guard candidate.count <= maximumKeys,
              Self.byteCount(candidate) <= maximumStorageBytes else {
            throw SkyStreamRuntimeError.storageQuotaExceeded
        }
        storage = candidate
    }

    fileprivate func preferenceValue(for key: String) -> SkyStreamJSONValue? {
        guard Self.validKey(key) else { return nil }
        lock.lock()
        let value = preferences[key]
        lock.unlock()
        return value
    }

    fileprivate func setPreferenceValue(_ value: SkyStreamJSONValue?, for key: String) throws {
        guard Self.validKey(key) else { throw SkyStreamRuntimeError.storageQuotaExceeded }
        lock.lock()
        defer { lock.unlock() }
        var candidate = preferences
        if let value {
            try SkyStreamJSONValueShapePolicy.validate(value, limits: .runtimePreference)
            let encoded = try JSONEncoder().encode(value)
            guard encoded.count <= maximumValueBytes else {
                throw SkyStreamRuntimeError.storageQuotaExceeded
            }
            candidate[key] = value
        } else {
            candidate.removeValue(forKey: key)
        }
        let bytes = (try? JSONEncoder().encode(candidate).count) ?? Int.max
        guard candidate.count <= maximumKeys, bytes <= maximumPreferenceBytes else {
            throw SkyStreamRuntimeError.storageQuotaExceeded
        }
        preferences = candidate
    }

    private func enforceInitialBounds() {
        storage = Dictionary(
            uniqueKeysWithValues: storage
                .filter { Self.validKey($0.key) && $0.value.utf8.count <= maximumValueBytes }
                .sorted { $0.key < $1.key }
                .prefix(maximumKeys)
                .map { ($0.key, $0.value) }
        )
        while Self.byteCount(storage) > maximumStorageBytes, let key = storage.keys.sorted().last {
            storage.removeValue(forKey: key)
        }

        preferences = Dictionary(
            uniqueKeysWithValues: preferences
                .filter { key, value in
                    Self.validKey(key)
                        && (try? SkyStreamJSONValueShapePolicy.validate(
                            value,
                            limits: .runtimePreference
                        )) != nil
                        && ((try? JSONEncoder().encode(value).count) ?? Int.max)
                            <= maximumValueBytes
                }
                .sorted { $0.key < $1.key }
                .prefix(maximumKeys)
                .map { ($0.key, $0.value) }
        )
        while (try? JSONEncoder().encode(preferences).count) ?? Int.max > maximumPreferenceBytes,
              let key = preferences.keys.sorted().last {
            preferences.removeValue(forKey: key)
        }
    }

    private static func validKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == key
            && key.utf8.count <= 256
            && !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func byteCount(_ values: [String: String]) -> Int {
        values.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
    }
}

public struct SkyStreamRuntimeConfiguration: @unchecked Sendable {
    public var manifest: SkyStreamPluginManifest
    public var providerID: String?
    /// Whether `providerID` is exposed as `manifest.providerId`. Static/dynamic providers with
    /// their own baseUrl use the base URL path in the documented ABI and omit providerId.
    public var exposesProviderID: Bool
    public var baseURL: String
    public var scriptURL: URL
    public var expectedScriptSHA256: String
    public var settingsFingerprint: String
    /// Ephemeral manager-issued execution authority. It changes only at explicit package
    /// revocation boundaries (code/domain/trust/reset/provider-bootstrap publication), not when
    /// ordinary shared runtime storage evolves.
    public var authorityRevision: UUID
    public var dataStore: SkyStreamRuntimeDataStore
    public var limits: SkyStreamRuntimeLimits
    /// Validation runtimes keep the manifest identity visible to JavaScript while using a unique
    /// internal namespace for runtime pooling, HTTP sessions, cookies, and package limiters.
    fileprivate var validationNamespace: String?

    public init(
        manifest: SkyStreamPluginManifest,
        providerID: String? = nil,
        exposesProviderID: Bool = true,
        baseURL: String? = nil,
        scriptURL: URL,
        expectedScriptSHA256: String,
        settingsFingerprint: String = "",
        authorityRevision: UUID = UUID(),
        dataStore: SkyStreamRuntimeDataStore = .init(),
        limits: SkyStreamRuntimeLimits = .default
    ) {
        self.manifest = manifest
        self.providerID = providerID
        self.exposesProviderID = exposesProviderID
        self.baseURL = baseURL ?? Self.providerBaseURL(
            manifest: manifest,
            providerID: providerID
        )
        self.scriptURL = scriptURL
        self.expectedScriptSHA256 = expectedScriptSHA256
        self.settingsFingerprint = settingsFingerprint
        self.authorityRevision = authorityRevision
        self.dataStore = dataStore
        self.limits = limits
        self.validationNamespace = nil
    }

    fileprivate var sourceID: String {
        if let validationNamespace {
            return providerID.map { "\(validationNamespace):\($0)" } ?? validationNamespace
        }
        return SkyStreamStableID.sourceID(
            packageName: manifest.packageName,
            providerID: providerID
        )
    }

    fileprivate var runtimePackageNamespace: String {
        validationNamespace ?? manifest.packageName
    }

    var fingerprint: String {
        [
            expectedScriptSHA256.lowercased(), baseURL, String(manifest.version),
            providerID ?? "", exposesProviderID ? "exposed" : "hidden", settingsFingerprint,
            authorityRevision.uuidString.lowercased(),
            validationNamespace ?? "installed"
        ]
            .joined(separator: "|")
    }

    private static func providerBaseURL(
        manifest: SkyStreamPluginManifest,
        providerID: String?
    ) -> String {
        guard let providerID,
              let provider = manifest.providers?.first(where: { $0.id == providerID }),
              let providerURL = provider.baseURL,
              !providerURL.isEmpty else {
            return manifest.baseURL
        }
        return providerURL
    }
}

public struct SkyStreamRuntimeSmokeResult: Sendable, Hashable {
    public var exportedOperations: Set<SkyStreamABIOperation>

    public init(exportedOperations: Set<SkyStreamABIOperation>) {
        self.exportedOperations = exportedOperations
    }
}

public struct SkyStreamStagedValidationResult: Sendable, Hashable {
    public let smokeResult: SkyStreamRuntimeSmokeResult
    public let providers: [SkyStreamPluginProvider]?

    public init(
        smokeResult: SkyStreamRuntimeSmokeResult,
        providers: [SkyStreamPluginProvider]? = nil
    ) {
        self.smokeResult = smokeResult
        self.providers = providers
    }
}

// MARK: - Bounded concurrency and LRU context pool

private enum SkyStreamHardWatchdogError: Error {
    case expired
}

/// Tracks the physical lifetime of an operation independently from the caller-facing
/// continuation. Cancellation is allowed to return promptly, but its ABI permit stays reserved
/// until JavaScriptCore actually unwinds or the hard deadline classifies the runtime as poisoned.
private final class SkyStreamOperationLiveness: @unchecked Sendable {
    private let lock = NSLock()
    private var physicallyFinished = false
    private var classifiedUnresponsive = false

    /// Returns true exactly once when physical completion owns resource release.
    func finishPhysically() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !physicallyFinished else { return false }
        physicallyFinished = true
        return !classifiedUnresponsive
    }

    /// Returns true exactly once when the hard deadline owns quarantine and resource release.
    func classifyUnresponsive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !physicallyFinished, !classifiedUnresponsive else { return false }
        classifiedUnresponsive = true
        return true
    }
}

private struct SkyStreamLifecycleSnapshot: Sendable {
    let isActive: Bool
    let generation: UInt64
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// Notification generation detects an active -> background -> active cycle even when both
/// endpoint application-state reads happen to observe `active`.
private final class SkyStreamLifecycleGeneration: @unchecked Sendable {
    static let shared = SkyStreamLifecycleGeneration()

    private let lock = NSLock()
    private var value: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let names = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.didBecomeActiveNotification
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.advance()
            }
        }
    }

    func snapshot() -> UInt64 {
        lock.lock()
        let result = value
        lock.unlock()
        return result
    }

    private func advance() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
#endif

/// A checked continuation that can be completed safely by the runtime task, cancellation, or an
/// off-queue watchdog. Late JavaScript completion is ignored instead of double-resuming a caller.
private final class SkyStreamOneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isCompleted = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            continuation.resume(throwing: SkyStreamRuntimeError.cancelled)
            return
        }
        if let result = pendingResult {
            pendingResult = nil
            isCompleted = true
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !isCompleted, pendingResult == nil else {
            lock.unlock()
            return false
        }
        if let continuation {
            self.continuation = nil
            isCompleted = true
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
        return true
    }
}

private final class SkyStreamTaskCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancellationRequested = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if cancellationRequested {
            lock.unlock()
            task.cancel()
        } else {
            self.task = task
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    func clear() {
        lock.lock()
        task = nil
        lock.unlock()
    }
}

private enum SkyStreamRuntimeInvocationPhase: Sendable, Equatable {
    case preparing
    case operation
}

private final class SkyStreamWatchdogPhaseState: @unchecked Sendable {
    struct Snapshot {
        let phase: SkyStreamRuntimeInvocationPhase
        let generation: UInt64
    }

    private let lock = NSLock()
    private var phase: SkyStreamRuntimeInvocationPhase?
    private var generation: UInt64 = 0

    func transition(to phase: SkyStreamRuntimeInvocationPhase) {
        lock.lock()
        self.phase = phase
        generation &+= 1
        lock.unlock()
    }

    func snapshot() -> Snapshot? {
        lock.lock()
        let value = phase.map { Snapshot(phase: $0, generation: generation) }
        lock.unlock()
        return value
    }
}

private actor SkyStreamPermitLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var active = 0
    private var activeIDs: Set<UUID> = []
    private var waiters: [Waiter] = []
    private var cancelledBeforeRegistration: Set<UUID> = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelledBeforeRegistration.remove(id) != nil || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if active < limit {
                    active += 1
                    activeIDs.insert(id)
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ id: UUID) {
        guard activeIDs.remove(id) != nil else { return }
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if cancelledBeforeRegistration.remove(next.id) != nil {
                next.continuation.resume(throwing: CancellationError())
                continue
            }
            activeIDs.insert(next.id)
            next.continuation.resume()
            return
        }
        active = max(0, active - 1)
    }

    func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else if !activeIDs.contains(id) {
            cancelledBeforeRegistration.insert(id)
        }
    }

    func cancelAllWaiters() {
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        cancelledBeforeRegistration.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
}

public actor SkyStreamRuntimePool {
    public static let shared = SkyStreamRuntimePool()
    private static let maximumPoisonedRuntimes = 3

    private struct Entry {
        let packageName: String
        let fingerprint: String
        let runtime: SkyStreamProviderRuntime
        var lastUsedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var packageStores: [String: SkyStreamRuntimeDataStore] = [:]
    // Match the UI's bounded three-provider fanout. Holding only two permits across an entire
    // async HTTP-backed ABI call serialized one otherwise independent provider into a second
    // wave and made SkyStream visibly slower than Services/Stremio.
    private let abiLimiter = SkyStreamPermitLimiter(limit: 3)
    /// Admit at most one ABI call per logical source before it can reserve a scarce global
    /// JavaScript slot. Without this layer, three calls queued behind one wedged provider could
    /// consume every global permit and starve unrelated healthy sources.
    private var sourceABIAdmissionLimiters: [String: SkyStreamPermitLimiter] = [:]
    private var sourceABIAdmissionPackages: [String: String] = [:]
    private let globalHTTPLimiter = SkyStreamPermitLimiter(limit: 12)
    private var packageHTTPLimiters: [String: SkyStreamPermitLimiter] = [:]
    /// Installed invocations capture this token before entering the global ABI queue. Any package
    /// invalidation rotates it, so a caller that already owns a stale configuration cannot resume
    /// after a reset/update and recreate the old package store.
    private var packageExecutionEpochs: [String: UUID] = [:]
    private var pendingInstalledABIRequestIDs: [String: Set<UUID>] = [:]
    private var acceptedPackageAuthorityRevisions: [String: UUID] = [:]
    private var packagesBeingInvalidated: Set<String> = []
    private var quarantinedInstalledFingerprintsByPackage: [String: Set<String>] = [:]
    /// Uncommitted candidates are quarantined by immutable code/configuration identity. A bad
    /// update must never disable the currently installed healthy package sharing its package ID.
    private var quarantinedValidationFingerprints: Set<String> = []
    private var poisonedRuntimeReservationCount = 0
    private var runtimeCircuitIsOpen = false

    public init() {}

    public func search(
        using configuration: SkyStreamRuntimeConfiguration,
        query: String
    ) async throws -> [SkyStreamSearchRecord] {
        let boundedQuery = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_024))
        guard !boundedQuery.isEmpty else { return [] }
        let data = try await invoke(
            .search,
            arguments: [boundedQuery],
            using: configuration
        )
        return try SkyStreamRuntimeMapper.searchRecords(
            from: data,
            maximum: configuration.limits.maximumSearchResults
        )
    }

    public func load(
        using configuration: SkyStreamRuntimeConfiguration,
        url: String
    ) async throws -> SkyStreamLoadedItemRecord {
        guard url.utf8.count <= 16_384 else { throw SkyStreamRuntimeError.invalidConfiguration }
        let data = try await invoke(.load, arguments: [url], using: configuration)
        guard let value = try SkyStreamRuntimeMapper.loadedItem(
            from: data,
            fallbackURL: url,
            maximumEpisodes: configuration.limits.maximumEpisodes,
            maximumRecommendations: configuration.limits.maximumSearchResults
        ) else {
            throw SkyStreamRuntimeError.malformedResult
        }
        return value
    }

    public func loadStreams(
        using configuration: SkyStreamRuntimeConfiguration,
        url: String
    ) async throws -> [SkyStreamStreamRecord] {
        guard url.utf8.count <= 16_384 else { throw SkyStreamRuntimeError.invalidConfiguration }
        let data = try await invoke(.loadStreams, arguments: [url], using: configuration)
        return try SkyStreamRuntimeMapper.streamRecords(
            from: data,
            maximum: configuration.limits.maximumRawStreams
        )
    }

    public func getProviders(
        using configuration: SkyStreamRuntimeConfiguration
    ) async throws -> [SkyStreamPluginProvider] {
        let data = try await invoke(.getProviders, arguments: [], using: configuration)
        return try SkyStreamRuntimeMapper.providers(
            from: data,
            maximum: configuration.limits.maximumProviders
        )
    }

    /// Runs uncommitted package code in a one-shot runtime whose storage, cookies, HTTP limiter,
    /// and pool identity cannot alias the installed package. The validation namespace is reset on
    /// every exit. A hard watchdog can detach the caller from uninterruptible JavaScriptCore work;
    /// it cannot terminate the underlying JavaScriptCore thread.
    public func validateStagedPackage(
        package: SkyStreamInstalledPluginState,
        scriptURL: URL,
        discoverDynamicProviders: Bool,
        isolatedState: SkyStreamRuntimeStorageSnapshot? = nil,
        allowsRecoverableProviderDiscoveryFailure: Bool = false,
        limits: SkyStreamRuntimeLimits = .default
    ) async throws -> SkyStreamStagedValidationResult {
        try Self.requireRuntimeAvailability()
        let validationFingerprint = Self.validationFingerprint(
            packageName: package.id,
            version: package.manifest.version,
            archiveSHA256: package.archiveSHA256,
            scriptSHA256: package.scriptSHA256,
            baseURL: package.selectedDomainURL ?? package.manifest.baseURL
        )
        try requireValidationExecutionAllowed(fingerprint: validationFingerprint)
        let safePreferences = package.preferences.reduce(into: [String: SkyStreamJSONValue]()) {
            guard !$1.value.isSecret, !$1.value.isRedacted else { return }
            $0[$1.key] = $1.value.value
        }
        let boundedIsolatedState = SkyStreamRuntimeDataStore(
            snapshot: isolatedState ?? .init(storage: [:], preferences: safePreferences)
        ).snapshot()
        let preparePermitID = UUID()
        do {
            try await abiLimiter.acquire(preparePermitID)
        } catch {
            throw SkyStreamRuntimeError.cancelled
        }
        var prepareOperationStarted = false
        defer {
            if !prepareOperationStarted {
                Task { await abiLimiter.release(preparePermitID) }
            }
        }

        // A caller may have queued before another poisoned runtime opened the circuit. Re-check
        // after capacity is actually reserved and only then construct the JavaScript runtime.
        try requireValidationExecutionAllowed(fingerprint: validationFingerprint)
        let namespace = "validation.\(UUID().uuidString.lowercased())"
        var configuration = SkyStreamRuntimeConfiguration(
            manifest: package.manifest,
            providerID: nil,
            baseURL: package.selectedDomainURL,
            scriptURL: scriptURL,
            expectedScriptSHA256: package.scriptSHA256,
            dataStore: SkyStreamRuntimeDataStore(snapshot: boundedIsolatedState),
            limits: limits
        )
        configuration.validationNamespace = namespace
        let runtime = SkyStreamProviderRuntime(
            configuration: configuration,
            globalHTTPLimiter: globalHTTPLimiter,
            packageHTTPLimiter: SkyStreamPermitLimiter(limit: 6)
        )
        defer {
            runtime.invalidate(reason: .cancelled)
            SkyStreamHTTPClient.shared.reset(packageID: namespace)
        }

        let exported: Set<SkyStreamABIOperation>
        prepareOperationStarted = true
        do {
            exported = try await withHardWatchdog(
                seconds: limits.providerTimeout + 2,
                onOperationSettled: { [abiLimiter] in
                    Task { await abiLimiter.release(preparePermitID) }
                },
                onUnresponsive: { [weak self] in
                    await self?.quarantinePoisonedValidationRuntime(
                        runtime,
                        fingerprint: validationFingerprint
                    )
                }
            ) {
                try await runtime.prepare()
            }
        } catch is SkyStreamHardWatchdogError {
            throw SkyStreamRuntimeError.runtimePreparationTimedOut
        }
        for required in [SkyStreamABIOperation.search, .load, .loadStreams]
            where !exported.contains(required) {
            throw SkyStreamRuntimeError.missingExport(required)
        }

        var providers: [SkyStreamPluginProvider]?
        if discoverDynamicProviders {
            guard exported.contains(.getProviders) else {
                throw SkyStreamRuntimeError.missingExport(.getProviders)
            }
            let providerPermitID = UUID()
            do {
                try await abiLimiter.acquire(providerPermitID)
            } catch {
                throw SkyStreamRuntimeError.cancelled
            }
            var providerOperationStarted = false
            defer {
                if !providerOperationStarted {
                    Task { await abiLimiter.release(providerPermitID) }
                }
            }
            try requireValidationExecutionAllowed(fingerprint: validationFingerprint)
            providerOperationStarted = true
            do {
                let data = try await withHardWatchdog(
                    seconds: limits.providerTimeout + 2,
                    onOperationSettled: { [abiLimiter] in
                        Task { await abiLimiter.release(providerPermitID) }
                    },
                    onUnresponsive: { [weak self] in
                        await self?.quarantinePoisonedValidationRuntime(
                            runtime,
                            fingerprint: validationFingerprint
                        )
                    }
                ) {
                    try await runtime.invoke(.getProviders, arguments: [])
                }
                providers = try SkyStreamRuntimeMapper.providers(
                    from: data,
                    maximum: limits.maximumProviders
                )
            } catch is SkyStreamHardWatchdogError {
                throw SkyStreamRuntimeError.operationTimedOut(.getProviders)
            } catch let error as SkyStreamRuntimeError
                where allowsRecoverableProviderDiscoveryFailure
                    && Self.isRecoverableProviderDiscoveryFailure(error) {
                providers = []
            }
        }
        return SkyStreamStagedValidationResult(
            smokeResult: SkyStreamRuntimeSmokeResult(exportedOperations: exported),
            providers: providers
        )
    }

    /// Isolated discovery for already-installed code. Callers explicitly supply the bounded
    /// non-secret preference view; runtime storage is always empty and cookies use a throwaway jar.
    public func getProvidersForValidation(
        using originalConfiguration: SkyStreamRuntimeConfiguration,
        safePreferences: [String: SkyStreamJSONValue]
    ) async throws -> [SkyStreamPluginProvider] {
        try Self.requireRuntimeAvailability()
        let packageName = originalConfiguration.manifest.packageName
        let validationFingerprint = Self.validationFingerprint(
            packageName: packageName,
            version: originalConfiguration.manifest.version,
            archiveSHA256: nil,
            scriptSHA256: originalConfiguration.expectedScriptSHA256,
            baseURL: originalConfiguration.baseURL
        )
        try requireValidationExecutionAllowed(fingerprint: validationFingerprint)
        let permitID = UUID()
        do {
            try await abiLimiter.acquire(permitID)
        } catch {
            throw SkyStreamRuntimeError.cancelled
        }
        var operationStarted = false
        defer {
            if !operationStarted {
                Task { await abiLimiter.release(permitID) }
            }
        }
        try requireValidationExecutionAllowed(fingerprint: validationFingerprint)
        let namespace = "validation.\(UUID().uuidString.lowercased())"
        var configuration = originalConfiguration
        configuration.validationNamespace = namespace
        configuration.dataStore = SkyStreamRuntimeDataStore(snapshot: .init(
            storage: [:],
            preferences: safePreferences
        ))
        let runtime = SkyStreamProviderRuntime(
            configuration: configuration,
            globalHTTPLimiter: globalHTTPLimiter,
            packageHTTPLimiter: SkyStreamPermitLimiter(limit: 6)
        )
        defer {
            runtime.invalidate(reason: .cancelled)
            SkyStreamHTTPClient.shared.reset(packageID: namespace)
        }
        let data: Data
        operationStarted = true
        do {
            let phaseState = SkyStreamWatchdogPhaseState()
            data = try await withHardWatchdog(
                seconds: configuration.limits.providerTimeout + 2,
                phaseState: phaseState,
                preparationSeconds: configuration.limits.providerTimeout + 2,
                onOperationSettled: { [abiLimiter] in
                    Task { await abiLimiter.release(permitID) }
                },
                onUnresponsive: { [weak self] in
                    await self?.quarantinePoisonedValidationRuntime(
                        runtime,
                        fingerprint: validationFingerprint
                    )
                }
            ) {
                try await runtime.invoke(
                    .getProviders,
                    arguments: [],
                    onPhaseChange: { phaseState.transition(to: $0) }
                )
            }
        } catch is SkyStreamHardWatchdogError {
            throw SkyStreamRuntimeError.operationTimedOut(.getProviders)
        }
        return try SkyStreamRuntimeMapper.providers(
            from: data,
            maximum: configuration.limits.maximumProviders
        )
    }

    /// Reconciles dynamic providers for code that is already durably accepted. The JavaScript
    /// context and data store remain one-shot clones, while HTTP intentionally uses the real
    /// package namespace so an authenticated cookie jar can participate without being copied into
    /// uncommitted candidate validation.
    public func getProvidersForCommittedRefresh(
        using configuration: SkyStreamRuntimeConfiguration
    ) async throws -> [SkyStreamPluginProvider] {
        try Self.requireRuntimeAvailability()
        let packageName = configuration.manifest.packageName
        let sourceID = configuration.sourceID
        let installedFingerprint = Self.installedRuntimeFingerprint(configuration)
        let executionEpoch = packageExecutionEpoch(for: packageName)
        try requireRuntimeExecutionAllowed(
            packageName: packageName,
            fingerprint: installedFingerprint,
            authorityRevision: configuration.authorityRevision,
            executionEpoch: executionEpoch
        )
        let sourceAdmission = sourceABIAdmissionLimiter(
            sourceID: sourceID,
            packageName: packageName
        )
        let sourceAdmissionID = UUID()
        do {
            try await sourceAdmission.acquire(sourceAdmissionID)
        } catch {
            throw SkyStreamRuntimeError.cancelled
        }

        let permitID = UUID()
        var globalPermitAcquired = false
        var operationStarted = false
        defer {
            if !operationStarted {
                let releaseGlobalPermit = globalPermitAcquired
                Task { [abiLimiter, sourceAdmission] in
                    if releaseGlobalPermit {
                        await abiLimiter.release(permitID)
                    }
                    await sourceAdmission.release(sourceAdmissionID)
                }
            }
        }
        try requireRuntimeExecutionAllowed(
            packageName: packageName,
            fingerprint: installedFingerprint,
            authorityRevision: configuration.authorityRevision,
            executionEpoch: executionEpoch
        )
        pendingInstalledABIRequestIDs[packageName, default: []].insert(permitID)
        do {
            try await abiLimiter.acquire(permitID)
        } catch {
            removePendingInstalledABIRequest(permitID, packageName: packageName)
            throw SkyStreamRuntimeError.cancelled
        }
        removePendingInstalledABIRequest(permitID, packageName: packageName)
        globalPermitAcquired = true
        try requireRuntimeExecutionAllowed(
            packageName: packageName,
            fingerprint: installedFingerprint,
            authorityRevision: configuration.authorityRevision,
            executionEpoch: executionEpoch
        )
        let packageLimiter: SkyStreamPermitLimiter
        if let existingLimiter = packageHTTPLimiters[packageName] {
            packageLimiter = existingLimiter
        } else {
            let created = SkyStreamPermitLimiter(limit: 6)
            packageHTTPLimiters[packageName] = created
            packageLimiter = created
        }
        let runtime = SkyStreamProviderRuntime(
            configuration: configuration,
            globalHTTPLimiter: globalHTTPLimiter,
            packageHTTPLimiter: packageLimiter
        )
        defer { runtime.invalidate(reason: .cancelled) }
        operationStarted = true
        let data: Data
        do {
            let phaseState = SkyStreamWatchdogPhaseState()
            data = try await withHardWatchdog(
                seconds: configuration.limits.providerTimeout + 2,
                phaseState: phaseState,
                preparationSeconds: configuration.limits.providerTimeout + 2,
                onOperationSettled: { [abiLimiter, sourceAdmission] in
                    Task {
                        await abiLimiter.release(permitID)
                        await sourceAdmission.release(sourceAdmissionID)
                    }
                },
                onUnresponsive: { [weak self] in
                    await self?.quarantinePoisonedInstalledRuntime(
                        runtime,
                        packageName: packageName,
                        fingerprint: installedFingerprint
                    )
                }
            ) {
                try await runtime.invoke(
                    .getProviders,
                    arguments: [],
                    onPhaseChange: { phaseState.transition(to: $0) }
                )
            }
        } catch is SkyStreamHardWatchdogError {
            throw SkyStreamRuntimeError.operationTimedOut(.getProviders)
        }
        return try SkyStreamRuntimeMapper.providers(
            from: data,
            maximum: configuration.limits.maximumProviders
        )
    }

    /// Evaluates a staged entry script after verifying its stored hash. No ABI
    /// function (including dynamic `getProviders`) is called, so install-time
    /// smoke evaluation cannot unexpectedly perform plugin network traffic.
    @discardableResult
    public func smokeTest(
        package: SkyStreamInstalledPluginState,
        scriptURL: URL,
        limits: SkyStreamRuntimeLimits = .default
    ) async throws -> SkyStreamRuntimeSmokeResult {
        try await validateStagedPackage(
            package: package,
            scriptURL: scriptURL,
            discoverDynamicProviders: false,
            limits: limits
        ).smokeResult
    }

    public func storageSnapshot(packageName: String) -> SkyStreamRuntimeStorageSnapshot? {
        packageStores[packageName]?.snapshot()
    }

    public func cancel(packageName: String, providerID: String? = nil) {
        let sourceID = SkyStreamStableID.sourceID(packageName: packageName, providerID: providerID)
        entries[sourceID]?.runtime.invalidate(reason: .cancelled)
        entries.removeValue(forKey: sourceID)
        revokeSourceAdmission(sourceID: sourceID)
    }

    public func invalidatePackage(
        _ packageName: String,
        acceptingRevision: UUID? = nil,
        resetCookies: Bool = false,
        resetDataStore: Bool = false
    ) {
        packagesBeingInvalidated.insert(packageName)
        defer { packagesBeingInvalidated.remove(packageName) }
        // Rotate first. Even an acquired permit whose continuation has already been resumed must
        // fail its post-acquisition epoch check before canonicalizing stale state.
        packageExecutionEpochs[packageName] = UUID()
        revokeSourceAdmissions(packageName: packageName)
        let pendingRequestIDs = pendingInstalledABIRequestIDs.removeValue(
            forKey: packageName
        ) ?? []
        for requestID in pendingRequestIDs {
            Task { await abiLimiter.cancel(requestID) }
        }
        let keys = entries.compactMap { key, value in
            value.packageName == packageName ? key : nil
        }
        for key in keys {
            entries.removeValue(forKey: key)?.runtime.invalidate(reason: .cancelled)
        }
        packageHTTPLimiters.removeValue(forKey: packageName)
        if resetCookies || resetDataStore {
            packageStores.removeValue(forKey: packageName)
        }
        if resetCookies {
            SkyStreamHTTPClient.shared.reset(packageID: packageName)
        }
        if let acceptingRevision {
            acceptedPackageAuthorityRevisions[packageName] = acceptingRevision
        }
    }

    /// A deliberate user reset may retry the exact installed code after clearing its package
    /// state. This does not restore capacity reserved by a physically hung JavaScriptCore call,
    /// and it never reopens the process-wide poison circuit.
    public func clearInstalledQuarantineForUserReset(packageName: String) {
        quarantinedInstalledFingerprintsByPackage.removeValue(forKey: packageName)
    }

    public func evictIdleContexts() {
        evictIdleContexts(now: Date(), lifetime: SkyStreamRuntimeLimits.default.idleContextLifetime)
    }

    private func invoke(
        _ operation: SkyStreamABIOperation,
        arguments: [String],
        using originalConfiguration: SkyStreamRuntimeConfiguration
    ) async throws -> Data {
        try Self.requireRuntimeAvailability()
        let packageName = originalConfiguration.manifest.packageName
        let sourceID = originalConfiguration.sourceID
        let installedFingerprint = Self.installedRuntimeFingerprint(originalConfiguration)
        let executionEpoch = packageExecutionEpoch(for: packageName)
        try requireRuntimeExecutionAllowed(
            packageName: packageName,
            fingerprint: installedFingerprint,
            authorityRevision: originalConfiguration.authorityRevision,
            executionEpoch: executionEpoch
        )
        let sourceAdmission = sourceABIAdmissionLimiter(
            sourceID: sourceID,
            packageName: packageName
        )
        let sourceAdmissionID = UUID()
        do {
            try await sourceAdmission.acquire(sourceAdmissionID)
        } catch {
            throw SkyStreamRuntimeError.cancelled
        }

        let permitID = UUID()
        var globalPermitAcquired = false
        var operationStarted = false
        defer {
            if !operationStarted {
                let releaseGlobalPermit = globalPermitAcquired
                Task { [abiLimiter, sourceAdmission] in
                    if releaseGlobalPermit {
                        await abiLimiter.release(permitID)
                    }
                    await sourceAdmission.release(sourceAdmissionID)
                }
            }
        }
        try requireRuntimeExecutionAllowed(
            packageName: packageName,
            fingerprint: installedFingerprint,
            authorityRevision: originalConfiguration.authorityRevision,
            executionEpoch: executionEpoch
        )
        pendingInstalledABIRequestIDs[packageName, default: []].insert(permitID)
        do {
            try await abiLimiter.acquire(permitID)
        } catch {
            removePendingInstalledABIRequest(permitID, packageName: packageName)
            throw SkyStreamRuntimeError.cancelled
        }
        removePendingInstalledABIRequest(permitID, packageName: packageName)
        globalPermitAcquired = true
        // A queued caller must observe a circuit/quarantine opened while it waited. Creating or
        // selecting the pooled runtime only after this check also avoids adding more contexts when
        // the reserved capacity has already been revoked.
        try requireRuntimeExecutionAllowed(
            packageName: packageName,
            fingerprint: installedFingerprint,
            authorityRevision: originalConfiguration.authorityRevision,
            executionEpoch: executionEpoch
        )
        let configuration = canonicalConfiguration(originalConfiguration)
        let runtime = try runtime(for: configuration)
        operationStarted = true
        do {
            let result: Data
            do {
                let phaseState = SkyStreamWatchdogPhaseState()
                result = try await withHardWatchdog(
                    seconds: operationTimeout(operation, limits: configuration.limits) + 2,
                    phaseState: phaseState,
                    preparationSeconds: configuration.limits.providerTimeout + 2,
                    onOperationSettled: { [abiLimiter, sourceAdmission] in
                        Task {
                            await abiLimiter.release(permitID)
                            await sourceAdmission.release(sourceAdmissionID)
                        }
                    },
                    onUnresponsive: { [weak self] in
                        await self?.quarantinePoisonedInstalledRuntime(
                            runtime,
                            packageName: packageName,
                            fingerprint: installedFingerprint
                        )
                    }
                ) {
                    try await runtime.invoke(
                        operation,
                        arguments: arguments,
                        onPhaseChange: { phaseState.transition(to: $0) }
                    )
                }
            } catch is SkyStreamHardWatchdogError {
                throw SkyStreamRuntimeError.operationTimedOut(operation)
            }
            if var entry = entries[configuration.sourceID], entry.runtime === runtime {
                entry.lastUsedAt = Date()
                entries[configuration.sourceID] = entry
            }
            return result
        } catch is CancellationError {
            throw SkyStreamRuntimeError.cancelled
        }
    }

    private func withHardWatchdog<Value: Sendable>(
        seconds: TimeInterval,
        phaseState: SkyStreamWatchdogPhaseState? = nil,
        preparationSeconds: TimeInterval? = nil,
        onOperationSettled: @escaping @Sendable () -> Void,
        onUnresponsive: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let completion = SkyStreamOneShot<Value>()
        let liveness = SkyStreamOperationLiveness()
        let operationBox = SkyStreamTaskCancellationBox()
        let watchdogBox = SkyStreamTaskCancellationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let operationTask = Task.detached(priority: .userInitiated) {
                    defer {
                        operationBox.clear()
                        if liveness.finishPhysically() {
                            watchdogBox.cancel()
                            onOperationSettled()
                        }
                    }
                    do {
                        try Task.checkCancellation()
                        completion.resolve(.success(try await operation()))
                    } catch {
                        completion.resolve(.failure(error))
                    }
                }
                operationBox.install(operationTask)
                let nanoseconds = UInt64(
                    max(1, min(seconds, 180)) * 1_000_000_000
                )
                let watchdogTask = Task.detached(priority: .userInitiated) {
                    defer { watchdogBox.clear() }
                    do {
                        if let phaseState {
                            try await Self.waitForPhaseAwareHardDeadline(
                                phaseState: phaseState,
                                preparationSeconds: preparationSeconds ?? seconds,
                                operationSeconds: seconds
                            )
                        } else {
                            var lifecycle = try await Self.waitForActiveLifecycle()
                            while true {
                                try await Task.sleep(nanoseconds: nanoseconds)
                                let current = await Self.applicationLifecycleSnapshot()
                                if current.isActive,
                                   current.generation == lifecycle.generation {
                                    break
                                }
                                // Background/suspension wall time is not JavaScript execution
                                // time. Grant a fresh complete deadline after foreground resumes.
                                lifecycle = try await Self.waitForActiveLifecycle()
                            }
                        }
                    } catch {
                        return
                    }
                    guard liveness.classifyUnresponsive() else { return }
                    // Quarantine/count precedes capacity release. A waiter awakened by that
                    // classification must therefore observe the circuit before it can run.
                    await onUnresponsive()
                    // A classified synchronous JavaScript execution may never unwind. Keep its
                    // ABI reservation consumed for the process lifetime so live + poisoned work
                    // can never exceed the three-slot execution budget.
                    _ = completion.resolve(.failure(SkyStreamHardWatchdogError.expired))
                    operationBox.cancel()
                }
                watchdogBox.install(watchdogTask)
            }
        } onCancel: {
            // Cancellation controls only the caller-facing continuation. The independent
            // liveness watchdog and ABI reservation survive until physical completion/deadline.
            if completion.resolve(.failure(SkyStreamRuntimeError.cancelled)) {
                operationBox.cancel()
            }
        }
    }

    /// Queue wait is protected by the predecessor's own watchdog and must not count against this
    /// call. Once the invocation reaches its provider queue, first-context preparation and the ABI
    /// operation receive independent foreground-only budgets.
    private static func waitForPhaseAwareHardDeadline(
        phaseState: SkyStreamWatchdogPhaseState,
        preparationSeconds: TimeInterval,
        operationSeconds: TimeInterval
    ) async throws {
        var lifecycle = try await waitForActiveLifecycle()
        var observedGeneration: UInt64?
        var phaseStartedAt = DispatchTime.now().uptimeNanoseconds
        while true {
            try await Task.sleep(nanoseconds: 50_000_000)
            let currentLifecycle = await applicationLifecycleSnapshot()
            if !currentLifecycle.isActive
                || currentLifecycle.generation != lifecycle.generation {
                lifecycle = try await waitForActiveLifecycle()
                phaseStartedAt = DispatchTime.now().uptimeNanoseconds
                continue
            }
            guard let phase = phaseState.snapshot() else {
                continue
            }
            if observedGeneration != phase.generation {
                observedGeneration = phase.generation
                phaseStartedAt = DispatchTime.now().uptimeNanoseconds
                continue
            }
            let budget = phase.phase == .preparing
                ? preparationSeconds
                : operationSeconds
            let elapsed = DispatchTime.now().uptimeNanoseconds &- phaseStartedAt
            if Double(elapsed) / 1_000_000_000 >= max(1, min(budget, 180)) {
                return
            }
        }
    }

    private static func applicationLifecycleSnapshot() async -> SkyStreamLifecycleSnapshot {
#if os(iOS) && !targetEnvironment(macCatalyst)
        let isActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        return SkyStreamLifecycleSnapshot(
            isActive: isActive,
            generation: SkyStreamLifecycleGeneration.shared.snapshot()
        )
#else
        return SkyStreamLifecycleSnapshot(isActive: true, generation: 0)
#endif
    }

    private static func waitForActiveLifecycle() async throws -> SkyStreamLifecycleSnapshot {
        while true {
            try Task.checkCancellation()
            let snapshot = await applicationLifecycleSnapshot()
            if snapshot.isActive { return snapshot }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func operationTimeout(
        _ operation: SkyStreamABIOperation,
        limits: SkyStreamRuntimeLimits
    ) -> TimeInterval {
        switch operation {
        case .search: return limits.searchTimeout
        case .load: return limits.loadTimeout
        case .loadStreams: return limits.streamTimeout
        case .getProviders: return limits.providerTimeout
        }
    }

    private func requireRuntimeExecutionAllowed(
        packageName: String,
        fingerprint: String,
        authorityRevision: UUID,
        executionEpoch: UUID
    ) throws {
        guard !runtimeCircuitIsOpen,
              !packagesBeingInvalidated.contains(packageName),
              acceptedAuthorityRevision(
                for: packageName,
                proposed: authorityRevision
              ),
              packageExecutionEpoch(for: packageName) == executionEpoch,
              quarantinedInstalledFingerprintsByPackage[packageName]?.contains(fingerprint) != true else {
            throw SkyStreamRuntimeError.runtimeQuarantined
        }
    }

    private func acceptedAuthorityRevision(
        for packageName: String,
        proposed: UUID
    ) -> Bool {
        if let accepted = acceptedPackageAuthorityRevisions[packageName] {
            return accepted == proposed
        }
        // Direct RuntimePool tests and the first authoritative launch call can establish the
        // initial lease. Every later manager revocation pins a replacement before publication.
        acceptedPackageAuthorityRevisions[packageName] = proposed
        return true
    }

    private func packageExecutionEpoch(for packageName: String) -> UUID {
        if let existing = packageExecutionEpochs[packageName] { return existing }
        let created = UUID()
        packageExecutionEpochs[packageName] = created
        return created
    }

    private func sourceABIAdmissionLimiter(
        sourceID: String,
        packageName: String
    ) -> SkyStreamPermitLimiter {
        if let existing = sourceABIAdmissionLimiters[sourceID] {
            return existing
        }
        let created = SkyStreamPermitLimiter(limit: 1)
        sourceABIAdmissionLimiters[sourceID] = created
        sourceABIAdmissionPackages[sourceID] = packageName
        return created
    }

    private func revokeSourceAdmission(sourceID: String) {
        sourceABIAdmissionPackages.removeValue(forKey: sourceID)
        guard let limiter = sourceABIAdmissionLimiters.removeValue(forKey: sourceID) else {
            return
        }
        Task { await limiter.cancelAllWaiters() }
    }

    private func revokeSourceAdmissions(packageName: String) {
        let sourceIDs = sourceABIAdmissionPackages.compactMap { sourceID, owner in
            owner == packageName ? sourceID : nil
        }
        for sourceID in sourceIDs {
            revokeSourceAdmission(sourceID: sourceID)
        }
    }

    private func revokeAllSourceAdmissions() {
        let limiters = Array(sourceABIAdmissionLimiters.values)
        sourceABIAdmissionLimiters.removeAll(keepingCapacity: false)
        sourceABIAdmissionPackages.removeAll(keepingCapacity: false)
        for limiter in limiters {
            Task { await limiter.cancelAllWaiters() }
        }
    }

    private func removePendingInstalledABIRequest(
        _ requestID: UUID,
        packageName: String
    ) {
        pendingInstalledABIRequestIDs[packageName]?.remove(requestID)
        if pendingInstalledABIRequestIDs[packageName]?.isEmpty == true {
            pendingInstalledABIRequestIDs.removeValue(forKey: packageName)
        }
    }

    private func requireValidationExecutionAllowed(fingerprint: String) throws {
        guard !runtimeCircuitIsOpen,
              !quarantinedValidationFingerprints.contains(fingerprint) else {
            throw SkyStreamRuntimeError.runtimeQuarantined
        }
    }

    private func quarantinePoisonedValidationRuntime(
        _ runtime: SkyStreamProviderRuntime,
        fingerprint: String
    ) {
        quarantinedValidationFingerprints.insert(fingerprint)
        recordPoisonedRuntime()
        // Validation uses a throwaway HTTP/store namespace and never owns live package entries.
        // Its caller/defer resets that namespace; do not evict the installed healthy package.
        runtime.invalidate(reason: .runtimeQuarantined)
    }

    private func quarantinePoisonedInstalledRuntime(
        _ runtime: SkyStreamProviderRuntime,
        packageName: String,
        fingerprint: String
    ) {
        quarantinedInstalledFingerprintsByPackage[packageName, default: []].insert(fingerprint)
        recordPoisonedRuntime()

        let packageEntries = entries.compactMap { key, entry in
            entry.packageName == packageName ? (key, entry.runtime) : nil
        }
        for (key, candidate) in packageEntries {
            entries.removeValue(forKey: key)
            if candidate !== runtime {
                candidate.invalidate(reason: .runtimeQuarantined)
            }
        }
        revokeSourceAdmissions(packageName: packageName)
        packageHTTPLimiters.removeValue(forKey: packageName)
        packageStores.removeValue(forKey: packageName)
        SkyStreamHTTPClient.shared.reset(packageID: packageName)
    }

    private func recordPoisonedRuntime() {
        poisonedRuntimeReservationCount += 1
        if poisonedRuntimeReservationCount >= Self.maximumPoisonedRuntimes,
           !runtimeCircuitIsOpen {
            runtimeCircuitIsOpen = true
            revokeAllSourceAdmissions()
            Task { await abiLimiter.cancelAllWaiters() }
        }
    }

    private static func validationFingerprint(
        packageName: String,
        version: Int,
        archiveSHA256: String?,
        scriptSHA256: String,
        baseURL: String
    ) -> String {
        let value = [
            packageName.lowercased(),
            String(version),
            archiveSHA256?.lowercased() ?? "no-archive",
            scriptSHA256.lowercased(),
            baseURL
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func installedRuntimeFingerprint(
        _ configuration: SkyStreamRuntimeConfiguration
    ) -> String {
        let value = "\(configuration.sourceID)|\(configuration.fingerprint)"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isRecoverableProviderDiscoveryFailure(
        _ error: SkyStreamRuntimeError
    ) -> Bool {
        switch error {
        case .pluginRejected, .incompatibleCaptchaRequirement, .operationTimedOut:
            return true
        default:
            return false
        }
    }

    private func canonicalConfiguration(
        _ configuration: SkyStreamRuntimeConfiguration
    ) -> SkyStreamRuntimeConfiguration {
        var value = configuration
        if let existing = packageStores[configuration.runtimePackageNamespace] {
            value.dataStore = existing
        } else {
            packageStores[configuration.runtimePackageNamespace] = configuration.dataStore
        }
        return value
    }

    private func runtime(
        for configuration: SkyStreamRuntimeConfiguration
    ) throws -> SkyStreamProviderRuntime {
        let now = Date()
        evictIdleContexts(now: now, lifetime: configuration.limits.idleContextLifetime)

        if let existing = entries[configuration.sourceID] {
            if existing.fingerprint == configuration.fingerprint {
                var refreshed = existing
                refreshed.lastUsedAt = now
                entries[configuration.sourceID] = refreshed
                return existing.runtime
            }
            existing.runtime.invalidate(reason: .cancelled)
            entries.removeValue(forKey: configuration.sourceID)
        }

        try makeCapacity(for: configuration)
        let created = makeRuntime(configuration: configuration)
        entries[configuration.sourceID] = Entry(
            packageName: configuration.manifest.packageName,
            fingerprint: configuration.fingerprint,
            runtime: created,
            lastUsedAt: now
        )
        return created
    }

    private func makeRuntime(
        configuration: SkyStreamRuntimeConfiguration
    ) -> SkyStreamProviderRuntime {
        let packageName = configuration.runtimePackageNamespace
        let packageLimiter: SkyStreamPermitLimiter
        if let existing = packageHTTPLimiters[packageName] {
            packageLimiter = existing
        } else {
            let created = SkyStreamPermitLimiter(limit: 6)
            packageHTTPLimiters[packageName] = created
            packageLimiter = created
        }
        return SkyStreamProviderRuntime(
            configuration: configuration,
            globalHTTPLimiter: globalHTTPLimiter,
            packageHTTPLimiter: packageLimiter
        )
    }

    private func makeCapacity(for configuration: SkyStreamRuntimeConfiguration) throws {
        let packageName = configuration.runtimePackageNamespace
        while entries.values.filter({ $0.packageName == packageName }).count
            >= configuration.limits.maximumContextsPerPackage {
            guard let candidate = entries
                .filter({ $0.value.packageName == packageName && !$0.value.runtime.isBusy })
                .min(by: { $0.value.lastUsedAt < $1.value.lastUsedAt }) else {
                throw SkyStreamRuntimeError.runtimePoolExhausted
            }
            entries.removeValue(forKey: candidate.key)?.runtime.invalidate(reason: .cancelled)
        }

        while entries.count >= configuration.limits.maximumContextsGlobally {
            guard let candidate = entries
                .filter({ !$0.value.runtime.isBusy })
                .min(by: { $0.value.lastUsedAt < $1.value.lastUsedAt }) else {
                throw SkyStreamRuntimeError.runtimePoolExhausted
            }
            entries.removeValue(forKey: candidate.key)?.runtime.invalidate(reason: .cancelled)
        }
    }

    private func evictIdleContexts(now: Date, lifetime: TimeInterval) {
        let expired = entries.compactMap { key, entry -> String? in
            guard !entry.runtime.isBusy,
                  now.timeIntervalSince(entry.lastUsedAt) >= lifetime else { return nil }
            return key
        }
        for key in expired {
            entries.removeValue(forKey: key)?.runtime.invalidate(reason: .cancelled)
        }
    }

    private static func requireRuntimeAvailability() throws {
#if os(iOS) && !targetEnvironment(macCatalyst)
        return
#else
        throw SkyStreamRuntimeError.unavailable
#endif
    }
}

// MARK: - Serialized provider runtime

private final class SkyStreamProviderRuntime: @unchecked Sendable {
    private static let maximumOutstandingChildTasks = 24
    private static let maximumOutstandingTimers = 256

    private struct Invocation {
        let id: UUID
        let operation: SkyStreamABIOperation
        let arguments: [String]
        let onPhaseChange: @Sendable (SkyStreamRuntimeInvocationPhase) -> Void
        let continuation: CheckedContinuation<Data, Error>
    }

    private final class OperationResources {
        var childTasks: [UUID: Task<Void, Never>] = [:]
        var timers: [Int: DispatchWorkItem] = [:]
        var timeoutWorkItem: DispatchWorkItem?

        func cancelAll() {
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            childTasks.values.forEach { $0.cancel() }
            childTasks.removeAll()
            timers.values.forEach { $0.cancel() }
            timers.removeAll()
        }
    }

    private struct ActiveInvocation {
        let invocation: Invocation
        let generation: UInt64
        let resources: OperationResources
        let transaction: SkyStreamRuntimeDataStore.Transaction
    }

    private struct BufferedJavaScriptCompletion {
        let id: UUID
        let result: Result<Data, SkyStreamRuntimeError>
        let invalidateContext: Bool
    }

    private let configuration: SkyStreamRuntimeConfiguration
    private let globalHTTPLimiter: SkyStreamPermitLimiter
    private let packageHTTPLimiter: SkyStreamPermitLimiter
    private let queue: DispatchQueue
    private let watchdogQueue = DispatchQueue(
        label: "app.eclipse.skystream.runtime.watchdog",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let busyLock = NSLock()
    private var busyValue = false
    /// Cancellation handlers run off the provider queue so intent remains visible even while
    /// synchronous JavaScriptCore evaluation is blocking that queue.
    private let cancellationIntentLock = NSLock()
    private var trackedInvocationIDs: Set<UUID> = []
    private var cancellationIntentIDs: Set<UUID> = []

    private var context: JSContext?
    /// Owns only the documents parsed by `context`. Keeping this beside the
    /// JavaScript context makes cache lifetime and cancellation semantics
    /// explicit: replacing a context also invalidates every native DOM handle
    /// that untrusted code from that context could still know about.
    private var htmlBridge: SkyStreamHTMLBridge?
    private var generation: UInt64 = 0
    private var queued: [Invocation] = []
    private var active: ActiveInvocation?
    /// A native completion can be called re-entrantly while `JSValue.call` is still executing.
    /// Buffer it until the synchronous JavaScript frame actually unwinds so callback-then-spin
    /// code remains covered by the hard watchdog and keeps its global ABI reservation.
    private var synchronousInvokeID: UUID?
    private var bufferedJavaScriptCompletion: BufferedJavaScriptCompletion?
    private var nextTimerID = 1

    init(
        configuration: SkyStreamRuntimeConfiguration,
        globalHTTPLimiter: SkyStreamPermitLimiter,
        packageHTTPLimiter: SkyStreamPermitLimiter
    ) {
        self.configuration = configuration
        self.globalHTTPLimiter = globalHTTPLimiter
        self.packageHTTPLimiter = packageHTTPLimiter
        let safeLabel = configuration.sourceID
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        queue = DispatchQueue(
            label: "app.eclipse.skystream.runtime.\(String(safeLabel).prefix(96))",
            qos: .userInitiated
        )
    }

    var isBusy: Bool {
        busyLock.lock()
        let value = busyValue
        busyLock.unlock()
        return value
    }

    func prepare() async throws -> Set<SkyStreamABIOperation> {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SkyStreamRuntimeError.cancelled)
                    return
                }
                do {
                    let exports = try self.prepareContextIfNeeded()
                    continuation.resume(returning: exports)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func invoke(
        _ operation: SkyStreamABIOperation,
        arguments: [String],
        onPhaseChange: @escaping @Sendable (SkyStreamRuntimeInvocationPhase) -> Void = { _ in }
    ) async throws -> Data {
        let id = UUID()
        registerInvocation(id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: SkyStreamRuntimeError.cancelled)
                        return
                    }
                    if self.consumeCancellationIntent(id) || Task.isCancelled {
                        self.completeInvocationTracking(id)
                        continuation.resume(throwing: SkyStreamRuntimeError.cancelled)
                        return
                    }
                    self.queued.append(
                        Invocation(
                            id: id,
                            operation: operation,
                            arguments: arguments,
                            onPhaseChange: onPhaseChange,
                            continuation: continuation
                        )
                    )
                    self.updateBusyFlag()
                    self.startNextIfPossible()
                }
            }
        } onCancel: {
            self.markCancellationIntent(id)
            self.queue.async { [weak self] in
                self?.cancel(id: id, reason: .cancelled)
            }
        }
    }

    func invalidate(reason: SkyStreamRuntimeError) {
        queue.async { [weak self] in
            self?.invalidateOnQueue(reason: reason)
        }
    }

    private func startNextIfPossible() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active == nil, !queued.isEmpty else { return }
        let invocation = queued.removeFirst()
        do {
            invocation.onPhaseChange(.preparing)
            let exports = try prepareContextIfNeeded()
            guard exports.contains(invocation.operation) else {
                completeInvocationTracking(invocation.id)
                invocation.continuation.resume(
                    throwing: SkyStreamRuntimeError.missingExport(invocation.operation)
                )
                updateBusyFlag()
                startNextIfPossible()
                return
            }

            let resources = OperationResources()
            let operationGeneration = generation
            let transaction = configuration.dataStore.beginTransaction()
            active = ActiveInvocation(
                invocation: invocation,
                generation: operationGeneration,
                resources: resources,
                transaction: transaction
            )
            updateBusyFlag()
            armTimeout(for: invocation, generation: operationGeneration, resources: resources)
            invocation.onPhaseChange(.operation)

            guard let context,
                  let function = context.objectForKeyedSubscript("__eclipseSkyInvoke"),
                  !function.isUndefined else {
                finish(
                    id: invocation.id,
                    result: .failure(SkyStreamRuntimeError.scriptEvaluationFailed),
                    invalidateContext: true
                )
                return
            }

            let serializedLimit: Int
            switch invocation.operation {
            case .getProviders:
                serializedLimit = min(configuration.limits.maximumSerializedResultBytes, 1 * 1_024 * 1_024)
            case .search:
                serializedLimit = min(configuration.limits.maximumSerializedResultBytes, 6 * 1_024 * 1_024)
            case .load, .loadStreams:
                serializedLimit = configuration.limits.maximumSerializedResultBytes
            }

            synchronousInvokeID = invocation.id
            _ = function.call(withArguments: [
                invocation.operation.rawValue,
                invocation.arguments,
                invocation.id.uuidString,
                configuration.limits.maximumSearchResults,
                configuration.limits.maximumEpisodes,
                configuration.limits.maximumRawStreams,
                configuration.limits.maximumProviders,
                serializedLimit
            ])
            synchronousInvokeID = nil

            // Cancellation can be marked while synchronous JavaScriptCore work owns this queue.
            // Consume it immediately after the call even if JavaScript synchronously completed
            // first; the context may have observed partial cancelled-call mutations and is not
            // eligible for reuse.
            if consumeCancellationIntent(invocation.id) {
                bufferedJavaScriptCompletion = nil
                if active?.invocation.id == invocation.id {
                    finish(
                        id: invocation.id,
                        result: .failure(.cancelled),
                        invalidateContext: true
                    )
                } else {
                    replaceContext()
                    completeInvocationTracking(invocation.id)
                }
                return
            }

            if context.exception != nil {
                context.exception = nil
                bufferedJavaScriptCompletion = nil
                finish(
                    id: invocation.id,
                    result: .failure(SkyStreamRuntimeError.scriptEvaluationFailed),
                    invalidateContext: true
                )
                return
            }

            if let buffered = bufferedJavaScriptCompletion,
               buffered.id == invocation.id {
                bufferedJavaScriptCompletion = nil
                finish(
                    id: buffered.id,
                    result: buffered.result,
                    invalidateContext: buffered.invalidateContext
                )
            }
        } catch {
            synchronousInvokeID = nil
            bufferedJavaScriptCompletion = nil
            completeInvocationTracking(invocation.id)
            invocation.continuation.resume(throwing: error)
            updateBusyFlag()
            startNextIfPossible()
        }
    }

    private func prepareContextIfNeeded() throws -> Set<SkyStreamABIOperation> {
        dispatchPrecondition(condition: .onQueue(queue))
        if let context {
            return exportedOperations(in: context)
        }

        let script = try verifiedScript()
        let created = JSContext()!
        var capturedException = false
        created.exceptionHandler = { _, _ in
            capturedException = true
        }
        let createdHTMLBridge = SkyStreamHTMLBridge()
        installNativeBridges(in: created, htmlBridge: createdHTMLBridge)
        _ = created.evaluateScript(Self.runtimeBootstrap)
        guard !capturedException, created.exception == nil else {
            created.exception = nil
            created.exceptionHandler = nil
            throw SkyStreamRuntimeError.scriptEvaluationFailed
        }

        let manifestObject = try manifestJSONObject()
        created.setObject(manifestObject, forKeyedSubscript: "manifest" as NSString)

        // The documented ABI has no dynamic-code-loading primitive. Disable the
        // ambient constructors before package evaluation so a plugin cannot fetch
        // and execute a second, unhashed program after plugin.js was verified.
        _ = created.evaluateScript(Self.runtimeCodeLockdown)
        guard !capturedException, created.exception == nil else {
            created.exception = nil
            created.exceptionHandler = nil
            throw SkyStreamRuntimeError.scriptEvaluationFailed
        }

        // Integrity is checked immediately before this untrusted evaluation.
        // Native shims are constants compiled into Eclipse and are not part of
        // the installed-code integrity statement.
        _ = created.evaluateScript(script, withSourceURL: configuration.scriptURL)
        guard !capturedException, created.exception == nil else {
            created.exception = nil
            created.exceptionHandler = nil
            throw SkyStreamRuntimeError.scriptEvaluationFailed
        }

        _ = created.evaluateScript(Self.captureExportsScript)
        guard !capturedException, created.exception == nil else {
            created.exception = nil
            created.exceptionHandler = nil
            throw SkyStreamRuntimeError.scriptEvaluationFailed
        }
        context = created
        htmlBridge = createdHTMLBridge
        generation &+= 1
        return exportedOperations(in: created)
    }

    private func verifiedScript() throws -> String {
        guard configuration.scriptURL.isFileURL else {
            throw SkyStreamRuntimeError.invalidConfiguration
        }
        let hash = configuration.expectedScriptSHA256.lowercased()
        guard hash.count == 64,
              hash.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            throw SkyStreamRuntimeError.invalidScriptHash
        }
        let values = try? configuration.scriptURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw SkyStreamRuntimeError.scriptMissing
        }
        if let fileSize = values?.fileSize,
           fileSize > configuration.limits.maximumScriptBytes {
            throw SkyStreamRuntimeError.scriptTooLarge
        }
        let data = try Data(contentsOf: configuration.scriptURL, options: [.mappedIfSafe])
        guard data.count <= configuration.limits.maximumScriptBytes else {
            throw SkyStreamRuntimeError.scriptTooLarge
        }
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual == hash else { throw SkyStreamRuntimeError.scriptIntegrityMismatch }
        guard let value = String(data: data, encoding: .utf8) else {
            throw SkyStreamRuntimeError.invalidScriptEncoding
        }
        return value
    }

    private func manifestJSONObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(configuration.manifest)
        guard var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkyStreamRuntimeError.invalidConfiguration
        }
        value["baseUrl"] = configuration.baseURL
        if configuration.exposesProviderID, let providerID = configuration.providerID {
            value["providerId"] = providerID
        } else {
            value.removeValue(forKey: "providerId")
        }
        return value
    }

    private func exportedOperations(in context: JSContext) -> Set<SkyStreamABIOperation> {
        guard let value = context.objectForKeyedSubscript("__eclipseSkyExportNames"),
              let names = value.toArray() as? [String] else { return [] }
        return Set(names.compactMap(SkyStreamABIOperation.init(rawValue:)))
    }

    private func armTimeout(
        for invocation: Invocation,
        generation: UInt64,
        resources: OperationResources
    ) {
        let seconds: TimeInterval
        switch invocation.operation {
        case .search: seconds = configuration.limits.searchTimeout
        case .load: seconds = configuration.limits.loadTimeout
        case .loadStreams: seconds = configuration.limits.streamTimeout
        case .getProviders: seconds = configuration.limits.providerTimeout
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self,
                      self.active?.invocation.id == invocation.id,
                      self.active?.generation == generation else { return }
                self.finish(
                    id: invocation.id,
                    result: .failure(.operationTimedOut(invocation.operation)),
                    invalidateContext: true
                )
            }
        }
        resources.timeoutWorkItem = item
        watchdogQueue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func completeFromJavaScript(idString: String, json: String, error: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let id = UUID(uuidString: idString),
              let active,
              active.invocation.id == id,
              active.generation == generation else { return }

        let completion: BufferedJavaScriptCompletion
        if consumeCancellationIntent(id) {
            completion = BufferedJavaScriptCompletion(
                id: id,
                result: .failure(.cancelled),
                invalidateContext: true
            )
        } else if !error.isEmpty {
            let safeMessage = String(error.prefix(512))
            let mapped: SkyStreamRuntimeError
            if safeMessage == "CAPTCHA_UNSUPPORTED" {
                mapped = .incompatibleCaptchaRequirement
            } else if safeMessage == "Plugin result exceeded the Eclipse boundary." {
                mapped = .resultTooLarge
            } else {
                mapped = .pluginRejected(safeMessage)
            }
            completion = BufferedJavaScriptCompletion(
                id: id,
                result: .failure(mapped),
                invalidateContext: true
            )
        } else if let data = json.data(using: .utf8),
                  data.count <= configuration.limits.maximumSerializedResultBytes {
            completion = BufferedJavaScriptCompletion(
                id: id,
                result: .success(data),
                invalidateContext: false
            )
        } else {
            completion = BufferedJavaScriptCompletion(
                id: id,
                result: .failure(.resultTooLarge),
                invalidateContext: true
            )
        }

        if synchronousInvokeID == id {
            // The documented completion is one-shot. Ignore duplicate callback attempts, keeping
            // the first observable result exactly as a Promise continuation would.
            if bufferedJavaScriptCompletion == nil {
                bufferedJavaScriptCompletion = completion
            }
            return
        }
        finish(
            id: id,
            result: completion.result,
            invalidateContext: completion.invalidateContext
        )
    }

    private func finish(
        id: UUID,
        result: Result<Data, SkyStreamRuntimeError>,
        invalidateContext: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let current = active, current.invocation.id == id else { return }
        let cancellationWon = finalizeInvocationTracking(id)
        var effectiveResult: Result<Data, SkyStreamRuntimeError> = cancellationWon
            ? .failure(.cancelled)
            : result
        var mustInvalidateContext = invalidateContext || cancellationWon
        if case .success = effectiveResult {
            do {
                try current.transaction.commit()
            } catch {
                effectiveResult = .failure(.storageQuotaExceeded)
                mustInvalidateContext = true
            }
        }
        current.resources.cancelAll()
        active = nil
        if let context {
            context.objectForKeyedSubscript("__eclipseSkyDrop")?
                .call(withArguments: [id.uuidString])
        }
        if mustInvalidateContext {
            replaceContext()
        }
        switch effectiveResult {
        case .success(let data):
            current.invocation.continuation.resume(returning: data)
        case .failure(let error):
            current.invocation.continuation.resume(throwing: error)
        }
        updateBusyFlag()
        // Let a synchronous JavaScript call fully unwind before another invocation enters the
        // same JSContext. This also gives the post-call cancellation check a chance to replace a
        // dirtied context before queued work starts.
        queue.async { [weak self] in self?.startNextIfPossible() }
    }

    private func cancel(id: UUID, reason: SkyStreamRuntimeError) {
        dispatchPrecondition(condition: .onQueue(queue))
        if active?.invocation.id == id {
            _ = consumeCancellationIntent(id)
            finish(id: id, result: .failure(reason), invalidateContext: true)
            return
        }
        if let index = queued.firstIndex(where: { $0.id == id }) {
            let invocation = queued.remove(at: index)
            _ = consumeCancellationIntent(id)
            completeInvocationTracking(id)
            invocation.continuation.resume(throwing: reason)
            updateBusyFlag()
            queue.async { [weak self] in self?.startNextIfPossible() }
        }
    }

    private func invalidateOnQueue(reason: SkyStreamRuntimeError) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let active {
            active.resources.cancelAll()
            completeInvocationTracking(active.invocation.id)
            active.invocation.continuation.resume(throwing: reason)
            self.active = nil
        }
        for invocation in queued {
            completeInvocationTracking(invocation.id)
            invocation.continuation.resume(throwing: reason)
        }
        queued.removeAll()
        synchronousInvokeID = nil
        bufferedJavaScriptCompletion = nil
        replaceContext()
        updateBusyFlag()
    }

    private func replaceContext() {
        synchronousInvokeID = nil
        bufferedJavaScriptCompletion = nil
        htmlBridge?.invalidate()
        htmlBridge = nil
        context?.exception = nil
        context?.exceptionHandler = nil
        context = nil
        generation &+= 1
    }

    private func updateBusyFlag() {
        busyLock.lock()
        busyValue = active != nil || !queued.isEmpty
        busyLock.unlock()
    }

    private func registerInvocation(_ id: UUID) {
        cancellationIntentLock.lock()
        trackedInvocationIDs.insert(id)
        cancellationIntentLock.unlock()
    }

    private func markCancellationIntent(_ id: UUID) {
        cancellationIntentLock.lock()
        if trackedInvocationIDs.contains(id) {
            cancellationIntentIDs.insert(id)
        }
        cancellationIntentLock.unlock()
    }

    private func consumeCancellationIntent(_ id: UUID) -> Bool {
        cancellationIntentLock.lock()
        let wasCancelled = cancellationIntentIDs.remove(id) != nil
        cancellationIntentLock.unlock()
        return wasCancelled
    }

    private func completeInvocationTracking(_ id: UUID) {
        cancellationIntentLock.lock()
        trackedInvocationIDs.remove(id)
        cancellationIntentIDs.remove(id)
        cancellationIntentLock.unlock()
    }

    /// Atomically closes the interval in which an off-queue cancellation can win. A cancellation
    /// arriving after this returns observes an already-physically-complete invocation and cannot
    /// create a stale marker; one arriving before it forces context replacement.
    private func finalizeInvocationTracking(_ id: UUID) -> Bool {
        cancellationIntentLock.lock()
        let wasCancelled = cancellationIntentIDs.remove(id) != nil
        trackedInvocationIDs.remove(id)
        cancellationIntentLock.unlock()
        return wasCancelled
    }
}

/// Converts Foundation's response-header representation into the SkyStream JavaScript ABI.
/// In particular, `Set-Cookie` remains a list: joining it with commas corrupts the `Expires`
/// attribute and prevents plugins from selecting an individual cookie.
enum SkyStreamHTTPResponseHeaderProjection {
    private static let maximumHeaders = 64
    private static let maximumHeaderBytes = 8 * 1_024
    private static let maximumSetCookieValues = 64

    static func project(_ fields: [AnyHashable: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (rawKey, rawValue) in fields {
            guard result.count < maximumHeaders,
                  let key = rawKey as? String,
                  key.utf8.count <= 128 else { continue }
            let normalized = key.lowercased()
            if normalized == "set-cookie" {
                let values = setCookieValues(rawValue)
                if !values.isEmpty { result[normalized] = values }
                continue
            }

            let value: String
            if let strings = rawValue as? [String] {
                value = strings.joined(separator: ",")
            } else if let values = rawValue as? [Any] {
                value = values.map(String.init(describing:)).joined(separator: ",")
            } else {
                value = String(describing: rawValue)
            }
            if value.utf8.count <= maximumHeaderBytes { result[normalized] = value }
        }
        return result
    }

    private static func setCookieValues(_ rawValue: Any) -> [String] {
        let candidates: [String]
        if let strings = rawValue as? [String] {
            candidates = strings
        } else if let values = rawValue as? [Any] {
            candidates = values.map(String.init(describing:))
        } else {
            candidates = splitCombinedSetCookieHeader(String(describing: rawValue))
        }
        var result: [String] = []
        for candidate in candidates {
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= maximumHeaderBytes else { continue }
            result.append(value)
            if result.count == maximumSetCookieValues { break }
        }
        return result
    }

    /// `HTTPURLResponse` may combine repeated Set-Cookie fields into one string. A separator
    /// comma is recognizable because it is followed by a new cookie-name and `=`; the comma
    /// in an RFC 1123 Expires value is followed by a date and therefore remains intact.
    private static func splitCombinedSetCookieHeader(_ value: String) -> [String] {
        guard let separator = try? NSRegularExpression(
            pattern: #",(?=\s*[!#$%&'*+\-.^_`|~0-9A-Za-z]+\s*=)"#
        ) else { return [value] }
        let source = value as NSString
        let matches = separator.matches(
            in: value,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return [value] }

        var output: [String] = []
        var start = 0
        for match in matches.prefix(maximumSetCookieValues - 1) {
            output.append(source.substring(with: NSRange(
                location: start,
                length: match.range.location - start
            )))
            start = match.range.location + match.range.length
        }
        output.append(source.substring(from: start))
        return output
    }
}

/// URLSession owns these transport headers. Official SkyStream packages sometimes include
/// browser-oriented values for them; dropping only those names preserves Cookie/Referer and
/// avoids turning an otherwise valid request or playback result into a total failure.
enum SkyStreamRuntimeHeaderCompatibility {
    private static let controlledNames: Set<String> = [
        "accept-encoding", "connection", "content-length", "host", "keep-alive",
        "range", "te", "trailer", "transfer-encoding", "upgrade"
    ]

    static func droppingControlled(_ headers: [String: String]) -> [String: String] {
        headers.filter { key, _ in
            let normalized = key.lowercased()
            return !controlledNames.contains(normalized) && !normalized.hasPrefix("proxy-")
        }
    }

    static func isControlled(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return controlledNames.contains(normalized) || normalized.hasPrefix("proxy-")
    }
}

// MARK: Native bridges

private extension SkyStreamProviderRuntime {
    struct HTTPBridgeRequest {
        let method: String
        let url: String
        let headers: [String: String]
        let body: Data?
    }

    func installNativeBridges(in context: JSContext, htmlBridge: SkyStreamHTMLBridge) {
        let completion: @convention(block) (String, String, String) -> Void = { [weak self] id, json, error in
            self?.completeFromJavaScript(idString: id, json: json, error: error)
        }
        context.setObject(
            completion,
            forKeyedSubscript: "__eclipseSkyNativeComplete" as NSString
        )

        let http: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] request, resolve, reject in
            self?.beginHTTPRequest(request, resolve: resolve, reject: reject)
        }
        context.setObject(http, forKeyedSubscript: "__eclipseSkyNativeHTTP" as NSString)

        let storage: @convention(block) (String) -> String = { [weak self] request in
            self?.handleStorageRequest(request) ?? "{\"ok\":false}"
        }
        context.setObject(storage, forKeyedSubscript: "__eclipseSkyNativeStorage" as NSString)

        let html: @convention(block) (String) -> String = { request in
            htmlBridge.handle(request)
        }
        context.setObject(html, forKeyedSubscript: "__eclipseSkyNativeHTML" as NSString)

        let crypto: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] request, resolve, reject in
            self?.beginCryptoRequest(request, resolve: resolve, reject: reject)
        }
        context.setObject(crypto, forKeyedSubscript: "__eclipseSkyNativeCrypto" as NSString)

        let cryptoSync: @convention(block) (String) -> String = { request in
            (try? Self.performCrypto(request)) ?? ""
        }
        context.setObject(cryptoSync, forKeyedSubscript: "__eclipseSkyNativeCryptoSync" as NSString)

        let resolveURL: @convention(block) (String, String) -> String = { raw, base in
            guard raw.utf8.count <= 16_384, base.utf8.count <= 16_384,
                  let result = URL(string: raw, relativeTo: base.isEmpty ? nil : URL(string: base))?
                    .absoluteURL.absoluteString else { return "" }
            return result
        }
        context.setObject(resolveURL, forKeyedSubscript: "__eclipseSkyNativeResolveURL" as NSString)

        let randomBytes: @convention(block) (Int) -> String = { count in
            let bounded = max(0, min(count, 65_536))
            var bytes = [UInt8](repeating: 0, count: bounded)
            guard SecRandomCopyBytes(kSecRandomDefault, bounded, &bytes) == errSecSuccess else {
                return ""
            }
            return Data(bytes).base64EncodedString()
        }
        context.setObject(randomBytes, forKeyedSubscript: "__eclipseSkyNativeRandom" as NSString)

        let setTimer: @convention(block) (JSValue, Double, ObjCBool) -> Int = { [weak self] callback, delay, repeats in
            self?.scheduleTimer(callback: callback, delay: delay, repeats: repeats.boolValue) ?? -1
        }
        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in
            self?.clearTimer(id)
        }
        context.setObject(setTimer, forKeyedSubscript: "__eclipseSkyNativeSetTimer" as NSString)
        context.setObject(clearTimer, forKeyedSubscript: "__eclipseSkyNativeClearTimer" as NSString)

        let console = JSValue(newObjectIn: context)
        let ignore: @convention(block) (JSValue) -> Void = { _ in }
        console?.setObject(ignore, forKeyedSubscript: "log" as NSString)
        console?.setObject(ignore, forKeyedSubscript: "warn" as NSString)
        console?.setObject(ignore, forKeyedSubscript: "error" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    func beginHTTPRequest(_ requestJSON: String, resolve: JSValue, reject: JSValue) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let active else {
            reject.call(withArguments: ["Network requests are allowed only during an ABI operation."])
            return
        }
        guard active.resources.childTasks.count < Self.maximumOutstandingChildTasks else {
            reject.call(withArguments: ["Too many concurrent plugin requests."])
            return
        }
        let request: HTTPBridgeRequest
        do {
            request = try Self.decodeHTTPRequest(requestJSON)
        } catch {
            reject.call(withArguments: ["Invalid HTTP request."])
            return
        }

        let operationID = active.invocation.id
        let operationGeneration = active.generation
        let childID = UUID()
        let globalPermitID = UUID()
        let packagePermitID = UUID()
        let packageName = configuration.runtimePackageNamespace
        let responseLimit = configuration.limits.maximumSerializedResultBytes
        let timeout = max(
            configuration.limits.searchTimeout,
            configuration.limits.streamTimeout
        )

        let task = Task { [weak self] in
            guard let self else { return }
            var ownsGlobalPermit = false
            var ownsPackagePermit = false
            do {
                try await self.globalHTTPLimiter.acquire(globalPermitID)
                ownsGlobalPermit = true
                try Task.checkCancellation()
                try await self.packageHTTPLimiter.acquire(packagePermitID)
                ownsPackagePermit = true
                try Task.checkCancellation()

                let validatedURL = try await SkyStreamRemoteURLPolicy.shared.validate(
                    request.url,
                    purpose: .pluginRequest
                )
                var rawHeaders = SkyStreamRuntimeHeaderCompatibility.droppingControlled(
                    request.headers
                )
                if !rawHeaders.keys.contains(where: {
                    $0.caseInsensitiveCompare("User-Agent") == .orderedSame
                }) {
                    rawHeaders["User-Agent"] =
                        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                        + "(KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
                }
                if ["POST", "PUT", "PATCH"].contains(request.method),
                   !rawHeaders.keys.contains(where: {
                       $0.caseInsensitiveCompare("Content-Type") == .orderedSame
                   }) {
                    rawHeaders["Content-Type"] = "application/x-www-form-urlencoded"
                }
                let headers = try SkyStreamHeaderSanitizer.sanitize(
                    rawHeaders,
                    purpose: .pluginRequest
                )
                let response = try await SkyStreamHTTPClient.shared.fetch(
                    SkyStreamHTTPRequest(
                        url: validatedURL,
                        method: request.method,
                        headers: headers,
                        body: request.body
                    ),
                    packageID: packageName,
                    limits: SkyStreamHTTPRequestLimits(
                        maximumResponseBytes: responseLimit,
                        maximumRequestBodyBytes: 2 * 1_024 * 1_024,
                        maximumRedirects: 5,
                        timeout: timeout
                    )
                )
                let responseJSON = try Self.httpResponseJSON(response)

                if ownsPackagePermit { await self.packageHTTPLimiter.release(packagePermitID) }
                if ownsGlobalPermit { await self.globalHTTPLimiter.release(globalPermitID) }
                ownsPackagePermit = false
                ownsGlobalPermit = false

                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.removeChildTask(childID, operationID: operationID)
                    guard self.active?.invocation.id == operationID,
                          self.active?.generation == operationGeneration,
                          self.generation == operationGeneration else { return }
                    resolve.call(withArguments: [responseJSON])
                }
            } catch {
                if ownsPackagePermit { await self.packageHTTPLimiter.release(packagePermitID) }
                if ownsGlobalPermit { await self.globalHTTPLimiter.release(globalPermitID) }
                let safeError = Self.safeNetworkError(error)
                let wasCancelled = Task.isCancelled
                    || error is CancellationError
                    || (error as? SkyStreamSecurityError) == .cancelled
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.removeChildTask(childID, operationID: operationID)
                    guard self.active?.invocation.id == operationID,
                          self.active?.generation == operationGeneration,
                          self.generation == operationGeneration else { return }
                    if wasCancelled {
                        reject.call(withArguments: [safeError])
                    } else {
                        // The documented bridge represents transport failure as a status-zero
                        // response so provider fallback code can try its next endpoint.
                        resolve.call(withArguments: [Self.httpFailureJSON()])
                    }
                }
            }
        }
        active.resources.childTasks[childID] = task
    }

    func removeChildTask(_ childID: UUID, operationID: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active?.invocation.id == operationID else { return }
        active?.resources.childTasks.removeValue(forKey: childID)
    }

    static func decodeHTTPRequest(_ json: String) throws -> HTTPBridgeRequest {
        guard json.utf8.count <= 2_500_000,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String,
              url.utf8.count <= 16_384 else {
            throw SkyStreamRuntimeError.invalidConfiguration
        }
        let method = (object["method"] as? String ?? "GET").uppercased()
        var headers: [String: String] = [:]
        if let rawHeaders = object["headers"] as? [String: Any] {
            for (key, value) in rawHeaders.prefix(64) {
                if let string = value as? String {
                    headers[key] = string
                } else if let number = value as? NSNumber {
                    headers[key] = number.stringValue
                }
            }
        }
        let body: Data?
        if let text = object["body"] as? String {
            body = text.data(using: .utf8)
        } else {
            body = nil
        }
        return HTTPBridgeRequest(method: method, url: url, headers: headers, body: body)
    }

    static func httpResponseJSON(_ response: SkyStreamHTTPResponse) throws -> String {
        let body = String(data: response.data, encoding: .utf8)
            ?? String(data: response.data, encoding: .isoLatin1)
            ?? ""
        let headers = SkyStreamHTTPResponseHeaderProjection.project(
            response.response.allHeaderFields
        )
        let object: [String: Any] = [
            "code": response.statusCode,
            "status": response.statusCode,
            "statusCode": response.statusCode,
            "ok": (200..<300).contains(response.statusCode),
            "url": response.finalURL.absoluteString,
            "finalUrl": response.finalURL.absoluteString,
            "body": body,
            "headers": headers
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SkyStreamRuntimeError.malformedResult
        }
        return json
    }

    static func httpFailureJSON() -> String {
        "{\"body\":\"\",\"code\":0,\"error\":\"Network request failed.\",\"headers\":{},\"ok\":false,\"status\":0,\"statusCode\":0}"
    }

    static func safeNetworkError(_ error: Error) -> String {
        if error is CancellationError || (error as? SkyStreamSecurityError) == .cancelled {
            return "Network request cancelled."
        }
        if let security = error as? SkyStreamSecurityError {
            return security.localizedDescription
        }
        if let urlError = error as? URLError {
            return "Network request failed (\(urlError.code.rawValue))."
        }
        return "Network request failed."
    }

    func handleStorageRequest(_ requestJSON: String) -> String {
        dispatchPrecondition(condition: .onQueue(queue))
        guard requestJSON.utf8.count <= 128 * 1_024,
              let data = requestJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String,
              let key = object["key"] as? String else {
            return "{\"ok\":false}"
        }
        do {
            switch action {
            case "getStorage":
                let value: String?
                if let transaction = active?.transaction {
                    value = transaction.storageValue(for: key)
                } else {
                    value = configuration.dataStore.storageValue(for: key)
                }
                return try Self.storageResponse(value)
            case "setStorage":
                // Package evaluation and install smoke tests have no active ABI operation.
                // Keep reads available for normal module initialization, but do not let
                // top-level untrusted code leave state that a later operation would persist.
                guard let transaction = active?.transaction else {
                    return "{\"ok\":false}"
                }
                let value = object["value"] as? String
                try transaction.setStorageValue(value, for: key)
                return "{\"ok\":true}"
            case "getPreference":
                let value: SkyStreamJSONValue?
                if let transaction = active?.transaction {
                    value = transaction.preferenceValue(for: key)
                } else {
                    value = configuration.dataStore.preferenceValue(for: key)
                }
                return try Self.preferenceResponse(value)
            case "setPreference":
                guard let transaction = active?.transaction else {
                    return "{\"ok\":false}"
                }
                let value: SkyStreamJSONValue?
                if let raw = object["valueJSON"] as? String,
                   let encoded = raw.data(using: .utf8) {
                    try SkyStreamJSONEnvelopeValidator.validate(
                        encoded,
                        limits: .runtimePreference
                    )
                    let decoded = try JSONDecoder().decode(
                        SkyStreamJSONValue.self,
                        from: encoded
                    )
                    try SkyStreamJSONValueShapePolicy.validate(
                        decoded,
                        limits: .runtimePreference
                    )
                    value = decoded
                } else {
                    value = nil
                }
                try transaction.setPreferenceValue(value, for: key)
                return "{\"ok\":true}"
            default:
                return "{\"ok\":false}"
            }
        } catch {
            return "{\"ok\":false,\"error\":\"Storage quota exceeded.\"}"
        }
    }

    static func storageResponse(_ value: String?) throws -> String {
        let object: [String: Any] = ["ok": true, "value": value ?? NSNull()]
        return String(
            data: try JSONSerialization.data(withJSONObject: object),
            encoding: .utf8
        ) ?? "{\"ok\":false}"
    }

    static func preferenceResponse(_ value: SkyStreamJSONValue?) throws -> String {
        guard let value else { return "{\"ok\":true,\"value\":null}" }
        let valueData = try JSONEncoder().encode(value)
        let valueObject = try JSONSerialization.jsonObject(
            with: valueData,
            options: [.fragmentsAllowed]
        )
        let object: [String: Any] = ["ok": true, "value": valueObject]
        return String(
            data: try JSONSerialization.data(withJSONObject: object),
            encoding: .utf8
        ) ?? "{\"ok\":false}"
    }

    func scheduleTimer(callback: JSValue, delay: Double, repeats: Bool) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let current = active,
              current.resources.timers.count < Self.maximumOutstandingTimers,
              !callback.isUndefined,
              !callback.isNull else { return -1 }
        let timerID = nextTimerID
        nextTimerID &+= 1
        let operationID = current.invocation.id
        let operationGeneration = current.generation
        let boundedDelay = max(repeats ? 16 : 0, min(delay.isFinite ? delay : 0, 60_000)) / 1_000

        func schedule() {
            let item = DispatchWorkItem { [weak self] in
                guard let self,
                      self.active?.invocation.id == operationID,
                      self.active?.generation == operationGeneration,
                      self.generation == operationGeneration,
                      self.active?.resources.timers[timerID] != nil else { return }
                if !repeats {
                    self.active?.resources.timers.removeValue(forKey: timerID)
                }
                _ = callback.call(withArguments: [])
                if repeats,
                   self.active?.invocation.id == operationID,
                   self.active?.resources.timers[timerID] != nil {
                    schedule()
                }
            }
            active?.resources.timers[timerID] = item
            queue.asyncAfter(deadline: .now() + boundedDelay, execute: item)
        }
        schedule()
        return timerID
    }

    func clearTimer(_ id: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        active?.resources.timers.removeValue(forKey: id)?.cancel()
    }
}

// MARK: Crypto bridge

private extension SkyStreamProviderRuntime {
    func beginCryptoRequest(_ requestJSON: String, resolve: JSValue, reject: JSValue) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let active else {
            reject.call(withArguments: ["Cryptography is allowed only during an ABI operation."])
            return
        }
        guard active.resources.childTasks.count < Self.maximumOutstandingChildTasks else {
            reject.call(withArguments: ["Too many concurrent plugin operations."])
            return
        }
        let operationID = active.invocation.id
        let operationGeneration = active.generation
        let childID = UUID()

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try Self.performCrypto(requestJSON))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                self.removeChildTask(childID, operationID: operationID)
                guard self.active?.invocation.id == operationID,
                      self.active?.generation == operationGeneration,
                      self.generation == operationGeneration else { return }
                switch result {
                case .success(let value):
                    resolve.call(withArguments: [value])
                case .failure:
                    reject.call(withArguments: ["Cryptographic operation failed."])
                }
            }
        }
        active.resources.childTasks[childID] = task
    }

    static func performCrypto(_ requestJSON: String) throws -> String {
        guard requestJSON.utf8.count <= 256 * 1_024,
              let data = requestJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let operation = object["operation"] as? String else {
            throw SkyStreamRuntimeError.unsupportedCrypto
        }
        switch operation {
        case "md5":
            guard let raw = object["data"] as? String,
                  let bytes = Data(base64Encoded: raw) else {
                throw SkyStreamRuntimeError.unsupportedCrypto
            }
            return Data(Insecure.MD5.hash(data: bytes)).base64EncodedString()

        case "sha256":
            guard let raw = object["data"] as? String,
                  let bytes = Data(base64Encoded: raw) else {
                throw SkyStreamRuntimeError.unsupportedCrypto
            }
            return Data(SHA256.hash(data: bytes)).base64EncodedString()

        case "pbkdf2":
            guard let password = object["password"] as? String,
                  password.utf8.count <= 64 * 1_024,
                  let saltText = object["salt"] as? String,
                  let salt = Data(base64Encoded: saltText) else {
                throw SkyStreamRuntimeError.unsupportedCrypto
            }
            let iterations = max(1, min((object["iterations"] as? NSNumber)?.intValue ?? 10_000, 250_000))
            let keyLength = max(1, min((object["keyLength"] as? NSNumber)?.intValue ?? 32, 64))
            return try derivePBKDF2(
                password: password,
                salt: salt,
                iterations: iterations,
                keyLength: keyLength
            ).base64EncodedString()

        case "aes":
            guard let encryptedText = object["data"] as? String,
                  let encrypted = Data(base64Encoded: Self.paddedBase64(encryptedText)),
                  let keyText = object["key"] as? String,
                  let key = Data(base64Encoded: Self.paddedBase64(keyText)),
                  let ivText = object["iv"] as? String,
                  let iv = Data(base64Encoded: Self.paddedBase64(ivText)) else {
                throw SkyStreamRuntimeError.unsupportedCrypto
            }
            let mode = (object["mode"] as? String ?? "cbc").lowercased()
            let clear: Data
            if mode == "gcm" {
                clear = try decryptGCM(encrypted: encrypted, key: key, nonceData: iv)
            } else if mode == "cbc" {
                clear = try decryptCBC(encrypted: encrypted, key: key, iv: iv)
            } else {
                throw SkyStreamRuntimeError.unsupportedCrypto
            }
            return clear.base64EncodedString()

        default:
            throw SkyStreamRuntimeError.unsupportedCrypto
        }
    }

    static func paddedBase64(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.count % 4 != 0 { result.append("=") }
        return result
    }

    static func decryptGCM(encrypted: Data, key: Data, nonceData: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count), nonceData.count == 12, encrypted.count >= 16 else {
            throw SkyStreamRuntimeError.unsupportedCrypto
        }
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let ciphertext = encrypted.dropLast(16)
        let tag = encrypted.suffix(16)
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    static func decryptCBC(encrypted: Data, key: Data, iv: Data) throws -> Data {
#if canImport(CommonCrypto)
        guard [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count),
              iv.count == kCCBlockSizeAES128,
              encrypted.count <= 10 * 1_024 * 1_024 else {
            throw SkyStreamRuntimeError.unsupportedCrypto
        }
        let outputCapacity = encrypted.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var moved = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBytes in
            encrypted.withUnsafeBytes { encryptedBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            encryptedBytes.baseAddress,
                            encrypted.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw SkyStreamRuntimeError.unsupportedCrypto }
        output.removeSubrange(moved..<output.count)
        return output
#else
        throw SkyStreamRuntimeError.unsupportedCrypto
#endif
    }

    static func derivePBKDF2(
        password: String,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) throws -> Data {
#if canImport(CommonCrypto)
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status: Int32 = salt.withUnsafeBytes { saltBytes in
            password.withCString { passwordBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes,
                    password.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived,
                    keyLength
                )
            }
        }
        guard status == kCCSuccess else { throw SkyStreamRuntimeError.unsupportedCrypto }
        return Data(derived)
#else
        throw SkyStreamRuntimeError.unsupportedCrypto
#endif
    }
}

// MARK: Bounded HTML bridge

/// A native DOM bridge owned by exactly one `SkyStreamProviderRuntime` context.
///
/// `parseHtml`/`JSDOM` callers commonly run several selectors over the same page.
/// Parsing that page for every selector was both CPU-heavy and forced the entire
/// HTML string through JavaScriptCore for every call. The bridge now returns an
/// opaque, context-local handle after the first parse and keeps a small LRU of
/// parsed trees. Raw-HTML requests remain supported for the existing `parse_html`
/// compatibility path and are deduplicated into the same cache.
final class SkyStreamHTMLBridge: @unchecked Sendable {
    struct Diagnostics: Equatable {
        let parseCount: Int
        let cachedDocumentCount: Int
        let cachedHTMLBytes: Int
        let isInvalidated: Bool
    }

    private struct CachedDocument {
        let handle: String
        let html: String
        let htmlByteCount: Int
#if canImport(SwiftSoup)
        let document: SwiftSoup.Document
#endif
        var lastAccess: UInt64
    }

    private static let maximumHTMLBytes = 2 * 1_024 * 1_024
    private static let maximumResults = 1_000
    private static let maximumOutputBytes = 2 * 1_024 * 1_024
    private static let maximumRequestBytes = maximumHTMLBytes + 8 * 1_024

    private let maximumCachedDocuments: Int
    private let maximumCachedHTMLBytes: Int
    private let lock = NSLock()
    private var documentsByHandle: [String: CachedDocument] = [:]
    private var handleByHTML: [String: String] = [:]
    private var cachedHTMLBytes = 0
    private var accessClock: UInt64 = 0
    private var parseCount = 0
    private var isInvalidated = false

    init(
        maximumCachedDocuments: Int = 4,
        maximumCachedHTMLBytes: Int = 4 * 1_024 * 1_024
    ) {
        self.maximumCachedDocuments = max(1, min(maximumCachedDocuments, 8))
        self.maximumCachedHTMLBytes = max(1, min(maximumCachedHTMLBytes, 8 * 1_024 * 1_024))
    }

    var diagnostics: Diagnostics {
        lock.lock()
        defer { lock.unlock() }
        return Diagnostics(
            parseCount: parseCount,
            cachedDocumentCount: documentsByHandle.count,
            cachedHTMLBytes: cachedHTMLBytes,
            isInvalidated: isInvalidated
        )
    }

    /// Invalid handles return no data after the owning JSContext is cancelled
    /// or replaced, even if JavaScriptCore happens to retain an old native block.
    func invalidate() {
        lock.lock()
        isInvalidated = true
        documentsByHandle.removeAll(keepingCapacity: false)
        handleByHTML.removeAll(keepingCapacity: false)
        cachedHTMLBytes = 0
        lock.unlock()
    }

    func handle(_ requestJSON: String) -> String {
        guard requestJSON.utf8.count <= Self.maximumRequestBytes,
              let data = requestJSON.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "[]"
        }

        switch request["action"] as? String {
        case "open":
            guard let html = boundedHTML(from: request) else {
                return Self.encoded(["handle": ""], fallback: "{\"handle\":\"\"}")
            }
            lock.lock()
            let handle = openDocumentLocked(html: html)
            lock.unlock()
            return Self.encoded(["handle": handle ?? ""], fallback: "{\"handle\":\"\"}")

        case "query":
            let selector = String((request["selector"] as? String ?? "*").prefix(2_048))
            let attribute = (request["attr"] as? String).map { String($0.prefix(256)) }
            let nodeSelector = (request["nodeSelector"] as? String).map {
                String($0.prefix(4_096))
            }
            if let handle = request["handle"] as? String, !handle.isEmpty {
                lock.lock()
                guard !isInvalidated, let entry = touchDocumentLocked(handle: handle) else {
                    lock.unlock()
                    return Self.encoded(["cacheMiss": true], fallback: "{\"cacheMiss\":true}")
                }
                let values = valuesLocked(
                    for: entry,
                    selector: selector,
                    attribute: attribute,
                    nodeSelector: nodeSelector
                )
                lock.unlock()
                return Self.encoded(values, fallback: "[]")
            }
            fallthrough

        case nil:
            // Legacy/raw path used by parse_html and retained so older bootstrap
            // variants still work. It shares the same exact-HTML cache.
            guard let html = boundedHTML(from: request) else { return "[]" }
            let selector = String((request["selector"] as? String ?? "*").prefix(2_048))
            let attribute = (request["attr"] as? String).map { String($0.prefix(256)) }
            lock.lock()
            guard !isInvalidated else {
                lock.unlock()
                return "[]"
            }
            let values: [[String: Any]]
            if let handle = openDocumentLocked(html: html),
               let entry = touchDocumentLocked(handle: handle) {
                values = valuesLocked(for: entry, selector: selector, attribute: attribute)
            } else {
                values = []
            }
            lock.unlock()
            return Self.encoded(values, fallback: "[]")

        case "relative":
            guard let handle = request["handle"] as? String, !handle.isEmpty,
                  let nodeSelector = request["nodeSelector"] as? String,
                  !nodeSelector.isEmpty,
                  nodeSelector.utf8.count <= 4_096,
                  let relation = request["relation"] as? String,
                  ["parentElement", "nextElementSibling", "previousElementSibling", "children"]
                    .contains(relation) else { return "null" }
            lock.lock()
            guard !isInvalidated, let entry = touchDocumentLocked(handle: handle) else {
                lock.unlock()
                return Self.encoded(["cacheMiss": true], fallback: "{\"cacheMiss\":true}")
            }
            let value = relativeValueLocked(
                for: entry,
                nodeSelector: nodeSelector,
                relation: relation
            )
            lock.unlock()
            return Self.encoded(value ?? NSNull(), fallback: "null")

        case "batch":
            guard let handle = request["handle"] as? String, !handle.isEmpty else {
                return "[]"
            }
            let nodeSelector = (request["nodeSelector"] as? String).map {
                String($0.prefix(4_096))
            }
            let queries = Array((request["queries"] as? [[String: Any]] ?? []).prefix(64))
            lock.lock()
            guard !isInvalidated, let entry = touchDocumentLocked(handle: handle) else {
                lock.unlock()
                return Self.encoded(["cacheMiss": true], fallback: "{\"cacheMiss\":true}")
            }
            let values = batchValuesLocked(
                for: entry,
                nodeSelector: nodeSelector,
                queries: queries
            )
            lock.unlock()
            return Self.encoded(values, fallback: "[]")

        default:
            return "[]"
        }
    }

    private func boundedHTML(from request: [String: Any]) -> String? {
        guard let html = request["html"] as? String,
              html.utf8.count <= Self.maximumHTMLBytes else { return nil }
        return html
    }

    /// Must be called with `lock` held.
    private func openDocumentLocked(html: String) -> String? {
        guard !isInvalidated else { return nil }
        if let existingHandle = handleByHTML[html],
           touchDocumentLocked(handle: existingHandle) != nil {
            return existingHandle
        }

        let byteCount = html.utf8.count
        guard byteCount <= maximumCachedHTMLBytes else { return nil }
#if canImport(SwiftSoup)
        let document: SwiftSoup.Document
        do {
            document = try SwiftSoup.parse(html)
        } catch {
            return nil
        }
        parseCount += 1
#endif

        while documentsByHandle.count >= maximumCachedDocuments
            || cachedHTMLBytes + byteCount > maximumCachedHTMLBytes {
            guard let evicted = documentsByHandle.values.min(by: {
                $0.lastAccess < $1.lastAccess
            }) else { return nil }
            removeDocumentLocked(handle: evicted.handle)
        }

        accessClock &+= 1
        let handle = UUID().uuidString
#if canImport(SwiftSoup)
        let entry = CachedDocument(
            handle: handle,
            html: html,
            htmlByteCount: byteCount,
            document: document,
            lastAccess: accessClock
        )
#else
        let entry = CachedDocument(
            handle: handle,
            html: html,
            htmlByteCount: byteCount,
            lastAccess: accessClock
        )
#endif
        documentsByHandle[handle] = entry
        handleByHTML[html] = handle
        cachedHTMLBytes += byteCount
        return handle
    }

    /// Must be called with `lock` held.
    private func touchDocumentLocked(handle: String) -> CachedDocument? {
        guard var entry = documentsByHandle[handle] else { return nil }
        accessClock &+= 1
        entry.lastAccess = accessClock
        documentsByHandle[handle] = entry
        return entry
    }

    /// Must be called with `lock` held.
    private func removeDocumentLocked(handle: String) {
        guard let removed = documentsByHandle.removeValue(forKey: handle) else { return }
        if handleByHTML[removed.html] == handle {
            handleByHTML.removeValue(forKey: removed.html)
        }
        cachedHTMLBytes = max(0, cachedHTMLBytes - removed.htmlByteCount)
    }

    /// Must be called with `lock` held because SwiftSoup documents are not
    /// promised to be safe for concurrent traversal.
    private func valuesLocked(
        for entry: CachedDocument,
        selector: String,
        attribute: String?,
        nodeSelector: String? = nil
    ) -> [[String: Any]] {
#if canImport(SwiftSoup)
        return Self.swiftSoupValues(
            document: entry.document,
            handle: entry.handle,
            selector: selector,
            attribute: attribute,
            nodeSelector: nodeSelector
        )
#else
        return Self.fallbackValues(html: entry.html, selector: selector, attribute: attribute)
#endif
    }

    /// Must be called with `lock` held.
    private func relativeValueLocked(
        for entry: CachedDocument,
        nodeSelector: String,
        relation: String
    ) -> Any? {
#if canImport(SwiftSoup)
        do {
            guard let element = try entry.document.select(nodeSelector).first() else { return nil }
            switch relation {
            case "parentElement":
                guard let parent = element.parent(), !(parent is SwiftSoup.Document) else { return nil }
                return try Self.serialize(parent, handle: entry.handle, attribute: nil)
            case "nextElementSibling":
                guard let sibling = try element.nextElementSibling() else { return nil }
                return try Self.serialize(sibling, handle: entry.handle, attribute: nil)
            case "previousElementSibling":
                guard let sibling = try element.previousElementSibling() else { return nil }
                return try Self.serialize(sibling, handle: entry.handle, attribute: nil)
            case "children":
                return try element.children().array().prefix(Self.maximumResults).map {
                    try Self.serialize($0, handle: entry.handle, attribute: nil)
                }
            default:
                return nil
            }
        } catch {
            return nil
        }
#else
        return nil
#endif
    }

    /// Must be called with `lock` held.
    private func batchValuesLocked(
        for entry: CachedDocument,
        nodeSelector: String?,
        queries: [[String: Any]]
    ) -> [Any] {
#if canImport(SwiftSoup)
        do {
            let root: SwiftSoup.Element
            if let nodeSelector, !nodeSelector.isEmpty {
                guard let selected = try entry.document.select(nodeSelector).first() else { return [] }
                root = selected
            } else {
                root = entry.document
            }
            return try queries.map { query in
                let selector = String((query["query"] as? String ?? "*").prefix(2_048))
                let attribute = String((query["attr"] as? String ?? "textContent").prefix(256))
                let first = query["first"] as? Bool ?? false
                let elements = try root.select(selector).array()
                    .filter { $0 !== root }
                    .prefix(Self.maximumResults)
                if first {
                    guard let element = elements.first else { return NSNull() }
                    return try Self.selectedValue(element, attribute: attribute)
                }
                return try elements.map { try Self.selectedValue($0, attribute: attribute) }
            }
        } catch {
            return []
        }
#else
        guard nodeSelector == nil else { return [] }
        return queries.map { query in
            let selector = String((query["query"] as? String ?? "*").prefix(2_048))
            let attribute = String((query["attr"] as? String ?? "textContent").prefix(256))
            let first = query["first"] as? Bool ?? false
            let values = Self.fallbackValues(
                html: entry.html,
                selector: selector,
                attribute: attribute
            ).compactMap { $0["attr"] as? String }
            if first {
                if let firstValue = values.first { return firstValue }
                return NSNull()
            }
            return values
        }
#endif
    }

    private static func encoded(_ object: Any, fallback: String) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let encoded = try? JSONSerialization.data(withJSONObject: object),
              encoded.count <= maximumOutputBytes,
              let result = String(data: encoded, encoding: .utf8) else { return fallback }
        return result
    }

#if canImport(SwiftSoup)
    private static func swiftSoupValues(
        document: SwiftSoup.Document,
        handle: String,
        selector: String,
        attribute: String?,
        nodeSelector: String?
    ) -> [[String: Any]] {
        do {
            let root: SwiftSoup.Element
            if let nodeSelector, !nodeSelector.isEmpty {
                guard let selected = try document.select(nodeSelector).first() else { return [] }
                root = selected
            } else {
                root = document
            }
            return try root.select(selector).array()
                .filter { $0 !== root }
                .prefix(maximumResults)
                .map { element in
                    try serialize(element, handle: handle, attribute: attribute)
                }
        } catch {
            return []
        }
    }

    private static func serialize(
        _ element: SwiftSoup.Element,
        handle: String,
        attribute: String?
    ) throws -> [String: Any] {
        var attributes: [String: String] = [:]
        for attribute in (element.getAttributes()?.asList() ?? []).prefix(64) {
            let key = attribute.getKey()
            let value = attribute.getValue()
            if key.utf8.count <= 128, value.utf8.count <= 16 * 1_024 {
                attributes[key] = value
            }
        }
        var result: [String: Any] = [
            "text": String(try element.text().prefix(256 * 1_024)),
            "html": String(try element.html().prefix(256 * 1_024)),
            "outerHTML": String(try element.outerHtml().prefix(256 * 1_024)),
            "attr": String(try selectedValue(element, attribute: attribute).prefix(256 * 1_024)),
            "attributes": attributes,
            "tagName": element.tagName(),
            "nodeHandle": handle
        ]
        if let selector = try? element.cssSelector(), selector.utf8.count <= 4_096 {
            result["nodeSelector"] = selector
        }
        return result
    }

    private static func selectedValue(
        _ element: SwiftSoup.Element,
        attribute: String?
    ) throws -> String {
        switch attribute {
        case "innerHTML": return try element.html()
        case "outerHTML": return try element.outerHtml()
        case "tagName": return element.tagName()
        case "className": return try element.className()
        case "text", "textContent", nil: return try element.text()
        case .some(let name): return try element.attr(name)
        }
    }
#endif

    /// Deliberately small fallback for builds that have not linked SwiftSoup.
    /// It supports tag, #id, .class, tag#id, and tag.class selectors. The
    /// package integration should link SwiftSoup for full CSS selector parity.
    private static func fallbackValues(
        html: String,
        selector: String,
        attribute: String?
    ) -> [[String: Any]] {
        let parsed = fallbackSelector(selector)
        guard parsed.isValid else { return [] }
        let tagPattern = parsed.tag.map(NSRegularExpression.escapedPattern)
            ?? "[A-Za-z][A-Za-z0-9:-]*"
        let pattern = "<(\(tagPattern))\\b([^>]*)>([\\s\\S]*?)</\\1\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let source = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        var output: [[String: Any]] = []
        for match in matches.prefix(maximumResults) {
            let tagName = source.substring(with: match.range(at: 1))
            let rawAttributes = source.substring(with: match.range(at: 2))
            let inner = source.substring(with: match.range(at: 3))
            let attributes = parseAttributes(rawAttributes)
            if let id = parsed.id, attributes["id"] != id { continue }
            if let className = parsed.className {
                let classes = Set((attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
                if !classes.contains(className) { continue }
            }
            let outer = source.substring(with: match.range(at: 0))
            let text = inner.replacingOccurrences(
                of: "<[^>]+>",
                with: " ",
                options: .regularExpression
            ).replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let selected: String
            switch attribute {
            case "innerHTML": selected = inner
            case "outerHTML": selected = outer
            case "text", "textContent", nil: selected = text
            case .some(let name): selected = attributes[name] ?? ""
            }
            output.append([
                "text": String(text.prefix(256 * 1_024)),
                "html": String(inner.prefix(256 * 1_024)),
                "outerHTML": String(outer.prefix(256 * 1_024)),
                "attr": String(selected.prefix(256 * 1_024)),
                "attributes": attributes,
                "tagName": tagName
            ])
        }
        return output
    }

    private static func fallbackSelector(
        _ selector: String
    ) -> (tag: String?, id: String?, className: String?, isValid: Bool) {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains(">") else {
            return (nil, nil, nil, false)
        }
        if trimmed.hasPrefix("#") {
            return (nil, String(trimmed.dropFirst()), nil, true)
        }
        if trimmed.hasPrefix(".") {
            return (nil, nil, String(trimmed.dropFirst()), true)
        }
        if let hash = trimmed.firstIndex(of: "#") {
            return (String(trimmed[..<hash]), String(trimmed[trimmed.index(after: hash)...]), nil, true)
        }
        if let dot = trimmed.firstIndex(of: ".") {
            return (String(trimmed[..<dot]), nil, String(trimmed[trimmed.index(after: dot)...]), true)
        }
        if trimmed == "*" {
            return (nil, nil, nil, true)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":-"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return (nil, nil, nil, false)
        }
        return (trimmed, nil, nil, true)
    }

    private static func parseAttributes(_ source: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        ) else { return [:] }
        let string = source as NSString
        var output: [String: String] = [:]
        for match in regex.matches(in: source, range: NSRange(location: 0, length: string.length)).prefix(64) {
            let key = string.substring(with: match.range(at: 1)).lowercased()
            let valueRange = [2, 3, 4].map { match.range(at: $0) }.first { $0.location != NSNotFound }
            guard let valueRange else { continue }
            let value = string.substring(with: valueRange)
            if value.utf8.count <= 16 * 1_024 { output[key] = value }
        }
        return output
    }
}

// MARK: JavaScript compatibility environment

private extension SkyStreamProviderRuntime {
    static let runtimeCodeLockdown = #"""
    (function () {
        "use strict";
        function blockedDynamicCode() {
            throw new Error("DYNAMIC_CODE_UNSUPPORTED");
        }
        var dynamicConstructorPrototypes = [];
        try { dynamicConstructorPrototypes.push(Object.getPrototypeOf(function () {})); } catch (_) {}
        try { dynamicConstructorPrototypes.push(Object.getPrototypeOf(function* () {})); } catch (_) {}
        try { dynamicConstructorPrototypes.push(Object.getPrototypeOf(async function () {})); } catch (_) {}
        try { dynamicConstructorPrototypes.push(Object.getPrototypeOf(async function* () {})); } catch (_) {}

        // Function, GeneratorFunction, AsyncFunction, and AsyncGeneratorFunction are distinct
        // constructors in JavaScriptCore. Blocking only globalThis.Function still leaves the
        // other three reachable through a function object's prototype.
        dynamicConstructorPrototypes.forEach(function (prototype) {
            try {
                Object.defineProperty(prototype, "constructor", {
                    value: blockedDynamicCode,
                    writable: false,
                    configurable: false
                });
            } catch (_) {}
        });
        try {
            Object.defineProperty(globalThis, "eval", {
                value: blockedDynamicCode,
                writable: false,
                configurable: false
            });
        } catch (_) { globalThis.eval = blockedDynamicCode; }
        try {
            Object.defineProperty(globalThis, "Function", {
                value: blockedDynamicCode,
                writable: false,
                configurable: false
            });
        } catch (_) { globalThis.Function = blockedDynamicCode; }
        // WebAssembly would be another fetched, unhashed executable payload and is not part of
        // the documented plugin ABI.
        try {
            Object.defineProperty(globalThis, "WebAssembly", {
                value: undefined,
                writable: false,
                configurable: false
            });
        } catch (_) { try { globalThis.WebAssembly = undefined; } catch (_) {} }
    })();
    """#

    static let captureExportsScript = #"""
    (function () {
        "use strict";
        var pick = function (lexical, globalName) {
            return typeof lexical === "function" ? lexical
                : (typeof globalThis[globalName] === "function" ? globalThis[globalName] : undefined);
        };
        var searchExport = (typeof search === "function") ? search : globalThis.search;
        var loadExport = (typeof load === "function") ? load : globalThis.load;
        var streamExport = (typeof loadStreams === "function") ? loadStreams : globalThis.loadStreams;
        var providersExport = (typeof getProviders === "function") ? getProviders : globalThis.getProviders;
        globalThis.__eclipseSkyExports = {
            search: typeof searchExport === "function" ? searchExport : undefined,
            load: typeof loadExport === "function" ? loadExport : undefined,
            loadStreams: typeof streamExport === "function" ? streamExport : undefined,
            getProviders: typeof providersExport === "function" ? providersExport : undefined
        };
        globalThis.__eclipseSkyExportNames = Object.keys(globalThis.__eclipseSkyExports)
            .filter(function (name) { return typeof globalThis.__eclipseSkyExports[name] === "function"; });

        // Eclipse never calls or retains the catalog entry point.
        try { delete globalThis.getHome; } catch (_) {}
    })();
    """#

    static let runtimeBootstrap = #"""
    (function () {
        "use strict";
        globalThis.global = globalThis;

        if (!Array.prototype.flat) {
            Array.prototype.flat = function (depth) {
                depth = depth === undefined ? 1 : Number(depth) || 0;
                var out = [];
                (function visit(values, level) {
                    values.forEach(function (value) {
                        if (Array.isArray(value) && level > 0) visit(value, level - 1);
                        else out.push(value);
                    });
                })(this, depth);
                return out;
            };
        }
        if (!Array.prototype.flatMap) {
            Array.prototype.flatMap = function (callback, thisArg) {
                return this.map(callback, thisArg).flat(1);
            };
        }

        function _skyParseJSON(value, fallback) {
            try { return JSON.parse(value); } catch (_) { return fallback; }
        }
        function _skyBinaryToBase64(bytes) {
            var binary = "";
            for (var i = 0; i < bytes.length; i += 0x8000) {
                binary += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + 0x8000, bytes.length)));
            }
            return btoa(binary);
        }
        function _skyBase64ToBytes(value) {
            var binary = atob(String(value || ""));
            var bytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i) & 255;
            return bytes;
        }
        function _skyToBytes(value) {
            if (value instanceof ArrayBuffer) return new Uint8Array(value);
            if (ArrayBuffer.isView && ArrayBuffer.isView(value)) {
                return new Uint8Array(value.buffer, value.byteOffset || 0, value.byteLength);
            }
            if (Array.isArray(value)) return new Uint8Array(value);
            return new TextEncoder().encode(String(value === undefined ? "" : value));
        }

        globalThis.btoa = globalThis.btoa || function (input) {
            var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
            var str = String(input);
            var output = "";
            for (var block, charCode, idx = 0, map = chars; str.charAt(idx | 0) || (map = "=", idx % 1); output += map.charAt(63 & block >> 8 - idx % 1 * 8)) {
                charCode = str.charCodeAt(idx += 3 / 4);
                if (charCode > 255) throw new TypeError("btoa accepts only byte strings");
                block = block << 8 | charCode;
            }
            return output;
        };
        globalThis.atob = globalThis.atob || function (input) {
            var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
            var str = String(input).replace(/=+$/, "").replace(/\s+/g, "");
            if (str.length % 4 === 1) throw new TypeError("Invalid base64");
            var output = "";
            for (var bc = 0, bs, buffer, idx = 0; (buffer = str.charAt(idx++));) {
                buffer = chars.indexOf(buffer);
                if (buffer < 0) throw new TypeError("Invalid base64");
                bs = bc % 4 ? bs * 64 + buffer : buffer;
                if (bc++ % 4) output += String.fromCharCode(255 & bs >> (-2 * bc & 6));
            }
            return output;
        };

        if (typeof TextEncoder === "undefined") {
            globalThis.TextEncoder = function TextEncoder() {};
            TextEncoder.prototype.encode = function (input) {
                var utf8 = unescape(encodeURIComponent(String(input)));
                var result = new Uint8Array(utf8.length);
                for (var i = 0; i < utf8.length; i++) result[i] = utf8.charCodeAt(i);
                return result;
            };
        }
        if (typeof TextDecoder === "undefined") {
            globalThis.TextDecoder = function TextDecoder() {};
            TextDecoder.prototype.decode = function (input) {
                var bytes = _skyToBytes(input);
                var binary = "";
                for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
                try { return decodeURIComponent(escape(binary)); } catch (_) { return binary; }
            };
        }

        function SkyHeaders(initial) {
            this._values = {};
            var self = this;
            if (initial && typeof initial.forEach === "function" && initial instanceof SkyHeaders) {
                initial.forEach(function (v, k) { self.set(k, v); });
            } else if (Array.isArray(initial)) {
                initial.forEach(function (pair) { if (pair && pair.length >= 2) self.set(pair[0], pair[1]); });
            } else if (initial && typeof initial === "object") {
                Object.keys(initial).forEach(function (key) { self.set(key, initial[key]); });
            }
        }
        SkyHeaders.prototype.set = function (name, value) { this._values[String(name).toLowerCase()] = String(value); };
        SkyHeaders.prototype.append = function (name, value) {
            name = String(name).toLowerCase();
            this._values[name] = this._values[name] ? this._values[name] + ", " + String(value) : String(value);
        };
        SkyHeaders.prototype.get = function (name) { return this._values[String(name).toLowerCase()] || null; };
        SkyHeaders.prototype.has = function (name) { return Object.prototype.hasOwnProperty.call(this._values, String(name).toLowerCase()); };
        SkyHeaders.prototype.delete = function (name) { delete this._values[String(name).toLowerCase()]; };
        SkyHeaders.prototype.forEach = function (callback, thisArg) {
            var self = this;
            Object.keys(this._values).forEach(function (key) { callback.call(thisArg, self._values[key], key, self); });
        };
        SkyHeaders.prototype.toJSON = function () { return Object.assign({}, this._values); };
        globalThis.Headers = globalThis.Headers || SkyHeaders;

        function SkyURLSearchParams(input) {
            this._pairs = [];
            var self = this;
            if (typeof input === "string") {
                input.replace(/^\?/, "").split("&").forEach(function (part) {
                    if (!part) return;
                    var bits = part.split("=");
                    self.append(decodeURIComponent(bits.shift().replace(/\+/g, " ")), decodeURIComponent(bits.join("=").replace(/\+/g, " ")));
                });
            } else if (Array.isArray(input)) {
                input.forEach(function (pair) { self.append(pair[0], pair[1]); });
            } else if (input && typeof input === "object") {
                Object.keys(input).forEach(function (key) { self.append(key, input[key]); });
            }
        }
        SkyURLSearchParams.prototype.append = function (key, value) { this._pairs.push([String(key), String(value)]); };
        SkyURLSearchParams.prototype.set = function (key, value) { this.delete(key); this.append(key, value); };
        SkyURLSearchParams.prototype.get = function (key) {
            key = String(key); for (var i = 0; i < this._pairs.length; i++) if (this._pairs[i][0] === key) return this._pairs[i][1]; return null;
        };
        SkyURLSearchParams.prototype.getAll = function (key) { key = String(key); return this._pairs.filter(function (p) { return p[0] === key; }).map(function (p) { return p[1]; }); };
        SkyURLSearchParams.prototype.has = function (key) { return this.get(key) !== null; };
        SkyURLSearchParams.prototype.delete = function (key) { key = String(key); this._pairs = this._pairs.filter(function (p) { return p[0] !== key; }); };
        SkyURLSearchParams.prototype.forEach = function (callback, thisArg) { this._pairs.forEach(function (p) { callback.call(thisArg, p[1], p[0], this); }, this); };
        SkyURLSearchParams.prototype.toString = function () { return this._pairs.map(function (p) { return encodeURIComponent(p[0]).replace(/%20/g, "+") + "=" + encodeURIComponent(p[1]).replace(/%20/g, "+"); }).join("&"); };
        globalThis.URLSearchParams = globalThis.URLSearchParams || SkyURLSearchParams;

        function SkyURL(raw, base) {
            var resolved = __eclipseSkyNativeResolveURL(String(raw), base === undefined ? "" : String(base));
            if (!resolved) throw new TypeError("Invalid URL");
            this.href = resolved;
            var match = resolved.match(/^([a-zA-Z][a-zA-Z0-9+.-]*:)?\/\/([^\/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/);
            if (!match) throw new TypeError("Invalid URL");
            this.protocol = match[1] || "";
            this.host = match[2] || "";
            var authority = this.host;
            var at = authority.lastIndexOf("@");
            if (at >= 0) authority = authority.substring(at + 1);
            if (authority.charAt(0) === "[") {
                var close = authority.indexOf("]");
                this.hostname = authority.substring(0, close + 1);
                this.port = authority.charAt(close + 1) === ":" ? authority.substring(close + 2) : "";
            } else {
                var colon = authority.lastIndexOf(":");
                this.hostname = colon >= 0 ? authority.substring(0, colon) : authority;
                this.port = colon >= 0 ? authority.substring(colon + 1) : "";
            }
            this.pathname = match[3] || "/";
            this.search = match[4] || "";
            this.hash = match[5] || "";
            this.origin = this.protocol + "//" + this.host;
            this.searchParams = new SkyURLSearchParams(this.search);
        }
        SkyURL.prototype.toString = function () { return this.href; };
        SkyURL.prototype.toJSON = function () { return this.href; };
        globalThis.URL = globalThis.URL || SkyURL;

        function SkyResponse(payload) {
            this.status = Number(payload.status || payload.statusCode || 0);
            this.statusCode = this.status;
            this.ok = payload.ok === true || (this.status >= 200 && this.status < 300);
            this.url = payload.url || "";
            this.headers = new SkyHeaders(payload.headers || {});
            this.body = payload.body || "";
            this._data = this.body;
        }
        SkyResponse.prototype.text = function () { return Promise.resolve(this._data); };
        SkyResponse.prototype.json = function () { var self = this; return Promise.resolve().then(function () { return JSON.parse(self._data); }); };
        SkyResponse.prototype.arrayBuffer = function () { return Promise.resolve(new TextEncoder().encode(this._data).buffer); };

        function _skyHTTP(request) {
            return new Promise(function (resolve, reject) {
                __eclipseSkyNativeHTTP(JSON.stringify(request), function (json) {
                    var payload = _skyParseJSON(json, null);
                    if (!payload) { reject(new Error("Malformed HTTP response")); return; }
                    resolve(payload);
                }, function (message) { reject(new Error(String(message || "Network request failed"))); });
            });
        }
        function _skyHeaderObject(value) {
            if (value instanceof SkyHeaders) value = value.toJSON();
            if (!value || typeof value !== "object" || Array.isArray(value)) return {};
            // Some official packages use Axios-style `{ headers: {...} }` options with
            // http_get. Accept both that form and the SDK's direct header-map form.
            if (value.headers && typeof value.headers === "object" && !Array.isArray(value.headers)) {
                value = value.headers;
                if (value instanceof SkyHeaders) value = value.toJSON();
            }
            var controlled = {
                "accept-encoding": true, "connection": true, "content-length": true,
                "host": true, "keep-alive": true, "range": true, "te": true,
                "trailer": true, "transfer-encoding": true, "upgrade": true
            };
            var result = {};
            Object.keys(value).slice(0, 64).forEach(function (key) {
                var normalized = String(key).toLowerCase();
                if (controlled[normalized] || normalized.indexOf("proxy-") === 0) return;
                result[key] = String(value[key]);
            });
            return result;
        }
        function _skyHybrid(payload) {
            var hybrid = new String(payload.body || "");
            ["code", "status", "statusCode", "ok", "url", "finalUrl", "body", "headers", "error"].forEach(function (key) {
                Object.defineProperty(hybrid, key, { value: payload[key], enumerable: false, configurable: true });
            });
            Object.defineProperty(hybrid, "toJSON", {
                value: function () { return payload; }, enumerable: false, configurable: true
            });
            return hybrid;
        }
        globalThis.http_get = function (url, headers, callback) {
            if (typeof headers === "function") { callback = headers; headers = {}; }
            return _skyHTTP({ method: "GET", url: String(url), headers: _skyHeaderObject(headers) }).then(function (payload) {
                var response = _skyHybrid(payload);
                if (typeof callback === "function") callback(response);
                return response;
            });
        };
        globalThis.http_post = function (url, headers, body, callback) {
            if (typeof headers === "function") { callback = headers; headers = {}; body = null; }
            if (typeof body === "function") { callback = body; body = null; }
            if (headers && typeof headers === "object" && (headers.headers || headers.body !== undefined) && body == null) {
                body = headers.body; headers = headers.headers || {};
            }
            if (body && typeof body === "object") body = JSON.stringify(body);
            return _skyHTTP({ method: "POST", url: String(url), headers: _skyHeaderObject(headers), body: body == null ? null : String(body) }).then(function (payload) {
                var response = _skyHybrid(payload);
                if (typeof callback === "function") callback(response);
                return response;
            });
        };
        globalThis.http_parallel = function (requests) {
            if (!Array.isArray(requests)) return Promise.reject(new TypeError("requests must be an array"));
            if (requests.length > 24) return Promise.reject(new Error("Too many parallel requests"));
            return Promise.all(requests.map(function (request) {
                request = request || {};
                var method = String(request.method || "GET").toUpperCase();
                var body = request.body;
                if (body && typeof body === "object") body = JSON.stringify(body);
                return _skyHTTP({ method: method, url: String(request.url || ""), headers: _skyHeaderObject(request.headers), body: body == null ? null : String(body) }).then(_skyHybrid);
            }));
        };
        globalThis.parallel = globalThis.http_parallel;
        globalThis.fetch = function (url, options) {
            options = options || {};
            if (options.signal && options.signal.aborted) return Promise.reject(new Error("AbortError"));
            var body = options.body;
            if (body && typeof body === "object" && !(body instanceof ArrayBuffer)) body = JSON.stringify(body);
            return _skyHTTP({
                method: String(options.method || "GET").toUpperCase(),
                url: String(url),
                headers: _skyHeaderObject(options.headers),
                body: body == null ? null : String(body)
            }).then(function (payload) { return new SkyResponse(payload); });
        };
        globalThis.Response = globalThis.Response || SkyResponse;

        function AbortSignal() { this.aborted = false; this.reason = undefined; this._listeners = []; }
        AbortSignal.prototype.addEventListener = function (name, callback) { if (name === "abort" && typeof callback === "function") this._listeners.push(callback); };
        function AbortController() { this.signal = new AbortSignal(); }
        AbortController.prototype.abort = function (reason) {
            if (this.signal.aborted) return;
            this.signal.aborted = true; this.signal.reason = reason;
            this.signal._listeners.splice(0).forEach(function (callback) { try { callback(); } catch (_) {} });
        };
        globalThis.AbortController = globalThis.AbortController || AbortController;

        globalThis.setTimeout = function (callback, delay) {
            if (typeof callback !== "function") return -1;
            return __eclipseSkyNativeSetTimer(callback, Number(delay) || 0, false);
        };
        globalThis.clearTimeout = function (id) { __eclipseSkyNativeClearTimer(Number(id)); };
        globalThis.setInterval = function (callback, delay) {
            if (typeof callback !== "function") return -1;
            return __eclipseSkyNativeSetTimer(callback, Number(delay) || 0, true);
        };
        globalThis.clearInterval = globalThis.clearTimeout;

        function _skyStorage(action, key, value, valueJSON) {
            return _skyParseJSON(__eclipseSkyNativeStorage(JSON.stringify({ action: action, key: String(key), value: value, valueJSON: valueJSON })), { ok: false });
        }
        globalThis.getStorage = function (key) { return Promise.resolve(_skyStorage("getStorage", key).value); };
        globalThis.setStorage = function (key, value) { return _skyStorage("setStorage", key, value == null ? null : String(value)).ok; };
        // Keep preference reads synchronous like the public plugin wrapper. `await` remains
        // compatible with a non-Promise value, while ordinary `const value = getPreference()`
        // no longer receives a truthy Promise object.
        globalThis.getPreference = function (key) { return _skyStorage("getPreference", key).value; };
        globalThis.setPreference = function (key, value) {
            var encoded;
            try { encoded = value === undefined ? null : JSON.stringify(value); } catch (_) { return false; }
            return _skyStorage("setPreference", key, null, encoded).ok;
        };
        globalThis.localStorage = {
            getItem: function (key) { return _skyStorage("getStorage", key).value; },
            setItem: function (key, value) { if (!_skyStorage("setStorage", key, String(value)).ok) throw new Error("Storage quota exceeded"); },
            removeItem: function (key) { _skyStorage("setStorage", key, null); },
            clear: function () { /* package-wide destructive clear requires native settings confirmation */ }
        };

        function SkyNode(rawHTML, data) {
            this._html = rawHTML;
            this._data = data || {};
            this._nativeHandle = this._data.nodeHandle || "";
            this._nativeSelector = this._data.nodeSelector || "";
            this.textContent = this._data.text || "";
            this.innerHTML = this._data.html || "";
            this.outerHTML = this._data.outerHTML || "";
            this.tagName = this._data.tagName || "";
        }
        SkyNode.prototype.getAttribute = function (name) { return (this._data.attributes || {})[String(name).toLowerCase()] || null; };
        function _skyNodeReference(handle, selector) {
            return JSON.stringify({ handle: String(handle || ""), selector: String(selector || "") });
        }
        function _skyDecodeNodeReference(value) {
            if (value && typeof value === "object") return value;
            return _skyParseJSON(String(value || ""), {});
        }
        function _skyQueryNode(node, selector) {
            for (var attempt = 0; attempt < 2; attempt++) {
                if (!node._nativeHandle) node._nativeHandle = _skyOpenDocument(node._html);
                if (!node._nativeHandle || !node._nativeSelector) break;
                var raw = __eclipseSkyNativeHTML(JSON.stringify({
                    action: "query",
                    handle: node._nativeHandle,
                    nodeSelector: node._nativeSelector,
                    selector: String(selector || "*")
                }));
                var values = _skyParseJSON(raw, []);
                if (Array.isArray(values)) {
                    return values.map(function (value) { return new SkyNode(node._html, value); });
                }
                if (!values || values.cacheMiss !== true) break;
                node._nativeHandle = "";
            }
            return _skyParseElements(node.innerHTML || node._html, selector);
        }
        function _skyRelatedNode(node, relation) {
            for (var attempt = 0; attempt < 2; attempt++) {
                if (!node._nativeHandle) node._nativeHandle = _skyOpenDocument(node._html);
                if (!node._nativeHandle || !node._nativeSelector) return relation === "children" ? [] : null;
                var raw = __eclipseSkyNativeHTML(JSON.stringify({
                    action: "relative",
                    handle: node._nativeHandle,
                    nodeSelector: node._nativeSelector,
                    relation: relation
                }));
                var value = _skyParseJSON(raw, null);
                if (value && value.cacheMiss === true) {
                    node._nativeHandle = "";
                    continue;
                }
                if (relation === "children") {
                    return Array.isArray(value) ? value.map(function (child) {
                        return new SkyNode(node._html, child);
                    }) : [];
                }
                return value && typeof value === "object" ? new SkyNode(node._html, value) : null;
            }
            return relation === "children" ? [] : null;
        }
        Object.defineProperties(SkyNode.prototype, {
            className: { get: function () { return this.getAttribute("class") || ""; } },
            nodeId: { get: function () { return _skyNodeReference(this._nativeHandle, this._nativeSelector); } },
            parentElement: { get: function () { return _skyRelatedNode(this, "parentElement"); } },
            nextElementSibling: { get: function () { return _skyRelatedNode(this, "nextElementSibling"); } },
            previousElementSibling: { get: function () { return _skyRelatedNode(this, "previousElementSibling"); } },
            children: { get: function () { return _skyRelatedNode(this, "children"); } }
        });
        SkyNode.prototype.querySelectorAll = function (selector) { return _skyQueryNode(this, selector); };
        SkyNode.prototype.querySelector = function (selector) { var all = this.querySelectorAll(selector); return all.length ? all[0] : null; };
        function _skyParseElements(html, selector, attr) {
            var raw = __eclipseSkyNativeHTML(JSON.stringify({ action: "query", html: String(html || ""), selector: String(selector || "*"), attr: attr == null ? null : String(attr) }));
            var values = _skyParseJSON(raw, []);
            return values.map(function (value) { return new SkyNode(String(html || ""), value); });
        }
        function _skyOpenDocument(html) {
            var raw = __eclipseSkyNativeHTML(JSON.stringify({ action: "open", html: String(html || "") }));
            var value = _skyParseJSON(raw, {});
            return value && typeof value.handle === "string" ? value.handle : "";
        }
        function _skyQueryDocument(document, selector, attr) {
            // A handle can be evicted by the bounded native LRU between calls.
            // Reopen once from the document's local immutable HTML on a miss.
            for (var attempt = 0; attempt < 2; attempt++) {
                if (!document._nativeHandle) document._nativeHandle = _skyOpenDocument(document._html);
                if (!document._nativeHandle) break;
                var raw = __eclipseSkyNativeHTML(JSON.stringify({
                    action: "query",
                    handle: document._nativeHandle,
                    selector: String(selector || "*"),
                    attr: attr == null ? null : String(attr)
                }));
                var value = _skyParseJSON(raw, []);
                if (Array.isArray(value)) return value;
                if (!value || value.cacheMiss !== true) break;
                document._nativeHandle = "";
            }
            // Compatibility fallback for a build without a cacheable native DOM.
            var fallback = __eclipseSkyNativeHTML(JSON.stringify({
                action: "query",
                html: String(document._html || ""),
                selector: String(selector || "*"),
                attr: attr == null ? null : String(attr)
            }));
            return _skyParseJSON(fallback, []);
        }
        function SkyDocument(html) {
            SkyNode.call(this, html, { html: html, outerHTML: html, tagName: "#document" });
            this._nativeHandle = _skyOpenDocument(html);
        }
        SkyDocument.prototype = Object.create(SkyNode.prototype);
        SkyDocument.prototype.constructor = SkyDocument;
        SkyDocument.prototype.querySelectorAll = function (selector) {
            var html = this._html;
            return _skyQueryDocument(this, selector, null).map(function (value) {
                return new SkyNode(html, value);
            });
        };
        SkyDocument.prototype.querySelector = function (selector) {
            var all = this.querySelectorAll(selector);
            return all.length ? all[0] : null;
        };
        Object.defineProperty(SkyDocument.prototype, "body", { get: function () { return this.querySelector("body"); } });
        globalThis.parse_html = function (html, selector, attr) {
            var document = new SkyDocument(String(html || ""));
            return Promise.resolve(_skyQueryDocument(document, selector, attr));
        };
        globalThis.parseHtml = function (html) { return Promise.resolve(new SkyDocument(String(html || ""))); };
        globalThis.JSDOM = function JSDOM(html) { this.window = { document: new SkyDocument(String(html || "")) }; };
        globalThis.JSDOM.prototype.waitForInit = function () { return Promise.resolve(this); };

        globalThis.nativeDomBatch = function (nodeId, queries) {
            var reference = _skyDecodeNodeReference(nodeId);
            if (!reference.handle || !Array.isArray(queries)) return [];
            var raw = __eclipseSkyNativeHTML(JSON.stringify({
                action: "batch",
                handle: String(reference.handle),
                nodeSelector: reference.selector ? String(reference.selector) : null,
                queries: queries.slice(0, 64)
            }));
            var values = _skyParseJSON(raw, []);
            return Array.isArray(values) ? values : [];
        };
        globalThis.nativeExtract = function (html, extractionMap) {
            return Promise.resolve().then(function () {
                var document = new SkyDocument(String(html || ""));
                var map = extractionMap && typeof extractionMap === "object" ? extractionMap : {};
                var keys = Object.keys(map).slice(0, 64);
                var queries = keys.map(function (key) {
                    var spec = map[key] && typeof map[key] === "object" ? map[key] : {};
                    return {
                        query: String(spec.query || "*").slice(0, 2048),
                        attr: String(spec.attr || "textContent").slice(0, 256),
                        first: spec.first === true
                    };
                });
                var values = globalThis.nativeDomBatch(document.nodeId, queries);
                var result = {};
                keys.forEach(function (key, index) {
                    result[key] = index < values.length ? values[index] : (queries[index].first ? null : []);
                });
                return result;
            });
        };
        globalThis.nativeRegex = function (text, pattern, group, caseSensitive) {
            text = String(text || "");
            pattern = String(pattern || "");
            if (text.length > 2 * 1024 * 1024 || pattern.length > 4096) return [];
            group = Math.max(0, Math.min(99, Math.floor(Number(group) || 0)));
            try {
                var expression = new RegExp(pattern, caseSensitive === false ? "gi" : "g");
                var result = [];
                var match;
                while (result.length < 10000 && (match = expression.exec(text)) !== null) {
                    if (match[group] !== undefined) result.push(match[group]);
                    if (match[0] === "") expression.lastIndex += 1;
                }
                return result;
            } catch (_) {
                return [];
            }
        };
        function _skyJSONPath(value, parts, index) {
            if (value == null) return null;
            if (index >= parts.length) return value;
            var part = parts[index];
            if (/\[\*\]$/.test(part)) {
                var wildcardKey = part.slice(0, -3);
                var list = wildcardKey ? (value && typeof value === "object" ? value[wildcardKey] : null) : value;
                if (!Array.isArray(list)) return null;
                return list.map(function (item) { return _skyJSONPath(item, parts, index + 1); });
            }
            var indexed = part.match(/^(.+)\[(\d+)\]$/);
            if (indexed) {
                var container = value && typeof value === "object" ? value[indexed[1]] : null;
                var offset = Number(indexed[2]);
                return Array.isArray(container) && offset < container.length
                    ? _skyJSONPath(container[offset], parts, index + 1) : null;
            }
            return value && typeof value === "object" && Object.prototype.hasOwnProperty.call(value, part)
                ? _skyJSONPath(value[part], parts, index + 1) : null;
        }
        globalThis.nativeJsonExtract = function (jsonStr, paths) {
            jsonStr = String(jsonStr || "{}");
            if (jsonStr.length > 2 * 1024 * 1024 || !Array.isArray(paths)) return {};
            try {
                var parsed = JSON.parse(jsonStr);
                var result = {};
                paths.slice(0, 256).forEach(function (path) {
                    var key = String(path);
                    result[key] = _skyJSONPath(parsed, key ? key.split(".") : [], 0);
                });
                return result;
            } catch (_) {
                return {};
            }
        };

        function Actor(params) { Object.assign(this, params || {}); }
        function VoiceActor(params) { Object.assign(this, params || {}); }
        function Trailer(params) { Object.assign(this, params || {}); }
        function NextAiring(params) { Object.assign(this, params || {}); }
        function SubtitleFile(params) { Object.assign(this, params || {}); }
        function MultimediaItem(params) {
            Object.assign(this, { type: "movie", status: "ongoing", playbackPolicy: "none", isAdult: false, streams: [], syncData: {} }, params || {});
        }
        function Episode(params) {
            Object.assign(this, { season: 0, episode: 0, dubStatus: "none", playbackPolicy: "none", streams: [] }, params || {});
        }
        function StreamResult(params) {
            params = params || {};
            Object.assign(this, params);
            this.source = params.source || params.name || "Auto";
            this.headers = params.headers || {};
            this.subtitles = params.subtitles || [];
        }
        globalThis.Actor = Actor;
        globalThis.VoiceActor = VoiceActor;
        globalThis.Trailer = Trailer;
        globalThis.NextAiring = NextAiring;
        globalThis.SubtitleFile = SubtitleFile;
        globalThis.Subtitle = SubtitleFile;
        globalThis.MultimediaItem = MultimediaItem;
        globalThis.Episode = Episode;
        globalThis.StreamResult = StreamResult;
        globalThis.ExtractorLink = StreamResult;
        globalThis.CloudStream = {
            getLanguage: function () { return "en"; },
            getRegion: function () { return "US"; }
        };

        function _skyCryptoAsync(payload) {
            return new Promise(function (resolve, reject) {
                __eclipseSkyNativeCrypto(JSON.stringify(payload), resolve, reject);
            });
        }
        function _skyCryptoSync(payload) {
            var value = __eclipseSkyNativeCryptoSync(JSON.stringify(payload));
            if (!value) throw new Error("Cryptographic operation failed");
            return value;
        }
        var cryptoObject = globalThis.crypto && typeof globalThis.crypto === "object" ? globalThis.crypto : {};
        cryptoObject.getRandomValues = function (array) {
            var bytes = _skyBase64ToBytes(__eclipseSkyNativeRandom(array.byteLength));
            new Uint8Array(array.buffer, array.byteOffset || 0, array.byteLength).set(bytes);
            return array;
        };
        cryptoObject.decryptAES = function (data, key, iv, options) {
            return _skyCryptoAsync({ operation: "aes", data: String(data), key: String(key), iv: String(iv), mode: options && options.mode || "cbc" })
                .then(function (base64) { return new TextDecoder().decode(_skyBase64ToBytes(base64)); });
        };
        cryptoObject.pbkdf2 = function (password, salt, iterations, keyLength) {
            return _skyCryptoAsync({ operation: "pbkdf2", password: String(password), salt: String(salt), iterations: iterations || 10000, keyLength: keyLength || 32 });
        };
        cryptoObject.subtle = {
            digest: function (algorithm, data) {
                var name = typeof algorithm === "string" ? algorithm : algorithm && algorithm.name;
                if (String(name).toUpperCase().replace("-", "") !== "SHA256") return Promise.reject(new Error("Unsupported digest"));
                return _skyCryptoAsync({ operation: "sha256", data: _skyBinaryToBase64(_skyToBytes(data)) })
                    .then(function (value) { return _skyBase64ToBytes(value).buffer; });
            },
            importKey: function (format, keyData, algorithm, extractable, usages) {
                return Promise.resolve({ format: format, data: _skyBinaryToBase64(_skyToBytes(keyData)), algorithm: algorithm || {}, usages: usages || [], extractable: !!extractable });
            },
            deriveBits: function (algorithm, baseKey, length) {
                if (!algorithm || String(algorithm.name).toUpperCase() !== "PBKDF2") return Promise.reject(new Error("Unsupported derivation"));
                var password = new TextDecoder().decode(_skyBase64ToBytes(baseKey.data));
                return _skyCryptoAsync({ operation: "pbkdf2", password: password, salt: _skyBinaryToBase64(_skyToBytes(algorithm.salt)), iterations: algorithm.iterations || 10000, keyLength: Math.ceil(Number(length) / 8) })
                    .then(function (value) { return _skyBase64ToBytes(value).buffer; });
            },
            decrypt: function (algorithm, key, data) {
                var mode = String(algorithm && algorithm.name || "AES-CBC").toUpperCase() === "AES-GCM" ? "gcm" : "cbc";
                return _skyCryptoAsync({ operation: "aes", data: _skyBinaryToBase64(_skyToBytes(data)), key: key.data, iv: _skyBinaryToBase64(_skyToBytes(algorithm.iv)), mode: mode })
                    .then(function (value) { return _skyBase64ToBytes(value).buffer; });
            }
        };
        globalThis.crypto = cryptoObject;
        globalThis.nativeMd5 = function (input) {
            var result = _skyCryptoSync({ operation: "md5", data: _skyBinaryToBase64(new TextEncoder().encode(String(input))) });
            return Array.prototype.map.call(_skyBase64ToBytes(result), function (b) { return ("0" + b.toString(16)).slice(-2); }).join("");
        };
        globalThis.nativeSha256 = function (input) {
            var result = _skyCryptoSync({ operation: "sha256", data: _skyBinaryToBase64(new TextEncoder().encode(String(input))) });
            return Array.prototype.map.call(_skyBase64ToBytes(result), function (b) { return ("0" + b.toString(16)).slice(-2); }).join("");
        };
        globalThis.sha256 = globalThis.nativeSha256;

        function WordArray(base64) { this.base64 = base64; }
        WordArray.prototype.toString = function (encoder) {
            if (encoder === CryptoJS.enc.Base64) return this.base64;
            var bytes = _skyBase64ToBytes(this.base64);
            if (encoder === CryptoJS.enc.Utf8) return new TextDecoder().decode(bytes);
            return Array.prototype.map.call(bytes, function (b) { return ("0" + b.toString(16)).slice(-2); }).join("");
        };
        globalThis.CryptoJS = globalThis.CryptoJS || {
            enc: {
                Utf8: { parse: function (value) { return new WordArray(_skyBinaryToBase64(new TextEncoder().encode(String(value)))); } },
                Base64: { parse: function (value) { return new WordArray(String(value)); }, stringify: function (word) { return word.base64; } },
                Hex: { stringify: function (word) { return word.toString(); } }
            },
            SHA256: function (value) {
                var bytes = value instanceof WordArray ? _skyBase64ToBytes(value.base64) : new TextEncoder().encode(String(value));
                return new WordArray(_skyCryptoSync({ operation: "sha256", data: _skyBinaryToBase64(bytes) }));
            },
            PBKDF2: function (password, salt, options) {
                options = options || {};
                var salt64 = salt instanceof WordArray ? salt.base64 : _skyBinaryToBase64(new TextEncoder().encode(String(salt)));
                return new WordArray(_skyCryptoSync({ operation: "pbkdf2", password: String(password), salt: salt64, iterations: options.iterations || 10000, keyLength: (options.keySize || 8) * 4 }));
            },
            AES: {
                decrypt: function (ciphertext, key, options) {
                    options = options || {};
                    var encrypted64 = ciphertext instanceof WordArray ? ciphertext.base64 : String(ciphertext);
                    var key64 = key instanceof WordArray ? key.base64 : String(key);
                    var iv64 = options.iv instanceof WordArray ? options.iv.base64 : String(options.iv || "");
                    return new WordArray(_skyCryptoSync({ operation: "aes", data: encrypted64, key: key64, iv: iv64, mode: "cbc" }));
                }
            }
        };

        globalThis.solveCaptcha = function () {
            return Promise.reject(new Error("CAPTCHA_UNSUPPORTED"));
        };

        // The official Anichi package still calls the legacy extractor registry for a small
        // set of ordinary VOD hosts. This local implementation adapts the GPLv3 reference
        // extractors from https://github.com/akashdh11/skystream-tools. Keep that compatibility
        // local and auditable: every extractor below is static bootstrap code, all parsing is
        // bounded, and unsupported hosts fail closed. It never downloads or evaluates code.
        var _skyExtractorMaximumResults = 48;
        function _skyExtractorResponseBody(response) {
            if (!response) return "";
            var value = response.body !== undefined ? response.body : response;
            value = String(value || "");
            return value.length <= 2 * 1024 * 1024 ? value : "";
        }
        function _skyExtractorSucceeded(response) {
            var status = Number(response && (response.status || response.statusCode || response.code) || 0);
            return status >= 200 && status < 300;
        }
        function _skyExtractorDecode(value) {
            return String(value || "")
                .replace(/&amp;/gi, "&")
                .replace(/&quot;/gi, '"')
                .replace(/&#39;|&apos;/gi, "'")
                .replace(/\\u0026/gi, "&")
                .replace(/\\\//g, "/")
                .replace(/\\"/g, '"')
                .trim();
        }
        function _skyExtractorURL(value, base) {
            var candidate = _skyExtractorDecode(value);
            if (!candidate || candidate.length > 16384) return "";
            try {
                var resolved = new URL(candidate, base || undefined).toString();
                return /^https?:\/\//i.test(resolved) && resolved.length <= 16384 ? resolved : "";
            } catch (_) {
                return "";
            }
        }
        function _skyExtractorOrigin(value) {
            try { return new URL(value).origin + "/"; } catch (_) { return ""; }
        }
        function _skyExtractorQuality(value) {
            var text = String(value || "");
            if (/(?:^|\D)(?:2160)(?:p|\D|$)|(?:^|\W)(?:4k|uhd)(?:\W|$)/i.test(text)) return 2160;
            var match = text.match(/(?:^|\D)(1440|1080|720|480|360|240|144)(?:p|\D|$)/i);
            return match ? Number(match[1]) : undefined;
        }
        function _skyExtractorResult(name, url, type, referer, quality, source) {
            var resolved = _skyExtractorURL(url, referer);
            if (!resolved) return null;
            var headers = referer ? { Referer: referer } : {};
            var result = new StreamResult({
                name: String(name || "Auto").slice(0, 256),
                source: String(source || name || "Auto").slice(0, 256),
                url: resolved,
                type: type === "m3u8" ? "m3u8" : "video",
                headers: headers
            });
            if (referer) result.referer = referer;
            if (quality !== undefined && isFinite(quality)) result.quality = Number(quality);
            return result;
        }
        function _skyExtractorDedupe(values) {
            var result = [], seen = Object.create(null);
            (Array.isArray(values) ? values : []).slice(0, _skyExtractorMaximumResults).forEach(function (value) {
                if (!value || typeof value !== "object") return;
                var url = _skyExtractorURL(value.url || value.file || value.link, value.referer);
                if (!url || seen[url]) return;
                seen[url] = true;
                value.url = url;
                result.push(value);
            });
            return result;
        }
        function _skyExtractorBrandLabel(hostname) {
            var labels = String(hostname || "").toLowerCase().split(".").filter(Boolean);
            if (labels.length < 2) return labels[0] || "";
            var index = labels.length - 2;
            if (labels[labels.length - 1].length === 2 && /^(?:co|com|net|org)$/.test(labels[index]) && index > 0) {
                index -= 1;
            }
            return labels[index] || "";
        }
        function _skyExtractorKind(url) {
            var label;
            try { label = _skyExtractorBrandLabel(new URL(url).hostname); } catch (_) { return ""; }
            if (label.indexOf("hubcloud") >= 0) return "hubcloud";
            if (label.indexOf("filemoon") >= 0) return "filemoon";
            if (label.indexOf("streamtape") >= 0) return "streamtape";
            if (label.indexOf("mixdrop") >= 0) return "mixdrop";
            if (label.indexOf("dood") >= 0) return "dood";
            if (/^voe[a-z0-9-]*$/.test(label)) return "voe";
            return "";
        }
        function _skyExtractorRandomToken(length) {
            var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
            var bytes = new Uint8Array(Math.max(1, Math.min(64, Number(length) || 1)));
            crypto.getRandomValues(bytes);
            var value = "";
            for (var index = 0; index < bytes.length; index++) value += alphabet.charAt(bytes[index] % alphabet.length);
            return value;
        }
        async function _skyExtractDood(url) {
            var page = await http_get(url);
            if (!_skyExtractorSucceeded(page)) return [];
            var match = _skyExtractorResponseBody(page).match(/\/pass_md5\/[^'"\s<]*/i);
            if (!match) return [];
            var passURL = _skyExtractorURL(match[0], url);
            if (!passURL) return [];
            var pass = await http_get(passURL, { Referer: url });
            if (!_skyExtractorSucceeded(pass)) return [];
            var prefix = _skyExtractorResponseBody(pass).trim();
            var token = (passURL.match(/[?&]token=([^&]+)/i) || [])[1] || "";
            var separator = prefix.indexOf("?") >= 0 ? "&" : "?";
            var mediaURL = _skyExtractorURL(
                prefix + _skyExtractorRandomToken(10) + separator + "token=" + encodeURIComponent(token) + "&expiry=" + Date.now(),
                passURL
            );
            var result = _skyExtractorResult("DoodStream", mediaURL, "video", url);
            return result ? [result] : [];
        }
        async function _skyExtractorM3U8(masterURL, referer, source) {
            var direct = _skyExtractorResult(source, masterURL, "m3u8", referer, undefined, source);
            if (!direct) return [];
            var response = await http_get(masterURL, referer ? { Referer: referer } : {});
            if (!_skyExtractorSucceeded(response)) return [direct];
            var body = _skyExtractorResponseBody(response);
            if (!/^\s*#EXTM3U/im.test(body)) return [direct];
            var lines = body.split(/\r?\n/).slice(0, 10000);
            var results = [], pendingQuality;
            for (var index = 0; index < lines.length && results.length < 24; index++) {
                var line = String(lines[index] || "").trim();
                if (/^#EXT-X-STREAM-INF:/i.test(line)) {
                    var resolution = line.match(/RESOLUTION=\d+x(\d+)/i);
                    var name = line.match(/(?:NAME|VIDEO)="([^"]+)"/i);
                    pendingQuality = resolution ? Number(resolution[1]) : _skyExtractorQuality(name && name[1]);
                    continue;
                }
                if (pendingQuality !== undefined && line && line.charAt(0) !== "#") {
                    var variant = _skyExtractorURL(line, masterURL);
                    var result = _skyExtractorResult(source, variant, "m3u8", referer, pendingQuality, source);
                    if (result) results.push(result);
                    pendingQuality = undefined;
                }
            }
            return results.length ? _skyExtractorDedupe(results) : [direct];
        }
        async function _skyExtractFilemoon(url) {
            var page = await http_get(url);
            if (!_skyExtractorSucceeded(page)) return [];
            var body = _skyExtractorResponseBody(page);
            if (/p\s*,\s*a\s*,\s*c\s*,\s*k\s*,\s*e\s*,\s*[dr]/i.test(body)) body = getAndUnpack(body);
            var match = body.match(/(?:file|hls)\s*:\s*["']([^"']+\.m3u8[^"']*)["']/i)
                || body.match(/(?:file|src)\s*:\s*["']([^"']+)["']/i);
            var masterURL = match ? _skyExtractorURL(match[1], url) : "";
            return masterURL ? _skyExtractorM3U8(masterURL, _skyExtractorOrigin(url), "Filemoon") : [];
        }
        async function _skyExtractHubCloud(url, referer) {
            var page = await http_get(url, referer ? { Referer: referer } : {});
            if (!_skyExtractorSucceeded(page)) return [];
            var body = _skyExtractorResponseBody(page), finalURL = url;
            var buttons = await parse_html(body, "a#download", "href");
            var nextValue = buttons && buttons[0] && buttons[0].attr;
            if (!nextValue) {
                var fallback = body.match(/<a\b[^>]*\bid=["']download["'][^>]*\bhref=["']([^"']+)["']/i);
                nextValue = fallback && fallback[1];
            }
            var nextURL = _skyExtractorURL(nextValue, url);
            if (nextURL) {
                var generated = await http_get(nextURL, { Referer: url });
                if (_skyExtractorSucceeded(generated)) {
                    body = _skyExtractorResponseBody(generated);
                    finalURL = nextURL;
                }
            }
            var links = await parse_html(body, "a.btn", "href");
            var results = [], playbackReferer = _skyExtractorOrigin(url);
            for (var index = 0; index < Math.min((links || []).length, _skyExtractorMaximumResults); index++) {
                var link = links[index] || {}, raw = String(link.attr || "").trim();
                if (!raw || raw.charAt(0) === "/" || /(?:winexch|tinyurl)/i.test(raw)) continue;
                var mediaURL = _skyExtractorURL(raw, finalURL);
                if (!mediaURL) continue;
                var label = String(link.text || "HubCloud Server").replace(/Download/ig, "").replace(/[\[\]]/g, " ").replace(/\s+/g, " ").trim();
                var result = _skyExtractorResult("HubCloud", mediaURL, "video", playbackReferer, _skyExtractorQuality(label), label || "HubCloud");
                if (result) results.push(result);
            }
            return _skyExtractorDedupe(results);
        }
        async function _skyExtractMixDrop(url, referer) {
            var page = await http_get(url, referer ? { Referer: referer } : {});
            if (!_skyExtractorSucceeded(page)) return [];
            var body = getAndUnpack(_skyExtractorResponseBody(page));
            var match = body.match(/(?:\b(?:MDCore\.)?wurl|["']wurl["'])\s*(?:=|:)\s*["']([^"']+)["']/i);
            var mediaURL = match ? _skyExtractorURL(match[1], url) : "";
            var result = _skyExtractorResult("MixDrop", mediaURL, "video", _skyExtractorOrigin(url));
            return result ? [result] : [];
        }
        function _skyExtractorStaticConcat(expression) {
            expression = String(expression || "");
            if (!expression || expression.length > 4096) return "";
            var pattern = /('((?:\\.|[^'\\])*)'|"((?:\\.|[^"\\])*)")((?:\s*\)*\s*\.substring\(\s*\d{1,4}\s*\))*)/g;
            var output = "", cursor = 0, match, tokenCount = 0;
            while ((match = pattern.exec(expression)) !== null && tokenCount < 16) {
                if (!/^[\s+()]*$/.test(expression.substring(cursor, match.index))) return "";
                var value = _skyExtractorDecode(match[2] !== undefined ? match[2] : match[3]);
                var substringPattern = /substring\(\s*(\d{1,4})\s*\)/g, substringMatch;
                while ((substringMatch = substringPattern.exec(match[4] || "")) !== null) {
                    value = value.substring(Number(substringMatch[1]));
                }
                output += value;
                if (output.length > 16384) return "";
                cursor = pattern.lastIndex;
                tokenCount += 1;
            }
            if (!tokenCount || !/^[\s+()]*$/.test(expression.substring(cursor))) return "";
            return output;
        }
        async function _skyExtractStreamTape(url) {
            var page = await http_get(url);
            if (!_skyExtractorSucceeded(page)) return [];
            var body = _skyExtractorResponseBody(page), mediaValue = "";
            var nodes = await parse_html(body, "#norobotlink", "innerHTML");
            if (nodes && nodes[0]) mediaValue = nodes[0].attr || nodes[0].html || nodes[0].text || "";
            if (!/get_video/i.test(mediaValue)) {
                var assignment = body.match(/norobotlink[\s\S]{0,512}?\.innerHTML\s*=\s*([\s\S]{1,4096}?);/i)
                    || body.match(/getElementById\(\s*["']norobotlink["']\s*\)[\s\S]{0,128}?=\s*([\s\S]{1,4096}?);/i);
                if (assignment) mediaValue = _skyExtractorStaticConcat(assignment[1]);
            }
            if (!mediaValue) {
                var direct = body.match(/(?:https?:)?\/\/[^'"\s<]+\/get_video\?[^'"\s<]+/i);
                mediaValue = direct && direct[0];
            }
            var mediaURL = _skyExtractorURL(mediaValue, url);
            if (!mediaURL || !/\/get_video\?/i.test(mediaURL) || !/[?&]id=[^&]+/i.test(mediaURL)) return [];
            var result = _skyExtractorResult("StreamTape", mediaURL, "video", _skyExtractorOrigin(url));
            return result ? [result] : [];
        }
        async function _skyExtractVoe(url) {
            var page = await http_get(url);
            if (!_skyExtractorSucceeded(page)) return [];
            var body = _skyExtractorResponseBody(page);
            var match = body.match(/["']hls["']\s*:\s*["']([^"']+)["']/i)
                || body.match(/["'](?:file|source)["']\s*:\s*["']([^"']+\.m3u8[^"']*)["']/i)
                || body.match(/https?:\\?\/\\?\/[^'"\s<]+\.m3u8[^'"\s<]*/i);
            var mediaURL = match ? _skyExtractorURL(match[1] || match[0], url) : "";
            var result = _skyExtractorResult("Voe", mediaURL, "m3u8", _skyExtractorOrigin(url));
            return result ? [result] : [];
        }
        async function _skyRunExtractor(url, referer) {
            url = _skyExtractorURL(url);
            if (!url) return [];
            switch (_skyExtractorKind(url)) {
            case "dood": return _skyExtractDood(url);
            case "filemoon": return _skyExtractFilemoon(url);
            case "hubcloud": return _skyExtractHubCloud(url, referer);
            case "mixdrop": return _skyExtractMixDrop(url, referer);
            case "streamtape": return _skyExtractStreamTape(url);
            case "voe": return _skyExtractVoe(url);
            default: return [];
            }
        }
        globalThis.loadExtractor = function (url, referer, callback) {
            if (typeof referer === "function") { callback = referer; referer = undefined; }
            if (typeof callback !== "function") callback = null;
            var safeReferer = referer == null ? undefined : _skyExtractorURL(referer);
            return Promise.resolve()
                .then(function () { return _skyRunExtractor(url, safeReferer); })
                .then(_skyExtractorDedupe, function () { return []; })
                .then(function (results) {
                    if (callback) results.forEach(function (result) {
                        try { callback(result); } catch (_) {}
                    });
                    return results;
                });
        };

        globalThis.getAndUnpack = function (source) {
            source = String(source || "");
            var maximumUnpackedLength = 2 * 1024 * 1024;
            if (source.length > maximumUnpackedLength) return source;
            try {
                if (!/eval\s*\(\s*function\s*\(\s*p\s*,\s*a\s*,\s*c\s*,\s*k\s*,\s*e\s*,\s*(?:r|d)\s*\)/.test(source)) {
                    return source;
                }
                // Match the terminal P.A.C.K.E.R invocation rather than its formatting-sensitive
                // function prefix. The official runtime accepts whitespace around every argument.
                var match = source.match(/\}\s*\(\s*'((?:\\.|[^'\\])*)'\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*'((?:\\.|[^'\\])*)'\s*\.split\s*\(\s*'\|'\s*\)/);
                var quote = "'";
                if (!match) {
                    match = source.match(/\}\s*\(\s*"((?:\\.|[^"\\])*)"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*"((?:\\.|[^"\\])*)"\s*\.split\s*\(\s*"\|"\s*\)/);
                    quote = '"';
                }
                if (!match) return source;

                function unescapeLiteral(value, delimiter) {
                    var escapedQuote = delimiter === "'" ? /\\'/g : /\\"/g;
                    return value.replace(escapedQuote, delimiter).replace(/\\\\/g, "\\");
                }
                var payload = unescapeLiteral(match[1], quote);
                var radix = parseInt(match[2], 10);
                var count = parseInt(match[3], 10);
                var words = unescapeLiteral(match[4], quote).split("|");
                if (!isFinite(radix) || radix < 2 || radix > 95 ||
                    !isFinite(count) || count < 0 || count > 100000 || words.length !== count) {
                    return source;
                }

                var alphabet62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
                var alphabet95 = "";
                for (var code = 32; code <= 126; code++) alphabet95 += String.fromCharCode(code);
                var alphabet = radix <= 36
                    ? "0123456789abcdefghijklmnopqrstuvwxyz".substring(0, radix)
                    : (radix <= 62 ? alphabet62.substring(0, radix) : alphabet95.substring(0, radix));
                function unbase(value) {
                    var result = 0;
                    for (var index = 0; index < value.length; index++) {
                        var character = value.charAt(index);
                        if (radix <= 36) character = character.toLowerCase();
                        var digit = alphabet.indexOf(character);
                        if (digit < 0) return -1;
                        result = result * radix + digit;
                        // Only symbol-table indexes are useful. This also avoids numeric overflow
                        // on maliciously long identifiers.
                        if (result >= count) return result;
                    }
                    return result;
                }

                // Decode in one pass. Replacing once per symbol is quadratic for large tables and
                // made heavily packed providers noticeably slower than their native counterparts.
                var tokenPattern = /\b[a-zA-Z0-9_]+\b/g;
                var output = "", lastIndex = 0, tokenMatch;
                while ((tokenMatch = tokenPattern.exec(payload)) !== null) {
                    var symbolIndex = unbase(tokenMatch[0]);
                    var replacement = symbolIndex >= 0 && symbolIndex < words.length && words[symbolIndex]
                        ? words[symbolIndex]
                        : tokenMatch[0];
                    var literal = payload.substring(lastIndex, tokenMatch.index);
                    if (output.length + literal.length + replacement.length > maximumUnpackedLength) return source;
                    output += literal + replacement;
                    lastIndex = tokenMatch.index + tokenMatch[0].length;
                }
                var remainder = payload.substring(lastIndex);
                if (output.length + remainder.length > maximumUnpackedLength) return source;
                return output + remainder;
            } catch (_) { return source; }
        };

        var _skySettled = Object.create(null);
        function _skyErrorText(error) {
            var text = error && error.message ? String(error.message) : String(error || "Plugin operation failed");
            if (text.indexOf("CAPTCHA_UNSUPPORTED") >= 0) return "CAPTCHA_UNSUPPORTED";
            // Result errors can contain signed URLs or response bodies. Keep a
            // fixed message at the native boundary instead of surfacing them.
            return "Plugin operation failed.";
        }
        function _skyUnwrap(value) {
            if (value && typeof value === "object" && Object.prototype.hasOwnProperty.call(value, "success")) {
                if (value.success === false) throw new Error(value.error || value.message || "Plugin operation failed");
                return value.data;
            }
            return value;
        }
        function _skySerialize(raw, operation, maxResults, maxEpisodes, maxStreams, maxProviders, maxBytes) {
            var value = _skyUnwrap(raw);
            var nodes = 0, estimated = 0, streamsRemaining = maxStreams;
            var maximumNodes = Math.min(100000, Math.max(20000, maxEpisodes * 20));
            var seen = [];
            function visit(input, key, depth, top) {
                nodes += 1;
                if (nodes > maximumNodes || depth > 12) throw new Error("RESULT_TOO_LARGE");
                if (input === null || input === undefined) return input === undefined ? null : input;
                var kind = typeof input;
                if (kind === "string") {
                    // Never truncate plugin values: doing so can turn a valid generated HLS or
                    // signed URL into different, corrupted data. Reject only when the complete
                    // value exceeds the bounded result envelope.
                    estimated += input.length * 2 + 8;
                    if (estimated > maxBytes) throw new Error("RESULT_TOO_LARGE");
                    return input;
                }
                if (kind === "number") return isFinite(input) ? input : null;
                if (kind === "boolean") return input;
                if (kind === "bigint") return visit(String(input), key, depth, top);
                if (kind === "function" || kind === "symbol") return null;
                if (seen.indexOf(input) >= 0) return null;
                seen.push(input);
                if (Array.isArray(input) || (typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView && ArrayBuffer.isView(input))) {
                    var limit = maxResults;
                    if ((top && operation === "loadStreams") || key === "streams") {
                        limit = streamsRemaining;
                        streamsRemaining = Math.max(0, streamsRemaining - Math.min(input.length, limit));
                    } else if (top && operation === "getProviders") limit = maxProviders;
                    else if (top && operation === "search") limit = maxResults;
                    else if (key === "episodes") limit = maxEpisodes;
                    else if (key === "recommendations") limit = maxResults;
                    else if (key === "subtitles") limit = Math.min(256, maxResults);
                    else limit = Math.min(maxResults, 512);
                    var output = [];
                    for (var i = 0; i < Math.min(input.length, limit); i++) output.push(visit(input[i], String(i), depth + 1, false));
                    seen.pop();
                    return output;
                }
                var result = {};
                var keys = [];
                try {
                    for (var candidateKey in input) {
                        if (!Object.prototype.hasOwnProperty.call(input, candidateKey)) continue;
                        keys.push(candidateKey);
                        if (keys.length >= 128) break;
                    }
                } catch (_) { keys = []; }
                for (var k = 0; k < keys.length; k++) {
                    var name = String(keys[k]).substring(0, 128);
                    try { result[name] = visit(input[keys[k]], name, depth + 1, false); } catch (error) {
                        if (error && error.message === "RESULT_TOO_LARGE") throw error;
                    }
                }
                seen.pop();
                return result;
            }
            var bounded = visit(value, "", 0, true);
            var json = JSON.stringify(bounded);
            if (json.length * 2 > maxBytes) throw new Error("RESULT_TOO_LARGE");
            return json;
        }
        function _skySettle(id, raw, error, operation, maxResults, maxEpisodes, maxStreams, maxProviders, maxBytes) {
            if (_skySettled[id]) return;
            _skySettled[id] = true;
            if (error) {
                __eclipseSkyNativeComplete(id, "", _skyErrorText(error));
                return;
            }
            try {
                __eclipseSkyNativeComplete(id, _skySerialize(raw, operation, maxResults, maxEpisodes, maxStreams, maxProviders, maxBytes), "");
            } catch (serializationError) {
                var message = serializationError && serializationError.message === "RESULT_TOO_LARGE"
                    ? "Plugin result exceeded the Eclipse boundary."
                    : _skyErrorText(serializationError);
                __eclipseSkyNativeComplete(id, "", message);
            }
        }
        globalThis.__eclipseSkyDrop = function (id) { delete _skySettled[id]; };
        globalThis.__eclipseSkyInvoke = function (operation, args, id, maxResults, maxEpisodes, maxStreams, maxProviders, maxBytes) {
            var fn = globalThis.__eclipseSkyExports && globalThis.__eclipseSkyExports[operation];
            if (typeof fn !== "function") {
                _skySettle(id, null, new Error("Missing export"), operation, maxResults, maxEpisodes, maxStreams, maxProviders, maxBytes);
                return;
            }
            var callback = function (value) { _skySettle(id, value, null, operation, maxResults, maxEpisodes, maxStreams, maxProviders, maxBytes); };
            try {
                var returned = fn.apply(undefined, (args || []).concat([callback]));
                if (returned && typeof returned.then === "function") {
                    returned.then(function (value) {
                        _skySettle(id, value, null, operation, maxResults, maxEpisodes, maxStreams, maxProviders, maxBytes);
                    }, function (error) {
                        _skySettle(id, null, error, operation, maxResults, maxEpisodes, maxStreams, maxProviders, maxBytes);
                    });
                } else if (returned !== undefined) {
                    _skySettle(id, returned, null, operation, maxResults, maxEpisodes, maxStreams, maxProviders, maxBytes);
                }
            } catch (error) {
                _skySettle(id, null, error, operation, maxResults, maxEpisodes, maxStreams, maxProviders, maxBytes);
            }
        };
    })();
    """#
}

// MARK: - Early normalization

private enum SkyStreamRuntimeMapper {
    private typealias JSONObject = [String: Any]

    static func searchRecords(from data: Data, maximum: Int) throws -> [SkyStreamSearchRecord] {
        guard let values = try jsonObject(data) as? [Any] else {
            if try jsonObject(data) is NSNull { return [] }
            throw SkyStreamRuntimeError.malformedResult
        }
        var result: [SkyStreamSearchRecord] = []
        var seen: Set<String> = []
        for value in values.prefix(maximum) {
            guard let object = value as? JSONObject,
                  let record = searchRecord(object),
                  seen.insert(record.id).inserted else { continue }
            result.append(record)
        }
        return result
    }

    static func loadedItem(
        from data: Data,
        fallbackURL: String,
        maximumEpisodes: Int,
        maximumRecommendations: Int
    ) throws -> SkyStreamLoadedItemRecord? {
        guard let object = try jsonObject(data) as? JSONObject else {
            throw SkyStreamRuntimeError.malformedResult
        }
        return loadedItem(
            object,
            fallbackURL: fallbackURL,
            maximumEpisodes: maximumEpisodes,
            maximumRecommendations: maximumRecommendations
        )
    }

    static func streamRecords(from data: Data, maximum: Int) throws -> [SkyStreamStreamRecord] {
        guard let values = try jsonObject(data) as? [Any] else {
            if try jsonObject(data) is NSNull { return [] }
            throw SkyStreamRuntimeError.malformedResult
        }
        return streams(values, maximum: maximum)
    }

    static func providers(from data: Data, maximum: Int) throws -> [SkyStreamPluginProvider] {
        guard let values = try jsonObject(data) as? [Any] else {
            if try jsonObject(data) is NSNull { return [] }
            throw SkyStreamRuntimeError.malformedResult
        }
        var output: [SkyStreamPluginProvider] = []
        var seen: Set<String> = []
        for raw in values.prefix(maximum) {
            guard let object = raw as? JSONObject,
                  let id = string(object, ["id", "providerId", "providerID"], maximum: 128),
                  validProviderID(id),
                  seen.insert(id.lowercased()).inserted else { continue }
            let name = string(object, ["name", "title"], maximum: 256) ?? id
            output.append(
                SkyStreamPluginProvider(
                    id: id,
                    name: name,
                    baseURL: string(object, ["baseUrl", "baseURL", "url"], maximum: 16_384),
                    iconURL: string(object, ["iconUrl", "iconURL", "icon"], maximum: 16_384),
                    languages: stringArray(object["languages"] ?? object["language"], maximum: 64),
                    categories: stringArray(object["categories"] ?? object["types"], maximum: 64),
                    additionalFields: additionalFields(
                        object,
                        excluding: ["id", "providerId", "providerID", "name", "title", "baseUrl", "baseURL", "url", "iconUrl", "iconURL", "icon", "languages", "language", "categories", "types"]
                    )
                )
            )
        }
        return output
    }

    private static func jsonObject(_ data: Data) throws -> Any {
        guard data.count <= SkyStreamRuntimeLimits.default.maximumSerializedResultBytes else {
            throw SkyStreamRuntimeError.resultTooLarge
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw SkyStreamRuntimeError.malformedResult
        }
    }

    private static func searchRecord(_ object: JSONObject) -> SkyStreamSearchRecord? {
        guard let title = displayString(object, ["title", "name"], maximum: 1_024),
              let url = string(object, ["url", "href", "link"], maximum: 16_384),
              !title.isEmpty, !url.isEmpty else { return nil }
        return SkyStreamSearchRecord(
            title: title,
            url: url,
            posterURL: string(object, ["posterUrl", "posterURL", "poster"], maximum: 16_384),
            contentType: contentType(object["type"] ?? object["contentType"]),
            year: integer(object["year"]),
            score: double(object["score"] ?? object["rating"]),
            durationMinutes: integer(object["duration"] ?? object["runtime"]),
            status: showStatus(object["status"] ?? object["showStatus"]),
            description: string(object, ["description", "synopsis", "plot"], maximum: 256 * 1_024),
            providerName: string(object, ["provider", "providerName", "source"], maximum: 512),
            alternateTitles: alternateTitles(object),
            headers: sanitizedHeaders(object["headers"], purpose: .pluginRequest),
            syncData: stringMap(object["syncData"], maximum: 64),
            streams: streams(object["streams"] as? [Any] ?? [], maximum: 1_200),
            additionalFields: additionalFields(
                object,
                excluding: itemKnownKeys.union(["episodes", "bannerUrl", "backgroundPosterUrl", "logoUrl", "tags", "contentRating", "playbackPolicy", "vpnStatus", "isAdult", "cast", "actors", "trailers", "nextAiring", "recommendations"])
            )
        )
    }

    private static func loadedItem(
        _ object: JSONObject,
        fallbackURL: String,
        maximumEpisodes: Int,
        maximumRecommendations: Int
    ) -> SkyStreamLoadedItemRecord? {
        guard let title = displayString(object, ["title", "name"], maximum: 1_024), !title.isEmpty else {
            return nil
        }
        let url = string(object, ["url", "href", "link"], maximum: 16_384) ?? fallbackURL
        guard !url.isEmpty else { return nil }

        var episodeOutput: [SkyStreamEpisodeRecord] = []
        var seenEpisodes: Set<String> = []
        for raw in (object["episodes"] as? [Any] ?? []).prefix(maximumEpisodes) {
            guard let episodeObject = raw as? JSONObject,
                  let episode = episodeRecord(episodeObject),
                  seenEpisodes.insert(episode.id).inserted else { continue }
            episodeOutput.append(episode)
        }

        var recommendations: [SkyStreamSearchRecord] = []
        var seenRecommendations: Set<String> = []
        for raw in (object["recommendations"] as? [Any] ?? []).prefix(maximumRecommendations) {
            guard let recommendationObject = raw as? JSONObject,
                  let recommendation = searchRecord(recommendationObject),
                  seenRecommendations.insert(recommendation.id).inserted else { continue }
            recommendations.append(recommendation)
        }

        return SkyStreamLoadedItemRecord(
            title: title,
            url: url,
            posterURL: string(object, ["posterUrl", "posterURL", "poster"], maximum: 16_384),
            bannerURL: string(object, ["bannerUrl", "bannerURL", "backgroundPosterUrl", "backdrop"], maximum: 16_384),
            logoURL: string(object, ["logoUrl", "logoURL"], maximum: 16_384),
            contentType: contentType(object["type"] ?? object["contentType"]),
            year: integer(object["year"]),
            score: double(object["score"] ?? object["rating"]),
            durationMinutes: integer(object["duration"] ?? object["runtime"]),
            status: showStatus(object["status"] ?? object["showStatus"]),
            description: string(object, ["description", "synopsis", "plot"], maximum: 256 * 1_024),
            tags: stringArray(object["tags"] ?? object["genres"], maximum: 128) ?? [],
            contentRating: string(object, ["contentRating", "ageRating"], maximum: 64),
            playbackPolicy: string(object, ["playbackPolicy", "vpnStatus", "policy"], maximum: 512),
            isAdult: boolean(object["isAdult"] ?? object["adult"]),
            providerName: string(object, ["provider", "providerName", "source"], maximum: 512),
            alternateTitles: alternateTitles(object),
            headers: sanitizedHeaders(object["headers"], purpose: .pluginRequest),
            syncData: stringMap(object["syncData"], maximum: 64),
            cast: actors(object["cast"] ?? object["actors"]),
            trailers: trailers(object["trailers"]),
            nextAiring: nextAiring(object["nextAiring"]),
            recommendations: recommendations,
            episodes: episodeOutput,
            streams: streams(object["streams"] as? [Any] ?? [], maximum: 1_200),
            additionalFields: additionalFields(
                object,
                excluding: itemKnownKeys.union(["episodes", "bannerUrl", "bannerURL", "backgroundPosterUrl", "backdrop", "logoUrl", "logoURL", "tags", "genres", "contentRating", "ageRating", "playbackPolicy", "vpnStatus", "policy", "isAdult", "adult", "cast", "actors", "trailers", "nextAiring", "recommendations"])
            )
        )
    }

    private static func episodeRecord(_ object: JSONObject) -> SkyStreamEpisodeRecord? {
        let url = string(object, ["url", "href", "link"], maximum: 16_384) ?? ""
        let embeddedStreams = streams(object["streams"] as? [Any] ?? [], maximum: 1_200)
        guard !url.isEmpty || !embeddedStreams.isEmpty else { return nil }
        let name = displayString(object, ["name", "title", "label"], maximum: 1_024) ?? "Episode"
        let explicitDubStatus = dubStatus(object["dubStatus"] ?? object["dub"])
        return SkyStreamEpisodeRecord(
            name: name,
            url: url,
            season: integer(object["season"] ?? object["seasonNumber"]),
            episode: integer(object["episode"] ?? object["episodeNumber"] ?? object["number"]),
            description: string(object, ["description", "synopsis"], maximum: 256 * 1_024),
            posterURL: string(object, ["posterUrl", "posterURL", "poster"], maximum: 16_384),
            headers: sanitizedHeaders(object["headers"], purpose: .pluginRequest),
            rating: double(object["rating"] ?? object["score"]),
            runtimeMinutes: integer(object["runtime"] ?? object["duration"]),
            airDate: string(object, ["airDate", "aired", "date"], maximum: 128),
            dubStatus: resolvedDubStatus(explicit: explicitDubStatus, episodeName: name),
            playbackPolicy: string(object, ["playbackPolicy", "vpnStatus", "policy"], maximum: 512),
            streams: embeddedStreams,
            additionalFields: additionalFields(
                object,
                excluding: ["url", "href", "link", "name", "title", "label", "season", "seasonNumber", "episode", "episodeNumber", "number", "description", "synopsis", "posterUrl", "posterURL", "poster", "headers", "rating", "score", "runtime", "duration", "airDate", "aired", "date", "dubStatus", "dub", "playbackPolicy", "vpnStatus", "policy", "streams"]
            )
        )
    }

    private static func streams(_ values: [Any], maximum: Int) -> [SkyStreamStreamRecord] {
        var result: [SkyStreamStreamRecord] = []
        var seen: Set<String> = []
        for raw in values.prefix(maximum) {
            guard let object = raw as? JSONObject,
                  let record = streamRecord(object),
                  seen.insert(record.id).inserted else { continue }
            result.append(record)
        }
        return result
    }

    private static func streamRecord(_ object: JSONObject) -> SkyStreamStreamRecord? {
        guard let url = string(object, ["url", "file", "link"], maximum: 1 * 1_024 * 1_024),
              !url.isEmpty else { return nil }
        let rawQuality = object["quality"]
        let label = stringValue(rawQuality, maximum: 128)
            ?? string(object, ["qualityLabel", "resolution"], maximum: 128)
        let parsedQuality = integer(rawQuality) ?? label.flatMap { value in
            value.range(of: #"\d{3,4}"#, options: .regularExpression).flatMap {
                Int(value[$0])
            }
        }
        var subtitles: [SkyStreamSubtitleRecord] = []
        var seenSubtitles: Set<String> = []
        for raw in (object["subtitles"] as? [Any] ?? []).prefix(256) {
            guard let subtitleObject = raw as? JSONObject,
                  let subtitle = subtitleRecord(subtitleObject),
                  seenSubtitles.insert(subtitle.id).inserted else { continue }
            subtitles.append(subtitle)
        }
        return SkyStreamStreamRecord(
            url: url,
            source: string(object, ["source", "server", "provider"], maximum: 512),
            name: string(object, ["name", "label", "title"], maximum: 512),
            qualityLabel: label,
            quality: parsedQuality,
            mediaType: string(object, ["type", "mediaType", "format"], maximum: 128),
            referer: string(object, ["referer", "referrer"], maximum: 16_384),
            headers: sanitizedHeaders(object["headers"], purpose: .stream),
            subtitles: subtitles,
            drmKeyID: string(object, ["drmKid", "drmKeyId", "drmKeyID", "kid"], maximum: 8 * 1_024),
            drmKey: string(object, ["drmKey", "key"], maximum: 8 * 1_024),
            licenseURL: string(object, ["licenseUrl", "licenseURL", "license"], maximum: 16_384),
            additionalFields: additionalFields(
                object,
                excluding: ["url", "file", "link", "source", "server", "provider", "name", "label", "title", "quality", "qualityLabel", "resolution", "type", "mediaType", "format", "referer", "referrer", "headers", "subtitles", "drmKid", "drmKeyId", "drmKeyID", "kid", "drmKey", "key", "licenseUrl", "licenseURL", "license"]
            )
        )
    }

    private static func subtitleRecord(_ object: JSONObject) -> SkyStreamSubtitleRecord? {
        guard let url = string(object, ["url", "file", "src"], maximum: 16_384), !url.isEmpty else {
            return nil
        }
        return SkyStreamSubtitleRecord(
            url: url,
            label: string(object, ["label", "name", "title"], maximum: 512),
            language: string(object, ["lang", "language", "languageCode"], maximum: 64),
            headers: sanitizedHeaders(object["headers"], purpose: .subtitle),
            additionalFields: additionalFields(
                object,
                excluding: ["url", "file", "src", "label", "name", "title", "lang", "language", "languageCode", "headers"]
            )
        )
    }

    private static func actors(_ value: Any?) -> [SkyStreamActorRecord] {
        guard let values = value as? [Any] else { return [] }
        return values.prefix(256).compactMap { raw in
            guard let object = raw as? JSONObject,
                  let name = string(object, ["name", "title"], maximum: 512), !name.isEmpty else {
                return nil
            }
            var voice: SkyStreamVoiceActorRecord?
            if let voiceObject = object["voiceActor"] as? JSONObject,
               let voiceName = string(voiceObject, ["name", "title"], maximum: 512) {
                voice = SkyStreamVoiceActorRecord(
                    name: voiceName,
                    imageURL: string(voiceObject, ["image", "imageUrl", "imageURL"], maximum: 16_384),
                    role: string(voiceObject, ["role", "character"], maximum: 512),
                    additionalFields: additionalFields(voiceObject, excluding: ["name", "title", "image", "imageUrl", "imageURL", "role", "character"])
                )
            }
            return SkyStreamActorRecord(
                name: name,
                imageURL: string(object, ["image", "imageUrl", "imageURL"], maximum: 16_384),
                role: string(object, ["role", "character"], maximum: 512),
                voiceActor: voice,
                additionalFields: additionalFields(object, excluding: ["name", "title", "image", "imageUrl", "imageURL", "role", "character", "voiceActor"])
            )
        }
    }

    private static func trailers(_ value: Any?) -> [SkyStreamTrailerRecord] {
        guard let values = value as? [Any] else { return [] }
        return values.prefix(64).compactMap { raw in
            guard let object = raw as? JSONObject,
                  let url = string(object, ["url", "file", "link"], maximum: 16_384), !url.isEmpty else {
                return nil
            }
            return SkyStreamTrailerRecord(
                url: url,
                headers: sanitizedHeaders(object["headers"], purpose: .stream),
                additionalFields: additionalFields(object, excluding: ["url", "file", "link", "headers"])
            )
        }
    }

    private static func nextAiring(_ value: Any?) -> SkyStreamNextAiringRecord? {
        guard let object = value as? JSONObject,
              let episode = integer(object["episode"] ?? object["episodeNumber"]),
              let unixTime = int64(object["unixTime"] ?? object["timestamp"]) else { return nil }
        return SkyStreamNextAiringRecord(
            episode: episode,
            season: integer(object["season"] ?? object["seasonNumber"]),
            unixTime: unixTime,
            additionalFields: additionalFields(object, excluding: ["episode", "episodeNumber", "season", "seasonNumber", "unixTime", "timestamp"])
        )
    }

    private static let itemKnownKeys: Set<String> = [
        "title", "name", "url", "href", "link", "posterUrl", "posterURL", "poster",
        "type", "contentType", "year", "score", "rating", "duration", "runtime",
        "status", "showStatus", "description", "synopsis", "plot", "provider",
        "providerName", "source", "alternateTitles", "synonyms", "aliases", "headers",
        "syncData", "streams"
    ]

    private static func alternateTitles(_ object: JSONObject) -> [String] {
        var values: [String] = []
        for key in ["alternateTitles", "synonyms", "aliases", "otherTitles"] {
            values.append(contentsOf: stringArray(object[key], maximum: 64) ?? [])
        }
        var seen: Set<String> = []
        return values.map(htmlUnescapedDisplayValue)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(64)
            .map { $0 }
    }

    private static func contentType(_ value: Any?) -> SkyStreamContentType? {
        guard let raw = stringValue(value, maximum: 64)?.lowercased() else { return nil }
        switch raw {
        case "movie", "movies", "film": return .movie
        case "series", "tv", "tvseries", "tvshow", "show": return .series
        case "anime": return .anime
        case "livestream", "live", "livetv", "iptv": return .livestream
        default: return SkyStreamContentType(rawValue: raw)
        }
    }

    private static func showStatus(_ value: Any?) -> SkyStreamShowStatus? {
        guard let raw = stringValue(value, maximum: 64)?.lowercased() else { return nil }
        switch raw {
        case "completed", "complete", "finished": return .completed
        case "ongoing", "airing", "continuing": return .ongoing
        case "upcoming", "planned", "not_yet_aired": return .upcoming
        default: return SkyStreamShowStatus(rawValue: raw)
        }
    }

    private static func dubStatus(_ value: Any?) -> SkyStreamDubStatus? {
        guard let raw = stringValue(value, maximum: 64)?.lowercased() else { return nil }
        if raw.contains("dub") { return .dubbed }
        if raw.contains("sub") { return .subbed }
        return SkyStreamDubStatus(rawValue: raw)
    }

    private static func resolvedDubStatus(
        explicit: SkyStreamDubStatus?,
        episodeName: String
    ) -> SkyStreamDubStatus? {
        // The official model treats its constructor's default `.none` like an absent value and
        // falls back to common episode-name markers. Preserve forward-compatible explicit values,
        // while still handling Episode({ name: "... (Dub)" }) correctly.
        if let explicit, explicit != .none { return explicit }
        let markers = episodeName.lowercased().components(
            separatedBy: CharacterSet.alphanumerics.inverted
        )
        if markers.contains("dub") || markers.contains("dubbed") { return .dubbed }
        if markers.contains("sub") || markers.contains("subbed") { return .subbed }
        return explicit
    }

    private static func sanitizedHeaders(
        _ value: Any?,
        purpose: SkyStreamHeaderPurpose
    ) -> [String: String] {
        guard let object = value as? JSONObject else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object.prefix(64) {
            guard !SkyStreamRuntimeHeaderCompatibility.isControlled(key) else { continue }
            let text: String?
            if let string = value as? String { text = string }
            else if let number = value as? NSNumber { text = number.stringValue }
            else { text = nil }
            guard let text,
                  let sanitized = try? SkyStreamHeaderSanitizer.sanitize(
                      [key: text],
                      purpose: purpose
                  ).values,
                  let pair = sanitized.first,
                  result[pair.key] == nil else { continue }
            var candidate = result
            candidate[pair.key] = pair.value
            guard let bounded = try? SkyStreamHeaderSanitizer.sanitize(
                candidate,
                purpose: purpose
            ).values else { continue }
            result = bounded
        }
        return result
    }

    private static func stringMap(_ value: Any?, maximum: Int) -> [String: String] {
        guard let object = value as? JSONObject else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object.prefix(maximum) where key.utf8.count <= 128 {
            if let text = stringValue(value, maximum: 8 * 1_024) { result[key] = text }
        }
        return result
    }

    private static func string(
        _ object: JSONObject,
        _ keys: [String],
        maximum: Int
    ) -> String? {
        for key in keys {
            if let value = stringValue(object[key], maximum: maximum) { return value }
        }
        return nil
    }

    private static func displayString(
        _ object: JSONObject,
        _ keys: [String],
        maximum: Int
    ) -> String? {
        string(object, keys, maximum: maximum).map(htmlUnescapedDisplayValue)
    }

    /// The documented models HTML-unescape display text. Keep this deliberately small and
    /// deterministic: named XML/HTML essentials plus bounded numeric entities cover provider
    /// titles without treating arbitrary entity names as executable or network-resolved data.
    private static func htmlUnescapedDisplayValue(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let named: [String: UnicodeScalar] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "
        ]
        var output = String.UnicodeScalarView()
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "&" else {
                output.append(scalars[index])
                index += 1
                continue
            }
            let searchEnd = min(scalars.count, index + 14)
            guard let semicolon = (index + 1..<searchEnd).first(where: { scalars[$0] == ";" }) else {
                output.append(scalars[index])
                index += 1
                continue
            }
            let entity = String(String.UnicodeScalarView(scalars[(index + 1)..<semicolon]))
            let decoded: UnicodeScalar?
            if let known = named[entity.lowercased()] {
                decoded = known
            } else if entity.lowercased().hasPrefix("#x") {
                decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init)
            } else if entity.hasPrefix("#") {
                decoded = UInt32(entity.dropFirst(), radix: 10).flatMap(UnicodeScalar.init)
            } else {
                decoded = nil
            }
            guard let decoded,
                  decoded.value >= 32 || decoded == "\t" || decoded == "\n" else {
                output.append(scalars[index])
                index += 1
                continue
            }
            output.append(decoded)
            index = semicolon + 1
        }
        return String(output)
    }

    private static func stringValue(_ value: Any?, maximum: Int) -> String? {
        let result: String
        if let value = value as? String { result = value }
        else if let value = value as? NSNumber { result = value.stringValue }
        else { return nil }
        guard result.utf8.count <= maximum else { return nil }
        guard !result.unicodeScalars.contains(where: CharacterSet.controlCharacters.subtracting(CharacterSet.whitespacesAndNewlines).contains) else {
            return nil
        }
        return result
    }

    private static func stringArray(_ value: Any?, maximum: Int) -> [String]? {
        if let text = stringValue(value, maximum: 1_024) { return [text] }
        guard let values = value as? [Any] else { return nil }
        return values.prefix(maximum).compactMap { stringValue($0, maximum: 1_024) }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        if let string = value as? String, let result = Double(string), result.isFinite { return result }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func validProviderID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return !value.isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func additionalFields(
        _ object: JSONObject,
        excluding keys: Set<String>
    ) -> [String: SkyStreamJSONValue] {
        var output: [String: SkyStreamJSONValue] = [:]
        let secretTokens = ["authorization", "cookie", "password", "passwd", "token", "secret", "apikey", "api_key"]
        for key in object.keys.sorted() where output.count < 32 && !keys.contains(key) {
            let lowered = key.lowercased()
            guard key.utf8.count <= 128,
                  !secretTokens.contains(where: lowered.contains),
                  let value = jsonValue(object[key], depth: 0) else { continue }
            output[key] = value
        }
        return output
    }

    private static func jsonValue(_ value: Any?, depth: Int) -> SkyStreamJSONValue? {
        guard depth <= 4 else { return nil }
        switch value {
        case nil, is NSNull:
            return .null
        case let value as Bool:
            return .boolean(value)
        case let value as NSNumber:
            let doubleValue = value.doubleValue
            guard doubleValue.isFinite else { return nil }
            if floor(doubleValue) == doubleValue,
               doubleValue >= Double(Int64.min), doubleValue <= Double(Int64.max) {
                return .integer(value.int64Value)
            }
            return .number(doubleValue)
        case let value as String:
            return .string(String(value.prefix(64 * 1_024)))
        case let values as [Any]:
            return .array(values.prefix(64).compactMap { jsonValue($0, depth: depth + 1) })
        case let object as JSONObject:
            var mapped: [String: SkyStreamJSONValue] = [:]
            for key in object.keys.sorted().prefix(64) where key.utf8.count <= 128 {
                if let child = jsonValue(object[key], depth: depth + 1) { mapped[key] = child }
            }
            return .object(mapped)
        default:
            return nil
        }
    }
}
