import CoreData
import SwiftUI

struct TagsView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(fetchRequest: LibraryQuery.allTags()) private var tags: FetchedResults<Tag>

    @State private var newTagName = ""
    @State private var showingNewTag = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(tags) { tag in
                    NavigationLink {
                        TagDetailView(tag: tag)
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: tag.colorHex) ?? .gray)
                                .frame(width: 12, height: 12)
                            Text(tag.displayName)
                            Spacer()
                            Text("\(tag.songs.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Tags")
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

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(tags[index]) }
        try? context.save()
    }
}

struct TagDetailView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme
    @ObservedObject var tag: Tag
    @State private var selection = Set<UUID>()
    @State private var showingColorPicker = false

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

    private var songs: [Song] {
        let request = Song.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", Array(songIDs))
        return LibraryQuery.fetch(request, in: context)
    }

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
                        let state = coverage(of: tag)
                        HStack {
                            Circle()
                                .fill(Color(hex: tag.colorHex) ?? .gray)
                                .frame(width: 10, height: 10)
                            Text(tag.displayName)
                            Spacer()
                            Image(systemName: state.symbol)
                                .foregroundStyle(state == .none ? theme.secondaryText : theme.accent)
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
                        try? context.save()
                        onFinish()
                        dismiss()
                    }
                }
            }
        }
    }

    private enum Coverage {
        case none, some, all

        var symbol: String {
            switch self {
            case .none: return "circle"
            case .some: return "minus.circle.fill"
            case .all: return "checkmark.circle.fill"
            }
        }
    }

    private func coverage(of tag: Tag) -> Coverage {
        let matching = songs.filter { $0.tags.contains(tag) }.count
        if matching == 0 { return .none }
        return matching == songs.count ? .all : .some
    }

    private func apply(_ tag: Tag, add: Bool) {
        for song in songs {
            if add { song.addTag(tag) } else { song.removeTag(tag) }
        }
    }
}

#Preview {
    TagsView()
        .environment(\.managedObjectContext, PersistenceController.preview.viewContext)
        .environmentObject(PlaybackController.shared)
}
