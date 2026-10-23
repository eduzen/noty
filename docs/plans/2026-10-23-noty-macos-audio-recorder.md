# Noty: macOS Menu Bar Audio Recorder

Date: 2026-10-23

## Summary

Build a native Swift/SwiftUI app for your Mac that records capturable system audio and the default microphone into one final local `.m4a` file. Start and stop recording from the macOS menu bar, with recoverable temporary artifacts retained when a recording cannot be finalized normally.

## Implementation

- Create an Xcode macOS app targeting macOS 15+, using Apple frameworks without third-party audio drivers. Use App Sandbox with read/write access to the Music folder and user-selected folders.
- Run as a menu bar app with no Dock icon. Its menu provides Start/Stop, elapsed recording time, Choose Recording Folder, Show Last Recording in Finder, and Quit. Persist a selected folder with a security-scoped bookmark and recreate the default folder when needed.
- Show a persistent recording indicator in the status item and menu. Disable repeated Start/Stop actions while capture starts, stops, or the output is being finalized.
- Request and check permissions only when recording is first requested. Declare `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription`, enable the macOS Audio Input entitlement, and handle Screen Recording permission separately. Explain denied or missing permissions, offer a link to the relevant System Settings pane, and account for the restart that may be required after Screen Recording permission is granted.
- Use ScreenCaptureKit to receive system audio and microphone samples. Resolve a full-display content filter for the main display, set `capturesAudio` and `captureMicrophone`, and attach only the `.audio` and `.microphone` outputs; do not save video. Treat protected or otherwise unavailable system audio as outside the capture guarantee.
- Convert both sources to timestamped 48 kHz stereo PCM on a single output timeline, using presentation timestamps rather than callback arrival order. Resample and map channels explicitly, preserve gaps as silence, handle overlaps and source discontinuities, mix with defined headroom and a limiter, and encode a single AAC `.m4a` at 192 kbps.
- Feed the mixer and writer through bounded queues with an explicit overflow policy. A slow writer must not cause unbounded memory growth; record and surface an overrun as a failed or partial recording rather than silently accumulating buffers.
- Write to a temporary output with periodic fragments and retain independently closed recovery segments while recording. On a normal stop, finish the writer, validate the media, and atomically rename the file to a timestamped destination under `~/Music/Noty` or the persisted user-selected folder. On interruption or write failure, retain any valid recoverable artifact and display its location and outcome.
- Route capture errors, sleep, microphone disconnection, and Quit through one idempotent finalization path. Delay application termination until capture has stopped and the writer has finished or a recoverable artifact has been recorded.

## Internal Interfaces

Keep capture, file writing, and the interface separate:

- A main-thread `RecordingController` exposes recording state, elapsed time, last saved file or recovery artifact, and asynchronous start/stop operations. It owns the single finalization operation so duplicate stop, stream errors, and Quit cannot race.
- A capture service supplies `CMSampleBuffer` values from the system-audio and microphone outputs to a serial mixer/writer pipeline. The pipeline owns format conversion, PTS-based timeline construction, bounded buffering, fragment/recovery output, and final media validation.
- Recording states are `idle`, `starting`, `recording`, `stopping`, `interrupted`, and `failed`. Each non-success terminal state carries an actionable reason and any recoverable file URL; the interface never reports success until finalization and validation complete.

No public API, server, or database is required.

## Verification

- Build and run through Xcode with local development signing, App Sandbox entitlements, privacy usage descriptions, and Screen Recording permission handling. Verify the first successful capture after granting permission and relaunching when required.
- Test state transitions, duplicate actions, idempotent finalization, unique filenames, last-recording behavior, and permission, folder, disk-full, and writer failures.
- Test the mixer with synthetic inputs at different sample rates and channel counts: both sources remain audible, leading/trailing gaps become silence, timestamps and clock drift stay within the defined tolerance, and the mixed peak remains below 0 dBFS without unexpected pumping or distortion.
- Test bounded queues under an intentionally slow writer and verify process memory stays within a fixed ceiling for the duration of the run; verify that an overrun produces an explicit partial/failure outcome.
- Manually record a meeting with headphones; confirm both participants and your voice play back in the resulting file. Test the main-display capture behavior with multiple displays and document protected or unavailable system audio.
- Verify permission denial and later grant, folder selection and relaunch, repeated recordings, microphone disconnection, capture interruption, sleep/wake, disk-full behavior, Quit during recording, and process termination during recording. Confirm that every case either produces a validated `.m4a` or clearly locates a recoverable artifact.
- Run a one-hour recording to check audio synchronization, playable output, bounded memory usage, fragment/recovery behavior, and final file naming.

## Assumptions and Defaults

- App name: **Noty**.
- Capture all system audio available through ScreenCaptureKit from the main-display filter, including other apps and notifications where permitted, plus the default microphone selected at start. Protected, restricted, or unavailable audio is not promised.
- Default encoding: 48 kHz stereo AAC at 192 kbps.
- Default folder: `~/Music/Noty`; selected folders are persisted with security-scoped bookmarks and must remain writable at recording start.
- Local installation only; App Store distribution and notarized releases are deferred, but the app still uses standard macOS sandbox, privacy, and capture-permission requirements.
- No pause/resume, transcription, cloud uploads, automatic meeting detection, or launch-at-login in this version.
