//
//  CloudStore.swift
//  Eclipse
//
//  Created by Dominic on 07.11.25.
//

import CoreData

private actor ServiceStoreReadiness {
    private enum State {
        case pending
        case ready
        case failed
    }

    private var state: State = .pending
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func complete(successfully: Bool) {
        guard case .pending = state else { return }
        state = successfully ? .ready : .failed
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            if successfully {
                waiter.resume()
            } else {
                waiter.resume(throwing: CocoaError(.persistentStoreOperation))
            }
        }
    }

    func waitUntilReady() async throws {
        switch state {
        case .ready:
            return
        case .failed:
            throw CocoaError(.persistentStoreOperation)
        case .pending:
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(continuation)
            }
        }
    }
}

public final class ServiceStore: @unchecked Sendable {
    public static let shared = ServiceStore()

    private var container: NSPersistentContainer? = nil
    private let readiness = ServiceStoreReadiness()

    private init() {
        container = NSPersistentContainer(name: "ServiceModels")

        guard let description = container?.persistentStoreDescriptions.first else {
            Logger.shared.log("Missing store description", type: "Storage")
            Task { await readiness.complete(successfully: false) }
            return
        }

        description.type = NSSQLiteStoreType

        let scopedURL = ServiceStoreScope.activeStoreURL
        ServiceStoreScope.seedIfNeeded(at: scopedURL)
        description.url = scopedURL
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)

