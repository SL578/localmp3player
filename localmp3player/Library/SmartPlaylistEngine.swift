import CoreData
import Foundation

/// The value form of a smart-playlist rule. Keeping it separate from the managed
/// object lets the editor preview a rule live without mutating stored state.
struct SmartRule: Equatable {
    var type: SmartRuleType
    var tagIDs: [UUID] = []
    var matchAllTags = false
    var thresholdDays: Int?
    var resultLimit: Int?
}

/// Turns a rule into a live fetch request. Smart playlists never store a song
/// list — every read re-evaluates against the current library.
enum SmartPlaylistEngine {
    static func fetchRequest(for rule: SmartRule, in context: NSManagedObjectContext) -> NSFetchRequest<Song> {
        let request = Song.fetchRequest()

        switch rule.type {
        case .tagInclude:
            let names = tagNames(for: rule.tagIDs, in: context)
            if names.isEmpty {
                request.predicate = NSPredicate(value: false)
            } else if rule.matchAllTags {
                let clauses = names.map { NSPredicate(format: "ANY tags.name == %@", $0) }
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
            } else {
                request.predicate = NSPredicate(format: "ANY tags.name IN %@", names)
            }
            request.sortDescriptors = SongSort.title.descriptors

        case .tagExclude:
            let names = tagNames(for: rule.tagIDs, in: context)
            request.predicate = names.isEmpty
                ? NSPredicate(value: true)
                : NSPredicate(format: "NOT (ANY tags.name IN %@)", names)
            request.sortDescriptors = SongSort.title.descriptors

        case .notPlayedSince:
            let days = rule.thresholdDays ?? 30
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            request.predicate = NSPredicate(format: "lastPlayed == nil OR lastPlayed < %@", cutoff as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: "lastPlayed", ascending: true)]

        case .recentlyAdded:
            request.sortDescriptors = SongSort.dateAdded.descriptors
            request.fetchLimit = rule.resultLimit ?? 50

        case .mostPlayed:
            request.predicate = NSPredicate(format: "playCount > 0")
            request.sortDescriptors = SongSort.playCount.descriptors
            request.fetchLimit = rule.resultLimit ?? 25

        case .liked:
            request.predicate = NSPredicate(format: "isLiked == YES")
            request.sortDescriptors = SongSort.title.descriptors
        }
        return request
    }

    static func fetchRequest(for playlist: SmartPlaylist, in context: NSManagedObjectContext) -> NSFetchRequest<Song> {
        fetchRequest(for: playlist.rule, in: context)
    }

    static func songs(for rule: SmartRule, in context: NSManagedObjectContext) -> [Song] {
        LibraryQuery.fetch(fetchRequest(for: rule, in: context), in: context)
    }

    static func songs(for playlist: SmartPlaylist, in context: NSManagedObjectContext) -> [Song] {
        songs(for: playlist.rule, in: context)
    }

    /// Rules are stored by tag ID but evaluated by canonical name, so the
    /// predicate stays a plain string comparison the store can index.
    private static func tagNames(for ids: [UUID], in context: NSManagedObjectContext) -> [String] {
        guard !ids.isEmpty else { return [] }
        let request = Tag.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", ids)
        return ((try? context.fetch(request)) ?? []).map(\.name)
    }
}

extension SmartPlaylist {
    var rule: SmartRule {
        get {
            SmartRule(
                type: ruleType,
                tagIDs: tagIDs ?? [],
                matchAllTags: matchAllTags,
                thresholdDays: thresholdDaysValue,
                resultLimit: resultLimitValue
            )
        }
        set {
            ruleType = newValue.type
            tagIDs = newValue.tagIDs.isEmpty ? nil : newValue.tagIDs
            matchAllTags = newValue.matchAllTags
            thresholdDaysValue = newValue.thresholdDays
            resultLimitValue = newValue.resultLimit
        }
    }
}
