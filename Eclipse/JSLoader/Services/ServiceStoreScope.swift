import CoreData
import Foundation

enum ServiceStoreScope {

    static let didChangeNotification = Notification.Name("eclipseServiceStoreScopeDidChange")

    private static let containerName = "ServiceModels"

    static var sharedStoreURL: URL {
        NSPersistentContainer.defaultDirectoryURL()
            .appendingPathComponent("\(containerName).sqlite")
    }

    static func storeURL(for profileID: UUID) -> URL {
        guard !ProfileSettingsStore.sharesServices,
              profileID != ProfileManager.defaultProfileID else {
            return sharedStoreURL
        }
        return NSPersistentContainer.defaultDirectoryURL()
            .appendingPathComponent(
                ProfileScopedStorage.documentFileName(
                    base: containerName,
                    fileExtension: "sqlite",
                    profileID: profileID
                )
            )
    }

    static var activeStoreURL: URL {
        storeURL(for: ProfileManager.shared.activeProfileID)
    }

    static func scopedStoreURL(forProfile profileID: UUID) -> URL {
        NSPersistentContainer.defaultDirectoryURL()
            .appendingPathComponent(
                ProfileScopedStorage.documentFileName(
                    base: containerName,
                    fileExtension: "sqlite",
                    profileID: profileID
                )
            )
    }

    static func scopedVaultAccountSuffix(forProfile profileID: UUID) -> String {
        guard profileID != ProfileManager.defaultProfileID else { return "" }
        return "#\(ProfileScopedStorage.token(for: profileID))"
    }

    static func seedIfNeeded(at url: URL) {
        let manager = FileManager.default
        guard url != sharedStoreURL,
              !manager.fileExists(atPath: url.path),
              manager.fileExists(atPath: sharedStoreURL.path) else { return }

        for suffix in ["", "-wal"] {
            let source = URL(fileURLWithPath: sharedStoreURL.path + suffix)
            let destination = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            try? manager.copyItem(at: source, to: destination)
        }
    }

    static func seedServicesSettingsIfNeeded(forProfile profileID: UUID) {
        guard profileID != ProfileManager.defaultProfileID else { return }
        let destination = ProfileSettingsStore.shared.store(for: profileID)
        let seededMarker = "eclipseServicesSettingsSeededV1"
        guard !destination.bool(forKey: seededMarker) else { return }

        let source = UserDefaults.standard
        let sourceDomain = source.persistentDomain(
            forName: Bundle.main.bundleIdentifier ?? "app.Eclipse"
        ) ?? [:]

        var copied = 0
        for (key, value) in sourceDomain where EclipseSettingsRegistry.scope(for: key) == .services {
            destination.set(value, forKey: key)
            copied += 1
        }
        destination.set(true, forKey: seededMarker)
        Logger.shared.log(
            "ServiceStoreScope: seeded \(copied) services settings into profile \(profileID)",
            type: "Services"
        )
    }

