import Foundation
import ScreenCaptureKit
import XCTest
@testable import Noty

final class ScreenCaptureServiceTests: XCTestCase {
    func testFakeStartAndStopAreIdempotent() async throws {
        let service = FakeCaptureService()
        try await service.start()
        try await service.start()
        await service.stop()
        await service.stop()
        XCTAssertEqual(service.startCount, 1)
        XCTAssertEqual(service.stopCount, 1)
    }

    func testFakeCanEmitAndFinishNormally() async throws {
        let service = FakeCaptureService()
        try await service.start()
        let packet = CapturedAudioPacket(source: .system, presentationTime: 0, sampleRate: 48_000, channelCount: 2, frameCount: 1, samples: [0.25, -0.25])
        service.emit(packet)
        service.finishNormally()
        var received: [CapturedAudioPacket] = []
        for try await value in service.packets { received.append(value) }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].samples, packet.samples)
    }

    func testFakeFailsAtConfiguredPacket() async throws {
        let service = FakeCaptureService()
        let issue = RecordingIssue(code: "capture.test", message: "failure")
        try await service.start()
        service.fail(atPacket: 1, with: issue)
        service.emit(packet(time: 0))
        service.emit(packet(time: 1))
        var received = 0
        do {
            for try await _ in service.packets { received += 1 }
            XCTFail("Expected configured capture failure")
        } catch let error as RecordingIssue {
            XCTAssertEqual(error, issue)
        }
        XCTAssertEqual(received, 1)
    }

    func testDuplicateStopDoesNotReportAnUnexpectedFailure() async throws {
        let backend = FakeScreenCaptureBackend()
        let service = ScreenCaptureService(backend: backend)
        try await service.start()
        await service.stop()
        await service.stop()
        var events: [CaptureTermination] = []
        for await event in service.terminations { events.append(event) }
        XCTAssertEqual(events, [.userStopped])
        XCTAssertEqual(backend.startCount, 1)
        XCTAssertEqual(backend.stopCount, 1)
    }
    func testPacketBufferOverflowProducesTypedFailure() async throws {
        let backend = FakeScreenCaptureBackend()
        let service = ScreenCaptureService(backend: backend)
        try await service.start()
        for index in 0..<4 { backend.emit(packet(time: Double(index))) }

        var events: [CaptureTermination] = []
        for await event in service.terminations { events.append(event) }
        XCTAssertEqual(events.first, .queueOverflow(RecordingIssue(code: "capture.queue-overflow", message: "Audio capture exceeded its bounded buffer.", isRetryAllowed: false)))
    }

    func testStopCancelsBackendStartupBeforeCaptureBegins() async throws {
        let backend = SlowStartingBackend()
        let service = ScreenCaptureService(backend: backend)
        let startTask = Task { try await service.start() }
        await fulfillment(of: [backend.startEntered], timeout: 1)

        await service.stop()
        do {
            try await startTask.value
            XCTFail("Startup should be cancelled")
        } catch is CancellationError {
            // Expected: stop cancels startup before the backend starts capture.
        } catch {
            XCTFail("Unexpected startup error: \(error)")
        }
        XCTAssertEqual(backend.captureStartCount, 0)
        XCTAssertEqual(backend.stopCount, 1)
    }


    func testStreamFailureProducesTypedTermination() async throws {
        let backend = FakeScreenCaptureBackend()
        let service = ScreenCaptureService(backend: backend)
        try await service.start()
        backend.terminate(.microphoneDisconnected(RecordingIssue(code: "capture.mic", message: "disconnected")))
        var events: [CaptureTermination] = []
        for await event in service.terminations { events.append(event) }
        XCTAssertEqual(events, [.microphoneDisconnected(RecordingIssue(code: "capture.mic", message: "disconnected"))])
    }

    func testScreenCaptureErrorMapping() {
        let denied = ScreenCaptureError.map(NSError(domain: SCStreamErrorDomain, code: -3801))
        XCTAssertEqual(denied.kind, .permissionDenied)
        XCTAssertEqual(denied.issue.code, "capture.screen-recording-denied")

        let interrupted = ScreenCaptureError.map(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        XCTAssertEqual(interrupted.kind, .interrupted)

        let unexpected = ScreenCaptureError.map(NSError(domain: "test", code: 42))
        XCTAssertEqual(unexpected.kind, .unexpected)
        XCTAssertEqual(unexpected.issue.code, "capture.stream-failed")
    }

    private func packet(time: TimeInterval) -> CapturedAudioPacket {
        CapturedAudioPacket(source: .system, presentationTime: time, sampleRate: 48_000, channelCount: 2, frameCount: 1, samples: [0, 0])
    }
}

private final class FakeScreenCaptureBackend: ScreenCaptureBackend {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var terminationHandler: ((CaptureTermination) -> Void)?
    private var packetHandler: ((CapturedAudioPacket) -> Void)?

    func start(onPacket: @escaping (CapturedAudioPacket) -> Void, onTermination: @escaping (CaptureTermination) -> Void) async throws {
        startCount += 1
        packetHandler = onPacket
        terminationHandler = onTermination
    }

    func stop() async { stopCount += 1 }

    func terminate(_ termination: CaptureTermination) { terminationHandler?(termination) }
    func emit(_ packet: CapturedAudioPacket) { packetHandler?(packet) }
}

private final class SlowStartingBackend: ScreenCaptureBackend {
    let startEntered = XCTestExpectation(description: "backend start entered")
    private(set) var captureStartCount = 0
    private(set) var stopCount = 0

    func start(onPacket: @escaping (CapturedAudioPacket) -> Void, onTermination: @escaping (CaptureTermination) -> Void) async throws {
        startEntered.fulfill()
        try await Task.sleep(nanoseconds: 5_000_000_000)
        try Task.checkCancellation()
        captureStartCount += 1
    }

    func stop() async { stopCount += 1 }
}
