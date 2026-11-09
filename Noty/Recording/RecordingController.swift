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
    func start(at destinationURL: URL, preferredName: String?) async throws
    func append(_ chunk: MixedAudioChunk) async throws
    func finish() async throws -> RecordingArtifact
    func fail(_ issue: RecordingIssue) async -> RecordingOutcome
    func recoverySessionIdentifier() async -> String?
}

extension RecordingWriting {
    func start(at destinationURL: URL) async throws {
        try await start(at: destinationURL, preferredName: nil)
    }

    func recoverySessionIdentifier() async -> String? {
        nil
    }
}

extension RecordingWriter: RecordingWriting {}

@MainActor
final class RecordingController: ObservableObject {
    typealias CaptureFactory = () -> CaptureService
    typealias WriterFactory = () -> any RecordingWriting
    typealias RecoveryDiscovery = (URL) async -> [RecordingArtifact]

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var elapsedDuration: TimeInterval = 0
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var currentDestinationURL: URL?
    @Published private(set) var lastArtifact: RecordingArtifact?
    @Published private(set) var latestIssue: RecordingIssue?
    @Published private(set) var recoveredRecordings: [RecordingArtifact] = []

    private let permissions: any RecordingPermissionPreparing
    private let destinations: any RecordingDestinationManaging
    private let captureFactory: CaptureFactory
    private let writerFactory: WriterFactory
    private let recoveryDiscovery: RecoveryDiscovery
    private let recoveryNoticeStore: any RecoveryNoticeStoring
    private let transcriptions: (any RecordingTranscriptionScheduling)?
    private let meetingNames: any MeetingNameProviding
    private var destinationLease: DestinationLease?
    private var capture: CaptureService?
    private var writer: (any RecordingWriting)?
    private var mixer = AudioMixer()
    private var startTask: Task<Void, Never>?
    private var captureTask: Task<AudioMixer, Never>?
    private var terminationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var levelPublishTask: Task<Void, Never>?
    private var finalizationTask: Task<RecordingOutcome, Never>?
    private var lastOutcome: RecordingOutcome?
    private var pendingFailure: (issue: RecordingIssue, state: RecordingState)?
    private var recordingStartTime: TimeInterval?
    private var pausedDuration: TimeInterval = 0
    private var pauseStartedAt: TimeInterval?
    private var pauseGate: RecordingPauseGate?
    private let clock: () -> TimeInterval
    private var heardSources: Set<AudioSource> = []
    private var startedRecoverySessions: Set<String> = []
    private var stopRequested = false
    private var didBootstrap = false
    private var lifecycleRevision: UInt64 = 0
    private let audioMeter = RecordingAudioMeter()

    init(
        permissions: any RecordingPermissionPreparing = PermissionCoordinator(),
        destinations: any RecordingDestinationManaging = RecordingDestinationStore(),
        captureFactory: @escaping CaptureFactory = { AudioCaptureService() },
        writerFactory: @escaping WriterFactory = { RecordingWriter() },
        recoveryDiscovery: @escaping RecoveryDiscovery = { folder in
            await RecoverySegmentStore.discoverOrphanedArtifacts(
                in: folder,
                validator: MediaValidator(),
                fileSystem: LocalRecordingMediaFileSystem()
            )
        },
        recoveryNoticeStore: any RecoveryNoticeStoring = RecoveryNoticeStore(),
        transcriptions: (any RecordingTranscriptionScheduling)? = nil,
        meetingNames: any MeetingNameProviding = NoMeetingName(),
        clock: @escaping () -> TimeInterval = RecordingClock.now
    ) {
        self.permissions = permissions
        self.destinations = destinations
        self.captureFactory = captureFactory
        self.writerFactory = writerFactory
        self.recoveryDiscovery = recoveryDiscovery
        self.recoveryNoticeStore = recoveryNoticeStore
        self.transcriptions = transcriptions
        self.meetingNames = meetingNames
        self.clock = clock
    }

    var canStart: Bool {
        state == .idle || state == .interrupted || state == .failed
    }

    var canPause: Bool {
        state == .recording
    }

