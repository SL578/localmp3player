import CoreData
import Foundation

enum SongSort: String, CaseIterable, Identifiable {
    case title
    case artist
    case dateAdded
    case playCount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .dateAdded: return "Recently Added"
        case .playCount: return "Most Played"
        }
    }

    var descriptors: [NSSortDescriptor] {
        switch self {
        case .title:
            return [NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))]
        case .artist:
            return [
                NSSortDescriptor(key: "artist", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:))),
                NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
            ]
        case .dateAdded:
            return [NSSortDescriptor(key: "dateAdded", ascending: false)]
        case .playCount:
            return [NSSortDescriptor(key: "playCount", ascending: false)]
        }
    }
}

/// The single source of truth for "which songs belong to X".
/// Both the SwiftUI screens and the CarPlay templates build their lists from here,
/// so a rule change never has to be implemented twice.
enum LibraryQuery {
    static func allSongs(sort: SongSort = .title, searchText: String = "") -> NSFetchRequest<Song> {
        let request = Song.fetchRequest()
        request.sortDescriptors = sort.descriptors
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            request.predicate = NSPredicate(
                format: "title CONTAINS[cd] %@ OR artist CONTAINS[cd] %@ OR album CONTAINS[cd] %@",
                trimmed, trimmed, trimmed
            )
        }
        return request
    }

    static func songs(taggedWith tag: Tag, sort: SongSort = .title) -> NSFetchRequest<Song> {
        let request = Song.fetchRequest()
        request.predicate = NSPredicate(format: "ANY tags == %@", tag)
        request.sortDescriptors = sort.descriptors
        return request
    }

    static func allTags() -> NSFetchRequest<Tag> {
        let request = Tag.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "displayName", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))]
        return request
    }

    static func allPlaylists() -> NSFetchRequest<Playlist> {
        let request = Playlist.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))]
        return request
    }

    static func allSmartPlaylists() -> NSFetchRequest<SmartPlaylist> {
        let request = SmartPlaylist.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))]
        return request
    }

    static func duplicateCandidates(for normalizedKey: String) -> NSFetchRequest<Song> {
        let request = Song.fetchRequest()
        request.predicate = NSPredicate(format: "normalizedKey == %@", normalizedKey)
        request.fetchLimit = 1
        return request
    }

    static func fetch(_ request: NSFetchRequest<Song>, in context: NSManagedObjectContext) -> [Song] {
        (try? context.fetch(request)) ?? []
    }

    static func fetchAll<T: NSManagedObject>(_ request: NSFetchRequest<T>, in context: NSManagedObjectContext) -> [T] {
        (try? context.fetch(request)) ?? []
    }
}
