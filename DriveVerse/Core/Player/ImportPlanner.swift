import Foundation

struct ImportItem: Equatable {
    let source: URL
    /// Destination path relative to the library root.
    let destination: String
    let size: Int64
}

struct ImportFailure: Equatable {
    let name: String
    let reason: String
}

struct ImportSummary: Equatable {
    var copied = 0
    var skippedExisting = 0
    var failed: [ImportFailure] = []
    /// Audio files iOS cannot play (ogg, wma, ...). Never copied.
    var unsupported: [String] = []
    var wasCancelled = false
}

/// Bulk import: copies picked files and whole folders into the library,
/// keeping folder structure. Pure Foundation so it can be tested off-device.
enum ImportPlanner {
    static func isWanted(_ ext: String) -> Bool {
        AudioFormats.isPlayable(ext) || AudioFormats.isLyrics(ext) || AudioFormats.isPlaylist(ext)
    }

    /// Expands files and folders into a flat copy list. Folder names are kept
    /// as a top-level folder so albums stay together.
    static func plan(sources: [URL]) -> (items: [ImportItem], unsupported: [String]) {
        let fm = FileManager.default
        var items: [ImportItem] = []
        var unsupported: [String] = []

        for source in sources {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let base = source.resolvingSymlinksInPath()
                let basePath = base.path
                let folderName = source.lastPathComponent
                guard let walker = fm.enumerator(
                    at: base,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let url as URL in walker {
                    guard url.path.hasPrefix(basePath + "/"),
                          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          values.isRegularFile == true else { continue }
                    let relative = String(url.path.dropFirst(basePath.count + 1))
                    let ext = url.pathExtension
                    if isWanted(ext) {
                        items.append(ImportItem(
                            source: url,
                            destination: folderName + "/" + relative,
                            size: Int64(values.fileSize ?? 0)
                        ))
                    } else if AudioFormats.isUnsupported(ext) {
                        unsupported.append(folderName + "/" + relative)
                    }
                }
            } else {
                let ext = source.pathExtension
                if isWanted(ext) {
                    let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    items.append(ImportItem(
                        source: source,
                        destination: source.lastPathComponent,
                        size: Int64(size)
                    ))
                } else if AudioFormats.isUnsupported(ext) {
                    unsupported.append(source.lastPathComponent)
                }
            }
        }
        items.sort { $0.destination < $1.destination }
        return (items, unsupported.sorted())
    }

    /// Copies the items. `progress(done, total)` is called after each file.
    /// Existing identical files are skipped; lyrics and playlist files are
    /// replaced when different; audio with the same name but a different
    /// size is kept under a numbered name.
    static func perform(
        items: [ImportItem],
        into root: URL,
        unsupported: [String] = [],
        progress: (Int, Int) -> Void = { _, _ in },
        isCancelled: () -> Bool = { false }
    ) -> ImportSummary {
        let fm = FileManager.default
        var summary = ImportSummary()
        summary.unsupported = unsupported

        for (index, item) in items.enumerated() {
            if isCancelled() {
                summary.wasCancelled = true
                break
            }
            defer { progress(index + 1, items.count) }

            var target = root.appendingPathComponent(item.destination)
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) {
                    let existingSize = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value
                    if existingSize == item.size {
                        summary.skippedExisting += 1
                        continue
                    }
                    if AudioFormats.isLyrics(target.pathExtension) || AudioFormats.isPlaylist(target.pathExtension) {
                        try fm.removeItem(at: target)
                    } else {
                        target = uniqueURL(for: target)
                    }
                }
                try fm.copyItem(at: item.source, to: target)
                summary.copied += 1
            } catch {
                summary.failed.append(ImportFailure(
                    name: item.destination,
                    reason: error.localizedDescription
                ))
            }
        }
        return summary
    }

    /// "Song.m4a" -> "Song (2).m4a" -> "Song (3).m4a" ...
    static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = TextKey.deletingExtension(url.lastPathComponent)
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
