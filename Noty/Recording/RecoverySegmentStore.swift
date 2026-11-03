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
    let directoryURL: URL
    private let factory: RecordingMediaWriterFactory
    private let fileSystem: RecordingMediaFileSystem
    private let noticeStore: any RecoveryNoticeStoring
    private let filenamePrefix: String
    private let segmentDuration: TimeInterval
    private var currentWriter: RecordingMediaWriter?
    private var currentURL: URL?
    private var currentStart: TimeInterval?
    private var sequence = 0
    private(set) var completedURLs: [URL] = []

    init(directoryURL: URL, factory: RecordingMediaWriterFactory, fileSystem: RecordingMediaFileSystem,
         filenamePrefix: String, segmentDuration: TimeInterval = 30,
         noticeStore: any RecoveryNoticeStoring = RecoveryNoticeStore()) {
        self.directoryURL = directoryURL
        self.factory = factory
        self.fileSystem = fileSystem
        self.segmentDuration = segmentDuration
        self.filenamePrefix = filenamePrefix
        self.noticeStore = noticeStore
    }

    /// Closes the current standalone AAC file when the next chunk crosses the segment-duration boundary.
    /// This bounds crash loss to the active segment while keeping completed files independently playable.
    func append(_ chunk: MixedAudioChunk) async throws {
        if let start = currentStart, chunk.presentationTime - start >= segmentDuration {
            try await closeCurrent()
        }
        if currentWriter == nil {
            sequence += 1
            let url = directoryURL.appendingPathComponent(
                "\(filenamePrefix)-recovery-\(String(format: "%06d", sequence)).m4a"
            )
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

    func cleanupAfterSuccessfulSave() {
        do { try fileSystem.removeItem(at: directoryURL) } catch {
            // A saved recording must not be reported as unfinished on the next launch.
            noticeStore.acknowledge(directoryURL.path)
        }
    }

    static func discoverOrphanedArtifacts(
        in parentDirectory: URL,
        validator: RecordingMediaValidating,
        fileSystem: RecordingMediaFileSystem,
        noticeStore: any RecoveryNoticeStoring = RecoveryNoticeStore()
    ) async -> [RecordingArtifact] {
        guard let entries = try? fileSystem.contentsOfDirectory(at: parentDirectory) else { return [] }
        var artifacts: [RecordingArtifact] = []
        for directory in entries
            where directory.lastPathComponent.hasPrefix(".noty-recovery-") && fileSystem.isDirectory(at: directory) {
            guard !noticeStore.isAcknowledged(directory.path),
                  let segments = try? fileSystem.contentsOfDirectory(at: directory) else { continue }
            let sessionID = String(directory.lastPathComponent.dropFirst(".noty-recovery-".count))
            let primary = parentDirectory.appendingPathComponent(".noty-\(sessionID).tmp.m4a")
            if fileSystem.fileExists(at: primary), fileSystem.isReadable(at: primary),
               let duration = try? await validator.validate(url: primary) {
                artifacts.append(RecordingArtifact(url: primary, duration: duration,
                                                   recoverySessionIdentifier: directory.path))
                continue
            }
            var parts: [(url: URL, duration: TimeInterval)] = []
            for segment in segments.sorted(by: { $0.path < $1.path }) where segment.pathExtension == "m4a" {
                guard let duration = try? await validator.validate(url: segment) else { continue }
                parts.append((segment, duration))
            }
            if let artifact = RecordingArtifact(recoveryParts: parts) {
                artifacts.append(artifact)
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
