import CoreData
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the suggester is told about one song. A value, not a `Song`, so an
/// import draft that isn't in the store yet can be asked about the same way.
struct SongFacts {
    var title: String
    var artist: String
    var album: String?
    /// Tags the song already has. Never suggested again.
    var tagNames: [String] = []
}

/// Suggests which of the user's *existing* tags fit a song. It never creates a
/// tag and never applies one — callers show the result for the user to accept.
///
/// Two signals, merged:
/// - **Artist history.** How the user has already tagged other songs by the same
///   artist. Works everywhere, and is the stronger signal when it exists.
/// - **The on-device model** (Apple Intelligence, iOS 26+), constrained by a
///   schema to answer only with names from the tag list. It sees the title,
///   artist and album, plus a handful of the user's own tagged songs as
///   examples. Where it's unavailable this half is skipped silently.
@MainActor
final class TagSuggester {
    private let tags: [Tag]
    /// Canonical artist key → (canonical tag name → songs by that artist with it).
    private let artistTagCounts: [String: [String: Int]]
    private let artistSongCounts: [String: Int]
    /// "Title" by Artist: tag, tag — the user's own tagging, shown to the model.
    private let examples: [String]

    /// Snapshots the library once; one suggester serves a whole batch.
    init(context: NSManagedObjectContext) {
        tags = LibraryQuery.fetchAll(LibraryQuery.allTags(), in: context)

        var tagCounts: [String: [String: Int]] = [:]
        var songCounts: [String: Int] = [:]
        let tagged = LibraryQuery.fetch(LibraryQuery.taggedSongs(), in: context)
        for song in tagged {
            for key in Self.artistKeys(song.artist) {
                songCounts[key, default: 0] += 1
                for tag in song.tags {
                    tagCounts[key, default: [:]][tag.name, default: 0] += 1
                }
            }
        }
        artistTagCounts = tagCounts
        artistSongCounts = songCounts
        examples = Self.pickExamples(from: tagged, tags: tags)
    }

    var hasTags: Bool { !tags.isEmpty }

    /// Display names of the suggested tags, artist history first. Excludes any
    /// the song already carries.
    func suggest(for song: SongFacts) async -> [String] {
        guard hasTags else { return [] }
        let existing = Set(song.tagNames.map(Tag.canonical))

        var picked: [String] = []
        func add(_ canonical: String) {
            guard !existing.contains(canonical), !picked.contains(canonical) else { return }
            picked.append(canonical)
        }

        artistSuggestions(for: song.artist).forEach(add)
        await modelSuggestions(for: song).forEach(add)

        let byName = Dictionary(uniqueKeysWithValues: tags.map { ($0.name, $0.displayName) })
        return picked.compactMap { byName[$0] }
    }

    // MARK: - Artist history

    /// A tag carried by at least half of the user's tagged songs by any artist
    /// credited on this one. Half rather than all, so one oddly tagged song
    /// doesn't veto the rest.
    private func artistSuggestions(for artist: String) -> [String] {
        var result: [String] = []
        for key in Self.artistKeys(artist) {
            guard let total = artistSongCounts[key], let counts = artistTagCounts[key] else { continue }
            let qualifying = counts
                .filter { Double($0.value) >= Double(total) / 2 }
                .sorted { $0.value > $1.value }
                .map(\.key)
            for name in qualifying where !result.contains(name) {
                result.append(name)
            }
        }
        return result
    }

    /// Each artist credited on a song, folded for matching. "Kurousa-P feat.
    /// Hatsune Miku" counts towards both, so a Miku song by a new producer still
    /// picks up how the user tags Miku.
    nonisolated static func artistKeys(_ artist: String) -> [String] {
        let separators = [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " & ", " x ", " × ", ", ", " / ", " and "]
        var parts = [artist.lowercased()]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts
            .map { $0.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty && $0 != "unknown artist" }
    }

    /// Up to two songs per tag, so every tag is illustrated at least once and
    /// the prompt stays well inside the model's context window.
    private static func pickExamples(from songs: [Song], tags: [Tag]) -> [String] {
        var chosen: [Song] = []
        for tag in tags {
            let carrying = songs.filter { $0.tags.contains(tag) && !chosen.contains($0) }
            chosen += carrying.prefix(2)
            if chosen.count >= 24 { break }
        }
        return chosen.map { song in
            let names = song.sortedTags.map(\.displayName).joined(separator: ", ")
            return "\(describe(title: song.title, artist: song.artist, album: song.album)): \(names)"
        }
    }

    private static func describe(title: String, artist: String, album: String?) -> String {
        var line = "\"\(title)\" by \(artist)"
        if let album, !album.isEmpty { line += " (album: \(album))" }
        return line
    }

    // MARK: - On-device model

    /// Whether the model half can run, and if not, why — for Settings to say.
    enum ModelStatus {
        case available
        case appleIntelligenceOff
        case downloading
        case unsupportedDevice
        case unsupportedOS

        var summary: String {
            switch self {
            case .available: return "On"
            case .appleIntelligenceOff: return "Apple Intelligence is off"
            case .downloading: return "Model still downloading"
            case .unsupportedDevice: return "Not supported on this device"
            case .unsupportedOS: return "Needs iOS 26"
            }
        }
    }

    static var modelStatus: ModelStatus {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
            case .unavailable(.modelNotReady): return .downloading
            case .unavailable: return .unsupportedDevice
            }
        }
        #endif
        return .unsupportedOS
    }

    private func modelSuggestions(for song: SongFacts) async -> [String] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await askModel(about: song)
        }
        #endif
        return []
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func askModel(about song: SongFacts) async -> [String] {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return [] }

        // The schema is what keeps the answer inside the user's vocabulary: the
        // model can only emit one of these strings, so there is nothing to
        // validate or fuzzy-match afterwards.
        let tagChoice = DynamicGenerationSchema(name: "Tag", anyOf: tags.map(\.displayName))
        let answer = DynamicGenerationSchema(
            name: "TagChoice",
            properties: [
                .init(
                    name: "tags",
                    description: "The library tags that fit this song. Empty if none clearly fit.",
                    schema: DynamicGenerationSchema(arrayOf: tagChoice, maximumElements: 4)
                )
            ]
        )
        guard let schema = try? GenerationSchema(root: answer, dependencies: []) else { return [] }

        // A fresh session per song: a long-lived one would carry every earlier
        // song in its transcript and run out of context partway through a batch.
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        do {
            let response = try await session.respond(
                to: prompt(for: song),
                schema: schema,
                options: GenerationOptions(samplingMode: .greedy)
            )
            let names = try response.content.value([String].self, forProperty: "tags")
            return names.map(Tag.canonical)
        } catch {
            // Guardrail refusals (some titles trip them), a locale the model
            // doesn't handle, a busy model: all just mean no model suggestions.
            return []
        }
    }
    #endif

    private static let instructions = """
        You help organise a personal music library. Given a song's title, artist \
        and album, choose which of the library's existing tags apply to it. The \
        tags mostly describe genre and the language of the lyrics. Use what you \
        know about the artist and the song. Follow the way the examples are \
        tagged. Only choose a tag you are confident about: choosing no tags is \
        better than guessing.
        """

    private func prompt(for song: SongFacts) -> String {
        var lines = ["Tags in this library: " + tags.map(\.displayName).joined(separator: ", ")]
        if !examples.isEmpty {
            lines.append("")
            lines.append("How songs in this library are tagged:")
            lines += examples.map { "- " + $0 }
        }
        lines.append("")
        lines.append("Song to tag: " + Self.describe(title: song.title, artist: song.artist, album: song.album))
        return lines.joined(separator: "\n")
    }
}
