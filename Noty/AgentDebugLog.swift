// #region agent log
import Foundation

enum AgentDebugLog {
    private static let endpoint = URL(string: "http://127.0.0.1:7280/ingest/4d5a6762-c0fa-4c25-9fef-5f814c969a54")!
    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastEmit: [String: TimeInterval] = [:]

    static func log(_ location: String, _ message: String, hypothesis: String, _ data: [String: Any] = [:]) {
        let payload: [String: Any] = [
            "sessionId": "c4b906", "runId": "pre-fix", "hypothesisId": hypothesis, "location": location,
            "message": message, "data": data, "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        lock.lock()
        if let handle = fileHandle() {
            handle.seekToEndOfFile()
            handle.write(body + Data([0x0A]))
        }
        lock.unlock()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("c4b906", forHTTPHeaderField: "X-Debug-Session-Id")
        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()
    }

    private nonisolated(unsafe) static var handle: FileHandle?

    private static func fileHandle() -> FileHandle? {
        if let handle {
            return handle
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-debug-c4b906.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        return handle
    }

    /// Returns true at most once per `interval` for `key`.
    static func shouldEmit(_ key: String, interval: TimeInterval = 2) -> Bool {
        let now = Date().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        if let last = lastEmit[key], now - last < interval {
            return false
        }
        lastEmit[key] = now
        return true
    }

    static func rms(_ samples: [Float], channels: Int, channel: Int) -> Double {
        guard channels > 0, channel < channels else { return 0 }
        var sum = 0.0
        var count = 0
        var index = channel
        while index < samples.count {
            sum += Double(samples[index] * samples[index])
            count += 1
            index += channels
        }
        return count == 0 ? 0 : (sum / Double(count)).squareRoot()
    }
}

// #endregion