    static func reopen(
        _ container: NSPersistentContainer?,
        at url: URL,
        label: String,
        seedIfMissing: Bool = true
    ) {
        guard let container else { return }
        let coordinator = container.persistentStoreCoordinator
        guard coordinator.persistentStores.first?.url != url else { return }

        container.viewContext.performAndWait {
            if container.viewContext.hasChanges {
                try? container.viewContext.save()
            }
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
            container.viewContext.reset()
        }

        if seedIfMissing {
            seedIfNeeded(at: url)
        }

        do {
            try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: url,
                options: [
                    NSPersistentHistoryTrackingKey: true as NSNumber,
                    NSMigratePersistentStoresAutomaticallyOption: true as NSNumber,
                    NSInferMappingModelAutomaticallyOption: true as NSNumber
                ]
            )
        } catch {
            Logger.shared.log(
                "\(label): Failed to open store at \(url.lastPathComponent): \(error.localizedDescription)",
                type: "Storage"
            )
        }
    }

    struct StoreFileSnapshot {
        let targetURL: URL
        fileprivate let snapshotDirectory: URL
        fileprivate let targetExisted: Bool
        fileprivate let scopedVaultProfileID: UUID?
        fileprivate let addonCredentials: [AddonCredentialSnapshot]
        fileprivate let serviceCredentials: [ServiceCredentialSnapshot]
    }

    fileprivate struct AddonCredentialSnapshot {
        let addonID: UUID
        let value: String?
    }

    fileprivate struct ServiceCredentialSnapshot {
        let serviceID: UUID
        let key: String
        let value: String?
    }

    @MainActor
    static func captureStoreFileSnapshot(
        at targetURL: URL,
        scopedVaultProfileID: UUID?
    ) throws -> StoreFileSnapshot {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(
            "Eclipse-ServiceRestore-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let targetURL = targetURL.standardizedFileURL
        let targetWasActive = targetURL == activeStoreURL.standardizedFileURL
        let parkingURL = directory.appendingPathComponent("parking.sqlite")
        var shouldKeepSnapshot = false
        if targetWasActive {
            ServiceStore.shared.reopenStore(at: parkingURL, seedIfMissing: false)
            StremioAddonStore.shared.reopenStore(at: parkingURL, seedIfMissing: false)
        }
        defer {
            if targetWasActive {
                ServiceStore.shared.reopenStore(at: targetURL)
                StremioAddonStore.shared.reopenStore(at: targetURL)
            }
            removeStoreFiles(at: parkingURL)
            if !shouldKeepSnapshot {
                try? manager.removeItem(at: directory)
            }
        }

        let targetExisted = manager.fileExists(atPath: targetURL.path)
        let credentialOwners = scopedCredentialOwnersIfSupported(at: targetURL)
        let addonCredentials = credentialOwners.addonIDs.map {
            AddonCredentialSnapshot(
                addonID: $0,
                value: StremioConfiguredURLVault.transactionSnapshotValue(
                    addonID: $0,
                    scopedProfileID: scopedVaultProfileID
                )
            )
        }
        let serviceCredentials = credentialOwners.serviceSettings.map {
            ServiceCredentialSnapshot(
                serviceID: $0.0,
                key: $0.1,
                value: TVServiceSettingVault.transactionSnapshotValue(
                    serviceID: $0.0,
                    key: $0.1,
                    scopedProfileID: scopedVaultProfileID
                )
            )
        }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: targetURL.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            let destination = directory.appendingPathComponent("snapshot.sqlite\(suffix)")
            try manager.copyItem(at: source, to: destination)
        }
        shouldKeepSnapshot = true
        return StoreFileSnapshot(
            targetURL: targetURL,
            snapshotDirectory: directory,
            targetExisted: targetExisted,
            scopedVaultProfileID: scopedVaultProfileID,
            addonCredentials: addonCredentials,
            serviceCredentials: serviceCredentials
        )
    }

    @MainActor
    static func restoreStoreFileSnapshot(_ snapshot: StoreFileSnapshot) throws {
        let manager = FileManager.default
        let targetURL = snapshot.targetURL.standardizedFileURL
        let targetWasActive = targetURL == activeStoreURL.standardizedFileURL
        let parkingURL = snapshot.snapshotDirectory.appendingPathComponent("rollback-parking.sqlite")
        if targetWasActive {
            ServiceStore.shared.reopenStore(at: parkingURL, seedIfMissing: false)
            StremioAddonStore.shared.reopenStore(at: parkingURL, seedIfMissing: false)
        }
        defer {
            if targetWasActive {
                ServiceStore.shared.reopenStore(at: targetURL)
                StremioAddonStore.shared.reopenStore(at: targetURL)
            }
            removeStoreFiles(at: parkingURL)
        }

        let currentCredentialOwners = scopedCredentialOwnersIfSupported(at: targetURL)
        removeStoreFiles(at: targetURL)
        if snapshot.targetExisted {
            for suffix in ["", "-wal", "-shm"] {
                let source = snapshot.snapshotDirectory.appendingPathComponent("snapshot.sqlite\(suffix)")
                guard manager.fileExists(atPath: source.path) else { continue }
                let destination = URL(fileURLWithPath: targetURL.path + suffix)
                try manager.copyItem(at: source, to: destination)
            }
        }
        restoreCredentialSnapshot(snapshot, replacing: currentCredentialOwners)
    }

    static func discardStoreFileSnapshot(_ snapshot: StoreFileSnapshot) {
        try? FileManager.default.removeItem(at: snapshot.snapshotDirectory)
    }

    private static func removeStoreFiles(at url: URL) {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: url.path + suffix)
            if manager.fileExists(atPath: candidate.path) {
                try? manager.removeItem(at: candidate)
            }
        }
    }

    private static func scopedCredentialOwnersIfSupported(
        at url: URL
    ) -> (addonIDs: [UUID], serviceSettings: [(UUID, String)]) {
#if os(tvOS)
        return scopedCredentialOwners(at: url)
#else
        return ([], [])
#endif
    }

    private static func restoreCredentialSnapshot(
        _ snapshot: StoreFileSnapshot,
        replacing current: (addonIDs: [UUID], serviceSettings: [(UUID, String)])
    ) {
#if os(tvOS)
        let originalAddonIDs = Set(snapshot.addonCredentials.map(\.addonID))
        for addonID in Set(current.addonIDs).subtracting(originalAddonIDs) {
            StremioConfiguredURLVault.restoreTransactionSnapshotValue(
                nil,
                addonID: addonID,
                scopedProfileID: snapshot.scopedVaultProfileID
            )
        }
        for credential in snapshot.addonCredentials {
            StremioConfiguredURLVault.restoreTransactionSnapshotValue(
                credential.value,
                addonID: credential.addonID,
                scopedProfileID: snapshot.scopedVaultProfileID
            )
        }

        let originalServiceKeys = Set(snapshot.serviceCredentials.map {
            "\($0.serviceID.uuidString):\($0.key)"
        })
        for (serviceID, key) in current.serviceSettings
        where !originalServiceKeys.contains("\(serviceID.uuidString):\(key)") {
            TVServiceSettingVault.restoreTransactionSnapshotValue(
                nil,
                serviceID: serviceID,
                key: key,
                scopedProfileID: snapshot.scopedVaultProfileID
            )
        }
        for credential in snapshot.serviceCredentials {
            TVServiceSettingVault.restoreTransactionSnapshotValue(
                credential.value,
                serviceID: credential.serviceID,
                key: credential.key,
                scopedProfileID: snapshot.scopedVaultProfileID
            )
        }
#endif
    }

    static func vaultAccountSuffix(forProfile profileID: UUID) -> String {
        guard !ProfileSettingsStore.sharesServices,
              profileID != ProfileManager.defaultProfileID else {
            return ""
        }
        return "#\(ProfileScopedStorage.token(for: profileID))"
    }

    static var vaultAccountSuffix: String {
        vaultAccountSuffix(forProfile: ProfileManager.shared.activeProfileID)
    }

    private(set) static var generation = 0

    static func isCurrent(_ captured: Int) -> Bool { captured == generation }

    static func willChangeActiveProfile() {
        generation &+= 1
    }

    static func discardStore(forProfile profileID: UUID) {
        guard profileID != ProfileManager.defaultProfileID else { return }

        let url = scopedStoreURL(forProfile: profileID)
        guard url != sharedStoreURL, url != activeStoreURL else { return }

        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }

