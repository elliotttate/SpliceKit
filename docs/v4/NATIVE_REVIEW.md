# Native review capture contract and integration design

Integrated beta status: native `review.capture` is fenced because the current
state probe does not attest project-viewer identity/readiness. The contract below
is implemented and tested against the offline fixture; native Share remains
unavailable. See [README](README.md).

`review.capture` takes exact project/sequence/revision, a half-open rational time
range of at most ten seconds, `mode`, and `max_dimension` (64–1280; default 640).
The output is a common envelope containing `readback.artifact`. Artifact metadata
records source of pixels, actual coverage, requested context range, audio presence,
proxy/color state, FCP identity/revision, byte SHA-256 and metadata binding hash.
A receipt never marks visual/audio review passed merely because export succeeded.

## Implemented frame route: offline-tested, live acceptance pending

1. Read native project/sequence/revision and stopped playback. Require a rendered
   viewer, native frame rate/aligned playhead, and `viewer_sequence_id` matching
   the project sequence. Unknown readiness or browser-source identity fails closed.
2. Call the existing `viewer.capture` with a unique path and `viewer:"normal"`.
   Require `status:"ok"`, `cropped:true`, matching file path and
   `capture.selectedViewer:"normal"`. Reject full-window/largest-view fallback.
3. Validate the PNG header; resize the native pixels using `/usr/bin/sips -Z` if
   needed. This performs image resizing only; it does not compose or render edits.
4. Read state again. Identity/revision/playhead/readiness must still match. Hash
   the actual resized PNG and write a sidecar JSON binding it to native identity.
   Actual artifact coverage is one frame. `has_audio:false`; motion/audio remain
   unchecked. Proxy/color states remain unknown unless native evidence supplies them.

Static source anchors in upstream 223694a:
`Sources/SpliceKitServer.m:19393–19482` selects `normal`/`360` player views through
existing target/player/video modules; an arbitrary `project` string would instead
select the largest player and is deliberately not used. Lines 19484–19613 capture
GPU/window pixels and write the cropped PNG. Existing methods/selectors are reused;
this workstream adds no unverified FCP selector or new native review RPC.

**UNVERIFIED:** target-module selection with multiple viewers/windows; readiness
and displayed-frame latency; screen-recording permissions; pixel/color/proxy truth.
Before/after state detects changes but cannot make a legacy capture atomic with a
human edit or a change-away/change-back. Native core needs an owned capture lock
or a single main-thread capture/readback operation before promoting this route to
live_verified. A model critique of a still cannot establish motion/audio quality.

## Native Share video route: designed, not enabled

The existing `share.export` (`Sources/SpliceKitServer.m:19052`) either executes the
selected share destination menu or sends `shareDefaultDestination:`. It returns
that invocation result; it does not own an output file, completion, requested range,
codec, dimensions, audio or revision. Calling it is not a completed preview.
Accordingly `mode:"native_share"` returns `NATIVE_SHARE_UNVERIFIED` without opening
any dialog or inventing an artifact.

A future native adapter should register `v4.review.start/status/cancel` through the
plugin registry, with a dedicated local-only low-resolution FCP Share preset:

- Start under native ownership with project/sequence/revision, rational frame-aligned
  range, maximum dimension, explicit audio request and an application-generated
  unique destination path. Resolve a native exporter/job through build-scoped
  probes; **UNVERIFIED: no private exporter selector is asserted here**.
- Return a job/operation ID and pending state. Opening a share/save dialog, preset
  mismatch, or unknown exporter support remains pending/unsupported, never success.
- Hold the baseline identity until FCP finishes the short export; do not switch
  renderer, reconstruct proxies, invoke ffmpeg, or silently repeat after timeout.
- On completion require a finalized nonempty local file and native job success.
  Inspect dimensions/range/rate/codec/audio with AVFoundation, not filename claims.
  Bind before/after revisions, exact covered range, color/proxy settings and file
  SHA-256 in the artifact manifest. Reject external/human revision changes.
- Restore temporary range/preset/playhead only under ownership and verify readback.
  Cancellation/timeout must expose terminal native job status before any retry.

Live fixtures and undo/race/permission cases are specified in
[`tests/live/v4/agent.json`](../../tests/live/v4/agent.json). No FCP/SpliceKit launch,
installed application write or paid model request was run for this workstream.
The final offline test runner explicitly blocks native TCP connections. The optional
`--live` example requires the merged core/native bindings
and separate authorization to run a live test host.
