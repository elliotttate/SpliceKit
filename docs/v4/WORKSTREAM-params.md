# Parameters workstream

This is the historical workstream report. [Integration README](README.md) and
[validation](VALIDATION.md) describe the final merged contract and current limits.

Branch: `v4/params`, based on upstream `223694a` (3.3.9). Implementation and static/offline verification only. No Final Cut Pro launch, deployment, bridge connection, library mutation, upstream push, or PR occurred.

## Delivered surface

Thirteen native RPCs are registered through the existing plugin method registry, with read-only metadata. They are described by self-contained input/output schemas in `mcp/splicekit_v4/capabilities/params.json`:

- `v4.effect.catalog`, `add`, `remove`, `enable`, `move`.
- `v4.object.inspect`.
- `v4.parameter.describe`, `get`, `set`.
- `v4.keyframe.list`, `set`, `delete`, `set_interpolation`.

The exact shared addressing and typed values are documented in [PARAMS-CONTRACT.md](PARAMS-CONTRACT.md). Media wrappers can call `describe` and receive the metadata leaf directly at `readback.type`, `readback.writable`, etc. Native gain is also discoverable under `/intrinsic/audio`; remaining intrinsic channels are under `/intrinsic/native`.

The legacy MCP effect/transition formatters now preserve complete identifiers. The root cause was the `[:40]` / `[:50]` formatting slices in `mcp/server.py`, not truncation by the native registry. This narrowly authorized two-line fix is isolated in commit `15acd47` so the agent workstream can integrate it without taking unrelated server changes.

A full build exposed an existing no-BRAW-SDK link failure. Both `SpliceKit_bootstrapBRAWAtLaunchPhase` and `SpliceKit_handleBRAWAVProbe` had unconditional callers but no SDK-free definitions. Commit `784f19c` adds matching no-op/unsupported fallbacks and an actual compiled export regression test. It does not enable BRAW or install its SDK.

## Design and limits

Targets resolve a native clip `persistentID` against the active sequence graph, then an exact effect `fileUUID` belonging to that clip. Missing/duplicate identities fail closed. Handles, display names, array positions and effect type IDs never substitute for an instance identity. Effect operations read the complete ordered inventory; removal supplies a one-element instance array. Move uses native section and instance identities, and rejects cross-section destinations and intrinsic effects. Add accepts video filters/audio effects; title, generator and transition insertion belongs to their dedicated workflows.

Paths include every numeric native `channelID`, including the root. Sibling collisions, graph cycles and bounded traversal limits are errors. UI names are localized metadata. Read-only inspection does not create default intrinsic effects. Present transform, crop/trim/Ken Burns, four-corner distort, opacity/blend and gain channels share this tree. Intrinsic selector bindings let consumers find scale axes without localized label matching. Unavailable components remain explicit `available:false` entries.

The supported values are double, native angle, int32, bool, remapped enum, native-curve RGBA, 2D/3D point and static string. Each type has a distinct native getter/setter; no generic string/boolean/RGBA-to-double conversion. Enum values use `intValueForIndex:`; UI ordinal assumptions are forbidden. Data limits and UI limits remain separate. Unestablished units and ranges are null. Geometry and color stay in native curve coordinates; the bridge does not invent UI percent/pixel/dB/color conversions.

Explicit time is a signed int64 numerator and positive int32 denominator. `clip_local` means native component-local time, not elapsed time since the visible trimmed start. Timeline mapping uses the host's `containerToLocalTime:container:` and reverse mapping, preserving retime/container ownership rather than subtracting a floating clip start. `NSInvocation` handles struct-return ABI on Intel and ARM. Finite numeric time, epoch zero and explicit space are required; there is no time-zero/playhead fallback.

`at_time` verifies exact key presence and typed readback, and compares all other existing key times/values/interpolation codes before and after. Compound curves use discoverable scalar descendants for preservation checks; opaque curves fail before writing. `constant` refuses an existing curve rather than clearing it. Strings are constant-only. `keyframe.list` exposes scalar keys; compound consumers can inspect and address scalar children. One key is deleted by exact time. Scalar interpolation supports native engine hold (0), linear (1), and S-curve ease-in/out (21). The latter is not claimed to equal the UI's spatial Smooth tangents. Arbitrary custom easing/tangent buffers are unsupported.

Every operation produces the common result envelope. Writes read back both while the native group is open and after it is saved. A mismatch is an error with `applied:true` and actual state. Native save failure produces `applied:null`, `undo.kind:unknown`, and no automatic retry. Revisions are deliberately null until the core integration supplies its transaction fence. Operation IDs are correlation only, not standalone idempotency keys.

