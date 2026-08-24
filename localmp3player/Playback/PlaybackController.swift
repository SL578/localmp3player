import AVFoundation
import Combine
import CoreData
import MediaPlayer
import UIKit

enum RepeatMode: String, CaseIterable {
    case off
    case all
    case one

    var systemImage: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var label: String {
        switch self {
        case .off: return "Repeat Off"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Owns the audio session, the queue, and the now-playing surface shared by the
/// phone UI, the lock screen, and CarPlay.
@MainActor
final class PlaybackController: NSObject, ObservableObject {
    static let shared = PlaybackController()

    @Published private(set) var currentSong: Song?
    @Published private(set) var isPlaying = false
    /// The queue in the order it will actually play (already shuffled if shuffle is on).
    @Published private(set) var queue: [Song] = []
    @Published private(set) var queueIndex: Int = 0
    @Published var currentTime: Double = 0
    /// Label for whatever the queue was built from, e.g. "Liked Songs".
    @Published private(set) var queueSourceName: String?
    @Published private(set) var isShuffled = false
    @Published private(set) var repeatMode: RepeatMode = .off

    /// The queue in its original browse order, kept so shuffle can be undone.
    private var orderedQueue: [Song] = []

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var context: NSManagedObjectContext { PersistenceController.shared.viewContext }

    private override init() {
        super.init()
        configureSession()
        configureRemoteCommands()
    }

    var duration: Double { player?.duration ?? currentSong?.duration ?? 0 }

    // MARK: - Queue control

    func play(songs: [Song], startingAt index: Int, sourceName: String? = nil) {
        guard !songs.isEmpty, songs.indices.contains(index) else { return }
        orderedQueue = songs
        queueSourceName = sourceName

        if isShuffled {
            // Keep the tapped song first so the tap still does what it looks like.
            let picked = songs[index]
            var rest = songs
            rest.remove(at: index)
            queue = [picked] + rest.shuffled()
            queueIndex = 0
        } else {
            queue = songs
            queueIndex = index
        }
        load(queue[queueIndex], autoPlay: true)
    }

    func play(song: Song, sourceName: String? = nil) {
        play(songs: [song], startingAt: 0, sourceName: sourceName)
    }

    /// Turns shuffle on and starts somewhere random — the "surprise me" entry point.
    func shufflePlay(songs: [Song], sourceName: String? = nil) {
        guard !songs.isEmpty else { return }
        isShuffled = true
        play(songs: songs, startingAt: Int.random(in: songs.indices), sourceName: sourceName)
    }

    /// Jumps straight to a queue position, used by the queue list.
    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        queueIndex = index
        load(queue[index], autoPlay: true)
    }

    // MARK: - Shuffle / repeat

    func toggleShuffle() {
        isShuffled.toggle()
        guard !queue.isEmpty else { return }
        let playing = currentSong

        if isShuffled {
            var rest = orderedQueue
            if let playing, let position = rest.firstIndex(of: playing) {
                rest.remove(at: position)
                queue = [playing] + rest.shuffled()
                queueIndex = 0
            } else {
                queue = rest.shuffled()
                queueIndex = 0
            }
        } else {
            queue = orderedQueue
            queueIndex = playing.flatMap { queue.firstIndex(of: $0) } ?? 0
        }
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTicker()
        } else {
            activateSession()
            player.play()
            isPlaying = true
            startTicker()
        }
        updateNowPlayingInfo()
    }

    /// User-initiated skip. Repeat-one deliberately does not trap the user here —
    /// pressing next always moves on.
    func next() {
        guard !queue.isEmpty else { return }
        if queueIndex + 1 < queue.count {
            queueIndex += 1
        } else if repeatMode != .off {
            queueIndex = 0
        } else {
            stop()
            return
        }
        load(queue[queueIndex], autoPlay: true)
    }

    func previous() {
        // Matches the platform convention: restart the track unless we're near the start.
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if queueIndex > 0 {
            queueIndex -= 1
        } else if repeatMode != .off, !queue.isEmpty {
            queueIndex = queue.count - 1
        } else {
            seek(to: 0)
            return
        }
        load(queue[queueIndex], autoPlay: true)
    }

    /// Natural end of a track — this is where repeat-one applies.
    fileprivate func handleTrackFinished() {
        guard let currentSong, repeatMode == .one else {
            next()
            return
        }
        load(currentSong, autoPlay: true)
    }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
        updateNowPlayingInfo()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentSong = nil
        queueSourceName = nil
        currentTime = 0
        orderedQueue = []
        queue = []
        queueIndex = 0
        stopTicker()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Called when a song is deleted out from under the queue.
    func forget(_ song: Song) {
        if currentSong?.id == song.id {
            stop()
            return
        }
        // Keep queueIndex pointing at the same song after the removal.
        let playing = currentSong
        queue.removeAll { $0.id == song.id }
        orderedQueue.removeAll { $0.id == song.id }
        queueIndex = playing.flatMap { queue.firstIndex(of: $0) } ?? 0
    }

    // MARK: - Loading

    private func load(_ song: Song, autoPlay: Bool) {
        let url = AudioFileStore.absoluteURL(for: song.filePath)
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
            // File is gone or unreadable — skip past it rather than stalling the queue.
            if queueIndex + 1 < queue.count {
                queueIndex += 1
                load(queue[queueIndex], autoPlay: autoPlay)
            } else {
                stop()
            }
            return
        }

        player?.stop()
        newPlayer.delegate = self
        newPlayer.prepareToPlay()
        player = newPlayer
        currentSong = song
        currentTime = 0

        if autoPlay {
            activateSession()
            newPlayer.play()
            isPlaying = true
            startTicker()
            recordPlay(of: song)
        }
        updateNowPlayingInfo()
    }

    private func recordPlay(of song: Song) {
        song.lastPlayed = Date()
        song.playCount += 1
        try? context.save()
    }

    // MARK: - Session

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Ticker

    private func startTicker() {
        stopTicker()
        // 1 Hz is enough for a progress bar and keeps the CPU mostly asleep.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // Bind strongly before hopping to the actor: a captured `weak var`
            // read inside the Task is an error under Swift 6.
            guard let self else { return }
            Task { @MainActor in
                guard let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - Now Playing / remote commands

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player, !player.isPlaying else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player, player.isPlaying else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .commandFailed }
            self.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .commandFailed }
            self.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let wantsShuffle = event.shuffleType != .off
            if self.isShuffled != wantsShuffle { self.toggleShuffle() }
            return .success
        }
        center.changeShuffleModeCommand.isEnabled = true
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            switch event.repeatType {
            case .off: self.repeatMode = .off
            case .one: self.repeatMode = .one
            case .all: self.repeatMode = .all
            @unknown default: self.repeatMode = .off
            }
            return .success
        }
        center.changeRepeatModeCommand.isEnabled = true
    }

    private func updateNowPlayingInfo() {
        guard let currentSong, let player else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentSong.title,
            MPMediaItemPropertyArtist: currentSong.artist,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0
        ]
        if let album = currentSong.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let data = currentSong.artworkData, let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension PlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.handleTrackFinished() }
    }
}
