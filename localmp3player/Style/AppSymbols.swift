import Foundation

/// Glyphs that appear in more than one place, named once so they can't drift
/// apart again. Anything used on a single screen stays inline.
enum AppSymbol {
    /// Edit, everywhere it appears: songs, tags, playlists, smart playlists.
    ///
    /// Sliders rather than a pencil. A pencil reads as "change the name" — which
    /// is what `rename` is for — while Edit opens the whole thing for changes.
    static let edit = "slider.horizontal.3"

    /// Rename only, where a name really is the one thing being changed.
    static let rename = "pencil"

    static let delete = "trash"
    static let done = "checkmark"
}
