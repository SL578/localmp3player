import Combine
import CoreData
import Foundation

/// Re-reads embedded cover art for songs already in the library.
///
/// Raising the stored artwork size only helps files imported after the change —
/// everything already in the library keeps the small copy it was saved with, and
/// the imported file is still sitting in `Audio/` with the original picture in
/// it. This is the way back: a user-initiated pass that re-extracts the art at
/// the current size.
///
/// Songs whose stored copy is already at least `maxPixelSize` are skipped, so
/// running it twice costs one cheap image-header read per song rather than a
/// second full re-extract.
@MainActor
final class ArtworkRefresher: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(completed: Int, total: Int)
        case finished(String)
    }

    @Published private(set) var phase: Phase = .idle

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func run(in context: NSManagedObjectContext) async {
        guard !isRunning else { return }

        let songs = (try? context.fetch(LibraryQuery.allSongs())) ?? []
        let candidates = songs.filter { needsRefresh($0) }
        guard !candidates.isEmpty else {
            phase = .finished("Artwork is already at full quality")
            return
        }

        phase = .running(completed: 0, total: candidates.count)
        var improved = 0

        for (index, song) in candidates.enumerated() {
            let url = AudioFileStore.absoluteURL(for: song.filePath)
            if let artwork = await MetadataExtractor.artwork(from: url), isLarger(artwork, than: song.artworkData) {
                song.artworkData = artwork
                improved += 1
            }
            phase = .running(completed: index + 1, total: candidates.count)
        }

        PersistenceController.shared.save()
        phase = .finished(improved == 0
            ? "Nothing to upgrade — every file's artwork is already stored at its full size"
            : "Upgraded \(improved) song\(improved == 1 ? "" : "s")")
    }

    /// Nil artwork is worth a look too: it may be a song imported before its art
    /// could be read, and the file is the only place that can say.
    private func needsRefresh(_ song: Song) -> Bool {
        guard let data = song.artworkData else { return true }
        guard let width = ArtworkThumbnailer.pixelWidth(of: data) else { return true }
        return width < ArtworkThumbnailer.maxPixelSize
    }

    /// Guards the write, so a song whose embedded art was *always* smaller than
    /// the cap — or a file with no art at all — is read and then left alone. It
    /// stays a candidate on the next run, but a re-run stops being a rewrite of
    /// identical bytes, and the summary can say plainly that nothing improved
    /// rather than counting it as work done.
    private func isLarger(_ candidate: Data, than existing: Data?) -> Bool {
        guard let existing else { return true }
        guard let new = ArtworkThumbnailer.pixelWidth(of: candidate) else { return false }
        guard let old = ArtworkThumbnailer.pixelWidth(of: existing) else { return true }
        return new > old
    }
}
