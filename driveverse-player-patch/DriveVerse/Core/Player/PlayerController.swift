#if os(iOS)
import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit

/// Position and duration live in their own object so only the scrubber
/// redraws twice a second, not every screen that watches the player.
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
}

/// DriveVerse's own music player: plays files from the library, owns the
/// queue, talks to the lock screen / car controls, and feeds the lyrics
/// pipeline through `statePublisher`.
@MainActor
final class PlayerController: ObservableObject {
    static let shared = PlayerController()

    @Published private(set) var queue = PlayQueue()
    @Published private(set) var currentTrack: LibraryTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: UIImage?
    @Published private(set) var rate: Float = 1
    @Published private(set) var sleepTimer = SleepTimer()
    @Published var message: String?

    let clock = PlaybackClock()
    /// Called with true when audio starts using a car (CarPlay) output.
    var onCarAudioChange: (@MainActor (Bool) -> Void)?

    var statePublisher: AnyPublisher<NowPlayingState?, Never> { stateSubject.eraseToAnyPublisher() }

    private let library = LibraryModel.shared
    private let player = AVPlayer()
    private let stateSubject = CurrentValueSubject<NowPlayingState?, Never>(nil)

    private var started = false
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var artworkTask: Task<Void, Never>?
    private var thumbnailData: Data?
    private var displayData: Data?
    private var lastEmittedSecond = -1
    private var lastSaved = Date.distantPast
    private var wasCarRoute = false

    private init() {}

    // MARK: Startup

