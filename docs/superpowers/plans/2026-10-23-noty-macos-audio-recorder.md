# Noty: macOS Menu Bar Audio Recorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS 15+ menu bar app that records capturable system audio and the default microphone into a validated 48 kHz stereo AAC `.m4a`, with bounded memory and recoverable output on failure.

**Architecture:** A menu-bar SwiftUI/AppKit shell owns a main-thread `RecordingController`. ScreenCaptureKit emits system and microphone audio into a serial audio pipeline; the pipeline normalizes timestamps and formats, mixes the sources, and hands bounded chunks to a writer that finalizes the output atomically. Permissions, destination access, capture, mixing, writing, and UI are separate components behind injectable interfaces.

**Tech Stack:** Swift, SwiftUI, AppKit, ScreenCaptureKit, AVFoundation, CoreMedia, Accelerate, UniformTypeIdentifiers, XCTest, and Xcodebuild. No third-party audio drivers or libraries.

**Spec:** `docs/plans/2026-10-23-noty-macos-audio-recorder.md`

## Global Constraints

- Target macOS 15+.
- Use App Sandbox with Music Folder read/write and User Selected Files read/write entitlements.
- Declare `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription`; enable the macOS Audio Input entitlement.
- Request and handle Screen Recording permission separately, including the possible relaunch after permission is granted.
- Use ScreenCaptureKit audio and microphone outputs only; do not write video.
- Use the main display’s full-display content filter. Capture guarantees cover only audio available through ScreenCaptureKit; protected or unavailable audio is excluded.
- Normalize to 48 kHz stereo PCM, preserve timestamp gaps as silence, mix with headroom and limiting, and encode AAC at 192 kbps.
- Bound every in-memory queue to at most 5 seconds or 64 MiB of copied audio, whichever is reached first. A queue overrun must produce an explicit failure or partial-recording outcome.
- Synthetic source alignment must remain within one 48 kHz output frame; a one-hour run must remain within 100 ms of the expected duration.
- Mixed output peak must remain at or below -1 dBFS. The one-hour test must keep process RSS within 128 MiB of its idle baseline, excluding OS-managed capture caches.
- Write to temporary output, validate before success, and atomically rename successful recordings into the destination folder.
- Persist selected folders with security-scoped bookmarks and hold access for the duration of a recording.
- Finalize through one idempotent path for Stop, capture errors, sleep, microphone disconnection, and Quit.
- Do not add pause/resume, transcription, cloud uploads, automatic meeting detection, or launch-at-login.

## Execution Order and Ownership

Task 1 is the prerequisite for all other tasks. After Task 1, Tasks 2 and 3 can proceed in parallel. Tasks 4 and 5 depend on Task 3 and can proceed in parallel. Task 6 depends on Tasks 2, 4, and 5. Task 7 runs after all implementation tasks.

Each subagent should modify only the files listed for its task. In particular, Task 1 owns initial project creation, Task 2 owns privacy and destination configuration, and Task 6 owns the final app delegate and menu-bar integration.

## Review Focus

- Permission is not determined, denied, or granted only after a relaunch; the app must show an actionable state and never start a silent recording. Test in Task 2.
- Audio buffers arrive with different formats, gaps, overlaps, or clock drift; the final timeline must remain synchronized and preserve silence. Test in Task 3.
- ScreenCaptureKit stops because of sleep, device removal, user cancellation, or an interruption; capture must terminate exactly once and hand off to finalization. Test in Task 4.
- The writer is slow, the destination fills, or the process terminates during recording; memory must remain bounded and any valid artifact must be surfaced. Test in Task 5.
- A selected folder moves, becomes inaccessible, or is used after relaunch; bookmark refresh and actionable folder errors must work. Test in Task 2.

---

### Task 1: Create the Xcode project and shared recording models

**Files:**

- Create: `Noty.xcodeproj`
- Create: `Noty/NotyApp.swift`
- Create: `Noty/Recording/RecordingModels.swift`
- Create: `Noty/Resources/Info.plist`
- Create: `Noty/Resources/Noty.entitlements`
- Create: `NotyTests/NotySmokeTests.swift`

**Interfaces:**

- Produces the `Noty` app target, `NotyTests` test target, macOS 15 deployment target, and a buildable Swift module.
- Produces `RecordingState`, `RecordingIssue`, `RecordingArtifact`, and `RecordingOutcome` shared by later tasks.
- `RecordingState` cases are `idle`, `starting`, `recording`, `stopping`, `interrupted`, and `failed`.
- `RecordingIssue` contains a stable code, user-facing message, optional recovery URL, and whether retry is allowed.

