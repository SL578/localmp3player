import CoreData
import SwiftUI

/// Corrects a song that's already in the library — the same fields the import
/// review screen offers, for when a bad filename only becomes obvious later.
///
/// Edits are held locally and written on Save, so Cancel really discards rather
/// than leaving a half-applied change on the managed object.
struct SongEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(fetchRequest: LibraryQuery.allTags()) private var existingTags: FetchedResults<Tag>

    @ObservedObject var song: Song

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var tagNames: [String] = []
    @State private var tagInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                    Button {
                        let swapped = title
                        title = artist
                        artist = swapped
                    } label: {
                        Label("Swap Title and Artist", systemImage: "arrow.up.arrow.down")
                    }
                    .accentAction(theme)
                } header: {
                    Text("Metadata")
                } footer: {
                    Text("Use swap for anything imported from a filename in the other order.")
                }
                .listRowBackground(theme.surface)

                Section("Tags") {
                    ForEach(tagNames, id: \.self) { name in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(color(forTagNamed: name))
                                .frame(width: 10, height: 10)
                            Text(name)
                        }
                    }
                    .onDelete { tagNames.remove(atOffsets: $0) }

                    if !unusedTags.isEmpty {
                        Menu {
                            ForEach(unusedTags) { tag in
                                Button {
                                    addTag(named: tag.displayName)
                                } label: {
                                    Label(tag.displayName, systemImage: "tag")
                                }
                            }
                        } label: {
                            Label("Choose Existing Tag", systemImage: "chevron.down.circle")
                        }
                        .accentAction(theme)
                    }

                    HStack {
                        TextField("New tag", text: $tagInput)
                            .onSubmit { addTag(named: tagInput) }
                        Button("Add") { addTag(named: tagInput) }
                            .accentAction(theme)
                            .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .listRowBackground(theme.surface)

                Section("Source") {
                    LabeledContent("File", value: song.originalFilename)
                    LabeledContent("Length", value: TimeFormatting.duration(song.duration))
                    LabeledContent("Added", value: song.dateAdded.formatted(date: .abbreviated, time: .omitted))
                }
                .listRowBackground(theme.surface)
            }
            .themedScrollBackground(theme)
            .navigationTitle("Edit Song")
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
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    /// Existing tags not already on this song, matched case-insensitively so the
    /// menu never offers one that's effectively already applied.
    private var unusedTags: [Tag] {
        existingTags.filter { tag in
            !tagNames.contains { $0.caseInsensitiveCompare(tag.displayName) == .orderedSame }
        }
    }

    private func color(forTagNamed name: String) -> Color {
        let hex = existingTags
            .first { $0.name == Tag.canonical(name) }?
            .colorHex ?? TagPalette.suggestedHex(for: Tag.canonical(name))
        return Color(hex: hex) ?? theme.accent
    }

    private func addTag(named raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !tagNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            tagNames.append(trimmed)
        }
        tagInput = ""
    }

    private func load() {
        title = song.title
        artist = song.artist
        album = song.album ?? ""
        tagNames = song.sortedTags.map(\.displayName)
    }

    private func save() {
        let newTitle = title.trimmingCharacters(in: .whitespaces)
        let newArtist = artist.trimmingCharacters(in: .whitespaces)
        let newAlbum = album.trimmingCharacters(in: .whitespaces)

        song.title = newTitle
        song.artist = newArtist
        song.album = newAlbum.isEmpty ? nil : newAlbum
        // Duplicate detection matches on this, not on the display fields, so a
        // correction here has to be reflected or the next import of the same
        // track won't recognise it.
        song.normalizedKey = NormalizedKey.make(title: newTitle, artist: newArtist)

        song.tags = Set(tagNames.compactMap { Tag.findOrCreate(named: $0, in: context) })
        PersistenceController.shared.save()
    }
}
