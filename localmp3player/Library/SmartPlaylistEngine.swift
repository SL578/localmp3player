import CoreData
import Foundation

/// Turns a rule into a live query. Smart playlists never store a song list —
/// every read re-evaluates against the current library.
///
/// A song qualifies when all of these pass, and any criterion left empty passes
/// automatically:
///
/// 1. tag include — any, or all, of `includeTagIDs` (plus "untagged", if set)
/// 2. artist include — any of `includeArtists`
/// 3. behavioural filters — last played, date added, liked
/// 4. not excluded — unless it also matches one of the `exceptIfHas` criteria
///
/// The exception in step 4 rescues a song from an *exclusion* only. It never
/// pulls back in a song that failed steps 1–3.
enum SmartPlaylistEngine {
    static func songs(for rule: SmartRule, in context: NSManagedObjectContext) -> [Song] {
        let matches = LibraryQuery.fetch(fetchRequest(for: rule), in: context)
        guard rule.sortBy == .random else { return matches }
        // Random has no sort descriptor to hand the store, so the shuffle happens
        // here — and after the fetch, so a limit takes a random sample of the
        // whole match set rather than the first N rows of it.
        return Array(matches.shuffled().prefix(rule.resultLimit ?? matches.count))
    }

    static func songs(for playlist: SmartPlaylist, in context: NSManagedObjectContext) -> [Song] {
        songs(for: playlist.rule, in: context)
    }

    /// Counted in the store rather than by fetching the objects, so the editor can
    /// re-run this on every keystroke.
    static func matchCount(for rule: SmartRule, in context: NSManagedObjectContext) -> Int {
        let request = Song.fetchRequest()
        request.predicate = predicate(for: rule)
        let total = (try? context.count(for: request)) ?? 0
        return min(total, rule.resultLimit ?? total)
    }

    // MARK: - Request

    private static func fetchRequest(for rule: SmartRule) -> NSFetchRequest<Song> {
        let request = Song.fetchRequest()
        request.predicate = predicate(for: rule)
        request.sortDescriptors = rule.sortBy.songSort.descriptors
        // A random sample is drawn from every match, so the limit is applied after
        // the shuffle instead of here.
        if let limit = rule.resultLimit, rule.sortBy != .random {
            request.fetchLimit = limit
        }
        return request
    }

    // MARK: - Predicate

    /// `nil` means "no filtering" — an untouched rule matches the whole library.
    private static func predicate(for rule: SmartRule) -> NSPredicate? {
        var clauses: [NSPredicate] = []

        if let tags = tagClause(rule.includeTagIDs, mode: rule.includeTagsMatchMode, untagged: rule.includeUntagged) {
            clauses.append(tags)
        }
        if let artists = artistClause(rule.includeArtists) {
            clauses.append(artists)
        }
        clauses.append(contentsOf: behavioralClauses(for: rule))
        if let survives = exclusionClause(for: rule) {
            clauses.append(survives)
        }

        guard !clauses.isEmpty else { return nil }
        return clauses.count == 1 ? clauses[0] : NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
    }

    private static func behavioralClauses(for rule: SmartRule) -> [NSPredicate] {
        var clauses: [NSPredicate] = []
        if let days = rule.notPlayedInDays, let cutoff = date(daysAgo: days) {
            clauses.append(NSPredicate(format: "lastPlayed == nil OR lastPlayed < %@", cutoff as NSDate))
        }
        if let days = rule.addedWithinDays, let cutoff = date(daysAgo: days) {
            clauses.append(NSPredicate(format: "dateAdded >= %@", cutoff as NSDate))
        }
        if rule.onlyLiked {
            clauses.append(NSPredicate(format: "isLiked == YES"))
        }
        return clauses
    }

    /// `NOT excluded OR rescued` — the one place the exception override applies.
    private static func exclusionClause(for rule: SmartRule) -> NSPredicate? {
        // Tag exclusion is written as a SUBQUERY count rather than `NOT (ANY
        // tags.id == x)`. The SQL store turns that negation into "this song has
        // some tag that isn't x", which is true of any song carrying a second
        // tag — so a song tagged both "2000s" and "rap" sailed through a rule
        // that excluded "rap". Counting the matching tags asks the question the
        // rule actually means: does it carry this tag at all.
        var survives: [NSPredicate] = rule.excludeTagIDs.map {
            NSPredicate(format: "SUBQUERY(tags, $tag, $tag.id == %@).@count == 0", $0 as NSUUID)
        }
        // Excluding "untagged" survives by carrying at least one tag.
        if rule.excludeUntagged {
            survives.append(NSPredicate(format: "tags.@count > 0"))
        }
        // Artist is single-valued, so a plain negation says what it looks like.
        if let artists = artistClause(rule.excludeArtists) {
            survives.append(NSCompoundPredicate(notPredicateWithSubpredicate: artists))
        }
        guard !survives.isEmpty else { return nil }
        let notExcluded = survives.count == 1
            ? survives[0]
            : NSCompoundPredicate(andPredicateWithSubpredicates: survives)

        var rescued: [NSPredicate] = []
        if let tags = tagClause(rule.exceptIfHasTagIDs, mode: .any) { rescued.append(tags) }
        if let artists = artistClause(rule.exceptIfHasArtists) { rescued.append(artists) }
        guard !rescued.isEmpty else { return notExcluded }

        return NSCompoundPredicate(orPredicateWithSubpredicates: [
            notExcluded,
            rescued.count == 1 ? rescued[0] : NSCompoundPredicate(orPredicateWithSubpredicates: rescued)
        ])
    }

    // MARK: - Clauses

    /// `untagged` is one more member of the same group rather than a clause of
    /// its own, so the Any/All mode covers it: with Any it widens the match to
    /// songs carrying nothing, with All it demands they carry nothing *and* the
    /// listed tags — a contradiction the editor warns about rather than hides.
    private static func tagClause(_ ids: [UUID], mode: TagMatchMode, untagged: Bool = false) -> NSPredicate? {
        guard !ids.isEmpty || untagged else { return nil }
        var each = ids.map { NSPredicate(format: "ANY tags.id == %@", $0 as NSUUID) }
        if untagged { each.append(NSPredicate(format: "tags.@count == 0")) }
        if each.count == 1 { return each[0] }
        return mode == .all
            ? NSCompoundPredicate(andPredicateWithSubpredicates: each)
            : NSCompoundPredicate(orPredicateWithSubpredicates: each)
    }

    /// Artists are stored as the name itself — there's no Artist entity, the name
    /// is the identity — so this is a case- and diacritic-insensitive comparison
    /// against the song's own single-valued field.
    private static func artistClause(_ names: [String]) -> NSPredicate? {
        guard !names.isEmpty else { return nil }
        let each = names.map { NSPredicate(format: "artist ==[cd] %@", $0) }
        return each.count == 1 ? each[0] : NSCompoundPredicate(orPredicateWithSubpredicates: each)
    }

    private static func date(daysAgo days: Int) -> Date? {
        Calendar.current.date(byAdding: .day, value: -days, to: Date())
    }
}
