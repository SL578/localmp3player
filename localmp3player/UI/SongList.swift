import CoreData
import SwiftUI

/// What removing a song *from this list* means.
///
/// The library owns its songs, so removing one there deletes the imported file
/// and goes through a confirmation. A tag or a playlist only holds a reference,
/// so removing one there detaches it and destroys nothing — which is why it
/// doesn't ask first.
enum SongRemoval {
    case deleteFromLibrary
    case detach(label: String, perform: (Song) -> Void)
}

/// Shared list body — the same view backs the library, playlists, tags, and
/// smart playlists so row behavior only exists in one place.
struct SongListContent: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.theme) private var theme
    @EnvironmentObject private var playback: PlaybackController

    @FetchRequest private var fetched: FetchedResults<Song>
    /// Set when the caller supplies the songs itself, for lists whose contents
    /// can't be expressed as a single fetch — a smart playlist's random sample,
    /// for one.
    private let suppliedSongs: [Song]?
    @Binding var selection: Set<UUID>
    let isSelecting: Bool
    let sourceName: String
    let removal: SongRemoval

    @State private var editing: Song?
    @State private var pendingDelete: Song?

    init(
        request: NSFetchRequest<Song>,
        selection: Binding<Set<UUID>>,
        isSelecting: Bool,
        sourceName: String,
        removal: SongRemoval = .deleteFromLibrary
    ) {
        _fetched = FetchRequest(fetchRequest: request, animation: nil)
        suppliedSongs = nil
        _selection = selection
        self.isSelecting = isSelecting
        self.sourceName = sourceName
        self.removal = removal
    }

    init(
        songs: [Song],
        selection: Binding<Set<UUID>>,
        isSelecting: Bool,
        sourceName: String,
        removal: SongRemoval = .deleteFromLibrary
    ) {
        _fetched = FetchRequest(fetchRequest: LibraryQuery.noSongs(), animation: nil)
        suppliedSongs = songs
        _selection = selection
        self.isSelecting = isSelecting
        self.sourceName = sourceName
        self.removal = removal
    }

    /// The songs currently on screen, which is what gets queued on tap.
    var visibleSongs: [Song] { suppliedSongs ?? Array(fetched) }

    var body: some View {
        List {
            if visibleSongs.isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "music.note",
                    description: Text("Import mp3 files from the Files app to get started.")
                )
                .listRowSeparator(.hidden)
                .listRowBackground(theme.background)
            }
            ForEach(visibleSongs) { song in
                SongRow(song: song, isSelected: selection.contains(song.id), isSelecting: isSelecting)
                    .listRowBackground(theme.background)
                    .contentShape(Rectangle())
                    .onTapGesture { handleTap(song) }
                    .swipeActions(edge: .leading) {
                        Button { toggleLiked(song) } label: {
                            Label(
                                song.isLiked ? "Unlike" : "Like",
                                systemImage: song.isLiked ? "heart.slash" : "heart"
                            )
                        }
                        .tint(theme.liked)
                    }
                    .swipeActions(edge: .trailing) {
                        trailingActions(for: song)
                    }
            }
        }
        .listStyle(.plain)
        .themedScrollBackground(theme)
        .sheet(item: $editing) { song in
            SongEditor(song: song)
                .environment(\.managedObjectContext, context)
                .themedSheet(theme)
        }
        .confirmDelete(
            $pendingDelete,
            title: { "Delete \($0.title)?" },
            message: "The imported file is removed from the app for good."
        ) { delete($0) }
    }

    /// Removal first, then Edit, so the destructive action stays at the outside
    /// edge wherever this list is used.
    @ViewBuilder
    private func trailingActions(for song: Song) -> some View {
        if case .detach(let label, let perform) = removal {
            Button(role: .destructive) { perform(song) } label: {
                Label(label, systemImage: "minus.circle")
            }
        } else {
            // No `role: .destructive` — see `confirmDelete`. This only raises
            // the prompt, so the row must not animate away.
            Button { pendingDelete = song } label: {
                Label("Delete", systemImage: AppSymbol.delete)
            }
            .tint(.red)
        }
        Button { editing = song } label: {
            Label("Edit", systemImage: AppSymbol.edit)
        }
        .tint(.indigo)
    }

    private func handleTap(_ song: Song) {
        if isSelecting {
            if selection.contains(song.id) { selection.remove(song.id) } else { selection.insert(song.id) }
            return
        }
        guard let index = visibleSongs.firstIndex(of: song) else { return }
        // Play and stay put. The mini bar is the way into the full player, and
        // it is the *only* way, so there is one player screen with one design
        // rather than a pushed copy that looks and exits differently.
        playback.play(songs: visibleSongs, startingAt: index, sourceName: sourceName)
    }

    private func toggleLiked(_ song: Song) {
        song.isLiked.toggle()
        try? context.save()
    }

    private func delete(_ song: Song) {
        playback.forget(song)
        AudioFileStore.delete(relativePath: song.filePath)
        context.delete(song)
        try? context.save()
    }
}

struct SongRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject var song: Song
    let isSelected: Bool
    let isSelecting: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
            }
            ArtworkThumbnail(data: song.artworkData, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(song.subtitle)
                        .font(.caption)
                        .secondaryText()
                        .lineLimit(1)
                    if song.isLiked {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(theme.liked)
                    }
                }
                if !song.tags.isEmpty {
                    TagChipRow(tags: song.sortedTags)
                }
            }
            Spacer(minLength: 4)
            Text(TimeFormatting.duration(song.duration))
                .font(.caption.monospacedDigit())
                .secondaryText()
        }
        .padding(.vertical, 2)
    }
}

struct TagChipRow: View {
    let tags: [Tag]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(4)) { tag in
                TagChip(tag: tag)
            }
            if tags.count > 4 {
                Text("+\(tags.count - 4)")
                    .font(.caption2)
                    .secondaryText()
            }
        }
    }
}

/// One chip, observing its own `Tag`. Reading `tag.colorHex` in the parent
/// instead left recolouring invisible until relaunch: the enclosing `SongRow`
/// observes the *Song*, and recolouring a tag never touches the song, so
/// nothing in that chain invalidated the row.
private struct TagChip: View {
    @ObservedObject var tag: Tag

    var body: some View {
        Text(tag.displayName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background((Color(hex: tag.colorHex) ?? .gray).opacity(0.25), in: Capsule())
    }
}

/// Decodes embedded artwork once per (image, size) and keeps the downsampled
/// result, so scrolling a list doesn't re-decode a full-resolution JPEG per row.
