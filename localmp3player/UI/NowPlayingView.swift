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
        // A `List` rather than a `ScrollView` so Up Next can be edited in place:
        // long-press a row to drag it, swipe it to take it out. The player
        // itself is a handful of rows above the queue, separators hidden, so it
        // still reads as one screen rather than a table.
        List {
            playerRow {
                ArtworkThumbnail(data: playback.currentSong?.artworkData, size: 260)
                    .modeShadow(uiMode, radius: 12)
            }
            playerRow { trackLabels }
            playerRow { progress }
            playerRow { transportControls }
            playerRow { secondaryControls }

            if !playback.queue.isEmpty {
                queueHeader
                queueRows
            }
        }
        .listStyle(.plain)
        // A presented navigation stack has its own default background — it
        // doesn't inherit RootView's — so the list states the theme's itself.
        .themedScrollBackground(theme)
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
        .modeNavigationChrome(uiMode, theme: theme)
        .modeToolbar(uiMode) {
            ToolbarItem(placement: .topBarLeading) {
                ToolbarGlyph("Close player", systemImage: "chevron.left") { dismiss() }
            }
        }
    }

    /// One piece of the player as a list row: centred, on the themed background,
    /// with no separator, so the rows above Up Next don't look like rows.
    private func playerRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowBackground(theme.background)
            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
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

    /// A row rather than a section header: a plain list pins its headers and
    /// gives them a background of their own, which the player doesn't want.
    private var queueHeader: some View {
        UpNextHeader(
            clock: playback.clock,
            count: playback.queue.count,
            duration: playback.duration,
            upcomingSeconds: playback.queue.dropFirst(playback.queueIndex + 1).map(\.song).totalDuration
        )
        .padding(.top, 8)
        .listRowBackground(theme.background)
    }

    private var queueRows: some View {
        ForEach(Array(playback.queue.enumerated()), id: \.element.id) { index, entry in
            let isCurrent = entry.id == playback.currentEntryID
            QueueRow(song: entry.song, position: index + 1, isCurrent: isCurrent, isPlaying: playback.isPlaying)
                .foregroundStyle(isCurrent ? theme.accent : theme.primaryText)
                .listRowBackground(theme.background)
                .contentShape(Rectangle())
                .onTapGesture { playback.jump(to: index) }
                // Takes the row out of the queue and nothing else, so it keeps
                // the role, and comes out blue like every other detach.
                .swipeActions(edge: .trailing) {
                    if !isCurrent {
                        Button(role: .destructive) {
                            playback.removeFromQueue(atOffsets: IndexSet(integer: index))
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                }
        }
        .onMove { playback.moveInQueue(fromOffsets: $0, toOffset: $1) }
    }
}

/// One song in Up Next.
private struct QueueRow: View {
    let song: Song
    let position: Int
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isCurrent {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                    .instantSymbolSwap(value: isPlaying)
            } else {
                Text("\(position)")
                    .font(.caption.monospacedDigit())
                    .secondaryText()
                    .frame(width: 22)
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
        .padding(.vertical, 2)
    }
}

/// "Up Next — 12 songs · 31 min left". The time left counts down with the song,
/// so this observes the clock in its own small view, the way the scrub bar
/// does; read in the player's body instead and the whole screen — queue
/// included — would rebuild every second.
private struct UpNextHeader: View {
    @ObservedObject var clock: PlaybackClock
    let count: Int
    let duration: Double
    let upcomingSeconds: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Up Next")
                .font(.headline)
            Spacer()
            Text("\(count) song\(count == 1 ? "" : "s") · \(TimeFormatting.totalLength(remaining)) left")
                .font(.caption)
                .secondaryText()
        }
    }

    private var remaining: Double {
        upcomingSeconds + max(duration - clock.currentTime, 0)
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
