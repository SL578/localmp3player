import CoreData
import SwiftUI

struct SmartPlaylistEditor: View {
    /// What the sheet is editing. A brand-new playlist is deliberately *not*
    /// inserted into the context up front: an unsaved insert plus a Cancel used to
    /// mean `context.rollback()`, which invalidated the very object the sheet and
    /// the list row were still observing, and reading any property on it crashed.
    /// Nothing is written until Save, so Cancel is now just a dismiss.
    enum Target: Identifiable {
        case new
        case existing(SmartPlaylist)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let playlist): return playlist.objectID.uriRepresentation().absoluteString
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    let target: Target

    @FetchRequest(fetchRequest: LibraryQuery.allTags()) private var tags: FetchedResults<Tag>

    @State private var name = ""
    @State private var ruleType: SmartRuleType = .recentlyAdded
    @State private var selectedTagIDs = Set<UUID>()
    @State private var matchAllTags = false
    @State private var thresholdDays = 30
    @State private var resultLimit = 50

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }

                Section("Rule") {
                    Picker("Rule", selection: $ruleType) {
                        ForEach(SmartRuleType.allCases) { type in
                            Label(type.label, systemImage: type.systemImage).tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                if ruleType.usesTags {
                    Section("Tags") {
                        if ruleType == .tagInclude {
                            Picker("Match", selection: $matchAllTags) {
                                Text("Any tag").tag(false)
                                Text("All tags").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        if tags.isEmpty {
                            Text("No tags yet.").foregroundStyle(.secondary)
                        }
                        ForEach(tags) { tag in
                            Button {
                                toggle(tag)
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(Color(hex: tag.colorHex) ?? .gray)
                                        .frame(width: 10, height: 10)
                                    Text(tag.displayName)
                                    Spacer()
                                    if selectedTagIDs.contains(tag.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if ruleType.usesThresholdDays {
                    Section("Threshold") {
                        Stepper("Not played in \(thresholdDays) days", value: $thresholdDays, in: 1...365)
                    }
                }

                if ruleType.usesResultLimit {
                    Section("Limit") {
                        Stepper("Top \(resultLimit) songs", value: $resultLimit, in: 5...500, step: 5)
                    }
                }

                Section {
                    LabeledContent("Matches now", value: "\(matchCount) song\(matchCount == 1 ? "" : "s")")
                } footer: {
                    Text("Smart playlists are evaluated every time you open them — nothing is stored as a fixed list.")
                }
            }
            .navigationTitle(isNew ? "New Smart Playlist" : "Smart Playlist")
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

    /// Previews the rule the user is currently editing without writing it back
    /// to the managed object, so nothing is persisted until Save.
    private var draftRule: SmartRule {
        SmartRule(
            type: ruleType,
            tagIDs: ruleType.usesTags ? Array(selectedTagIDs) : [],
            matchAllTags: matchAllTags,
            thresholdDays: ruleType.usesThresholdDays ? thresholdDays : nil,
            resultLimit: ruleType.usesResultLimit ? resultLimit : nil
        )
    }

    private var matchCount: Int {
        SmartPlaylistEngine.songs(for: draftRule, in: context).count
    }

    private func load() {
        switch target {
        case .new:
            name = "New Smart Playlist"
            ruleType = .recentlyAdded
            resultLimit = 50
        case .existing(let playlist):
            name = playlist.name
            ruleType = playlist.ruleType
            selectedTagIDs = Set(playlist.tagIDs ?? [])
            matchAllTags = playlist.matchAllTags
            thresholdDays = playlist.thresholdDaysValue ?? 30
            resultLimit = playlist.resultLimitValue ?? 50
        }
    }

    /// The only place a smart playlist is created or mutated.
    private func save() {
        let playlist: SmartPlaylist
        switch target {
        case .new:
            playlist = SmartPlaylist(context: context)
            playlist.id = UUID()
            playlist.dateCreated = Date()
        case .existing(let existing):
            playlist = existing
        }
        playlist.name = name.trimmingCharacters(in: .whitespaces)
        playlist.rule = draftRule
        PersistenceController.shared.save()
    }

    private func toggle(_ tag: Tag) {
        if selectedTagIDs.contains(tag.id) { selectedTagIDs.remove(tag.id) } else { selectedTagIDs.insert(tag.id) }
    }
}
