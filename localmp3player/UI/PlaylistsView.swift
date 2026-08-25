import CoreData
import SwiftUI

struct PlaylistsView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme

    @FetchRequest(fetchRequest: LibraryQuery.allSmartPlaylists()) private var smartPlaylists: FetchedResults<SmartPlaylist>
    @FetchRequest(fetchRequest: LibraryQuery.allPlaylists()) private var playlists: FetchedResults<Playlist>

    @State private var playlistEditorTarget: PlaylistEditor.Target?
    @State private var editorTarget: SmartPlaylistEditor.Target?
    @State private var editMode: EditMode = .inactive
    /// One set for both kinds — playlist UUIDs don't collide across entities.
    @State private var selection = Set<UUID>()
    @State private var confirmingDelete = false
    @State private var pendingSmartDelete: SmartPlaylist?
    @State private var pendingPlaylistDelete: Playlist?
    @State private var smartTarget: SmartPlaylist?
    @State private var manualTarget: Playlist?
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                // Sections are dropped entirely when a search rules them out, so
                // a search never leaves a header standing over nothing.
                if !isSearching || !filteredSmartPlaylists.isEmpty {
                    Section("Smart Playlists") {
                        ForEach(filteredSmartPlaylists) { playlist in
                            DisclosureRow(isSelecting: isSelecting) {
                                navigate { smartTarget = playlist }
                            } label: {
                                SmartPlaylistRow(playlist: playlist)
                            }
                            .tag(playlist.id)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pendingSmartDelete = playlist } label: {
                                    Label("Delete", systemImage: AppSymbol.delete)
                                }
                                Button { editorTarget = .existing(playlist) } label: {
                                    Label("Edit", systemImage: AppSymbol.edit)
                                }
                                .tint(.indigo)
                            }
                        }
                        // Not a result, so it stays out of the way while searching.
                        if !isSelecting && !isSearching {
                            Button {
                                editorTarget = .new
                            } label: {
                                Label("New Smart Playlist", systemImage: "wand.and.stars")
                            }
                            .accentAction(theme)
                        }
                    }
                    .listRowBackground(theme.background)
                }

                if !isSearching || !filteredPlaylists.isEmpty {
                    Section("Playlists") {
                        ForEach(filteredPlaylists) { playlist in
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
                                Button(role: .destructive) { pendingPlaylistDelete = playlist } label: {
                                    Label("Delete", systemImage: AppSymbol.delete)
                                }
                                Button { playlistEditorTarget = .existing(playlist) } label: {
                                    Label("Edit", systemImage: AppSymbol.edit)
                                }
                                .tint(.indigo)
                            }
                        }
                        if !isSelecting && !isSearching {
                            Button {
                                playlistEditorTarget = .new
                            } label: {
                                Label("New Playlist", systemImage: "plus")
                            }
                            .accentAction(theme)
                        }
                    }
                    .listRowBackground(theme.background)
                }
            }
            // Flat rows on the themed background, the same as the Library.
            .listStyle(.plain)
            .themedScrollBackground(theme)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Playlists and smart playlists"
            )
            .overlay {
                if isSearching, filteredSmartPlaylists.isEmpty, filteredPlaylists.isEmpty {
                    ContentUnavailableView.search(text: trimmedSearch)
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
            .sheet(item: $playlistEditorTarget) { target in
                PlaylistEditor(target: target)
                    .environment(\.managedObjectContext, context)
                    .themedSheet(theme)
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
            .confirmDelete(
                $pendingSmartDelete,
                title: { "Delete \($0.name)?" },
                message: "The rule is deleted. The songs it was matching are untouched."
            ) { delete($0) }
            .confirmDelete(
                $pendingPlaylistDelete,
                title: { "Delete \($0.name)?" },
                message: "The songs themselves are not deleted."
            ) { delete($0) }
            .sheet(item: $editorTarget) { target in
                SmartPlaylistEditor(target: target)
                    .environment(\.managedObjectContext, context)
                    .environment(\.uiMode, uiMode)
                    .themedSheet(theme)
            }
        }
    }

    private var isSelecting: Bool { editMode.isEditing }

    private var isSearching: Bool { !trimmedSearch.isEmpty }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// Both kinds are searched together — as far as finding something goes they
    /// are one list — and stay in their own sections so it's still obvious which
    /// is which.
    private var filteredSmartPlaylists: [SmartPlaylist] {
        guard isSearching else { return Array(smartPlaylists) }
        return smartPlaylists.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    private var filteredPlaylists: [Playlist] {
        guard isSearching else { return Array(playlists) }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearch) }
    }

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
                Label("Delete", systemImage: AppSymbol.delete)
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

/// Create or rename a manual playlist. Mirrors `SmartPlaylistEditor`'s shape —
/// nothing is written until Save, so Cancel is always just a dismiss, and both
/// creation and rename share one screen instead of a system alert.
struct PlaylistEditor: View {
    enum Target: Identifiable {
        case new
        case existing(Playlist)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let playlist): return playlist.objectID.uriRepresentation().absoluteString
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.managedObjectContext) private var context
    let target: Target

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                .listRowBackground(theme.surface)
            }
            .themedScrollBackground(theme)
            .navigationTitle(isNew ? "New Playlist" : "Rename Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private func load() {
        switch target {
        case .new: name = ""
        case .existing(let playlist): name = playlist.name
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch target {
        case .new:
            let playlist = Playlist(context: context)
            playlist.id = UUID()
            playlist.name = trimmed
            playlist.dateCreated = Date()
        case .existing(let playlist):
            playlist.name = trimmed
        }
        PersistenceController.shared.save()
    }
}

