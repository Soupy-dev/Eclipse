import Foundation
import Combine
import CryptoKit

public struct SkyStreamProviderDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var packageName: String
    public var providerID: String?
    public var displayName: String
    public var pluginName: String
    public var providerName: String?
    public var iconURL: String?
    public var isEnabled: Bool
    public var sortIndex: Int
    public var compatibility: SkyStreamCompatibilityResult
    public var selectedDomainURL: String?

    public init(
        id: String,
        packageName: String,
        providerID: String?,
        displayName: String,
        pluginName: String,
        providerName: String?,
        iconURL: String?,
        isEnabled: Bool,
        sortIndex: Int,
        compatibility: SkyStreamCompatibilityResult,
        selectedDomainURL: String?
    ) {
        self.id = id
        self.packageName = packageName
        self.providerID = providerID
        self.displayName = displayName
        self.pluginName = pluginName
        self.providerName = providerName
        self.iconURL = iconURL
        self.isEnabled = isEnabled
        self.sortIndex = sortIndex
        self.compatibility = compatibility
        self.selectedDomainURL = selectedDomainURL
    }
}

struct SkyStreamRuntimeAuthoritySnapshot: Sendable {
    let provider: SkyStreamProviderDescriptor
    let plugin: SkyStreamInstalledPluginState
    let revision: UUID
}

public enum SkyStreamReplacementPolicy: Sendable {
    case normal
    case userConfirmedReplacement
}

public struct SkyStreamSafeCloudRestoreResult: Sendable, Equatable {
    public let unresolvedPackageIDs: [String]

    public var isComplete: Bool { unresolvedPackageIDs.isEmpty }

    public init(unresolvedPackageIDs: [String] = []) {
        self.unresolvedPackageIDs = Array(Set(unresolvedPackageIDs)).sorted()
    }
}

public enum SkyStreamPluginManagerError: Error, Sendable, Equatable {
    case unavailable
    case managerNotLoaded
    case stateLoadFailed
    case packageNotFound
    case repositoryNotFound
    case pluginEntryNotFound
    case catalogManifestMismatch
    case provenanceTakeoverRequiresConfirmation
    case downgradeRequiresConfirmation(installed: Int, proposed: Int)
    case sameVersionCodeReplacementRequiresConfirmation
    case packageIncompatible(String)
    case integrityFailure
    case invalidPersistedPath
    case persistenceFailed
    case capacityLimitReached(kind: String, maximum: Int)
    case persistedStateBudgetExceeded(maximumBytes: Int)
    case invalidBackup
    case backupArchiveBudgetExceeded(maximumBytes: Int)
    case backupRollbackFailed
    case stateChangedDuringValidation
    case validationAlreadyInProgress
    case requiresGrownUpProfile
}

extension SkyStreamPluginManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "SkyStream plugins are available only on iPhone and iPad."
        case .managerNotLoaded:
            return "SkyStream is still loading its saved state."
        case .stateLoadFailed:
            return "SkyStream could not read its saved data. Open SkyStream Plugins to retry or reset it."
        case .packageNotFound:
            return "The SkyStream package is not installed."
        case .repositoryNotFound:
            return "The saved SkyStream repository could not be found."
        case .pluginEntryNotFound:
            return "The plugin is no longer present in its pinned repository."
        case .catalogManifestMismatch:
            return "The package manifest does not match its repository entry."
        case .provenanceTakeoverRequiresConfirmation:
            return "A different source cannot replace this package without explicit confirmation."
        case .downgradeRequiresConfirmation(let installed, let proposed):
            return "Version \(proposed) is older than installed version \(installed). Confirm replacement to continue."
        case .sameVersionCodeReplacementRequiresConfirmation:
            return "This source replaced code without changing its version. Confirm replacement to continue."
        case .packageIncompatible(let reason):
            return reason
        case .integrityFailure:
            return "The installed SkyStream package failed its integrity check."
        case .invalidPersistedPath:
            return "The saved SkyStream package path is invalid."
        case .persistenceFailed:
            return "The SkyStream package was validated but its state could not be saved."
        case .capacityLimitReached(let kind, let maximum):
            return "Eclipse supports at most \(maximum) SkyStream \(kind). Remove one before adding another."
        case .persistedStateBudgetExceeded(let maximumBytes):
            let maximumMiB = maximumBytes / (1_024 * 1_024)
            return "The saved SkyStream repositories and packages exceed the \(maximumMiB) MB storage limit. Remove a saved repository or an installed package before adding another."
        case .invalidBackup:
            return "The SkyStream backup contains invalid or incomplete package data."
        case .backupArchiveBudgetExceeded(let maximumBytes):
            let maximumMiB = maximumBytes / (1_024 * 1_024)
            return "The installed SkyStream package archives exceed the \(maximumMiB) MB manual-backup limit. Remove some packages or install smaller packages before exporting."
        case .backupRollbackFailed:
            return "The SkyStream restore failed and its previous state could not be fully re-applied."
        case .stateChangedDuringValidation:
            return "SkyStream settings changed while the package was being checked. Please try again."
        case .validationAlreadyInProgress:
            return "SkyStream is already checking this package or has reached its validation limit. Wait for an existing check to finish before trying again."
        case .requiresGrownUpProfile:
            return "This is a kids profile. Switch to a grown-up profile to change installed SkyStream plugins."
        }
    }
}

struct SkyStreamServiceScopeAuthority: Equatable {
    let profileID: UUID
    let serviceStoreGeneration: Int

    @MainActor
    static func capture() -> Self {
        Self(
            profileID: ProfileManager.shared.activeProfileID,
            serviceStoreGeneration: ServiceStoreScope.generation
        )
    }

    func matches(profileID: UUID, serviceStoreGeneration: Int) -> Bool {
        self.profileID == profileID
            && self.serviceStoreGeneration == serviceStoreGeneration
    }

    @MainActor
    var isCurrent: Bool {
        matches(
            profileID: ProfileManager.shared.activeProfileID,
            serviceStoreGeneration: ServiceStoreScope.generation
        )
    }
}

enum ServicePluginAdministrativeAdmissionPolicy {
    static func permits(isKidsProfile: Bool) -> Bool {
        !isKidsProfile
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)

private enum SkyStreamSafeRestoreTaskContext {
    @TaskLocal static var token: UUID?
}

struct SkyStreamManualBackupCapturePlan: Sendable {
    struct Plugin: Sendable {
        let state: SkyStreamInstalledPluginState
        let archiveURL: URL
    }

    let repositories: [SkyStreamRepositoryBackupSnapshot]
    let plugins: [Plugin]
}

@MainActor
public final class SkyStreamPluginManager: ObservableObject {
    public static let shared = SkyStreamPluginManager()
    nonisolated static let pendingSafeCloudSnapshotKey = "skyStreamPendingSafeCloudSnapshot.v1"

    nonisolated private static let maximumPackageArchiveBytes = 20 * 1_024 * 1_024
    nonisolated private static let maximumManualBackupArchiveBytes = 64 * 1_024 * 1_024
    private static let maximumManualRestoreExpandedBytes: UInt64 = 256 * 1_024 * 1_024
    private static let maximumRepositoryCount = 64
    private static let maximumInstalledPluginCount = 128
    private static let maximumProviderStateCount = 256
    private static let maximumConcurrentPackageValidations = 4
    nonisolated private static let maximumPersistedStateBytes = 6 * 1_024 * 1_024

    @Published public private(set) var repositories: [SkyStreamSavedRepository] = []
    @Published public private(set) var installedPlugins: [SkyStreamInstalledPluginState] = [] {
        didSet {
            cachedPluginsByID = installedPlugins.reduce(
                into: [String: SkyStreamInstalledPluginState]()
            ) {
                if $0[$1.id] == nil { $0[$1.id] = $1 }
            }
            cachedProviderOrder = nil
            cachedProviders = []
            cachedProvidersByID = [:]
        }
    }
    @Published public private(set) var isLoaded = false
    @Published public private(set) var stateLoadDidFail = false
    @Published public private(set) var unreadablePackageIDs: [String] = []
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var lastNoticeMessage: String?

    private var committedRepositories: [SkyStreamSavedRepository] = []
    private var committedInstalledPlugins: [SkyStreamInstalledPluginState] = []
    private var committedPluginsByID: [String: SkyStreamInstalledPluginState] = [:]
    private var runtimeAuthorityRevisions: [String: UUID] = [:]
    private var cachedPluginsByID: [String: SkyStreamInstalledPluginState] = [:]
    private var cachedProviderOrder: [String]?
    private var cachedProviders: [SkyStreamProviderDescriptor] = []
    private var cachedProvidersByID: [String: SkyStreamProviderDescriptor] = [:]

    private struct PersistedState: Codable, Sendable {
        var schemaVersion: Int
        var repositories: [SkyStreamSavedRepository]
        var installedPlugins: [SkyStreamInstalledPluginState]

        init(
            schemaVersion: Int = 1,
            repositories: [SkyStreamSavedRepository],
            installedPlugins: [SkyStreamInstalledPluginState]
        ) {
            self.schemaVersion = schemaVersion
            self.repositories = repositories
            self.installedPlugins = installedPlugins
        }
    }

    private let store: ServiceStore
    private let repositoryManager: SkyStreamRepositoryManager
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let applicationSupportRoot: URL
    private let skyStreamRoot: URL
    private let packageRoot: URL
    private let archiveRoot: URL
    private let stagingRoot: URL

    private var mutationGateIsHeld = false
    private var mutationGateWaiters: [CheckedContinuation<Void, Never>] = []

    private var packagesWithRuntimeValidationInFlight = Set<String>()

    private var activeSafeRestoreTokens = Set<UUID>()
    private var invalidatedSafeRestoreTokens = Set<UUID>()

    private var runtimePublicationBlockedPackageIDs = Set<String>()

    private struct PackageCodeFingerprint: Hashable, Sendable {
        let packageName: String
        let version: Int
        let archiveSHA256: String
        let scriptSHA256: String
        let payloadRelativePath: String

        init(_ plugin: SkyStreamInstalledPluginState) {
            packageName = plugin.id
            version = plugin.manifest.version
            archiveSHA256 = plugin.archiveSHA256.lowercased()
            scriptSHA256 = plugin.scriptSHA256.lowercased()
            payloadRelativePath = plugin.payloadRelativePath
        }
    }

    private struct DynamicProviderConfigurationFingerprint: Equatable {
        let code: PackageCodeFingerprint
        let selectedDomainURL: String?
        let preferences: [String: SkyStreamPreferenceValue]
        let runtimeStorage: [String: String]?

        init(_ plugin: SkyStreamInstalledPluginState) {
            code = PackageCodeFingerprint(plugin)
            selectedDomainURL = plugin.selectedDomainURL
            preferences = plugin.preferences
            runtimeStorage = plugin.runtimeStorage
        }
    }

    private struct PreparedDynamicProviderRefresh {
        let packageName: String
        let expectedConfiguration: DynamicProviderConfigurationFingerprint
        let providers: [SkyStreamPluginProvider]

        let runtimeSnapshot: SkyStreamRuntimeStorageSnapshot
        let scopeAuthority: SkyStreamServiceScopeAuthority
    }

    private struct RepositoryInstallAuthority: Equatable {
        let repository: SkyStreamSavedRepository
        let entry: SkyStreamPluginListEntry
    }

    private struct InstallValidationAuthorityFingerprint: Equatable {
        let code: PackageCodeFingerprint
        let selectedDomainURL: String?
        let provenanceBehaviorIdentity: String
        let publicPreferences: [String: SkyStreamJSONValue]

        init(_ plugin: SkyStreamInstalledPluginState) {
            code = PackageCodeFingerprint(plugin)
            selectedDomainURL = plugin.selectedDomainURL
            provenanceBehaviorIdentity = SkyStreamPluginManager.provenanceBehaviorIdentity(
                plugin.provenance
            )
            publicPreferences = plugin.preferences.reduce(into: [:]) {
                guard !$1.value.isSecret, !$1.value.isRedacted else { return }
                $0[$1.key] = $1.value.value
            }
        }
    }

    private struct PreparedInstall {
        let transactionRootURL: URL
        let stagedPayloadURL: URL
        let archiveData: Data
        let validatedManifest: SkyStreamPluginManifest
        let effectiveManifest: SkyStreamPluginManifest
        let archiveSHA256: String
        let scriptSHA256: String
        let compatibility: SkyStreamCompatibilityResult
        let usesDynamicProviders: Bool
        let provenance: SkyStreamInstallProvenance
        let expectedEntry: SkyStreamPluginListEntry?
        let replacementPolicy: SkyStreamReplacementPolicy
        let existingAtPreparation: SkyStreamInstalledPluginState?
        let repositoryAuthority: RepositoryInstallAuthority?
        let requiredPackageName: String?
        let isByteIdenticalReinstall: Bool

        let scopeAuthority: SkyStreamServiceScopeAuthority
    }

    private struct CommittedInstall {
        let installed: SkyStreamInstalledPluginState
    }

    private enum SafeCloudReconstructionFetch: Sendable {
        case package(id: String, data: Data?)
        case deadline
    }

    private struct SafeCloudMetadataCommit {
        let configuredPackageIDs: [String]
        let dynamicPackageIDs: [String]
    }

    private struct SafeCloudConfigurationFingerprint: Equatable {
        let dynamicConfiguration: DynamicProviderConfigurationFingerprint
        let providers: [SkyStreamProviderState]

        init(_ plugin: SkyStreamInstalledPluginState) {
            dynamicConfiguration = DynamicProviderConfigurationFingerprint(plugin)
            providers = plugin.providers
        }
    }

    struct SkySourceDefaultsSnapshot: Equatable {
        var selectedIDs: [String]
        var orderIDs: [String]
        var explicitIDs: [String]?
    }

    private func withMutationGate<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamPluginManagerError.unavailable
        }
        try Task.checkCancellation()
        await acquireMutationGate()
        defer { releaseMutationGate() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquireMutationGate() async {
        if !mutationGateIsHeld {
            mutationGateIsHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationGateWaiters.append(continuation)
        }
    }

    private func releaseMutationGate() {
        precondition(mutationGateIsHeld, "SkyStream mutation gate released without an owner")
        if mutationGateWaiters.isEmpty {
            mutationGateIsHeld = false
        } else {
            let next = mutationGateWaiters.removeFirst()

            next.resume()
        }
    }

    private func beginPackageRuntimeValidation(packageName: String) throws {
        guard !packagesWithRuntimeValidationInFlight.contains(packageName),
              packagesWithRuntimeValidationInFlight.count
                < Self.maximumConcurrentPackageValidations else {
            throw SkyStreamPluginManagerError.validationAlreadyInProgress
        }
        packagesWithRuntimeValidationInFlight.insert(packageName)
    }

    private func endPackageRuntimeValidation(packageName: String) {
        packagesWithRuntimeValidationInFlight.remove(packageName)
    }

    private func beginSafeRestore() -> UUID {
        let token = UUID()
        activeSafeRestoreTokens.insert(token)
        return token
    }

    private func endSafeRestore(_ token: UUID) {
        activeSafeRestoreTokens.remove(token)
        invalidatedSafeRestoreTokens.remove(token)
    }

    private func requireSafeRestoreIsCurrent(_ token: UUID) throws {
        guard activeSafeRestoreTokens.contains(token),
              !invalidatedSafeRestoreTokens.contains(token) else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
    }

    private func invalidateConcurrentSafeRestores(afterPersistFrom origin: UUID?) {
        invalidatedSafeRestoreTokens.formUnion(
            activeSafeRestoreTokens.filter { $0 != origin }
        )
    }

    private func updateRuntimePublicationFence(
        adding: Set<String> = [],
        removing: Set<String> = []
    ) {
        runtimePublicationBlockedPackageIDs.formUnion(adding)
        runtimePublicationBlockedPackageIDs.subtract(removing)
        cachedProviderOrder = nil
        cachedProviders = []
        cachedProvidersByID = [:]
    }

    private func reconcileSkySourceDefaults(defaults: UserDefaults = ProfileSettingsStore.services) {
        struct DurableSource {
            let id: String
            let state: SkyStreamProviderState
            let fallbackOrder: Int
        }

        var durableSources: [DurableSource] = []
        var fallbackOrder = 0
        for plugin in committedInstalledPlugins {
            let activeStates = plugin.providers.reduce(into: [String: SkyStreamProviderState]()) {
                guard $1.removedAt == nil, $0[$1.id] == nil else { return }
                $0[$1.id] = $1
            }
            for pair in Self.currentProviderPairs(for: plugin.manifest) {
                guard let state = activeStates[pair.sourceID] else { continue }
                durableSources.append(DurableSource(
                    id: pair.sourceID,
                    state: state,
                    fallbackOrder: fallbackOrder
                ))
                fallbackOrder += 1
            }
        }
        let durableIDs = Set(durableSources.map(\.id))
        let missingOrder = durableSources.sorted {
            switch ($0.state.sourceOrder, $1.state.sourceOrder) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.fallbackOrder < $1.fallbackOrder
            }
        }.map(\.id)

        func removingStaleSkySources(_ values: [String]) -> [String] {
            values.filter { id in
                !id.hasPrefix(SkyStreamStableID.prefix) || durableIDs.contains(id)
            }
        }

        var order = removingStaleSkySources(
            defaults.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? []
        )
        var ordered = Set(order)
        var newlyOfferedIDs: [String] = []
        for id in missingOrder where ordered.insert(id).inserted {
            order.append(id)
            newlyOfferedIDs.append(id)
        }
        defaults.set(order, forKey: "servicesAutoModeSourceOrderIds")

        var selected = removingStaleSkySources(
            defaults.stringArray(forKey: "servicesAutoModeSourceIds") ?? []
        )
        var selectedIDs = Set(selected)
        for id in newlyOfferedIDs where selectedIDs.insert(id).inserted {
            selected.append(id)
        }
        defaults.set(selected, forKey: "servicesAutoModeSourceIds")

        if let explicit = StreamLanguageFilter.extraRulesSourceIds(defaults: defaults) {
            let reconciled = removingStaleSkySources(explicit)
            StreamLanguageFilter.setExtraRulesSourceIds(reconciled, defaults: defaults)
        }
    }

    private func sourceDefaultsSnapshot(
        defaults: UserDefaults = ProfileSettingsStore.services
    ) -> SkySourceDefaultsSnapshot {
        SkySourceDefaultsSnapshot(
            selectedIDs: defaults.stringArray(forKey: "servicesAutoModeSourceIds") ?? [],
            orderIDs: defaults.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? [],
            explicitIDs: StreamLanguageFilter.extraRulesSourceIds(defaults: defaults)
        )
    }

    private static func applySourceDefaultsSnapshot(
        _ snapshot: SkySourceDefaultsSnapshot,
        defaults: UserDefaults = ProfileSettingsStore.services
    ) {
        defaults.set(snapshot.selectedIDs, forKey: "servicesAutoModeSourceIds")
        defaults.set(snapshot.orderIDs, forKey: "servicesAutoModeSourceOrderIds")
        StreamLanguageFilter.setExtraRulesSourceIds(snapshot.explicitIDs, defaults: defaults)
    }

    private static func reconciledSourceDefaultsSnapshot(
        _ snapshot: SkySourceDefaultsSnapshot,
        plugins: [SkyStreamInstalledPluginState]
    ) -> SkySourceDefaultsSnapshot {
        struct DurableSource {
            let id: String
            let state: SkyStreamProviderState
            let fallbackOrder: Int
        }
        var durableSources: [DurableSource] = []
        var fallbackOrder = 0
        for plugin in plugins {
            let activeStates = plugin.providers.reduce(into: [String: SkyStreamProviderState]()) {
                guard $1.removedAt == nil, $0[$1.id] == nil else { return }
                $0[$1.id] = $1
            }
            for pair in currentProviderPairs(for: plugin.manifest) {
                guard let state = activeStates[pair.sourceID] else { continue }
                durableSources.append(DurableSource(
                    id: pair.sourceID,
                    state: state,
                    fallbackOrder: fallbackOrder
                ))
                fallbackOrder += 1
            }
        }
        let durableIDs = Set(durableSources.map(\.id))
        let durableOrder = durableSources.sorted {
            switch ($0.state.sourceOrder, $1.state.sourceOrder) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.fallbackOrder < $1.fallbackOrder
            }
        }.map(\.id)
        func removingStaleSkySources(_ values: [String]) -> [String] {
            values.filter {
                !$0.hasPrefix(SkyStreamStableID.prefix) || durableIDs.contains($0)
            }
        }

