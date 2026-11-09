import Foundation
import Testing
@testable import DriveVerse

/// Deterministic generator so shuffle tests are repeatable.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func ids(_ entries: [QueueEntry]) -> [String] { entries.map(\.trackID) }

@Suite struct PlayQueueTests {
    private func queue(_ n: Int, startAt: Int = 0, repeatMode: RepeatMode = .off) -> PlayQueue {
        PlayQueue.make(trackIDs: (1...n).map { "t\($0)" }, startAt: startAt, repeatMode: repeatMode)
    }

    @Test func startsAtRequestedTrack() {
        let q = queue(5, startAt: 2)
        #expect(q.current?.trackID == "t3")
        #expect(ids(q.upNext) == ["t4", "t5"])
        #expect(ids(q.history) == ["t1", "t2"])
    }

    @Test func emptyQueueHasNothing() {
        let q = PlayQueue.make(trackIDs: [])
        #expect(q.current == nil)
        #expect(q.isEmpty)
        #expect(!q.hasNext)
    }

    @Test func finishingAdvancesThenStopsAtEnd() {
        var q = queue(2)
        #expect(q.advanceAfterFinish()?.trackID == "t2")
        #expect(q.advanceAfterFinish() == nil)
        #expect(q.current?.trackID == "t2")
    }

    @Test func repeatAllWraps() {
        var q = queue(2, startAt: 1, repeatMode: .all)
        #expect(q.advanceAfterFinish()?.trackID == "t1")
        #expect(q.currentIndex == 0)
    }

    @Test func repeatOneReplaysOnFinishButSkipMovesOn() {
        var q = queue(3, repeatMode: .one)
        #expect(q.advanceAfterFinish()?.trackID == "t1")
        #expect(q.skipForward()?.trackID == "t2")
    }

    @Test func previousAtStartStaysUnlessRepeatAll() {
        var q = queue(3)
        #expect(q.skipBackward()?.trackID == "t1")
        var r = queue(3, repeatMode: .all)
        #expect(r.skipBackward()?.trackID == "t3")
    }

    @Test func playNextInsertsAfterCurrentInOrder() {
        var q = queue(3)
        q.playNext(["a", "b"])
        #expect(ids(q.entries) == ["t1", "a", "b", "t2", "t3"])
        #expect(q.current?.trackID == "t1")
    }

    @Test func appendGoesToEnd() {
        var q = queue(2)
        q.append(["x"])
        #expect(ids(q.entries) == ["t1", "t2", "x"])
    }

    @Test func removingEarlierEntryKeepsCurrentPlaying() {
        var q = queue(4, startAt: 2)
        let first = q.entries[0].id
        #expect(q.remove(first) == .removedOther)
        #expect(q.current?.trackID == "t3")
    }

    @Test func removingCurrentReportsNextToPlay() {
        var q = queue(3, startAt: 1)
        let playing = q.current!.id
        let outcome = q.remove(playing)
        #expect(outcome == .removedCurrent(next: q.current))
        #expect(q.current?.trackID == "t3")
    }

    @Test func removingLastCurrentStops() {
        var q = queue(2, startAt: 1)
        let playing = q.current!.id
        #expect(q.remove(playing) == .removedCurrent(next: nil))
    }

    @Test func removingOnlyEntryEmptiesQueue() {
        var q = queue(1)
        let only = q.current!.id
        _ = q.remove(only)
        #expect(q.isEmpty)
        #expect(q.current == nil)
    }

    @Test func moveKeepsCurrentTrackPlaying() {
        var q = queue(4, startAt: 1)
        q.move(from: 3, to: 0)
        #expect(ids(q.entries) == ["t4", "t1", "t2", "t3"])
        #expect(q.current?.trackID == "t2")
    }

    @Test func moveDownUsesOnMoveSemantics() {
        var q = queue(4)
        q.move(from: 0, to: 3)
        #expect(ids(q.entries) == ["t2", "t3", "t1", "t4"])
    }

    @Test func shuffleKeepsCurrentFirstAndAllTracks() {
        var rng = SeededGenerator(seed: 7)
        var q = queue(10, startAt: 4)
        q.setShuffle(true, using: &rng)
        #expect(q.current?.trackID == "t5")
        #expect(q.currentIndex == 0)
        #expect(Set(ids(q.entries)) == Set((1...10).map { "t\($0)" }))
        #expect(q.count == 10)
    }

    @Test func shuffleChangesOrder() {
        var rng = SeededGenerator(seed: 3)
        var q = queue(20)
        q.setShuffle(true, using: &rng)
        #expect(ids(q.entries) != (1...20).map { "t\($0)" })
    }

    @Test func unshuffleRestoresOriginalOrderAndCurrent() {
        var rng = SeededGenerator(seed: 11)
        var q = queue(8, startAt: 2)
        q.setShuffle(true, using: &rng)
        _ = q.skipForward()
        let playing = q.current!.trackID
        q.setShuffle(false, using: &rng)
        #expect(ids(q.entries) == (1...8).map { "t\($0)" })
        #expect(q.current?.trackID == playing)
    }

    @Test func tracksAddedWhileShuffledSurviveUnshuffle() {
        var rng = SeededGenerator(seed: 5)
        var q = queue(4)
        q.setShuffle(true, using: &rng)
        q.append(["late"])
        q.setShuffle(false, using: &rng)
        #expect(ids(q.entries) == ["t1", "t2", "t3", "t4", "late"])
    }

    @Test func duplicatesAreIndependentEntries() {
        var q = PlayQueue.make(trackIDs: ["a", "a", "b"])
        let second = q.entries[1].id
        _ = q.jump(to: second)
        #expect(q.currentIndex == 1)
        #expect(q.current?.trackID == "a")
    }

    @Test func clearUpNextKeepsHistoryAndCurrent() {
        var q = queue(5, startAt: 2)
        q.clearUpNext()
        #expect(ids(q.entries) == ["t1", "t2", "t3"])
        #expect(q.upNext.isEmpty)
    }

    @Test func queueRoundTripsThroughJSON() throws {
        var rng = SeededGenerator(seed: 1)
        var q = queue(5, startAt: 1, repeatMode: .all)
        q.setShuffle(true, using: &rng)
        let data = try JSONEncoder().encode(q)
        let back = try JSONDecoder().decode(PlayQueue.self, from: data)
        #expect(back == q)
    }

    @Test func repeatModeCycles() {
        #expect(RepeatMode.off.next == .all)
        #expect(RepeatMode.all.next == .one)
        #expect(RepeatMode.one.next == .off)
    }
}

@Suite struct SleepTimerTests {
    @Test func timedTimerExpires() {
        var timer = SleepTimer()
        let start = Date(timeIntervalSince1970: 1_000)
        timer.start(minutes: 10, now: start)
        #expect(timer.isActive)
        #expect(!timer.isExpired(now: start.addingTimeInterval(599)))
        #expect(timer.isExpired(now: start.addingTimeInterval(600)))
        #expect(timer.remaining(now: start.addingTimeInterval(300)) == 300)
    }

    @Test func endOfTrackModeDoesNotExpireByClock() {
        var timer = SleepTimer()
        timer.stopAtEndOfTrack()
        #expect(timer.stopsAtEndOfTrack)
        #expect(!timer.isExpired(now: Date.distantFuture))
    }

    @Test func cancelAndZeroMinutesTurnItOff() {
        var timer = SleepTimer()
        timer.start(minutes: 5)
        timer.cancel()
        #expect(!timer.isActive)
        timer.start(minutes: 0)
        #expect(!timer.isActive)
    }
}