## Required core integration

`SpliceKitServer.m` is untouched by this workstream. Its legacy final router currently treats `error:NSNull` as an old string error. Consequently the common success envelope needs the core-owned fix before end-to-end v4 success responses work over TCP. The original standalone router patch is superseded by early v4 routing and the explicit NSNull guard in `Sources/SpliceKitServer.m`. The integration implements that prerequisite; this is not a live test result.

The new native constructor schedules only method registration on the main queue. It does not start FCP or mutate a project. The agent workstream should ingest the capability JSON; no new public MCP slider tools are added here.

## Files

- `Sources/SpliceKitV4Effects.m`: full catalog and exact-instance lifecycle.
- `Sources/SpliceKitV4Parameters.{h,m}`: identity resolution, tree, typed values, time and envelope/action handling.
- `Sources/SpliceKitV4Keyframes.m`: native pointer iteration confined to one call, curve preservation, point CRUD and segment modes.
- `Sources/SOURCES.txt`: three new translation units.
- `mcp/splicekit_v4/capabilities/params.json`: 13 capability schemas.
- `tests/v4/build_params_contract.py`: reproducible schema generation.
- `tests/v4/params_native_tests.m`, `tests/test_v4_params.py`: production-code native mocks and contract/failure tests.
- `tests/test_effect_identity_output.py`, `tests/test_braw_optional_exports.py`: independent root-cause regressions.
- `tests/v4/verify_params_native_surface.py`, `docs/v4/params-selectors.tsv`, `docs/v4/params-channel-arm64.txt`: bounded reproducible selector ABI and interpolation/time evidence.
- `tests/live/v4/params.json`: coordinated, unexecuted native acceptance plan.

## Verification

`make` passes and produces a universal ARM64/x86_64 dylib. The Makefile fetches its pinned Sentry Cocoa framework into the worktree as an ignored build dependency. Existing linker alignment/deprecation warnings remain; there are no new params compiler warnings under the native test's `-Werror` build. No installed application is written.

`python3 -m unittest discover -s tests -p 'test_*.py' -v` passes: 75 tests, 2 skipped because optional `opentimelineio` is absent. The native production-handler test performs 130 checks, covers all 13 RPC output schemas, compiles with `-Werror`, and does not load FCP. Coverage includes repeated effect IDs, exact removal/bypass/reordering, remapped enums, bool versus number, HDR color, typed points/text/int, distinct data/UI bounds, nonzero rational times, timeline mapping, key preservation, post-save normalization and unknown native-save outcomes. The stdlib contract checker covers the schema vocabulary emitted by the generator; it does not claim full JSON Schema implementation conformance.

`python3 tests/v4/verify_params_native_surface.py` re-reads FCP 12.4 build 454072 binaries using `otool -ov`, `-tvV` and a small constant-table read. It records 191 relevant selector ABI entries. ProChannel's strategy constructors and getInterpolator table establish codes 0/1/21; the double reader disassembly distinguishes curve-local from evaluated values. These are static facts, not live host acceptance.

## UNVERIFIED and live acceptance

Explicit `// UNVERIFIED:` markers identify:

1. Component-local to native curve alignment for trimmed, nested and retimed effects.
2. The existing bridge's `options=0` exact-time write behavior in the real host; readback rejects missing keys/changed neighbors.
3. Native move's pre-removal insertion-index semantics; the handler verifies the resulting exact order and never retries on mismatch.

Additional live gates are native `persistentID`/`fileUUID` stability across save/reopen and undo/redo, group ownership and restoration, real Motion rig/channel trees and enum representation, native color/geometry/angle units, missing downloadable package payloads, and correct Viewer/audio output. Introspection does not claim all third-party custom parameters are supported.

The live JSON plan has cases for Gaussian, repeated Gaussian instances, Letterbox, Colorize, transform scale keyframes and all interpolation modes, crop/trim/Ken Burns/distort/opacity/blend/gain, and time/identity failure boundaries. Each requires native readback, owned undo, persistence and independent visual/audio checks. It has not been executed.

## Upstream PR split

1. Lossless legacy IDs plus isolated formatter regression (`15acd47`).
2. Optional BRAW SDK build/export fix plus compiled regression (`784f19c`); independently useful to source builders.
3. The cohesive native params/effect/keyframe surface, bounded static evidence and mock tests.
4. Agent/core integration consumes the schema and applies the envelope-router compatibility fix. Live acceptance is a separate coordinated wave before promoting evidence to `live_verified`.
