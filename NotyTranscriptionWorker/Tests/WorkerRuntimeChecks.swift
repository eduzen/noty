import Darwin
import Foundation

@main
struct WorkerRuntimeChecks {
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--linger" {
            let status = await WorkerRuntime.execute(
                requestAt: URL(fileURLWithPath: CommandLine.arguments[2])
            ) { request in
                try FileHandle.standardOutput.write(contentsOf: Data("ready\n".utf8))
                try await Task.sleep(for: .seconds(30))
                return TranscriptionWorkerResult(jobID: request.jobID, attemptID: request.attemptID)
            }
            Darwin.exit(status)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = TranscriptionWorkerRequest(
            jobID: UUID(), attemptID: UUID(), phase: .validate,
            modelsURL: directory.appendingPathComponent("models"),
            resultURL: directory.appendingPathComponent("result.json"), parentPID: getppid()
        )
        let requestURL = directory.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL)
        let status = await WorkerRuntime.execute(requestAt: requestURL) { request in
            TranscriptionWorkerResult(jobID: request.jobID, attemptID: request.attemptID)
        }
        guard status == 0, FileManager.default.fileExists(atPath: request.resultURL.path) else {
            throw CheckFailure.failed("Successful operation did not publish its result")
        }
        let success = try JSONDecoder().decode(
            TranscriptionWorkerResult.self, from: Data(contentsOf: request.resultURL)
        )
        guard success.jobID == request.jobID, success.attemptID == request.attemptID else {
            throw CheckFailure.failed("Worker lost job or attempt identity")
        }
        let failedStatus = await WorkerRuntime.execute(requestAt: requestURL) { _ in
            throw WorkerFailure.modelNeedsRepair
        }
        let failure = try JSONDecoder().decode(
            TranscriptionWorkerResult.self, from: Data(contentsOf: request.resultURL)
        )
        guard failedStatus != 0, failure.needsModelRepair, failure.error != nil else {
            throw CheckFailure.failed("Missing models were not reported as repairable")
        }
        var orphanedRequest = request
        orphanedRequest.parentPID = -1
        try JSONEncoder().encode(orphanedRequest).write(to: requestURL)
        let orphanStatus = await WorkerRuntime.execute(requestAt: requestURL) { _ in
            throw CheckFailure.failed("Worker ran after its parent was gone")
        }
        guard orphanStatus != 0 else {
            throw CheckFailure.failed("Worker accepted a mismatched parent")
        }
        let models = directory.appendingPathComponent("models")
        let setID = UUID()
        let assetRoot = models.appendingPathComponent("sets").appendingPathComponent(setID.uuidString)
        for name in ["whisper", "tokenizer", "speakers"] {
            try FileManager.default.createDirectory(
                at: assetRoot.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }
        try JSONEncoder().encode(WorkerAssetManifest(setID: setID))
            .write(to: models.appendingPathComponent("current.json"))
        let assets = try WorkerAssetLocations.current(at: models)
        guard assets.root.path == assetRoot.path else {
            throw CheckFailure.failed("Complete assets did not resolve to the selected set")
        }
        try FileManager.default.removeItem(at: assets.tokenizer)
        do {
            _ = try WorkerAssetLocations.current(at: models)
            throw CheckFailure.failed("Incomplete assets were accepted")
        } catch WorkerFailure.modelNeedsRepair {}
        let replacementID = UUID()
        let replacement = try WorkerAssetLocations.beginPreparation(at: models, setID: replacementID)
        for folder in [replacement.whisper, replacement.tokenizer, replacement.speakers] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try replacement.publish(at: models, setID: replacementID)
        let published = try WorkerAssetLocations.current(at: models)
        guard published.root.lastPathComponent == replacementID.uuidString,
              !FileManager.default.fileExists(atPath: assetRoot.path)
        else { throw CheckFailure.failed("Asset publication lost selected assets or retained obsolete assets") }
        let progressURL = directory.appendingPathComponent("progress.ndjson")
        FileManager.default.createFile(atPath: progressURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: progressURL)
        let emitter = WorkerProgressEmitter(output: handle)
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            emitter.emit(fraction: Double(index) / 49, "progress")
        }
        try handle.close()
        let lines = try String(contentsOf: progressURL, encoding: .utf8).split(separator: "\n")
        guard lines.count == 50 else { throw CheckFailure.failed("Concurrent progress writes lost records") }
        for line in lines {
            _ = try JSONDecoder().decode(TranscriptionWorkerProgress.self, from: Data(line.utf8))
        }
        print("Worker runtime, atomic asset publication and concurrent NDJSON checks passed")
    }
}

private enum CheckFailure: Error {
    case failed(String)
}
