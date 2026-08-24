import CoreData
import SwiftUI

struct TagsView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @FetchRequest(fetchRequest: LibraryQuery.allTags()) private var tags: FetchedResults<Tag>

    @State private var newTagName = ""
    @State private var showingNewTag = false
    @State private var target: Tag?

    var body: some View {
        NavigationStack {
            List {
                ForEach(tags) { tag in
                    DisclosureRow(isSelecting: false) {
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
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Tags")
            .navigationDestination(item: $target) { TagDetailView(tag: $0) }
            .overlay {
                if tags.isEmpty {
                    ContentUnavailableView("No Tags", systemImage: "tag", description: Text("Tags let you build smart playlists and browse quickly in CarPlay."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNewTag = true } label: { Image(systemName: "plus") }
                }
            }
            .alert("New Tag", isPresented: $showingNewTag) {
                TextField("Name", text: $newTagName)
                Button("Cancel", role: .cancel) { newTagName = "" }
                Button("Create") {
                    Tag.findOrCreate(named: newTagName, in: context)
                    newTagName = ""
                    try? context.save()
                }
            }
        }
    }

    /// Performance mode pushes without a transition.
    private func navigate(_ action: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = !uiMode.usesAnimation
        withTransaction(transaction, action)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(tags[index]) }
        PersistenceController.shared.save()
    }
}

struct TagDetailView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme
    @ObservedObject var tag: Tag
    @State private var selection = Set<UUID>()
    @State private var showingColorPicker = false
    @State private var showingSongPicker = false

    var body: some View {
        SongListContent(
            request: LibraryQuery.songs(taggedWith: tag),
            selection: $selection,
            isSelecting: false,
            sourceName: tag.displayName
        )
        .navigationTitle(tag.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .modeNavigationChrome(uiMode, theme: theme)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShufflePlayButton(sourceName: tag.displayName) {
                    LibraryQuery.fetch(LibraryQuery.songs(taggedWith: tag), in: context)
                }
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
        .sheet(isPresented: $showingColorPicker) {
            TagColorPicker(tag: tag)
                .environment(\.managedObjectContext, context)
                .environment(\.theme, theme)
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
            .environment(\.theme, theme)
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

                Section {
                    ColorPicker("Custom color", selection: customBinding, supportsOpacity: false)
                } footer: {
                    Text("Tag colors show on song chips and make tags easier to pick out at a glance in CarPlay.")
                }

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
            }
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
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
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
            }
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
