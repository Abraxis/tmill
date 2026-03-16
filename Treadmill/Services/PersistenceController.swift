// ~/src/tmill/Treadmill/Services/PersistenceController.swift
import CoreData
import os

final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer

    private let logger = Logger(subsystem: "com.treadmill.app", category: "Persistence")

    init(inMemory: Bool = false) {
        let model = CoreDataModel.create()
        container = NSPersistentCloudKitContainer(name: "Treadmill", managedObjectModel: model)

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        } else {
            guard let description = container.persistentStoreDescriptions.first else {
                fatalError("No persistent store descriptions found")
            }
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.treadmill.app"
            )
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
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

    /// For testing
    static var preview: PersistenceController = {
        PersistenceController(inMemory: true)
    }()
}
