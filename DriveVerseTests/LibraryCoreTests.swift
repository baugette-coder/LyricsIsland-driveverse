import Foundation
import Testing
@testable import DriveVerse

private func track(
    _ path: String, title: String? = nil, artist: String? = nil, album: String? = nil,
    albumArtist: String? = nil, no: Int = 0, disc: Int = 0, size: Int64 = 100
) -> LibraryTrack {
    LibraryTrack(path: path, title: title, artist: artist, album: album,
                 albumArtist: albumArtist, trackNumber: no, discNumber: disc,
                 durationMs: 180_000, fileSize: size,
                 modified: Date(timeIntervalSince1970: 1_000), addedAt: Date(timeIntervalSince1970: 1_000))
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lib-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ root: URL, _ relative: String, _ body: String = "x") throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(body.utf8).write(to: url)
}

@Suite struct LibraryTrackTests {
    @Test func missingTagsFallBackToFileNameAndUnknowns() {
        let t = LibraryTrack(path: "Vocaloid/イガク.m4a")
        #expect(t.title == "イガク")
        #expect(t.artist == "Unknown Artist")
        #expect(t.album == "Unknown Album")
        #expect(t.folder == "Vocaloid")
        #expect(t.fileStem == "イガク")
    }

    @Test func blankTagsCountAsMissing() {
        let t = LibraryTrack(path: "a.m4a", title: "  ", artist: "")
        #expect(t.title == "a")
        #expect(!t.hasKnownArtist)
    }

    @Test func albumArtistFallsBackToArtist() {
        let t = LibraryTrack(path: "a.m4a", artist: "Teto")
        #expect(t.albumArtist == "Teto")
    }

    @Test func topLevelFileHasNoFolder() {
        #expect(LibraryTrack(path: "song.mp3").folder == "")
    }

    @Test func extensionHelperKeepsDotFiles() {
        #expect(TextKey.deletingExtension("a.b.m4a") == "a.b")
        #expect(TextKey.deletingExtension(".hidden") == ".hidden")
        #expect(TextKey.deletingExtension("noext") == "noext")
    }
}

@Suite struct LibraryIndexTests {
    private func sample() -> LibraryIndex {
        LibraryIndex(tracks: [
            track("a/2.m4a", title: "Second", artist: "Teto", album: "Album A", no: 2),
            track("a/1.m4a", title: "First", artist: "Teto", album: "Album A", no: 1),
            track("b/x.m4a", title: "Solo", artist: "Miku", album: "Album B", no: 1),
            track("loose.m4a", title: "Loose"),
            track("a/d2.m4a", title: "Disc Two", artist: "Teto", album: "Album A", no: 1, disc: 2),
        ])
    }

    @Test func songsAreSortedByTitle() {
        let titles = sample().tracks.map(\.title)
        #expect(titles == ["Disc Two", "First", "Loose", "Second", "Solo"])
    }

    @Test func albumTracksFollowDiscThenTrackNumber() {
        let index = sample()
        let album = index.albums.first { $0.title == "Album A" }!
        #expect(index.tracks(for: album.trackIDs).map(\.title) == ["First", "Second", "Disc Two"])
    }

    @Test func artistsListTheirAlbums() {
        let index = sample()
        let teto = index.artists.first { $0.name == "Teto" }!
        #expect(teto.trackIDs.count == 3)
        #expect(teto.albumIDs.count == 1)
    }

    @Test func looseTrackGetsUnknownGroups() {
        let index = sample()
        #expect(index.albums.contains { $0.title == "Unknown Album" })
        #expect(index.artists.contains { $0.name == "Unknown Artist" })
    }

    @Test func searchMatchesAnyFieldAndAllWords() {
        let index = sample()
        #expect(index.search("teto album").count == 3)
        #expect(index.search("MIKU").map(\.title) == ["Solo"])
        #expect(index.search("   ").isEmpty)
        #expect(index.search("zzz").isEmpty)
    }

