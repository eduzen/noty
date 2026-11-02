# Review remediation plan

Date: 2026-11-02

## Goal and scope

Fix the three reproduced correctness defects from the whole-repository review:

1. Stale bootstrap recovery results can overwrite an active recording lifecycle.
2. The menu-bar status label does not observe recording state or elapsed time.
3. Per-packet sample-rate conversion introduces gaps and boundary artifacts.

Separately investigate the conditional low-rate microphone delivery risk. Do not treat a synthetic delivery schedule as proof of native-device behavior.

Keep existing capture backpressure, failure reporting, sandbox access, writer serialization, and validated-artifact publication. No new retries, recovery concatenation, permission model, or general audio architecture rewrite.

## 1. Protect lifecycle state from stale recovery discovery

### Files

- `Noty/Recording/RecordingController.swift`
- `NotyTests/Recording/RecordingControllerTests.swift`

### Decision

Keep recovery discovery asynchronous and leave Start available. Introduce a controller revision that changes when a Start is accepted or a destination selection succeeds. Capture the revision and initial idle eligibility before discovery; publish discovery results only if both are still valid afterward.

Do not rely only on `hasActiveRecording`: a newer recording may have started and completed while discovery was suspended. Also prevent discovery begun after a lifecycle has already advanced from overwriting that lifecycle.

Always close the discovery destination lease, including the stale-result path. Ignoring stale presentation must not delete recovery files.

### Acceptance

Use the existing continuation-gate test convention, not timing sleeps:

- Discovery completes during recording: state stays recording, Stop stays enabled, and stopping finalizes exactly once.
- Discovery completes during startup: it does not replace starting state or interfere with termination cleanup.
- A recording starts and finishes before discovery returns: its artifact and outcome remain authoritative.
- A recording fails before discovery returns: its actionable failure remains authoritative.
- A successful folder change makes results from the old destination stale.
- With no intervening action, a valid orphan is still surfaced and its lease is closed.

Repeat the review's gated executable scenario with actual recovery discovery and AAC validation; prove that Stop and Quit still use finalization after discovery returns.

## 2. Observe controller changes in the status-item label

### Files

- `Noty/NotyApp.swift`
- `Noty/UI/RecordingStatusView.swift`

### Decision

Add a small label view in the existing status-view file with `@ObservedObject var controller: RecordingController`. Construct the existing value-based `RecordingStatusView` inside that observing view and use it as the `MenuBarExtra` label.

Keep formatting and state presentation in `RecordingStatusView`. Do not make the app delegate observable or add manual Combine forwarding.

### Acceptance

Exercise the native status item, not only view-formatting helpers:

- Idle shows the idle presentation.
- Starting a recording changes the persistent icon and adds elapsed time.
- Elapsed text advances while the menu is closed.
- Stopping and terminal failures update the label and accessibility presentation.
- Repeated recordings continue updating without recreating the app.

Verify the actual `NSStatusBarButton` title/icon changes using the same native probe approach that confirmed the defect. Keep existing formatting/accessibility tests; do not add source-shape or observation-wiring tests.

## 3. Preserve continuous per-source sample-rate conversion

### Files

- `Noty/Audio/AudioNormalizer.swift`
- `Noty/Recording/RecordingController.swift`
- `NotyTests/Audio/AudioNormalizerTests.swift`
- Relevant consumer tests in `NotyTests/Audio/`, `NotyTests/Recording/`, and `NotyTests/Integration/`
- `Noty/Audio/AudioTimeline.swift` only if timestamp integration requires a focused change

### Decision

Give the detached recording worker session-lifetime normalization state, separate for system audio and microphone audio. Retain each source's converter, filter history, and fractional output position across contiguous packets. Reuse conversion buffers where practical; do not create a converter per callback.

Treat an exhausted callback buffer as temporarily unavailable input, not end-of-stream. Conversion may legitimately produce no output for a particular input packet. Drain available output and flush remaining converter output at actual stream completion before the mixer is finalized.

Timestamp output from each contiguous source segment's capture-time anchor and cumulative emitted output frames, with converter latency accounted for. Do not independently round every packet's output length, concatenate across genuine timestamp gaps, or silently retime clock drift.

Define and verify reset/drain behavior for explicit discontinuities, real timestamp gaps, and input-format changes. Preserve the existing timeline's overlap/discontinuity policy. Keep all staging bounded and conversion errors explicit.

Update every affected caller to the streaming contract; remove the old stateless path rather than adding a compatibility shim. Query references before changing the normalizer interface.

### Acceptance

Permanent behavior regressions must cover:

- Continuous 44.1 kHz input split into 4096-frame and irregular packets: no interior holes or packet-boundary artifacts beyond a defined numerical tolerance against continuous conversion.
- Total output duration after drain within one 48 kHz frame of the expected source duration.
- Independent system/microphone conversion state and timestamp alignment.
- Unchanged 48 kHz channel values and mono-to-stereo mapping.
- Genuine timestamp gaps remain silence; discontinuities do not mix old filter history into a new segment.
- Stream-end draining preserves trailing audio without inventing a tail on repeated finalization.
- Existing malformed-input, queue-bound, failure, and idempotent-finalization behavior remains intact.

Use constant input to detect artificial zero holes and continuous sine input to detect boundary distortion. Reproduce the review's failed 44.1 kHz case before the change, then prove it passes afterward.

Extend the existing AAC integration coverage with a packetized 44.1 kHz source mixed with a 48 kHz source. Decode the result and verify both sources, preserved gaps, and duration. Separately run a throwaway executable through normalization, mixing, AAC writing, and validation; tests alone are not the end-to-end proof.

## 4. Investigate low-rate microphone delivery

### Status

Conditional risk, not a confirmed hardware defect. A synthetic 4096-frame/16 kHz microphone schedule exceeds the 250 ms reorder allowance and loses 288 leading output frames; the 48 kHz control loses none. AVAudioEngine may deliver a different callback size from the requested size.

### Investigation

- Re-run the synthetic scenario after the resampling fix to separate conversion behavior from delivery-latency behavior.
- With a native low-rate input, use a temporary probe to measure the actual format, callback frame counts, and delivery timing relative to the system stream.
- Compare the mixed output with known continuous input, including startup and steady-state callback boundaries.

### Decision gate

If native delivery reproduces loss, coordinate the timeline watermark with source progress and an explicit bounded delivery allowance. A duration-based microphone buffer request may help, but must not be the sole correctness guarantee because the requested size is not guaranteed.

If no suitable native device is available, record that prerequisite and keep the finding conditional. Do not increase the reorder window arbitrarily or claim native verification from synthetic evidence.

## Execution and release verification

Implement in order: lifecycle protection, reactive status label, continuous resampling, then the low-rate investigation. The first two changes are independent, but the lifecycle and resampling changes share `RecordingController`; one integration owner should reconcile them.

For each confirmed bug, retain a failing-before/passing-after behavioral regression where practical and exercise the changed surface directly. Do not add a new UI test framework solely for the label fix.

After the implementation slices are integrated:

1. Run `just format` and `just check`.
2. Exercise the gated recovery race, native status item, and mixed-rate AAC executable scenarios.
3. Record only observed results in `docs/verification/noty-macos-audio-recorder-checklist.md`, adding the new scenarios and any native-device limitations.
4. Update affected interface documentation and remove temporary probes and artifacts.

The three confirmed fixes are complete only when their acceptance criteria and runtime checks pass. The conditional timing investigation has a separate evidence outcome and must not be silently counted as a verified hardware fix.
