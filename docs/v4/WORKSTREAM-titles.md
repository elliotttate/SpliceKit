# v4 titles, captions, transitions and generators

This is the historical workstream report. [Integration README](README.md) and
[validation](VALIDATION.md) describe the final merged contract and current limits.

Implementation workstream: `titles`, branch `v4/titles`, based on upstream
`223694a` (3.3.9). No Final Cut process was launched, no installed application
was modified, and no deployment, push or PR was performed.

## Delivered surface

| RPC | Behavior |
| --- | --- |
| `v4.title.insert` | Instantiate the exact installed title effect and anchor it at an explicit rational start/duration and connected lane. Return the native persistent `clip_id`. |
| `v4.title.get` | Read every indexed native text field, all supported attributed-text runs, pixel position, lane, effect ID and rational timing. |
| `v4.title.set_text` | Replace one explicit `field_index`, retaining the initial run's native attributes. Other fields are not selected by name or channel-tree order. |
| `v4.title.set_style` | Patch disjoint UTF-16 ranges with font, point size, sRGB fill, signed stroke width/color, shadow and paragraph alignment. Optionally update the clip's pixel x/y position, preserving z. |
| `v4.caption.list` | List actual `FFAnchoredCaption` objects, indexed blocks/lines, persistent identities, timing and existing caption roles in the active sequence. |
| `v4.caption.set_text` | Update one native text block through `updateCaptionTextBlock:withAttributedStrings:`; retain each existing line's initial attributes. |
| `v4.caption.set_timing` | Update duration and reanchor at an explicit timeline start, preserving the existing lane. Reject out-of-project intervals and overlaps in the same role. |
| `v4.caption.set_role` | Assign an existing caption role object, preserving its native language/format binding. |
| `v4.transition.set` | Target an explicit adjacent primary clip pair, exact effect and duration; require `fail`, `shorten` or `freeze` handle policy. Read back the transition and verify project duration. |
| `v4.transition.remove` | Remove the transition at that cut using the native time-preserving operation, optionally checking its persistent identity; absent transitions are a no-op. |
| `v4.generator.insert` | Instantiate and anchor a real generator with exact lane/start/duration. Return persistent identity plus a separate runtime handle for the params workstream. |

All capabilities are `offline_tested`, scoped to Final Cut Pro **12.4 build
454072**. Selector evidence does not establish native operation semantics or
rendered output. In particular, freeze behavior is a requested native overlap
mode, not a claimed visual verification.

## Files and registration

- `Sources/SpliceKitV4TitlesSupport.{h,m}`: rational/frame validation, active
  sequence traversal, persistent-ID lookup, common result envelope, native undo
  grouping, dispatch cancellation and transform access.
- `Sources/SpliceKitV4TitleStyles.m`: attributed-text patches and complete supported
  style-run serialization.
- `Sources/SpliceKitV4Titles.m`: indexed title text, title insertion and generator
  insertion. Reuses CaptionPanel's effect-level text/persistence path rather than
  sending strings to a numeric channel setter.
- `Sources/SpliceKitV4Captions.m`: native caption blocks, roles and timing. Reuses
  the same object model as CaptionPanel without transcription, temporary project
  imports, clipboard changes or synthetic input.
- `Sources/SpliceKitV4Transitions.m`: explicit cut targeting, source-handle policy
  and readback. Does not call legacy `transitions.apply`, change preferences or
  depend on the current selection.
- `Sources/SOURCES.txt`: canonical build registration. Constructors register all
  eleven full RPC names and metadata through the existing plugin method registry.
  **No change to `Sources/SpliceKitServer.m` is required.**
- `mcp/splicekit_v4/capabilities/titles.json`: eleven standalone input/output
  schemas and capability descriptors compatible with the agent workstream's
  descriptor format (`backend`, `method`, `undo_kind`, readback support, exact
  build scope and limitations). `mcp/server.py` changes only for the isolated
  legacy boolean bugfix.
- `tests/native/v4/titles_mock.m`, `tests/test_v4_titles.py`: executable native
  boundary mocks and schema checks.
- `tests/fixtures/v4/titles-selector-evidence.json`: 39 static selector/ABI records
  with original otool/nm source lines from research report B.
