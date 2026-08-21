import CoreData
import Foundation

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
