// Copyright 2026 Eclipse contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ReaderExtensionPersistence {
    static let repositoriesKey = "readerExtensions.repositories.v1"
    static let installedSourcesKey = "readerExtensions.installedSources.v1"
    static let showMatureSourcesKey = "readerExtensions.showMatureSources.v1"
    static let autoUpdateSourcesKey = "readerExtensions.autoUpdateSources.v1"
    static let lastAutoUpdateKey = "readerExtensions.lastAutoUpdate.v1"
    static let approvedDomainsKey = "readerExtensions.approvedDomains.v1"
    static let preferenceOverlayKey = "readerExtensions.preferenceOverlay.v1"
    static let preferenceOverlayMigrationKey = "readerExtensions.preferenceOverlayMigrated.v1"
    static let pendingAuthenticationCleanupKey = "readerExtensions.pendingAuthenticationCleanup.v1"
    static let runtimeQuarantineKey = "readerExtensions.runtimeQuarantine.v1"
    static let maximumRepositoryCount = 100
    static let maximumInstalledSourceCount = 1_000
    private static let maximumPreferenceOverlayBytes = 4 * 1_024 * 1_024
    private static let maximumAuthenticationCleanupBytes = 512 * 1_024
    private static let maximumAuthenticationCleanupEntries = 6_000
    private static let maximumRepositoryMetadataBytes = 2 * 1_024 * 1_024
    private static let maximumInstalledSourceMetadataBytes = 12 * 1_024 * 1_024
    private static let maximumAggregateMetadataBytes = 16 * 1_024 * 1_024
    private static let maximumRuntimeQuarantineBytes = 512 * 1_024
    private static let maximumRuntimeQuarantineEntries = 4_000
    private static let runtimeQuarantineLock = NSLock()

    /// Bounds the local service-store object graph before Foundation decodes
    /// it. The decoded model/schema checks below remain authoritative.
    static func validateRepositoryStoreJSON(_ data: Data) throws {
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: maximumRepositoryMetadataBytes,
            maximumDepth: 8,
            maximumContainerEntries: 128,
            maximumTopLevelEntries: maximumRepositoryCount,
            maximumTotalTokens: 20_000,
            maximumStringBytes: 32 * 1_024
        ))
    }

    /// Shared with legacy reconnect preflight, which reads the same installed
    /// source payload directly rather than through `loadInstalledSources`.
    static func validateInstalledSourceStoreJSON(_ data: Data) throws {
        try validateInstalledSourceStoreJSON(
            data,
            maximumBytes: maximumInstalledSourceMetadataBytes
        )
    }

    static func validateInstalledSourceStoreJSON(_ data: Data, maximumBytes: Int) throws {
        guard maximumBytes > 0,
              maximumBytes <= maximumInstalledSourceMetadataBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: maximumBytes,
            maximumDepth: 12,
            maximumContainerEntries: 256,
            maximumTopLevelEntries: maximumInstalledSourceCount,
            maximumTotalTokens: Swift.min(2_000_000, Swift.max(1, maximumBytes / 4)),
            // Persisted values are validated to 16 KiB after decoding; allow
            // the bounded JSON escape expansion emitted by JSONEncoder.
            maximumStringBytes: 32 * 1_024
        ))
    }

    static func loadRepositories(from store: UserDefaults) throws -> [ReaderExtensionRepositoryRecord] {
        guard let data = store.data(forKey: repositoriesKey) else { return [] }
        guard data.count <= maximumRepositoryMetadataBytes else { throw ReaderExtensionError.contentTooLarge }
        try validateRepositoryStoreJSON(data)
        let repositories = try decode([ReaderExtensionRepositoryRecord].self, data: data)
        try validateCollectionCounts(repositories: repositories, sources: [])
        return repositories
    }

    static func loadInstalledSources(from store: UserDefaults) throws -> [ReaderExtensionInstalledSource] {
        guard let data = store.data(forKey: installedSourcesKey) else { return [] }
        guard data.count <= maximumInstalledSourceMetadataBytes else { throw ReaderExtensionError.contentTooLarge }
        try validateInstalledSourceStoreJSON(data)
        let sources = try decode([ReaderExtensionInstalledSource].self, data: data)
        try validateCollectionCounts(repositories: [], sources: sources)
        return sources
    }

    static func loadRuntimeQuarantine(
        from store: UserDefaults = .standard
    ) throws -> Set<ReaderExtensionRuntimeQuarantineEntry> {
        try runtimeQuarantineLock.withReaderExtensionPersistenceLock {
            try loadRuntimeQuarantineUnlocked(from: store)
        }
    }

    static func runtimeQuarantineContains(
        sourceID: ReaderExtensionSourceID,
        digest: String,
        in store: UserDefaults = .standard,
        fileStore providedFileStore: ReaderExtensionRuntimeQuarantineFileStore? = nil
    ) throws -> Bool {
        let entry = ReaderExtensionRuntimeQuarantineEntry(sourceID: sourceID, digest: digest)
        if try loadRuntimeQuarantine(from: store).contains(entry) { return true }
        let fileStore = try providedFileStore ?? ReaderExtensionRuntimeQuarantineFileStore()
        return try fileStore.contains(entry)
    }

    static func runtimeQuarantineEntries(
        in store: UserDefaults = .standard,
        fileStore providedFileStore: ReaderExtensionRuntimeQuarantineFileStore? = nil
    ) throws -> Set<ReaderExtensionRuntimeQuarantineEntry> {
        let metadataEntries = try loadRuntimeQuarantine(from: store)
        let fileStore = try providedFileStore ?? ReaderExtensionRuntimeQuarantineFileStore()
        return metadataEntries.union(try fileStore.entries())
    }

    static func markRuntimeQuarantined(
        sourceID: ReaderExtensionSourceID,
        digest: String,
        in store: UserDefaults = .standard,
        fileStore providedFileStore: ReaderExtensionRuntimeQuarantineFileStore? = nil,
        checkpoint: (UserDefaults) -> Bool = { $0.synchronize() }
    ) throws {
        let entry = ReaderExtensionRuntimeQuarantineEntry(sourceID: sourceID, digest: digest)
        var fileError: Error?
        do {
            let fileStore = try providedFileStore ?? ReaderExtensionRuntimeQuarantineFileStore()
            try fileStore.mark(entry)
        } catch {
            fileError = error
        }
        var metadataError: Error?
        runtimeQuarantineLock.withReaderExtensionPersistenceLock {
            do {
                var entries = try loadRuntimeQuarantineUnlocked(from: store)
                entries.insert(entry)
                try persistRuntimeQuarantineUnlocked(entries, to: store, checkpoint: checkpoint)
            } catch {
                metadataError = error
            }
        }
        // Either independently durable representation is sufficient. Total
        // storage failure is surfaced while the Runtime also retains its
        // process-local deny entry.
        if fileError != nil, let metadataError { throw metadataError }
    }

    static func clearRuntimeQuarantine(
        sourceIDs: Set<ReaderExtensionSourceID>,
        in store: UserDefaults = .standard,
        fileStore providedFileStore: ReaderExtensionRuntimeQuarantineFileStore? = nil,
        checkpoint: (UserDefaults) -> Bool = { $0.synchronize() }
    ) throws {
        guard !sourceIDs.isEmpty else { return }
        try runtimeQuarantineLock.withReaderExtensionPersistenceLock {
            var entries = try loadRuntimeQuarantineUnlocked(from: store)
            entries = Set(entries.filter { !sourceIDs.contains($0.sourceID) })
            try persistRuntimeQuarantineUnlocked(entries, to: store, checkpoint: checkpoint)
        }
        let fileStore = try providedFileStore ?? ReaderExtensionRuntimeQuarantineFileStore()
        try fileStore.clear(sourceIDs: sourceIDs)
    }

    static func clearRuntimeQuarantine(
        sourceID: ReaderExtensionSourceID,
        digest: String,
        in store: UserDefaults = .standard,
        fileStore providedFileStore: ReaderExtensionRuntimeQuarantineFileStore? = nil,
        checkpoint: (UserDefaults) -> Bool = { $0.synchronize() }
    ) throws {
        let entry = ReaderExtensionRuntimeQuarantineEntry(sourceID: sourceID, digest: digest)
        try runtimeQuarantineLock.withReaderExtensionPersistenceLock {
            var entries = try loadRuntimeQuarantineUnlocked(from: store)
            entries.remove(entry)
            try persistRuntimeQuarantineUnlocked(entries, to: store, checkpoint: checkpoint)
        }
        let fileStore = try providedFileStore ?? ReaderExtensionRuntimeQuarantineFileStore()
        try fileStore.clear(entry)
    }

    static func runtimeQuarantineIsReadable(in store: UserDefaults = .standard) -> Bool {
        guard (try? loadRuntimeQuarantine(from: store)) != nil,
              let fileStore = try? ReaderExtensionRuntimeQuarantineFileStore() else { return false }
        return fileStore.isReadable
    }

    static func loadPendingAuthenticationCleanup(
        from store: UserDefaults
    ) throws -> Set<ReaderExtensionPendingAuthenticationCleanup> {
        guard let data = store.data(forKey: pendingAuthenticationCleanupKey) else { return [] }
        guard data.count <= maximumAuthenticationCleanupBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        let entries = try JSONDecoder().decode([ReaderExtensionPendingAuthenticationCleanup].self, from: data)
        guard entries.count <= maximumAuthenticationCleanupEntries,
              entries.allSatisfy(\.isValid),
              Set(entries).count == entries.count else {
            throw ReaderExtensionError.persistenceFailed("pending authentication cleanup metadata is invalid")
        }
        return Set(entries)
    }

    static func persistPendingAuthenticationCleanup(
        _ candidate: Set<ReaderExtensionPendingAuthenticationCleanup>,
        to store: UserDefaults,
        checkpoint: (UserDefaults) -> Bool = { $0.synchronize() }
    ) throws {
        guard candidate.count <= maximumAuthenticationCleanupEntries,
              candidate.allSatisfy(\.isValid) else {
            throw ReaderExtensionError.contentTooLarge
        }
        let ordered = candidate.sorted(by: ReaderExtensionPendingAuthenticationCleanup.isOrderedBefore)
        let data = try encode(ordered)
        guard data.count <= maximumAuthenticationCleanupBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        let previous = store.object(forKey: pendingAuthenticationCleanupKey)
        do {
            if ordered.isEmpty {
                store.removeObject(forKey: pendingAuthenticationCleanupKey)
                guard checkpoint(store),
                      store.object(forKey: pendingAuthenticationCleanupKey) == nil else {
                    throw ReaderExtensionError.persistenceFailed("pending authentication cleanup removal verification failed")
                }
            } else {
                store.set(data, forKey: pendingAuthenticationCleanupKey)
                guard checkpoint(store),
                      store.data(forKey: pendingAuthenticationCleanupKey) == data,
                      try loadPendingAuthenticationCleanup(from: store) == candidate else {
                    throw ReaderExtensionError.persistenceFailed("pending authentication cleanup write verification failed")
                }
            }
        } catch {
            if let previous { store.set(previous, forKey: pendingAuthenticationCleanupKey) }
            else { store.removeObject(forKey: pendingAuthenticationCleanupKey) }
            _ = checkpoint(store)
            throw error
        }
    }

    static func pendingAuthenticationCleanupIsReadable(in store: UserDefaults) -> Bool {
        (try? loadPendingAuthenticationCleanup(from: store)) != nil
    }

    static func metadataIsReadable(
        in store: UserDefaults,
        preferenceStore: UserDefaults
    ) -> Bool {
        do {
            let aggregateBytes = (store.data(forKey: repositoriesKey)?.count ?? 0)
                + (store.data(forKey: installedSourcesKey)?.count ?? 0)
                + (preferenceStore.data(forKey: preferenceOverlayKey)?.count ?? 0)
            guard aggregateBytes <= maximumAggregateMetadataBytes else { return false }
            let repositories = try loadRepositories(from: store)
            let sources = try loadInstalledSources(from: store)
            guard sanitizeRepositories(repositories).count == repositories.count,
                  sanitizeSources(sources).count == sources.count else { return false }
            _ = try applyingPreferenceOverlay(to: sources, from: preferenceStore)
            guard runtimeQuarantineIsReadable() else { return false }
            return true
        } catch {
            return false
        }
    }

    static func capturePrivateCloudConfiguration(
        profileID: UUID,
        metadataStore: UserDefaults,
        preferenceStore: UserDefaults,
        keychain: any ReaderExtensionKeychainAccess = ReaderExtensionSystemKeychainAccess()
    ) throws -> ReaderExtensionPrivateCloudConfiguration {
        let namespace = profileID.uuidString
        try requirePrivateCloudAuthenticationIsStable(namespace: namespace)
        let metadataSources = try loadInstalledSources(from: metadataStore)
        let sources = try applyingPreferenceOverlay(
            to: metadataSources,
            from: preferenceStore
        )
        guard sanitizeSources(sources) == sources else {
            throw ReaderExtensionError.persistenceFailed("Reader source configuration is unreadable")
        }
        let stores = Dictionary(uniqueKeysWithValues: sources.map { source in
            (
                source.id,
                ReaderExtensionKeychainStore(
                    sourceID: source.id,
                    values: source.preferences,
                    namespace: namespace,
                    schemaSecretKeys: source.secretPreferenceKeys,
                    keychain: keychain
                )
            )
        })
        let captured = try ReaderExtensionAuthenticationGenerationRegistry
            .withPrivateCloudConfigurationReadFence {
                try sources.sorted { $0.id.rawValue < $1.id.rawValue }.map { source in
                    guard let keychainStore = stores[source.id] else {
                        throw ReaderExtensionError.persistenceFailed("Reader source configuration changed")
                    }
                    let ordinary = try privateCloudOrdinaryPreferences(for: source)
                    let keychainConfiguration = try keychainStore
                        .privateCloudConfigurationUnlocked()
                    try validatePrivateCloudKeychainConfiguration(
                        keychainConfiguration,
                        for: source
                    )
                    return ReaderExtensionPrivateCloudSourceConfiguration(
                        source: source,
                        ordinaryPreferences: ordinary,
                        keychain: keychainConfiguration
                    )
                }
            }
        try requirePrivateCloudAuthenticationIsStable(namespace: namespace)
        let configuration = ReaderExtensionPrivateCloudConfiguration(
            profileID: profileID,
            sources: captured
        )
        try ReaderExtensionPrivateCloudConfigurationPolicy.validate(configuration)
        return configuration
    }

    static func applyPrivateCloudConfiguration(
        _ configuration: ReaderExtensionPrivateCloudConfiguration,
        profileID: UUID,
        metadataStore: UserDefaults,
        preferenceStore: UserDefaults,
        keychain: any ReaderExtensionKeychainAccess = ReaderExtensionSystemKeychainAccess(),
        previousSources: [ReaderExtensionInstalledSource] = [],
        postMutationVerification: (() throws -> Void)? = nil
    ) throws {
        guard configuration.profileID == profileID else {
            throw ReaderExtensionError.persistenceFailed("Reader private-cloud profile does not match")
        }
        try ReaderExtensionPrivateCloudConfigurationPolicy.validate(configuration)
        let namespace = profileID.uuidString
        try requirePrivateCloudAuthenticationIsStable(namespace: namespace)
        let metadataSources = try loadInstalledSources(from: metadataStore)
        let sources = try applyingPreferenceOverlay(
            to: metadataSources,
            from: preferenceStore
        )
        guard sanitizeSources(sources) == sources else {
            throw ReaderExtensionError.persistenceFailed("Reader source configuration is unreadable")
        }
        guard sanitizeSources(previousSources) == previousSources else {
            throw ReaderExtensionError.persistenceFailed("Previous Reader source configuration is unreadable")
        }
        let currentByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let incomingByID = Dictionary(
            uniqueKeysWithValues: configuration.sources.map { ($0.sourceID, $0) }
        )
        guard configuration.sources.allSatisfy({ incoming in
            currentByID[incoming.sourceID].map {
                ReaderExtensionPrivateCloudConfigurationPolicy.identityMatches(
                    incoming,
                    source: $0
                )
            } == true
        }) else {
            throw ReaderExtensionError.persistenceFailed("Reader private-cloud source does not match")
        }

        var targetSources = sources
        var targetKeychain: [ReaderExtensionSourceID: ReaderExtensionPrivateCloudKeychainConfiguration] = [:]
        for index in targetSources.indices {
            let source = targetSources[index]
            let incoming = incomingByID[source.id]
            let keychainConfiguration = incoming?.keychain ?? .empty
            try validatePrivateCloudKeychainConfiguration(
                keychainConfiguration,
                for: source
            )
            let ordinary = incoming?.ordinaryPreferences ?? [:]
            for key in ordinary.keys where source.secretPreferenceKeys.contains(key) {
                throw ReaderExtensionError.persistenceFailed("Reader secret preference used ordinary storage")
            }
            var preferences = ordinary
            for key in keychainConfiguration.secrets.keys {
                preferences[key] = .secretReference(key)
            }
            targetSources[index].preferences = preferences
            targetKeychain[source.id] = keychainConfiguration
        }
        guard sanitizeSources(targetSources) == targetSources else {
            throw ReaderExtensionError.persistenceFailed("Reader private-cloud configuration is invalid")
        }

        let removedSources = previousSources.filter { currentByID[$0.id] == nil }
        let transactionSources = (sources + removedSources).sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        for source in removedSources {
            targetKeychain[source.id] = .empty
        }
        let stores = Dictionary(uniqueKeysWithValues: transactionSources.map { source in
            (
                source.id,
                ReaderExtensionKeychainStore(
                    sourceID: source.id,
                    values: source.preferences,
                    namespace: namespace,
                    schemaSecretKeys: source.secretPreferenceKeys,
                    keychain: keychain
                )
            )
        })
        let previousOverlayData = preferenceStore.object(forKey: preferenceOverlayKey)
        let previousOverlayMarker = preferenceStore.object(forKey: preferenceOverlayMigrationKey)
        try ReaderExtensionAuthenticationGenerationRegistry
            .withPrivateCloudConfigurationMutationFence(
                sourceIDs: Set(transactionSources.map(\.id)),
                namespace: namespace
            ) {
                var previousKeychain: [ReaderExtensionSourceID: ReaderExtensionPrivateCloudKeychainConfiguration] = [:]
                for source in transactionSources {
                    guard let keychainStore = stores[source.id] else {
                        throw ReaderExtensionError.persistenceFailed("Reader source configuration changed")
                    }
                    previousKeychain[source.id] = try keychainStore
                        .privateCloudConfigurationUnlocked()
                }
                do {
                    for source in transactionSources {
                        guard let keychainStore = stores[source.id],
                              let target = targetKeychain[source.id] else {
                            throw ReaderExtensionError.persistenceFailed("Reader source configuration changed")
                        }
                        try keychainStore.replacePrivateCloudConfigurationUnlocked(target)
                    }
                    try writePreferenceOverlay(
                        preferenceOverlayPayload(from: targetSources),
                        to: preferenceStore
                    )
                    let persistedSources = try applyingPreferenceOverlay(
                        to: try loadInstalledSources(from: metadataStore),
                        from: preferenceStore
                    )
                    guard Dictionary(uniqueKeysWithValues: persistedSources.map {
                        ($0.id, $0.preferences)
                    }) == Dictionary(uniqueKeysWithValues: targetSources.map {
                        ($0.id, $0.preferences)
                    }) else {
                        throw ReaderExtensionError.persistenceFailed("Reader preference restore verification failed")
                    }
                    for source in transactionSources {
                        guard let keychainStore = stores[source.id],
                              try keychainStore.privateCloudConfigurationUnlocked()
                                == targetKeychain[source.id] else {
                            throw ReaderExtensionError.persistenceFailed("Reader secure configuration restore verification failed")
                        }
                    }
                    try postMutationVerification?()
                } catch {
                    var rollbackError: Error?
                    for source in transactionSources.reversed() {
                        guard let keychainStore = stores[source.id],
                              let previous = previousKeychain[source.id] else { continue }
                        do {
                            try keychainStore.replacePrivateCloudConfigurationUnlocked(previous)
                        } catch {
                            if rollbackError == nil { rollbackError = error }
                        }
                    }
                    if let previousOverlayData {
                        preferenceStore.set(previousOverlayData, forKey: preferenceOverlayKey)
                    } else {
                        preferenceStore.removeObject(forKey: preferenceOverlayKey)
                    }
                    if let previousOverlayMarker {
                        preferenceStore.set(previousOverlayMarker, forKey: preferenceOverlayMigrationKey)
                    } else {
                        preferenceStore.removeObject(forKey: preferenceOverlayMigrationKey)
                    }
                    if let rollbackError { throw rollbackError }
                    throw error
                }
            }
    }

    private static func requirePrivateCloudAuthenticationIsStable(
        namespace: String
    ) throws {
        let pending = try loadPendingAuthenticationCleanup(from: .standard)
        guard !pending.contains(where: {
            $0.namespace == namespace
        }) else {
            throw ReaderExtensionError.persistenceFailed("Reader authentication cleanup is pending")
        }
    }

    private static func privateCloudOrdinaryPreferences(
        for source: ReaderExtensionInstalledSource
    ) throws -> [String: ReaderExtensionPreferenceValue] {
        guard source.preferences.count <= ReaderExtensionSecurityPolicy.maximumPreferenceCount else {
            throw ReaderExtensionError.contentTooLarge
        }
        var ordinary: [String: ReaderExtensionPreferenceValue] = [:]
        for (key, value) in source.preferences {
            if case .secretReference(let reference) = value {
                guard reference == key,
                      source.secretPreferenceKeys.contains(key)
                        || ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key) else {
                    throw ReaderExtensionError.persistenceFailed("Reader secret preference metadata is invalid")
                }
                continue
            }
            guard !source.secretPreferenceKeys.contains(key),
                  !ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key) else {
                throw ReaderExtensionError.persistenceFailed("Reader credential preference used ordinary storage")
            }
            try ReaderExtensionSecurityPolicy.validatePreference(key: key, value: value)
            ordinary[key] = value
        }
        return ordinary
    }

    private static func validatePrivateCloudKeychainConfiguration(
        _ configuration: ReaderExtensionPrivateCloudKeychainConfiguration,
        for source: ReaderExtensionInstalledSource
    ) throws {
        guard configuration.secrets.keys.allSatisfy({ key in
            source.secretPreferenceKeys.contains(key)
                || ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
        }) else {
            throw ReaderExtensionError.persistenceFailed("Reader secret preference schema does not match")
        }
        for (key, value) in configuration.secrets {
            try ReaderExtensionSecurityPolicy.validatePreferenceSecret(key: key, value: value)
        }
        let userApprovedDomains = Set(configuration.userApprovedDomains)
        guard configuration.userApprovedDomains.count
                <= ReaderExtensionPrivateCloudConfigurationPolicy.maximumApprovedDomainCount,
              userApprovedDomains.count == configuration.userApprovedDomains.count,
              ReaderExtensionSecurityPolicy.canonicalHosts(
                userApprovedDomains
              ) == userApprovedDomains,
              configuration.userApprovedDomains == userApprovedDomains.sorted(),
              userApprovedDomains.allSatisfy({ host in
                  guard let url = ReaderExtensionSecurityPolicy.canonicalHTTPSURL(forHost: host)
                  else { return false }
                  return (try? ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
                      url,
                      requireHTTPS: true
                  )) != nil
              }) else {
            throw ReaderExtensionError.insecureURL
        }
    }

    /// Validates that executable metadata is backed by the exact bytes it
    /// names before a source can become runnable. A complete, valid LKG
    /// snapshot is restored as one unit; digest-only historical metadata is
    /// never paired with the failed update's URLs, license, or capabilities.
    static func reconcileExecutableContent(
        _ input: [ReaderExtensionInstalledSource],
        contentStore: ReaderExtensionContentStore?
    ) -> (sources: [ReaderExtensionInstalledSource], changed: Bool) {
        // Failure to open Application Support is transient and must never be
        // interpreted as every executable disappearing. The Manager stays
        // inert in this state and retries on a later process launch.
        guard let contentStore else { return (input, false) }
        var sources = sanitizeSources(input)
        var changed = sources != input

        func hasExactBytes(_ digest: String?, sourceID: ReaderExtensionSourceID) -> Bool {
            guard let digest,
                  (try? runtimeQuarantineContains(sourceID: sourceID, digest: digest)) == false else {
                return false
            }
            return (try? contentStore.scriptData(digest: digest)) != nil
        }

        for index in sources.indices where sources[index].implementation == .javascript {
            let activeIsValid = hasExactBytes(
                sources[index].activeContentDigest,
                sourceID: sources[index].id
            )
            let rollbackIsValid = hasExactBytes(
                sources[index].rollbackSourceSnapshot?.activeContentDigest,
                sourceID: sources[index].id
            )

            if activeIsValid {
                if sources[index].rollbackSourceSnapshot != nil, !rollbackIsValid {
                    sources[index].rollbackSourceSnapshot = nil
                    sources[index].rollbackContentDigest = nil
                    changed = true
                }
                continue
            }

            let failedDigest = sources[index].activeContentDigest
            if rollbackIsValid,
               let restored = sources[index].restoringLastKnownGood(afterFailureOf: failedDigest) {
                sources[index] = restored
            } else {
                sources[index].activeContentDigest = nil
                sources[index].rollbackContentDigest = nil
                sources[index].rollbackSourceSnapshot = nil
                sources[index].requiresReinstall = true
                sources[index].lastError = "The installed source code is missing or failed integrity validation. Reinstall the source to continue."
            }
            changed = true
        }
        return (sources, changed)
    }

    static func backupSnapshot(
        from store: UserDefaults,
        preferenceStore: UserDefaults? = nil
    ) throws -> ReaderExtensionBackupSnapshot {
        let global = UserDefaults.standard
        let metadataSources = try loadInstalledSources(from: store)
        let sources = if let preferenceStore {
            try applyingPreferenceOverlay(to: metadataSources, from: preferenceStore)
        } else {
            metadataSources
        }
        return ReaderExtensionBackupSnapshot(
            repositories: sanitizeRepositories(try loadRepositories(from: store)).map { repository in
                var copy = repository
                copy.errorMessage = nil
                return copy
            },
            installedSources: sources.map(sanitizedBackupMetadata),
            showMatureSources: global.object(forKey: showMatureSourcesKey) as? Bool ?? false,
            autoUpdateSources: global.object(forKey: autoUpdateSourcesKey) as? Bool ?? true,
            lastAutoUpdate: global.object(forKey: lastAutoUpdateKey) as? Date
        )
    }

    static func restoreMetadata(
        _ snapshot: ReaderExtensionBackupSnapshot,
        to store: UserDefaults,
        preferenceStore: UserDefaults? = nil,
        retainLegacyPreferencesInMetadata: Bool = false
    ) throws {
        try validateCollectionCounts(repositories: snapshot.repositories, sources: snapshot.installedSources)
        try validateRestorableLicenses(in: snapshot)
        let repositories = sanitizeRepositories(snapshot.repositories)
        let sources = sanitizeSources(snapshot.installedSources).map(sanitizedBackupMetadata)
        try transactionalWrite(
            repositories: repositories,
            sources: sources,
            showMature: snapshot.showMatureSources,
            autoUpdate: snapshot.autoUpdateSources,
            lastAutoUpdate: snapshot.lastAutoUpdate,
            to: store,
            preferenceStore: preferenceStore,
            retainLegacyPreferencesInMetadata: retainLegacyPreferencesInMetadata
        )
    }

    /// Restores portable backup metadata while retaining executable state only
    /// from the caller's already reconciled, device-local source records. Raw
    /// digests or runnable flags in `snapshot` are always cleared first; the
    /// matching policy then copies only code-coupled runtime fields from an
    /// exact local identity match.
    static func restorePortableMetadata(
        _ snapshot: ReaderExtensionBackupSnapshot,
        retainingVerifiedRuntimeFrom verifiedLocalSources: [ReaderExtensionInstalledSource],
        to store: UserDefaults,
        preferenceStore: UserDefaults? = nil,
        retainLegacyPreferencesInMetadata: Bool = false
    ) throws {
        try validateCollectionCounts(repositories: snapshot.repositories, sources: snapshot.installedSources)
        try validateCollectionCounts(repositories: [], sources: verifiedLocalSources)
        try validateRestorableLicenses(in: snapshot)
        let repositories = sanitizeRepositories(snapshot.repositories)
        // This conversion is unconditional. It makes this API safe even if a
        // caller accidentally passes decoded raw backup metadata containing a
        // crafted digest or requiresReinstall=false assertion.
        let portableSources = sanitizeSources(snapshot.installedSources).map(sanitizedBackupMetadata)
        let localSources = sanitizeSources(verifiedLocalSources)
        let sources = retainingVerifiedRuntime(in: portableSources, from: localSources)
        try transactionalWrite(
            repositories: repositories,
            sources: sources,
            showMature: snapshot.showMatureSources,
            autoUpdate: snapshot.autoUpdateSources,
            lastAutoUpdate: snapshot.lastAutoUpdate,
            to: store,
            preferenceStore: preferenceStore,
            retainLegacyPreferencesInMetadata: retainLegacyPreferencesInMetadata
        )
    }

    /// Compares backup metadata in the exact Codable shape persisted by this
    /// store. Date values are normalized to millisecond precision while Sets
    /// retain semantic equality independent of encoded array ordering.
    static func metadataSnapshotsArePersistenceEquivalent(
        _ lhs: ReaderExtensionBackupSnapshot,
        _ rhs: ReaderExtensionBackupSnapshot
    ) -> Bool {
        guard let normalizedLHS: ReaderExtensionBackupSnapshot = try? roundTrip(lhs),
              let normalizedRHS: ReaderExtensionBackupSnapshot = try? roundTrip(rhs) else {
            return false
        }
        return normalizedLHS == normalizedRHS
    }

    static func persist(
        repositories: [ReaderExtensionRepositoryRecord],
        installedSources: [ReaderExtensionInstalledSource],
        showMature: Bool,
        autoUpdate: Bool,
        lastAutoUpdate: Date?,
        to store: UserDefaults,
        preferenceStore: UserDefaults? = nil,
        retainLegacyPreferencesInMetadata: Bool = false
    ) throws {
        try validateCollectionCounts(repositories: repositories, sources: installedSources)
        let sanitizedRepositories = sanitizeRepositories(repositories)
        let sanitizedSources = sanitizeSources(installedSources)
        guard sanitizedRepositories.count == repositories.count,
              sanitizedSources.count == installedSources.count else {
            throw ReaderExtensionError.persistenceFailed("Reader Extension metadata failed validation")
        }
        try transactionalWrite(
            repositories: sanitizedRepositories,
            sources: sanitizedSources,
            showMature: showMature,
            autoUpdate: autoUpdate,
            lastAutoUpdate: lastAutoUpdate,
            to: store,
            preferenceStore: preferenceStore,
            retainLegacyPreferencesInMetadata: retainLegacyPreferencesInMetadata
        )
    }

    static func applyingPreferenceOverlay(
        to sources: [ReaderExtensionInstalledSource],
        from preferenceStore: UserDefaults
    ) throws -> [ReaderExtensionInstalledSource] {
        let hasMigrationMarker = preferenceStore.bool(forKey: preferenceOverlayMigrationKey)
        guard let data = preferenceStore.data(forKey: preferenceOverlayKey) else {
            if !hasMigrationMarker { return sources }
            return sources.map { source in
                var copy = source
                copy.preferences = [:]
                return copy
            }
        }
        guard data.count <= maximumPreferenceOverlayBytes else {
            throw ReaderExtensionError.persistenceFailed("preference overlay is too large")
        }
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: maximumPreferenceOverlayBytes,
            maximumDepth: 8,
            // The `values` dictionary may contain one entry for each installed
            // source. Per-source preference maps and string lists are capped
            // more tightly by the semantic sanitizer after decoding.
            maximumContainerEntries: maximumInstalledSourceCount,
            maximumTopLevelEntries: 4,
            maximumTotalTokens: 512_000,
            // Ordinary preference values are capped at 16 KiB after decode;
            // permit bounded JSON escaping without admitting giant strings.
            maximumStringBytes: 32 * 1_024
        ))
        let payload = try JSONDecoder().decode(ReaderExtensionPreferenceOverlayPayload.self, from: data)
        guard payload.values.count <= 1_000 else { throw ReaderExtensionError.contentTooLarge }
        return sources.map { source in
            var copy = source
            if let values = payload.values[source.id.rawValue] {
                copy.preferences = sanitizedPreferenceMetadata(for: copy, values: values)
            } else {
                copy.preferences = [:]
            }
            return copy
        }
    }

    /// Seeds legacy embedded preferences exactly once for a profile. Callers
    /// migrate every readable profile before stripping shared metadata so the
    /// old shared behavior becomes an explicit starting value, then diverges
    /// safely per profile.
    @discardableResult
    static func seedPreferenceOverlayIfNeeded(
        from legacySources: [ReaderExtensionInstalledSource],
        to preferenceStore: UserDefaults
    ) throws -> Bool {
        guard !preferenceStore.bool(forKey: preferenceOverlayMigrationKey) else { return false }
        try validateCollectionCounts(repositories: [], sources: legacySources)
        let payload = preferenceOverlayPayload(from: sanitizeSources(legacySources))
        try writePreferenceOverlay(payload, to: preferenceStore)
        return true
    }

    private static func transactionalWrite(
        repositories: [ReaderExtensionRepositoryRecord],
        sources: [ReaderExtensionInstalledSource],
        showMature: Bool,
        autoUpdate: Bool,
        lastAutoUpdate: Date?,
        to store: UserDefaults,
        preferenceStore: UserDefaults?,
        retainLegacyPreferencesInMetadata: Bool
    ) throws {
        try validateCollectionCounts(repositories: repositories, sources: sources)
        let metadataKeys = [repositoriesKey, installedSourcesKey]
        let globalKeys = [showMatureSourcesKey, autoUpdateSourcesKey, lastAutoUpdateKey]
        let global = UserDefaults.standard
        let previousMetadata = Dictionary(uniqueKeysWithValues: metadataKeys.map { ($0, store.object(forKey: $0)) })
        let previousGlobal = Dictionary(uniqueKeysWithValues: globalKeys.map { ($0, global.object(forKey: $0)) })
        let previousOverlay = preferenceStore.map {
            (
                data: $0.object(forKey: preferenceOverlayKey),
                marker: $0.object(forKey: preferenceOverlayMigrationKey)
            )
        }
        do {
            let repositoryData = try encode(repositories)
            let metadataSources = sources.map { source -> ReaderExtensionInstalledSource in
                guard preferenceStore != nil, !retainLegacyPreferencesInMetadata else { return source }
                var copy = source
                copy.preferences = [:]
                return copy
            }
            let sourceData = try encode(metadataSources)
            guard repositoryData.count <= maximumRepositoryMetadataBytes,
                  sourceData.count <= maximumInstalledSourceMetadataBytes,
                  repositoryData.count + sourceData.count <= maximumAggregateMetadataBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            let overlayData: Data?
            if let preferenceStore {
                let payload = preferenceOverlayPayload(from: sources)
                let encoded = try encode(payload)
                guard encoded.count <= maximumPreferenceOverlayBytes else { throw ReaderExtensionError.contentTooLarge }
                preferenceStore.set(encoded, forKey: preferenceOverlayKey)
                preferenceStore.set(true, forKey: preferenceOverlayMigrationKey)
                overlayData = encoded
            } else {
                overlayData = nil
            }
            guard repositoryData.count + sourceData.count + (overlayData?.count ?? 0)
                    <= maximumAggregateMetadataBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            store.set(repositoryData, forKey: repositoriesKey)
            store.set(sourceData, forKey: installedSourcesKey)
            global.set(showMature, forKey: showMatureSourcesKey)
            global.set(autoUpdate, forKey: autoUpdateSourcesKey)
            if let lastAutoUpdate { global.set(lastAutoUpdate, forKey: lastAutoUpdateKey) }
            else { global.removeObject(forKey: lastAutoUpdateKey) }
            if store !== global {
                globalKeys.forEach(store.removeObject(forKey:))
            }

            let persistedMetadataSources = try loadInstalledSources(from: store)
            let reconstructedSources = if let preferenceStore {
                try applyingPreferenceOverlay(to: persistedMetadataSources, from: preferenceStore)
            } else {
                persistedMetadataSources
            }
            // JSON persistence rounds Date values to milliseconds. Compare the
            // reconstructed records against the same encoded/decoded shape,
            // while retaining semantic Set equality so nondeterministic Set
            // array ordering cannot produce a false verification failure.
            let expectedReconstructedSources: [ReaderExtensionInstalledSource] = try roundTrip(sources)

            guard store.data(forKey: repositoriesKey) == repositoryData,
                  store.data(forKey: installedSourcesKey) == sourceData,
                  (try? loadRepositories(from: store)) != nil,
                  (try? loadInstalledSources(from: store)) != nil,
                  global.object(forKey: showMatureSourcesKey) as? Bool == showMature,
                  global.object(forKey: autoUpdateSourcesKey) as? Bool == autoUpdate,
                  global.object(forKey: lastAutoUpdateKey) as? Date == lastAutoUpdate,
                  preferenceStore.map({ overlayStore in
                    overlayStore.data(forKey: preferenceOverlayKey) == overlayData
                        && overlayStore.bool(forKey: preferenceOverlayMigrationKey)
                  }) ?? true,
                  reconstructedSources == expectedReconstructedSources else {
                throw ReaderExtensionError.persistenceFailed("write verification failed")
            }
        } catch {
            for key in metadataKeys {
                if let value = previousMetadata[key] ?? nil { store.set(value, forKey: key) }
                else { store.removeObject(forKey: key) }
            }
            for key in globalKeys {
                if let value = previousGlobal[key] ?? nil { global.set(value, forKey: key) }
                else { global.removeObject(forKey: key) }
            }
            if let preferenceStore, let previousOverlay {
                if let value = previousOverlay.data { preferenceStore.set(value, forKey: preferenceOverlayKey) }
                else { preferenceStore.removeObject(forKey: preferenceOverlayKey) }
                if let value = previousOverlay.marker { preferenceStore.set(value, forKey: preferenceOverlayMigrationKey) }
                else { preferenceStore.removeObject(forKey: preferenceOverlayMigrationKey) }
            }
            throw error
        }
    }

    private static func writePreferenceOverlay(
        _ payload: ReaderExtensionPreferenceOverlayPayload,
        to store: UserDefaults
    ) throws {
        let data = try encode(payload)
        guard data.count <= maximumPreferenceOverlayBytes else { throw ReaderExtensionError.contentTooLarge }
        let previousData = store.object(forKey: preferenceOverlayKey)
        let previousMarker = store.object(forKey: preferenceOverlayMigrationKey)
        do {
            store.set(data, forKey: preferenceOverlayKey)
            store.set(true, forKey: preferenceOverlayMigrationKey)
            guard store.data(forKey: preferenceOverlayKey) == data,
                  store.bool(forKey: preferenceOverlayMigrationKey) else {
                throw ReaderExtensionError.persistenceFailed("preference overlay verification failed")
            }
        } catch {
            if let previousData { store.set(previousData, forKey: preferenceOverlayKey) }
            else { store.removeObject(forKey: preferenceOverlayKey) }
            if let previousMarker { store.set(previousMarker, forKey: preferenceOverlayMigrationKey) }
            else { store.removeObject(forKey: preferenceOverlayMigrationKey) }
            throw error
        }
    }

    private static func preferenceOverlayPayload(
        from sources: [ReaderExtensionInstalledSource]
    ) -> ReaderExtensionPreferenceOverlayPayload {
        ReaderExtensionPreferenceOverlayPayload(values: Dictionary(uniqueKeysWithValues: sources.map {
            ($0.id.rawValue, sanitizedPreferenceMetadata(for: $0))
        }))
    }

    private static func sanitizeRepositories(_ input: [ReaderExtensionRepositoryRecord]) -> [ReaderExtensionRepositoryRecord] {
        var seen = Set<String>()
        return input.filter { repository in
            guard (try? ReaderExtensionSecurityPolicy.validateRepositoryURLSyntax(repository.indexURL)) != nil,
                  repository.indexURL.absoluteString.utf8.count <= 16 * 1_024,
                  repository.id.utf8.count == 64,
                  repository.name.utf8.count <= 512,
                  repository.license.name.utf8.count <= 512,
                  repository.license.textSHA256.map(isValidDigest) ?? true,
                  (repository.errorMessage?.utf8.count ?? 0) <= 4 * 1_024,
                  repository.sourceCount >= 0,
                  repository.sourceCount <= maximumInstalledSourceCount,
                  ReaderExtensionRepositoryRecord(indexURL: repository.indexURL).id == repository.id else { return false }
            return seen.insert(repository.id).inserted
        }.map { repository in
            var copy = repository
            copy.websiteURL = ReaderExtensionSecurityPolicy.sanitizedMetadataDisplayURL(copy.websiteURL)
            copy.license.url = ReaderExtensionSecurityPolicy.sanitizedMetadataDisplayURL(copy.license.url)
            return copy
        }
    }

    private static func sanitizeSources(_ input: [ReaderExtensionInstalledSource]) -> [ReaderExtensionInstalledSource] {
        var seen = Set<ReaderExtensionSourceID>()
        return input.filter { source in
            guard source.id.isValid, seen.insert(source.id).inserted,
                  source.license.kind.permitsInstallation,
                  source.name.utf8.count <= 512, source.version.utf8.count <= 128,
                  source.upstreamID.utf8.count <= 128,
                  source.repositoryID.utf8.count <= 128,
                  source.repositoryURL.absoluteString.utf8.count <= 16 * 1_024,
                  source.baseURL.absoluteString.utf8.count <= 16 * 1_024,
                  (source.apiURL?.absoluteString.utf8.count ?? 0) <= 16 * 1_024,
                  (source.iconURL?.absoluteString.utf8.count ?? 0) <= 16 * 1_024,
                  (source.sourceCodeURL?.absoluteString.utf8.count ?? 0) <= 16 * 1_024,
                  source.language.utf8.count <= 64,
                  source.languageSelectionVersion.map({ (1...1_024).contains($0) }) ?? true,
                  (source.dateFormat?.utf8.count ?? 0) <= 128,
                  (source.dateFormatLocale?.utf8.count ?? 0) <= 64,
                  (source.additionalParameters?.utf8.count ?? 0) <= 16 * 1_024,
                  source.codeProvenanceFingerprint.utf8.count == 64,
                  source.license.name.utf8.count <= 512,
                  source.license.textSHA256.map(isValidDigest) ?? true,
                  (source.lastError?.utf8.count ?? 0) <= 4 * 1_024,
                  source.declaredDomains.count <= 64,
                  source.runtimeCapabilities.count <= 8,
                  source.secretPreferenceKeys.count <= ReaderExtensionSecurityPolicy.maximumPreferenceCount,
                  source.preferences.count <= 200,
                  source.activeContentDigest.map(isValidDigest) ?? true,
                  source.id == ReaderExtensionSourceID(
                    repositoryURL: source.repositoryURL,
                    upstreamID: source.upstreamID,
                    language: source.language,
                    mediaType: source.mediaType
                  ),
                  (try? ReaderExtensionSecurityPolicy.validateRepositoryURLSyntax(source.repositoryURL)) != nil,
                  (try? ReaderExtensionSecurityPolicy.validatePublicURLSyntax(source.baseURL)) != nil,
                  source.baseURL.query == nil, source.baseURL.fragment == nil,
                  (try? ReaderExtensionSecurityPolicy.validateNotArchive(data: Data(), response: nil, url: source.baseURL)) != nil,
                  source.apiURL.map({
                    (try? ReaderExtensionSecurityPolicy.validatePublicURLSyntax($0)) != nil
                        && $0.query == nil && $0.fragment == nil
                        && (try? ReaderExtensionSecurityPolicy.validateNotArchive(data: Data(), response: nil, url: $0)) != nil
                  }) ?? true,
                  source.iconURL.map({
                    (try? ReaderExtensionSecurityPolicy.validatePublicURLSyntax($0, requireHTTPS: true)) != nil
                        && $0.user == nil && $0.password == nil
                        && $0.fragment == nil
                        && ReaderExtensionSecurityPolicy.sanitizedIconURL($0)?.absoluteString == $0.absoluteString
                        && (try? ReaderExtensionSecurityPolicy.validateNotArchive(data: Data(), response: nil, url: $0)) != nil
                  }) ?? true,
                  isValidSourceCodeURL(source.sourceCodeURL, implementation: source.implementation) else { return false }
            return true
        }.map { source in
            var copy = source
            copy.license.url = ReaderExtensionSecurityPolicy.sanitizedMetadataDisplayURL(copy.license.url)
            copy.activeContentDigest = copy.activeContentDigest?.lowercased()
            copy.declaredDomains = Set(copy.declaredDomains.compactMap(
                ReaderExtensionSecurityPolicy.canonicalHost
            ).prefix(64))
            copy.secretPreferenceKeys = Set(copy.secretPreferenceKeys.sorted().filter {
                (try? ReaderExtensionSecurityPolicy.validatePreferenceSecret(key: $0, value: nil)) != nil
            }.prefix(ReaderExtensionSecurityPolicy.maximumPreferenceCount))
            copy.preferences = sanitizedPreferenceMetadata(for: copy)
            let material = [
                ReaderExtensionURLCanonicalizer.canonicalString(copy.repositoryURL),
                copy.upstreamID,
                copy.sourceCodeURL.map(ReaderExtensionURLCanonicalizer.canonicalString) ?? copy.implementation.rawValue
            ].joined(separator: "\u{1f}")
            copy.codeProvenanceFingerprint = SHA256.hash(data: Data(material.utf8))
                .map { String(format: "%02x", $0) }.joined()
            if let snapshot = copy.rollbackSourceSnapshot {
                var candidate = snapshot.installedSource()
                candidate.rollbackContentDigest = nil
                candidate.rollbackSourceSnapshot = nil
                if let sanitized = sanitizeSources([candidate]).first,
                   sanitized.id == copy.id,
                   sanitized.implementation == .javascript,
                   sanitized.activeContentDigest != copy.activeContentDigest,
                   let safeSnapshot = ReaderExtensionInstalledSourceRollbackSnapshot(source: sanitized) {
                    copy.rollbackSourceSnapshot = safeSnapshot
                    copy.rollbackContentDigest = safeSnapshot.activeContentDigest
                } else {
                    copy.rollbackSourceSnapshot = nil
                    copy.rollbackContentDigest = nil
                }
            } else {
                // Digest-only rollback metadata predates complete snapshots and
                // must never cause old bytes to run under newer metadata.
                copy.rollbackContentDigest = nil
            }
            return copy
        }
    }

    private static func isValidDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }

    private static func isValidSourceCodeURL(
        _ url: URL?,
        implementation: ReaderExtensionImplementation
    ) -> Bool {
        if implementation == .javascript {
            guard let url else { return false }
            return (try? ReaderExtensionSecurityPolicy.validateScriptURLSyntax(url)) != nil
        }
        guard let url else { return true }
        return (try? ReaderExtensionSecurityPolicy.validatePublicURLSyntax(url, requireHTTPS: true)) != nil
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    private static func validateCollectionCounts(
        repositories: [ReaderExtensionRepositoryRecord],
        sources: [ReaderExtensionInstalledSource]
    ) throws {
        guard repositories.count <= maximumRepositoryCount,
              sources.count <= maximumInstalledSourceCount else {
            throw ReaderExtensionError.contentTooLarge
        }
    }

    private static func loadRuntimeQuarantineUnlocked(
        from store: UserDefaults
    ) throws -> Set<ReaderExtensionRuntimeQuarantineEntry> {
        guard let data = store.data(forKey: runtimeQuarantineKey) else { return [] }
        guard data.count <= maximumRuntimeQuarantineBytes else { throw ReaderExtensionError.contentTooLarge }
        let decoded = try JSONDecoder().decode([ReaderExtensionRuntimeQuarantineEntry].self, from: data)
        let entries = Set(decoded)
        guard decoded.count <= maximumRuntimeQuarantineEntries,
              entries.count == decoded.count,
              decoded.allSatisfy(\.isValid) else {
            throw ReaderExtensionError.persistenceFailed("runtime quarantine metadata is invalid")
        }
        return entries
    }

    private static func persistRuntimeQuarantineUnlocked(
        _ entries: Set<ReaderExtensionRuntimeQuarantineEntry>,
        to store: UserDefaults,
        checkpoint: (UserDefaults) -> Bool
    ) throws {
        guard entries.count <= maximumRuntimeQuarantineEntries,
              entries.allSatisfy(\.isValid) else { throw ReaderExtensionError.contentTooLarge }
        let previous = store.object(forKey: runtimeQuarantineKey)
        let ordered = entries.sorted(by: ReaderExtensionRuntimeQuarantineEntry.isOrderedBefore)
        let data = try encode(ordered)
        guard data.count <= maximumRuntimeQuarantineBytes else { throw ReaderExtensionError.contentTooLarge }
        do {
            if ordered.isEmpty { store.removeObject(forKey: runtimeQuarantineKey) }
            else { store.set(data, forKey: runtimeQuarantineKey) }
            guard checkpoint(store),
                  (ordered.isEmpty
                    ? store.object(forKey: runtimeQuarantineKey) == nil
                    : store.data(forKey: runtimeQuarantineKey) == data),
                  try loadRuntimeQuarantineUnlocked(from: store) == entries else {
                throw ReaderExtensionError.persistenceFailed("runtime quarantine write verification failed")
            }
        } catch {
            if let previous { store.set(previous, forKey: runtimeQuarantineKey) }
            else { store.removeObject(forKey: runtimeQuarantineKey) }
            _ = checkpoint(store)
            throw error
        }
    }

    private static func validateRestorableLicenses(
        in snapshot: ReaderExtensionBackupSnapshot
    ) throws {
        if let prohibited = snapshot.repositories.first(where: {
            !$0.license.kind.permitsInstallation
        }) {
            throw ReaderExtensionError.restrictiveLicense(prohibited.license.name)
        }
        if let prohibited = snapshot.installedSources.first(where: {
            !$0.license.kind.permitsInstallation
        }) {
            // Restore must fail before any transaction begins. Silently
            // filtering crafted metadata would make backup verification report
            // misleading success and weaken the license boundary.
            throw ReaderExtensionError.restrictiveLicense(prohibited.license.name)
        }
    }

    /// Removes untrusted or oversized values before they enter profile-scoped
    /// metadata. A schema-declared or credential-like key is never accepted as
    /// an ordinary value; secret references are normalized to the key itself
    /// so a malicious backup cannot smuggle a credential in the marker field.
    private static func sanitizedPreferenceMetadata(
        for source: ReaderExtensionInstalledSource
    ) -> [String: ReaderExtensionPreferenceValue] {
        var output: [String: ReaderExtensionPreferenceValue] = [:]
        for (key, value) in source.preferences.prefix(ReaderExtensionSecurityPolicy.maximumPreferenceCount) {
            if value.isSecret {
                guard (try? ReaderExtensionSecurityPolicy.validatePreferenceSecret(key: key, value: nil)) != nil else { continue }
                output[key] = .secretReference(key)
                continue
            }
            guard !source.secretPreferenceKeys.contains(key),
                  !ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key),
                  (try? ReaderExtensionSecurityPolicy.validatePreference(key: key, value: value)) != nil else { continue }
            output[key] = value
        }
        return output
    }

    private static func sanitizedPreferenceMetadata(
        for source: ReaderExtensionInstalledSource,
        values: [String: ReaderExtensionPreferenceValue]
    ) -> [String: ReaderExtensionPreferenceValue] {
        var candidate = source
        candidate.preferences = values
        return sanitizedPreferenceMetadata(for: candidate)
    }

    /// Evaluate schema/heuristic sensitivity before metadataForBackup clears
    /// `secretPreferenceKeys`; otherwise a stale `.string` credential could be
    /// copied into an Eclipse backup as an apparently ordinary preference.
    private static func sanitizedBackupMetadata(
        _ source: ReaderExtensionInstalledSource
    ) -> ReaderExtensionInstalledSource {
        var copy = source
        copy.preferences = sanitizedPreferenceMetadata(for: source).filter { !$0.value.isSecret }
        return copy.metadataForBackup()
    }

    private static func retainingVerifiedRuntime(
        in portableSources: [ReaderExtensionInstalledSource],
        from verifiedLocalSources: [ReaderExtensionInstalledSource]
    ) -> [ReaderExtensionInstalledSource] {
        let localByID = Dictionary(
            verifiedLocalSources.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return portableSources.map { incoming in
            guard let local = localByID[incoming.id],
                  localRuntimeCanBeRetained(local),
                  runtimeIdentityMatches(incoming, local) else {
                return incoming
            }
            var merged = incoming
            merged.activeContentDigest = local.activeContentDigest
            merged.rollbackContentDigest = local.rollbackContentDigest
            merged.rollbackSourceSnapshot = local.rollbackSourceSnapshot
            merged.declaredDomains = local.declaredDomains
            merged.requiresReinstall = false
            merged.lastError = nil
            return merged
        }
    }

    private static func localRuntimeCanBeRetained(
        _ source: ReaderExtensionInstalledSource
    ) -> Bool {
        guard !source.requiresReinstall,
              source.implementation != .unsupportedNative,
              source.license.kind.permitsInstallation else { return false }
        if source.implementation == .javascript {
            guard let digest = source.activeContentDigest, isValidDigest(digest) else { return false }
        }
        return true
    }

    private static func runtimeIdentityMatches(
        _ incoming: ReaderExtensionInstalledSource,
        _ local: ReaderExtensionInstalledSource
    ) -> Bool {
        func sameURL(_ lhs: URL?, _ rhs: URL?) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none): return true
            case (.some(let lhs), .some(let rhs)):
                return ReaderExtensionURLCanonicalizer.canonicalString(lhs)
                    == ReaderExtensionURLCanonicalizer.canonicalString(rhs)
            default: return false
            }
        }

        return incoming.id == local.id
            && incoming.upstreamID == local.upstreamID
            && incoming.repositoryID == local.repositoryID
            && sameURL(incoming.repositoryURL, local.repositoryURL)
            && sameURL(incoming.baseURL, local.baseURL)
            && sameURL(incoming.apiURL, local.apiURL)
            && sameURL(incoming.sourceCodeURL, local.sourceCodeURL)
            && incoming.language.lowercased() == local.language.lowercased()
            && incoming.languageSelectionVersion == local.languageSelectionVersion
            && incoming.mediaType == local.mediaType
            && incoming.implementation == local.implementation
            && incoming.version == local.version
            && incoming.maturity == local.maturity
            && incoming.license.provenanceFingerprint == local.license.provenanceFingerprint
            && incoming.hasCloudflare == local.hasCloudflare
            && incoming.dateFormat == local.dateFormat
            && incoming.dateFormatLocale == local.dateFormatLocale
            && incoming.additionalParameters == local.additionalParameters
            && incoming.codeProvenanceFingerprint == local.codeProvenanceFingerprint
            && incoming.runtimeCapabilities == local.runtimeCapabilities
            && incoming.preferenceSchemaFingerprint == local.preferenceSchemaFingerprint
            && incoming.secretPreferenceKeys == local.secretPreferenceKeys
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, from store: UserDefaults) throws -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }

    private static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }

    private static func roundTrip<T: Codable>(_ value: T) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(T.self, from: encode(value))
    }
}