    @Test func searchFindsJapaneseTitleByRomajiReading() {
        let index = LibraryIndex(
            tracks: [track("v/igaku.m4a", title: "イガク", artist: "重音テト")],
            romanize: { $0 == "イガク" ? "igaku" : "" }
        )
        #expect(index.search("igaku").count == 1)
        #expect(index.search("イガク").count == 1)
        #expect(index.search("テト").count == 1)
    }

    @Test func searchIgnoresWidthAndCase() {
        let index = LibraryIndex(tracks: [track("a.m4a", title: "Ｍarshall Maximizer")])
        #expect(index.search("marshall maximizer").count == 1)
    }

    @Test func folderListingShowsDirectChildrenOnly() {
        let index = sample()
        let top = index.folderListing(at: "")
        #expect(top.folders == ["a", "b"])
        #expect(top.tracks.map(\.path) == ["loose.m4a"])
        let inA = index.folderListing(at: "a")
        #expect(inA.folders.isEmpty)
        #expect(inA.tracks.count == 3)
    }

    @Test func nestedFoldersListLeafNames() {
        let index = LibraryIndex(tracks: [track("x/y/z.m4a"), track("x/q.m4a")])
        #expect(index.folderListing(at: "x").folders == ["y"])
        #expect(index.tracks(inFolder: "x").count == 2)
    }

    @Test func missingIdsAreDroppedWhenResolving() {
        let index = sample()
        #expect(index.tracks(for: ["loose.m4a", "gone.m4a"]).count == 1)
        #expect(index.track("gone.m4a") == nil)
    }
}

@Suite struct PlaylistCollectionTests {
    @Test func createAddAndDeduplicate() {
        var c = PlaylistCollection()
        let p = c.create(name: "Drive", trackIDs: ["a", "b", "a"])
        #expect(c.playlist(p.id)?.trackIDs == ["a", "b"])
        #expect(c.add(["b", "c"], to: p.id) == 1)
        #expect(c.playlist(p.id)?.trackIDs == ["a", "b", "c"])
    }

    @Test func blankNameGetsUniqueDefault() {
        var c = PlaylistCollection()
        let first = c.create(name: "")
        let second = c.create(name: " ")
        #expect(first.name == "New Playlist")
        #expect(second.name == "New Playlist 2")
    }

    @Test func renameIgnoresBlank() {
        var c = PlaylistCollection()
        let p = c.create(name: "A")
        c.rename(p.id, to: "  ")
        #expect(c.playlist(p.id)?.name == "A")
        c.rename(p.id, to: "B")
        #expect(c.playlist(p.id)?.name == "B")
    }

    @Test func removeAndMoveTracks() {
        var c = PlaylistCollection()
        let p = c.create(name: "P", trackIDs: ["a", "b", "c", "d"])
        c.remove(trackAt: [0, 2], from: p.id)
        #expect(c.playlist(p.id)?.trackIDs == ["b", "d"])
        c.move(from: 0, to: 2, in: p.id)
        #expect(c.playlist(p.id)?.trackIDs == ["d", "b"])
    }

    @Test func deleteRemovesPlaylist() {
        var c = PlaylistCollection()
        let p = c.create(name: "P")
        c.delete(p.id)
        #expect(c.playlists.isEmpty)
    }

    @Test func favouritesToggle() {
        var c = PlaylistCollection()
        c.setFavorite("a", true)
        c.setFavorite("a", true)
        #expect(c.favoriteIDs == ["a"])
        #expect(c.isFavorite("a"))
        c.setFavorite("a", false)
        #expect(!c.isFavorite("a"))
    }

    @Test func reconcileDropsGoneTracksAndFollowsRenames() {
        var c = PlaylistCollection()
        let p = c.create(name: "P", trackIDs: ["old.m4a", "keep.m4a", "gone.m4a"])
        c.setFavorite("old.m4a", true)
        c.reconcile(existing: ["new.m4a", "keep.m4a"], renamed: ["old.m4a": "new.m4a"])
        #expect(c.playlist(p.id)?.trackIDs == ["new.m4a", "keep.m4a"])
        #expect(c.favoriteIDs == ["new.m4a"])
    }

