import CoreData
import SwiftUI

struct TagsView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme
    @FetchRequest(fetchRequest: LibraryQuery.allTags()) private var tags: FetchedResults<Tag>

    @State private var editorTarget: TagEditor.Target?
    @State private var pendingDelete: Tag?
    @State private var target: Tag?
    @State private var searchText = ""
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(filteredTags) { tag in
                    DisclosureRow(isSelecting: isSelecting) {
                        navigate { target = tag }
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: tag.colorHex) ?? .gray)
                                .frame(width: 12, height: 12)
                            Text(tag.displayName)
                            Spacer()
                            Text("\(tag.songs.count)")
                                .font(.caption)
                                .secondaryText()
                        }
                    }
                    .tag(tag.id)
                    .listRowBackground(theme.background)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = tag } label: {
                            Label("Delete", systemImage: AppSymbol.delete)
                        }
                        Button { editorTarget = .existing(tag) } label: {
                            Label("Edit", systemImage: AppSymbol.edit)
                        }
                        .tint(.indigo)
                    }
                }
            }
            // Flat rows on the themed background, the same as the Library.
            .listStyle(.plain)
            .themedScrollBackground(theme)
            .navigationTitle("Tags")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Tags")
            .navigationDestination(item: $target) { TagDetailView(tag: $0) }
            .environment(\.editMode, $editMode)
            .overlay {
                if isSearching, filteredTags.isEmpty {
                    ContentUnavailableView.search(text: trimmedSearch)
                } else if tags.isEmpty {
                    ContentUnavailableView("No Tags", systemImage: "tag", description: Text("Tags let you build smart playlists and browse quickly in CarPlay."))
                }
            }
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if isSelecting && !selection.isEmpty {
                    selectionBar
                }
            }
            .sheet(item: $editorTarget) { target in
                TagEditor(target: target)
                    .environment(\.managedObjectContext, context)
                    .themedSheet(theme)
            }
            .confirmationDialog(
                "Delete \(selection.count) tag\(selection.count == 1 ? "" : "s")?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: deleteSelected)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The tags come off every song that has them. The songs themselves are kept.")
            }
            .confirmDelete(
                $pendingDelete,
                title: { "Delete \($0.displayName)?" },
                message: "The tag is removed from every song that has it. The songs themselves are kept."
            ) { delete($0) }
        }
    }

    private var isSelecting: Bool { editMode.isEditing }

    private var isSearching: Bool { !trimmedSearch.isEmpty }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var filteredTags: [Tag] {
        guard isSearching else { return Array(tags) }
        return tags.filter { $0.displayName.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    /// Performance mode pushes without a transition.
    private func navigate(_ action: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = !uiMode.usesAnimation
        withTransaction(transaction, action)
    }

    /// Placed leading, the same as the Library and Playlists.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(isSelecting ? "Done" : "Select") {
                withAnimation(uiMode.animation) {
                    editMode = isSelecting ? .inactive : .active
                }
                selection.removeAll()
            }
            .disabled(tags.isEmpty)
        }
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                let visible = Set(filteredTags.map(\.id))
                let allSelected = !visible.isEmpty && visible.isSubset(of: selection)
                Button(allSelected ? "Select None" : "Select All") {
                    selection = allSelected ? [] : visible
                }
                .disabled(visible.isEmpty)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { editorTarget = .new } label: { Image(systemName: "plus") }
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
        for tag in tags where selection.contains(tag.id) {
            context.delete(tag)
        }
        selection.removeAll()
        editMode = .inactive
        PersistenceController.shared.save()
    }

    private func delete(_ tag: Tag) {
        context.delete(tag)
        PersistenceController.shared.save()
    }
}

/// Create or rename a tag. Mirrors `PlaylistEditor`/`SmartPlaylistEditor` — a
/// proper Form sheet with Cancel on the left and a single confirm action, rather
/// than a system alert whose two buttons both render in the accent color with no
/// visual distinction between them.
struct TagEditor: View {
    enum Target: Identifiable {
        case new
        case existing(Tag)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let tag): return tag.objectID.uriRepresentation().absoluteString
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(fetchRequest: LibraryQuery.allTags()) private var tags: FetchedResults<Tag>