        var result = snapshot
        result.orderIDs = removingStaleSkySources(result.orderIDs)
        var ordered = Set(result.orderIDs)
        for sourceID in durableOrder where ordered.insert(sourceID).inserted {
            result.orderIDs.append(sourceID)
        }
        result.selectedIDs = removingStaleSkySources(result.selectedIDs)
        if let explicitIDs = result.explicitIDs {
            result.explicitIDs = removingStaleSkySources(explicitIDs)
        }
        return result
    }

    private static func pluginByOverlayingSourceDefaults(
        _ plugin: SkyStreamInstalledPluginState,
        snapshot: SkySourceDefaultsSnapshot
    ) -> SkyStreamInstalledPluginState {
        let selected = Set(snapshot.selectedIDs)
        let explicit = snapshot.explicitIDs.map { Set($0) }
        let orderRank = snapshot.orderIDs.enumerated().reduce(into: [String: Int]()) {
            if $0[$1.element] == nil { $0[$1.element] = $1.offset }
        }
        let currentIDs = Set(Self.currentProviderPairs(for: plugin.manifest).map(\.sourceID))
        var result = plugin
        for index in result.providers.indices {
            let sourceID = result.providers[index].id
            guard result.providers[index].removedAt == nil, currentIDs.contains(sourceID) else {
                continue
            }
            result.providers[index].sourceOrder = orderRank[sourceID]
            result.providers[index].isAutoModeSelected = selected.contains(sourceID)
            result.providers[index].isExplicitlySelectedForExtraRules = explicit.map {
                $0.contains(sourceID)
            }
        }
        return result
    }

    static func mergedSafeCloudSourceDefaults(
        baseline: SkySourceDefaultsSnapshot,
        current: SkySourceDefaultsSnapshot,
        incomingBySourceID: [String: SkyStreamProviderState],
        allCurrentSourceIDs: Set<String>
    ) -> SkySourceDefaultsSnapshot {
        guard !incomingBySourceID.isEmpty else { return current }
        var target = current

        func contains(_ id: String, in values: [String]) -> Bool {
            values.contains(id)
        }
        for (sourceID, incoming) in incomingBySourceID.sorted(by: { $0.key < $1.key }) {
            guard contains(sourceID, in: current.selectedIDs)
                    == contains(sourceID, in: baseline.selectedIDs) else { continue }
            target.selectedIDs.removeAll { $0 == sourceID }
            if incoming.isAutoModeSelected { target.selectedIDs.append(sourceID) }
        }

        func firstRanks(_ values: [String]) -> [String: Int] {
            values.enumerated().reduce(into: [:]) {
                if $0[$1.element] == nil { $0[$1.element] = $1.offset }
            }
        }
        let baselineRanks = firstRanks(baseline.orderIDs)
        let currentRanks = firstRanks(current.orderIDs)
        let remotelyOrdered = incomingBySourceID.filter {
            currentRanks[$0.key] == baselineRanks[$0.key]
        }
        target.orderIDs.removeAll { remotelyOrdered[$0] != nil }
        for (sourceID, state) in remotelyOrdered.sorted(by: {
            switch ($0.value.sourceOrder, $1.value.sourceOrder) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.key < $1.key
            }
        }) {
            let insertionIndex = min(max(0, state.sourceOrder ?? target.orderIDs.count), target.orderIDs.count)
            target.orderIDs.insert(sourceID, at: insertionIndex)
        }

        let baselineExplicit = baseline.explicitIDs.map { Set($0) }
        let currentExplicit = current.explicitIDs.map { Set($0) }
        let explicitModeChanged = (baselineExplicit == nil) != (currentExplicit == nil)
        if !explicitModeChanged {
            var explicitValues = current.explicitIDs
            if explicitValues == nil,
               incomingBySourceID.values.contains(where: {
                   $0.isExplicitlySelectedForExtraRules == false
               }) {

                var seen = Set<String>()
                explicitValues = (current.orderIDs + current.selectedIDs
                    + allCurrentSourceIDs.sorted()).filter { seen.insert($0).inserted }
            }
            if var explicitValues {
                for (sourceID, incoming) in incomingBySourceID.sorted(by: { $0.key < $1.key }) {
                    let baselineContains = baselineExplicit?.contains(sourceID) ?? true
                    let currentContains = currentExplicit?.contains(sourceID) ?? true
                    guard baselineContains == currentContains else { continue }
                    explicitValues.removeAll { $0 == sourceID }
                    if incoming.isExplicitlySelectedForExtraRules ?? true {
                        explicitValues.append(sourceID)
                    }
                }

                target.explicitIDs = explicitValues
            }
        }
        return target
    }

    public func captureSourceDefaultsState(expectedScopeGeneration: Int? = nil) async {
        guard isLoaded, PlatformCapabilities.current.supportsSkyStreamPlugins,
              expectedScopeGeneration.map(ServiceStoreScope.isCurrent) ?? true else { return }
        do {
            try await withMutationGate {
                guard expectedScopeGeneration.map(ServiceStoreScope.isCurrent) ?? true else {
                    throw SkyStreamPluginManagerError.stateChangedDuringValidation
                }
                try await captureSourceDefaultsStateUnlocked(
                    expectedScopeGeneration: expectedScopeGeneration
                )
            }
        } catch {
            log("failed to persist source settings", error: error)
        }
    }

    private func captureSourceDefaultsStateUnlocked(
        defaults: UserDefaults = ProfileSettingsStore.services,
        expectedScopeGeneration: Int? = nil
    ) async throws {
        guard expectedScopeGeneration.map(ServiceStoreScope.isCurrent) ?? true else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        let selectedSourceIDs = Set(
            defaults.stringArray(forKey: "servicesAutoModeSourceIds") ?? []
        )
        let orderedSourceIDs = defaults.stringArray(
            forKey: "servicesAutoModeSourceOrderIds"
        ) ?? []
        let sourceOrder = orderedSourceIDs.enumerated().reduce(into: [String: Int]()) {
            if $0[$1.element] == nil { $0[$1.element] = $1.offset }
        }
        let explicitlySelectedSourceIDs = StreamLanguageFilter
            .extraRulesSourceIds(defaults: defaults)
            .map { Set($0) }

        var candidate = installedPlugins
        for pluginIndex in candidate.indices {
            let currentSourceIDs = Set(
                Self.currentProviderPairs(for: candidate[pluginIndex].manifest).map(\.sourceID)
            )
            var pluginChanged = false
            for providerIndex in candidate[pluginIndex].providers.indices {
                var state = candidate[pluginIndex].providers[providerIndex]
                guard state.removedAt == nil, currentSourceIDs.contains(state.id) else { continue }
                let newOrder = sourceOrder[state.id]
                let isSelected = selectedSourceIDs.contains(state.id)
                let isExplicitlySelected = explicitlySelectedSourceIDs.map { $0.contains(state.id) }
                guard state.sourceOrder != newOrder
                        || state.isAutoModeSelected != isSelected
                        || state.isExplicitlySelectedForExtraRules != isExplicitlySelected else {
                    continue
                }
                state.sourceOrder = newOrder
                state.isAutoModeSelected = isSelected
                state.isExplicitlySelectedForExtraRules = isExplicitlySelected
                candidate[pluginIndex].providers[providerIndex] = state
                pluginChanged = true
            }
            if pluginChanged {
                candidate[pluginIndex].updatedAt = Date()
            }
        }
        guard candidate != installedPlugins else { return }
        guard expectedScopeGeneration.map(ServiceStoreScope.isCurrent) ?? true else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        installedPlugins = candidate
        try await persist()
    }

    public init(
        store: ServiceStore = .shared,
        repositoryManager: SkyStreamRepositoryManager = .shared,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.repositoryManager = repositoryManager
        self.fileManager = fileManager
        self.decoder = JSONDecoder()

        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory.appendingPathComponent("EclipseApplicationSupport", isDirectory: true)
        self.applicationSupportRoot = support.standardizedFileURL
        self.skyStreamRoot = support.appendingPathComponent("SkyStream", isDirectory: true).standardizedFileURL
        self.packageRoot = skyStreamRoot.appendingPathComponent("Packages", isDirectory: true)
        self.archiveRoot = skyStreamRoot.appendingPathComponent("Archives", isDirectory: true)
        self.stagingRoot = skyStreamRoot.appendingPathComponent("Staging", isDirectory: true)

        Task { [weak self] in
            await self?.loadPersistedState()
        }

        NotificationCenter.default.addObserver(
            forName: ServiceStoreScope.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.loadPersistedState()
            }
        }
    }

    public var providers: [SkyStreamProviderDescriptor] {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else { return [] }
        let order = ProfileSettingsStore.services.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? []
        if cachedProviderOrder == order { return cachedProviders }
        let orderRank = order.enumerated().reduce(into: [String: Int]()) {
            if $0[$1.element] == nil { $0[$1.element] = $1.offset }
        }
        var descriptors: [SkyStreamProviderDescriptor] = []
        for plugin in committedInstalledPlugins
            where !runtimePublicationBlockedPackageIDs.contains(plugin.id) {
            let current = Self.currentProviderPairs(for: plugin.manifest)
            let stateByID = plugin.providers.reduce(into: [String: SkyStreamProviderState]()) {

                if $0[$1.id] == nil { $0[$1.id] = $1 }
            }
            for pair in current {
                let sourceID = SkyStreamStableID.sourceID(
                    packageName: plugin.manifest.packageName,
                    providerID: pair.provider?.id
                )
                guard let state = stateByID[sourceID], state.removedAt == nil else { continue }
                let displayName = pair.provider.map { "\(plugin.manifest.name) — \($0.name)" }
                    ?? plugin.manifest.name
                descriptors.append(SkyStreamProviderDescriptor(
                    id: sourceID,
                    packageName: plugin.manifest.packageName,
                    providerID: pair.provider?.id,
                    displayName: displayName,
                    pluginName: plugin.manifest.name,
                    providerName: pair.provider?.name,
                    iconURL: pair.provider?.iconURL ?? plugin.manifest.iconURL,
                    isEnabled: state.isEnabled && plugin.compatibility.status != .incompatible,
                    sortIndex: orderRank[sourceID] ?? Int.max,
                    compatibility: plugin.compatibility,
                    selectedDomainURL: plugin.selectedDomainURL
                ))
            }
        }
        let sorted = descriptors.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        cachedProviderOrder = order
        cachedProviders = sorted
        cachedProvidersByID = sorted.reduce(into: [:]) {
            if $0[$1.id] == nil { $0[$1.id] = $1 }
        }
        return sorted
    }

    public func provider(sourceID: String) -> SkyStreamProviderDescriptor? {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else { return nil }
        _ = providers
        return cachedProvidersByID[sourceID]
    }

    public func plugin(packageName: String) -> SkyStreamInstalledPluginState? {
        guard !runtimePublicationBlockedPackageIDs.contains(packageName) else { return nil }
        return committedPluginsByID[packageName]
    }

    func runtimeAuthoritySnapshot(sourceID: String) -> SkyStreamRuntimeAuthoritySnapshot? {
        guard let provider = provider(sourceID: sourceID),
              let plugin = plugin(packageName: provider.packageName),
              let revision = runtimeAuthorityRevisions[plugin.id] else {
            return nil
        }
        return SkyStreamRuntimeAuthoritySnapshot(
            provider: provider,
            plugin: plugin,
            revision: revision
        )
    }

    public func dismissNotice() {
        lastNoticeMessage = nil
    }

    public func addUserInput(_ rawURL: String) async throws -> SkyStreamResolvedInput {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamPluginManagerError.unavailable
        }
        guard isLoaded else { throw notLoadedError }
        let resolution = try await repositoryManager.resolveUserInput(rawURL)
        if case .repository(let repository) = resolution {
            try await saveRepository(repository)
            return resolution
        }
        guard case .archive(let data, _) = resolution else { return resolution }

        let pinnedURL = try SkyStreamRemoteURLPolicy.shared.validateSyntactic(
            rawURL,
            purpose: .package
        ).url
        return .archive(data: data, sourceURL: pinnedURL)
    }

    public func saveRepository(_ repository: SkyStreamSavedRepository) async throws {
        let scopeAuthority = SkyStreamServiceScopeAuthority.capture()
        try await withMutationGate {
            try await saveRepositoryUnlocked(
                repository,
                expectedScopeAuthority: scopeAuthority
            )
        }
    }

    private func saveRepositoryUnlocked(
        _ repository: SkyStreamSavedRepository,
        expectedScopeAuthority: SkyStreamServiceScopeAuthority
    ) async throws {
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        guard isLoaded else { throw notLoadedError }
        guard repository.plugins.count <= 2_000,
              repository.pluginListURLs.count <= 32,
              !repository.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              repository.name.utf8.count <= 256,
              Self.backupRepository(repository) != nil else {
            throw SkyStreamRepositoryError.invalidRepositoryManifest
        }
        _ = try SkyStreamRemoteURLPolicy.shared.validateSyntactic(
            repository.sourceURL,
            purpose: .repository
        )
        for listURL in repository.pluginListURLs {
            _ = try SkyStreamRemoteURLPolicy.shared.validateSyntactic(
                listURL,
                purpose: .repository
            )
        }
        var candidate = repositories
        if let index = candidate.firstIndex(where: { $0.sourceURL == repository.sourceURL }) {
            candidate[index] = repository
        } else {
            guard candidate.count < Self.maximumRepositoryCount else {
                throw SkyStreamPluginManagerError.capacityLimitReached(
                    kind: "repositories",
                    maximum: Self.maximumRepositoryCount
                )
            }
            candidate.append(repository)
        }
        let previous = repositories
        repositories = candidate
        do {
            try await persist(
                expectedScopeGeneration: expectedScopeAuthority.serviceStoreGeneration
            )
            guard expectedScopeAuthority.isCurrent else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
            log("repository saved", url: repository.sourceURL)
        } catch {
            if expectedScopeAuthority.isCurrent {
                repositories = previous
            }
            throw error
        }
    }

    public func refreshRepositoriesAndInstalledPlugins(autoUpdate: Bool) async {
        guard isLoaded,
              PlatformCapabilities.current.supportsSkyStreamPlugins,
              canAdministerPlugins else { return }
        let scopeAuthority = SkyStreamServiceScopeAuthority.capture()
        let repositoriesAtStart = repositories.filter { $0.frozenAt == nil }
        for repository in repositoriesAtStart {
            guard !Task.isCancelled,
                  canAdministerPlugins,
                  scopeAuthority.isCurrent else { return }
            do {
                let refreshed = try await repositoryManager.refresh(repository)
                guard canAdministerPlugins, scopeAuthority.isCurrent else { return }
                try await withMutationGate {
                    guard canAdministerPlugins,
                          scopeAuthority.isCurrent,
                          repositories.contains(repository) else { return }
                    try await saveRepositoryUnlocked(
                        refreshed,
                        expectedScopeAuthority: scopeAuthority
                    )
                }
            } catch {
                guard scopeAuthority.isCurrent else { return }
                log("repository refresh failed", url: repository.sourceURL, error: error)
            }
        }
        guard canAdministerPlugins, scopeAuthority.isCurrent else { return }
        let dynamicCodeBeforeUpdate = installedPlugins
            .filter { $0.usesDynamicProviders == true }
            .reduce(into: [String: String]()) {
                if $0[$1.id] == nil {
                    $0[$1.id] = "\($1.manifest.version)|\($1.archiveSHA256)"
                }
            }
        if autoUpdate {
            let pluginsAtStart = installedPlugins.filter { $0.provenance.frozenAt == nil }
            for plugin in pluginsAtStart {
                guard !Task.isCancelled,
                      canAdministerPlugins,
                      scopeAuthority.isCurrent else { return }
                do {
                    try await updateIfAvailable(
                        packageName: plugin.manifest.packageName,
                        expectedScopeAuthority: scopeAuthority
                    )
                } catch {
                    guard scopeAuthority.isCurrent else { return }
                    log("automatic update retained installed version", packageName: plugin.manifest.packageName, error: error)
                }
            }
        }
        guard canAdministerPlugins, scopeAuthority.isCurrent else { return }
        let dynamicPackages = installedPlugins
            .filter { $0.usesDynamicProviders == true }
            .map(\.id)
        for packageName in dynamicPackages {
            guard !Task.isCancelled,
                  canAdministerPlugins,
                  scopeAuthority.isCurrent else { return }
            if autoUpdate,
               let previousCode = dynamicCodeBeforeUpdate[packageName],
               let current = plugin(packageName: packageName),
               previousCode != "\(current.manifest.version)|\(current.archiveSHA256)" {

                continue
            }
            do {
                try await refreshDynamicProviders(
                    packageName: packageName,
                    expectedScopeAuthority: scopeAuthority
                )
            } catch {
                guard scopeAuthority.isCurrent else { return }
                log("dynamic provider refresh retained previous rows", packageName: packageName, error: error)
            }
        }
    }

    public func removeRepository(sourceURL: String) async throws {
        try await withMutationGate {
            try await removeRepositoryUnlocked(sourceURL: sourceURL)
        }
    }

    private func removeRepositoryUnlocked(sourceURL: String) async throws {
        guard let repositoryIndex = repositories.firstIndex(where: { $0.sourceURL == sourceURL }) else {
            throw SkyStreamPluginManagerError.repositoryNotFound
        }
        let oldRepositories = repositories
        let oldPlugins = installedPlugins
        repositories.remove(at: repositoryIndex)
        let now = Date()
        for index in installedPlugins.indices where Self.provenanceIdentity(installedPlugins[index].provenance) == sourceURL {
            installedPlugins[index].provenance.frozenAt = now
        }
        do {
            try await persist()
            log("repository removed; installed packages retained", url: sourceURL)
        } catch {
            repositories = oldRepositories
            installedPlugins = oldPlugins
            throw error
        }
    }

    private func refreshDynamicProviders(
        packageName: String,
        expectedScopeAuthority: SkyStreamServiceScopeAuthority? = nil
    ) async throws {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamPluginManagerError.unavailable
        }
        let scopeAuthority = expectedScopeAuthority
            ?? SkyStreamServiceScopeAuthority.capture()
        guard scopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        guard let prepared = try await prepareDynamicProviderRefresh(
            packageName: packageName,
            expectedScopeAuthority: scopeAuthority
        ) else {
            return
        }
        _ = try await withMutationGate {
            guard scopeAuthority.isCurrent else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
            return try await commitDynamicProviderRefreshUnlocked(prepared)
        }
    }

    private func prepareDynamicProviderRefresh(
        packageName: String,
        expectedScopeAuthority: SkyStreamServiceScopeAuthority
    ) async throws -> PreparedDynamicProviderRefresh? {
        try Task.checkCancellation()
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        guard let existing = plugin(packageName: packageName), existing.usesDynamicProviders == true else {
            return nil
        }
        try beginPackageRuntimeValidation(packageName: packageName)
        defer { endPackageRuntimeValidation(packageName: packageName) }
        let expectedConfiguration = DynamicProviderConfigurationFingerprint(existing)
        guard let authorityRevision = runtimeAuthorityRevisions[existing.id] else {
            throw SkyStreamPluginManagerError.managerNotLoaded
        }
        let scriptURL = try verifyScriptIntegrity(for: existing)
        var runtimeManifest = existing.manifest
        runtimeManifest.providers = []
        let committedRuntimeStore = SkyStreamRuntimeDataStore(snapshot: .init(
            storage: existing.runtimeStorage ?? [:],
            preferences: existing.preferences.mapValues(\.value)
        ))
        let configuration = SkyStreamRuntimeConfiguration(
            manifest: runtimeManifest,
            baseURL: existing.selectedDomainURL ?? existing.manifest.baseURL,
            scriptURL: scriptURL,
            expectedScriptSHA256: existing.scriptSHA256,
            authorityRevision: authorityRevision,
            dataStore: committedRuntimeStore
        )
        let discovered = try await SkyStreamRuntimePool.shared.getProvidersForCommittedRefresh(
            using: configuration
        )
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        let runtimeSnapshot = committedRuntimeStore.snapshot()
        let providers = try await validatedDynamicProviders(discovered)
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        guard !providers.isEmpty else {
            throw SkyStreamPluginManagerError.packageIncompatible(
                "This package did not return any usable dynamic providers."
            )
        }

        return PreparedDynamicProviderRefresh(
            packageName: packageName,
            expectedConfiguration: expectedConfiguration,
            providers: providers,
            runtimeSnapshot: runtimeSnapshot,
            scopeAuthority: expectedScopeAuthority
        )
    }

    private func commitDynamicProviderRefreshUnlocked(
        _ prepared: PreparedDynamicProviderRefresh
    ) async throws -> Bool {
        guard prepared.scopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        guard let index = installedPlugins.firstIndex(where: { $0.id == prepared.packageName }),
              installedPlugins[index].usesDynamicProviders == true,
              DynamicProviderConfigurationFingerprint(installedPlugins[index])
                == prepared.expectedConfiguration else {
            return false
        }
        let oldPlugins = installedPlugins
        var manifest = installedPlugins[index].manifest
        manifest.providers = prepared.providers
        let reconciled = Self.reconciledProviderStates(
            manifest: manifest,
            previous: installedPlugins[index].providers
        )
        installedPlugins[index].manifest = manifest
        installedPlugins[index].providers = reconciled.states
        let previousPreferences = installedPlugins[index].preferences
        installedPlugins[index].runtimeStorage = prepared.runtimeSnapshot.storage.isEmpty
            ? nil
            : prepared.runtimeSnapshot.storage
        installedPlugins[index].preferences = prepared.runtimeSnapshot.preferences.reduce(
            into: [String: SkyStreamPreferenceValue]()
        ) { result, entry in
            let previous = previousPreferences[entry.key]
            result[entry.key] = SkyStreamPreferenceValue(
                value: entry.value,
                isSecret: previous?.isSecret ?? true,
                isRedacted: false,
                updatedAt: previous?.value == entry.value ? previous?.updatedAt : Date()
            )
        }
        installedPlugins[index].updatedAt = Date()
        do {
            try await persist(
                runtimeResetPackageIDs: [prepared.packageName],
                expectedScopeGeneration: prepared.scopeAuthority.serviceStoreGeneration
            ) {
                await SkyStreamRuntimePool.shared.invalidatePackage(
                    prepared.packageName,
                    resetDataStore: true
                )
            }
        } catch {
            if prepared.scopeAuthority.isCurrent {
                installedPlugins = oldPlugins
            }
            throw error
        }
        return true
    }

    public func install(
        packageName: String,
        from repository: SkyStreamSavedRepository,
        replacementPolicy: SkyStreamReplacementPolicy = .normal
    ) async throws -> SkyStreamInstalledPluginState {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamPluginManagerError.unavailable
        }
        guard isLoaded else { throw notLoadedError }
        guard canAdministerPlugins else {
            throw SkyStreamPluginManagerError.requiresGrownUpProfile
        }
        let scopeAuthority = SkyStreamServiceScopeAuthority.capture()
        return try await performRepositoryInstall(
            packageName: packageName,
            from: repository,
            replacementPolicy: replacementPolicy,
            installedBaseline: installedPlugins,
            expectedScopeAuthority: scopeAuthority
        )
    }

    private func performRepositoryInstall(
        packageName: String,
        from repository: SkyStreamSavedRepository,
        replacementPolicy: SkyStreamReplacementPolicy,
        installedBaseline: [SkyStreamInstalledPluginState],
        expectedScopeAuthority: SkyStreamServiceScopeAuthority
    ) async throws -> SkyStreamInstalledPluginState {
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        guard let currentRepository = repositories.first(where: {
            $0.sourceURL == repository.sourceURL
        }), currentRepository == repository,
              let entry = currentRepository.plugins.first(where: {
                  $0.manifest.packageName == packageName
              }) else {
            throw SkyStreamPluginManagerError.pluginEntryNotFound
        }
        let authority = RepositoryInstallAuthority(
            repository: currentRepository,
            entry: entry
        )
        let baseURL = URL(
            string: currentRepository.pluginListURLs.first ?? currentRepository.sourceURL
        ) ?? URL(string: currentRepository.sourceURL)!
        let downloaded = try await repositoryManager.downloadArchive(
            from: entry,
            relativeTo: baseURL,
            packageName: packageName
        )
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        let provenance = SkyStreamInstallProvenance(
            kind: .repository,
            sourceURL: downloaded.finalURL.absoluteString,
            repositoryURL: currentRepository.sourceURL,
            pluginListURL: currentRepository.pluginListURLs.first,
            repositoryPackageName: currentRepository.repositoryPackageName,
            expectedArchiveSHA256: entry.expectedArchiveSHA256
        )
        let prepared = try await prepareInstallArchive(
            downloaded.data,
            expectedEntry: entry,
            provenance: provenance,
            replacementPolicy: replacementPolicy,
            installedBaseline: installedBaseline,
            repositoryAuthority: authority,
            expectedScopeAuthority: expectedScopeAuthority
        )
        return try await commitPreparedInstall(prepared)
    }

    public func installDirectArchive(
        _ data: Data,
        sourceURL: URL,
        replacementPolicy: SkyStreamReplacementPolicy = .normal
    ) async throws -> SkyStreamInstalledPluginState {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamPluginManagerError.unavailable
        }
        guard isLoaded else { throw notLoadedError }
        guard canAdministerPlugins else {
            throw SkyStreamPluginManagerError.requiresGrownUpProfile
        }
        let scopeAuthority = SkyStreamServiceScopeAuthority.capture()
        let installedBaseline = installedPlugins
        let pinnedURL = try SkyStreamRemoteURLPolicy.shared.validateSyntactic(
            sourceURL.absoluteString,
            purpose: .package
        ).url
        let provenance = SkyStreamInstallProvenance(
            kind: .directArchive,
            sourceURL: pinnedURL.absoluteString
        )
        let prepared = try await prepareInstallArchive(
            data,
            expectedEntry: nil,
            provenance: provenance,
            replacementPolicy: replacementPolicy,
            installedBaseline: installedBaseline,
            repositoryAuthority: nil,
            expectedScopeAuthority: scopeAuthority
        )
        return try await commitPreparedInstall(prepared)
    }

    public func updateIfAvailable(packageName: String) async throws {
        guard canAdministerPlugins else {
            throw SkyStreamPluginManagerError.requiresGrownUpProfile
        }
        let scopeAuthority = SkyStreamServiceScopeAuthority.capture()
        try await updateIfAvailable(
            packageName: packageName,
            expectedScopeAuthority: scopeAuthority
        )
    }

    private func updateIfAvailable(
        packageName: String,
        expectedScopeAuthority: SkyStreamServiceScopeAuthority
    ) async throws {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamPluginManagerError.unavailable
        }
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        guard isLoaded else { throw notLoadedError }
        let installedBaseline = installedPlugins
        guard let installed = plugin(packageName: packageName) else {
            throw SkyStreamPluginManagerError.packageNotFound
        }
        switch installed.provenance.kind {
        case .repository:
            guard let repositoryURL = installed.provenance.repositoryURL,
                  let repository = repositories.first(where: { $0.sourceURL == repositoryURL }),
                  let entry = repository.plugins.first(where: { $0.manifest.packageName == packageName }) else {
                throw SkyStreamPluginManagerError.pluginEntryNotFound
            }
            guard entry.manifest.version > installed.manifest.version else { return }
            _ = try await performRepositoryInstall(
                packageName: packageName,
                from: repository,
                replacementPolicy: .normal,
                installedBaseline: installedBaseline,
                expectedScopeAuthority: expectedScopeAuthority
            )

        case .directArchive:

            let pinned = try SkyStreamRemoteURLPolicy.shared.validateSyntactic(
                installed.provenance.sourceURL,
                purpose: .package
            ).url
            let resolution = try await repositoryManager.resolveUserInput(pinned.absoluteString)
            guard expectedScopeAuthority.isCurrent else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
            guard case .archive(let data, _) = resolution else {
                throw SkyStreamRepositoryError.unsupportedInput
            }
            let provenance = SkyStreamInstallProvenance(
                kind: .directArchive,
                sourceURL: pinned.absoluteString
            )
            let prepared = try await prepareInstallArchive(
                data,
                expectedEntry: nil,
                provenance: provenance,
                replacementPolicy: .normal,
                installedBaseline: installedBaseline,
                repositoryAuthority: nil,
                expectedScopeAuthority: expectedScopeAuthority,
                requiredPackageName: installed.id
            )
            _ = try await commitPreparedInstall(prepared)

        case .backup:

            return
        }
    }

    public func setProviderEnabled(
        sourceID: String,
        enabled: Bool,
        expectedScopeGeneration: Int? = nil
    ) async throws {
        guard canAdministerPlugins else {
            throw SkyStreamPluginManagerError.requiresGrownUpProfile
        }
        guard expectedScopeGeneration.map(ServiceStoreScope.isCurrent) ?? true else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        try await withMutationGate {
            guard expectedScopeGeneration.map(ServiceStoreScope.isCurrent) ?? true else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
            try await setProviderEnabledUnlocked(
                sourceID: sourceID,
                enabled: enabled,
                expectedScopeGeneration: expectedScopeGeneration
            )
        }
    }

    private func setProviderEnabledUnlocked(
        sourceID: String,
        enabled: Bool,
        expectedScopeGeneration: Int?
    ) async throws {
        guard let pluginIndex = installedPlugins.firstIndex(where: { plugin in
            plugin.providers.contains { $0.id == sourceID && $0.removedAt == nil }
        }), let stateIndex = installedPlugins[pluginIndex].providers.firstIndex(where: { $0.id == sourceID }) else {
            throw SkyStreamPluginManagerError.packageNotFound
        }
        let previous = installedPlugins
        installedPlugins[pluginIndex].providers[stateIndex].isEnabled = enabled
        installedPlugins[pluginIndex].updatedAt = Date()
        do {
            try await persist(expectedScopeGeneration: expectedScopeGeneration)
            SkyStreamResolver.shared.invalidateCachesForPackage(previous[pluginIndex].id)
        } catch {
            if expectedScopeGeneration.map(ServiceStoreScope.isCurrent) ?? true {
                installedPlugins = previous
            }
            throw error
        }
    }

    public func setSelectedDomain(packageName: String, domainURL: String) async throws {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamPluginManagerError.unavailable
        }
        guard canAdministerPlugins else {
            throw SkyStreamPluginManagerError.requiresGrownUpProfile
        }
        guard let beforeValidation = plugin(packageName: packageName) else {
            throw SkyStreamPluginManagerError.packageNotFound
        }
        let expectedConfiguration = DynamicProviderConfigurationFingerprint(beforeValidation)
        let allowed = Set((beforeValidation.manifest.domains ?? []).map(\.url))
        guard allowed.contains(domainURL) else {
            throw SkyStreamPluginManagerError.catalogManifestMismatch
        }

        _ = try await SkyStreamRemoteURLPolicy.shared.validate(domainURL, purpose: .pluginRequest)
        let shouldRefreshDynamicProviders = try await withMutationGate {
            try await setSelectedDomainUnlocked(
                packageName: packageName,
                domainURL: domainURL,
                expectedConfiguration: expectedConfiguration
            )
        }
        if shouldRefreshDynamicProviders {
            do {
                try await refreshDynamicProviders(packageName: packageName)
            } catch {

                log("dynamic providers retained after mirror refresh failure", packageName: packageName, error: error)
            }
        }
    }

    private func setSelectedDomainUnlocked(
        packageName: String,
        domainURL: String,
        expectedConfiguration: DynamicProviderConfigurationFingerprint
    ) async throws -> Bool {

        guard let index = installedPlugins.firstIndex(where: { $0.id == packageName }) else {
            throw SkyStreamPluginManagerError.packageNotFound
        }
        guard DynamicProviderConfigurationFingerprint(installedPlugins[index]) == expectedConfiguration,
              installedPlugins[index].manifest.domains?.contains(where: { $0.url == domainURL }) == true else {
            throw SkyStreamPluginManagerError.catalogManifestMismatch
        }
        let previous = installedPlugins
        installedPlugins[index].selectedDomainURL = domainURL
        installedPlugins[index].updatedAt = Date()
        do {
            try await persist(runtimeResetPackageIDs: [packageName]) {
                await SkyStreamRuntimePool.shared.invalidatePackage(
                    packageName,
                    resetCookies: true,
                    resetDataStore: true
                )
            }
        } catch {
            installedPlugins = previous
            throw error
        }
        return previous[index].usesDynamicProviders == true
    }

    public func resetPreferences(packageName: String) async throws {
        guard canAdministerPlugins else {
            throw SkyStreamPluginManagerError.requiresGrownUpProfile
        }
        let shouldRefreshDynamicProviders = try await withMutationGate {
            try await resetPreferencesUnlocked(packageName: packageName)
        }
        if shouldRefreshDynamicProviders {
            do {
                try await refreshDynamicProviders(packageName: packageName)
            } catch {

                log("dynamic providers retained after preference reset failure", packageName: packageName, error: error)
            }
        }
    }

    private func resetPreferencesUnlocked(packageName: String) async throws -> Bool {
        guard let index = installedPlugins.firstIndex(where: { $0.manifest.packageName == packageName }) else {
            throw SkyStreamPluginManagerError.packageNotFound
        }
        let previous = installedPlugins
        installedPlugins[index].preferences = [:]
        installedPlugins[index].runtimeStorage = nil
        installedPlugins[index].updatedAt = Date()
        do {
            try await persist(runtimeResetPackageIDs: [packageName]) {
                await SkyStreamRuntimePool.shared.invalidatePackage(
                    packageName,
                    resetCookies: true,
                    resetDataStore: true
                )
                await SkyStreamRuntimePool.shared.clearInstalledQuarantineForUserReset(
                    packageName: packageName
                )
            }
        } catch {
            installedPlugins = previous
            throw error
        }
        return previous[index].usesDynamicProviders == true
    }

    func persistRuntimeSnapshot(
        packageName: String,
        expectedScriptSHA256: String,
        snapshot: SkyStreamRuntimeStorageSnapshot
    ) async throws {

        guard let expectedPlugin = plugin(packageName: packageName),
              expectedPlugin.scriptSHA256.caseInsensitiveCompare(expectedScriptSHA256) == .orderedSame else {
            return
        }
        try await withMutationGate {
            try await persistRuntimeSnapshotUnlocked(
                packageName: packageName,
                expectedScriptSHA256: expectedScriptSHA256,
                snapshot: snapshot,
                expectedPlugin: expectedPlugin
            )
        }
    }

    private func persistRuntimeSnapshotUnlocked(
        packageName: String,
        expectedScriptSHA256: String,
        snapshot: SkyStreamRuntimeStorageSnapshot,
        expectedPlugin: SkyStreamInstalledPluginState? = nil
    ) async throws {
        guard let index = installedPlugins.firstIndex(where: { $0.id == packageName }) else { return }
        guard installedPlugins[index].scriptSHA256.caseInsensitiveCompare(expectedScriptSHA256) == .orderedSame else {
            return
        }
        if let expectedPlugin, installedPlugins[index] != expectedPlugin { return }

        let oldPlugin = installedPlugins[index]
        var preferences: [String: SkyStreamPreferenceValue] = [:]
        for (key, value) in snapshot.preferences {
            let previous = oldPlugin.preferences[key]
            preferences[key] = SkyStreamPreferenceValue(
                value: value,
                isSecret: previous?.isSecret ?? true,
                isRedacted: false,
                updatedAt: previous?.value == value ? previous?.updatedAt : Date()
            )
        }
        let storage = snapshot.storage.isEmpty ? nil : snapshot.storage
        guard oldPlugin.runtimeStorage != storage || oldPlugin.preferences != preferences else { return }

        installedPlugins[index].runtimeStorage = storage
        installedPlugins[index].preferences = preferences
        installedPlugins[index].updatedAt = Date()
        do {
            try await persist()
            SkyStreamResolver.shared.invalidateCachesForPackage(packageName)
        } catch {
            installedPlugins[index] = oldPlugin
            throw error
        }
    }

    public func uninstall(packageName: String) async throws {
        guard canAdministerPlugins else {
            throw SkyStreamPluginManagerError.requiresGrownUpProfile
        }
        try await withMutationGate {
            try await uninstallUnlocked(packageName: packageName)
        }
    }

    private func uninstallUnlocked(packageName: String) async throws {
        guard let index = installedPlugins.firstIndex(where: { $0.manifest.packageName == packageName }) else {
            throw SkyStreamPluginManagerError.packageNotFound
        }
        let removed = installedPlugins[index]
        let previous = installedPlugins
        installedPlugins.remove(at: index)
        do {
            try await persist(runtimeResetPackageIDs: [packageName]) {
                await SkyStreamRuntimePool.shared.invalidatePackage(
                    packageName,
                    resetCookies: true,
                    resetDataStore: true
                )
            }
        } catch {
            installedPlugins = previous
            throw error
        }

        if canDeleteSharedPluginPayloads {
            try? removeManagedItem(relativePath: removed.payloadRelativePath)
            try? removeManagedItem(url: archiveURL(for: removed))
        } else {
            log(
                "plugin payload retained: services are not shared and another profile may still reference it",
                packageName: packageName
            )
        }

        let rootID = SkyStreamStableID.rootProvider(packageName: packageName)
        SourceHealthStore.shared.removeRecords { sourceID in
            sourceID == rootID || sourceID.hasPrefix(rootID + "::")
        }
        log("plugin uninstalled", packageName: packageName)
    }

    private var canAdministerPlugins: Bool {
        ServicePluginAdministrativeAdmissionPolicy.permits(
            isKidsProfile: ProfileManager.shared.activeProfile?.isKidsProfile == true
        )
    }

    private var canDeleteSharedPluginPayloads: Bool {
        ProfileSettingsStore.sharesServices || ProfileManager.shared.profiles.count == 1
    }

    public func verifyScriptIntegrity(for plugin: SkyStreamInstalledPluginState) throws -> URL {
        let scriptURL = try runtimeScriptURL(for: plugin)
        let values = try? scriptURL.resourceValues(forKeys: [.fileSizeKey])
        guard fileManager.isReadableFile(atPath: scriptURL.path),
              (values?.fileSize ?? 10 * 1_024 * 1_024 + 1) <= 10 * 1_024 * 1_024,
              let data = try? Data(contentsOf: scriptURL, options: [.mappedIfSafe]),
              data.count <= 10 * 1_024 * 1_024,
              Self.sha256Hex(data) == plugin.scriptSHA256.lowercased() else {
            throw SkyStreamPluginManagerError.integrityFailure
        }
        return scriptURL
    }

    public func runtimeScriptURL(for plugin: SkyStreamInstalledPluginState) throws -> URL {
        let payloadURL = try managedURL(relativePath: plugin.payloadRelativePath)
        let scriptURL = payloadURL.appendingPathComponent("plugin.js", isDirectory: false)
        let values = try? scriptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard isDescendant(scriptURL, of: packageRoot),
              values?.isRegularFile == true,
              values?.isSymbolicLink != true else {
            throw SkyStreamPluginManagerError.integrityFailure
        }
        return scriptURL
    }

    func manualBackupCapturePlan() throws -> SkyStreamManualBackupCapturePlan {
        let repositorySnapshots = committedRepositories.compactMap(Self.backupRepository)
        guard repositorySnapshots.count == committedRepositories.count else {

            throw SkyStreamPluginManagerError.invalidBackup
        }
        let liveSourceDefaults = sourceDefaultsSnapshot()
        return SkyStreamManualBackupCapturePlan(
            repositories: repositorySnapshots,
            plugins: committedInstalledPlugins.map {
                let overlaid = Self.pluginByOverlayingSourceDefaults(
                    $0,
                    snapshot: liveSourceDefaults
                )
                return SkyStreamManualBackupCapturePlan.Plugin(
                    state: overlaid,
                    archiveURL: archiveURL(for: $0)
                )
            }
        )
    }

    nonisolated static func materializeManualBackupSnapshot(
        _ plan: SkyStreamManualBackupCapturePlan
    ) throws -> SkyStreamBackupSnapshot {
        var aggregateArchiveBytes = 0
        var plugins: [SkyStreamPluginBackupSnapshot] = []
        plugins.reserveCapacity(plan.plugins.count)
        for captured in plan.plugins {
            let plugin = captured.state
            let values = try? captured.archiveURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true,
                  (values?.fileSize ?? Self.maximumPackageArchiveBytes + 1)
                    <= Self.maximumPackageArchiveBytes,
                  let archive = try? Data(contentsOf: captured.archiveURL, options: [.mappedIfSafe]),
                  archive.count <= Self.maximumPackageArchiveBytes,
                  Self.sha256Hex(archive).caseInsensitiveCompare(plugin.archiveSHA256) == .orderedSame else {

                throw SkyStreamPluginManagerError.integrityFailure
            }
            let (nextAggregateBytes, overflow) = aggregateArchiveBytes.addingReportingOverflow(archive.count)
            guard !overflow, nextAggregateBytes <= Self.maximumManualBackupArchiveBytes else {
                throw SkyStreamPluginManagerError.backupArchiveBudgetExceeded(
                    maximumBytes: Self.maximumManualBackupArchiveBytes
                )
            }
            aggregateArchiveBytes = nextAggregateBytes
            plugins.append(SkyStreamPluginBackupSnapshot(
                state: plugin,
                archivePayload: archive,
                payloadWasRedacted: false,
                preferencesWereRedacted: false
            ))
        }
        return SkyStreamBackupSnapshot(
            repositories: plan.repositories,
            plugins: plugins,
            isSafeCloudSnapshot: false
        )
    }

    public func manualBackupSnapshot() throws -> SkyStreamBackupSnapshot {
        try Self.materializeManualBackupSnapshot(manualBackupCapturePlan())
    }

    public func safeCloudBackupSnapshot() -> SkyStreamBackupSnapshot {
        safeCloudBackupSnapshot(includingArchives: true)
    }

    public func safeCloudMetadataSnapshot() -> SkyStreamBackupSnapshot {
        safeCloudBackupSnapshot(includingArchives: false)
    }

    public func completePrivateCloudMetadataSnapshot() -> SkyStreamBackupSnapshot? {
        completePrivateCloudSnapshot(includingArchives: false)
    }

    public func completePrivateCloudBackupSnapshot() -> SkyStreamBackupSnapshot? {
        completePrivateCloudSnapshot(includingArchives: true)
    }

    static func completePrivateCloudMetadataSnapshot(
        fromPersistedStateData data: Data
    ) -> SkyStreamBackupSnapshot? {
        guard data.count <= Self.maximumPersistedStateBytes,
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.schemaVersion == 1,
              state.repositories.count <= Self.maximumRepositoryCount,
              state.installedPlugins.count <= Self.maximumInstalledPluginCount,
              Set(state.repositories.map(\.sourceURL)).count == state.repositories.count,
              Set(state.installedPlugins.map(\.id)).count == state.installedPlugins.count else {
            return nil
        }
        var repositories: [SkyStreamRepositoryBackupSnapshot] = []
        repositories.reserveCapacity(state.repositories.count)
        for repository in state.repositories {
            guard let captured = Self.backupRepository(repository),
                  Self.privateCloudRepositoryConfigurationIsCapturable(captured) else { return nil }
            repositories.append(captured)
        }
        var plugins: [SkyStreamPluginBackupSnapshot] = []
        plugins.reserveCapacity(state.installedPlugins.count)
        for plugin in state.installedPlugins {
            guard Self.privateCloudPluginConfigurationIsCapturable(plugin) else { return nil }
            var captured = plugin
            captured.runtimeStorage = nil
            plugins.append(SkyStreamPluginBackupSnapshot(
                state: captured,
                archivePayload: nil,
                payloadWasRedacted: true,
                preferencesWereRedacted: false
            ))
        }
        return SkyStreamBackupSnapshot(
            repositories: repositories,
            plugins: plugins,
            isSafeCloudSnapshot: true,
            privateCloudConfigurationIsComplete: true
        )
    }

    static func safeCloudMetadataSnapshot(
        fromPersistedStateData data: Data
    ) -> SkyStreamBackupSnapshot? {
        guard data.count <= Self.maximumPersistedStateBytes,
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.schemaVersion == 1,
              state.repositories.count <= Self.maximumRepositoryCount,
              state.installedPlugins.count <= Self.maximumInstalledPluginCount,
              Set(state.repositories.map(\.sourceURL)).count == state.repositories.count else {
            return nil
        }
        let repositories = state.repositories.compactMap(Self.backupRepository)
        let plugins = state.installedPlugins.compactMap { plugin -> SkyStreamPluginBackupSnapshot? in
            guard Self.isCloudSafeHTTPSURL(plugin.provenance.sourceURL),
                  plugin.provenance.repositoryURL.map(Self.isCloudSafeHTTPSURL) ?? true,
                  plugin.provenance.pluginListURL.map(Self.isCloudSafeHTTPSURL) ?? true else {
                return nil
            }
            var redacted = plugin
            redacted.runtimeStorage = nil
            redacted.preferences = redacted.preferences.filter { key, value in
                !value.isSecret && !value.isRedacted && !Self.containsCloudUnsafeSecretMarker(key)
            }
            return SkyStreamPluginBackupSnapshot(
                state: redacted,
                archivePayload: nil,
                payloadWasRedacted: true,
                preferencesWereRedacted: true
            )
        }
        return SkyStreamBackupSnapshot(
            repositories: repositories,
            plugins: plugins,
            isSafeCloudSnapshot: true
        )
    }

    private func safeCloudBackupSnapshot(includingArchives: Bool) -> SkyStreamBackupSnapshot {
        let repositorySnapshots = committedRepositories.compactMap(Self.backupRepository)
        let liveSourceDefaults = sourceDefaultsSnapshot()
        var aggregateArchiveBytes = 0
        let plugins = committedInstalledPlugins.compactMap { committedPlugin -> SkyStreamPluginBackupSnapshot? in
            let plugin = Self.pluginByOverlayingSourceDefaults(
                committedPlugin,
                snapshot: liveSourceDefaults
            )
            guard Self.isCloudSafeHTTPSURL(plugin.provenance.sourceURL),
                  plugin.provenance.repositoryURL.map(Self.isCloudSafeHTTPSURL) ?? true,
                  plugin.provenance.pluginListURL.map(Self.isCloudSafeHTTPSURL) ?? true else {
                return nil
            }
            var redacted = plugin
            redacted.runtimeStorage = nil
            redacted.preferences = redacted.preferences.filter { !$0.value.isSecret && !$0.value.isRedacted }
            let archive: Data?
            if !includingArchives {
                archive = nil
            } else {
                let archiveURL = archiveURL(for: plugin)
                let candidateArchive = try? Data(contentsOf: archiveURL, options: [.mappedIfSafe])
                if let candidateArchive,
                   candidateArchive.count <= Self.maximumPackageArchiveBytes,
                   Self.sha256Hex(candidateArchive).caseInsensitiveCompare(plugin.archiveSHA256)
                    == .orderedSame {
                    let (nextAggregateBytes, overflow) = aggregateArchiveBytes.addingReportingOverflow(
                        candidateArchive.count
                    )
                    if !overflow, nextAggregateBytes <= Self.maximumManualBackupArchiveBytes {
                        aggregateArchiveBytes = nextAggregateBytes
                        archive = candidateArchive
                    } else {
                        archive = nil
                        log("safe cloud backup redacted archive budget", packageName: plugin.id)
                    }
                } else {
                    archive = nil
                    log("safe cloud backup redacted unavailable archive", packageName: plugin.id)
                }
            }
            return SkyStreamPluginBackupSnapshot(
                state: redacted,
                archivePayload: archive,
                payloadWasRedacted: archive == nil,

                preferencesWereRedacted: true
            )
        }
        return SkyStreamBackupSnapshot(
            repositories: repositorySnapshots,
            plugins: plugins,
            isSafeCloudSnapshot: true
        )
    }

    private func completePrivateCloudSnapshot(
        includingArchives: Bool
    ) -> SkyStreamBackupSnapshot? {
        var repositorySnapshots: [SkyStreamRepositoryBackupSnapshot] = []
        repositorySnapshots.reserveCapacity(committedRepositories.count)
        for repository in committedRepositories {
            guard let captured = Self.backupRepository(repository),
                  Self.privateCloudRepositoryConfigurationIsCapturable(captured) else { return nil }
            repositorySnapshots.append(captured)
        }
        let liveSourceDefaults = sourceDefaultsSnapshot()
        var aggregateArchiveBytes = 0
        var plugins: [SkyStreamPluginBackupSnapshot] = []
        plugins.reserveCapacity(committedInstalledPlugins.count)
        for committedPlugin in committedInstalledPlugins {
            let plugin = Self.pluginByOverlayingSourceDefaults(
                committedPlugin,
                snapshot: liveSourceDefaults
            )
            guard Self.privateCloudPluginConfigurationIsCapturable(plugin) else { return nil }
            var captured = plugin
            captured.runtimeStorage = nil
            let archive: Data?
            if includingArchives {
                let archiveURL = archiveURL(for: plugin)
                let candidate = try? Data(contentsOf: archiveURL, options: [.mappedIfSafe])
                if let candidate,
                   candidate.count <= Self.maximumPackageArchiveBytes,
                   Self.sha256Hex(candidate).caseInsensitiveCompare(plugin.archiveSHA256)
                    == .orderedSame {
                    let (nextBytes, overflow) = aggregateArchiveBytes.addingReportingOverflow(
                        candidate.count
                    )
                    if !overflow, nextBytes <= Self.maximumManualBackupArchiveBytes {
                        aggregateArchiveBytes = nextBytes
                        archive = candidate
                    } else {
                        archive = nil
                    }
                } else {
                    archive = nil
                }
            } else {
                archive = nil
            }
            plugins.append(SkyStreamPluginBackupSnapshot(
                state: captured,
                archivePayload: archive,
                payloadWasRedacted: archive == nil,
                preferencesWereRedacted: false
            ))
        }
        return SkyStreamBackupSnapshot(
            repositories: repositorySnapshots,
            plugins: plugins,
            isSafeCloudSnapshot: true,
            privateCloudConfigurationIsComplete: true
        )
    }

    public func restoreManualBackupSnapshot(_ snapshot: SkyStreamBackupSnapshot) async throws {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamPluginManagerError.unavailable
        }
        guard isLoaded else { throw notLoadedError }
        let prepared = try await prepareAuthoritativeManualSnapshot(snapshot)
        defer { try? removeManagedItem(url: prepared.transactionRootURL) }
        _ = try await withMutationGate {
            try await commitAuthoritativeManualSnapshotUnlocked(prepared)
        }

        for packageName in prepared.preparedPackages
            .filter(\.usesDynamicProviders)
            .map({ $0.backup.id }) {
            do {
                try await refreshDynamicProviders(
                    packageName: packageName
                )
            } catch {
                log(
                    "manual restore retained validated dynamic provider catalog",
                    packageName: packageName,
                    error: error
                )
            }
        }
        log("manual backup restored", packageName: "\(prepared.preparedPackages.count)-packages")
    }

    public func restoreSafeCloudSnapshot(
        _ snapshot: SkyStreamBackupSnapshot
    ) async throws -> SkyStreamSafeCloudRestoreResult {
        try await restoreSafeCloudSnapshot(
            snapshot,
            expectedScopeAuthority: SkyStreamServiceScopeAuthority.capture()
        )
    }

    func restoreSafeCloudSnapshot(
        _ snapshot: SkyStreamBackupSnapshot,
        expectedScopeAuthority: SkyStreamServiceScopeAuthority
    ) async throws -> SkyStreamSafeCloudRestoreResult {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamPluginManagerError.unavailable
        }
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        guard isLoaded else { throw notLoadedError }
        let token = beginSafeRestore()
        defer { endSafeRestore(token) }
        return try await SkyStreamSafeRestoreTaskContext.$token.withValue(token) {
            try await restoreSafeCloudSnapshot(
                snapshot,
                token: token,
                expectedScopeAuthority: expectedScopeAuthority
            )
        }
    }

    private func restoreSafeCloudSnapshot(
        _ snapshot: SkyStreamBackupSnapshot,
        token: UUID,
        expectedScopeAuthority: SkyStreamServiceScopeAuthority
    ) async throws -> SkyStreamSafeCloudRestoreResult {
        try requireSafeRestoreIsCurrent(token)
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        let configurationIsComplete = snapshot.privateCloudConfigurationIsComplete == true
        guard snapshot.isSafeCloudSnapshot,
              snapshot.schemaVersion == 1,
              snapshot.additionalFields.isEmpty,
              snapshot.repositories.count <= Self.maximumRepositoryCount,
              snapshot.plugins.count <= Self.maximumInstalledPluginCount,
              Set(snapshot.repositories.map(\.sourceURL)).count == snapshot.repositories.count,
              Set(snapshot.plugins.map(\.id)).count == snapshot.plugins.count,
              configurationIsComplete || Set(repositories.map(\.sourceURL))
                .union(snapshot.repositories.map(\.sourceURL)).count <= Self.maximumRepositoryCount,
              configurationIsComplete || Set(installedPlugins.map(\.id))
                .union(snapshot.plugins.map(\.id)).count <= Self.maximumInstalledPluginCount else {
            throw SkyStreamPluginManagerError.invalidBackup
        }
        let initialInstalledStates = installedPlugins.reduce(
            into: [String: SkyStreamInstalledPluginState]()
        ) { result, plugin in
            if result[plugin.id] == nil {
                result[plugin.id] = plugin
            }
        }
        let configurationBaseline = initialInstalledStates.mapValues(
            SafeCloudConfigurationFingerprint.init
        )
        let initialSourceDefaults = sourceDefaultsSnapshot()
        let initialRepositoryStates = repositories.reduce(
            into: [String: SkyStreamSavedRepository]()
        ) { result, repository in
            if result[repository.sourceURL] == nil {
                result[repository.sourceURL] = repository
            }
        }

        let restoredCloudRepositories = try preflightSafeCloudSnapshot(snapshot)
        try requireSafeRestoreIsCurrent(token)
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        let snapshotPackageIDs = Set(snapshot.plugins.map(\.id))
        let initialPlugins = initialInstalledStates.values.filter {
            snapshotPackageIDs.contains($0.id)
        }
        let integritySkyStreamRoot = skyStreamRoot
        let integrityPackageRoot = packageRoot
        let initialIntegrityTask = Task.detached(priority: .utility) {
            var valid = Set<PackageCodeFingerprint>()
            for plugin in initialPlugins {
                if Task.isCancelled { break }
                if Self.persistedScriptIntegrityIsValid(
                    plugin,
                    skyStreamRoot: integritySkyStreamRoot,
                    packageRoot: integrityPackageRoot
                ) {
                    valid.insert(PackageCodeFingerprint(plugin))
                }
            }
            return valid
        }
        let reconstructedArchives = await prefetchSafeCloudReconstructionArchives(snapshot)
        let validInitialCodeFingerprints = await withTaskCancellationHandler {
            await initialIntegrityTask.value
        } onCancel: {
            initialIntegrityTask.cancel()
        }
        try Task.checkCancellation()
        try requireSafeRestoreIsCurrent(token)
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }

        var acceptedInstalledStates: [String: SkyStreamInstalledPluginState] = [:]
        for snapshotPlugin in snapshot.plugins where !snapshotPlugin.payloadWasRedacted {
            try Task.checkCancellation()
            try requireSafeRestoreIsCurrent(token)
            guard expectedScopeAuthority.isCurrent else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
            let installedBaseline = installedPlugins
            let existing = installedBaseline.first { $0.id == snapshotPlugin.id }
            if let initial = initialInstalledStates[snapshotPlugin.id] {
                guard existing == initial else {
                    log(
                        "safe cloud archive skipped local package changed or deleted",
                        packageName: snapshotPlugin.id
                    )
                    continue
                }
            } else if existing != nil {
                log(
                    "safe cloud archive skipped concurrent local install",
                    packageName: snapshotPlugin.id
                )
                continue
            }
            if !Self.safeCloudArchiveMayInstall(
                incoming: snapshotPlugin.state,
                over: existing
            ) {
                log(
                    "safe cloud archive skipped existing fingerprint mismatch",
                    packageName: snapshotPlugin.id
                )
                continue
            }
            guard let archive = snapshotPlugin.archivePayload,
                  archive.count <= Self.maximumPackageArchiveBytes,
                  Self.sha256Hex(archive).caseInsensitiveCompare(
                      snapshotPlugin.state.archiveSHA256
                  ) == .orderedSame,
                  Self.isSafeHTTPSURL(snapshotPlugin.state.provenance.sourceURL),
                  let sourceURL = URL(string: snapshotPlugin.state.provenance.sourceURL) else {
                log("safe cloud restore skipped invalid archive", packageName: snapshotPlugin.id)
                continue
            }
            do {
                let expectedEntry = SkyStreamPluginListEntry(
                    manifest: snapshotPlugin.state.manifest,
                    url: sourceURL.absoluteString,
                    archiveSHA256: snapshotPlugin.state.archiveSHA256,
                    scriptSHA256: snapshotPlugin.state.scriptSHA256
                )
                let prepared = try await prepareInstallArchive(
                    archive,
                    expectedEntry: expectedEntry,
                    provenance: snapshotPlugin.state.provenance,
                    replacementPolicy: .normal,
                    installedBaseline: installedBaseline,
                    repositoryAuthority: nil,
                    expectedScopeAuthority: expectedScopeAuthority
                )
                let installed = try await commitPreparedInstall(
                    prepared,
                    safeRestoreToken: token
                )
                acceptedInstalledStates[installed.id] = installed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard expectedScopeAuthority.isCurrent else {
                    throw SkyStreamPluginManagerError.stateChangedDuringValidation
                }
                log("safe cloud archive restore skipped", packageName: snapshotPlugin.id, error: error)
            }
        }

        for snapshotPlugin in snapshot.plugins where snapshotPlugin.payloadWasRedacted {
            try Task.checkCancellation()
            try requireSafeRestoreIsCurrent(token)
            guard expectedScopeAuthority.isCurrent else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
            let installedBaseline = installedPlugins
            let existing = installedBaseline.first { $0.id == snapshotPlugin.id }
            if let initial = initialInstalledStates[snapshotPlugin.id] {
                guard existing == initial else {
                    log(
                        "safe cloud reconstruction skipped local package changed or deleted",
                        packageName: snapshotPlugin.id
                    )
                    continue
                }

                continue
            } else if existing != nil {
                log(
                    "safe cloud reconstruction skipped concurrent local install",
                    packageName: snapshotPlugin.id
                )
                continue
            }
            guard
                  Self.isSafeHTTPSURL(snapshotPlugin.state.provenance.sourceURL),
                  let pinnedURL = URL(string: snapshotPlugin.state.provenance.sourceURL),
                  let archive = reconstructedArchives[snapshotPlugin.id],
                  archive.count <= Self.maximumPackageArchiveBytes,
                  Self.sha256Hex(archive).caseInsensitiveCompare(
                      snapshotPlugin.state.archiveSHA256
                  ) == .orderedSame else {
                continue
            }
            do {
                let expectedEntry = SkyStreamPluginListEntry(
                    manifest: snapshotPlugin.state.manifest,
                    url: pinnedURL.absoluteString,
                    archiveSHA256: snapshotPlugin.state.archiveSHA256,
                    scriptSHA256: snapshotPlugin.state.scriptSHA256
                )
                let prepared = try await prepareInstallArchive(
                    archive,
                    expectedEntry: expectedEntry,
                    provenance: snapshotPlugin.state.provenance,
                    replacementPolicy: .normal,
                    installedBaseline: installedBaseline,
                    repositoryAuthority: nil,
                    expectedScopeAuthority: expectedScopeAuthority
                )
                let installed = try await commitPreparedInstall(
                    prepared,
                    safeRestoreToken: token
                )
                acceptedInstalledStates[installed.id] = installed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard expectedScopeAuthority.isCurrent else {
                    throw SkyStreamPluginManagerError.stateChangedDuringValidation
                }
                log(
                    "safe cloud reconstruction skipped",
                    packageName: snapshotPlugin.id,
                    error: error
                )
            }
        }

        let metadataCommit = try await withMutationGate {
            try requireSafeRestoreIsCurrent(token)
            guard expectedScopeAuthority.isCurrent else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
            return try await mergeSafeCloudSnapshotUnlocked(
                snapshot,
                safeRestoreToken: token,
                restoredCloudRepositories: restoredCloudRepositories,
                initialRepositoryStates: initialRepositoryStates,
                configurationBaseline: configurationBaseline,
                initialSourceDefaults: initialSourceDefaults,
                acceptedInstalledStates: acceptedInstalledStates,
                validInitialCodeFingerprints: validInitialCodeFingerprints,
                expectedScopeAuthority: expectedScopeAuthority
            )
        }

        for packageName in metadataCommit.dynamicPackageIDs {
            do {
                try await refreshDynamicProviders(
                    packageName: packageName,
                    expectedScopeAuthority: expectedScopeAuthority
                )
            } catch {
                guard expectedScopeAuthority.isCurrent else {
                    throw SkyStreamPluginManagerError.stateChangedDuringValidation
                }
                log("safe cloud dynamic providers retained after refresh failure", packageName: packageName, error: error)
            }
        }
        return SkyStreamSafeCloudRestoreResult(
            unresolvedPackageIDs: snapshot.plugins.compactMap { snapshotPlugin in
                guard plugin(packageName: snapshotPlugin.id) == nil else { return nil }

                guard initialInstalledStates[snapshotPlugin.id] == nil,
                      acceptedInstalledStates[snapshotPlugin.id] == nil else { return nil }
                return snapshotPlugin.id
            }
        )
    }

    private func mergeSafeCloudSnapshotUnlocked(
        _ snapshot: SkyStreamBackupSnapshot,
        safeRestoreToken: UUID,
        restoredCloudRepositories: [SkyStreamSavedRepository],
        initialRepositoryStates: [String: SkyStreamSavedRepository],
        configurationBaseline: [String: SafeCloudConfigurationFingerprint],
        initialSourceDefaults: SkySourceDefaultsSnapshot,
        acceptedInstalledStates: [String: SkyStreamInstalledPluginState],
        validInitialCodeFingerprints: Set<PackageCodeFingerprint>,
        expectedScopeAuthority: SkyStreamServiceScopeAuthority
    ) async throws -> SafeCloudMetadataCommit {
        try requireSafeRestoreIsCurrent(safeRestoreToken)
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        let configurationIsComplete = snapshot.privateCloudConfigurationIsComplete == true
        guard snapshot.isSafeCloudSnapshot,
              snapshot.schemaVersion == 1,
              snapshot.repositories.count <= 64,
              snapshot.plugins.count <= 128,
              Set(snapshot.repositories.map(\.sourceURL)).count == snapshot.repositories.count,
              Set(snapshot.plugins.map(\.id)).count == snapshot.plugins.count,
              configurationIsComplete || Set(repositories.map(\.sourceURL))
                .union(snapshot.repositories.map(\.sourceURL)).count <= Self.maximumRepositoryCount,
              configurationIsComplete || Set(installedPlugins.map(\.id))
                .union(snapshot.plugins.map(\.id)).count <= Self.maximumInstalledPluginCount else {
            throw SkyStreamPluginManagerError.invalidBackup
        }
        let oldRepositories = repositories
        let oldPlugins = installedPlugins
        var metadataCommitted = false
        defer {
            if !metadataCommitted, expectedScopeAuthority.isCurrent {
                repositories = oldRepositories
                installedPlugins = oldPlugins
            }
        }
        var runtimeResetPackageIDs = Set<String>()
        var cookieResetPackageIDs = Set<String>()
        var cacheInvalidationPackageIDs = Set<String>()
        var changedPackageIDs = Set<String>()
        var transientSessionPreservingPackageIDs = Set<String>()
        var incomingSourceStates: [String: SkyStreamProviderState] = [:]
        guard restoredCloudRepositories.allSatisfy({ repository in
            Self.acceptsSafeCloudConfigurationURL(
                repository.sourceURL,
                configurationIsComplete: configurationIsComplete
            )
                && repository.pluginListURLs.allSatisfy {
                    Self.acceptsSafeCloudConfigurationURL(
                        $0,
                        configurationIsComplete: configurationIsComplete
                    )
                }
        }) else { throw SkyStreamPluginManagerError.invalidBackup }
        let currentRepositoryURLs = Set(repositories.map(\.sourceURL))
        let authorizedIncomingRepositories = restoredCloudRepositories.filter { repository in
            initialRepositoryStates[repository.sourceURL] == nil
                || currentRepositoryURLs.contains(repository.sourceURL)
        }
        repositories = configurationIsComplete
            ? Self.restoringCompletePrivateCloudRepositories(
                current: repositories,
                incoming: authorizedIncomingRepositories,
                baseline: initialRepositoryStates
            )
            : Self.mergingSafeCloudRepositories(
                current: repositories,
                incoming: authorizedIncomingRepositories
            )
        guard repositories.count <= Self.maximumRepositoryCount else {
            throw SkyStreamPluginManagerError.invalidBackup
        }

        for snapshotPlugin in snapshot.plugins {
            try Task.checkCancellation()
            guard let index = installedPlugins.firstIndex(where: { $0.id == snapshotPlugin.id }) else {
                continue
            }
            let current = installedPlugins[index]
            let acceptedBaseline = acceptedInstalledStates[snapshotPlugin.id].map(
                SafeCloudConfigurationFingerprint.init
            )
            let baseline = acceptedBaseline ?? configurationBaseline[snapshotPlugin.id]
            let matchesInitialConfiguration = baseline.map {
                DynamicProviderConfigurationFingerprint(current) == $0.dynamicConfiguration
            } ?? false

            let matchesAcceptedPublication = acceptedBaseline.map {
                DynamicProviderConfigurationFingerprint(current) == $0.dynamicConfiguration
            } ?? false
            let configurationIsAuthorized = matchesAcceptedPublication || matchesInitialConfiguration
            guard configurationIsAuthorized else {
                log(
                    "safe cloud package settings skipped local configuration changed",
                    packageName: snapshotPlugin.id
                )
                continue
            }
            let integrityIsAuthorized = matchesAcceptedPublication
                || validInitialCodeFingerprints.contains(PackageCodeFingerprint(current))
            guard integrityIsAuthorized else {
                log(
                    "safe cloud package settings skipped unverified payload",
                    packageName: snapshotPlugin.id
                )
                continue
            }
            guard Self.safeCloudStateMatchesInstalledCodeAndProvenance(
                snapshotPlugin.state,
                current
            ) else {

                log(
                    "safe cloud package settings skipped fingerprint mismatch",
                    packageName: snapshotPlugin.id
                )
                continue
            }
            var candidate = current
            let requestedDomain = snapshotPlugin.state.selectedDomainURL
            let requestedDomainIsAllowed = requestedDomain.map { domain in
                candidate.manifest.domains?.contains(where: { $0.url == domain }) == true
                    && Self.isSafeHTTPSURL(domain)
            } ?? true
            if requestedDomainIsAllowed, candidate.selectedDomainURL != requestedDomain {
                candidate.selectedDomainURL = requestedDomain
                runtimeResetPackageIDs.insert(candidate.id)
                cookieResetPackageIDs.insert(candidate.id)
            }
            let incomingProviders = snapshotPlugin.state.providers.reduce(into: [String: SkyStreamProviderState]()) {
                if $0[$1.id] == nil { $0[$1.id] = $1 }
            }
            let baselineProviders = baseline?.providers.reduce(
                into: [String: SkyStreamProviderState](),
                { if $0[$1.id] == nil { $0[$1.id] = $1 } }
            ) ?? [:]
            for providerIndex in candidate.providers.indices {
                let sourceID = candidate.providers[providerIndex].id
                guard let incoming = incomingProviders[sourceID], incoming.removedAt == nil else { continue }
                incomingSourceStates[sourceID] = incoming
                if candidate.providers[providerIndex].isEnabled
                    == baselineProviders[sourceID]?.isEnabled,
                   candidate.providers[providerIndex].isEnabled != incoming.isEnabled {
                    candidate.providers[providerIndex].isEnabled = incoming.isEnabled
                    cacheInvalidationPackageIDs.insert(candidate.id)
                }
            }
            guard let mergedPreferences = SkyStreamPrivateCloudConfigurationPolicy.restoredPreferences(
                local: candidate.preferences,
                incoming: snapshotPlugin.state.preferences,
                incomingIsComplete: snapshot.privateCloudConfigurationIsComplete == true
                    && !snapshotPlugin.preferencesWereRedacted
            ) else { throw SkyStreamPluginManagerError.invalidBackup }
            if !Self.safeCloudPreferenceBehaviorIsEqual(
                candidate.preferences,
                mergedPreferences
            ) {
                candidate.preferences = mergedPreferences
                runtimeResetPackageIDs.insert(candidate.id)
                transientSessionPreservingPackageIDs.insert(candidate.id)
            }
            if candidate != current {
                candidate.updatedAt = Date()
                installedPlugins[index] = candidate
                changedPackageIDs.insert(candidate.id)
            }
        }

        if snapshot.privateCloudConfigurationIsComplete == true {
            let incomingPackageIDs = Set(snapshot.plugins.map(\.id))
            for index in installedPlugins.indices where !incomingPackageIDs.contains(installedPlugins[index].id) {
                let current = installedPlugins[index]
                guard let baseline = configurationBaseline[current.id],
                      DynamicProviderConfigurationFingerprint(current) == baseline.dynamicConfiguration,
                      validInitialCodeFingerprints.contains(PackageCodeFingerprint(current)),
                      !current.preferences.isEmpty else {
                    continue
                }
                installedPlugins[index].preferences = [:]
                installedPlugins[index].updatedAt = Date()
                changedPackageIDs.insert(current.id)
                runtimeResetPackageIDs.insert(current.id)
                transientSessionPreservingPackageIDs.insert(current.id)
            }
        }

        let currentSourceDefaults = sourceDefaultsSnapshot()
        let sourceComparisonBaseline = Self.reconciledSourceDefaultsSnapshot(
            initialSourceDefaults,
            plugins: installedPlugins
        )
        let allCurrentSourceIDs = Set(installedPlugins.flatMap {
            Self.currentProviderPairs(for: $0.manifest).map(\.sourceID)
        })
        let targetSourceDefaults = Self.mergedSafeCloudSourceDefaults(
            baseline: sourceComparisonBaseline,
            current: currentSourceDefaults,
            incomingBySourceID: incomingSourceStates,
            allCurrentSourceIDs: allCurrentSourceIDs
        )
        let sourceDefaultsChanged = targetSourceDefaults != currentSourceDefaults
        if sourceDefaultsChanged {
            for index in installedPlugins.indices {
                var overlaid = Self.pluginByOverlayingSourceDefaults(
                    installedPlugins[index],
                    snapshot: targetSourceDefaults
                )
                if overlaid.providers != installedPlugins[index].providers {
                    overlaid.updatedAt = Date()
                    changedPackageIDs.insert(overlaid.id)
                    cacheInvalidationPackageIDs.insert(overlaid.id)
                    installedPlugins[index] = overlaid
                }
            }
        }

        try Task.checkCancellation()
        let persistenceChanged = repositories != oldRepositories || installedPlugins != oldPlugins
        let configuredPackageIDs = changedPackageIDs.sorted()
        if persistenceChanged {
            let sessionPreservingPackageIDs = transientSessionPreservingPackageIDs
                .subtracting(cookieResetPackageIDs)
            try await persist(
                runtimeResetPackageIDs: runtimeResetPackageIDs,
                expectedScopeGeneration: expectedScopeAuthority.serviceStoreGeneration
            ) {
                for packageName in runtimeResetPackageIDs.sorted() {
                    await SkyStreamRuntimePool.shared.invalidatePackage(
                        packageName,
                        resetCookies: cookieResetPackageIDs.contains(packageName),
                        resetDataStore: !sessionPreservingPackageIDs.contains(packageName)
                    )
                }
                if sourceDefaultsChanged {
                    Self.applySourceDefaultsSnapshot(targetSourceDefaults)
                }
            }
        } else if sourceDefaultsChanged {
            guard expectedScopeAuthority.isCurrent else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
            Self.applySourceDefaultsSnapshot(targetSourceDefaults)
            reconcileSkySourceDefaults()
        }
        metadataCommitted = true
        for packageName in cacheInvalidationPackageIDs.subtracting(runtimeResetPackageIDs) {
            SkyStreamResolver.shared.invalidateCachesForPackage(packageName)
        }
        let dynamicPackageIDs = runtimeResetPackageIDs.sorted()
            .filter { plugin(packageName: $0)?.usesDynamicProviders == true }
        return SafeCloudMetadataCommit(
            configuredPackageIDs: configuredPackageIDs,
            dynamicPackageIDs: dynamicPackageIDs
        )
    }

    private func prefetchSafeCloudReconstructionArchives(
        _ snapshot: SkyStreamBackupSnapshot
    ) async -> [String: Data] {
        let candidates = snapshot.plugins.filter {
            $0.payloadWasRedacted
                && plugin(packageName: $0.id) == nil
                && Self.isSafeHTTPSURL($0.state.provenance.sourceURL)
        }
        guard !candidates.isEmpty else { return [:] }

        let repositoryManager = self.repositoryManager
        return await withTaskGroup(of: SafeCloudReconstructionFetch.self) { group in
            let maximumConcurrentFetches = 4
            var nextIndex = 0
            var inFlightPackages = 0
            var aggregateBytes = 0
            var accepted: [String: Data] = [:]

            func addFetch(_ candidate: SkyStreamPluginBackupSnapshot) {
                group.addTask {
                    guard !Task.isCancelled else { return .package(id: candidate.id, data: nil) }
                    do {
                        let resolution = try await repositoryManager.resolveUserInput(
                            candidate.state.provenance.sourceURL
                        )
                        guard case .archive(let data, _) = resolution else {
                            return .package(id: candidate.id, data: nil)
                        }
                        return .package(id: candidate.id, data: data)
                    } catch {
                        return .package(id: candidate.id, data: nil)
                    }
                }
            }

            while nextIndex < min(maximumConcurrentFetches, candidates.count) {
                addFetch(candidates[nextIndex])
                nextIndex += 1
                inFlightPackages += 1
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return .deadline
            }

            while inFlightPackages > 0, let result = await group.next() {
                switch result {
                case .deadline:
                    group.cancelAll()
                    inFlightPackages = 0
                case .package(let id, let data):
                    inFlightPackages -= 1
                    if let data,
                       data.count <= Self.maximumPackageArchiveBytes,
                       let expected = candidates.first(where: { $0.id == id }),
                       Self.sha256Hex(data).caseInsensitiveCompare(
                            expected.state.archiveSHA256
                       ) == .orderedSame {
                        let (nextBytes, overflow) = aggregateBytes.addingReportingOverflow(data.count)
                        if !overflow, nextBytes <= Self.maximumManualBackupArchiveBytes {
                            aggregateBytes = nextBytes
                            accepted[id] = data
                        }
                    }
                    if nextIndex < candidates.count,
                       aggregateBytes < Self.maximumManualBackupArchiveBytes {
                        addFetch(candidates[nextIndex])
                        nextIndex += 1
                        inFlightPackages += 1
                    }
                }
            }
            group.cancelAll()
            return accepted
        }
    }

    private struct PreparedManualRestorePackage {
        let backup: SkyStreamInstalledPluginState
        let existingInstalled: SkyStreamInstalledPluginState?
        let stagedPayloadURL: URL?
        let archiveData: Data?
        let effectiveManifest: SkyStreamPluginManifest
        let archiveSHA256: String
        let scriptSHA256: String
        let compatibility: SkyStreamCompatibilityResult
        let usesDynamicProviders: Bool
        let expandedByteCount: UInt64
    }

    private struct PreparedManualRestoreSnapshot {
        let transactionRootURL: URL
        let restoredRepositories: [SkyStreamSavedRepository]
        let preparedPackages: [PreparedManualRestorePackage]
        let installedBaseline: [SkyStreamInstalledPluginState]
        let repositoryBaseline: [SkyStreamSavedRepository]
    }

    private struct PublishedManualRestorePackage {
        let installed: SkyStreamInstalledPluginState
        let newlyPublishedPayloadURL: URL?
        let newlyPublishedArchiveURL: URL?
    }

    private func prepareAuthoritativeManualSnapshot(
        _ snapshot: SkyStreamBackupSnapshot
    ) async throws -> PreparedManualRestoreSnapshot {
        guard snapshot.schemaVersion == 1,
              !snapshot.isSafeCloudSnapshot,
              snapshot.plugins.count <= 128,
              snapshot.repositories.count <= 64 else {
            throw SkyStreamPluginManagerError.invalidBackup
        }
        guard snapshot.plugins.allSatisfy({
            SkyStreamBackupMetadataPolicy.isBounded(pluginState: $0.state)
        }) else {
            throw SkyStreamPluginManagerError.invalidBackup
        }
        let restoredRepositories = try restoredRepositories(from: snapshot.repositories)
        var aggregateArchiveBytes = 0
        for plugin in snapshot.plugins {
            guard let archiveByteCount = plugin.archivePayload?.count,
                  archiveByteCount <= Self.maximumPackageArchiveBytes else {
                throw SkyStreamPluginManagerError.invalidBackup
            }
            let (nextAggregateBytes, overflow) = aggregateArchiveBytes.addingReportingOverflow(archiveByteCount)
            guard !overflow, nextAggregateBytes <= Self.maximumManualBackupArchiveBytes else {
                throw SkyStreamPluginManagerError.backupArchiveBudgetExceeded(
                    maximumBytes: Self.maximumManualBackupArchiveBytes
                )
            }
            aggregateArchiveBytes = nextAggregateBytes
        }

        let packageNames = snapshot.plugins.map(\.state.id)
        guard Set(packageNames).count == packageNames.count,
              packageNames.allSatisfy(SkyStreamStableID.isValidPackageName) else {
            throw SkyStreamPluginManagerError.invalidBackup
        }
        let repositoryURLs = snapshot.repositories.map(\.sourceURL)
        guard Set(repositoryURLs).count == repositoryURLs.count else {
            throw SkyStreamPluginManagerError.invalidBackup
        }

        let installedBaseline = installedPlugins
        let repositoryBaseline = repositories
        try prepareDirectories()
        let transactionRoot = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: false)
        var preparationCompleted = false
        defer {
            if !preparationCompleted {
                try? removeManagedItem(url: transactionRoot)
            }
        }

        var preparedPackages: [PreparedManualRestorePackage] = []
        preparedPackages.reserveCapacity(snapshot.plugins.count)
        var aggregateExpandedBytes: UInt64 = 0
        for (offset, backupPlugin) in snapshot.plugins.enumerated() {
            try Task.checkCancellation()
            guard !backupPlugin.payloadWasRedacted,
                  !backupPlugin.preferencesWereRedacted,
                  let archive = backupPlugin.archivePayload,
                  archive.count <= Self.maximumPackageArchiveBytes,
                  Self.sha256Hex(archive).caseInsensitiveCompare(backupPlugin.state.archiveSHA256) == .orderedSame,
                  Self.isSafeHTTPSURL(backupPlugin.state.provenance.sourceURL),
                  URL(string: backupPlugin.state.provenance.sourceURL) != nil else {
                throw SkyStreamPluginManagerError.invalidBackup
            }
            let packageStagingRoot = transactionRoot.appendingPathComponent(
                "package-\(offset)-\(UUID().uuidString)",
                isDirectory: true
            )
            let remainingExpandedBytes = Self.maximumManualRestoreExpandedBytes
                - aggregateExpandedBytes
            let prepared = try await prepareManualRestorePackage(
                backupPlugin,
                archive: archive,
                stagingRoot: packageStagingRoot,
                existing: installedBaseline.first { $0.id == backupPlugin.id },
                maximumExpandedBytes: remainingExpandedBytes
            )
            let (nextExpandedBytes, expandedOverflow) = aggregateExpandedBytes
                .addingReportingOverflow(prepared.expandedByteCount)
            guard !expandedOverflow,
                  nextExpandedBytes <= Self.maximumManualRestoreExpandedBytes else {
                throw SkyStreamPackageValidationError.expandedDataTooLarge(
                    actual: nextExpandedBytes,
                    maximum: Self.maximumManualRestoreExpandedBytes
                )
            }
            aggregateExpandedBytes = nextExpandedBytes
            preparedPackages.append(prepared)
        }

        preparationCompleted = true
        return PreparedManualRestoreSnapshot(
            transactionRootURL: transactionRoot,
            restoredRepositories: restoredRepositories,
            preparedPackages: preparedPackages,
            installedBaseline: installedBaseline,
            repositoryBaseline: repositoryBaseline
        )
    }

    private func commitAuthoritativeManualSnapshotUnlocked(
        _ preparedSnapshot: PreparedManualRestoreSnapshot
    ) async throws -> [String] {
        guard isLoaded else { throw notLoadedError }
        let transactionRootValues = try? preparedSnapshot.transactionRootURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard installedPlugins == preparedSnapshot.installedBaseline,
              repositories == preparedSnapshot.repositoryBaseline else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        guard isDescendant(preparedSnapshot.transactionRootURL, of: stagingRoot),
              transactionRootValues?.isDirectory == true,
              transactionRootValues?.isSymbolicLink != true else {
            throw SkyStreamPluginManagerError.invalidPersistedPath
        }

        var newlyPublishedPayloads: [URL] = []
        var newlyPublishedArchives: [URL] = []
        var publicationCommitted = false
        defer {
            if !publicationCommitted {
                for url in newlyPublishedPayloads { try? removeManagedItem(url: url) }
                for url in newlyPublishedArchives { try? removeManagedItem(url: url) }
            }
        }

        var restoredPlugins: [SkyStreamInstalledPluginState] = []
        restoredPlugins.reserveCapacity(preparedSnapshot.preparedPackages.count)
        for prepared in preparedSnapshot.preparedPackages {
            try Task.checkCancellation()
            let published = try publishManualRestorePackage(prepared)
            if let url = published.newlyPublishedPayloadURL { newlyPublishedPayloads.append(url) }
            if let url = published.newlyPublishedArchiveURL { newlyPublishedArchives.append(url) }
            restoredPlugins.append(try restoredState(
                from: prepared.backup,
                installed: published.installed
            ))
        }

        let intermediatePlugins = preparedSnapshot.installedBaseline
        let previousRepositories = repositories
        let previousPlugins = installedPlugins
        repositories = preparedSnapshot.restoredRepositories
        installedPlugins = restoredPlugins
        let affectedPackageIDs = Set(intermediatePlugins.map(\.id))
            .union(restoredPlugins.map(\.id))
            .sorted()
        do {
            try await persist(runtimeResetPackageIDs: Set(affectedPackageIDs)) {
                for packageName in affectedPackageIDs {
                    await SkyStreamRuntimePool.shared.invalidatePackage(
                        packageName,
                        resetCookies: true,
                        resetDataStore: true
                    )
                }
            }
        } catch {
            repositories = previousRepositories
            installedPlugins = previousPlugins
            throw error
        }
        publicationCommitted = true

        let retainedPaths = Set(restoredPlugins.map(\.payloadRelativePath))
        let retainedArchives = Set(restoredPlugins.map { "\($0.id)|\($0.archiveSHA256.lowercased())" })
        for stale in intermediatePlugins where !retainedPaths.contains(stale.payloadRelativePath) {
            removeSharedManagedItem(relativePath: stale.payloadRelativePath)
            if !retainedArchives.contains("\(stale.id)|\(stale.archiveSHA256.lowercased())") {
                removeSharedManagedItem(url: archiveURL(for: stale))
            }
        }
        return affectedPackageIDs
    }

    private func prepareManualRestorePackage(
        _ backupPlugin: SkyStreamPluginBackupSnapshot,
        archive: Data,
        stagingRoot: URL,
        existing: SkyStreamInstalledPluginState?,
        maximumExpandedBytes: UInt64
    ) async throws -> PreparedManualRestorePackage {
        try Task.checkCancellation()
        let backup = backupPlugin.state
        if let existing,
           existing.archiveSHA256.caseInsensitiveCompare(backup.archiveSHA256) == .orderedSame,
           existing.scriptSHA256.caseInsensitiveCompare(backup.scriptSHA256) == .orderedSame,
           (try? verifyScriptIntegrity(for: existing)) != nil {
            let usesDynamicProviders = backup.usesDynamicProviders == true
                || existing.usesDynamicProviders == true
            var effectiveManifest = existing.manifest
            if usesDynamicProviders {
                effectiveManifest.providers = try await validatedDynamicProviders(
                    backup.manifest.providers ?? []
                )
            }
            return PreparedManualRestorePackage(
                backup: backup,
                existingInstalled: existing,
                stagedPayloadURL: nil,

                archiveData: archive,
                effectiveManifest: effectiveManifest,
                archiveSHA256: existing.archiveSHA256,
                scriptSHA256: existing.scriptSHA256,
                compatibility: existing.compatibility,
                usesDynamicProviders: usesDynamicProviders,
                expandedByteCount: 0
            )
        }

        guard isDescendant(stagingRoot, of: self.stagingRoot) else {
            throw SkyStreamPluginManagerError.invalidPersistedPath
        }
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        let archiveFile = stagingRoot.appendingPathComponent("candidate.sky", isDirectory: false)
        let candidatePayload = stagingRoot.appendingPathComponent("payload", isDirectory: true)
        try archive.write(to: archiveFile, options: [.atomic, .completeFileProtectionUnlessOpen])

        var validationLimits = SkyStreamPackageValidationLimits.default
        validationLimits.maximumExpandedBytes = min(
            validationLimits.maximumExpandedBytes,
            maximumExpandedBytes
        )
        let boundedValidationLimits = validationLimits
        let expectedPackageName = backup.id
        let expectedArchiveSHA256 = backup.archiveSHA256
        let expectedScriptSHA256 = backup.scriptSHA256
        let validated = try await Task.detached(priority: .userInitiated) {
            try SkyStreamPackageValidator.validateAndExtract(
                archiveAt: archiveFile,
                to: candidatePayload,
                expectedPackageName: expectedPackageName,
                expectedArchiveSHA256: expectedArchiveSHA256,
                expectedScriptSHA256: expectedScriptSHA256,
                limits: boundedValidationLimits
            )
        }.value
        try Task.checkCancellation()
        guard validated.manifest.packageName == backup.id,
              validated.manifest.version == backup.manifest.version else {
            throw SkyStreamPluginManagerError.invalidBackup
        }
        try Task.checkCancellation()

        let scriptURL = candidatePayload.appendingPathComponent("plugin.js", isDirectory: false)
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let compatibility = Self.staticCompatibility(for: validated.manifest, script: script)
        if compatibility.status == .incompatible {
            throw SkyStreamPluginManagerError.packageIncompatible(
                compatibility.reasons.first?.message ?? "This SkyStream package is incompatible."
            )
        }

        try Self.validateReplacement(
            existing: existing,
            proposedManifest: validated.manifest,
            proposedArchiveHash: validated.archiveSHA256,
            provenance: backup.provenance,
            policy: .userConfirmedReplacement
        )

        let usesDynamicProviders = validated.manifest.providers?.isEmpty == true
        try beginPackageRuntimeValidation(packageName: backup.id)
        defer { endPackageRuntimeValidation(packageName: backup.id) }
        let selectedDomainURL = Self.reconciledDomain(
            previous: backup.selectedDomainURL,
            manifest: validated.manifest
        )
        let smokePackage = SkyStreamInstalledPluginState(
            manifest: validated.manifest,
            archiveSHA256: validated.archiveSHA256,
            scriptSHA256: validated.scriptSHA256,
            payloadRelativePath: "staging-only",
            provenance: backup.provenance,
            selectedDomainURL: selectedDomainURL,
            compatibility: compatibility,
            providers: [],
            preferences: backup.preferences
        )

        let manualValidationState = SkyStreamRuntimeStorageSnapshot(
            storage: backup.runtimeStorage ?? [:],
            preferences: backup.preferences.mapValues(\.value)
        )
        let boundedManualValidationState = SkyStreamRuntimeDataStore(
            snapshot: manualValidationState
        ).snapshot()
        guard boundedManualValidationState == manualValidationState else {
            throw SkyStreamPluginManagerError.invalidBackup
        }
        let validation = try await SkyStreamRuntimePool.shared.validateStagedPackage(
            package: smokePackage,
            scriptURL: scriptURL,
            discoverDynamicProviders: usesDynamicProviders,
            isolatedState: boundedManualValidationState,
            allowsRecoverableProviderDiscoveryFailure: true
        )
        var effectiveManifest = validated.manifest
        if usesDynamicProviders {
            let discovered = validation.providers ?? []
            effectiveManifest.providers = try await validatedDynamicProviders(
                discovered.isEmpty ? (backup.manifest.providers ?? []) : discovered
            )
            guard effectiveManifest.providers?.isEmpty == false else {
                throw SkyStreamPluginManagerError.packageIncompatible(
                    "This package did not return any usable dynamic providers."
                )
            }
        }

        return PreparedManualRestorePackage(
            backup: backup,
            existingInstalled: nil,
            stagedPayloadURL: candidatePayload,
            archiveData: archive,
            effectiveManifest: effectiveManifest,
            archiveSHA256: validated.archiveSHA256,
            scriptSHA256: validated.scriptSHA256,
            compatibility: compatibility,
            usesDynamicProviders: usesDynamicProviders,
            expandedByteCount: validated.expandedByteCount
        )
    }

    private func publishManualRestorePackage(
        _ prepared: PreparedManualRestorePackage
    ) throws -> PublishedManualRestorePackage {
        if let existing = prepared.existingInstalled {
            guard let archiveData = prepared.archiveData,
                  prepared.effectiveManifest.packageName == existing.id,
                  prepared.effectiveManifest.version == existing.manifest.version,
                  Self.sha256Hex(archiveData)
                    .caseInsensitiveCompare(existing.archiveSHA256) == .orderedSame,
                  (try? verifyScriptIntegrity(for: existing)) != nil else {
                throw SkyStreamPluginManagerError.invalidBackup
            }
            let existingArchiveURL = archiveURL(for: existing)
            let existingArchiveValues = try? existingArchiveURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            let existingArchiveData: Data?
            if existingArchiveValues?.isRegularFile == true,
               existingArchiveValues?.isSymbolicLink != true,
               (existingArchiveValues?.fileSize ?? Self.maximumPackageArchiveBytes + 1)
                    <= Self.maximumPackageArchiveBytes {
                existingArchiveData = try? Data(
                    contentsOf: existingArchiveURL,
                    options: [.mappedIfSafe]
                )
            } else {
                existingArchiveData = nil
            }
            let archiveIsValid = existingArchiveData.map {
                Self.sha256Hex($0).caseInsensitiveCompare(existing.archiveSHA256) == .orderedSame
            } ?? false
            var newlyPublishedArchiveURL: URL?
            if !archiveIsValid {
                let archiveAlreadyExisted = fileManager.fileExists(atPath: existingArchiveURL.path)
                if !archiveAlreadyExisted { newlyPublishedArchiveURL = existingArchiveURL }
                try fileManager.createDirectory(
                    at: existingArchiveURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
                )
                do {
                    try archiveData.write(
                        to: existingArchiveURL,
                        options: [.atomic, .completeFileProtectionUnlessOpen]
                    )
                } catch {
                    if let newlyPublishedArchiveURL {
                        try? removeManagedItem(url: newlyPublishedArchiveURL)
                    }
                    throw error
                }
                guard let repaired = try? Data(
                    contentsOf: existingArchiveURL,
                    options: [.mappedIfSafe]
                ), repaired.count <= Self.maximumPackageArchiveBytes,
                    Self.sha256Hex(repaired)
                    .caseInsensitiveCompare(existing.archiveSHA256) == .orderedSame else {
                    if let newlyPublishedArchiveURL {
                        try? removeManagedItem(url: newlyPublishedArchiveURL)
                    }
                    throw SkyStreamPluginManagerError.integrityFailure
                }
            }
            var restoredInstalled = existing
            restoredInstalled.manifest = prepared.effectiveManifest
            restoredInstalled.usesDynamicProviders = prepared.usesDynamicProviders
            return PublishedManualRestorePackage(
                installed: restoredInstalled,
                newlyPublishedPayloadURL: nil,
                newlyPublishedArchiveURL: newlyPublishedArchiveURL
            )
        }
        guard let stagedPayload = prepared.stagedPayloadURL,
              let archiveData = prepared.archiveData else {
            throw SkyStreamPluginManagerError.invalidBackup
        }
        let stagedPayloadValues = try? stagedPayload.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard isDescendant(stagedPayload, of: stagingRoot),
              stagedPayloadValues?.isDirectory == true,
              stagedPayloadValues?.isSymbolicLink != true else {
            throw SkyStreamPluginManagerError.invalidPersistedPath
        }

        let packageDirectoryName = Self.safePackageDirectoryName(
            manifest: prepared.effectiveManifest,
            archiveHash: prepared.archiveSHA256
        )
        let publishedPayload = packageRoot.appendingPathComponent(packageDirectoryName, isDirectory: true)
        guard isDescendant(publishedPayload, of: packageRoot),
              !fileManager.fileExists(atPath: publishedPayload.path) else {
            throw SkyStreamPluginManagerError.invalidPersistedPath
        }

        var succeeded = false
        var newlyPublishedArchive: URL?
        defer {
            if !succeeded {
                try? removeManagedItem(url: publishedPayload)
                if let newlyPublishedArchive { try? removeManagedItem(url: newlyPublishedArchive) }
            }
        }

        try fileManager.moveItem(at: stagedPayload, to: publishedPayload)
        try setProtectedAttributesRecursively(at: publishedPayload)

        let publishedArchive = archiveURL(
            packageName: prepared.backup.id,
            archiveHash: prepared.archiveSHA256
        )
        guard isDescendant(publishedArchive, of: archiveRoot) else {
            throw SkyStreamPluginManagerError.invalidPersistedPath
        }
        let archiveAlreadyExisted = fileManager.fileExists(atPath: publishedArchive.path)
        if !archiveAlreadyExisted {
            newlyPublishedArchive = publishedArchive
            try fileManager.createDirectory(
                at: publishedArchive.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        }

        try archiveData.write(to: publishedArchive, options: [.atomic, .completeFileProtectionUnlessOpen])
        let finalArchiveValues = try? publishedArchive.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard finalArchiveValues?.isRegularFile == true,
              finalArchiveValues?.isSymbolicLink != true,
              (finalArchiveValues?.fileSize ?? Self.maximumPackageArchiveBytes + 1)
                <= Self.maximumPackageArchiveBytes,
              let finalArchiveData = try? Data(
            contentsOf: publishedArchive,
            options: [.mappedIfSafe]
        ), Self.sha256Hex(finalArchiveData)
            .caseInsensitiveCompare(prepared.archiveSHA256) == .orderedSame else {
            throw SkyStreamPluginManagerError.integrityFailure
        }

        let installed = SkyStreamInstalledPluginState(
            manifest: prepared.effectiveManifest,
            archiveSHA256: prepared.archiveSHA256,
            scriptSHA256: prepared.scriptSHA256,
            payloadRelativePath: relativeManagedPath(for: publishedPayload),
            provenance: prepared.backup.provenance,
            selectedDomainURL: Self.reconciledDomain(
                previous: prepared.backup.selectedDomainURL,
                manifest: prepared.effectiveManifest
            ),
            compatibility: prepared.compatibility,
            providers: [],
            usesDynamicProviders: prepared.usesDynamicProviders,
            installedAt: prepared.backup.installedAt
        )
        let publishedScript = publishedPayload.appendingPathComponent("plugin.js", isDirectory: false)
        let publishedScriptValues = try? publishedScript.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard publishedScriptValues?.isRegularFile == true,
              publishedScriptValues?.isSymbolicLink != true,
              (publishedScriptValues?.fileSize ?? 10 * 1_024 * 1_024 + 1)
                <= 10 * 1_024 * 1_024,
              let finalData = try? Data(contentsOf: publishedScript, options: [.mappedIfSafe]),
              Self.sha256Hex(finalData).caseInsensitiveCompare(prepared.scriptSHA256) == .orderedSame else {
            throw SkyStreamPluginManagerError.integrityFailure
        }

        succeeded = true
        return PublishedManualRestorePackage(
            installed: installed,
            newlyPublishedPayloadURL: publishedPayload,
            newlyPublishedArchiveURL: newlyPublishedArchive
        )
    }

    private func restoredState(
        from backup: SkyStreamInstalledPluginState,
        installed: SkyStreamInstalledPluginState
    ) throws -> SkyStreamInstalledPluginState {
        guard backup.id == installed.id,
              backup.archiveSHA256.caseInsensitiveCompare(installed.archiveSHA256) == .orderedSame,
              backup.scriptSHA256.caseInsensitiveCompare(installed.scriptSHA256) == .orderedSame else {
            throw SkyStreamPluginManagerError.invalidBackup
        }

        guard backup.providers.count <= Self.maximumProviderStateCount else {
            throw SkyStreamPluginManagerError.invalidBackup
        }
        let validProviderStates = backup.providers.filter { state in
            guard state.packageName == installed.id else { return false }
            return state.providerID.map(SkyStreamStableID.isValidProviderID) ?? true
        }
        let providers = Self.reconciledProviderStates(
            manifest: installed.manifest,
            previous: Array(validProviderStates)
        ).states

        let selectedDomain: String?
        if let candidate = backup.selectedDomainURL,
           installed.manifest.domains?.contains(where: { $0.url == candidate }) == true,
           (try? SkyStreamRemoteURLPolicy.shared.validateSyntactic(candidate, purpose: .pluginRequest)) != nil {
            selectedDomain = candidate
        } else {
            selectedDomain = Self.reconciledDomain(previous: nil, manifest: installed.manifest)
        }

        let runtimeStore = SkyStreamRuntimeDataStore(snapshot: .init(
            storage: backup.runtimeStorage ?? [:],
            preferences: backup.preferences.mapValues(\.value)
        ))
        let boundedRuntime = runtimeStore.snapshot()
        guard boundedRuntime.storage == (backup.runtimeStorage ?? [:]),
              boundedRuntime.preferences == backup.preferences.mapValues(\.value) else {
            throw SkyStreamPluginManagerError.invalidBackup
        }
        let preferences = boundedRuntime.preferences.reduce(into: [String: SkyStreamPreferenceValue]()) {
            let metadata = backup.preferences[$1.key]
            $0[$1.key] = SkyStreamPreferenceValue(
                value: $1.value,
                isSecret: metadata?.isSecret ?? true,
                isRedacted: false,
                updatedAt: metadata?.updatedAt
            )
        }

        var provenance = backup.provenance
        guard Self.isSafeHTTPSURL(provenance.sourceURL),
              provenance.repositoryURL.map(Self.isSafeHTTPSURL) ?? true,
              provenance.pluginListURL.map(Self.isSafeHTTPSURL) ?? true else {
            throw SkyStreamPluginManagerError.invalidBackup
        }
        provenance.expectedArchiveSHA256 = installed.archiveSHA256

        return SkyStreamInstalledPluginState(
            manifest: installed.manifest,
            archiveSHA256: installed.archiveSHA256,
            scriptSHA256: installed.scriptSHA256,
            payloadRelativePath: installed.payloadRelativePath,
            provenance: provenance,
            selectedDomainURL: selectedDomain,
            compatibility: installed.compatibility,
            providers: providers,
            usesDynamicProviders: installed.usesDynamicProviders,
            runtimeStorage: boundedRuntime.storage.isEmpty ? nil : boundedRuntime.storage,
            preferences: preferences,
            installedAt: backup.installedAt,
            updatedAt: Date(),
            additionalFields: backup.additionalFields
        )
    }

    private func restoredRepositories(
        from snapshots: [SkyStreamRepositoryBackupSnapshot]
    ) throws -> [SkyStreamSavedRepository] {
        try snapshots.map { snapshot in
            guard SkyStreamBackupMetadataPolicy.isBounded(repository: snapshot),
                  Self.isSafeHTTPSURL(snapshot.sourceURL),
                  let baseURL = URL(string: snapshot.sourceURL) else {
                throw SkyStreamPluginManagerError.invalidBackup
            }
            guard snapshot.pluginListURLs.count <= 32 else {
                throw SkyStreamPluginManagerError.invalidBackup
            }
            let listURLs = try snapshot.pluginListURLs.map { rawValue -> String in
                guard let resolved = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL,
                      Self.isSafeHTTPSURL(resolved.absoluteString) else {
                    throw SkyStreamPluginManagerError.invalidBackup
                }
                return resolved.absoluteString
            }
            switch snapshot.kind {
            case .repository:
                guard let manifest = snapshot.manifest,
                      SkyStreamRepositoryManifest.isSupportedManifestVersion(
                          manifest.manifestVersion
                      ),
                      !listURLs.isEmpty else {
                    throw SkyStreamPluginManagerError.invalidBackup
                }
            case .pluginList:
                guard snapshot.manifest == nil, !listURLs.isEmpty else {
                    throw SkyStreamPluginManagerError.invalidBackup
                }
            }
            return SkyStreamSavedRepository(
                sourceURL: snapshot.sourceURL,
                kind: snapshot.kind,
                name: snapshot.name,
                repositoryPackageName: snapshot.manifest?.packageName,
                manifest: snapshot.manifest,
                pluginListURLs: listURLs,
                plugins: [],
                lastRefreshedAt: snapshot.lastRefreshedAt ?? .distantPast,
                frozenAt: snapshot.frozenAt
            )
        }
    }

    private func prepareInstallArchive(
        _ data: Data,
        expectedEntry: SkyStreamPluginListEntry?,
        provenance: SkyStreamInstallProvenance,
        replacementPolicy: SkyStreamReplacementPolicy,
        installedBaseline: [SkyStreamInstalledPluginState],
        repositoryAuthority: RepositoryInstallAuthority?,
        expectedScopeAuthority: SkyStreamServiceScopeAuthority,
        requiredPackageName: String? = nil
    ) async throws -> PreparedInstall {
        try Task.checkCancellation()
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamPluginManagerError.unavailable
        }
        guard isLoaded else { throw notLoadedError }
        if let expectedPackageName = expectedEntry?.manifest.packageName ?? requiredPackageName {
            let initialTarget = installedBaseline.first { $0.id == expectedPackageName }
            let currentTarget = installedPlugins.first { $0.id == expectedPackageName }
            guard currentTarget.map(InstallValidationAuthorityFingerprint.init)
                    == initialTarget.map(InstallValidationAuthorityFingerprint.init) else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
        }
        if let repositoryAuthority {
            guard repositoryInstallAuthorityIsCurrent(repositoryAuthority) else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
        }
        guard data.count <= Self.maximumPackageArchiveBytes else {
            throw SkyStreamPackageValidationError.archiveTooLarge(
                actual: UInt64(data.count),
                maximum: UInt64(Self.maximumPackageArchiveBytes)
            )
        }
        try prepareDirectories()

        let transactionRoot = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: false)
        var preparationCompleted = false
        defer {
            if !preparationCompleted {
                try? removeManagedItem(url: transactionRoot)
            }
        }
        let archiveFile = transactionRoot.appendingPathComponent("candidate.sky", isDirectory: false)
        let candidatePayload = transactionRoot.appendingPathComponent("payload", isDirectory: true)
        try data.write(to: archiveFile, options: [.atomic, .completeFileProtectionUnlessOpen])

        let expectedPackageName = expectedEntry?.manifest.packageName ?? requiredPackageName
        let expectedArchiveSHA256 = expectedEntry?.expectedArchiveSHA256
        let expectedScriptSHA256 = expectedEntry?.scriptSHA256
        let validated = try await Task.detached(priority: .userInitiated) {
            try SkyStreamPackageValidator.validateAndExtract(
                archiveAt: archiveFile,
                to: candidatePayload,
                expectedPackageName: expectedPackageName,
                expectedArchiveSHA256: expectedArchiveSHA256,
                expectedScriptSHA256: expectedScriptSHA256
            )
        }.value
        try Task.checkCancellation()
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        if let expectedEntry {
            guard expectedEntry.manifest.version == validated.manifest.version,
                  expectedEntry.manifest.packageName == validated.manifest.packageName else {
                throw SkyStreamPluginManagerError.catalogManifestMismatch
            }
        }
        if let requiredPackageName,
           validated.manifest.packageName != requiredPackageName {
            throw SkyStreamPluginManagerError.catalogManifestMismatch
        }
        try Task.checkCancellation()

        let scriptURL = candidatePayload.appendingPathComponent("plugin.js", isDirectory: false)
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let compatibility = Self.staticCompatibility(for: validated.manifest, script: script)
        if compatibility.status == .incompatible {
            throw SkyStreamPluginManagerError.packageIncompatible(
                compatibility.reasons.first?.message ?? "This SkyStream package is incompatible."
            )
        }

        let existing = installedBaseline.first {
            $0.id == validated.manifest.packageName
        }
        guard installedPlugins.first(where: {
            $0.id == validated.manifest.packageName
        }).map(InstallValidationAuthorityFingerprint.init)
            == existing.map(InstallValidationAuthorityFingerprint.init) else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        if existing == nil, installedPlugins.count >= Self.maximumInstalledPluginCount {
            throw SkyStreamPluginManagerError.capacityLimitReached(
                kind: "plugins",
                maximum: Self.maximumInstalledPluginCount
            )
        }
        try Self.validateReplacement(
            existing: existing,
            proposedManifest: validated.manifest,
            proposedArchiveHash: validated.archiveSHA256,
            provenance: provenance,
            policy: replacementPolicy
        )

        let isByteIdenticalReinstall = existing.map {
            $0.archiveSHA256.caseInsensitiveCompare(validated.archiveSHA256) == .orderedSame
                && $0.scriptSHA256.caseInsensitiveCompare(validated.scriptSHA256) == .orderedSame
                && (try? verifyScriptIntegrity(for: $0)) != nil
        } ?? false
        if isByteIdenticalReinstall, let existing {
            preparationCompleted = true
            return PreparedInstall(
                transactionRootURL: transactionRoot,
                stagedPayloadURL: candidatePayload,
                archiveData: data,
                validatedManifest: validated.manifest,
                effectiveManifest: existing.manifest,
                archiveSHA256: validated.archiveSHA256,
                scriptSHA256: validated.scriptSHA256,
                compatibility: existing.compatibility,
                usesDynamicProviders: existing.usesDynamicProviders == true,
                provenance: provenance,
                expectedEntry: expectedEntry,
                replacementPolicy: replacementPolicy,
                existingAtPreparation: existing,
                repositoryAuthority: repositoryAuthority,
                requiredPackageName: requiredPackageName,
                isByteIdenticalReinstall: true,
                scopeAuthority: expectedScopeAuthority
            )
        }

        let usesDynamicProviders = validated.manifest.providers?.isEmpty == true
        try beginPackageRuntimeValidation(packageName: validated.manifest.packageName)
        defer { endPackageRuntimeValidation(packageName: validated.manifest.packageName) }
        let smokePackage = SkyStreamInstalledPluginState(
            manifest: validated.manifest,
            archiveSHA256: validated.archiveSHA256,
            scriptSHA256: validated.scriptSHA256,
            payloadRelativePath: "staging-only",
            provenance: provenance,
            selectedDomainURL: Self.reconciledDomain(
                previous: existing?.selectedDomainURL,
                manifest: validated.manifest
            ),
            compatibility: compatibility,
            providers: [],
            preferences: existing?.preferences ?? [:]
        )
        let validation = try await SkyStreamRuntimePool.shared.validateStagedPackage(
            package: smokePackage,
            scriptURL: scriptURL,
            discoverDynamicProviders: usesDynamicProviders
        )
        guard expectedScopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        var effectiveManifest = validated.manifest
        if usesDynamicProviders {
            let discovered = validation.providers ?? []
            effectiveManifest.providers = try await validatedDynamicProviders(
                discovered
            )
            guard expectedScopeAuthority.isCurrent else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
            guard effectiveManifest.providers?.isEmpty == false else {
                throw SkyStreamPluginManagerError.packageIncompatible(
                    "This package did not return any usable dynamic providers."
                )
            }
        }

        preparationCompleted = true
        return PreparedInstall(
            transactionRootURL: transactionRoot,
            stagedPayloadURL: candidatePayload,
            archiveData: data,
            validatedManifest: validated.manifest,
            effectiveManifest: effectiveManifest,
            archiveSHA256: validated.archiveSHA256,
            scriptSHA256: validated.scriptSHA256,
            compatibility: compatibility,
            usesDynamicProviders: usesDynamicProviders,
            provenance: provenance,
            expectedEntry: expectedEntry,
            replacementPolicy: replacementPolicy,
            existingAtPreparation: existing,
            repositoryAuthority: repositoryAuthority,
            requiredPackageName: requiredPackageName,
            isByteIdenticalReinstall: false,
            scopeAuthority: expectedScopeAuthority
        )
    }

    private func commitPreparedInstall(
        _ prepared: PreparedInstall,
        safeRestoreToken: UUID? = nil
    ) async throws -> SkyStreamInstalledPluginState {
        defer { try? removeManagedItem(url: prepared.transactionRootURL) }
        let committed = try await withMutationGate {
            if let safeRestoreToken {
                try requireSafeRestoreIsCurrent(safeRestoreToken)
            }
            return try await commitPreparedInstallUnlocked(prepared)
        }
        guard prepared.scopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        let shouldRefreshAcceptedDynamicState = !prepared.isByteIdenticalReinstall
            && prepared.usesDynamicProviders
            && prepared.existingAtPreparation.map {
                Self.provenanceIdentity($0.provenance)
                    == Self.provenanceIdentity(prepared.provenance)
            } == true
        if shouldRefreshAcceptedDynamicState {
            do {
                try await refreshDynamicProviders(
                    packageName: committed.installed.id,
                    expectedScopeAuthority: prepared.scopeAuthority
                )
            } catch {
                guard prepared.scopeAuthority.isCurrent else {
                    throw SkyStreamPluginManagerError.stateChangedDuringValidation
                }
                log(
                    "installed update retained validated dynamic provider catalog",
                    packageName: committed.installed.id,
                    error: error
                )
            }
        }
        guard prepared.scopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        return plugin(packageName: committed.installed.id) ?? committed.installed
    }

    private func commitPreparedInstallUnlocked(
        _ prepared: PreparedInstall
    ) async throws -> CommittedInstall {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamPluginManagerError.unavailable
        }
        guard isLoaded else { throw notLoadedError }
        if let authority = prepared.repositoryAuthority {
            guard repositoryInstallAuthorityIsCurrent(authority) else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
        }

        let transactionRootValues = try? prepared.transactionRootURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let stagedPayloadValues = try? prepared.stagedPayloadURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard isDescendant(prepared.transactionRootURL, of: stagingRoot),
              transactionRootValues?.isDirectory == true,
              transactionRootValues?.isSymbolicLink != true,
              prepared.stagedPayloadURL.standardizedFileURL
                == prepared.transactionRootURL
                    .appendingPathComponent("payload", isDirectory: true)
                    .standardizedFileURL,
              stagedPayloadValues?.isDirectory == true,
              stagedPayloadValues?.isSymbolicLink != true,
              Self.sha256Hex(prepared.archiveData)
                .caseInsensitiveCompare(prepared.archiveSHA256) == .orderedSame,
              prepared.validatedManifest.packageName == prepared.effectiveManifest.packageName,
              (prepared.requiredPackageName == nil
                || prepared.requiredPackageName == prepared.validatedManifest.packageName),
              prepared.validatedManifest.version == prepared.effectiveManifest.version else {
            throw SkyStreamPluginManagerError.integrityFailure
        }
        let stagedScript = prepared.stagedPayloadURL
            .appendingPathComponent("plugin.js", isDirectory: false)
        guard isDescendant(stagedScript, of: prepared.stagedPayloadURL),
              let scriptValues = try? stagedScript.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              scriptValues.isRegularFile == true,
              scriptValues.isSymbolicLink != true,
              (scriptValues.fileSize ?? 10 * 1_024 * 1_024 + 1) <= 10 * 1_024 * 1_024,
              let stagedScriptData = try? Data(contentsOf: stagedScript, options: [.mappedIfSafe]),
              Self.sha256Hex(stagedScriptData)
                .caseInsensitiveCompare(prepared.scriptSHA256) == .orderedSame else {
            throw SkyStreamPluginManagerError.integrityFailure
        }
        if let expectedEntry = prepared.expectedEntry {
            let expectedArchiveMatches = expectedEntry.expectedArchiveSHA256.map {
                $0.caseInsensitiveCompare(prepared.archiveSHA256) == .orderedSame
            } ?? true
            let expectedScriptMatches = expectedEntry.scriptSHA256.map {
                $0.caseInsensitiveCompare(prepared.scriptSHA256) == .orderedSame
            } ?? true
            guard expectedEntry.manifest.packageName == prepared.validatedManifest.packageName,
                  expectedEntry.manifest.version == prepared.validatedManifest.version,
                  expectedArchiveMatches,
                  expectedScriptMatches else {
                throw SkyStreamPluginManagerError.catalogManifestMismatch
            }
        }

        let existing = installedPlugins.first {
            $0.id == prepared.validatedManifest.packageName
        }
        guard existing.map(InstallValidationAuthorityFingerprint.init)
                == prepared.existingAtPreparation.map(InstallValidationAuthorityFingerprint.init) else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }

        guard prepared.scopeAuthority.isCurrent else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        if existing == nil, installedPlugins.count >= Self.maximumInstalledPluginCount {
            throw SkyStreamPluginManagerError.capacityLimitReached(
                kind: "plugins",
                maximum: Self.maximumInstalledPluginCount
            )
        }
        try Self.validateReplacement(
            existing: existing,
            proposedManifest: prepared.validatedManifest,
            proposedArchiveHash: prepared.archiveSHA256,
            provenance: prepared.provenance,
            policy: prepared.replacementPolicy
        )
        let crossesProvenanceTrustDomain = existing.map {
            Self.provenanceBehaviorIdentity($0.provenance)
                != Self.provenanceBehaviorIdentity(prepared.provenance)
        } ?? false

        if prepared.isByteIdenticalReinstall {
            guard var existing,
                  existing.archiveSHA256.caseInsensitiveCompare(
                      prepared.archiveSHA256
                  ) == .orderedSame,
                  existing.scriptSHA256.caseInsensitiveCompare(
                      prepared.scriptSHA256
                  ) == .orderedSame,
                  (try? verifyScriptIntegrity(for: existing)) != nil,
                  let index = installedPlugins.firstIndex(where: { $0.id == existing.id }) else {
                throw SkyStreamPluginManagerError.stateChangedDuringValidation
            }
            let publishedArchive = archiveURL(for: existing)
            let archiveAlreadyExisted = fileManager.fileExists(atPath: publishedArchive.path)
            let newlyPublishedArchive = try ensureManagedArchive(
                prepared.archiveData,
                packageName: existing.id,
                archiveSHA256: existing.archiveSHA256
            )
            if !crossesProvenanceTrustDomain {

                log(
                    newlyPublishedArchive
                        ? "byte-identical plugin archive repaired"
                        : "byte-identical plugin update was a no-op",
                    packageName: existing.id
                )
                return CommittedInstall(installed: existing)
            }
            let previous = installedPlugins
            existing.provenance = prepared.provenance
            if crossesProvenanceTrustDomain {
                existing.runtimeStorage = nil
                existing.preferences = existing.preferences.filter {
                    !$0.value.isSecret && !$0.value.isRedacted
                }
            }
            existing.updatedAt = Date()
            installedPlugins[index] = existing
            do {
                if crossesProvenanceTrustDomain {
                    try await persist(
                        runtimeResetPackageIDs: [existing.id],
                        expectedScopeGeneration: prepared.scopeAuthority.serviceStoreGeneration
                    ) {
                        await SkyStreamRuntimePool.shared.invalidatePackage(
                            existing.id,
                            resetCookies: true,
                            resetDataStore: true
                        )
                    }
                } else {
                    try await persist(
                        expectedScopeGeneration: prepared.scopeAuthority.serviceStoreGeneration
                    )
                }
            } catch {
                if prepared.scopeAuthority.isCurrent {
                    installedPlugins = previous
                }
                if newlyPublishedArchive && !archiveAlreadyExisted {
                    try? removeManagedItem(url: publishedArchive)
                }
                throw error
            }
            log("byte-identical plugin reinstall committed", packageName: existing.id)
            return CommittedInstall(
                installed: existing
            )
        }

        let oldPlugins = installedPlugins
        let packageDirectoryName = Self.safePackageDirectoryName(
            manifest: prepared.effectiveManifest,
            archiveHash: prepared.archiveSHA256
        )
        let publishedPayload = packageRoot.appendingPathComponent(packageDirectoryName, isDirectory: true)
        guard isDescendant(publishedPayload, of: packageRoot),
              !fileManager.fileExists(atPath: publishedPayload.path) else {
            throw SkyStreamPluginManagerError.invalidPersistedPath
        }
        try fileManager.moveItem(at: prepared.stagedPayloadURL, to: publishedPayload)
        var publicationCommitted = false
        var newlyPublishedArchive: URL?
        defer {
            if !publicationCommitted {
                try? removeManagedItem(url: publishedPayload)
                if let newlyPublishedArchive {
                    try? removeManagedItem(url: newlyPublishedArchive)
                }
            }
        }
        try setProtectedAttributesRecursively(at: publishedPayload)

        let publishedArchive = archiveURL(
            packageName: prepared.validatedManifest.packageName,
            archiveHash: prepared.archiveSHA256
        )
        let archiveAlreadyExisted = fileManager.fileExists(atPath: publishedArchive.path)
        if try ensureManagedArchive(
            prepared.archiveData,
            packageName: prepared.validatedManifest.packageName,
            archiveSHA256: prepared.archiveSHA256
        ) {
            newlyPublishedArchive = publishedArchive
        }

        let reconciled = Self.reconciledProviderStates(
            manifest: prepared.effectiveManifest,
            previous: existing?.providers ?? []
        )
        let relativePath = relativeManagedPath(for: publishedPayload)
        let installed = SkyStreamInstalledPluginState(
            manifest: prepared.effectiveManifest,
            archiveSHA256: prepared.archiveSHA256,
            scriptSHA256: prepared.scriptSHA256,
            payloadRelativePath: relativePath,
            provenance: prepared.provenance,
            selectedDomainURL: Self.reconciledDomain(
                previous: existing?.selectedDomainURL,
                manifest: prepared.effectiveManifest
            ),
            compatibility: prepared.compatibility,
            providers: reconciled.states,
            usesDynamicProviders: prepared.usesDynamicProviders,
            runtimeStorage: crossesProvenanceTrustDomain ? nil : existing?.runtimeStorage,
            preferences: crossesProvenanceTrustDomain
                ? (existing?.preferences.filter {
                    !$0.value.isSecret && !$0.value.isRedacted
                } ?? [:])
                : (existing?.preferences ?? [:]),
            installedAt: existing?.installedAt ?? Date(),
            updatedAt: Date(),
            additionalFields: existing?.additionalFields ?? [:]
        )

        let publishedScript = publishedPayload.appendingPathComponent("plugin.js", isDirectory: false)
        let publishedScriptValues = try? publishedScript.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard publishedScriptValues?.isRegularFile == true,
              publishedScriptValues?.isSymbolicLink != true,
              (publishedScriptValues?.fileSize ?? 10 * 1_024 * 1_024 + 1)
                <= 10 * 1_024 * 1_024,
              let finalData = try? Data(contentsOf: publishedScript, options: [.mappedIfSafe]),
              Self.sha256Hex(finalData) == installed.scriptSHA256.lowercased() else {
            try? removeManagedItem(url: publishedPayload)
            if !archiveAlreadyExisted { try? removeManagedItem(url: publishedArchive) }
            throw SkyStreamPluginManagerError.integrityFailure
        }

        if let index = installedPlugins.firstIndex(where: { $0.id == installed.id }) {
            installedPlugins[index] = installed
        } else {
            installedPlugins.append(installed)
        }

        let resetsTrustScopedState = existing == nil || crossesProvenanceTrustDomain
        do {
            try await persist(
                runtimeResetPackageIDs: [installed.id],
                expectedScopeGeneration: prepared.scopeAuthority.serviceStoreGeneration
            ) {
                await SkyStreamRuntimePool.shared.invalidatePackage(
                    installed.id,
                    resetCookies: resetsTrustScopedState,
                    resetDataStore: resetsTrustScopedState
                )
            }
            publicationCommitted = true
        } catch {
            if prepared.scopeAuthority.isCurrent {
                installedPlugins = oldPlugins
            }
            try? removeManagedItem(url: publishedPayload)
            if !archiveAlreadyExisted { try? removeManagedItem(url: publishedArchive) }
            throw error
        }

        if let old = existing, old.payloadRelativePath != installed.payloadRelativePath {
            removeSharedManagedItem(relativePath: old.payloadRelativePath)
        }
        if let old = existing,
           old.archiveSHA256.caseInsensitiveCompare(installed.archiveSHA256) != .orderedSame {
            removeSharedManagedItem(url: archiveURL(for: old))
        }
        if let oldDomain = existing?.selectedDomainURL,
           installed.selectedDomainURL != oldDomain {
            lastNoticeMessage = "\(installed.manifest.name) no longer offers the selected mirror. Eclipse switched to the package default."
            log("selected domain disappeared; default restored", packageName: installed.id)
        }
        log("plugin installed", packageName: installed.id)
        return CommittedInstall(
            installed: installed
        )
    }

    private func loadPersistedState() async {

        let scopeEpoch = ServiceStoreScope.generation
        var quarantinedPackageIDs: [String] = []
        do {
            try prepareDirectories()
            removeStaleStagingItems()
            if let data = try await store.loadSkyStreamStateData() {
                guard ServiceStoreScope.isCurrent(scopeEpoch) else {
                    log("abandoned a persisted-state load, the services store moved")
                    return
                }
                let state = try decoder.decode(PersistedState.self, from: data)
                guard state.schemaVersion == 1,
                      state.repositories.count <= Self.maximumRepositoryCount,
                      state.installedPlugins.count <= Self.maximumInstalledPluginCount,
                      Set(state.repositories.map(\.sourceURL)).count == state.repositories.count,
                      state.repositories.allSatisfy({ Self.isSafeHTTPSURL($0.sourceURL) }) else {
                    throw SkyStreamPluginManagerError.persistenceFailed
                }
                let loadedRepositories = state.repositories
                var structurallyValidPlugins: [SkyStreamInstalledPluginState] = []
                var seenPackageIDs = Set<String>()
                for var plugin in state.installedPlugins {
                    guard SkyStreamStableID.isValidPackageName(plugin.manifest.packageName),
                          !seenPackageIDs.contains(plugin.id),
                          (plugin.manifest.providers?.count ?? 0) <= 64,
                          (plugin.manifest.domains?.count ?? 0) <= 64,
                          plugin.providers.count <= 256 else {
                        log("persisted plugin quarantined by structural check", packageName: plugin.id)
                        quarantinedPackageIDs.append(plugin.id)
                        continue
                    }

                    if plugin.compatibility.status == .compatible {
                        plugin.compatibility = .untested
                    }
                    seenPackageIDs.insert(plugin.id)
                    structurallyValidPlugins.append(plugin)
                }

                let skyStreamRoot = self.skyStreamRoot
                let packageRoot = self.packageRoot
                let integrityResults = await Task.detached(priority: .utility) {
                    structurallyValidPlugins.map { plugin in
                        (
                            plugin,
                            Self.persistedScriptIntegrityIsValid(
                                plugin,
                                skyStreamRoot: skyStreamRoot,
                                packageRoot: packageRoot
                            )
                        )
                    }
                }.value
                for (plugin, isValid) in integrityResults where !isValid {
                    log("persisted plugin quarantined by integrity check", packageName: plugin.id)
                    quarantinedPackageIDs.append(plugin.id)
                }

                guard ServiceStoreScope.isCurrent(scopeEpoch) else {
                    log("abandoned a persisted-state load, the services store moved")
                    return
                }
                repositories = loadedRepositories
                installedPlugins = integrityResults.filter { $0.1 }.map(\.0)
            } else {
                guard ServiceStoreScope.isCurrent(scopeEpoch) else {
                    log("abandoned a persisted-state load, the services store moved")
                    return
                }

                repositories = []
                installedPlugins = []
            }
            committedRepositories = repositories
            committedInstalledPlugins = installedPlugins
            committedPluginsByID = committedInstalledPlugins.reduce(into: [:]) {
                if $0[$1.id] == nil { $0[$1.id] = $1 }
            }
            runtimeAuthorityRevisions = committedInstalledPlugins.reduce(into: [:]) {
                if $0[$1.id] == nil { $0[$1.id] = UUID() }
            }
            for packageName in runtimeAuthorityRevisions.keys.sorted() {
                guard let revision = runtimeAuthorityRevisions[packageName] else { continue }
                await SkyStreamRuntimePool.shared.invalidatePackage(
                    packageName,
                    acceptingRevision: revision
                )
            }

            guard ServiceStoreScope.isCurrent(scopeEpoch) else {
                log("abandoned a persisted-state load, the services store moved")
                return
            }
            unreadablePackageIDs = quarantinedPackageIDs.sorted()
            if unreadablePackageIDs.isEmpty {
                reconcileSkySourceDefaults()
                removeUnreferencedManagedArtifacts()
            }
            lastErrorMessage = nil
            stateLoadDidFail = false
            isLoaded = true
            await restorePendingSafeCloudSnapshotIfNeeded(scopeEpoch: scopeEpoch)
            guard ServiceStoreScope.isCurrent(scopeEpoch) else {
                log("abandoned a pending cloud restore, the services store moved")
                return
            }
            NotificationCenter.default.post(name: .skyStreamMetadataDidChange, object: self)
        } catch {

            guard ServiceStoreScope.isCurrent(scopeEpoch) else {
                log("abandoned a persisted-state load, the services store moved", error: error)
                return
            }
            lastErrorMessage = error.localizedDescription
            repositories = []
            installedPlugins = []
            committedRepositories = []
            committedInstalledPlugins = []
            committedPluginsByID = [:]
            runtimeAuthorityRevisions = [:]
            unreadablePackageIDs = []
            stateLoadDidFail = true
            isLoaded = false
            NotificationCenter.default.post(name: .skyStreamMetadataDidChange, object: self)
            log("state load failed closed", error: error)
        }
    }

    public func reloadPersistedStateAfterRestore() async {
        await loadPersistedState()
    }

    public func retryLoadingPersistedState() async {
        await loadPersistedState()
    }

    public func resetPluginData() async throws {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            throw SkyStreamPluginManagerError.unavailable
        }
        guard canAdministerPlugins else {
            throw SkyStreamPluginManagerError.requiresGrownUpProfile
        }
        let resetPackageIDs = Set(committedInstalledPlugins.map(\.id))
            .union(unreadablePackageIDs)
        try await withMutationGate {
            repositories = []
            installedPlugins = []
            try await persist(runtimeResetPackageIDs: resetPackageIDs) {
                for packageName in resetPackageIDs.sorted() {
                    await SkyStreamRuntimePool.shared.invalidatePackage(
                        packageName,
                        resetCookies: true,
                        resetDataStore: true
                    )
                }
            }
            unreadablePackageIDs = []
            lastNoticeMessage = nil
            lastErrorMessage = nil
            stateLoadDidFail = false
            isLoaded = true
            removeUnreferencedManagedArtifacts()
            SourceHealthStore.shared.removeRecords { sourceID in
                sourceID.hasPrefix(SkyStreamStableID.prefix)
            }
            log("plugin data reset")
        }
    }

    private var notLoadedError: SkyStreamPluginManagerError {
        stateLoadDidFail ? .stateLoadFailed : .managerNotLoaded
    }

    private func restorePendingSafeCloudSnapshotIfNeeded(scopeEpoch: Int) async {
        let store = ProfileSettingsStore.services
        guard let data = store.data(forKey: Self.pendingSafeCloudSnapshotKey),
              data.count <= 50_000_000 else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(SkyStreamBackupSnapshot.self, from: data),
              snapshot.isSafeCloudSnapshot else {
            store.removeObject(forKey: Self.pendingSafeCloudSnapshotKey)
            log("discarded an invalid pending safe-cloud snapshot")
            return
        }
        do {
            let result = try await restoreSafeCloudSnapshot(snapshot)
            guard ServiceStoreScope.isCurrent(scopeEpoch) else { return }
            if result.isComplete {
                store.removeObject(forKey: Self.pendingSafeCloudSnapshotKey)
                log("applied the active profile's pending safe-cloud snapshot")
            } else {
                log(
                    "kept a partially reconstructed pending safe-cloud snapshot unresolved=\(result.unresolvedPackageIDs.count)"
                )
            }
        } catch {
            guard ServiceStoreScope.isCurrent(scopeEpoch) else { return }
            log("pending safe-cloud reconstruction deferred", error: error)
        }
    }

    nonisolated private static func persistedScriptIntegrityIsValid(
        _ plugin: SkyStreamInstalledPluginState,
        skyStreamRoot: URL,
        packageRoot: URL
    ) -> Bool {
        let relativePath = plugin.payloadRelativePath
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.split(separator: "/").contains("..") else {
            return false
        }
        let normalizedSkyRoot = skyStreamRoot.standardizedFileURL
        let normalizedPackageRoot = packageRoot.standardizedFileURL
        let payloadURL = normalizedSkyRoot
            .appendingPathComponent(relativePath, isDirectory: true)
            .standardizedFileURL
        guard payloadURL.path.hasPrefix(normalizedPackageRoot.path + "/") else { return false }

        let scriptURL = payloadURL.appendingPathComponent("plugin.js", isDirectory: false)
        guard let values = try? scriptURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 10 * 1_024 * 1_024 + 1) <= 10 * 1_024 * 1_024,
              let data = try? Data(contentsOf: scriptURL, options: [.mappedIfSafe]),
              data.count <= 10 * 1_024 * 1_024 else {
            return false
        }
        return sha256Hex(data) == plugin.scriptSHA256.lowercased()
    }

    private func persist(
        runtimeResetPackageIDs: Set<String> = [],
        expectedScopeGeneration: Int? = nil,
        beforePublishing: (() async -> Void)? = nil
    ) async throws {

        let scopeEpoch = expectedScopeGeneration ?? ServiceStoreScope.generation
        guard ServiceStoreScope.isCurrent(scopeEpoch) else {
            throw SkyStreamPluginManagerError.stateChangedDuringValidation
        }
        let state = PersistedState(
            repositories: repositories,
            installedPlugins: installedPlugins
        )
        let newlyBlockedPackageIDs = runtimeResetPackageIDs.subtracting(
            runtimePublicationBlockedPackageIDs
        )
        updateRuntimePublicationFence(adding: newlyBlockedPackageIDs)
        var publicationFinished = false
        defer {
            if !publicationFinished {
                updateRuntimePublicationFence(removing: newlyBlockedPackageIDs)
            }
        }

        repositories = committedRepositories
        installedPlugins = committedInstalledPlugins
        let data: Data
        do {
            data = try await Task.detached(priority: .utility) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return try encoder.encode(state)
            }.value
        } catch {
            lastErrorMessage = error.localizedDescription
            throw SkyStreamPluginManagerError.persistenceFailed
        }
        guard data.count <= Self.maximumPersistedStateBytes else {
            let budgetError = SkyStreamPluginManagerError.persistedStateBudgetExceeded(
                maximumBytes: Self.maximumPersistedStateBytes
            )
            lastErrorMessage = budgetError.localizedDescription
            log("persist refused, the saved state exceeds its storage budget")
            throw budgetError
        }
        do {
            guard ServiceStoreScope.isCurrent(scopeEpoch) else {
                log("abandoned a persist, the services store moved")
                throw SkyStreamPluginManagerError.persistenceFailed
            }
            try await store.saveSkyStreamStateData(data, expectedScopeGeneration: scopeEpoch)
            for packageName in runtimeResetPackageIDs.sorted() {
                let revision = UUID()
                runtimeAuthorityRevisions[packageName] = revision
                await SkyStreamRuntimePool.shared.invalidatePackage(
                    packageName,
                    acceptingRevision: revision
                )
                SkyStreamResolver.shared.invalidateCachesForPackage(packageName)
            }
            if let beforePublishing {
                await beforePublishing()
            }

            guard ServiceStoreScope.isCurrent(scopeEpoch) else {
                log("abandoned a persist, the services store moved")
                throw SkyStreamPluginManagerError.persistenceFailed
            }
            committedRepositories = state.repositories
            committedInstalledPlugins = state.installedPlugins
            committedPluginsByID = state.installedPlugins.reduce(into: [:]) {
                if $0[$1.id] == nil { $0[$1.id] = $1 }
            }
            repositories = state.repositories
            installedPlugins = state.installedPlugins
            reconcileSkySourceDefaults()
            updateRuntimePublicationFence(removing: newlyBlockedPackageIDs)
            publicationFinished = true
            invalidateConcurrentSafeRestores(
                afterPersistFrom: SkyStreamSafeRestoreTaskContext.token
            )
            NotificationCenter.default.post(name: .skyStreamMetadataDidChange, object: self)
        } catch {
            lastErrorMessage = error.localizedDescription
            throw SkyStreamPluginManagerError.persistenceFailed
        }
    }

    private func prepareDirectories() throws {
        for directory in [skyStreamRoot, packageRoot, archiveRoot, stagingRoot] {
            guard isDescendantOrEqual(directory, of: skyStreamRoot) else {
                throw SkyStreamPluginManagerError.invalidPersistedPath
            }
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        }
    }

    private func removeStaleStagingItems() {
        guard let items = try? fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for item in items where isDescendant(item, of: stagingRoot) {
            try? removeManagedItem(url: item)
        }
    }

    private func removeUnreferencedManagedArtifacts() {

        guard canDeleteSharedPluginPayloads else {
            log("startup artifact pruning skipped: services are not shared, so this profile cannot see what others reference")
            return
        }
        let retainedPayloadPaths = Set(installedPlugins.compactMap {
            try? managedURL(relativePath: $0.payloadRelativePath).standardizedFileURL.path
        })
        if let payloads = try? fileManager.contentsOfDirectory(
            at: packageRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for payload in payloads
            where isDescendant(payload, of: packageRoot)
                && !retainedPayloadPaths.contains(payload.standardizedFileURL.path) {
                try? removeManagedItem(url: payload)
            }
        }

        let retainedArchivePaths = Set(installedPlugins.map {
            archiveURL(for: $0).standardizedFileURL.path
        })
        guard let packageArchiveDirectories = try? fileManager.contentsOfDirectory(
            at: archiveRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for packageDirectory in packageArchiveDirectories where isDescendant(packageDirectory, of: archiveRoot) {
            let values = try? packageDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else {
                try? removeManagedItem(url: packageDirectory)
                continue
            }
            let archiveItems = (try? fileManager.contentsOfDirectory(
                at: packageDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            for archive in archiveItems
            where isDescendant(archive, of: archiveRoot)
                && !retainedArchivePaths.contains(archive.standardizedFileURL.path) {
                try? removeManagedItem(url: archive)
            }
            if ((try? fileManager.contentsOfDirectory(atPath: packageDirectory.path)) ?? []).isEmpty {
                try? removeManagedItem(url: packageDirectory)
            }
        }
    }

    private func managedURL(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.split(separator: "/").contains("..") else {
            throw SkyStreamPluginManagerError.invalidPersistedPath
        }
        let url = skyStreamRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard isDescendant(url, of: packageRoot) else {
            throw SkyStreamPluginManagerError.invalidPersistedPath
        }
        return url
    }

    private func relativeManagedPath(for url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(skyStreamRoot.path.count + 1))
    }

    private func removeSharedManagedItem(relativePath: String) {
        guard canDeleteSharedPluginPayloads else {
            log("shared payload retained: another profile may still reference it", packageName: relativePath)
            return
        }
        try? removeManagedItem(relativePath: relativePath)
    }

    private func removeSharedManagedItem(url: URL) {
        guard canDeleteSharedPluginPayloads else {
            log("shared artifact retained: another profile may still reference it", packageName: url.lastPathComponent)
            return
        }
        try? removeManagedItem(url: url)
    }

    private func removeManagedItem(relativePath: String) throws {
        try removeManagedItem(url: try managedURL(relativePath: relativePath))
    }

    private func removeManagedItem(url: URL) throws {
        let standardized = url.standardizedFileURL
        guard isDescendant(standardized, of: skyStreamRoot) else {
            throw SkyStreamPluginManagerError.invalidPersistedPath
        }
        if fileManager.fileExists(atPath: standardized.path) {
            try fileManager.removeItem(at: standardized)
        }
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(rootPath)
    }

    private func isDescendantOrEqual(_ url: URL, of root: URL) -> Bool {
        url.standardizedFileURL == root.standardizedFileURL || isDescendant(url, of: root)
    }

    private func archiveURL(for plugin: SkyStreamInstalledPluginState) -> URL {
        archiveURL(packageName: plugin.id, archiveHash: plugin.archiveSHA256)
    }

    private func archiveURL(packageName: String, archiveHash: String) -> URL {
        archiveRoot
            .appendingPathComponent(packageName, isDirectory: true)
            .appendingPathComponent("\(archiveHash.lowercased()).sky", isDirectory: false)
    }

    @discardableResult
    private func ensureManagedArchive(
        _ data: Data,
        packageName: String,
        archiveSHA256: String
    ) throws -> Bool {
        let normalizedHash = archiveSHA256.lowercased()
        guard data.count <= Self.maximumPackageArchiveBytes,
              SkyStreamStableID.isValidPackageName(packageName),
              normalizedHash.count == 64,
              Self.sha256Hex(data).caseInsensitiveCompare(normalizedHash) == .orderedSame else {
            throw SkyStreamPluginManagerError.integrityFailure
        }
        let url = archiveURL(packageName: packageName, archiveHash: normalizedHash)
        guard isDescendant(url, of: archiveRoot) else {
            throw SkyStreamPluginManagerError.invalidPersistedPath
        }
        let existed = fileManager.fileExists(atPath: url.path)
        if existed,
           let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
           values.isRegularFile == true,
           (values.fileSize ?? Self.maximumPackageArchiveBytes + 1) <= Self.maximumPackageArchiveBytes,
           let current = try? Data(contentsOf: url, options: [.mappedIfSafe]),
           current.count <= Self.maximumPackageArchiveBytes,
           Self.sha256Hex(current).caseInsensitiveCompare(normalizedHash) == .orderedSame {
            return false
        }

        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        guard let repaired = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              repaired.count <= Self.maximumPackageArchiveBytes,
              Self.sha256Hex(repaired).caseInsensitiveCompare(normalizedHash) == .orderedSame else {
            throw SkyStreamPluginManagerError.integrityFailure
        }
        return !existed
    }

    private func setProtectedAttributesRecursively(at root: URL) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: root.path
        )
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw SkyStreamPackageValidationError.symbolicLinkNotAllowed(item.lastPathComponent)
            }
            let permissions: Int16 = values.isDirectory == true ? 0o700 : 0o600
            try fileManager.setAttributes(
                [
                    .posixPermissions: NSNumber(value: permissions),
                    .protectionKey: FileProtectionType.completeUnlessOpen
                ],
                ofItemAtPath: item.path
            )
        }
    }

    private func log(
        _ event: String,
        packageName: String? = nil,
        url: String? = nil,
        error: Error? = nil
    ) {
        var details: [String] = ["SkyStream:", event]
        if let packageName { details.append("package=\(packageName)") }
        if let url { details.append("origin=\(SkyStreamRemoteURLPolicy.redactedDescription(of: url))") }
        if let error { details.append("error=\(String(describing: type(of: error)))") }
        Logger.shared.log(details.joined(separator: " "), type: "SkyStream")
    }

    private static func currentProviderPairs(
        for manifest: SkyStreamPluginManifest
    ) -> [(provider: SkyStreamPluginProvider?, sourceID: String)] {
        guard let providers = manifest.providers, !providers.isEmpty else {
            return [(nil, SkyStreamStableID.rootProvider(packageName: manifest.packageName))]
        }
        return providers.map {
            ($0, SkyStreamStableID.provider(packageName: manifest.packageName, providerID: $0.id))
        }
    }

    private func validatedDynamicProviders(
        _ providers: [SkyStreamPluginProvider]
    ) async throws -> [SkyStreamPluginProvider] {
        guard !providers.isEmpty, providers.count <= 64 else {
            throw SkyStreamPluginManagerError.packageIncompatible(
                "The dynamic provider list is empty or exceeds Eclipse's provider limit."
            )
        }
        var result: [SkyStreamPluginProvider] = []
        var seen = Set<String>()
        for var provider in providers {
            guard SkyStreamStableID.isValidProviderID(provider.id),
                  seen.insert(provider.id).inserted,
                  !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  provider.name.utf8.count <= 256 else {
                throw SkyStreamPluginManagerError.packageIncompatible(
                    "The package returned an invalid or duplicate dynamic provider."
                )
            }
            if let baseURL = provider.baseURL {
                _ = try SkyStreamRemoteURLPolicy.shared.validateSyntactic(
                    baseURL,
                    purpose: .pluginRequest
                )
            }
            if let iconURL = provider.iconURL,
               (try? SkyStreamRemoteURLPolicy.shared.validateSyntactic(iconURL, purpose: .icon)) == nil {
                provider.iconURL = nil
            }
            result.append(provider)
        }
        return result
    }

    private static func reconciledProviderStates(
        manifest: SkyStreamPluginManifest,
        previous: [SkyStreamProviderState]
    ) -> (states: [SkyStreamProviderState], newSourceIDs: [String], removedSourceIDs: [String]) {
        let current = currentProviderPairs(for: manifest)
        let currentIDs = Set(current.map(\.sourceID))
        var statesByID = previous.reduce(into: [String: SkyStreamProviderState]()) {
            if $0[$1.id] == nil { $0[$1.id] = $1 }
        }
        var newIDs: [String] = []
        for pair in current {
            if var state = statesByID[pair.sourceID] {
                let wasRemoved = state.removedAt != nil
                state.providerID = pair.provider?.id
                state.lastSeenPluginVersion = manifest.version
                state.removedAt = nil
                if wasRemoved {

                    state.isAutoModeSelected = false
                    state.isExplicitlySelectedForExtraRules = nil
                    newIDs.append(pair.sourceID)
                }
                statesByID[pair.sourceID] = state
            } else {
                let state = SkyStreamProviderState(
                    packageName: manifest.packageName,
                    providerID: pair.provider?.id,
                    isEnabled: true,
                    isAutoModeSelected: false,
                    lastSeenPluginVersion: manifest.version
                )
                statesByID[pair.sourceID] = state
                newIDs.append(pair.sourceID)
            }
        }

        let removedIDs = previous
            .filter { $0.removedAt == nil && !currentIDs.contains($0.id) }
            .map(\.id)
        for sourceID in removedIDs {
            guard var state = statesByID[sourceID] else { continue }
            state.removedAt = Date()
            state.lastSeenPluginVersion = manifest.version
            statesByID[sourceID] = state
        }
        let activeOrder = current.compactMap { statesByID[$0.sourceID] }
        let tombstoneCapacity = max(0, Self.maximumProviderStateCount - activeOrder.count)
        let tombstones = statesByID.values
            .filter { !currentIDs.contains($0.id) }
            .sorted {
                let lhsDate = $0.removedAt ?? .distantPast
                let rhsDate = $1.removedAt ?? .distantPast
                return lhsDate == rhsDate ? $0.id < $1.id : lhsDate > rhsDate
            }
            .prefix(tombstoneCapacity)
        return (activeOrder + Array(tombstones), newIDs, removedIDs)
    }

    private static func reconciledDomain(
        previous: String?,
        manifest: SkyStreamPluginManifest
    ) -> String? {
        let domains = manifest.domains ?? []
        if let previous, domains.contains(where: { $0.url == previous }) {
            return previous
        }
        return domains.first(where: { $0.url == manifest.baseURL })?.url ?? domains.first?.url
    }

    private static func staticCompatibility(
        for manifest: SkyStreamPluginManifest,
        script: String
    ) -> SkyStreamCompatibilityResult {
        let bounded = String(script.prefix(10 * 1_024 * 1_024))
        let lowercased = bounded.lowercased()
        if lowercased.contains("solvecaptcha") || lowercased.contains("solve_captcha") {
            return SkyStreamCompatibilityResult(
                status: .incompatible,
                reasons: [
                    SkyStreamCompatibilityReason(
                        code: .genericCaptchaRequired,
                        message: "This plugin requires unsupported generic CAPTCHA solving."
                    )
                ],
                evaluatedAt: Date()
            )
        }
        var limitedReasons: [SkyStreamCompatibilityReason] = []
        if usesDynamicCodeEvaluation(in: bounded) {
            limitedReasons.append(
                SkyStreamCompatibilityReason(
                    code: .unsupportedRuntimeFeature,
                    message: "This package evaluates JavaScript at runtime. Eclipse blocks that, so some streams may not resolve."
                )
            )
        }
        if manifest.categories.contains(where: { $0.lowercased().contains("live") }) {
            limitedReasons.append(
                SkyStreamCompatibilityReason(
                    code: .liveOnly,
                    message: "Live output is filtered; only verified VOD streams can be used."
                )
            )
        }
        guard limitedReasons.isEmpty else {
            return SkyStreamCompatibilityResult(
                status: .limited,
                reasons: limitedReasons,
                evaluatedAt: Date()
            )
        }
        return SkyStreamCompatibilityResult(
            status: .untested,
            reasons: SkyStreamCompatibilityResult.untested.reasons,
            evaluatedAt: Date()
        )
    }

    private static func usesDynamicCodeEvaluation(in script: String) -> Bool {
        let scanned = executableCode(in: script)
        let patterns = [
            "\\beval\\s*\\(",
            "\\bnew\\s+Function\\b",
            "\\bFunction\\s*\\("
        ]
        return patterns.contains {
            scanned.range(of: $0, options: [.regularExpression]) != nil
        }
    }

    private static func executableCode(in input: String) -> String {
        enum ScanState {
            case code
            case single
            case double
            case template
            case lineComment
            case blockComment
        }

        var state = ScanState.code
        var escaped = false
        var output = String()
        output.reserveCapacity(input.count)
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            let next = input.index(after: index)
            let following = next < input.endIndex ? input[next] : nil
            switch state {
            case .code:
                if character == "/", following == "/" {
                    state = .lineComment
                    output.append("  ")
                    index = input.index(after: next)
                    continue
                }
                if character == "/", following == "*" {
                    state = .blockComment
                    output.append("  ")
                    index = input.index(after: next)
                    continue
                }
                if character == "'" {
                    state = .single
                    escaped = false
                    output.append(" ")
                } else if character == "\"" {
                    state = .double
                    escaped = false
                    output.append(" ")
                } else if character == "`" {
                    state = .template
                    escaped = false
                    output.append(" ")
                } else {
                    output.append(character)
                }
            case .single, .double, .template:
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if (state == .single && character == "'")
                            || (state == .double && character == "\"")
                            || (state == .template && character == "`") {
                    state = .code
                }
                output.append(character == "\n" ? "\n" : " ")
            case .lineComment:
                if character == "\n" {
                    state = .code
                    output.append("\n")
                } else {
                    output.append(" ")
                }
            case .blockComment:
                if character == "*", following == "/" {
                    state = .code
                    output.append("  ")
                    index = input.index(after: next)
                    continue
                }
                output.append(character == "\n" ? "\n" : " ")
            }
            index = next
        }
        return output
    }

    private static func validateReplacement(
        existing: SkyStreamInstalledPluginState?,
        proposedManifest: SkyStreamPluginManifest,
        proposedArchiveHash: String,
        provenance: SkyStreamInstallProvenance,
        policy: SkyStreamReplacementPolicy
    ) throws {
        guard let existing else { return }
        let confirmed = policy == .userConfirmedReplacement
        if provenanceIdentity(existing.provenance) != provenanceIdentity(provenance), !confirmed {
            throw SkyStreamPluginManagerError.provenanceTakeoverRequiresConfirmation
        }
        if proposedManifest.version < existing.manifest.version, !confirmed {
            throw SkyStreamPluginManagerError.downgradeRequiresConfirmation(
                installed: existing.manifest.version,
                proposed: proposedManifest.version
            )
        }
        if proposedManifest.version == existing.manifest.version,
           proposedArchiveHash.caseInsensitiveCompare(existing.archiveSHA256) != .orderedSame,
           !confirmed {
            throw SkyStreamPluginManagerError.sameVersionCodeReplacementRequiresConfirmation
        }
    }

    private func repositoryInstallAuthorityIsCurrent(
        _ authority: RepositoryInstallAuthority
    ) -> Bool {
        guard let current = repositories.first(where: {
            $0.sourceURL == authority.repository.sourceURL
        }) else { return false }
        return current.kind == authority.repository.kind
            && current.repositoryPackageName == authority.repository.repositoryPackageName
            && current.pluginListURLs == authority.repository.pluginListURLs
            && current.frozenAt == authority.repository.frozenAt
            && current.plugins.first(where: {
                $0.manifest.packageName == authority.entry.manifest.packageName
            }) == authority.entry
    }

    private static func provenanceIdentity(_ provenance: SkyStreamInstallProvenance) -> String {
        provenance.repositoryURL ?? provenance.sourceURL
    }

    nonisolated private static func provenanceBehaviorIdentity(
        _ provenance: SkyStreamInstallProvenance
    ) -> String {
        [
            provenance.kind.rawValue,
            provenance.repositoryURL ?? provenance.sourceURL,
            provenance.sourceURL,
            provenance.pluginListURL ?? "",
            provenance.repositoryPackageName ?? ""
        ].joined(separator: "\u{1f}")
    }

    private static func safePackageDirectoryName(
        manifest: SkyStreamPluginManifest,
        archiveHash: String
    ) -> String {
        let hash = String(archiveHash.lowercased().prefix(16))
        return "\(manifest.packageName)-v\(manifest.version)-\(hash)-\(UUID().uuidString.prefix(8))"
    }

    nonisolated private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.count == 64 && normalized.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private static func privateCloudPluginConfigurationIsCapturable(
        _ plugin: SkyStreamInstalledPluginState
    ) -> Bool {
        var boundedState = plugin
        boundedState.runtimeStorage = nil
        return SkyStreamBackupMetadataPolicy.isBounded(pluginState: boundedState)
            && SkyStreamPrivateCloudConfigurationPolicy.preferencesAreCompleteAndBounded(
                plugin.preferences
            )
            && isSafeHTTPSURL(plugin.provenance.sourceURL)
            && (plugin.provenance.repositoryURL.map(isSafeHTTPSURL) ?? true)
            && (plugin.provenance.pluginListURL.map(isSafeHTTPSURL) ?? true)
            && (plugin.selectedDomainURL.map(isSafeHTTPSURL) ?? true)
            && (plugin.selectedDomainURL.map { selected in
                plugin.manifest.domains?.contains(where: { $0.url == selected }) == true
            } ?? true)
            && (plugin.manifest.baseURL.isEmpty
                || isSafeHTTPSURL(plugin.manifest.baseURL))
            && (plugin.manifest.iconURL.map(isSafeHTTPSURL) ?? true)
            && (plugin.manifest.domains?.allSatisfy {
                isSafeHTTPSURL($0.url)
            } ?? true)
            && (plugin.manifest.providers?.allSatisfy {
                ($0.baseURL.map(isSafeHTTPSURL) ?? true)
                    && ($0.iconURL.map(isSafeHTTPSURL) ?? true)
            } ?? true)
    }

    private static func privateCloudRepositoryConfigurationIsCapturable(
        _ repository: SkyStreamRepositoryBackupSnapshot
    ) -> Bool {
        guard isSafeHTTPSURL(repository.sourceURL),
              !repository.pluginListURLs.isEmpty,
              repository.pluginListURLs.allSatisfy(isSafeHTTPSURL) else { return false }
        switch repository.kind {
        case .repository:
            guard let manifest = repository.manifest,
                  manifest.pluginLists == repository.pluginListURLs,
                  manifest.iconURL.map(isSafeHTTPSURL) ?? true,
                  manifest.websiteURL.map(isSafeHTTPSURL) ?? true else { return false }
        case .pluginList:
            guard repository.manifest == nil else { return false }
        }
        return true
    }

    private static func containsCloudUnsafeSecretMarker(_ value: String) -> Bool {
        let lowercase = value.lowercased()
        return [
            "access_token", "refresh_token", "authorization", "api_key", "apikey",
            "password", "passwd", "session", "secret", "token"
        ].contains { lowercase.contains($0) }
    }

    private static func backupRepository(
        _ repository: SkyStreamSavedRepository
    ) -> SkyStreamRepositoryBackupSnapshot? {
        guard isSafeHTTPSURL(repository.sourceURL),
              repository.pluginListURLs.count <= 32,
              repository.pluginListURLs.allSatisfy(isSafeHTTPSURL) else { return nil }
        switch repository.kind {
        case .repository:
            guard let manifestVersion = repository.manifest?.manifestVersion,
                  SkyStreamRepositoryManifest.isSupportedManifestVersion(
                      manifestVersion
                  ) else { return nil }
        case .pluginList:
            guard repository.manifest == nil, !repository.pluginListURLs.isEmpty else { return nil }
        }
        let snapshot = SkyStreamRepositoryBackupSnapshot(
            sourceURL: repository.sourceURL,
            kind: repository.kind,
            name: repository.name,
            manifest: repository.manifest,
            pluginListURLs: repository.pluginListURLs,
            lastRefreshedAt: repository.lastRefreshedAt,
            frozenAt: repository.frozenAt
        )
        guard SkyStreamBackupMetadataPolicy.isBounded(repository: snapshot) else { return nil }
        return snapshot
    }

    private static func isSafeHTTPSURL(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.host?.isEmpty == false else { return false }
        return true
    }

    private static func isCloudSafeHTTPSURL(_ rawValue: String) -> Bool {
        guard isSafeHTTPSURL(rawValue),
              let components = URLComponents(string: rawValue),
              components.queryItems?.isEmpty != false,
              components.fragment == nil else { return false }
        return true
    }

    static func acceptsSafeCloudConfigurationURL(
        _ rawValue: String,
        configurationIsComplete: Bool
    ) -> Bool {
        configurationIsComplete
            ? isSafeHTTPSURL(rawValue)
            : isCloudSafeHTTPSURL(rawValue)
    }

    static func safeCloudArchiveMayInstall(
        incoming: SkyStreamInstalledPluginState,
        over existing: SkyStreamInstalledPluginState?
    ) -> Bool {
        guard let existing else { return true }
        return safeCloudStateMatchesInstalledCodeAndProvenance(incoming, existing)
    }

    static func mergingSafeCloudRepositories(
        current: [SkyStreamSavedRepository],
        incoming: [SkyStreamSavedRepository]
    ) -> [SkyStreamSavedRepository] {
        let currentByURL = current.reduce(into: [String: SkyStreamSavedRepository]()) {
            if $0[$1.sourceURL] == nil { $0[$1.sourceURL] = $1 }
        }
        let incomingURLs = Set(incoming.map(\.sourceURL))
        let mergedIncoming = incoming.map { candidate in

            currentByURL[candidate.sourceURL] ?? candidate
        }
        return mergedIncoming + current.filter { !incomingURLs.contains($0.sourceURL) }
    }

    static func restoringCompletePrivateCloudRepositories(
        current: [SkyStreamSavedRepository],
        incoming: [SkyStreamSavedRepository],
        baseline: [String: SkyStreamSavedRepository]
    ) -> [SkyStreamSavedRepository] {
        let incomingURLs = Set(incoming.map(\.sourceURL))
        let concurrentLocal = current.filter { repository in
            guard !incomingURLs.contains(repository.sourceURL) else { return false }
            guard let original = baseline[repository.sourceURL] else { return true }
            return original != repository
        }
        return incoming + concurrentLocal
    }

    static func mergingSafeCloudPreferences(
        local: [String: SkyStreamPreferenceValue],
        incoming: [String: SkyStreamPreferenceValue]
    ) -> [String: SkyStreamPreferenceValue] {
        var merged = local
        let publicIncoming = incoming.filter { !$0.value.isSecret && !$0.value.isRedacted }
        let boundedIncoming = SkyStreamRuntimeDataStore(snapshot: .init(
            preferences: publicIncoming.mapValues(\.value)
        )).snapshot().preferences
        for key in boundedIncoming.keys.sorted() {
            guard let boundedValue = boundedIncoming[key] else { continue }

            if let existing = merged[key], existing.isSecret || existing.isRedacted { continue }
            guard let metadata = publicIncoming[key] else { continue }
            if let existing = merged[key],
               existing.value == boundedValue,
               !existing.isSecret,
               !existing.isRedacted {

                continue
            }
            var candidate = merged
            candidate[key] = SkyStreamPreferenceValue(
                value: boundedValue,
                isSecret: false,
                isRedacted: false,
                updatedAt: metadata.updatedAt
            )
            if SkyStreamBackupMetadataPolicy.preferencesAreBounded(candidate) {
                merged = candidate
            }
        }
        return merged
    }

    private static func safeCloudPreferenceBehaviorIsEqual(
        _ lhs: [String: SkyStreamPreferenceValue],
        _ rhs: [String: SkyStreamPreferenceValue]
    ) -> Bool {
        guard Set(lhs.keys) == Set(rhs.keys) else { return false }
        return lhs.allSatisfy { key, value in
            guard let other = rhs[key] else { return false }
            return value.value == other.value
                && value.isSecret == other.isSecret
                && value.isRedacted == other.isRedacted
        }
    }

    private func preflightSafeCloudSnapshot(
        _ snapshot: SkyStreamBackupSnapshot
    ) throws -> [SkyStreamSavedRepository] {
        let configurationIsComplete = snapshot.privateCloudConfigurationIsComplete == true
        if configurationIsComplete,
           !SkyStreamPrivateCloudConfigurationPolicy.snapshotHasCompleteConfiguration(snapshot) {
            throw SkyStreamPluginManagerError.invalidBackup
        }
        let acceptsURL: (String) -> Bool = {
            Self.acceptsSafeCloudConfigurationURL(
                $0,
                configurationIsComplete: configurationIsComplete
            )
        }
        guard snapshot.repositories.allSatisfy({ repository in
            SkyStreamBackupMetadataPolicy.isBounded(repository: repository)
                && repository.additionalFields.isEmpty
                && repository.manifest?.additionalFields.isEmpty != false
                && (repository.manifest.map {
                    $0.pluginLists == repository.pluginListURLs
                } ?? true)
                && (repository.manifest?.iconURL.map(acceptsURL) ?? true)
                && (repository.manifest?.websiteURL.map(acceptsURL) ?? true)
        }) else { throw SkyStreamPluginManagerError.invalidBackup }
        let restored = try restoredRepositories(from: snapshot.repositories)
        guard restored.allSatisfy({ repository in
            acceptsURL(repository.sourceURL)
                && repository.pluginListURLs.allSatisfy(acceptsURL)
        }) else { throw SkyStreamPluginManagerError.invalidBackup }

        var aggregateArchiveBytes = 0
        for plugin in snapshot.plugins {
            let state = plugin.state
            let preferencesAreValid = configurationIsComplete
                ? !plugin.preferencesWereRedacted
                    && SkyStreamPrivateCloudConfigurationPolicy
                        .preferencesAreCompleteAndBounded(state.preferences)
                : plugin.preferencesWereRedacted
                    && state.preferences.allSatisfy { key, value in
                        !value.isSecret && !value.isRedacted
                            && !Self.containsCloudUnsafeSecretMarker(key)
                    }
            guard SkyStreamBackupMetadataPolicy.isBounded(pluginState: state),
                  plugin.additionalFields.isEmpty,
                  state.payloadRelativePath.isEmpty,
                  state.runtimeStorage == nil,
                  state.additionalFields.isEmpty,
                  Self.isValidSHA256(state.archiveSHA256),
                  Self.isValidSHA256(state.scriptSHA256),
                  preferencesAreValid,
                  acceptsURL(state.provenance.sourceURL),
                  state.provenance.repositoryURL.map(acceptsURL) ?? true,
                  state.provenance.pluginListURL.map(acceptsURL) ?? true,
                  state.provenance.additionalFields.isEmpty,
                  state.selectedDomainURL.map(acceptsURL) ?? true,
                  state.manifest.additionalFields.isEmpty,
                  state.manifest.baseURL.isEmpty
                    || acceptsURL(state.manifest.baseURL),
                  state.manifest.iconURL.map(acceptsURL) ?? true,
                  state.manifest.domains?.allSatisfy({
                      $0.additionalFields.isEmpty && acceptsURL($0.url)
                  }) ?? true,
                  state.manifest.providers?.allSatisfy({
                      $0.additionalFields.isEmpty
                          && ($0.baseURL.map(acceptsURL) ?? true)
                          && ($0.iconURL.map(acceptsURL) ?? true)
                  }) ?? true,
                  state.providers.allSatisfy({ $0.additionalFields.isEmpty }),
                  state.compatibility.reasons.allSatisfy({ $0.additionalFields.isEmpty }) else {
                throw SkyStreamPluginManagerError.invalidBackup
            }
            if let selectedDomainURL = state.selectedDomainURL,
               state.manifest.domains?.contains(where: { $0.url == selectedDomainURL }) != true {
                throw SkyStreamPluginManagerError.invalidBackup
            }
            if let archive = plugin.archivePayload {
                let (nextBytes, overflow) = aggregateArchiveBytes.addingReportingOverflow(archive.count)
                guard !plugin.payloadWasRedacted,
                      archive.count <= Self.maximumPackageArchiveBytes,
                      !overflow,
                      nextBytes <= Self.maximumManualBackupArchiveBytes,
                      Self.sha256Hex(archive).caseInsensitiveCompare(state.archiveSHA256)
                        == .orderedSame else {
                    throw SkyStreamPluginManagerError.invalidBackup
                }
                aggregateArchiveBytes = nextBytes
            } else if !plugin.payloadWasRedacted {
                throw SkyStreamPluginManagerError.invalidBackup
            }
        }
        return restored
    }

    static func safeCloudStateMatchesInstalledCodeAndProvenance(
        _ incoming: SkyStreamInstalledPluginState,
        _ installed: SkyStreamInstalledPluginState
    ) -> Bool {
        incoming.id == installed.id
            && incoming.manifest.version == installed.manifest.version
            && incoming.archiveSHA256.caseInsensitiveCompare(installed.archiveSHA256) == .orderedSame
            && incoming.scriptSHA256.caseInsensitiveCompare(installed.scriptSHA256) == .orderedSame
            && incoming.provenance.kind == installed.provenance.kind
            && incoming.provenance.sourceURL == installed.provenance.sourceURL
            && incoming.provenance.repositoryURL == installed.provenance.repositoryURL
            && incoming.provenance.pluginListURL == installed.provenance.pluginListURL
            && incoming.provenance.repositoryPackageName == installed.provenance.repositoryPackageName
    }
}

