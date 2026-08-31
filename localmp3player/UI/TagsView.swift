import CoreData
import SwiftUI

struct TagsView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme
    @FetchRequest(fetchRequest: LibraryQuery.allTags()) private var tags: FetchedResults<Tag>

    /// Bumped by `RootView` when the Tags tab is tapped while already showing.
    /// Panes are kept alive behind an opacity change, so a tab has no lifecycle
    /// event to reset on — this stands in for one.
    var popToRoot: Int = 0

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
                                .fill(tag.tint(theme))
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
                        // No `role: .destructive` — see `confirmDelete`. This
                        // only raises the prompt, so the row must not animate away.
                        Button { pendingDelete = tag } label: {
                            Label("Delete", systemImage: AppSymbol.delete)
                        }
                        .tint(.red)
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
            // See `LibraryView` — without this the tab roots keep iOS 26's glass
            // bar and rows blur visibly through it in Performance mode.
            .modeNavigationChrome(uiMode, theme: theme, title: .large)
            .navigationDestination(item: $target) { TagDetailView(tag: $0) }
            .onChange(of: popToRoot) { target = nil }
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
            .toolbarTint()
            .disabled(tags.isEmpty)
        }
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                let visible = Set(filteredTags.map(\.id))
                let allSelected = !visible.isEmpty && visible.isSubset(of: selection)
                Button(allSelected ? "Select None" : "Select All") {
                    selection = allSelected ? [] : visible
                }
                .toolbarTint()
                .disabled(visible.isEmpty)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            ToolbarGlyph("New Tag", systemImage: "plus") { editorTarget = .new }
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
    /// Editing a tag means picking songs out of it and renaming it. There is no
    /// running order to rearrange — a tag's songs come back sorted by title —
    /// so this drives the selection rather than a `List`'s own `EditMode`.
    @State private var isEditing = false
    @State private var showingColorPicker = false
    @State private var showingSongPicker = false
    @State private var showingPlaylistPicker = false
    @State private var renaming = false

    var body: some View {
        SongListContent(
            request: LibraryQuery.songs(taggedWith: tag),
            selection: $selection,
            isSelecting: isEditing,
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
        // Large, like a playlist's. An inline title shares the bar with the
        // buttons and loses to them; a large one gets its own line, which is
        // both more readable and less crowded.
        .modeNavigationChrome(uiMode, theme: theme, title: .large)
        // Editing owns the whole bar: Done takes the back button's place, so the
        // one way out of edit mode is the one that also settles the list. Leaving
        // both up meant five controls and a title truncated to "Ta...".
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    ToolbarGlyph("Done", systemImage: AppSymbol.done) {
                        withAnimation(uiMode.animation) { isEditing = false }
                        selection.removeAll()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    let visible = Set(taggedSongs().map(\.id))
                    let allSelected = !visible.isEmpty && visible.isSubset(of: selection)
                    Button(allSelected ? "Select None" : "Select All") {
                        selection = allSelected ? [] : visible
                    }
                    .toolbarTint()
                    .disabled(visible.isEmpty)
                }
            }
            // Shaped like `PlaylistDetailView`: the actions that change the tag
            // itself sit together while editing, and the ones that only make
            // sense on a settled list stand down.
            if !isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    ShufflePlayButton(sourceName: tag.displayName) { taggedSongs() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ToolbarGlyph("Add songs to this tag", systemImage: "plus") {
                        showingSongPicker = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ToolbarGlyph("Edit", systemImage: AppSymbol.edit) {
                        withAnimation(uiMode.animation) { isEditing = true }
                    }
                }
            } else {
                // Name and color are both "what this tag is", so both live in
                // edit mode and neither takes up room the rest of the time.
                ToolbarItem(placement: .topBarTrailing) {
                    ToolbarGlyph("Rename", systemImage: AppSymbol.rename) { renaming = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingColorPicker = true } label: {
                        // Show the tag's actual color, so the button says what it does.
                        Circle()
                            .fill(tag.tint(theme))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1))
                    }
                    .accessibilityLabel("Tag color, currently \(TagPalette.name(for: tag.colorHex))")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isEditing && !selection.isEmpty {
                selectionBar
            }
        }
        .sheet(isPresented: $renaming) {
            TagEditor(target: .existing(tag))
                .environment(\.managedObjectContext, context)
                .themedSheet(theme)
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            PlaylistPickerView(songs: selectedSongs()) { endSelection() }
                .environment(\.managedObjectContext, context)
                .environment(\.uiMode, uiMode)
                .themedSheet(theme)
        }
        .sheet(isPresented: $showingColorPicker) {
            EntityColorPicker(object: tag)
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
        let liked = selectedSongs().allLiked
        return SelectionBar(count: selection.count) {
            SelectionAction("Add to Playlist", systemImage: "text.badge.plus") { showingPlaylistPicker = true }
            SelectionAction(liked ? "Unlike" : "Like", systemImage: liked ? "heart.slash" : "heart") {
                selectedSongs().setLiked(!liked)
            }
            SelectionAction("Remove from Tag", systemImage: "minus.circle", role: .destructive) {
                removeSelectedFromTag()
            }
        }
    }

    private func taggedSongs() -> [Song] {
        LibraryQuery.fetch(LibraryQuery.songs(taggedWith: tag), in: context)
    }

    private func selectedSongs() -> [Song] {
        taggedSongs().filter { selection.contains($0.id) }
    }

    private func removeSelectedFromTag() {
        for song in selectedSongs() { song.removeTag(tag) }
        endSelection()
        PersistenceController.shared.save()
    }

    private func endSelection() {
        selection.removeAll()
        isEditing = false
    }
}

