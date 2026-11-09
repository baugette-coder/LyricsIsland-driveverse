import Foundation

/// Sleep timer state. The player owns one and asks it when to stop.
struct SleepTimer: Equatable {
    enum Mode: Equatable {
        case off
        case until(Date)
        case endOfTrack
    }

    private(set) var mode: Mode = .off

    mutating func start(minutes: Int, now: Date = Date()) {
        mode = minutes > 0 ? .until(now.addingTimeInterval(Double(minutes) * 60)) : .off
    }

    mutating func stopAtEndOfTrack() { mode = .endOfTrack }
    mutating func cancel() { mode = .off }

    var isActive: Bool { mode != .off }

    /// True when playback should stop now (timed mode only).
    func isExpired(now: Date = Date()) -> Bool {
        if case .until(let deadline) = mode { return now >= deadline }
        return false
    }

    /// Seconds left in timed mode, else nil.
    func remaining(now: Date = Date()) -> TimeInterval? {
        if case .until(let deadline) = mode { return max(0, deadline.timeIntervalSince(now)) }
        return nil
    }

    var stopsAtEndOfTrack: Bool { mode == .endOfTrack }
}
