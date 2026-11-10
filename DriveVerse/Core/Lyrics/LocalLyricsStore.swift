import Foundation

/// Hand-made lyrics: reads `.lrc` files from the app's Documents folder.
/// The folder is visible in the Files app and in Apple Devices (File Sharing),
/// so lyrics can sit next to the songs they belong to, or in a "Lyrics" folder.
///
/// Matching, best first:
///   1. a file named exactly like the song's audio file (`Song.m4a` -> `Song.lrc`)
///   2. a file named like the title tag (`イガク.lrc`)
///   3. `Artist - Title.lrc` in either order
///   4. a file whose name starts or ends with the title
/// When several files tie, one in the same folder as the audio file wins, then
/// the shortest name.
///
/// Stacked lines at one timestamp become original + translation (the stock
/// `LRCParser` already does this), so a file with a romaji line and an English
/// line per timestamp shows romaji with English underneath.
enum LocalLyricsStore {
    static let folderName = "Lyrics"
    /// UserDefaults switch: also search online for songs played in-app.
    static let onlineFallbackKey = "lyricsOnlineFallbackForLocalSongs"

    static var rootFolder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Creates the folder (plus a short note) so it is visible in Files.
    static func prepareFolder() {
        guard let root = rootFolder else { return }
        let fm = FileManager.default
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = folder.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: note.path) {
            let text = "Put .lrc files here, or next to your songs. Name each file after "
                + "the song, for example: Song Title.lrc\n"
            try? text.write(to: note, atomically: true, encoding: .utf8)
        }
    }

    /// Returns synced lyrics from a matching local file, or nil if none match.
    /// `audioFolder` is the song's folder relative to the root ("" if none).
    static func lyrics(
        title: String,
        artist: String,
        fileStem: String? = nil,
        audioFolder: String = "",
        in folder: URL? = nil
    ) -> LyricsContent? {
        guard let root = folder ?? rootFolder,
              let url = bestMatch(
                  title: title, artist: artist, fileStem: fileStem,
                  audioFolder: audioFolder, in: root
              ),
              let raw = readText(url)
        else { return nil }
        let lines = LRCParser.parse(raw)
        guard !lines.isEmpty else { return nil }
        return .document(LyricsDocument(source: .local, timing: .synced, lines: lines))
    }

    // MARK: - Matching

    static func normalize(_ text: String) -> String { TextKey.normalize(text) }

    static func bestMatch(
        title: String,
        artist: String,
        fileStem: String? = nil,
        audioFolder: String = "",
        in root: URL
    ) -> URL? {
        let wantedTitle = normalize(title)
        let wantedFile = fileStem.map(normalize) ?? ""
        guard !wantedTitle.isEmpty || !wantedFile.isEmpty else { return nil }
        let who = normalize(artist)
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return nil }

        var best: (score: Int, sameFolder: Bool, length: Int, url: URL)?
        while let relative = walker.nextObject() as? String {
            let parts = relative.split(separator: "/").map(String.init)
            guard let name = parts.last else { continue }
            if parts.contains(where: { $0.hasPrefix(".") }) {
                walker.skipDescendants()
                continue
            }
            guard TextKey.fileExtension(name) == "lrc" else { continue }
            let stem = normalize(TextKey.deletingExtension(name))
            guard !stem.isEmpty else { continue }

            var score = 0
            if !wantedFile.isEmpty, stem == wantedFile {
                score = 5
            } else if !wantedTitle.isEmpty, stem == wantedTitle {
                score = 4
            } else if !wantedTitle.isEmpty, !who.isEmpty,
                      stem == who + wantedTitle || stem == wantedTitle + who {
                score = 3
            } else if !wantedTitle.isEmpty, wantedTitle.count >= 2,
                      stem.hasPrefix(wantedTitle) || stem.hasSuffix(wantedTitle) {
                score = 1
            }
            guard score > 0 else { continue }

            let relativeParent = parts.dropLast().joined(separator: "/")
            let candidate = (score, relativeParent == audioFolder, stem.count,
                             root.appendingPathComponent(relative))
            if let current = best, !isBetter(candidate, than: current) { continue }
            best = candidate
        }
        return best?.url
    }

    private static func isBetter(
        _ a: (score: Int, sameFolder: Bool, length: Int, url: URL),
        than b: (score: Int, sameFolder: Bool, length: Int, url: URL)
    ) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.sameFolder != b.sameFolder { return a.sameFolder }
        if a.length != b.length { return a.length < b.length }
        return a.url.path < b.url.path
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
        if text?.hasPrefix("\u{FEFF}") == true { text?.removeFirst() }
        return text
    }
}