#else

@MainActor
public final class SkyStreamPluginManager: ObservableObject {
    public static let shared = SkyStreamPluginManager()
    nonisolated static let pendingSafeCloudSnapshotKey = "skyStreamPendingSafeCloudSnapshot.v1"
    @Published public private(set) var repositories: [SkyStreamSavedRepository] = []
    @Published public private(set) var installedPlugins: [SkyStreamInstalledPluginState] = []
    @Published public private(set) var isLoaded = true
    public var providers: [SkyStreamProviderDescriptor] { [] }
    public init() {}

    static func safeCloudMetadataSnapshot(
        fromPersistedStateData data: Data
    ) -> SkyStreamBackupSnapshot? {
        nil
    }

    static func completePrivateCloudMetadataSnapshot(
        fromPersistedStateData data: Data
    ) -> SkyStreamBackupSnapshot? {
        nil
    }

    public func captureSourceDefaultsState(expectedScopeGeneration: Int? = nil) async {}

    public func reloadPersistedStateAfterRestore() async {}

    public func opaqueBackupSnapshotData() -> Data? {
        Self.boundedData(at: Self.manualOpaqueBackupURL, maximumBytes: 128 * 1_024 * 1_024)
            ?? Self.boundedData(at: Self.legacySharedOpaqueURL, maximumBytes: 128 * 1_024 * 1_024)
            ?? Self.boundedData(at: Self.cloudOpaqueBackupURL, maximumBytes: 50_000_000)
    }

