import CoreData
import Foundation

/// `name` is the lowercased canonical form used for uniqueness and predicates;
/// `displayName` preserves the casing the user typed.
@objc(Tag)
public final class Tag: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var displayName: String
    @NSManaged public var colorHex: String?
    @NSManaged public var songs: Set<Song>
}

extension Tag {
    static func fetchRequest() -> NSFetchRequest<Tag> {
        NSFetchRequest<Tag>(entityName: "Tag")
    }

    static func canonical(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Returns the existing tag for this name, or creates one. Case-insensitive.
    @discardableResult
    static func findOrCreate(named raw: String, in context: NSManagedObjectContext) -> Tag? {
        let display = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalName = canonical(raw)
        guard !canonicalName.isEmpty else { return nil }

        let request = fetchRequest()
        request.predicate = NSPredicate(format: "name == %@", canonicalName)
        request.fetchLimit = 1
        if let existing = try? context.fetch(request).first { return existing }

        let tag = Tag(context: context)
        tag.id = UUID()
        tag.name = canonicalName
        tag.displayName = display
        tag.colorHex = TagPalette.suggestedHex(for: canonicalName)
        return tag
    }
}

/// Something that carries a color from `TagPalette`, so one picker can paint all
/// of them. `NSManagedObject` already conforms to `ObservableObject`, which is
/// what lets the picker observe whichever one it was handed.
protocol Colorable: NSManagedObject, ObservableObject {
    var colorHex: String? { get set }
    /// What the picker's preview chip reads.
    var colorLabel: String { get }
    /// Naming the screen after the thing being colored, rather than a generic
    /// "Color", so the sheet says what it is a color for.
    static var colorTitle: String { get }
    static var colorFooter: String { get }
}

extension Tag: Colorable {
    var colorLabel: String { displayName }
    static var colorTitle: String { "Tag Color" }
    static var colorFooter: String {
        "Tag colors show on song chips and make tags easier to pick out at a glance in CarPlay."
    }
}

enum TagPalette {
    /// Named so the picker can show something meaningful instead of a hex code.
    struct Swatch: Identifiable, Hashable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let swatches: [Swatch] = [
        Swatch(name: "Red", hex: "FF6B6B"),
        Swatch(name: "Orange", hex: "F7B267"),
        Swatch(name: "Yellow", hex: "F4D35E"),
        Swatch(name: "Green", hex: "8AC926"),
        Swatch(name: "Teal", hex: "4CC9A7"),
        Swatch(name: "Blue", hex: "4CA3DD"),
        Swatch(name: "Indigo", hex: "7B8CDE"),
        Swatch(name: "Purple", hex: "B08BEB"),
        Swatch(name: "Pink", hex: "E27396"),
        Swatch(name: "Gray", hex: "9E9E9E")
    ]

    static let hexes = swatches.map(\.hex)

    static func name(for hex: String?) -> String {
        guard let hex else { return "Custom" }
        return swatches.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }?.name ?? "Custom"
    }

    /// Deterministic so a tag keeps its color across devices and CarPlay sessions.
    static func suggestedHex(for canonicalName: String) -> String {
        let hash = canonicalName.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return hexes[Int(hash % UInt32(hexes.count))]
    }
}
