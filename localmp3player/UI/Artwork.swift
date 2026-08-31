import SwiftUI
import UIKit

/// Decodes embedded artwork once per (image, size) and keeps the downsampled
/// result, so scrolling a list doesn't re-decode a full-resolution JPEG per row.
///
/// **The decode runs off the main thread.** `UIImage(data:)` followed by
/// `preparingThumbnail` on a full-size cover is tens of milliseconds, and it used
/// to happen inside `ArtworkThumbnail`'s body — so every row scrolled into view
/// for the first time stalled the main thread, which was the app's largest
/// remaining source of scroll stutter. A row now draws the placeholder for a
/// frame or two and fills in when the decode lands; every later sighting is a
/// cache hit and draws immediately.
///
/// The module builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an
/// ordinary `async` method here would still run *on* the main actor and change
/// nothing. `decode` is `nonisolated` and reached through `Task.detached` for
/// that reason — don't drop either without checking that setting.
enum ArtworkCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    /// Identifies a decoded thumbnail. Rows are recycled, so callers hold on to
    /// this to tell "the image I decoded" from "the image this row wants now".
    static func key(for data: Data, size: CGFloat, scale: CGFloat) -> String {
        "\(data.count)-\(data.hashValue)-\(pixels(size: size, scale: scale))"
    }

    /// A cache lookup and nothing else — no decode, so this is safe to call from
    /// a view body on every render.
    static func cached(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// Returns the thumbnail, decoding it off the main thread if it isn't cached.
    static func thumbnail(for data: Data, size: CGFloat, scale: CGFloat) async -> UIImage? {
        let key = key(for: data, size: size, scale: scale)
        if let hit = cached(key) { return hit }

        let target = pixels(size: size, scale: scale)
        let work = Task.detached(priority: .userInitiated) { decode(data, pixels: target) }
        guard let decoded = await work.value else { return nil }

        cache.setObject(decoded, forKey: key as NSString)
        return decoded
    }

    private static func pixels(size: CGFloat, scale: CGFloat) -> Int {
        max(1, Int((size * scale).rounded()))
    }

    nonisolated private static func decode(_ data: Data, pixels: Int) -> UIImage? {
        guard let full = UIImage(data: data) else { return nil }
        let target = CGSize(width: CGFloat(pixels), height: CGFloat(pixels))
        return full.preparingThumbnail(of: target) ?? full
    }
}

struct ArtworkThumbnail: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let data: Data?
    let size: CGFloat

    /// What this view decoded, tagged with the key it was decoded for. A cache
    /// hit never writes it, so the steady state renders without touching
    /// `@State` at all — which matters inside a `List`, where a row that
    /// invalidates itself while UIKit is still configuring the cell can come up
    /// with no swipe actions. The key is carried because rows are recycled:
    /// without it, a reused row would show the previous song's cover until its
    /// own decode landed.
    @State private var decoded: (key: String, image: UIImage)?

    var body: some View {
        let key = data.map { ArtworkCache.key(for: $0, size: size, scale: displayScale) }
        Group {
            if let image = image(for: key) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.surface)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
        .task(id: key) { await load() }
    }

    private func image(for key: String?) -> UIImage? {
        guard let key else { return nil }
        if let hit = ArtworkCache.cached(key) { return hit }
        return decoded?.key == key ? decoded?.image : nil
    }

    private func load() async {
        guard let data else { return }
        let key = ArtworkCache.key(for: data, size: size, scale: displayScale)
        // Already cached: the body drew it without ever consulting `decoded`, so
        // writing state here would be a re-render for nothing.
        guard ArtworkCache.cached(key) == nil else { return }
        guard let image = await ArtworkCache.thumbnail(for: data, size: size, scale: displayScale) else { return }
        decoded = (key, image)
    }
}