struct ReaderExtensionRuntimeQuarantineEntry: Codable, Hashable, Sendable {
    let sourceID: ReaderExtensionSourceID
    let digest: String

    init(sourceID: ReaderExtensionSourceID, digest: String) {
        self.sourceID = sourceID
        self.digest = digest.lowercased()
    }

    var isValid: Bool {
        sourceID.isValid && digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }

    static func isOrderedBefore(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.sourceID.rawValue != rhs.sourceID.rawValue {
            return lhs.sourceID.rawValue < rhs.sourceID.rawValue
        }
        return lhs.digest < rhs.digest
    }
}

final class ReaderExtensionRuntimeQuarantineFileStore: @unchecked Sendable {
    private static let maximumEntries = 4_000
    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("ReaderExtensions", isDirectory: true)
            .appendingPathComponent("RuntimeQuarantine", isDirectory: true)
        }
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try synchronizeDirectory()
    }

    var isReadable: Bool {
        guard let files = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), files.count <= Self.maximumEntries else { return false }
        return files.allSatisfy { file in
            let components = file.deletingPathExtension().lastPathComponent.split(separator: ".")
            return file.pathExtension == "blocked"
                && components.count == 2
                && components[0].count == 64
                && components[1].count == 64
                && components.joined().allSatisfy(\.isHexDigit)
        }
    }

    func contains(_ entry: ReaderExtensionRuntimeQuarantineEntry) throws -> Bool {
        guard entry.isValid else { throw ReaderExtensionError.persistenceFailed("invalid runtime quarantine entry") }
        return fileManager.fileExists(atPath: markerURL(for: entry).path)
    }

    func entries() throws -> Set<ReaderExtensionRuntimeQuarantineEntry> {
        let files = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard files.count <= Self.maximumEntries else { throw ReaderExtensionError.contentTooLarge }
        var result = Set<ReaderExtensionRuntimeQuarantineEntry>()
        result.reserveCapacity(files.count)
        for file in files {
            guard file.pathExtension == "blocked" else {
                throw ReaderExtensionError.persistenceFailed("runtime quarantine marker is invalid")
            }
            let components = file.deletingPathExtension().lastPathComponent.split(
                separator: ".",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard components.count == 2 else {
                throw ReaderExtensionError.persistenceFailed("runtime quarantine marker is invalid")
            }
            let entry = ReaderExtensionRuntimeQuarantineEntry(
                sourceID: ReaderExtensionSourceID(rawValue: String(components[0])),
                digest: String(components[1])
            )
            guard entry.isValid, result.insert(entry).inserted else {
                throw ReaderExtensionError.persistenceFailed("runtime quarantine marker is invalid")
            }
        }
        return result
    }

    func mark(_ entry: ReaderExtensionRuntimeQuarantineEntry) throws {
        guard entry.isValid else { throw ReaderExtensionError.persistenceFailed("invalid runtime quarantine entry") }
        let url = markerURL(for: entry)
        let existing = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard fileManager.fileExists(atPath: url.path) || existing.count < Self.maximumEntries else {
            throw ReaderExtensionError.contentTooLarge
        }
        try Data("blocked\n".utf8).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try synchronizeFile(at: url)
        try synchronizeDirectory()
        guard fileManager.fileExists(atPath: url.path) else {
            throw ReaderExtensionError.persistenceFailed("runtime quarantine marker verification failed")
        }
    }

    func clear(_ entry: ReaderExtensionRuntimeQuarantineEntry) throws {
        guard entry.isValid else { throw ReaderExtensionError.persistenceFailed("invalid runtime quarantine entry") }
        let url = markerURL(for: entry)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            try synchronizeDirectory()
        }
        guard !fileManager.fileExists(atPath: url.path) else {
            throw ReaderExtensionError.persistenceFailed("runtime quarantine marker removal verification failed")
        }
    }

    func clear(sourceIDs: Set<ReaderExtensionSourceID>) throws {
        guard sourceIDs.allSatisfy(\.isValid) else {
            throw ReaderExtensionError.persistenceFailed("invalid runtime quarantine source identity")
        }
        let prefixes = sourceIDs.map { "\($0.rawValue)." }
        let files = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var changed = false
        for file in files where prefixes.contains(where: { file.lastPathComponent.hasPrefix($0) }) {
            try fileManager.removeItem(at: file)
            changed = true
        }
        if changed { try synchronizeDirectory() }
        let remaining = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard !remaining.contains(where: { file in
            prefixes.contains(where: { file.lastPathComponent.hasPrefix($0) })
        }) else {
            throw ReaderExtensionError.persistenceFailed("runtime quarantine source cleanup verification failed")
        }
    }

    private func markerURL(for entry: ReaderExtensionRuntimeQuarantineEntry) -> URL {
        rootURL.appendingPathComponent("\(entry.sourceID.rawValue).\(entry.digest).blocked", isDirectory: false)
    }

    private func synchronizeFile(at url: URL) throws {
#if canImport(Darwin)
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw ReaderExtensionError.persistenceFailed("runtime quarantine marker could not be opened") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ReaderExtensionError.persistenceFailed("runtime quarantine marker could not be synchronized")
        }