- `tests/live/v4/titles.json`: unexecuted fixture, steps, readback, visual,
  save/reopen and operation-owned undo/redo checks.

Research inputs: A section 3, B gaps 2 and 18, C sections 5.4–5.6 and 8, and the
existing CaptionPanel implementation. The critical selector/ABI evidence is
included in the fixture so reviewers do not need the local research directory.

## Contract and integration decisions

- Times are `{value, timescale}` rationals, aligned exactly to the sequence frame
  grid. Input integers are bounded to JSON's exactly representable range.
- Insertions require an existing primary storyline and a clear connected lane
  in **[1,1024]**. Lane 0 would require a separate explicit primary/ripple edit
  contract and is rejected. Generator parameter dictionaries are not guessed or
  written during insertion.
- `clip_id` is the native `persistentID`, resolved again in the active sequence on
  each request. No pointer, array index or in-memory handle is called durable.
  `object_handle` is explicitly separate and transient. The
  `parameter_inspection` result is a handoff hint for `v4.object.inspect`; its
  argument schema remains owned by the params workstream.
- Title `field_index` uses the native `textFieldCount` / `textForField:` /
  `setText:forField:` interface. No assumption maps the first `CHChannelText`
  encountered in an arbitrary folder tree to the requested text field.
- Span ranges use UTF-16 offsets. Overlaps, out-of-bounds spans and splits inside
  composed characters/surrogate pairs are rejected before a timeline edit.
  Font lookup fails explicitly rather than silently substituting a font. Negative
  stroke width means fill plus stroke, matching CaptionPanel's existing path.
  Alignment has AppKit paragraph semantics; position applies to the clip at
  `source_start`, not to one word or glyph.
- Caption edits require an explicit block index. Role assignment uses existing
  native roles, not fabricated `ITT.xx` IDs or undocumented role-constructor
  enum values. New language/format role creation is outside this surface.
- Transitions currently accept ordinary unretimed media clips with source sample
  duration exactly matching the sequence frame duration. Centered durations must
  contain an even number of frames. `fail` rejects insufficient handles before
  editing; `shorten` reduces the transition to twice the smaller available
  whole-frame handle count; `freeze` explicitly requests native overlap mode 2.
  Project duration is checked after set/remove, and a mismatch is an error rather
  than a successful ripple trim.
- The sequence's own `undoHandler` supplies `undoableBegin:` /
  `undoableEnd:save:error:`; `finally` closes the group on exceptions. Effect
  updates also request `storeForUndo` where exposed. Native undo/redo remains a
  live acceptance requirement; opening a group is not proof of correct inverses.
- Every RPC returns the common v4 envelope. Caller/core-assigned `operation_id`
  is retained. `revision_before` and `revision_after` are null locally; the core
  dispatcher owns global revisions, the writer queue, idempotency, reconciliation
  and operation-owned history. If `expected_revision` is supplied without an
  executing core dispatcher, the handler fails closed instead of ignoring it.
- Core integration is through registry metadata (`readOnly`, `v4Undo`,
  `v4RequiresSequence`), with no compile-time dependency on another workstream.
  Mutations complete synchronously when called on the core's main thread.
- Standalone off-main dispatch has a 10-second wait. A pending operation is
  cancelled before execution; an already running operation returns
  `TIMEOUT_UNKNOWN`, `applied=null`, `retryable=false`. It must be reconciled
  before any repeat. A potentially partial native failure is never reported as
  `applied=false`. Available mismatch readback is retained.
- Evidence remains `offline_tested`. The envelope warns that live verification
  is pending; no fake global revision or rendered acceptance is emitted.

## Isolated compatibility fixes

1. **`da3d012` — explicit false transition transport.**
   `apply_transition(freeze_extend=False)` now sends `freezeExtend: false` instead
   of omitting the key and triggering the native handler's default `YES`.
   `tests/test_transition_transport.py` extracts and executes the actual wrapper
   with a fake bridge, testing false, true and the default. This commit can be
   submitted upstream independently and does not claim to repair the existing
   disabled freeze-auto-hold implementation.
