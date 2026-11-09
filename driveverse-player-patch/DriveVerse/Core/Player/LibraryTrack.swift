import Foundation

/// One playable file in the library. Identified by its path relative to the
/// app's Documents folder, so the id survives rescans and app updates.
struct LibraryTrack: Codable, Equatable, Hashable, Identifiable {
    static let unknownArtist = "Unknown Artist"
    static let unknownAlbum = "Unknown Album"

    var path: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var trackNumber: Int
    var discNumber: Int
    var durationMs: Int
    var year: Int
    var fileSize: Int64
    var modified: Date
    var addedAt: Date

    var id: String { path }

    init(
        path: String,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        trackNumber: Int = 0,
        discNumber: Int = 0,
        durationMs: Int = 0,
        year: Int = 0,
        fileSize: Int64 = 0,
        modified: Date = .distantPast,
        addedAt: Date = Date()
    ) {
        self.path = path
        let stem = Self.stem(of: path)
        self.title = Self.clean(title) ?? stem
        self.artist = Self.clean(artist) ?? Self.unknownArtist
        self.album = Self.clean(album) ?? Self.unknownAlbum
        self.albumArtist = Self.clean(albumArtist) ?? Self.clean(artist) ?? Self.unknownArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.durationMs = durationMs
        self.year = year
        self.fileSize = fileSize
        self.modified = modified
        self.addedAt = addedAt
    }

    /// File name without folders or extension.
    var fileStem: String { Self.stem(of: path) }

    /// Folder part of the path, "" for files at the top level.
    var folder: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    var hasKnownArtist: Bool { artist != Self.unknownArtist }
    var hasKnownAlbum: Bool { album != Self.unknownAlbum }

    static func stem(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return TextKey.deletingExtension(name)
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
