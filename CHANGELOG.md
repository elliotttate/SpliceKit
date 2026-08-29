# Changelog

All notable user-facing changes to SpliceKit. Each release's full DMG,
notarization ticket, and Sparkle signature live on the
[GitHub Releases page](https://github.com/elliotttate/SpliceKit/releases).
Sparkle users are notified automatically; manual download is available from the
same page or via `appcast.xml`.

## [3.3.9] — 2026-08-29

### Added
- **LiveCam now shows a live dBFS audio monitor directly below the microphone
  selector.** The larger color-coded meter includes a numerical peak readout,
  peak-hold marker, headroom scale, and a held clipping warning.
- **Optional Logitech MX Master 4 haptic feedback is now supported through the
  included Logi Options+ plugin source.** SpliceKit emits typed events for FCP's
  native haptics as well as clip and playhead snapping, with editable waveform
  mappings for the mouse.

### Changed
- **LiveCam's green-screen pipeline now remains bounded during long sessions.**
  Mask history uses materialized pooled buffers, adaptive inference timing, and
  the selected capture resolution instead of accumulating lazy image graphs or
  silently falling back to a larger camera format.
- **Smooth Scroll now animates FCP's native playhead at display refresh.** It
  reuses one display link, hands the first frame off cleanly, and safely restores
  FCP's scrolling behavior after interactions or when the feature is disabled.

### Fixed
- **LiveCam recordings no longer force mono USB microphones through a fixed
  stereo writer format.** Audio encoding now follows AVFoundation's
  session-aware recommendation, preserves the microphone's native capture
  format, and runs callbacks on an audio-priority queue. This removes the
  Shure MVX2U's unnecessary real-time mono-to-stereo conversion and protects
  capture from 4K video pressure. LiveCam status and logs now also report the
  source sample rate, channel count, and any source-timestamp discontinuities
  separately from writer back-pressure drops.
- **The LiveCam audio monitor now decodes each Core Media buffer using its live
  channel layout and buffer count.** This fixes the meter appearing correctly
  but remaining frozen with microphones that supply a variable-sized
  `AudioBufferList`.
- **Smooth Scroll now handles duplicate playback notifications and FCP 12.3's
  anchored timeline state correctly.** Native scrolling is reliably restored
  when playback ends, a user interacts with the timeline, or the timeline is
  torn down.

## [3.3.2] — 2026-04-21

### Changed
- **SpliceKit is now authoritative for BRAW playback even when third-party
  Media Extensions are installed.** Apple prioritises Media Extension
  video decoders (e.g. BRAW Toolbox's Decoder.appex) over legacy
  in-process VT registrations. SpliceKit now overrides four
  `FFMediaExtensionManager` predicates so FCP's Media Extension routing
  consistently sees the in-process VT decoder as authoritative for the
  six BRAW FourCCs (`braw`, `brxq`, `brst`, `brvn`, `brs2`, `brxh`):
  - `copyDecoderInfo:` returns nil — Media Extension lookup misses,
    decoder selection falls through to `VTRegisterVideoDecoder`'s
    in-process registry where `SpliceKitBRAW_registerInProcessDecoder`
    has bound all six variants to `SpliceKitBRAWInProcess_CreateInstance`.
  - `copyProcessorInfo:` returns nil — same routing intent for the RAW
    processor side (SpliceKit handles BRAW RAW adjustments in-process
    via the `FFSourceVideoFig.setRAWAdjustmentInfo:` hook in
    `SpliceKitBRAWRAW.mm`; we don't want a third-party RAW processor
    inserted into the pipeline).
  - `isAppExclusiveDecoder:` returns YES — signals "the in-app decoder
    is exclusive for this codec, skip Media Extension lookup".
  - `isDecoderUsingMediaExtension:` returns NO — callers that gate on
    this predicate (cache invalidation, Inspector display,
    asset-rep-provider selection) believe FCP is using the in-process
    path even when a third-party Media Extension is registered for the
    codec.

  Other codecs are still routed to whichever Media Extension claims
  them (Sony Raw via nablet, AVI/MKV via QLVideo, etc.). The first
  redirect for each FourCC logs one line so it's visible at startup;
  subsequent calls are silent.

  Known limitation: this only changes decoder/processor selection.
  Format reader selection (the .braw container parser) lives below FCP
  in `mediaextensiond` and is not yet redirected — Apple resolves
  format readers by UTI lookup before the asset reaches `FFAsset`, so
  if BRAW Toolbox's `FormatReader.appex` is installed it can still win
  that lookup. Disabling its format reader requires either OS-level
  `pluginkit -e ignore` (heavy-handed; affects all apps) or shipping
  SpliceKit's own format reader as a competing Media Extension; both
  are tracked separately.

### Fixed
- **Crash in FCP's thumbnail manager when an installed Media Extension
  returns nil for a VTExtensionProperties key.** FCP's thumbnail dispatch
  thread calls `-[FFMediaExtensionManager copyDecoderInfo:]`, which calls
  Apple's `VTCopyVideoDecoderExtensionProperties`. That function builds a
  CFDictionary of six required keys (extension identifier, name, URL, host
  bundle name, host bundle URL, codec name) by querying the matched
  Media Extension. If any value resolves to nil — for example, an
  extension whose `CodecInfo` array does not declare an entry for the
  FourCC the format description carries — VT calls
  `__setObject:forKey:` with nil and `__NSDictionaryM` raises
  `NSInvalidArgumentException`. The exception unwinds to FCP's uncaught
  handler and abort()s the process. SpliceKit now wraps non-BRAW codec
  lookups in a `@try`/`@catch` that swallows that one specific exception
  (matched on `__setObject:forKey:` + `object cannot be nil` reason text)
  and returns nil, mirroring the `kVTCouldNotFindExtensionErr` path that
  FCP already handles cleanly. Any other exception is re-raised so we
  don't hide unrelated bugs. (BRAW codecs avoid the original method
  entirely under the routing change above, so they can't reach the
  crash.) First catch logs in full; subsequent catches throttle to one
  log line per minute with a running count.
- **LiveCam camera/microphone access is restored.** Re-signing Final Cut
  Pro with `--entitlements` replaces Apple's full entitlement set on the
  bundle, which stripped `com.apple.security.device.camera`,
  `com.apple.security.device.microphone`, and
  `com.apple.security.device.audio-input` so LiveCam's "Allow Camera"
  button did nothing and TCC silently denied every request. The patcher
  now injects the three device entitlements into every codesign invocation
  (BRAW plugin bundles, framework, app bundle) and signs with
  `--options runtime` so the hardened runtime is engaged. The modded
  app's `Info.plist` also gains `NSCameraUsageDescription` and
  `NSMicrophoneUsageDescription` so TCC has a consent string to show.
- **Final Cut Pro is now launched via `NSWorkspace.openApplication`
  instead of `Process()`.** macOS TCC tracks a "responsible process" for
  privacy decisions; spawning FCP through fork+exec from the patcher made
  the patcher the responsible process for all of FCP's subsequent
  camera/mic requests, so tccd checked the patcher's entitlements and
  declined. Routing through LaunchServices makes FCP its own top-level
  process and lets TCC evaluate FCP's own entitlements.
- **Patcher install + update now strip extended attributes immediately
  before each `codesign` invocation.** The initial post-copy sweep can be
  invalidated by the steps in between it and signing (insert_dylib
  rewriting the Mach-O, PlistBuddy edits to `Info.plist`, BRAW bundle
  copies from quarantined sources), which re-attach
  `com.apple.FinderInfo` or resource forks and trigger codesign's
  "resource fork, Finder information, or similar detritus not allowed"
  rejection. The extra strip runs as the first step of the sign shell
  pipeline in both the fresh-install and update paths, on both the
  Developer ID and ad-hoc fallback attempts.
- **"Launch FCP" now surfaces a clear error when the modded bundle is
  missing.** `canLaunchFCP` only inspects patcher state (not patching,
  not already launching, not running); it does not verify the bundle is
  still on disk. If the user deleted the modded app or the patch never
  completed, `NSWorkspace.openApplication` surfaced this as a raw
  `NSCocoaErrorDomain Code 4` Sentry event with no actionable guidance.
  A `FileManager.fileExists` pre-flight at the top of `launch()` now
  catches this case and writes a clear "run the patch again" message to
  the patcher log instead.
- **Build fails fast on undefined `SpliceKit_` symbols.** The dylib was
  built with `-undefined dynamic_lookup`, so missing implementation files
  were never caught at link time — they only surfaced in production as
  `PC=0x0` crashes inside `safeInstall` blocks at launch. The build
  system now scans `nm -u build/SpliceKit` for any unresolved
  `_SpliceKit_*` symbol and fails the build if one is present. Three
  latent crash sites that would have triggered this were fixed in the
  same pass.

## [3.2.10] — 2026-04-20

### Fixed
- **Crash on first install of the overview bar.** Two call sites were
  hitting the FFAnchoredCollectionImageCreation renderer synchronously
  before the child panel had finished attaching and the active sequence
  had finished becoming current, so the renderer occasionally landed on
  a half-built graph and crashed. Both paths now go through a single
  `scheduleInitialRerender` helper that defers the invalidate + rerender
  via `performSelector:afterDelay:`, so the first paint always lands
  after the run-loop turn where the collection is actually renderable.
- **Smooth Scroll now respects the Continuous Scrolling preference.** The
  gate that decided whether to engage the 120 Hz centered-scroll takeover
  was reading `keepsPlayheadCenteredDuringPlayback` on TLKScrollingTimeline
  — which reads correct by name but is actually a rate-derived computed
  value set only during fast-forward / rewind (and always off at the
  default playback rate of 1.0). Swapped the gate over to the real
  user-facing `scrollDuringPlayback` flag on TLKTimelineView
  (backed by the `FFScrollDuringPlaybackKey` NSUserDefaults key and
  pushed into the view from
  `-[FFAnchoredTimelineModule updateTimelineScrollDuringPlaybackToMatchUserDefaults]`).
  Now:
  - Continuous Scrolling ON → Apple's step-based centering is paused
    and our display-link-driven scroll is authoritative, so the
    timeline content slides continuously under a stationary playhead.
  - Continuous Scrolling OFF → we leave Apple's native edge-tracking
    alone and just draw the smooth 120 Hz playhead line on top, so the
    playhead slides smoothly across the viewport until it reaches the
    side threshold and FCP's autoscroller takes over.

## [3.2.09] — 2026-04-20

### Added
- **Smooth Scroll** — a new master toggle in the Splices menu (on by
  default) that replaces Final Cut's 24/30 Hz playback-centering step
  scroll with a proper 120 Hz display-link-driven path. The clip view
  follows the playhead continuously instead of hopping sideways once per
  source frame; on a ProMotion display the timeline content now actually
  slides smoothly under a stationary playhead line during centered
  playback. Toggle from *Splices → Smooth Scroll*, or via the
  `timelinePerformanceMode` bridge option. Three sub-features are
  individually exposed as bridge options for A/B:
  - `timelinePlayheadOverlay` — draws a cosmetic playhead line at the
    display refresh rate by extrapolating
    `-[TLKTimelineView _setPlayheadTime_NoKVO:animate:]` samples forward
    via `-[TLKTimelineView locationRangeForTime:]`, and pauses
    `TLKScrollingTimeline` during playback so Apple's step-scroll doesn't
    fight our smooth path. Clip view bounds are updated directly via
    `setBoundsOrigin:` + `reflectScrolledClipView:` on every tick, with a
    safety gate that falls back to overlay-only if the clip-view or
    time-to-x mapping can't be resolved. Apple's real playhead layer is
    hidden during playback so only one line is visible.
  - `timelineInteractionSuspend` — observes
    `TLKEventHandlerDid{Start,Stop}TrackingNotification` (marquee-zoom,
    scroll-bar drag, range drag) and swizzles
    `-[TLKTimelineHandler magnifyWithEvent:]` to cover pinch (which runs
    its own inline event loop and never posts tracking notifications).
    While an interaction is active, `setDisableFilmstripLayerUpdates:YES`
    + `setSuspendLayerUpdatesForAnchoredClips:YES` +
    `setMinThumbnailCount:0` are applied so the per-cell
    `FFFilmstripCell` rebuild (which otherwise fails
    `isEquivalentToFilmstripCell:` on every zoom step because
    `timeRange`, `frame.size`, and `audioHeight` all change) goes away;
    one coalesced `_reloadVisibleLayers` runs on tracking end. Prior
    state is saved per-view via an ObjC-boxed associated object (ARC
    frees it when the view deallocs).
  - `tlkOptimizedReload` — swizzles
    `+[TLKUserDefaults optimizedReload]` so the hidden
    `TLKOptimizedReload` flag actually takes effect. Apple's
    `_loadUserDefaults` in current FCP reads `TLKItemLayerContentsOperations`
    and `TLKEnableUpdateFilmstripsForItemComponentFragments` from plist
    but never wires the `optimizedReload` bit to any NSUserDefaults key;
    we override the getter so the optimized ripple-adjustment skip in
    `-[TLKLayoutManager _performHorizontalLayoutForItemsAdded:...]` is
    reachable.

### Fixed
- **MCP bridge no longer gets poisoned by event frames.** The server's
  default for event delivery flipped to opt-in — clients must call
  `events.subscribe` to receive `method:"event"` frames. Previously a
  single-socket JSON-RPC client (like the MCP bridge) could have the
  next tool call consume an unsolicited event as its response and
  permanently desync the socket. The Python bridge client also now
  skips any frame that lacks a matching `id` or that carries a `method`
  field, so stray notifications can't be consumed as responses.
- **Async `command.completed` reports `status:"error"` for normal RPC
  failures**, not only for ObjC exceptions. Clients no longer have to
  peek inside the nested `result` payload to tell whether the command
  succeeded.
- **Per-client socket writes are now atomic AND ordered.** Every
  connected fd has a dedicated serial `dispatch_queue_t`; both RPC
  replies and event broadcasts route through it so bytes can't
  interleave mid-line and events B/C can't overtake event A on the same
  socket. Replaces the earlier mix of `fwrite`/`fflush` on the RPC path
  with raw `write()` on the async path.
- **Timeline overview bar now tears down its notification observers on
  uninstall.** Block-based `addObserverForName:...usingBlock:` returns
  opaque tokens that the previous `removeObserver:bar` call couldn't
  reach; toggling the feature off then back on stacked duplicate
  observers and left hidden rerenders scheduled. Tokens are now
  captured in a single array and released explicitly.
- **`TLKOptimizedReload` toggle no longer sticks permanently off** when
  the first call happens to disable it (the previous `dispatch_once`
  plus early-return ate the one-shot token).

## [3.2.07] — 2026-04-19

### Fixed
- **HEVC MP4s tagged `hev1` now import into Final Cut.** Apple's
  AVFoundation / QuickTime / Final Cut decoder only accepts HEVC when the
  MP4 sample-entry is `hvc1` (parameter sets in extradata); files muxed
  with `hev1` — including most Dolby Vision iTunes rips — played in VLC
  but showed up as unimportable in FCP. The hook extension filter now
  covers `.mp4`/`.m4v`/`.mov` alongside the Matroska family, detects the
  `hev1` tag via AVURLAsset's codec FourCC, and retags the file for
  Final Cut.
- **Zero-duplication fast path for large HEVC retags.** A full
  stream-copy remux of a 19 GB DV rip would have to write out another
  19 GB (and needs the headroom to do it). Instead we use APFS
  `clonefile()` to make an instant COW snapshot, `mmap` the tail 64 MB
  of the clone (where the moov box sits on non-faststart MP4s), find
  the `hev1` sample-entry by its box-size prefix, and overwrite 2 bytes
  in place (`e`→`v`, `v`→`c`). Total extra disk: a single modified
  block (~KB). Total runtime: a few seconds. The original file on disk
  is untouched — only the clone is modified.

## [3.2.06] — 2026-04-19

### Fixed
- **MKV shadow-remux now handles h264, hevc, av1, prores** (and mpeg4 /
  mpeg2video) — the previous pass only covered VP9/VP8, so typical WEB-DL
  releases (h264 + E-AC3 + subrip) failed to import. Audio is handled
  independently: aac/mp3/ac3/eac3/alac/pcm stream-copy, everything else
  transcodes to AAC 192k stereo so the shadow MP4 is guaranteed playable.
- **HEVC Main-10 10-bit MKVs are now decoded in FCP.** Apple's
  AVFoundation/FCP only accepts HEVC with the `hvc1` sample-entry tag;
  ffmpeg defaults to `hev1` from Matroska input, which plays in VLC but
  refuses to open in Final Cut. We force `-tag:v hvc1` on HEVC sources.
- **Subtitle / attachment streams no longer break the remux.** Explicit
  `-map 0:v:0 -map 0:a:0?` replaces `-map 0`, so subrip subtitles (two per
  episode on most WEB releases) and font attachments are dropped instead
  of failing the MP4 mux.
- **B-frame display order survives the CFR timestamp rewrite.** New
  `setts` expression rewrites DTS to a clean `N·frameTicks` grid while
  preserving each packet's source PTS–DTS offset (snapped to whole
  frame-durations). VP9/VP8 behaviour is unchanged (offset term collapses
  to 0); h264/hevc/av1 now keep their B-frame reordering instead of all
  frames collapsing to `pts==dts`.
