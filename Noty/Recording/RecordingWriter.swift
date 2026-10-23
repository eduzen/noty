import AVFoundation
import Foundation

actor RecordingWriter {
    private enum State { case idle, active, finishing, finished(RecordingArtifact), failed(RecordingOutcome) }

    private let factory: RecordingMediaWriterFactory
    private let validator: RecordingMediaValidating
    private let fileSystem: RecordingMediaFileSystem
    private let recoverySegmentDuration: TimeInterval
    private let now: () -> Date
    private var state: State = .idle
    private var writer: RecordingMediaWriter?
    private var temporaryURL: URL?
    private var recoveryStore: RecoverySegmentStore?
    private var destinationFolder: URL?
    private var lastPresentationTime: TimeInterval?
    private var finishTask: Task<RecordingArtifact, Error>?
    private var failTask: Task<RecordingOutcome, Never>?
    private let maximumChunkFrames = Int(AudioFormat.sampleRate * 5)
    private let maximumPendingBytes = 64 * 1024 * 1024

    init(factory: RecordingMediaWriterFactory = AVRecordingMediaWriterFactory(),
         validator: RecordingMediaValidating = MediaValidator(),
         fileSystem: RecordingMediaFileSystem = LocalRecordingMediaFileSystem(),
         recoverySegmentDuration: TimeInterval = 30,
         now: @escaping () -> Date = Date.init) {
        self.factory = factory
        self.validator = validator
        self.fileSystem = fileSystem
        self.recoverySegmentDuration = recoverySegmentDuration
        self.now = now
    }

    func start(at destinationURL: URL) async throws {
        guard case .idle = state else {
            throw issue("writer.invalid-state", "The recording writer has already been started.")
        }
        do {
            try fileSystem.createDirectory(at: destinationURL)
            destinationFolder = destinationURL
            let id = UUID().uuidString
            let temp = destinationURL.appendingPathComponent(".noty-\(id).tmp.m4a")
            let recoveryDirectory = destinationURL.appendingPathComponent(".noty-recovery-\(id)", isDirectory: true)
            try fileSystem.createDirectory(at: recoveryDirectory)
            writer = try factory.makeWriter(at: temp)
            temporaryURL = temp
            recoveryStore = RecoverySegmentStore(directoryURL: recoveryDirectory, factory: factory,
                                                 fileSystem: fileSystem, segmentDuration: recoverySegmentDuration)
            state = .active
        } catch {
            throw asIssue(error, code: "writer.start-failed", message: "Noty could not start the recording.")
        }
    }

    func append(_ chunk: MixedAudioChunk) async throws {
        guard case .active = state, let writer else {
            throw issue("writer.not-active", "Audio cannot be appended after recording has stopped.")
        }
        let bytes = chunk.samples.count * MemoryLayout<Float>.size
        guard chunk.frameCount <= maximumChunkFrames, bytes <= maximumPendingBytes else {
            throw issue("writer.overflow", "The recording writer could not keep up with incoming audio.")
        }
        guard chunk.sampleRate == AudioFormat.sampleRate, chunk.channelCount == AudioFormat.channelCount,
              chunk.frameCount > 0, chunk.samples.count == chunk.frameCount * AudioFormat.channelCount,
              chunk.presentationTime.isFinite,
              lastPresentationTime.map({ chunk.presentationTime >= $0 }) ?? true else {
            throw issue("writer.invalid-chunk", "The audio chunk is malformed or out of order.")
        }
        do {
            try writer.append(chunk)
            try await recoveryStore?.append(chunk)
            lastPresentationTime = chunk.presentationTime
        } catch {
            throw asIssue(error, code: "writer.write-failed", message: "Noty could not write the recording.", url: temporaryURL)
        }
    }

    func finish() async throws -> RecordingArtifact {
        if case .finished(let artifact) = state { return artifact }
        if case .failed(.partial(_, let issue)) = state { throw issue }
        if case .failed(.failed(let issue)) = state { throw issue }
        if case .finishing = state {
            if let finishTask { return try await finishTask.value }
            if let failTask {
                let outcome = await failTask.value
                if case .saved(let artifact) = outcome { return artifact }
                throw outcome.issueOrFallback
            }
        }
        guard case .active = state else {
            throw issue("writer.not-active", "There is no active recording to finish.")
        }
        state = .finishing
        let task = Task { try await self.finalize() }
        finishTask = task
        return try await task.value
    }

    func fail(_ issue: RecordingIssue) async -> RecordingOutcome {
        if case .finished(let artifact) = state { return .saved(artifact) }
        if case .failed(let outcome) = state { return outcome }
        if case .finishing = state {
            if let finishTask {
                do { return .saved(try await finishTask.value) }
                catch {
                    if case .failed(let outcome) = state { return outcome }
                    return .failed(issue)
                }
            }
            if let failTask { return await failTask.value }
        }
        guard case .active = state else { return .failed(issue) }
        state = .finishing
        let task = Task { await self.performFailure(issue) }
        failTask = task
        return await task.value
    }

    private func finalize() async throws -> RecordingArtifact {
        guard let writer, let temporaryURL, let destinationFolder else {
            let error = issue("writer.invalid-state", "The recording writer could not finalize its output.")
            state = .failed(.failed(error))
            finishTask = nil
            throw error
        }
        do {
            try await writer.finish()
            self.writer = nil
            try await recoveryStore?.closeCurrent()
            let validatedDuration = try await validator.validate(url: temporaryURL)
            let finalURL = uniqueFinalURL(in: destinationFolder)
            try fileSystem.moveItem(at: temporaryURL, to: finalURL)
            let artifact = RecordingArtifact(url: finalURL, kind: .recording, duration: validatedDuration)
            state = .finished(artifact)
            try? recoveryStore?.cleanup()
            finishTask = nil
            return artifact
        } catch {
            let issue = asIssue(error, code: "writer.finalize-failed", message: "Noty could not validate or save the recording.", url: temporaryURL)
            let outcome = await recover(issue)
            state = .failed(outcome)
            finishTask = nil
            throw issue
        }
    }

    private func performFailure(_ issue: RecordingIssue) async -> RecordingOutcome {
        let outcome = await recover(issue)
        state = .failed(outcome)
        failTask = nil
        return outcome
    }


    private func recover(_ issue: RecordingIssue) async -> RecordingOutcome {
        writer?.cancel()
        writer = nil
        await recoveryStore?.closeBestEffort()
        var candidates: [(URL, TimeInterval)] = []
        if let temporaryURL, let time = try? await validator.validate(url: temporaryURL) {
            candidates.append((temporaryURL, time))
        }
        for url in recoveryStore?.completedURLs ?? [] {
            if let time = try? await validator.validate(url: url) { candidates.append((url, time)) }
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 }) else { return .failed(issue) }
        let kind: RecordingArtifact.Kind = best.0 == temporaryURL ? .recording : .recovery
        return .partial(RecordingArtifact(url: best.0, kind: kind, duration: best.1), issue)
    }

    private func uniqueFinalURL(in folder: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        var url = folder.appendingPathComponent("Noty-\(formatter.string(from: now())).m4a")
        while fileSystem.fileExists(at: url) { url = folder.appendingPathComponent("Noty-\(formatter.string(from: now()))-\(UUID().uuidString.prefix(8)).m4a") }
        return url
    }

    private func issue(_ code: String, _ message: String) -> RecordingIssue {
        RecordingIssue(code: code, message: message, isRetryAllowed: false)
    }

    private func asIssue(_ error: Error, code: String, message: String, url: URL? = nil) -> RecordingIssue {
        if let issue = error as? RecordingIssue { return issue }
        return RecordingIssue(code: code, message: "\(message) \(error.localizedDescription)", recoveryURL: url, isRetryAllowed: true)
    }
}

