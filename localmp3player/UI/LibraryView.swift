import CoreData
import SwiftUI

struct LibraryView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var importCoordinator: ImportCoordinator

    @State private var searchText = ""
    @State private var selection = Set<UUID>()
    @State private var isSelecting = false
    @State private var showingPicker = false
    @State private var showingBatchTags = false

    var body: some View {
        NavigationStack {
            SongListContent(
                request: LibraryQuery.allSongs(sort: settings.songSort, searchText: searchText),
                selection: $selection,
                isSelecting: isSelecting,
                sourceName: "Library"
            )
            .navigationTitle("Library")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Songs, artists, albums"
            )
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if isSelecting && !selection.isEmpty {
                    selectionBar
                }
            }
            .modeAnimation(uiMode, value: selection.count)
        }
        .sheet(isPresented: $showingPicker) {
            DocumentPicker { urls in
                showingPicker = false
                guard !urls.isEmpty else { return }
                Task { await importCoordinator.stage(urls: urls) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: reviewBinding) {
            ImportReviewView()
                .environmentObject(importCoordinator)
                .environment(\.managedObjectContext, context)
                .environment(\.uiMode, uiMode)
        }
        .sheet(isPresented: $showingBatchTags) {
            BatchTagEditor(songIDs: selection) { selection.removeAll(); isSelecting = false }
                .environment(\.managedObjectContext, context)
                .environment(\.uiMode, uiMode)
        }
        .overlay(alignment: .center) {
            if case .scanning(let done, let total) = importCoordinator.phase {
                ScanningOverlay(completed: done, total: total)
            }
        }
    }

    /// Re-runs the query the list is currently showing, so shuffle respects the
    /// active search and sort.
    private func currentSongs() -> [Song] {
        LibraryQuery.fetch(
            LibraryQuery.allSongs(sort: settings.songSort, searchText: searchText),
            in: context
        )
    }

    private var reviewBinding: Binding<Bool> {
        Binding(
            get: { importCoordinator.isPresentingReview },
            set: { if !$0 { importCoordinator.cancelReview() } }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(isSelecting ? "Done" : "Select") {
                isSelecting.toggle()
                if !isSelecting { selection.removeAll() }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            ShufflePlayButton(sourceName: "Library", songs: currentSongs)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $settings.songSort) {
                    ForEach(SongSort.allCases) { sort in
                        Text(sort.label).tag(sort)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingPicker = true
            } label: {
                Label("Import", systemImage: "plus")
            }
        }
    }

    private var selectionBar: some View {
        HStack {
            Text("\(selection.count) selected")
                .font(.subheadline)
            Spacer()
            Button {
                showingBatchTags = true
            } label: {
                Label("Tags", systemImage: "tag")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .modePanelBackground(uiMode, theme: theme)
    }
}

/// Shared list body — the same view backs the library, playlists, tags, and
/// smart playlists so row behavior only exists in one place.
struct SongListContent: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.theme) private var theme
    @EnvironmentObject private var playback: PlaybackController

    @FetchRequest private var songs: FetchedResults<Song>
    @Binding var selection: Set<UUID>
    let isSelecting: Bool
    let sourceName: String

    @State private var showingPlayer = false

    init(request: NSFetchRequest<Song>, selection: Binding<Set<UUID>>, isSelecting: Bool, sourceName: String) {
        _songs = FetchRequest(fetchRequest: request, animation: nil)
        _selection = selection
        self.isSelecting = isSelecting
        self.sourceName = sourceName
    }

    /// The songs currently on screen, which is what gets queued on tap.
    var visibleSongs: [Song] { Array(songs) }

    var body: some View {
        List {
            if songs.isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "music.note",
                    description: Text("Import mp3 files from the Files app to get started.")
                )
                .listRowSeparator(.hidden)
            }
            ForEach(songs) { song in
                SongRow(song: song, isSelected: selection.contains(song.id), isSelecting: isSelecting)
                    .contentShape(Rectangle())
                    .onTapGesture { handleTap(song) }
                    .swipeActions(edge: .leading) {
                        Button {
                            song.isLiked.toggle()
                            try? context.save()
                        } label: {
                            Label(song.isLiked ? "Unlike" : "Like", systemImage: song.isLiked ? "heart.slash" : "heart")
                        }
                        .tint(theme.liked)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { delete(song) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .navigationDestination(isPresented: $showingPlayer) {
            NowPlayingView()
        }
    }

    private func handleTap(_ song: Song) {
        if isSelecting {
            if selection.contains(song.id) { selection.remove(song.id) } else { selection.insert(song.id) }
            return
        }
        guard let index = songs.firstIndex(of: song) else { return }
        playback.play(songs: visibleSongs, startingAt: index, sourceName: sourceName)
        // Land on the player for this list, rather than leaving the user to hunt
        // for the mini bar.
        showingPlayer = true
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
                        .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct TagChipRow: View {
    let tags: [Tag]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(4)) { tag in
                Text(tag.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background((Color(hex: tag.colorHex) ?? .gray).opacity(0.25), in: Capsule())
            }
            if tags.count > 4 {
                Text("+\(tags.count - 4)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Decodes embedded artwork once per (image, size) and keeps the downsampled
/// result, so scrolling a list doesn't re-decode a full-resolution JPEG per row.
enum ArtworkCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    static func thumbnail(for data: Data, size: CGFloat, scale: CGFloat) -> UIImage? {
        let pixels = max(1, Int((size * scale).rounded()))
        let key = "\(data.count)-\(data.hashValue)-\(pixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let full = UIImage(data: data) else { return nil }
        let target = CGSize(width: CGFloat(pixels), height: CGFloat(pixels))
        let thumbnail = full.preparingThumbnail(of: target) ?? full
        cache.setObject(thumbnail, forKey: key)
        return thumbnail
    }
}

struct ArtworkThumbnail: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.surface)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
    }

    private var image: UIImage? {
        guard let data else { return nil }
        return ArtworkCache.thumbnail(for: data, size: size, scale: displayScale)
    }
}

struct ScanningOverlay: View {
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme
    let completed: Int
    let total: Int

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                .frame(width: 160)
            Text("Reading \(completed) of \(total)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .modeCard(uiMode, theme: theme)
    }
}

#Preview {
    LibraryView()
        .environment(\.managedObjectContext, PersistenceController.preview.viewContext)
        .environmentObject(AppSettings())
        .environmentObject(PlaybackController.shared)
        .environmentObject(ImportCoordinator(context: PersistenceController.preview.viewContext))
}
