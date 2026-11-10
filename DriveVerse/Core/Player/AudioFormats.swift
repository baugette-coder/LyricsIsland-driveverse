import Foundation

/// Which files the library understands.
enum AudioFormats {
    /// Containers AVFoundation can play on iOS.
    static let playable: Set<String> = [
        "m4a", "m4b", "mp3", "aac", "wav", "aif", "aiff", "caf", "flac",
    ]
    /// Common audio containers iOS cannot play. Reported to the user instead
    /// of being silently ignored.
    static let unsupported: Set<String> = [
        "ogg", "oga", "opus", "wma", "ape", "wv", "mka", "dsf", "dff", "mpc",
    ]
    static let lyrics: Set<String> = ["lrc"]
    static let playlists: Set<String> = ["m3u", "m3u8"]

    static func isPlayable(_ ext: String) -> Bool { playable.contains(ext.lowercased()) }
    static func isUnsupported(_ ext: String) -> Bool { unsupported.contains(ext.lowercased()) }
    static func isLyrics(_ ext: String) -> Bool { lyrics.contains(ext.lowercased()) }
    static func isPlaylist(_ ext: String) -> Bool { playlists.contains(ext.lowercased()) }
}

struct ScannedFile: Equatable, Hashable {
    /// Path relative to the scanned root, using "/" separators.
    let path: String
    let size: Int64
    let modified: Date
}

struct ScanResult: Equatable {
    var audio: [ScannedFile] = []
    var lyrics: [ScannedFile] = []
    var playlists: [ScannedFile] = []
    /// Relative paths of audio files iOS cannot play.
    var unsupported: [String] = []
}

enum MediaFileScanner {
    /// Walks `root` recursively. Hidden files and the app's own bookkeeping
    /// folders are skipped. Cheap: reads file attributes only, never contents.
    /// Works with relative paths handed out by FileManager, so it does not
    /// matter how the system spells the root (/var vs /private/var).
    static func scan(root: URL, skippingTopLevel skipped: Set<String> = []) -> ScanResult {
        let fm = FileManager.default
        let rootPath = root.path
        guard let walker = fm.enumerator(atPath: rootPath) else { return ScanResult() }

        var result = ScanResult()
        while let relative = walker.nextObject() as? String {
            let parts = relative.split(separator: "/").map(String.init)
            guard let name = parts.last else { continue }
            if parts.contains(where: { $0.hasPrefix(".") })
                || (parts.first.map { skipped.contains($0) } ?? false) {
                walker.skipDescendants()
                continue
            }
            guard let attributes = try? fm.attributesOfItem(atPath: rootPath + "/" + relative),
                  (attributes[.type] as? FileAttributeType) == .typeRegular else { continue }
            let file = ScannedFile(
                path: relative,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modified: (attributes[.modificationDate] as? Date) ?? .distantPast
            )
            let ext = TextKey.fileExtension(name)
            if AudioFormats.isPlayable(ext) {
                result.audio.append(file)
            } else if AudioFormats.isLyrics(ext) {
                result.lyrics.append(file)
            } else if AudioFormats.isPlaylist(ext) {
                result.playlists.append(file)
            } else if AudioFormats.isUnsupported(ext) {
                result.unsupported.append(relative)
            }
        }
        result.audio.sort { $0.path < $1.path }
        result.lyrics.sort { $0.path < $1.path }
        result.playlists.sort { $0.path < $1.path }
        result.unsupported.sort()
        return result
    }
}
