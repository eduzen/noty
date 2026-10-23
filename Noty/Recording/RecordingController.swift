import AppKit
import Combine
import Foundation

@MainActor
protocol RecordingPermissionPreparing {
    func prepareForRecording() async throws -> PermissionGrant
}

extension PermissionCoordinator: RecordingPermissionPreparing {}

@MainActor
protocol RecordingDestinationManaging {
    func resolveCurrentDestination() throws -> DestinationLease
    func chooseFolder() throws -> DestinationLease
}

extension RecordingDestinationStore: RecordingDestinationManaging {}

protocol RecordingWriting: Sendable {
    func start(at destinationURL: URL) async throws
    func append(_ chunk: MixedAudioChunk) async throws
    func finish() async throws -> RecordingArtifact
    func fail(_ issue: RecordingIssue) async -> RecordingOutcome
}

extension RecordingWriter: RecordingWriting {}

@MainActor
final class RecordingController: ObservableObject {
    typealias CaptureFactory = () -> CaptureService
    typealias WriterFactory = () -> any RecordingWriting
    typealias RecoveryDiscovery = (URL) async -> [RecordingArtifact]

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var elapsedDuration: TimeInterval = 0
    @Published private(set) var currentDestinationURL: URL?
    @Published private(set) var lastArtifact: RecordingArtifact?
    @Published private(set) var latestIssue: RecordingIssue?

    private let permissions: any RecordingPermissionPreparing
    private let destinations: any RecordingDestinationManaging
    private let captureFactory: CaptureFactory
    private let writerFactory: WriterFactory
    private let recoveryDiscovery: RecoveryDiscovery
    private var destinationLease: DestinationLease?
    private var capture: CaptureService?
    private var writer: (any RecordingWriting)?
    private var mixer = AudioMixer()
    private var startTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var finalizationTask: Task<RecordingOutcome, Never>?
    private var lastOutcome: RecordingOutcome?
    private var pendingFailure: (issue: RecordingIssue, state: RecordingState)?
    private var recordingStartUptime: TimeInterval?
    private var stopRequested = false
    private var didBootstrap = false

    init(
        permissions: any RecordingPermissionPreparing = PermissionCoordinator(),
        destinations: any RecordingDestinationManaging = RecordingDestinationStore(),
        captureFactory: @escaping CaptureFactory = { ScreenCaptureService() },
        writerFactory: @escaping WriterFactory = { RecordingWriter() },
        recoveryDiscovery: @escaping RecoveryDiscovery = { folder in
            await RecoverySegmentStore.discoverOrphanedArtifacts(
                in: folder,
                validator: MediaValidator(),
                fileSystem: LocalRecordingMediaFileSystem()
            )
        }
    ) {
        self.permissions = permissions
        self.destinations = destinations
        self.captureFactory = captureFactory
        self.writerFactory = writerFactory
        self.recoveryDiscovery = recoveryDiscovery
    }

