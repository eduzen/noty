import Foundation
@testable import Noty
import XCTest

@MainActor
final class RecordingControllerTests: XCTestCase {
    func testStartStopWritesAudibleSystemAndMicrophoneAudio() async throws {
        let capture = FakeCaptureService()
        let writer = FakeRecordingWriter()
        let controller = makeController(capture: capture, writer: writer)

        await controller.start()
        XCTAssertEqual(controller.state, .recording)
        capture.emit(packet(source: .system, time: 0, frames: 4800, left: 0.5, right: -0.5))
        capture.emit(packet(source: .microphone, time: 0, frames: 4800, left: 0.2, right: 0.1))
        await controller.stop()

        let snapshot = await writer.snapshot()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.lastArtifact?.kind, .recording)
        XCTAssertEqual(snapshot.startCount, 1)
        XCTAssertEqual(snapshot.finishCount, 1)
        XCTAssertGreaterThan(snapshot.chunks.reduce(0) { $0 + $1.frameCount }, 0)
        let samples = try XCTUnwrap(snapshot.chunks.first?.samples)
        XCTAssertGreaterThan(samples[0], 0.3)
        XCTAssertLessThan(samples[1], -0.15)
    }

    func testPermissionFailureDoesNotStartCaptureOrWriter() async {
        let issue = RecordingIssue(code: "permission.microphone-denied", message: "Allow microphone access.")
        let capture = FakeCaptureService()
        let writer = FakeRecordingWriter()
        let controller = makeController(permissions: FakePermissions(issue: issue), capture: capture, writer: writer)

        await controller.start()

        let snapshot = await writer.snapshot()
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.latestIssue, issue)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(snapshot.startCount, 0)
    }

    func testDuplicateStartAndStopAreIdempotent() async {
        let capture = FakeCaptureService()
        let writer = FakeRecordingWriter()
        let controller = makeController(capture: capture, writer: writer)

        await controller.start()
        await controller.start()
        await controller.stop()
        await controller.stop()

        let snapshot = await writer.snapshot()
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(snapshot.startCount, 1)
        XCTAssertEqual(snapshot.finishCount, 1)
    }

    func testCaptureFailureSurfacesValidatedRecoveryArtifact() async {
        let capture = FakeCaptureService()
        let issue = RecordingIssue(code: "capture.microphone-disconnected", message: "Microphone disconnected.")
        let artifact = RecordingArtifact(
            url: URL(fileURLWithPath: "/recordings/recovery.m4a"),
            kind: .recovery,
            duration: 1
        )
        let writer = FakeRecordingWriter(failureOutcome: .partial(artifact, issue))
        let controller = makeController(capture: capture, writer: writer)
        await controller.start()

        capture.fail(issue)
        await writer.waitUntilFailure()
        await controller.stop()

        XCTAssertEqual(controller.state, .interrupted)
        XCTAssertEqual(controller.latestIssue, issue)
        XCTAssertEqual(controller.lastArtifact, artifact)
    }

    func testWriterFailureStopsCaptureAndSurfacesRecoveryURL() async {
        let capture = FakeCaptureService()
        let issue = RecordingIssue(code: "writer.disk-full", message: "Disk is full.")
        let artifact = RecordingArtifact(
            url: URL(fileURLWithPath: "/recordings/partial.m4a"),
            kind: .recovery,
            duration: 0.25
        )
        let writer = FakeRecordingWriter(appendIssue: issue, failureOutcome: .partial(artifact, issue))
        let controller = makeController(capture: capture, writer: writer)
        await controller.start()

        capture.emit(packet(source: .system, time: 0, frames: 24000, left: 0.4, right: 0.4))
        await writer.waitUntilFailure()
        await controller.stop()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.latestIssue, issue)
        XCTAssertEqual(controller.lastArtifact, artifact)
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testStopDuringStartupCancelsBeforeWriterOrCaptureStarts() async {
        let permissions = FakePermissions(shouldWait: true)
        let capture = FakeCaptureService()
        let writer = FakeRecordingWriter()
        let controller = makeController(permissions: permissions, capture: capture, writer: writer)
        let starting = Task { await controller.start() }
        await permissions.waitUntilEntered()
        let terminating = Task { await controller.finishForTermination() }
        await Task.yield()
        permissions.release()

        let shouldTerminate = await terminating.value
        await starting.value
        let snapshot = await writer.snapshot()
        XCTAssertTrue(shouldTerminate)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(snapshot.startCount, 0)
        XCTAssertEqual(capture.startCount, 0)
    }

    func testConcurrentTerminationAndStopShareFinalization() async {
        let capture = FakeCaptureService()
        let writer = FakeRecordingWriter()
        let gate = AsyncControllerGate()
        await writer.setFinishGate(gate)
        let controller = makeController(capture: capture, writer: writer)
        await controller.start()

        let firstTermination = Task { await controller.finishForTermination() }
        await gate.waitForEntry()
        let secondTermination = Task { await controller.finishForTermination() }
        let duplicateStop = Task { await controller.stop() }
        await gate.open()

        let firstCanQuit = await firstTermination.value
        let secondCanQuit = await secondTermination.value
        await duplicateStop.value
        let snapshot = await writer.snapshot()
        XCTAssertTrue(firstCanQuit)
        XCTAssertTrue(secondCanQuit)
        XCTAssertEqual(snapshot.finishCount, 1)
        XCTAssertEqual(controller.state, .idle)
    }

    func testTerminationRefusesToQuitWhenNoArtifactWasRecovered() async {
        let capture = FakeCaptureService()
        let issue = RecordingIssue(code: "capture.failure", message: "Capture failed.")
        let writer = FakeRecordingWriter(failureOutcome: .failed(issue))
        let controller = makeController(capture: capture, writer: writer)
        await controller.start()
        capture.fail(issue)
        await writer.waitUntilFailure()
        await controller.stop()

        let shouldTerminate = await controller.finishForTermination()
        XCTAssertFalse(shouldTerminate)
    }

    private func makeController(
        permissions: FakePermissions? = nil,
        destinations: FakeDestinations? = nil,
        capture: FakeCaptureService? = nil,
        writer: FakeRecordingWriter? = nil
    ) -> RecordingController {
        let resolvedPermissions = permissions ?? FakePermissions()
        let resolvedDestinations = destinations ?? FakeDestinations()
        let resolvedCapture = capture ?? FakeCaptureService()
        let resolvedWriter = writer ?? FakeRecordingWriter()
        return RecordingController(
            permissions: resolvedPermissions,
            destinations: resolvedDestinations,
            captureFactory: { resolvedCapture },
            writerFactory: { resolvedWriter },
            recoveryDiscovery: { _ in [] }
        )
    }

    private func packet(source: AudioSource, time: Double, frames: Int, left: Float,
                        right: Float) -> CapturedAudioPacket {
        CapturedAudioPacket(
            source: source,
            presentationTime: time,
            sampleRate: 48000,
            channelCount: 2,
            frameCount: frames,
            samples: Array(repeating: [left, right], count: frames).flatMap { $0 }
        )
    }
}

