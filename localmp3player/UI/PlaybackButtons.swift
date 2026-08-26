import SwiftUI

/// "Surprise me" — shuffles whichever list it was placed on and starts playing.
/// Used from the Library, playlists, smart playlists, and tags so the behaviour
/// is identical everywhere.
struct ShufflePlayButton: View {
    @EnvironmentObject private var playback: PlaybackController

    let sourceName: String
    let songs: () -> [Song]

    var body: some View {
        Button {
            playback.shufflePlay(songs: songs(), sourceName: sourceName)
        } label: {
            Label("Shuffle Play", systemImage: "shuffle")
        }
        .accessibilityLabel("Shuffle play \(sourceName)")
    }
}

