# Noty macOS Audio Recorder Manual Verification

Automated checks cannot exercise TCC prompts, ScreenCaptureKit against live applications, sleep/wake, device removal, or a one-hour run. Record the macOS version, Noty build, audio devices, result, and evidence for each case. Do not use protected or confidential meeting content during testing.

## Developer shortcuts

- `just` lists the available recipes.
- `just run` builds and opens the menu-bar app; `just quit` closes it.
- `just test` runs the full XCTest suite.
- `just test-controller` runs controller and status UI tests.
- `just test-integration` runs the 60-second synthetic AAC integration test.
- `just test-only AudioTimelineTests` runs one test suite; pass any XCTest suite name.
- `just check` runs tests, builds the app, and checks unstaged diff whitespace.
- `just clean` cleans the local Xcode build products.

## Test record

- macOS version/build:
- Noty build/commit:
- Mac model and available memory:
- Display configuration:
- System output and microphone:
- Start time / end time:
- Result and evidence location:

## Scenarios

| Status | Scenario | Procedure | Expected result |
|---|---|---|---|
| Not run | Signed entitlements | Build the app and inspect its signature with `codesign -d --entitlements :- build/DerivedData/Build/Products/Debug/Noty.app`. | The embedded plist contains App Sandbox, `com.apple.security.device.microphone`, Music Folder read/write, and user-selected files read/write, all enabled. |
| Not run | Fresh permissions | Reset Noty's Microphone and Screen Recording privacy decisions. Launch Noty without starting a recording, then start one. | No permission prompt at launch. Start requests required access and never reports recording until capture starts. |
| Not run | Permission denied, then granted | Deny microphone access. Confirm the actionable issue and System Settings action. Grant access in Settings and retry. Repeat for Screen Recording. | No silent recording. Denial is identified by permission type; retry succeeds when permission is available. |
| Not run | Screen Recording relaunch requirement | Grant Screen Recording when macOS requires the app to relaunch. Retry before relaunch, then quit and reopen Noty. | Noty explains the relaunch requirement, does not start a silent recording, and can record after relaunch. |
| Not run | Multiple displays | Connect at least two displays, change the primary display, and record system audio plus microphone. | Audio capture starts against the current main-display filter; no video is written. |
| Not run | Audio-only stream outputs | Record a short system test sound and microphone audio, stop, and repeat. Inspect the output tracks and the capture console. | Both sources are audible, the `.m4a` has no video track, and no `stream output NOT found. Dropping frame` errors appear during capture or shutdown. |
| Not run | Native microphone PCM | Record with a microphone that supplies signed 16-bit PCM, then play the saved file. | Native microphone samples are converted to Float32 without a capture interruption; microphone audio is audible and not distorted. |
| Not run | Protected or unavailable audio | Play a protected or otherwise unavailable source while recording. | Noty records only audio that ScreenCaptureKit supplies; it does not claim protected audio was captured. |
| Not run | Microphone disconnection | Start recording, disconnect or disable the selected microphone, and observe the menu-bar state and output. | Recording finalizes once, reports the microphone interruption, and reveals any validated partial artifact. |
| Not run | Sleep and wake | Start recording, put the Mac to sleep, then wake it. | Capture interruption finalizes once and surfaces the interruption and any validated partial artifact. |
| Not run | Folder selection and relaunch | Choose a user folder, record a short clip, quit, relaunch, and record again. Also move or revoke access to the selected folder. | The bookmark survives relaunch; access errors are actionable; the prior valid folder is not silently replaced on a failed selection. |
| Not run | Repeated recordings | Record, stop, and repeat several times without quitting. | Every recording is a distinct timestamped `.m4a`; the status and Finder action refer to the latest artifact. |
| Not run | Menu interaction during capture | Keep the Noty menu open, dismiss it, and interact with other app menus during a recording. | Audio consumption continues independently of the UI actor; the recording does not fail with capture queue overflow and the final file retains the audio from that interval. |
| Not run | Disk full | Use a disposable test volume with limited free space. Fill it during a recording. | Noty reports the write failure, finalizes once, and surfaces the best validated recording or recovery segment. |
| Not run | Quit during recording | Start recording and choose Quit Noty. | App termination waits for finalization; it quits only after a saved or validated recovery artifact is handled. |
| Not run | Process termination and recovery | Record long enough for at least one closed recovery segment, terminate Noty without normal Quit, relaunch, and inspect the recovery action. | A valid closed segment is discovered and surfaced; no incomplete media is reported as successful. |
| Not run | Finder reveal | Stop a successful recording and choose Show Last Recording in Finder. Repeat for a recovered segment. | Finder selects the actual artifact path. |
| Not run | One-hour duration and memory | Record known continuous system audio and microphone for 60 minutes. Measure idle RSS after launch/warm-up and peak recording RSS, excluding OS-managed capture caches. Validate the final file duration and listen to both sources. | Duration differs from expected by at most 100 ms; RSS growth remains within 128 MiB; both sources are audible; the final `.m4a` is playable. |

## Execution notes

- Use headphones for live capture checks to avoid feedback.
- Keep test recordings short except for the explicit one-hour scenario.
- Validate files in Finder or a media player and inspect the audio format and duration with a media tool.
- Record failures and recovery URLs; do not delete recovery files until their contents have been validated.
