# Local transcription worker verification

The app embeds `NotyTranscriptionWorker` in `Contents/MacOS`. It accepts one
JSON request path; its stdout contains only newline-delimited progress JSON.
SDK output is disabled and any third-party stdout is redirected to stderr.
Results are written atomically to the app's staging directory; the parent alone
publishes user-facing transcripts. Killing the worker discards partial inference.
A watchdog checks the original parent PID immediately and every 250 ms.

Assets are downloaded only in `prepare`. A new asset set is fully loaded and its
local tokenizer parsed before `current.json` is published. Preparation leaves an
existing selected set usable until replacement succeeds. Incomplete preparation
folders are removed on the next setup attempt. Validation and inference use
explicit local model/tokenizer paths with downloads disabled; invalid caches
return `needsModelRepair` before inference.

## Automated checks

Run from the repository root:

```sh
swiftc -module-cache-path /tmp/noty-worker-module-cache \
  -o /tmp/noty-worker-runtime-checks \
  TranscriptionShared/TranscriptionTypes.swift \
  NotyTranscriptionWorker/WorkerRuntime.swift \
  NotyTranscriptionWorker/WorkerModelAssets.swift \
  NotyTranscriptionWorker/Tests/WorkerRuntimeChecks.swift
/tmp/noty-worker-runtime-checks
```

Build the `NotyTranscriptionWorker` scheme to check the pinned Argmax 1.1.1 APIs.
Build the `Noty` scheme to check helper embedding. Inspect both signatures with
`codesign -d --entitlements :-` and verify that the helper has only
`com.apple.security.app-sandbox` and `com.apple.security.inherit`, uses the same
stable identity as Noty, and has no `get-task-allow` entitlement.

Use `just build` after tests: Xcode's test preparation rewrites cached signing
inputs with additional test entitlements. The build recipe invalidates those
generated inputs so both the app and inherited helper regain their production
permissions. The XCTest integration check skips only when it detects Xcode's
specific injected exceptions; the production sandbox probe below checks the
normal signed parent/child boundary.

The process runner's interruption check runs outside the app sandbox because it
launches a temporary shell fixture:

```sh
swiftc -parse-as-library -swift-version 6 -module-cache-path /tmp/noty-worker-module-cache \
  TranscriptionShared/TranscriptionTypes.swift \
  Noty/Transcription/TranscriptionWorkerProcess.swift \
  docs/verification/WorkerProcessChecks.swift -o /tmp/noty-worker-process-checks
/tmp/noty-worker-process-checks
```

Xcode 27.2 test preparation adds its own file-read and testmanager sandbox
exceptions even when base entitlement injection is disabled. Those extra
entitlements make an inherited helper abort before `main`. The bundled-helper
XCTest skips only when its signature contains that specific set of injected
exceptions. Normal app builds use the two required entitlements. Check the actual
production sandbox boundary with the reproducible signed parent probe:

```sh
just build
sh docs/verification/WorkerSandboxProbe/check.sh \
  "$PWD/build/DerivedData/Build/Products/Debug/Noty.app/Contents/MacOS/NotyTranscriptionWorker" \
  "Noty Local"
```

Use the same signing identity configured for the app in place of `Noty Local`.
The probe preserves the built helper's signature, compiles a disposable sandboxed
parent, and verifies container access and the matching missing-model repair
response. It requests no microphone or system-audio access. Apple's
[helper tool instructions](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)
explain why the helper must contain exactly the sandbox and inheritance pair.

## Manual acceptance

- Explicit setup downloads and fully loads Whisper and speaker models; cancel
  setup, retry, and verify incomplete assets are never marked ready.
- Restart the app, disable networking, and transcribe an English `.m4a` file.
  Check words preserve spacing and speakers change at audible turns.
- Exercise transcription and speaker labeling on a two-hour meeting while
  watching memory. SpeakerKit decodes the entire file and retains additional
  intermediate chunks; long-file peak memory must be measured on real hardware.
- Start recording during each worker phase: the parent terminates the worker,
  waits for exit, and requeues the interrupted job. No partial sidecar is exported.
- Quit/force-quit Noty during a job and verify its worker exits within one second.
- Move/delete an active model or tokenizer file and verify Repair Setup is shown.
- Audio beyond two hours remains eligible for transcription; speaker labeling is
  skipped by the app, and the worker rejects an accidental longer diarize request.

## Evidence collected on 2026-11-03

- Final `just format` and `just check` passed: 148 XCTest cases passed with
  zero failures and zero skips. The normal-build recipe restored the embedded
  helper's production entitlements, and its signed sandbox probe passed again.

- The worker scheme compiled against resolved Argmax OSS 1.1.1 using Swift 6
  and Xcode 27.2. An independently built helper's signature verified and contained
  exactly sandbox + inherit entitlements, with an embedded bundle identifier.
- A separate signed sandboxed parent app launched the production helper, passing
  a request in its app container. The helper returned matching job/attempt IDs
  and `needsModelRepair` for absent models. This exercises actual sandbox inheritance.
- Explicit preparation downloaded roughly 619 MiB of selected assets, fully
  loaded the models/tokenizer, and published the selected asset set successfully.
- Fresh processes with outbound networking denied validated cached assets,
  transcribed a 23-second synthetic English recording (8 segments, 76 timed words),
  and identified its Samantha/Daniel voice change as two speakers. Removing a
  tokenizer file returned `needsModelRepair` while offline; the file was restored.
- A two-hour loop of that synthetic sample completed offline diarization in
  58.27 seconds with 2,802.2 MiB sampled peak worker RSS and 621 speaker intervals.
  This measures duration and resource handling, not real-meeting accuracy. The
  SDK left the final roughly 20 seconds without a speaker interval; alignment must
  retain such text under Unknown. A real two-hour meeting still needs listening QA.
- The parent-death runtime check exited a running worker in 0.27 seconds and
  published no result. Standalone checks also covered matching result identities,
  missing/incomplete assets, atomic selection replacement, and concurrent NDJSON.

SDK smoke tests used a disposable copy without inheritance entitlements because
an inheriting helper cannot start directly from an unsandboxed shell. The separate
signed parent probe above covers the production parent/child sandbox boundary.