struct AVRecordingMediaWriterFactory: RecordingMediaWriterFactory {
    func makeWriter(at url: URL) throws -> RecordingMediaWriter { try AVRecordingMediaWriter(url: url) }
}

private final class AVRecordingMediaWriter: RecordingMediaWriter {
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private var finished = false

    init(url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFormat.sampleRate,
                                         channels: AVAudioChannelCount(AudioFormat.channelCount), interleaved: false) else {
            throw RecordingIssue(code: "writer.format", message: "The recording audio format is unavailable.")
        }
        self.format = format
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                       AVSampleRateKey: AudioFormat.sampleRate,
                                       AVNumberOfChannelsKey: AudioFormat.channelCount,
                                       AVEncoderBitRateKey: 192_000]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ chunk: MixedAudioChunk) throws {
        guard !finished, let file,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.frameCount)),
              let channels = buffer.floatChannelData else {
            throw RecordingIssue(code: "writer.buffer", message: "The recording audio buffer could not be allocated.")
        }
        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)
        for frame in 0..<chunk.frameCount {
            channels[0][frame] = chunk.samples[frame * 2]
            channels[1][frame] = chunk.samples[frame * 2 + 1]
        }
        try file.write(from: buffer)
    }

    func finish() async throws { finished = true; file = nil }
    func cancel() { finished = true; file = nil }
}
private extension RecordingOutcome {
    var issueOrFallback: RecordingIssue {
        switch self {
        case .saved:
            return RecordingIssue(code: "writer.already-saved", message: "The recording was already saved.")
        case .partial(_, let issue), .failed(let issue):
            return issue
        }
    }
}
