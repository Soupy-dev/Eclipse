import CoreData
#if os(tvOS)
import Security
#endif

enum StremioConfiguredURLVault {
    struct ProtectedValue {
        let persistedURL: String
        let resolvedURL: String
    }

    static func protect(_ configuredURL: String, addonID: UUID) -> ProtectedValue {
#if os(tvOS)
        if isKeychainReference(configuredURL) {
            return ProtectedValue(
                persistedURL: configuredURL,
                resolvedURL: load(addonID: addonID) ?? configuredURL
            )
        }

        let didStore = store(configuredURL, addonID: addonID)
        if !didStore {
            Logger.shared.log(
                "Stremio: Could not store configured URL securely addon=\(addonID.uuidString)",
                type: "Storage"
            )
        }
        let safeURL = keychainReference(addonID: addonID)
        return ProtectedValue(
            persistedURL: safeURL,
            resolvedURL: didStore ? configuredURL : safeURL
        )
#else
        return ProtectedValue(persistedURL: configuredURL, resolvedURL: configuredURL)
#endif
    }

    static func migrateOrResolve(_ persistedURL: String, addonID: UUID) -> ProtectedValue {
#if os(tvOS)
        if let securedURL = load(addonID: addonID) {
            return ProtectedValue(
                persistedURL: keychainReference(addonID: addonID),
                resolvedURL: securedURL
            )
        }
        return protect(persistedURL, addonID: addonID)
#else
        return ProtectedValue(persistedURL: persistedURL, resolvedURL: persistedURL)
#endif
    }

    static func resolve(addonID: UUID, persistedURL: String) -> String {
#if os(tvOS)
        return load(addonID: addonID) ?? persistedURL
#else
        return persistedURL
#endif
    }

    static func remove(addonID: UUID) {
#if os(tvOS)
        SecItemDelete(query(addonID: addonID) as CFDictionary)
#endif
    }

#if os(tvOS)
    private static let service = "app.Eclipse.Soupy.stremio-configured-url"

    private static func keychainReference(addonID: UUID) -> String {
        "eclipse-keychain://stremio-addon/\(addonID.uuidString)"
    }

    private static func isKeychainReference(_ value: String) -> Bool {
        value.lowercased().hasPrefix("eclipse-keychain://stremio-addon/")
    }

    private static func query(addonID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: addonID.uuidString
        ]
    }

    private static func store(_ value: String, addonID: UUID) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        var item = query(addonID: addonID)
        SecItemDelete(item as CFDictionary)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func load(addonID: UUID) -> String? {
        var item = query(addonID: addonID)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
#endif
}

final class StremioAddonStore {
    static let shared = StremioAddonStore()

    private var container: NSPersistentContainer? = nil

    private init() {
        container = NSPersistentContainer(name: "ServiceModels")

        guard let description = container?.persistentStoreDescriptions.first else {
            Logger.shared.log("Stremio: Missing store description", type: "Storage")
            return
        }

        description.type = NSSQLiteStoreType
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)