#if os(tvOS)
        for (addonIDs, serviceSettings) in [scopedCredentialOwners(at: url)] {
            for addonID in addonIDs {
                StremioConfiguredURLVault.removeScoped(addonID: addonID, profileID: profileID)
            }
            for (serviceID, key) in serviceSettings {
                TVServiceSettingVault.removeScoped(serviceID: serviceID, key: key, profileID: profileID)
            }
        }
#endif

        for suffix in ["", "-wal", "-shm"] {
            try? manager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }

        Logger.shared.log(
            "ServiceStoreScope: reclaimed the services database for profile \(profileID)",
            type: "Services"
        )
    }

    static func withReadOnlyStore<Value>(
        forProfile profileID: UUID,
        _ body: (NSManagedObjectContext) -> Value
    ) -> Value? {
        let url = storeURL(for: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let container = NSPersistentContainer(name: containerName)
        guard let description = container.persistentStoreDescriptions.first else { return nil }
        description.type = NSSQLiteStoreType
        description.url = url
        description.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption)

        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        if let failure {
            Logger.shared.log(
                "ServiceStoreScope: could not open \(url.lastPathComponent) read-only: \(failure.localizedDescription)",
                type: "Storage"
            )
            return nil
        }
        defer {
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
        }

        var result: Value?
        container.viewContext.performAndWait {
            result = body(container.viewContext)
        }
        return result
    }

    struct RestoredService {
        let id: UUID
        let url: String
        let jsonMetadata: String
        let jsScript: String
        let isActive: Bool
        let sortIndex: Int64
    }

    struct RestoredAddon {
        let id: UUID
        let configuredURL: String
        let manifestJSON: String
        let isActive: Bool
        let sortIndex: Int64
    }

    static func restoreSources(
        services: [RestoredService],
        addons: [RestoredAddon],
        skyStreamStateData: Data? = nil,
        forProfile profileID: UUID
    ) {
        let url = storeURL(for: profileID)
        guard url != activeStoreURL else { return }

        seedIfNeeded(at: url)

        let container = NSPersistentContainer(name: containerName)
        guard let description = container.persistentStoreDescriptions.first else { return }
        description.type = NSSQLiteStoreType
        description.url = url
        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        if let failure {
            Logger.shared.log(
                "ServiceStoreScope: could not open \(url.lastPathComponent) to restore sources: \(failure.localizedDescription)",
                type: "Storage"
            )
            return
        }
        defer {
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
        }

        let context = container.viewContext
        context.performAndWait {

            var replacedAddonIDs: [UUID] = []
            var replacedServiceSettings: [(UUID, String)] = []
            for entityName in ["ServiceEntity", "StremioAddonEntity"] {
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                guard let existing = try? context.fetch(request) as? [NSManagedObject] else { continue }
                for entity in existing {
                    if entityName == "StremioAddonEntity" {
                        if let id = entity.value(forKey: "id") as? UUID { replacedAddonIDs.append(id) }
                    } else if let id = entity.value(forKey: "id") as? UUID,
                              let script = entity.value(forKey: "jsScript") as? String {
                        for setting in ServiceManager.parseSettingsFromJS(script) where setting.isSensitive {
                            replacedServiceSettings.append((id, setting.key))
                        }
                    }
                    context.delete(entity)
                }
            }

            for service in services {

                guard let script = securedScriptForRestore(
                    service.jsScript,
                    serviceID: service.id,
                    profileID: profileID
                ) else { continue }
                guard let entity = NSEntityDescription.insertNewObject(
                    forEntityName: "ServiceEntity",
                    into: context
                ) as NSManagedObject? else { continue }
                entity.setValue(service.id, forKey: "id")
                entity.setValue(service.url, forKey: "url")
                entity.setValue(service.jsonMetadata, forKey: "jsonMetadata")
                entity.setValue(script, forKey: "jsScript")
                entity.setValue(service.isActive, forKey: "isActive")
                entity.setValue(service.sortIndex, forKey: "sortIndex")
            }

            for addon in addons {
                guard let entity = NSEntityDescription.insertNewObject(
                    forEntityName: "StremioAddonEntity",
                    into: context
                ) as NSManagedObject? else { continue }
                entity.setValue(addon.id, forKey: "id")

                let protected = StremioConfiguredURLVault.protect(
                    addon.configuredURL,
                    addonID: addon.id,
                    profileID: profileID
                )
                entity.setValue(protected.persistedURL, forKey: "configuredURL")
                entity.setValue(addon.manifestJSON, forKey: "manifestJSON")
                entity.setValue(addon.isActive, forKey: "isActive")
                entity.setValue(addon.sortIndex, forKey: "sortIndex")
            }

            if let skyStreamStateData,
               skyStreamStateData.count <= 8 * 1_024 * 1_024,
               let json = String(data: skyStreamStateData, encoding: .utf8) {
                let request = NSFetchRequest<NSManagedObject>(entityName: "SkyStreamStateEntity")
                request.predicate = NSPredicate(format: "id == %@", SkyStreamStateEntity.singletonID)
                request.fetchLimit = 1
                let entity = (try? context.fetch(request))?.first
                    ?? NSEntityDescription.insertNewObject(
                        forEntityName: "SkyStreamStateEntity",
                        into: context
                    )
                entity.setValue(SkyStreamStateEntity.singletonID, forKey: "id")
                entity.setValue(json, forKey: "jsonState")
                entity.setValue(Date(), forKey: "updatedAt")
            }

            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    Logger.shared.log(
                        "ServiceStoreScope: failed to restore sources for profile \(profileID): \(error.localizedDescription)",
                        type: "Storage"
                    )
                    return
                }
            }

