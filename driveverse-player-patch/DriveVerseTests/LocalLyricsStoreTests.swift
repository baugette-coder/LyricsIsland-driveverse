import Foundation
import Testing
@testable import DriveVerse

private func makeFolder(_ files: [String: Data]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lyrics-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, body) in files {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url)
    }
    return dir
}

private func utf8(_ text: String) -> Data { Data(text.utf8) }

@Suite struct LocalLyricsStoreTests {
    @Test func normalizeKeepsJapaneseAndDropsPunctuation() {
        #expect(LocalLyricsStore.normalize("イガク") == "イガク")
        #expect(LocalLyricsStore.normalize("Marshall Maximizer!") == "marshallmaximizer")
    }

    @Test func stackedLinesBecomeOriginalAndTranslation() throws {
        let folder = try makeFolder([
            "Test Song.lrc": utf8("[00:01.00]aiueo\n[00:01.00]hello\n[00:05.00]kakiku\n[00:05.00]world\n"),
        ])
        let content = LocalLyricsStore.lyrics(title: "Test Song", artist: "Someone", in: folder)
        guard case .document(let doc)? = content else {
            Issue.record("expected a lyrics document")
            return
        }
        #expect(doc.source == .local)
        #expect(doc.lines.count == 2)
        #expect(doc.lines[0].original == "aiueo")
        #expect(doc.lines[0].translation == "hello")
        #expect(doc.lines[1].original == "kakiku")
        #expect(doc.lines[1].translation == "world")
    }

    @Test func exactNameBeatsLooseMatch() throws {
        let folder = try makeFolder([
            "Song.lrc": utf8("[00:01.00]exact\n"),
            "Song - Extra.lrc": utf8("[00:01.00]loose\n"),
        ])
        let url = LocalLyricsStore.bestMatch(title: "Song", artist: "", in: folder)
        #expect(url?.lastPathComponent == "Song.lrc")
    }

    @Test func artistAndTitleFileNameMatches() throws {
        let folder = try makeFolder(["Artist - Song.lrc": utf8("[00:01.00]a\n")])
        let url = LocalLyricsStore.bestMatch(title: "Song", artist: "Artist", in: folder)
        #expect(url?.lastPathComponent == "Artist - Song.lrc")
    }

    @Test func audioFileNameBeatsTitleTag() throws {
        let folder = try makeFolder([
            "01 - イガク.lrc": utf8("[00:01.00]by file\n"),
            "Wrong Tag.lrc": utf8("[00:01.00]by tag\n"),
        ])
        let url = LocalLyricsStore.bestMatch(title: "Wrong Tag", artist: "", fileStem: "01 - イガク", in: folder)
        #expect(url?.lastPathComponent == "01 - イガク.lrc")
    }

    @Test func findsLyricsInSubfoldersAndPrefersSameFolder() throws {
        let folder = try makeFolder([
            "Lyrics/Song.lrc": utf8("[00:01.00]shared\n"),
            "Album/Song.lrc": utf8("[00:01.00]next to audio\n"),
        ])
        let url = LocalLyricsStore.bestMatch(
            title: "Song", artist: "", fileStem: "Song", audioFolder: "Album", in: folder
        )
        #expect(url?.path.hasSuffix("Album/Song.lrc") == true)
        let other = LocalLyricsStore.bestMatch(
            title: "Song", artist: "", fileStem: "Song", audioFolder: "", in: folder
        )
        #expect(other != nil)
    }

    @Test func noMatchReturnsNil() throws {
        let folder = try makeFolder(["Other.lrc": utf8("[00:01.00]a\n")])
        #expect(LocalLyricsStore.lyrics(title: "Song", artist: "x", in: folder) == nil)
    }

    @Test func utf8ByteOrderMarkIsIgnored() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(utf8("[00:01.00]a\n[00:01.00]b\n"))
        let folder = try makeFolder(["Song.lrc": data])
        let content = LocalLyricsStore.lyrics(title: "Song", artist: "", in: folder)
        guard case .document(let doc)? = content else {
            Issue.record("expected a lyrics document")
            return
        }
        #expect(doc.lines.first?.original == "a")
        #expect(doc.lines.first?.translation == "b")
    }

    @Test func japaneseFileNameMatchesJapaneseTitle() throws {
        let folder = try makeFolder(["イガク.lrc": utf8("[00:01.00]a\n[00:01.00]b\n")])
        let content = LocalLyricsStore.lyrics(title: "イガク", artist: "重音テト", in: folder)
        #expect(content != nil)
    }
}
