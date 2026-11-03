import AVFoundation
@testable import Noty
import XCTest

final class TranscriptionViewTests: XCTestCase {
    func testImportedAudioAcceptsMonoAACAt44100Hz() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("voice-note.m4a")
        try writeMonoAAC(at: url)

        let duration = try await TranscriptionAudioImport.duration(at: url)

        XCTAssertGreaterThan(duration, 0)
        let audio = try AVAudioFile(forReading: url)
        XCTAssertEqual(audio.processingFormat.sampleRate, 44100)
        XCTAssertEqual(audio.processingFormat.channelCount, 1)
    }

    func testImportedAudioRejectsCorruptM4A() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await TranscriptionAudioImport.duration(at: url)
            XCTFail("A corrupt file must not enter the transcription queue")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not a playable .m4a"))
        }
    }

    private func writeMonoAAC(at url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
        buffer.frameLength = 4410
        let samples = try XCTUnwrap(buffer.floatChannelData).pointee
        for frame in 0 ..< 4410 {
            samples[frame] = Float(0.25 * sin(2 * .pi * 440 * Double(frame) / 44100))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ]
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
        try file?.write(from: buffer)
        file = nil
    }
}
