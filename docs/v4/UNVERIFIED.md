# Unverified v4 boundaries

Round 2, 2026-10-18: **29/46 steps passed; 10 failed, 1 UNKNOWN, 6 not dispatched.**
Twelve unique mutation capabilities have historical four-gate proofs on the loaded
FCP 12.4/454072 binary at checkpoint `8dfc3e8`. Latest source fixes are **offline-only**:
the copy is stuck in normal native shutdown, so it could not be redeployed or retried.
See [LIVE_REPORT](LIVE_REPORT.md), [SUPPORT_MATRIX](SUPPORT_MATRIX.md), and the
[46-step disposition](../../evidence/2026-10-18/round2-suite-disposition.json).

## Current host and restoration block

PID 93991 is the patched copy. Normal quit blocked at native thumbnail shutdown,
with a Motion background-loader lock wait; later main-thread RPC reads timed out.
No kill, forced termination, GUI action or original-app launch was used. User library
and active-project reopening are **incomplete**, and the final native library list
cannot be independently read. The latest framework build is not installed.
The new local lifecycle quarantine must be explicitly reconciled before writes.
The original app's executable/plist/code-resource hashes still match.

The user DB before/after trees are preserved read-only. Six of eight files match;
two differ only in the measured SQLite row counters, playhead defaults and thumbnail
metadata detailed in the [row/column diff](../../evidence/2026-10-18/round2-user-db-diff.json).
This establishes the measured logical differences for round 2, not byte restoration
or a reconstruction of round 1's unavailable before database bytes.

## Required live retries on fresh fixtures

- `effect-bypass-false`: the earlier snapshot-only bypass undo failed; an explicit
  current-operation native inverse is now implemented and offline-tested.
- `colorize-rgba`: native RGB has implicit alpha 1; the parent lacks keyframeCount.
  RGB ABI support and recursive no-curve validation need a complete live write/undo.
- `key-set`, `key-delete`: direct intrinsic key changes survived undo. Stack snapshots
  and channel operation boundaries are implemented but not live-rerun.
- `title-insert`, `generator-insert`: native source origin is 3600s. The corrected
  anchor uses that actual origin; offline regression covers it, native retry pending.
- `title-text`, `title-style`: text/style inverse and float32 style tolerance await
  fresh native restoration proofs. No baseline XML field is relaxed by the tolerance.
- `transition-set`: preflight now handles one verified unretimed AV component inside
  its collection; compound/multicam/mixed-rate handle semantics remain fenced.
- `source-channel-enable`: native original metadata count replaces mapped channel
  count after disabling a source; complete native readback/undo retry pending.
- `constant-retime`: UNKNOWN because the preset left an inner FFUndoHandler scope.
  Explicitly closing measured scopes preserved semantic state; no undo/replay of the
  UNKNOWN occurred. The scope-completion adapter is offline-tested, not accepted live.
- Six blocked analysis admissions were not executed. Native analysis execution remains
  NOT_IMPLEMENTED; no successful admission would prove implemented analysis anyway.

A library-wide undo handler spans project identities. Switching disposable projects
alone does not isolate an unclosed scope. The affected UNKNOWN project and the later
import inside its leaked scope remain retired; preserve their raw evidence.

## Remaining architecture and acceptance gates

- Baseline/restore comparison is **exact except security-scoped bookmark bytes**,
  with raw XML retained and separately checked asset source/duration/format IDs.
  No other volatile field is removed; future differences require byte-level evidence.
- The twelve scoped live proofs do not automatically validate the newest source or
  another native binary. Registry entries intentionally remain offline_tested.
- Native history.restore, source/word-state and a v4 cut primitive are missing.
  Checkpoint is observational; the multi-step EditPlan remains fenced. A new adapter
  must chain exact revisions and operation-owned restoration before the requested
  two-cut/highlight/keyframe/transition scenario can be accepted.
- Full save/reopen, restart ownership, human-edit races, modal behavior, x86_64
  execution, rendered picture/audio and user acceptance remain unperformed gates.

## Current source markers

- [SpliceKitV4Audio.m:221](../../Sources/SpliceKitV4Audio.m#L221): Native copy depth and stereo-group preservation need
- [SpliceKitV4Color.m:4](../../Sources/SpliceKitV4Color.m#L4): These are logical binding names, not a calibrated native
- [SpliceKitV4Core.m:179](../../Sources/SpliceKitV4Core.m#L179): Phase-two FCP tests must prove notification coverage for
- [SpliceKitV4Core.m:290](../../Sources/SpliceKitV4Core.m#L290): Real FCP modal/startup loops need phase-two scheduling tests.
- [SpliceKitV4Core.m:379](../../Sources/SpliceKitV4Core.m#L379): FFUndoHandler transactions must be exercised
- [SpliceKitV4Media.m:141](../../Sources/SpliceKitV4Media.m#L141): Audio identifier 0 must be checked against the audible AV
- [SpliceKitV4Parameters.m:78](../../Sources/SpliceKitV4Parameters.m#L78): Component-local -> native curve alignment on trimmed, nested and retimed effects needs the live fixture.
- [SpliceKitV4Retime.m:11](../../Sources/SpliceKitV4Retime.m#L11): Native mapping semantics for nested trims, reverse and holds
- [SpliceKitV4Titles.m:49](../../Sources/SpliceKitV4Titles.m#L49): these optional selectors are present in the existing CaptionPanel path,
- [SpliceKitV4Transitions.m:57](../../Sources/SpliceKitV4Transitions.m#L57): mediaRange versus clippedRange availability must be checked against
- [SpliceKitV4Transitions.m:102](../../Sources/SpliceKitV4Transitions.m#L102): the direct operation's array/output semantics require the live
- [SpliceKitV4Transitions.m:144](../../Sources/SpliceKitV4Transitions.m#L144): transition object / coerceEdit / cut-time semantics need live
- [review.py:34](../../mcp/splicekit_v4/review.py#L34): the current share.export only opens a share flow. It provides

13 current source markers; each remains scoped to its stated limitation.