    @Test func collectionRoundTripsThroughJSON() throws {
        var c = PlaylistCollection()
        c.create(name: "P", trackIDs: ["a"])
        c.setFavorite("a", true)
        let back = try JSONDecoder().decode(PlaylistCollection.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }
}

@Suite struct M3UTests {
    @Test func entriesSkipCommentsAndBlankLinesAndBOM() {
        let text = "\u{FEFF}#EXTM3U\n#EXTINF:123,Artist - Title\nMusic\\a.m4a\n\n  b.mp3  \n"
        #expect(M3UParser.entries(from: text) == ["Music\\a.m4a", "b.mp3"])
    }

    @Test func matchesByExactPathSuffixAndUniqueName() {
        let paths = ["Vocaloid/a.m4a", "Vocaloid/Sub/b.m4a", "c.m4a", "x/dup.m4a", "y/dup.m4a"]
        let result = M3UParser.match(
            entries: ["Vocaloid\\a.m4a", "D:\\Music\\Vocaloid\\Sub\\b.m4a", "elsewhere/c.m4a", "dup.m4a", "nothere.m4a"],
            trackPaths: paths
        )
        #expect(result.matched == ["Vocaloid/a.m4a", "Vocaloid/Sub/b.m4a", "c.m4a"])
        #expect(result.missing == ["dup.m4a", "nothere.m4a"])
    }

    @Test func matchingIsCaseInsensitive() {
        let result = M3UParser.match(entries: ["VOCALOID/A.M4A"], trackPaths: ["Vocaloid/a.m4a"])
        #expect(result.matched == ["Vocaloid/a.m4a"])
    }
}

@Suite struct ReconcilerTests {
    private func scanned(_ path: String, size: Int64 = 100, at t: Double = 1_000) -> ScannedFile {
        ScannedFile(path: path, size: size, modified: Date(timeIntervalSince1970: t))
    }

    @Test func unchangedFilesKeepTheirTags() {
        let known = track("a.m4a", title: "A")
        let plan = LibraryReconciler.plan(existing: [known], scanned: [scanned("a.m4a")])
        #expect(plan.kept == [known])
        #expect(plan.toRead.isEmpty)
        #expect(plan.removedPaths.isEmpty)
    }

    @Test func newAndChangedFilesAreReadAgain() {
        let known = track("a.m4a", size: 100)
        let plan = LibraryReconciler.plan(
            existing: [known],
            scanned: [scanned("a.m4a", size: 999), scanned("b.m4a")]
        )
        #expect(plan.kept.isEmpty)
        #expect(plan.toRead.map(\.path) == ["a.m4a", "b.m4a"])
    }

    @Test func deletedFilesAreReported() {
        let plan = LibraryReconciler.plan(existing: [track("a.m4a"), track("b.m4a")], scanned: [scanned("a.m4a")])
        #expect(plan.removedPaths == ["b.m4a"])
    }

    @Test func movedFileIsRecognisedAsRename() {
        let plan = LibraryReconciler.plan(
            existing: [track("old/song.m4a", size: 500)],
            scanned: [scanned("new/song.m4a", size: 500)]
        )
        #expect(plan.renamed == ["old/song.m4a": "new/song.m4a"])
        #expect(plan.removedPaths == ["old/song.m4a"])
    }

    @Test func differentSizeIsNotARename() {
        let plan = LibraryReconciler.plan(
            existing: [track("old/song.m4a", size: 500)],
            scanned: [scanned("new/song.m4a", size: 501)]
        )
        #expect(plan.renamed.isEmpty)
    }
}

@Suite struct ScannerAndImportTests {
    @Test func scannerFindsAudioLyricsPlaylistsAndReportsUnsupported() throws {
        let root = try makeTempDir()
        try write(root, "a.m4a")
        try write(root, "Album/b.MP3")
        try write(root, "Album/b.lrc")
        try write(root, "list.m3u8")
        try write(root, "weird.ogg")
        try write(root, "notes.txt")
        try write(root, ".hidden.m4a")
        let result = MediaFileScanner.scan(root: root)
        #expect(result.audio.map(\.path) == ["Album/b.MP3", "a.m4a"])
        #expect(result.lyrics.map(\.path) == ["Album/b.lrc"])
        #expect(result.playlists.map(\.path) == ["list.m3u8"])
        #expect(result.unsupported == ["weird.ogg"])
    }

