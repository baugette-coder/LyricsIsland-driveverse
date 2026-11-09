#if os(iOS)
import AVFoundation
import Foundation
import UIKit

struct TrackMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber = 0
    var discNumber = 0
    var year = 0
    var durationMs = 0
}

/// Reads tags from an audio file with AVFoundation. M4A (iTunes atoms) and
/// MP3 (ID3) are both handled; anything missing is left nil so the caller
/// can fall back to the file name.
enum TrackMetadataReader {
    static func read(url: URL) async -> TrackMetadata {
        let asset = AVURLAsset(url: url)
        var meta = TrackMetadata()

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { meta.durationMs = Int(seconds * 1000) }
        }

        let common = (try? await asset.load(.commonMetadata)) ?? []
        let specific = (try? await asset.load(.metadata)) ?? []
        let items = common + specific

        func text(_ identifier: AVMetadataIdentifier) async -> String? {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let value = try? await item.load(.stringValue) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }
        func data(_ identifier: AVMetadataIdentifier) async -> Data? {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let value = try? await item.load(.dataValue) { return value }
            }
            return nil
        }

        meta.title = await text(.commonIdentifierTitle)
        meta.artist = await text(.commonIdentifierArtist)
        meta.album = await text(.commonIdentifierAlbumName)
        if let value = await text(.iTunesMetadataAlbumArtist) {
            meta.albumArtist = value
        } else {
            meta.albumArtist = await text(.id3MetadataBand)
        }

        // Track / disc numbers: iTunes stores 8 bytes, number in bytes 2-3;
        // ID3 stores text like "3/12".
        if let bytes = await data(.iTunesMetadataTrackNumber) {
            meta.trackNumber = number(fromAtom: bytes)
        } else if let value = await text(.id3MetadataTrackNumber) {
            meta.trackNumber = leadingNumber(value)
        }
        if let bytes = await data(.iTunesMetadataDiscNumber) {
            meta.discNumber = number(fromAtom: bytes)
        } else if let value = await text(.id3MetadataPartOfASet) {
            meta.discNumber = leadingNumber(value)
        }

        var dateText = await text(.commonIdentifierCreationDate)
        if dateText == nil { dateText = await text(.iTunesMetadataReleaseDate) }
        if dateText == nil { dateText = await text(.id3MetadataYear) }
        if let dateText { meta.year = leadingNumber(String(dateText.prefix(4))) }
        return meta
    }

    /// Embedded cover art bytes, if the file has any.
    static func artworkData(url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let common = (try? await asset.load(.commonMetadata)) ?? []
        for item in AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierArtwork) {
            if let value = try? await item.load(.dataValue) { return value }
        }
        return nil
    }

    private static func number(fromAtom bytes: Data) -> Int {
        guard bytes.count >= 4 else { return 0 }
        let start = bytes.startIndex
        return Int(bytes[start + 2]) << 8 | Int(bytes[start + 3])
    }

    private static func leadingNumber(_ text: String) -> Int {
        let digits = text.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }
}

/// Image helpers: a sub-2 KB thumbnail for the Live Activity payload and a
/// larger copy for the app's own screens.
enum ArtworkTools {
    /// ActivityKit state must stay under 4 KB, so this squeezes a small JPEG
    /// under 1.6 KB the same way the Apple Music source does.
    static func compactThumbnail(from data: Data) -> Data? {
        guard let source = UIImage(data: data) else { return nil }
        for side: CGFloat in [48, 44, 40, 36, 32] {
            let size = CGSize(width: side, height: side)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                source.draw(in: CGRect(origin: .zero, size: size))
            }
            for quality: CGFloat in [0.6, 0.4, 0.25, 0.15] {
                if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= 1_600 {
                    return jpeg
                }
            }
        }
        return nil
    }

    static func displayImage(from data: Data, side: CGFloat = 640) -> UIImage? {
        guard let source = UIImage(data: data) else { return nil }
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func displayJPEG(from data: Data, side: CGFloat = 640) -> Data? {
        displayImage(from: data, side: side)?.jpegData(compressionQuality: 0.82)
    }
}
#endif