#else
        let handle = try FileHandle(forReadingFrom: url)
        try handle.synchronize()
        try handle.close()
#endif
    }

    private func synchronizeDirectory() throws {
#if canImport(Darwin)
        let descriptor = Darwin.open(rootURL.path, O_RDONLY)
        guard descriptor >= 0 else { throw ReaderExtensionError.persistenceFailed("runtime quarantine directory could not be opened") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ReaderExtensionError.persistenceFailed("runtime quarantine directory could not be synchronized")
        }
#endif
    }
}

private extension NSLock {
    func withReaderExtensionPersistenceLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

enum ReaderExtensionAuthenticationCleanupKind: String, Codable, Hashable {
    case authentication
    case deviceState
    case namespaceDeviceState
}

struct ReaderExtensionPendingAuthenticationCleanup: Codable, Hashable {
    static let namespaceSentinelSourceID = ReaderExtensionSourceID(
        rawValue: String(repeating: "0", count: 64)
    )

    let sourceID: ReaderExtensionSourceID
    let namespace: String
    let kind: ReaderExtensionAuthenticationCleanupKind

    var isNamespaceWide: Bool { kind == .namespaceDeviceState }

    var isValid: Bool {
        let sourceIsValid = isNamespaceWide
            ? sourceID == Self.namespaceSentinelSourceID
            : sourceID.isValid
        return sourceIsValid
            && namespace.utf8.count <= 64
            && UUID(uuidString: namespace)?.uuidString == namespace
    }