- [ ] **Step 1: Create the failing smoke test**

  Add a test that instantiates the shared recording models and asserts the initial state is `idle`.

- [ ] **Step 2: Create the macOS app and test target**

  Configure the app for macOS 15+, SwiftUI, local development signing, App Sandbox capability, and a menu-bar-compatible application lifecycle. Add the required target membership and test scheme.

- [ ] **Step 3: Add shared models and privacy placeholders**

  Define the state and artifact types in `RecordingModels.swift`. Add the `LSUIElement` setting so the app has no Dock icon. Leave the concrete privacy strings and file-access entitlement values for Task 2.

- [ ] **Step 4: Run the smoke test and build**

  Run:

  ```bash
  xcodebuild -project Noty.xcodeproj -scheme Noty -destination 'platform=macOS' test
  ```

  Expected: the smoke test passes and the app target compiles.

- [ ] **Step 5: Commit**

  ```bash
  git add Noty.xcodeproj Noty NotyTests
  git commit -m "build: scaffold Noty macOS app"
  ```

### Task 2: Implement permissions and recording destination access

**Files:**

- Modify: `Noty/Resources/Info.plist`
- Modify: `Noty/Resources/Noty.entitlements`
- Create: `Noty/Permissions/PermissionCoordinator.swift`
- Create: `Noty/Storage/RecordingDestinationStore.swift`
- Create: `NotyTests/Permissions/PermissionCoordinatorTests.swift`
- Create: `NotyTests/Storage/RecordingDestinationStoreTests.swift`

**Interfaces:**

- `PermissionCoordinator.prepareForRecording() async throws -> PermissionGrant` checks microphone and Screen Recording readiness without prompting at app launch.
- `RecordingDestinationStore.resolveCurrentDestination() throws -> DestinationLease` returns a writable URL and holds any security-scoped access until the lease closes.
- `RecordingDestinationStore.chooseFolder() throws -> DestinationLease` presents a directory chooser, stores a security-scoped bookmark, and replaces the current destination only after validation.
- Both components accept injectable permission, panel, bookmark, and file-system dependencies so tests do not depend on TCC or user interaction.

- [ ] **Step 1: Write permission and destination failure tests**

  Cover not-determined, denied, and authorized microphone states; Screen Recording denial; missing entitlement mapping; default-folder creation; inaccessible destination; stale bookmark refresh; and a folder that moved between launches.

