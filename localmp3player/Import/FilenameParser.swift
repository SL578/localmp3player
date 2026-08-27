import Foundation

struct ParsedFilename: Equatable {
    var title: String
    var artist: String?
}

/// Rule-based cleanup for downloaded filenames like
/// `Artist - Song Title (Official Video) [Audio].mp3`, and for the video titles
/// that downloaders write into a file's own tags.
///
/// The result is always shown in an editable confirmation step, so the parser
/// aims to be conservative: it only drops text it is confident is noise, and
/// leaves anything ambiguous for the user to fix.
enum FilenameParser {
    /// A bracketed group is dropped when *every* word in it is one of these (or a
    /// bare number). That kills `(Official Video)`, `[Audio]`, `(Official HD Video)`
    /// and `(4K)` while keeping `(Live at Wembley)` and `(feat. Pharrell)`.
    ///
    /// The Japanese entries are the same idea in the other alphabet: a cover
    /// upload is titled `曲名【歌ってみた】` the way an English one is
    /// `Title (Cover)`, and each is a whole word on its own because these scripts
    /// don't space their words.
    private static let noiseWords: Set<String> = [
        "official", "video", "videos", "audio", "music", "lyric", "lyrics",
        "hd", "hq", "uhd", "sd", "4k", "8k", "1080p", "720p", "480p", "360p",
        "full", "high", "quality", "visualizer", "visualiser", "mv", "pv",
        "explicit", "clean", "free", "download", "downloaded", "new", "hot",
        "with", "version", "upload", "reupload", "hi", "res",
        "歌ってみた", "弾いてみた", "叩いてみた", "踊ってみた", "描いてみた",
        "公式", "高音質", "音源", "フル", "オリジナル曲", "字幕付"
    ]

    /// Only these get stripped when they trail the *unbracketed* text, where a
    /// false positive would eat a real title word.
    private static let trailingNoiseWords: Set<String> = [
        "official", "lyrics", "lyric", "hd", "hq", "uhd",
        "4k", "8k", "1080p", "720p", "480p", "360p", "audio"
    ]

    private static let separators = [" - ", " – ", " — ", " -- ", " _ "]