    static func namespaceDeviceState(_ namespace: String) -> Self {
        Self(
            sourceID: namespaceSentinelSourceID,
            namespace: namespace,
            kind: .namespaceDeviceState
        )
    }

    func applies(to sourceID: ReaderExtensionSourceID, namespace: String) -> Bool {
        self.namespace == namespace && (isNamespaceWide || self.sourceID == sourceID)
    }

    static func isOrderedBefore(
        _ lhs: ReaderExtensionPendingAuthenticationCleanup,
        _ rhs: ReaderExtensionPendingAuthenticationCleanup
    ) -> Bool {
        if lhs.sourceID.rawValue != rhs.sourceID.rawValue {
            return lhs.sourceID.rawValue < rhs.sourceID.rawValue
        }
        if lhs.namespace != rhs.namespace { return lhs.namespace < rhs.namespace }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}

enum ReaderExtensionAuthenticationCleanupPolicy {
    static func adding(
        sourceIDs: [ReaderExtensionSourceID],
        namespaces: [String],
        kind: ReaderExtensionAuthenticationCleanupKind,
        to existing: Set<ReaderExtensionPendingAuthenticationCleanup>
    ) throws -> Set<ReaderExtensionPendingAuthenticationCleanup> {
        guard kind != .namespaceDeviceState,
              sourceIDs.count <= 1_000, namespaces.count <= 6 else {
            throw ReaderExtensionError.contentTooLarge
        }
        var result = existing
        for sourceID in Set(sourceIDs) {
            for namespace in Set(namespaces) {
                let authentication = ReaderExtensionPendingAuthenticationCleanup(
                    sourceID: sourceID,
                    namespace: namespace,
                    kind: .authentication
                )
                let deviceState = ReaderExtensionPendingAuthenticationCleanup(
                    sourceID: sourceID,
                    namespace: namespace,
                    kind: .deviceState
                )
                guard authentication.isValid else {
                    throw ReaderExtensionError.persistenceFailed("invalid authentication cleanup scope")
                }
                if result.contains(where: { $0.isNamespaceWide && $0.namespace == namespace }) {
                    continue
                }
                if kind == .deviceState {
                    result.remove(authentication)
                    result.insert(deviceState)
                } else if !result.contains(deviceState) {
                    result.insert(authentication)
                }
            }
        }
        guard result.count <= 6_000 else { throw ReaderExtensionError.contentTooLarge }
        return result
    }

