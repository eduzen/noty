import Foundation
import XCTest
@testable import Noty

final class RecordingWriterTests: XCTestCase {
    func testSuccessfulFinishCreatesUniqueTimestampedRecording() async throws {
        let fixture = Fixture()
        let writer = fixture.makeWriter()
        try await writer.start(at: fixture.folder)
        try await writer.append(chunk(time: 0))
        let artifact = try await writer.finish()
        XCTAssertEqual(artifact.kind, .recording)
        XCTAssertEqual(artifact.url.lastPathComponent, "Noty-2026-10-23-120000-000.m4a")
        XCTAssertTrue(fixture.fileSystem.exists.contains(artifact.url))
        XCTAssertFalse(fixture.fileSystem.directories.contains { $0.lastPathComponent.hasPrefix(".noty-recovery-") })
        let duplicateFinish = try await writer.finish()
        XCTAssertEqual(duplicateFinish, artifact)
    }

    func testDistinctWritersNeverOverwriteSameTimestampRecording() async throws {
        let fixture = Fixture()
        let first = fixture.makeWriter()
        let second = fixture.makeWriter()
        try await first.start(at: fixture.folder)
        try await first.append(chunk(time: 0))
        let firstArtifact = try await first.finish()
        try await second.start(at: fixture.folder)
        try await second.append(chunk(time: 0))
        let secondArtifact = try await second.finish()
        XCTAssertNotEqual(firstArtifact.url, secondArtifact.url)
    }

    func testAppendAfterFinishIsRejectedDeterministically() async throws {
        let fixture = Fixture()
        let writer = fixture.makeWriter()
        try await writer.start(at: fixture.folder)
        try await writer.append(chunk(time: 0))
        _ = try await writer.finish()
        do { try await writer.append(chunk(time: 1)); XCTFail("Expected terminal-state rejection") }
        catch let issue as RecordingIssue { XCTAssertEqual(issue.code, "writer.not-active") }
    }

    func testMalformedAndOutOfOrderChunksAreRejected() async throws {
        let fixture = Fixture()
        let writer = fixture.makeWriter()
        try await writer.start(at: fixture.folder)
        try await writer.append(chunk(time: 1))
        do { try await writer.append(chunk(time: 0)); XCTFail("Expected order rejection") }
        catch let issue as RecordingIssue { XCTAssertEqual(issue.code, "writer.invalid-chunk") }
    }

    func testWriterFailureReportsValidatedRecoverySegment() async throws {
        let fixture = Fixture(segmentDuration: 0.5)
        fixture.factory.failOnAppendNumber = 5
        let writer = fixture.makeWriter()
        try await writer.start(at: fixture.folder)
        fixture.validator.invalidURLs.insert(fixture.factory.writers[0].url)
        try await writer.append(chunk(time: 0))
        try await writer.append(chunk(time: 1))
        do { try await writer.append(chunk(time: 2)); XCTFail("Expected injected disk-full failure") }
        catch let issue as RecordingIssue { XCTAssertEqual(issue.code, "disk.full") }
        let outcome = await writer.fail(RecordingIssue(code: "recording.interrupted", message: "Interrupted"))
        guard case .partial(let artifact?, let issue) = outcome else { return XCTFail("Expected recovery artifact") }
        XCTAssertEqual(artifact.kind, .recovery)
        XCTAssertEqual(issue.code, "recording.interrupted")
        XCTAssertTrue(fixture.validator.validURLs.contains(artifact.url))
    }

    func testInvalidFinalMediaIsNeverReportedAsSaved() async throws {
        let fixture = Fixture()
        fixture.validator.invalidURLs.insert(fixture.folder.appendingPathComponent(".invalid"))
        fixture.validator.failAll = true
        let writer = fixture.makeWriter()
        try await writer.start(at: fixture.folder)
        try await writer.append(chunk(time: 0))
        do { _ = try await writer.finish(); XCTFail("Expected validation failure") }
        catch let issue as RecordingIssue { XCTAssertEqual(issue.code, "media.invalid") }
    }

    func testDuplicateFailureAndAppendAfterFailureAreDeterministic() async throws {
        let fixture = Fixture()
        let writer = fixture.makeWriter()
        try await writer.start(at: fixture.folder)
        try await writer.append(chunk(time: 0))
        let failure = RecordingIssue(code: "recording.interrupted", message: "Interrupted")
        let first = await writer.fail(failure)
        let second = await writer.fail(RecordingIssue(code: "different", message: "Different"))
        XCTAssertEqual(first, second)
        do { try await writer.append(chunk(time: 1)); XCTFail("Expected terminal-state rejection") }
        catch let issue as RecordingIssue { XCTAssertEqual(issue.code, "writer.not-active") }
    }

    func testConcurrentFinishCallsShareFinalizationAndFailWaitsForItsResult() async throws {
        let fixture = Fixture()
        let gate = AsyncTestGate()
        fixture.factory.finishGate = gate
        let writer = fixture.makeWriter()
        try await writer.start(at: fixture.folder)
        try await writer.append(chunk(time: 0))
        let first = Task { try await writer.finish() }
        await gate.waitForEntry()
        let second = Task { try await writer.finish() }
        let interruption = Task {
            await writer.fail(RecordingIssue(code: "recording.interrupted", message: "Interrupted"))
        }
        await gate.open()
        let firstArtifact = try await first.value
        let secondArtifact = try await second.value
        let failureOutcome = await interruption.value
        XCTAssertEqual(firstArtifact, secondArtifact)
        XCTAssertEqual(failureOutcome, .saved(firstArtifact))
    }

