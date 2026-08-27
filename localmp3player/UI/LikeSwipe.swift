import SwiftUI
import UIKit

/// Swipe a song row right to like it, at a distance the app chooses.
///
/// `swipeActions(edge: .leading)` gives no control over its full-swipe trigger.
/// Measured on an iPhone 17: a 200pt pull across a 402pt row (50%) only parks
/// the Like button open, and 240pt (60%) fires it. That is most of the screen
/// for the action used most often, and there is no API to shorten it — so the
/// leading swipe is the app's own gesture now. The trailing edge is untouched
/// and still uses `swipeActions`.
///
/// `simultaneousGesture`, not `gesture` or `highPriorityGesture`: the row is
/// still a `List` row, and the scroll view's pan and the trailing swipe's own
/// recognizer both have to keep working. This gesture decides on the first few
/// points of movement whether it is looking at a horizontal drag at all, and
/// stays out of the way of everything else.
struct LikeSwipe: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.uiMode) private var uiMode
    @ObservedObject var song: Song
    let toggle: () -> Void

    /// Share of the row's width the finger has to cross before releasing.
    private static let triggerFraction: CGFloat = 0.45
    /// Never ask for less than this, so a narrow row can't make the gesture
    /// fire by accident.
    private static let minimumTravel: CGFloat = 70
    /// How far a drag runs before it commits to being horizontal or vertical.
    /// Under this it could still turn out to be a scroll, and nothing moves.
    private static let axisLock: CGFloat = 10

    private enum Axis { case horizontal, vertical }

    @State private var offset: CGFloat = 0
    @State private var axis: Axis?
    @State private var rowWidth: CGFloat = 0
    /// Whether the last `onChanged` was already past the trigger, so the haptic
    /// fires on the crossing rather than on every frame beyond it.
    @State private var armed = false

    private var threshold: CGFloat {
        max(rowWidth * Self.triggerFraction, Self.minimumTravel)
    }

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            track
            content.offset(x: offset)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { rowWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in rowWidth = width }
            }
        }
        .simultaneousGesture(drag)
        .accessibilityAction(named: song.isLiked ? "Unlike" : "Like", toggle)
    }

    /// Only drawn while the finger is down. The heart fills in once the drag is
    /// far enough to fire, which is the only signal the trigger point exists.
    @ViewBuilder
    private var track: some View {
        if offset > 0 {
            Image(systemName: armed ? "heart.fill" : "heart")
                .font(.headline)
                .foregroundStyle(theme.liked)
                .opacity(min(1, offset / max(threshold, 1) + 0.35))
                .padding(.leading, 12)
                .accessibilityHidden(true)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                if axis == nil {
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    guard max(horizontal, vertical) >= Self.axisLock else { return }
                    axis = horizontal > vertical ? .horizontal : .vertical
                }
                guard axis == .horizontal else { return }
                // Rightward only. A leftward drag belongs to the trailing swipe
                // actions and is left entirely alone.
                offset = max(0, value.translation.width)
                let past = offset >= threshold
                if past != armed {
                    armed = past
                    if past { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                }
            }
            .onEnded { _ in
                let fired = armed
                axis = nil
                armed = false
                withAnimation(uiMode.animation) { offset = 0 }
                if fired { toggle() }
            }
    }
}

extension View {
    /// Swipe-right-to-like on a song row. See `LikeSwipe`.
    func likeSwipe(_ song: Song, toggle: @escaping () -> Void) -> some View {
        modifier(LikeSwipe(song: song, toggle: toggle))
    }
}
