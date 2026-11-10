import Foundation

/// Decides which files need their tags read after a scan. Reading tags is
/// the slow part, so unchanged files keep their stored metadata.
struct ReconcilePlan: Equatable {
    /// Files that are new or changed and must be (re)read.
    var toRead: [ScannedFile]
    /// Tracks still on disk and unchanged.
    var kept: [LibraryTrack]
    /// Paths that were in the library but are no longer on disk.
    var removedPaths: [String]
    /// Old path -> new path, for files that were moved or renamed. Used to
    /// keep playlists intact.
    var renamed: [String: String]
}

enum LibraryReconciler {
    static func plan(existing: [LibraryTrack], scanned: [ScannedFile]) -> ReconcilePlan {
        let existingByPath = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let scannedPaths = Set(scanned.map(\.path))

        var kept: [LibraryTrack] = []
        var toRead: [ScannedFile] = []
        for file in scanned {
            if let known = existingByPath[file.path],
               known.fileSize == file.size,
               abs(known.modified.timeIntervalSince(file.modified)) < 1 {
                kept.append(known)
            } else {
                toRead.append(file)
            }
        }
        let removed = existing.map(\.path).filter { !scannedPaths.contains($0) }

        // A removed track and a new file with the same name and size are
        // almost certainly a move. Pair them one-to-one.
        var renamed: [String: String] = [:]
        let newOnes = toRead.filter { existingByPath[$0.path] == nil }
        var unclaimed = newOnes
        for path in removed {
            guard let old = existingByPath[path] else { continue }
            let oldName = TextKey.deletingExtension(path.split(separator: "/").last.map(String.init) ?? path)
            if let match = unclaimed.firstIndex(where: {
                $0.size == old.fileSize
                    && TextKey.deletingExtension($0.path.split(separator: "/").last.map(String.init) ?? $0.path) == oldName
            }) {
                renamed[path] = unclaimed[match].path
                unclaimed.remove(at: match)
            }
        }
        return ReconcilePlan(toRead: toRead, kept: kept, removedPaths: removed, renamed: renamed)
    }
}
