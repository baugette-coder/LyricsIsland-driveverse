#if os(iOS)
import SwiftUI

// MARK: - Queue

struct QueueView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let queue = player.queue
            List {
                if let current = queue.current {
                    Section("Now Playing") {
                        QueueRow(entry: current, isCurrent: true)
                    }
                }
                Section {
                    ForEach(queue.upNext) { entry in
                        Button { player.jump(to: entry.id) } label: { QueueRow(entry: entry, isCurrent: false) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let upNext = queue.upNext
                        for offset in offsets { player.removeFromQueue(upNext[offset].id) }
                    }
                    .onMove { source, destination in
                        guard let from = source.first, let base = queue.currentIndex else { return }
                        player.moveInQueue(from: base + 1 + from, to: base + 1 + destination)
                    }
                } header: {
                    HStack {
                        Text("Up Next")
                        if queue.isShuffled { Image(systemName: "shuffle").font(.caption) }
                        if queue.repeatMode != .off {
                            Image(systemName: queue.repeatMode == .one ? "repeat.1" : "repeat").font(.caption)
                        }
                    }
                } footer: {
                    if queue.upNext.isEmpty { Text("Nothing queued.") }
                }
                if !queue.history.isEmpty {
                    Section("Played") {
                        ForEach(queue.history.reversed()) { entry in
                            Button { player.jump(to: entry.id) } label: { QueueRow(entry: entry, isCurrent: false) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Clear Up Next", role: .destructive) { player.clearUpNext() }
                        .disabled(queue.upNext.isEmpty)
                }
            }
        }
    }
}

private struct QueueRow: View {
    @EnvironmentObject private var library: LibraryModel
    let entry: QueueEntry
    let isCurrent: Bool

    var body: some View {
        let track = library.index.track(entry.trackID)
        VStack(alignment: .leading, spacing: 2) {
            Text(track?.title ?? "Missing file").lineLimit(1)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
            if let track, track.hasKnownArtist {
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - Playlists

struct PlaylistsList: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var showsNew = false
    @State private var newName = ""

    var body: some View {
        List {
            NavigationLink {
                FavoritesDetail()
            } label: {
                Label("Favorites (\(library.playlists.favoriteIDs.count))", systemImage: "heart.fill")
                    .foregroundStyle(.pink)
            }
            ForEach(library.playlists.playlists) { playlist in
                NavigationLink {
                    PlaylistDetail(playlistID: playlist.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                        Text("\(playlist.trackIDs.count) songs").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                let items = library.playlists.playlists
                for offset in offsets { library.deletePlaylist(items[offset].id) }
            }
            Button {
                newName = ""
                showsNew = true
            } label: {
                Label("New Playlist", systemImage: "plus")
            }
        }
        .listStyle(.plain)
        .alert("New Playlist", isPresented: $showsNew) {
            TextField("Name", text: $newName)
            Button("Create") { library.createPlaylist(name: newName) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct FavoritesDetail: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        let ids = library.playlists.favoriteIDs
        TrackList(
            tracks: library.index.tracks(for: ids),
            showsNumbers: false,
            header: AnyView(PlayShuffleHeader(trackIDs: ids))
        )
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlaylistDetail: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID
    @State private var showsRename = false
    @State private var name = ""
    @State private var confirmsDelete = false

    var body: some View {
        if let playlist = library.playlists.playlist(playlistID) {
            let tracks = library.index.tracks(for: playlist.trackIDs)
            List {
                PlayShuffleHeader(trackIDs: tracks.map(\.id))
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    Button {
                        player.play(trackIDs: tracks.map(\.id), startAt: index)
                    } label: {
                        TrackRow(track: track, number: index + 1)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { library.removeFromPlaylist(offsets: Array($0), playlist: playlistID) }
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    library.moveInPlaylist(from: from, to: destination, playlist: playlistID)
                }
            }
            .listStyle(.plain)
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            name = playlist.name
                            showsRename = true
                        } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { confirmsDelete = true } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .alert("Rename Playlist", isPresented: $showsRename) {
                TextField("Name", text: $name)
                Button("Save") { library.renamePlaylist(playlistID, to: name) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this playlist?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Playlist", role: .destructive) {
                    library.deletePlaylist(playlistID)
                    dismiss()
                }
            } message: {
                Text("The songs stay in your library.")
            }
        } else {
            ContentUnavailableView("Playlist not found", systemImage: "music.note.list")
        }
    }
}

// MARK: - Playback extras (Now Playing tab)

/// Shuffle, repeat, speed, sleep timer and queue: the controls VLC has that
/// the stock lyrics screen does not.
struct PlayerExtrasCard: View {
    @EnvironmentObject private var player: PlayerController
    @State private var showsQueue = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                extraButton(
                    symbol: "shuffle",
                    title: "Shuffle",
                    active: player.queue.isShuffled
                ) { player.toggleShuffle() }
                extraButton(
                    symbol: player.queue.repeatMode == .one ? "repeat.1" : "repeat",
                    title: repeatTitle,
                    active: player.queue.repeatMode != .off
                ) { player.cycleRepeat() }
                speedMenu
                sleepMenu
                extraButton(symbol: "list.bullet", title: "Queue", active: false) { showsQueue = true }
            }
        }
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showsQueue) { QueueView() }
    }

    private var repeatTitle: String {
        switch player.queue.repeatMode {
        case .off: return "Repeat"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }

    private func extraButton(symbol: String, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                Button {
                    player.setRate(Float(value))
                } label: {
                    if abs(Double(player.rate) - value) < 0.01 {
                        Label(Self.speedText(value), systemImage: "checkmark")
                    } else {
                        Text(Self.speedText(value))
                    }
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "speedometer").font(.title3)
                Text(Self.speedText(Double(player.rate))).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(player.rate != 1 ? Color.accentColor : Color.primary)
        }
    }

    private var sleepMenu: some View {
        Menu {
            ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minutes") { player.startSleepTimer(minutes: minutes) }
            }
            Button("End of this song") { player.sleepAtEndOfTrack() }
            if player.sleepTimer.isActive {
                Button("Turn Off", role: .destructive) { player.cancelSleepTimer() }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "moon.zzz").font(.title3)
                Text("Sleep").font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(player.sleepTimer.isActive ? Color.accentColor : Color.primary)
        }
    }

    private static func speedText(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : String(format: "%g×", value)
    }
}
#endif