    static func addingNamespaces(
        _ namespaces: [String],
        to existing: Set<ReaderExtensionPendingAuthenticationCleanup>
    ) throws -> Set<ReaderExtensionPendingAuthenticationCleanup> {
        guard namespaces.count <= 6 else { throw ReaderExtensionError.contentTooLarge }
        var result = existing
        for namespace in Set(namespaces) {
            let entry = ReaderExtensionPendingAuthenticationCleanup.namespaceDeviceState(namespace)
            guard entry.isValid else {
                throw ReaderExtensionError.persistenceFailed("invalid Reader authentication namespace")
            }
            result = result.filter { $0.namespace != namespace }
            result.insert(entry)
        }
        guard result.count <= 6_000 else { throw ReaderExtensionError.contentTooLarge }
        return result
    }

    static func retry(
        _ pending: Set<ReaderExtensionPendingAuthenticationCleanup>,
        sourceIDs: Set<ReaderExtensionSourceID>? = nil,
        namespaces: Set<String>? = nil,
        cleanup: (ReaderExtensionPendingAuthenticationCleanup) throws -> Void
    ) -> (remaining: Set<ReaderExtensionPendingAuthenticationCleanup>, firstError: Error?) {
        var remaining = pending
        var firstError: Error?
        let selected = pending.filter {
            (sourceIDs == nil || $0.isNamespaceWide || sourceIDs?.contains($0.sourceID) == true)
                && (namespaces == nil || namespaces?.contains($0.namespace) == true)
        }
            .sorted(by: ReaderExtensionPendingAuthenticationCleanup.isOrderedBefore)
        for entry in selected {
            do {
                try cleanup(entry)
                remaining.remove(entry)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        return (remaining, firstError)
    }
}

struct ReaderExtensionProfileAuthenticationCleanupResult {
    let namespaces: Set<String>
    let firstError: Error?

    var isFullyClean: Bool { firstError == nil }
}

/// Owns the device-global cleanup journal transaction. Profile/service stores
/// may move or disappear, so destructive authentication intent is always
/// checkpointed in the stable standard defaults domain before any caller is
/// allowed to remove a profile's metadata.
enum ReaderExtensionAuthenticationCleanupJournal {
    private static let lock = NSLock()

    @discardableResult
    static func enqueueSources(
        sourceIDs: [ReaderExtensionSourceID],
        namespaces: [String],
        kind: ReaderExtensionAuthenticationCleanupKind,
        store: UserDefaults = .standard
    ) throws -> Set<ReaderExtensionPendingAuthenticationCleanup> {
        lock.lock(); defer { lock.unlock() }
        let previous = try ReaderExtensionPersistence.loadPendingAuthenticationCleanup(from: store)
        let candidate = try ReaderExtensionAuthenticationCleanupPolicy.adding(
            sourceIDs: sourceIDs,
            namespaces: namespaces,
            kind: kind,
            to: previous
        )
        let sources = Set(sourceIDs)
        let scopes = Set(namespaces)
        try ReaderExtensionAuthenticationGenerationRegistry.prepareSourceRevocation(
            sourceIDs: sources,
            namespaces: scopes
        ) {
            if candidate != previous {
                try ReaderExtensionPersistence.persistPendingAuthenticationCleanup(candidate, to: store)
            }
        }
        return previous
    }

    @discardableResult
    static func enqueueNamespaces(
        _ namespaces: [String],
        store: UserDefaults = .standard,
        checkpoint: @escaping (UserDefaults) -> Bool = { $0.synchronize() }
    ) throws -> Set<ReaderExtensionPendingAuthenticationCleanup> {
        lock.lock(); defer { lock.unlock() }
        let previous = try ReaderExtensionPersistence.loadPendingAuthenticationCleanup(from: store)
        let candidate = try ReaderExtensionAuthenticationCleanupPolicy.addingNamespaces(
            namespaces,
            to: previous
        )
        try ReaderExtensionAuthenticationGenerationRegistry.prepareNamespaceRevocation(
            Set(namespaces)
        ) {
            if candidate != previous {
                try ReaderExtensionPersistence.persistPendingAuthenticationCleanup(
                    candidate,
                    to: store,
                    checkpoint: checkpoint
                )
            }
        }
        return previous
    }

    static func restore(
        _ previous: Set<ReaderExtensionPendingAuthenticationCleanup>,
        store: UserDefaults = .standard
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try ReaderExtensionPersistence.persistPendingAuthenticationCleanup(previous, to: store)
    }

    /// Returns a cleanup error only after the journal has been updated. A
    /// failed deletion stays in `remaining`; a failed journal update throws and
    /// its persistence helper restores the prior (conservative) marker bytes.
    static func retry(
        store: UserDefaults = .standard,
        sourceIDs: Set<ReaderExtensionSourceID>? = nil,
        namespaces: Set<String>? = nil,
        cleanup: (ReaderExtensionPendingAuthenticationCleanup) throws -> Void
    ) throws -> Error? {
        lock.lock(); defer { lock.unlock() }
        let pending = try ReaderExtensionPersistence.loadPendingAuthenticationCleanup(from: store)
        guard !pending.isEmpty else { return nil }
        let outcome = ReaderExtensionAuthenticationCleanupPolicy.retry(
            pending,
            sourceIDs: sourceIDs,
            namespaces: namespaces,
            cleanup: cleanup
        )
        if outcome.remaining != pending {
            try ReaderExtensionPersistence.persistPendingAuthenticationCleanup(outcome.remaining, to: store)
        }
        return outcome.firstError
    }
}

enum ReaderExtensionProfileAuthenticationLifecycle {
    /// Durably revokes and cleans all Reader Extension Keychain items for the
    /// supplied profile UUIDs. Once enqueue succeeds, callers may remove the
    /// profile stores even if Keychain is temporarily unavailable: the global
    /// tombstone survives and blocks a same-UUID restore until retry succeeds.
    static func prepareForProfileStoreDeletion(
        profileIDs: [UUID],
        journalStore: UserDefaults = .standard,
        keychain: any ReaderExtensionKeychainAccess = ReaderExtensionSystemKeychainAccess(),
        checkpoint: @escaping (UserDefaults) -> Bool = { $0.synchronize() }
    ) throws -> ReaderExtensionProfileAuthenticationCleanupResult {
        let namespaces = Set(profileIDs.map { $0.uuidString })
        guard !namespaces.isEmpty else {
            return ReaderExtensionProfileAuthenticationCleanupResult(
                namespaces: [],
                firstError: nil
            )
        }
        _ = try ReaderExtensionAuthenticationCleanupJournal.enqueueNamespaces(
            Array(namespaces),
            store: journalStore,
            checkpoint: checkpoint
        )
        do {
            let cleanupError = try ReaderExtensionAuthenticationCleanupJournal.retry(
                store: journalStore,
                namespaces: namespaces
            ) { entry in
                guard entry.isNamespaceWide else { return }
                try ReaderExtensionKeychainStore.removeAllDeviceState(
                    inNamespace: entry.namespace,
                    keychain: keychain
                )
            }
            return ReaderExtensionProfileAuthenticationCleanupResult(
                namespaces: namespaces,
                firstError: cleanupError
            )
        } catch {
            // Enqueue already completed and is crash-durable. A stale marker is
            // intentionally safer than claiming cleanup completed.
            return ReaderExtensionProfileAuthenticationCleanupResult(
                namespaces: namespaces,
                firstError: error
            )
        }
    }
}

private struct ReaderExtensionPreferenceOverlayPayload: Codable, Equatable {
    var values: [String: [String: ReaderExtensionPreferenceValue]]
}

enum ReaderExtensionContentRetentionPolicy {
    /// Returns nil whenever the complete profile roster or any candidate
    /// metadata store cannot be trusted. Callers interpret nil as "retain
    /// everything", preventing hidden/corrupt profile state from becoming a
    /// destructive garbage-collection decision.
    static func referencedDigests(
        rosterStoreIsReadable: Bool,
        stores: [UserDefaults]
    ) -> Set<String>? {
        guard rosterStoreIsReadable else { return nil }
        var digests = Set<String>()
        for store in stores {
            guard let sources = try? ReaderExtensionPersistence.loadInstalledSources(from: store) else {
                return nil
            }
            for source in sources {
                if let active = source.activeContentDigest {
                    guard isValidDigest(active) else { return nil }
                    digests.insert(active.lowercased())
                }
                if let snapshot = source.rollbackSourceSnapshot {
                    guard isValidDigest(snapshot.activeContentDigest),
                          source.rollbackContentDigest?.lowercased() == snapshot.activeContentDigest.lowercased() else {
                        return nil
                    }
                    digests.insert(snapshot.activeContentDigest.lowercased())
                } else if source.rollbackContentDigest != nil {
                    return nil
                }
            }
        }
        return digests
    }

    private static func isValidDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

enum ReaderExtensionRuntimeQuarantineReferencePolicy {
    /// Quarantine is device-global while installed-source metadata may be
    /// profile-scoped. A marker can be removed only when every readable
    /// metadata namespace proves that exact source+digest pair is absent.
    /// Unreadable roster/store state returns nil and therefore retains every
    /// marker fail-closed.
    static func referencedEntries(
        rosterStoreIsReadable: Bool,
        stores: [UserDefaults]
    ) -> Set<ReaderExtensionRuntimeQuarantineEntry>? {
        guard rosterStoreIsReadable else { return nil }
        var result = Set<ReaderExtensionRuntimeQuarantineEntry>()
        for store in stores {
            guard let sources = try? ReaderExtensionPersistence.loadInstalledSources(from: store) else {
                return nil
            }
            for source in sources where source.implementation == .javascript {
                if let digest = source.activeContentDigest {
                    let entry = ReaderExtensionRuntimeQuarantineEntry(sourceID: source.id, digest: digest)
                    guard entry.isValid else { return nil }
                    result.insert(entry)
                }
                if let snapshot = source.rollbackSourceSnapshot {
                    let entry = ReaderExtensionRuntimeQuarantineEntry(
                        sourceID: source.id,
                        digest: snapshot.activeContentDigest
                    )
                    guard entry.isValid,
                          source.rollbackContentDigest?.lowercased() == entry.digest else { return nil }
                    result.insert(entry)
                } else if source.rollbackContentDigest != nil {
                    return nil
                }
            }
        }
        return result
    }
}

enum ReaderExtensionRuntimeQuarantineClearPolicy {
    static func eligibleEntries(
        available: Set<ReaderExtensionRuntimeQuarantineEntry>,
        sourceIDs: Set<ReaderExtensionSourceID>,
        referenced: Set<ReaderExtensionRuntimeQuarantineEntry>
    ) -> Set<ReaderExtensionRuntimeQuarantineEntry> {
        Set(available.filter {
            sourceIDs.contains($0.sourceID) && !referenced.contains($0)
        })
    }
}

final class ReaderExtensionContentStore: @unchecked Sendable {
    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let applicationSupport: URL
        if let rootURL {
            applicationSupport = rootURL
        } else {
            applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("ReaderExtensions", isDirectory: true)
        }
        self.rootURL = applicationSupport
        try fileManager.createDirectory(at: contentURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try excludeFromBackup(applicationSupport)
    }

    var contentURL: URL { rootURL.appendingPathComponent("Content", isDirectory: true) }
    var stagingURL: URL { rootURL.appendingPathComponent("Staging", isDirectory: true) }

    func stageExactScript(_ data: Data) throws -> ReaderExtensionStagedContent {
        _ = try ReaderExtensionSecurityPolicy.validateScript(data)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let stage = stagingURL.appendingPathComponent("\(UUID().uuidString).js")
        do {
            try data.write(to: stage, options: [.atomic, .completeFileProtectionUnlessOpen])
            try excludeFromBackup(stage)
            guard try Data(contentsOf: stage) == data else {
                throw ReaderExtensionError.persistenceFailed("staged script verification failed")
            }
            try synchronizeFile(at: stage)
            try synchronizeDirectory(at: stagingURL)
        } catch {
            try? fileManager.removeItem(at: stage)
            try? synchronizeDirectory(at: stagingURL)
            throw error
        }
        return ReaderExtensionStagedContent(digest: digest, temporaryURL: stage, byteCount: data.count)
    }

    func activate(_ staged: ReaderExtensionStagedContent) throws -> String {
        let destination = contentURL.appendingPathComponent("\(staged.digest).js")
        if fileManager.fileExists(atPath: destination.path) {
            if (try? digest(of: destination)) == staged.digest {
                try synchronizeFile(at: destination)
                try synchronizeDirectory(at: contentURL)
                try? fileManager.removeItem(at: staged.temporaryURL)
                try? synchronizeDirectory(at: stagingURL)
                return staged.digest
            }
            // A crash or external corruption may leave a bad blob at the
            // correct content-addressed path. Replace it with the verified
            // staged bytes so an equal-version reinstall can recover.
            try fileManager.removeItem(at: destination)
            try synchronizeDirectory(at: contentURL)
        }
        do {
            try fileManager.moveItem(at: staged.temporaryURL, to: destination)
            try excludeFromBackup(destination)
            guard try digest(of: destination) == staged.digest else {
                throw ReaderExtensionError.persistenceFailed("activated script hash mismatch")
            }
            // The blob and both sides of the staging-to-content rename must be
            // durable before metadata is allowed to publish this digest.
            try synchronizeFile(at: destination)
            try synchronizeDirectory(at: contentURL)
            try synchronizeDirectory(at: stagingURL)
        } catch {
            try? fileManager.removeItem(at: staged.temporaryURL)
            try? fileManager.removeItem(at: destination)
            try? synchronizeDirectory(at: stagingURL)
            try? synchronizeDirectory(at: contentURL)
            throw error
        }
        return staged.digest
    }

    func discard(_ staged: ReaderExtensionStagedContent) {
        try? fileManager.removeItem(at: staged.temporaryURL)
        try? synchronizeDirectory(at: stagingURL)
    }

    func scriptData(digest: String) throws -> Data {
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
            throw ReaderExtensionError.persistenceFailed("invalid content digest")
        }
        let url = contentURL.appendingPathComponent("\(digest.lowercased()).js")
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= ReaderExtensionSecurityPolicy.maximumScriptBytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest.lowercased() else {
            throw ReaderExtensionError.persistenceFailed("stored script hash mismatch")
        }
        return data
    }

    /// Last-resort fail-closed path when neither independent quarantine marker
    /// can be checkpointed. Removing the exact content-addressed blob ensures
    /// startup reconciliation cannot re-admit it under stale metadata.
    func removeExecutable(digest: String) throws {
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
            throw ReaderExtensionError.persistenceFailed("invalid content digest")
        }
        let url = contentURL.appendingPathComponent("\(digest.lowercased()).js")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            try synchronizeDirectory(at: contentURL)
        }
        guard !fileManager.fileExists(atPath: url.path) else {
            throw ReaderExtensionError.persistenceFailed("quarantined script removal verification failed")
        }
    }

