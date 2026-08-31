import CoreData
import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.theme) private var theme
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(data: playback.currentSong?.artworkData, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(playback.currentSong?.title ?? "")
                    .font(.subheadline)
                    .lineLimit(1)
                Text(playback.currentSong?.artist ?? "")
                    .font(.caption)
                    .secondaryText()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(theme.primaryText)
                    .instantSymbolSwap(value: playback.isPlaying)
            }
            .buttonStyle(.plain)
            Button { playback.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(theme.primaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(theme.primaryText)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the full player")
    }
}

/// The full player. There is exactly one way in — the mini player bar — so
/// there is exactly one presentation and one design. Tapping a song used to
/// push a second copy onto whichever stack it was tapped from, which arrived
/// from a different edge and exited through a different control.
///
/// Its dismiss control is a leading chevron rather than a trailing Done, to read
/// as "back to where I was" the way every other screen in the app does.
struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.managedObjectContext) private var context
    @Environment(\.uiMode) private var uiMode
    @EnvironmentObject private var playback: PlaybackController

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ArtworkThumbnail(data: playback.currentSong?.artworkData, size: 260)
                    .modeShadow(uiMode, radius: 12)

                trackLabels
                progress
                transportControls
                secondaryControls

                if !playback.queue.isEmpty {
                    Divider().padding(.top, 4)
                    queueSection
                }
            }
            .padding()
        }
        // A pushed navigation destination is its own view controller with its own
        // default background — it doesn't inherit RootView's. Every other screen
        // gets this from `themedScrollBackground` on its List/Form; this one has
        // neither, so it needs the background and text colour set directly.
        .background(theme.background)
        .foregroundStyle(theme.primaryText)
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
        .modeNavigationChrome(uiMode, theme: theme)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ToolbarGlyph("Close player", systemImage: "chevron.left") { dismiss() }
            }
        }
    }

    // MARK: - Pieces

    private var trackLabels: some View {
        VStack(spacing: 4) {
            Text(playback.currentSong?.title ?? "Nothing Playing")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(playback.currentSong?.artist ?? "")
                .secondaryText()
            if let source = playback.queueSourceName {
                Text("Playing from \(source)")
                    .font(.caption)
                    .tertiaryText()
            }
        }
    }

    private var progress: some View {
        ProgressSection(
            clock: playback.clock,
            duration: playback.duration,
            trackID: playback.currentSong?.id,
            onSeek: { playback.seek(to: $0) }
        )
    }

    private var transportControls: some View {
        // Colours are explicit: `.buttonStyle(.plain)` opts out of the tint, so
        // anything left unstyled falls back to the inherited foreground styles.
        HStack(spacing: 40) {
            Button { playback.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .foregroundStyle(theme.primaryText)
            }
            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 62))
                    .foregroundStyle(theme.accent)
                    .instantSymbolSwap(value: playback.isPlaying)
            }
            Button { playback.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .foregroundStyle(theme.primaryText)
            }
        }
        .buttonStyle(.plain)
    }

    private var secondaryControls: some View {
        HStack(spacing: 28) {
            Button { playback.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(playback.isShuffled ? theme.accent : theme.secondaryText)
            }
            .accessibilityLabel(playback.isShuffled ? "Shuffle on" : "Shuffle off")

            if let song = playback.currentSong {
                Button {
                    song.isLiked.toggle()
                    try? context.save()
                } label: {
                    Image(systemName: song.isLiked ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(song.isLiked ? theme.liked : theme.secondaryText)
                }
                .accessibilityLabel(song.isLiked ? "Liked" : "Like")
            }

            Button { playback.cycleRepeatMode() } label: {
                Image(systemName: playback.repeatMode.systemImage)
                    .font(.title3)
                    .foregroundStyle(playback.repeatMode == .off ? theme.secondaryText : theme.accent)
            }
            .accessibilityLabel(playback.repeatMode.label)
        }
        .buttonStyle(.plain)
        .modeAnimation(uiMode, value: playback.isShuffled)
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Up Next")
                    .font(.headline)
                Spacer()
                Text("\(playback.queue.count) songs")
                    .font(.caption)
                    .secondaryText()
            }

            ForEach(Array(playback.queue.enumerated()), id: \.element.id) { index, song in
                Button {
                    playback.jump(to: index)
                } label: {
                    HStack(spacing: 10) {
                        if index == playback.queueIndex {
                            Image(systemName: playback.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                                .frame(width: 16)
                                .instantSymbolSwap(value: playback.isPlaying)
                        } else {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .secondaryText()
                                .frame(width: 16)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.title)
                                .lineLimit(1)
                            Text(song.artist)
                                .font(.caption)
                                .secondaryText()
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(TimeFormatting.duration(song.duration))
                            .font(.caption.monospacedDigit())
                            .secondaryText()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == playback.queueIndex ? theme.accent : theme.primaryText)
                Divider()
            }
        }
    }
}

/// The scrub bar and the clock it draws.
///
/// Split into its own view so the once-a-second tick invalidates this and
/// nothing else. Read straight off `playback` in the player's body instead and
/// the whole screen — artwork, labels, transport, queue — rebuilds every second.
private struct ProgressSection: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    let trackID: UUID?
    let onSeek: (Double) -> Void

    var body: some View {
        ScrubBar(
            currentTime: clock.currentTime,
            duration: duration,
            trackID: trackID,
            onSeek: onSeek
        )
    }
}