- **Media Import "Processing files for import…" no longer stalls.** The
  hook short-circuits for any non-`.mkv`/`.webm`/`.mka`/`.mk3d`
  extension (previously it ran ffprobe on every file in the tree — a
  `~/Movies/` with Motion Templates and JDownloader sub-folders meant
  thousands of pointless probes) and uses a deterministic
  `basename.<hash>.mp4` shadow path so re-entering the hook for the same
  source (3–5× per Media Import row) hits the existing shadow instead of
  respawning ffmpeg.

### Changed
- **Menu renamed from "Enhancements" to "Splices"** in Final Cut's menu
  bar. The Debug menu-bar dropdown is no longer installed — the Debug
  prefs pane still rebuilds, just doesn't clutter the menu bar.

## [3.2.05] — 2026-04-18

### Added
- **MKV / WebM imports.** Drop .mkv or .webm files onto Final Cut and SpliceKit
  generates a shadow MP4 remux on the fly. FCP sees a native container; the
  original file stays untouched on disk.
- **Highest Quality toggle for URL imports.** New checkbox in the
  "Import URL to Library" / "Import URL to Timeline" dialog (and a
  `highest_quality` parameter on the MCP `import_url` tool) fetches the highest
  available resolution from YouTube / Vimeo — 1080p, 1440p, or 4K via VP9 / AV1
  — instead of YouTube's 720p progressive-mp4 cap. Leave it off for the fast
  720p path.
