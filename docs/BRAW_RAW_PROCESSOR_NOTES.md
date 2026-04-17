# BRAW RAW Processor Notes

This is the current state of the MediaExtension-based BRAW RAW processor work.

## Current conclusions

- The fake `FFVTRAWProcessorSession` approach was a dead end and has now been removed from `Sources/SpliceKitBRAWRAW.mm`.
- A real RAW processor extension is required to give FCP a stable VT RAW session and controller object graph.
- A real RAW processor extension is not, by itself, enough to provide true BRAW-domain RAW controls with the current decoder path.
- The public MediaExtension contract expects a decoder that can produce RAW output for an `MERAWProcessor`, typically through a custom pixel format shared by the decoder and processor.
- The current BRAW decoder path decodes directly to `kCVPixelFormatType_32BGRA`, so it does not currently satisfy that model.

## What was added

- A new RAW processor extension scaffold under `MediaExtensions/BRAWRAWProcessor/`
- A `make braw-raw-processor` target that builds:
  - `build/braw-prototype/Extensions/SpliceKitBRAWRAWProcessor.appex`
- An opt-in deploy flag:
  - `ENABLE_BRAW_RAW_PROCESSOR=1 make deploy`

The current scaffold now does more than the original no-op:

- registers a RAW processor extension point
- advertises all known BRAW FourCCs:
  - `braw`, `brxq`, `brst`, `brvn`, `brs2`, `brxh`
- links against `BlackmagicRawAPI.framework` and embeds it in:
  - `Contents/Frameworks/BlackmagicRawAPI.framework`
- builds real `MERAWProcessingParameter` objects for:
  - `iso`, `kelvin`, `tint`, `exposure`, `saturation`, `contrast`, `highlights`, `shadows`
- probes clip-level BRAW SDK state during init to seed tone-curve ranges and a frame-0 read to seed ISO / WB / exposure defaults where possible
- logs input-frame attachments and parameter snapshots to `/tmp/splicekit-braw.log`
- allocates output pixel buffers matching the incoming frame and copies the input through when possible, falling back to black only if the copy cannot be performed

This is enough to validate the VT-side parameter surface and keep the extension from visibly destroying playback if it gets activated, without claiming that true BRAW-domain decode is finished.

## Entitlement and registration status

- Apple’s public header for `MERAWProcessor` explicitly requires the `com.apple.developer.mediaextension.videodecoder` entitlement and a provisioning profile.
- This machine now has provisioning-backed profiles staged in the target directory, and the built appex is Developer ID signed with:
  - `com.apple.application-identifier`
  - `com.apple.developer.team-identifier`
  - `com.apple.developer.mediaextension.videodecoder`
  - `com.apple.security.application-groups`
- The built appex verifies as:
  - `Identifier=com.splicekit.braw.rawprocessor`
  - `Authority=Developer ID Application: Brian Tate (RH4U5VJHM6)`
  - `@rpath/BlackmagicRawAPI.framework/Versions/A/BlackmagicRawAPI`
- `pluginkit -a build/braw-prototype/Extensions/SpliceKitBRAWRAWProcessor.appex` still did not yield a discoverable entry in `pluginkit -m` from the staged bundle path alone.

Working assumption: the remaining registration proof point must be checked from the deployed host-app path inside the modded `Final Cut Pro.app`.

## Live FCP validation

### Current working state

- The native FCP RAW HUD is live for BRAW and now drives the in-process BRAW decode path instead of being a no-op UI.
- `FFAsset.rawProcessorSettings` is mirrored into a host-side settings cache keyed by the resolved source path, not the `.fcpbundle/Original Media/...` symlink path.
- Updating RAW settings now invalidates any live BRAW host decode entry so the next frame request reopens the clip and applies the new settings.
- `FFVTRAWProcessorSession.setProcessingParameter:forKey:` is now hooked for real sessions, not just the dead fake-session path:
  - the current VT session snapshot is converted back into the persisted settings shape
  - the host-side BRAW cache is updated immediately
  - the owning `FFAsset` is written back with the merged settings
  - `FFAsset.invalidate` is called so the viewer repaints without needing a manual click back into the timeline
- On the normal viewer decode path, all 8 target controls now apply through the BRAW SDK:
  - `iso`
  - `kelvin`
  - `tint`
  - `exposure`
  - `saturation`
  - `contrast`
  - `highlights`
  - `shadows`
- ISO required special handling:
  - `GetFrameAttributeRange` is not usable for ISO on this SDK surface
  - `GetISOList` must be queried and the incoming slider value snapped to the nearest supported ISO before `SetFrameAttribute(ISO, ...)`
- Tone-curve controls required range clamping:
  - `contrast` and `shadows` were being rejected until the value was clamped against `GetClipAttributeRange(...)`
