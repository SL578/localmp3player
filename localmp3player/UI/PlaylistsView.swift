import CoreData
import SwiftUI

struct PlaylistsView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme

    @FetchRequest(fetchRequest: LibraryQuery.allSmartPlaylists()) private var smartPlaylists: FetchedResults<SmartPlaylist>
    @FetchRequest(fetchRequest: LibraryQuery.allPlaylists()) private var playlists: FetchedResults<Playlist>

    /// Bumped by `RootView` when the Playlists tab is tapped while already
    /// showing. See `TagsView.popToRoot`.
    var popToRoot: Int = 0

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
                                // No `role: .destructive` — see `confirmDelete`.
                                // This only raises the prompt, so the row must not
                                // animate away.
                                Button { pendingSmartDelete = playlist } label: {
                                    Label("Delete", systemImage: AppSymbol.delete)
                                }
                                .tint(.red)
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
                                PlaylistRow(playlist: playlist)
                            }
                            .tag(playlist.id)
                            .swipeActions(edge: .trailing) {
                                // No `role: .destructive` — see `confirmDelete`.
                                // This only raises the prompt, so the row must not
                                // animate away.
                                Button { pendingPlaylistDelete = playlist } label: {
                                    Label("Delete", systemImage: AppSymbol.delete)
                                }
                                .tint(.red)
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
            .onChange(of: popToRoot) {
                smartTarget = nil
                manualTarget = nil
            }
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

    /// Everything currently on screen, both kinds together — which is what
    /// Select All should reach, search included.
    private var visibleIDs: Set<UUID> {
        Set(filteredSmartPlaylists.map(\.id)).union(filteredPlaylists.map(\.id))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Leading, the same as the Library and Tags. Select is where you start
        // from, so it sits where the eye starts.
        ToolbarItem(placement: .topBarLeading) {
            Button(isSelecting ? "Done" : "Select") {
                withAnimation(uiMode.animation) {
                    editMode = isSelecting ? .inactive : .active
                }
                selection.removeAll()
            }
            .toolbarTint()
            .disabled(smartPlaylists.isEmpty && playlists.isEmpty)
        }
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                let visible = visibleIDs
                let allSelected = !visible.isEmpty && visible.isSubset(of: selection)
                Button(allSelected ? "Select None" : "Select All") {
                    selection = allSelected ? [] : visible
                }
                .toolbarTint()
                .disabled(visible.isEmpty)
            }
        }
    }

    private var selectionBar: some View {
        SelectionBar(count: selection.count) {
            SelectionAction("Delete", systemImage: AppSymbol.delete, role: .destructive) {
                confirmingDelete = true
            }
        }
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
    @Environment(\.theme) private var theme
    @ObservedObject var playlist: SmartPlaylist

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: playlist.ruleIcon)
                .frame(width: 24)
                // The playlist's own color rather than `.tint`, falling back to
                // the accent — which is what `.tint` resolved to anyway, so an
                // uncolored row is unchanged.
                .foregroundStyle(playlist.tint(theme))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                Text(playlist.ruleSummary)
                    .font(.caption)
                    .secondaryText()
            }
        }
    }
}

