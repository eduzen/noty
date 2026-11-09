# Table audio playback

**Goal:** Add a play/pause icon in the Actions column and a thin underline beneath the playing row that grows with playback. Play one file at a time using AVAudioPlayer without dependencies.

**Design:** A shared main-actor playback controller owns the player and security-scoped folder lease. The transcription controller resolves existing bookmarks and stops playback before recording and termination. The Actions cell observes playback state for its play/pause icon. A small AppKit bridge attaches a two-point underline to the native table row, spanning every column and following resizing, sorting, and scrolling. Pausing freezes the underline; stopping clears it. Keep the original columns and window dimensions.

**Approaches:** Use AVAudioPlayer for local file playback (chosen); AVPlayer adds unnecessary streaming machinery; opening an external player cannot provide inline playback progress.

**Plan:**
- [x] Add tests for exclusive playback, pause/resume, seek bounds, completion, load failure, and lease cleanup.
- [x] Add the shared playback controller and integrate bookmark resolution and recording suspension.
- [x] Add an accessible play/pause icon to Actions and a full-row progress underline.
- [x] Verify underline geometry, row movement/cleanup, and attachment in a hosted recordings table.
- [x] Run focused tests, `just format`, `just check`, and review the diff.

**Review focus:** Switching must release the previous file; paused playback must resume at its position; finished audio must replay from the start; missing files must show an error; playback must stop before recording starts.

**Verification:** Playback tests and recording-interaction regression passed. Underline tests verify row-wide fill geometry, removal on stop, movement between rows, and integration into a hosted SwiftUI table with the original five columns.
