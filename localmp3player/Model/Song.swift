import CoreData
import Foundation

@objc(Song)
public final class Song: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var filePath: String
    @NSManaged public var title: String
    @NSManaged public var artist: String
    @NSManaged public var album: String?
    @NSManaged public var duration: Double
    @NSManaged public var artworkData: Data?
    @NSManaged public var dateAdded: Date
    @NSManaged public var lastPlayed: Date?
    @NSManaged public var playCount: Int64
    @NSManaged public var normalizedKey: String
    @NSManaged public var originalFilename: String
    @NSManaged public var fileSize: Int64
    @NSManaged public var isLiked: Bool
    @NSManaged public var tags: Set<Tag>
    @NSManaged public var playlistEntries: Set<PlaylistEntry>
}

extension Song {
    static func fetchRequest() -> NSFetchRequest<Song> {
        NSFetchRequest<Song>(entityName: "Song")
    }

    var sortedTags: [Tag] {
        tags.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var subtitle: String {
        if let album, !album.isEmpty { return "\(artist) — \(album)" }
        return artist
    }

    func addTag(_ tag: Tag) {
        tags.insert(tag)
    }

    func removeTag(_ tag: Tag) {
        tags.remove(tag)
    }
}
