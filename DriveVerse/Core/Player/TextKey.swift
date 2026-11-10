import Foundation

/// Shared text normalisation for searching and file-name matching.
enum TextKey {
    /// Width-folded, lowercased, letters and digits only. Keeps kana and kanji.
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        var out = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            out.append(scalar)
        }
        return String(out)
    }

    /// Splits a search query into normalised words; blank queries give [].
    static func queryWords(_ query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// "name.ext" -> "name". Dot-files and extension-less names are unchanged.
    static func deletingExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// Case- and width-insensitive "is `a` before `b`" for lists shown to people.
    static func sortsBefore(_ a: String, _ b: String) -> Bool {
        let order = a.localizedStandardCompare(b)
        if order != .orderedSame { return order == .orderedAscending }
        return a < b
    }

    /// One spelling for a path. macOS can report the same folder as /var/x or
    /// /private/var/x; normalising both sides keeps "relative path" maths exact.
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Lowercased extension without the dot ("Song.M4A" -> "m4a"), "" if none.
    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}
