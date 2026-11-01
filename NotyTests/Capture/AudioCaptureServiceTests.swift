import Foundation
@testable import Noty
import XCTest

final class AudioCaptureServiceTests: XCTestCase {
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
        let packet = CapturedAudioPacket(
            source: .system,
            presentationTime: 0,
            sampleRate: 48000,
            channelCount: 2,
            frameCount: 1,
            samples: [0.25, -0.25]
        )
        service.emit(packet)
        service.finishNormally()
        var received: [CapturedAudioPacket] = []
        for try await value in service.packets {
            received.append(value)
        }
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
            for try await _ in service.packets {
                received += 1
            }
            XCTFail("Expected configured capture failure")
        } catch let error as RecordingIssue {
            XCTAssertEqual(error, issue)
        }
        XCTAssertEqual(received, 1)
    }

    func testDuplicateStopDoesNotReportAnUnexpectedFailure() async throws {
        let backend = FakeAudioBackend()
        let service = AudioCaptureService(backends: [backend])
        try await service.start()
        await service.stop()
        await service.stop()
        var events: [CaptureTermination] = []
        for await event in service.terminations {
            events.append(event)
        }
        XCTAssertEqual(events, [.userStopped])
        XCTAssertEqual(backend.startCount, 1)
        XCTAssertEqual(backend.stopCount, 1)
    }

    func testPacketBufferOverflowProducesTypedFailure() async throws {
        let backend = FakeAudioBackend()
        let service = AudioCaptureService(backends: [backend])
        try await service.start()
        for index in 0 ..< 4 {
            backend.emit(packet(time: Double(index)))
        }

        var events: [CaptureTermination] = []
        for await event in service.terminations {
            events.append(event)
        }
        XCTAssertEqual(
            events.first,
            .queueOverflow(RecordingIssue(
                code: "capture.queue-overflow",
                message: "Audio capture exceeded its bounded buffer.",
                isRetryAllowed: false
            ))
        )
    }

    func testStopCancelsBackendStartupBeforeCaptureBegins() async throws {
        let backend = SlowStartingBackend()
        let service = AudioCaptureService(backends: [backend])
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
        let backend = FakeAudioBackend()
        let service = AudioCaptureService(backends: [backend])
        try await service.start()
        backend.terminate(.microphoneDisconnected(RecordingIssue(code: "capture.mic", message: "disconnected")))
        var events: [CaptureTermination] = []
        for await event in service.terminations {
            events.append(event)
        }
        XCTAssertEqual(events, [.microphoneDisconnected(RecordingIssue(code: "capture.mic", message: "disconnected"))])
    }

    func testFailureFromEitherSourceEndsTheSessionAndStopsBothBackends() async throws {
        let system = FakeAudioBackend()
        let microphone = FakeAudioBackend()
        let service = AudioCaptureService(backends: [system, microphone])
        try await service.start()

        microphone.terminate(.microphoneDisconnected(RecordingIssue(code: "capture.mic", message: "disconnected")))
        var events: [CaptureTermination] = []
        for await event in service.terminations {
            events.append(event)
        }
        // stop() waits for the shared backend shutdown started by the failure.
        await service.stop()

        XCTAssertEqual(events, [.microphoneDisconnected(RecordingIssue(code: "capture.mic", message: "disconnected"))])
        XCTAssertEqual(system.stopCount, 1)
        XCTAssertEqual(microphone.stopCount, 1)
    }

    func testFailedSecondBackendStopsTheFirstAndReportsTheError() async {
        let system = FakeAudioBackend()
        let microphone = FakeAudioBackend(startError: CaptureServiceError.microphoneUnavailable)
        let service = AudioCaptureService(backends: [system, microphone])

        do {
            try await service.start()
            XCTFail("Expected microphone startup failure")
        } catch let error as CaptureServiceError {
            XCTAssertEqual(error, .microphoneUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(system.startCount, 1)
        XCTAssertEqual(system.stopCount, 1)
    }

    func testStartupFailurePreservesDiagnosticInBothStreams() async {
        let message = "System audio capture could not create process tap (OSStatus 1852797029)."
        let failure = CaptureServiceError.streamFailure(message)
        let backend = FakeAudioBackend(startError: failure)
        let service = AudioCaptureService(backends: [backend])

        do {
            try await service.start()
            XCTFail("Expected tap creation failure")
        } catch {
            XCTAssertEqual(error as? CaptureServiceError, failure)
        }

        do {
            for try await _ in service.packets {
                XCTFail("A failed startup must not produce audio")
            }
            XCTFail("Expected packet stream failure")
        } catch {
            XCTAssertEqual(error as? CaptureServiceError, failure)
        }

        var events: [CaptureTermination] = []
        for await event in service.terminations {
            events.append(event)
        }
        XCTAssertEqual(events, [.unexpected(RecordingIssue(
            code: "capture.stream-failed",
            message: message,
            isRetryAllowed: true
        ))])
        XCTAssertEqual(backend.stopCount, 1)
    }

    func testDeniedSystemAudioProducesActionableTermination() async {
        let backend = FakeAudioBackend(startError: CaptureServiceError.systemAudioDenied)
        let service = AudioCaptureService(backends: [backend])
        do {
            try await service.start()
            XCTFail("Expected system audio denial")
        } catch {
            // The termination stream carries the actionable issue.
        }

        var events: [CaptureTermination] = []
        for await event in service.terminations {
            events.append(event)
        }
        guard case let .systemAudioDenied(issue)? = events.first else {
            return XCTFail("Expected systemAudioDenied, got \(events)")
        }
        XCTAssertEqual(issue.code, "capture.system-audio-denied")
        XCTAssertEqual(issue.recoveryURL, CaptureSettingsLinks.systemAudio)
        XCTAssertTrue(issue.message.contains("System Audio Recording Only"))
    }

    private func packet(time: TimeInterval) -> CapturedAudioPacket {
        CapturedAudioPacket(
            source: .system,
            presentationTime: time,
            sampleRate: 48000,
            channelCount: 2,
            frameCount: 1,
            samples: [0, 0]
        )
    }
}

private final class FakeAudioBackend: AudioCaptureBackend {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private let startError: Error?
    private var terminationHandler: ((CaptureTermination) -> Void)?
    private var packetHandler: ((CapturedAudioPacket) -> Void)?

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func start(
        onPacket: @escaping (CapturedAudioPacket) -> Void,
        onTermination: @escaping (CaptureTermination) -> Void
    ) async throws {
        startCount += 1
        packetHandler = onPacket
        terminationHandler = onTermination
        if let startError {
            throw startError
        }
    }

    func stop() async {
        stopCount += 1
    }

    func terminate(_ termination: CaptureTermination) {
        terminationHandler?(termination)
    }

    func emit(_ packet: CapturedAudioPacket) {
        packetHandler?(packet)
    }
}

private final class SlowStartingBackend: AudioCaptureBackend {
    let startEntered = XCTestExpectation(description: "backend start entered")
    private(set) var captureStartCount = 0
    private(set) var stopCount = 0

    func start(
        onPacket _: @escaping (CapturedAudioPacket) -> Void,
        onTermination _: @escaping (CaptureTermination) -> Void
    ) async throws {
        startEntered.fulfill()
        try await Task.sleep(nanoseconds: 5_000_000_000)
        try Task.checkCancellation()
        captureStartCount += 1
    }

    func stop() async {
        stopCount += 1
    }
}
