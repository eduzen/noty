import Foundation

protocol CaptureService: AnyObject {
    var packets: AsyncThrowingStream<CapturedAudioPacket, Error> { get }
    var terminations: AsyncStream<CaptureTermination> { get }
    func start() async throws
    func stop() async
}

enum CaptureTermination: Equatable, Sendable {
    case userStopped
    case screenRecordingDenied(RecordingIssue)
    case interrupted(RecordingIssue)
    case microphoneDisconnected(RecordingIssue)
    case unexpected(RecordingIssue)
    case queueOverflow(RecordingIssue)
}

enum CaptureServiceError: Error, Equatable, Sendable {
    case alreadyStarted
    case notStarted
    case screenRecordingDenied
    case noMainDisplay
    case microphoneUnavailable
    case invalidAudioFormat
    case queueOverflow
    case streamFailure(String)
}