    var canResume: Bool {
        state == .paused
    }

    var canStop: Bool {
        state == .recording || state == .paused
    }

    var canChooseDestination: Bool {
        canStart
    }

    var hasActiveRecording: Bool {
        state == .starting || state == .recording || state == .paused || state == .stopping
    }

    var destinationDisplayPath: String {
        currentDestinationURL?.path ?? "~/Music/Noty"
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        let revision = lifecycleRevision
        let isInitialIdle = state == .idle && revision == 0
        do {
            let lease = try destinations.resolveCurrentDestination()
            defer { lease.close() }
            if isInitialIdle {
                currentDestinationURL = lease.url
            }
            let recoveries = await recoveryDiscovery(lease.url)
            guard currentDestinationURL == nil || currentDestinationURL == lease.url else { return }
            for artifact in recoveries {
                let identifier = artifact.recoveryIdentifier
                guard !recoveryNoticeStore.isAcknowledged(identifier),
                      !startedRecoverySessions.contains(identifier),
                      !recoveredRecordings.contains(where: { $0.recoveryIdentifier == identifier }) else { continue }
                recoveredRecordings.append(artifact)
            }
            // Discovery may finish after a new recording starts. Keep old sessions available without
            // replacing the active recording's state, issue, or latest saved file.
            guard isInitialIdle, lifecycleRevision == revision else { return }
            if let artifact = recoveredRecordings.max(by: { $0.duration < $1.duration }) {
                lastArtifact = artifact
                updateRecoveryNotice()
            }
        } catch {
            guard isInitialIdle, lifecycleRevision == revision else { return }
            latestIssue = issue(from: error)
        }
    }

    func start() async {
        guard canStart else { return }
        lifecycleRevision += 1
        stopRequested = false
        pendingFailure = nil
        finalizationTask = nil
        lastOutcome = nil
        latestIssue = nil
        heardSources = []
        elapsedDuration = 0
        pausedDuration = 0
        pauseStartedAt = nil
        state = .starting
        startAudioLevelPublishing()
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
        if canStop {
            _ = await requestFinalization(issue: nil, terminalState: nil)
        } else if state == .stopping, let finalizationTask {
            _ = await finalizationTask.value
        }
    }

    /// Stops writing audio. Capture keeps running so resuming needs no new permission prompt or tap.
    func pause() {
        guard canPause, let pauseGate else { return }
        let now = clock()
        pauseGate.pause(at: now)
        pauseStartedAt = now
        state = .paused
        refreshElapsedDuration()
    }

    func resume() {
        guard canResume, let pauseGate, let pauseStartedAt else { return }
        let now = clock()
        pauseGate.resume(at: now)
        pausedDuration += max(0, now - pauseStartedAt)
        self.pauseStartedAt = nil
        state = .recording
        refreshElapsedDuration()
    }