    let target: Target

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                } footer: {
                    if collidesWithAnotherTag {
                        Text("A tag called “\(trimmedName)” already exists.")
                    } else if !isNew {
                        Text("Songs keep this tag — only what it's called changes.")
                    }
                }
                .listRowBackground(theme.surface)
            }
            .themedScrollBackground(theme)
            .navigationTitle(isNew ? "New Tag" : "Rename Tag")
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
                    .disabled(trimmedName.isEmpty || collidesWithAnotherTag)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    /// Tag names are unique in the store, so a rename onto an existing name would
    /// fail the constraint at save time. Caught here instead, while there's still
    /// something useful to say about it.
    private var collidesWithAnotherTag: Bool {
        let canonical = Tag.canonical(trimmedName)
        guard !canonical.isEmpty else { return false }
        return tags.contains { $0.name == canonical && $0.id != editingTag?.id }
    }

    private var editingTag: Tag? {
        if case .existing(let tag) = target { return tag }
        return nil
    }

    private func load() {
        name = editingTag?.displayName ?? ""
    }

    private func save() {
        if let tag = editingTag {
            tag.displayName = trimmedName
            tag.name = Tag.canonical(trimmedName)
        } else {
            Tag.findOrCreate(named: trimmedName, in: context)
        }
        PersistenceController.shared.save()
    }
}

struct TagDetailView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme
    @ObservedObject var tag: Tag
    @State private var selection = Set<UUID>()
    @State private var isSelecting = false
    @State private var showingColorPicker = false
    @State private var showingSongPicker = false
    @State private var showingPlaylistPicker = false

    var body: some View {
        SongListContent(
            request: LibraryQuery.songs(taggedWith: tag),
            selection: $selection,
            isSelecting: isSelecting,
            sourceName: tag.displayName,
            // This screen is a view of one tag's membership, not of the library.
            // Deleting the song outright from here was destroying the file over
            // what reads as "take it out of this tag".
            removal: .detach(label: "Remove") { song in
                song.removeTag(tag)
                PersistenceController.shared.save()
            }
        )
        .navigationTitle(tag.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .modeNavigationChrome(uiMode, theme: theme)
        .toolbar {
            // Leading, next to the back button — the trailing side is already
            // three controls deep, and this matches where Select sits everywhere
            // else.
            ToolbarItem(placement: .topBarLeading) {
                Button(isSelecting ? "Done" : "Select") {
                    withAnimation(uiMode.animation) { isSelecting.toggle() }
                    if !isSelecting { selection.removeAll() }
                }
                .disabled(tag.songs.isEmpty)
            }
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    let visible = Set(taggedSongs().map(\.id))
                    let allSelected = !visible.isEmpty && visible.isSubset(of: selection)
                    Button(allSelected ? "Select None" : "Select All") {
                        selection = allSelected ? [] : visible
                    }
                    .disabled(visible.isEmpty)
                }
            }
            // Stood down while selecting: none of them act on a selection, and
            // leaving them up pushed the bar past what fits, which iOS resolved by
            // folding them into an anonymous "..." menu.
            if !isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    ShufflePlayButton(sourceName: tag.displayName) { taggedSongs() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSongPicker = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add songs to this tag")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingColorPicker = true } label: {
                        // Show the tag's actual color, so the button says what it does.
                        Circle()
                            .fill(Color(hex: tag.colorHex) ?? .gray)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1))
                    }
                    .accessibilityLabel("Tag color, currently \(TagPalette.name(for: tag.colorHex))")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !selection.isEmpty {
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
            TagColorPicker(tag: tag)
                .environment(\.managedObjectContext, context)
                .themedSheet(theme)
        }
        .sheet(isPresented: $showingSongPicker) {
            SongPickerView(
                title: "Add to \(tag.displayName)",
                excluding: Set(tag.songs.map(\.id))
            ) { songs in
                for song in songs { song.addTag(tag) }
                PersistenceController.shared.save()
            }
            .environment(\.managedObjectContext, context)
            .themedSheet(theme)
        }
        .overlay {
            if tag.songs.isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "tag",
                    description: Text("Tap + to add songs to this tag.")
                )
            }
        }
    }

    /// No Delete here on purpose: removing songs from a tag never touches the
    /// library, so this bar has nothing destructive on it.
    private var selectionBar: some View {
        HStack(spacing: 4) {
            Text("\(selection.count) selected")
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            SelectionAction("Add to Playlist", systemImage: "text.badge.plus") { showingPlaylistPicker = true }
            SelectionAction(allSelectionLiked ? "Unlike" : "Like",
                            systemImage: allSelectionLiked ? "heart.slash" : "heart") {
                setLiked(!allSelectionLiked)
            }
            SelectionAction("Remove from Tag", systemImage: "minus.circle", role: .destructive) {
                removeSelectedFromTag()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .modePanelBackground(uiMode, theme: theme)
    }

    private func taggedSongs() -> [Song] {
        LibraryQuery.fetch(LibraryQuery.songs(taggedWith: tag), in: context)
    }

    private func selectedSongs() -> [Song] {
        taggedSongs().filter { selection.contains($0.id) }
    }

    private var allSelectionLiked: Bool {
        let songs = selectedSongs()
        return !songs.isEmpty && songs.allSatisfy(\.isLiked)
    }

    private func setLiked(_ liked: Bool) {
        for song in selectedSongs() { song.isLiked = liked }
        PersistenceController.shared.save()
    }

    private func removeSelectedFromTag() {
        for song in selectedSongs() { song.removeTag(tag) }
        endSelection()
        PersistenceController.shared.save()
    }

    private func endSelection() {
        selection.removeAll()
        isSelecting = false
    }
}

/// Picks the color used for this tag's chips in the library and in CarPlay.
struct TagColorPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.theme) private var theme
    @ObservedObject var tag: Tag

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 16)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(TagPalette.swatches) { swatch in
                            swatchButton(swatch)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Preset colors")
                }
                .listRowBackground(theme.surface)

                Section {
                    ColorPicker("Custom color", selection: customBinding, supportsOpacity: false)
                } footer: {
                    Text("Tag colors show on song chips and make tags easier to pick out at a glance in CarPlay.")
                }
                .listRowBackground(theme.surface)

                Section {
                    HStack {
                        Text("Preview")
                        Spacer()
                        Text(tag.displayName)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background((Color(hex: tag.colorHex) ?? .gray).opacity(0.25), in: Capsule())
                    }
                }
                .listRowBackground(theme.surface)
            }
            .themedScrollBackground(theme)
            .navigationTitle("Tag Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
    }

    private func swatchButton(_ swatch: TagPalette.Swatch) -> some View {
        let isSelected = tag.colorHex?.caseInsensitiveCompare(swatch.hex) == .orderedSame
        return Button {
            tag.colorHex = swatch.hex
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color(hex: swatch.hex) ?? .gray)
                        .frame(width: 44, height: 44)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
                .overlay(
                    Circle().strokeBorder(isSelected ? theme.primaryText : .clear, lineWidth: 2)
                )
                Text(swatch.name)
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var customBinding: Binding<Color> {
        Binding(
            get: { Color(hex: tag.colorHex) ?? .gray },
            set: { tag.colorHex = $0.hexString }
        )
    }
}

