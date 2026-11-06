import Foundation

/// Hand-made lyrics: reads `.lrc` files from the app's "Lyrics" folder, which
/// shows up in the Files app under On My iPhone > DriveVerse > Lyrics.
///
/// Files are matched to the playing track by name. A file called
/// `イガク.lrc` matches a track titled "イガク". `Artist - Title.lrc` works too.
/// Stacked lines at one timestamp become original + translation (the stock
/// `LRCParser` already does this), so a file with a romaji line and an English
/// line per timestamp shows romaji with English underneath.
enum LocalLyricsStore {
    static let folderName = "Lyrics"

    static var defaultFolder: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Creates the folder (plus a short note) so it is visible in Files.
    static func prepareFolder() {
        guard let folder = defaultFolder else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = folder.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: note.path) {
            let text = "Put .lrc files here. Name each file after the song title, "
                + "for example: Song Title.lrc\n"
            try? text.write(to: note, atomically: true, encoding: .utf8)
        }
    }

    /// Returns synced lyrics from a matching local file, or nil if none match.
    static func lyrics(
        title: String,
        artist: String,
        in folder: URL? = nil
    ) -> LyricsContent? {
        guard let folder = folder ?? defaultFolder,
              let url = bestMatch(title: title, artist: artist, in: folder),
              let raw = readText(url)
        else { return nil }
        let lines = LRCParser.parse(raw)
        guard !lines.isEmpty else { return nil }
        return .document(LyricsDocument(source: .local, timing: .synced, lines: lines))
    }

    // MARK: - Matching

    /// Lowercased, width-folded, letters and digits only. Keeps kana and kanji.
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        var out = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            out.append(scalar)
        }
        return String(out)
    }

    static func bestMatch(title: String, artist: String, in folder: URL) -> URL? {
        let wanted = normalize(title)
        guard !wanted.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: folder, includingPropertiesForKeys: nil
              )
        else { return nil }
        let who = normalize(artist)

        var best: (score: Int, length: Int, url: URL)?
        for url in files where url.pathExtension.lowercased() == "lrc" {
            let stem = normalize(url.deletingPathExtension().lastPathComponent)
            guard !stem.isEmpty else { continue }
            var score = 0
            if stem == wanted {
                score = 3
            } else if !who.isEmpty, stem == who + wanted || stem == wanted + who {
                score = 2
            } else if wanted.count >= 2, stem.hasPrefix(wanted) || stem.hasSuffix(wanted) {
                score = 1
            }
            guard score > 0 else { continue }
            if let current = best,
               current.score > score || (current.score == score && current.length <= stem.count) {
                continue
            }
            best = (score, stem.count, url)
        }
        return best?.url
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
        if text?.hasPrefix("\u{FEFF}") == true { text?.removeFirst() }
        return text
    }
}