    func removeUnreferencedContent(keeping digests: Set<String>) {
        guard let files = try? fileManager.contentsOfDirectory(at: contentURL, includingPropertiesForKeys: nil) else { return }
        var removedAny = false
        for file in files where file.pathExtension == "js" && !digests.contains(file.deletingPathExtension().lastPathComponent) {
            if (try? fileManager.removeItem(at: file)) != nil { removedAny = true }
        }
        if removedAny { try? synchronizeDirectory(at: contentURL) }
    }

    func clearStaging() {
        guard let files = try? fileManager.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil) else { return }
        var removedAny = false
        for file in files {
            if (try? fileManager.removeItem(at: file)) != nil { removedAny = true }
        }
        if removedAny { try? synchronizeDirectory(at: stagingURL) }
    }

    private func digest(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: [.mappedIfSafe])).map { String(format: "%02x", $0) }.joined()
    }

    private func excludeFromBackup(_ url: URL) throws {
        var copy = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try copy.setResourceValues(values)
    }

    private func synchronizeFile(at url: URL) throws {
#if canImport(Darwin)
        try synchronizeDescriptor(at: url, kind: "file")
#else
        let handle = try FileHandle(forReadingFrom: url)
        try handle.synchronize()
        try handle.close()
#endif
    }

    private func synchronizeDirectory(at url: URL) throws {
#if canImport(Darwin)
        try synchronizeDescriptor(at: url, kind: "directory")
#endif
    }