/// Picks the color for anything that carries one — a tag, a playlist, a smart
/// playlist. Generic over `Colorable` rather than copied per entity: the swatch
/// grid, the custom picker and the live preview are the same in all three, and
/// three near-identical copies is exactly how two of them end up drifting.
///
/// `@ObservedObject` on the object itself, not a `Binding` to its color: writing
/// through a binding changes the store but publishes nothing, so the swatch
/// checkmark and the preview would only catch up on reopen.
struct EntityColorPicker<Object: Colorable>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.theme) private var theme
    @ObservedObject var object: Object

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ColorSwatchGrid(selection: colorBinding)
                } header: {
                    Text("Preset colors")
                }
                .listRowBackground(theme.surface)

                Section {
                    ColorPicker("Custom color", selection: colorBinding.asColor, supportsOpacity: false)
                } footer: {
                    Text(Object.colorFooter)
                }
                .listRowBackground(theme.surface)

                Section {
                    HStack {
                        Text("Preview")
                        Spacer()
                        Text(object.colorLabel)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(object.tint(theme).opacity(0.25), in: Capsule())
                    }
                }
                .listRowBackground(theme.surface)
            }
            .themedScrollBackground(theme)
            .navigationTitle(Object.colorTitle)
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

    private var colorBinding: Binding<String?> {
        Binding(get: { object.colorHex }, set: { object.colorHex = $0 })
    }
}

extension Binding where Value == String? {
    /// Bridges a stored hex to the system color picker, so anything holding a
    /// hex — a managed object or a draft — can offer a custom color with one row.
    var asColor: Binding<Color> {
        Binding<Color>(
            // Grey, not the theme accent: this is the swatch the system picker
            // opens on, and a `Binding` extension has no environment to read a
            // theme from. Colours that get *displayed* fall back to the accent
            // through `Colorable.tint(_:)`.
            get: { Color(hex: wrappedValue) ?? .gray },
            set: { wrappedValue = $0.hexString }
        )
    }
}

/// The palette itself, over a plain hex binding. Split out of
/// `EntityColorPicker` so the smart playlist editor — which holds a draft and
/// has no object to hand a picker until Save — shows the same swatches rather
/// than a second, slightly different set.
struct ColorSwatchGrid: View {
    @Environment(\.theme) private var theme
    @Binding var selection: String?

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(TagPalette.swatches) { swatch in
                swatchButton(swatch)
            }
        }
        .padding(.vertical, 8)
    }

    private func swatchButton(_ swatch: TagPalette.Swatch) -> some View {
        let isSelected = selection?.caseInsensitiveCompare(swatch.hex) == .orderedSame
        return Button {
            // Tapping the current color clears it, which is the only way back to
            // "no color" — and no color is a real state: it means the row draws
            // in the theme accent.
            selection = isSelected ? nil : swatch.hex
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
                                .fill(tag.tint(theme))
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
