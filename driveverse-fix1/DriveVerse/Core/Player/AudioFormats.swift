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
    static func scan(root: URL, skippingTopLevel skipped: Set<String> = []) -> ScanResult {
        let fm = FileManager.default
        let base = root.resolvingSymlinksInPath()
        let basePath = TextKey.canonicalPath(base)
        guard let walker = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ScanResult() }

        var result = ScanResult()
        for case let url as URL in walker {
            let full = TextKey.canonicalPath(url)
            guard full.hasPrefix(basePath + "/") else { continue }
            let relative = String(full.dropFirst(basePath.count + 1))
            if let top = relative.split(separator: "/").first, skipped.contains(String(top)) {
                walker.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            ]), values.isRegularFile == true else { continue }
            let file = ScannedFile(
                path: relative,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            )
            let ext = url.pathExtension
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
