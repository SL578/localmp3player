import CoreData
import Foundation

/// How a song has to relate to the tags listed under Must Have. Artists have no
/// equivalent: a song carries exactly one, so "all of them" could never match.
enum TagMatchMode: String, Codable, CaseIterable, Identifiable {
    case any
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: return "Any"
        case .all: return "All"
        }
    }
}

/// Order the matches come back in, and — when a limit is set — which end of that
/// order the limit keeps.
enum SmartSort: String, Codable, CaseIterable, Identifiable {
    case title
    case artist
    case recentlyAdded
    case mostPlayed
    case random

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .recentlyAdded: return "Recently Added"
        case .mostPlayed: return "Most Played"
        case .random: return "Random"
        }
    }

    /// `.random` has no store-side equivalent — it's shuffled after the fetch —
    /// so it borrows a stable order to fetch with.
    var songSort: SongSort {
        switch self {
        case .title, .random: return .title
        case .artist: return .artist
        case .recentlyAdded: return .dateAdded
        case .mostPlayed: return .playCount
        }
    }
}

/// Every criterion a smart playlist can carry.
///
/// There is deliberately no rule *type* here. Each field is independently
/// optional and they all apply together, so one playlist can require a tag,
/// forbid an artist, rescue an exception, and cap its own length at once —
/// which the previous one-rule-at-a-time shape structurally could not express.
struct SmartRule: Equatable {
    var includeTagIDs: [UUID] = []
    var includeTagsMatchMode: TagMatchMode = .any
    var includeArtists: [String] = []

    var excludeTagIDs: [UUID] = []
    var excludeArtists: [String] = []

    /// Rescues a song from the exclusions above. Never rescues one that failed
    /// the include criteria — see `SmartPlaylistEngine`.
    var exceptIfHasTagIDs: [UUID] = []
    var exceptIfHasArtists: [String] = []

    var notPlayedInDays: Int?
    var addedWithinDays: Int?
    var onlyLiked = false

    var resultLimit: Int?
    var sortBy: SmartSort = .title

    var hasExclusions: Bool { !excludeTagIDs.isEmpty || !excludeArtists.isEmpty }

    var hasBehavioralFilters: Bool {
        notPlayedInDays != nil || addedWithinDays != nil || onlyLiked || resultLimit != nil
    }

    /// A rule with nothing set matches the whole library, which is a valid thing
    /// to save — it just means "every song, in this order".
    var isEmpty: Bool {
        includeTagIDs.isEmpty && includeArtists.isEmpty
            && !hasExclusions
            && exceptIfHasTagIDs.isEmpty && exceptIfHasArtists.isEmpty
            && !hasBehavioralFilters
    }
}

// MARK: - Storage