@MainActor
private final class FakePermissions: RecordingPermissionPreparing {
    private let issue: RecordingIssue?
    private let shouldWait: Bool
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(issue: RecordingIssue? = nil, shouldWait: Bool = false) {
        self.issue = issue
        self.shouldWait = shouldWait
    }

    func prepareForRecording() async throws -> PermissionGrant {
        if shouldWait {
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        if let issue {
            throw issue
        }
        return PermissionGrant(microphone: true, screenRecording: true)
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
private final class FakeDestinations: RecordingDestinationManaging {
    private let folder = URL(fileURLWithPath: "/recordings", isDirectory: true)
    func resolveCurrentDestination() throws -> DestinationLease {
        DestinationLease(url: folder, releaseAccess: nil)
    }

    func chooseFolder() throws -> DestinationLease {
        DestinationLease(url: folder, releaseAccess: nil)
    }
}

private actor FakeRecordingWriter: RecordingWriting {
    struct Snapshot: Sendable {
        let startCount: Int
        let appendCount: Int
        let finishCount: Int
        let failCount: Int
        let chunks: [MixedAudioChunk]
    }

    private let artifact = RecordingArtifact(url: URL(fileURLWithPath: "/recordings/Noty-test.m4a"), duration: 0)
    private let appendIssue: RecordingIssue?
    private let failureOutcome: RecordingOutcome?
    private var finishGate: AsyncControllerGate?
    private var startCount = 0
    private var appendCount = 0
    private var finishCount = 0
    private var failCount = 0
    private var chunks: [MixedAudioChunk] = []
    private var failureWaiters: [CheckedContinuation<Void, Never>] = []

    init(appendIssue: RecordingIssue? = nil, failureOutcome: RecordingOutcome? = nil) {
        self.appendIssue = appendIssue
        self.failureOutcome = failureOutcome
    }

    func start(at _: URL) async throws {
        startCount += 1
    }

    func append(_ chunk: MixedAudioChunk) async throws {
        appendCount += 1
        if let appendIssue {
            throw appendIssue
        }
        chunks.append(chunk)
    }

    func finish() async throws -> RecordingArtifact {
        finishCount += 1
        if let finishGate {
            await finishGate.wait()
        }
        let duration = Double(chunks.reduce(0) { $0 + $1.frameCount }) / 48000
        return RecordingArtifact(url: artifact.url, duration: duration)
    }

    func fail(_ issue: RecordingIssue) async -> RecordingOutcome {
        failCount += 1
        for waiter in failureWaiters {
            waiter.resume()
        }
        failureWaiters.removeAll()
        return failureOutcome ?? .failed(issue)
    }

    func setFinishGate(_ gate: AsyncControllerGate) {
        finishGate = gate
    }

    func waitUntilFailure() async {
        guard failCount == 0 else { return }
        await withCheckedContinuation { failureWaiters.append($0) }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            startCount: startCount,
            appendCount: appendCount,
            finishCount: finishCount,
            failCount: failCount,
            chunks: chunks
        )
    }
}

private actor AsyncControllerGate {
    private var openState = false
    private var enteredState = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !openState else { return }
        enteredState = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForEntry() async {
        guard !enteredState else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func open() {
        openState = true
        continuation?.resume()
        continuation = nil
    }
}
