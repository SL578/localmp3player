import CoreData
import SwiftUI

struct PlaylistsView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode

    @FetchRequest(fetchRequest: LibraryQuery.allSmartPlaylists()) private var smartPlaylists: FetchedResults<SmartPlaylist>
    @FetchRequest(fetchRequest: LibraryQuery.allPlaylists()) private var playlists: FetchedResults<Playlist>

    @State private var newPlaylistName = ""
    @State private var showingNewPlaylist = false
    @State private var editingSmartPlaylist: SmartPlaylist?

    var body: some View {
        NavigationStack {
            List {
                Section("Smart Playlists") {
                    ForEach(smartPlaylists) { playlist in
                        NavigationLink {
                            SmartPlaylistDetailView(playlist: playlist)
                        } label: {
                            SmartPlaylistRow(playlist: playlist)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(playlist) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { editingSmartPlaylist = playlist } label: {
                                Label("Edit", systemImage: "slider.horizontal.3")
                            }
                            .tint(.indigo)
                        }
                    }
                    Button {
                        editingSmartPlaylist = makeSmartPlaylist()
                    } label: {
                        Label("New Smart Playlist", systemImage: "wand.and.stars")
                    }
                }

                Section("Playlists") {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                Text("\(playlist.entries.count) songs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deletePlaylists)
                    Button {
                        showingNewPlaylist = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Playlists")
            .alert("New Playlist", isPresented: $showingNewPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
                Button("Create", action: createPlaylist)
            }
            .sheet(item: $editingSmartPlaylist) { playlist in
                SmartPlaylistEditor(playlist: playlist)
                    .environment(\.managedObjectContext, context)
                    .environment(\.uiMode, uiMode)
            }
        }
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

    private func makeSmartPlaylist() -> SmartPlaylist {
        let playlist = SmartPlaylist(context: context)
        playlist.id = UUID()
        playlist.name = "New Smart Playlist"
        playlist.dateCreated = Date()
        playlist.ruleType = .recentlyAdded
        playlist.resultLimitValue = 50
        return playlist
    }

    private func delete(_ playlist: SmartPlaylist) {
        context.delete(playlist)
        try? context.save()
    }

    private func deletePlaylists(at offsets: IndexSet) {
        for index in offsets { context.delete(playlists[index]) }
        try? context.save()
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
                    .foregroundStyle(.secondary)
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
        showingPlayer = true
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

/// Multi-select song picker used when adding to a manual playlist.
struct SongPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(fetchRequest: LibraryQuery.allSongs()) private var songs: FetchedResults<Song>
    @State private var selection = Set<UUID>()

    let onAdd: ([Song]) -> Void

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
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
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