struct SmartPlaylistRow: View {
    @ObservedObject var playlist: SmartPlaylist

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: playlist.ruleIcon)
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
    @Environment(\.theme) private var theme
    @EnvironmentObject private var playback: PlaybackController
    @ObservedObject var playlist: Playlist
    @State private var showingPicker = false
    @State private var showingPlayer = false
    /// Owned here rather than left to `EditButton` so the rename action can
    /// appear alongside Done while the list is being edited.
    @State private var editMode: EditMode = .inactive
    @State private var renaming = false
    @State private var editing: Song?

    var body: some View {
        List {
            ForEach(playlist.orderedEntries) { entry in
                if let song = entry.song {
                    SongRow(song: song, isSelected: false, isSelecting: false)
                        .listRowBackground(theme.background)
                        .contentShape(Rectangle())
                        .onTapGesture { play(from: entry) }
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
                            // Removes the song from this playlist rather than from
                            // the library, so it doesn't go through the delete
                            // confirmation — nothing is destroyed.
                            Button(role: .destructive) { remove(entry) } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                            Button { editing = song } label: {
                                Label("Edit", systemImage: AppSymbol.edit)
                            }
                            .tint(.indigo)
                        }
                }
            }
            .onMove(perform: move)
            .onDelete { offsets in
                playlist.remove(atOffsets: offsets)
                try? context.save()
            }
        }
        // Bound to the list itself. Applied further out it never reached the
        // rows, so tapping Edit changed the button and nothing else.
        .environment(\.editMode, $editMode)
        .listStyle(.plain)
        .themedScrollBackground(theme)
        .navigationTitle(playlist.name)
        .navigationDestination(isPresented: $showingPlayer) {
            NowPlayingView()
        }
        .toolbar {
            // Hand-rolled rather than `EditButton`, which drives the environment
            // value it finds rather than this one — leaving the toolbar unable to
            // tell whether the list was being edited.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(uiMode.animation) {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                } label: {
                    // Symbols rather than words, so this reads as the same Edit
                    // action the swipe on this playlist's own row offers.
                    editMode.isEditing
                        ? Label("Done", systemImage: AppSymbol.done)
                        : Label("Edit", systemImage: AppSymbol.edit)
                }
            }
            // Editing a playlist means its name as much as its running order, so
            // Rename lives with the row reordering rather than behind its own
            // permanent button.
            if editMode.isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { renaming = true } label: { Label("Rename", systemImage: AppSymbol.rename) }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    ShufflePlayButton(sourceName: playlist.name) { playlist.songs }
                        .disabled(playlist.entries.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingPicker = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(isPresented: $renaming) {
            PlaylistEditor(target: .existing(playlist))
                .environment(\.managedObjectContext, context)
                .themedSheet(theme)
        }
        .sheet(item: $editing) { song in
            SongEditor(song: song)
                .environment(\.managedObjectContext, context)
                .themedSheet(theme)
        }
        .sheet(isPresented: $showingPicker) {
            SongPickerView { songs in
                for song in songs { playlist.append(song) }
                try? context.save()
            }
            .environment(\.managedObjectContext, context)
            .themedSheet(theme)
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

    private func remove(_ entry: PlaylistEntry) {
        guard let index = playlist.orderedEntries.firstIndex(of: entry) else { return }
        playlist.remove(atOffsets: IndexSet(integer: index))
        try? context.save()
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
    /// Evaluated into an array rather than handed to the list as a fetch request:
    /// a rule can end in a random sample, and no single request expresses that.
    /// Re-run whenever the store changes, so the list still reacts to edits made
    /// from this screen.
    @State private var matches: [Song] = []
    @State private var editorTarget: SmartPlaylistEditor.Target?

    var body: some View {
        SongListContent(
            songs: matches,
            selection: $selection,
            isSelecting: false,
            sourceName: playlist.name
        )
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .modeNavigationChrome(uiMode, theme: theme)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShufflePlayButton(sourceName: playlist.name) { matches }
            }
            ToolbarItem(placement: .topBarTrailing) {
                PlayAllButton(sourceName: playlist.name) { matches }
            }
            // The rule is the only thing there is to edit here, and reaching it
            // meant backing out to the list first.
            ToolbarItem(placement: .topBarTrailing) {
                Button { editorTarget = .existing(playlist) } label: {
                    Label("Edit Rule", systemImage: AppSymbol.edit)
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            SmartPlaylistEditor(target: target)
                .environment(\.managedObjectContext, context)
                .environment(\.uiMode, uiMode)
                .themedSheet(theme)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave, object: context)) { _ in
            refresh()
        }
    }

    private func refresh() {
        matches = SmartPlaylistEngine.songs(for: playlist, in: context)
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
                .listRowBackground(theme.background)
                .contentShape(Rectangle())
                .onTapGesture {
                    if selection.contains(song.id) { selection.remove(song.id) } else { selection.insert(song.id) }
                }
            }
            .listStyle(.plain)
            .themedScrollBackground(theme)
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
