# Local transcription implementation

Approved scope: automatic post-recording transcription, manual .m4a import,
English word-timed text with per-recording Speaker 1/2 labels, persistent FIFO
queue, recording takes priority. Save text beside audio, preserve existing files.
Target speaker labeling up to two hours; longer audio gets text only.
Changed retry exports always use a new numbered filename: review reproduced a
concurrent-editor race when replacing an apparently unchanged previous export.
Identical previously published output is recognized without rewriting it.

Architecture: bundled sandbox-inheriting signed Swift CLI worker, Argmax OSS
Swift exactly 1.1.1, WhisperKit and SpeakerKit only. Fixed Whisper variant
openai_whisper-large-v3-v20240930_626MB; default Pyannote models. Prepare/validate,
transcribe, and diarize are separate worker process invocations. Shared Codable
request/result/progress types live in TranscriptionShared. Only parent app
publishes exports. Source compressed audio is copied into app-owned staging.

Tasks:
- [x] Worker, exact dependency, signing/embedding and licensing.
- [x] Transcript alignment, atomic persistence, staging and safe export.
- [x] Observable queue, restart recovery, worker lifecycle and model setup.
- [x] Recording lifecycle, import and UI integration.
- [x] Unit/integration checks, format, full check, independent review.

Worker contract: executable NotyTranscriptionWorker accepts one request JSON
path as its only argument. It emits newline-delimited TranscriptionWorkerProgress
JSON to stdout, diagnostics to stderr, and atomically writes request.resultURL
with matching jobID/attemptID before exit. Nonzero exit for failures, result.error
is user-facing; needsModelRepair flags incomplete assets. Result segments use
seconds and words preserve whitespace. Prepare downloads and fully loads models
and tokenizer under modelsURL; validate performs local-only checks. Transcribe
uses English, word timestamps and incremental audio; diarize uses 16k mono,
automatic count, exclusive reconciliation. Worker monitors parentPID and exits
on parent death. No source/export access in worker.

Progress: branch codex/local-transcription; original checkout was clean. Baseline
tests started before changes. No recording, signing identity or user files are
to be removed. All verification limitations must be reported.

Final verification: `just format` and `just check` passed. Final XCTest run:
148 passed, 0 skipped, 0 failed. An earlier run narrowly skipped the inherited
helper check when Xcode injected incompatible test entitlements; refreshing
normal-build signing inputs allowed the final integration check to run and pass.
The production embedded-helper sandbox probe passed after normal-build signing
inputs were refreshed. Real-model offline and synthetic two-hour evidence is
recorded in docs/verification/local-transcription-worker.md. Independent review
findings on cancellation, export replacement, and staging were fixed with
regression coverage; final scoped review reported no remaining blocking issue.
