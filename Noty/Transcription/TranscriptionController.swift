import AppKit
import Combine
import Foundation

@MainActor
protocol RecordingTranscriptionScheduling: AnyObject {
    func suspendForRecording() async throws
    func enqueueRecording(_ artifact: RecordingArtifact) async
    func resumeAfterRecording()
}

@MainActor
final class TranscriptionController: ObservableObject, RecordingTranscriptionScheduling {
    let playback: AudioPlaybackController
    @Published private(set) var jobs: [TranscriptionJob] = []
    @Published private(set) var modelState: TranscriptionModelState = .notInstalled
    @Published private(set) var automaticEnabled = false
    @Published private(set) var isRecording = false
    @Published private(set) var progress: Double?
    @Published private(set) var progressMessage: String?
    @Published private(set) var issue: String?
    @Published private(set) var deletingJobID: UUID?

    private let store: TranscriptionFileStore
    private let worker: any TranscriptionWorkerRunning
    private let trashItem: (URL) throws -> Void
    @Published private var didBootstrap = false
    private var persistenceBlocked = false
    private var isSuspending = false
    private var isTerminating = false
    private var generation = UUID()
    private var activeJobID: UUID?
    private var workTask: Task<Void, Never>?

    init(store: TranscriptionFileStore = TranscriptionFileStore(),
         worker: (any TranscriptionWorkerRunning)? = nil,
         playback: AudioPlaybackController? = nil,
         trashItem: @escaping (URL) throws -> Void = {
             try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
         }) {
        self.store = store
        self.worker = worker ?? TranscriptionWorkerProcess()
        self.playback = playback ?? AudioPlaybackController()
        self.trashItem = trashItem
    }

    var canPrepareModels: Bool {
        didBootstrap && !isRecording && workTask == nil && !persistenceBlocked && deletingJobID == nil
    }

    var canImport: Bool {
        !persistenceBlocked && !isTerminating && deletingJobID == nil
    }

