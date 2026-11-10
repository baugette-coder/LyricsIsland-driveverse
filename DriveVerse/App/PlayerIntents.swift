#if os(iOS)
import AppIntents

// Voice and Shortcuts control for the built-in player. Apps that are not
// approved for CarPlay's browse screens cannot show a song list on the car
// display, so choosing music by voice ("Hey Siri, shuffle my music in
// DriveVerse") is how you pick songs without touching the phone.

// MARK: Entities

struct SongEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song")
    static let defaultQuery = SongQuery()

    let id: String
    let title: String
    let artist: String

    init(track: LibraryTrack) {
        id = track.id
        title = track.title
        artist = track.hasKnownArtist ? track.artist : ""
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: title),
            subtitle: artist.isEmpty ? nil : LocalizedStringResource(stringLiteral: artist)
        )
    }
}

struct SongQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SongEntity] {
        await MainActor.run { () -> [SongEntity] in
            LibraryModel.shared.start()
            let index = LibraryModel.shared.index
            return identifiers.compactMap { index.track($0) }.map { SongEntity(track: $0) }
        }
    }

    func entities(matching string: String) async throws -> [SongEntity] {
        await MainActor.run { () -> [SongEntity] in
            LibraryModel.shared.start()
            return LibraryModel.shared.index.search(string).prefix(30).map { SongEntity(track: $0) }
        }
    }

    func suggestedEntities() async throws -> [SongEntity] {
        await MainActor.run { () -> [SongEntity] in
            LibraryModel.shared.start()
            return LibraryModel.shared.index.tracks.prefix(30).map { SongEntity(track: $0) }
        }
    }
}

struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static let defaultQuery = PlaylistQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

struct PlaylistQuery: EntityStringQuery {
    private func all() async -> [PlaylistEntity] {
        await MainActor.run { () -> [PlaylistEntity] in
            LibraryModel.shared.start()
            return LibraryModel.shared.playlists.playlists.map {
                PlaylistEntity(id: $0.id.uuidString, name: $0.name)
            }
        }
    }

    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let words = TextKey.queryWords(string)
        return await all().filter { entity in
            let key = TextKey.normalize(entity.name)
            return words.allSatisfy { key.contains($0) }
        }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] { await all() }
}

struct AlbumEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Album")
    static let defaultQuery = AlbumQuery()

    let id: String
    let title: String
    let artist: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: title),
            subtitle: LocalizedStringResource(stringLiteral: artist)
        )
    }
}

struct AlbumQuery: EntityStringQuery {
    private func all() async -> [AlbumEntity] {
        await MainActor.run { () -> [AlbumEntity] in
            LibraryModel.shared.start()
            return LibraryModel.shared.index.albums.map {
                AlbumEntity(id: $0.id, title: $0.title, artist: $0.artist)
            }
        }
    }

    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [AlbumEntity] {
        let words = TextKey.queryWords(string)
        return await all().filter { entity in
            let key = TextKey.normalize(entity.title + entity.artist)
            return words.allSatisfy { key.contains($0) }
        }.prefix(30).map { $0 }
    }

    func suggestedEntities() async throws -> [AlbumEntity] {
        let items = await all()
        return Array(items.prefix(30))
    }
}

struct ArtistEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Artist")
    static let defaultQuery = ArtistQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

struct ArtistQuery: EntityStringQuery {
    private func all() async -> [ArtistEntity] {
        await MainActor.run { () -> [ArtistEntity] in
            LibraryModel.shared.start()
            return LibraryModel.shared.index.artists.map { ArtistEntity(id: $0.id, name: $0.name) }
        }
    }

    func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ArtistEntity] {
        let words = TextKey.queryWords(string)
        return await all().filter { entity in
            let key = TextKey.normalize(entity.name)
            return words.allSatisfy { key.contains($0) }
        }.prefix(30).map { $0 }
    }

    func suggestedEntities() async throws -> [ArtistEntity] {
        let items = await all()
        return Array(items.prefix(30))
    }
}

// MARK: Intents

@MainActor
private func prepareLibraryAndPlayer() {
    LibraryModel.shared.start()
    PlayerController.shared.start()
}

struct ShuffleAllIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle My Music"
    static let description = IntentDescription("Shuffles every song in your DriveVerse library.")

    @MainActor func perform() async throws -> some IntentResult {
        prepareLibraryAndPlayer()
        PlayerController.shared.shuffleAll()
        return .result()
    }
}

struct PlayFavoritesIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play My Favorites"
    static let description = IntentDescription("Plays the songs you marked as favorites.")

    @MainActor func perform() async throws -> some IntentResult {
        prepareLibraryAndPlayer()
        let ids = LibraryModel.shared.index
            .tracks(for: LibraryModel.shared.playlists.favoriteIDs).map(\.id)
        PlayerController.shared.play(trackIDs: ids, startAt: 0, shuffle: true)
        return .result()
    }
}

struct PlaySongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song"
    static let description = IntentDescription("Plays one song from your library.")

    @Parameter(title: "Song") var song: SongEntity

    @MainActor func perform() async throws -> some IntentResult {
        prepareLibraryAndPlayer()
        PlayerController.shared.play(trackIDs: [song.id], startAt: 0, shuffle: false)
        return .result()
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays a playlist from your library.")

    @Parameter(title: "Playlist") var playlist: PlaylistEntity

    @MainActor func perform() async throws -> some IntentResult {
        prepareLibraryAndPlayer()
        let library = LibraryModel.shared
        guard let uuid = UUID(uuidString: playlist.id),
              let found = library.playlists.playlist(uuid) else { return .result() }
        let ids = library.index.tracks(for: found.trackIDs).map(\.id)
        PlayerController.shared.play(trackIDs: ids, startAt: 0)
        return .result()
    }
}

struct PlayAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let description = IntentDescription("Plays an album from your library.")

    @Parameter(title: "Album") var album: AlbumEntity

    @MainActor func perform() async throws -> some IntentResult {
        prepareLibraryAndPlayer()
        if let group = LibraryModel.shared.index.album(album.id) {
            PlayerController.shared.play(trackIDs: group.trackIDs, startAt: 0)
        }
        return .result()
    }
}

struct PlayArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Artist"
    static let description = IntentDescription("Plays everything by one artist.")

    @Parameter(title: "Artist") var artist: ArtistEntity

    @MainActor func perform() async throws -> some IntentResult {
        prepareLibraryAndPlayer()
        if let group = LibraryModel.shared.index.artist(artist.id) {
            PlayerController.shared.play(trackIDs: group.trackIDs, startAt: 0)
        }
        return .result()
    }
}
#endif
