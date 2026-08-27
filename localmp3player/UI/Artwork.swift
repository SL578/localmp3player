import SwiftUI
import UIKit

/// Decodes embedded artwork once per (image, size) and keeps the downsampled
/// result, so scrolling a list doesn't re-decode a full-resolution JPEG per row.
enum ArtworkCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    static func thumbnail(for data: Data, size: CGFloat, scale: CGFloat) -> UIImage? {
        let pixels = max(1, Int((size * scale).rounded()))
        let key = "\(data.count)-\(data.hashValue)-\(pixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let full = UIImage(data: data) else { return nil }
        let target = CGSize(width: CGFloat(pixels), height: CGFloat(pixels))
        let thumbnail = full.preparingThumbnail(of: target) ?? full
        cache.setObject(thumbnail, forKey: key)
        return thumbnail
    }
}

struct ArtworkThumbnail: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
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
    }

    private var image: UIImage? {
        guard let data else { return nil }
        return ArtworkCache.thumbnail(for: data, size: size, scale: displayScale)
    }
}