#if os(tvOS)

            let survivingAddonIDs = Set(addons.map(\.id))
            for addonID in replacedAddonIDs where !survivingAddonIDs.contains(addonID) {
                StremioConfiguredURLVault.remove(addonID: addonID, profileID: profileID)
            }
            let survivingServiceIDs = Set(services.map(\.id))
            for (serviceID, key) in replacedServiceSettings where !survivingServiceIDs.contains(serviceID) {
                TVServiceSettingVault.remove(serviceID: serviceID, key: key, profileID: profileID)
            }
#endif
        }
        Logger.shared.log(
            "ServiceStoreScope: restored \(services.count) service(s) and \(addons.count) addon(s) into profile \(profileID)",
            type: "Services"
        )
    }

    static func securedScriptForRestore(
        _ script: String,
        serviceID: UUID,
        profileID: UUID
    ) -> String? {
#if os(tvOS)
        let settings = ServiceManager.parseSettingsFromJS(script)
        guard settings.contains(where: \.isSensitive) else { return script }

        var persisted: [ServiceSetting] = []
        persisted.reserveCapacity(settings.count)
        for setting in settings {
            guard setting.isSensitive else {
                persisted.append(setting)
                continue
            }

            if setting.value != ServiceSettingSecurity.keychainPlaceholder,
               !TVServiceSettingVault.protect(
                   setting.value,
                   serviceID: serviceID,
                   key: setting.key,
                   profileID: profileID
               ) {
                Logger.shared.log(
                    "ServiceStoreScope: refused to restore service \(serviceID) into profile \(profileID); its \(setting.key) credential could not be secured",
                    type: "Storage"
                )
                return nil
            }
            persisted.append(ServiceSetting(
                key: setting.key,
                value: ServiceSettingSecurity.keychainPlaceholder,
                type: .string,
                comment: setting.comment,
                options: setting.options
            ))
        }
        return ServiceManager.updateSettingsInJS(script, with: persisted)
#else
        return script
#endif
    }

