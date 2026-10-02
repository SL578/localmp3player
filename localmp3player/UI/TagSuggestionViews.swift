import CoreData
import SwiftUI

/// Suggested tags as tappable chips. An open suggestion is a dashed outline
/// with a plus; a taken one fills with the tag's colour and shows a tick.
/// Tapping flips it. Used by the import review sheet, the import editor and
/// the suggestion review for existing songs, so all three read the same way.
struct SuggestedTagChips: View {
    @Environment(\.theme) private var theme
    @FetchRequest(fetchRequest: LibraryQuery.allTags()) private var tags: FetchedResults<Tag>

    let names: [String]
    let isAccepted: (String) -> Bool
    let toggle: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
                .accessibilityHidden(true)
            ForEach(names, id: \.self) { name in
                chip(name, accepted: isAccepted(name))
            }
        }
    }

    private func chip(_ name: String, accepted: Bool) -> some View {
        let color = tint(forTagNamed: name)
        return Button {
            toggle(name)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: accepted ? "checkmark" : "plus")
                    .font(.caption2.weight(.bold))
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                if accepted {
                    Capsule().fill(color.opacity(0.35))
                } else {
                    Capsule().strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .contentShape(Capsule())
        }
        // Per button, never on the list: see `accentAction`. Borderless is what
        // lets a chip take its own tap inside a row that has one of its own.
        .buttonStyle(.borderless)
        .accessibilityLabel(name)
        .accessibilityValue(accepted ? "Added" : "Suggested")
        .accessibilityHint(accepted ? "Removes this tag" : "Adds this tag")
    }

    private func tint(forTagNamed name: String) -> Color {
        tags.first { $0.name == Tag.canonical(name) }?.tint(theme) ?? theme.accent
    }
}

/// Footer copy shared by every place suggestions appear, so it names the
/// sources the same way and only mentions Apple Intelligence when it's on.
enum TagSuggestionCopy {
    static var sources: String {
        TagSuggester.modelStatus == .available
            ? "Suggestions come from how you've tagged the same artists, and from Apple Intelligence on this device."
            : "Suggestions come from how you've tagged the same artists."
    }
}

/// Suggests tags for songs already in the library, one row per song, and
/// applies only what the user ticks. Pushed from the batch tag sheet.
struct TagSuggestionReview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.uiMode) private var uiMode
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var settings: AppSettings

    let songIDs: Set<UUID>

    @State private var songs: [Song] = []
    @State private var suggestions: [UUID: [String]] = [:]
    /// Display names the user has ticked, per song.
    @State private var accepted: [UUID: Set<String>] = [:]
    @State private var answered = 0
    @State private var hasTags = true

    var body: some View {
        List {
            Section {
                if !hasTags {
                    Text("Create a few tags first. Suggestions only ever pick from tags you already have.")
                        .secondaryText()
                } else if isRunning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Suggesting \(answered + 1) of \(songs.count)")
                            .secondaryText()
                    }
                } else if withSuggestions.isEmpty {
                    Text("No suggestions for \(songs.count == 1 ? "this song" : "these songs").")
                        .secondaryText()
                } else if openCount > 0 {
                    Button("Select All Suggestions") {
                        for song in withSuggestions {
                            accepted[song.id] = Set(suggestions[song.id] ?? [])
                        }
                    }
                    .accentAction(theme)
                }
            } footer: {
                Text(footer)
            }
            .listRowBackground(theme.surface)

            if !withSuggestions.isEmpty {
                Section {
                    ForEach(withSuggestions) { song in
                        row(for: song)
                    }
                }
                .listRowBackground(theme.surface)
            }
        }
        .themedScrollBackground(theme)
        .navigationTitle("Suggested Tags")
        .navigationBarTitleDisplayMode(.inline)
        .modeNavigationChrome(uiMode, theme: theme)
        .modeToolbar(uiMode) {
            ToolbarItem(placement: .confirmationAction) {
                Button(acceptedCount > 0 ? "Add \(acceptedCount)" : "Add") { apply() }
                    .disabled(acceptedCount == 0)
            }
        }
        // Cancelled with the screen, so backing out stops the model mid-batch.
        .task { await run() }
    }

    private func row(for song: Song) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                Text(song.artist)
                    .font(.caption)
                    .secondaryText()
                    .lineLimit(1)
            }
            if !song.tags.isEmpty {
                TagChipRow(tags: song.sortedTags)
            }
            SuggestedTagChips(
                names: suggestions[song.id] ?? [],
                isAccepted: { accepted[song.id, default: []].contains($0) },
                toggle: { name in
                    if accepted[song.id, default: []].contains(name) {
                        accepted[song.id, default: []].remove(name)
                    } else {
                        accepted[song.id, default: []].insert(name)
                    }
                }
            )
        }
        .padding(.vertical, 2)
    }

    /// Empty songs means not loaded yet, which counts as running so the first
    /// frame doesn't flash "No suggestions".
    private var isRunning: Bool { hasTags && (songs.isEmpty || answered < songs.count) }

    private var withSuggestions: [Song] {
        songs.filter { !(suggestions[$0.id] ?? []).isEmpty }
    }

    private var acceptedCount: Int {
        accepted.values.reduce(0) { $0 + $1.count }
    }

    private var openCount: Int {
        withSuggestions.reduce(0) { total, song in
            total + (suggestions[song.id] ?? []).filter { !accepted[song.id, default: []].contains($0) }.count
        }
    }

    private var footer: String {
        let skipped = songs.count - withSuggestions.count
        guard !isRunning, skipped > 0, !withSuggestions.isEmpty else { return TagSuggestionCopy.sources }
        return "\(TagSuggestionCopy.sources) Nothing to suggest for \(skipped) of the selected songs."
    }

    private func run() async {
        guard songs.isEmpty else { return }
        let request = Song.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", Array(songIDs))
        request.sortDescriptors = SongSort.title.descriptors
        songs = LibraryQuery.fetch(request, in: context)

        let suggester = TagSuggester(context: context)
        hasTags = suggester.hasTags
        guard hasTags else { return }

        let autoSelect = settings.autoSelectSuggestedTags
        for song in songs {
            let names = await suggester.suggest(for: SongFacts(
                title: song.title,
                artist: song.artist,
                album: song.album,
                tagNames: song.tags.map(\.displayName)
            ))
            guard !Task.isCancelled else { return }
            suggestions[song.id] = names
            if autoSelect { accepted[song.id] = Set(names) }
            answered += 1
        }
    }

    private func apply() {
        for song in songs {
            for name in accepted[song.id] ?? [] {
                if let tag = Tag.findOrCreate(named: name, in: context) {
                    song.addTag(tag)
                }
            }
        }
        PersistenceController.shared.save()
        dismiss()
    }
}
