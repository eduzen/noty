import Foundation

enum TranscriptionJobStatus: String, Codable, Sendable {
    case waiting, transcribing, identifyingSpeakers, complete, needsAttention, cancelled

    var title: String {
        switch self {
        case .waiting: "Waiting"
        case .transcribing: "Transcribing"
        case .identifyingSpeakers: "Identifying speakers"
        case .complete: "Complete"
        case .needsAttention: "Needs attention"
        case .cancelled: "Cancelled"
        }
    }

    var isRunning: Bool {
        self == .transcribing || self == .identifyingSpeakers
    }
}

struct TranscriptionSourceIdentity: Codable, Equatable, Sendable {
    var size: UInt64
    var modified: Date
    var fileNumber: UInt64?

    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modified = attributes[.modificationDate] as? Date ?? .distantPast
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

struct TranscriptionJob: Codable, Identifiable, Sendable {
    var id = UUID()
    var sourceURL: URL
    var folderBookmark: Data?
    var identity: TranscriptionSourceIdentity
    var duration: TimeInterval
    var status: TranscriptionJobStatus = .waiting
    var message: String?
    var requiresModelRepair = false
    var exportReservation: ExportReservation?
    var lastExport: ExportReservation?
    var pendingExportText: String?
    var pendingCompletionStatus: TranscriptionJobStatus?

    var displayName: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }

    var canRetry: Bool {
        status == .needsAttention || status == .cancelled
    }

    var canCancel: Bool {
        status == .waiting || status.isRunning
    }
}

struct TranscriptionSnapshot: Codable, Sendable {
    var version = 1
    var automaticEnabled = false
    var modelsReady = false
    var jobs: [TranscriptionJob] = []
}

enum TranscriptionModelState: Equatable {
    case notInstalled, preparing, ready, needsRepair
}

enum TranscriptionError: Error, LocalizedError {
    case workerUnavailable
    case workerFailed(String, needsRepair: Bool)
    case invalidResult
    case workerDidNotStop
    case sourceChanged
    case invalidQueue

    var errorDescription: String? {
        switch self {
        case .workerUnavailable: "The transcription worker is missing. Rebuild or reinstall Noty."
        case let .workerFailed(message, _): message
        case .invalidResult: "The transcription worker could not finish. Try again."
        case .workerDidNotStop: "Noty could not stop transcription. Try recording again."
        case .sourceChanged: "The audio file changed or is unavailable. Import it again."
        case .invalidQueue: "Noty could not read its saved transcription queue. The saved queue has been kept."
        }
    }
}
