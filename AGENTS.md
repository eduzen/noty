# AGENTS.md

## Project overview

Noty is a macOS menu-bar app written in Swift/SwiftUI. It captures system audio with a Core Audio process tap and microphone audio with AVAudioEngine, mixes and normalizes the streams, and writes validated AAC recordings to a user-selected folder.

## Repository layout

- `Noty/Audio/` — audio formats, normalization, mixing, timeline, and bounded queues.
- `Noty/Capture/` — `AudioCaptureService` plus the system tap (`SystemAudioTapBackend`) and microphone (`MicrophoneEngineBackend`) backends.
- `Noty/Permissions/` — microphone and entitlement checks.
- `Config/` — xcconfig signing defaults; `Signing.local.xcconfig` is per machine and gitignored.
- `Noty/Recording/` — recording state machine, media writer, validation, and recovery segments.
- `Noty/Storage/` — recording destination persistence and security-scoped access.
- `Noty/UI/` — menu-bar and recording-status SwiftUI views.
- `NotyTests/` — XCTest target.
- `Noty.xcodeproj/` — Xcode project; it uses filesystem-synchronized groups.

## Development commands

Use the `justfile` from the repository root:

- `just build` — build the Debug app.
- `just test` — run all tests.
- `just test-only <TestName>` — run one test case.
- `just test-controller` — run controller/UI tests when present.
- `just test-integration` — run recording pipeline integration tests when present.
- `just check` — run tests, build, and `git diff --check`.
- `just format` — run `prek` hooks, including SwiftFormat and SwiftLint.
- `just run` / `just quit` — launch or quit the built app.

Target the latest stable macOS release, Xcode, macOS SDK, and Swift language mode. Supporting older versions is not required unless explicitly requested. Existing deployment targets or Swift compatibility settings are implementation state, not compatibility requirements; keep documentation accurate when migrating them.

System audio and microphone behavior cannot be fully validated without the corresponding macOS permissions (System Audio Recording Only and Microphone). Noty does not use Screen Recording.

## Implementation notes

- `RecordingController` is `@MainActor` and owns the recording lifecycle/state machine.
- `RecordingWriter` is an actor; preserve its serialized file/recovery operations.
- `CaptureService` exposes bounded async streams. Treat queue overflow and capture termination as recording failures/interruption, not as silently recoverable conditions.
- System audio has no public permission preflight. Denial shows up as silence, so `AudioSilenceMonitor` warns during recording instead of blocking the start. The same monitor warns when the microphone stays silent.
- The microphone comes from `MicrophonePreference` (chosen in Settings; `nil` follows the macOS default input). A chosen microphone that is disconnected fails the start instead of falling back to another device.
- Keep the app signed with a stable identity (`just setup-signing` or an Apple Development certificate). Ad-hoc signing changes on every build, so macOS asks for permissions again. Use `just reset-permissions` after changing identities.
- Keep permission checks and system-framework access behind protocols where practical so they remain testable.
- Recordings are written to a temporary/recovery location first, validated, then moved to a final `.m4a` path.
- Preserve user changes already present in the working tree or index; inspect `git status` and diffs before editing.

## Style

Always run `just format` after making changes. Follow the existing SwiftFormat/SwiftLint configuration and keep changes focused. Avoid editing generated Xcode project data unless necessary.
