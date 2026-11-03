import Foundation

/// Error vocabulary used by the production runner, without importing the SwiftUI app.
enum TranscriptionError: Error {
    case workerUnavailable, invalidResult, workerDidNotStop
    case workerFailed(String, needsRepair: Bool)
}

@main
struct WorkerProcessChecks {
    @MainActor
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("worker")
        let script = """
        #!/bin/sh
        trap '' TERM
        echo '{"message":"ready"}'
        exec /bin/sleep 30
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let worker = TranscriptionWorkerProcess(executableURL: executable)
        let request = TranscriptionWorkerRequest(
            jobID: UUID(), attemptID: UUID(), phase: .validate, modelsURL: folder,
            resultURL: folder.appendingPathComponent("result.json"), parentPID: getpid()
        )
        var ready = false
        let running = Task {
            try await worker.run(request) { ready = $0.message == "ready" }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(ready, "Worker progress was not decoded")
        let start = ContinuousClock.now
        try await worker.stop()
        precondition(start.duration(to: .now) < .seconds(2), "Worker stop exceeded its deadline")
        do {
            _ = try await running.value
            preconditionFailure("Cancelled worker returned a result")
        } catch is CancellationError {}
        print("PASS: progress decoded; forced termination confirmed; cancelled result suppressed")
    }
}
