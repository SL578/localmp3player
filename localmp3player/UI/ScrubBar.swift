import SwiftUI

/// The Now Playing progress bar.
///
/// Hand-rolled rather than a `Slider`, because `Slider` gives exactly one signal
/// for "the finger left the screen" — `onEditingChanged(false)` — and on iOS 26's
/// fluid slider that call never arrives. The previous implementation set an
/// `isScrubbing` flag on the *first* touch and cleared it on release, so the flag
/// latched on permanently at the first drag: the thumb and the elapsed label were
/// pinned to the scrub position for the rest of the session, the seek that was
/// supposed to run on release never ran, and the stale position stayed on screen
/// across song changes. Owning the gesture means owning the end of it.
///
/// Tapping anywhere on the bar seeks there too — a `DragGesture` with a zero
/// minimum distance reports a tap as a drag that ends where it began, so this
/// falls out of the same code path rather than needing a second gesture.
struct ScrubBar: View {
    @Environment(\.theme) private var theme

    let currentTime: Double
    let duration: Double
    /// The song the times belong to. A song change abandons a scrub in progress
    /// rather than carrying its position into the next track.
    let trackID: UUID?
    let onSeek: (Double) -> Void

    private static let trackHeight: CGFloat = 6
    private static let thumbSize: CGFloat = 22

    /// Non-nil only while a finger is down. The bar draws this in preference to
    /// the player's clock, so the ticker doesn't fight the thumb mid-drag.
    @State private var dragTime: Double?

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let filled = position(in: width)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.secondaryText.opacity(0.25))
                        .frame(height: Self.trackHeight)
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: filled, height: Self.trackHeight)
                    Circle()
                        .fill(Color.white)
                        .frame(width: Self.thumbSize, height: Self.thumbSize)
                        .offset(x: filled - Self.thumbSize / 2)
                }
                .frame(height: Self.thumbSize)
                .contentShape(Rectangle())
                // High priority so the enclosing ScrollView doesn't claim the
                // drag: a scrub is mostly horizontal, but a slightly diagonal one
                // would otherwise be handed to the scroll view mid-gesture and
                // this view would never hear that it ended.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { dragTime = time(atX: $0.location.x, width: width) }
                        .onEnded { value in
                            let target = time(atX: value.location.x, width: width)
                            dragTime = nil
                            onSeek(target)
                        }
                )
            }
            .frame(height: Self.thumbSize)

            HStack {
                Text(TimeFormatting.duration(displayedTime))
                Spacer()
                Text(TimeFormatting.duration(duration))
            }
            .font(.caption.monospacedDigit())
            .secondaryText()
        }
        .onChange(of: trackID) { _, _ in dragTime = nil }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(TimeFormatting.duration(displayedTime))
        .accessibilityAdjustableAction { direction in
            let step: Double = 15
            let target = direction == .increment ? displayedTime + step : displayedTime - step
            onSeek(min(max(target, 0), duration))
        }
    }

    /// The finger's position while scrubbing, the player's clock otherwise.
    private var displayedTime: Double { dragTime ?? currentTime }

    /// Centre of the thumb, which is also the width of the filled track. The
    /// thumb is inset by its own radius at both ends so it stays inside the bar
    /// at 0:00 and at the end of the song.
    private func position(in width: CGFloat) -> CGFloat {
        let usable = max(width - Self.thumbSize, 1)
        return Self.thumbSize / 2 + usable * fraction
    }

    private var fraction: CGFloat {
        guard duration > 0 else { return 0 }
        return min(max(CGFloat(displayedTime / duration), 0), 1)
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        let usable = max(width - Self.thumbSize, 1)
        let ratio = min(max((x - Self.thumbSize / 2) / usable, 0), 1)
        return Double(ratio) * duration
    }
}
