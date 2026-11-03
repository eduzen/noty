import Foundation

enum TranscriptionPhase: String, Codable, Sendable {
    case prepare, validate, transcribe, diarize
}

struct TranscriptWord: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

struct TranscriptSegment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var words: [TranscriptWord]
}

struct SpeakerInterval: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var speaker: Int
}

struct TranscriptionWorkerRequest: Codable, Sendable {
    var jobID: UUID
    var attemptID: UUID
    var phase: TranscriptionPhase
    var inputURL: URL?
    var modelsURL: URL
    var resultURL: URL
    var parentPID: Int32
}

struct TranscriptionWorkerResult: Codable, Sendable {
    var jobID: UUID
    var attemptID: UUID
    var segments: [TranscriptSegment] = []
    var speakers: [SpeakerInterval] = []
    var error: String?
    var needsModelRepair: Bool = false
}

struct TranscriptionWorkerProgress: Codable, Sendable {
    var fraction: Double?
    var message: String
}