#if canImport(Darwin)
    private func synchronizeDescriptor(at url: URL, kind: String) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ReaderExtensionError.persistenceFailed("could not open \(kind) for durable storage")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ReaderExtensionError.persistenceFailed("could not synchronize \(kind) for durable storage")
        }
    }
#endif
}

struct ReaderExtensionStagedContent: Sendable {
    let digest: String
    let temporaryURL: URL
    let byteCount: Int
}

struct ReaderExtensionRepositoryCatalog: Sendable {
    var name: String?
    var websiteURL: URL?
    var declaredLicenseName: String?
    var declaredLicenseURL: URL?
    var sources: [ReaderExtensionCatalogSource]

    static func decode(data: Data, indexURL: URL, repository: ReaderExtensionRepositoryRecord) throws -> Self {
        guard data.count <= ReaderExtensionSecurityPolicy.maximumRepositoryBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        // Bound the remote object graph before either Decodable shape asks
        // Foundation to allocate it. Both supported contracts fit this single
        // structural envelope: a direct top-level source array, or a small
        // metadata object containing `sources`/`extensions`. Applying the
        // 1,000-entry limit to every container also blocks dense source rows
        // designed to amplify dictionaries within the four MiB byte ceiling.
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: ReaderExtensionSecurityPolicy.maximumRepositoryBytes,
            maximumDepth: 8,
            maximumContainerEntries: ReaderExtensionPersistence.maximumInstalledSourceCount,
            maximumTopLevelEntries: ReaderExtensionPersistence.maximumInstalledSourceCount,
            maximumTotalTokens: 128_000,
            maximumStringBytes: 16 * 1_024
        ))
        let decoder = JSONDecoder()
        let envelope: ReaderExtensionRawCatalogEnvelope
        if let direct = try? decoder.decode([ReaderExtensionRawCatalogSource].self, from: data) {
            envelope = ReaderExtensionRawCatalogEnvelope(name: nil, website: nil, license: nil, licenseURL: nil, sources: direct)
        } else {
            envelope = try decoder.decode(ReaderExtensionRawCatalogEnvelope.self, from: data)
        }
        guard envelope.sources.count <= ReaderExtensionPersistence.maximumInstalledSourceCount else {
            throw ReaderExtensionError.invalidManifest("too many source rows")
        }
        guard (envelope.name?.utf8.count ?? 0) <= 512,
              (envelope.license?.utf8.count ?? 0) <= 512,
              (envelope.website?.utf8.count ?? 0) <= 16 * 1_024,
              (envelope.licenseURL?.utf8.count ?? 0) <= 16 * 1_024 else {
            throw ReaderExtensionError.contentTooLarge
        }
        let website = envelope.website.flatMap(URL.init(string:))
        let licenseURL = envelope.licenseURL.flatMap(URL.init(string:))
        guard envelope.website == nil || website != nil,
              envelope.licenseURL == nil || licenseURL != nil else {
            throw ReaderExtensionError.invalidManifest("repository metadata URL is invalid")
        }
        if let website {
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(website)
            guard website.query == nil, website.fragment == nil, website.user == nil, website.password == nil else {
                throw ReaderExtensionError.invalidManifest("repository website URL contains private or unstable components")
            }
        }
        if let licenseURL {
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(licenseURL, requireHTTPS: true)
            guard licenseURL.query == nil, licenseURL.fragment == nil, licenseURL.user == nil, licenseURL.password == nil else {
                throw ReaderExtensionError.invalidManifest("repository license URL contains private or unstable components")
            }
        }
        var result: [ReaderExtensionCatalogSource] = []
        var seen: [ReaderExtensionSourceID: ReaderExtensionCatalogSource] = [:]
        for raw in envelope.sources {
            guard let mediaType = raw.mediaType else { continue }
            let source: ReaderExtensionCatalogSource
            do {
                source = try raw.normalized(
                    indexURL: indexURL,
                    repository: repository,
                    mediaType: mediaType
                )
            } catch is ReaderExtensionError {
                // Mangayomi catalogs are community-maintained and a single
                // stale or incomplete row must not make every unrelated
                // source disappear. Invalid rows remain completely inert:
                // they are neither displayed nor installable, while every
                // admitted sibling still passes the full per-source policy.
                continue
            }
            if let existing = seen[source.id] {
                guard existing == source else {
                    throw ReaderExtensionError.invalidManifest("conflicting duplicate source identity \(source.id.rawValue)")
                }
                continue
            }
            seen[source.id] = source
            result.append(source)
        }
        return ReaderExtensionRepositoryCatalog(
            name: envelope.name,
            websiteURL: website,
            declaredLicenseName: envelope.license,
            declaredLicenseURL: licenseURL,
            sources: result
        )
    }
}

