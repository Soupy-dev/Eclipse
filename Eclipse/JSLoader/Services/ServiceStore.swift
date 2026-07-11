import CoreData

public final class ServiceStore {
    public static let shared = ServiceStore()

    // MARK: private - internal setup and update functions

    private var container: NSPersistentContainer? = nil

    private init() {
        container = NSPersistentContainer(name: "ServiceModels")

        guard let description = container?.persistentStoreDescriptions.first else {
            Logger.shared.log("Missing store description", type: "Storage")
            return
        }

        description.type = NSSQLiteStoreType
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)

        container?.loadPersistentStores { _, error in
            if let error = error {
                Logger.shared.log("Failed to load persistent store: \(error.localizedDescription)", type: "Storage")
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let viewContext = self?.container?.viewContext else { return }
                    viewContext.automaticallyMergesChangesFromParent = true
                    viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                }
            }
        }
    }

    // MARK: public - status, add, get, remove, save, syncManually functions

    public enum CloudStatus {
        case unavailable       // container not initialized
        case ready             // container initialized and loaded
        case unknown           // initialization failed
    }

    public func status() -> CloudStatus {
        guard let container = container else { return .unavailable }

        if container.persistentStoreCoordinator.persistentStores.first != nil {
            return .ready
        } else {
            return .unknown
        }
    }

    public func storeService(
        id: UUID,
        url: String,
        jsonMetadata: String,
        jsScript: String,
        isActive: Bool,
        sortIndex: Int64? = nil
    ) {
        guard let container = container else {
            Logger.shared.log("Persistent container not initialized: storeService", type: "Storage")
            return
        }

        container.viewContext.performAndWait {
            let context = container.viewContext

            // Check if a service with the same ID already exists
            let fetchRequest: NSFetchRequest<ServiceEntity> = ServiceEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetchRequest.fetchLimit = 1

            do {
                let results = try context.fetch(fetchRequest)
                let service: ServiceEntity

                if let existing = results.first {
                    // Update existing service
                    service = existing
                } else {
                    // Create new service
                    service = ServiceEntity(context: context)
                    service.id = id

                    // Assign proper sort index so new services go to the bottom
                    let countRequest: NSFetchRequest<ServiceEntity> = ServiceEntity.fetchRequest()
                    countRequest.includesSubentities = false
                    let count = try context.count(for: countRequest)

                    service.sortIndex = sortIndex ?? Int64(count)
                }

                service.url = url
                service.jsonMetadata = jsonMetadata
                service.jsScript = jsScript
                service.isActive = isActive
                if let sortIndex {
                    service.sortIndex = sortIndex
                }

                do {
                    if context.hasChanges {
                        try context.save()
                    }
                } catch {
                    Logger.shared.log("Save failed: \(error.localizedDescription)", type: "Storage")
                }
            } catch {
                Logger.shared.log("Failed to fetch existing service: \(error.localizedDescription)", type: "Storage")
            }
        }
    }

    public func getEntities() -> [ServiceEntity] {
        guard let container = container else {
            Logger.shared.log("Persistent container not initialized: getEntities", type: "Storage")
            return []
        }

        var result: [ServiceEntity] = []

        container.viewContext.performAndWait {
            do {
                let request: NSFetchRequest<ServiceEntity> = ServiceEntity.fetchRequest()
                let sort = NSSortDescriptor(key: "sortIndex", ascending: true)
                request.sortDescriptors = [sort]
                result = try container.viewContext.fetch(request)
            } catch {
                Logger.shared.log("Fetch failed: \(error.localizedDescription)", type: "Storage")
            }
        }

        return result
    }

    public func getServices() -> [Service] {
        guard let container = container else {
            Logger.shared.log("Persistent container not initialized: getServices", type: "Storage")
            return []
        }

        var result: [Service] = []

        container.viewContext.performAndWait {
            do {
                let request: NSFetchRequest<ServiceEntity> = ServiceEntity.fetchRequest()
                let sort = NSSortDescriptor(key: "sortIndex", ascending: true)
                request.sortDescriptors = [sort]
                let entities = try container.viewContext.fetch(request)
                Logger.shared.log("Loaded \(entities.count) ServiceEntities", type: "Storage")
                result = entities.compactMap { $0.asModel }
            } catch {
                Logger.shared.log("Fetch failed: \(error.localizedDescription)", type: "Storage")
            }
        }

        return result
    }

    public func remove(_ service: Service) {
        guard let container = container else {
            Logger.shared.log("Persistent container not initialized: remove", type: "Storage")
            return
        }

        container.viewContext.performAndWait {
            let request: NSFetchRequest<ServiceEntity> = ServiceEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", service.id as CVarArg)
            do {
                if let entity = try container.viewContext.fetch(request).first {
                    container.viewContext.delete(entity)
                    if container.viewContext.hasChanges {
                        try container.viewContext.save()
                    }
                } else {
                    Logger.shared.log("ServiceEntity not found for id: \(service.id)", type: "Storage")
                }
            } catch {
                Logger.shared.log("Failed to fetch ServiceEntity to delete: \(error.localizedDescription)", type: "Storage")
            }
        }
    }

    public func save() {
        guard let container = container else {
            Logger.shared.log("Persistent container not initialized: save", type: "Storage")
            return
        }

        container.viewContext.performAndWait {
            do {
                if container.viewContext.hasChanges {
                    try container.viewContext.save()
                }
            } catch {
                Logger.shared.log("Save failed: \(error.localizedDescription)", type: "Storage")
            }
        }
    }

    public func syncManually() async {
        guard let container = container else {
            Logger.shared.log("Persistent container not initialized: syncManually", type: "Storage")
            return
        }

        do {
            try await container.viewContext.perform {
                try container.viewContext.save()
                let _ = ServiceStore.shared.getServices()
            }
        } catch {
            Logger.shared.log("Sync failed: \(error.localizedDescription)", type: "Storage")
        }
    }
}
