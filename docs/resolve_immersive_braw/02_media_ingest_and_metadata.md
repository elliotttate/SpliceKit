# Media Ingest And Metadata

## The official Resolve workflow starts with project mode, not with import

The workflow guide is explicit that immersive work starts at project setup, not at clip decode:

- `Enable Apple Immersive workflow`
- set timeline resolution to `8160 x 7200 Immersive` or `4080 x 3600 Immersive`
- default timeline and playback frame rate of `90 fps`

Evidence: `analysis/resolve_immersive_braw/source_pdfs/DaVinci_Resolve_Immersive_Workflow_Guide.txt`, around lines `185-210`.

That is a strong hint that immersive media is a first-class timeline mode with downstream effects on viewers, Fusion, delivery, and monitoring. FCP will likely need a dedicated immersive project mode too.

## Ingest keeps both eyes and the immersive metadata together

The workflow guide states:

- "When ingesting raw immersive content, both eyes and all associated immersive metadata travel with the imported `.braw` clip."

Evidence: `DaVinci_Resolve_Immersive_Workflow_Guide.txt`, around lines `332-346`.

This is the single most important product-level behavior to match. Resolve is telling users that immersive `.braw` is one logical asset that carries:

- both eyes
- lens calibration / projection metadata
- associated immersive metadata

The import path is not "make two eyes and try to relink metadata later."

## What the BRAW runtime appears to preserve

`BlackmagicRawAPI` embeds interface names that strongly imply a structured immersive clip model:

- `IBlackmagicRawClipImmersiveVideo`
- `IBlackmagicRawClipMultiVideo`
- `IBlackmagicRawFrameMultiVideo`
- `IBlackmagicRawClipGeometry`
- `IBlackmagicRawClipGyroscopeMotion`
- `IBlackmagicRawClipOrientationMotion`

That points to at least five data domains in the clip:

| Domain | Evidence |
| --- | --- |
| Left/right image views | `IBlackmagicRawClipMultiVideo`, `IBlackmagicRawFrameMultiVideo` |
| Immersive clip identity | `IBlackmagicRawClipImmersiveVideo` |
| Lens and rig geometry | `BlackmagicRawClipGeometry`, `IBlackmagicRawClipGeometry` |
| Motion sensor data | `IBlackmagicRawClipGyroscopeMotion`, `IBlackmagicRawClipOrientationMotion` |
| Per-frame immersive metadata samples | error strings and metadata-key parsing in decompiled code |

## The Apple/ProIM metadata keys are embedded in the BRAW path

The decompiled function [`sub_11E260.c`](../../analysis/resolve_immersive_braw/BlackmagicRawAPI-full/sub_11E260.c) constructs a metadata-key table containing:

- `com.blackmagicdesign.motiondata.gyroscope`
- `com.blackmagicdesign.motiondata.accelerometer`
- `com.blackmagicdesign.pdafdata`
- `com.apple.quicktime.proim.optical.lens.ilpdUUID`
- `com.apple.quicktime.proim.optical.lens.ilpdFileName`
- `com.apple.quicktime.proim.optical.lens.interaxial`
- `com.apple.quicktime.proim.optical.lens.projectionKind`
- `com.apple.quicktime.proim.optical.lens.calibrationType`
- `com.apple.quicktime.proim.optical.lens.projectionData`

This is one of the most useful reverse-engineering findings in the whole effort. It means the BRAW-side runtime is not only aware of generic stereo data. It is aware of Apple / ProIM lens metadata specifically.

## Per-frame immersive metadata is stored in a timed track

The decompiled function [`sub_11BFF0.c`](../../analysis/resolve_immersive_braw/BlackmagicRawAPI-full/sub_11BFF0.c) is especially revealing. It throws errors such as:

- `the clip doesn't contain an immersive data frame track`
- `the immersive data frame sample size was invalid`
- `failed to read the immersive data frame sample data`
- `failed to read the correct amount of immersive data frame sample data`

This strongly suggests:

1. Resolve expects immersive per-frame data in a dedicated sample track.
2. It validates sample size and reads sample payloads frame-by-frame.
3. It parses those payloads into typed fields, not opaque blobs.

There are also parser-side strings in the same binary for:

- `Timed Metadata Media Handler`
- `Invalid video stereo view box, Required atoms missing`
- `Invalid projection box, Required atoms missing`
- `This is not an immersive video file.`

Taken together, the clip parser appears to validate:

- stereo-view box structure
- projection metadata box structure
- timed metadata media handlers
- presence and integrity of immersive frame-sample payloads

## Resolve appears to couple motion analysis to ingestable metadata, not derived optical flow

The workflow guide exposes "Apple Immersive Motion Data" as an editor-facing graph of acceleration and gyroscope values, used to spot viewer-disorienting motion.

Evidence: `DaVinci_Resolve_Immersive_Workflow_Guide.txt`, around lines `449-466`.

This lines up with the raw API metadata keys and interface names. The motion graph is likely built from sensor-backed metadata already present in the BRAW clip, not inferred afterward from image analysis.

That has consequences for FCP:

- motion metadata should survive import intact
- it should remain accessible at clip and frame scope
- UX can expose it later, but the import model has to keep it first

## ILPD is a core concept, not a sidecar afterthought

The workflow guide mentions Apple Immersive Calibration and ILPD selection during setup, and later states that titles use the clip's ILPD to distort text correctly.

Evidence:

- setup / calibration selection around lines `332-338`
- titles and ILPD behavior around lines `449-490`

This matches the BRAW key set:

- `ilpdUUID`
- `ilpdFileName`
- `projectionKind`
- `projectionData`
- `calibrationType`

Resolve appears to treat ILPD as part of the fundamental media model for immersive footage, not just as export-time metadata.

## What FCP support likely needs on the ingest side

To match DaVinci's behavior closely, FCP will probably need all of the following:

1. A clip type that owns both eye streams, not two loosely-associated clips.
2. Storage for clip-level optical metadata:
   - ILPD identity
   - projection kind
   - projection data
   - interaxial
   - calibration type
3. Storage for timed per-frame metadata samples.
4. Storage for motion sensor streams:
   - gyroscope
   - accelerometer
   - orientation
5. Geometry accessors that higher layers can use for preview and title distortion.

If SpliceKit can eventually read or surface those domains directly, FCP-side immersive support becomes much more feasible. If the import path discards them, every downstream feature gets harder or impossible.