#if os(tvOS)

    private static func scopedCredentialOwners(
        at url: URL
    ) -> (addonIDs: [UUID], serviceSettings: [(UUID, String)]) {
        let container = NSPersistentContainer(name: containerName)
        guard let description = container.persistentStoreDescriptions.first else {
            return ([], [])
        }
        description.type = NSSQLiteStoreType
        description.url = url
        description.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption)

        var failed = false
        container.loadPersistentStores { _, error in
            if error != nil { failed = true }
        }
        guard !failed else { return ([], []) }
        defer {
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
        }

        var addonIDs: [UUID] = []
        var serviceSettings: [(UUID, String)] = []
        let context = container.viewContext
        context.performAndWait {
            let addonRequest = NSFetchRequest<NSManagedObject>(entityName: "StremioAddonEntity")
            addonIDs = ((try? context.fetch(addonRequest)) ?? [])
                .compactMap { $0.value(forKey: "id") as? UUID }

            let serviceRequest = NSFetchRequest<NSManagedObject>(entityName: "ServiceEntity")
            for entity in (try? context.fetch(serviceRequest)) ?? [] {
                guard let id = entity.value(forKey: "id") as? UUID,
                      let script = entity.value(forKey: "jsScript") as? String else { continue }
                for setting in ServiceManager.parseSettingsFromJS(script) where setting.isSensitive {
                    serviceSettings.append((id, setting.key))
                }
            }
        }
        return (addonIDs, serviceSettings)
    }
#endif

    static func activeProfileDidChange(notifyObservers: Bool = true) {

        generation &+= 1
        let profileID = ProfileManager.shared.activeProfileID

        if !ProfileSettingsStore.sharesServices {
            seedServicesSettingsIfNeeded(forProfile: profileID)
        }
        let url = storeURL(for: profileID)
        ServiceStore.shared.reopenStore(at: url)
        StremioAddonStore.shared.reopenStore(at: url)
        if notifyObservers {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}