    /// Every bracket shape that can open a group, paired with its closer. The
    /// CJK ones matter as much as the ASCII ones here: `【】` is where a Japanese
    /// upload puts exactly the text `()` holds in an English one.
    private static let bracketPairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}",
        "（": "）", "［": "］", "｛": "｝",
        "【": "】", "「": "」", "『": "』",
        "〈": "〉", "《": "》", "〔": "〕"
    ]

    static func parse(filename: String) -> ParsedFilename {
        let stem = (filename as NSString).deletingPathExtension
        // Underscores stand in for spaces in downloaded names, so they are read
        // as spaces — unless one is spaced out on both sides, which makes it the
        // separator instead. Replacing unconditionally, as this used to, ran
        // first and left `Artist _ Title` as `Artist Title`, which is why " _ "
        // has been in `separators` all along without ever being reachable.
        let normalized = stem.contains(" _ ") ? stem : stem.replacingOccurrences(of: "_", with: " ")
        // A filename can't contain "/", so the slash split has nothing to do here
        // and is left off rather than being a rule that can never fire.
        let parsed = clean(normalized, splittingOnSlash: false)
        return parsed.title.isEmpty ? ParsedFilename(title: filename, artist: parsed.artist) : parsed
    }

    /// The title frame of a file a video downloader produced.
    ///
    /// Same pipeline as a filename with one step added, because the conventions
    /// are the same conventions — these files' tags *are* the video title, which
    /// is where the filename came from too. The extra step is the slash split,
    /// which only makes sense here: a filename can't hold a `/` in the first
    /// place, so the character survives in the tag when it was flattened to `_`
    /// on the way to disk. That is why parsing the tag beats parsing the name.
    static func parse(videoTitle: String) -> ParsedFilename {
        clean(videoTitle, splittingOnSlash: true)
    }

    // MARK: - Pipeline

    private static func clean(_ value: String, splittingOnSlash: Bool) -> ParsedFilename {
        var working = value
        working = stripLeadingTrackNumber(working)
        if splittingOnSlash { working = takeLeadingSlashSide(working) }
        working = stripNoiseGroups(working)
        working = stripTrailingNoiseWords(working)
        working = stripFeaturedArtists(working)
        working = stripCreditClause(working)
        working = stripOpusNumber(working)
        working = collapseWhitespace(working)

        if let split = splitArtistAndTitle(working) {
            return ParsedFilename(title: split.title, artist: split.artist)
        }
        return ParsedFilename(title: working, artist: nil)
    }

    // MARK: - Steps

    private static func stripLeadingTrackNumber(_ value: String) -> String {
        replacing(value, pattern: #"^\s*\d{1,3}\s*[-.\)]\s+"#, with: "")
    }

    /// Video titles use `/` for two things and both want the left-hand side:
    /// `日本語タイトル / English Title` names one song twice, and
    /// `曲名/歌い手` names the song and then who sang it.
    ///
    /// The guard is that the left side has to contain whitespace. Without it
    /// `AC/DC - Thunderstruck` becomes `AC`, and a band with a slash in its name
    /// is a far worse thing to break than a `Scarborough Fair/Canticle` losing
    /// its second half in an editable field. A phrase on the left is what makes
    /// this a title boundary rather than a spelling.
    private static func takeLeadingSlashSide(_ value: String) -> String {
        guard let index = topLevelSlashIndex(in: value) else { return value }
        let left = String(value[value.startIndex..<index]).trimmingCharacters(in: .whitespaces)
        let right = String(value[value.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty, !right.isEmpty, left.contains(" ") || left.contains("　") else { return value }
        return left
    }

    /// First slash that isn't inside a bracket group, so `(A/B) - Title` is left
    /// alone.
    private static func topLevelSlashIndex(in value: String) -> String.Index? {
        var depth = 0
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if bracketPairs[character] != nil {
                depth += 1
            } else if bracketPairs.values.contains(character) {
                depth = max(0, depth - 1)
            } else if character == "/" && depth == 0 {
                return index
            }
            index = value.index(after: index)
        }
        return nil
    }

    /// Walks the string once, buffering the contents of top-level bracket groups
    /// and dropping the ones that read as noise. Nested brackets are preserved
    /// inside the buffer so `(feat. X [Remix])` survives intact.
    private static func stripNoiseGroups(_ value: String) -> String {
        var result = ""
        var buffer = ""
        var opener: Character = "("
        var depth = 0

        for character in value {
            if bracketPairs[character] != nil {
                if depth == 0 {
                    buffer = ""
                    opener = character
                } else {
                    buffer.append(character)
                }
                depth += 1
            } else if bracketPairs.values.contains(character) {
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
        while let last = words.last, last.allSatisfy({ "-–—_|/".contains($0) }) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// Drops a trailing `feat. …` / `ft. …` run.
    ///
    /// Guest credits are the artist's business, not the song's, and they run to
    /// the end of the line once they start — `feat. 雨衣, Gemini, ミク` is one
    /// clause, not three fields. A *bracketed* `(feat. X)` is deliberately left
    /// where it is: someone who bracketed it was marking it as part of the title.
    private static func stripFeaturedArtists(_ value: String) -> String {
        // The lookbehind is for `20 ft Under`: a bare `ft` after a number is a
        // unit, not a credit, and eating the rest of the line there would throw
        // away the title itself.
        replacing(value, pattern: #"(?<!\d)\s+(feat\.?|ft\.?|featuring)\s+.+$"#, with: "")
    }

    /// Drops a trailing performance credit — `, conducted by X`,
    /// `, performed by Y`. Common on uploads of classical recordings, where the
    /// work is the song and the performance is provenance.
    private static func stripCreditClause(_ value: String) -> String {
        let verbs = "conducted|performed|played|sung|arranged|orchestrated|directed|remixed|covered|produced"
        return replacing(value, pattern: #"(\s*[,—–-]\s*|\s+)(\#(verbs))\s+by\s+.+$"#, with: "")
    }

    /// Drops a trailing opus/catalogue number — `, Op. 71a`, `Op 35`, `BWV 1043`,
    /// `K. 550`. These are how a classical work is *catalogued*; the user reads
    /// the name.
    private static func stripOpusNumber(_ value: String) -> String {
        // Single-letter catalogues (Mozart's K, Schubert's D) require the period.
        // Without it the pattern also matches `Level 42` and `Sum 41`, and a
        // rule that renames a song to `Level` is worse than one that leaves
        // `K 550` alone.
        let number = #"\.?\s*\d+[a-z]?(\s*(no\.?|№)\s*\d+)?"#
        let pattern = #"\s*,?\s*(\b(op|opus|bwv|kv|hob|rv|woo)\#(number)|\b(k|d)\.\s*\d+[a-z]?)\s*$"#
        return replacing(value, pattern: pattern, with: "")
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
        value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "　" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ value: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
    }
}
