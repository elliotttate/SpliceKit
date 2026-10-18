# Media workstream

This is the historical workstream report. [Integration README](README.md) and
[validation](VALIDATION.md) describe the final merged contract and current limits.

Branch: `v4/media`. Base: upstream `223694a`. This is an offline implementation;
FCP was not started, the installed application was not modified, and nothing was
deployed, imported, pushed or published.

## Delivered behavior

18 RPCs are registered using the existing native plugin method registry. Existing
v3 endpoints and `mcp/server.py` are unchanged. Media mutations require the v4
core; standalone v3 dispatch returns `CORE_REQUIRED` before writing.

- **Color:** `v4.color.inspect` forwards the exact-instance parameter tree and
  exposes logical Board/Wheels/LUT control names with allowed types.
  `v4.color.apply_adjustment` creates a correction using a full native catalog ID,
  or writes named values using explicit instance-discovered parameter paths.
  Creation and adjustment are separate calls, so a new instance is inspected
  before assigning any paths. Curves/Hue-Sat can be created and inspected;
  their custom control-point buffers cannot be written by this implementation.
- **Audio:** independent `inspect`, absolute `set_gain` in dB with constant or
  exact-time keyframe mode, one-edge `fade`, audio-only `effect.add`, bound EQ band
  and compressor `effect.configure`, native factory `apply_preset`, source enable
  `get_channel_map`/`set_channel_map`, and existing-UID `set_role`.
  `ducking.plan` records the exact music/dialogue targets and the missing activity,
  automation merge and native-support requirements. It does not execute ducking.
- **Retime:** `inspect` reads native rate/segment count and source/component/
  timeline sample relations. `set` supports constant rate with explicit ripple,
  one reverse toggle, a timed freeze, and native to/from-zero ramps. Real `CMTime`
  structures and output pointers match the binary ABI, rather than the object
  placeholders in some existing direct-action examples.
- **Analysis:** `start/status/cancel/result` implement a bounded, process-local
  **blocked admission** contract for object tracker, shape/magnetic/auto mask,
  Smart Conform and stabilizer requests. `start` returns
  `UNSUPPORTED_ANALYSIS_ADAPTER`, `applied:false`, `native_started:false`,
  `ready:false`. No native task is submitted. Cancellation changes only a local
  blocked admission; result always reports `ANALYSIS_NOT_READY`. These are not
  advertised as working native analysis adapters.

## Addressing, types and transaction boundaries

Clip addressing is the params workstream's native `persistentID`, resolved
unambiguously within the active sequence. Effect addressing is native `fileUUID`,
never a display name, stack index or synthetic identity. Traversal is bounded;
ambiguous identities, unsupported receiver signatures and missing objects fail
before a native write. Selection is never a fallback.

Named color/EQ controls reuse `target`, `parameter_path`, typed `value`, `mode`,
and rational `time` from `docs/v4/PARAMS-CONTRACT.md` in the params workstream.
They describe every path and validate types/values before the first write. Constant
named writes preflight existing animation. A parameter-path binding is supplied
by the caller after inspecting this exact instance; **there is no built-in
name-to-channel calibration or native color-family classifier**. Logical names
are not claims about parameter units. No UI percent, Hz, Q, milliseconds, enum
ordinal or FCPXML channel key is guessed.

Example after exact-instance discovery:

```json
{
  "target": {"clip_id": "native-persistentID", "effect_instance_id": "native-fileUUID"},
  "family": "board",
  "time": {"value": 330, "timescale": 30, "space": "clip_local"},
  "bindings": {"exposure.master": "/effects/native-fileUUID/channels/ACTUAL_DISCOVERED_ID"},
  "adjustments": {"exposure.master": {"type": "double", "value": 0.1}},
  "mode": "at_time"
}
```

The placeholder in this example must be replaced by an actual discovered path.
String LUT controls require `constant` mode. Arbitrary Curves/Hue-Sat point arrays
are explicitly rejected instead of passed through a scalar setter.

The core owns serialization, operation IDs, revision preconditions, UNKNOWN
reconciliation and the outer undo group. Domain edits use verified native actions
or native action begin/end with undo snapshots. A thrown mutation closes its
native transaction and reports `applied:null`; a known write with a readback
mismatch reports `applied:true` and an error. Multi-parameter failures retain
completed readbacks and never claim automatic rollback. Undo ownership is
established by the core's observed native manager, not by a handler promise.

Gain uses `10^(dB/20)` for the native linear amplitude channel. Constant gain
rejects any existing keyframes; point writes verify an exact-time native key.
Native audio identifier 0 is explicit and never falls back to the video stack.
Retime samples call native time conversion APIs; they are not a complete exported
curve or a unique inverse. Holds/reverse can produce multiple timeline matches.

## Files

- `Sources/SpliceKitV4Media.{h,m}`: validation, runtime ABI checks, exact target
  resolution, native transaction helper, result envelopes and method registration.
- `Sources/SpliceKitV4Color.m`, `SpliceKitV4Audio.m`, `SpliceKitV4Retime.m`,
  `SpliceKitV4Analysis.m`: domain handlers.
