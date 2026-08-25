import CoreData
import SwiftUI

/// Nothing is written to the library until the user confirms here.
struct ImportReviewView: View {
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme
    @EnvironmentObject private var coordinator: ImportCoordinator
    @State private var isCommitting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($coordinator.drafts) { $draft in
                        NavigationLink {
                            ImportDraftEditor(draft: $draft)
                        } label: {
                            DraftSummaryRow(draft: draft)
                        }
                    }
                    .onDelete { coordinator.removeDrafts(atOffsets: $0) }
                } footer: {
                    Text("Titles and artists are read from the file's own tags first, then guessed from the filename. Tap any row to correct it.")
                }
                .listRowBackground(theme.surface)
            }
            .themedScrollBackground(theme)
            .navigationTitle("Review Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { coordinator.cancelReview() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(coordinator.drafts.count)") {
                        isCommitting = true
                        Task {
                            await coordinator.commit()
                            isCommitting = false
                        }
                    }
                    .disabled(coordinator.drafts.isEmpty || isCommitting)
                }
            }
            .sheet(isPresented: duplicateBinding) {
                if let pending = coordinator.pendingDuplicate {
                    DuplicateResolutionView(draft: pending.draft, existing: pending.existing) { decision in
                        coordinator.resolvePendingDuplicate(decision)
                    }
                    .environment(\.uiMode, uiMode)
                    .themedSheet(theme)
                    .interactiveDismissDisabled()
                }
            }
        }
        // The review list and the per-song editor both live in this sheet. Without
        // this, a downward drag while editing one song tore down the whole import.
        .interactiveDismissDisabled()
    }

    private var duplicateBinding: Binding<Bool> {
        Binding(get: { coordinator.pendingDuplicate != nil }, set: { _ in })
    }
}

private struct DraftSummaryRow: View {
    let draft: ImportDraft

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(data: draft.artworkData, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title).lineLimit(1)
                Text(draft.artist)
                    .font(.caption)
                    .secondaryText()
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(draft.metadataSource.label)
                        .font(.caption2)
                        .tertiaryText()
                    if !draft.tagNames.isEmpty {
                        Text("· \(draft.tagNames.count) tag\(draft.tagNames.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .tertiaryText()
                    }
                }
            }
        }
    }
}

/// Edits one staged file. Works on a local copy so Cancel really discards.
struct ImportDraftEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @FetchRequest(fetchRequest: LibraryQuery.allTags()) private var existingTags: FetchedResults<Tag>

    @Binding var draft: ImportDraft
    @State private var edited: ImportDraft
    @State private var tagInput = ""

    init(draft: Binding<ImportDraft>) {
        _draft = draft
        _edited = State(initialValue: draft.wrappedValue)
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $edited.title)
                TextField("Artist", text: $edited.artist)
                TextField("Album", text: Binding(
                    get: { edited.album ?? "" },
                    set: { edited.album = $0.isEmpty ? nil : $0 }
                ))
                Button {
                    let title = edited.title
                    edited.title = edited.artist
                    edited.artist = title
                } label: {
                    Label("Swap Title and Artist", systemImage: "arrow.up.arrow.down")
                }
                .accentAction(theme)
            } header: {
                Text("Metadata")
            } footer: {
                Text("Filenames are read as “Artist - Title”. Use swap for files that use the other order.")
            }
            .listRowBackground(theme.surface)

            Section("Tags") {
                ForEach(edited.tagNames, id: \.self) { name in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(forTagNamed: name))
                            .frame(width: 10, height: 10)
                        Text(name)
                    }
                }
                .onDelete { edited.tagNames.remove(atOffsets: $0) }

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
                LabeledContent("File", value: edited.originalFilename)
                LabeledContent("Length", value: TimeFormatting.duration(edited.duration))
                LabeledContent("Read from", value: edited.metadataSource.label)
            }
            .listRowBackground(theme.surface)
        }
        .themedScrollBackground(theme)
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    draft = edited
                    dismiss()
                }
                .disabled(edited.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// Existing tags not already on this draft, matched case-insensitively so the
    /// menu never offers a tag the user has effectively already added.
    private var unusedTags: [Tag] {
        existingTags.filter { tag in
            !edited.tagNames.contains { $0.caseInsensitiveCompare(tag.displayName) == .orderedSame }
        }
    }

    private func color(forTagNamed name: String) -> Color {
        let hex = existingTags
            .first { $0.name == Tag.canonical(name) }?
            .colorHex ?? TagPalette.suggestedHex(for: Tag.canonical(name))
        return Color(hex: hex) ?? .gray
    }

    private func addTag(named raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !edited.tagNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            edited.tagNames.append(trimmed)
        }
        tagInput = ""
    }
}

struct DuplicateResolutionView: View {
    let draft: ImportDraft
    let existing: Song
    let onDecide: (DuplicateDecision) -> Void

    /// Drives a detent sized to the content, so the sheet rises only as far as it
    /// needs to and the heading sits at the top instead of floating mid-panel.
    @State private var contentHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Cancel as its own capsule, title centered in the same row and
            // vertically aligned with it — the standard sheet-header layout used
            // everywhere else in the app, rather than a plain text link.
            ZStack {
                Text("Possible Duplicate")
                    .font(.headline)
                    .frame(maxWidth: .infinity)

                HStack {
                    Button("Cancel") { onDecide(.cancel) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    Spacer()
                }
            }

            Text("\(draft.title) — \(draft.artist) already looks like it's in your library.")
                .font(.subheadline)
                .secondaryText()
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                comparisonColumn(
                    heading: "In library",
                    artwork: existing.artworkData,
                    length: existing.duration,
                    detail: "Added \(existing.dateAdded.formatted(date: .abbreviated, time: .omitted))"
                )
                comparisonColumn(
                    heading: "Importing",
                    artwork: draft.artworkData,
                    length: draft.duration,
                    detail: draft.originalFilename
                )
            }

            VStack(spacing: 10) {
                // The two real choices get equal width and full height, so they are
                // the easiest things on the panel to hit.
                HStack(spacing: 10) {
                    // The width goes on the *label*, so the filled shape itself
                    // stretches — on the button it would only pad around a
                    // content-sized capsule and stay small.
                    Button {
                        onDecide(DuplicateDecision(choice: .replace, applyToRest: false))
                    } label: {
                        Text("Replace").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        onDecide(DuplicateDecision(choice: .keepBoth, applyToRest: false))
                    } label: {
                        Text("Keep Both").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)

                // Batch escapes for both choices, kept visually subordinate to
                // the two single-song decisions above.
                HStack(spacing: 10) {
                    Button {
                        onDecide(DuplicateDecision(choice: .replace, applyToRest: true))
                    } label: {
                        Text("Replace All Remaining")
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .contentShape(Rectangle())
                    }

                    Button {
                        onDecide(DuplicateDecision(choice: .keepBoth, applyToRest: true))
                    } label: {
                        Text("Keep All Remaining")
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.borderless)
                .font(.footnote)
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .padding(.top, 4)
        .padding(.bottom, 20)
        .background(heightReader)
        .onPreferenceChange(ContentHeightKey.self) { height in
            guard height > 0 else { return }
            contentHeight = height
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(contentHeight)])
    }

    private var heightReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
        }
    }

    private func comparisonColumn(heading: String, artwork: Data?, length: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.caption.weight(.semibold))
                .secondaryText()
            ArtworkThumbnail(data: artwork, size: 56)
            Text(TimeFormatting.duration(length))
                .font(.caption.monospacedDigit())
            Text(detail)
                .font(.caption2)
                .tertiaryText()
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