        container?.loadPersistentStores { _, error in
            if let error = error {
                Logger.shared.log("Failed to load persistent store: \(error.localizedDescription)", type: "Storage")
                Task { await self.readiness.complete(successfully: false) }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let viewContext = self?.container?.viewContext else { return }
                    viewContext.automaticallyMergesChangesFromParent = true
                    viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                }
                Task { await self.readiness.complete(successfully: true) }
            }
        }
    }

    func reopenStore(at url: URL, seedIfMissing: Bool = true) {
        ServiceStoreScope.reopen(
            container,
            at: url,
            label: "Services",
            seedIfMissing: seedIfMissing
        )
    }

    public enum CloudStatus {
        case unavailable
        case ready
        case unknown
    }

    struct BackupRow {
        let id: UUID
        let url: String
        let jsonMetadata: String
        let jsScript: String
        let isActive: Bool
        let sortIndex: Int64
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
            self.storeService(
                id: id,
                url: url,
                jsonMetadata: jsonMetadata,
                jsScript: jsScript,
                isActive: isActive,
                sortIndex: sortIndex,
                in: container.viewContext
            )
        }
    }

    public func storeServiceAsync(
        id: UUID,
        url: String,
        jsonMetadata: String,
        jsScript: String,
        isActive: Bool,
        sortIndex: Int64? = nil,
        expectedScopeGeneration: Int? = nil
    ) async -> Bool {
        guard let container else {
            Logger.shared.log("Persistent container not initialized: storeServiceAsync", type: "Storage")
            return false
        }

        return await withCheckedContinuation { continuation in
            container.performBackgroundTask { context in
                if let expectedScopeGeneration,
                   !ServiceStoreScope.isCurrent(expectedScopeGeneration) {
                    Logger.shared.log(
                        "Services: dropped a queued service write, the services store moved",
                        type: "Storage"
                    )
                    continuation.resume(returning: false)
                    return
                }
                context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                let succeeded = self.storeService(
                    id: id,
                    url: url,
                    jsonMetadata: jsonMetadata,
                    jsScript: jsScript,
                    isActive: isActive,
                    sortIndex: sortIndex,
                    in: context
                )
                continuation.resume(returning: succeeded)
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
            result = self.fetchServices(in: container.viewContext)
        }

        return result
    }

    func backupRows() throws -> [BackupRow] {
        guard let container,
              container.persistentStoreCoordinator.persistentStores.first != nil else {
            throw CocoaError(.persistentStoreOperation)
        }
        var outcome: Result<[BackupRow], Error>!
        container.viewContext.performAndWait {
            outcome = Result {
                let request: NSFetchRequest<ServiceEntity> = ServiceEntity.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
                let entities = try container.viewContext.fetch(request)
                return try entities.map { entity in
                    guard entity.asModel != nil,
                          let id = entity.id,
                          let url = entity.url,
                          let jsonMetadata = entity.jsonMetadata,
                          let jsScript = entity.jsScript else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    return BackupRow(
                        id: id,
                        url: url,
                        jsonMetadata: jsonMetadata,
                        jsScript: jsScript,
                        isActive: entity.isActive,
                        sortIndex: entity.sortIndex
                    )
                }
            }
        }
        return try outcome.get()
    }

    public func getServicesAsync() async -> [Service] {
        guard let container else {
            Logger.shared.log("Persistent container not initialized: getServicesAsync", type: "Storage")
            return []
        }

        return await withCheckedContinuation { continuation in
            container.performBackgroundTask { context in
                context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                continuation.resume(returning: self.fetchServices(in: context))
            }
        }
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

    @discardableResult
    func removeAllServicesForAccountBoundary() -> Bool {
        guard let container else { return false }
        var succeeded = false
        container.viewContext.performAndWait {
            do {
                let request: NSFetchRequest<ServiceEntity> = ServiceEntity.fetchRequest()
                for entity in try container.viewContext.fetch(request) {
                    container.viewContext.delete(entity)
                }
                if container.viewContext.hasChanges {
                    try container.viewContext.save()
                }
                succeeded = true
            } catch {
                Logger.shared.log(
                    "Services: failed to clear account-owned rows: \(error.localizedDescription)",
                    type: "Storage"
                )
            }
        }
        return succeeded
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

    func loadSkyStreamStateData() async throws -> Data? {
        try await readiness.waitUntilReady()
        guard let container else {
            Logger.shared.log("SkyStream: persistent container unavailable while loading state", type: "Storage")
            throw CocoaError(.persistentStoreOperation)
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data?, Error>) in
            container.performBackgroundTask { context in
                let request: NSFetchRequest<SkyStreamStateEntity> = SkyStreamStateEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", SkyStreamStateEntity.singletonID)
                request.fetchLimit = 1
                do {
                    guard let entity = try context.fetch(request).first else {
                        continuation.resume(returning: nil)
                        return
                    }

                    guard let json = entity.jsonState,
                          let state = json.data(using: .utf8) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    guard state.count <= 8 * 1_024 * 1_024 else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                    continuation.resume(returning: state)
                } catch {
                    Logger.shared.log(
                        "SkyStream: failed to load persistent state (\(error.localizedDescription))",
                        type: "Storage"
                    )
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func saveSkyStreamStateData(_ data: Data, expectedScopeGeneration: Int? = nil) async throws {
        try await readiness.waitUntilReady()
        guard let container else {
            throw CocoaError(.persistentStoreOperation)
        }
        guard data.count <= 8 * 1_024 * 1_024,
              let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.performBackgroundTask { context in
                if let expectedScopeGeneration,
                   !ServiceStoreScope.isCurrent(expectedScopeGeneration) {
                    Logger.shared.log(
                        "SkyStream: dropped a queued state write, the services store moved",
                        type: "Storage"
                    )
                    continuation.resume(throwing: CocoaError(.persistentStoreOperation))
                    return
                }
                context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                let request: NSFetchRequest<SkyStreamStateEntity> = SkyStreamStateEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", SkyStreamStateEntity.singletonID)
                request.fetchLimit = 1
                do {
                    let entity = try context.fetch(request).first ?? SkyStreamStateEntity(context: context)
                    entity.id = SkyStreamStateEntity.singletonID
                    entity.jsonState = json
                    entity.updatedAt = Date()
                    if context.hasChanges {
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    Logger.shared.log(
                        "SkyStream: failed to persist state (\(error.localizedDescription))",
                        type: "Storage"
                    )
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    func clearSkyStreamStateDataForAccountBoundary() -> Bool {
        guard let container else { return false }
        var succeeded = false
        container.viewContext.performAndWait {
            let request: NSFetchRequest<SkyStreamStateEntity> = SkyStreamStateEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", SkyStreamStateEntity.singletonID)
            do {
                for entity in try container.viewContext.fetch(request) {
                    container.viewContext.delete(entity)
                }
                if container.viewContext.hasChanges {
                    try container.viewContext.save()
                }
                succeeded = true
            } catch {
                Logger.shared.log(
                    "SkyStream: failed to clear account-owned state: \(error.localizedDescription)",
                    type: "Storage"
                )
            }
        }
        return succeeded
    }

    @discardableResult
    private func storeService(
        id: UUID,
        url: String,
        jsonMetadata: String,
        jsScript: String,
        isActive: Bool,
        sortIndex: Int64?,
        in context: NSManagedObjectContext
    ) -> Bool {
        let fetchRequest: NSFetchRequest<ServiceEntity> = ServiceEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        fetchRequest.fetchLimit = 1

        do {
            let results = try context.fetch(fetchRequest)
            let service: ServiceEntity

            if let existing = results.first {
                service = existing
            } else {
                service = ServiceEntity(context: context)
                service.id = id

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

            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            Logger.shared.log("Failed to save service: \(error.localizedDescription)", type: "Storage")
            return false
        }
    }

    private func fetchServices(in context: NSManagedObjectContext) -> [Service] {
        do {
            let request: NSFetchRequest<ServiceEntity> = ServiceEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
            let entities = try context.fetch(request)
            Logger.shared.log("Loaded \(entities.count) ServiceEntities", type: "Storage")
            return entities.compactMap { $0.asModel }
        } catch {
            Logger.shared.log("Fetch failed: \(error.localizedDescription)", type: "Storage")
            return []
        }
    }
}
