import Foundation

enum RecordingState: String, Equatable, Sendable {
    case idle
    case starting
    case recording
    case stopping
    case interrupted
    case failed
}

struct RecordingIssue: Error, Equatable, Sendable, LocalizedError {
    let code: String
    let message: String
    let recoveryURL: URL?
    let isRetryAllowed: Bool

    init(code: String, message: String, recoveryURL: URL? = nil, isRetryAllowed: Bool = false) {
        self.code = code
        self.message = message
        self.recoveryURL = recoveryURL
        self.isRetryAllowed = isRetryAllowed
    }

    var errorDescription: String? {
        message
    }
}

struct RecordingArtifact: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case recording
        case recovery
    }

    let url: URL
    let kind: Kind
    let duration: TimeInterval

    init(url: URL, kind: Kind = .recording, duration: TimeInterval) {
        self.url = url
        self.kind = kind
        self.duration = duration
    }
}

enum RecordingOutcome: Equatable, Sendable {
    case saved(RecordingArtifact)
    case partial(RecordingArtifact?, RecordingIssue)
    case failed(RecordingIssue)
}
