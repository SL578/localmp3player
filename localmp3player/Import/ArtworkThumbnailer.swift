import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Embedded cover art is frequently 1500x1500 and can run to a megabyte or more.
/// A copy is stored instead of the original so the store stays a sensible size,
/// but it has to be large enough that the biggest place the app draws it — the
/// 260pt square on Now Playing — is never upscaled.
///
/// It was 320px at quality 0.8, which is under half the 780 physical pixels a
/// 260pt square needs on a 3x screen. Every full-size cover was being blown up
/// 2.4x over JPEG artefacts baked in at a size never meant to be seen this
/// large: soft edges and mushy gradients next to the same file in another
/// player. 1024px clears the 3x case with headroom for a future larger layout,
/// and the higher quality factor stops the compressor from being the limit
/// instead.
///
/// `Song.artworkData` has `allowsExternalBinaryDataStorage`, so blobs this size
/// are written beside the store rather than inside it and don't slow down
/// ordinary fetches. `ArtworkCache` downsamples per display size and keeps the
/// result, so list rows still decode once each rather than per scroll.
enum ArtworkThumbnailer {
    static let maxPixelSize: CGFloat = 1024
    static let compressionQuality: CGFloat = 0.92

    static func thumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    /// Longest edge of an already-stored copy, in pixels. Used to tell artwork
    /// saved at the old size apart from artwork saved at the current one without
    /// adding an attribute to the model to record it — the image itself knows.
    static func pixelWidth(of data: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        return max(width, height)
    }
}
