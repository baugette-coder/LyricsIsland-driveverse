import Foundation

struct NowPlayingState: Equatable {
    let title: String
    let artist: String
    let album: String?
    /// Small JPEG thumbnail suitable for the Live Activity payload.
    let artworkData: Data?
    /// A larger, app-only image. This is deliberately kept separate from the
    /// sub-4 KB ActivityKit state used by `artworkData`.
    let displayArtworkData: Data?
    let durationMs: Int?
    let positionMs: Int
    let isPlaying: Bool
    /// When `positionMs` was observed — the sync engine extrapolates from here.
    let capturedAt: Date
    /// Set only for tracks played by DriveVerse's own player: the audio file
    /// name without extension. Lets a same-named .lrc file match exactly.
    let fileStem: String?
    /// Folder of that audio file, relative to the library root ("" = top level).
    let fileFolder: String?

    init(
        title: String,
        artist: String,
        album: String?,
        artworkData: Data? = nil,
        displayArtworkData: Data? = nil,
        durationMs: Int?,
        positionMs: Int,
        isPlaying: Bool,
        capturedAt: Date,
        fileStem: String? = nil,
        fileFolder: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
        self.displayArtworkData = displayArtworkData
        self.durationMs = durationMs
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        self.capturedAt = capturedAt
        self.fileStem = fileStem
        self.fileFolder = fileFolder
    }

    func with(isPlaying: Bool) -> NowPlayingState {
        NowPlayingState(
            title: title, artist: artist, album: album, artworkData: artworkData,
            displayArtworkData: displayArtworkData,
            durationMs: durationMs, positionMs: positionMs,
            isPlaying: isPlaying, capturedAt: capturedAt,
            fileStem: fileStem, fileFolder: fileFolder
        )
    }

    /// Same logical track (ignoring position/playback flags).
    func isSameTrack(as other: NowPlayingState) -> Bool {
        title == other.title && artist == other.artist
    }
}
