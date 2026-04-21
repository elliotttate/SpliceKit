# FCP Support Gap Analysis

## What "full support" appears to mean in DaVinci terms

Based on the guides and the decompilation results, "full support" for immersive BRAW is not just:

- decoding the clip
- showing both eyes
- exporting something Vision Pro can read

In Resolve, full support appears to include:

1. Immersive project mode with dedicated timeline defaults.
2. Import that keeps both eyes and immersive metadata unified in one logical clip.
3. Projection-aware viewing and monitoring.
4. Editing rules that respect per-shot lens space.
5. Fusion/compositing workflows that can flatten and re-warp safely.
6. Live Vision Pro preview and stream transport.
7. Delivery presets that preserve or flatten immersive semantics intentionally.
8. An immersive-audio path.

That is a much larger target than a decoder patch.

## Current likely gaps for FCP / SpliceKit

Relative to the Resolve model, the missing or incomplete categories are likely:

| Area | Gap |
| --- | --- |
| Media model | FCP does not appear to expose a first-class immersive-BRAW clip abstraction with both-eye ownership plus timed immersive metadata. |
| Lens / calibration metadata | ILPD / projection kind / projection data / interaxial / calibration type need durable storage and accessors. |
| Motion metadata | Gyroscope, accelerometer, and orientation streams need to survive ingest and remain queryable. |
| Edit semantics | Titles, backdrops, transitions, and clip-boundary rules need immersive-specific validation and rendering policy. |
| Viewer | Need lens, lat-long, and viewport modes, not only a flat frame viewer. |
| Vision Pro preview | Need peer discovery, frame push, metadata playback, and headset control surfaces. |
| Interchange | Need a way to represent dynamic immersive commands and transition policy in exportable metadata. |
| Audio | Need at least a strategy for immersive-audio export if not a full ASAF working environment. |

## The parts that map best to existing SpliceKit directions

Some of Resolve's architecture overlaps well with what SpliceKit is already set up to explore:

- Vision Pro tooling already exists in the repo and can likely align with AIME/static-metadata work.
- FCPXML generation and parsing are already central to SpliceKit workflows.
- Direct ObjC access inside FCP makes it realistic to surface new metadata and preview controls without UI automation hacks.

That means the best path is probably not "recreate Resolve's UI". It is:

- surface the underlying media and metadata primitives in FCP
- build proof-of-work preview and export flows
- then add ergonomic editing behavior on top

## Recommended implementation order

### Phase 1: media introspection

Goal: prove what immersive data FCP can already see or preserve.

- Add import-time or clip-level probes for:
  - both-eye identity
  - projection and calibration metadata
  - timed immersive sample tracks
  - motion sensor streams
- Build dump tools that expose this at clip and frame scope.
- Compare FCP-imported immersive BRAW against Resolve's raw surfaces.

### Phase 2: static and dynamic metadata model

Goal: make immersive metadata first-class in SpliceKit.

- Define a static metadata object model compatible with:
  - AIME
  - camera ids
  - lens and rig geometry
  - masks / venue / calibration details where relevant
- Define a dynamic metadata model compatible with:
  - timed commands
  - camera-change events
  - shot-flop or similar presentation commands
- Verify whether FCPXML can carry enough structure directly or needs a sidecar.

### Phase 3: preview and monitoring

Goal: make immersive work inspectable before editing policy work.

- Add projection transforms for:
  - native lens view
  - lat-long
  - viewport
- Extend the existing Vision Pro session work toward:
  - device discovery
  - frame push
  - static metadata handoff
  - dynamic metadata playback

### Phase 4: editing semantics

Goal: stop treating immersive clips like normal clips.

- Enforce title boundary constraints.
- Introduce backdrop-style support or an equivalent concept.
- Add immersive-aware transition behavior:
  - semantic transition intent
  - explicit flatten/bypass/export options
- Expose motion comfort diagnostics from metadata.

### Phase 5: delivery

Goal: produce outputs that preserve immersive intent.

- Support Vision Pro review-style outputs.
- Support archival/full-fidelity bundle outputs.
- Support EXR or other VFX turnovers without dropping both-eye and lens metadata.
- Decide whether audio is:
  - passthrough
  - externalized
  - or eventually integrated into an immersive-audio bridge

## Immediate reverse-engineering next steps

The framework-wide decompiles already gave the architectural picture, but the next high-value tasks are:

1. Finish the targeted `Resolve` binary slice and extract app-level immersive timeline and delivery glue.
2. Trace where `ProtoVideoProcParamsBRAW`, `isspatialvideo`, `projectionformat`, and `stereoscopicmode` are consumed.
3. Inspect how Resolve chooses between:
   - headset-rendered transitions
   - pre-rendered transition streams
   - flattened timeline transitions
4. Inspect whether the EXR re-import path writes a reusable metadata sidecar or embeds enough optical metadata directly in the render package.

## Artifacts created in this repo

These reverse-engineering helpers were added during this pass:

- [`tools/ida_targeted_slice.py`](../../tools/ida_targeted_slice.py)
- [`tools/decompile_resolve_immersive_braw.sh`](../../tools/decompile_resolve_immersive_braw.sh)

Primary outputs live under:

- `analysis/resolve_immersive_braw/BlackmagicRawAPI-full`
- `analysis/resolve_immersive_braw/ImmersiveVideoToolbox-full`
- `analysis/resolve_immersive_braw/Resolve-targeted`
- `analysis/resolve_immersive_braw/source_pdfs`

## Bottom line

If the target is "full immersive BRAW support in FCP", the DaVinci evidence points toward a platform feature, not a codec feature. The minimum credible implementation is:

- immersive clip model
- projection and calibration metadata
- dynamic metadata playback
- Vision Pro preview path
- immersive-aware edit rules

Everything else is a partial bridge.
