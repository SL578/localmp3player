import CoreData
import SwiftUI

struct PlaylistsView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme

    @FetchRequest(fetchRequest: LibraryQuery.allSmartPlaylists()) private var smartPlaylists: FetchedResults<SmartPlaylist>
    @FetchRequest(fetchRequest: LibraryQuery.allPlaylists()) private var playlists: FetchedResults<Playlist>

    @State private var newPlaylistName = ""
    @State private var showingNewPlaylist = false
    @State private var editorTarget: SmartPlaylistEditor.Target?
    @State private var editMode: EditMode = .inactive
    /// One set for both kinds — playlist UUIDs don't collide across entities.
    @State private var selection = Set<UUID>()
    @State private var confirmingDelete = false
    @State private var smartTarget: SmartPlaylist?
    @State private var manualTarget: Playlist?

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                Section("Smart Playlists") {
                    ForEach(smartPlaylists) { playlist in
                        DisclosureRow(isSelecting: isSelecting) {
                            navigate { smartTarget = playlist }
                        } label: {
                            SmartPlaylistRow(playlist: playlist)
                        }
                        .tag(playlist.id)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(playlist) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { editorTarget = .existing(playlist) } label: {
                                Label("Edit", systemImage: "slider.horizontal.3")
                            }
                            .tint(.indigo)
                        }
                    }
                    if !isSelecting {
                        Button {
                            editorTarget = .new
                        } label: {
                            Label("New Smart Playlist", systemImage: "wand.and.stars")
                        }
                    }
                }

                Section("Playlists") {
                    ForEach(playlists) { playlist in
                        DisclosureRow(isSelecting: isSelecting) {
                            navigate { manualTarget = playlist }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                Text("\(playlist.entries.count) songs")
                                    .font(.caption)
                                    .secondaryText()
                            }
                        }
                        .tag(playlist.id)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(playlist) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    if !isSelecting {
                        Button {
                            showingNewPlaylist = true
                        } label: {
                            Label("New Playlist", systemImage: "plus")
                        }
                    }
                }
            }
            .navigationTitle("Playlists")
            .navigationDestination(item: $smartTarget) { SmartPlaylistDetailView(playlist: $0) }
            .navigationDestination(item: $manualTarget) { PlaylistDetailView(playlist: $0) }
            .environment(\.editMode, $editMode)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if isSelecting && !selection.isEmpty {
                    selectionBar
                }
            }
            .alert("New Playlist", isPresented: $showingNewPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
                Button("Create", action: createPlaylist)
            }
            .confirmationDialog(
                "Delete \(selection.count) playlist\(selection.count == 1 ? "" : "s")?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: deleteSelected)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The songs themselves are not deleted.")
            }
            .sheet(item: $editorTarget) { target in
                SmartPlaylistEditor(target: target)
                    .environment(\.managedObjectContext, context)
                    .environment(\.uiMode, uiMode)
            }
        }
    }

    private var isSelecting: Bool { editMode.isEditing }

    /// Performance mode pushes without a transition.
    private func navigate(_ action: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = !uiMode.usesAnimation
        withTransaction(transaction, action)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(isSelecting ? "Done" : "Select") {
                withAnimation(uiMode.animation) {
                    editMode = isSelecting ? .inactive : .active
                }
                selection.removeAll()
            }
            .disabled(smartPlaylists.isEmpty && playlists.isEmpty)
        }
    }

    private var selectionBar: some View {
        HStack {
            Text("\(selection.count) selected")
                .font(.subheadline)
            Spacer()
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .modePanelBackground(uiMode, theme: theme)
    }

    private func deleteSelected() {
        for playlist in smartPlaylists where selection.contains(playlist.id) {
            context.delete(playlist)
        }
        for playlist in playlists where selection.contains(playlist.id) {
            context.delete(playlist)
        }
        selection.removeAll()
        editMode = .inactive
        PersistenceController.shared.save()
    }

    private func createPlaylist() {
        let trimmed = newPlaylistName.trimmingCharacters(in: .whitespaces)
        newPlaylistName = ""
        guard !trimmed.isEmpty else { return }
        let playlist = Playlist(context: context)
        playlist.id = UUID()
        playlist.name = trimmed
        playlist.dateCreated = Date()
        try? context.save()
    }

    private func delete(_ playlist: SmartPlaylist) {
        context.delete(playlist)
        PersistenceController.shared.save()
    }

    private func delete(_ playlist: Playlist) {
        context.delete(playlist)
        PersistenceController.shared.save()
    }
}

/// A list row that looks like a `NavigationLink` but drives navigation itself.
///
/// `NavigationLink` inside a `List` puts the row into UIKit's *selected* state and
/// relies on the pop to clear it. `RootView` keeps every tab alive behind an
/// opacity change rather than removing it, so a tab switch stranded that pending
/// deselect and the row stayed grey — still tappable, just permanently
/// highlighted. Owning the tap keeps rows stateless, and lets the caller decide
/// whether the push animates.
struct DisclosureRow<Label: View>: View {
    @Environment(\.theme) private var theme

