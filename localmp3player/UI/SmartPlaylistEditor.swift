import CoreData
import SwiftUI

/// One group of criteria — tags and artists together, never one or the other.
struct SmartCriteria: Equatable {
    var tagIDs: Set<UUID> = []
    var artists: Set<String> = []

    var isEmpty: Bool { tagIDs.isEmpty && artists.isEmpty }
}

/// A single chip: one tag or one artist, already resolved to something drawable.
private struct Criterion: Identifiable, Hashable {
    enum Kind: Hashable {
        case tag(UUID)
        case artist(String)
    }

    let kind: Kind
    let label: String
    let color: Color?

    var id: Kind { kind }
}

/// Which of the three groups a sheet or a row is acting on.
private enum CriteriaSlot: String, Identifiable, CaseIterable {
    case include
    case exclude
    case except

    var id: String { rawValue }

    var title: String {
        switch self {
        case .include: return "Must Have"
        case .exclude: return "Must Not Have"
        case .except: return "Except If Has"
        }
    }

    var emptyText: String {
        switch self {
        case .include: return "Nothing required — every song qualifies."
        case .exclude: return "Nothing excluded."
        case .except: return "No exceptions."
        }
    }

    var footer: String? {
        switch self {
        case .include: return nil
        case .exclude: return "Songs matching any of these are left out."
        case .except: return "Songs matching these are kept even if excluded above."
        }
    }
}

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
    @Environment(\.theme) private var theme
    let target: Target

    @FetchRequest(fetchRequest: LibraryQuery.allTags()) private var tags: FetchedResults<Tag>
    @FetchRequest(fetchRequest: LibraryQuery.allSongs()) private var songs: FetchedResults<Song>

    @State private var name = ""
    @State private var include = SmartCriteria()
    @State private var exclude = SmartCriteria()
    @State private var except = SmartCriteria()
    @State private var tagMatchMode: TagMatchMode = .any

    @State private var limitsNotPlayed = false
    @State private var notPlayedInDays = 30
    @State private var limitsAdded = false
    @State private var addedWithinDays = 7
    @State private var onlyLiked = false
    @State private var limitsResults = false
    @State private var resultLimit = 50
    @State private var sortBy: SmartSort = .title

    @State private var showingMoreFilters = false
    @State private var picking: CriteriaSlot?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                .listRowBackground(theme.surface)

                criteriaSection(.include)
                criteriaSection(.exclude)
                // Only worth showing once there is something for it to override.
                if !exclude.isEmpty {
                    criteriaSection(.except)
                }

                moreFilters
                matchesSection
            }
            .themedScrollBackground(theme)
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
            .sheet(item: $picking) { slot in
                CriteriaPicker(
                    title: slot.title,
                    tags: Array(tags),
                    artists: artistNames,
                    criteria: binding(for: slot)
                )
                .themedSheet(theme)
            }
        }
    }

    // MARK: - Criteria sections

    @ViewBuilder
    private func criteriaSection(_ slot: CriteriaSlot) -> some View {
        let criteria = binding(for: slot).wrappedValue

        Section {
            // Artists are single-valued, so All only ever describes the tags, and
            // it only means anything once there are two of them to combine.
            if slot == .include, criteria.tagIDs.count > 1 {
                Picker("Tag match", selection: $tagMatchMode) {
                    ForEach(TagMatchMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if criteria.isEmpty {
                Text(slot.emptyText)
                    .font(.footnote)
                    .secondaryText()
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(criteria.resolved(tags: tagsByID)) { criterion in
                        CriterionChip(criterion: criterion) {
                            remove(criterion, from: slot)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Button {
                picking = slot
            } label: {
                Label("Add Tags or Artists", systemImage: "plus.circle")
            }
            .accentAction(theme)
        } header: {
            Text(slot.title)
        } footer: {
            if slot == .include, criteria.tagIDs.count > 1 {
                Text("Match applies to tags: \(tagMatchMode == .all ? "a song needs every tag listed" : "any one tag is enough"). Artists always match any.")
            } else if let footer = slot.footer {
                Text(footer)
            }
        }
        .listRowBackground(theme.surface)
    }

    // MARK: - More filters

    private var moreFilters: some View {
        Section {
            DisclosureGroup("More Filters", isExpanded: $showingMoreFilters) {
                Toggle("Not played in a while", isOn: $limitsNotPlayed)
                if limitsNotPlayed {
                    Stepper("Not played in \(notPlayedInDays) days", value: $notPlayedInDays, in: 1...365)
                }

                Toggle("Added recently", isOn: $limitsAdded)
                if limitsAdded {
                    Stepper("Added within \(addedWithinDays) days", value: $addedWithinDays, in: 1...365)
                }

                Toggle("Liked songs only", isOn: $onlyLiked)

                Toggle("Limit how many", isOn: $limitsResults)
                if limitsResults {
                    Stepper("Keep \(resultLimit) songs", value: $resultLimit, in: 5...500, step: 5)
                }

                Picker("Order by", selection: $sortBy) {
                    ForEach(SmartSort.allCases) { sort in
                        Text(sort.label).tag(sort)
                    }
                }
            }
        }
        .listRowBackground(theme.surface)
    }

    private var matchesSection: some View {
        Section {
            NavigationLink {
                SmartPlaylistPreview(rule: draftRule)
                    .environment(\.theme, theme)
            } label: {
                LabeledContent("Matches now", value: "\(matchCount) song\(matchCount == 1 ? "" : "s")")
            }
        } footer: {
            Text("Smart playlists are evaluated every time you open them — nothing is stored as a fixed list.")
        }
        .listRowBackground(theme.surface)
    }

    // MARK: - Criteria plumbing

    private func binding(for slot: CriteriaSlot) -> Binding<SmartCriteria> {
        switch slot {
        case .include: return $include
        case .exclude: return $exclude
        case .except: return $except
        }
    }

    private func remove(_ criterion: Criterion, from slot: CriteriaSlot) {
        let binding = binding(for: slot)
        switch criterion.kind {
        case .tag(let id): binding.wrappedValue.tagIDs.remove(id)
        case .artist(let name): binding.wrappedValue.artists.remove(name)
        }
        // An emptied Must Not Have takes its exceptions with it — they would have
        // nothing left to override, and leaving them behind would quietly widen
        // the playlist the next time something was excluded.
        if slot == .exclude, exclude.isEmpty {
            except = SmartCriteria()
        }
    }

    private var tagsByID: [UUID: Tag] {
        Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
    }

    /// Artists are read off the library itself — there's no Artist entity, so the
    /// set of names in use is the only list there is to pick from.
    private var artistNames: [String] {
        Set(songs.map(\.artist))
            .subtracting([""])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Load / save

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    /// The rule as currently edited, without writing anything back to the store.
    private var draftRule: SmartRule {
        SmartRule(
            includeTagIDs: Array(include.tagIDs),
            includeTagsMatchMode: tagMatchMode,
            includeArtists: Array(include.artists),
            excludeTagIDs: Array(exclude.tagIDs),
            excludeArtists: Array(exclude.artists),
            exceptIfHasTagIDs: Array(except.tagIDs),
            exceptIfHasArtists: Array(except.artists),
            notPlayedInDays: limitsNotPlayed ? notPlayedInDays : nil,
            addedWithinDays: limitsAdded ? addedWithinDays : nil,
            onlyLiked: onlyLiked,
            resultLimit: limitsResults ? resultLimit : nil,
            sortBy: sortBy
        )
    }

    private var matchCount: Int {
        SmartPlaylistEngine.matchCount(for: draftRule, in: context)
    }

    private func load() {
        guard case .existing(let playlist) = target else {
            name = "New Smart Playlist"
            return
        }
        name = playlist.name
        let rule = playlist.rule
        include = SmartCriteria(tagIDs: Set(rule.includeTagIDs), artists: Set(rule.includeArtists))
        exclude = SmartCriteria(tagIDs: Set(rule.excludeTagIDs), artists: Set(rule.excludeArtists))
        except = SmartCriteria(tagIDs: Set(rule.exceptIfHasTagIDs), artists: Set(rule.exceptIfHasArtists))
        tagMatchMode = rule.includeTagsMatchMode

        limitsNotPlayed = rule.notPlayedInDays != nil
        notPlayedInDays = rule.notPlayedInDays ?? 30
        limitsAdded = rule.addedWithinDays != nil
        addedWithinDays = rule.addedWithinDays ?? 7
        onlyLiked = rule.onlyLiked
        limitsResults = rule.resultLimit != nil
        resultLimit = rule.resultLimit ?? 50
        sortBy = rule.sortBy
        // Opened collapsed unless this playlist actually uses one of them, so the
        // section isn't hiding settings that are already in force.
        showingMoreFilters = rule.hasBehavioralFilters
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
}

private extension SmartCriteria {
    /// Chips in one stable order: tags first with their colours, then artists,
    /// each group alphabetical.
    func resolved(tags: [UUID: Tag]) -> [Criterion] {
        let tagChips = tagIDs.compactMap { id -> Criterion? in
            guard let tag = tags[id] else { return nil }
            return Criterion(kind: .tag(id), label: tag.displayName, color: Color(hex: tag.colorHex) ?? .gray)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }

        let artistChips = artists
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Criterion(kind: .artist($0), label: $0, color: nil) }

        return tagChips + artistChips
    }
}

// MARK: - Chips

private struct CriterionChip: View {
    @Environment(\.theme) private var theme
    let criterion: Criterion
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 4) {
                if criterion.color == nil {
                    Image(systemName: "music.mic")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                }
                Text(criterion.label)
                    .font(.caption)
                    .foregroundStyle(theme.primaryText)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(criterion.label)")
    }

    /// Tags keep their own colour so a chip reads the same here as it does on a
    /// song row; artists have no colour of their own to borrow.
    private var fill: Color {
        (criterion.color ?? theme.secondaryText).opacity(0.22)
    }
}

/// Wrapping row layout for the chips. A `LazyVGrid` would need a fixed column
/// count, and chips are all different widths.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.replacingUnspecifiedDimensions().width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(subviews, width: bounds.width).origins
        for (index, origin) in origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}

// MARK: - Picker sheet

/// Adds tags and artists to one criteria group in a single trip: both kinds are
/// searchable in the same sheet, and everything checked is applied on Done.
private struct CriteriaPicker: View {
    private enum Segment: String, CaseIterable, Identifiable {
        case tags
        case artists

        var id: String { rawValue }
        var label: String { self == .tags ? "Tags" : "Artists" }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let title: String
    let tags: [Tag]
    let artists: [String]
    @Binding var criteria: SmartCriteria

    @State private var segment: Segment = .tags
    @State private var search = ""
    /// Edited locally so Cancel really discards, and so several picks across both
    /// segments land as one change.
    @State private var draft = SmartCriteria()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Kind", selection: $segment) {
                        ForEach(Segment.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                Section {
                    switch segment {
                    case .tags: tagRows
                    case .artists: artistRows
                    }
                }
                .listRowBackground(theme.surface)
            }
            .themedScrollBackground(theme)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        criteria = draft
                        dismiss()
                    }
                }
            }
            .onAppear { draft = criteria }
        }
    }

    @ViewBuilder
    private var tagRows: some View {
        let matches = tags.filter { matchesSearch($0.displayName) }
        if matches.isEmpty {
            Text(tags.isEmpty ? "No tags yet." : "No tags match.").secondaryText()
        }
        ForEach(matches) { tag in
            row(label: tag.displayName, color: Color(hex: tag.colorHex) ?? .gray, isOn: draft.tagIDs.contains(tag.id)) {
                toggle(tag.id, in: &draft.tagIDs)
            }
        }
    }

    @ViewBuilder
    private var artistRows: some View {
        let matches = artists.filter { matchesSearch($0) }
        if matches.isEmpty {
            Text(artists.isEmpty ? "No artists in your library yet." : "No artists match.").secondaryText()
        }
        ForEach(matches, id: \.self) { artist in
            row(label: artist, color: nil, isOn: draft.artists.contains(artist)) {
                toggle(artist, in: &draft.artists)
            }
        }
    }

    private func row(label: String, color: Color?, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                if let color {
                    Circle().fill(color).frame(width: 10, height: 10)
                }
                Text(label).foregroundStyle(theme.primaryText)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark").foregroundStyle(theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func matchesSearch(_ value: String) -> Bool {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || value.localizedCaseInsensitiveContains(trimmed)
    }

    private func toggle<T: Hashable>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}

// MARK: - Preview of matches

/// Read-only list of what the rule currently selects, so the match count can be
/// checked rather than trusted.
private struct SmartPlaylistPreview: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.theme) private var theme
    let rule: SmartRule

    @State private var matches: [Song] = []

    var body: some View {
        List {
            ForEach(matches) { song in
                SongRow(song: song, isSelected: false, isSelecting: false)
                    .listRowBackground(theme.background)
            }
        }
        .listStyle(.plain)
        .themedScrollBackground(theme)
        .navigationTitle("\(matches.count) Match\(matches.count == 1 ? "" : "es")")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if matches.isEmpty {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Nothing in your library fits this rule yet.")
                )
            }
        }
        .onAppear { matches = SmartPlaylistEngine.songs(for: rule, in: context) }
    }
}
