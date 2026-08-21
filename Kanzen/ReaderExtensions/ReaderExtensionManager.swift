// Copyright 2026 Eclipse contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import CryptoKit
import Foundation
import SwiftUI

struct ReaderExtensionManagerMutationScope: Equatable, Sendable {
    let scopeID: String
    let authenticationNamespace: String
    let authenticationNamespaceGeneration: UInt64
    let allowsKidsModeAdministrativeBypass: Bool

    init(
        scopeID: String,
        authenticationNamespace: String,
        authenticationNamespaceGeneration: UInt64,
        allowsKidsModeAdministrativeBypass: Bool = false
    ) {
        self.scopeID = scopeID
        self.authenticationNamespace = authenticationNamespace
        self.authenticationNamespaceGeneration = authenticationNamespaceGeneration
        self.allowsKidsModeAdministrativeBypass = allowsKidsModeAdministrativeBypass
    }
}

/// Immutable security material for one visible sign-in sheet. The manager
/// revalidates it before and after every proxied WebKit request, while the
/// bound HTTP client independently fences Keychain use against source/profile
/// authentication revocation.
struct ReaderExtensionSignInSession: @unchecked Sendable {
    let sourceID: ReaderExtensionSourceID
    let sourceName: String
    let startURL: URL
    let approvedDomains: Set<String>
    let baseDomain: String?
    let mutationScope: ReaderExtensionManagerMutationScope
    let securityRevision: SecurityRevision
    let network: ReaderExtensionSecureHTTPClient
    let authenticationStore: ReaderExtensionKeychainStore

    struct SecurityRevision: Hashable, Sendable {
        let repositoryURL: URL
        let baseURL: URL
        let apiURL: URL?
        let sourceCodeURL: URL?
        let version: String
        let implementation: ReaderExtensionImplementation
        let license: ReaderExtensionLicense
        let codeProvenanceFingerprint: String
        let activeContentDigest: String?
        let declaredDomains: Set<String>
        let runtimeCapabilities: Set<ReaderExtensionCapability>
        let secretPreferenceKeys: Set<String>

        init(source: ReaderExtensionInstalledSource) {
            repositoryURL = source.repositoryURL
            baseURL = source.baseURL
            apiURL = source.apiURL
            sourceCodeURL = source.sourceCodeURL
            version = source.version
            implementation = source.implementation
            license = source.license
            codeProvenanceFingerprint = source.codeProvenanceFingerprint
            activeContentDigest = source.activeContentDigest
            declaredDomains = source.declaredDomains
            runtimeCapabilities = source.runtimeCapabilities
            secretPreferenceKeys = source.secretPreferenceKeys
        }
    }
}

enum ReaderExtensionManagerMutationScopePolicy {
    static func validate(
        _ captured: ReaderExtensionManagerMutationScope,
        current: ReaderExtensionManagerMutationScope
    ) throws {
        guard captured == current else {
            throw ReaderExtensionError.runtimeUnavailable
        }
    }
}

enum ReaderExtensionAdministrativeAdmissionPolicy {
    static func validate(isKidsModeActive: Bool) throws {
        guard !isKidsModeActive else { throw ReaderExtensionError.unsupportedSource }
    }
}

struct ReaderExtensionEphemeralPageRequest {
    let sourceID: ReaderExtensionSourceID
    let sourceRevision: String
    let scopeID: String
    let key: String
    let url: URL
    let headers: [String: String]

    var retainedByteCount: Int {
        128 + sourceID.rawValue.utf8.count + sourceRevision.utf8.count
            + scopeID.utf8.count + key.utf8.count + url.absoluteString.utf8.count
            + headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
    }
}

/// Process-local, byte-aware LRU for opaque page requests. A new chapter is
/// inserted atomically without invalidating still-visible prior chapters;
/// oldest handles leave only under per-source/global pressure or an explicit
/// source/scope invalidation.
final class ReaderExtensionPageRequestRegistry {
    static let maximumGlobalCount = 1_024
    static let maximumPerSourceCount = 512
    static let maximumGlobalBytes = 8 * 1_024 * 1_024
    static let maximumPerSourceBytes = 2 * 1_024 * 1_024

    private var entries: [UUID: ReaderExtensionEphemeralPageRequest] = [:]
    private var order: [UUID] = []
    private(set) var retainedByteCount = 0

    var count: Int { entries.count }

    func contains(_ requestID: UUID) -> Bool { entries[requestID] != nil }

    func insert(
        _ replacements: [(UUID, ReaderExtensionEphemeralPageRequest)],
        for sourceID: ReaderExtensionSourceID
    ) throws {
        guard replacements.count <= Self.maximumPerSourceCount,
              Set(replacements.map { $0.0 }).count == replacements.count,
              replacements.allSatisfy({ $0.1.sourceID == sourceID }) else {
            throw ReaderExtensionError.contentTooLarge
        }
        let replacementBytes = replacements.reduce(0) { $0 + $1.1.retainedByteCount }
        guard replacementBytes <= Self.maximumPerSourceBytes,
              replacementBytes <= Self.maximumGlobalBytes else {
            throw ReaderExtensionError.contentTooLarge
        }

        var candidateEntries = entries
        var candidateOrder = order
        for (id, request) in replacements {
            guard candidateEntries[id] == nil else { throw ReaderExtensionError.resultInvalid("duplicate page request handle") }
            candidateEntries[id] = request
            candidateOrder.append(id)
        }
        var candidateBytes = candidateEntries.values.reduce(0) { $0 + $1.retainedByteCount }
        func sourceUsage() -> (count: Int, bytes: Int) {
            candidateEntries.values.reduce(into: (count: 0, bytes: 0)) { result, request in
                guard request.sourceID == sourceID else { return }
                result.count += 1
                result.bytes += request.retainedByteCount
            }
        }
        var usage = sourceUsage()
        while usage.count > Self.maximumPerSourceCount || usage.bytes > Self.maximumPerSourceBytes {
            guard let oldestIndex = candidateOrder.firstIndex(where: {
                candidateEntries[$0]?.sourceID == sourceID
            }) else { throw ReaderExtensionError.contentTooLarge }
            let oldest = candidateOrder.remove(at: oldestIndex)
            if let discarded = candidateEntries.removeValue(forKey: oldest) {
                candidateBytes -= discarded.retainedByteCount
            }
            usage = sourceUsage()
        }
        while candidateEntries.count > Self.maximumGlobalCount || candidateBytes > Self.maximumGlobalBytes {
            guard let oldest = candidateOrder.first else { throw ReaderExtensionError.contentTooLarge }
            candidateOrder.removeFirst()
            if let discarded = candidateEntries.removeValue(forKey: oldest) {
                candidateBytes -= discarded.retainedByteCount
            }
        }
        let replacementIDs = Set(replacements.map { $0.0 })
        guard replacementIDs.isSubset(of: Set(candidateEntries.keys)) else {
            throw ReaderExtensionError.contentTooLarge
        }
        entries = candidateEntries
        order = candidateOrder
        retainedByteCount = candidateBytes
    }

    func material(for requestID: UUID) -> ReaderExtensionEphemeralPageRequest? {
        guard let material = entries[requestID] else { return nil }
        order.removeAll { $0 == requestID }
        order.append(requestID)
        return material
    }

    func consume(_ requestID: UUID) {
        guard let removed = entries.removeValue(forKey: requestID) else { return }
        retainedByteCount = max(0, retainedByteCount - removed.retainedByteCount)
        order.removeAll { $0 == requestID }
    }

    func remove(sourceID: ReaderExtensionSourceID) {
        let removed = entries.compactMap { $0.value.sourceID == sourceID ? $0.key : nil }
        removed.forEach(consume)
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        retainedByteCount = 0
    }
}

/// Content is activated before its metadata transaction so a published digest
/// can never point at missing bytes. Keep those brief, not-yet-durable
/// references explicit: a failed install may clean up its own orphan without
/// racing a different source that is concurrently awaiting its commit.
struct ReaderExtensionPendingInstallContent {
    private var digestsBySource: [ReaderExtensionSourceID: String] = [:]

    var retainedDigests: Set<String> {
        Set(digestsBySource.values)
    }

    mutating func register(digest: String, sourceID: ReaderExtensionSourceID) {
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { return }
        digestsBySource[sourceID] = digest.lowercased()
    }

    @discardableResult
    mutating func release(sourceID: ReaderExtensionSourceID) -> String? {
        digestsBySource.removeValue(forKey: sourceID)
    }
}

/// Repository records are durable metadata, while their decoded source
/// catalogs are deliberately process-only. A recent `lastRefreshedAt` value
/// therefore cannot prove that the current process has a catalog to display.
struct ReaderExtensionRepositoryCatalogHydrationPolicy {
    static func needsHydration(
        repository: ReaderExtensionRepositoryRecord?,
        hasLoadedCatalog: Bool
    ) -> Bool {
        guard let repository, repository.isEnabled else { return false }
        return !hasLoadedCatalog
    }
}

@MainActor
final class ReaderExtensionManager: ObservableObject {
    static let shared = ReaderExtensionManager()

    @Published private(set) var repositories: [ReaderExtensionRepositoryRecord] = []
    @Published private(set) var installedSources: [ReaderExtensionInstalledSource] = []
    @Published private(set) var catalogSources: [ReaderExtensionCatalogSource] = []
    @Published private(set) var showMatureSources = false
    @Published private(set) var autoUpdateSources = true
    @Published private(set) var lastAutoUpdate: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isUpdatingSources = false
    @Published private(set) var installingSourceIDs: Set<ReaderExtensionSourceID> = []
    @Published private(set) var blockedSourceIDs: Set<ReaderExtensionSourceID> = []

    var installedSourceCount: Int { isAvailable ? installedSources.count : 0 }
    var enabledSources: [ReaderExtensionInstalledSource] {
        guard isAvailable else { return [] }
        return installedSources.filter { $0.enabled && $0.isRunnable && isMaturityAllowed($0.maturity) }
            .sorted { $0.sortIndex < $1.sortIndex }
    }
    var availableSources: [ReaderExtensionCatalogSource] {
        guard isAvailable else { return [] }
        return catalogSources.filter { source in
            !blockedSourceIDs.contains(source.id) && !installedSources.contains(where: { $0.id == source.id })
                && isMaturityAllowed(source.maturity)
        }
    }

    private static let blockedSourcesKey = "readerExtensions.blockedSources.v1"
    private var isAvailable: Bool
    private var store: UserDefaults { ProfileSettingsStore.services }
    private var authenticationCleanupStore: UserDefaults { .standard }
    private var keychainNamespace: String {
        ProfileManager.shared.activeProfileID.uuidString
    }
    private var network: ReaderExtensionSecureHTTPClient { ReaderExtensionSecureHTTPClient(keychainNamespace: keychainNamespace) }
    private func authenticatedNetwork(for sourceID: ReaderExtensionSourceID) -> ReaderExtensionSecureHTTPClient {
        ReaderExtensionSecureHTTPClient(
            keychainNamespace: keychainNamespace,
            authenticationSourceID: sourceID
        )
    }
    private let contentStore: ReaderExtensionContentStore?
    private var repositoryCatalogs: [String: ReaderExtensionRepositoryCatalog] = [:]
    private var hydratingRepositoryIDs: Set<String> = []
    private var pendingInstallContent = ReaderExtensionPendingInstallContent()
    private struct ApprovedDomainRollback {
        let store: ReaderExtensionKeychainStore
        let previousDomains: Set<String>
    }
    private struct ResourceHeaderCacheEntry {
        let revision: String
        let result: Result<[String: String], ReaderExtensionError>
    }
    private struct ResourceHeaderLoad {
        let revision: String
        let task: Task<Result<[String: String], ReaderExtensionError>, Never>
    }
    private let pageRequests = ReaderExtensionPageRequestRegistry()
    /// Header values may contain source credentials, so this cache is
    /// deliberately process-only, source/profile scoped, and never logged.
    private var resourceHeaderCache: [ReaderExtensionSourceID: ResourceHeaderCacheEntry] = [:]
    private var resourceHeaderLoads: [ReaderExtensionSourceID: ResourceHeaderLoad] = [:]
    private var resourceHeaderSourceGenerations: [ReaderExtensionSourceID: UInt64] = [:]
    private var resourceHeaderGlobalGeneration: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()
    private var loadedScopeID: String
    private var loadedKeychainNamespace: String
    private var canStripLegacyPreferenceMetadata = false
    private var codeReacquisitionTask: Task<Void, Never>?
    private var codeReacquisitionGeneration = 0

    private init() {
        let migrationSucceeded = ReaderExtensionAidokuMigration.runAllKnownProfilesIfNeeded()
        let metadataReadable = migrationSucceeded
            && ReaderExtensionPersistence.metadataIsReadable(
                in: ProfileSettingsStore.services,
                preferenceStore: ProfileSettingsStore.active
            )
            && ReaderExtensionPersistence.pendingAuthenticationCleanupIsReadable(in: .standard)
            && Self.blockedMetadataIsReadable(in: ProfileSettingsStore.services)
        let preparedContentStore = metadataReadable ? (try? ReaderExtensionContentStore()) : nil
        let runtimeAvailable = migrationSucceeded && metadataReadable && preparedContentStore != nil
        isAvailable = runtimeAvailable
        loadedScopeID = runtimeAvailable ? Self.currentScopeID : ""
        loadedKeychainNamespace = ProfileManager.shared.activeProfileID.uuidString
        contentStore = preparedContentStore
        guard runtimeAvailable else {
            return
        }
        do {
            _ = try reloadPersistedStateAfterRestore()
        } catch {
            repositories = []
            installedSources = []
            isAvailable = false
            return
        }
        // Cleanup is intentionally retried before providers become usable. A
        // transient Keychain failure leaves its durable tombstone in place;
        // the per-source gates below retry and refuse use/reinstall until the
        // requested deletion can be verified.
        try? retryPendingAuthenticationCleanup()
        contentStore?.clearStaging()
        removeUnreferencedContent()
        observeScopeChanges()
    }

    var isAvailableForTesting: Bool { isAvailable }

    private func requireAvailability() throws {
        guard isAvailable else { throw ReaderExtensionError.runtimeUnavailable }
    }

    private func requireAdministrativeAdmission() throws {
        try requireAvailability()
        try ReaderExtensionAdministrativeAdmissionPolicy.validate(
            isKidsModeActive: ProfileManager.shared.isKidsModeActive
        )
    }

    private func mutationScope(
        allowsKidsModeAdministrativeBypass: Bool = false
    ) -> ReaderExtensionManagerMutationScope {
        let namespace = keychainNamespace
        return ReaderExtensionManagerMutationScope(
            scopeID: Self.currentScopeID,
            authenticationNamespace: namespace,
            authenticationNamespaceGeneration: ReaderExtensionAuthenticationGenerationRegistry
                .namespaceGeneration(namespace),
            allowsKidsModeAdministrativeBypass: allowsKidsModeAdministrativeBypass
        )
    }

    private func captureMutationScope(
        allowsKidsModeAdministrativeBypass: Bool = false
    ) throws -> ReaderExtensionManagerMutationScope {
        if allowsKidsModeAdministrativeBypass { try requireAvailability() }
        else { try requireAdministrativeAdmission() }
        return mutationScope(
            allowsKidsModeAdministrativeBypass: allowsKidsModeAdministrativeBypass
        )
    }

    private func validateMutationScope(
        _ captured: ReaderExtensionManagerMutationScope
    ) throws {
        try requireAvailability()
        if !captured.allowsKidsModeAdministrativeBypass {
            try ReaderExtensionAdministrativeAdmissionPolicy.validate(
                isKidsModeActive: ProfileManager.shared.isKidsModeActive
            )
        }
        try ReaderExtensionManagerMutationScopePolicy.validate(
            captured,
            current: mutationScope(
                allowsKidsModeAdministrativeBypass: captured.allowsKidsModeAdministrativeBypass
            )
        )
    }

    private static func blockedMetadataIsReadable(in store: UserDefaults) -> Bool {
        guard let data = store.data(forKey: blockedSourcesKey) else { return true }
        return (try? JSONDecoder().decode(Set<ReaderExtensionSourceID>.self, from: data)) != nil
    }

    func repository(id: String) -> ReaderExtensionRepositoryRecord? {
        guard isAvailable else { return nil }
        return repositories.first { $0.id == id }
    }

    func sources(inRepository id: String) -> [ReaderExtensionCatalogSource] {
        guard isAvailable else { return [] }
        return catalogSources.filter { $0.repositoryID == id }
    }

    func source(for id: ReaderExtensionSourceID) -> ReaderExtensionInstalledSource? {
        guard isAvailable else { return nil }
        return installedSources.first { $0.id == id }
    }

    func catalogSource(for id: ReaderExtensionSourceID) -> ReaderExtensionCatalogSource? {
        guard isAvailable else { return nil }
        return catalogSources.first { $0.id == id }
    }

