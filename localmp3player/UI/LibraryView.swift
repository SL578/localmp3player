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
    @State private var showingPlaylistPicker = false
    @State private var confirmingDelete = false

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
                .themedSheet(theme)
        }
        .sheet(isPresented: $showingBatchTags) {
            BatchTagEditor(songIDs: selection) { endSelection() }
                .environment(\.managedObjectContext, context)
                .environment(\.uiMode, uiMode)
                .themedSheet(theme)
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            PlaylistPickerView(songs: selectedSongs()) { endSelection() }
                .environment(\.managedObjectContext, context)
                .environment(\.uiMode, uiMode)
                .themedSheet(theme)
        }
        .confirmationDialog(
            "Delete \(selection.count) song\(selection.count == 1 ? "" : "s")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: deleteSelected)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The imported files are removed from the app for good.")
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
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                let visible = currentSongs()
                let allSelected = !visible.isEmpty && selection.count == visible.count
                Button(allSelected ? "Select None" : "Select All") {
                    selection = allSelected ? [] : Set(visible.map(\.id))
                }
                .disabled(visible.isEmpty)
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
                // A `Label` here renders with no glyph at all inside a `Menu` — the
                // control stays tappable but invisible. A bare `Image` draws
                // reliably, but unlike a `Button`'s label it doesn't pick up the
                // root `.tint` on its own, which is why this stayed system
                // black/white instead of matching Shuffle and Import. Foreground
                // is set explicitly instead.
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(theme.accent)
            }
            .accessibilityLabel("Sort")
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
        HStack(spacing: 4) {
            Text("\(selection.count) selected")
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            action("Tag", systemImage: "tag") { showingBatchTags = true }
            action("Add to Playlist", systemImage: "text.badge.plus") { showingPlaylistPicker = true }
            action(allSelectionLiked ? "Unlike" : "Like",
                   systemImage: allSelectionLiked ? "heart.slash" : "heart") {
                setLiked(!allSelectionLiked)
            }
            action("Delete", systemImage: AppSymbol.delete, role: .destructive) { confirmingDelete = true }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .modePanelBackground(uiMode, theme: theme)
    }

    private func action(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        perform: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: perform) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }

    /// The songs behind the current selection, in the list's own order.
    private func selectedSongs() -> [Song] {
        currentSongs().filter { selection.contains($0.id) }
    }

    private var allSelectionLiked: Bool {
        let songs = selectedSongs()
        return !songs.isEmpty && songs.allSatisfy(\.isLiked)
    }

    private func setLiked(_ liked: Bool) {
        for song in selectedSongs() { song.isLiked = liked }
        PersistenceController.shared.save()
    }

    private func deleteSelected() {
        for song in selectedSongs() {
            playback.forget(song)
            AudioFileStore.delete(relativePath: song.filePath)
            context.delete(song)
        }
        endSelection()
        PersistenceController.shared.save()
    }

    private func endSelection() {
        selection.removeAll()
        isSelecting = false
    }
}

/// Adds a multi-selection to one manual playlist.
struct PlaylistPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.theme) private var theme
    @FetchRequest(fetchRequest: LibraryQuery.allPlaylists()) private var playlists: FetchedResults<Playlist>

    let songs: [Song]
    let onFinish: () -> Void

    @State private var newPlaylistName = ""
    @State private var showingNewPlaylist = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingNewPlaylist = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                    .accentAction(theme)
                }
                .listRowBackground(theme.surface)
                Section("Playlists") {
                    if playlists.isEmpty {
                        Text("No playlists yet.").secondaryText()
                    }
                    ForEach(playlists) { playlist in
                        Button {
                            add(to: playlist)
                        } label: {
                            HStack {
                                Text(playlist.name)
                                Spacer()
                                Text("\(playlist.entries.count)")
                                    .font(.caption)
                                    .secondaryText()
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
                .listRowBackground(theme.surface)
            }
            .themedScrollBackground(theme)
            .navigationTitle("Add \(songs.count) Song\(songs.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingNewPlaylist) {
                NavigationStack {
                    Form {
                        Section {
                            TextField("Name", text: $newPlaylistName)
                        }
                        .listRowBackground(theme.surface)
                    }
                    .themedScrollBackground(theme)
                    .themedSheet(theme)
                    .navigationTitle("New Playlist")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                newPlaylistName = ""
                                showingNewPlaylist = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Create", action: createAndAdd)
                                .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func add(to playlist: Playlist) {
        for song in songs { playlist.append(song) }
        PersistenceController.shared.save()
        onFinish()
        dismiss()
    }

    private func createAndAdd() {
        let trimmed = newPlaylistName.trimmingCharacters(in: .whitespaces)
        newPlaylistName = ""
        guard !trimmed.isEmpty else { return }
        let playlist = Playlist(context: context)
        playlist.id = UUID()
        playlist.name = trimmed
        playlist.dateCreated = Date()
        add(to: playlist)
    }
}

/// Shared list body — the same view backs the library, playlists, tags, and
/// smart playlists so row behavior only exists in one place.
struct SongListContent: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.theme) private var theme
    @Environment(\.uiMode) private var uiMode
    @EnvironmentObject private var playback: PlaybackController

    @FetchRequest private var fetched: FetchedResults<Song>
    /// Set when the caller supplies the songs itself, for lists whose contents
    /// can't be expressed as a single fetch — a smart playlist's random sample,
    /// for one.
    private let suppliedSongs: [Song]?
    @Binding var selection: Set<UUID>
    let isSelecting: Bool
    let sourceName: String

    @State private var showingPlayer = false
    @State private var editing: Song?
    @State private var pendingDelete: Song?

    init(request: NSFetchRequest<Song>, selection: Binding<Set<UUID>>, isSelecting: Bool, sourceName: String) {
        _fetched = FetchRequest(fetchRequest: request, animation: nil)
        suppliedSongs = nil
        _selection = selection
        self.isSelecting = isSelecting
        self.sourceName = sourceName
    }

    init(songs: [Song], selection: Binding<Set<UUID>>, isSelecting: Bool, sourceName: String) {
        _fetched = FetchRequest(fetchRequest: LibraryQuery.noSongs(), animation: nil)
        suppliedSongs = songs
        _selection = selection
        self.isSelecting = isSelecting
        self.sourceName = sourceName
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
                        Button {
                            song.isLiked.toggle()
                            try? context.save()
                        } label: {
                            Label(song.isLiked ? "Unlike" : "Like", systemImage: song.isLiked ? "heart.slash" : "heart")
                        }
                        .tint(theme.liked)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = song } label: {
                            Label("Delete", systemImage: AppSymbol.delete)
                        }
                        Button { editing = song } label: {
                            Label("Edit", systemImage: AppSymbol.edit)
                        }
                        .tint(.indigo)
                    }
            }
        }
        .listStyle(.plain)
        .themedScrollBackground(theme)
        .navigationDestination(isPresented: $showingPlayer) {
            NowPlayingView()
        }
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

    private func handleTap(_ song: Song) {
        if isSelecting {
            if selection.contains(song.id) { selection.remove(song.id) } else { selection.insert(song.id) }
            return
        }
        guard let index = visibleSongs.firstIndex(of: song) else { return }
        playback.play(songs: visibleSongs, startingAt: index, sourceName: sourceName)
        // Land on the player for this list, rather than leaving the user to hunt
        // for the mini bar.
        pushPlayer()
    }

    private func pushPlayer() {
        var transaction = Transaction()
        transaction.disablesAnimations = !uiMode.usesAnimation
        withTransaction(transaction) { showingPlayer = true }
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
                .secondaryText()
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
