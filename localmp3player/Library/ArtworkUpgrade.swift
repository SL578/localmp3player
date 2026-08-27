import CoreData
import Foundation

/// Brings cover art already in the library up to the size the app draws it.
///
/// Raising the stored artwork size only helps files imported after the change —
/// everything already in the library keeps the small copy it was saved with, and
/// the imported file is still sitting in `Audio/` with the original picture in
/// it. This is the way back.
///
/// It used to be a button in Settings. It isn't a decision the user has any way
/// to make well ("should my artwork be the right size?" has one answer), so it
/// runs itself once, in the background, on the first launch after the change.
/// Import has stored art at full size since the same change, so there is nothing
/// for it to do on anything imported from here on.
///
/// Songs whose stored copy is already at least `maxPixelSize` are skipped, so
/// the run costs one cheap image-header read per song and nothing else when the
/// library is already current.
@MainActor
enum ArtworkUpgrade {
    /// Set only after a complete pass, so a run interrupted by the app being
    /// killed is picked up again next launch instead of being skipped forever.
    private static let completedKey = "artworkUpgradeCompleted"

    static func runIfNeeded(in context: NSManagedObjectContext) async {
        guard !UserDefaults.standard.bool(forKey: completedKey) else { return }

        let songs = (try? context.fetch(LibraryQuery.allSongs())) ?? []
        for song in songs where needsRefresh(song) {
            let url = AudioFileStore.absoluteURL(for: song.filePath)
            guard let artwork = await MetadataExtractor.artwork(from: url),
                  isLarger(artwork, than: song.artworkData) else { continue }
            song.artworkData = artwork
        }

        if context.hasChanges {
            PersistenceController.shared.save()
        }
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    /// Nil artwork is worth a look too: it may be a song imported before its art
    /// could be read, and the file is the only place that can say.
    private static func needsRefresh(_ song: Song) -> Bool {
        guard let data = song.artworkData else { return true }
        guard let width = ArtworkThumbnailer.pixelWidth(of: data) else { return true }
        return width < ArtworkThumbnailer.maxPixelSize
    }

    /// Guards the write, so a song whose embedded art was *always* smaller than
    /// the cap — or a file with no art at all — is read and then left alone,
    /// rather than rewritten with identical bytes.
    private static func isLarger(_ candidate: Data, than existing: Data?) -> Bool {
        guard let existing else { return true }
        guard let new = ArtworkThumbnailer.pixelWidth(of: candidate) else { return false }
        guard let old = ArtworkThumbnailer.pixelWidth(of: existing) else { return true }
        return new > old
    }
}