2. **`48a52a3` — missing no-SDK BRAW exports.**
   The first full build exposed an upstream baseline link-check failure:
   `SpliceKit_bootstrapBRAWAtLaunchPhase` and `SpliceKit_handleBRAWAVProbe` were
   defined only in the SDK-enabled branch of `SpliceKitBRAW.mm`, but referenced
   unconditionally. `SpliceKitV4BRAWCompatibility.m` supplies a no-op optional
   bootstrap and an explicit SDK-unavailable probe result only when the exact
   same SDK-header condition is false. The SDK-enabled implementation is
   unchanged. `tests/test_braw_no_sdk_exports.py` verifies both C exports for
   arm64 and x86_64. This prerequisite fix is also independently reviewable.

## Verification

The full `make` target succeeds and produces an arm64/x86_64 universal dylib.
The existing linker warning about BRAW decoder pointer alignment is unrelated
and remains visible in the build log. No deployment target was run.

Offline commands, from this worktree:

```sh
# Full Draft 2020-12 validation uses the lightweight jsonschema test dependency.
# It was installed only under ignored build/, not into a global environment.
python3 -m pip install --target build/titles-test-deps jsonschema
PYTHONPATH=build/titles-test-deps python3 -m unittest discover -s tests -p 'test_*.py'
make
```

The offline suite contains **75 tests**: **73 pass**, **2 skip** because the
optional OpenTimelineIO package is not installed. The new native executable
passes **583 assertions** across all eleven RPCs, including JSON-serializable
result envelopes. Every recorded native result is validated against its
capability output schema. Positive live-plan requests validate against the
input schemas; malformed lane, field, block, duration and missing-policy inputs
are rejected by schema tests.

Native mock coverage includes explicit second-field edits, independent word
styling, stroke/shadow/alignment/position readback, composed Unicode boundaries,
empty text, lane collisions, off-frame inputs, stale identities, native multiline
caption blocks, timeline versus source timing, caption roles, transition
replacement/removal, all three handle policies, mixed-rate rejection, observed
readback mismatch, native commit failure, missing revision guard, cancelled queued
writes and already-running timeout ambiguity. These are boundary/contract tests,
not a substitute for executing the actual FCP object methods.

## UNVERIFIED list and live acceptance

1. `SpliceKitV4Titles.m`: optional Motion selectors
   `syncChannelStateForXMLExport`, `saveDirtyTextToEffectValues` and
   `_channelsChanged` are reused from CaptionPanel and guarded with
   `respondsToSelector:`. They are absent from the available static metadata
   snapshot. Actual Basic Title persistence, correct rendering of all spans,
   stable identity after reopen, and native undo/redo require live checks.
2. `SpliceKitV4Transitions.m`: `mediaRange` / `clippedRange` source-handle
   interpretation, explicit-duration operation collection/output arguments,
   existing-transition replacement, and overlap mode 2 frozen-edge rendering
   require the disposable live fixtures. Selector names and ABIs are verified;
   object argument semantics and freeze imagery are not.
3. `SpliceKitV4Transitions.m`: the object, `coerceEdit` and cut-time semantics of
   `operationRemoveTransitionPreservingTime:coerceEdit:toTime:` require live
   readback/export/undo checks. Failure or changed total timing is reported as an
   error, with no automatic retry or unrelated global undo.

Caption text-block/role behavior, caption reanchoring, generator parameter-tree
handoff and every mutation's owned undo/redo also remain live acceptance gates.
The test plan includes Basic Title, yellow word emphasis, Cross Dissolve, native
caption correction, existing-role language binding, a real generator, each
handle policy, fresh FCPXML readback and save/reopen checks. Its status is
`not_run`; promote evidence only after those checks pass.

## Upstream split

- Submit the explicit-false MCP transport fix alone.
- Submit the no-SDK BRAW missing-export fix alone.
- Submit native title/span support and generator insertion with the shared
  support/style files, descriptors and tests. Captions and transitions can be
  split into subsequent PRs using the same helper, retaining their own live
  evidence and documented limits.
- Integration should merge this workstream's new source-list entries, manifest,
  fixture and live plan. There is no proposed `SpliceKitServer.m` patch and no
  dependency on an unimplemented params API.
