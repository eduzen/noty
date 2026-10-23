import Foundation

protocol RecordingMediaWriter: AnyObject {
    func append(_ chunk: MixedAudioChunk) throws
    func finish() async throws
    func cancel()
}

protocol RecordingMediaWriterFactory {
    func makeWriter(at url: URL) throws -> RecordingMediaWriter
}

/// Keeps completed, independently playable chunks so an interrupted session has a useful fallback.
final class RecoverySegmentStore {
    private let directoryURL: URL
    private let factory: RecordingMediaWriterFactory
    private let fileSystem: RecordingMediaFileSystem
    private let segmentDuration: TimeInterval
    private var currentWriter: RecordingMediaWriter?
    private var currentURL: URL?
    private var currentStart: TimeInterval?
    private var sequence = 0
    private(set) var completedURLs: [URL] = []

    init(directoryURL: URL, factory: RecordingMediaWriterFactory, fileSystem: RecordingMediaFileSystem,
         segmentDuration: TimeInterval = 30) {
        self.directoryURL = directoryURL
        self.factory = factory
        self.fileSystem = fileSystem
        self.segmentDuration = segmentDuration
    }

    /// Closes the current standalone AAC file when the next chunk crosses the segment-duration boundary.
    /// This bounds crash loss to the active segment while keeping completed files independently playable.
    func append(_ chunk: MixedAudioChunk) async throws {
        if let start = currentStart, chunk.presentationTime - start >= segmentDuration {
            try await closeCurrent()
        }
        if currentWriter == nil {
            sequence += 1
            let url = directoryURL.appendingPathComponent(String(format: "segment-%06d.m4a", sequence))
            currentWriter = try factory.makeWriter(at: url)
            currentURL = url
            currentStart = chunk.presentationTime
        }
        do { try currentWriter?.append(chunk) } catch {
            currentWriter?.cancel()
            currentWriter = nil
            currentURL = nil
            currentStart = nil
            throw error
        }
    }

    func closeCurrent() async throws {
        guard let writer = currentWriter, let url = currentURL else { return }
        try await writer.finish()
        currentWriter = nil
        currentURL = nil
        currentStart = nil
        guard fileSystem.fileExists(at: url), fileSystem.isReadable(at: url) else {
            throw RecordingIssue(
                code: "recovery.invalid",
                message: "A recovery segment could not be read.",
                recoveryURL: url,
                isRetryAllowed: false
            )
        }
        completedURLs.append(url)
    }

    func cleanup() throws {
        try fileSystem.removeItem(at: directoryURL)
    }

    static func discoverOrphanedArtifacts(
        in parentDirectory: URL,
        validator: RecordingMediaValidating,
        fileSystem: RecordingMediaFileSystem
    ) async -> [RecordingArtifact] {
        guard let entries = try? fileSystem.contentsOfDirectory(at: parentDirectory) else { return [] }
        var artifacts: [RecordingArtifact] = []
        for directory in entries
            where directory.lastPathComponent.hasPrefix(".noty-recovery-") && fileSystem.isDirectory(at: directory) {
            guard let segments = try? fileSystem.contentsOfDirectory(at: directory) else { continue }
            for segment in segments where segment.pathExtension == "m4a" {
                guard let duration = try? await validator.validate(url: segment) else { continue }
                artifacts.append(RecordingArtifact(url: segment, kind: .recovery, duration: duration))
            }
        }
        return artifacts.sorted { $0.url.path < $1.url.path }
    }

    func closeBestEffort() async {
        do { try await closeCurrent() } catch {
            currentWriter?.cancel(); currentWriter = nil; currentURL = nil; currentStart = nil
        }
    }
}