- Tone-curve controls also required a full custom-gamma bundle, not just the four user-facing clip attributes:
  - the SDK accepts `toneCurveContrast`, `toneCurveSaturation`, `toneCurveHighlights`, and `toneCurveShadows`, but leaving gamma on the camera/default curve still produced no visible output change
  - the working path is:
    - query `IBlackmagicRawToneCurve` from the live codec object
    - use the current camera type + current gamma + color-science gen to fetch the baseline tone-curve tuple
    - switch clip gamma to `Blackmagic Design Custom`
    - seed `midpoint`, `blackLevel`, `whiteLevel`, and `videoBlackLevel` from the queried defaults
    - then apply the user’s `saturation`, `contrast`, `highlights`, and `shadows` overrides on top
  - after that change, `capture_viewer` diffs from live FCP confirmed that:
    - `saturation` and `contrast` now visibly affect the image
    - `highlights` and `shadows` now visibly affect the image

### Diagnostics caveats

- `braw_probe(selected: true, decode_frame_index: 0)` is currently unsafe in this build and can drop the bridge / kill FCP. It is not a trustworthy validation path for RAW-settings work right now.
- `capture_viewer` is usable again for this path and is now helpful for proving session-write repaint behavior.
- The authoritative proof point is now log output like:
  - `[raw-settings-cache] store /Users/.../Boy-and-the-Watch.braw.braw`
  - `[raw-settings-apply] clip ...`
  - `[raw-settings-apply] frame ...`

The deployed host-app path is now the authoritative registration path.

- `pluginkit -m -A -D -v -i com.splicekit.braw.rawprocessor` resolves to:
  - `/Users/briantate/Applications/SpliceKit/Final Cut Pro.app/Contents/Extensions/SpliceKitBRAWRAWProcessor.appex`
- A stale build-path registration for the same identifier caused an earlier failure mode where:
  - `VTCopyRAWProcessorExtensionProperties` surfaced a nil `MediaExtensionContainingBundleName`
  - the native HUD path crashed before a controller could be built
- Removing the duplicate staged registration fixed that crash path.

Inside live Final Cut Pro, the remaining HUD blocker was not the extension registration itself but the legacy factory gate:

- `FFAsset newRawSettingsController` still returned `nil`
- `FFVTRAWHUDControllerFactory copyControllerForAnchoredObjects:` therefore returned `nil`
- `FFVTRAWSettingsHud` opened with `_controller == nil` and `_parameters == nil`

The direct cause was:

- `FFSourceVideoFig.codecIsRawExtension == NO` for BRAW sources
- `FFVTRAWProcessorSettingsControllerFactory controllerWithProvider:settings:asset:` only instantiates `FFVTRAWSettingsController` when that method returns `YES`

The current fix is narrower than the old global override:

- `Sources/SpliceKitBRAWRAW.mm` now swizzles `FFSourceVideoFig.codecIsRawExtension`
- it only returns `YES` when:
  - the source is BRAW, and
  - `VTCopyRAWProcessorExtensionProperties(videoFormatDescription, ...)` succeeds for that format

That keeps the old fake-session dead end out of the tree, while allowing the real MediaExtension-backed VT controller path to materialize.

### Verified in live FCP after the gate fix

- `FFAsset newRawSettingsController` returns a real `FFVTRAWSettingsController`
- its `_processingSession` is a real `FFVTRAWProcessorSession`
- `hasValidSession == YES`
- `extensionIdentifier == com.splicekit.braw.rawprocessor`
- `copyRAWParameters:` returns 8 `FFRAWProcessingParameterNumber` objects:
  - `iso`, `kelvin`, `tint`, `exposure`, `saturation`, `contrast`, `highlights`, `shadows`
- the native `FFVTRAWSettingsHud` now rebuilds as a populated `NSGridView` with 8 slider rows instead of an empty body
- direct calls to `FFVTRAWProcessorSession setProcessingParameter:forKey:` update the live session snapshot:
  - `copyVTRAWSettingsFromSession` reflects changed values such as `iso = 900`
- direct session writes now also repaint the current viewer frame once the BRAW asset is invalidated from the session hook
- `capture_viewer` comparisons now show real pixel changes after session-driven tone-curve updates, not just log-only confirmation

One caveat remains for programmatic verification:

- direct bridge calls to `RAWSliderHandler setDoubleValue:` no longer crash FCP, which is the important regression fix
- but the bridge’s primitive-double marshaling does not appear reliable enough to use that method as proof of value propagation by itself
- session-level writes on `FFVTRAWProcessorSession` do propagate correctly and are the more trustworthy validation surface for now

## Next steps

1. Add a repeatable non-UI validation tool for:
   - `VTCopyRAWProcessorExtensionProperties`
   - `VTRAWProcessingSessionCreate`
   - `copyVTRAWSettingsFromSession`
2. Replace the current BGRA passthrough processor implementation with real BRAW SDK-backed rendering inside the appex, or decide explicitly to keep rendering in-process and use the appex only as the native settings/UI surface.
3. Decide whether to:
   - redesign the decoder to produce RAW output for the processor, or
   - keep the extension as the UI/settings surface and add a side channel back to the in-process BRAW decode path.