        container?.loadPersistentStores { _, error in
            if let error = error {
                Logger.shared.log("Stremio: Failed to load persistent store: \(error.localizedDescription)", type: "Storage")
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let viewContext = self?.container?.viewContext else { return }
                    viewContext.automaticallyMergesChangesFromParent = true
                    viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                }
            }
        }
    }

    // MARK: - CRUD

    func storeAddon(id: UUID, configuredURL: String, manifestJSON: String, isActive: Bool, sortIndex: Int64? = nil) {
        guard let container = container else {
            Logger.shared.log("Stremio: Container not initialized: storeAddon", type: "Storage")
            return
        }

        container.viewContext.performAndWait {
            let context = container.viewContext
            let fetchRequest: NSFetchRequest<StremioAddonEntity> = StremioAddonEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetchRequest.fetchLimit = 1

            do {
                let results = try context.fetch(fetchRequest)
                let entity: StremioAddonEntity

                if let existing = results.first {
                    entity = existing
                } else {
                    entity = StremioAddonEntity(context: context)
                    entity.id = id

                    let countRequest: NSFetchRequest<StremioAddonEntity> = StremioAddonEntity.fetchRequest()
                    countRequest.includesSubentities = false
                    let count = try context.count(for: countRequest)
                    entity.sortIndex = sortIndex ?? Int64(count)
                }

                let protectedURL = StremioConfiguredURLVault.protect(configuredURL, addonID: id)
                entity.configuredURL = protectedURL.persistedURL
                entity.manifestJSON = manifestJSON
                entity.isActive = isActive
                if let sortIndex {
                    entity.sortIndex = sortIndex
                }

                if context.hasChanges {
                    try context.save()
                }
            } catch {
                Logger.shared.log("Stremio: Store addon failed: \(error.localizedDescription)", type: "Storage")
            }
        }
    }

    func getAddons() -> [StremioAddon] {
        guard let container = container else {
            Logger.shared.log("Stremio: Container not initialized: getAddons", type: "Storage")
            return []
        }

        var result: [StremioAddon] = []

        container.viewContext.performAndWait {
            do {
                let request: NSFetchRequest<StremioAddonEntity> = StremioAddonEntity.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
                let entities = try container.viewContext.fetch(request)
                for entity in entities {
                    guard let id = entity.id, let configuredURL = entity.configuredURL else { continue }
                    let protectedURL = StremioConfiguredURLVault.migrateOrResolve(configuredURL, addonID: id)
                    if entity.configuredURL != protectedURL.persistedURL {
                        entity.configuredURL = protectedURL.persistedURL
                    }
                }
                if container.viewContext.hasChanges {
                    try container.viewContext.save()
                }
                result = entities.compactMap { $0.asModel }
            } catch {
                Logger.shared.log("Stremio: Fetch addons failed: \(error.localizedDescription)", type: "Storage")
            }
        }

        return result
    }

    func getEntities() -> [StremioAddonEntity] {
        guard let container = container else { return [] }

        var result: [StremioAddonEntity] = []

        container.viewContext.performAndWait {
            do {
                let request: NSFetchRequest<StremioAddonEntity> = StremioAddonEntity.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
                result = try container.viewContext.fetch(request)
            } catch {
                Logger.shared.log("Stremio: Fetch entities failed: \(error.localizedDescription)", type: "Storage")
            }
        }

        return result
    }

    func remove(_ addon: StremioAddon) {
        guard let container = container else { return }

        container.viewContext.performAndWait {
            let request: NSFetchRequest<StremioAddonEntity> = StremioAddonEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", addon.id as CVarArg)
            do {
                if let entity = try container.viewContext.fetch(request).first {
                    if let id = entity.id {
                        StremioConfiguredURLVault.remove(addonID: id)
                    }
                    container.viewContext.delete(entity)
                    if container.viewContext.hasChanges {
                        try container.viewContext.save()
                    }
                }
            } catch {
                Logger.shared.log("Stremio: Remove addon failed: \(error.localizedDescription)", type: "Storage")
            }
        }
    }

    func removeAll() {
        guard let container = container else { return }
        let existingIDs = getEntities().compactMap(\.id)

        container.viewContext.performAndWait {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "StremioAddonEntity")
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
            deleteRequest.resultType = .resultTypeObjectIDs

            do {
                let result = try container.viewContext.execute(deleteRequest) as? NSBatchDeleteResult
                let objectIDs = result?.result as? [NSManagedObjectID] ?? []
                if !objectIDs.isEmpty {
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                        into: [container.viewContext]
                    )
                }
                if container.viewContext.hasChanges {
                    try container.viewContext.save()
                }
                existingIDs.forEach { StremioConfiguredURLVault.remove(addonID: $0) }
            } catch {
                Logger.shared.log("Stremio: Remove all addons failed: \(error.localizedDescription)", type: "Storage")
            }
        }
    }

    func save() {
        guard let container = container else { return }

        container.viewContext.performAndWait {
            do {
                if container.viewContext.hasChanges {
                    try container.viewContext.save()
                }
            } catch {
                Logger.shared.log("Stremio: Save failed: \(error.localizedDescription)", type: "Storage")
            }
        }
    }
}
