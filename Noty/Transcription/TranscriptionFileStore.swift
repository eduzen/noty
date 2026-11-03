import CryptoKit
import Darwin
import Foundation

struct ExportReservation: Codable, Equatable, Sendable {
    var url: URL
    var digest: String
}

struct TranscriptionFileStore: Sendable {
    let rootURL: URL

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noty/Transcription", isDirectory: true)
    }

    init(rootURL: URL = Self.defaultRoot) {
        self.rootURL = rootURL
    }

    var modelsURL: URL {
        rootURL.appendingPathComponent("Models", isDirectory: true)
    }

    var jobsURL: URL {
        rootURL.appendingPathComponent("Jobs", isDirectory: true)
    }

    func jobDirectory(id: UUID) -> URL {
        jobsURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func stagedURL(jobID: UUID) -> URL {
        jobDirectory(id: jobID).appendingPathComponent("input.m4a")
    }

    func stage(source: URL, jobID: UUID) throws -> URL {
        let destination = stagedURL(jobID: jobID)
        if FileManager.default.fileExists(atPath: destination.path) {
            try validateStagedFile(destination)
            return destination
        }
        guard source.isFileURL,
              try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw StoreError.invalidSource
        }
        try createDirectory(jobDirectory(id: jobID))
        let temporary = jobDirectory(id: jobID).appendingPathComponent(".copy-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        if renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            let failure = errno
            guard failure == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
            // A paused attempt may finish copying while its replacement stages the same immutable job.
            // Reuse the committed copy rather than failing or replacing it.
            try validateStagedFile(destination)
        }
        return destination
    }

    func load<Value: Decodable>(_ type: Value.Type) throws -> Value? {
        try read(type, from: rootURL.appendingPathComponent("queue.json"))
    }

    func save(_ value: some Encodable) throws {
        try createDirectory(rootURL)
        try JSONEncoder().encode(value).write(to: rootURL.appendingPathComponent("queue.json"), options: .atomic)
    }

    func writeCheckpoint(segments: [TranscriptSegment], jobID: UUID) throws {
        try createDirectory(jobDirectory(id: jobID))
        try JSONEncoder().encode(segments).write(to: checkpointURL(jobID), options: .atomic)
    }

    func readCheckpoint(jobID: UUID) throws -> [TranscriptSegment]? {
        try read([TranscriptSegment].self, from: checkpointURL(jobID))
    }

    func removeStaging(jobID: UUID) throws {
        let url = stagedURL(jobID: jobID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func removeJob(jobID: UUID) throws {
        let url = jobDirectory(id: jobID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func reserveExport(sourceURL: URL, text: String, previous: ExportReservation?) throws -> ExportReservation {
        let digest = Self.digest(Data(text.utf8))
        if let previous, previous.url.deletingLastPathComponent() == sourceURL.deletingLastPathComponent(),
           !FileManager.default.fileExists(atPath: previous.url.path) || (try? fileDigest(previous.url)) == digest {
            return ExportReservation(url: previous.url, digest: digest)
        }
        let base = sourceURL.deletingPathExtension()
        for suffix in 1 ... 10000 {
            let url = suffix == 1 ? base.appendingPathExtension("txt") :
                base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) (\(suffix)).txt")
            if !FileManager.default.fileExists(atPath: url.path) {
                return ExportReservation(url: url, digest: digest)
            }
        }
        throw StoreError.noAvailableFilename
    }

    func publish(text: String, reservation: ExportReservation) throws {
        let data = Data(text.utf8)
        guard Self.digest(data) == reservation.digest else { throw StoreError.invalidReservation }
        let url = reservation.url
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists, try fileDigest(url) == reservation.digest {
            return
        }
        guard !exists else { throw StoreError.exportChanged }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".noty-transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        // Every publication is exclusive, including retries of Noty's own exports. A digest check
        // cannot authorize replacement because a concurrent editor could change the file afterward.
        guard renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST {
                throw StoreError.exportChanged
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func checkpointURL(_ jobID: UUID) -> URL {
        jobDirectory(id: jobID).appendingPathComponent("transcript.json")
    }

    private func validateStagedFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw StoreError.invalidStaging }
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func fileDigest(_ url: URL) throws -> String {
        guard try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw StoreError.exportChanged
        }
        return try Self.digest(Data(contentsOf: url))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum StoreError: LocalizedError {
        case invalidSource, invalidStaging, invalidReservation, exportChanged, noAvailableFilename

        var errorDescription: String? {
            switch self {
            case .invalidSource: "The audio file is unavailable or cannot be copied. Import it again."
            case .invalidStaging: "Noty's staged audio is unavailable. Cancel this job and import the audio again."
            case .invalidReservation: "The transcript changed before it could be saved. Retry transcription."
            case .exportChanged: "A file at the transcript destination changed. Retry to save with another filename."
            case .noAvailableFilename: "Noty could not find an available transcript filename in this folder."
            }
        }
    }
}