    let isSelecting: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: { if !isSelecting { action() } }) {
            HStack(spacing: 8) {
                label
                Spacer(minLength: 4)
                if !isSelecting {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.separator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SmartPlaylistRow: View {
    @ObservedObject var playlist: SmartPlaylist

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: playlist.ruleType.systemImage)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                Text(playlist.ruleSummary)
                    .font(.caption)
                    .secondaryText()
            }
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @EnvironmentObject private var playback: PlaybackController
    @ObservedObject var playlist: Playlist
    @State private var showingPicker = false
    @State private var showingPlayer = false

    var body: some View {
        List {
            ForEach(playlist.orderedEntries) { entry in
                if let song = entry.song {
                    SongRow(song: song, isSelected: false, isSelecting: false)
                        .contentShape(Rectangle())
                        .onTapGesture { play(from: entry) }
                }
            }
            .onMove(perform: move)
            .onDelete { offsets in
                playlist.remove(atOffsets: offsets)
                try? context.save()
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.name)
        .navigationDestination(isPresented: $showingPlayer) {
            NowPlayingView()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                ShufflePlayButton(sourceName: playlist.name) { playlist.songs }
                    .disabled(playlist.entries.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingPicker = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingPicker) {
            SongPickerView { songs in
                for song in songs { playlist.append(song) }
                try? context.save()
            }
            .environment(\.managedObjectContext, context)
        }
        .overlay {
            if playlist.entries.isEmpty {
                ContentUnavailableView("Empty Playlist", systemImage: "music.note.list", description: Text("Tap + to add songs."))
            }
        }
    }

    private func play(from entry: PlaylistEntry) {
        let songs = playlist.songs
        guard let index = songs.firstIndex(where: { $0.id == entry.song?.id }) else { return }
        playback.play(songs: songs, startingAt: index, sourceName: playlist.name)
        // Push the player for this playlist so the queue on screen is the
        // playlist's songs and nothing else.
        var transaction = Transaction()
        transaction.disablesAnimations = !uiMode.usesAnimation
        withTransaction(transaction) { showingPlayer = true }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var songs = playlist.songs
        songs.move(fromOffsets: offsets, toOffset: destination)
        playlist.reorder(to: songs)
        try? context.save()
    }
}

struct SmartPlaylistDetailView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme
    @ObservedObject var playlist: SmartPlaylist
    @State private var selection = Set<UUID>()

    var body: some View {
        SongListContent(
            request: SmartPlaylistEngine.fetchRequest(for: playlist, in: context),
            selection: $selection,
            isSelecting: false,
            sourceName: playlist.name
        )
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .modeNavigationChrome(uiMode, theme: theme)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShufflePlayButton(sourceName: playlist.name, songs: matches)
            }
            ToolbarItem(placement: .topBarTrailing) {
                PlayAllButton(sourceName: playlist.name, songs: matches)
            }
        }
    }

    /// Re-evaluated on demand — a smart playlist never holds a fixed song list.
    private func matches() -> [Song] {
        SmartPlaylistEngine.songs(for: playlist, in: context)
    }
}

/// Multi-select song picker, shared by manual playlists and tags.
struct SongPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(fetchRequest: LibraryQuery.allSongs()) private var allSongs: FetchedResults<Song>
    @State private var selection = Set<UUID>()
    @State private var searchText = ""

    var title = "Add Songs"
    /// Songs already in the destination, hidden so the list only offers new ones.
    var excluding: Set<UUID> = []
    let onAdd: ([Song]) -> Void

    private var songs: [Song] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        return allSongs.filter { song in
            guard !excluding.contains(song.id) else { return false }
            guard !trimmed.isEmpty else { return true }
            return song.title.localizedCaseInsensitiveContains(trimmed)
                || song.artist.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            List(songs) { song in
                HStack {
                    Image(systemName: selection.contains(song.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(song.id) ? theme.accent : theme.secondaryText)
                    SongRow(song: song, isSelected: false, isSelecting: false)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selection.contains(song.id) { selection.remove(song.id) } else { selection.insert(song.id) }
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists")
            .overlay {
                if songs.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "Nothing to Add" : "No Matches",
                        systemImage: "music.note",
                        description: Text(searchText.isEmpty ? "Every song is already here." : "Try a different search.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selection.count)") {
                        onAdd(songs.filter { selection.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
    }
}

#Preview {
    PlaylistsView()
        .environment(\.managedObjectContext, PersistenceController.preview.viewContext)
        .environmentObject(PlaybackController.shared)
}