- **Share Logs** button in the Patcher status panel — one-click upload of the
  latest Final Cut Pro crash log plus SpliceKit logs to filebin.net, with the
  link copied to the clipboard.

### Fixed
- **URL import FCPXML parse failure** when the downloaded filename contained
  ampersands or other XML-reserved characters (e.g. a YouTube title containing
  "PS5 & PS5 Pro"). `NSURL.absoluteString` leaves `&` literal in file URLs; we
  now XML-escape the `src=` URL before it lands in the generated FCPXML, so
  `FFXMLTranslationTask` accepts it.
- **URL import progress HUD.** Finer-grained updates (~5× more frequent), the
  live percent is embedded in the status text, and the duplicate
  "Downloading YouTube media… 100.0% 72%" readout is gone. Spinner now stays
  vertically centered against the label whether it wraps to one line or two.
- **LiveCam** mask kernel dispatch and shader-coordinate fix resolves
  subject-lift / green-screen edge artifacts on some machines.
- **BRAW** settings inspector locks to a dark appearance to match FCP's other
  inspectors.

### Developer / Setup
- `.mcp.json` now points at the `mcp-setup` venv interpreter, so Claude Desktop
  MCP works without hand-editing Python paths.
- MCP `import_url` tool gained `highest_quality: bool = False` for programmatic
  access to the new quality toggle.

---

## Older releases

For full notes on prior releases, see the
[GitHub Releases page](https://github.com/elliotttate/SpliceKit/releases).
Highlights:

- **v3.2.04** — LiveCam: native webcam booth with subject-lift green screen and
  ProRes 4444 alpha capture.
- **v3.2.03** — URL import workflow for direct media and YouTube VOD URLs
  (Command Palette, Lua, MCP).
- **v3.2.02** — Fixed jerky Effects-browser sidebar scroll on installs with
  many effects.
- **v3.2.01** — Native Blackmagic BRAW color grading (Gamma, Gamut, ISO,
  tone curve, LUT, etc.) with in-process decoder.
- **v3.1.151** — Ship BRAW plugin bundles in the patcher so BRAW works on
  fresh installs.
- **v3.1.150** — Serialize BRAW ReleaseClip through the work queue to fix a
  tear-down crash.
- **v3.1.149** — Native Blackmagic RAW playback in FCP via the BRAW SDK.
