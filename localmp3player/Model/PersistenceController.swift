import CoreData
import Foundation

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "LocalLibrary")
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        // Stated rather than left to the default. Every model change so far has
        // been an added optional attribute, which Core Data can infer a mapping
        // for; a change it can't infer should fail loudly here rather than be
        // silently absent because someone assumed migration was off.
        container.persistentStoreDescriptions.first?.shouldMigrateStoreAutomatically = true
        container.persistentStoreDescriptions.first?.shouldInferMappingModelAutomatically = true
        container.loadPersistentStores { _, error in
            if let error {
                assertionFailure("Core Data store failed to load: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    var viewContext: NSManagedObjectContext { container.viewContext }

    func save() {
        let context = container.viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            assertionFailure("Save failed: \(error)")
        }
    }
}

extension PersistenceController {
    /// Populates an in-memory store so SwiftUI previews render real rows.
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.viewContext
        let rock = Tag.findOrCreate(named: "Rock", in: context)
        let drive = Tag.findOrCreate(named: "Driving", in: context)

        let samples: [(String, String, Double, Int64)] = [
            ("Blue Monday", "New Order", 448, 12),
            ("Midnight City", "M83", 244, 5),
            ("Nightcall", "Kavinsky", 258, 31),
            ("Teenage Riot", "Sonic Youth", 398, 0)
        ]
        for (index, sample) in samples.enumerated() {
            let song = Song(context: context)
            song.id = UUID()
            song.title = sample.0
            song.artist = sample.1
            song.duration = sample.2
            song.playCount = sample.3
            song.filePath = "Audio/sample-\(index).mp3"
            song.originalFilename = "\(sample.0) - \(sample.1).mp3"
            song.dateAdded = Date().addingTimeInterval(Double(-index) * 86_400)
            song.normalizedKey = NormalizedKey.make(title: sample.0, artist: sample.1)
            song.fileSize = 4_000_000
            song.isLiked = index.isMultiple(of: 2)
            if let rock { song.addTag(rock) }
            if index < 2, let drive { song.addTag(drive) }
        }
        try? context.save()
        return controller
    }()
}
