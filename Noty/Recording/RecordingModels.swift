import Foundation

enum RecordingState: String, Equatable, Sendable {
    case idle
    case starting
    case recording
    case paused
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

    func withRecordingURL(_ url: URL?) -> RecordingIssue {
        // Permission actions remain available even when audio was also recovered.
        if let recoveryURL, !recoveryURL.isFileURL {
            return self
        }
        return RecordingIssue(code: code, message: message, recoveryURL: url, isRetryAllowed: isRetryAllowed)
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
    let additionalURLs: [URL]
    let recoverySessionIdentifier: String?

    var fileURLs: [URL] {
        [url] + additionalURLs
    }

    var fileCountDescription: String {
        let count = additionalURLs.count + 1
        return count == 1 ? "1 audio file" : "\(count) audio files"
    }

    var recoveryIdentifier: String {
        if let recoverySessionIdentifier {
            return recoverySessionIdentifier
        }
        switch kind {
        case .recording: return url.path
        case .recovery: return url.deletingLastPathComponent().path
        }
    }

    var displayName: String {
        let name = url.deletingPathExtension().lastPathComponent
        if let range = name.range(of: "-recovery-") {
            return String(name[..<range.lowerBound])
        }
        return name.hasPrefix("segment-") || name.hasPrefix(".noty-") ? "Earlier recording" : name
    }

    init(url: URL, kind: Kind = .recording, duration: TimeInterval, additionalURLs: [URL] = [],
         recoverySessionIdentifier: String? = nil) {
        self.url = url
        self.kind = kind
        self.duration = duration
        self.additionalURLs = additionalURLs
        self.recoverySessionIdentifier = recoverySessionIdentifier
    }

    init?(recoveryParts: [(url: URL, duration: TimeInterval)]) {
        guard let first = recoveryParts.first else { return nil }
        self.init(url: first.url, kind: .recovery,
                  duration: recoveryParts.reduce(0) { $0 + $1.duration },
                  additionalURLs: recoveryParts.dropFirst().map(\.url))
    }
}

enum RecordingOutcome: Equatable, Sendable {
    case saved(RecordingArtifact)
    case partial(RecordingArtifact?, RecordingIssue)
    case failed(RecordingIssue)
}
