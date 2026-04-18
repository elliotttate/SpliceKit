# SpliceKit

[![Release](https://img.shields.io/github/v/release/elliotttate/SpliceKit)](https://github.com/elliotttate/SpliceKit/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-FCP%20Cafe-5865F2?logo=discord&logoColor=white)](https://discord.com/invite/HD3FPc4Azu)
[![Docs](https://img.shields.io/badge/docs-splicekit.fcp.cafe-0A84FF)](https://splicekit.fcp.cafe)

**Final Cut Pro, unlocked. A Command Palette, MCP server, and an open plugin framework to do almost anything.**

| 🎹 Command Palette | 🤖 MCP Server | 🧩 Plugin Framework |
|---|---|---|
| Hit `Cmd+Shift+P` and type what you want. Apple Intelligence runs it. | Any LLM can read and edit your timeline — and build new tools as it goes. | Every built-in feature is just an example plugin. You (or an AI) can ship more. |

---

## The Three Pillars

### 1. The Command Palette — one keystroke to anything

Hit **Cmd+Shift+P** inside the patched FCP. Fuzzy-search 100+ built-in editing actions (blade, trim, color, speed, markers, effects, transitions, export — all of them), or type plain English and let **Apple Intelligence** (on-device, private) figure out what you meant:

- *"add markers every 5 seconds"*
- *"slow this clip to half speed"*
- *"blade at every scene change"*
- *"remove all the silences"*
- *"add a cross dissolve"*

No more menu hunting. No more memorizing shortcuts. No cloud.

### 2. The MCP Server — Claude (or any other LLM) can drive your editor, and teach it new tricks

SpliceKit ships with an MCP server that exposes ~200 tools covering every major FCP subsystem. Point Claude Code, Claude Desktop, or any MCP-compatible AI client at it and you can say things like:

- *"cut this 40-minute interview down to its best moments"*
- *"remove the silences from this podcast, add captions, and export"*
- *"assemble a rough cut from these clips, synced to the beat of this song"*

It's not a chat wrapper around keyboard shortcuts — the MCP talks to FCP's internal ObjC runtime directly, so it can read timeline state, inspect clips, blade, retime, color-correct, apply effects, and render without ever touching the UI.

**And here's where it gets interesting: the MCP gets better the more you use it.**

The first time you ask for something complicated, Claude (or any other LLM) might be a little clumsy. It's improvising — stitching together the primitives it has, trial-and-error against your timeline, occasionally picking the long way around.

When that happens, tell Claude (or any other LLM) to *build the ability*. With full access to the SpliceKit framework, Claude (or any other LLM) can write a new plugin, register a new MCP tool, and wire it straight into your editor. What started as a ten-step improvisation becomes a single high-level command. Next time you ask for it — or the hundredth time after that — it's instant, reliable, and shared with everyone else who installs the same plugin.

Every clumsy first attempt is a prompt to turn that workflow into a first-class feature. The toolset compounds. The editor you use six months from now is smarter than the one you installed today — and most of that improvement won't have come from the SpliceKit team. It'll come from you, and from the community shipping plugins back.

### 3. The Plugin Framework — everything is a plugin

SpliceKit isn't a feature list. It's a platform. Once the SpliceKit dylib is loaded into Final Cut Pro, the entire ObjC runtime (78,000+ classes including all private APIs) is open for plugins to use.

Plugins can:

- Add new panels and windows inside FCP
- Add buttons to the toolbar, menu, or Enhancements menu
- Register commands in the Command Palette
- Expose new tools over the MCP server
- Hook into timeline events, selection changes, playback
- Ship custom Motion templates, FxPlug effects, and Workflow Extensions
- Be written in Objective-C/C++, Swift, Lua, or Python

And — maybe the most important part — **you can ask an AI to build one**. Describe what you want the plugin to do, hand the spec to Claude, and it can write it against the SpliceKit framework. The project ships with full API reference docs specifically designed for AI consumption.

---

## Example Plugins (What Ships in the Box)

Every one of these is a plugin. They're bundled so you can use SpliceKit the day you install it, and they double as working examples for anyone building their own.

### Text-Based Editor
Transcribe every clip on your timeline with on-device speech recognition (NVIDIA Parakeet — 25 languages, no cloud, with speaker diarization). Click a word to jump there. Select a sentence, hit Delete, and the video gets cut to match. Drag words to reorder clips. Export as SRT or plain text.

[![Text-Based Editor Demo](https://img.youtube.com/vi/JxxDSH4Ly0I/maxresdefault.jpg)](https://www.youtube.com/watch?v=JxxDSH4Ly0I)

### Silence Remover
Point it at an interview or podcast recording and it finds and cuts every silent pause. Configurable threshold, minimum duration, and padding. Pure Apple-native AVFoundation + Accelerate under the hood.

### Social Media Captions
Generate word-by-word highlighted, animated captions in 13 built-in styles (Bold Pop, Neon Glow, Karaoke, Typewriter, Bounce, and more). Captions land directly on your timeline as editable Motion titles.

### Scene Detection
Finds every shot change in your footage using vImage histogram comparison. Add markers, blade the timeline, or both.

### Beat Detection & Song Cut
Pulls BPM, beats, bars, and song sections from any music file. Hand **Song Cut** a music track and a folder of footage and get back a beat-synced music video on your timeline, with selectable pacing (natural, medium, fast, aggressive) or custom step weights.

### LiveCam
A built-in webcam booth that records straight to your library or active timeline. Live preview with color adjustments, audio meter, and a subject-lift green-screen matte that works on people *and* objects (macOS 14+). Pick "Transparent" as the green-screen color and LiveCam writes ProRes 4444 with a real alpha channel.

### URL Import
Paste a YouTube, Vimeo, or Twitter link and pull it into your library as a real clip. Auto-discovers `yt-dlp` and `ffmpeg` from your shell PATH.

### Batch Export
One command, every clip on your timeline exports as its own file — all effects, color grades, and transitions baked in.

### Dual Timelines, FlexMusic, Montage Maker, OpenTimelineIO exchange, Lua REPL, in-process debugger…
…and more. Every one of them is code in `Sources/` you can read, fork, or gut for parts.

---

## Install in 60 Seconds

The easiest path is the GUI patcher. Download the latest release, open it, click the button.

[![Installation Guide](https://img.youtube.com/vi/NxbInKlXQVs/maxresdefault.jpg)](https://www.youtube.com/watch?v=NxbInKlXQVs)

1. Download **SpliceKit** from the [latest release](https://github.com/elliotttate/SpliceKit/releases/latest)
2. Unzip and open the app
3. Click **Patch** — it handles the rest

<img src="docs/patcher-screenshot.jpg" width="500" alt="SpliceKit Patcher">

The patcher copies Final Cut Pro to `~/Applications/SpliceKit/`, injects the SpliceKit dylib, re-signs it, and sets up the MCP server. **Your original Final Cut Pro is never touched.**

Once done, click **Launch FCP** in the patcher, or open the new copy from `~/Applications/SpliceKit/`. Press **Cmd+Shift+P** to open the Command Palette and you're off.

Prefer the terminal? `./patcher/patch_fcp.sh` does the same job.

---

## Is This Safe? Is It Legal? Will Apple Ban Me?

Short answers: **Yes, it's safe. Yes, it's legal. No, Apple won't ban you.**

- **Your FCP stays untouched.** SpliceKit makes a *copy* in `~/Applications/SpliceKit/`. Your App Store FCP is never modified. Your libraries, projects, and media files are not touched by the install.
- **It's legal.** Reverse engineering for interoperability is explicitly protected under [DMCA §1201(f)](https://www.law.cornell.edu/uscode/text/17/1201) (US) and the EU Software Directive. SpliceKit is MIT licensed.
- **Apple doesn't ban Apple IDs for running modded local apps.** There's no precedent, and the mechanism (dyld injection + code signing) is the same one used by BetterTouchTool, Alfred, Hammerspoon, accessibility tools, and every Xcode debugger session.
- **The realistic risks** are that FCP updates can break compatibility (just re-patch) and that private APIs can behave unexpectedly in edge cases (Cmd+Z is your friend).

The full plain-English version is in [docs/WHAT_IS_SPLICEKIT.md](docs/WHAT_IS_SPLICEKIT.md).

---

## Building Plugins

If you're here to build things, this is the section for you.

### What's actually happening

SpliceKit injects a dynamic library into a re-signed copy of Final Cut Pro. Once loaded:

- The full ObjC runtime is exposed (78,000+ classes including all private APIs)
- A JSON-RPC 2.0 server listens on `127.0.0.1:9876`
- An MCP server translates tool calls into bridge RPCs
- Flexo, Ozone, TimelineKit, LunaKit, Helium, ProCore — all of FCP's internal frameworks — are reachable via direct `objc_msgSend`
- Crash points around CloudKit / ImagePlayground (which need entitlements a re-signed app doesn't have) are swizzled out

```
┌─────────────────────────────────────────────┐
│  Final Cut Pro (patched copy)               │
│  ┌───────────────────────────────────────┐  │
│  │  SpliceKit.framework (LC_LOAD_DYLIB)  │  │
│  │  ├── Command Palette                  │  │
│  │  ├── MCP / JSON-RPC server on :9876   │  │
│  │  ├── Plugin loader (hot-reload)       │  │
│  │  └── your plugins here                │  │
│  └───────────┬───────────────────────────┘  │
│              │ objc_msgSend                  │
│  ┌───────────▼───────────────────────────┐  │
│  │  Flexo / Ozone / TimelineKit / ...    │  │
│  └───────────────────────────────────────┘  │
└──────────────────────┬──────────────────────┘
                       │ TCP :9876
        ┌──────────────▼──────────────┐
        │  MCP server / Python REPL / │
        │  nc / curl / Lua / your app │
        └─────────────────────────────┘
```

### Ways to build

- **Native plugin** (ObjC / Swift / C++) — link against `SpliceKit.framework`, drop your dylib into the plugins folder, hot-load it with `debug.loadPlugin`. Examples in `Plugins/` and `Sources/`.
- **Lua, inside FCP** — Ctrl+Opt+L opens a REPL with an `sk` module. Drop `.lua` files into `~/Library/Application Support/SpliceKit/lua/auto/` for live coding. Full SDK in [docs/LUA_SDK_REFERENCE.md](docs/LUA_SDK_REFERENCE.md).
- **Python / any language with a TCP socket** — `python3 Scripts/splicekit_client.py` gives you an interactive runtime REPL. Or: `echo '{"jsonrpc":"2.0","method":"system.version","id":1}' | nc 127.0.0.1 9876`
- **MCP tools** — expose your plugin's capabilities as MCP tools and any AI client can drive them.
- **Ask an AI to build it** — the API reference in `docs/` is written to be AI-consumable. Describe what you want, hand the spec to Claude, and it can write the plugin for you.

### Key FCP internals worth knowing

| Class | Methods | Purpose |
|-------|---------|---------|
| `FFAnchoredTimelineModule` | 1435 | Primary timeline controller |
| `FFAnchoredSequence` | 1074 | Timeline data model |
| `FFLibrary` / `FFLibraryDocument` | 203 / 231 | Library management |
| `FFEditActionMgr` | 42 | Edit command dispatcher |
| `FFPlayer` | 228 | Playback engine |
| `PEAppController` | 484 | App controller |

| Prefix | Framework | Classes |
|--------|-----------|---------|
| FF | Flexo — core engine, timeline, editing | 2849 |
| OZ | Ozone — effects, compositing, color | 841 |
| PE | ProEditor — app controller, windows | 271 |
| LK | LunaKit — UI framework | 220 |
| TK | TimelineKit — timeline UI | 111 |
| IX | Interchange — FCPXML import/export | 155 |

### Build from source

```bash
git clone https://github.com/elliotttate/SpliceKit.git
cd SpliceKit
make all && make deploy
```

### Documentation map

- [`docs/WHAT_IS_SPLICEKIT.md`](docs/WHAT_IS_SPLICEKIT.md) — the plain-English tour
- [`docs/FCP_API_REFERENCE.md`](docs/FCP_API_REFERENCE.md) — full API reference for FCP internals
- [`docs/COMMAND_PALETTE_GUIDE.md`](docs/COMMAND_PALETTE_GUIDE.md) — Command Palette & Apple Intelligence
- [`docs/LUA_SDK_REFERENCE.md`](docs/LUA_SDK_REFERENCE.md) · [`docs/LUA_SCRIPTING_GUIDE.md`](docs/LUA_SCRIPTING_GUIDE.md) — Lua plugin scripting
- [`docs/TRANSCRIPT_EDITING_GUIDE.md`](docs/TRANSCRIPT_EDITING_GUIDE.md) — the Text-Based Editor plugin
- [`docs/FXPLUG_PLUGIN_GUIDE.md`](docs/FXPLUG_PLUGIN_GUIDE.md) — FxPlug 4 plugin dev
- [`docs/WORKFLOW_EXTENSIONS_GUIDE.md`](docs/WORKFLOW_EXTENSIONS_GUIDE.md) — Workflow Extensions
- [`docs/DEBUG_TOOLS_GUIDE.md`](docs/DEBUG_TOOLS_GUIDE.md) — in-process debugging, tracing, hot-loading
- [`docs/RUNTIME_INTROSPECTION_GUIDE.md`](docs/RUNTIME_INTROSPECTION_GUIDE.md) — ObjC runtime exploration
- [`docs/FCPXML_FORMAT_REFERENCE.md`](docs/FCPXML_FORMAT_REFERENCE.md) — FCPXML format
- [`docs/SCENE_BEAT_DETECTION_GUIDE.md`](docs/SCENE_BEAT_DETECTION_GUIDE.md) · [`docs/FLEXMUSIC_AND_MONTAGE_GUIDE.md`](docs/FLEXMUSIC_AND_MONTAGE_GUIDE.md) — detection & montage plugins

---

## Community

- **Questions, help, feature requests**: [FCP Cafe Discord](https://discord.com/invite/HD3FPc4Azu) (SpliceKit channels)
- **Bug reports**: [GitHub Issues](https://github.com/elliotttate/SpliceKit/issues)
- **Features, videos, FAQ**: [splicekit.fcp.cafe](https://splicekit.fcp.cafe)

There's a long tradition of community modding projects getting adopted back into the official products they extend. If SpliceKit helps push Final Cut Pro forward, everyone wins.

---

## License

[MIT](LICENSE). Use it, modify it, ship your own plugins with it.

Onwards & upwards 🥳