/// A manual playlist's row. Given the same shape as `SmartPlaylistRow` — glyph,
/// name, one line of detail — so the two sections read as one list and a color
/// has the same place to land in both.
struct PlaylistRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject var playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .frame(width: 24)
                .foregroundStyle(playlist.tint(theme))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                Text("\(playlist.entries.count) songs")
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
    /// Owned here rather than left to `EditButton` so the rename action can
    /// appear alongside Done while the list is being edited.
    @State private var editMode: EditMode = .inactive
    @State private var renaming = false
    @State private var showingColorPicker = false
    @State private var showingPlaylistPicker = false
    @State private var editing: Song?
    /// Keyed by entry, not by song: a playlist may hold the same song twice, and
    /// selecting one of those two rows must not tick the other.
    @State private var selection = Set<UUID>()

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        List {
            ForEach(playlist.orderedEntries) { entry in
                if let song = entry.song {
                    SongRow(song: song, isSelected: selection.contains(entry.id), isSelecting: isEditing)
                        .listRowBackground(theme.background)
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(entry) }
                        .swipeActions(edge: .leading) {
                            Button {
                                song.isLiked.toggle()
                                try? context.save()
                            } label: {
                                Label(
                                    song.isLiked ? "Unlike" : "Like",
                                    systemImage: song.isLiked ? "heart.slash" : "heart"
                                )
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
            // `onMove` stays — reordering is the other half of editing a
            // playlist — but `onDelete` is gone: its red circles land in the same
            // place as the selection ticks, and swiping a row still offers Remove.
            .onMove(perform: move)
        }
        // Bound to the list itself. Applied further out it never reached the
        // rows, so tapping Edit changed the button and nothing else.
        .environment(\.editMode, $editMode)
        .listStyle(.plain)
        .themedScrollBackground(theme)
        .navigationTitle(playlist.name)
        // Done takes the back button's place while editing, the same as in
        // `TagDetailView` — one way out, and a bar with room for the title.
        .navigationBarBackButtonHidden(editMode.isEditing)
        .toolbar {
            // Hand-rolled rather than `EditButton`, which drives the environment
            // value it finds rather than this one — leaving the toolbar unable to
            // tell whether the list was being edited.
            if editMode.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    ToolbarGlyph("Done", systemImage: AppSymbol.done) {
                        withAnimation(uiMode.animation) { editMode = .inactive }
                        selection.removeAll()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    let visible = Set(playlist.orderedEntries.map(\.id))
                    let allSelected = !visible.isEmpty && visible.isSubset(of: selection)
                    Button(allSelected ? "Select None" : "Select All") {
                        selection = allSelected ? [] : visible
                    }
                    .toolbarTint()
                    .disabled(visible.isEmpty)
                }
                // Editing a playlist means its name as much as its running order,
                // so Rename lives with the row reordering rather than behind its
                // own permanent button.
                ToolbarItem(placement: .topBarTrailing) {
                    ToolbarGlyph("Rename", systemImage: AppSymbol.rename) { renaming = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingColorPicker = true } label: {
                        Circle()
                            .fill(playlist.tint(theme))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1))
                    }
                    .accessibilityLabel("Playlist color, currently \(TagPalette.name(for: playlist.colorHex))")
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    ShufflePlayButton(sourceName: playlist.name) { playlist.songs }
                        .disabled(playlist.entries.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ToolbarGlyph("Add Songs", systemImage: "plus") { showingPicker = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // A symbol rather than a word, so this reads as the same Edit
                    // action the swipe on this playlist's own row offers.
                    ToolbarGlyph("Edit", systemImage: AppSymbol.edit) {
                        withAnimation(uiMode.animation) { editMode = .active }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isEditing && !selection.isEmpty {
                selectionBar
            }
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            PlaylistPickerView(songs: selectedSongs()) { endSelection() }
                .environment(\.managedObjectContext, context)
                .environment(\.uiMode, uiMode)
                .themedSheet(theme)
        }
        .sheet(isPresented: $showingColorPicker) {
            EntityColorPicker(object: playlist)
                .environment(\.managedObjectContext, context)
                .themedSheet(theme)
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

    /// No Delete here: removing a song from a playlist never touches the library.
    private var selectionBar: some View {
        let liked = selectedSongs().allLiked
        return SelectionBar(count: selection.count) {
            SelectionAction("Add to Playlist", systemImage: "text.badge.plus") { showingPlaylistPicker = true }
            SelectionAction(liked ? "Unlike" : "Like", systemImage: liked ? "heart.slash" : "heart") {
                selectedSongs().setLiked(!liked)
            }
            SelectionAction("Remove from Playlist", systemImage: "minus.circle", role: .destructive) {
                removeSelected()
            }
        }
    }

    private func handleTap(_ entry: PlaylistEntry) {
        guard isEditing else {
            play(from: entry)
            return
        }
        if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
    }

    /// The songs behind the selected rows, de-duplicated: two rows can point at
    /// one song, and liking it twice or adding it to a playlist twice is not what
    /// picking both rows means.
    private func selectedSongs() -> [Song] {
        var seen = Set<UUID>()
        return playlist.orderedEntries
            .filter { selection.contains($0.id) }
            .compactMap(\.song)
            .filter { seen.insert($0.id).inserted }
    }

    private func removeSelected() {
        let offsets = IndexSet(
            playlist.orderedEntries.enumerated()
                .filter { selection.contains($0.element.id) }
                .map(\.offset)
        )
        playlist.remove(atOffsets: offsets)
        endSelection()
        PersistenceController.shared.save()
    }

    private func endSelection() {
        selection.removeAll()
        editMode = .inactive
    }

    private func play(from entry: PlaylistEntry) {
        let songs = playlist.songs
        guard let index = songs.firstIndex(where: { $0.id == entry.song?.id }) else { return }
        // Play and stay put; the mini bar is the single way into the full
        // player. The queue is still this playlist's songs and nothing else.
        playback.play(songs: songs, startingAt: index, sourceName: playlist.name)
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
        // Large, matching a playlist's — see `TagDetailView`.
        .modeNavigationChrome(uiMode, theme: theme, title: .large)
        .toolbar {
            // Shuffle only. Play All queued the same songs in the order already
            // on screen, which tapping the first row does.
            ToolbarItem(placement: .topBarTrailing) {
                ShufflePlayButton(sourceName: playlist.name) { matches }
            }
            // The rule is the only thing there is to edit here, and reaching it
            // meant backing out to the list first.
            ToolbarItem(placement: .topBarTrailing) {
                ToolbarGlyph("Edit Rule", systemImage: AppSymbol.edit) {
                    editorTarget = .existing(playlist)
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
