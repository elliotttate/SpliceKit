# Editing Fusion And Delivery

## Editing is mostly normal, but only inside immersive-specific rules

Resolve's workflow guide presents immersive editing as familiar editing with several non-negotiable exceptions. The key pattern is:

- ordinary cut-based editorial still works
- viewer and title behavior become projection-aware
- transitions and backdrops obey immersive-specific constraints
- Fusion has an immersive-safe compositing path

That is the right mental model for FCP parity too.

## Backdrops are a special track type with hard boundary rules

When immersive workflow mode is enabled, Resolve auto-creates a dedicated `Backdrops` track under `Video 1`.

Evidence: `DaVinci_Resolve_Immersive_Workflow_Guide.txt`, around lines `381-390`.

Backdrop files are `.usdz` assets and have a hard alignment rule:

- they can span one clip, multiple clips, or the whole timeline
- they cannot cut through the middle of an immersive `.braw` clip

Evidence: same guide, lines `390-407`.

This matters because it implies the timeline is aware that each immersive clip has its own lens/projection space. Resolve will not let a single backdrop straddle incompatible lens spaces.

## Viewer modes are not cosmetic; they are workflow modes

Resolve offers at least three viewer representations:

- native circular lens-space view
- `LatLong`
- `Viewport`

Evidence: guide lines `413-424`.

The guide explicitly says `LatLong` makes tracking and compositing easier, while `Viewport` shows a centered, correctly-proportioned cutout for standard monitors.

That suggests Resolve internally supports multiple projection/render views over the same underlying immersive clip. This is consistent with the `ImmersiveVideoToolbox` class set:

- `PreviewProjectionSpace`
- `IVTPreviewRenderer`
- `STMapGenerator`
- `STMapImageWarper`
- `MetalRenderer`

The framework names imply projection conversion is handled by dedicated rendering utilities, not by ad hoc viewer math inside the app.

## Titles depend on ILPD and clip boundaries

Resolve's title behavior is very specific:

- titles placed over immersive clips distort according to that clip's ILPD
- if no ILPD is available, default lens distortion is used
- titles should not cross immersive clip boundaries

Evidence: `DaVinci_Resolve_Immersive_Workflow_Guide.txt`, around lines `449-490`.

The reason is straightforward: each shot may have a different lens space. Crossing a cut risks re-warping title geometry incorrectly.

For FCP, that implies immersive titles are not just standard titles rendered on top. They need access to the active clip's lens model and need boundary validation.

## Transitions are treated as headset-aware events, not standard baked dissolves

The guide's transition model is unusual and important:

- users should prefer direct cuts, fade handles, or `Dip To Color Dissolve`
- transitions "should not be baked into the footage"
- Apple Vision Pro renders the transition during playback
- if you do use a transition, `Render Bypass` should be enabled so the headset handles it correctly

Evidence: `DaVinci_Resolve_Immersive_Workflow_Guide.txt`, around lines `433-446`.

Then on delivery, Resolve exposes explicit transition-bypass behavior:

- immersive timeline transitions may be pre-rendered into a single playback track
- generated XML describes switching between footage, pre-rendered transition stream, and footage again
- render settings expose `Always`, `With transition settings`, or `Off` behavior for visionOS transitions

Evidence: guide page 33, lines `803-819`.

This looks like a hybrid model:

- editorial timeline stores transition intent
- delivery decides whether to preserve it as a visionOS transition or flatten it
- the interchange metadata can describe stream switching rather than only pixel baking

That is a major clue for FCP support. If FCP wants parity, immersive transitions should probably be represented semantically, not only as flattened render results.

## Fusion is explicitly immersive-aware

The guide describes immersive-specific Fusion behavior:

- two `MediaIn` nodes feeding corresponding `MediaOut` nodes
- `Stereo Eye` routing in `MediaOut`
- `Auto` mode to merge left/right outputs appropriately
- immersive workflows for `Renderer3D`
- a paired `Immersive Patcher` workflow for undistort -> work flat -> redistort

Evidence: guide lines `520-575`.

The 20.1 and 20.2 feature guides add:

- Immersive option in Fusion's 2D viewer `360 View`
- `Immersive Patcher`
- `PanoMap` immersive option
- immersive world-pose rotations and flips
- stereoscopic node-stack support

Evidence:

- `DaVinci_Resolve_20.1_New_Features_Guide.txt`, around lines `428-461`
- `DaVinci_Resolve_20.2_New_Features_Guide.txt`, around lines `93-115`

The reverse-engineered framework strongly supports this reading. `ImmersiveVideoToolbox` contains:

- `FinalCutXMLParser`
- `IVTDynamicMetadata`
- `AIVSetCameraCommand`
- `AIVShotFlopCommand`
- `IVTDynamicMetadataPlayer`

That combination makes it plausible that Fusion and delivery are generating timed immersive commands, not only image transforms.

## The decompiled XML and metadata path is a major clue

Two decompiled entry points are especially important:

- [`IVTDynamicMetadata initWithFcpXml:error:`](../../analysis/resolve_immersive_braw/ImmersiveVideoToolbox-full/-[_TtC21ImmersiveVideoToolbox18IVTDynamicMetadata%20initWithFcpXml_error_].c)
- [`FinalCutXMLParser.init(url:)`](../../analysis/resolve_immersive_braw/ImmersiveVideoToolbox-full/_$s21ImmersiveVideoToolbox17FinalCutXMLParserC3urlAC10Foundation3URLV_tKcfc.c)

The parser constructor:

- initializes a dynamic-metadata object
- inspects the path extension for `.fcpxml` / `.fcpxmld`
- stores a `rootUrl`

That strongly suggests Resolve has an FCPXML-based interchange path for immersive dynamic metadata, even if the product UI centers on Resolve workflows. For SpliceKit, this is relevant because:

- FCPXML is already native territory for us
- Resolve's immersive tooling appears willing to consume or emit metadata described in XML form

## Delivery paths are productized

Resolve exposes several immersive output modes:

- `Vision Pro Review`
- `Vision Pro Bundle`
- `ASAF`
- `VR180`

Evidence: guide page 33, lines `803-811`.

The 20.2 feature guide also says immersive-camera EXR renders now keep:

- both-eye image data
- lens metadata
- re-importability into immersive projects

Evidence: `DaVinci_Resolve_20.2_New_Features_Guide.txt`, around lines `111-114`.

This is a strong hint that Resolve does not treat immersive VFX turnovers as destructive flattening. It preserves enough optical metadata for the media to come back into the immersive pipeline.

## What this implies for FCP

FCP parity would likely need:

1. A dedicated immersive timeline mode.
2. Viewer projection modes:
   - native lens
   - lat-long
   - viewport
3. Immersive-safe title generation with per-shot lens distortion.
4. Dedicated backdrop semantics.
5. Transition metadata that can be preserved or flattened at export.
6. A compositing story that supports undistort / work / redistort, even if the first implementation is modest.

DaVinci is not merely decoding immersive media. It has built editing policy around the projection model.
