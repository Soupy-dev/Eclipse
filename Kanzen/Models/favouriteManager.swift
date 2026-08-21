//
//  favouriteManager.swift
//  Eclipse
//
//  Created by Dawud Osman on 17/11/2025.
//

//
//  favouriteManager.swift
//  Kanzen
//
//  Created by Dawud Osman on 18/10/2025.
//
import SwiftUI
import CoreData

class FavouriteManager: ObservableObject {
    static let shared = FavouriteManager()
    let container: NSPersistentContainer

    init() {
        container = NSPersistentContainer(name: "ContentModel")
        container.loadPersistentStores { [container] _, error in
            if let error = error {
                ReaderLogger.shared.log(
                    "Unable to load favorites store; using a temporary in-memory store: \(error.localizedDescription)",
                    type: "Error"
                )

                let fallback = NSPersistentStoreDescription()
                fallback.type = NSInMemoryStoreType
                container.persistentStoreDescriptions = [fallback]
                container.loadPersistentStores { _, fallbackError in
                    if let fallbackError {
                        ReaderLogger.shared.log(
                            "Unable to load temporary favorites store: \(fallbackError.localizedDescription)",
                            type: "Error"
                        )
                    }
                }
            }
        }
    }

    func addFavourite(module: ModuleDataContainer?, content: Manga) {
        createFavouriteEntity(module: module, content: content)
    }

    func removeFavourite(moduleId: UUID, contentId: String) {
        let context = container.viewContext
        let fetchRequest = MangaData.fetchRequest() as! NSFetchRequest<MangaData>
        fetchRequest.predicate = NSPredicate(format: "sourceId == %@ AND mangaId == %@", moduleId as CVarArg, contentId)

        do {
            let contentsToDelete = try context.fetch(fetchRequest)
            for contentToDelete in contentsToDelete {
                context.delete(contentToDelete)
            }
            try context.save()
        } catch {
            ReaderLogger.shared.log("Failed to delete favorite: \(error.localizedDescription)", type: "Error")
        }
    }

    func createFavouriteEntity(module: ModuleDataContainer?, content: Manga) {
        guard let module else { return }

        let context = container.viewContext
        let newContent = MangaData(context: context)
        newContent.title = content.title
        newContent.imageURL = content.imageURL
        newContent.mangaId = content.mangaId
        newContent.sourceId = module.id

        do {
            try context.save()
        } catch {
            ReaderLogger.shared.log("Failed to save favorite: \(error.localizedDescription)", type: "Error")
        }
    }

    func isFavourite(moduleId: UUID, contentId: String) -> Bool {
        let context = container.viewContext
        let fetchRequest = MangaData.fetchRequest() as! NSFetchRequest<MangaData>
        fetchRequest.predicate = NSPredicate(format: "sourceId == %@ AND mangaId == %@", moduleId as CVarArg, contentId)

        do {
            return try context.count(for: fetchRequest) > 0
        } catch {
            ReaderLogger.shared.log("Failed to read favorite state: \(error.localizedDescription)", type: "Error")
            return false
        }
    }
}
