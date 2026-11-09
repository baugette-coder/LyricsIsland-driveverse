#if os(iOS)
import AppIntents
import Combine
import Foundation

/// Owns the song library, playlists and the scan / import jobs. UI reads it;
/// the player resolves track ids through it.
@MainActor
final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()

    enum Activity: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case importing(done: Int, total: Int)
    }

    struct Report: Equatable, Identifiable {
        let id = UUID()
        var title: String
        var lines: [String]
    }

    @Published private(set) var index = LibraryIndex(tracks: [])
    @Published private(set) var playlists = PlaylistCollection()
    @Published private(set) var activity: Activity = .idle
    /// Shown as an alert after a scan or import finishes with something to say.
    @Published var report: Report?
    /// Normalised names of every .lrc in the library, for the "has lyrics" mark.
    @Published private(set) var lyricsKeys: Set<String> = []

    private var tracks: [LibraryTrack] = []
    private var importCancelled = false
    private var started = false
    private static let importedPlaylistsKey = "importedM3UPlaylistPaths"

    private init() {}

    var isBusy: Bool { activity != .idle }

    // MARK: Startup

    func start() {
        guard !started else { return }
        started = true
        LocalLyricsStore.prepareFolder()
        tracks = JSONStore.load([LibraryTrack].self, from: LibraryPaths.libraryFile) ?? []
        playlists = JSONStore.load(PlaylistCollection.self, from: LibraryPaths.playlistsFile) ?? PlaylistCollection()
        rebuildIndex()
        Task { await rescan() }
    }

    private func rebuildIndex() {
        index = LibraryIndex(tracks: tracks, romanize: { title in
            Transliterator.needsLatinization(title) ? Transliterator.latinized(title) : ""
        })
    }

    // MARK: Scanning

    /// Looks for added, changed and removed files. Cheap when nothing changed.
    func rescan() async {
        guard activity == .idle else { return }
        activity = .scanning(done: 0, total: 0)

        let root = LibraryPaths.root
        let skipped = LibraryPaths.skippedTopLevel
        let scan = await Task.detached(priority: .utility) {
            MediaFileScanner.scan(root: root, skippingTopLevel: skipped)
        }.value

        let plan = LibraryReconciler.plan(existing: tracks, scanned: scan.audio)
        var merged = plan.kept
        let total = plan.toRead.count
        activity = .scanning(done: 0, total: total)

        // Read tags a few files at a time; the slow part is disk and decoding.
        var done = 0
        let batchSize = 6
        var start = 0
        let known = Dictionary(tracks.map { ($0.path, $0.addedAt) }, uniquingKeysWith: { a, _ in a })
        while start < plan.toRead.count {
            let batch = Array(plan.toRead[start..<min(start + batchSize, plan.toRead.count)])
            start += batchSize
            let read: [LibraryTrack] = await withTaskGroup(of: LibraryTrack.self) { group in
                for file in batch {
                    group.addTask {
                        let meta = await TrackMetadataReader.read(url: LibraryPaths.url(forTrackPath: file.path))
                        return LibraryTrack(
                            path: file.path,
                            title: meta.title,
                            artist: meta.artist,
                            album: meta.album,
                            albumArtist: meta.albumArtist,
                            trackNumber: meta.trackNumber,
                            discNumber: meta.discNumber,
                            durationMs: meta.durationMs,
                            year: meta.year,
                            fileSize: file.size,
                            modified: file.modified,
                            addedAt: known[file.path] ?? Date()
                        )
                    }
                }
                var out: [LibraryTrack] = []
                for await track in group { out.append(track) }
                return out
            }
            merged.append(contentsOf: read)
            done += batch.count
            activity = .scanning(done: done, total: total)
        }

        tracks = merged
        JSONStore.save(tracks, to: LibraryPaths.libraryFile)
        rebuildIndex()
        lyricsKeys = Set(scan.lyrics.map { TextKey.normalize(TextKey.deletingExtension(($0.path as NSString).lastPathComponent)) })

        playlists.reconcile(existing: Set(tracks.map(\.path)), renamed: plan.renamed)
        importNewM3UPlaylists(scan.playlists)
        savePlaylists()
        activity = .idle
        DriveVerseShortcuts.updateAppShortcutParameters()

        var lines: [String] = []
        if !scan.unsupported.isEmpty {
            lines.append("\(scan.unsupported.count) file(s) are in a format iPhone cannot play (for example OGG or WMA). Convert them to M4A, MP3 or FLAC.")
            lines.append(contentsOf: scan.unsupported.prefix(5).map { "• " + $0 })
        }
        if !lines.isEmpty {
            report = Report(title: "Some files were skipped", lines: lines)
        }
    }

    /// Whether a lyrics file exists that would match this track.
    func hasLyrics(_ track: LibraryTrack) -> Bool {
        lyricsKeys.contains(TextKey.normalize(track.fileStem))
            || lyricsKeys.contains(TextKey.normalize(track.title))
    }

    // MARK: Importing (bulk add)

    /// Copies picked files and folders into the library. Keeps folder
    /// structure, skips duplicates, and rescans when finished.
    func importFiles(from urls: [URL]) async {
        guard activity == .idle, !urls.isEmpty else { return }
        importCancelled = false
        activity = .importing(done: 0, total: 0)

        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        let root = LibraryPaths.root
        let plan = await Task.detached(priority: .userInitiated) {
            ImportPlanner.plan(sources: urls)
        }.value
        activity = .importing(done: 0, total: plan.items.count)

        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let progressTask = Task { @MainActor in
            for await done in stream {
                self.activity = .importing(done: done, total: plan.items.count)
            }
        }
        let flag = CancelFlag()
        cancelFlag = flag
        let summary = await Task.detached(priority: .userInitiated) {
            ImportPlanner.perform(
                items: plan.items,
                into: root,
                unsupported: plan.unsupported,
                progress: { done, _ in continuation.yield(done) },
                isCancelled: { flag.isCancelled }
            )
        }.value
        continuation.finish()
        await progressTask.value
        cancelFlag = nil
        activity = .idle

        await rescan()

        var lines = ["Added \(summary.copied) file(s)."]
        if summary.skippedExisting > 0 { lines.append("\(summary.skippedExisting) already in the library were skipped.") }
        if summary.wasCancelled { lines.append("Import was cancelled.") }
        if !summary.unsupported.isEmpty {
            lines.append("\(summary.unsupported.count) file(s) are in a format iPhone cannot play and were not copied.")
        }
        if !summary.failed.isEmpty {
            lines.append("\(summary.failed.count) file(s) failed:")
            lines.append(contentsOf: summary.failed.prefix(3).map { "• \($0.name): \($0.reason)" })
        }
        report = Report(title: "Import finished", lines: lines)
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }
    private var cancelFlag: CancelFlag?

    func cancelImport() { cancelFlag?.cancel() }

    // MARK: Deleting

    /// Removes the audio files from the device.
    func delete(trackIDs: [String]) {
        let fm = FileManager.default
        for id in trackIDs { try? fm.removeItem(at: LibraryPaths.url(forTrackPath: id)) }
        let gone = Set(trackIDs)
        tracks.removeAll { gone.contains($0.path) }
        JSONStore.save(tracks, to: LibraryPaths.libraryFile)
        rebuildIndex()
        playlists.reconcile(existing: Set(tracks.map(\.path)))
        savePlaylists()
    }

    // MARK: Playlists

    func savePlaylists() { JSONStore.save(playlists, to: LibraryPaths.playlistsFile) }

    @discardableResult
    func createPlaylist(name: String, trackIDs: [String] = []) -> Playlist {
        let made = playlists.create(name: name, trackIDs: trackIDs)
        savePlaylists()
        return made
    }

    func renamePlaylist(_ id: UUID, to name: String) { playlists.rename(id, to: name); savePlaylists() }
    func deletePlaylist(_ id: UUID) { playlists.delete(id); savePlaylists() }

    @discardableResult
    func addToPlaylist(_ trackIDs: [String], playlist id: UUID) -> Int {
        let added = playlists.add(trackIDs, to: id)
        savePlaylists()
        return added
    }

    func removeFromPlaylist(offsets: [Int], playlist id: UUID) { playlists.remove(trackAt: offsets, from: id); savePlaylists() }
    func moveInPlaylist(from source: Int, to destination: Int, playlist id: UUID) {
        playlists.move(from: source, to: destination, in: id)
        savePlaylists()
    }

    func toggleFavorite(_ trackID: String) {
        playlists.setFavorite(trackID, !playlists.isFavorite(trackID))
        savePlaylists()
    }

    /// Creates a playlist for each .m3u/.m3u8 file not imported before.
    private func importNewM3UPlaylists(_ files: [ScannedFile]) {
        let defaults = UserDefaults.standard
        var done = Set(defaults.stringArray(forKey: Self.importedPlaylistsKey) ?? [])
        let paths = tracks.map(\.path)
        for file in files where !done.contains(file.path) {
            guard let data = try? Data(contentsOf: LibraryPaths.url(forTrackPath: file.path)),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { continue }
            let matched = M3UParser.match(entries: M3UParser.entries(from: text), trackPaths: paths).matched
            guard !matched.isEmpty else { continue }
            let name = playlists.uniqueName(TextKey.deletingExtension((file.path as NSString).lastPathComponent))
            playlists.create(name: name, trackIDs: matched)
            done.insert(file.path)
        }
        defaults.set(Array(done), forKey: Self.importedPlaylistsKey)
    }
}
#endif