    func start() {
        guard !started else { return }
        started = true
        player.automaticallyWaitsToMinimizeStalling = false
        configureSession()
        installRemoteCommands()
        observeSystem()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor [weak self] in self?.tick(seconds) }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor [weak self] in self?.playbackStatusChanged(playing) }
        }
        wasCarRoute = Self.isCarAudioRoute()
        restoreSession()
    }

    private func restoreSession() {
        guard let session = JSONStore.load(PlayerSession.self, from: LibraryPaths.sessionFile) else { return }
        queue = session.queue
        rate = session.rate > 0 ? session.rate : 1
        // Drop entries whose files have gone.
        for entry in queue.entries where library.index.track(entry.trackID) == nil {
            queue.remove(entry.id)
        }
        guard queue.current != nil else { return }
        loadCurrent(autoplay: false, startAt: session.positionSec)
    }

    // MARK: Starting playback

    /// Replaces the queue and starts playing. Keeps the current shuffle and
    /// repeat settings unless told otherwise.
    func play(trackIDs: [String], startAt: Int = 0, shuffle: Bool? = nil) {
        guard !trackIDs.isEmpty else { return }
        queue = PlayQueue.make(
            trackIDs: trackIDs,
            startAt: startAt,
            shuffle: shuffle ?? queue.isShuffled,
            repeatMode: queue.repeatMode
        )
        loadCurrent(autoplay: true)
    }

    func shuffleAll() {
        play(trackIDs: library.index.tracks.map(\.id), startAt: 0, shuffle: true)
    }

    func playNext(_ trackIDs: [String]) {
        queue.playNext(trackIDs)
        if currentTrack == nil { loadCurrent(autoplay: false) }
        saveSession()
    }

    func addToQueue(_ trackIDs: [String]) {
        queue.append(trackIDs)
        if currentTrack == nil { loadCurrent(autoplay: false) }
        saveSession()
    }

    func jump(to entryID: UUID) {
        guard queue.jump(to: entryID) != nil else { return }
        loadCurrent(autoplay: true)
    }

    func removeFromQueue(_ entryID: UUID) {
        switch queue.remove(entryID) {
        case .removedCurrent(let next):
            if next != nil { loadCurrent(autoplay: isPlaying) } else { unload() }
        case .removedOther, .notFound:
            break
        }
        saveSession()
    }

    func moveInQueue(from source: Int, to destination: Int) {
        queue.move(from: source, to: destination)
        saveSession()
    }

    func clearUpNext() {
        queue.clearUpNext()
        saveSession()
    }

    // MARK: Transport

    func togglePlayPause() {
        if currentTrack == nil {
            if queue.current != nil { loadCurrent(autoplay: true) }
            return
        }
        isPlaying ? pause() : play()
    }

    func play() {
        guard currentTrack != nil else { return }
        activateSession()
        if clock.duration > 0, clock.position >= clock.duration - 0.2 { seek(to: 0) }
        player.defaultRate = rate
        player.rate = rate
        checkCarRoute()
    }

    func pause() {
        player.pause()
        saveSession()
    }

    func skipForward() {
        guard queue.skipForward() != nil else { return }
        loadCurrent(autoplay: true)
    }

    /// Restarts the track if it has been playing for a few seconds, like a
    /// CD player; otherwise goes to the previous track.
    func skipBackward() {
        if clock.position > 3 || queue.currentIndex == nil {
            seek(to: 0)
            return
        }
        guard queue.skipBackward() != nil else { return }
        loadCurrent(autoplay: true)
    }

    func seek(to seconds: Double) {
        let limit = clock.duration > 0 ? clock.duration : max(seconds, 0)
        let target = max(0, min(seconds, limit))
        clock.position = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitState(force: true)
                self?.updateNowPlayingInfo()
            }
        }
    }

    func seek(toFraction fraction: Double) {
        guard clock.duration > 0 else { return }
        seek(to: min(1, max(0, fraction)) * clock.duration)
    }

    func seek(bySeconds offset: Double) { seek(to: clock.position + offset) }

    func setRate(_ newRate: Float) {
        rate = min(2.5, max(0.5, newRate))
        player.defaultRate = rate
        if isPlaying { player.rate = rate }
        updateNowPlayingInfo()
        emitState(force: true)
        saveSession()
    }

    func toggleShuffle() {
        queue.setShuffle(!queue.isShuffled)
        updateRemoteModes()
        saveSession()
    }

    func setRepeat(_ mode: RepeatMode) {
        queue.repeatMode = mode
        updateRemoteModes()
        saveSession()
    }

    func cycleRepeat() { setRepeat(queue.repeatMode.next) }

    // MARK: Sleep timer

    func startSleepTimer(minutes: Int) { sleepTimer.start(minutes: minutes) }
    func sleepAtEndOfTrack() { sleepTimer.stopAtEndOfTrack() }
    func cancelSleepTimer() { sleepTimer.cancel() }

    // MARK: Loading tracks

    private func loadCurrent(autoplay: Bool, startAt: Double = 0, attempts: Int = 0) {
        guard let entry = queue.current else { unload(); return }
        guard let track = library.index.track(entry.trackID),
              FileManager.default.fileExists(atPath: LibraryPaths.url(forTrackPath: track.path).path)
        else {
            // The file is gone. Drop it and move on, but never loop forever.
            if attempts < 20, case .removedCurrent(let next) = queue.remove(entry.id), next != nil {
                loadCurrent(autoplay: autoplay, attempts: attempts + 1)
            } else {
                unload()
            }
            return
        }

        let url = LibraryPaths.url(forTrackPath: track.path)
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        observe(item: item)
        player.replaceCurrentItem(with: item)

        currentTrack = track
        clock.duration = Double(track.durationMs) / 1000
        clock.position = startAt
        lastEmittedSecond = -1
        if startAt > 0 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        loadArtwork(for: track, url: url)

        if autoplay {
            activateSession()
            player.defaultRate = rate
            player.rate = rate
            checkCarRoute()
        } else {
            player.pause()
        }
        updateNowPlayingInfo()
        updateRemoteModes()
        emitState(force: true)
        saveSession()
    }

    private func unload() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTrack = nil
        artwork = nil
        thumbnailData = nil
        displayData = nil
        clock.position = 0
        clock.duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        stateSubject.send(nil)
        saveSession()
    }

    private func observe(item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.itemFinished() }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in self?.itemFailed() }
        }
    }

    private func itemFinished() {
        if sleepTimer.stopsAtEndOfTrack {
            sleepTimer.cancel()
            // Line up the next track but leave it paused.
            if queue.advanceAfterFinish() != nil { loadCurrent(autoplay: false) } else { rewindAndPause() }
            message = "Sleep timer: stopped after the track."
            return
        }
        if queue.advanceAfterFinish() != nil {
            loadCurrent(autoplay: true)
        } else {
            rewindAndPause()
        }
    }

    private func rewindAndPause() {
        player.pause()
        seek(to: 0)
        saveSession()
    }

    private func itemFailed() {
        let name = currentTrack?.title ?? "this file"
        message = "Couldn’t play “\(name)”. Skipping."
        if queue.skipForward() != nil { loadCurrent(autoplay: true) } else { unload() }
    }

    private func loadArtwork(for track: LibraryTrack, url: URL) {
        artworkTask?.cancel()
        artwork = nil
        thumbnailData = nil
        displayData = nil
        artworkTask = Task { [weak self] in
            let data = await TrackMetadataReader.artworkData(url: url)
            guard !Task.isCancelled, let self else { return }
            guard self.currentTrack?.path == track.path else { return }
            if let data {
                self.artwork = ArtworkTools.displayImage(from: data, side: 640)
                self.thumbnailData = ArtworkTools.compactThumbnail(from: data)
                self.displayData = self.artwork?.jpegData(compressionQuality: 0.82)
            }
            self.updateNowPlayingInfo()
            self.emitState(force: true)
        }
    }

    // MARK: Ticking and state

    private func playbackStatusChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        updateNowPlayingInfo()
        emitState(force: true)
        if !playing { saveSession() }
    }

    private func tick(_ seconds: Double) {
        guard currentTrack != nil, seconds.isFinite else { return }
        clock.position = max(0, seconds)
        if clock.duration <= 0,
           let item = player.currentItem {
            let total = CMTimeGetSeconds(item.duration)
            if total.isFinite, total > 0 { clock.duration = total }
        }
        if isPlaying, sleepTimer.isExpired() {
            sleepTimer.cancel()
            pause()
            message = "Sleep timer: playback stopped."
        }
        // The lyrics engine extrapolates at 1x between updates, so at other
        // speeds it needs a fresh position every tick.
        let second = Int(seconds)
        if second != lastEmittedSecond || rate != 1 {
            emitState(force: false)
        }
        if isPlaying, Date().timeIntervalSince(lastSaved) > 15 { saveSession() }
    }

    private func emitState(force: Bool) {
        guard let track = currentTrack else { stateSubject.send(nil); return }
        lastEmittedSecond = Int(clock.position)
        let state = NowPlayingState(
            title: track.title,
            artist: track.hasKnownArtist ? track.artist : "",
            album: track.hasKnownAlbum ? track.album : nil,
            artworkData: thumbnailData,
            displayArtworkData: displayData,
            durationMs: clock.duration > 0 ? Int(clock.duration * 1000) : nil,
            positionMs: Int(clock.position * 1000),
            isPlaying: isPlaying,
            capturedAt: Date(),
            fileStem: track.fileStem,
            fileFolder: track.folder
        )
        stateSubject.send(state)
    }

    // MARK: Lock screen and car controls

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: clock.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if track.hasKnownArtist { info[MPMediaItemPropertyArtist] = track.artist }
        if track.hasKnownAlbum { info[MPMediaItemPropertyAlbumTitle] = track.album }
        if let image = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            command.addTarget { _ in
                Task { @MainActor in action() }
                return .success
            }
        }
        handle(center.playCommand) { [weak self] in self?.play() }
        handle(center.pauseCommand) { [weak self] in self?.pause() }
        handle(center.togglePlayPauseCommand) { [weak self] in self?.togglePlayPause() }
        handle(center.nextTrackCommand) { [weak self] in self?.skipForward() }
        handle(center.previousTrackCommand) { [weak self] in self?.skipBackward() }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in PlayerController.shared.seek(to: position) }
            return .success
        }

        center.changeShuffleModeCommand.isEnabled = true
        center.changeShuffleModeCommand.addTarget { event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let on = event.shuffleType != .off
            Task { @MainActor in
                let player = PlayerController.shared
                if player.queue.isShuffled != on { player.toggleShuffle() }
            }
            return .success
        }

        center.changeRepeatModeCommand.isEnabled = true
        center.changeRepeatModeCommand.addTarget { event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode
            switch event.repeatType {
            case .off: mode = .off
            case .one: mode = .one
            default: mode = .all
            }
            Task { @MainActor in PlayerController.shared.setRepeat(mode) }
            return .success
        }

        center.changePlaybackRateCommand.isEnabled = true
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1.0, 1.25, 1.5, 2.0]
        center.changePlaybackRateCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let value = event.playbackRate
            Task { @MainActor in PlayerController.shared.setRate(value) }
            return .success
        }
    }

    private func updateRemoteModes() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = queue.isShuffled ? .items : .off
        switch queue.repeatMode {
        case .off: center.changeRepeatModeCommand.currentRepeatType = .off
        case .one: center.changeRepeatModeCommand.currentRepeatType = .one
        case .all: center.changeRepeatModeCommand.currentRepeatType = .all
        }
    }

    // MARK: Audio session

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            let typeValue = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionValue = info?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in self?.handleInterruption(typeValue, optionValue) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in self?.handleRouteChange(reasonValue) }
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.saveSession() }
        }
    }

    private func handleInterruption(_ typeValue: UInt?, _ optionValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            break // timeControlStatus observation updates the UI
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionValue ?? 0)
            if options.contains(.shouldResume) { play() }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ reasonValue: UInt?) {
        if let reasonValue, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
           reason == .oldDeviceUnavailable, isPlaying {
            pause()
        }
        checkCarRoute()
    }

    static func isCarAudioRoute() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    private func checkCarRoute() {
        let now = Self.isCarAudioRoute()
        guard now != wasCarRoute else { return }
        wasCarRoute = now
        onCarAudioChange?(now)
    }

    // MARK: Saving

    func saveSession() {
        lastSaved = Date()
        let session = PlayerSession(queue: queue, positionSec: clock.position, rate: rate)
        JSONStore.save(session, to: LibraryPaths.sessionFile)
    }
}
#endif