    var canDeleteJobs: Bool {
        canImport && !isSuspending
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            if let snapshot = try store.load(TranscriptionSnapshot.self) {
                guard snapshot.version == 1 else { throw TranscriptionError.invalidQueue }
                jobs = snapshot.jobs.map { job in
                    var job = job
                    if job.status.isRunning {
                        job.status = .waiting
                    }
                    return job
                }
                modelState = snapshot.modelsReady ? .ready : .notInstalled
                automaticEnabled = snapshot.automaticEnabled
            }
            persist()
            pump()
        } catch {
            persistenceBlocked = true
            issue = TranscriptionError.invalidQueue.localizedDescription
        }
    }

    func setAutomaticEnabled(_ enabled: Bool) {
        guard modelState == .ready, !persistenceBlocked else { return }
        automaticEnabled = enabled
        persist()
    }

    func prepareModels() {
        guard canPrepareModels else { return }
        modelState = .preparing
        issue = nil
        persist()
        let token = generation
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await invoke(phase: .prepare, jobID: UUID(), inputURL: nil, token: token)
                guard generation == token else { return }
                modelState = .ready
                automaticEnabled = true
                for index in jobs.indices where jobs[index].requiresModelRepair && jobs[index].status != .cancelled {
                    jobs[index].requiresModelRepair = false
                    jobs[index].message = nil
                    jobs[index].status = .waiting
                }
            } catch {
                guard generation == token else { return }
                modelState = .needsRepair
                issue = error.localizedDescription
            }
            finishWork(token: token)
        }
    }

    func cancelModelPreparation() async {
        guard modelState == .preparing else { return }
        await interrupt(requeue: true)
    }

    func enqueueRecording(_ artifact: RecordingArtifact) async {
        guard automaticEnabled, artifact.kind == .recording else { return }
        do {
            let bookmark = try artifact.url.deletingLastPathComponent().bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
            )
            await enqueue(sourceURL: artifact.url, duration: artifact.duration, folderBookmark: bookmark)
        } catch {
            issue = "The recording was saved, but Noty could not retain folder access for transcription. "
                + "Import it again."
        }
    }

    func enqueue(sourceURL: URL, duration: TimeInterval, folderBookmark: Data?) async {
        await bootstrap()
        guard !persistenceBlocked else { return }
        do {
            guard sourceURL.pathExtension.lowercased() == "m4a", duration.isFinite, duration > 0 else {
                throw TranscriptionError.sourceChanged
            }
            let identity = try TranscriptionSourceIdentity(url: sourceURL)
            if jobs.contains(where: {
                $0.sourceURL.standardizedFileURL == sourceURL.standardizedFileURL && $0.identity == identity
                    && $0.status != .cancelled
            }) {
                return
            }
            jobs.append(TranscriptionJob(sourceURL: sourceURL, folderBookmark: folderBookmark,
                                         identity: identity, duration: duration))
            persist()
            pump()
        } catch { issue = error.localizedDescription }
    }

    func reportImportError(_ message: String) {
        issue = message
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].canRetry,
              !persistenceBlocked else { return }
        jobs[index].status = .waiting
        if jobs[index].pendingExportText == nil {
            jobs[index].message = nil
        }
        persist()
        pump()
    }

    func cancel(_ id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].canCancel else { return }
        jobs[index].status = .cancelled
        jobs[index].message = nil
        if activeJobID == id {
            await interrupt(requeue: false)
        }
        persist()
        pump()
    }

    func delete(_ id: UUID) async {
        guard canDeleteJobs, let selected = jobs.first(where: { $0.id == id }) else { return }
        let relatedIDs = Set(jobs.filter {
            $0.sourceURL.standardizedFileURL == selected.sourceURL.standardizedFileURL
        }.map(\.id))
        deletingJobID = id
        issue = nil
        defer {
            deletingJobID = nil
            pump()
        }
        guard persist() else { return }
        if let playingID = playback.activeID, relatedIDs.contains(playingID) {
            playback.stop()
        }

        do {
            if let activeID = activeJobID, relatedIDs.contains(activeID) {
                let task = workTask
                try await worker.stop()
                if activeJobID == activeID {
                    modify(activeID) { $0.status = .cancelled }
                    invalidateWork(requeue: false)
                }
                // A detached staging copy must finish before its job directory can be removed.
                await task?.value
            }
            guard !isTerminating, !persistenceBlocked,
                  let job = jobs.first(where: { $0.id == id }) else { return }
            let access = try resolveSource(job)
            defer { access.lease.close() }
            guard !persistenceBlocked else { return }
            try trashRecordingFiles(source: access.url, identity: job.identity,
                                    relatedJobs: jobs.filter { relatedIDs.contains($0.id) })

            let previousJobs = jobs
            jobs.removeAll { relatedIDs.contains($0.id) }
            guard persist() else {
                jobs = previousJobs
                return
            }
            for jobID in relatedIDs {
                try? store.removeJob(jobID: jobID)
            }
        } catch {
            issue = "Could not move the recording and transcript to Trash: \(error.localizedDescription)"
        }
    }

    private func trashRecordingFiles(source: URL, identity: TranscriptionSourceIdentity,
                                     relatedJobs: [TranscriptionJob]) throws {
        let files = FileManager.default
        if files.fileExists(atPath: source.path) {
            guard try TranscriptionSourceIdentity(url: source) == identity else {
                throw TranscriptionError.sourceChanged
            }
            try trashItem(source)
        }
        let folder = source.deletingLastPathComponent()
        var transcripts = Set(relatedJobs.compactMap(\.lastExport).map {
            folder.appendingPathComponent($0.url.lastPathComponent)
        })
        for job in relatedJobs {
            guard let reserved = job.exportReservation else { continue }
            let url = folder.appendingPathComponent(reserved.url.lastPathComponent)
            if store.matchesExport(reserved, at: url) {
                transcripts.insert(url)
            }
        }
        for transcript in transcripts.sorted(by: { $0.path < $1.path })
            where files.fileExists(atPath: transcript.path) {
            try trashItem(transcript)
        }
    }

    func suspendForRecording() async throws {
        isRecording = true
        playback.stop()
        await bootstrap()
        isSuspending = true
        defer { isSuspending = false }
        invalidateWork(requeue: true)
        do { try await worker.stop() } catch {
            throw RecordingIssue(code: "transcription.worker-stop-failed", message: error.localizedDescription,
                                 isRetryAllowed: true)
        }
    }

    func resumeAfterRecording() {
        isRecording = false
        pump()
    }

    func prepareForTermination() async {
        isTerminating = true
        playback.stop()
        await bootstrap()
        await interrupt(requeue: true)
        persist()
    }

    func cancelTermination() {
        isTerminating = false
        pump()
    }

    func togglePlayback(_ job: TranscriptionJob) {
        guard !isRecording, !isTerminating, deletingJobID == nil else { return }
        playback.toggle(id: job.id) { try resolveSource(job) }
    }

    func openTranscript(_ job: TranscriptionJob) {
        withFolderAccess(job) { source in
            guard let output = job.lastExport?.url else { return }
            let relocated = source.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent)
            NSWorkspace.shared.open(relocated)
        }
    }

    func revealTranscript(_ job: TranscriptionJob) {
        withFolderAccess(job) { source in
            let name = job.lastExport?.url.lastPathComponent ?? source.lastPathComponent
            NSWorkspace.shared.activateFileViewerSelecting([
                source.deletingLastPathComponent().appendingPathComponent(name)
            ])
        }
    }

    private func pump() {
        guard didBootstrap, !isRecording, !isSuspending, !isTerminating, !persistenceBlocked,
              deletingJobID == nil,
              modelState == .ready, workTask == nil,
              let id = jobs.first(where: { $0.status == .waiting })?.id else { return }
        activeJobID = id
        let token = generation
        workTask = Task { [weak self] in
            guard let self else { return }
            await process(id: id, token: token)
            finishWork(token: token)
        }
    }

    private func process(id: UUID, token: UUID) async {
        guard let initial = jobs.first(where: { $0.id == id }) else { return }
        do {
            let access = try resolveSource(initial)
            defer { access.lease.close() }
            let source = access.url
            guard try TranscriptionSourceIdentity(url: source) == initial.identity else {
                throw TranscriptionError.sourceChanged
            }
            if let pending = initial.pendingExportText, let status = initial.pendingCompletionStatus {
                try publish(id: id, source: source, text: pending, status: status, message: initial.message)
                return
            }
            let fileStore = store
            let staged = try await Task.detached(priority: .utility) {
                try fileStore.stage(source: source, jobID: id)
            }.value
            try check(token)
            let textSegments = try await transcribe(id: id, source: staged, token: token)
            try check(token)
            var speakers: [SpeakerInterval] = []
            var warning: String?
            if initial.duration > 7200 {
                warning = "Speaker labels unavailable: recordings longer than two hours receive text only."
            } else if !textSegments.isEmpty {
                update(id, status: .identifyingSpeakers)
                do {
                    speakers = try await invoke(phase: .diarize, jobID: id, inputURL: staged,
                                                token: token).speakers
                } catch {
                    try check(token)
                    warning = "Speaker labels unavailable. \(error.localizedDescription)"
                    if case let TranscriptionError.workerFailed(_, needsRepair) = error, needsRepair {
                        modelState = .needsRepair
                        modify(id) { $0.requiresModelRepair = true }
                    }
                }
            }
            try check(token)
            let speakerIntervals = speakers
            let speakerWarning = warning
            let text = await Task.detached(priority: .utility) {
                TranscriptFormatter.format(segments: textSegments, speakers: speakerIntervals,
                                           speakerWarning: speakerWarning)
            }.value
            try check(token)
            try publish(id: id, source: source, text: text,
                        status: warning == nil || initial.duration > 7200 ? .complete : .needsAttention,
                        message: warning)
        } catch {
            guard generation == token else {
                if jobs.first(where: { $0.id == id })?.status == .cancelled {
                    try? store.removeStaging(jobID: id)
                }
                return
            }
            if case let TranscriptionError.workerFailed(_, needsRepair) = error, needsRepair {
                modelState = .needsRepair
                modify(id) { $0.requiresModelRepair = true }
            }
            modify(id) {
                $0.status = .needsAttention
                $0.message = error.localizedDescription
            }
            persist()
        }
    }

    private func transcribe(id: UUID, source: URL, token: UUID) async throws -> [TranscriptSegment] {
        if let segments = try store.readCheckpoint(jobID: id) {
            return segments
        }
        update(id, status: .transcribing)
        let result = try await invoke(phase: .transcribe, jobID: id, inputURL: source, token: token)
        try check(token)
        try store.writeCheckpoint(segments: result.segments, jobID: id)
        return result.segments
    }

    private func publish(id: UUID, source: URL, text: String, status: TranscriptionJobStatus,
                         message: String?) throws {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        var reservation: ExportReservation
        if let reserved = job.exportReservation, job.pendingExportText == text {
            reservation = reserved
        } else {
            reservation = try store.reserveExport(sourceURL: source, text: text, previous: job.lastExport)
        }
        // Persist the exact rendered text as well as the path. Speaker clustering can vary on retry.
        modify(id) {
            $0.exportReservation = reservation
            $0.pendingExportText = text
            $0.pendingCompletionStatus = status
            $0.message = message
        }
        guard persist() else { return }
        do {
            try store.publish(text: text, reservation: reservation)
        } catch TranscriptionFileStore.StoreError.exportChanged {
            reservation = try store.reserveExport(sourceURL: source, text: text, previous: job.lastExport)
            modify(id) { $0.exportReservation = reservation }
            guard persist() else { return }
            try store.publish(text: text, reservation: reservation)
        }
        modify(id) {
            $0.lastExport = reservation
            $0.pendingExportText = nil
            $0.pendingCompletionStatus = nil
            $0.status = status
            $0.message = message
        }
        if persist() {
            try? store.removeStaging(jobID: id)
        }
    }

    private func invoke(phase: TranscriptionPhase, jobID: UUID, inputURL: URL?, token: UUID) async throws
        -> TranscriptionWorkerResult {
        try check(token)
        let attempt = UUID()
        let resultURL = store.jobDirectory(id: jobID).appendingPathComponent("result-\(attempt).json")
        let request = TranscriptionWorkerRequest(jobID: jobID, attemptID: attempt, phase: phase,
                                                 inputURL: inputURL, modelsURL: store.modelsURL,
                                                 resultURL: resultURL, parentPID: getpid())
        let result = try await worker.run(request) { [weak self] event in
            guard let self, generation == token else { return }
            progress = event.fraction
            progressMessage = event.message
        }
        try check(token)
        return result
    }

    private func resolveSource(_ job: TranscriptionJob) throws -> (url: URL, lease: DestinationLease) {
        var folder = job.sourceURL.deletingLastPathComponent()
        guard let bookmark = job.folderBookmark else {
            return (job.sourceURL, DestinationLease(url: folder, releaseAccess: nil))
        }
        var stale = false
        folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                         relativeTo: nil, bookmarkDataIsStale: &stale)
        guard folder.startAccessingSecurityScopedResource() else {
            throw RecordingIssue(code: "transcription.folder-access", message:
                "Noty cannot access this recording folder. Import the file and allow folder access again.")
        }
        let lease = DestinationLease(url: folder, releaseAccess: { folder.stopAccessingSecurityScopedResource() })
        if stale {
            let refreshed = try folder.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil, relativeTo: nil)
            modify(job.id) { $0.folderBookmark = refreshed }
            persist()
        }
        let resolvedSource = folder.appendingPathComponent(job.sourceURL.lastPathComponent)
        if resolvedSource != job.sourceURL {
            modify(job.id) {
                $0.sourceURL = resolvedSource
                if let previous = $0.lastExport {
                    $0.lastExport?.url = folder.appendingPathComponent(previous.url.lastPathComponent)
                }
                if let reserved = $0.exportReservation {
                    $0.exportReservation?.url = folder.appendingPathComponent(reserved.url.lastPathComponent)
                }
            }
            persist()
        }
        return (resolvedSource, lease)
    }

    private func withFolderAccess(_ job: TranscriptionJob, action: (URL) -> Void) {
        do {
            let access = try resolveSource(job)
            defer { access.lease.close() }
            action(access.url)
        } catch { issue = error.localizedDescription }
    }

    private func update(_ id: UUID, status: TranscriptionJobStatus) {
        modify(id) { $0.status = status }
        progress = nil
        progressMessage = nil
        persist()
    }

    private func modify(_ id: UUID, _ change: (inout TranscriptionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    @discardableResult
    private func persist() -> Bool {
        guard didBootstrap, !persistenceBlocked else { return false }
        do {
            try store.save(TranscriptionSnapshot(automaticEnabled: automaticEnabled,
                                                 modelsReady: modelState == .ready, jobs: jobs))
            return true
        } catch {
            persistenceBlocked = true
            issue = "Noty could not save the transcription queue. Check available disk space and reopen Noty."
            return false
        }
    }

    private func check(_ token: UUID) throws {
        guard token == generation, !isRecording, !isTerminating, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func invalidateWork(requeue: Bool) {
        generation = UUID()
        workTask?.cancel()
        workTask = nil
        if requeue, let activeJobID {
            modify(activeJobID) {
                if $0.status.isRunning {
                    $0.status = .waiting
                }
            }
        }
        activeJobID = nil
        if modelState == .preparing {
            modelState = .notInstalled
        }
        progress = nil
        progressMessage = nil
        persist()
    }

    private func interrupt(requeue: Bool) async {
        isSuspending = true
        invalidateWork(requeue: requeue)
        do { try await worker.stop() } catch { issue = error.localizedDescription }
        isSuspending = false
    }

    private func finishWork(token: UUID) {
        guard generation == token else { return }
        workTask = nil
        activeJobID = nil
        progress = nil
        progressMessage = nil
        persist()
        pump()
    }
}