    @Test func scannerCanSkipBookkeepingFolders() throws {
        let root = try makeTempDir()
        try write(root, "keep.m4a")
        try write(root, "Inbox/skip.m4a")
        let result = MediaFileScanner.scan(root: root, skippingTopLevel: ["Inbox"])
        #expect(result.audio.map(\.path) == ["keep.m4a"])
    }

    @Test func importCopiesFolderKeepingStructureAndSkipsJunk() throws {
        let source = try makeTempDir().appendingPathComponent("My Album")
        try write(source, "01.m4a", "audio1")
        try write(source, "Disc 2/02.m4a", "audio2")
        try write(source, "01.lrc", "[00:01.00]a")
        try write(source, "cover.jpg", "img")
        try write(source, "bad.wma", "w")
        let dest = try makeTempDir()
        let plan = ImportPlanner.plan(sources: [source])
        #expect(plan.items.count == 3)
        #expect(plan.unsupported == ["My Album/bad.wma"])
        let summary = ImportPlanner.perform(items: plan.items, into: dest, unsupported: plan.unsupported)
        #expect(summary.copied == 3)
        #expect(summary.failed.isEmpty)
        let scan = MediaFileScanner.scan(root: dest)
        #expect(scan.audio.map(\.path) == ["My Album/01.m4a", "My Album/Disc 2/02.m4a"])
        #expect(scan.lyrics.map(\.path) == ["My Album/01.lrc"])
    }

    @Test func importSkipsIdenticalAndNumbersDifferentAudio() throws {
        let src = try makeTempDir()
        try write(src, "song.m4a", "AAAA")
        let dest = try makeTempDir()
        let first = ImportPlanner.plan(sources: [src.appendingPathComponent("song.m4a")])
        _ = ImportPlanner.perform(items: first.items, into: dest)
        let again = ImportPlanner.perform(items: first.items, into: dest)
        #expect(again.skippedExisting == 1)
        #expect(again.copied == 0)
        try write(src, "song.m4a", "BBBBBBBB")
        let changed = ImportPlanner.plan(sources: [src.appendingPathComponent("song.m4a")])
        let third = ImportPlanner.perform(items: changed.items, into: dest)
        #expect(third.copied == 1)
        #expect(MediaFileScanner.scan(root: dest).audio.map(\.path) == ["song (2).m4a", "song.m4a"])
    }

    @Test func importReplacesChangedLyricsFile() throws {
        let src = try makeTempDir()
        try write(src, "s.lrc", "[00:01.00]old")
        let dest = try makeTempDir()
        let item = ImportPlanner.plan(sources: [src.appendingPathComponent("s.lrc")])
        _ = ImportPlanner.perform(items: item.items, into: dest)
        try write(src, "s.lrc", "[00:01.00]a much newer version")
        let item2 = ImportPlanner.plan(sources: [src.appendingPathComponent("s.lrc")])
        _ = ImportPlanner.perform(items: item2.items, into: dest)
        let text = try String(contentsOf: dest.appendingPathComponent("s.lrc"), encoding: .utf8)
        #expect(text == "[00:01.00]a much newer version")
    }

    @Test func importReportsProgressAndHonoursCancel() throws {
        let src = try makeTempDir()
        for n in 1...4 { try write(src, "\(n).m4a", "data\(n)") }
        let dest = try makeTempDir()
        let plan = ImportPlanner.plan(sources: [src])
        var seen: [Int] = []
        var calls = 0
        let summary = ImportPlanner.perform(
            items: plan.items, into: dest,
            progress: { done, _ in seen.append(done) },
            isCancelled: { calls += 1; return calls > 2 }
        )
        #expect(summary.wasCancelled)
        #expect(summary.copied == 2)
        #expect(seen == [1, 2])
    }

    @Test func nonexistentSourcesAreIgnored() {
        let plan = ImportPlanner.plan(sources: [URL(fileURLWithPath: "/definitely/not/here.m4a")])
        #expect(plan.items.isEmpty)
    }
}
