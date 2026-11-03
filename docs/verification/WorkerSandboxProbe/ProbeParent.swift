import Darwin
import Foundation

@main
struct ProbeParent {
    static func main() throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotyWorkerProbe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = TranscriptionWorkerRequest(
            jobID: UUID(), attemptID: UUID(), phase: .validate,
            modelsURL: directory.appendingPathComponent("models"),
            resultURL: directory.appendingPathComponent("result.json"), parentPID: getpid()
        )
        let requestURL = directory.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL)
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NotyTranscriptionWorker")
        process.arguments = [requestURL.path]
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard !process.isRunning else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw NSError(domain: "WorkerProbe", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Worker did not exit within ten seconds"])
        }
        process.waitUntilExit()
        let result = try JSONDecoder().decode(TranscriptionWorkerResult.self, from: Data(contentsOf: request.resultURL))
        guard process.terminationStatus == 1, result.jobID == request.jobID,
              result.attemptID == request.attemptID, result.needsModelRepair else {
            throw NSError(domain: "WorkerProbe", code: 1)
        }
        print("Production sandbox parent/child launch, container access, result identity and repair response passed")
    }
}
