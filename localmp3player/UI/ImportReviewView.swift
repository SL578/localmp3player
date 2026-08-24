import SwiftUI

/// Nothing is written to the library until the user confirms here.
struct ImportReviewView: View {
    @Environment(\.uiMode) private var uiMode
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
                    .onDelete { coordinator.drafts.remove(atOffsets: $0) }
                } footer: {
                    Text("Titles and artists are read from the file's own tags first, then guessed from the filename. Tap any row to correct it.")
                }
            }
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
                    .presentationDetents([.medium])
                    .interactiveDismissDisabled()
                }
            }
        }
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(draft.metadataSource.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ImportDraftEditor: View {
    @Binding var draft: ImportDraft
    @State private var tagInput = ""

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $draft.title)
                TextField("Artist", text: $draft.artist)
                TextField("Album", text: Binding(
                    get: { draft.album ?? "" },
                    set: { draft.album = $0.isEmpty ? nil : $0 }
                ))
                Button {
                    let title = draft.title
                    draft.title = draft.artist
                    draft.artist = title
                } label: {
                    Label("Swap Title and Artist", systemImage: "arrow.up.arrow.down")
                }
            } header: {
                Text("Metadata")
            } footer: {
                Text("Filenames are read as “Artist - Title”. Use swap for files that use the other order.")
            }
            Section("Tags") {
                ForEach(draft.tagNames, id: \.self) { name in
                    Text(name)
                }
                .onDelete { draft.tagNames.remove(atOffsets: $0) }
                HStack {
                    TextField("Add tag", text: $tagInput)
                        .onSubmit(addTag)
                    Button("Add", action: addTag)
                        .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Source") {
                LabeledContent("File", value: draft.originalFilename)
                LabeledContent("Length", value: TimeFormatting.duration(draft.duration))
                LabeledContent("Read from", value: draft.metadataSource.label)
            }
        }
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !draft.tagNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            draft.tagNames.append(trimmed)
        }
        tagInput = ""
    }
}

struct DuplicateResolutionView: View {
    let draft: ImportDraft
    let existing: Song
    let onDecide: (DuplicateDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Possible Duplicate")
                    .font(.headline)
                Text("\(draft.title) — \(draft.artist) already looks like it's in your library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

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

            VStack(spacing: 8) {
                Button("Replace") { onDecide(DuplicateDecision(choice: .replace, applyToRest: false)) }
                    .buttonStyle(.borderedProminent)
                Button("Keep Both") { onDecide(DuplicateDecision(choice: .keepBoth, applyToRest: false)) }
                    .buttonStyle(.bordered)
                Button("Replace All Remaining") { onDecide(DuplicateDecision(choice: .replace, applyToRest: true)) }
                    .buttonStyle(.borderless)
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
    }

    private func comparisonColumn(heading: String, artwork: Data?, length: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ArtworkThumbnail(data: artwork, size: 56)
            Text(TimeFormatting.duration(length))
                .font(.caption.monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
