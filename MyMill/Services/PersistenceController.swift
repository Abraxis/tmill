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

    /// One-time migration: trim trailing zeros from all stored sessions
    /// and extrapolate initial gaps
    func migrateSessionSamples() {
        let key = "didMigrateSessionSamples_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let context = viewContext
        let request = NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession")
        guard let sessions = try? context.fetch(request) else { return }

        for session in sessions {
            guard let data = session.speedSamples,
                  var samples = try? JSONDecoder().decode([WorkoutSession.Sample].self, from: data) else { continue }

            let original = samples.count
            samples = WorkoutSession.trimTrailingZeros(from: samples)
            samples = WorkoutSession.extrapolateInitialGap(in: samples)

            if samples.count != original {
                session.speedSamples = try? JSONEncoder().encode(samples)
            }
        }

        save()
        UserDefaults.standard.set(true, forKey: key)
        logger.info("Migrated session samples: trimmed trailing zeros and extrapolated initial gaps")
    }

    static var preview: PersistenceController = {
        PersistenceController(inMemory: true)
    }()
}
