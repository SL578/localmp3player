import CoreData
import Foundation

enum SmartRuleType: String, CaseIterable, Identifiable {
    case tagInclude
    case tagExclude
    case notPlayedSince
    case recentlyAdded
    case mostPlayed
    case liked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tagInclude: return "Has tags"
        case .tagExclude: return "Excludes tags"
        case .notPlayedSince: return "Not played in a while"
        case .recentlyAdded: return "Recently added"
        case .mostPlayed: return "Most played"
        case .liked: return "Liked songs"
        }
    }

    var systemImage: String {
        switch self {
        case .tagInclude: return "tag"
        case .tagExclude: return "tag.slash"
        case .notPlayedSince: return "clock.arrow.circlepath"
        case .recentlyAdded: return "sparkles"
        case .mostPlayed: return "chart.bar.fill"
        case .liked: return "heart.fill"
        }
    }

    var usesTags: Bool { self == .tagInclude || self == .tagExclude }
    var usesThresholdDays: Bool { self == .notPlayedSince }
    var usesResultLimit: Bool { self == .mostPlayed || self == .recentlyAdded }
}

@objc(SmartPlaylist)
public final class SmartPlaylist: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var dateCreated: Date
    @NSManaged public var ruleTypeRaw: String
    @NSManaged public var tagIDsData: Data?
    @NSManaged public var thresholdDays: NSNumber?
    @NSManaged public var resultLimit: NSNumber?
    @NSManaged public var matchAllTags: Bool
}

extension SmartPlaylist {
    static func fetchRequest() -> NSFetchRequest<SmartPlaylist> {
        NSFetchRequest<SmartPlaylist>(entityName: "SmartPlaylist")
    }

    var ruleType: SmartRuleType {
        get { SmartRuleType(rawValue: ruleTypeRaw) ?? .recentlyAdded }
        set { ruleTypeRaw = newValue.rawValue }
    }

    /// Stored as JSON rather than a transformable so the attribute stays
    /// queryable-as-data and survives model migrations without a value transformer.
    var tagIDs: [UUID]? {
        get {
            guard let tagIDsData else { return nil }
            return try? JSONDecoder().decode([UUID].self, from: tagIDsData)
        }
        set {
            guard let newValue, !newValue.isEmpty else { tagIDsData = nil; return }
            tagIDsData = try? JSONEncoder().encode(newValue)
        }
    }

    var thresholdDaysValue: Int? {
        get { thresholdDays?.intValue }
        set { thresholdDays = newValue.map(NSNumber.init(value:)) }
    }

    var resultLimitValue: Int? {
        get { resultLimit?.intValue }
        set { resultLimit = newValue.map(NSNumber.init(value:)) }
    }

    var ruleSummary: String {
        switch ruleType {
        case .tagInclude:
            let count = tagIDs?.count ?? 0
            return count == 1 ? "1 tag" : "\(count) tags (\(matchAllTags ? "all" : "any"))"
        case .tagExclude:
            let count = tagIDs?.count ?? 0
            return "excluding \(count) tag\(count == 1 ? "" : "s")"
        case .notPlayedSince:
            return "not played in \(thresholdDaysValue ?? 30) days"
        case .recentlyAdded:
            return "newest \(resultLimitValue ?? 50)"
        case .mostPlayed:
            return "top \(resultLimitValue ?? 25)"
        case .liked:
            return "liked"
        }
    }
}
