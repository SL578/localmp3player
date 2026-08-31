import Combine
import Foundation

/// The playing position, published on its own so a ticking clock doesn't
/// invalidate everything that observes playback.
///
/// `currentTime` used to be `@Published` on `PlaybackController`, which meant the
/// 1 Hz ticker sent `objectWillChange` through the controller once a second.
/// `RootView` observes the controller, so every tick rebuilt all four tab panes'
/// view structs — including the three off screen, each with its own `List` and
/// search controller. Nothing looked wrong; the app was simply doing a full tree
/// rebuild every second for the sake of one progress bar.
///
/// Splitting it out costs one extra object and makes the dependency honest: only
/// a view that actually draws the position observes this, and everything else
/// hears from the controller only when something it cares about really changes.
///
/// `PlaybackController` holds this as a plain `let`. That is the whole point — a
/// stored reference doesn't republish its owner, so **don't** make it
/// `@Published`, and don't add a `currentTime` passthrough that views read from
/// the controller: reading it there compiles and then never updates.
final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
}