    /// Decoded catalogs are not stored in UserDefaults, so hydrate one on
    /// demand after a cold launch even when its durable refresh timestamp is
    /// still recent. Concurrent view tasks coalesce behind the first load; the
    /// catalog publication wakes every observer when that load completes.
    func hydrateRepositoryCatalogIfNeeded(id: String) async throws {
        try requireAdministrativeAdmission()
        guard ReaderExtensionRepositoryCatalogHydrationPolicy.needsHydration(
            repository: repository(id: id),
            hasLoadedCatalog: repositoryCatalogs[id] != nil
        ) else { return }
        guard hydratingRepositoryIDs.insert(id).inserted else { return }
        defer { hydratingRepositoryIDs.remove(id) }
        try await refreshRepository(id: id)
    }

    func addRepository(_ url: URL, allowUnknownLicense: Bool = false) async throws {
        let diagnosticRecord = ReaderExtensionRepositoryRecord(indexURL: url)
        let diagnosticContext = ReaderExtensionDiagnosticContext(
            repositoryID: diagnosticRecord.id,
            name: diagnosticRecord.name
        )
        let startedAt = Date()
        ReaderExtensionDiagnostics.record(
            context: diagnosticContext,
            operation: "add-repository",
            event: "started",
            type: ReaderExtensionDiagnostics.repositoryType
        )
        do {
            try requireAdministrativeAdmission()
            let scope = try captureMutationScope()
        // The pinned transport performs public-address resolution immediately
        // before connecting. Keep the MainActor admission check syntactic so
        // repository navigation never blocks on synchronous DNS.
        try ReaderExtensionSecurityPolicy.validateRepositoryURLSyntax(url)
        var record = ReaderExtensionRepositoryRecord(indexURL: url)
        guard !repositories.contains(where: { $0.id == record.id }) else {
            try await refreshRepository(id: record.id)
            ReaderExtensionDiagnostics.record(
                context: diagnosticContext,
                operation: "add-repository",
                event: "refreshed-existing",
                type: ReaderExtensionDiagnostics.repositoryType,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt),
                count: sources(inRepository: record.id).count
            )
            return
        }
        guard repositories.count < ReaderExtensionPersistence.maximumRepositoryCount else {
            throw ReaderExtensionError.contentTooLarge
        }
        let loaded = try await loadCatalog(record: record)
        try validateMutationScope(scope)
        guard !repositories.contains(where: { $0.id == record.id }) else {
            throw ReaderExtensionError.updateConsentRequired("the repository changed while it was loading")
        }
        record = loaded.record
        try enforceLicense(record.license, allowUnknown: allowUnknownLicense)
        let candidateRepositories = repositories + [record]
        try validateMutationScope(scope)
            try ReaderExtensionDurableMutation.commit(
                candidate: candidateRepositories,
                persist: {
                    try persist(repositories: $0, installedSources: installedSources)
                },
                publish: {
                    repositories = $0
                    repositoryCatalogs[record.id] = loaded.catalog
                    rebuildCatalogSources()
                }
            )
            ReaderExtensionDiagnostics.record(
                context: ReaderExtensionDiagnosticContext(repositoryID: record.id, name: record.name),
                operation: "add-repository",
                event: "succeeded",
                type: ReaderExtensionDiagnostics.repositoryType,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt),
                count: loaded.catalog.sources.count
            )
        } catch {
            ReaderExtensionDiagnostics.recordFailure(
                context: diagnosticContext,
                operation: "add-repository",
                error: error,
                type: ReaderExtensionDiagnostics.repositoryType,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            throw error
        }
    }

    func refreshRepository(id: String, allowScopeExpansion: Bool = false) async throws {
        let diagnosticContext = ReaderExtensionDiagnosticContext(
            repositoryID: id,
            name: repository(id: id)?.name ?? "Unknown Repository"
        )
        let startedAt = Date()
        ReaderExtensionDiagnostics.record(
            context: diagnosticContext,
            operation: "refresh-repository",
            event: "started",
            type: ReaderExtensionDiagnostics.repositoryType
        )
        do {
            try requireAdministrativeAdmission()
            let scope = try captureMutationScope()
            guard let index = repositories.firstIndex(where: { $0.id == id }) else { throw ReaderExtensionError.sourceNotFound }
            isRefreshing = true
            defer { isRefreshing = false }
            let previous = repositories[index]
            let loaded = try await loadCatalog(record: previous)
            try validateMutationScope(scope)
            guard let currentIndex = repositories.firstIndex(where: { $0.id == id }),
                  repositories[currentIndex] == previous else {
                throw ReaderExtensionError.runtimeUnavailable
            }
            try enforceLicense(loaded.record.license, allowUnknown: true)
            var candidateRepositories = repositories
            candidateRepositories[currentIndex] = loaded.record
            try validateMutationScope(scope)
            try ReaderExtensionDurableMutation.commit(
                candidate: candidateRepositories,
                persist: {
                    try persist(repositories: $0, installedSources: installedSources)
                },
                publish: {
                    repositories = $0
                    repositoryCatalogs[id] = loaded.catalog
                    rebuildCatalogSources()
                }
            )
            ReaderExtensionDiagnostics.record(
                context: ReaderExtensionDiagnosticContext(repositoryID: id, name: loaded.record.name),
                operation: "refresh-repository",
                event: "succeeded",
                type: ReaderExtensionDiagnostics.repositoryType,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt),
                count: loaded.catalog.sources.count
            )
        } catch {
            ReaderExtensionDiagnostics.recordFailure(
                context: diagnosticContext,
                operation: "refresh-repository",
                error: error,
                type: ReaderExtensionDiagnostics.repositoryType,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            throw error
        }
    }

    func refreshAllRepositories() async {
        guard (try? requireAdministrativeAdmission()) != nil else { return }
        await refreshAllRepositoriesAdmitted(allowsKidsModeAdministrativeBypass: false)
    }

    private func refreshAllRepositoriesAdmitted(
        allowsKidsModeAdministrativeBypass: Bool
    ) async {
        guard let scope = try? captureMutationScope(
            allowsKidsModeAdministrativeBypass: allowsKidsModeAdministrativeBypass
        ) else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let diagnosticContext = ReaderExtensionDiagnosticContext(
            repositoryID: "all",
            name: "Enabled Repositories"
        )
        let startedAt = Date()
        ReaderExtensionDiagnostics.record(
            context: diagnosticContext,
            operation: "refresh-all",
            event: "started",
            type: ReaderExtensionDiagnostics.repositoryType
        )
        let baselineRepositories = repositories
        var candidateRepositories = repositories
        var candidateCatalogs = repositoryCatalogs
        var refreshedCount = 0
        var failureCount = 0
        for id in candidateRepositories.filter(\.isEnabled).map(\.id) {
            do {
                guard let record = candidateRepositories.first(where: { $0.id == id }) else { continue }
                let loaded = try await loadCatalog(record: record)
                guard (try? validateMutationScope(scope)) != nil else { return }
                try enforceLicense(loaded.record.license, allowUnknown: true)
                if let index = candidateRepositories.firstIndex(where: { $0.id == id }) {
                    candidateRepositories[index] = loaded.record
                    candidateCatalogs[id] = loaded.catalog
                    refreshedCount += 1
                }
            } catch {
                guard (try? validateMutationScope(scope)) != nil else { return }
                failureCount += 1
                let failedRecord = candidateRepositories.first(where: { $0.id == id })
                ReaderExtensionDiagnostics.recordFailure(
                    context: ReaderExtensionDiagnosticContext(
                        repositoryID: id,
                        name: failedRecord?.name ?? "Unknown Repository"
                    ),
                    operation: "refresh-all-item",
                    error: error,
                    type: ReaderExtensionDiagnostics.repositoryType
                )
                if let index = candidateRepositories.firstIndex(where: { $0.id == id }) {
                    candidateRepositories[index].errorMessage = error.localizedDescription
                }
            }
        }
        guard (try? validateMutationScope(scope)) != nil,
              repositories == baselineRepositories else { return }
        do {
            try ReaderExtensionDurableMutation.commit(
                candidate: candidateRepositories,
                persist: {
                    try persist(repositories: $0, installedSources: installedSources)
                },
                publish: {
                    repositories = $0
                    repositoryCatalogs = candidateCatalogs
                    rebuildCatalogSources()
                }
            )
            ReaderExtensionDiagnostics.record(
                context: diagnosticContext,
                operation: "refresh-all",
                event: failureCount == 0 ? "succeeded" : "partial",
                type: ReaderExtensionDiagnostics.repositoryType,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt),
                count: refreshedCount
            )
        } catch {
            ReaderExtensionDiagnostics.recordFailure(
                context: diagnosticContext,
                operation: "refresh-all",
                error: error,
                type: ReaderExtensionDiagnostics.repositoryType,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            // Refresh-all has no throwing UI contract. A failed transaction is
            // deliberately left wholly unpublished; a foreground single-row
            // refresh remains available to surface the storage error.
        }
    }

    func removeRepository(id: String) throws {
        try requireAdministrativeAdmission()
        guard let namespaces = removalDeviceStateNamespaces() else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        let removedSources = installedSources.filter { $0.repositoryID == id }
        let removedSourceIDs = Set(removedSources.map(\.id)).union(
            repositoryCatalogs[id]?.sources.map(\.id) ?? []
        )
        let candidateRepositories = repositories.filter { $0.id != id }
        let candidateSources = normalizedSortIndexes(
            installedSources.filter { $0.repositoryID != id }
        )
        let previousCleanup = try enqueueAuthenticationCleanup(
            sourceIDs: removedSources.map(\.id),
            namespaces: namespaces,
            kind: .deviceState
        )

        do {
            try persist(
                repositories: candidateRepositories,
                installedSources: candidateSources
            )
        } catch {
            try? ReaderExtensionAuthenticationCleanupJournal.restore(
                previousCleanup,
                store: authenticationCleanupStore
            )
            throw error
        }
        repositories = candidateRepositories
        installedSources = candidateSources
        repositoryCatalogs[id] = nil
        rebuildCatalogSources()
        for source in removedSources {
            removePageRequests(for: source.id)
        }
        clearUnreferencedRuntimeQuarantine(sourceIDs: removedSourceIDs)
        removeUnreferencedContent()
        try retryPendingAuthenticationCleanup(
            sourceIDs: Set(removedSources.map(\.id)),
            namespaces: Set(namespaces)
        )
    }

    func requiredDomains(for sourceID: ReaderExtensionSourceID) -> Set<String> {
        guard isAvailable else { return [] }
        return catalogSource(for: sourceID).map(installationDomains) ?? []
    }

    func install(
        sourceID: ReaderExtensionSourceID,
        allowUnknownLicense: Bool = false,
        approvedDomains: Set<String> = []
    ) async throws {
        let diagnosticContext = catalogSource(for: sourceID)
            .map(ReaderExtensionDiagnosticContext.init(catalog:))
            ?? ReaderExtensionDiagnosticContext(sourceID: sourceID)
        let startedAt = Date()
        var diagnosticStage = "admission"
        ReaderExtensionDiagnostics.record(
            context: diagnosticContext,
            operation: "install",
            event: "started",
            type: ReaderExtensionDiagnostics.lifecycleType,
            stage: diagnosticStage
        )
        do {
            try requireAdministrativeAdmission()
        // Awaiting the script download/runtime bootstrap leaves this MainActor
        // method re-entrant. Admit one install per source so repeated taps
        // cannot race and roll back the successful attempt's device state.
        guard installingSourceIDs.insert(sourceID).inserted else {
            ReaderExtensionDiagnostics.record(
                context: diagnosticContext,
                operation: "install",
                event: "coalesced",
                type: ReaderExtensionDiagnostics.lifecycleType,
                stage: "admission",
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            return
        }
        defer { installingSourceIDs.remove(sourceID) }
        let scope = try captureMutationScope()
        try retryPendingAuthenticationCleanupForInstallation(sourceID: sourceID)
        guard let catalog = catalogSource(for: sourceID) else { throw ReaderExtensionError.sourceNotFound }
        diagnosticStage = "catalog-validation"
        guard !installedSources.contains(where: { $0.id == sourceID }) else {
            throw ReaderExtensionError.updateConsentRequired("reinstalling an installed source")
        }
        guard installedSources.count < ReaderExtensionPersistence.maximumInstalledSourceCount else {
            throw ReaderExtensionError.contentTooLarge
        }
        guard catalog.implementation != .unsupportedNative else { throw ReaderExtensionError.unsupportedSource }
        guard isMaturityAllowed(catalog.maturity) else { throw ReaderExtensionError.unsupportedSource }
        guard !blockedSourceIDs.contains(sourceID) else {
            throw ReaderExtensionError.unsupportedSource
        }
        let domains = installationDomains(catalog)
        guard approvedDomains.allSatisfy({ ReaderExtensionSecurityPolicy.canonicalHost($0) != nil }) else {
            throw ReaderExtensionError.insecureURL
        }
        let normalizedApproval = ReaderExtensionSecurityPolicy.canonicalHosts(approvedDomains)
        guard normalizedApproval == domains else {
            let missing = domains.subtracting(normalizedApproval).sorted().first ?? domains.sorted().first ?? "source domain"
            ReaderExtensionDomainConsentCoordinator.emit(
                sourceID: sourceID,
                host: missing,
                scopeID: keychainNamespace
            )
            throw ReaderExtensionError.domainConsentRequired(missing)
        }
        for host in normalizedApproval {
            guard let url = ReaderExtensionSecurityPolicy.canonicalHTTPSURL(forHost: host) else {
                throw ReaderExtensionError.insecureURL
            }
            // Actual requests resolve and pin public addresses at use time.
            // This rejects private/local syntax without doing synchronous DNS
            // for every declared domain on the MainActor.
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(url, requireHTTPS: true)
        }
        var resolvedCatalog = catalog
        let artifact: ReaderExtensionJavaScriptArtifact?
        if catalog.implementation == .javascript {
            diagnosticStage = "script-fetch"
            let fetched = try await fetchJavaScriptArtifact(for: catalog, approvedDomains: normalizedApproval)
            try validateMutationScope(scope)
            guard catalogSource(for: sourceID) == catalog,
                  !installedSources.contains(where: { $0.id == sourceID }) else {
                throw ReaderExtensionError.runtimeUnavailable
            }
            resolvedCatalog.license = fetched.license
            artifact = fetched
        } else {
            artifact = nil
        }
        diagnosticStage = "license-validation"
        try enforceLicense(resolvedCatalog.license, allowUnknown: allowUnknownLicense)
        try validateMutationScope(scope)
        var installed = ReaderExtensionInstalledSource(catalog: resolvedCatalog, sortIndex: installedSources.count)
        var didCommitInstall = false
        var didWriteDeviceState = false
        var activatedContentDigest: String?
        defer {
            if let activatedContentDigest {
                pendingInstallContent.release(sourceID: sourceID)
                if !didCommitInstall {
                    // Persistence failures happen after content-addressed
                    // activation. Remove this install's orphan while retaining
                    // every other source currently between activation and its
                    // own metadata commit.
                    removeUnreferencedContent()
                    let retained = (try? contentStore?.scriptData(digest: activatedContentDigest)) != nil
                    ReaderExtensionDiagnostics.record(
                        context: diagnosticContext,
                        operation: "install-cleanup",
                        event: retained ? "retained" : "removed",
                        type: ReaderExtensionDiagnostics.lifecycleType,
                        stage: "orphan-content"
                    )
                }
            }
            if didWriteDeviceState && !didCommitInstall {
                do {
                    _ = try enqueueAuthenticationCleanup(
                        sourceIDs: [sourceID],
                        namespaces: [scope.authenticationNamespace],
                        kind: .deviceState
                    )
                    try retryPendingAuthenticationCleanup(
                        sourceIDs: [sourceID],
                        namespaces: [scope.authenticationNamespace]
                    )
                    ReaderExtensionDiagnostics.record(
                        context: diagnosticContext,
                        operation: "install-cleanup",
                        event: "succeeded",
                        type: ReaderExtensionDiagnostics.lifecycleType,
                        stage: "device-state"
                    )
                } catch {
                    ReaderExtensionDiagnostics.recordFailure(
                        context: diagnosticContext,
                        operation: "install-cleanup",
                        error: error,
                        type: ReaderExtensionDiagnostics.lifecycleType,
                        stage: "device-state"
                    )
                }
            }
        }
        if let artifact {
            diagnosticStage = "runtime-validation"
            installed = try await installingScript(
                for: installed,
                artifact: artifact,
                approvedDomains: normalizedApproval,
                previous: nil,
                allowScopeExpansion: false,
                mutationScope: scope
            )
            if let digest = installed.activeContentDigest {
                activatedContentDigest = digest
                pendingInstallContent.register(digest: digest, sourceID: sourceID)
            }
            try validateMutationScope(scope)
        }
        try validateMutationScope(scope)
        guard catalogSource(for: sourceID) == catalog,
              !installedSources.contains(where: { $0.id == sourceID }) else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        diagnosticStage = "device-state"
        try ReaderExtensionKeychainStore(
            source: installed,
            namespace: scope.authenticationNamespace
        ).setApprovedDomains(normalizedApproval)
        didWriteDeviceState = true
        protectSecretPreferences(
            in: &installed,
            namespace: scope.authenticationNamespace
        )
        var candidateSources = installedSources
        candidateSources.append(installed)
        try validateMutationScope(scope)
        diagnosticStage = "metadata-persistence"
        try ReaderExtensionDurableMutation.commit(
            candidate: candidateSources,
            persist: { try persist(installedSources: $0) },
            publish: {
                installedSources = $0
                didCommitInstall = true
            }
        )
        pendingInstallContent.release(sourceID: sourceID)
        activatedContentDigest = nil
        clearUnreferencedRuntimeQuarantine(sourceIDs: [sourceID])
        removeUnreferencedContent()
        ReaderExtensionDiagnostics.record(
            context: ReaderExtensionDiagnosticContext(source: installed),
            operation: "install",
            event: "succeeded",
            type: ReaderExtensionDiagnostics.lifecycleType,
            stage: "complete",
            elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
        )
        } catch {
            ReaderExtensionDiagnostics.recordFailure(
                context: diagnosticContext,
                operation: "install",
                error: error,
                type: ReaderExtensionDiagnostics.lifecycleType,
                stage: diagnosticStage,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            throw error
        }
    }

    func update(sourceID: ReaderExtensionSourceID, allowScopeExpansion: Bool = false) async throws {
        let diagnosticContext = source(for: sourceID).map(ReaderExtensionDiagnosticContext.init(source:))
            ?? catalogSource(for: sourceID).map(ReaderExtensionDiagnosticContext.init(catalog:))
            ?? ReaderExtensionDiagnosticContext(sourceID: sourceID)
        let startedAt = Date()
        ReaderExtensionDiagnostics.record(
            context: diagnosticContext,
            operation: "update",
            event: "started",
            type: ReaderExtensionDiagnostics.lifecycleType
        )
        do {
            try requireAdministrativeAdmission()
            try await updateAdmitted(
                sourceID: sourceID,
                allowScopeExpansion: allowScopeExpansion
            )
            ReaderExtensionDiagnostics.record(
                context: diagnosticContext,
                operation: "update",
                event: "succeeded",
                type: ReaderExtensionDiagnostics.lifecycleType,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
            )
        } catch {
            ReaderExtensionDiagnostics.recordFailure(
                context: diagnosticContext,
                operation: "update",
                error: error,
                type: ReaderExtensionDiagnostics.lifecycleType,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            throw error
        }
    }

    private func updateAdmitted(
        sourceID: ReaderExtensionSourceID,
        allowScopeExpansion: Bool = false,
        allowsKidsModeAdministrativeBypass: Bool = false
    ) async throws {
        let scope = try captureMutationScope(
            allowsKidsModeAdministrativeBypass: allowsKidsModeAdministrativeBypass
        )
        try retryPendingAuthenticationCleanup(sourceID: sourceID)
        guard var installedIndex = installedSources.firstIndex(where: { $0.id == sourceID }),
              let catalog = catalogSource(for: sourceID) else { throw ReaderExtensionError.sourceNotFound }
        let current = installedSources[installedIndex]
        let versionOrder = ReaderExtensionVersion.compare(catalog.version, current.version)
        let requiresCatalogRevalidation = current.requiresReinstall
        let isCodeReinstall = current.implementation == .javascript
            && current.activeContentDigest == nil
        let mayRevalidateSameVersion = requiresCatalogRevalidation || isCodeReinstall
        switch versionOrder {
        case .orderedDescending:
            break
        case .orderedSame:
            // Metadata-only backup restoration intentionally preserves the
            // source version while dropping executable bytes. That one case
            // may reacquire the exact catalog version automatically. Replacing
            // runnable same-version bytes is an explicit update-consent action.
            guard mayRevalidateSameVersion || allowScopeExpansion else { return }
        case .orderedAscending:
            // Updates never downgrade runnable code, including manually
            // consented updates. A metadata-only restored record has no
            // runnable code, so it may reacquire the repository's current
            // older version instead of dead-ending.
            guard isCodeReinstall else { return }
        case nil:
            // A changed version that is not valid SemVer has no safe monotonic
            // ordering. Automatic updates leave it untouched; a foreground
            // scope/update-consent action may proceed. An exact legacy version
            // may still restore code omitted from a metadata-only backup.
            guard (mayRevalidateSameVersion && catalog.version == current.version) || allowScopeExpansion else {
                throw ReaderExtensionError.updateConsentRequired("an unrecognized source version change")
            }
        }
        guard catalog.codeProvenanceFingerprint == current.codeProvenanceFingerprint || allowScopeExpansion else {
            throw ReaderExtensionError.updateConsentRequired("the source code owner or path")
        }
        let oldDomains = installationDomains(current)
        let newDomains = installationDomains(catalog)
        guard newDomains.isSubset(of: oldDomains) || allowScopeExpansion else {
            throw ReaderExtensionError.updateConsentRequired("the source's network domains")
        }
        if catalog.maturity != current.maturity && !allowScopeExpansion {
            throw ReaderExtensionError.updateConsentRequired("the source maturity rating")
        }
        var resolvedCatalog = catalog
        var artifact: ReaderExtensionJavaScriptArtifact?
        if catalog.implementation == .javascript {
            let approved = ReaderExtensionMetadataReacquisitionPolicy.fetchAuthorizedDomains(
                allowScopeExpansion: allowScopeExpansion,
                reacquiresMetadataOnlyInstall: mayRevalidateSameVersion,
                catalogInstallationDomains: newDomains,
                currentInstallationDomains: oldDomains,
                runtimeAuthorizedDomains: {
                    approvedDomains(for: sourceID, namespace: scope.authenticationNamespace)
                }
            )
            artifact = try await fetchJavaScriptArtifact(for: catalog, approvedDomains: approved)
            try validateMutationScope(scope)
            guard let refreshedIndex = installedSources.firstIndex(where: { $0.id == sourceID }),
                  installedSources[refreshedIndex] == current,
                  catalogSource(for: sourceID) == catalog else {
                throw ReaderExtensionError.runtimeUnavailable
            }
            installedIndex = refreshedIndex
            resolvedCatalog.license = artifact?.license ?? .unknown
        }
        try enforceLicense(
            resolvedCatalog.license,
            allowUnknown: ReaderExtensionMetadataReacquisitionPolicy.allowsUnknownLicense(
                allowScopeExpansion: allowScopeExpansion,
                currentLicenseKind: current.license.kind
            )
        )
        var replacement = ReaderExtensionInstalledSource(catalog: resolvedCatalog, sortIndex: current.sortIndex)
        // Preserve whether the language was explicitly selected. Legacy
        // language compatibility must survive an ordinary source update;
        // fresh installs still receive the current explicit-selection marker.
        replacement.languageSelectionVersion = current.languageSelectionVersion
        replacement.enabled = current.enabled
        replacement.installedAt = current.installedAt
        replacement.preferences = current.preferences
        replacement.activeContentDigest = current.activeContentDigest
        replacement.rollbackContentDigest = current.rollbackContentDigest
        replacement.rollbackSourceSnapshot = current.rollbackSourceSnapshot
        if let artifact {
            let approved = ReaderExtensionMetadataReacquisitionPolicy.fetchAuthorizedDomains(
                allowScopeExpansion: allowScopeExpansion,
                reacquiresMetadataOnlyInstall: mayRevalidateSameVersion,
                catalogInstallationDomains: newDomains,
                currentInstallationDomains: oldDomains,
                runtimeAuthorizedDomains: {
                    approvedDomains(for: sourceID, namespace: scope.authenticationNamespace)
                }
            )
            replacement = try await installingScript(
                for: replacement,
                artifact: artifact,
                approvedDomains: approved,
                previous: current,
                allowScopeExpansion: allowScopeExpansion,
                mutationScope: scope
            )
            try validateMutationScope(scope)
            guard let refreshedIndex = installedSources.firstIndex(where: { $0.id == sourceID }),
                  installedSources[refreshedIndex] == current,
                  catalogSource(for: sourceID) == catalog else {
                throw ReaderExtensionError.runtimeUnavailable
            }
            installedIndex = refreshedIndex
            replacement.rollbackSourceSnapshot = ReaderExtensionInstalledSourceRollbackSnapshot(source: current)
            replacement.rollbackContentDigest = replacement.rollbackSourceSnapshot?.activeContentDigest
        }
        try validateMutationScope(scope)
        protectSecretPreferences(
            in: &replacement,
            namespace: scope.authenticationNamespace
        )
        let approvalStore = ReaderExtensionKeychainStore(
            source: current,
            namespace: scope.authenticationNamespace
        )
        let previousApprovedDomains = approvalStore.approvedDomains()
        try validateMutationScope(scope)
        if allowScopeExpansion { try approvalStore.setApprovedDomains(newDomains) }
        try validateMutationScope(scope)
        var candidateSources = installedSources
        guard candidateSources.indices.contains(installedIndex),
              candidateSources[installedIndex] == current else {
            if allowScopeExpansion { try? approvalStore.setApprovedDomains(previousApprovedDomains) }
            throw ReaderExtensionError.runtimeUnavailable
        }
        candidateSources[installedIndex] = replacement
        do {
            try persist(installedSources: candidateSources)
            installedSources = candidateSources
        } catch {
            if allowScopeExpansion { try? approvalStore.setApprovedDomains(previousApprovedDomains) }
            removeUnreferencedContent()
            throw error
        }
        removePageRequests(for: sourceID)
        clearUnreferencedRuntimeQuarantine(sourceIDs: [sourceID])
        removeUnreferencedContent()
    }

    func updateAll() async {
        guard (try? requireAdministrativeAdmission()) != nil else { return }
        await updateAllAdmitted(allowsKidsModeAdministrativeBypass: false)
    }

    private func updateAllAdmitted(
        allowsKidsModeAdministrativeBypass: Bool
    ) async {
        guard let scope = try? captureMutationScope(
            allowsKidsModeAdministrativeBypass: allowsKidsModeAdministrativeBypass
        ) else { return }
        guard !isUpdatingSources else { return }
        isUpdatingSources = true
        defer { isUpdatingSources = false }
        await refreshAllRepositoriesAdmitted(
            allowsKidsModeAdministrativeBypass: allowsKidsModeAdministrativeBypass
        )
        guard (try? validateMutationScope(scope)) != nil else { return }
        let sourceIDs = installedSources.map(\.id)
        for id in sourceIDs {
            let diagnosticContext = source(for: id).map(ReaderExtensionDiagnosticContext.init(source:))
                ?? ReaderExtensionDiagnosticContext(sourceID: id)
            let startedAt = Date()
            ReaderExtensionDiagnostics.record(
                context: diagnosticContext,
                operation: "auto-update",
                event: "started",
                type: ReaderExtensionDiagnostics.lifecycleType
            )
            do {
                try await updateAdmitted(
                    sourceID: id,
                    allowsKidsModeAdministrativeBypass: allowsKidsModeAdministrativeBypass
                )
                ReaderExtensionDiagnostics.record(
                    context: diagnosticContext,
                    operation: "auto-update",
                    event: "succeeded",
                    type: ReaderExtensionDiagnostics.lifecycleType,
                    elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
                )
            } catch {
                ReaderExtensionDiagnostics.recordFailure(
                    context: diagnosticContext,
                    operation: "auto-update",
                    error: error,
                    type: ReaderExtensionDiagnostics.lifecycleType,
                    elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
                )
            }
            guard (try? validateMutationScope(scope)) != nil else { return }
        }
        let candidateLastAutoUpdate = Date()
        guard (try? validateMutationScope(scope)) != nil else { return }
        do {
            try persist(
                showMature: showMatureSources,
                autoUpdate: autoUpdateSources,
                lastAutoUpdate: candidateLastAutoUpdate
            )
            lastAutoUpdate = candidateLastAutoUpdate
        } catch {
            // An update pass may still have installed individually durable
            // versions. Only the scheduling timestamp remains unchanged so a
            // later foreground/background pass can retry it.
        }
    }

    func autoUpdateInstalledSourcesIfNeeded(reason: String) async {
        guard isAvailable else { return }
        scheduleAutomaticCodeReacquisition(reason: reason)
        guard autoUpdateSources, !installedSources.isEmpty, !isUpdatingSources else { return }
        if let lastAutoUpdate, Date().timeIntervalSince(lastAutoUpdate) < 24 * 60 * 60 { return }
        await updateAllAdmitted(allowsKidsModeAdministrativeBypass: true)
    }

    var sourceIDsAwaitingCodeReacquisition: [ReaderExtensionSourceID] {
        guard isAvailable else { return [] }
        return installedSources.filter { source in
            guard ReaderExtensionMetadataReacquisitionPolicy.needsCodeReacquisition(
                source,
                blockedSourceIDs: blockedSourceIDs
            ) else { return false }
            guard let record = repositories.first(where: { $0.id == source.repositoryID }) else {
                return true
            }
            return record.isEnabled
        }.map(\.id)
    }

    func scheduleAutomaticCodeReacquisition(reason: String) {
        guard isAvailable else { return }
        codeReacquisitionGeneration &+= 1
        let generation = codeReacquisitionGeneration
        let predecessor = codeReacquisitionTask
        predecessor?.cancel()
        guard !sourceIDsAwaitingCodeReacquisition.isEmpty else {
            codeReacquisitionTask = nil
            return
        }
        codeReacquisitionTask = Task { [weak self] in
            await predecessor?.value
            await self?.reacquireMissingSourceCode(generation: generation, reason: reason)
        }
    }

    private func reacquireMissingSourceCode(generation: Int, reason: String) async {
        guard isAvailable, !isUpdatingSources,
              codeReacquisitionGeneration == generation, !Task.isCancelled else { return }
        isUpdatingSources = true
        defer { isUpdatingSources = false }
        await refreshAllRepositoriesAdmitted(allowsKidsModeAdministrativeBypass: true)
        guard codeReacquisitionGeneration == generation, !Task.isCancelled else { return }
        var repairedCount = 0
        var failureSummaries: [String] = []
        for sourceID in sourceIDsAwaitingCodeReacquisition {
            guard codeReacquisitionGeneration == generation, !Task.isCancelled else { break }
            do {
                try await updateAdmitted(
                    sourceID: sourceID,
                    allowsKidsModeAdministrativeBypass: true
                )
                let stillPending = source(for: sourceID).map {
                    ReaderExtensionMetadataReacquisitionPolicy.needsCodeReacquisition(
                        $0,
                        blockedSourceIDs: blockedSourceIDs
                    )
                } ?? true
                if !stillPending {
                    repairedCount += 1
                } else {
                    failureSummaries.append("\(sourceID.rawValue): still pending after an update pass")
                }
            } catch {
                failureSummaries.append("\(sourceID.rawValue): \(error.localizedDescription)")
            }
        }
        let failureSuffix = failureSummaries.isEmpty
            ? ""
            : " [" + failureSummaries.joined(separator: "; ") + "]"
        Logger.shared.log(
            "ReaderExtension code reacquisition reason=\(reason) repaired=\(repairedCount) failed=\(failureSummaries.count)\(failureSuffix)",
            type: "Plugin"
        )
    }

    func uninstall(sourceID: ReaderExtensionSourceID) throws {
        try requireAdministrativeAdmission()
        guard let source = source(for: sourceID) else { throw ReaderExtensionError.sourceNotFound }
        guard let namespaces = removalDeviceStateNamespaces() else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        let candidateSources = normalizedSortIndexes(
            installedSources.filter { $0.id != sourceID }
        )
        let previousCleanup = try enqueueAuthenticationCleanup(
            sourceIDs: [source.id],
            namespaces: namespaces,
            kind: .deviceState
        )
        do {
            try persist(installedSources: candidateSources)
        } catch {
            try? ReaderExtensionAuthenticationCleanupJournal.restore(
                previousCleanup,
                store: authenticationCleanupStore
            )
            throw error
        }
        installedSources = candidateSources
        removePageRequests(for: sourceID)
        clearUnreferencedRuntimeQuarantine(sourceIDs: [sourceID])
        removeUnreferencedContent()
        try retryPendingAuthenticationCleanup(
            sourceIDs: [sourceID],
            namespaces: Set(namespaces)
        )
    }

    func block(sourceID: ReaderExtensionSourceID) throws {
        try requireAdministrativeAdmission()
        guard let source = source(for: sourceID) else { throw ReaderExtensionError.sourceNotFound }
        guard let namespaces = removalDeviceStateNamespaces() else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        let previousSources = installedSources
        let candidateSources = normalizedSortIndexes(
            installedSources.filter { $0.id != sourceID }
        )
        var candidateBlockedSourceIDs = blockedSourceIDs
        candidateBlockedSourceIDs.insert(sourceID)
        let candidate = (sources: candidateSources, blocked: candidateBlockedSourceIDs)
        let previousCleanup = try enqueueAuthenticationCleanup(
            sourceIDs: [source.id],
            namespaces: namespaces,
            kind: .deviceState
        )
        do {
            try ReaderExtensionDurableMutation.commitCoordinated(
                candidate: candidate,
                persist: { try persist(installedSources: $0.sources) },
                applySecondary: { try persistBlockedSources(candidate.blocked) },
                rollbackPersistence: { try? persist(installedSources: previousSources) },
                publish: {
                    installedSources = $0.sources
                    blockedSourceIDs = $0.blocked
                },
                afterCommit: { removePageRequests(for: sourceID) }
            )
        } catch {
            try? ReaderExtensionAuthenticationCleanupJournal.restore(
                previousCleanup,
                store: authenticationCleanupStore
            )
            throw error
        }
        clearUnreferencedRuntimeQuarantine(sourceIDs: [sourceID])
        removeUnreferencedContent()
        try retryPendingAuthenticationCleanup(
            sourceIDs: [sourceID],
            namespaces: Set(namespaces)
        )
    }

    func unblock(sourceID: ReaderExtensionSourceID) throws {
        try requireAdministrativeAdmission()
        var candidate = blockedSourceIDs
        candidate.remove(sourceID)
        try persistBlockedSources(candidate)
        blockedSourceIDs = candidate
    }

    func setEnabled(_ enabled: Bool, for sourceID: ReaderExtensionSourceID) throws {
        try requireAdministrativeAdmission()
        guard let index = installedSources.firstIndex(where: { $0.id == sourceID }) else {
            throw ReaderExtensionError.sourceNotFound
        }
        var candidateSources = installedSources
        candidateSources[index].enabled = enabled
        try ReaderExtensionDurableMutation.commit(
            candidate: candidateSources,
            persist: { try persist(installedSources: $0) },
            publish: { installedSources = $0 }
        )
        if !enabled { removePageRequests(for: sourceID) }
    }

    func moveInstalledSources(from offsets: IndexSet, to destination: Int) throws {
        try requireAdministrativeAdmission()
        var ordered = installedSources.sorted { $0.sortIndex < $1.sortIndex }
        ordered.move(fromOffsets: offsets, toOffset: destination)
        let candidateSources = normalizedSortIndexes(ordered)
        try ReaderExtensionDurableMutation.commit(
            candidate: candidateSources,
            persist: { try persist(installedSources: $0) },
            publish: { installedSources = $0 }
        )
    }

    func setShowMatureSources(_ value: Bool) throws {
        try requireAdministrativeAdmission()
        try ReaderExtensionDurableMutation.commit(
            candidate: value,
            persist: {
                try persist(
                    showMature: $0,
                    autoUpdate: autoUpdateSources,
                    lastAutoUpdate: lastAutoUpdate
                )
            },
            publish: { showMatureSources = $0 }
        )
    }

    func setAutoUpdateSources(_ value: Bool) throws {
        try requireAdministrativeAdmission()
        try ReaderExtensionDurableMutation.commit(
            candidate: value,
            persist: {
                try persist(
                    showMature: showMatureSources,
                    autoUpdate: $0,
                    lastAutoUpdate: lastAutoUpdate
                )
            },
            publish: { autoUpdateSources = $0 }
        )
    }

    func preferenceValue(for key: String, sourceID: ReaderExtensionSourceID) -> ReaderExtensionPreferenceValue? {
        guard isAvailable else { return nil }
        guard let pending = try? ReaderExtensionPersistence.loadPendingAuthenticationCleanup(
            from: authenticationCleanupStore
        ) else { return nil }
        if pending.contains(where: {
            $0.applies(to: sourceID, namespace: keychainNamespace)
        }) {
            return nil
        }
        guard let source = source(for: sourceID) else { return nil }
        if source.secretPreferenceKeys.contains(key) {
            return (try? ReaderExtensionKeychainStore(source: source, namespace: keychainNamespace).secret(for: key)).flatMap { $0 }.map(ReaderExtensionPreferenceValue.secretReference)
        }
        if ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
            || source.preferences[key]?.isSecret == true {
            // Heuristic keys remain Keychain-only on write, but an old value
            // is unreadable after the validated schema drops that capability.
            return nil
        }
        return source.preferences[key]
    }

    func setPreference(_ value: ReaderExtensionPreferenceValue, for key: String, sourceID: ReaderExtensionSourceID) throws {
        try requireAdministrativeAdmission()
        try retryPendingAuthenticationCleanup(sourceID: sourceID)
        guard let index = installedSources.firstIndex(where: { $0.id == sourceID }) else {
            throw ReaderExtensionError.sourceNotFound
        }
        let source = installedSources[index]
        let keychain = ReaderExtensionKeychainStore(source: source, namespace: keychainNamespace)
        let mustUseKeychain = source.secretPreferenceKeys.contains(key)
            || ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
            || value.isSecret
        var candidateSources = installedSources
        if mustUseKeychain {
            let secret: String
            switch value {
            case .secretReference(let value), .string(let value): secret = value
            case .bool(let value): secret = String(value)
            case .number(let value): secret = String(value)
            case .stringList(let value): secret = value.joined(separator: "\n")
            }
            try ReaderExtensionSecurityPolicy.validatePreferenceSecret(key: key, value: secret)
            let previousSecret = try keychain.secret(for: key)
            let previousSources = installedSources
            candidateSources[index].preferences[key] = .secretReference(key)
            try ReaderExtensionDurableMutation.commitCoordinated(
                candidate: candidateSources,
                persist: { try persist(installedSources: $0) },
                applySecondary: {
                    do {
                        try keychain.setSecret(secret, for: key)
                    } catch {
                        try? keychain.setSecret(previousSecret, for: key)
                        throw error
                    }
                },
                rollbackPersistence: { try? persist(installedSources: previousSources) },
                publish: { installedSources = $0 }
            )
            removePageRequests(for: sourceID)
            NotificationCenter.default.post(name: .readerExtensionAuthenticationDidChange, object: sourceID)
        } else {
            try ReaderExtensionSecurityPolicy.validatePreference(key: key, value: value)
            guard candidateSources[index].preferences[key] != nil
                    || candidateSources[index].preferences.count < ReaderExtensionSecurityPolicy.maximumPreferenceCount else {
                throw ReaderExtensionError.contentTooLarge
            }
            candidateSources[index].preferences[key] = value
            try ReaderExtensionDurableMutation.commit(
                candidate: candidateSources,
                persist: { try persist(installedSources: $0) },
                publish: { installedSources = $0 }
            )
            removePageRequests(for: sourceID)
        }
    }

    /// Restores every ordinary option in one durable mutation. Authentication
    /// and secret preference references are intentionally retained; resetting
    /// source options must not silently sign the user out or rewrite Keychain
    /// material. Values are supplied from the currently validated preference
    /// schema rather than from untrusted persisted metadata.
    func resetOrdinaryPreferences(
        to declaredDefaults: [String: ReaderExtensionPreferenceValue],
        sourceID: ReaderExtensionSourceID
    ) throws {
        try requireAdministrativeAdmission()
        try retryPendingAuthenticationCleanup(sourceID: sourceID)
        guard let index = installedSources.firstIndex(where: { $0.id == sourceID }) else {
            throw ReaderExtensionError.sourceNotFound
        }
        guard declaredDefaults.count <= ReaderExtensionSecurityPolicy.maximumPreferenceCount else {
            throw ReaderExtensionError.contentTooLarge
        }

        let source = installedSources[index]
        var validatedDefaults: [String: ReaderExtensionPreferenceValue] = [:]
        for (key, value) in declaredDefaults {
            guard !source.secretPreferenceKeys.contains(key),
                  !ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key),
                  !value.isSecret else {
                continue
            }
            try ReaderExtensionSecurityPolicy.validatePreference(key: key, value: value)
            validatedDefaults[key] = value
        }

        var candidateSources = installedSources
        let retainedSecrets = source.preferences.filter { key, value in
            source.secretPreferenceKeys.contains(key)
                || ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
                || value.isSecret
        }
        candidateSources[index].preferences = retainedSecrets.merging(validatedDefaults) { _, declared in
            declared
        }
        try ReaderExtensionDurableMutation.commit(
            candidate: candidateSources,
            persist: { try persist(installedSources: $0) },
            publish: { installedSources = $0 }
        )
        removePageRequests(for: sourceID)
    }

    func approvedDomains(for sourceID: ReaderExtensionSourceID) -> Set<String> {
        guard isAvailable else { return [] }
        return approvedDomains(for: sourceID, namespace: keychainNamespace)
    }

    private func approvedDomains(
        for sourceID: ReaderExtensionSourceID,
        namespace: String
    ) -> Set<String> {
        guard let source = installedSources.first(where: { $0.id == sourceID }) else { return [] }
        let store = ReaderExtensionKeychainStore(
            source: source,
            namespace: namespace
        )
        return ReaderExtensionInstalledDomainAuthorizationPolicy.runtimeAuthorizedDomains(
            source: source,
            store: store,
            onPersistenceFailure: {
                // Do not include the Keychain status, host, URL, or stored
                // value. Runtime continues with the installed record's exact
                // trusted declaration and retries this mirror on the next use.
                ReaderExtensionDiagnostics.record(
                    context: ReaderExtensionDiagnosticContext(source: source),
                    operation: "domain-authorization-mirror",
                    event: "degraded",
                    type: ReaderExtensionDiagnostics.lifecycleType,
                    stage: "device-state"
                )
            }
        )
    }

    func approve(domain: String, for sourceID: ReaderExtensionSourceID) throws {
        try requireAdministrativeAdmission()
        guard let source = source(for: sourceID) else { throw ReaderExtensionError.sourceNotFound }
        guard let host = ReaderExtensionSecurityPolicy.canonicalHost(domain),
              let url = ReaderExtensionSecurityPolicy.canonicalHTTPSURL(forHost: host),
              (try? ReaderExtensionSecurityPolicy.validatePublicURL(url)) != nil else {
            throw ReaderExtensionError.privateNetworkDestination
        }
        let keychain = ReaderExtensionKeychainStore(source: source, namespace: keychainNamespace)
        var domains = keychain.userApprovedDomains(); domains.insert(host); try keychain.setUserApprovedDomains(domains)
        ReaderExtensionDomainConsentCoordinator.shared.resolve(
            sourceID: sourceID,
            host: host,
            scopeID: keychainNamespace
        )
        invalidateResourceHeaders(for: sourceID)
        // Domain approvals live in device-only Keychain rather than source
        // metadata, so explicitly invalidate settings/reconnect task inputs.
        objectWillChange.send()
    }

    func approve(_ request: ReaderExtensionDomainConsentRequest) throws {
        try requireAvailability()
        guard request.scopeID == keychainNamespace else {
            throw ReaderExtensionError.domainConsentRequired(request.host)
        }
        try approve(domain: request.host, for: request.sourceID)
    }

    func domainConsentRequest(domain: String, for sourceID: ReaderExtensionSourceID) -> ReaderExtensionDomainConsentRequest {
        guard isAvailable else {
            return ReaderExtensionDomainConsentRequest(scopeID: "", sourceID: sourceID, host: "")
        }
        return ReaderExtensionDomainConsentRequest(
            scopeID: keychainNamespace,
            sourceID: sourceID,
            host: domain
        )
    }

    func clearAuthentication(for sourceID: ReaderExtensionSourceID) throws {
        try requireAdministrativeAdmission()
        guard let index = installedSources.firstIndex(where: { $0.id == sourceID }) else {
            throw ReaderExtensionError.sourceNotFound
        }
        let source = installedSources[index]
        var candidateSources = installedSources
        let previousCleanup = try enqueueAuthenticationCleanup(
            sourceIDs: [source.id],
            namespaces: [keychainNamespace],
            kind: .authentication
        )
        // Opaque requests may contain provider-supplied Authorization headers.
        // Invalidate them as soon as durable revocation intent exists, so a
        // later retry that clears the tombstone cannot revive pre-clear bytes.
        removePageRequests(for: sourceID)
        if candidateSources[index].removeAuthenticationPreferenceMetadata() {
            do {
                try persist(installedSources: candidateSources)
            } catch {
                try? ReaderExtensionAuthenticationCleanupJournal.restore(
                    previousCleanup,
                    store: authenticationCleanupStore
                )
                throw error
            }
            installedSources = candidateSources
        }
        do {
            try retryPendingAuthenticationCleanup(sourceID: sourceID)
        } catch {
            // The durable marker remains and gates every provider/network path
            // until the exact deletion can be verified on a later retry.
            throw error
        }
        NotificationCenter.default.post(name: .readerExtensionAuthenticationDidChange, object: sourceID)
    }

    func makeSignInSession(for sourceID: ReaderExtensionSourceID) throws -> ReaderExtensionSignInSession {
        try requireAdministrativeAdmission()
        try retryPendingAuthenticationCleanup(sourceID: sourceID)
        guard let source = source(for: sourceID) else {
            throw ReaderExtensionError.sourceNotFound
        }
        try ReaderExtensionProviderAdmissionPolicy.validate(source, requiresEnabled: false)
        try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
            source.baseURL,
            requireHTTPS: true
        )
        let domains = approvedDomains(for: sourceID)
        try ReaderExtensionSecurityPolicy.validateApprovedDomain(
            source.baseURL,
            approvedDomains: domains
        )
        return ReaderExtensionSignInSession(
            sourceID: sourceID,
            sourceName: source.name,
            startURL: source.baseURL,
            approvedDomains: domains,
            baseDomain: source.baseURL.host,
            mutationScope: mutationScope(),
            securityRevision: .init(source: source),
            network: ReaderExtensionSecureHTTPClient(
                keychainNamespace: keychainNamespace,
                authenticationSourceID: sourceID,
                emitsDomainConsentRequests: false
            ),
            authenticationStore: ReaderExtensionKeychainStore(
                source: source,
                namespace: keychainNamespace
            )
        )
    }

    /// A source update, approval shrink, profile switch, uninstall, block, or
    /// authentication clear invalidates an already-presented sign-in browser.
    func validateSignInSession(_ session: ReaderExtensionSignInSession) throws {
        try requireAdministrativeAdmission()
        try validateMutationScope(session.mutationScope)
        guard let source = source(for: session.sourceID),
              ReaderExtensionSignInSession.SecurityRevision(source: source) == session.securityRevision,
              approvedDomains(for: session.sourceID) == session.approvedDomains else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        try session.network.validateAuthenticationAdmission(for: session.sourceID)
    }

    /// Registers only opaque handles with the reader. The corresponding URLs
    /// and provider-supplied headers remain bounded, process-local manager
    /// state and are never placed in PageData, download manifests, backups, or
    /// logs. Authentication is added by the secure client at fetch time.
    func pageResources(
        for pages: [ReaderExtensionPage],
        sourceID: ReaderExtensionSourceID
    ) throws -> [ReaderExtensionPageResource] {
        let diagnosticContext = source(for: sourceID)
            .map(ReaderExtensionDiagnosticContext.init(source:))
            ?? ReaderExtensionDiagnosticContext(sourceID: sourceID)
        let startedAt = Date()
        do {
            try requireAvailability()
        try retryPendingAuthenticationCleanup(sourceID: sourceID)
        guard let source = source(for: sourceID), source.enabled, source.isRunnable,
              isMaturityAllowed(source.maturity) else {
            throw ReaderExtensionError.sourceNotFound
        }
        let revision = pageRequestRevision(for: source)
        let scopeID = keychainNamespace
        guard pages.count <= ReaderExtensionPageRequestRegistry.maximumPerSourceCount else {
            throw ReaderExtensionError.contentTooLarge
        }
        var replacements: [(UUID, ReaderExtensionEphemeralPageRequest)] = []
        var resources: [ReaderExtensionPageResource] = []
        replacements.reserveCapacity(pages.count)
        resources.reserveCapacity(pages.count)
        for page in pages {
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(page.url)
            try ReaderExtensionSecurityPolicy.validateNotArchive(data: Data(), response: nil, url: page.url)
            guard page.url.absoluteString.utf8.count <= 16 * 1_024,
                  page.key.utf8.count <= 32 * 1_024 else {
                throw ReaderExtensionError.contentTooLarge
            }
            let headers = try ReaderExtensionSecurityPolicy.sanitizedHeaders(
                page.transientRequestHeaders,
                crossOrigin: false
            )
            let requestID = UUID()
            replacements.append((requestID, ReaderExtensionEphemeralPageRequest(
                sourceID: sourceID,
                sourceRevision: revision,
                scopeID: scopeID,
                key: page.key,
                url: page.url,
                headers: headers
            )))
            resources.append(ReaderExtensionPageResource(
                requestID: requestID,
                sourceID: sourceID,
                key: page.key
            ))
        }
        try pageRequests.insert(replacements, for: sourceID)
        ReaderExtensionDiagnostics.record(
            context: ReaderExtensionDiagnosticContext(source: source),
            operation: "prepare-page-resources",
            event: "succeeded",
            type: ReaderExtensionDiagnostics.networkType,
            elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt),
            count: resources.count
        )
            return resources
        } catch {
            ReaderExtensionDiagnostics.recordFailure(
                context: diagnosticContext,
                operation: "prepare-page-resources",
                error: error,
                type: ReaderExtensionDiagnostics.networkType,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            throw error
        }
    }

    /// Fetches an opaque page through the same DNS-pinned, consent-aware,
    /// source-scoped authenticated client used by extension operations.
    func fetchPage(_ resource: ReaderExtensionPageResource) async throws -> ReaderExtensionNetworkResponse {
        let diagnosticContext = source(for: resource.sourceID)
            .map(ReaderExtensionDiagnosticContext.init(source:))
            ?? ReaderExtensionDiagnosticContext(sourceID: resource.sourceID)
        let startedAt = Date()
        do {
            try requireAvailability()
        try retryPendingAuthenticationCleanup(sourceID: resource.sourceID)
        guard let material = pageRequests.material(for: resource.requestID),
              material.sourceID == resource.sourceID,
              material.key == resource.key,
              material.scopeID == keychainNamespace,
              let source = source(for: resource.sourceID),
              source.enabled,
              source.isRunnable,
              isMaturityAllowed(source.maturity),
              material.sourceRevision == pageRequestRevision(for: source) else {
            throw ReaderExtensionError.sourceNotFound
        }
        let sourceHeaderMaterial = try await resourceHeaders(for: source)
        guard pageRequests.contains(resource.requestID),
              material.scopeID == keychainNamespace,
              let requestSource = self.source(for: resource.sourceID),
              requestSource.enabled,
              requestSource.isRunnable,
              isMaturityAllowed(requestSource.maturity),
              material.sourceRevision == pageRequestRevision(for: requestSource),
              sourceHeaderMaterial.revision == resourceHeaderRevision(for: requestSource) else {
            throw ReaderExtensionError.sourceNotFound
        }
        let approved = approvedDomains(for: resource.sourceID)
        let targetIsApproved = ReaderExtensionSecurityPolicy.canonicalHost(of: material.url)
            .map(approved.contains) ?? false
        let requestHeaders = try ReaderExtensionResourceHeaderPolicy.merging([
            ["Accept": "image/avif,image/webp,image/*,*/*;q=0.8"],
            sourceHeaderMaterial.headers,
            material.headers
        ])
        let requestedReferer = requestHeaders.keys.contains {
            $0.caseInsensitiveCompare("Referer") == .orderedSame
        }
        let response = try await authenticatedNetwork(for: resource.sourceID).request(ReaderExtensionNetworkRequest(
            url: material.url,
            headers: requestHeaders,
            sourceID: material.sourceID,
            approvedDomains: approved,
            baseDomain: requestSource.baseURL.host,
            // JavaScript cannot inject an arbitrary cross-origin Referer. If a
            // source asked for one, reduce it to the verified source origin.
            hostGeneratedOriginReferer: requestSource.implementation == .javascript && !requestedReferer
                ? nil
                : requestSource.baseURL,
            allowsCookies: targetIsApproved,
            redirectPolicy: targetIsApproved ? .approvedDomainsThenPublicHTTPS : .publicHTTPS,
            maximumResponseBytes: ReaderExtensionSecurityPolicy.maximumPageResponseBytes
        ))
        guard (200...299).contains(response.statusCode) else {
            throw ReaderExtensionError.resultInvalid("page returned HTTP \(response.statusCode)")
        }
        guard !response.body.isEmpty else {
            throw ReaderExtensionError.resultInvalid("page response was empty")
        }
        // Image decoding, prefetch, zoom retries, and downloads may legitimately
        // request the same opaque handle more than once. Keep it in the bounded
        // LRU until the source publishes a replacement page list, changes
        // revision/scope, or global pressure evicts it.
            return response
        } catch {
            ReaderExtensionDiagnostics.recordFailure(
                context: diagnosticContext,
                operation: "fetch-page",
                error: error,
                type: ReaderExtensionDiagnostics.networkType,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            throw error
        }
    }

    /// Loads a Reader Extension-owned cover or thumbnail through the pinned
    /// transport. Legacy/module artwork continues to use its existing image
    /// pipeline and never enters this source-scoped path.
    func fetchAsset(at url: URL, sourceID: ReaderExtensionSourceID) async throws -> ReaderExtensionNetworkResponse {
        let diagnosticContext = source(for: sourceID)
            .map(ReaderExtensionDiagnosticContext.init(source:))
            ?? ReaderExtensionDiagnosticContext(sourceID: sourceID)
        let startedAt = Date()
        do {
            try requireAvailability()
        try retryPendingAuthenticationCleanup(sourceID: sourceID)
        guard let source = source(for: sourceID), source.enabled, source.isRunnable,
              isMaturityAllowed(source.maturity) else {
            throw ReaderExtensionError.sourceNotFound
        }
        try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(url)
        try ReaderExtensionSecurityPolicy.validateNotArchive(data: Data(), response: nil, url: url)
        let sourceHeaderMaterial = try await resourceHeaders(for: source)
        guard let requestSource = self.source(for: sourceID),
              requestSource.enabled,
              requestSource.isRunnable,
              isMaturityAllowed(requestSource.maturity),
              resourceHeaderRevision(for: requestSource) == sourceHeaderMaterial.revision else {
            throw ReaderExtensionError.sourceNotFound
        }
        let approved = approvedDomains(for: sourceID)
        let targetIsApproved = ReaderExtensionSecurityPolicy.canonicalHost(of: url)
            .map(approved.contains) ?? false
        let requestHeaders = try ReaderExtensionResourceHeaderPolicy.merging([
            ["Accept": "image/avif,image/webp,image/*,*/*;q=0.8"],
            sourceHeaderMaterial.headers
        ])
        let response = try await authenticatedNetwork(for: sourceID).request(ReaderExtensionNetworkRequest(
            url: url,
            headers: requestHeaders,
            sourceID: sourceID,
            approvedDomains: approved,
            baseDomain: requestSource.baseURL.host,
            hostGeneratedOriginReferer: requestSource.baseURL,
            allowsCookies: targetIsApproved,
            redirectPolicy: targetIsApproved ? .approvedDomainsThenPublicHTTPS : .publicHTTPS,
            maximumResponseBytes: ReaderExtensionSecurityPolicy.maximumAssetResponseBytes
        ))
        guard (200...299).contains(response.statusCode) else {
            throw ReaderExtensionError.resultInvalid("asset returned HTTP \(response.statusCode)")
        }
        guard !response.body.isEmpty else {
            throw ReaderExtensionError.resultInvalid("asset response was empty")
        }
            return response
        } catch {
            ReaderExtensionDiagnostics.recordFailure(
                context: diagnosticContext,
                operation: "fetch-asset",
                error: error,
                type: ReaderExtensionDiagnostics.networkType,
                elapsedMs: ReaderExtensionDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            throw error
        }
    }

    func assetCacheScopeID() -> String {
        guard isAvailable else { return "" }
        return keychainNamespace
    }

    func reportURL(for sourceID: ReaderExtensionSourceID) -> URL? {
        guard isAvailable else { return nil }
        let sourceName = source(for: sourceID)?.name ?? catalogSource(for: sourceID)?.name ?? sourceID.rawValue
        var components = URLComponents(string: "https://github.com/Soupy-dev/Eclipse/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Reader source report: \(sourceName)"),
            URLQueryItem(name: "body", value: "Source ID: \(sourceID.rawValue)\n\nDescribe the source or content issue. Do not include cookies, credentials, page contents, or logs.")
        ]
        return components?.url
    }

    func provider(for sourceID: ReaderExtensionSourceID) throws -> any ReaderSourceProvider {
        try requireAvailability()
        try retryPendingAuthenticationCleanup(sourceID: sourceID)
        guard let source = source(for: sourceID), isMaturityAllowed(source.maturity) else {
            throw ReaderExtensionError.sourceNotFound
        }
        try ReaderExtensionProviderAdmissionPolicy.validate(source, requiresEnabled: true)
        return try makeProvider(
            source: source,
            network: authenticatedNetwork(for: sourceID),
            approvedDomains: approvedDomains(for: sourceID),
            requiresEnabled: true
        )
    }

    func configurationProvider(for sourceID: ReaderExtensionSourceID) throws -> any ReaderSourceProvider {
        try requireAvailability()
        try retryPendingAuthenticationCleanup(sourceID: sourceID)
        guard let source = source(for: sourceID) else { throw ReaderExtensionError.sourceNotFound }
        try ReaderExtensionProviderAdmissionPolicy.validate(source, requiresEnabled: false)
        return try makeProvider(
            source: source,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: approvedDomains(for: sourceID),
            requiresEnabled: false
        )
    }

    private func makeProvider(
        source: ReaderExtensionInstalledSource,
        network providerNetwork: ReaderExtensionNetworkClient,
        approvedDomains domains: Set<String>,
        requiresEnabled: Bool
    ) throws -> any ReaderSourceProvider {
        try ReaderExtensionProviderAdmissionPolicy.validate(source, requiresEnabled: requiresEnabled)
        let provider: any ReaderSourceProvider
        if source.implementation == .javascript {
            guard let digest = source.activeContentDigest, let contentStore else { throw ReaderExtensionError.runtimeUnavailable }
            let scopeID = keychainNamespace
            let preferenceStore = ReaderExtensionKeychainStore(
                sourceID: source.id,
                values: source.preferences,
                namespace: scopeID,
                schemaSecretKeys: source.secretPreferenceKeys,
                ordinaryValueWriter: { [weak self] key, value in
                    let completion = DispatchSemaphore(value: 0)
                    let result = ReaderExtensionSynchronousPreferenceWriteResult()
                    Task { @MainActor [weak self] in
                        defer { completion.signal() }
                        do {
                            guard let self, self.keychainNamespace == scopeID else {
                                throw ReaderExtensionError.persistenceFailed("Reader profile changed during preference write")
                            }
                            try self.persistRuntimePreference(value, for: key, sourceID: source.id)
                            result.set(.success(()))
                        } catch {
                            result.set(.failure(error))
                        }
                    }
                    guard completion.wait(timeout: .now() + 5) == .success else {
                        throw ReaderExtensionError.persistenceFailed("Preference persistence timed out")
                    }
                    try result.value.get()
                }
            )
            provider = try JavaScriptReaderProvider(
                source: source,
                scriptData: try contentStore.scriptData(digest: digest),
                network: providerNetwork,
                approvedDomains: domains,
                consentScopeID: keychainNamespace,
                preferenceStore: preferenceStore,
                runtimeIdentity: ReaderExtensionLanguageCompatibilityPolicy.runtimeIdentity(
                    for: source
                ),
                onRuntimeIntegrityFailure: { [weak self] sourceID, digest in
                    Task { @MainActor in self?.rollbackAfterRuntimeIntegrityFailure(sourceID: sourceID, failedDigest: digest) }
                }
            )
        } else {
            provider = try ReaderExtensionNativeProviderFactory.make(
                source: source,
                network: providerNetwork,
                approvedDomains: domains,
                consentScopeID: keychainNamespace
            )
        }
        return ReaderExtensionLoggingProvider(wrapping: provider)
    }

    func backupSnapshot() -> ReaderExtensionBackupSnapshot {
        guard isAvailable else {
            return ReaderExtensionBackupSnapshot(
                repositories: [],
                installedSources: [],
                showMatureSources: false,
                autoUpdateSources: true,
                lastAutoUpdate: nil
            )
        }
        let sources = installedSources.map { source -> ReaderExtensionInstalledSource in
            var copy = source.metadataForBackup()
            copy.preferences = copy.preferences.filter { key, _ in
                !source.secretPreferenceKeys.contains(key)
                    && !ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
            }
            return copy
        }
        return ReaderExtensionBackupSnapshot(
            repositories: repositories.map { repository in
                var copy = repository; copy.errorMessage = nil; return copy
            },
            installedSources: sources,
            showMatureSources: showMatureSources,
            autoUpdateSources: autoUpdateSources,
            lastAutoUpdate: lastAutoUpdate
        )
    }

    func capturePrivateCloudConfiguration(
        for profileID: UUID
    ) throws -> ReaderExtensionPrivateCloudConfiguration {
        try requireAvailability()
        guard ProfileManager.shared.rosterStoreIsReadable,
              ProfileManager.shared.profiles.contains(where: { $0.id == profileID })
                || profileID == ProfileManager.defaultProfileID else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        let sharesServices = ProfileSettingsStore.sharesServices
        let profileIDs = Set(ProfileManager.shared.profiles.map(\.id))
            .union([ProfileManager.defaultProfileID])
        let namespaceGeneration = ReaderExtensionAuthenticationGenerationRegistry
            .namespaceGeneration(profileID.uuidString)
        let profileStore = ProfileSettingsStore.shared.store(for: profileID)
        let metadataStore = sharesServices ? UserDefaults.standard : profileStore
        let configuration = try ReaderExtensionPersistence.capturePrivateCloudConfiguration(
            profileID: profileID,
            metadataStore: metadataStore,
            preferenceStore: profileStore
        )
        guard ProfileManager.shared.rosterStoreIsReadable,
              ProfileSettingsStore.sharesServices == sharesServices,
              Set(ProfileManager.shared.profiles.map(\.id))
                .union([ProfileManager.defaultProfileID]) == profileIDs,
              ReaderExtensionAuthenticationGenerationRegistry
                .namespaceGeneration(profileID.uuidString) == namespaceGeneration else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        return configuration
    }

    func applyPrivateCloudConfiguration(
        _ configuration: ReaderExtensionPrivateCloudConfiguration,
        for profileID: UUID
    ) throws {
        try requireAvailability()
        guard ProfileManager.shared.rosterStoreIsReadable,
              ProfileManager.shared.profiles.contains(where: { $0.id == profileID })
                || profileID == ProfileManager.defaultProfileID else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        let sharesServices = ProfileSettingsStore.sharesServices
        let profileIDs = Set(ProfileManager.shared.profiles.map(\.id))
            .union([ProfileManager.defaultProfileID])
        let activeProfileID = ProfileManager.shared.activeProfileID
        let namespaceGeneration = ReaderExtensionAuthenticationGenerationRegistry
            .namespaceGeneration(profileID.uuidString)
        let profileStore = ProfileSettingsStore.shared.store(for: profileID)
        let metadataStore = sharesServices ? UserDefaults.standard : profileStore
        try ReaderExtensionPersistence.applyPrivateCloudConfiguration(
            configuration,
            profileID: profileID,
            metadataStore: metadataStore,
            preferenceStore: profileStore
        )
        guard ProfileManager.shared.rosterStoreIsReadable,
              ProfileSettingsStore.sharesServices == sharesServices,
              Set(ProfileManager.shared.profiles.map(\.id))
                .union([ProfileManager.defaultProfileID]) == profileIDs,
              ProfileManager.shared.activeProfileID == activeProfileID,
              ReaderExtensionAuthenticationGenerationRegistry
                .namespaceGeneration(profileID.uuidString) == namespaceGeneration else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        if profileID == activeProfileID {
            _ = try reloadPersistedStateAfterRestore()
            for sourceID in installedSources.map(\.id) {
                NotificationCenter.default.post(
                    name: .readerExtensionAuthenticationDidChange,
                    object: sourceID
                )
            }
        }
    }

    func restoreMetadata(from snapshot: ReaderExtensionBackupSnapshot) async throws {
        try requireAvailability()
        try ReaderExtensionPersistence.restoreMetadata(
            snapshot,
            to: store,
            preferenceStore: ProfileSettingsStore.active,
            retainLegacyPreferencesInMetadata: !canStripLegacyPreferenceMetadata
        )
        _ = try reloadPersistedStateAfterRestore(invalidateRepositoryCatalogs: true)
    }

    @discardableResult
    func reloadPersistedStateAfterRestore(
        invalidateRepositoryCatalogs: Bool = false
    ) throws -> Bool {
        try requireAvailability()
        if invalidateRepositoryCatalogs {
            repositoryCatalogs.removeAll()
            catalogSources.removeAll()
        }
        let loadedRepositories = try ReaderExtensionPersistence.loadRepositories(from: store)
        let rawSources = try ReaderExtensionPersistence.loadInstalledSources(from: store)
        canStripLegacyPreferenceMetadata = try migrateLegacyPreferenceOverlaysIfPossible()
        let scopedSources = try ReaderExtensionPersistence.applyingPreferenceOverlay(
            to: rawSources,
            from: ProfileSettingsStore.active
        )
        let reconciled = ReaderExtensionPersistence.reconcileExecutableContent(
            scopedSources,
            contentStore: contentStore
        )
        var loadedSources = reconciled.sources.sorted { $0.sortIndex < $1.sortIndex }
        var movedLegacySecrets = false
        for index in loadedSources.indices {
            movedLegacySecrets = protectSecretPreferences(in: &loadedSources[index]) || movedLegacySecrets
        }

        let global = UserDefaults.standard
        let loadedShowMature = global.object(forKey: ReaderExtensionPersistence.showMatureSourcesKey) as? Bool ?? false
        let loadedAutoUpdate = global.object(forKey: ReaderExtensionPersistence.autoUpdateSourcesKey) as? Bool ?? true
        let loadedLastAutoUpdate = global.object(forKey: ReaderExtensionPersistence.lastAutoUpdateKey) as? Date
        let loadedBlockedSourceIDs: Set<ReaderExtensionSourceID>
        if let data = store.data(forKey: Self.blockedSourcesKey) {
            guard let ids = try? JSONDecoder().decode(Set<ReaderExtensionSourceID>.self, from: data) else {
                // Init fails closed on this exact corruption; a restore reload
                // must not fail open and silently resurrect blocked sources.
                throw ReaderExtensionError.persistenceFailed("Blocked source metadata is unreadable")
            }
            loadedBlockedSourceIDs = ids
        } else {
            loadedBlockedSourceIDs = []
        }

        // Repair corrupt/missing executable references before publishing the
        // candidate state to providers or SwiftUI. A failed metadata write
        // leaves the previously loaded in-memory state untouched.
        let shouldStripLegacyPreferences = canStripLegacyPreferenceMetadata
            && rawSources.contains(where: { !$0.preferences.isEmpty })
        let domainRollbacks = try applyStartupRollbackDomains(
            original: scopedSources,
            reconciled: loadedSources
        )
        do {
            if reconciled.changed || movedLegacySecrets || shouldStripLegacyPreferences {
                try ReaderExtensionPersistence.persist(
                    repositories: loadedRepositories,
                    installedSources: loadedSources,
                    showMature: loadedShowMature,
                    autoUpdate: loadedAutoUpdate,
                    lastAutoUpdate: loadedLastAutoUpdate,
                    to: store,
                    preferenceStore: ProfileSettingsStore.active,
                    retainLegacyPreferencesInMetadata: !canStripLegacyPreferenceMetadata
                )
            }
        } catch {
            for rollback in domainRollbacks.reversed() {
                try? rollback.store.setApprovedDomains(rollback.previousDomains)
            }
            throw error
        }

        let changed = repositories != loadedRepositories
            || installedSources != loadedSources
            || showMatureSources != loadedShowMature
            || autoUpdateSources != loadedAutoUpdate
            || lastAutoUpdate != loadedLastAutoUpdate
            || blockedSourceIDs != loadedBlockedSourceIDs
        if changed {
            pageRequests.removeAll()
            invalidateAllResourceHeaders()
        }
        repositories = loadedRepositories
        installedSources = loadedSources
        showMatureSources = loadedShowMature
        autoUpdateSources = loadedAutoUpdate
        lastAutoUpdate = loadedLastAutoUpdate
        blockedSourceIDs = loadedBlockedSourceIDs
        repositoryCatalogs = repositoryCatalogs.filter { entry in
            loadedRepositories.contains(where: { $0.id == entry.key })
        }
        rebuildCatalogSources()
        scheduleAutomaticCodeReacquisition(reason: "restore-reload")
        // This API is used as a restore-success gate. A validated no-op reload
        // is still a success and must not cause the caller to roll back.
        return true
    }

    @discardableResult
    func reloadAfterExternalRestore() throws -> Bool {
        try requireAvailability()
        return try reloadPersistedStateAfterRestore(invalidateRepositoryCatalogs: true)
    }

    private func loadCatalog(record: ReaderExtensionRepositoryRecord) async throws -> (record: ReaderExtensionRepositoryRecord, catalog: ReaderExtensionRepositoryCatalog) {
        let response = try await network.request(ReaderExtensionNetworkRequest(
            url: record.indexURL,
            sourceID: ReaderExtensionSourceID(rawValue: record.id),
            approvedDomains: ReaderExtensionSecurityPolicy.canonicalHosts([record.indexURL.host].compactMap { $0 }),
            baseDomain: record.indexURL.host,
            allowsCookies: false,
            redirectPolicy: .publicHTTPS
        ))
        guard (200...299).contains(response.statusCode) else { throw ReaderExtensionError.invalidManifest("repository returned HTTP \(response.statusCode)") }
        let provisional = try ReaderExtensionRepositoryCatalog.decode(
            data: response.body,
            indexURL: response.finalURL,
            repository: record
        )
        let license = detectLicense(
            catalog: provisional,
            resolvedIndexURL: response.finalURL
        )
        var updated = record
        updated.name = provisional.name ?? record.name
        updated.websiteURL = provisional.websiteURL ?? record.websiteURL
        updated.license = license
        updated.lastRefreshedAt = Date()
        updated.sourceCount = provisional.sources.count
        updated.errorMessage = nil
        var catalog = provisional
        catalog.sources = provisional.sources.map { source in
            var copy = source
            // A catalog's license does not license independently hosted JavaScript.
            // JavaScript is verified from its own file/repository when installed.
            copy.license = source.implementation == .javascript ? .unknown : license
            return copy
        }
        return (updated, catalog)
    }

    private func detectLicense(
        catalog: ReaderExtensionRepositoryCatalog,
        resolvedIndexURL: URL
    ) -> ReaderExtensionLicense {
        if let declared = catalog.declaredLicenseName {
            let kind = ReaderExtensionLicenseDetector.kind(nameOrText: declared)
            return ReaderExtensionLicense(
                kind: kind,
                name: declared,
                url: catalog.declaredLicenseURL,
                textSHA256: nil,
                detectedAt: Date()
            )
        }
        // Remote license probing used to add several sequential requests and
        // then repeat them after an unknown-license alert. License provenance
        // is no longer interactive; retain an explicit restrictive declaration
        // as an internal block and classify absence locally.
        return ReaderExtensionLicense(
            kind: .unknown,
            name: "Unknown",
            url: catalog.declaredLicenseURL ?? resolvedIndexURL,
            textSHA256: nil,
            detectedAt: Date()
        )
    }

    private func fetchJavaScriptArtifact(
        for catalog: ReaderExtensionCatalogSource,
        approvedDomains: Set<String>
    ) async throws -> ReaderExtensionJavaScriptArtifact {
        guard let codeURL = catalog.sourceCodeURL else { throw ReaderExtensionError.runtimeUnavailable }
        try ReaderExtensionSecurityPolicy.validateScriptURLSyntax(codeURL)
        let domains = installationDomains(catalog)
        guard domains.isSubset(of: approvedDomains) else {
            let host = domains.subtracting(approvedDomains).sorted().first ?? "source domain"
            ReaderExtensionDomainConsentCoordinator.emit(
                sourceID: catalog.id,
                host: host,
                scopeID: keychainNamespace
            )
            throw ReaderExtensionError.domainConsentRequired(host)
        }
        let response = try await network.request(ReaderExtensionNetworkRequest(
            url: codeURL,
            sourceID: catalog.id,
            approvedDomains: approvedDomains,
            baseDomain: catalog.baseURL.host,
            allowsCookies: false
        ))
        let acceptedCodeURL = try ReaderExtensionExecutableFetchPolicy.validatedFinalURL(
            requested: codeURL,
            response: response.finalURL
        )
        guard response.statusCode == 200 else {
            throw ReaderExtensionError.invalidManifest("script returned HTTP \(response.statusCode)")
        }
        _ = try ReaderExtensionSecurityPolicy.validateScript(response.body)
        let license = detectJavaScriptLicense(
            scriptData: response.body,
            codeURL: acceptedCodeURL
        )
        return ReaderExtensionJavaScriptArtifact(scriptData: response.body, license: license)
    }

    private func detectJavaScriptLicense(
        scriptData: Data,
        codeURL: URL
    ) -> ReaderExtensionLicense {
        let headerData = scriptData.prefix(64 * 1_024)
        if let rawHeader = String(data: headerData, encoding: .utf8) {
            let header = ReaderExtensionLicenseDetector.sourceHeader(in: rawHeader)
            let kind = ReaderExtensionLicenseDetector.kind(nameOrText: header)
            if kind != .unknown {
                let declaration = ReaderExtensionLicenseDetector.declaration(in: header, kind: kind)
                return ReaderExtensionLicense(
                    kind: kind,
                    name: ReaderExtensionLicenseDetector.displayName(
                        kind,
                        recognizedDeclaration: declaration
                    ),
                    url: codeURL,
                    textSHA256: SHA256.hash(data: Data(declaration.utf8)).map { String(format: "%02x", $0) }.joined(),
                    detectedAt: Date()
                )
            }
        }
        return ReaderExtensionLicense(kind: .unknown, name: "Unknown", url: codeURL, textSHA256: nil, detectedAt: Date())
    }

    private func installingScript(
        for source: ReaderExtensionInstalledSource,
        artifact: ReaderExtensionJavaScriptArtifact,
        approvedDomains: Set<String>,
        previous: ReaderExtensionInstalledSource?,
        allowScopeExpansion: Bool,
        mutationScope: ReaderExtensionManagerMutationScope
    ) async throws -> ReaderExtensionInstalledSource {
        guard let contentStore else { throw ReaderExtensionError.runtimeUnavailable }
        let staged = try contentStore.stageExactScript(artifact.scriptData)
        do {
            let validation = try await ReaderExtensionJavaScriptRuntime.bootstrapValidate(
                scriptData: artifact.scriptData,
                source: source
            )
            try validateMutationScope(mutationScope)
            if let previous, !allowScopeExpansion {
                let addedCapabilities = validation.capabilities.subtracting(previous.runtimeCapabilities)
                guard addedCapabilities.isEmpty else {
                    throw ReaderExtensionError.updateConsentRequired("the source's runtime capabilities")
                }
                let addedSecrets = validation.secretPreferenceKeys.subtracting(previous.secretPreferenceKeys)
                guard addedSecrets.isEmpty else {
                    throw ReaderExtensionError.updateConsentRequired("the source's secret preference access")
                }
            }
            let digest = try contentStore.activate(staged)
            var result = source
            result.license = artifact.license
            result.activeContentDigest = digest
            result.requiresReinstall = false
            result.updatedAt = Date()
            result.declaredDomains = approvedDomains
            result.runtimeCapabilities = validation.capabilities
            result.preferenceSchemaFingerprint = validation.preferenceSchemaFingerprint
            result.secretPreferenceKeys = validation.secretPreferenceKeys
            return result
        } catch {
            contentStore.discard(staged)
            throw error
        }
    }

    private func installationDomains(_ source: ReaderExtensionCatalogSource) -> Set<String> {
        ReaderExtensionSecurityPolicy.canonicalHosts(
            [source.repositoryURL.host, source.sourceCodeURL?.host, source.baseURL.host, source.apiURL?.host]
                .compactMap { $0 }
        )
    }

    private func installationDomains(_ source: ReaderExtensionInstalledSource) -> Set<String> {
        ReaderExtensionSecurityPolicy.canonicalHosts(
            [source.repositoryURL.host, source.sourceCodeURL?.host, source.baseURL.host, source.apiURL?.host]
                .compactMap { $0 }
        )
    }

    private func enforceLicense(_ license: ReaderExtensionLicense, allowUnknown _: Bool) throws {
        guard license.kind.permitsInstallation else { throw ReaderExtensionError.restrictiveLicense(license.name) }
    }

    private func rebuildCatalogSources() {
        var seen = Set<ReaderExtensionSourceID>()
        catalogSources = repositories.filter(\.isEnabled).flatMap { repositoryCatalogs[$0.id]?.sources ?? [] }.filter { seen.insert($0.id).inserted }
    }

    private func normalizedSortIndexes(
        _ sources: [ReaderExtensionInstalledSource]
    ) -> [ReaderExtensionInstalledSource] {
        var result = sources.sorted { $0.sortIndex < $1.sortIndex }
        for index in result.indices { result[index].sortIndex = index }
        return result
    }

    private func rollbackAfterRuntimeIntegrityFailure(sourceID: ReaderExtensionSourceID, failedDigest: String?) {
        guard let index = installedSources.firstIndex(where: { $0.id == sourceID }),
              installedSources[index].activeContentDigest == failedDigest else { return }
        var candidateSources = installedSources
        let restoredDomains: Set<String>?
        if let restored = installedSources[index].restoringLastKnownGood(afterFailureOf: failedDigest) {
            candidateSources[index] = restored
            restoredDomains = restored.declaredDomains
        } else {
            // A digest without its exact historical metadata is not a safe
            // rollback target: the old bytes must never run under the failed
            // update's URLs, license, capabilities, or preference schema.
            candidateSources[index].enabled = false
            candidateSources[index].rollbackContentDigest = nil
            candidateSources[index].rollbackSourceSnapshot = nil
            candidateSources[index].lastError = "The source was disabled after a runtime integrity failure."
            restoredDomains = nil
        }
        let approvalStores: [ReaderExtensionKeychainStore]
        if restoredDomains != nil {
            guard let stores = rollbackDomainStores(for: installedSources[index]) else { return }
            approvalStores = stores
        } else {
            approvalStores = []
        }
        var approvalRollbacks: [ApprovedDomainRollback] = []
        do {
            if let restoredDomains {
                for approvalStore in approvalStores {
                    let previous = approvalStore.approvedDomains()
                    guard previous != restoredDomains else { continue }
                    try approvalStore.setApprovedDomains(restoredDomains)
                    approvalRollbacks.append(ApprovedDomainRollback(
                        store: approvalStore,
                        previousDomains: previous
                    ))
                }
            }
            // Persist the entire candidate array first. In-memory provider state
            // changes only after the transactional metadata write verifies.
            try persist(installedSources: candidateSources)
            installedSources = candidateSources
            removePageRequests(for: sourceID)
            // A historical LKG snapshot is not fresh proof that its digest is
            // safe in every profile. Preserve any existing exact quarantine
            // marker; provider admission remains fail-closed until a later
            // globally unreferenced replacement/removal can clear it.
            removeUnreferencedContent()
        } catch {
            for rollback in approvalRollbacks.reversed() {
                try? rollback.store.setApprovedDomains(rollback.previousDomains)
            }
            // Keep the failed digest quarantined. A failed persistence write is
            // safer than exposing a process-only rollback that disappears on
            // relaunch or pairs old code with new metadata.
        }
    }

    private func persist() throws {
        try persist(installedSources: installedSources)
    }

    private func persist(installedSources candidateSources: [ReaderExtensionInstalledSource]) throws {
        try persist(repositories: repositories, installedSources: candidateSources)
    }

    private func persist(
        repositories candidateRepositories: [ReaderExtensionRepositoryRecord],
        installedSources candidateSources: [ReaderExtensionInstalledSource]
    ) throws {
        try persist(
            repositories: candidateRepositories,
            installedSources: candidateSources,
            showMature: showMatureSources,
            autoUpdate: autoUpdateSources,
            lastAutoUpdate: lastAutoUpdate
        )
    }

    private func persist(
        showMature candidateShowMature: Bool,
        autoUpdate candidateAutoUpdate: Bool,
        lastAutoUpdate candidateLastAutoUpdate: Date?
    ) throws {
        try persist(
            repositories: repositories,
            installedSources: installedSources,
            showMature: candidateShowMature,
            autoUpdate: candidateAutoUpdate,
            lastAutoUpdate: candidateLastAutoUpdate
        )
    }

    private func persist(
        repositories candidateRepositories: [ReaderExtensionRepositoryRecord],
        installedSources candidateSources: [ReaderExtensionInstalledSource],
        showMature candidateShowMature: Bool,
        autoUpdate candidateAutoUpdate: Bool,
        lastAutoUpdate candidateLastAutoUpdate: Date?
    ) throws {
        try requireAvailability()
        try ReaderExtensionPersistence.persist(
            repositories: candidateRepositories,
            installedSources: candidateSources,
            showMature: candidateShowMature,
            autoUpdate: candidateAutoUpdate,
            lastAutoUpdate: candidateLastAutoUpdate,
            to: store,
            preferenceStore: ProfileSettingsStore.active,
            retainLegacyPreferencesInMetadata: !canStripLegacyPreferenceMetadata
        )
    }

    private func migrateLegacyPreferenceOverlaysIfPossible() throws -> Bool {
        guard ProfileManager.shared.rosterStoreIsReadable else { return false }
        let sharedSources = try ReaderExtensionPersistence.loadInstalledSources(from: .standard)
        for profile in ProfileManager.shared.profiles {
            let profileStore = ProfileSettingsStore.shared.store(for: profile.id)
            let profileSources = try ReaderExtensionPersistence.loadInstalledSources(from: profileStore)
            var seeds = ProfileSettingsStore.sharesServices ? sharedSources : profileSources
            if ProfileSettingsStore.sharesServices, !profileSources.isEmpty {
                var profileValues: [ReaderExtensionSourceID: [String: ReaderExtensionPreferenceValue]] = [:]
                for source in profileSources { profileValues[source.id] = source.preferences }
                for index in seeds.indices {
                    if let values = profileValues[seeds[index].id], !values.isEmpty {
                        seeds[index].preferences = values
                    }
                }
            }
            try ReaderExtensionPersistence.seedPreferenceOverlayIfNeeded(
                from: seeds,
                to: profileStore
            )
        }
        return true
    }

    private func applyStartupRollbackDomains(
        original: [ReaderExtensionInstalledSource],
        reconciled: [ReaderExtensionInstalledSource]
    ) throws -> [ApprovedDomainRollback] {
        var originalByID: [ReaderExtensionSourceID: ReaderExtensionInstalledSource] = [:]
        for source in original { originalByID[source.id] = source }
        var applied: [ApprovedDomainRollback] = []
        do {
            for restored in reconciled {
                guard let failed = originalByID[restored.id],
                      failed.activeContentDigest != restored.activeContentDigest,
                      failed.rollbackSourceSnapshot?.activeContentDigest == restored.activeContentDigest else {
                    continue
                }
                guard let keychains = rollbackDomainStores(for: failed) else {
                    throw ReaderExtensionError.runtimeUnavailable
                }
                for keychain in keychains {
                    let previous = keychain.approvedDomains()
                    guard previous != restored.declaredDomains else { continue }
                    try keychain.setApprovedDomains(restored.declaredDomains)
                    applied.append(ApprovedDomainRollback(store: keychain, previousDomains: previous))
                }
            }
            return applied
        } catch {
            for rollback in applied.reversed() {
                try? rollback.store.setApprovedDomains(rollback.previousDomains)
            }
            throw error
        }
    }

    private func removalDeviceStateNamespaces() -> [String]? {
        ReaderExtensionProfileDeviceStatePolicy.removalNamespaces(
            sharesServices: ProfileSettingsStore.sharesServices,
            rosterStoreIsReadable: ProfileManager.shared.rosterStoreIsReadable,
            profileIDs: ProfileManager.shared.profiles.map(\.id),
            activeProfileID: ProfileManager.shared.activeProfileID
        )
    }

    @discardableResult
    private func enqueueAuthenticationCleanup(
        sourceIDs: [ReaderExtensionSourceID],
        namespaces: [String],
        kind: ReaderExtensionAuthenticationCleanupKind
    ) throws -> Set<ReaderExtensionPendingAuthenticationCleanup> {
        try ReaderExtensionAuthenticationCleanupJournal.enqueueSources(
            sourceIDs: sourceIDs,
            namespaces: namespaces,
            kind: kind,
            store: authenticationCleanupStore
        )
    }

    private func retryPendingAuthenticationCleanup(
        sourceID: ReaderExtensionSourceID
    ) throws {
        try retryPendingAuthenticationCleanup(
            sourceIDs: [sourceID],
            namespaces: [keychainNamespace]
        )
    }

    private func retryPendingAuthenticationCleanupForInstallation(
        sourceID: ReaderExtensionSourceID
    ) throws {
        guard let namespaces = removalDeviceStateNamespaces() else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        try retryPendingAuthenticationCleanup(
            sourceIDs: [sourceID],
            namespaces: Set(namespaces)
        )
    }

    /// Retries the bounded durable deletion journal. Successful entries are
    /// removed only after Keychain reports deletion and a fresh lookup verifies
    /// absence. Failed entries remain durable and the first failure is surfaced
    /// after all selected namespaces have had a chance to clean up.
    private func retryPendingAuthenticationCleanup(
        sourceIDs: Set<ReaderExtensionSourceID>? = nil,
        namespaces: Set<String>? = nil
    ) throws {
        let firstError = try ReaderExtensionAuthenticationCleanupJournal.retry(
            store: authenticationCleanupStore,
            sourceIDs: sourceIDs,
            namespaces: namespaces
        ) { entry in
            switch entry.kind {
            case .authentication:
                try ReaderExtensionKeychainStore(
                    sourceID: entry.sourceID,
                    namespace: entry.namespace
                ).removeAuthenticationState()
            case .deviceState:
                try ReaderExtensionKeychainStore(
                    sourceID: entry.sourceID,
                    namespace: entry.namespace
                ).removeAllDeviceState()
            case .namespaceDeviceState:
                try ReaderExtensionKeychainStore.removeAllDeviceState(
                    inNamespace: entry.namespace
                )
            }
        }
        if let firstError { throw firstError }
    }

    private func rollbackDomainStores(
        for source: ReaderExtensionInstalledSource
    ) -> [ReaderExtensionKeychainStore]? {
        removalDeviceStateNamespaces()?.map {
            ReaderExtensionKeychainStore(source: source, namespace: $0)
        }
    }

    private func persistRuntimePreference(
        _ value: ReaderExtensionPreferenceValue,
        for key: String,
        sourceID: ReaderExtensionSourceID
    ) throws {
        try requireAvailability()
        try ReaderExtensionSecurityPolicy.validatePreference(key: key, value: value)
        guard let index = installedSources.firstIndex(where: { $0.id == sourceID }) else {
            throw ReaderExtensionError.sourceNotFound
        }
        guard !installedSources[index].secretPreferenceKeys.contains(key),
              !ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key) else {
            throw ReaderExtensionError.persistenceFailed("Secret preference cannot be stored as metadata")
        }
        guard installedSources[index].preferences[key] != nil
                || installedSources[index].preferences.count < ReaderExtensionSecurityPolicy.maximumPreferenceCount else {
            throw ReaderExtensionError.contentTooLarge
        }
        let previous = installedSources[index].preferences[key]
        guard previous != value else { return }
        installedSources[index].preferences[key] = value
        do { try persist() }
        catch {
            installedSources[index].preferences[key] = previous
            throw error
        }
        removePageRequests(for: sourceID)
    }

    /// Moves any legacy ordinary value whose key is now known to be secret
    /// into device-only Keychain storage before that source can execute or be
    /// included in backup metadata. If Keychain is unexpectedly unavailable,
    /// the plaintext metadata is still removed and the source asks the user to
    /// sign in again instead of retaining/exporting the credential.
    @discardableResult
    private func protectSecretPreferences(
        in source: inout ReaderExtensionInstalledSource,
        namespace: String? = nil
    ) -> Bool {
        let originalPreferences = source.preferences
        var boundedPreferences: [String: ReaderExtensionPreferenceValue] = [:]
        for (key, value) in originalPreferences.prefix(ReaderExtensionSecurityPolicy.maximumPreferenceCount) {
            if value.isSecret {
                guard (try? ReaderExtensionSecurityPolicy.validatePreferenceSecret(key: key, value: nil)) != nil else { continue }
                // The metadata payload is only a marker. Never preserve a
                // caller-supplied secretReference payload as though it were a
                // credential value.
                boundedPreferences[key] = .secretReference(key)
            } else if (try? ReaderExtensionSecurityPolicy.validatePreference(key: key, value: value)) != nil {
                boundedPreferences[key] = value
            }
        }
        source.preferences = boundedPreferences
        var changed = source.preferences != originalPreferences
        let protectedKeys = Set(source.preferences.keys.filter {
            source.secretPreferenceKeys.contains($0)
                || ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey($0)
        })
        guard !protectedKeys.isEmpty else { return changed }
        let keychain = ReaderExtensionKeychainStore(
            source: source,
            namespace: namespace ?? keychainNamespace
        )
        for key in protectedKeys {
            guard let value = source.preferences[key], !value.isSecret else { continue }
            let secret: String
            switch value {
            case .string(let value): secret = value
            case .bool(let value): secret = String(value)
            case .number(let value): secret = String(value)
            case .stringList(let value): secret = value.joined(separator: "\n")
            case .secretReference: continue
            }
            do {
                try keychain.setSecret(secret, for: key)
            } catch {
                source.lastError = "Authentication must be entered again because secure storage was unavailable."
            }
            source.preferences[key] = .secretReference(key)
            changed = true
        }
        return changed
    }

    private func persistBlockedSources(
        _ candidate: Set<ReaderExtensionSourceID>
    ) throws {
        try requireAvailability()
        let previous = store.object(forKey: Self.blockedSourcesKey)
        do {
            let data = try JSONEncoder().encode(candidate)
            store.set(data, forKey: Self.blockedSourcesKey)
            guard store.data(forKey: Self.blockedSourcesKey) == data,
                  (try? JSONDecoder().decode(
                    Set<ReaderExtensionSourceID>.self,
                    from: data
                  )) == candidate else {
                throw ReaderExtensionError.persistenceFailed("blocked-source write verification failed")
            }
        } catch {
            if let previous { store.set(previous, forKey: Self.blockedSourcesKey) }
            else { store.removeObject(forKey: Self.blockedSourcesKey) }
            throw error
        }
    }

    private func removeUnreferencedContent() {
        guard isAvailable else { return }
        var stores: [UserDefaults] = [.standard]
        stores.append(contentsOf: ProfileManager.shared.profiles.map { ProfileSettingsStore.shared.store(for: $0.id) })
        guard let digests = ReaderExtensionContentRetentionPolicy.referencedDigests(
            rosterStoreIsReadable: ProfileManager.shared.rosterStoreIsReadable,
            stores: stores
        ) else { return }
        contentStore?.removeUnreferencedContent(
            keeping: digests.union(pendingInstallContent.retainedDigests)
        )
    }

    private func clearUnreferencedRuntimeQuarantine(
        sourceIDs: Set<ReaderExtensionSourceID>
    ) {
        guard isAvailable, !sourceIDs.isEmpty else { return }
        var stores: [UserDefaults] = [.standard]
        stores.append(contentsOf: ProfileManager.shared.profiles.map {
            ProfileSettingsStore.shared.store(for: $0.id)
        })
        guard let referenced = ReaderExtensionRuntimeQuarantineReferencePolicy.referencedEntries(
            rosterStoreIsReadable: ProfileManager.shared.rosterStoreIsReadable,
            stores: stores
        ) else { return }
        ReaderExtensionJavaScriptRuntime.clearQuarantineAfterVerifiedReplacementOrRemoval(
            sourceIDs: sourceIDs,
            retaining: referenced
        )
    }

    private static var currentScopeID: String {
        let metadataScope = ProfileSettingsStore.sharesServices ? "shared" : "profile"
        return "\(metadataScope):\(ProfileManager.shared.activeProfileID.uuidString)"
    }

    private func observeScopeChanges() {
        guard isAvailable else { return }
        NotificationCenter.default.publisher(for: .activeProfileDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in self?.reloadForScopeChangeIfNeeded() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.loadGlobalSettings()
                    self.reloadForScopeChangeIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    private func reloadForScopeChangeIfNeeded() {
        guard isAvailable else { return }
        let newScopeID = Self.currentScopeID
        guard newScopeID != loadedScopeID else {
            objectWillChange.send()
            return
        }
        let outgoingKeychainNamespace = loadedKeychainNamespace
        // A provider/client retained by a disappearing Reader profile must not
        // issue a second authenticated request after the app switches scopes.
        ReaderExtensionAuthenticationGenerationRegistry.revokeNamespace(
            outgoingKeychainNamespace
        )
        loadedScopeID = newScopeID
        loadedKeychainNamespace = keychainNamespace
        repositoryCatalogs.removeAll()
        catalogSources.removeAll()
        pageRequests.removeAll()
        invalidateAllResourceHeaders()
        ReaderExtensionItemSeedCache.clearAll()
        ReaderExtensionDomainConsentCoordinator.shared.resetForScopeChange()
        do {
            _ = try reloadPersistedStateAfterRestore()
            try? retryPendingAuthenticationCleanup()
        } catch {
            repositories = []
            installedSources = []
            blockedSourceIDs = []
            isAvailable = false
        }
        removeUnreferencedContent()
    }

    private func loadGlobalSettings() {
        guard isAvailable else { return }
        let global = UserDefaults.standard
        showMatureSources = global.object(forKey: ReaderExtensionPersistence.showMatureSourcesKey) as? Bool ?? false
        autoUpdateSources = global.object(forKey: ReaderExtensionPersistence.autoUpdateSourcesKey) as? Bool ?? true
        lastAutoUpdate = global.object(forKey: ReaderExtensionPersistence.lastAutoUpdateKey) as? Date
    }

    private func isMaturityAllowed(_ maturity: ReaderExtensionMaturity) -> Bool {
        guard isAvailable else { return false }
        if ProfileManager.shared.isKidsModeActive { return maturity == .safe }
        return maturity == .safe || showMatureSources
    }

    private func pageRequestRevision(for source: ReaderExtensionInstalledSource) -> String {
        "\(source.version)|\(source.codeProvenanceFingerprint)|\(source.activeContentDigest ?? "native")"
    }

    private func removePageRequests(for sourceID: ReaderExtensionSourceID) {
        pageRequests.remove(sourceID: sourceID)
        invalidateResourceHeaders(for: sourceID)
    }

    private func resourceHeaders(
        for source: ReaderExtensionInstalledSource,
        retryCount: Int = 1
    ) async throws -> (headers: [String: String], revision: String) {
        let revision = resourceHeaderRevision(for: source)
        guard source.implementation == .javascript else { return ([:], revision) }
        if let cached = resourceHeaderCache[source.id], cached.revision == revision {
            return (try cached.result.get(), revision)
        }

        let task: Task<Result<[String: String], ReaderExtensionError>, Never>
        if let existing = resourceHeaderLoads[source.id], existing.revision == revision {
            task = existing.task
        } else {
            let provider = try provider(for: source.id)
            task = Task {
                do {
                    return .success(try await provider.resourceHeaders())
                } catch let error as ReaderExtensionError {
                    switch error {
                    case .runtimeFailed, .resultInvalid, .contentTooLarge:
                        // getHeaders() is optional. A broken implementation
                        // should lose hotlink compatibility, not every image.
                        ReaderLogger.shared.log(
                            "Optional resource headers unavailable source=\(source.id.rawValue.prefix(12))",
                            type: "ReaderSandbox"
                        )
                        return .success([:])
                    default:
                        return .failure(error)
                    }
                } catch {
                    // Cancellation and unknown transport conditions are
                    // transient. Mapping them to a cacheable empty result
                    // silently stripped hotlink headers for the whole source
                    // revision after one unlucky load.
                    ReaderLogger.shared.log(
                        "Optional resource headers deferred source=\(source.id.rawValue.prefix(12))",
                        type: "ReaderSandbox"
                    )
                    return .failure(.runtimeUnavailable)
                }
            }
            resourceHeaderLoads[source.id] = ResourceHeaderLoad(
                revision: revision,
                task: task
            )
        }

        let result = await task.value
        if resourceHeaderLoads[source.id]?.revision == revision {
            resourceHeaderLoads.removeValue(forKey: source.id)
        }
        guard let currentSource = self.source(for: source.id),
              currentSource.enabled,
              currentSource.isRunnable,
              isMaturityAllowed(currentSource.maturity) else {
            throw ReaderExtensionError.sourceNotFound
        }
        let currentRevision = resourceHeaderRevision(for: currentSource)
        guard currentRevision == revision else {
            guard retryCount > 0 else { throw ReaderExtensionError.runtimeUnavailable }
            return try await resourceHeaders(for: currentSource, retryCount: retryCount - 1)
        }

        // Cache valid values and recoverable empty fallbacks. Security,
        // quarantine, and persistence failures remain retryable after their
        // owning recovery path succeeds.
        if case .success = result {
            resourceHeaderCache[source.id] = ResourceHeaderCacheEntry(
                revision: revision,
                result: result
            )
        }
        return (try result.get(), revision)
    }

    private func resourceHeaderRevision(for source: ReaderExtensionInstalledSource) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let preferences = (try? encoder.encode(source.preferences)) ?? Data()
        let fields = [
            loadedScopeID,
            keychainNamespace,
            String(resourceHeaderGlobalGeneration),
            String(resourceHeaderSourceGenerations[source.id, default: 0]),
            source.upstreamID,
            source.name,
            source.baseURL.absoluteString,
            source.apiURL?.absoluteString ?? "",
            source.effectiveLanguage,
            source.mediaType.rawValue,
            source.version,
            source.dateFormat ?? "",
            source.dateFormatLocale ?? "",
            source.additionalParameters ?? "",
            source.codeProvenanceFingerprint,
            source.activeContentDigest ?? "native",
            source.preferenceSchemaFingerprint ?? "",
            source.secretPreferenceKeys.sorted().joined(separator: "\u{1f}")
        ].joined(separator: "\u{1e}")
        var material = Data(fields.utf8)
        material.append(preferences)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    private func invalidateResourceHeaders(for sourceID: ReaderExtensionSourceID) {
        resourceHeaderCache.removeValue(forKey: sourceID)
        // Do not cancel an executing JavaScript operation. Removing the load
        // reference plus advancing the revision prevents its result from being
        // cached or used after a preference/authentication mutation.
        resourceHeaderLoads.removeValue(forKey: sourceID)
        resourceHeaderSourceGenerations[sourceID, default: 0] &+= 1
        NotificationCenter.default.post(
            name: .readerExtensionResourceHeadersDidChange,
            object: sourceID
        )
    }

    private func invalidateAllResourceHeaders() {
        resourceHeaderCache.removeAll(keepingCapacity: true)
        resourceHeaderLoads.removeAll(keepingCapacity: true)
        resourceHeaderSourceGenerations.removeAll(keepingCapacity: true)
        resourceHeaderGlobalGeneration &+= 1
        NotificationCenter.default.post(
            name: .readerExtensionResourceHeadersDidChange,
            object: nil
        )
    }
}

enum ReaderExtensionProfileDeviceStatePolicy {
    static func removalNamespaces(
        sharesServices: Bool,
        rosterStoreIsReadable: Bool,
        profileIDs: [UUID],
        activeProfileID: UUID
    ) -> [String]? {
        guard !sharesServices || rosterStoreIsReadable else { return nil }
        let ids = sharesServices ? profileIDs : [activeProfileID]
        return Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }.map(\.uuidString)
    }
}

enum ReaderExtensionProviderAdmissionPolicy {
    static func validate(
        _ source: ReaderExtensionInstalledSource,
        requiresEnabled: Bool = true
    ) throws {
        guard source.license.kind.permitsInstallation else {
            throw ReaderExtensionError.restrictiveLicense(source.license.name)
        }
        guard (!requiresEnabled || source.enabled),
              !source.requiresReinstall,
              source.implementation != .unsupportedNative,
              source.implementation != .javascript || source.activeContentDigest != nil else {
            throw ReaderExtensionError.sourceNotFound
        }
    }
}

private struct ReaderExtensionJavaScriptArtifact {
    let scriptData: Data
    let license: ReaderExtensionLicense
}

enum ReaderExtensionDurableMutation {
    /// Publishes state and performs irreversible cleanup only after the caller's
    /// persistence transaction succeeds. This keeps process state aligned with
    /// what a relaunch will load when storage is unavailable or rejects a write.
    static func commit<State>(
        candidate: State,
        persist: (State) throws -> Void,
        publish: (State) -> Void,
        afterCommit: () -> Void = {}
    ) throws {
        try persist(candidate)
        publish(candidate)
        afterCommit()
    }

    /// Coordinates metadata with a secondary durable store such as Keychain.
    /// The secondary write never runs when metadata persistence fails. If it
    /// fails after metadata succeeds, the caller restores the prior persisted
    /// snapshot and this method deliberately leaves live state unpublished.
    static func commitCoordinated<State>(
        candidate: State,
        persist: (State) throws -> Void,
        applySecondary: () throws -> Void,
        rollbackPersistence: () -> Void,
        publish: (State) -> Void,
        afterCommit: () -> Void = {}
    ) throws {
        try persist(candidate)
        do {
            try applySecondary()
        } catch {
            rollbackPersistence()
            throw error
        }
        publish(candidate)
        afterCommit()
    }
}

enum ReaderExtensionExecutableFetchPolicy {
    static func validatedFinalURL(requested: URL, response: URL) throws -> URL {
        try ReaderExtensionSecurityPolicy.validateScriptURLSyntax(response)
        guard ReaderExtensionURLCanonicalizer.canonicalString(requested)
                == ReaderExtensionURLCanonicalizer.canonicalString(response) else {
            throw ReaderExtensionError.invalidManifest(
                "executable source redirected to a different owner or path"
            )
        }
        return response
    }
}

enum ReaderExtensionLicenseFetchPolicy {
    /// License discovery is an implementation detail of adding or refreshing
    /// a repository, not consent to contact another operator. Restrict both a
    /// manifest-declared candidate and its final redirect URL to the canonical
    /// HTTPS origin that the user explicitly entered.
    static func allowsCandidate(_ candidate: URL, owner: URL) -> Bool {
        guard (try? ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
            candidate,
            requireHTTPS: true
        )) != nil,
        candidate.query == nil,
        candidate.fragment == nil else { return false }
        return canonicalOrigin(candidate) == canonicalOrigin(owner)
    }

    private static func canonicalOrigin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = ReaderExtensionSecurityPolicy.canonicalHost(of: url) else { return nil }
        return "\(scheme)://\(host):\(url.port ?? 443)"
    }
}