    func finishForTermination() async -> Bool {
        if state == .starting || state == .recording || state == .paused {
            await stop()
        }
        if state == .stopping, let finalizationTask {
            _ = await finalizationTask.value
        }
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
            lifecycleRevision += 1
            currentDestinationURL = lease.url
            lease.close()
            latestIssue = nil
        } catch {
            let issue = issue(from: error)
            if issue.code != "destination-selection-cancelled" {
                latestIssue = issue
            }
        }
    }

    func revealLastRecordingInFinder() {
        guard let lastArtifact else { return }
        revealRecordingInFinder(lastArtifact)
    }

    func revealRecordingInFinder(_ artifact: RecordingArtifact) {
        NSWorkspace.shared.activateFileViewerSelecting(artifact.fileURLs)
    }

    func recordingURLs(for issue: RecordingIssue) -> [URL] {
        guard let url = issue.recoveryURL, url.isFileURL else { return [] }
        let artifacts = recoveredRecordings + [lastArtifact].compactMap { $0 }
        return artifacts.first(where: { $0.fileURLs.contains(url) })?.fileURLs ?? [url]
    }

    func openIssueAction(_ issue: RecordingIssue) {
        guard let url = issue.recoveryURL else { return }
        if url.isFileURL {
            NSWorkspace.shared.activateFileViewerSelecting(recordingURLs(for: issue))
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func dismissRecovery(_ artifact: RecordingArtifact) {
        recoveryNoticeStore.acknowledge(artifact.recoveryIdentifier)
        recoveredRecordings.removeAll { $0.recoveryIdentifier == artifact.recoveryIdentifier }
        if latestIssue?.code == "recording.recovery-found" {
            updateRecoveryNotice()
        }
    }

    private func updateRecoveryNotice() {
        guard !recoveredRecordings.isEmpty else {
            latestIssue = nil
            return
        }
        latestIssue = RecordingIssue(
            code: "recording.recovery-found",
            message: "Audio from an earlier recording is available. Review the recovered recordings below. "
                + "Each recording may contain several audio files. Dismissing this notice keeps the audio.",
            recoveryURL: recoveredRecordings.first?.url
        )
    }
}

extension RecordingController {
    private func startOperation() async {
        do {
            try await transcriptions?.suspendForRecording()
            guard !stopRequested else { await cancelStartup(); return }
            _ = try await permissions.prepareForRecording()
            guard !stopRequested else { await cancelStartup(); return }

            let lease = try destinations.resolveCurrentDestination()
            destinationLease = lease
            currentDestinationURL = lease.url
            guard !stopRequested else { await cancelStartup(); return }

            let meetingName = await meetingNames.meetingName(at: Date())
            guard !stopRequested else { await cancelStartup(); return }

            let writer = writerFactory()
            self.writer = writer
            try await writer.start(at: lease.url, preferredName: meetingName)
            if let identifier = await writer.recoverySessionIdentifier() {
                startedRecoverySessions.insert(identifier)
            }
            guard !stopRequested else { await cancelStartup(); return }

            let capture = captureFactory()
            self.capture = capture
            startCaptureTasks(capture, writer: writer)
            try await capture.start()
            if let pendingFailure {
                throw pendingFailure.issue
            }
            guard !stopRequested else { await cancelStartup(); return }
            state = .recording
            recordingStartTime = clock()
            startElapsedTimer()
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
        stopAudioLevelPublishing()
        timerTask?.cancel()
        captureTask?.cancel()
        terminationTask?.cancel()
        if let capture {
            await capture.stop()
        }
        _ = await captureTask?.value
        if let writer {
            _ = await writer.fail(RecordingIssue(
                code: "recording.start-cancelled",
                message: "Recording startup was cancelled.",
                isRetryAllowed: true
            ))
        }
        destinationLease?.close()
        destinationLease = nil
        capture = nil
        writer = nil
        captureTask = nil
        terminationTask?.cancel()
        terminationTask = nil
        recordingStartTime = nil
        resetPauseTracking()
        elapsedDuration = 0
        lastOutcome = nil
        pendingFailure = nil
        state = .idle
        transcriptions?.resumeAfterRecording()
    }

    private func failStartup(_ issue: RecordingIssue) async {
        stopAudioLevelPublishing()
        timerTask?.cancel()
        captureTask?.cancel()
        terminationTask?.cancel()
        if let capture {
            await capture.stop()
        }
        _ = await captureTask?.value
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
        transcriptions?.resumeAfterRecording()
    }

    private func startCaptureTasks(_ capture: CaptureService, writer: any RecordingWriting) {
        let packets = capture.packets
        // UI work must not stall the bounded audio stream.
        let revision = lifecycleRevision
        let gate = RecordingPauseGate()
        pauseGate = gate
        captureTask = Task.detached(priority: .userInitiated) { [weak self, meter = audioMeter] in
            guard let self else { return AudioMixer() }
            return await self.consumePackets(
                from: packets, writer: writer, revision: revision, meter: meter, pauseGate: gate
            )
        }
        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.consumeTerminations(from: capture)
        }
    }

    private nonisolated func consumePackets(
        from packets: AsyncThrowingStream<CapturedAudioPacket, Error>,
        writer: any RecordingWriting,
        revision: UInt64,
        meter: RecordingAudioMeter,
        pauseGate: RecordingPauseGate
    ) async -> AudioMixer {
        var mixer = AudioMixer()
        let normalizer = AudioNormalizer()
        var systemSilence = AudioSilenceMonitor(source: .system)
        var microphoneSilence = AudioSilenceMonitor(source: .microphone)
        var isPaused = false
        var failure: Error?
        do {
            for try await packet in packets {
                // Paused audio is not silence; the monitors only see audio that is written, on the written timeline.
                if case let .keep(shift) = pauseGate.disposition(for: packet.presentationTime) {
                    let timed = shift > 0 ? packet.shifted(by: shift) : packet
                    observeSilence(timed, with: &systemSilence, revision: revision)
                    observeSilence(timed, with: &microphoneSilence, revision: revision)
                }
                // Normalize every packet, paused or not, so the converter's state stays continuous.
                try await appendNormalizedPackets(
                    normalizer.normalize(packet),
                    to: &mixer,
                    writer: writer,
                    meter: meter,
                    pauseGate: pauseGate,
                    isPaused: &isPaused
                )
            }
        } catch {
            failure = error
        }
        // Drain converter look-ahead on Stop or capture interruption, never after a writer/audio failure.
        let canDrain = failure.map { RecordingIssueMapper.issue(from: $0).code.hasPrefix("capture.") } ?? true
        if !Task.isCancelled, canDrain {
            do {
                try await appendNormalizedPackets(
                    normalizer.finish(),
                    to: &mixer,
                    writer: writer,
                    meter: meter,
                    pauseGate: pauseGate,
                    isPaused: &isPaused
                )
            } catch {
                failure = error
            }
        }
        await captureEnded(error: failure)
        return mixer
    }

    private nonisolated func appendNormalizedPackets(
        _ packets: [NormalizedAudioPacket],
        to mixer: inout AudioMixer,
        writer: any RecordingWriting,
        meter: RecordingAudioMeter,
        pauseGate: RecordingPauseGate,
        isPaused: inout Bool
    ) async throws {
        for packet in packets {
            switch pauseGate.disposition(for: packet.presentationTime) {
            case .drop:
                guard !isPaused else { continue }
                isPaused = true
                // Write what is buffered so the audio just before the pause is on disk, not held for resume.
                let chunks = try mixer.flush()
                try await appendChunks(chunks, writer: writer, meter: meter)
            case let .keep(shift):
                isPaused = false
                let timed = shift > 0 ? packet.shifted(by: shift) : packet
                // #region agent log
                if AgentDebugLog.shouldEmit("controller.normalized.\(packet.source.rawValue)") {
                    AgentDebugLog.log(
                        "RecordingController.appendNormalizedPackets",
                        "normalized packet to mixer",
                        hypothesis: "B,C",
                        [
                            "source": packet.source.rawValue, "pts": timed.presentationTime, "shift": shift,
                            "frames": packet.frameCount, "rmsL": AgentDebugLog.rms(
                                packet.samples,
                                channels: 2,
                                channel: 0
                            ),
                            "rmsR": AgentDebugLog.rms(packet.samples, channels: 2, channel: 1)
                        ]
                    )
                }
                // #endregion
                let chunks = try mixer.append(timed)
                try await appendChunks(chunks, writer: writer, meter: meter)
            }
        }
    }

    private nonisolated func appendChunks(
        _ chunks: [MixedAudioChunk],
        writer: any RecordingWriting,
        meter: RecordingAudioMeter
    ) async throws {
        for chunk in chunks {
            meter.observe(samples: chunk.samples)
            try await writer.append(chunk)
        }
    }

    private nonisolated func observeSilence(
        _ packet: CapturedAudioPacket,
        with monitor: inout AudioSilenceMonitor,
        revision: UInt64
    ) {
        let source = monitor.source
        let hadAudio = monitor.heardAudio
        if monitor.observe(packet) {
            Task { await self.updateSilenceStatus(source: source, isAudible: false, revision: revision) }
        } else if !hadAudio, monitor.heardAudio {
            Task { await self.updateSilenceStatus(source: source, isAudible: true, revision: revision) }
        }
    }

    /// UI notices must never hold up the bounded audio stream.
    private func updateSilenceStatus(source: AudioSource, isAudible: Bool, revision: UInt64) {
        guard lifecycleRevision == revision else { return }
        let warning = Self.silenceWarning(for: source)
        if isAudible {
            heardSources.insert(source)
            if latestIssue?.code == warning.code {
                latestIssue = nil
            }
            return
        }
        guard state == .recording, !heardSources.contains(source), latestIssue == nil else { return }
        latestIssue = warning
    }

    private static func silenceWarning(for source: AudioSource) -> RecordingIssue {
        switch source {
        case .system:
            RecordingIssue(
                code: "capture.system-audio-silent",
                message: """
                No system audio has been detected yet. If something is playing, allow Noty in System Settings → \
                Privacy & Security → System Audio Recording Only. Microphone recording is continuing.
                """,
                recoveryURL: CaptureSettingsLinks.systemAudio,
                isRetryAllowed: true
            )
        case .microphone:
            RecordingIssue(
                code: "capture.microphone-silent",
                message: """
                No sound has been detected from the microphone yet. Check that the microphone chosen in Noty \
                Settings is the one you are using and that it isn’t muted. System audio recording is continuing.
                """,
                isRetryAllowed: true
            )
        }
    }

    private func captureEnded(error: Error? = nil) {
        guard !Task.isCancelled else { return }
        if let error {
            guard isCapturing || state == .stopping else { return }
            let issue = issue(from: error)
            scheduleFinalization(issue: issue, terminalState: terminalState(for: issue))
        } else if isCapturing {
            scheduleFinalization(
                issue: RecordingIssue(
                    code: "capture.ended",
                    message: "Audio capture stopped unexpectedly.",
                    isRetryAllowed: true
                ),
                terminalState: .interrupted
            )
        }
    }

    private func consumeTerminations(from capture: CaptureService) async {
        for await termination in capture.terminations {
            let issue: RecordingIssue
            switch termination {
            case .userStopped:
                guard state == .recording || state == .paused else { continue }
                issue = RecordingIssue(
                    code: "capture.ended",
                    message: "Audio capture stopped unexpectedly.",
                    isRetryAllowed: true
                )
            case let .systemAudioDenied(value), let .interrupted(value), let .microphoneDisconnected(value),
                 let .unexpected(value),
                 let .queueOverflow(value):
                issue = self.issue(from: value)
            }
            guard isCapturing || state == .stopping else { return }
            scheduleFinalization(issue: issue, terminalState: terminalState(for: issue))
            return
        }
    }

    private func scheduleFinalization(issue: RecordingIssue, terminalState: RecordingState) {
        if state == .starting {
            pendingFailure = pendingFailure ?? (issue, terminalState)
            return
        }
        pendingFailure = (issue, terminalState)
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.requestFinalization(issue: issue, terminalState: terminalState)
        }
    }

    private func requestFinalization(issue: RecordingIssue?, terminalState: RecordingState?) async -> RecordingOutcome {
        if let issue, let terminalState {
            pendingFailure = (issue, terminalState)
        }
        if let finalizationTask {
            return await finalizationTask.value
        }
        guard writer != nil || capture != nil else {
            let issue = issue ?? RecordingIssue(
                code: "recording.not-active",
                message: "There is no active recording to finalize."
            )
            return .failed(issue)
        }
        state = .stopping
        timerTask?.cancel()
        stopAudioLevelPublishing()
        refreshElapsedDuration()
        let task = Task<RecordingOutcome, Never> { @MainActor [weak self] in
            guard let self else {
                return RecordingOutcome.failed(RecordingIssue(
                    code: "recording.controller-unavailable",
                    message: "Recording finalization could not finish."
                ))
            }
            return await self.performFinalization(issue: issue, terminalState: terminalState)
        }
        finalizationTask = task
        return await task.value
    }

    private func performFinalization(issue initialIssue: RecordingIssue?,
                                     terminalState initialState: RecordingState?) async -> RecordingOutcome {
        if let capture {
            await capture.stop()
        }
        if let captureTask {
            mixer = await captureTask.value
        }
        terminationTask?.cancel()
        terminationTask = nil

        let finalIssue = initialIssue ?? pendingFailure?.issue
        let finalState = initialState ?? pendingFailure?.state
        let outcome: RecordingOutcome
        if let finalIssue {
            if finalState == .interrupted, let writer, let trailingChunks = try? mixer.finish() {
                for chunk in trailingChunks {
                    try? await writer.append(chunk)
                }
            }
            outcome = await writer?.fail(finalIssue) ?? .failed(finalIssue)
        } else if let writer {
            do {
                for chunk in try mixer.finish() {
                    try await writer.append(chunk)
                }
                outcome = try .saved(await writer.finish())
            } catch {
                let failure = issue(from: error)
                let failedOutcome = await writer.fail(failure)
                pendingFailure = (failure, .failed)
                if case let .saved(artifact) = failedOutcome {
                    await transcriptions?.enqueueRecording(artifact)
                }
                apply(failedOutcome, terminalState: .failed)
                releaseRecordingResources()
                lastOutcome = failedOutcome
                return failedOutcome
            }
        } else {
            let failure = RecordingIssue(code: "writer.not-active", message: "The recording writer is unavailable.")
            outcome = .failed(failure)
        }

        if case let .saved(artifact) = outcome {
            await transcriptions?.enqueueRecording(artifact)
        }
        apply(outcome, terminalState: finalState)
        releaseRecordingResources()
        lastOutcome = outcome
        return outcome
    }

    private func apply(_ outcome: RecordingOutcome, terminalState: RecordingState?) {
        switch outcome {
        case let .saved(artifact):
            lastArtifact = artifact
            latestIssue = nil
            state = .idle
        case let .partial(artifact, issue):
            if let artifact {
                lastArtifact = artifact
                recoveredRecordings.removeAll { $0.recoveryIdentifier == artifact.recoveryIdentifier }
                recoveredRecordings.append(artifact)
            }
            latestIssue = self.issue(from: issue)
            state = terminalState ?? .interrupted
        case let .failed(issue):
            latestIssue = self.issue(from: issue.withRecordingURL(nil))
            state = terminalState ?? .failed
        }
    }

    private func releaseRecordingResources() {
        destinationLease?.close()
        destinationLease = nil
        capture = nil
        writer = nil
        captureTask = nil
        recordingStartTime = nil
        resetPauseTracking()
        mixer = AudioMixer()
        stopAudioLevelPublishing()
        transcriptions?.resumeAfterRecording()
    }

    private var isCapturing: Bool {
        state == .starting || state == .recording || state == .paused
    }

    /// Active recording time: wall time since start, minus every completed pause and any pause in progress.
    private func refreshElapsedDuration() {
        guard let recordingStartTime else { return }
        let now = clock()
        let currentPause = pauseStartedAt.map { max(0, now - $0) } ?? 0
        elapsedDuration = max(0, now - recordingStartTime - pausedDuration - currentPause)
    }

    private func resetPauseTracking() {
        pausedDuration = 0
        pauseStartedAt = nil
        pauseGate = nil
    }

    private func startElapsedTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.recordingStartTime != nil else { return }
                self.refreshElapsedDuration()
            }
        }
    }

    private func startAudioLevelPublishing() {
        levelPublishTask?.cancel()
        audioMeter.reset()
        audioLevel = 0
        levelPublishTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                guard let self, self.isCapturing else { return }
                self.audioLevel = Double(self.audioMeter.sampleAndDecay())
            }
        }
    }

    private func stopAudioLevelPublishing() {
        levelPublishTask?.cancel()
        levelPublishTask = nil
        audioMeter.reset()
        audioLevel = 0
    }

    private func terminalState(for issue: RecordingIssue) -> RecordingState {
        issue.code.hasPrefix("capture.") ? .interrupted : .failed
    }

    private func issue(from error: Error) -> RecordingIssue {
        RecordingIssueMapper.issue(from: error)
    }
}
