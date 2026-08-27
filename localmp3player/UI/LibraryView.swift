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
            .toolbarTint()
        }
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                // Membership, not a count: a selection made before the search was
                // narrowed still holds songs that aren't on screen, and comparing
                // counts called that "all selected" while rows sat unticked.
                let visible = Set(currentSongs().map(\.id))
                let allSelected = !visible.isEmpty && visible.isSubset(of: selection)
                Button(allSelected ? "Select None" : "Select All") {
                    selection = allSelected ? [] : visible
                }
                .toolbarTint()
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
                // A `Label` renders with no glyph at all inside a `Menu` — the
                // control stays tappable but invisible — so this draws its own
                // `Image`, coloured the same way every other glyph in the bar is.
                Image(systemName: "arrow.up.arrow.down").toolbarTint()
            }
            .accessibilityLabel("Sort")
        }
        ToolbarItem(placement: .topBarTrailing) {
            ToolbarGlyph("Import", systemImage: "plus") { showingPicker = true }
        }
    }

    private var selectionBar: some View {
        let liked = selectedSongs().allLiked
        return SelectionBar(count: selection.count) {
            SelectionAction("Tag", systemImage: "tag") { showingBatchTags = true }
            SelectionAction("Add to Playlist", systemImage: "text.badge.plus") { showingPlaylistPicker = true }
            SelectionAction(liked ? "Unlike" : "Like", systemImage: liked ? "heart.slash" : "heart") {
                selectedSongs().setLiked(!liked)
            }
            SelectionAction("Delete", systemImage: AppSymbol.delete, role: .destructive) { confirmingDelete = true }
        }
    }

    /// The songs behind the current selection, in the list's own order.
    private func selectedSongs() -> [Song] {
        currentSongs().filter { selection.contains($0.id) }
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