/// Rules live as JSON in one Binary attribute rather than as a column per
/// criterion. Adding a criterion later is then a change to this struct alone,
/// with no Core Data model version to migrate.
///
/// Decoding is written out by hand instead of synthesised because the
/// synthesised initialiser treats a missing key as an error even when the
/// property has a default — so a rule written before a new field existed would
/// fail to decode wholesale and the playlist would silently reset.
extension SmartRule: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case includeTagIDs, includeTagsMatchMode, includeArtists
        case excludeTagIDs, excludeArtists
        case exceptIfHasTagIDs, exceptIfHasArtists
        case notPlayedInDays, addedWithinDays, onlyLiked
        case resultLimit, sortBy
    }

    /// Bumped only if a future shape can't be read by the decoder below.
    private static let currentVersion = 2

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        includeTagIDs = try container.decodeIfPresent([UUID].self, forKey: .includeTagIDs) ?? []
        includeTagsMatchMode = try container.decodeIfPresent(TagMatchMode.self, forKey: .includeTagsMatchMode) ?? .any
        includeArtists = try container.decodeIfPresent([String].self, forKey: .includeArtists) ?? []
        excludeTagIDs = try container.decodeIfPresent([UUID].self, forKey: .excludeTagIDs) ?? []
        excludeArtists = try container.decodeIfPresent([String].self, forKey: .excludeArtists) ?? []
        exceptIfHasTagIDs = try container.decodeIfPresent([UUID].self, forKey: .exceptIfHasTagIDs) ?? []
        exceptIfHasArtists = try container.decodeIfPresent([String].self, forKey: .exceptIfHasArtists) ?? []
        notPlayedInDays = try container.decodeIfPresent(Int.self, forKey: .notPlayedInDays)
        addedWithinDays = try container.decodeIfPresent(Int.self, forKey: .addedWithinDays)
        onlyLiked = try container.decodeIfPresent(Bool.self, forKey: .onlyLiked) ?? false
        resultLimit = try container.decodeIfPresent(Int.self, forKey: .resultLimit)
        sortBy = try container.decodeIfPresent(SmartSort.self, forKey: .sortBy) ?? .title
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(includeTagIDs, forKey: .includeTagIDs)
        try container.encode(includeTagsMatchMode, forKey: .includeTagsMatchMode)
        try container.encode(includeArtists, forKey: .includeArtists)
        try container.encode(excludeTagIDs, forKey: .excludeTagIDs)
        try container.encode(excludeArtists, forKey: .excludeArtists)
        try container.encode(exceptIfHasTagIDs, forKey: .exceptIfHasTagIDs)
        try container.encode(exceptIfHasArtists, forKey: .exceptIfHasArtists)
        try container.encodeIfPresent(notPlayedInDays, forKey: .notPlayedInDays)
        try container.encodeIfPresent(addedWithinDays, forKey: .addedWithinDays)
        try container.encode(onlyLiked, forKey: .onlyLiked)
        try container.encodeIfPresent(resultLimit, forKey: .resultLimit)
        try container.encode(sortBy, forKey: .sortBy)
    }
}

/// The single-criterion shape `ruleData` held before this rebuild. Read only, to
/// carry playlists built under it into the new form.
private struct SingleCriterionPayload: Decodable {
    struct Attribute: Decodable {
        var kind = "tag"
        var includeIDs: [String] = []
        var matchAllIncluded = false
        var excludeIDs: [String] = []
        var exceptIDs: [String] = []
    }

    /// Non-optional on purpose: its presence is what identifies the old payload,
    /// since the new one has no such key.
    let attribute: Attribute
    var thresholdDays: Int?
    var resultLimit: Int?
}

@objc(SmartPlaylist)
public final class SmartPlaylist: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var dateCreated: Date
    @NSManaged public var ruleData: Data?
    /// Pre-`ruleData` fields, and the coarse rule type that went with them. Only
    /// read now, as a migration source — nothing writes them any more.
    @NSManaged public var ruleTypeRaw: String
    @NSManaged public var tagIDsData: Data?
    @NSManaged public var matchAllTags: Bool
    @NSManaged public var thresholdDays: NSNumber?
    @NSManaged public var resultLimit: NSNumber?
}

extension SmartPlaylist {
    static func fetchRequest() -> NSFetchRequest<SmartPlaylist> {
        NSFetchRequest<SmartPlaylist>(entityName: "SmartPlaylist")
    }

    /// Reads whichever of the three stored shapes this playlist happens to be in.
    /// Writing always produces the current one, so a playlist upgrades itself the
    /// first time it's saved.
    var rule: SmartRule {
        get {
            guard let ruleData else { return migratedFromColumns() }
            // The old payload is checked first: its own decoder tolerates missing
            // keys, so a new-shaped rule would otherwise decode as an empty one.
            if let old = try? JSONDecoder().decode(SingleCriterionPayload.self, from: ruleData) {
                return migrated(from: old)
            }
            return (try? JSONDecoder().decode(SmartRule.self, from: ruleData)) ?? SmartRule()
        }
        set { ruleData = try? JSONEncoder().encode(newValue) }
    }

