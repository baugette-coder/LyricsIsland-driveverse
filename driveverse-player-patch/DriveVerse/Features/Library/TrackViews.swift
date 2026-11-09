#if os(iOS)
import SwiftUI

/// A scrolling list of tracks. Tapping a row plays the whole list from there.
struct TrackList: View {
    let tracks: [LibraryTrack]
    var showsNumbers = false
    var header: AnyView?
    var footer: String?

    var body: some View {
        List {
            if let header { header.listRowSeparator(.hidden) }
            TrackRows(tracks: tracks, showsNumbers: showsNumbers)
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }
}

/// The rows themselves, for use inside any `List`.
struct TrackRows: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: LibraryModel
    let tracks: [LibraryTrack]
    var showsNumbers = false
    @State private var pendingDelete: LibraryTrack?

    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            Button {
                player.play(trackIDs: tracks.map(\.id), startAt: index)
            } label: {
                TrackRow(track: track, number: showsNumbers ? index + 1 : nil)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .leading) {
                Button { player.playNext([track.id]) } label: { Label("Play Next", systemImage: "text.insert") }
                    .tint(.blue)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { pendingDelete = track } label: { Label("Delete", systemImage: "trash") }
                Button { player.addToQueue([track.id]) } label: { Label("Queue", systemImage: "text.append") }
                    .tint(.indigo)
            }
            .contextMenu { TrackMenu(track: track, onDelete: { pendingDelete = track }) }
            .confirmationDialog(
                "Delete this song from your iPhone?",
                isPresented: Binding(
                    get: { pendingDelete?.id == track.id },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete “\(track.title)”", role: .destructive) {
                    library.delete(trackIDs: [track.id])
                }
            } message: {
                Text("The audio file is removed from the app. Its lyrics file stays.")
            }
        }
    }
}

struct TrackRow: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: LibraryModel
    let track: LibraryTrack
    var number: Int?

    var body: some View {
        let isCurrent = player.currentTrack?.id == track.id
        HStack(spacing: 10) {
            if let number {
                Text("\(number)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
            }
            if isCurrent {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if library.hasLyrics(track) {
                Image(systemName: "text.quote").font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Has lyrics")
            }
            if library.playlists.isFavorite(track.id) {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink)
                    .accessibilityLabel("Favorite")
            }
            Text(Self.duration(track.durationMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        [track.hasKnownArtist ? track.artist : nil, track.hasKnownAlbum ? track.album : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    static func duration(_ ms: Int) -> String {
        guard ms > 0 else { return "" }
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Long-press menu shared by every track row.
struct TrackMenu: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: LibraryModel
    let track: LibraryTrack
    let onDelete: () -> Void

    var body: some View {
        Button { player.playNext([track.id]) } label: { Label("Play Next", systemImage: "text.insert") }
        Button { player.addToQueue([track.id]) } label: { Label("Add to Queue", systemImage: "text.append") }
        Button { library.toggleFavorite(track.id) } label: {
            if library.playlists.isFavorite(track.id) {
                Label("Remove from Favorites", systemImage: "heart.slash")
            } else {
                Label("Favorite", systemImage: "heart")
            }
        }
        Menu {
            ForEach(library.playlists.playlists) { playlist in
                Button(playlist.name) { library.addToPlaylist([track.id], playlist: playlist.id) }
            }
            Button {
                library.createPlaylist(
                    name: library.playlists.uniqueName("New Playlist"),
                    trackIDs: [track.id]
                )
            } label: {
                Label("New Playlist", systemImage: "plus")
            }
        } label: {
            Label("Add to Playlist", systemImage: "music.note.list")
        }
        Divider()
        Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
    }
}

// MARK: - Mini player

struct MiniPlayer: View {
    @EnvironmentObject private var player: PlayerController
    let open: () -> Void

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: 12) {
                Group {
                    if let artwork = player.artwork {
                        Image(uiImage: artwork).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.quaternary)
                    }
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if track.hasKnownArtist {
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skipForward() } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .accessibilityLabel("Next")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
    }
}

// MARK: - Sleep timer menu

struct SleepTimerMenu: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        Menu {
            ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minutes") { player.startSleepTimer(minutes: minutes) }
            }
            Button("End of this song") { player.sleepAtEndOfTrack() }
            if player.sleepTimer.isActive {
                Button("Turn Off", role: .destructive) { player.cancelSleepTimer() }
            }
        } label: {
            Label(
                player.sleepTimer.isActive ? "Sleep Timer (on)" : "Sleep Timer",
                systemImage: "moon.zzz"
            )
        }
    }
}
#endif
