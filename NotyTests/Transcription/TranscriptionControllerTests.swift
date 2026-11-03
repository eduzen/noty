import Foundation
@testable import Noty
import XCTest

@MainActor
final class TranscriptionControllerTests: XCTestCase {
    func testRecordingSuspendsWorkerAndKeepsJobQueued() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.cleanup() }
        let worker = TestTranscriptionWorker()
        let controller = TranscriptionController(store: fixture.store, worker: worker)
        await controller.bootstrap()
        await controller.enqueue(sourceURL: fixture.audio, duration: 10, folderBookmark: nil)
        await worker.waitForRun()
        try await controller.suspendForRecording()
        XCTAssertEqual(controller.jobs.first?.status, .waiting)
        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(worker.stopCount, 1)
        XCTAssertEqual(controller.jobs.count, 1)
    }

    func testRelaunchRequeuesInterruptedWorkAndKeepsDestination() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.cleanup() }
        let worker = TestTranscriptionWorker()
        let first = TranscriptionController(store: fixture.store, worker: worker)
        await first.bootstrap()
        await first.enqueue(sourceURL: fixture.audio, duration: 10, folderBookmark: nil)
        await worker.waitForRun()
        await first.prepareForTermination()
        let second = TranscriptionController(store: fixture.store, worker: TestTranscriptionWorker())
        try await second.suspendForRecording()
        await second.bootstrap()
        XCTAssertEqual(second.jobs.first?.sourceURL, fixture.audio)
        XCTAssertEqual(second.jobs.first?.status, .waiting)
    }

    func testDuplicateSourceDoesNotQueueTwice() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.cleanup() }
        let controller = TranscriptionController(store: fixture.store, worker: TestTranscriptionWorker())
        try await controller.suspendForRecording()
        await controller.bootstrap()
        await controller.enqueue(sourceURL: fixture.audio, duration: 10, folderBookmark: nil)
        await controller.enqueue(sourceURL: fixture.audio, duration: 10, folderBookmark: nil)
        XCTAssertEqual(controller.jobs.count, 1)
    }

    func testAutomaticRecordingRequiresEnabledSetting() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.cleanup() }
        let controller = TranscriptionController(store: fixture.store, worker: TestTranscriptionWorker())
        await controller.bootstrap()
        await controller.enqueueRecording(RecordingArtifact(url: fixture.audio, duration: 10))
        XCTAssertTrue(controller.jobs.isEmpty)
    }

    func testSuccessfulJobPublishesSpeakerText() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.cleanup() }
        let worker = TestTranscriptionWorker()
        worker.completeAutomatically = true
        let controller = TranscriptionController(store: fixture.store, worker: worker)
        await controller.enqueue(sourceURL: fixture.audio, duration: 10, folderBookmark: nil)
        await waitUntil { controller.jobs.first?.status == .complete }
        let output = try XCTUnwrap(controller.jobs.first?.lastExport?.url)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "[00:00:00] Speaker 1: Hello\n")
        XCTAssertEqual(worker.phases, [.transcribe, .diarize])
    }

    func testSpeakerFailureExportsTextAndRetryUsesCheckpoint() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.cleanup() }
        let worker = TestTranscriptionWorker()
        worker.completeAutomatically = true
        worker.failDiarization = true
        let controller = TranscriptionController(store: fixture.store, worker: worker)
        await controller.enqueue(sourceURL: fixture.audio, duration: 10, folderBookmark: nil)
        await waitUntil { controller.jobs.first?.status == .needsAttention }
        let job = try XCTUnwrap(controller.jobs.first)
        let fallback = try XCTUnwrap(job.lastExport?.url)
        XCTAssertTrue(try String(contentsOf: fallback, encoding: .utf8).contains("Speaker labels unavailable"))
        worker.failDiarization = false
        controller.retry(job.id)
        await waitUntil { controller.jobs.first?.status == .complete }
        XCTAssertEqual(worker.phases.filter { $0 == .transcribe }.count, 1)
        let completed = try XCTUnwrap(controller.jobs.first?.lastExport?.url)
        XCTAssertNotEqual(completed, fallback)
        XCTAssertTrue(try String(contentsOf: fallback, encoding: .utf8).contains("Speaker labels unavailable"))
        XCTAssertEqual(try String(contentsOf: completed, encoding: .utf8), "[00:00:00] Speaker 1: Hello\n")
    }

    func testLongRecordingDoesNotRunSpeakerDetection() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.cleanup() }
        let worker = TestTranscriptionWorker()
        worker.completeAutomatically = true
        let controller = TranscriptionController(store: fixture.store, worker: worker)
        await controller.enqueue(sourceURL: fixture.audio, duration: 7201, folderBookmark: nil)
        await waitUntil { controller.jobs.first?.status == .complete }
        XCTAssertEqual(worker.phases, [.transcribe])
        XCTAssertTrue(controller.jobs.first?.message?.contains("two hours") == true)
    }

    func testModelRepairDoesNotRestartCancelledJob() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.cleanup() }
        let worker = TestTranscriptionWorker()
        worker.completeAutomatically = true
        worker.failDiarization = true
        worker.failureNeedsRepair = true
        let controller = TranscriptionController(store: fixture.store, worker: worker)
        await controller.enqueue(sourceURL: fixture.audio, duration: 10, folderBookmark: nil)
        await waitUntil { controller.jobs.first?.status == .needsAttention && controller.canPrepareModels }
        let id = try XCTUnwrap(controller.jobs.first?.id)
        controller.retry(id)
        await controller.cancel(id)
        controller.prepareModels()
        await waitUntil { controller.modelState == .ready }
        XCTAssertEqual(controller.jobs.first?.status, .cancelled)
    }

    func testQuitStillPersistsNewlyFinalizedJob() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.cleanup() }
        let controller = TranscriptionController(store: fixture.store, worker: TestTranscriptionWorker())
        await controller.prepareForTermination()
        await controller.enqueue(sourceURL: fixture.audio, duration: 10, folderBookmark: nil)
        let snapshot = try XCTUnwrap(fixture.store.load(TranscriptionSnapshot.self))
        XCTAssertEqual(snapshot.jobs.count, 1)
        XCTAssertEqual(snapshot.jobs.first?.status, .waiting)
    }

    func testCrashAfterExportPublicationReconcilesWithoutWorkerOrDuplicate() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.cleanup() }
        let text = "[00:00:00] Speaker 1: Already saved\n"
        let reserved = try fixture.store.reserveExport(sourceURL: fixture.audio, text: text, previous: nil)
        try fixture.store.publish(text: text, reservation: reserved)
        var job = try TranscriptionJob(
            sourceURL: fixture.audio,
            identity: TranscriptionSourceIdentity(url: fixture.audio),
            duration: 10,
            status: .identifyingSpeakers
        )
        job.exportReservation = reserved
        job.pendingExportText = text
        job.pendingCompletionStatus = .complete
        try fixture.store.save(TranscriptionSnapshot(modelsReady: true, jobs: [job]))
        let worker = TestTranscriptionWorker()
        let controller = TranscriptionController(store: fixture.store, worker: worker)
        await controller.bootstrap()
        await waitUntil { controller.jobs.first?.status == .complete }
        XCTAssertTrue(worker.phases.isEmpty)
        XCTAssertEqual(controller.jobs.first?.lastExport, reserved)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.folder.appendingPathComponent("meeting (2).txt").path))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition())
    }
}

