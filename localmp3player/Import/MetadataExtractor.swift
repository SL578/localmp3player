import AVFoundation
import Foundation

struct ExtractedMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var artworkData: Data?
    var duration: Double
}

enum MetadataExtractor {
    /// Reads embedded ID3/iTunes tags. Anything missing here falls back to the
    /// filename parser at the call site.
    static func read(from url: URL) async -> ExtractedMetadata {
        let asset = AVURLAsset(url: url)
        var result = ExtractedMetadata(duration: 0)

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            result.duration = seconds.isFinite ? seconds : 0
        }

        guard let items = try? await asset.load(.metadata) else { return result }

        for item in items {
            guard let identifier = item.identifier else { continue }
            switch identifier {
            case .commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName:
                guard result.title == nil else { continue }
                result.title = await string(from: item)
            case .commonIdentifierArtist, .id3MetadataOriginalArtist, .id3MetadataLeadPerformer,
                 .iTunesMetadataArtist, .iTunesMetadataAlbumArtist:
                guard result.artist == nil else { continue }
                result.artist = await string(from: item)
            case .commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum:
                guard result.album == nil else { continue }
                result.album = await string(from: item)
            case .commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt:
                guard result.artworkData == nil, let data = try? await item.load(.dataValue) else { continue }
                result.artworkData = ArtworkThumbnailer.thumbnail(from: data)
            default:
                continue
            }
        }
        return result
    }

    private static func string(from item: AVMetadataItem) async -> String? {
        guard let value = try? await item.load(.stringValue) else { return nil }
        return value.nonEmpty
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