    public func preserveOpaqueBackupSnapshotData(_ data: Data) throws {
        guard data.count <= 128 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(SkyStreamBackupSnapshot.self, from: data)
        let maximumBytes = snapshot.isSafeCloudSnapshot ? 50_000_000 : 128 * 1_024 * 1_024
        guard data.count <= maximumBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        guard let url = snapshot.isSafeCloudSnapshot
                ? Self.cloudOpaqueBackupURL
                : Self.manualOpaqueBackupURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try data.write(to: url, options: .atomic)
        for filename in SkyStreamOpaqueStorageLayout.filenamesInvalidatedAfterWrite(
            isSafeCloudSnapshot: snapshot.isSafeCloudSnapshot
        ) {
            let staleURL = url.deletingLastPathComponent().appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: staleURL.path) {
                try FileManager.default.removeItem(at: staleURL)
            }
        }
    }

    public func opaqueMediaStateSnapshotData() -> Data? {
        guard let data = Self.boundedData(
            at: Self.mediaStateOpaqueURL,
            maximumBytes: SkyStreamMediaStateDocument.maximumPayloadBytes
        ),
              (try? SkyStreamMediaStateDocument.decodeMetadataOnly(data)) != nil else {
            return nil
        }
        return data
    }

    public func preserveOpaqueMediaStateSnapshotData(_ data: Data) throws {
        let snapshot = try SkyStreamMediaStateDocument.decodeMetadataOnly(data)
        let canonical = try SkyStreamMediaStateDocument.encodeMetadataOnly(snapshot)
        guard let url = Self.mediaStateOpaqueURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try canonical.write(to: url, options: .atomic)
        NotificationCenter.default.post(name: .skyStreamMetadataDidChange, object: self)
    }

    public func clearOpaqueMediaStateSnapshotData() {
        guard let url = Self.mediaStateOpaqueURL else { return }
        try? FileManager.default.removeItem(at: url)
        NotificationCenter.default.post(name: .skyStreamMetadataDidChange, object: self)
    }

    private static var opaqueStorageRootURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Eclipse", isDirectory: true)
            .appendingPathComponent("SkyStream", isDirectory: true)
    }

    private static var manualOpaqueBackupURL: URL? {
        opaqueStorageRootURL?.appendingPathComponent(
            SkyStreamOpaqueStorageLayout.manualBackupFilename,
            isDirectory: false
        )
    }

    private static var mediaStateOpaqueURL: URL? {
        opaqueStorageRootURL?.appendingPathComponent(
            SkyStreamOpaqueStorageLayout.mediaStateFilename,
            isDirectory: false
        )
    }

    private static var cloudOpaqueBackupURL: URL? {
        opaqueStorageRootURL?.appendingPathComponent(
            SkyStreamOpaqueStorageLayout.experimentalCloudBackupFilename,
            isDirectory: false
        )
    }

    private static var legacySharedOpaqueURL: URL? {
        opaqueStorageRootURL?.appendingPathComponent(
            SkyStreamOpaqueStorageLayout.legacySharedFilename,
            isDirectory: false
        )
    }

    private static func boundedData(at url: URL?, maximumBytes: Int) -> Data? {
        guard let url,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= maximumBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= maximumBytes else { return nil }
        return data
    }
}

#endif
