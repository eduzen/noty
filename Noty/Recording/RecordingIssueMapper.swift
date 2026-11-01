import Foundation

enum RecordingIssueMapper {
    static func issue(from error: Error) -> RecordingIssue {
        if let issue = error as? RecordingIssue {
            return issue
        }
        if let error = error as? AudioPipelineError {
            return audioIssue(for: error)
        }
        if let error = error as? CaptureServiceError {
            return captureIssue(for: error)
        }
        return RecordingIssue(code: "recording.failed", message: error.localizedDescription, isRetryAllowed: true)
    }

    private static func audioIssue(for error: AudioPipelineError) -> RecordingIssue {
        switch error {
        case let .malformedPacket(message):
            RecordingIssue(code: "audio.malformed-packet", message: message, isRetryAllowed: true)
        case let .unsupportedFormat(message):
            RecordingIssue(code: "audio.unsupported-format", message: message, isRetryAllowed: true)
        case let .conversionFailed(message):
            RecordingIssue(code: "audio.conversion-failed", message: message, isRetryAllowed: true)
        case let .timingDiscontinuity(message):
            RecordingIssue(code: "audio.timing-discontinuity", message: message, isRetryAllowed: false)
        case .queueOverflow:
            RecordingIssue(
                code: "audio.queue-overflow",
                message: "Audio processing exceeded its bounded buffer.",
                isRetryAllowed: false
            )
        }
    }

    private static func captureIssue(for error: CaptureServiceError) -> RecordingIssue {
        switch error {
        case .systemAudioDenied:
            RecordingIssue(
                code: "capture.system-audio-denied",
                message: "Allow Noty under System Audio Recording Only, then try again.",
                recoveryURL: CaptureSettingsLinks.systemAudio,
                isRetryAllowed: true
            )
        case .microphoneUnavailable:
            RecordingIssue(code: "capture.microphone-unavailable", message: "No default microphone is available.",
                           isRetryAllowed: true)
        case .invalidAudioFormat:
            RecordingIssue(
                code: "capture.invalid-audio",
                message: "Audio capture returned an unsupported audio format.",
                isRetryAllowed: false
            )
        case .queueOverflow:
            RecordingIssue(
                code: "capture.queue-overflow",
                message: "Audio capture exceeded its bounded buffer.",
                isRetryAllowed: false
            )
        case let .streamFailure(message):
            RecordingIssue(code: "capture.stream-failed", message: message, isRetryAllowed: true)
        case .alreadyStarted, .notStarted:
            RecordingIssue(code: "capture.lifecycle-error", message: error.localizedDescription, isRetryAllowed: true)
        }
    }
}
