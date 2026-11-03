import Darwin
import Foundation

@MainActor
protocol TranscriptionWorkerRunning: AnyObject {
    func run(_ request: TranscriptionWorkerRequest,
             progress: @escaping @MainActor (TranscriptionWorkerProgress) -> Void) async throws
        -> TranscriptionWorkerResult
    func stop() async throws
}

@MainActor
final class TranscriptionWorkerProcess: TranscriptionWorkerRunning {
    private final class Invocation {
        let process: Process
        let request: TranscriptionWorkerRequest
        let output = Pipe()
        let diagnostics = Pipe()
        var buffer = Data()
        var stopped = false
        let progress: @MainActor (TranscriptionWorkerProgress) -> Void
        let continuation: CheckedContinuation<TranscriptionWorkerResult, Error>

        init(process: Process, request: TranscriptionWorkerRequest,
             progress: @escaping @MainActor (TranscriptionWorkerProgress) -> Void,
             continuation: CheckedContinuation<TranscriptionWorkerResult, Error>) {
            self.process = process
            self.request = request
            self.progress = progress
            self.continuation = continuation
        }
    }

    private let executableURL: URL?
    private var active: Invocation?

    init(executableURL: URL? = Bundle.main.url(forAuxiliaryExecutable: "NotyTranscriptionWorker")) {
        self.executableURL = executableURL
    }

    func run(_ request: TranscriptionWorkerRequest,
             progress: @escaping @MainActor (TranscriptionWorkerProgress) -> Void) async throws
        -> TranscriptionWorkerResult {
        guard active == nil else { throw TranscriptionError.invalidResult }
        guard let executableURL else { throw TranscriptionError.workerUnavailable }
        let requestURL = request.resultURL.deletingLastPathComponent()
            .appendingPathComponent("request-\(request.attemptID).json")
        try FileManager.default.createDirectory(at: requestURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = [requestURL.path]
            let invocation = Invocation(process: process, request: request, progress: progress,
                                        continuation: continuation)
            active = invocation
            process.standardOutput = invocation.output
            process.standardError = invocation.diagnostics
            invocation.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                guard !bytes.isEmpty else { return }
                Task { @MainActor in self?.receive(bytes, attempt: request.attemptID) }
            }
            invocation.diagnostics.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in self?.didExit(attempt: request.attemptID) }
            }
            do { try process.run() } catch {
                active = nil
                close(invocation)
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() async throws {
        guard let invocation = active else { return }
        invocation.stopped = true
        let process = invocation.process
        if process.isRunning {
            process.terminate()
        }
        let start = ContinuousClock.now
        var escalated = false
        while process.isRunning {
            let elapsed = start.duration(to: .now)
            if elapsed >= .seconds(1), !escalated {
                kill(process.processIdentifier, SIGKILL)
                escalated = true
            }
            guard elapsed < .seconds(2) else { throw TranscriptionError.workerDidNotStop }
            // Deliberately independent of the cancelled job's task.
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        didExit(attempt: invocation.request.attemptID)
    }

    private func receive(_ data: Data, attempt: UUID) {
        guard let invocation = active, invocation.request.attemptID == attempt, !invocation.stopped else { return }
        invocation.buffer.append(data)
        while let newline = invocation.buffer.firstIndex(of: 10) {
            let line = invocation.buffer[..<newline]
            if let progress = try? JSONDecoder().decode(TranscriptionWorkerProgress.self, from: Data(line)) {
                invocation.progress(progress)
            }
            invocation.buffer.removeSubrange(...newline)
        }
        if invocation.buffer.count > 65536 {
            invocation.buffer.removeAll()
        }
    }

    private func didExit(attempt: UUID) {
        guard let invocation = active, invocation.request.attemptID == attempt else { return }
        active = nil
        close(invocation)
        if invocation.stopped {
            invocation.continuation.resume(throwing: CancellationError())
            return
        }
        do {
            let result = try JSONDecoder().decode(TranscriptionWorkerResult.self,
                                                  from: Data(contentsOf: invocation.request.resultURL))
            guard result.jobID == invocation.request.jobID, result.attemptID == attempt else {
                throw TranscriptionError.invalidResult
            }
            if let error = result.error {
                throw TranscriptionError.workerFailed(error, needsRepair: result.needsModelRepair)
            }
            guard invocation.process.terminationStatus == 0 else { throw TranscriptionError.invalidResult }
            invocation.continuation.resume(returning: result)
        } catch {
            invocation.continuation.resume(throwing: error)
        }
    }

    private func close(_ invocation: Invocation) {
        invocation.output.fileHandleForReading.readabilityHandler = nil
        invocation.diagnostics.fileHandleForReading.readabilityHandler = nil
        try? invocation.output.fileHandleForReading.close()
        try? invocation.diagnostics.fileHandleForReading.close()
        try? invocation.output.fileHandleForWriting.close()
        try? invocation.diagnostics.fileHandleForWriting.close()
    }
}