    /// Carries a rule stored as one attribute filter plus a coarse type.
    private func migrated(from old: SingleCriterionPayload) -> SmartRule {
        var rule = SmartRule()
        if old.attribute.kind == "artist" {
            rule.includeArtists = old.attribute.includeIDs
            rule.excludeArtists = old.attribute.excludeIDs
            rule.exceptIfHasArtists = old.attribute.exceptIDs
        } else {
            rule.includeTagIDs = old.attribute.includeIDs.compactMap(UUID.init(uuidString:))
            rule.excludeTagIDs = old.attribute.excludeIDs.compactMap(UUID.init(uuidString:))
            rule.exceptIfHasTagIDs = old.attribute.exceptIDs.compactMap(UUID.init(uuidString:))
            rule.includeTagsMatchMode = old.attribute.matchAllIncluded ? .all : .any
        }
        applyLegacyType(to: &rule, thresholdDays: old.thresholdDays, resultLimit: old.resultLimit)
        return rule
    }

    /// Carries the oldest shape, where the tag list lived in its own column.
    private func migratedFromColumns() -> SmartRule {
        var rule = SmartRule()
        let ids = (tagIDsData.flatMap { try? JSONDecoder().decode([UUID].self, from: $0) }) ?? []
        if ruleTypeRaw == "tagExclude" {
            rule.excludeTagIDs = ids
        } else {
            rule.includeTagIDs = ids
            rule.includeTagsMatchMode = matchAllTags ? .all : .any
        }
        applyLegacyType(to: &rule, thresholdDays: thresholdDays?.intValue, resultLimit: resultLimit?.intValue)
        return rule
    }

    /// The behavioural rule types are all expressible as ordinary filters now, so
    /// each old type becomes the filter that means the same thing.
    private func applyLegacyType(to rule: inout SmartRule, thresholdDays: Int?, resultLimit: Int?) {
        switch ruleTypeRaw {
        case "notPlayedSince":
            rule.notPlayedInDays = thresholdDays ?? 30
        case "recentlyAdded":
            rule.resultLimit = resultLimit ?? 50
            rule.sortBy = .recentlyAdded
        case "mostPlayed":
            rule.resultLimit = resultLimit ?? 25
            rule.sortBy = .mostPlayed
        case "liked":
            rule.onlyLiked = true
        default:
            break
        }
    }

    /// Stands in for the old per-type icon, picked from whatever the rule leads
    /// with so the row still says something at a glance.
    var ruleIcon: String {
        let rule = self.rule
        if !rule.includeTagIDs.isEmpty || rule.hasExclusions { return "tag" }
        if !rule.includeArtists.isEmpty { return "music.mic" }
        if rule.onlyLiked { return "heart.fill" }
        if rule.notPlayedInDays != nil { return "clock.arrow.circlepath" }
        if rule.sortBy == .recentlyAdded { return "sparkles" }
        if rule.sortBy == .mostPlayed { return "chart.bar.fill" }
        return "wand.and.stars"
    }

    /// One line for the playlist row and for CarPlay's detail text. Counts rather
    /// than names, so it never has to go back to the store to render a list row.
    var ruleSummary: String {
        let rule = self.rule
        var parts: [String] = []

        let included = rule.includeTagIDs.count + rule.includeArtists.count
        if included > 0 {
            let joiner = rule.includeTagsMatchMode == .all && rule.includeTagIDs.count > 1 ? "all of" : "any of"
            parts.append(included == 1 ? "has 1 criterion" : "has \(joiner) \(included)")
        }
        let excluded = rule.excludeTagIDs.count + rule.excludeArtists.count
        if excluded > 0 {
            parts.append("excludes \(excluded)")
            let rescued = rule.exceptIfHasTagIDs.count + rule.exceptIfHasArtists.count
            if rescued > 0 { parts.append("except \(rescued)") }
        }
        if rule.onlyLiked { parts.append("liked only") }
        if let days = rule.notPlayedInDays { parts.append("not played in \(days)d") }
        if let days = rule.addedWithinDays { parts.append("added within \(days)d") }
        if let limit = rule.resultLimit { parts.append("top \(limit) by \(rule.sortBy.label.lowercased())") }

        return parts.isEmpty ? "every song" : parts.joined(separator: " · ")
    }
}