    var canStart: Bool { state == .idle || state == .interrupted || state == .failed }
    var canStop: Bool { state == .recording }
    var canChooseDestination: Bool { canStart }
    var hasActiveRecording: Bool { state == .starting || state == .recording || state == .stopping }
    var destinationDisplayPath: String { currentDestinationURL?.path ?? "~/Music/Noty" }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            let lease = try destinations.resolveCurrentDestination()
            currentDestinationURL = lease.url
            let recoveries = await recoveryDiscovery(lease.url)
            lease.close()
            if let artifact = recoveries.max(by: { $0.duration < $1.duration }) {
                lastArtifact = artifact
                latestIssue = RecordingIssue(
                    code: "recording.recovery-found",
                    message: "Noty found a recoverable recording segment at \(artifact.url.path).",
                    recoveryURL: artifact.url,
                    isRetryAllowed: false
                )
                state = .interrupted
            }
        } catch {
            latestIssue = issue(from: error)
        }
    }

    func start() async {
        guard canStart else { return }
        stopRequested = false
        pendingFailure = nil
        finalizationTask = nil
        lastOutcome = nil
        latestIssue = nil
        elapsedDuration = 0
        state = .starting
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startOperation()
        }
        startTask = task
        await task.value
        startTask = nil
    }

    func stop() async {
        if state == .starting {
            stopRequested = true
            await startTask?.value
        }
        if state == .recording {
            _ = await requestFinalization(issue: nil, terminalState: nil)
        } else if state == .stopping, let finalizationTask {
            _ = await finalizationTask.value
        }
    }

    func finishForTermination() async -> Bool {
        if state == .starting || state == .recording { await stop() }
        if state == .stopping, let finalizationTask { _ = await finalizationTask.value }
        guard let lastOutcome else { return true }
        switch lastOutcome {
        case .saved, .partial: return true
        case .failed: return false
        }
    }

    func chooseDestination() {
        guard canChooseDestination else { return }
        do {
            let lease = try destinations.chooseFolder()
            currentDestinationURL = lease.url
            lease.close()
            latestIssue = nil
        } catch {
            let issue = issue(from: error)
            if issue.code != "destination-selection-cancelled" { latestIssue = issue }
        }
    }

    func revealLastRecordingInFinder() {
        guard let lastArtifact else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastArtifact.url])
    }

    private func startOperation() async {
        do {
            _ = try await permissions.prepareForRecording()
            guard !stopRequested else { await cancelStartup(); return }

            let lease = try destinations.resolveCurrentDestination()
            destinationLease = lease
            currentDestinationURL = lease.url
            guard !stopRequested else { await cancelStartup(); return }

            let writer = writerFactory()
            self.writer = writer
            try await writer.start(at: lease.url)
            guard !stopRequested else { await cancelStartup(); return }

            let capture = captureFactory()
            self.capture = capture
            try await capture.start()
            state = .recording
            recordingStartUptime = ProcessInfo.processInfo.systemUptime
            startElapsedTimer()
            startCaptureTasks(capture)
        } catch {
            if stopRequested {
                await cancelStartup()
            } else {
                await failStartup(issue(from: error))
            }
        }
    }

    private func cancelStartup() async {
        state = .stopping
        timerTask?.cancel()
        if let capture { await capture.stop() }
        if let writer {
            _ = await writer.fail(RecordingIssue(code: "recording.start-cancelled", message: "Recording startup was cancelled.", isRetryAllowed: true))
        }
        destinationLease?.close()
        destinationLease = nil
        capture = nil
        writer = nil
        captureTask = nil
        terminationTask?.cancel()
        terminationTask = nil
        recordingStartUptime = nil
        elapsedDuration = 0
        lastOutcome = nil
        pendingFailure = nil
        state = .idle
    }

    private func failStartup(_ issue: RecordingIssue) async {
        timerTask?.cancel()
        if let capture { await capture.stop() }
        let outcome = await writer?.fail(issue)
        if let outcome {
            apply(outcome, terminalState: terminalState(for: issue))
        } else {
            latestIssue = issue
            state = terminalState(for: issue)
        }
        destinationLease?.close()
        destinationLease = nil
        capture = nil
        writer = nil
        captureTask = nil
        terminationTask?.cancel()
        terminationTask = nil
    }

    private func startCaptureTasks(_ capture: CaptureService) {
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.consumePackets(from: capture)
        }
        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.consumeTerminations(from: capture)
        }
    }

    private func consumePackets(from capture: CaptureService) async {
        do {
            for try await packet in capture.packets {
                try await process(packet)
            }
            if state == .recording {
                scheduleFinalization(
                    issue: RecordingIssue(code: "capture.ended", message: "Audio capture stopped unexpectedly.", isRetryAllowed: true),
                    terminalState: .interrupted
                )
            }
        } catch {
            if state == .recording || state == .stopping {
                let issue = issue(from: error)
                scheduleFinalization(issue: issue, terminalState: terminalState(for: issue))
            }
        }
    }

    private func consumeTerminations(from capture: CaptureService) async {
        for await termination in capture.terminations {
            let issue: RecordingIssue
            switch termination {
            case .userStopped:
                guard state == .recording else { continue }
                issue = RecordingIssue(code: "capture.ended", message: "Audio capture stopped unexpectedly.", isRetryAllowed: true)
            case .screenRecordingDenied(let value), .interrupted(let value), .microphoneDisconnected(let value), .unexpected(let value), .queueOverflow(let value):
                issue = value
            }
            guard state == .recording || state == .stopping else { return }
            scheduleFinalization(issue: issue, terminalState: terminalState(for: issue))
            return
        }
    }

    private func process(_ packet: CapturedAudioPacket) async throws {
        let normalized = try AudioNormalizer().normalize(packet)
        let chunks = try mixer.append(normalized)
        guard let writer else {
            throw RecordingIssue(code: "writer.not-active", message: "The recording writer is unavailable.", isRetryAllowed: false)
        }
        for chunk in chunks { try await writer.append(chunk) }
    }

    private func scheduleFinalization(issue: RecordingIssue, terminalState: RecordingState) {
        pendingFailure = (issue, terminalState)
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.requestFinalization(issue: issue, terminalState: terminalState)
        }
    }

    private func requestFinalization(issue: RecordingIssue?, terminalState: RecordingState?) async -> RecordingOutcome {
        if let issue, let terminalState { pendingFailure = (issue, terminalState) }
        if let finalizationTask { return await finalizationTask.value }
        guard writer != nil || capture != nil else {
            let issue = issue ?? RecordingIssue(code: "recording.not-active", message: "There is no active recording to finalize.")
            return .failed(issue)
        }
        state = .stopping
        timerTask?.cancel()
        if let recordingStartUptime {
            elapsedDuration = max(0, ProcessInfo.processInfo.systemUptime - recordingStartUptime)
        }
        let task = Task<RecordingOutcome, Never> { @MainActor [weak self] in
            guard let self else {
                return RecordingOutcome.failed(RecordingIssue(code: "recording.controller-unavailable", message: "Recording finalization could not finish."))
            }
            return await self.performFinalization(issue: issue, terminalState: terminalState)
        }
        finalizationTask = task
        return await task.value
    }

    private func performFinalization(issue initialIssue: RecordingIssue?, terminalState initialState: RecordingState?) async -> RecordingOutcome {
        if let capture { await capture.stop() }
        if let captureTask { await captureTask.value }
        terminationTask?.cancel()
        terminationTask = nil

        let finalIssue = initialIssue ?? pendingFailure?.issue
        let finalState = initialState ?? pendingFailure?.state
        let outcome: RecordingOutcome
        if let finalIssue {
            if finalState == .interrupted, let writer, let trailingChunks = try? mixer.finish() {
                for chunk in trailingChunks { try? await writer.append(chunk) }
            }
            outcome = await writer?.fail(finalIssue) ?? .failed(finalIssue)
        } else if let writer {
            do {
                for chunk in try mixer.finish() { try await writer.append(chunk) }
                outcome = .saved(try await writer.finish())
            } catch {
                let failure = issue(from: error)
                let failedOutcome = await writer.fail(failure)
                pendingFailure = (failure, .failed)
                apply(failedOutcome, terminalState: .failed)
                releaseRecordingResources()
                lastOutcome = failedOutcome
                return failedOutcome
            }
        } else {
            let failure = RecordingIssue(code: "writer.not-active", message: "The recording writer is unavailable.")
            outcome = .failed(failure)
        }

        apply(outcome, terminalState: finalState)
        releaseRecordingResources()
        lastOutcome = outcome
        return outcome
    }

    private func apply(_ outcome: RecordingOutcome, terminalState: RecordingState?) {
        switch outcome {
        case .saved(let artifact):
            lastArtifact = artifact
            latestIssue = nil
            state = .idle
        case .partial(let artifact, let issue):
            if let artifact { lastArtifact = artifact }
            latestIssue = issue
            state = terminalState ?? .interrupted
        case .failed(let issue):
            latestIssue = issue
            state = terminalState ?? .failed
        }
    }

    private func releaseRecordingResources() {
        destinationLease?.close()
        destinationLease = nil
        capture = nil
        writer = nil
        captureTask = nil
        recordingStartUptime = nil
        mixer = AudioMixer()
    }

    private func startElapsedTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let self, let start = self.recordingStartUptime else { return }
                self.elapsedDuration = max(0, ProcessInfo.processInfo.systemUptime - start)
            }
        }
    }

    private func terminalState(for issue: RecordingIssue) -> RecordingState {
        issue.code.hasPrefix("capture.") || issue.code.hasPrefix("permission.screen-recording") ? .interrupted : .failed
    }

    private func issue(from error: Error) -> RecordingIssue {
        if let issue = error as? RecordingIssue { return issue }
        if let error = error as? AudioPipelineError {
            switch error {
            case .malformedPacket(let message): return RecordingIssue(code: "audio.malformed-packet", message: message, isRetryAllowed: true)
            case .unsupportedFormat(let message): return RecordingIssue(code: "audio.unsupported-format", message: message, isRetryAllowed: true)
            case .conversionFailed(let message): return RecordingIssue(code: "audio.conversion-failed", message: message, isRetryAllowed: true)
            case .timingDiscontinuity(let message): return RecordingIssue(code: "audio.timing-discontinuity", message: message, isRetryAllowed: false)
            case .queueOverflow: return RecordingIssue(code: "audio.queue-overflow", message: "Audio processing exceeded its bounded buffer.", isRetryAllowed: false)
            }
        }
        if let error = error as? CaptureServiceError {
            switch error {
            case .screenRecordingDenied: return RecordingIssue(code: "capture.screen-recording-denied", message: "Screen Recording permission is required.", recoveryURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"), isRetryAllowed: true)
            case .noMainDisplay: return RecordingIssue(code: "capture.main-display-unavailable", message: "Noty could not resolve the main display for audio capture.", isRetryAllowed: true)
            case .microphoneUnavailable: return RecordingIssue(code: "capture.microphone-unavailable", message: "No default microphone is available.", isRetryAllowed: true)
            case .invalidAudioFormat: return RecordingIssue(code: "capture.invalid-audio", message: "ScreenCaptureKit returned an unsupported audio format.", isRetryAllowed: false)
            case .queueOverflow: return RecordingIssue(code: "capture.queue-overflow", message: "Audio capture exceeded its bounded buffer.", isRetryAllowed: false)
            case .streamFailure(let message): return RecordingIssue(code: "capture.stream-failed", message: message, isRetryAllowed: true)
            case .alreadyStarted, .notStarted: return RecordingIssue(code: "capture.lifecycle-error", message: error.localizedDescription, isRetryAllowed: true)
            }
        }
        return RecordingIssue(code: "recording.failed", message: error.localizedDescription, isRetryAllowed: true)
    }
}
