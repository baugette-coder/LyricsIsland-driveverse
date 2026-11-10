import Foundation

struct Playlist: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var trackIDs: [String]
    var createdAt: Date
    var modifiedAt: Date

    init(id: UUID = UUID(), name: String, trackIDs: [String] = [], now: Date = Date()) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.createdAt = now
        self.modifiedAt = now
    }
}

/// All user playlists plus favourites. Pure value type; the app wraps it in
/// an observable object and saves it as JSON.
struct PlaylistCollection: Codable, Equatable {
    private(set) var playlists: [Playlist] = []
    private(set) var favoriteIDs: [String] = []

    init() {}

    // MARK: Playlists

    @discardableResult
    mutating func create(name: String, trackIDs: [String] = [], now: Date = Date()) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(
            name: trimmed.isEmpty ? uniqueName("New Playlist") : trimmed,
            trackIDs: Self.deduplicated(trackIDs),
            now: now
        )
        playlists.append(playlist)
        return playlist
    }

    mutating func rename(_ id: UUID, to name: String, now: Date = Date()) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = index(of: id) else { return }
        playlists[i].name = trimmed
        playlists[i].modifiedAt = now
    }

    mutating func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
    }

    /// Adds tracks to the end, skipping any already in the playlist.
    /// Returns how many were actually added.
    @discardableResult
    mutating func add(_ trackIDs: [String], to id: UUID, now: Date = Date()) -> Int {
        guard let i = index(of: id) else { return 0 }
        var existing = Set(playlists[i].trackIDs)
        var added = 0
        for trackID in trackIDs where existing.insert(trackID).inserted {
            playlists[i].trackIDs.append(trackID)
            added += 1
        }
        if added > 0 { playlists[i].modifiedAt = now }
        return added
    }

    mutating func remove(trackAt offsets: [Int], from id: UUID, now: Date = Date()) {
        guard let i = index(of: id) else { return }
        for offset in offsets.sorted(by: >) where playlists[i].trackIDs.indices.contains(offset) {
            playlists[i].trackIDs.remove(at: offset)
        }
        playlists[i].modifiedAt = now
    }

    /// `destination` follows SwiftUI `onMove` semantics.
    mutating func move(from source: Int, to destination: Int, in id: UUID, now: Date = Date()) {
        guard let i = index(of: id),
              playlists[i].trackIDs.indices.contains(source),
              destination >= 0, destination <= playlists[i].trackIDs.count else { return }
        let item = playlists[i].trackIDs.remove(at: source)
        let target = destination > source ? destination - 1 : destination
        playlists[i].trackIDs.insert(item, at: min(target, playlists[i].trackIDs.count))
        playlists[i].modifiedAt = now
    }

    func playlist(_ id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    /// A name not used by another playlist: "Road Trip", "Road Trip 2", ...
    func uniqueName(_ base: String) -> String {
        let taken = Set(playlists.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Favourites

    func isFavorite(_ trackID: String) -> Bool { favoriteIDs.contains(trackID) }

    mutating func setFavorite(_ trackID: String, _ on: Bool) {
        if on {
            if !favoriteIDs.contains(trackID) { favoriteIDs.append(trackID) }
        } else {
            favoriteIDs.removeAll { $0 == trackID }
        }
    }

    // MARK: Library changes

    /// Drops ids of tracks that no longer exist, and follows renamed files
    /// when a mapping old path -> new path is known.
    mutating func reconcile(existing: Set<String>, renamed: [String: String] = [:]) {
        func fix(_ ids: [String]) -> [String] {
            Self.deduplicated(ids.compactMap { id -> String? in
                if existing.contains(id) { return id }
                if let moved = renamed[id], existing.contains(moved) { return moved }
                return nil
            })
        }
        for i in playlists.indices { playlists[i].trackIDs = fix(playlists[i].trackIDs) }
        favoriteIDs = fix(favoriteIDs)
    }

    // MARK: Helpers

    private func index(of id: UUID) -> Int? { playlists.firstIndex { $0.id == id } }

    static func deduplicated(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - M3U / M3U8 import

/// Reads playlists exported by desktop players. Entries are matched to library
/// tracks by relative path first, then by file name, so a playlist written on
/// the PC still works after the songs are copied into the app.
enum M3UParser {
    /// Track locations in file order; comments and `#EXTINF` lines are skipped.
    static func entries(from text: String) -> [String] {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        return body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Maps playlist entries to library track ids. Unmatched entries are
    /// returned separately so the UI can say how many were skipped.
    static func match(
        entries: [String],
        trackPaths: [String]
    ) -> (matched: [String], missing: [String]) {
        var byFullPath: [String: String] = [:]
        var byName: [String: [String]] = [:]
        for path in trackPaths {
            byFullPath[path.lowercased()] = path
            let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
            byName[name, default: []].append(path)
        }
        var matched: [String] = []
        var missing: [String] = []
        for raw in entries {
            let normalized = raw.replacingOccurrences(of: "\\", with: "/")
            let cleaned = normalized.hasPrefix("file://") ? String(normalized.dropFirst(7)) : normalized
            let lower = cleaned.lowercased()
            if let exact = byFullPath[lower] {
                matched.append(exact)
                continue
            }
            // Longest path suffix that matches a library path wins.
            let parts = lower.split(separator: "/").map(String.init)
            var found: String?
            for start in 0..<parts.count {
                let candidate = parts[start...].joined(separator: "/")
                if let hit = byFullPath[candidate] { found = hit; break }
            }
            if found == nil, let name = parts.last, let options = byName[name], options.count == 1 {
                found = options[0]
            }
            if let found { matched.append(found) } else { missing.append(raw) }
        }
        return (matched, missing)
    }
}
