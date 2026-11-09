import AVFAudio
import Combine
import Foundation

@MainActor
protocol AudioPlaybackPlaying: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: AudioPlaybackPlaying {}

@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var activeID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var issue: String?

    private let makePlayer: (URL) throws -> any AudioPlaybackPlaying
    private var player: (any AudioPlaybackPlaying)?
    private var lease: DestinationLease?
    private var progressTask: Task<Void, Never>?

    init(makePlayer: @escaping (URL) throws -> any AudioPlaybackPlaying = { try AVAudioPlayer(contentsOf: $0) }) {
        self.makePlayer = makePlayer
    }

    func toggle(id: UUID, source: () throws -> (url: URL, lease: DestinationLease)) {
        issue = nil
        if activeID == id, let player {
            if isPlaying {
                pause(player)
            } else {
                start(player)
            }
            return
        }

        stop()
        do {
            let access = try source()
            lease = access.lease
            let player = try makePlayer(access.url)
            guard player.duration.isFinite, player.duration > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.player = player
            activeID = id
            duration = player.duration
            start(player)
        } catch {
            stop()
            issue = "Could not play audio: \(error.localizedDescription)"
        }
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite, let player else { return }
        currentTime = min(max(time, 0), duration)
        player.currentTime = currentTime
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        lease?.close()
        lease = nil
        activeID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func refresh() {
        guard isPlaying, let player else { return }
        guard player.isPlaying else {
            stop()
            return
        }
        currentTime = min(max(player.currentTime, 0), duration)
    }

    private func start(_ player: any AudioPlaybackPlaying) {
        if player.currentTime >= duration {
            seek(to: 0)
        }
        guard player.play() else {
            stop()
            issue = "Could not start audio playback. Try again."
            return
        }
        isPlaying = true
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self else { return }
                refresh()
            }
        }
    }

    private func pause(_ player: any AudioPlaybackPlaying) {
        player.pause()
        isPlaying = false
        currentTime = player.currentTime
        progressTask?.cancel()
        progressTask = nil
    }

    deinit { progressTask?.cancel() }
}