    func testClosedRecoverySegmentsCanBeDiscoveredAfterRelaunch() async throws {
        let fixture = Fixture(segmentDuration: 0.5)
        let writer = fixture.makeWriter()
        try await writer.start(at: fixture.folder)
        fixture.validator.invalidURLs.insert(fixture.factory.writers[0].url)
        try await writer.append(chunk(time: 0))
        try await writer.append(chunk(time: 1))
        let outcome = await writer.fail(RecordingIssue(code: "recording.interrupted", message: "Interrupted"))
        guard case .partial(let artifact?, _) = outcome else { return XCTFail("Expected active recovery artifact") }
        let discovered = await RecoverySegmentStore.discoverOrphanedArtifacts(
            in: fixture.folder, validator: fixture.validator, fileSystem: fixture.fileSystem
        )
        XCTAssertTrue(discovered.contains(artifact))
        XCTAssertTrue(discovered.allSatisfy { $0.kind == .recovery })
    }

    func testOverflowRejectedBeforeWriterSeesUnboundedData() async throws {
        let fixture = Fixture()
        let writer = fixture.makeWriter()
        try await writer.start(at: fixture.folder)
        let oversized = MixedAudioChunk(presentationTime: 0, frameCount: 240_001, samples: [])
        do { try await writer.append(oversized); XCTFail("Expected bounded-writer overflow") }
        catch let issue as RecordingIssue { XCTAssertEqual(issue.code, "writer.overflow") }
        XCTAssertEqual(fixture.factory.appendCount, 0)
    }

    private func chunk(time: Double) -> MixedAudioChunk {
        MixedAudioChunk(presentationTime: time, frameCount: 48_000, samples: Array(repeating: 0.1, count: 96_000))
    }
}

private final class Fixture {
    let folder = URL(fileURLWithPath: "/recordings", isDirectory: true)
    let fileSystem = FakeMediaFileSystem()
    let factory = FakeMediaWriterFactory()
    let validator = FakeMediaValidator()
    let date = ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")!
    let segmentDuration: TimeInterval
    init(segmentDuration: TimeInterval = 30) {
        self.segmentDuration = segmentDuration
        factory.configure(fileSystem: fileSystem)
    }
    func makeWriter() -> RecordingWriter {
        RecordingWriter(factory: factory, validator: validator, fileSystem: fileSystem,
                        recoverySegmentDuration: segmentDuration, now: { self.date })
    }
}

private final class FakeMediaFileSystem: RecordingMediaFileSystem {
    var exists: Set<URL> = []
    var directories: Set<URL> = []
    func createDirectory(at url: URL) throws { directories.insert(url) }
    func fileExists(at url: URL) -> Bool { exists.contains(url) }
    func isReadable(at url: URL) -> Bool { exists.contains(url) }
    func isDirectory(at url: URL) -> Bool { directories.contains(url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] {
        (Array(exists) + Array(directories)).filter { $0.deletingLastPathComponent() == url }
    }
    func moveItem(at source: URL, to destination: URL) throws {
        guard exists.remove(source) != nil else { throw RecordingIssue(code: "filesystem.missing", message: "missing") }
        exists.insert(destination)
    }
    func removeItem(at url: URL) throws {
        exists = exists.filter { $0 != url && !$0.path.hasPrefix(url.path + "/") }
        directories = directories.filter { $0 != url && !$0.path.hasPrefix(url.path + "/") }
    }
}

private final class FakeMediaWriterFactory: RecordingMediaWriterFactory {
    var failOnAppendNumber: Int?
    var appendCount = 0
    var finishGate: AsyncTestGate?
    private(set) var writers: [FakeMediaWriter] = []
    func makeWriter(at url: URL) throws -> RecordingMediaWriter {
        let writer = FakeMediaWriter(url: url, fileSystem: fileSystem, owner: self)
        writers.append(writer)
        return writer
    }
    private var fileSystem = FakeMediaFileSystem()
    func configure(fileSystem: FakeMediaFileSystem) { self.fileSystem = fileSystem }
}

private final class FakeMediaWriter: RecordingMediaWriter {
    let url: URL
    let fileSystem: FakeMediaFileSystem
    unowned let owner: FakeMediaWriterFactory
    var failed = false
    init(url: URL, fileSystem: FakeMediaFileSystem, owner: FakeMediaWriterFactory) {
        self.url = url; self.fileSystem = fileSystem; self.owner = owner
    }
    func append(_ chunk: MixedAudioChunk) throws {
        owner.appendCount += 1
        if owner.failOnAppendNumber == owner.appendCount {
            failed = true
            throw RecordingIssue(code: "disk.full", message: "Disk is full.")
        }
        fileSystem.exists.insert(url)
    }
    func finish() async throws {
        if let gate = owner.finishGate { await gate.wait() }
        if !failed { fileSystem.exists.insert(url) }
    }
    func cancel() { fileSystem.exists.remove(url) }
}

private final class FakeMediaValidator: RecordingMediaValidating {
    var failAll = false
    var invalidURLs: Set<URL> = []
    private(set) var validURLs: Set<URL> = []
    func validate(url: URL) async throws -> TimeInterval {
        guard !failAll, !invalidURLs.contains(url) else {
            throw RecordingIssue(code: "media.invalid", message: "Invalid media", recoveryURL: url)
        }
        validURLs.insert(url)
        return 1
    }
}
private actor AsyncTestGate {
    private var openState = false
    private var enteredState = false
    private var writerWaiter: CheckedContinuation<Void, Never>?
    private var entryWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !openState else { return }
        enteredState = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { writerWaiter = $0 }
    }

    func waitForEntry() async {
        guard !enteredState else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func open() {
        openState = true
        writerWaiter?.resume()
        writerWaiter = nil
    }
}
