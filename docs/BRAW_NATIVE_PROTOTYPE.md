# BRAW Native Prototype

This repo now contains the first safe slice of native Blackmagic RAW support work for SpliceKit.

## What Exists

`braw.probe`

- Runs inside the injected SpliceKit dylib.
- Resolves `.braw` paths from an explicit file path, a stored clip handle, or the current timeline selection.
- Dynamically loads the installed Blackmagic RAW SDK or Player framework at runtime.
- Opens the clip with the Blackmagic SDK, reports core clip metadata, samples clip metadata keys, inspects audio, and can optionally read and decode one frame for validation.
- Does not import, transcode, or mutate FCP state.

Current probe flags:

- `includeMetadata`
- `includeProcessing`
- `includeAudio`
- `decodeFrameIndex`

Bundle scaffolding under `Plugins/BRAW/`

- `FormatReaders/SpliceKitBRAWImport.bundle/Contents/Info.plist`
- `Codecs/SpliceKitBRAWDecoder.bundle/Contents/Info.plist`

These mirror the broad shape of FCP's native RED/Canon integration, but they are not functional reader/decoder implementations yet.

## Build and Staging

Stage the prototype bundles locally:

```bash
make braw-prototype
```

This creates:

```text
build/braw-prototype/FormatReaders/SpliceKitBRAWImport.bundle
build/braw-prototype/Codecs/SpliceKitBRAWDecoder.bundle
```

Opt-in copy of the scaffold bundles into the modded FCP app:

```bash
ENABLE_BRAW_PROTOTYPE=1 make deploy
```

This is disabled by default because the private MediaToolbox/VideoToolbox factory implementation is not wired yet. The current staged bundles are packaging skeletons only.

## Why This Is Safe

- The probe command validates the Blackmagic SDK path we actually need for native support.
- Default `make deploy` does not place fake reader/decoder binaries into FCP.
- The staged bundle plists let us iterate on identifiers and packaging without pretending the private ABI layer is finished.

## Live Validation

Validated inside the injected FCP process against:

- `/Users/briantate/Downloads/A004_07112105_C037 2.braw`

Known-good probe coverage in FCP:

- Clip open and basic dimensions/frame count/frame rate
- Metadata iteration and timecode/camera info sampling
- Audio stream inspection
- Clip processing attribute inspection
- Single-frame CPU decode at half resolution via `decodeFrameIndex=0`

The current probe is a validation/inspection command only. It does not register `.braw` as an importable format in FCP yet.

## Next Steps

1. Implement the private `MTPluginFormatReader` derived object and track/sample cursor objects for `.braw`.
2. Implement the private `VTVideoDecoder` derived object backed by the Blackmagic SDK decode path.
3. Route BRAW sidecar and RAW setting controls through SpliceKit commands after reader/decoder load works.
4. Only then should the prototype bundles become real deploy-time components by default.
