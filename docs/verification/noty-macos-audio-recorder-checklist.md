# Noty macOS Audio Recorder Manual Verification

Automated checks cannot exercise TCC prompts, the system audio tap against live applications, sleep/wake, device removal, or a one-hour run. Record the macOS version, Noty build, audio devices, result, and evidence for each case. Do not use protected or confidential meeting content during testing.

## Developer shortcuts

- `just` lists the available recipes.
- `just run` builds and opens the menu-bar app; `just quit` closes it.
- `just test` runs the full XCTest suite.
- `just test-controller` runs controller and status UI tests.
- `just test-integration` runs the 60-second synthetic AAC integration test.
- `just test-only AudioTimelineTests` runs one test suite; pass any XCTest suite name.
- `just check` runs tests, builds the app, and checks unstaged diff whitespace.
- `just clean` cleans the local Xcode build products.
- `just setup-signing` creates a local "Noty Local" signing identity and writes `Config/Signing.local.xcconfig`. Run it once (or use an Apple ID, see `Config/Signing.local.xcconfig.example`). Stable signing keeps permissions across rebuilds.
- `just reset-permissions` clears Noty's Microphone and System Audio Recording privacy decisions. Run it once after switching from ad-hoc signing.

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
| Passed 2026-11-01 | Signed entitlements | Build the app and inspect its signature with `codesign -d --entitlements - build/DerivedData/Build/Products/Debug/Noty.app`. | The embedded plist contains App Sandbox, `com.apple.security.device.microphone`, Music Folder read/write, and user-selected files read/write, all enabled. No Screen Recording entitlement is needed. |
| Passed 2026-11-01 | Stable signature | Run `codesign -dv build/DerivedData/Build/Products/Debug/Noty.app 2>&1 \| grep Authority` after a build. | The authority is `Noty Local` (or your Apple Development certificate), not ad-hoc (`Signature=adhoc`). |
| Not run | Fresh permissions | Run `just reset-permissions`. Launch Noty without starting a recording, then start one. | No permission prompt at launch. Starting a recording prompts only for Microphone and System Audio Recording Only, and reports recording only after capture starts. |
| Not run | Permission denied, then granted | Deny microphone access and confirm the actionable issue. Grant it in Settings and retry. Then deny System Audio Recording Only, start a recording, and confirm the issue links to Privacy & Security → System Audio Recording Only. | Microphone denial blocks the start with an actionable issue. System audio denial shows a warning within about 5 seconds and links to the setting; the recording keeps running and is not reported as complete system audio. Granting access and retrying succeeds. |
| Not run | Rebuild keeps permissions | Grant both permissions, rebuild Noty with the same signing identity, and start a recording. | No new permission prompt; the recording starts with system audio and microphone. |
| Not run | Output device change | Start recording, then switch the default output device (for example, to headphones). | Recording finalizes once, reports that the output device changed, and reveals any validated partial artifact. |
| Passed native pipeline 2026-11-01 | Duplex USB output device | Use an output device that also exposes inputs, such as a Scarlett 2i2. Keep a different microphone selected, play a system test sound, and record both sources. | The system aggregate exposes only the tap's stereo input buffer. Hardware inputs are not added to that aggregate; both sources reach the mixer and AAC writer without `capture.invalid-audio`. |
| Not run | Audio-only capture | Record a short system test sound and microphone audio, stop, and repeat. Inspect the output tracks and the Console app. | Both sources are audible, the `.m4a` has no video track, and no capture errors appear during capture or shutdown. |
| Not run | Native microphone PCM | Record with a microphone that supplies signed 16-bit PCM, then play the saved file. | Native microphone samples are converted to Float32 without a capture interruption; microphone audio is audible and not distorted. |
| Not run | Protected or unavailable audio | Play a protected or otherwise unavailable source while recording. | Noty records only audio the system tap supplies; protected audio may arrive silent, and Noty does not claim it was captured. |
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
| Passed native UI probe 2026-11-02 | Reactive status item | Exercise idle, startup, recording, stopping, another recording, and failure with injected capture/permission/writer dependencies; inspect the actual native status button with the menu closed. | Icon, elapsed text, and accessibility title follow controller updates. |
| Passed synthetic pipeline 2026-11-02 | Recovery scan racing Start | Hold actual recovery discovery after validating an orphan, start a new recording, then release discovery and exercise Stop and Quit independently. | Discovery does not replace the active lifecycle; capture stops once and the new recording validates successfully. |
| Passed synthetic pipeline 2026-11-02 | Continuous mixed-rate conversion | Send continuous 44.1 kHz audio in 4096-frame and irregular packets through the streaming normalizer and mixer; compare with unsplit conversion and drain at stream end. | No interior holes or callback-boundary artifacts; output duration stays within one 48 kHz frame and source state remains independent. |
| Synthetic risk reproduced; native not verified 2026-11-02 | Low-rate microphone delivery | Measure callback frame counts and timing with a native 16 kHz input; compare microphone coverage with the 250 ms timeline reorder allowance. | Establish whether real callback delivery can lose microphone samples; do not assume the requested buffer size is guaranteed. |

