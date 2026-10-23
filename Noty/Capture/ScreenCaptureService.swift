import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

protocol ScreenCaptureBackend: AnyObject {
    func start(onPacket: @escaping (CapturedAudioPacket) -> Void, onTermination: @escaping (CaptureTermination) -> Void) async throws
    func stop() async
}

final class ScreenCaptureService: CaptureService {
    let packets: AsyncThrowingStream<CapturedAudioPacket, Error>
    let terminations: AsyncStream<CaptureTermination>

    private let packetContinuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation
    private let terminationContinuation: AsyncStream<CaptureTermination>.Continuation
    private let backend: ScreenCaptureBackend
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var startupTask: Task<Void, Error>?
    private var backendStopTask: Task<Void, Never>?
    init(backend: ScreenCaptureBackend = ScreenCaptureKitBackend()) {
        let (packets, packetContinuation) = AsyncThrowingStream<CapturedAudioPacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(3))
        let (terminations, terminationContinuation) = AsyncStream<CaptureTermination>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.packets = packets
        self.packetContinuation = packetContinuation
        self.terminations = terminations
        self.terminationContinuation = terminationContinuation
        self.backend = backend
    }

    func start() async throws {
        let task: Task<Void, Error>? = withLock {
            guard !started, !stopped else { return nil }
            started = true
            let task = Task { [weak self] in
                guard let self else { return }
                try await backend.start(onPacket: { [weak self] packet in
                    guard let self else { return }
                    switch packetContinuation.yield(packet) {
                    case .enqueued: break
                    case .dropped:
                        terminate(with: .queueOverflow(RecordingIssue(code: "capture.queue-overflow", message: "Audio capture exceeded its bounded buffer.", isRetryAllowed: false)))
                    case .terminated: break
                    @unknown default: break
                    }
                }, onTermination: { [weak self] in self?.terminate(with: $0) })
            }
            startupTask = task
            return task
        }
        guard let task else { return }

        do {
            try await task.value
        } catch {
            let shouldFinish = withLock {
                let shouldFinish = !stopped
                stopped = true
                return shouldFinish
            }
            await stopBackendOnce()
            if shouldFinish {
                packetContinuation.finish(throwing: error)
                terminationContinuation.yield(Self.termination(for: error))
                terminationContinuation.finish()
            }
            throw error
        }
    }

    func stop() async {
        let state: (shouldFinish: Bool, shouldStopBackend: Bool, startupTask: Task<Void, Error>?) = withLock {
            let shouldFinish = !stopped
            let shouldStopBackend = started
            stopped = true
            return (shouldFinish, shouldStopBackend, startupTask)
        }
        state.startupTask?.cancel()
        if state.shouldStopBackend {
            if let startupTask = state.startupTask { _ = try? await startupTask.value }
            await stopBackendOnce()
        }
        guard state.shouldFinish else { return }
        packetContinuation.finish()
        terminationContinuation.yield(.userStopped)
        terminationContinuation.finish()
    }

    private func stopBackendOnce() async {
        let task: Task<Void, Never> = withLock {
            if let existingTask = backendStopTask { return existingTask }
            let task = Task { [backend] in await backend.stop() }
            backendStopTask = task
            return task
        }
        await task.value
    }

    private func terminate(with termination: CaptureTermination) {
        let state = withLock {
            let shouldFinish = !stopped
            stopped = true
            return (shouldFinish, startupTask)
        }
        guard state.0 else { return }
        state.1?.cancel()
        packetContinuation.finish(throwing: Self.error(for: termination))
        terminationContinuation.yield(termination)
        terminationContinuation.finish()
        Task {
            if let startupTask = state.1 { _ = try? await startupTask.value }
            await stopBackendOnce()
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }



    private static func termination(for error: Error) -> CaptureTermination {
        if let captureError = error as? CaptureServiceError {
            switch captureError {
            case .screenRecordingDenied:
                return .screenRecordingDenied(RecordingIssue(code: "capture.screen-recording-denied", message: "Screen Recording permission is required to capture audio.", recoveryURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"), isRetryAllowed: true))
            case .microphoneUnavailable:
                return .microphoneDisconnected(RecordingIssue(code: "capture.microphone-unavailable", message: "No default microphone is available.", isRetryAllowed: true))
            case .streamFailure(let message):
                return .unexpected(RecordingIssue(code: "capture.stream-failed", message: message, isRetryAllowed: true))
            case .queueOverflow:
                return .queueOverflow(RecordingIssue(code: "capture.queue-overflow", message: "Audio capture exceeded its bounded buffer.", isRetryAllowed: false))
            case .alreadyStarted, .notStarted, .noMainDisplay, .invalidAudioFormat:
                return .unexpected(RecordingIssue(code: "capture.setup-failed", message: error.localizedDescription, isRetryAllowed: true))
        }
        }
        let mapped = ScreenCaptureError.map(error)
        switch mapped.kind {
        case .permissionDenied: return .screenRecordingDenied(mapped.issue)
        case .interrupted: return .interrupted(mapped.issue)
        case .microphoneDisconnected: return .microphoneDisconnected(mapped.issue)
        case .unexpected: return .unexpected(mapped.issue)
        }
    }

    private static func error(for termination: CaptureTermination) -> Error {
        switch termination {
        case .userStopped: return CancellationError()
        case .screenRecordingDenied(let issue), .interrupted(let issue), .microphoneDisconnected(let issue), .unexpected(let issue), .queueOverflow(let issue): return issue
        }
    }
}

private final class ScreenCaptureKitBackend: NSObject, ScreenCaptureBackend, SCStreamOutput, SCStreamDelegate {
    private let outputQueue = DispatchQueue(label: "noty.capture.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    private var packetHandler: ((CapturedAudioPacket) -> Void)?
    private var terminationHandler: ((CaptureTermination) -> Void)?
    private var microphoneID: String?
    private var stopped = false
    private var cleanupStarted = false
    private var sleepObserver: NSObjectProtocol?
    private var microphoneObserver: NSObjectProtocol?

    func start(onPacket: @escaping (CapturedAudioPacket) -> Void, onTermination: @escaping (CaptureTermination) -> Void) async throws {
        withLock {
            packetHandler = onPacket
            terminationHandler = onTermination
            stopped = false
        }

        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw CaptureServiceError.microphoneUnavailable
        }
        microphoneID = microphone.uniqueID

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { throw CaptureServiceError.noMainDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphone.uniqueID
        configuration.sampleRate = Int(AudioFormat.sampleRate)
        configuration.channelCount = AudioFormat.channelCount

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: outputQueue)
        try Task.checkCancellation()
        try await stream.startCapture()
        installLifecycleObservers()
    }

    func stop() async {
        let state = withLock {
            let shouldStop = !cleanupStarted
            cleanupStarted = true
            stopped = true
            let stream = self.stream
            self.stream = nil
            packetHandler = nil
            terminationHandler = nil
            return (shouldStop, stream)
        }
        guard state.0 else { return }

        removeLifecycleObservers()
        if let stream = state.1 {
            try? stream.removeStreamOutput(self, type: .audio)
            try? stream.removeStreamOutput(self, type: .microphone)
            try? await stream.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        do {
            guard let packet = try Self.copyPacket(sampleBuffer, source: type == .audio ? .system : .microphone) else { return }
            let handler = withLock { stopped ? nil : packetHandler }
            handler?(packet)
        } catch CaptureServiceError.queueOverflow {
            notify(.queueOverflow(RecordingIssue(code: "capture.queue-overflow", message: "Audio capture exceeded its bounded buffer.", isRetryAllowed: false)))
        } catch {
            notify(.unexpected(RecordingIssue(code: "capture.invalid-audio", message: "ScreenCaptureKit returned an invalid audio buffer.", isRetryAllowed: false)))
        }
    }


    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let mapped = ScreenCaptureError.map(error)
        let termination: CaptureTermination
        switch mapped.kind {
        case .permissionDenied: termination = .screenRecordingDenied(mapped.issue)
        case .interrupted: termination = .interrupted(mapped.issue)
        case .microphoneDisconnected: termination = .microphoneDisconnected(mapped.issue)
        case .unexpected: termination = .unexpected(mapped.issue)
        }
        notify(termination)
    }


    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.notify(.interrupted(RecordingIssue(code: "capture.sleep", message: "Audio capture stopped because the Mac is going to sleep.", isRetryAllowed: true)))
        }
        microphoneObserver = center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self,
                  let device = notification.object as? AVCaptureDevice,
                  device.uniqueID == self.microphoneID else { return }
            self.notify(.microphoneDisconnected(RecordingIssue(code: "capture.microphone-disconnected", message: "The microphone was disconnected.", isRetryAllowed: true)))
        }
    }

    private func removeLifecycleObservers() {
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let microphoneObserver { NotificationCenter.default.removeObserver(microphoneObserver) }
        sleepObserver = nil
        microphoneObserver = nil
    }

    private func notify(_ termination: CaptureTermination) {
        let handler: ((CaptureTermination) -> Void)? = withLock {
            guard !stopped else { return nil }
            stopped = true
            return terminationHandler
        }
        handler?(termination)
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
    private static let maximumPacketBytes = 64 * 1024 * 1024 / 5

    private static func copyPacket(_ sampleBuffer: CMSampleBuffer, source: AudioSource) throws -> CapturedAudioPacket? {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mSampleRate.isFinite,
              asbd.mSampleRate > 0 else { throw CaptureServiceError.invalidAudioFormat }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = Int(asbd.mChannelsPerFrame)
        guard frames > 0, channels > 0, channels <= 8 else { throw CaptureServiceError.invalidAudioFormat }
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let expectedBytesPerFrame = isNonInterleaved ? MemoryLayout<Float>.size : channels * MemoryLayout<Float>.size
        guard asbd.mBytesPerFrame == UInt32(expectedBytesPerFrame) else { throw CaptureServiceError.invalidAudioFormat }
        let (sampleCount, sampleCountOverflow) = frames.multipliedReportingOverflow(by: channels)
        let (byteCount, byteCountOverflow) = sampleCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        let (minimumListSize, listSizeOverflow) = channels.multipliedReportingOverflow(by: MemoryLayout<AudioBuffer>.size)
        guard !sampleCountOverflow, !byteCountOverflow, !listSizeOverflow else { throw CaptureServiceError.queueOverflow }
        guard Double(frames) / asbd.mSampleRate <= 1.0, byteCount <= maximumPacketBytes else {
            throw CaptureServiceError.queueOverflow
        }

        var needed = 0
        var retainedBlock: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &retainedBlock)
        guard status == noErr, needed > 0, needed <= 4_096, needed <= minimumListSize + MemoryLayout<AudioBufferList>.size else {
            throw CaptureServiceError.invalidAudioFormat
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &retainedBlock)
        guard status == noErr else { throw CaptureServiceError.invalidAudioFormat }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let bytesPerPlane = frames.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !bytesPerPlane.overflow else { throw CaptureServiceError.queueOverflow }

        if buffers.count == 1, buffers[0].mNumberChannels == UInt32(channels) {
            guard Int(buffers[0].mDataByteSize) >= byteCount, buffers[0].mData != nil else {
                throw CaptureServiceError.invalidAudioFormat
            }
        } else {
            guard buffers.count == channels,
                  buffers.allSatisfy({ $0.mNumberChannels == 1 && Int($0.mDataByteSize) >= bytesPerPlane.partialValue && $0.mData != nil }) else {
                throw CaptureServiceError.invalidAudioFormat
            }
        }

        var samples = [Float]()
        samples.reserveCapacity(sampleCount)
        if buffers.count == 1 {
            let data = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: sampleCount))
        } else {
            for frame in 0..<frames {
                for buffer in buffers {
                    let data = buffer.mData!.assumingMemoryBound(to: Float.self)
                    samples.append(data[frame])
                }
            }
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid, time.isNumeric else { throw CaptureServiceError.invalidAudioFormat }
        return CapturedAudioPacket(source: source, presentationTime: CMTimeGetSeconds(time), sampleRate: asbd.mSampleRate, channelCount: channels, frameCount: frames, samples: samples)
    }
}
