import CoreData
import os

final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    private let logger = Logger(subsystem: "com.mymill.app", category: "Persistence")

    init(inMemory: Bool = false) {
        let model = CoreDataModel.create()
        // Use regular container — CloudKit requires code signing + provisioning.
        // Switch to NSPersistentCloudKitContainer when distributing via App Store.
        container = NSPersistentContainer(name: "Treadmill", managedObjectModel: model)

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        }

        container.loadPersistentStores { description, error in
            if let error {
                self.logger.error("Core Data load failed: \(error.localizedDescription)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    func save() {
        let context = viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            logger.error("Core Data save failed: \(error.localizedDescription)")
        }
    }

    static var preview: PersistenceController = {
        PersistenceController(inMemory: true)
    }()
}