private struct TranscriptionFixture {
    let folder: URL
    let audio: URL
    let store: TranscriptionFileStore

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        audio = folder.appendingPathComponent("meeting.m4a")
        try Data("fixture".utf8).write(to: audio)
        store = TranscriptionFileStore(rootURL: folder.appendingPathComponent("queue"))
        try store.save(TranscriptionSnapshot(modelsReady: true))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: folder)
    }
}

@MainActor
private final class TestTranscriptionWorker: TranscriptionWorkerRunning {
    var stopCount = 0
    var phases: [TranscriptionPhase] = []
    var completeAutomatically = false
    var failDiarization = false
    var failureNeedsRepair = false
    private var continuation: CheckedContinuation<TranscriptionWorkerResult, Error>?
    private var runWaiters: [CheckedContinuation<Void, Never>] = []

    func run(_ request: TranscriptionWorkerRequest,
             progress _: @escaping @MainActor (TranscriptionWorkerProgress) -> Void) async throws
        -> TranscriptionWorkerResult {
        phases.append(request.phase)
        if completeAutomatically {
            if request.phase == .diarize, failDiarization {
                throw TranscriptionError.workerFailed("Test speaker failure", needsRepair: failureNeedsRepair)
            }
            return TranscriptionWorkerResult(
                jobID: request.jobID, attemptID: request.attemptID,
                segments: request.phase == .transcribe ? [
                    TranscriptSegment(start: 0, end: 1, text: "Hello",
                                      words: [TranscriptWord(start: 0, end: 1, text: "Hello")])
                ] : [], speakers: request.phase == .diarize ? [SpeakerInterval(start: 0, end: 1, speaker: 9)] : []
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            runWaiters.forEach { $0.resume() }
            runWaiters.removeAll()
        }
    }

    func stop() async throws {
        stopCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func waitForRun() async {
        if continuation != nil {
            return
        }
        await withCheckedContinuation { runWaiters.append($0) }
    }
}
