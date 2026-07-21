import CoreData
import Foundation

/// A single bounded metadata document stored beside legacy Services and Stremio addons.
/// Executable package data is intentionally kept out of Core Data.
@objc(SkyStreamStateEntity)
final class SkyStreamStateEntity: NSManagedObject {
    static let singletonID = "state-v1"
}

extension SkyStreamStateEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<SkyStreamStateEntity> {
        NSFetchRequest<SkyStreamStateEntity>(entityName: "SkyStreamStateEntity")
    }

    @NSManaged var id: String
    @NSManaged var jsonState: String?
    @NSManaged var updatedAt: Date?
}

