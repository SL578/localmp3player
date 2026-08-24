import Foundation

struct ParsedFilename: Equatable {
    var title: String
    var artist: String?
}

/// Rule-based cleanup for downloaded filenames like
/// `Artist - Song Title (Official Video) [Audio].mp3`.
///
/// The result is always shown in an editable confirmation step, so the parser
/// aims to be conservative: it only drops text it is confident is noise, and
/// leaves anything ambiguous for the user to fix.
enum FilenameParser {
    /// A bracketed group is dropped when *every* word in it is one of these (or a
    /// bare number). That kills `(Official Video)`, `[Audio]`, `(Official HD Video)`
    /// and `(4K)` while keeping `(Live at Wembley)` and `(feat. Pharrell)`.
    private static let noiseWords: Set<String> = [
        "official", "video", "videos", "audio", "music", "lyric", "lyrics",
        "hd", "hq", "uhd", "sd", "4k", "8k", "1080p", "720p", "480p", "360p",
        "full", "high", "quality", "visualizer", "visualiser", "mv", "pv",
        "explicit", "clean", "free", "download", "downloaded", "new", "hot",
        "with", "version", "upload", "reupload", "hi", "res"
    ]

    /// Only these get stripped when they trail the *unbracketed* text, where a
    /// false positive would eat a real title word.
    private static let trailingNoiseWords: Set<String> = [
        "official", "lyrics", "lyric", "hd", "hq", "uhd",
        "4k", "8k", "1080p", "720p", "480p", "360p", "audio"
    ]

    private static let separators = [" - ", " – ", " — ", " -- ", " _ "]

    static func parse(filename: String) -> ParsedFilename {
        var working = (filename as NSString).deletingPathExtension
        working = working.replacingOccurrences(of: "_", with: " ")
        working = stripLeadingTrackNumber(working)
        working = stripNoiseGroups(working)
        working = stripTrailingNoiseWords(working)
        working = collapseWhitespace(working)

        if let split = splitArtistAndTitle(working) {
            return ParsedFilename(title: split.title, artist: split.artist)
        }
        return ParsedFilename(title: working.isEmpty ? filename : working, artist: nil)
    }

    // MARK: - Steps

    private static func stripLeadingTrackNumber(_ value: String) -> String {
        replacing(value, pattern: #"^\s*\d{1,3}\s*[-.\)]\s+"#, with: "")
    }

    /// Walks the string once, buffering the contents of top-level bracket groups
    /// and dropping the ones that read as noise. Nested brackets are preserved
    /// inside the buffer so `(feat. X [Remix])` survives intact.
    private static func stripNoiseGroups(_ value: String) -> String {
        let closers: Set<Character> = [")", "]", "}"]
        var result = ""
        var buffer = ""
        var opener: Character = "("
        var depth = 0

        for character in value {
            if character == "(" || character == "[" || character == "{" {
                if depth == 0 {
                    buffer = ""
                    opener = character
                } else {
                    buffer.append(character)
                }
                depth += 1
            } else if closers.contains(character) {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0 {
                    if !isNoise(buffer) {
                        result += String(opener) + buffer.trimmingCharacters(in: .whitespaces) + String(character)
                    }
                    buffer = ""
                } else {
                    buffer.append(character)
                }
            } else if depth > 0 {
                buffer.append(character)
            } else {
                result.append(character)
            }
        }
        // Unbalanced opener — keep the tail unless it is noise.
        if depth > 0 && !isNoise(buffer) {
            result += " " + buffer
        }
        return result
    }

    private static func isNoise(_ group: String) -> Bool {
        let words = tokenize(group)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { noiseWords.contains($0) || Int($0) != nil }
    }

    private static func stripTrailingNoiseWords(_ value: String) -> String {
        var words = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let last = words.last {
            let normalized = normalizeWord(last)
            guard !normalized.isEmpty, trailingNoiseWords.contains(normalized) else { break }
            words.removeLast()
        }
        // Drop a separator left dangling by the removal, e.g. "Blue Monday -".
        while let last = words.last, last.allSatisfy({ "-–—_|".contains($0) }) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    private static func splitArtistAndTitle(_ value: String) -> (artist: String, title: String)? {
        guard let separator = separators.first(where: { value.contains($0) }) else { return nil }
        let components = value.components(separatedBy: separator)
        guard components.count >= 2 else { return nil }

        let left = collapseWhitespace(components[0])
        let right = collapseWhitespace(components.dropFirst().joined(separator: separator))
        guard !left.isEmpty, !right.isEmpty else { return nil }

        // `Artist - Title` is by far the dominant convention for downloaded files.
        // The confirmation UI offers a one-tap swap for the files that aren't.
        return (artist: left, title: right)
    }

    // MARK: - Helpers

    private static func tokenize(_ value: String) -> [String] {
        value.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { normalizeWord(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeWord(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ value: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
    }
}