/// Applies or removes a tag across a multi-selection in one action.
struct BatchTagEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(fetchRequest: LibraryQuery.allTags()) private var tags: FetchedResults<Tag>

    let songIDs: Set<UUID>
    let onFinish: () -> Void

    @State private var newTagName = ""
    @State private var songs: [Song] = []
    /// Coverage per tag, held explicitly rather than recomputed from the songs on
    /// every redraw. Editing a relationship doesn't reliably republish the tag
    /// fetch, so the derived version only refreshed for whichever tag happened to
    /// invalidate the view first — later toggles applied to the store but showed
    /// no change until the sheet was reopened.
    @State private var coverage: [UUID: Coverage] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New tag", text: $newTagName)
                        Button("Create") {
                            if let tag = Tag.findOrCreate(named: newTagName, in: context) {
                                apply(tag, add: true)
                            }
                            newTagName = ""
                        }
                        .accentAction(theme)
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .listRowBackground(theme.surface)
                Section("Tags") {
                    ForEach(tags) { tag in
                        let state = coverage[tag.id] ?? .absent
                        HStack {
                            Circle()
                                .fill(Color(hex: tag.colorHex) ?? .gray)
                                .frame(width: 10, height: 10)
                            Text(tag.displayName)
                            Spacer()
                            Image(systemName: state.symbol)
                                .foregroundStyle(state == .absent ? theme.secondaryText : theme.accent)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { apply(tag, add: state != .all) }
                    }
                }
                .listRowBackground(theme.surface)
            }
            .themedScrollBackground(theme)
            .navigationTitle("\(songIDs.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        PersistenceController.shared.save()
                        onFinish()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: loadSongs)
        }
    }

    /// Cases are deliberately not named `none`/`some`: those collide with
    /// `Optional`'s own cases and make `coverage[id] ?? .none` ambiguous.
    private enum Coverage {
        case absent, partial, all

        var symbol: String {
            switch self {
            case .absent: return "circle"
            case .partial: return "minus.circle.fill"
            case .all: return "checkmark.circle.fill"
            }
        }
    }

    private func loadSongs() {
        let request = Song.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", Array(songIDs))
        songs = LibraryQuery.fetch(request, in: context)
        coverage = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, measure($0)) })
    }

    private func measure(_ tag: Tag) -> Coverage {
        let matching = songs.filter { $0.tags.contains(tag) }.count
        if matching == 0 { return .absent }
        return matching == songs.count ? .all : .partial
    }

    private func apply(_ tag: Tag, add: Bool) {
        for song in songs {
            if add { song.addTag(tag) } else { song.removeTag(tag) }
        }
        // Update the row from the action we just performed, so every tag responds
        // on the first tap regardless of what Core Data chooses to republish.
        coverage[tag.id] = add ? .all : .absent
    }
}

#Preview {
    TagsView()
        .environment(\.managedObjectContext, PersistenceController.preview.viewContext)
        .environmentObject(PlaybackController.shared)
}