## Execution notes

- Use headphones for live capture checks to avoid feedback.
- Keep test recordings short except for the explicit one-hour scenario.
- Validate files in Finder or a media player and inspect the audio format and duration with a media tool.
- Record failures and recovery URLs; do not delete recovery files until their contents have been validated.

## Permission repair verification — 2026-11-01

- macOS 26.7.1 on Apple Silicon; Xcode 27.2.
- `just setup-signing` installed the local identity. The generated xcconfig uses `CODE_SIGN_IDENTITY = Noty Local`; quotes in this setting made Xcode search for a certificate whose name included literal quotes.
- `just check` passed all 77 tests, the Debug build, and the whitespace check. `just format` passed.
- The tap-creation regression failed against the old permission-denied mapping, then passed after routing the result through the Core Audio status checker. Service and controller tests confirm that the original diagnostic survives startup failure.
- The justfile and Xcode GUI builds both passed signature verification and have identical certificate-based designated requirements. Signed sandbox, microphone, Music folder, and user-selected-file entitlements remain enabled.
- Microphone, AudioCapture, and legacy ScreenCapture grants were reset successfully once after switching identities.
- A separate build made with the command-line override `CURRENT_PROJECT_VERSION=2` has a different signature hash and the same designated requirement. The override is confined to the verification build; project settings were not changed.
- The first live recording produced a decodable 2.56-second AAC `.m4a` at 48 kHz stereo with no video track, but it was nearly silent. The user confirmed that the changed build did not ask for permissions again; audio capture still failed.
- A signed native probe using the actual capture sources reproduced `capture.invalid-audio` with Scarlett 2i2 USB output and Logitech StreamCam input. The aggregate returned two interleaved stereo buffers, while the tap format described one. The physical output subdevice contributed the extra hardware input.
- Removing the physical output subdevice left one stereo tap buffer and captured both sources without errors. The probe then exercised the actual normalizer, mixer, recovery writer, AAC writer, and validator for 20.53 seconds. Measured raw peaks were 0.1983 for system audio and 0.3112 for microphone audio; the decoded AAC peak was -16.2 dBFS. The file decoded successfully as 48 kHz stereo AAC with no video track.
- `just check` passed all 77 tests again after the topology fix, and `just format` passed. The App Sandbox and existing audio entitlements were retained; no audio analytics exception was added.

## Review remediation verification — 2026-11-02

- `just check` passed all 101 tests, the Debug build, and the whitespace check. The integration case now mixes a 48 kHz system source with a 44.1 kHz microphone source.
- Bootstrap presentation now requires initial-idle eligibility and an unchanged lifecycle revision. Gated regressions cover discovery during startup/recording, after completion/failure, after folder selection, and discovery begun after a lifecycle has already advanced. Discovery leases close even when presentation is discarded.
- A throwaway executable seeded and validated an actual AAC recovery segment, suspended discovery, started recording, and resumed discovery. Stop and Quit each preserved the live lifecycle, stopped capture exactly once, and produced a validated 3.0-second AAC recording. Decoded system/microphone spectral amplitudes were approximately 0.2005/0.2004; the intentional silence gap had RMS 0.0.
- The session-owned normalizer retains independent converter history per source. Contiguous output uses the segment capture-time anchor plus cumulative output frames; host-clock jitter is tolerated up to half an output frame, measured against cumulative input timing so drift cannot remain hidden. Real gaps, overlaps, format changes, and explicit discontinuities end the old segment. Converter tails drain before mixer finalization on Stop or capture interruption.
- For one second of constant and sine input at 44.1 kHz, both 4096-frame callbacks and irregular callbacks `[7, 511, 4096, 997, 13, 2048]` produced exactly 48000 normalized/rendered frames. Maximum sample error against continuous conversion was 0.0; constant input had no interior zero holes.
- A native SwiftUI probe used the production controller, menu/status views, and observing status-label wrapper with injected permission/capture/writer dependencies. The actual status button progressed from `Noty` to `Noty 00:01` and `Noty 00:02`, returned to idle after Stop, and updated again for a second recording. Accessibility titles followed idle, startup, recording, stopping, and failure states. No live microphone or system-audio capture was required for this UI check.
- The post-fix synthetic delivery scenario still loses 288 leading microphone output frames (6 ms) when 4096 native frames at 16 kHz arrive after corresponding system packets; the 48 kHz control loses none. This is separate from resampling continuity.
- Core Audio input inventory found eduzenn Microphone at fixed 48 kHz, MacBook Pro Microphone supporting 44.1/48/88.2/96 kHz, and ZoomAudioDevice supporting 44.1–192 kHz. No suitable native 16 kHz input was available. Device settings and privacy grants were not changed; native reachability of the delivery risk remains unverified, and the reorder policy was not changed.
- Live TCC prompts, device disconnection, sleep/wake, disk exhaustion, and a one-hour run were not exercised during this remediation.
