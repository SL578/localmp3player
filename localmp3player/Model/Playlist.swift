import CoreData
import Foundation

@objc(Playlist)
public final class Playlist: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var dateCreated: Date
    /// Optional, and nil on every playlist that existed before colors did — the
    /// rows fall back to the theme accent, so an uncolored playlist looks exactly
    /// as it did.
    @NSManaged public var colorHex: String?
    @NSManaged public var entries: Set<PlaylistEntry>
}

@objc(PlaylistEntry)
public final class PlaylistEntry: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var position: Int64
    @NSManaged public var playlist: Playlist?
    @NSManaged public var song: Song?
}

extension Playlist: Colorable {
    var colorLabel: String { name }
    static var colorTitle: String { "Playlist Color" }
    static var colorFooter: String {
        "The color shows on this playlist's row, so it's quicker to find in a long list."
    }
}

extension Playlist {
    static func fetchRequest() -> NSFetchRequest<Playlist> {
        NSFetchRequest<Playlist>(entityName: "Playlist")
    }

    var orderedEntries: [PlaylistEntry] {
        entries.sorted { $0.position < $1.position }
    }

    var songs: [Song] {
        orderedEntries.compactMap(\.song)
    }

    func append(_ song: Song) {
        guard let context = managedObjectContext else { return }
        let entry = PlaylistEntry(context: context)
        entry.id = UUID()
        entry.song = song
        entry.playlist = self
        entry.position = Int64(entries.count)
    }

    /// Rewrites `position` on every entry so it matches the given order.
    func reorder(to songs: [Song]) {
        var byID: [UUID: PlaylistEntry] = [:]
        for entry in entries {
            if let songID = entry.song?.id { byID[songID] = entry }
        }
        for (index, song) in songs.enumerated() {
            byID[song.id]?.position = Int64(index)
        }
    }

    func remove(atOffsets offsets: IndexSet) {
        guard let context = managedObjectContext else { return }
        let ordered = orderedEntries
        for index in offsets {
            context.delete(ordered[index])
        }
        let remaining = ordered.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        for (index, entry) in remaining.enumerated() {
            entry.position = Int64(index)
        }
    }
}

extension PlaylistEntry {
    static func fetchRequest() -> NSFetchRequest<PlaylistEntry> {
        NSFetchRequest<PlaylistEntry>(entityName: "PlaylistEntry")
    }
}
