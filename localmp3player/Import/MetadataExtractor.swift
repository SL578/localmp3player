import AVFoundation
import Foundation

struct ExtractedMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var artworkData: Data?
    var duration: Double
    /// True when the tags read like a video download rather than a music file:
    /// the title is a video title and the artist is a channel name. See
    /// `isVideoSourceURL`.
    var isVideoDownload: Bool = false
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
            case .id3MetadataUserText, .id3MetadataComments, .id3MetadataOfficialAudioSourceWebpage,
                 .id3MetadataOfficialAudioFileWebpage, .iTunesMetadataUserComment:
                guard !result.isVideoDownload, let value = await string(from: item) else { continue }
                result.isVideoDownload = isVideoSourceURL(value)
            default:
                continue
            }
        }
        return result
    }

    /// Artwork on its own, for re-reading a file already in the library without
    /// paying for the rest of its tags.
    static func artwork(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items {
            switch item.identifier {
            case .commonIdentifierArtwork?, .id3MetadataAttachedPicture?, .iTunesMetadataCoverArt?:
                guard let data = try? await item.load(.dataValue) else { continue }
                if let thumbnail = ArtworkThumbnailer.thumbnail(from: data) { return thumbnail }
            default:
                continue
            }
        }
        return nil
    }

    /// A file downloaded from YouTube carries the source URL in its tags —
    /// `yt-dlp` writes it to `purl` and to the comment, both of which land in
    /// ID3 as user-text frames. Its presence is what tells the two shapes of
    /// file apart, and the distinction matters: on a music file the title and
    /// artist frames are the answer and should be left alone, while on one of
    /// these the title is a *video* title (`Artist – Title, conducted by …`,
    /// `日本語 / English`, `… 【歌ってみた】`) and the artist is whatever the
    /// uploading channel is called. Only the second kind gets tidied up.
    private static func isVideoSourceURL(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered.contains("youtube.com/") || lowered.contains("youtu.be/")
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