- `Sources/SOURCES.txt`: five added compilation units.
- `mcp/splicekit_v4/capabilities/media.json`: 18 input/output schemas, backends,
  undo/readback declarations and explicit limitations; all `offline_tested`,
  build-bound to FCP 12.4 / `454072`.
- `tests/v4/media_mock.m`, `tests/test_v4_media.py`: execute the actual native
  implementation against typed mock objects and validate published contracts.
- `tests/live/v4/media.json`: fenced live fixture template, 11 runner cycles,
  and manual fixture/readback/undo instructions for all 18 RPCs.
- `docs/v4/media-selectors.tsv`: 80 relevant ABI rows from the B report's static
  FCP 12.4 binary extraction. Foundation/AppKit runtime operations use public APIs.

The evidence source is the supplied research's
`B-evidence/objc-methods.jsonl.gz` (binary, class, selector, encoding and otool line),
plus B gaps 6–17/20, C sections 3.3/5.7/6 and E section 6.4. No live runtime
introspection or binary decompiler was run in this workstream.

## Validation

- New native mock: **72/72 behavioral checks passed**, including dB conversion,
  trimmed timeline time conversion, keyframe preservation, mismatches, partial
  failures, transaction closure, duplicate IDs, source channel maps, role type
  validation, presets, shared named paths, real freeze/ramp ABI and all six blocked
  analysis kinds. Nested anonymous FCP `CMTimeRange` ABI is covered explicitly.
- `python3 -m unittest discover -s tests -p 'test_*.py'`: **73 tests, OK,
  2 skipped** (optional OpenTimelineIO fixture dependency). This discovery does not
  run the separate live endpoint or Apple Intelligence CLI suites.
- Agent workstream's `CapabilityRegistry` loaded all **18 capabilities** using its
  JSON Schema validator. No dependencies were installed by this workstream.
- Tests workstream's live-plan validator accepted **11 cycles / 18 manual cases**.
  The plan remains `template:true` until real native identities are bound; it has
  not been executed against FCP. Target-local projections do not establish a full
  project semantic restore; complete exported XML comparison is a required manual
  gate before widening acceptance.
- All five added native objects compile for **arm64 and x86_64** with the existing
  Makefile. Native mock execution was on the current Mac architecture only.
- Full `make`: **BLOCKED at the existing BRAW link guard**, after compilation:
  `_SpliceKit_bootstrapBRAWAtLaunchPhase` and `_SpliceKit_handleBRAWAVProbe` are
  missing when the Blackmagic SDK is absent. Their definitions in
  `SpliceKitBRAW.mm` are inside `#if SPLICEKIT_HAS_BRAW_SDK`, while the fallback
  branch lacks these two symbols. No media symbol was unresolved. This unrelated
  source was not edited; core/head were notified. The integration needs a separate
  no-SDK fallback build fix. Logs are local build artifacts under `build/`.

## UNVERIFIED and live risks

No invented private selector is invoked. The code's `// UNVERIFIED:` comments
mark behavior that static ABI evidence and mocks cannot prove:

1. `SpliceKitV4Media.m`: audio identifier 0 must correspond to the intended audible
   component on AV, compound, trimmed and multichannel fixtures. Other components
   are currently unsupported.
2. `SpliceKitV4Color.m`: logical control names require actual per-instance path
   and unit calibration. Native family matching is not implemented.
3. `SpliceKitV4Audio.m`: native channel-map copy depth, zero-based source enable
   semantics, stereo-group preservation and complete native undo need live proof.
   All copy mutation occurs after an undo snapshot inside the native edit group.
4. `SpliceKitV4Retime.m`: component/source/timeline mapping for nested trims,
   reverse and holds needs independent exported XML and native playback checks.

Also verify that AU insertion lands in the intended audio component, factory
presets restore their entire AU state, fade duration/default-shape behavior is
correct, gain keyframe option 1 preserves unrelated automation, role assignment
does not change unrelated subroles, and owned undo restores every operation.
Preview color-space/tonemap metadata is deliberately null. No picture, listening,
save/reopen durability or user-acceptance claim has been made.

## Deferred scope

- Built-in calibrated Board/Wheels/LUT channel tables and automatic family
  classification; all Curves/Hue-Sat custom control-point writes.
- Automatic AU band/unit/preset discovery, file presets, channel routing/stereo
  group edits, component-specific roles and more than audio identifier 0.
- Native ducking execution, dialogue activity analysis and automation merge.
- Arbitrary piecewise retime keys/falloff editing, full curve export/inversion and
  optical-flow quality analysis.
- Native tracker, mask, Smart Conform and stabilizer execution/result/cancellation
  adapters. Idle flags are not readiness evidence.
- Multicam exact-time angle switching and AV split (B gap 20).

## Upstream PR split

1. Media ABI/result/target helpers and exact native audio gain/fade/readback,
   depending on the operation core and with live undo/audio evidence attached.
2. Color and EQ named bindings using the shared parameter contract, plus explicit
   custom-curve limitations and fixture-backed calibration in follow-up PRs.
3. Retime ABI-correct actions and source/timeline readback with native fixture
   evidence, independently reviewable from audio/color.
4. Honest analysis admission/discovery contract; native adapters only in later
   PRs after their data formats and readiness/cancellation evidence are resolved.

No upstream PR or external communication was created.