- [ ] **Step 2: Add privacy strings and entitlements**

  Add `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, Audio Input, Music Folder read/write, and User Selected Files read/write configuration. Keep Screen Recording handling separate from microphone authorization.

- [ ] **Step 3: Implement `PermissionCoordinator`**

  Check permission state only from the start-recording flow. Map denied, restricted, missing-entitlement, and relaunch-required conditions to `RecordingIssue` values with a System Settings URL where applicable.

- [ ] **Step 4: Implement `RecordingDestinationStore`**

  Create `~/Music/Noty` on first use, use `NSOpenPanel` for folder selection, persist security-scoped bookmark data, refresh stale bookmarks, and verify write access before returning a lease.

- [ ] **Step 5: Run focused tests**

  Run:

  ```bash
  xcodebuild -project Noty.xcodeproj -scheme Noty -destination 'platform=macOS' test -only-testing:NotyTests/PermissionCoordinatorTests -only-testing:NotyTests/RecordingDestinationStoreTests
  ```

  Expected: all injected permission and bookmark cases pass.

- [ ] **Step 6: Commit**

  ```bash
  git add Noty/Resources Noty/Permissions Noty/Storage NotyTests/Permissions NotyTests/Storage
  git commit -m "feat: add capture permissions and destination storage"
  ```

### Task 3: Build the timestamped audio normalization and mixer pipeline

**Files:**

- Create: `Noty/Audio/AudioTypes.swift`
- Create: `Noty/Audio/AudioNormalizer.swift`
- Create: `Noty/Audio/AudioTimeline.swift`
- Create: `Noty/Audio/AudioMixer.swift`
- Create: `Noty/Audio/BoundedAudioQueue.swift`
- Create: `NotyTests/Audio/AudioNormalizerTests.swift`
- Create: `NotyTests/Audio/AudioTimelineTests.swift`
- Create: `NotyTests/Audio/AudioMixerTests.swift`
- Create: `NotyTests/Audio/BoundedAudioQueueTests.swift`

**Interfaces:**

- `CapturedAudioPacket` contains source (`system` or `microphone`), a presentation timestamp, sample rate, channel count, frame count, and copied interleaved Float32 samples.
- `AudioNormalizer.normalize(_:) -> NormalizedAudioPacket` produces 48 kHz stereo samples using `AVAudioConverter` and explicit channel mapping.
- `AudioTimeline.append(_:) -> [MixedAudioChunk]` orders packets by presentation timestamp, inserts silence for gaps, and applies the defined overlap/discontinuity policy.
- `AudioMixer.append(_:) -> [MixedAudioChunk]` mixes both sources with fixed headroom and a limiter; `finish() -> [MixedAudioChunk]` flushes the remaining timeline.
- `BoundedAudioQueue` has a fixed duration/capacity and a `.failOnOverflow` policy for recording. It never grows past its configured bound.

- [ ] **Step 1: Write synthetic audio tests**

  Cover 44.1 kHz mono microphone plus 48 kHz stereo system audio, leading and trailing gaps, overlapping packets, out-of-order arrival, a timestamp discontinuity, silence preservation, both sources audible, one-frame synthetic alignment, and mixed peaks at or below -1 dBFS.

- [ ] **Step 2: Write bounded-queue tests**

  Assert that normal consumption preserves order and that a slow consumer reaches the 5-second/64 MiB limit and returns an overflow error without allocating additional queued duration.

- [ ] **Step 3: Implement normalization**

  Convert each packet to 48 kHz stereo Float32, preserve the packet’s presentation timestamp, and reject malformed or unsupported audio formats with a typed issue.

- [ ] **Step 4: Implement the timeline**

  Use presentation timestamps rather than callback arrival order. Define the output origin at the first valid packet, insert silence for positive gaps, trim or replace overlaps deterministically, and reset the clock on an explicit discontinuity. If source timing cannot stay within the one-frame synthetic tolerance, fail the pipeline rather than silently retiming speech.

- [ ] **Step 5: Implement mixing and limiting**

  Mix system and microphone frames at the same output sample positions, apply fixed headroom before summing, and apply a deterministic limiter that keeps the peak at or below -1 dBFS without changing silence into non-silence.

- [ ] **Step 6: Run focused tests**

  Run:

  ```bash
  xcodebuild -project Noty.xcodeproj -scheme Noty -destination 'platform=macOS' test -only-testing:NotyTests/Audio
  ```

  Expected: all format, timestamp, clipping, and bounded-queue tests pass.

- [ ] **Step 7: Commit**

  ```bash
  git add Noty/Audio NotyTests/Audio
  git commit -m "feat: add timestamped audio mixing pipeline"
  ```

### Task 4: Implement the ScreenCaptureKit audio service

**Files:**

- Create: `Noty/Capture/CaptureService.swift`
- Create: `Noty/Capture/ScreenCaptureService.swift`
- Create: `Noty/Capture/ScreenCaptureError.swift`
- Create: `NotyTests/Capture/FakeCaptureService.swift`
- Create: `NotyTests/Capture/ScreenCaptureServiceTests.swift`

**Interfaces:**

- `CaptureService` exposes `start() async throws`, `stop() async`, and an `AsyncThrowingStream<CapturedAudioPacket, Error>` of copied audio packets.
- `ScreenCaptureService` owns `SCShareableContent`, the main-display `SCContentFilter`, `SCStream`, and the two stream output queues.
- The service emits a typed termination event for user stop, Screen Recording denial, sleep/interruption, microphone disconnection, and unexpected stream errors.

- [ ] **Step 1: Write fake-service and event-mapping tests**

  Assert that duplicate `start`/`stop` calls are idempotent, intentional user stop is not reported as an unexpected failure, and each stream error maps to the correct typed termination issue.

- [ ] **Step 2: Implement the capture protocol and fake**

  Add the protocol and deterministic fake used by controller tests. The fake must be able to emit packets, finish normally, and fail at a chosen packet.

- [ ] **Step 3: Implement ScreenCaptureKit setup**

  Resolve the main display, create a full-display filter, set `capturesAudio` and `captureMicrophone`, set the default microphone device, and attach only `.audio` and `.microphone` outputs. Do not attach `.screen`.

- [ ] **Step 4: Copy and convert sample buffers at the boundary**

  Read the sample buffer’s presentation timestamp and audio format, copy its samples into `CapturedAudioPacket`, and immediately release framework-owned buffer memory so downstream work cannot retain capture callbacks.

- [ ] **Step 5: Implement lifecycle/error handling**

  Map `SCStreamDelegate` errors and active/inactive transitions to the capture service’s typed events. Ensure `stop()` removes outputs and stops the stream exactly once.

- [ ] **Step 6: Run focused tests and compile the service**

  Run:

  ```bash
  xcodebuild -project Noty.xcodeproj -scheme Noty -destination 'platform=macOS' test -only-testing:NotyTests/ScreenCaptureServiceTests
  ```

  Expected: fake-service tests pass and the ScreenCaptureKit implementation compiles without requiring a live permission grant in unit tests.

- [ ] **Step 7: Commit**

  ```bash
  git add Noty/Capture NotyTests/Capture
  git commit -m "feat: capture system audio and microphone with ScreenCaptureKit"
  ```

### Task 5: Implement the writer, recovery artifacts, and atomic finalization

**Files:**

- Create: `Noty/Recording/RecordingWriter.swift`
- Create: `Noty/Recording/RecoverySegmentStore.swift`
- Create: `Noty/Recording/MediaValidator.swift`
- Create: `NotyTests/Recording/RecordingWriterTests.swift`
- Create: `NotyTests/Recording/MediaValidatorTests.swift`

**Interfaces:**

- `RecordingWriter.start(at:) async throws` creates a unique temporary recording and recovery location.
- `RecordingWriter.append(_:) async throws` accepts `MixedAudioChunk` values only while active and returns a typed overflow or write error.
- `RecordingWriter.finish() async throws -> RecordingArtifact` closes the writer, validates the media, and atomically renames the final `.m4a`.
- `RecordingWriter.fail(_:) async -> RecordingOutcome` stops accepting samples and returns the best validated `.m4a` or recovery artifact URL.
- `MediaValidator.validate(url:) async throws` confirms that the output exists, is readable, playable, and has the expected audio format.

- [ ] **Step 1: Write writer and validator tests**

  Cover unique output names, normal finalization, duplicate finish calls, append-after-finish rejection, invalid media rejection, injected writer failure, disk-full simulation, and recovery-artifact reporting.

- [ ] **Step 2: Implement temporary output and recovery storage**

  Create a temporary `.m4a` in the destination folder, configure periodic fragments, and retain independently closed recovery segments while the recording is active. Keep temporary names distinct from successful user-facing names.

- [ ] **Step 3: Implement AAC writing**

  Configure `AVAssetWriter` for 48 kHz stereo AAC at 192 kbps. Append mixed chunks in presentation order and reject calls after a terminal transition.

- [ ] **Step 4: Implement validation and atomic rename**

  Validate the completed file before moving it to its timestamped final name. Use a same-volume atomic replace/rename and preserve the temporary or recovery artifact if validation fails.

- [ ] **Step 5: Implement failure recovery**

  On write failure or termination, stop the writer once, close any valid fragment/segment, validate every candidate, and return the best artifact plus an actionable issue. Never report success for an unvalidated file.

- [ ] **Step 6: Run focused tests**

  Run:

  ```bash
  xcodebuild -project Noty.xcodeproj -scheme Noty -destination 'platform=macOS' test -only-testing:NotyTests/Recording
  ```

  Expected: normal output is playable and failure paths return either a validated final file or a clearly surfaced recovery artifact.

- [ ] **Step 7: Commit**

  ```bash
  git add Noty/Recording NotyTests/Recording
  git commit -m "feat: write validated recordings with recovery"
  ```

### Task 6: Connect the controller, menu bar UI, and termination lifecycle

**Files:**

- Create: `Noty/Recording/RecordingController.swift`
- Create: `Noty/UI/MenuBarView.swift`
- Create: `Noty/UI/RecordingStatusView.swift`
- Create: `Noty/AppDelegate.swift`
- Modify: `Noty/NotyApp.swift`
- Create: `NotyTests/Recording/RecordingControllerTests.swift`
- Create: `NotyTests/UI/MenuBarViewTests.swift`

**Interfaces:**

- `@MainActor final class RecordingController` publishes `state`, elapsed duration, current destination, last artifact, and the latest issue.
- `start() async`, `stop() async`, and `finishForTermination() async` all use the same single-flight finalization task.
- The controller consumes `PermissionCoordinator`, `RecordingDestinationStore`, `CaptureService`, `AudioMixer`, and `RecordingWriter` through injected protocols.
- `AppDelegate.applicationShouldTerminate(_:)` returns delayed termination while a recording is active and calls `reply(toApplicationShouldTerminate:)` only after finalization completes.

- [ ] **Step 1: Write controller state-machine tests**

  Cover start success, permission failure, duplicate start, duplicate stop, capture failure, writer failure with recovery URL, stop during startup, and repeated finalization calls.

- [ ] **Step 2: Implement the controller**

  Start dependencies in order, consume capture packets into the mixer and writer, publish elapsed time, and route every terminal event through one idempotent finalization task. Do not publish success until the writer returns a validated artifact.

- [ ] **Step 3: Implement menu-bar presentation**

  Add Start/Stop, elapsed time, Choose Recording Folder, Show Last Recording in Finder, and Quit. Disable controls according to state and show actionable permission, folder, interruption, and recovery errors.

- [ ] **Step 4: Implement the recording indicator**

  Change the status-item image and accessible label for idle, starting, recording, stopping, interrupted, and failed states. Keep the indicator visible while the menu is closed.

- [ ] **Step 5: Implement delayed termination**

  Integrate `NSApplicationDelegate` termination callbacks. If recording is active, prevent immediate termination, finalize once, then approve or cancel termination based on whether the output/recovery artifact was handled.

- [ ] **Step 6: Run focused tests and build the app**

  Run:

  ```bash
  xcodebuild -project Noty.xcodeproj -scheme Noty -destination 'platform=macOS' test -only-testing:NotyTests/RecordingControllerTests -only-testing:NotyTests/MenuBarViewTests
  xcodebuild -project Noty.xcodeproj -scheme Noty -destination 'platform=macOS' build
  ```

  Expected: state-machine tests pass and the menu-bar app builds.

- [ ] **Step 7: Commit**

  ```bash
  git add Noty/Recording/RecordingController.swift Noty/UI Noty/AppDelegate.swift Noty/NotyApp.swift NotyTests/Recording/RecordingControllerTests.swift NotyTests/UI/MenuBarViewTests.swift
  git commit -m "feat: add recording controller and menu bar UI"
  ```

### Task 7: Run integration, failure-mode, and long-duration verification

**Files:**

- Create: `NotyTests/Integration/RecordingPipelineIntegrationTests.swift`
- Create: `docs/verification/noty-macos-audio-recorder-checklist.md`

**Interfaces:**

- Integration tests use the fake capture service and real mixer/writer to prove the end-to-end pipeline without requiring Screen Recording permission.
- The verification checklist records the manual macOS-only cases and expected user-visible outcomes.

- [ ] **Step 1: Write end-to-end synthetic tests**

  Feed deterministic system and microphone packets through the fake capture service and assert a playable `.m4a`, expected duration within 100 ms for the long-run fixture, both audible sources, silence gaps, bounded queue behavior, and a peak at or below -1 dBFS.

- [ ] **Step 2: Add the manual verification checklist**

  Include fresh permission state, denial and later grant, required relaunch, multiple displays, protected audio, microphone disconnection, sleep/wake, folder selection and relaunch, repeated recordings, disk-full behavior, Quit during recording, process termination, Finder reveal, and one-hour recording.

- [ ] **Step 3: Run automated verification**

  Run:

  ```bash
  xcodebuild -project Noty.xcodeproj -scheme Noty -destination 'platform=macOS' test
  xcodebuild -project Noty.xcodeproj -scheme Noty -destination 'platform=macOS' build
  git diff --check
  ```

  Expected: all automated tests pass, the app builds, and the diff has no whitespace errors.

- [ ] **Step 4: Run manual capture verification**

  Use headphones for a real meeting recording. Confirm the final file is playable, both participants and the microphone are audible, the status indicator remains visible, process RSS stays within 128 MiB of idle baseline during the one-hour run, and every failure case displays the correct artifact or action.

- [ ] **Step 5: Commit verification artifacts**

  ```bash
  git add NotyTests/Integration docs/verification/noty-macos-audio-recorder-checklist.md
  git commit -m "test: verify Noty recording pipeline"
  ```

## Completion Criteria

- Every checkbox above is complete and its focused test command passes.
- The full `xcodebuild test` and `xcodebuild build` commands pass on macOS 15+.
- A normal recording produces a validated timestamped `.m4a` in the configured folder.
- A permission, capture, storage, writer, interruption, or termination failure produces an actionable state and preserves any validated recovery artifact.
- A one-hour recording remains within 100 ms of expected duration and stays within the 128 MiB RSS-growth ceiling.
