import AVFoundation
import Foundation
import SpeakerKit
import WhisperKit

struct WorkerBackend: Sendable {
    static let whisperVariant = "openai_whisper-large-v3-v20240930_626MB"
    let progress: WorkerProgressEmitter

    func perform(_ request: TranscriptionWorkerRequest) async throws -> TranscriptionWorkerResult {
        Logging.shared.logLevel = .none
        var result = TranscriptionWorkerResult(jobID: request.jobID, attemptID: request.attemptID)
        switch request.phase {
        case .prepare:
            try await prepare(at: request.modelsURL)
        case .validate:
            let assets = try WorkerAssetLocations.current(at: request.modelsURL)
            try await validate(assets)
        case .transcribe:
            result.segments = try await transcribe(request)
        case .diarize:
            result.speakers = try await diarize(request)
        }
        progress.emit(fraction: 1, "Finished")
        return result
    }

    private func prepare(at modelsURL: URL) async throws {
        let setID = UUID()
        let assets = try WorkerAssetLocations.beginPreparation(at: modelsURL, setID: setID)
        let downloads = assets.root.appendingPathComponent("downloads")
        progress.emit(fraction: 0, "Downloading speech model")
        let whisperDownload = try await WhisperKit.download(
            variant: Self.whisperVariant,
            downloadBase: downloads.appendingPathComponent("whisper"),
            progressCallback: { update in
                progress.emit(fraction: update.fractionCompleted * 0.7, "Downloading speech model")
            }
        )
        try FileManager.default.moveItem(at: whisperDownload, to: assets.whisper)
        progress.emit(fraction: 0.7, "Downloading speech tokenizer")
        let tokenizerDownload = try await HubApiWrapper(downloadBase: downloads.appendingPathComponent("tokenizer"))
            .snapshot(
                from: .init(id: "openai/whisper-large-v3"),
                matching: [
                    "tokenizer.json",
                    "tokenizer_config.json",
                    "config.json",
                    "special_tokens_map.json",
                    "added_tokens.json"
                ]
            )
        try FileManager.default.createDirectory(at: assets.tokenizer, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(
            at: tokenizerDownload, includingPropertiesForKeys: [.isRegularFileKey]
        ) where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            try FileManager.default.copyItem(
                at: url,
                to: assets.tokenizer.appendingPathComponent(url.lastPathComponent)
            )
        }
        progress.emit(fraction: 0.75, "Downloading speaker models")
        let downloader = ModelDownloader(config: ModelDownloadConfig(
            downloadBase: downloads.appendingPathComponent("speakers").path,
            modelRepo: "argmaxinc/speakerkit-coreml"
        ))
        let speakerDownload = try await downloader.resolveRepo(
            patterns: [
                ModelInfo.segmenter().downloadPattern,
                ModelInfo.embedder().downloadPattern,
                ModelInfo.plda().downloadPattern
            ],
            progressCallback: { update in
                progress.emit(fraction: 0.75 + update.fractionCompleted * 0.15, "Downloading speaker models")
            }
        )
        try FileManager.default.moveItem(at: speakerDownload, to: assets.speakers)
        try? FileManager.default.removeItem(at: downloads)
        try await validate(assets)
        try assets.publish(at: modelsURL, setID: setID)
    }

    private func validate(_ assets: WorkerAssetLocations) async throws {
        progress.emit("Checking speech models")
        let whisper = try await loadWhisper(assets)
        await whisper.unloadModels()
        progress.emit("Checking speaker models")
        let speakers = try await loadSpeakers(assets)
        await speakers.unloadModels()
    }

    private func loadWhisper(_ assets: WorkerAssetLocations) async throws -> WhisperKit {
        do {
            // Parse all local tokenizer files first. The isolated flat folder has no shadow Hub cache.
            // On failure, stop here instead of entering the SDK's download fallback.
            _ = try await AutoTokenizerWrapper.from(modelFolder: assets.tokenizer)
            return try await WhisperKit(WhisperKitConfig(
                model: Self.whisperVariant,
                modelFolder: assets.whisper.path,
                tokenizerFolder: assets.tokenizer,
                verbose: false,
                logLevel: .none,
                prewarm: true,
                load: true,
                download: false
            ))
        } catch { throw WorkerFailure.modelNeedsRepair }
    }

    private func loadSpeakers(_ assets: WorkerAssetLocations) async throws -> SpeakerKit {
        do {
            return try await SpeakerKit(PyannoteConfig(
                modelFolder: assets.speakers.path,
                download: false,
                load: true,
                verbose: false,
                logLevel: .none
            ))
        } catch { throw WorkerFailure.modelNeedsRepair }
    }

    private func transcribe(_ request: TranscriptionWorkerRequest) async throws -> [TranscriptSegment] {
        let (input, duration) = try inputDetails(request)
        let assets = try WorkerAssetLocations.current(at: request.modelsURL)
        progress.emit("Loading speech model")
        let whisper = try await loadWhisper(assets)
        whisper.segmentDiscoveryCallback = { segments in
            let end = segments.map(\.end).max().map(Double.init) ?? 0
            progress.emit(fraction: end / duration, "Transcribing")
        }
        let results = try await whisper.transcribe(
            audioPath: input.path,
            audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
            decodeOptions: DecodingOptions(
                language: "en", detectLanguage: false, skipSpecialTokens: true,
                wordTimestamps: true, concurrentWorkerCount: 1, chunkingStrategy: .vad
            )
        )
        return results.flatMap(\.segments).map { segment in
            TranscriptSegment(
                start: Double(segment.start), end: Double(segment.end), text: segment.text,
                words: (segment.words ?? []).map {
                    TranscriptWord(start: Double($0.start), end: Double($0.end), text: $0.word)
                }
            )
        }
    }

    private func diarize(_ request: TranscriptionWorkerRequest) async throws -> [SpeakerInterval] {
        let (input, duration) = try inputDetails(request)
        guard duration <= 7200.5 else { throw SpeakerDurationLimit() }
        let assets = try WorkerAssetLocations.current(at: request.modelsURL)
        progress.emit("Loading speaker models")
        let speakers = try await loadSpeakers(assets)
        progress.emit(fraction: 0, "Preparing speaker audio")
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: input.path)
        let result = try await speakers.diarize(
            audioArray: audio,
            options: PyannoteDiarizationOptions(numberOfSpeakers: nil, useExclusiveReconciliation: true),
            progressCallback: { update in
                progress.emit(fraction: update.fractionCompleted, "Identifying speakers")
            }
        )
        return result.segments.compactMap { segment in
            guard let speaker = segment.speaker.speakerId else { return nil }
            return SpeakerInterval(
                start: Double(segment.startTime), end: Double(segment.endTime), speaker: speaker
            )
        }
    }

    private func inputDetails(_ request: TranscriptionWorkerRequest) throws -> (URL, Double) {
        guard let input = request.inputURL, input.isFileURL else { throw WorkerFailure.missingInput }
        do {
            let file = try AVAudioFile(forReading: input)
            let duration = Double(file.length) / file.fileFormat.sampleRate
            guard duration.isFinite, duration > 0 else { throw WorkerFailure.missingInput }
            return (input, duration)
        } catch { throw WorkerFailure.missingInput }
    }
}

private struct SpeakerDurationLimit: LocalizedError {
    var errorDescription: String? {
        "Speaker labels are supported for recordings up to two hours."
    }
}
