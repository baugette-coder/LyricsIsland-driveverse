import Foundation

struct AlbumGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let year: Int
    /// Ordered by disc, track number, then title.
    let trackIDs: [String]
}

struct ArtistGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let albumIDs: [String]
    let trackIDs: [String]
}

struct FolderListing: Equatable {
    /// Leaf names of sub-folders, sorted.
    var folders: [String]
    var tracks: [LibraryTrack]
}

/// Read-only browse structure built from a flat track list. Cheap enough to
/// rebuild after every scan (thousands of tracks).
struct LibraryIndex {
    let tracks: [LibraryTrack]
    let albums: [AlbumGroup]
    let artists: [ArtistGroup]

    private let byID: [String: LibraryTrack]
    private let searchKeys: [String: String]
    private let albumsByID: [String: AlbumGroup]

    /// `romanize` lets the app add an offline romaji reading of titles so a
    /// Japanese song can be found by typing its romaji.
    init(tracks input: [LibraryTrack], romanize: (String) -> String = { _ in "" }) {
        let sorted = input.sorted {
            if $0.title != $1.title { return TextKey.sortsBefore($0.title, $1.title) }
            return $0.path < $1.path
        }
        tracks = sorted
        var map: [String: LibraryTrack] = [:]
        var keys: [String: String] = [:]
        for track in sorted {
            map[track.id] = track
            let reading = romanize(track.title)
            keys[track.id] = TextKey.normalize(
                [track.title, reading, track.artist, track.album, track.fileStem].joined(separator: " ")
            )
        }
        byID = map
        searchKeys = keys

        // Albums: grouped by album artist + album title.
        var albumBuckets: [String: [LibraryTrack]] = [:]
        for track in sorted {
            let key = TextKey.normalize(track.albumArtist) + "|" + TextKey.normalize(track.album)
            albumBuckets[key, default: []].append(track)
        }
        var builtAlbums: [AlbumGroup] = []
        for (key, members) in albumBuckets {
            let ordered = members.sorted(by: Self.albumOrder)
            builtAlbums.append(AlbumGroup(
                id: key,
                title: ordered[0].album,
                artist: ordered[0].albumArtist,
                year: ordered.map(\.year).filter { $0 > 0 }.min() ?? 0,
                trackIDs: ordered.map(\.id)
            ))
        }
        builtAlbums.sort {
            if $0.title != $1.title { return TextKey.sortsBefore($0.title, $1.title) }
            return $0.id < $1.id
        }
        albums = builtAlbums
        let albumLookup = Dictionary(uniqueKeysWithValues: builtAlbums.map { ($0.id, $0) })
        albumsByID = albumLookup

        // Artists: by track artist, so features and compilations stay findable.
        var artistBuckets: [String: (name: String, tracks: [LibraryTrack])] = [:]
        for track in sorted {
            let key = TextKey.normalize(track.artist)
            artistBuckets[key, default: (track.artist, [])].tracks.append(track)
        }
        var builtArtists: [ArtistGroup] = []
        for (key, bucket) in artistBuckets {
            let albumIDs = Set(bucket.tracks.map {
                TextKey.normalize($0.albumArtist) + "|" + TextKey.normalize($0.album)
            })
            let orderedAlbums = albumIDs.compactMap { albumLookup[$0] }
                .sorted { TextKey.sortsBefore($0.title, $1.title) }
                .map(\.id)
            builtArtists.append(ArtistGroup(
                id: key,
                name: bucket.name,
                albumIDs: orderedAlbums,
                trackIDs: bucket.tracks.sorted(by: Self.albumOrder).map(\.id)
            ))
        }
        builtArtists.sort {
            if $0.name != $1.name { return TextKey.sortsBefore($0.name, $1.name) }
            return $0.id < $1.id
        }
        artists = builtArtists
    }

    private static func albumOrder(_ a: LibraryTrack, _ b: LibraryTrack) -> Bool {
        if a.discNumber != b.discNumber { return a.discNumber < b.discNumber }
        if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
        if a.title != b.title { return TextKey.sortsBefore(a.title, b.title) }
        return a.path < b.path
    }

    func track(_ id: String) -> LibraryTrack? { byID[id] }
    func album(_ id: String) -> AlbumGroup? { albumsByID[id] }
    func artist(_ id: String) -> ArtistGroup? { artists.first { $0.id == id } }

    /// Resolves ids to tracks, silently dropping ids that no longer exist.
    func tracks(for ids: [String]) -> [LibraryTrack] { ids.compactMap { byID[$0] } }

    /// Every word must appear somewhere in title, romaji reading, artist,
    /// album or file name. Blank queries match nothing.
    func search(_ query: String) -> [LibraryTrack] {
        let words = TextKey.queryWords(query)
        guard !words.isEmpty else { return [] }
        return tracks.filter { track in
            guard let key = searchKeys[track.id] else { return false }
            return words.allSatisfy { key.contains($0) }
        }
    }

    /// Direct contents of a folder ("" is the top level).
    func folderListing(at folder: String) -> FolderListing {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var subfolders = Set<String>()
        var here: [LibraryTrack] = []
        for track in tracks where track.path.hasPrefix(prefix) {
            let rest = track.path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                subfolders.insert(String(rest[..<slash]))
            } else {
                here.append(track)
            }
        }
        return FolderListing(
            folders: subfolders.sorted(by: TextKey.sortsBefore),
            tracks: here.sorted { TextKey.sortsBefore($0.fileStem, $1.fileStem) }
        )
    }

    /// All tracks at or below a folder, in path order.
    func tracks(inFolder folder: String) -> [LibraryTrack] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        return tracks.filter { $0.path.hasPrefix(prefix) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
