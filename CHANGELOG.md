# Changelog

All notable user-facing changes to SpliceKit. Each release's full DMG,
notarization ticket, and Sparkle signature live on the
[GitHub Releases page](https://github.com/elliotttate/SpliceKit/releases).
Sparkle users are notified automatically; manual download is available from the
same page or via `appcast.xml`.

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
