# AGENTS.md

## Project overview

Noty is a macOS menu-bar app written in Swift/SwiftUI. It captures system audio and microphone audio with ScreenCaptureKit, mixes and normalizes the streams, and writes validated AAC recordings to a user-selected folder.

## Repository layout

- `Noty/Audio/` — audio formats, normalization, mixing, timeline, and bounded queues.
- `Noty/Capture/` — capture service and ScreenCaptureKit backend.
- `Noty/Permissions/` — microphone, screen-recording, and entitlement checks.
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

The project requires macOS 15.0 or newer and uses Swift 5 mode. Screen capture and microphone behavior cannot be fully validated without the corresponding macOS permissions.

## Implementation notes

- `RecordingController` is `@MainActor` and owns the recording lifecycle/state machine.
- `RecordingWriter` is an actor; preserve its serialized file/recovery operations.
- `CaptureService` exposes bounded async streams. Treat queue overflow and capture termination as recording failures/interruption, not as silently recoverable conditions.
- Keep permission checks and system-framework access behind protocols where practical so they remain testable.
- Recordings are written to a temporary/recovery location first, validated, then moved to a final `.m4a` path.
- Preserve user changes already present in the working tree or index; inspect `git status` and diffs before editing.

## Style

Always run `just format` after making changes. Follow the existing SwiftFormat/SwiftLint configuration and keep changes focused. Avoid editing generated Xcode project data unless necessary.
