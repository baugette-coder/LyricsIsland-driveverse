import Foundation

/// Where the library lives. Everything the user drops into the app's
/// Documents folder (Files app, Apple Devices File Sharing) is the library.
enum LibraryPaths {
    /// The library root: the app's Documents folder.
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// App-private bookkeeping (not shown in Files, not scanned).
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DriveVersePlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var libraryFile: URL { supportDirectory.appendingPathComponent("library.json") }
    static var playlistsFile: URL { supportDirectory.appendingPathComponent("playlists.json") }
    static var sessionFile: URL { supportDirectory.appendingPathComponent("session.json") }

    /// Folders in Documents that are not music.
    static let skippedTopLevel: Set<String> = ["Inbox"]

    static func url(forTrackPath path: String) -> URL {
        root.appendingPathComponent(path)
    }
}

/// Small JSON helpers shared by the stores.
enum JSONStore {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// What gets saved so the app can resume where it left off.
struct PlayerSession: Codable, Equatable {
    var queue: PlayQueue
    var positionSec: Double
    var rate: Float
}
