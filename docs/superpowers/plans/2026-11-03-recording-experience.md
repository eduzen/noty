# Recording experience implementation plan

Goal: address the five reviewed recovery and user messaging problems while retaining recorded audio.

Approach: represent a recovered session as an artifact containing ordered playable file URLs and total duration. Keep all recovered sessions available separately from transient issues. Persist dismissals by recovery directory; successful cleanup failures are acknowledged too. Preserve Settings actions, but only expose validated audio as recording actions. Translate internal errors at the presentation boundary and clear the initial silence warning when system audio becomes audible.

Constraints: macOS 15, Swift 5, serialized writer operations, bounded capture streams, local timestamp filenames, preserve existing edits. No audio deletion on dismissal. Existing orphaned segment names remain supported.

- [x] Add regression coverage for grouped recovery, validated action targets, and silence warning clearance; observe failures.
- [x] Extend artifact recovery URLs, group discovery and failure fallback, and add persistent recovery acknowledgments with an injectable store.
- [x] Expose recovered sessions and dismissal actions in the controller, window, and menu; preserve them during recording.
- [x] Map technical errors to actionable user messages with private diagnostic logging; keep permission and device actions useful.
- [x] Verify restart/dismissal, multiple sessions, successful cleanup failure, and action targets; run just format and just check, review final diff.

Review focus: old segment filenames; separate recording sessions; missing/unplayable primary output; warning clears only for audible system audio; dismissing notices never deletes audio or hides unrelated failures.

Verification: full `just test`, `just check` (tests, build, diff check), and `just format` passed. Initial regressions failed before implementation. Independent review identified temporary-primary dismissal identity and discovery/start races; both received failing regression coverage and fixes before the final passing suite.

Implementation decisions: recovery remains ordered playable files grouped by session, rather than merging media; a valid complete temporary primary is preferred and rediscovered after a failed final move. Dismissal persists session acknowledgment without removing files. Discovery excludes sessions started during this launch.

Scope: macOS hardware permissions and Finder presentation were not exercised interactively. Atomic crash durability between final move and backup cleanup remains outside these user-experience fixes. Concurrent Xcode project/scheme upgrades were left untouched.