enum ReaderExtensionLicenseUpdatePolicy {
    /// Backup restoration may require same-version catalog revalidation, but
    /// it is never consent to a different license or license provenance. The
    /// normal explicit update confirmation remains mandatory for every change.
    static func validateTransition(
        from previous: ReaderExtensionLicense,
        to incoming: ReaderExtensionLicense,
        allowScopeExpansion: Bool
    ) throws {
        guard incoming.provenanceFingerprint == previous.provenanceFingerprint
                || allowScopeExpansion else {
            throw ReaderExtensionError.updateConsentRequired("the source license")
        }
    }
}

enum ReaderExtensionLicenseDetector {
    static func fetchedLicense(
        data: Data,
        finalURL: URL,
        unknownName: String = "Unknown"
    ) -> ReaderExtensionLicense? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let detectedKind = kind(nameOrText: text)
        return ReaderExtensionLicense(
            kind: detectedKind,
            name: detectedKind == .unknown ? unknownName : displayName(detectedKind),
            url: finalURL,
            textSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            detectedAt: Date()
        )
    }

    static func kind(nameOrText input: String) -> ReaderExtensionLicenseKind {
        let value = normalized(input)
        // Additional field-of-use, redistribution, or modification terms are
        // incompatible with a canonical permissive grant. They win even when
        // a permissive license name or SPDX token appears elsewhere.
        if containsStrongAdditionalRestriction(value) { return .restrictive }

        switch exactSPDXDeclaration(in: input) {
        case .valid(let declaration):
            if value.contains("all rights reserved"), declaration.kind != .bsd2,
               declaration.kind != .bsd3 {
                return .restrictive
            }
            return declaration.kind
        case .invalid:
            return .unknown
        case .absent:
            break
        }

        if let canonical = canonicalBodyKind(in: input, normalized: value) {
            return canonical
        }
        if value.contains("all rights reserved") { return .restrictive }
        return .unknown
    }

    static func declaration(in text: String, kind: ReaderExtensionLicenseKind) -> String {
        if case .valid(let declaration) = exactSPDXDeclaration(in: text),
           declaration.kind == kind {
            return declaration.provenanceText
        }
        // Canonical bodies are already validated by `kind`; bind provenance to
        // their bounded normalized bytes rather than collapsing every owner or
        // notice to the enum case.
        return normalized(text)
    }

    private struct SPDXDeclaration {
        let kind: ReaderExtensionLicenseKind
        let identifier: String
        let provenanceText: String
    }

    private enum SPDXResult {
        case absent
        case invalid
        case valid(SPDXDeclaration)
    }

    private static func exactSPDXDeclaration(in text: String) -> SPDXResult {
        let marker = "spdx-license-identifier:"
        let bareDeclaration = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bareDeclaration.isEmpty,
           bareDeclaration.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           let kind = kind(forExactSPDXIdentifier: bareDeclaration) {
            return .valid(SPDXDeclaration(
                kind: kind,
                identifier: bareDeclaration.lowercased(),
                provenanceText: "spdx-license-identifier: \(bareDeclaration)"
            ))
        }

        let cleanedLines = text.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine -> String in
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "*/" { return "" }
            for prefix in ["//", "#", "/*", "*"] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            if line.hasSuffix("*/") {
                line = String(line.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return line
        }
        let relevant = cleanedLines.filter { $0.lowercased().contains(marker) }
        guard !relevant.isEmpty else { return .absent }
        guard cleanedLines.allSatisfy({ line in
            let lower = line.lowercased()
            return line.isEmpty || lower.hasPrefix(marker) || lower.hasPrefix("copyright")
                || lower.hasPrefix("©") || lower.hasPrefix("!/")
        }) else {
            // SPDX is conclusive only as an exact declaration. Other license
            // prose must validate as a canonical body rather than being
            // silently ignored as additional terms.
            return .invalid
        }
        var detected: ReaderExtensionLicenseKind?
        var detectedIdentifier: String?
        for line in relevant {
            guard line.lowercased().hasPrefix(marker) else { return .invalid }
            let identifier = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty,
                  identifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  let kind = kind(forExactSPDXIdentifier: identifier) else { return .invalid }
            if let detected, detected != kind { return .invalid }
            let normalizedIdentifier = identifier.lowercased()
            if let detectedIdentifier, detectedIdentifier != normalizedIdentifier { return .invalid }
            detected = kind
            detectedIdentifier = normalizedIdentifier
        }
        guard let detected, let detectedIdentifier else { return .invalid }
        let provenanceLines = cleanedLines.compactMap { line -> String? in
            let lower = line.lowercased()
            guard lower.hasPrefix(marker) || lower.hasPrefix("copyright")
                    || lower.hasPrefix("©") else { return nil }
            return line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        guard !provenanceLines.isEmpty else { return .invalid }
        return .valid(SPDXDeclaration(
            kind: detected,
            identifier: detectedIdentifier,
            provenanceText: provenanceLines.joined(separator: "\n")
        ))
    }

    private static func kind(forExactSPDXIdentifier identifier: String) -> ReaderExtensionLicenseKind? {
        switch identifier.lowercased() {
        case "apache-2.0": return .apache2
        case "mit": return .mit
        case "bsd-2-clause": return .bsd2
        case "bsd-3-clause": return .bsd3
        case "isc": return .isc
        case "mpl-2.0": return .mpl2
        case "gpl-3.0", "gpl-3.0-only", "gpl-3.0-or-later": return .gpl3
        default: return nil
        }
    }

    private static func spdxIdentifier(for kind: ReaderExtensionLicenseKind) -> String? {
        switch kind {
        case .apache2: return "Apache-2.0"
        case .mit: return "MIT"
        case .bsd2: return "BSD-2-Clause"
        case .bsd3: return "BSD-3-Clause"
        case .isc: return "ISC"
        case .mpl2: return "MPL-2.0"
        case .gpl3: return "GPL-3.0-or-later"
        case .restrictive, .unknown: return nil
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201c}", with: "\"")
            .replacingOccurrences(of: "\u{201d}", with: "\"")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func containsStrongAdditionalRestriction(_ value: String) -> Bool {
        [
            "no redistribution", "redistribution prohibited", "may not redistribute",
            "may not distribute", "no derivatives", "no derivative works",
            "derivative works prohibited", "may not modify", "modification prohibited",
            "non-commercial", "noncommercial", "non commercial", "not for commercial use",
            "commercial use prohibited", "may not be used commercially", "personal use only",
            "source available only", "proprietary license", "commons clause"
        ].contains(where: value.contains)
    }

    private static func canonicalBodyKind(
        in original: String,
        normalized value: String
    ) -> ReaderExtensionLicenseKind? {
        if containsAll([
            "apache license version 2.0, january 2004",
            "terms and conditions for use, reproduction, and distribution",
            "grant of copyright license",
            "limitations under the license"
        ], in: value), hasCanonicalTerminal(in: value, markers: ["limitations under the license.", "end of terms and conditions"]) {
            return .apache2
        }
        if containsAll([
            "permission is hereby granted, free of charge, to any person obtaining a copy",
            "to deal in the software without restriction",
            "the above copyright notice and this permission notice shall be included",
            "the software is provided \"as is\", without warranty"
        ], in: value), hasAllowedPreamble(in: original, bodyMarker: "permission is hereby granted", titles: ["mit license"]),
           hasCanonicalTerminal(in: value, markers: ["other dealings in the software."]) {
            return .mit
        }
        if containsAll([
            "redistribution and use in source and binary forms, with or without modification, are permitted",
            "neither the name of the copyright holder nor the names of its contributors",
            "this software is provided by the copyright holders and contributors \"as is\""
        ], in: value), hasCanonicalTerminal(in: value, markers: ["possibility of such damage.", "possibility of such damages."]) {
            return .bsd3
        }
        if containsAll([
            "redistribution and use in source and binary forms, with or without modification, are permitted",
            "redistributions of source code must retain the above copyright notice",
            "redistributions in binary form must reproduce the above copyright notice",
            "this software is provided by the copyright holders and contributors \"as is\""
        ], in: value), hasCanonicalTerminal(in: value, markers: ["possibility of such damage.", "possibility of such damages."]) {
            return .bsd2
        }
        if containsAll([
            "permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted",
            "the software is provided \"as is\" and the author disclaims all warranties"
        ], in: value), hasAllowedPreamble(in: original, bodyMarker: "permission to use, copy, modify", titles: ["isc license"]),
           hasCanonicalTerminal(in: value, markers: ["arising from, out of or in connection with the use or performance of this software."]) {
            return .isc
        }
        if containsAll([
            "mozilla public license version 2.0",
            "1. definitions",
            "2. source code form license grants",
            "exhibit b - \"incompatible with secondary licenses\" notice"
        ], in: value), hasCanonicalTerminal(in: value, markers: ["incompatible with secondary licenses."]) {
            return .mpl2
        }
        if containsAll([
            "gnu general public license",
            "version 3, 29 june 2007",
            "terms and conditions",
            "end of terms and conditions"
        ], in: value), hasCanonicalTerminal(in: value, markers: ["later version.", "end of terms and conditions"]) {
            return .gpl3
        }
        return nil
    }

    private static func containsAll(_ phrases: [String], in value: String) -> Bool {
        phrases.allSatisfy(value.contains)
    }

    private static func hasCanonicalTerminal(in value: String, markers: [String]) -> Bool {
        for marker in markers {
            guard let range = value.range(of: marker, options: .backwards) else { continue }
            let suffix = value[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if suffix.isEmpty { return true }
        }
        return false
    }

    private static func hasAllowedPreamble(in text: String, bodyMarker: String, titles: [String]) -> Bool {
        var reachedBody = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            if lower.contains(bodyMarker) { reachedBody = true; break }
            guard line.isEmpty || lower.hasPrefix("copyright") || lower.hasPrefix("©")
                    || titles.contains(lower) else { return false }
        }
        return reachedBody
    }

    static func sourceHeader(in text: String) -> String {
        var result: [String] = []
        var insideBlockComment = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(256) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if insideBlockComment {
                result.append(line)
                if trimmed.contains("*/") { insideBlockComment = false }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("#!") {
                result.append(line)
                continue
            }
            if trimmed.hasPrefix("/*") {
                result.append(line)
                insideBlockComment = !trimmed.contains("*/")
                continue
            }
            break
        }
        return result.joined(separator: "\n")
    }

    static func displayName(
        _ kind: ReaderExtensionLicenseKind,
        recognizedDeclaration: String? = nil
    ) -> String {
        switch kind {
        case .apache2: return "Apache License 2.0"
        case .mit: return "MIT License"
        case .bsd2: return "BSD 2-Clause"
        case .bsd3: return "BSD 3-Clause"
        case .isc: return "ISC License"
        case .mpl2: return "Mozilla Public License 2.0"
        case .gpl3:
            let declaration = recognizedDeclaration?.lowercased() ?? ""
            if declaration.contains("gpl-3.0-only") { return "GNU GPL v3 only" }
            if declaration.contains("gpl-3.0-or-later") { return "GNU GPL v3 or later" }
            return "GNU GPL v3"
        case .restrictive: return "Restrictive"
        case .unknown: return "Unknown"
        }
    }

    static func candidateURLs(indexURL: URL, declared: URL?) -> [URL] {
        var result = declared.map { [$0] } ?? []
        if ReaderExtensionSecurityPolicy.canonicalHost(of: indexURL) == "raw.githubusercontent.com" {
            let parts = indexURL.pathComponents.filter { $0 != "/" }
            if parts.count >= 3 {
                var components = URLComponents(); components.scheme = "https"; components.host = "raw.githubusercontent.com"
                components.path = "/\(parts[0])/\(parts[1])/\(parts[2])/LICENSE"
                if let url = components.url { result.append(url) }
            }
        }
        result.append(indexURL.deletingLastPathComponent().appendingPathComponent("LICENSE"))
        result.append(indexURL.deletingLastPathComponent().appendingPathComponent("LICENSE.txt"))
        var seen = Set<String>()
        return result.filter { seen.insert($0.absoluteString).inserted }
    }
}

enum ReaderExtensionVersion {
    private struct SemanticVersion {
        struct Identifier {
            let text: String
            let isNumeric: Bool
        }

        let major: UInt64
        let minor: UInt64
        let patch: UInt64
        let prerelease: [Identifier]
    }

    /// SemVer 2.0 precedence. Returns nil when either side is malformed so
    /// callers cannot guess an ordering from arbitrary digits in a label.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = parse(lhs), let right = parse(rhs) else { return nil }
        for (l, r) in [(left.major, right.major), (left.minor, right.minor), (left.patch, right.patch)] {
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        if left.prerelease.isEmpty, right.prerelease.isEmpty { return .orderedSame }
        if left.prerelease.isEmpty { return .orderedDescending }
        if right.prerelease.isEmpty { return .orderedAscending }
        for index in 0..<min(left.prerelease.count, right.prerelease.count) {
            let l = left.prerelease[index], r = right.prerelease[index]
            switch (l.isNumeric, r.isNumeric) {
            case (true, true):
                if l.text.count < r.text.count { return .orderedAscending }
                if l.text.count > r.text.count { return .orderedDescending }
                let order = l.text.compare(r.text, options: .literal)
                if order != .orderedSame { return order }
            case (true, false):
                return .orderedAscending
            case (false, true):
                return .orderedDescending
            case (false, false):
                let order = l.text.compare(r.text, options: .literal)
                if order != .orderedSame { return order }
            }
        }
        if left.prerelease.count < right.prerelease.count { return .orderedAscending }
        if left.prerelease.count > right.prerelease.count { return .orderedDescending }
        return .orderedSame
    }

    static func isStrictlyNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    private static func parse(_ raw: String) -> SemanticVersion? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 128 else { return nil }
        let pattern = "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let majorRange = Range(match.range(at: 1), in: value),
              let minorRange = Range(match.range(at: 2), in: value),
              let patchRange = Range(match.range(at: 3), in: value),
              let major = UInt64(value[majorRange]),
              let minor = UInt64(value[minorRange]),
              let patch = UInt64(value[patchRange]) else { return nil }
        var identifiers: [SemanticVersion.Identifier] = []
        if match.range(at: 4).location != NSNotFound, let range = Range(match.range(at: 4), in: value) {
            for rawIdentifier in value[range].split(separator: ".", omittingEmptySubsequences: false) {
                let text = String(rawIdentifier)
                let numeric = text.allSatisfy(\.isNumber)
                if numeric && text.count > 1 && text.first == "0" { return nil }
                identifiers.append(.init(text: text, isNumeric: numeric))
            }
        }
        return SemanticVersion(major: major, minor: minor, patch: patch, prerelease: identifiers)
    }
}

private final class ReaderExtensionSynchronousPreferenceWriteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Void, Error>?

    func set(_ value: Result<Void, Error>) {
        lock.lock(); stored = value; lock.unlock()
    }

    var value: Result<Void, Error> {
        lock.lock(); defer { lock.unlock() }
        return stored ?? .failure(ReaderExtensionError.persistenceFailed("Preference persistence did not complete"))
    }
}
