import AVFoundation
import Foundation
import XCTest
@testable import Noty

@MainActor
final class RecordingPipelineIntegrationTests: XCTestCase {
    func testSixtySecondCaptureProducesPlayableMixedAACWithSourceAudioAndSilenceGap() async throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Noty-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let capture = FakeCaptureService()
        let controller = RecordingController(
            permissions: IntegrationPermissions(),
            destinations: IntegrationDestinations(url: destinationURL),
            captureFactory: { capture },
            writerFactory: { RecordingWriter() },
            recoveryDiscovery: { _ in [] }
        )
        await controller.start()
        XCTAssertEqual(controller.state, .recording)

        let packetFrames = 4_800
        for index in 0..<600 {
            guard !(3...5).contains(index) else { continue }
            let presentationTime = Double(index) / 10
            let overloadedMix = index >= 6
            capture.emit(packet(
                source: .system,
                time: presentationTime,
                frames: packetFrames,
                frequency: 440,
                amplitude: overloadedMix ? 1 : 0.7
            ))
            try await Task.sleep(nanoseconds: 5_000_000)
            capture.emit(packet(
                source: .microphone,
                time: presentationTime,
                frames: packetFrames,
                frequency: index < 3 ? 880 : (overloadedMix ? 440 : 880),
                amplitude: overloadedMix ? 1 : 0.5
            ))
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await controller.stop()

        XCTAssertEqual(controller.state, .idle)
        let artifact = try XCTUnwrap(controller.lastArtifact)
        XCTAssertEqual(artifact.kind, .recording)
        XCTAssertEqual(artifact.duration, 60, accuracy: 0.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
        let validatedDuration = try await MediaValidator().validate(url: artifact.url)
        XCTAssertEqual(validatedDuration, 60, accuracy: 0.1)

        let file = try AVAudioFile(forReading: artifact.url)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let frameCount = Int(buffer.frameLength)
        let channel = try XCTUnwrap(buffer.floatChannelData).pointee
        let samples = UnsafeBufferPointer(start: channel, count: frameCount)

        XCTAssertGreaterThan(spectralAmplitude(samples, in: 4_800..<14_400, frequency: 440), 0.2)
        XCTAssertGreaterThan(spectralAmplitude(samples, in: 4_800..<14_400, frequency: 880), 0.1)
        XCTAssertLessThan(rootMeanSquare(samples, in: 19_200..<24_000), 0.01)
        XCTAssertLessThanOrEqual(peak(samples), 0.92)
    }

    private func packet(source: AudioSource, time: Double, frames: Int, frequency: Double, amplitude: Double) -> CapturedAudioPacket {
        var samples: [Float] = []
        samples.reserveCapacity(frames * 2)
        for frame in 0..<frames {
            let instant = time + Double(frame) / AudioFormat.sampleRate
            let sample = Float(amplitude * sin(2 * Double.pi * frequency * instant))
            samples.append(sample)
            samples.append(sample)
        }
        return CapturedAudioPacket(
            source: source,
            presentationTime: time,
            sampleRate: AudioFormat.sampleRate,
            channelCount: AudioFormat.channelCount,
            frameCount: frames,
            samples: samples
        )
    }

    private func spectralAmplitude(_ samples: UnsafeBufferPointer<Float>, in range: Range<Int>, frequency: Double) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for frame in range {
            let phase = 2 * Double.pi * frequency * Double(frame) / AudioFormat.sampleRate
            real += Double(samples[frame]) * cos(phase)
            imaginary -= Double(samples[frame]) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(range.count)
    }

    private func rootMeanSquare(_ samples: UnsafeBufferPointer<Float>, in range: Range<Int>) -> Double {
        let power = range.reduce(0.0) { $0 + Double(samples[$1]) * Double(samples[$1]) }
        return sqrt(power / Double(range.count))
    }

    private func peak(_ samples: UnsafeBufferPointer<Float>) -> Double {
        samples.reduce(0.0) { max($0, abs(Double($1))) }
    }
}

@MainActor
private struct IntegrationPermissions: RecordingPermissionPreparing {
    func prepareForRecording() async throws -> PermissionGrant {
        PermissionGrant(microphone: true, screenRecording: true)
    }
}

@MainActor
private struct IntegrationDestinations: RecordingDestinationManaging {
    let url: URL
    func resolveCurrentDestination() throws -> DestinationLease { DestinationLease(url: url, releaseAccess: nil) }
    func chooseFolder() throws -> DestinationLease { DestinationLease(url: url, releaseAccess: nil) }
}
