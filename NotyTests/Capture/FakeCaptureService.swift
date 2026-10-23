import Foundation
@testable import Noty

final class FakeCaptureService: CaptureService {
    let packets: AsyncThrowingStream<CapturedAudioPacket, Error>
    let terminations: AsyncStream<CaptureTermination>

    private let packetContinuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation
    private let terminationContinuation: AsyncStream<CaptureTermination>.Continuation
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var started = false
    private var terminal = false
    private var emittedPackets = 0
    private var failure: (index: Int, issue: RecordingIssue)?

    init() {
        let (packets, packetContinuation) = AsyncThrowingStream<CapturedAudioPacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(3))
        let (terminations, terminationContinuation) = AsyncStream<CaptureTermination>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.packets = packets
        self.packetContinuation = packetContinuation
        self.terminations = terminations
        self.terminationContinuation = terminationContinuation
    }

    func start() async throws {
        guard !started else { return }
        started = true
        startCount += 1
    }

    func stop() async {
        guard !terminal else { return }
        stopCount += 1
        terminal = true
        packetContinuation.finish()
        terminationContinuation.yield(.userStopped)
        terminationContinuation.finish()
    }

    func emit(_ packet: CapturedAudioPacket) {
        guard started, !terminal else { return }
        if let failure, failure.index == emittedPackets {
            fail(failure.issue)
            return
        }
        emittedPackets += 1
        if case .dropped = packetContinuation.yield(packet) {
            let issue = RecordingIssue(code: "capture.queue-overflow", message: "Audio capture exceeded its bounded buffer.", isRetryAllowed: false)
            terminal = true
            packetContinuation.finish(throwing: issue)
            terminationContinuation.yield(.queueOverflow(issue))
            terminationContinuation.finish()
        }
    }

    func fail(atPacket index: Int, with issue: RecordingIssue) {
        guard index >= 0, !terminal else { return }
        failure = (index, issue)
    }

    func fail(_ issue: RecordingIssue) {
        guard !terminal else { return }
        terminal = true
        packetContinuation.finish(throwing: issue)
        terminationContinuation.yield(.unexpected(issue))
        terminationContinuation.finish()
    }

    func finishNormally() {
        guard !terminal else { return }
        terminal = true
        packetContinuation.finish()
        terminationContinuation.yield(.userStopped)
        terminationContinuation.finish()
    }
}