private struct ReaderExtensionRawCatalogEnvelope: Decodable {
    var name: String?
    var website: String?
    var license: String?
    var licenseURL: String?
    var sources: [ReaderExtensionRawCatalogSource]

    enum CodingKeys: String, CodingKey { case name, website, license, licenseURL, sources, extensions }

    init(name: String?, website: String?, license: String?, licenseURL: String?, sources: [ReaderExtensionRawCatalogSource]) {
        self.name = name; self.website = website; self.license = license; self.licenseURL = licenseURL; self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        name = try box.decodeIfPresent(String.self, forKey: .name)
        website = try box.decodeIfPresent(String.self, forKey: .website)
        license = try box.decodeIfPresent(String.self, forKey: .license)
        licenseURL = try box.decodeIfPresent(String.self, forKey: .licenseURL)
        sources = try box.decodeIfPresent([ReaderExtensionRawCatalogSource].self, forKey: .sources)
            ?? box.decode([ReaderExtensionRawCatalogSource].self, forKey: .extensions)
    }
}

private struct ReaderExtensionRawCatalogSource: Decodable {
    var name: String
    var id: String
    var baseURL: String
    var language: String
    var typeSource: String
    var dateFormat: String?
    var dateFormatLocale: String?
    var isNSFW: Bool?
    var hasCloudflare: Bool?
    var sourceCodeURL: String?
    var apiURL: String?
    var iconURL: String?
    var version: String?
    var isManga: Bool?
    var itemType: Int?
    var additionalParameters: String?
    var sourceCodeLanguage: ReaderExtensionCodeLanguage
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case name, id, baseUrl, lang, typeSource, dateFormat, dateFormatLocale, isNsfw, hasCloudflare
        case sourceCodeUrl, apiUrl, iconUrl, version, isManga, itemType, additionalParams, sourceCodeLanguage, notes
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        name = try box.decode(String.self, forKey: .name)
        if let integer = try? box.decode(Int64.self, forKey: .id) { id = String(integer) }
        else { id = try box.decode(String.self, forKey: .id) }
        baseURL = try box.decode(String.self, forKey: .baseUrl)
        language = try box.decodeIfPresent(String.self, forKey: .lang) ?? "und"
        typeSource = try box.decodeIfPresent(String.self, forKey: .typeSource) ?? "single"
        dateFormat = try box.decodeIfPresent(String.self, forKey: .dateFormat)
        dateFormatLocale = try box.decodeIfPresent(String.self, forKey: .dateFormatLocale)
        isNSFW = try box.decodeIfPresent(Bool.self, forKey: .isNsfw)
        hasCloudflare = try box.decodeIfPresent(Bool.self, forKey: .hasCloudflare)
        sourceCodeURL = try box.decodeIfPresent(String.self, forKey: .sourceCodeUrl)
        apiURL = try box.decodeIfPresent(String.self, forKey: .apiUrl)
        iconURL = try box.decodeIfPresent(String.self, forKey: .iconUrl)
        version = try box.decodeIfPresent(String.self, forKey: .version)
        isManga = try box.decodeIfPresent(Bool.self, forKey: .isManga)
        itemType = try box.decodeIfPresent(Int.self, forKey: .itemType)
        additionalParameters = try box.decodeIfPresent(String.self, forKey: .additionalParams)
        if let raw = try? box.decode(Int.self, forKey: .sourceCodeLanguage) {
            sourceCodeLanguage = ReaderExtensionCodeLanguage(catalogValue: raw)
        } else if let raw = try? box.decode(String.self, forKey: .sourceCodeLanguage) {
            sourceCodeLanguage = ReaderExtensionCodeLanguage(rawValue: raw.lowercased()) ?? .unsupported
        } else {
            sourceCodeLanguage = .dart
        }
        notes = try box.decodeIfPresent(String.self, forKey: .notes)
    }

    var mediaType: ReaderExtensionMediaType? {
        if itemType == 1 { return nil }
        if itemType == 2 || isManga == false { return .novel }
        return .manga
    }

    func normalized(
        indexURL: URL,
        repository: ReaderExtensionRepositoryRecord,
        mediaType: ReaderExtensionMediaType
    ) throws -> ReaderExtensionCatalogSource {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.utf8.count <= 512, id.utf8.count <= 128,
              baseURL.utf8.count <= 16 * 1_024,
              language.utf8.count <= 64,
              typeSource.utf8.count <= 128,
              (dateFormat?.utf8.count ?? 0) <= 128,
              (dateFormatLocale?.utf8.count ?? 0) <= 64,
              (sourceCodeURL?.utf8.count ?? 0) <= 16 * 1_024,
              (apiURL?.utf8.count ?? 0) <= 16 * 1_024,
              (iconURL?.utf8.count ?? 0) <= 16 * 1_024,
              (version?.utf8.count ?? 0) <= 128,
              (additionalParameters?.utf8.count ?? 0) <= 16 * 1_024,
              (notes?.utf8.count ?? 0) <= 4 * 1_024,
              let base = URL(string: baseURL), ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              let host = base.host, !host.isEmpty else {
            throw ReaderExtensionError.invalidManifest("invalid source identity or base URL")
        }
        let codeURL = sourceCodeURL.flatMap(URL.init(string:))
        if let sourceCodeURL, !sourceCodeURL.isEmpty, codeURL == nil {
            throw ReaderExtensionError.invalidManifest("source script URL is invalid")
        }
        if sourceCodeLanguage == .javascript {
            guard let codeURL else { throw ReaderExtensionError.invalidManifest("JavaScript source has no script URL") }
            try ReaderExtensionSecurityPolicy.validateScriptURLSyntax(codeURL)
        } else if let codeURL {
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(codeURL, requireHTTPS: true)
            guard codeURL.query == nil, codeURL.fragment == nil,
                  codeURL.user == nil, codeURL.password == nil else {
                throw ReaderExtensionError.invalidManifest("source code URL contains private or unstable components")
            }
        }
        let api = apiURL.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        if let apiURL, !apiURL.isEmpty, api == nil {
            throw ReaderExtensionError.invalidManifest("source API URL is invalid")
        }
        try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(base)
        guard base.query == nil, base.fragment == nil, base.user == nil, base.password == nil else {
            throw ReaderExtensionError.invalidManifest("source base URL contains private or unstable components")
        }
        if let api {
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(api)
            guard api.query == nil, api.fragment == nil, api.user == nil, api.password == nil else {
                throw ReaderExtensionError.invalidManifest("source API URL contains private or unstable components")
            }
        }
        let declaredIcon = iconURL.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        if let iconURL, !iconURL.isEmpty, declaredIcon == nil {
            throw ReaderExtensionError.invalidManifest("source icon URL is invalid")
        }
        let icon: URL?
        if let declaredIcon {
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(declaredIcon, requireHTTPS: true)
            try ReaderExtensionSecurityPolicy.validateNotArchive(data: Data(), response: nil, url: declaredIcon)
            guard declaredIcon.user == nil, declaredIcon.password == nil,
                  let sanitizedIcon = ReaderExtensionSecurityPolicy.sanitizedIconURL(declaredIcon) else {
                throw ReaderExtensionError.invalidManifest("source icon URL contains credentials")
            }
            // Icon queries survive with credential-bearing parameter names
            // removed: catalogs routinely point at favicon services whose
            // query IS the resource identity, and stripping it produced
            // icon-less sources that fetched a bare 404 endpoint forever.
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(sanitizedIcon, requireHTTPS: true)
            icon = sanitizedIcon
        } else {
            icon = nil
        }
        let implementation = ReaderExtensionImplementation.catalogValue(typeSource: typeSource, sourceCodeLanguage: sourceCodeLanguage)
        let sourceID = ReaderExtensionSourceID(repositoryURL: indexURL, upstreamID: id, language: language, mediaType: mediaType)
        return ReaderExtensionCatalogSource(
            id: sourceID,
            upstreamID: id,
            repositoryID: repository.id,
            repositoryURL: indexURL,
            name: cleanName,
            baseURL: base,
            apiURL: api,
            iconURL: icon,
            language: language,
            mediaType: mediaType,
            implementation: implementation,
            sourceCodeURL: codeURL,
            version: version ?? "0.0.0",
            maturity: isNSFW.map { $0 ? .mature : .safe } ?? .unknown,
            hasCloudflare: hasCloudflare ?? false,
            dateFormat: dateFormat,
            dateFormatLocale: dateFormatLocale,
            additionalParameters: additionalParameters,
            notes: notes,
            license: implementation == .javascript ? .unknown : repository.license
        )
    }
}
