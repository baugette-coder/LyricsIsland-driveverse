import Foundation

enum RepeatMode: String, Codable, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

struct QueueEntry: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    let trackID: String

    init(id: UUID = UUID(), trackID: String) {
        self.id = id
        self.trackID = trackID
    }
}

/// The play queue: pure value type with no audio or UI dependencies.
///
/// `entries` is the order tracks will actually play. When shuffle is on it is
/// a shuffled copy; `originalOrder` remembers the un-shuffled order so
/// switching shuffle off restores it.
struct PlayQueue: Codable, Equatable {
    private(set) var entries: [QueueEntry] = []
    private(set) var originalOrder: [UUID] = []
    private(set) var currentIndex: Int?
    private(set) var isShuffled = false
    var repeatMode: RepeatMode = .off

    init() {}

    // MARK: Building

    /// A fresh queue. With shuffle on, `startAt` still plays first.
    static func make<G: RandomNumberGenerator>(
        trackIDs: [String],
        startAt: Int = 0,
        shuffle: Bool = false,
        repeatMode: RepeatMode = .off,
        using rng: inout G
    ) -> PlayQueue {
        var queue = PlayQueue()
        queue.repeatMode = repeatMode
        guard !trackIDs.isEmpty else { return queue }
        let list = trackIDs.map { QueueEntry(trackID: $0) }
        queue.entries = list
        queue.originalOrder = list.map(\.id)
        queue.currentIndex = min(max(startAt, 0), list.count - 1)
        if shuffle { queue.setShuffle(true, using: &rng) }
        return queue
    }

    static func make(
        trackIDs: [String],
        startAt: Int = 0,
        shuffle: Bool = false,
        repeatMode: RepeatMode = .off
    ) -> PlayQueue {
        var rng = SystemRandomNumberGenerator()
        return make(trackIDs: trackIDs, startAt: startAt, shuffle: shuffle,
                    repeatMode: repeatMode, using: &rng)
    }

    // MARK: Reading

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    var current: QueueEntry? {
        guard let i = currentIndex, entries.indices.contains(i) else { return nil }
        return entries[i]
    }
    /// Entries that will play after the current one (not counting repeat).
    var upNext: [QueueEntry] {
        guard let i = currentIndex else { return entries }
        return Array(entries.dropFirst(i + 1))
    }
    var history: [QueueEntry] {
        guard let i = currentIndex else { return [] }
        return Array(entries.prefix(i))
    }
    var hasNext: Bool {
        guard let i = currentIndex else { return false }
        return i + 1 < entries.count || (repeatMode == .all && !entries.isEmpty)
    }
    var hasPrevious: Bool {
        guard let i = currentIndex else { return false }
        return i > 0 || (repeatMode == .all && !entries.isEmpty)
    }

    // MARK: Moving through the queue

    /// The current track finished by itself. Repeat-one replays it; at the
    /// end, repeat-all wraps and repeat-off stops (returns nil, index kept).
    @discardableResult
    mutating func advanceAfterFinish() -> QueueEntry? {
        guard let i = currentIndex, !entries.isEmpty else { return nil }
        if repeatMode == .one { return entries[i] }
        return stepForward(from: i)
    }

    /// The user tapped Next. Repeat-one does not trap the user on a track.
    @discardableResult
    mutating func skipForward() -> QueueEntry? {
        guard let i = currentIndex, !entries.isEmpty else { return nil }
        return stepForward(from: i)
    }

    /// Previous track. At the start: wraps with repeat-all, otherwise returns
    /// the same entry so the caller restarts it.
    @discardableResult
    mutating func skipBackward() -> QueueEntry? {
        guard let i = currentIndex, !entries.isEmpty else { return nil }
        if i > 0 {
            currentIndex = i - 1
        } else if repeatMode == .all {
            currentIndex = entries.count - 1
        }
        return current
    }

    private mutating func stepForward(from i: Int) -> QueueEntry? {
        if i + 1 < entries.count {
            currentIndex = i + 1
            return current
        }
        if repeatMode == .all {
            currentIndex = 0
            return current
        }
        return nil
    }

