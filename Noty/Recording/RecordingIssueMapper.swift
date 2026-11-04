import Foundation
import OSLog

enum RecordingIssueMapper {
    private static let logger = Logger(subsystem: "com.eduzen.noty", category: "Recording")

    static func issue(from error: Error) -> RecordingIssue {
        let original: RecordingIssue
        if let issue = error as? RecordingIssue {
            original = issue
        } else if let error = error as? AudioPipelineError {
            original = audioIssue(for: error)
        } else if let error = error as? CaptureServiceError {
            original = captureIssue(for: error)
        } else {
            original = RecordingIssue(
                code: "recording.failed",
                message: error.localizedDescription,
                isRetryAllowed: true
            )
        }
        let message = userMessage(for: original)
        if message != original.message {
            logger.error("\(original.code, privacy: .public): \(original.message, privacy: .private)")
        }
        return RecordingIssue(code: original.code, message: message, recoveryURL: original.recoveryURL,
                              isRetryAllowed: original.isRetryAllowed)
    }

    private static func userMessage(for issue: RecordingIssue) -> String {
        switch issue.code {
        case "audio.queue-overflow", "capture.queue-overflow", "writer.overflow", "writer.backpressure":
            return "Recording stopped because Noty couldn’t process the audio fast enough. "
                + "Try closing busy apps before recording again."
        case "audio.malformed-packet", "audio.conversion-failed", "audio.timing-discontinuity":
            return "Recording stopped because Noty couldn’t process the audio. Try recording again."
        case "audio.unsupported-format", "capture.invalid-audio":
            return "Noty couldn’t use this audio device. "
                + "Choose another device in Sound settings and try again."
        case "capture.stream-failed", "capture.setup-failed", "capture.lifecycle-error":
            return "Noty couldn’t capture audio. "
                + "Check that your audio devices are connected and try recording again."
        case "permission.audio-input-entitlement-missing":
            return "This copy of Noty can’t use the microphone. Reinstall Noty and try again."
        case "destination-bookmark-refresh-failed":
            return "Noty couldn’t keep access to the recording folder. Choose the folder again."
        case "recovery.invalid":
            return "Noty couldn’t read part of the saved audio. "
                + "Other available audio is listed in Recovered recordings."
        case "media.invalid-format":
            return "Noty couldn’t confirm that this recording can be played. Any usable audio is listed below."
        case "recording.failed":
            return "Noty couldn’t complete the recording. "
                + "Check your audio devices and recording folder, then try again."
        default:
            if issue.code.hasPrefix("writer.") {
                return "Noty couldn’t save the recording. Check that the recording folder is available "
                    + "and your disk has free space, then try again."
            } else {
                return issue.message
            }
        }
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
            RecordingIssue(code: "capture.microphone-unavailable", message: "No microphone is available.",
                           isRetryAllowed: true)
        case let .selectedMicrophoneUnavailable(name):
            RecordingIssue(code: "capture.selected-microphone-unavailable",
                           message: CaptureServiceError.selectedMicrophoneMessage(name), isRetryAllowed: true)
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
