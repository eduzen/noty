import Darwin
import Foundation

enum WorkerFailure: Error, LocalizedError {
    case modelNeedsRepair
    case invalidRequest
    case parentEnded
    case missingInput

    var errorDescription: String? {
        switch self {
        case .modelNeedsRepair: "The transcription models need repair. Download them again in Noty."
        case .invalidRequest: "The transcription request is invalid."
        case .parentEnded: "The app closed before transcription could finish."
        case .missingInput: "The staged recording could not be opened."
        }
    }
}

enum WorkerRuntime {
    static func execute(
        requestAt requestURL: URL,
        operation: @Sendable (TranscriptionWorkerRequest) async throws -> TranscriptionWorkerResult
    ) async -> Int32 {
        let request: TranscriptionWorkerRequest
        do {
            request = try JSONDecoder().decode(
                TranscriptionWorkerRequest.self, from: Data(contentsOf: requestURL)
            )
            guard request.modelsURL.isFileURL, request.resultURL.isFileURL,
                  request.inputURL?.isFileURL != false
            else { throw WorkerFailure.invalidRequest }
        } catch {
            diagnostic(error.localizedDescription)
            return EX_USAGE
        }
        do {
            let watchdog = try ParentWatchdog(expectedPID: request.parentPID)
            defer { watchdog.cancel() }
            var result = try await operation(request)
            try watchdog.check()
            result.jobID = request.jobID
            result.attemptID = request.attemptID
            try publish(result, to: request.resultURL)
            return result.error == nil ? EXIT_SUCCESS : EXIT_FAILURE
        } catch {
            let result = TranscriptionWorkerResult(
                jobID: request.jobID, attemptID: request.attemptID,
                error: error.localizedDescription,
                needsModelRepair: (error as? WorkerFailure) == .modelNeedsRepair
            )
            do {
                try publish(result, to: request.resultURL)
            } catch {
                diagnostic("Could not save the transcription result: \(error.localizedDescription)")
            }
            diagnostic(error.localizedDescription)
            return EXIT_FAILURE
        }
    }

    private static func publish(_ result: TranscriptionWorkerResult, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(result).write(to: url, options: .atomic)
    }

    static func diagnostic(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8))
    }
}

/// A separate dispatch queue remains responsive while an SDK is running CPU work.
/// Checking getppid also catches reparenting/PID reuse and the race before the timer starts.
private final class ParentWatchdog {
    private let expectedPID: Int32
    private let timer: DispatchSourceTimer

    init(expectedPID: Int32) throws {
        guard expectedPID > 1, getppid() == expectedPID else { throw WorkerFailure.parentEnded }
        self.expectedPID = expectedPID
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler {
            if expectedPID <= 1 || getppid() != expectedPID {
                Darwin._exit(EX_TEMPFAIL)
            }
        }
        timer.resume()
    }

    func check() throws {
        guard expectedPID > 1, getppid() == expectedPID else { throw WorkerFailure.parentEnded }
    }

    func cancel() {
        timer.cancel()
    }
}

/// SDK callbacks may arrive concurrently. Each write must remain one JSON record.
final class WorkerProgressEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private let output: FileHandle

    init(output: FileHandle = .standardOutput) {
        self.output = output
    }

    func emit(fraction: Double? = nil, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let progress = TranscriptionWorkerProgress(
            fraction: fraction.map { min(1, max(0, $0)) }, message: message
        )
        guard var data = try? JSONEncoder().encode(progress) else { return }
        data.append(0x0A)
        try? output.write(contentsOf: data)
    }
}