    /// Jump straight to an entry (tapping a row in the queue).
    @discardableResult
    mutating func jump(to entryID: UUID) -> QueueEntry? {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return nil }
        currentIndex = index
        return current
    }

    // MARK: Editing

    /// Plays these next, in the order given, right after the current track.
    mutating func playNext(_ trackIDs: [String]) {
        let new = trackIDs.map { QueueEntry(trackID: $0) }
        guard !new.isEmpty else { return }
        guard let i = currentIndex else {
            entries = new
            originalOrder = new.map(\.id)
            currentIndex = 0
            return
        }
        entries.insert(contentsOf: new, at: i + 1)
        let currentID = entries[i].id
        let anchor = originalOrder.firstIndex(of: currentID).map { $0 + 1 } ?? originalOrder.count
        originalOrder.insert(contentsOf: new.map(\.id), at: anchor)
    }

    mutating func append(_ trackIDs: [String]) {
        let new = trackIDs.map { QueueEntry(trackID: $0) }
        guard !new.isEmpty else { return }
        entries.append(contentsOf: new)
        originalOrder.append(contentsOf: new.map(\.id))
        if currentIndex == nil { currentIndex = 0 }
    }

    enum RemoveOutcome: Equatable {
        case removedOther
        /// The removed entry was playing; `next` is what should play now.
        case removedCurrent(next: QueueEntry?)
        case notFound
    }

    @discardableResult
    mutating func remove(_ entryID: UUID) -> RemoveOutcome {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return .notFound }
        entries.remove(at: index)
        originalOrder.removeAll { $0 == entryID }
        guard let current = currentIndex else { return .removedOther }
        if entries.isEmpty {
            currentIndex = nil
            return .removedCurrent(next: nil)
        }
        if index < current {
            currentIndex = current - 1
            return .removedOther
        }
        if index == current {
            if current >= entries.count {
                // Removed the last entry while it played.
                if repeatMode == .all {
                    currentIndex = 0
                    return .removedCurrent(next: self.current)
                }
                currentIndex = entries.count - 1
                return .removedCurrent(next: nil)
            }
            return .removedCurrent(next: self.current)
        }
        return .removedOther
    }

    /// Same semantics as SwiftUI's `onMove`: `destination` is an index in the
    /// array as it was before the move. The playing track stays playing.
    mutating func move(from source: Int, to destination: Int) {
        guard entries.indices.contains(source), destination >= 0, destination <= entries.count else { return }
        let playingID = current?.id
        let item = entries.remove(at: source)
        let target = destination > source ? destination - 1 : destination
        entries.insert(item, at: min(target, entries.count))
        if let playingID { currentIndex = entries.firstIndex { $0.id == playingID } }
        if !isShuffled { originalOrder = entries.map(\.id) }
    }

    /// Drops everything after the current track.
    mutating func clearUpNext() {
        guard let i = currentIndex else { return }
        let keep = Set(entries.prefix(i + 1).map(\.id))
        entries = Array(entries.prefix(i + 1))
        originalOrder.removeAll { !keep.contains($0) }
    }

    // MARK: Shuffle

    /// Turning shuffle on keeps the current track playing and shuffles the
    /// rest; turning it off restores the original order.
    mutating func setShuffle<G: RandomNumberGenerator>(_ on: Bool, using rng: inout G) {
        guard on != isShuffled else { return }
        let playing = current
        if on {
            var rest = entries
            if let playing, let index = rest.firstIndex(where: { $0.id == playing.id }) {
                rest.remove(at: index)
            }
            rest.shuffle(using: &rng)
            entries = (playing.map { [$0] } ?? []) + rest
            currentIndex = entries.isEmpty ? nil : 0
            isShuffled = true
        } else {
            let lookup = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            entries = originalOrder.compactMap { lookup[$0] }
            if let playing { currentIndex = entries.firstIndex { $0.id == playing.id } }
            isShuffled = false
        }
    }

    mutating func setShuffle(_ on: Bool) {
        var rng = SystemRandomNumberGenerator()
        setShuffle(on, using: &rng)
    }
}
