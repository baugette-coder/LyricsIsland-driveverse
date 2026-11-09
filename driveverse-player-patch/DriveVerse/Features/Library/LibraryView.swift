#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerController
    let openPlayer: () -> Void

    enum Browse: String, CaseIterable, Identifiable {
        case songs = "Songs", albums = "Albums", artists = "Artists"
        case playlists = "Playlists", folders = "Folders"
        var id: String { rawValue }
    }
    enum ImportMode { case songs, folder }

    @State private var section: Browse = .songs
    @State private var query = ""
    @State private var showsImporter = false
    @State private var importMode: ImportMode = .songs
    @State private var showsQueue = false

    private var importTypes: [UTType] {
        switch importMode {
        case .folder:
            return [.folder]
        case .songs:
            let extra = ["lrc", "m3u", "m3u8", "flac", "m4a"].compactMap { UTType(filenameExtension: $0) }
            return [.audio] + extra
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if case .scanning(let done, let total) = library.activity {
                    ActivityBanner(
                        text: total > 0 ? "Reading song info… \(done)/\(total)" : "Looking for new songs…",
                        progress: total > 0 ? Double(done) / Double(total) : nil,
                        cancel: nil
                    )
                }
                if case .importing(let done, let total) = library.activity {
                    ActivityBanner(
                        text: total > 0 ? "Importing… \(done)/\(total)" : "Preparing import…",
                        progress: total > 0 ? Double(done) / Double(total) : nil,
                        cancel: { library.cancelImport() }
                    )
                }
                if trimmedQuery.isEmpty {
                    Picker("Browse", selection: $section) {
                        ForEach(Browse.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    content
                } else {
                    SearchResults(query: trimmedQuery)
                }
            }
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Songs, artists, albums")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { MiniPlayer(open: openPlayer) }
            .fileImporter(
                isPresented: $showsImporter,
                allowedContentTypes: importTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    Task { await library.importFiles(from: urls) }
                }
            }
            .sheet(isPresented: $showsQueue) { QueueView() }
            .alert(
                library.report?.title ?? "",
                isPresented: Binding(
                    get: { library.report != nil },
                    set: { if !$0 { library.report = nil } }
                ),
                presenting: library.report
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { report in
                Text(report.lines.joined(separator: "\n"))
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder private var content: some View {
        if library.index.tracks.isEmpty && !library.isBusy {
            EmptyLibraryView(importSongs: { startImport(.songs) }, importFolder: { startImport(.folder) })
        } else {
            switch section {
            case .songs: SongsList()
            case .albums: AlbumsList()
            case .artists: ArtistsList()
            case .playlists: PlaylistsList()
            case .folders: FolderBrowser(path: "")
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                player.shuffleAll()
            } label: {
                Label("Shuffle All", systemImage: "shuffle")
            }
            .disabled(library.index.tracks.isEmpty)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showsQueue = true } label: { Label("Queue", systemImage: "list.bullet") }
            Menu {
                Button { startImport(.songs) } label: { Label("Import Songs…", systemImage: "square.and.arrow.down") }
                Button { startImport(.folder) } label: { Label("Import Folder…", systemImage: "folder.badge.plus") }
                Button { Task { await library.rescan() } } label: { Label("Rescan Library", systemImage: "arrow.clockwise") }
                    .disabled(library.isBusy)
                Divider()
                SleepTimerMenu()
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func startImport(_ mode: ImportMode) {
        importMode = mode
        showsImporter = true
    }
}

// MARK: - Pieces

struct ActivityBanner: View {
    let text: String
    let progress: Double?
    let cancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(text).font(.footnote)
                Spacer()
                if let cancel { Button("Cancel", action: cancel).font(.footnote) }
            }
            if let progress {
                ProgressView(value: progress)
            } else {
                ProgressView()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}

struct EmptyLibraryView: View {
    let importSongs: () -> Void
    let importFolder: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "music.note.house")
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary)
                Text("No songs yet").font(.title2.bold())
                Text("Add your songs and they play offline, with lyrics.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Button(action: importFolder) {
                        Label("Import a Folder", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(action: importSongs) {
                        Label("Import Songs", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Adding many songs from a PC").font(.headline)
                    Text("Install Apple Devices on Windows, plug in the iPhone, open File Sharing, choose DriveVerse, and drag your music folders in. Then pull down on Songs or choose Rescan Library. Put each song’s .lrc lyrics file next to it with the same name.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
    }
}

struct SearchResults: View {
    @EnvironmentObject private var library: LibraryModel
    let query: String

    var body: some View {
        let found = library.index.search(query)
        if found.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            TrackList(tracks: found, showsNumbers: false)
        }
    }
}

/// Everything, sorted by title, with a footer counting lyrics coverage.
struct SongsList: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        let tracks = library.index.tracks
        TrackList(tracks: tracks, showsNumbers: false, footer: footerText(tracks))
            .refreshable { await library.rescan() }
    }

    private func footerText(_ tracks: [LibraryTrack]) -> String {
        let withLyrics = tracks.filter { library.hasLyrics($0) }.count
        return "\(tracks.count) songs · \(withLyrics) with lyrics files"
    }
}

struct AlbumsList: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        List(library.index.albums) { album in
            NavigationLink {
                AlbumDetail(albumID: album.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).lineLimit(1)
                    Text("\(album.artist) · \(album.trackIDs.count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await library.rescan() }
    }
}

struct AlbumDetail: View {
    @EnvironmentObject private var library: LibraryModel
    let albumID: String

    var body: some View {
        if let album = library.index.album(albumID) {
            TrackList(
                tracks: library.index.tracks(for: album.trackIDs),
                showsNumbers: true,
                header: AnyView(PlayShuffleHeader(trackIDs: album.trackIDs))
            )
            .navigationTitle(album.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Album not found", systemImage: "music.note")
        }
    }
}

struct ArtistsList: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        List(library.index.artists) { artist in
            NavigationLink {
                ArtistDetail(artistID: artist.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name).lineLimit(1)
                    Text("\(artist.trackIDs.count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await library.rescan() }
    }
}

struct ArtistDetail: View {
    @EnvironmentObject private var library: LibraryModel
    let artistID: String

    var body: some View {
        if let artist = library.index.artist(artistID) {
            TrackList(
                tracks: library.index.tracks(for: artist.trackIDs),
                showsNumbers: false,
                header: AnyView(PlayShuffleHeader(trackIDs: artist.trackIDs))
            )
            .navigationTitle(artist.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Artist not found", systemImage: "person")
        }
    }
}

/// Folders, exactly as they are on disk. Handy when the library is organised
/// by the folders the songs were copied in.
struct FolderBrowser: View {
    @EnvironmentObject private var library: LibraryModel
    let path: String

    var body: some View {
        let listing = library.index.folderListing(at: path)
        List {
            if !listing.tracks.isEmpty || !listing.folders.isEmpty {
                PlayShuffleHeader(trackIDs: library.index.tracks(inFolder: path).map(\.id))
            }
            ForEach(listing.folders, id: \.self) { name in
                NavigationLink {
                    FolderBrowser(path: path.isEmpty ? name : path + "/" + name)
                } label: {
                    Label(name, systemImage: "folder")
                }
            }
            TrackRows(tracks: listing.tracks, showsNumbers: false)
        }
        .listStyle(.plain)
        .navigationTitle(path.isEmpty ? "" : (path.split(separator: "/").last.map(String.init) ?? path))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlayShuffleHeader: View {
    @EnvironmentObject private var player: PlayerController
    let trackIDs: [String]

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.play(trackIDs: trackIDs, startAt: 0, shuffle: false)
            } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                player.play(trackIDs: trackIDs, startAt: 0, shuffle: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .disabled(trackIDs.isEmpty)
        .listRowSeparator(.hidden)
    }
}
#endif
