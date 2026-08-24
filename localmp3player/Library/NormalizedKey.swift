import Foundation

/// Builds the duplicate-detection key stored on `Song.normalizedKey`.
/// Never shown in the UI — only used for exact-match lookups.
enum NormalizedKey {
    static func make(title: String, artist: String) -> String {
        normalize(title) + "|" + normalize(artist)
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
